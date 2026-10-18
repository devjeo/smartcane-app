import 'package:another_telephony/telephony.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/device_model.dart';
import '../../services/emergency_contacts_service.dart';
import '../../services/main_tab_controller.dart';
import '../../services/sos_ladder_runner.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_colors.dart';

/// Who gets texted and called when SOS is pressed on a SOLO cane (a cane with
/// no guardian app). The list is ordered: the phone calls #1 first, then #2...
class EmergencyContactsScreen extends StatefulWidget {
  const EmergencyContactsScreen({super.key});

  @override
  State<EmergencyContactsScreen> createState() => _EmergencyContactsScreenState();
}

class _EmergencyContactsScreenState extends State<EmergencyContactsScreen>
    with WidgetsBindingObserver {
  final _svc = EmergencyContactsService.instance;

  bool _loading = true;
  String _error = '';
  List<DeviceModel> _devices = [];
  DeviceModel? _device;
  List<EmergencyContact> _contacts = [];
  bool _permsOk = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkPerms();
  }

  Future<void> _init() async {
    try {
      final all = await SupabaseService.instance.fetchDevices();
      final mine = all.where((d) => d.isGuardian || d.isCaneUser).toList();
      if (!mounted) return;
      setState(() {
        _devices = mine;
        _device = mine.isNotEmpty ? mine.first : null;
      });
      await _checkPerms();
      await _loadContacts();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load your cane. Pull down to retry.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadContacts() async {
    final d = _device;
    if (d == null) return;
    try {
      final list = await _svc.fetch(d.id);
      if (mounted) setState(() { _contacts = list; _error = ''; });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load contacts. Pull down to retry.');
    }
  }

  Future<void> _checkPerms() async {
    final ok = await Permission.phone.isGranted &&
        await Permission.sms.isGranted &&
        await Permission.systemAlertWindow.isGranted;
    if (mounted) setState(() => _permsOk = ok);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------- actions ----------

  Future<void> _askPermissions() async {
    await SosLadderRunner.ensurePermissions();
    await _checkPerms();
    if (!_permsOk) {
      _toast('Some permissions are still off. Open Settings > Apps > SmartCane > Permissions.');
      await openAppSettings();
    }
  }

  Future<void> _setSolo(bool value) async {
    final d = _device;
    if (d == null) return;
    try {
      await Supabase.instance.client.rpc('set_device_solo', params: {
        'p_device_id': d.id,
        'p_solo': value,
      });
      MainTabController.rolesChanged.value++;
      final all = await SupabaseService.instance.fetchDevices();
      final mine = all.where((x) => x.isGuardian || x.isCaneUser).toList();
      if (!mounted) return;
      setState(() {
        _devices = mine;
        _device = mine.firstWhere((x) => x.id == d.id, orElse: () => d);
      });
    } on PostgrestException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('Could not change solo mode. Please try again.');
    }
  }

  Future<void> _addOrEdit([EmergencyContact? existing]) async {
    final d = _device;
    if (d == null) return;
    if (existing == null && _contacts.length >= EmergencyContactsService.maxContacts) {
      _toast('You can save up to ${EmergencyContactsService.maxContacts} contacts.');
      return;
    }
    final result = await showDialog<_ContactInput>(
      context: context,
      builder: (_) => _ContactDialog(existing: existing),
    );
    if (result == null) return;
    try {
      if (existing == null) {
        await _svc.add(
          deviceId: d.id,
          name: result.name,
          phone: result.phone,
          priority: _contacts.length + 1,
        );
      } else {
        await _svc.update(existing.id, {'name': result.name, 'phone': result.phone});
      }
      await _loadContacts();
    } on PostgrestException catch (e) {
      _toast(e.code == '23505'
          ? 'That number is already in your list.'
          : 'Could not save the contact. ${e.message}');
    } catch (_) {
      _toast('Could not save the contact. Please try again.');
    }
  }

  Future<void> _toggle(EmergencyContact c, String column, bool value) async {
    try {
      await _svc.update(c.id, {column: value});
      await _loadContacts();
    } catch (_) {
      _toast('Could not update the contact.');
    }
  }

  Future<void> _move(int index, int delta) async {
    final target = index + delta;
    if (target < 0 || target >= _contacts.length) return;
    final list = [..._contacts];
    final item = list.removeAt(index);
    list.insert(target, item);
    try {
      await _svc.saveOrder(list);
      await _loadContacts();
    } catch (_) {
      _toast('Could not change the order.');
    }
  }

  Future<void> _delete(EmergencyContact c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove contact?'),
        content: Text('${c.name} will no longer be called or texted in an emergency.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove', style: TextStyle(color: AppColors.alert)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _svc.delete(c.id);
      final rest = _contacts.where((x) => x.id != c.id).toList();
      await _svc.saveOrder(rest);
      await _loadContacts();
    } catch (_) {
      _toast('Could not remove the contact.');
    }
  }

  Future<void> _sendTestText(EmergencyContact c) async {
    if (!await Permission.sms.isGranted) {
      final s = await Permission.sms.request();
      if (!s.isGranted) {
        _toast('Allow SMS first, then try again.');
        return;
      }
    }
    try {
      await Telephony.instance.sendSms(
        to: c.phone,
        message: 'Test from SmartCane: you were added as an emergency contact. '
            'No action needed.',
      );
      _toast('Test text sent to ${c.name}.');
    } catch (_) {
      _toast('Could not send the text.');
    }
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final me = SupabaseService.instance.currentUser?.id;
    final d = _device;
    final showSolo = d != null && d.isGuardian && (d.isSolo || d.caneUserId == null || d.caneUserId == me);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('Emergency Contacts'),
        backgroundColor: AppColors.card,
        foregroundColor: AppColors.textMain,
        elevation: 0,
      ),
      floatingActionButton: d == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _addOrEdit(),
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Add contact'),
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async {
                await _checkPerms();
                await _loadContacts();
              },
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                children: [
                  if (d == null)
                    const _InfoCard(
                      icon: Icons.info_outline,
                      text: 'No cane found on this account yet. Add a cane first.',
                    )
                  else ...[
                    if (_devices.length > 1) _devicePicker(),
                    const _InfoCard(
                      icon: Icons.sos,
                      text: 'When SOS is pressed on your cane, your phone texts each '
                          'contact your location, then calls them in this order until '
                          'someone answers. Emergency hotlines (like 911) cannot be added.',
                    ),
                    const SizedBox(height: 12),
                    _permissionCard(),
                    if (showSolo) ...[const SizedBox(height: 12), _soloCard(d)],
                    const SizedBox(height: 12),
                    if (_error.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(_error, style: const TextStyle(color: AppColors.alert)),
                      ),
                    if (_contacts.isEmpty && _error.isEmpty)
                      const _InfoCard(
                        icon: Icons.warning_amber_rounded,
                        text: 'No contacts yet. Without at least one, SOS cannot call anyone. '
                            'Tap "Add contact" and choose someone who is usually reachable, '
                            'like a neighbor.',
                        warn: true,
                      ),
                    for (var i = 0; i < _contacts.length; i++) _contactCard(i),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _devicePicker() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        value: _device?.id,
        decoration: const InputDecoration(labelText: 'Cane', border: OutlineInputBorder()),
        items: [
          for (final x in _devices) DropdownMenuItem(value: x.id, child: Text(x.name)),
        ],
        onChanged: (id) async {
          if (id == null) return;
          setState(() => _device = _devices.firstWhere((x) => x.id == id));
          await _loadContacts();
        },
      ),
    );
  }

  Widget _permissionCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _cardDeco(color: _permsOk ? const Color(0xFFF0FDF4) : const Color(0xFFFFFBEB)),
      child: Row(
        children: [
          Icon(_permsOk ? Icons.check_circle : Icons.lock_open,
              color: _permsOk ? AppColors.success : AppColors.warning),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _permsOk
                  ? 'Calling and texting are allowed.'
                  : 'Allow Phone, SMS and "Display over other apps" so your phone can '
                      'call and text for you in an emergency.',
              style: const TextStyle(fontSize: 14, color: AppColors.textMain, height: 1.4),
            ),
          ),
          if (!_permsOk)
            TextButton(onPressed: _askPermissions, child: const Text('Allow')),
        ],
      ),
    );
  }

  Widget _soloCard(DeviceModel d) {
    return Container(
      decoration: _cardDeco(),
      child: SwitchListTile(
        value: d.isSolo,
        onChanged: _setSolo,
        title: const Text('I use this cane myself (no guardian)',
            style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.textMain)),
        subtitle: const Text('Your phone will call your contacts instead of a guardian app.'),
      ),
    );
  }

  Widget _contactCard(int i) {
    final c = _contacts[i];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
      decoration: _cardDeco(),
      child: Column(
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: AppColors.primary,
                child: Text('${i + 1}',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.name,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textMain)),
                    Text(c.phone,
                        style: const TextStyle(fontSize: 14, color: AppColors.textSub)),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Move ${c.name} up',
                onPressed: i == 0 ? null : () => _move(i, -1),
                icon: const Icon(Icons.arrow_upward),
              ),
              IconButton(
                tooltip: 'Move ${c.name} down',
                onPressed: i == _contacts.length - 1 ? null : () => _move(i, 1),
                icon: const Icon(Icons.arrow_downward),
              ),
              PopupMenuButton<String>(
                tooltip: 'More options for ${c.name}',
                onSelected: (v) {
                  if (v == 'edit') _addOrEdit(c);
                  if (v == 'test') _sendTestText(c);
                  if (v == 'delete') _delete(c);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'test', child: Text('Send test text')),
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Remove')),
                ],
              ),
            ],
          ),
          Wrap(
            spacing: 4,
            children: [
              _MiniSwitch('Call', c.allowCall, (v) => _toggle(c, 'allow_call', v)),
              _MiniSwitch('Text', c.allowSms, (v) => _toggle(c, 'allow_sms', v)),
              _MiniSwitch('Active', c.active, (v) => _toggle(c, 'active', v)),
            ],
          ),
        ],
      ),
    );
  }

  BoxDecoration _cardDeco({Color color = AppColors.card}) => BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      );
}

class _MiniSwitch extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _MiniSwitch(this.label, this.value, this.onChanged);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 13, color: AppColors.textSub)),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool warn;
  const _InfoCard({required this.icon, required this.text, this.warn = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: warn ? const Color(0xFFFFFBEB) : const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: warn ? const Color(0xFFFDE68A) : const Color(0xFFBFDBFE)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: warn ? AppColors.warning : AppColors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: const TextStyle(fontSize: 14, color: AppColors.textMain, height: 1.4)),
          ),
        ],
      ),
    );
  }
}

class _ContactInput {
  final String name;
  final String phone;
  const _ContactInput(this.name, this.phone);
}

class _ContactDialog extends StatefulWidget {
  final EmergencyContact? existing;
  const _ContactDialog({this.existing});

  @override
  State<_ContactDialog> createState() => _ContactDialogState();
}

class _ContactDialogState extends State<_ContactDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _phone =
      TextEditingController(text: widget.existing?.phone ?? '');
  String _err = '';

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final phone = EmergencyContactsService.normalizePhone(_phone.text);
    if (name.isEmpty) {
      setState(() => _err = 'Enter a name.');
      return;
    }
    if (phone == null) {
      setState(() => _err = 'Enter a full mobile number, like 09171234567 or '
          '+639171234567. Emergency hotlines such as 911 cannot be added.');
      return;
    }
    Navigator.pop(context, _ContactInput(name.length > 80 ? name.substring(0, 80) : name, phone));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add contact' : 'Edit contact'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name (e.g., Neighbor Ana)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Mobile number'),
            ),
            if (_err.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_err, style: const TextStyle(color: AppColors.alert, fontSize: 13)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}
