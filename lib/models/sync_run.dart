import 'json.dart';

enum SyncStatus { queued, running, succeeded, partial, failed, timedOut }

extension SyncStatusText on SyncStatus {
  bool get isActive => this == SyncStatus.queued || this == SyncStatus.running;
  String get label => switch (this) {
        SyncStatus.queued => 'Queued',
        SyncStatus.running => 'Running',
        SyncStatus.succeeded => 'Complete',
        SyncStatus.partial => 'Complete with gaps',
        SyncStatus.failed => 'Failed',
        SyncStatus.timedOut => 'Timed out',
      };
}

class SyncStage {
  const SyncStage({required this.stage, required this.status, required this.at, this.detail});
  final String stage; // fub | email | doorloop | time_doctor | summary | store
  final String status; // running | ok | partial | failed
  final DateTime at;
  final String? detail;
}

class SyncRun {
  const SyncRun({
    required this.id,
    required this.status,
    required this.progress,
    required this.dataMode,
    this.reportId,
    this.error,
  });

  factory SyncRun.fromJson(Json row) => SyncRun(
        id: row['id'] as String,
        status: switch (row['status']) {
          'queued' => SyncStatus.queued,
          'running' => SyncStatus.running,
          'succeeded' => SyncStatus.succeeded,
          'partial' => SyncStatus.partial,
          'timed_out' => SyncStatus.timedOut,
          _ => SyncStatus.failed,
        },
        progress: [
          for (final stage in asMapList(row['progress']))
            if (asDateTime(stage['at']) case final at?)
              SyncStage(
                stage: asString(stage['stage']) ?? '',
                status: asString(stage['status']) ?? '',
                at: at,
                detail: asString(stage['detail']),
              ),
        ],
        dataMode: row['data_mode'] as String,
        reportId: asString(row['report_id']),
        error: asString(row['error']),
      );

  final String id;
  final SyncStatus status;
  final List<SyncStage> progress;
  final String dataMode;
  final String? reportId;
  final String? error;
}

class TaskReview {
  const TaskReview({required this.taskId, required this.status, this.notes, this.reviewer, this.at});
  final String taskId;
  final String status; // not_reviewed | claimed_complete | verified_complete | disputed
  final String? notes;
  final String? reviewer;
  final DateTime? at;

  String get label => switch (status) {
        'claimed_complete' => 'Completion claimed, not verified',
        'verified_complete' => 'Independently verified complete',
        'disputed' => 'Completion disputed',
        _ => 'Not reviewed',
      };
}

/// A human "evidence reviewed" mark on a deal. It never changes the CRM stage.
class EvidenceReview {
  const EvidenceReview({required this.dealId, required this.reviewer, required this.at});
  final int dealId;
  final String reviewer;
  final DateTime at;
}
