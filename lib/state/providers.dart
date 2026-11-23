import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ops_repository.dart';
import '../data/synthetic_repository.dart';
import '../models/app_user.dart';
import '../models/payment.dart';
import '../models/report.dart';
import '../models/sync_run.dart';

/// Fixture text, loaded from assets in `main` and overridden into the scope.
final fixtureJsonProvider = Provider<String>((ref) => throw UnimplementedError('Override fixtureJsonProvider'));

final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

class SessionNotifier extends Notifier<AppUser?> {
  @override
  AppUser? build() => null;

  void signIn(AppUser user) => state = user;
  void signOut() {
    if (state == null) return; // also called when the backend reports an expired session
    state = null;
    ref.read(repositoryProvider).signOut();
  }
}

final sessionProvider = NotifierProvider<SessionNotifier, AppUser?>(SessionNotifier.new);

/// Phase 3: synthetic only. Phase 4 swaps in a Supabase implementation here.
final repositoryProvider = Provider<OpsRepository>((ref) => SyntheticRepository(
      fixtureJson: ref.watch(fixtureJsonProvider),
      currentUser: () => ref.read(sessionProvider),
      now: ref.watch(clockProvider),
    ));

/// Bumped after any write (refresh finished, payment reviewed, task verified…). Report providers
/// depend only on this and the session, never on each other: chained async
/// providers invalidated each other mid-build after an account switch.
class DataVersion extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final dataVersionProvider = NotifierProvider<DataVersion, int>(DataVersion.new);

final reportsProvider = FutureProvider<List<ReportSummary>>((ref) {
  ref.watch(sessionProvider);
  ref.watch(dataVersionProvider);
  return ref.watch(repositoryProvider).listReports();
});

final reportProvider = FutureProvider.family<Report, String>((ref, id) {
  ref.watch(sessionProvider);
  ref.watch(dataVersionProvider); // latest/historical status changes after a refresh
  return ref.watch(repositoryProvider).getReport(id);
});

/// `null` id means the latest report.
final selectedReportProvider = FutureProvider.family<Report?, String?>((ref, id) async {
  ref.watch(sessionProvider);
  ref.watch(dataVersionProvider);
  final repo = ref.watch(repositoryProvider);
  if (id != null) return repo.getReport(id);
  final list = await repo.listReports();
  final latest = list.where((r) => repo.isSynthetic || r.dataMode == 'live').firstOrNull;
  return latest == null ? null : repo.getReport(latest.id);
});

final paymentsProvider = FutureProvider<List<PaymentSubmission>>((ref) {
  ref.watch(sessionProvider);
  ref.watch(dataVersionProvider);
  return ref.watch(repositoryProvider).listPayments();
});

final taskReviewsProvider = FutureProvider<Map<String, TaskReview>>((ref) {
  ref.watch(sessionProvider);
  ref.watch(dataVersionProvider);
  return ref.watch(repositoryProvider).taskReviews();
});

class RefreshController extends Notifier<SyncRun?> {
  StreamSubscription<SyncRun>? _sub;

  @override
  SyncRun? build() {
    ref.listen(sessionProvider, (previous, next) {
      if (previous?.id == next?.id) return;
      _sub?.cancel();
      state = null;
    });
    ref.onDispose(() => _sub?.cancel());
    return null;
  }

  bool get isRunning => state?.status.isActive ?? false;

  void start({required String mode}) {
    if (isRunning) return; // double taps are ignored; the backend also enforces one active run
    _sub?.cancel();
    state = SyncRun(id: 'queuing', status: SyncStatus.queued, progress: const [], dataMode: mode);
    _sub = ref.read(repositoryProvider).refresh(mode: mode).listen(
      (run) {
        state = run;
        if (!run.status.isActive) ref.read(dataVersionProvider.notifier).bump();
      },
      onError: (Object e) {
        state = SyncRun(
          id: state?.id ?? 'not-started',
          status: SyncStatus.failed,
          progress: state?.progress ?? const [],
          dataMode: mode,
          error: e.toString(),
        );
      },
    );
  }

  void dismiss() {
    if (!isRunning) state = null;
  }
}

final refreshControllerProvider = NotifierProvider<RefreshController, SyncRun?>(RefreshController.new);
