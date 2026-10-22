import 'dart:typed_data';

import 'address.dart';
import 'bytes.dart';
import 'constants.dart';
import 'onion.dart';
import 'sphinx.dart';
import 'tokens.dart';

/// Commands carried in the payload of a forward onion packet and executed
/// by its last hop, and the replies sent back over SURBs.
abstract class Cmd {
  static const store = 0x01;
  static const fetch = 0x02;
  static const delete = 0x03;
  static const drop = 0x04;
  static const tokenReq = 0x05;
  static const dhtFind = 0x06;
  static const handoff = 0x07;
  static const watch = 0x08;
}

abstract class Reply {
  static const blob = 0x10;
  static const empty = 0x11;
  static const credential = 0x12;
  static const nodes = 0x13;
}

/// Number of SURBs per fetch and how many mailbox IDs still fit next to them.
const int fetchSurbs = 4;
const int fetchMaxIds =
    (payloadSize - 1 - 1 - fetchSurbs * Surb.encodedSize - 2) ~/ 16;

/// Longest a relay keeps a watch.
const Duration maxWatchTtl = Duration(minutes: 5);

/// A standing fetch: the relay keeps the SURBs (each usable once) and sends
/// a blob for any of [mailboxIds] through one of them as soon as it arrives.
/// Blobs already waiting are sent right away. This is what keeps delivery
/// under ten seconds without polling every few seconds.
class WatchCmd {
  final Duration ttl;
  final List<Surb> surbs;
  final List<Uint8List> mailboxIds;
  WatchCmd(this.ttl, this.surbs, this.mailboxIds);

  Uint8List encode() {
    final w = ByteWriter()
      ..u8(Cmd.watch)
      ..u16(ttl.inSeconds)
      ..u8(surbs.length);
    for (final s in surbs) {
      w.bytes(s.encode());
    }
    w.u16(mailboxIds.length);
    for (final id in mailboxIds) {
      w.bytes(id);
    }
    return w.toPadded(payloadSize);
  }

  static WatchCmd decode(ByteReader r) {
    final ttl = Duration(seconds: r.u16());
    if (ttl > maxWatchTtl || ttl == Duration.zero) throw const FormatException('bad watch ttl');
    final n = r.u8();
    if (n == 0 || n > fetchSurbs) throw const FormatException('bad watch surb count');
    final surbs = [for (var i = 0; i < n; i++) Surb.decode(r.bytes(Surb.encodedSize))];
    final m = r.u16();
    if (m > fetchMaxIds) throw const FormatException('too many watch ids');
    return WatchCmd(ttl, surbs, [for (var i = 0; i < m; i++) r.bytes(16)]);
  }
}

/// Splits mailbox IDs into fetch-sized batches, one fetch packet each.
List<List<Uint8List>> fetchBatches(List<Uint8List> ids) => [
  for (var i = 0; i < ids.length; i += fetchMaxIds)
    ids.sublist(i, i + fetchMaxIds > ids.length ? ids.length : i + fetchMaxIds),
];

/// Handoff partners advertised in every reply.
const int maxPartners = 2;

class StoreCmd {
  final Uint8List mailboxId;
  final Token token;
  final Uint8List deleteTag;
  final Uint8List blob;
  StoreCmd(this.mailboxId, this.token, this.deleteTag, this.blob);

  Uint8List encode() => (ByteWriter()
        ..u8(Cmd.store)
        ..bytes(mailboxId)
        ..bytes(token.encode())
        ..bytes(deleteTag)
        ..bytes(blob))
      .toPadded(payloadSize);

  static StoreCmd decode(ByteReader r) => StoreCmd(
    r.bytes(16),
    Token.decode(r.bytes(Token.encodedSize)),
    r.bytes(32),
    r.bytes(blobSize),
  );
}

class FetchCmd {
  final List<Surb> surbs;
  final List<Uint8List> mailboxIds;
  FetchCmd(this.surbs, this.mailboxIds);

  Uint8List encode() {
    final w = ByteWriter()
      ..u8(Cmd.fetch)
      ..u8(surbs.length);
    for (final s in surbs) {
      w.bytes(s.encode());
    }
    w.u16(mailboxIds.length);
    for (final id in mailboxIds) {
      w.bytes(id);
    }
    return w.toPadded(payloadSize);
  }

  static FetchCmd decode(ByteReader r) {
    final n = r.u8();
    final surbs = [for (var i = 0; i < n; i++) Surb.decode(r.bytes(Surb.encodedSize))];
    final m = r.u16();
    return FetchCmd(surbs, [for (var i = 0; i < m; i++) r.bytes(16)]);
  }
}

class DeleteEntry {
  final Uint8List mailboxId;
  final Uint8List hash;
  final Uint8List deleteKey;
  DeleteEntry(this.mailboxId, this.hash, this.deleteKey);
}

class DeleteCmd {
  final List<DeleteEntry> entries;
  DeleteCmd(this.entries);

  static const maxEntries = (payloadSize - 2) ~/ 80;

  Uint8List encode() {
    final w = ByteWriter()
      ..u8(Cmd.delete)
      ..u8(entries.length);
    for (final e in entries) {
      w
        ..bytes(e.mailboxId)
        ..bytes(e.hash)
        ..bytes(e.deleteKey);
    }
    return w.toPadded(payloadSize);
  }

  static DeleteCmd decode(ByteReader r) {
    final n = r.u8();
    return DeleteCmd([
      for (var i = 0; i < n; i++) DeleteEntry(r.bytes(16), r.bytes(32), r.bytes(32)),
    ]);
  }
}

class HandoffCmd {
  final Uint8List mailboxId;
  final Uint8List deleteTag;
  final DateTime expiresAt;
  final Uint8List blob;
  HandoffCmd(this.mailboxId, this.deleteTag, this.expiresAt, this.blob);

  Uint8List encode() => (ByteWriter()
        ..u8(Cmd.handoff)
        ..bytes(mailboxId)
        ..bytes(deleteTag)
        ..u64(expiresAt.millisecondsSinceEpoch)
        ..bytes(blob))
      .toPadded(payloadSize);

  static HandoffCmd decode(ByteReader r) {
    final mailboxId = r.bytes(16);
    final deleteTag = r.bytes(32);
    final ms = r.u64();
    // Expiry must be a sane time (the relay also caps it at its TTL).
    if (ms < 0 || ms > DateTime(2200).millisecondsSinceEpoch) throw const FormatException('bad expiry');
    return HandoffCmd(mailboxId, deleteTag, DateTime.fromMillisecondsSinceEpoch(ms), r.bytes(blobSize));
  }
}

Uint8List dropCmd() =>
    (ByteWriter()..u8(Cmd.drop)..bytes(randomBytes(64))).toPadded(payloadSize);

Uint8List surbCmd(int cmd, Surb surb, [List<int> extra = const []]) =>
    (ByteWriter()
          ..u8(cmd)
          ..bytes(surb.encode())
          ..bytes(extra))
        .toPadded(payloadSize);

// --- Replies ------------------------------------------------------------

class ReplyMsg {
  final int type;
  final bool last;
  final List<RelayInfo> partners;
  final Uint8List? mailboxId;
  final Uint8List? blob;
  final Credential? credential;
  final List<RelayInfo> nodes;

  /// Onion-key certificates for [nodes] (DHT replies), so they can be hops.
  final List<OnionKeyCert> certs;

  static const maxNodeCerts = 16;

  ReplyMsg(
    this.type, {
    this.last = true,
    this.partners = const [],
    this.mailboxId,
    this.blob,
    this.credential,
    this.nodes = const [],
    this.certs = const [],
  });

  Uint8List encode() {
    final w = ByteWriter()
      ..u8(type)
      ..u8(last ? 1 : 0)
      ..u8(partners.length);
    for (final p in partners.take(maxPartners)) {
      w.bytes(p.encode());
    }
    switch (type) {
      case Reply.blob:
        w
          ..bytes(mailboxId!)
          ..bytes(blob!);
      case Reply.credential:
        w.bytes(credential!.encode());
      case Reply.nodes:
        w.u8(nodes.length);
        for (final n in nodes) {
          w.bytes(n.encode());
        }
        final cs = certs.take(maxNodeCerts).toList();
        w.u8(cs.length);
        for (final c in cs) {
          w.bytes(c.encode());
        }
    }
    return w.toPadded(payloadSize);
  }

  static ReplyMsg decode(Uint8List payload) {
    final r = ByteReader(payload);
    final type = r.u8();
    final last = r.u8() == 1;
    final np = r.u8();
    if (np > maxPartners) throw const FormatException('too many partners');
    final partners = [
      for (var i = 0; i < np; i++) RelayInfo.decode(r.bytes(RelayInfo.encodedSize)),
    ];
    switch (type) {
      case Reply.blob:
        return ReplyMsg(
          type,
          last: last,
          partners: partners,
          mailboxId: r.bytes(16),
          blob: r.bytes(blobSize),
        );
      case Reply.empty:
        return ReplyMsg(type, last: last, partners: partners);
      case Reply.credential:
        return ReplyMsg(
          type,
          last: last,
          partners: partners,
          credential: Credential.decode(r),
        );
      case Reply.nodes:
        final n = r.u8();
        final nodes = [
          for (var i = 0; i < n; i++) RelayInfo.decode(r.bytes(RelayInfo.encodedSize)),
        ];
        final m = r.u8();
        if (m > maxNodeCerts) throw const FormatException('too many certs');
        return ReplyMsg(
          type,
          last: last,
          partners: partners,
          nodes: nodes,
          certs: [for (var i = 0; i < m; i++) OnionKeyCert.decode(r)],
        );
      default:
        throw const FormatException('unknown reply');
    }
  }
}
