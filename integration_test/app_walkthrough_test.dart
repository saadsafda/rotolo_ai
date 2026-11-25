import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rotolo_ai_assistant/core/time_format.dart';
import 'package:rotolo_ai_assistant/main.dart';
import 'package:rotolo_ai_assistant/state/providers.dart';

/// Drives the real app on a simulator/emulator through every area and
/// captures a screenshot at each step (saved by test_driver/integration_test.dart).
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  var shot = 0;

  Future<void> snap(WidgetTester tester, String name) async {
    await tester.pumpAndSettle();
    await binding.takeScreenshot('${(++shot).toString().padLeft(2, '0')}_$name');
  }

  Future<void> pumpFor(WidgetTester tester, Duration total) async {
    final end = DateTime.now().add(total);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  // Vertical lists only (chip rows are horizontal Scrollables).
  Finder vertical() => find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).last;

  Future<void> tapVisible(WidgetTester tester, Finder f) async {
    await tester.scrollUntilVisible(f, 250, scrollable: vertical());
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  Future<void> toTop(WidgetTester tester) async {
    await tester.drag(vertical(), const Offset(0, 4000));
    await tester.pumpAndSettle();
  }

  Future<void> nav(WidgetTester tester, String label) async {
    const inMore = {'Home': 'overview', 'Payments': 'payments', 'Tasks': 'maintenance'};
    if (inMore.containsKey(label)) {
      await tester.tap(find.byKey(const ValueKey('nav-more')));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(ValueKey('more-${inMore[label]}')));
      return;
    }
    await tester.tap(find.byKey(ValueKey('nav-${label.toLowerCase()}')));
    await tester.pumpAndSettle();
  }

  Future<void> back(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Back').last);
    await tester.pumpAndSettle();
  }

  Future<void> signIn(WidgetTester tester, String id) async {
    await tester.ensureVisible(find.byKey(ValueKey('signin-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('signin-$id')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('signin-submit')));
    await tester.tap(find.byKey(const ValueKey('signin-submit')));
    await pumpFor(tester, const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
  }

  Future<void> signOut(WidgetTester tester) async {
    await nav(tester, 'More');
    while (find.byKey(const ValueKey('more-settings')).evaluate().isEmpty) {
      await back(tester);
    }
    await tester.tap(find.byKey(const ValueKey('more-settings')));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const ValueKey('sign-out')));
  }

  testWidgets('full walkthrough', (tester) async {
    initTimeZones();
    final fixtures = await rootBundle.loadString('assets/fixtures/synthetic_reports.json');
    await tester.pumpWidget(ProviderScope(
      retry: (_, _) => null,
      overrides: [fixtureJsonProvider.overrideWithValue(fixtures)],
      child: const RotoloApp(),
    ));
    await snap(tester, 'sign_in');
    await tester.ensureVisible(find.byKey(const ValueKey('signin-wrong')));
    await tester.tap(find.byKey(const ValueKey('signin-wrong')));
    await tester.tap(find.byKey(const ValueKey('signin-submit')));
    await pumpFor(tester, const Duration(milliseconds: 800));
    await snap(tester, 'sign_in_error');

    // ── Owner: home ──
    await signIn(tester, 'demo-owner');
    await snap(tester, 'owner_home');
    await tester.drag(vertical(), const Offset(0, -700));
    await snap(tester, 'owner_home_glance');
    await tester.drag(vertical(), const Offset(0, -700));
    await snap(tester, 'owner_home_sources');
    await toTop(tester);

    // ── Report detail and refresh ──
    await tapVisible(tester, find.byKey(const ValueKey('home-report-card')));
    await snap(tester, 'report_detail');
    await tester.tap(find.byKey(const ValueKey('refresh-button')));
    await pumpFor(tester, const Duration(milliseconds: 1600));
    await binding.takeScreenshot('${(++shot).toString().padLeft(2, '0')}_refresh_in_progress');
    await pumpFor(tester, const Duration(seconds: 4));
    await snap(tester, 'refresh_done');
    await tapVisible(tester, find.text('Open new report'));
    await tapVisible(tester, find.text('Rent and payments'));
    await snap(tester, 'report_rent_section');

    // ── Reports history ──
    await nav(tester, 'Reports');
    await snap(tester, 'reports_list');
    await tester.tap(find.text('Tue, Nov 17'));
    await tester.pumpAndSettle();
    await snap(tester, 'historical_report');

    // ── Payments ──
    await nav(tester, 'Payments');
    await snap(tester, 'payments_approvals');
    await tester.tap(find.text('Balances'));
    await tester.pumpAndSettle();
    await snap(tester, 'payments_balances');
    await tapVisible(tester, find.text('TEST Maple Court Apartments · 2B'));
    await snap(tester, 'balance_detail');
    await tester.drag(vertical(), const Offset(0, -600));
    await snap(tester, 'balance_detail_pending');
    await back(tester);

    // ── Tasks ──
    await nav(tester, 'Tasks');
    await snap(tester, 'tasks');
    await tapVisible(tester, find.text('TEST Replace smoke detector batteries'));
    await snap(tester, 'task_detail');
    await tapVisible(tester, find.byKey(const ValueKey('task-verify')));
    await snap(tester, 'task_verified');
    await back(tester);
    await toTop(tester);
    await tester.tap(find.text('Calendar'));
    await tester.pumpAndSettle();
    await snap(tester, 'tasks_calendar');

    // ── More: deals, team, notifications, integrations, settings ──
    await nav(tester, 'More');
    await snap(tester, 'more');
    await tester.tap(find.byKey(const ValueKey('more-deals')));
    await tester.pumpAndSettle();
    await snap(tester, 'deals');
    await tapVisible(tester, find.text('TEST 220 Oak Ave Riverton').first);
    await snap(tester, 'deal_needs_review');
    await tester.drag(vertical(), const Offset(0, -700));
    await snap(tester, 'deal_email_evidence');
    await tapVisible(tester, find.byKey(const ValueKey('mark-reviewed')));
    await back(tester);
    await back(tester);
    await tester.tap(find.byKey(const ValueKey('more-team-activity')));
    await tester.pumpAndSettle();
    await snap(tester, 'team_activity');
    await back(tester);
    await tester.tap(find.byKey(const ValueKey('more-notifications')));
    await tester.pumpAndSettle();
    await snap(tester, 'notifications');
    await back(tester);
    await tapVisible(tester, find.byKey(const ValueKey('more-connections')));
    await tester.pumpAndSettle();
    await snap(tester, 'integrations');
    await back(tester);
    await tester.tap(find.byKey(const ValueKey('more-settings')));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('Dark'));
    await toTop(tester);
    await snap(tester, 'settings_dark');
    await nav(tester, 'Home');
    await snap(tester, 'home_dark');
    await nav(tester, 'More');
    await tapVisible(tester, find.text('Light'));
    await signOut(tester);

    // ── Admin submits an outside payment (matches a pending DoorLoop payment) ──
    await signIn(tester, 'demo-admin');
    await nav(tester, 'Payments');
    await tester.tap(find.byKey(const ValueKey('new-payment')));
    await tester.pumpAndSettle();
    await snap(tester, 'wizard_lease');
    await tester.tap(find.text('TEST Maple Court Apartments'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('TEST Tenant Bravo'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('wizard-next')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('amount')), '500.00');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('Venmo'));
    await snap(tester, 'wizard_details');
    await tester.tap(find.byKey(const ValueKey('wizard-next')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('reference')), 'vn-sim-0001');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('wizard-next')));
    await tester.pumpAndSettle();
    await snap(tester, 'wizard_review_duplicate');
    await tapVisible(tester, find.byKey(const ValueKey('funds-confirm')));
    final submit = find.byKey(const ValueKey('submit-payment'));
    await tester.tap(submit);
    await tester.tap(submit, warnIfMissed: false); // double tap
    await snap(tester, 'wizard_submitted');
    await tester.tap(find.text('View request'));
    await tester.pumpAndSettle();
    await snap(tester, 'admin_request_view_only');
    await signOut(tester);

    // ── Owner reviews: duplicate check gates approval; posting stays disabled ──
    await signIn(tester, 'demo-owner');
    await nav(tester, 'Payments');
    expect(find.textContaining('VN-SIM-0001'), findsNothing); // reference is not on the card
    await snap(tester, 'owner_payment_queue');
    await tester.tap(find.text(r'$500.00').first);
    await tester.pumpAndSettle();
    await snap(tester, 'owner_review_submitted');
    await tester.tap(find.byKey(const ValueKey('start-review')));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const ValueKey('dup-ack')));
    await snap(tester, 'owner_review_duplicate_ack');
    await tester.tap(find.byKey(const ValueKey('approve')));
    await tester.pumpAndSettle();
    await snap(tester, 'approve_dialog');
    await tester.tap(find.widgetWithText(FilledButton, 'Approve').last);
    await tester.pumpAndSettle();
    await toTop(tester);
    await snap(tester, 'payment_approved_posting_disabled');
    await signOut(tester);

    // ── Staff: restricted ──
    await signIn(tester, 'demo-staff');
    await snap(tester, 'staff_home');
    expect(find.byKey(const ValueKey('nav-payments')), findsNothing);
    expect(find.byKey(const ValueKey('nav-tasks')), findsNothing);
    await nav(tester, 'Reports');
    await tester.tap(find.text('Wed, Nov 18').first);
    await tester.pumpAndSettle();
    await snap(tester, 'staff_report_detail');
    await nav(tester, 'More');
    await snap(tester, 'staff_more');
  });
}
