import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'backup.dart';
import 'bytes.dart';
import 'crypto.dart';
import 'phrase.dart';
import 'state_split.dart';

/// Where backups go. Names are `zelt-backup` and `zelt-media/<name>`.
abstract class BackupTarget {
  /// Short description for the user ("WebDAV cloud.example.org").
  String get label;

  Future<void> put(String name, Uint8List data);

  /// Null if there is no such file.
  Future<Uint8List?> get(String name);

  /// Names under [prefix] (with the prefix).
  Future<Set<String>> list(String prefix);
  Future<void> delete(String name);

  /// Ends a backup run (writes the file, closes connections).
  Future<void> finish() async {}

  Map<String, dynamic> toJson();

  static BackupTarget fromJson(Map<String, dynamic> j, {FilePackIO? fileIO}) => switch (j['type']) {
    'webdav' => WebDavTarget.fromJson(j),
    's3' => S3Target.fromJson(j),
    'sftp' => SftpTarget.fromJson(j),
    'file' => FilePackTarget(fileIO ?? FilePackIO.path(j['path'] as String), label: j['label'] as String? ?? 'File'),
    _ => throw FormatException('unknown backup target ${j['type']}'),
  };
}

class BackupTargetError implements Exception {
  final String message;
  const BackupTargetError(this.message);
  @override
  String toString() => message;
}

/// One backup run's result.
class BackupStats {
  final int uploaded;
  final int uploadedBytes;
  final int manifestBytes;
  final int removed;
  final int missing;
  BackupStats(this.uploaded, this.uploadedBytes, this.manifestBytes, this.removed, this.missing);
}

class RestoredBackup {
  /// The full state (private chats included).
  final Map<String, dynamic> state;
  final DateTime created;
  final int media;
  final int missingMedia;
  RestoredBackup(this.state, this.created, this.media, this.missingMedia);
}

class BackupRunner {
  BackupRunner._();

  /// Writes one backup. [privateMedia] null: the private part is passed
  /// through unread (duress session), so no picture may be removed.
  static Future<BackupStats> write(
    BackupTarget t,
    BackupKeys keys, {
    required Map<String, dynamic> state,
    required Set<String> media,
    required Uint8List? privatePart,
    required Set<String>? privateMedia,
    required Future<Uint8List?> Function(String hash) readMedia,
  }) async {
    try {
      final existing = await t.list(Backup.mediaPrefix);
      final wanted = <String>{};
      var uploaded = 0, bytes = 0, missing = 0;
      for (final hash in {...media, ...?privateMedia}) {
        final name = Backup.blobName(keys, hash);
        wanted.add(name);
        if (existing.contains(name)) continue;
        final data = await readMedia(hash);
        if (data == null) {
          missing++;
          continue;
        }
        final blob = await Backup.sealBlob(keys, hash, data);
        await t.put(name, blob);
        uploaded++;
        bytes += blob.length;
      }
      final manifest = await Backup.sealManifest(keys, state: state, media: media, privatePart: privatePart);
      await t.put(Backup.manifestName, manifest);
      var removed = 0;
      if (privateMedia != null) {
        for (final name in existing.difference(wanted)) {
          await t.delete(name);
          removed++;
        }
      }
      await t.finish();
      return BackupStats(uploaded, bytes, manifest.length, removed, missing);
    } catch (e) {
      try {
        await t.finish();
      } catch (_) {}
      rethrow;
    }
  }

  /// Reads the backup in [t] with [phrase]: the full state, with every
  /// picture that is there handed to [writeMedia].
  static Future<RestoredBackup> read(
    BackupTarget t,
    BackupPhrase phrase, {
    required Future<void> Function(String hash, Uint8List bytes) writeMedia,
    void Function(int done, int total)? progress,
  }) async {
    try {
      final keys = await BackupKeys.fromPhrase(phrase);
      final sealed = await t.get(Backup.manifestName);
      if (sealed == null) throw const BackupError('there is no zelt backup there');
      final m = await Backup.openManifest(keys, sealed);
      var privateState = <String, dynamic>{};
      var privateMedia = <String>[];
      if (m.privatePart != null) (privateState, privateMedia) = await Backup.openPrivate(keys, m.privatePart!);
      final all = {...m.media, ...privateMedia}.toList();
      var missing = 0;
      for (var i = 0; i < all.length; i++) {
        progress?.call(i, all.length);
        final blob = await t.get(Backup.blobName(keys, all[i]));
        final bytes = blob == null ? null : await Backup.openBlob(keys, all[i], blob);
        if (bytes == null) {
          missing++;
        } else {
          await writeMedia(all[i], bytes);
        }
      }
      progress?.call(all.length, all.length);
      await t.finish();
      return RestoredBackup(StateSplit.merge(m.state, [privateState]), m.created, all.length, missing);
    } catch (e) {
      try {
        await t.finish();
      } catch (_) {}
      rethrow;
    }
  }
}

// --- HTTP helpers -----------------------------------------------------------

/// Plain HTTP only to this device (tests, a local proxy): everything else
/// must be HTTPS, so credentials never travel in the clear.
void _requireTls(Uri u) {
  final h = u.host;
  final loopback = h == 'localhost' || h == '::1' || h.startsWith('127.');
  if (u.scheme != 'https' && !(u.scheme == 'http' && loopback)) {
    throw const BackupTargetError('the address must start with https://');
  }
}

Future<(int, Uint8List)> _http(
  String method,
  Uri url, {
  Map<String, String> headers = const {},
  List<int>? body,
}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..idleTimeout = const Duration(seconds: 5);
  try {
    final req = await client.openUrl(method, url).timeout(const Duration(seconds: 30));
    req.followRedirects = false;
    headers.forEach(req.headers.set);
    if (body != null) {
      req.contentLength = body.length;
      req.add(body);
    } else if (method == 'PUT' || method == 'POST') {
      req.contentLength = 0;
    }
    final res = await req.close().timeout(const Duration(seconds: 120));
    final b = BytesBuilder(copy: false);
    await for (final chunk in res.timeout(const Duration(seconds: 120))) {
      b.add(chunk);
    }
    return (res.statusCode, b.takeBytes());
  } on SocketException catch (e) {
    throw BackupTargetError('cannot reach ${url.host}: ${e.osError?.message ?? e.message}');
  } on HandshakeException {
    throw BackupTargetError('${url.host}: the TLS certificate is not valid');
  } on TimeoutException {
    throw BackupTargetError('${url.host} did not answer in time');
  } finally {
    client.close(force: true);
  }
}

String _xmlText(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

// --- WebDAV -----------------------------------------------------------------

/// A WebDAV folder (Nextcloud, ownCloud, NAS boxes, many hosters).
class WebDavTarget extends BackupTarget {
  final Uri base;
  final String user;
  final String password;
  bool _madeDirs = false;

  WebDavTarget({required String url, required this.user, required this.password})
    : base = Uri.parse(url.endsWith('/') ? url : '$url/') {
    _requireTls(base);
  }

  factory WebDavTarget.fromJson(Map<String, dynamic> j) =>
      WebDavTarget(url: j['url'] as String, user: j['user'] as String, password: j['password'] as String);

  @override
  Map<String, dynamic> toJson() => {'type': 'webdav', 'url': base.toString(), 'user': user, 'password': password};

  @override
  String get label => 'WebDAV ${base.host}';

  Map<String, String> get _auth => {
    'authorization': 'Basic ${base64.encode(utf8.encode('$user:$password'))}',
  };

  Uri _url(String name) => base.resolve(name.split('/').map(Uri.encodeComponent).join('/'));

  void _check(int status, String what) {
    if (status == 401 || status == 403) throw const BackupTargetError('WebDAV: user name or password not accepted');
    if (status >= 300) throw BackupTargetError('WebDAV: $what failed (HTTP $status)');
  }

  Future<void> _dirs() async {
    if (_madeDirs) return;
    for (final dir in [base, _url(Backup.mediaPrefix)]) {
      final (status, _) = await _http('MKCOL', dir, headers: _auth);
      // 405: exists already.
      if (status != 405 && status != 301) _check(status, 'creating a folder');
    }
    _madeDirs = true;
  }

  @override
  Future<void> put(String name, Uint8List data) async {
    await _dirs();
    final (status, _) = await _http('PUT', _url(name), headers: {..._auth, 'content-type': 'application/octet-stream'}, body: data);
    _check(status, 'upload');
  }

  @override
  Future<Uint8List?> get(String name) async {
    final (status, body) = await _http('GET', _url(name), headers: _auth);
    if (status == 404) return null;
    _check(status, 'download');
    return body;
  }

  @override
  Future<Set<String>> list(String prefix) async {
    final dir = _url(prefix);
    final (status, body) = await _http('PROPFIND', dir, headers: {
      ..._auth,
      'depth': '1',
      'content-type': 'application/xml',
    }, body: utf8.encode('<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>'));
    if (status == 404) return {};
    _check(status, 'listing');
    final names = <String>{};
    for (final m in RegExp(r'<(?:[A-Za-z0-9]+:)?href>([^<]*)</(?:[A-Za-z0-9]+:)?href>').allMatches(utf8.decode(body, allowMalformed: true))) {
      final path = Uri.decodeComponent(_xmlText(m.group(1)!).trim());
      final seg = path.split('/').where((s) => s.isNotEmpty).lastOrNull;
      if (seg == null || path.endsWith('/')) continue;
      names.add('$prefix$seg');
    }
    return names;
  }

  @override
  Future<void> delete(String name) async {
    final (status, _) = await _http('DELETE', _url(name), headers: _auth);
    if (status != 404) _check(status, 'delete');
  }
}

// --- S3 ---------------------------------------------------------------------

/// An S3-compatible bucket (AWS S3, Backblaze B2, MinIO, Wasabi, R2), with
/// path-style URLs and Signature Version 4.
class S3Target extends BackupTarget {
  final Uri endpoint;
  final String region;
  final String bucket;
  final String accessKey;
  final String secretKey;

  /// Folder inside the bucket ('' or 'zelt/').
  final String prefix;

  /// Overridable for tests (the signature covers the time).
  DateTime Function() clock = () => DateTime.now().toUtc();

  S3Target({
    required String endpoint,
    required this.region,
    required this.bucket,
    required this.accessKey,
    required this.secretKey,
    String prefix = '',
  }) : endpoint = Uri.parse(endpoint.endsWith('/') ? endpoint.substring(0, endpoint.length - 1) : endpoint),
       prefix = prefix.isEmpty || prefix.endsWith('/') ? prefix : '$prefix/' {
    _requireTls(this.endpoint);
    if (bucket.isEmpty || bucket.contains('/')) throw const BackupTargetError('S3: give the bucket name only');
  }

  factory S3Target.fromJson(Map<String, dynamic> j) => S3Target(
    endpoint: j['endpoint'] as String,
    region: j['region'] as String,
    bucket: j['bucket'] as String,
    accessKey: j['accessKey'] as String,
    secretKey: j['secretKey'] as String,
    prefix: j['prefix'] as String? ?? '',
  );

  @override
  Map<String, dynamic> toJson() => {
    'type': 's3',
    'endpoint': endpoint.toString(),
    'region': region,
    'bucket': bucket,
    'accessKey': accessKey,
    'secretKey': secretKey,
    'prefix': prefix,
  };

  @override
  String get label => 'S3 $bucket (${endpoint.host})';

  /// RFC 3986 encoding as SigV4 wants it ([slash]: keep '/').
  static String uriEncode(String s, {bool slash = false}) {
    final out = StringBuffer();
    for (final b in utf8.encode(s)) {
      final c = String.fromCharCode(b);
      if (RegExp(r'[A-Za-z0-9\-_.~]').hasMatch(c) || (slash && c == '/')) {
        out.write(c);
      } else {
        out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }

  static String _hex(List<int> b) => hex(Uint8List.fromList(b));

  /// The Authorization header for a request (AWS Signature Version 4).
  static String sign({
    required String method,
    required String path,
    required Map<String, String> query,
    required Map<String, String> headers,
    required String payloadHash,
    required String accessKey,
    required String secretKey,
    required String region,
    required DateTime time,
    String service = 's3',
  }) {
    final amzDate = _amzDate(time);
    final date = amzDate.substring(0, 8);
    final sortedQuery = query.keys.toList()..sort();
    final canonicalQuery = [for (final k in sortedQuery) '${uriEncode(k)}=${uriEncode(query[k]!)}'].join('&');
    final lower = {for (final e in headers.entries) e.key.toLowerCase(): e.value.trim()};
    final names = lower.keys.toList()..sort();
    final canonicalHeaders = [for (final n in names) '$n:${lower[n]}\n'].join();
    final signedHeaders = names.join(';');
    final canonicalRequest = [method, path, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash].join('\n');
    final scope = '$date/$region/$service/aws4_request';
    final stringToSign = ['AWS4-HMAC-SHA256', amzDate, scope, _hex(CryptoSync.sha256(utf8.encode(canonicalRequest)))].join('\n');
    var k = CryptoSync.hmac(utf8.encode('AWS4$secretKey'), utf8.encode(date));
    k = CryptoSync.hmac(k, utf8.encode(region));
    k = CryptoSync.hmac(k, utf8.encode(service));
    k = CryptoSync.hmac(k, utf8.encode('aws4_request'));
    final signature = _hex(CryptoSync.hmac(k, utf8.encode(stringToSign)));
    return 'AWS4-HMAC-SHA256 Credential=$accessKey/$scope, SignedHeaders=$signedHeaders, Signature=$signature';
  }

  static String _amzDate(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    final u = t.toUtc();
    return '${u.year}${two(u.month)}${two(u.day)}T${two(u.hour)}${two(u.minute)}${two(u.second)}Z';
  }

  Future<(int, Uint8List)> _request(String method, String key, {Map<String, String> query = const {}, List<int>? body}) {
    final path = '${endpoint.path}/${uriEncode(bucket)}${key.isEmpty ? '' : '/${uriEncode(key, slash: true)}'}';
    final payloadHash = _hex(CryptoSync.sha256(body ?? const []));
    final now = clock();
    final host = endpoint.hasPort ? '${endpoint.host}:${endpoint.port}' : endpoint.host;
    final headers = {
      'host': host,
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': _amzDate(now),
    };
    final auth = sign(
      method: method,
      path: path,
      query: query,
      headers: headers,
      payloadHash: payloadHash,
      accessKey: accessKey,
      secretKey: secretKey,
      region: region,
      time: now,
    );
    final q = query.isEmpty ? '' : '?${[for (final e in query.entries) '${uriEncode(e.key)}=${uriEncode(e.value)}'].join('&')}';
    final url = Uri.parse('${endpoint.scheme}://$host$path$q');
    return _http(method, url, headers: {
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': _amzDate(now),
      'authorization': auth,
    }, body: body);
  }

  void _check(int status, Uint8List body, String what) {
    if (status < 300) return;
    final code = RegExp(r'<Code>([^<]*)</Code>').firstMatch(utf8.decode(body, allowMalformed: true))?.group(1);
    if (status == 403) throw BackupTargetError('S3: access denied${code == null ? '' : ' ($code)'}: check the keys and the region');
    throw BackupTargetError('S3: $what failed (HTTP $status${code == null ? '' : ', $code'})');
  }

  @override
  Future<void> put(String name, Uint8List data) async {
    final (status, body) = await _request('PUT', '$prefix$name', body: data);
    _check(status, body, 'upload');
  }

  @override
  Future<Uint8List?> get(String name) async {
    final (status, body) = await _request('GET', '$prefix$name');
    if (status == 404) return null;
    _check(status, body, 'download');
    return body;
  }

  @override
  Future<Set<String>> list(String p) async {
    final names = <String>{};
    String? token;
    do {
      final (status, body) = await _request('GET', '', query: {
        'list-type': '2',
        'prefix': '$prefix$p',
        'continuation-token': ?token,
      });
      _check(status, body, 'listing');
      final xml = utf8.decode(body, allowMalformed: true);
      for (final m in RegExp(r'<Key>([^<]*)</Key>').allMatches(xml)) {
        final k = _xmlText(m.group(1)!);
        if (k.startsWith(prefix)) names.add(k.substring(prefix.length));
      }
      final truncated = RegExp(r'<IsTruncated>true</IsTruncated>').hasMatch(xml);
      token = truncated ? RegExp(r'<NextContinuationToken>([^<]*)</NextContinuationToken>').firstMatch(xml)?.group(1) : null;
      if (token != null) token = _xmlText(token);
    } while (token != null);
    return names;
  }

  @override
  Future<void> delete(String name) async {
    final (status, body) = await _request('DELETE', '$prefix$name');
    if (status != 404) _check(status, body, 'delete');
  }
}

// --- SFTP -------------------------------------------------------------------

/// A folder on any server with SSH. The server's host key is pinned: the
/// fingerprint shown when the target was added must match on every
/// connection, or nothing is sent.
class SftpTarget extends BackupTarget {
  final String host;
  final int port;
  final String user;
  final String? password;
  final String? privateKey;
  final String path;

  /// "SHA256:..." as OpenSSH shows it.
  final String hostKey;

  SSHClient? _client;
  SftpClient? _sftp;
  bool _madeDirs = false;

  SftpTarget({
    required this.host,
    this.port = 22,
    required this.user,
    this.password,
    this.privateKey,
    required this.path,
    required this.hostKey,
  }) {
    if (password == null && privateKey == null) throw const BackupTargetError('SFTP: give a password or a key');
    if (!hostKey.startsWith('SHA256:')) throw const BackupTargetError('SFTP: the server key fingerprint is missing');
  }

  factory SftpTarget.fromJson(Map<String, dynamic> j) => SftpTarget(
    host: j['host'] as String,
    port: j['port'] as int? ?? 22,
    user: j['user'] as String,
    password: j['password'] as String?,
    privateKey: j['key'] as String?,
    path: j['path'] as String,
    hostKey: j['hostKey'] as String,
  );

  @override
  Map<String, dynamic> toJson() => {
    'type': 'sftp',
    'host': host,
    'port': port,
    'user': user,
    'password': ?password,
    'key': ?privateKey,
    'path': path,
    'hostKey': hostKey,
  };

  @override
  String get label => 'SFTP $user@$host';

  /// The server's host key fingerprint, to show before trusting it.
  static Future<String> fetchHostKey(String host, int port) async {
    String? seen;
    try {
      final socket = await SSHSocket.connect(host, port, timeout: const Duration(seconds: 20));
      final client = SSHClient(
        socket,
        username: 'zelt',
        onVerifyHostKey: (type, fp) {
          seen = utf8.decode(fp);
          return false;
        },
      );
      try {
        await client.authenticated;
      } catch (_) {}
      client.close();
    } on SocketException catch (e) {
      throw BackupTargetError('cannot reach $host: ${e.osError?.message ?? e.message}');
    } on TimeoutException {
      throw BackupTargetError('$host did not answer in time');
    }
    if (seen == null) throw BackupTargetError('$host did not answer like an SSH server');
    return seen!;
  }

  String _remote(String name) => '${path.endsWith('/') ? path.substring(0, path.length - 1) : path}/$name';

  Future<SftpClient> _open() async {
    if (_sftp != null) return _sftp!;
    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(host, port, timeout: const Duration(seconds: 20));
    } on SocketException catch (e) {
      throw BackupTargetError('cannot reach $host: ${e.osError?.message ?? e.message}');
    }
    var keyMismatch = false;
    final client = SSHClient(
      socket,
      username: user,
      onVerifyHostKey: (type, fp) {
        final ok = utf8.decode(fp) == hostKey;
        keyMismatch = !ok;
        return ok;
      },
      onPasswordRequest: password == null ? null : () => password,
      identities: privateKey == null ? null : SSHKeyPair.fromPem(privateKey!),
    );
    try {
      await client.authenticated.timeout(const Duration(seconds: 30));
    } catch (e) {
      client.close();
      if (keyMismatch) {
        throw BackupTargetError('SFTP: $host presented a different server key than when it was added. '
            'Nothing was sent. If the server was reinstalled, remove and add this target again.');
      }
      throw BackupTargetError('SFTP: could not log in to $host ($e)');
    }
    _client = client;
    return _sftp = await client.sftp();
  }

  Future<void> _dirs(SftpClient s) async {
    if (_madeDirs) return;
    final parts = _remote(Backup.mediaPrefix).split('/');
    var cur = parts.first.isEmpty ? '' : parts.first;
    for (final p in parts.skip(1).where((p) => p.isNotEmpty)) {
      cur = '$cur/$p';
      try {
        await s.mkdir(cur);
      } catch (_) {
        // Exists (or not ours to make: the write will tell).
      }
    }
    _madeDirs = true;
  }

  @override
  Future<void> put(String name, Uint8List data) async {
    final s = await _open();
    await _dirs(s);
    final dest = _remote(name);
    final tmp = '$dest.part';
    final f = await s.open(tmp, mode: SftpFileOpenMode.create | SftpFileOpenMode.truncate | SftpFileOpenMode.write);
    try {
      await f.writeBytes(data);
    } finally {
      await f.close();
    }
    try {
      await s.remove(dest);
    } catch (_) {}
    await s.rename(tmp, dest);
  }

  @override
  Future<Uint8List?> get(String name) async {
    final s = await _open();
    final SftpFile f;
    try {
      f = await s.open(_remote(name));
    } on SftpStatusError catch (e) {
      if (e.code == SftpStatusCode.noSuchFile) return null;
      rethrow;
    }
    try {
      return await f.readBytes();
    } finally {
      await f.close();
    }
  }

  @override
  Future<Set<String>> list(String prefix) async {
    final s = await _open();
    try {
      final entries = await s.listdir(_remote(prefix));
      return {
        for (final e in entries)
          if (e.filename != '.' && e.filename != '..' && !e.filename.endsWith('.part')) '$prefix${e.filename}',
      };
    } on SftpStatusError catch (e) {
      if (e.code == SftpStatusCode.noSuchFile) return {};
      rethrow;
    }
  }

  @override
  Future<void> delete(String name) async {
    final s = await _open();
    try {
      await s.remove(_remote(name));
    } on SftpStatusError catch (e) {
      if (e.code != SftpStatusCode.noSuchFile) rethrow;
    }
  }

  @override
  Future<void> finish() async {
    _sftp?.close();
    _client?.close();
    _sftp = null;
    _client = null;
    _madeDirs = false;
  }
}

// --- One file ---------------------------------------------------------------

/// Reads and writes the one backup file (a path, or on Android a file in
/// Downloads through the platform).
class FilePackIO {
  final Future<Uint8List?> Function() read;
  final Future<void> Function(Uint8List bytes) write;
  FilePackIO(this.read, this.write);

  factory FilePackIO.path(String path) => FilePackIO(
    () async {
      final f = File(path);
      return await f.exists() ? await f.readAsBytes() : null;
    },
    (bytes) async {
      final tmp = File('$path.part');
      await tmp.parent.create(recursive: true);
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(path);
    },
  );
}

/// Everything in one file: to keep on a USB stick, in a synced folder, or
/// to carry to a new phone by hand.
class FilePackTarget extends BackupTarget {
  final FilePackIO io;
  @override
  final String label;
  Map<String, Uint8List>? _entries;
  bool _dirty = false;

  FilePackTarget(this.io, {this.label = 'File'});

  /// A pack already in memory (a file the user picked for a restore).
  factory FilePackTarget.bytes(Uint8List bytes) => FilePackTarget(FilePackIO(() async => bytes, (_) async {}));

  static final _magic = utf8.encode('ZELTPK1\n');

  @override
  Map<String, dynamic> toJson() => {'type': 'file', 'label': label};

  Future<Map<String, Uint8List>> _load() async {
    if (_entries != null) return _entries!;
    final b = await io.read();
    final m = <String, Uint8List>{};
    if (b != null && b.isNotEmpty) {
      if (b.length < _magic.length || !bytesEqual(b.sublist(0, _magic.length), _magic)) {
        throw const BackupError('this file is not a zelt backup');
      }
      final r = ByteReader(b.sublist(_magic.length));
      final n = r.u32();
      for (var i = 0; i < n; i++) {
        final name = r.str();
        m[name] = r.bytes(r.u32());
      }
    }
    return _entries = m;
  }

  @override
  Future<void> put(String name, Uint8List data) async {
    (await _load())[name] = data;
    _dirty = true;
  }

  @override
  Future<Uint8List?> get(String name) async => (await _load())[name];

  @override
  Future<Set<String>> list(String prefix) async => (await _load()).keys.where((k) => k.startsWith(prefix)).toSet();

  @override
  Future<void> delete(String name) async {
    if ((await _load()).remove(name) != null) _dirty = true;
  }

  @override
  Future<void> finish() async {
    final m = _entries;
    if (m != null && _dirty) {
      final w = ByteWriter()
        ..bytes(_magic)
        ..u32(m.length);
      // The manifest first: a reader finds it without scanning.
      final names = m.keys.toList()..sort((a, b) => a == Backup.manifestName ? -1 : (b == Backup.manifestName ? 1 : a.compareTo(b)));
      for (final n in names) {
        w
          ..str(n)
          ..u32(m[n]!.length)
          ..bytes(m[n]!);
      }
      await io.write(w.toBytes());
    }
    _entries = null;
    _dirty = false;
  }
}
