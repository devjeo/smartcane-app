import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'supabase_service.dart';

/// Remembers which logs this phone has already SHOWN on the Logs tab.
///
/// Home only counts / highlights logs that are NOT in this set, so a guardian
/// never mistakes an alert they already saw for a new one. Read logs stay in
/// the Logs tab as history.
///
/// Stored per signed-in user, and pruned to the logs still inside the 24 h
/// window so it never grows.
class LogReadStore {
  LogReadStore._();
  static final LogReadStore instance = LogReadStore._();

  /// Bumps whenever new logs get marked read, so Home can recount at once.
  static final ValueNotifier<int> changed = ValueNotifier<int>(0);

  String? _cacheKey;
  Set<String> _cache = {};

  String get _key =>
      'read_log_ids_${SupabaseService.instance.currentUser?.id ?? 'anon'}';

  Future<Set<String>> readIds() async {
    final key = _key;
    if (_cacheKey != key) {
      final prefs = await SharedPreferences.getInstance();
      _cache = (prefs.getStringList(key) ?? const <String>[]).toSet();
      _cacheKey = key;
    }
    return _cache;
  }

  /// Marks [ids] as read. [allKnownIds] is every log currently inside the
  /// 24 h window; read ids that fell out of it are dropped.
  Future<void> markRead(
    Iterable<String> ids, {
    required Iterable<String> allKnownIds,
  }) async {
    final current = await readIds();
    final known = allKnownIds.toSet();
    final next = {...current, ...ids}.where(known.contains).toSet();
    final grew = next.difference(current).isNotEmpty;
    if (!grew && next.length == current.length) return;

    _cache = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, next.toList());
    if (grew) changed.value++;
  }
}
