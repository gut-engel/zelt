// Headless zelt peer for testing a phone over USB.
//
//   adb reverse tcp:47100 tcp:47100 (and 47101..47103)
//   dart run bin/zelt_peer.dart --state peer.json --control cmd.txt
//
// Runs one messenger and three relays on 127.0.0.1, prints its pairing code,
// and answers every incoming text with "echo: <text>". Commands are read
// from the control file, one per line:
//   pair <code>     complete pairing with the phone's code
//   send <text>     send to every paired contact
//   status          print network status
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:zelt_core/address.dart';
import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/crypto.dart';
import 'package:zelt_core/messenger.dart';
import 'package:zelt_core/models.dart';
import 'package:zelt_core/node.dart';

void out(String s) => stdout.writeln('[${DateTime.now().toIso8601String().substring(11, 19)}] $s');

Future<void> main(List<String> args) async {
  var statePath = 'zelt-peer.json';
  var controlPath = 'zelt-peer.cmd';
  var basePort = 47100;
  var localRelays = true;
  final extraPeers = <String>[];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--state':
        statePath = args[++i];
      case '--control':
        controlPath = args[++i];
      case '--port':
        basePort = int.parse(args[++i]);
      case '--client-only':
        // Behave like a phone behind NAT: no relay of our own, only --peer relays.
        localRelays = false;
      case '--peer':
        extraPeers.add(args[++i]);
    }
  }
  final lo = InternetAddress.loopbackIPv4;

  final relays = <Node>[];
  for (var i = 1; i <= (localRelays ? 3 : 0); i++) {
    final n = Node(identity: await Crypto.ed25519Generate(), relaySecret: randomBytes(32), port: basePort + i, bindAddress: lo);
    await n.start(relay: true);
    relays.add(n);
  }

  final f = File(statePath);
  final Messenger m;
  if (f.existsSync()) {
    m = await Messenger.load(jsonDecode(f.readAsStringSync()), bindAddress: lo);
  } else {
    m = Messenger(
      identity: await Identity.generate(),
      settings: Settings(name: 'PC peer', port: basePort, cover: CoverMode.off, relay: localRelays),
      bindAddress: lo,
    );
  }
  m.onSave = (s) async => f.writeAsStringSync(jsonEncode(s));
  m.onLogLine = out;
  m.onIncoming = (c, msg) {
    out('<< ${c.name}: ${msg.text}');
    m.sendText(c.id, 'echo: ${msg.text}');
  };
  await m.start();
  for (final r in relays) {
    m.addManualPeer((await r.localRelayInfos()).first);
  }
  for (final p in extraPeers) {
    m.addManualPeer(RelayInfo.parseShareString(p));
  }
  // Give the mailbox setup a moment to fetch public tokens from the relays.
  for (var i = 0; i < 40 && m.status.mailboxRelays == 0; i++) {
    await Future.delayed(const Duration(milliseconds: 500));
  }

  var session = await m.newPairingSession();
  out('PAIRCODE ${session.code}');

  final ctl = File(controlPath)..writeAsStringSync('');
  var consumed = 0;
  Timer.periodic(const Duration(milliseconds: 500), (_) async {
    final lines = ctl.readAsLinesSync();
    for (final line in lines.skip(consumed)) {
      consumed++;
      final sp = line.indexOf(' ');
      final cmd = sp < 0 ? line : line.substring(0, sp);
      final arg = sp < 0 ? '' : line.substring(sp + 1).trim();
      try {
        switch (cmd) {
          case 'pair':
            final c = await m.completePairing(session, arg);
            out('PAIRED ${c.name} safety=${c.keys.safetyNumber}');
            session = await m.newPairingSession();
            out('PAIRCODE ${session.code}');
          case 'code':
            session = await m.newPairingSession();
            out('PAIRCODE ${session.code}');
          case 'send':
            for (final c in m.contacts.values) {
              await m.sendText(c.id, arg);
              out('>> ${c.name}: $arg');
            }
          case 'status':
            final s = m.status;
            out('peers=${s.activePeers}/${s.knownPeers} mailboxes=${s.mailboxRelays} '
                'contacts=${m.contacts.values.map((c) => '${c.name}:${c.ready ? 'ready' : 'pending'}').join(',')} '
                'relayBlobs=${relays.map((r) => r.store.count).join('/')}');
            for (final c in m.contacts.values) {
              for (final msg in c.messages) {
                out('  ${msg.outgoing ? '>>' : '<<'} ${msg.text} [${msg.status.name}]');
              }
            }
        }
      } catch (e) {
        out('ERROR $cmd: $e');
      }
    }
  });
}
