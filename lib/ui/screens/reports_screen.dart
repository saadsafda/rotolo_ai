import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../models/payloads.dart';
import '../../models/report.dart';
import '../../models/sync_run.dart';
import '../../state/app_state.dart';
import '../../state/providers.dart';
import '../../state/view_models.dart';
import '../theme.dart';
import '../widgets/kit.dart';
import 'home_screen.dart' show reportStatusLook;
import 'report_detail_screen.dart' show ReportRefreshPanel;

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});
  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  int _days = 7;
  SectionSource? _source;

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(sessionProvider)!;
    final repo = ref.watch(repositoryProvider);
    final now = ref.watch(clockProvider)();
    final zone = repo.businessTimezone;
    final reports = ref.watch(allReportsProvider);
    final run = user.canRefresh ? ref.watch(refreshControllerProvider) : null;
    final sources = [
      for (final s in const [SectionSource.fubDeals, SectionSource.doorloopRent, SectionSource.emailEvidence, SectionSource.timeDoctor])
        if (user.canRead(s)) s,
    ];
    return AsyncBody(
      value: reports,
      builder: (list) {
        final today = businessDay(now, zone);
        final shown = list.where((r) => daysBetween(r.summary.businessDate, today) < _days).toList();
        final groups = <String, List<Report>>{};
        for (final r in shown) {
          final age = daysBetween(r.summary.businessDate, today);
          final weekStart = today.subtract(Duration(days: today.weekday - 1));
          final g = !r.summary.businessDate.isBefore(weekStart)
              ? 'This week'
              : age < today.weekday + 6
                  ? 'Last week'
                  : 'Earlier';
          groups.putIfAbsent(g, () => []).add(r);
        }
        return ListView(padding: const EdgeInsets.only(top: 8, bottom: 28), children: [
          PageTitle('Daily reports',
              subtitle: list.isEmpty
                  ? 'No reports yet'
                  : 'Latest generated ${timeIn(list.first.summary.generatedAt, zone)} · previous-day activity and current snapshots'),
          if (user.canRefresh && !repo.isSynthetic)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                OutlinedButton.icon(
                  onPressed: run?.status.isActive ?? false
                      ? null
                      : () => ref.read(refreshControllerProvider.notifier).start(mode: 'live'),
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Generate report'),
                ),
                if (run != null) ReportRefreshPanel(run: run),
              ]),
            ),
          const SizedBox(height: 14),
          ChipRow<int>(
            options: const [(7, 'Last 7 days'), (30, 'Last 30 days')],
            selected: _days,
            leading: Icons.calendar_today_outlined,
            onSelected: (v) => setState(() => _days = v),
          ),
          const SizedBox(height: 14),
          ChipRow<SectionSource?>(
            options: [(null, 'All'), for (final s in sources) (s, _short(s))],
            selected: _source,
            onSelected: (v) => setState(() => _source = v),
          ),
          if (shown.isEmpty)
            const EmptyState(icon: Icons.summarize_outlined, title: 'No reports in this range')
          else
            for (final e in groups.entries)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(e.key, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.t.mu)),
                  for (final r in e.value) ...[const SizedBox(height: 8), _ReportRow(report: r, source: _source)],
                ]),
              ),
        ]);
      },
    );
  }
}

String _short(SectionSource s) => switch (s) {
      SectionSource.fubDeals => 'FUB',
      SectionSource.doorloopRent => 'DoorLoop',
      SectionSource.emailEvidence => 'Gmail',
      SectionSource.timeDoctor => 'Time Doctor',
      _ => s.system,
    };

class _ReportRow extends StatelessWidget {
  const _ReportRow({required this.report, required this.source});
  final Report report;
  final SectionSource? source;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final (label, tone, _) = reportStatusLook(report.summary.status);
    return SurfaceCard(
      onTap: () => openRoute(context, '/reports/${report.summary.id}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(dayLabel(report.summary.businessDate), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
          if (report.summary.dataMode == 'synthetic') ...[
            const ToneChip('Demo data', Tone.wa),
            const SizedBox(width: 6),
          ],
          ToneChip(label, tone),
        ]),
        const SizedBox(height: 6),
        Text(source == null ? reportLine(report) : '${_short(source!)}: ${sourceLine(report, source!)}',
            style: TextStyle(fontSize: 14, height: 1.45, color: t.mu)),
      ]),
    );
  }
}

/// One-line digest built only from returned figures.
String reportLine(Report r) {
  final parts = <String>[];
  final deals = r[SectionSource.fubDeals];
  if (deals != null && deals.isAvailable) parts.add('${DealsPayload(deals.payload).count('open') ?? '?'} open deals');
  final rent = r[SectionSource.doorloopRent];
  if (rent != null && rent.isAvailable) {
    final review = RentPayload(rent.payload).leases.map(LeaseView.new).where((l) => l.needsReview).length;
    parts.add('$review leases to review');
  }
  final tasks = r[SectionSource.doorloopTasks];
  if (tasks != null && tasks.isAvailable) {
    parts.add('${TasksPayload(tasks.payload).tasks.where((t) => t.isOverdue && !t.completionClaimed).length} tasks overdue');
  }
  final gaps = [for (final s in r.sections.values) if (s.status != 'complete') _gapName(s)];
  final head = parts.isEmpty ? '' : '${parts.join(' · ')}. ';
  return gaps.isEmpty ? '${head}All sources complete.' : '$head${gaps.join(', ')}.';
}

String _gapName(ReportSection s) => '${SourceHealth(s, false).name} ${s.status == 'unavailable' ? 'unavailable' : 'partial'}';

String sourceLine(Report r, SectionSource s) {
  final sec = r[s];
  if (sec == null) return 'Not in this report';
  if (!sec.isAvailable) return 'Unavailable${sec.warnings.isEmpty ? '' : ' · ${sec.warnings.first.message}'}';
  final partial = sec.status == 'complete' ? '' : ' · partial';
  return switch (s) {
    SectionSource.fubDeals => () {
        final p = DealsPayload(sec.payload);
        return '${p.count('open') ?? '?'} open deals · ${p.deals.where((d) => d.flags.isNotEmpty).length} flagged$partial';
      }(),
    SectionSource.doorloopRent => () {
        final p = RentPayload(sec.payload);
        final due = p.leases.fold<int>(0, (a, l) => a + (l.apiBalance.totalDue ?? 0));
        return '${p.leases.length} leases · ${Money(due).format()} due$partial';
      }(),
    SectionSource.emailEvidence => () {
        final p = EmailEvidencePayload(sec.payload);
        return '${p.items.length} matched emails · ${p.unmatched.length} unmatched$partial';
      }(),
    SectionSource.timeDoctor => () {
        final p = StaffActivityPayload(sec.payload);
        final total = p.users.fold<int>(0, (a, u) => a + (u.trackedSec ?? 0));
        return '${hours(total)} tracked · ${p.users.length} of ${p.users.length + p.missing.length} users$partial';
      }(),
    _ => sec.status,
  };
}
