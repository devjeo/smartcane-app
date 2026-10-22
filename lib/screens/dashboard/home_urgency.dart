import '../../models/device_model.dart';

/// Battery at or below this percent counts as "low battery" on Home.
const int kLowBatteryPercent = 20;

/// How urgent a cane is, most urgent first. The order of these values IS the
/// order of the Home list.
enum HomeUrgency {
  sos,             // 1. an SOS in the last 30 minutes
  offlineOrSilent, // 2. cane offline, or online but the user's phone is silent
  lowBattery,      // 3. battery <= kLowBatteryPercent
  walking,         // 4. on an active walk
  normal,          // 5. everything else
}

HomeUrgency urgencyOf(
  DeviceModel d, {
  required bool sos,
  required bool silentPhone,
  required bool walking,
}) {
  if (sos) return HomeUrgency.sos;
  if (!d.isOnline || silentPhone) return HomeUrgency.offlineOrSilent;
  if (d.battery <= kLowBatteryPercent) return HomeUrgency.lowBattery;
  if (walking) return HomeUrgency.walking;
  return HomeUrgency.normal;
}

/// Sorts canes by urgency, then alphabetically by the cane user's name.
/// Returns a new list; [devices] is not changed.
List<DeviceModel> sortByUrgency(
  List<DeviceModel> devices, {
  required Set<String> sosIds,
  required Set<String> silentIds,
  required Set<String> walkingIds,
}) {
  HomeUrgency u(DeviceModel d) => urgencyOf(d,
      sos: sosIds.contains(d.id),
      silentPhone: silentIds.contains(d.id),
      walking: walkingIds.contains(d.id));
  final list = [...devices];
  list.sort((a, b) {
    final byTier = u(a).index.compareTo(u(b).index);
    if (byTier != 0) return byTier;
    return a.userName.toLowerCase().compareTo(b.userName.toLowerCase());
  });
  return list;
}
