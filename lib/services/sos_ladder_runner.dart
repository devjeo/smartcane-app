import 'dart:async';

import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:another_telephony/telephony.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show Helper;
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:phone_state/phone_state.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'call_log.dart';

/// SOLO cane users: when the cane's SOS creates a `sos_events` row, this runs
/// INSIDE the always-running tracking service (like UserCallRunner) and
///   1. speaks what is happening,
///   2. texts every contact a Google Maps link (so they know even if they miss the call),
///   3. calls the phone contacts in priority order, up to [_rounds] rounds.
/// A call counts as answered when it lasted at least [_answeredMin] seconds
/// (Android does not tell us who picked up; voicemail usually answers later
/// than this). Emergency hotlines are never dialed: contacts must be E.164
/// numbers (enforced by the database).
class SosLadderRunner {
  SosLadderRunner._();
  static final SosLadderRunner instance = SosLadderRunner._();

  static const _answeredMin = Duration(seconds: 25);
  static const _startGuard = Duration(seconds: 20); // call must reach "dialing" by then
  static const _maxCall = Duration(minutes: 15);
  static const _roundPause = Duration(seconds: 20);
  static const _rounds = 2;
  static const _stale = Duration(seconds: 120);

  SupabaseClient get _db => Supabase.instance.client;
  final FlutterTts _tts = FlutterTts();
  bool _ttsReady = false;

  RealtimeChannel? _channel;
  String? _uid;
  String? _activeId;

  /// True while an SOS ladder is running (used by background location
  /// sending to switch to fast "live" reporting).
  bool get isActive => _activeId != null;

  /// Call once from the MAIN isolate (e.g. when a solo cane is paired or the
  /// contacts screen opens). Returns true when phone + SMS were granted.
  static Future<bool> ensurePermissions() async {
    final r = await [Permission.phone, Permission.sms].request();
    if (!await Permission.systemAlertWindow.isGranted) {
      // "Display over other apps": lets Android start the call from the background.
      await Permission.systemAlertWindow.request();
    }
    return r.values.every((s) => s.isGranted);
  }

  Future<void> start(String uid) async {
    if (_uid == uid && _channel != null) return;
    _uid = uid;
    await _channel?.unsubscribe();
    _channel = _db
        .channel('user-sos-$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'sos_events',
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq, column: 'user_id', value: uid),
          callback: (p) => _onRow(p.newRecord),
        )
        .subscribe();
    await _resumeIfOpen(uid);
  }

  Future<void> stop() async {
    await _channel?.unsubscribe();
    _channel = null;
    _uid = null;
  }

  /// Backup path: the `start_sos` push names the event.
  Future<void> handleSosId(String sosId) async {
    if (_activeId != null) return;
    try {
      final row = await _db.from('sos_events').select().eq('id', sosId).maybeSingle();
      if (row != null) _onRow(row);
    } catch (e) {
      callLog('SOS fetch failed: $e');
    }
  }

  Future<void> _resumeIfOpen(String uid) async {
    try {
      final since = DateTime.now().toUtc().subtract(_stale);
      final rows = await _db
          .from('sos_events')
          .select()
          .eq('user_id', uid)
          .eq('status', 'open')
          .gte('created_at', since.toIso8601String())
          .order('created_at', ascending: false)
          .limit(1);
      if (rows.isNotEmpty) _onRow(rows.first);
    } catch (_) {}
  }

  void _onRow(Map<String, dynamic> row) {
    if (_activeId != null) return; // one SOS at a time
    if (row['status'] != 'open') return;
    final created = DateTime.tryParse('${row['created_at']}');
    if (created != null && DateTime.now().toUtc().difference(created.toUtc()) > _stale) {
      return;
    }
    _run(row);
  }

  // ---------- the ladder ----------

  Future<void> _run(Map<String, dynamic> row) async {
    final id = '${row['id']}';
    final deviceId = '${row['device_id']}';
    _activeId = id;
    var outcome = 'exhausted';
    try {
      final contacts = await _loadContacts(deviceId);
      if (contacts.isEmpty) {
        outcome = 'no_contacts';
        await _say('Emergency. You have no emergency contacts saved.');
        return;
      }

      final who = await _who(deviceId);
      final link = await _mapsLink(deviceId);
      await _say('Emergency. Sending your location and calling your contacts.');
      await _sendSms(contacts, 'SOS from $who. I need help. Location: $link');

      for (var round = 0; round < _rounds; round++) {
        for (final c in contacts.where((c) => c.allowCall)) {
          if (await _isCancelled(id)) {
            outcome = 'cancelled';
            return;
          }
          await _say('Calling ${c.name}.');
          await Future.delayed(const Duration(seconds: 2));
          if (await _dial(c.phone)) {
            outcome = 'contact:${c.name}';
            return;
          }
        }
        if (round < _rounds - 1) {
          await Future.delayed(_roundPause);
        }
      }
      await _say('Nobody answered. Your contacts have been sent a message.');
    } catch (e) {
      callLog('SOS ladder error: $e');
    } finally {
      try {
        await _db.rpc('finish_sos', params: {
          'p_sos_id': id,
          'p_status': outcome == 'cancelled' ? 'cancelled' : 'resolved',
          'p_by': outcome,
        });
      } catch (e) {
        callLog('finish_sos failed: $e');
      }
      _activeId = null;
    }
  }

  Future<List<_Contact>> _loadContacts(String deviceId) async {
    final rows = await _db
        .from('device_contacts')
        .select('name, phone, allow_call, allow_sms')
        .eq('device_id', deviceId)
        .eq('active', true)
        .eq('kind', 'phone')
        .order('priority', ascending: true);
    return rows
        .map((r) => _Contact(
              name: '${r['name']}',
              phone: '${r['phone']}',
              allowCall: r['allow_call'] == true,
              allowSms: r['allow_sms'] == true,
            ))
        .toList();
  }

  Future<bool> _isCancelled(String id) async {
    try {
      final r = await _db.from('sos_events').select('status').eq('id', id).maybeSingle();
      return r != null && r['status'] == 'cancelled';
    } catch (_) {
      return false;
    }
  }

  Future<String> _who(String deviceId) async {
    try {
      final uid = _uid;
      if (uid != null) {
        final p = await _db.from('profiles').select('full_name').eq('id', uid).maybeSingle();
        final n = '${p?['full_name'] ?? ''}'.trim();
        if (n.isNotEmpty) return n.length > 24 ? n.substring(0, 24) : n;
      }
    } catch (_) {}
    return 'a SmartCane user';
  }

  Future<String> _mapsLink(String deviceId) async {
    double? lat, lng;
    try {
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 10));
      lat = p.latitude;
      lng = p.longitude;
    } catch (_) {
      try {
        final d = await _db.from('devices').select('latitude, longitude').eq('id', deviceId).maybeSingle();
        lat = (d?['latitude'] as num?)?.toDouble();
        lng = (d?['longitude'] as num?)?.toDouble();
      } catch (_) {}
    }
    if (lat == null || lng == null) return '(location unavailable)';
    return 'https://maps.google.com/?q=${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}';
  }

  Future<void> _sendSms(List<_Contact> contacts, String text) async {
    if (!await Permission.sms.isGranted) {
      callLog('SOS: SMS permission missing');
      return;
    }
    for (final c in contacts.where((c) => c.allowSms)) {
      try {
        await Telephony.instance.sendSms(to: c.phone, message: text);
      } catch (e) {
        callLog('SOS SMS to ${c.name} failed: $e');
      }
    }
  }

  /// Places the call and waits until it ends. true = answered (long enough).
  Future<bool> _dial(String phone) async {
    if (!await Permission.phone.isGranted) {
      callLog('SOS: phone permission missing');
      return false;
    }
    final done = Completer<bool>();
    DateTime? startedAt;

    final sub = PhoneState.stream.listen((s) {
      if (s.status == PhoneStateStatus.CALL_STARTED && startedAt == null) {
        startedAt = DateTime.now();
      } else if (s.status == PhoneStateStatus.CALL_ENDED &&
          startedAt != null &&
          !done.isCompleted) {
        done.complete(DateTime.now().difference(startedAt!) >= _answeredMin);
      }
    });
    final startGuard = Timer(_startGuard, () {
      if (startedAt == null && !done.isCompleted) done.complete(false);
    });
    final maxGuard = Timer(_maxCall, () {
      if (!done.isCompleted) done.complete(true);
    });

    try {
      await _launchCall(phone);
      unawaited(_speakerOn());
      return await done.future;
    } catch (e) {
      callLog('SOS dial failed: $e');
      return false;
    } finally {
      startGuard.cancel();
      maxGuard.cancel();
      await sub.cancel();
    }
  }

  /// Apps like Viber also answer "call this number", which makes Android show
  /// a "Complete action using" chooser that nobody can tap during an emergency.
  /// Aim the intent straight at the system phone service (no chooser), and only
  /// fall back to the open intent if that is not available on this phone.
  static const _phoneServices = ['com.android.server.telecom', 'com.android.phone'];

  Future<void> _launchCall(String phone) async {
    Object? lastError;
    for (final pkg in <String?>[..._phoneServices, null]) {
      try {
        final intent = AndroidIntent(
          action: 'android.intent.action.CALL',
          data: 'tel:$phone',
          package: pkg,
          flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
        );
        if (pkg != null && await intent.canResolveActivity() == false) continue;
        await intent.launch();
        callLog('SOS: call placed via ${pkg ?? 'default chooser'}');
        return;
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? Exception('no phone app can place the call');
  }

  /// Best effort: the person may be unable to see the dialer's speaker button.
  Future<void> _speakerOn() async {
    for (final s in const [3, 6]) {
      await Future.delayed(Duration(seconds: s));
      try {
        await Helper.setSpeakerphoneOn(true);
      } catch (_) {}
    }
  }

  Future<void> _say(String text) async {
    try {
      if (!_ttsReady) {
        _ttsReady = true;
        await _tts.setLanguage('en-US');
        await _tts.setSpeechRate(0.45);
      }
      await _tts.speak(text);
    } catch (_) {}
  }
}

class _Contact {
  final String name;
  final String phone;
  final bool allowCall;
  final bool allowSms;
  _Contact({
    required this.name,
    required this.phone,
    required this.allowCall,
    required this.allowSms,
  });
}
