import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zelt_core/update.dart';

import 'update_key.dart';

/// An update that passed signature verification.
class AvailableUpdate {
  final UpdateManifest manifest;
  final UpdateAsset asset;
  AvailableUpdate(this.manifest, this.asset);
  String get version => manifest.version;
}

/// Self-update for Android, Linux and Windows.
///
/// Fetches the signed manifest of the latest GitHub release, verifies the
/// Ed25519 signature against the key compiled into the app, refuses anything
/// that is not newer than the running build, downloads the file for this
/// platform, checks its size and SHA-256, and only then installs it.
class Updater {
  Updater._();

  /// Overridable for testing against a local server.
  static const baseUrl = String.fromEnvironment(
    'ZELT_UPDATE_URL',
    defaultValue: 'https://github.com/gut-engel/zelt/releases/latest/download',
  );

  static const _channel = MethodChannel('zelt/service');
  static const _maxManifest = 64 * 1024;
  static const _maxAsset = 300 * 1024 * 1024;

  static PackageInfo? _info;

  static Future<PackageInfo> info() async => _info ??= await PackageInfo.fromPlatform();

  /// Android split APKs add 1000 x ABI to the version code; the release build
  /// number is the remainder.
  static Future<int> currentBuild() async => (int.tryParse((await info()).buildNumber) ?? 0) % 1000;

  static bool get supported => Platform.isAndroid || Platform.isLinux || Platform.isWindows;

  static Future<String?> _assetKey() async {
    if (Platform.isLinux) return 'linux-x64';
    if (Platform.isWindows) return 'windows-x64';
    if (Platform.isAndroid) {
      final abi = await _channel.invokeMethod<String>('abi');
      return switch (abi) {
        'arm64-v8a' => 'android-arm64',
        'armeabi-v7a' => 'android-armv7',
        'x86_64' => 'android-x64',
        _ => null,
      };
    }
    return null;
  }

  static Future<Uint8List> _get(String url, int maxBytes, [void Function(double)? progress]) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, 'zelt-updater');
      final res = await req.close();
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode} for $url');
      final total = res.contentLength;
      if (total > maxBytes) throw const UpdateRejected('file too large');
      final b = BytesBuilder(copy: false);
      await for (final chunk in res) {
        b.add(chunk);
        if (b.length > maxBytes) throw const UpdateRejected('file too large');
        if (progress != null && total > 0) progress(b.length / total);
      }
      return b.toBytes();
    } finally {
      client.close(force: true);
    }
  }

  /// Returns a verified newer release, or null if up to date.
  static Future<AvailableUpdate?> check() async {
    if (!supported) return null;
    final manifestBytes = await _get('$baseUrl/${UpdateManifest.file}', _maxManifest);
    final sig = utf8.decode(await _get('$baseUrl/${UpdateManifest.sigFile}', 4096));
    final m = await UpdateManifest.verify(manifestBytes, sig, updatePublicKey);
    if (m.build <= await currentBuild()) return null;
    final key = await _assetKey();
    final asset = key == null ? null : m.assets[key];
    if (asset == null) return null;
    return AvailableUpdate(m, asset);
  }

  /// Downloads, verifies and installs. On desktop the app restarts itself;
  /// call [onBeforeExit] to shut down cleanly first.
  static Future<void> install(
    AvailableUpdate u, {
    void Function(double)? progress,
    Future<void> Function()? onBeforeExit,
  }) async {
    final bytes = await _get('$baseUrl/${u.asset.file}', _maxAsset, progress);
    await UpdateManifest.checkFile(u.asset, bytes);
    // A fresh private directory (mkdtemp, mode 0700): in a shared /tmp another
    // local user could otherwise plant or swap the verified file, the staging
    // directory or the helper script before they are used.
    final tmp = await (await getTemporaryDirectory()).createTemp('zelt-update-');
    final file = File('${tmp.path}/${u.asset.file}');
    await file.writeAsBytes(bytes, flush: true);

    if (Platform.isAndroid) {
      // The system installer also checks that the APK is signed with the same
      // key as the installed app.
      await _channel.invokeMethod('installApk', {'path': file.path});
      return;
    }
    final appDir = File(Platform.resolvedExecutable).parent;
    if (!await _writable(appDir)) {
      throw UpdateRejected('cannot write to ${appDir.path}; download it from the releases page');
    }
    if (Platform.isLinux) {
      await _installLinux(file, appDir, tmp);
    } else if (Platform.isWindows) {
      await _installWindows(file, appDir, tmp);
    }
    await onBeforeExit?.call();
    exit(0);
  }

  static Future<bool> _writable(Directory d) async {
    try {
      final probe = File('${d.path}/.zelt-update-probe');
      await probe.writeAsString('x');
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Unpacks next to the app, then a detached helper waits for this process to
  /// exit, copies the new files over the old ones and starts the new version.
  static Future<void> _installLinux(File archive, Directory appDir, Directory tmp) async {
    final stage = Directory('${tmp.path}/zelt-update-stage');
    if (await stage.exists()) await stage.delete(recursive: true);
    await stage.create(recursive: true);
    final r = await Process.run('tar', ['-xzf', archive.path, '-C', stage.path]);
    if (r.exitCode != 0) throw UpdateRejected('could not unpack: ${r.stderr}');
    if (!await File('${stage.path}/zelt').exists()) throw const UpdateRejected('archive has no zelt binary');
    final script = File('${tmp.path}/zelt-update.sh');
    String q(String s) => "'${s.replaceAll("'", "'\\''")}'";
    await script.writeAsString('''#!/bin/sh
while kill -0 $pid 2>/dev/null; do sleep 0.3; done
cp -a ${q('${stage.path}/.')} ${q('${appDir.path}/')} && rm -rf ${q(tmp.path)}
exec ${q('${appDir.path}/zelt')} >/dev/null 2>&1
''');
    await Process.start('/bin/sh', [script.path], mode: ProcessStartMode.detached);
  }

  static Future<void> _installWindows(File archive, Directory appDir, Directory tmp) async {
    final stage = '${tmp.path}\\zelt-update-stage';
    final script = File('${tmp.path}\\zelt-update.ps1');
    String q(String s) => "'${s.replaceAll("'", "''")}'";
    await script.writeAsString('''
\$ErrorActionPreference = 'Stop'
Wait-Process -Id $pid -ErrorAction SilentlyContinue
if (Test-Path ${q(stage)}) { Remove-Item -Recurse -Force ${q(stage)} }
Expand-Archive -Path ${q(archive.path)} -DestinationPath ${q(stage)} -Force
Copy-Item -Path (Join-Path ${q(stage)} '*') -Destination ${q(appDir.path)} -Recurse -Force
Remove-Item -Recurse -Force ${q(tmp.path)}
Start-Process -FilePath (Join-Path ${q(appDir.path)} 'zelt.exe')
''');
    await Process.start(
      'powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', script.path],
      mode: ProcessStartMode.detached,
    );
  }
}
