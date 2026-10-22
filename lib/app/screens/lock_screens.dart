import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:zelt_core/vault.dart';
import '../app_state.dart';

class _Brand extends StatelessWidget {
  final String subtitle;
  const _Brand(this.subtitle);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      children: [
        Icon(Icons.change_history_rounded, size: 72, color: t.colorScheme.primary),
        const SizedBox(height: 8),
        Text('zelt', style: t.textTheme.displaySmall),
        const SizedBox(height: 8),
        Text(subtitle, textAlign: TextAlign.center, style: t.textTheme.bodyMedium),
      ],
    );
  }
}

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _name = TextEditingController();
  final _pin = TextEditingController();
  final _pin2 = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _go() async {
    if (_pin.text.length < 6) {
      setState(() => _error = 'Use at least 6 characters');
      return;
    }
    if (_pin.text != _pin2.text) {
      setState(() => _error = 'The two entries differ');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await context.read<AppState>().setup(_name.text.trim(), _pin.text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 32),
            const _Brand(
              'No servers, no accounts, no phone number.\n'
              'Your identity is a key pair made on this phone.',
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name shown to friends when pairing (optional)',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _pin,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'PIN or passphrase'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _pin2,
              obscureText: true,
              decoration: InputDecoration(labelText: 'Repeat', errorText: _error),
              onSubmitted: (_) => _go(),
            ),
            const SizedBox(height: 8),
            Text(
              'It seals your messages on this phone. There is no recovery: '
              'if you forget it, the data is gone.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _go,
              child: _busy
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Create identity'),
            ),
          ],
        ),
      ),
    );
  }
}

class UnlockScreen extends StatefulWidget {
  const UnlockScreen({super.key});

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  final _pin = TextEditingController();
  String? _error;
  bool _busy = false;
  DateTime? _lockedUntil;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _setLock(context.read<AppState>().lockedUntil);
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// Wrong PINs cause escalating delays (kept across restarts by the vault).
  void _setLock(DateTime? until) {
    _tick?.cancel();
    _lockedUntil = until;
    if (until == null) return;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (!DateTime.now().isBefore(_lockedUntil!)) {
          _lockedUntil = null;
          _tick?.cancel();
        }
      });
    });
  }

  String? get _lockText {
    final u = _lockedUntil;
    if (u == null) return null;
    final s = u.difference(DateTime.now()).inSeconds + 1;
    return 'Too many wrong PINs. Try again in ${s >= 60 ? '${s ~/ 60} min ${s % 60} s' : '$s s'}.';
  }

  Future<void> _go() async {
    if (_lockedUntil != null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AppState>().unlock(_pin.text);
    } on WrongPin {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Wrong PIN';
        _pin.clear();
        _setLock(context.read<AppState>().lockedUntil);
      });
    } on LockedOut catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = null;
        _setLock(e.until);
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Could not open: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 64),
            const _Brand('Locked'),
            const SizedBox(height: 32),
            TextField(
              controller: _pin,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(labelText: 'PIN or passphrase', errorText: _lockText ?? _error),
              onSubmitted: (_) => _go(),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy || _lockedUntil != null ? null : _go,
              child: _busy
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Unlock'),
            ),
          ],
        ),
      ),
    );
  }
}
