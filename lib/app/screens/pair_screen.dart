import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:zelt_core/messenger.dart';
import 'package:zelt_core/models.dart';
import 'package:zelt_core/pairing.dart';
import '../app_state.dart';
import 'scan_page.dart';
import 'widgets.dart';

/// In-person pairing: both phones show their code and scan the other's.
class PairScreen extends StatefulWidget {
  /// How long the code stays visible before it hides itself.
  final Duration qrTimeout;
  const PairScreen({super.key, this.qrTimeout = const Duration(seconds: 90)});

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  PairingSession? _session;
  Contact? _paired;
  String? _error;
  bool _hidden = false;
  Timer? _hideTimer;
  late final AppState _app;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _app.setSecureScreen(true);
    _app.m.newPairingSession().then((s) {
      if (mounted) setState(() => _session = s);
    });
    _armHide();
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
    _app.setSecureScreen(false);
    super.dispose();
  }

  Future<void> _scan() async {
    final code = await push<String>(
      context,
      const ScanPage(title: 'Scan friend\'s code', prefixes: [PairingCode.prefix]),
    );
    if (code == null || !mounted) return;
    await _complete(code);
  }

  /// Debug and profile builds only: lets a test harness type the friend's code over adb
  /// instead of pointing the camera at it. Release builds pair in person only.
  Future<void> _paste() async {
    final ctl = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(canScanQr ? 'Paste code (debug)' : 'Friend\'s code'),
        content: TextField(key: const Key('debugCode'), controller: ctl, autofocus: true, maxLines: 4),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('Pair')),
        ],
      ),
    );
    if (code == null || code.isEmpty || !mounted) return;
    await _complete(code);
  }

  Future<void> _complete(String code) async {
    try {
      final parsed = PairingCode.parse(code);
      final name = await _askName(parsed.name);
      if (name == null || !mounted) return;
      final c = await context.read<AppState>().m.completePairing(_session!, code, name: name);
      setState(() {
        _paired = c;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = 'That code did not work: $e');
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
    final s = _session;
    return Scaffold(
      appBar: AppBar(title: const Text('Add friend')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              _paired == null ? '1. Let your friend scan this code' : 'Let ${_paired!.name} scan this code too',
              style: t.textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Center(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                child: s == null
                    ? const SizedBox(width: 280, height: 280, child: Center(child: CircularProgressIndicator()))
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
                        data: s.code,
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
                        'secret and your relay addresses. Show it only to the friend in '
                        'front of you. It hides itself after ${widget.qrTimeout.inSeconds} s.',
                        style: TextStyle(color: t.colorScheme.onErrorContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text('2. Scan their code', style: t.textTheme.titleMedium),
            const SizedBox(height: 12),
            if (_paired == null) ...[
              if (canScanQr)
                FilledButton.icon(
                  onPressed: s == null ? null : _scan,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan friend\'s code'),
                )
              else
                // Desktop has no camera scanner: type or paste the code shown
                // on your friend's phone while you are together.
                FilledButton.icon(
                  onPressed: s == null ? null : _paste,
                  icon: const Icon(Icons.keyboard),
                  label: const Text('Enter friend\'s code'),
                ),
              if (canScanQr && (kDebugMode || kProfileMode))
                TextButton(onPressed: s == null ? null : _paste, child: const Text('Paste code (debug)')),
            ],
            if (_paired != null)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.check_circle),
                  title: Text('Paired with ${_paired!.name}'),
                  subtitle: const Text(
                    'Keep this screen open until they have scanned your code. '
                    'Then compare safety numbers in the contact screen.',
                  ),
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: t.colorScheme.error)),
            ],
            if (_paired != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
            ],
          ],
        ),
      ),
    );
  }
}
