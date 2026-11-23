import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/time_format.dart';
import '../../models/payloads.dart';
import '../../models/payment.dart';
import '../../models/report.dart';
import '../../state/app_state.dart';
import '../../state/providers.dart';
import '../../state/view_models.dart';
import '../theme.dart';
import '../widgets/kit.dart';

class BalanceDetailScreen extends ConsumerWidget {
  const BalanceDetailScreen({super.key, required this.leaseId});
  final String leaseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(sessionProvider)!;
    final snap = ref.watch(snapshotProvider);
    final zone = ref.watch(repositoryProvider).businessTimezone;
    final t = context.t;
    return Column(children: [
      const DetailHeader(title: 'Balance detail', fallback: '/payments?tab=balances'),
      Expanded(
        child: AsyncBody(
          value: snap,
          builder: (s) {
            if (!user.canRead(SectionSource.doorloopRent)) {
              return const EmptyState(icon: Icons.lock_outline_rounded, title: 'Not available for your role');
            }
            final rent = s.rent;
            final match = rent?.leases.where((l) => l.leaseId == leaseId) ?? const <Lease>[];
            if (match.isEmpty) return const EmptyState(icon: Icons.search_off_rounded, title: 'Lease not found in the latest report');
            final l = LeaseView(match.first);
            final ledger = l.lease.ledger;
            final (recon, tone) = l.recon;
            final cutoff = s.latest?[SectionSource.doorloopRent]?.cutoff.asOf;
            final pending = ledger.pendingPayments ?? 0;
            final ifCleared = ledger.reconciledBalance == null || ledger.pendingPayments == null
                ? null
                : ledger.reconciledBalance! - ledger.pendingPayments!;
            final related = s.payments.where((p) => p.draft.leaseId == leaseId.toLowerCase() && p.status != PaymentStatus.rejected).toList();
            final dlPayments = rent!.payments.where((p) => p.leaseId == leaseId).toList();

            Widget line(String k, String d, int? v, String sign, {Color? color}) => ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 56),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                        Text(k, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                        Text(d, style: TextStyle(fontSize: 12, color: t.mu)),
                      ]),
                    ),
                    Text(v == null ? 'Not returned' : '$sign${Money(v).format()}',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, fontFeatures: tabular, color: v == null ? t.na : color ?? t.tx)),
                  ]),
                );

            return ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 28), children: [
              Text(l.lease.unit == null ? l.lease.propertyName : '${l.lease.propertyName} · Unit ${l.lease.unit}',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('${l.tenant} · Lease ${l.ref} · ${l.lease.isActive ? 'Active' : 'Inactive'}',
                  style: TextStyle(fontSize: 14, color: t.mu)),
              const SizedBox(height: 16),
              SurfaceCard(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text('DoorLoop balance', style: TextStyle(fontSize: 13, color: t.mu))),
                    ToneChip(recon, tone),
                  ]),
                  const SizedBox(height: 6),
                  Text(formatMinor(l.balance),
                      style: TextStyle(fontSize: 30, fontWeight: FontWeight.w600, letterSpacing: -.3, fontFeatures: tabular, color: l.balance == null ? t.na : t.tx)),
                  const SizedBox(height: 6),
                  Text(
                    'Lease balance field from DoorLoop · cutoff ${cutoff == null ? 'unknown' : formatInstant(cutoff, zone)}',
                    style: TextStyle(fontSize: 13, color: t.mu),
                  ),
                  const SizedBox(height: 8),
                  Wrap(spacing: 14, runSpacing: 4, children: [
                    for (final (k, v) in [
                      ('Overdue', l.lease.apiBalance.overdue),
                      ('Current', l.lease.apiBalance.current),
                      ('Upcoming', l.lease.apiBalance.upcoming),
                    ])
                      Text('$k ${formatMinor(v)}', style: TextStyle(fontSize: 12, color: t.mu, fontFeatures: tabular)),
                  ]),
                ]),
              ),
              const SizedBox(height: 16),
              SurfaceCard(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Column(children: [
                  line('Charges', 'Rent and fees billed', ledger.charges, ''),
                  Divider(height: 1, color: t.bd),
                  line('Cleared payments', 'Settled in DoorLoop', ledger.clearedPayments, '− '),
                  Divider(height: 1, color: t.bd),
                  line('Applied credits', 'Concessions and adjustments', ledger.appliedCredits, '− '),
                  Divider(height: 1, color: t.bd),
                  line('Returned payments', 'Previously cleared, then reversed', ledger.returnedPayments, '+ ',
                      color: (ledger.returnedPayments ?? 0) > 0 ? t.er : null),
                  Divider(height: 1, color: t.bd),
                  SizedBox(
                    height: 52,
                    child: Row(children: [
                      const Expanded(child: Text('Reconciled balance', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
                      Text(ledger.reconciledBalance == null ? 'Not computed' : Money(ledger.reconciledBalance!).format(),
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              fontFeatures: tabular,
                              color: ledger.reconciledBalance == null ? t.na : t.tx)),
                    ]),
                  ),
                ]),
              ),
              const SizedBox(height: 8),
              Text(ledger.statusLabel, style: TextStyle(fontSize: 12, color: t.mu)),
              const SizedBox(height: 16),
              if (pending > 0)
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                  decoration: BoxDecoration(
                    color: t.sf2,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: t.wa, width: 1),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(Icons.schedule_rounded, size: 20, color: t.wa),
                      const SizedBox(width: 8),
                      const Expanded(child: Text('Pending payments', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
                      Text(Money(pending).format(), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, fontFeatures: tabular)),
                    ]),
                    const SizedBox(height: 8),
                    Text(
                      'Not included in the reconciled balance.'
                      '${ifCleared == null ? '' : ' If it clears, the reconciled balance would be ${Money(ifCleared).format()}.'}',
                      style: TextStyle(fontSize: 13, height: 1.45, color: t.mu),
                    ),
                    for (final p in related)
                      TextButton(
                        onPressed: () => openRoute(context, '/payments/${p.id}'),
                        style: TextButton.styleFrom(padding: EdgeInsets.zero),
                        child: Text('View ${displayId(p.id)}'),
                      ),
                    if (related.isEmpty) const SizedBox(height: 8),
                  ]),
                )
              else
                Text('No pending payments on this lease.', style: TextStyle(fontSize: 13, color: t.mu)),
              if (dlPayments.isNotEmpty) ...[
                const SizedBox(height: 16),
                ListCard(title: 'DoorLoop payments in this report', children: [
                  for (final p in dlPayments)
                    KVRow(
                      '${p.date == null ? 'Date not returned' : fullDate(p.date!)} · ${p.depositStatus?.toLowerCase() ?? 'deposit status not returned'}',
                      formatMinor(p.amount),
                      trailing: ToneChip(
                        switch (p.classification) {
                          'cleared' => 'Cleared',
                          'pending' => 'Pending',
                          'returned' => 'Returned',
                          _ => 'Unclassified',
                        },
                        switch (p.classification) {
                          'cleared' => Tone.ok,
                          'pending' => Tone.wa,
                          'returned' => Tone.er,
                          _ => Tone.na,
                        },
                        small: true,
                      ),
                    ),
                ]),
              ],
              if (user.canSubmitPayments) ...[
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () => openRoute(context, '/submit-payment?lease=$leaseId'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  icon: Icon(Icons.add_rounded, size: 20, color: t.tx),
                  label: const Text('Submit outside payment for this lease'),
                ),
              ],
            ]);
          },
        ),
      ),
    ]);
  }
}
