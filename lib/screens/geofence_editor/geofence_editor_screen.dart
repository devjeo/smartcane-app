import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../services/supabase_service.dart';

class _Colors {
  static const bg = Color(0xFFF8FAFC);
  static const card = Color(0xFFFFFFFF);
  static const textMain = Color(0xFF1E293B);
  static const textSub = Color(0xFF64748B);
  static const border = Color(0xFFE2E8F0);
  static const primary = Color(0xFF007BFF);
  static const alert = Color(0xFFEF4444);
  static const success = Color(0xFF22C55E);
  static const disabled = Color(0xFFCBD5E1);
}

class GeofenceZone {
  final String id;
  final String type; // 'safe' or 'danger'
  final List<LatLng> coordinates;
  const GeofenceZone({required this.id, required this.type, required this.coordinates});

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'coordinates': coordinates.map((c) => {'latitude': c.latitude, 'longitude': c.longitude}).toList(),
      };

  static GeofenceZone fromJson(Map<String, dynamic> json) => GeofenceZone(
        id: json['id'].toString(),
        type: json['type'] ?? 'danger',
        coordinates: (json['coordinates'] as List)
            .map((c) => LatLng((c['latitude'] as num).toDouble(), (c['longitude'] as num).toDouble()))
            .toList(),
      );
}

/// Route arguments: { 'id': String, 'name': String?, 'lat': double?, 'lng': double? }
class GeofenceEditorScreen extends StatefulWidget {
  final String deviceId;
  final String? deviceName;
  final double? lat;
  final double? lng;

  const GeofenceEditorScreen({super.key, required this.deviceId, this.deviceName, this.lat, this.lng});

  @override
  State<GeofenceEditorScreen> createState() => _GeofenceEditorScreenState();
}

class _GeofenceEditorScreenState extends State<GeofenceEditorScreen> {
  GoogleMapController? _mapController;
  late LatLng _initialCenter;

  String _drawingMode = 'danger'; // 'safe' or 'danger'
  bool _hasUnsavedChanges = false;

  List<LatLng> _activePolygon = [];
  final List<List<LatLng>> _undoStack = [];
  final List<List<LatLng>> _redoStack = [];
  List<GeofenceZone> _savedZones = [];
  String? _selectedZoneId;

  BitmapDescriptor? _greenCircleIcon;
  BitmapDescriptor? _redCircleIcon;

  final _dbService = SupabaseService.instance;

  @override
  void initState() {
    super.initState();
    _initialCenter = LatLng(widget.lat ?? 13.1391, widget.lng ?? 123.7438);
    _loadSavedZones();
    _loadVertexIcons();
  }

  Future<void> _loadVertexIcons() async {
    final green = await _createCircleIcon(_Colors.success);
    final red = await _createCircleIcon(_Colors.alert);
    if (mounted) {
      setState(() {
        _greenCircleIcon = green;
        _redCircleIcon = red;
      });
    }
  }

  /// Draws a small filled circle with a white border and returns it as a
  /// BitmapDescriptor, used in place of the default map pin for vertices.
  Future<BitmapDescriptor> _createCircleIcon(Color color, {double size = 36}) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final borderWidth = size * 0.12;
    final radius = (size - borderWidth) / 2;
    final center = Offset(size / 2, size / 2);

    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth;

    canvas.drawCircle(center, radius, fillPaint);
    canvas.drawCircle(center, radius, borderPaint);

    final picture = recorder.endRecording();
    final image = await picture.toImage(size.round(), size.round());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(byteData!.buffer.asUint8List());
  }

  String get _deviceName => widget.deviceName?.isNotEmpty == true ? widget.deviceName! : 'Device';

  Future<void> _loadSavedZones() async {
    try {
      final polygonData = await _dbService.getGeofenceZones(widget.deviceId);
      if (polygonData != null && mounted) {
        final list = polygonData.map((z) => GeofenceZone.fromJson(z as Map<String, dynamic>)).toList();
        setState(() => _savedZones = list);
      }
    } catch (e) {
      debugPrint('Failed to load zones from cloud: $e');
    }
  }

  void _handleMapTap(LatLng point) {
    if (_selectedZoneId != null) {
      setState(() => _selectedZoneId = null);
      return;
    }
    setState(() {
      _undoStack.add(List.from(_activePolygon));
      _activePolygon = [..._activePolygon, point];
      _redoStack.clear();
      _hasUnsavedChanges = true;
    });
  }

  void _handleZoneTap(String zoneId) {
    if (_activePolygon.isNotEmpty) return;
    setState(() => _selectedZoneId = zoneId == _selectedZoneId ? null : zoneId);
  }

  void _handleUndo() {
    if (_undoStack.isEmpty) return;
    setState(() {
      final previous = _undoStack.removeLast();
      _redoStack.add(List.from(_activePolygon));
      _activePolygon = previous;
      _hasUnsavedChanges = true;
    });
  }

  void _handleRedo() {
    if (_redoStack.isEmpty) return;
    setState(() {
      final next = _redoStack.removeLast();
      _undoStack.add(List.from(_activePolygon));
      _activePolygon = next;
      _hasUnsavedChanges = true;
    });
  }

  void _handleDelete() {
    if (_selectedZoneId == null) return;
    setState(() {
      _savedZones = _savedZones.where((z) => z.id != _selectedZoneId).toList();
      _selectedZoneId = null;
      _hasUnsavedChanges = true;
    });
  }

  void _handleEdit() {
    if (_selectedZoneId == null) return;
    final zone = _savedZones.firstWhere((z) => z.id == _selectedZoneId);
    setState(() {
      _drawingMode = zone.type;
      _activePolygon = List.from(zone.coordinates);
      _savedZones = _savedZones.where((z) => z.id != _selectedZoneId).toList();
      _selectedZoneId = null;
      _undoStack.clear();
      _redoStack.clear();
      _hasUnsavedChanges = true;
    });
  }

  void _handleCompleteShape() {
    if (_activePolygon.length < 3) return;
    final newZone = GeofenceZone(id: DateTime.now().millisecondsSinceEpoch.toString(), type: _drawingMode, coordinates: _activePolygon);
    setState(() {
      _savedZones = [..._savedZones, newZone];
      _activePolygon = [];
      _undoStack.clear();
      _redoStack.clear();
      _hasUnsavedChanges = true;
    });
  }

  Future<void> _handleSave() async {
    if (!_hasUnsavedChanges) return;
    try {
      await _dbService.saveGeofenceZones(
        widget.deviceId,
        _savedZones.map((z) => z.toJson()).toList()
      );

      setState(() => _hasUnsavedChanges = false);
      if (mounted) {
        await showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Zones Synced'),
            content: Text('${_savedZones.length} zones have been saved to the cloud.'),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
          ),
        );
        if (mounted) Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        await showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Database Error'),
            content: const Text('Could not sync zones to the cloud.'),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
          ),
        );
      }
      debugPrint('$e');
    }
  }

  void _onDragActiveVertex(int index, LatLng newPoint) {
    setState(() {
      final updated = List<LatLng>.from(_activePolygon);
      updated[index] = newPoint;
      _activePolygon = updated;
      _hasUnsavedChanges = true;
    });
  }

  Set<Polygon> _buildPolygons() {
    final polygons = <Polygon>{};

    for (final zone in _savedZones) {
      final isSafe = zone.type == 'safe';
      final isSelected = zone.id == _selectedZoneId;
      polygons.add(Polygon(
        polygonId: PolygonId(zone.id),
        points: zone.coordinates,
        fillColor: (isSafe ? _Colors.success : _Colors.alert).withOpacity(0.3),
        strokeColor: isSelected ? Colors.black : (isSafe ? _Colors.success : _Colors.alert),
        strokeWidth: isSelected ? 4 : 2,
        consumeTapEvents: true,
        onTap: () => _handleZoneTap(zone.id),
      ));
    }

    if (_activePolygon.length >= 3) {
      polygons.add(Polygon(
        polygonId: const PolygonId('active'),
        points: _activePolygon,
        fillColor: (_drawingMode == 'safe' ? _Colors.success : _Colors.alert).withOpacity(0.4),
        strokeColor: _drawingMode == 'safe' ? _Colors.success : _Colors.alert,
        strokeWidth: 2,
      ));
    }

    return polygons;
  }

  Set<Marker> _buildActiveVertexMarkers() {
    final markers = <Marker>{};
    final isSafe = _drawingMode == 'safe';
    final fallbackIcon = BitmapDescriptor.defaultMarkerWithHue(
      isSafe ? BitmapDescriptor.hueGreen : BitmapDescriptor.hueRed,
    );
    final circleIcon = (isSafe ? _greenCircleIcon : _redCircleIcon) ?? fallbackIcon;

    for (int i = 0; i < _activePolygon.length; i++) {
      markers.add(Marker(
        markerId: MarkerId('active-vertex-$i'),
        position: _activePolygon[i],
        draggable: true,
        onDragEnd: (newPos) => _onDragActiveVertex(i, newPos),
        icon: circleIcon,
        anchor: const Offset(0.5, 0.5),
      ));
    }
    return markers;
  }

  @override
  Widget build(BuildContext context) {
    final isDrawing = _activePolygon.isNotEmpty;
    final isSelected = _selectedZoneId != null;

    return Scaffold(
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(target: _initialCenter, zoom: 17),
            onMapCreated: (c) => _mapController = c,
            onTap: _handleMapTap,
            polygons: _buildPolygons(),
            markers: _buildActiveVertexMarkers(),
            myLocationButtonEnabled: false,
          ),

          // Header
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _RoundIconButton(icon: Icons.close, onTap: () => Navigator.of(context).pop()),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
                    decoration: BoxDecoration(color: _Colors.card, borderRadius: BorderRadius.circular(20), boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 5)]),
                    child: Text('$_deviceName Zones', style: const TextStyle(fontWeight: FontWeight.bold, color: _Colors.textMain)),
                  ),
                  SizedBox(
                    height: 40,
                    child: ElevatedButton(
                      onPressed: _hasUnsavedChanges ? _handleSave : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _hasUnsavedChanges ? _Colors.primary : _Colors.disabled,
                        padding: const EdgeInsets.symmetric(horizontal: 15),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      ),
                      child: Text('Save', style: TextStyle(color: _hasUnsavedChanges ? Colors.white : const Color(0xFF64748B), fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Floating palette
          Positioned(
            right: 15,
            top: 120,
            child: Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(color: _Colors.card, borderRadius: BorderRadius.circular(15), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)]),
              child: Column(
                children: [
                  _PaletteButton(
                    icon: Icons.verified_user,
                    label: 'Safe',
                    active: _drawingMode == 'safe',
                    activeColor: _Colors.success,
                    onTap: isDrawing ? null : () => setState(() => _drawingMode = 'safe'),
                  ),
                  Container(height: 1, margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2), color: _Colors.border),
                  _PaletteButton(
                    icon: Icons.warning_amber_rounded,
                    label: 'Danger',
                    active: _drawingMode == 'danger',
                    activeColor: _Colors.alert,
                    onTap: isDrawing ? null : () => setState(() => _drawingMode = 'danger'),
                  ),
                ],
              ),
            ),
          ),

          // Bottom panel
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).padding.bottom + 15),
              decoration: const BoxDecoration(
                color: _Colors.card,
                borderRadius: BorderRadius.only(topLeft: Radius.circular(30), topRight: Radius.circular(30)),
                boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10)],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isDrawing
                        ? 'Drawing $_drawingMode zone (${_activePolygon.length} pts)...'
                        : isSelected
                            ? 'Zone Selected. Choose an action.'
                            : 'Select a mode and tap map to draw, or tap a zone to manage.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13, color: _Colors.textSub, fontStyle: FontStyle.italic),
                  ),
                  const SizedBox(height: 15),
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(color: _Colors.bg, borderRadius: BorderRadius.circular(15)),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _ToolButton(icon: Icons.undo, label: 'Undo', enabled: _undoStack.isNotEmpty, onTap: _handleUndo),
                        _ToolButton(icon: Icons.redo, label: 'Redo', enabled: _redoStack.isNotEmpty, onTap: _handleRedo),
                        _ToolButton(icon: Icons.edit, label: 'Edit', enabled: isSelected, color: _Colors.primary, onTap: _handleEdit),
                        _ToolButton(icon: Icons.delete, label: 'Delete', enabled: isSelected, color: _Colors.alert, onTap: _handleDelete),
                      ],
                    ),
                  ),
                  const SizedBox(height: 15),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton.icon(
                      onPressed: (isDrawing && _activePolygon.length >= 3) ? _handleCompleteShape : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: (isDrawing && _activePolygon.length >= 3) ? _Colors.primary : _Colors.disabled,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                      ),
                      icon: const Icon(Icons.check_circle, size: 20, color: Colors.white),
                      label: const Text('Complete Shape', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                    ),
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
        decoration: const BoxDecoration(color: _Colors.card, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 5)]),
        child: Icon(icon, size: 24, color: _Colors.textMain),
      ),
    );
  }
}

class _PaletteButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final Color activeColor;
  final VoidCallback? onTap;
  const _PaletteButton({required this.icon, required this.label, required this.active, required this.activeColor, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        decoration: BoxDecoration(color: active ? activeColor : Colors.transparent, borderRadius: BorderRadius.circular(10)),
        child: Column(
          children: [
            Icon(icon, size: 20, color: active ? Colors.white : activeColor),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: active ? Colors.white : _Colors.textSub)),
          ],
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final Color? color;
  final VoidCallback onTap;
  const _ToolButton({required this.icon, required this.label, required this.enabled, this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = enabled ? (color ?? _Colors.textMain) : _Colors.disabled;
    return SizedBox(
      width: 60,
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