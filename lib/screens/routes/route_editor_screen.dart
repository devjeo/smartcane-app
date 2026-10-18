import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../models/geo_point.dart';
import '../../models/route_model.dart';
import '../../services/route_service.dart';
import '../../services/turn_builder.dart';
import '../../theme/app_colors.dart';
import 'place_search_sheet.dart';
import 'route_widgets.dart';

LatLng _ll(GeoPoint p) => LatLng(p.lat, p.lng);
GeoPoint _gp(LatLng l) => GeoPoint(l.latitude, l.longitude);

const _maxVia = 8;

/// Creates a route, or edits one when [routeId] is given.
///
/// Two ways to make a route:
///  * Google: search or tap a start and an end (plus optional points the
///    route must pass), then ask Google for the walking route.
///  * Hand drawn: tap the path on the map; turns are worked out on the phone
///    by [TurnBuilder] (free, works where Google's walking data is weak).
///
/// Pops with `true` when something was saved.
class RouteEditorScreen extends StatefulWidget {
  final String deviceId;
  final String? deviceName;
  final double? lat;
  final double? lng;
  final String? routeId;

  const RouteEditorScreen({
    super.key,
    required this.deviceId,
    this.deviceName,
    this.lat,
    this.lng,
    this.routeId,
  });

  @override
  State<RouteEditorScreen> createState() => _RouteEditorScreenState();
}

class _RouteEditorScreenState extends State<RouteEditorScreen> {
  final _service = RouteService.instance;
  GoogleMapController? _map;
  late final GeoPoint _center;

  String _mode = 'google'; // 'google' | 'drawn'
  String _tapTarget = 'start'; // google mode: 'start' | 'end' | 'via'

  // Google mode
  GeoPoint? _start;
  GeoPoint? _end;
  String _startLabel = '';
  String _endLabel = '';
  final List<GeoPoint> _via = [];
  List<PlannedRoute> _plans = [];
  int _planIndex = 0;

  // Drawn mode
  List<GeoPoint> _taps = [];
  final List<List<GeoPoint>> _undo = [];
  final List<List<GeoPoint>> _redo = [];
  BuiltRoute? _built;
  String? _buildNote;

  bool _loadingExisting = false;
  bool _planning = false;
  bool _saving = false;
  bool _hasChanges = false;
  String _existingName = '';

  bool get _isEdit => widget.routeId != null;

  @override
  void initState() {
    super.initState();
    _center = GeoPoint(widget.lat ?? 14.1153, widget.lng ?? 122.9566);
    if (_isEdit) _loadExisting();
  }

  // ---------------------------------------------------------------------
  // Loading an existing route
  // ---------------------------------------------------------------------

  Future<void> _loadExisting() async {
    setState(() => _loadingExisting = true);
    try {
      final r = await _service.fetchRoute(widget.routeId!);
      if (!mounted) return;
      if (r == null) {
        await showRouteAlert(context, 'Route not found', 'This route no longer exists.');
        if (mounted) Navigator.of(context).pop(true);
        return;
      }
      setState(() {
        _existingName = r.name;
        if (r.isDrawn) {
          _mode = 'drawn';
          _taps = List.of(r.waypoints.length >= 2 ? r.waypoints : r.path);
          _recomputeBuilt();
        } else {
          _mode = 'google';
          _start = r.start;
          _end = r.end;
          _startLabel = r.startLabel;
          _endLabel = r.endLabel;
          _via
            ..clear()
            ..addAll(r.waypoints);
          _plans = [
            PlannedRoute(
              distanceM: r.distanceM,
              durationS: r.durationS,
              path: r.path,
              steps: r.steps,
              warnings: const [],
            ),
          ];
          _planIndex = 0;
          _tapTarget = 'via';
        }
        _loadingExisting = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _fit(_mode == 'drawn' ? (_built?.path ?? _taps) : _plans.first.path);
      });
    } on RouteException catch (e) {
      if (!mounted) return;
      setState(() => _loadingExisting = false);
      await showRouteAlert(context, 'Could not load the route', e.message);
      if (mounted) Navigator.of(context).pop(false);
    }
  }

  // ---------------------------------------------------------------------
  // Map helpers
  // ---------------------------------------------------------------------

  Future<void> _fit(List<GeoPoint> pts) async {
    if (pts.isEmpty || _map == null) return;
    var minLat = pts.first.lat, maxLat = pts.first.lat;
    var minLng = pts.first.lng, maxLng = pts.first.lng;
    for (final p in pts) {
      if (p.lat < minLat) minLat = p.lat;
      if (p.lat > maxLat) maxLat = p.lat;
      if (p.lng < minLng) minLng = p.lng;
      if (p.lng > maxLng) maxLng = p.lng;
    }
    try {
      if (minLat == maxLat && minLng == maxLng) {
        await _map!.animateCamera(CameraUpdate.newLatLngZoom(LatLng(minLat, minLng), 17));
      } else {
        await _map!.animateCamera(CameraUpdate.newLatLngBounds(
          LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng)),
          90,
        ));
      }
    } catch (_) {
      // The map may not be laid out yet; the camera simply stays where it is.
    }
  }

  void _invalidatePlans() {
    _plans = [];
    _planIndex = 0;
  }

  // ---------------------------------------------------------------------
  // Google mode
  // ---------------------------------------------------------------------

  void _onMapTap(LatLng latLng) {
    final p = _gp(latLng);
    setState(() {
      _hasChanges = true;
      if (_mode == 'drawn') {
        _pushUndo();
        _taps = [..._taps, p];
        _recomputeBuilt();
        return;
      }
      switch (_tapTarget) {
        case 'start':
          _start = p;
          _startLabel = 'Dropped pin';
          _invalidatePlans();
          if (_end == null) _tapTarget = 'end';
          break;
        case 'end':
          _end = p;
          _endLabel = 'Dropped pin';
          _invalidatePlans();
          break;
        default:
          if (_via.length < _maxVia) {
            _via.add(p);
            _invalidatePlans();
          }
      }
    });
  }

  Future<void> _searchFor(String which) async {
    final res = await showPlaceSearchSheet(
      context,
      deviceId: widget.deviceId,
      title: which == 'start' ? 'Search start point' : 'Search destination',
      bias: _start ?? _center,
    );
    if (res == null || !mounted) return;
    setState(() {
      _hasChanges = true;
      if (which == 'start') {
        _start = res.point;
        _startLabel = res.address;
        if (_end == null) _tapTarget = 'end';
      } else {
        _end = res.point;
        _endLabel = res.address;
      }
      _invalidatePlans();
    });
    _map?.animateCamera(CameraUpdate.newLatLngZoom(_ll(res.point), 16));
  }

  Future<void> _findRoute() async {
    final s = _start, e = _end;
    if (s == null || e == null || _planning) return;
    setState(() => _planning = true);
    try {
      final plans = await _service.planWalkingRoute(
        deviceId: widget.deviceId,
        origin: s,
        destination: e,
        via: List.of(_via),
        alternatives: _via.isEmpty,
      );
      if (!mounted) return;
      setState(() {
        _plans = plans;
        _planIndex = 0;
        _planning = false;
        _hasChanges = true;
      });
      _fit(plans.first.path);
    } on RouteException catch (ex) {
      if (!mounted) return;
      setState(() => _planning = false);
      await showRouteAlert(context, 'No route', ex.message);
    }
  }

  // ---------------------------------------------------------------------
  // Drawn mode
  // ---------------------------------------------------------------------

  void _pushUndo() {
    _undo.add(List.of(_taps));
    _redo.clear();
  }

  void _recomputeBuilt() {
    if (_taps.length < 2) {
      _built = null;
      _buildNote = null;
      return;
    }
    try {
      _built = TurnBuilder.build(_taps);
      _buildNote = null;
    } on ArgumentError {
      _built = null;
      _buildNote = 'The points are too close together. Tap further apart.';
    }
  }

  void _undoTap() {
    if (_undo.isEmpty) return;
    setState(() {
      _redo.add(List.of(_taps));
      _taps = _undo.removeLast();
      _recomputeBuilt();
      _hasChanges = true;
    });
  }

  void _redoTap() {
    if (_redo.isEmpty) return;
    setState(() {
      _undo.add(List.of(_taps));
      _taps = _redo.removeLast();
      _recomputeBuilt();
      _hasChanges = true;
    });
  }

  void _clearTaps() {
    if (_taps.isEmpty) return;
    setState(() {
      _pushUndo();
      _taps = [];
      _recomputeBuilt();
      _hasChanges = true;
    });
  }

  void _dragTap(int i, LatLng pos) {
    setState(() {
      _pushUndo();
      final next = List<GeoPoint>.of(_taps);
      next[i] = _gp(pos);
      _taps = next;
      _recomputeBuilt();
      _hasChanges = true;
    });
  }

  // ---------------------------------------------------------------------
  // Saving
  // ---------------------------------------------------------------------

  bool get _canSave {
    if (_saving || _loadingExisting) return false;
    return _mode == 'google' ? _plans.isNotEmpty : _built != null;
  }

  Future<String?> _askName() {
    final suggestion = _existingName.isNotEmpty
        ? _existingName
        : (_mode == 'google' && _startLabel.isNotEmpty && _endLabel.isNotEmpty
            ? '$_startLabel to $_endLabel'
            : '');
    final c = TextEditingController(
        text: suggestion.length > 80 ? suggestion.substring(0, 80) : suggestion);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name this route'),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: 80,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'For example: Home to the market'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              final v = c.text.trim();
              if (v.isNotEmpty) Navigator.pop(ctx, v);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    if (!_canSave) return;
    final name = await _askName();
    if (name == null || !mounted) return;

    setState(() => _saving = true);
    try {
      if (_mode == 'google') {
        final plan = _plans[_planIndex];
        await _service.saveRoute(
          deviceId: widget.deviceId,
          routeId: widget.routeId,
          name: name,
          start: _start!,
          startLabel: _startLabel,
          end: _end!,
          endLabel: _endLabel,
          waypoints: List.of(_via),
          path: plan.path,
          steps: plan.steps,
          distanceM: plan.distanceM,
          durationS: plan.durationS,
          source: 'google',
        );
      } else {
        final b = _built!;
        await _service.saveRoute(
          deviceId: widget.deviceId,
          routeId: widget.routeId,
          name: name,
          start: b.path.first,
          startLabel: 'Start point',
          end: b.path.last,
          endLabel: 'End point',
          waypoints: List.of(_taps),
          path: b.path,
          steps: b.steps,
          distanceM: b.distanceM,
          durationS: b.durationS,
          source: 'drawn',
        );
      }
      _hasChanges = false;
      if (mounted) Navigator.of(context).pop(true);
    } on RouteException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      await showRouteAlert(
        context,
        'Could not save',
        e.code == '55006'
            ? 'A walk is in progress on this route. Finish or cancel it first.'
            : e.message,
      );
    }
  }

  Future<void> _confirmClose() async {
    if (!_hasChanges) {
      Navigator.of(context).pop(false);
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your route has not been saved.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep editing')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard', style: TextStyle(color: AppColors.alert)),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop(false);
  }

  void _showSteps(List<RouteStep> steps) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
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
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Turn by turn',
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textMain)),
            ),
            Expanded(child: StepsList(steps: steps, controller: controller)),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Map layers
  // ---------------------------------------------------------------------

  Set<Marker> _markers() {
    final out = <Marker>{};
    if (_mode == 'google') {
      if (_start != null) {
        out.add(Marker(
          markerId: const MarkerId('start'),
          position: _ll(_start!),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
          infoWindow: InfoWindow(title: 'Start', snippet: _startLabel),
          draggable: true,
          onDragEnd: (p) => setState(() {
            _start = _gp(p);
            _startLabel = 'Dropped pin';
            _invalidatePlans();
            _hasChanges = true;
          }),
        ));
      }
      if (_end != null) {
        out.add(Marker(
          markerId: const MarkerId('end'),
          position: _ll(_end!),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          infoWindow: InfoWindow(title: 'Destination', snippet: _endLabel),
          draggable: true,
          onDragEnd: (p) => setState(() {
            _end = _gp(p);
            _endLabel = 'Dropped pin';
            _invalidatePlans();
            _hasChanges = true;
          }),
        ));
      }
      for (var i = 0; i < _via.length; i++) {
        out.add(Marker(
          markerId: MarkerId('via-$i'),
          position: _ll(_via[i]),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          infoWindow: InfoWindow(title: 'Pass through ${i + 1}'),
          draggable: true,
          onDragEnd: (p) => setState(() {
            _via[i] = _gp(p);
            _invalidatePlans();
            _hasChanges = true;
          }),
        ));
      }
    } else {
      for (var i = 0; i < _taps.length; i++) {
        final first = i == 0;
        final last = i == _taps.length - 1 && _taps.length > 1;
        out.add(Marker(
          markerId: MarkerId('tap-$i'),
          position: _ll(_taps[i]),
          icon: BitmapDescriptor.defaultMarkerWithHue(first
              ? BitmapDescriptor.hueGreen
              : last
                  ? BitmapDescriptor.hueRed
                  : BitmapDescriptor.hueOrange),
          draggable: true,
          anchor: const Offset(0.5, 1.0),
          onDragEnd: (p) => _dragTap(i, p),
        ));
      }
    }
    return out;
  }

  Set<Polyline> _polylines() {
    final out = <Polyline>{};
    if (_mode == 'google') {
      for (var i = 0; i < _plans.length; i++) {
        final selected = i == _planIndex;
        out.add(Polyline(
          polylineId: PolylineId('plan-$i'),
          points: _plans[i].path.map(_ll).toList(),
          color: selected ? AppColors.primary : const Color(0xFF94A3B8),
          width: selected ? 7 : 5,
          zIndex: selected ? 2 : 1,
          consumeTapEvents: true,
          onTap: () => setState(() => _planIndex = i),
        ));
      }
    } else if (_built != null) {
      out.add(Polyline(
        polylineId: const PolylineId('built'),
        points: _built!.path.map(_ll).toList(),
        color: const Color(0xFFF97316),
        width: 6,
      ));
    }
    return out;
  }

  // ---------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmClose();
      },
      child: Scaffold(
        body: Stack(
          children: [
            GoogleMap(
              initialCameraPosition: CameraPosition(target: _ll(_center), zoom: 16),
              onMapCreated: (c) => _map = c,
              onTap: _onMapTap,
              markers: _markers(),
              polylines: _polylines(),
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              mapToolbarEnabled: false,
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _RoundIconButton(icon: Icons.close, onTap: _confirmClose),
                        Flexible(
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            decoration: BoxDecoration(
                              color: AppColors.card,
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 5)],
                            ),
                            child: Text(
                              _isEdit ? 'Edit route' : 'New route',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, color: AppColors.textMain),
                            ),
                          ),
                        ),
                        SizedBox(
                          height: 40,
                          child: ElevatedButton(
                            onPressed: _canSave ? _save : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              disabledBackgroundColor: const Color(0xFFCBD5E1),
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                            ),
                            child: _saving
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white))
                                : Text('Save',
                                    style: TextStyle(
                                        color: _canSave ? Colors.white : AppColors.textSub,
                                        fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _ModeToggle(
                      mode: _mode,
                      onChanged: (m) => setState(() => _mode = m),
                    ),
                  ],
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: _mode == 'google' ? _googlePanel() : _drawnPanel(),
            ),
            if (_loadingExisting)
              Container(
                color: Colors.black26,
                child: const Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }

  Widget _panel({required List<Widget> children}) {
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
      padding: EdgeInsets.fromLTRB(20, 18, 20, MediaQuery.of(context).padding.bottom + 14),
      decoration: const BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10)],
      ),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }

  Widget _googlePanel() {
    final hasPlan = _plans.isNotEmpty;
    final plan = hasPlan ? _plans[_planIndex] : null;
    final canFind = _start != null && _end != null && !_planning;
    final hint = {
      'start': 'Tap the map to set the start point.',
      'end': 'Tap the map to set the destination.',
      'via': 'Tap the map to add a point the route must pass through.',
    }[_tapTarget]!;

    return _panel(children: [
      _PointRow(
        color: AppColors.success,
        hint: 'Start point',
        label: _start == null ? null : (_startLabel.isEmpty ? 'Chosen on map' : _startLabel),
        mapSelected: _tapTarget == 'start',
        onSearch: () => _searchFor('start'),
        onMapPin: () => setState(() => _tapTarget = 'start'),
      ),
      const SizedBox(height: 8),
      _PointRow(
        color: AppColors.alert,
        hint: 'Destination',
        label: _end == null ? null : (_endLabel.isEmpty ? 'Chosen on map' : _endLabel),
        mapSelected: _tapTarget == 'end',
        onSearch: () => _searchFor('end'),
        onMapPin: () => setState(() => _tapTarget = 'end'),
      ),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: _tapTarget == 'via' ? const Color(0xFFE0F2FE) : AppColors.bg,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            const Icon(Icons.alt_route, size: 20, color: AppColors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Pass through: ${_via.length} of $_maxVia (optional)',
                style: const TextStyle(fontSize: 14, color: AppColors.textMain),
              ),
            ),
            IconButton(
              tooltip: 'Add points on the map',
              icon: Icon(Icons.add_location_alt,
                  color: _tapTarget == 'via' ? AppColors.primary : AppColors.textSub),
              onPressed: () => setState(() => _tapTarget = 'via'),
            ),
            IconButton(
              tooltip: 'Remove last point',
              icon: Icon(Icons.undo,
                  color: _via.isEmpty ? const Color(0xFFCBD5E1) : AppColors.textMain),
              onPressed: _via.isEmpty
                  ? null
                  : () => setState(() {
                        _via.removeLast();
                        _invalidatePlans();
                        _hasChanges = true;
                      }),
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Text(hint,
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 12, color: AppColors.textSub, fontStyle: FontStyle.italic)),
      const SizedBox(height: 12),
      if (plan != null) ...[
        _SummaryRow(
          text: '${plan.distanceText}  -  ${plan.durationText}  -  ${plan.steps.length} steps',
          onSteps: () => _showSteps(plan.steps),
        ),
        if (_plans.length > 1) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (var i = 0; i < _plans.length; i++)
                ChoiceChip(
                  label: Text('Option ${i + 1}: ${_plans[i].distanceText}'),
                  selected: i == _planIndex,
                  onSelected: (_) => setState(() => _planIndex = i),
                ),
            ],
          ),
        ],
        if (plan.warnings.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(plan.warnings.first,
              style: const TextStyle(fontSize: 12, color: AppColors.warning)),
        ],
        const SizedBox(height: 12),
      ],
      SizedBox(
        width: double.infinity,
        height: 48,
        child: OutlinedButton.icon(
          onPressed: canFind ? _findRoute : null,
          style: OutlinedButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            side: BorderSide(color: canFind ? AppColors.primary : AppColors.border),
          ),
          icon: _planning
              ? const SizedBox(
                  width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.directions_walk),
          label: Text(hasPlan ? 'Update walking route' : 'Find walking route',
              style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
      ),
    ]);
  }

  Widget _drawnPanel() {
    final b = _built;
    return _panel(children: [
      Text(
        _taps.isEmpty
            ? 'Tap along the path the walker should follow. Drag a pin to adjust it.'
            : _taps.length == 1
                ? 'Keep tapping to add more points. At least two are needed.'
                : '${_taps.length} points. Keep tapping to extend the path.',
        textAlign: TextAlign.center,
        style: const TextStyle(
            fontSize: 13, color: AppColors.textSub, fontStyle: FontStyle.italic),
      ),
      if (_buildNote != null) ...[
        const SizedBox(height: 8),
        Text(_buildNote!, style: const TextStyle(fontSize: 13, color: AppColors.alert)),
      ],
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(15)),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _ToolButton(icon: Icons.undo, label: 'Undo', enabled: _undo.isNotEmpty, onTap: _undoTap),
            _ToolButton(icon: Icons.redo, label: 'Redo', enabled: _redo.isNotEmpty, onTap: _redoTap),
            _ToolButton(
                icon: Icons.delete_outline,
                label: 'Clear',
                enabled: _taps.isNotEmpty,
                color: AppColors.alert,
                onTap: _clearTaps),
          ],
        ),
      ),
      if (b != null) ...[
        const SizedBox(height: 12),
        _SummaryRow(
          text:
              '${formatDistance(b.distanceM)}  -  ${formatDuration(b.durationS)}  -  ${b.steps.length} steps',
          onSteps: () => _showSteps(b.steps),
        ),
      ],
    ]);
  }
}

// -------------------------------------------------------------------------
// Small widgets
// -------------------------------------------------------------------------

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _RoundIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 40,
        height: 40,
        decoration: const BoxDecoration(
          color: AppColors.card,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 5)],
        ),
        child: Icon(icon, size: 24, color: AppColors.textMain),
      ),
    );
  }
}

class _ModeToggle extends StatelessWidget {
  final String mode;
  final ValueChanged<String> onChanged;
  const _ModeToggle({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    Widget seg(String value, IconData icon, String label) {
      final active = mode == value;
      return Expanded(
        child: InkWell(
          onTap: () => onChanged(value),
          borderRadius: BorderRadius.circular(18),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              color: active ? AppColors.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 18, color: active ? Colors.white : AppColors.textSub),
                const SizedBox(width: 6),
                Text(label,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: active ? Colors.white : AppColors.textSub)),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 5)],
      ),
      child: Row(
        children: [
          seg('google', Icons.travel_explore, 'Google route'),
          seg('drawn', Icons.draw, 'Draw by hand'),
        ],
      ),
    );
  }
}

class _PointRow extends StatelessWidget {
  final Color color;
  final String hint;
  final String? label;
  final bool mapSelected;
  final VoidCallback onSearch;
  final VoidCallback onMapPin;
  const _PointRow({
    required this.color,
    required this.hint,
    required this.label,
    required this.mapSelected,
    required this.onSearch,
    required this.onMapPin,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: mapSelected ? const Color(0xFFE0F2FE) : AppColors.bg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onSearch,
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                child: Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        label ?? '$hint - tap to search',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: label == null ? AppColors.textSub : AppColors.textMain,
                          fontWeight: label == null ? FontWeight.normal : FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Choose on the map',
            icon: Icon(Icons.pin_drop,
                color: mapSelected ? AppColors.primary : AppColors.textSub),
            onPressed: onMapPin,
          ),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String text;
  final VoidCallback onSteps;
  const _SummaryRow({required this.text, required this.onSteps});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(text,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textMain)),
        ),
        TextButton(onPressed: onSteps, child: const Text('View steps')),
      ],
    );
  }
}

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final Color? color;
  final VoidCallback onTap;
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.enabled,
    this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = enabled ? (color ?? AppColors.textMain) : const Color(0xFFCBD5E1);
    return SizedBox(
      width: 70,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Column(
          children: [
            Icon(icon, size: 22, color: c),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: c)),
          ],
        ),
      ),
    );
  }
}
