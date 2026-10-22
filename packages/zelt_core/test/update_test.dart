import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/crypto.dart';
import 'package:zelt_core/update.dart';

void main() {
  late String seed, pub;
  late Uint8List apk;
  late UpdateManifest m;
  late List<int> bytes;
  late String sig;

  setUp(() async {
    (seed, pub) = await UpdateSigner.generate();
    apk = randomBytes(5000);
    m = UpdateManifest(version: '1.0.1', build: 2, assets: {
      'android-arm64': UpdateAsset(file: 'zelt-1.0.1-android-arm64.apk', sha256: hex(await Crypto.sha256(apk)), size: apk.length),
    });
    bytes = utf8.encode(m.encode());
    sig = await UpdateSigner.sign(seed, bytes);
  });

  test('valid manifest and file verify', () async {
    final v = await UpdateManifest.verify(bytes, sig, pub);
    expect(v.build, 2);
    await UpdateManifest.checkFile(v.assets['android-arm64']!, apk);
  });

  test('tampered manifest is rejected', () async {
    final evil = utf8.encode(m.encode().replaceFirst('"build": 2', '"build": 99'));
    await expectLater(UpdateManifest.verify(evil, sig, pub), throwsA(isA<UpdateRejected>()));
  });

  test('signature from another key is rejected', () async {
    final (otherSeed, _) = await UpdateSigner.generate();
    final forged = await UpdateSigner.sign(otherSeed, bytes);
    await expectLater(UpdateManifest.verify(bytes, forged, pub), throwsA(isA<UpdateRejected>()));
  });

  test('modified or truncated download is rejected', () async {
    final a = m.assets['android-arm64']!;
    await expectLater(UpdateManifest.checkFile(a, Uint8List.fromList(apk)..[100] ^= 1), throwsA(isA<UpdateRejected>()));
    await expectLater(UpdateManifest.checkFile(a, apk.sublist(1)), throwsA(isA<UpdateRejected>()));
  });

  test('asset names cannot be paths', () {
    expect(() => UpdateAsset.fromJson({'file': '../evil', 'sha256': '', 'size': 1}), throwsFormatException);
    expect(() => UpdateAsset.fromJson({'file': 'a/b.apk', 'sha256': '', 'size': 1}), throwsFormatException);
  });
}
