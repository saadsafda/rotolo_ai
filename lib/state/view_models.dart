import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/money.dart';
import '../core/time_format.dart';
import '../models/app_user.dart';
import '../models/payloads.dart';
import '../models/payment.dart';
import '../models/report.dart';
import '../models/sync_run.dart';
import '../ui/theme.dart';
import 'app_state.dart';

// Pure presentation logic shared by screens. Nothing here calculates an
// authoritative balance: amounts come from the backend in minor units and are
// only summed for display totals.

// ───────────── Dates in the business time zone ─────────────

DateTime businessDay(DateTime instant, String zone) {
  final l = inZone(instant, zone);
  return DateTime(l.year, l.month, l.day);
}

int daysBetween(DateTime from, DateTime to) =>
    DateTime.utc(to.year, to.month, to.day).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

String shortDate(DateTime d) => DateFormat('MMM d').format(d); // Nov 17
String dayLabel(DateTime d) => DateFormat('EEE, MMM d').format(d); // Tue, Nov 17
String longDay(DateTime d) => DateFormat('EEEE, MMM d, y').format(d); // Tuesday, Nov 17, 2026
String fullDate(DateTime d) => DateFormat('MMM d, y').format(d); // Nov 17, 2026

/// "7:02 AM ET" style time in the business zone.
String timeIn(DateTime? instant, String zone) {
  if (instant == null) return 'Not collected';
  final l = inZone(instant, zone);
  return '${DateFormat('h:mm a').format(l)} ${l.timeZoneName}';
}

/// "Today 7:02 AM EST", "Yesterday 4:12 PM EST" or "Nov 14, 9:41 AM EST".
String whenIn(DateTime? instant, DateTime now, String zone) {
  if (instant == null) return 'Not collected';
  final l = inZone(instant, zone);
  final diff = daysBetween(businessDay(instant, zone), businessDay(now, zone));
  final time = '${DateFormat('h:mm a').format(l)} ${l.timeZoneName}';
  if (diff == 0) return 'Today $time';
  if (diff == 1) return 'Yesterday $time';
  return '${DateFormat('MMM d').format(l)}, $time';
}

String hours(int? seconds) => seconds == null ? 'Unavailable' : '${(seconds / 3600).toStringAsFixed(1)} h';

// ───────────── Payments ─────────────

class PaymentLook {
  const PaymentLook(this.label, this.tone, this.icon, this.step);
  final String label;
  final Tone tone;
  final IconData icon;
  final int step; // 0..4 on the five-step tracker
}

PaymentLook paymentLook(PaymentStatus s) => switch (s) {
      PaymentStatus.submitted => const PaymentLook('Submitted', Tone.ac, Icons.outbox_rounded, 0),
      PaymentStatus.underReview => const PaymentLook('Under review', Tone.wa, Icons.rate_review_outlined, 1),
      PaymentStatus.approved => const PaymentLook('Approved · not posted', Tone.ac, Icons.task_alt_rounded, 2),
      PaymentStatus.rejected => const PaymentLook('Rejected', Tone.na, Icons.block_rounded, 2),
      PaymentStatus.posting => const PaymentLook('Posting to DoorLoop', Tone.ac, Icons.sync_rounded, 3),
      PaymentStatus.posted => const PaymentLook('Posted in DoorLoop', Tone.ok, Icons.check_circle_rounded, 4),
      PaymentStatus.failed => const PaymentLook('Posting failed', Tone.er, Icons.error_rounded, 4),
    };

bool needsReviewerAction(PaymentStatus s) =>
    s == PaymentStatus.submitted || s == PaymentStatus.underReview || s == PaymentStatus.approved || s == PaymentStatus.failed;

/// Short, readable form of a submission ID (live IDs are UUIDs).
String displayId(String id) => id.length > 16 ? 'PAY-${id.substring(0, 6).toUpperCase()}' : id;

String paymentWhere(PaymentDraft d) =>
    [d.propertyName ?? 'Unknown property', if (d.unit != null) 'Unit ${d.unit}'].join(' · ');

class DuplicateHint {
  const DuplicateHint(this.why, this.what);
  final String why;
  final String what;
}

/// Possible duplicates for a lease + amount: another live request, or a DoorLoop
/// payment of the same amount within a week. Warning only; the reviewer decides.
DuplicateHint? duplicateFor({
  required String leaseId,
  required int amountMinor,
  required DateTime? paymentDate,
  required List<PaymentSubmission> submissions,
  required RentPayload? rent,
  String? excludeId,
}) {
  final lease = leaseId.toLowerCase();
  for (final p in submissions) {
    if (p.id == excludeId || p.status == PaymentStatus.rejected) continue;
    if (p.draft.leaseId == lease && p.draft.amountMinor == amountMinor) {
      return DuplicateHint(
        'Same lease and amount as another outside-payment request.',
        '${displayId(p.id)} · ${Money(p.draft.amountMinor).format()} · ${p.draft.method.label} · ${paymentLook(p.status).label}',
      );
    }
  }
  for (final p in rent?.payments ?? const <LeasePayment>[]) {
    if (p.leaseId.toLowerCase() != lease || p.amount != amountMinor || p.classification == 'returned') continue;
    if (paymentDate != null && p.date != null && daysBetween(p.date!, paymentDate).abs() > 7) continue;
    final kind = p.classification == 'pending' ? 'pending' : p.classification == 'cleared' ? 'cleared' : 'unclassified';
    return DuplicateHint(
      'Same lease and amount as a $kind payment already in DoorLoop.',
      'DoorLoop $kind payment · ${Money(amountMinor).format()} · ${p.date == null ? 'date not returned' : fullDate(p.date!)}',
    );
  }
  return null;
}

// ───────────── Leases / balances ─────────────

class LeaseView {
  LeaseView(this.lease);
  final Lease lease;

  String get title => [lease.propertyName, if (lease.unit != null) lease.unit!].join(' · ');
  String get tenant => lease.tenants?.join(', ') ?? lease.leaseName;
  String get ref => lease.reference ?? lease.leaseId;

  /// The balance DoorLoop reports for the lease (API field), `null` when not returned.
  int? get balance => lease.apiBalance.totalDue;
  int? get pending => lease.ledger.pendingPayments;

  (String, Tone) get recon => switch (lease.ledger.status) {
        'matches_api' => ('Reconciled', Tone.ok),
        'mismatch_review' => ('Needs review', Tone.wa),
        _ => ('Not reconciled', Tone.na),
      };

  String get reason {
    if (lease.flags.contains('balance_fields_missing')) return 'DoorLoop returned no balance fields';
    if (lease.ledger.status == 'mismatch_review') return 'Reconciled ledger differs from DoorLoop balance';
    if ((lease.ledger.returnedPayments ?? 0) > 0) return 'Returned payment on ledger';
    if ((lease.apiBalance.overdue ?? 0) > 0) return '${Money(lease.apiBalance.overdue!).format()} overdue';
    if (!lease.isActive) return 'Lease inactive';
    return 'Current';
  }

  bool get needsReview =>
      (lease.apiBalance.overdue ?? 0) > 0 ||
      lease.ledger.status == 'mismatch_review' ||
      lease.flags.isNotEmpty ||
      (pending ?? 0) > 0 ||
      balance == null;
}

// ───────────── Tasks ─────────────

class TaskView {
  TaskView(this.task, this.review, this.today);
  final MaintenanceTask task;
  final TaskReview? review;
  final DateTime today;

  bool get verified => review?.status == 'verified_complete';
  bool get disputed => review?.status == 'disputed';
  bool get claimed => task.completionClaimed && !verified && !disputed;
  bool get overdue => task.isOverdue && !task.completionClaimed;
  int get overdueDays => task.dueDate == null ? 0 : daysBetween(task.dueDate!, today);

  String get where => [task.propertyName ?? 'Unknown property', ?task.unit].join(' · ');

  /// null = DoorLoop did not return assignees (not the same as nobody assigned).
  String get assignee => task.assignees == null
      ? 'Assignee not returned'
      : task.assignees!.isEmpty
          ? 'Unassigned'
          : task.assignees!.join(', ');

  (String, Tone) get status {
    if (verified) return ('Completion verified', Tone.ok);
    if (disputed) return ('Claim disputed', Tone.er);
    if (task.completionClaimed) return ('Completion claimed', Tone.wa);
    return switch (task.status) {
      'NOT_STARTED' => ('Open', Tone.na),
      'IN_PROGRESS' => ('In progress', Tone.ac),
      'WAITING_FOR_PARTS' => ('Waiting for parts', Tone.ac),
      _ => (task.status, Tone.na),
    };
  }

  (String, Tone) get priority => switch (task.priority) {
        'HIGH' => ('High', Tone.er),
        'MEDIUM' => ('Medium', Tone.wa),
        'LOW' => ('Low', Tone.na),
        _ => ('No priority', Tone.na),
      };

  String get dueLabel => task.dueDate == null ? 'No due date' : 'Due ${shortDate(task.dueDate!)}';
}

// ───────────── Deals ─────────────

class DealView {
  DealView(this.deal, this.evidence, this.review);
  final Deal deal;
  final EmailEvidencePayload? evidence;
  final EvidenceReview? review;

  DealEvidenceStatus? get evidenceStatus => evidence?.statusFor(deal.id);
  List<EvidenceItem> get items => evidence?.itemsFor(deal.id) ?? const [];

  bool get ambiguousEvidence =>
      evidenceStatus?.status == 'CORRESPONDENCE_VISIBLE_REVIEW' || items.any((i) => i.isAmbiguous);

  /// Evidence or CRM labels need a human look, and nobody has marked it reviewed.
  bool get needsReview => review == null && (ambiguousEvidence || deal.classification == 'closed_label_needs_review');

  bool get isClosedVerified => deal.classification == 'closed_by_system_flag';
  bool get isOpen => deal.classification == 'open';

  Tone get stageTone => switch (deal.classification) {
        'closed_by_system_flag' => Tone.ok,
        'cancelled' => Tone.na,
        'closed_label_needs_review' => Tone.wa,
        _ => Tone.ac,
      };

  String? get attention {
    if (needsReview) return 'Email evidence needs review';
    if (deal.flags.isNotEmpty) return deal.flags.first;
    return null;
  }

  String get client => deal.linkedPeople.isEmpty ? 'No linked contact' : deal.linkedPeople.map((p) => p.name).join(', ');
}

// ───────────── Source health ─────────────

class SourceHealth {
  SourceHealth(this.section, this.stale);
  final ReportSection section;
  final bool stale;

  SectionSource get source => section.source;
  String get name => switch (source) {
        SectionSource.aiSummary => 'OpenAI summary',
        SectionSource.fubDeals => 'Follow Up Boss',
        SectionSource.emailEvidence => 'Gmail',
        SectionSource.doorloopRent => 'DoorLoop rent',
        SectionSource.doorloopTasks => 'DoorLoop tasks',
        SectionSource.timeDoctor => 'Time Doctor',
      };

  IconData get icon => sourceIcon(source);

  (String, Tone) get status {
    if (section.status == 'unavailable') return ('Unavailable', Tone.er);
    if (stale) return ('Stale', Tone.wa);
    if (section.status == 'complete') return ('Connected', Tone.ok);
    return ('Partial', Tone.wa);
  }
}

IconData sourceIcon(SectionSource s) => switch (s) {
      SectionSource.aiSummary => Icons.auto_awesome_outlined,
      SectionSource.fubDeals => Icons.handshake_outlined,
      SectionSource.emailEvidence => Icons.mail_outline_rounded,
      SectionSource.doorloopRent => Icons.apartment_rounded,
      SectionSource.doorloopTasks => Icons.build_outlined,
      SectionSource.timeDoctor => Icons.timer_outlined,
    };

List<SourceHealth> sourceHealth(Report? report, DateTime now, int staleAfterHours) => [
      for (final s in report?.sections.values ?? const <ReportSection>[])
        SourceHealth(
          s,
          s.status != 'unavailable' &&
              (!(report?.isLatest ?? false) ||
                  s.collectedAt == null ||
                  now.difference(s.collectedAt!) > Duration(hours: staleAfterHours)),
        ),
    ];

// ───────────── Attention list ─────────────

class AttentionItem {
  const AttentionItem({required this.icon, required this.tone, required this.title, required this.detail, required this.cta, required this.route});
  final IconData icon;
  final Tone tone;
  final String title;
  final String detail;
  final String cta;
  final String route;
}

List<AttentionItem> attentionItems(Snapshot s, {required AppUser user, required DateTime now, required String zone}) {
  final items = <AttentionItem>[];
  final today = businessDay(now, zone);
  final rent = s.rent;

  for (final p in s.payments) {
    final open = p.status == PaymentStatus.submitted || p.status == PaymentStatus.underReview;
    if (!open) continue;
    final d = p.draft;
    final detail = '${displayId(p.id)} · ${Money(d.amountMinor).format()} ${d.method.label} · ${paymentWhere(d)}';
    if (user.canReviewPayments) {
      final dup = duplicateFor(
          leaseId: d.leaseId, amountMinor: d.amountMinor, paymentDate: d.paymentDate, submissions: s.payments, rent: rent, excludeId: p.id);
      items.add(AttentionItem(
        icon: dup != null ? Icons.content_copy_rounded : Icons.payments_outlined,
        tone: dup != null ? Tone.wa : Tone.ac,
        title: dup != null ? 'Possible duplicate payment' : 'Payment awaiting approval',
        detail: detail,
        cta: 'Review',
        route: '/payments/${p.id}',
      ));
    } else if (p.submittedBy == user.id) {
      items.add(AttentionItem(
          icon: Icons.outbox_rounded, tone: Tone.ac, title: 'Your submission is awaiting review', detail: detail, cta: 'View', route: '/payments/${p.id}'));
    }
  }

  for (final dv in dealViews(s)) {
    if (dv.needsReview) {
      items.add(AttentionItem(
        icon: Icons.mark_email_unread_outlined,
        tone: Tone.wa,
        title: 'Deal evidence needs review',
        detail: '${dv.deal.property} · email is ambiguous, FUB says ${dv.deal.stage}',
        cta: 'Review',
        route: '/more/deals/${dv.deal.id}',
      ));
    } else if (dv.isOpen && (dv.deal.daysToProjectedClose ?? 0) < 0) {
      items.add(AttentionItem(
        icon: Icons.event_busy_outlined,
        tone: Tone.wa,
        title: 'Projected close date passed',
        detail: '${dv.deal.property} · verify the stage in Follow Up Boss',
        cta: 'Open',
        route: '/more/deals/${dv.deal.id}',
      ));
    }
  }

  for (final l in rent?.leases ?? const <Lease>[]) {
    if (l.ledger.status == 'mismatch_review') {
      final v = LeaseView(l);
      items.add(AttentionItem(
          icon: Icons.account_balance_wallet_outlined,
          tone: Tone.wa,
          title: 'Balance needs review',
          detail: '${v.title} · ledger differs from DoorLoop',
          cta: 'Open',
          route: '/payments/balance/${l.leaseId}'));
    }
  }

  final tasks = taskViews(s, today);
  final overdue = tasks.where((t) => t.overdue).toList()..sort((a, b) => b.overdueDays.compareTo(a.overdueDays));
  if (overdue.isNotEmpty) {
    final o = overdue.first;
    items.add(AttentionItem(
      icon: Icons.build_outlined,
      tone: Tone.er,
      title: overdue.length == 1 ? '${o.task.subject} is ${o.overdueDays} days overdue' : '${overdue.length} maintenance tasks overdue',
      detail: overdue.length == 1 ? '${o.where} · ${o.assignee}' : 'Oldest: ${o.task.subject} · ${o.overdueDays} days',
      cta: 'Open',
      route: overdue.length == 1 ? '/tasks/${o.task.id}' : '/tasks?status=overdue',
    ));
  }
  for (final t in tasks.where((t) => t.claimed)) {
    items.add(AttentionItem(
        icon: Icons.task_alt_rounded,
        tone: Tone.wa,
        title: 'Contractor claimed completion',
        detail: '${t.task.subject} · ${t.where}',
        cta: 'Open',
        route: '/tasks/${t.task.id}'));
  }

  final staff = s.staff;
  final staffSection = s.latest?[SectionSource.timeDoctor];
  if (staff != null && staffSection != null && staffSection.status != 'complete') {
    final req = staffSection.coverage['users_requested'];
    final res = staffSection.coverage['users_resolved'];
    items.add(AttentionItem(
        icon: Icons.sync_problem_rounded,
        tone: Tone.wa,
        title: 'Team hours incomplete',
        detail: req is int && res is int ? 'Time Doctor returned $res of $req users' : 'Time Doctor coverage is partial',
        cta: 'View',
        route: '/more/team'));
  }
  return items;
}

List<TaskView> taskViews(Snapshot s, DateTime today) =>
    [for (final t in s.tasks?.tasks ?? const <MaintenanceTask>[]) TaskView(t, s.taskReviews[t.id], today)];

List<DealView> dealViews(Snapshot s) {
  final ev = s.evidence;
  return [for (final d in s.deals?.deals ?? const <Deal>[]) DealView(d, ev, s.evidenceReviews[d.id])];
}

// ───────────── Notifications (derived feed; push delivery arrives with FCM) ─────────────

class AppNotification {
  const AppNotification({
    required this.id,
    required this.category,
    required this.icon,
    required this.tone,
    required this.title,
    required this.body,
    required this.at,
    required this.route,
  });
  final String id;
  final String category; // Reports | Payments | Tasks | Sync
  final IconData icon;
  final Tone tone;
  final String title;
  final String body;
  final DateTime at;
  final String route;
}

List<AppNotification> buildNotifications(Snapshot s, {required AppUser user, required DateTime now, required String zone}) {
  final out = <AppNotification>[];
  final today = businessDay(now, zone);

  for (final r in s.reports) {
    final gaps = [
      for (final sec in r.sections.values)
        if (sec.status != 'complete') '${SourceHealth(sec, false).name} ${sec.status}',
    ];
    final tag = r.summary.status == 'complete' ? '' : ' (${r.summary.status})';
    out.add(AppNotification(
      id: 'rpt-${r.summary.id}',
      category: 'Reports',
      icon: Icons.summarize_outlined,
      tone: r.summary.status == 'complete' ? Tone.ac : r.summary.status == 'failed' ? Tone.er : Tone.wa,
      title: 'Daily report for ${shortDate(r.summary.businessDate)} is ready$tag',
      body: gaps.isEmpty ? 'All sources complete.' : '${gaps.join(', ')}.',
      at: r.summary.generatedAt,
      route: '/reports/${r.summary.id}',
    ));
  }

  final latest = s.latest;
  if (latest != null) {
    for (final sec in latest.sections.values) {
      if (sec.status == 'complete') continue;
      final name = SourceHealth(sec, false).name;
      out.add(AppNotification(
        id: 'sync-${latest.summary.id}-${sec.source.key}',
        category: 'Sync',
        icon: sec.status == 'unavailable' ? Icons.error_outline_rounded : Icons.sync_problem_rounded,
        tone: sec.status == 'unavailable' ? Tone.er : Tone.wa,
        title: sec.status == 'unavailable' ? '$name unavailable' : '$name sync incomplete',
        body: sec.warnings.isEmpty ? 'Coverage is partial.' : sec.warnings.first.message,
        at: sec.collectedAt ?? latest.summary.generatedAt,
        route: user.isOwnerOrAdmin ? '/more/integrations' : '/reports/${latest.summary.id}',
      ));
    }
  }

  for (final p in s.payments) {
    final d = p.draft;
    final amt = Money(d.amountMinor).format();
    if (user.canReviewPayments && (p.status == PaymentStatus.submitted || p.status == PaymentStatus.underReview)) {
      final dup = duplicateFor(
          leaseId: d.leaseId, amountMinor: d.amountMinor, paymentDate: d.paymentDate, submissions: s.payments, rent: s.rent, excludeId: p.id);
      out.add(AppNotification(
        id: 'pay-${p.id}-${p.status.key}',
        category: 'Payments',
        icon: dup != null ? Icons.content_copy_rounded : Icons.outbox_rounded,
        tone: dup != null ? Tone.wa : Tone.ac,
        title: dup != null ? 'Possible duplicate on ${displayId(p.id)}' : 'New outside payment ${displayId(p.id)}',
        body: '$amt ${d.method.label} · ${paymentWhere(d)} · submitted by ${p.submittedByName}',
        at: p.createdAt,
        route: '/payments/${p.id}',
      ));
    } else if (!user.canReviewPayments && p.submittedBy == user.id && p.status != PaymentStatus.submitted) {
      out.add(AppNotification(
        id: 'pay-${p.id}-${p.status.key}',
        category: 'Payments',
        icon: paymentLook(p.status).icon,
        tone: paymentLook(p.status).tone,
        title: '${displayId(p.id)}: ${paymentLook(p.status).label}',
        body: '$amt ${d.method.label} · ${paymentWhere(d)}',
        at: p.events.last.at,
        route: '/payments/${p.id}',
      ));
    }
  }

  final tasksAt = latest?[SectionSource.doorloopTasks]?.collectedAt ?? latest?.summary.generatedAt ?? now;
  for (final t in taskViews(s, today)) {
    if (t.claimed) {
      out.add(AppNotification(
        id: 'task-claim-${t.task.id}',
        category: 'Tasks',
        icon: Icons.task_alt_rounded,
        tone: Tone.ac,
        title: 'Completion claimed: ${t.task.subject}',
        body: '${t.where} · ${t.assignee}',
        at: t.task.updatedAt ?? tasksAt,
        route: '/tasks/${t.task.id}',
      ));
    } else if (t.overdue) {
      out.add(AppNotification(
        id: 'task-overdue-${t.task.id}',
        category: 'Tasks',
        icon: Icons.schedule_rounded,
        tone: Tone.er,
        title: '${t.task.subject} is overdue',
        body: '${t.where} · ${t.overdueDays} days past due',
        at: tasksAt,
        route: '/tasks/${t.task.id}',
      ));
    }
  }

  out.sort((a, b) => b.at.compareTo(a.at));
  return out;
}

String notificationGroup(DateTime at, DateTime now, String zone) {
  final d = daysBetween(businessDay(at, zone), businessDay(now, zone));
  return d <= 0 ? 'Today' : d == 1 ? 'Yesterday' : 'Earlier';
}
