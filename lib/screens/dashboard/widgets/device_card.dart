import 'package:flutter/material.dart';
import 'package:ionicons_plus/ionicons_plus.dart';
import '../../../models/device_model.dart';
import '../../../theme/app_colors.dart';
import 'status_badge.dart';

/// Equivalent of `const DeviceCard = ({ device }) => {...}` in index.tsx.
///
/// `onTap` mirrors `router.push('/tracker', {...})` and `onAlertsTap` mirrors
/// the alert badge's `router.push('/logs', {...})` — both left as callbacks
/// since the /tracker screen isn't built yet (that's a "next time" page).
class DeviceCard extends StatelessWidget {
  final DeviceModel device;
  final VoidCallback? onTap;
  final VoidCallback? onAlertsTap;

  const DeviceCard({
    super.key,
    required this.device,
    this.onTap,
    this.onAlertsTap,
  });

  @override
  Widget build(BuildContext context) {
    final primaryStatusColor = device.isOnline ? AppColors.primary : AppColors.offline;
    final batteryColor = device.isOnline ? AppColors.online : AppColors.offline;

    return Opacity(
      opacity: device.isOnline ? 1 : 0.8,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: Container(
          padding: const EdgeInsets.all(20),
          margin: const EdgeInsets.only(bottom: 15),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: AppColors.border),
            boxShadow: const [
              BoxShadow(color: Color(0x0D000000), blurRadius: 10, offset: Offset(0, 4)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Ionicons.pulse, size: 36, color: primaryStatusColor),
                  const SizedBox(width: 15),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                device.name,
                                style: const TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textMain),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (device.isViewer) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppColors.viewerTagBg,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: AppColors.viewerTagBorder),
                                ),
                                child: const Text('VIEWER',
                                    style: TextStyle(
                                        fontSize: 10, fontWeight: FontWeight.w900, color: AppColors.accent)),
                              ),
                            ],
                          ],
                        ),
                        Text(device.serial,
                            style: const TextStyle(fontSize: 12, color: AppColors.textSub)),
                      ],
                    ),
                  ),
                  device.alerts > 0
                      ? GestureDetector(
                          onTap: onAlertsTap,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: AppColors.alert,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('${device.alerts} alerts',
                                    style: const TextStyle(
                                        fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold)),
                                const SizedBox(width: 2),
                                const Icon(Ionicons.chevron_forward, size: 16, color: Colors.white),
                              ],
                            ),
                          ),
                        )
                      : const Icon(Ionicons.chevron_forward, size: 24, color: AppColors.offline),
                ],
              ),

              const SizedBox(height: 10),

              // Status badges row (horizontal scroll)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    if (device.isViewer)
                      Container(
                        margin: const EdgeInsets.only(right: 10),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppColors.viewerTagBg,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Ionicons.people, size: 12, color: AppColors.accent),
                            SizedBox(width: 4),
                            Text('Caregiver Access',
                                style: TextStyle(
                                    fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.accent)),
                          ],
                        ),
                      ),
                    if (device.isOnline) ...[
                      StatusBadge(type: 'online', icon: kOnlineDotIcon, label: 'Online'),
                      if (device.isConnected)
                        StatusBadge(
                          type: 'connected',
                          icon: kWifiIcon,
                          label: 'Connected',
                          margin: const EdgeInsets.only(left: 10),
                        ),
                    ] else
                      StatusBadge(type: 'offline', icon: kOfflineDotIcon, label: device.statusText),
                  ],
                ),
              ),

              const SizedBox(height: 15),

              // Battery + location row
              Row(
                children: [
                  Icon(
                    device.isOnline ? Ionicons.battery_charging : Ionicons.battery_dead,
                    size: 16,
                    color: batteryColor,
                  ),
                  const SizedBox(width: 4),
                  Text('${device.battery}%',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: batteryColor)),
                  const SizedBox(width: 15),
                  const Icon(Ionicons.location_outline, size: 16, color: AppColors.textSub),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(device.location,
                        style: const TextStyle(fontSize: 14, color: AppColors.textMain),
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),

              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.only(top: 12),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: AppColors.border)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: device.userBgBase,
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            device.userInitials,
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold, color: device.userColorBase),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(device.userName, style: const TextStyle(fontSize: 14, color: AppColors.textMain)),
                      ],
                    ),
                    Text(device.version,
                        style: const TextStyle(fontSize: 11, color: AppColors.textSub, letterSpacing: 1)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
