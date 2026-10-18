import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../models/route_model.dart';
import '../../services/route_service.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_colors.dart';
import 'destination_editor_screen.dart';
import 'route_editor_screen.dart';
import 'route_widgets.dart';
import 'live_walk_screen.dart';
import 'walk_history_screen.dart';
import 'walk_screen.dart';

/// Route arguments: { 'id': String, 'name': String?, 'lat': double?, 'lng': double? }
///
/// Lists the saved walking routes of one cane.
///  * Guardians, solo owners (and the cane user, when the guardian allows it)
///    can add, edit and delete routes.
///  * Everyone linked to the cane can open a route to read its steps.
///  * The guardian of a linked cane user sees a switch that lets that user
///    manage routes too.
class RoutesScreen extends StatefulWidget {
  final String deviceId;
  final String? deviceName;
  final double? lat;
  final double? lng;

  const RoutesScreen({
    super.key,
    required this.deviceId,
    this.deviceName,
    this.lat,
    this.lng,
  });

  @override
  State<RoutesScreen> createState() => _RoutesScreenState();
}

class _RoutesScreenState extends State<RoutesScreen> {
  final _service = RouteService.instance;

  List<RouteModel> _routes = [];
  bool _loading = true;
  String? _error;
  bool _canManage = false;
  bool _isGuardianOfUser = false; // guardian of a separate cane user
  bool _canWalk = false; // I carry this cane, so I can start walks
  RouteSession? _activeWalk; // my walk in progress, if any
  bool _allowUserRoutes = false;
  bool _toggleBusy = false;

  String get _deviceName =>
      widget.deviceName?.isNotEmpty == true ? widget.deviceName! : 'Cane';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _service.fetchRoutes(widget.deviceId),
        _service.canManageRoutes(widget.deviceId),
        _service.fetchAllowUserRoutes(widget.deviceId),
        _loadRole(),
        _loadActiveWalk(),
      ]);
      if (!mounted) return;
      setState(() {
        _routes = results[0] as List<RouteModel>;
        _canManage = results[1] as bool;
        _allowUserRoutes = results[2] as bool;
        final role = results[3] as (bool, bool);
        _isGuardianOfUser = role.$1;
        _canWalk = role.$2;
        _activeWalk = results[4] as RouteSession?;
        _loading = false;
      });
    } on RouteException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  /// True when I am the guardian and the cane has a different person as its
  /// user (so the "let the user manage routes" switch makes sense).
  ///
  /// Returns (guardianOfSeparateUser, iCarryTheCane). Only the person who
  /// carries the cane can start a walk (the server checks this too).
  Future<(bool, bool)> _loadRole() async {
    try {
      final row = await SupabaseService.instance.fetchCaneUser(widget.deviceId);
      final me = Supabase.instance.client.auth.currentUser?.id;
      if (row == null || me == null) return (false, false);
      final guardian = row['guardian_id']?.toString();
      final user = row['user_id']?.toString();
      return (guardian == me && user != null && user != guardian, user == me);
    } catch (_) {
      return (false, false);
    }
  }

  /// The walk in progress on this cane, if any (anyone linked can watch it).
  Future<RouteSession?> _loadActiveWalk() async {
    try {
      return await _service.fetchActiveSession(widget.deviceId);
    } catch (_) {
      return null;
    }
  }

  /// The walker returns to the walking screen; everyone else watches live.
  Future<void> _openActive(RouteSession s) async {
    final me = Supabase.instance.client.auth.currentUser?.id;
    if (_canWalk && s.startedBy == me) {
      await _openWalk(s.routeId, s.routeName);
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => LiveWalkScreen(
          deviceId: widget.deviceId,
          deviceName: widget.deviceName,
        ),
      ),
    );
    if (mounted) _load();
  }

  void _openHistory() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => WalkHistoryScreen(
          deviceId: widget.deviceId,
          deviceName: widget.deviceName,
        ),
      ),
    );
  }

  Future<void> _openWalk(String routeId, String routeName) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => WalkScreen(
          deviceId: widget.deviceId,
          routeId: routeId,
          routeName: routeName,
        ),
      ),
    );
    if (mounted) _load();
  }

  /// New routes (and edits of destination routes) use the destination-only
  /// editor; only old routes with a fixed start and path open the old one.
  Future<void> _openEditor({RouteModel? route}) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => (route == null || route.isDestination)
            ? DestinationEditorScreen(
                deviceId: widget.deviceId,
                deviceName: widget.deviceName,
                lat: widget.lat,
                lng: widget.lng,
                routeId: route?.id,
              )
            : RouteEditorScreen(
                deviceId: widget.deviceId,
                deviceName: widget.deviceName,
                lat: widget.lat,
                lng: widget.lng,
                routeId: route.id,
              ),
      ),
    );
    if (saved == true) _load();
  }

  Future<void> _setAllow(bool v) async {
    if (_toggleBusy) return;
    setState(() {
      _toggleBusy = true;
      _allowUserRoutes = v;
    });
    try {
      await _service.setAllowUserRoutes(widget.deviceId, v);
    } on RouteException catch (e) {
      if (!mounted) return;
      setState(() => _allowUserRoutes = !v);
      await showRouteAlert(context, 'Could not change this', e.message);
    }
    if (mounted) setState(() => _toggleBusy = false);
  }

  Future<void> _delete(RouteModel r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete route?'),
        content: Text('"${r.name}" will be removed. Past walks stay in the history.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: AppColors.alert)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _service.deleteRoute(r.id);
      if (mounted) _load();
    } on RouteException catch (e) {
      if (!mounted) return;
      await showRouteAlert(
        context,
        'Could not delete',
        e.code == '55006'
            ? 'A walk is in progress on this route. Finish or cancel it first.'
            : e.message,
      );
    }
  }

  Future<void> _showDetails(RouteModel summary) async {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _RouteDetailsSheet(
        summary: summary,
        canManage: _canManage,
        onStart: _canWalk
            ? () {
                Navigator.of(context).pop();
                _openWalk(summary.id, summary.name);
              }
            : null,
        onEdit: () {
          Navigator.of(context).pop();
          _openEditor(route: summary);
        },
        onDelete: () {
          Navigator.of(context).pop();
          _delete(summary);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.card,
        elevation: 0,
        foregroundColor: AppColors.textMain,
        title: Text('$_deviceName routes',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        actions: [
          IconButton(
            tooltip: 'Walk history',
            icon: const Icon(Icons.history),
            onPressed: _openHistory,
          ),
        ],
      ),
      floatingActionButton: _canManage
          ? FloatingActionButton.extended(
              onPressed: () => _openEditor(),
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add),
              label: const Text('New route'),
            )
          : null,
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textSub)),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
        children: [
          if (_activeWalk != null) _walkBanner(_activeWalk!),
          if (_isGuardianOfUser) _allowCard(),
          if (_routes.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 60),
              child: Column(
                children: [
                  const Icon(Icons.route, size: 56, color: Color(0xFFCBD5E1)),
                  const SizedBox(height: 12),
                  Text(
                    _canManage
                        ? 'No routes yet. Tap "New route" to make the first one.'
                        : 'No routes yet. A guardian can add them.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.textSub, fontSize: 15),
                  ),
                ],
              ),
            ),
          for (final r in _routes) _routeCard(r),
        ],
      ),
    );
  }

  Widget _walkBanner(RouteSession s) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: AppColors.primary.withOpacity(0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.directions_walk, color: AppColors.primary, size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.offRoute ? 'Walk in progress - off route' : 'Walk in progress',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: s.offRoute ? AppColors.alert : AppColors.primary)),
                Text(s.routeName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: AppColors.textMain)),
              ],
            ),
          ),
          ElevatedButton(
            onPressed: () => _openActive(s),
            child: Text(_canWalk && s.startedBy == Supabase.instance.client.auth.currentUser?.id
                ? 'Open'
                : 'Watch live'),
          ),
        ],
      ),
    );
  }

  Widget _allowCard() {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: AppColors.border),
      ),
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _allowUserRoutes,
        onChanged: _toggleBusy ? null : _setAllow,
        title: const Text('Let the cane user make routes',
            style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.textMain)),
        subtitle: const Text('They can add, edit and delete routes themselves.',
            style: TextStyle(fontSize: 12, color: AppColors.textSub)),
      ),
    );
  }

  Widget _routeCard(RouteModel r) {
    final from = r.isDestination || r.startLabel.isEmpty ? null : r.startLabel;
    final to = r.endLabel.isNotEmpty ? r.endLabel : null;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: AppColors.border),
      ),
      child: InkWell(
        onTap: () => _showDetails(r),
        borderRadius: BorderRadius.circular(15),
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFFE0F2FE),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.route, color: AppColors.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textMain)),
                    if (r.isDestination && to != null) ...[
                      const SizedBox(height: 2),
                      Text('To $to',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: AppColors.textSub)),
                    ] else if (from != null && to != null) ...[
                      const SizedBox(height: 2),
                      Text('$from to $to',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: AppColors.textSub)),
                    ],
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Flexible(
                          child: Text(r.summaryText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textSub)),
                        ),
                        const SizedBox(width: 8),
                        SourceBadge(drawn: r.isDrawn, destination: r.isDestination),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.border),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens one route (loads the full steps) with Edit / Delete when allowed.
class _RouteDetailsSheet extends StatefulWidget {
  final RouteModel summary;
  final bool canManage;
  final VoidCallback? onStart; // null unless I carry this cane
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _RouteDetailsSheet({
    required this.summary,
    required this.canManage,
    required this.onStart,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<_RouteDetailsSheet> createState() => _RouteDetailsSheetState();
}

class _RouteDetailsSheetState extends State<_RouteDetailsSheet> {
  RouteModel? _full;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadFull();
  }

  Future<void> _loadFull() async {
    try {
      final r = await RouteService.instance.fetchRoute(widget.summary.id);
      if (!mounted) return;
      setState(() {
        _full = r;
        if (r == null) _error = 'This route no longer exists.';
      });
    } on RouteException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.summary;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.65,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      builder: (_, controller) => Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.name,
                          style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textMain)),
                      const SizedBox(height: 4),
                      Text(
                          r.isDestination && r.endLabel.isNotEmpty
                              ? 'To ${r.endLabel}'
                              : r.summaryText,
                          style: const TextStyle(fontSize: 13, color: AppColors.textSub)),
                    ],
                  ),
                ),
                if (widget.canManage) ...[
                  IconButton(
                    tooltip: 'Edit',
                    icon: const Icon(Icons.edit, color: AppColors.primary),
                    onPressed: widget.onEdit,
                  ),
                  IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline, color: AppColors.alert),
                    onPressed: widget.onDelete,
                  ),
                ],
              ],
            ),
          ),
          if (widget.onStart != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: _full == null ? null : widget.onStart,
                  icon: const Icon(Icons.directions_walk),
                  label: const Text('Start walk', style: TextStyle(fontSize: 17)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ),
          const Divider(height: 1, color: AppColors.border),
          Expanded(
            child: _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(_error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppColors.textSub)),
                    ),
                  )
                : _full == null
                    ? const Center(child: CircularProgressIndicator())
                    : r.isDestination
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Text(
                                'The walking route is planned from wherever the cane user is when the walk starts.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: AppColors.textSub, fontSize: 15, height: 1.4),
                              ),
                            ),
                          )
                        : StepsList(steps: _full!.steps, controller: controller),
          ),
        ],
      ),
    );
  }
}
