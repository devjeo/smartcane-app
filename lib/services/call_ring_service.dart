import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../firebase_options.dart';
import 'call_log.dart';
import 'background_location_service.dart' show startBackgroundTracking;

/// Lets call_ring_service open the call screen without a BuildContext.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

const _supabaseUrl = 'https://ldnspxkgplermswenlcw.supabase.co';
const _supabasePublishableKey = 'sb_publishable_BS85pEN8ysMODHWLRwqGwQ_uRimdY6P';

/// FCM data messages that arrive while the app is in the background or closed.
/// Must be a top-level function (the system starts a separate isolate for it).
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (_) {}
  await CallRingService.handleFcmData(message.data);
}

/// Ring-screen button presses while the app is in the background or closed.
/// Answer needs the app screen, so only Decline is handled here; Answer is
/// picked up by the app when it opens (see CallRingService.start).
@pragma('vm:entry-point')
Future<void> callkitBackgroundHandler(CallEvent event) async {
  if (event is CallEventActionCallDecline) {
    await CallRingService.declineCall(event.callKitParams.id);
  }
}

/// Guardian side of the emergency call: shows the full-screen ring when the
/// `incoming_call` push arrives and answers/declines through the database.
class CallRingService {
  CallRingService._();
  static final CallRingService instance = CallRingService._();

  static final Set<String> _acceptedIds = {};
  static const _finishedStates = {'ended', 'missed', 'declined', 'failed'};
  StreamSubscription? _sub;
  bool _started = false;
  _ResumeObserver? _observer;

  // ---------- ending the CallKit call / notification ----------

  /// Removes the ring screen / "call in progress" notification for [callId].
  /// Never throws, but logs a failure instead of hiding it.
  static Future<void> endCallkit(String callId) async {
    try {
      await FlutterCallkitIncoming.endCall(callId);
    } catch (e) {
      callLog('endCallkit($callId) failed: $e');
    }
    // Some phones (e.g. Xiaomi/Poco HyperOS) leave the plugin's foreground
    // service - and its "call in progress" notification - running even after
    // endCall. Stop it directly.
    await forceStopCallService(callId: callId);
  }

  static const MethodChannel _native = MethodChannel('smartcane/callkit_cleanup');

  /// Stops the plugin's ongoing-call foreground service (see MainActivity.kt).
  /// Only works in the main isolate; elsewhere it is a harmless no-op.
  static Future<void> forceStopCallService({String? callId, bool clearAll = false}) async {
    try {
      await _native.invokeMethod('stopCallService', {
        'callId': callId,
        'clearAll': clearAll,
      });
    } catch (e) {
      callLog('forceStopCallService: $e');
    }
  }

  /// Ends every CallKit call whose database row is already finished (or gone).
  /// Cleans up a "call in progress" notification left behind when the app was
  /// killed or frozen while the call ended. Runs on start and on every resume.
  static Future<void> sweepStaleCalls() async {
    try {
      final calls = await FlutterCallkitIncoming.activeCalls();
      if (calls.isEmpty) {
        // No call is active, so no "call in progress" notification should be.
        await forceStopCallService(clearAll: true);
        return;
      }
      final c = await _client();
      if (c.auth.currentUser == null) return;
      for (final call in calls) {
        final id = call.id;
        if (id.isEmpty) continue;
        try {
          final row = await c
              .from('calls')
              .select('status')
              .eq('id', id)
              .maybeSingle();
          final status = row?['status'] as String?;
          if (status == null || _finishedStates.contains(status)) {
            callLog('sweep: ending stale call $id (status=$status)');
            await endCallkit(id);
          }
        } catch (e) {
          callLog('sweep: could not check call $id: $e');
        }
      }
    } catch (e) {
      callLog('sweep error: $e');
    }
  }

  // ---------- push -> ring ----------

  /// Called for every FCM data message (foreground and background).
  static Future<void> handleFcmData(Map<String, dynamic> data) async {
    final type = data['type']?.toString();
    if (type == 'start_sos') {
      await _forwardSos(data['sos_id']?.toString());
      return;
    }
    final callId = data['call_id']?.toString();
    if (callId == null || callId.isEmpty) return;
    callLog('push received: $type call=$callId');

    if (type == 'incoming_call') {
      await _showIncoming(callId, data);
    } else if (type == 'call_ended') {
      await endCallkit(callId);
    }
    else if (type == 'start_call') {
      // Backup path for the cane user's phone: the tracking service owns the
      // microphone, so the call is handed to it. (The main path is Realtime.)
      try {
        final svc = FlutterBackgroundService();
        if (await svc.isRunning()) {
          svc.invoke('startCall', {'call_id': callId});
        } else {
          // Best effort: the service is not running. Try to start it; once
          // up, it picks up the still-ringing call by itself (it checks for
          // a ringing call in the last 60 s). Android 14+ forbids starting a
          // microphone service from the background, so this can fail there.
          callLog('start_call: service not running, trying to start it');
          final ok = await startBackgroundTracking()
              .timeout(const Duration(seconds: 10), onTimeout: () => false);
          callLog(ok
              ? 'start_call: service start requested'
              : 'start_call: could not start service (permission or timeout)');
        }
      } catch (e) {
        callLog('start_call: service start blocked by Android: $e');
      }
    }
  }

  /// Solo SOS push: hand it to the tracking service (it owns the dialing).
  static Future<void> _forwardSos(String? sosId) async {
    if (sosId == null || sosId.isEmpty) return;
    callLog('push received: start_sos id=$sosId');
    try {
      final svc = FlutterBackgroundService();
      if (await svc.isRunning()) {
        svc.invoke('startSos', {'sos_id': sosId});
      } else {
        // Once the service is up it picks up the still-open SOS by itself.
        await startBackgroundTracking()
            .timeout(const Duration(seconds: 10), onTimeout: () => false);
      }
    } catch (e) {
      callLog('start_sos: could not reach the service: $e');
    }
  }

  static Future<void> _showIncoming(String callId, Map<String, dynamic> data) async {
    // The same push can arrive twice (foreground + background path).
    try {
      final active = await FlutterCallkitIncoming.activeCalls();
      if (active.any((c) => c.id == callId)) return;
    } catch (_) {}

    final userName = (data['user_name']?.toString().trim().isNotEmpty ?? false)
        ? data['user_name'].toString()
        : 'Cane user';
    final deviceName = data['device_name']?.toString() ?? 'Smart Cane';

    final params = CallKitParams(
      id: callId,
      nameCaller: userName,
      appName: 'SmartCane',
      handle: 'Emergency call from $deviceName',
      type: 0, // 0 = audio
      duration: 45000, // stops ringing after 45 s, same as the retry rule
      // No "call in progress" notification / foreground service after the call
      // is answered. On Xiaomi/Poco that notification could get stuck forever
      // (Android does not let an app remove a foreground-service notification
      // once its service is gone). The app's own call screen is the call UI.
      callingNotification: const NotificationParams(showNotification: false),
      missedCallNotification: const NotificationParams(
        showNotification: true,
        isShowCallback: false,
        subtitle: 'Missed emergency call',
      ),
      extra: <String, dynamic>{
        'call_id': callId,
        'device_id': data['device_id']?.toString() ?? '',
        'device_name': deviceName,
        'user_name': userName,
      },
      android: const AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#B3261E',
        actionColor: '#2E7D32',
        textColor: '#ffffff',
        incomingCallNotificationChannelName: 'Emergency calls',
        missedCallNotificationChannelName: 'Missed emergency calls',
        isShowFullLockedScreen: true,
        textAccept: 'Answer',
        textDecline: 'Decline',
      ),
    );
    await FlutterCallkitIncoming.showCallkitIncoming(params);
  }

  // ---------- ring buttons ----------

  /// Call once from main() after runApp. Listens for Answer / Decline while the
  /// app is open, and picks up an Answer pressed while the app was closed.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    _sub = FlutterCallkitIncoming.onEvent.listen((event) {
      callLog('GUARDIAN callkit event: ${event.runtimeType}');
      if (event is CallEventActionCallAccept) {
        _accept(event.callKitParams.id, event.callKitParams.extra ?? {});
      } else if (event is CallEventActionCallDecline) {
        declineCall(event.callKitParams.id);
      } else if (event is CallEventActionCallEnded) {
        // Hang-up pressed on the notification.
        endCallkit(event.callKitParams.id);
      } else if (event is CallEventActionCallTimeout) {
        // The ring timed out. (This event carries `id`, not `callKitParams`.)
        endCallkit(event.id);
      }
    });

    // Answer pressed on the lock screen while the app was closed: the app was
    // launched by that tap, so the answered call is waiting for us here.
    try {
      final calls = await FlutterCallkitIncoming.activeCalls();
      for (final c in calls) {
        if (c.isAccepted) {
          _accept(c.id, c.extra ?? {}, fromLaunch: true);
        }
      }
    } catch (_) {}

    // Leftover notifications from calls that already finished.
    unawaited(sweepStaleCalls());
    _observer = _ResumeObserver(() => unawaited(sweepStaleCalls()));
    WidgetsBinding.instance.addObserver(_observer!);

    unawaited(_askPermissionsOnce());
  }

  static Future<SupabaseClient> _client() async {
    try {
      return Supabase.instance.client;
    } catch (_) {
      // Background isolate: Supabase is not started there yet. The saved
      // login is restored automatically.
      await Supabase.initialize(url: _supabaseUrl, publishableKey: _supabasePublishableKey);
      return Supabase.instance.client;
    }
  }

  static Future<void> declineCall(String callId) async {
    try {
      final c = await _client();
      if (c.auth.currentUser != null) {
        await c.rpc('decline_call', params: {'p_call_id': callId});
      }
    } catch (_) {}
    await endCallkit(callId);
  }

  static Future<NavigatorState?> _waitForNavigator() async {
    for (var i = 0; i < 50; i++) {
      final nav = appNavigatorKey.currentState;
      if (nav != null) return nav;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return null;
  }

  static Future<void> _accept(String callId, Map<String, dynamic> extra,
      {bool fromLaunch = false}) async {
    if (!_acceptedIds.add(callId)) return; // already handled in this run
    callLog('GUARDIAN accepting call $callId');
    final nav = await _waitForNavigator();
    if (nav == null) {
      // No screen to show the call on: don't leave a ghost call / notification.
      callLog('GUARDIAN accept: navigator not ready, declining $callId');
      await declineCall(callId);
      return;
    }
    try {
      final c = await _client();
      if (c.auth.currentUser == null) throw Exception('Please sign in to answer.');
      await c.rpc('accept_call', params: {'p_call_id': callId});
      nav.pushNamed('/call', arguments: {
        'callId': callId,
        'deviceId': extra['device_id'],
        'deviceName': extra['device_name'] ?? 'Smart Cane',
        'userName': extra['user_name'] ?? 'Cane user',
      });
    } catch (e) {
      await endCallkit(callId);
      if (fromLaunch) return; // stale entry from an older call: stay quiet
      final state = RegExp(r'no longer ringing \((\w+)\)').firstMatch(e.toString())?.group(1);
      final msg = state != null
          ? 'This call is no longer ringing ($state).'
          : 'Could not answer the call.';
      // (the call's current state is in the error text, e.g. "(missed)")
      final ctx = nav.context;
      ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  /// Android 14+ shows the full-screen ring on a locked phone only when the
  /// app has the "full-screen notifications" permission. Asked once.
  Future<void> _askPermissionsOnce() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (Supabase.instance.client.auth.currentUser == null) return;
      // The guardian needs the microphone to talk; ask while the app is
      // visible, because it cannot be asked from the lock screen.
      if (prefs.getBool('call_mic_asked') != true) {
        await prefs.setBool('call_mic_asked', true);
        if (!await Permission.microphone.isGranted) {
          await Permission.microphone.request();
        }
      }
      if (prefs.getBool('fullscreen_call_asked') == true) return;
      await prefs.setBool('fullscreen_call_asked', true);
      if (!await FlutterCallkitIncoming.canUseFullScreenIntent()) {
        await FlutterCallkitIncoming.requestFullIntentPermission();
      }
    } catch (_) {}
  }

  void dispose() {
    _sub?.cancel();
    if (_observer != null) {
      WidgetsBinding.instance.removeObserver(_observer!);
      _observer = null;
    }
    _started = false;
  }
}

/// Runs [onResume] every time the app comes back to the foreground.
class _ResumeObserver with WidgetsBindingObserver {
  _ResumeObserver(this.onResume);
  final VoidCallback onResume;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResume();
  }
}