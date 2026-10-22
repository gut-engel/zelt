import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zelt_core/address.dart';
import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/constants.dart';
import 'package:zelt_core/crypto.dart';
import 'package:zelt_core/node.dart';
import 'package:zelt_core/onion.dart';
import 'package:zelt_core/protocol.dart';
import 'package:zelt_core/sphinx.dart';

Future<void> until(bool Function() c, {Duration max = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(max);
  while (!c()) {
    if (DateTime.now().isAfter(end)) fail('timeout');
    await Future.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('keyring keeps a current and a next key, signed and separate from the identity', () async {
    final id = await Crypto.ed25519Generate();
    final ring = OnionKeyring(id);
    final t = DateTime.now();
    await ring.maintain(now: t);
    final certs = ring.certs;
    expect(certs.length, 2);
    for (final c in certs) {
      expect(await c.verify(), isTrue);
      expect(c.onionPk, isNot(id.pub), reason: 'onion key is not the identity key');
    }
    certs.sort((a, b) => a.validFrom.compareTo(b.validFrom));
    expect(certs[0].usableAt(t), isTrue);
    expect(certs[1].validFrom.difference(certs[0].validFrom), onionKeyLifetime);
    expect(certs[0].keyId, isNot(certs[1].keyId));
  });

  test('expired keys disappear together with their replay sets', () async {
    final ring = OnionKeyring(await Crypto.ed25519Generate());
    final t = DateTime.now();
    await ring.maintain(now: t);
    final first = ring.certs.reduce((a, b) => a.validFrom.isBefore(b.validFrom) ? a : b);
    await ring.maintain(now: first.validUntil.add(const Duration(minutes: 1)));
    expect(ring.certs.any((c) => bytesEqual(c.onionPk, first.onionPk)), isFalse);
  });

  test('a full replay set retires its key early instead of evicting tags', () async {
    final ring = OnionKeyring(await Crypto.ed25519Generate(), maxTags: 3);
    await ring.maintain();
    final cur = ring.currentCert!;
    final (_, replay) = ring.lookup(cur.keyId)!;
    for (var i = 0; i < 3; i++) {
      expect(replay.checkAndAdd(randomBytes(16)), isTrue);
    }
    expect(replay.checkAndAdd(randomBytes(16)), isFalse, reason: 'full: refuse, never forget');
    await ring.maintain();
    expect(ring.certs.any((c) => bytesEqual(c.onionPk, cur.onionPk)), isFalse);
    expect(ring.currentCert, isNotNull);
  });

  test('forged certificates are rejected; a relay push replaces stale ones', () async {
    final a = await Crypto.ed25519Generate();
    final b = await Crypto.ed25519Generate();
    final store = CertStore();
    final now = DateTime.now();
    final good = await OnionKeyCert.sign(a, 1, randomBytes(32), now, now.add(const Duration(hours: 26)));
    expect(await store.add(good), isTrue);
    // B signs a key and claims it belongs to A.
    final bSigned = await OnionKeyCert.sign(b, 2, randomBytes(32), now, now.add(const Duration(hours: 26)));
    final forged = OnionKeyCert(a.pub, 2, bSigned.onionPk, bSigned.validFrom, bSigned.validUntil, bSigned.sig);
    expect(await store.add(forged), isFalse);
    final tampered = OnionKeyCert(a.pub, 1, randomBytes(32), good.validFrom, good.validUntil, good.sig);
    expect(await store.add(tampered), isFalse);
    // After a restart A pushes only its new key: the old one must go.
    final fresh = await OnionKeyCert.sign(a, 9, randomBytes(32), now, now.add(const Duration(hours: 26)));
    expect(await store.replaceFor(a.pub, [fresh]), isTrue);
    expect(store.of(a.pub).single.keyId, 9);
    expect(store.best(a.pub)!.keyId, 9);
  });

  test('a recorded packet is refused as a replay, and again after the relay restarts', () async {
    final identity = await Crypto.ed25519Generate();
    var relay = Node(identity: identity, relaySecret: randomBytes(32), port: 0, bindAddress: InternetAddress.loopbackIPv4);
    await relay.start(relay: true);
    final port = relay.port;
    final info = RelayInfo(NodeAddr(InternetAddress.loopbackIPv4, port), identity.pub);
    final client = Node(identity: await Crypto.ed25519Generate(), relaySecret: randomBytes(32), port: 0);
    final pkt = await Sphinx.forward([Hop.fromCert(info, relay.keyring.currentCert!)], dropCmd());

    await client.sendPacket(info, Uint8List.fromList(pkt));
    await until(() => relay.stats.packetsIn == 1);
    expect(relay.stats.packetsRejected, 0);
    await client.sendPacket(info, Uint8List.fromList(pkt));
    await until(() => relay.stats.packetsIn == 2);
    await until(() => relay.stats.packetsRejected == 1);

    // Restart: same identity and address, fresh onion keys.
    await relay.stop();
    await client.stop();
    relay = Node(identity: identity, relaySecret: randomBytes(32), port: port, bindAddress: InternetAddress.loopbackIPv4);
    await relay.start(relay: true);
    final client2 = Node(identity: await Crypto.ed25519Generate(), relaySecret: randomBytes(32), port: 0);
    await client2.sendPacket(info, Uint8List.fromList(pkt));
    await until(() => relay.stats.packetsIn == 1);
    await until(() => relay.stats.packetsRejected == 1, max: const Duration(seconds: 2));
    await relay.stop();
    await client2.stop();
  });

  test('switching relaying off drops connections peers already opened', () async {
    final relay = Node(identity: await Crypto.ed25519Generate(), relaySecret: randomBytes(32), port: 0, bindAddress: InternetAddress.loopbackIPv4);
    await relay.start(relay: true);
    final info = RelayInfo(NodeAddr(InternetAddress.loopbackIPv4, relay.port), relay.identity.pub);
    final client = Node(identity: await Crypto.ed25519Generate(), relaySecret: randomBytes(32), port: 0);
    expect(await client.ping(info), isTrue);
    await relay.setRelay(false);
    expect(await client.ping(info, timeout: const Duration(seconds: 2)), isFalse,
        reason: 'the old connection must not keep relaying');
    await client.stop();
    await relay.stop();
  });

  test('constants are what PROTOCOL.md states', () {
    expect(onionKeyLifetime, const Duration(hours: 24));
    expect(onionKeyOverlap, const Duration(hours: 2));
    expect(maxReplayTagsPerKey, 250000);
    expect(headerSize + payloadSize, packetSize);
  });
}
