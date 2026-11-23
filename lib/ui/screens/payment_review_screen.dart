import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../data/ops_repository.dart';
import '../../models/app_user.dart';
import '../../models/payment.dart';
import '../../models/report.dart';
import '../../state/app_state.dart';
import '../../state/providers.dart';
import '../../state/view_models.dart';
import '../theme.dart';
import '../widgets/kit.dart';

class PaymentReviewScreen extends ConsumerStatefulWidget {
  const PaymentReviewScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<PaymentReviewScreen> createState() => _PaymentReviewScreenState();
}

class _PaymentReviewScreenState extends ConsumerState<PaymentReviewScreen> {
  bool _busy = false;
  bool _rejecting = false;
  bool _dupAck = false;
  final _rejectNote = TextEditingController();
  final _comment = TextEditingController();

  void _openReceipt(String path) {
    final result = ref.read(repositoryProvider).readReceipt(path);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Receipt image'),
        content: FutureBuilder(
          future: result,
          builder: (context, snapshot) {
            if (snapshot.hasError) return const Text('Could not open this receipt.');
            final bytes = snapshot.data;
            if (bytes == null) return const Center(widthFactor: 2, heightFactor: 2, child: CircularProgressIndicator());
            return Image.memory(bytes, cacheWidth: 1600, fit: BoxFit.contain, errorBuilder: (_, _, _) => const Text('Could not read this image.'));
          },
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
      ),
    );
  }

  @override
  void dispose() {
    _rejectNote.dispose();
    _comment.dispose();
    super.dispose();
  }

  Future<void> _run(Future<Object?> Function() action, {String? toast}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      ref.read(dataVersionProvider.notifier).bump();
      if (toast != null && mounted) showToast(context, toast);
    } on PaymentRuleException catch (e) {
      if (mounted) showToast(context, e.message, icon: Icons.error_outline_rounded);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _approve(PaymentSubmission p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Approve this payment?'),
        content: Text(
          'Approve ${Money(p.draft.amountMinor).format()} for ${paymentWhere(p.draft)}, reference ${p.draft.reference}.\n\n'
          'Approval does not post to DoorLoop. Posting is a separate step that runs lease, amount and duplicate checks first.',
          style: const TextStyle(height: 1.45),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
              child: const Text('Approve')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => ref.read(repositoryProvider).reviewPayment(p.id, ReviewAction.approve),
        toast: '${displayId(p.id)} approved. Posting is a separate step.');
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(sessionProvider)!;
    final snap = ref.watch(snapshotProvider);
    return Column(children: [
      DetailHeader(title: 'Payment review', fallback: '/payments', trailing: HeaderId(displayId(widget.id))),
      Expanded(
        child: AsyncBody(
          value: snap,
          builder: (s) {
            final match = s.payments.where((p) => p.id == widget.id);
            if (match.isEmpty) {
              return const EmptyState(icon: Icons.search_off_rounded, title: 'Submission not found', body: 'It may belong to another user.');
            }
            final p = match.first;
            final dup = duplicateFor(
                leaseId: p.draft.leaseId,
                amountMinor: p.draft.amountMinor,
                paymentDate: p.draft.paymentDate,
                submissions: s.payments,
                rent: s.rent,
                excludeId: p.id);
            final reviewer = user.canReviewPayments;
            final bar = reviewer &&
                const {PaymentStatus.submitted, PaymentStatus.underReview, PaymentStatus.approved, PaymentStatus.failed}.contains(p.status);
            return Column(children: [
              Expanded(child: _content(p, dup, user)),
              if (bar) _actionBar(p, dup, user),
            ]);
          },
        ),
      ),
    ]);
  }

  Widget _content(PaymentSubmission p, DuplicateHint? dup, AppUser user) {
    final t = context.t;
    final d = p.draft;
    final zone = ref.read(repositoryProvider).businessTimezone;
    final now = ref.read(clockProvider)();
    final look = paymentLook(p.status);
    final lastReason = p.events.lastWhere((e) => e.reason != null, orElse: () => p.events.last).reason;
    return ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 24), children: [
      SurfaceCard(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('Status', style: TextStyle(fontSize: 13, color: t.mu))),
            ToneChip(look.label, look.tone, icon: look.icon),
          ]),
          const SizedBox(height: 14),
          _Tracker(status: p.status),
          ...switch (p.status) {
            PaymentStatus.approved => [_note('Approved. Not yet in DoorLoop. Posting is a separate step.', t.mu)],
            PaymentStatus.posting => [_note('Waiting for DoorLoop to confirm…', t.ac)],
            PaymentStatus.posted => [_note('DoorLoop confirmed this payment on the lease ledger${p.doorloopPaymentId == null ? '' : ' (${p.doorloopPaymentId})'}.', t.ok)],
            PaymentStatus.rejected => [_note('Rejected. Nothing was sent to DoorLoop.', t.mu)],
            _ => const <Widget>[],
          },
        ]),
      ),
      if (p.status == PaymentStatus.posting) ...[
        const SizedBox(height: 16),
        AlertPanel(tone: Tone.wa, icon: Icons.help_outline_rounded, title: 'Do not submit this payment again', children: [
          Text('If DoorLoop does not confirm, the server checks the lease ledger before any retry, so one payment is never recorded twice.',
              style: TextStyle(fontSize: 14, height: 1.5, color: t.tx)),
        ]),
      ],
      if (p.status == PaymentStatus.failed) ...[
        const SizedBox(height: 16),
        AlertPanel(tone: Tone.er, icon: Icons.error_rounded, title: 'Posting failed', children: [
          Text(lastReason ?? 'DoorLoop did not record this payment.', style: TextStyle(fontSize: 14, height: 1.5, color: t.tx)),
        ]),
      ],
      if (p.status == PaymentStatus.rejected && p.decisionReason != null) ...[
        const SizedBox(height: 16),
        NoticeBox(tone: Tone.na, icon: Icons.comment_outlined, title: 'Reason:', text: p.decisionReason!),
      ],
      const SizedBox(height: 16),
      SurfaceCard(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Proposed payment', style: TextStyle(fontSize: 13, color: t.mu)),
          const SizedBox(height: 4),
          Text.rich(
            TextSpan(children: [
              TextSpan(text: Money(d.amountMinor).format()),
              TextSpan(text: ' ${d.currency}', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: t.mu)),
            ]),
            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w600, letterSpacing: -.3, fontFeatures: tabular),
          ),
          const SizedBox(height: 12),
          _grid([
            ('Method', '${d.method.label} (DoorLoop ${d.method.doorloopMethod})', false),
            ('Paid on', fullDate(d.paymentDate), false),
            ('Reference', d.reference, true),
            ('Submitted', '${p.submittedByName} · ${whenIn(p.createdAt, now, zone)}', false),
          ]),
          if (d.notes != null) ...[
            const SizedBox(height: 10),
            Divider(height: 1, color: t.bd),
            const SizedBox(height: 10),
            Text('“${d.notes}”', style: const TextStyle(fontSize: 14, height: 1.45)),
          ],
        ]),
      ),
      if (dup != null && p.status != PaymentStatus.posted && p.status != PaymentStatus.rejected) ...[
        const SizedBox(height: 16),
        AlertPanel(tone: Tone.wa, icon: Icons.content_copy_rounded, title: 'Possible duplicate', children: [
          Text(dup.why, style: TextStyle(fontSize: 14, height: 1.5, color: t.tx)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: t.sf, borderRadius: BorderRadius.circular(10)),
            child: Text(dup.what, style: mono(context)),
          ),
          if (user.canReviewPayments && p.status == PaymentStatus.underReview)
            InkWell(
              key: const ValueKey('dup-ack'),
              onTap: () => setState(() => _dupAck = !_dupAck),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Row(children: [
                  Icon(_dupAck ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded, size: 24, color: t.wa),
                  const SizedBox(width: 10),
                  Expanded(child: Text('I checked DoorLoop and this is a separate payment', style: TextStyle(fontSize: 14, color: t.tx))),
                ]),
              ),
            ),
        ]),
      ],
      const SizedBox(height: 16),
      ListCard(title: 'Evidence', children: [
        if (p.receiptPath case final path?)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(onPressed: () => _openReceipt(path), icon: const Icon(Icons.image_outlined),
                label: const Text('Open receipt image')),
          )
        else
          _evidenceRow(Icons.image_outlined, 'Receipt image', 'None attached', Tone.na),
        _evidenceRow(Icons.tag_rounded, 'Reference number', 'Not verified', Tone.wa),
        _evidenceRow(Icons.account_balance_outlined, 'Bank deposit match', 'Unavailable', Tone.na),
        _evidenceRow(Icons.how_to_reg_outlined, 'Submitter says funds received', d.fundsConfirmed ? 'Attested' : 'Not attested', Tone.na),
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 12),
          child: Text('A receipt or attestation alone is not verified payment evidence. Check the bank or processor record.',
              style: TextStyle(fontSize: 12, height: 1.4, color: t.mu)),
        ),
      ]),
      const SizedBox(height: 16),
      ListCard(title: 'Lease and deposit mapping', children: [
        KVRow('Property and unit', paymentWhere(d), stacked: true),
        KVRow(
          'Lease',
          '${d.leaseId} · ${d.tenantName ?? 'Tenant not provided'}',
          stacked: true,
          valueStyle: const TextStyle(fontSize: 14),
          onTap: user.canRead(SectionSource.doorloopRent) ? () => openRoute(context, '/payments/balance/${d.leaseId}') : null,
          trailing: user.canRead(SectionSource.doorloopRent) ? Icon(Icons.chevron_right_rounded, size: 20, color: t.ac) : null,
        ),
        KVRow('Deposit account', 'Not mapped yet', stacked: true, trailing: const ToneChip('Unverified', Tone.na)),
      ]),
      const SizedBox(height: 16),
      SurfaceCard(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Reviewer comments', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          for (final c in p.comments) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(color: t.sf2, borderRadius: BorderRadius.circular(12)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text.rich(TextSpan(children: [
                  TextSpan(text: c.authorName, style: TextStyle(fontWeight: FontWeight.w600, color: t.tx)),
                  TextSpan(text: ' · ${whenIn(c.at, now, zone)}'),
                ]), style: TextStyle(fontSize: 12, color: t.mu)),
                const SizedBox(height: 4),
                Text(c.body, style: const TextStyle(fontSize: 14, height: 1.45)),
              ]),
            ),
          ],
          if (p.comments.isEmpty) ...[
            const SizedBox(height: 6),
            Text('No comments yet.', style: TextStyle(fontSize: 13, color: t.mu)),
          ],
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: TextField(
                key: const ValueKey('comment-field'),
                controller: _comment,
                maxLength: 2000,
                buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                style: const TextStyle(fontSize: 14),
                decoration: const InputDecoration(hintText: 'Add a comment', contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12)),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: 'Send comment',
              style: IconButton.styleFrom(
                backgroundColor: t.acs,
                foregroundColor: t.ac,
                fixedSize: const Size(44, 44),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _busy
                  ? null
                  : () {
                      final text = _comment.text.trim();
                      if (text.isEmpty) return;
                      _run(() async {
                        await ref.read(repositoryProvider).addPaymentComment(p.id, text);
                        _comment.clear();
                        return null;
                      });
                    },
              icon: const Icon(Icons.send_rounded, size: 20),
            ),
          ]),
        ]),
      ),
      const SizedBox(height: 16),
      SurfaceCard(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Audit timeline', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Timeline([
            for (final e in p.events.reversed)
              TimelineEntry(
                e.from == null
                    ? 'Submitted by ${e.actorName}'
                    : '${paymentLook(e.to).label} · ${e.actorName}${e.reason == null ? '' : '\n${e.reason}'}',
                whenIn(e.at, now, zone),
              ),
          ]),
          Divider(height: 16, color: t.bd),
          Text('Request key', style: TextStyle(fontSize: 12, color: t.mu)),
          Text(d.idempotencyKey, style: mono(context, size: 12, color: t.mu)),
        ]),
      ),
      if (!user.canReviewPayments) ...[
        const SizedBox(height: 16),
        const NoticeBox(
          tone: Tone.na,
          icon: Icons.lock_outline_rounded,
          title: 'View only.',
          text: 'Only the owner can approve, reject or post payments.',
        ),
      ],
    ]);
  }

  Widget _note(String text, Color color) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Text(text, style: TextStyle(fontSize: 13, height: 1.45, color: color)),
      );

  Widget _grid(List<(String, String, bool)> cells) {
    final t = context.t;
    Widget cell((String, String, bool) c) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c.$1, style: TextStyle(fontSize: 12, color: t.mu)),
          const SizedBox(height: 2),
          Text(c.$2, style: c.$3 ? mono(context) : const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
        ]);
    return Column(children: [
      for (var i = 0; i < cells.length; i += 2) ...[
        if (i > 0) const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: cell(cells[i])),
          const SizedBox(width: 16),
          Expanded(child: i + 1 < cells.length ? cell(cells[i + 1]) : const SizedBox()),
        ]),
      ],
    ]);
  }

  Widget _evidenceRow(IconData icon, String label, String chip, Tone tone) => SizedBox(
        height: 52,
        child: Row(children: [
          Icon(icon, size: 20, color: context.t.mu),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
          ToneChip(chip, tone),
        ]),
      );

  Widget _actionBar(PaymentSubmission p, DuplicateHint? dup, AppUser user) {
    final t = context.t;
    final repo = ref.read(repositoryProvider);
    final own = p.submittedBy == user.id;
    final dupBlock = dup != null && !_dupAck && p.status == PaymentStatus.underReview;
    final rejectOk = _rejectNote.text.trim().length > 3;
    final rejectButton = OutlinedButton.icon(
      onPressed: _busy ? null : () => setState(() => _rejecting = true),
      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52), foregroundColor: t.er),
      icon: Icon(Icons.close_rounded, size: 20, color: t.er),
      label: const Text('Reject'),
    );
    final List<Widget> children;
    if (_rejecting) {
      children = [
        const Text('Reason for rejection (required)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('reject-reason'),
          controller: _rejectNote,
          autofocus: true,
          maxLines: 2,
          onChanged: (_) => setState(() {}),
          style: const TextStyle(fontSize: 14),
          decoration: const InputDecoration(hintText: 'Shared with the submitter'),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => setState(() {
                _rejecting = false;
                _rejectNote.clear();
              }),
              child: const Text('Cancel'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              key: const ValueKey('reject-confirm'),
              onPressed: rejectOk && !_busy
                  ? () {
                      final reason = _rejectNote.text.trim();
                      _run(() => repo.reviewPayment(p.id, ReviewAction.reject, reason: reason), toast: '${displayId(p.id)} rejected.')
                          .then((_) {
                        if (mounted) {
                          setState(() {
                            _rejecting = false;
                            _rejectNote.clear();
                          });
                        }
                      });
                    }
                  : null,
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48), backgroundColor: t.er, foregroundColor: Colors.white),
              child: const Text('Reject'),
            ),
          ),
        ]),
      ];
    } else {
      children = switch (p.status) {
        PaymentStatus.submitted => [
            Row(children: [
              Expanded(child: rejectButton),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: FilledButton(
                  key: const ValueKey('start-review'),
                  onPressed: _busy ? null : () => _run(() => repo.reviewPayment(p.id, ReviewAction.startReview)),
                  child: const Text('Start review'),
                ),
              ),
            ]),
          ],
        PaymentStatus.underReview => [
            Row(children: [
              Expanded(child: rejectButton),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('approve'),
                  onPressed: _busy || dupBlock || own ? null : () => _approve(p),
                  style: FilledButton.styleFrom(backgroundColor: t.ok, foregroundColor: Colors.white),
                  icon: const Icon(Icons.check_rounded, size: 20),
                  label: const Text('Approve'),
                ),
              ),
            ]),
            if (own)
              _barCaption('You submitted this payment, so another reviewer must approve it.', t.mu)
            else if (dupBlock)
              _barCaption('Confirm the duplicate check above to approve.', t.wa),
          ],
        _ => [
            // Approved or failed: posting is gated on the server flag.
            FilledButton.icon(
              key: const ValueKey('post-doorloop'),
              onPressed: repo.doorloopPostingEnabled && !_busy && user.role == AppRole.owner
                  ? () => _run(() => repo.requestPosting(p.id))
                  : null,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), backgroundColor: t.nv, foregroundColor: Colors.white),
              icon: const Icon(Icons.upload_rounded, size: 20),
              label: Text(p.status == PaymentStatus.failed ? 'Retry posting' : 'Post to DoorLoop'),
            ),
            if (!repo.doorloopPostingEnabled)
              _barCaption('DoorLoop posting is disabled on the server until the posting workflow is verified.', t.mu),
          ],
      };
    }
    return StickyBar(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children));
  }

  Widget _barCaption(String text, Color color) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: color)),
      );
}

class _Tracker extends StatelessWidget {
  const _Tracker({required this.status});
  final PaymentStatus status;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final look = paymentLook(status);
    final idx = look.step;
    final (ring, fg) = t.tone(look.tone);
    final names = [
      'Submitted',
      'Under review',
      status == PaymentStatus.rejected ? 'Rejected' : 'Approved',
      'Posting',
      status == PaymentStatus.failed ? 'Failed' : 'Posted',
    ];
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var i = 0; i < 5; i++)
        Expanded(
          child: Builder(builder: (context) {
            final skip = status == PaymentStatus.rejected && i > 2;
            final done = i < idx || status == PaymentStatus.posted && i == idx;
            final cur = i == idx && status != PaymentStatus.posted;
            final dot = skip ? t.bd : done ? t.ok : cur ? fg : t.bd;
            return Column(children: [
              SizedBox(
                height: 34,
                width: double.infinity,
                child: Stack(alignment: Alignment.center, children: [
                  if (i < 4)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 16,
                      child: FractionallySizedBox(
                        alignment: Alignment.centerRight,
                        widthFactor: .5,
                        child: Container(height: 2, color: done && !skip ? t.ok : t.bd),
                      ),
                    ),
                  if (i > 0)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 16,
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: .5,
                        child: Container(height: 2, color: (done || cur) && !skip ? t.ok : t.bd),
                      ),
                    ),
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: dot,
                      shape: BoxShape.circle,
                      boxShadow: cur ? [BoxShadow(color: ring, spreadRadius: 4)] : null,
                    ),
                    child: Icon(
                      skip ? Icons.remove_rounded : done ? Icons.check_rounded : cur ? look.icon : null,
                      size: 16,
                      color: (done || cur) && !skip ? Colors.white : t.mu,
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 4),
              Text(names[i],
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, height: 1.2, color: cur ? t.tx : t.mu, fontWeight: cur ? FontWeight.w600 : FontWeight.w500)),
            ]);
          }),
        ),
    ]);
  }
}
