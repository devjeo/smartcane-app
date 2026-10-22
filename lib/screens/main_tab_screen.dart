import 'package:flutter/material.dart';
import 'package:ionicons_plus/ionicons_plus.dart';
import '../services/push_notification_service.dart';
import '../services/main_tab_controller.dart';
import '../services/supabase_service.dart';
import '../services/background_location_service.dart'
    show startBackgroundTracking, stopBackgroundTracking;
import '../theme/app_colors.dart';
import 'dashboard/dashboard_screen.dart';
import 'logs/logs_screen.dart';
import 'settings/settings_screen.dart';
import 'user_home/user_home_screen.dart';

/// Equivalent of `export default function TabLayout()` + `CustomTabBar` in
/// _layout.tsx. Expo Router's file-based `<Tabs>` becomes an explicit
/// `IndexedStack` + custom bottom nav bar here, since Flutter has no
/// automatic file-based tab routing.
class MainTabScreen extends StatefulWidget {
  const MainTabScreen({super.key});

  @override
  State<MainTabScreen> createState() => _MainTabScreenState();
}

class _MainTabScreenState extends State<MainTabScreen> {
  // Default until the roles load: the guardian layout (the app's old
  // behavior). A cane-user-only account is switched to My Cane as soon as
  // the roles arrive.
  List<AppTab> _tabs = const [AppTab.home, AppTab.logs, AppTab.account];
  AppTab _current = AppTab.home;
  bool _rolesLoaded = false;

  // Key gives us a handle to LogsScreenState so filters can be pushed into
  // it from outside (e.g. from a device card's alert badge) without
  // recreating the widget; IndexedStack keeps it mounted the whole time.
  final _logsScreenKey = GlobalKey<LogsScreenState>();

  late final Map<AppTab, Widget> _screens = {
    AppTab.home: const DashboardScreen(),
    AppTab.logs: LogsScreen(key: _logsScreenKey),
    AppTab.account: const SettingsScreen(),
    AppTab.myCane: const UserHomeScreen(),
  };

  @override
  void initState() {
    super.initState();
    // Equivalent of the registerForPushNotifications() useEffect in
    // TabLayout, runs once when the tab shell mounts.
    PushNotificationService.instance.registerForPushNotifications();

    MainTabController.rolesChanged.addListener(_loadRoles);
    _loadRoles();

    // Wire up MainTabController so other screens can switch tabs and/or
    // set the Logs filter without using Navigator.
    MainTabController.instance.attach(
      setTab: _selectTab,
      applyLogsFilter: ({device, category}) {
        _logsScreenKey.currentState?.applyFilter(device: device, category: category);
      },
      openLog: (id) => _logsScreenKey.currentState?.openLog(id),
    );
  }

  @override
  void dispose() {
    MainTabController.rolesChanged.removeListener(_loadRoles);
    super.dispose();
  }

  /// Which tabs an account gets, from its raw share roles.
  /// ('owner' is already expanded to admin + user by fetchMyShareRoles.)
  ///   guardian side only (admin / viewer): Home, Logs, Account
  ///   cane user only:                      My Cane, Account
  ///   both (dual-role or solo owner):      Home, My Cane, Logs, Account
  static List<AppTab> tabsForRoles(List<String> roles) {
    final hasGuardianSide = roles.contains('admin') || roles.contains('viewer');
    final hasUser = roles.contains('user');
    if (hasGuardianSide && hasUser) {
      return const [AppTab.home, AppTab.myCane, AppTab.logs, AppTab.account];
    }
    if (hasUser) return const [AppTab.myCane, AppTab.account];
    return const [AppTab.home, AppTab.logs, AppTab.account];
  }

  Future<void> _loadRoles() async {
    try {
      final roles = await SupabaseService.instance.fetchMyShareRoles();
      if (!mounted) return;
      final tabs = tabsForRoles(roles);
      final hasUser = roles.contains('user');
      setState(() {
        _tabs = tabs;
        if (!_rolesLoaded) {
          // First load: land on the first tab of this account's layout
          // (My Cane for a cane-user-only account).
          _current = tabs.first;
        } else if (!tabs.contains(_current)) {
          // The tab we were on no longer exists: fall back to the first one.
          _current = tabs.first;
        }
        _rolesLoaded = true;
      });

      // Only the cane USER's phone reports location. Guardians/viewers
      // don't run the tracking service at all.
      if (hasUser) {
        startBackgroundTracking();
      } else {
        stopBackgroundTracking();
      }
    } catch (_) {}
  }

  /// Selects a tab by name. Returns false (and does nothing) when this
  /// account does not have that tab.
  bool _selectTab(AppTab tab) {
    if (!_tabs.contains(tab)) return false;
    if (_current != tab) setState(() => _current = tab);
    return true;
  }

  void _onTabSelected(int index) {
    final tab = _tabs[index];
    // A direct tap on the Logs tab in the bottom nav always starts
    // unfiltered; only the alert-badge path (MainTabController
    // .showLogsFiltered) should carry a filter through.
    if (tab == AppTab.logs) {
      _logsScreenKey.currentState?.clearFilters();
    }
    _selectTab(tab);
  }

  @override
  Widget build(BuildContext context) {
    final index = _tabs.indexOf(_current).clamp(0, _tabs.length - 1).toInt();
    // Logs only count as "read" while their tab is actually on screen.
    final logsVisible = _tabs[index] == AppTab.logs;
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _logsScreenKey.currentState?.setTabVisible(logsVisible));
    return Scaffold(
      // IndexedStack keeps each tab's state alive when switching, matching
      // Expo Router's <Tabs> default behavior of keeping screens mounted.
      // Each child is keyed by its tab so state survives when the list changes.
      body: IndexedStack(
        index: index,
        children: [
          for (final t in _tabs) KeyedSubtree(key: ValueKey(t), child: _screens[t]!),
        ],
      ),
      bottomNavigationBar: _CustomTabBar(
        tabs: _tabs,
        currentIndex: index,
        onTap: _onTabSelected,
      ),
    );
  }
}

/// Equivalent of `function CustomTabBar({ state, descriptors, navigation })`.
class _CustomTabBar extends StatefulWidget {
  final List<AppTab> tabs;
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _CustomTabBar({required this.tabs, required this.currentIndex, required this.onTap});

  @override
  State<_CustomTabBar> createState() => _CustomTabBarState();
}

class _CustomTabBarState extends State<_CustomTabBar> with SingleTickerProviderStateMixin {
  static const _meta = <AppTab, ({IconData icon, IconData activeIcon, String label})>{
    AppTab.home: (icon: Ionicons.home_outline, activeIcon: Ionicons.home, label: 'Home'),
    AppTab.logs: (icon: Ionicons.document_text_outline, activeIcon: Ionicons.document_text, label: 'Logs'),
    AppTab.account: (icon: Ionicons.settings_outline, activeIcon: Ionicons.settings, label: 'Account'),
    AppTab.myCane: (icon: Ionicons.person_outline, activeIcon: Ionicons.person, label: 'My Cane'),
  };

  List<({IconData icon, IconData activeIcon, String label})> get _tabs =>
      [for (final t in widget.tabs) _meta[t]!];

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final screenWidth = MediaQuery.of(context).size.width;
    final tabWidth = screenWidth / _tabs.length;

    return Container(
      height: 60 + bottomInset + 10,
      padding: EdgeInsets.only(bottom: bottomInset + 10, top: 10),
      decoration: const BoxDecoration(
        color: AppColors.card,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Sliding indicator — equivalent of the Animated.spring translateX
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            top: -1,
            left: tabWidth * widget.currentIndex,
            width: tabWidth,
            child: Center(
              child: Container(
                width: 45,
                height: 4,
                decoration: const BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.vertical(bottom: Radius.circular(4)),
                ),
              ),
            ),
          ),

          Row(
            children: List.generate(_tabs.length, (i) {
              final isFocused = widget.currentIndex == i;
              final tab = _tabs[i];
              return Expanded(
                child: InkWell(
                  onTap: () => widget.onTap(i),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isFocused ? tab.activeIcon : tab.icon,
                        size: 24,
                        color: isFocused ? AppColors.primary : AppColors.textSub,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        tab.label,
                        style: TextStyle(
                          fontSize: 11,
                          color: isFocused ? AppColors.primary : AppColors.textSub,
                          fontWeight: isFocused ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}