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

class _MainTabScreenState extends State<MainTabScreen> with SingleTickerProviderStateMixin {
  int _index = 0;
  bool _hasUserRole = false; // account carries at least one cane -> show "My Cane" tab
  bool _rolesLoaded = false;
  static const _userTabIndex = 3;

  // Key gives us a handle to LogsScreenState so filters can be pushed into
  // it from outside (e.g. from a device card's alert badge) without
  // recreating the widget — IndexedStack keeps it mounted the whole time.
  final _logsScreenKey = GlobalKey<LogsScreenState>();

  late final _screens = [
    const DashboardScreen(),
    LogsScreen(key: _logsScreenKey),
    const SettingsScreen(),
  ];
  final _userHome = const UserHomeScreen();

  @override
  void initState() {
    super.initState();
    // Equivalent of the registerForPushNotifications() useEffect in
    // TabLayout — runs once when the tab shell mounts.
    PushNotificationService.instance.registerForPushNotifications();

    MainTabController.rolesChanged.addListener(_loadRoles);
    _loadRoles();

    // Wire up MainTabController so other screens can switch tabs and/or
    // set the Logs filter without using Navigator.
    MainTabController.instance.attach(
      setTabIndex: (i) => setState(() => _index = i),
      applyLogsFilter: ({device, category}) {
        _logsScreenKey.currentState?.applyFilter(device: device, category: category);
      },
      clearLogsFilter: () => _logsScreenKey.currentState?.clearFilters(),
      openLog: (id) => _logsScreenKey.currentState?.openLog(id),
    );
  }

  @override
  void dispose() {
    MainTabController.rolesChanged.removeListener(_loadRoles);
    super.dispose();
  }

  Future<void> _loadRoles() async {
    try {
      final roles = await SupabaseService.instance.fetchMyShareRoles();
      if (!mounted) return;
      final hasUser = roles.contains('user');
      final onlyUser = hasUser && roles.every((r) => r == 'user');
      setState(() {
        _hasUserRole = hasUser;
        // An account that only carries canes lands on its own screen.
        if (!_rolesLoaded && onlyUser) _index = _userTabIndex;
        if (!hasUser && _index == _userTabIndex) _index = 0;
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

  void _onTabSelected(int index) {
    // A direct tap on the Logs tab in the bottom nav always starts
    // unfiltered — only the alert-badge path (MainTabController
    // .showLogsFiltered) should carry a filter through.
    if (index == 1) {
      _logsScreenKey.currentState?.clearFilters();
    }
    setState(() => _index = index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // IndexedStack keeps each tab's state alive when switching, matching
      // Expo Router's <Tabs> default behavior of keeping screens mounted.
      body: IndexedStack(
        index: _index,
        children: [..._screens, if (_hasUserRole) _userHome],
      ),
      bottomNavigationBar: _CustomTabBar(
        currentIndex: _index,
        onTap: _onTabSelected,
        showUserTab: _hasUserRole,
      ),
    );
  }
}

/// Equivalent of `function CustomTabBar({ state, descriptors, navigation })`.
class _CustomTabBar extends StatefulWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final bool showUserTab;

  const _CustomTabBar({required this.currentIndex, required this.onTap, this.showUserTab = false});

  @override
  State<_CustomTabBar> createState() => _CustomTabBarState();
}

class _CustomTabBarState extends State<_CustomTabBar> with SingleTickerProviderStateMixin {
  static const _baseTabs = [
    (icon: Ionicons.phone_portrait_outline, activeIcon: Ionicons.phone_portrait, label: 'Devices'),
    (icon: Ionicons.document_text_outline, activeIcon: Ionicons.document_text, label: 'Logs'),
    (icon: Ionicons.settings_outline, activeIcon: Ionicons.settings, label: 'Settings'),
  ];
  static const _userTab = (icon: Ionicons.person_outline, activeIcon: Ionicons.person, label: 'My Cane');

  List<({IconData icon, IconData activeIcon, String label})> get _tabs =>
      [..._baseTabs, if (widget.showUserTab) _userTab];

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