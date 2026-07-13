import 'package:flutter/material.dart';
import 'package:ionicons_plus/ionicons_plus.dart';
import 'package:intl/intl.dart';
import '../theme/app_colors.dart';

/// Small value object mirroring the return value of `getStyleForEvent()`.
class LogEventStyle {
  final IconData icon;
  final Color color;
  final String category; // 'alert' | 'system' | 'battery' | 'vision'

  const LogEventStyle({
    required this.icon,
    required this.color,
    required this.category,
  });
}

/// Mirrors `getStyleForEvent(eventType)` from logs.tsx — same branching order,
/// same keyword matching.
LogEventStyle getStyleForEvent(String? eventType) {
  final typeLower = (eventType ?? '').toLowerCase();

  if (typeLower.contains('geofence breach') || typeLower.contains('violation')) {
    return const LogEventStyle(
        icon: Icons.warning_amber_rounded, color: AppColors.warning, category: 'alert');
  }
  if (typeLower.contains('emergency')) {
    return const LogEventStyle(
        icon: Ionicons.alert_circle, color: AppColors.alert, category: 'alert');
  }
  if (typeLower.contains('safe') || typeLower.contains('resolved')) {
    return const LogEventStyle(
        icon: Ionicons.shield_checkmark, color: AppColors.success, category: 'system');
  }
  if (typeLower.contains('battery')) {
    return const LogEventStyle(
        icon: Ionicons.battery_dead, color: AppColors.alert, category: 'battery');
  }
  if (typeLower.contains('vision') || typeLower.contains('crosswalk')) {
    return const LogEventStyle(
        icon: Ionicons.camera, color: AppColors.primary, category: 'vision');
  }
  return const LogEventStyle(
      icon: Ionicons.information_circle, color: AppColors.primary, category: 'system');
}

/// Mirrors the object built inside `fetchLogs()`'s `data.map(dbLog => ...)`.
class LogModel {
  final String id;
  final String type; // category from getStyleForEvent
  final String title;
  final String desc;
  final String device;
  final DateTime createdAt;
  final IconData icon;
  final Color color;
  final double? lat;
  final double? lng;

  const LogModel({
    required this.id,
    required this.type,
    required this.title,
    required this.desc,
    required this.device,
    required this.createdAt,
    required this.icon,
    required this.color,
    this.lat,
    this.lng,
  });

  /// Equivalent of formatTime(dateString) -> toLocaleTimeString hour:minute
  String get time => DateFormat('h:mm a').format(createdAt.toLocal());

  factory LogModel.fromRow(Map<String, dynamic> row) {
    final style = getStyleForEvent(row['event_type'] as String?);
    final createdAtRaw = row['created_at'] as String?;
    return LogModel(
      id: row['id'].toString(),
      type: style.category,
      title: (row['title'] as String?) ?? (row['event_type'] as String?) ?? 'Log',
      desc: row['message'] as String? ?? '',
      device: row['device_id']?.toString() ?? 'Unknown Device',
      createdAt: createdAtRaw != null
          ? DateTime.tryParse(createdAtRaw) ?? DateTime.now()
          : DateTime.now(),
      icon: style.icon,
      color: style.color,
      lat: (row['latitude'] as num?)?.toDouble(),
      lng: (row['longitude'] as num?)?.toDouble(),
    );
  }
}
