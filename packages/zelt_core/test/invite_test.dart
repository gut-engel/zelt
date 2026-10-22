@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:zelt_core/invite.dart';
import 'package:zelt_core/messenger.dart';
import 'package:zelt_core/node.dart';

import 'e2e_test.dart' show debugLogs, fastTimings, messenger, relayNode, until;

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

  Future<Messenger> up(String name, {bool relay = true}) async {
    final m = await messenger(name, relay: relay);
    cleanup.add(m);
    await m.start();
    for (final r in relays) {
      m.addManualPeer((await r.localRelayInfos()).first);
    }
    return m;
  }

  /// Waits until [m] can hand out mailboxes (own relay or held grants).
  Future<PendingInvite> inviteFrom(Messenger m) async {
    final end = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      try {
        return await m.createInvite();
      } on StateError {
        if (DateTime.now().isAfter(end)) rethrow;
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }
  }

  test('invite text: friend joins, both sides talk; the invite is gone afterwards', () async {
    // The inviter runs no relay, like a phone behind CGNAT.
    final alice = await up('alice', relay: false);
    final bob = await up('bob');
    final inv = await inviteFrom(alice);
    expect(inv.text, startsWith(InviteCode.prefix));
    expect(InviteCode.parse(inv.text).expiresAt.difference(DateTime.now()).inMinutes, inInclusiveRange(14, 15));

    final t0 = DateTime.now();
    final ba = await bob.acceptInvite(inv.text);
    await until(() => alice.contacts.length == 1, 'alice accepts the join request');
    final ab = alice.contacts.values.single;
    expect(ab.name, 'bob');
    expect(ba.name, 'alice');
    await until(() => ab.ready && ba.ready, 'handshake');
    expect(DateTime.now().difference(t0), lessThan(const Duration(seconds: 10)));
    expect(alice.invites, isEmpty);
    expect(ab.keys.safetyNumber, ba.keys.safetyNumber);

    await bob.sendText(ba.id, 'hi alice');
    await until(() => ab.messages.any((m) => m.text == 'hi alice'), 'bob -> alice');
    await alice.sendText(ab.id, 'hi bob');
    await until(() => ba.messages.any((m) => m.text == 'hi bob'), 'alice -> bob');
    await until(() => ba.pendingJoin == null, 'join request retired');
  });

  test('one activation only: two people racing with the same text, then a third', () async {
    final alice = await up('alice');
    final bob = await up('bob');
    final carol = await up('carol');
    final dave = await up('dave');
    final inv = await inviteFrom(alice);

    final both = await Future.wait([bob.acceptInvite(inv.text), carol.acceptInvite(inv.text)]);
    await until(() => alice.contacts.length == 1, 'one join accepted');
    final winner = alice.contacts.values.single;
    final joiner = winner.name == 'bob' ? both[0] : both[1];
    final loser = winner.name == 'bob' ? both[1] : both[0];
    await until(() => winner.ready && joiner.ready, 'winner handshake');

    final late = await dave.acceptInvite(inv.text);
    // Give the losers' join requests plenty of time to arrive and be ignored.
    await Future.delayed(const Duration(seconds: 4));
    expect(alice.contacts.length, 1, reason: 'only the first activation counts');
    expect(loser.ready, isFalse);
    expect(late.ready, isFalse);
    expect(alice.invites, isEmpty);
  });

  test('both scan each other at the same moment: one link, both sides agree', () async {
    final alice = await up('alice');
    final bob = await up('bob');
    final ia = await inviteFrom(alice);
    final ib = await inviteFrom(bob);
    await Future.wait([alice.acceptInvite(ib.text), bob.acceptInvite(ia.text)]);
    await until(() => alice.contacts.length == 1 && bob.contacts.length == 1, 'contacts');
    final ab = alice.contacts.values.single;
    final ba = bob.contacts.values.single;
    await until(() => alice.contacts.values.single.ready && bob.contacts.values.single.ready, 'handshake');
    expect(alice.contacts.values.single.keys.rk0, bob.contacts.values.single.keys.rk0);
    await alice.sendText(ab.id, 'one link');
    await until(() => bob.contacts.values.single.messages.any((m) => m.text == 'one link'), 'alice -> bob');
    await bob.sendText(ba.id, 'agreed');
    await until(() => alice.contacts.values.single.messages.any((m) => m.text == 'agreed'), 'bob -> alice');
    // The pairing screen cancels its own unused invite once linked.
  });

  test('an invite stops working when it expires, also across a restart', () async {
    var alice = await up('alice');
    final bob = await up('bob');
    final inv = await alice.createInvite(validity: const Duration(seconds: 3));

    // The inviter is offline until after the expiry; the join request waits
    // on its relay meanwhile.
    await alice.stop();
    final saved = alice.toJson();
    cleanup.remove(alice);
    await alice.dispose();
    final ba = await bob.acceptInvite(inv.text);
    await Future.delayed(const Duration(seconds: 4));

    alice = await Messenger.load(saved, timings: fastTimings, bindAddress: InternetAddress.loopbackIPv4);
    cleanup.add(alice);
    await alice.start();
    await Future.delayed(const Duration(seconds: 4));
    expect(alice.contacts, isEmpty, reason: 'expired before it was used');
    expect(alice.invites, isEmpty);
    expect(ba.ready, isFalse);

    // The joiner's side refuses an expired text outright.
    await expectLater(bob.acceptInvite(inv.text), throwsA(isA<FormatException>()));
  });

  test('an open invite survives an app restart', () async {
    var alice = await up('alice');
    final bob = await up('bob');
    final inv = await inviteFrom(alice);
    await alice.stop();
    final saved = alice.toJson();
    cleanup.remove(alice);
    await alice.dispose();
    alice = await Messenger.load(saved, timings: fastTimings, bindAddress: InternetAddress.loopbackIPv4);
    cleanup.add(alice);
    await alice.start();

    final ba = await bob.acceptInvite(inv.text);
    await until(() => alice.contacts.length == 1, 'join accepted after restart');
    await until(() => alice.contacts.values.single.ready && ba.ready, 'handshake');
  });

  test('invite text parsing: whitespace is ignored, QR codes and garbage are rejected', () async {
    final alice = await up('alice');
    final inv = await inviteFrom(alice);
    final wrapped = inv.text.replaceAllMapped(RegExp('.{40}'), (m) => '${m[0]}\n  ');
    expect(InviteCode.parse(wrapped).inviteId, inv.inviteId);
    final qr = (await alice.newPairingSession()).code;
    expect(() => InviteCode.parse(qr), throwsA(isA<FormatException>()));
    expect(() => InviteCode.parse('${inv.text}AAAA'), throwsA(isA<FormatException>()));
    expect(() => InviteCode.parse('hello'), throwsA(isA<FormatException>()));
    alice.cancelInvite(inv.id);
    expect(alice.invites, isEmpty);
  });
}
