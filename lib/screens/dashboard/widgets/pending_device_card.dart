import 'package:flutter/material.dart';
import 'package:ionicons_plus/ionicons_plus.dart';
import '../../../theme/app_colors.dart';
import '../../../services/pending_device_store.dart';

/// Shown for a cane the setup wizard walked through provisioning for, but
/// that hasn't shown up in a `fetchDevices()` result yet. Deliberately not
/// tappable — there's nothing to open until Supabase actually has the row.
class PendingDeviceCard extends StatelessWidget {
  final PendingDevice device;
  const PendingDeviceCard({super.key, required this.device});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.7,
      child: Container(
        padding: const EdgeInsets.all(20),
        margin: const EdgeInsets.only(bottom: 15),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(device.name,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textMain)),
                  const SizedBox(height: 2),
                  const Text(
                    'Setting up — this will appear once your cane finishes registering.',
                    style: TextStyle(fontSize: 12, color: AppColors.textSub),
                  ),
                ],
              ),
            ),
            const Icon(Ionicons.time_outline, size: 20, color: AppColors.textSub),
          ],
        ),
      ),
    );
  }
}