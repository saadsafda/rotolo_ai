import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/report_push.dart';
import '../../state/app_state.dart';
import '../../state/providers.dart';
import '../theme.dart';
import '../widgets/kit.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _savingPush = false;

  Future<void> _setPush(ReportPush push, String userId, bool enabled) async {
    setState(() => _savingPush = true);
    try {
      if (enabled) {
        await push.enable(userId);
      } else {
        await push.disable(userId);
      }
    } on StateError catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update push notifications. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _savingPush = false);
    }
  }

  Future<void> _setQuietHours(ReportPush push, String userId, bool enabled) async {
    setState(() => _savingPush = true);
    final notifier = ref.read(settingsProvider.notifier);
    notifier.setPreference('quiet', enabled);
    try {
      await push.applyQuietHours(userId);
    } catch (_) {
      if (mounted) {
        notifier.setPreference('quiet', !enabled);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not update quiet hours. Try again.')));
      }
    } finally {
      if (mounted) setState(() => _savingPush = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(sessionProvider)!;
    final settings = ref.watch(settingsProvider);
    final repo = ref.watch(repositoryProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final t = context.t;
    final push = ref.watch(reportPushProvider);
    const prefs = [
      ('reports', 'Daily report ready'),
      ('payments', 'Payments and approvals'),
      ('tasks', 'Overdue and claimed tasks'),
      ('sync', 'Sync failures'),
    ];
    return Column(children: [
      const DetailHeader(title: 'Settings', fallback: '/more'),
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 28), children: [
          SurfaceCard(
            child: Row(children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: t.nv, shape: BoxShape.circle),
                child: Text(user.initials, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Colors.white)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(user.displayName, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  Text(user.email, style: TextStyle(fontSize: 13, color: t.mu)),
                ]),
              ),
              ToneChip(user.roleLabel, Tone.ac),
            ]),
          ),
          const SizedBox(height: 16),
          ListCard(children: [
            KVRow('Business timezone', '${repo.businessTimezone} (ET)'),
          ]),
          const SizedBox(height: 6),
          Text('Reports, cutoffs and due dates use this zone.', style: TextStyle(fontSize: 12, color: t.mu)),
          const SizedBox(height: 16),
          const SectionLabel('Notifications'),
          const SizedBox(height: 8),
          ListCard(children: [
            for (final (key, label) in prefs)
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: settings.prefs[key] ?? false,
                onChanged: (_) => notifier.togglePref(key),
                activeTrackColor: t.ac,
                title: Text(label, style: const TextStyle(fontSize: 14)),
              ),
          ]),
          const SizedBox(height: 6),
          if (push != null)
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: push.optedIn(user.id),
              onChanged: _savingPush ? null : (enabled) => _setPush(push, user.id, enabled),
              title: const Text('Send report alerts to this device'),
            ),
          if (push != null)
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: settings.prefs['quiet'] ?? false,
              onChanged: _savingPush ? null : (enabled) => _setQuietHours(push, user.id, enabled),
              title: const Text('Quiet hours 9 PM – 7 AM ET'),
              subtitle: const Text('Report alerts are skipped during quiet hours. Reports still appear in the app.'),
            ),
          Text('Notification preferences are stored on this device.', style: TextStyle(fontSize: 12, color: t.mu)),
          const SizedBox(height: 16),
          const SectionLabel('Roles'),
          const SizedBox(height: 8),
          ListCard(children: [
            if (repo.demoUsers.isEmpty) KVRow(user.displayName, user.roleLabel),
            for (final u in repo.demoUsers) KVRow(u.displayName, u.roleLabel),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                'Admins can submit outside payments. Only the owner approves them, and nobody approves their own. '
                'Staff see deals only until the owner decides which other sections they may read.',
                style: TextStyle(fontSize: 12, height: 1.45, color: t.mu),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          const SectionLabel('Appearance'),
          const SizedBox(height: 8),
          Segmented<ThemeMode>(
            options: const [(ThemeMode.light, 'Light'), (ThemeMode.dark, 'Dark')],
            selected: settings.themeMode,
            onSelected: notifier.setTheme,
          ),
          const SizedBox(height: 10),
          Text('Text size', style: TextStyle(fontSize: 13, color: t.mu)),
          const SizedBox(height: 8),
          Segmented<double>(
            options: const [(1.0, 'Default'), (1.15, 'Large'), (1.3, 'Larger')],
            selected: settings.textScale,
            onSelected: notifier.setTextScale,
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            key: const ValueKey('sign-out'),
            onPressed: () => ref.read(sessionProvider.notifier).signOut(),
            style: OutlinedButton.styleFrom(foregroundColor: t.er, minimumSize: const Size.fromHeight(48)),
            child: const Text('Sign out'),
          ),
        ]),
      ),
    ]);
  }
}
