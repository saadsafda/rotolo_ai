import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/app_user.dart';
import '../state/providers.dart';
import 'screens/assistant_screen.dart';
import 'screens/balance_detail_screen.dart';
import 'screens/deal_detail_screen.dart';
import 'screens/deals_screen.dart';
import 'screens/home_screen.dart';
import 'screens/integrations_screen.dart';
import 'screens/more_screen.dart';
import 'screens/notifications_screen.dart';
import 'screens/payment_review_screen.dart';
import 'screens/payments_screen.dart';
import 'screens/report_detail_screen.dart';
import 'screens/reports_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/sign_in_screen.dart';
import 'screens/submit_payment_screen.dart';
import 'screens/task_detail_screen.dart';
import 'screens/tasks_screen.dart';
import 'screens/team_screen.dart';
import 'shell.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();

final routerProvider = Provider<GoRouter>((ref) {
  final session = ValueNotifier<AppUser?>(ref.read(sessionProvider));
  final recovery = ValueNotifier(ref.read(passwordRecoveryProvider));
  ref.listen(passwordRecoveryProvider, (_, active) => recovery.value = active);
  ref.onDispose(recovery.dispose);
  // A deliberate sign-out returns to a clean sign-in; only deep links opened
  // while signed out are kept for after sign-in.
  var signedOut = false;
  ref.listen(sessionProvider, (prev, next) {
    signedOut = prev != null && next == null;
    session.value = next;
  });
  ref.onDispose(session.dispose);

  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/assistant',
    refreshListenable: Listenable.merge([session, recovery]),
    redirect: (context, state) {
      final signedIn = session.value != null;
      final atSignIn = state.matchedLocation == '/sign-in';
      if (recovery.value) return atSignIn ? null : '/sign-in';
      if (!signedIn) {
        if (atSignIn) return null;
        if (signedOut) {
          signedOut = false;
          return '/sign-in';
        }
        // Keep the deep link (e.g. from a push notification) for after sign-in.
        return Uri(path: '/sign-in', queryParameters: {'from': state.uri.toString()}).toString();
      }
      if (atSignIn) {
        final from = state.uri.queryParameters['from'];
        return (from != null && from.startsWith('/') && !from.startsWith('//')) ? from : '/assistant';
      }
      return null;
    },
    routes: [
      GoRoute(path: '/sign-in', builder: (_, _) => const SignInScreen()),
      // Full-screen flow without the tab bar.
      GoRoute(
        path: '/submit-payment',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => SubmitPaymentScreen(leaseId: s.uri.queryParameters['lease']),
      ),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/assistant', builder: (_, _) => const AssistantScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/home', builder: (_, _) => const HomeScreen())]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/reports',
              builder: (_, _) => const ReportsScreen(),
              routes: [GoRoute(path: ':id', builder: (_, s) => ReportDetailScreen(reportId: s.pathParameters['id']!))],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/payments',
              builder: (_, s) => PaymentsScreen(initialTab: s.uri.queryParameters['tab']),
              routes: [
                GoRoute(path: 'balance/:leaseId', builder: (_, s) => BalanceDetailScreen(leaseId: s.pathParameters['leaseId']!)),
                GoRoute(path: ':id', builder: (_, s) => PaymentReviewScreen(id: s.pathParameters['id']!)),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/tasks',
              builder: (_, s) => TasksScreen(initialStatus: s.uri.queryParameters['status']),
              routes: [GoRoute(path: ':id', builder: (_, s) => TaskDetailScreen(taskId: s.pathParameters['id']!))],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/more',
              builder: (_, _) => const MoreScreen(),
              routes: [
                GoRoute(
                  path: 'deals',
                  builder: (_, _) => const DealsScreen(),
                  routes: [
                    GoRoute(path: ':id', builder: (_, s) => DealDetailScreen(dealId: int.tryParse(s.pathParameters['id']!) ?? -1)),
                  ],
                ),
                GoRoute(path: 'team', builder: (_, _) => const TeamScreen()),
                GoRoute(path: 'notifications', builder: (_, _) => const NotificationsScreen()),
                GoRoute(path: 'integrations', builder: (_, _) => const IntegrationsScreen()),
                GoRoute(path: 'settings', builder: (_, _) => const SettingsScreen()),
              ],
            ),
          ]),
        ],
      ),
    ],
  );
});
