import 'dart:async';
import 'dart:io';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'package:zelt_core/backup_targets.dart';
import 'package:zelt_core/groups.dart';
import 'package:zelt_core/messenger.dart';
import 'package:zelt_core/models.dart';
import 'package:zelt_core/phrase.dart';
import 'package:zelt_core/state_split.dart';
import 'package:zelt_core/vault.dart';

import 'backup_service.dart';
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
  BackupService? backup;

  /// Just created: offer to set up a backup before anything else.
  bool offerBackup = false;

  /// Opened with the duress PIN (private chats are not loaded).
  bool get duress => _vault?.duress ?? false;

  /// A duress session's chats marked private: their pending addition to the
  /// private section, rewritten on every save.
  String? _duressPending;

  /// A duress session pretends a duress PIN can be set (it cannot touch the
  /// real slot): what it was told, for this session only.
  bool _fakeDuressSet = false;
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

  /// Tests: a messenger without a vault, wired to the widgets like a real one.
  @visibleForTesting
  void useMessenger(Messenger msgr) {
    messenger = msgr;
    _sub = msgr.changes.listen((_) => notifyListeners());
  }

  /// Tests: the app's data folder, without the platform's.
  @visibleForTesting
  Future<void> initAt(Directory dir) async {
    _dir = dir;
    phase = Vault.exists(_dir) ? Phase.locked : Phase.setup;
  }

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

  Future<void> setup(String name, String pin, {@visibleForTesting Settings? settings}) async {
    _vault = await Vault.create(_dir, pin, hardware: await AndroidKeystoreWrapper.open());
    final msgr = Messenger(identity: await Identity.generate(), settings: settings ?? Settings(name: name));
    offerBackup = true;
    await _attach(msgr);
  }

  /// Restores a backup onto this device (no vault yet): reads everything
  /// first, so a wrong phrase or a broken connection leaves nothing behind.
  Future<RestoredBackup> restore(
    BackupTarget target,
    BackupPhrase phrase,
    String pin, {
    void Function(int done, int total)? progress,
  }) async {
    final media = <String, Uint8List>{};
    final r = await BackupRunner.read(target, phrase, writeMedia: (h, b) async => media[h] = b, progress: progress);
    final msgr = await Messenger.restore(r.state);
    final v = await Vault.create(_dir, pin, hardware: await AndroidKeystoreWrapper.open());
    for (final e in media.entries) {
      await v.writeBlob(e.key, e.value);
    }
    _vault = v;
    await _attach(msgr);
    // Backups go on with the same phrase.
    await backup!.usePhrase(phrase);
    return r;
  }

  /// Throws [WrongPin], or [LockedOut] after too many wrong PINs.
  Future<void> unlock(String pin) async {
    final v = await Vault.unlock(_dir, pin, hardware: await AndroidKeystoreWrapper.open());
    var state = await v.load();
    if (!v.duress) {
      // The private section, plus chats a duress session marked private.
      final parts = await v.loadPrivate();
      if (state != null) state = StateSplit.merge(state, parts);
    }
    _vault = v;
    _duressPending = null;
    _fakeDuressSet = false;
    final msgr = state == null
        ? Messenger(identity: await Identity.generate(), settings: Settings())
        : await Messenger.load(state);
    await _attach(msgr);
  }

  /// Saves the state in its two parts. A duress session cannot write the
  /// private section: chats it marks private go into an addition sealed to
  /// the private section, merged by the next real unlock.
  Future<void> _save(Map<String, dynamic> full) async {
    final v = _vault;
    if (v == null) return;
    final (public, private) = StateSplit.split(full);
    await v.save(public);
    if (!v.duress) {
      await v.savePrivate(private);
    } else if (_duressPending != null || (private['contacts'] as List).isNotEmpty || (private['groups'] as List).isNotEmpty) {
      _duressPending = await v.addPrivate(private, replace: _duressPending);
    }
  }

  Future<void> _attach(Messenger msgr) async {
    messenger = msgr;
    msgr.media = VaultMediaStore(_vault!);
    msgr.onSave = _save;
    msgr.onLogLine = (l) => debugPrint('zelt: $l');
    msgr.onIncoming = (c, msg) {
      if (openChat == c.id) return;
      _unseen++;
      _call('notify', {'count': _unseen});
    };
    msgr.onIncomingGroup = (g, msg) {
      if (openChat == g.id) return;
      _unseen++;
      _call('notify', {'count': _unseen});
    };
    _sub = msgr.changes.listen((_) => notifyListeners());
    await msgr.save();
    await msgr.start();
    backup = BackupService(msgr, _vault!)
      ..addListener(notifyListeners)
      ..start();
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
    messenger?.markGroupRead(id);
    _unseen = 0;
    _call('clearNotifications');
  }

  void leftChat() => openChat = null;

  /// Stops everything and forgets the keys from memory.
  Future<void> lock() async {
    _statusTimer?.cancel();
    backup?.dispose();
    backup = null;
    offerBackup = false;
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

  /// Changes the PIN this session was opened with. Throws [ArgumentError]
  /// if it would match the other PIN.
  Future<void> changePin(String pin) async {
    await _vault!.changePin(pin);
  }

  // --- Duress PIN ------------------------------------------------------

  bool get duressPinSet => duress ? _fakeDuressSet : (_vault?.duressPinSet ?? false);

  /// Sets the duress PIN: it opens zelt without the private chats. In a
  /// duress session this only pretends (the real PIN's data must stay
  /// untouched, and must not be detectable either).
  Future<void> setDuressPin(String pin) async {
    if (duress) {
      _fakeDuressSet = true;
    } else {
      await _vault!.setDuressPin(pin);
    }
    notifyListeners();
  }

  Future<void> clearDuressPin() async {
    if (duress) {
      _fakeDuressSet = false;
    } else {
      await _vault!.clearDuressPin();
    }
    notifyListeners();
  }

  /// The backup offer after creating an identity was answered.
  void finishBackupOffer() {
    offerBackup = false;
    notifyListeners();
  }

  /// Marks a chat (contact or group) private or not.
  void setPrivate(String id, bool private) {
    final m = messenger;
    if (m == null) return;
    if (m.contacts.containsKey(id)) {
      m.setContactPrivate(id, private);
    } else {
      m.setGroupPrivate(id, private);
    }
  }

  bool isPrivate(String id) =>
      messenger?.contacts[id]?.private ?? messenger?.groups[id]?.private ?? false;

  Group? group(String id) => messenger?.groups[id];

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
