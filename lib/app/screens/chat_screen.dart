import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:zelt_core/constants.dart';
import 'package:zelt_core/media.dart';
import 'package:zelt_core/messenger.dart';
import 'package:zelt_core/models.dart';
import '../app_state.dart';
import '../media_codec.dart';
import '../media_view.dart';
import 'contact_screen.dart';
import 'widgets.dart';

class ChatScreen extends StatefulWidget {
  final String contactId;
  const ChatScreen({super.key, required this.contactId});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _text = TextEditingController();
  late final AppState _app;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _app.seenChat(widget.contactId);
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _app.leftChat();
    _text.dispose();
    super.dispose();
  }

  int get _bytes => utf8.encode(_text.text).length;

  bool _busy = false;

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty || _bytes > maxTextBytes) return;
    _text.clear();
    await _app.m.sendText(widget.contactId, t);
  }

  void _toast(String s) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  /// Picks a photo, converts it (scaled WebP, metadata stripped) and sends it;
  /// the text field becomes its caption.
  Future<void> _sendPhoto() async {
    final file = await openFile(acceptedTypeGroups: [imageFiles]);
    if (file == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final p = await preparePhoto(await file.readAsBytes());
      final caption = _text.text.trim();
      if (utf8.encode(caption).length > maxTextBytes ~/ 2) throw MediaRejected('caption too long');
      _text.clear();
      await _app.m.sendImage(widget.contactId, p.bytes, width: p.width, height: p.height, caption: caption);
    } on MediaRejected catch (e) {
      _toast('Cannot send this image: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stickers() async {
    final ref = await showModalBottomSheet<MediaRef>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => StickerPicker(messenger: _app.m),
    );
    if (ref != null) await _app.m.sendSticker(widget.contactId, ref);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final c = app.m.contacts[widget.contactId];
    if (c == null) return const Scaffold(body: Center(child: Text('Contact removed')));
    if (c.unread > 0) WidgetsBinding.instance.addPostFrameCallback((_) => app.seenChat(c.id));
    final msgs = c.messages.reversed.toList();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: () => push(context, ContactScreen(contactId: c.id)),
          child: Row(
            children: [
              Avatar(c.name, radius: 18),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(child: Text(c.name, overflow: TextOverflow.ellipsis)),
                        if (c.verified) ...[
                          const SizedBox(width: 4),
                          Icon(Icons.verified, size: 16, color: scheme.primary),
                        ],
                      ],
                    ),
                    Text(
                      c.ready
                          ? (c.verified ? 'Verified · ${app.m.settings.hops} hops' : 'Not verified · tap to compare safety number')
                          : 'Setting up encryption…',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          const NetworkBanner(),
          Expanded(
            child: ListView.builder(
              reverse: true,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: msgs.length,
              itemBuilder: (_, i) => _Bubble(msgs[i], app.m),
            ),
          ),
          if (!c.ready)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                'Messages you write now are kept and sent once the post-quantum '
                'handshake with ${c.name} finishes.',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    onPressed: _busy ? null : _stickers,
                    tooltip: 'Stickers',
                    icon: const Icon(Icons.emoji_emotions_outlined),
                  ),
                  IconButton(
                    onPressed: _busy ? null : _sendPhoto,
                    tooltip: 'Send a photo',
                    icon: _busy
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.image_outlined),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _text,
                      minLines: 1,
                      maxLines: 6,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: 'Message',
                        isDense: true,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                        counterText: _bytes > maxTextBytes - 500 ? '$_bytes / $maxTextBytes bytes' : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton.filled(
                    onPressed: _text.text.trim().isEmpty || _bytes > maxTextBytes ? null : _send,
                    tooltip: 'Send',
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final Message m;
  final Messenger messenger;
  const _Bubble(this.m, this.messenger);

  Future<void> _stickerMenu(BuildContext context, MediaRef ref) async {
    if (m.outgoing || messenger.stickers.any((s) => s.id == ref.id)) return;
    final add = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListTile(
          leading: const Icon(Icons.bookmark_add_outlined),
          title: const Text('Add to my stickers'),
          onTap: () => Navigator.pop(ctx, true),
        ),
      ),
    );
    if (add == true && !await messenger.saveSticker(ref) && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not downloaded yet')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final bg = m.outgoing ? s.primaryContainer : s.surfaceContainerHighest;
    final fg = m.outgoing ? s.onPrimaryContainer : s.onSurface;
    final icon = switch (m.status) {
      MsgStatus.queued => Icons.schedule,
      MsgStatus.sent => Icons.check,
      MsgStatus.delivered => Icons.done_all,
    };
    final tip = switch (m.status) {
      MsgStatus.queued => 'Waiting to send',
      MsgStatus.sent => 'Stored on relays',
      MsgStatus.delivered => 'Delivered',
    };
    final media = m.media;
    final width = MediaQuery.of(context).size.width;
    final meta = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(shortTime(m.time), style: t.labelSmall?.copyWith(color: fg.withValues(alpha: 0.7))),
        if (m.outgoing) ...[
          const SizedBox(width: 4),
          Tooltip(message: tip, child: Icon(icon, size: 14, color: fg.withValues(alpha: 0.7))),
        ],
      ],
    );
    if (media != null && media.kind == MediaKind.sticker) {
      // Stickers stand on their own, without a bubble.
      return Align(
        alignment: m.outgoing ? Alignment.centerRight : Alignment.centerLeft,
        child: GestureDetector(
          onLongPress: () => _stickerMenu(context, media),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: m.outgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                MediaView(messenger: messenger, media: media, maxWidth: 150, maxHeight: 150),
                meta,
              ],
            ),
          ),
        ),
      );
    }
    return Align(
      alignment: m.outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(m.outgoing ? 16 : 4),
              bottomRight: Radius.circular(m.outgoing ? 4 : 16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (media != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: GestureDetector(
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => MediaFullScreen(messenger: messenger, media: media),
                    )),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: MediaView(messenger: messenger, media: media, maxWidth: width * 0.65, maxHeight: 360),
                    ),
                  ),
                ),
              if (m.text.isNotEmpty) SelectableText(m.text, style: t.bodyLarge?.copyWith(color: fg)),
              const SizedBox(height: 2),
              meta,
            ],
          ),
        ),
      ),
    );
  }
}

const imageFiles = XTypeGroup(
  label: 'Images',
  extensions: ['jpg', 'jpeg', 'png', 'webp', 'gif'],
  mimeTypes: ['image/jpeg', 'image/png', 'image/webp', 'image/gif'],
  uniformTypeIdentifiers: ['public.image'],
);

/// The user's stickers: tap to send, + to add from files, long-press to remove.
class StickerPicker extends StatefulWidget {
  final Messenger messenger;
  const StickerPicker({super.key, required this.messenger});

  @override
  State<StickerPicker> createState() => _StickerPickerState();
}

class _StickerPickerState extends State<StickerPicker> {
  bool _busy = false;
  String? _error;

  Future<void> _add() async {
    final file = await openFile(acceptedTypeGroups: [imageFiles]);
    if (file == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final p = await prepareSticker(await file.readAsBytes());
      await widget.messenger.addSticker(p.bytes, width: p.width, height: p.height);
    } on MediaRejected catch (e) {
      _error = 'Cannot use this file: $e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(MediaRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove sticker?'),
        content: const Text('It stays in chats where you already sent it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) setState(() => widget.messenger.removeSticker(ref.id));
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.messenger.stickers.reversed.toList();
    final t = Theme.of(context);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.5,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Stickers travel as a fingerprint only; a friend who does not have one yet gets it from you once.',
                style: t.textTheme.bodySmall,
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(_error!, style: TextStyle(color: t.colorScheme.error)),
              ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 96, mainAxisSpacing: 8, crossAxisSpacing: 8),
                itemCount: list.length + 1,
                itemBuilder: (_, i) {
                  if (i == 0) {
                    return OutlinedButton(
                      key: const Key('addSticker'),
                      onPressed: _busy ? null : _add,
                      style: OutlinedButton.styleFrom(padding: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                      child: _busy
                          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.add), Text('Add', style: TextStyle(fontSize: 12))]),
                    );
                  }
                  final ref = list[i - 1];
                  return InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => Navigator.pop(context, ref),
                    onLongPress: () => _remove(ref),
                    child: Center(child: MediaView(messenger: widget.messenger, media: ref, maxWidth: 88, maxHeight: 88)),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
