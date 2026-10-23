@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/crypto.dart';
import 'package:zelt_core/state_split.dart';
import 'package:zelt_core/vault.dart';

import 'units_test.dart' show FakeHardware;

void main() {
  late Directory d;
  setUp(() async => d = await Directory.systemTemp.createTemp('zelt'));
  tearDown(() async => d.delete(recursive: true));

  Map<String, dynamic> meta() => jsonDecode(File('${d.path}/vault.json').readAsStringSync());

  /// The shape of vault.json: field names and value lengths.
  Map<String, int> shape() => {
    for (final e in meta().entries)
      if (e.key != 'failed' && e.key != 'lockUntil') e.key: e.value is String ? (e.value as String).length : -1,
  };

  for (final hw in [null, FakeHardware()]) {
    final label = hw == null ? 'PIN only' : 'hardware';

    test('the duress PIN opens everything but the private section ($label)', () async {
      final v = await Vault.create(d, 'real-pin', hardware: hw);
      expect(v.duress, isFalse);
      await v.save({'chats': 'public'});
      await v.savePrivate({'chats': 'secret'});
      expect(v.duressPinSet, isFalse);
      final before = shape();
      await v.setDuressPin('duress-pin');
      expect(v.duressPinSet, isTrue);
      expect(shape(), before, reason: 'vault.json looks the same with or without a duress PIN');

      final dv = await Vault.unlock(d, 'duress-pin', hardware: hw);
      expect(dv.duress, isTrue);
      expect(await dv.load(), {'chats': 'public'});
      expect(dv.duressPinSet, isFalse, reason: 'a duress session does not know');
      expect(() => dv.loadPrivate(), throwsStateError);
      expect(() => dv.savePrivate({}), throwsStateError);
      expect(() => dv.setDuressPin('x'), throwsStateError);
      // The duress session keeps working with the public state.
      await dv.save({'chats': 'public, changed under duress'});
      final secret = File('${d.path}/private.bin').readAsBytesSync();

      final rv = await Vault.unlock(d, 'real-pin', hardware: hw);
      expect(rv.duress, isFalse);
      expect(await rv.load(), {'chats': 'public, changed under duress'});
      expect(await rv.loadPrivate(), [
        {'chats': 'secret'},
      ]);
      expect(File('${d.path}/private.bin').readAsBytesSync(), secret, reason: 'untouched by the duress session');
      await expectLater(Vault.unlock(d, 'neither', hardware: hw), throwsA(isA<WrongPin>()));
    });

    test('changing a PIN changes only its own slot ($label)', () async {
      final v = await Vault.create(d, 'real-pin', hardware: hw);
      await v.setDuressPin('duress-pin');
      final dv = await Vault.unlock(d, 'duress-pin', hardware: hw);
      await dv.changePin('new-duress');
      expect((await Vault.unlock(d, 'new-duress', hardware: hw)).duress, isTrue);
      expect((await Vault.unlock(d, 'real-pin', hardware: hw)).duress, isFalse);
      await expectLater(Vault.unlock(d, 'duress-pin', hardware: hw), throwsA(isA<WrongPin>()));
      // A PIN that would open the other slot is refused.
      await expectLater(dv.changePin('real-pin'), throwsArgumentError);
      final rv = await Vault.unlock(d, 'real-pin', hardware: hw);
      await expectLater(rv.changePin('new-duress'), throwsArgumentError);
      await expectLater(rv.setDuressPin('real-pin'), throwsArgumentError);
      await rv.changePin('new-real');
      expect((await Vault.unlock(d, 'new-real', hardware: hw)).duress, isFalse);
      expect((await Vault.unlock(d, 'new-duress', hardware: hw)).duress, isTrue);
      // Removing the duress PIN.
      await rv.loadPrivate();
      await rv.clearDuressPin();
      await expectLater(Vault.unlock(d, 'new-duress', hardware: hw), throwsA(isA<WrongPin>()));
    });
  }

  test('a duress session can hide a chat it cannot read back', () async {
    final v = await Vault.create(d, 'real-pin');
    await v.savePrivate({'contacts': [{'id': 'a'}]});
    await v.setDuressPin('duress-pin');
    final dv = await Vault.unlock(d, 'duress-pin');
    await dv.addPrivate({'contacts': [{'id': 'b'}]});
    final pending = Directory('${d.path}/pending').listSync();
    expect(pending, hasLength(1));
    expect(String.fromCharCodes(File(pending.single.path).readAsBytesSync()).contains('"b"'), isFalse);

    final rv = await Vault.unlock(d, 'real-pin');
    final parts = await rv.loadPrivate();
    expect(parts, hasLength(2));
    expect(parts.last['contacts'], [{'id': 'b'}]);
    await rv.savePrivate(StateSplit.merge({}, parts)..remove('outbox'));
    expect(Directory('${d.path}/pending').listSync(), isEmpty, reason: 'merged, then removed');
    final again = await (await Vault.unlock(d, 'real-pin')).loadPrivate();
    expect((again.single['contacts'] as List).map((c) => c['id']), ['a', 'b']);
  });

  test('the private section is padded', () async {
    final v = await Vault.create(d, 'real-pin');
    final empty = File('${d.path}/private.bin').lengthSync();
    await v.savePrivate({'x': 'y' * 1000});
    expect(File('${d.path}/private.bin').lengthSync(), empty);
    await v.savePrivate({'x': 'y' * 100000});
    expect(File('${d.path}/private.bin').lengthSync(), greaterThan(empty));
  });

  test('a vault from before private chats opens and gains the new slots', () async {
    // The old format: one 32-byte master key wrapped by the PIN.
    await d.create(recursive: true);
    final master = randomBytes(32);
    final salt = randomBytes(16);
    final pinKey = await Crypto.argon2id('old-pin', salt, memoryKib: 64 * 1024, iterations: 3);
    final nonce = randomBytes(12);
    final wrapped = concat([nonce, await Crypto.seal(pinKey, nonce, master, aad: utf8.encode('zelt-vault'))]);
    File('${d.path}/vault.json').writeAsStringSync(jsonEncode({
      'kdf': 'argon2id', 'salt': b64(salt), 'mem': 64 * 1024, 'it': 3, 'failed': 0, 'v': 1, 'wrapped': b64(wrapped),
    }));
    final sn = randomBytes(12);
    final st = await Crypto.seal(master, sn, utf8.encode(jsonEncode({'old': true})), aad: utf8.encode('zelt-state'));
    File('${d.path}/state.bin').writeAsBytesSync(concat([sn, st]));

    final v = await Vault.unlock(d, 'old-pin');
    expect(v.duress, isFalse);
    expect(await v.load(), {'old': true});
    expect(meta().keys, containsAll(['wrapped2', 'salt2', 'apk']));
    expect(await v.loadPrivate(), [<String, dynamic>{}]);
    final again = await Vault.unlock(d, 'old-pin');
    expect(await again.load(), {'old': true});
    await again.setDuressPin('duress');
    expect((await Vault.unlock(d, 'duress')).duress, isTrue);
  });

  test('a hardware-bound vault from before private chats upgrades too', () async {
    await d.create(recursive: true);
    final hw = FakeHardware();
    final master = randomBytes(32);
    final salt = randomBytes(16);
    final pinKey = await Crypto.argon2id('old-pin', salt, memoryKib: 64 * 1024, iterations: 3);
    final nonce = randomBytes(12);
    final pinWrapped = concat([nonce, await Crypto.seal(pinKey, nonce, master, aad: utf8.encode('zelt-vault'))]);
    File('${d.path}/vault.json').writeAsStringSync(jsonEncode({
      'kdf': 'argon2id', 'salt': b64(salt), 'mem': 64 * 1024, 'it': 3, 'failed': 0,
      'v': 2, 'hw': 'tee', 'wrapped': b64(await hw.wrap(pinWrapped)),
    }));
    final sn = randomBytes(12);
    final st = await Crypto.seal(master, sn, utf8.encode(jsonEncode({'old': 2})), aad: utf8.encode('zelt-state'));
    File('${d.path}/state.bin').writeAsBytesSync(concat([sn, st]));
    // A picture stored by the old version (keys from the old master key).
    final mediaName = hex(randomBytes(32));
    final nameKey = await Crypto.hkdf(master, info: 'zelt/media/name/v1');
    final encKey = await Crypto.hkdf(master, info: 'zelt/media/enc/v1');
    final fn = hex(await Crypto.hmac(nameKey, utf8.encode(mediaName))).substring(0, 40);
    final bn = randomBytes(12);
    Directory('${d.path}/media').createSync();
    File('${d.path}/media/$fn').writeAsBytesSync(
      concat([bn, await Crypto.seal(encKey, bn, Uint8List.fromList([1, 2, 3]), aad: utf8.encode(mediaName))]),
    );

    final v = await Vault.unlock(d, 'old-pin', hardware: hw);
    expect(v.duress, isFalse);
    expect(await v.load(), {'old': 2});
    expect(await v.readBlob(mediaName), [1, 2, 3]);
    expect(Vault.formatOf(d), 'v2 (tee)');
    expect(meta()['wrapped2'], isNotNull);
    await v.setDuressPin('duress');
    expect((await Vault.unlock(d, 'duress', hardware: hw)).duress, isTrue);
    expect((await Vault.unlock(d, 'old-pin', hardware: hw)).duress, isFalse);
    await expectLater(Vault.unlock(d, 'old-pin', hardware: FakeHardware()), throwsA(isA<WrongPin>()));
  });

  test('moving to the hardware key never happens with the duress PIN', () async {
    final v = await Vault.create(d, 'real-pin');
    await v.setDuressPin('duress-pin');
    final hw = FakeHardware();
    final dv = await Vault.unlock(d, 'duress-pin', hardware: hw);
    expect(dv.duress, isTrue);
    expect(Vault.formatOf(d), 'v1 (PIN only)');
    final rv = await Vault.unlock(d, 'real-pin', hardware: hw);
    expect(rv.duress, isFalse);
    expect(Vault.formatOf(d), 'v2 (tee)');
    expect(rv.duressPinSet, isFalse, reason: 'the duress PIN has to be set again');
    expect((await Vault.unlock(d, 'real-pin', hardware: hw)).duress, isFalse);
  });

  group('splitting the state', () {
    Map<String, dynamic> full() => {
      'identity': {'k': 1},
      'contacts': [
        {'id': 'pub', 'name': 'Pat'},
        {'id': 'sec', 'name': 'Sam', 'private': true},
      ],
      'groups': [
        {
          'id': 'g1',
          'by': 'sec',
          'pi': ['sec', 'pub'],
          'messages': [
            {'id': 'm1', 'via': 'sec'},
            {'id': 'm2', 'via': 'pub'},
          ],
        },
        {'id': 'g2', 'private': true, 'messages': []},
      ],
      'outbox': [
        {'id': 'o1', 'c': 'pub'},
        {'id': 'o2', 'c': 'sec'},
        {'id': 'o3', 'c': 'pub', 'gm': 'g2/x'},
      ],
      'seen': {
        'h1': {'c': 'pub'},
        'h2': {'c': 'sec'},
      },
      'peers': {
        'known': [
          {'r': {}, 's': ['sec', 'manual']},
          {'r': {}, 's': ['via:sec']},
          {'r': {}, 's': ['pub']},
        ],
        'active': [],
      },
    };

    test('nothing in the public part names a private chat', () {
      final (public, private) = StateSplit.split(full());
      final text = jsonEncode(public);
      expect(text.contains('sec'), isFalse, reason: text);
      expect(text.contains('g2'), isFalse);
      expect((public['contacts'] as List).single['id'], 'pub');
      expect((private['contacts'] as List).single['id'], 'sec');
      expect((private['outbox'] as List).map((o) => o['id']), ['o2', 'o3']);
      expect((public['peers']['known'] as List).map((r) => r['s']), [
        ['history', 'manual'],
        ['history'],
        ['pub'],
      ]);
    });

    test('merging gives back the full state', () {
      final (public, private) = StateSplit.split(full());
      final merged = StateSplit.merge(public, [private]);
      final g1 = (merged['groups'] as List).firstWhere((g) => g['id'] == 'g1');
      expect(g1['by'], 'sec');
      expect(<String>{...g1['pi']}, {'sec', 'pub'});
      expect((g1['messages'] as List).map((m) => m['via']), ['sec', 'pub']);
      expect((merged['contacts'] as List).map((c) => c['id']), containsAll(['pub', 'sec']));
      expect((merged['outbox'] as List).length, 3);
      expect((merged['seen'] as Map).keys, containsAll(['h1', 'h2']));
    });

    test('a chat hidden later replaces its public version', () {
      final (public, _) = StateSplit.split(full());
      final merged = StateSplit.merge(public, [
        {
          'contacts': [
            {'id': 'pub', 'name': 'Pat', 'private': true},
          ],
        },
      ]);
      expect((merged['contacts'] as List).where((c) => c['id'] == 'pub').single['private'], true);
    });
  });
}
