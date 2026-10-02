import 'dart:convert';
import '../../services/supabase_service.dart';

enum PairingState { waiting, claimed, expired }

class PairingResult {
  final PairingState state;
  final String? deviceId;
  const PairingResult(this.state, [this.deviceId]);
}

/// Phone side of pairing a Smart Cane. The cane has no screen or keyboard, so
/// instead of the old "join the cane's hotspot and talk HTTP to it" flow
/// (pi_setup_server.py), the phone now:
///
///   1. asks Supabase for a single-use pairing token for the logged-in user,
///   2. shows a QR code holding the phone's hotspot name + password + token,
///   3. waits until Supabase says the cane claimed that token.
///
/// The cane (cane_boot.py) reads the QR with its camera, joins the hotspot,
/// then trades the token for its device secret via `claim_device_with_token`.
/// Supabase links the account that owns the token to the cane's device id, so
/// the user id itself never appears in the QR.
///
/// QR payload (must match parse_setup_qr in cane_boot.py exactly):
///   {"v": 1, "ssid": "<hotspot>", "pw": "<password>", "tok": "<token>"}
///
/// Supabase RPCs this file expects:
///   create_pairing_token(p_device_name text) -> text (or {"token": text})
///       single-use, ~5 min, tied to auth.uid(); token must match
///       [A-Za-z0-9_-]{16,128} or the cane will reject the QR.
///   pairing_token_status(p_token text) -> {"claimed": bool, "expired": bool,
///       "device_id": text|null}   (only for the token's own user)
class DeviceProvisioningService {
  /// How long the QR stays valid. Keep in sync with the server-side expiry.
  static const Duration codeLifetime = Duration(minutes: 5);

  static const int qrVersion = 1;
  static final RegExp _tokenRe = RegExp(r'^[A-Za-z0-9_\-]{16,128}$');

  final SupabaseService _db = SupabaseService.instance;

  static bool _hasControlChars(String s) =>
      s.runes.any((c) => c < 32 || c == 127);

  /// Same limits the cane enforces, so a bad value is caught here with a
  /// friendly message instead of the cane saying "not a setup code".
  /// Returns null when the hotspot details are fine.
  String? validateHotspot(String ssid, String password) {
    if (ssid.isEmpty) return 'Enter your hotspot name.';
    if (utf8.encode(ssid).length > 32) {
      return 'Hotspot names can be at most 32 characters.';
    }
    if (_hasControlChars(ssid) || _hasControlChars(password)) {
      return 'The hotspot name or password contains an invalid character.';
    }
    if (password.length < 8 || password.length > 63) {
      return 'The hotspot password must be 8 to 63 characters (WPA2). '
          'Open hotspots are not supported.';
    }
    return null;
  }

  /// Asks Supabase for a one-time pairing token for the current user.
  Future<String> createPairingToken(String deviceName) async {
    final token = await _db.createPairingToken(deviceName);
    if (!_tokenRe.hasMatch(token)) {
      throw Exception(
        'The server returned a pairing code in an unexpected format. '
        'Please try again.',
      );
    }
    return token;
  }

  /// The exact text to put in the QR code.
  String buildQrPayload({
    required String ssid,
    required String password,
    required String token,
  }) {
    return jsonEncode({
      'v': qrVersion,
      'ssid': ssid,
      'pw': password,
      'tok': token,
    });
  }

  /// One poll: has the cane claimed this token yet?
  Future<PairingResult> checkStatus(String token) async {
    final row = await _db.pairingTokenStatus(token);
    if (row['claimed'] == true) {
      return PairingResult(PairingState.claimed, row['device_id']?.toString());
    }
    if (row['expired'] == true) {
      return const PairingResult(PairingState.expired);
    }
    return const PairingResult(PairingState.waiting);
  }
}