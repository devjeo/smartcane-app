import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class PendingDevice {
  final String id;
  final String name;
  final DateTime addedAt;

  PendingDevice({required this.id, required this.name, required this.addedAt});

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'addedAt': addedAt.toIso8601String(),
      };

  factory PendingDevice.fromJson(Map<String, dynamic> json) => PendingDevice(
        id: json['id'] as String,
        name: json['name'] as String? ?? 'My Smart Cane',
        addedAt: DateTime.tryParse(json['addedAt'] as String? ?? '') ?? DateTime.now(),
      );
}

/// Devices the phone has walked through the provisioning wizard for but
/// that haven't shown up in a `SupabaseService.fetchDevices()` result yet
/// — either because the cane hasn't finished registering itself, or
/// because the row exists but hasn't propagated to this client's next
/// fetch. Purely local bookkeeping so the dashboard can show "setting
/// up..." instead of the device just vanishing after the wizard closes.
class PendingDeviceStore {
  PendingDeviceStore._();
  static final PendingDeviceStore instance = PendingDeviceStore._();

  static const _prefsKey = 'pending_devices_v1';

  Future<List<PendingDevice>> getAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_prefsKey) ?? [];
    return raw
        .map((s) {
          try {
            return PendingDevice.fromJson(jsonDecode(s) as Map<String, dynamic>);
          } catch (_) {
            return null;
          }
        })
        .whereType<PendingDevice>()
        .toList();
  }

  Future<void> add(String deviceId, String name) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await getAll();
    if (current.any((d) => d.id == deviceId)) return;
    current.add(PendingDevice(id: deviceId, name: name, addedAt: DateTime.now()));
    await prefs.setStringList(_prefsKey, current.map((d) => jsonEncode(d.toJson())).toList());
  }

  /// Call once a device shows up in a real `fetchDevices()` result — there's
  /// no more need to track it locally, the real card takes over.
  Future<void> remove(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await getAll();
    current.removeWhere((d) => d.id == deviceId);
    await prefs.setStringList(_prefsKey, current.map((d) => jsonEncode(d.toJson())).toList());
  }

  /// Drops any pending entry older than [maxAge] — a safety net in case a
  /// setup silently failed server-side (e.g. the cane never got internet
  /// access to register itself) and would otherwise sit "setting up..."
  /// forever.
  Future<void> pruneStale({Duration maxAge = const Duration(hours: 6)}) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await getAll();
    final cutoff = DateTime.now().subtract(maxAge);
    final kept = current.where((d) => d.addedAt.isAfter(cutoff)).toList();
    await prefs.setStringList(_prefsKey, kept.map((d) => jsonEncode(d.toJson())).toList());
  }
}