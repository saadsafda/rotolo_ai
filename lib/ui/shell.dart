import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/app_user.dart';
import '../models/report.dart';
import '../state/providers.dart';
import '../state/view_models.dart';
import 'theme.dart';

class NavDest {
  const NavDest(this.branch, this.label, this.icon, this.activeIcon);
  final int branch;
  final String label;
  final IconData icon;
  final IconData activeIcon;
}

/// Bottom-bar destinations for a user. Tabs for sources the user cannot read are
/// not shown at all (server RLS is still the real gate).
List<NavDest> destinationsFor(AppUser user) => [
  const NavDest(0, 'Ask', Icons.chat_bubble_outline_rounded, Icons.chat_bubble_rounded),
  const NavDest(1, 'Home', Icons.home_outlined, Icons.home_rounded),
  const NavDest(2, 'Reports', Icons.summarize_outlined, Icons.summarize_rounded),
  if (user.canSeePayments || user.canRead(SectionSource.doorloopRent))
    const NavDest(3, 'Payments', Icons.payments_outlined, Icons.payments_rounded),
  if (user.canRead(SectionSource.doorloopTasks)) const NavDest(4, 'Tasks', Icons.build_outlined, Icons.build_rounded),
  const NavDest(5, 'More', Icons.menu_rounded, Icons.menu_rounded),
];

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(sessionProvider);
    if (user == null) return const SizedBox.shrink();
    final t = context.t;
    final dests = destinationsFor(user);
    return Scaffold(
      backgroundColor: t.bg,
      body: Column(
        children: [
          shell.currentIndex == 0 ? DemoStrip(background: t.nv, foreground: Colors.white) : const DemoStrip(),
          const StaleBanner(),
          Expanded(
            child: MediaQuery.removePadding(context: context, removeTop: true, child: shell),
          ),
        ],
      ),
      bottomNavigationBar: NavBar(
        destinations: dests,
        current: shell.currentIndex,
        onTap: (branch) => shell.goBranch(branch, initialLocation: branch == shell.currentIndex),
      ),
    );
  }
}

/// Status-bar inset plus a "DEMO DATA" pill whenever anything shown is not live.
class DemoStrip extends ConsumerWidget {
  const DemoStrip({super.key, this.background, this.foreground});
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(repositoryProvider);
    final latest = ref.watch(reportsProvider).value;
    final notLive = repo.isSynthetic || (latest != null && latest.isNotEmpty && latest.first.dataMode != 'live');
    final t = context.t;
    final fg = foreground ?? t.tx;
    return Container(
      color: background ?? t.bg,
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: notLive
          ? SizedBox(
              height: 26,
              child: Center(
                child: Tooltip(
                  message: 'Invented test data. No real tenant or financial records.',
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: fg.withValues(alpha: .85)),
                    ),
                    child: Text(
                      'DEMO DATA',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: .6,
                        color: fg.withValues(alpha: .85),
                      ),
                    ),
                  ),
                ),
              ),
            )
          : const SizedBox(height: 4),
    );
  }
}

/// Warns when the newest report is older than the freshness limit.
class StaleBanner extends ConsumerWidget {
  const StaleBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(reportsProvider).value;
    if (list == null || list.isEmpty) return const SizedBox.shrink();
    final repo = ref.watch(repositoryProvider);
    final now = ref.watch(clockProvider)();
    final last = list.first.generatedAt;
    final age = now.difference(last);
    if (age <= Duration(hours: repo.staleAfterHours)) return const SizedBox.shrink();
    final t = context.t;
    final (bg, fg) = t.tone(Tone.wa);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        border: Border(bottom: BorderSide(color: t.bd)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.history_rounded, size: 18, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  const TextSpan(
                    text: 'Data may be out of date. ',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextSpan(
                    text:
                        'Last report was generated ${age.inHours} hours ago (${whenIn(last, now, repo.businessTimezone)}).',
                  ),
                ],
              ),
              style: TextStyle(fontSize: 13, height: 1.35, color: fg),
            ),
          ),
        ],
      ),
    );
  }
}

class NavBar extends StatelessWidget {
  const NavBar({super.key, required this.destinations, required this.current, required this.onTap});
  final List<NavDest> destinations;
  final int current;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.0,
      child: Material(
        color: t.nv,
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
            child: Row(
              children: [
                for (final d in destinations)
                  Expanded(
                    child: Semantics(
                      selected: d.branch == current,
                      button: true,
                      label: d.label,
                      excludeSemantics: true,
                      child: InkResponse(
                        key: ValueKey('nav-${d.label.toLowerCase()}'),
                        onTap: () => onTap(d.branch),
                        radius: 36,
                        child: SizedBox(
                          height: 56,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                width: 56,
                                height: 30,
                                decoration: BoxDecoration(
                                  color: d.branch == current ? NavColors.pill : Colors.transparent,
                                  borderRadius: BorderRadius.circular(15),
                                ),
                                child: Center(
                                  child: Icon(
                                    d.branch == current ? d.activeIcon : d.icon,
                                    size: 22,
                                    color: d.branch == current ? NavColors.active : NavColors.inactive,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                d.label,
                                maxLines: 1,
                                overflow: TextOverflow.fade,
                                softWrap: false,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: d.branch == current ? FontWeight.w600 : FontWeight.w500,
                                  color: d.branch == current ? NavColors.active : NavColors.inactive,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
