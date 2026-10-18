import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/geo_point.dart';
import '../../models/route_model.dart';
import '../../services/route_service.dart';
import '../../theme/app_colors.dart';

/// Bottom sheet to search a place by name. Returns the chosen [PlaceDetails]
/// (coordinates + address) or null when closed.
///
/// Cost control: waits 500 ms after typing stops, needs 3+ characters, and
/// uses one session token for the typing and the final lookup so Google bills
/// the whole search as one.
Future<PlaceDetails?> showPlaceSearchSheet(
  BuildContext context, {
  required String deviceId,
  required String title,
  GeoPoint? bias,
}) {
  return showModalBottomSheet<PlaceDetails>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _PlaceSearchSheet(deviceId: deviceId, title: title, bias: bias),
  );
}

class _PlaceSearchSheet extends StatefulWidget {
  final String deviceId;
  final String title;
  final GeoPoint? bias;
  const _PlaceSearchSheet({required this.deviceId, required this.title, required this.bias});

  @override
  State<_PlaceSearchSheet> createState() => _PlaceSearchSheetState();
}

class _PlaceSearchSheetState extends State<_PlaceSearchSheet> {
  final _controller = TextEditingController();
  final _service = RouteService.instance;
  final String _token = RouteService.newSessionToken();
  Timer? _debounce;

  List<PlaceSuggestion> _results = [];
  bool _loading = false;
  bool _picking = false;
  String? _error;
  String _lastQuery = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    final q = text.trim();
    if (q.length < 3) {
      setState(() {
        _results = [];
        _error = null;
        _loading = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 500), () => _search(q));
  }

  Future<void> _search(String q) async {
    if (q == _lastQuery) return;
    _lastQuery = q;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await _service.autocomplete(
        deviceId: widget.deviceId,
        input: q,
        sessionToken: _token,
        bias: widget.bias,
      );
      if (!mounted || _controller.text.trim() != q) return;
      setState(() {
        _results = r;
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

  Future<void> _pick(PlaceSuggestion s) async {
    if (_picking) return;
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final d = await _service.placeDetails(
        deviceId: widget.deviceId,
        placeId: s.placeId,
        sessionToken: _token,
      );
      // Keep the short, readable name as the label when Google gives one.
      final label = s.main.isNotEmpty ? s.main : d.address;
      if (!mounted) return;
      Navigator.of(context).pop(PlaceDetails(
        placeId: d.placeId,
        address: label,
        lat: d.lat,
        lng: d.lng,
      ));
    } on RouteException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _picking = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: insets),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
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
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(widget.title,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textMain)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: AppColors.textSub),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _controller,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: _onChanged,
                decoration: InputDecoration(
                  hintText: 'Type at least 3 letters',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _loading || _picking
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      : null,
                  filled: true,
                  fillColor: AppColors.bg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Text(_error!,
                    style: const TextStyle(color: AppColors.alert, fontSize: 13)),
              ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.only(top: 8),
                itemCount: _results.length,
                separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.border),
                itemBuilder: (_, i) {
                  final s = _results[i];
                  return ListTile(
                    leading: const Icon(Icons.place_outlined, color: AppColors.primary),
                    title: Text(s.main,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: s.secondary.isEmpty ? null : Text(s.secondary),
                    onTap: _picking ? null : () => _pick(s),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
