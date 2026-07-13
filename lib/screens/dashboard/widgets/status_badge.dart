import 'package:flutter/material.dart';
import 'package:ionicons_plus/ionicons_plus.dart';
import '../../../theme/app_colors.dart';

/// Equivalent of `function StatusBadge({ type, icon, label, style })` in index.tsx.
class StatusBadge extends StatelessWidget {
  final String type; // 'online' | 'connected' | 'alert' | 'offline'
  final IconData? icon;
  final String label;
  final EdgeInsetsGeometry? margin;

  const StatusBadge({
    super.key,
    required this.type,
    required this.label,
    this.icon,
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    Color badgeColor;
    Color textColor = Colors.white;

    switch (type) {
      case 'online':
        badgeColor = AppColors.online;
        break;
      case 'connected':
        badgeColor = AppColors.primary;
        break;
      case 'alert':
        badgeColor = AppColors.alert;
        break;
      case 'offline':
        badgeColor = AppColors.border;
        textColor = AppColors.textSub;
        break;
      default:
        badgeColor = AppColors.textSub;
    }

    return Container(
      margin: margin,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: badgeColor,
        borderRadius: BorderRadius.circular(15),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: textColor),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: textColor),
          ),
        ],
      ),
    );
  }
}

/// Small helper so callers can pass the same 'ellipse'/'wifi' style names
/// used in the RN JSX without hardcoding Ionicons everywhere.
const IconData kOnlineDotIcon = Ionicons.ellipse;
const IconData kOfflineDotIcon = Ionicons.ellipse_outline;
const IconData kWifiIcon = Ionicons.wifi;
