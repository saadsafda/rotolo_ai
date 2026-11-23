import 'json.dart';

// Typed read-only views over section payloads (contract v1.0).

// ───────────── AI summary ─────────────
class AiSummary {
  AiSummary(Json j)
      : text = asString(j['text']),
        model = asString(j['model']),
        status = asString(j['status']) ?? 'unavailable';
  final String? text;
  final String? model;
  final String status; // ok | unavailable | rejected_by_guard
}

// ───────────── Deals ─────────────
class LinkedPerson {
  LinkedPerson(Json j)
      : id = asInt(j['id']),
        name = asString(j['name']) ?? 'Unknown contact',
        url = asString(j['url']);
  final int? id;
  final String name;
  final String? url;
}

class Communication {
  Communication(Json j)
      : date = asDateTime(j['date']),
        type = asString(j['type']),
        direction = asString(j['direction']),
        personName = asString(j['person_name']);
  final DateTime? date;
  final String? type;
  final String? direction;
  final String? personName;
}

class Deal {
  Deal(Json j)
      : id = asInt(j['deal_id']) ?? -1,
        property = asString(j['property']) ?? 'Unnamed deal',
        pipeline = asString(j['pipeline']) ?? 'Unknown pipeline',
        stage = asString(j['stage']) ?? 'Unknown stage',
        classification = asString(j['classification']) ?? 'review',
        projectedCloseDate = asDate(j['projected_close_date']),
        daysToProjectedClose = asInt(j['days_to_projected_close']),
        daysInStage = asInt(j['days_in_stage']),
        assignedUsers = asStringList(j['assigned_users']),
        flags = asStringList(j['flags']),
        fubUrl = asString(j['fub_url']),
        linkedPeople = asMapList(j['linked_people']).map(LinkedPerson.new).toList(),
        latestCommunication = j['latest_linked_communication'] is Map
            ? Communication(asMap(j['latest_linked_communication']))
            : null;

  final int id;
  final String property;
  final String pipeline;
  final String stage;
  final String classification;
  final DateTime? projectedCloseDate;
  final int? daysToProjectedClose;
  final int? daysInStage;
  final List<String> assignedUsers;
  final List<String> flags;
  final String? fubUrl;
  final List<LinkedPerson> linkedPeople;
  final Communication? latestCommunication;

  String get classificationLabel => switch (classification) {
        'open' => 'Open',
        'closed_by_system_flag' => 'Closed (CRM flag)',
        'closed_label_needs_review' => 'Closed label · review',
        'cancelled' => 'Cancelled',
        _ => 'Review',
      };
}

class DealsPayload {
  DealsPayload(Json j)
      : deals = asMapList(j['deals']).map(Deal.new).toList(),
        counts = asMap(j['counts']),
        pipelineOrder = asMapList(j['pipelines']).map((p) => asString(p['name']) ?? '').toList(),
        stageOrder = {
          for (final p in asMapList(j['pipelines']))
            asString(p['name']) ?? '': asMapList(p['stages']).map((s) => asString(s['name']) ?? '').toList()
        };

  final List<Deal> deals;
  final Json counts;
  final List<String> pipelineOrder;
  final Map<String, List<String>> stageOrder;

  int? count(String key) => asInt(counts[key]);
}

// ───────────── Email evidence ─────────────
class EvidenceItem {
  EvidenceItem(Json j)
      : messageId = asString(j['message_id']) ?? '',
        threadId = asString(j['thread_id']),
        date = asDateTime(j['date']),
        from = asString(j['from']) ?? '',
        to = asStringList(j['to']),
        subject = asString(j['subject']) ?? '(no subject)',
        excerpt = asString(j['excerpt']) ?? '',
        kind = asString(j['kind']) ?? 'CORRESPONDENCE_REVIEW',
        dealId = asInt(j['deal_id']),
        mapping = asString(j['mapping']) ?? 'UNMATCHED',
        sourceUrl = asString(j['source_url']);

  final String messageId;
  final String? threadId;
  final DateTime? date;
  final String from;
  final List<String> to;
  final String subject;

  /// Untrusted vendor/email text. Display as plain text only.
  final String excerpt;
  final String kind;
  final int? dealId;
  final String mapping;
  final String? sourceUrl;

  bool get isAmbiguous => mapping != 'UNIQUE_PROPERTY_DEAL';
}

class DealEvidenceStatus {
  DealEvidenceStatus(Json j)
      : dealId = asInt(j['deal_id']),
        status = asString(j['status']) ?? 'NO_MATCHED_EVIDENCE_IN_SCOPE',
        messageCount = asInt(j['message_count']),
        latestMessageId = asString(j['latest_message_id']),
        verifiedReplyMessageId = asString(j['verified_reply_message_id']);

  final int? dealId;
  final String status;
  final int? messageCount;
  final String? latestMessageId;
  final String? verifiedReplyMessageId;

  String get label => switch (status) {
        'ATTORNEY_REPLY_VERIFIED' => 'Attorney reply in thread',
        'VA_OUTREACH_VISIBLE' => 'VA outreach visible',
        'CORRESPONDENCE_VISIBLE_REVIEW' => 'Correspondence · review',
        _ => 'No matched evidence in scope',
      };
}

class UnmatchedEmail {
  UnmatchedEmail(Json j)
      : messageId = asString(j['message_id']) ?? '',
        subject = asString(j['subject']) ?? '(no subject)',
        date = asDateTime(j['date']),
        reason = asString(j['reason']) ?? '';
  final String messageId;
  final String subject;
  final DateTime? date;
  final String reason;
}

class EmailEvidencePayload {
  EmailEvidencePayload(Json j)
      : mailbox = asString(j['mailbox']),
        mailboxVerified = asBool(j['mailbox_verified']) ?? false,
        items = asMapList(j['items']).map(EvidenceItem.new).toList(),
        dealStatus = asMapList(j['deal_status']).map(DealEvidenceStatus.new).toList(),
        unmatched = asMapList(j['unmatched']).map(UnmatchedEmail.new).toList();

  final String? mailbox;
  final bool mailboxVerified;
  final List<EvidenceItem> items;
  final List<DealEvidenceStatus> dealStatus;
  final List<UnmatchedEmail> unmatched;

  DealEvidenceStatus? statusFor(int dealId) {
    for (final s in dealStatus) {
      if (s.dealId == dealId) return s;
    }
    return null;
  }

  /// Evidence for a deal: direct matches plus ambiguous messages referenced by its status row.
  List<EvidenceItem> itemsFor(int dealId) {
    final status = statusFor(dealId);
    final ids = {status?.latestMessageId, status?.verifiedReplyMessageId}..remove(null);
    return items.where((i) => i.dealId == dealId || ids.contains(i.messageId)).toList()
      ..sort((a, b) => (b.date ?? DateTime(0)).compareTo(a.date ?? DateTime(0)));
  }
}

// ───────────── Rent ─────────────
class ApiBalance {
  ApiBalance(Json j)
      : totalDue = asInt(j['total_due_minor']),
        overdue = asInt(j['overdue_minor']),
        current = asInt(j['current_minor']),
        upcoming = asInt(j['upcoming_minor']);
  final int? totalDue;
  final int? overdue;
  final int? current;
  final int? upcoming;
}

class Ledger {
  Ledger(Json j)
      : charges = asInt(j['charges_minor']),
        clearedPayments = asInt(j['cleared_payments_minor']),
        pendingPayments = asInt(j['pending_payments_minor']),
        appliedCredits = asInt(j['applied_credits_minor']),
        returnedPayments = asInt(j['returned_payments_minor']),
        reconciledBalance = asInt(j['reconciled_balance_minor']),
        status = asString(j['status']) ?? 'not_computed';
  final int? charges;
  final int? clearedPayments;
  final int? pendingPayments;
  final int? appliedCredits;
  final int? returnedPayments;
  final int? reconciledBalance;
  final String status; // not_computed | matches_api | mismatch_review

  String get statusLabel => switch (status) {
        'matches_api' => 'Reconciled · matches DoorLoop',
        'mismatch_review' => 'Reconciled · differs from DoorLoop, review',
        _ => 'Reconciled ledger not computed yet',
      };
}

class Lease {
  Lease(Json j)
      : leaseId = asString(j['lease_id']) ?? '',
        reference = asString(j['reference']),
        propertyId = asString(j['property_id']),
        propertyName = asString(j['property_name']) ?? 'Unknown property',
        unit = asString(j['unit']),
        leaseName = asString(j['lease_name']) ?? 'Unnamed lease',
        tenants = j['tenants'] == null ? null : asStringList(j['tenants']),
        status = asString(j['status']) ?? 'UNKNOWN',
        collectionStatus = asString(j['collection_status']),
        apiBalance = ApiBalance(asMap(j['api_balance'])),
        ledger = Ledger(asMap(j['ledger'])),
        flags = asStringList(j['flags']);

  final String leaseId;
  final String? reference;
  final String? propertyId;
  final String propertyName;
  final String? unit;
  final String leaseName;
  final List<String>? tenants;
  final String status;
  final String? collectionStatus;
  final ApiBalance apiBalance;
  final Ledger ledger;
  final List<String> flags;

  bool get isActive => status == 'ACTIVE';
  bool get hasOverdue => (apiBalance.overdue ?? 0) > 0;
}

class LeasePayment {
  LeasePayment(Json j)
      : paymentId = asString(j['payment_id']) ?? '',
        leaseId = asString(j['lease_id']) ?? '',
        date = asDate(j['date']),
        amount = asInt(j['amount_minor']),
        depositStatus = asString(j['deposit_status']),
        returnedLinked = asBool(j['returned_linked']) ?? false,
        classification = asString(j['classification']) ?? 'unclassified';
  final String paymentId;
  final String leaseId;
  final DateTime? date;
  final int? amount;
  final String? depositStatus;
  final bool returnedLinked;
  final String classification; // cleared | pending | returned | unclassified
}

class RentPayload {
  RentPayload(Json j)
      : currency = asString(j['currency']) ?? 'USD',
        leases = asMapList(j['leases']).map(Lease.new).toList(),
        payments = asMapList(j['payments']).map(LeasePayment.new).toList(),
        promisesStatus = asString(asMap(j['promises'])['status']) ?? 'not_connected';
  final String currency;
  final List<Lease> leases;
  final List<LeasePayment> payments;
  final String promisesStatus;
}

// ───────────── Tasks ─────────────
class MaintenanceTask {
  MaintenanceTask(Json j)
      : id = asString(j['task_id']) ?? '',
        subject = asString(j['subject']) ?? 'Untitled task',
        type = asString(j['type']),
        status = asString(j['status']) ?? 'UNKNOWN',
        priority = asString(j['priority']),
        propertyName = asString(j['property_name']),
        unit = asString(j['unit']),
        dueDate = asDate(j['due_date']),
        assignees = j['assignees'] == null ? null : asStringList(j['assignees']),
        updatedAt = asDateTime(j['updated_at']),
        isOverdue = asBool(j['is_overdue']) ?? false,
        completionClaimed = asBool(asMap(j['completion_claim'])['claimed']) ?? false;

  final String id;
  final String subject;
  final String? type;
  final String status;
  final String? priority;
  final String? propertyName;
  final String? unit;
  final DateTime? dueDate;
  final List<String>? assignees;
  final DateTime? updatedAt;
  final bool isOverdue;

  /// DoorLoop status says done. This is a claim, not independent verification.
  final bool completionClaimed;
}

class TasksPayload {
  TasksPayload(Json j)
      : tasks = asMapList(j['tasks']).map(MaintenanceTask.new).toList(),
        excludedReminders = asInt(asMap(j['excluded'])['rent_reminder_tasks']);
  final List<MaintenanceTask> tasks;
  final int? excludedReminders;
}

// ───────────── Staff activity ─────────────
class StaffUserActivity {
  StaffUserActivity(Json j)
      : userId = asString(j['user_id']),
        name = asString(j['name']) ?? 'Unknown user',
        trackedSec = asInt(j['tracked_sec']),
        activeSec = asInt(j['active_sec']),
        idleSec = asInt(j['idle_sec']),
        wholeIdleMinutes = asInt(j['whole_idle_minutes']),
        meetingSec = asInt(j['meeting_sec']),
        unavailableMetrics = asStringList(j['unavailable_metrics']);
  final String? userId;
  final String name;
  final int? trackedSec;
  final int? activeSec;
  final int? idleSec;
  final int? wholeIdleMinutes;
  final int? meetingSec;
  final List<String> unavailableMetrics;
}

class ActivityGap {
  ActivityGap(Json j)
      : userId = asString(j['user_id']),
        start = asDateTime(j['start']),
        end = asDateTime(j['end']),
        approxMinutes = asInt(j['approx_minutes']),
        interpretation = asString(j['interpretation']) ?? '';
  final String? userId;
  final DateTime? start;
  final DateTime? end;
  final int? approxMinutes;
  final String interpretation;
}

class MissingStaff {
  MissingStaff(Json j)
      : name = asString(j['name']) ?? 'Unknown',
        reason = asString(j['reason']) ?? '';
  final String name;
  final String reason;
}

class StaffActivityPayload {
  StaffActivityPayload(Json j)
      : workDate = asDate(j['work_date']),
        noActivity = j['activity_status'] == 'no_activity',
        _teamTrackedSec = asInt(asMap(j['team_total'])['tracked_sec']),
        users = asMapList(j['users']).map(StaffUserActivity.new).toList(),
        missing = asMapList(asMap(j['scope'])['missing']).map(MissingStaff.new).toList(),
        gaps = asMapList(j['gaps']).map(ActivityGap.new).toList(),
        metricAvailability = asMap(j['metric_availability']),
        reconciled = asBool(asMap(j['validation'])['user_team_reconciled']);
  final DateTime? workDate;
  final bool noActivity;
  final int? _teamTrackedSec;
  final List<StaffUserActivity> users;
  final List<MissingStaff> missing;
  final List<ActivityGap> gaps;
  final Json metricAvailability;
  final bool? reconciled;

  int? get trackedSec {
    if (_teamTrackedSec != null) return _teamTrackedSec;
    // Older reports may only contain per-user totals.
    if (users.isEmpty || users.any((user) => user.trackedSec == null)) return null;
    return users.fold<int>(0, (total, user) => total + user.trackedSec!);
  }
}
