import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../models/geo_point.dart';
import '../../models/route_model.dart';
import '../../services/nav_engine.dart' show spokenManeuver;
import '../../services/route_service.dart';
import '../../theme/app_colors.dart';
import 'route_widgets.dart';

/// Guardian's (or any linked person's) view of a walk.
///  * No [sessionId]: follows the walk in progress on the cane. If none is
///    running it waits, and the walk appears as soon as one starts.
///  * With [sessionId]: shows that one walk (used by the history list); it
///    keeps updating only while that walk is active.
///
/// Updates arrive by Supabase realtime, with a 10 second refresh as a backup
/// (realtime can be off for the table, or drop on a weak connection).
class LiveWalkScreen extends StatefulWidget {
  final String deviceId;
  final String? deviceName;
  final String? sessionId;

  const LiveWalkScreen({
    super.key,
    required this.deviceId,
    this.deviceName,
    this.sessionId,
  });

  @override
  State<LiveWalkScreen> createState() => _LiveWalkScreenState();
}

class _LiveWalkScreenState extends State<LiveWalkScreen> {
  final _service = RouteService.instance;

  RouteSession? _session;
  WalkPlan? _route; // the line and steps of this walk
  String? _planLoadedFor; // session id whose plan is loaded
  DateTime? _planTriedAt;
  String? _error;
  bool _loading = true;
  bool _following = true;

  RealtimeChannel? _channel;
  Timer? _poll;
  GoogleMapController? _map;

  @override
  void initState() {
    super.initState();
    _refresh(first: true);
    if (widget.sessionId == null) {
      _channel = _service.subscribeToSessions(widget.deviceId, _onRealtime);
    }
    _poll = Timer.periodic(const Duration(seconds: 10), (_) {
      final s = _session;
      // A finished walk does not change; a missing one may start any time.
      if (widget.sessionId == null || s == null || s.isActive) _refresh();
      if (mounted) setState(() {}); // keeps "not reporting" fresh
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    if (_channel != null) _service.unsubscribe(_channel!);
    _map?.dispose();
    super.dispose();
  }

  void _onRealtime(RouteSession? s) {
    if (!mounted) return;
    if (s == null) {
      _refresh();
      return;
    }
    final cur = _session;
    // Follow the active walk; also accept the end of the walk we are showing.
    if (s.isActive || (cur != null && cur.id == s.id)) _apply(s);
  }

  Future<void> _refresh({bool first = false}) async {
    try {
      final s = widget.sessionId != null
          ? await _service.fetchSession(widget.sessionId!)
          : await _service.fetchActiveSession(widget.deviceId);
      if (!mounted) return;
      // Walk just ended and we were showing it: fetch its final row.
      if (s == null && _session != null && widget.sessionId == null) {
        final fin = await _service.fetchSession(_session!.id);
        if (!mounted) return;
        _apply(fin ?? _session!);
      } else {
        _apply(s);
      }
      if (first || _error != null) setState(() => _error = null);
    } on RouteException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  void _apply(RouteSession? s) {
    setState(() {
      _session = s;
      _loading = false;
    });
    if (s != null) {
      _loadPlan(s);
      if (_following && s.isActive) _moveCamera();
    }
  }

  /// Loads the line of this walk: its own plan (destination routes) or the
  /// saved route's path (old routes). The plan appears a few seconds after the
  /// walk starts, so an active walk without one is checked again later.
  Future<void> _loadPlan(RouteSession s) async {
    if (_planLoadedFor == s.id) return;
    final now = DateTime.now();
    if (_planTriedAt != null &&
        now.difference(_planTriedAt!) < const Duration(seconds: 4)) {
      return;
    }
    _planTriedAt = now;
    try {
      final p = await _service.fetchWalkPlan(s);
      if (!mounted) return;
      if (p != null) {
        _planLoadedFor = s.id;
        setState(() => _route = p);
      }
    } catch (_) {
      // try again on the next update
    }
  }

  void _moveCamera() {
    final p = _session?.lastPoint;
    if (p == null) return;
    _map?.animateCamera(CameraUpdate.newLatLng(LatLng(p.lat, p.lng)));
  }

  // ---- UI ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final name = widget.deviceName?.isNotEmpty == true ? widget.deviceName! : 'Cane';
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.card,
        elevation: 0,
        foregroundColor: AppColors.textMain,
        title: Text(_session?.routeName.isNotEmpty == true ? _session!.routeName : '$name walk',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final s = _session;
    if (s == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.directions_walk, size: 64, color: Color(0xFFCBD5E1)),
              const SizedBox(height: 12),
              Text(
                _error ?? 'No walk in progress. This page updates by itself when a walk starts.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSub, fontSize: 15),
              ),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: () => _refresh(first: true), child: const Text('Refresh')),
            ],
          ),
        ),
      );
    }

    final steps = _route?.steps ?? const <RouteStep>[];
    final cs = s.currentStep;
    final next = (cs + 1 < steps.length) ? steps[cs + 1] : null;

    return Column(
      children: [
        _statusBanner(s),
        Expanded(flex: 5, child: _mapView(s)),
        Expanded(
          flex: 4,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: s.fraction,
                  minHeight: 10,
                  backgroundColor: AppColors.border,
                  color: s.offRoute ? AppColors.alert : AppColors.primary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${formatDistance(s.progressM)} of ${formatDistance(s.totalM)}'
                '  -  ${(s.fraction * 100).round()}%',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textMain),
              ),
              const SizedBox(height: 4),
              Text(_timesText(s), style: const TextStyle(fontSize: 12, color: AppColors.textSub)),
              if (s.isActive && next != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    children: [
                      Icon(maneuverIcon(next.maneuver), color: AppColors.primary, size: 30),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Next',
                                style: TextStyle(fontSize: 12, color: AppColors.textSub)),
                            Text(
                              next.text.isNotEmpty ? next.text : spokenManeuver(next.maneuver),
                              style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textMain),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (steps.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text('Steps',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textMain)),
                const SizedBox(height: 4),
                for (var i = 0; i < steps.length; i++) _stepRow(steps[i], i, cs, s.isActive),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _stepRow(RouteStep st, int i, int current, bool active) {
    final done = i < current || (!active && _session?.status == 'completed');
    final isNow = active && i == current;
    final color = done ? AppColors.success : (isNow ? AppColors.primary : AppColors.textSub);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(done ? Icons.check_circle : maneuverIcon(st.maneuver), size: 22, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(st.text.isNotEmpty ? st.text : spokenManeuver(st.maneuver),
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: isNow ? FontWeight.bold : FontWeight.normal,
                    color: done ? AppColors.textSub : AppColors.textMain)),
          ),
        ],
      ),
    );
  }

  String _timesText(RouteSession s) {
    final started = _clock(s.startedAt);
    if (s.isActive) {
      final ago = DateTime.now().difference(s.lastUpdate);
      return 'Started $started  -  updated ${_ago(ago)}';
    }
    final ended = s.endedAt != null ? ' - ended ${_clock(s.endedAt!)}' : '';
    return 'Started $started$ended';
  }

  String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _ago(Duration d) {
    if (d.inSeconds < 15) return 'just now';
    if (d.inMinutes < 1) return '${d.inSeconds} s ago';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    return '${d.inHours} h ago';
  }

  /// One line that says what matters most right now.
  Widget _statusBanner(RouteSession s) {
    String text;
    IconData icon;
    Color color;
    switch (s.status) {
      case 'completed':
        text = 'Arrived safely';
        icon = Icons.flag;
        color = AppColors.success;
        break;
      case 'cancelled':
        text = 'Walk was cancelled';
        icon = Icons.stop_circle_outlined;
        color = AppColors.textSub;
        break;
      case 'expired':
        text = 'Walk closed after no signal';
        icon = Icons.signal_wifi_off;
        color = AppColors.warning;
        break;
      default:
        if (s.isStale) {
          text = 'Not reporting for ${_ago(DateTime.now().difference(s.lastUpdate)).replaceAll(' ago', '')}. '
              'The phone may have no signal or be off.';
          icon = Icons.signal_cellular_connected_no_internet_0_bar;
          color = AppColors.warning;
        } else if (s.offRoute) {
          text = 'Off course - not on the planned route';
          icon = Icons.wrong_location;
          color = AppColors.alert;
        } else {
          text = 'On route';
          icon = Icons.directions_walk;
          color = AppColors.success;
        }
    }
    return Container(
      width: double.infinity,
      color: color.withOpacity(0.12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(text,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _mapView(RouteSession s) {
    final r = _route;
    LatLng ll(GeoPoint p) => LatLng(p.lat, p.lng);
    final here = s.lastPoint;
    final center = here != null
        ? ll(here)
        : (r != null && r.path.isNotEmpty ? ll(r.path.first) : const LatLng(0, 0));
    final off = s.offRoute && s.isActive;

    return Stack(
      children: [
        GoogleMap(
          initialCameraPosition: CameraPosition(target: center, zoom: 17),
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
                infoWindow: InfoWindow(title: r.endLabel.isNotEmpty ? r.endLabel : 'Destination'),
                icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
              ),
            if (here != null)
              Marker(
                markerId: const MarkerId('walker'),
                position: ll(here),
                icon: BitmapDescriptor.defaultMarkerWithHue(
                    off ? BitmapDescriptor.hueRed : BitmapDescriptor.hueAzure),
              ),
          },
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
          mapToolbarEnabled: false,
        ),
        if (s.isActive)
          Positioned(
            right: 12,
            bottom: 12,
            child: FloatingActionButton.small(
              heroTag: 'live_follow',
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
