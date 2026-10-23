import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:zelt_core/backup.dart';
import 'package:zelt_core/backup_targets.dart';
import 'package:zelt_core/phrase.dart';
import '../app_state.dart';
import '../backup_service.dart';
import 'widgets.dart';

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} day${d.inDays == 1 ? '' : 's'} ago';
}

// --- After creating an identity ----------------------------------------------

/// Offered once, right after a new identity is made. Skipping is fine: it
/// can be set up any time in Settings.
class BackupIntroScreen extends StatelessWidget {
  const BackupIntroScreen({super.key});

  void _done(BuildContext context, {bool skipped = false}) {
    final app = context.read<AppState>();
    if (skipped) app.backup?.markSkipped();
    Navigator.of(context).popUntil((r) => r.isFirst);
    app.finishBackupOffer();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 32),
            Icon(Icons.cloud_sync_outlined, size: 64, color: t.colorScheme.primary),
            const SizedBox(height: 16),
            Text('Back up your chats?', style: t.textTheme.headlineSmall, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            const Text(
              'zelt keeps everything on this phone only. If it is lost or broken, a backup brings back '
              'your identity, your friends, your chats and pictures, on a new phone.\n\n'
              'Backups are encrypted with a 12-word backup phrase that only you have. You can keep '
              'them on your own WebDAV or SFTP server, in an S3 bucket, or in a file. They are small: '
              'after the first one, only what is new goes up, once a day.',
            ),
            const SizedBox(height: 32),
            FilledButton(
              key: const Key('setupBackup'),
              onPressed: () => push(context, PhraseScreen(onDone: () => _done(context))),
              child: const Text('Set up backup'),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('skipBackup'),
              onPressed: () => _done(context, skipped: true),
              child: const Text('Skip for now (you can do it later in Settings)'),
            ),
          ],
        ),
      ),
    );
  }
}

// --- The phrase ---------------------------------------------------------------

/// Shows a new backup phrase to write down, then checks three of its words.
class PhraseScreen extends StatefulWidget {
  final VoidCallback onDone;
  const PhraseScreen({super.key, required this.onDone});

  @override
  State<PhraseScreen> createState() => _PhraseScreenState();
}

class _PhraseScreenState extends State<PhraseScreen> {
  final _phrase = BackupPhrase.generate();
  late final AppState _app;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    // No screenshots of the phrase.
    _app.setSecureScreen(true);
  }

  @override
  void dispose() {
    _app.setSecureScreen(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final words = _phrase.wordList;
    return Scaffold(
      appBar: AppBar(title: const Text('Your backup phrase')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('Write these 12 words on paper, in this order. Keep the paper somewhere safe.'),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                // Two columns, 1-6 and 7-12, as wide as the screen allows.
                child: LayoutBuilder(
                  builder: (context, box) {
                    final w = (box.maxWidth - 12) / 2;
                    Widget cell(int i) => SizedBox(
                      width: w,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            SizedBox(width: 30, child: Text('${i + 1}.', style: t.textTheme.bodySmall)),
                            Expanded(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(words[i], key: Key('word$i'), style: t.textTheme.titleMedium?.copyWith(fontFamily: 'monospace')),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Column(children: [for (var i = 0; i < 6; i++) cell(i)]),
                        const SizedBox(width: 12),
                        Column(children: [for (var i = 6; i < 12; i++) cell(i)]),
                      ],
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              color: t.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Anyone with these words can read your backups. Never type them into a website, '
                  'never photograph them, never send them to anyone. zelt does not keep them and '
                  'cannot show them again: without them, a backup cannot be opened.',
                  style: TextStyle(color: t.colorScheme.onErrorContainer),
                ),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('wroteItDown'),
              onPressed: () => push(context, _PhraseCheckScreen(phrase: _phrase, onDone: widget.onDone)),
              child: const Text('I wrote them down'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhraseCheckScreen extends StatefulWidget {
  final BackupPhrase phrase;
  final VoidCallback onDone;
  const _PhraseCheckScreen({required this.phrase, required this.onDone});

  @override
  State<_PhraseCheckScreen> createState() => _PhraseCheckScreenState();
}

class _PhraseCheckScreenState extends State<_PhraseCheckScreen> {
  late final List<int> _ask;
  late final List<TextEditingController> _ctl;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final rng = Random.secure();
    final idx = List.generate(BackupPhrase.words, (i) => i)..shuffle(rng);
    _ask = idx.take(3).toList()..sort();
    _ctl = [for (final _ in _ask) TextEditingController()];
  }

  @override
  void dispose() {
    for (final c in _ctl) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _check() async {
    final words = widget.phrase.wordList;
    for (var i = 0; i < _ask.length; i++) {
      final typed = _ctl[i].text.trim().toLowerCase();
      final idx = BackupPhrase.lookup(typed);
      if (idx == null || words[_ask[i]] != BackupPhrase.suggest(typed, max: 1).firstOrNull && words[_ask[i]] != typed) {
        setState(() => _error = 'Word ${_ask[i] + 1} does not match. Check your paper.');
        return;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final app = context.read<AppState>();
    await app.backup!.usePhrase(widget.phrase);
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => BackupSettingsScreen(firstRun: true, onDone: widget.onDone)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Check your paper')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('To be sure the words are written down correctly, type these three from your paper.'),
            const SizedBox(height: 16),
            for (var i = 0; i < _ask.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  key: Key('check$i'),
                  controller: _ctl[i],
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(labelText: 'Word ${_ask[i] + 1}'),
                ),
              ),
            if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 12),
            FilledButton(key: const Key('checkWords'), onPressed: _busy ? null : _check, child: const Text('Check')),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Show the words again')),
          ],
        ),
      ),
    );
  }
}

// --- Settings -----------------------------------------------------------------

class BackupSettingsScreen extends StatelessWidget {
  /// Right after setting up the phrase: ends with [onDone].
  final bool firstRun;
  final VoidCallback? onDone;
  const BackupSettingsScreen({super.key, this.firstRun = false, this.onDone});

  Future<void> _runNow(BuildContext context, BackupService b) async {
    final errors = await b.runNow();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(errors.isEmpty ? 'Backup done' : 'Backup failed: ${errors.join('; ')}'),
    ));
  }

  Future<void> _newPhrase(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New backup phrase?'),
        content: const Text(
          'Use this if the old words were lost or seen by someone. The next backup replaces the old '
          'one, and only the new words can open it.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Make new words')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await push(context, PhraseScreen(onDone: () => Navigator.of(context).popUntil((r) => r.settings.name == 'backup' || r.isFirst)));
    }
  }

  Future<void> _move(BuildContext context, BackupService b) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move to a new phone'),
        content: const Text(
          '1. zelt makes a fresh backup now.\n'
          '2. On the new phone, install zelt and choose "Restore from backup", with your 12 words.\n'
          '3. Erase zelt on this phone.\n\n'
          'Your friends\' apps start new encrypted sessions with the new phone. This phone stops '
          'by itself as soon as one of them talks to the new one; it cannot read anything new.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Back up now')),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
    final errors = await b.runNow();
    if (!context.mounted) return;
    if (errors.length == b.targets.length) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Backup failed: ${errors.join('; ')}')));
      return;
    }
    final erase = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Backup done'),
        content: Text(
          '${errors.isEmpty ? '' : 'Some destinations failed: ${errors.join('; ')}\n\n'}'
          'Restore it on the new phone now. When the new phone shows your chats, erase this one.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Later')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Erase this phone now'),
          ),
        ],
      ),
    );
    if (erase == true && context.mounted) {
      Navigator.of(context).popUntil((r) => r.isFirst);
      await context.read<AppState>().wipe();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final b = app.backup!;
    final t = Theme.of(context);
    final last = b.lastRun;
    return Scaffold(
      appBar: AppBar(title: const Text('Backup')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (!b.configured) ...[
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No backup yet. Backups are encrypted with a 12-word phrase that only you have, '
                'and can go to your own server, an S3 bucket or a file.',
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton(
                key: const Key('setupBackupSettings'),
                onPressed: () => push(context, PhraseScreen(onDone: () => Navigator.of(context).popUntil((r) => r.isFirst))),
                child: const Text('Set up backup'),
              ),
            ),
          ] else ...[
            ListTile(
              leading: const Icon(Icons.key_outlined),
              title: const Text('Backup phrase'),
              subtitle: Text('Set (fingerprint ${b.fingerprint}). Only its 12 words can open the backups.'),
            ),
            ListTile(
              leading: b.running
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.history),
              title: Text(b.running ? (b.progress ?? 'Backing up…') : (last == null ? 'No backup made yet' : 'Last backup ${_ago(last)}')),
              trailing: FilledButton.tonal(
                key: const Key('backupNow'),
                onPressed: b.running || b.targets.isEmpty ? null : () => _runNow(context, b),
                child: const Text('Back up now'),
              ),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.schedule),
              title: const Text('Back up every day'),
              subtitle: const Text('While zelt runs; only what is new is uploaded'),
              value: b.auto,
              onChanged: b.setAuto,
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text('Destinations', style: t.textTheme.titleMedium),
            ),
            if (b.targets.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Add at least one place for the backups to go. More than one is safer.'),
              ),
            for (final target in b.targets)
              ListTile(
                leading: Icon(switch (target.type) {
                  'file' => Icons.insert_drive_file_outlined,
                  'sftp' => Icons.terminal,
                  's3' => Icons.cloud_outlined,
                  _ => Icons.dns_outlined,
                }),
                title: Text(target.label),
                subtitle: Text(
                  target.lastError != null
                      ? 'Last try failed: ${target.lastError}'
                      : target.lastOk != null
                      ? 'OK ${_ago(DateTime.fromMillisecondsSinceEpoch(target.lastOk!))}'
                      : 'Not used yet',
                  style: target.lastError != null ? TextStyle(color: t.colorScheme.error) : null,
                ),
                trailing: IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => b.removeTarget(target.id),
                ),
              ),
            ListTile(
              key: const Key('addTarget'),
              leading: const Icon(Icons.add),
              title: const Text('Add a destination'),
              onTap: () async {
                final type = await pickTargetType(context);
                if (type == null || !context.mounted) return;
                final config = await push<Map<String, dynamic>>(context, TargetEditScreen(type: type));
                if (config != null) {
                  b.addTarget(config);
                  if (context.mounted && !b.running) unawaited(_runNow(context, b));
                }
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.phone_android),
              title: const Text('Move to a new phone'),
              subtitle: const Text('Back up now, restore on the new phone, then erase this one'),
              enabled: b.targets.isNotEmpty && !b.running,
              onTap: () => _move(context, b),
            ),
            ListTile(
              leading: const Icon(Icons.autorenew),
              title: const Text('New backup phrase'),
              subtitle: const Text('If the words were lost or seen by someone'),
              onTap: () => _newPhrase(context),
            ),
          ],
          if (firstRun)
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                key: const Key('backupDone'),
                onPressed: onDone,
                child: Text(b.targets.isEmpty ? 'Add destinations later' : 'Done'),
              ),
            ),
        ],
      ),
    );
  }
}

/// Which kind of destination to add (or to restore from).
Future<String?> pickTargetType(BuildContext context, {bool restore = false}) => showModalBottomSheet<String>(
  context: context,
  showDragHandle: true,
  builder: (ctx) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          key: const Key('target-file'),
          leading: const Icon(Icons.insert_drive_file_outlined),
          title: Text(restore ? 'A backup file' : 'A file'),
          subtitle: Text(
            restore
                ? 'A zelt-backup.zbk file, from Downloads/Zelt on the old phone, a USB stick or a synced folder'
                : Platform.isAndroid
                ? 'Download/Zelt/zelt-backup.zbk on this phone: copy it off, or sync the folder'
                : 'One file wherever you choose (a USB stick, a synced folder)',
          ),
          onTap: () => Navigator.pop(ctx, 'file'),
        ),
        ListTile(
          key: const Key('target-webdav'),
          leading: const Icon(Icons.dns_outlined),
          title: const Text('WebDAV'),
          subtitle: const Text('Nextcloud, ownCloud, a NAS, many hosting providers'),
          onTap: () => Navigator.pop(ctx, 'webdav'),
        ),
        ListTile(
          key: const Key('target-sftp'),
          leading: const Icon(Icons.terminal),
          title: const Text('SFTP'),
          subtitle: const Text('Any server you can reach with SSH'),
          onTap: () => Navigator.pop(ctx, 'sftp'),
        ),
        ListTile(
          key: const Key('target-s3'),
          leading: const Icon(Icons.cloud_outlined),
          title: const Text('S3-compatible storage'),
          subtitle: const Text('AWS S3, Backblaze B2, MinIO, Wasabi, Cloudflare R2'),
          onTap: () => Navigator.pop(ctx, 's3'),
        ),
      ],
    ),
  ),
);

// --- One destination ----------------------------------------------------------

/// The form for one destination. Pops with its configuration once a test
/// connection worked. [restore]: reading an existing backup (a file is
/// picked instead of chosen as a place to write).
class TargetEditScreen extends StatefulWidget {
  final String type;
  final bool restore;
  const TargetEditScreen({super.key, required this.type, this.restore = false});

  @override
  State<TargetEditScreen> createState() => _TargetEditScreenState();
}

class _TargetEditScreenState extends State<TargetEditScreen> {
  final _f = <String, TextEditingController>{};
  String? _error;
  bool _busy = false;
  bool _useKey = false;
  String? _hostKey;
  String? _filePath;

  TextEditingController _c(String k, [String initial = '']) => _f.putIfAbsent(k, () => TextEditingController(text: initial));
  String _v(String k) => _c(k).text.trim();

  @override
  void dispose() {
    for (final c in _f.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic>? _config() {
    switch (widget.type) {
      case 'file':
        if (Platform.isAndroid && !widget.restore) return {'type': 'file', 'label': 'File in Downloads/Zelt'};
        if (_filePath == null) {
          _error = widget.restore ? 'Choose the backup file' : 'Choose where to save the file';
          return null;
        }
        return {'type': 'file', 'path': _filePath, 'label': 'File'};
      case 'webdav':
        return {'type': 'webdav', 'url': _v('url'), 'user': _v('user'), 'password': _c('password').text};
      case 's3':
        return {
          'type': 's3',
          'endpoint': _v('endpoint'),
          'region': _v('region'),
          'bucket': _v('bucket'),
          'accessKey': _v('accessKey'),
          'secretKey': _c('secretKey').text.trim(),
          'prefix': _v('prefix'),
        };
      case 'sftp':
        if (_hostKey == null) {
          _error = 'Check the server key first';
          return null;
        }
        return {
          'type': 'sftp',
          'host': _v('host'),
          'port': int.tryParse(_v('port')) ?? 22,
          'user': _v('user'),
          if (!_useKey) 'password': _c('password').text,
          if (_useKey) 'key': _c('key').text,
          'path': _v('path'),
          'hostKey': _hostKey,
        };
    }
    return null;
  }

  Future<void> _pickFile() async {
    if (widget.restore) {
      final f = await openFile(acceptedTypeGroups: const [XTypeGroup(label: 'zelt backup')]);
      if (f != null) setState(() => _filePath = f.path);
    } else {
      final loc = await getSaveLocation(suggestedName: 'zelt-backup.zbk');
      if (loc != null) setState(() => _filePath = loc.path);
    }
  }

  Future<void> _checkHostKey() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final fp = await SftpTarget.fetchHostKey(_v('host'), int.tryParse(_v('port')) ?? 22);
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Is this your server?'),
          content: SelectableText(
            'The server ${_v('host')} identifies itself with:\n\n$fp\n\n'
            'Compare it with what the server shows for its key, e.g.\n'
            'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub\n\n'
            'zelt remembers it and refuses to send anything if it ever changes.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes, trust it')),
          ],
        ),
      );
      if (ok == true) setState(() => _hostKey = fp);
    } on BackupTargetError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final config = _config();
    if (config == null) {
      setState(() => _busy = false);
      return;
    }
    String? problem;
    try {
      BackupService.build(config);
      // Restoring only needs to read; a new destination is tested fully.
      problem = widget.restore ? null : await BackupService.check(config);
    } on BackupTargetError catch (e) {
      problem = e.message;
    } on BackupError catch (e) {
      problem = e.message;
    } on FormatException catch (e) {
      problem = e.message;
    }
    if (!mounted) return;
    if (problem != null) {
      setState(() {
        _busy = false;
        _error = problem;
      });
      return;
    }
    Navigator.pop(context, config);
  }

  Widget _field(String k, String label, {String initial = '', bool secret = false, String? hint, TextInputType? type, int lines = 1}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          key: Key('field-$k'),
          controller: _c(k, initial),
          obscureText: secret,
          keyboardType: type,
          autocorrect: false,
          enableSuggestions: false,
          minLines: lines,
          maxLines: secret ? 1 : lines,
          decoration: InputDecoration(labelText: label, hintText: hint),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final fields = switch (widget.type) {
      'file' => [
        if (Platform.isAndroid && !widget.restore)
          const Text(
            'The backup is saved as Download/Zelt/zelt-backup.zbk and replaced every time. Copy it to '
            'a computer or a USB stick now and then, or let a sync app (Syncthing, Nextcloud) take it '
            'off the phone: a backup that stays on the phone does not help if the phone is lost.',
          )
        else ...[
          OutlinedButton.icon(
            onPressed: _pickFile,
            icon: const Icon(Icons.folder_open),
            label: Text(_filePath == null ? (widget.restore ? 'Choose the backup file' : 'Choose where to save it') : _filePath!),
          ),
          if (!widget.restore) ...[
            const SizedBox(height: 8),
            Text('The file is replaced on every backup.', style: t.textTheme.bodySmall),
          ],
        ],
      ],
      'webdav' => [
        _field('url', 'Folder address', hint: 'https://cloud.example.org/remote.php/dav/files/me/zelt', type: TextInputType.url),
        _field('user', 'User name'),
        _field('password', 'Password (an app password, if the server has them)', secret: true),
      ],
      's3' => [
        _field('endpoint', 'Endpoint', initial: 'https://s3.amazonaws.com', type: TextInputType.url),
        _field('region', 'Region', hint: 'eu-central-1'),
        _field('bucket', 'Bucket'),
        _field('prefix', 'Folder in the bucket (optional)', hint: 'zelt'),
        _field('accessKey', 'Access key ID'),
        _field('secretKey', 'Secret access key', secret: true),
        Text('Use a key that can only reach this bucket.', style: t.textTheme.bodySmall),
      ],
      'sftp' => [
        _field('host', 'Server', hint: 'backup.example.org'),
        _field('port', 'Port', initial: '22', type: TextInputType.number),
        _field('user', 'User name'),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Password')),
            ButtonSegment(value: true, label: Text('Private key')),
          ],
          selected: {_useKey},
          onSelectionChanged: (s) => setState(() => _useKey = s.first),
        ),
        const SizedBox(height: 12),
        if (_useKey)
          _field('key', 'Private key (OpenSSH format, without passphrase)', lines: 4)
        else
          _field('password', 'Password', secret: true),
        _field('path', 'Folder on the server', hint: '/home/me/zelt-backup'),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(_hostKey == null ? Icons.help_outline : Icons.verified_user_outlined),
          title: Text(_hostKey == null ? 'Server key not checked yet' : 'Server key trusted'),
          subtitle: _hostKey == null ? null : Text(_hostKey!),
          trailing: OutlinedButton(onPressed: _busy ? null : _checkHostKey, child: const Text('Check')),
        ),
      ],
      _ => <Widget>[],
    };
    final title = switch (widget.type) {
      'file' => widget.restore ? 'Backup file' : 'File',
      'webdav' => 'WebDAV',
      's3' => 'S3-compatible storage',
      'sftp' => 'SFTP',
      _ => '',
    };
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            ...fields,
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: t.colorScheme.error)),
            ],
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('saveTarget'),
              onPressed: _busy ? null : _save,
              child: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(widget.restore ? 'Use this' : 'Test and save'),
            ),
          ],
        ),
      ),
    );
  }
}

// --- Restore ------------------------------------------------------------------

/// Restore on a new device: where the backup is, the 12 words, a PIN.
class RestoreScreen extends StatefulWidget {
  const RestoreScreen({super.key});

  @override
  State<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends State<RestoreScreen> {
  Map<String, dynamic>? _source;
  final _words = TextEditingController();
  final _pin = TextEditingController();
  final _pin2 = TextEditingController();
  String? _error;
  String? _wordsInfo;
  bool _busy = false;
  String? _progress;
  late final AppState _app;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _app.setSecureScreen(true);
    _words.addListener(_checkWords);
  }

  @override
  void dispose() {
    _app.setSecureScreen(false);
    _words.dispose();
    _pin.dispose();
    _pin2.dispose();
    super.dispose();
  }

  void _checkWords() {
    final typed = _words.text.toLowerCase().split(RegExp(r'[^a-z]+')).where((w) => w.isNotEmpty).toList();
    String? info;
    final unknown = [for (var i = 0; i < typed.length; i++) if (BackupPhrase.lookup(typed[i]) == null && (i < typed.length - 1 || _words.text.endsWith(' '))) i + 1];
    if (unknown.isNotEmpty) {
      info = 'Word ${unknown.first} is not in the word list';
    } else if (typed.length == BackupPhrase.words) {
      try {
        BackupPhrase.parse(_words.text);
        info = null;
      } on FormatException catch (e) {
        info = e.message;
      }
    } else {
      info = '${typed.length} of ${BackupPhrase.words} words';
    }
    setState(() => _wordsInfo = info);
  }

  Future<void> _chooseSource() async {
    final type = await pickTargetType(context, restore: true);
    if (type == null || !mounted) return;
    final config = await push<Map<String, dynamic>>(context, TargetEditScreen(type: type, restore: true));
    if (config != null) setState(() => _source = config);
  }

  Future<void> _restore() async {
    final BackupPhrase phrase;
    try {
      phrase = BackupPhrase.parse(_words.text);
    } on FormatException catch (e) {
      setState(() => _error = 'Backup phrase: ${e.message}');
      return;
    }
    if (_pin.text.length < 6) {
      setState(() => _error = 'Use a PIN of at least 6 characters');
      return;
    }
    if (_pin.text != _pin2.text) {
      setState(() => _error = 'The two PIN entries differ');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _progress = 'Reading the backup…';
    });
    try {
      final target = BackupService.build(_source!);
      final r = await _app.restore(
        target,
        phrase,
        _pin.text,
        progress: (done, total) {
          if (mounted) setState(() => _progress = 'Pictures: $done of $total');
        },
      );
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
      final missing = r.missingMedia > 0 ? ' ${r.missingMedia} pictures were missing; friends send them again.' : '';
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text('Restored the backup from ${_ago(r.created)}.$missing'),
        duration: const Duration(seconds: 8),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
        _error = switch (e) {
          BackupError(:final message) => message,
          BackupTargetError(:final message) => message,
          _ => 'Could not restore: $e',
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final src = _source;
    return Scaffold(
      appBar: AppBar(title: const Text('Restore from backup')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('1. Where is the backup?', style: t.textTheme.titleMedium),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('restoreSource'),
              onPressed: _busy ? null : _chooseSource,
              icon: const Icon(Icons.folder_open),
              label: Text(src == null ? 'Choose' : TargetEntry('', src).label),
            ),
            const SizedBox(height: 20),
            Text('2. Your 12-word backup phrase', style: t.textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              key: const Key('restoreWords'),
              controller: _words,
              minLines: 3,
              maxLines: 4,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.visiblePassword,
              decoration: InputDecoration(hintText: 'word word word …', helperText: _wordsInfo),
            ),
            const SizedBox(height: 20),
            Text('3. A PIN for this device', style: t.textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(key: const Key('restorePin'), controller: _pin, obscureText: true, decoration: const InputDecoration(labelText: 'PIN or passphrase')),
            const SizedBox(height: 12),
            TextField(key: const Key('restorePin2'), controller: _pin2, obscureText: true, decoration: const InputDecoration(labelText: 'Repeat')),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'After the restore, zelt starts new encrypted sessions with every friend. Do not keep '
                  'using the old device: it stops by itself as soon as a friend talks to this one.',
                  style: t.textTheme.bodySmall,
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: t.colorScheme.error)),
            ],
            if (_progress != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 12),
                  Expanded(child: Text(_progress!)),
                ],
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('restoreGo'),
              onPressed: _busy || src == null ? null : _restore,
              child: const Text('Restore'),
            ),
          ],
        ),
      ),
    );
  }
}

// --- This device was replaced -------------------------------------------------

class SupersededScreen extends StatelessWidget {
  const SupersededScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final t = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 48),
            Icon(Icons.phonelink_erase, size: 64, color: t.colorScheme.error),
            const SizedBox(height: 16),
            Text('This identity moved to another device', style: t.textTheme.headlineSmall, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            const Text(
              'Your backup was restored on another device, and your friends now talk to that one. '
              'This device stopped: it cannot send or receive anything any more.\n\n'
              'If you did not restore a backup yourself, someone has your 12-word backup phrase: '
              'tell your friends in person and set up a new identity.',
            ),
            const SizedBox(height: 32),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: t.colorScheme.error),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Erase zelt on this device?'),
                    content: const Text('Everything stored here is deleted.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Erase')),
                    ],
                  ),
                );
                if (ok == true) await app.wipe();
              },
              child: const Text('Erase this device'),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: app.lock, child: const Text('Lock')),
          ],
        ),
      ),
    );
  }
}
