import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:zelt_core/constants.dart';
import 'package:zelt_core/models.dart';
import '../app_state.dart';
import '../updater.dart';
import 'network_screen.dart';
import 'widgets.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _changePin(BuildContext context) async {
    final a = TextEditingController();
    final b = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: a, obscureText: true, decoration: const InputDecoration(labelText: 'New PIN')),
            const SizedBox(height: 12),
            TextField(controller: b, obscureText: true, decoration: const InputDecoration(labelText: 'Repeat')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (a.text.length >= 6 && a.text == b.text) Navigator.pop(ctx, a.text);
            },
            child: const Text('Change'),
          ),
        ],
      ),
    );
    if (pin != null && context.mounted) {
      await context.read<AppState>().changePin(pin);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN changed')));
      }
    }
  }

  Future<void> _wipe(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wipe everything?'),
        content: const Text('Deletes your identity, all friends and all messages from this phone. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Wipe')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      Navigator.of(context).popUntil((r) => r.isFirst);
      await context.read<AppState>().wipe();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final m = app.m;
    final s = m.settings;
    final t = Theme.of(context);
    void apply() => m.applySettings();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _Header('Privacy'),
          ListTile(
            title: Text('Onion hops: ${s.hops}'),
            subtitle: Slider(
              min: minHops.toDouble(),
              max: maxHops.toDouble(),
              divisions: maxHops - minHops,
              value: s.hops.toDouble(),
              label: '${s.hops}',
              onChanged: (v) {
                s.hops = v.round();
                apply();
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Each hop peels one layer and only knows its neighbours. More hops '
              'make collusion harder and add latency.',
              style: t.textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 16),
          ListTile(
            title: const Text('Delay'),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SegmentedButton<DelayMode>(
                segments: const [
                  ButtonSegment(value: DelayMode.fast, label: Text('Fast')),
                  ButtonSegment(value: DelayMode.normal, label: Text('Normal')),
                  ButtonSegment(value: DelayMode.paranoid, label: Text('Paranoid')),
                ],
                selected: {s.delay},
                onSelectionChanged: (v) {
                  s.delay = v.first;
                  apply();
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(switch (s.delay) {
              DelayMode.fast => 'Minimal per-hop delay. Easiest to correlate by timing.',
              DelayMode.normal => '100–500 ms random delay per hop, about 1–2 s extra at 4 hops.',
              DelayMode.paranoid => 'Seconds per hop, released in batches. Strongest timing protection.',
            }, style: t.textTheme.bodySmall),
          ),
          const SizedBox(height: 16),
          ListTile(
            title: const Text('Cover traffic'),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SegmentedButton<CoverMode>(
                segments: const [
                  ButtonSegment(value: CoverMode.off, label: Text('Off')),
                  ButtonSegment(value: CoverMode.low, label: Text('Low')),
                  ButtonSegment(value: CoverMode.constant, label: Text('Constant')),
                ],
                selected: {s.cover},
                onSelectionChanged: (v) {
                  s.cover = v.first;
                  apply();
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(switch (s.cover) {
              CoverMode.off => 'No dummy packets. Saves battery and data; reveals when you send.',
              CoverMode.low => 'Dummy packets at random times, about 25 MB a day.',
              CoverMode.constant =>
                'One packet every 2 s, real or dummy, so sending looks like idling. '
                'About 350 MB a day: use on Wi-Fi.',
            }, style: t.textTheme.bodySmall),
          ),
          _Header('Relay'),
          SwitchListTile(
            title: const Text('Relay for friends'),
            subtitle: const Text(
              'Forward onions and hold up to 12 MB of encrypted blobs in RAM for '
              'up to 7 days. Works best on Wi-Fi with IPv6 or port forwarding.',
            ),
            value: s.relay,
            onChanged: (v) {
              s.relay = v;
              apply();
            },
          ),
          SwitchListTile(
            title: const Text('Share known relays with friends'),
            subtitle: const Text(
              'Keeps everyone\'s relay lists in sync, so a relay one friend adds '
              'helps all. Friends learn which relays you can reach.',
            ),
            value: s.shareRelays,
            onChanged: (v) {
              s.shareRelays = v;
              apply();
            },
          ),
          ListTile(
            title: const Text('Network and peers'),
            subtitle: const Text('Status, relay addresses, add an always-on node'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => push(context, const NetworkScreen()),
          ),
          _Header('Appearance'),
          ListTile(
            title: const Text('Theme'),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.brightness_auto)),
                  ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode)),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode)),
                ],
                selected: {app.themeMode},
                onSelectionChanged: (v) => app.setThemeMode(v.first),
              ),
            ),
          ),
          if (Updater.supported) ...[
            _Header('Updates'),
            FutureBuilder(
              future: Updater.info(),
              builder: (context, snap) => ListTile(
                title: const Text('Version'),
                subtitle: Text(snap.hasData ? '${snap.data!.version} (build ${snap.data!.buildNumber})' : ''),
              ),
            ),
            SwitchListTile(
              title: const Text('Check for updates automatically'),
              subtitle: const Text(
                'Once a day, from github.com (which sees your IP address). Updates are '
                'installed only if signed by the zelt release key.',
              ),
              value: app.autoUpdateCheck,
              onChanged: app.setAutoUpdateCheck,
            ),
            ListTile(
              title: Text(app.update != null ? 'Update to ${app.update!.version}' : 'Check now'),
              subtitle: app.updateMessage == null ? null : Text(app.updateMessage!),
              trailing: app.updateChecking || app.updateProgress != null
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.system_update),
              onTap: app.updateChecking || app.updateProgress != null
                  ? null
                  : () => app.update != null ? app.installUpdate() : app.checkForUpdate(manual: true),
            ),
          ],
          _Header('This phone'),
          ListTile(
            title: const Text('Name shown when pairing'),
            subtitle: Text(s.name.isEmpty ? 'Not set' : s.name),
            onTap: () async {
              final ctl = TextEditingController(text: s.name);
              final v = await showDialog<String>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Your name'),
                  content: TextField(controller: ctl, autofocus: true),
                  actions: [
                    FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('Save')),
                  ],
                ),
              );
              if (v != null) {
                s.name = v;
                apply();
              }
            },
          ),
          ListTile(title: const Text('Change PIN'), onTap: () => _changePin(context)),
          ListTile(
            title: const Text('Lock now'),
            subtitle: const Text('Stops the relay and clears keys from memory'),
            onTap: () {
              Navigator.of(context).popUntil((r) => r.isFirst);
              app.lock();
            },
          ),
          ListTile(
            title: Text('Wipe all data', style: TextStyle(color: t.colorScheme.error)),
            onTap: () => _wipe(context),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
  );
}
