import 'package:intl/intl.dart';
import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

bool _initialised = false;

void initTimeZones() {
  if (_initialised) return;
  tzdata.initializeTimeZones();
  _initialised = true;
}

tz.TZDateTime inZone(DateTime instant, String zone) {
  initTimeZones();
  return tz.TZDateTime.from(instant.toUtc(), tz.getLocation(zone));
}

/// "9:01 AM EST, Wed 18 Nov"
String formatInstant(DateTime? instant, String zone) {
  if (instant == null) return 'Not collected';
  final local = inZone(instant, zone);
  return '${DateFormat('h:mm a').format(local)} ${local.timeZoneName}, ${DateFormat('EEE d MMM').format(local)}';
}

/// "Wed 18 Nov 2026"
String formatDate(DateTime date) => DateFormat('EEE d MMM y').format(date);

String formatDuration(int? seconds) {
  if (seconds == null) return 'Not returned';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  return '${h}h ${m.toString().padLeft(2, '0')}m';
}
