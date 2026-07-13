import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Mirrors the `mappedDevices` shape built inside `fetchDevices()` in index.tsx.
class DeviceModel {
  final String id;
  final String name;
  final String serial;
  final int alerts;
  final String userRole; // 'owner' | 'viewer'
  final bool isOnline;
  final bool isConnected;
  final int battery;
  final String location;
  final double lat;
  final double lng;
  final Color userBgBase;
  final Color userColorBase;
  final String userInitials;
  final String userName;
  final String version;
  final String statusText;

  const DeviceModel({
    required this.id,
    required this.name,
    required this.serial,
    required this.alerts,
    required this.userRole,
    required this.isOnline,
    required this.isConnected,
    required this.battery,
    required this.location,
    required this.lat,
    required this.lng,
    required this.userBgBase,
    required this.userColorBase,
    required this.userInitials,
    required this.userName,
    required this.version,
    required this.statusText,
  });

  bool get isViewer => userRole == 'viewer';

  /// Builds a DeviceModel from a `device_shares` row joined with `devices`
  /// and `profiles`, exactly like the RN `.map((shareRow) => ...)` block.
  /// `exactAddress` is resolved separately (async reverse-geocode call) and
  /// passed in, since Dart doesn't await inline inside a map the way the
  /// RN code does with Promise.all.
  factory DeviceModel.fromShareRow(
    Map<String, dynamic> shareRow, {
    required String exactAddress,
  }) {
    final d = shareRow['devices'] as Map<String, dynamic>? ?? {};
    final profile = d['profiles'] as Map<String, dynamic>?;

    final lastUpdatedRaw = d['last_updated'] as String?;
    final lastPing = lastUpdatedRaw != null
        ? DateTime.tryParse(lastUpdatedRaw)
        : null;
    final isActuallyOnline = lastPing != null &&
        DateTime.now().difference(lastPing).inMilliseconds < 10000;

    final guardianName = (profile?['full_name'] as String?)?.trim().isNotEmpty == true
        ? profile!['full_name'] as String
        : 'Primary Guardian';
    final initials = guardianName
        .split(' ')
        .where((p) => p.isNotEmpty)
        .map((p) => p[0])
        .join()
        .substring(0, guardianName.trim().split(' ').length > 1 ? 2 : 1)
        .toUpperCase();

    final logsCount = (d['logs'] as List?)?.isNotEmpty == true
        ? (d['logs'][0]['count'] as int? ?? 0)
        : 0;

    return DeviceModel(
      id: d['id']?.toString() ?? '',
      name: d['name'] as String? ?? 'Unknown Device',
      serial: d['id']?.toString() ?? '',
      alerts: logsCount,
      userRole: shareRow['role'] as String? ?? 'owner',
      isOnline: isActuallyOnline,
      isConnected: isActuallyOnline,
      battery: d['battery_level'] as int? ?? 100,
      location: exactAddress,
      lat: (d['latitude'] as num?)?.toDouble() ?? 13.1391,
      lng: (d['longitude'] as num?)?.toDouble() ?? 123.7438,
      userBgBase: const Color(0xFFF0EFFF),
      userColorBase: AppColors.accent,
      userInitials: initials,
      userName: guardianName,
      version: 'v1.0.0',
      statusText: isActuallyOnline ? 'Online' : 'Offline',
    );
  }
}
