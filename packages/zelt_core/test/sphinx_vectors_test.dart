// Sphinx-variant test vectors: fixed inputs -> fixed packet bytes.
//
// The random stream is ChaCha20 with key SHA-256("zelt sphinx v2 test vector")
// and a zero nonce, consumed in the order documented on Sphinx._header.
// Regenerate (only after an intentional format change) with:
//   ZELT_WRITE_VECTORS=1 dart test test/sphinx_vectors_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zelt_core/address.dart';
import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/constants.dart';
import 'package:zelt_core/crypto.dart';
import 'package:zelt_core/sphinx.dart';

class VectorRandom {
  final Uint8List _stream;
  int _pos = 0;
  VectorRandom(Uint8List seed) : _stream = CryptoSync.keystream(seed, 1 << 16);
  Uint8List call(int n) {
    final out = Uint8List.fromList(_stream.sublist(_pos, _pos + n));
    _pos += n;
    return out;
  }
}

Uint8List label(String s) => CryptoSync.sha256(utf8.encode(s));

const file = 'test/vectors/sphinx_v2.json';

Map<String, dynamic> build() {
  final onionKeys = [for (var i = 0; i < 4; i++) KeyPair25519.fromPrivateSync(label('onion-$i'))];
  final hops = [
    for (var i = 0; i < 4; i++)
      Hop(
        RelayInfo(NodeAddr(InternetAddress('127.0.0.${i + 1}'), 47017), label('identity-$i')),
        onionKeys[i].pub,
        10 * (i + 1),
        delayMs: 100 * (i + 1),
      ),
  ];
  final payload = CryptoSync.keystream(label('payload'), payloadSize);
  final rand = VectorRandom(label('zelt sphinx v2 test vector'));

  // Forward packet through 4 hops.
  final packet = Sphinx.forwardWith(hops, payload, rand.call);
  final steps = <Map<String, dynamic>>[];
  var cur = packet;
  for (var i = 0; i < 4; i++) {
    final (p, tag) = Sphinx.peelWith(onionKeys[i], cur)!;
    steps.add({
      'cmd': p.slot.cmd.name,
      'delayMs': p.slot.delayMs,
      'keyId': Sphinx.keyIdOf(cur),
      'nextAddr': p.slot.nextAddr?.toString(),
      'nextPk': hex(p.slot.nextPk),
      'nextEph': hex(p.slot.nextEph),
      'nextMac': hex(p.slot.nextMac),
      'extra': hex(p.slot.extra),
      'replayTag': hex(tag),
      'outSha256': p.next == null ? null : hex(CryptoSync.sha256(p.next!)),
      'payloadSha256': hex(CryptoSync.sha256(p.payload)),
    });
    if (p.next != null) cur = p.next!;
  }

  // SURB through 3 hops and a reply along it.
  final (surb, secret) = Sphinx.surbWith(hops.sublist(0, 3), label('cookie').sublist(0, 8), rand.call);
  final reply = CryptoSync.keystream(label('reply'), payloadSize);
  var rp = surb.packetWith(reply);
  final replySteps = <String>[];
  for (var i = 0; i < 3; i++) {
    final (p, _) = Sphinx.peelWith(onionKeys[i], rp)!;
    replySteps.add(hex(CryptoSync.sha256(p.next ?? p.payload)));
    if (p.next != null) rp = p.next!;
    if (i == 2) {
      expect(Sphinx.openReplyWith(secret, p.payload), reply);
    }
  }

  return {
    'description': 'zelt Sphinx v2 vectors; see header of test/sphinx_vectors_test.dart',
    'inputs': {
      'onionPrivateKeys': [for (final k in onionKeys) hex(k.priv)],
      'onionPublicKeys': [for (final k in onionKeys) hex(k.pub)],
      'keyIds': [for (final h in hops) h.keyId],
      'identities': [for (final h in hops) hex(h.relay.nodePk)],
      'addrs': [for (final h in hops) h.relay.addr.toString()],
      'delaysMs': [for (final h in hops) h.delayMs],
      'payloadSha256': hex(CryptoSync.sha256(payload)),
    },
    'forward': {'packet': hex(packet), 'hops': steps},
    'surb': {'id': hex(secret.id), 'header': hex(surb.header), 'replyHops': replySteps},
  };
}

void main() {
  test('Sphinx v2 vectors', () {
    final got = build();
    if (Platform.environment['ZELT_WRITE_VECTORS'] == '1') {
      File(file).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(got));
    }
    final want = jsonDecode(File(file).readAsStringSync());
    expect(jsonEncode(got), jsonEncode(want));
    expect((want['forward']['packet'] as String).length, packetSize * 2);
  });
}
