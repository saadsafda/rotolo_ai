final _safeId = RegExp(r'^[A-Za-z0-9-]{1,64}$');

/// Maps an FCM data payload to an in-app route. Only known message types with
/// well-formed IDs are routed; anything else opens nothing.
String? routeForNotification(Map<String, dynamic> data) {
  final type = data['type'];
  final id = data['report_id'];
  if (type == 'report_ready' && id is String && _safeId.hasMatch(id)) {
    return '/reports/$id';
  }
  return null;
}
