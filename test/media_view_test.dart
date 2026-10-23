import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zelt/app/media_view.dart';
import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/media.dart';
import 'package:zelt_core/messenger.dart';
import 'package:zelt_core/models.dart';

void main() {
  testWidgets('a media view handed other media never shows the old picture', (tester) async {
    late Messenger m;
    MediaRef sticker() =>
        MediaRef(hash: randomBytes(32), size: 1000, kind: MediaKind.sticker, format: MediaFormat.webp, width: 64, height: 64);
    final red = sticker(), blue = sticker();
    await tester.runAsync(() async {
      m = Messenger(identity: await Identity.generate(), settings: Settings(name: 'me', port: 0));
      MediaCache.instance.put(red.id, MediaFrames([await createTestImage(width: 64, height: 64)], [100]));
      MediaCache.instance.put(blue.id, MediaFrames([await createTestImage(width: 64, height: 64)], [100]));
    });

    // Same position, no key: Flutter reuses the state, as in a chat list
    // where a new message pushes the others along.
    Widget at(MediaRef r) => Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: MediaView(messenger: m, media: r, maxWidth: 64, maxHeight: 64)),
    );
    RawImage shown() => tester.widget<RawImage>(find.byType(RawImage));

    await tester.pumpWidget(at(red));
    expect(shown().image, same(MediaCache.instance.peek(red.id)!.images.first));
    await tester.pumpWidget(at(blue));
    expect(shown().image, same(MediaCache.instance.peek(blue.id)!.images.first));
  });

  testWidgets('media that arrives while a load is running shows at once', (tester) async {
    late Messenger m;
    final store = _GatedStore();
    final ref = MediaRef(hash: randomBytes(32), size: 1000, kind: MediaKind.sticker, format: MediaFormat.webp, width: 64, height: 64);
    late MediaFrames frames;
    late Identity id;
    await tester.runAsync(() async {
      id = await Identity.generate();
      frames = MediaFrames([await createTestImage(width: 64, height: 64)], [100]);
    });
    // Built in the test's zone, so its change events run on the test clock.
    m = Messenger(identity: id, settings: Settings(name: 'me', port: 0))..media = store;

    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: MediaView(messenger: m, media: ref, maxWidth: 64, maxHeight: 64)),
    ));
    expect(store.pending, isNotNull, reason: 'first look at the store is running');

    // The bytes land (decoded here) and the messenger says so, while that
    // first look is still running; then it comes back empty.
    MediaCache.instance.put(ref.id, frames);
    m.removeSticker('none'); // any change notification
    await tester.pump();
    store.pending!.complete(null);
    await tester.idle();
    await tester.pump();

    expect(find.byType(RawImage), findsOneWidget, reason: 'no waiting for a later, unrelated change');
    await tester.pump(const Duration(seconds: 1)); // the messenger's save timer
  });

  test('a load for bytes that are not here yet finishes (empty)', () async {
    final m = Messenger(identity: await Identity.generate(), settings: Settings(name: 'me', port: 0));
    final ref = MediaRef(hash: randomBytes(32), size: 1000, kind: MediaKind.image, format: MediaFormat.webp, width: 64, height: 64);
    expect(await MediaCache.instance.load(m, ref).timeout(const Duration(seconds: 5)), isNull);
    expect(await MediaCache.instance.load(m, ref).timeout(const Duration(seconds: 5)), isNull, reason: 'and again');
  });
}

/// The first read waits until the test releases it.
class _GatedStore implements MediaStore {
  Completer<Uint8List?>? pending;
  @override
  Future<Uint8List?> read(String hash) {
    if (pending == null) return (pending = Completer<Uint8List?>()).future;
    return Future.value(null);
  }

  @override
  Future<void> write(String hash, Uint8List bytes) async {}
  @override
  Future<bool> has(String hash) async => false;
}
