import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:zelt_core/invite.dart';
import 'package:zelt_core/models.dart';
import '../app_state.dart';

/// The second way to add a friend: a one-time invite text, sent over any
/// channel. One use only; unused, it stops working after 15 minutes.
class InviteScreen extends StatefulWidget {
  const InviteScreen({super.key});

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  late final AppState _app;
  StreamSubscription<void>? _sub;
  Timer? _tick;

  // Inviting.
  PendingInvite? _invite;
  bool _copied = false;
  bool _cancelled = false;
  String? _outcome;
  int _contactsBefore = 0;

  // Joining.
  final _text = TextEditingController();
  Contact? _joined;

  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    // The text is a secret, like the QR code.
    _app.setSecureScreen(true);
    _sub = _app.m.changes.listen((_) => _refresh());
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tick?.cancel();
    _text.dispose();
    _app.setSecureScreen(false);
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    final inv = _invite;
    if (inv != null && _outcome == null && !_app.m.invites.containsKey(inv.id)) {
      final now = DateTime.now();
      if (_cancelled) {
        _outcome = 'The invite was cancelled.';
      } else if (inv.expiredAt(now)) {
        _outcome = 'The invite expired unused.';
      } else {
        final who = _app.m.contacts.length > _contactsBefore ? _app.m.contacts.values.last.name : 'Your friend';
        _outcome = '$who joined with your invite. Compare safety numbers in their contact screen.';
      }
      _wipeClipboard();
    } else if (inv != null && _outcome == null && inv.expiredAt(DateTime.now())) {
      _app.m.cancelInvite(inv.id);
      _outcome = 'The invite expired unused.';
      _wipeClipboard();
    }
    setState(() {});
  }

  /// Once the text is useless, do not leave it lying in the clipboard.
  void _wipeClipboard() {
    if (_copied) Clipboard.setData(const ClipboardData(text: ''));
    _copied = false;
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _contactsBefore = _app.m.contacts.length;
      final inv = await _app.m.createInvite();
      setState(() {
        _invite = inv;
        _outcome = null;
        _cancelled = false;
      });
    } catch (e) {
      setState(() => _error = e is StateError ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _invite!.text));
    _copied = true;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied. Send it to your friend over a channel you trust.')),
    );
  }

  void _cancel() {
    _cancelled = true;
    _app.m.cancelInvite(_invite!.id);
    _refresh();
  }

  Future<void> _join() async {
    final text = _text.text;
    InviteCode code;
    try {
      code = InviteCode.parse(text);
      if (code.expiredAt(DateTime.now())) throw const FormatException('this invite has expired');
    } on FormatException catch (e) {
      setState(() => _error = 'That invite did not work: ${e.message}');
      return;
    }
    final name = await _askName(code.code.name);
    if (name == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final c = await _app.m.acceptInvite(text, name: name);
      _text.clear();
      setState(() => _joined = c);
    } catch (e) {
      setState(() => _error = 'That invite did not work: ${e is FormatException ? e.message : e}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askName(String suggested) {
    final ctl = TextEditingController(text: suggested);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name this friend'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Only stored on this device'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Save')),
        ],
      ),
    );
  }

  static String _mmss(Duration d) {
    final s = d.isNegative ? 0 : d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final inv = _invite;
    final joined = _joined == null ? null : _app.m.contacts[_joined!.id];
    return Scaffold(
      appBar: AppBar(title: const Text('Invite text')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('Invite a friend', style: t.textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'Creates a text you send to one friend, for example in another messenger. '
              'It works once: the first person who uses it is added, nobody after that. '
              'Unused, it stops working after 15 minutes.',
            ),
            const SizedBox(height: 12),
            if (inv == null || _outcome != null)
              FilledButton.icon(
                key: const Key('createInvite'),
                onPressed: _busy ? null : _create,
                icon: const Icon(Icons.add_link),
                label: Text(inv == null ? 'Create invite text' : 'Create a new invite text'),
              ),
            if (inv != null && _outcome == null) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    inv.text,
                    key: const Key('inviteText'),
                    maxLines: 4,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
              Row(
                children: [
                  Icon(Icons.timer_outlined, size: 18, color: t.colorScheme.primary),
                  const SizedBox(width: 6),
                  Text('Valid for ${_mmss(inv.expiresAt.difference(DateTime.now()))}, one use'),
                  const Spacer(),
                  TextButton(onPressed: _cancel, child: const Text('Cancel invite')),
                ],
              ),
              FilledButton.icon(onPressed: _copy, icon: const Icon(Icons.copy), label: const Text('Copy invite text')),
              const SizedBox(height: 8),
              Text(
                'Anyone who reads this text before your friend uses it can join in their place. '
                'Send it over a channel you trust, then compare safety numbers with your friend.',
                style: t.textTheme.bodySmall,
              ),
            ],
            if (_outcome != null)
              Card(
                child: ListTile(
                  leading: Icon(_outcome!.contains('joined') ? Icons.check_circle : Icons.timer_off),
                  title: Text(_outcome!),
                ),
              ),
            const Divider(height: 40),
            Text('Got an invite text?', style: t.textTheme.titleMedium),
            const SizedBox(height: 8),
            if (joined == null) ...[
              TextField(
                key: const Key('inviteInput'),
                controller: _text,
                minLines: 2,
                maxLines: 5,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'Paste the zelt-invite:1:… text here',
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                key: const Key('joinInvite'),
                onPressed: _busy ? null : _join,
                icon: const Icon(Icons.person_add),
                label: const Text('Join'),
              ),
            ] else
              Card(
                child: ListTile(
                  leading: Icon(joined.ready ? Icons.check_circle : Icons.hourglass_top),
                  title: Text(joined.ready ? 'Added ${joined.name}' : 'Waiting for ${joined.name} to accept…'),
                  subtitle: Text(
                    joined.ready
                        ? 'Compare safety numbers in their contact screen.'
                        : 'Their device has to be online before the invite expires. '
                              'If someone else used the invite first, this never completes.',
                  ),
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: t.colorScheme.error)),
            ],
          ],
        ),
      ),
    );
  }
}
