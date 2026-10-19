import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../models/geo_point.dart';
import '../../services/danger_zones.dart';
import '../../services/route_service.dart';
import '../../theme/app_colors.dart';
import 'place_search_sheet.dart';
import 'route_widgets.dart';

/// Creates (or edits) a destination-only route: the guardian picks WHERE to
/// go, by searching a place or tapping the map, and gives it a name. No start
/// point and no path are saved. When the cane user starts the walk, their
/// phone asks Google for the walking route from wherever they are.
///
/// Pops with `true` when something was saved.
class DestinationEditorScreen extends StatefulWidget {
  final String deviceId;
  final String? deviceName;
  final double? lat; // where the cane was last seen (map starts here)
  final double? lng;
  final String? routeId;

  const DestinationEditorScreen({
    super.key,
    required this.deviceId,
    this.deviceName,
    this.lat,
    this.lng,
    this.routeId,
  });

  @override
  State<DestinationEditorScreen> createState() => _DestinationEditorScreenState();
}

class _DestinationEditorScreenState extends State<DestinationEditorScreen> {
  final _service = RouteService.instance;
  final _nameCtrl = TextEditingController();
  GoogleMapController? _map;
  late GeoPoint _center;
  GeoPoint? _fresh; // newest cane position, loaded when the screen opens
  DangerZones _zones = DangerZones.none;

  GeoPoint? _dest;
  String _destLabel = '';
  bool _nameTouched = false;
  bool _loading = false;
  bool _saving = false;
  bool _changed = false;

  bool get _isEdit => widget.routeId != null;
  bool get _canSave => _dest != null && _nameCtrl.text.trim().isNotEmpty && !_saving;

  @override
  void initState() {
    super.initState();
    _center = GeoPoint(widget.lat ?? 14.1153, widget.lng ?? 122.9566);
    if (_isEdit) _loadExisting();
    _service.fetchDangerZones(widget.deviceId).then((z) {
      if (mounted) setState(() => _zones = z);
    }).catchError((_) {});
    // The position passed in is only a snapshot from an earlier screen:
    // ask for the newest one so the map opens where the cane is now.
    _service.fetchDeviceLocation(widget.deviceId).then((p) {
      if (p == null || !mounted) return;
      _fresh = p;
      _center = p;
      if (_map != null && _dest == null && !_isEdit) {
        _map!.animateCamera(CameraUpdate.newLatLngZoom(LatLng(p.lat, p.lng), 16));
      }
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _map?.dispose();
    super.dispose();
  }

  Future<void> _loadExisting() async {
    setState(() => _loading = true);
    try {
      final r = await _service.fetchRoute(widget.routeId!);
      if (!mounted) return;
      if (r == null) {
        await showRouteAlert(context, 'Route not found', 'This route no longer exists.');
        if (mounted) Navigator.of(context).pop(true);
        return;
      }
      setState(() {
        _nameCtrl.text = r.name;
        _nameTouched = true;
        _dest = r.end;
        _destLabel = r.endLabel;
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _focus(r.end));
    } on RouteException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      await showRouteAlert(context, 'Could not load the route', e.message);
      if (mounted) Navigator.of(context).pop(false);
    }
  }

  void _focus(GeoPoint p) {
    _map?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(p.lat, p.lng), 16));
  }

  void _setDestination(GeoPoint p, String label) {
    if (_zones.contains(p)) {
      showRouteAlert(context, 'Danger zone', RouteService.dangerPinMessage);
      return;
    }
    setState(() {
      _dest = p;
      _destLabel = label;
      _changed = true;
      // Suggest the place name as the route name until the person types one.
      if (!_nameTouched && label.isNotEmpty) {
        _nameCtrl.text = label.length > 80 ? label.substring(0, 80) : label;
      }
    });
    _focus(p);
  }

  Future<void> _search() async {
    final res = await showPlaceSearchSheet(
      context,
      deviceId: widget.deviceId,
      title: 'Where to?',
      bias: _dest ?? _center,
    );
    if (res == null || !mounted) return;
    _setDestination(res.point, res.address);
  }

  void _onMapTap(LatLng l) => _setDestination(GeoPoint(l.latitude, l.longitude), '');

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _saving = true);
    try {
      await _service.saveDestinationRoute(
        deviceId: widget.deviceId,
        routeId: widget.routeId,
        name: _nameCtrl.text.trim(),
        destination: _dest!,
        destinationLabel: _destLabel,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on RouteException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      await showRouteAlert(
        context,
        'Could not save',
        e.code == '55006'
            ? 'A walk is in progress on this route. Finish or cancel it first.'
            : e.code == '54000'
                ? 'This cane already has 30 routes. Delete one first.'
                : e.message,
      );
    }
  }

  Future<bool> _confirmLeave() async {
    if (!_changed) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your changes to this route will be lost.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep editing')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard', style: TextStyle(color: AppColors.alert)),
          ),
        ],
      ),
    );
    return leave == true;
  }

  @override
  Widget build(BuildContext context) {
    final d = _dest;
    return PopScope(
      canPop: !_changed,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        if (await _confirmLeave()) nav.pop(false);
      },
      child: Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          backgroundColor: AppColors.card,
          elevation: 0,
          foregroundColor: AppColors.textMain,
          title: Text(_isEdit ? 'Edit route' : 'New route',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Column(
                      children: [
                        InkWell(
                          onTap: _search,
                          borderRadius: BorderRadius.circular(14),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                            decoration: BoxDecoration(
                              color: AppColors.card,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: AppColors.border),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.flag, color: AppColors.success),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    d == null
                                        ? 'Search for the destination'
                                        : (_destLabel.isNotEmpty ? _destLabel : 'Point chosen on the map'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: d == null ? FontWeight.normal : FontWeight.w600,
                                      color: d == null ? AppColors.textSub : AppColors.textMain,
                                    ),
                                  ),
                                ),
                                const Icon(Icons.search, color: AppColors.textSub),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: EdgeInsets.only(left: 4, top: 4),
                            child: Text('Or tap the map to place the destination.',
                                style: TextStyle(fontSize: 12, color: AppColors.textSub)),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: GoogleMap(
                      initialCameraPosition: CameraPosition(
                        target: LatLng(_dest?.lat ?? _center.lat, _dest?.lng ?? _center.lng),
                        zoom: 15,
                      ),
                      onMapCreated: (c) {
                        _map = c;
                        final f = _fresh;
                        if (f != null && _dest == null && !_isEdit) {
                          c.moveCamera(CameraUpdate.newLatLngZoom(LatLng(f.lat, f.lng), 16));
                        }
                      },
                      polygons: {
                        for (var i = 0; i < _zones.polygons.length; i++)
                          Polygon(
                            polygonId: PolygonId('danger-$i'),
                            points: [for (final g in _zones.polygons[i]) LatLng(g.lat, g.lng)],
                            fillColor: AppColors.alert.withOpacity(0.25),
                            strokeColor: AppColors.alert,
                            strokeWidth: 2,
                          ),
                      },
                      onTap: _onMapTap,
                      markers: {
                        if (d != null)
                          Marker(
                            markerId: const MarkerId('dest'),
                            position: LatLng(d.lat, d.lng),
                            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
                          ),
                      },
                      myLocationButtonEnabled: false,
                      zoomControlsEnabled: false,
                      mapToolbarEnabled: false,
                    ),
                  ),
                  Container(
                    color: AppColors.card,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: SafeArea(
                      top: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            controller: _nameCtrl,
                            maxLength: 80,
                            textCapitalization: TextCapitalization.sentences,
                            onChanged: (_) => setState(() {
                              _nameTouched = true;
                              _changed = true;
                            }),
                            decoration: InputDecoration(
                              labelText: 'Route name',
                              hintText: 'For example: To the market',
                              counterText: '',
                              filled: true,
                              fillColor: AppColors.bg,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'The walking route is planned from wherever the cane user is when they start the walk.',
                            style: TextStyle(fontSize: 12, color: AppColors.textSub, height: 1.4),
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            height: 52,
                            child: ElevatedButton(
                              onPressed: _canSave ? _save : null,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              ),
                              child: _saving
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                  : const Text('Save route', style: TextStyle(fontSize: 17)),
                            ),
                          ),
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
