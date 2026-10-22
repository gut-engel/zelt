import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zelt/app/updater.dart';
import 'package:zelt_core/update.dart';

/// Runs the real Linux install helper: it must wait for the old process,
/// replace the bundle, start the new binary and clean up its private
/// staging directory, also when the install path needs shell quoting.
void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('zelt-up-test-'));
  tearDown(() async => root.delete(recursive: true));

  Future<File> archiveWith(Map<String, String> files) async {
    final src = await Directory('${root.path}/src').create();
    for (final e in files.entries) {
      final f = File('${src.path}/${e.key}');
      await f.writeAsString(e.value);
      await Process.run('chmod', ['755', f.path]);
    }
    final a = File('${root.path}/zelt-9.9.9-linux-x64.tar.gz');
    final r = await Process.run('tar', ['-czf', a.path, '-C', src.path, '.']);
    expect(r.exitCode, 0);
    return a;
  }

  test('replaces the bundle after the old process exits and starts the new one', () async {
    final appDir = await Directory("${root.path}/app dir's \$HOME").create();
    await File('${appDir.path}/zelt').writeAsString('old');
    await File('${appDir.path}/keep.txt').writeAsString('untouched');
    final marker = File('${root.path}/started');
    final archive = await archiveWith({
      'zelt': '#!/bin/sh\necho "new started" > \'${marker.path}\'\n',
      'data.txt': 'v9',
    });
    final tmp = await root.createTemp('zelt-update-');
    final old = await Process.start('sleep', ['1']);
    final t0 = DateTime.now();

    await Updater.installLinux(archive, appDir, tmp, waitPid: old.pid);

    for (var i = 0; i < 100 && !await marker.exists(); i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    expect(await marker.readAsString(), 'new started\n');
    expect(DateTime.now().difference(t0), greaterThan(const Duration(milliseconds: 800)),
        reason: 'waited for the old process');
    expect(await File('${appDir.path}/data.txt').readAsString(), 'v9');
    expect(await File('${appDir.path}/keep.txt').readAsString(), 'untouched');
    expect(await tmp.exists(), isFalse, reason: 'private staging dir removed');
  });

  test('an archive without the zelt binary is rejected before anything changes', () async {
    final appDir = await Directory('${root.path}/app').create();
    await File('${appDir.path}/zelt').writeAsString('old');
    final archive = await archiveWith({'other': 'x'});
    final tmp = await root.createTemp('zelt-update-');
    await expectLater(Updater.installLinux(archive, appDir, tmp), throwsA(isA<UpdateRejected>()));
    expect(await File('${appDir.path}/zelt').readAsString(), 'old');
  });
}
