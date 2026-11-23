import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/payment.dart';
import '../../state/app_state.dart';
import '../../state/providers.dart';
import '../../state/view_models.dart';
import '../theme.dart';
import '../widgets/kit.dart';

class TaskDetailScreen extends ConsumerStatefulWidget {
  const TaskDetailScreen({super.key, required this.taskId});
  final String taskId;
  @override
  ConsumerState<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends ConsumerState<TaskDetailScreen> {
  bool _busy = false;

  Future<void> _review(String status, String toast) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(repositoryProvider).setTaskReview(widget.taskId, status);
      ref.read(dataVersionProvider.notifier).bump();
      if (mounted) showToast(context, toast);
    } on PaymentRuleException catch (e) {
      if (mounted) showToast(context, e.message, icon: Icons.error_outline_rounded);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(sessionProvider)!;
    final snap = ref.watch(snapshotProvider);
    final repo = ref.watch(repositoryProvider);
    final now = ref.watch(clockProvider)();
    final t = context.t;
    return Column(children: [
      DetailHeader(title: 'Task', fallback: '/tasks', trailing: HeaderId(widget.taskId)),
      Expanded(
        child: AsyncBody(
          value: snap,
          builder: (s) {
            final views = taskViews(s, businessDay(now, repo.businessTimezone)).where((v) => v.task.id == widget.taskId);
            if (views.isEmpty) return const EmptyState(icon: Icons.search_off_rounded, title: 'Task not found in the latest report');
            final v = views.first;
            final (pri, priTone) = v.priority;
            final (st, stTone) = v.status;
            final review = v.review;
            return ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 28), children: [
              Text(v.task.subject, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(v.where, style: TextStyle(fontSize: 14, color: t.mu)),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                ToneChip(v.task.priority == null ? pri : '$pri priority', priTone),
                ToneChip(st, stTone),
                if (v.overdue) ToneChip('${v.overdueDays} days overdue', Tone.er),
              ]),
              const SizedBox(height: 16),
              ListCard(children: [
                KVRow('Due date', v.task.dueDate == null ? 'No due date' : fullDate(v.task.dueDate!)),
                KVRow('Assignee', v.assignee),
                KVRow('Type', switch (v.task.type) {
                  'TENANT_REQUEST' => 'Tenant request',
                  'WORK_ORDER' => 'Work order',
                  'INTERNAL_TASK' => 'Internal task',
                  _ => v.task.type ?? 'Not returned',
                }),
                KVRow('DoorLoop status', v.task.status.replaceAll('_', ' ').toLowerCase()),
              ]),
              const SizedBox(height: 16),
              SurfaceCard(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text('Completion', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  _step(
                    v.task.completionClaimed ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                    v.task.completionClaimed ? t.wa : t.na,
                    'Completion claimed',
                    v.task.completionClaimed
                        ? 'DoorLoop status is Completed${v.task.updatedAt == null ? '' : ' · ${whenIn(v.task.updatedAt, now, repo.businessTimezone)}'}. This is a claim, not verification.'
                        : 'Not claimed yet',
                  ),
                  const SizedBox(height: 12),
                  _step(
                    v.verified ? Icons.verified_rounded : v.disputed ? Icons.report_outlined : Icons.radio_button_unchecked_rounded,
                    v.verified ? t.ok : v.disputed ? t.er : t.na,
                    v.disputed ? 'Claim disputed' : 'Completion verified',
                    review != null && (v.verified || v.disputed)
                        ? '${review.reviewer ?? 'Reviewer'} · ${whenIn(review.at, now, repo.businessTimezone)}'
                        : v.task.completionClaimed
                            ? 'Awaiting owner or admin verification'
                            : 'Not verified',
                  ),
                  if (v.claimed && user.isOwnerOrAdmin) ...[
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                        child: OutlinedButton(
                          key: const ValueKey('task-reopen'),
                          onPressed: _busy ? null : () => _review('disputed', 'Claim disputed. Follow up with the contractor.'),
                          child: const Text('Reopen'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          key: const ValueKey('task-verify'),
                          onPressed: _busy ? null : () => _review('verified_complete', 'Completion verified.'),
                          style: FilledButton.styleFrom(minimumSize: const Size(0, 48), backgroundColor: t.ok, foregroundColor: Colors.white),
                          child: const Text('Verify completion'),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    Text('Verify only after an inspection, photo or tenant confirmation. Your review is recorded in the app; DoorLoop is not changed.',
                        style: TextStyle(fontSize: 12, height: 1.4, color: t.mu)),
                  ],
                  if (v.claimed && !user.isOwnerOrAdmin) ...[
                    const SizedBox(height: 10),
                    Text('Owner or admin verifies completion.', style: TextStyle(fontSize: 13, color: t.mu)),
                  ],
                ]),
              ),
              const SizedBox(height: 16),
              const Text('Activity', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Timeline([
                if (review != null && review.at != null)
                  TimelineEntry('${review.label} by ${review.reviewer ?? 'reviewer'}', whenIn(review.at, now, repo.businessTimezone)),
                if (v.task.updatedAt != null)
                  TimelineEntry('Last updated in DoorLoop', whenIn(v.task.updatedAt, now, repo.businessTimezone)),
              ]),
              if (review == null && v.task.updatedAt == null) Text('No activity returned.', style: TextStyle(fontSize: 13, color: t.mu)),
            ]);
          },
        ),
      ),
    ]);
  }

  Widget _step(IconData icon, Color color, String title, String text) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 22, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(text, style: TextStyle(fontSize: 13, height: 1.4, color: context.t.mu)),
          ]),
        ),
      ]);
}
