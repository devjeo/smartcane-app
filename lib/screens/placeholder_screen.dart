import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Stand-in for screens that aren't ported yet (login, tracker, add-device,
/// edit-profile, about) — exactly the pages you said we'd tackle "next
/// time". Swap each route in main.dart for the real screen as you build it.
class PlaceholderScreen extends StatelessWidget {
  final String title;
  const PlaceholderScreen({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        foregroundColor: AppColors.textMain,
        title: Text(title),
      ),
      body: Center(
        child: Text(
          '$title screen — coming soon',
          style: const TextStyle(color: AppColors.textSub, fontSize: 16),
        ),
      ),
    );
  }
}
