// Background location tracking, equivalent to the expo-task-manager +
// expo-location block at the top of _layout.tsx.
//
// IMPORTANT — Flutter has no built-in background-location primitive like
// Expo's TaskManager. The most common approach is:
//   • geolocator            -> gets the actual GPS position
//   • flutter_background_service (or flutter_foreground_task on Android)
//                           -> keeps a long-running isolate/service alive
//                              so location updates keep flowing while the
//                              app is backgrounded/killed.
// This file uses `flutter_background_service`, which works on both
// Android (as a foreground service) and iOS (as a background fetch /
// location-updates capable process, with the usual Info.plist background
// mode caveats). You still need to:
//   1. Add the `geolocator` and `flutter_background_service` packages.
//   2. Add ACCESS_BACKGROUND_LOCATION (Android) and the "Location updates"
//      background mode (iOS Info.plist).
//   3. Call `initializeBackgroundService()` once during app startup
//      (e.g. in main() before runApp), then `startBackgroundTracking()` /
//      `stopBackgroundTracking()` from your settings/tracker screen.

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'supabase_service.dart';
import 'user_call_runner.dart';
import 'sos_ladder_runner.dart';
import 'walk_runner.dart';
import 'dart:async';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'location_filter.dart';

const String kLocationServiceNotificationChannelId =
    'location_tracking_channel';

const AndroidNotificationChannel channel = AndroidNotificationChannel(
  kLocationServiceNotificationChannelId,
  'Smart Cane Tracking',
  description: 'This channel is used for background location tracking.',
  importance: Importance.high, // High importance ensures it displays reliably
);

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> initializeBackgroundService() async {
  print('=== BACKGROUND TRACKING: Initializing Service ===');

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  print('=== BACKGROUND TRACKING: Service Instance Created ===');
  await _configureService();
}

/// Service types: always `location`; `microphone` only once the microphone
/// permission is granted. Android 14+ throws a SecurityException if a
/// foreground service is started with the microphone type without that
/// permission (it would also crash location tracking).
Future<bool> _micGranted() async => await Permission.microphone.isGranted;
Future<bool> _camGranted() async => await Permission.camera.isGranted;

Future<bool> _configureService() async {
  final withMic = await _micGranted();
  // Camera type only once the camera permission is granted (same Android 14+
  // SecurityException rule as the microphone).
  final withCam = await _camGranted();
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: _onServiceStart,
      // Started from the app only for accounts that carry a cane
      // (see MainTabScreen), never automatically for guardians/viewers.
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: kLocationServiceNotificationChannelId,
      initialNotificationTitle: 'SmartCaneApp',
      initialNotificationContent: 'Tracking location in the background',
      foregroundServiceTypes: [
        AndroidForegroundType.location,
        if (withMic) AndroidForegroundType.microphone,
        if (withCam) AndroidForegroundType.camera,
      ],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: _onServiceStart,
      onBackground: (service) async => true,
    ),
  );
  return withMic;
}

/// SharedPreferences flag: was the service last configured WITH the
/// microphone type? (User Home restarts the service when mic is granted later.)
const String kServiceHasMicPref = 'svc_has_mic';

/// Same idea for the camera type (video, Phase V).
const String kServiceHasCamPref = 'svc_has_cam';

@pragma('vm:entry-point')
void _onServiceStart(ServiceInstance service) async {
  print('=== BACKGROUND TRACKING: Isolate Started ===');

  // ⚠️ IMPORTANT: Background isolates do not share memory with the main app.
  await Supabase.initialize(
    url: 'https://ldnspxkgplermswenlcw.supabase.co',
    publishableKey: 'sb_publishable_BS85pEN8ysMODHWLRwqGwQ_uRimdY6P',
  );

  print('=== BACKGROUND TRACKING: Supabase Initialized ===');

  final dbService = SupabaseService.instance;

  Timer? ticker;
  StreamSubscription<Position>? posSub;
  service.on('stopService').listen((_) async {
    ticker?.cancel();
    await posSub?.cancel();
    await UserCallRunner.instance.stop();
    await SosLadderRunner.instance.stop();
    // Keeps the walk open on the server so it can resume after a restart.
    await WalkRunner.instance.shutdown();
    service.stopSelf();
  });
  // Emergency calls: this isolate is the only place the microphone can be
  // opened in the background, so the cane user's side of the call lives here.
  // While the camera is on, the permanent service notification says so.
  UserCallRunner.instance.onCameraChanged = (on) {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: on ? 'Camera is on' : 'SmartCaneApp',
        content: on
            ? 'Your guardian is viewing your camera.'
            : 'Tracking location in the background',
      );
    }
  };
  final callUid = dbService.currentUser?.id;
  if (callUid != null) {
    UserCallRunner.instance.start(callUid);
    SosLadderRunner.instance.start(callUid); // solo canes: contact ladder
  }
  // Backup path: the start_sos push is forwarded here by the app.
  service.on('startSos').listen((e) {
    final id = e?['sos_id'];
    if (id != null) SosLadderRunner.instance.handleSosId(id.toString());
  });
  // Backup path: the start_call push is forwarded here by the app.
  service.on('startCall').listen((e) {
    final id = e?['call_id'];
    if (id != null) UserCallRunner.instance.handleCallId(id.toString());
  });
  // Walking routes: voice guidance and progress reports for a saved route.
  // The screen starts a walk with the 'startWalk' message; a walk that was
  // running when the service restarted is picked up again here.
  WalkRunner.instance.attach(service);
  // generate random session ID for this background tracking session
  final sessionId = DateTime.now().millisecondsSinceEpoch.toString();

  // ---- Movement-driven, filtered location sending -----------------------
  //
  //   GPS stream (best accuracy)
  //     -> LocationFilter  (quality gates, Kalman smoothing, stationary hold)
  //     -> PublishPolicy   (send on movement / heartbeat / live mode)
  //     -> location_history
  //
  // The GPS stream only runs while the cane is online (same rule as before:
  // do not wake the GPS chip for a cane that is offline).
  final filter = LocationFilter();
  final policy = PublishPolicy();
  String? deviceId; // cached; re-checked by refresh()
  var liveMode = false; // guardian watching, walk running, or SOS running
  var publishing = false; // one insert at a time
  var refreshing = false;
  var tick = 0;

  Future<void> onPosition(Position p) async {
    final id = deviceId;
    if (id == null) return;

    final DateTime? ts = p.timestamp;
    final res = filter.process(RawFix(
      lat: p.latitude,
      lng: p.longitude,
      accuracy: p.accuracy,
      time: ts ?? DateTime.now(),
      isMocked: p.isMocked,
      speed: p.speed,
    ));
    if (!res.accepted) {
      print('=== LOCATION: dropped (${res.verdict.name}) ===');
      return;
    }
    final f = res.fix!;

    final reason = policy.decide(f, live: liveMode);
    if (reason == null || publishing) return;

    publishing = true;
    try {
      await dbService.logLocationPing(
        sessionId: sessionId,
        deviceId: id,
        latitude: f.lat,
        longitude: f.lng,
        accuracy: f.accuracy,
      );
      policy.markPublished(f); // only after a successful send, so failures retry
      print('=== LOCATION: sent (${reason.name}, +-${f.accuracy.toStringAsFixed(0)} m) ===');
    } catch (e) {
      print('=== LOCATION: send failed: $e ===');
    } finally {
      publishing = false;
    }
  }

  void startStream() {
    if (posSub != null) return;
    filter.reset(); // a fresh stream starts with a fresh warm-up
    policy.reset();
    final LocationSettings settings = defaultTargetPlatform == TargetPlatform.android
        ? AndroidSettings(
            accuracy: LocationAccuracy.best,
            distanceFilter: 0,
            intervalDuration: const Duration(seconds: 2),
          )
        : const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 0);
    posSub = Geolocator.getPositionStream(locationSettings: settings).listen(
      onPosition,
      onError: (e) => print('=== LOCATION: stream error: $e ==='),
      cancelOnError: false,
    );
    print('=== LOCATION: GPS stream started ===');
  }

  Future<void> stopStream() async {
    if (posSub == null) return;
    await posSub!.cancel();
    posSub = null;
    print('=== LOCATION: GPS stream stopped ===');
  }

  /// Every 15 s: keep the stream in step with the cane's online state and
  /// refresh live mode. The device id is re-checked every 60 s while online,
  /// and every tick while offline (so tracking resumes quickly).
  Future<void> refresh() async {
    if (refreshing) return;
    refreshing = true;
    try {
      final user = dbService.currentUser;
      if (user == null) {
        deviceId = null;
        liveMode = false;
        await stopStream();
        return;
      }
      if (deviceId == null || tick % 4 == 0) {
        deviceId = await dbService.getLinkedDeviceId(user.id);
      }
      final id = deviceId;
      if (id == null) {
        liveMode = false;
        await stopStream(); // cane offline or unpaired: GPS off
        return;
      }
      startStream();

      var live = WalkRunner.instance.isWalking || SosLadderRunner.instance.isActive;
      if (!live) live = await dbService.isLiveWatchActive(id);
      if (live != liveMode) print('=== LOCATION: live mode ${live ? "ON" : "OFF"} ===');
      liveMode = live;
    } catch (e) {
      print('=== LOCATION: refresh error: $e ===');
    } finally {
      tick++;
      refreshing = false;
    }
  }

  await refresh();
  ticker = Timer.periodic(const Duration(seconds: 15), (_) => refresh());
}

/// Equivalent to `startBackgroundTracking()` in _layout.tsx.
///
/// Calls that overlap (MainTabScreen reloads roles several times in a row)
/// share one in-flight start, so the service is never started twice.
Future<bool>? _startInFlight;

Future<bool> startBackgroundTracking() {
  return _startInFlight ??=
      _startBackgroundTracking().whenComplete(() => _startInFlight = null);
}

Future<bool> _startBackgroundTracking() async {
  LocationPermission permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.deniedForever) {
    return false;
  }
  // On Android 10+, background access is a *separate* permission prompt
  // from foreground access — `geolocator` surfaces this via
  // LocationPermission.always vs .whileInUse.
  if (permission != LocationPermission.always &&
      permission != LocationPermission.whileInUse) {
    return false;
  }

  // Re-read the microphone permission so the service type is right.
  final withMic = await _configureService();
  final service = FlutterBackgroundService();
  if (!await service.isRunning()) {
    await service.startService();
    // Remember which type this service instance was started with.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kServiceHasMicPref, withMic);
    await prefs.setBool(kServiceHasCamPref, await _camGranted());
  }
  return true;
}

/// Stops and starts the service again (used when the microphone permission
/// is granted AFTER the service was started without the microphone type).
/// Must be called while the app is visible.
Future<bool> restartBackgroundTracking() async {
  await stopBackgroundTracking();
  // Wait until the old service has really stopped. If start ran while it was
  // still alive it would be skipped, the "has microphone" flag would stay
  // unset, and User Home would restart the service again on every resume.
  final service = FlutterBackgroundService();
  for (var i = 0; i < 12 && await service.isRunning(); i++) {
    await Future.delayed(const Duration(milliseconds: 500));
  }
  return startBackgroundTracking();
}

/// Equivalent to `stopBackgroundTracking()` in _layout.tsx.
/// Also called on logout, so a phone that is signed out (or switched to
/// another account) never keeps reporting as the previous account.
Future<void> stopBackgroundTracking() async {
  final service = FlutterBackgroundService();
  final isRunning = await service.isRunning();
  if (isRunning) {
    service.invoke('stopService');
  }
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(kServiceHasMicPref);
  await prefs.remove(kServiceHasCamPref);
}