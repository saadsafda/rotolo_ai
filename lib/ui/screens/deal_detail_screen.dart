import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/payloads.dart';
import '../../models/payment.dart';
import '../../models/report.dart';
import '../../state/app_state.dart';
import '../../state/providers.dart';
import '../../state/view_models.dart';
import '../theme.dart';
import '../widgets/kit.dart';

class DealDetailScreen extends ConsumerStatefulWidget {
  const DealDetailScreen({super.key, required this.dealId});
  final int dealId;
  @override
  ConsumerState<DealDetailScreen> createState() => _DealDetailScreenState();
}

class _DealDetailScreenState extends ConsumerState<DealDetailScreen> {
  bool _busy = false;

  Future<void> _markReviewed() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(repositoryProvider).markEvidenceReviewed(widget.dealId);
      ref.read(dataVersionProvider.notifier).bump();
      if (mounted) showToast(context, 'Marked reviewed. Stage unchanged in Follow Up Boss.');
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
    final zone = repo.businessTimezone;
    final t = context.t;
    return Column(children: [
      DetailHeader(title: 'Deal', fallback: '/more/deals', trailing: HeaderId('${widget.dealId}')),
      Expanded(
        child: AsyncBody(
          value: snap,
          builder: (s) {
            final match = dealViews(s).where((d) => d.deal.id == widget.dealId);
            if (match.isEmpty) return const EmptyState(icon: Icons.search_off_rounded, title: 'Deal not found in the latest report');
            final v = match.first;
            final d = v.deal;
            final mailSec = s.latest?[SectionSource.emailEvidence];
            return ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 28), children: [
              Text(d.property, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text('${d.pipeline} · ${d.classificationLabel}', style: TextStyle(fontSize: 14, color: t.mu)),
              const SizedBox(height: 16),
              ListCard(children: [
                KVRow('Stage · Follow Up Boss', '', trailing: ToneChip(d.stage, v.stageTone)),
                KVRow('Contact', v.client),
                KVRow('Assigned', d.assignedUsers.isEmpty ? 'Unassigned' : d.assignedUsers.join(', ')),
              ]),
              if (v.needsReview) ...[
                const SizedBox(height: 16),
                const NoticeBox(
                  tone: Tone.wa,
                  icon: Icons.rule_rounded,
                  title: 'Needs review.',
                  text: 'Email evidence is ambiguous. The stage shown comes from Follow Up Boss only. An email does not confirm a closing.',
                ),
              ],
              if (v.review != null) ...[
                const SizedBox(height: 16),
                NoticeBox(
                  tone: Tone.ac,
                  icon: Icons.fact_check_outlined,
                  text: 'Evidence marked reviewed by ${v.review!.reviewer} · ${whenIn(v.review!.at, now, zone)}. Stage unchanged.',
                ),
              ],
              if (v.isClosedVerified) ...[
                const SizedBox(height: 16),
                const NoticeBox(tone: Tone.ok, icon: Icons.verified_outlined, text: 'Closed stage set in Follow Up Boss.'),
              ],
              for (final f in d.flags) ...[
                const SizedBox(height: 10),
                NoticeBox(tone: Tone.wa, icon: Icons.flag_outlined, text: f),
              ],
              const SizedBox(height: 16),
              const SectionLabel('Important dates'),
              const SizedBox(height: 8),
              ListCard(children: [
                KVRow('Projected close', d.projectedCloseDate == null ? 'Not set' : fullDate(d.projectedCloseDate!)),
                KVRow(
                  'Days to projected close',
                  d.daysToProjectedClose == null
                      ? 'Not returned'
                      : d.daysToProjectedClose! < 0
                          ? '${-d.daysToProjectedClose!} days past'
                          : '${d.daysToProjectedClose} days',
                ),
                KVRow('Days in stage', d.daysInStage == null ? 'Not returned' : '${d.daysInStage}'),
              ]),
              const SizedBox(height: 16),
              const SectionLabel('Attorney email evidence · Gmail'),
              const SizedBox(height: 8),
              if (!user.canRead(SectionSource.emailEvidence))
                Text('Email evidence is not available for your role.', style: TextStyle(fontSize: 14, color: t.mu))
              else if (v.evidence == null)
                Text('Email evidence was not returned in the latest report.', style: TextStyle(fontSize: 14, color: t.mu))
              else ...[
                if (v.evidenceStatus != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(v.evidenceStatus!.label, style: TextStyle(fontSize: 13, color: t.mu)),
                  ),
                for (final e in v.items) ...[_EmailCard(item: e, now: now, zone: zone), const SizedBox(height: 10)],
                if (v.items.isEmpty) Text('No matched attorney emails.', style: TextStyle(fontSize: 14, color: t.mu)),
                if (mailSec != null)
                  for (final w in mailSec.warnings)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(w.message, style: TextStyle(fontSize: 12, height: 1.4, color: t.mu)),
                    ),
              ],
              if (v.needsReview && user.isOwnerOrAdmin && user.canRead(SectionSource.emailEvidence)) ...[
                const SizedBox(height: 12),
                OutlinedButton(
                  key: const ValueKey('mark-reviewed'),
                  onPressed: _busy ? null : _markReviewed,
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  child: const Text('Mark evidence reviewed'),
                ),
              ],
              const SizedBox(height: 16),
              const SectionLabel('Timeline'),
              const SizedBox(height: 4),
              Timeline([
                if (d.latestCommunication?.date != null)
                  TimelineEntry(
                    'Latest ${d.latestCommunication!.type?.toLowerCase() ?? 'communication'} '
                    '${d.latestCommunication!.direction ?? ''} · ${d.latestCommunication!.personName ?? 'contact'} (FUB)',
                    whenIn(d.latestCommunication!.date, now, zone),
                  ),
                if (d.daysInStage != null)
                  TimelineEntry('Stage set to ${d.stage} (FUB)', '${d.daysInStage} days ago'),
              ]),
            ]);
          },
        ),
      ),
    ]);
  }
}

class _EmailCard extends StatelessWidget {
  const _EmailCard({required this.item, required this.now, required this.zone});
  final EvidenceItem item;
  final DateTime now;
  final String zone;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final (label, tone) = item.isAmbiguous
        ? ('Ambiguous match', Tone.wa)
        : switch (item.kind) {
            'ATTORNEY_MESSAGE' => ('Attorney message', Tone.ac),
            'VA_OUTREACH' => ('VA outreach', Tone.na),
            _ => ('Correspondence', Tone.na),
          };
    return SurfaceCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.subject, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text('${item.from} · ${whenIn(item.date, now, zone)}', style: TextStyle(fontSize: 12, color: t.mu)),
            ]),
          ),
          const SizedBox(width: 8),
          ToneChip(label, tone, small: true),
        ]),
        const SizedBox(height: 8),
        // Untrusted email text: shown as plain text only. It never changes deal status.
        Container(
          padding: const EdgeInsets.only(left: 10),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: t.bd, width: 2))),
          child: Text(item.excerpt, style: TextStyle(fontSize: 14, height: 1.5, color: t.mu)),
        ),
        if (item.isAmbiguous) ...[
          const SizedBox(height: 8),
          Text(
            'This email matched more than one deal at the same address. It does not confirm a closing, and nothing in its text can change a deal.',
            style: TextStyle(fontSize: 13, height: 1.45, color: t.wa),
          ),
        ],
      ]),
    );
  }
}
