import 'dart:math' as math;
import '../models/geo_point.dart';

// Pure Dart (no Flutter): used by the route editor now and by the
// navigation engine / background service later.

const double _earthRadiusM = 6371000.0;
const double _metersPerDegree = 111320.0;

double _rad(double deg) => deg * math.pi / 180.0;
double _deg(double rad) => rad * 180.0 / math.pi;

/// Great-circle distance in metres.
double distanceM(GeoPoint a, GeoPoint b) {
  final dLat = _rad(b.lat - a.lat);
  final dLng = _rad(b.lng - a.lng);
  final sLat = math.sin(dLat / 2);
  final sLng = math.sin(dLng / 2);
  final h = sLat * sLat + math.cos(_rad(a.lat)) * math.cos(_rad(b.lat)) * sLng * sLng;
  return 2 * _earthRadiusM * math.asin(math.min(1.0, math.sqrt(h)));
}

/// Compass bearing from [a] to [b], 0..360 (0 = north, 90 = east).
double bearingDeg(GeoPoint a, GeoPoint b) {
  final p1 = _rad(a.lat);
  final p2 = _rad(b.lat);
  final dl = _rad(b.lng - a.lng);
  final y = math.sin(dl) * math.cos(p2);
  final x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
  return (_deg(math.atan2(y, x)) + 360.0) % 360.0;
}

/// Signed turn from bearing [from] to bearing [to], in [-180, 180).
/// Positive = clockwise = a turn to the RIGHT, negative = LEFT.
double angleDiffDeg(double from, double to) => ((to - from + 540.0) % 360.0) - 180.0;

/// Distance from the start of the path to each vertex (first value is 0).
List<double> cumulativeDistances(List<GeoPoint> path) {
  final out = <double>[0.0];
  for (var i = 1; i < path.length; i++) {
    out.add(out[i - 1] + distanceM(path[i - 1], path[i]));
  }
  return out;
}

/// Shortest distance in metres from [p] to the segment [a]-[b].
double segmentDistanceM(GeoPoint p, GeoPoint a, GeoPoint b) {
  final k = math.cos(_rad(a.lat)) * _metersPerDegree;
  final bx = (b.lng - a.lng) * k;
  final by = (b.lat - a.lat) * _metersPerDegree;
  final px = (p.lng - a.lng) * k;
  final py = (p.lat - a.lat) * _metersPerDegree;
  final len2 = bx * bx + by * by;
  var t = len2 == 0 ? 0.0 : (px * bx + py * by) / len2;
  if (t < 0.0) t = 0.0;
  if (t > 1.0) t = 1.0;
  final dx = px - bx * t;
  final dy = py - by * t;
  return math.sqrt(dx * dx + dy * dy);
}

class _Span {
  final int start;
  final int end;
  const _Span(this.start, this.end);
}

/// Douglas-Peucker: drops points that lie within [toleranceM] of the line
/// through their neighbours. Keeps the first and last point.
List<GeoPoint> simplifyPath(List<GeoPoint> pts, double toleranceM) {
  if (pts.length < 3) return List<GeoPoint>.of(pts);
  final keep = List<bool>.filled(pts.length, false);
  keep[0] = true;
  keep[pts.length - 1] = true;
  final stack = <_Span>[_Span(0, pts.length - 1)];
  while (stack.isNotEmpty) {
    final span = stack.removeLast();
    var maxD = 0.0;
    var idx = -1;
    for (var i = span.start + 1; i < span.end; i++) {
      final d = segmentDistanceM(pts[i], pts[span.start], pts[span.end]);
      if (d > maxD) {
        maxD = d;
        idx = i;
      }
    }
    if (idx != -1 && maxD > toleranceM) {
      keep[idx] = true;
      stack.add(_Span(span.start, idx));
      stack.add(_Span(idx, span.end));
    }
  }
  return [
    for (var i = 0; i < pts.length; i++)
      if (keep[i]) pts[i],
  ];
}
