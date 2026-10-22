import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zelt_core/address.dart';
import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/constants.dart';
import 'package:zelt_core/crypto.dart';
import 'package:zelt_core/envelope.dart';
import 'package:zelt_core/models.dart';
import 'package:zelt_core/pairing.dart';
import 'package:zelt_core/peers.dart';
import 'package:zelt_core/relay_store.dart';
import 'package:zelt_core/tokens.dart';
import 'package:zelt_core/protocol.dart';
import 'package:zelt_core/sphinx.dart';
import 'package:zelt_core/vault.dart';

RelayInfo ri(String ip, [int port = 1]) =>
    RelayInfo(NodeAddr(InternetAddress(ip), port), randomBytes(32));

void main() {
  group('tokens', () {
    test('valid once, bound to blob, rejects forgery', () async {
      final issuer = TokenIssuer(randomBytes(32));
      final cred = await issuer.issue(ri('10.0.0.1'), 7);
      final h = randomBytes(32);
      final t = await cred.take(h);
      expect(await issuer.verifyAndSpend(t, h), isTrue);
      expect(await issuer.verifyAndSpend(t, h), isFalse, reason: 'spent');
      final t2 = await cred.take(h);
      expect(await issuer.verifyAndSpend(t2, randomBytes(32)), isFalse, reason: 'other blob');
      final other = await TokenIssuer(randomBytes(32)).issue(ri('10.0.0.1'), 7);
      expect(await issuer.verifyAndSpend(await other.take(h), h), isFalse);
    });

    test('carve gives disjoint ranges', () async {
      final cred = await TokenIssuer(randomBytes(32)).issue(ri('10.0.0.1'), 1);
      final a = cred.carve(10)!;
      final b = cred.carve(10)!;
      expect(a.end, b.next);
      expect(cred.next, 20);
    });
  });

  group('relay store', () {
    Uint8List blob() => randomBytes(blobSize);

    test('per-slot quota drops oldest first', () {
      final s = RelayStore();
      final mb = randomBytes(16);
      final first = blob();
      s.store(mailboxId: mb, blob: first, deleteTag: randomBytes(32), slot: 1);
      final perSlot = slotQuotaBytes ~/ blobSize;
      for (var i = 0; i < perSlot + 5; i++) {
        s.store(mailboxId: mb, blob: blob(), deleteTag: randomBytes(32), slot: 1);
      }
      expect(s.count, perSlot);
      final (got, _) = s.fetch([mb], 10000);
      expect(got.any((b) => bytesEqual(b.blob, first)), isFalse);
      // Another slot is unaffected.
      s.store(mailboxId: mb, blob: blob(), deleteTag: randomBytes(32), slot: 2);
      expect(s.count, perSlot + 1);
    });

    test('hard cap', () {
      final s = RelayStore(capBytes: blobSize * 10);
      for (var i = 0; i < 20; i++) {
        s.store(mailboxId: randomBytes(16), blob: blob(), deleteTag: randomBytes(32), slot: i);
      }
      expect(s.totalBytes, lessThanOrEqualTo(blobSize * 10));
    });

    test('delete needs the key', () {
      final s = RelayStore();
      final key = randomBytes(32);
      final mb = randomBytes(16);
      final b = blob();
      s.store(mailboxId: mb, blob: b, deleteTag: Crypto.sha256Sync(key), slot: 1);
      final h = Crypto.sha256Sync(b);
      expect(s.delete(mb, h, randomBytes(32)), isFalse);
      expect(s.delete(mb, h, key), isTrue);
      expect(s.count, 0);
    });

    test('ttl', () {
      final s = RelayStore(ttl: const Duration(milliseconds: -1));
      s.store(mailboxId: randomBytes(16), blob: blob(), deleteTag: randomBytes(32), slot: 1);
      s.expire();
      expect(s.count, 0);
    });
  });

  group('pairing', () {
    test('both sides derive matching keys and directions', () async {
      final ida = await Crypto.x25519Generate();
      final idb = await Crypto.x25519Generate();
      final ea = await Crypto.x25519Generate();
      final eb = await Crypto.x25519Generate();
      final sa = randomBytes(32);
      final sb = randomBytes(32);
      final ca = PairingCode(idPub: ida.pub, ephPub: ea.pub, seed: sa, name: 'a', relays: [ri('192.168.1.2', 47017)]);
      final cb = PairingCode(idPub: idb.pub, ephPub: eb.pub, seed: sb, name: 'b');
      final parsed = PairingCode.parse(ca.encode());
      expect(parsed.relays.single.addr.port, 47017);
      final ka = await ConversationKeys.derive(myId: ida, myEph: ea, mySeed: sa, theirs: cb);
      final kb = await ConversationKeys.derive(myId: idb, myEph: eb, mySeed: sb, theirs: parsed);
      expect(ka.rk0, kb.rk0);
      expect(ka.mboxOut, kb.mboxIn);
      expect(ka.envIn, kb.envOut);
      expect(ka.initiator, isNot(kb.initiator));
      expect(ka.safetyNumber, kb.safetyNumber);
      expect(ka.safetyNumber.replaceAll(' ', '').length, 60);
    });
  });

  test('worst-case pairing code stays a phone-scannable QR size', () async {
    final relay = RelayInfo(NodeAddr(InternetAddress('2001:db8::1'), 47017), randomBytes(32));
    final g = await TokenIssuer(randomBytes(32)).issue(relay, 3);
    final code = PairingCode(
      idPub: randomBytes(32),
      ephPub: randomBytes(32),
      seed: randomBytes(32),
      name: 'A rather long display name',
      relays: [relay, relay, relay],
      credSlot: 1,
      credEpoch: 1,
      credKey: randomBytes(32),
      grants: [g, g],
    ).encode();
    // ~1000 bytes in QR byte mode is version ~22 at level L.
    expect(code.length, lessThan(1000));
  });

  test('fetch batches: every packet fits, every mailbox ID is covered', () async {
    final ids = [for (var i = 0; i < 1000; i++) randomBytes(16)];
    final batches = fetchBatches(ids);
    expect(batches.length, (1000 / fetchMaxIds).ceil());
    expect(batches.every((b) => b.length <= fetchMaxIds), isTrue);
    expect([for (final b in batches) ...b.map(hex)], [for (final i in ids) hex(i)]);
    final k = await Crypto.x25519Generate();
    final hop = Hop(RelayInfo(NodeAddr(InternetAddress.loopbackIPv4, 1), k.pub));
    final surbs = [for (var i = 0; i < fetchSurbs; i++) (await Sphinx.surb([hop, hop, hop, hop], randomBytes(8))).$1];
    for (final b in batches) {
      final encoded = FetchCmd(surbs, b).encode(); // throws if it overflowed
      expect(encoded.length, payloadSize);
      expect(FetchCmd.decode(ByteReader(encoded.sublist(1))).mailboxIds.length, b.length);
    }
  });

  group('envelope', () {
    test('seal/open fixed size', () async {
      final k = randomBytes(32);
      final b = await Envelope.seal(k, 1, Uint8List.fromList([1, 2, 3]));
      expect(b.length, blobSize);
      final (kind, c) = (await Envelope.open(k, b))!;
      expect(kind, 1);
      expect(c, [1, 2, 3]);
      expect(await Envelope.open(randomBytes(32), b), isNull);
    });

    test('mailbox ids rotate per epoch', () async {
      final k = randomBytes(32);
      expect(hex(await Envelope.mailboxId(k, 1)), isNot(hex(await Envelope.mailboxId(k, 2))));
      expect((await Envelope.pollIds(k, DateTime.now())).length, Envelope.idsPerContact);
    });

    test('recipient polls the next epoch too (sender clock ahead)', () async {
      final k = randomBytes(32);
      final now = DateTime.now();
      final polled = {for (final id in await Envelope.pollIds(k, now)) hex(id)};
      final e = mailboxEpochOf(now);
      expect(polled, contains(hex(await Envelope.mailboxId(k, e + 1))));
      expect(polled, contains(hex(await Envelope.mailboxId(k, e - mailboxLookback))));
      expect(polled, isNot(contains(hex(await Envelope.mailboxId(k, e + 2)))));
    });
  });

  group('peers', () {
    test('diversity: at most 3 per source and per range', () {
      final pm = PeerManager();
      for (var i = 0; i < 10; i++) {
        pm.add(ri('10.1.0.$i'), 'friendA');
      }
      for (var i = 0; i < 10; i++) {
        pm.add(ri('10.${i + 2}.0.1'), 'friendB');
      }
      for (var i = 0; i < 10; i++) {
        pm.add(ri('172.${16 + i}.0.1'), 'dht');
      }
      pm.refresh();
      expect(pm.active.length, 9, reason: '3 sources x 3, all distinct ranges');
      expect(pm.lowDiversity, isFalse);
    });

    test('relaxes when too few peers exist, and says so', () {
      final pm = PeerManager();
      for (var i = 0; i < 6; i++) {
        pm.add(ri('10.1.0.$i'), 'friendA');
      }
      pm.refresh();
      expect(pm.active.length, 6);
      expect(pm.lowDiversity, isTrue);
    });

    test('failing peers drop out', () {
      final pm = PeerManager();
      final r = ri('10.1.0.1');
      pm.add(r, 'x');
      pm.refresh();
      for (var i = 0; i < 3; i++) {
        pm.markFail(r);
      }
      pm.refresh();
      expect(pm.active, isEmpty);
    });
  });

  test('vault: create, save, unlock, wrong pin, change pin', () async {
    final d = await Directory.systemTemp.createTemp('zelt');
    try {
      final v = await Vault.create(d, '1234');
      await v.save({'hello': 'world'});
      expect(await (await Vault.unlock(d, '1234')).load(), {'hello': 'world'});
      await expectLater(Vault.unlock(d, '9999'), throwsA(isA<WrongPin>()));
      await v.changePin('5678');
      expect(await (await Vault.unlock(d, '5678')).load(), {'hello': 'world'});
      final raw = await File('${d.path}/state.bin').readAsBytes();
      expect(String.fromCharCodes(raw).contains('world'), isFalse);
    } finally {
      await d.delete(recursive: true);
    }
  });

  test('identity json round trip', () async {
    final i = await Identity.generate();
    final j = Identity.fromJson(i.toJson());
    expect(j.id.pub, i.id.pub);
  });
}
