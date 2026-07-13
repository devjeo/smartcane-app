import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'supabase_service.dart';

/// Flutter/FCM equivalent of the notification block in _layout.tsx:
///   - Notifications.setNotificationHandler(...)   -> _onForegroundMessage
///   - Notifications.requestPermissionsAsync()      -> requestPermission()
///   - Notifications.getExpoPushTokenAsync(...)     -> FirebaseMessaging token
///   - supabase.from('profiles').update({expo_push_token})
///
/// NOTE: Expo's push service is Expo-only, so there's no direct Flutter
/// equivalent — Firebase Cloud Messaging is the standard replacement. Your
/// backend sender (the Python service that was calling Expo's push API)
/// will need a small change to send via FCM instead of Expo for Flutter
/// devices, or you keep both fields on `profiles` if RN and Flutter builds
/// coexist.
class PushNotificationService {
  PushNotificationService._();
  static final PushNotificationService instance = PushNotificationService._();

  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  /// Call once, near app startup, after Supabase + Firebase are initialized
  /// and (ideally) after the user is logged in — mirrors the useEffect in
  /// TabLayout that ran on every tab-layout mount.
  Future<void> registerForPushNotifications() async {
    final messaging = FirebaseMessaging.instance;

    // 1. Ask for permission (Android 13+/iOS)
    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      // eslint-disable-next-line no-console (kept for parity with the RN log)
      // ignore: avoid_print
      print('Failed to get push token for push notification!');
      return;
    }

    // 2. Set up the local-notification channel so foreground pushes actually
    //    show a banner, same intent as setNotificationHandler's
    //    shouldShowAlert/shouldPlaySound/shouldSetBadge: true.
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await _localNotifications.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
    );

    FirebaseMessaging.onMessage.listen(_onForegroundMessage);

    // 3. Get this device's unique push token
    final token = await messaging.getToken();
    // ignore: avoid_print
    print('My Push Token: $token');

    if (token == null) return;

    // 4. Save it to Supabase, same as the RN version — only if a user is
    //    logged in.
    if (SupabaseService.instance.currentUser != null) {
      try {
        await SupabaseService.instance.savePushToken(token);
        // ignore: avoid_print
        print(
            '✅ Push token successfully saved for user: ${SupabaseService.instance.currentUser!.id}');
      } catch (e) {
        // ignore: avoid_print
        print('Error saving push token to Supabase: $e');
      }
    } else {
      // ignore: avoid_print
      print('⚠️ No active user logged in. Push token was not saved.');
    }
  }

  Future<void> _onForegroundMessage(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;

    const androidDetails = AndroidNotificationDetails(
      'guardian_alerts',
      'Guardian Alerts',
      importance: Importance.max,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);

    await _localNotifications.show(
      notification.hashCode,
      notification.title,
      notification.body,
      details,
    );
  }
}
