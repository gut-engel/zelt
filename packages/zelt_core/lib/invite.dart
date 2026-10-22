import 'dart:typed_data';

import 'bytes.dart';
import 'constants.dart';
import 'crypto.dart';
import 'pairing.dart';

/// Remote pairing by a one-time invite text (the second way to add a friend).
///
/// The inviter makes a text that carries its half of an in-person pairing
/// code plus an invite ID, an invite X25519 public key and an expiry:
///
///   zelt-invite:1:b64( inviteId(16) ‖ invitePub(32) ‖ expires(u32, unix s) ‖ PairingCode )
///
/// The friend pastes it and stores one sealed join request (its own pairing
/// code) in the inviter's mailboxes, under per-relay mailbox IDs derived from
/// the text. The join key mixes an X25519 exchange with the invite key, whose
/// private half never leaves the inviter's device, with the seed in the text:
/// reading the text later does not open a recorded join request.
///
/// The inviter accepts exactly one valid join request: the invite is deleted
/// (and the deletion saved) before the pairing completes, so any later
/// activation finds nothing. Unused invites stop working after
/// [inviteValidity]; the inviter's own clock decides.
const Duration inviteValidity = Duration(minutes: 15);

class InviteCode {
  static const prefix = 'zelt-invite:1:';

  final Uint8List inviteId;
  final Uint8List invitePub;
  final DateTime expiresAt;
  final PairingCode code;

  InviteCode({required this.inviteId, required this.invitePub, required this.expiresAt, required this.code});

  String encode() => prefix +
      b64((ByteWriter()
            ..bytes(inviteId)
            ..bytes(invitePub)
            ..u32(expiresAt.millisecondsSinceEpoch ~/ 1000)
            ..bytes(code.toBytes()))
          .toBytes());

  /// Accepts the text with any whitespace or line breaks a messenger added.
  static InviteCode parse(String s) {
    final t = s.replaceAll(RegExp(r'\s'), '');
    if (!t.startsWith(prefix)) {
      throw FormatException(t.startsWith(PairingCode.prefix) ? 'this is an in-person QR code, not an invite text' : 'not a zelt invite');
    }
    final r = ByteReader(unb64(t.substring(prefix.length)));
    final id = r.bytes(16);
    final pub = r.bytes(32);
    final exp = DateTime.fromMillisecondsSinceEpoch(r.u32() * 1000);
    final code = PairingCode.read(r);
    if (r.remaining != 0) throw const FormatException('trailing bytes');
    return InviteCode(inviteId: id, invitePub: pub, expiresAt: exp, code: code);
  }

  bool expiredAt(DateTime now) => !now.isBefore(expiresAt);
}

/// Keys both sides derive from the text: the mailbox key for join requests
/// and the delete key for their copies.
class InviteKeys {
  final Uint8List mbox;
  final Uint8List del;
  InviteKeys(this.mbox, this.del);

  static Future<InviteKeys> derive(Uint8List seed, Uint8List inviteId) async => InviteKeys(
    await Crypto.hkdf(seed, salt: inviteId, info: 'zelt/invite/mbox'),
    await Crypto.hkdf(seed, salt: inviteId, info: 'zelt/invite/del'),
  );

  /// Encryption key of one join request.
  static Future<Uint8List> joinKey(Uint8List dh, Uint8List seed, Uint8List inviteId, Uint8List joinerEphPub) =>
      Crypto.hkdf(concat([dh, seed]), salt: concat([inviteId, joinerEphPub]), info: 'zelt/invite/join/v1');
}

/// A join request blob: joinerEph(32) ‖ nonce(12) ‖ AEAD(key, len ‖ content ‖ pad),
/// always [blobSize] bytes like every other blob.
class JoinBlob {
  JoinBlob._();

  static const _head = 32 + 12;

  static Future<Uint8List> seal(Uint8List key, Uint8List ephPub, Uint8List inviteId, Uint8List content) async {
    final plain = (ByteWriter()..varBytes(content)).toPadded(blobSize - _head - 16);
    final nonce = randomBytes(12);
    return concat([ephPub, nonce, await Crypto.seal(key, nonce, plain, aad: inviteId)]);
  }

  static Uint8List? ephOf(Uint8List blob) => blob.length == blobSize ? blob.sublist(0, 32) : null;

  static Future<Uint8List?> open(Uint8List key, Uint8List inviteId, Uint8List blob) async {
    if (blob.length != blobSize) return null;
    try {
      final plain = await Crypto.open(key, blob.sublist(32, _head), blob.sublist(_head), aad: inviteId);
      return ByteReader(plain).varBytes();
    } catch (_) {
      return null;
    }
  }
}

/// Inviter side: an open invite, kept (encrypted, in the vault) until it is
/// used once or expires.
class PendingInvite {
  final Uint8List inviteId;
  final KeyPair25519 inviteKey;

  /// Can only move earlier ([Messenger.shortenInvite]).
  DateTime expiresAt;

  /// The pairing half the text carries.
  final KeyPair25519 eph;
  final Uint8List seed;
  final int slot;
  final String text;
  final InviteKeys keys;

  PendingInvite({
    required this.inviteId,
    required this.inviteKey,
    required this.expiresAt,
    required this.eph,
    required this.seed,
    required this.slot,
    required this.text,
    required this.keys,
  });

  String get id => hex(inviteId);
  bool expiredAt(DateTime now) => !now.isBefore(expiresAt);

  Map<String, dynamic> toJson() => {
    'id': b64(inviteId),
    'k': inviteKey.toJson(),
    'x': expiresAt.millisecondsSinceEpoch,
    'e': eph.toJson(),
    's': b64(seed),
    'slot': slot,
    't': text,
    'm': b64(keys.mbox),
    'd': b64(keys.del),
  };

  factory PendingInvite.fromJson(Map<String, dynamic> j) => PendingInvite(
    inviteId: unb64(j['id']),
    inviteKey: KeyPair25519.fromJson(j['k']),
    expiresAt: DateTime.fromMillisecondsSinceEpoch(j['x']),
    eph: KeyPair25519.fromJson(j['e']),
    seed: unb64(j['s']),
    slot: j['slot'],
    text: j['t'],
    keys: InviteKeys(unb64(j['m']), unb64(j['d'])),
  );
}

/// Joiner side: the join request, resent until the inviter answers or the
/// invite expires. Each copy is sealed afresh.
class PendingJoin {
  final Uint8List inviteId;
  final Uint8List key;
  final Uint8List ephPub;
  final Uint8List content;
  final DateTime expiresAt;
  final InviteKeys keys;
  DateTime? lastSent;

  PendingJoin({
    required this.inviteId,
    required this.key,
    required this.ephPub,
    required this.content,
    required this.expiresAt,
    required this.keys,
    this.lastSent,
  });

  Map<String, dynamic> toJson() => {
    'id': b64(inviteId),
    'k': b64(key),
    'e': b64(ephPub),
    'c': b64(content),
    'x': expiresAt.millisecondsSinceEpoch,
    'm': b64(keys.mbox),
    'd': b64(keys.del),
    if (lastSent != null) 'l': lastSent!.millisecondsSinceEpoch,
  };

  factory PendingJoin.fromJson(Map<String, dynamic> j) => PendingJoin(
    inviteId: unb64(j['id']),
    key: unb64(j['k']),
    ephPub: unb64(j['e']),
    content: unb64(j['c']),
    expiresAt: DateTime.fromMillisecondsSinceEpoch(j['x']),
    keys: InviteKeys(unb64(j['m']), unb64(j['d'])),
    lastSent: j['l'] == null ? null : DateTime.fromMillisecondsSinceEpoch(j['l']),
  );
}
