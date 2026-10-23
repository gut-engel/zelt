@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zelt_core/backup.dart';
import 'package:zelt_core/backup_targets.dart';
import 'package:zelt_core/bip39_words.dart';
import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/crypto.dart';
import 'package:zelt_core/phrase.dart';

Uint8List fill(int b) => Uint8List.fromList(List.filled(16, b));

/// The S3 calls a backup makes, against an in-memory bucket that checks
/// every signature (with the signer that the AWS vectors below pin).
Future<(HttpServer, Map<String, Uint8List>)> fakeS3({int pageSize = 1000}) async {
  final objects = <String, Uint8List>{};
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final body = await req.fold<BytesBuilder>(BytesBuilder(), (b, c) => b..add(c)).then((b) => b.takeBytes());
    final payloadHash = hex(CryptoSync.sha256(body));
    final expected = S3Target.sign(
      method: req.method,
      path: req.uri.path,
      query: req.uri.queryParameters,
      headers: {
        'host': req.headers.value('host')!,
        'x-amz-content-sha256': req.headers.value('x-amz-content-sha256')!,
        'x-amz-date': req.headers.value('x-amz-date')!,
      },
      payloadHash: payloadHash,
      accessKey: 'AK',
      secretKey: 'SK',
      region: 'eu-test-1',
      time: DateTime.parse(req.headers.value('x-amz-date')!.replaceFirst('T', ' ').replaceFirst('Z', 'Z')),
    );
    final res = req.response;
    if (req.headers.value('authorization') != expected || req.headers.value('x-amz-content-sha256') != payloadHash) {
      res.statusCode = 403;
      res.write('<Error><Code>SignatureDoesNotMatch</Code></Error>');
      await res.close();
      return;
    }
    final segs = req.uri.pathSegments;
    final key = segs.skip(1).join('/');
    switch (req.method) {
      case 'PUT':
        objects[key] = body;
      case 'GET' when key.isEmpty:
        final prefix = req.uri.queryParameters['prefix'] ?? '';
        final keys = objects.keys.where((k) => k.startsWith(prefix)).toList()..sort();
        final start = int.tryParse(req.uri.queryParameters['continuation-token'] ?? '') ?? 0;
        final page = keys.skip(start).take(pageSize).toList();
        final more = start + page.length < keys.length;
        res.write('<ListBucketResult>${page.map((k) => '<Contents><Key>$k</Key></Contents>').join()}'
            '<IsTruncated>$more</IsTruncated>${more ? '<NextContinuationToken>${start + page.length}</NextContinuationToken>' : ''}'
            '</ListBucketResult>');
      case 'GET':
        final o = objects[key];
        if (o == null) {
          res.statusCode = 404;
        } else {
          res.add(o);
        }
      case 'DELETE':
        objects.remove(key);
        res.statusCode = 204;
    }
    await res.close();
  });
  return (server, objects);
}

/// A minimal WebDAV server (PUT, GET, DELETE, MKCOL, PROPFIND depth 1).
Future<(HttpServer, Map<String, Uint8List>)> fakeWebDav() async {
  final files = <String, Uint8List>{};
  final dirs = <String>{'/dav/'};
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final body = await req.fold<BytesBuilder>(BytesBuilder(), (b, c) => b..add(c)).then((b) => b.takeBytes());
    final res = req.response;
    if (req.headers.value('authorization') != 'Basic ${base64.encode(utf8.encode('u:p'))}') {
      res.statusCode = 401;
      await res.close();
      return;
    }
    final path = Uri.decodeComponent(req.uri.path);
    switch (req.method) {
      case 'MKCOL':
        res.statusCode = dirs.add(path.endsWith('/') ? path : '$path/') ? 201 : 405;
      case 'PUT':
        final parent = path.substring(0, path.lastIndexOf('/') + 1);
        if (!dirs.contains(parent)) {
          res.statusCode = 409;
        } else {
          files[path] = body;
          res.statusCode = 201;
        }
      case 'GET':
        final f = files[path];
        if (f == null) {
          res.statusCode = 404;
        } else {
          res.add(f);
        }
      case 'DELETE':
        res.statusCode = files.remove(path) == null ? 404 : 204;
      case 'PROPFIND':
        final dir = path.endsWith('/') ? path : '$path/';
        if (!dirs.contains(dir)) {
          res.statusCode = 404;
        } else {
          res.statusCode = 207;
          final inside = files.keys.where((f) => f.startsWith(dir) && !f.substring(dir.length).contains('/'));
          res.write('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">'
              '<d:response><d:href>${Uri.encodeFull(dir)}</d:href></d:response>'
              '${inside.map((f) => '<d:response><d:href>${Uri.encodeFull(f)}</d:href></d:response>').join()}'
              '</d:multistatus>');
        }
    }
    await res.close();
  });
  return (server, files);
}

void main() {
  group('backup phrase', () {
    test('BIP39 test vectors', () {
      final vectors = {
        fill(0x00): 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about',
        fill(0x7f): 'legal winner thank year wave sausage worth useful legal winner thank yellow',
        fill(0x80): 'letter advice cage absurd amount doctor acoustic avoid letter advice cage above',
        fill(0xff): 'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong',
      };
      for (final e in vectors.entries) {
        expect(BackupPhrase.fromEntropy(e.key).toString(), e.value);
        expect(BackupPhrase.parse(e.value).entropy, e.key);
      }
    });

    test('a phrase is read the way people type it', () {
      final p = BackupPhrase.generate();
      expect(p.wordList, hasLength(12));
      final sloppy = '  ${p.wordList.map((w) => w.length > 4 ? w.substring(0, 4).toUpperCase() : w).join(',  ')}\n';
      expect(BackupPhrase.parse(sloppy).entropy, p.entropy);
      expect(() => BackupPhrase.parse(p.wordList.take(11).join(' ')), throwsA(isA<FormatException>().having((e) => e.message, 'm', contains('12 words'))));
      expect(() => BackupPhrase.parse([...p.wordList.take(11), 'xylophone'].join(' ')), throwsFormatException);
    });

    test('typos and swapped words are caught by the checksum', () {
      // Swapping two different words breaks the checksum for this phrase.
      final words = 'legal winner thank year wave sausage worth useful legal winner thank yellow'.split(' ');
      final swapped = [...words]..[0] = words[1]..[1] = words[0];
      expect(() => BackupPhrase.parse(swapped.join(' ')), throwsFormatException);
      final wrongLast = [...words]..[11] = 'zoo';
      expect(() => BackupPhrase.parse(wrongLast.join(' ')), throwsFormatException);
    });

    test('the first four letters identify every word', () {
      final prefixes = {for (final w in bip39English) w.length >= 4 ? w.substring(0, 4) : w};
      expect(prefixes.length, 2048);
      expect(BackupPhrase.suggest('aba'), ['abandon']);
    });

    test('the device keeps only what writes a backup', () async {
      final p = BackupPhrase.generate();
      final k = await BackupKeys.fromPhrase(p);
      final w = BackupKeys.writeOnly(k.publicKey, k.nameKey);
      expect(w.canRead, isFalse);
      final sealed = await Backup.sealManifest(w, state: {'a': 1}, media: [], privatePart: null);
      expect(() => Backup.openManifest(w, sealed), throwsStateError);
      expect((await Backup.openManifest(k, sealed)).state, {'a': 1});
      expect(k.fingerprint, matches(RegExp(r'^[0-9A-F]{4}-[0-9A-F]{4}$')));
    });
  });

  group('S3 signature (AWS Signature Version 4)', () {
    // The examples from the AWS S3 documentation ("Authenticating Requests:
    // Using the Authorization Header", Signature Version 4).
    const ak = 'AKIAIOSFODNN7EXAMPLE';
    const sk = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY';
    const empty = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
    final t = DateTime.utc(2013, 5, 24);

    test('GET object', () {
      final auth = S3Target.sign(
        method: 'GET',
        path: '/test.txt',
        query: {},
        headers: {
          'Host': 'examplebucket.s3.amazonaws.com',
          'Range': 'bytes=0-9',
          'x-amz-content-sha256': empty,
          'x-amz-date': '20130524T000000Z',
        },
        payloadHash: empty,
        accessKey: ak,
        secretKey: sk,
        region: 'us-east-1',
        time: t,
      );
      expect(auth, endsWith('Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41'));
      expect(auth, contains('SignedHeaders=host;range;x-amz-content-sha256;x-amz-date'));
    });

    test('GET bucket (list objects)', () {
      final auth = S3Target.sign(
        method: 'GET',
        path: '/',
        query: {'max-keys': '2', 'prefix': 'J'},
        headers: {
          'Host': 'examplebucket.s3.amazonaws.com',
          'x-amz-content-sha256': empty,
          'x-amz-date': '20130524T000000Z',
        },
        payloadHash: empty,
        accessKey: ak,
        secretKey: sk,
        region: 'us-east-1',
        time: t,
      );
      expect(auth, endsWith('Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7'));
    });

    test('keys are encoded the way S3 expects', () {
      expect(S3Target.uriEncode('zelt-media/a b+c', slash: true), 'zelt-media/a%20b%2Bc');
      expect(S3Target.uriEncode('a/b'), 'a%2Fb');
    });
  });

  group('backup and restore', () {
    late BackupPhrase phrase;
    late BackupKeys keys;
    late BackupKeys device;
    final media = {for (var i = 0; i < 4; i++) i: randomBytes(3000 + i)};
    String h(int i) => hex(CryptoSync.sha256(media[i]!));

    setUp(() async {
      phrase = BackupPhrase.generate();
      keys = await BackupKeys.fromPhrase(phrase);
      device = BackupKeys.writeOnly(keys.publicKey, keys.nameKey);
    });

    Future<Uint8List?> read(String hash) async {
      for (final m in media.values) {
        if (hex(CryptoSync.sha256(m)) == hash) return m;
      }
      return null;
    }

    Map<String, dynamic> state(String marker) => {
      'contacts': [
        {'id': 'pub', 'name': marker},
      ],
      'groups': [],
      'outbox': [],
      'seen': {},
    };

    Future<void> roundTrip(BackupTarget Function() target) async {
      final private = await Backup.sealPrivate(device, {
        'contacts': [
          {'id': 'sec', 'name': 'hidden', 'private': true},
        ],
      }, [h(3)]);
      var s = await BackupRunner.write(
        target(),
        device,
        state: state('first'),
        media: {h(0), h(1)},
        privatePart: private,
        privateMedia: {h(3)},
        readMedia: read,
      );
      expect(s.uploaded, 3);
      // Daily backup: nothing new, only the manifest goes up.
      s = await BackupRunner.write(
        target(),
        device,
        state: state('second'),
        media: {h(0), h(1), h(2)},
        privatePart: private,
        privateMedia: {h(3)},
        readMedia: read,
      );
      expect(s.uploaded, 1, reason: 'only the new picture');
      expect(s.removed, 0);
      // A picture no longer referenced is removed.
      s = await BackupRunner.write(
        target(),
        device,
        state: state('third'),
        media: {h(1), h(2)},
        privatePart: private,
        privateMedia: {h(3)},
        readMedia: read,
      );
      expect((s.uploaded, s.removed), (0, 1));
      // Duress session: private part passed through unread, nothing removed.
      s = await BackupRunner.write(
        target(),
        device,
        state: state('duress'),
        media: {h(2)},
        privatePart: private,
        privateMedia: null,
        readMedia: read,
      );
      expect(s.removed, 0);

      final restored = <String, Uint8List>{};
      final r = await BackupRunner.read(target(), phrase, writeMedia: (hash, b) async => restored[hash] = b);
      final names = [for (final c in r.state['contacts'] as List) c['name']];
      expect(names, containsAll(['duress', 'hidden']));
      expect(restored.keys, containsAll([h(2), h(3)]));
      expect(restored[h(3)], media[3]);
      expect(r.missingMedia, 0);

      // The wrong phrase opens nothing.
      await expectLater(
        BackupRunner.read(target(), BackupPhrase.generate(), writeMedia: (_, _) async {}),
        throwsA(isA<BackupError>().having((e) => e.message, 'm', contains('different backup phrase'))),
      );
    }

    test('in one file', () async {
      Uint8List? file;
      await roundTrip(() => FilePackTarget(FilePackIO(() async => file, (b) async => file = b)));
      // Nothing readable in it.
      expect(String.fromCharCodes(file!).contains('hidden'), isFalse);
      expect(String.fromCharCodes(file!).contains('duress'), isFalse);
      expect(() => FilePackTarget.bytes(Uint8List.fromList(utf8.encode('not a backup'))).get('x'), throwsA(isA<BackupError>()));
    });

    test('over WebDAV', () async {
      final (server, files) = await fakeWebDav();
      addTearDown(() => server.close(force: true));
      await roundTrip(() => WebDavTarget(url: 'http://127.0.0.1:${server.port}/dav/zelt', user: 'u', password: 'p'));
      expect(files.keys, contains('/dav/zelt/zelt-backup'));
      // The duress run removed nothing: three pictures stay.
      expect(files.keys.where((k) => k.startsWith('/dav/zelt/zelt-media/')), hasLength(3));
      final bad = WebDavTarget(url: 'http://127.0.0.1:${server.port}/dav/zelt', user: 'u', password: 'wrong');
      await expectLater(bad.get('zelt-backup'), throwsA(isA<BackupTargetError>().having((e) => e.message, 'm', contains('password'))));
    });

    test('in an S3 bucket, with paged listings', () async {
      final (server, objects) = await fakeS3(pageSize: 1);
      addTearDown(() => server.close(force: true));
      S3Target t() => S3Target(
        endpoint: 'http://127.0.0.1:${server.port}',
        region: 'eu-test-1',
        bucket: 'b',
        accessKey: 'AK',
        secretKey: 'SK',
        prefix: 'phone',
      );
      await roundTrip(t);
      expect(objects.keys, contains('phone/zelt-backup'));
      final wrong = S3Target(endpoint: 'http://127.0.0.1:${server.port}', region: 'eu-test-1', bucket: 'b', accessKey: 'AK', secretKey: 'nope');
      await expectLater(wrong.get('zelt-backup'), throwsA(isA<BackupTargetError>().having((e) => e.message, 'm', contains('access denied'))));
    });

    test('only HTTPS leaves the device', () {
      expect(() => WebDavTarget(url: 'http://cloud.example.org/dav', user: 'u', password: 'p'), throwsA(isA<BackupTargetError>()));
      expect(() => S3Target(endpoint: 'http://s3.example.org', region: 'r', bucket: 'b', accessKey: 'a', secretKey: 's'), throwsA(isA<BackupTargetError>()));
      expect(WebDavTarget(url: 'https://cloud.example.org/dav', user: 'u', password: 'p').label, 'WebDAV cloud.example.org');
    });

    test('a damaged or swapped picture is not restored', () async {
      final blob = await Backup.sealBlob(device, h(0), media[0]!);
      expect(await Backup.openBlob(keys, h(0), blob), media[0]);
      expect(await Backup.openBlob(keys, h(1), blob), isNull);
      blob[20] ^= 1;
      expect(await Backup.openBlob(keys, h(0), blob), isNull);
    });

    test('compression picks the smallest and round-trips', () {
      final json = utf8.encode(jsonEncode({'messages': [for (var i = 0; i < 500; i++) {'t': 'hello number $i', 'ts': 1700000000000 + i}]}));
      final packed = Backup.compress(json);
      expect(packed.length, lessThan(json.length ~/ 5));
      expect(Backup.decompress(packed), json);
      final noise = randomBytes(1000);
      expect(Backup.decompress(Backup.compress(noise)), noise);
      expect(Backup.compress(noise).length, 1001, reason: 'stored as is when nothing helps');
    });
  });

  group('SFTP against a real sshd', () {
    late Directory dir;
    late Process sshd;
    late int port;
    late String fingerprint;
    late String clientKey;

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('zelt-sftp');
      Future<void> run(String exe, List<String> args) async {
        final r = await Process.run(exe, args);
        if (r.exitCode != 0) throw StateError('$exe: ${r.stderr}');
      }

      await run('ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-f', '${dir.path}/host']);
      await run('ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-f', '${dir.path}/client']);
      File('${dir.path}/auth').writeAsStringSync(File('${dir.path}/client.pub').readAsStringSync());
      clientKey = File('${dir.path}/client').readAsStringSync();
      final fp = await Process.run('ssh-keygen', ['-l', '-E', 'sha256', '-f', '${dir.path}/host.pub']);
      fingerprint = (fp.stdout as String).split(' ')[1];
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      port = probe.port;
      await probe.close();
      final sftpServer = ['/usr/lib/ssh/sftp-server', '/usr/lib/openssh/sftp-server', '/usr/libexec/sftp-server']
          .firstWhere((p) => File(p).existsSync(), orElse: () => 'internal-sftp');
      File('${dir.path}/sshd_config').writeAsStringSync([
        'Port $port',
        'ListenAddress 127.0.0.1',
        'HostKey ${dir.path}/host',
        'PidFile ${dir.path}/pid',
        'AuthorizedKeysFile ${dir.path}/auth',
        'StrictModes no',
        'UsePAM no',
        'PasswordAuthentication no',
        'Subsystem sftp $sftpServer',
      ].join('\n'));
      sshd = await Process.start('/usr/bin/sshd', ['-D', '-e', '-f', '${dir.path}/sshd_config']);
      sshd.stderr.drain<void>();
      for (var i = 0; i < 50; i++) {
        try {
          (await Socket.connect('127.0.0.1', port)).destroy();
          break;
        } catch (_) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }
    });

    tearDownAll(() async {
      sshd.kill();
      await dir.delete(recursive: true);
    });

    final user = Platform.environment['USER'] ?? 'root';

    test('the host key is shown before it is trusted', () async {
      expect(await SftpTarget.fetchHostKey('127.0.0.1', port), fingerprint);
    });

    test('backs up and restores, and refuses a different host key', () async {
      final phrase = BackupPhrase.generate();
      final keys = await BackupKeys.fromPhrase(phrase);
      final pic = randomBytes(5000);
      final hash = hex(CryptoSync.sha256(pic));
      SftpTarget t({String? hostKey}) => SftpTarget(
        host: '127.0.0.1',
        port: port,
        user: user,
        privateKey: clientKey,
        path: '${dir.path}/backups/phone',
        hostKey: hostKey ?? fingerprint,
      );
      final s = await BackupRunner.write(
        t(),
        BackupKeys.writeOnly(keys.publicKey, keys.nameKey),
        state: {'contacts': [], 'hello': 'sftp'},
        media: {hash},
        privatePart: null,
        privateMedia: {},
        readMedia: (_) async => pic,
      );
      expect(s.uploaded, 1);
      expect(File('${dir.path}/backups/phone/zelt-backup').existsSync(), isTrue);
      final got = <String, Uint8List>{};
      final r = await BackupRunner.read(t(), phrase, writeMedia: (h, b) async => got[h] = b);
      expect(r.state['hello'], 'sftp');
      expect(got[hash], pic);
      await expectLater(
        t(hostKey: 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA').get('zelt-backup'),
        throwsA(isA<BackupTargetError>().having((e) => e.message, 'm', contains('different server key'))),
      );
    });
  }, skip: File('/usr/bin/sshd').existsSync() ? false : 'no sshd here');
}
