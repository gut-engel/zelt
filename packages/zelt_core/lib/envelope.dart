import 'dart:typed_data';

import 'bytes.dart';
import 'constants.dart';
import 'crypto.dart';

/// Mailbox IDs, blob envelopes and delete keys.
///
/// A blob is nonce(12) || AEAD(envKey, kind || len || content || pad), always
/// [blobSize] bytes. The envelope hides the Double Ratchet header from relays
/// so its keys cannot link messages.
class Envelope {
  Envelope._();

  static const kindHandshake = 0;
  static const kindRatchet = 1;
  static const maxContent = blobSize - 12 - 16 - 3;

  static Future<Uint8List> mailboxId(Uint8List key, int epoch) async {
    final w = ByteWriter()
      ..str('mb')
      ..u32(epoch);
    return (await Crypto.hmac(key, w.toBytes())).sublist(0, 16);
  }

  /// Mailbox IDs a recipient polls: the next epoch (a sender whose clock runs
  /// ahead), the current one and the look-back that covers the TTL.
  static Future<List<Uint8List>> pollIds(Uint8List key, DateTime now) async {
    final e = mailboxEpochOf(now);
    return [for (var i = -1; i <= mailboxLookback; i++) await mailboxId(key, e - i)];
  }

  /// Mailbox IDs polled per contact.
  static const idsPerContact = mailboxLookback + 2;

  static Future<Uint8List> seal(Uint8List envKey, int kind, Uint8List content) async {
    if (content.length > maxContent) throw ArgumentError('content too large');
    final plain = (ByteWriter()
          ..u8(kind)
          ..varBytes(content))
        .toPadded(blobSize - 12 - 16);
    final nonce = randomBytes(12);
    return concat([nonce, await Crypto.seal(envKey, nonce, plain)]);
  }

  /// Returns (kind, content) or null if the blob is not for this key.
  static Future<(int, Uint8List)?> open(Uint8List envKey, Uint8List blob) async {
    if (blob.length != blobSize) return null;
    try {
      final plain = await Crypto.open(envKey, blob.sublist(0, 12), blob.sublist(12));
      final r = ByteReader(plain);
      return (r.u8(), r.varBytes());
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List> deleteKey(Uint8List delKey, Uint8List blobHash) =>
      Crypto.hmac(delKey, blobHash);

  static Future<Uint8List> deleteTag(Uint8List deleteKey) => Crypto.sha256(deleteKey);
}
