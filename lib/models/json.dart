/// Defensive JSON readers. Malformed values become null rather than throwing or
/// being coerced to zero, so the UI can show "Not returned".
typedef Json = Map<String, dynamic>;

Json asMap(Object? v) => v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};

List<Json> asMapList(Object? v) =>
    v is List ? v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList() : const [];

List<String> asStringList(Object? v) =>
    v is List ? v.where((e) => e != null).map((e) => e.toString()).toList() : const [];

String? asString(Object? v) => v?.toString();

/// Integers only. A fractional number is rejected (money must arrive in minor units).
int? asInt(Object? v) {
  if (v is int) return v;
  if (v is double && v == v.roundToDouble() && v.isFinite) return v.toInt();
  return null;
}

bool? asBool(Object? v) => v is bool ? v : null;

DateTime? asDateTime(Object? v) => v is String ? DateTime.tryParse(v) : null;

DateTime? asDate(Object? v) {
  if (v is! String) return null;
  final d = DateTime.tryParse(v);
  return d == null ? null : DateTime(d.year, d.month, d.day);
}
