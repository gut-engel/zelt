import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:zelt_core/constants.dart';
import 'package:zelt_core/models.dart';
import '../app_state.dart';
import '../media_codec.dart';
import 'backup_screens.dart';
import 'chat_screen.dart' show imageFiles;
import '../updater.dart';
import 'network_screen.dart';
import 'widgets.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  /// Asks for a new PIN twice. Null if cancelled.
  static Future<String?> _askPin(BuildContext context, String title, {String? explain, String action = 'Save'}) {
    final a = TextEditingController();
    final b = TextEditingController();
    String? error;
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (explain != null) ...[Text(explain), const SizedBox(height: 12)],
              TextField(key: const Key('pinA'), controller: a, obscureText: true, decoration: const InputDecoration(labelText: 'New PIN')),
              const SizedBox(height: 12),
              TextField(
                key: const Key('pinB'),
                controller: b,
                obscureText: true,
                decoration: InputDecoration(labelText: 'Repeat', errorText: error),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              key: const Key('pinSave'),
              onPressed: () {
                if (a.text.length < 6) {
                  setState(() => error = 'Use at least 6 characters');
                } else if (a.text != b.text) {
                  setState(() => error = 'The two entries differ');
                } else {
                  Navigator.pop(ctx, a.text);
                }
              },
              child: Text(action),
            ),
          ],
        ),
      ),
    );
  }

  static void _toast(BuildContext context, String text) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _changePin(BuildContext context) async {
    final pin = await _askPin(context, 'Change PIN', action: 'Change');
    if (pin == null || !context.mounted) return;
    try {
      await context.read<AppState>().changePin(pin);
      if (context.mounted) _toast(context, 'PIN changed');
    } on ArgumentError {
      if (context.mounted) _toast(context, 'Choose a different PIN: that one is already in use');
    }
  }

  Future<void> _duressPin(BuildContext context) async {
    final app = context.read<AppState>();
    String? choice = 'set';
    if (app.duressPinSet) {
      choice = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(leading: const Icon(Icons.password), title: const Text('Change duress PIN'), onTap: () => Navigator.pop(ctx, 'set')),
              ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Remove duress PIN'), onTap: () => Navigator.pop(ctx, 'clear')),
            ],
          ),
        ),
      );
    }
    if (choice == null || !context.mounted) return;
    if (choice == 'clear') {
      await app.clearDuressPin();
      if (context.mounted) _toast(context, 'Duress PIN removed');
      return;
    }
    final pin = await _askPin(
      context,
      'Duress PIN',
      explain: 'Entered instead of your PIN, it opens zelt with every chat marked private hidden, '
          'without a trace. Mark chats private on their contact or group screen.',
    );
    if (pin == null || !context.mounted) return;
    try {
      await app.setDuressPin(pin);
      if (context.mounted) _toast(context, 'Duress PIN set');
    } on ArgumentError {
      if (context.mounted) _toast(context, 'The duress PIN must differ from your PIN');
    }
  }

  Future<void> _wipe(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wipe everything?'),
        content: const Text('Deletes your identity, all friends and all messages from this device. This cannot be undone.'),
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
              DelayMode.normal => '50–250 ms random delay per hop. Messages arrive in about 1 s.',
              DelayMode.paranoid =>
                'Up to 900 ms per hop, released in batches. Strongest timing protection; '
                'messages still arrive within 10 s.',
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
                'One packet every second, real or dummy, so sending looks like idling. '
                'About 700 MB a day: use on Wi-Fi.',
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
          _Header('Backup'),
          ListTile(
            key: const Key('backupSettings'),
            leading: const Icon(Icons.cloud_sync_outlined),
            title: const Text('Backup'),
            subtitle: Text(switch (app.backup) {
              null => '',
              final b when !b.configured => 'Not set up',
              final b when b.targets.isEmpty => 'No destination yet',
              final b when b.lastRun == null => 'No backup made yet',
              final b => 'Last backup ${shortTime(b.lastRun!)} · ${b.targets.length} destination${b.targets.length == 1 ? '' : 's'}',
            }),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(settings: const RouteSettings(name: 'backup'), builder: (_) => const BackupSettingsScreen()),
            ),
          ),
          _Header('This device'),
          const _ProfilePictureTile(),
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
          ListTile(
            title: const Text('Storage protection'),
            subtitle: Text(switch (app.vaultFormat) {
              'v2 (strongbox)' => 'PIN + StrongBox hardware key: a copied vault cannot be opened elsewhere',
              'v2 (tee)' => 'PIN + hardware key (TEE): a copied vault cannot be opened elsewhere',
              _ => 'PIN only (Argon2id). No hardware key on this platform.',
            }),
          ),
          ListTile(title: const Text('Change PIN'), onTap: () => _changePin(context)),
          ListTile(
            key: const Key('duressPin'),
            title: const Text('Duress PIN'),
            subtitle: Text(
              app.duressPinSet
                  ? 'Set. It opens zelt without your private chats.'
                  : 'A second PIN that opens zelt with private chats hidden',
            ),
            onTap: () => _duressPin(context),
          ),
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

/// Our profile picture. It only goes to contacts we verified, and comes back
/// from them when we un-verify them or remove it.
class _ProfilePictureTile extends StatefulWidget {
  const _ProfilePictureTile();

  @override
  State<_ProfilePictureTile> createState() => _ProfilePictureTileState();
}

class _ProfilePictureTileState extends State<_ProfilePictureTile> {
  bool _busy = false;

  Future<void> _pick() async {
    final app = context.read<AppState>();
    final file = await openFile(acceptedTypeGroups: [imageFiles]);
    if (file == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final p = await prepareAvatar(await file.readAsBytes());
      await app.m.setAvatar(p.bytes, width: p.width, height: p.height);
    } on MediaRejected catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Cannot use this image: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = context.watch<AppState>().m;
    final pic = m.settings.avatar;
    final verified = m.contacts.values.where((c) => c.verified).length;
    return ListTile(
      key: const Key('profilePicture'),
      leading: _busy
          ? const SizedBox(width: 40, height: 40, child: Padding(padding: EdgeInsets.all(10), child: CircularProgressIndicator(strokeWidth: 2)))
          : Avatar(m.settings.name, picture: pic),
      title: const Text('Profile picture'),
      subtitle: Text(
        'Only verified friends see it ($verified now). Friends you un-verify lose it.',
      ),
      onTap: _busy ? null : _pick,
      trailing: pic == null || _busy
          ? null
          : IconButton(
              key: const Key('removeProfilePicture'),
              tooltip: 'Remove',
              icon: const Icon(Icons.delete_outline),
              onPressed: m.clearAvatar,
            ),
    );
  }
}
