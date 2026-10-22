// Headless always-on zelt relay for a home server or VPS.
//
//   dart run bin/zelt_relay.dart [--port 47017] [--state relay.json]
//                                [--peer zelt-relay:IP:PORT/KEY ...]
//                                [--public-ip 203.0.113.7[,2001:db8::1]] (repeatable)
//
// Prints its share string; add it in the app under Settings > Network and peers > Add relay.
// Blobs are kept in RAM only. The state file holds just the node key and
// the token secret, so restarts keep the same identity.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:zelt_core/address.dart';
import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/constants.dart';
import 'package:zelt_core/crypto.dart';
import 'package:zelt_core/node.dart';

Future<void> main(List<String> args) async {
  var port = defaultPort;
  var statePath = 'zelt-relay.json';
  final publicIps = <String>[];
  final peers = <RelayInfo>[];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--port':
        port = int.parse(args[++i]);
      case '--state':
        statePath = args[++i];
      case '--peer':
        peers.add(RelayInfo.parseShareString(args[++i]));
      case '--public-ip':
        publicIps.addAll(args[++i].split(',').map((x) => x.trim()).where((x) => x.isNotEmpty));
      default:
        stderr.writeln('unknown argument ${args[i]}');
        exit(64);
    }
  }

  final f = File(statePath);
  KeyPair25519 key;
  List<int> secret;
  if (f.existsSync()) {
    final j = jsonDecode(f.readAsStringSync());
    key = KeyPair25519.fromJson(j['node']);
    secret = unb64(j['secret']);
  } else {
    key = await Crypto.x25519Generate();
    secret = randomBytes(32);
    f.writeAsStringSync(jsonEncode({'node': key.toJson(), 'secret': b64(secret)}));
  }

  final node = Node(key: key, relaySecret: unb64(b64(secret)), port: port);
  node.onLog = (m) => stdout.writeln('[${DateTime.now().toIso8601String()}] $m');
  await node.start(relay: true);

  var mine = await node.localRelayInfos();
  // With --public-ip only those addresses are advertised (container bridges
  // and private interfaces would only confuse peers).
  if (publicIps.isNotEmpty) {
    mine = [for (final ip in publicIps) RelayInfo(NodeAddr(InternetAddress(ip), node.port), key.pub)];
  }
  stdout.writeln('zelt relay running. Share strings:');
  for (final r in mine) {
    stdout.writeln('  ${r.toShareString()}');
  }

  Future<void> announce() async {
    final me = mine.firstOrNull;
    if (me == null) return;
    for (final p in {...peers, ...node.dht.all}) {
      node.dht.add(p);
      await node.announceTo(p, me);
    }
  }

  await announce();
  Timer.periodic(const Duration(minutes: 30), (_) => announce());
  Timer.periodic(const Duration(minutes: 1), (_) {
    stdout.writeln(
      'blobs=${node.store.count} bytes=${node.store.totalBytes} '
      'relayed=${node.stats.packetsRelayed} dht=${node.dht.size}',
    );
  });

  Future<void> shutdown(ProcessSignal s) async {
    stdout.writeln('stopping ($s)');
    await node.stop();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  ProcessSignal.sigterm.watch().listen(shutdown);
}
