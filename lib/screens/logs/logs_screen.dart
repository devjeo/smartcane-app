import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../models/log_model.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_colors.dart';
import 'widgets/filter_modal.dart';

/// Equivalent of `export default function LogsScreen()` in logs.tsx.
///
/// `initialTargetDevice` / `initialTargetCategory` mirror the RN
/// `useLocalSearchParams()` values used when navigating in from a device's
/// alert badge (`router.push('/logs', { targetDevice, targetCategory })`).
class LogsScreen extends StatefulWidget {
  final String? initialTargetDevice;
  final String? initialTargetCategory;

  const LogsScreen({
    super.key,
    this.initialTargetDevice,
    this.initialTargetCategory,
  });

  @override
  State<LogsScreen> createState() => LogsScreenState();
}

class LogsScreenState extends State<LogsScreen> {
  List<LogModel> _systemLogs = [];
  bool _isLoading = true;
  bool _isRefreshing = false;

  late String _activeDevice;
  late String _activeCategory;
  List<String> _devices = ['All Devices'];
  final _categories = const ['All Types', 'Alerts', 'Battery', 'Vision', 'System'];

  RealtimeChannel? _logSubscription;
  final Set<String> _expanded = {};   // ids of log cards that are open

  bool get _isFilterActive => _activeDevice != 'All Devices' || _activeCategory != 'All Types';

  @override
  void initState() {
    super.initState();
    debugPrint('[LogsScreen] initState called');
    _activeDevice = widget.initialTargetDevice ?? 'All Devices';
    _activeCategory = widget.initialTargetCategory ?? 'All Types';
    debugPrint('[LogsScreen] initial filters -> device: $_activeDevice, category: $_activeCategory');

    // Check auth state right away, since RLS-protected queries silently
    // return nothing if there's no valid session.
    final session = Supabase.instance.client.auth.currentSession;
    debugPrint('[LogsScreen] current session: ${session == null ? 'NULL (not authenticated!)' : 'present, user=${session.user.id}'}');

    _fetchLogs();

    // Equivalent of the 'live-logs-page' realtime channel subscription
    _logSubscription = SupabaseService.instance.subscribeToLogs(() {
      debugPrint('[LogsScreen] realtime event received -> refetching logs');
      _fetchLogs();
    });
    debugPrint('[LogsScreen] realtime subscription set up: $_logSubscription');
  }

  @override
  void dispose() {
    if (_logSubscription != null) {
      SupabaseService.instance.unsubscribe(_logSubscription!);
    }
    super.dispose();
  }

  Future<void> _fetchLogs() async {
    debugPrint('[LogsScreen] _fetchLogs() started');
    try {
      final logs = await SupabaseService.instance.fetchLogs();
      debugPrint('[LogsScreen] fetchLogs() returned ${logs.length} row(s)');

      if (logs.isEmpty) {
        debugPrint('[LogsScreen] WARNING: query succeeded but returned 0 rows. '
            'This usually means either (a) the table is genuinely empty, '
            'or (b) RLS is filtering everything out for this user.');
      } else {
        // Print a sample of the first row so you can eyeball whether the
        // fields (device, type, title, time, etc.) look right.
        final sample = logs.first;
        debugPrint('[LogsScreen] sample row -> device: ${sample.device}, '
            'type: ${sample.type}, title: ${sample.title}, time: ${sample.time}');
      }

      final uniqueDevices = logs.map((l) => l.device).toSet().toList();
      debugPrint('[LogsScreen] unique devices found: $uniqueDevices');

      if (mounted) {
        setState(() {
          _systemLogs = logs;
          _devices = ['All Devices', ...uniqueDevices];
        });
        debugPrint('[LogsScreen] setState done -> _systemLogs.length = ${_systemLogs.length}');
      } else {
        debugPrint('[LogsScreen] widget unmounted before setState, skipped');
      }
    } catch (e, stack) {
      // This is the block that was previously swallowing errors silently.
      // Now it prints the full exception + stack trace so you can see
      // exactly what's failing (auth, network, parsing, etc).
      debugPrint('[LogsScreen] ERROR in _fetchLogs(): $e');
      debugPrint('[LogsScreen] stack trace:\n$stack');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
        debugPrint('[LogsScreen] _isLoading set to false');
      }
    }
  }

  Future<void> _onRefresh() async {
    setState(() => _isRefreshing = true);
    await _fetchLogs();
    if (mounted) setState(() => _isRefreshing = false);
  }

  List<LogModel> get _filteredLogs {
    final result = _systemLogs.where((log) {
      final matchesDevice = _activeDevice == 'All Devices' || log.device == _activeDevice;
      var matchesCategory = true;
      if (_activeCategory != 'All Types') {
        switch (_activeCategory) {
          case 'Alerts':
            matchesCategory = log.type == 'alert';
            break;
          case 'Battery':
            matchesCategory = log.type == 'battery';
            break;
          case 'Vision':
            matchesCategory = log.type == 'vision';
            break;
          case 'System':
            matchesCategory = log.type == 'system';
            break;
        }
      }
      return matchesDevice && matchesCategory;
    }).toList();

    debugPrint('[LogsScreen] _filteredLogs -> ${result.length} of ${_systemLogs.length} '
        '(device filter: $_activeDevice, category filter: $_activeCategory)');
    return result;
  }

  void _clearFilters() {
    setState(() {
      _activeDevice = 'All Devices';
      _activeCategory = 'All Types';
    });
  }

  /// Called by [MainTabController] when the user taps an alert badge
  /// elsewhere in the app. Updates the filter on this already-mounted
  /// screen (kept alive by the tab shell's IndexedStack) instead of
  /// pushing/replacing a route.
  void applyFilter({String? device, String? category}) {
    debugPrint('[LogsScreen] applyFilter called -> device: $device, category: $category');
    setState(() {
      _activeDevice = device ?? 'All Devices';
      _activeCategory = category ?? 'All Types';
    });
  }

  /// Called when the user taps a push notification: show every log, open this one.
  void openLog(String logId) {
    setState(() {
      _activeDevice = 'All Devices';
      _activeCategory = 'All Types';
      _expanded.add(logId);
    });
    _fetchLogs();
  }

  /// Called by [MainTabController] whenever the Logs tab is tapped directly
  /// in the bottom nav, so a plain tab switch always starts unfiltered.
  void clearFilters() => _clearFilters();

  Future<void> _openFilterModal() async {
    final result = await showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FilterModalSheet(
        devices: _devices,
        categories: _categories,
        activeDevice: _activeDevice,
        activeCategory: _activeCategory,
      ),
    );

    if (result != null) {
      setState(() {
        _activeDevice = result['activeDevice'] ?? _activeDevice;
        _activeCategory = result['activeCategory'] ?? _activeCategory;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final filteredLogs = _filteredLogs;
    debugPrint('[LogsScreen] build() -> isLoading: $_isLoading, '
        'filteredLogs.isEmpty: ${filteredLogs.isEmpty}, systemLogs.length: ${_systemLogs.length}');

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
              decoration: const BoxDecoration(
                color: AppColors.bg,
                border: Border(bottom: BorderSide(color: AppColors.border)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('System Logs',
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: AppColors.textMain)),
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: AppColors.card,
                          shape: BoxShape.circle,
                          border: Border.all(color: AppColors.border),
                        ),
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          icon: Icon(Icons.tune,
                              size: 20, color: _isFilterActive ? AppColors.primary : AppColors.textMain),
                          onPressed: _openFilterModal,
                        ),
                      ),
                      if (_isFilterActive)
                        Positioned(
                          top: -2,
                          right: -2,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: AppColors.alert,
                              shape: BoxShape.circle,
                              border: Border.all(color: AppColors.bg, width: 2),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),

            // Log list
            Expanded(
              child: RefreshIndicator(
                onRefresh: _onRefresh,
                color: AppColors.primary,
                child: _isLoading
                    ? ListView(
                        children: const [
                          SizedBox(height: 50),
                          Center(child: CircularProgressIndicator(color: AppColors.primary)),
                          SizedBox(height: 10),
                          Center(
                              child: Text('Loading history...', style: TextStyle(color: AppColors.textSub))),
                        ],
                      )
                    : filteredLogs.isEmpty
                        ? ListView(
                            children: [
                              const SizedBox(height: 50),
                              const Icon(Icons.filter_alt_off_outlined, size: 60, color: AppColors.border),
                              const SizedBox(height: 15),
                              const Center(
                                child: Text('No logs found for this filter combination.',
                                    style: TextStyle(color: AppColors.textSub, fontSize: 14)),
                              ),
                              Center(
                                child: TextButton(
                                  onPressed: _clearFilters,
                                  child: const Text('Clear Filters',
                                      style: TextStyle(
                                          color: AppColors.primary, fontWeight: FontWeight.bold, fontSize: 16)),
                                ),
                              ),
                            ],
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(20, 20, 20, 60),
                            itemCount: filteredLogs.length,
                            itemBuilder: (context, index) {
                              final log = filteredLogs[index];
                              return _LogCard(
                                log: log,
                                expanded: _expanded.contains(log.id),
                                onTap: () => setState(() {
                                  if (!_expanded.remove(log.id)) _expanded.add(log.id);
                                }),
                              );
                            },
                          ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LogCard extends StatelessWidget {
  final LogModel log;
  final bool expanded;
  final VoidCallback onTap;

  const _LogCard({required this.log, required this.expanded, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(15),
      child: Container(
        margin: const EdgeInsets.only(bottom: 15),
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: expanded ? log.color.withOpacity(0.5) : AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: log.color.withOpacity(0.125),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(log.icon, size: 24, color: log.color),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(log.title,
                                style: const TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textMain),
                                overflow: TextOverflow.ellipsis),
                          ),
                          Text(log.time,
                              style: const TextStyle(
                                  fontSize: 12, color: AppColors.textSub, fontWeight: FontWeight.w500)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(log.desc,
                          maxLines: expanded ? null : 2,
                          overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14, color: AppColors.textSub, height: 1.4)),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Text(log.device.toUpperCase(),
                              style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.primary,
                                  letterSpacing: 0.5)),
                          if (log.imagePath != null) ...[
                            const SizedBox(width: 8),
                            const Icon(Icons.photo_camera_outlined, size: 14, color: AppColors.textSub),
                          ],
                          if (log.hasLocation) ...[
                            const SizedBox(width: 6),
                            const Icon(Icons.location_on_outlined, size: 14, color: AppColors.textSub),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                AnimatedRotation(
                  turns: expanded ? 0.25 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Icons.chevron_right, size: 20, color: AppColors.textSub),
                ),
              ],
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: expanded ? _LogDetails(log: log) : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

/// The part that opens when a log card is tapped.
class _LogDetails extends StatelessWidget {
  final LogModel log;
  const _LogDetails({required this.log});

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 84,
                child: Text(k, style: const TextStyle(fontSize: 13, color: AppColors.textSub))),
            Expanded(
                child: Text(v,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.textMain, fontWeight: FontWeight.w600))),
          ],
        ),
      );

  Future<void> _openMaps() async {
    final uri = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=${log.lat},${log.lng}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final when = DateFormat('EEE, MMM d, y · h:mm:ss a').format(log.createdAt.toLocal());
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 1, color: AppColors.border),
          const SizedBox(height: 10),
          _row('Time', when),
          _row('Device', log.device),
          if (log.eventType.isNotEmpty) _row('Event', log.eventType),
          if (log.imagePath != null) ...[
            const SizedBox(height: 10),
            _SosPhoto(path: log.imagePath!),
          ] else if (log.isSos &&
              DateTime.now().difference(log.createdAt) < const Duration(minutes: 2)) ...[
            const SizedBox(height: 10),
            const Text('Photo is uploading…',
                style: TextStyle(fontSize: 12, color: AppColors.textSub)),
          ],
          if (log.hasLocation) ...[
            const SizedBox(height: 10),
            _row('Location',
                '${log.lat!.toStringAsFixed(5)}, ${log.lng!.toStringAsFixed(5)}'),
            if (log.locationAt != null)
              _row('Phone fix', DateFormat('h:mm:ss a').format(log.locationAt!.toLocal())),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: _openMaps,
              icon: const Icon(Icons.map_outlined, size: 18),
              label: const Text('Open in Maps'),
            ),
          ] else if (log.isEmergency) ...[
            const SizedBox(height: 10),
            const Text(
              'No location attached (the cane was offline, or the phone had not reported a position yet).',
              style: TextStyle(fontSize: 12, color: AppColors.textSub),
            ),
          ],
        ],
      ),
    );
  }
}

/// Loads the private photo through a signed URL; tap for full screen.
class _SosPhoto extends StatefulWidget {
  final String path;
  const _SosPhoto({required this.path});

  @override
  State<_SosPhoto> createState() => _SosPhotoState();
}

class _SosPhotoState extends State<_SosPhoto> {
  late final Future<String?> _url = SupabaseService.instance.sosPhotoUrl(widget.path);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _url,
      builder: (context, snap) {
        Widget box(Widget child) => ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: ColoredBox(color: AppColors.chipBg, child: child)),
            );
        if (snap.connectionState != ConnectionState.done) {
          return box(const Center(child: CircularProgressIndicator(strokeWidth: 2)));
        }
        final url = snap.data;
        if (url == null) {
          return box(const Center(
              child: Text('Photo unavailable', style: TextStyle(color: AppColors.textSub))));
        }
        return GestureDetector(
          onTap: () => showDialog(
            context: context,
            builder: (_) => Dialog(
              backgroundColor: Colors.black,
              insetPadding: const EdgeInsets.all(12),
              child: InteractiveViewer(child: Image.network(url)),
            ),
          ),
          child: box(Image.network(
            url,
            fit: BoxFit.cover,
            loadingBuilder: (c, child, p) =>
                p == null ? child : const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            errorBuilder: (c, e, s) => const Center(
                child: Text('Photo unavailable', style: TextStyle(color: AppColors.textSub))),
          )),
        );
      },
    );
  }
}
