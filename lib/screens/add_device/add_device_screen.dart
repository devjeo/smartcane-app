import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import '../../services/supabase_service.dart';
import '../../services/pending_device_store.dart';
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

/// Steps of the "Setup New Cane" provisioning wizard.
enum _SetupStep {
  searching, // Android: automatic scan + join of the cane's open hotspot
  awaitingManualJoin, // fallback: instructs the person to join via system WiFi settings
  foundDevice, // we know the deviceId and are already joined to its network; user names it
  connectingToDevice, // confirms identity over HTTP once joined
  scanningNetworks, // asking the cane to scan for nearby WiFi
  selectNetwork, // user picks a network + enters its password
  finalizing, // cane is joining home WiFi; then we register it in Supabase
  error,
}

class AddDeviceScreen extends StatefulWidget {
  final String? deepLinkId;
  const AddDeviceScreen({super.key, this.deepLinkId});

  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> with WidgetsBindingObserver {
  String _activeMode = 'setup';

  // --- Setup New Cane state ---
  // Holds whichever deviceId we're currently acting on — either detected
  // from the network the phone joined, or supplied via a deep link. Never
  // typed by hand.
  String _selectedDeviceId = '';
  // True only for the deep-link path, where we know the exact SSID up
  // front and can join it programmatically. For the manual-join path the
  // phone is already connected by the time we know the deviceId, so no
  // further join step is needed.
  bool _needsAutoJoin = false;
  final _deviceNameController = TextEditingController();
  final _networkPasswordController = TextEditingController();
  final _manualSsidController = TextEditingController();

  _SetupStep _setupStep = _SetupStep.searching;
  String _statusMessage = '';
  String _errorMessage = '';
  List<ScannedNetwork> _networks = [];
  ScannedNetwork? _selectedNetwork;
  bool _enterNetworkManually = false;

  final _provisioningService = DeviceProvisioningService();

  // --- Join as Caregiver state ---
  final _codeController = TextEditingController();
  bool _isJoining = false;

  final _dbService = SupabaseService.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _codeController.addListener(() => setState(() {}));

    if (widget.deepLinkId != null && widget.deepLinkId!.isNotEmpty) {
      // A QR code or share link already told us exactly which cane this is
      // — we know the SSID up front, so we can join it directly instead of
      // running a scan at all.
      _activeMode = 'setup';
      _selectedDeviceId = widget.deepLinkId!.trim().toUpperCase();
      _needsAutoJoin = true;
      _setupStep = _SetupStep.foundDevice;
      debugPrint('Deep link detected for device: ${widget.deepLinkId}');
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _beginAutoDiscovery());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Only relevant to the manual fallback: the person left the app to join
    // the hotspot in system WiFi settings — check automatically the moment
    // they come back, so most of the time they never have to tap
    // "I've Connected" themselves.
    if (state == AppLifecycleState.resumed && _setupStep == _SetupStep.awaitingManualJoin) {
      _checkForCaneConnection();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _deviceNameController.dispose();
    _networkPasswordController.dispose();
    _manualSsidController.dispose();
    _codeController.dispose();
    // Make sure we don't leave the phone stuck routing traffic to a
    // hotspot that may no longer exist if the user backs out mid-flow.
    _provisioningService.disconnectFromDeviceHotspot();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Setup New Cane — provisioning wizard
  // ---------------------------------------------------------------------

  /// Primary path: scans for a nearby cane and joins its (open) hotspot
  /// automatically — the person never leaves the app. Android only; on
  /// iOS, or if nothing turns up, this falls back to the manual step.
  Future<void> _beginAutoDiscovery() async {
    if (!mounted) return;
    setState(() {
      _setupStep = _SetupStep.searching;
      _statusMessage = 'Looking for a nearby Smart Cane...';
      _errorMessage = '';
    });

    try {
      final id = await _provisioningService.autoDiscoverAndJoin();
      if (!mounted) return;
      if (id == null) {
        _fallBackToManualJoin(
          "No Smart Cane was found nearby. Make sure it's powered on and "
          "blinking blue, then try again — or join its network manually "
          'below.',
        );
        return;
      }
      setState(() {
        _selectedDeviceId = id;
        _needsAutoJoin = false; // already joined during discovery
        _setupStep = _SetupStep.foundDevice;
      });
    } on UnsupportedError {
      // iOS: there's no public API for a third-party app to scan nearby
      // WiFi networks — that's an Apple platform restriction, not
      // something this app can route around.
      _fallBackToManualJoin(
        "Your phone can't automatically search for WiFi networks on iOS. "
        "Join the cane's network manually below instead — it only takes a "
        'second.',
      );
    } catch (e) {
      _fallBackToManualJoin(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _fallBackToManualJoin(String message) {
    if (!mounted) return;
    setState(() {
      _setupStep = _SetupStep.awaitingManualJoin;
      _statusMessage = message;
    });
  }

  /// Checks whether the phone is currently joined to a cane's setup
  /// hotspot — called automatically on app resume, and also wired to an
  /// explicit "I've Connected" button in case the lifecycle callback ever
  /// doesn't fire (e.g. the person was already connected before opening
  /// this screen).
  ///
  /// In debug builds this skips the "actually joined" requirement — see
  /// [_bypassIfCaneDetectedNearby] — since main.py's `--skip-hotspot`
  /// harness runs on the regular WiFi network rather than hosting its own
  /// "SmartCane-..." hotspot, so the phone can never really be joined to
  /// it. Detection still has to be real: the bypass only fires if a
  /// genuine SmartCane SSID shows up in a scan.
  Future<void> _checkForCaneConnection() async {
    if (!mounted || _setupStep != _SetupStep.awaitingManualJoin) return;

    if (kDebugMode) {
      await _bypassIfCaneDetectedNearby();
      return;
    }

    try {
      final id = await _provisioningService.currentDeviceIdIfOnCaneHotspot();
      if (!mounted) return;
      if (id == null) {
        setState(() {
          _statusMessage = 'Not connected yet — join the network that starts '
              'with "SmartCane-" in WiFi settings, then come back here.';
        });
        return;
      }
      setState(() {
        _selectedDeviceId = id;
        _needsAutoJoin = false; // already connected, nothing left to join
        _setupStep = _SetupStep.foundDevice;
      });
    } on UnknownSsidException catch (e) {
      if (!mounted) return;
      setState(() => _statusMessage = e.toString());
    }
  }

  /// TEST-ONLY: stands in for [_checkForCaneConnection] succeeding without
  /// actually being joined to a cane's hotspot — but only when a real
  /// "SmartCane-..." network is genuinely detected nearby. The deviceId is
  /// read straight off that SSID (see [DeviceProvisioningService.
  /// scanForNearbyCaneId]), never typed in, so this only ever proceeds if
  /// a cane is actually around; if none is detected, it behaves like the
  /// normal "not connected yet" case. Skipping the join itself (rather
  /// than the detection) makes sense here because [DeviceProvisioningService]
  /// talks to a hardcoded test address, not the hotspot's own address —
  /// there's nothing to gain from actually being joined to it. Only
  /// reachable when [kDebugMode] is true, never in a release build.
  Future<void> _bypassIfCaneDetectedNearby() async {
    if (!mounted) return;
    setState(() => _statusMessage = 'Scanning for a nearby Smart Cane...');
    try {
      final id = await _provisioningService.scanForNearbyCaneId();
      if (!mounted) return;
      if (id == null) {
        setState(() {
          _statusMessage = 'No Smart Cane hotspot detected nearby yet — make '
              'sure it\'s powered on and blinking blue, then try again.';
        });
        return;
      }
      setState(() {
        _selectedDeviceId = id;
        _needsAutoJoin = false; // detected, not joined — talking to the hardcoded test address instead
        _setupStep = _SetupStep.foundDevice;
        _statusMessage = '';
      });
    } on UnsupportedError {
      if (!mounted) return;
      setState(() {
        _statusMessage = "Your phone can't automatically scan for WiFi "
            'networks on iOS.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _statusMessage = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _startProvisioning() async {
    final deviceId = _selectedDeviceId.trim().toUpperCase();
    if (deviceId.isEmpty) return;

    setState(() {
      _setupStep = _SetupStep.connectingToDevice;
      _statusMessage = 'Connecting to your Smart Cane...';
      _errorMessage = '';
    });

    try {
      if (_needsAutoJoin) {
        final joined = await _provisioningService.connectToDeviceHotspot(deviceId);
        if (!joined) {
          _failSetup(
            "Couldn't join that cane's setup network. Make sure it's "
            'powered on and blinking blue, then try again.',
          );
          return;
        }
      }

      final identified = await _provisioningService.identifyDevice(deviceId);
      if (!identified) {
        _failSetup(
          'Connected to a WiFi network, but the cane never responded. '
          'Move a little closer to it and try again.',
        );
        return;
      }

      await _startNetworkScan();
    } catch (e) {
      _failSetup(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _startNetworkScan() async {
    if (!mounted) return;
    setState(() {
      _setupStep = _SetupStep.scanningNetworks;
      _statusMessage = 'Looking for nearby WiFi networks...';
    });

    try {
      final networks = await _provisioningService.scanNearbyNetworks();
      if (!mounted) return;
      setState(() {
        _networks = networks;
        _setupStep = _SetupStep.selectNetwork;
      });
    } catch (e) {
      _failSetup(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _submitWifiCredentials() async {
    final ssid = _enterNetworkManually
        ? _manualSsidController.text.trim()
        : _selectedNetwork?.ssid ?? '';
    final password = _networkPasswordController.text;
    if (ssid.isEmpty) return;

    setState(() {
      _setupStep = _SetupStep.finalizing;
      _statusMessage = 'Sending WiFi details to your cane...';
      _errorMessage = '';
    });

    try {
      await _provisioningService.sendWifiCredentials(ssid: ssid, password: password);

      if (mounted) {
        setState(() => _statusMessage = 'Waiting for your cane to connect...');
      }

      final result = await _provisioningService.pollConnectionStatus();

      if (result == WifiConnectStatus.failed) {
        _failSetup('The cane could not join "$ssid". Double check the password and try again.');
        return;
      }
      if (result == WifiConnectStatus.timedOut) {
        _failSetup(
          "We lost touch with the cane. If its light is now solid (not "
          "blinking), it likely connected — reopen the app and check your "
          'device list. Otherwise, try again.',
        );
        return;
      }

      // Connected! The cane has dropped its hotspot and joined home WiFi.
      if (mounted) {
        setState(() => _statusMessage = 'Registering your cane...');
      }
      await _provisioningService.disconnectFromDeviceHotspot();

      final deviceId = _selectedDeviceId.trim().toUpperCase();
      final nickname = _deviceNameController.text.trim().isNotEmpty
          ? _deviceNameController.text.trim()
          : 'My Smart Cane';

      // We deliberately do NOT call a Supabase pairing method here anymore.
      // The cane itself registers its own row in Supabase over its now-real
      // internet connection (see main.py's _register_device_with_supabase,
      // called right after it reports "connected") — that happens
      // asynchronously and isn't guaranteed to have finished by the time we
      // get here, so an app-side lookup for this deviceId right now can
      // race it and fail with something like "invalid serial number, this
      // Smart Cane does not exist". Instead, the app only remembers the
      // deviceId locally; the dashboard is what confirms it against
      // Supabase (see DashboardScreen._fetchDevices, which now re-scans
      // every time the dashboard becomes the visible screen again, not
      // just on first launch) and clears it from local storage once the
      // real row shows up there.
      await PendingDeviceStore.instance.add(deviceId, nickname);

      if (mounted) {
        await _alert('Success', 'Smart Cane Paired Successfully!');
        if (mounted) Navigator.of(context).pushReplacementNamed('/');
      }
    } catch (e) {
      _failSetup(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _failSetup(String message) {
    if (!mounted) return;
    setState(() {
      _setupStep = _SetupStep.error;
      _errorMessage = message;
    });
  }

  void _retryFromNetworkSelection() {
    setState(() {
      _setupStep = _SetupStep.selectNetwork;
      _errorMessage = '';
    });
  }

  void _restartSetup() {
    setState(() {
      _statusMessage = '';
      _errorMessage = '';
      _networks = [];
      _selectedNetwork = null;
      _selectedDeviceId = '';
      _needsAutoJoin = false;
      _networkPasswordController.clear();
    });
    _beginAutoDiscovery();
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

            if (_activeMode == 'setup' &&
                _setupStep != _SetupStep.searching &&
                _setupStep != _SetupStep.awaitingManualJoin)
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
    final midFlow = _activeMode == 'setup' &&
        _setupStep != _SetupStep.searching &&
        _setupStep != _SetupStep.awaitingManualJoin &&
        _setupStep != _SetupStep.foundDevice &&
        _setupStep != _SetupStep.error;
    if (!midFlow) {
      Navigator.of(context).pop();
      return;
    }
    // Bail out of an in-progress connection cleanly before leaving the screen.
    _provisioningService.disconnectFromDeviceHotspot();
    Navigator.of(context).pop();
  }

  Widget _buildSetupWizard() {
    switch (_setupStep) {
      case _SetupStep.searching:
        return _buildLoadingStep(_statusMessage.isEmpty ? 'Looking for a nearby Smart Cane...' : _statusMessage);
      case _SetupStep.awaitingManualJoin:
        return _buildAwaitingManualJoinStep();
      case _SetupStep.foundDevice:
        return _buildFoundDeviceStep();
      case _SetupStep.connectingToDevice:
      case _SetupStep.scanningNetworks:
        return _buildLoadingStep(_statusMessage);
      case _SetupStep.selectNetwork:
        return _buildSelectNetworkStep();
      case _SetupStep.finalizing:
        return _buildLoadingStep(_statusMessage);
      case _SetupStep.error:
        return _buildErrorStep();
    }
  }

  /// Instructions step: since there's no ambient-scan API available to a
  /// normal app on either platform, this hands the person off to the OS's
  /// own WiFi picker (which *can* see the cane's hotspot) and then detects
  /// the join automatically — either the moment they return to the app, or
  /// via the explicit button below as a fallback.
  Widget _buildAwaitingManualJoinStep() {
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
            'Power on the Smart Cane and wait for its light to blink blue. '
            'Then open WiFi settings and join the network that starts with '
            '"SmartCane-" — no password needed.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: _Colors.textSub, height: 1.6),
          ),
          const SizedBox(height: 30),
          _PrimaryButton(
            label: 'Open WiFi Settings',
            color: _Colors.primary,
            enabled: true,
            onTap: () => _provisioningService.openWifiSettings(),
          ),
          const SizedBox(height: 12),
          TextButton(onPressed: _checkForCaneConnection, child: const Text("I've Connected — Continue")),
          if (Platform.isAndroid) ...[
            const SizedBox(height: 4),
            TextButton(onPressed: _beginAutoDiscovery, child: const Text('Try automatic search again')),
          ],
          if (_statusMessage.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _statusMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: _Colors.textSub),
              ),
            ),
        ],
      ),
    );
  }

  /// Shown once we know the deviceId — either detected from the network the
  /// phone is now joined to, or supplied via a deep link.
  Widget _buildFoundDeviceStep() {
    return SingleChildScrollView(
      child: Column(
        children: [
          Container(
            width: 80,
            height: 80,
            margin: const EdgeInsets.only(bottom: 20),
            decoration: const BoxDecoration(color: Color(0xFFE6F2FF), shape: BoxShape.circle),
            child: const Icon(Icons.check_circle_outline, size: 48, color: _Colors.primary),
          ),
          const Text(
            'Found your Smart Cane and ready to continue.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: _Colors.textSub, height: 1.6),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: _Colors.card,
              border: Border.all(color: _Colors.border),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.qr_code_outlined, size: 20, color: _Colors.textSub),
                const SizedBox(width: 12),
                Text(_selectedDeviceId,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _Colors.textMain)),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _LabeledField(label: 'Device Nickname', icon: Icons.text_fields_outlined, controller: _deviceNameController, hint: "e.g., Patient's Cane"),
          const SizedBox(height: 10),
          _PrimaryButton(
            label: 'Start Setup',
            color: _Colors.primary,
            enabled: _selectedDeviceId.isNotEmpty,
            onTap: _startProvisioning,
          ),
          if (!_needsAutoJoin) ...[
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => setState(() {
                _setupStep = _SetupStep.awaitingManualJoin;
                _statusMessage = '';
              }),
              child: const Text('Not the right one?'),
            ),
          ],
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
          const SizedBox(height: 8),
          const Text(
            'Keep your phone close to the cane during this step.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: _Colors.textSub),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectNetworkStep() {
    final ssidReady = _enterNetworkManually
        ? _manualSsidController.text.trim().isNotEmpty
        : _selectedNetwork != null;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Select the WiFi Network', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _Colors.textMain)),
          const SizedBox(height: 6),
          const Text(
            "This is the home WiFi you want the cane to connect to — not the cane's own network.",
            style: TextStyle(fontSize: 13, color: _Colors.textSub, height: 1.5),
          ),
          const SizedBox(height: 16),
          if (!_enterNetworkManually) ...[
            if (_networks.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text('No networks found nearby.', style: TextStyle(color: _Colors.textSub)),
              )
            else
              ..._networks.map(
                (network) => _NetworkTile(
                  network: network,
                  selected: _selectedNetwork?.ssid == network.ssid,
                  onTap: () => setState(() => _selectedNetwork = network),
                ),
              ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => setState(() => _enterNetworkManually = true),
              child: const Text('My network is not listed'),
            ),
          ] else ...[
            _LabeledField(label: 'Network Name (SSID)', icon: Icons.wifi, controller: _manualSsidController, hint: 'e.g., Home WiFi'),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => setState(() => _enterNetworkManually = false),
              child: const Text('Choose from nearby networks instead'),
            ),
          ],
          const SizedBox(height: 12),
          _LabeledField(
            label: 'WiFi Password',
            icon: Icons.lock_outline,
            controller: _networkPasswordController,
            hint: 'Leave blank if the network is open',
            obscure: true,
          ),
          const SizedBox(height: 20),
          _PrimaryButton(
            label: 'Connect',
            color: _Colors.primary,
            enabled: ssidReady,
            onTap: _submitWifiCredentials,
          ),
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
          if (_networks.isNotEmpty || _enterNetworkManually)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _PrimaryButton(label: 'Try Again', color: _Colors.primary, enabled: true, onTap: _retryFromNetworkSelection),
            ),
          TextButton(onPressed: _restartSetup, child: const Text('Start Over')),
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

class _StepProgress extends StatelessWidget {
  final _SetupStep step;
  const _StepProgress({required this.step});

  int get _index {
    switch (step) {
      case _SetupStep.searching:
        return 0;
      case _SetupStep.awaitingManualJoin:
        return 0;
      case _SetupStep.foundDevice:
        return 0;
      case _SetupStep.connectingToDevice:
        return 1;
      case _SetupStep.scanningNetworks:
        return 2;
      case _SetupStep.selectNetwork:
        return 2;
      case _SetupStep.finalizing:
        return 3;
      case _SetupStep.error:
        return 3;
    }
  }

  @override
  Widget build(BuildContext context) {
    const labels = ['Find Cane', 'Connect', 'WiFi', 'Finish'];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: List.generate(labels.length, (i) {
          final active = i <= _index;
          return Expanded(
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    height: 4,
                    margin: EdgeInsets.only(left: i == 0 ? 0 : 4, right: i == labels.length - 1 ? 0 : 4),
                    decoration: BoxDecoration(
                      color: active ? _Colors.primary : _Colors.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }
}

class _NetworkTile extends StatelessWidget {
  final ScannedNetwork network;
  final bool selected;
  final VoidCallback onTap;
  const _NetworkTile({required this.network, required this.selected, required this.onTap});

  IconData get _signalIcon {
    if (network.signalStrength >= -60) return Icons.wifi;
    if (network.signalStrength >= -75) return Icons.wifi_2_bar;
    return Icons.wifi_1_bar;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
        decoration: BoxDecoration(
          color: _Colors.card,
          border: Border.all(color: selected ? _Colors.primary : _Colors.border, width: selected ? 2 : 1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(_signalIcon, size: 20, color: _Colors.textSub),
            const SizedBox(width: 12),
            Expanded(
              child: Text(network.ssid, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _Colors.textMain)),
            ),
            if (network.secured) const Icon(Icons.lock_outline, size: 16, color: _Colors.textSub),
            if (selected) const Padding(padding: EdgeInsets.only(left: 8), child: Icon(Icons.check_circle, size: 20, color: _Colors.primary)),
          ],
        ),
      ),
    );
  }
}

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