import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/time_format.dart';
import '../../models/app_user.dart';
import '../../models/assistant.dart';
import '../../models/report.dart';
import '../../state/app_state.dart';
import '../../state/assistant_state.dart';
import '../../state/providers.dart';
import '../theme.dart';
import '../widgets/brand.dart';
import '../widgets/kit.dart';

/// "Ask your portfolio": the first screen after sign-in.
class AssistantScreen extends ConsumerStatefulWidget {
  const AssistantScreen({super.key});
  @override
  ConsumerState<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends ConsumerState<AssistantScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
        }
      });

  Future<void> _send(String uid, String text) async {
    if (text.trim().isEmpty) return;
    _input.clear();
    _toBottom();
    await ref.read(assistantThreadsProvider.notifier).send(uid, text);
    _toBottom();
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(sessionProvider)!;
    final thread = ref.watch(assistantThreadsProvider)[user.id] ?? const <ChatEntry>[];
    final busy = thread.any((e) => e.pending);
    final t = context.t;
    final last = thread.lastWhere((e) => !e.user && e.reply != null, orElse: () => ChatEntry(id: -1, user: false, text: '', at: DateTime(0)));
    final suggestions = (last.reply?.suggestions.isNotEmpty ?? false) ? last.reply!.suggestions : defaultPrompts(user);
    ref.listen(assistantThreadsProvider, (_, _) => _toBottom());

    return Column(children: [
      _Header(user: user, onAsk: (q) => _send(user.id, q), onNewChat: () => ref.read(assistantThreadsProvider.notifier).clear(user.id)),
      Expanded(
        child: Container(
          color: t.bg,
          child: thread.isEmpty
              ? _Welcome(user: user, onAsk: (q) => _send(user.id, q))
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  itemCount: thread.length + 1,
                  itemBuilder: (context, i) {
                    if (i == 0) return _DayStamp(at: thread.first.at);
                    final e = thread[i - 1];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 18),
                      child: e.user
                          ? _UserBubble(text: e.text)
                          : _AssistantMessage(
                              entry: e,
                              onRetry: () => ref.read(assistantThreadsProvider.notifier).retry(user.id, e.id),
                              onFeedback: (v) => ref.read(assistantThreadsProvider.notifier).setFeedback(user.id, e.id, v),
                            ),
                    );
                  },
                ),
        ),
      ),
      Container(
        color: t.bg,
        padding: const EdgeInsets.fromLTRB(0, 6, 0, 10),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: suggestions.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) => _SuggestionChip(text: suggestions[i], onTap: busy ? null : () => _send(user.id, suggestions[i])),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _Composer(controller: _input, focus: _focus, busy: busy, onSend: () => _send(user.id, _input.text)),
          ),
        ]),
      ),
    ]);
  }
}

List<String> defaultPrompts(AppUser user) => [
      if (user.canRead(SectionSource.doorloopRent)) 'Which tenants are late on rent?',
      if (user.canRead(SectionSource.fubDeals)) 'Which deals need evidence review?',
      if (user.canRead(SectionSource.doorloopTasks)) 'What maintenance is overdue?',
      if (user.canRead(SectionSource.fubDeals)) 'Which deals close in the next two weeks?',
      if (user.canRead(SectionSource.timeDoctor)) 'How many hours did the team track yesterday?',
      if (user.canSeePayments) 'Any outside payments waiting for review?',
      'Is the latest report complete?',
    ];

// ───────── header ─────────

class _Header extends ConsumerWidget {
  const _Header({required this.user, required this.onAsk, required this.onNewChat});
  final AppUser user;
  final ValueChanged<String> onAsk;
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final snap = ref.watch(snapshotProvider).value;
    final properties = {for (final l in snap?.rent?.leases ?? const []) l.propertyName}.length;
    final chips = <(IconData, String, String)>[
      if (user.canRead(SectionSource.doorloopRent))
        (Icons.storage_rounded, properties > 0 ? '$properties properties' : 'Properties', 'Give me a rent overview across my properties'),
      if (user.canRead(SectionSource.doorloopRent)) (Icons.description_outlined, 'Leases & rent', 'Which tenants are late on rent?'),
      if (user.canSeePayments) (Icons.payments_outlined, 'Payments', 'Any outside payments waiting for review?'),
      if (user.canRead(SectionSource.fubDeals)) (Icons.handshake_outlined, 'Deals', 'Which deals need evidence review?'),
      if (user.canRead(SectionSource.doorloopTasks)) (Icons.build_outlined, 'Maintenance', 'What maintenance is overdue?'),
    ];
    return Container(
      color: t.nv,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const BrandMark(size: 44),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Ask your portfolio', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: Colors.white)),
              SizedBox(height: 2),
              Text('GROUNDED IN YOUR DATA',
                  style: TextStyle(fontFamily: kMono, fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w500, color: NavColors.active)),
            ]),
          ),
          Material(
            color: Colors.white.withValues(alpha: .08),
            borderRadius: BorderRadius.circular(12),
            child: PopupMenuButton<String>(
              tooltip: 'Options',
              icon: const Icon(Icons.tune_rounded, color: Colors.white),
              onSelected: (v) => v == 'new' ? onNewChat() : openRoute(context, '/more/settings'),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'new', child: Text('New conversation')),
                PopupMenuItem(value: 'settings', child: Text('Settings')),
              ],
            ),
          ),
        ]),
        if (chips.isNotEmpty) ...[
          const SizedBox(height: 14),
          SizedBox(
            height: 42,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: chips.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) => Material(
                color: Colors.white.withValues(alpha: .08),
                shape: const StadiumBorder(),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: () => onAsk(chips[i].$3),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(children: [
                      Icon(chips[i].$1, size: 17, color: NavColors.active),
                      const SizedBox(width: 6),
                      Text(chips[i].$2,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: NavColors.active)),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

// ───────── conversation pieces ─────────

class _Welcome extends StatelessWidget {
  const _Welcome({required this.user, required this.onAsk});
  final AppUser user;
  final ValueChanged<String> onAsk;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ListView(padding: const EdgeInsets.fromLTRB(20, 28, 20, 20), children: [
      Text('Hi ${user.firstName}, what would you like to know?',
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: -.2)),
      const SizedBox(height: 8),
      Text('Answers come from your latest synced report: DoorLoop rent and tasks, Follow Up Boss deals, '
          'attorney emails and Time Doctor hours. Every figure links to its source.',
          style: TextStyle(fontSize: 14, height: 1.5, color: t.mu)),
      const SizedBox(height: 20),
      for (final q in defaultPrompts(user).take(5))
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SurfaceCard(
            onTap: () => onAsk(q),
            child: Row(children: [
              Icon(Icons.auto_awesome_outlined, size: 18, color: t.ac),
              const SizedBox(width: 12),
              Expanded(child: Text(q, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500))),
              Icon(Icons.north_east_rounded, size: 18, color: t.mu),
            ]),
          ),
        ),
    ]);
  }
}

class _DayStamp extends ConsumerWidget {
  const _DayStamp({required this.at});
  final DateTime at;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zone = ref.watch(repositoryProvider).businessTimezone;
    final local = inZone(at, zone);
    final now = inZone(ref.watch(clockProvider)(), zone);
    final day = local.year == now.year && local.month == now.month && local.day == now.day ? 'TODAY' : DateFormat('MMM d').format(local).toUpperCase();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Text('$day · ${DateFormat('h:mm a').format(local)}',
          textAlign: TextAlign.center, style: TextStyle(fontFamily: kMono, fontSize: 12, letterSpacing: 1.2, color: context.t.mu)),
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .78),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: t.ac,
            borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18), topRight: Radius.circular(18), bottomLeft: Radius.circular(18), bottomRight: Radius.circular(6)),
          ),
          child: SelectableText(text, style: TextStyle(fontSize: 15.5, height: 1.4, color: t.onac)),
        ),
      ),
    );
  }
}

class _AssistantMessage extends StatelessWidget {
  const _AssistantMessage({required this.entry, required this.onRetry, required this.onFeedback});
  final ChatEntry entry;
  final VoidCallback onRetry;
  final ValueChanged<int> onFeedback;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final reply = entry.reply;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const BrandMark(size: 34),
      const SizedBox(width: 10),
      Expanded(
        child: entry.pending
            ? const Padding(padding: EdgeInsets.only(top: 8), child: _TypingDots())
            : entry.error != null
                ? NoticeBox(
                    tone: Tone.er,
                    icon: Icons.error_outline_rounded,
                    text: entry.error!,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton(
                          onPressed: onRetry, style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)), child: const Text('Try again')),
                    ),
                  )
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Padding(padding: const EdgeInsets.only(top: 4), child: RichAnswer(text: entry.text)),
                    if (reply != null && reply.dataMode != null && reply.dataMode != 'live') ...[
                      const SizedBox(height: 8),
                      const Align(alignment: Alignment.centerLeft, child: ToneChip('Demo data', Tone.wa, icon: Icons.science_outlined)),
                    ],
                    if (reply != null) ..._blocks(reply.blocks),
                    if (reply != null && reply.sources.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Row(children: [
                        Icon(Icons.verified_outlined, size: 15, color: t.mu),
                        const SizedBox(width: 6),
                        Text('SOURCES · ${reply.sources.length} RECORD${reply.sources.length == 1 ? '' : 'S'}',
                            style: TextStyle(fontFamily: kMono, fontSize: 12, letterSpacing: 1.2, color: t.mu)),
                      ]),
                      const SizedBox(height: 8),
                      for (final s in reply.sources) Padding(padding: const EdgeInsets.only(bottom: 8), child: _SourceCard(source: s)),
                    ],
                    if (reply?.asOf != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Consumer(builder: (context, ref, _) {
                          final zone = ref.watch(repositoryProvider).businessTimezone;
                          return Text('From the report generated ${formatInstant(reply!.asOf, zone)}',
                              style: TextStyle(fontSize: 12, color: t.mu));
                        }),
                      ),
                    const SizedBox(height: 8),
                    _Actions(entry: entry, onFeedback: onFeedback),
                  ]),
      ),
    ]);
  }

  List<Widget> _blocks(List<AssistantBlock> blocks) {
    final out = <Widget>[];
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      final next = i + 1 < blocks.length ? blocks[i + 1] : null;
      out.add(const SizedBox(height: 12));
      if (b is MetricBlock && next is BarsBlock) {
        out.add(SurfaceCard(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [_Metric(b), const SizedBox(height: 18), _Bars(next)])));
        i++;
      } else {
        out.add(switch (b) {
          MetricBlock() => SurfaceCard(padding: const EdgeInsets.all(16), child: _Metric(b)),
          BarsBlock() => SurfaceCard(padding: const EdgeInsets.fromLTRB(16, 16, 16, 14), child: _Bars(b)),
          ListBlock() => _ListCard(b),
          DraftBlock() => _DraftCard(b),
        });
      }
    }
    return out;
  }
}

/// Answer text with **bold** spans; dollar amounts are emphasised in teal.
class RichAnswer extends StatelessWidget {
  const RichAnswer({super.key, required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final spans = <InlineSpan>[];
    final parts = text.split('**');
    final money = RegExp(r'\$\d[\d,]*(?:\.\d+)?k?');
    for (var i = 0; i < parts.length; i++) {
      final bold = i.isOdd;
      var rest = parts[i];
      while (rest.isNotEmpty) {
        final m = money.firstMatch(rest);
        if (m == null) {
          spans.add(TextSpan(text: rest, style: bold ? const TextStyle(fontWeight: FontWeight.w700) : null));
          break;
        }
        if (m.start > 0) spans.add(TextSpan(text: rest.substring(0, m.start), style: bold ? const TextStyle(fontWeight: FontWeight.w700) : null));
        spans.add(TextSpan(text: m.group(0), style: TextStyle(fontWeight: FontWeight.w700, color: t.ac, fontFeatures: tabular)));
        rest = rest.substring(m.end);
      }
    }
    return SelectableText.rich(TextSpan(children: spans), style: TextStyle(fontSize: 16, height: 1.5, color: t.tx));
  }
}

Tone _tone(String? s) => switch (s) {
      'ok' => Tone.ok,
      'wa' => Tone.wa,
      'er' => Tone.er,
      'ac' => Tone.ac,
      _ => Tone.na,
    };

class _Metric extends StatelessWidget {
  const _Metric(this.b);
  final MetricBlock b;
  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: Text(b.label.toUpperCase(),
              style: TextStyle(fontFamily: kMono, fontSize: 12, letterSpacing: 1.3, fontWeight: FontWeight.w500, color: t.mu)),
        ),
        if (b.chipText != null) ToneChip(b.chipText!, _tone(b.chipTone)),
      ]),
      const SizedBox(height: 6),
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(b.value, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w700, letterSpacing: -.5, fontFeatures: tabular)),
      ),
      if (b.caption != null) ...[
        const SizedBox(height: 4),
        Text(b.caption!, style: TextStyle(fontSize: 14, height: 1.35, color: t.mu)),
      ],
    ]);
  }
}

class _Bars extends StatelessWidget {
  const _Bars(this.b);
  final BarsBlock b;
  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final max = b.bars.fold<double>(0, (a, x) => x.value > a ? x.value : a);
    const h = 92.0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (b.title != null) ...[Text(b.title!, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)), const SizedBox(height: 10)],
      SizedBox(
        height: h + 22,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (final x in b.bars)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                  Text(x.display,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: x.highlight ? t.ac : t.mu, fontFeatures: tabular)),
                  const SizedBox(height: 4),
                  Container(
                    height: max <= 0 ? 4 : (x.value / max * h).clamp(4, h),
                    decoration: BoxDecoration(color: x.highlight ? t.ac : t.acs, borderRadius: BorderRadius.circular(4)),
                  ),
                ]),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 8),
      Row(children: [
        for (final x in b.bars)
          Expanded(
            child: Text(x.label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: kMono, fontSize: 11, color: t.mu)),
          ),
      ]),
    ]);
  }
}

class _ListCard extends StatelessWidget {
  const _ListCard(this.b);
  final ListBlock b;
  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(b.title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        for (var i = 0; i < b.items.length; i++) ...[
          if (i > 0) Divider(height: 1, color: t.bd),
          InkWell(
            onTap: b.items[i].route == null ? null : () => openRoute(context, b.items[i].route!),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: t.fg(_tone(b.items[i].tone)), shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(b.items[i].title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, height: 1.3)),
                    if (b.items[i].subtitle != null)
                      Text(b.items[i].subtitle!, style: TextStyle(fontSize: 12.5, height: 1.3, color: t.mu)),
                  ]),
                ),
                if (b.items[i].trailing != null) ...[
                  const SizedBox(width: 8),
                  Text(b.items[i].trailing!,
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          fontFeatures: tabular,
                          color: _tone(b.items[i].tone) == Tone.na ? t.tx : t.fg(_tone(b.items[i].tone)))),
                ],
                if (b.items[i].route != null) Icon(Icons.chevron_right_rounded, size: 18, color: t.mu),
              ]),
            ),
          ),
        ],
      ]),
    );
  }
}

class _DraftCard extends StatelessWidget {
  const _DraftCard(this.b);
  final DraftBlock b;
  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return SurfaceCard(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.edit_note_rounded, size: 20, color: t.ac),
          const SizedBox(width: 8),
          Expanded(child: Text(b.title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
          const ToneChip('Not sent', Tone.na, small: true),
        ]),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: t.sf2, borderRadius: BorderRadius.circular(12), border: Border.all(color: t.bd)),
          child: SelectableText(b.body, style: const TextStyle(fontSize: 14, height: 1.5)),
        ),
        const SizedBox(height: 8),
        Text(b.note, style: TextStyle(fontSize: 12.5, height: 1.4, color: t.wa)),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: b.body));
              showToast(context, 'Draft copied. Nothing was sent.');
            },
            icon: Icon(Icons.copy_rounded, size: 16, color: t.ac),
            label: const Text('Copy draft'),
          ),
        ),
      ]),
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({required this.source});
  final AssistantSource source;
  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final (icon, tone) = switch (source.kind) {
      'ledger' => (Icons.receipt_long_outlined, Tone.ac),
      'lease' => (Icons.description_outlined, Tone.wa),
      'deal' => (Icons.handshake_outlined, Tone.ac),
      'email' => (Icons.mail_outline_rounded, Tone.wa),
      'tasks' => (Icons.build_outlined, Tone.er),
      'time' => (Icons.timer_outlined, Tone.ac),
      'payments' => (Icons.payments_outlined, Tone.ok),
      _ => (Icons.summarize_outlined, Tone.na),
    };
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      onTap: source.route == null ? null : () => openRoute(context, source.route!),
      child: Row(children: [
        IconTile(icon, tone, size: 38),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(source.title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
            Text(source.subtitle, style: TextStyle(fontSize: 12.5, color: t.mu)),
          ]),
        ),
        if (source.route != null) Icon(Icons.chevron_right_rounded, size: 20, color: t.mu),
      ]),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.entry, required this.onFeedback});
  final ChatEntry entry;
  final ValueChanged<int> onFeedback;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    Widget btn(IconData icon, String tip, VoidCallback? onTap, {bool on = false}) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Material(
            color: on ? t.acs : t.sf,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: on ? t.ac : t.bd)),
            child: InkWell(
              customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              onTap: onTap,
              child: Tooltip(message: tip, child: SizedBox(width: 40, height: 40, child: Icon(icon, size: 19, color: on ? t.ac : t.mu))),
            ),
          ),
        );
    final route = entry.reply?.sources.where((s) => s.route != null).firstOrNull?.route;
    return Row(children: [
      btn(entry.feedback == 1 ? Icons.thumb_up_rounded : Icons.thumb_up_outlined, 'Helpful', () => onFeedback(1), on: entry.feedback == 1),
      btn(entry.feedback == -1 ? Icons.thumb_down_rounded : Icons.thumb_down_outlined, 'Not helpful', () => onFeedback(-1),
          on: entry.feedback == -1),
      const Spacer(),
      btn(Icons.copy_rounded, 'Copy answer', () {
        Clipboard.setData(ClipboardData(text: entry.text));
        showToast(context, 'Answer copied.');
      }),
      if (route != null) btn(Icons.open_in_new_rounded, 'Open record', () => openRoute(context, route)),
    ]);
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      label: 'Assistant is checking your records',
      child: Row(children: [
        AnimatedBuilder(
          animation: _c,
          builder: (_, _) => Row(children: [
            for (var i = 0; i < 3; i++)
              Container(
                margin: const EdgeInsets.only(right: 5),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: t.ac.withValues(alpha: .3 + .7 * (((_c.value * 3 - i) % 3) < 1 ? 1 - ((_c.value * 3 - i) % 3) : 0)),
                ),
              ),
          ]),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text('Checking your records…', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: t.mu)),
        ),
      ]),
    );
  }
}

class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.text, required this.onTap});
  final String text;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Material(
      color: t.sf,
      shape: StadiumBorder(side: BorderSide(color: t.bd)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(children: [
            Icon(Icons.auto_awesome_outlined, size: 16, color: t.ac),
            const SizedBox(width: 6),
            Text(text, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: onTap == null ? t.mu : t.tx)),
          ]),
        ),
      ),
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({required this.controller, required this.focus, required this.busy, required this.onSend});
  final TextEditingController controller;
  final FocusNode focus;
  final bool busy;
  final VoidCallback onSend;
  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final canSend = !widget.busy && widget.controller.text.trim().isNotEmpty;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 4, 6, 4),
      decoration: BoxDecoration(
        color: t.sf,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: t.bd),
        boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 10, offset: Offset(0, 2))],
      ),
      child: Row(children: [
        Expanded(
          child: TextField(
            key: const ValueKey('assistant-input'),
            controller: widget.controller,
            focusNode: widget.focus,
            minLines: 1,
            maxLines: 4,
            maxLength: 2000,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => canSend ? widget.onSend() : null,
            style: const TextStyle(fontSize: 15.5),
            decoration: InputDecoration(
              hintText: 'Ask about rent, deals, leases…',
              counterText: '',
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
              hintStyle: TextStyle(color: t.mu),
            ),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 48,
          height: 48,
          child: FilledButton(
            key: const ValueKey('assistant-send'),
            onPressed: canSend ? widget.onSend : null,
            style: FilledButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(48, 48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: widget.busy
                ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: t.mu))
                : const Icon(Icons.arrow_upward_rounded, size: 24),
          ),
        ),
      ]),
    );
  }
}
