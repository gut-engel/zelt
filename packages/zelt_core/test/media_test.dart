@Timeout(Duration(minutes: 3))
library;

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/crypto.dart';
import 'package:zelt_core/media.dart';
import 'package:zelt_core/messages.dart';
import 'package:zelt_core/messenger.dart';
import 'package:zelt_core/models.dart';
import 'package:zelt_core/node.dart';

import 'e2e_test.dart' show debugLogs, messenger, pair, relayNode, until;

/// Random bytes with a WebP header (the core only checks format and hash).
Uint8List fakeWebp(int n) => Uint8List.fromList([...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits, ...randomBytes(n - 12)]);

void main() {
  late List<Node> relays;
  final cleanup = <Messenger>[];

  setUp(() async {
    relays = [for (var i = 0; i < 5; i++) await relayNode()];
  });

  tearDown(() async {
    for (final m in cleanup) {
      await m.dispose();
    }
    cleanup.clear();
    debugLogs.clear();
    for (final r in relays) {
      await r.stop();
    }
  });

  Future<(Messenger, Messenger, Contact, Contact)> friends() async {
    final a = await messenger('alice');
    final b = await messenger('bob');
    cleanup.addAll([a, b]);
    for (final m in [a, b]) {
      await m.start();
      for (final r in relays) {
        m.addManualPeer((await r.localRelayInfos()).first);
      }
    }
    final (ab, ba) = await pair(a, b);
    await until(() => ab.ready && ba.ready, 'handshake');
    return (a, b, ab, ba);
  }

  int served(Messenger m) => m.logLines.where((l) => l.contains('serving ')).length;

  test('an image arrives in chunks and matches its hash', () async {
    final (alice, bob, ab, ba) = await friends();
    final jpeg = fakeWebp(100 * 1024); // 15 chunks
    final sent = await alice.sendImage(ab.id, jpeg, width: 1280, height: 960, caption: 'look');
    await until(() => ba.messages.any((m) => m.media?.id == sent.media!.id), 'image message');
    final ref = sent.media!;
    expect(ref.chunks, 15);
    await until(() => bob.mediaProgress(ref.id) == null && ba.messages.last.text == 'look', 'transfer');
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!await bob.hasMedia(ref.id) && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    expect(await bob.media.read(ref.id), jpeg);
    expect(served(alice), 0, reason: 'images are pushed, not requested');
  });

  Future<void> untilHas(Messenger m, String hash) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!await m.hasMedia(hash) && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  int chunksTo(Messenger m, String contactId) =>
      m.outbox.where((o) => o.contactId == contactId).length;

  test('a new sticker is pushed once, then travels as its hash only', () async {
    final (alice, bob, ab, ba) = await friends();
    final png = fakeWebp(20000);
    final ref = await alice.addSticker(png, width: 256, height: 256);
    expect(alice.stickers.single.id, ref.id);
    await alice.sendSticker(ab.id, ref);
    expect(chunksTo(alice, ab.id), greaterThanOrEqualTo(1 + ref.chunks), reason: 'bytes follow the first send');
    await untilHas(bob, ref.id);
    expect(await bob.media.read(ref.id), png);
    await Future.delayed(const Duration(seconds: 8));
    expect(served(alice), 0, reason: 'pushed: no request round trip');

    // Known now: the second sticker message costs only its hash.
    await until(() => alice.outbox.isEmpty, 'outbox drained');
    await alice.sendSticker(ab.id, ref);
    expect(chunksTo(alice, ab.id), 1);
    await until(() => ba.messages.where((m) => m.media?.id == ref.id).length == 2, 'second sticker');
    await Future.delayed(const Duration(seconds: 2));
    expect(served(alice), 0, reason: 'no fetch');

    // Bob sends it back: alice has it, so only the hash goes.
    await until(() => bob.outbox.isEmpty, 'bob outbox drained');
    await bob.saveSticker(ref);
    await bob.sendSticker(ba.id, ref);
    expect(chunksTo(bob, ba.id), 1);
  });

  test('a sticker sent as hash only (older senders) is fetched on request', () async {
    final (alice, bob, ab, ba) = await friends();
    final png = fakeWebp(20000);
    final ref = await alice.addSticker(png, width: 256, height: 256);
    ab.sentMedia.add(ref.id); // as if bob already had it: no push
    await alice.sendSticker(ab.id, ref);
    await untilHas(bob, ref.id);
    expect(await bob.media.read(ref.id), png);
    expect(served(alice), 1);
  });

  test('media is only served to friends it was sent to, and must match its hash', () async {
    final (alice, bob, ab, ba) = await friends();
    final ref = await alice.addSticker(fakeWebp(9000), width: 128, height: 128);
    ab.sentMedia.add(ref.id); // hash only, no push
    await alice.sendSticker(ab.id, ref);
    ab.sentMedia.clear(); // as if never sent to bob: requests must be refused
    await until(() => ba.messages.any((m) => m.media?.id == ref.id), 'sticker message');
    await Future.delayed(const Duration(seconds: 3));
    expect(served(alice), 0);
    expect(await bob.hasMedia(ref.id), isFalse);

    // A sender whose bytes do not match the hash: the receiver rejects them.
    final ref2 = await alice.addSticker(fakeWebp(9000), width: 128, height: 128);
    await alice.media.write(ref2.id, fakeWebp(9000)); // same size, different bytes
    ab.sentMedia.add(ref2.id);
    await alice.sendSticker(ab.id, ref2);
    await until(() => served(alice) == 1, 'served the bad bytes');
    await until(() => bob.logLines.any((l) => l.contains('did not match its hash')), 'rejected');
    expect(await bob.hasMedia(ref2.id), isFalse);
  });

  test('media references outside the limits are rejected before any transfer', () {
    Uint8List enc(MediaKind k, int f, int size, int w, int h) {
      final wr = ByteWriter();
      MediaRef(hash: randomBytes(32), size: size, kind: k, format: f, width: w, height: h).write(wr);
      return wr.toBytes();
    }

    expect(MediaRef.read(ByteReader(enc(MediaKind.image, MediaFormat.webp, 1000, 100, 100))).size, 1000);
    for (final bad in [
      enc(MediaKind.image, MediaFormat.jpeg, 1000, 100, 100), // only WebP on the wire
      enc(MediaKind.sticker, MediaFormat.gif, 1000, 100, 100),
      enc(MediaKind.image, MediaFormat.webp, maxImageBytes + 1, 100, 100),
      enc(MediaKind.image, MediaFormat.webp, 1000, maxImageSide + 1, 100),
      enc(MediaKind.sticker, MediaFormat.webp, maxStickerBytes + 1, 100, 100),
      enc(MediaKind.sticker, MediaFormat.webp, 1000, maxStickerSide + 1, 10),
      enc(MediaKind.sticker, MediaFormat.webp, 0, 10, 10),
    ]) {
      expect(() => MediaRef.read(ByteReader(bad)), throwsFormatException);
    }
    // A chunk claiming more chunks than the largest image could have.
    final chunk = ChatMsg(MsgType.mediaChunk, randomBytes(16),
            mediaHash: randomBytes(32), chunkIndex: 0, chunkTotal: chunkCount(maxImageBytes) + 1, chunkData: randomBytes(10))
        .encode();
    expect(() => ChatMsg.decode(chunk), throwsFormatException);
    expect(CryptoSync.sha256(Uint8List(0)).length, 32);
  });
}
