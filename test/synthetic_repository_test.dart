import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rotolo_ai_assistant/data/ops_repository.dart';
import 'package:rotolo_ai_assistant/data/synthetic_repository.dart';
import 'package:rotolo_ai_assistant/models/app_user.dart';
import 'package:rotolo_ai_assistant/models/json.dart';
import 'package:rotolo_ai_assistant/models/payloads.dart';
import 'package:rotolo_ai_assistant/models/payment.dart';
import 'package:rotolo_ai_assistant/models/report.dart';
import 'package:rotolo_ai_assistant/models/sync_run.dart';

final fixture = File('assets/fixtures/synthetic_reports.json').readAsStringSync();
final now = DateTime.utc(2026, 11, 18, 15);
final owner = SyntheticRepository.users[0];
final admin = SyntheticRepository.users[1];
final staff = SyntheticRepository.users[2];

({SyntheticRepository repo, void Function(AppUser?) as}) make() {
  AppUser? current = owner;
  final repo = SyntheticRepository(
    fixtureJson: fixture,
    currentUser: () => current,
    now: () => now,
    stageDelay: Duration.zero,
  );
  return (repo: repo, as: (u) => current = u);
}

PaymentDraft draft({String key = 'k-1', int amount = 50000, String ref = 'zl-100', String lease = 'aaaaaaaaaaaaaaaaaaaaaaa3'}) =>
    PaymentDraft(
      idempotencyKey: key,
      leaseId: lease,
      amountMinor: amount,
      paymentDate: DateTime(2026, 11, 17),
      method: PaymentMethod.zelle,
      reference: ref,
      fundsConfirmed: true,
    );

Matcher throwsRule(String pattern) =>
    throwsA(isA<PaymentRuleException>().having((e) => e.message, 'message', matches(RegExp(pattern, caseSensitive: false))));

void main() {
  group('fixture contract', () {
    final root = asMap(jsonDecode(fixture));
    final reports = asMapList(root['reports']);

    test('every report and section is synthetic with a valid cutoff', () {
      for (final r in reports) {
        expect(r['data_mode'], 'synthetic');
        expect(r['contract_version'], '1.0');
        for (final s in asMapList(r['sections'])) {
          expect(s['data_mode'], 'synthetic', reason: '${r['id']}/${s['source']}');
          expect(SectionSource.fromKey(s['source'] as String?), isNotNull);
          expect(['snapshot', 'business_day', 'lookback'], contains(asMap(s['cutoff'])['kind']));
          expect(['complete', 'partial', 'unavailable'], contains(s['status']));
        }
      }
    });

    test('all money fields are integer minor units or null', () {
      void walk(Object? v, String path) {
        if (v is Map) {
          v.forEach((k, val) {
            if (k.toString().endsWith('_minor')) {
              expect(val == null || val is int, isTrue, reason: '$path.$k = $val');
            }
            walk(val, '$path.$k');
          });
        } else if (v is List) {
          for (var i = 0; i < v.length; i++) {
            walk(v[i], '$path[$i]');
          }
        }
      }

      walk(root, r'$');
    });

    test('reconciled ledgers are internally consistent', () {
      final rent = asMapList(reports.first['sections']).firstWhere((s) => s['source'] == 'doorloop_rent');
      for (final lease in RentPayload(asMap(rent['payload'])).leases) {
        final l = lease.ledger;
        if (l.status == 'not_computed') {
          expect(l.reconciledBalance, isNull);
          continue;
        }
        expect(l.reconciledBalance,
            l.charges! - l.clearedPayments! - l.appliedCredits! + l.returnedPayments!,
            reason: lease.leaseId);
      }
    });

    test('a non-synthetic fixture is refused', () {
      final live = fixture.replaceFirst('"data_mode": "synthetic"', '"data_mode": "live"');
      expect(() => SyntheticRepository(fixtureJson: live, currentUser: () => owner), throwsStateError);
    });
  });

  group('section access', () {
    test('staff only receive deals', () async {
      final t = make()..as(staff);
      final r = await t.repo.getReport('syn-rpt-20261118');
      expect(r.sections.keys, [SectionSource.fubDeals]);
    });

    test('owner receives all sections; latest/historical flagged', () async {
      final t = make();
      final latest = await t.repo.getReport('syn-rpt-20261118');
      final old = await t.repo.getReport('syn-rpt-20261117');
      expect(latest.sections.length, 6);
      expect(latest.isLatest, isTrue);
      expect(old.isLatest, isFalse);
    });

    test('signed-out users get nothing', () {
      final t = make()..as(null);
      expect(t.repo.listReports(), throwsA(isA<PaymentRuleException>()));
    });
  });

  group('payment submission', () {
    test('same idempotency key returns the original (double tap / retry)', () async {
      final t = make();
      final a = await t.repo.submitPayment(draft());
      final b = await t.repo.submitPayment(draft());
      expect(b.id, a.id);
      expect((await t.repo.listPayments()).where((p) => p.draft.idempotencyKey == 'k-1').length, 1);
    });

    test('same key with a different payload is refused', () async {
      final t = make();
      await t.repo.submitPayment(draft());
      expect(t.repo.submitPayment(draft(amount: 60000)), throwsRule('already used'));
    });

    test('same lease/method/reference under a new key is a duplicate', () async {
      final t = make();
      await t.repo.submitPayment(draft());
      expect(t.repo.submitPayment(draft(key: 'k-2', ref: ' ZL-100 ')), throwsRule('already exists'));
    });

    test('a rejected payment can be resubmitted', () async {
      final t = make()..as(admin);
      final a = await t.repo.submitPayment(draft());
      t.as(owner);
      await t.repo.reviewPayment(a.id, ReviewAction.reject, reason: 'Wrong lease');
      t.as(admin);
      final b = await t.repo.submitPayment(draft(key: 'k-2'));
      expect(b.status, PaymentStatus.submitted);
    });

    test('validation mirrors the database', () async {
      final t = make();
      expect(t.repo.submitPayment(draft(amount: 0)), throwsRule('amount'));
      expect(t.repo.submitPayment(draft(amount: 5000001)), throwsRule('amount'));
      expect(t.repo.submitPayment(draft(lease: 'not-a-lease')), throwsRule('lease'));
      expect(t.repo.submitPayment(draft(ref: 'x')), throwsRule('reference'));
      expect(
          t.repo.submitPayment(PaymentDraft(
              idempotencyKey: 'k-9',
              leaseId: 'aaaaaaaaaaaaaaaaaaaaaaa3',
              amountMinor: 100,
              paymentDate: DateTime(2026, 11, 19),
              method: PaymentMethod.cash,
              reference: 'CASH-1',
              fundsConfirmed: true)),
          throwsRule('date'));
      expect(
          t.repo.submitPayment(PaymentDraft(
              idempotencyKey: 'k-10',
              leaseId: 'aaaaaaaaaaaaaaaaaaaaaaa3',
              amountMinor: 100,
              paymentDate: DateTime(2026, 11, 17),
              method: PaymentMethod.cash,
              reference: 'CASH-1',
              fundsConfirmed: false)),
          throwsRule('received'));
    });

    test('staff cannot submit', () {
      final t = make()..as(staff);
      expect(t.repo.submitPayment(draft()), throwsRule('not authorised'));
    });
  });

  group('payment review', () {
    test('full path and audit trail', () async {
      final t = make()..as(admin);
      final s = await t.repo.submitPayment(draft());
      t.as(owner);
      await t.repo.reviewPayment(s.id, ReviewAction.startReview);
      final approved = await t.repo.reviewPayment(s.id, ReviewAction.approve);
      expect(approved.status, PaymentStatus.approved);
      expect(approved.events.map((e) => e.to),
          [PaymentStatus.submitted, PaymentStatus.underReview, PaymentStatus.approved]);
    });

    test('cannot skip review, self-approve, or reject without a reason', () async {
      final t = make();
      final s = await t.repo.submitPayment(draft()); // owner submits
      expect(t.repo.reviewPayment(s.id, ReviewAction.approve), throwsRule('cannot move'));
      await t.repo.reviewPayment(s.id, ReviewAction.startReview);
      expect(t.repo.reviewPayment(s.id, ReviewAction.approve), throwsRule('own payment'));
      expect(t.repo.reviewPayment(s.id, ReviewAction.reject, reason: '  '), throwsRule('reason'));
    });

    test('non-reviewers cannot review', () async {
      final t = make()..as(admin);
      final s = await t.repo.submitPayment(draft());
      expect(t.repo.reviewPayment(s.id, ReviewAction.startReview), throwsRule('not authorised'));
    });

    test('non-reviewers only see their own submissions', () async {
      final t = make()..as(admin);
      final mine = await t.repo.listPayments();
      expect(mine.every((p) => p.submittedBy == admin.id), isTrue);
    });

    test('posting to DoorLoop is disabled', () async {
      final t = make();
      expect(t.repo.doorloopPostingEnabled, isFalse);
      expect(t.repo.requestPosting('syn-pay-1'), throwsRule('disabled'));
    });
  });

  group('refresh', () {
    test('produces a traceable run and a new latest report', () async {
      final t = make();
      final runs = await t.repo.refresh(mode: 'synthetic').toList();
      expect(runs.first.status, SyncStatus.queued);
      final last = runs.last;
      expect(last.status, SyncStatus.partial);
      expect(last.reportId, isNotNull);
      expect(last.progress.map((s) => s.stage), ['fub', 'email', 'doorloop', 'time_doctor', 'summary', 'store']);
      final list = await t.repo.listReports();
      expect(list.first.id, last.reportId);
      expect((await t.repo.getReport('syn-rpt-20261118')).isLatest, isFalse);
    });

    test('only one active run; staff cannot refresh; live refresh needs backend', () async {
      final t = make();
      final first = t.repo.refresh(mode: 'synthetic').listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(() => t.repo.refresh(mode: 'synthetic').first, throwsStateError);
      await first.cancel();
      expect(() => t.repo.refresh(mode: 'live').first, throwsA(isA<PaymentRuleException>()));
      t.as(staff);
      expect(() => t.repo.refresh(mode: 'synthetic').first, throwsA(isA<PaymentRuleException>()));
    });
  });

  group('task reviews', () {
    test('only owner/admin can verify completion', () async {
      final t = make()..as(admin);
      final r = await t.repo.setTaskReview('task-02', 'verified_complete');
      expect(r.status, 'verified_complete');
      t.as(staff);
      expect(t.repo.setTaskReview('task-02', 'claimed_complete'), throwsRule('not authorised'));
    });
  });

  group('sign-in', () {
    test('accepts demo accounts with the demo password only', () async {
      final t = make();
      t.as(null);
      expect((await t.repo.signIn(' HARRY@demo.example ', 'demo')).id, 'demo-owner');
      expect(t.repo.signIn('harry@demo.example', 'wrong'), throwsA(isA<AuthFailure>()));
      expect(t.repo.signIn('nobody@demo.example', 'demo'), throwsA(isA<AuthFailure>()));
    });
  });

  group('payment comments', () {
    test('submitter and reviewers can comment; others cannot; text is trimmed', () async {
      final t = make();
      t.as(admin);
      final sub = await t.repo.submitPayment(draft());
      expect((await t.repo.addPaymentComment(sub.id, '  bank slip attached  ')).comments.single.body, 'bank slip attached');
      t.as(owner);
      final c = await t.repo.addPaymentComment(sub.id, 'Checked');
      expect(c.comments.map((x) => x.authorName), ['Priya Shah', 'Harry Rotolo']);
      expect(c.status, PaymentStatus.submitted, reason: 'a comment never changes status');
      expect(t.repo.addPaymentComment(sub.id, '   '), throwsRule('empty'));
      t.as(staff);
      expect(t.repo.addPaymentComment(sub.id, 'hi'), throwsRule('not authorised'));
    });
  });

  group('deal evidence reviews', () {
    test('owner/admin only; staff cannot read them', () async {
      final t = make();
      await t.repo.markEvidenceReviewed(9002);
      expect((await t.repo.evidenceReviews())[9002]!.reviewer, 'Harry Rotolo');
      t.as(staff);
      expect(await t.repo.evidenceReviews(), isEmpty);
      expect(t.repo.markEvidenceReviewed(9002), throwsRule('only owner or admin'));
    });
  });
}
