import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:pqcrypto/pqcrypto.dart';

import 'bytes.dart';
import 'worker.dart';

/// Thin facade over audited primitives from `package:cryptography` and
/// `package:pqcrypto`. No primitive is implemented here.
class Crypto {
  Crypto._();

  static const _x25519 = DartX25519();
  static final _aead = Chacha20.poly1305Aead();
  static final _stream = Chacha20(macAlgorithm: MacAlgorithm.empty);
  static final _hmac = Hmac.sha256();
  static final _sha256 = Sha256();
  static final _zeroNonce = Uint8List(12);

  // --- X25519 ----------------------------------------------------------

  static Future<KeyPair25519> x25519Generate() =>
      x25519FromPrivate(randomBytes(32));

  static Future<KeyPair25519> x25519FromPrivate(List<int> priv) async {
    final kp = await _x25519.newKeyPairFromSeed(priv);
    final pub = await kp.extractPublicKey();
    return KeyPair25519(Uint8List.fromList(priv), Uint8List.fromList(pub.bytes));
  }

  static Future<Uint8List> x25519(KeyPair25519 mine, List<int> theirPub) async {
    if (theirPub.length != 32) throw const FormatException('bad x25519 key');
    final kp = SimpleKeyPairData(
      mine.priv,
      publicKey: SimplePublicKey(mine.pub, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );
    final s = await _x25519.sharedSecretKey(
      keyPair: kp,
      remotePublicKey: SimplePublicKey(theirPub, type: KeyPairType.x25519),
    );
    final out = Uint8List.fromList(await s.extractBytes());
    if (out.every((b) => b == 0)) {
      throw const FormatException('low-order x25519 point');
    }
    return out;
  }

  // --- Hashes and KDFs -------------------------------------------------

  static Future<Uint8List> sha256(List<int> data) async =>
      Uint8List.fromList((await _sha256.hash(data)).bytes);

  static Uint8List sha256Sync(List<int> data) =>
      Uint8List.fromList(const DartSha256().hashSync(data).bytes);

  static Future<Uint8List> hmac(List<int> key, List<int> data) async {
    final mac = await _hmac.calculateMac(data, secretKey: SecretKey(key));
    return Uint8List.fromList(mac.bytes);
  }

  static Future<Uint8List> hkdf(
    List<int> ikm, {
    List<int> salt = const [],
    required String info,
    int length = 32,
  }) async {
    final h = Hkdf(hmac: _hmac, outputLength: length);
    final k = await h.deriveKey(
      secretKey: SecretKey(ikm),
      nonce: salt,
      info: utf8.encode(info),
    );
    return Uint8List.fromList(await k.extractBytes());
  }

  /// Runs on the crypto worker: it takes seconds on a phone.
  static Future<Uint8List> argon2id(
    String password,
    List<int> salt, {
    int memoryKib = 19 * 1024,
    int iterations = 2,
  }) => Worker.run(() => _argon2id(password, salt, memoryKib, iterations));

  static Future<Uint8List> _argon2id(
    String password,
    List<int> salt,
    int memoryKib,
    int iterations,
  ) async {
    final a = Argon2id(
      parallelism: 1,
      memory: memoryKib,
      iterations: iterations,
      hashLength: 32,
    );
    final k = await a.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    return Uint8List.fromList(await k.extractBytes());
  }

  // --- Ciphers ---------------------------------------------------------

  /// ChaCha20 keystream of [length] bytes. Keys passed here are single-use,
  /// so a zero nonce is safe.
  static Future<Uint8List> keystream(List<int> key, int length) async {
    final box = await _stream.encrypt(
      Uint8List(length),
      secretKey: SecretKey(key),
      nonce: _zeroNonce,
    );
    return Uint8List.fromList(box.cipherText);
  }

  /// ChaCha20-Poly1305. Returns ciphertext || 16-byte tag.
  static Future<Uint8List> seal(
    List<int> key,
    List<int> nonce,
    List<int> plaintext, {
    List<int> aad = const [],
  }) async {
    final box = await _aead.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: aad,
    );
    return concat([box.cipherText, box.mac.bytes]);
  }

  /// Opens a [seal]ed box. Throws [SecretBoxAuthenticationError] on tamper.
  static Future<Uint8List> open(
    List<int> key,
    List<int> nonce,
    List<int> sealed, {
    List<int> aad = const [],
  }) async {
    if (sealed.length < 16) throw const FormatException('box too short');
    final ct = sealed.sublist(0, sealed.length - 16);
    final tag = sealed.sublist(sealed.length - 16);
    final out = await _aead.decrypt(
      SecretBox(ct, nonce: nonce, mac: Mac(tag)),
      secretKey: SecretKey(key),
      aad: aad,
    );
    return Uint8List.fromList(out);
  }

  // --- ML-KEM-768 -------------------------------------------------------

  static Future<KemKeyPair> kemGenerate() => Worker.run(() {
    final (pk, sk) = PqcKem.kyber768.generateKeyPair();
    return KemKeyPair(pk, sk);
  });

  /// Returns (ciphertext, sharedSecret).
  static Future<(Uint8List, Uint8List)> kemEncapsulate(Uint8List pk) =>
      Worker.run(() => PqcKem.kyber768.encapsulate(pk));

  static Future<Uint8List> kemDecapsulate(Uint8List sk, Uint8List ct) =>
      Worker.run(() => PqcKem.kyber768.decapsulate(sk, ct));
}

class KeyPair25519 {
  final Uint8List priv;
  final Uint8List pub;
  KeyPair25519(this.priv, this.pub);

  Map<String, dynamic> toJson() => {'priv': b64(priv), 'pub': b64(pub)};
  factory KeyPair25519.fromJson(Map<String, dynamic> j) =>
      KeyPair25519(unb64(j['priv']), unb64(j['pub']));
}

class KemKeyPair {
  final Uint8List pk;
  final Uint8List sk;
  KemKeyPair(this.pk, this.sk);
}
