import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/payloads.dart';
import '../models/payment.dart';
import '../models/report.dart';
import '../models/sync_run.dart';
import 'providers.dart';
import 'view_models.dart';

// ───────────── Device preferences (kept on this device only) ─────────────

class AppSettings {
  const AppSettings({this.themeMode = ThemeMode.light, this.textScale = 1.0, this.prefs = defaultPrefs});
  final ThemeMode themeMode;
  final double textScale; // 1.0 Default · 1.15 Large · 1.3 Larger
  final Map<String, bool> prefs;

  static const defaultPrefs = {'reports': true, 'payments': true, 'tasks': true, 'sync': true, 'quiet': false};

  AppSettings copyWith({ThemeMode? themeMode, double? textScale, Map<String, bool>? prefs}) => AppSettings(
        themeMode: themeMode ?? this.themeMode,
        textScale: textScale ?? this.textScale,
        prefs: prefs ?? this.prefs,
      );
}

final devicePreferencesProvider = Provider<SharedPreferences?>((ref) => null);

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    final saved = ref.watch(devicePreferencesProvider);
    return AppSettings(
      themeMode: ThemeMode.values.firstWhere(
        (mode) => mode.name == saved?.getString('rotolo-theme'),
        orElse: () => ThemeMode.light,
      ),
      textScale: saved?.getDouble('rotolo-text-scale') ?? 1.0,
      prefs: {for (final entry in AppSettings.defaultPrefs.entries)
        entry.key: saved?.getBool('rotolo-notify-${entry.key}') ?? entry.value},
    );
  }

  void setTheme(ThemeMode mode) {
    state = state.copyWith(themeMode: mode);
    unawaited(ref.read(devicePreferencesProvider)?.setString('rotolo-theme', mode.name));
  }

  void setTextScale(double scale) {
    state = state.copyWith(textScale: scale);
    unawaited(ref.read(devicePreferencesProvider)?.setDouble('rotolo-text-scale', scale));
  }

  void setPreference(String key, bool value) {
    state = state.copyWith(prefs: {...state.prefs, key: value});
    unawaited(ref.read(devicePreferencesProvider)?.setBool('rotolo-notify-$key', value));
  }

  void togglePref(String key) => setPreference(key, !(state.prefs[key] ?? false));
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

// ───────────── Notification read state ─────────────

/// Read notification IDs per user. Deliberately does not watch the session:
/// a notifier that resets itself on sign-in would rebuild mid-frame.
class ReadNotifications extends Notifier<Map<String, Set<String>>> {
  @override
  Map<String, Set<String>> build() => const {};

  void markRead(String userId, String id) => markAll(userId, [id]);

  void markAll(String userId, Iterable<String> ids) {
    final saved = ref.read(devicePreferencesProvider);
    final key = 'rotolo-read-$userId';
    final previous = state[userId] ?? saved?.getStringList(key)?.toSet() ?? const <String>{};
    final seen = {...ids, ...previous}.take(250).toSet();
    state = {...state, userId: seen};
    unawaited(saved?.setStringList(key, seen.toList()));
  }
}

final readNotificationsProvider = NotifierProvider<ReadNotifications, Map<String, Set<String>>>(ReadNotifications.new);

// ───────────── Repository-backed data ─────────────

final evidenceReviewsProvider = FutureProvider<Map<int, EvidenceReview>>((ref) {
  ref.watch(sessionProvider);
  ref.watch(dataVersionProvider);
  return ref.watch(repositoryProvider).evidenceReviews();
});

/// Every report the user can read, newest first (history, team comparisons).
final allReportsProvider = FutureProvider<List<Report>>((ref) {
  ref.watch(sessionProvider);
  ref.watch(dataVersionProvider);
  return ref.watch(repositoryProvider).listReportDetails();
});

/// Everything the home screen, notifications and badges are derived from.
class Snapshot {
  Snapshot({
    required this.reports,
    required this.payments,
    required this.taskReviews,
    required this.evidenceReviews,
  });
  final List<Report> reports;
  final List<PaymentSubmission> payments;
  final Map<String, TaskReview> taskReviews;
  final Map<int, EvidenceReview> evidenceReviews;

  Report? get latest => reports.isEmpty ? null : reports.first;
  T? payload<T>(SectionSource s, T Function(Map<String, dynamic>) parse) {
    final sec = latest?[s];
    if (sec == null || !sec.isAvailable) return null;
    return parse(sec.payload);
  }

  DealsPayload? get deals => payload(SectionSource.fubDeals, DealsPayload.new);
  EmailEvidencePayload? get evidence => payload(SectionSource.emailEvidence, EmailEvidencePayload.new);
  RentPayload? get rent => payload(SectionSource.doorloopRent, RentPayload.new);
  TasksPayload? get tasks => payload(SectionSource.doorloopTasks, TasksPayload.new);
  StaffActivityPayload? get staff => payload(SectionSource.timeDoctor, StaffActivityPayload.new);
}

/// Loads straight from the repository. Like the other data providers it depends
/// only on the session and [dataVersionProvider], never on another async
/// provider: chained async providers invalidate each other mid-build after an
/// account switch.
final snapshotProvider = FutureProvider<Snapshot>((ref) async {
  final user = ref.watch(sessionProvider);
  ref.watch(dataVersionProvider);
  final repo = ref.watch(repositoryProvider);
  return Snapshot(
    reports: [
      for (final report in await repo.listReportDetails())
        if (repo.isSynthetic || report.summary.dataMode == 'live') report,
    ],
    payments: user != null && user.canSeePayments ? await repo.listPayments() : <PaymentSubmission>[],
    taskReviews: await repo.taskReviews(),
    evidenceReviews: await repo.evidenceReviews(),
  );
});

// Notifications are derived in the widget from the snapshot (no provider chain).

AsyncValue<List<AppNotification>> watchNotifications(WidgetRef ref) {
  final snap = ref.watch(snapshotProvider);
  final user = ref.watch(sessionProvider);
  final zone = ref.watch(repositoryProvider).businessTimezone;
  final now = ref.watch(clockProvider)();
  final prefs = ref.watch(settingsProvider).prefs;
  return snap.whenData((s) => user == null ? const [] : [
    for (final item in buildNotifications(s, user: user, now: now, zone: zone))
      if (prefs[item.category.toLowerCase()] ?? true) item,
  ]);
}

Set<String> watchReadIds(WidgetRef ref) {
  final userId = ref.watch(sessionProvider)?.id;
  if (userId == null) return const {};
  return ref.watch(readNotificationsProvider)[userId] ??
      ref.watch(devicePreferencesProvider)?.getStringList('rotolo-read-$userId')?.toSet() ??
      const {};
}

int watchUnread(WidgetRef ref) {
  final list = watchNotifications(ref).value ?? const <AppNotification>[];
  final read = watchReadIds(ref);
  return list.where((n) => !read.contains(n.id)).length;
}
