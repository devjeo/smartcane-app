import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'call_log.dart';
import 'call_peer.dart';

/// The cane user's side of the emergency call. Runs INSIDE the always-running
/// tracking service (the only place Android lets us open the microphone from
/// the background). It hears the new `calls` row over Realtime (primary) or
/// the `start_call` push (backup), then places the call by itself: speaks,
/// opens the mic, turns the speaker on, and retries up to 3 attempts.
class UserCallRunner {
  UserCallRunner._();
  static final UserCallRunner instance = UserCallRunner._();

  static const _ringTimeout = Duration(seconds: 45);
  static const _connectTimeout = Duration(seconds: 25);
  static const _retryDelay = Duration(seconds: 15);
  static const _maxCall = Duration(minutes: 15);
  static const _maxVideo = Duration(minutes: 10); // plan V5

  SupabaseClient get _db => Supabase.instance.client;
  final FlutterTts _tts = FlutterTts();
  bool _ttsReady = false;

  RealtimeChannel? _channel;
  String? _uid;

  String? _activeId; // call being placed / in progress
  String? _logId;
  CallPeer? _peer;
  bool _answered = false;
  bool _connected = false;
  Timer? _ringTimer, _connectTimer, _maxTimer, _pollTimer, _retryTimer;
  Timer? _videoLimit, _videoWatch;
  bool _videoBusy = false;

  /// Told when the camera turns on or off, so the service can show (or clear)
  /// the "camera is on" notification. Set by the tracking service.
  void Function(bool on)? onCameraChanged;

  Future<void> start(String uid) async {
    if (_uid == uid && _channel != null) return;
    _uid = uid;
    await _channel?.unsubscribe();

    final filter = PostgresChangeFilter(
        type: PostgresChangeFilterType.eq, column: 'caller_id', value: uid);
    _channel = _db
        .channel('user-calls-$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'calls',
          filter: filter,
          callback: (p) => _onInsert(p.newRecord),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'calls',
          filter: filter,
          callback: (p) => _onUpdate(p.newRecord),
        )
        .subscribe();

    // A call may already be ringing (service restarted just now).
    await _resumeIfRinging(uid);
  }

  Future<void> stop() async {
    _teardown();
    _activeId = null;
    await _channel?.unsubscribe();
    _channel = null;
    _uid = null;
  }

  /// Backup path: the `start_call` push names the call.
  Future<void> handleCallId(String callId) async {
    if (_activeId != null) return;
    try {
      final row = await _db.from('calls').select().eq('id', callId).maybeSingle();
      if (row != null) _onInsert(row);
    } catch (_) {}
  }

  Future<void> _resumeIfRinging(String uid) async {
    try {
      final since = DateTime.now().toUtc().subtract(const Duration(seconds: 60));
      final rows = await _db
          .from('calls')
          .select()
          .eq('caller_id', uid)
          .eq('status', 'ringing')
          .gte('created_at', since.toIso8601String())
          .order('created_at', ascending: false)
          .limit(1);
      if (rows.isNotEmpty) _onInsert(rows.first);
    } catch (_) {}
  }

  // ---------- events ----------

  void _onInsert(Map<String, dynamic> row) {
    callLog('USER call row inserted: ${row['id']} status=${row['status']} busy=${_activeId != null}');
    if (_activeId != null) return; // one call at a time
    if (row['status'] != 'ringing') return;
    final created = DateTime.tryParse('${row['created_at']}');
    if (created != null &&
        DateTime.now().toUtc().difference(created.toUtc()) > const Duration(seconds: 90)) {
      return; // stale
    }
    _placeCall(row);
  }

  String? _lastStatus;
  void _onUpdate(Map<String, dynamic> row) {
    if (row['id'] != _activeId) return;
    if (_lastStatus != '${row['status']}') {
      _lastStatus = '${row['status']}';
      callLog('USER db status -> ${row['status']}');
    }
    switch (row['status']) {
      case 'active':
        if (!_answered) {
          _answered = true;
          _ringTimer?.cancel();
          // The guardian answered: the audio handshake must finish soon.
          _connectTimer?.cancel();
          _connectTimer = Timer(_connectTimeout, () {
            if (!_connected) {
              callLog('USER connect timeout (25 s after answer) -> ending call');
              _endCall('failed', say: 'The call could not connect.');
            }
          });
        }
        break;
      case 'declined':
        _say('Your guardian is unavailable.');
        _scheduleRetry();
        break;
      case 'missed':
        _scheduleRetry();
        break;
      case 'ended':
      case 'failed':
        callLog('USER db says ${row['status']} -> tearing down');
        _say('Call ended.');
        _teardown();
        _activeId = null;
        break;
    }
  }

  // ---------- placing the call ----------

  Future<void> _placeCall(Map<String, dynamic> row) async {
    final id = row['id'] as String;
    _activeId = id;
    _logId = row['log_id'] as String?;
    _answered = false;
    _connected = false;

    callLog('USER placing call $id');
    _say('Emergency. Calling your guardian.');
    try {
      await _db.rpc('begin_outgoing_call', params: {'p_call_id': id});
    } catch (e) {
      callLog('USER begin_outgoing_call error: $e');
    }

    _peer = CallPeer(
      callId: id,
      isCaller: true,
      onState: _onPeerState,
      onRemoteBye: () => _endCall('ended', say: 'Call ended.', sendBye: false),
      onVideoMsg: _onVideoMsg,
      onCameraEnded: _onCameraLost,
    );
    try {
      await _peer!.start();
      await _peer!.setSpeaker(true);
    } catch (e) {
      callLog('USER peer.start error: $e');
      // Microphone could not be opened (permission, or service not started
      // with the microphone type). The alert push still reached the guardian.
      _say('The call could not start.');
      _endCall('failed');
      return;
    }

    _ringTimer = Timer(_ringTimeout, _onRingTimeout);
    _maxTimer = Timer(_maxCall, () => _endCall('ended', say: 'Call ended.'));
    // Safety net: the Realtime update can be missed, so also check the row.
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      final cid = _activeId;
      if (cid == null) return;
      try {
        final r = await _db.from('calls').select().eq('id', cid).maybeSingle();
        if (r != null) _onUpdate(r);
      } catch (_) {}
    });
  }

  void _onPeerState(PeerState s) {
    if (s == PeerState.connected && !_connected) {
      _connected = true;
      callLog('USER audio CONNECTED');
      _connectTimer?.cancel();
      _ringTimer?.cancel();
      _say('Your guardian is on the line.');
    } else if (s == PeerState.failed && _activeId != null) {
      callLog('USER peer FAILED -> ending call');
      _endCall('failed', say: 'The call could not connect.');
    }
  }

  Future<void> _onRingTimeout() async {
    if (_answered || _activeId == null) return;
    callLog('USER ring timeout (45 s, nobody answered)');
    try {
      await _db.rpc('end_call', params: {'p_call_id': _activeId, 'p_status': 'missed'});
    } catch (_) {}
    _say('Your guardian is not answering.');
    _scheduleRetry();
  }

  /// Missed or declined: wait 15 s, then ask the server for the next attempt
  /// (it refuses after the 3rd).
  void _scheduleRetry() {
    final log = _logId;
    _teardown();
    _activeId = null;
    if (log == null) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(_retryDelay, () async {
      try {
        final newId = await _db.rpc('retry_emergency_call', params: {'p_log_id': log});
        if (newId == null) {
          _say('Your guardian could not be reached. The alert has been sent.');
          return;
        }
        final row = await _db.from('calls').select().eq('id', newId as String).maybeSingle();
        if (row != null && _activeId == null) _placeCall(row);
      } catch (_) {}
    });
  }

  Future<void> _endCall(String status, {String? say, bool sendBye = true}) async {
    final id = _activeId;
    if (id == null) return;
    callLog('USER endCall status=$status sendBye=$sendBye say=$say');
    if (say != null) _say(say);
    final peer = _peer;
    _teardown(closePeer: false);
    _activeId = null;
    try {
      await _db.rpc('end_call', params: {'p_call_id': id, 'p_status': status});
    } catch (e) {
      callLog('USER end_call error: $e');
    }
    await peer?.close(sendBye: sendBye);
    _peer = null;
  }

  void _teardown({bool closePeer = true}) {
    _ringTimer?.cancel();
    _connectTimer?.cancel();
    _maxTimer?.cancel();
    _pollTimer?.cancel();
    _videoLimit?.cancel();
    _videoLimit = null;
    _videoWatch?.cancel();
    _videoWatch = null;
    _videoBusy = false;
    onCameraChanged?.call(false);
    if (closePeer) {
      _peer?.close();
      _peer = null;
    }
  }

  // ---------- live video (guardian asks, this phone answers) ----------

  void _onVideoMsg(String event, Map<String, dynamic> data) {
    // Only the two people on this call can reach this channel (private
    // channel, Phase V3); _startVideo additionally checks the call itself.
    switch (event) {
      case 'video_request':
        _startVideo();
        break;
      case 'video_stop':
        _stopVideo(tell: false);
        break;
      case 'video_switch':
        _switchVideo();
        break;
    }
  }

  /// Guardian asked to flip the camera. Same fail-closed check as starting.
  Future<void> _switchVideo() async {
    final peer = _peer;
    if (peer == null) return;
    if (!peer.cameraOn || _videoBusy || !await _callIsValidForVideo()) {
      peer.sendVideoMsg('video_facing', facing: 'failed');
      return;
    }
    _videoBusy = true;
    try {
      final f = await peer.switchCamera();
      if (f != null) _say(f == 'front' ? 'Front camera.' : 'Back camera.');
      peer.sendVideoMsg('video_facing', facing: f ?? 'failed');
    } finally {
      _videoBusy = false;
    }
  }

  Future<void> _startVideo() async {
    final peer = _peer;
    if (peer == null || _activeId == null) return;
    if (!_connected) {
      peer.sendVideoMsg('video_denied', reason: 'the call is not connected yet');
      return;
    }
    if (peer.cameraOn) {
      peer.sendVideoMsg('video_started'); // already on: just confirm
      return;
    }
    if (_videoBusy) return;
    _videoBusy = true;
    try {
      if (!await _callIsValidForVideo()) {
        callLog('USER video request REJECTED (call not verified)');
        peer.sendVideoMsg('video_denied', reason: 'the request could not be verified');
        return;
      }
      try {
        if (!await Permission.camera.isGranted) {
          callLog('USER video denied: camera permission missing');
          peer.sendVideoMsg('video_denied', reason: 'camera not allowed on that phone');
          return;
        }
      } catch (_) {
        // Could not check from here: try to open the camera anyway.
      }
      callLog('USER video requested -> opening the camera');
      final err = await peer.startCamera();
      if (err != null) {
        _say('The camera could not start.');
        peer.sendVideoMsg('video_denied', reason: err);
        return;
      }
      _say('Your guardian is viewing your camera.');
      onCameraChanged?.call(true);
      peer.sendVideoMsg('video_started');
      _videoLimit?.cancel();
      _videoLimit = Timer(_maxVideo, () {
        callLog('USER video time limit reached');
        _stopVideo(tell: true, reason: 'time limit reached (10 minutes)');
      });
      _videoWatch?.cancel();
      _videoWatch = Timer.periodic(const Duration(seconds: 5), (_) async {
        try {
          if (!await Permission.camera.isGranted) {
            callLog('USER camera permission removed during video');
            _stopVideo(tell: true, reason: 'camera permission was removed on that phone');
          }
        } catch (_) {}
      });
    } finally {
      _videoBusy = false;
    }
  }

  /// Fresh check against the database, failing closed: the call must be the
  /// one in progress, still active (the guardian answered), and placed by
  /// THIS account. Any doubt means no camera.
  Future<bool> _callIsValidForVideo() async {
    final id = _activeId;
    final me = _uid;
    if (id == null || me == null) return false;
    try {
      final r = await _db
          .from('calls')
          .select('caller_id, status')
          .eq('id', id)
          .maybeSingle();
      if (r == null) return false;
      return r['status'] == 'active' && r['caller_id'] == me;
    } catch (e) {
      callLog('USER video verify error: $e');
      return false;
    }
  }

  /// The camera died by itself (another app took it, or the system closed it).
  void _onCameraLost() {
    callLog('USER camera lost');
    _stopVideo(tell: true, reason: 'the camera stopped (another app may be using it)',
        alreadyStopped: true);
  }

  /// [tell] = we decided to stop (limit, error), so tell the guardian too.
  Future<void> _stopVideo({
    required bool tell,
    String? reason,
    bool alreadyStopped = false,
  }) async {
    final peer = _peer;
    _videoLimit?.cancel();
    _videoLimit = null;
    _videoWatch?.cancel();
    _videoWatch = null;
    if (peer == null) return;
    if (!alreadyStopped) {
      if (!peer.cameraOn) return;
      await peer.stopCamera();
    }
    onCameraChanged?.call(false);
    _say('Camera off.');
    if (tell) peer.sendVideoMsg('video_stop', reason: reason);
  }

  // ---------- speech ----------

  Future<void> _say(String text) async {
    try {
      if (!_ttsReady) {
        _ttsReady = true;
        await _tts.setLanguage('en-US');
        await _tts.setSpeechRate(0.45);
      }
      await _tts.speak(text); // not awaited to completion: never delay the call
    } catch (_) {}
  }
}