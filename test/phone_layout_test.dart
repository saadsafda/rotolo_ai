import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rotolo_ai_assistant/state/app_state.dart';

import 'helpers.dart';

/// Visits every screen at phone size; any RenderFlex overflow or build error fails.
void main() {
  const routes = [
    '/home',
    '/reports',
    '/reports/syn-rpt-20261118',
    '/reports/syn-rpt-20261117',
    '/payments',
    '/payments?tab=balances',
    '/payments/balance/aaaaaaaaaaaaaaaaaaaaaaa2',
    '/payments/balance/aaaaaaaaaaaaaaaaaaaaaaa5',
    '/payments/syn-pay-1',
    '/payments/syn-pay-2',
    '/payments/syn-pay-3',
    '/submit-payment',
    '/submit-payment?lease=aaaaaaaaaaaaaaaaaaaaaaa3',
    '/tasks',
    '/tasks?status=overdue',
    '/tasks/task-01',
    '/tasks/task-02',
    '/more',
    '/more/deals',
    '/more/deals/9001',
    '/more/deals/9002',
    '/more/team',
    '/more/notifications',
    '/more/integrations',
    '/more/settings',
  ];

  Future<void> visitAll(WidgetTester tester, String user, {ThemeMode theme = ThemeMode.light, double scale = 1}) async {
    final c = await pumpApp(tester);
    c.read(settingsProvider.notifier)
      ..setTheme(theme)
      ..setTextScale(scale);
    await tester.pumpAndSettle();
    await signIn(tester, user);
    for (final r in routes) {
      await go(tester, c, r);
      expect(tester.takeException(), isNull, reason: '$user at $r');
    }
    // Expand every report section and switch tasks to the calendar.
    await go(tester, c, '/reports/syn-rpt-20261118');
    for (final title in ['Rent and payments', 'Maintenance', 'Team activity']) {
      final f = find.text(title);
      if (f.evaluate().isEmpty) continue;
      await tester.scrollUntilVisible(f, 200, scrollable: verticalScrollable());
      await tester.tap(f);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$user expanding $title');
    }
    if (user != 'demo-staff') {
      await go(tester, c, '/tasks');
      await tester.tap(find.text('Calendar'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$user tasks calendar');
    }
  }

  for (final user in ['demo-owner', 'demo-admin', 'demo-staff']) {
    testWidgets('all screens lay out at 390x844 as $user', (tester) => visitAll(tester, user));
  }
  testWidgets('dark theme with largest in-app text lays out as owner',
      (tester) => visitAll(tester, 'demo-owner', theme: ThemeMode.dark, scale: 1.3));
}
