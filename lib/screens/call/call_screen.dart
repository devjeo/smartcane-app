import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../services/call_log.dart';
import '../../services/call_peer.dart';

/// Guardian's call screen: two-way audio with the cane user's phone.
class CallScreen extends StatefulWidget {
  final String callId;
  final String deviceName;
  final String userName;

  const CallScreen({
    super.key,
    required this.callId,
    required this.deviceName,
    required this.userName,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

enum _Video { off, waiting, live, unavailable, stopped }

class _CallScreenState extends State<CallScreen> {
  // Only one call screen per call (a cold-start answer can try to open two).
  static final Set<String> _open = {};
  bool _duplicate = false;
  StreamSubscription? _sub;
  CallPeer? _peer;
  Timer? _connectTimer;
  String _dbStatus = 'active';
  PeerState _peerState = PeerState.starting;
  String? _error;
  bool _speaker = true;
  bool _closing = false;

  // ---- live video (the cane user's camera) ----
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  bool _rendererReady = false;
  _Video _video = _Video.off;
  String _videoReason = '';
  bool _controls = true; // on-screen buttons visible (tap the picture to toggle)
  bool _cover = true; // true = picture fills the screen, false = whole picture
  bool _frontCam = false; // which camera the user's phone is sending
  bool _switching = false;
  bool _immersive = false;
  Timer? _hideTimer;
  bool _quiet = false; // picture hardly changing: camera may be covered
  Timer? _videoTimeout;
  Timer? _statusPoll;

  bool get _finished => const {'ended', 'missed', 'declined', 'failed'}.contains(_dbStatus);
  bool get _connected => _peerState == PeerState.connected;

  @override
  void initState() {
    super.initState();
    if (!_open.add(widget.callId)) {
      _duplicate = true;
      callLog('GUARDIAN duplicate CallScreen for ${widget.callId} -> closing the extra one');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
      return;
    }
    WakelockPlus.enable();

    // Close the screen when the other side (or the server) ends the call.
    _sub = Supabase.instance.client
        .from('calls')
        .stream(primaryKey: ['id'])
        .eq('id', widget.callId)
        .listen((rows) {
      if (rows.isEmpty || !mounted) return;
      _applyDbStatus(rows.first['status'] as String);
    }, onError: (Object e) {
      // The live stream can be refused (e.g. project set to private channels
      // only). The 3-second check below keeps the screen correct anyway.
      callLog('GUARDIAN calls stream error: $e');
    });
    _statusPoll = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (_closing || !mounted) return;
      try {
        final r = await Supabase.instance.client
            .from('calls')
            .select('status')
            .eq('id', widget.callId)
            .maybeSingle();
        if (r != null && mounted) _applyDbStatus(r['status'] as String);
      } catch (_) {}
    });

    _startAudio();
  }

  void _applyDbStatus(String s) {
    if (s == _dbStatus) return;
    callLog('GUARDIAN db status -> $s');
    setState(() => _dbStatus = s);
    if (_finished) _close(endDb: false);
  }

  Future<void> _startAudio() async {
    try {
      await _renderer.initialize();
      _rendererReady = true;
    } catch (e) {
      callLog('GUARDIAN video renderer init failed: $e');
    }
    final peer = CallPeer(
      callId: widget.callId,
      isCaller: false,
      onState: (s) {
        if (!mounted) return;
        callLog('GUARDIAN peer state -> $s');
        setState(() => _peerState = s);
        if (s == PeerState.connected) _connectTimer?.cancel();
        if (_video == _Video.live && s == PeerState.failed) {
          setState(() {
            _video = _Video.unavailable;
            _videoReason = 'connection to that phone was lost';
            _quiet = false;
          });
          _peer?.watchQuiet(false);
        }
        if (s == PeerState.failed) {
          setState(() => _error = "The audio connection failed.");
        }
      },
      onRemoteBye: () {
        callLog('GUARDIAN remote bye -> closing');
        _close(endDb: true);
      },
      onDiag: () {
        if (mounted) setState(() {});
      },
      onRemoteVideo: (stream) {
        if (!mounted || !_rendererReady) return;
        setState(() => _renderer.srcObject = stream);
      },
      onVideoMsg: _onVideoMsg,
      onVideoQuiet: (q) {
        if (mounted && _video == _Video.live) setState(() => _quiet = q);
      },
    );
    _peer = peer;
    try {
      await peer.start();
      await peer.setSpeaker(true);
    } catch (e) {
      if (mounted) {
        setState(() => _error =
            'Could not open the microphone. Allow microphone access for the app, then ask again.');
      }
      return;
    }
    // The user's phone should join within ~20 s after we answer.
    _connectTimer = Timer(const Duration(seconds: 20), () {
      if (mounted && !_connected && _error == null) {
        setState(() => _error =
            "Couldn't reach ${widget.userName}'s phone. Check the last location in the Logs tab.");
      }
    });
  }

  void _onVideoMsg(String event, Map<String, dynamic> d) {
    if (!mounted) return;
    _videoTimeout?.cancel();
    switch (event) {
      case 'video_started':
        setState(() {
          _video = _Video.live;
          _quiet = false;
          _frontCam = false;
          _switching = false;
        });
        _peer?.watchQuiet(true);
        _showControls();
        break;
      case 'video_facing':
        final f = '${d['facing'] ?? ''}';
        setState(() {
          _switching = false;
          if (f == 'front') _frontCam = true;
          if (f == 'back') _frontCam = false;
        });
        if (f == 'failed') {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Could not switch the camera.')));
        }
        break;
      case 'video_denied':
        setState(() {
          _video = _Video.unavailable;
          _videoReason = '${d['reason'] ?? 'unknown reason'}';
          _quiet = false;
        });
        _peer?.watchQuiet(false);
        break;
      case 'video_stop':
        setState(() {
          _video = _Video.stopped;
          _videoReason = '${d['reason'] ?? ''}';
          _quiet = false;
        });
        _peer?.watchQuiet(false);
        break;
    }
  }

  void _watchCamera() {
    final peer = _peer;
    if (peer == null || !_connected) return;
    callLog('GUARDIAN asks to watch the camera');
    setState(() {
      _video = _Video.waiting;
      _videoReason = '';
      _quiet = false;
    });
    peer.sendVideoMsg('video_request');
    _videoTimeout?.cancel();
    _videoTimeout = Timer(const Duration(seconds: 20), () {
      if (mounted && _video == _Video.waiting) {
        setState(() {
          _video = _Video.unavailable;
          _videoReason = 'no answer from ${widget.userName}\'s phone';
        });
      }
    });
  }

  void _showControls() {
    _hideTimer?.cancel();
    if (!_controls && mounted) setState(() => _controls = true);
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && _video == _Video.live) setState(() => _controls = false);
    });
  }

  void _switchCamera() {
    if (_switching) return;
    setState(() => _switching = true);
    _peer?.sendVideoMsg('video_switch');
    _showControls();
    Timer(const Duration(seconds: 6), () {
      if (mounted && _switching) setState(() => _switching = false);
    });
  }

  void _stopWatching() {
    callLog('GUARDIAN stops watching the camera');
    _videoTimeout?.cancel();
    _peer?.sendVideoMsg('video_stop');
    _peer?.watchQuiet(false);
    setState(() {
      _video = _Video.stopped;
      _videoReason = '';
      _quiet = false;
    });
  }

  Future<void> _toggleSpeaker() async {
    setState(() => _speaker = !_speaker);
    await _peer?.setSpeaker(_speaker);
  }

  Future<void> _close({required bool endDb}) async {
    if (_closing) return;
    _closing = true;
    callLog('GUARDIAN screen _close(endDb=$endDb) dbStatus=$_dbStatus peer=$_peerState');
    // Remove the "call in progress" notification FIRST, so a slow or offline
    // end_call request can never leave it stuck.
    try {
      await FlutterCallkitIncoming.endCall(widget.callId);
    } catch (_) {}
    if (endDb) {
      try {
        await Supabase.instance.client
            .rpc('end_call', params: {'p_call_id': widget.callId, 'p_status': 'ended'});
      } catch (_) {}
    }
    await _peer?.close();
    _peer = null;
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    if (_duplicate) {
      super.dispose();
      return;
    }
    _open.remove(widget.callId);
    callLog('GUARDIAN CallScreen dispose (closing=$_closing)');
    _sub?.cancel();
    _statusPoll?.cancel();
    _hideTimer?.cancel();
    if (_immersive) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _connectTimer?.cancel();
    _videoTimeout?.cancel();
    _peer?.close();
    _renderer.srcObject = null;
    _renderer.dispose();
    WakelockPlus.disable();
    // Safety net: whatever way this screen was left (back gesture, route
    // popped, etc.), make sure the "call in progress" notification is removed.
    FlutterCallkitIncoming.endCall(widget.callId).catchError((_) {});
    super.dispose();
  }

  String get _statusText {
    if (_finished) return 'Call ended';
    if (_error != null) return _error!;
    switch (_peerState) {
      case PeerState.connected:
        return 'Connected';
      case PeerState.connecting:
        return 'Connecting audio...';
      case PeerState.waiting:
      case PeerState.starting:
        return 'Waiting for ${widget.userName}\'s phone...';
      case PeerState.failed:
        return 'The audio connection failed.';
      case PeerState.closed:
        return 'Call ended';
    }
  }

  String get _videoText {
    switch (_video) {
      case _Video.off:
        return '';
      case _Video.waiting:
        return 'Waiting for the camera...';
      case _Video.live:
        return 'Live';
      case _Video.unavailable:
        return 'Camera unavailable: $_videoReason';
      case _Video.stopped:
        return _videoReason.isEmpty ? 'Camera stopped' : 'Camera stopped: $_videoReason';
    }
  }

  Widget _watchButton() {
    final busy = _video == _Video.waiting;
    final live = _video == _Video.live;
    if (live) {
      return OutlinedButton.icon(
        onPressed: _stopWatching,
        icon: const Icon(Icons.videocam_off, color: Colors.white),
        label: const Text('Stop camera', style: TextStyle(color: Colors.white)),
        style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white38)),
      );
    }
    return OutlinedButton.icon(
      onPressed: (_connected && !_finished && !busy) ? _watchCamera : null,
      icon: Icon(Icons.videocam, color: _connected ? Colors.white : Colors.white24),
      label: Text(busy ? 'Asking...' : 'Watch camera',
          style: TextStyle(color: _connected ? Colors.white : Colors.white24)),
      style: OutlinedButton.styleFrom(
          side: BorderSide(color: _connected ? Colors.white38 : Colors.white12)),
    );
  }

  Widget _roundBtn({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    Color bg = const Color(0x66FFFFFF),
  }) {
    return Opacity(
      opacity: onTap == null ? 0.5 : 1,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: bg,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(
                width: 60,
                height: 60,
                child: Icon(icon, color: Colors.white, size: 28),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
        ],
      ),
    );
  }

  /// Messenger-style: the picture fills the whole screen, buttons float on
  /// top and fade away; tap to bring them back, double-tap to fill / fit.
  Widget _liveScreen() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (_controls) {
            _hideTimer?.cancel();
            setState(() => _controls = false);
          } else {
            _showControls();
          }
        },
        onDoubleTap: () => setState(() => _cover = !_cover),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_rendererReady)
              RTCVideoView(
                _renderer,
                objectFit: _cover
                    ? RTCVideoViewObjectFit.RTCVideoViewObjectFitCover
                    : RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
              ),
            // top bar
            Align(
              alignment: Alignment.topCenter,
              child: AnimatedOpacity(
                opacity: _controls ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: Container(
                  width: double.infinity,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xAA000000), Color(0x00000000)],
                    ),
                  ),
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                      child: Column(
                        children: [
                          Text(widget.userName,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text(_frontCam ? 'Live - front camera' : 'Live - back camera',
                              style: const TextStyle(color: Colors.white70, fontSize: 13)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // covered / frozen warning (stays visible)
            if (_quiet)
              Positioned(
                left: 16,
                right: 16,
                bottom: 150,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    'Camera may be covered, or nothing is moving.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFFFFE08A), fontSize: 14),
                  ),
                ),
              ),
            // bottom buttons
            Align(
              alignment: Alignment.bottomCenter,
              child: AnimatedOpacity(
                opacity: _controls ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !_controls,
                  child: Container(
                    width: double.infinity,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Color(0xCC000000), Color(0x00000000)],
                      ),
                    ),
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 36, 12, 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _roundBtn(
                              icon: Icons.cameraswitch,
                              label: _frontCam ? 'Back cam' : 'Front cam',
                              onTap: _switching ? null : _switchCamera,
                            ),
                            _roundBtn(
                              icon: _speaker ? Icons.volume_up : Icons.hearing,
                              label: _speaker ? 'Speaker' : 'Earpiece',
                              onTap: () {
                                _toggleSpeaker();
                                _showControls();
                              },
                            ),
                            _roundBtn(
                              icon: Icons.videocam_off,
                              label: 'Stop video',
                              onTap: _stopWatching,
                            ),
                            _roundBtn(
                              icon: Icons.call_end,
                              label: 'End',
                              bg: const Color(0xFFB3261E),
                              onTap: () => _close(endDb: true),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final live = _video == _Video.live;
    if (live != _immersive) {
      _immersive = live;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          SystemChrome.setEnabledSystemUIMode(
              live ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
        } catch (_) {}
      });
    }
    if (live) return _liveScreen();
    return Scaffold(
      backgroundColor: const Color(0xFF1B1B1F),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(),
              Text(widget.userName,
                  style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text('Emergency call from ${widget.deviceName}',
                  style: const TextStyle(color: Colors.white70, fontSize: 16)),
              const SizedBox(height: 24),
              Text(
                _statusText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _error != null ? const Color(0xFFFFB4AB) : Colors.white,
                  fontSize: 18,
                ),
              ),
              if (_video != _Video.off) ...[
                const SizedBox(height: 10),
                Text(
                  _videoText,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _video == _Video.unavailable
                        ? const Color(0xFFFFB4AB)
                        : Colors.white70,
                    fontSize: 15,
                  ),
                ),
              ],
              const Spacer(),
              // Temporary diagnostics (removed once calls are stable)
              Text(
                'This phone: ${_peer?.diag ?? '-'}\nOther phone: ${(_peer?.remoteDiag.isEmpty ?? true) ? 'no data yet' : _peer!.remoteDiag}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
              const SizedBox(height: 16),
              _watchButton(),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _toggleSpeaker,
                icon: Icon(_speaker ? Icons.volume_up : Icons.hearing, color: Colors.white),
                label: Text(_speaker ? 'Speaker on' : 'Speaker off',
                    style: const TextStyle(color: Colors.white)),
                style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white38)),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 64,
                child: ElevatedButton(
                  onPressed: () => _close(endDb: true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFB3261E),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
                  ),
                  child: const Text('End call', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}