import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'bytes.dart';
import 'crypto.dart';

class WrongPin implements Exception {
  @override
  String toString() => 'Wrong PIN';
}

/// Too many wrong PINs: try again after [until].
class LockedOut implements Exception {
  final DateTime until;
  LockedOut(this.until);
  Duration get remaining => until.difference(DateTime.now());
  @override
  String toString() => 'Too many wrong PINs. Try again in ${remaining.inSeconds + 1} s.';
}

/// A key that never leaves this device's secure hardware (Android Keystore:
/// StrongBox or TEE). It can only encrypt and decrypt on the device.
abstract class HardwareKeyWrapper {
  /// "strongbox" or "tee".
  String get kind;
  Future<Uint8List> wrap(Uint8List data);
  Future<Uint8List> unwrap(Uint8List data);
}

/// Encrypted local storage for history, keys and the unsent outbox.
///
/// Three random keys protect the data: one for the state (and media), one for
/// the private section (chats marked private), and an X25519 key pair whose
/// public half lets any session add to the private section without reading
/// it. vault.json holds two PIN slots, each the keys wrapped with a key
/// stretched from a PIN by Argon2id, then by a non-exportable hardware key
/// ([HardwareKeyWrapper]). The real PIN's slot holds all keys. The duress
/// PIN's slot holds only the state key: it opens everything except private
/// chats, and leaves them untouched. Without a duress PIN the second slot is
/// random bytes of the same size, so vault.json looks the same either way
/// and nothing shows whether a duress PIN exists. Every attempt tries both
/// slots (two Argon2id runs), so the time taken does not tell either.
///
/// A copy of the vault is useless anywhere else: PIN guesses can only be
/// tested on this device. Wrong PINs cause escalating delays recorded in
/// vault.json, so they survive restarts. Without hardware (desktop) the
/// slots are wrapped by Argon2id only, with the same delays.
class Vault {
  final Directory dir;
  final Uint8List _stateKey;

  /// Null in a duress session.
  final Uint8List? _privateKey;
  final KeyPair25519? _pendingKey;
  final HardwareKeyWrapper? _hw;

  static const _memKib = 64 * 1024;
  static const _iterations = 3;

  /// Wrong PINs allowed before delays start.
  static const freeAttempts = 4;
  static const firstDelay = Duration(seconds: 30);
  static const maxDelay = Duration(hours: 1);

  /// Slot contents: state key, private key, pending-key seed.
  static const _slotKeys = 96;

  Vault._(this.dir, this._stateKey, this._privateKey, this._pendingKey, this._hw);

  /// Opened with the duress PIN: private chats are neither readable nor
  /// shown, and stay as they are.
  bool get duress => _privateKey == null;

  static File _meta(Directory d) => File('${d.path}/vault.json');
  static File _state(Directory d) => File('${d.path}/state.bin');
  static File _private(Directory d) => File('${d.path}/private.bin');
  static Directory _pendingDir(Directory d) => Directory('${d.path}/pending');

  static bool exists(Directory d) => _meta(d).existsSync();

  /// "v2 (strongbox)", "v2 (tee)" or "v1 (PIN only)".
  static String formatOf(Directory d) {
    final m = jsonDecode(_meta(d).readAsStringSync()) as Map<String, dynamic>;
    return m['v'] == 2 ? 'v2 (${m['hw']})' : 'v1 (PIN only)';
  }

  static Future<Uint8List> _pinKey(String pin, Map<String, dynamic> meta, {bool second = false}) => Crypto.argon2id(
    pin,
    unb64(meta[second ? 'salt2' : 'salt']),
    memoryKib: meta['mem'],
    iterations: meta['it'],
  );

  static final _aad = utf8.encode('zelt-vault');

  static Future<Vault> create(Directory d, String pin, {HardwareKeyWrapper? hardware}) async {
    await d.create(recursive: true);
    final keys = randomBytes(_slotKeys);
    final meta = _freshMeta()..['salt2'] = b64(randomBytes(16));
    meta['apk'] = b64((await Crypto.x25519FromPrivate(keys.sublist(64, 96))).pub);
    await _writeSlot(d, meta, pin, keys, hardware);
    await _writeRandomSlot(meta, hardware);
    await _saveMeta(d, meta);
    final v = await _open(d, keys, hardware);
    await v.savePrivate(const {});
    return v;
  }

  static Future<Vault> _open(Directory d, Uint8List keys, HardwareKeyWrapper? hw) async {
    final duress = keys.sublist(32).every((b) => b == 0);
    return Vault._(
      d,
      keys.sublist(0, 32),
      duress ? null : keys.sublist(32, 64),
      duress ? null : await Crypto.x25519FromPrivate(keys.sublist(64, 96)),
      hw,
    );
  }

  static Map<String, dynamic> _freshMeta() => {
    'kdf': 'argon2id',
    'salt': b64(randomBytes(16)),
    'mem': _memKib,
    'it': _iterations,
    'failed': 0,
  };

  /// Wraps [keys] with [pin] into slot 1 (`wrapped`) or 2 (`wrapped2`).
  static Future<void> _writeSlot(
    Directory d,
    Map<String, dynamic> meta,
    String pin,
    Uint8List keys,
    HardwareKeyWrapper? hw, {
    bool second = false,
  }) async {
    final nonce = randomBytes(12);
    final pinKey = await _pinKey(pin, meta, second: second);
    final pinWrapped = concat([nonce, await Crypto.seal(pinKey, nonce, keys, aad: _aad)]);
    if (hw != null) {
      meta['v'] = 2;
      meta['hw'] = hw.kind;
    } else {
      meta['v'] = 1;
      meta.remove('hw');
    }
    meta[second ? 'wrapped2' : 'wrapped'] = b64(hw != null ? await hw.wrap(pinWrapped) : pinWrapped);
  }

  /// Slot 2 without a duress PIN: random bytes, the size of a real slot.
  static Future<void> _writeRandomSlot(Map<String, dynamic> meta, HardwareKeyWrapper? hw) async {
    final fake = randomBytes(12 + _slotKeys + 16);
    meta['wrapped2'] = b64(hw != null ? await hw.wrap(fake) : fake);
  }

  static Future<void> _saveMeta(Directory d, Map<String, dynamic> meta) =>
      _atomicWrite(_meta(d), utf8.encode(jsonEncode(meta)));

  /// Delay after [failed] consecutive wrong PINs.
  static Duration delayAfter(int failed) {
    if (failed <= freeAttempts) return Duration.zero;
    final ms = firstDelay.inMilliseconds * (1 << (failed - freeAttempts - 1).clamp(0, 20));
    return Duration(milliseconds: ms > maxDelay.inMilliseconds ? maxDelay.inMilliseconds : ms);
  }

  /// When the next attempt is allowed (null: now).
  static DateTime? lockedUntil(Directory d) {
    final meta = jsonDecode(_meta(d).readAsStringSync()) as Map<String, dynamic>;
    final t = meta['lockUntil'];
    if (t == null) return null;
    final until = DateTime.fromMillisecondsSinceEpoch(t);
    return until.isAfter(DateTime.now()) ? until : null;
  }

  static Future<void> _attempts = Future.value();

  /// Throws [LockedOut] while delayed, [WrongPin] on a wrong PIN. A v1 vault
  /// is upgraded to v2 when [hardware] is given. Opens the real or the duress
  /// slot, whichever the PIN fits ([duress]).
  ///
  /// Attempts are serialised (parallel guesses cannot share one count), and
  /// each is recorded with its would-be delay *before* the PIN is tested, so
  /// killing the app mid-check still counts the guess. Success clears it.
  static Future<Vault> unlock(Directory d, String pin, {HardwareKeyWrapper? hardware}) {
    final done = Completer<Vault>();
    _attempts = _attempts.then((_) async {
      try {
        done.complete(await _unlock(d, pin, hardware));
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  /// Opens slot 1 or 2 with [pin]; null if it fits neither.
  static Future<(Uint8List, bool)?> _tryPin(Map<String, dynamic> meta, String pin, HardwareKeyWrapper? hw) async {
    Future<Uint8List?> attempt(bool second) async {
      final field = second ? 'wrapped2' : 'wrapped';
      if (meta[field] == null || (second && meta['salt2'] == null)) return null;
      try {
        var w = unb64(meta[field]);
        if (meta['v'] == 2) w = await hw!.unwrap(w);
        final pinKey = await _pinKey(pin, meta, second: second);
        return await Crypto.open(pinKey, w.sublist(0, 12), w.sublist(12), aad: _aad);
      } catch (_) {
        return null;
      }
    }

    // Both slots, always: the time taken must not depend on the PIN.
    final results = await Future.wait([attempt(false), attempt(true)]);
    if (results[0] != null) return (results[0]!, false);
    if (results[1] != null) return (results[1]!, true);
    return null;
  }

  static Future<Vault> _unlock(Directory d, String pin, HardwareKeyWrapper? hardware) async {
    final meta = jsonDecode(await _meta(d).readAsString()) as Map<String, dynamic>;
    final lock = meta['lockUntil'];
    if (lock != null && DateTime.fromMillisecondsSinceEpoch(lock).isAfter(DateTime.now())) {
      throw LockedOut(DateTime.fromMillisecondsSinceEpoch(lock));
    }
    final v2 = meta['v'] == 2;
    if (v2 && hardware == null) {
      throw StateError('this vault is bound to the hardware key of the device that created it');
    }
    // Count this attempt as failed until proven otherwise.
    final failed = (meta['failed'] as int? ?? 0) + 1;
    meta['failed'] = failed;
    final delay = delayAfter(failed);
    if (delay > Duration.zero) {
      meta['lockUntil'] = DateTime.now().add(delay).millisecondsSinceEpoch;
    } else {
      meta.remove('lockUntil');
    }
    await _saveMeta(d, meta);

    final opened = await _tryPin(meta, pin, v2 ? hardware : null);
    if (opened == null) throw WrongPin();
    var (keys, second) = opened;

    meta['failed'] = 0;
    meta.remove('lockUntil');
    // Binding to the hardware key re-wraps the slot that was opened and
    // drops the other one (it cannot be re-wrapped without its PIN). Only
    // the real PIN may do that, or it would destroy the real slot.
    final upgrade = !v2 && hardware != null && !second;
    if (keys.length == 32) {
      // Before private chats: the one master key becomes the state key, and
      // the private keys and the second slot are made now.
      keys = concat([keys, randomBytes(_slotKeys - 32)]);
      meta['salt2'] ??= b64(randomBytes(16));
      meta['apk'] = b64((await Crypto.x25519FromPrivate(keys.sublist(64, 96))).pub);
      await _writeSlot(d, meta, pin, keys, upgrade ? hardware : (v2 ? hardware : null));
      await _writeRandomSlot(meta, upgrade || v2 ? hardware : null);
      await _saveMeta(d, meta);
      final v = await _open(d, keys, upgrade || v2 ? hardware : null);
      await v.savePrivate(const {});
      return v;
    }
    if (upgrade) {
      // An existing duress PIN is dropped with the second slot and has to be
      // set again.
      await _writeSlot(d, meta, pin, keys, hardware);
      await _writeRandomSlot(meta, hardware);
      await _saveMeta(d, meta);
      final v = await _open(d, keys, hardware);
      await v.loadPrivate();
      v._privateMeta['duress'] = false;
      await v._savePrivateFile();
      return v;
    }
    await _saveMeta(d, meta);
    return _open(d, keys, v2 ? hardware : null);
  }

  /// Changes the PIN of the slot this session was opened with.
  Future<void> changePin(String newPin) async {
    final meta = jsonDecode(await _meta(dir).readAsString()) as Map<String, dynamic>;
    final second = duress;
    if (await _tryPin(meta, newPin, _hw) case (_, final otherSecond) when otherSecond != second) {
      throw ArgumentError('choose a PIN different from the other one');
    }
    if (second) {
      meta['salt2'] = b64(randomBytes(16));
    } else {
      meta['salt'] = b64(randomBytes(16));
    }
    meta.remove('lockUntil');
    meta['failed'] = 0;
    await _writeSlot(dir, meta, newPin, _slotContents(), _hw, second: second);
    await _saveMeta(dir, meta);
  }

  Uint8List _slotContents() => duress
      ? concat([_stateKey, Uint8List(64)])
      : concat([_stateKey, _privateKey!, _pendingKey!.priv]);

  // --- Duress PIN (real session only) ----------------------------------

  void _requireReal() {
    if (duress) throw StateError('not available');
  }

  /// Sets (or changes) the duress PIN. It must differ from the real PIN.
  Future<void> setDuressPin(String pin) async {
    _requireReal();
    final meta = jsonDecode(await _meta(dir).readAsString()) as Map<String, dynamic>;
    if (await _tryPin(meta, pin, _hw) case (_, false)) throw ArgumentError('the duress PIN must differ from your PIN');
    meta['salt2'] = b64(randomBytes(16));
    await _writeSlot(dir, meta, pin, concat([_stateKey, Uint8List(64)]), _hw, second: true);
    await _saveMeta(dir, meta);
    _privateMeta['duress'] = true;
    await _savePrivateFile();
  }

  Future<void> clearDuressPin() async {
    _requireReal();
    final meta = jsonDecode(await _meta(dir).readAsString()) as Map<String, dynamic>;
    meta['salt2'] = b64(randomBytes(16));
    await _writeRandomSlot(meta, _hw);
    await _saveMeta(dir, meta);
    _privateMeta['duress'] = false;
    await _savePrivateFile();
  }

  /// Whether a duress PIN is set (known to the real session only).
  bool get duressPinSet => !duress && _privateMeta['duress'] == true;

  // --- State -----------------------------------------------------------

  Future<Map<String, dynamic>?> load() async {
    final f = _state(dir);
    if (!await f.exists()) return null;
    final b = await f.readAsBytes();
    final plain = await Crypto.open(_stateKey, b.sublist(0, 12), b.sublist(12), aad: utf8.encode('zelt-state'));
    return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
  }

  Future<void> save(Map<String, dynamic> state) async {
    final nonce = randomBytes(12);
    final ct = await Crypto.seal(_stateKey, nonce, utf8.encode(jsonEncode(state)), aad: utf8.encode('zelt-state'));
    await _atomicWrite(_state(dir), concat([nonce, ct]));
  }

  // --- Private section -------------------------------------------------

  Map<String, dynamic> _privateMeta = {};
  Map<String, dynamic> _privateState = {};
  final Set<String> _consumed = {};

  static const _padStep = 64 * 1024;

  /// The private section plus everything added since by any session
  /// ([addPrivate]), oldest first. Real session only.
  Future<List<Map<String, dynamic>>> loadPrivate() async {
    _requireReal();
    final parts = <Map<String, dynamic>>[];
    final f = _private(dir);
    if (await f.exists()) {
      final b = await f.readAsBytes();
      final padded = await Crypto.open(_privateKey!, b.sublist(0, 12), b.sublist(12), aad: utf8.encode('zelt-private'));
      final n = ByteData.sublistView(padded).getUint32(0);
      final j = jsonDecode(utf8.decode(padded.sublist(4, 4 + n))) as Map<String, dynamic>;
      _privateMeta = Map<String, dynamic>.of(j['meta'] as Map<String, dynamic>? ?? {});
      _privateState = j['state'] as Map<String, dynamic>? ?? {};
      parts.add(_privateState);
    }
    final pd = _pendingDir(dir);
    if (await pd.exists()) {
      final files = await pd.list().where((e) => e is File).cast<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        final b = await file.readAsBytes();
        if (b.length < 32 + 12 + 16) continue;
        try {
          final key = await _pendingKeyFor(await Crypto.x25519(_pendingKey!, b.sublist(0, 32)), b.sublist(0, 32), _pendingKey.pub);
          final plain = await Crypto.open(key, b.sublist(32, 44), b.sublist(44), aad: utf8.encode('zelt-pending'));
          parts.add(jsonDecode(utf8.decode(plain)) as Map<String, dynamic>);
          _consumed.add(file.path);
        } catch (_) {
          // Not ours, or damaged: leave it.
        }
      }
    }
    return parts;
  }

  /// Replaces the private section (padded, so its size says little), then
  /// drops the additions it now contains. Real session only.
  Future<void> savePrivate(Map<String, dynamic> state) async {
    _requireReal();
    _privateState = state;
    await _savePrivateFile();
    for (final path in _consumed) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    _consumed.clear();
  }

  Future<void> _savePrivateFile() async {
    final json = utf8.encode(jsonEncode({'meta': _privateMeta, 'state': _privateState}));
    var size = _padStep;
    while (size < json.length + 4) {
      size *= 2;
    }
    final padded = Uint8List(size);
    ByteData.sublistView(padded).setUint32(0, json.length);
    padded.setRange(4, 4 + json.length, json);
    final nonce = randomBytes(12);
    await _atomicWrite(
      _private(dir),
      concat([nonce, await Crypto.seal(_privateKey!, nonce, padded, aad: utf8.encode('zelt-private'))]),
    );
  }

  /// The private part of the last backup a real session made (sealed to
  /// the backup phrase, unreadable here): a duress session puts it in its
  /// backups unchanged.
  Future<void> writeBackupPrivate(Uint8List sealed) => _atomicWrite(File('${dir.path}/backup-private.bin'), sealed);

  Future<Uint8List?> readBackupPrivate() async {
    final f = File('${dir.path}/backup-private.bin');
    return await f.exists() ? f.readAsBytes() : null;
  }

  /// Adds to the private section from any session (also the duress one,
  /// which cannot read it): sealed to the private section's public key, and
  /// merged by the next real session. [replace]: the name an earlier call
  /// returned, to overwrite that addition. Returns the name.
  Future<String> addPrivate(Map<String, dynamic> part, {String? replace}) async {
    final meta = jsonDecode(await _meta(dir).readAsString()) as Map<String, dynamic>;
    final apk = unb64(meta['apk']);
    final eph = await Crypto.x25519Generate();
    final key = await _pendingKeyFor(await Crypto.x25519(eph, apk), eph.pub, apk);
    final nonce = randomBytes(12);
    final ct = await Crypto.seal(key, nonce, utf8.encode(jsonEncode(part)), aad: utf8.encode('zelt-pending'));
    final pd = _pendingDir(dir);
    await pd.create(recursive: true);
    final name = replace ?? '${DateTime.now().microsecondsSinceEpoch.toString().padLeft(20, '0')}-${hex(randomBytes(4))}';
    if (name.contains('/') || name.contains('.')) throw ArgumentError('bad name');
    await _atomicWrite(File('${pd.path}/$name'), concat([eph.pub, nonce, ct]));
    return name;
  }

  static Future<Uint8List> _pendingKeyFor(Uint8List shared, Uint8List ephPub, Uint8List pub) =>
      Crypto.hkdf(shared, salt: concat([ephPub, pub]), info: 'zelt/vault/pending');

  // --- Media blobs ----------------------------------------------------

  Uint8List? _mediaNameKey;
  Uint8List? _mediaEncKey;

  Future<(Uint8List, Uint8List)> _mediaKeys() async {
    _mediaNameKey ??= await Crypto.hkdf(_stateKey, info: 'zelt/media/name/v1');
    _mediaEncKey ??= await Crypto.hkdf(_stateKey, info: 'zelt/media/enc/v1');
    return (_mediaNameKey!, _mediaEncKey!);
  }

  /// File for a blob. The name is a keyed hash, so the files do not reveal
  /// which (known) media this device holds.
  Future<File> _blobFile(String name) async {
    final (nk, _) = await _mediaKeys();
    final fn = hex(await Crypto.hmac(nk, utf8.encode(name))).substring(0, 40);
    return File('${dir.path}/media/$fn');
  }

  Future<void> writeBlob(String name, Uint8List data) async {
    final (_, ek) = await _mediaKeys();
    final f = await _blobFile(name);
    await f.parent.create(recursive: true);
    final nonce = randomBytes(12);
    await _atomicWrite(f, concat([nonce, await Crypto.seal(ek, nonce, data, aad: utf8.encode(name))]));
  }

  Future<Uint8List?> readBlob(String name) async {
    final f = await _blobFile(name);
    if (!await f.exists()) return null;
    final b = await f.readAsBytes();
    if (b.length < 28) return null;
    final (_, ek) = await _mediaKeys();
    try {
      return await Crypto.open(ek, b.sublist(0, 12), b.sublist(12), aad: utf8.encode(name));
    } catch (_) {
      return null;
    }
  }

  Future<bool> hasBlob(String name) async => (await _blobFile(name)).exists();

  /// Deletes everything, irreversibly.
  static Future<void> wipe(Directory d) async {
    if (await d.exists()) await d.delete(recursive: true);
  }

  static Future<void> _atomicWrite(File f, List<int> bytes) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  }
}
