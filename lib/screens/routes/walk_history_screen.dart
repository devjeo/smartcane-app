import 'package:flutter/material.dart';
import '../../models/route_model.dart';
import '../../services/route_service.dart';
import '../../theme/app_colors.dart';
import 'live_walk_screen.dart';

/// Past walks of a cane, newest first. Tap one to see where it went.
class WalkHistoryScreen extends StatefulWidget {
  final String deviceId;
  final String? deviceName;
  final String? routeId; // only the walks of this route, when given

  const WalkHistoryScreen({
    super.key,
    required this.deviceId,
    this.deviceName,
    this.routeId,
  });

  @override
  State<WalkHistoryScreen> createState() => _WalkHistoryScreenState();
}

class _WalkHistoryScreenState extends State<WalkHistoryScreen> {
  List<RouteSession> _walks = [];
  bool _loading = true;
  String? _error;

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
      final w = await RouteService.instance.fetchSessions(widget.deviceId, routeId: widget.routeId);
      if (!mounted) return;
      setState(() {
        _walks = w;
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

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  String _when(DateTime t) =>
      '${t.day} ${_months[t.month - 1]}, ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _length(RouteSession s) {
    final end = s.endedAt ?? s.lastUpdate;
    final d = end.difference(s.startedAt);
    if (d.inMinutes < 1) return 'under 1 min';
    if (d.inHours < 1) return '${d.inMinutes} min';
    return '${d.inHours} h ${d.inMinutes % 60} min';
  }

  (String, Color) _label(RouteSession s) {
    switch (s.status) {
      case 'completed':
        return ('Arrived', AppColors.success);
      case 'cancelled':
        return ('Cancelled', AppColors.textSub);
      case 'expired':
        return ('No signal', AppColors.warning);
      default:
        return ('In progress', AppColors.primary);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.deviceName?.isNotEmpty == true ? widget.deviceName! : 'Cane';
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.card,
        elevation: 0,
        foregroundColor: AppColors.textMain,
        title: Text('$name walks',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
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
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _walks.isEmpty
                      ? ListView(children: const [
                          Padding(
                            padding: EdgeInsets.only(top: 80, left: 30, right: 30),
                            child: Text('No walks yet.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: AppColors.textSub, fontSize: 15)),
                          ),
                        ])
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 30),
                          itemCount: _walks.length,
                          itemBuilder: (_, i) => _tile(_walks[i]),
                        ),
                ),
    );
  }

  Widget _tile(RouteSession s) {
    final (label, color) = _label(s);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: AppColors.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(15),
        onTap: () => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => LiveWalkScreen(
              deviceId: widget.deviceId,
              deviceName: widget.deviceName,
              sessionId: s.id,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  s.status == 'completed' ? Icons.flag : Icons.directions_walk,
                  color: color,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.routeName.isEmpty ? 'Walk' : s.routeName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textMain)),
                    const SizedBox(height: 2),
                    Text('${_when(s.startedAt)}  -  ${_length(s)}',
                        style: const TextStyle(fontSize: 12, color: AppColors.textSub)),
                    const SizedBox(height: 4),
                    Text('${(s.fraction * 100).round()}% of ${formatDistance(s.totalM)}',
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSub)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(label,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
