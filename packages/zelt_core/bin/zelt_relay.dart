// Headless always-on zelt relay for a home server or VPS.
//
//   dart run bin/zelt_relay.dart [--port 47017] [--state relay.json]
//                                [--peer zelt-relay:IP:PORT/KEY ...]
//                                [--public-ip 203.0.113.7[,2001:db8::1]] (repeatable)
//                                [--stats-minutes 1]
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
import 'package:zelt_core/worker.dart';

/// Every option can also come from the environment (used by the Docker
/// image); command-line arguments win.
///   ZELT_PORT, ZELT_STATE, ZELT_PUBLIC_IP (comma-separated),
///   ZELT_PEERS (share strings, comma- or space-separated),
///   ZELT_STATS_MINUTES (0 = no periodic stats line)
Future<void> main(List<String> args) async {
  final env = Platform.environment;
  // A dedicated relay can use more cores for onion processing.
  Worker.size = int.tryParse(env['ZELT_WORKERS'] ?? '') ?? Platform.numberOfProcessors.clamp(1, 8);
  List<String> list(String? v) =>
      (v ?? '').split(RegExp(r'[,\s]+')).where((x) => x.isNotEmpty).toList();

  var port = int.tryParse(env['ZELT_PORT'] ?? '') ?? defaultPort;
  var statePath = env['ZELT_STATE'] ?? 'zelt-relay.json';
  var statsMinutes = int.tryParse(env['ZELT_STATS_MINUTES'] ?? '') ?? 1;
  final publicIps = list(env['ZELT_PUBLIC_IP']);
  final peers = <RelayInfo>[];
  for (final p in list(env['ZELT_PEERS'])) {
    try {
      peers.add(RelayInfo.parseShareString(p));
    } on FormatException catch (e) {
      stderr.writeln('ignoring bad ZELT_PEERS entry "$p": $e');
    }
  }
  var cliIps = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--port':
        port = int.parse(args[++i]);
      case '--state':
        statePath = args[++i];
      case '--peer':
        peers.add(RelayInfo.parseShareString(args[++i]));
      case '--public-ip':
        if (!cliIps) publicIps.clear();
        cliIps = true;
        publicIps.addAll(list(args[++i]));
      case '--stats-minutes':
        statsMinutes = int.parse(args[++i]);
      default:
        stderr.writeln('unknown argument ${args[i]}');
        exit(64);
    }
  }

  // State: the relay's Ed25519 identity and token secret. Onion keys are
  // never stored; they live in RAM and rotate.
  final f = File(statePath);
  SigningKey identity;
  List<int> secret;
  final j = f.existsSync() ? jsonDecode(f.readAsStringSync()) as Map<String, dynamic> : <String, dynamic>{};
  secret = j['secret'] != null ? unb64(j['secret']) : randomBytes(32);
  if (j['identity'] != null) {
    identity = SigningKey.fromJson(j['identity']);
  } else {
    identity = await Crypto.ed25519Generate();
    if (j['node'] != null) {
      stdout.writeln('Upgraded to protocol v$protocolVersion: this relay has a new identity and share string.');
    }
    f.writeAsStringSync(jsonEncode({'identity': identity.toJson(), 'secret': b64(secret)}));
    await Process.run('chmod', ['600', f.path]);
  }

  final node = Node(identity: identity, relaySecret: unb64(b64(secret)), port: port);
  node.onLog = (m) => stdout.writeln('[${DateTime.now().toIso8601String()}] $m');
  await node.start(relay: true);

  var mine = await node.localRelayInfos();
  // With --public-ip only those addresses are advertised (container bridges
  // and private interfaces would only confuse peers).
  if (publicIps.isNotEmpty) {
    mine = [for (final ip in publicIps) RelayInfo(NodeAddr(InternetAddress(ip), node.port), identity.pub)];
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
  if (statsMinutes > 0) {
    Timer.periodic(Duration(minutes: statsMinutes), (_) {
      stdout.writeln(
        'blobs=${node.store.count} bytes=${node.store.totalBytes} '
        'relayed=${node.stats.packetsRelayed} dht=${node.dht.size}',
      );
    });
  }

  Future<void> shutdown(ProcessSignal s) async {
    stdout.writeln('stopping ($s)');
    await node.stop();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  ProcessSignal.sigterm.watch().listen(shutdown);
}
