import 'dart:typed_data';

import 'address.dart';
import 'bytes.dart';
import 'constants.dart';
import 'crypto.dart';
import 'lioness.dart';
import 'onion.dart';
import 'worker.dart';

/// Sphinx-style onion packets.
///
/// Packet = keyId(1) | eph(32) | mac(16) | routing(R) | payload(P), always
/// [packetSize]. keyId names which of the hop's onion keys (see onion.dart)
/// the layer is encrypted to.
///
/// Each hop computes s = X25519(nodeKey, eph), checks the MAC over the
/// routing info, decrypts (routing || 0^S) with a stream keyed from s and
/// reads its own slot from the front. The slot names the next hop and holds
/// the next hop's ephemeral key and MAC, so successive headers share no bytes.
/// The payload is re-encrypted at each hop. Filler is computed by the sender
/// so the header length never shrinks.
///
/// The payload is encrypted per hop with LIONESS, a wide-block cipher, as in
/// the Sphinx paper: tampering anywhere destroys the whole payload, so relays
/// cannot tag packets. The final hop also checks a payload digest from its
/// slot, and the blob inside carries end-to-end AEAD.
///
/// Departure from textbook Sphinx: per-hop ephemeral keys are carried inside
/// the encrypted routing info instead of being derived by group-element
/// blinding.
///
/// All crypto here is synchronous and runs on the crypto worker pool.
enum SlotCmd { relay, deliver, toClient }

class Hop {
  /// Where to send the packet and the identity the link must prove.
  final RelayInfo relay;

  /// The relay's current onion key (from a verified [OnionKeyCert]).
  final Uint8List onionPk;
  final int keyId;

  /// How long this relay holds the packet before forwarding.
  final int delayMs;
  Hop(this.relay, this.onionPk, this.keyId, {this.delayMs = 0});

  factory Hop.fromCert(RelayInfo relay, OnionKeyCert cert, {int delayMs = 0}) =>
      Hop(relay, cert.onionPk, cert.keyId, delayMs: delayMs);
}

class _HopKeys {
  final Uint8List mac;
  final Uint8List header;
  final Uint8List payload;
  final Uint8List replayTag;
  _HopKeys(this.mac, this.header, this.payload, this.replayTag);

  static _HopKeys derive(Uint8List shared) {
    final k = CryptoSync.hkdf(shared, info: 'zelt/sphinx/v2', length: 32 + 32 + Lioness.keyBytes + 16);
    return _HopKeys(
      Uint8List.sublistView(k, 0, 32),
      Uint8List.sublistView(k, 32, 64),
      Uint8List.sublistView(k, 64, 64 + Lioness.keyBytes),
      Uint8List.sublistView(k, 64 + Lioness.keyBytes),
    );
  }
}

class Slot {
  final SlotCmd cmd;
  final int delayMs;
  final NodeAddr? nextAddr;
  final Uint8List nextPk;
  final Uint8List nextEph;
  final Uint8List nextMac;
  final Uint8List extra;

  Slot(
    this.cmd, {
    this.delayMs = 0,
    this.nextAddr,
    Uint8List? nextPk,
    Uint8List? nextEph,
    Uint8List? nextMac,
    Uint8List? extra,
  }) : nextPk = nextPk ?? Uint8List(32),
       nextEph = nextEph ?? Uint8List(32),
       nextMac = nextMac ?? Uint8List(16),
       extra = extra ?? Uint8List(16);

  Uint8List encode() {
    final w = ByteWriter()
      ..u8(cmd.index + 1)
      ..u32(delayMs)
      ..bytes(nextAddr?.encode() ?? Uint8List(NodeAddr.encodedSize))
      ..bytes(nextPk)
      ..bytes(nextEph)
      ..bytes(nextMac)
      ..bytes(extra);
    return w.toPadded(slotSize);
  }

  static Slot decode(Uint8List b) {
    final r = ByteReader(b);
    final c = r.u8();
    if (c < 1 || c > SlotCmd.values.length) {
      throw const FormatException('bad slot cmd');
    }
    final cmd = SlotCmd.values[c - 1];
    final delay = r.u32();
    final addrBytes = r.bytes(NodeAddr.encodedSize);
    return Slot(
      cmd,
      delayMs: delay,
      nextAddr: cmd == SlotCmd.relay ? NodeAddr.decode(addrBytes) : null,
      nextPk: r.bytes(32),
      nextEph: r.bytes(32),
      nextMac: r.bytes(16),
      extra: r.bytes(16),
    );
  }
}

/// A single-use reply block: lets a relay answer someone it cannot identify.
class Surb {
  final RelayInfo firstHop;
  final Uint8List header;
  Surb(this.firstHop, this.header);

  static const encodedSize = RelayInfo.encodedSize + headerSize;

  Uint8List encode() => concat([firstHop.encode(), header]);

  static Surb decode(List<int> b) => Surb(
    RelayInfo.decode(b.sublist(0, RelayInfo.encodedSize)),
    Uint8List.fromList(b.sublist(RelayInfo.encodedSize, encodedSize)),
  );

  /// Builds the packet a relay sends back along this SURB.
  Uint8List packetWith(Uint8List payload) {
    if (payload.length != payloadSize) throw ArgumentError('payload size');
    return concat([header, payload]);
  }
}

/// What the client keeps to decrypt a reply that arrives over a [Surb].
class SurbSecret {
  final Uint8List id;
  final List<Uint8List> payloadKeys;
  SurbSecret(this.id, this.payloadKeys);
}

/// Result of peeling one layer.
class Peeled {
  final Slot slot;

  /// Packet to forward (only for [SlotCmd.relay]).
  final Uint8List? next;

  /// Decrypted payload as seen by this hop.
  final Uint8List payload;
  Peeled(this.slot, this.next, this.payload);
}

class Sphinx {
  Sphinx._();

  static (Uint8List, List<_HopKeys>) _header(
    List<Hop> hops,
    Slot Function(int i, Uint8List nextEph, Uint8List nextMac) slotFor,
  ) {
    final n = hops.length;
    if (n < 1 || n > numSlots) throw ArgumentError('1..$numSlots hops');

    final ephs = <KeyPair25519>[];
    final keys = <_HopKeys>[];
    final streams = <Uint8List>[];
    for (final h in hops) {
      final e = KeyPair25519.generateSync();
      ephs.add(e);
      final k = _HopKeys.derive(CryptoSync.x25519(e, h.onionPk));
      keys.add(k);
      streams.add(CryptoSync.keystream(k.header, routingSize + slotSize));
    }

    // Filler: what earlier hops shift into the tail of the routing info.
    var filler = Uint8List(0);
    for (var i = 0; i < n - 1; i++) {
      final ext = Uint8List(filler.length + slotSize)..setAll(0, filler);
      final start = routingSize - i * slotSize;
      xorInto(ext, Uint8List.sublistView(streams[i], start, start + ext.length));
      filler = ext;
    }

    // Innermost routing info for the last hop.
    final lastLen = routingSize - (n - 1) * slotSize;
    final inner = Uint8List(lastLen)
      ..setAll(0, slotFor(n - 1, Uint8List(32), Uint8List(16)).encode())
      ..setAll(slotSize, randomBytes(lastLen - slotSize));
    xorInto(inner, Uint8List.sublistView(streams[n - 1], 0, lastLen));
    var beta = concat([inner, filler]);
    var mac = CryptoSync.hmac(keys[n - 1].mac, beta).sublist(0, 16);

    for (var i = n - 2; i >= 0; i--) {
      final plain = Uint8List(routingSize)
        ..setAll(0, slotFor(i, ephs[i + 1].pub, mac).encode())
        ..setAll(slotSize, Uint8List.sublistView(beta, 0, routingSize - slotSize));
      xorInto(plain, Uint8List.sublistView(streams[i], 0, routingSize));
      beta = plain;
      mac = CryptoSync.hmac(keys[i].mac, beta).sublist(0, 16);
    }
    return (concat([[hops[0].keyId], ephs[0].pub, mac, beta]), keys);
  }

  /// Builds a forward packet whose last hop receives [payload] in the clear.
  /// Runs on the crypto worker.
  static Future<Uint8List> forward(List<Hop> hops, Uint8List payload) =>
      Worker.run(() => _forward(hops, payload));

  static Uint8List _forward(List<Hop> hops, Uint8List payload) {
    if (payload.length != payloadSize) throw ArgumentError('payload size');
    final digest = CryptoSync.sha256(payload);
    final n = hops.length;
    final (header, keys) = _header(hops, (i, eph, mac) {
      if (i == n - 1) {
        return Slot(
          SlotCmd.deliver,
          delayMs: hops[i].delayMs,
          extra: digest.sublist(0, 16),
        );
      }
      final next = hops[i + 1];
      return Slot(
        SlotCmd.relay,
        delayMs: hops[i].delayMs,
        nextAddr: next.relay.addr,
        nextPk: next.relay.nodePk,
        nextEph: eph,
        nextMac: mac,
        extra: Uint8List(16)..[0] = next.keyId,
      );
    });
    // Hop i decrypts one layer, so wrap the innermost (last hop) first.
    final body = Uint8List.fromList(payload);
    for (var i = n - 1; i >= 0; i--) {
      Lioness.encrypt(keys[i].payload, body);
    }
    return concat([header, body]);
  }

  /// Builds a reply block for a path whose last hop hands the packet to the
  /// client connected under [cookie].
  static Future<(Surb, SurbSecret)> surb(List<Hop> hops, Uint8List cookie) =>
      Worker.run(() => _surb(hops, cookie));

  static (Surb, SurbSecret) _surb(List<Hop> hops, Uint8List cookie) {
    final id = randomBytes(8);
    final n = hops.length;
    final (header, keys) = _header(hops, (i, eph, mac) {
      if (i == n - 1) {
        return Slot(
          SlotCmd.toClient,
          delayMs: hops[i].delayMs,
          extra: concat([cookie, id]),
        );
      }
      final next = hops[i + 1];
      return Slot(
        SlotCmd.relay,
        delayMs: hops[i].delayMs,
        nextAddr: next.relay.addr,
        nextPk: next.relay.nodePk,
        nextEph: eph,
        nextMac: mac,
        extra: Uint8List(16)..[0] = next.keyId,
      );
    });
    return (
      Surb(hops.first.relay, header),
      SurbSecret(id, [for (final k in keys) k.payload]),
    );
  }

  /// Removes the layers the reply path added.
  static Future<Uint8List> openReply(SurbSecret s, Uint8List payload) =>
      Worker.run(() => _openReply(s, payload));

  static Uint8List _openReply(SurbSecret s, Uint8List payload) {
    // Each reply hop decrypted one layer in path order; undo from the end.
    final body = Uint8List.fromList(payload);
    for (var i = s.payloadKeys.length - 1; i >= 0; i--) {
      Lioness.encrypt(s.payloadKeys[i], body);
    }
    return body;
  }

  /// Peels one layer with the onion key named by the packet's key ID
  /// ([keyIdOf]). Returns null if the packet is invalid or a replay. The crypto
  /// runs on the worker; the replay check stays here.
  static int keyIdOf(Uint8List packet) => packet[0];

  static Future<Peeled?> peel(
    KeyPair25519 nodeKey,
    Uint8List packet,
    ReplayFilter replay,
  ) async {
    final r = await Worker.run(() => _peel(nodeKey, packet));
    if (r == null) return null;
    final (peeled, tag) = r;
    if (!replay.checkAndAdd(tag)) return null;
    return peeled;
  }

  static (Peeled, Uint8List)? _peel(KeyPair25519 nodeKey, Uint8List packet) {
    if (packet.length != packetSize) return null;
    final eph = Uint8List.sublistView(packet, 1, 33);
    final mac = Uint8List.sublistView(packet, 33, 49);
    final beta = Uint8List.sublistView(packet, 49, headerSize);
    final Uint8List shared;
    try {
      shared = CryptoSync.x25519(nodeKey, eph);
    } on FormatException {
      return null;
    }
    final keys = _HopKeys.derive(shared);
    final want = CryptoSync.hmac(keys.mac, beta);
    if (!bytesEqual(Uint8List.sublistView(want, 0, 16), mac)) return null;

    final ext = Uint8List(routingSize + slotSize)..setAll(0, beta);
    CryptoSync.xorStream(keys.header, ext);
    final Slot slot;
    try {
      slot = Slot.decode(Uint8List.sublistView(ext, 0, slotSize));
    } on FormatException {
      return null;
    }

    final payload = Uint8List.fromList(Uint8List.sublistView(packet, headerSize));
    Lioness.decrypt(keys.payload, payload);

    switch (slot.cmd) {
      case SlotCmd.relay:
        final next = concat([[slot.extra[0]], slot.nextEph, slot.nextMac, Uint8List.sublistView(ext, slotSize)]);
        return (Peeled(slot, concat([next, payload]), payload), keys.replayTag);
      case SlotCmd.deliver:
        final d = CryptoSync.sha256(payload);
        if (!bytesEqual(Uint8List.sublistView(d, 0, 16), slot.extra)) return null;
        return (Peeled(slot, null, payload), keys.replayTag);
      case SlotCmd.toClient:
        return (Peeled(slot, null, payload), keys.replayTag);
    }
  }
}
