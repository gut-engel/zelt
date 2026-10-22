import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'bytes.dart';
import 'crypto.dart';

class WrongPin implements Exception {
  @override
  String toString() => 'Wrong PIN';
}

/// Encrypted local storage for history, keys and the unsent outbox.
///
/// A random master key encrypts the state; the master key itself is wrapped
/// with a key stretched from the PIN or passphrase by Argon2id. Relay data
/// never comes here: it lives in RAM only.
class Vault {
  final Directory dir;
  final Uint8List _master;

  static const _memKib = 64 * 1024;
  static const _iterations = 3;

  Vault._(this.dir, this._master);

  static File _meta(Directory d) => File('${d.path}/vault.json');
  static File _state(Directory d) => File('${d.path}/state.bin');

  static bool exists(Directory d) => _meta(d).existsSync();

  static Future<Uint8List> _wrapKey(String pin, Map<String, dynamic> meta) => Crypto.argon2id(
    pin,
    unb64(meta['salt']),
    memoryKib: meta['mem'],
    iterations: meta['it'],
  );

  static Future<Vault> create(Directory d, String pin) async {
    await d.create(recursive: true);
    final master = randomBytes(32);
    final meta = <String, dynamic>{
      'v': 1,
      'kdf': 'argon2id',
      'salt': b64(randomBytes(16)),
      'mem': _memKib,
      'it': _iterations,
    };
    await _writeMeta(d, meta, await _wrapKey(pin, meta), master);
    return Vault._(d, master);
  }

  static Future<void> _writeMeta(
    Directory d,
    Map<String, dynamic> meta,
    Uint8List wrapKey,
    Uint8List master,
  ) async {
    final nonce = randomBytes(12);
    meta['wrapped'] = b64(concat([nonce, await Crypto.seal(wrapKey, nonce, master, aad: utf8.encode('zelt-vault'))]));
    await _atomicWrite(_meta(d), utf8.encode(jsonEncode(meta)));
  }

  static Future<Vault> unlock(Directory d, String pin) async {
    final meta = jsonDecode(await _meta(d).readAsString()) as Map<String, dynamic>;
    final wrapKey = await _wrapKey(pin, meta);
    final w = unb64(meta['wrapped']);
    try {
      final master = await Crypto.open(wrapKey, w.sublist(0, 12), w.sublist(12), aad: utf8.encode('zelt-vault'));
      return Vault._(d, master);
    } catch (_) {
      throw WrongPin();
    }
  }

  Future<void> changePin(String newPin) async {
    final meta = jsonDecode(await _meta(dir).readAsString()) as Map<String, dynamic>;
    meta['salt'] = b64(randomBytes(16));
    meta['mem'] = _memKib;
    meta['it'] = _iterations;
    await _writeMeta(dir, meta, await _wrapKey(newPin, meta), _master);
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
