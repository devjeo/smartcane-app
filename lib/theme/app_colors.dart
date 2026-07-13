import 'package:flutter/material.dart';

/// Mirrors the `colors` object that was redefined in every RN screen
/// (index.tsx, logs.tsx, settings.tsx, _layout.tsx). Centralized here so
/// every screen/widget pulls from one source of truth.
class AppColors {
  AppColors._();

  static const bg = Color(0xFFF8FAFC); // Very light grey main background
  static const card = Color(0xFFFFFFFF); // Pure white cards
  static const textMain = Color(0xFF1E293B); // Dark grey (headings)
  static const textSub = Color(0xFF64748B); // Medium grey (labels/subtitles)
  static const border = Color(0xFFE2E8F0); // Light border color
  static const primary = Color(0xFF007BFF); // Guardian blue (active/connected)
  static const accent = Color(0xFF7C3AED); // Purple user initial
  static const online = Color(0xFF22C55E); // Green
  static const offline = Color(0xFF94A3B8); // Grey (offline status)
  static const alert = Color(0xFFEF4444); // Red (alerts badge)
  static const warning = Color(0xFFF59E0B); // Amber (battery/geofence warnings)
  static const success = Color(0xFF22C55E);
  static const chipBg = Color(0xFFF1F5F9);

  // Used for the small "Caregiver Access" / VIEWER pill badges
  static const viewerTagBg = Color(0xFFF3E8FF);
  static const viewerTagBorder = Color(0xFFD8B4FE);
}
