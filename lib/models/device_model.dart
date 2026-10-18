import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Mirrors the `mappedDevices` shape built inside `fetchDevices()` in index.tsx.
class DeviceModel {
  final String id;
  final String name;
  final String serial;
  final int alerts;
  final String userRole; // raw device_shares.role: 'admin' (guardian) | 'user' | 'viewer'
  final DateTime? lastSeenAt;   // written ONLY by the cane's heartbeat (devices.last_seen_at)
  final int battery;
  final String location;
  final double? lat;   // null until the device has reported a real location
  final double? lng;
  final Color userBgBase;
  final Color userColorBase;
  final String userInitials;
  final String userName;   // the cane's USER (not the guardian); 'No user linked' if none
  final String version;
  final String? guardianId;
  final String? caneUserId;
  final String guardianName;

  const DeviceModel({
    required this.id,
    required this.name,
    required this.serial,
    required this.alerts,
    required this.userRole,
    required this.lastSeenAt,
    required this.battery,
    required this.location,
    required this.lat,
    required this.lng,
    required this.userBgBase,
    required this.userColorBase,
    required this.userInitials,
    required this.userName,
    required this.version,
    this.guardianId,
    this.caneUserId,
    this.guardianName = '',
  });

  bool get isViewer => userRole == 'viewer';
  bool get isGuardian => userRole == 'admin' || userRole == 'owner';
  bool get isCaneUser => userRole == 'user' || userRole == 'owner';
  bool get isSolo => userRole == 'owner';
  bool get hasUser => caneUserId != null;

  /// 'guardian' | 'user' | 'viewer'
  String get myRole => isGuardian ? 'guardian' : (isCaneUser ? 'user' : 'viewer');
  String get roleLabel => isGuardian ? 'Guardian' : (isCaneUser ? 'Cane user' : 'Viewer');

  /// The cane heartbeats every 15 s; no heartbeat for this long = offline.
  static const onlineWindow = Duration(seconds: 50);

  /// Evaluated every time it is read, so a screen that rebuilds on a timer
  /// flips to Offline by itself instead of waiting for the next fetch.
  bool get isOnline =>
      lastSeenAt != null && DateTime.now().difference(lastSeenAt!) < onlineWindow;
  bool get isConnected => isOnline;
  String get statusText => isOnline ? 'Online' : 'Offline';

  DeviceModel withLastSeen(DateTime? t) => DeviceModel(
        id: id,
        name: name,
        serial: serial,
        alerts: alerts,
        userRole: userRole,
        lastSeenAt: t,
        battery: battery,
        location: location,
        lat: lat,
        lng: lng,
        userBgBase: userBgBase,
        userColorBase: userColorBase,
        userInitials: userInitials,
        userName: userName,
        version: version,
        guardianId: guardianId,
        caneUserId: caneUserId,
        guardianName: guardianName,
      );

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
    final guardian = d['guardian'] as Map<String, dynamic>?;
    final caneUser = d['cane_user'] as Map<String, dynamic>?;

    final lastSeenRaw = d['last_seen_at'] as String?;
    final lastSeen = lastSeenRaw != null ? DateTime.tryParse(lastSeenRaw) : null;

    String nameOf(Map<String, dynamic>? p) {
      final n = (p?['full_name'] as String?)?.trim() ?? '';
      return n;
    }

    final guardianName = nameOf(guardian).isNotEmpty ? nameOf(guardian) : 'Primary Guardian';
    final hasUser = d['user_id'] != null;
    final userName = !hasUser
        ? 'No user linked'
        : (nameOf(caneUser).isNotEmpty ? nameOf(caneUser) : 'Cane user');
    final initials = !hasUser ? '?' : _initialsOf(userName);

    final logsCount = (d['logs'] as List?)?.isNotEmpty == true
        ? (d['logs'][0]['count'] as int? ?? 0)
        : 0;

    return DeviceModel(
      id: d['id']?.toString() ?? '',
      name: d['name'] as String? ?? 'Unknown Device',
      serial: d['id']?.toString() ?? '',
      alerts: logsCount,
      userRole: shareRow['role'] as String? ?? 'owner',
      lastSeenAt: lastSeen,
      battery: d['battery_level'] as int? ?? 100,
      location: exactAddress,
      lat: (d['latitude'] as num?)?.toDouble(),
      lng: (d['longitude'] as num?)?.toDouble(),
      userBgBase: const Color(0xFFF0EFFF),
      userColorBase: AppColors.accent,
      userInitials: initials,
      userName: userName,
      version: 'v1.0.0',
      guardianId: d['guardian_id']?.toString(),
      caneUserId: d['user_id']?.toString(),
      guardianName: guardianName,
    );
  }

  static String _initialsOf(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }
}
