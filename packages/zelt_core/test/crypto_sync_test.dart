import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/crypto.dart';
import 'package:zelt_core/lioness.dart';

void main() {
  group('HKDF (RFC 5869)', () {
    test('test case 1', () {
      final okm = CryptoSync.hkdfBytes(
        List.filled(22, 0x0b),
        salt: unhex('000102030405060708090a0b0c'),
        info: unhex('f0f1f2f3f4f5f6f7f8f9'),
        length: 42,
      );
      expect(hex(okm), '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865');
    });
    test('test case 3 (empty salt and info)', () {
      final okm = CryptoSync.hkdfBytes(List.filled(22, 0x0b), length: 42);
      expect(hex(okm), '8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8');
    });
    test('matches the library HKDF', () async {
      final ikm = randomBytes(32);
      final salt = randomBytes(32);
      expect(CryptoSync.hkdf(ikm, salt: salt, info: 'x', length: 208),
          await Crypto.hkdf(ikm, salt: salt, info: 'x', length: 208));
    });
  });

  test('sync primitives equal the async ones', () async {
    final a = await Crypto.x25519Generate();
    final b = await Crypto.x25519Generate();
    expect(CryptoSync.x25519(a, b.pub), await Crypto.x25519(a, b.pub));
    final k = randomBytes(32);
    final d = randomBytes(1000);
    expect(CryptoSync.hmac(k, d), await Crypto.hmac(k, d));
    expect(CryptoSync.sha256(d), await Crypto.sha256(d));
    expect(CryptoSync.keystream(k, 777), await Crypto.keystream(k, 777));
    final n = randomBytes(12);
    final sealed = CryptoSync.seal(k, n, d, aad: [1, 2]);
    expect(sealed, await Crypto.seal(k, n, d, aad: [1, 2]));
    expect(await Crypto.open(k, n, sealed, aad: [1, 2]), d);
    expect(() => CryptoSync.open(k, n, Uint8List.fromList(sealed)..[3] ^= 1, aad: [1, 2]), throwsA(anything));
  });

  test('keyed BLAKE2b matches the official BLAKE2 known-answer test', () {
    // blake2b-kat.txt, first keyed entry: key = 00..3f, input empty.
    final key = Uint8List.fromList(List.generate(64, (i) => i));
    expect(
      hex(CryptoSync.blake2bMac(key, const [], length: 64)),
      '10ebb67700b1868efb4417987acf4690ae9d972fb7a590c2f02871799aaa4786'
      'b5e996e8f0f4eb981fc214b005f42d2ff4233499391653df7aefcbc13fc51568',
    );
  });

  test('sync key generation gives the same public key as the library', () async {
    final kp = KeyPair25519.generateSync();
    expect(kp.pub, (await Crypto.x25519FromPrivate(kp.priv)).pub);
  });

  group('LIONESS', () {
    test('round trip', () {
      final keys = randomBytes(Lioness.keyBytes);
      final plain = randomBytes(7304);
      final b = Uint8List.fromList(plain);
      Lioness.encrypt(keys, b);
      expect(b, isNot(plain));
      Lioness.decrypt(keys, b);
      expect(b, plain);
    });

    test('one flipped bit scrambles the whole block (no tagging)', () {
      final keys = randomBytes(Lioness.keyBytes);
      final plain = randomBytes(7304);
      final b = Uint8List.fromList(plain);
      Lioness.encrypt(keys, b);
      b[5000] ^= 0x01; // a relay tampers with one bit
      Lioness.decrypt(keys, b);
      var same = 0;
      for (var i = 0; i < plain.length; i++) {
        if (b[i] == plain[i]) same++;
      }
      // Random bytes match by chance ~1/256 of the time.
      expect(same, lessThan(plain.length ~/ 100));
      expect(b.sublist(0, 32), isNot(plain.sublist(0, 32)));
    });
  });
}
