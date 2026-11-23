import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:timezone/timezone.dart' as tz;

import '../core/time_format.dart';
import '../models/app_user.dart';
import '../models/assistant.dart';
import '../models/json.dart';
import '../models/payment.dart';
import '../models/report.dart';
import '../models/sync_run.dart';
import 'ops_repository.dart';

final _leasePattern = RegExp(r'^[a-f0-9]{24}$');
final _referencePattern = RegExp(r'^[A-Z0-9._/-]{3,100}$');
const _maxPaymentMinor = 5000000; // $50,000, matches workflow 02 and the DB check

/// In-memory backend over bundled fixtures. Every value it returns is synthetic.
class SyntheticRepository implements OpsRepository {
  SyntheticRepository({
    required String fixtureJson,
    required AppUser? Function() currentUser,
    DateTime Function()? now,
    this.stageDelay = const Duration(milliseconds: 700),
  })  : _currentUser = currentUser,
        _now = now ?? DateTime.now {
    final root = asMap(jsonDecode(fixtureJson));
    _reports = asMapList(root['reports']);
    for (final r in _reports) {
      if (r['data_mode'] != 'synthetic') {
        throw StateError('Synthetic repository refuses non-synthetic fixture ${r['id']}');
      }
    }
    _seedPayments();
  }

  final AppUser? Function() _currentUser;
  final DateTime Function() _now;
  final Duration stageDelay;

  late List<Json> _reports;
  final _payments = <PaymentSubmission>[];
  final _taskReviews = <String, TaskReview>{};
  final _evidenceReviews = <int, EvidenceReview>{};

  /// Demo accounts only. There are no real credentials in the app.
  static const demoPassword = 'demo';
  SyncRun? _activeRun;
  int _seq = 0;

  static final users = <AppUser>[
    AppUser(
        id: 'demo-owner',
        displayName: 'Harry Rotolo',
        email: 'harry@demo.example',
        role: AppRole.owner,
        canSubmitPayments: true,
        canReviewPayments: true,
        readableSources: defaultSourcesFor(AppRole.owner)),
    AppUser(
        id: 'demo-admin',
        displayName: 'Priya Shah',
        email: 'priya@demo.example',
        role: AppRole.admin,
        canSubmitPayments: true,
        canReviewPayments: false,
        readableSources: defaultSourcesFor(AppRole.admin)),
    AppUser(
        id: 'demo-staff',
        displayName: 'Marcus Diaz',
        email: 'marcus@demo.example',
        role: AppRole.staff,
        canSubmitPayments: false,
        canReviewPayments: false,
        readableSources: defaultSourcesFor(AppRole.staff)),
  ];

  @override
  bool get isSynthetic => true;
  @override
  String get businessTimezone => 'America/New_York';
  @override
  int get staleAfterHours => 26;
  @override
  bool get doorloopPostingEnabled => false;
  @override
  List<AppUser> get demoUsers => users;

  @override
  Future<AppUser> signIn(String email, String password) async {
    await Future<void>.delayed(stageDelay ~/ 2);
    final match = users.where((u) => u.email.toLowerCase() == email.trim().toLowerCase());
    if (match.isEmpty || password != demoPassword) {
      throw const AuthFailure('Email or password is incorrect.');
    }
    return match.first;
  }

  @override
  Future<AppUser?> restoreSession() async => null;

  @override
  Future<void> signOut() async {}

  AppUser _requireUser() {
    final u = _currentUser();
    if (u == null) throw const PaymentRuleException('Sign in required');
    return u;
  }

  List<Json> get _sortedReports => [..._reports]
    ..sort((a, b) => asString(b['generated_at'])!.compareTo(asString(a['generated_at'])!));

  @override
  Future<void> requestPasswordReset(String email) async {}

  @override
  Future<void> finishPasswordReset(String password) async => throw const AuthFailure('Password changes require a live account.');

  @override
  Future<List<ReportSummary>> listReports() async {
    _requireUser();
    final sorted = _sortedReports;
    return [for (var i = 0; i < sorted.length; i++) Report.fromJson(sorted[i], isLatest: i == 0).summary];
  }

  @override
  Future<List<Report>> listReportDetails() async =>
      [for (final report in await listReports()) await getReport(report.id)];

  @override
  Future<Report> getReport(String id) async {
    final user = _requireUser();
    final sorted = _sortedReports;
    final index = sorted.indexWhere((r) => r['id'] == id);
    if (index < 0) throw StateError('Report not found');
    final report = Report.fromJson(sorted[index], isLatest: index == 0);
    return Report(
      summary: report.summary,
      sections: {
        for (final e in report.sections.entries)
          if (user.canRead(e.key)) e.key: e.value,
      },
      isLatest: report.isLatest,
    );
  }

  @override
  Stream<SyncRun> refresh({required String mode}) async* {
    final user = _requireUser();
    if (!user.canRefresh) throw const PaymentRuleException('Only owner or admin can refresh');
    if (mode != 'synthetic') {
      throw const PaymentRuleException('Live refresh needs the backend connection (phase 4)');
    }
    if (_activeRun != null) throw StateError('A refresh is already running');

    final id = 'syn-run-${++_seq}';
    final progress = <SyncStage>[];
    var run = SyncRun(id: id, status: SyncStatus.queued, progress: const [], dataMode: mode);
    _activeRun = run;
    try {
      yield run;
      const stages = [
        ('fub', 'ok', null),
        ('email', 'partial', 'First batch only; older messages remain'),
        ('doorloop', 'ok', null),
        ('time_doctor', 'partial', 'One intended VA not in active directory'),
        ('summary', 'ok', null),
        ('store', 'ok', null),
      ];
      for (final (stage, status, detail) in stages) {
        await Future<void>.delayed(stageDelay);
        progress.add(SyncStage(stage: stage, status: status, at: _now(), detail: detail));
        run = SyncRun(id: id, status: SyncStatus.running, progress: [...progress], dataMode: mode);
        yield run;
      }
      final reportId = _storeRefreshedReport(id);
      run = SyncRun(
          id: id, status: SyncStatus.partial, progress: [...progress], dataMode: mode, reportId: reportId);
      yield run;
    } finally {
      _activeRun = null;
    }
  }

  String _storeRefreshedReport(String runId) {
    final latest = jsonDecode(jsonEncode(_sortedReports.first)) as Map<String, dynamic>;
    final now = _now().toUtc();
    final local = inZone(now, businessTimezone);
    final date = '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    final id = 'syn-rpt-${now.millisecondsSinceEpoch}';
    latest
      ..['id'] = id
      ..['business_date'] = date
      ..['report_key'] = 'OPS-${date.replaceAll('-', '')}'
      ..['generated_at'] = now.toIso8601String()
      ..['sync_run_id'] = runId;
    // Keep cutoffs consistent with the new collection time.
    final loc = tz.getLocation(businessTimezone);
    final todayStart = tz.TZDateTime(loc, local.year, local.month, local.day);
    final prevStart = tz.TZDateTime(loc, local.year, local.month, local.day - 1);
    final prevDate = prevStart.toIso8601String().substring(0, 10);
    for (final s in asMapList(latest['sections'])) {
      if (s['collected_at'] != null) s['collected_at'] = now.toIso8601String();
      final cutoff = asMap(s['cutoff']);
      switch (cutoff['kind']) {
        case 'snapshot' || 'lookback':
          cutoff['as_of'] = now.toIso8601String();
        case 'business_day':
          cutoff
            ..['date'] = prevDate
            ..['from'] = prevStart.toUtc().toIso8601String()
            ..['to'] = todayStart.toUtc().toIso8601String();
          asMap(s['payload'])['work_date'] = prevDate;
      }
    }
    _reports.add(latest);
    return id;
  }

  // ───────────── Payments ─────────────

  void _seedPayments() {
    final t = _now();
    PaymentSubmission seed(String id, String by, String byName, PaymentDraft d, List<PaymentStatus> path,
        {String? reason}) {
      var s = PaymentSubmission(
        id: id,
        draft: d,
        submittedBy: by,
        submittedByName: byName,
        createdAt: t.subtract(const Duration(hours: 20)),
        status: PaymentStatus.submitted,
        events: [PaymentEvent(from: null, to: PaymentStatus.submitted, actorName: byName, at: t.subtract(const Duration(hours: 20)))],
      );
      for (final next in path) {
        s = s.copyWith(
          status: next,
          decisionReason: next == PaymentStatus.rejected ? reason : null,
          event: PaymentEvent(from: s.status, to: next, actorName: 'Harry Rotolo', at: t.subtract(const Duration(hours: 2)), reason: next == PaymentStatus.rejected ? reason : null),
        );
      }
      return s;
    }

    final day = DateTime(t.year, t.month, t.day);
    _payments.addAll([
      seed('syn-pay-1', 'demo-admin', 'Priya Shah',
          PaymentDraft(idempotencyKey: 'seed-1', leaseId: 'aaaaaaaaaaaaaaaaaaaaaaa1', amountMinor: 70000, paymentDate: day.subtract(const Duration(days: 1)), method: PaymentMethod.zelle, reference: 'ZL-TEST-7781', fundsConfirmed: true, propertyName: 'TEST Maple Court Apartments', unit: '1A', tenantName: 'TEST Tenant Alpha', notes: 'Synthetic example.'),
          const []),
      seed('syn-pay-2', 'demo-admin', 'Priya Shah',
          PaymentDraft(idempotencyKey: 'seed-2', leaseId: 'aaaaaaaaaaaaaaaaaaaaaaa5', amountMinor: 95000, paymentDate: day.subtract(const Duration(days: 3)), method: PaymentMethod.check, reference: 'CHK-TEST-2044', fundsConfirmed: true, propertyName: 'TEST 31 Cedar Rd', unit: 'Lower', tenantName: 'TEST Tenant Echo'),
          const [PaymentStatus.underReview]),
      seed('syn-pay-3', 'demo-admin', 'Priya Shah',
          PaymentDraft(idempotencyKey: 'seed-3', leaseId: 'aaaaaaaaaaaaaaaaaaaaaaa2', amountMinor: 50000, paymentDate: day.subtract(const Duration(days: 2)), method: PaymentMethod.venmo, reference: 'VN-TEST-1200', fundsConfirmed: true, propertyName: 'TEST Maple Court Apartments', unit: '2B', tenantName: 'TEST Tenant Bravo'),
          const [PaymentStatus.underReview, PaymentStatus.rejected],
          reason: 'Already recorded in DoorLoop as pending payment pay-03.'),
    ]);
  }

  @override
  Future<List<PaymentSubmission>> listPayments() async {
    final user = _requireUser();
    final visible = user.canReviewPayments ? _payments : _payments.where((p) => p.submittedBy == user.id);
    return visible.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<Uint8List> readReceipt(String path) async => throw const PaymentRuleException('Receipt images are available in live mode.');

  @override
  Future<PaymentSubmission> submitPayment(PaymentDraft d, {PaymentReceipt? receipt}) async {
    final user = _requireUser();
    if (!(user.canSubmitPayments || user.role == AppRole.owner)) {
      throw const PaymentRuleException('Not authorised to submit payments');
    }
    for (final p in _payments) {
      if (p.draft.idempotencyKey == d.idempotencyKey) {
        final same = p.draft.leaseId == d.leaseId.toLowerCase() &&
            p.draft.amountMinor == d.amountMinor &&
            p.draft.normalizedReference == d.normalizedReference &&
            p.draft.method.doorloopMethod == d.method.doorloopMethod &&
            p.draft.paymentDate == d.paymentDate;
        if (same) return p; // replay (double tap / retry)
        throw const PaymentRuleException('This submission key was already used for a different payment');
      }
    }
    _validateDraft(d);
    final dup = _payments.where((p) => p.status != PaymentStatus.rejected && p.draft.duplicateKey == d.duplicateKey);
    if (dup.isNotEmpty) {
      throw PaymentRuleException(
          'A submission with this lease, method and reference already exists (${dup.first.status.label})');
    }
    final now = _now();
    final sub = PaymentSubmission(
      // Distinct prefix from the seeded `syn-pay-N` rows so IDs can never collide.
      id: 'syn-sub-${++_seq}',
      draft: PaymentDraft(
        idempotencyKey: d.idempotencyKey,
        leaseId: d.leaseId.toLowerCase(),
        amountMinor: d.amountMinor,
        currency: d.currency,
        paymentDate: d.paymentDate,
        method: d.method,
        reference: d.normalizedReference,
        fundsConfirmed: d.fundsConfirmed,
        propertyId: d.propertyId,
        propertyName: d.propertyName,
        unit: d.unit,
        tenantName: d.tenantName,
        notes: d.notes,
      ),
      submittedBy: user.id,
      submittedByName: user.displayName,
      createdAt: now,
      status: PaymentStatus.submitted,
      events: [PaymentEvent(from: null, to: PaymentStatus.submitted, actorName: user.displayName, at: now)],
    );
    _payments.add(sub);
    return sub;
  }

  void _validateDraft(PaymentDraft d) {
    if (!_leasePattern.hasMatch(d.leaseId.toLowerCase())) {
      throw const PaymentRuleException('Lease ID must be the 24-character DoorLoop lease ID');
    }
    if (d.amountMinor <= 0 || d.amountMinor > _maxPaymentMinor) {
      throw const PaymentRuleException(r'Amount must be between $0.01 and $50,000.00');
    }
    if (d.currency != 'USD') throw const PaymentRuleException('Only USD is supported');
    if (!_referencePattern.hasMatch(d.normalizedReference)) {
      throw const PaymentRuleException('Reference must be 3–100 letters, digits or . _ / -');
    }
    if (!d.fundsConfirmed) {
      throw const PaymentRuleException('Confirm that the funds were actually received');
    }
    final local = inZone(_now(), businessTimezone);
    final today = DateTime(local.year, local.month, local.day);
    if (d.paymentDate.isAfter(today) || d.paymentDate.isBefore(today.subtract(const Duration(days: 90)))) {
      throw const PaymentRuleException('Payment date must be within the last 90 days');
    }
  }

  @override
  Future<PaymentSubmission> reviewPayment(String id, ReviewAction action, {String? reason}) async {
    final user = _requireUser();
    if (!user.canReviewPayments) throw const PaymentRuleException('Not authorised to review payments');
    final i = _payments.indexWhere((p) => p.id == id);
    if (i < 0) throw const PaymentRuleException('Submission not found');
    final sub = _payments[i];
    final target = switch (action) {
      ReviewAction.startReview => PaymentStatus.underReview,
      ReviewAction.approve => PaymentStatus.approved,
      ReviewAction.reject => PaymentStatus.rejected,
    };
    if (!paymentTransitions[sub.status]!.contains(target)) {
      throw PaymentRuleException('Cannot move from "${sub.status.label}" to "${target.label}"');
    }
    if (target == PaymentStatus.approved && sub.submittedBy == user.id) {
      throw const PaymentRuleException('A submitter cannot approve their own payment');
    }
    if (target == PaymentStatus.rejected && (reason == null || reason.trim().isEmpty)) {
      throw const PaymentRuleException('A rejection reason is required');
    }
    final updated = sub.copyWith(
      status: target,
      decisionReason: reason,
      event: PaymentEvent(from: sub.status, to: target, actorName: user.displayName, at: _now(), reason: reason),
    );
    _payments[i] = updated;
    return updated;
  }

  @override
  Future<PaymentSubmission> requestPosting(String id) async {
    throw const PaymentRuleException(
        'DoorLoop posting is disabled until the posting workflow, field mapping and approvals are verified.');
  }

  @override
  Future<PaymentSubmission> addPaymentComment(String id, String body) async {
    final user = _requireUser();
    final i = _payments.indexWhere((p) => p.id == id);
    if (i < 0) throw const PaymentRuleException('Submission not found');
    if (!(user.canReviewPayments || _payments[i].submittedBy == user.id)) {
      throw const PaymentRuleException('Not authorised');
    }
    final text = body.trim();
    if (text.isEmpty) throw const PaymentRuleException('Comment is empty');
    if (text.length > 2000) throw const PaymentRuleException('Comment is too long');
    final updated = _payments[i].withComment(PaymentComment(authorName: user.displayName, body: text, at: _now()));
    _payments[i] = updated;
    return updated;
  }

  // ───────────── Evidence reviews ─────────────

  @override
  Future<Map<int, EvidenceReview>> evidenceReviews() async {
    final user = _requireUser();
    if (!user.canRead(SectionSource.emailEvidence)) return const {};
    return Map.unmodifiable(_evidenceReviews);
  }

  @override
  Future<EvidenceReview> markEvidenceReviewed(int dealId) async {
    final user = _requireUser();
    if (!user.isOwnerOrAdmin || !user.canRead(SectionSource.emailEvidence)) {
      throw const PaymentRuleException('Only owner or admin can mark evidence reviewed');
    }
    final review = EvidenceReview(dealId: dealId, reviewer: user.displayName, at: _now());
    _evidenceReviews[dealId] = review;
    return review;
  }

  // ───────────── Task reviews ─────────────

  @override
  Future<Map<String, TaskReview>> taskReviews() async {
    final user = _requireUser();
    if (!user.canRead(SectionSource.doorloopTasks)) return const {};
    return Map.unmodifiable(_taskReviews);
  }

  @override
  Future<TaskReview> setTaskReview(String taskId, String status, {String? notes}) async {
    final user = _requireUser();
    if (!user.canRead(SectionSource.doorloopTasks)) throw const PaymentRuleException('Not authorised');
    if ((status == 'verified_complete' || status == 'disputed') && !user.isOwnerOrAdmin) {
      throw const PaymentRuleException('Only owner or admin can verify task completion');
    }
    final review = TaskReview(taskId: taskId, status: status, notes: notes, reviewer: user.displayName, at: _now());
    _taskReviews[taskId] = review;
    return review;
  }

  @override
  Future<AssistantReply> ask(List<ChatTurn> conversation) async {
    _requireUser();
    return const AssistantReply(
      answer: 'The assistant answers from the live Supabase data. Run the app with the live configuration to use it.',
      dataMode: 'synthetic',
    );
  }
}
