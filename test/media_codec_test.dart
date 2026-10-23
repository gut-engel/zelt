import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zelt/app/media_codec.dart';
import 'package:zelt_core/crypto.dart';
import 'package:zelt_core/media.dart';

img.Image photo(int w, int h) {
  final r = Random(1);
  final im = img.Image(width: w, height: h);
  for (final p in im) {
    p
      ..r = (p.x * 255 ~/ w + r.nextInt(30)).clamp(0, 255)
      ..g = (p.y * 255 ~/ h + r.nextInt(30)).clamp(0, 255)
      ..b = (128 + r.nextInt(60)).clamp(0, 255);
  }
  return im;
}

img.Image animation(int w, int h, int frames) {
  late img.Image anim;
  for (var i = 0; i < frames; i++) {
    final f = img.Image(width: w, height: h, numChannels: 4)..frameDuration = 70;
    img.fillCircle(f, x: (w * i) ~/ frames, y: h ~/ 2, radius: h ~/ 4, color: img.ColorRgba8(220, 40, 40, 255));
    if (i == 0) {
      anim = f;
    } else {
      anim.addFrame(f);
    }
  }
  return anim;
}

MediaRef refFor(PreparedMedia p, MediaKind kind) => MediaRef(
  hash: CryptoSync.sha256(p.bytes),
  size: p.bytes.length,
  kind: kind,
  format: MediaFormat.webp,
  width: p.width,
  height: p.height,
);

bool containsAscii(Uint8List b, String s) {
  final t = s.codeUnits;
  outer:
  for (var i = 0; i + t.length <= b.length; i++) {
    for (var j = 0; j < t.length; j++) {
      if (b[i + j] != t[j]) continue outer;
    }
    return true;
  }
  return false;
}

void main() {
  test('a profile picture is a small, centred square without metadata', () async {
    final p = await prepareAvatar(img.encodeJpg(photo(1600, 900), quality: 95));
    expect((p.width, p.height), (avatarSide, avatarSide));
    expect(p.bytes.length, lessThanOrEqualTo(avatarTargetBytes));
    final d = await decodeReceived(p.bytes, refFor(p, MediaKind.avatar));
    expect(d.frames, hasLength(1));
    expect(d.width, avatarSide);
  });

  test('a photo becomes a small WebP, scaled and without metadata', () async {
    final src = photo(3000, 2000);
    src.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(48, 1);
    src.exif.imageIfd['Make'] = img.IfdValueAscii('SpyCam');
    final jpeg = img.encodeJpg(src, quality: 95);
    expect(containsAscii(jpeg, 'SpyCam'), isTrue);

    final p = await preparePhoto(jpeg);
    expect(MediaFormat.sniff(p.bytes), MediaFormat.webp);
    expect(p.width, photoMaxSide);
    expect(p.height, 853);
    expect(p.bytes.length, lessThanOrEqualTo(photoTargetBytes));
    expect(containsAscii(p.bytes, 'SpyCam'), isFalse, reason: 'metadata stripped');
    expect(containsAscii(p.bytes, 'EXIF'), isFalse);

    final d = await decodeReceived(p.bytes, refFor(p, MediaKind.image));
    expect(d.frames.single.length, p.width * p.height * 4);
  });

  test('an animated GIF becomes an animated WebP sticker', () async {
    final gif = img.encodeGif(animation(400, 300, 6));
    final p = await prepareSticker(gif);
    expect(MediaFormat.sniff(p.bytes), MediaFormat.webp);
    expect(p.width, stickerSide);
    expect(p.frames, 6);
    expect(p.bytes.length, lessThanOrEqualTo(maxStickerBytes));
    final d = await decodeReceived(p.bytes, refFor(p, MediaKind.sticker));
    expect(d.frames.length, 6);
    expect(d.durationsMs.every((ms) => ms >= 20), isTrue);
  });

  test('long animations are cut to the frame limit', () async {
    final gif = img.encodeGif(animation(64, 64, 200));
    final p = await prepareSticker(gif);
    expect(p.frames, lessThanOrEqualTo(maxStickerFrames));
  });

  test('received media: anything malformed or out of range is rejected, never parsed natively', () async {
    final good = await prepareSticker(img.encodePng(photo(200, 200)));
    final ref = refFor(good, MediaKind.sticker);

    Future<void> rejects(Uint8List bytes, MediaRef r) async {
      await expectLater(() => decodeReceived(bytes, r), throwsA(isA<MediaRejected>()));
    }

    // Not WebP at all: refused before any decoding.
    final png = img.encodePng(photo(50, 50));
    await rejects(png, refFor(PreparedMedia(png, 50, 50, 1), MediaKind.sticker));
    // A WebP header followed by garbage.
    final garbage = Uint8List.fromList([...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits, ...List.filled(500, 7)]);
    await rejects(garbage, refFor(PreparedMedia(garbage, 10, 10, 1), MediaKind.sticker));
    // Truncated.
    final cut = good.bytes.sublist(0, good.bytes.length ~/ 2);
    await rejects(cut, refFor(PreparedMedia(cut, good.width, good.height, 1), MediaKind.sticker));
    // Larger than a sticker may be (a valid file, just too big).
    final wide = img.encodeWebP(photo(400, 20), lossless: false);
    await rejects(wide, refFor(PreparedMedia(wide, 300, 15, 1), MediaKind.sticker));
    // Size mismatch with the reference.
    await rejects(Uint8List.fromList([...good.bytes, 0]), ref);

    // Mutations of a valid file: only clean rejections or decodes.
    final rnd = Random(7);
    for (var i = 0; i < 200; i++) {
      final m = Uint8List.fromList(good.bytes);
      for (var k = 0; k < 1 + rnd.nextInt(8); k++) {
        m[12 + rnd.nextInt(m.length - 12)] = rnd.nextInt(256);
      }
      try {
        await decodeReceived(m, refFor(PreparedMedia(m, good.width, good.height, 1), MediaKind.sticker));
      } on MediaRejected {
        // fine
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('saving received media writes a fresh file rebuilt from pixels', () async {
    final photo0 = await preparePhoto(img.encodeJpg(photo(800, 600)));
    final jpg = await exportReceived(photo0.bytes, refFor(photo0, MediaKind.image));
    expect((jpg.extension, jpg.mimeType), ('jpg', 'image/jpeg'));
    expect(MediaFormat.sniff(jpg.bytes), MediaFormat.jpeg, reason: 'not the received WebP');
    final back = img.decodeJpg(jpg.bytes)!;
    expect((back.width, back.height), (photo0.width, photo0.height));
    expect(back.exif.isEmpty, isTrue);

    final still = await prepareSticker(img.encodePng(photo(100, 100)));
    final png = await exportReceived(still.bytes, refFor(still, MediaKind.sticker));
    expect(png.extension, 'png');
    expect(MediaFormat.sniff(png.bytes), MediaFormat.png);

    final anim = await prepareSticker(img.encodeGif(animation(120, 90, 5)));
    final gif = await exportReceived(anim.bytes, refFor(anim, MediaKind.sticker));
    expect(gif.extension, 'gif');
    expect(img.decodeGif(gif.bytes)!.numFrames, 5);

    // Bytes that do not match their reference are not exported at all.
    final bad = Uint8List.fromList(still.bytes)..[20] ^= 0xff;
    expect(() => exportReceived(bad.sublist(1), refFor(still, MediaKind.sticker)), throwsA(isA<MediaRejected>()));
  });
}
