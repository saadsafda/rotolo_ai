import 'json.dart';

enum SectionSource {
  aiSummary('ai_summary', 'AI summary', 'OpenAI'),
  fubDeals('fub_deals', 'Deals', 'Follow Up Boss'),
  emailEvidence('email_evidence', 'Email evidence', 'Gmail (Harry mailbox)'),
  doorloopRent('doorloop_rent', 'Rent & payments', 'DoorLoop'),
  doorloopTasks('doorloop_tasks', 'Maintenance tasks', 'DoorLoop'),
  timeDoctor('time_doctor', 'Staff activity', 'Time Doctor');

  const SectionSource(this.key, this.title, this.system);
  final String key;
  final String title;
  final String system;

  static SectionSource? fromKey(String? key) {
    for (final s in values) {
      if (s.key == key) return s;
    }
    return null;
  }
}

class Cutoff {
  const Cutoff({required this.kind, this.asOf, this.date, this.timezone, this.days});

  final String kind; // snapshot | business_day | lookback
  final DateTime? asOf;
  final DateTime? date;
  final String? timezone;
  final int? days;

  factory Cutoff.fromJson(Json j) => Cutoff(
        kind: asString(j['kind']) ?? 'unknown',
        asOf: asDateTime(j['as_of']),
        date: asDate(j['date']),
        timezone: asString(j['timezone']),
        days: asInt(j['days']),
      );
}

class SectionWarning {
  const SectionWarning({required this.code, required this.severity, required this.message});

  final String code;
  final String severity; // review | info | error
  final String message;

  factory SectionWarning.fromJson(Json j) => SectionWarning(
        code: asString(j['code']) ?? 'UNKNOWN',
        severity: asString(j['severity']) ?? 'review',
        message: asString(j['message']) ?? '',
      );
}

class ReportSection {
  const ReportSection({
    required this.source,
    required this.status,
    required this.dataMode,
    required this.collectedAt,
    required this.cutoff,
    required this.coverage,
    required this.warnings,
    required this.payload,
    this.workflowId,
    this.executionId,
  });

  final SectionSource source;
  final String status;
  final String dataMode;
  final DateTime? collectedAt;
  final Cutoff cutoff;
  final Json coverage;
  final List<SectionWarning> warnings;
  final Json payload;
  final String? workflowId;
  final String? executionId;

  bool get isAvailable => status != 'unavailable';

  static ReportSection? tryParse(Json j) {
    final source = SectionSource.fromKey(asString(j['source']));
    if (source == null) return null;
    final workflow = asMap(j['workflow']);
    return ReportSection(
      source: source,
      status: asString(j['status']) ?? 'unavailable',
      dataMode: asString(j['data_mode']) ?? 'unknown',
      collectedAt: asDateTime(j['collected_at']),
      cutoff: Cutoff.fromJson(asMap(j['cutoff'])),
      coverage: asMap(j['coverage']),
      warnings: asMapList(j['warnings']).map(SectionWarning.fromJson).toList(),
      payload: asMap(j['payload']),
      workflowId: asString(workflow['id']),
      executionId: asString(workflow['execution_id']),
    );
  }
}

class ReportSummary {
  const ReportSummary({
    required this.id,
    required this.reportKey,
    required this.businessDate,
    required this.timezone,
    required this.dataMode,
    required this.status,
    required this.generatedAt,
  });

  final String id;
  final String reportKey;
  final DateTime businessDate;
  final String timezone;
  final String dataMode;
  final String status; // complete | partial | failed
  final DateTime generatedAt;
}

class Report {
  const Report({required this.summary, required this.sections, required this.isLatest});

  final ReportSummary summary;
  final Map<SectionSource, ReportSection> sections;
  final bool isLatest;

  ReportSection? operator [](SectionSource s) => sections[s];

  static Report fromJson(Json j, {required bool isLatest}) {
    final sections = <SectionSource, ReportSection>{};
    for (final s in asMapList(j['sections'])) {
      final parsed = ReportSection.tryParse(s);
      if (parsed != null) sections[parsed.source] = parsed;
    }
    return Report(
      summary: ReportSummary(
        id: asString(j['id'])!,
        reportKey: asString(j['report_key']) ?? '',
        businessDate: asDate(j['business_date'])!,
        timezone: asString(j['timezone']) ?? 'America/New_York',
        dataMode: asString(j['data_mode']) ?? 'unknown',
        status: asString(j['status']) ?? 'failed',
        generatedAt: asDateTime(j['generated_at'])!,
      ),
      sections: sections,
      isLatest: isLatest,
    );
  }
}
