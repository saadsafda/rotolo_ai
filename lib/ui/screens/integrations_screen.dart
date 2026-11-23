import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/payloads.dart';
import '../../models/report.dart';
import '../../state/app_state.dart';
import '../../state/providers.dart';
import '../../state/view_models.dart';
import '../theme.dart';
import '../widgets/kit.dart';

class IntegrationsScreen extends ConsumerWidget {
  const IntegrationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(sessionProvider)!;
    final snap = ref.watch(snapshotProvider);
    final repo = ref.watch(repositoryProvider);
    final now = ref.watch(clockProvider)();
    final t = context.t;
    return Column(children: [
      const DetailHeader(title: 'Integrations', fallback: '/more'),
      Expanded(
        child: !user.isOwnerOrAdmin
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
                child: Column(children: [
                  Icon(Icons.lock_outline_rounded, size: 40, color: t.na),
                  const SizedBox(height: 12),
                  const Text('Permission denied', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  Text('Integrations are managed by the owner or an admin. Ask them if a source looks wrong.',
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 14, height: 1.5, color: t.mu)),
                ]),
              )
            : AsyncBody(
                value: snap,
                builder: (s) {
                  final health = sourceHealth(s.latest, now, repo.staleAfterHours);
                  return ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 28), children: [
                    for (final h in health) ...[
                      SurfaceCard(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(color: t.sf2, border: Border.all(color: t.bd), borderRadius: BorderRadius.circular(12)),
                              child: Icon(h.icon, size: 22, color: t.tx),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(h.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                                Text(_account(h.section), style: TextStyle(fontSize: 13, color: t.mu)),
                              ]),
                            ),
                            ToneChip(h.status.$1, h.status.$2),
                          ]),
                          const SizedBox(height: 10),
                          Text(
                            h.section.collectedAt == null
                                ? 'No successful collection in the latest report'
                                : 'Last collected · ${whenIn(h.section.collectedAt, now, repo.businessTimezone)}',
                            style: TextStyle(fontSize: 13, color: t.mu),
                          ),
                          for (final w in h.section.warnings) ...[
                            const SizedBox(height: 10),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(color: t.was, borderRadius: BorderRadius.circular(10)),
                              child: Text(w.message, style: TextStyle(fontSize: 13, height: 1.45, color: t.tx)),
                            ),
                          ],
                          TextButton.icon(
                            onPressed: () => showToast(context, 'Credentials for ${h.name} are managed in n8n, never in this app.',
                                icon: Icons.shield_outlined),
                            style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 40)),
                            icon: Icon(Icons.shield_outlined, size: 18, color: t.ac),
                            label: const Text('Manage in secure setup'),
                          ),
                        ]),
                      ),
                      const SizedBox(height: 10),
                    ],
                    Text('Credentials are never entered in the mobile app. Connections are configured in n8n by an administrator.',
                        style: TextStyle(fontSize: 12, height: 1.45, color: t.mu)),
                  ]);
                },
              ),
      ),
    ]);
  }

  String _account(ReportSection s) {
    if (s.source == SectionSource.emailEvidence) {
      final p = EmailEvidencePayload(s.payload);
      return p.mailbox == null ? 'Mailbox not returned' : '${p.mailbox}${p.mailboxVerified ? ' · verified' : ' · NOT verified'}';
    }
    if (s.source == SectionSource.aiSummary) return 'Report summaries${AiSummary(s.payload).model == null ? '' : ' · ${AiSummary(s.payload).model}'}';
    return 'Workflow ${s.workflowId ?? 'not reported'}';
  }
}
