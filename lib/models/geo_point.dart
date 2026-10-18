/// A plain latitude/longitude pair.
///
/// Pure Dart on purpose (no Flutter or Google Maps imports) so the
/// background navigation service can use it too. In the UI convert with
/// `LatLng(p.lat, p.lng)`.
class GeoPoint {
  final double lat;
  final double lng;
  const GeoPoint(this.lat, this.lng);

  /// Stored in the database as `[lat, lng]`.
  List<double> toJson() => [lat, lng];

  /// Accepts `[lat, lng]` or `{lat:, lng:}`.
  static GeoPoint fromJson(dynamic j) {
    if (j is List && j.length >= 2) {
      return GeoPoint((j[0] as num).toDouble(), (j[1] as num).toDouble());
    }
    if (j is Map) {
      return GeoPoint((j['lat'] as num).toDouble(), (j['lng'] as num).toDouble());
    }
    throw FormatException('Not a point: $j');
  }

  @override
  bool operator ==(Object other) =>
      other is GeoPoint && other.lat == lat && other.lng == lng;

  @override
  int get hashCode => Object.hash(lat, lng);

  @override
  String toString() => 'GeoPoint($lat, $lng)';
}
