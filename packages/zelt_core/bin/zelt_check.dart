// Checks that a zelt relay is reachable and holds the key in its share string.
//
//   dart run bin/zelt_check.dart zelt-relay:203.0.113.7:47017/KEY [...]
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
  final me = await Crypto.x25519Generate();
  final node = Node(key: me, relaySecret: randomBytes(32), port: 0);
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
    stdout.writeln(ok
        ? 'OK    ${r.addr}  handshake + ping in ${sw.elapsedMilliseconds} ms'
        : 'FAIL  ${r.addr}  no answer (unreachable, filtered, or wrong key)');
    if (!ok) failed++;
  }
  await node.stop();
  exit(failed == 0 ? 0 : 1);
}
