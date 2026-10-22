// Release signing tool (maintainer only).
//
//   zelt_sign keygen <keyfile>                  new Ed25519 key, prints public key
//   zelt_sign pubkey <keyfile>                  print the public key
//   zelt_sign manifest <keyfile> <dir> <version> <build> [notes]
//       hashes every release file in <dir>, writes zelt-update.json and signs it
//   zelt_sign verify <pubkey> <dir>             check the manifest and all files
//
// The key file never belongs in a repository; the Makefile keeps it in
// ~/.config/zelt-signing/ with mode 600.
import 'dart:convert';
import 'dart:io';

import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/crypto.dart';
import 'package:zelt_core/update.dart';

/// Release file name -> manifest asset key.
String? assetKey(String name) {
  final m = RegExp(r'^zelt-[0-9][^-]*-(android-arm64|android-armv7|android-x64|linux-x64|windows-x64)\.(apk|tar\.gz|zip)$')
      .firstMatch(name);
  return m?.group(1);
}

Future<void> main(List<String> a) async {
  if (a.isEmpty) _usage();
  switch (a[0]) {
    case 'keygen':
      if (a.length != 2) _usage();
      final f = File(a[1]);
      if (f.existsSync()) _die('${a[1]} already exists; refusing to overwrite');
      final (seed, pub) = await UpdateSigner.generate();
      f.parent.createSync(recursive: true);
      f.writeAsStringSync('$seed\n');
      await Process.run('chmod', ['600', f.path]);
      stdout.writeln(pub);
    case 'pubkey':
      if (a.length != 2) _usage();
      stdout.writeln(await UpdateSigner.publicKeyOf(File(a[1]).readAsStringSync().trim()));
    case 'manifest':
      if (a.length < 5) _usage();
      final seed = File(a[1]).readAsStringSync().trim();
      final dir = Directory(a[2]);
      final assets = <String, UpdateAsset>{};
      for (final f in dir.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        final key = assetKey(name);
        if (key == null) continue;
        final bytes = f.readAsBytesSync();
        assets[key] = UpdateAsset(file: name, sha256: hex(await Crypto.sha256(bytes)), size: bytes.length);
        stdout.writeln('  $key: $name');
      }
      if (assets.isEmpty) _die('no release files in ${dir.path}');
      final m = UpdateManifest(
        version: a[3],
        build: int.parse(a[4]),
        notes: a.length > 5 ? a[5] : '',
        assets: assets,
      );
      final text = utf8.encode(m.encode());
      File('${dir.path}/${UpdateManifest.file}').writeAsBytesSync(text);
      File('${dir.path}/${UpdateManifest.sigFile}').writeAsStringSync('${await UpdateSigner.sign(seed, text)}\n');
      stdout.writeln('signed ${UpdateManifest.file} (${assets.length} assets)');
    case 'verify':
      if (a.length != 3) _usage();
      final dir = a[2];
      final bytes = File('$dir/${UpdateManifest.file}').readAsBytesSync();
      final m = await UpdateManifest.verify(bytes, File('$dir/${UpdateManifest.sigFile}').readAsStringSync(), a[1]);
      for (final e in m.assets.values) {
        await UpdateManifest.checkFile(e, File('$dir/${e.file}').readAsBytesSync());
      }
      stdout.writeln('OK: ${m.version} (build ${m.build}), ${m.assets.length} assets verified');
    default:
      _usage();
  }
}

Never _usage() {
  stderr.writeln('usage: zelt_sign keygen|pubkey|manifest|verify ... (see source)');
  exit(64);
}

Never _die(String m) {
  stderr.writeln('error: $m');
  exit(1);
}
