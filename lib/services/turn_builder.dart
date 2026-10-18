import 'dart:math' as math;
import '../models/geo_point.dart';
import '../models/route_model.dart';
import 'geo_utils.dart';

/// A walkable route made from a line the guardian tapped on the map.
class BuiltRoute {
  final List<GeoPoint> path; // smoothed line; step.pathIndex points into this
  final List<RouteStep> steps;
  final int distanceM;
  final int durationS;
  const BuiltRoute({
    required this.path,
    required this.steps,
    required this.distanceM,
    required this.durationS,
  });
}

class _Turn {
  final int index;
  final double angle; // + = right, - = left
  const _Turn(this.index, this.angle);
}

/// Turns the points a guardian tapped into turn-by-turn steps, with no
/// routing service involved (this is the free, offline mode).
///
/// How it works:
///  1. drop taps closer than 2 m, then smooth tiny jitter (3 m tolerance);
///  2. at each vertex measure the change of direction between the path 20 m
///     behind and 20 m ahead; 30 degrees or more is a turn candidate;
///  3. neighbouring candidates on the same side within 25 m are one turn;
///  4. each turn is measured again over a wider span (up to 50 m, never
///     reaching into the neighbouring turns) so a curve reads as the real
///     angle, not just its tightest part.
/// Very gentle, wide curves (less than 30 degrees per 20 m) are not announced;
/// the walker simply follows the line.
class TurnBuilder {
  TurnBuilder._();

  /// Used for the walking-time estimate. 1.0 m/s is slow on purpose for a
  /// cane user (3.6 km/h).
  static const double walkingSpeedMps = 1.0;

  static const double _minSegmentM = 2.0;
  static const double _jitterM = 3.0;
  static const double _windowM = 20.0;
  static const double _minTurnDeg = 30.0;
  static const double _mergeM = 25.0;
  static const double _wideWindowM = 50.0;

  /// Throws [ArgumentError] when fewer than two different points were given.
  static BuiltRoute build(List<GeoPoint> tapped) {
    // 1. clean the taps
    final pts = <GeoPoint>[];
    for (final p in tapped) {
      if (pts.isEmpty || distanceM(pts.last, p) >= _minSegmentM) pts.add(p);
    }
    if (pts.length < 2) {
      throw ArgumentError('A route needs at least two different points.');
    }
    final path = simplifyPath(pts, _jitterM);
    final cum = cumulativeDistances(path);

    // 2. candidates
    final candidates = <_Turn>[];
    for (var i = 1; i < path.length - 1; i++) {
      final b = _back(cum, i, _windowM);
      final f = _ahead(cum, i, _windowM);
      final angle = angleDiffDeg(
        bearingDeg(path[b], path[i]),
        bearingDeg(path[i], path[f]),
      );
      if (angle.abs() >= _minTurnDeg) candidates.add(_Turn(i, angle));
    }

    // 3. merge neighbours on the same side
    final merged = <_Turn>[];
    for (final c in candidates) {
      if (merged.isNotEmpty) {
        final prev = merged.last;
        final sameSide = (prev.angle > 0) == (c.angle > 0);
        if (sameSide && cum[c.index] - cum[prev.index] <= _mergeM) {
          if (c.angle.abs() > prev.angle.abs()) merged[merged.length - 1] = c;
          continue;
        }
      }
      merged.add(c);
    }

    // 4. measure each turn over a wider span
    final turns = <_Turn>[];
    for (var n = 0; n < merged.length; n++) {
      final t = merged[n];
      var w = _wideWindowM;
      if (n > 0) w = math.min(w, (cum[t.index] - cum[merged[n - 1].index]) / 2);
      if (n < merged.length - 1) {
        w = math.min(w, (cum[merged[n + 1].index] - cum[t.index]) / 2);
      }
      w = math.max(w, _windowM);
      final b = _back(cum, t.index, w);
      final f = _ahead(cum, t.index, w);
      var wide = angleDiffDeg(
        bearingDeg(path[b], path[t.index]),
        bearingDeg(path[t.index], path[f]),
      );
      // never weaken a turn and never flip its side
      if (wide.abs() < t.angle.abs() || (wide > 0) != (t.angle > 0)) wide = t.angle;
      turns.add(_Turn(t.index, wide));
    }

    // 5. steps: depart, each turn, arrive
    final indices = <int>[0, ...turns.map((t) => t.index), path.length - 1];
    final steps = <RouteStep>[];
    for (var k = 0; k < indices.length; k++) {
      final idx = indices[k];
      final isFirst = k == 0;
      final isLast = k == indices.length - 1;
      final distM = isLast ? 0 : (cum[indices[k + 1]] - cum[idx]).round();

      late final String maneuver;
      late final String text;
      if (isFirst) {
        maneuver = Maneuver.depart;
        final f = _ahead(cum, 0, _windowM);
        text = 'Head ${_compass(bearingDeg(path[0], path[f]))}';
      } else if (isLast) {
        maneuver = Maneuver.arrive;
        text = 'You have arrived';
      } else {
        maneuver = _maneuverFor(turns[k - 1].angle);
        text = _textFor(maneuver);
      }

      steps.add(RouteStep(
        text: text,
        maneuver: maneuver,
        distM: distM,
        lat: path[idx].lat,
        lng: path[idx].lng,
        pathIndex: idx,
      ));
    }

    final total = cum.last;
    return BuiltRoute(
      path: path,
      steps: steps,
      distanceM: total.round(),
      durationS: (total / walkingSpeedMps).round(),
    );
  }

  // first vertex at least [w] metres BEHIND vertex [i] (or the start)
  static int _back(List<double> cum, int i, double w) {
    var j = i - 1;
    while (j > 0 && cum[i] - cum[j] < w) {
      j--;
    }
    return j;
  }

  // first vertex at least [w] metres AHEAD of vertex [i] (or the end)
  static int _ahead(List<double> cum, int i, double w) {
    var k = i + 1;
    while (k < cum.length - 1 && cum[k] - cum[i] < w) {
      k++;
    }
    return k;
  }

  static String _maneuverFor(double angle) {
    final a = angle.abs();
    final right = angle > 0;
    if (a >= 160) return right ? Maneuver.uTurnRight : Maneuver.uTurnLeft;
    if (a >= 120) return right ? Maneuver.sharpRight : Maneuver.sharpLeft;
    if (a >= 60) return right ? Maneuver.right : Maneuver.left;
    return right ? Maneuver.slightRight : Maneuver.slightLeft;
  }

  static String _textFor(String maneuver) {
    switch (maneuver) {
      case Maneuver.slightLeft:
        return 'Bear left';
      case Maneuver.slightRight:
        return 'Bear right';
      case Maneuver.left:
        return 'Turn left';
      case Maneuver.right:
        return 'Turn right';
      case Maneuver.sharpLeft:
        return 'Turn sharp left';
      case Maneuver.sharpRight:
        return 'Turn sharp right';
      case Maneuver.uTurnLeft:
      case Maneuver.uTurnRight:
        return 'Make a U-turn';
      default:
        return 'Continue straight';
    }
  }

  static String _compass(double bearing) {
    const names = [
      'north', 'northeast', 'east', 'southeast',
      'south', 'southwest', 'west', 'northwest',
    ];
    return names[((bearing + 22.5) / 45).floor() % 8];
  }
}
