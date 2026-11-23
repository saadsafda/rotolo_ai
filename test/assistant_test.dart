import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rotolo_ai_assistant/core/time_format.dart';
import 'package:rotolo_ai_assistant/data/synthetic_repository.dart';
import 'package:rotolo_ai_assistant/main.dart';
import 'package:rotolo_ai_assistant/models/assistant.dart';
import 'package:rotolo_ai_assistant/state/providers.dart';

import 'helpers.dart';

/// Stands in for the ask-portfolio function with the JSON shape it returns.
class _FakeAssistantRepo extends SyntheticRepository {
  _FakeAssistantRepo({required super.fixtureJson, required super.currentUser, super.now, this.fail = false});
  final bool fail;
  final asked = <List<ChatTurn>>[];

  @override
  Future<AssistantReply> ask(List<ChatTurn> conversation) async {
    asked.add(conversation);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (fail && asked.length == 1) throw const AssistantFailure('The assistant could not answer right now. Try again in a moment.');
    return AssistantReply.fromJson({
      'answer': 'Three leases are past due, totalling **\$3,125.50**. The largest is **TEST Former Tenant Delta**.',
      'blocks': [
        {'type': 'metric', 'label': 'Overdue rent · Nov', 'value': '\$3,125.50', 'caption': 'Across 3 of 5 leases · DoorLoop balance fields'},
        {'type': 'bars', 'bars': [
          {'label': '1A · TEST Maple', 'value': 70000, 'display': '\$700', 'highlight': false},
          {'label': 'Upper · TEST 31', 'value': 210000, 'display': '\$2.1k', 'highlight': true},
        ]},
        {'type': 'list', 'title': 'Leases with an overdue balance', 'items': [
          {'title': 'TEST Tenant Alpha', 'subtitle': 'TEST Maple Court Apartments · 1A', 'trailing': '\$700.00', 'tone': 'er',
           'route': '/payments/balance/aaaaaaaaaaaaaaaaaaaaaaa1'},
        ]},
        {'type': 'draft', 'title': 'Reminder draft · 1A', 'body': 'Hi TEST Tenant Alpha, ...', 'note': 'Not sent.'},
      ],
      'sources': [
        {'kind': 'ledger', 'title': 'DoorLoop rent snapshot', 'subtitle': 'Collected Nov 18 · Rent', 'route': '/reports/syn-rpt-20261118'},
        {'kind': 'lease', 'title': 'Lease — evil', 'subtitle': 'x', 'route': 'https://evil.example/phish'},
      ],
      'suggestions': ['Draft a reminder to TEST Tenant Alpha'],
      'data_mode': 'synthetic',
      'as_of': '2026-11-18T14:05:12Z',
    });
  }
}

Future<(ProviderContainer, _FakeAssistantRepo)> _pump(WidgetTester tester, {bool fail = false}) async {
  initTimeZones();
  tester.view.physicalSize = const Size(390, 844) * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  late _FakeAssistantRepo repo;
  final c = ProviderContainer(retry: (_, _) => null, overrides: [
    fixtureJsonProvider.overrideWithValue(fixture),
    clockProvider.overrideWithValue(() => fixedNow),
    repositoryProvider.overrideWith((ref) => repo = _FakeAssistantRepo(
        fixtureJson: fixture, currentUser: () => ref.read(sessionProvider), now: () => fixedNow, fail: fail)),
  ]);
  addTearDown(c.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const RotoloApp()));
  await tester.pumpAndSettle();
  await signIn(tester, 'demo-owner');
  return (c, repo);
}

void main() {
  testWidgets('chat opens after sign-in and renders grounded cards and sources', (tester) async {
    final (_, repo) = await _pump(tester);
    expect(find.text('Ask your portfolio'), findsOneWidget);
    expect(find.text('GROUNDED IN YOUR DATA'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('assistant-input')), 'Which tenants are late on rent?');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('assistant-send')));
    await tester.pump();
    expect(find.text('Which tenants are late on rent?'), findsWidgets);
    expect(find.text('Checking your records…'), findsOneWidget);
    await tester.pumpAndSettle();

    expect(repo.asked.single.single.text, 'Which tenants are late on rent?');
    expect(find.textContaining('Three leases are past due'), findsOneWidget);
    expect(find.text('OVERDUE RENT · NOV'), findsOneWidget);
    expect(find.text('\$3,125.50'), findsOneWidget); // metric value
    expect(find.text('\$2.1k'), findsOneWidget); // bar label
    expect(find.text('Demo data'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Copy draft'), 200, scrollable: verticalScrollable());
    expect(find.text('Not sent'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('DoorLoop rent snapshot'), 200, scrollable: verticalScrollable());
    expect(find.text('SOURCES · 2 RECORDS'), findsOneWidget);
    expect(find.text('Draft a reminder to TEST Tenant Alpha'), findsOneWidget); // follow-up suggestion
    expect(tester.takeException(), isNull);

    // Tapping a source opens the record inside the app.
    await tester.tap(find.text('DoorLoop rent snapshot'));
    await tester.pumpAndSettle();
    expect(find.text('Daily report'), findsOneWidget);
  });

  test('routes outside the app are dropped from replies', () {
    final r = AssistantReply.fromJson({
      'answer': 'x',
      'sources': [{'kind': 'lease', 'title': 't', 'subtitle': 's', 'route': 'https://evil.example/phish'}],
      'blocks': [{'type': 'list', 'title': 'l', 'items': [{'title': 'i', 'route': '//evil.example'}]}, {'type': 'unknown'}],
    });
    expect(r.sources.single.route, isNull);
    expect((r.blocks.single as ListBlock).items.single.route, isNull);
  });

  testWidgets('a failed answer shows the reason and can be retried', (tester) async {
    final (_, repo) = await _pump(tester, fail: true);
    await tester.enterText(find.byKey(const ValueKey('assistant-input')), 'What maintenance is overdue?');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('assistant-send')));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('could not answer right now'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(repo.asked.length, 2);
    expect(repo.asked.last.single.text, 'What maintenance is overdue?');
    expect(find.textContaining('Three leases are past due'), findsOneWidget);
  });

  testWidgets('conversations are per account', (tester) async {
    final (c, _) = await _pump(tester);
    await tester.enterText(find.byKey(const ValueKey('assistant-input')), 'Which tenants are late on rent?');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('assistant-send')));
    await tester.pumpAndSettle();
    await go(tester, c, '/more/settings');
    await tapVisible(tester, find.byKey(const ValueKey('sign-out')));
    await signIn(tester, 'demo-staff');
    expect(find.text('Which tenants are late on rent?'), findsNothing);
    expect(find.textContaining('what would you like to know?'), findsOneWidget);
    expect(find.text('Which deals need evidence review?'), findsWidgets); // staff prompts: deals only
    expect(find.text('Which tenants are late on rent?'), findsNothing);
  });
}
