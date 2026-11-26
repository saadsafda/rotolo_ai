import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/report_push.dart';
import '../models/app_user.dart';
import '../models/assistant.dart';
import '../models/assistant_chat.dart';
import '../models/assistant_email.dart';
import '../models/json.dart';
import '../models/payment.dart';
import '../models/report.dart';
import '../models/sync_run.dart';
import 'ops_repository.dart';

/// Live backend. The app holds only the publishable key; what each user can read
/// is decided by row-level security, and every write goes through a database
/// function (`submit_outside_payment`, `review_outside_payment`, …) that
/// enforces the same rules as [SyntheticRepository].
class SupabaseOpsRepository implements OpsRepository {
  SupabaseOpsRepository(this._db, {ReportPush? push}) : _push = push;

  final ReportPush? _push;
  final SupabaseClient _db;

  String _zone = 'America/New_York';
  int _staleAfter = 26;
  bool _postingEnabled = false;
  Map<String, String> _names = {};

  @override
  bool get isSynthetic => false;
  @override
  String get businessTimezone => _zone;
  @override
  int get staleAfterHours => _staleAfter;
  @override
  bool get doorloopPostingEnabled => _postingEnabled;
  @override
  List<AppUser> get demoUsers => const [];

  // ───────────── Auth ─────────────

  @override
  Future<AppUser> signIn(String email, String password) async {
    try {
      await _db.auth.signInWithPassword(email: email.trim(), password: password);
    } on AuthException catch (e) {
      // Same message for unknown email and wrong password.
      if (e.statusCode == '400' || e.code == 'invalid_credentials') {
        throw const AuthFailure('Email or password is incorrect.');
      }
      throw AuthFailure(e.message);
    } catch (_) {
      throw const AuthFailure('Could not reach the server. Check your connection and try again.');
    }
    final AppUser? user;
    try {
      user = await restoreSession();
    } catch (e) {
      // Signed in, but the profile could not be read (permissions, schema, network).
      await _db.auth.signOut();
      throw AuthFailure('Signed in, but your profile could not be loaded. '
          '${e is PostgrestException ? e.message : 'Check your connection and try again.'}');
    }
    if (user == null) {
      await _db.auth.signOut();
      throw const AuthFailure('Your account has no access to this app yet. Ask the owner to add you.');
    }
    return user;
  }

  @override
  Future<AppUser?> restoreSession() async {
    final auth = _db.auth.currentUser;
    if (auth == null) return null;
    final profile = await _db.from('profiles').select().eq('id', auth.id).eq('active', true).maybeSingle();
    if (profile == null) return null;
    final role = AppRole.values.byName(asString(profile['role']) ?? 'staff');
    final access = await _db.from('section_access').select('source').eq('role', role.name).eq('allowed', true);
    await _loadConfig();
    return AppUser(
      id: auth.id,
      displayName: asString(profile['display_name']) ?? auth.email ?? 'User',
      email: auth.email ?? '',
      role: role,
      canSubmitPayments: asBool(profile['can_submit_payments']) ?? false,
      canReviewPayments: asBool(profile['can_review_payments']) ?? false,
      readableSources: {
        for (final r in access) ?SectionSource.fromKey(asString(r['source'])),
      },
    );
  }

  @override
  Future<void> signOut() async {
    final user = _db.auth.currentUser;
    if (user != null) {
      try {
        await _push?.revoke(user.id);
      } catch (_) {
        // Losing connectivity must not prevent local sign-out.
      }
    }
    await _db.auth.signOut();
  }

  static final passwordResetUri = Uri.parse('com.rotolo.operations://password-reset');

  @override
  Future<void> requestPasswordReset(String email) async {
    try {
      await _db.auth.resetPasswordForEmail(email.trim(), redirectTo: passwordResetUri.toString());
    } on AuthException catch (error) {
      if (error.statusCode == '429') throw const AuthFailure('Too many requests. Wait a moment and try again.');
      throw const AuthFailure('Password reset is temporarily unavailable. Try again later.');
    } catch (_) {
      throw const AuthFailure('Could not reach the server. Check your connection and try again.');
    }
  }

  @override
  Future<void> finishPasswordReset(String password) async {
    try {
      await _db.auth.updateUser(UserAttributes(password: password));
    } on AuthException catch (error) {
      throw AuthFailure(error.message);
    } catch (_) {
      throw const AuthFailure('Could not update the password. Check your connection and try again.');
    }
    await signOut();
  }

  Future<void> _loadConfig() async {
    final rows = await _db.from('app_config').select('key, value');
    for (final r in rows) {
      final v = r['value'];
      switch (r['key']) {
        case 'business_timezone' when v is String:
          _zone = v;
        case 'stale_after_hours' when v is num:
          _staleAfter = v.toInt();
        case 'doorloop_posting_enabled':
          _postingEnabled = v == true;
      }
    }
  }

  Future<void> _loadNames() async {
    // RLS: owner/admin see everyone, others only themselves.
    final rows = await _db.from('profiles').select('id, display_name');
    _names = {for (final r in rows) r['id'] as String: (r['display_name'] as String?) ?? 'User'};
  }

  String _name(String? id, {String? kind}) =>
      id == null ? (kind == 'n8n' ? 'n8n workflow' : 'System') : _names[id] ?? 'Another user';

  // ───────────── Reports ─────────────

  static const _reportCols = 'id, report_key, business_date, timezone, data_mode, status, generated_at';

  @override
  Future<List<ReportSummary>> listReports() async {
    final rows = await _db.from('reports').select(_reportCols).order('generated_at', ascending: false).limit(60);
    return [for (final r in rows) Report.fromJson(r, isLatest: false).summary];
  }

  static const _reportDetails = '$_reportCols, report_sections(*)';

  @override
  Future<List<Report>> listReportDetails() async {
    final rows = await _db.from('reports').select(_reportDetails).order('generated_at', ascending: false).limit(60);
    final latest = <String>{};
    return [
      for (final row in rows)
        _report(row, isLatest: latest.add(row['data_mode'] as String)),
    ];
  }

  @override
  Future<Report> getReport(String id) async {
    final row = await _db.from('reports').select(_reportDetails).eq('id', id).maybeSingle();
    if (row == null) throw StateError('Report not found');
    final latest = await _db.from('reports').select('id')
        .eq('data_mode', row['data_mode'] as String).order('generated_at', ascending: false).limit(1).maybeSingle();
    return _report(row, isLatest: latest?['id'] == id);
  }

  Report _report(Json row, {required bool isLatest}) {
    final json = {...row, 'sections': [
      for (final s in asMapList(row['report_sections']))
        {...s, 'workflow': {'id': s['workflow_id'], 'execution_id': s['execution_id']}},
    ]};
    return Report.fromJson(json, isLatest: isLatest);
  }

  @override
  Stream<SyncRun> refresh({required String mode}) async* {
    final id = await _guard(() async {
      final result = await _db.rpc('request_app_report', params: {'p_mode': mode});
      return result as String;
    });
    yield SyncRun(id: id, status: SyncStatus.queued, progress: const [], dataMode: mode);

    final deadline = DateTime.now().add(const Duration(minutes: 19));
    var consecutiveFailures = 0;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final row = asMap(await _db
            .rpc('app_report_progress', params: {'p_run': id})
            .timeout(const Duration(seconds: 10)));
        if (row.isEmpty) throw const PaymentRuleException('The report request could not be found.');
        final run = SyncRun.fromJson(row);
        consecutiveFailures = 0;
        yield run;
        if (!run.status.isActive) return;
      } on PostgrestException {
        throw const PaymentRuleException('Could not read report progress. Sign in again or try refreshing.');
      } on PaymentRuleException {
        rethrow;
      } catch (_) {
        if (++consecutiveFailures >= 3) {
          throw const PaymentRuleException('Connection lost. Refresh again to follow the report already running.');
        }
      }
      await Future<void>.delayed(const Duration(seconds: 4));
    }
    throw const PaymentRuleException('Could not confirm the report result. Check Reports or refresh again.');
  }

  // ───────────── Payments ─────────────

  static const _paymentCols = '*, payment_events(*), payment_comments(*)';

  @override
  Future<List<PaymentSubmission>> listPayments() async {
    await _loadNames();
    final rows = await _db.from('payment_submissions').select(_paymentCols).order('created_at', ascending: false);
    return [for (final r in rows) _payment(r)];
  }

  Future<PaymentSubmission> _fetchPayment(String id) async {
    await _loadNames();
    final row = await _db.from('payment_submissions').select(_paymentCols).eq('id', id).single();
    return _payment(row);
  }

  PaymentSubmission _payment(Map<String, dynamic> r) {
    final events = asMapList(r['payment_events'])..sort((a, b) => (a['id'] as num).compareTo(b['id'] as num));
    final comments = asMapList(r['payment_comments'])
      ..sort((a, b) => asString(a['created_at'])!.compareTo(asString(b['created_at'])!));
    return PaymentSubmission(
      id: r['id'] as String,
      draft: PaymentDraft(
        idempotencyKey: r['idempotency_key'] as String,
        leaseId: r['lease_id'] as String,
        amountMinor: asInt(r['amount_minor'])!,
        currency: asString(r['currency'])?.trim() ?? 'USD',
        paymentDate: asDate(r['payment_date'])!,
        method: _method(asString(r['method']), asString(r['method_detail'])),
        reference: r['reference'] as String,
        fundsConfirmed: asBool(r['funds_confirmed']) ?? false,
        propertyId: asString(r['property_id']),
        propertyName: asString(r['property_name']),
        unit: asString(r['unit']),
        tenantName: asString(r['tenant_name']),
        notes: asString(r['notes']),
      ),
      submittedBy: r['submitted_by'] as String,
      submittedByName: _name(r['submitted_by'] as String?),
      createdAt: asDateTime(r['created_at'])!,
      status: _status(asString(r['status'])),
      decisionReason: asString(r['decision_reason']),
      doorloopPaymentId: asString(r['doorloop_payment_id']),
      receiptPath: asString(r['receipt_path']),
      events: [
        for (final e in events)
          PaymentEvent(
            from: e['from_status'] == null ? null : _status(asString(e['from_status'])),
            to: _status(asString(e['to_status'])),
            actorName: _name(asString(e['actor']), kind: asString(e['actor_kind'])),
            at: asDateTime(e['created_at'])!,
            reason: asString(asMap(e['detail'])['reason']),
          ),
      ],
      comments: [
        for (final c in comments)
          PaymentComment(
            authorName: asString(c['author_name']) ?? 'User',
            body: asString(c['body']) ?? '',
            at: asDateTime(c['created_at'])!,
          ),
      ],
    );
  }

  static PaymentStatus _status(String? key) =>
      PaymentStatus.values.firstWhere((s) => s.key == key, orElse: () => PaymentStatus.failed);

  static PaymentMethod _method(String? dl, String? detail) {
    for (final m in PaymentMethod.values) {
      if (m.label == detail && m.doorloopMethod == dl) return m;
    }
    return switch (dl) {
      'CASH' => PaymentMethod.cash,
      'CHECK' => PaymentMethod.check,
      'MONEY_ORDER' => PaymentMethod.moneyOrder,
      'CASHIERS_CHECK' => PaymentMethod.cashiersCheck,
      'EFT' => PaymentMethod.bankTransfer,
      _ => PaymentMethod.other,
    };
  }

  Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on PostgrestException catch (e) {
      final msg = e.message;
      if (msg.contains('payment_submissions_one_live')) {
        throw const PaymentRuleException('A submission with this lease, method and reference already exists.');
      }
      if (e.code == '42501' || msg.contains('permission denied')) {
        throw PaymentRuleException(msg.contains('permission denied') ? 'Not authorised' : msg);
      }
      throw PaymentRuleException(msg);
    }
  }

  static const _receiptBucket = 'payment-receipts';

  Future<String> _uploadReceipt(PaymentDraft draft, PaymentReceipt receipt) async {
    final user = _db.auth.currentUser;
    if (user == null) throw const PaymentRuleException('Sign in again to attach a receipt.');
    final digest = sha256.convert(receipt.bytes);
    final path = '${user.id}/${draft.idempotencyKey}/$digest.${receipt.extension}';
    final bucket = _db.storage.from(_receiptBucket);
    try {
      await bucket.uploadBinary(path, receipt.bytes, fileOptions: FileOptions(contentType: receipt.mimeType));
    } catch (_) {
      // A retry can follow an upload whose response was lost. Only reuse an identical file.
      try {
        if (sha256.convert(await bucket.download(path)) == digest) return path;
      } catch (_) {}
      throw const PaymentRuleException('Could not attach the receipt. Check your connection and try again.');
    }
    return path;
  }

  @override
  Future<Uint8List> readReceipt(String path) async {
    try {
      return await _db.storage.from(_receiptBucket).download(path);
    } catch (_) {
      throw const PaymentRuleException('Could not open the receipt. Check your access and connection.');
    }
  }

  @override
  Future<PaymentSubmission> submitPayment(PaymentDraft d, {PaymentReceipt? receipt}) => _guard(() async {
        final receiptPath = receipt == null ? null : await _uploadReceipt(d, receipt);
        final row = await _db.rpc('submit_outside_payment', params: {
          'p_idempotency_key': d.idempotencyKey,
          'p_lease_id': d.leaseId,
          'p_amount_minor': d.amountMinor,
          'p_currency': d.currency,
          'p_payment_date': DateFormat('yyyy-MM-dd').format(d.paymentDate),
          'p_method': d.method.doorloopMethod,
          'p_method_detail': d.method.label,
          'p_reference': d.reference,
          'p_property_id': d.propertyId,
          'p_property_name': d.propertyName,
          'p_unit': d.unit,
          'p_tenant_name': d.tenantName,
          'p_notes': d.notes,
          'p_receipt_path': receiptPath,
          'p_funds_confirmed': d.fundsConfirmed,
        });
        return _fetchPayment(asMap(row)['id'] as String);
      });

  @override
  Future<PaymentSubmission> reviewPayment(String id, ReviewAction action, {String? reason}) => _guard(() async {
        await _db.rpc('review_outside_payment', params: {
          'p_submission_id': id,
          'p_action': switch (action) {
            ReviewAction.startReview => 'start_review',
            ReviewAction.approve => 'approve',
            ReviewAction.reject => 'reject',
          },
          'p_reason': reason,
        });
        return _fetchPayment(id);
      });

  @override
  Future<PaymentSubmission> requestPosting(String id) async => throw const PaymentRuleException(
      'DoorLoop posting is disabled until the posting workflow, field mapping and approvals are verified.');

  @override
  Future<PaymentSubmission> addPaymentComment(String id, String body) => _guard(() async {
        await _db.rpc('add_payment_comment', params: {'p_submission_id': id, 'p_body': body});
        return _fetchPayment(id);
      });

  // ───────────── Reviews ─────────────

  @override
  Future<Map<String, TaskReview>> taskReviews() async {
    await _loadNames();
    final rows = await _db.from('task_reviews').select();
    return {for (final r in rows) r['task_id'] as String: _taskReview(r)};
  }

  TaskReview _taskReview(Map<String, dynamic> r) => TaskReview(
        taskId: r['task_id'] as String,
        status: asString(r['review_status']) ?? 'not_reviewed',
        notes: asString(r['notes']),
        reviewer: _name(asString(r['reviewed_by'])),
        at: asDateTime(r['reviewed_at']),
      );

  @override
  Future<TaskReview> setTaskReview(String taskId, String status, {String? notes}) => _guard(() async {
        final row = await _db.rpc('set_task_review',
            params: {'p_task_id': taskId, 'p_status': status, 'p_notes': notes, 'p_evidence_paths': <String>[]});
        await _loadNames();
        return _taskReview(asMap(row));
      });

  @override
  Future<Map<int, EvidenceReview>> evidenceReviews() async {
    final rows = await _db.from('deal_evidence_reviews').select();
    return {for (final r in rows) asInt(r['deal_id'])!: _evidence(r)};
  }

  EvidenceReview _evidence(Map<String, dynamic> r) => EvidenceReview(
        dealId: asInt(r['deal_id'])!,
        reviewer: asString(r['reviewer_name']) ?? 'Reviewer',
        at: asDateTime(r['reviewed_at'])!,
      );

  @override
  Future<EvidenceReview> markEvidenceReviewed(int dealId) => _guard(() async {
        final row = await _db.rpc('mark_deal_evidence_reviewed', params: {'p_deal_id': dealId, 'p_notes': null});
        return _evidence(asMap(row));
      });

  // ───────────── Assistant ─────────────

  @override
  Future<List<ChatSummary>> listAssistantChats() async {
    final chats = <ChatSummary>[];
    const pageSize = 100;
    for (var offset = 0;; offset += pageSize) {
      final rows = await _db.from('assistant_chats').select('id,title,updated_at')
          .order('updated_at').order('id').range(offset, offset + pageSize - 1);
      chats.addAll(rows.map(ChatSummary.fromJson));
      if (rows.length < pageSize) return chats;
    }
  }

  @override
  Future<SavedChat> getAssistantChat(String id) async {
    final row = await _db.from('assistant_chats').select('id,title,updated_at,version,entries').eq('id', id).single();
    return SavedChat.fromJson(row);
  }

  @override
  Future<SavedChat> saveAssistantChat(ChatSummary chat, List<ChatEntry> entries, {int? version}) async {
    final values = {'title': chat.title, 'entries': [for (final entry in entries) entry.toJson()]};
    const columns = 'id,title,updated_at,version,entries';
    final table = _db.from('assistant_chats');
    final row = version == null
        ? await table.insert({'id': chat.id, ...values}).select(columns).single()
        : await table.update({
            ...values, 'version': version + 1, 'updated_at': chat.updatedAt.toUtc().toIso8601String(),
          }).eq('id', chat.id).eq('version', version).select(columns).maybeSingle();
    if (row == null) throw const AssistantFailure('This chat changed on another device. Reopen it from Chat history to continue.');
    return SavedChat.fromJson(row);
  }

  @override
  Future<AssistantReply> ask(List<ChatTurn> conversation) async {
    try {
      final res = await _db.functions.invoke('ask-portfolio', body: {
        'messages': [for (final t in conversation.skip(conversation.length > 12 ? conversation.length - 12 : 0)) t.toJson()],
      });
      return AssistantReply.fromJson(asMap(res.data));
    } on FunctionException catch (e) {
      final code = asString(asMap(e.details)['error']);
      throw AssistantFailure(switch ((e.status, code)) {
        (0, _) => 'No connection to the server. Check your internet and try again.',
        (401, _) => 'Your session has expired. Sign out and sign in again.',
        (403, _) => 'Your account does not have access to the assistant.',
        (404, _) || (503, 'assistant_not_configured') => 'The assistant is unavailable right now.',
        _ => 'The assistant could not answer right now. Try again in a moment.',
      });
    } catch (_) {
      throw const AssistantFailure('The assistant could not answer right now. Try again in a moment.');
    }
  }

  @override
  Future<AssistantEmailReceipt> sendAssistantEmail(AssistantEmail email, {required String requestId}) async {
    try {
      final response = await _db.functions.invoke('send-assistant-email', body: {
        ...email.toJson(),
        'request_id': requestId,
      });
      if (asMap(response.data)['status'] != 'sent') {
        throw const AssistantFailure('I could not confirm delivery. Check Gmail’s Sent folder before sending again.');
      }
      return AssistantEmailReceipt(to: email.to);
    } on FunctionException catch (e) {
      final code = asString(asMap(e.details)['error']);
      throw AssistantFailure(switch ((e.status, code)) {
        (401, _) => 'Your session expired. Please sign in again.',
        (403, _) => 'This account does not have permission to send email.',
        (400, _) => 'Check the email address, subject, and message.',
        (404, _) || (503, 'mail_not_connected') => 'Email sending isn’t connected yet.',
        (502, 'mail_rejected') => 'Gmail rejected this email. Check the details before trying again.',
        _ => 'I could not confirm delivery. Check Gmail’s Sent folder before sending again.',
      });
    } on AssistantFailure {
      rethrow;
    } catch (_) {
      throw const AssistantFailure('I could not confirm delivery. Check Gmail’s Sent folder before sending again.');
    }
  }
}
