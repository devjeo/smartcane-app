import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../models/device_model.dart';
import '../../services/main_tab_controller.dart';
import '../../services/location_filter.dart' show haversineM;
import '../../services/supabase_service.dart';
import '../geofence_editor/geofence_editor_screen.dart' show GeofenceZone;
import 'trail_smoothing.dart';

const List<Color> kTrackColors = [
  Color(0xFF007BFF), Color(0xFFFF3B30), Color(0xFF34C759), Color(0xFFFF9500), Color(0xFFAF52DE),
  Color(0xFFFF2D55), Color(0xFF5856D6), Color(0xFFFFCC00), Color(0xFF00C7BE), Color(0xFF32ADE6),
];

class TripSession {
  final String id;
  final String label;
  final String dateStr;
  final String startTime;
  final String endTime;
  final Color color;
  final List<LatLng> coords;

  TripSession({
    required this.id,
    required this.label,
    required this.dateStr,
    required this.startTime,
    required this.endTime,
    required this.color,
    required this.coords,
  });
}

/// Route arguments:
/// { 'id': String, 'name': String?, 'lat': double?, 'lng': double?, 'userRole': String? }
class TrackerScreen extends StatefulWidget {
  final String deviceId;
  final String? deviceName;
  final double? lat;
  final double? lng;
  final String? userRole;

  const TrackerScreen({super.key, required this.deviceId, this.deviceName, this.lat, this.lng, this.userRole});

  @override
  State<TrackerScreen> createState() => _TrackerScreenState();
}

class _TrackerScreenState extends State<TrackerScreen>
    with SingleTickerProviderStateMixin {
  late LatLng _caneLocation;
  bool _hasLiveLocation = false;
  int _battery = 100;
  bool _isOnline = false;      // unknown until the first status read
  DateTime? _lastSeen;
  Timer? _statusTimer;

  List<TripSession> _trips = [];
  List<String> _activeTripIds = [];

  String? _activityStatus;       // devices.activity_status
  DateTime? _liveUpdatedAt;      // devices.last_updated (newest live position)
  DateTime? _lastHistoryAt;      // newest recorded history point
  List<GeofenceZone> _zones = [];
  static const _staleAfter = Duration(minutes: 5);

  String? _tappedTripId;
  String? _tappedTripText;
  Color? _tappedTripColor;
  bool _toastVisible = false;

  RealtimeChannel? _channel;
  GoogleMapController? _mapController;

  // ---- Smooth movement -------------------------------------------------
  // The pin glides from where it is to each new position instead of jumping.
  late final AnimationController _moveCtrl;
  final ValueNotifier<LatLng?> _shown = ValueNotifier<LatLng?>(null); // pin on screen
  LatLng? _animFrom;
  LatLng? _animTo;
  DateTime? _lastTargetAt;
  DateTime _lastTick = DateTime.fromMillisecondsSinceEpoch(0);
  bool _follow = false; // camera follows the pin
  DateTime _followIgnoreUntil = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _liveTimer; // tells the cane phone "a guardian is watching"
  final JumpGuard _jumpGuard = JumpGuard();

  // Drawn objects are cached so the map does not re-send them every frame.
  final Map<String, _SmoothedTrail> _smoothCache = {};
  Set<Polyline>? _polylineCache;
  String _polylineKey = '';
  Set<Polygon>? _polygonCache;
  List<GeofenceZone>? _polygonZones;

  String get _deviceName => widget.deviceName?.isNotEmpty == true ? widget.deviceName! : 'Smart Cane';

  @override
  void initState() {
    super.initState();
    _moveCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 1))
      ..addListener(_onMoveTick);
    _caneLocation = LatLng(widget.lat ?? 14.1153, widget.lng ?? 122.9566);
    _hasLiveLocation = widget.lat != null && widget.lng != null;
    _fetchInitialData();
    _loadZones();
    _subscribeToUpdates();
    _statusTimer = Timer.periodic(const Duration(seconds: 10), (_) => _refreshStatus());
    // Live mode: while this screen is open the cane phone reports every few
    // seconds. The window is short, so it closes by itself after we leave.
    _dbService.setLiveWatch(widget.deviceId, seconds: 75);
    _liveTimer = Timer.periodic(const Duration(seconds: 25),
        (_) => _dbService.setLiveWatch(widget.deviceId, seconds: 75));
  }

  final _dbService = SupabaseService.instance;

  @override
  void dispose() {
    _statusTimer?.cancel();
    _liveTimer?.cancel();
    _moveCtrl.dispose();
    _shown.dispose();
    if (_channel != null) _dbService.unsubscribe(_channel!);
    super.dispose();
  }

  Future<void> _fetchInitialData() async {
    final liveData = await _dbService.getDeviceLiveStatus(widget.deviceId);
    bool isActuallyOnline = false;

    if (liveData != null && mounted) {
      setState(() {
        if (liveData['latitude'] != null && liveData['longitude'] != null) {
          _caneLocation = LatLng((liveData['latitude'] as num).toDouble(), (liveData['longitude'] as num).toDouble());
          _hasLiveLocation = true;
        }
        _battery = liveData['battery_level'] ?? _battery;
        _liveUpdatedAt = _parseTime(liveData['last_updated']);
        _activityStatus = (liveData['activity_status'] as String?)?.trim();
      });
      _applyLastSeen(liveData['last_seen_at']);
      isActuallyOnline = _isOnline;
    }

    final historyData = await _dbService.getDeviceLocationHistory(widget.deviceId);

    if (historyData.isNotEmpty) {
      final rows = List<Map<String, dynamic>>.from(historyData).reversed.toList();
      final Map<String, List<LatLng>> coordsBySession = {};
      final Map<String, List<int>> timesBySession = {};

      for (final row in rows) {
        final sId = row['session_id']?.toString() ?? 'unknown';
        coordsBySession.putIfAbsent(sId, () => []);
        timesBySession.putIfAbsent(sId, () => []);
        coordsBySession[sId]!.add(LatLng((row['latitude'] as num).toDouble(), (row['longitude'] as num).toDouble()));
        timesBySession[sId]!.add(DateTime.parse(row['created_at']).millisecondsSinceEpoch);
      }

      final sessionKeys = coordsBySession.keys.toList().reversed.toList();
      final newestMs = timesBySession.values.expand((t) => t).reduce((a, b) => a > b ? a : b);

      final formattedTrips = <TripSession>[];
      for (int index = 0; index < sessionKeys.length; index++) {
        final key = sessionKeys[index];
        final times = timesBySession[key]!;
        final startDate = DateTime.fromMillisecondsSinceEpoch(times.reduce((a, b) => a < b ? a : b));
        final endDate = DateTime.fromMillisecondsSinceEpoch(times.reduce((a, b) => a > b ? a : b));
        final isLatest = index == 0;

        formattedTrips.add(TripSession(
          id: key,
          label: isLatest ? 'Current Live Session' : 'Past Walk',
          dateStr: _formatDate(startDate),
          startTime: _formatTime(startDate),
          endTime: isLatest && isActuallyOnline ? 'Now' : _formatTime(endDate),
          color: kTrackColors[index % kTrackColors.length],
          coords: TrailSmoothing.removeSpikes(coordsBySession[key]!, timesBySession[key]!),
        ));
      }

      if (mounted) {
        setState(() {
          _trips = formattedTrips;
          _lastHistoryAt = DateTime.fromMillisecondsSinceEpoch(newestMs);
          if (formattedTrips.isNotEmpty) _activeTripIds = [formattedTrips[0].id];
        });
        if (_hasRealLocation) {
          _jumpGuard.seed(_pinLocation, DateTime.now());
          _mapController?.animateCamera(CameraUpdate.newLatLng(_pinLocation));
        }
      }
    }
  }

  /// Online = the cane's own heartbeat (devices.last_seen_at) is recent.
  /// Same rule as the dashboard; the is_online column is not used.
  void _applyLastSeen(dynamic raw) {
    if (raw is String) _lastSeen = DateTime.tryParse(raw);
    _recomputeOnline();
  }

  void _recomputeOnline() {
    final online = _lastSeen != null &&
        DateTime.now().difference(_lastSeen!) < DeviceModel.onlineWindow;
    if (mounted && online != _isOnline) setState(() => _isOnline = online);
  }

  Future<void> _refreshStatus() async {
    _recomputeOnline();   // flips to Offline even if the poll below fails
    if (mounted) setState(() {});   // re-evaluates the stale-location banner
    try {
      final live = await _dbService.getDeviceLiveStatus(widget.deviceId);
      if (live == null || !mounted) return;
      _applyLastSeen(live['last_seen_at']);
      setState(() {
        if (live['battery_level'] != null) _battery = live['battery_level'];
        _liveUpdatedAt = _parseTime(live['last_updated']) ?? _liveUpdatedAt;
        _activityStatus = (live['activity_status'] as String?)?.trim();
      });
    } catch (_) {}
  }

  String _formatDate(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  String _formatTime(DateTime d) {
    final hour = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final period = d.hour >= 12 ? 'PM' : 'AM';
    final minute = d.minute.toString().padLeft(2, '0');
    return '$hour:$minute $period';
  }

  DateTime? _parseTime(dynamic raw) =>
      raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

  /// The danger / safe zones drawn in the geofence editor, shown as an overlay.
  Future<void> _loadZones() async {
    try {
      final raw = await _dbService.getGeofenceZones(widget.deviceId);
      final zones = <GeofenceZone>[];
      for (final z in raw ?? const []) {
        try {
          final zone = GeofenceZone.fromJson(Map<String, dynamic>.from(z as Map));
          if (zone.coordinates.length >= 3) zones.add(zone);
        } catch (_) {}   // skip a malformed zone instead of failing them all
      }
      if (mounted) setState(() => _zones = zones);
    } catch (_) {}
  }

  /// Newest sign of a real position: the live column or the last history point.
  DateTime? get _locationAt {
    final a = _liveUpdatedAt, b = _lastHistoryAt;
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  bool get _isStale {
    final t = _locationAt;
    return _hasRealLocation && t != null && DateTime.now().difference(t) > _staleAfter;
  }

  String _agoText(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  String get _activityText {
    final a = _activityStatus;
    if (a == null || a.isEmpty) return 'Unknown';
    return a
        .split(RegExp(r'[\s_]+'))
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join(' ');
  }

  void _subscribeToUpdates() {
    _channel = _dbService.subscribeToDeviceLocation(widget.deviceId, (newData) {
      if (newData['latitude'] != null && newData['longitude'] != null) {
        final newCoord = LatLng((newData['latitude'] as num).toDouble(), (newData['longitude'] as num).toDouble());
        // Safety net: ignore an impossible jump (the phone already filters).
        final accepted = _jumpGuard.accept(newCoord, DateTime.now());
        if (accepted) _animateTo(newCoord); // glide the pin (must run before the state change)
        if (accepted) setState(() {
          _caneLocation = newCoord;
          _hasLiveLocation = true;
          _liveUpdatedAt = _parseTime(newData['last_updated']) ?? DateTime.now();
          if (_trips.isNotEmpty) {
            final updated = List<TripSession>.from(_trips);
            final first = updated[0];
            updated[0] = TripSession(
              id: first.id,
              label: first.label,
              dateStr: first.dateStr,
              startTime: first.startTime,
              endTime: _isOnline ? 'Now' : first.endTime,
              color: first.color,
              coords: (first.coords.isNotEmpty && first.coords.last == newCoord)
                  ? first.coords // same position (heartbeat/battery update): no duplicate point
                  : [...first.coords, newCoord],
            );
            _trips = updated;
          }
        });
      }
      if (newData['battery_level'] != null) setState(() => _battery = newData['battery_level']);
      if (newData.containsKey('activity_status')) {
        setState(() => _activityStatus = (newData['activity_status'] as String?)?.trim());
      }
      if (newData['last_seen_at'] != null) _applyLastSeen(newData['last_seen_at']);
    });
  }

  void _toggleTrip(String tripId) {
    setState(() {
      if (_activeTripIds.contains(tripId)) {
        _activeTripIds = _activeTripIds.where((i) => i != tripId).toList();
      } else {
        _activeTripIds = [..._activeTripIds, tripId];
      }
    });
  }

  void _showTripToast(TripSession trip) {
    setState(() {
      _tappedTripId = trip.id;
      _tappedTripText = '${trip.dateStr} | ${trip.startTime} - ${trip.endTime}';
      _tappedTripColor = trip.color;
      _toastVisible = true;
    });
  }

  void _handleMapTap() {
    if (_tappedTripId != null) {
      setState(() => _toastVisible = false);
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) setState(() => _tappedTripId = null);
      });
    }
  }

  List<TripSession> get _activeTrips => _trips.where((t) => _activeTripIds.contains(t.id)).toList();

  /// Where the pin should sit: the live device location if we have one,
  /// otherwise the last recorded point from the most recent trip's line.
  LatLng get _pinLocation {
    if (_hasLiveLocation) return _caneLocation;
    if (_trips.isNotEmpty && _trips.first.coords.isNotEmpty) {
      return _trips.first.coords.last;
    }
    return _caneLocation;
  }

  /// The trail as the map draws it: spikes already removed at load time,
  /// then simplified and curved. Cached per trip until a point is added.
  List<LatLng> _smoothedCoords(TripSession trip) {
    final c = trip.coords;
    if (c.length < 3) return c;
    final cached = _smoothCache[trip.id];
    if (cached != null && cached.length == c.length && cached.last == c.last) {
      return cached.points;
    }
    final pts = TrailSmoothing.smoothTrail(c);
    _smoothCache[trip.id] = _SmoothedTrail(c.length, c.last, pts);
    return pts;
  }

  Set<Polyline> _buildPolylines() {
    final trips = _activeTrips;
    // The map is rebuilt ~30x per second while the pin glides, so identical
    // polylines must be the same objects (otherwise they are re-sent each frame).
    final key = trips
        .map((t) =>
            '${t.id}:${t.endTime}:${t.coords.length}:${t.coords.isEmpty ? '' : '${t.coords.last.latitude},${t.coords.last.longitude}'}')
        .join('|');
    if (_polylineCache != null && key == _polylineKey) return _polylineCache!;
    final set = trips
        .map((trip) => Polyline(
              polylineId: PolylineId(trip.id),
              points: _smoothedCoords(trip),
              color: trip.color,
              width: 5,
              jointType: JointType.round,
              startCap: Cap.roundCap,
              endCap: Cap.roundCap,
              consumeTapEvents: true,
              onTap: () => _showTripToast(trip),
            ))
        .toSet();
    _polylineKey = key;
    _polylineCache = set;
    return set;
  }

  /// Geofence overlay: red = danger, green = safe, same colours as the editor.
  Set<Polygon> _buildPolygons() {
    if (_polygonCache != null && identical(_polygonZones, _zones)) return _polygonCache!;
    final set = _zones.map((z) {
      final safe = z.type == 'safe';
      final c = safe ? const Color(0xFF22C55E) : const Color(0xFFEF4444);
      return Polygon(
        polygonId: PolygonId('zone_${z.id}'),
        points: z.coordinates,
        fillColor: c.withOpacity(0.2),
        strokeColor: c,
        strokeWidth: 2,
      );
    }).toSet();
    _polygonZones = _zones;
    _polygonCache = set;
    return set;
  }

  /// Recenter on the pin and keep following it. Following stops by itself
  /// when the guardian drags the map away.
  void _recenter() {
    final target = _shown.value ?? _pinLocation;
    _followIgnoreUntil = DateTime.now().add(const Duration(milliseconds: 1500));
    setState(() => _follow = true);
    _mapController?.animateCamera(CameraUpdate.newLatLngZoom(target, 17));
  }

  void _onCameraMove(CameraPosition pos) {
    if (!_follow) return;
    if (DateTime.now().isBefore(_followIgnoreUntil)) return; // our own recenter
    final shown = _shown.value ?? _pinLocation;
    final d = haversineM(pos.target.latitude, pos.target.longitude,
        shown.latitude, shown.longitude);
    // While following, the camera centre stays on the pin. If it is farther
    // away than ~20 m (at zoom 17), the user dragged the map: stop following.
    final limit = 20 * math.pow(2, 17 - pos.zoom);
    if (d > limit) setState(() => _follow = false);
  }

  /// Glide the pin to [target]. Duration = time since the previous update,
  /// clamped to 0.6-3 s: with fast (live) updates the pin moves continuously
  /// with a few seconds of lag; with slow updates it moves briskly and rests.
  void _animateTo(LatLng target) {
    if (_animTo == target) return; // same target again (e.g. a heartbeat): keep gliding
    final now = DateTime.now();
    final current = _shown.value ?? (_hasRealLocation ? _pinLocation : null);
    final gapMs = _lastTargetAt == null ? 1000 : now.difference(_lastTargetAt!).inMilliseconds;

    if (current == null) {
      _lastTargetAt = now;
      _shown.value = target;
      _animFrom = _animTo = target;
      return;
    }
    final dist = haversineM(current.latitude, current.longitude, target.latitude, target.longitude);
    // Row updates that carry the same position (heartbeats, battery, live
    // flag) must not count as movement: the glide time is measured between
    // real position changes.
    if (dist < 0.5) return;
    _lastTargetAt = now;
    if (dist > 250) {
      // Far away (e.g. first fix after a long gap): do not slide across the map.
      _moveCtrl.stop();
      _shown.value = target;
      _animFrom = _animTo = target;
      return;
    }
    _animFrom = current;
    _animTo = target;
    _moveCtrl.duration = Duration(milliseconds: gapMs.clamp(600, 3000).toInt());
    _moveCtrl.forward(from: 0);
  }

  /// Called by the animation controller; limited to ~30 map updates/second.
  void _onMoveTick() {
    final from = _animFrom, to = _animTo;
    if (from == null || to == null) return;
    final done = _moveCtrl.value >= 1.0;
    final now = DateTime.now();
    if (!done && now.difference(_lastTick) < const Duration(milliseconds: 33)) return;
    _lastTick = now;
    final t = _moveCtrl.value;
    final p = LatLng(
      from.latitude + (to.latitude - from.latitude) * t,
      from.longitude + (to.longitude - from.longitude) * t,
    );
    _shown.value = p;
    if (_follow) _mapController?.moveCamera(CameraUpdate.newLatLng(p));
  }

  /// True once we have a real position: a live device location, or at least
  /// one recorded history point. Without one, no pin is drawn at all.
  bool get _hasRealLocation =>
      _hasLiveLocation || (_trips.isNotEmpty && _trips.first.coords.isNotEmpty);

  Set<Marker> _buildMarkers([LatLng? at]) {
    if (!_hasRealLocation) return {};
    return {
      Marker(
        markerId: const MarkerId('cane'),
        position: at ?? _pinLocation,
        infoWindow: InfoWindow(title: _deviceName),
        // A stale position is drawn faded (Google's built-in pins have no grey).
        alpha: _isStale ? 0.5 : 1.0,
        icon: BitmapDescriptor.defaultMarkerWithHue(_isStale || !_isOnline ? BitmapDescriptor.hueViolet : BitmapDescriptor.hueAzure),
        anchor: const Offset(0.5, 1),
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.of(context).padding;
    final isAdmin = widget.userRole == 'admin' || widget.userRole == 'owner';
    final locAt = _locationAt;

    return Scaffold(
      body: Stack(
        children: [
          // Only the map rebuilds while the pin glides (not the whole screen).
          ValueListenableBuilder<LatLng?>(
            valueListenable: _shown,
            builder: (context, shown, _) => GoogleMap(
              initialCameraPosition: CameraPosition(target: _caneLocation, zoom: 17),
              onMapCreated: (c) => _mapController = c,
              onTap: (_) => _handleMapTap(),
              onCameraMove: _onCameraMove,
              polygons: _buildPolygons(),
              polylines: _buildPolylines(),
              markers: _buildMarkers(shown),
              myLocationEnabled: false,
              myLocationButtonEnabled: false,
            ),
          ),

          // Back (left) and recenter (right)
          Positioned(
            left: 20,
            top: insets.top + 15,
            child: _RoundButton(icon: Icons.arrow_back, onTap: () => Navigator.of(context).pop()),
          ),
          Positioned(
            right: 20,
            top: insets.top + 15,
            child: _RoundButton(icon: Icons.my_location, onTap: _recenter, active: _follow),
          ),

          // Stale-location banner, between the two buttons
          if (_isStale && locAt != null)
            Positioned(
              left: 76,
              right: 76,
              top: insets.top + 18,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFFBEB),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFFFDE68A)),
                  boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 5)],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.history, size: 15, color: Color(0xFF92400E)),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text('Location from ${_agoText(locAt)}',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF92400E))),
                    ),
                  ],
                ),
              ),
            ),

          // Trip history (pick specific walks / sessions), under the recenter button
          Positioned(
            right: 20,
            top: insets.top + 70,
            child: _RoundButton(
              icon: Icons.layers,
              onTap: () => showTripHistorySheet(
                context,
                // Getters, not copies: the sheet re-reads the CURRENT trips
                // and selection every time it redraws, so the checkmarks
                // follow the taps. (_toggleTrip already calls setState.)
                tripsOf: () => _trips,
                activeTripIdsOf: () => _activeTripIds,
                onToggle: _toggleTrip,
              ),
              badgeCount: _activeTripIds.length > 1 ? _activeTripIds.length : null,
            ),
          ),

          if (_tappedTripId != null)
            Positioned(
              top: insets.top + 70,
              left: 0,
              right: 0,
              child: Center(
                child: AnimatedOpacity(
                  opacity: _toastVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 500),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 5)]),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.info, size: 20, color: _tappedTripColor),
                        const SizedBox(width: 8),
                        Text(_tappedTripText ?? '', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF1E293B))),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // Bottom panel
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              padding: EdgeInsets.fromLTRB(25, 25, 25, insets.bottom + 20),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.only(topLeft: Radius.circular(30), topRight: Radius.circular(30)),
                boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10)],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Text(_deviceName,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF1E293B))),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(color: _isOnline ? const Color(0xFF22C55E) : const Color(0xFF94A3B8), borderRadius: BorderRadius.circular(15)),
                        child: Text(_isOnline ? 'Live' : 'Offline', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(child: _SensorItem(icon: Icons.battery_charging_full_outlined, iconColor: _isOnline ? const Color(0xFF22C55E) : const Color(0xFF64748B), label: 'Battery', value: '$_battery%')),
                      const SizedBox(width: 10),
                      Expanded(child: _SensorItem(icon: Icons.directions_walk_outlined, iconColor: const Color(0xFF007BFF), label: 'Status', value: _activityText)),
                      const SizedBox(width: 10),
                      Expanded(child: _SensorItem(icon: Icons.place_outlined, iconColor: _isStale ? const Color(0xFFF59E0B) : const Color(0xFF64748B), label: 'Location', value: locAt == null ? 'Unknown' : _agoText(locAt))),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      if (isAdmin) ...[
                        Expanded(
                          child: _PanelButton(
                            icon: Icons.alt_route,
                            label: 'Routes',
                            onTap: () => Navigator.of(context).pushNamed('/routes', arguments: {
                              'id': widget.deviceId,
                              'name': widget.deviceName,
                              'lat': widget.lat,
                              'lng': widget.lng,
                            }),
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        child: _PanelButton(
                          icon: Icons.description_outlined,
                          label: 'Logs',
                          onTap: () {
                            Navigator.of(context).pop();
                            MainTabController.instance.showLogsFiltered(device: widget.deviceId, category: 'All Types');
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final int? badgeCount;
  final bool active; // e.g. "following" is on
  const _RoundButton({required this.icon, required this.onTap, this.badgeCount, this.active = false});

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(25),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: active ? const Color(0xFF007BFF) : Colors.white, shape: BoxShape.circle, boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 5)]),
            child: Icon(icon, size: 24, color: active ? Colors.white : const Color(0xFF1E293B)),
          ),
        ),
        if (badgeCount != null)
          Positioned(
            top: -5,
            right: -5,
            child: Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: const BoxDecoration(color: Color(0xFFEF4444), shape: BoxShape.circle),
              child: Text('$badgeCount', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
            ),
          ),
      ],
    );
  }
}

class _PanelButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _PanelButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: const Color(0xFF1E293B)),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF1E293B))),
          ],
        ),
      ),
    );
  }
}

class _SensorItem extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;
  const _SensorItem({required this.icon, required this.iconColor, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 15),
      decoration: BoxDecoration(color: const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(15)),
      child: Column(
        children: [
          Icon(icon, size: 24, color: iconColor),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
          const SizedBox(height: 4),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF1E293B))),
        ],
      ),
    );
  }
}

/// Trip-history filter bottom sheet. Call this instead of relying on
/// Scaffold.bottomSheet, since it needs a dim scrim like the original Modal.
void showTripHistorySheet(BuildContext context, {
  required List<TripSession> Function() tripsOf,
  required List<String> Function() activeTripIdsOf,
  required ValueChanged<String> onToggle,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setModalState) {
        final trips = tripsOf();
        final activeTripIds = activeTripIdsOf();
        return Container(
          height: MediaQuery.of(ctx).size.height * 0.6,
          padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).padding.bottom + 20),
          decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.only(topLeft: Radius.circular(30), topRight: Radius.circular(30))),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Trip History', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF1E293B))),
                  IconButton(icon: const Icon(Icons.cancel, size: 30, color: Color(0xFF64748B)), onPressed: () => Navigator.pop(ctx)),
                ],
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: trips.length,
                  itemBuilder: (ctx, index) {
                    final item = trips[index];
                    final isSelected = activeTripIds.contains(item.id);
                    return InkWell(
                      onTap: () {
                        onToggle(item.id);
                        setModalState(() {});
                      },
                      child: Container(
                        padding: EdgeInsets.symmetric(vertical: 15, horizontal: isSelected ? 10 : 0),
                        decoration: BoxDecoration(
                          color: isSelected ? const Color(0xFFF8FAFC) : null,
                          borderRadius: BorderRadius.circular(10),
                          border: const Border(bottom: BorderSide(color: Color(0xFFF1F5F9))),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Container(width: 14, height: 14, margin: const EdgeInsets.only(right: 15), decoration: BoxDecoration(color: item.color, shape: BoxShape.circle)),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(item.dateStr, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF1E293B))),
                                    const SizedBox(height: 2),
                                    Text('${item.startTime} - ${item.endTime}', style: const TextStyle(fontSize: 13, color: Color(0xFF64748B))),
                                  ],
                                ),
                              ],
                            ),
                            Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                color: isSelected ? const Color(0xFF007BFF) : Colors.transparent,
                                border: Border.all(color: isSelected ? const Color(0xFF007BFF) : const Color(0xFFCBD5E1), width: 2),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: isSelected ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      });
    },
  );
}

/// Smoothed copy of a trip's trail, reused until a point is added.
class _SmoothedTrail {
  final int length;
  final LatLng last;
  final List<LatLng> points;
  _SmoothedTrail(this.length, this.last, this.points);
}
