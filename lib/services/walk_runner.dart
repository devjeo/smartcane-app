import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/geo_point.dart';
import '../models/route_model.dart';
import 'geo_utils.dart';
import 'nav_engine.dart';
import 'route_service.dart';

/// SharedPreferences key that remembers the walk in progress, so it can pick
/// up again if the background service restarts.
const String kWalkPref = 'walk_active';

/// Messages between the screen and this runner (they live in different
/// isolates, so everything is a plain Map).
///
///   screen -> runner   startWalk {session_id, route_id, device_id}
///                      stopWalk {completed: bool}
///                      walkStatus {}        (asks for the current state)
///                      walkRepeat {}        (say the next instruction again)
///                      walkGuideBack {}     (plan the way back to the route)
///   runner -> screen   walkState {...}      (see _buildState)
///                      walkCue {haptic, text}
class WalkRunner {
  WalkRunner._();
  static final WalkRunner instance = WalkRunner._();

  static const _planCooldown = Duration(seconds: 60);
  static const _autoRejoinAfter = Duration(seconds: 20); // after "off route"
  static const _farFromStartM = 40.0; // farther than this from the line: guide to the start
  static const _maxPlans = 6;
  static const _reportEvery = 5; // seconds

  final FlutterTts _tts = FlutterTts();
  bool _ttsReady = false;

  ServiceInstance? _service;
  StreamSubscription<Position>? _posSub;
  Timer? _timer;
  _Walk? _walk;
  Map<String, dynamic> _state = {'phase': 'idle'};
  String _lastSpoken = '';

  /// Called once from the background service's start-up code.
  void attach(ServiceInstance service) {
    _service = service;
    service.on('startWalk').listen((e) {
      final sid = e?['session_id']?.toString();
      final rid = e?['route_id']?.toString();
      final did = e?['device_id']?.toString();
      if (sid == null || rid == null || did == null) return;
      _begin(sessionId: sid, routeId: rid, deviceId: did);
    });
    service.on('stopWalk').listen((e) {
      final w = _walk;
      if (w == null) return;
      final completed = e?['completed'] == true;
      _finish(
        w,
        completed ? 'arrived' : 'cancelled',
        completed: completed,
        say: completed ? null : 'Walk ended.',
      );
    });
    service.on('walkStatus').listen((_) => _emit());
    service.on('walkRepeat').listen((_) => _repeat());
    service.on('walkGuideBack').listen((_) {
      final w = _walk;
      if (w == null || w.lead != null) return;
      _planLead(w, toStart: w.awaitingStart, manual: true);
    });
    resumeIfAny();
  }

  /// The service is stopping (logout, or a restart to add a permission).
  /// The walk is NOT ended on the server, so it can resume.
  Future<void> shutdown() async {
    _timer?.cancel();
    _timer = null;
    await _posSub?.cancel();
    _posSub = null;
    _walk = null;
  }

  // ---------------------------------------------------------------------
  // Start / resume / finish
  // ---------------------------------------------------------------------

  Future<void> resumeIfAny() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final raw = prefs.getString(kWalkPref);
      if (raw == null) return;
      final m = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final deviceId = m['device_id']?.toString();
      final sessionId = m['session_id']?.toString();
      final routeId = m['route_id']?.toString();
      if (deviceId == null || sessionId == null || routeId == null) {
        await prefs.remove(kWalkPref);
        return;
      }
      final s = await RouteService.instance.fetchActiveSession(deviceId);
      if (s == null || s.id != sessionId) {
        await prefs.remove(kWalkPref);
        return;
      }
      await _begin(
        sessionId: sessionId,
        routeId: routeId,
        deviceId: deviceId,
        resumed: true,
        seedProgressM: s.progressM,
      );
    } catch (_) {}
  }

  Future<void> _begin({
    required String sessionId,
    required String routeId,
    required String deviceId,
    bool resumed = false,
    int seedProgressM = 0,
  }) async {
    if (_walk != null) {
      _emit(); // already walking (the screen asked twice): just re-send state
      return;
    }
    final w = _Walk(sessionId: sessionId, routeId: routeId, deviceId: deviceId);
    _walk = w;
    _state = {'phase': 'preparing', 'session_id': sessionId, 'route_id': routeId};
    _emit();

    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        await _fail(w, 'Location permission is needed to follow a route.');
        return;
      }
      if (!await Geolocator.isLocationServiceEnabled()) {
        await _fail(w, 'Please turn on location (GPS) to follow a route.');
        return;
      }
      final route = await RouteService.instance.fetchRoute(routeId);
      if (route == null) {
        await _fail(w, 'This route could not be loaded.');
        return;
      }
      if (w.finishing || _walk != w) return; // stopped while loading
      w.route = route;

      // Where does the line come from?
      //  1. this walk already has a plan (resumed destination walk)
      //  2. an old route that carries its own path
      //  3. a destination route: plan it now from where the person stands
      List<GeoPoint>? path;
      List<RouteStep>? steps;
      int? total;
      var seedAllowed = resumed;

      final saved = await RouteService.instance.fetchSessionPlan(sessionId);
      if (saved != null && saved.hasPath) {
        path = saved.path;
        steps = saved.steps;
        total = saved.distanceM;
        w.fromPlan = true;
      } else if (route.hasGeometry) {
        path = route.path;
        steps = route.steps;
        total = route.distanceM;
      } else if (route.isDestination) {
        seedAllowed = false; // a fresh plan starts at zero
        _state = {
          'phase': 'preparing',
          'stage': 'locating',
          'session_id': sessionId,
          'route_id': routeId,
        };
        _emit();
        final origin = await _currentPosition();
        if (w.finishing || _walk != w) return;
        if (origin == null) {
          await _fail(w, 'Could not get your location. Go outside or somewhere with a clearer sky, then try again.');
          return;
        }
        _state = {
          'phase': 'preparing',
          'stage': 'planning',
          'session_id': sessionId,
          'route_id': routeId,
        };
        _emit();
        final plans = await RouteService.instance.planWalkingRoute(
          deviceId: deviceId,
          origin: GeoPoint(origin.latitude, origin.longitude),
          destination: route.end,
          alternatives: true, // lets a route that avoids danger zones win
        );
        if (w.finishing || _walk != w) return;
        final pr = plans.first;
        if (pr.distanceM < 15) {
          await _fail(w, 'You are already at the destination.');
          return;
        }
        path = pr.path;
        steps = pr.steps;
        total = pr.distanceM;
        w.fromPlan = true;
        await _savePlan(sessionId, pr, GeoPoint(origin.latitude, origin.longitude));
      }

      if (path == null || path.length < 2) {
        await _fail(w, 'This route could not be loaded.');
        return;
      }
      // Saved lines (fixed routes) are checked again here: a danger zone may
      // have been drawn after the route was made. Fresh plans were already
      // filtered by planWalkingRoute.
      if (!w.fromPlan) {
        final zones = await RouteService.instance.fetchDangerZones(deviceId);
        if (w.finishing || _walk != w) return;
        if (zones.pathHits(path)) {
          await _fail(w,
              'This route now goes through a danger zone, so the walk cannot start. Ask your guardian to change the route.');
          return;
        }
      }
      if (w.finishing || _walk != w) return;
      w.total0 = (total ?? 0) > 0 ? total! : 0;
      w.main = NavEngine(path: path, steps: steps ?? const [], now: DateTime.now());
      w.ready = true;
      if (route.isDestination) {
        // The line starts where the person is: no "walk to the start" phase.
        w.awaitingStart = false;
        w.firstHandled = true;
      }
      if (seedAllowed && seedProgressM > 0 && w.total > 0) {
        w.main.seed(seedProgressM / w.total * w.main.lengthM);
        w.awaitingStart = false;
      }
    } on RouteException catch (e) {
      await _fail(w, e.message);
      return;
    } catch (_) {
      await _fail(w, 'This route could not be loaded.');
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        kWalkPref,
        jsonEncode({'session_id': sessionId, 'route_id': routeId, 'device_id': deviceId}),
      );
    } catch (_) {}

    final LocationSettings settings = defaultTargetPlatform == TargetPlatform.android
        ? AndroidSettings(
            accuracy: LocationAccuracy.best,
            distanceFilter: 0,
            intervalDuration: const Duration(seconds: 2),
          )
        : const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 0);
    await _posSub?.cancel();
    _posSub = Geolocator.getPositionStream(locationSettings: settings).listen(
      _onPosition,
      onError: (_) {},
      cancelOnError: false,
    );
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _onSecond());

    if (resumed) {
      _say('Walk resumed.');
    } else {
      _say(w.main.introText(w.route.name));
    }
    _emit();
  }

  /// One good GPS fix to plan from (waits up to ~30 s outdoors).
  Future<Position?> _currentPosition() async {
    Position? best;
    for (var i = 0; i < 2; i++) {
      try {
        final p = await Geolocator.getCurrentPosition(
          locationSettings: AndroidSettings(
            accuracy: LocationAccuracy.best,
            timeLimit: const Duration(seconds: 20),
          ),
        );
        if (best == null || p.accuracy < best.accuracy) best = p;
        if (p.accuracy <= 50) return p;
      } catch (_) {}
    }
    return (best != null && best.accuracy <= 150) ? best : null;
  }

  /// Saves the plan so the guardian can see the line. A failure here must not
  /// stop the walk, so it only retries a few times.
  Future<void> _savePlan(String sessionId, PlannedRoute plan, GeoPoint origin) async {
    for (var i = 0; i < 3; i++) {
      try {
        await RouteService.instance.setSessionPlan(
            sessionId: sessionId, plan: plan, origin: origin);
        return;
      } catch (_) {
        await Future.delayed(Duration(seconds: 1 + i * 2));
      }
    }
  }

  Future<void> _fail(_Walk w, String message) async {
    _say(message);
    _state = {
      'phase': 'error',
      'session_id': w.sessionId,
      'route_id': w.routeId,
      'error': message,
    };
    _emit();
    _walk = null;
    await _clearPref();
    await _endOnServer(w.sessionId, completed: false);
  }

  Future<void> _finish(
    _Walk w,
    String phase, {
    bool completed = false,
    bool callServer = true,
    String? say,
  }) async {
    if (w.finishing) return;
    w.finishing = true;
    if (say != null) _say(say);
    if (!w.ready) {
      // Stopped before the route finished loading.
      _state = {'phase': phase, 'session_id': w.sessionId, 'route_id': w.routeId};
      _emit();
      _walk = null;
      await _clearPref();
      if (callServer) await _endOnServer(w.sessionId, completed: false);
      return;
    }
    _timer?.cancel();
    _timer = null;
    await _posSub?.cancel();
    _posSub = null;
    await _clearPref();
    if (completed) {
      // Last position first, so the guardian sees 100 %.
      await _report(w, force: true);
    }
    _state = _buildState(w, phase: phase);
    _emit();
    _walk = null;
    if (callServer) await _endOnServer(w.sessionId, completed: completed);
  }

  Future<void> _endOnServer(String sessionId, {required bool completed}) async {
    for (var i = 0; i < 3; i++) {
      try {
        await RouteService.instance.endSession(sessionId, completed: completed);
        return;
      } catch (_) {
        await Future.delayed(Duration(seconds: 2 + i * 3));
      }
    }
  }

  Future<void> _clearPref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kWalkPref);
    } catch (_) {}
  }

  // ---------------------------------------------------------------------
  // GPS fixes
  // ---------------------------------------------------------------------

  void _onPosition(Position pos) {
    final w = _walk;
    if (w == null || w.finishing || !w.hasRoute) return;
    final now = DateTime.now();
    final fix = NavFix(
      point: GeoPoint(pos.latitude, pos.longitude),
      accuracyM: pos.accuracy,
      time: now,
      headingDeg: (pos.heading.isNaN || pos.heading < 0) ? null : pos.heading,
      speedMps: (pos.speed.isNaN || pos.speed < 0) ? 0.0 : pos.speed,
    );
    final good = pos.accuracy <= w.main.cfg.minAccuracyM;
    if (good) {
      w.lastFix = fix;
      w.lastFixAt = now;
    }

    // First good fix: are we anywhere near the route?
    if (good && !w.firstHandled) {
      w.firstHandled = true;
      if (w.awaitingStart) {
        final hit = w.main.nearest(fix.point);
        if (hit.distM > _farFromStartM) {
          _say('You are about ${spokenDistance(hit.distM)} from the route. Finding the way to the start.');
          _planLead(w, toStart: true);
        } else {
          w.awaitingStart = false;
        }
      }
    }

    // Waiting to reach the start: the main route is not followed yet.
    if (w.awaitingStart && w.lead == null) {
      if (good && w.main.nearest(fix.point).distM <= _farFromStartM) {
        w.awaitingStart = false;
        _say('You are at the route. ${w.main.introText(null)}');
      } else {
        if (good && !w.planning) _planLead(w, toStart: true); // retries after a cooldown
        _emit();
        _maybeReport(w);
        return;
      }
    }

    final lead = w.lead;
    if (lead != null) {
      _followLead(w, lead, fix);
    } else {
      final res = w.main.update(fix);
      w.mainSnap = res.snapshot;
      _handleCues(w, res.cues);
      if (res.snapshot.arrived) {
        _finish(w, 'arrived', completed: true);
        return;
      }
      _checkAutoRejoin(w, res.snapshot, now);
    }
    _emit();
    _maybeReport(w);
  }

  void _followLead(_Walk w, NavEngine lead, NavFix fix) {
    // Reached the main route before the lead-in ended?
    if (fix.accuracyM <= w.main.cfg.minAccuracyM) {
      final h = w.main.nearest(fix.point);
      if (h.distM <= 15 && (!w.leadToStart || h.alongM <= 40)) {
        _switchToMain(w, fix, w.leadToStart ? 'You are at the start of the route.' : 'Back on the route.');
        return;
      }
    }
    final res = lead.update(fix);
    if (res.cues.any((c) => c.kind == CueKind.arrived)) {
      _switchToMain(w, fix, w.leadToStart ? 'You are at the start of the route.' : 'Back on the route.');
      return;
    }
    _handleCues(w, res.cues);
  }

  void _switchToMain(_Walk w, NavFix fix, String say) {
    w.lead = null;
    w.awaitingStart = false;
    w.offSince = null;
    w.main.reanchor(fix.point);
    _say(say);
    _cue(Haptic.light, say);
    final res = w.main.update(fix);
    w.mainSnap = res.snapshot;
  }

  void _handleCues(_Walk w, List<NavCue> cues) {
    for (final c in cues) {
      _say(c.text);
      _cue(c.haptic, c.text);
    }
  }

  void _onSecond() {
    final w = _walk;
    if (w == null || w.finishing || !w.hasRoute) return;
    w.seconds++;
    final engine = w.lead ?? w.main;
    // Only the engine being followed can notice a weak signal.
    if (!(w.awaitingStart && w.lead == null)) {
      final res = engine.tick(DateTime.now());
      if (res.cues.isNotEmpty) {
        _handleCues(w, res.cues);
        _emit();
      }
    }
    if (w.seconds % _reportEvery == 0) _maybeReport(w, force: true);
  }

  // ---------------------------------------------------------------------
  // Lead-in route (to the start, or back to the route) through Google
  // ---------------------------------------------------------------------

  void _checkAutoRejoin(_Walk w, NavSnapshot s, DateTime now) {
    if (s.offRoute && !s.wrongWay) {
      w.offSince ??= now;
      if (now.difference(w.offSince!) >= _autoRejoinAfter) {
        _planLead(w, toStart: false);
      }
    } else {
      w.offSince = null;
    }
  }

  Future<void> _planLead(_Walk w, {required bool toStart, bool manual = false}) async {
    if (w.planning || w.lead != null) return;
    final fix = w.lastFix;
    if (fix == null) return;
    final now = DateTime.now();
    if (!manual) {
      if (w.plans >= _maxPlans) return;
      if (w.lastPlanAt != null && now.difference(w.lastPlanAt!) < _planCooldown) return;
    }
    w.planning = true;
    w.plans++;
    w.lastPlanAt = now;
    final GeoPoint target = toStart ? w.main.path.first : w.main.nearest(fix.point).point;
    try {
      final routes = await RouteService.instance.planWalkingRoute(
        deviceId: w.deviceId,
        origin: fix.point,
        destination: target,
      );
      if (_walk != w || w.finishing) return;
      final pr = routes.first;
      final engine = NavEngine(
        path: pr.path,
        steps: pr.steps,
        cfg: w.main.cfg.copyWith(arriveM: 20),
        now: DateTime.now(),
      );
      w.lead = engine;
      w.leadToStart = toStart;
      final say = toStart
          ? 'Guiding you to the start of the route. ${engine.introText(null)}'
          : 'Guiding you back to the route. ${engine.introText(null)}';
      _say(say);
      _cue(Haptic.light, say);
    } on RouteException catch (e) {
      if (_walk == w) _say('I could not plan the way automatically. ${_whereIs(fix.point, target)}');
      w.lastError = e.message;
    } catch (_) {
      if (_walk == w) _say('I could not plan the way automatically. ${_whereIs(fix.point, target)}');
    } finally {
      w.planning = false;
      if (_walk == w) _emit();
    }
  }

  String _whereIs(GeoPoint from, GeoPoint to) {
    final d = distanceM(from, to);
    final b = bearingDeg(from, to);
    const names = [
      'north', 'north-east', 'east', 'south-east',
      'south', 'south-west', 'west', 'north-west',
    ];
    final dir = names[((b + 22.5) % 360 ~/ 45)];
    return 'The route is about ${spokenDistance(d)} to the $dir.';
  }

  // ---------------------------------------------------------------------
  // Reporting to the server (guardian sees it live)
  // ---------------------------------------------------------------------

  void _maybeReport(_Walk w, {bool force = false}) {
    final now = DateTime.now();
    final changed = w.lastSentOff != _isOff(w) || w.lastSentStep != _stepNow(w);
    final due = w.lastReportAt == null ||
        now.difference(w.lastReportAt!) >= const Duration(seconds: _reportEvery);
    if (force || changed || due) _report(w);
  }

  bool _isOff(_Walk w) {
    if (w.awaitingStart && w.lead == null) return false;
    final e = w.lead ?? w.main;
    return e.lastSnapshot?.offRoute ?? false;
  }

  int _stepNow(_Walk w) => w.mainSnap?.currentStep ?? 0;

  Future<void> _report(_Walk w, {bool force = false}) async {
    final fix = w.lastFix;
    if (fix == null || w.reporting) return;
    if (w.finishing && !force) return;
    w.reporting = true;
    final off = _isOff(w);
    final step = _stepNow(w);
    try {
      final stillActive = await RouteService.instance.reportProgress(
        sessionId: w.sessionId,
        lat: fix.point.lat,
        lng: fix.point.lng,
        progressM: _progressM(w),
        step: step,
        offRoute: off,
      );
      w.lastReportAt = DateTime.now();
      w.lastSentOff = off;
      w.lastSentStep = step;
      w.failures = 0;
      if (!stillActive && !w.finishing) {
        w.reporting = false;
        await _finish(w, 'ended', callServer: false, say: 'This walk has ended.');
        return;
      }
    } on RouteException catch (e) {
      w.failures++;
      // "Not allowed" means this walk is no longer ours: stop quietly.
      if (e.code == '42501' && !w.finishing) {
        w.reporting = false;
        await _finish(w, 'ended', callServer: false, say: 'This walk has ended.');
        return;
      }
    } catch (_) {
      w.failures++;
    }
    w.reporting = false;
  }

  /// Progress in the same scale as the route's stored distance.
  int _progressM(_Walk w) {
    final total = w.total;
    final snap = w.mainSnap;
    if (snap == null) return 0;
    if (snap.arrived) return total;
    final len = w.main.lengthM;
    if (len <= 0) return 0;
    return (snap.progressM / len * total).round().clamp(0, total).toInt();
  }

  // ---------------------------------------------------------------------
  // Talking to the screen
  // ---------------------------------------------------------------------

  Future<void> _say(String text) async {
    if (text.isEmpty) return;
    _lastSpoken = text;
    try {
      if (!_ttsReady) {
        _ttsReady = true;
        await _tts.setLanguage('en-US');
        await _tts.setSpeechRate(0.45);
      }
      await _tts.speak(text);
    } catch (_) {}
  }

  void _cue(Haptic h, String text) {
    if (h == Haptic.none) return;
    try {
      _service?.invoke('walkCue', {'haptic': h.name, 'text': text});
    } catch (_) {}
  }

  void _repeat() {
    final w = _walk;
    if (w == null || !w.hasRoute) return;
    final e = w.lead ?? w.main;
    final s = e.lastSnapshot;
    if (s == null) {
      _say(_lastSpoken);
      return;
    }
    if (s.offRoute) {
      _say(_lastSpoken.isEmpty ? 'You are off the route.' : _lastSpoken);
      return;
    }
    if (s.nextStep == null) {
      _say('Walk ${spokenDistance(s.remainingM)} to the end.');
      return;
    }
    final next = e.sortedSteps[s.nextStep!];
    final d = spokenDistance(s.distToNextM ?? 0);
    if (next.isArrival) {
      _say('Your destination is $d ahead.');
    } else if (next.maneuver == Maneuver.straight) {
      _say('Continue straight for $d.');
    } else {
      _say('In $d, ${spokenManeuver(next.maneuver)}.');
    }
  }

  void _emit() {
    final w = _walk;
    if (w != null && w.hasRoute) _state = _buildState(w);
    try {
      _service?.invoke('walkState', _state);
    } catch (_) {}
  }

  Map<String, dynamic> _buildState(_Walk w, {String? phase}) {
    final e = w.lead ?? w.main;
    final s = e.lastSnapshot;
    final fix = w.lastFix;
    final main = w.mainSnap;

    String ph;
    if (phase != null) {
      ph = phase;
    } else if (w.lead != null) {
      ph = w.leadToStart ? 'toStart' : 'rejoining';
    } else if (w.awaitingStart && w.firstHandled) {
      ph = 'toStart';
    } else if (w.lastFix == null) {
      ph = 'preparing';
    } else {
      ph = 'walking';
    }

    String? nextManeuver;
    String? nextText;
    int? distToNext;
    if (s != null && s.nextStep != null) {
      final st = e.sortedSteps[s.nextStep!];
      nextManeuver = st.maneuver;
      nextText = st.text;
      distToNext = (s.distToNextM ?? 0).round();
    }

    final total = w.total;
    final progress = _progressM(w);
    return {
      'phase': ph,
      'session_id': w.sessionId,
      'route_id': w.routeId,
      'device_id': w.deviceId,
      'route_name': w.route.name,
      'total_m': total,
      'progress_m': progress,
      'remaining_m': math.max(0, total - progress),
      'off_route': _isOff(w),
      'wrong_way': s?.wrongWay ?? false,
      'weak_gps': s?.weakGps ?? false,
      'leg': w.lead == null ? 'route' : (w.leadToStart ? 'to_start' : 'rejoin'),
      'next_maneuver': nextManeuver,
      'next_text': nextText,
      'dist_to_next_m': distToNext,
      'current_step': main?.currentStep ?? 0,
      'lat': fix?.point.lat,
      'lng': fix?.point.lng,
      'heading': fix?.headingDeg,
      'message': _lastSpoken,
      'planning': w.planning,
      'plan_ready': w.fromPlan,
    };
  }
}

class _Walk {
  final String sessionId;
  final String routeId;
  final String deviceId;

  late RouteModel route;
  late NavEngine main;
  bool ready = false; // route and engine are loaded
  bool get hasRoute => ready;

  bool fromPlan = false; // the line is this walk's own plan
  int total0 = 0; // distance of the line in use, 0 = unknown
  int get total => total0 > 0 ? total0 : main.lengthM.round();

  NavEngine? lead; // lead-in route being followed instead of the main one
  bool leadToStart = false;
  bool awaitingStart = true; // true until we are on the route for the first time
  bool firstHandled = false;

  NavSnapshot? mainSnap;
  NavFix? lastFix;
  DateTime? lastFixAt;

  DateTime? offSince;
  bool planning = false;
  int plans = 0;
  DateTime? lastPlanAt;
  String? lastError;

  int seconds = 0;
  bool reporting = false;
  DateTime? lastReportAt;
  bool? lastSentOff;
  int? lastSentStep;
  int failures = 0;
  bool finishing = false;

  _Walk({required this.sessionId, required this.routeId, required this.deviceId});
}
