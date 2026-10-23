import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zelt_core/backup.dart';
import 'package:zelt_core/backup_targets.dart';
import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/messenger.dart';
import 'package:zelt_core/phrase.dart';
import 'package:zelt_core/state_split.dart';
import 'package:zelt_core/vault.dart';

/// One configured backup destination and how its last run went.
class TargetEntry {
  final String id;
  final Map<String, dynamic> config;
  final int? lastOk;
  final String? lastError;
  final int? lastAttempt;
  TargetEntry(this.id, this.config, {this.lastOk, this.lastError, this.lastAttempt});

  String get type => config['type'] as String;
  String get label => switch (type) {
    'file' => Platform.isAndroid ? 'File in Downloads/Zelt' : 'File ${config['path']}',
    'webdav' => 'WebDAV ${Uri.tryParse(config['url'] as String)?.host ?? ''}',
    's3' => 'S3 ${config['bucket']}',
    'sftp' => 'SFTP ${config['user']}@${config['host']}',
    _ => type,
  };

  Map<String, dynamic> toJson() => {
    'id': id,
    'config': config,
    'lastOk': ?lastOk,
    'lastError': ?lastError,
    'lastAttempt': ?lastAttempt,
  };

  factory TargetEntry.fromJson(Map<String, dynamic> j) => TargetEntry(
    j['id'] as String,
    Map<String, dynamic>.of(j['config'] as Map<String, dynamic>),
    lastOk: j['lastOk'] as int?,
    lastError: j['lastError'] as String?,
    lastAttempt: j['lastAttempt'] as int?,
  );
}

/// Backups for the app: the phrase's public half, the destinations, daily
/// runs. Everything lives in the messenger state (and so in backups too),
/// in `appData['backup']`.
class BackupService extends ChangeNotifier {
  static const _service = MethodChannel('zelt/service');
  static const androidFileName = 'zelt-backup.zbk';
  static const interval = Duration(hours: 24);

  final Messenger m;
  final Vault vault;
  Timer? _timer;
  bool running = false;
  String? progress;

  BackupService(this.m, this.vault);

  Map<String, dynamic> get _cfg => Map<String, dynamic>.of(m.appData['backup'] as Map<String, dynamic>? ?? {});

  void _save(Map<String, dynamic> cfg) {
    m.setAppData('backup', cfg);
    notifyListeners();
  }

  /// A phrase was set up (or restored with): backups can be written.
  bool get configured => _cfg['pub'] != null;
  String? get fingerprint => _cfg['fp'] as String?;
  bool get auto => _cfg['auto'] as bool? ?? true;
  DateTime? get lastRun => _cfg['last'] == null ? null : DateTime.fromMillisecondsSinceEpoch(_cfg['last'] as int);
  bool get skippedSetup => _cfg['skipped'] == true;

  List<TargetEntry> get targets => [
    for (final t in (_cfg['targets'] as List? ?? []).cast<Map<String, dynamic>>()) TargetEntry.fromJson(t),
  ];

  BackupKeys? get _keys {
    final c = _cfg;
    if (c['pub'] == null) return null;
    return BackupKeys.writeOnly(unb64(c['pub'] as String), unb64(c['names'] as String));
  }

  /// Uses [p] from now on. Only its public half is kept.
  Future<void> usePhrase(BackupPhrase p) async {
    final k = await BackupKeys.fromPhrase(p);
    _save(_cfg
      ..['pub'] = b64(k.publicKey)
      ..['names'] = b64(k.nameKey)
      ..['fp'] = k.fingerprint
      ..remove('skipped')
      ..remove('last'));
  }

  void markSkipped() => _save(_cfg..['skipped'] = true);

  void setAuto(bool on) => _save(_cfg..['auto'] = on);

  /// The target for a configuration (the file target goes through Android's
  /// Downloads folder, or the chosen path on a desktop).
  static BackupTarget build(Map<String, dynamic> config) {
    if (config['type'] == 'file' && Platform.isAndroid) {
      return FilePackTarget(
        FilePackIO(
          () async => await _service.invokeMethod<Uint8List>('readBackup', {'name': androidFileName}),
          (bytes) async => _service.invokeMethod('writeBackup', {'bytes': bytes, 'name': androidFileName}),
        ),
        label: 'File in Downloads/Zelt',
      );
    }
    return BackupTarget.fromJson(config);
  }

  /// Checks a target works (list, write, read back, delete). Null if it does,
  /// otherwise a sentence for the user.
  static Future<String?> check(Map<String, dynamic> config) async {
    try {
      final t = build(config);
      await t.list(Backup.mediaPrefix);
      if (config['type'] != 'file') {
        final probe = Uint8List.fromList(List.generate(64, (i) => i));
        await t.put('zelt-check', probe);
        final back = await t.get('zelt-check');
        await t.delete('zelt-check');
        if (back == null || !bytesEqual(back, probe)) return 'the test file did not come back unchanged';
      }
      await t.finish();
      return null;
    } on BackupTargetError catch (e) {
      return e.message;
    } on BackupError catch (e) {
      return e.message;
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    } catch (e) {
      return '$e';
    }
  }

  void addTarget(Map<String, dynamic> config) {
    final list = [...targets, TargetEntry(hex(randomBytes(8)), config)];
    _save(_cfg..['targets'] = [for (final t in list) t.toJson()]);
  }

  void removeTarget(String id) {
    _save(_cfg..['targets'] = [for (final t in targets) if (t.id != id) t.toJson()]);
  }

  void _record(String id, {String? error}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _save(_cfg
      ..['targets'] = [
        for (final t in targets)
          if (t.id != id)
            t.toJson()
          else
            TargetEntry(t.id, t.config, lastOk: error == null ? now : t.lastOk, lastError: error, lastAttempt: now).toJson(),
      ]);
  }

  /// Hashes of every picture a state refers to.
  static Set<String> mediaIn(Map<String, dynamic> state) {
    final out = <String>{};
    void ref(Object? r) {
      if (r is Map<String, dynamic> && r['h'] is String) out.add(hex(unb64(r['h'] as String)));
    }

    void messages(Object? l) {
      for (final msg in (l as List? ?? []).cast<Map<String, dynamic>>()) {
        ref(msg['m']);
      }
    }

    for (final c in (state['contacts'] as List? ?? []).cast<Map<String, dynamic>>()) {
      messages(c['messages']);
      ref(c['av']);
    }
    for (final g in (state['groups'] as List? ?? []).cast<Map<String, dynamic>>()) {
      messages(g['messages']);
    }
    for (final s in (state['stickers'] as List? ?? [])) {
      ref(s);
    }
    ref((state['settings'] as Map<String, dynamic>? ?? {})['avatar']);
    return out;
  }

  /// Backs up to every target now. Returns the errors (empty: all fine).
  Future<List<String>> runNow() async {
    final keys = _keys;
    // A device whose identity moved elsewhere must never overwrite the new
    // device's backups with its old state.
    if (keys == null || running || m.superseded) return const [];
    final list = targets;
    if (list.isEmpty) return const [];
    running = true;
    progress = 'Preparing…';
    notifyListeners();
    final errors = <String>[];
    try {
      final full = m.backupJson();
      final Map<String, dynamic> public;
      final Uint8List? privatePart;
      final Set<String>? privateMedia;
      if (vault.duress) {
        // The private part cannot be read here: the last real one goes in
        // unchanged, and no picture is removed from the backup.
        public = full;
        privatePart = await vault.readBackupPrivate();
        privateMedia = null;
      } else {
        final (pub, priv) = StateSplit.split(full);
        public = pub;
        privateMedia = mediaIn(priv);
        privatePart = await Backup.sealPrivate(keys, priv, privateMedia);
        await vault.writeBackupPrivate(privatePart);
      }
      final media = mediaIn(public);
      for (final t in list) {
        progress = 'Backing up to ${t.label}…';
        notifyListeners();
        try {
          await BackupRunner.write(
            build(t.config),
            keys,
            state: public,
            media: media,
            privatePart: privatePart,
            privateMedia: privateMedia,
            readMedia: m.media.read,
          );
          _record(t.id);
        } catch (e) {
          final msg = switch (e) {
            BackupTargetError(:final message) => message,
            PlatformException(:final message, :final code) => message ?? code,
            _ => '$e',
          };
          errors.add('${t.label}: $msg');
          _record(t.id, error: msg);
          m.log('backup to ${t.label} failed: $msg');
        }
      }
      if (errors.length < list.length) _save(_cfg..['last'] = DateTime.now().millisecondsSinceEpoch);
      m.log('backup done: ${list.length - errors.length}/${list.length} targets');
    } finally {
      running = false;
      progress = null;
      notifyListeners();
    }
    return errors;
  }

  /// Daily automatic backups while the app runs.
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 30), (_) => _maybeRun());
    Timer(const Duration(minutes: 2), _maybeRun);
  }

  void _maybeRun() {
    if (!auto || !configured || targets.isEmpty || running || m.superseded) return;
    final last = lastRun;
    if (last != null && DateTime.now().difference(last) < interval) return;
    unawaited(runNow());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
