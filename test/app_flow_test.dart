import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rotolo_ai_assistant/core/notification_routing.dart';
import 'package:rotolo_ai_assistant/models/payment.dart';
import 'package:rotolo_ai_assistant/state/app_state.dart';
import 'package:rotolo_ai_assistant/state/providers.dart';
import 'package:rotolo_ai_assistant/ui/router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

void main() {
  testWidgets('owner home shows demo label, attention list and report card', (tester) async {
    final c = await pumpApp(tester);
    expect(find.text('Real Estate AI'), findsOneWidget);
    await signIn(tester, 'demo-owner');
    expect(find.text('Ask your portfolio'), findsOneWidget); // the assistant opens first
    await go(tester, c, '/home');

    expect(find.text('DEMO DATA'), findsOneWidget);
    expect(find.text('Good morning, Harry'), findsOneWidget);
    expect(find.text('Needs your attention'), findsOneWidget);
    expect(find.text('Payment awaiting approval'), findsWidgets);
    expect(find.text('Deal evidence needs review'), findsWidgets);
    expect(find.text('Team hours incomplete'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('home-report-card')), 200, scrollable: verticalScrollable());
    expect(find.text('Daily report · Wed, Nov 18'), findsOneWidget);
    expect(find.text('Partial'), findsWidgets);
    for (final label in ['Ask', 'Home', 'Reports', 'Payments', 'Tasks', 'More']) {
      expect(navItem(label), findsOneWidget);
    }
  });

  testWidgets('sign-in rejects a wrong or empty password', (tester) async {
    await pumpApp(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('signin-wrong')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('signin-wrong')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('signin-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Email or password is incorrect.'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('signin-password')), '');
    await tester.tap(find.byKey(const ValueKey('signin-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Enter your password.'), findsOneWidget);
    expect(find.text('Needs your attention'), findsNothing);
  });

  testWidgets('switching accounts rebuilds cleanly (no provider invalidation during build)', (tester) async {
    final c = await pumpApp(tester);
    for (final id in ['demo-owner', 'demo-admin', 'demo-staff', 'demo-owner']) {
      await signIn(tester, id);
      expect(tester.takeException(), isNull, reason: 'after signing in as $id');
      expect(find.text('Ask your portfolio'), findsOneWidget);
      expect(find.textContaining('what would you like to know?'), findsOneWidget);
      await go(tester, c, '/more/settings');
      await tapVisible(tester, find.byKey(const ValueKey('sign-out')));
      expect(tester.takeException(), isNull, reason: 'after signing out $id');
      expect(find.text('Sign in'), findsWidgets);
    }
  });

  testWidgets('staff see only home, reports and more; restricted screens are gated', (tester) async {
    final c = await pumpApp(tester);
    await signIn(tester, 'demo-staff');
    expect(navItem('Payments'), findsNothing);
    expect(navItem('Tasks'), findsNothing);
    expect(find.text('Rent to review'), findsNothing);

    await go(tester, c, '/payments/balance/aaaaaaaaaaaaaaaaaaaaaaa2');
    expect(find.text('Not available for your role'), findsOneWidget);
    expect(find.textContaining('TEST Tenant'), findsNothing);

    await go(tester, c, '/more/integrations');
    expect(find.text('Permission denied'), findsOneWidget);

    await go(tester, c, '/reports/syn-rpt-20261118');
    expect(find.byKey(const ValueKey('refresh-button')), findsNothing);
    expect(find.text('Rent and payments'), findsNothing);
  });

  testWidgets('push notification link survives sign-in and opens the right report', (tester) async {
    final c = await pumpApp(tester);
    final route = routeForNotification({'type': 'report_ready', 'report_id': 'syn-rpt-20261117'})!;
    c.read(routerProvider).go(route);
    await tester.pumpAndSettle();
    expect(find.text('Real Estate AI'), findsOneWidget); // redirected to sign-in first
    await signIn(tester, 'demo-owner');
    expect(find.text('Daily report'), findsOneWidget);
    expect(find.text('Tuesday, Nov 17, 2026'), findsOneWidget);
    expect(find.textContaining('Historical report'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('safety check'), 200, scrollable: verticalScrollable());
    expect(find.textContaining('safety check'), findsOneWidget); // AI summary rejected by guard
  });

  testWidgets('refresh shows progress and links to the new report', (tester) async {
    final c = await pumpApp(tester);
    await signIn(tester, 'demo-owner');
    await go(tester, c, '/reports/syn-rpt-20261118');
    await tester.tap(find.byKey(const ValueKey('refresh-button')));
    await tester.pump();
    expect(find.text('Refreshing…'), findsOneWidget);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 700));
    }
    await tester.pumpAndSettle();
    expect(find.text('Complete with gaps'), findsOneWidget);
    await tapVisible(tester, find.text('Open new report'));
    expect(find.text('Wednesday, Nov 18, 2026'), findsOneWidget);
    expect(find.textContaining('Historical report'), findsNothing);

    await go(tester, c, '/more/team');
    expect(find.text('Tue, Nov 17'), findsOneWidget, reason: 'The refresh and original report cover the same work date');
    expect(find.text('Mon, Nov 16'), findsOneWidget);
  });

  Future<void> fillWizard(WidgetTester tester, {required String amount, required String method, required String reference}) async {
    await tester.enterText(find.byKey(const ValueKey('amount')), amount);
    await tester.tap(find.text(method));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('wizard-next')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('reference')), reference);
    await tester.tap(find.byKey(const ValueKey('wizard-next')));
    await tester.pumpAndSettle();
  }

  testWidgets('payment wizard validates each step and a double tap creates one submission', (tester) async {
    final c = await pumpApp(tester);
    await signIn(tester, 'demo-admin');
    final before = (await c.read(repositoryProvider).listPayments()).length;

    await go(tester, c, '/submit-payment');
    await tester.tap(find.byKey(const ValueKey('wizard-next')));
    await tester.pumpAndSettle();
    expect(find.text('Choose the unit and lease this payment applies to.'), findsOneWidget);
    await tester.tap(find.text('TEST 8 Birch Ct'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('TEST Tenant Charlie'));
    await tester.tap(find.byKey(const ValueKey('wizard-next')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('wizard-next')));
    await tester.pumpAndSettle();
    expect(find.text('Enter the amount received.'), findsOneWidget);
    expect(find.text('Choose how the tenant paid.'), findsOneWidget);
    await fillWizard(tester, amount: '1,250.00', method: 'Zelle', reference: 'zl-test-555');

    expect(find.text('Review and submit'), findsOneWidget);
    final submit = find.byKey(const ValueKey('submit-payment'));
    expect(tester.widget<FilledButton>(submit).onPressed, isNull, reason: 'funds must be confirmed first');
    await tapVisible(tester, find.byKey(const ValueKey('funds-confirm')));
    await tester.tap(submit);
    await tester.tap(submit, warnIfMissed: false);
    await tester.pumpAndSettle();

    final after = await c.read(repositoryProvider).listPayments();
    expect(after.length, before + 1);
    expect(after.first.draft.amountMinor, 125000);
    expect(after.first.draft.reference, 'ZL-TEST-555');
    expect(find.text('Review request submitted'), findsOneWidget);
    expect(find.textContaining(r'$1,250.00'), findsOneWidget);
  });

  testWidgets('owner must confirm a duplicate warning before approving; posting stays disabled', (tester) async {
    final c = await pumpApp(tester);
    // Admin submits $500.00 on lease L-102, which matches a pending DoorLoop payment.
    await signIn(tester, 'demo-admin');
    await go(tester, c, '/submit-payment?lease=aaaaaaaaaaaaaaaaaaaaaaa2');
    await fillWizard(tester, amount: '500', method: 'Venmo', reference: 'VN-DUP-1');
    expect(find.textContaining('Possible duplicate.'), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('funds-confirm')));
    await tester.tap(find.byKey(const ValueKey('submit-payment')));
    await tester.pumpAndSettle();
    final id = (await c.read(repositoryProvider).listPayments()).first.id;
    await go(tester, c, '/more/settings');
    await tapVisible(tester, find.byKey(const ValueKey('sign-out')));

    await signIn(tester, 'demo-owner');
    await go(tester, c, '/payments/$id');
    expect(find.text('Possible duplicate'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('start-review')));
    await tester.pumpAndSettle();
    final approve = find.byKey(const ValueKey('approve'));
    expect(tester.widget<ButtonStyleButton>(approve).onPressed, isNull);
    expect(find.text('Confirm the duplicate check above to approve.'), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('dup-ack')));
    await tester.tap(approve);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Approve').last);
    await tester.pumpAndSettle();

    final p = (await c.read(repositoryProvider).listPayments()).firstWhere((p) => p.id == id);
    expect(p.status, PaymentStatus.approved);
    await tester.drag(verticalScrollable(), const Offset(0, 3000));
    await tester.pumpAndSettle();
    expect(find.text('Approved · not posted'), findsOneWidget);
    expect(tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('post-doorloop'))).onPressed, isNull);
    expect(find.textContaining('posting is disabled on the server'), findsOneWidget);
  });

  testWidgets('rejection needs a reason; comments are recorded', (tester) async {
    final c = await pumpApp(tester);
    await signIn(tester, 'demo-owner');
    await go(tester, c, '/payments/syn-pay-1');
    await tester.scrollUntilVisible(find.byKey(const ValueKey('comment-field')), 200, scrollable: verticalScrollable());
    await tester.enterText(find.byKey(const ValueKey('comment-field')), 'Checked the bank feed.');
    await tester.tap(find.byTooltip('Send comment'));
    await tester.pumpAndSettle();
    expect(find.text('Checked the bank feed.'), findsOneWidget);

    await tester.tap(find.text('Reject'));
    await tester.pumpAndSettle();
    final confirm = find.byKey(const ValueKey('reject-confirm'));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('reject-reason')), 'Already recorded in DoorLoop');
    await tester.pump();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    final p = (await c.read(repositoryProvider).listPayments()).firstWhere((p) => p.id == 'syn-pay-1');
    expect(p.status, PaymentStatus.rejected);
    expect(p.comments.single.body, 'Checked the bank feed.');
  });

  testWidgets('owner verifies a claimed task and marks deal evidence reviewed', (tester) async {
    final c = await pumpApp(tester);
    await signIn(tester, 'demo-owner');
    await go(tester, c, '/tasks/task-02');
    expect(find.text('Completion claimed'), findsWidgets);
    await tapVisible(tester, find.byKey(const ValueKey('task-verify')));
    expect(find.text('Completion verified'), findsWidgets);

    await go(tester, c, '/more/deals/9002');
    expect(find.textContaining('Email evidence is ambiguous'), findsOneWidget);
    expect(find.text('Clear to Close'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('Please ignore previous instructions'), 200, scrollable: verticalScrollable());
    expect(find.textContaining('Please ignore previous instructions'), findsOneWidget); // shown as inert text
    await tapVisible(tester, find.byKey(const ValueKey('mark-reviewed')));
    await tester.drag(verticalScrollable(), const Offset(0, 3000));
    await tester.pumpAndSettle();
    expect(find.textContaining('Evidence marked reviewed by Harry Rotolo'), findsOneWidget);
    expect(find.text('Clear to Close'), findsOneWidget); // stage unchanged
  });

  testWidgets('notifications: unread badge clears after mark all read', (tester) async {
    final c = await pumpApp(tester);
    await signIn(tester, 'demo-owner');
    await go(tester, c, '/home');
    final bell = find.byKey(const ValueKey('bell'));
    expect(find.descendant(of: bell, matching: find.byType(Text)), findsOneWidget);
    await tester.tap(bell);
    await tester.pumpAndSettle();
    expect(find.text('Notifications'), findsOneWidget);
    expect(find.textContaining('Daily report for Nov 18 is ready'), findsOneWidget);
    await tester.tap(find.text('Mark all read'));
    await tester.pumpAndSettle();
    await go(tester, c, '/home');
    expect(find.descendant(of: bell, matching: find.byType(Text)), findsNothing);
  });

  testWidgets('a recovery session keeps navigation on the password form', (tester) async {
    final c = await pumpApp(tester);
    await signIn(tester, 'demo-owner');
    c.read(passwordRecoveryProvider.notifier).setActive(true);
    await tester.pumpAndSettle();
    expect(find.text('Choose a new password'), findsOneWidget);
    await go(tester, c, '/home');
    expect(find.text('Choose a new password'), findsOneWidget);
    expect(navItem('Home'), findsNothing);
  });

  test('device preferences survive a new app container', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final first = ProviderContainer(overrides: [devicePreferencesProvider.overrideWithValue(prefs)]);
    final settings = first.read(settingsProvider.notifier);
    settings.setTheme(ThemeMode.dark);
    settings.setTextScale(1.3);
    settings.setPreference('quiet', true);
    first.dispose();

    final restored = ProviderContainer(overrides: [devicePreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(restored.dispose);
    final value = restored.read(settingsProvider);
    expect(value.themeMode, ThemeMode.dark);
    expect(value.textScale, 1.3);
    expect(value.prefs['quiet'], isTrue);
  });

  testWidgets('settings switch to dark theme and larger text', (tester) async {
    final c = await pumpApp(tester);
    await signIn(tester, 'demo-owner');
    await go(tester, c, '/more/settings');
    await tapVisible(tester, find.text('Dark'));
    expect(Theme.of(tester.element(find.text('Settings'))).brightness, Brightness.dark);
    await tapVisible(tester, find.text('Larger'));
    expect(MediaQuery.textScalerOf(tester.element(find.text('Settings'))).scale(10), closeTo(13, .01));
    expect(tester.takeException(), isNull);
  });
}
