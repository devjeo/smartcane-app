import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
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

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _fullNameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _locationController = TextEditingController();
  final _roleController = TextEditingController();
  final _emailController = TextEditingController();

  File? _profileImage;
  String _initials = 'AB';
  bool _isGoogleLinked = false;
  bool _hasChanges = false;
  bool _isLoading = false;
  bool _isDeleteModalVisible = false;

  final _dbService = SupabaseService.instance;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    for (final c in [_fullNameController, _phoneController, _locationController, _roleController, _emailController]) {
      c.addListener(() {
        if (!_hasChanges) setState(() => _hasChanges = true);
      });
    }
  }

  Future<void> _loadProfile() async {
    try {
      final user = _dbService.currentUser;
      if (user != null) {
        _emailController.text = user.email ?? '';

        final profile = await _dbService.getFullProfile();

        if (profile != null && mounted) {
          setState(() {
            _fullNameController.text = profile['full_name'] ?? '';
            _initials = (profile['full_name'] as String?)?.isNotEmpty == true
                ? (profile['full_name'] as String).split(' ').map((n) => n.isNotEmpty ? n[0] : '').join().toUpperCase()
                : 'AB';
            _phoneController.text = profile['phone_number'] ?? '';
            _locationController.text = profile['location'] ?? '';
            _roleController.text = profile['role'] ?? '';
            _hasChanges = false; 
          });
        }
      }
    } catch (e) {
      debugPrint('Failed to load profile: $e');
    }
  }

  Future<void> _handlePickImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery, imageQuality: 50);
    if (picked != null) {
      setState(() {
        _profileImage = File(picked.path);
        _hasChanges = true;
      });
    }
  }

  Future<void> _handleSave() async {
    if (!_hasChanges) return;
    setState(() => _isLoading = true);

    try {
      await _dbService.updateFullProfile(
        fullName: _fullNameController.text.trim(),
        phoneNumber: _phoneController.text.trim(),
        location: _locationController.text.trim(),
        role: _roleController.text.trim(),
      );

      setState(() => _hasChanges = false);
      if (mounted) {
        await _alert('Profile Updated', 'Your information has been successfully saved.');
        if (mounted) Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) await _alert('Update Failed', 'Could not save your changes.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleConnectGoogle() async {
    final connect = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Connect Google Account'),
        content: const Text('This will redirect you to Google to securely link your account.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Connect')),
        ],
      ),
    );
    if (connect == true) {
      setState(() {
        _isGoogleLinked = true;
        _hasChanges = true;
      });
    }
  }

  Future<void> _handleConfirmDeleteAccount() async {
    setState(() => _isDeleteModalVisible = false);
    try {
      await _dbService.deleteAccountData();
      if (mounted) Navigator.of(context).pushReplacementNamed('/login');
    } catch (e) {
      if (mounted) await _alert('Error', 'Could not delete account data.');
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
  void dispose() {
    _fullNameController.dispose();
    _phoneController.dispose();
    _locationController.dispose();
    _roleController.dispose();
    _emailController.dispose();
    super.dispose();
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
                // Header
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _CircleIconButton(icon: Icons.arrow_back, onTap: () => Navigator.of(context).pop()),
                      const Text('Edit Profile', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _Colors.textMain)),
                      SizedBox(
                        height: 36,
                        child: ElevatedButton(
                          onPressed: (_hasChanges && !_isLoading) ? _handleSave : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _hasChanges ? _Colors.primary : _Colors.disabled,
                            padding: const EdgeInsets.symmetric(horizontal: 15),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                          ),
                          child: Text(
                            _isLoading ? 'Saving...' : 'Save',
                            style: TextStyle(color: _hasChanges ? Colors.white : const Color(0xFF64748B), fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 40),
                    children: [
                      Center(
                        child: GestureDetector(
                          onTap: _handlePickImage,
                          child: Stack(
                            children: [
                              Container(
                                width: 90,
                                height: 90,
                                decoration: const BoxDecoration(color: Color(0xFFE0F2FE), shape: BoxShape.circle),
                                alignment: Alignment.center,
                                child: _profileImage != null
                                    ? ClipOval(child: Image.file(_profileImage!, width: 90, height: 90, fit: BoxFit.cover))
                                    : Text(_initials, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold, color: _Colors.primary)),
                              ),
                              Positioned(
                                bottom: 0,
                                right: 0,
                                child: Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: _Colors.primary,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: _Colors.bg, width: 3),
                                  ),
                                  child: const Icon(Icons.camera_alt, size: 14, color: Colors.white),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),

                      const _SectionTitle('Personal Details'),
                      _Card(children: [
                        _FieldRow(label: 'Full Name', controller: _fullNameController),
                        const _RowDivider(),
                        _FieldRow(label: 'Emergency Phone Number', controller: _phoneController, keyboardType: TextInputType.phone),
                        const _RowDivider(),
                        _FieldRow(label: 'Location / Region', controller: _locationController),
                        const _RowDivider(),
                        _FieldRow(label: 'Relationship to User', controller: _roleController, hint: 'e.g., Parent, Sibling, Caregiver'),
                      ]),

                      const _SectionTitle('Account & Security'),
                      _Card(children: [
                        _FieldRow(
                          label: 'Email Address',
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          enabled: !_isGoogleLinked,
                          dimmed: _isGoogleLinked,
                        ),
                        const _RowDivider(),
                        _isGoogleLinked
                            ? Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 16),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: const [
                                    Row(children: [
                                      Icon(Icons.g_mobiledata, size: 20, color: _Colors.textSub),
                                      SizedBox(width: 12),
                                      Text('Connected to Google', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: _Colors.textSub)),
                                    ]),
                                    Icon(Icons.check_circle, size: 22, color: _Colors.success),
                                  ],
                                ),
                              )
                            : _ActionRow(
                                icon: Icons.g_mobiledata,
                                iconColor: const Color(0xFFDB4437),
                                label: 'Connect Google Account',
                                onTap: _handleConnectGoogle,
                              ),
                        const _RowDivider(),
                        _ActionRow(
                          icon: Icons.lock_outline,
                          iconColor: _Colors.textMain,
                          label: _isGoogleLinked ? 'Set Fallback Password' : 'Change Password',
                          onTap: () => _alert('Change Password', 'Redirecting to secure password reset...'),
                        ),
                      ]),

                      Center(
                        child: TextButton(
                          onPressed: () => setState(() => _isDeleteModalVisible = true),
                          child: const Text('Delete Account Data', style: TextStyle(color: _Colors.alert, fontSize: 14, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_isDeleteModalVisible)
              _ConfirmDeleteModal(
                onCancel: () => setState(() => _isDeleteModalVisible = false),
                onConfirm: _handleConfirmDeleteAccount,
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

class _Card extends StatelessWidget {
  final List<Widget> children;
  const _Card({required this.children});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 25),
      padding: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        color: _Colors.card,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: _Colors.border),
      ),
      child: Column(children: children),
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 15),
        child: Divider(height: 1, color: _Colors.border),
      );
}

class _FieldRow extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final String? hint;
  final bool enabled;
  final bool dimmed;

  const _FieldRow({required this.label, required this.controller, this.keyboardType, this.hint, this.enabled = true, this.dimmed = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: _Colors.textSub)),
          const SizedBox(height: 5),
          TextField(
            controller: controller,
            keyboardType: keyboardType,
            enabled: enabled,
            autocorrect: false,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: dimmed ? _Colors.textSub : _Colors.textMain),
            decoration: InputDecoration(
              hintText: hint,
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final VoidCallback onTap;
  const _ActionRow({required this.icon, required this.iconColor, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(children: [
              Icon(icon, size: 20, color: iconColor),
              const SizedBox(width: 12),
              Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: _Colors.textMain)),
            ]),
            const Icon(Icons.chevron_right, size: 20, color: _Colors.border),
          ],
        ),
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

class _ConfirmDeleteModal extends StatelessWidget {
  final VoidCallback onCancel;
  final VoidCallback onConfirm;
  const _ConfirmDeleteModal({required this.onCancel, required this.onConfirm});

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
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 20)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              margin: const EdgeInsets.only(bottom: 15),
              decoration: const BoxDecoration(color: Color(0xFFFEF2F2), shape: BoxShape.circle),
              child: const Icon(Icons.warning_amber_rounded, size: 36, color: _Colors.alert),
            ),
            const Text('Delete Everything?', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: _Colors.textMain)),
            const SizedBox(height: 10),
            const Text(
              'Are you absolutely sure? This will permanently erase your Guardian profile, all paired SmartCaneApp canes, and all tracking history. This cannot be undone.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: _Colors.textSub, height: 1.6),
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
                      child: const Text('Keep Account', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    height: 50,
                    child: ElevatedButton(
                      onPressed: onConfirm,
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF1F5F9), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                      child: const Text('Delete', style: TextStyle(color: Color(0xFF475569), fontWeight: FontWeight.bold)),
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