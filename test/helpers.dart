import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rotolo_ai_assistant/core/time_format.dart';
import 'package:rotolo_ai_assistant/main.dart';
import 'package:rotolo_ai_assistant/state/providers.dart';
import 'package:rotolo_ai_assistant/ui/router.dart';

final fixture = File('assets/fixtures/synthetic_reports.json').readAsStringSync();

/// 10:00 AM Eastern on Wed 18 Nov 2026, shortly after the 9:05 report.
final fixedNow = DateTime.utc(2026, 11, 18, 15);

/// Pumps the app on an iPhone-sized (390×844 pt) surface.
Future<ProviderContainer> pumpApp(WidgetTester tester, {Size logical = const Size(390, 844)}) async {
  initTimeZones();
  tester.view.physicalSize = logical * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      fixtureJsonProvider.overrideWithValue(fixture),
      clockProvider.overrideWithValue(() => fixedNow),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const RotoloApp()));
  await tester.pumpAndSettle();
  return container;
}

/// Fills a demo account from the chips and signs in.
Future<void> signIn(WidgetTester tester, String id) async {
  await tester.ensureVisible(find.byKey(ValueKey('signin-$id')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('signin-$id')));
  await tester.pump();
  await tester.ensureVisible(find.byKey(const ValueKey('signin-submit')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('signin-submit')));
  await tester.pumpAndSettle();
}

Future<void> go(WidgetTester tester, ProviderContainer c, String route) async {
  c.read(routerProvider).go(route);
  await tester.pumpAndSettle();
}

/// Scrolls the first vertical list until [f] is visible, then taps it.
Future<void> tapVisible(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 200, scrollable: verticalScrollable());
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Finder verticalScrollable() =>
    find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first;

Finder navItem(String label) => find.byKey(ValueKey('nav-${label.toLowerCase()}'));
