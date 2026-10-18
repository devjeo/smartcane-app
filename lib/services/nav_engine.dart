import 'dart:math' as math;

import '../models/geo_point.dart';
import '../models/route_model.dart';
import 'geo_utils.dart';

// Pure Dart (no Flutter, no plugins): runs inside the background service and
// can be unit tested on its own.
//
// The engine follows ONE line (a saved route, or a short "lead-in" route that
// brings the walker back to the main route). Feed it GPS fixes with
// [NavEngine.update]; it answers with a snapshot (progress, current step,
// off-route state) and a list of cues to speak.

const double _mPerDeg = 111320.0;
double _rad(double d) => d * math.pi / 180.0;

/// One GPS reading.
class NavFix {
  final GeoPoint point;
  final double accuracyM;
  final double? headingDeg; // null when unknown
  final double speedMps;
  final DateTime time;
  const NavFix({
    required this.point,
    required this.accuracyM,
    required this.time,
    this.headingDeg,
    this.speedMps = 0,
  });
}

class NavConfig {
  /// A fix further than this from the line counts as "away from the route"
  /// (raised to 1.5 x the GPS accuracy, capped at [offRouteMaxM]).
  final double offRouteBaseM;
  final double offRouteMaxM;

  /// Off route is only confirmed after this many fixes in a row AND this long.
  final int offRouteFixes;
  final Duration offRouteDelay;

  /// Back on route is confirmed after this many good fixes in a row.
  final int rejoinFixes;

  /// Fixes less accurate than this are ignored.
  final double minAccuracyM;

  /// Distance to the end that counts as arrived.
  final double arriveM;

  /// Going back along the route further than this counts as the wrong way.
  final double wrongWayM;

  final Duration weakGpsAfter;
  final Duration offRouteRepeat;

  const NavConfig({
    this.offRouteBaseM = 25,
    this.offRouteMaxM = 60,
    this.offRouteFixes = 3,
    this.offRouteDelay = const Duration(seconds: 8),
    this.rejoinFixes = 2,
    this.minAccuracyM = 40,
    this.arriveM = 15,
    this.wrongWayM = 40,
    this.weakGpsAfter = const Duration(seconds: 20),
    this.offRouteRepeat = const Duration(seconds: 25),
  });

  NavConfig copyWith({double? arriveM}) => NavConfig(
        offRouteBaseM: offRouteBaseM,
        offRouteMaxM: offRouteMaxM,
        offRouteFixes: offRouteFixes,
        offRouteDelay: offRouteDelay,
        rejoinFixes: rejoinFixes,
        minAccuracyM: minAccuracyM,
        arriveM: arriveM ?? this.arriveM,
        wrongWayM: wrongWayM,
        weakGpsAfter: weakGpsAfter,
        offRouteRepeat: offRouteRepeat,
      );
}

enum CueKind {
  approach, // "In 100 meters, turn left"
  turnNow, // "Turn left now"
  continueFor, // "Continue for 250 meters"
  arrived,
  offRoute,
  wrongWay,
  backOnRoute,
  weakGps,
  gpsBack,
}

/// How the phone should buzz for a cue (done by the screen when it is open).
enum Haptic { none, light, turn, arrive, warn }

class NavCue {
  final CueKind kind;
  final String text;
  final Haptic haptic;
  const NavCue(this.kind, this.text, this.haptic);
}

/// Closest point of the line to some position.
class PathHit {
  final int seg;
  final double distM; // from the position to the line
  final double alongM; // from the start of the line to this point
  final GeoPoint point;
  const PathHit(this.seg, this.distM, this.alongM, this.point);
}

class NavSnapshot {
  final double progressM; // furthest point reached along the line
  final double lengthM;
  final double distToPathM; // -1 when unknown
  final bool offRoute; // confirmed (after the short delay)
  final bool wrongWay;
  final bool arrived;
  final bool weakGps;
  final int currentStep;
  final int? nextStep;
  final double? distToNextM;
  final PathHit? nearest;

  const NavSnapshot({
    required this.progressM,
    required this.lengthM,
    required this.distToPathM,
    required this.offRoute,
    required this.wrongWay,
    required this.arrived,
    required this.weakGps,
    required this.currentStep,
    required this.nextStep,
    required this.distToNextM,
    required this.nearest,
  });

  double get remainingM => math.max(0.0, lengthM - progressM);
}

class NavUpdate {
  final NavSnapshot snapshot;
  final List<NavCue> cues;
  const NavUpdate(this.snapshot, this.cues);
}

/// Words for a maneuver, e.g. Maneuver.left -> "turn left".
String spokenManeuver(String m) {
  switch (m) {
    case Maneuver.slightLeft:
      return 'bear left';
    case Maneuver.left:
      return 'turn left';
    case Maneuver.sharpLeft:
      return 'turn sharp left';
    case Maneuver.slightRight:
      return 'bear right';
    case Maneuver.right:
      return 'turn right';
    case Maneuver.sharpRight:
      return 'turn sharp right';
    case Maneuver.uTurnLeft:
    case Maneuver.uTurnRight:
      return 'make a U-turn';
    case Maneuver.arrive:
      return 'arrive at your destination';
    case Maneuver.depart:
      return 'start walking';
    default:
      return 'continue straight';
  }
}

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// "40 meters", "1.2 kilometers". Rounded the way a person would say it.
String spokenDistance(num m) {
  final v = m.round();
  if (v >= 1000) {
    final km = (v / 1000.0);
    return '${km.toStringAsFixed(1)} kilometers';
  }
  if (v < 20) return v == 1 ? '1 meter' : '$v meters';
  return '${((v / 10).round() * 10)} meters';
}

class NavEngine {
  final List<GeoPoint> path;
  final List<RouteStep> steps;
  final NavConfig cfg;

  late final List<double> _cum;
  late final List<double> _k; // metres per degree of longitude, per segment
  late final List<double> _bx;
  late final List<double> _by;
  late final List<double> _len2;
  late final List<double> _stepAlong;

  // state
  double _furthest = 0;
  bool _off = false;
  int _offFixes = 0;
  DateTime? _offSince;
  DateTime? _lastOffCue;
  int _onFixes = 0;
  bool _arrived = false;
  bool _weak = false;
  DateTime _lastGood;
  int _currentStep = 0;
  final Set<int> _spoken = {};
  NavSnapshot? _last;

  NavEngine({
    required this.path,
    required this.steps,
    this.cfg = const NavConfig(),
    DateTime? now,
  }) : _lastGood = now ?? DateTime.now() {
    if (path.length < 2) {
      throw ArgumentError('A route needs at least 2 points.');
    }
    _cum = cumulativeDistances(path);
    final n = path.length - 1;
    _k = List<double>.filled(n, 0);
    _bx = List<double>.filled(n, 0);
    _by = List<double>.filled(n, 0);
    _len2 = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final a = path[i];
      final b = path[i + 1];
      final k = math.cos(_rad(a.lat)) * _mPerDeg;
      _k[i] = k;
      _bx[i] = (b.lng - a.lng) * k;
      _by[i] = (b.lat - a.lat) * _mPerDeg;
      _len2[i] = _bx[i] * _bx[i] + _by[i] * _by[i];
    }
    final sorted = List<RouteStep>.of(steps)
      ..sort((a, b) => a.pathIndex.compareTo(b.pathIndex));
    _steps = sorted;
    _stepAlong = [
      for (final s in sorted) _cum[s.pathIndex.clamp(0, path.length - 1).toInt()],
    ];
  }

  late final List<RouteStep> _steps;

  double get lengthM => _cum.last;
  GeoPoint get end => path.last;
  bool get arrived => _arrived;
  NavSnapshot? get lastSnapshot => _last;

  /// Spoken opening line: first leg, then the first turn if there is one.
  /// [name] null leaves out the "Starting ..." sentence.
  String introText(String? name) {
    final b = StringBuffer();
    if (name != null) b.write(name.isEmpty ? 'Starting the walk. ' : 'Starting $name. ');
    if (_steps.length >= 2) {
      final next = _steps[1];
      final d = _stepAlong[1] - _stepAlong[0];
      if (!next.isArrival && next.maneuver != Maneuver.straight) {
        b.write('Walk ${spokenDistance(d)}, then ${spokenManeuver(next.maneuver)}.');
      } else if (next.isArrival) {
        b.write('Walk ${spokenDistance(d)} to your destination.');
      } else {
        b.write('Walk ${spokenDistance(d)}.');
      }
    } else {
      b.write('Walk ${spokenDistance(lengthM)}.');
    }
    return b.toString().trim();
  }

  /// Closest point of the whole line to [p] (null never; the line has points).
  PathHit nearest(GeoPoint p) => _scan(p, double.infinity).nearest;

  /// After a rejoin: forget the old progress and continue from wherever the
  /// walker is now (the closest point of the line).
  void reanchor(GeoPoint p) {
    seed(nearest(p).alongM);
    _off = false;
    _offFixes = 0;
    _offSince = null;
    _onFixes = 0;
  }

  /// Continue from [alongM] metres along the line (used when a walk resumes
  /// after the service restarted). Cues for steps behind it stay quiet.
  void seed(double alongM) {
    _furthest = math.min(math.max(alongM, 0.0), lengthM);
    _currentStep = _stepIndexAt(_furthest);
    // Do not repeat cues for steps already behind the walker.
    for (var i = 0; i <= _currentStep; i++) {
      for (final lvl in const [0, 1, 2]) {
        _spoken.add(i * 10 + lvl);
      }
    }
  }

  // -- scanning the line ---------------------------------------------------

  ({PathHit nearest, PathHit? chosen}) _scan(GeoPoint p, double threshold) {
    var nearD = double.infinity;
    var nearI = 0;
    var nearT = 0.0;
    var chosenScore = double.infinity;
    var chosenI = -1;
    var chosenT = 0.0;
    var chosenD = 0.0;

    for (var i = 0; i < _k.length; i++) {
      final a = path[i];
      final px = (p.lng - a.lng) * _k[i];
      final py = (p.lat - a.lat) * _mPerDeg;
      final len2 = _len2[i];
      var t = len2 == 0 ? 0.0 : (px * _bx[i] + py * _by[i]) / len2;
      if (t < 0) t = 0;
      if (t > 1) t = 1;
      final dx = px - _bx[i] * t;
      final dy = py - _by[i] * t;
      final d = math.sqrt(dx * dx + dy * dy);

      if (d < nearD) {
        nearD = d;
        nearI = i;
        nearT = t;
      }
      if (d <= threshold) {
        final along = _cum[i] + t * (_cum[i + 1] - _cum[i]);
        // Prefer the part of the line just ahead of where we got to. Going
        // back is penalised, so an out-and-back route follows the walker.
        final score = along >= _furthest ? along - _furthest : (_furthest - along) * 3.0;
        if (score < chosenScore) {
          chosenScore = score;
          chosenI = i;
          chosenT = t;
          chosenD = d;
        }
      }
    }
    return (
      nearest: _hitAt(nearI, nearT, nearD),
      chosen: chosenI < 0 ? null : _hitAt(chosenI, chosenT, chosenD),
    );
  }

  PathHit _hitAt(int i, double t, double d) {
    final a = path[i];
    final b = path[i + 1];
    return PathHit(
      i,
      d,
      _cum[i] + t * (_cum[i + 1] - _cum[i]),
      GeoPoint(a.lat + (b.lat - a.lat) * t, a.lng + (b.lng - a.lng) * t),
    );
  }

  int _stepIndexAt(double along) {
    var idx = 0;
    for (var i = 0; i < _steps.length; i++) {
      if (_stepAlong[i] <= along + 3.0) idx = i;
    }
    return idx;
  }

  // -- updates ---------------------------------------------------------------

  /// Call when no good fix has arrived for a while (the runner calls it about
  /// once a second) so "GPS is weak" can be noticed.
  NavUpdate tick(DateTime now) {
    final cues = <NavCue>[];
    if (!_weak && now.difference(_lastGood) > cfg.weakGpsAfter) {
      _weak = true;
      cues.add(const NavCue(CueKind.weakGps, 'GPS signal is weak. Keep walking carefully.', Haptic.warn));
    }
    return NavUpdate(_snapshot(_last?.distToPathM ?? -1, _last?.nearest, _last?.wrongWay ?? false), cues);
  }

  NavUpdate update(NavFix fix) {
    if (fix.accuracyM > cfg.minAccuracyM) {
      return tick(fix.time);
    }
    final cues = <NavCue>[];
    _lastGood = fix.time;
    if (_weak) {
      _weak = false;
      cues.add(const NavCue(CueKind.gpsBack, 'GPS signal is back.', Haptic.none));
    }

    final threshold = math.min(
      cfg.offRouteMaxM,
      math.max(cfg.offRouteBaseM, fix.accuracyM * 1.5),
    );
    final scan = _scan(fix.point, threshold);
    final chosen = scan.chosen;
    final nearest = scan.nearest;

    final behind = chosen == null ? 0.0 : _furthest - chosen.alongM;
    final wrongWay = chosen != null && behind > cfg.wrongWayM;
    final offNow = chosen == null || wrongWay;

    if (offNow) {
      _onFixes = 0;
      _offFixes++;
      _offSince ??= fix.time;
      if (!_off) {
        if (_offFixes >= cfg.offRouteFixes &&
            fix.time.difference(_offSince!) >= cfg.offRouteDelay) {
          _off = true;
          _lastOffCue = fix.time;
          cues.add(_offRouteCue(fix, nearest, wrongWay));
        }
      } else if (_lastOffCue == null ||
          fix.time.difference(_lastOffCue!) >= cfg.offRouteRepeat) {
        _lastOffCue = fix.time;
        cues.add(_offRouteCue(fix, nearest, wrongWay));
      }
    } else {
      _offFixes = 0;
      _offSince = null;
      if (_off) {
        _onFixes++;
        if (_onFixes >= cfg.rejoinFixes) {
          _off = false;
          _onFixes = 0;
          _lastOffCue = null;
          cues.add(const NavCue(CueKind.backOnRoute, 'Back on the route.', Haptic.light));
        }
      }
      if (!_off) {
        _furthest = math.max(_furthest, chosen.alongM);
      }
    }

    if (!_arrived) {
      final dEnd = distanceM(fix.point, end);
      final nearEnd = dEnd <= math.max(cfg.arriveM, fix.accuracyM);
      final alongEnd = !offNow && !_off && _furthest >= lengthM - cfg.arriveM;
      if (alongEnd || (nearEnd && _furthest >= lengthM * 0.5)) {
        _arrived = true;
        _furthest = lengthM;
        cues.add(const NavCue(CueKind.arrived, 'You have arrived at your destination.', Haptic.arrive));
      }
    }

    if (!_arrived) _stepCues(cues);

    final snap = _snapshot(
      chosen?.distM ?? nearest.distM,
      chosen ?? nearest,
      wrongWay,
    );
    return NavUpdate(snap, cues);
  }

  NavCue _offRouteCue(NavFix fix, PathHit nearest, bool wrongWay) {
    if (wrongWay) {
      return const NavCue(
        CueKind.wrongWay,
        'You are walking the wrong way. Turn around.',
        Haptic.warn,
      );
    }
    final d = spokenDistance(nearest.distM);
    String where = '';
    final h = fix.headingDeg;
    if (h != null && fix.speedMps >= 0.7) {
      final rel = angleDiffDeg(h, bearingDeg(fix.point, nearest.point));
      if (rel.abs() <= 45) {
        where = ' The route is ahead of you.';
      } else if (rel > 45 && rel <= 135) {
        where = ' The route is to your right.';
      } else if (rel < -45 && rel >= -135) {
        where = ' The route is to your left.';
      } else {
        where = ' The route is behind you.';
      }
    }
    return NavCue(
      CueKind.offRoute,
      'You are off the route, about $d away.$where',
      Haptic.warn,
    );
  }

  void _stepCues(List<NavCue> cues) {
    final cs = _stepIndexAt(_furthest);
    if (cs > _currentStep) {
      _currentStep = cs;
      final s = _steps[cs];
      if (!s.isArrival && cs + 1 < _steps.length) {
        final leg = _stepAlong[cs + 1] - _stepAlong[cs];
        if (leg >= 150) {
          cues.add(NavCue(CueKind.continueFor, 'Continue for ${spokenDistance(leg)}.', Haptic.none));
        }
      }
    }
    final n = _currentStep + 1;
    if (n >= _steps.length) return;
    final next = _steps[n];
    if (next.maneuver == Maneuver.straight) return;
    final d = _stepAlong[n] - _furthest;
    if (d < 0) return;
    final legLen = _stepAlong[n] - _stepAlong[_currentStep];

    // Levels: 0 = 100 m, 1 = 30 m, 2 = 10 m. A level is skipped when the leg
    // is too short to fit it. Of the levels that apply, the closest one speaks.
    const dist = [100.0, 30.0, 10.0];
    int? fire;
    for (var lvl = 0; lvl <= 2; lvl++) {
      final key = n * 10 + lvl;
      if (_spoken.contains(key)) continue;
      if (legLen < dist[lvl] + 20 && lvl != 2) {
        _spoken.add(key);
        continue;
      }
      if (d <= dist[lvl]) fire = lvl; // ascending: ends on the closest level
    }
    if (fire == null) return;
    for (var lvl = 0; lvl <= fire; lvl++) {
      _spoken.add(n * 10 + lvl);
    }
    final what = spokenManeuver(next.maneuver);
    if (fire == 2) {
      cues.add(NavCue(
        CueKind.turnNow,
        next.isArrival ? 'Your destination is right here.' : '${_cap(what)} now.',
        next.isArrival ? Haptic.arrive : Haptic.turn,
      ));
    } else {
      final far = spokenDistance(math.max(10.0, d));
      cues.add(NavCue(
        CueKind.approach,
        next.isArrival ? 'Your destination is $far ahead.' : 'In $far, $what.',
        Haptic.light,
      ));
    }
  }

  NavSnapshot _snapshot(double distToPath, PathHit? nearest, bool wrongWay) {
    final cs = _stepIndexAt(_furthest);
    int? nextIdx;
    double? dNext;
    if (cs + 1 < _steps.length) {
      nextIdx = cs + 1;
      dNext = math.max(0.0, _stepAlong[nextIdx] - _furthest);
    }
    final snap = NavSnapshot(
      progressM: _furthest,
      lengthM: lengthM,
      distToPathM: distToPath,
      offRoute: _off,
      wrongWay: wrongWay && _off,
      arrived: _arrived,
      weakGps: _weak,
      currentStep: cs,
      nextStep: nextIdx,
      distToNextM: dNext,
      nearest: nearest,
    );
    _last = snap;
    return snap;
  }

  /// The sorted steps the engine uses (indexes match the snapshot).
  List<RouteStep> get sortedSteps => _steps;
}