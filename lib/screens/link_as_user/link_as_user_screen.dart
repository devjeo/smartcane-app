import 'dart:async';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_colors.dart';

/// Shown on the phone of the person who CARRIES the cane (the "user").
/// It displays a QR code; the guardian scans it from the cane's
/// Device Settings -> Cane user -> Scan QR. The code is single-use and
/// valid for 5 minutes (enforced by the server).
///
/// QR payload: `smartcane-user:<token>`
class LinkAsUserScreen extends StatefulWidget {
  const LinkAsUserScreen({super.key});

  /// Prefix the guardian's scanner looks for.
  static const qrPrefix = 'smartcane-user:';

  @override
  State<LinkAsUserScreen> createState() => _LinkAsUserScreenState();
}

enum _Step { loading, showQr, claimed, expired, error }

class _LinkAsUserScreenState extends State<LinkAsUserScreen> {
  static const _codeLifetime = Duration(minutes: 5);

  final _db = SupabaseService.instance;

  _Step _step = _Step.loading;
  String _qrData = '';
  String _errorText = '';
  String _deviceName = '';
  Duration _timeLeft = _codeLifetime;

  Timer? _countdown;
  int _generation = 0; // bumps on every new code / dispose so old loops stop

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _generation++;
    _countdown?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    _countdown?.cancel();
    final gen = ++_generation;
    setState(() => _step = _Step.loading);

    try {
      final token = await _db.createUserLinkToken();
      if (!mounted || gen != _generation) return;

      final expiresAt = DateTime.now().add(_codeLifetime);
      setState(() {
        _qrData = '${LinkAsUserScreen.qrPrefix}$token';
        _timeLeft = _codeLifetime;
        _step = _Step.showQr;
      });

      _countdown = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || gen != _generation) return;
        final left = expiresAt.difference(DateTime.now());
        setState(() => _timeLeft = left.isNegative ? Duration.zero : left);
      });

      unawaited(_waitForClaim(token, gen));
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _errorText = e.toString().replaceFirst('Exception: ', '');
        _step = _Step.error;
      });
    }
  }

  /// Polls until the guardian has scanned the code (or it expired).
  /// Network blips are ignored.
  Future<void> _waitForClaim(String token, int gen) async {
    while (mounted && gen == _generation) {
      try {
        final r = await _db.userLinkStatus(token);
        if (!mounted || gen != _generation) return;

        if (r['claimed'] == true) {
          _countdown?.cancel();
          setState(() {
            _deviceName = (r['device_name'] as String?) ?? 'the cane';
            _step = _Step.claimed;
          });
          return;
        }
        if (r['expired'] == true) {
          _countdown?.cancel();
          setState(() => _step = _Step.expired);
          return;
        }
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        foregroundColor: AppColors.textMain,
        title: const Text('Link me as a cane user',
            style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Center(child: SingleChildScrollView(child: _body())),
        ),
      ),
    );
  }

  Widget _body() {
    switch (_step) {
      case _Step.loading:
        return const CircularProgressIndicator();

      case _Step.showQr:
        return Column(
          children: [
            const Text(
              'Ask the cane\'s guardian to open the cane in their app:\n'
              'Device Settings → Cane user → Scan QR, and scan this code.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: AppColors.textSub, height: 1.5),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
              ),
              child: QrImageView(
                data: _qrData,
                version: QrVersions.auto,
                size: 260,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _timeLeft == Duration.zero
                  ? 'Code expired'
                  : 'Code valid for ${_fmt(_timeLeft)}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: _timeLeft.inSeconds < 30 ? AppColors.alert : AppColors.textSub,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Turn your screen brightness up. This code works once.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.textSub),
            ),
            const SizedBox(height: 16),
            TextButton(onPressed: _start, child: const Text('New code')),
          ],
        );

      case _Step.claimed:
        return Column(
          children: [
            const Icon(Icons.check_circle, size: 72, color: AppColors.success),
            const SizedBox(height: 16),
            const Text('You are linked!',
                style: TextStyle(
                    fontSize: 22, fontWeight: FontWeight.bold, color: AppColors.textMain)),
            const SizedBox(height: 8),
            Text('You are now the user of $_deviceName.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15, color: AppColors.textSub)),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Done'),
            ),
          ],
        );

      case _Step.expired:
        return Column(
          children: [
            const Icon(Icons.timer_off_outlined, size: 56, color: AppColors.warning),
            const SizedBox(height: 12),
            const Text('This code has expired.',
                style: TextStyle(fontSize: 16, color: AppColors.textMain)),
            const SizedBox(height: 16),
            FilledButton(onPressed: _start, child: const Text('Show a new code')),
          ],
        );

      case _Step.error:
        return Column(
          children: [
            const Icon(Icons.error_outline, size: 56, color: AppColors.alert),
            const SizedBox(height: 12),
            Text(_errorText,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15, color: AppColors.textMain)),
            const SizedBox(height: 16),
            FilledButton(onPressed: _start, child: const Text('Try again')),
          ],
        );
    }
  }
}
