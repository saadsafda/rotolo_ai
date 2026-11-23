import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/money.dart';
import '../../core/time_format.dart';
import '../../models/app_user.dart';
import '../../models/payloads.dart';
import '../../models/payment.dart';
import '../../models/report.dart';
import '../../state/app_state.dart';
import '../../state/providers.dart';
import '../../state/view_models.dart';
import '../theme.dart';
import '../widgets/kit.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(sessionProvider)!;
    final snap = ref.watch(snapshotProvider);
    return AsyncBody(
      value: snap,
      builder: (s) => RefreshIndicator(
        onRefresh: () async {
          ref.read(dataVersionProvider.notifier).bump();
          await ref.read(snapshotProvider.future);
        },
        child: _HomeBody(snapshot: s, user: user),
      ),
    );
  }
}

class _HomeBody extends ConsumerWidget {
  const _HomeBody({required this.snapshot, required this.user});
  final Snapshot snapshot;
  final AppUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final repo = ref.watch(repositoryProvider);
    final zone = repo.businessTimezone;
    final now = ref.watch(clockProvider)();
    final local = inZone(now, zone);
    final greeting = local.hour < 12 ? 'Good morning' : local.hour < 18 ? 'Good afternoon' : 'Good evening';
    final latest = snapshot.latest;
    final attention = attentionItems(snapshot, user: user, now: now, zone: zone);
    final unread = watchUnread(ref);

    return ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 28), children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$greeting, ${user.firstName}',
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600, letterSpacing: -.2)),
            const SizedBox(height: 4),
            Text('${DateFormat('EEE, MMM d, y').format(local)} · Eastern Time (${local.timeZoneName})',
                style: TextStyle(fontSize: 14, color: t.mu)),
          ]),
        ),
        _BellButton(unread: unread),
      ]),
      const SizedBox(height: 20),
      if (latest == null)
        const EmptyState(icon: Icons.summarize_outlined, title: 'No reports yet', body: 'The first daily report has not been generated.')
      else ...[
        _FreshnessCard(report: latest, user: user, now: now, zone: zone, staleAfter: repo.staleAfterHours),
        const SizedBox(height: 20),
        if (attention.isNotEmpty) ...[
          SectionLabel('Needs your attention',
              size: 17,
              trailing: Text('${attention.length} items', style: TextStyle(fontSize: 13, color: t.mu))),
          const SizedBox(height: 10),
          _AttentionList(items: attention),
          const SizedBox(height: 20),
        ],
        _ReportCard(report: latest),
        const SizedBox(height: 20),
        ..._glance(context, now, zone),
        const SizedBox(height: 20),
        SectionLabel('Source health',
            size: 17,
            trailing: user.isOwnerOrAdmin
                ? GestureDetector(
                    onTap: () => openRoute(context, '/more/integrations'),
                    child: Text('Integrations', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.ac)),
                  )
                : null),
        const SizedBox(height: 10),
        _SourceHealthCard(health: sourceHealth(latest, now, repo.staleAfterHours), now: now, zone: zone),
        const SizedBox(height: 20),
        _Shortcuts(user: user),
      ],
    ]);
  }

  List<Widget> _glance(BuildContext context, DateTime now, String zone) {
    final t = context.t;
    final today = businessDay(now, zone);
    final tiles = <_TileData>[];
    final deals = dealViews(snapshot);
    if (snapshot.deals != null) {
      final open = deals.where((d) => d.isOpen).length;
      final attn = deals.where((d) => d.needsReview || (d.isOpen && (d.deal.daysToProjectedClose ?? 0) < 0)).length;
      tiles.add(_TileData(Icons.handshake_outlined, 'Open deals', '$open', attn == 0 ? 'None need attention' : '$attn need attention',
          '/more/deals'));
    }
    final rent = snapshot.rent;
    if (rent != null) {
      final review = rent.leases.map(LeaseView.new).where((l) => l.needsReview).toList();
      final total = review.fold<int>(0, (a, l) => a + (l.balance ?? 0));
      final missing = review.where((l) => l.balance == null).length;
      tiles.add(_TileData(Icons.account_balance_wallet_outlined, 'Rent to review', Money(total).format(),
          '${review.length} leases${missing > 0 ? ' · $missing not returned' : ''}', '/payments?tab=balances'));
    }
    if (user.canReviewPayments) {
      final waiting = snapshot.payments
          .where((p) => p.status == PaymentStatus.submitted || p.status == PaymentStatus.underReview)
          .toList();
      tiles.add(_TileData(Icons.pending_actions_outlined, 'Awaiting approval', '${waiting.length}',
          Money(waiting.fold(0, (a, p) => a + p.draft.amountMinor)).format(), '/payments'));
    } else if (user.canSubmitPayments) {
      final mine = snapshot.payments.where((p) => p.submittedBy == user.id).toList();
      tiles.add(_TileData(Icons.outbox_rounded, 'My submissions', '${mine.length}',
          mine.isEmpty ? 'None yet' : paymentLook(mine.first.status).label, '/payments'));
    }
    if (snapshot.tasks != null) {
      final overdue = taskViews(snapshot, today).where((t) => t.overdue).toList();
      final oldest = overdue.fold<int>(0, (a, t) => t.overdueDays > a ? t.overdueDays : a);
      tiles.add(_TileData(Icons.build_outlined, 'Overdue tasks', '${overdue.length}',
          overdue.isEmpty ? 'Nothing overdue' : 'Oldest $oldest days', '/tasks?status=overdue'));
    }
    final staff = snapshot.staff;
    final staffSec = snapshot.latest?[SectionSource.timeDoctor];
    if (tiles.isEmpty && staff == null) return const [];
    return [
      const SectionLabel('At a glance', size: 17),
      const SizedBox(height: 10),
      for (var i = 0; i < tiles.length; i += 2) ...[
        if (i > 0) const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: _Tile(tiles[i])),
            const SizedBox(width: 12),
            Expanded(child: i + 1 < tiles.length ? _Tile(tiles[i + 1]) : const SizedBox()),
          ]),
        ),
      ],
      if (staff != null && staffSec != null) ...[
        const SizedBox(height: 12),
        SurfaceCard(
          onTap: () => openRoute(context, '/more/team'),
          child: Row(children: [
            Icon(Icons.schedule_rounded, size: 20, color: t.mu),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Staff tracked hours', style: TextStyle(fontSize: 13, color: t.mu)),
                Text(staff.noActivity ? 'No recorded activity' : hours(staff.trackedSec),
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, fontFeatures: tabular)),
                Text(
                  staff.missing.isEmpty
                      ? '${staff.users.length} users reporting'
                      : '${staff.users.length} of ${staff.users.length + staff.missing.length} users reporting · '
                          '${staff.missing.map((m) => m.name).join(', ')} unavailable',
                  style: TextStyle(fontSize: 12, color: staff.missing.isEmpty ? t.mu : t.wa),
                ),
              ]),
            ),
            if (staff.workDate != null)
              Align(alignment: Alignment.topCenter, child: ToneChip(shortDate(staff.workDate!), Tone.na, square: true, small: true)),
          ]),
        ),
      ],
    ];
  }
}

class _BellButton extends StatelessWidget {
  const _BellButton({required this.unread});
  final int unread;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      button: true,
      label: unread > 0 ? 'Notifications, $unread unread' : 'Notifications',
      excludeSemantics: true,
      child: Material(
        key: const ValueKey('bell'),
        color: t.sf,
        shape: CircleBorder(side: BorderSide(color: t.bd)),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => openRoute(context, '/more/notifications'),
          child: SizedBox(
            width: 48,
            height: 48,
            child: Stack(clipBehavior: Clip.none, children: [
              Center(child: Icon(Icons.notifications_outlined, size: 24, color: t.tx)),
              if (unread > 0)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 18),
                    height: 18,
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    decoration: BoxDecoration(color: t.er, borderRadius: BorderRadius.circular(9)),
                    alignment: Alignment.center,
                    child: Text('$unread', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white)),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _FreshnessCard extends StatelessWidget {
  const _FreshnessCard({required this.report, required this.user, required this.now, required this.zone, required this.staleAfter});
  final Report report;
  final AppUser user;
  final DateTime now;
  final String zone;
  final int staleAfter;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final snapshotSec = report[SectionSource.doorloopRent] ?? report[SectionSource.fubDeals];
    final staff = report[SectionSource.timeDoctor];
    final asOf = snapshotSec?.cutoff.asOf ?? snapshotSec?.collectedAt;
    final stale = asOf == null || now.difference(asOf) > Duration(hours: staleAfter);
    final freshTone = stale ? Tone.wa : Tone.ok;

    Widget cell(IconData icon, String head, String main, Widget foot) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, size: 16, color: t.mu),
              const SizedBox(width: 6),
              Flexible(child: Text(head, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.mu))),
            ]),
            const SizedBox(height: 4),
            Text(main, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            foot,
          ]),
        );

    final left = cell(
      Icons.account_balance_outlined,
      snapshotSec?.source == SectionSource.doorloopRent ? 'Account snapshot' : 'CRM snapshot',
      'Now · as of ${asOf == null ? 'unknown' : DateFormat('h:mm a').format(inZone(asOf, zone))}',
      Row(children: [
        Icon(stale ? Icons.history_rounded : Icons.cloud_done_outlined, size: 14, color: t.fg(freshTone)),
        const SizedBox(width: 4),
        Flexible(
          child: Text(stale ? 'Stale · ${whenIn(asOf, now, zone)}' : 'Synced ${whenIn(asOf, now, zone).replaceFirst('Today', 'today')}',
              style: TextStyle(fontSize: 12, color: t.fg(freshTone))),
        ),
      ]),
    );
    final right = staff == null
        ? null
        : cell(
            Icons.history_rounded,
            'Staff activity',
            'Previous day · ${staff.cutoff.date == null ? 'unknown' : shortDate(staff.cutoff.date!)}',
            Text('Time Doctor · full day ${staff.cutoff.timezone == zone ? 'ET' : staff.cutoff.timezone ?? ''}',
                style: TextStyle(fontSize: 12, color: t.mu)),
          );
    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: left),
          if (right != null) ...[VerticalDivider(width: 1, color: t.bd), Expanded(child: right)],
        ]),
      ),
    );
  }
}

class _AttentionList extends StatelessWidget {
  const _AttentionList({required this.items});
  final List<AttentionItem> items;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) Divider(height: 1, color: t.bd),
          InkWell(
            onTap: () => openRoute(context, items[i].route),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 64),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(children: [
                  IconTile(items[i].icon, items[i].tone),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(items[i].title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(items[i].detail, style: TextStyle(fontSize: 13, height: 1.35, color: t.mu)),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  Text(items[i].cta, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.ac)),
                  Icon(Icons.chevron_right_rounded, size: 18, color: t.ac),
                ]),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

class _ReportCard extends ConsumerWidget {
  const _ReportCard({required this.report});
  final Report report;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final ai = report[SectionSource.aiSummary];
    final summary = ai == null ? null : AiSummary(ai.payload);
    final (label, tone, icon) = reportStatusLook(report.summary.status);
    return SurfaceCard(
      key: const ValueKey('home-report-card'),
      padding: const EdgeInsets.all(16),
      onTap: () => openRoute(context, '/reports/${report.summary.id}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.summarize_outlined, size: 20, color: t.ac),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Daily report · ${dayLabel(report.summary.businessDate)}',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          ToneChip(label, tone, icon: icon),
        ]),
        const SizedBox(height: 10),
        if (summary != null) ...[
          Row(children: [
            Icon(Icons.auto_awesome_outlined, size: 15, color: t.mu),
            const SizedBox(width: 6),
            Flexible(
              child: Text('AI summary · verify against sources',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.mu)),
            ),
          ]),
          const SizedBox(height: 10),
          Text(aiSummaryText(summary), style: const TextStyle(fontSize: 14, height: 1.5)),
          const SizedBox(height: 10),
        ],
        Row(children: [
          Text('Open report', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.ac)),
          Icon(Icons.chevron_right_rounded, size: 18, color: t.ac),
        ]),
      ]),
    );
  }
}

(String, Tone, IconData) reportStatusLook(String status) => switch (status) {
      'complete' => ('Complete', Tone.ok, Icons.check_circle_outline_rounded),
      'partial' => ('Partial', Tone.wa, Icons.warning_amber_rounded),
      _ => ('Failed', Tone.er, Icons.error_outline_rounded),
    };

String aiSummaryText(AiSummary s) => switch (s.status) {
      'ok' when s.text != null => s.text!,
      'rejected_by_guard' => 'The AI summary failed a safety check and was withheld. Figures in the report come directly from each source.',
      _ => 'No AI summary for this report. Figures in the report come directly from each source.',
    };

class _TileData {
  const _TileData(this.icon, this.label, this.value, this.sub, this.route);
  final IconData icon;
  final String label;
  final String value;
  final String sub;
  final String route;
}

class _Tile extends StatelessWidget {
  const _Tile(this.d);
  final _TileData d;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return SurfaceCard(
      onTap: () => openRoute(context, d.route),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 84),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(d.icon, size: 20, color: t.mu),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: t.acs, borderRadius: BorderRadius.circular(6)),
              child: Text('Now', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: t.ac)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(d.label, style: TextStyle(fontSize: 13, color: t.mu)),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(d.value,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: -.2, fontFeatures: tabular)),
          ),
          const SizedBox(height: 2),
          Text(d.sub, style: TextStyle(fontSize: 12, color: t.mu)),
        ]),
      ),
    );
  }
}

class _SourceHealthCard extends StatelessWidget {
  const _SourceHealthCard({required this.health, required this.now, required this.zone});
  final List<SourceHealth> health;
  final DateTime now;
  final String zone;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Column(children: [
        for (var i = 0; i < health.length; i++) ...[
          if (i > 0) Divider(height: 1, color: t.bd),
          SizedBox(
            height: 44,
            child: Row(children: [
              Icon(health[i].icon, size: 18, color: t.mu),
              const SizedBox(width: 10),
              Expanded(child: Text(health[i].name, style: const TextStyle(fontSize: 14))),
              Text(
                health[i].section.collectedAt == null
                    ? '—'
                    : DateFormat(daysBetween(businessDay(health[i].section.collectedAt!, zone), businessDay(now, zone)) == 0
                            ? 'h:mm a'
                            : 'MMM d')
                        .format(inZone(health[i].section.collectedAt!, zone)),
                style: TextStyle(fontSize: 12, color: t.mu, fontFeatures: tabular),
              ),
              const SizedBox(width: 10),
              ToneChip(health[i].status.$1, health[i].status.$2),
            ]),
          ),
        ],
      ]),
    );
  }
}

class _Shortcuts extends StatelessWidget {
  const _Shortcuts({required this.user});
  final AppUser user;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final items = [
      if (user.canRead(SectionSource.fubDeals)) (Icons.handshake_outlined, 'Deals', '/more/deals'),
      if (user.canRead(SectionSource.timeDoctor)) (Icons.groups_outlined, 'Team activity', '/more/team'),
      (Icons.notifications_outlined, 'Notifications', '/more/notifications'),
      if (user.isOwnerOrAdmin) (Icons.hub_outlined, 'Integrations', '/more/integrations'),
    ];
    return Row(children: [
      for (var i = 0; i < 4; i++) ...[
        if (i > 0) const SizedBox(width: 8),
        Expanded(
          child: i >= items.length
              ? const SizedBox()
              : Material(
                  color: t.sf,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: t.bd)),
                  child: InkWell(
                    customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    onTap: () => openRoute(context, items[i].$3),
                    child: SizedBox(
                      height: 76,
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(items[i].$1, size: 22, color: t.ac),
                        const SizedBox(height: 6),
                        Text(items[i].$2,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, height: 1.2)),
                      ]),
                    ),
                  ),
                ),
        ),
      ],
    ]);
  }
}
