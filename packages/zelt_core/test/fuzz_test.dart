// Fuzz tests: random and mutated inputs must never crash or hang a parser;
// they may only parse or be rejected (FormatException / null). Seeded, so a
// failure is reproducible; set ZELT_FUZZ_ITER for longer runs.
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zelt_core/address.dart';
import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/constants.dart';
import 'package:zelt_core/crypto.dart';
import 'package:zelt_core/envelope.dart';
import 'package:zelt_core/invite.dart';
import 'package:zelt_core/media.dart';
import 'package:zelt_core/link.dart';
import 'package:zelt_core/messages.dart';
import 'package:zelt_core/node.dart';
import 'package:zelt_core/onion.dart';
import 'package:zelt_core/pairing.dart';
import 'package:zelt_core/protocol.dart';
import 'package:zelt_core/sphinx.dart';
import 'package:zelt_core/tokens.dart';

final int iterations = int.tryParse(Platform.environment['ZELT_FUZZ_ITER'] ?? '') ?? 300;

class Fuzzer {
  final Random rng;
  Fuzzer(int seed) : rng = Random(seed);

  Uint8List random(int maxLen) => Uint8List.fromList(List.generate(rng.nextInt(maxLen + 1), (_) => rng.nextInt(256)));

  /// Bit flips, truncation, extension or overwritten runs of a valid input.
  Uint8List mutate(Uint8List valid) {
    final b = BytesBuilder()..add(valid);
    var out = b.toBytes();
    switch (rng.nextInt(5)) {
      case 0:
        for (var i = 0; i < 1 + rng.nextInt(8) && out.isNotEmpty; i++) {
          out[rng.nextInt(out.length)] ^= 1 << rng.nextInt(8);
        }
      case 1:
        out = out.sublist(0, out.isEmpty ? 0 : rng.nextInt(out.length));
      case 2:
        out = Uint8List.fromList([...out, ...random(64)]);
      case 3:
        if (out.isNotEmpty) {
          final at = rng.nextInt(out.length);
          final n = min(1 + rng.nextInt(16), out.length - at);
          for (var i = 0; i < n; i++) {
            out[at + i] = rng.nextBool() ? 0xff : 0x00;
          }
        }
      case 4:
        // Large length/count fields are the classic parser killer.
        if (out.length > 4) {
          final at = rng.nextInt(out.length - 2);
          out[at] = 0xff;
          out[at + 1] = 0xff;
        }
    }
    return out;
  }
}

/// Runs [parse]; only success or FormatException is acceptable.
void mustNotCrash(String what, Object? Function() parse) {
  try {
    parse();
  } on FormatException {
    // Rejected cleanly.
  } catch (e, st) {
    fail('$what crashed with ${e.runtimeType}: $e\n$st');
  }
}

Future<void> mustNotCrashAsync(String what, Future<Object?> Function() parse) async {
  try {
    await parse();
  } on FormatException {
    // Rejected cleanly.
  } catch (e, st) {
    fail('$what crashed with ${e.runtimeType}: $e\n$st');
  }
}

void main() {
  test('onion packet parser: random and mutated packets are only rejected', () async {
    final f = Fuzzer(1);
    final keys = [for (var i = 0; i < 3; i++) KeyPair25519.generateSync()];
    final hops = [
      for (var i = 0; i < 3; i++) Hop(RelayInfo(NodeAddr(InternetAddress.loopbackIPv4, 9000 + i), randomBytes(32)), keys[i].pub, i),
    ];
    final valid = Sphinx.forwardWith(hops, Uint8List(payloadSize), randomBytes);
    var accepted = 0;
    for (var i = 0; i < iterations; i++) {
      final input = i.isEven ? f.mutate(valid) : f.random(packetSize + 64);
      mustNotCrash('peel', () {
        final r = Sphinx.peelWith(keys[0], input);
        if (r != null) accepted++;
        return r;
      });
    }
    // A mutation that leaves the header intact may still peel (payload is
    // only checked at the last hop); anything else must be rejected.
    expect(accepted, lessThan(iterations ~/ 2));
  });

  test('payload command and reply decoders', () async {
    final f = Fuzzer(2);
    final k = KeyPair25519.generateSync();
    final hop = Hop(RelayInfo(NodeAddr(InternetAddress.loopbackIPv4, 1), randomBytes(32)), k.pub, 1);
    final (surb, _) = Sphinx.surbWith([hop, hop], randomBytes(8), randomBytes);
    final cred = await TokenIssuer(randomBytes(32)).issue(hop.relay, 5);
    final valids = <Uint8List>[
      StoreCmd(randomBytes(16), await cred.take(randomBytes(32)), randomBytes(32), randomBytes(blobSize)).encode(),
      FetchCmd([surb, surb], [randomBytes(16), randomBytes(16)]).encode(),
      WatchCmd(const Duration(minutes: 1), [surb, surb], [randomBytes(16), randomBytes(16)]).encode(),
      DeleteCmd([DeleteEntry(randomBytes(16), randomBytes(32), randomBytes(32))]).encode(),
      HandoffCmd(randomBytes(16), randomBytes(32), DateTime.now(), randomBytes(blobSize)).encode(),
      surbCmd(Cmd.dhtFind, surb, randomBytes(32)),
    ];
    final replies = <Uint8List>[
      ReplyMsg(Reply.blob, mailboxId: randomBytes(16), blob: randomBytes(blobSize)).encode(),
      ReplyMsg(Reply.empty, partners: [hop.relay]).encode(),
      ReplyMsg(Reply.credential, credential: cred).encode(),
      ReplyMsg(Reply.nodes, nodes: [hop.relay]).encode(),
    ];
    Object? decodeCmd(Uint8List p) {
      final r = ByteReader(p);
      return switch (r.u8()) {
        Cmd.store => StoreCmd.decode(r),
        Cmd.fetch => FetchCmd.decode(r),
        Cmd.watch => WatchCmd.decode(r),
        Cmd.delete => DeleteCmd.decode(r),
        Cmd.handoff => HandoffCmd.decode(r),
        Cmd.tokenReq || Cmd.dhtFind => Surb.decode(r.bytes(Surb.encodedSize)),
        _ => null,
      };
    }

    for (var i = 0; i < iterations; i++) {
      final v = valids[i % valids.length];
      mustNotCrash('command', () => decodeCmd(i % 3 == 0 ? f.random(payloadSize) : f.mutate(v)));
      final rv = replies[i % replies.length];
      mustNotCrash('reply', () => ReplyMsg.decode(i % 3 == 0 ? f.random(payloadSize) : f.mutate(rv)));
    }
  });

  test('message, pairing, credential and certificate decoders', () async {
    final f = Fuzzer(3);
    final relay = RelayInfo(NodeAddr(InternetAddress('2001:db8::1'), 47017), randomBytes(32));
    final cred = await TokenIssuer(randomBytes(32)).issue(relay, 2);
    final id = await Crypto.ed25519Generate();
    final cert = await OnionKeyCert.sign(id, 1, randomBytes(32), DateTime.now(), DateTime.now().add(const Duration(hours: 1)));
    final info = AddressInfo(relays: [relay], mailboxes: [cred], relayCreds: [cred], known: [relay], certs: [cert]);
    final hello = Hello(kemPk: randomBytes(1184), info: info).encode();
    final chat = ChatMsg(MsgType.text, randomBytes(16), timestamp: 1, text: 'hi').encode();
    final update = ChatMsg(MsgType.update, randomBytes(16), info: info).encode();
    final mref = MediaRef(hash: randomBytes(32), size: 5000, kind: MediaKind.sticker, format: MediaFormat.webp, width: 200, height: 200);
    final mediaMsgs = [
      ChatMsg(MsgType.image, randomBytes(16), timestamp: 1, text: 'c',
          media: MediaRef(hash: randomBytes(32), size: 90000, kind: MediaKind.image, format: MediaFormat.webp, width: 1280, height: 720)).encode(),
      ChatMsg(MsgType.sticker, randomBytes(16), timestamp: 1, media: mref).encode(),
      ChatMsg(MsgType.mediaChunk, randomBytes(16), mediaHash: randomBytes(32), chunkIndex: 2, chunkTotal: 5, chunkData: randomBytes(mediaChunkSize)).encode(),
      ChatMsg(MsgType.mediaRequest, randomBytes(16), mediaHash: randomBytes(32), indices: [1, 2, 3]).encode(),
    ];
    final code = PairingCode(idPub: randomBytes(32), ephPub: randomBytes(32), seed: randomBytes(32), name: 'x', relays: [relay], grants: [cred]).encode();
    final codeBytes = unb64(code.substring(PairingCode.prefix.length));

    for (var i = 0; i < iterations; i++) {
      mustNotCrash('Hello', () => Hello.decode(i.isEven ? f.mutate(hello) : f.random(800)));
      mustNotCrash('ChatMsg', () => ChatMsg.decode(f.mutate(i.isEven ? chat : update)));
      mustNotCrash('media ChatMsg', () => ChatMsg.decode(f.mutate(mediaMsgs[i % mediaMsgs.length])));
      mustNotCrash('AddressInfo', () => AddressInfo.read(ByteReader(f.mutate(i.isEven ? hello.sublist(1188) : f.random(300)))));
      mustNotCrash('PairingCode', () => PairingCode.parse(PairingCode.prefix + b64(f.mutate(codeBytes))));
      mustNotCrash('PairingCode text', () => PairingCode.parse(String.fromCharCodes(f.random(200))));
      mustNotCrash('Credential', () => Credential.decode(ByteReader(f.mutate(cred.encode()))));
      mustNotCrash('OnionKeyCert', () => OnionKeyCert.decode(ByteReader(f.mutate(cert.encode()))));
      mustNotCrash('RelayInfo share string', () => RelayInfo.parseShareString(String.fromCharCodes(f.random(120))));
      final invite = InviteCode(inviteId: randomBytes(16), invitePub: randomBytes(32), expiresAt: DateTime.now(), code: PairingCode.parse(code));
      final inviteBytes = unb64(invite.encode().substring(InviteCode.prefix.length));
      mustNotCrash('InviteCode', () => InviteCode.parse(InviteCode.prefix + b64(f.mutate(inviteBytes))));
      mustNotCrash('InviteCode text', () => InviteCode.parse(InviteCode.prefix + String.fromCharCodes(f.random(200))));
    }
  });

  test('envelope open rejects garbage without throwing', () async {
    final f = Fuzzer(4);
    final key = randomBytes(32);
    final valid = await Envelope.seal(key, 1, randomBytes(100));
    for (var i = 0; i < iterations ~/ 3; i++) {
      await mustNotCrashAsync('Envelope.open', () => Envelope.open(key, i.isEven ? f.mutate(valid) : f.random(blobSize + 10)));
    }
  });

  test('link handshake and frames: garbage from a peer only closes the connection', () async {
    final f = Fuzzer(5);
    final identity = await Crypto.ed25519Generate();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final outcomes = <Object>[];
    server.listen((s) async {
      try {
        final l = (await Link.accept(s, identity, timeout: const Duration(seconds: 2))).start();
        await l.frames.drain<void>().timeout(const Duration(seconds: 3), onTimeout: l.close);
        outcomes.add('closed');
      } catch (e) {
        outcomes.add(e);
      }
    });
    final n = min(40, iterations ~/ 5);
    for (var i = 0; i < n; i++) {
      final c = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
      if (i.isEven) {
        c.add(f.random(Frame.wireSize * 2)); // raw garbage, maybe with a valid-looking preamble
      } else {
        // A correct preamble and key, then garbage frames.
        c.add([0x5a, 0x4c, 0x54, protocolVersion, ...randomBytes(32)]);
        await Future.delayed(const Duration(milliseconds: 20));
        c.add(f.random(Frame.wireSize * 3));
      }
      await c.flush().catchError((_) {});
      await Future.delayed(const Duration(milliseconds: 30));
      c.destroy();
    }
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (outcomes.length < n && DateTime.now().isBefore(end)) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    await server.close();
    expect(outcomes.length, n, reason: 'every connection ended (no hang)');
    for (final o in outcomes) {
      expect(o is String || o is IncompatiblePeer || o is SocketException || o is TimeoutException || o is StateError,
          isTrue, reason: 'unexpected ${o.runtimeType}: $o');
    }
  });

  test('a live relay rejects random packets and keeps working', () async {
    final f = Fuzzer(6);
    final relay = Node(identity: await Crypto.ed25519Generate(), relaySecret: randomBytes(32), port: 0, bindAddress: InternetAddress.loopbackIPv4);
    await relay.start(relay: true);
    final info = RelayInfo(NodeAddr(InternetAddress.loopbackIPv4, relay.port), relay.identity.pub);
    final client = Node(identity: await Crypto.ed25519Generate(), relaySecret: randomBytes(32), port: 0);
    final n = min(200, iterations);
    for (var i = 0; i < n; i++) {
      final p = Uint8List(packetSize)..setAll(0, f.random(packetSize));
      // Sometimes aim at a live key ID so the packet reaches the full peel.
      if (i.isEven) p[0] = relay.keyring.currentCert!.keyId;
      await client.sendPacket(info, p);
    }
    final end = DateTime.now().add(const Duration(seconds: 20));
    // Rejections are counted once the worker has finished each peel.
    while (relay.stats.packetsRejected < n && DateTime.now().isBefore(end)) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    expect(relay.stats.packetsIn, n);
    expect(relay.stats.packetsRejected, n);
    expect(await client.ping(info), isTrue, reason: 'relay still serves');
    await client.stop();
    await relay.stop();
  });
}
