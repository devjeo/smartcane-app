import 'dart:async';
import 'dart:math';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'call_log.dart';

enum PeerState { starting, waiting, connecting, connected, failed, closed }

/// One end of the emergency call audio (WebRTC) plus its signalling over a
/// Supabase Realtime broadcast channel `call:<callId>`.
///
/// Caller = the cane user's phone (runs inside the tracking service).
/// Callee = the guardian's phone (runs in the call screen).
///
/// Handshake: the callee sends `ready` every 2 s until an offer arrives; the
/// caller answers every `ready` with its offer; then answer + ICE candidates.
/// Both sides open the microphone first so the handshake is quick.
class CallPeer {
  final String callId;
  final bool isCaller;
  final void Function(PeerState state) onState;
  final void Function() onRemoteBye;
  final void Function()? onDiag; // fired when the diagnostics text changes

  /// Video messages from the other phone: video_request, video_started,
  /// video_denied (data['reason']), video_stop.
  final void Function(String event, Map<String, dynamic> data)? onVideoMsg;

  /// Guardian side: the incoming video stream (null = it went away).
  final void Function(MediaStream? stream)? onRemoteVideo;

  /// User's phone: the camera stopped by itself (taken by another app, or the
  /// system closed it). The peer has already released it when this fires.
  final void Function()? onCameraEnded;

  /// Guardian side: true when the incoming picture has hardly changed for a
  /// few seconds (camera covered, in a pocket, or nothing is moving).
  final void Function(bool quiet)? onVideoQuiet;

  String get _who => isCaller ? 'USER' : 'GUARDIAN';

  CallPeer({
    required this.callId,
    required this.isCaller,
    required this.onState,
    required this.onRemoteBye,
    this.onDiag,
    this.onVideoMsg,
    this.onRemoteVideo,
    this.onCameraEnded,
    this.onVideoQuiet,
  });

  // ---- diagnostics (shown on the guardian's call screen) ----
  String _ice = 'new';
  final Map<String, int> _localTypes = {};
  final Map<String, int> _remoteTypes = {};
  bool _gotAnswer = false;
  String remoteDiag = '';
  String _lastError = '';
  Timer? _diagTimer;
  Timer? _statsTimer;
  int _lastIn = 0, _lastOut = 0;

  static String _fmt(Map<String, int> m) =>
      'host ${m['host'] ?? 0}, srflx ${m['srflx'] ?? 0}, relay ${m['relay'] ?? 0}';
  static String _typeOf(String? c) =>
      RegExp(r' typ (\w+)').firstMatch(c ?? '')?.group(1) ?? 'other';

  String get diag =>
      'ice=$_ice | turn=$_turnNote | local: ${_fmt(_localTypes)} | remote: ${_fmt(_remoteTypes)} | '
      '${isCaller ? 'got answer=$_gotAnswer' : 'got offer=$_gotOffer'}'
      '${_lastError.isEmpty ? '' : ' | err: $_lastError'}';

  /// TEST SWITCH: true = use ONLY the TURN relay (proves the relay works:
  /// the call must connect and "relay" must be above 0 in the gray line).
  /// Keep false for normal use.
  static const bool kForceRelay = false;

  /// Phase V3: the call channel is PRIVATE, so Supabase only lets the two
  /// people on the call (caller and callee of the `calls` row) join it.
  /// Needs v3_private_call_channel.sql applied first. If a call will not
  /// connect after the change, set this to false to go back to the old behaviour.
  static const bool kPrivateChannel = true;

  static const _stunOnly = <Map<String, dynamic>>[
    {
      'urls': [
        'stun:stun.l.google.com:19302',
        'stun:stun1.l.google.com:19302',
      ]
    },
  ];

  // TURN credentials come from the `turn-credentials` Edge Function (the
  // provider key stays on the server). Cached so a retry call is instant.
  static List<Map<String, dynamic>>? _turnCache;
  static DateTime? _turnCacheAt;
  String _turnNote = 'none';

  Future<List<Map<String, dynamic>>> _iceServers() async {
    final at = _turnCacheAt;
    if (_turnCache != null && at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 30)) {
      _turnNote = 'cached';
      return [..._stunOnly, ..._turnCache!];
    }
    try {
      final res = await Supabase.instance.client.functions
          .invoke('turn-credentials')
          .timeout(const Duration(seconds: 5));
      final raw = (res.data as Map?)?['iceServers'];
      if (raw is List && raw.isNotEmpty) {
        final list = raw
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
        _turnCache = list;
        _turnCacheAt = DateTime.now();
        _turnNote = 'ok';
        return [..._stunOnly, ...list];
      }
      _turnNote = 'empty';
    } catch (e) {
      _turnNote = 'failed';
      callLog('$_who turn fetch failed: $e');
    }
    return _stunOnly; // never block the call: fall back to STUN only
  }

  // Random id so a phone can recognise (and ignore) its own broadcasts.
  final String _me = Random().nextInt(1 << 31).toRadixString(36) +
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  RealtimeChannel? _channel;
  RTCPeerConnection? _pc;
  MediaStream? _local;

  // ---- video (user's phone sends, guardian's phone receives) ----
  static const int kVideoMaxKbps = 400;
  static const int kVideoMaxFps = 15;
  static const double kVideoScaleDown = 2.0; // 1280x720 camera -> 640x360 sent
  // "Camera may be covered": under ~6 kbps for 8 s. A still scene measured
  // about 3 kbps, so this also fires when nothing moves; the wording says so.
  static const int kQuietBytesPer2s = 1500;
  static const int kQuietSamples = 4;
  bool _watchQuiet = false;
  bool _quiet = false;
  int _quietCount = 0;
  int _lastVidBytes = -1;
  RTCRtpTransceiver? _videoTx;
  MediaStream? _videoStream;
  MediaStream? _cam;
  bool get cameraOn => _cam != null;
  bool _front = false; // the camera always opens on the back
  Timer? _readyTimer;
  final List<RTCIceCandidate> _pendingIce = [];
  Map<String, dynamic>? _offerPayload;
  bool _remoteSet = false;
  bool _gotOffer = false;
  bool _offering = false; // an offer is being created right now
  bool _closed = false;

  Future<void> start() async {
    onState(PeerState.starting);

    _local = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': false,
    });

    final servers = await _iceServers();
    final pc = await createPeerConnection({
      'iceServers': servers,
      'sdpSemantics': 'unified-plan',
      if (kForceRelay) 'iceTransportPolicy': 'relay',
    });
    _pc = pc;
    for (final t in _local!.getAudioTracks()) {
      await pc.addTrack(t, _local!);
    }
    if (isCaller) {
      // A send-only video line from the start, with NO camera attached: no
      // camera is opened and no video flows until the guardian asks. Later the
      // camera is swapped in with replaceTrack, so nothing is renegotiated.
      try {
        _videoStream = await createLocalMediaStream('cane-video');
        _videoTx = await pc.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: RTCRtpTransceiverInit(
            direction: TransceiverDirection.SendOnly,
            streams: [_videoStream!],
          ),
        );
        callLog('$_who video line added (send-only, no camera yet)');
      } catch (e) {
        _videoTx = null;
        callLog('$_who video line FAILED: $e');
      }
    }

    pc.onIceCandidate = (c) {
      if (c.candidate == null || c.candidate!.isEmpty) return;
      final t = _typeOf(c.candidate);
      _localTypes[t] = (_localTypes[t] ?? 0) + 1;
      callLog('$_who local candidate: $t');
      onDiag?.call();
      _send('ice', {
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    };
    pc.onTrack = (e) async {
      if (e.track.kind == 'audio') e.track.enabled = true;
      if (e.track.kind == 'video' && !isCaller) {
        callLog('$_who got remote video track (streams=${e.streams.length})');
        MediaStream? st = e.streams.isNotEmpty ? e.streams.first : null;
        if (st == null) {
          try {
            st = await createLocalMediaStream('remote-video');
            await st.addTrack(e.track);
          } catch (err) {
            callLog('$_who could not wrap the video track: $err');
          }
        }
        if (!_closed) onRemoteVideo?.call(st);
      }
    };
    pc.onConnectionState = (s) => callLog('$_who connectionState -> $s');
    pc.onIceConnectionState = (s) {
      if (_closed) return;
      _ice = s.toString().split('.').last.replaceFirst('RTCIceConnectionState', '');
      callLog('$_who ice -> $_ice');
      onDiag?.call();
      switch (s) {
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          onState(PeerState.connected);
          break;
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          onState(PeerState.failed);
          break;
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          onState(PeerState.connecting);
          break;
        default:
          break;
      }
    };

    final ch = Supabase.instance.client.channel(
      'call:$callId',
      opts: const RealtimeChannelConfig(private: kPrivateChannel),
    );
    _channel = ch;
    ch
        .onBroadcast(event: 'ready', callback: (p) => _guard(() => _onReady(p)))
        .onBroadcast(event: 'offer', callback: (p) => _guard(() => _onOffer(p)))
        .onBroadcast(event: 'answer', callback: (p) => _guard(() => _onAnswer(p)))
        .onBroadcast(event: 'ice', callback: (p) => _guard(() => _onIce(p)))
        .onBroadcast(event: 'diag', callback: (p) {
          final d = _in(p, 'diag');
          if (d == null) return;
          remoteDiag = '${d['t']}';
          onDiag?.call();
        })
        .onBroadcast(event: 'video_request', callback: (p) => _video(p, 'video_request'))
        .onBroadcast(event: 'video_started', callback: (p) => _video(p, 'video_started'))
        .onBroadcast(event: 'video_denied', callback: (p) => _video(p, 'video_denied'))
        .onBroadcast(event: 'video_stop', callback: (p) => _video(p, 'video_stop'))
        .onBroadcast(event: 'video_switch', callback: (p) => _video(p, 'video_switch'))
        .onBroadcast(event: 'video_facing', callback: (p) => _video(p, 'video_facing'))
        .onBroadcast(event: 'bye', callback: (p) {
      if (_in(p, 'bye') != null && !_closed) {
        callLog('$_who got BYE from the other phone');
        onRemoteBye();
      }
    }).subscribe((status, error) {
      if (status == RealtimeSubscribeStatus.subscribed) {
        _onSubscribed();
      } else {
        // A refused private join shows up here (channelError + the reason).
        callLog('$_who channel status=$status error=$error');
        if (status == RealtimeSubscribeStatus.channelError ||
            status == RealtimeSubscribeStatus.timedOut) {
          _lastError = 'channel $status ${error ?? ''}'.trim();
          onDiag?.call();
        }
      }
    });
  }

  void _onSubscribed() {
    if (_closed) return;
    callLog('$_who channel subscribed');
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) => _logStats());
    onState(PeerState.waiting);
    _diagTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_closed) _send('diag', {'t': diag});
    });
    if (!isCaller) {
      // Tell the caller we are here; repeat until the offer arrives, because
      // the caller may join the channel later than we do.
      _send('ready', {});
      _readyTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (_gotOffer || _closed) {
          _readyTimer?.cancel();
        } else {
          _send('ready', {});
        }
      });
    }
  }

  // ---- caller side ----
  Future<void> _onReady(Map<String, dynamic> p) async {
    if (_in(p, 'ready') == null) return;
    callLog('$_who got ready');
    if (!isCaller || _closed || _pc == null) return;
    if (_offerPayload != null) {
      _send('offer', _offerPayload!); // resend: the first one may have been missed
      return;
    }
    // Several `ready` messages can arrive in one burst (a delayed socket).
    // Only the first may build the offer; building two at once makes WebRTC
    // fail with "order of m-lines ... doesn't match".
    if (_offering) return;
    _offering = true;
    try {
      onState(PeerState.connecting);
      final offer = await _pc!.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      });
      await _pc!.setLocalDescription(offer);
      _offerPayload = {'sdp': offer.sdp};
      _send('offer', _offerPayload!);
    } finally {
      _offering = false;
    }
  }

  Future<void> _onAnswer(Map<String, dynamic> p) async {
    final data = _in(p, 'answer');
    if (data == null) return;
    callLog('$_who got answer');
    if (!isCaller || _closed || _pc == null || _remoteSet) return;
    final sdp = data['sdp'];
    if (sdp is! String || sdp.isEmpty) return; // malformed: ignore, never crash
    // The type is fixed by the protocol, so it never depends on the payload.
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    _remoteSet = true;
    _gotAnswer = true;
    onDiag?.call();
    await _flushIce();
  }

  // ---- callee side ----
  Future<void> _onOffer(Map<String, dynamic> p) async {
    final data = _in(p, 'offer');
    if (data == null) return;
    callLog('$_who got offer');
    if (isCaller || _closed || _pc == null || _gotOffer) return;
    final sdp = data['sdp'];
    if (sdp is! String || sdp.isEmpty) return;
    _gotOffer = true;
    _readyTimer?.cancel();
    onState(PeerState.connecting);
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    _remoteSet = true;
    await _flushIce();
    final answer = await _pc!.createAnswer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': true,
    });
    await _pc!.setLocalDescription(answer);
    _send('answer', {'sdp': answer.sdp});
  }

  // ---- both ----
  Future<void> _onIce(Map<String, dynamic> p) async {
    final d = _in(p, 'ice');
    if (d == null || _closed || _pc == null) return;
    final c = d['candidate'];
    callLog('$_who got remote candidate: ${c is String ? _typeOf(c) : 'INVALID'}');
    // A candidate without text would make the native WebRTC library abort the
    // whole app (SIGABRT), so anything incomplete is dropped here.
    if (c is! String || c.isEmpty) return;
    final rt = _typeOf(c);
    _remoteTypes[rt] = (_remoteTypes[rt] ?? 0) + 1;
    onDiag?.call();
    final cand = RTCIceCandidate(
      c,
      (d['sdpMid'] as String?) ?? '0',
      (d['sdpMLineIndex'] as num?)?.toInt() ?? 0,
    );
    if (_remoteSet) {
      await _pc!.addCandidate(cand);
    } else {
      _pendingIce.add(cand);
    }
  }

  Future<void> _flushIce() async {
    for (final c in _pendingIce) {
      await _pc?.addCandidate(c);
    }
    _pendingIce.clear();
  }

  /// Finds our own message inside whatever wrapping the Realtime client
  /// added (the layering differs between library versions). Returns null when
  /// the message is not the expected event, or was sent by this phone.
  Map<String, dynamic>? _in(Map<String, dynamic> p, String event) {
    Map<String, dynamic> m = p;
    for (var i = 0; i < 4; i++) {
      if (m.containsKey('k')) break;
      final inner = m['payload'];
      if (inner is Map) {
        m = Map<String, dynamic>.from(inner);
      } else {
        break;
      }
    }
    if (m['k'] != event) return null;
    if (m['from'] == _me) return null;
    return m;
  }

  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      _lastError = '$e';
      callLog('$_who handler error: $e');
      onDiag?.call();
    }
  }

  void _send(String event, Map<String, dynamic> payload) {
    if (event != 'diag' && event != 'ice') callLog('$_who send $event');
    try {
      // The Realtime client WRITES 'type' and 'event' into the map it is
      // given, so our own fields must never use those names, and the data
      // goes under 'payload' with a fresh copy every time.
      _channel?.sendBroadcastMessage(
        event: event,
        payload: {
          'payload': {...payload, 'k': event, 'from': _me},
        },
      );
    } catch (_) {}
  }



  // ---------- video ----------

  void _video(Map<String, dynamic> p, String event) {
    final d = _in(p, event);
    if (d == null || _closed) return;
    callLog('$_who got $event${d['reason'] != null ? ' (${d['reason']})' : ''}');
    onVideoMsg?.call(event, d);
  }

  void sendVideoMsg(String event, {String? reason, String? facing}) => _send(event, {
        if (reason != null) 'reason': reason,
        if (facing != null) 'facing': facing,
      });

  /// User's phone: flip between the back and the front camera while it is on.
  /// Returns 'front' or 'back', or null if it failed.
  Future<String?> switchCamera() async {
    final c = _cam;
    if (c == null) return null;
    final tracks = c.getVideoTracks();
    if (tracks.isEmpty) return null;
    try {
      await Helper.switchCamera(tracks.first);
      _front = !_front;
      callLog('$_who camera switched to ${_front ? 'front' : 'back'}');
      return _front ? 'front' : 'back';
    } catch (e) {
      callLog('$_who camera switch FAILED: $e');
      return null;
    }
  }

  /// User's phone: open the camera and start sending it. Returns null on
  /// success, otherwise a short reason for the guardian.
  Future<String?> startCamera() async {
    final tx = _videoTx;
    if (tx == null) return 'video is not available in this call';
    if (_cam != null) return null;
    MediaStream cam;
    try {
      cam = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {
          'facingMode': 'environment',
          'width': {'ideal': 640},
          'height': {'ideal': 480},
          'frameRate': {'ideal': kVideoMaxFps},
        },
      });
    } catch (e) {
      callLog('$_who camera open FAILED: $e');
      final t = '$e'.toLowerCase();
      if (t.contains('security') || t.contains('permission')) {
        return 'Android blocked the camera in the background';
      }
      return 'the camera could not be opened';
    }
    final tracks = cam.getVideoTracks();
    if (tracks.isEmpty) {
      await _disposeStream(cam);
      return 'the camera gave no picture';
    }
    try {
      await tx.sender.replaceTrack(tracks.first);
    } catch (e) {
      callLog('$_who replaceTrack FAILED: $e');
      await _disposeStream(cam);
      return 'the video could not be attached';
    }
    _cam = cam;
    _front = false;
    // If the camera dies by itself, release everything and tell the app.
    tracks.first.onEnded = () {
      if (_cam == null || _closed) return;
      callLog('$_who camera track ENDED by itself');
      stopCamera().then((_) => onCameraEnded?.call());
    };
    callLog('$_who camera ON and attached to the call');
    await _capVideo();
    return null;
  }

  /// Keep mobile data low: cap bitrate and frame rate, shrink the picture.
  Future<void> _capVideo() async {
    final tx = _videoTx;
    if (tx == null) return;
    try {
      final params = tx.sender.parameters;
      final encs = params.encodings;
      if (encs == null || encs.isEmpty) {
        callLog('$_who video cap: sender has no encodings yet');
        return;
      }
      for (final e in encs) {
        e.maxBitrate = kVideoMaxKbps * 1000;
        e.maxFramerate = kVideoMaxFps;
        e.scaleResolutionDownBy = kVideoScaleDown;
      }
      final ok = await tx.sender.setParameters(params);
      callLog('$_who video cap set ($kVideoMaxKbps kbps, $kVideoMaxFps fps, '
          '1/$kVideoScaleDown size) ok=$ok');
    } catch (e) {
      callLog('$_who video cap FAILED: $e');
    }
  }

  Future<void> stopCamera() async {
    try {
      await _videoTx?.sender.replaceTrack(null);
    } catch (_) {}
    final c = _cam;
    _cam = null;
    if (c != null) {
      for (final t in c.getVideoTracks()) {
        t.onEnded = null; // our own stop must not look like a failure
      }
      await _disposeStream(c);
      callLog('$_who camera OFF');
    }
  }

  Future<void> _disposeStream(MediaStream s) async {
    for (final t in s.getTracks()) {
      try {
        await t.stop();
      } catch (_) {}
    }
    try {
      await s.dispose();
    } catch (_) {}
  }

  /// Every 2 s: which route the audio uses and whether bytes are still flowing.
  Future<void> _logStats() async {
    final pc = _pc;
    if (pc == null || _closed) return;
    try {
      final reports = await pc.getStats();
      final byId = {for (final r in reports) r.id: r};
      StatsReport? pair;
      for (final r in reports) {
        if (r.type != 'candidate-pair') continue;
        final v = r.values;
        if ('${v['nominated']}' == 'true' && '${v['state']}' == 'succeeded') {
          pair = r;
        }
      }
      if (pair == null) {
        callLog('$_who stats: no selected pair yet');
        return;
      }
      final v = pair.values;
      final loc = byId['${v['localCandidateId']}']?.values ?? {};
      final rem = byId['${v['remoteCandidateId']}']?.values ?? {};
      final inB = int.tryParse('${v['bytesReceived']}') ?? 0;
      final outB = int.tryParse('${v['bytesSent']}') ?? 0;
      callLog('$_who stats: route local=${loc['candidateType']}/${loc['networkType']} '
          'remote=${rem['candidateType']} | in +${inB - _lastIn}B out +${outB - _lastOut}B '
          '| rtt=${v['currentRoundTripTime']}');
      _lastIn = inB;
      _lastOut = outB;
      for (final r in reports) {
        final rv = r.values;
        if ('${rv['kind'] ?? rv['mediaType']}' != 'video') continue;
        if (r.type == 'outbound-rtp' && cameraOn) {
          callLog('$_who video out: ${rv['bytesSent']}B total, '
              '${rv['frameWidth']}x${rv['frameHeight']}, frames ${rv['framesEncoded']}');
        } else if (r.type == 'inbound-rtp' && !isCaller) {
          callLog('$_who video in: ${rv['bytesReceived']}B total, '
              '${rv['frameWidth']}x${rv['frameHeight']}, frames ${rv['framesDecoded']}');
          if (_watchQuiet) {
            final b = int.tryParse('${rv['bytesReceived']}') ?? 0;
            if (_lastVidBytes >= 0) {
              _quietCount = (b - _lastVidBytes) < kQuietBytesPer2s ? _quietCount + 1 : 0;
              final q = _quietCount >= kQuietSamples;
              if (q != _quiet) {
                _quiet = q;
                callLog('$_who video quiet=$q');
                onVideoQuiet?.call(q);
              }
            }
            _lastVidBytes = b;
          }
        }
      }
    } catch (e) {
      callLog('$_who stats error: $e');
    }
  }

  /// Guardian side: start/stop watching for a covered or frozen picture.
  void watchQuiet(bool on) {
    _watchQuiet = on;
    _quietCount = 0;
    _lastVidBytes = -1;
    if (_quiet) {
      _quiet = false;
      onVideoQuiet?.call(false);
    }
  }

  Future<void> setSpeaker(bool on) async {
    try {
      await Helper.setSpeakerphoneOn(on);
    } catch (_) {}
  }

  Future<void> close({bool sendBye = true}) async {
    if (_closed) return;
    callLog('$_who peer.close(sendBye=$sendBye) ice=$_ice');
    if (sendBye) _send('bye', {});
    _closed = true;
    _readyTimer?.cancel();
    _diagTimer?.cancel();
    _statsTimer?.cancel();
    await stopCamera();
    try {
      for (final t in _local?.getTracks() ?? <MediaStreamTrack>[]) {
        await t.stop();
      }
      await _local?.dispose();
    } catch (_) {}
    try {
      await _pc?.close();
    } catch (_) {}
    try {
      final ch = _channel;
      if (ch != null) await Supabase.instance.client.removeChannel(ch);
    } catch (_) {}
    _local = null;
    _pc = null;
    _channel = null;
    onState(PeerState.closed);
  }
}