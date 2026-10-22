@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zelt_core/address.dart';
import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/constants.dart';
import 'package:zelt_core/messenger.dart';
import 'package:zelt_core/models.dart';
import 'package:zelt_core/node.dart';

final debugLogs = <Messenger>[];

const fastTimings = Timings(
  poll: Duration(milliseconds: 400),
  tick: Duration(milliseconds: 250),
  hello: Duration(milliseconds: 700),
  request: Duration(seconds: 2),
  retry: Duration(seconds: 3),
  discovery: Duration(seconds: 1),
  announce: Duration(seconds: 1),
  coverLowMean: Duration(milliseconds: 500),
  coverConstant: Duration(milliseconds: 50),
);

Future<void> until(bool Function() cond, String what, {Duration max = const Duration(seconds: 40)}) async {
  final end = DateTime.now().add(max);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) {
      for (final m in debugLogs) {
        // ignore: avoid_print
        print(m.logLines.join("\n"));
        // ignore: avoid_print
        print([for (final o in m.outbox) '${o.id.substring(0, 6)} pending=${o.pending != null} attempts=${o.attempts} copies=${o.copies.length}']);
      }
      fail("timed out waiting for $what");
    }
    await Future.delayed(const Duration(milliseconds: 100));
  }
}

Future<Node> relayNode() async {
  final id = await Identity.generate();
  final n = Node(
    key: id.node,
    relaySecret: id.relaySecret,
    port: 0,
    bindAddress: InternetAddress.loopbackIPv4,
  );
  await n.start(relay: true);
  return n;
}

Future<Messenger> messenger(String name, {bool relay = true, CoverMode cover = CoverMode.off}) async {
  final m = Messenger(
    identity: await Identity.generate(),
    settings: Settings(name: name, relay: relay, port: 0, delay: DelayMode.fast, cover: cover, hops: 4),
    timings: fastTimings,
    bindAddress: InternetAddress.loopbackIPv4,
  );
  debugLogs.add(m);
  return m;
}

Future<(Contact, Contact)> pair(Messenger a, Messenger b) async {
  final sa = await a.newPairingSession();
  final sb = await b.newPairingSession();
  final ab = await a.completePairing(sa, sb.code);
  final ba = await b.completePairing(sb, sa.code);
  return (ab, ba);
}

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

  Future<void> addRelays(Messenger m) async {
    for (final r in relays) {
      m.addManualPeer((await r.localRelayInfos()).first);
    }
  }

  test('two relay-capable phones: handshake, message, receipt, reply', () async {
    final alice = await messenger('alice');
    final bob = await messenger('bob');
    cleanup.addAll([alice, bob]);
    await alice.start();
    await bob.start();
    await addRelays(alice);
    await addRelays(bob);

    final (ab, ba) = await pair(alice, bob);
    expect(ab.keys.safetyNumber, ba.keys.safetyNumber);
    expect(ab.name, 'bob');

    await until(() => ab.ready && ba.ready, 'handshake');
    expect(ab.keys.initiator, isNot(ba.keys.initiator));

    final m = await alice.sendText(ab.id, 'hello bob');
    await until(() => ba.messages.any((x) => x.text == 'hello bob'), 'bob receives');
    await until(() => m.status == MsgStatus.delivered, 'receipt to alice');
    expect(ba.messages.where((x) => x.text == 'hello bob').length, 1, reason: 'dedup of 3 copies');

    await bob.sendText(ba.id, 'hi alice');
    await until(() => ab.messages.any((x) => x.text == 'hi alice'), 'alice receives');

    // A burst, received exactly once each.
    for (var i = 0; i < 5; i++) {
      await alice.sendText(ab.id, 'burst $i');
    }
    await until(() => ba.messages.where((x) => x.text.startsWith('burst')).length == 5, 'burst');
    await Future.delayed(const Duration(seconds: 2));
    expect(ba.messages.where((x) => x.text.startsWith('burst')).length, 5);
    await until(() => alice.outbox.where((o) => o.needsReceipt && !o.handshake).isEmpty, 'outbox drained');
  });

  test('phone without inbound reachability uses friend and public relays', () async {
    final alice = await messenger('alice');
    final bob = await messenger('bob', relay: false);
    cleanup.addAll([alice, bob]);
    await alice.start();
    await bob.start();
    await addRelays(alice);
    await addRelays(bob);

    final (ab, ba) = await pair(alice, bob);
    await until(() => ab.ready && ba.ready, 'handshake');

    await alice.sendText(ab.id, 'to natted bob');
    await until(() => ba.messages.any((x) => x.text == 'to natted bob'), 'bob receives');
    final r = await bob.sendText(ba.id, 'from natted bob');
    await until(() => ab.messages.any((x) => x.text == 'from natted bob'), 'alice receives');
    await until(() => r.status == MsgStatus.delivered, 'receipt to bob');
    expect(bob.mailboxes.values.any((m) => m.own), isFalse);
  });

  test('constant-rate cover traffic still delivers', () async {
    final alice = await messenger('alice', cover: CoverMode.constant);
    final bob = await messenger('bob', cover: CoverMode.constant);
    cleanup.addAll([alice, bob]);
    await alice.start();
    await bob.start();
    await addRelays(alice);
    await addRelays(bob);
    final (ab, ba) = await pair(alice, bob);
    await until(() => ab.ready && ba.ready, 'handshake');
    await alice.sendText(ab.id, 'covered');
    await until(() => ba.messages.any((x) => x.text == 'covered'), 'delivery under cover');
    final relayed = relays.fold(0, (n, r) => n + r.stats.packetsIn);
    expect(relayed, greaterThan(20));
  });

  test('state survives a restart', () async {
    final alice = await messenger('alice');
    var bob = await messenger('bob');
    cleanup.add(alice);
    await alice.start();
    await bob.start();
    await addRelays(alice);
    await addRelays(bob);
    final (ab, ba) = await pair(alice, bob);
    await until(() => ab.ready && ba.ready, 'handshake');

    await bob.stop();
    final saved = bob.toJson();
    await alice.sendText(ab.id, 'while you were away');
    await Future.delayed(const Duration(seconds: 1));

    bob = Messenger.fromJson(saved, timings: fastTimings, bindAddress: InternetAddress.loopbackIPv4);
    cleanup.add(bob);
    await bob.start();
    final ba2 = bob.contacts[ba.id]!;
    await until(() => ba2.messages.any((x) => x.text == 'while you were away'), 'delivery after restart');
    expect(ba2.ready, isTrue);
  });

  test('peer discovery through the DHT', () async {
    final alice = await messenger('alice');
    cleanup.add(alice);
    await alice.start();
    // Relays know each other via announcements.
    for (final r in relays) {
      for (final o in relays) {
        if (r != o) r.dht.add((await o.localRelayInfos()).first);
      }
    }
    alice.addManualPeer((await relays.first.localRelayInfos()).first);
    alice.addManualPeer((await relays[1].localRelayInfos()).first);
    await until(() => alice.peers.known.length >= 5, 'dht discovery');
    expect(alice.peers.known.values.where((p) => p.sources.contains('dht')).length, greaterThanOrEqualTo(3));
  });

  test('clean shutdown hands relay blobs to partners', () async {
    final alice = await messenger('alice');
    cleanup.add(alice);
    await alice.start();
    await addRelays(alice);
    await until(() => alice.peers.known.values.where((p) => p.lastOk != null).length >= 2, 'peer health');
    final mb = randomBytes(16);
    for (var i = 0; i < 4; i++) {
      alice.node.store.store(mailboxId: mb, blob: randomBytes(blobSize), deleteTag: randomBytes(32), slot: 1);
    }
    await alice.stop(handoff: true);
    await until(() => relays.fold(0, (n, r) => n + r.store.fetch([mb], 100).$1.length) == 4, 'handoff');
    final holders = relays.where((r) => r.store.fetch([mb], 100).$1.isNotEmpty).length;
    expect(holders, 2, reason: 'spread over two partners, not one bulk transfer');
  });

  test('a dead mailbox relay does not hold up delivery from a working one', () async {
    final alice = await messenger('alice');
    final bob = await messenger('bob');
    cleanup.addAll([alice, bob]);
    await alice.start();
    await bob.start();
    await addRelays(alice);
    await addRelays(bob);
    final (ab, ba) = await pair(alice, bob);
    await until(() => ab.ready && ba.ready, 'handshake');
    // A mailbox Bob still polls but which never answers (nothing listens there).
    final dead = RelayInfo(NodeAddr(InternetAddress.loopbackIPv4, 9), randomBytes(32));
    bob.mailboxes[dead.id] = MailboxRecord(dead);
    for (var i = 0; i < 3; i++) {
      await alice.sendText(ab.id, 'through the dead one $i');
      await until(
        () => ba.messages.any((x) => x.text == 'through the dead one $i'),
        'delivery $i',
        max: const Duration(seconds: 6),
      );
    }
  });

  test('friends sync relays, and relays are never forgotten', () async {
    final alice = await messenger('alice');
    final bob = await messenger('bob');
    cleanup.addAll([alice, bob]);
    await alice.start();
    await bob.start();
    // Alice knows all relays, Bob only the first two.
    await addRelays(alice);
    for (final r in relays.take(2)) {
      bob.addManualPeer((await r.localRelayInfos()).first);
    }
    final (ab, ba) = await pair(alice, bob);
    await until(() => ab.ready && ba.ready, 'handshake');
    // A relay Alice has reached (only verified relays are shared) and Bob
    // was never told about directly.
    final bobInitial = {for (final r in relays.take(2)) (await r.localRelayInfos()).first.key};
    await until(
      () => alice.peers.shareable(24).any((r) => !bobInitial.contains(r.key)),
      'alice verifies a relay bob lacks',
    );
    final extra = alice.peers.shareable(24).firstWhere((r) => !bobInitial.contains(r.key));
    await until(() => bob.peers.known.containsKey(extra.key), 'bob learns alice\'s relays');
    expect(bob.peers.known[extra.key]!.sources, contains('via:${ba.id}'));

    // A relay Alice adds later reaches Bob too.
    final late = await relayNode();
    relays.add(late);
    final lateInfo = (await late.localRelayInfos()).first;
    alice.addManualPeer(lateInfo);
    await until(() => bob.peers.known.containsKey(lateInfo.key), 'late relay synced', max: const Duration(seconds: 20));

    // Deleting the contact keeps its relays in the history.
    final before = bob.peers.known.length;
    bob.deleteContact(ba.id);
    expect(bob.peers.known.length, before);
    expect(bob.peers.known[extra.key]!.sources, contains('history'));
  });

  test('with every peer failing, the relay history is probed until one answers', () async {
    final alice = await messenger('alice');
    cleanup.add(alice);
    await alice.start();
    await addRelays(alice);
    await until(() => alice.peers.pick(1).isNotEmpty, 'verified peers');
    for (final rec in alice.peers.known.values) {
      rec.failures = 9;
      rec.lastFail = DateTime.now();
      rec.lastOk = null;
    }
    alice.peers.refresh();
    expect(alice.peers.pick(1), isEmpty);
    await until(() => alice.peers.pick(1).isNotEmpty, 'recovered from history', max: const Duration(seconds: 10));
  });

  test('share string round trip', () async {
    final r = (await relays.first.localRelayInfos()).first;
    expect(RelayInfo.parseShareString(r.toShareString()), r);
  });
}
