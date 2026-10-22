import 'package:flutter/material.dart';
import 'package:ionicons_plus/ionicons_plus.dart';
import '../../../models/device_model.dart';
import '../../../models/route_model.dart';
import '../../../theme/app_colors.dart';
import '../home_urgency.dart';

/// One cane on Home: person first, then the cane, then status and actions.
///
/// [hero] is the single-cane layout: the same card with a larger header
/// panel (pin + address) on top.
class DeviceCard extends StatelessWidget {
  final DeviceModel device;
  final bool sosActive;
  final RouteSession? walk;

  /// Guardian-side warning: the cane user's phone is not reporting, so an
  /// SOS call would not connect. Null = no warning.
  final String? callWarning;
  final bool hero;

  final VoidCallback onTrack;
  final VoidCallback onLogs;
  final VoidCallback? onRoutes;    // guardian / owner only
  final VoidCallback? onSettings;  // guardian / owner only
  final VoidCallback? onAlertsTap;

  const DeviceCard({
    super.key,
    required this.device,
    required this.onTrack,
    required this.onLogs,
    this.sosActive = false,
    this.walk,
    this.callWarning,
    this.hero = false,
    this.onRoutes,
    this.onSettings,
    this.onAlertsTap,
  });

  static const _sosBg = Color(0xFFFEF2F2);
  static const _amber = Color(0xFF92400E);

  String _titleCase(String s) => s
      .trim()
      .split(RegExp(r'[\s_]+'))
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
      .join(' ');

  String _lastSeenText() {
    final t = device.lastSeenAt;
    if (t == null) return 'Never connected';
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return 'Last seen just now';
    if (diff.inMinutes < 60) return 'Last seen ${diff.inMinutes} min ago';
    if (diff.inHours < 24) {
      return 'Last seen ${diff.inHours} h ago';
    }
    return 'Last seen ${diff.inDays} d ago';
  }

  /// The one line under the chips: what the person is doing right now.
  ({String text, Color color, IconData icon})? _statusLine() {
    if (sosActive) {
      return (text: 'SOS sent, check on them now', color: AppColors.alert, icon: Ionicons.warning);
    }
    final w = walk;
    if (w != null) {
      final pct = (w.fraction * 100).round();
      final text = w.offRoute
          ? 'Off route: ${w.routeName} · $pct% done'
          : 'Walking: ${w.routeName} · $pct% done';
      return (
        text: text,
        color: w.offRoute ? AppColors.alert : AppColors.primary,
        icon: Ionicons.walk,
      );
    }
    if (!device.isOnline) {
      return (text: _lastSeenText(), color: AppColors.textSub, icon: Ionicons.time_outline);
    }
    final a = device.activityStatus;
    if (a != null && a.isNotEmpty) {
      return (text: _titleCase(a), color: AppColors.textSub, icon: Ionicons.pulse);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final lowBattery = device.battery <= kLowBatteryPercent;
    final dotColor = sosActive
        ? AppColors.alert
        : (device.isOnline ? AppColors.online : AppColors.offline);
    final status = _statusLine();

    return Container(
      margin: const EdgeInsets.only(bottom: 15),
      decoration: BoxDecoration(
        color: sosActive ? _sosBg : AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: sosActive ? AppColors.alert : AppColors.border,
          width: sosActive ? 2 : 1,
        ),
        boxShadow: const [
          BoxShadow(color: Color(0x0D000000), blurRadius: 10, offset: Offset(0, 4)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Opacity(
        opacity: device.isOnline || sosActive ? 1 : 0.9,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hero) _heroPanel(),
            InkWell(
              onTap: onTrack,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Person + cane + gear
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                color: device.userBgBase,
                                shape: BoxShape.circle,
                              ),
                              alignment: Alignment.center,
                              child: Text(device.userInitials,
                                  style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: device.userColorBase)),
                            ),
                            Positioned(
                              right: -1,
                              bottom: -1,
                              child: Container(
                                width: 14,
                                height: 14,
                                decoration: BoxDecoration(
                                  color: dotColor,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 2),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(device.userName,
                                  style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: AppColors.textMain),
                                  overflow: TextOverflow.ellipsis),
                              const SizedBox(height: 2),
                              Text('${device.name} · ${device.roleLabel}',
                                  style: const TextStyle(
                                      fontSize: 13, color: AppColors.textSub),
                                  overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                        if (onSettings != null)
                          InkWell(
                            onTap: onSettings,
                            borderRadius: BorderRadius.circular(20),
                            child: const Padding(
                              padding: EdgeInsets.all(6),
                              child: Icon(Ionicons.settings_outline,
                                  size: 22, color: AppColors.textSub),
                            ),
                          ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    // Chips: online, battery, alerts
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _Chip(
                          label: device.isOnline ? 'Online' : 'Offline',
                          fg: device.isOnline ? AppColors.online : AppColors.textSub,
                          bg: device.isOnline
                              ? const Color(0xFFDCFCE7)
                              : const Color(0xFFF1F5F9),
                          icon: Ionicons.ellipse,
                          iconSize: 8,
                        ),
                        _Chip(
                          label: '${device.battery}%',
                          fg: lowBattery ? AppColors.alert : AppColors.textMain,
                          bg: lowBattery ? const Color(0xFFFEE2E2) : const Color(0xFFF1F5F9),
                          icon: lowBattery ? Ionicons.battery_dead : Ionicons.battery_full,
                        ),
                        if (device.alerts > 0)
                          GestureDetector(
                            onTap: onAlertsTap,
                            child: _Chip(
                              label: '${device.alerts} ${device.alerts == 1 ? 'alert' : 'alerts'}',
                              fg: Colors.white,
                              bg: AppColors.alert,
                              icon: Ionicons.notifications,
                            ),
                          ),
                      ],
                    ),

                    if (status != null) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Icon(status.icon, size: 15, color: status.color),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(status.text,
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: status.color),
                                overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                    ],

                    if (!hero) ...[
                      const SizedBox(height: 8),
                      _addressRow(),
                    ],

                    if (callWarning != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFFBEB),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFFDE68A)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.phone_disabled, size: 16, color: _amber),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(callWarning!,
                                  style: const TextStyle(
                                      fontSize: 12, color: _amber, height: 1.4)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // Actions
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: _ActionButton(
                      label: sosActive ? 'Track now' : 'Track',
                      icon: Ionicons.navigate,
                      filled: true,
                      color: sosActive ? AppColors.alert : AppColors.primary,
                      onTap: onTrack,
                    ),
                  ),
                  if (onRoutes != null) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: _ActionButton(
                        label: 'Routes',
                        icon: Ionicons.map_outline,
                        onTap: onRoutes!,
                      ),
                    ),
                  ],
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: _ActionButton(
                      label: 'Logs',
                      icon: Ionicons.document_text_outline,
                      onTap: onLogs,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _addressRow() => Row(
        children: [
          const Icon(Ionicons.location_outline, size: 15, color: AppColors.textSub),
          const SizedBox(width: 6),
          Expanded(
            child: Text(device.location,
                style: const TextStyle(fontSize: 13, color: AppColors.textMain),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      );

  /// Single-cane header: a simple pin panel with the address (no live map, so
  /// it costs nothing and cannot fail to render).
  Widget _heroPanel() {
    return Container(
      height: 120,
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFE0F2FE), Color(0xFFEDE9FE)],
        ),
      ),
      child: Stack(
        children: [
          Center(
            child: Icon(Ionicons.location,
                size: 44, color: sosActive ? AppColors.alert : AppColors.primary),
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.9),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(device.location,
                  style: const TextStyle(fontSize: 12, color: AppColors.textMain),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color fg;
  final Color bg;
  final IconData icon;
  final double iconSize;
  const _Chip({
    required this.label,
    required this.fg,
    required this.bg,
    required this.icon,
    this.iconSize = 13,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: iconSize, color: fg),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: fg)),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool filled;
  final Color color;
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.filled = false,
    this.color = AppColors.primary,
  });

  @override
  Widget build(BuildContext context) {
    final fg = filled ? Colors.white : AppColors.textMain;
    return Material(
      color: filled ? color : Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 42,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: filled ? null : Border.all(color: AppColors.border),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: 6),
              Flexible(
                child: Text(label,
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.bold, color: fg),
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
