import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../models/geo_point.dart';
import '../../models/route_model.dart';
import '../../services/nav_engine.dart' show spokenManeuver;
import '../../services/route_service.dart';
import '../../services/walk_controller.dart';
import '../../theme/app_colors.dart';
import 'route_widgets.dart';

/// The cane user's walking screen. The walk itself runs in the background
/// service (voice guidance keeps working with the screen off); this screen
/// shows it, repeats instructions and ends the walk.
///
/// Leaving the screen does NOT end the walk. Open the route list again to come
/// back to it.
class WalkScreen extends StatefulWidget {
  final String deviceId;
  final String routeId;
  final String routeName;

  const WalkScreen({
    super.key,
    required this.deviceId,
    required this.routeId,
    required this.routeName,
  });

  @override
  State<WalkScreen> createState() => _WalkScreenState();
}

class _WalkScreenState extends State<WalkScreen> {
  final _walk = WalkController();
  GoogleMapController? _map;

  WalkPlan? _plan; // the line on the map (old route path, or this walk's plan)
  bool _loadingPlan = false;
  String? _startError;
  bool _starting = true;
  bool _ending = false;
  bool _following = true;
  late String _routeId = widget.routeId;

  @override
  void initState() {
    super.initState();
    _walk.addListener(_onWalk);
    _boot();
  }

  @override
  void dispose() {
    _walk.removeListener(_onWalk);
    _walk.dispose();
    _map?.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    setState(() {
      _starting = true;
      _startError = null;
    });

    // Already walking (for example after leaving this screen)? Show that walk.
    final running = await _walk.currentWalk();
    if (!mounted) return;
    if (running != null) {
      _routeId = (running['route_id'] ?? widget.routeId).toString();
      await _loadRoute();
      if (!mounted) return;
      setState(() => _starting = false);
      return;
    }

    await _loadRoute();
    final err = await _walk.begin(deviceId: widget.deviceId, routeId: widget.routeId);
    if (!mounted) return;
    setState(() {
      _starting = false;
      _startError = err;
    });
  }

  /// Old routes carry their own path; a destination route gets its line from
  /// the plan the phone makes when the walk starts (see [_onWalk]).
  Future<void> _loadRoute() async {
    if (_loadingPlan) return;
    _loadingPlan = true;
    try {
      final r = await RouteService.instance.fetchRoute(_routeId);
      WalkPlan? p;
      if (r != null && r.hasGeometry) {
        p = WalkPlan(
            path: r.path,
            steps: r.steps,
            distanceM: r.distanceM,
            durationS: r.durationS,
            endLabel: r.endLabel);
      } else if (_walk.state['plan_ready'] == true) {
        final sid = _walk.state['session_id']?.toString();
        if (sid != null) {
          p = await RouteService.instance
              .fetchSessionPlan(sid, endLabel: r?.endLabel ?? '');
        }
      }
      if (mounted && p != null && p.hasPath) setState(() => _plan = p);
    } catch (_) {
    } finally {
      _loadingPlan = false;
    }
  }

  void _onWalk() {
    if (!mounted) return;
    setState(() {});
    if (_plan == null && _walk.state['plan_ready'] == true) _loadRoute();
    if (_following && _walk.isActive) _moveCamera();
  }

  void _moveCamera() {
    final lat = (_walk.state['lat'] as num?)?.toDouble();
    final lng = (_walk.state['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return;
    _map?.animateCamera(CameraUpdate.newLatLng(LatLng(lat, lng)));
  }

  Future<void> _confirmEnd() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End this walk?'),
        content: const Text('Your guardian will be told the walk was cancelled.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep walking')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('End walk', style: TextStyle(color: AppColors.alert)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _ending = true);
    _walk.end();
  }

  // ---- UI ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final name = (_walk.state['route_name']?.toString().isNotEmpty ?? false)
        ? _walk.state['route_name'].toString()
        : widget.routeName;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.card,
        elevation: 0,
        foregroundColor: AppColors.textMain,
        title: Text(name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_starting) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Starting your walk...', style: TextStyle(color: AppColors.textSub, fontSize: 16)),
          ],
        ),
      );
    }
    if (_startError != null) {
      return _message(
        icon: Icons.error_outline,
        color: AppColors.alert,
        title: 'The walk did not start',
        text: _startError!,
        actions: [
          ElevatedButton(onPressed: _boot, child: const Text('Try again')),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
        ],
      );
    }
    switch (_walk.phase) {
      case 'arrived':
        return _message(
          icon: Icons.flag,
          color: AppColors.success,
          title: 'You have arrived',
          text: 'Your guardian has been told you arrived safely.',
          actions: [ElevatedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done'))],
        );
      case 'cancelled':
        return _message(
          icon: Icons.stop_circle_outlined,
          color: AppColors.textSub,
          title: 'Walk ended',
          text: 'The walk was cancelled.',
          actions: [ElevatedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done'))],
        );
      case 'ended':
        return _message(
          icon: Icons.info_outline,
          color: AppColors.warning,
          title: 'This walk has ended',
          text: 'It was closed, for example after a long time without a signal.',
          actions: [ElevatedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done'))],
        );
      case 'error':
        return _message(
          icon: Icons.error_outline,
          color: AppColors.alert,
          title: 'The walk stopped',
          text: (_walk.state['error'] ?? 'Something went wrong.').toString(),
          actions: [ElevatedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
        );
    }
    return _walking();
  }

  Widget _message({
    required IconData icon,
    required Color color,
    required String title,
    required String text,
    required List<Widget> actions,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 72, color: color),
            const SizedBox(height: 16),
            Semantics(
              liveRegion: true,
              child: Text(title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: AppColors.textMain)),
            ),
            const SizedBox(height: 8),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15, color: AppColors.textSub, height: 1.4)),
            const SizedBox(height: 20),
            ...actions,
          ],
        ),
      ),
    );
  }

  Widget _walking() {
    final s = _walk.state;
    final off = s['off_route'] == true;
    final weak = s['weak_gps'] == true;
    final wrong = s['wrong_way'] == true;
    final leg = (s['leg'] ?? 'route').toString();
    final planning = s['planning'] == true;
    final phase = _walk.phase;
    final progress = (s['progress_m'] as num?)?.toInt() ?? 0;
    final total = (s['total_m'] as num?)?.toInt() ?? 0;
    final remaining = (s['remaining_m'] as num?)?.toInt() ?? 0;
    final frac = total <= 0 ? 0.0 : (progress / total).clamp(0.0, 1.0).toDouble();

    String headline;
    String? sub;
    IconData icon;
    Color color = AppColors.primary;

    if (phase == 'preparing') {
      final stage = (s['stage'] ?? '').toString();
      headline = stage == 'planning'
          ? 'Planning your route...'
          : stage == 'locating'
              ? 'Finding your location...'
              : 'Waiting for GPS...';
      icon = stage == 'planning' ? Icons.route : Icons.gps_not_fixed;
      color = AppColors.textSub;
    } else if (off) {
      headline = wrong ? 'Wrong way. Turn around.' : 'You are off the route';
      icon = wrong ? Icons.u_turn_left : Icons.wrong_location;
      color = AppColors.alert;
    } else if (phase == 'toStart' && leg != 'to_start') {
      headline = planning ? 'Finding the way to the start...' : 'Go to the start of the route';
      icon = Icons.near_me;
      color = AppColors.warning;
    } else {
      final m = (s['next_maneuver'] ?? Maneuver.straight).toString();
      final d = (s['dist_to_next_m'] as num?)?.toInt();
      icon = maneuverIcon(m);
      if (m == Maneuver.arrive) {
        headline = 'Destination';
      } else {
        final w = spokenManeuver(m);
        headline = w[0].toUpperCase() + w.substring(1);
      }
      if (d != null) sub = 'in ${formatDistance(d)}';
      if (leg == 'to_start') {
        sub = 'Walking to the start of the route${sub == null ? '' : ' - $sub'}';
      } else if (leg == 'rejoin') {
        sub = 'Walking back to the route${sub == null ? '' : ' - $sub'}';
      }
    }

    final canGuideBack = (off || (phase == 'toStart' && leg != 'to_start')) && !planning && leg == 'route';

    return Column(
      children: [
        Expanded(flex: 4, child: _mapView()),
        Expanded(
          flex: 6,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: color.withOpacity(0.5), width: 2),
                  ),
                  child: Row(
                    children: [
                      Icon(icon, size: 52, color: color),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Semantics(
                          liveRegion: true,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(headline,
                                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color)),
                              if (sub != null)
                                Text(sub,
                                    style: const TextStyle(fontSize: 16, color: AppColors.textMain)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: frac,
                    minHeight: 10,
                    backgroundColor: AppColors.border,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(height: 6),
                Text('${formatDistance(remaining)} to go',
                    style: const TextStyle(fontSize: 14, color: AppColors.textSub)),
                if (weak) ...[
                  const SizedBox(height: 10),
                  _chip(Icons.signal_cellular_connected_no_internet_0_bar, 'GPS signal is weak', AppColors.warning),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  height: 56,
                  child: ElevatedButton.icon(
                    onPressed: _walk.repeat,
                    icon: const Icon(Icons.volume_up),
                    label: const Text('Repeat instruction', style: TextStyle(fontSize: 17)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
                if (canGuideBack) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 52,
                    child: OutlinedButton.icon(
                      onPressed: _walk.guideBack,
                      icon: const Icon(Icons.near_me),
                      label: Text(phase == 'toStart' ? 'Guide me to the start' : 'Guide me back to the route',
                          style: const TextStyle(fontSize: 16)),
                      style: OutlinedButton.styleFrom(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                SizedBox(
                  height: 52,
                  child: OutlinedButton.icon(
                    onPressed: _ending ? null : _confirmEnd,
                    icon: const Icon(Icons.stop_circle_outlined, color: AppColors.alert),
                    label: const Text('End walk',
                        style: TextStyle(fontSize: 16, color: AppColors.alert)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppColors.alert),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Voice guidance keeps working with the screen off. The walk also keeps going if you leave this screen.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: AppColors.textSub, height: 1.4),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _chip(IconData icon, String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color)),
          ],
        ),
      );

  Widget _mapView() {
    final r = _plan;
    final lat = (_walk.state['lat'] as num?)?.toDouble();
    final lng = (_walk.state['lng'] as num?)?.toDouble();
    final here = (lat != null && lng != null) ? LatLng(lat, lng) : null;
    final first = r != null && r.path.isNotEmpty ? r.path.first : const GeoPoint(0, 0);
    LatLng ll(GeoPoint p) => LatLng(p.lat, p.lng);

    return Stack(
      children: [
        GoogleMap(
          initialCameraPosition: CameraPosition(target: here ?? ll(first), zoom: 17),
          onMapCreated: (c) => _map = c,
          polylines: {
            if (r != null && r.path.length >= 2)
              Polyline(
                polylineId: const PolylineId('route'),
                points: r.path.map(ll).toList(),
                width: 6,
                color: AppColors.primary,
              ),
          },
          markers: {
            if (r != null && r.path.length >= 2)
              Marker(
                markerId: const MarkerId('end'),
                position: ll(r.path.last),
                icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
              ),
            if (here != null)
              Marker(
                markerId: const MarkerId('me'),
                position: here,
                icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
              ),
          },
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
          mapToolbarEnabled: false,
        ),
        Positioned(
          right: 12,
          bottom: 12,
          child: FloatingActionButton.small(
            heroTag: 'walk_recenter',
            backgroundColor: AppColors.card,
            foregroundColor: AppColors.primary,
            onPressed: () {
              setState(() => _following = !_following);
              if (_following) _moveCamera();
            },
            child: Icon(_following ? Icons.my_location : Icons.location_searching),
          ),
        ),
      ],
    );
  }
}
