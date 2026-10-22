import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zelt_core/address.dart';
import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/constants.dart';
import 'package:zelt_core/crypto.dart';
import 'package:zelt_core/envelope.dart';
import 'package:zelt_core/messenger.dart';
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

    test('carve hands out aligned, disjoint power-of-two blocks', () async {
      final cred = await TokenIssuer(randomBytes(32)).issue(ri('10.0.0.1'), 1);
      cred.next = 5; // unaligned position
      final a = cred.carve(16)!;
      final b = cred.carve(16)!;
      expect((a.next, a.end), (16, 32), reason: 'aligned to its size');
      expect((b.next, b.end), (32, 48));
      expect(a.nodes.length, 1, reason: 'one subtree key');
      expect(cred.next, 48);
      expect(() => cred.carve(10), throwsArgumentError);
    });

    test('delegated tokens verify, including nested delegation', () async {
      final issuer = TokenIssuer(randomBytes(32));
      final root = await issuer.issue(ri('10.0.0.1'), 3);
      final mid = root.carve(256)!; // [0, 256)
      final leaf = mid.carve(64)!; // [0, 64) of mid
      for (final c in [root, mid, leaf]) {
        final h = randomBytes(32);
        expect(await issuer.verifyAndSpend(await c.take(h), h), isTrue);
      }
    });

    test('a delegated range cannot produce tokens outside it', () async {
      final issuer = TokenIssuer(randomBytes(32));
      final root = await issuer.issue(ri('10.0.0.1'), 7);
      root.next = 64;
      final d = root.carve(64)!; // [64, 128)
      expect((d.next, d.end), (64, 128));

      // 1. Editing the range fields does not give the keys.
      final widened = Credential(d.relay, d.slot, d.epoch, d.nodes, next: 200, end: 4096);
      await expectLater(widened.take(randomBytes(32)), throwsStateError);

      // 2. Using any key the holder has, or can derive, for index 200.
      final h = randomBytes(32);
      final candidates = <Uint8List>[
        for (final n in d.nodes) n.key,
        for (final n in d.nodes) ...[for (var i = n.start; i < n.end; i++) tokenLeafKey(n.key, i)],
      ];
      for (final k in candidates.take(200)) {
        final mac = await Crypto.hmac(k, [0, 200, ...h]);
        expect(await issuer.verifyAndSpend(Token(7, d.epoch, 200, mac.sublist(0, 16)), h), isFalse);
      }
      // 3. Its own range still works.
      final ok = randomBytes(32);
      expect(await issuer.verifyAndSpend(await d.take(ok), ok), isTrue);
    });

    test('credential encoding and saved formats round-trip', () async {
      final issuer = TokenIssuer(randomBytes(32));
      final c = (await issuer.issue(ri('10.0.0.1'), 9)).carve(128)!;
      final back = Credential.decode(ByteReader(c.encode()));
      expect((back.next, back.end, back.nodes.length), (c.next, c.end, c.nodes.length));
      final json = Credential.fromJson(c.toJson());
      final h = randomBytes(32);
      expect(await issuer.verifyAndSpend(await json.take(h), h), isTrue);
      // Saved before the key tree: {k: slot key}.
      final slotKey = await issuer.keyFor(9, c.epoch);
      final legacy = Credential.fromJson({
        'r': c.relay.toJson(), 's': 9, 'e': c.epoch, 'k': b64(slotKey), 'n': 300, 'x': 400,
      });
      final h2 = randomBytes(32);
      final t = await legacy.take(h2);
      expect(t.index, 300);
      expect(await issuer.verifyAndSpend(t, h2), isTrue);
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
    final hop = Hop(RelayInfo(NodeAddr(InternetAddress.loopbackIPv4, 1), randomBytes(32)), k.pub, 1);
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

    test('mailbox ids rotate per epoch and differ per relay', () async {
      final k = randomBytes(32);
      final r1 = randomBytes(32);
      final r2 = randomBytes(32);
      expect(hex(await Envelope.mailboxId(k, 1, r1)), isNot(hex(await Envelope.mailboxId(k, 2, r1))));
      expect(hex(await Envelope.mailboxId(k, 1, r1)), isNot(hex(await Envelope.mailboxId(k, 1, r2))));
      expect((await Envelope.pollIds(k, DateTime.now(), r1)).length, Envelope.idsPerContact);
    });

    test('the same inner content seals to different blobs per copy', () async {
      final k = randomBytes(32);
      final inner = Envelope.inner(Envelope.kindRatchet, randomBytes(500));
      final a = await Envelope.sealInner(k, inner);
      final b = await Envelope.sealInner(k, inner);
      expect(hex(a), isNot(hex(b)));
      final (ka, ca) = (await Envelope.open(k, a))!;
      final (kb, cb) = (await Envelope.open(k, b))!;
      expect(Envelope.inner(ka, ca), Envelope.inner(kb, cb));
    });

    test('recipient polls the next epoch too (sender clock ahead)', () async {
      final k = randomBytes(32);
      final now = DateTime.now();
      final r = randomBytes(32);
      final polled = {for (final id in await Envelope.pollIds(k, now, r)) hex(id)};
      final e = mailboxEpochOf(now);
      expect(polled, contains(hex(await Envelope.mailboxId(k, e + 1, r))));
      expect(polled, contains(hex(await Envelope.mailboxId(k, e - mailboxLookback, r))));
      expect(polled, isNot(contains(hex(await Envelope.mailboxId(k, e + 2, r)))));
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

    test('last-resort probing: bounded batches, every relay each pass, random order', () {
      final pm = PeerManager();
      for (var i = 0; i < 20; i++) {
        pm.add(ri('10.${i + 1}.0.1'), 'history');
      }
      List<String> pass() {
        final seen = <String>[];
        while (seen.length < 20) {
          final b = pm.lastResort(10);
          expect(b.length, lessThanOrEqualTo(PeerManager.maxResortBatch));
          seen.addAll(b.map((r) => r.key));
        }
        return seen;
      }
      final p1 = pass();
      final p2 = pass();
      expect(p1.toSet().length, 20, reason: 'whole history covered in a pass');
      expect(p2.toSet().length, 20);
      expect(p1, isNot(p2), reason: 'a fresh random order every pass');
    });

    test('last-resort backoff doubles from ~5 s to ~5 min with jitter', () {
      final rng = Random(1);
      for (var i = 0; i < 50; i++) {
        final d0 = Messenger.resortDelay(0, rng).inMilliseconds;
        expect(d0, inInclusiveRange(4000, 6000));
        final dMax = Messenger.resortDelay(30, rng).inMilliseconds;
        expect(dMax, inInclusiveRange(240000, 360000));
      }
      expect(Messenger.resortDelay(3, Random(2)).inMilliseconds, greaterThan(Messenger.resortDelay(1, Random(2)).inMilliseconds));
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

  group('vault v2 (hardware-bound) and lockout', () {
    late Directory d;
    setUp(() async => d = await Directory.systemTemp.createTemp('zelt'));
    tearDown(() async => d.delete(recursive: true));

    Map<String, dynamic> meta() => jsonDecode(File('${d.path}/vault.json').readAsStringSync());
    void writeMeta(Map<String, dynamic> m) => File('${d.path}/vault.json').writeAsStringSync(jsonEncode(m));

    test('a copied vault cannot be opened without this device\'s hardware key', () async {
      final hw = FakeHardware();
      final v = await Vault.create(d, 'correct horse', hardware: hw);
      await v.save({'secret': 1});
      expect(Vault.formatOf(d), 'v2 (tee)');
      expect(await (await Vault.unlock(d, 'correct horse', hardware: hw)).load(), {'secret': 1});
      // Same files, other device: right PIN, wrong hardware key.
      await expectLater(Vault.unlock(d, 'correct horse', hardware: FakeHardware()), throwsA(isA<WrongPin>()));
      await expectLater(Vault.unlock(d, 'correct horse'), throwsStateError);
    });

    test('escalating delays after 4 wrong PINs, persisted, blocking even the right PIN', () async {
      final hw = FakeHardware();
      await Vault.create(d, '123456', hardware: hw);
      for (var i = 0; i < Vault.freeAttempts; i++) {
        await expectLater(Vault.unlock(d, 'wrong', hardware: hw), throwsA(isA<WrongPin>()));
      }
      expect(Vault.lockedUntil(d), isNull);
      await expectLater(Vault.unlock(d, 'wrong', hardware: hw), throwsA(isA<WrongPin>()));
      final until = Vault.lockedUntil(d)!;
      expect(until.difference(DateTime.now()).inSeconds, inInclusiveRange(25, 30));
      await expectLater(Vault.unlock(d, '123456', hardware: hw), throwsA(isA<LockedOut>()));
      // Survives a restart: the state is in vault.json.
      expect(meta()['failed'], 5);
      // Once the delay has passed, the right PIN works and resets the counter.
      writeMeta(meta()..['lockUntil'] = DateTime.now().subtract(const Duration(seconds: 1)).millisecondsSinceEpoch);
      await Vault.unlock(d, '123456', hardware: hw);
      expect(meta()['failed'], 0);
      expect(Vault.lockedUntil(d), isNull);
    });

    test('parallel guesses cannot share one attempt count', () async {
      final hw = FakeHardware();
      await Vault.create(d, '123456', hardware: hw);
      final results = await Future.wait([
        for (var i = 0; i < 8; i++) Vault.unlock(d, 'guess$i', hardware: hw).then((_) => 'ok').catchError((Object e) => e.runtimeType.toString()),
      ]);
      expect(results.where((r) => r == 'ok'), isEmpty);
      // Serialised: 5 wrong guesses are counted, then the rest hit the lockout.
      expect(results.where((r) => r == 'WrongPin').length, Vault.freeAttempts + 1);
      expect(results.where((r) => r == 'LockedOut').length, 8 - Vault.freeAttempts - 1);
      expect(meta()['failed'], Vault.freeAttempts + 1);
    });

    test('an attempt is counted before the PIN is checked (killing the app does not help)', () async {
      final gate = Completer<void>();
      final hw = GatedHardware(gate.future);
      await Vault.create(d, '123456', hardware: hw);
      for (var i = 0; i < Vault.freeAttempts; i++) {
        await expectLater(Vault.unlock(d, 'w$i', hardware: hw.open), throwsA(isA<WrongPin>()));
      }
      final pending = Vault.unlock(d, 'still checking', hardware: hw);
      await Future.delayed(const Duration(milliseconds: 100));
      // Mid-check (the app could be killed here): already counted and locked.
      expect(meta()['failed'], Vault.freeAttempts + 1);
      expect(Vault.lockedUntil(d), isNotNull);
      gate.complete();
      await expectLater(pending, throwsA(isA<WrongPin>()));
    });

    test('delay schedule', () {
      expect(Vault.delayAfter(4), Duration.zero);
      expect(Vault.delayAfter(5), const Duration(seconds: 30));
      expect(Vault.delayAfter(6), const Duration(seconds: 60));
      expect(Vault.delayAfter(11), const Duration(seconds: 1920));
      expect(Vault.delayAfter(12), Vault.maxDelay, reason: '3840 s would exceed the 1 h cap');
      expect(Vault.delayAfter(40), Vault.maxDelay);
    });

    test('a v1 vault is bound to the hardware key on the next unlock', () async {
      final v = await Vault.create(d, '123456');
      await v.save({'x': 2});
      expect(Vault.formatOf(d), 'v1 (PIN only)');
      final hw = FakeHardware();
      expect(await (await Vault.unlock(d, '123456', hardware: hw)).load(), {'x': 2});
      expect(Vault.formatOf(d), 'v2 (tee)');
      await expectLater(Vault.unlock(d, '123456'), throwsStateError);
      final again = await Vault.unlock(d, '123456', hardware: hw);
      await again.changePin('654321');
      expect(await (await Vault.unlock(d, '654321', hardware: hw)).load(), {'x': 2});
      expect(Vault.formatOf(d), 'v2 (tee)');
    });
  });

  test('identity json round trip', () async {
    final i = await Identity.generate();
    final j = await Identity.load(i.toJson());
    expect(j.id.pub, i.id.pub);
    expect(j.node.pub, i.node.pub);
  });

  test('a v1 identity (X25519 node key) migrates to a new Ed25519 relay identity', () async {
    final i = await Identity.generate();
    final v1 = {'id': i.id.toJson(), 'node': (await Crypto.x25519Generate()).toJson(), 'rs': b64(i.relaySecret)};
    final j = await Identity.load(v1);
    expect(j.id.pub, i.id.pub);
    expect(j.node.pub.length, 32);
    expect(await Crypto.ed25519Verify(j.node.pub, [1, 2, 3], await Crypto.ed25519Sign(j.node, [1, 2, 3])), isTrue);
  });
}

/// Stands in for the Android Keystore: a key that exists only in this object.
class FakeHardware implements HardwareKeyWrapper {
  final Uint8List _key = randomBytes(32);
  @override
  String get kind => 'tee';
  @override
  Future<Uint8List> wrap(Uint8List data) async {
    final n = randomBytes(12);
    return concat([n, await Crypto.seal(_key, n, data)]);
  }

  @override
  Future<Uint8List> unwrap(Uint8List data) => Crypto.open(_key, data.sublist(0, 12), data.sublist(12));
}

/// Like [FakeHardware], but unwrap waits for [gate] (to look mid-check).
class GatedHardware extends FakeHardware {
  final Future<void> gate;
  GatedHardware(this.gate);

  /// The same key without the gate.
  FakeHardware get open => _Ungated(this);

  @override
  Future<Uint8List> unwrap(Uint8List data) async {
    await gate;
    return super.unwrap(data);
  }

  Future<Uint8List> superUnwrap(Uint8List data) => super.unwrap(data);
}

class _Ungated extends FakeHardware {
  final GatedHardware inner;
  _Ungated(this.inner);
  @override
  Future<Uint8List> wrap(Uint8List data) => inner.wrap(data);
  @override
  Future<Uint8List> unwrap(Uint8List data) => inner.superUnwrap(data);
}
