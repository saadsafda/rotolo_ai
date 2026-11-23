import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/firebase_options.dart';
import 'core/notification_routing.dart';
import 'core/report_push.dart';
import 'core/time_format.dart';
import 'data/supabase_repository.dart';
import 'state/app_state.dart';
import 'state/providers.dart';
import 'ui/router.dart';
import 'ui/theme.dart';

/// Live backend only when built with `--dart-define-from-file=config/supabase.json`.
/// That file holds the project URL and the publishable key, both public by design.
/// The service-role key never belongs in the app.
const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const _supabaseKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initTimeZones();
  if (_supabaseUrl.isEmpty || _supabaseKey.isEmpty) {
    final fixtures = await rootBundle.loadString('assets/fixtures/synthetic_reports.json');
    runApp(ProviderScope(
      // Surface errors immediately instead of silently retrying.
      retry: (_, _) => null,
      overrides: [fixtureJsonProvider.overrideWithValue(fixtures)],
      child: const RotoloApp(),
    ));
    return;
  }

  await Supabase.initialize(url: _supabaseUrl, publishableKey: _supabaseKey);
  final client = Supabase.instance.client;
  ReportPush? push;
  if (!kIsWeb) {
    final options = switch (defaultTargetPlatform) {
      TargetPlatform.android => rotoloAndroidFirebase,
      TargetPlatform.iOS => rotoloIosFirebase,
      _ => null,
    };
    if (options != null) {
      try {
        await Firebase.initializeApp(options: options);
        push = ReportPush(client, await SharedPreferences.getInstance(),
            defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android');
      } catch (_) {
        debugPrint('Unable to initialize report notifications.');
      }
    }
  }
  final repo = SupabaseOpsRepository(client, push: push);
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [repositoryProvider.overrideWithValue(repo), reportPushProvider.overrideWithValue(push)],
  );
  // Resume a stored session; if the profile is gone or inactive, sign out.
  try {
    final user = await repo.restoreSession();
    if (user != null) {
      container.read(sessionProvider.notifier).signIn(user);
    } else if (client.auth.currentSession != null) {
      await client.auth.signOut();
    }
  } catch (_) {
    // Offline or schema missing: start at sign-in.
  }
  client.auth.onAuthStateChange.listen((change) {
    if (change.event == AuthChangeEvent.signedOut) container.read(sessionProvider.notifier).signOut();
  });
  final notifications = push;
  if (notifications != null) {
    container.listen(sessionProvider, (_, user) {
      if (user != null) unawaited(notifications.refresh(user.id));
    }, fireImmediately: true);
    FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      final user = client.auth.currentUser;
      if (user != null) unawaited(notifications.refresh(user.id, updatedToken: token));
    });
    void openNotification(RemoteMessage message) {
      final route = routeForNotification(message.data);
      if (route != null) container.read(routerProvider).go(route);
    }
    FirebaseMessaging.onMessageOpenedApp.listen(openNotification);
    FirebaseMessaging.onMessage.listen((_) => container.read(dataVersionProvider.notifier).bump());
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final message = await FirebaseMessaging.instance.getInitialMessage();
        if (message != null) openNotification(message);
      } catch (_) {}
    });
  }
  runApp(UncontrolledProviderScope(container: container, child: const RotoloApp()));
}

class RotoloApp extends ConsumerWidget {
  const RotoloApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return MaterialApp.router(
      title: 'Real Estate AI',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: settings.themeMode,
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) {
        // In-app text size multiplies the system setting (capped so layouts hold).
        final system = MediaQuery.textScalerOf(context).scale(1);
        final scale = (system * settings.textScale).clamp(1.0, 2.0);
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        );
      },
    );
  }
}
