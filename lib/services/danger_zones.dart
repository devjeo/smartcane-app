import '../models/geo_point.dart';

/// The red "danger" polygons a guardian drew in the geofence editor
/// (`devices.geofence_polygon`, entries with type 'danger').
///
/// Pure Dart so the walking routes code and the background service can use it.
/// "Safe" zones are ignored on purpose.
class DangerZones {
  final List<List<GeoPoint>> polygons;
  const DangerZones(this.polygons);

  static const DangerZones none = DangerZones([]);

  bool get isEmpty => polygons.isEmpty;

  /// Reads the JSON stored in `devices.geofence_polygon`. Anything that does
  /// not look like a polygon is skipped instead of throwing.
  static DangerZones fromJson(dynamic raw) {
    final out = <List<GeoPoint>>[];
    if (raw is List) {
      for (final z in raw) {
        if (z is! Map) continue;
        if ((z['type'] ?? 'danger').toString() != 'danger') continue;
        final coords = z['coordinates'];
        if (coords is! List) continue;
        final pts = <GeoPoint>[];
        for (final c in coords) {
          if (c is Map && c['latitude'] is num && c['longitude'] is num) {
            pts.add(GeoPoint((c['latitude'] as num).toDouble(), (c['longitude'] as num).toDouble()));
          }
        }
        if (pts.length >= 3) out.add(pts);
      }
    }
    return DangerZones(out);
  }

  /// Is this point inside any danger zone?
  bool contains(GeoPoint p) => polygons.any((poly) => _inside(p, poly));

  /// Does the line touch any danger zone (a point inside it, or a segment
  /// crossing its edge)?
  ///
  /// A zone that already contains [origin] is skipped: someone who is
  /// standing inside a danger zone must still be able to get a route OUT of it.
  bool pathHits(List<GeoPoint> path, {GeoPoint? origin}) {
    if (path.isEmpty) return false;
    for (final poly in polygons) {
      if (origin != null && _inside(origin, poly)) continue;
      if (_pathTouches(path, poly)) return true;
    }
    return false;
  }

  static bool _pathTouches(List<GeoPoint> path, List<GeoPoint> poly) {
    for (final p in path) {
      if (_inside(p, poly)) return true;
    }
    for (var i = 1; i < path.length; i++) {
      final a = path[i - 1], b = path[i];
      for (var j = 0; j < poly.length; j++) {
        final c = poly[j], d = poly[(j + 1) % poly.length];
        if (_segmentsCross(a, b, c, d)) return true;
      }
    }
    return false;
  }

  // Ray casting; x = longitude, y = latitude (fine for areas this small).
  static bool _inside(GeoPoint p, List<GeoPoint> poly) {
    var inside = false;
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final yi = poly[i].lat, yj = poly[j].lat;
      final xi = poly[i].lng, xj = poly[j].lng;
      final crosses = (yi > p.lat) != (yj > p.lat) &&
          p.lng < (xj - xi) * (p.lat - yi) / (yj - yi) + xi;
      if (crosses) inside = !inside;
    }
    return inside;
  }

  static double _orient(GeoPoint a, GeoPoint b, GeoPoint c) =>
      (b.lng - a.lng) * (c.lat - a.lat) - (b.lat - a.lat) * (c.lng - a.lng);

  static bool _segmentsCross(GeoPoint a, GeoPoint b, GeoPoint c, GeoPoint d) {
    final o1 = _orient(a, b, c), o2 = _orient(a, b, d);
    final o3 = _orient(c, d, a), o4 = _orient(c, d, b);
    return ((o1 > 0 && o2 < 0) || (o1 < 0 && o2 > 0)) &&
        ((o3 > 0 && o4 < 0) || (o3 < 0 && o4 > 0));
  }
}
