import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../models/log_model.dart';
import '../../services/log_read_store.dart';
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

class LogsScreenState extends State<LogsScreen> with WidgetsBindingObserver {
  /// Logs loaded so far, newest first. This is the FULL history, loaded a
  /// page at a time; nothing is hidden by age.
  List<LogModel> _systemLogs = [];
  List<String> _deviceIds = [];
  bool _isLoading = true;
  bool _isRefreshing = false;
  bool _loadingMore = false;
  bool _hasMore = true;          // there may be older logs on the server
  String? _loadError;            // set when the main load fails

  static const _pageSize = 100;

  late String _activeDevice;
  late String _activeCategory;
  String _activeDate = kDateAny;
  DateTimeRange? _customRange;
  List<String> get _devices => ['All Devices', ...(_deviceIds.toList()..sort())];
  final _categories = const ['All Types', 'Alerts', 'Battery', 'Vision', 'System'];

  RealtimeChannel? _logSubscription;
  final Set<String> _expanded = {};   // ids of log cards that are open

  bool _alertsOnly = false;   // the "Alerts" quick filter

  // Read tracking: opening the Logs tab marks every log from the last 24 h
  // as read (whatever filter is on), so the Home alert clears. Logs that
  // arrive afterwards are unread again and bring the Home alert back. Older
  // logs are never "unread"; they are just history.
  bool _tabVisible = false;

  /// Told by the tab shell whenever this tab is shown / hidden.
  void setTabVisible(bool v) {
    if (_tabVisible == v) return;
    setState(() => _tabVisible = v);   // rebuild -> marks what is recent
    // Showing the tab: pick up anything that arrived while it was hidden.
    if (v) _refreshNewest();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      setState(() {});
      if (_tabVisible) _refreshNewest();
    }
  }

  void _markDisplayedRead() {
    if (!mounted || !_tabVisible || _isLoading || _loadError != null) return;
    final life = WidgetsBinding.instance.lifecycleState;
    if (life != null && life != AppLifecycleState.resumed) return;
    final recentIds = _systemLogs.where((l) => l.isRecent).map((l) => l.id).toList();
    LogReadStore.instance.markRead(recentIds, allKnownIds: recentIds);
  }

  /// The "Alerts" quick filter: an SOS or any alert-type log, ALL time.
  /// It is only a filter. Nothing here counts as pending or unresolved.
  bool _isAlertLog(LogModel l) => l.isSos || l.type == 'alert';

  bool get _isFilterActive =>
      _activeDevice != 'All Devices' ||
      _activeCategory != 'All Types' ||
      _activeDate != kDateAny;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _activeDevice = widget.initialTargetDevice ?? 'All Devices';
    _activeCategory = widget.initialTargetCategory ?? 'All Types';

    _fetchLogs();

    // New / changed / deleted log -> refresh the newest page only.
    _logSubscription = SupabaseService.instance.subscribeToLogs(_refreshNewest);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_logSubscription != null) {
      SupabaseService.instance.unsubscribe(_logSubscription!);
    }
    super.dispose();
  }

  // ---------- loading ----------

  /// Appends [more] (older logs) to [base], dropping ids already present.
  ({List<LogModel> logs, int added}) _appendOlder(List<LogModel> base, List<LogModel> more) {
    final have = base.map((l) => l.id).toSet();
    final fresh = more.where((l) => !have.contains(l.id)).toList();
    return (logs: [...base, ...fresh], added: fresh.length);
  }

  /// If the cane picked in the device filter is no longer paired, go back
  /// to "All Devices" (it is no longer in the list to choose from).
  void _dropStaleDeviceFilter(List<String> ids) {
    if (_activeDevice != 'All Devices' && !ids.contains(_activeDevice)) {
      _activeDevice = 'All Devices';
    }
  }

  /// Full (re)load: the newest page, then older pages until the whole last
  /// 24 h is covered (so the Home alert count and this list always agree).
  Future<void> _fetchLogs() async {
    try {
      final ids = await SupabaseService.instance.fetchLogDeviceIds();
      var logs = await SupabaseService.instance.fetchLogs(deviceIds: ids, limit: _pageSize);
      var hasMore = logs.length >= _pageSize;
      var pages = 0;
      while (hasMore && logs.isNotEmpty && logs.last.isRecent && pages < 20) {
        pages++;
        final more = await SupabaseService.instance.fetchLogs(
            deviceIds: ids, before: logs.last.createdAt, limit: _pageSize);
        final r = _appendOlder(logs, more);
        logs = r.logs;
        hasMore = more.length >= _pageSize && r.added > 0;
      }
      if (!mounted) return;
      setState(() {
        _deviceIds = ids;
        _dropStaleDeviceFilter(ids);
        _systemLogs = logs;
        _hasMore = hasMore;
        _loadError = null;
      });
    } catch (e, stack) {
      debugPrint('[LogsScreen] ERROR in _fetchLogs(): $e\n$stack');
      if (mounted) {
        setState(() => _loadError = "Couldn't load logs. Check your connection and try again.");
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
    _fillForFilter();
  }

  /// Quietly refreshes the newest page and merges it into what is loaded
  /// (also drops logs that were deleted). Used by realtime events, when the
  /// tab is shown, and when the app comes back to the foreground.
  Future<void> _refreshNewest() async {
    if (!mounted || _isLoading || _loadingMore) return;
    try {
      final ids = await SupabaseService.instance.fetchLogDeviceIds();
      final fresh = await SupabaseService.instance.fetchLogs(deviceIds: ids, limit: _pageSize);
      if (!mounted) return;

      // 100+ new logs since the last load would leave a hole in the list.
      if (fresh.length >= _pageSize &&
          _systemLogs.isNotEmpty &&
          fresh.last.createdAt.isAfter(_systemLogs.first.createdAt)) {
        await _fetchLogs();
        return;
      }

      final freshIds = fresh.map((l) => l.id).toSet();
      final List<LogModel> kept;
      if (fresh.length < _pageSize || fresh.isEmpty) {
        kept = const [];   // fresh already holds the entire history
      } else {
        final oldest = fresh.last.createdAt;
        // Older logs already loaded stay, except those of a cane that has
        // been unpaired since.
        kept = _systemLogs
            .where((l) =>
                !freshIds.contains(l.id) &&
                l.createdAt.isBefore(oldest) &&
                ids.contains(l.device))
            .toList();
      }
      setState(() {
        _deviceIds = ids;
        _dropStaleDeviceFilter(ids);
        _systemLogs = [...fresh, ...kept];
        if (fresh.length < _pageSize) {
          _hasMore = false;
        } else if (kept.isEmpty) {
          _hasMore = true;
        }
        _loadError = null;
      });
    } catch (e) {
      debugPrint('[LogsScreen] _refreshNewest failed: $e');
    }
  }

  /// Loads the next, older page.
  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _isLoading || _systemLogs.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final more = await SupabaseService.instance.fetchLogs(
          deviceIds: _deviceIds, before: _systemLogs.last.createdAt, limit: _pageSize);
      if (!mounted) return;
      final r = _appendOlder(_systemLogs, more);
      setState(() {
        _systemLogs = r.logs;
        _hasMore = more.length >= _pageSize && r.added > 0;
      });
    } catch (e) {
      debugPrint('[LogsScreen] _loadMore failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Couldn't load older logs. Try again.")));
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// While a filter leaves the list short (or a date range reaches further
  /// back than what is loaded), keep loading older pages. Stops at the end
  /// of the history or after 30 pages; the "Load older logs" button covers
  /// the rest.
  bool get _needsMoreForFilter {
    if (!_hasMore || _systemLogs.isEmpty) return false;
    final w = _dateWindow;
    if (w.from != null && _systemLogs.last.createdAt.isAfter(w.from!)) return true;
    return (_isFilterActive || _alertsOnly) && _filteredLogs.length < 15;
  }

  Future<void> _fillForFilter() async {
    var guard = 0;
    while (mounted && !_isLoading && _needsMoreForFilter && guard < 30) {
      guard++;
      final before = _systemLogs.length;
      await _loadMore();
      if (_systemLogs.length == before) break;
    }
  }

  Future<void> _onRefresh() async {
    setState(() => _isRefreshing = true);
    await _fetchLogs();
    if (mounted) setState(() => _isRefreshing = false);
  }

  // ---------- filtering ----------

  /// The date filter as a window: [from] inclusive, [to] exclusive (either
  /// can be null = no limit).
  ({DateTime? from, DateTime? to}) get _dateWindow {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (_activeDate) {
      case 'Today':
        return (from: today, to: null);
      case 'Last 7 days':
        return (from: DateTime(now.year, now.month, now.day - 6), to: null);
      case 'Last 30 days':
        return (from: DateTime(now.year, now.month, now.day - 29), to: null);
      case kDateCustom:
        final r = _customRange;
        if (r == null) return (from: null, to: null);
        return (
          from: DateTime(r.start.year, r.start.month, r.start.day),
          to: DateTime(r.end.year, r.end.month, r.end.day + 1),
        );
      default:
        return (from: null, to: null);
    }
  }

  List<LogModel> get _filteredLogs {
    final w = _dateWindow;
    return _systemLogs.where((log) {
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
      final t = log.createdAt.toLocal();
      final matchesDate =
          (w.from == null || !t.isBefore(w.from!)) && (w.to == null || t.isBefore(w.to!));
      final matchesAlerts = !_alertsOnly || _isAlertLog(log);
      return matchesDevice && matchesCategory && matchesDate && matchesAlerts;
    }).toList();
  }

  void _clearFilters() {
    setState(() {
      _activeDevice = 'All Devices';
      _activeCategory = 'All Types';
      _activeDate = kDateAny;
      _customRange = null;
      _alertsOnly = false;
    });
  }

  static String _dayLabel(DateTime t) {
    final now = DateTime.now();
    final today = DateTime.utc(now.year, now.month, now.day);
    final l = t.toLocal();
    final day = DateTime.utc(l.year, l.month, l.day);
    final diff = today.difference(day).inDays;
    if (diff <= 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    // Older than this calendar year: include the year.
    return DateFormat(l.year == now.year ? 'EEE, MMM d' : 'EEE, MMM d, y').format(l);
  }

  /// Flat list for the ListView: RECENT SOS pinned first under its own
  /// header, then every other log under a day header. Items are [_Header]
  /// or [LogModel].
  List<Object> _buildItems(List<LogModel> logs) {
    final sos = logs.where((l) => l.isSos && l.isRecent).toList();
    final rest = logs.where((l) => !(l.isSos && l.isRecent)).toList();
    final items = <Object>[];
    if (sos.isNotEmpty) {
      items.add(_Header('SOS', sos.length, isSos: true));
      items.addAll(sos);
    }
    // One pass for the per-day counts.
    final labels = [for (final l in rest) _dayLabel(l.createdAt)];
    final counts = <String, int>{};
    for (final label in labels) {
      counts[label] = (counts[label] ?? 0) + 1;
    }
    String? currentDay;
    for (var i = 0; i < rest.length; i++) {
      if (labels[i] != currentDay) {
        currentDay = labels[i];
        items.add(_Header(currentDay, counts[currentDay]!));
      }
      items.add(rest[i]);
    }
    return items;
  }

  /// Called by [MainTabController] when the user taps an alert badge
  /// elsewhere in the app. Updates the filter on this already-mounted
  /// screen (kept alive by the tab shell's IndexedStack) instead of
  /// pushing/replacing a route.
  void applyFilter({String? device, String? category}) {
    setState(() {
      _activeDevice = device ?? 'All Devices';
      _activeCategory = category ?? 'All Types';
      _activeDate = kDateAny;
      _customRange = null;
      _alertsOnly = false;
    });
    _refreshNewest();
    _fillForFilter();
  }

  /// Called when the user taps a push notification: show every log, open this one.
  void openLog(String logId) {
    setState(() {
      _activeDevice = 'All Devices';
      _activeCategory = 'All Types';
      _activeDate = kDateAny;
      _customRange = null;
      _alertsOnly = false;
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
        activeDate: _activeDate,
        customRange: _customRange,
      ),
    );

    if (result != null) {
      final from = DateTime.tryParse(result['rangeFrom'] ?? '');
      final to = DateTime.tryParse(result['rangeTo'] ?? '');
      setState(() {
        _activeDevice = result['activeDevice'] ?? _activeDevice;
        _activeCategory = result['activeCategory'] ?? _activeCategory;
        _activeDate = result['activeDate'] ?? _activeDate;
        _customRange = (from != null && to != null) ? DateTimeRange(start: from, end: to) : null;
      });
      _fillForFilter();
    }
  }

  @override
  Widget build(BuildContext context) {
    final filteredLogs = _filteredLogs;
    final items = _buildItems(filteredLogs);
    WidgetsBinding.instance.addPostFrameCallback((_) => _markDisplayedRead());

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

            // Quick filter: All / Alerts (a plain filter, no count)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Row(
                children: [
                  _QuickChip(
                    label: 'All',
                    selected: !_alertsOnly,
                    onTap: () => setState(() => _alertsOnly = false),
                  ),
                  const SizedBox(width: 8),
                  _QuickChip(
                    label: 'Alerts',
                    selected: _alertsOnly,
                    onTap: () {
                      setState(() => _alertsOnly = true);
                      _fillForFilter();
                    },
                  ),
                ],
              ),
            ),

            if (_loadError != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF2F2),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.alert),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(_loadError!,
                          style: const TextStyle(fontSize: 13, color: AppColors.alert)),
                    ),
                    TextButton(
                      onPressed: _fetchLogs,
                      child: const Text('Retry',
                          style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.alert)),
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
                              Center(
                                child: Text(
                                  _alertsOnly && _activeCategory == 'All Types' && _activeDevice == 'All Devices'
                                      ? 'No alerts found.'
                                      : 'No logs found for this filter combination.',
                                  style: const TextStyle(color: AppColors.textSub, fontSize: 14),
                                ),
                              ),
                              Center(
                                child: TextButton(
                                  onPressed: _clearFilters,
                                  child: const Text('Clear Filters',
                                      style: TextStyle(
                                          color: AppColors.primary, fontWeight: FontWeight.bold, fontSize: 16)),
                                ),
                              ),
                              if (_loadingMore)
                                const Padding(
                                  padding: EdgeInsets.only(top: 10),
                                  child: Center(child: CircularProgressIndicator(color: AppColors.primary)),
                                )
                              else if (_hasMore)
                                Center(
                                  child: TextButton(
                                    onPressed: _loadMore,
                                    child: const Text('Search older logs',
                                        style: TextStyle(color: AppColors.primary)),
                                  ),
                                ),
                            ],
                          )
                        : NotificationListener<ScrollNotification>(
                            onNotification: (n) {
                              // Near the bottom: quietly load the next older page.
                              if (n.depth == 0 && n.metrics.extentAfter < 400) _loadMore();
                              return false;
                            },
                            child: ListView.builder(
                              padding: const EdgeInsets.fromLTRB(20, 20, 20, 60),
                              itemCount: items.length + 1,
                              itemBuilder: (context, index) {
                                if (index == items.length) return _footer();
                                final item = items[index];
                                if (item is _Header) return _SectionHeader(header: item);
                                final log = item as LogModel;
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
            ),
          ],
        ),
      ),
    );
  }

  /// Bottom of the list: spinner while loading, a button when there are
  /// older logs, and a quiet note at the very end of the history.
  Widget _footer() {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator(color: AppColors.primary)),
      );
    }
    if (_hasMore) {
      return Center(
        child: TextButton(
          onPressed: _loadMore,
          child: const Text('Load older logs',
              style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold)),
        ),
      );
    }
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text('No older logs', style: TextStyle(fontSize: 12, color: AppColors.textSub)),
      ),
    );
  }
}

class _Header {
  final String label;
  final int count;
  final bool isSos;
  const _Header(this.label, this.count, {this.isSos = false});
}

class _SectionHeader extends StatelessWidget {
  final _Header header;
  const _SectionHeader({required this.header});

  @override
  Widget build(BuildContext context) {
    final color = header.isSos ? AppColors.alert : AppColors.textSub;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 10),
      child: Row(
        children: [
          if (header.isSos) ...[
            Icon(Icons.push_pin, size: 14, color: color),
            const SizedBox(width: 6),
          ],
          Text(header.label.toUpperCase(),
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                  color: color)),
          const SizedBox(width: 8),
          Text('${header.count}', style: TextStyle(fontSize: 12, color: color)),
        ],
      ),
    );
  }
}

class _QuickChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _QuickChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? AppColors.primary : AppColors.border),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: selected ? Colors.white : AppColors.textMain)),
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
          color: log.isSos ? const Color(0xFFFEF2F2) : AppColors.card,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: log.isSos
                ? AppColors.alert
                : (expanded ? log.color.withOpacity(0.5) : AppColors.border),
            width: log.isSos ? 1.5 : 1,
          ),
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
