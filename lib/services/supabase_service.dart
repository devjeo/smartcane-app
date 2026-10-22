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

    // Alerts on the device card only reflect the last 24h (UTC cutoff, see
    // recentLogCutoffIso). The Logs tab itself shows the full history.
    final cutoff = recentLogCutoffIso();

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
            last_seen_at,
            guardian_id,
            user_id,
            logs (count),
            guardian:profiles!devices_guardian_id_fkey (
              id,
              full_name
            ),
            cane_user:profiles!devices_user_id_fkey (
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
      final lat = (d['latitude'] as num?)?.toDouble();
      final lng = (d['longitude'] as num?)?.toDouble();
      final address = (lat == null || lng == null)
          ? 'Location not available yet'
          : await _reverseGeocode(lat, lng);
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

  /// Ids of the canes whose logs this account may read: guardian (admin),
  /// viewer and solo owner. A cane the account only CARRIES (role 'user')
  /// never feeds that person's Logs. A cane that is no longer paired (no
  /// guardian, or the share is gone) is left out, even though its old logs
  /// still exist in the database; same rule as Home.
  Future<List<String>> fetchLogDeviceIds() async {
    final user = currentUser;
    if (user == null) return [];
    final sharesData = await _client
        .from('device_shares')
        .select('devices!inner(id)')
        .eq('user_id', user.id)
        .inFilter('role', ['admin', 'viewer', 'owner'])
        .not('devices.guardian_id', 'is', null);
    return List<Map<String, dynamic>>.from(sharesData as List)
        .map((row) => (row['devices'] as Map<String, dynamic>)['id'].toString())
        .toSet()
        .toList();
  }

  /// One page of the FULL log history, newest first (no age limit).
  /// Pass [before] (the createdAt of the oldest log already loaded) to get
  /// the next, older page. The page can repeat logs that share [before]'s
  /// exact timestamp, so the caller drops duplicates by id.
  Future<List<LogModel>> fetchLogs({
    required List<String> deviceIds,
    DateTime? before,
    int limit = 100,
  }) async {
    if (deviceIds.isEmpty) return [];
    var query = _client.from('logs').select('*').inFilter('device_id', deviceIds);
    if (before != null) {
      query = query.lte('created_at', before.toUtc().toIso8601String());
    }
    final data = await query
        .order('created_at', ascending: false)
        .order('id', ascending: false)
        .limit(limit);
    return List<Map<String, dynamic>>.from(data as List)
        .map(LogModel.fromRow)
        .toList();
  }

  /// Temporary (1 h) link to an SOS photo in the private bucket. Allowed by
  /// the storage policy only for users that have a device_shares row.
  Future<String?> sosPhotoUrl(String path) async {
    try {
      return await _client.storage.from('sos-photos').createSignedUrl(path, 3600);
    } catch (_) {
      return null;
    }
  }

  /// Subscribes to INSERTs *and* UPDATEs on `logs`: the SOS photo and phone
  /// location are attached to the row a moment after it is created.
  RealtimeChannel subscribeToLogs(void Function() onInsert) {
    return _client
        .channel('live-logs-page')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
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
    // Forget this phone's push token so the next person who logs in on it
    // (or nobody) gets the alerts, not the account that just signed out.
    final user = currentUser;
    if (user != null) {
      try {
        // Phase 8: the push token column is hidden from the app, so it is
        // cleared through the server function (null = forget this phone).
        await _client.rpc('save_push_token', params: {'p_token': null});
      } catch (_) {}
    }
    await _client.auth.signOut();
  }

  /// Saves this phone's FCM token on the current user's profile (column
  /// `expo_push_token` is just reused for FCM). The `save_push_token` SQL
  /// function also removes the same token from any other account.
  Future<void> savePushToken(String token) async {
    if (currentUser == null) return;
    await _client.rpc('save_push_token', params: {'p_token': token});
  }

  // ---------- Add Device Screen ----------

  /// Verifies a device exists and pairs it to the current user as an admin
  Future<void> pairDevice(String serial, String deviceName) async {
    // Phase 8: closed on purpose. Taking a cane by its serial number let anyone
    // grab a cane that had no guardian. A cane is now claimed only through the
    // QR code (create_pairing_token -> claim_device_with_token).
    throw Exception('Pairing by serial number is no longer supported. Use the QR code.');
  }

  // ---------- QR pairing (matches cane_boot.py on the Raspberry Pi) ----------

  /// Asks Supabase for a single-use pairing token for the logged-in user.
  /// The token goes into the QR code the cane scans; the cane later trades it
  /// (claim_device_with_token) to attach itself to this account, so the user
  /// id never has to be put in the QR.
  Future<String> createPairingToken(String deviceName, {bool solo = false}) async {
    final user = currentUser;
    if (user == null) {
      throw Exception('You must be logged in to pair a device.');
    }
    final res = await _client.rpc('create_pairing_token', params: {
      'p_device_name': deviceName,
      'p_solo': solo,
    });
    final token = res is Map ? res['token'] : res;
    if (token is! String || token.isEmpty) {
      throw Exception('Could not create a setup code. Please try again.');
    }
    return token;
  }

  /// Has the cane claimed this token yet? Returns a map with `claimed`,
  /// `expired` and (once claimed) `device_id`; an empty map if the server
  /// sent nothing usable.
  Future<Map<String, dynamic>> pairingTokenStatus(String token) async {
    final res = await _client.rpc('pairing_token_status', params: {
      'p_token': token,
    });
    final row = res is List ? (res.isEmpty ? null : res.first) : res;
    return row is Map ? Map<String, dynamic>.from(row) : <String, dynamic>{};
  }

  // ---------- Roles: link a cane user (Phase 1 SQL functions) ----------

  /// The future USER's phone asks for a single-use token (valid 5 min).
  /// It goes into the QR the guardian scans.
  Future<String> createUserLinkToken() async {
    final res = await _client.rpc('create_user_link_token');
    final token = res is Map ? res['token'] : res;
    if (token is! String || token.isEmpty) {
      throw Exception('Could not create a link code. Please try again.');
    }
    return token;
  }

  /// Polled by the user's phone: `claimed`, `expired`, `device_id`, `device_name`.
  Future<Map<String, dynamic>> userLinkStatus(String token) async {
    final res = await _client.rpc('user_link_status', params: {'p_token': token});
    final row = res is List ? (res.isEmpty ? null : res.first) : res;
    return row is Map ? Map<String, dynamic>.from(row) : <String, dynamic>{};
  }

  /// Guardian side, after scanning the user's QR.
  Future<Map<String, dynamic>> claimUserLink(String deviceId, String token) async {
    final res = await _client.rpc('claim_user_link', params: {
      'p_device_id': deviceId,
      'p_token': token,
    });
    final row = res is List ? (res.isEmpty ? null : res.first) : res;
    return row is Map ? Map<String, dynamic>.from(row) : <String, dynamic>{};
  }

  Future<void> swapGuardianUser(String deviceId) async {
    await _client.rpc('swap_guardian_user', params: {'p_device_id': deviceId});
  }

  Future<void> unlinkUser(String deviceId) async {
    await _client.rpc('unlink_user', params: {'p_device_id': deviceId});
  }

  /// Raw share roles ('admin' | 'user' | 'viewer') of every active cane the
  /// account has. Drives which tabs the home screen shows.
  Future<List<String>> fetchMyShareRoles() async {
    final user = currentUser;
    if (user == null) return [];
    final data = await _client
        .from('device_shares')
        .select('role, devices!inner (guardian_id)')
        .eq('user_id', user.id)
        .not('devices.guardian_id', 'is', null);
    // 'owner' (solo user) acts as both guardian and cane user.
    return (data as List).expand((r) {
      final role = (r as Map)['role'].toString();
      return role == 'owner' ? const ['admin', 'user'] : [role];
    }).toList();
  }

  /// Canes the current account carries (share role 'user'):
  /// `{id, name, battery_level, last_seen_at, guardian: {full_name}}`.
  Future<List<Map<String, dynamic>>> fetchMyUserCanes() async {
    final user = currentUser;
    if (user == null) return [];
    final data = await _client
        .from('device_shares')
        .select('''
          devices!inner (
            id,
            name,
            battery_level,
            last_seen_at,
            guardian_id,
            guardian:profiles!devices_guardian_id_fkey (full_name)
          )
        ''')
        .eq('user_id', user.id)
        .inFilter('role', ['user', 'owner'])
        .not('devices.guardian_id', 'is', null);
    return (data as List)
        .map((r) => Map<String, dynamic>.from((r as Map)['devices'] as Map))
        .toList();
  }

  /// Current cane user of a device: `{user_id, cane_user: {id, full_name}}`
  /// (`user_id` is null when nobody is linked). Used by Device Settings.
  Future<Map<String, dynamic>?> fetchCaneUser(String deviceId) async {
    final row = await _client
        .from('devices')
        .select('user_id, guardian_id, cane_user:profiles!devices_user_id_fkey (id, full_name)')
        .eq('id', deviceId)
        .maybeSingle();
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  /// Joins a cane as a caregiver (viewer) with its share code, in ONE server
  /// call (join_device_by_code). The server checks the code, limits wrong
  /// guesses and clears the code after use. Returns
  /// `{ok: true, device_id, name}` or `{ok: false, reason}` where reason is
  /// `invalid_code`, `rate_limited` or `already_linked`.
  Future<Map<String, dynamic>> joinByShareCode(String code) async {
    final res = await _client.rpc('join_device_by_code', params: {
      'p_code': code,
    });
    final row = res is List ? (res.isEmpty ? null : res.first) : res;
    return row is Map ? Map<String, dynamic>.from(row) : <String, dynamic>{};
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

  /// Unpairs a device (server function unpair_device: guardian only). It also
  /// removes every share, the cane's secret and the share code, so the cane
  /// must be paired again with a QR code.
  Future<void> unpairDevice(String deviceId) async {
    await _client.rpc('unpair_device', params: {'p_device_id': deviceId});
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
        .select('id, full_name, phone_number, location, role, email')
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
    final res = await _client.auth
        .signInWithPassword(email: email, password: password);

    // One phone per account: end every other session of this account.
    // The session on this phone stays valid.
    try {
      await _client.auth.signOut(scope: SignOutScope.others);
    } catch (_) {
      // Never block a login because the cleanup failed.
    }
    return res;
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
        .select('latitude, longitude, battery_level, last_seen_at, last_updated, activity_status')
        .eq('id', deviceId)
        .maybeSingle();
  }

  /// Cheap status poll for the dashboard: just each device's last heartbeat.
  Future<Map<String, DateTime?>> fetchLastSeen(List<String> ids) async {
    if (ids.isEmpty) return {};
    final data = await _client
        .from('devices')
        .select('id, last_seen_at')
        .inFilter('id', ids);
    return {
      for (final row in List<Map<String, dynamic>>.from(data))
        row['id'].toString(): row['last_seen_at'] != null
            ? DateTime.tryParse(row['last_seen_at'] as String)
            : null,
    };
  }

  /// What Home shows for [ids], counting only logs the guardian has NOT yet
  /// seen on the Logs tab ([readIds], see LogReadStore):
  ///  - counts: unread logs per device in the last 24 h (the alert badge)
  ///  - sosIds: devices with an unread SOS from the last 30 minutes
  Future<({Map<String, int> counts, Set<String> sosIds})> fetchUnreadSummary(
    List<String> ids,
    Set<String> readIds,
  ) async {
    if (ids.isEmpty) return (counts: <String, int>{}, sosIds: <String>{});
    final now = DateTime.now();
    final cutoff = recentLogCutoffIso();
    final sosCutoff = now.subtract(const Duration(minutes: 30));
    final data = await _client
        .from('logs')
        .select('id, device_id, alert_type, created_at')
        .inFilter('device_id', ids)
        .gte('created_at', cutoff);

    final counts = <String, int>{};
    final sosIds = <String>{};
    for (final row in List<Map<String, dynamic>>.from(data as List)) {
      if (readIds.contains(row['id'].toString())) continue;
      final deviceId = row['device_id'].toString();
      counts[deviceId] = (counts[deviceId] ?? 0) + 1;
      if (row['alert_type'] == 'sos') {
        final at = DateTime.tryParse(row['created_at']?.toString() ?? '');
        if (at != null && at.isAfter(sosCutoff)) sosIds.add(deviceId);
      }
    }
    return (counts: counts, sosIds: sosIds);
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

  /// Returns the id of the user's cane ONLY if it is online right now, else null.
  /// "Online" is decided on the server (my_online_device_id, see 02_online_check.sql):
  /// is_online = true AND a heartbeat within [DeviceModel.onlineWindow]. Doing it
  /// server-side means a wrong clock on the phone can't break the check.
  /// [userId] is unused (the server uses the signed-in user); kept so callers don't change.
  Future<String?> getLinkedDeviceId(String userId) async {
    final res = await _client.rpc('my_online_device_id', params: {
      'p_window_seconds': DeviceModel.onlineWindow.inSeconds,
    });
    if (res is String && res.isNotEmpty) {
      print('=== BACKGROUND TRACKING: cane online ($res) ===');
      return res;
    }
    return null; // cane offline, unpaired, or none
  }

  /// Inserts a new location ping into the history table
  /// Newest phone location ping per cane (location_history.created_at).
  /// Only the cane USER's phone writes these, so this is a "is the user's
  /// phone alive and reporting" signal. Missing key = no ping on record.
  Future<Map<String, DateTime>> fetchLastPhonePings(List<String> deviceIds) async {
    final out = <String, DateTime>{};
    await Future.wait(deviceIds.map((id) async {
      try {
        final rows = await _client
            .from('location_history')
            .select('created_at')
            .eq('device_id', id)
            .order('created_at', ascending: false)
            .limit(1);
        if ((rows as List).isNotEmpty) {
          final t = DateTime.tryParse(rows.first['created_at'] as String);
          if (t != null) out[id] = t.toLocal();
        }
      } catch (_) {}
    }));
    return out;
  }

  /// Set after the server told us `location_history.accuracy` does not exist
  /// yet (migration not applied): pings are then sent without it instead of
  /// failing.
  bool _accuracyColumnMissing = false;

  /// Inserts a location ping into the history table.
  /// [accuracy] is the (smoothed) error radius in metres; it needs the
  /// `accuracy` column from sql/01_location_accuracy.sql.
  Future<void> logLocationPing({
    required String deviceId,
    required String sessionId,
    required double latitude,
    required double longitude,
    double? accuracy,
  }) async {
    final row = <String, dynamic>{
      'device_id': deviceId,
      'latitude': latitude,
      'longitude': longitude,
      'session_id': sessionId,
    };
    if (accuracy != null && !_accuracyColumnMissing) {
      row['accuracy'] = double.parse(accuracy.toStringAsFixed(1));
    }
    try {
      await _client.from('location_history').insert(row);
    } on PostgrestException catch (e) {
      // PGRST204 / 42703 = unknown column. Retry once without it.
      final missing = e.code == 'PGRST204' ||
          e.code == '42703' ||
          e.message.contains('accuracy');
      if (row.containsKey('accuracy') && missing) {
        _accuracyColumnMissing = true;
        row.remove('accuracy');
        await _client.from('location_history').insert(row);
      } else {
        rethrow;
      }
    }
  }

  // ---------- Live mode (guardian is watching) ----------
  // Needs sql/01_location_accuracy.sql. Both calls fail soft: if the SQL is
  // not applied or RLS denies it, live mode simply never turns on and the
  // normal movement-driven sending keeps working.

  /// Guardian side: "I am watching this cane live for the next [seconds]".
  /// The expiry is computed by the server clock, so phone clocks cannot
  /// disagree.
  Future<void> setLiveWatch(String deviceId, {int seconds = 90}) async {
    try {
      await _client.rpc('set_live_watch',
          params: {'p_device_id': deviceId, 'p_seconds': seconds});
    } catch (_) {}
  }

  /// Cane phone side: is a guardian watching live right now?
  Future<bool> isLiveWatchActive(String deviceId) async {
    try {
      final res = await _client
          .rpc('device_live_watch_active', params: {'p_device_id': deviceId});
      return res == true;
    } catch (_) {
      return false;
    }
  }
}
