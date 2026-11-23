/// Labels that tell the user how much to trust a section.
/// Ordered by severity; `live` only appears when nothing else applies.
enum QualityFlag { synthetic, unavailable, incomplete, stale, historical, live }

extension QualityFlagText on QualityFlag {
  String get label => switch (this) {
        QualityFlag.synthetic => 'SYNTHETIC',
        QualityFlag.unavailable => 'UNAVAILABLE',
        QualityFlag.incomplete => 'INCOMPLETE',
        QualityFlag.stale => 'STALE',
        QualityFlag.historical => 'HISTORICAL',
        QualityFlag.live => 'LIVE',
      };

  String get explanation => switch (this) {
        QualityFlag.synthetic => 'Invented test data. Not real records.',
        QualityFlag.unavailable => 'The source could not be collected for this report.',
        QualityFlag.incomplete => 'Only part of the source was collected. Absence of a record proves nothing.',
        QualityFlag.stale => 'Older than the freshness limit. Refresh before acting on it.',
        QualityFlag.historical => 'From an earlier report. Newer data exists.',
        QualityFlag.live => 'Collected from the live source and passed completeness checks.',
      };
}

/// Fail-safe classification: unknown modes/statuses are never treated as live/complete.
List<QualityFlag> qualityFlags({
  required String dataMode,
  required String status,
  required DateTime? collectedAt,
  required DateTime now,
  required int staleAfterHours,
  required bool isLatest,
}) {
  final flags = <QualityFlag>[];
  if (dataMode != 'live') flags.add(QualityFlag.synthetic);
  switch (status) {
    case 'complete':
      break;
    case 'unavailable':
      flags.add(QualityFlag.unavailable);
    default:
      flags.add(QualityFlag.incomplete);
  }
  if (!isLatest) {
    flags.add(QualityFlag.historical);
  } else if (status != 'unavailable' &&
      (collectedAt == null || now.difference(collectedAt) > Duration(hours: staleAfterHours))) {
    flags.add(QualityFlag.stale);
  }
  if (flags.isEmpty) flags.add(QualityFlag.live);
  return flags;
}
