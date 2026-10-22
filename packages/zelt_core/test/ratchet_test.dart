import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/crypto.dart';
import 'package:zelt_core/ratchet.dart';

Uint8List t(String s) => Uint8List.fromList(utf8.encode(s));
String s(Uint8List b) => utf8.decode(b);

Future<(Ratchet, Ratchet)> pair() async {
  final root = randomBytes(32);
  final bobKey = await Crypto.x25519Generate();
  return (await Ratchet.alice(root, bobKey.pub), await Ratchet.bob(root, bobKey));
}

void main() {
  test('both sides can send first, then ping-pong', () async {
    final (a, b) = await pair();
    final b0 = await b.encrypt(t('bob first'));
    final a0 = await a.encrypt(t('alice first'));
    expect(s(await a.decrypt(b0)), 'bob first');
    expect(s(await b.decrypt(a0)), 'alice first');
    for (var i = 0; i < 5; i++) {
      expect(s(await b.decrypt(await a.encrypt(t('a$i')))), 'a$i');
      expect(s(await a.decrypt(await b.encrypt(t('b$i')))), 'b$i');
    }
  });

  test('out of order and across ratchet steps', () async {
    final (a, b) = await pair();
    final pre = [for (var i = 0; i < 3; i++) await b.encrypt(t('pre$i'))];
    final m = [for (var i = 0; i < 4; i++) await a.encrypt(t('m$i'))];
    expect(s(await b.decrypt(m[3])), 'm3');
    expect(s(await b.decrypt(m[1])), 'm1');
    final post = await b.encrypt(t('post'));
    expect(s(await a.decrypt(post)), 'post');
    expect(s(await a.decrypt(pre[2])), 'pre2');
    expect(s(await a.decrypt(pre[0])), 'pre0');
    expect(s(await b.decrypt(m[0])), 'm0');
    expect(s(await b.decrypt(m[2])), 'm2');
  });

  test('replay and tamper are rejected without corrupting state', () async {
    final (a, b) = await pair();
    final m = await a.encrypt(t('hello'));
    expect(s(await b.decrypt(m)), 'hello');
    await expectLater(b.decrypt(m), throwsA(anything));
    final bad = Uint8List.fromList(await a.encrypt(t('x')))..[50] ^= 1;
    await expectLater(b.decrypt(bad), throwsA(anything));
    expect(s(await b.decrypt(await a.encrypt(t('still ok')))), 'still ok');
  });

  test('survives serialization', () async {
    var (a, b) = await pair();
    await b.decrypt(await a.encrypt(t('1')));
    a = Ratchet.fromJson(jsonDecode(jsonEncode(a.toJson())));
    b = Ratchet.fromJson(jsonDecode(jsonEncode(b.toJson())));
    expect(s(await a.decrypt(await b.encrypt(t('2')))), '2');
  });
}
