import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/time_format.dart';
import '../../models/app_user.dart';
import '../../models/payment.dart';
import '../../models/report.dart';
import '../../state/app_state.dart';
import '../../state/providers.dart';
import '../../state/view_models.dart';
import '../theme.dart';
import '../widgets/kit.dart';

enum _PayFilter { needsAction, inPosting, done, all }

class PaymentsScreen extends ConsumerStatefulWidget {
  const PaymentsScreen({super.key, this.initialTab});
  final String? initialTab;
  @override
  ConsumerState<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends ConsumerState<PaymentsScreen> {
  late bool _balances = widget.initialTab == 'balances';
  _PayFilter _filter = _PayFilter.needsAction;
  String _query = '';
  String? _property;

  @override
  void didUpdateWidget(covariant PaymentsScreen old) {
    super.didUpdateWidget(old);
    if (widget.initialTab != old.initialTab && widget.initialTab != null) _balances = widget.initialTab == 'balances';
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(sessionProvider)!;
    final snap = ref.watch(snapshotProvider);
    final repo = ref.watch(repositoryProvider);
    final now = ref.watch(clockProvider)();
    final t = context.t;
    final canBalances = user.canRead(SectionSource.doorloopRent);
    final balances = !user.canSeePayments || (_balances && canBalances);
    return AsyncBody(
      value: snap,
      builder: (s) {
        final rentSec = s.latest?[SectionSource.doorloopRent];
        final at = rentSec?.collectedAt;
        final stale = at == null || now.difference(at) > Duration(hours: repo.staleAfterHours);
        return ListView(padding: const EdgeInsets.only(top: 8, bottom: 28), children: [
          PageTitle(
            'Payments',
            subtitleWidget: rentSec == null
                ? null
                : Row(children: [
                    Icon(stale ? Icons.history_rounded : Icons.cloud_done_outlined, size: 14, color: stale ? t.wa : t.ok),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text('DoorLoop · ${stale ? 'Stale · ' : 'Synced '}${whenIn(at, now, repo.businessTimezone)}',
                          style: TextStyle(fontSize: 13, color: t.mu)),
                    ),
                  ]),
          ),
          if (user.canSubmitPayments) ...[
            const SizedBox(height: 14),
            Padding(
              padding: pagePad,
              child: FilledButton.icon(
                key: const ValueKey('new-payment'),
                onPressed: () => openRoute(context, '/submit-payment'),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                icon: const Icon(Icons.add_rounded, size: 20),
                label: const Text('Submit outside payment'),
              ),
            ),
          ],
          if (user.canSeePayments && canBalances) ...[
            const SizedBox(height: 14),
            Padding(
              padding: pagePad,
              child: Segmented<bool>(
                options: const [(false, 'Approvals'), (true, 'Balances')],
                selected: balances,
                onSelected: (v) => setState(() => _balances = v),
              ),
            ),
          ],
          const SizedBox(height: 14),
          if (balances) ..._balanceList(s, rentSec) else ..._approvals(s, user),
        ]);
      },
    );
  }

  List<Widget> _approvals(Snapshot s, AppUser user) {
    final t = context.t;
    bool match(PaymentSubmission p) => switch (_filter) {
          _PayFilter.needsAction => needsReviewerAction(p.status),
          _PayFilter.inPosting => p.status == PaymentStatus.approved || p.status == PaymentStatus.posting,
          _PayFilter.done => p.status == PaymentStatus.posted || p.status == PaymentStatus.rejected,
          _PayFilter.all => true,
        };
    final list = s.payments.where(match).toList();
    return [
      ChipRow<_PayFilter>(
        options: const [
          (_PayFilter.needsAction, 'Needs action'),
          (_PayFilter.inPosting, 'In posting'),
          (_PayFilter.done, 'Done'),
          (_PayFilter.all, 'All'),
        ],
        selected: _filter,
        onSelected: (v) => setState(() => _filter = v),
      ),
      if (!user.canReviewPayments)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Text('Showing your submissions. The owner approves.', style: TextStyle(fontSize: 13, color: t.mu)),
        ),
      const SizedBox(height: 12),
      if (list.isEmpty)
        const EmptyState(icon: Icons.inbox_outlined, title: 'Nothing here', body: 'No payment requests match this filter.')
      else
        for (final p in list)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: PaymentCard(payment: p),
          ),
    ];
  }

  List<Widget> _balanceList(Snapshot s, ReportSection? rentSec) {
    final t = context.t;
    final rent = s.rent;
    if (rent == null) {
      return [
        EmptyState(
          icon: Icons.cloud_off_outlined,
          title: 'Balances unavailable',
          body: rentSec?.warnings.isNotEmpty ?? false ? rentSec!.warnings.first.message : 'DoorLoop data was not returned in the latest report.',
        ),
      ];
    }
    final rows = rent.leases.map(LeaseView.new).where((l) => l.needsReview).toList();
    final props = {for (final l in rent.leases) l.propertyName}.toList()..sort();
    final q = _query.trim().toLowerCase();
    final shown = rows
        .where((l) => _property == null || l.lease.propertyName == _property)
        .where((l) => q.isEmpty || [l.tenant, l.lease.unit ?? '', l.ref, l.lease.propertyName].join(' ').toLowerCase().contains(q))
        .toList();
    final total = rows.fold<int>(0, (a, l) => a + (l.balance ?? 0));
    final missing = rows.where((l) => l.balance == null).length;
    final cutoff = rentSec?.cutoff.asOf;
    final zone = ref.read(repositoryProvider).businessTimezone;
    return [
      Padding(
        padding: pagePad,
        child: SurfaceCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Balances requiring review', style: TextStyle(fontSize: 13, color: t.mu)),
            const SizedBox(height: 4),
            Text(Money(total).format(), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600, fontFeatures: tabular)),
            const SizedBox(height: 4),
            Text(
              '${rows.length} leases${missing > 0 ? ' · $missing balance${missing == 1 ? '' : 's'} not returned (excluded)' : ''} · '
              'DoorLoop balance fields · cutoff ${cutoff == null ? 'unknown' : formatInstant(cutoff, zone)}',
              style: TextStyle(fontSize: 12, height: 1.4, color: t.mu),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      Padding(
        padding: pagePad,
        child: TextField(
          key: const ValueKey('balance-search'),
          onChanged: (v) => setState(() => _query = v),
          style: const TextStyle(fontSize: 15),
          decoration: InputDecoration(
            hintText: 'Tenant, unit or lease ID',
            prefixIcon: Icon(Icons.search_rounded, color: t.mu),
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      ),
      const SizedBox(height: 12),
      ChipRow<String?>(
        options: [(null, 'All'), for (final p in props) (p, p)],
        selected: _property,
        onSelected: (v) => setState(() => _property = v),
      ),
      const SizedBox(height: 12),
      if (shown.isEmpty)
        EmptyState(icon: Icons.search_off_rounded, title: 'No balances match', body: 'Try another property or search.')
      else
        for (final l in shown)
          Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 10), child: _BalanceCard(lease: l)),
    ];
  }
}

class PaymentCard extends StatelessWidget {
  const PaymentCard({super.key, required this.payment});
  final PaymentSubmission payment;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final d = payment.draft;
    final look = paymentLook(payment.status);
    return SurfaceCard(
      onTap: () => openRoute(context, '/payments/${payment.id}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(Money(d.amountMinor).format(),
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, fontFeatures: tabular)),
          ),
          ToneChip(look.label, look.tone, icon: look.icon),
        ]),
        const SizedBox(height: 8),
        Text('${paymentWhere(d)} · ${d.tenantName ?? 'Tenant not provided'}', style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 4),
        Text('${displayId(payment.id)} · ${d.method.label} · paid ${shortDate(d.paymentDate)} · by ${payment.submittedByName}',
            style: TextStyle(fontSize: 13, color: t.mu)),
      ]),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.lease});
  final LeaseView lease;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final (recon, tone) = lease.recon;
    return SurfaceCard(
      onTap: () => openRoute(context, '/payments/balance/${lease.lease.leaseId}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(lease.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
          Text(formatMinor(lease.balance), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, fontFeatures: tabular, color: lease.balance == null ? t.na : t.tx)),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: Text('${lease.tenant} · ${lease.ref}', style: TextStyle(fontSize: 13, color: t.mu))),
          ToneChip(recon, tone),
        ]),
        const SizedBox(height: 6),
        Text(lease.reason, style: TextStyle(fontSize: 13, color: t.mu)),
        if ((lease.pending ?? 0) > 0) ...[
          const SizedBox(height: 6),
          Row(children: [
            Icon(Icons.schedule_rounded, size: 14, color: t.wa),
            const SizedBox(width: 4),
            Expanded(
              child: Text('${Money(lease.pending!).format()} pending · not yet cleared',
                  style: TextStyle(fontSize: 12, color: t.wa)),
            ),
          ]),
        ],
      ]),
    );
  }
}
