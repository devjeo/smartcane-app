import 'dart:async';
import 'package:flutter/material.dart';
import 'package:ionicons_plus/ionicons_plus.dart';
import '../../models/device_model.dart';
import '../../services/supabase_service.dart';
import '../../services/pending_device_store.dart';
import '../../services/main_tab_controller.dart';
import '../../theme/app_colors.dart';
import 'widgets/device_card.dart';
import 'widgets/pending_device_card.dart';

/// Lets DashboardScreen know when it's become the visible route again (e.g.
/// coming back from Add Device) so it can rescan for newly-registered
/// devices — not just on first launch. Register this with your app's
/// MaterialApp: `navigatorObservers: [dashboardRouteObserver]`.
final RouteObserver<PageRoute> dashboardRouteObserver = RouteObserver<PageRoute>();

/// Equivalent of `export default function GuardianDashboard()` in index.tsx.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with SingleTickerProviderStateMixin, RouteAware {
  List<DeviceModel> _devices = [];
  List<PendingDevice> _pendingDevices = [];
  bool _refreshing = false;
  bool _showLoadingBanner = true;

  late final AnimationController _spinController;
  Timer? _bannerTimer;

  @override
  void initState() {
    super.initState();

    // Equivalent of the Animated.loop spin value in index.tsx
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();

    // Equivalent of the 3-second setTimeout that hides the loading banner
    _bannerTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showLoadingBanner = false);
    });

    _fetchDevices();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      dashboardRouteObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    dashboardRouteObserver.unsubscribe(this);
    _spinController.dispose();
    _bannerTimer?.cancel();
    super.dispose();
  }

  /// Called by [dashboardRouteObserver] when a route pushed on top of this
  /// one (e.g. Add Device) gets popped and this screen becomes visible
  /// again — this is the "every time the dashboard opens" moment that
  /// needs to rescan for a pending device that has since registered
  /// itself in Supabase.
  @override
  void didPopNext() {
    _fetchDevices();
  }

  // Equivalent of fetchDevices() — re-run via useFocusEffect on every tab
  // focus in the RN original. Wired here to initState (first mount),
  // pull-to-refresh, and didPopNext above (returning to this screen after
  // Add Device or any other pushed route pops).
  Future<void> _fetchDevices() async {
    try {
      final devices = await SupabaseService.instance.fetchDevices();
      final remoteIds = devices.map((d) => d.id).toSet();

      // Any locally-tracked "pending" device that now has a real row
      // stops being tracked locally — the real card takes over from here.
      final pendingStore = PendingDeviceStore.instance;
      for (final id in remoteIds) {
        await pendingStore.remove(id);
      }
      await pendingStore.pruneStale();
      var stillPending = (await pendingStore.getAll())
          .where((p) => !remoteIds.contains(p.id))
          .toList();

      // fetchDevices() above only returns devices we're already linked to
      // as guardian/owner — a cane's row showing up in Supabase (via its
      // own self-registration) doesn't by itself make it ours. Try to
      // claim guardianship of each still-pending device now; this is safe
      // to retry every time this runs, so if the cane hasn't finished
      // self-registering yet this just fails quietly and we try again on
      // the next scan instead of surfacing an error.
      var claimedAny = false;
      for (final pending in stillPending) {
        try {
          await SupabaseService.instance.pairDevice(pending.id, pending.name);
          await pendingStore.remove(pending.id);
          claimedAny = true;
        } catch (_) {
          // Not registered yet (or some other transient issue) — leave it
          // pending, retried on the next scan.
        }
      }

      if (claimedAny) {
        // Re-fetch so the newly-claimed device(s) render as real cards
        // instead of pending ones on this same pass.
        final refreshed = await SupabaseService.instance.fetchDevices();
        final refreshedIds = refreshed.map((d) => d.id).toSet();
        stillPending = (await pendingStore.getAll())
            .where((p) => !refreshedIds.contains(p.id))
            .toList();
        if (mounted) {
          setState(() {
            _devices = refreshed;
            _pendingDevices = stillPending;
          });
        }
        return;
      }

      if (mounted) {
        setState(() {
          _devices = devices;
          _pendingDevices = stillPending;
        });
      }
    } catch (e) {
      if (SupabaseService.instance.currentUser == null && mounted) {
        Navigator.of(context).pushReplacementNamed('/login');
      }
    }
  }

  Future<void> _onRefresh() async {
    setState(() => _refreshing = true);
    await _fetchDevices();
    if (mounted) setState(() => _refreshing = false);
  }

  @override
  Widget build(BuildContext context) {
    final onlineCount = _devices.where((d) => d.isOnline).length;
    final offlineCount = _devices.length - onlineCount;
    // Sum of each device's alert count, so this matches the number shown
    // in the "X alerts" badge on each device card (not just how many
    // devices happen to have at least one alert).
    final alertCount = _devices.fold<int>(0, (sum, d) => sum + d.alerts);

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeAreaView(
        child: Stack(
          children: [
            Column(
              children: [
                // A. Fixed top header
                Container(
                  padding: const EdgeInsets.fromLTRB(20, 15, 20, 20),
                  decoration: const BoxDecoration(
                    color: AppColors.bg,
                    border: Border(bottom: BorderSide(color: AppColors.border)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('My Devices',
                              style: TextStyle(
                                  fontSize: 28, fontWeight: FontWeight.bold, color: AppColors.textMain)),
                          Text(
                            'Monitoring ${_devices.length} registered ${_devices.length == 1 ? 'cane' : 'canes'}',
                            style: const TextStyle(fontSize: 14, color: AppColors.textSub),
                          ),
                        ],
                      ),
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: AppColors.card,
                              borderRadius: BorderRadius.circular(15),
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.primary.withOpacity(0.15),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            alignment: Alignment.center,
                            child: const Icon(Ionicons.shield_checkmark, size: 24, color: AppColors.primary),
                          ),
                          Positioned(
                            top: -2,
                            right: -2,
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: AppColors.alert,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 1),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // B. Scrollable content
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _onRefresh,
                    color: AppColors.primary,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 15, 20, 60),
                      children: [
                        // Summary bar
                        Container(
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          margin: const EdgeInsets.only(bottom: 20),
                          decoration: BoxDecoration(
                            color: AppColors.card,
                            borderRadius: BorderRadius.circular(15),
                            boxShadow: const [
                              BoxShadow(color: Color(0x0D000000), blurRadius: 10, offset: Offset(0, 4)),
                            ],
                          ),
                          child: Row(
                            children: [
                              _SummaryStat(
                                  value: onlineCount, label: 'Online', color: AppColors.online, showBorder: true),
                              _SummaryStat(
                                  value: offlineCount,
                                  label: 'Offline',
                                  color: AppColors.offline,
                                  showBorder: true),
                              _SummaryStat(value: alertCount, label: 'Alerts', color: AppColors.alert),
                            ],
                          ),
                        ),

                        for (final device in _devices)
                          DeviceCard(
                            key: ValueKey(device.id),
                            device: device,
                            onTap: () => Navigator.of(context).pushNamed('/tracker', arguments: {
                              'id': device.id,
                              'name': device.name,
                              'userRole': device.userRole,
                              'lat': device.lat,
                              'lng': device.lng,
                            }),
                            onAlertsTap: () => MainTabController.instance.showLogsFiltered(
                              device: device.id,
                              category: 'All Types',
                            ),
                          ),

                        for (final pending in _pendingDevices)
                          PendingDeviceCard(key: ValueKey(pending.id), device: pending),

                        // Add device (dashed border)
                        InkWell(
                          borderRadius: BorderRadius.circular(15),
                          onTap: () => Navigator.of(context).pushNamed('/add-device'),
                          child: Container(
                            margin: const EdgeInsets.only(top: 10, bottom: 20),
                            padding: const EdgeInsets.all(25),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(15),
                              border: Border.all(color: AppColors.primary, width: 1.5),
                            ),
                            child: CustomPaint(
                              painter: _DashedBorderPainter(color: AppColors.primary),
                              child: Column(
                                children: [
                                  Container(
                                    width: 50,
                                    height: 50,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF0F8FF),
                                      shape: BoxShape.circle,
                                      border: Border.all(color: AppColors.border),
                                    ),
                                    alignment: Alignment.center,
                                    child: const Icon(Ionicons.add, size: 28, color: AppColors.primary),
                                  ),
                                  const SizedBox(height: 15),
                                  const Text('Add New Device',
                                      style: TextStyle(
                                          fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.primary)),
                                  const SizedBox(height: 5),
                                  const Text('Tap to pair a new Smart Cane',
                                      style: TextStyle(fontSize: 14, color: AppColors.textSub)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),

            // Loading banner overlay
            if (_showLoadingBanner)
              Positioned(
                bottom: 80,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    width: MediaQuery.of(context).size.width * 0.9,
                    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xCC1E293B),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        RotationTransition(
                          turns: _spinController,
                          child: const Icon(Ionicons.reload, size: 20, color: Colors.white),
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Live preview loading, interactions may not be saved',
                            style: TextStyle(color: Colors.white, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SummaryStat extends StatelessWidget {
  final int value;
  final String label;
  final Color color;
  final bool showBorder;

  const _SummaryStat({
    required this.value,
    required this.label,
    required this.color,
    this.showBorder = false,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        decoration: showBorder
            ? const BoxDecoration(
                border: Border(right: BorderSide(color: AppColors.border)),
              )
            : null,
        child: Column(
          children: [
            Text('$value', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: color)),
            const SizedBox(height: 3),
            Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textSub)),
          ],
        ),
      ),
    );
  }
}

/// Draws a dashed rounded-rect border, since Flutter has no CSS
/// `borderStyle: 'dashed'` equivalent out of the box.
class _DashedBorderPainter extends CustomPainter {
  final Color color;
  const _DashedBorderPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    // Intentionally left transparent — the solid border above already
    // approximates the RN dashed container. Swap in a dash_painter package
    // if you want a pixel-perfect dashed line.
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Thin SafeArea wrapper so this file reads closely to the RN
/// `<SafeAreaView edges={['top']}>` usage.
class SafeAreaView extends StatelessWidget {
  final Widget child;
  const SafeAreaView({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return SafeArea(bottom: false, child: child);
  }
}