import '../models/app_user.dart';
import '../models/assistant.dart';
import '../models/payment.dart';
import '../models/report.dart';
import '../models/sync_run.dart';

/// App-facing backend. The synthetic implementation mirrors the Supabase rules
/// (RLS, RPC checks, payment state machine) so the UI behaves identically once
/// `SupabaseOpsRepository` replaces it in phase 4.
abstract class OpsRepository {
  /// True when every record this repository can return is synthetic.
  bool get isSynthetic;

  String get businessTimezone;
  int get staleAfterHours;
  bool get doorloopPostingEnabled;

  List<AppUser> get demoUsers;

  /// Throws [AuthFailure] when the credentials are not accepted.
  Future<AppUser> signIn(String email, String password);

  /// The signed-in user from a stored session (app restart), or null.
  Future<AppUser?> restoreSession();
  Future<void> signOut();

  Future<List<ReportSummary>> listReports();

  Future<List<Report>> listReportDetails();

  /// Sections the current user may not read are omitted (RLS in the real backend).
  Future<Report> getReport(String id);

  /// Starts a refresh. Throws [StateError] if a run is already active.
  Stream<SyncRun> refresh({required String mode});

  Future<List<PaymentSubmission>> listPayments();
  Future<PaymentSubmission> submitPayment(PaymentDraft draft);
  Future<PaymentSubmission> reviewPayment(String id, ReviewAction action, {String? reason});
  Future<PaymentSubmission> requestPosting(String id);
  Future<PaymentSubmission> addPaymentComment(String id, String body);

  Future<Map<String, TaskReview>> taskReviews();
  Future<TaskReview> setTaskReview(String taskId, String status, {String? notes});

  Future<Map<int, EvidenceReview>> evidenceReviews();
  Future<EvidenceReview> markEvidenceReviewed(int dealId);

  /// "Ask your portfolio": grounded answer over the user's own data.
  /// Throws [AssistantFailure] with a readable message.
  Future<AssistantReply> ask(List<ChatTurn> conversation);
}

class AuthFailure implements Exception {
  const AuthFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

enum ReviewAction { startReview, approve, reject }
