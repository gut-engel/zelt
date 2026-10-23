import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zelt_core/media.dart';
import 'package:zelt_core/messenger.dart';
import 'package:zelt_core/vault.dart';

import 'media_codec.dart';

/// Media bytes in the vault: one encrypted file each, names hidden.
class VaultMediaStore implements MediaStore {
  final Vault vault;
  VaultMediaStore(this.vault);

  @override
  Future<Uint8List?> read(String hash) => vault.readBlob(hash);
  @override
  Future<void> write(String hash, Uint8List bytes) => vault.writeBlob(hash, bytes);
  @override
  Future<bool> has(String hash) => vault.hasBlob(hash);
}

class MediaFrames {
  final List<ui.Image> images;
  final List<int> durationsMs;
  MediaFrames(this.images, this.durationsMs);
  void dispose() {
    for (final i in images) {
      i.dispose();
    }
  }
}

/// Decoded media, least recently used dropped first. Decoding goes through
/// [decodeReceived] (pure Dart, isolated, limited); the renderer only ever
/// gets raw pixels via [ui.decodeImageFromPixels], never encoded bytes.
class MediaCache {
  MediaCache._();
  static final instance = MediaCache._();
  static const _max = 40;

  final _done = <String, MediaFrames>{};
  final _loading = <String, Future<MediaFrames?>>{};
  final _failed = <String>{};

  bool failed(String hash) => _failed.contains(hash);

  @visibleForTesting
  void put(String hash, MediaFrames f) => _done[hash] = f;

  MediaFrames? peek(String hash) {
    final f = _done.remove(hash);
    if (f != null) _done[hash] = f;
    return f;
  }

  /// Null while the bytes have not arrived yet.
  Future<MediaFrames?> load(Messenger m, MediaRef ref) {
    final hit = peek(ref.id);
    if (hit != null) return Future.value(hit);
    if (_failed.contains(ref.id)) return Future.value(null);
    // The callback must not return the removed future: whenComplete would
    // wait for it, that is for itself, and the load would never finish.
    return _loading[ref.id] ??= _load(m, ref).whenComplete(() {
      _loading.remove(ref.id);
    });
  }

  Future<MediaFrames?> _load(Messenger m, MediaRef ref) async {
    final bytes = await m.media.read(ref.id);
    if (bytes == null) return null;
    final sw = Stopwatch()..start();
    try {
      final d = await decodeReceived(bytes, ref);
      final images = <ui.Image>[];
      for (final px in d.frames) {
        final c = Completer<ui.Image>();
        ui.decodeImageFromPixels(px, d.width, d.height, ui.PixelFormat.rgba8888, c.complete);
        images.add(await c.future);
      }
      final f = MediaFrames(images, d.durationsMs);
      m.log('${ref.kind.name} ${ref.id.substring(0, 8)} decoded in ${sw.elapsedMilliseconds} ms');
      _done[ref.id] = f;
      while (_done.length > _max) {
        _done.remove(_done.keys.first)!.dispose();
      }
      return f;
    } on MediaRejected {
      _failed.add(ref.id);
      return null;
    }
  }
}

/// Shows an image or a (possibly animated) sticker once its bytes are here,
/// a placeholder with progress until then.
class MediaView extends StatefulWidget {
  final Messenger messenger;
  final MediaRef media;
  final double maxWidth;
  final double maxHeight;
  const MediaView({super.key, required this.messenger, required this.media, required this.maxWidth, required this.maxHeight});

  @override
  State<MediaView> createState() => _MediaViewState();
}

class _MediaViewState extends State<MediaView> {
  MediaFrames? _frames;

  /// The media [_frames] were decoded from. Only frames of exactly the
  /// widget's hash are ever shown, even if Flutter hands this state to
  /// another message.
  String? _framesId;
  int _i = 0;
  Timer? _anim;
  StreamSubscription<void>? _sub;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(MediaView old) {
    super.didUpdateWidget(old);
    if (old.media.id == widget.media.id && identical(old.messenger, widget.messenger)) return;
    _stop();
    _frames = null;
    _framesId = null;
    _i = 0;
    _start();
  }

  void _start() {
    _frames = MediaCache.instance.peek(widget.media.id);
    _framesId = _frames == null ? null : widget.media.id;
    if (_frames == null) {
      // Retry whenever the messenger changes (a chunk or the last part came in).
      _sub = widget.messenger.changes.listen((_) => _try());
      _try();
    }
    _animate();
  }

  void _stop() {
    _anim?.cancel();
    _anim = null;
    _sub?.cancel();
    _sub = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  /// A change came in while a load was running: look again afterwards.
  bool _again = false;

  /// Loads until the bytes are here. A change during a load is never lost:
  /// the load that started before the bytes were stored may still come back
  /// empty, so it runs once more (otherwise the picture waits for some later,
  /// unrelated change).
  Future<void> _try() async {
    if (_frames != null) return;
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    try {
      do {
        _again = false;
        final id = widget.media.id;
        final f = await MediaCache.instance.load(widget.messenger, widget.media);
        if (!mounted) return;
        // Switched to other media meanwhile: load that one instead.
        if (id != widget.media.id) {
          _again = true;
          continue;
        }
        if (f != null) {
          _sub?.cancel();
          _sub = null;
          _frames = f;
          _framesId = id;
          _animate();
          break;
        }
      } while (_again);
    } finally {
      _busy = false;
    }
    if (mounted) setState(() {});
  }

  void _animate() {
    final f = _frames;
    if (f == null || f.images.length < 2) return;
    _anim?.cancel();
    _anim = Timer(Duration(milliseconds: f.durationsMs[_i].clamp(20, 5000)), () {
      if (!mounted) return;
      setState(() => _i = (_i + 1) % f.images.length);
      _animate();
    });
  }

  Size _size() {
    final w = widget.media.width.toDouble(), h = widget.media.height.toDouble();
    final scale = [widget.maxWidth / w, widget.maxHeight / h, 1.0].reduce((a, b) => a < b ? a : b);
    return Size(w * scale, h * scale);
  }

  @override
  Widget build(BuildContext context) {
    final size = _size();
    final f = _framesId == widget.media.id ? _frames : null;
    if (f != null) {
      return SizedBox.fromSize(
        size: size,
        child: RawImage(image: f.images[_i % f.images.length], fit: BoxFit.contain, filterQuality: FilterQuality.medium),
      );
    }
    final s = Theme.of(context).colorScheme;
    final failed = MediaCache.instance.failed(widget.media.id);
    final p = widget.messenger.mediaProgress(widget.media.id);
    return Container(
      width: size.width,
      height: size.height,
      decoration: BoxDecoration(color: s.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
      alignment: Alignment.center,
      child: failed
          ? Tooltip(message: 'Cannot display this file', child: Icon(Icons.broken_image_outlined, color: s.error))
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(width: 28, height: 28, child: CircularProgressIndicator(value: p, strokeWidth: 3)),
                if (p != null) ...[
                  const SizedBox(height: 6),
                  Text('${(p * 100).round()} %', style: Theme.of(context).textTheme.labelSmall),
                ],
              ],
            ),
    );
  }
}

/// Full-screen view of a received or sent image (zoom and pan).
class MediaFullScreen extends StatelessWidget {
  final Messenger messenger;
  final MediaRef media;
  const MediaFullScreen({super.key, required this.messenger, required this.media});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Save to device',
            icon: const Icon(Icons.download_outlined),
            onPressed: () => saveMediaToDevice(context, messenger, media),
          ),
        ],
      ),
      body: InteractiveViewer(
        maxScale: 6,
        child: Center(child: MediaView(messenger: messenger, media: media, maxWidth: size.width, maxHeight: size.height)),
      ),
    );
  }
}

/// Saves a photo or sticker on the device (gallery on Android, a file of the
/// user's choice on desktop). What is saved is re-encoded from pixels by
/// [exportReceived], never the received bytes.
Future<void> saveMediaToDevice(BuildContext context, Messenger m, MediaRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  void toast(String s) => messenger.showSnackBar(SnackBar(content: Text(s)));
  final bytes = await m.media.read(ref.id);
  if (bytes == null) {
    toast('Not downloaded yet');
    return;
  }
  try {
    final out = await exportReceived(bytes, ref);
    final name = 'zelt-${ref.id.substring(0, 12)}.${out.extension}';
    if (Platform.isAndroid) {
      final where = await const MethodChannel('zelt/service').invokeMethod<String>('saveImage', {
        'bytes': out.bytes,
        'name': name,
        'mime': out.mimeType,
      });
      toast('Saved to ${where ?? 'the gallery'}');
    } else {
      final loc = await getSaveLocation(
        suggestedName: name,
        acceptedTypeGroups: [XTypeGroup(label: out.extension.toUpperCase(), extensions: [out.extension], mimeTypes: [out.mimeType])],
      );
      if (loc == null) return;
      await File(loc.path).writeAsBytes(out.bytes, flush: true);
      toast('Saved');
    }
  } on MediaRejected catch (e) {
    toast('Cannot save this file: $e');
  } on PlatformException catch (e) {
    toast('Saving failed: ${e.message}');
  } on FileSystemException catch (e) {
    toast('Saving failed: ${e.message}');
  }
}
