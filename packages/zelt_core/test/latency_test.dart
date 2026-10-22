// Delivery budget: every message must reach the recipient within 10 s, in
// every delay mode, without relying on polling (polls are pushed out to five
// minutes here, so only watches can deliver).
@Timeout(Duration(minutes: 6))
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:zelt_core/messenger.dart';
import 'package:zelt_core/models.dart';
import 'package:zelt_core/node.dart';

const budgetTimings = Timings(
  poll: Duration(minutes: 5),
  pollBackground: Duration(minutes: 5),
  tick: Duration(milliseconds: 500),
  hello: Duration(seconds: 2),
  discovery: Duration(seconds: 2),
  announce: Duration(seconds: 2),
);

Future<void> until(bool Function() c, String what, {Duration max = const Duration(seconds: 60)}) async {
  final end = DateTime.now().add(max);
  while (!c()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await Future.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  for (final (mode, hops) in [(DelayMode.normal, 4), (DelayMode.paranoid, 4), (DelayMode.paranoid, 7), (DelayMode.fast, 3)]) {
    test('${mode.name}, $hops hops: every message within ${deliveryBudget.inSeconds} s', () async {
      final relays = <Node>[];
      for (var i = 0; i < 8; i++) {
        final id = await Identity.generate();
        final n = Node(identity: id.node, relaySecret: id.relaySecret, port: 0, bindAddress: InternetAddress.loopbackIPv4);
        await n.start(relay: true);
        relays.add(n);
      }
      Future<Messenger> mk(String name, bool relay) async => Messenger(
        identity: await Identity.generate(),
        settings: Settings(name: name, relay: relay, port: 0, delay: mode, cover: CoverMode.off, hops: hops),
        timings: budgetTimings,
        bindAddress: InternetAddress.loopbackIPv4,
      );
      final alice = await mk('alice', true);
      // Bob has no relay: his mail must come from remote mailboxes.
      final bob = await mk('bob', false);
      try {
        await alice.start();
        await bob.start();
        for (final r in relays) {
          final info = (await r.localRelayInfos()).first;
          alice.addManualPeer(info);
          bob.addManualPeer(info);
        }
        final sa = await alice.newPairingSession();
        final sb = await bob.newPairingSession();
        final ab = await alice.completePairing(sa, sb.code);
        final ba = await bob.completePairing(sb, sa.code);
        await until(() => ab.ready && ba.ready, 'handshake');
        // Let watches settle on the final mailbox set.
        await Future.delayed(const Duration(seconds: 3));

        final times = <int>[];
        for (var i = 0; i < 5; i++) {
          final text = 'm$i';
          final sw = Stopwatch()..start();
          await alice.sendText(ab.id, text);
          await until(() => ba.messages.any((m) => m.text == text), 'delivery of $text', max: const Duration(seconds: 30));
          times.add(sw.elapsedMilliseconds);
          // Reply the other way, too.
          final back = 'r$i';
          final sw2 = Stopwatch()..start();
          await bob.sendText(ba.id, back);
          await until(() => ab.messages.any((m) => m.text == back), 'delivery of $back', max: const Duration(seconds: 30));
          times.add(sw2.elapsedMilliseconds);
        }
        // ignore: avoid_print
        print('${mode.name}/$hops hops delivery ms: $times  watchMisses=${relays.map((r) => r.watchMisses).toList()} '
            'served=${relays.map((r) => r.stats.watchesServed).toList()} '
            'bobMailboxes=${bob.mailboxes.length} aliceSends=${alice.logLines.where((l) => l.contains('copies stored')).length}');
        for (final t in times) {
          expect(t, lessThan(deliveryBudget.inMilliseconds), reason: 'delivery took $t ms');
        }
      } finally {
        await alice.dispose();
        await bob.dispose();
        for (final r in relays) {
          await r.stop();
        }
      }
    });
  }
}
