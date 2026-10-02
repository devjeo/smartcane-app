import 'dart:async';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../services/supabase_service.dart';
import 'device_provisioning_service.dart';

class _Colors {
  static const bg = Color(0xFFF8FAFC);
  static const card = Color(0xFFFFFFFF);
  static const textMain = Color(0xFF1E293B);
  static const textSub = Color(0xFF64748B);
  static const border = Color(0xFFE2E8F0);
  static const primary = Color(0xFF007BFF);
  static const accent = Color(0xFF7C3AED);
  static const disabled = Color(0xFFCBD5E1);
  static const danger = Color(0xFFDC2626);
  static const success = Color(0xFF16A34A);
}

/// Steps of the "Setup New Cane" flow. The cane has no screen or keyboard, so
/// the phone shows a QR code (hotspot name + password + one-time pairing
/// token) and the cane reads it with its camera. See cane_boot.py on the Pi.
enum _SetupStep {
  enterHotspot, // owner types their phone's hotspot name + password
  creatingCode, // asking Supabase for a one-time pairing token
  showQr, // QR on screen; waiting for the cane to scan it and pair
  success, // the cane claimed the token -- it is now linked to this account
  error,
}

class AddDeviceScreen extends StatefulWidget {
  const AddDeviceScreen({super.key});

  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  String _activeMode = 'setup';

  // --- Setup New Cane state ---
  final _deviceNameController = TextEditingController();
  final _hotspotSsidController = TextEditingController();
  final _hotspotPasswordController = TextEditingController();
  bool _showPassword = false;

  _SetupStep _setupStep = _SetupStep.enterHotspot;
  String _formError = '';
  String _errorMessage = '';
  String _qrData = '';
  String _pairedDeviceId = '';
  Duration _timeLeft = DeviceProvisioningService.codeLifetime;
  Timer? _countdown;
  int _generation = 0; // bumped to cancel an in-flight wait for the cane

  final _provisioningService = DeviceProvisioningService();

  // --- Join as Caregiver state ---
  final _codeController = TextEditingController();
  bool _isJoining = false;

  final _dbService = SupabaseService.instance;

  @override
  void initState() {
    super.initState();
    _codeController.addListener(() => setState(() {}));
    // Re-evaluate the "Show Setup Code" button as the person types.
    _hotspotSsidController.addListener(() => setState(() {}));
    _hotspotPasswordController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _cancelWait();
    _deviceNameController.dispose();
    _hotspotSsidController.dispose();
    _hotspotPasswordController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Setup New Cane -- QR pairing
  // ---------------------------------------------------------------------

  void _cancelWait() {
    _generation++;
    _countdown?.cancel();
    _countdown = null;
  }

  /// Validates the hotspot details, gets a one-time token from Supabase,
  /// shows the QR, and starts waiting for the cane to claim it. Also used by
  /// "Create a new code" (each code is single-use and expires).
  Future<void> _generateCode() async {
    final ssid = _hotspotSsidController.text.trim();
    final password = _hotspotPasswordController.text;

    final problem = _provisioningService.validateHotspot(ssid, password);
    if (problem != null) {
      setState(() => _formError = problem);
      return;
    }

    FocusScope.of(context).unfocus();
    _cancelWait();
    setState(() {
      _formError = '';
      _errorMessage = '';
      _setupStep = _SetupStep.creatingCode;
    });

    try {
      final nickname = _deviceNameController.text.trim().isNotEmpty
          ? _deviceNameController.text.trim()
          : 'My Smart Cane';
      final token = await _provisioningService.createPairingToken(nickname);
      if (!mounted) return;

      final qr = _provisioningService.buildQrPayload(
        ssid: ssid,
        password: password,
        token: token,
      );

      final myGeneration = ++_generation;
      final expiresAt = DateTime.now().add(DeviceProvisioningService.codeLifetime);
      setState(() {
        _qrData = qr;
        _timeLeft = DeviceProvisioningService.codeLifetime;
        _setupStep = _SetupStep.showQr;
      });

      _countdown = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || myGeneration != _generation) return;
        final left = expiresAt.difference(DateTime.now());
        setState(() => _timeLeft = left.isNegative ? Duration.zero : left);
      });

      unawaited(_waitForClaim(token, myGeneration));
    } catch (e) {
      _failSetup(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// Polls Supabase until the cane claims the token (or the server says it
  /// expired). Network blips are ignored -- the phone may switch networks
  /// while its hotspot is being used by the cane.
  Future<void> _waitForClaim(String token, int generation) async {
    while (mounted && generation == _generation) {
      try {
        final result = await _provisioningService.checkStatus(token);
        if (!mounted || generation != _generation) return;

        if (result.state == PairingState.claimed) {
          _cancelWait();
          setState(() {
            _pairedDeviceId = result.deviceId ?? '';
            _setupStep = _SetupStep.success;
          });
          return;
        }
        if (result.state == PairingState.expired) {
          _failSetup(
            'The setup code expired before the cane used it. '
            'Create a new code and show it to the cane again.',
          );
          return;
        }
      } catch (_) {
        // Transient network error -- keep polling.
      }
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  void _failSetup(String message) {
    _cancelWait();
    if (!mounted) return;
    setState(() {
      _setupStep = _SetupStep.error;
      _errorMessage = message;
    });
  }

  void _backToHotspotForm() {
    _cancelWait();
    setState(() {
      _setupStep = _SetupStep.enterHotspot;
      _errorMessage = '';
      _formError = '';
    });
  }

  // ---------------------------------------------------------------------
  // Join as Caregiver — unchanged
  // ---------------------------------------------------------------------

  Future<void> _joinAsCaregiver() async {
    setState(() => _isJoining = true);
    try {
      final caneData = await _dbService.getDeviceByShareCode(_codeController.text.toUpperCase());

      debugPrint('Search result for share code: $caneData');

      if (caneData == null) {
        if (mounted) await _alert('Error', 'Invalid Share Code. Please check the code and try again.');
        setState(() => _isJoining = false);
        return;
      }

      try {
        await _dbService.joinAsCaregiver(caneData['id']);
      } catch (shareError) {
        debugPrint('REAL INSERT ERROR: $shareError');
        if (mounted) await _alert('Error', 'You are already linked to this device!');
        setState(() => _isJoining = false);
        return;
      }

      if (mounted) {
        await _alert('Success!', 'You are now a viewer for ${caneData['name']}');
        if (mounted) Navigator.of(context).pushReplacementNamed('/');
      }
    } catch (e) {
      debugPrint('$e');
      setState(() => _isJoining = false);
    }
  }

  Future<void> _alert(String title, String message) {
    return showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final code = _codeController.text;
    final midFlow = _activeMode == 'setup' && _setupStep != _SetupStep.enterHotspot;

    return Scaffold(
      backgroundColor: _Colors.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _CircleIconButton(icon: Icons.arrow_back, onTap: _handleBack),
                  const Text('Add Device', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _Colors.textMain)),
                  const SizedBox(width: 40),
                ],
              ),
            ),

            if (midFlow)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: _StepProgress(step: _setupStep),
              )
            else
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 20),
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(color: const Color(0xFFE2E8F0), borderRadius: BorderRadius.circular(12)),
                child: Row(
                  children: [
                    Expanded(child: _ToggleButton(label: 'Setup New Cane', active: _activeMode == 'setup', onTap: () => setState(() => _activeMode = 'setup'))),
                    Expanded(child: _ToggleButton(label: 'Join as Caregiver', active: _activeMode == 'join', onTap: () => setState(() => _activeMode = 'join'))),
                  ],
                ),
              ),

            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 30, 20, 20),
                child: _activeMode == 'setup' ? _buildSetupWizard() : _buildJoinMode(code),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _handleBack() {
    // Leaving mid-flow just stops waiting; the unused token expires by itself.
    _cancelWait();
    Navigator.of(context).pop();
  }

  Widget _buildSetupWizard() {
    switch (_setupStep) {
      case _SetupStep.enterHotspot:
        return _buildEnterHotspotStep();
      case _SetupStep.creatingCode:
        return _buildLoadingStep('Creating your setup code...');
      case _SetupStep.showQr:
        return _buildShowQrStep();
      case _SetupStep.success:
        return _buildSuccessStep();
      case _SetupStep.error:
        return _buildErrorStep();
    }
  }

  Widget _buildEnterHotspotStep() {
    final ready = _hotspotSsidController.text.trim().isNotEmpty &&
        _hotspotPasswordController.text.isNotEmpty;

    return SingleChildScrollView(
      child: Column(
        children: [
          Container(
            width: 80,
            height: 80,
            margin: const EdgeInsets.only(bottom: 20),
            decoration: const BoxDecoration(color: Color(0xFFE6F2FF), shape: BoxShape.circle),
            child: const Icon(Icons.wifi_tethering, size: 48, color: _Colors.primary),
          ),
          const Text(
            "Turn on your phone's hotspot, then enter its name and password. "
            'Your cane uses it to get online. Next, you will show a QR code '
            "to the cane's camera to pair it.",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: _Colors.textSub, height: 1.6),
          ),
          const SizedBox(height: 24),
          _LabeledField(
            label: 'Device Nickname',
            icon: Icons.text_fields_outlined,
            controller: _deviceNameController,
            hint: "e.g., Patient's Cane",
          ),
          const SizedBox(height: 14),
          _LabeledField(
            label: 'Hotspot Name',
            icon: Icons.wifi_tethering,
            controller: _hotspotSsidController,
            hint: "Your phone's hotspot name",
            plain: true,
          ),
          const SizedBox(height: 14),
          _LabeledField(
            label: 'Hotspot Password',
            icon: Icons.lock_outline,
            controller: _hotspotPasswordController,
            hint: '8 characters or more',
            obscure: !_showPassword,
            plain: true,
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(() => _showPassword = !_showPassword),
              child: Text(_showPassword ? 'Hide password' : 'Show password'),
            ),
          ),
          if (_formError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                _formError,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: _Colors.danger, height: 1.5),
              ),
            ),
          _PrimaryButton(
            label: 'Show Setup Code',
            color: _Colors.primary,
            enabled: ready,
            onTap: _generateCode,
          ),
        ],
      ),
    );
  }

  String get _timeLeftLabel {
    final minutes = _timeLeft.inMinutes;
    final seconds = (_timeLeft.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Widget _buildShowQrStep() {
    final expired = _timeLeft == Duration.zero;

    return SingleChildScrollView(
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _Colors.border),
            ),
            // Low error correction = fewer, bigger squares, which a small
            // camera reads far more reliably off a phone screen.
            child: QrImageView(
              data: _qrData,
              version: QrVersions.auto,
              size: 260,
              backgroundColor: Colors.white,
              errorCorrectionLevel: QrErrorCorrectLevel.L,
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            "Hold this screen 20-30 cm in front of the cane's camera and turn "
            'your screen brightness up. Keep your hotspot on. The cane will say '
            '"Code received" and connect.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: _Colors.textSub, height: 1.6),
          ),
          const SizedBox(height: 16),
          if (expired)
            const Text(
              'This code has expired.',
              style: TextStyle(fontSize: 14, color: _Colors.danger, fontWeight: FontWeight.w600),
            )
          else
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: _Colors.primary)),
                const SizedBox(width: 10),
                Text(
                  'Waiting for your cane...  $_timeLeftLabel',
                  style: const TextStyle(fontSize: 14, color: _Colors.textMain, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          const SizedBox(height: 16),
          TextButton(onPressed: _generateCode, child: const Text('Create a new code')),
          TextButton(onPressed: _backToHotspotForm, child: const Text('Change hotspot details')),
        ],
      ),
    );
  }

  Widget _buildSuccessStep() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(color: Color(0xFFDCFCE7), shape: BoxShape.circle),
            child: const Icon(Icons.check_circle_outline, size: 40, color: _Colors.success),
          ),
          const SizedBox(height: 20),
          const Text('Smart Cane paired!', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _Colors.textMain)),
          if (_pairedDeviceId.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(_pairedDeviceId, style: const TextStyle(fontSize: 14, color: _Colors.textSub)),
          ],
          const SizedBox(height: 8),
          const Text(
            'It will show up on your dashboard.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: _Colors.textSub),
          ),
          const SizedBox(height: 24),
          _PrimaryButton(
            label: 'Done',
            color: _Colors.primary,
            enabled: true,
            onTap: () => Navigator.of(context).pushReplacementNamed('/'),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingStep(String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 44, height: 44, child: CircularProgressIndicator(strokeWidth: 3, color: _Colors.primary)),
          const SizedBox(height: 24),
          Text(message, textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, color: _Colors.textMain, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildErrorStep() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(color: Color(0xFFFEE2E2), shape: BoxShape.circle),
            child: const Icon(Icons.error_outline, size: 40, color: _Colors.danger),
          ),
          const SizedBox(height: 20),
          Text(_errorMessage, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, color: _Colors.textMain, height: 1.5)),
          const SizedBox(height: 24),
          _PrimaryButton(label: 'Try Again', color: _Colors.primary, enabled: true, onTap: _backToHotspotForm),
        ],
      ),
    );
  }

  Widget _buildJoinMode(String code) {
    final canSubmit = code.length == 6 && !_isJoining;
    return SingleChildScrollView(
      child: Column(
        children: [
          Container(
            width: 80,
            height: 80,
            margin: const EdgeInsets.only(bottom: 20),
            decoration: const BoxDecoration(color: Color(0xFFF3E8FF), shape: BoxShape.circle),
            child: const Icon(Icons.people, size: 48, color: _Colors.accent),
          ),
          const Text(
            "Enter the 6-digit Share Code provided by the Primary Guardian to view their cane's location.",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: _Colors.textSub, height: 1.6),
          ),
          const SizedBox(height: 30),
          _LabeledField(
            label: 'Share Code',
            icon: Icons.key_outlined,
            controller: _codeController,
            hint: 'A7X9BQ',
            capitalize: true,
            maxLength: 6,
            enabled: !_isJoining,
            bold: true,
          ),
          const SizedBox(height: 10),
          _PrimaryButton(
            label: _isJoining ? 'Verifying Code...' : 'Join',
            color: _Colors.accent,
            enabled: canSubmit,
            loading: _isJoining,
            onTap: _joinAsCaregiver,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Small reusable widgets
// ---------------------------------------------------------------------

class _PrimaryButton extends StatelessWidget {
  final String label;
  final Color color;
  final bool enabled;
  final bool loading;
  final VoidCallback onTap;
  const _PrimaryButton({required this.label, required this.color, required this.enabled, required this.onTap, this.loading = false});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 55,
      child: ElevatedButton(
        onPressed: enabled ? onTap : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: enabled ? color : _Colors.disabled,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: loading
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                  const SizedBox(width: 10),
                  Text(label, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              )
            : Text(label, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
      ),
    );
  }
}

class _ToggleButton extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _ToggleButton({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: active ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          boxShadow: active ? const [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2))] : null,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: active ? _Colors.textMain : _Colors.textSub),
        ),
      ),
    );
  }
}

class _LabeledField extends StatelessWidget {
  final String label;
  final IconData icon;
  final TextEditingController controller;
  final String hint;
  final bool capitalize;
  final bool bold;
  final bool obscure;
  final int? maxLength;
  final bool enabled;
  final bool plain; // no autocorrect/suggestions (for SSIDs and passwords)

  const _LabeledField({
    required this.label,
    required this.icon,
    required this.controller,
    required this.hint,
    this.capitalize = false,
    this.bold = false,
    this.obscure = false,
    this.maxLength,
    this.enabled = true,
    this.plain = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _Colors.textMain)),
        const SizedBox(height: 8),
        Container(
          height: 55,
          padding: const EdgeInsets.symmetric(horizontal: 15),
          decoration: BoxDecoration(
            color: _Colors.card,
            border: Border.all(color: _Colors.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: _Colors.textSub),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: controller,
                  enabled: enabled,
                  maxLength: maxLength,
                  obscureText: obscure,
                  autocorrect: !plain,
                  enableSuggestions: !plain,
                  textCapitalization: capitalize ? TextCapitalization.characters : TextCapitalization.none,
                  style: TextStyle(
                    fontSize: 16,
                    color: _Colors.textMain,
                    fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                    letterSpacing: bold ? 3 : 0,
                  ),
                  decoration: InputDecoration(
                    hintText: hint,
                    hintStyle: const TextStyle(color: _Colors.textSub),
                    border: InputBorder.none,
                    counterText: '',
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CircleIconButton({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(color: _Colors.card, shape: BoxShape.circle, border: Border.all(color: _Colors.border)),
        child: Icon(icon, size: 24, color: _Colors.textMain),
      ),
    );
  }
}

class _StepProgress extends StatelessWidget {
  final _SetupStep step;
  const _StepProgress({required this.step});

  int get _index {
    switch (step) {
      case _SetupStep.enterHotspot:
        return 0;
      case _SetupStep.creatingCode:
        return 1;
      case _SetupStep.showQr:
        return 1;
      case _SetupStep.success:
        return 2;
      case _SetupStep.error:
        return 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    const labels = ['Hotspot', 'Show code', 'Done'];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: List.generate(labels.length, (i) {
          final active = i <= _index;
          return Expanded(
            child: Container(
              height: 4,
              margin: EdgeInsets.only(left: i == 0 ? 0 : 4, right: i == labels.length - 1 ? 0 : 4),
              decoration: BoxDecoration(
                color: active ? _Colors.primary : _Colors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          );
        }),
      ),
    );
  }
}