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
import 'supabase_service.dart';
import 'dart:async';

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

  final service = FlutterBackgroundService();
  print('=== BACKGROUND TRACKING: Service Instance Created ===');

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: _onServiceStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: kLocationServiceNotificationChannelId,
      initialNotificationTitle: 'SmartCaneApp',
      initialNotificationContent: 'Tracking location in the background',
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: _onServiceStart,
      onBackground: (service) async => true,
    ),
  );
}

@pragma('vm:entry-point')
void _onServiceStart(ServiceInstance service) async {
  print('=== BACKGROUND TRACKING: Isolate Started ===');

  // ⚠️ IMPORTANT: Background isolates do not share memory with the main app.
  await Supabase.initialize(
    url: 'https://ldnspxkgplermswenlcw.supabase.co',
    anonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxkbnNweGtncGxlcm1zd2VubGN3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM1MTg1OTUsImV4cCI6MjA4OTA5NDU5NX0.qCn-1WvwwZNrIF2m6um2CnDozkhWPhPmVyrMrQo8Svg',
  );

  print('=== BACKGROUND TRACKING: Supabase Initialized ===');

  final dbService = SupabaseService.instance;
  // generate random session ID for this background tracking session
  final sessionId = DateTime.now().millisecondsSinceEpoch.toString();

  // Triggers exactly once every 60 seconds, regardless of movement
  Timer.periodic(const Duration(seconds: 20), (timer) async {
    print('=== BACKGROUND TRACKING: Timer Triggered ===');

    try {
      final user = dbService.currentUser;
      if (user == null) {
        print('=== BACKGROUND TRACKING ABORTED: User is null ===');
        return;
      }
      print('=== BACKGROUND TRACKING: User Found (${user.id}) ===');

      // 1. Check if the device is online FIRST
      final deviceId = await dbService.getLinkedDeviceId(user.id);
      print('=== BACKGROUND TRACKING: Device ID Retrieved ($deviceId) ===');
      if (deviceId == null) {
        print(
            '=== BACKGROUND TRACKING ABORTED: Device offline or not found ===');
        return;
      }
      print('=== BACKGROUND TRACKING: Device Found ($deviceId) ===');

      // 2. Only wake up the GPS chip if the device is actually online
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
        ),
      );

      // 3. Send the location
      await dbService.logLocationPing(
        sessionId: sessionId,
        deviceId: deviceId,
        latitude: position.latitude,
        longitude: position.longitude,
      );
      print('=== BACKGROUND TRACKING SUCCESS: Pushed to Supabase ===');
    } catch (e) {
      print('=== BACKGROUND TRACKING FATAL ERROR: $e ===');
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
  if (permission != LocationPermission.always &&
      permission != LocationPermission.whileInUse) {
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
