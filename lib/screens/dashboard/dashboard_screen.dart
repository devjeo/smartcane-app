import 'dart:async';
import 'package:flutter/material.dart';
import 'package:ionicons_plus/ionicons_plus.dart';
import '../../models/device_model.dart';
import '../../models/route_model.dart';
import '../../services/supabase_service.dart';
import '../../services/route_service.dart';
import '../../services/pending_device_store.dart';
import '../../services/main_tab_controller.dart';
import '../../services/log_read_store.dart';
import '../../theme/app_colors.dart';
import 'home_urgency.dart';
import 'widgets/device_card.dart';
import 'widgets/pending_device_card.dart';

/// Lets DashboardScreen know when it's become the visible route again (e.g.
/// coming back from Add Device) so it can rescan for newly-registered
/// devices — not just on first launch. Register this with your app's
/// MaterialApp: `navigatorObservers: [dashboardRouteObserver]`.
final RouteObserver<PageRoute> dashboardRouteObserver =
    RouteObserver<PageRoute>();

/// Equivalent of `export default function GuardianDashboard()` in index.tsx.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with RouteAware {
  List<DeviceModel> _devices = [];
  List<PendingDevice> _pendingDevices = [];
  Map<String, DateTime> _phonePings = {};
  static const _pingStale = Duration(minutes: 2);
  Set<String> _sosIds = {};
  Map<String, int> _unread = {};   // unread logs per device (alert badge)
  Map<String, RouteSession> _walks = {};
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();

    _fetchDevices();
    // Logs got read on the Logs tab -> recount right away.
    LogReadStore.changed.addListener(_refreshStatus);
    _statusTimer = Timer.periodic(const Duration(seconds: 10), (_) => _refreshStatus());

    // Background tracking is started by MainTabScreen, and only for accounts
    // that carry a cane (the cane USER's phone is the only location source).
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
    LogReadStore.changed.removeListener(_refreshStatus);
    _statusTimer?.cancel();
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
      final allDevices = await SupabaseService.instance.fetchDevices();
      final remoteIds = allDevices.map((d) => d.id).toSet();
      // Home only lists canes this account guards or watches; a cane the
      // account merely CARRIES lives on the My Cane tab.
      final devices = allDevices.where((d) => d.showsOnHome).toList();

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
        final refreshedAll = await SupabaseService.instance.fetchDevices();
        final refreshedIds = refreshedAll.map((d) => d.id).toSet();
        final refreshed = refreshedAll.where((d) => d.showsOnHome).toList();
        stillPending = (await pendingStore.getAll())
            .where((p) => !refreshedIds.contains(p.id))
            .toList();
        if (mounted) {
          setState(() {
            _devices = refreshed;
            _pendingDevices = stillPending;
          });
          unawaited(_refreshStatus());
        }
        return;
      }

      if (mounted) {
        setState(() {
          _devices = devices;
          _pendingDevices = stillPending;
        });
        unawaited(_refreshStatus());
      }
    } catch (e) {
      if (SupabaseService.instance.currentUser == null && mounted) {
        Navigator.of(context).pushReplacementNamed('/login');
      }
    }
  }

  /// Every 10 s: re-read each cane's last heartbeat so Online/Offline stays
  /// correct without a manual refresh, plus active SOS and walks (one query
  /// each for all canes). Rebuilds even if a read fails.
  Future<void> _refreshStatus() async {
    if (!mounted || _devices.isEmpty) return;
    final ids = _devices.map((d) => d.id).toList();
    try {
      final seen = await SupabaseService.instance.fetchLastSeen(ids);
      // Guardian only: is the cane user's phone still pinging?
      final watch = _devices.where((d) => d.isGuardian && d.hasUser).map((d) => d.id).toList();
      final pings = watch.isEmpty
          ? <String, DateTime>{}
          : await SupabaseService.instance.fetchLastPhonePings(watch);
      // SOS and walks are optional extras: if one fails the rest still shows.
      Set<String> sos = _sosIds;
      Map<String, int> unread = _unread;
      Map<String, RouteSession> walks = _walks;
      try {
        final readIds = await LogReadStore.instance.readIds();
        final summary =
            await SupabaseService.instance.fetchUnreadSummary(ids, readIds);
        sos = summary.sosIds;
        unread = summary.counts;
      } catch (_) {}
      try {
        walks = await RouteService.instance.fetchActiveSessions(ids);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _phonePings = pings;
        _sosIds = sos;
        _unread = unread;
        _walks = walks;
        _devices = _devices
            .map((d) => seen.containsKey(d.id) ? d.withLastSeen(seen[d.id]) : d)
            .toList();
      });
    } catch (_) {
      if (mounted) setState(() {});   // still re-evaluate with what we have
    }
  }

  /// Shown to the guardian when the cane is online but the user's phone has
  /// not reported for 2 minutes (the phone pings every 20 s while ready).
  String? _callWarning(DeviceModel d) {
    if (!d.isGuardian || !d.hasUser || !d.isOnline) return null;
    final last = _phonePings[d.id];
    final stale = last == null || DateTime.now().difference(last) > _pingStale;
    if (!stale) return null;
    return "${d.userName}'s phone has not reported for over 2 minutes. "
        "An SOS call may not connect. Ask them to open the SmartCane app.";
  }

  Future<void> _onRefresh() async {
    await _fetchDevices();
  }

  // ---------- navigation helpers ----------

  Map<String, dynamic> _args(DeviceModel d) => {
        'id': d.id,
        'name': d.name,
        'userRole': d.userRole,
        'lat': d.lat,
        'lng': d.lng,
      };

  void _openTracker(DeviceModel d) =>
      Navigator.of(context).pushNamed('/tracker', arguments: _args(d));

  void _openRoutes(DeviceModel d) =>
      Navigator.of(context).pushNamed('/routes', arguments: _args(d));

  void _openSettings(DeviceModel d) =>
      Navigator.of(context).pushNamed('/device-settings', arguments: _args(d));

  void _openLogs(DeviceModel d) => MainTabController.instance
      .showLogsFiltered(device: d.id, category: 'All Types');

  void _addCane() => Navigator.of(context).pushNamed('/add-device');

  Widget _card(DeviceModel d, {bool hero = false}) => DeviceCard(
        key: ValueKey(d.id),
        device: d.withAlerts(_unread[d.id] ?? 0),
        hero: hero,
        sosActive: _sosIds.contains(d.id),
        walk: _walks[d.id],
        callWarning: _callWarning(d),
        onTrack: () => _openTracker(d),
        onLogs: () => _openLogs(d),
        onAlertsTap: () => _openLogs(d),
        onRoutes: d.isGuardian ? () => _openRoutes(d) : null,
        onSettings: d.isGuardian ? () => _openSettings(d) : null,
      );

  Widget _alertStrip(int totalAlerts, List<DeviceModel> sosDevices) {
    final sos = sosDevices.isNotEmpty;
    final text = sos
        ? (sosDevices.length == 1
            ? 'SOS from ${sosDevices.first.userName}'
            : 'SOS from ${sosDevices.length} canes')
        : '$totalAlerts new ${totalAlerts == 1 ? 'alert' : 'alerts'}';
    return GestureDetector(
      onTap: () => MainTabController.instance.showLogsFiltered(),
      child: Container(
        margin: const EdgeInsets.only(bottom: 15),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: sos ? AppColors.alert : const Color(0xFFFEF2F2),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.alert),
        ),
        child: Row(
          children: [
            Icon(sos ? Ionicons.warning : Ionicons.notifications,
                size: 18, color: sos ? Colors.white : AppColors.alert),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: sos ? Colors.white : AppColors.alert)),
            ),
            Icon(Ionicons.chevron_forward,
                size: 18, color: sos ? Colors.white : AppColors.alert),
          ],
        ),
      ),
    );
  }

  Widget _emptyState() {
    return Padding(
      padding: const EdgeInsets.only(top: 60),
      child: Column(
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: const BoxDecoration(
                color: Color(0xFFE0F2FE), shape: BoxShape.circle),
            alignment: Alignment.center,
            child: const Icon(Ionicons.add, size: 40, color: AppColors.primary),
          ),
          const SizedBox(height: 20),
          const Text('No canes yet',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textMain)),
          const SizedBox(height: 6),
          const Text('Pair your cane, or join one with a share code.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: AppColors.textSub)),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton.icon(
              onPressed: _addCane,
              icon: const Icon(Ionicons.add, color: Colors.white),
              label: const Text('Pair your first cane',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final silentIds = {
      for (final d in _devices)
        if (_callWarning(d) != null) d.id,
    };
    final sorted = sortByUrgency(
      _devices,
      sosIds: _sosIds,
      silentIds: silentIds,
      walkingIds: _walks.keys.toSet(),
    );
    final totalAlerts = _devices.fold<int>(0, (sum, d) => sum + (_unread[d.id] ?? 0));
    final sosDevices = sorted.where((d) => _sosIds.contains(d.id)).toList();
    final isEmpty = _devices.isEmpty && _pendingDevices.isEmpty;
    final single = _devices.length == 1;

    // A plain status line: facts only, no "needs attention" wording and no
    // red. Alerts and SOS are shown by the strip and the cards themselves.
    final offline = _devices.where((d) => !d.isOnline).length;
    final lowBattery =
        _devices.where((d) => d.battery <= kLowBatteryPercent).length;
    final subtitle = _devices.isEmpty
        ? 'No canes yet'
        : [
            '${_devices.length} ${_devices.length == 1 ? 'cane' : 'canes'}',
            if (offline == 0 && lowBattery == 0) 'all online',
            if (offline > 0) '$offline offline',
            if (lowBattery > 0) '$lowBattery low battery',
          ].join(' · ');

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // Header: title + subtitle + "+"
            Container(
              padding: const EdgeInsets.fromLTRB(20, 15, 20, 16),
              decoration: const BoxDecoration(
                color: AppColors.bg,
                border: Border(bottom: BorderSide(color: AppColors.border)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Home',
                            style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                                color: AppColors.textMain)),
                        Text(subtitle,
                            style: const TextStyle(
                                fontSize: 14, color: AppColors.textSub)),
                      ],
                    ),
                  ),
                  Material(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      onTap: _addCane,
                      borderRadius: BorderRadius.circular(14),
                      child: const SizedBox(
                        width: 46,
                        height: 46,
                        child: Icon(Ionicons.add, size: 26, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: RefreshIndicator(
                onRefresh: _onRefresh,
                color: AppColors.primary,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 15, 20, 60),
                  children: [
                    if (totalAlerts > 0 || sosDevices.isNotEmpty)
                      _alertStrip(totalAlerts, sosDevices),

                    if (isEmpty)
                      _emptyState()
                    else ...[
                      for (final d in sorted) _card(d, hero: single),
                      for (final pending in _pendingDevices)
                        PendingDeviceCard(key: ValueKey(pending.id), device: pending),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
