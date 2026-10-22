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
/// A random master key encrypts the state. vault.json (v2) holds the master
/// key wrapped twice: first with a key stretched from the PIN by Argon2id,
/// then by a non-exportable hardware key ([HardwareKeyWrapper]). A copy of the
/// vault is useless anywhere else: PIN guesses can only be tested on this
/// device. Wrong PINs cause escalating delays recorded in vault.json, so they
/// survive restarts. Without hardware (desktop) the format is v1: Argon2id
/// only, with the same delays.
class Vault {
  final Directory dir;
  final Uint8List _master;
  final HardwareKeyWrapper? _hw;

  static const _memKib = 64 * 1024;
  static const _iterations = 3;

  /// Wrong PINs allowed before delays start.
  static const freeAttempts = 4;
  static const firstDelay = Duration(seconds: 30);
  static const maxDelay = Duration(hours: 1);

  Vault._(this.dir, this._master, this._hw);

  static File _meta(Directory d) => File('${d.path}/vault.json');
  static File _state(Directory d) => File('${d.path}/state.bin');

  static bool exists(Directory d) => _meta(d).existsSync();

  /// "v2 (strongbox)", "v2 (tee)" or "v1 (PIN only)".
  static String formatOf(Directory d) {
    final m = jsonDecode(_meta(d).readAsStringSync()) as Map<String, dynamic>;
    return m['v'] == 2 ? 'v2 (${m['hw']})' : 'v1 (PIN only)';
  }

  static Future<Uint8List> _pinKey(String pin, Map<String, dynamic> meta) => Crypto.argon2id(
    pin,
    unb64(meta['salt']),
    memoryKib: meta['mem'],
    iterations: meta['it'],
  );

  static final _aad = utf8.encode('zelt-vault');

  static Future<Vault> create(Directory d, String pin, {HardwareKeyWrapper? hardware}) async {
    await d.create(recursive: true);
    final master = randomBytes(32);
    final meta = _freshMeta();
    await _writeMeta(d, meta, pin, master, hardware);
    return Vault._(d, master, hardware);
  }

  static Map<String, dynamic> _freshMeta() => {
    'kdf': 'argon2id',
    'salt': b64(randomBytes(16)),
    'mem': _memKib,
    'it': _iterations,
    'failed': 0,
  };

  static Future<void> _writeMeta(
    Directory d,
    Map<String, dynamic> meta,
    String pin,
    Uint8List master,
    HardwareKeyWrapper? hw,
  ) async {
    final nonce = randomBytes(12);
    final pinWrapped = concat([nonce, await Crypto.seal(await _pinKey(pin, meta), nonce, master, aad: _aad)]);
    if (hw != null) {
      meta['v'] = 2;
      meta['hw'] = hw.kind;
      meta['wrapped'] = b64(await hw.wrap(pinWrapped));
    } else {
      meta['v'] = 1;
      meta.remove('hw');
      meta['wrapped'] = b64(pinWrapped);
    }
    await _saveMeta(d, meta);
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

  /// Throws [LockedOut] while delayed, [WrongPin] on a wrong PIN. A v1 vault
  /// is upgraded to v2 when [hardware] is given.
  static Future<Vault> unlock(Directory d, String pin, {HardwareKeyWrapper? hardware}) async {
    final meta = jsonDecode(await _meta(d).readAsString()) as Map<String, dynamic>;
    final lock = meta['lockUntil'];
    if (lock != null && DateTime.fromMillisecondsSinceEpoch(lock).isAfter(DateTime.now())) {
      throw LockedOut(DateTime.fromMillisecondsSinceEpoch(lock));
    }
    final v2 = meta['v'] == 2;
    if (v2 && hardware == null) {
      throw StateError('this vault is bound to the hardware key of the device that created it');
    }
    Uint8List? master;
    try {
      var w = unb64(meta['wrapped']);
      if (v2) w = await hardware!.unwrap(w);
      master = await Crypto.open(await _pinKey(pin, meta), w.sublist(0, 12), w.sublist(12), aad: _aad);
    } catch (_) {
      master = null;
    }
    if (master == null) {
      final failed = (meta['failed'] as int? ?? 0) + 1;
      meta['failed'] = failed;
      final delay = delayAfter(failed);
      if (delay > Duration.zero) {
        meta['lockUntil'] = DateTime.now().add(delay).millisecondsSinceEpoch;
      }
      await _saveMeta(d, meta);
      throw WrongPin();
    }
    meta['failed'] = 0;
    meta.remove('lockUntil');
    if (!v2 && hardware != null) {
      // Upgrade: bind the vault to this device's hardware key.
      await _writeMeta(d, meta, pin, master, hardware);
    } else {
      await _saveMeta(d, meta);
    }
    return Vault._(d, master, v2 || hardware != null ? hardware : null);
  }

  Future<void> changePin(String newPin) async {
    final meta = jsonDecode(await _meta(dir).readAsString()) as Map<String, dynamic>;
    meta.addAll(_freshMeta());
    meta.remove('lockUntil');
    await _writeMeta(dir, meta, newPin, _master, _hw);
  }

  Future<Map<String, dynamic>?> load() async {
    final f = _state(dir);
    if (!await f.exists()) return null;
    final b = await f.readAsBytes();
    final plain = await Crypto.open(_master, b.sublist(0, 12), b.sublist(12), aad: utf8.encode('zelt-state'));
    return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
  }

  Future<void> save(Map<String, dynamic> state) async {
    final nonce = randomBytes(12);
    final ct = await Crypto.seal(_master, nonce, utf8.encode(jsonEncode(state)), aad: utf8.encode('zelt-state'));
    await _atomicWrite(_state(dir), concat([nonce, ct]));
  }

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
