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
import 'supabase_service.dart';

const String kLocationServiceNotificationChannelId = 'location_tracking_channel';

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: _onServiceStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: kLocationServiceNotificationChannelId,
      initialNotificationTitle: 'SmartCaneApp',
      initialNotificationContent: 'Tracking location in the background',
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: _onServiceStart,
      onBackground: (service) async => true,
    ),
  );
}

@pragma('vm:entry-point')
void _onServiceStart(ServiceInstance service) async {
  // ⚠️ IMPORTANT: Background isolates do not share memory with the main app.
  // You MUST re-initialize Supabase here before using the service.
  // Replace the URL and AnonKey with your actual Supabase credentials.
  await Supabase.initialize(
    url: 'YOUR_SUPABASE_URL', 
    anonKey: 'YOUR_SUPABASE_ANON_KEY',
  );

  final dbService = SupabaseService.instance;

  Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.medium, // matches expo-location's Balanced
      distanceFilter: 50, // meters — matches original distanceInterval
    ),
  ).listen((position) async {
    try {
      final user = dbService.currentUser;
      if (user == null) return;

      // Gets the device ID, aborting if none is linked to this user
      final deviceId = await dbService.getLinkedDeviceId(user.id);
      if (deviceId == null) {
        return; 
      }

      // Logs the location
      await dbService.logLocationPing(
        deviceId: deviceId,
        latitude: position.latitude,
        longitude: position.longitude,
      );
    } catch (e) {
      // Swallow errors here; a background isolate has nowhere to surface them.
    }
  });
}

/// Equivalent to `startBackgroundTracking()` in _layout.tsx.
Future<bool> startBackgroundTracking() async {
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
  if (permission != LocationPermission.always && permission != LocationPermission.whileInUse) {
    return false;
  }

  final service = FlutterBackgroundService();
  await service.startService();
  return true;
}

/// Equivalent to `stopBackgroundTracking()` in _layout.tsx.
Future<void> stopBackgroundTracking() async {
  final service = FlutterBackgroundService();
  final isRunning = await service.isRunning();
  if (isRunning) {
    service.invoke('stopService');
  }
}