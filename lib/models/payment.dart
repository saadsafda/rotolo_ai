import 'dart:typed_data';

class PaymentReceipt {
  static const maxBytes = 5 * 1024 * 1024;

  PaymentReceipt(this.bytes) {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const PaymentRuleException('Choose an image under 5 MB.');
    }
    if (_startsWith([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
      extension = 'png';
      mimeType = 'image/png';
    } else if (_startsWith([0xff, 0xd8, 0xff])) {
      extension = 'jpg';
      mimeType = 'image/jpeg';
    } else {
      throw const PaymentRuleException('Choose a JPEG or PNG receipt image.');
    }
  }

  final Uint8List bytes;
  late final String extension;
  late final String mimeType;

  bool _startsWith(List<int> signature) {
    if (bytes.length <= signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return false;
    }
    return true;
  }
}

enum PaymentStatus { submitted, underReview, approved, rejected, posting, posted, failed }

extension PaymentStatusText on PaymentStatus {
  String get key => switch (this) {
        PaymentStatus.submitted => 'submitted',
        PaymentStatus.underReview => 'under_review',
        PaymentStatus.approved => 'approved',
        PaymentStatus.rejected => 'rejected',
        PaymentStatus.posting => 'posting',
        PaymentStatus.posted => 'posted',
        PaymentStatus.failed => 'failed',
      };

  String get label => switch (this) {
        PaymentStatus.submitted => 'Submitted',
        PaymentStatus.underReview => 'Under review',
        PaymentStatus.approved => 'Approved, not posted',
        PaymentStatus.rejected => 'Rejected',
        PaymentStatus.posting => 'Posting to DoorLoop',
        PaymentStatus.posted => 'Posted to DoorLoop',
        PaymentStatus.failed => 'Posting failed',
      };
}

/// Same allowed transitions as the `payment_guard` trigger in the migration.
const paymentTransitions = <PaymentStatus, Set<PaymentStatus>>{
  PaymentStatus.submitted: {PaymentStatus.underReview, PaymentStatus.rejected},
  PaymentStatus.underReview: {PaymentStatus.approved, PaymentStatus.rejected},
  PaymentStatus.approved: {PaymentStatus.posting},
  PaymentStatus.posting: {PaymentStatus.posted, PaymentStatus.failed},
  PaymentStatus.failed: {PaymentStatus.posting, PaymentStatus.rejected},
  PaymentStatus.rejected: {},
  PaymentStatus.posted: {},
};

enum PaymentMethod {
  zelle('Zelle', 'EFT'),
  venmo('Venmo', 'EFT'),
  cashApp('Cash App', 'EFT'),
  bankTransfer('Bank transfer', 'EFT'),
  cash('Cash', 'CASH'),
  check('Check', 'CHECK'),
  moneyOrder('Money order', 'MONEY_ORDER'),
  cashiersCheck("Cashier's check", 'CASHIERS_CHECK'),
  other('Other', 'OTHER');

  const PaymentMethod(this.label, this.doorloopMethod);
  final String label;

  /// DoorLoop paymentMethod value used by workflow 02. EPAY is never offered.
  final String doorloopMethod;
}

class PaymentDraft {
  const PaymentDraft({
    required this.idempotencyKey,
    required this.leaseId,
    required this.amountMinor,
    required this.paymentDate,
    required this.method,
    required this.reference,
    required this.fundsConfirmed,
    this.currency = 'USD',
    this.propertyId,
    this.propertyName,
    this.unit,
    this.tenantName,
    this.notes,
  });

  final String idempotencyKey;
  final String leaseId;
  final int amountMinor;
  final String currency;
  final DateTime paymentDate;
  final PaymentMethod method;
  final String reference;
  final bool fundsConfirmed;
  final String? propertyId;
  final String? propertyName;
  final String? unit;
  final String? tenantName;
  final String? notes;

  String get normalizedReference => reference.trim().toUpperCase();
  String get duplicateKey => '${leaseId.toLowerCase()}|${method.doorloopMethod}|$normalizedReference';
}

class PaymentEvent {
  const PaymentEvent({required this.from, required this.to, required this.actorName, required this.at, this.reason});
  final PaymentStatus? from;
  final PaymentStatus to;
  final String actorName;
  final DateTime at;
  final String? reason;
}

class PaymentComment {
  const PaymentComment({required this.authorName, required this.body, required this.at});
  final String authorName;

  /// Untrusted user text. Displayed as plain text; never changes status.
  final String body;
  final DateTime at;
}

class PaymentSubmission {
  PaymentSubmission({
    required this.id,
    required this.draft,
    required this.submittedBy,
    required this.submittedByName,
    required this.createdAt,
    required this.status,
    required this.events,
    this.decisionReason,
    this.doorloopPaymentId,
    this.receiptPath,
    this.comments = const [],
  });

  final String id;
  final PaymentDraft draft;
  final String submittedBy;
  final String submittedByName;
  final DateTime createdAt;
  final PaymentStatus status;
  final List<PaymentEvent> events;
  final String? decisionReason;
  final String? doorloopPaymentId;
  final String? receiptPath;
  final List<PaymentComment> comments;

  PaymentSubmission withComment(PaymentComment c) => PaymentSubmission(
        id: id,
        draft: draft,
        submittedBy: submittedBy,
        submittedByName: submittedByName,
        createdAt: createdAt,
        status: status,
        events: events,
        decisionReason: decisionReason,
        doorloopPaymentId: doorloopPaymentId,
        receiptPath: receiptPath,
        comments: [...comments, c],
      );

  PaymentSubmission copyWith({required PaymentStatus status, required PaymentEvent event, String? decisionReason}) =>
      PaymentSubmission(
        id: id,
        draft: draft,
        submittedBy: submittedBy,
        submittedByName: submittedByName,
        createdAt: createdAt,
        status: status,
        events: [...events, event],
        decisionReason: decisionReason ?? this.decisionReason,
        doorloopPaymentId: doorloopPaymentId,
        receiptPath: receiptPath,
        comments: comments,
      );
}

class PaymentRuleException implements Exception {
  const PaymentRuleException(this.message);
  final String message;
  @override
  String toString() => message;
}
