import 'dart:typed_data';

import 'address.dart';
import 'bytes.dart';
import 'crypto.dart';
import 'tokens.dart';

/// What one phone shows as a QR code during in-person pairing.
///
/// Carries the long-term identity key, a fresh ephemeral key, a fresh seed
/// secret, the owner's relay addresses, one token credential for the owner's
/// own relay (if it runs one) and up to two mailbox grants on other relays.
/// The seeds never touch the network, so the root key stays secret even if
/// all traffic is recorded and X25519 is later broken.
class PairingCode {
  static const prefix = 'zelt:1:';

  final Uint8List idPub;
  final Uint8List ephPub;
  final Uint8List seed;
  final String name;
  final List<RelayInfo> relays;

  /// Credential for the owner's relay: indices [0, half) are for sending
  /// to the owner, [half, end) for the scanner's own mailbox use.
  final int? credSlot;
  final int? credEpoch;
  final Uint8List? credKey;
  final List<Credential> grants;

  PairingCode({
    required this.idPub,
    required this.ephPub,
    required this.seed,
    required this.name,
    this.relays = const [],
    this.credSlot,
    this.credEpoch,
    this.credKey,
    this.grants = const [],
  });

  String encode() {
    final w = ByteWriter()
      ..bytes(idPub)
      ..bytes(ephPub)
      ..bytes(seed)
      ..str(name)
      ..u8(relays.length);
    for (final r in relays) {
      w.bytes(r.encode());
    }
    if (credKey != null) {
      w
        ..u8(1)
        ..u16(credSlot!)
        ..u32(credEpoch!)
        ..bytes(credKey!);
    } else {
      w.u8(0);
    }
    w.u8(grants.length);
    for (final g in grants) {
      w.bytes(g.encode());
    }
    return prefix + b64(w.toBytes());
  }

  static PairingCode parse(String s) {
    final t = s.trim();
    if (!t.startsWith(prefix)) throw const FormatException('not a zelt code');
    final r = ByteReader(unb64(t.substring(prefix.length)));
    final id = r.bytes(32);
    final eph = r.bytes(32);
    final seed = r.bytes(32);
    final name = r.str();
    final relays = [
      for (var i = r.u8(); i > 0; i--) RelayInfo.decode(r.bytes(RelayInfo.encodedSize)),
    ];
    int? slot, epoch;
    Uint8List? key;
    if (r.u8() == 1) {
      slot = r.u16();
      epoch = r.u32();
      key = r.bytes(32);
    }
    final grants = [for (var i = r.u8(); i > 0; i--) Credential.decode(r)];
    return PairingCode(
      idPub: id,
      ephPub: eph,
      seed: seed,
      name: name,
      relays: relays,
      credSlot: slot,
      credEpoch: epoch,
      credKey: key,
      grants: grants,
    );
  }
}

/// Symmetric keys for one conversation, derived from the pairing.
class ConversationKeys {
  final bool initiator;
  final Uint8List rk0;
  final Uint8List mboxOut, mboxIn, envOut, envIn, delOut, delIn;
  final String safetyNumber;

  ConversationKeys({
    required this.initiator,
    required this.rk0,
    required this.mboxOut,
    required this.mboxIn,
    required this.envOut,
    required this.envIn,
    required this.delOut,
    required this.delIn,
    required this.safetyNumber,
  });

  Map<String, dynamic> toJson() => {
    'i': initiator,
    'rk0': b64(rk0),
    'mo': b64(mboxOut),
    'mi': b64(mboxIn),
    'eo': b64(envOut),
    'ei': b64(envIn),
    'do': b64(delOut),
    'di': b64(delIn),
    'sn': safetyNumber,
  };

  factory ConversationKeys.fromJson(Map<String, dynamic> j) => ConversationKeys(
    initiator: j['i'],
    rk0: unb64(j['rk0']),
    mboxOut: unb64(j['mo']),
    mboxIn: unb64(j['mi']),
    envOut: unb64(j['eo']),
    envIn: unb64(j['ei']),
    delOut: unb64(j['do']),
    delIn: unb64(j['di']),
    safetyNumber: j['sn'],
  );

  /// Derives the shared keys. The side with the lower identity key is the
  /// initiator; both sides compute identical values.
  static Future<ConversationKeys> derive({
    required KeyPair25519 myId,
    required KeyPair25519 myEph,
    required Uint8List mySeed,
    required PairingCode theirs,
  }) async {
    if (bytesEqual(myId.pub, theirs.idPub)) {
      throw const FormatException('cannot pair with yourself');
    }
    final initiator = compareBytes(myId.pub, theirs.idPub) < 0;
    final dhId = await Crypto.x25519(myId, theirs.idPub);
    final dhEph = await Crypto.x25519(myEph, theirs.ephPub);
    final dhA = await Crypto.x25519(myId, theirs.ephPub);
    final dhB = await Crypto.x25519(myEph, theirs.idPub);
    // Order the mixed DHs by role so both sides agree.
    final (iEphId, rEphId) = initiator ? (dhA, dhB) : (dhB, dhA);
    final (iId, rId) = initiator ? (myId.pub, theirs.idPub) : (theirs.idPub, myId.pub);
    final (iEph, rEph) = initiator ? (myEph.pub, theirs.ephPub) : (theirs.ephPub, myEph.pub);
    final (iSeed, rSeed) = initiator ? (mySeed, theirs.seed) : (theirs.seed, mySeed);

    final rk0 = await Crypto.hkdf(
      concat([dhId, dhEph, iEphId, rEphId, iSeed, rSeed]),
      salt: concat([iId, rId, iEph, rEph]),
      info: 'zelt/pair/v1',
    );
    Future<Uint8List> k(String label) => Crypto.hkdf(rk0, info: 'zelt/conv/$label');
    final i2r = (await k('mbox/i2r'), await k('env/i2r'), await k('del/i2r'));
    final r2i = (await k('mbox/r2i'), await k('env/r2i'), await k('del/r2i'));
    final out = initiator ? i2r : r2i;
    final inn = initiator ? r2i : i2r;
    return ConversationKeys(
      initiator: initiator,
      rk0: rk0,
      mboxOut: out.$1,
      envOut: out.$2,
      delOut: out.$3,
      mboxIn: inn.$1,
      envIn: inn.$2,
      delIn: inn.$3,
      safetyNumber: await computeSafetyNumber(myId.pub, theirs.idPub),
    );
  }
}

/// 60 digits in 12 groups, identical on both phones. Friends compare them
/// to confirm nobody swapped a QR code.
Future<String> computeSafetyNumber(Uint8List a, Uint8List b) async {
  final (lo, hi) = compareBytes(a, b) < 0 ? (a, b) : (b, a);
  var h = await Crypto.sha256(concat([lo, hi]));
  final groups = <String>[];
  while (groups.length < 12) {
    h = await Crypto.sha256(concat([h, lo, hi]));
    for (var i = 0; i + 5 <= h.length && groups.length < 12; i += 5) {
      var v = 0;
      for (var j = 0; j < 5; j++) {
        v = v * 256 + h[i + j];
      }
      groups.add((v % 100000).toString().padLeft(5, '0'));
    }
  }
  return groups.join(' ');
}

/// Mixes the ML-KEM shared secret into the pairing root (hybrid PQ).
Future<Uint8List> hybridRoot(Uint8List rk0, Uint8List kemSecret) =>
    Crypto.hkdf(kemSecret, salt: rk0, info: 'zelt/hybrid/v1');
