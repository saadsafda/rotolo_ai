import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/report.dart';
import '../../state/app_state.dart';
import '../../state/providers.dart';
import '../../state/view_models.dart';
import '../theme.dart';
import '../widgets/kit.dart';

class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(sessionProvider)!;
    final snap = ref.watch(snapshotProvider).value;
    final unread = watchUnread(ref);
    final t = context.t;
    final deals = snap == null ? null : dealViews(snap);
    final staff = snap?.staff;
    final attentionSources = snap == null
        ? 0
        : sourceHealth(snap.latest, ref.watch(clockProvider)(), ref.watch(repositoryProvider).staleAfterHours)
            .where((h) => h.status.$2 != Tone.ok)
            .length;
    final items = [
      (Icons.dashboard_outlined, 'Overview', 'See what needs your attention', '/home'),
      if (user.canSeePayments || user.canRead(SectionSource.doorloopRent))
        (Icons.payments_outlined, 'Payments', 'Check rent balances and review payments', '/payments'),
      if (user.canRead(SectionSource.doorloopTasks))
        (Icons.build_outlined, 'Maintenance', 'See open and overdue work', '/tasks'),
      if (user.canRead(SectionSource.fubDeals))
        (
          Icons.handshake_outlined,
          'Deals',
          deals == null ? 'Follow Up Boss' : '${deals.where((d) => d.isOpen).length} open · ${deals.where((d) => d.needsReview).length} need review',
          '/more/deals'
        ),
      if (user.canRead(SectionSource.timeDoctor))
        (
          Icons.groups_outlined,
          'Team activity',
          staff?.workDate == null ? 'Time Doctor' : 'Previous day · ${shortDate(staff!.workDate!)}',
          '/more/team'
        ),
      (Icons.notifications_outlined, 'Notifications', '$unread unread', '/more/notifications'),
      if (user.isOwnerOrAdmin)
        (
          Icons.hub_outlined,
          'Connections',
          attentionSources == 0 ? 'All sources connected' : '$attentionSources source${attentionSources == 1 ? '' : 's'} need attention',
          '/more/integrations'
        ),
      (Icons.settings_outlined, 'Settings', 'Profile, timezone, appearance', '/more/settings'),
    ];
    return ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 28), children: [
      const Text('More', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
      const SizedBox(height: 14),
      SurfaceCard(
        padding: EdgeInsets.zero,
        child: Column(children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) Divider(height: 1, color: t.bd),
            InkWell(
              key: ValueKey('more-${items[i].$2.toLowerCase().replaceAll(' ', '-')}'),
              onTap: () => openRoute(context, items[i].$4),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 64),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(children: [
                    IconTile(items[i].$1, Tone.ac, size: 40),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(items[i].$2, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(items[i].$3, style: TextStyle(fontSize: 13, color: t.mu)),
                      ]),
                    ),
                    Icon(Icons.chevron_right_rounded, size: 22, color: t.mu),
                  ]),
                ),
              ),
            ),
          ],
        ]),
      ),
    ]);
  }
}
