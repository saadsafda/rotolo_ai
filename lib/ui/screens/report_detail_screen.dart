import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/data_quality.dart';
import '../../core/money.dart';
import '../../models/app_user.dart';
import '../../models/payloads.dart';
import '../../models/report.dart';
import '../../models/sync_run.dart';
import '../../state/app_state.dart';
import '../../state/providers.dart';
import '../../state/view_models.dart';
import '../theme.dart';
import '../widgets/kit.dart';
import 'home_screen.dart' show reportStatusLook, aiSummaryText;

class ReportDetailScreen extends ConsumerStatefulWidget {
  const ReportDetailScreen({super.key, required this.reportId});
  final String reportId;
  @override
  ConsumerState<ReportDetailScreen> createState() => _ReportDetailScreenState();
}

class _ReportDetailScreenState extends ConsumerState<ReportDetailScreen> {
  final _open = <String>{'deals'};

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(sessionProvider)!;
    final report = ref.watch(reportProvider(widget.reportId));
    final run = ref.watch(refreshControllerProvider);
    final t = context.t;
    return Column(children: [
      DetailHeader(
        title: 'Daily report',
        fallback: '/reports',
        trailing: user.canRefresh
            ? OutlinedButton.icon(
                key: const ValueKey('refresh-button'),
                onPressed: run?.status.isActive ?? false
                    ? null
                    : () => ref.read(refreshControllerProvider.notifier).start(mode: ref.read(repositoryProvider).isSynthetic ? 'synthetic' : 'live'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  textStyle: const TextStyle(fontFamily: kSans, fontSize: 13, fontWeight: FontWeight.w600),
                ),
                icon: Icon(Icons.refresh_rounded, size: 18, color: t.tx),
                label: const Text('Refresh'),
              )
            : null,
      ),
      Expanded(
        child: AsyncBody(
          value: report,
          builder: (r) => ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 28), children: [
            ..._header(r),
            if (run != null) ...[const SizedBox(height: 16), ReportRefreshPanel(run: run)],
            const SizedBox(height: 16),
            ..._body(r, user),
          ]),
        ),
      ),
    ]);
  }

  List<Widget> _header(Report r) {
    final t = context.t;
    final repo = ref.read(repositoryProvider);
    final zone = repo.businessTimezone;
    final (label, tone, _) = reportStatusLook(r.summary.status);
    final staff = r[SectionSource.timeDoctor];
    return [
      Row(children: [
        Expanded(child: Text(longDay(r.summary.businessDate), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600))),
        ToneChip(label, tone),
      ]),
      const SizedBox(height: 6),
      Text(
        'Snapshots as of collection time · '
        '${staff?.cutoff.date == null ? '' : 'staff activity for ${dayLabel(staff!.cutoff.date!)} · '}'
        'generated ${whenIn(r.summary.generatedAt, ref.read(clockProvider)(), zone)}',
        style: TextStyle(fontSize: 13, color: t.mu, height: 1.4),
      ),
      const SizedBox(height: 10),
      Wrap(spacing: 6, runSpacing: 6, children: [
        if (r.summary.dataMode != 'live') SourceBadge('Demo data', icon: Icons.science_outlined, iconColor: t.wa),
        for (final s in r.sections.values)
          SourceBadge(
            SourceHealth(s, false).name,
            icon: s.status == 'complete'
                ? Icons.check_circle_rounded
                : s.status == 'unavailable'
                    ? Icons.error_rounded
                    : Icons.warning_rounded,
            iconColor: s.status == 'complete' ? t.ok : s.status == 'unavailable' ? t.er : t.wa,
          ),
      ]),
      if (!r.isLatest) ...[
        const SizedBox(height: 12),
        NoticeBox(
          tone: Tone.na,
          icon: Icons.history_rounded,
          title: 'Historical report.',
          text: 'Newer data exists. Figures here describe ${dayLabel(r.summary.businessDate)} only.',
        ),
      ],
    ];
  }

  List<Widget> _body(Report r, AppUser user) {
    final t = context.t;
    if (r.summary.status == 'failed') {
      return [
        AlertPanel(tone: Tone.er, icon: Icons.error_rounded, title: 'Report not generated', children: [
          Text(
            [for (final s in r.sections.values) ...s.warnings.map((w) => w.message)].join(' ').ifEmpty(
                'A required source failed, so the report was held back instead of summarising incomplete data.'),
            style: TextStyle(fontSize: 14, height: 1.5, color: t.tx),
          ),
          if (user.isOwnerOrAdmin)
            Row(children: [
              OutlinedButton(onPressed: () => openRoute(context, '/more/integrations'), child: const Text('Check sources')),
            ]),
        ]),
      ];
    }
    final gaps = [for (final s in r.sections.values) if (s.status != 'complete') s];
    final ai = r[SectionSource.aiSummary];
    final summary = ai == null ? null : AiSummary(ai.payload);
    return [
      if (gaps.isNotEmpty) ...[
        NoticeBox(
          tone: Tone.wa,
          icon: Icons.warning_amber_rounded,
          title: 'Partial report.',
          text: '${gaps.map((s) => '${SourceHealth(s, false).name} ${s.status == 'unavailable' ? 'was unavailable' : 'returned partial data'}').join('; ')}. '
              'Other sections are complete.',
        ),
        const SizedBox(height: 16),
      ],
      if (summary != null) ...[
        SurfaceCard(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              const ToneChip('AI-generated summary', Tone.ac, icon: Icons.auto_awesome_outlined, square: true),
              Text('OpenAI${summary.model == null ? '' : ' · ${summary.model}'} · from synced records',
                  style: TextStyle(fontSize: 12, color: t.mu)),
            ]),
            const SizedBox(height: 10),
            Text(aiSummaryText(summary), style: const TextStyle(fontSize: 15, height: 1.55)),
            const SizedBox(height: 10),
            Text('Summaries can be wrong. Figures below come directly from each source.',
                style: TextStyle(fontSize: 12, height: 1.4, color: t.mu)),
          ]),
        ),
        const SizedBox(height: 16),
      ],
      for (final g in _groups(r, user)) ...[
        _SectionCard(
          group: g,
          open: _open.contains(g.key),
          onToggle: () => setState(() => _open.contains(g.key) ? _open.remove(g.key) : _open.add(g.key)),
          report: r,
        ),
        const SizedBox(height: 10),
      ],
    ];
  }

  List<_Group> _groups(Report r, AppUser user) {
    final reviews = ref.watch(evidenceReviewsProvider).value ?? const {};
    final taskReviews = ref.watch(taskReviewsProvider).value ?? const {};
    final zone = ref.read(repositoryProvider).businessTimezone;
    final today = businessDay(ref.read(clockProvider)(), zone);
    final groups = <_Group>[];

    final dealsSec = r[SectionSource.fubDeals];
    final mailSec = r[SectionSource.emailEvidence];
    if (dealsSec != null || mailSec != null) {
      final deals = dealsSec != null && dealsSec.isAvailable ? DealsPayload(dealsSec.payload) : null;
      final mail = mailSec != null && mailSec.isAvailable ? EmailEvidencePayload(mailSec.payload) : null;
      final views = [for (final d in deals?.deals ?? const <Deal>[]) DealView(d, mail, reviews[d.id])];
      final items = <_Item>[
        for (final v in views.where((v) => v.needsReview))
          _Item('${v.deal.property}: attorney email needs review', 'FUB stage is ${v.deal.stage}. Email does not confirm a closing.',
              'Needs review', Tone.wa, 'Open deal', '/more/deals/${v.deal.id}'),
        for (final v in views.where((v) => !v.needsReview && v.isOpen && v.deal.flags.isNotEmpty))
          _Item('${v.deal.property}: ${v.deal.flags.first}', '${v.deal.pipeline} · ${v.deal.stage}', 'Check CRM', Tone.wa,
              'Open deal', '/more/deals/${v.deal.id}'),
        for (final v in views.where((v) => v.isClosedVerified))
          _Item('${v.deal.property} is closed', 'Closed stage set in Follow Up Boss', 'Verified', Tone.ok, 'Open deal',
              '/more/deals/${v.deal.id}'),
        for (final u in mail?.unmatched ?? const <UnmatchedEmail>[])
          _Item('Unmatched email: ${u.subject}', u.reason, 'Unmatched', Tone.na, 'View deals', '/more/deals'),
      ];
      groups.add(_Group(
        key: 'deals',
        title: 'Deals and email evidence',
        icon: Icons.handshake_outlined,
        sections: [?dealsSec, ?mailSec],
        summary: deals == null
            ? 'Deals unavailable'
            : '${deals.count('open') ?? '?'} open · ${views.where((v) => v.needsReview).length} need review',
        items: items,
      ));
    }

    final rentSec = r[SectionSource.doorloopRent];
    if (rentSec != null) {
      final rent = rentSec.isAvailable ? RentPayload(rentSec.payload) : null;
      final review = [for (final l in rent?.leases ?? const <Lease>[]) LeaseView(l)].where((l) => l.needsReview).toList();
      final leaseById = {for (final l in rent?.leases ?? const <Lease>[]) l.leaseId: l};
      final items = <_Item>[
        for (final l in review)
          _Item('${l.title}: ${l.balance == null ? 'balance not returned' : Money(l.balance!).format()}', '${l.tenant} · ${l.reason}',
              l.recon.$1, l.recon.$2, 'Open balance', '/payments/balance/${l.lease.leaseId}'),
        for (final p in rent?.payments ?? const <LeasePayment>[])
          if (p.classification == 'returned' || p.classification == 'pending')
            _Item(
              '${p.classification == 'returned' ? 'Returned' : 'Pending'} payment · ${formatMinor(p.amount)}',
              '${leaseById[p.leaseId] == null ? p.leaseId : LeaseView(leaseById[p.leaseId]!).title} · '
                  '${p.date == null ? 'date not returned' : fullDate(p.date!)}',
              p.classification == 'returned' ? 'Returned' : 'Pending',
              p.classification == 'returned' ? Tone.er : Tone.wa,
              'Open balance',
              '/payments/balance/${p.leaseId}',
            ),
      ];
      groups.add(_Group(
        key: 'rent',
        title: 'Rent and payments',
        icon: Icons.account_balance_wallet_outlined,
        sections: [rentSec],
        summary: rent == null
            ? 'Unavailable'
            : '${review.length} leases to review · ${Money(review.fold(0, (a, l) => a + (l.balance ?? 0))).format()}',
        items: items,
      ));
    }

    final taskSec = r[SectionSource.doorloopTasks];
    if (taskSec != null) {
      final tasks = taskSec.isAvailable ? TasksPayload(taskSec.payload) : null;
      final views = [for (final x in tasks?.tasks ?? const <MaintenanceTask>[]) TaskView(x, taskReviews[x.id], today)];
      final overdue = views.where((v) => v.overdue).toList();
      final claimed = views.where((v) => v.claimed).toList();
      groups.add(_Group(
        key: 'maint',
        title: 'Maintenance',
        icon: Icons.build_outlined,
        sections: [taskSec],
        summary: tasks == null ? 'Unavailable' : '${overdue.length} overdue · ${claimed.length} completion claimed',
        items: [
          for (final v in overdue)
            _Item('${v.task.subject} is ${v.overdueDays} days overdue', '${v.where} · ${v.assignee}', 'Overdue', Tone.er, 'Open task',
                '/tasks/${v.task.id}'),
          for (final v in claimed)
            _Item('${v.task.subject}: completion claimed', 'DoorLoop status says done. Awaiting your verification.', 'Claimed', Tone.wa,
                'Open task', '/tasks/${v.task.id}'),
        ],
      ));
    }

    final staffSec = r[SectionSource.timeDoctor];
    if (staffSec != null) {
      final staff = staffSec.isAvailable ? StaffActivityPayload(staffSec.payload) : null;
      final total = staff?.trackedSec;
      final activity = staff?.noActivity == true ? 'No recorded activity' : hours(total);
      final count = staff == null ? '' : '${staff.users.length} of ${staff.users.length + staff.missing.length} users';
      groups.add(_Group(
        key: 'team',
        title: 'Team activity',
        icon: Icons.groups_outlined,
        sections: [staffSec],
        summary: staff == null ? 'Unavailable' : '$activity · $count',
        items: [
          if (staff != null)
            _Item(staff.noActivity || total == null ? '$activity · $count' : '$activity tracked across $count',
                staff.missing.isEmpty ? 'Time Doctor coverage' : 'Totals exclude ${staff.missing.map((m) => m.name).join(', ')}',
                staffSec.status == 'complete' ? 'Complete' : 'Partial', staffSec.status == 'complete' ? Tone.ok : Tone.wa, 'View team', '/more/team'),
          for (final m in staff?.missing ?? const <MissingStaff>[])
            _Item('${m.name}: no data returned', '${m.reason}. Shown as Unavailable, not zero.', 'Unavailable', Tone.na,
                user.isOwnerOrAdmin ? 'Check integration' : 'View team', user.isOwnerOrAdmin ? '/more/integrations' : '/more/team'),
        ],
      ));
    }
    return groups;
  }
}

extension on String {
  String ifEmpty(String other) => trim().isEmpty ? other : this;
}

class _Item {
  const _Item(this.text, this.sub, this.chip, this.tone, this.link, this.route);
  final String text;
  final String sub;
  final String chip;
  final Tone tone;
  final String link;
  final String route;
}

class _Group {
  const _Group({required this.key, required this.title, required this.icon, required this.sections, required this.summary, required this.items});
  final String key;
  final String title;
  final IconData icon;
  final List<ReportSection> sections;
  final String summary;
  final List<_Item> items;
}

class _SectionCard extends ConsumerWidget {
  const _SectionCard({required this.group, required this.open, required this.onToggle, required this.report});
  final _Group group;
  final bool open;
  final VoidCallback onToggle;
  final Report report;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final repo = ref.read(repositoryProvider);
    final zone = repo.businessTimezone;
    final now = ref.read(clockProvider)();
    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: onToggle,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Icon(group.icon, size: 22, color: t.ac),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(group.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(group.summary, style: TextStyle(fontSize: 13, color: t.mu)),
                  ]),
                ),
                Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 24, color: t.mu),
              ]),
            ),
          ),
        ),
        if (open)
          Container(
            decoration: BoxDecoration(border: Border(top: BorderSide(color: t.bd))),
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final s in group.sections) ...[
                Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  SourceBadge(s.source.system, small: true),
                  for (final f in qualityFlags(
                    dataMode: 'live', // synthetic is labelled once for the whole report
                    status: s.status,
                    collectedAt: s.collectedAt,
                    now: now,
                    staleAfterHours: repo.staleAfterHours,
                    isLatest: report.isLatest,
                  ))
                    if (f != QualityFlag.live)
                      Tooltip(
                        message: f.explanation,
                        child: ToneChip(f.label[0] + f.label.substring(1).toLowerCase(),
                            f == QualityFlag.unavailable ? Tone.er : f == QualityFlag.historical ? Tone.na : Tone.wa, small: true),
                      ),
                  Text(cutoffText(s.cutoff, zone), style: TextStyle(fontSize: 12, color: t.mu)),
                ]),
                for (final w in s.warnings)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(w.message, style: TextStyle(fontSize: 12, height: 1.4, color: w.severity == 'info' ? t.mu : t.wa)),
                  ),
                const SizedBox(height: 6),
              ],
              if (group.items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text('Nothing needs attention here.', style: TextStyle(fontSize: 14, color: t.mu)),
                ),
              for (var i = 0; i < group.items.length; i++) ...[
                if (i > 0) Divider(height: 1, color: t.bd),
                _ItemRow(item: group.items[i]),
              ],
            ]),
          ),
      ]),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item});
  final _Item item;
  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(item.text, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, height: 1.4))),
          const SizedBox(width: 8),
          ToneChip(item.chip, item.tone, small: true),
        ]),
        const SizedBox(height: 6),
        Text(item.sub, style: TextStyle(fontSize: 13, height: 1.4, color: t.mu)),
        TextButton.icon(
          onPressed: () => openRoute(context, item.route),
          style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 36), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          icon: Icon(Icons.open_in_new_rounded, size: 16, color: t.ac),
          label: Text(item.link, style: const TextStyle(fontSize: 13)),
        ),
      ]),
    );
  }
}

class ReportRefreshPanel extends ConsumerWidget {
  const ReportRefreshPanel({super.key, required this.run});
  final SyncRun run;

  static const _stages = [
    ('fub', 'Follow Up Boss'),
    ('email', 'Gmail'),
    ('doorloop', 'DoorLoop'),
    ('time_doctor', 'Time Doctor'),
    ('summary', 'OpenAI summary'),
    ('store', 'Save report'),
  ];

  static String pDetail(SyncStage? stage, bool current, bool active) {
    if (current) return 'Syncing…';
    return stage?.detail ?? switch (stage?.status) {
      'ok' => 'Done',
      'partial' => 'With gaps',
      'failed' => 'Unavailable',
      _ => active ? 'Waiting' : '—',
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final done = {for (final p in run.progress) p.stage: p};
    final active = run.status.isActive;
    final current = active ? _stages.map((s) => s.$1).lastWhere((s) => done[s]?.status == 'running', orElse: () => '') : '';
    return SurfaceCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Text(active ? 'Refreshing…' : run.status.label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          if (!active)
            IconButton(
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close_rounded, size: 18, color: t.mu),
              onPressed: () => ref.read(refreshControllerProvider.notifier).dismiss(),
            ),
        ]),
        const SizedBox(height: 4),
        for (final (key, name) in _stages)
          SizedBox(
            height: 30,
            child: Row(children: [
              Builder(builder: (_) {
                final p = done[key];
                if (key == current) {
                  return SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: t.ac));
                }
                if (p == null || p.status == 'running') return Icon(Icons.radio_button_unchecked_rounded, size: 18, color: t.mu);
                if (p.status == 'ok') return Icon(Icons.check_circle_rounded, size: 18, color: t.ok);
                if (p.status == 'partial') return Icon(Icons.warning_rounded, size: 18, color: t.wa);
                return Icon(Icons.error_rounded, size: 18, color: t.er);
              }),
              const SizedBox(width: 10),
              Expanded(child: Text(name, style: const TextStyle(fontSize: 14))),
              Flexible(
                child: Text(
                  pDetail(done[key], key == current, active),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: t.mu),
                ),
              ),
            ]),
          ),
        if (run.error != null) ...[
          const SizedBox(height: 6),
          Text(run.error!, style: TextStyle(fontSize: 13, color: t.er)),
        ],
        if (!active && run.reportId != null) ...[
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () {
              final id = run.reportId!;
              ref.read(refreshControllerProvider.notifier).dismiss();
              context.pushReplacement('/reports/$id');
            },
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
            child: const Text('Open new report'),
          ),
        ],
      ]),
    );
  }
}

String cutoffText(Cutoff c, String zone) => switch (c.kind) {
      'snapshot' => 'Snapshot as of ${timeIn(c.asOf, zone)}',
      'business_day' => 'Workday ${c.date == null ? 'unknown' : dayLabel(c.date!)}',
      'lookback' => 'Last ${c.days ?? '?'} days to ${timeIn(c.asOf, zone)}',
      _ => 'Cutoff not reported',
    };
