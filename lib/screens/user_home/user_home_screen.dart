import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/background_location_service.dart'
    show restartBackgroundTracking, kServiceHasMicPref, kServiceHasCamPref;
import '../../models/device_model.dart';
import '../../services/main_tab_controller.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_colors.dart';

/// "My Cane" tab: shown to accounts that CARRY a cane (share role 'user').
/// Shows the cane(s) they carry and a readiness checklist for this phone,
/// because this phone is the one that reports the cane's location (and,
/// from Phase 4, places the emergency call).
class UserHomeScreen extends StatefulWidget {
  const UserHomeScreen({super.key});

  @override
  State<UserHomeScreen> createState() => _UserHomeScreenState();
}

class _UserHomeScreenState extends State<UserHomeScreen> with WidgetsBindingObserver {
  final _db = SupabaseService.instance;

  List<Map<String, dynamic>> _canes = [];
  bool _loading = true;
  String? _loadError;
  Timer? _poll;

  LocationPermission? _loc;
  PermissionStatus? _notif;
  PermissionStatus? _mic;
  PermissionStatus? _cam;
  PermissionStatus? _batt;
  bool _svcRunning = false;
  bool _svcHasMic = false;
  bool _svcHasCam = false;
  DateTime? _lastPing;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshAll();
    // keep Online/Offline and battery fresh
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _loadCanes());
    MainTabController.rolesChanged.addListener(_loadCanes);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    MainTabController.rolesChanged.removeListener(_loadCanes);
    _poll?.cancel();
    super.dispose();
  }

  // Coming back from the system settings screen -> re-check permissions.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadPerms();
  }

  Future<void> _refreshAll() async {
    await Future.wait([_loadCanes(), _loadPerms()]);
  }

  Future<void> _loadCanes() async {
    try {
      final canes = await _db.fetchMyUserCanes();
      final running = await FlutterBackgroundService().isRunning();
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final hasMic = prefs.getBool(kServiceHasMicPref) ?? false;
      final hasCam = prefs.getBool(kServiceHasCamPref) ?? false;
      final pings = canes.isEmpty
          ? <String, DateTime>{}
          : await _db.fetchLastPhonePings(canes.map((c) => c['id'].toString()).toList());
      DateTime? newest;
      for (final t in pings.values) {
        if (newest == null || t.isAfter(newest)) newest = t;
      }
      if (!mounted) return;
      setState(() {
        _svcRunning = running;
        _svcHasMic = hasMic;
        _svcHasCam = hasCam;
        _lastPing = newest;
        _canes = canes;
        _loading = false;
        _loadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = 'Could not load your cane. Pull down to retry.';
      });
    }
  }

  Future<void> _loadPerms() async {
    try {
      final loc = await Geolocator.checkPermission();
      final notif = await Permission.notification.status;
      final mic = await Permission.microphone.status;
      final cam = await Permission.camera.status;
      final batt = await Permission.ignoreBatteryOptimizations.status;
      if (!mounted) return;
      setState(() {
        _loc = loc;
        _notif = notif;
        _mic = mic;
        _cam = cam;
        _batt = batt;
      });

      // The tracking service must carry the microphone type to keep the mic
      // in the background. If mic was granted after it started, restart it
      // (the app is visible right now, which Android requires).
      if ((mic.isGranted || cam.isGranted) && _canes.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        final needMic = mic.isGranted && !(prefs.getBool(kServiceHasMicPref) ?? false);
        final needCam = cam.isGranted && !(prefs.getBool(kServiceHasCamPref) ?? false);
        if (needMic || needCam) {
          await restartBackgroundTracking();
        }
      }
    } catch (_) {}
  }

  // ---- fixes ----
  Future<void> _fixLocation() async {
    if (_loc == LocationPermission.denied) {
      await Geolocator.requestPermission();
    } else {
      await Geolocator.openAppSettings();
    }
    await _loadPerms();
  }

  Future<void> _fixPermission(Permission p, PermissionStatus? current) async {
    if (current?.isPermanentlyDenied == true) {
      await openAppSettings();
    } else {
      await p.request();
    }
    await _loadPerms();
  }

  Future<void> _linkAnother() async {
    await Navigator.of(context).pushNamed('/link-as-user');
    MainTabController.rolesChanged.value++;
    _loadCanes();
  }

  // ---- UI ----
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _refreshAll,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
          children: [
            const Text('My Cane',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: AppColors.textMain)),
            const SizedBox(height: 4),
            const Text('Your phone shares the cane\'s location and keeps your guardian informed.',
                style: TextStyle(fontSize: 14, color: AppColors.textSub, height: 1.4)),
            const SizedBox(height: 20),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(30),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_loadError != null)
              _notice(_loadError!, AppColors.alert)
            else if (_canes.isEmpty)
              _notice('You are not linked to any cane yet.', AppColors.textSub)
            else
              for (final c in _canes) _caneCard(c),
            const SizedBox(height: 4),
            OutlinedButton.icon(
              onPressed: _linkAnother,
              icon: const Icon(Icons.qr_code_2),
              label: const Text('Link me to another cane'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 28),
            if (!_loading && _loadError == null && _canes.isNotEmpty) ...[
              _protectionCard(),
              const SizedBox(height: 24),
            ],
            const Text('Phone readiness',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textMain)),
            const SizedBox(height: 4),
            const Text('Fix anything marked in orange so your phone keeps working with the screen off.',
                style: TextStyle(fontSize: 13, color: AppColors.textSub, height: 1.4)),
            const SizedBox(height: 12),
            _checklist(),
            const SizedBox(height: 16),
            _samsungTip(),
          ],
        ),
      ),
    );
  }

  /// (ok, headline, detail). ON only when an SOS could really start a call.
  (bool, String, String) _protection() {
    if (_mic?.isGranted != true) {
      return (false, 'Call protection: OFF', 'Microphone permission is missing. Tap Fix on Microphone below.');
    }
    if (!_svcRunning) {
      return (false, 'Call protection: OFF',
          'The background service is not running. Keep this app open for a moment, or restart your phone and open SmartCane once.');
    }
    if (!_svcHasMic) {
      return (false, 'Call protection: OFF',
          'The service started before the microphone was allowed. It is restarting; keep this screen open.');
    }
    final anyOnline = _canes.any((c) {
      final raw = c['last_seen_at'] as String?;
      final t = raw != null ? DateTime.tryParse(raw) : null;
      return t != null && DateTime.now().difference(t) < DeviceModel.onlineWindow;
    });
    if (anyOnline) {
      final stale = _lastPing == null ||
          DateTime.now().difference(_lastPing!) > const Duration(minutes: 2);
      if (stale) {
        return (false, 'Call protection: OFF',
            'This phone has not reported its location for over 2 minutes. Check location "Allow all the time" and battery settings below.');
      }
    }
    // Voice protection is ON; the camera only affects live video.
    final camLine = (_cam?.isGranted == true && _svcHasCam)
        ? 'Camera: ready for live video.'
        : 'Camera: not ready, so live video is unavailable (voice still works).';
    return (true, 'Call protection: ON',
        '${anyOnline ? 'An SOS will call your guardian, even with the screen off.' : 'Ready. Waiting for your cane to come online.'}\n$camLine');
  }

  Widget _protectionCard() {
    final (ok, title, detail) = _protection();
    final color = ok ? AppColors.success : AppColors.warning;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ok ? Icons.verified_user : Icons.gpp_maybe, color: color, size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
                const SizedBox(height: 3),
                Text(detail,
                    style: const TextStyle(fontSize: 13, color: AppColors.textMain, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _notice(String text, Color color) => Container(
        padding: const EdgeInsets.all(16),
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: AppColors.border),
        ),
        child: Text(text, style: TextStyle(fontSize: 14, color: color)),
      );

  Widget _caneCard(Map<String, dynamic> c) {
    final lastSeenRaw = c['last_seen_at'] as String?;
    final lastSeen = lastSeenRaw != null ? DateTime.tryParse(lastSeenRaw) : null;
    final online = lastSeen != null &&
        DateTime.now().difference(lastSeen) < DeviceModel.onlineWindow;
    final battery = c['battery_level'] as int? ?? 0;
    final guardian = (c['guardian'] as Map?)?['full_name'] as String?;
    final color = online ? AppColors.online : AppColors.offline;

    return Container(
      padding: const EdgeInsets.all(18),
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.accessible_forward, size: 30, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Text(c['name'] as String? ?? 'Smart Cane',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textMain)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(online ? 'Online' : 'Offline',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(online ? Icons.battery_charging_full : Icons.battery_unknown,
                  size: 18, color: color),
              const SizedBox(width: 6),
              Text(online ? '$battery%' : 'Battery unknown',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: color)),
              const SizedBox(width: 18),
              const Icon(Icons.shield_outlined, size: 18, color: AppColors.textSub),
              const SizedBox(width: 6),
              Flexible(
                child: Text('Guardian: ${guardian?.trim().isNotEmpty == true ? guardian : 'unknown'}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, color: AppColors.textMain)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.of(context).pushNamed('/routes', arguments: {
                'id': c['id'].toString(),
                'name': c['name'] as String?,
              }),
              icon: const Icon(Icons.directions_walk),
              label: const Text('Walking routes'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _checklist() {
    final locOk = _loc == LocationPermission.always;
    final locPartial = _loc == LocationPermission.whileInUse;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          _CheckRow(
            title: 'Location: allow all the time',
            okText: 'Your location is shared even when the screen is off.',
            fixText: locPartial
                ? 'Currently "only while using the app". Choose "Allow all the time".'
                : 'Needed so your guardian can see where the cane is.',
            ok: locOk,
            known: _loc != null,
            onFix: _fixLocation,
          ),
          const Divider(height: 1, color: AppColors.border),
          _CheckRow(
            title: 'Notifications',
            okText: 'You will see the app\'s status and alerts.',
            fixText: 'Needed for the background service notification.',
            ok: _notif?.isGranted == true,
            known: _notif != null,
            onFix: () => _fixPermission(Permission.notification, _notif),
          ),
          const Divider(height: 1, color: AppColors.border),
          _CheckRow(
            title: 'Microphone',
            okText: 'Ready for emergency calls to your guardian.',
            fixText: 'Needed so you can talk to your guardian in an emergency call.',
            ok: _mic?.isGranted == true,
            known: _mic != null,
            onFix: () => _fixPermission(Permission.microphone, _mic),
          ),
          const Divider(height: 1, color: AppColors.border),
          _CheckRow(
            title: 'Camera (for live video)',
            okText: 'Ready to share your camera if your guardian asks.',
            fixText: 'Needed only for live video. Voice calls work without it.',
            ok: _cam?.isGranted == true,
            known: _cam != null,
            onFix: () => _fixPermission(Permission.camera, _cam),
          ),
          const Divider(height: 1, color: AppColors.border),
          _CheckRow(
            title: 'Battery: unrestricted',
            okText: 'Android will not put the app to sleep.',
            fixText: 'Without this, Android may stop the app in the background.',
            ok: _batt?.isGranted == true,
            known: _batt != null,
            onFix: () => _fixPermission(Permission.ignoreBatteryOptimizations, _batt),
          ),
        ],
      ),
    );
  }

  Widget _samsungTip() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFBEB),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFFDE68A)),
        ),
        child: const Text(
          'Samsung phones: also open Settings > Battery > Background usage limits and make sure SmartCane is '
          'not in "Sleeping apps" or "Deep sleeping apps". On other brands, look for "Autostart" or '
          '"Battery saver" and allow SmartCane.',
          style: TextStyle(fontSize: 12, color: Color(0xFF92400E), height: 1.5),
        ),
      );
}

class _CheckRow extends StatelessWidget {
  final String title;
  final String okText;
  final String fixText;
  final bool ok;
  final bool known;
  final VoidCallback onFix;

  const _CheckRow({
    required this.title,
    required this.okText,
    required this.fixText,
    required this.ok,
    required this.known,
    required this.onFix,
  });

  @override
  Widget build(BuildContext context) {
    final color = !known ? AppColors.offline : (ok ? AppColors.success : AppColors.warning);
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(ok ? Icons.check_circle : Icons.error_outline, color: color, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textMain)),
                const SizedBox(height: 2),
                Text(ok ? okText : fixText,
                    style: const TextStyle(fontSize: 12, color: AppColors.textSub, height: 1.4)),
              ],
            ),
          ),
          if (known && !ok)
            TextButton(
              onPressed: onFix,
              child: const Text('Fix', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
        ],
      ),
    );
  }
}