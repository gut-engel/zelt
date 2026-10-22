@Timeout(Duration(minutes: 3))
library;

import 'package:test/test.dart';
import 'package:zelt_core/address.dart';
import 'package:zelt_core/messenger.dart';
import 'package:zelt_core/node.dart';

import 'e2e_test.dart' show debugLogs, messenger, pair, relayNode, until;

/// Two phones on a home LAN (each running a relay), two more LAN relays and
/// three relays on the internet. Internet relays cannot open connections to
/// LAN addresses, like a VPS cannot reach 192.168.x.y. Every path, request
/// and reply path must respect that, or messages vanish silently.
void main() {
  late List<Node> lan;
  late List<Node> internet;
  final cleanup = <Messenger>[];
  final publicPorts = <int>{};

  bool isPublic(RelayInfo r) => publicPorts.contains(r.addr.port);

  setUp(() async {
    lan = [for (var i = 0; i < 2; i++) await relayNode()];
    internet = [for (var i = 0; i < 3; i++) await relayNode()];
    publicPorts
      ..clear()
      ..addAll(internet.map((n) => n.port));
    for (final n in internet) {
      n.canDial = isPublic;
    }
  });

  tearDown(() async {
    for (final m in cleanup) {
      await m.dispose();
    }
    cleanup.clear();
    debugLogs.clear();
    for (final n in [...lan, ...internet]) {
      await n.stop();
    }
  });

  Future<Messenger> phone(String name) async {
    final m = await messenger(name);
    m.peers.publicOverride = isPublic;
    cleanup.add(m);
    await m.start();
    for (final n in [...lan, ...internet]) {
      m.addManualPeer((await n.localRelayInfos()).first);
    }
    return m;
  }

  test('LAN phones with internet relays: every message arrives within 10 s, both ways', () async {
    final alice = await phone('alice');
    final bob = await phone('bob');
    // The phones' own relays are LAN relays too: internet relays cannot reach them.
    for (final n in internet) {
      n.canDial = (r) => isPublic(r);
    }
    final (ab, ba) = await pair(alice, bob);
    await until(() => ab.ready && ba.ready, 'handshake');

    final times = <int>[];
    for (var i = 0; i < 10; i++) {
      final from = i.isEven ? alice : bob;
      final to = i.isEven ? ba : ab;
      final text = 'msg $i';
      final sw = Stopwatch()..start();
      await from.sendText(i.isEven ? ab.id : ba.id, text);
      await until(() => to.messages.any((m) => m.text == text), 'delivery of $text', max: const Duration(seconds: 10));
      times.add(sw.elapsedMilliseconds);
    }
    // ignore: avoid_print
    print('LAN+internet delivery ms: $times');
    expect(times.every((t) => t < 10000), isTrue);
    // Receipts made it back too (reply paths work).
    await until(() => alice.outbox.isEmpty && bob.outbox.isEmpty, 'all receipts');
  });

  test('a private entry relay is replaced by a public one for internet targets', () async {
    final alice = await phone('alice');
    await until(() => alice.peers.pick(10).any(isPublic), 'a public relay verified');
    expect(isPublic(alice.peers.entryCandidates().first), isTrue,
        reason: 'a verified public relay is tried first as entry');
    expect(NodeAddr.parse('192.168.8.145:1').isPrivate, isTrue);
    expect(NodeAddr.parse('10.0.0.1:1').isPrivate, isTrue);
    expect(NodeAddr.parse('100.100.1.1:1').isPrivate, isTrue);
    expect(NodeAddr.parse('[fd00::1]:1').isPrivate, isTrue);
    expect(NodeAddr.parse('[fe80::1]:1').isPrivate, isTrue);
    expect(NodeAddr.parse('212.132.70.129:1').isPrivate, isFalse);
    expect(NodeAddr.parse('[2a01:239:2eb:8500::1]:1').isPrivate, isFalse);
  });
}
