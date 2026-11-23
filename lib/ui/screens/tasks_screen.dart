import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../models/report.dart';
import '../../state/app_state.dart';
import '../../state/providers.dart';
import '../../state/view_models.dart';
import '../theme.dart';
import '../widgets/kit.dart';

enum _Status { all, overdue, open, claimed, verified }

class TasksScreen extends ConsumerStatefulWidget {
  const TasksScreen({super.key, this.initialStatus});
  final String? initialStatus;
  @override
  ConsumerState<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends ConsumerState<TasksScreen> {
  bool _calendar = false;
  late _Status _status = widget.initialStatus == 'overdue' ? _Status.overdue : _Status.all;
  String? _priority;
  String? _property;
  DateTime? _day;

  @override
  void didUpdateWidget(covariant TasksScreen old) {
    super.didUpdateWidget(old);
    if (widget.initialStatus != old.initialStatus && widget.initialStatus == 'overdue') _status = _Status.overdue;
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(sessionProvider)!;
    final snap = ref.watch(snapshotProvider);
    final repo = ref.watch(repositoryProvider);
    final now = ref.watch(clockProvider)();
    final t = context.t;
    if (!user.canRead(SectionSource.doorloopTasks)) {
      return const EmptyState(icon: Icons.lock_outline_rounded, title: 'Not available for your role');
    }
    return AsyncBody(
      value: snap,
      builder: (s) {
        final today = businessDay(now, repo.businessTimezone);
        final sec = s.latest?[SectionSource.doorloopTasks];
        final all = taskViews(s, today);
        final props = {for (final v in all) ?v.task.propertyName}.toList()..sort();
        return ListView(padding: const EdgeInsets.only(top: 8, bottom: 28), children: [
          PageTitle('Tasks',
              subtitle: 'Maintenance and contractors · DoorLoop · ${sec == null ? 'not in report' : 'synced ${whenIn(sec.collectedAt, now, repo.businessTimezone)}'}'),
          const SizedBox(height: 12),
          Padding(
            padding: pagePad,
            child: Segmented<bool>(
              options: const [(false, 'List'), (true, 'Calendar')],
              selected: _calendar,
              onSelected: (v) => setState(() => _calendar = v),
            ),
          ),
          const SizedBox(height: 12),
          if (s.tasks == null)
            EmptyState(icon: Icons.cloud_off_outlined, title: 'Tasks unavailable', body: sec?.warnings.firstOrNull?.message)
          else if (_calendar)
            ..._calendarView(all, today)
          else
            ..._list(all, props),
          if (s.tasks?.excludedReminders != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text('${s.tasks!.excludedReminders} automatic rent-reminder tasks are hidden. Due dates are not confirmed contractor appointments.',
                  style: TextStyle(fontSize: 12, height: 1.4, color: t.mu)),
            ),
        ]);
      },
    );
  }

  List<Widget> _list(List<TaskView> all, List<String> props) {
    final t = context.t;
    bool statusOk(TaskView v) => switch (_status) {
          _Status.all => true,
          _Status.overdue => v.overdue,
          _Status.open => !v.overdue && !v.task.completionClaimed,
          _Status.claimed => v.claimed,
          _Status.verified => v.verified,
        };
    final list = all
        .where(statusOk)
        .where((v) => _priority == null || v.task.priority == _priority)
        .where((v) => _property == null || v.task.propertyName == _property)
        .toList()
      ..sort((a, b) => (a.task.dueDate ?? DateTime(9999)).compareTo(b.task.dueDate ?? DateTime(9999)));
    return [
      ChipRow<_Status>(
        options: const [
          (_Status.all, 'Any status'),
          (_Status.overdue, 'Overdue'),
          (_Status.open, 'Open'),
          (_Status.claimed, 'Claimed'),
          (_Status.verified, 'Verified'),
        ],
        selected: _status,
        onSelected: (v) => setState(() => _status = v),
      ),
      const SizedBox(height: 10),
      ChipRow<String?>(
        options: const [(null, 'Any priority'), ('HIGH', 'High'), ('MEDIUM', 'Medium'), ('LOW', 'Low')],
        selected: _priority,
        onSelected: (v) => setState(() => _priority = v),
      ),
      const SizedBox(height: 10),
      Padding(
        padding: pagePad,
        child: DropdownButtonFormField<String?>(
          initialValue: _property,
          isExpanded: true,
          decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
          style: TextStyle(fontSize: 14, color: t.tx, fontFamily: kSans),
          items: [
            const DropdownMenuItem(value: null, child: Text('All properties')),
            for (final p in props) DropdownMenuItem(value: p, child: Text(p, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() => _property = v),
        ),
      ),
      const SizedBox(height: 10),
      if (list.isEmpty)
        EmptyState(
          icon: Icons.task_alt_rounded,
          title: 'No tasks match',
          action: 'Clear filters',
          onAction: () => setState(() {
            _status = _Status.all;
            _priority = null;
            _property = null;
          }),
        )
      else
        for (final v in list) Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 10), child: TaskCard(view: v)),
    ];
  }

  List<Widget> _calendarView(List<TaskView> all, DateTime today) {
    final t = context.t;
    final selected = _day ?? today;
    final first = DateTime(today.year, today.month);
    final daysInMonth = DateTime(today.year, today.month + 1, 0).day;
    final lead = first.weekday % 7; // Sunday-first grid
    final cells = lead + daysInMonth;
    final rows = (cells / 7).ceil();
    final dayTasks = all.where((v) => v.task.dueDate != null && daysBetween(v.task.dueDate!, selected) == 0).toList();
    return [
      Padding(
        padding: pagePad,
        child: SurfaceCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(DateFormat('MMMM y').format(first), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Row(children: [
              for (final d in const ['S', 'M', 'T', 'W', 'T', 'F', 'S'])
                Expanded(child: Text(d, textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: t.mu))),
            ]),
            const SizedBox(height: 4),
            for (var r = 0; r < rows; r++)
              Row(children: [
                for (var c = 0; c < 7; c++)
                  Expanded(
                    child: Builder(builder: (_) {
                      final n = r * 7 + c - lead + 1;
                      if (n < 1 || n > daysInMonth) return const SizedBox(height: 46);
                      final date = DateTime(today.year, today.month, n);
                      final ts = all.where((v) => v.task.dueDate != null && daysBetween(v.task.dueDate!, date) == 0).toList();
                      final sel = daysBetween(selected, date) == 0;
                      final isToday = daysBetween(today, date) == 0;
                      final dot = ts.isEmpty ? Colors.transparent : ts.any((v) => v.overdue) ? t.er : t.ac;
                      return Padding(
                        padding: const EdgeInsets.all(1),
                        child: Material(
                          color: sel ? t.sel : Colors.transparent,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                            side: BorderSide(color: isToday && !sel ? t.ac : Colors.transparent, width: 1.5),
                          ),
                          child: InkWell(
                            customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            onTap: () => setState(() => _day = date),
                            child: SizedBox(
                              height: 44,
                              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                                Text('$n', style: TextStyle(fontSize: 14, color: sel ? t.onsel : t.tx, fontFeatures: tabular)),
                                const SizedBox(height: 3),
                                Container(width: 5, height: 5, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
                              ]),
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
              ]),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      Padding(
        padding: pagePad,
        child: Text('${shortDate(selected)}${daysBetween(today, selected) == 0 ? ' · Today' : ''}',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      ),
      const SizedBox(height: 8),
      if (dayTasks.isEmpty)
        Padding(padding: pagePad, child: Text('Nothing due this day.', style: TextStyle(fontSize: 14, color: t.mu)))
      else
        for (final v in dayTasks)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: SurfaceCard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              onTap: () => openRoute(context, '/tasks/${v.task.id}'),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(v.task.subject, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text('${v.where} · ${v.status.$1}', style: TextStyle(fontSize: 13, color: t.mu)),
              ]),
            ),
          ),
    ];
  }
}

class TaskCard extends StatelessWidget {
  const TaskCard({super.key, required this.view});
  final TaskView view;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final (pri, priTone) = view.priority;
    final (st, stTone) = view.status;
    return SurfaceCard(
      onTap: () => openRoute(context, '/tasks/${view.task.id}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(view.task.subject, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
          const SizedBox(width: 8),
          ToneChip(pri, priTone, small: true),
        ]),
        const SizedBox(height: 8),
        Text('${view.where} · ${view.assignee}', style: TextStyle(fontSize: 13, color: t.mu)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (view.overdue) ToneChip('${view.overdueDays} day${view.overdueDays == 1 ? '' : 's'} overdue', Tone.er, icon: Icons.schedule_rounded),
          ToneChip(st, stTone),
          Text(view.dueLabel, style: TextStyle(fontSize: 12, color: t.mu)),
        ]),
      ]),
    );
  }
}
