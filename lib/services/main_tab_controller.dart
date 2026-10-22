import 'package:flutter/foundation.dart';

/// Every tab the shell can show. Which ones exist depends on the account's
/// roles (see `MainTabScreen`), so tabs are addressed by NAME, never by
/// position.
enum AppTab { home, logs, account, myCane }

/// Lets any screen (e.g. a device card's alert badge on the Home tab)
/// tell the tab shell (`MainTabScreen`) to switch tabs and/or update the
/// Logs tab's filter, without pushing a new route.
///
/// `MainTabScreen` calls [attach] once, in its `initState`, to wire itself
/// up. Any other screen can then call [showLogsFiltered] or [showLog].
/// If the requested tab does not exist for this account (e.g. Logs for a
/// cane-user-only account) the call does nothing.
class MainTabController {
  MainTabController._();
  static final MainTabController instance = MainTabController._();

  /// Bump to make the tab shell re-check the account's roles (e.g. after
  /// linking as a cane user) so the tabs appear/disappear.
  static final ValueNotifier<int> rolesChanged = ValueNotifier<int>(0);

  /// Returns true if the tab exists and was selected.
  bool Function(AppTab tab)? _setTab;
  void Function({String? device, String? category})? _applyLogsFilter;
  void Function(String logId)? _openLog;

  void attach({
    required bool Function(AppTab tab) setTab,
    required void Function({String? device, String? category}) applyLogsFilter,
    void Function(String logId)? openLog,
  }) {
    _setTab = setTab;
    _applyLogsFilter = applyLogsFilter;
    _openLog = openLog;
  }

  /// Switches to the Logs tab with the given device/category filter.
  /// Used by the device card's alert badge. No-op if there is no Logs tab.
  void showLogsFiltered({String? device, String? category}) {
    if (_setTab?.call(AppTab.logs) != true) return;
    _applyLogsFilter?.call(device: device, category: category);
  }

  /// Opens the Logs tab with this log already expanded (tapping a push).
  /// No-op if there is no Logs tab.
  void showLog(String logId) {
    if (_setTab?.call(AppTab.logs) != true) return;
    _openLog?.call(logId);
  }
}
