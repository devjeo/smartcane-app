import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/supabase_service.dart';
import '../link_as_user/link_as_user_screen.dart';

/// Guardian side: scans the QR shown on the future user's phone
/// (Settings -> Link me as a cane user) and links that person to [deviceId].
/// Pops with the `claim_user_link` result map on success.
class ScanUserQrScreen extends StatefulWidget {
  final String deviceId;
  const ScanUserQrScreen({super.key, required this.deviceId});

  @override
  State<ScanUserQrScreen> createState() => _ScanUserQrScreenState();
}

class _ScanUserQrScreenState extends State<ScanUserQrScreen> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.normal,
    detectionTimeoutMs: 1500,
  );

  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _friendly(Object e) {
    final raw = e is PostgrestException ? e.message : e.toString();
    if (raw.contains('invalid, used or expired')) {
      return 'That code is expired or was already used. Ask for a new one.';
    }
    if (raw.contains('own cane')) {
      return 'You cannot link yourself. The cane user must scan with their own account.';
    }
    if (raw.contains('not allowed')) {
      return 'Only this cane\'s guardian can link a user.';
    }
    return raw.replaceFirst('Exception: ', '');
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_busy) return;

    String? token;
    for (final b in capture.barcodes) {
      final v = b.rawValue;
      if (v != null && v.startsWith(LinkAsUserScreen.qrPrefix)) {
        token = v.substring(LinkAsUserScreen.qrPrefix.length);
        break;
      }
    }
    if (token == null || token.isEmpty) {
      if (capture.barcodes.isNotEmpty && mounted) {
        setState(() => _message = 'That is not a SmartCane user code.');
      }
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final result = await SupabaseService.instance.claimUserLink(widget.deviceId, token);
      if (mounted) Navigator.of(context).pop(result);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = _friendly(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan the user\'s QR'),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  error.errorCode == MobileScannerErrorCode.permissionDenied
                      ? 'Camera permission is needed to scan the code. Allow it in the app settings.'
                      : 'Could not start the camera.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
            ),
          ),
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 40,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(12),
              ),
              child: _busy
                  ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                        SizedBox(width: 12),
                        Text('Linking...', style: TextStyle(color: Colors.white)),
                      ],
                    )
                  : Text(
                      _message ??
                          'Point the camera at the QR on the cane user\'s phone\n(Settings > Link me as a cane user).',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: _message != null ? const Color(0xFFFCA5A5) : Colors.white,
                          fontSize: 14,
                          height: 1.4),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
