@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zelt/app/app_state.dart';
import 'package:zelt_core/backup_targets.dart';
import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/messenger.dart';
import 'package:zelt_core/models.dart';
import 'package:zelt_core/phrase.dart';
import 'package:zelt_core/vault.dart';

/// A friend for [app] (paired locally; nothing has to be delivered).
Future<Contact> friend(AppState app, String name) async {
  final other = Messenger(identity: await Identity.generate(), settings: Settings(name: name));
  final mine = await app.m.newPairingSession();
  final theirs = await other.newPairingSession();
  await other.completePairing(theirs, mine.code);
  return app.m.completePairing(mine, theirs.code, name: name);
}

Settings quiet(String name) => Settings(name: name, port: 0, relay: false);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('zelt-app'));
  tearDown(() async => dir.delete(recursive: true));

  test('the duress PIN opens zelt without private chats, and they survive it', () async {
    final app = AppState();
    await app.initAt(dir);
    await app.setup('me', 'real-pin', settings: quiet('me'));
    final open = await friend(app, 'Olivia');
    final secret = await friend(app, 'Sam');
    app.setPrivate(secret.id, true);
    final g = await app.m.createGroup('Secret club', [secret.id]);
    app.setPrivate(g.id, true);
    await app.m.sendText(secret.id, 'only for Sam');
    await app.setDuressPin('duress-pin');
    expect(app.duressPinSet, isTrue);
    await app.m.save();
    await app.lock();

    // Nothing in the public part names Sam or the group.
    final dv = await Vault.unlock(dir, 'duress-pin');
    final public = (await dv.load())!;
    final text = public.toString();
    expect(text.contains(secret.id), isFalse);
    expect(text.contains('Sam'), isFalse);
    expect(text.contains(g.id), isFalse);

    await app.unlock('duress-pin');
    expect(app.duress, isTrue);
    expect(app.m.contacts.keys, [open.id]);
    expect(app.m.groups, isEmpty);
    expect(app.duressPinSet, isFalse, reason: 'looks like a vault without a duress PIN');
    // The duress session marks Olivia private: she is hidden from the next
    // duress session too, and still there with the real PIN.
    app.setPrivate(open.id, true);
    await app.m.save();
    await app.lock();

    await app.unlock('duress-pin');
    expect(app.m.contacts, isEmpty);
    await app.lock();

    await app.unlock('real-pin');
    expect(app.duress, isFalse);
    expect(app.m.contacts.keys.toSet(), {open.id, secret.id});
    expect(app.m.contacts[secret.id]!.messages.single.text, 'only for Sam');
    expect(app.m.groups.keys, [g.id]);
    expect(app.m.contacts[open.id]!.private, isTrue);
    // Un-hiding works the same way.
    app.setPrivate(open.id, false);
    await app.m.save();
    await app.lock();
    await app.unlock('duress-pin');
    expect(app.m.contacts.keys, [open.id]);
    await app.lock();
  });

  test('a backup restores the identity, the chats and the private ones on a new device', () async {
    final app = AppState();
    await app.initAt(dir);
    await app.setup('me', 'real-pin', settings: quiet('me'));
    final open = await friend(app, 'Olivia');
    final secret = await friend(app, 'Sam');
    app.setPrivate(secret.id, true);
    await app.m.sendText(open.id, 'hello Olivia');
    final phrase = BackupPhrase.generate();
    await app.backup!.usePhrase(phrase);
    final file = '${dir.path}/out/zelt-backup.zbk';
    app.backup!.addTarget({'type': 'file', 'path': file, 'label': 'File'});
    expect(await app.backup!.runNow(), isEmpty);
    expect(app.backup!.targets.single.lastOk, isNotNull);
    final id = hex(app.m.identity.id.pub);
    // Once replaced by another device, this one never backs up again.
    final size = File(file).lengthSync();
    app.m.superseded = true;
    expect(await app.backup!.runNow(), isEmpty);
    expect(File(file).lengthSync(), size);
    expect(app.m.backupJson()['superseded'], isNull, reason: 'a backup never carries the flag');
    app.m.superseded = false;
    await app.lock();

    // A new device: no vault yet.
    final newDir = await Directory.systemTemp.createTemp('zelt-new');
    addTearDown(() => newDir.delete(recursive: true));
    final fresh = AppState();
    await fresh.initAt(newDir);
    expect(fresh.phase, Phase.setup);
    // The wrong words open nothing and leave nothing behind.
    await expectLater(
      fresh.restore(FilePackTarget(FilePackIO.path(file)), BackupPhrase.generate(), 'new-pin'),
      throwsA(anything),
    );
    expect(Vault.exists(newDir), isFalse);
    await fresh.restore(FilePackTarget(FilePackIO.path(file)), phrase, 'new-pin');
    expect(fresh.phase, Phase.unlocked);
    expect(hex(fresh.m.identity.id.pub), id);
    expect(fresh.m.contacts.keys.toSet(), {open.id, secret.id});
    expect(fresh.m.contacts[secret.id]!.private, isTrue);
    expect(fresh.m.contacts[open.id]!.messages.single.text, 'hello Olivia');
    expect(fresh.m.contacts.values.every((c) => !c.ready && c.epoch > 0), isTrue, reason: 'new sessions');
    expect(fresh.backup!.configured, isTrue, reason: 'backups go on with the same words');
    expect(fresh.backup!.targets, hasLength(1));
    await fresh.lock();
    await fresh.unlock('new-pin');
    expect(fresh.m.contacts[secret.id]!.private, isTrue);
    await fresh.lock();
  });
}
