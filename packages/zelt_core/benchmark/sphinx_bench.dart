// Relay hot path throughput: dart run benchmark/sphinx_bench.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:zelt_core/address.dart';
import 'package:zelt_core/constants.dart';
import 'package:zelt_core/crypto.dart';
import 'package:zelt_core/onion.dart';
import 'package:zelt_core/sphinx.dart';

Future<void> main() async {
  final keys = [for (var i = 0; i < 4; i++) await Crypto.x25519Generate()];
  final hops = [
    for (var i = 0; i < 4; i++)
      Hop(RelayInfo(NodeAddr(InternetAddress.loopbackIPv4, 9000 + i), keys[i].pub), keys[i].pub, i),
  ];
  final payload = Uint8List(payloadSize);
  // Warm up the worker and JIT/AOT caches.
  for (var i = 0; i < 20; i++) {
    await Sphinx.peel(keys[0], await Sphinx.forward(hops, payload), ReplayFilter());
  }

  const n = 300;
  final pkts = [for (var i = 0; i < n; i++) await Sphinx.forward(hops, payload)];

  var sw = Stopwatch()..start();
  for (var i = 0; i < 100; i++) {
    await Sphinx.forward(hops, payload);
  }
  final buildMs = sw.elapsedMicroseconds / 100 / 1000;

  final rf = ReplayFilter();
  sw = Stopwatch()..start();
  for (final p in pkts) {
    await Sphinx.peel(keys[0], p, rf);
  }
  final seq = n / (sw.elapsedMicroseconds / 1e6);

  final rf2 = ReplayFilter();
  final pkts2 = [for (var i = 0; i < n; i++) await Sphinx.forward(hops, payload)];
  sw = Stopwatch()..start();
  await Future.wait([for (final p in pkts2) Sphinx.peel(keys[0], p, rf2)]);
  final par = n / (sw.elapsedMicroseconds / 1e6);

  stdout.writeln('build 4-hop packet: ${buildMs.toStringAsFixed(2)} ms');
  stdout.writeln('peel sequential:    ${seq.toStringAsFixed(0)} packets/s');
  stdout.writeln('peel concurrent:    ${par.toStringAsFixed(0)} packets/s');
  exit(0);
}
