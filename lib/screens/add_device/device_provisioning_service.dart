import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:app_settings/app_settings.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:op_wifi_utils/op_wifi_utils.dart';
import 'package:wifi_scan/wifi_scan.dart' as wifi_scan;

/// Represents a WiFi network the cane found during its scan.
class ScannedNetwork {
  final String ssid;
  final int signalStrength; // dBm, more negative = weaker
  final bool secured;

  ScannedNetwork({required this.ssid, required this.signalStrength, required this.secured});

  factory ScannedNetwork.fromJson(Map<String, dynamic> json) {
    return ScannedNetwork(
      ssid: json['ssid'] as String? ?? '',
      signalStrength: (json['rssi'] as num?)?.toInt() ?? -100,
      secured: json['secured'] as bool? ?? true,
    );
  }
}

enum WifiConnectStatus { connected, failed, timedOut }

/// Thrown by [DeviceProvisioningService.currentDeviceIdIfOnCaneHotspot]
/// specifically when Android hands back the "<unknown ssid>" placeholder
/// instead of a real network name — almost always because the app hasn't
/// been granted location permission, which Android ties WiFi-info access
/// to for historical reasons unrelated to actually using location.
class UnknownSsidException implements Exception {
  @override
  String toString() =>
      "Android couldn't read the current WiFi network name — this app "
      'needs location permission granted for that (a platform quirk, not '
      "related to actually using your location). Check Settings > Apps > "
      '[this app] > Permissions > Location, then try again.';
}

/// Handles every step of talking to the cane, from finding it in the first
/// place through to the phone being joined to *its* hotspot (not the home
/// WiFi yet).
///
/// `op_wifi_utils` itself only exposes four calls — `connectToWifi`,
/// `disconnectFromWifi`, `getCurrentSsid`, `isAvailable` — it has no
/// "list nearby networks" method, so ambient scanning here comes from the
/// separate `wifi_scan` package instead (Android only, see
/// [autoDiscoverAndJoin]).
///
/// Contract with the device firmware (see pi_setup_server.py):
///   GET  /identify -> { "deviceId": "...", "model": "..." }
///   GET  /scan     -> { "networks": [ { "ssid", "rssi", "secured" }, ... ] }
///   POST /connect  <- { "ssid": "...", "password": "..." }
///   GET  /status   -> { "status": "connecting" | "connected" | "failed" }
/// (currently pointed at a hardcoded address — see [_deviceBaseUrl].)
class DeviceProvisioningService {
  // HARDCODED per current setup: the test server (main.py) isn't reachable
  // at a dynamically-resolved address (it's not hosting its own hotspot —
  // it runs on the regular WiFi network), so gateway-IP resolution was
  // removed. If the server's address ever changes, update this constant.
  static const String _deviceBaseUrl = 'http://192.168.4.1';

  /// Every cane's own setup hotspot starts with this. The deviceId is
  /// embedded straight in the SSID, so once we know *which* SSID the
  /// phone joined, we know the deviceId without anyone typing it in.
  static const String hotspotPrefix = 'SmartCane-';

  String hotspotSsidFor(String deviceId) => '$hotspotPrefix$deviceId';

  /// Full hands-off discovery: ambient-scans for a nearby cane hotspot and
  /// joins it automatically (it's an open network — see pi_setup_server.py
  /// — so there's no password to supply). Returns the deviceId of the cane
  /// it joined, or null if none was found nearby.
  ///
  /// Android only. iOS has no public API for a third-party app to scan
  /// nearby WiFi networks — that's an Apple platform restriction, not
  /// something any app can route around — so on iOS this throws
  /// [UnsupportedError] and callers should fall back to
  /// [openWifiSettings] + [currentDeviceIdIfOnCaneHotspot], or to scanning
  /// a QR code if the cane ships with one.
  Future<String?> autoDiscoverAndJoin() async {
    final matchSsid = await _scanForCaneSsid();
    if (matchSsid == null) return null;

    final deviceId = matchSsid.substring(hotspotPrefix.length);
    if (deviceId.isEmpty) return null;

    final joined = await OpWifiUtils.connectToWifi(ssid: matchSsid, password: '');
    if (!joined.isSuccess) {
      throw Exception('Found the cane but could not join its network.');
    }
    return deviceId;
  }

  /// TEST-ONLY: same ambient scan as [autoDiscoverAndJoin], but stops at
  /// detection — it never actually joins the cane's hotspot. Used for the
  /// debug-only bypass on the manual-join screen: the deviceId is read
  /// straight off a real "SmartCane-..." SSID nearby (so this only
  /// succeeds if a cane is genuinely detected), but since requests go to
  /// [_deviceBaseUrl]'s hardcoded test address rather than the hotspot
  /// itself, there's nothing to gain from actually joining it. Returns
  /// null if no matching SSID is currently visible. Android only, same
  /// platform restriction as [autoDiscoverAndJoin].
  Future<String?> scanForNearbyCaneId() async {
    final matchSsid = await _scanForCaneSsid();
    if (matchSsid == null) return null;
    final deviceId = matchSsid.substring(hotspotPrefix.length);
    return deviceId.isEmpty ? null : deviceId;
  }

  /// Shared ambient-scan step behind [autoDiscoverAndJoin] and
  /// [scanForNearbyCaneId] — returns the first matching "SmartCane-..."
  /// SSID currently visible, or null if none is.
  Future<String?> _scanForCaneSsid() async {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'Automatic WiFi discovery is only available on Android.',
      );
    }

    final scanner = wifi_scan.WiFiScan.instance;

    final canScan = await scanner.canStartScan(askPermissions: true);
    if (canScan != wifi_scan.CanStartScan.yes) {
      throw Exception(
        'WiFi scanning needs location permission on Android — please '
        'allow it and try again.',
      );
    }
    await scanner.startScan();
    // Give the platform scan a moment to actually populate results.
    await Future.delayed(const Duration(seconds: 3));

    final canGetResults = await scanner.canGetScannedResults(askPermissions: true);
    if (canGetResults != wifi_scan.CanGetScannedResults.yes) {
      throw Exception('WiFi scan results are not available on this device.');
    }

    final results = await scanner.getScannedResults();
    for (final r in results) {
      if (r.ssid.startsWith(hotspotPrefix)) return r.ssid;
    }
    return null;
  }

  /// Opens the OS's own WiFi settings screen — the fallback path for when
  /// [autoDiscoverAndJoin] isn't available (iOS) or didn't find anything.
  Future<void> openWifiSettings() {
    return AppSettings.openAppSettings(type: AppSettingsType.wifi);
  }

  /// Checks whether the phone is *currently* joined to a cane's setup
  /// hotspot — call this after the person comes back from system WiFi
  /// settings — and returns the deviceId encoded in its SSID, or null if
  /// the current network isn't a cane hotspot at all.
  ///
  /// Throws [UnknownSsidException] specifically when Android can't read
  /// the SSID at all (almost always a missing location permission) — that
  /// case is deliberately NOT folded into a plain "returned null", so the
  /// caller can show a real fix instead of a generic "not connected yet".
  Future<String?> currentDeviceIdIfOnCaneHotspot() async {
    final result = await OpWifiUtils.getCurrentSsid();
    // NOTE: confirm the field name your installed op_wifi_utils version
    // uses for the payload (`.data` here) — some releases call it
    // `.value` instead. `result.isSuccess` is already used elsewhere in
    // this file against the same OpResult type, so that part is solid.
    var ssid = result.data;

    // Debug: leave this in temporarily while chasing a "not connected yet"
    // false negative — it'll show you exactly what the OS handed back.
    // Two very common surprises here:
    //  1. Android wraps the SSID in literal double quotes
    //     (`"SmartCane-DID-..."`) unless it's a hex SSID — stripped below.
    //  2. Android returns the placeholder string "<unknown ssid>" instead
    //     of the real SSID if the app doesn't have location permission
    //     granted (WiFi info is gated behind it on Android, for
    //     historical reasons unrelated to actual location use).
    debugPrint('[provisioning] getCurrentSsid -> isSuccess=${result.isSuccess}, raw="$ssid"');

    if (!result.isSuccess || ssid == null) return null;

    if (ssid.startsWith('"') && ssid.endsWith('"') && ssid.length >= 2) {
      ssid = ssid.substring(1, ssid.length - 1);
    }

    if (ssid == '<unknown ssid>' || ssid.isEmpty) {
      throw UnknownSsidException();
    }

    if (!ssid.startsWith(hotspotPrefix)) return null;
    final id = ssid.substring(hotspotPrefix.length);
    return id.isEmpty ? null : id;
  }

  /// Joins the cane's own hotspot directly — used when we already know the
  /// exact deviceId (from a QR code / deep link) but haven't joined its
  /// network yet. The setup hotspot is open, so no password is sent.
  ///
  /// Returns true if the OS reports the connection succeeded (does NOT
  /// guarantee /identify will respond yet — give the device a beat to
  /// bring its HTTP server up).
  Future<bool> connectToDeviceHotspot(String deviceId) async {
    final ssid = hotspotSsidFor(deviceId);
    final result = await OpWifiUtils.connectToWifi(ssid: ssid, password: '');
    return result.isSuccess;
  }

  /// Confirms we're actually talking to the expected cane (not some other
  /// device, and not a stale connection). Retries briefly since the
  /// device's local server can take a second or two to come up after
  /// the hotspot connection succeeds.
  Future<bool> identifyDevice(String expectedDeviceId) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        final res = await http
            .get(Uri.parse('$_deviceBaseUrl/identify'))
            .timeout(const Duration(seconds: 4));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          if (data['deviceId'] == expectedDeviceId) return true;
        }
      } catch (_) {
        // fall through and retry
      }
      await Future.delayed(const Duration(seconds: 1));
    }
    return false;
  }

  Future<List<ScannedNetwork>> scanNearbyNetworks() async {
    final res = await http
        .get(Uri.parse('$_deviceBaseUrl/scan'))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw Exception('The cane could not scan for WiFi networks.');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final list = (data['networks'] as List<dynamic>? ?? [])
        .map((e) => ScannedNetwork.fromJson(e as Map<String, dynamic>))
        // Defensive filter: the home-network list should never include
        // another cane's own setup hotspot.
        .where((n) => !n.ssid.startsWith(hotspotPrefix))
        .toList();
    list.sort((a, b) => b.signalStrength.compareTo(a.signalStrength));
    return list;
  }

  Future<void> sendWifiCredentials({required String ssid, required String password}) async {
    final res = await http
        .post(
          Uri.parse('$_deviceBaseUrl/connect'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'ssid': ssid, 'password': password}),
        )
        .timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) {
      throw Exception('The cane rejected the WiFi details. Please try again.');
    }
  }

  /// Polls the cane's status while it attempts to join the home network.
  /// Expect the phone to briefly lose the connection partway through —
  /// that's the cane dropping its hotspot after a successful join, not
  /// an error by itself. We only give up after [timeout].
  Future<WifiConnectStatus> pollConnectionStatus({
    Duration timeout = const Duration(seconds: 40),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final res = await http
            .get(Uri.parse('$_deviceBaseUrl/status'))
            .timeout(const Duration(seconds: 1));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          switch (data['status']) {
            case 'connected':
              return WifiConnectStatus.connected;
            case 'failed':
              return WifiConnectStatus.failed;
          }
        }
      } catch (_) {
        // Expected while the cane's hotspot is dropping — keep polling.
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    return WifiConnectStatus.timedOut;
  }

  /// Best-effort cleanup: if we're still sitting on a cane's setup hotspot
  /// (e.g. the user backed out mid-flow), hop off it so the phone goes
  /// back to normal connectivity. `disconnectFromWifi` needs the SSID to
  /// disconnect from, so we look up the current one first — there's
  /// nothing to do if we're not on a cane hotspot at all.
  Future<void> disconnectFromDeviceHotspot() async {
    try {
      final result = await OpWifiUtils.getCurrentSsid();
      if (!result.isSuccess) return;
      final ssid = result.data;
      if (ssid != null && ssid.startsWith(hotspotPrefix)) {
        await OpWifiUtils.disconnectFromWifi(ssid);
      }
    } catch (_) {
      // Best-effort cleanup only.
    }
  }
}