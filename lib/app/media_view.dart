import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
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
    return _loading[ref.id] ??= _load(m, ref).whenComplete(() => _loading.remove(ref.id));
  }

  Future<MediaFrames?> _load(Messenger m, MediaRef ref) async {
    final bytes = await m.media.read(ref.id);
    if (bytes == null) return null;
    try {
      final d = await decodeReceived(bytes, ref);
      final images = <ui.Image>[];
      for (final px in d.frames) {
        final c = Completer<ui.Image>();
        ui.decodeImageFromPixels(px, d.width, d.height, ui.PixelFormat.rgba8888, c.complete);
        images.add(await c.future);
      }
      final f = MediaFrames(images, d.durationsMs);
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
  int _i = 0;
  Timer? _anim;
  StreamSubscription<void>? _sub;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _frames = MediaCache.instance.peek(widget.media.id);
    if (_frames == null) {
      // Retry whenever the messenger changes (a chunk or the last part came in).
      _sub = widget.messenger.changes.listen((_) => _try());
      _try();
    }
    _animate();
  }

  @override
  void dispose() {
    _anim?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _try() async {
    if (_busy || _frames != null) return;
    _busy = true;
    final f = await MediaCache.instance.load(widget.messenger, widget.media);
    _busy = false;
    if (!mounted) return;
    if (f != null) {
      _sub?.cancel();
      _frames = f;
      _animate();
    }
    setState(() {});
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
    final f = _frames;
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
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: InteractiveViewer(
        maxScale: 6,
        child: Center(child: MediaView(messenger: messenger, media: media, maxWidth: size.width, maxHeight: size.height)),
      ),
    );
  }
}
