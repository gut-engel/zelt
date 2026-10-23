import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zelt_core/media.dart';

/// Image work for zelt, all in pure Dart (package:image), all in a separate
/// isolate that is killed when it overruns its time limit.
///
/// Security: bytes from other people are only ever decoded here, by a
/// memory-safe decoder, after checking format, dimensions and frame count.
/// Only raw RGBA pixels leave the isolate; no received byte reaches a native
/// codec (Skia, libwebp, the OS image stack). That removes the attack surface
/// zero-click exploits use (for example the libwebp bug CVE-2023-4863).
///
/// Compression: lossy WebP (VP8), clearly smaller than JPEG at the same
/// quality, with alpha and animation for stickers. Re-encoding also drops all
/// metadata (EXIF location, camera, time) from photos.

class PreparedMedia {
  final Uint8List bytes;
  final int width;
  final int height;
  final int frames;
  PreparedMedia(this.bytes, this.width, this.height, this.frames);
}

class DecodedMedia {
  final int width;
  final int height;

  /// RGBA8888 pixels per frame.
  final List<Uint8List> frames;

  /// Display time per frame (animated stickers).
  final List<int> durationsMs;
  DecodedMedia(this.width, this.height, this.frames, this.durationsMs);
}

class MediaRejected implements Exception {
  final String reason;
  MediaRejected(this.reason);
  @override
  String toString() => reason;
}

/// Longest side of a sent photo.
const photoMaxSide = 1280;

/// Target size of a sent photo (at most 10 chunks): every chunk is a
/// mixnet message, so size is what makes a photo slow. Camera photos land
/// around 50-60 KB at quality 66-74, which still looks clean at 1280 px.
const photoTargetBytes = 64 * 1024;

/// Sticker canvas.
const stickerSide = 256;

/// Largest file accepted for converting (local input).
const maxInputBytes = 40 * 1024 * 1024;

void _isolateEntry((SendPort, Object? Function()) msg) {
  final (reply, f) = msg;
  try {
    reply.send(('ok', f()));
  } on MediaRejected catch (e) {
    reply.send(('rejected', e.reason));
  } catch (e) {
    reply.send(('rejected', 'cannot read this image'));
  }
}

/// Runs [job] in a fresh isolate; kills it after [timeout].
Future<T> _isolated<T>(T Function() job, Duration timeout) async {
  final port = ReceivePort();
  final iso = await Isolate.spawn<(SendPort, Object? Function())>(
    _isolateEntry,
    (port.sendPort, job),
    errorsAreFatal: true,
  );
  try {
    final (kind, value) = await port.first.timeout(timeout) as (String, Object?);
    if (kind == 'ok') return value as T;
    throw MediaRejected(value as String);
  } on TimeoutException {
    throw MediaRejected('took too long to process');
  } finally {
    iso.kill(priority: Isolate.immediate);
    port.close();
  }
}

// --- Local input: photos and new stickers ---------------------------------

/// A local file to send as a photo: scaled, oriented, metadata-free WebP.
Future<PreparedMedia> preparePhoto(Uint8List file) {
  if (file.length > maxInputBytes) throw MediaRejected('file too large');
  return _isolated(() => _preparePhoto(file), const Duration(seconds: 60));
}

/// A local file to add as a sticker: PNG, JPEG, WebP or (animated) GIF,
/// fitted into [stickerSide], as (animated) WebP.
Future<PreparedMedia> prepareSticker(Uint8List file) {
  if (file.length > maxInputBytes) throw MediaRejected('file too large');
  return _isolated(() => _prepareSticker(file), const Duration(seconds: 90));
}

img.Decoder _inputDecoder(Uint8List b, int maxPixels) => switch (MediaFormat.sniff(b)) {
  MediaFormat.jpeg => img.JpegDecoder(maxPixels: maxPixels),
  MediaFormat.png => img.PngDecoder(maxPixels: maxPixels),
  MediaFormat.gif => img.GifDecoder()..maxPixels = maxPixels,
  MediaFormat.webp => img.WebPDecoder()..maxPixels = maxPixels,
  _ => throw MediaRejected('unsupported format (use JPEG, PNG, GIF or WebP)'),
};

PreparedMedia _preparePhoto(Uint8List file) {
  final d = _inputDecoder(file, 80 * 1000 * 1000);
  final info = d.startDecode(file);
  if (info == null) throw MediaRejected('cannot read this image');
  if (info.width * info.height > 80 * 1000 * 1000) throw MediaRejected('image too large');
  var image = d.decode(file, frame: 0);
  if (image == null) throw MediaRejected('cannot read this image');
  if (image.numFrames > 1) image = image.frames.first;
  image = _stripMetadata(img.bakeOrientation(image));
  var side = photoMaxSide;
  while (true) {
    final scaled = _fit(image, side);
    for (final q in [74, 66, 58, 50, 42]) {
      final out = img.encodeWebP(scaled, lossless: false, quality: q, method: 4, exact: false);
      if (out.length <= photoTargetBytes || (q == 42 && side <= 640)) {
        if (out.length > maxImageBytes) throw MediaRejected('image does not compress enough');
        return PreparedMedia(out, scaled.width, scaled.height, 1);
      }
    }
    side = (side * 3) ~/ 4;
  }
}

PreparedMedia _prepareSticker(Uint8List file) {
  final d = _inputDecoder(file, 150 * 1000 * 1000);
  final info = d.startDecode(file);
  if (info == null) throw MediaRejected('cannot read this image');
  if (info.width * info.height > 40 * 1000 * 1000) throw MediaRejected('image too large');
  final decoded = d.decode(file);
  if (decoded == null) throw MediaRejected('cannot read this image');
  var anim = _stripMetadata(_limitFrames(decoded, maxStickerFrames));
  for (final side in [stickerSide, 200, 160, 128]) {
    final scaled = _fit(anim, side);
    for (final q in [78, 66, 54, 42]) {
      final out = img.encodeWebP(scaled, lossless: false, quality: q, alphaQuality: 80, method: 4, exact: false);
      if (out.length <= maxStickerBytes) {
        return PreparedMedia(out, scaled.width, scaled.height, scaled.numFrames);
      }
    }
    anim = _limitFrames(anim, (anim.numFrames * 2 / 3).ceil());
  }
  throw MediaRejected('sticker does not compress enough (too many frames?)');
}

/// Encoders copy EXIF, ICC and text chunks from the source: drop them all
/// (location, camera, time, software).
img.Image _stripMetadata(img.Image im) {
  for (final f in im.frames) {
    f.exif = img.ExifData();
    f.iccProfile = null;
    f.textData = null;
  }
  return im;
}

/// Scales so the longest side is at most [side] (never enlarges).
img.Image _fit(img.Image src, int side) {
  final w = src.width, h = src.height;
  if (w <= side && h <= side) return src;
  return w >= h
      ? img.copyResize(src, width: side, interpolation: img.Interpolation.average)
      : img.copyResize(src, height: side, interpolation: img.Interpolation.average);
}

/// Keeps at most [max] frames, evenly spread, adding up their durations.
img.Image _limitFrames(img.Image src, int max) {
  if (src.numFrames <= max) return src;
  final step = src.numFrames / max;
  late img.Image out;
  for (var i = 0; i < max; i++) {
    final from = (i * step).floor();
    final to = ((i + 1) * step).floor();
    var dur = 0;
    for (var j = from; j < to && j < src.numFrames; j++) {
      dur += src.frames[j].frameDuration;
    }
    final f = img.Image.from(src.frames[from], noAnimation: true)..frameDuration = dur;
    if (i == 0) {
      out = f..frameType = img.FrameType.animation;
    } else {
      out.addFrame(f);
    }
  }
  return out;
}

// --- Received media: decode for display only ------------------------------

/// Decodes received media for display. Only WebP within the limits of
/// [ref] is accepted; anything else is rejected without being parsed.
Future<DecodedMedia> decodeReceived(Uint8List bytes, MediaRef ref) {
  if (bytes.length != ref.size || MediaFormat.sniff(bytes) != MediaFormat.webp) {
    throw MediaRejected('not a valid media file');
  }
  final image = ref.kind == MediaKind.image;
  return _isolated(
    () => _decodeReceived(bytes, image ? maxImageSide : maxStickerSide, image ? 1 : maxStickerFrames),
    const Duration(seconds: 8),
  );
}

DecodedMedia _decodeReceived(Uint8List bytes, int maxSide, int maxFrames) {
  final d = img.WebPDecoder()..maxPixels = maxSide * maxSide * maxFrames;
  final info = d.startDecode(bytes);
  if (info == null) throw MediaRejected('cannot read this image');
  if (info.width <= 0 || info.height <= 0 || info.width > maxSide || info.height > maxSide) {
    throw MediaRejected('image dimensions out of range');
  }
  if (info.numFrames > maxFrames) throw MediaRejected('too many frames');
  final decoded = maxFrames == 1 ? d.decodeFrame(0) : d.decode(bytes);
  if (decoded == null) throw MediaRejected('cannot read this image');
  final frames = <Uint8List>[];
  final durations = <int>[];
  for (final f in decoded.frames.take(maxFrames)) {
    if (f.width != decoded.width || f.height != decoded.height) throw MediaRejected('bad frame');
    final rgba = f.convert(format: img.Format.uint8, numChannels: 4, alpha: 255);
    frames.add(rgba.getBytes(order: img.ChannelOrder.rgba));
    durations.add(f.frameDuration <= 10 ? 100 : f.frameDuration);
  }
  return DecodedMedia(decoded.width, decoded.height, frames, durations);
}

// --- Saving received media to the device ----------------------------------

/// A file to hand to the gallery or the file system.
class ExportedMedia {
  final Uint8List bytes;
  final String extension;
  final String mimeType;
  ExportedMedia(this.bytes, this.extension, this.mimeType);
}

/// Media to save on the device, rebuilt from pixels: received bytes are
/// decoded here like for display (same limits), then encoded afresh. The
/// gallery and other apps decode files with native codecs, so they never get
/// the bytes a friend (or an attacker using a friend's device) crafted, only
/// a clean JPEG (photos), PNG (stickers) or GIF (animated stickers) made by
/// our own encoder, without any metadata.
Future<ExportedMedia> exportReceived(Uint8List bytes, MediaRef ref) {
  if (bytes.length != ref.size || MediaFormat.sniff(bytes) != MediaFormat.webp) {
    throw MediaRejected('not a valid media file');
  }
  final image = ref.kind == MediaKind.image;
  return _isolated(
    () => _export(_decodeReceived(bytes, image ? maxImageSide : maxStickerSide, image ? 1 : maxStickerFrames), image),
    const Duration(seconds: 30),
  );
}

ExportedMedia _export(DecodedMedia d, bool photo) {
  img.Image frame(int i) => img.Image.fromBytes(
    width: d.width,
    height: d.height,
    bytes: d.frames[i].buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  if (photo) return ExportedMedia(img.encodeJpg(frame(0), quality: 92), 'jpg', 'image/jpeg');
  if (d.frames.length == 1) return ExportedMedia(img.encodePng(frame(0)), 'png', 'image/png');
  final anim = frame(0)..frameDuration = d.durationsMs[0];
  for (var i = 1; i < d.frames.length; i++) {
    anim.addFrame(frame(i)..frameDuration = d.durationsMs[i]);
  }
  return ExportedMedia(img.encodeGif(anim), 'gif', 'image/gif');
}
