import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/supabase_service.dart';

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

class _TrackerScreenState extends State<TrackerScreen> {
  late LatLng _caneLocation;
  bool _hasLiveLocation = false;
  int _battery = 100;
  bool _isOnline = true;

  List<TripSession> _trips = [];
  List<String> _activeTripIds = [];

  String? _tappedTripId;
  String? _tappedTripText;
  Color? _tappedTripColor;
  bool _toastVisible = false;

  RealtimeChannel? _channel;
  GoogleMapController? _mapController;

  String get _deviceName => widget.deviceName?.isNotEmpty == true ? widget.deviceName! : 'Smart Cane';

  @override
  void initState() {
    super.initState();
    _caneLocation = LatLng(widget.lat ?? 14.1153, widget.lng ?? 122.9566);
    _hasLiveLocation = widget.lat != null && widget.lng != null;
    _fetchInitialData();
    _subscribeToUpdates();
  }

  final _dbService = SupabaseService.instance;

  @override
  void dispose() {
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
      });
      final lastUpdated = liveData['last_updated'];
      if (lastUpdated != null) {
        final lastPingTime = DateTime.parse(lastUpdated).millisecondsSinceEpoch;
        final currentTime = DateTime.now().millisecondsSinceEpoch;
        isActuallyOnline = (currentTime - lastPingTime) < 10000;
        if (mounted) setState(() => _isOnline = isActuallyOnline);
      }
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
          coords: coordsBySession[key]!,
        ));
      }

      if (mounted) {
        setState(() {
          _trips = formattedTrips;
          if (formattedTrips.isNotEmpty) _activeTripIds = [formattedTrips[0].id];
        });
      }
    }
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

  void _subscribeToUpdates() {
    _channel = _dbService.subscribeToDeviceLocation(widget.deviceId, (newData) {
      if (newData['latitude'] != null && newData['longitude'] != null) {
        final newCoord = LatLng((newData['latitude'] as num).toDouble(), (newData['longitude'] as num).toDouble());
        setState(() {
          _caneLocation = newCoord;
          _hasLiveLocation = true;
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
              coords: [...first.coords, newCoord],
            );
            _trips = updated;
          }
        });
      }
      if (newData['battery_level'] != null) setState(() => _battery = newData['battery_level']);
      if (newData['is_online'] != null) setState(() => _isOnline = newData['is_online']);
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

  Set<Polyline> _buildPolylines() {
    return _activeTrips
        .map((trip) => Polyline(
              polylineId: PolylineId(trip.id),
              points: trip.coords,
              color: trip.color,
              width: 5,
              jointType: JointType.round,
              startCap: Cap.roundCap,
              endCap: Cap.roundCap,
              consumeTapEvents: true,
              onTap: () => _showTripToast(trip),
            ))
        .toSet();
  }

  Set<Marker> _buildMarkers() {
    return {
      Marker(
        markerId: const MarkerId('cane'),
        position: _pinLocation,
        infoWindow: InfoWindow(title: _deviceName),
        icon: BitmapDescriptor.defaultMarkerWithHue(_isOnline ? BitmapDescriptor.hueAzure : BitmapDescriptor.hueViolet),
        anchor: const Offset(0.5, 1),
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.of(context).padding;
    final isAdmin = widget.userRole == 'admin';

    return Scaffold(
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(target: _caneLocation, zoom: 17),
            onMapCreated: (c) => _mapController = c,
            onTap: (_) => _handleMapTap(),
            polylines: _buildPolylines(),
            markers: _buildMarkers(),
            myLocationEnabled: false,
            myLocationButtonEnabled: false,
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

          Positioned(
            left: 20,
            top: insets.top + 15,
            child: _RoundButton(icon: Icons.arrow_back, onTap: () => Navigator.of(context).pop()),
          ),

          if (isAdmin)
            Positioned(
              right: 20,
              top: insets.top + 15,
              child: _RoundButton(
                icon: Icons.settings,
                onTap: () => Navigator.of(context).pushNamed('/device-settings', arguments: {
                  'id': widget.deviceId,
                  'name': widget.deviceName,
                  'lat': widget.lat,
                  'lng': widget.lng,
                }),
              ),
            ),

          Positioned(
            right: 20,
            top: insets.top + (isAdmin ? 115 : 15),
            child: _RoundButton(
              icon: Icons.layers,
              onTap: () => showTripHistorySheet(
                context,
                trips: _trips,
                activeTripIds: _activeTripIds,
                onToggle: (id) => setState(() => _toggleTrip(id)),
              ),
              badgeCount: _activeTripIds.length > 1 ? _activeTripIds.length : null,
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
                      Text(_deviceName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF1E293B))),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(color: _isOnline ? const Color(0xFF22C55E) : const Color(0xFF94A3B8), borderRadius: BorderRadius.circular(15)),
                        child: Text(_isOnline ? 'Live' : 'Offline', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _SensorItem(icon: Icons.battery_charging_full_outlined, iconColor: _isOnline ? const Color(0xFF22C55E) : const Color(0xFF64748B), label: 'Battery', value: '$_battery%'),
                      const _SensorItem(icon: Icons.camera_alt_outlined, iconColor: Color(0xFF007BFF), label: 'AI Vision', value: 'Active'),
                      const _SensorItem(icon: Icons.directions_walk_outlined, iconColor: Color(0xFF007BFF), label: 'Status', value: 'Walking'),
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
  const _RoundButton({required this.icon, required this.onTap, this.badgeCount});

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
            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 5)]),
            child: Icon(icon, size: 24, color: const Color(0xFF1E293B)),
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

class _SensorItem extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;
  const _SensorItem({required this.icon, required this.iconColor, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: MediaQuery.of(context).size.width * 0.26,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(color: const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(15)),
      child: Column(
        children: [
          Icon(icon, size: 24, color: iconColor),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF1E293B))),
        ],
      ),
    );
  }
}

/// Trip-history filter bottom sheet. Call this instead of relying on
/// Scaffold.bottomSheet, since it needs a dim scrim like the original Modal.
void showTripHistorySheet(BuildContext context, {
  required List<TripSession> trips,
  required List<String> activeTripIds,
  required ValueChanged<String> onToggle,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setModalState) {
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