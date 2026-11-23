import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/report.dart';
import '../../state/app_state.dart';
import '../../state/providers.dart';
import '../../state/view_models.dart';
import '../theme.dart';
import '../widgets/kit.dart';

class DealsScreen extends ConsumerStatefulWidget {
  const DealsScreen({super.key});
  @override
  ConsumerState<DealsScreen> createState() => _DealsScreenState();
}

class _DealsScreenState extends ConsumerState<DealsScreen> {
  String? _pipeline;
  String _stage = 'All';
  String _query = '';
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(sessionProvider)!;
    final snap = ref.watch(snapshotProvider);
    final t = context.t;
    return Column(children: [
      const DetailHeader(title: 'Deals', subtitle: 'Follow Up Boss · stage of record', fallback: '/more'),
      Expanded(
        child: !user.canRead(SectionSource.fubDeals)
            ? const EmptyState(icon: Icons.lock_outline_rounded, title: 'Not available for your role')
            : AsyncBody(
                value: snap,
                builder: (s) {
                  final payload = s.deals;
                  if (payload == null) {
                    return const EmptyState(icon: Icons.cloud_off_outlined, title: 'Deals unavailable', body: 'Follow Up Boss data was not returned in the latest report.');
                  }
                  final all = dealViews(s);
                  final stages = <String>['All', if (all.any((d) => d.needsReview)) 'Needs review', ...{for (final d in all) d.deal.stage}];
                  final q = _query.trim().toLowerCase();
                  final list = all
                      .where((d) => _pipeline == null || d.deal.pipeline == _pipeline)
                      .where((d) => _stage == 'All' || (_stage == 'Needs review' ? d.needsReview : d.deal.stage == _stage))
                      .where((d) => q.isEmpty || [d.deal.property, d.client, ...d.deal.assignedUsers].join(' ').toLowerCase().contains(q))
                      .toList();
                  return ListView(padding: const EdgeInsets.only(bottom: 28), children: [
                    const SizedBox(height: 4),
                    Padding(
                      padding: pagePad,
                      child: TextField(
                        controller: _search,
                        onChanged: (v) => setState(() => _query = v),
                        style: const TextStyle(fontSize: 15),
                        decoration: InputDecoration(
                          hintText: 'Address or contact',
                          prefixIcon: Icon(Icons.search_rounded, color: t.mu),
                          contentPadding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (payload.pipelineOrder.length > 1) ...[
                      Padding(
                        padding: pagePad,
                        child: Segmented<String?>(
                          options: [(null, 'All'), for (final p in payload.pipelineOrder) (p, p.replaceFirst('TEST ', ''))],
                          selected: _pipeline,
                          onSelected: (v) => setState(() => _pipeline = v),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    ChipRow<String>(
                      options: [for (final st in stages) (st, st == 'All' ? 'All stages' : st)],
                      selected: _stage,
                      onSelected: (v) => setState(() => _stage = v),
                    ),
                    const SizedBox(height: 12),
                    if (list.isEmpty)
                      EmptyState(
                        icon: Icons.search_off_rounded,
                        title: 'No deals found',
                        action: 'Clear search',
                        onAction: () => setState(() {
                          _search.clear();
                          _query = '';
                          _stage = 'All';
                          _pipeline = null;
                        }),
                      )
                    else
                      for (final d in list) Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 10), child: _DealCard(view: d)),
                  ]);
                },
              ),
      ),
    ]);
  }
}

class _DealCard extends StatelessWidget {
  const _DealCard({required this.view});
  final DealView view;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final d = view.deal;
    final close = d.projectedCloseDate == null ? 'No projected close' : 'Close ${shortDate(d.projectedCloseDate!)}';
    return SurfaceCard(
      onTap: () => openRoute(context, '/more/deals/${d.id}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(d.property, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text('${d.pipeline} · $close', style: TextStyle(fontSize: 13, color: t.mu)),
            ]),
          ),
          const SizedBox(width: 8),
          ToneChip(d.stage, view.stageTone),
        ]),
        const SizedBox(height: 8),
        Text(view.client, style: TextStyle(fontSize: 13, color: t.mu)),
        if (view.attention != null) ...[
          const SizedBox(height: 8),
          ToneChip(view.attention!, view.needsReview ? Tone.wa : Tone.ac, icon: Icons.flag_outlined),
        ],
      ]),
    );
  }
}
