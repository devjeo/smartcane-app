SmartCane update pack (lib + pubspec + android notes)
=====================================================
1. Copy the "lib" folder over your project's lib folder (overwrite).
   Based on the lib.zip you sent earlier; if you edited those files since, tell me.
2. Replace your project's pubspec.yaml with the one here (only change: 3 new packages
   under wakelock_plus), then run:  flutter pub get
3. Replace android/app/src/main/AndroidManifest.xml with the one here (your own file with
   4 permissions added: CALL_PHONE, READ_PHONE_STATE, SEND_SMS, SYSTEM_ALERT_WINDOW).
4. Call SosLadderRunner.ensurePermissions() once from the main app (e.g. after a solo
   cane is paired) so Android shows the Phone / SMS / Display-over-apps prompts.

Changed files:
  NEW      lib/services/sos_ladder_runner.dart
  NEW      lib/services/emergency_contacts_service.dart
  NEW      lib/screens/emergency_contacts/emergency_contacts_screen.dart
  CHANGED  lib/main.dart  (route '/emergency-contacts')
  CHANGED  lib/screens/settings/settings_screen.dart  (Settings > Emergency > Emergency contacts)
  CHANGED  lib/services/background_location_service.dart
           lib/services/call_ring_service.dart
           lib/services/push_notification_service.dart
           lib/services/supabase_service.dart
           lib/models/device_model.dart
           lib/screens/add_device/add_device_screen.dart
           lib/screens/add_device/device_provisioning_service.dart
           lib/screens/tracker/tracker_screen.dart
  CHANGED  pubspec.yaml
  CHANGED  android/app/src/main/AndroidManifest.xml
The Supabase files (SQL + Edge Function) are sent separately, not in this zip.
