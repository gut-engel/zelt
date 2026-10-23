import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:zelt_core/invite.dart';
import 'package:zelt_core/models.dart';
import 'package:zelt_core/pairing.dart';
import '../app_state.dart';
import 'scan_page.dart';
import 'widgets.dart';

/// How long the QR invite works. One scan links both devices.
const qrInviteValidity = Duration(minutes: 10);

/// After leaving the screen unused, the QR invite stays valid this long, in
/// case the friend's scan is still on its way.
const qrInviteGrace = Duration(minutes: 2);

/// In-person pairing: one device shows its QR code, the other scans it, and
/// both are linked. The code is a one-time invite (see invite.dart): the first
/// scan uses it up, and it expires after [qrInviteValidity].
class PairScreen extends StatefulWidget {
  /// How long the code stays visible before it hides itself.
  final Duration qrTimeout;

  /// An invite made beforehand (tests); normally the screen makes its own.
  final PendingInvite? invite;
  const PairScreen({super.key, this.qrTimeout = const Duration(seconds: 90), this.invite});

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  PendingInvite? _invite;
  Contact? _linked;
  String? _error;
  bool _hidden = false;
  bool _busy = false;
  Timer? _hideTimer;
  Timer? _retry;
  StreamSubscription<void>? _sub;
  late final AppState _app;
  late final Map<String, Contact> _before;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _app.setSecureScreen(true);
    _before = Map.of(_app.m.contacts);
    _sub = _app.m.changes.listen((_) => _onChange());
    _invite = widget.invite;
    if (_invite == null) _createInvite();
    _armHide();
  }

  Future<void> _createInvite() async {
    try {
      final inv = await _app.m.createInvite(validity: qrInviteValidity);
      if (!mounted) {
        _app.m.cancelInvite(inv.id);
        return;
      }
      setState(() {
        _invite = inv;
        _error = null;
      });
    } on StateError {
      // Not connected yet: no mailbox to receive the friend's scan.
      _retry = Timer(const Duration(seconds: 2), _createInvite);
      if (mounted) setState(() {});
    }
  }

  /// The friend scanned our code: their join request linked us. Once linked,
  /// keeps redrawing until the key exchange is done.
  void _onChange() {
    if (!mounted) return;
    if (_linked != null) {
      setState(() {});
      return;
    }
    final inv = _invite;
    if (inv == null || _app.m.invites.containsKey(inv.id)) return;
    final c = _app.m.contacts.values.where((c) => !identical(_before[c.id], c)).lastOrNull;
    if (c != null) setState(() => _linked = c);
  }

  void _armHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(widget.qrTimeout, () {
      if (mounted) setState(() => _hidden = true);
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _retry?.cancel();
    _sub?.cancel();
    final inv = _invite;
    if (inv != null) _app.m.shortenInvite(inv.id, qrInviteGrace);
    _app.setSecureScreen(false);
    super.dispose();
  }

  Future<void> _scan() async {
    final code = await push<String>(
      context,
      const ScanPage(title: 'Scan friend\'s code', prefixes: [InviteCode.prefix, PairingCode.prefix]),
    );
    if (code == null || !mounted) return;
    await _complete(code);
  }

  /// Desktop (no camera), and debug/profile builds for test harnesses: paste
  /// the friend's code instead of scanning it.
  Future<void> _paste() async {
    final ctl = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(canScanQr ? 'Paste code (debug)' : 'Friend\'s code'),
        content: TextField(key: const Key('debugCode'), controller: ctl, autofocus: true, maxLines: 4),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('Link')),
        ],
      ),
    );
    if (code == null || code.isEmpty || !mounted) return;
    await _complete(code);
  }

  Future<void> _complete(String code) async {
    final InviteCode parsed;
    try {
      if (code.trim().startsWith(PairingCode.prefix)) {
        throw const FormatException('that device runs an older zelt; update both and try again');
      }
      parsed = InviteCode.parse(code);
      if (parsed.expiredAt(DateTime.now())) throw const FormatException('that code has expired; ask for a new one');
    } on FormatException catch (e) {
      setState(() => _error = 'That code did not work: ${e.message}');
      return;
    }
    final name = await _askName(parsed.code.name);
    if (name == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final c = await _app.m.acceptInvite(code, name: name);
      // Linked through their code: ours is not needed any more.
      final own = _invite;
      if (own != null) _app.m.cancelInvite(own.id);
      setState(() {
        _linked = c;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = 'That code did not work: ${e is FormatException ? e.message : e}');
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

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final inv = _invite;
    final linked = _linked == null ? null : (_app.m.contacts[_linked!.id] ?? _linked!);
    return Scaffold(
      appBar: AppBar(title: const Text('Add friend')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (linked != null) ...[
              Card(
                child: ListTile(
                  leading: Icon(linked.ready ? Icons.check_circle : Icons.hourglass_top),
                  title: Text(linked.ready ? 'Linked with ${linked.name}' : 'Linking with ${linked.name}…'),
                  subtitle: Text(
                    linked.ready
                        ? 'End-to-end encrypted.'
                        : 'Finishing the key exchange; this needs ${linked.name}\'s device online.',
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text('Safety number', style: t.textTheme.titleMedium),
              const SizedBox(height: 8),
              SafetyNumberCard(linked),
              const SizedBox(height: 8),
              Text(
                'Compare this with ${linked.name}\'s screen now, while you are together. If the '
                'numbers match, nobody swapped a code during pairing.',
                style: t.textTheme.bodySmall,
              ),
              SwitchListTile(
                key: const Key('numbersMatch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Numbers match'),
                subtitle: const Text('Also shares your profile picture with them'),
                value: linked.verified,
                onChanged: (v) => setState(() => _app.m.setVerified(linked.id, v)),
              ),
              const SizedBox(height: 8),
              FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
            ] else ...[
              Text('Let your friend scan this code', style: t.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text('Only one of you needs to scan: that links both devices.', style: t.textTheme.bodySmall),
              const SizedBox(height: 12),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                  child: inv == null
                      ? const SizedBox(
                          width: 280,
                          height: 280,
                          child: Center(child: Text('Connecting…', style: TextStyle(color: Colors.black54))),
                        )
                      : _hidden
                      ? SizedBox(
                          width: 280,
                          height: 280,
                          child: Center(
                            child: OutlinedButton.icon(
                              key: const Key('showQrAgain'),
                              onPressed: () {
                                setState(() => _hidden = false);
                                _armHide();
                              },
                              icon: const Icon(Icons.visibility),
                              label: const Text('Show code again'),
                            ),
                          ),
                        )
                      : QrImageView(
                          data: inv.text,
                          size: 280,
                          backgroundColor: Colors.white,
                          errorCorrectionLevel: QrErrorCorrectLevel.L,
                        ),
                ),
              ),
              const SizedBox(height: 8),
              Card(
                color: t.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber, color: t.colorScheme.onErrorContainer),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'This code is a secret. Anyone who photographs it gets your pairing '
                          'secret and your relay addresses, and could link instead of your friend. '
                          'Show it only to the friend in front of you. It works once, hides itself '
                          'after ${widget.qrTimeout.inSeconds} s and expires after ${qrInviteValidity.inMinutes} min.',
                          style: TextStyle(color: t.colorScheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text('Or scan their code', style: t.textTheme.titleMedium),
              const SizedBox(height: 12),
              if (canScanQr)
                FilledButton.icon(
                  onPressed: _busy ? null : _scan,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan friend\'s code'),
                )
              else
                // Desktop has no camera scanner: the friend's phone scans this
                // screen, or the friend's code is entered here.
                FilledButton.icon(
                  onPressed: _busy ? null : _paste,
                  icon: const Icon(Icons.keyboard),
                  label: const Text('Enter friend\'s code'),
                ),
              if (canScanQr && (kDebugMode || kProfileMode))
                TextButton(onPressed: _busy ? null : _paste, child: const Text('Paste code (debug)')),
            ],
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
