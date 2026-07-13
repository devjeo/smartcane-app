/// Lets any screen (e.g. a device card's alert badge on the Dashboard tab)
/// tell the tab shell (`MainTabScreen`) to switch tabs and/or update the
/// Logs tab's filter — without pushing a new route. This is what makes the
/// alert badge behave like "switch to the Logs tab, pre-filtered" instead of
/// navigating to a separate page (which had no back button).
///
/// `MainTabScreen` calls [attach] once, in its `initState`, to wire itself
/// up. Any other screen can then call [showLogsFiltered] or [goToTab].
class MainTabController {
  MainTabController._();
  static final MainTabController instance = MainTabController._();

  void Function(int index)? _setTabIndex;
  void Function({String? device, String? category})? _applyLogsFilter;
  void Function()? _clearLogsFilter;

  void attach({
    required void Function(int index) setTabIndex,
    required void Function({String? device, String? category}) applyLogsFilter,
    required void Function() clearLogsFilter,
  }) {
    _setTabIndex = setTabIndex;
    _applyLogsFilter = applyLogsFilter;
    _clearLogsFilter = clearLogsFilter;
  }

  /// Switches to the Logs tab (index 1) with the given device/category
  /// filter applied. Used by the device card's alert badge.
  void showLogsFiltered({String? device, String? category}) {
    _applyLogsFilter?.call(device: device, category: category);
    _setTabIndex?.call(1);
  }

  /// Switches to an arbitrary tab by index. If it's the Logs tab, its
  /// filters are reset first — this is what a *direct* tap on the "Logs"
  /// bottom nav item should always do.
  void goToTab(int index) {
    if (index == 1) {
      _clearLogsFilter?.call();
    }
    _setTabIndex?.call(index);
  }
}