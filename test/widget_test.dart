import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zelt/app/app_state.dart';
import 'package:zelt_core/messenger.dart';
import 'package:zelt_core/models.dart';
import 'package:zelt/app/screens/pair_screen.dart';
import 'package:zelt/main.dart';
import 'package:zelt/app/media_view.dart';
import 'package:zelt/app/screens/settings_screen.dart';
import 'package:zelt/app/screens/backup_screens.dart';
import 'package:zelt/app/screens/contact_screen.dart';
import 'package:zelt/app/backup_service.dart';
import 'package:zelt_core/groups.dart';
import 'package:zelt_core/vault.dart';
import 'dart:io';
import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/media.dart';
import 'package:zelt_core/crypto.dart';
import 'package:zelt_core/ratchet.dart';

void main() {
  testWidgets('first launch shows identity setup', (tester) async {
    final app = AppState()..phase = Phase.setup;
    await tester.pumpWidget(ChangeNotifierProvider.value(value: app, child: const ZeltApp()));
    expect(find.text('Create identity'), findsOneWidget);
    expect(find.textContaining('No servers'), findsOneWidget);
  });

  testWidgets('locked app asks for the PIN', (tester) async {
    final app = AppState()..phase = Phase.locked;
    await tester.pumpWidget(ChangeNotifierProvider.value(value: app, child: const ZeltApp()));
    expect(find.text('Unlock'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  screens();
  pairScreen();
  mediaScreens();
  pairQrAutoHide();
  pairLinked();
  profilePictures();
  newFeatures();
}

final msgX = '0a' * 16, msgY = '0b' * 16;

Future<AppState> unlockedWithFriend(WidgetTester tester) async {
  final app = AppState();
  await tester.runAsync(() async {
    final a = Messenger(identity: await Identity.generate(), settings: Settings(name: 'me', port: 0));
    final b = Messenger(identity: await Identity.generate(), settings: Settings(name: 'Robin'));
    final sa = await a.newPairingSession();
    final sb = await b.newPairingSession();
    final c = await a.completePairing(sa, sb.code);
    c.messages.add(Message(id: msgX, outgoing: false, text: 'hey there', time: DateTime.now()));
    c.messages.add(Message(id: msgY, outgoing: true, text: 'hi!', time: DateTime.now(), status: MsgStatus.delivered));
    app.useMessenger(a);
  });
  app.phase = Phase.unlocked;
  return app;
}

void screens() {
  testWidgets('home, chat, contact, settings and network screens render', (tester) async {
    final app = await unlockedWithFriend(tester);
    await tester.pumpWidget(ChangeNotifierProvider.value(value: app, child: const ZeltApp()));
    expect(find.text('Robin'), findsOneWidget);
    await tester.tap(find.text('Robin'));
    await tester.pumpAndSettle();
    expect(find.text('hey there'), findsOneWidget);
    expect(find.byIcon(Icons.done_all), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'draft');
    await tester.pump();
    await tester.tap(find.text('Robin').first);
    await tester.pumpAndSettle();
    expect(find.text('Safety number'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Onion hops: 4'), findsOneWidget);
    await tester.tap(find.text('Paranoid'));
    await tester.pump();
    expect(app.m.settings.delay, DelayMode.paranoid);
    await tester.scrollUntilVisible(find.text('Network and peers'), 200);
    await tester.tap(find.text('Network and peers'));
    await tester.pumpAndSettle();
    expect(find.text('Your relay'), findsOneWidget);
  });
}

void pairScreen() {
  testWidgets('pair screen shows the QR code', (tester) async {
    final app = await unlockedWithFriend(tester);
    // The QR code is an invite: it needs a mailbox, here our own relay.
    await tester.runAsync(() => app.m.node.start(relay: true));
    addTearDown(() => tester.runAsync(() => app.m.node.stop()));
    await tester.pumpWidget(ChangeNotifierProvider.value(value: app, child: const ZeltApp()));
    await tester.tap(find.text('New chat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('In person'));
    await tester.pumpAndSettle();
    // The real screen makes its invite in the background (real crypto and
    // network I/O, which the widget test clock does not run); check the chooser
    // led to it, then render it with an invite made under real time.
    expect(find.byType(PairScreen), findsOneWidget);
    final inv = (await tester.runAsync(() => app.m.createInvite()))!;
    await tester.pumpWidget(ChangeNotifierProvider.value(value: app, child: MaterialApp(home: PairScreen(invite: inv))));
    await tester.pump();
    expect(find.byType(QrImageView), findsOneWidget);
    expect(tester.takeException(), isNull);
    // Leaving the screen shortens the invite and saves (a short timer).
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 3));
  });

  testWidgets('add friend offers an invite text as the second way', (tester) async {
    final app = await unlockedWithFriend(tester);
    await tester.pumpWidget(ChangeNotifierProvider.value(value: app, child: const ZeltApp()));
    await tester.tap(find.text('New chat'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('addByInvite')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('createInvite')), findsOneWidget);
    expect(find.byKey(const Key('inviteInput')), findsOneWidget);
    // A QR code pasted as an invite is refused with an explanation.
    final qr = (await tester.runAsync(() => app.m.newPairingSession()))!.code;
    await tester.enterText(find.byKey(const Key('inviteInput')), qr);
    await tester.tap(find.byKey(const Key('joinInvite')));
    await tester.pump();
    expect(find.textContaining('in-person QR code'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

void pairLinked() {
  testWidgets('a friend scanning our code shows the safety number and the end of the key exchange', (tester) async {
    final app = await unlockedWithFriend(tester);
    await tester.runAsync(() => app.m.node.start(relay: true));
    addTearDown(() => tester.runAsync(() => app.m.node.stop()));
    final inv = (await tester.runAsync(() => app.m.createInvite()))!;
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(home: PairScreen(invite: inv)),
    ));
    // The friend's join request: the invite is used up and a contact appears,
    // its key exchange still running.
    final c = (await tester.runAsync(() async {
      final f = Messenger(identity: await Identity.generate(), settings: Settings(name: 'Sam'));
      final sa = await app.m.newPairingSession();
      final sf = await f.newPairingSession();
      app.m.cancelInvite(inv.id);
      return app.m.completePairing(sa, sf.code);
    }))!;
    await tester.pump();
    expect(c.ready, isFalse);
    expect(find.byIcon(Icons.hourglass_top), findsOneWidget);
    expect(find.byKey(const Key('safetyNumber')), findsOneWidget);
    expect(find.textContaining(c.keys.safetyNumber.split(' ').first), findsOneWidget);
    // The key exchange finishes later: the screen follows without any input.
    await tester.runAsync(() async => c.ratchet = await Ratchet.bob(randomBytes(32), c.myEph));
    app.m.renameContact(c.id, c.name);
    await tester.pump();
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byIcon(Icons.hourglass_top), findsNothing);
    await tester.tap(find.byKey(const Key('numbersMatch')));
    await tester.pump();
    expect(app.m.contacts[c.id]!.verified, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 3));
  });
}

void pairQrAutoHide() {
  testWidgets('pairing QR warns, hides itself after the timeout and can be shown again', (tester) async {
    final app = await unlockedWithFriend(tester);
    await tester.runAsync(() => app.m.node.start(relay: true));
    addTearDown(() => tester.runAsync(() => app.m.node.stop()));
    final inv = (await tester.runAsync(() => app.m.createInvite()))!;
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(home: PairScreen(qrTimeout: const Duration(seconds: 2), invite: inv)),
    ));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 500)));
    await tester.pump();
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.textContaining('Anyone who photographs it'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.byType(QrImageView), findsNothing);
    await tester.tap(find.byKey(const Key('showQrAgain')));
    await tester.pump();
    expect(find.byType(QrImageView), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.byType(QrImageView), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}

void mediaScreens() {
  testWidgets('chat shows image and sticker messages; the sticker picker opens', (tester) async {
    final app = await unlockedWithFriend(tester);
    final c = app.m.contacts.values.single;
    MediaRef ref(MediaKind k, int w, int h) =>
        MediaRef(hash: randomBytes(32), size: 1000, kind: k, format: MediaFormat.webp, width: w, height: h);
    c.messages
      ..add(Message(id: 'img', outgoing: false, text: 'a caption', time: DateTime.now(), media: ref(MediaKind.image, 1280, 960)))
      ..add(Message(id: 'stk', outgoing: true, text: '', time: DateTime.now(), media: ref(MediaKind.sticker, 256, 256)));
    await tester.pumpWidget(ChangeNotifierProvider.value(value: app, child: const ZeltApp()));
    await tester.tap(find.text('Robin'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(MediaView), findsNWidgets(2), reason: 'placeholders until the bytes arrive');
    expect(find.text('a caption'), findsOneWidget);
    await tester.tap(find.byTooltip('Stickers'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('addSticker')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}

void profilePictures() {
  testWidgets('a friend\'s profile picture shows only once they are verified', (tester) async {
    final app = await unlockedWithFriend(tester);
    final c = app.m.contacts.values.single;
    final pic = MediaRef(hash: randomBytes(32), size: 1000, kind: MediaKind.avatar, format: MediaFormat.webp, width: 256, height: 256);
    c.theirAvatar = pic;
    await tester.runAsync(() async {
      MediaCache.instance.put(pic.id, MediaFrames([await createTestImage(width: 64, height: 64)], [100]));
    });
    await tester.pumpWidget(ChangeNotifierProvider.value(value: app, child: const ZeltApp()));
    await tester.pump();
    expect(find.text('Robin'), findsOneWidget);
    expect(find.byType(RawImage), findsNothing, reason: 'not verified: initials only');
    expect(find.text('R'), findsOneWidget);
    app.m.setVerified(c.id, true);
    await tester.tap(find.text('Robin'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(RawImage), findsOneWidget, reason: 'verified: the chat shows the picture');
    // Our own picture is set in the settings.
    await tester.pumpWidget(ChangeNotifierProvider.value(value: app, child: const MaterialApp(home: SettingsScreen())));
    await tester.pump();
    await tester.scrollUntilVisible(find.byKey(const Key('profilePicture')), 200);
    expect(find.byKey(const Key('profilePicture')), findsOneWidget);
    expect(find.textContaining('Only verified friends see it (1 now)'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}

void newFeatures() {
  testWidgets('first launch offers to restore a backup', (tester) async {
    final app = AppState()..phase = Phase.setup;
    await tester.pumpWidget(ChangeNotifierProvider.value(value: app, child: const ZeltApp()));
    await tester.scrollUntilVisible(find.byKey(const Key('restoreBackup')), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('restoreBackup')));
    await tester.pumpAndSettle();
    expect(find.text('Restore from backup'), findsWidgets);
    expect(find.byKey(const Key('restoreWords')), findsOneWidget);
    // Words are checked while typing.
    await tester.enterText(find.byKey(const Key('restoreWords')), 'abandon abandon xyzzy ');
    await tester.pump();
    expect(find.textContaining('Word 3 is not in the word list'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('restoreWords')), List.filled(12, 'abandon').join(' '));
    await tester.pump();
    expect(find.textContaining('do not fit together'), findsOneWidget);
  });

  testWidgets('a new identity is offered a backup, which can be skipped', (tester) async {
    final app = await unlockedWithFriend(tester);
    app.offerBackup = true;
    await tester.pumpWidget(ChangeNotifierProvider.value(value: app, child: const ZeltApp()));
    expect(find.text('Back up your chats?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('skipBackup')));
    await tester.pumpAndSettle();
    expect(find.text('Robin'), findsOneWidget);
  });

  testWidgets('the phrase is shown once and three words are checked', (tester) async {
    final app = await unlockedWithFriend(tester);
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('zelt-w')))!;
    addTearDown(() => tester.runAsync(() => dir.delete(recursive: true)));
    final vault = (await tester.runAsync(() => Vault.create(dir, 'pin-123456')))!;
    app.backup = BackupService(app.m, vault);
    var done = false;
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(home: PhraseScreen(onDone: () => done = true)),
    ));
    final words = [for (var i = 0; i < 12; i++) (tester.widget<Text>(find.byKey(Key('word$i')))).data!];
    await tester.tap(find.byKey(const Key('wroteItDown')));
    await tester.pumpAndSettle();
    int asked(int field) {
      final label = tester.widget<TextField>(find.byKey(Key('check$field'))).decoration!.labelText!;
      return int.parse(label.split(' ').last) - 1;
    }

    // A wrong word is refused.
    await tester.enterText(find.byKey(const Key('check0')), words[asked(0)] == 'zoo' ? 'abandon' : 'zoo');
    await tester.enterText(find.byKey(const Key('check1')), words[asked(1)]);
    await tester.enterText(find.byKey(const Key('check2')), words[asked(2)]);
    await tester.tap(find.byKey(const Key('checkWords')));
    await tester.pump();
    expect(find.textContaining('does not match'), findsOneWidget);
    expect(app.backup!.configured, isFalse);
    // The right ones (four letters are enough).
    await tester.enterText(find.byKey(const Key('check0')), words[asked(0)].substring(0, words[asked(0)].length.clamp(3, 4)));
    await tester.tap(find.byKey(const Key('checkWords')));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    expect(app.backup!.configured, isTrue);
    expect(find.byKey(const Key('addTarget')), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('backupDone')), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('backupDone')));
    expect(done, isTrue);
  });

  testWidgets('long-press a message to react or reply', (tester) async {
    final app = await unlockedWithFriend(tester);
    await tester.pumpWidget(ChangeNotifierProvider.value(value: app, child: const ZeltApp()));
    await tester.tap(find.text('Robin'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('hey there'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('react👍')));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    final c = app.m.contacts.values.single;
    expect(c.messages.firstWhere((m) => m.id == msgX).shownReactions[Message.me], '👍');
    expect(find.text('👍'), findsOneWidget);

    await tester.longPress(find.text('hey there'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('replyAction')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('replyPreview')), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'sure');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(c.messages.last.replyTo, msgX);
    expect(find.byKey(const Key('replyPreview')), findsNothing);
    expect(find.text('hey there'), findsNWidgets(2), reason: 'the quote shows the answered message');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a group invitation shows in the list and can be joined', (tester) async {
    final app = await unlockedWithFriend(tester);
    final robin = app.m.contacts.values.single;
    final roster = (await tester.runAsync(() async {
      final adminKey = await Crypto.ed25519Generate();
      return Roster.sign(adminKey, groupId: randomBytes(16), version: 1, name: 'Hiking', members: [
        GroupMember(robin.idPub, adminKey.pub, 'Robin'),
      ]);
    }))!;
    app.m.groups[roster.id] = Group(id: roster.id, roster: roster, state: GroupState.invited, invitedBy: robin.id);
    await tester.pumpWidget(ChangeNotifierProvider.value(value: app, child: const ZeltApp()));
    expect(find.text('Hiking'), findsOneWidget);
    expect(find.text('Robin invited you'), findsOneWidget);
    await tester.tap(find.text('Hiking'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('joinGroup')), findsOneWidget);
    await tester.tap(find.byKey(const Key('joinGroup')));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    expect(app.m.groups[roster.id]!.state, GroupState.joining);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a chat is marked private on its contact screen', (tester) async {
    final app = await unlockedWithFriend(tester);
    final c = app.m.contacts.values.single;
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(home: ContactScreen(contactId: c.id)),
    ));
    await tester.scrollUntilVisible(find.byKey(const Key('contactPrivate')), 200);
    await tester.tap(find.byKey(const Key('contactPrivate')));
    await tester.pump();
    expect(c.private, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('settings show backup and the duress PIN', (tester) async {
    final app = await unlockedWithFriend(tester);
    await tester.pumpWidget(ChangeNotifierProvider.value(value: app, child: const MaterialApp(home: SettingsScreen())));
    await tester.scrollUntilVisible(find.byKey(const Key('backupSettings')), 200);
    expect(find.byKey(const Key('backupSettings')), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('duressPin')), 200);
    expect(find.textContaining('A second PIN'), findsOneWidget);
    await tester.tap(find.byKey(const Key('duressPin')));
    await tester.pumpAndSettle();
    expect(find.textContaining('private hidden'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('pinA')), '12');
    await tester.enterText(find.byKey(const Key('pinB')), '12');
    await tester.tap(find.byKey(const Key('pinSave')));
    await tester.pump();
    expect(find.text('Use at least 6 characters'), findsOneWidget);
  });
}
