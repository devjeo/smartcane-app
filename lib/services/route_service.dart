import 'dart:math' as math;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/geo_point.dart';
import '../models/route_model.dart';

/// Anything that goes wrong in the routes feature, with a message that is
/// safe to show to the person. [code] is a short machine-readable reason
/// (for example 'daily_limit', 'not_allowed', 'network', or a Postgres
/// error code such as '55006' = a walk is in progress).
class RouteException implements Exception {
  final String code;
  final String message;
  const RouteException(this.code, this.message);

  @override
  String toString() => message;
}

/// Everything the routes feature needs from Supabase:
///  * routes and walks (tables + the functions from 01_routes_phase1.sql)
///  * Google walking routes and place search, through the `route-tools`
///    Edge Function (the Google key never leaves the server).
///
/// Pure Supabase calls, so it also works inside the background service
/// isolate once Supabase is initialised there.
class RouteService {
  RouteService._();
  static final RouteService instance = RouteService._();

  SupabaseClient get _client => Supabase.instance.client;

  // ---------------------------------------------------------------------
  // Routes
  // ---------------------------------------------------------------------

  /// Active routes of a cane, newest first, WITHOUT path/steps (light).
  Future<List<RouteModel>> fetchRoutes(String deviceId) async {
    try {
      final data = await _client
          .from('routes')
          .select(RouteModel.listColumns)
          .eq('device_id', deviceId)
          .eq('status', 'active')
          .order('created_at', ascending: false);
      return (data as List)
          .map((r) => RouteModel.fromRow(Map<String, dynamic>.from(r as Map)))
          .toList();
    } on PostgrestException catch (e) {
      throw RouteException(e.code ?? 'db', _dbMessage(e));
    }
  }

  /// One route with its full path and steps; null if it no longer exists.
  Future<RouteModel?> fetchRoute(String routeId) async {
    try {
      final row = await _client
          .from('routes')
          .select(RouteModel.fullColumns)
          .eq('id', routeId)
          .eq('status', 'active')
          .maybeSingle();
      return row == null ? null : RouteModel.fromRow(Map<String, dynamic>.from(row));
    } on PostgrestException catch (e) {
      throw RouteException(e.code ?? 'db', _dbMessage(e));
    }
  }

  /// Server-side answer to "may I create/edit/delete routes of this cane?"
  /// (guardian, solo owner, or the cane user when the guardian allows it).
  Future<bool> canManageRoutes(String deviceId) async {
    try {
      final res = await _client.rpc('can_manage_routes', params: {'p_device_id': deviceId});
      return res == true;
    } on PostgrestException {
      return false;
    }
  }

  Future<bool> fetchAllowUserRoutes(String deviceId) async {
    try {
      final row = await _client
          .from('devices')
          .select('allow_user_routes')
          .eq('id', deviceId)
          .maybeSingle();
      return row != null && row['allow_user_routes'] == true;
    } on PostgrestException {
      return false;
    }
  }

  /// Guardian only.
  Future<void> setAllowUserRoutes(String deviceId, bool allow) async {
    try {
      await _client.rpc('set_allow_user_routes',
          params: {'p_device_id': deviceId, 'p_allow': allow});
    } on PostgrestException catch (e) {
      throw RouteException(e.code ?? 'db', _dbMessage(e));
    }
  }

  /// Creates a route ([routeId] null) or updates one. Returns the route id.
  /// [source] is 'google' or 'drawn'.
  Future<String> saveRoute({
    required String deviceId,
    String? routeId,
    required String name,
    required GeoPoint start,
    String startLabel = '',
    required GeoPoint end,
    String endLabel = '',
    List<GeoPoint> waypoints = const [],
    required List<GeoPoint> path,
    required List<RouteStep> steps,
    required int distanceM,
    required int durationS,
    required String source,
  }) async {
    try {
      final res = await _client.rpc('save_route', params: {
        'p_device_id': deviceId,
        'p_route_id': routeId,
        'p_name': name.trim(),
        'p_start_lat': start.lat,
        'p_start_lng': start.lng,
        'p_start_label': startLabel,
        'p_end_lat': end.lat,
        'p_end_lng': end.lng,
        'p_end_label': endLabel,
        'p_waypoints': waypoints.map((p) => p.toJson()).toList(),
        'p_path': path.map((p) => p.toJson()).toList(),
        'p_steps': steps.map((s) => s.toJson()).toList(),
        'p_distance_m': distanceM,
        'p_duration_s': durationS,
        'p_source': source,
      });
      return res.toString();
    } on PostgrestException catch (e) {
      throw RouteException(e.code ?? 'db', _dbMessage(e));
    }
  }

  /// Creates or renames/moves a destination-only route. Returns the route id.
  Future<String> saveDestinationRoute({
    required String deviceId,
    String? routeId,
    required String name,
    required GeoPoint destination,
    String destinationLabel = '',
  }) async {
    try {
      final res = await _client.rpc('save_destination_route', params: {
        'p_device_id': deviceId,
        'p_route_id': routeId,
        'p_name': name.trim(),
        'p_end_lat': destination.lat,
        'p_end_lng': destination.lng,
        'p_end_label': destinationLabel,
      });
      return res.toString();
    } on PostgrestException catch (e) {
      throw RouteException(e.code ?? 'db', _dbMessage(e));
    }
  }

  /// Archives the route (it disappears from lists; walk history is kept).
  Future<void> deleteRoute(String routeId) async {
    try {
      await _client.rpc('delete_route', params: {'p_route_id': routeId});
    } on PostgrestException catch (e) {
      throw RouteException(e.code ?? 'db', _dbMessage(e));
    }
  }

  // ---------------------------------------------------------------------
  // Walks (route sessions)
  // ---------------------------------------------------------------------

  /// Starts a walk, or resumes your own unfinished walk of the same route.
  /// Returns the session id.
  Future<String> startSession(String routeId) async {
    try {
      final res = await _client.rpc('start_route_session', params: {'p_route_id': routeId});
      final row = res is List ? (res.isEmpty ? null : res.first) : res;
      final id = row is Map ? row['session_id'] : null;
      if (id == null) throw const RouteException('server_error', 'Could not start the walk.');
      return id.toString();
    } on PostgrestException catch (e) {
      throw RouteException(e.code ?? 'db', _dbMessage(e));
    }
  }

  /// Stores the route the phone planned for this walk (the first plan wins).
  Future<void> setSessionPlan({
    required String sessionId,
    required PlannedRoute plan,
    required GeoPoint origin,
  }) async {
    try {
      await _client.rpc('set_route_session_plan', params: {
        'p_session_id': sessionId,
        'p_path': plan.path.map((p) => p.toJson()).toList(),
        'p_steps': plan.steps.map((s) => s.toJson()).toList(),
        'p_distance_m': plan.distanceM,
        'p_duration_s': plan.durationS,
        'p_start_lat': origin.lat,
        'p_start_lng': origin.lng,
      });
    } on PostgrestException catch (e) {
      throw RouteException(e.code ?? 'db', _dbMessage(e));
    }
  }

  /// The route planned for one walk; null when this walk has none (old
  /// routes, or the plan is not saved yet).
  Future<WalkPlan?> fetchSessionPlan(String sessionId, {String endLabel = ''}) async {
    try {
      final row = await _client
          .from('route_session_plans')
          .select('path, steps, distance_m, duration_s')
          .eq('session_id', sessionId)
          .maybeSingle();
      return row == null
          ? null
          : WalkPlan.fromRow(Map<String, dynamic>.from(row), endLabel: endLabel);
    } on PostgrestException catch (e) {
      throw RouteException(e.code ?? 'db', _dbMessage(e));
    }
  }

  /// The line to show for a walk: its own plan when it has one, otherwise
  /// the path of the saved route. Null when neither is available (yet).
  Future<WalkPlan?> fetchWalkPlan(RouteSession s) async {
    final route = await fetchRoute(s.routeId);
    final label = route?.endLabel ?? '';
    final plan = await fetchSessionPlan(s.id, endLabel: label);
    if (plan != null && plan.hasPath) return plan;
    if (route != null && route.hasGeometry) {
      return WalkPlan(
        path: route.path,
        steps: route.steps,
        distanceM: route.distanceM,
        durationS: route.durationS,
        endLabel: label,
      );
    }
    return null;
  }

  /// Sends the phone's position (call about every 5 s while walking).
  /// Returns false when the server says the walk is no longer active.
  Future<bool> reportProgress({
    required String sessionId,
    required double lat,
    required double lng,
    required int progressM,
    required int step,
    required bool offRoute,
  }) async {
    try {
      final res = await _client.rpc('report_route_progress', params: {
        'p_session_id': sessionId,
        'p_lat': lat,
        'p_lng': lng,
        'p_progress_m': progressM,
        'p_step': step,
        'p_off_route': offRoute,
      });
      return res == 'ok';
    } on PostgrestException catch (e) {
      throw RouteException(e.code ?? 'db', _dbMessage(e));
    }
  }

  /// Finishes a walk: [completed] true = arrived, false = cancelled.
  Future<void> endSession(String sessionId, {required bool completed}) async {
    try {
      await _client.rpc('end_route_session', params: {
        'p_session_id': sessionId,
        'p_status': completed ? 'completed' : 'cancelled',
      });
    } on PostgrestException catch (e) {
      throw RouteException(e.code ?? 'db', _dbMessage(e));
    }
  }

  /// The walk in progress on a cane, if any (there is at most one).
  Future<RouteSession?> fetchActiveSession(String deviceId) async {
    try {
      final row = await _client
          .from('route_sessions')
          .select()
          .eq('device_id', deviceId)
          .eq('status', 'active')
          .maybeSingle();
      return row == null ? null : RouteSession.fromRow(Map<String, dynamic>.from(row));
    } on PostgrestException catch (e) {
      throw RouteException(e.code ?? 'db', _dbMessage(e));
    }
  }

  /// One walk by id (active or finished); null if it does not exist.
  Future<RouteSession?> fetchSession(String sessionId) async {
    try {
      final row = await _client
          .from('route_sessions')
          .select()
          .eq('id', sessionId)
          .maybeSingle();
      return row == null ? null : RouteSession.fromRow(Map<String, dynamic>.from(row));
    } on PostgrestException catch (e) {
      throw RouteException(e.code ?? 'db', _dbMessage(e));
    }
  }

  /// Past and current walks of a cane, newest first. Pass [routeId] to see
  /// only the walks of one route.
  Future<List<RouteSession>> fetchSessions(String deviceId,
      {String? routeId, int limit = 50}) async {
    try {
      var q = _client.from('route_sessions').select().eq('device_id', deviceId);
      if (routeId != null) q = q.eq('route_id', routeId);
      final data = await q.order('started_at', ascending: false).limit(limit);
      return (data as List)
          .map((r) => RouteSession.fromRow(Map<String, dynamic>.from(r as Map)))
          .toList();
    } on PostgrestException catch (e) {
      throw RouteException(e.code ?? 'db', _dbMessage(e));
    }
  }

  /// Live updates for a cane's walks (the guardian's map). [onChange] gets the
  /// new row, or null if it could not be read.
  RealtimeChannel subscribeToSessions(String deviceId, void Function(RouteSession?) onChange) {
    return _client
        .channel('route_sessions_$deviceId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'route_sessions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'device_id',
            value: deviceId,
          ),
          callback: (payload) {
            try {
              final rec = payload.newRecord;
              onChange(rec.isEmpty ? null : RouteSession.fromRow(Map<String, dynamic>.from(rec)));
            } catch (_) {
              onChange(null);
            }
          },
        )
        .subscribe();
  }

  void unsubscribe(RealtimeChannel channel) => _client.removeChannel(channel);

  // ---------------------------------------------------------------------
  // Google tools (through the route-tools Edge Function)
  // ---------------------------------------------------------------------

  /// A fresh id for one search session (typing + picking one place). Google
  /// bills a whole session as one when the same id is used for the typing
  /// and the final place lookup.
  static String newSessionToken() {
    final r = math.Random.secure();
    String hex(int n) =>
        List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-a${hex(3)}-${hex(12)}';
  }

  /// Place suggestions while typing. Call it only after a short pause and at
  /// least 3 characters; every call counts toward the daily limit.
  Future<List<PlaceSuggestion>> autocomplete({
    required String deviceId,
    required String input,
    String? sessionToken,
    GeoPoint? bias,
  }) async {
    final data = await _invoke({
      'action': 'autocomplete',
      'device_id': deviceId,
      'input': input,
      if (sessionToken != null) 'session_token': sessionToken,
      if (bias != null) 'bias': {'lat': bias.lat, 'lng': bias.lng},
    });
    return ((data['suggestions'] as List?) ?? const [])
        .map((s) => PlaceSuggestion.fromJson(Map<String, dynamic>.from(s as Map)))
        .toList();
  }

  /// Coordinates and address of a chosen suggestion.
  Future<PlaceDetails> placeDetails({
    required String deviceId,
    required String placeId,
    String? sessionToken,
  }) async {
    final data = await _invoke({
      'action': 'place',
      'device_id': deviceId,
      'place_id': placeId,
      if (sessionToken != null) 'session_token': sessionToken,
    });
    final place = data['place'];
    if (place is! Map) {
      throw const RouteException('server_error', 'That place could not be found.');
    }
    return PlaceDetails.fromJson(Map<String, dynamic>.from(place));
  }

  /// Walking route(s) from Google. [via] are points the route must pass
  /// through (max 8). Alternatives are only returned when [via] is empty.
  Future<List<PlannedRoute>> planWalkingRoute({
    required String deviceId,
    required GeoPoint origin,
    required GeoPoint destination,
    List<GeoPoint> via = const [],
    bool alternatives = false,
  }) async {
    final data = await _invoke({
      'action': 'route',
      'device_id': deviceId,
      'origin': {'lat': origin.lat, 'lng': origin.lng},
      'destination': {'lat': destination.lat, 'lng': destination.lng},
      'via': via.map((p) => {'lat': p.lat, 'lng': p.lng}).toList(),
      'alternatives': alternatives,
    });
    final routes = ((data['routes'] as List?) ?? const [])
        .map((r) => PlannedRoute.fromJson(Map<String, dynamic>.from(r as Map)))
        .where((r) => r.path.length >= 2)
        .toList();
    if (routes.isEmpty) {
      throw const RouteException(
          'no_route', 'Google found no walking route to that place from here.');
    }
    return routes;
  }

  Future<Map<String, dynamic>> _invoke(Map<String, dynamic> body) async {
    try {
      final res = await _client.functions.invoke('route-tools', body: body);
      final data = res.data;
      if (data is Map) return Map<String, dynamic>.from(data);
      throw const RouteException('server_error', 'Unexpected answer from the server.');
    } on RouteException {
      rethrow;
    } on FunctionException catch (e) {
      final d = e.details;
      final code = d is Map ? (d['error']?.toString() ?? 'server_error') : 'server_error';
      final msg = d is Map ? d['message']?.toString() : null;
      throw RouteException(code, _toolMessage(code, msg));
    } catch (_) {
      throw const RouteException(
          'network', 'No connection. Check your internet and try again.');
    }
  }

  String _toolMessage(String code, String? detail) {
    switch (code) {
      case 'daily_limit':
        return 'Daily map search limit reached. Try again tomorrow.';
      case 'not_allowed':
        return 'You are not allowed to do this for this cane.';
      case 'not_authenticated':
        return 'Please sign in again.';
      case 'too_far':
        return 'That walk is too long (over 30 km).';
      case 'google_error':
        return 'Google Maps could not complete the request'
            '${detail == null || detail.isEmpty ? '.' : ': $detail'}';
      case 'server_not_configured':
        return 'The map service is not set up yet.';
      default:
        return 'Something went wrong. Please try again.';
    }
  }

  String _dbMessage(PostgrestException e) {
    switch (e.code) {
      case '42501':
        return 'You are not allowed to do this.';
      case '28000':
        return 'Please sign in again.';
      default:
        return e.message.isEmpty ? 'Something went wrong. Please try again.' : e.message;
    }
  }
}
