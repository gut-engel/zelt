import 'dart:async';
import 'dart:io';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'package:zelt_core/messenger.dart';
import 'package:zelt_core/models.dart';
import 'package:zelt_core/vault.dart';

import 'hardware_key.dart';
import 'media_view.dart';
import 'updater.dart';

enum Phase { loading, setup, locked, unlocked }

/// Bridges the pure-Dart core to the widget tree and the Android service.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
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

  // --- Updates (preferences live outside the vault too) ---
  bool autoUpdateCheck = true;
  DateTime? _lastUpdateCheck;
  AvailableUpdate? update;
  bool updateChecking = false;
  double? updateProgress;
  String? updateMessage;
  int _unseen = 0;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    messenger?.setForeground(state == AppLifecycleState.resumed);
  }

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    final base = await getApplicationSupportDirectory();
    _dir = Directory('${base.path}/zelt');
    await _loadPrefs();
    phase = Vault.exists(_dir) ? Phase.locked : Phase.setup;
    notifyListeners();
    _maybeAutoCheck();
  }

  Messenger get m => messenger!;

  File get _prefsFile => File('${_dir.path}/ui.json');

  Future<void> _loadPrefs() async {
    try {
      final j = jsonDecode(await _prefsFile.readAsString()) as Map<String, dynamic>;
      themeMode = ThemeMode.values.byName(j['theme'] ?? 'system');
      autoUpdateCheck = j['autoUpdate'] ?? true;
      final t = j['lastUpdateCheck'];
      _lastUpdateCheck = t == null ? null : DateTime.fromMillisecondsSinceEpoch(t);
    } catch (_) {
      themeMode = ThemeMode.system;
    }
  }

  Future<void> _savePrefs() async {
    try {
      await _dir.create(recursive: true);
      await _prefsFile.writeAsString(jsonEncode({
        'theme': themeMode.name,
        'autoUpdate': autoUpdateCheck,
        if (_lastUpdateCheck != null) 'lastUpdateCheck': _lastUpdateCheck!.millisecondsSinceEpoch,
      }));
    } catch (e) {
      debugPrint('prefs: $e');
    }
  }

  Future<void> setAutoUpdateCheck(bool on) async {
    autoUpdateCheck = on;
    notifyListeners();
    await _savePrefs();
  }

  /// Checks GitHub for a signed newer release. [manual] reports "up to date".
  Future<void> checkForUpdate({bool manual = false}) async {
    if (!Updater.supported || updateChecking) return;
    updateChecking = true;
    updateMessage = null;
    notifyListeners();
    try {
      update = await Updater.check();
      _lastUpdateCheck = DateTime.now();
      await _savePrefs();
      if (manual && update == null) updateMessage = 'zelt is up to date.';
    } catch (e) {
      if (manual) updateMessage = 'Update check failed: ${_errorText(e)}';
    } finally {
      updateChecking = false;
      notifyListeners();
    }
  }

  void _maybeAutoCheck() {
    if (!autoUpdateCheck) return;
    final last = _lastUpdateCheck;
    if (last != null && DateTime.now().difference(last) < const Duration(hours: 24)) return;
    unawaited(checkForUpdate());
  }

  /// A sentence for the user, not a Dart exception dump.
  static String _errorText(Object e) => switch (e) {
    PlatformException(:final message, :final code) => message ?? code,
    _ => '$e',
  };

  Future<void> installUpdate() async {
    final u = update;
    if (u == null) return;
    updateProgress = 0;
    updateMessage = null;
    notifyListeners();
    try {
      await Updater.install(
        u,
        progress: (p) {
          updateProgress = p;
          notifyListeners();
        },
        onBeforeExit: () async => messenger?.stop(),
      );
      updateMessage = Platform.isAndroid ? 'Confirm the installation in the system dialog.' : null;
    } catch (e) {
      updateMessage = _errorText(e);
    } finally {
      updateProgress = null;
      notifyListeners();
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    await _savePrefs();
  }

  Future<void> setup(String name, String pin) async {
    _vault = await Vault.create(_dir, pin, hardware: await AndroidKeystoreWrapper.open());
    final msgr = Messenger(identity: await Identity.generate(), settings: Settings(name: name));
    await _attach(msgr);
  }

  /// Throws [WrongPin], or [LockedOut] after too many wrong PINs.
  Future<void> unlock(String pin) async {
    final v = await Vault.unlock(_dir, pin, hardware: await AndroidKeystoreWrapper.open());
    final state = await v.load();
    _vault = v;
    final msgr = state == null
        ? Messenger(identity: await Identity.generate(), settings: Settings())
        : await Messenger.load(state);
    await _attach(msgr);
  }

  Future<void> _attach(Messenger msgr) async {
    messenger = msgr;
    msgr.media = VaultMediaStore(_vault!);
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

  /// How the vault is protected, for the settings screen.
  String get vaultFormat {
    try {
      return Vault.exists(_dir) ? Vault.formatOf(_dir) : '';
    } catch (_) {
      return '';
    }
  }

  /// When the next PIN attempt is allowed (null: now).
  DateTime? get lockedUntil {
    try {
      return Vault.exists(_dir) ? Vault.lockedUntil(_dir) : null;
    } catch (_) {
      return null;
    }
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

  /// Blocks screenshots and screen recording while a secret is on screen.
  Future<void> setSecureScreen(bool on) => _call('secure', {'on': on});

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
