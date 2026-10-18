import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import 'background_location_service.dart' show startBackgroundTracking;
import 'route_service.dart';

/// The screen's side of a walk. The walk itself runs in the background
/// service (see walk_runner.dart); this class sends it commands and keeps the
/// last state it reported, so the walk screen can simply listen to it.
class WalkController extends ChangeNotifier {
  final FlutterBackgroundService _svc = FlutterBackgroundService();
  StreamSubscription? _stateSub;
  StreamSubscription? _cueSub;

  Map<String, dynamic> state = const {'phase': 'idle'};

  String get phase => (state['phase'] ?? 'idle').toString();

  /// The walk is going on (or about to).
  bool get isActive => const {'preparing', 'walking', 'toStart', 'rejoining'}.contains(phase);

  /// The walk is over (arrived, cancelled, ended by the server, or failed).
  bool get isOver => const {'arrived', 'cancelled', 'ended', 'error'}.contains(phase);

  /// Start listening. Call once, before [begin] or [attachToRunning].
  void listen() {
    _stateSub ??= _svc.on('walkState').listen((e) {
      if (e == null) return;
      state = Map<String, dynamic>.from(e);
      notifyListeners();
    });
    _cueSub ??= _svc.on('walkCue').listen((e) => _buzz(e?['haptic']?.toString()));
  }

  /// Asks the service whether a walk is in progress. Returns its state, or
  /// null when it did not answer in time (no service, or no walk).
  Future<Map<String, dynamic>?> currentWalk() async {
    listen();
    for (var i = 0; i < 3; i++) {
      state = const {'phase': 'idle'};
      _svc.invoke('walkStatus');
      for (var j = 0; j < 5; j++) {
        await Future.delayed(const Duration(milliseconds: 200));
        if (isActive) return state;
      }
    }
    return null;
  }

  /// Starts a walk of [routeId]. Returns null on success, or a message that
  /// is safe to show.
  Future<String?> begin({required String deviceId, required String routeId}) async {
    listen();
    try {
      final ok = await startBackgroundTracking();
      if (!ok) {
        return 'Location permission is needed. Open this app\'s settings and allow location "all the time".';
      }
      for (var i = 0; i < 16 && !await _svc.isRunning(); i++) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      if (!await _svc.isRunning()) {
        return 'The background service did not start. Close and reopen the app, then try again.';
      }

      // The server decides: starts a new walk, or resumes this user's own
      // unfinished walk of the same route.
      final sessionId = await RouteService.instance.startSession(routeId);

      // The service may still be starting and miss the first message, so send
      // it again until it answers.
      for (var i = 0; i < 12; i++) {
        _svc.invoke('startWalk', {
          'session_id': sessionId,
          'route_id': routeId,
          'device_id': deviceId,
        });
        await Future.delayed(const Duration(milliseconds: 1200));
        if (state['session_id']?.toString() == sessionId && phase != 'idle') {
          return phase == 'error' ? (state['error']?.toString() ?? 'The walk could not start.') : null;
        }
      }
      // Never answered: do not leave a walk running on the server.
      try {
        await RouteService.instance.endSession(sessionId, completed: false);
      } catch (_) {}
      return 'The phone did not start the walk. Please try again.';
    } on RouteException catch (e) {
      return _startMessage(e);
    } catch (_) {
      return 'The walk could not start. Check your connection and try again.';
    }
  }

  String _startMessage(RouteException e) {
    switch (e.code) {
      case '42501':
        return 'Only the person carrying the cane can start a walk.';
      case '55006':
        return 'Another walk is already in progress on this cane.';
      default:
        return e.message.isEmpty ? 'The walk could not start.' : e.message;
    }
  }

  void end({bool completed = false}) => _svc.invoke('stopWalk', {'completed': completed});
  void repeat() => _svc.invoke('walkRepeat');
  void guideBack() => _svc.invoke('walkGuideBack');

  Future<void> _buzz(String? kind) async {
    try {
      switch (kind) {
        case 'turn':
          await HapticFeedback.heavyImpact();
          await Future.delayed(const Duration(milliseconds: 180));
          await HapticFeedback.heavyImpact();
          break;
        case 'arrive':
          for (var i = 0; i < 3; i++) {
            await HapticFeedback.heavyImpact();
            await Future.delayed(const Duration(milliseconds: 200));
          }
          break;
        case 'warn':
          await HapticFeedback.vibrate();
          await Future.delayed(const Duration(milliseconds: 250));
          await HapticFeedback.vibrate();
          break;
        case 'light':
          await HapticFeedback.mediumImpact();
          break;
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _cueSub?.cancel();
    super.dispose();
  }
}
