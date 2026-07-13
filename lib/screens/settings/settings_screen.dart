import 'package:flutter/material.dart';
import 'package:ionicons_plus/ionicons_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_colors.dart';

/// Equivalent of `export default function SettingsTab()` in settings.tsx.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _profileName = 'Loading...';
  String _profileEmail = '';
  String _profileLocation = '...';
  String _initials = '';

  bool _pushNotifications = true;
  bool _emailAlerts = false;

  @override
  void initState() {
    super.initState();
    _loadUserProfile();
  }

  // Equivalent of the loadUserProfile() effect in settings.tsx
  Future<void> _loadUserProfile() async {
    try {
      final profile = await SupabaseService.instance.fetchProfile();
      if (profile == null || !mounted) return;

      final name = profile['full_name'] as String;
      final nameParts = name.split(' ').where((p) => p.isNotEmpty).toList();

      setState(() {
        _profileEmail = profile['email'] as String;
        _profileName = name;
        _profileLocation = profile['location'] as String;
        _initials = nameParts.length >= 2
            ? (nameParts.first[0] + nameParts.last[0]).toUpperCase()
            : name.substring(0, name.length >= 2 ? 2 : 1).toUpperCase();
      });
    } catch (e) {
      debugPrint('Error loading profile: $e');
    }
  }

  // Equivalent of handleLogout()
  Future<void> _handleLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Log Out'),
        content: const Text('Are you sure you want to log out of your Guardian account?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Log Out', style: TextStyle(color: AppColors.alert)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await SupabaseService.instance.signOut();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('@user_token');
    } catch (e) {
      debugPrint('Logout Exception: $e');
    } finally {
      if (mounted) Navigator.of(context).pushReplacementNamed('/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
          children: [
            const Text('Account Settings',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: AppColors.textMain)),
            const SizedBox(height: 25),

            // Profile card
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(20),
                boxShadow: const [
                  BoxShadow(color: Color(0x0D000000), blurRadius: 10, offset: Offset(0, 4)),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 60,
                    height: 60,
                    decoration: const BoxDecoration(color: Color(0xFFE0F2FE), shape: BoxShape.circle),
                    alignment: Alignment.center,
                    child: Text(_initials,
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.primary)),
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_profileName,
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textMain)),
                        Text(_profileEmail,
                            style: const TextStyle(fontSize: 13, color: AppColors.textSub)),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Icon(Ionicons.location, size: 12, color: AppColors.textSub),
                            const SizedBox(width: 4),
                            Text(_profileLocation,
                                style: const TextStyle(fontSize: 12, color: AppColors.textSub)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 36,
                    height: 36,
                    decoration: const BoxDecoration(color: Color(0xFFF1F5F9), shape: BoxShape.circle),
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: const Icon(Ionicons.pencil, size: 18, color: AppColors.primary),
                      onPressed: () => Navigator.of(context).pushReplacementNamed('/edit-profile'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 30),

            _SectionTitle('App Preferences'),
            _SectionCard(children: [
              _SettingRow(
                icon: Ionicons.notifications_outline,
                label: 'Push Notifications',
                value: _pushNotifications,
                onChanged: (v) => setState(() => _pushNotifications = v),
              ),
              const _RowDivider(),
              _SettingRow(
                icon: Ionicons.mail_outline,
                label: 'Email Alerts',
                value: _emailAlerts,
                onChanged: (v) => setState(() => _emailAlerts = v),
              ),
            ]),
            const SizedBox(height: 25),

            _SectionTitle('Support'),
            _SectionCard(children: [
              _LinkRow(
                icon: Ionicons.help_circle_outline,
                label: 'Help Center',
                onTap: () => launchUrl(Uri.parse('https://support.google.com')),
              ),
              const _RowDivider(),
              _LinkRow(
                icon: Ionicons.document_text_outline,
                label: 'Terms of Service',
                onTap: () => launchUrl(Uri.parse('https://policies.google.com/terms')),
              ),
              const _RowDivider(),
              _LinkRow(
                icon: Ionicons.information_circle_outline,
                label: 'About SmartCaneApp',
                onTap: () => Navigator.of(context).pushReplacementNamed('/about'),
              ),
            ]),
            const SizedBox(height: 10),

            // Logout button
            InkWell(
              borderRadius: BorderRadius.circular(15),
              onTap: _handleLogout,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 16),
                margin: const EdgeInsets.only(top: 10, bottom: 20),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF2F2),
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(color: const Color(0xFFFECACA)),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Ionicons.log_out_outline, size: 22, color: AppColors.alert),
                    SizedBox(width: 8),
                    Text('Log Out',
                        style: TextStyle(color: AppColors.alert, fontSize: 16, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),

            const Center(
              child: Text('SmartCaneApp v1.0.0',
                  style: TextStyle(color: AppColors.textSub, fontSize: 12)),
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
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.textSub, letterSpacing: 0.5),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final List<Widget> children;
  const _SectionCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(children: children),
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(left: 62),
      child: Divider(height: 1, color: AppColors.border),
    );
  }
}

/// Equivalent of `<SettingRow type="toggle" .../>`
class _SettingRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SettingRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 15),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 20, color: AppColors.textSub),
              ),
              const SizedBox(width: 15),
              Text(label, style: const TextStyle(fontSize: 16, color: AppColors.textMain, fontWeight: FontWeight.w500)),
            ],
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: Colors.white,
            activeTrackColor: AppColors.success,
            inactiveTrackColor: const Color(0xFFCBD5E1),
          ),
        ],
      ),
    );
  }
}

/// Equivalent of `<SettingRow type="link" .../>`
class _LinkRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _LinkRow({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 15),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Icon(icon, size: 20, color: AppColors.textSub),
                ),
                const SizedBox(width: 15),
                Text(label,
                    style: const TextStyle(fontSize: 16, color: AppColors.textMain, fontWeight: FontWeight.w500)),
              ],
            ),
            const Icon(Ionicons.chevron_forward, size: 20, color: AppColors.border),
          ],
        ),
      ),
    );
  }
}
