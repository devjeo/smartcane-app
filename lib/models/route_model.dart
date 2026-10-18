import 'geo_point.dart';

/// Turn vocabulary. The same names are produced by Google (through the
/// route-tools Edge Function) and by [TurnBuilder] for hand-drawn paths.
class Maneuver {
  Maneuver._();
  static const depart = 'DEPART';
  static const straight = 'STRAIGHT';
  static const slightLeft = 'TURN_SLIGHT_LEFT';
  static const left = 'TURN_LEFT';
  static const sharpLeft = 'TURN_SHARP_LEFT';
  static const slightRight = 'TURN_SLIGHT_RIGHT';
  static const right = 'TURN_RIGHT';
  static const sharpRight = 'TURN_SHARP_RIGHT';
  static const uTurnLeft = 'UTURN_LEFT';
  static const uTurnRight = 'UTURN_RIGHT';
  static const arrive = 'ARRIVE';
}

String formatDistance(int m) =>
    m < 1000 ? '$m m' : '${(m / 1000).toStringAsFixed(1)} km';

String formatDuration(int s) {
  final min = (s / 60).round();
  if (min < 1) return '1 min';
  if (min < 60) return '$min min';
  final h = min ~/ 60;
  final r = min % 60;
  return r == 0 ? '$h h' : '$h h $r min';
}

/// One instruction. The maneuver happens at the START of the step
/// ([lat],[lng], vertex [pathIndex] of the path); [distM] is how far to walk
/// until the next step.
class RouteStep {
  final String text;
  final String maneuver;
  final int distM;
  final double lat;
  final double lng;
  final int pathIndex;

  const RouteStep({
    required this.text,
    required this.maneuver,
    required this.distM,
    required this.lat,
    required this.lng,
    required this.pathIndex,
  });

  GeoPoint get point => GeoPoint(lat, lng);
  bool get isArrival => maneuver == Maneuver.arrive;

  Map<String, dynamic> toJson() => {
        'text': text,
        'maneuver': maneuver,
        'dist_m': distM,
        'lat': lat,
        'lng': lng,
        'path_index': pathIndex,
      };

  factory RouteStep.fromJson(Map<String, dynamic> j) => RouteStep(
        text: (j['text'] ?? '').toString(),
        maneuver: (j['maneuver'] ?? Maneuver.straight).toString(),
        distM: (j['dist_m'] as num?)?.round() ?? 0,
        lat: (j['lat'] as num).toDouble(),
        lng: (j['lng'] as num).toDouble(),
        pathIndex: (j['path_index'] as num?)?.toInt() ?? 0,
      );
}

List<GeoPoint> _points(dynamic v) =>
    v is List ? v.map(GeoPoint.fromJson).toList() : <GeoPoint>[];

DateTime? _dt(dynamic v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;

/// A saved route (`public.routes`).
class RouteModel {
  final String id;
  final String deviceId;
  final String? createdBy;
  final String name;
  final GeoPoint start;
  final GeoPoint end;
  final String startLabel;
  final String endLabel;
  final List<GeoPoint> waypoints; // points the guardian chose
  final List<GeoPoint> path; // the full line to follow
  final List<RouteStep> steps;
  final int distanceM;
  final int durationS;
  final String source; // 'google' | 'drawn' | 'destination'
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const RouteModel({
    required this.id,
    required this.deviceId,
    required this.createdBy,
    required this.name,
    required this.start,
    required this.end,
    required this.startLabel,
    required this.endLabel,
    required this.waypoints,
    required this.path,
    required this.steps,
    required this.distanceM,
    required this.durationS,
    required this.source,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Lists load WITHOUT the heavy path/steps; [hasGeometry] tells you whether
  /// this instance has them (use `RouteService.fetchRoute` for the full one).
  bool get hasGeometry => path.length >= 2;
  bool get isDrawn => source == 'drawn';

  /// Only a destination is saved; the path is planned from wherever the cane
  /// user is when the walk starts.
  bool get isDestination => source == 'destination';
  String get distanceText => formatDistance(distanceM);
  String get durationText => formatDuration(durationS);

  /// "1.2 km - 15 min", or a hint when nothing is planned yet.
  String get summaryText =>
      isDestination ? 'Planned when the walk starts' : '$distanceText  -  $durationText';

  static const listColumns =
      'id, device_id, created_by, name, start_lat, start_lng, start_label, '
      'end_lat, end_lng, end_label, distance_m, duration_s, source, status, '
      'created_at, updated_at';
  static const fullColumns = '$listColumns, waypoints, path, steps';

  factory RouteModel.fromRow(Map<String, dynamic> r) => RouteModel(
        id: r['id'].toString(),
        deviceId: r['device_id'].toString(),
        createdBy: r['created_by']?.toString(),
        name: (r['name'] ?? '').toString(),
        // A destination-only route has no start: fall back to the destination
        // so nothing that reads [start] can crash.
        start: GeoPoint(
          ((r['start_lat'] ?? r['end_lat']) as num).toDouble(),
          ((r['start_lng'] ?? r['end_lng']) as num).toDouble(),
        ),
        end: GeoPoint((r['end_lat'] as num).toDouble(), (r['end_lng'] as num).toDouble()),
        startLabel: (r['start_label'] ?? '').toString(),
        endLabel: (r['end_label'] ?? '').toString(),
        waypoints: _points(r['waypoints']),
        path: _points(r['path']),
        steps: (r['steps'] is List)
            ? (r['steps'] as List)
                .map((s) => RouteStep.fromJson(Map<String, dynamic>.from(s as Map)))
                .toList()
            : <RouteStep>[],
        distanceM: (r['distance_m'] as num?)?.toInt() ?? 0,
        durationS: (r['duration_s'] as num?)?.toInt() ?? 0,
        source: (r['source'] ?? 'drawn').toString(),
        createdAt: _dt(r['created_at']),
        updatedAt: _dt(r['updated_at']),
      );
}

/// One walk (`public.route_sessions`).
class RouteSession {
  final String id;
  final String routeId;
  final String deviceId;
  final String startedBy;
  final String routeName;
  final int totalM;
  final String status; // active | completed | cancelled | expired
  final bool offRoute;
  final int progressM;
  final int currentStep;
  final double? lastLat;
  final double? lastLng;
  final DateTime lastUpdate;
  final DateTime startedAt;
  final DateTime? endedAt;

  const RouteSession({
    required this.id,
    required this.routeId,
    required this.deviceId,
    required this.startedBy,
    required this.routeName,
    required this.totalM,
    required this.status,
    required this.offRoute,
    required this.progressM,
    required this.currentStep,
    required this.lastLat,
    required this.lastLng,
    required this.lastUpdate,
    required this.startedAt,
    required this.endedAt,
  });

  bool get isActive => status == 'active';
  bool get hasPosition => lastLat != null && lastLng != null;
  GeoPoint? get lastPoint => hasPosition ? GeoPoint(lastLat!, lastLng!) : null;

  double get fraction =>
      totalM <= 0 ? 0.0 : (progressM / totalM).clamp(0.0, 1.0).toDouble();

  /// The phone has stopped reporting (it reports about every 5 s).
  bool get isStale =>
      isActive && DateTime.now().difference(lastUpdate) > const Duration(minutes: 2);

  factory RouteSession.fromRow(Map<String, dynamic> r) => RouteSession(
        id: r['id'].toString(),
        routeId: r['route_id'].toString(),
        deviceId: r['device_id'].toString(),
        startedBy: r['started_by'].toString(),
        routeName: (r['route_name'] ?? '').toString(),
        totalM: (r['total_m'] as num?)?.toInt() ?? 0,
        status: (r['status'] ?? 'active').toString(),
        offRoute: r['off_route'] == true,
        progressM: (r['progress_m'] as num?)?.toInt() ?? 0,
        currentStep: (r['current_step'] as num?)?.toInt() ?? 0,
        lastLat: (r['last_lat'] as num?)?.toDouble(),
        lastLng: (r['last_lng'] as num?)?.toDouble(),
        lastUpdate: _dt(r['last_update']) ?? DateTime.now(),
        startedAt: _dt(r['started_at']) ?? DateTime.now(),
        endedAt: _dt(r['ended_at']),
      );
}

// ---- results of the Google tools (route-tools Edge Function) --------------

class PlaceSuggestion {
  final String placeId;
  final String main;
  final String secondary;
  const PlaceSuggestion({required this.placeId, required this.main, required this.secondary});

  factory PlaceSuggestion.fromJson(Map<String, dynamic> j) => PlaceSuggestion(
        placeId: (j['place_id'] ?? '').toString(),
        main: (j['main'] ?? '').toString(),
        secondary: (j['secondary'] ?? '').toString(),
      );
}

class PlaceDetails {
  final String placeId;
  final String address;
  final double lat;
  final double lng;
  const PlaceDetails({
    required this.placeId,
    required this.address,
    required this.lat,
    required this.lng,
  });

  GeoPoint get point => GeoPoint(lat, lng);

  factory PlaceDetails.fromJson(Map<String, dynamic> j) => PlaceDetails(
        placeId: (j['place_id'] ?? '').toString(),
        address: (j['address'] ?? '').toString(),
        lat: (j['lat'] as num).toDouble(),
        lng: (j['lng'] as num).toDouble(),
      );
}

/// A route proposed by Google, not saved yet.
class PlannedRoute {
  final int distanceM;
  final int durationS;
  final List<GeoPoint> path;
  final List<RouteStep> steps;
  final List<String> warnings;

  const PlannedRoute({
    required this.distanceM,
    required this.durationS,
    required this.path,
    required this.steps,
    required this.warnings,
  });

  String get distanceText => formatDistance(distanceM);
  String get durationText => formatDuration(durationS);

  factory PlannedRoute.fromJson(Map<String, dynamic> j) => PlannedRoute(
        distanceM: (j['distance_m'] as num?)?.toInt() ?? 0,
        durationS: (j['duration_s'] as num?)?.toInt() ?? 0,
        path: _points(j['path']),
        steps: ((j['steps'] as List?) ?? const [])
            .map((s) => RouteStep.fromJson(Map<String, dynamic>.from(s as Map)))
            .toList(),
        warnings: ((j['warnings'] as List?) ?? const []).map((e) => e.toString()).toList(),
      );
}

/// The line and steps of ONE walk (`public.route_session_plans`). For a
/// destination-only route this is the route Google planned when the walk
/// started; for an old route the walk uses the route's own path instead.
class WalkPlan {
  final List<GeoPoint> path;
  final List<RouteStep> steps;
  final int distanceM;
  final int durationS;
  final String endLabel;

  const WalkPlan({
    required this.path,
    required this.steps,
    required this.distanceM,
    required this.durationS,
    this.endLabel = '',
  });

  bool get hasPath => path.length >= 2;

  factory WalkPlan.fromRow(Map<String, dynamic> r, {String endLabel = ''}) => WalkPlan(
        path: _points(r['path']),
        steps: ((r['steps'] as List?) ?? const [])
            .map((s) => RouteStep.fromJson(Map<String, dynamic>.from(s as Map)))
            .toList(),
        distanceM: (r['distance_m'] as num?)?.toInt() ?? 0,
        durationS: (r['duration_s'] as num?)?.toInt() ?? 0,
        endLabel: endLabel,
      );
}
