import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

import 'screens/main_tab_screen.dart';
import 'screens/logs/logs_screen.dart';
import 'screens/about/about_screen.dart';
import 'screens/edit_profile/edit_profile_screen.dart';
import 'screens/login/login_screen.dart';
import 'screens/register/register_screen.dart';
import 'screens/add_device/add_device_screen.dart';
import 'screens/tracker/tracker_screen.dart';
import 'screens/device_settings/device_settings_screen.dart';
import 'screens/geofence_editor/geofence_editor_screen.dart';
import 'screens/placeholder_screen.dart';
import 'theme/app_colors.dart';
import 'services/background_location_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Same Supabase project the RN app used — plug in your real values,
  // e.g. via --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
  await Supabase.initialize(
    url: const String.fromEnvironment('SUPABASE_URL', defaultValue: 'https://ldnspxkgplermswenlcw.supabase.co'),
    publishableKey: const String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY', defaultValue: 'sb_publishable_BS85pEN8ysMODHWLRwqGwQ_uRimdY6P'),
  );

  await initializeBackgroundService();
  print('=== BACKGROUND TRACKING: Service Initialized ===');

  // Needed for push_notification_service.dart (FCM). Run `flutterfire configure`
  // to generate firebase_options.dart, then pass it here as `options:`.
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );


  runApp(const SmartCaneApp());
}

class SmartCaneApp extends StatelessWidget {
  const SmartCaneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SmartCaneApp',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: AppColors.bg,
        colorScheme: ColorScheme.fromSeed(seedColor: AppColors.primary),
        fontFamily: 'Roboto',
        useMaterial3: true,
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const MainTabScreen(),
        '/login': (context) => const LoginScreen(),
        '/register': (context) => const RegisterScreen(),
        '/add-device': (context) => const AddDeviceScreen(),
        '/edit-profile': (context) => const EditProfileScreen(),
        '/about': (context) => const AboutScreen(),
        '/tracker': (context) {
          final args = ModalRoute.of(context)!.settings.arguments as Map?;
          return TrackerScreen(deviceId: args?['id'] as String, userRole: args?['userRole'] as String, deviceName: args?['name'] as String, lat: args?['lat'] as double, lng: args?['lng'] as double);
        },
        // Deep-links into the Logs tab pre-filtered by device/category —
        // equivalent of router.push('/logs', { targetDevice, targetCategory })
        '/logs-filtered': (context) {
          final args = ModalRoute.of(context)!.settings.arguments as Map?;
          return LogsScreen(
            initialTargetDevice: args?['targetDevice'] as String?,
            initialTargetCategory: args?['targetCategory'] as String?,
          );
        },
        '/device-settings': (context) {
          final args = ModalRoute.of(context)!.settings.arguments as Map?;
          return DeviceSettingsScreen(
            id: args?['id'] as String,
            name: args?['name'] as String,
            lat: args?['lat'] as double,
            lng: args?['lng'] as double,
          );
        },
        '/geofence-editor': (context) {
          final args = ModalRoute.of(context)!.settings.arguments as Map?;
          return GeofenceEditorScreen(
            deviceId: args?['id'] as String,
            deviceName: args?['name'] as String,
            lat: args?['lat'] as double,
            lng: args?['lng'] as double,
          );
        },
      },
    );
  }
}
