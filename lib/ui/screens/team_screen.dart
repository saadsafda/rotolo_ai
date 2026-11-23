import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/time_format.dart';
import '../../models/json.dart';
import '../../models/payloads.dart';
import '../../models/report.dart';
import '../../state/app_state.dart';
import '../../state/providers.dart';
import '../../state/view_models.dart';
import '../theme.dart';
import '../widgets/kit.dart';

class TeamScreen extends ConsumerStatefulWidget {
  const TeamScreen({super.key});
  @override
  ConsumerState<TeamScreen> createState() => _TeamScreenState();
}

class _TeamScreenState extends ConsumerState<TeamScreen> {
  int _index = 0;
  String? _user;

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(sessionProvider)!;
    final reports = ref.watch(allReportsProvider);
    final repo = ref.watch(repositoryProvider);
    final zone = repo.businessTimezone;
    final t = context.t;
    return Column(children: [
      const DetailHeader(title: 'Team activity', subtitle: 'Time Doctor · previous-day totals, ET', fallback: '/more'),
      Expanded(
        child: !user.canRead(SectionSource.timeDoctor)
            ? const EmptyState(icon: Icons.lock_outline_rounded, title: 'Not available for your role')
            : AsyncBody(
                value: reports,
                builder: (list) {
                  final days = <(DateTime?, ReportSection)>[];
                  final seenDates = <DateTime>{};
                  for (final report in list) {
                    if (!repo.isSynthetic && report.summary.dataMode != 'live') continue;
                    final section = report[SectionSource.timeDoctor];
                    if (section == null) continue;
                    final date = section.cutoff.date ?? asDate(section.payload['work_date']);
                    // Reports are newest first. A refresh can produce several for the same work date.
                    if (date == null || seenDates.add(date)) days.add((date, section));
                  }
                  if (days.isEmpty) return const EmptyState(icon: Icons.timer_off_outlined, title: 'No Time Doctor data yet');
                  final i = _index.clamp(0, days.length - 1);
                  final dates = ChipRow<int>(
                    options: [
                      for (var k = 0; k < days.length; k++)
                        (k, days[k].$1 == null ? 'Unknown day' : dayLabel(days[k].$1!)),
                    ],
                    selected: i,
                    onSelected: (v) => setState(() {
                      _index = v;
                      _user = null;
                    }),
                  );
                  final section = days[i].$2;
                  if (!section.isAvailable) {
                    return Column(children: [
                      dates,
                      const Expanded(child: EmptyState(
                        icon: Icons.timer_off_outlined,
                        title: 'Time Doctor is unavailable for this day',
                      )),
                    ]);
                  }
                  final day = StaffActivityPayload(section.payload);
                  final previous = i + 1 < days.length ? days[i + 1].$2 : null;
                  final prior = previous?.isAvailable == true ? StaffActivityPayload(previous!.payload) : null;
                  final names = [...day.users.map((u) => u.name), ...day.missing.map((m) => m.name)];
                  final rows = [
                    for (final u in day.users)
                      if (_user == null || u.name == _user) (u.name, u, prior?.users.where((p) => p.name == u.name).firstOrNull),
                    for (final m in day.missing)
                      if (_user == null || m.name == _user) (m.name, null, prior?.users.where((p) => p.name == m.name).firstOrNull),
                  ];
                  const maxSec = 10 * 3600;
                  return ListView(padding: const EdgeInsets.only(bottom: 28), children: [
                    dates,
                    const SizedBox(height: 10),
                    ChipRow<String?>(
                      options: [(null, 'All staff'), for (final n in names) (n, n)],
                      selected: _user,
                      onSelected: (v) => setState(() => _user = v),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: pagePad,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        if (day.missing.isNotEmpty) ...[
                          NoticeBox(
                            tone: Tone.wa,
                            icon: Icons.person_off_outlined,
                            title: 'Incomplete coverage.',
                            text: '${day.missing.map((m) => '${m.name} (${m.reason})').join(', ')} returned no data. Totals exclude them.',
                          ),
                          const SizedBox(height: 12),
                        ],
                        SurfaceCard(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('Tracked hours', style: TextStyle(fontSize: 13, color: t.mu)),
                            Text(day.noActivity ? 'No recorded activity' : hours(day.trackedSec),
                                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600, fontFeatures: tabular)),
                            Text('${day.users.length} of ${names.length} users covered', style: TextStyle(fontSize: 13, color: t.mu)),
                          ]),
                        ),
                        const SizedBox(height: 12),
                        SurfaceCard(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            Row(children: [
                              const Expanded(child: Text('Hours vs prior day', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
                              _legend(t.ac, 'Selected'),
                              const SizedBox(width: 14),
                              _legend(t.bd, 'Prior'),
                            ]),
                            for (final (name, u, p) in rows) ...[
                              const SizedBox(height: 14),
                              Row(children: [
                                Expanded(child: Text(name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500))),
                                Text(hours(u?.trackedSec),
                                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, fontFeatures: tabular, color: u?.trackedSec == null ? t.na : t.tx)),
                              ]),
                              const SizedBox(height: 5),
                              if (u?.trackedSec != null)
                                _bar(t, (u!.trackedSec! / maxSec).clamp(0, 1).toDouble(), 10, t.ac)
                              else
                                Container(
                                  height: 10,
                                  decoration: BoxDecoration(border: Border.all(color: t.na), borderRadius: BorderRadius.circular(5)),
                                ),
                              const SizedBox(height: 5),
                              _bar(t, p?.trackedSec == null ? 0 : (p!.trackedSec! / maxSec).clamp(0, 1).toDouble(), 6, t.bd),
                              const SizedBox(height: 5),
                              Text(p?.trackedSec == null ? 'Prior day unavailable' : '${hours(p!.trackedSec)} prior day',
                                  style: TextStyle(fontSize: 12, color: t.mu)),
                            ],
                          ]),
                        ),
                        const SizedBox(height: 12),
                        SurfaceCard(
                          padding: EdgeInsets.zero,
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            Container(
                              color: t.sf2,
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              child: _row(t, 'Staff', 'Active', 'Idle', header: true),
                            ),
                            for (final (name, u, _) in rows)
                              Container(
                                decoration: BoxDecoration(border: Border(top: BorderSide(color: t.bd))),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                child: _row(t, name, u == null ? 'Unavailable' : formatDuration(u.activeSec),
                                    u == null ? 'Unavailable' : formatDuration(u.idleSec)),
                              ),
                          ]),
                        ),
                        if (day.gaps.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          ListCard(title: 'Untracked intervals', children: [
                            for (final g in day.gaps)
                              KVRow(
                                '${day.users.where((u) => u.userId == g.userId).firstOrNull?.name ?? 'User'} · '
                                    '${timeIn(g.start, zone)}–${timeIn(g.end, zone)}',
                                '${g.approxMinutes ?? '?'} min',
                              ),
                          ]),
                          const SizedBox(height: 6),
                          Text(day.gaps.first.interpretation, style: TextStyle(fontSize: 12, height: 1.4, color: t.mu)),
                        ],
                        const SizedBox(height: 12),
                        Text('“Unavailable” means Time Doctor returned no value. It is never shown as zero. Screenshots are not collected in this app.',
                            style: TextStyle(fontSize: 12, height: 1.45, color: t.mu)),
                      ]),
                    ),
                  ]);
                },
              ),
      ),
    ]);
  }

  Widget _legend(Color c, String label) => Row(children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 12, color: context.t.mu)),
      ]);

  Widget _bar(AppTokens t, double f, double h, Color c) => Container(
        height: h,
        decoration: BoxDecoration(color: t.sf2, borderRadius: BorderRadius.circular(h / 2)),
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: f,
          child: Container(decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(h / 2))),
        ),
      );

  Widget _row(AppTokens t, String a, String b, String c, {bool header = false}) {
    TextStyle s(String v) => TextStyle(
          fontSize: header ? 12 : 14,
          fontWeight: header ? FontWeight.w600 : FontWeight.w400,
          color: header ? t.mu : v == 'Unavailable' || v == 'Not returned' ? t.na : t.tx,
          fontFeatures: tabular,
        );
    return Row(children: [
      Expanded(flex: 13, child: Text(a, style: s(a).copyWith(fontWeight: header ? FontWeight.w600 : FontWeight.w500))),
      Expanded(flex: 10, child: Text(b, style: s(b))),
      Expanded(flex: 10, child: Text(c, style: s(c))),
    ]);
  }
}
