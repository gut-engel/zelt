import 'dart:async';
import 'dart:io';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'package:zelt_core/messenger.dart';
import 'package:zelt_core/models.dart';
import 'package:zelt_core/vault.dart';

enum Phase { loading, setup, locked, unlocked }

/// Bridges the pure-Dart core to the widget tree and the Android service.
class AppState extends ChangeNotifier {
  static const _service = MethodChannel('zelt/service');

  Phase phase = Phase.loading;
  Vault? _vault;
  Messenger? messenger;
  late Directory _dir;
  StreamSubscription<void>? _sub;
  Timer? _statusTimer;
  String? openChat;

  /// Not secret, so it lives outside the vault and applies to the lock screen.
  ThemeMode themeMode = ThemeMode.system;
  int _unseen = 0;

  Future<void> init() async {
    final base = await getApplicationSupportDirectory();
    _dir = Directory('${base.path}/zelt');
    await _loadPrefs();
    phase = Vault.exists(_dir) ? Phase.locked : Phase.setup;
    notifyListeners();
  }

  Messenger get m => messenger!;

  File get _prefsFile => File('${_dir.path}/ui.json');

  Future<void> _loadPrefs() async {
    try {
      final j = jsonDecode(await _prefsFile.readAsString()) as Map<String, dynamic>;
      themeMode = ThemeMode.values.byName(j['theme'] ?? 'system');
    } catch (_) {
      themeMode = ThemeMode.system;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    try {
      await _dir.create(recursive: true);
      await _prefsFile.writeAsString(jsonEncode({'theme': mode.name}));
    } catch (e) {
      debugPrint('prefs: $e');
    }
  }

  Future<void> setup(String name, String pin) async {
    _vault = await Vault.create(_dir, pin);
    final msgr = Messenger(identity: await Identity.generate(), settings: Settings(name: name));
    await _attach(msgr);
  }

  /// Throws [WrongPin].
  Future<void> unlock(String pin) async {
    final v = await Vault.unlock(_dir, pin);
    final state = await v.load();
    _vault = v;
    final msgr = state == null
        ? Messenger(identity: await Identity.generate(), settings: Settings())
        : Messenger.fromJson(state);
    await _attach(msgr);
  }

  Future<void> _attach(Messenger msgr) async {
    messenger = msgr;
    msgr.onSave = (s) => _vault!.save(s);
    msgr.onLogLine = (l) => debugPrint('zelt: $l');
    msgr.onIncoming = (c, msg) {
      if (openChat == c.id) return;
      _unseen++;
      _call('notify', {'count': _unseen});
    };
    _sub = msgr.changes.listen((_) => notifyListeners());
    await msgr.save();
    await msgr.start();
    phase = Phase.unlocked;
    notifyListeners();
    await _call('start', {'text': _statusText()});
    _statusTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _call('update', {'text': _statusText()});
      notifyListeners();
    });
  }

  String _statusText() {
    final s = messenger?.status;
    if (s == null) return '';
    final relay = s.relayRunning ? 'relay on' : 'relay off';
    return '${s.activePeers} peers · $relay · ${s.storedBlobs} blobs held';
  }

  void seenChat(String id) {
    openChat = id;
    messenger?.markRead(id);
    _unseen = 0;
    _call('clearNotifications');
  }

  void leftChat() => openChat = null;

  /// Stops everything and forgets the keys from memory.
  Future<void> lock() async {
    _statusTimer?.cancel();
    await _sub?.cancel();
    await messenger?.stop();
    messenger = null;
    _vault = null;
    phase = Phase.locked;
    await _call('stop');
    notifyListeners();
  }

  Future<void> changePin(String pin) async {
    await _vault!.changePin(pin);
  }

  Future<void> wipe() async {
    await lock();
    await Vault.wipe(_dir);
    phase = Phase.setup;
    notifyListeners();
  }

  /// Sends the task to the background instead of finishing the activity,
  /// so the relay keeps running.
  Future<void> moveToBackground() => _call('background');

  Future<void> _call(String method, [Map<String, Object?>? args]) async {
    if (!Platform.isAndroid) return;
    try {
      await _service.invokeMethod(method, args);
    } catch (e) {
      debugPrint('service $method: $e');
    }
  }
}
