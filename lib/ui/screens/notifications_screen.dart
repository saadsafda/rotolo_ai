import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/time_format.dart';
import '../../state/app_state.dart';
import '../../state/providers.dart';
import '../../state/view_models.dart';
import '../theme.dart';
import '../widgets/kit.dart';

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});
  @override
  ConsumerState<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  String? _category;

  @override
  Widget build(BuildContext context) {
    final list = watchNotifications(ref);
    final read = watchReadIds(ref);
    final userId = ref.watch(sessionProvider)!.id;
    final repo = ref.watch(repositoryProvider);
    final now = ref.watch(clockProvider)();
    final t = context.t;
    return Column(children: [
      DetailHeader(
        title: 'Notifications',
        fallback: '/more',
        trailing: TextButton(
          onPressed: () => ref.read(readNotificationsProvider.notifier).markAll(userId, (list.value ?? const []).map((n) => n.id)),
          child: const Text('Mark all read'),
        ),
      ),
      Expanded(
        child: AsyncBody(
          value: list,
          builder: (all) {
            final shown = all.where((n) => _category == null || n.category == _category).toList();
            final groups = <String, List<AppNotification>>{};
            for (final n in shown) {
              groups.putIfAbsent(notificationGroup(n.at, now, repo.businessTimezone), () => []).add(n);
            }
            return ListView(padding: const EdgeInsets.only(bottom: 28), children: [
              const SizedBox(height: 4),
              ChipRow<String?>(
                options: const [(null, 'All'), ('Reports', 'Reports'), ('Payments', 'Payments'), ('Tasks', 'Tasks'), ('Sync', 'Sync')],
                selected: _category,
                onSelected: (v) => setState(() => _category = v),
              ),
              if (shown.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(40),
                  child: Text('No notifications in this category.', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: t.mu)),
                ),
              for (final g in const ['Today', 'Yesterday', 'Earlier'])
                if (groups[g] != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text(g, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: t.mu)),
                      const SizedBox(height: 6),
                      Container(
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(color: t.sf2, border: Border.all(color: t.bd), borderRadius: BorderRadius.circular(16)),
                        child: Column(children: [
                          for (var i = 0; i < groups[g]!.length; i++) ...[
                            if (i > 0) Divider(height: 1, color: t.bd),
                            _Row(n: groups[g]![i], unread: !read.contains(groups[g]![i].id), now: now, zone: repo.businessTimezone),
                          ],
                        ]),
                      ),
                    ]),
                  ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: Text('In-app alerts are based on recent reports and requests.',
                    style: TextStyle(fontSize: 12, height: 1.4, color: t.mu)),
              ),
            ]);
          },
        ),
      ),
    ]);
  }
}

class _Row extends ConsumerWidget {
  const _Row({required this.n, required this.unread, required this.now, required this.zone});
  final AppNotification n;
  final bool unread;
  final DateTime now;
  final String zone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final local = inZone(n.at, zone);
    final at = notificationGroup(n.at, now, zone) == 'Today' ? DateFormat('h:mm a').format(local) : DateFormat('MMM d').format(local);
    return Material(
      color: unread ? t.sf : Colors.transparent,
      child: InkWell(
        onTap: () {
          ref.read(readNotificationsProvider.notifier).markRead(ref.read(sessionProvider)!.id, n.id);
          openRoute(context, n.route);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            IconTile(n.icon, n.tone),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(n.title, style: TextStyle(fontSize: 14, height: 1.35, fontWeight: unread ? FontWeight.w600 : FontWeight.w500)),
                const SizedBox(height: 2),
                Text(n.body, style: TextStyle(fontSize: 13, height: 1.35, color: t.mu)),
                const SizedBox(height: 2),
                Text('${n.category} · $at', style: TextStyle(fontSize: 12, color: t.mu)),
              ]),
            ),
            if (unread)
              Semantics(
                label: 'Unread',
                child: Container(
                  margin: const EdgeInsets.only(top: 6, left: 8),
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: t.ac, shape: BoxShape.circle),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
