import 'dart:typed_data';

import 'bip39_words.dart';
import 'bytes.dart';
import 'crypto.dart';

/// A backup phrase: 12 words that encode 128 random bits plus a 4-bit
/// checksum (BIP39, English list). Typos are caught by the checksum, and
/// every word is identified by its first four letters.
class BackupPhrase {
  final Uint8List entropy;
  BackupPhrase._(this.entropy);

  static const words = 12;

  static BackupPhrase generate() => BackupPhrase._(randomBytes(16));

  static BackupPhrase fromEntropy(Uint8List e) {
    if (e.length != 16) throw ArgumentError('16 bytes');
    return BackupPhrase._(Uint8List.fromList(e));
  }

  /// The 12 words.
  List<String> get wordList {
    final checksum = CryptoSync.sha256(entropy)[0] >> 4;
    var bits = BigInt.zero;
    for (final b in entropy) {
      bits = (bits << 8) | BigInt.from(b);
    }
    bits = (bits << 4) | BigInt.from(checksum);
    return [
      for (var i = words - 1; i >= 0; i--) bip39English[((bits >> (11 * i)) & BigInt.from(0x7ff)).toInt()],
    ];
  }

  @override
  String toString() => wordList.join(' ');

  /// Reads a phrase typed by a person: any case, any spacing, a word may be
  /// cut after four letters. Throws [FormatException] with a sentence a
  /// person can act on.
  static BackupPhrase parse(String text) {
    final typed = text.toLowerCase().split(RegExp(r'[^a-z]+')).where((w) => w.isNotEmpty).toList();
    if (typed.length != words) {
      throw FormatException('a backup phrase has $words words, this has ${typed.length}');
    }
    var bits = BigInt.zero;
    for (var i = 0; i < typed.length; i++) {
      final w = typed[i];
      final idx = lookup(w);
      if (idx == null) throw FormatException('word ${i + 1} ("$w") is not in the word list');
      bits = (bits << 11) | BigInt.from(idx);
    }
    final checksum = (bits & BigInt.from(0xf)).toInt();
    bits >>= 4;
    final e = Uint8List(16);
    for (var i = 15; i >= 0; i--) {
      e[i] = (bits & BigInt.from(0xff)).toInt();
      bits >>= 8;
    }
    if (CryptoSync.sha256(e)[0] >> 4 != checksum) {
      throw const FormatException('the words do not fit together: check for a typo or a swapped word');
    }
    return BackupPhrase._(e);
  }

  /// Index of a word, or of the only word starting with these four or more
  /// letters.
  static int? lookup(String w) {
    final exact = bip39English.indexOf(w);
    if (exact >= 0) return exact;
    if (w.length < 4) return null;
    final matches = [for (var i = 0; i < bip39English.length; i++) if (bip39English[i].startsWith(w)) i];
    return matches.length == 1 ? matches.single : null;
  }

  /// Words starting with [prefix] (for suggestions while typing).
  static List<String> suggest(String prefix, {int max = 6}) =>
      prefix.isEmpty ? const [] : bip39English.where((w) => w.startsWith(prefix.toLowerCase())).take(max).toList();
}

/// The keys a phrase stands for. The device keeps only [publicKey] (to
/// encrypt backups) and [nameKey] (to name and encrypt media blobs, which
/// are useless without the encrypted list of what they are); reading a
/// backup takes the phrase.
class BackupKeys {
  final KeyPair25519? keyPair;
  final Uint8List publicKey;
  final Uint8List nameKey;
  BackupKeys._(this.keyPair, this.publicKey, this.nameKey);

  static Future<BackupKeys> fromPhrase(BackupPhrase p) async {
    final priv = await Crypto.hkdf(p.entropy, info: 'zelt/backup/x25519/v1');
    final kp = await Crypto.x25519FromPrivate(priv);
    final nameKey = await Crypto.hkdf(p.entropy, info: 'zelt/backup/names/v1');
    return BackupKeys._(kp, kp.pub, nameKey);
  }

  /// The device's half: can write backups, cannot read them.
  static BackupKeys writeOnly(Uint8List publicKey, Uint8List nameKey) => BackupKeys._(null, publicKey, nameKey);

  bool get canRead => keyPair != null;

  /// Short fingerprint shown in settings, to tell phrases apart.
  String get fingerprint {
    final h = hex(CryptoSync.sha256(publicKey)).toUpperCase();
    return '${h.substring(0, 4)}-${h.substring(4, 8)}';
  }
}
