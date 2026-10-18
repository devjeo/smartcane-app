import 'package:supabase_flutter/supabase_flutter.dart';

/// One row of `device_contacts` (kind = 'phone'). App-guardian contacts
/// (kind = 'app') are not used by the SOS ladder yet.
class EmergencyContact {
  final String id;
  final String deviceId;
  final String name;
  final String phone;
  final int priority;
  final bool allowCall;
  final bool allowSms;
  final bool active;

  const EmergencyContact({
    required this.id,
    required this.deviceId,
    required this.name,
    required this.phone,
    required this.priority,
    required this.allowCall,
    required this.allowSms,
    required this.active,
  });

  factory EmergencyContact.fromMap(Map<String, dynamic> m) => EmergencyContact(
        id: '${m['id']}',
        deviceId: '${m['device_id']}',
        name: '${m['name']}',
        phone: '${m['phone'] ?? ''}',
        priority: (m['priority'] as num?)?.toInt() ?? 1,
        allowCall: m['allow_call'] == true,
        allowSms: m['allow_sms'] == true,
        active: m['active'] == true,
      );
}

class EmergencyContactsService {
  EmergencyContactsService._();
  static final EmergencyContactsService instance = EmergencyContactsService._();

  static const maxContacts = 20;
  SupabaseClient get _db => Supabase.instance.client;

  Future<List<EmergencyContact>> fetch(String deviceId) async {
    final rows = await _db
        .from('device_contacts')
        .select()
        .eq('device_id', deviceId)
        .eq('kind', 'phone')
        .order('priority', ascending: true)
        .order('created_at', ascending: true);
    return (rows as List)
        .map((r) => EmergencyContact.fromMap(Map<String, dynamic>.from(r as Map)))
        .toList();
  }

  Future<void> add({
    required String deviceId,
    required String name,
    required String phone,
    required int priority,
  }) async {
    await _db.from('device_contacts').insert({
      'device_id': deviceId,
      'name': name,
      'kind': 'phone',
      'phone': phone,
      'priority': priority.clamp(1, maxContacts),
    });
  }

  Future<void> update(String id, Map<String, dynamic> changes) async {
    await _db.from('device_contacts').update(changes).eq('id', id);
  }

  Future<void> delete(String id) async {
    await _db.from('device_contacts').delete().eq('id', id);
  }

  /// Rewrites priorities as 1..n in the given order (only rows that changed).
  Future<void> saveOrder(List<EmergencyContact> ordered) async {
    for (var i = 0; i < ordered.length; i++) {
      if (ordered[i].priority != i + 1) {
        await update(ordered[i].id, {'priority': i + 1});
      }
    }
  }

  /// "0917 123 4567", "9171234567", "639171234567", "+63 917 123 4567" ->
  /// "+639171234567". Returns null when it is not a full phone number, which
  /// also rejects short emergency codes such as 911 or 117.
  static String? normalizePhone(String raw) {
    var s = raw.trim().replaceAll(RegExp(r'[\s\-().]'), '');
    if (s.startsWith('00')) s = '+${s.substring(2)}';
    if (!s.startsWith('+')) {
      if (RegExp(r'^09\d{9}$').hasMatch(s)) {
        s = '+63${s.substring(1)}';
      } else if (RegExp(r'^9\d{9}$').hasMatch(s)) {
        s = '+63$s';
      } else if (RegExp(r'^639\d{9}$').hasMatch(s)) {
        s = '+$s';
      } else {
        return null;
      }
    }
    return RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch(s) ? s : null;
  }
}
