import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'bytes.dart';
import 'crypto.dart';
import 'phrase.dart';

/// Encrypted backups.
///
/// A backup is one manifest plus one blob per picture, in a backup target
/// (a folder on a server, a bucket, or one file: see backup_targets.dart).
///
/// - **Manifest** (`zelt-backup`): the state, compressed (zstd or bzip2,
///   whichever is smaller), sealed to the backup phrase's X25519 key with a
///   fresh ephemeral key: the device can write backups but not read them.
///   It holds no message keys (see Messenger.backupJson).
/// - **Private chats** go in a part sealed the same way, padded, inside the
///   manifest. A session opened with the duress PIN cannot read it, so it
///   puts in the part the last real session made, unchanged.
/// - **Pictures** (`zelt-media/<name>`): one blob each, uploaded once and
///   kept while referenced. Name and key come from the hash via a key from
///   the phrase, so a blob reveals nothing, and an unchanged picture is never
///   uploaded twice: daily backups only send the manifest and new pictures.
class Backup {
  Backup._();

  static const manifestName = 'zelt-backup';
  static const mediaPrefix = 'zelt-media/';
  static final _magic = utf8.encode('ZELTBK1\n');
  static final _privateMagic = utf8.encode('ZELTBP1\n');

  /// Seals the private part: the private state and the hashes of its media.
  static Future<Uint8List> sealPrivate(BackupKeys keys, Map<String, dynamic> state, Iterable<String> media) async {
    final packed = compress(utf8.encode(jsonEncode({'state': state, 'media': media.toList()})));
    // Padded to a power of two (at least 4 KiB): its size says little.
    var size = 4096;
    while (size < packed.length + 4) {
      size *= 2;
    }
    final padded = Uint8List(size);
    ByteData.sublistView(padded).setUint32(0, packed.length);
    padded.setRange(4, 4 + packed.length, packed);
    return _seal(keys.publicKey, padded, _privateMagic, 'zelt/backup/private/v1');
  }

  static Future<(Map<String, dynamic>, List<String>)> openPrivate(BackupKeys keys, Uint8List sealed) async {
    final padded = await _open(keys, sealed, _privateMagic, 'zelt/backup/private/v1');
    final n = ByteData.sublistView(padded).getUint32(0);
    final j = jsonDecode(utf8.decode(decompress(padded.sublist(4, 4 + n)))) as Map<String, dynamic>;
    return (j['state'] as Map<String, dynamic>, (j['media'] as List).cast<String>());
  }

  /// The manifest: [state] (the public part), its media hashes, and the
  /// sealed private part.
  static Future<Uint8List> sealManifest(
    BackupKeys keys, {
    required Map<String, dynamic> state,
    required Iterable<String> media,
    required Uint8List? privatePart,
  }) async {
    final body = compress(utf8.encode(jsonEncode({
      'v': 1,
      'created': DateTime.now().millisecondsSinceEpoch,
      'state': state,
      'media': media.toList(),
    })));
    final w = ByteWriter();
    final p = privatePart ?? Uint8List(0);
    w.u32(p.length);
    w.bytes(p);
    w.bytes(body);
    return _seal(keys.publicKey, w.toBytes(), _magic, 'zelt/backup/manifest/v1');
  }

  /// Throws [BackupError] if the phrase does not fit this backup.
  static Future<OpenedManifest> openManifest(BackupKeys keys, Uint8List sealed) async {
    final plain = await _open(keys, sealed, _magic, 'zelt/backup/manifest/v1');
    final r = ByteReader(plain);
    final n = r.u32();
    final privatePart = r.bytes(n);
    final j = jsonDecode(utf8.decode(decompress(r.bytes(r.remaining)))) as Map<String, dynamic>;
    return OpenedManifest(
      state: j['state'] as Map<String, dynamic>,
      media: (j['media'] as List).cast<String>(),
      created: DateTime.fromMillisecondsSinceEpoch(j['created'] as int),
      privatePart: n == 0 ? null : privatePart,
    );
  }

  static Future<Uint8List> _seal(Uint8List pub, Uint8List plain, List<int> magic, String info) async {
    final eph = await Crypto.x25519Generate();
    final key = await Crypto.hkdf(await Crypto.x25519(eph, pub), salt: concat([eph.pub, pub]), info: info);
    final nonce = randomBytes(12);
    return concat([magic, eph.pub, nonce, await Crypto.seal(key, nonce, plain, aad: magic)]);
  }

  static Future<Uint8List> _open(BackupKeys keys, Uint8List sealed, List<int> magic, String info) async {
    if (!keys.canRead) throw StateError('reading a backup needs the phrase');
    if (sealed.length < magic.length + 32 + 12 + 16 || !bytesEqual(sealed.sublist(0, magic.length), magic)) {
      throw const BackupError('this is not a zelt backup');
    }
    final o = magic.length;
    final ephPub = sealed.sublist(o, o + 32);
    final key = await Crypto.hkdf(
      await Crypto.x25519(keys.keyPair!, ephPub),
      salt: concat([ephPub, keys.publicKey]),
      info: info,
    );
    try {
      return await Crypto.open(key, sealed.sublist(o + 32, o + 44), sealed.sublist(o + 44), aad: magic);
    } catch (_) {
      throw const BackupError('this backup was made with a different backup phrase');
    }
  }

  // --- Media blobs ------------------------------------------------------

  /// The blob name of a picture (a keyed hash: reveals nothing).
  static String blobName(BackupKeys keys, String hash) =>
      mediaPrefix + hex(CryptoSync.hmac(keys.nameKey, concat([utf8.encode('name'), unhex(hash)]))).substring(0, 40);

  static Uint8List _blobKey(BackupKeys keys, String hash) =>
      CryptoSync.hmac(keys.nameKey, concat([utf8.encode('key'), unhex(hash)]));

  static Future<Uint8List> sealBlob(BackupKeys keys, String hash, Uint8List bytes) async {
    final nonce = randomBytes(12);
    return concat([nonce, await Crypto.seal(_blobKey(keys, hash), nonce, bytes, aad: unhex(hash))]);
  }

  /// The picture, checked against its hash; null if damaged or not it.
  static Future<Uint8List?> openBlob(BackupKeys keys, String hash, Uint8List blob) async {
    if (blob.length < 28) return null;
    try {
      final bytes = await Crypto.open(_blobKey(keys, hash), blob.sublist(0, 12), blob.sublist(12), aad: unhex(hash));
      return bytesEqual(await Crypto.sha256(bytes), unhex(hash)) ? bytes : null;
    } catch (_) {
      return null;
    }
  }

  // --- Compression ------------------------------------------------------

  static const _raw = 0, _zstd = 1, _bzip2 = 2;

  /// The smallest of zstd (level 19) and bzip2, or the data itself.
  static Uint8List compress(List<int> data) {
    final candidates = <(int, List<int>)>[
      (_raw, data),
      (_zstd, ZstdEncoder().encodeBytes(data, level: 19)),
      (_bzip2, BZip2Encoder().encodeBytes(data)),
    ];
    candidates.sort((a, b) => a.$2.length - b.$2.length);
    final (kind, out) = candidates.first;
    return Uint8List.fromList([kind, ...out]);
  }

  static Uint8List decompress(Uint8List packed) {
    if (packed.isEmpty) throw const BackupError('empty backup data');
    final body = packed.sublist(1);
    return switch (packed[0]) {
      _raw => body,
      _zstd => Uint8List.fromList(ZstdDecoder().decodeBytes(body)),
      _bzip2 => Uint8List.fromList(BZip2Decoder().decodeBytes(body)),
      _ => throw const BackupError('unknown compression'),
    };
  }
}

class OpenedManifest {
  final Map<String, dynamic> state;
  final List<String> media;
  final DateTime created;
  final Uint8List? privatePart;
  OpenedManifest({required this.state, required this.media, required this.created, required this.privatePart});
}

class BackupError implements Exception {
  final String message;
  const BackupError(this.message);
  @override
  String toString() => message;
}
