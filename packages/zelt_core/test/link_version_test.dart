import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zelt_core/address.dart';
import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/constants.dart';
import 'package:zelt_core/crypto.dart';
import 'package:zelt_core/link.dart';

void main() {
  test('client refuses a v1 relay (no preamble)', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) => s.add(randomBytes(32))); // what a v1 relay answers
    final key = await Crypto.x25519Generate();
    final r = RelayInfo(NodeAddr(InternetAddress.loopbackIPv4, server.port), key.pub);
    await expectLater(Link.connect(r), throwsA(isA<IncompatiblePeer>().having((e) => e.theirVersion, 'v', null)));
    await server.close();
  });

  test('client refuses a relay that speaks another version and learns which', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) => s.add(Uint8List.fromList([0x5a, 0x4c, 0x54, protocolVersion + 1, ...randomBytes(32)])));
    final key = await Crypto.x25519Generate();
    final r = RelayInfo(NodeAddr(InternetAddress.loopbackIPv4, server.port), key.pub);
    await expectLater(
      Link.connect(r),
      throwsA(isA<IncompatiblePeer>().having((e) => e.theirVersion, 'v', protocolVersion + 1)),
    );
    await server.close();
  });

  test('relay answers a newer client with its own version and hangs up', () async {
    final key = await Crypto.ed25519Generate();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<Object?>();
    server.listen((s) async {
      try {
        await Link.accept(s, key);
        accepted.complete(null);
      } catch (e) {
        accepted.complete(e);
      }
    });
    final c = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
    c.add([0x5a, 0x4c, 0x54, protocolVersion + 1, ...randomBytes(32)]);
    final reply = await c.fold<List<int>>([], (a, b) => a..addAll(b)).timeout(const Duration(seconds: 5));
    expect(reply, [0x5a, 0x4c, 0x54, protocolVersion]);
    expect(await accepted.future, isA<IncompatiblePeer>());
    c.destroy();
    await server.close();
  });

  test('same version connects and exchanges frames', () async {
    final key = await Crypto.ed25519Generate();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final got = Completer<Frame>();
    server.listen((s) async => (await Link.accept(s, key)).start().frames.first.then(got.complete));
    final link = (await Link.connect(RelayInfo(NodeAddr(InternetAddress.loopbackIPv4, server.port), key.pub))).start();
    await link.send(Frame.ping());
    expect((await got.future.timeout(const Duration(seconds: 5))).type, FrameType.ping);
    link.close();
    await server.close();
  });

  test('a relay that cannot sign for the advertised identity is refused', () async {
    final real = await Crypto.ed25519Generate();
    final impostor = await Crypto.ed25519Generate();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) => Link.accept(s, impostor).catchError((_) => throw 'x').ignore());
    final r = RelayInfo(NodeAddr(InternetAddress.loopbackIPv4, server.port), real.pub);
    await expectLater(Link.connect(r), throwsA(isA<SocketException>()));
    await server.close();
  });
}
