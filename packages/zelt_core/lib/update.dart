import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'bytes.dart';
import 'crypto.dart';

/// A signed release manifest (`zelt-update.json` + `zelt-update.json.sig`).
///
/// The signature is Ed25519 over the exact manifest bytes, made with an offline
/// key that only the release maintainer holds. Apps embed the public key and
/// install nothing unless the signature verifies, the build number is higher
/// than their own (no downgrades) and the downloaded file matches its SHA-256.
class UpdateManifest {
  final String version;
  final int build;
  final String notes;
  final Map<String, UpdateAsset> assets;

  UpdateManifest({
    required this.version,
    required this.build,
    this.notes = '',
    required this.assets,
  });

  static const file = 'zelt-update.json';
  static const sigFile = 'zelt-update.json.sig';

  Map<String, dynamic> toJson() => {
    'app': 'zelt',
    'version': version,
    'build': build,
    'notes': notes,
    'assets': {for (final e in assets.entries) e.key: e.value.toJson()},
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  static UpdateManifest decode(String text) {
    final j = jsonDecode(text) as Map<String, dynamic>;
    if (j['app'] != 'zelt') throw const FormatException('not a zelt manifest');
    return UpdateManifest(
      version: j['version'] as String,
      build: j['build'] as int,
      notes: j['notes'] as String? ?? '',
      assets: {
        for (final e in (j['assets'] as Map<String, dynamic>).entries)
          e.key: UpdateAsset.fromJson(e.value as Map<String, dynamic>),
      },
    );
  }

  /// Verifies [signatureB64] over [manifestBytes] with [publicKeyB64] and
  /// parses the manifest. Throws [UpdateRejected] on any problem.
  static Future<UpdateManifest> verify(
    List<int> manifestBytes,
    String signatureB64,
    String publicKeyB64,
  ) async {
    final ok = await Ed25519().verify(
      manifestBytes,
      signature: Signature(
        unb64(signatureB64.trim()),
        publicKey: SimplePublicKey(unb64(publicKeyB64), type: KeyPairType.ed25519),
      ),
    );
    if (!ok) throw const UpdateRejected('bad signature');
    try {
      return decode(utf8.decode(manifestBytes));
    } on FormatException catch (e) {
      throw UpdateRejected('malformed manifest: ${e.message}');
    }
  }

  /// Checks a downloaded file against the manifest entry.
  static Future<void> checkFile(UpdateAsset asset, Uint8List bytes) async {
    if (bytes.length != asset.size) throw const UpdateRejected('size mismatch');
    if (hex(await Crypto.sha256(bytes)) != asset.sha256) {
      throw const UpdateRejected('checksum mismatch');
    }
  }
}

class UpdateAsset {
  final String file;
  final String sha256;
  final int size;
  UpdateAsset({required this.file, required this.sha256, required this.size});

  Map<String, dynamic> toJson() => {'file': file, 'sha256': sha256, 'size': size};

  factory UpdateAsset.fromJson(Map<String, dynamic> j) {
    final f = j['file'] as String;
    // A file name, never a path.
    if (f.contains('/') || f.contains('\\') || f.startsWith('.')) {
      throw const FormatException('bad asset file name');
    }
    return UpdateAsset(file: f, sha256: j['sha256'] as String, size: j['size'] as int);
  }
}

class UpdateRejected implements Exception {
  final String reason;
  const UpdateRejected(this.reason);
  @override
  String toString() => 'Update rejected: $reason';
}

/// Release signing (maintainer side).
class UpdateSigner {
  UpdateSigner._();

  /// Returns (privateSeedB64, publicKeyB64).
  static Future<(String, String)> generate() async {
    final kp = await Ed25519().newKeyPair();
    final seed = await kp.extractPrivateKeyBytes();
    final pub = await kp.extractPublicKey();
    return (b64(seed), b64(pub.bytes));
  }

  static Future<String> publicKeyOf(String seedB64) async {
    final kp = await Ed25519().newKeyPairFromSeed(unb64(seedB64));
    return b64((await kp.extractPublicKey()).bytes);
  }

  static Future<String> sign(String seedB64, List<int> data) async {
    final kp = await Ed25519().newKeyPairFromSeed(unb64(seedB64));
    final sig = await Ed25519().sign(data, keyPair: kp);
    return b64(sig.bytes);
  }
}
