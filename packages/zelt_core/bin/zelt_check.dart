// Checks that a zelt relay is reachable and holds the key in its share string.
//
//   dart run bin/zelt_check.dart zelt-relay:IP:PORT/KEY [...]
//
// For each relay: TCP connect, encrypted link handshake (only the holder of
// the node key can complete it), and a ping round trip. Exit code 0 when all
// relays answer.
import 'dart:io';

import 'package:zelt_core/address.dart';
import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/crypto.dart';
import 'package:zelt_core/node.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: zelt_check zelt-relay:IP:PORT/KEY [...]');
    exit(64);
  }
  final node = Node(identity: await Crypto.ed25519Generate(), relaySecret: randomBytes(32), port: 0);
  var failed = 0;
  for (final a in args) {
    final RelayInfo r;
    try {
      r = RelayInfo.parseShareString(a);
    } on FormatException catch (e) {
      stdout.writeln('BAD   $a ($e)');
      failed++;
      continue;
    }
    final sw = Stopwatch()..start();
    final ok = await node.ping(r, timeout: const Duration(seconds: 8));
    // The relay pushes its onion-key certificates right after the handshake.
    for (var i = 0; ok && i < 20 && node.certs.best(r.nodePk) == null; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    final cert = node.certs.best(r.nodePk);
    stdout.writeln(ok
        ? 'OK    ${r.addr}  identity verified, ping ${sw.elapsedMilliseconds} ms, '
            '${cert == null ? 'NO onion key' : 'onion key valid until ${cert.validUntil.toUtc()}'}'
        : 'FAIL  ${r.addr}  no answer (unreachable, filtered, wrong identity, or old protocol)');
    if (!ok) failed++;
  }
  await node.stop();
  exit(failed == 0 ? 0 : 1);
}
