import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../models/device_model.dart';
import '../models/log_model.dart';

/// Central place for every Supabase call used by the three tabs.
/// Equivalent of `import { supabase } from '../../utils/supabase'` plus
/// all the inline query logic that lived inside each screen in the RN app.
class SupabaseService {
  SupabaseService._();
  static final SupabaseService instance = SupabaseService._();

  SupabaseClient get _client => Supabase.instance.client;

  // ⚠️ Same key that was hardcoded client-side in index.tsx. Exactly like the
  // RN version, this ships inside the app bundle — consider proxying this
  // through a Supabase Edge Function so the key isn't exposed to end users.
  static const _googleApiKey = 'AIzaSyCB-2TjrRCG8954qyGBDp_DjrFJh1hKkw4';

  User? get currentUser => _client.auth.currentUser;

  // ---------- Dashboard (index.tsx) ----------

  /// Equivalent of `fetchDevices()` in index.tsx: pulls every device shared
  /// with the current user, then reverse-geocodes each device's lat/lng.
  Future<List<DeviceModel>> fetchDevices() async {
    final user = currentUser;
    if (user == null) {
      throw Exception('Not authenticated');
    }

    // Alerts on the device card only reflect the last 24h — logs older
    // than that are excluded from the count entirely.
    final cutoff = DateTime.now().subtract(const Duration(days: 1)).toIso8601String();

    final data = await _client
        .from('device_shares')
        .select('''
          role,
          devices!inner (
            id,
            name,
            latitude,
            longitude,
            battery_level,
            activity_status,
            is_online,
            last_updated,
            guardian_id,
            logs (count),
            profiles (
              id,
              full_name
            )
          )
        ''')
        .eq('user_id', user.id)
        .not('devices.guardian_id', 'is', null)
        .gte('devices.logs.created_at', cutoff);

    final rows = List<Map<String, dynamic>>.from(data as List);

    final devices = await Future.wait(rows.map((row) async {
      final d = row['devices'] as Map<String, dynamic>;
      final lat = (d['latitude'] as num?)?.toDouble() ?? 13.1391;
      final lng = (d['longitude'] as num?)?.toDouble() ?? 123.7438;
      final address = await _reverseGeocode(lat, lng);
      return DeviceModel.fromShareRow(row, exactAddress: address);
    }));

    return devices;
  }

  /// Equivalent of the Google Geocoding `fetch()` call in index.tsx.
  Future<String> _reverseGeocode(double lat, double lng) async {
    try {
      final uri = Uri.parse(
        'https://maps.googleapis.com/maps/api/geocode/json'
        '?latlng=$lat,$lng&key=$_googleApiKey',
      );
      final response = await http.get(uri);
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final results = data['results'] as List?;

      if (results != null && results.isNotEmpty) {
        final components = results[0]['address_components'] as List;
        if (components.length > 3) {
          return '${components[2]['long_name']}, ${components[3]['long_name']}';
        }
        return 'Address not found';
      }
      return 'Address not found';
    } catch (_) {
      return 'Location unavailable';
    }
  }

  // ---------- Logs tab (logs.tsx) ----------

  /// Equivalent of `fetchLogs()` in logs.tsx.
  Future<List<LogModel>> fetchLogs() async {
    final user = currentUser;
    List<String> deviceIds = [];

    if (user != null) {
      // Use device_shares, same as fetchDevices(), so shared devices
      // (like the cane, TSC-4236) are included too — not just devices
      // where you are the guardian_id.
      final sharesData = await _client
          .from('device_shares')
          .select('devices!inner(id)')
          .eq('user_id', user.id);

      deviceIds = List<Map<String, dynamic>>.from(sharesData as List)
          .map((row) =>
              (row['devices'] as Map<String, dynamic>)['id'].toString())
          .toList();
    }

    print('Fetching logs for devices: $deviceIds');

    // Logs older than 24h are hidden entirely — both from this list and
    // from the alert count used on the dashboard's device cards.
    final cutoff = DateTime.now().subtract(const Duration(days: 1)).toIso8601String();
    print(cutoff);

    final data = await _client
        .from('logs')
        .select('*')
        .inFilter('device_id', deviceIds.isNotEmpty ? deviceIds : ['dummy'])
        .gte('created_at', cutoff)
        .order('created_at', ascending: false);

    print('Fetched logs data: $data');

    return List<Map<String, dynamic>>.from(data as List)
        .map(LogModel.fromRow)
        .toList();
  }

  /// Subscribes to new INSERTs on `logs`, same as the `live-logs-page` channel.
  RealtimeChannel subscribeToLogs(void Function() onInsert) {
    return _client
        .channel('live-logs-page')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'logs',
          callback: (payload) => onInsert(),
        )
        .subscribe();
  }

  void unsubscribe(RealtimeChannel channel) {
    _client.removeChannel(channel);
  }

  // ---------- Settings tab (settings.tsx) ----------

  /// Equivalent of the profile load inside settings.tsx's useEffect.
  Future<Map<String, dynamic>?> fetchProfile() async {
    final user = currentUser;
    if (user == null) return null;

    final profile = await _client
        .from('profiles')
        .select('full_name, location')
        .eq('id', user.id)
        .maybeSingle();

    return profile == null
        ? null
        : {
            'email': user.email ?? '',
            'full_name': profile['full_name'] ?? 'Guardian',
            'location': profile['location'] ?? 'Location Not Set',
          };
  }

  /// Equivalent of handleLogout()'s supabase.auth.signOut() call.
  Future<void> signOut() async {
    await _client.auth.signOut();
  }

  /// Equivalent of saving the Expo push token to `profiles`, but for an FCM
  /// token. Rename the column in Supabase (or keep expo_push_token) to match.
  Future<void> savePushToken(String token) async {
    final user = currentUser;
    if (user == null) return;
    await _client
        .from('profiles')
        .update({'expo_push_token': token}).eq('id', user.id);
  }

  // ---------- Add Device Screen ----------

  /// Verifies a device exists and pairs it to the current user as an admin
  Future<void> pairDevice(String serial, String deviceName) async {
    final user = currentUser;
    if (user == null)
      throw Exception('You must be logged in to pair a device.');

    final deviceCheck = await _client
        .from('devices')
        .select('guardian_id')
        .eq('id', serial)
        .maybeSingle();

    if (deviceCheck == null) {
      throw Exception('Invalid Serial Number. This Smart Cane does not exist.');
    }

    await _client.from('devices').update({
      'guardian_id': user.id,
      'name': deviceName.isNotEmpty ? deviceName : 'My Smart Cane',
      'is_online': true,
    }).eq('id', serial);

    await _client.from('device_shares').insert({
      'device_id': serial,
      'user_id': user.id,
      'role': 'admin',
    });
  }

  /// Looks up a device by its 6-digit share code
  Future<Map<String, dynamic>?> getDeviceByShareCode(String code) async {
    return await _client
        .from('devices')
        .select('id, name')
        .eq('share_code', code)
        .maybeSingle();
  }

  /// Joins an existing device as a caregiver (viewer) and clears the share code
  Future<void> joinAsCaregiver(String deviceId) async {
    final user = currentUser;
    if (user == null) throw Exception('Not authenticated');

    await _client.from('device_shares').insert({
      'device_id': deviceId,
      'user_id': user.id,
      'role': 'viewer',
    });

    await _client
        .from('devices')
        .update({'share_code': null}).eq('id', deviceId);
  }

  // ---------- Device Settings Screen ----------

  /// Fetches just the light mode status for a specific device
  Future<bool> getDeviceLightMode(String deviceId) async {
    final data = await _client
        .from('devices')
        .select('light_mode')
        .eq('id', deviceId)
        .single();
    return data['light_mode'] ?? false;
  }

  /// Updates the light mode setting for a specific device
  Future<void> updateDeviceLightMode(String deviceId, bool isLightMode) async {
    await _client
        .from('devices')
        .update({'light_mode': isLightMode}).eq('id', deviceId);
  }

  /// Unpairs a device by removing the guardian_id
  Future<void> unpairDevice(String deviceId) async {
    await _client
        .from('devices')
        .update({'guardian_id': null}).eq('id', deviceId);
  }

  /// Generates and saves a new share code for a device
  Future<void> updateDeviceShareCode(String deviceId, String newCode) async {
    await _client
        .from('devices')
        .update({'share_code': newCode}).eq('id', deviceId);
  }

  // ---------- Edit Profile Screen ----------

  /// Fetches the complete profile row for the current user
  Future<Map<String, dynamic>?> getFullProfile() async {
    final user = currentUser;
    if (user == null) return null;
    return await _client
        .from('profiles')
        .select('*')
        .eq('id', user.id)
        .maybeSingle();
  }

  /// Updates the profile fields for the current user
  Future<void> updateFullProfile({
    required String fullName,
    required String phoneNumber,
    required String location,
    required String role,
  }) async {
    final user = currentUser;
    if (user == null) throw Exception('Not authenticated');

    await _client.from('profiles').update({
      'full_name': fullName,
      'phone_number': phoneNumber,
      'location': location,
      'role': role,
    }).eq('id', user.id);
  }

  /// Deletes the user's profile record and signs them out
  Future<void> deleteAccountData() async {
    final user = currentUser;
    if (user == null) throw Exception('Not authenticated');

    await _client.from('profiles').delete().eq('id', user.id);
    await _client.auth.signOut();
  }

  // ---------- Geofence Editor Screen ----------

  /// Fetches the saved polygon zones for a specific device.
  Future<List<dynamic>?> getGeofenceZones(String deviceId) async {
    final data = await _client
        .from('devices')
        .select('geofence_polygon')
        .eq('id', deviceId)
        .single();
    return data['geofence_polygon'] as List<dynamic>?;
  }

  /// Updates the geofence zones in the database for a specific device.
  Future<void> saveGeofenceZones(
      String deviceId, List<Map<String, dynamic>> polygonData) async {
    await _client
        .from('devices')
        .update({'geofence_polygon': polygonData}).eq('id', deviceId);
  }

  // ---------- Auth Screens (Login & Register) ----------

  /// Signs in a user with an email and password.
  Future<AuthResponse> signInWithPassword(String email, String password) async {
    return await _client.auth
        .signInWithPassword(email: email, password: password);
  }

  /// Registers a new user with an email, password, and their full name.
  Future<AuthResponse> signUp(
      String email, String password, String fullName) async {
    return await _client.auth.signUp(
      email: email,
      password: password,
      data: {'full_name': fullName},
    );
  }

  /// Triggers the Google OAuth flow for authentication.
  Future<void> signInWithGoogle() async {
    await _client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: 'io.supabase.smartcaneapp://login-callback/',
      authScreenLaunchMode: LaunchMode.externalApplication,
    );
  }

  // ---------- Tracker Screen ----------

  /// Fetches the live location and battery status of a device.
  Future<Map<String, dynamic>?> getDeviceLiveStatus(String deviceId) async {
    return await _client
        .from('devices')
        .select('latitude, longitude, battery_level, is_online, last_updated')
        .eq('id', deviceId)
        .maybeSingle();
  }

  /// Retrieves up to 2000 of the most recent location points for a device's history.
  Future<List<Map<String, dynamic>>> getDeviceLocationHistory(
      String deviceId) async {
    final data = await _client
        .from('location_history')
        .select('latitude, longitude, session_id, created_at')
        .eq('device_id', deviceId)
        .order('created_at', ascending: false)
        .limit(2000);
    return List<Map<String, dynamic>>.from(data);
  }

  /// Subscribes to realtime updates for a specific device's coordinates.
  RealtimeChannel subscribeToDeviceLocation(
      String deviceId, void Function(Map<String, dynamic>) onUpdate) {
    return _client
        .channel('device_tracker_$deviceId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'devices',
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq, column: 'id', value: deviceId),
          callback: (payload) => onUpdate(payload.newRecord),
        )
        .subscribe();
  }

  /// Checks if a device exists for the user and returns its ID.
  Future<String?> getLinkedDeviceId(String userId) async {
    // Calculate the exact time 3 minutes ago
    final cutoff = DateTime.now().subtract(const Duration(minutes: 3)).toIso8601String();

    final shareData = await _client
        .from('device_shares')
        .select('devices!inner(id, last_updated)')
        .eq('user_id', userId)
        // Ensure the device's last_updated timestamp is newer than the cutoff
        .gte('devices.last_updated', cutoff)
        .limit(1) 
        .maybeSingle();

    if (shareData != null) {
      final device = shareData['devices'] as Map<String, dynamic>;
      return device['id']?.toString();
    }

    return null; // Returns null if no device exists OR if the device is older than 3 mins
  }

  /// Inserts a new location ping into the history table
  Future<void> logLocationPing({
    required String deviceId,
    required double latitude,
    required double longitude,
  }) async {
    await _client.from('location_history').insert({
      'device_id': deviceId,
      'latitude': latitude,
      'longitude': longitude,
    });
  }
}