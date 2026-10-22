import 'dart:typed_data';

import 'address.dart';
import 'bytes.dart';
import 'constants.dart';
import 'crypto.dart';
import 'worker.dart';

/// Sphinx-style onion packets.
///
/// Packet = eph(32) | mac(16) | routing(R) | payload(P), always [packetSize].
///
/// Each hop computes s = X25519(nodeKey, eph), checks the MAC over the
/// routing info, decrypts (routing || 0^S) with a stream keyed from s and
/// reads its own slot from the front. The slot names the next hop and holds
/// the next hop's ephemeral key and MAC, so successive headers share no bytes.
/// The payload is re-encrypted at each hop. Filler is computed by the sender
/// so the header length never shrinks.
///
/// Departure from textbook Sphinx: per-hop ephemeral keys are carried inside
/// the encrypted routing info instead of being derived by group-element
/// blinding, and the payload uses a stream cipher per hop. Payload integrity
/// is checked by the final hop (a digest in its slot) and end to end by the
/// AEAD inside the blob.
enum SlotCmd { relay, deliver, toClient }

class Hop {
  final RelayInfo relay;

  /// How long this relay holds the packet before forwarding.
  final int delayMs;
  Hop(this.relay, {this.delayMs = 0});
}

class _HopKeys {
  final Uint8List mac;
  final Uint8List header;
  final Uint8List payload;
  final Uint8List replayTag;
  _HopKeys(this.mac, this.header, this.payload, this.replayTag);

  static Future<_HopKeys> derive(Uint8List shared) async {
    final k = await Crypto.hkdf(shared, info: 'zelt/sphinx/v1', length: 128);
    return _HopKeys(
      k.sublist(0, 32),
      k.sublist(32, 64),
      k.sublist(64, 96),
      k.sublist(96, 112),
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

  static Future<(Uint8List, List<_HopKeys>)> _header(
    List<Hop> hops,
    Slot Function(int i, Uint8List nextEph, Uint8List nextMac) slotFor,
  ) async {
    final n = hops.length;
    if (n < 1 || n > numSlots) throw ArgumentError('1..$numSlots hops');

    final ephs = <KeyPair25519>[];
    final keys = <_HopKeys>[];
    final streams = <Uint8List>[];
    for (final h in hops) {
      final e = await Crypto.x25519Generate();
      ephs.add(e);
      final k = await _HopKeys.derive(await Crypto.x25519(e, h.relay.nodePk));
      keys.add(k);
      streams.add(await Crypto.keystream(k.header, routingSize + slotSize));
    }

    // Filler: what earlier hops shift into the tail of the routing info.
    var filler = Uint8List(0);
    for (var i = 0; i < n - 1; i++) {
      final ext = Uint8List(filler.length + slotSize)..setAll(0, filler);
      final start = routingSize - i * slotSize;
      xorInto(ext, streams[i].sublist(start, start + ext.length));
      filler = ext;
    }

    // Innermost routing info for the last hop.
    final lastLen = routingSize - (n - 1) * slotSize;
    final inner = Uint8List(lastLen)
      ..setAll(0, slotFor(n - 1, Uint8List(32), Uint8List(16)).encode())
      ..setAll(slotSize, randomBytes(lastLen - slotSize));
    xorInto(inner, streams[n - 1].sublist(0, lastLen));
    var beta = concat([inner, filler]);
    var mac = (await Crypto.hmac(keys[n - 1].mac, beta)).sublist(0, 16);

    for (var i = n - 2; i >= 0; i--) {
      final plain = Uint8List(routingSize)
        ..setAll(0, slotFor(i, ephs[i + 1].pub, mac).encode())
        ..setAll(slotSize, beta.sublist(0, routingSize - slotSize));
      xorInto(plain, streams[i].sublist(0, routingSize));
      beta = plain;
      mac = (await Crypto.hmac(keys[i].mac, beta)).sublist(0, 16);
    }
    return (concat([ephs[0].pub, mac, beta]), keys);
  }

  /// Builds a forward packet whose last hop receives [payload] in the clear.
  /// Runs on the crypto worker.
  static Future<Uint8List> forward(List<Hop> hops, Uint8List payload) =>
      Worker.run(() => _forward(hops, payload));

  static Future<Uint8List> _forward(List<Hop> hops, Uint8List payload) async {
    if (payload.length != payloadSize) throw ArgumentError('payload size');
    final digest = await Crypto.sha256(payload);
    final n = hops.length;
    final (header, keys) = await _header(hops, (i, eph, mac) {
      if (i == n - 1) {
        return Slot(
          SlotCmd.deliver,
          delayMs: hops[i].delayMs,
          extra: digest.sublist(0, 16),
        );
      }
      final next = hops[i + 1].relay;
      return Slot(
        SlotCmd.relay,
        delayMs: hops[i].delayMs,
        nextAddr: next.addr,
        nextPk: next.nodePk,
        nextEph: eph,
        nextMac: mac,
      );
    });
    final body = Uint8List.fromList(payload);
    for (final k in keys) {
      xorInto(body, await Crypto.keystream(k.payload, payloadSize));
    }
    return concat([header, body]);
  }

  /// Builds a reply block for a path whose last hop hands the packet to the
  /// client connected under [cookie].
  static Future<(Surb, SurbSecret)> surb(List<Hop> hops, Uint8List cookie) =>
      Worker.run(() => _surb(hops, cookie));

  static Future<(Surb, SurbSecret)> _surb(
    List<Hop> hops,
    Uint8List cookie,
  ) async {
    final id = randomBytes(8);
    final n = hops.length;
    final (header, keys) = await _header(hops, (i, eph, mac) {
      if (i == n - 1) {
        return Slot(
          SlotCmd.toClient,
          delayMs: hops[i].delayMs,
          extra: concat([cookie, id]),
        );
      }
      final next = hops[i + 1].relay;
      return Slot(
        SlotCmd.relay,
        delayMs: hops[i].delayMs,
        nextAddr: next.addr,
        nextPk: next.nodePk,
        nextEph: eph,
        nextMac: mac,
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

  static Future<Uint8List> _openReply(SurbSecret s, Uint8List payload) async {
    final body = Uint8List.fromList(payload);
    for (final k in s.payloadKeys) {
      xorInto(body, await Crypto.keystream(k, payloadSize));
    }
    return body;
  }

  /// Peels one layer with this node's key. Returns null if the packet is
  /// invalid or a replay (see [ReplayFilter]). The crypto runs on the worker;
  /// the replay check stays here.
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

  static Future<(Peeled, Uint8List)?> _peel(KeyPair25519 nodeKey, Uint8List packet) async {
    if (packet.length != packetSize) return null;
    final eph = packet.sublist(0, 32);
    final mac = packet.sublist(32, 48);
    final beta = packet.sublist(48, headerSize);
    final Uint8List shared;
    try {
      shared = await Crypto.x25519(nodeKey, eph);
    } on FormatException {
      return null;
    }
    final keys = await _HopKeys.derive(shared);
    final want = (await Crypto.hmac(keys.mac, beta)).sublist(0, 16);
    if (!bytesEqual(want, mac)) return null;

    final ext = Uint8List(routingSize + slotSize)..setAll(0, beta);
    xorInto(ext, await Crypto.keystream(keys.header, routingSize + slotSize));
    final Slot slot;
    try {
      slot = Slot.decode(ext.sublist(0, slotSize));
    } on FormatException {
      return null;
    }

    final payload = packet.sublist(headerSize);
    xorInto(payload, await Crypto.keystream(keys.payload, payloadSize));

    switch (slot.cmd) {
      case SlotCmd.relay:
        final next = concat([slot.nextEph, slot.nextMac, ext.sublist(slotSize)]);
        return (Peeled(slot, concat([next, payload]), payload), keys.replayTag);
      case SlotCmd.deliver:
        final d = (await Crypto.sha256(payload)).sublist(0, 16);
        if (!bytesEqual(d, slot.extra)) return null;
        return (Peeled(slot, null, payload), keys.replayTag);
      case SlotCmd.toClient:
        return (Peeled(slot, null, payload), keys.replayTag);
    }
  }
}

/// Remembers per-packet tags so a replayed packet is dropped, which stops an
/// observer from replaying a packet to see where its copy goes.
class ReplayFilter {
  final Duration keep;
  final Map<String, int> _seen = {};
  ReplayFilter({this.keep = relayTtl});

  bool checkAndAdd(Uint8List tag) {
    final k = hex(tag);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_seen.containsKey(k)) return false;
    _seen[k] = now;
    if (_seen.length > 200000) prune();
    return true;
  }

  void prune() {
    final cutoff = DateTime.now().millisecondsSinceEpoch - keep.inMilliseconds;
    _seen.removeWhere((_, t) => t < cutoff);
    // Hard bound: drop the oldest half if still too large.
    if (_seen.length > 200000) {
      final keys = _seen.keys.take(_seen.length ~/ 2).toList();
      keys.forEach(_seen.remove);
    }
  }
}
