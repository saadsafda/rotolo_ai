import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => const AppSettings();
  void setTheme(ThemeMode m) => state = state.copyWith(themeMode: m);
  void setTextScale(double s) => state = state.copyWith(textScale: s);
  void togglePref(String key) => state = state.copyWith(prefs: {...state.prefs, key: !(state.prefs[key] ?? false)});
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

// ───────────── Notification read state ─────────────

/// Read notification IDs per user. Deliberately does not watch the session:
/// a notifier that resets itself on sign-in would rebuild mid-frame.
class ReadNotifications extends Notifier<Map<String, Set<String>>> {
  @override
  Map<String, Set<String>> build() => const {};

  void markRead(String userId, String id) => state = {...state, userId: {...?state[userId], id}};
  void markAll(String userId, Iterable<String> ids) => state = {...state, userId: {...?state[userId], ...ids}};
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
  return snap.whenData((s) => user == null ? const [] : buildNotifications(s, user: user, now: now, zone: zone));
}

Set<String> watchReadIds(WidgetRef ref) =>
    ref.watch(readNotificationsProvider)[ref.watch(sessionProvider)?.id ?? ''] ?? const {};

int watchUnread(WidgetRef ref) {
  final list = watchNotifications(ref).value ?? const <AppNotification>[];
  final read = watchReadIds(ref);
  return list.where((n) => !read.contains(n.id)).length;
}
