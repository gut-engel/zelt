import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zelt_core/address.dart';
import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/constants.dart';
import 'package:zelt_core/crypto.dart';
import 'package:zelt_core/onion.dart';
import 'package:zelt_core/sphinx.dart';

Future<(List<KeyPair25519>, List<Hop>)> makeHops(int n) async {
  final keys = <KeyPair25519>[];
  final hops = <Hop>[];
  for (var i = 0; i < n; i++) {
    final k = await Crypto.x25519Generate();
    keys.add(k);
    hops.add(
      Hop(
        // Identity (link) key and onion key are distinct.
        RelayInfo(NodeAddr(InternetAddress.loopbackIPv4, 9000 + i), randomBytes(32)),
        k.pub,
        i * 7,
        delayMs: i * 10,
      ),
    );
  }
  return (keys, hops);
}

void main() {
  for (final n in [1, 3, 4, maxHops]) {
    test('forward packet through $n hops', () async {
      final (keys, hops) = await makeHops(n);
      final payload = randomBytes(payloadSize);
      var pkt = await Sphinx.forward(hops, payload);
      expect(pkt.length, packetSize);
      final seen = <String>{};
      for (var i = 0; i < n; i++) {
        seen.add(hex(pkt.sublist(0, headerSize)));
        final p = await Sphinx.peel(keys[i], pkt, ReplayFilter());
        expect(p, isNotNull, reason: 'hop $i');
        expect(p!.slot.delayMs, i * 10);
        if (i < n - 1) {
          expect(p.slot.cmd, SlotCmd.relay);
          expect(p.slot.nextAddr, hops[i + 1].relay.addr);
          expect(p.slot.nextPk, hops[i + 1].relay.nodePk);
          pkt = p.next!;
          expect(pkt.length, packetSize);
        } else {
          expect(p.slot.cmd, SlotCmd.deliver);
          expect(p.payload, payload);
        }
      }
      expect(seen.length, n, reason: 'headers must differ at every hop');
    });
  }

  test('wrong key and tampering are rejected', () async {
    final (keys, hops) = await makeHops(3);
    final pkt = await Sphinx.forward(hops, Uint8List(payloadSize));
    expect(await Sphinx.peel(keys[1], pkt, ReplayFilter()), isNull);
    final bad = Uint8List.fromList(pkt)..[100] ^= 1;
    expect(await Sphinx.peel(keys[0], bad, ReplayFilter()), isNull);

    // Payload tampering is caught by the final hop's digest.
    final p1 = await Sphinx.peel(keys[0], pkt, ReplayFilter());
    final p2 = await Sphinx.peel(keys[1], p1!.next!, ReplayFilter());
    final tampered = Uint8List.fromList(p2!.next!)..[headerSize + 5] ^= 1;
    expect(await Sphinx.peel(keys[2], tampered, ReplayFilter()), isNull);
  });

  test('a flipped payload bit after hop k garbles the payload at hop k+1 (no tagging)', () async {
    final (keys, hops) = await makeHops(4);
    final payload = randomBytes(payloadSize);
    final pkt0 = await Sphinx.forward(hops, payload);
    // Walk the honest path, keeping each hop's input packet.
    final inputs = <Uint8List>[pkt0];
    for (var i = 0; i < 3; i++) {
      inputs.add((await Sphinx.peel(keys[i], inputs[i], ReplayFilter()))!.next!);
    }
    for (var k = 0; k < 3; k++) {
      // A malicious hop k flips one payload bit in what it forwards.
      final tampered = Uint8List.fromList(inputs[k + 1])..[headerSize + 4321] ^= 0x10;
      final honest = await Sphinx.peel(keys[k + 1], inputs[k + 1], ReplayFilter());
      final bad = await Sphinx.peel(keys[k + 1], tampered, ReplayFilter());
      if (k + 1 == 3) {
        expect(bad, isNull, reason: 'last hop rejects a tampered payload');
        continue;
      }
      var same = 0;
      for (var i = 0; i < payloadSize; i++) {
        if (honest!.payload[i] == bad!.payload[i]) same++;
      }
      // Unrelated random bytes match ~1/256 of the time.
      expect(same, lessThan(payloadSize ~/ 100), reason: 'hop ${k + 1}: $same/$payloadSize bytes survived');
    }
  });

  test('replays are dropped', () async {
    final (keys, hops) = await makeHops(2);
    final pkt = await Sphinx.forward(hops, Uint8List(payloadSize));
    final rf = ReplayFilter();
    expect(await Sphinx.peel(keys[0], pkt, rf), isNotNull);
    expect(await Sphinx.peel(keys[0], pkt, rf), isNull);
  });

  test('SURB reply reaches client and decrypts', () async {
    final (keys, hops) = await makeHops(4);
    final cookie = randomBytes(8);
    final (surb, secret) = await Sphinx.surb(hops, cookie);
    final decoded = Surb.decode(surb.encode());
    expect(decoded.firstHop, hops.first.relay);

    final reply = randomBytes(payloadSize);
    var pkt = decoded.packetWith(reply);
    Peeled? p;
    for (var i = 0; i < 4; i++) {
      p = await Sphinx.peel(keys[i], pkt, ReplayFilter());
      expect(p, isNotNull);
      if (i < 3) pkt = p!.next!;
    }
    expect(p!.slot.cmd, SlotCmd.toClient);
    expect(p.slot.extra.sublist(0, 8), cookie);
    expect(p.slot.extra.sublist(8, 16), secret.id);
    expect(await Sphinx.openReply(secret, p.payload), reply);
  });
}
