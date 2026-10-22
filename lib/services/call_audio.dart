import 'dart:io' show Platform;

import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'call_log.dart';

/// Loudspeaker routing and in-call volume for the emergency call.
///
/// Used by [CallPeer] on both phones:
///  - the cane user's phone is ALWAYS on the loudspeaker, at full call volume;
///  - the guardian's phone starts on the loudspeaker and can be switched to
///    the ear speaker with the on-screen button.
class CallAudio {
  CallAudio._();

  static String _lastOutputs = '';

  /// Sends the call sound to the loudspeaker ([speaker] = true) or to the ear
  /// speaker / headset ([speaker] = false).
  ///
  /// Two steps, because one alone is not reliable on every phone:
  ///   1. `setSpeakerphoneOn` (sets the preferred output),
  ///   2. `selectAudioOutput` with the exact output id ('speaker' / 'earpiece').
  ///
  /// Returns false when the phone did not offer the output we asked for (the
  /// available outputs are written to the call log so we can see why).
  static Future<bool> route({
    required bool speaker,
    required String who,
    bool quiet = false,
  }) async {
    try {
      await Helper.setSpeakerphoneOn(speaker);
    } catch (e) {
      callLog('$who setSpeakerphoneOn($speaker) failed: $e');
    }

    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      final outputs = devices
          .where((d) => d.kind == 'audiooutput')
          .map((d) => d.deviceId)
          .toList();

      final text = outputs.join(', ');
      if (!quiet || text != _lastOutputs) {
        callLog('$who audio outputs: [$text] -> want ${speaker ? 'speaker' : 'earpiece'}');
      }
      _lastOutputs = text;

      final want = speaker ? 'speaker' : 'earpiece';
      if (outputs.contains(want)) {
        await Helper.selectAudioOutput(want);
        return true;
      }
      if (!speaker) {
        // No ear speaker offered (a headset or Bluetooth is connected): the
        // preferred-output call above already picked it, so this is fine.
        return outputs.isNotEmpty && !outputs.every((o) => o == 'speaker');
      }
      return false;
    } catch (e) {
      callLog('$who selectAudioOutput failed: $e');
      return false;
    }
  }

  /// Raises (never lowers) the in-call volume to at least [atLeast] (0.0 - 1.0).
  /// This is the volume the phone's volume keys control during a call, which
  /// is often left low, so one phone can sound much quieter than the other.
  static Future<void> raiseVolume({
    required double atLeast,
    required String who,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await FlutterVolumeController.updateShowSystemUI(false);
      final now =
          await FlutterVolumeController.getVolume(stream: AudioStream.voiceCall);
      callLog('$who call volume is ${now?.toStringAsFixed(2)}, want at least $atLeast');
      if (now == null || now < atLeast) {
        await FlutterVolumeController.setVolume(atLeast,
            stream: AudioStream.voiceCall);
      }
    } catch (e) {
      callLog('$who raiseVolume failed: $e');
    }
  }
}
