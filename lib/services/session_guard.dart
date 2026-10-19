import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'background_location_service.dart' show stopBackgroundTracking;
import 'call_ring_service.dart' show appNavigatorKey;

/// One phone per account.
///
/// When the same account logs in on another phone, the server deletes this
/// phone's session. But this phone still holds a valid access token for up to
/// an hour, so the app keeps working as if nothing happened. This guard asks
/// the server "is my session still alive?" when the app comes to the
/// foreground and every [_interval] while it is open. If the answer is no, it
/// signs this phone out locally and returns to the login screen.
class SessionGuard with WidgetsBindingObserver {
  SessionGuard._();
  static final SessionGuard instance = SessionGuard._();

  static const Duration _interval = Duration(seconds: 30);

  Timer? _timer;
  bool _started = false;
  bool _checking = false;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(_interval, (_) => check());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
    _started = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) check();
  }

  Future<void> check() async {
    if (_checking) return;
    final auth = Supabase.instance.client.auth;
    if (auth.currentSession == null) return; // already on the login screen
    _checking = true;
    try {
      // Asks the server; fails if this session was removed.
      await auth.getUser();
    } on AuthRetryableFetchException {
      // No internet. Not a reason to sign out.
    } on AuthException catch (e) {
      const dead = {
        'session_not_found',
        'session_expired',
        'refresh_token_not_found',
        'refresh_token_already_used',
        'bad_jwt',
      };
      final revoked = dead.contains(e.code) ||
          e.statusCode == '401' ||
          e.statusCode == '403';
      if (revoked) await _kickOut();
    } catch (_) {
      // Any other error (timeout, etc.): try again at the next check.
    } finally {
      _checking = false;
    }
  }

  Future<void> _kickOut() async {
    try {
      // Stop reporting this phone's location as the old account.
      await stopBackgroundTracking();
    } catch (_) {}
    try {
      // Local only. Do NOT use SupabaseService.signOut(): it clears the push
      // token, which now belongs to the other phone.
      await Supabase.instance.client.auth.signOut(scope: SignOutScope.local);
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('@user_token');
    } catch (_) {}
    appNavigatorKey.currentState
        ?.pushNamedAndRemoveUntil('/login', (_) => false);
  }
}
