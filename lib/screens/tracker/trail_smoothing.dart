// Helpers that make the guardian's tracker look smooth.
//
//   removeSpikes  - drops impossible jumps from stored history
//   simplify      - Douglas-Peucker, removes noise points on straight stretches
//   roundCorners  - Chaikin corner cutting, so the line curves instead of
//                   showing sharp angles
//   smoothTrail   - simplify + roundCorners
//   JumpGuard     - second safety net for live updates

import 'dart:math' as math;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../services/location_filter.dart' show haversineM;

class TrailSmoothing {
  TrailSmoothing._();

  /// Removes points that imply an impossible speed from the previous kept
  /// point (GPS spikes in stored history). [timesMs] are epoch milliseconds,
  /// one per point. Same idea as the sender's speed gate:
  ///  - only points farther than [noiseFloorM] can be spikes (history has no
  ///    accuracy for old rows),
  ///  - after [rejectsBeforeAccept] rejections in a row the next point is
  ///    kept (a real relocation, or the first point was the bad one).
  /// Use a bigger [maxSpeedMps] (about 25) if the user can ride a vehicle.
  static List<LatLng> removeSpikes(
    List<LatLng> pts,
    List<int> timesMs, {
    double maxSpeedMps = 3.0,
    double noiseFloorM = 20,
    int rejectsBeforeAccept = 3,
  }) {
    if (pts.length < 2 || pts.length != timesMs.length) return pts;
    final out = <LatLng>[pts.first];
    var lastTime = timesMs.first;
    var streak = 0;
    for (var i = 1; i < pts.length; i++) {
      final dt = (timesMs[i] - lastTime) / 1000.0;
      final meters = haversineM(out.last.latitude, out.last.longitude,
          pts[i].latitude, pts[i].longitude);
      final speed = meters / math.max(dt, 1.0);
      if (speed > maxSpeedMps && meters > noiseFloorM) {
        streak++;
        if (streak <= rejectsBeforeAccept) continue;
      }
      streak = 0;
      out.add(pts[i]);
      lastTime = timesMs[i];
    }
    return out;
  }

  /// Douglas-Peucker simplification. [toleranceM] in metres.
  static List<LatLng> simplify(List<LatLng> pts, {double toleranceM = 2.5}) {
    if (pts.length < 3) return pts;
    final lat0 = pts.first.latitude;
    final mPerLng = 111320.0 * math.cos(lat0 * math.pi / 180);
    final xs = List<double>.generate(
        pts.length, (i) => (pts[i].longitude - pts.first.longitude) * mPerLng);
    final ys = List<double>.generate(
        pts.length, (i) => (pts[i].latitude - lat0) * 111320.0);

    final keep = List<bool>.filled(pts.length, false);
    keep[0] = true;
    keep[pts.length - 1] = true;

    // Iterative (explicit stack): histories can be thousands of points.
    final stack = <List<int>>[
      [0, pts.length - 1]
    ];
    while (stack.isNotEmpty) {
      final seg = stack.removeLast();
      final a = seg[0], b = seg[1];
      if (b <= a + 1) continue;
      var maxD = -1.0;
      var idx = -1;
      for (var i = a + 1; i < b; i++) {
        final d = _perpDist(xs[i], ys[i], xs[a], ys[a], xs[b], ys[b]);
        if (d > maxD) {
          maxD = d;
          idx = i;
        }
      }
      if (maxD > toleranceM && idx != -1) {
        keep[idx] = true;
        stack.add([a, idx]);
        stack.add([idx, b]);
      }
    }
    return [
      for (var i = 0; i < pts.length; i++)
        if (keep[i]) pts[i]
    ];
  }

  static double _perpDist(
      double px, double py, double ax, double ay, double bx, double by) {
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    if (len2 == 0) return math.sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay));
    var t = ((px - ax) * dx + (py - ay) * dy) / len2;
    t = t.clamp(0.0, 1.0).toDouble();
    final cx = ax + t * dx, cy = ay + t * dy;
    return math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
  }

  /// Chaikin corner cutting. Keeps the first and last point exactly.
  static List<LatLng> roundCorners(List<LatLng> pts, {int iterations = 2}) {
    var cur = pts;
    for (var it = 0; it < iterations; it++) {
      if (cur.length < 3) return cur;
      final next = <LatLng>[cur.first];
      for (var i = 0; i < cur.length - 1; i++) {
        final p = cur[i], q = cur[i + 1];
        next.add(LatLng(0.75 * p.latitude + 0.25 * q.latitude,
            0.75 * p.longitude + 0.25 * q.longitude));
        next.add(LatLng(0.25 * p.latitude + 0.75 * q.latitude,
            0.25 * p.longitude + 0.75 * q.longitude));
      }
      next.add(cur.last);
      cur = next;
    }
    return cur;
  }

  /// What the map draws: simplified, then curved.
  static List<LatLng> smoothTrail(List<LatLng> pts) =>
      roundCorners(simplify(pts));
}

/// Second safety net on the guardian side, for live updates. The phone
/// already filters, so this is deliberately lenient: it only stops the pin
/// from teleporting on an obviously impossible jump.
class JumpGuard {
  JumpGuard({
    this.maxSpeedMps = 12.0,
    this.noiseFloorM = 30,
    this.rejectsBeforeAccept = 3,
  });

  final double maxSpeedMps;
  final double noiseFloorM;
  final int rejectsBeforeAccept;

  LatLng? _last;
  DateTime? _at;
  int _streak = 0;

  /// Use the position already on screen as the reference.
  void seed(LatLng p, DateTime at) {
    _last = p;
    _at = at;
    _streak = 0;
  }

  /// True if [p] should move the pin.
  bool accept(LatLng p, DateTime now) {
    final last = _last, at = _at;
    if (last != null && at != null) {
      final dt = now.difference(at).inMilliseconds / 1000.0;
      final meters = haversineM(
          last.latitude, last.longitude, p.latitude, p.longitude);
      final speed = meters / math.max(dt, 1.0);
      if (speed > maxSpeedMps && meters > noiseFloorM) {
        _streak++;
        if (_streak <= rejectsBeforeAccept) return false;
      }
    }
    _streak = 0;
    _last = p;
    _at = now;
    return true;
  }
}
