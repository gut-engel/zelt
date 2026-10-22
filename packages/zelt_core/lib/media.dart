import 'dart:typed_data';

import 'bytes.dart';

/// Images and stickers.
///
/// Media travel as content-addressed blobs: `hash = SHA-256(bytes)`. An image
/// message carries a [MediaRef] and the sender pushes the bytes right after it
/// as [mediaChunkSize] chunks, one ratchet message each. A sticker message
/// carries only the [MediaRef]; a friend who does not have that hash yet asks
/// the sender for it (`mediaRequest`), and the sender answers only for media
/// it sent to that friend. Reassembled bytes are accepted only if their size
/// and hash match the reference.
///
/// Received bytes are never handed to a native image decoder (see the app's
/// media codec): they are decoded by a pure-Dart, memory-safe decoder in a
/// separate isolate with size and time limits, and only raw pixels reach the
/// renderer. That shuts out zero-click exploits of native codecs.
enum MediaKind { image, sticker }

/// Formats. On the wire everything is WebP: lossy VP8 for photos, and for
/// stickers lossy VP8 with alpha, animated when the source was (GIF imports
/// become animated WebP, far smaller than GIF). Anything else is rejected.
/// JPEG, PNG and GIF are only accepted as local input to convert.
class MediaFormat {
  MediaFormat._();
  static const jpeg = 1;
  static const png = 2;
  static const gif = 3;
  static const webp = 4;

  static bool allowed(MediaKind k, int f) => f == webp;

  /// Format detected from the first bytes (null: not one we accept).
  static int? sniff(Uint8List b) {
    if (b.length >= 3 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) return jpeg;
    if (b.length >= 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4e && b[3] == 0x47) return png;
    if (b.length >= 6 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38) return gif;
    if (b.length >= 12 &&
        b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && // RIFF
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) { // WEBP
      return webp;
    }
    return null;
  }
}

/// Data bytes per chunk: one chunk message fills one ratchet message in one
/// blob (7137 bytes of content minus ratchet and chunk headers).
const int mediaChunkSize = 6900;

const int maxImageBytes = 512 * 1024;
const int maxStickerBytes = 256 * 1024;

/// Largest dimensions a receiver will decode (the sender scales below these).
const int maxImageSide = 2048;
const int maxStickerSide = 320;
const int maxStickerFrames = 80;

/// Receiver: bytes buffered for incomplete transfers, per contact.
const int maxBufferedPerContact = 2 * 1024 * 1024;

/// Sender: chunks served on request, per contact and hour.
const int maxServedChunksPerHour = 400;

int chunkCount(int size) => (size + mediaChunkSize - 1) ~/ mediaChunkSize;

int maxBytesFor(MediaKind k) => k == MediaKind.image ? maxImageBytes : maxStickerBytes;

class MediaRef {
  final Uint8List hash;
  final int size;
  final MediaKind kind;
  final int format;
  final int width;
  final int height;

  MediaRef({
    required this.hash,
    required this.size,
    required this.kind,
    required this.format,
    required this.width,
    required this.height,
  });

  String get id => hex(hash);
  int get chunks => chunkCount(size);

  void write(ByteWriter w) => w
    ..bytes(hash)
    ..u32(size)
    ..u8(kind.index)
    ..u8(format)
    ..u16(width)
    ..u16(height);

  /// Rejects anything outside the limits before a single byte is fetched.
  static MediaRef read(ByteReader r) {
    final hash = r.bytes(32);
    final size = r.u32();
    final k = r.u8();
    if (k >= MediaKind.values.length) throw const FormatException('media kind');
    final kind = MediaKind.values[k];
    final format = r.u8();
    final w = r.u16();
    final h = r.u16();
    if (!MediaFormat.allowed(kind, format)) throw const FormatException('media format');
    if (size == 0 || size > maxBytesFor(kind)) throw const FormatException('media size');
    final side = kind == MediaKind.image ? maxImageSide : maxStickerSide;
    if (w == 0 || h == 0 || w > side || h > side) throw const FormatException('media dimensions');
    return MediaRef(hash: hash, size: size, kind: kind, format: format, width: w, height: h);
  }

  Map<String, dynamic> toJson() => {
    'h': b64(hash),
    's': size,
    'k': kind.index,
    'f': format,
    'w': width,
    'hh': height,
  };

  factory MediaRef.fromJson(Map<String, dynamic> j) => MediaRef(
    hash: unb64(j['h']),
    size: j['s'],
    kind: MediaKind.values[j['k']],
    format: j['f'],
    width: j['w'],
    height: j['hh'],
  );
}

/// Where media bytes live (encrypted at rest in the app's vault).
abstract class MediaStore {
  Future<Uint8List?> read(String hash);
  Future<void> write(String hash, Uint8List bytes);
  Future<bool> has(String hash);
}

/// In-memory store (tests, headless peers).
class MemoryMediaStore implements MediaStore {
  final Map<String, Uint8List> _m = {};
  @override
  Future<Uint8List?> read(String hash) async => _m[hash];
  @override
  Future<void> write(String hash, Uint8List bytes) async => _m[hash] = bytes;
  @override
  Future<bool> has(String hash) async => _m.containsKey(hash);
}
