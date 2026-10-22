// Location quality filter for the cane user's phone.
//
// Pure Dart (no Flutter, no plugins) so it can be unit-tested and reused by
// the background service, WalkRunner and the SOS flow.
//
// Pipeline for every raw GPS fix:
//   1. Quality gates   (mock, warm-up, accuracy, staleness, order, speed spike)
//   2. Kalman smoothing (accuracy-weighted, removes 5-15 m jitter)
//   3. Stationary hold  (pin does not wander while the person sits still)
// then [PublishPolicy] decides whether the result is worth sending.

import 'dart:math' as math;

const double _earthRadiusM = 6371000.0;
double _rad(double d) => d * math.pi / 180.0;

/// Great-circle distance in metres between two lat/lng pairs.
double haversineM(double lat1, double lng1, double lat2, double lng2) {
  final dLat = _rad(lat2 - lat1);
  final dLng = _rad(lng2 - lng1);
  final s1 = math.sin(dLat / 2);
  final s2 = math.sin(dLng / 2);
  final h = s1 * s1 + math.cos(_rad(lat1)) * math.cos(_rad(lat2)) * s2 * s2;
  return 2 * _earthRadiusM * math.asin(math.min(1.0, math.sqrt(h)));
}

/// A raw GPS fix, independent of the geolocator plugin.
class RawFix {
  final double lat;
  final double lng;

  /// Reported error radius in metres. <= 0 means "unknown".
  final double accuracy;

  /// Time of the fix as reported by the GPS chip.
  final DateTime time;
  final bool isMocked;

  /// Ground speed in m/s, or a negative number when unknown.
  final double speed;

  const RawFix({
    required this.lat,
    required this.lng,
    required this.accuracy,
    required this.time,
    this.isMocked = false,
    this.speed = -1,
  });
}

class LocationFilterConfig {
  /// Drop fixes whose error radius is worse than this (metres).
  final double maxAccuracyM;

  /// Drop fixes older than this, measured against the freshest fix seen
  /// (self-calibrating, so a wrong phone clock does not drop everything).
  final Duration maxFixAge;

  /// The first N fixes after a (re)start are ignored: they are often coarse.
  final int warmUpFixes;

  /// Implied speed above this is treated as a GPS spike (m/s).
  /// 3 m/s = walking only. Use ~25 if the user can ride a vehicle.
  final double maxSpeedMps;

  /// After this many consecutive spike rejections the NEXT fix is
  /// accepted anyway (the person really did relocate, or the first point
  /// was the bad one).
  final int rejectsBeforeAccept;

  /// Kalman process noise: how fast the true position may change (m/s).
  final double processNoiseMps;

  /// Below this speed the person counts as standing still (m/s).
  final double stationarySpeedMps;

  /// While still, the published point is held unless the smoothed position
  /// moves farther than max(accuracy, this) (metres).
  final double minHoldRadiusM;

  final bool rejectMocked;

  const LocationFilterConfig({
    this.maxAccuracyM = 20,
    this.maxFixAge = const Duration(seconds: 5),
    this.warmUpFixes = 3,
    this.maxSpeedMps = 3.0,
    this.rejectsBeforeAccept = 3,
    this.processNoiseMps = 3.0,
    this.stationarySpeedMps = 0.5,
    this.minHoldRadiusM = 8,
    this.rejectMocked = true,
  });
}

enum FixVerdict {
  accepted,
  warmUp,
  mocked,
  poorAccuracy,
  stale,
  outOfOrder,
  speedSpike,
}

/// A fix that passed the gates and was smoothed.
class FilteredFix {
  final double lat;
  final double lng;

  /// Estimated error radius after smoothing (metres).
  final double accuracy;
  final DateTime time;

  /// Speed in m/s (reported by the chip when known, otherwise computed).
  final double speed;

  /// True when the stationary hold kept the previous point.
  final bool held;

  const FilteredFix({
    required this.lat,
    required this.lng,
    required this.accuracy,
    required this.time,
    required this.speed,
    required this.held,
  });
}

class FilterResult {
  final FixVerdict verdict;
  final FilteredFix? fix;
  const FilterResult(this.verdict, [this.fix]);
  bool get accepted => fix != null;
}

class LocationFilter {
  LocationFilter([this.config = const LocationFilterConfig()]);

  final LocationFilterConfig config;

  int _seen = 0;
  int? _minOffsetMs; // smallest (wall clock - fix time) seen so far
  int _staleStreak = 0;

  RawFix? _lastAccepted;
  double _lastAcc = 0;
  int _spikeStreak = 0;

  // Kalman state (degrees) and variance (metres squared). _var < 0 = unset.
  double _lat = 0;
  double _lng = 0;
  double _var = -1;
  DateTime? _kalmanTime;

  // Last point handed out (for the stationary hold).
  double? _outLat;
  double? _outLng;

  /// Forget everything. Call when the GPS stream is (re)started.
  void reset() {
    _seen = 0;
    _minOffsetMs = null;
    _staleStreak = 0;
    _lastAccepted = null;
    _lastAcc = 0;
    _spikeStreak = 0;
    _lat = 0;
    _lng = 0;
    _var = -1;
    _kalmanTime = null;
    _outLat = null;
    _outLng = null;
  }

  FilterResult process(RawFix fix, {DateTime? now}) {
    final wall = now ?? DateTime.now();
    _seen++;

    // Track how far the phone clock is from GPS time, so "stale" can be
    // judged relative to the freshest fix instead of the (maybe wrong) clock.
    final offsetMs = wall.difference(fix.time).inMilliseconds;
    if (_minOffsetMs == null || offsetMs < _minOffsetMs!) {
      _minOffsetMs = offsetMs;
    }

    if (config.rejectMocked && fix.isMocked) {
      return const FilterResult(FixVerdict.mocked);
    }

    if (_seen <= config.warmUpFixes) {
      return const FilterResult(FixVerdict.warmUp);
    }

    // Unknown accuracy (<= 0) is treated as "worst acceptable".
    final acc = fix.accuracy > 0 ? fix.accuracy : config.maxAccuracyM;
    if (acc > config.maxAccuracyM) {
      return const FilterResult(FixVerdict.poorAccuracy);
    }

    final ageMs = offsetMs - _minOffsetMs!;
    if (ageMs > config.maxFixAge.inMilliseconds) {
      _staleStreak++;
      // A long run of "stale" fixes means the clock jumped, not that every
      // fix is old: re-calibrate.
      if (_staleStreak >= 10) {
        _minOffsetMs = offsetMs;
        _staleStreak = 0;
      }
      return const FilterResult(FixVerdict.stale);
    }
    _staleStreak = 0;

    final last = _lastAccepted;
    if (last != null && !fix.time.isAfter(last.time)) {
      return const FilterResult(FixVerdict.outOfOrder);
    }

    // Speed sanity against the last accepted fix.
    var reseed = false;
    var computedSpeed = 0.0;
    if (last != null) {
      final dt = fix.time.difference(last.time).inMilliseconds / 1000.0;
      final meters = haversineM(last.lat, last.lng, fix.lat, fix.lng);
      computedSpeed = meters / math.max(dt, 1.0);
      final beyondNoise = meters > (acc + _lastAcc);
      if (computedSpeed > config.maxSpeedMps && beyondNoise) {
        _spikeStreak++;
        if (_spikeStreak <= config.rejectsBeforeAccept) {
          return const FilterResult(FixVerdict.speedSpike);
        }
        reseed = true; // accept the relocation and restart smoothing
      }
    }
    _spikeStreak = 0;

    // Kalman smoothing, weighted by the fix's own accuracy.
    if (_var < 0 || reseed || _kalmanTime == null) {
      _lat = fix.lat;
      _lng = fix.lng;
      _var = acc * acc;
    } else {
      final dt =
          math.max(fix.time.difference(_kalmanTime!).inMilliseconds / 1000.0, 0.1);
      _var += dt * config.processNoiseMps * config.processNoiseMps;
      final k = _var / (_var + acc * acc);
      _lat += k * (fix.lat - _lat);
      _lng += k * (fix.lng - _lng);
      _var = (1 - k) * _var;
    }
    _kalmanTime = fix.time;
    _lastAccepted = fix;
    _lastAcc = acc;

    final smoothAcc = math.max(math.sqrt(_var), 3.0);
    final speed = fix.speed >= 0 ? fix.speed : computedSpeed;

    // Stationary hold: keep the previous point while still and inside the
    // error radius, so the pin does not wander.
    var outLat = _lat;
    var outLng = _lng;
    var held = false;
    if (_outLat != null && speed < config.stationarySpeedMps) {
      final d = haversineM(_outLat!, _outLng!, _lat, _lng);
      if (d < math.max(smoothAcc, config.minHoldRadiusM)) {
        outLat = _outLat!;
        outLng = _outLng!;
        held = true;
      }
    }
    _outLat = outLat;
    _outLng = outLng;

    return FilterResult(
      FixVerdict.accepted,
      FilteredFix(
        lat: outLat,
        lng: outLng,
        accuracy: smoothAcc,
        time: fix.time,
        speed: speed,
        held: held,
      ),
    );
  }
}

enum PublishReason { first, moved, heartbeat, live }

/// Decides when a filtered fix is worth sending to the server.
class PublishPolicy {
  PublishPolicy({
    this.moveThresholdM = 10,
    this.heartbeat = const Duration(minutes: 3),
    this.liveInterval = const Duration(milliseconds: 2500),
    this.liveMinMoveM = 1,
    this.liveStillRepeat = const Duration(seconds: 10),
  });

  /// Normal mode: publish when moved farther than max(this, accuracy).
  final double moveThresholdM;

  /// Stationary heartbeat: publish at least this often.
  final Duration heartbeat;

  /// Live mode (walk, SOS, guardian watching): publish this often...
  final Duration liveInterval;

  /// ...as long as the person moved at least this far (metres)...
  final double liveMinMoveM;

  /// ...or at least this often when standing still.
  final Duration liveStillRepeat;

  double? _lat;
  double? _lng;
  DateTime? _at;

  void reset() {
    _lat = null;
    _lng = null;
    _at = null;
  }

  /// Returns why [f] should be sent, or null if it should not be.
  PublishReason? decide(FilteredFix f, {required bool live, DateTime? now}) {
    final t = now ?? DateTime.now();
    if (_at == null || _lat == null || _lng == null) return PublishReason.first;

    final elapsed = t.difference(_at!);
    final moved = haversineM(_lat!, _lng!, f.lat, f.lng);

    if (live &&
        elapsed >= liveInterval &&
        (moved >= liveMinMoveM || elapsed >= liveStillRepeat)) {
      return PublishReason.live;
    }
    if (moved >= math.max(moveThresholdM, f.accuracy)) return PublishReason.moved;
    if (elapsed >= heartbeat) return PublishReason.heartbeat;
    return null;
  }

  /// Call after the point was really sent.
  void markPublished(FilteredFix f, {DateTime? now}) {
    _lat = f.lat;
    _lng = f.lng;
    _at = now ?? DateTime.now();
  }
}
