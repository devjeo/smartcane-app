import 'package:flutter/material.dart';

class _Colors {
  static const bg = Color(0xFFF8FAFC);
  static const card = Color(0xFFFFFFFF);
  static const textMain = Color(0xFF1E293B);
  static const textSub = Color(0xFF64748B);
  static const border = Color(0xFFE2E8F0);
  static const primary = Color(0xFF007BFF);
}

class TeamMember {
  final String name;
  final String role;
  const TeamMember(this.name, this.role);
}

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const List<TeamMember> _team = [
    TeamMember('Prince Jeorge V. Ojeda', 'Software & Backend Systems'),
    TeamMember('Harry M. Cayrel', 'Hardware Integration & IoT'),
    TeamMember('Criscel Annjela N. Alim', 'UI/UX & Mobile Application'),
    TeamMember('Angelica Galotino', 'UI/UX & Mobile Application'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _Colors.bg,
      body: SafeAreaView(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _BackButton(onTap: () => Navigator.of(context).pop()),
                  const Text(
                    'About',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _Colors.textMain),
                  ),
                  const SizedBox(width: 40),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 40),
                children: [
                  // Hero section
                  Center(
                    child: Column(
                      children: [
                        Container(
                          width: 80,
                          height: 80,
                          margin: const EdgeInsets.only(bottom: 15),
                          decoration: BoxDecoration(
                            color: _Colors.primary,
                            borderRadius: BorderRadius.circular(24),
                            boxShadow: const [
                              BoxShadow(color: Colors.black12, blurRadius: 10),
                            ],
                          ),
                          child: const Icon(Icons.visibility, size: 48, color: Colors.white),
                        ),
                        const Text(
                          'SmartCaneApp',
                          style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: _Colors.textMain),
                        ),
                        const SizedBox(height: 5),
                        const Text(
                          'Version 1.0.0',
                          style: TextStyle(fontSize: 14, color: _Colors.textSub),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 30),

                  const _SectionTitle('System Overview'),
                  Container(
                    padding: const EdgeInsets.all(20),
                    margin: const EdgeInsets.only(bottom: 25),
                    decoration: BoxDecoration(
                      color: _Colors.card,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _Colors.border),
                    ),
                    child: const Text(
                      'SmartCaneApp is an intelligent mobility cane designed to enhance the '
                      'safety and independence of visually impaired individuals.\n\n'
                      'Powered by a Raspberry Pi microcomputer, the cane utilizes an AI '
                      'camera for real-time object recognition and laser sensors for precise '
                      'environmental mapping. This Guardian App pairs directly with the '
                      'hardware to provide caretakers with live GPS tracking, geofencing '
                      'alerts, and device status monitoring.',
                      style: TextStyle(fontSize: 15, color: _Colors.textMain, height: 1.6),
                    ),
                  ),

                  const _SectionTitle('Development Team'),
                  Container(
                    padding: const EdgeInsets.all(20),
                    margin: const EdgeInsets.only(bottom: 25),
                    decoration: BoxDecoration(
                      color: _Colors.card,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _Colors.border),
                    ),
                    child: Column(
                      children: [
                        for (int i = 0; i < _team.length; i++) ...[
                          _TeamRow(member: _team[i]),
                          if (i != _team.length - 1)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 15),
                              child: Divider(height: 1, color: _Colors.border),
                            ),
                        ],
                      ],
                    ),
                  ),

                  Column(
                    children: [
                      const Icon(Icons.school_outlined, size: 28, color: _Colors.textSub),
                      const SizedBox(height: 10),
                      const Text(
                        'Camarines Norte State College',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: _Colors.textMain),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'System Analysis and Design Project • 2026',
                        style: TextStyle(fontSize: 13, color: _Colors.textSub),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SafeAreaView extends StatelessWidget {
  final Widget child;
  const SafeAreaView({super.key, required this.child});
  @override
  Widget build(BuildContext context) => SafeArea(child: child);
}

class _BackButton extends StatelessWidget {
  final VoidCallback onTap;
  const _BackButton({required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: _Colors.card,
          shape: BoxShape.circle,
          border: Border.all(color: _Colors.border),
        ),
        child: const Icon(Icons.arrow_back, size: 24, color: _Colors.textMain),
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
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: _Colors.textSub,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _TeamRow extends StatelessWidget {
  final TeamMember member;
  const _TeamRow({required this.member});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          margin: const EdgeInsets.only(right: 15),
          decoration: const BoxDecoration(color: Color(0xFFEFF6FF), shape: BoxShape.circle),
          child: const Icon(Icons.person, size: 20, color: _Colors.primary),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(member.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _Colors.textMain)),
            const SizedBox(height: 2),
            Text(member.role, style: const TextStyle(fontSize: 13, color: _Colors.textSub)),
          ],
        ),
      ],
    );
  }
}