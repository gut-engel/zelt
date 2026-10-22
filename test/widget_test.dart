import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zelt/app/app_state.dart';
import 'package:zelt_core/messenger.dart';
import 'package:zelt_core/models.dart';
import 'package:zelt/app/screens/pair_screen.dart';
import 'package:zelt/main.dart';

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
  pairQrAutoHide();
}

Future<AppState> unlockedWithFriend(WidgetTester tester) async {
  final app = AppState();
  await tester.runAsync(() async {
    final a = Messenger(identity: await Identity.generate(), settings: Settings(name: 'me'));
    final b = Messenger(identity: await Identity.generate(), settings: Settings(name: 'Robin'));
    final sa = await a.newPairingSession();
    final sb = await b.newPairingSession();
    final c = await a.completePairing(sa, sb.code);
    c.messages.add(Message(id: 'x', outgoing: false, text: 'hey there', time: DateTime.now()));
    c.messages.add(Message(id: 'y', outgoing: true, text: 'hi!', time: DateTime.now(), status: MsgStatus.delivered));
    app.messenger = a;
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
    await tester.pumpWidget(ChangeNotifierProvider.value(value: app, child: const ZeltApp()));
    await tester.tap(find.text('Add friend'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('In person'));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 500)));
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('add friend offers an invite text as the second way', (tester) async {
    final app = await unlockedWithFriend(tester);
    await tester.pumpWidget(ChangeNotifierProvider.value(value: app, child: const ZeltApp()));
    await tester.tap(find.text('Add friend'));
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

void pairQrAutoHide() {
  testWidgets('pairing QR warns, hides itself after the timeout and can be shown again', (tester) async {
    final app = await unlockedWithFriend(tester);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: const MaterialApp(home: PairScreen(qrTimeout: Duration(seconds: 2))),
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
  });
}
