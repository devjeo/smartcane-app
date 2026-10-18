// Phase V0 spike: can the always-running tracking service keep the CAMERA
// open with the screen locked and the app in the background?
// Runs inside the background-service isolate. Watch the result with:
//   adb -s <serial> logcat -s flutter | findstr CAM
// ignore_for_file: avoid_print
import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'call_log.dart';

class CameraSpike {
  CameraSpike._();
  static final CameraSpike instance = CameraSpike._();

  MediaStream? _stream;
  Timer? _tick;
  Timer? _limit;
  DateTime? _t0;

  bool get running => _stream != null;

  Future<void> start({int minutes = 30}) async {
    if (_stream != null) {
      callLog('CAM test already running');
      return;
    }
    try {
      _stream = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {
          'facingMode': 'environment',
          'width': {'ideal': 640},
          'height': {'ideal': 480},
          'frameRate': {'ideal': 15},
        },
      });
    } catch (e) {
      _stream = null;
      callLog('CAM test FAILED to open the camera: $e');
      return;
    }
    final tracks = _stream!.getVideoTracks();
    if (tracks.isEmpty) {
      callLog('CAM test: stream has no video track');
      await stop();
      return;
    }
    final track = tracks.first;
    _t0 = DateTime.now();
    callLog('CAM test STARTED (will stop after $minutes min). Lock the screen now.');

    _tick = Timer.periodic(const Duration(seconds: 10), (_) async {
      final secs = DateTime.now().difference(_t0!).inSeconds;
      try {
        final buf = await track.captureFrame();
        final b = buf.asUint8List();
        var h = 0;
        for (var i = 0; i < b.length; i += 997) {
          h = (h * 31 + b[i]) & 0x7fffffff;
        }
        callLog('CAM alive +${secs}s: frame ${b.length} bytes, hash $h, '
            'enabled=${track.enabled}, muted=${track.muted}');
      } catch (e) {
        callLog('CAM capture failed at +${secs}s: $e');
      }
    });
    _limit = Timer(Duration(minutes: minutes), () {
      callLog('CAM test time limit reached');
      stop();
    });
  }

  Future<void> stop() async {
    _tick?.cancel();
    _limit?.cancel();
    _tick = null;
    _limit = null;
    final s = _stream;
    _stream = null;
    if (s != null) {
      for (final t in s.getTracks()) {
        try {
          await t.stop();
        } catch (_) {}
      }
      try {
        await s.dispose();
      } catch (_) {}
      final secs = _t0 == null ? 0 : DateTime.now().difference(_t0!).inSeconds;
      callLog('CAM test STOPPED after ${secs}s');
    }
  }
}