import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
}

/// Route arguments: { 'id': String, 'name': String?, 'lat': double?, 'lng': double? }
class DeviceSettingsScreen extends StatefulWidget {
  final String id;
  final String? name;
  final double? lat;
  final double? lng;

  const DeviceSettingsScreen({super.key, required this.id, this.name, this.lat, this.lng});

  @override
  State<DeviceSettingsScreen> createState() => _DeviceSettingsScreenState();
}

class _DeviceSettingsScreenState extends State<DeviceSettingsScreen> {
  bool _isDeleteModalVisible = false;
  bool _aiVision = true;
  bool _laserAlerts = true;
  bool _highSensitivity = false;
  bool _lightMode = false;
  bool _audioFeedback = true;
  bool _geofencing = true;
  bool _isUnpairing = false;
  String? _activeShareCode;

  final _dbService = SupabaseService.instance;

  String get _deviceName => widget.name?.isNotEmpty == true ? widget.name! : 'Device';

  @override
  void initState() {
    super.initState();
    _fetchDeviceSettings();
  }

  Future<void> _fetchDeviceSettings() async {
    try {
      final isLightMode = await _dbService.getDeviceLightMode(widget.id);
      if (mounted) setState(() => _lightMode = isLightMode);
    } catch (e) {
      if (mounted) await _alert('Error', 'Failed to fetch device settings.');
    }
  }

  Future<void> _handleLightModeChange(bool newValue) async {
    final previousValue = _lightMode;
    setState(() => _lightMode = newValue);
    try {
      await _dbService.updateDeviceLightMode(widget.id, newValue);
    } catch (e) {
      setState(() => _lightMode = previousValue);
      if (mounted) await _alert('Update Failed', 'Could not save Light Mode setting. Please check your connection.');
    }
  }

  Future<void> _handleUnpair() async {
    setState(() => _isUnpairing = true);
    try {
      await _dbService.unpairDevice(widget.id);
      if (mounted) {
        await _alert('Unpaired', 'The Smart Cane has been removed from your account.');
        if (mounted) Navigator.of(context).pushReplacementNamed('/');
      }
    } catch (e) {
      if (mounted) await _alert('Error', 'Failed to unpair the device.');
      setState(() => _isUnpairing = false);
    }
  }

  Future<void> _generateShareCode() async {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rand = Random();
    final newCode = List.generate(6, (_) => chars[rand.nextInt(chars.length)]).join().toUpperCase();

    await _dbService.updateDeviceShareCode(widget.id, newCode);
    setState(() => _activeShareCode = newCode);
  }

  Future<void> _copyToClipboard() async {
    if (_activeShareCode != null) {
      await Clipboard.setData(ClipboardData(text: _activeShareCode!));
      if (mounted) await _alert('Copied!', 'Share code copied to clipboard. You can now paste it in a message.');
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _Colors.bg,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                  decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: _Colors.border))),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _CircleIconButton(icon: Icons.arrow_back, onTap: () => Navigator.of(context).pop()),
                      Text('$_deviceName Settings', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _Colors.textMain)),
                      const SizedBox(width: 40),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
                    children: [
                      const _SectionTitle('Hardware Modules'),
                      _SectionCard(children: [
                        _SettingRow(icon: Icons.camera_alt_outlined, label: 'AI Object Recognition', description: 'Uses camera to identify obstacles', value: _aiVision, onChanged: (v) => setState(() => _aiVision = v)),
                        const _RowDivider(),
                        _SettingRow(icon: Icons.qr_code_scanner_outlined, label: 'Laser Sensors', description: 'Emits lasers for drop-off detection', value: _laserAlerts, onChanged: (v) => setState(() => _laserAlerts = v)),
                        const _RowDivider(),
                        _SettingRow(icon: Icons.tune_outlined, label: 'High Sensitivity Mode', description: 'Increases laser detection range', value: _highSensitivity, onChanged: (v) => setState(() => _highSensitivity = v)),
                        _SettingRow(icon: Icons.lightbulb_outline, label: 'Light Mode', description: 'On = better for dark places, Off = saves battery in well-lit areas', value: _lightMode, onChanged: _handleLightModeChange),
                      ]),

                      const _SectionTitle('Cane Feedback'),
                      _SectionCard(children: [
                        _SettingRow(icon: Icons.volume_up_outlined, label: 'Audio Prompts', description: 'Speaks detected objects aloud', value: _audioFeedback, onChanged: (v) => setState(() => _audioFeedback = v)),
                      ]),

                      const _SectionTitle('Safety Zones'),
                      _SectionCard(children: [
                        _SettingRow(icon: Icons.map_outlined, label: 'Enable Geofencing', description: 'Track boundaries and restricted areas', value: _geofencing, onChanged: (v) => setState(() => _geofencing = v)),
                        const _RowDivider(),
                        InkWell(
                          onTap: !_geofencing
                              ? null
                              : () => Navigator.of(context).pushReplacementNamed('/geofence-editor', arguments: {
                                    'id': widget.id,
                                    'name': widget.name,
                                    'lat': widget.lat,
                                    'lng': widget.lng,
                                  }),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 15),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      width: 36,
                                      height: 36,
                                      margin: const EdgeInsets.only(right: 15),
                                      decoration: BoxDecoration(color: _geofencing ? const Color(0xFFE0F2FE) : const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(10)),
                                      child: Icon(Icons.map_outlined, size: 20, color: _geofencing ? _Colors.primary : _Colors.textSub),
                                    ),
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text('Manage Geofences', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _geofencing ? _Colors.textMain : _Colors.textSub)),
                                        const SizedBox(height: 2),
                                        const Text('Draw safe boundaries and danger zones', style: TextStyle(fontSize: 12, color: _Colors.textSub)),
                                      ],
                                    ),
                                  ],
                                ),
                                Icon(Icons.chevron_right, size: 20, color: _geofencing ? _Colors.border : Colors.transparent),
                              ],
                            ),
                          ),
                        ),
                      ]),

                      // Caregiver access
                      Container(
                        padding: const EdgeInsets.all(20),
                        margin: const EdgeInsets.only(bottom: 20),
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15), border: Border.all(color: _Colors.border)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const _SectionTitle('Caregiver Access'),
                            const Text('Generate a temporary code to allow a family member or caregiver to view this device.',
                                style: TextStyle(fontSize: 14, color: _Colors.textSub, height: 1.4)),
                            const SizedBox(height: 15),
                            if (_activeShareCode != null)
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(20),
                                decoration: BoxDecoration(
                                  color: _Colors.bg,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: _Colors.primary, style: BorderStyle.solid),
                                ),
                                child: Column(
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        const Text('Share this code:', style: TextStyle(fontSize: 14, color: _Colors.textSub)),
                                        TextButton.icon(
                                          onPressed: _generateShareCode,
                                          icon: const Icon(Icons.refresh_outlined, size: 16, color: _Colors.primary),
                                          label: const Text('Refresh', style: TextStyle(color: _Colors.primary, fontSize: 12, fontWeight: FontWeight.bold)),
                                          style: TextButton.styleFrom(backgroundColor: const Color(0xFFE0F2FE), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6)),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    InkWell(
                                      onTap: _copyToClipboard,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 15),
                                        margin: const EdgeInsets.symmetric(vertical: 10),
                                        decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(10)),
                                        child: Row(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Text(_activeShareCode!, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: _Colors.primary, letterSpacing: 5)),
                                            Container(
                                              margin: const EdgeInsets.only(left: 15),
                                              padding: const EdgeInsets.all(8),
                                              decoration: BoxDecoration(color: const Color(0xFFDBEAFE), borderRadius: BorderRadius.circular(8)),
                                              child: const Icon(Icons.copy_outlined, size: 20, color: _Colors.primary),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    const Text('This code will expire once used.', style: TextStyle(fontSize: 12, color: _Colors.alert)),
                                  ],
                                ),
                              )
                            else
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  onPressed: _generateShareCode,
                                  icon: const Icon(Icons.vpn_key_outlined, size: 20, color: Colors.white),
                                  label: const Text('Generate Share Code', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                                  style: ElevatedButton.styleFrom(backgroundColor: _Colors.primary, padding: const EdgeInsets.all(15), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                                ),
                              ),
                          ],
                        ),
                      ),

                      InkWell(
                        onTap: () => setState(() => _isDeleteModalVisible = true),
                        borderRadius: BorderRadius.circular(15),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(15), border: Border.all(color: const Color(0xFFFECACA))),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.delete_outline, size: 20, color: _Colors.alert),
                              const SizedBox(width: 8),
                              Text('Unpair $_deviceName', style: const TextStyle(color: _Colors.alert, fontSize: 16, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_isDeleteModalVisible)
              _RemoveDeviceModal(
                isUnpairing: _isUnpairing,
                onCancel: () => setState(() => _isDeleteModalVisible = false),
                onConfirm: _handleUnpair,
              ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle(this.title);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 5),
      child: Text(title.toUpperCase(),
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: _Colors.textSub, letterSpacing: 0.5)),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final List<Widget> children;
  const _SectionCard({required this.children});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 25),
      decoration: BoxDecoration(color: _Colors.card, borderRadius: BorderRadius.circular(15), border: Border.all(color: _Colors.border)),
      child: Column(children: children),
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.only(left: 65),
        child: Divider(height: 1, color: _Colors.border),
      );
}

class _SettingRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? description;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SettingRow({required this.icon, required this.label, this.description, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 15),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  margin: const EdgeInsets.only(right: 15),
                  decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(10)),
                  child: Icon(icon, size: 20, color: _Colors.textSub),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _Colors.textMain)),
                      if (description != null) ...[
                        const SizedBox(height: 2),
                        Text(description!, style: const TextStyle(fontSize: 12, color: _Colors.textSub)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged, activeColor: Colors.white, activeTrackColor: _Colors.success, inactiveTrackColor: const Color(0xFFCBD5E1)),
        ],
      ),
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

class _RemoveDeviceModal extends StatelessWidget {
  final bool isUnpairing;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;
  const _RemoveDeviceModal({required this.isUnpairing, required this.onCancel, required this.onConfirm});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0x990F172A),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(20),
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxWidth: 340),
        padding: const EdgeInsets.all(25),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 20)]),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              margin: const EdgeInsets.only(bottom: 15),
              decoration: const BoxDecoration(color: Color(0xFFFEF2F2), shape: BoxShape.circle),
              child: const Icon(Icons.warning_amber_rounded, size: 32, color: _Colors.alert),
            ),
            const Text('Remove Device?', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: _Colors.textMain)),
            const SizedBox(height: 10),
            const Text(
              'Are you sure you want to unpair this SmartCaneApp cane? It will be removed from your dashboard and tracking will stop.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: _Colors.textSub, height: 1.4),
            ),
            const SizedBox(height: 25),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 50,
                    child: ElevatedButton(
                      onPressed: onCancel,
                      style: ElevatedButton.styleFrom(backgroundColor: _Colors.alert, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                      child: const Text('Cancel', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    height: 50,
                    child: ElevatedButton(
                      onPressed: isUnpairing ? null : onConfirm,
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF1F5F9), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                      child: const Text('Remove', style: TextStyle(color: Color(0xFF475569), fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}