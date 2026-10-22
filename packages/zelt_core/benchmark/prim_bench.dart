import 'dart:io';
import 'dart:typed_data';

import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/crypto.dart';

void bench(String name, void Function() f, {int n = 2000}) {
  for (var i = 0; i < 50; i++) {
    f();
  }
  final sw = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    f();
  }
  stdout.writeln('${name.padRight(28)} ${(sw.elapsedMicroseconds / n).toStringAsFixed(1)} us');
}

void main() {
  final a = KeyPair25519.generateSync();
  final b = KeyPair25519.generateSync();
  final k = randomBytes(32);
  final d = randomBytes(7304);
  final n = randomBytes(12);
  bench('x25519', () => CryptoSync.x25519(a, b.pub), n: 500);
  bench('hkdf 208B', () => CryptoSync.hkdf(k, info: 'x', length: 208));
  bench('hmac 7.3KB', () => CryptoSync.hmac(k, d));
  bench('keystream 7.3KB', () => CryptoSync.keystream(k, 7304));
  bench('xorStream 7.3KB', () => CryptoSync.xorStream(k, d));
  bench('seal 8.2KB (link)', () => CryptoSync.seal(k, n, Uint8List(8201)));
  exit(0);
}
