import 'dart:typed_data';

import 'address.dart';
import 'bytes.dart';
import 'media.dart';
import 'onion.dart';
import 'tokens.dart';

/// Routing information friends keep sending each other. This is how the
/// network grows without a directory.
class AddressInfo {
  /// Relay addresses of the sender's own node (for the receiver's routing).
  final List<RelayInfo> relays;

  /// Where to send messages to the sender, with tokens to pay for storage.
  final List<Credential> mailboxes;

  /// Credentials on the sender's relay for the receiver's own mailbox use.
  final List<Credential> relayCreds;

  /// Other relays the sender knows and has reached recently, so friends'
  /// relay lists stay in sync.
  final List<RelayInfo> known;

  /// Onion-key certificates for the relays above (each verified against the
  /// identity it names), so receivers can route through them.
  final List<OnionKeyCert> certs;

  static const maxKnown = 16;
  static const maxCerts = 20;

  AddressInfo({
    this.relays = const [],
    this.mailboxes = const [],
    this.relayCreds = const [],
    this.known = const [],
    this.certs = const [],
  });

  void write(ByteWriter w) {
    w.u8(relays.length);
    for (final r in relays) {
      w.bytes(r.encode());
    }
    w.u8(mailboxes.length);
    for (final c in mailboxes) {
      w.bytes(c.encode());
    }
    w.u8(relayCreds.length);
    for (final c in relayCreds) {
      w.bytes(c.encode());
    }
    final k = known.take(maxKnown).toList();
    w.u8(k.length);
    for (final r in k) {
      w.bytes(r.encode());
    }
    final c = certs.take(maxCerts).toList();
    w.u8(c.length);
    for (final x in c) {
      w.bytes(x.encode());
    }
  }

  static AddressInfo read(ByteReader r) => AddressInfo(
    relays: [
      for (var i = r.u8(); i > 0; i--) RelayInfo.decode(r.bytes(RelayInfo.encodedSize)),
    ],
    mailboxes: [for (var i = r.u8(); i > 0; i--) Credential.decode(r)],
    relayCreds: [for (var i = r.u8(); i > 0; i--) Credential.decode(r)],
    known: _list(r, maxKnown, () => RelayInfo.decode(r.bytes(RelayInfo.encodedSize))),
    certs: _list(r, maxCerts, () => OnionKeyCert.decode(r)),
  );

  static List<T> _list<T>(ByteReader r, int max, T Function() item) {
    final n = r.u8();
    if (n > max) throw const FormatException('list too long');
    return [for (var i = 0; i < n; i++) item()];
  }
}

/// Sent before the Double Ratchet exists, sealed with the pairing keys.
/// The initiator sends its ML-KEM public key; the responder answers with
/// the ciphertext.
class Hello {
  final Uint8List? kemPk;
  final Uint8List? kemCt;
  final AddressInfo info;
  Hello({this.kemPk, this.kemCt, required this.info});

  Uint8List encode() {
    final w = ByteWriter();
    if (kemPk != null) {
      w
        ..u8(1)
        ..varBytes(kemPk!);
    } else {
      w.u8(0);
    }
    if (kemCt != null) {
      w
        ..u8(1)
        ..varBytes(kemCt!);
    } else {
      w.u8(0);
    }
    info.write(w);
    return w.toBytes();
  }

  static Hello decode(Uint8List b) {
    final r = ByteReader(b);
    final pk = r.u8() == 1 ? r.varBytes() : null;
    final ct = r.u8() == 1 ? r.varBytes() : null;
    return Hello(kemPk: pk, kemCt: ct, info: AddressInfo.read(r));
  }
}

enum MsgType { text, receipt, update, updateRequest, image, sticker, mediaChunk, mediaRequest }

/// Most chunk indices one media request may list.
const int maxRequestIndices = 200;

/// Plaintext inside the Double Ratchet.
class ChatMsg {
  final MsgType type;
  final Uint8List id;
  final int timestamp;
  final String text;
  final List<Uint8List> receiptFor;
  final AddressInfo? info;

  /// image / sticker.
  final MediaRef? media;

  /// mediaChunk / mediaRequest: the media hash.
  final Uint8List? mediaHash;
  final int chunkIndex;
  final int chunkTotal;
  final Uint8List? chunkData;

  /// mediaRequest: missing chunk indices (empty: all).
  final List<int> indices;

  ChatMsg(
    this.type,
    this.id, {
    this.timestamp = 0,
    this.text = '',
    this.receiptFor = const [],
    this.info,
    this.media,
    this.mediaHash,
    this.chunkIndex = 0,
    this.chunkTotal = 0,
    this.chunkData,
    this.indices = const [],
  });

  Uint8List encode() {
    final w = ByteWriter()
      ..u8(type.index + 1)
      ..bytes(id);
    switch (type) {
      case MsgType.text:
        w
          ..u64(timestamp)
          ..str(text);
      case MsgType.receipt:
        w.u8(receiptFor.length);
        for (final r in receiptFor) {
          w.bytes(r);
        }
      case MsgType.update:
        info!.write(w);
      case MsgType.updateRequest:
        break;
      case MsgType.image:
        w
          ..u64(timestamp)
          ..str(text);
        media!.write(w);
      case MsgType.sticker:
        w.u64(timestamp);
        media!.write(w);
      case MsgType.mediaChunk:
        w
          ..bytes(mediaHash!)
          ..u16(chunkIndex)
          ..u16(chunkTotal)
          ..varBytes(chunkData!);
      case MsgType.mediaRequest:
        w
          ..bytes(mediaHash!)
          ..u16(indices.length);
        for (final i in indices) {
          w.u16(i);
        }
    }
    return w.toBytes();
  }

  static ChatMsg decode(Uint8List b) {
    final r = ByteReader(b);
    final t = r.u8();
    if (t < 1 || t > MsgType.values.length) throw const FormatException('type');
    final type = MsgType.values[t - 1];
    final id = r.bytes(16);
    switch (type) {
      case MsgType.text:
        return ChatMsg(type, id, timestamp: r.u64(), text: r.str());
      case MsgType.receipt:
        return ChatMsg(type, id, receiptFor: [for (var i = r.u8(); i > 0; i--) r.bytes(16)]);
      case MsgType.update:
        return ChatMsg(type, id, info: AddressInfo.read(r));
      case MsgType.updateRequest:
        return ChatMsg(type, id);
      case MsgType.image:
        final ts = r.u64();
        final text = r.str();
        return ChatMsg(type, id, timestamp: ts, text: text, media: MediaRef.read(r));
      case MsgType.sticker:
        final ts = r.u64();
        return ChatMsg(type, id, timestamp: ts, media: MediaRef.read(r));
      case MsgType.mediaChunk:
        final h = r.bytes(32);
        final i = r.u16();
        final n = r.u16();
        final data = r.varBytes();
        if (n == 0 || i >= n || n > chunkCount(maxImageBytes) || data.isEmpty || data.length > mediaChunkSize) {
          throw const FormatException('media chunk');
        }
        return ChatMsg(type, id, mediaHash: h, chunkIndex: i, chunkTotal: n, chunkData: data);
      case MsgType.mediaRequest:
        final h = r.bytes(32);
        final n = r.u16();
        if (n > maxRequestIndices) throw const FormatException('too many indices');
        return ChatMsg(type, id, mediaHash: h, indices: [for (var i = 0; i < n; i++) r.u16()]);
    }
  }
}
