// NIST ACVP known-answer tests for ML-KEM-768 (FIPS 203), exercising the
// exact package:pqcrypto entry points zelt uses (via Crypto.kem*).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pqcrypto/pqcrypto.dart';
import 'package:test/test.dart';
import 'package:zelt_core/bytes.dart';

void main() {
  final v = jsonDecode(File('test/vectors/mlkem768_acvp.json').readAsStringSync()) as Map<String, dynamic>;
  final kem = PqcKem.kyber768;
  Uint8List h(Object? s) => unhex(s as String);

  test('key generation from (d, z)', () {
    for (final t in v['keyGen'] as List) {
      final (ek, dk) = kem.generateKeyPair(Uint8List.fromList([...h(t['d']), ...h(t['z'])]));
      expect(hex(ek), (t['ek'] as String).toLowerCase(), reason: 'tcId ${t['tcId']} ek');
      expect(hex(dk), (t['dk'] as String).toLowerCase(), reason: 'tcId ${t['tcId']} dk');
    }
  });

  test('encapsulation with fixed m', () {
    for (final t in v['encap'] as List) {
      final (c, k) = kem.encapsulate(h(t['ek']), h(t['m']));
      expect(hex(c), (t['c'] as String).toLowerCase(), reason: 'tcId ${t['tcId']} c');
      expect(hex(k), (t['k'] as String).toLowerCase(), reason: 'tcId ${t['tcId']} k');
    }
  });

  test('decapsulation, including implicit rejection of bad ciphertexts', () {
    for (final t in v['decap'] as List) {
      expect(hex(kem.decapsulate(h(t['dk']), h(t['c']))), (t['k'] as String).toLowerCase(),
          reason: 'tcId ${t['tcId']}');
    }
  });

  test('encapsulation key check rejects invalid keys', () {
    for (final t in v['ekCheck'] as List) {
      final ek = h(t['ek']);
      if (t['valid'] == true) {
        expect(() => kem.encapsulate(ek), returnsNormally, reason: 'tcId ${t['tcId']}');
      } else {
        expect(() => kem.encapsulate(ek), throwsA(anything), reason: 'tcId ${t['tcId']}');
      }
    }
  });

  test('decapsulation key check rejects invalid keys', () {
    final someCt = h((v['decap'] as List).first['c']);
    for (final t in v['dkCheck'] as List) {
      final dk = h(t['dk']);
      if (t['valid'] == true) {
        expect(() => kem.decapsulate(dk, someCt), returnsNormally, reason: 'tcId ${t['tcId']}');
      } else {
        expect(() => kem.decapsulate(dk, someCt), throwsA(anything), reason: 'tcId ${t['tcId']}');
      }
    }
  });
}
