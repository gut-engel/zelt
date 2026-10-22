import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:zelt_core/bytes.dart';

void main() {
  final d = randomBytes(7304);
  final k = randomBytes(32);
  const b2 = DartBlake2b(hashLengthInBytes: 32);
  for (var i = 0; i < 100; i++) {
    b2.calculateMacSync(d, secretKeyData: SecretKeyData(k), nonce: const []);
  }
  final sw = Stopwatch()..start();
  for (var i = 0; i < 2000; i++) {
    b2.calculateMacSync(d, secretKeyData: SecretKeyData(k), nonce: const []);
  }
  stdout.writeln('keyed blake2b-256 7.3KB: ${(sw.elapsedMicroseconds / 2000).toStringAsFixed(1)} us');
  exit(0);
}
