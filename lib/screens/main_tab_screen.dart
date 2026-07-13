import 'package:flutter/material.dart';
import 'package:ionicons_plus/ionicons_plus.dart';
import '../services/push_notification_service.dart';
import '../services/main_tab_controller.dart';
import '../theme/app_colors.dart';
import 'dashboard/dashboard_screen.dart';
import 'logs/logs_screen.dart';
import 'settings/settings_screen.dart';

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

  // Key gives us a handle to LogsScreenState so filters can be pushed into
  // it from outside (e.g. from a device card's alert badge) without
  // recreating the widget — IndexedStack keeps it mounted the whole time.
  final _logsScreenKey = GlobalKey<LogsScreenState>();

  late final _screens = [
    const DashboardScreen(),
    LogsScreen(key: _logsScreenKey),
    const SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    // Equivalent of the registerForPushNotifications() useEffect in
    // TabLayout — runs once when the tab shell mounts.
    PushNotificationService.instance.registerForPushNotifications();

    // Wire up MainTabController so other screens can switch tabs and/or
    // set the Logs filter without using Navigator.
    MainTabController.instance.attach(
      setTabIndex: (i) => setState(() => _index = i),
      applyLogsFilter: ({device, category}) {
        _logsScreenKey.currentState?.applyFilter(device: device, category: category);
      },
      clearLogsFilter: () => _logsScreenKey.currentState?.clearFilters(),
    );
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
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: _CustomTabBar(
        currentIndex: _index,
        onTap: _onTabSelected,
      ),
    );
  }
}

/// Equivalent of `function CustomTabBar({ state, descriptors, navigation })`.
class _CustomTabBar extends StatefulWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _CustomTabBar({required this.currentIndex, required this.onTap});

  @override
  State<_CustomTabBar> createState() => _CustomTabBarState();
}

class _CustomTabBarState extends State<_CustomTabBar> with SingleTickerProviderStateMixin {
  static const _tabs = [
    (icon: Ionicons.phone_portrait_outline, activeIcon: Ionicons.phone_portrait, label: 'Devices'),
    (icon: Ionicons.document_text_outline, activeIcon: Ionicons.document_text, label: 'Logs'),
    (icon: Ionicons.settings_outline, activeIcon: Ionicons.settings, label: 'Settings'),
  ];

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