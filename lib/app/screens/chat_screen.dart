import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:zelt_core/constants.dart';
import 'package:zelt_core/groups.dart';
import 'package:zelt_core/media.dart';
import 'package:zelt_core/messenger.dart';
import 'package:zelt_core/models.dart';
import '../app_state.dart';
import '../media_codec.dart';
import '../media_view.dart';
import 'contact_screen.dart';
import 'group_screens.dart';
import 'widgets.dart';

/// Reactions offered first (any emoji can come in).
const quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// A one-to-one chat ([contactId]) or a group chat ([groupId]).
class ChatScreen extends StatefulWidget {
  final String? contactId;
  final String? groupId;
  const ChatScreen({super.key, this.contactId}) : groupId = null;
  const ChatScreen.group({super.key, required String this.groupId}) : contactId = null;

  String get id => contactId ?? groupId!;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _text = TextEditingController();
  late final AppState _app;
  Message? _replyTo;

  bool get _isGroup => widget.groupId != null;
  Messenger get _m => _app.m;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _app.seenChat(widget.id);
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

  void _toast(String s) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  /// Runs a send; a group that changed meanwhile (left, removed) says so.
  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
    } on StateError catch (e) {
      _toast('Not sent: ${e.message}');
    } on ArgumentError catch (e) {
      _toast('Not sent: ${e.message}');
    } on FormatException catch (e) {
      _toast('Not sent: ${e.message}');
    }
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty || _bytes > maxTextBytes) return;
    final reply = _replyTo?.id;
    _text.clear();
    setState(() => _replyTo = null);
    await _guard(() async {
      if (_isGroup) {
        await _m.sendGroupText(widget.id, t, replyTo: reply);
      } else {
        await _m.sendText(widget.id, t, replyTo: reply);
      }
    });
  }

  /// Picks a photo, converts it (scaled WebP, metadata stripped) and sends it;
  /// the text field becomes its caption.
  Future<void> _sendPhoto() async {
    final file = await openFile(acceptedTypeGroups: [imageFiles]);
    if (file == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final sw = Stopwatch()..start();
      final p = await preparePhoto(await file.readAsBytes());
      _m.log('photo prepared in ${sw.elapsedMilliseconds} ms (${p.bytes.length} bytes)');
      final caption = _text.text.trim();
      if (utf8.encode(caption).length > maxTextBytes ~/ 2) throw MediaRejected('caption too long');
      final reply = _replyTo?.id;
      _text.clear();
      setState(() => _replyTo = null);
      await _guard(() async {
        if (_isGroup) {
          await _m.sendGroupImage(widget.id, p.bytes, width: p.width, height: p.height, caption: caption, replyTo: reply);
        } else {
          await _m.sendImage(widget.id, p.bytes, width: p.width, height: p.height, caption: caption, replyTo: reply);
        }
      });
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
      builder: (_) => StickerPicker(messenger: _m),
    );
    if (ref == null) return;
    final reply = _replyTo?.id;
    setState(() => _replyTo = null);
    await _guard(() async {
      if (_isGroup) {
        await _m.sendGroupSticker(widget.id, ref, replyTo: reply);
      } else {
        await _m.sendSticker(widget.id, ref, replyTo: reply);
      }
    });
  }

  Future<void> _react(Message msg, String emoji) => _guard(() async {
    if (_isGroup) {
      await _m.reactInGroup(widget.id, msg.id, emoji);
    } else {
      await _m.react(widget.id, msg.id, emoji);
    }
  });

  /// Who wrote a message, as this user knows them.
  String _authorName(Message msg) {
    if (msg.outgoing) return 'You';
    if (!_isGroup) return _m.contacts[widget.id]?.name ?? '';
    final a = msg.author;
    if (a == null) return '';
    return _m.contacts[a]?.name ?? _m.groups[widget.id]?.roster.member(a)?.name ?? 'Former member';
  }

  void _startReply(Message msg) {
    setState(() => _replyTo = msg);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final m = app.m;
    final c = _isGroup ? null : m.contacts[widget.id];
    final g = _isGroup ? m.groups[widget.id] : null;
    if (c == null && g == null) return const Scaffold(body: Center(child: Text('This chat no longer exists')));
    final unread = c?.unread ?? g!.unread;
    if (unread > 0) WidgetsBinding.instance.addPostFrameCallback((_) => app.seenChat(widget.id));
    final all = c?.messages ?? g!.messages;
    final byId = {for (final msg in all) msg.id: msg};
    final msgs = all.reversed.toList();
    final scheme = Theme.of(context).colorScheme;
    final canWrite = c != null || g!.active;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: () => push(context, c != null ? ContactScreen(contactId: c.id) : GroupInfoScreen(groupId: g!.id)),
          child: Row(
            children: [
              c != null ? Avatar(c.name, radius: 18, picture: c.shownAvatar) : GroupAvatar(g!.name, radius: 18),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(child: Text(c?.name ?? g!.name, overflow: TextOverflow.ellipsis)),
                        if (c?.verified ?? false) ...[
                          const SizedBox(width: 4),
                          Icon(Icons.verified, size: 16, color: scheme.primary),
                        ],
                        if (app.isPrivate(widget.id)) ...[
                          const SizedBox(width: 4),
                          Icon(Icons.lock_outline, size: 16, color: scheme.primary),
                        ],
                      ],
                    ),
                    Text(
                      c != null
                          ? (c.ready
                                ? (c.verified ? 'Verified · ${m.settings.hops} hops' : 'Not verified · tap to compare safety number')
                                : 'Setting up encryption…')
                          : groupStatus(g!),
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
              itemBuilder: (_, i) {
                final msg = msgs[i];
                final quoted = msg.replyTo == null ? null : byId[msg.replyTo];
                return _Bubble(
                  msg,
                  m,
                  key: ValueKey(msg.id),
                  author: _isGroup && !msg.outgoing ? _authorName(msg) : null,
                  quote: msg.replyTo == null ? null : (quoted == null ? null : _authorName(quoted), quoted),
                  onReply: canWrite ? () => _startReply(msg) : null,
                  onReact: canWrite ? (e) => _react(msg, e) : null,
                  reactorName: (who) => who == Message.me ? 'You' : (_isGroup ? _authorName(Message(id: '', outgoing: false, text: '', time: DateTime.now(), author: who)) : c!.name),
                );
              },
            ),
          ),
          if (c != null && !c.ready)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                'Messages you write now are kept and sent once the post-quantum '
                'handshake with ${c.name} finishes.',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
          if (g != null && g.state == GroupState.invited)
            _GroupInviteBar(group: g)
          else if (!canWrite)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(groupStatus(g), textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
            )
          else ...[
            if (_replyTo != null)
              _ReplyPreview(
                name: _authorName(_replyTo!),
                text: snippet(_replyTo!),
                onCancel: () => setState(() => _replyTo = null),
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
        ],
      ),
    );
  }
}

/// One line describing a message (for quotes and the chat list).
String snippet(Message m) {
  final media = m.media;
  if (media == null) return m.text.replaceAll('\n', ' ');
  if (media.kind == MediaKind.sticker) return 'Sticker';
  return m.text.isEmpty ? 'Photo' : 'Photo: ${m.text.replaceAll('\n', ' ')}';
}

class _ReplyPreview extends StatelessWidget {
  final String name;
  final String text;
  final VoidCallback onCancel;
  const _ReplyPreview({required this.name, required this.text, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      key: const Key('replyPreview'),
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: s.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: s.primary, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Replying to $name', style: TextStyle(color: s.primary, fontWeight: FontWeight.w600, fontSize: 12)),
                Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          IconButton(tooltip: 'Cancel reply', icon: const Icon(Icons.close, size: 18), onPressed: onCancel),
        ],
      ),
    );
  }
}

class _GroupInviteBar extends StatelessWidget {
  final Group group;
  const _GroupInviteBar({required this.group});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final by = app.m.contacts[group.invitedBy]?.name ?? 'A friend';
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$by invited you to "${group.name}".', textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(
              'The other members will see the name you set in Settings, and you will see theirs.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: () async {
                    await app.m.declineGroupInvite(group.id);
                    if (context.mounted) Navigator.of(context).maybePop();
                  },
                  child: const Text('Decline'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  key: const Key('joinGroup'),
                  onPressed: () => app.m.acceptGroupInvite(group.id),
                  child: const Text('Join'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final Message m;
  final Messenger messenger;

  /// Group chats: who wrote it (incoming only).
  final String? author;

  /// The answered message: (its author's name, the message), or null if it
  /// is not (no longer) in this chat.
  final (String?, Message?)? quote;
  final VoidCallback? onReply;
  final void Function(String emoji)? onReact;
  final String Function(String who) reactorName;

  const _Bubble(
    this.m,
    this.messenger, {
    super.key,
    this.author,
    this.quote,
    this.onReply,
    this.onReact,
    required this.reactorName,
  });

  /// Everything one can do with a message: react, reply, copy, and for a
  /// picture save it (and add a friend's sticker to our own).
  Future<void> _menu(BuildContext context) async {
    final ref = m.media;
    final failed = ref != null && MediaCache.instance.failed(ref.id);
    // Never into the library: our own, ones already there, and ones that
    // failed the safe decoder (they would only fail again for every friend).
    final canAdd = ref != null &&
        ref.kind == MediaKind.sticker &&
        !m.outgoing &&
        !failed &&
        !messenger.stickers.any((s) => s.id == ref.id);
    final mine = m.reactions[Message.me]?.$1 ?? '';
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onReact != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final e in quickReactions)
                      InkWell(
                        key: Key('react$e'),
                        borderRadius: BorderRadius.circular(24),
                        onTap: () => Navigator.pop(ctx, 'react:$e'),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: e == mine
                              ? BoxDecoration(color: Theme.of(ctx).colorScheme.primaryContainer, shape: BoxShape.circle)
                              : null,
                          child: Text(e, style: const TextStyle(fontSize: 26)),
                        ),
                      ),
                  ],
                ),
              ),
            if (onReply != null)
              ListTile(
                key: const Key('replyAction'),
                leading: const Icon(Icons.reply),
                title: const Text('Reply'),
                onTap: () => Navigator.pop(ctx, 'reply'),
              ),
            if (mine.isNotEmpty && onReact != null)
              ListTile(
                leading: const Icon(Icons.remove_circle_outline),
                title: const Text('Remove my reaction'),
                onTap: () => Navigator.pop(ctx, 'react:'),
              ),
            if (m.text.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('Copy text'),
                onTap: () => Navigator.pop(ctx, 'copy'),
              ),
            if (canAdd)
              ListTile(
                leading: const Icon(Icons.bookmark_add_outlined),
                title: const Text('Add to my stickers'),
                onTap: () => Navigator.pop(ctx, 'add'),
              ),
            if (ref != null && !failed)
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('Save to device'),
                onTap: () => Navigator.pop(ctx, 'save'),
              ),
          ],
        ),
      ),
    );
    if (!context.mounted || choice == null) return;
    if (choice.startsWith('react:')) {
      onReact?.call(choice.substring(6));
      return;
    }
    switch (choice) {
      case 'reply':
        onReply?.call();
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.text));
      case 'add':
        final ok = await messenger.saveSticker(ref!);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(ok ? 'Added to your stickers' : 'Not downloaded yet')),
          );
        }
      case 'save':
        await saveMediaToDevice(context, messenger, ref!);
    }
  }

  Widget _quoteBox(BuildContext context, Color fg) {
    final s = Theme.of(context).colorScheme;
    final (name, msg) = quote!;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: s.primary, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (name != null) Text(name, style: TextStyle(color: s.primary, fontWeight: FontWeight.w600, fontSize: 12)),
          Text(
            msg == null ? 'Message not available' : snippet(msg),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: fg.withValues(alpha: 0.8), fontStyle: msg == null ? FontStyle.italic : null),
          ),
        ],
      ),
    );
  }

  Widget _reactions(BuildContext context) {
    final shown = m.shownReactions;
    if (shown.isEmpty) return const SizedBox.shrink();
    final s = Theme.of(context).colorScheme;
    final byEmoji = <String, List<String>>{};
    for (final e in shown.entries) {
      byEmoji.putIfAbsent(e.value, () => []).add(e.key);
    }
    final mine = shown[Message.me];
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final e in byEmoji.entries)
            Tooltip(
              message: e.value.map(reactorName).join(', '),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                // Tapping ours removes it; tapping another one makes it ours.
                onTap: onReact == null ? null : () => onReact!(e.key == mine ? '' : e.key),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: e.key == mine ? s.primaryContainer : s.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: s.outlineVariant),
                  ),
                  child: Text(e.value.length > 1 ? '${e.key} ${e.value.length}' : e.key, style: const TextStyle(fontSize: 13)),
                ),
              ),
            ),
        ],
      ),
    );
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
    final align = m.outgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final authorLine = author == null
        ? null
        : Text(author!, style: TextStyle(color: s.primary, fontWeight: FontWeight.w600, fontSize: 12));
    if (media != null && media.kind == MediaKind.sticker) {
      // Stickers stand on their own, without a bubble.
      return Align(
        alignment: m.outgoing ? Alignment.centerRight : Alignment.centerLeft,
        child: GestureDetector(
          onTap: () => _menu(context),
          onLongPress: () => _menu(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: align,
              children: [
                ?authorLine,
                if (quote != null) ConstrainedBox(constraints: BoxConstraints(maxWidth: width * 0.6), child: _quoteBox(context, s.onSurface)),
                MediaView(key: ValueKey(media.id), messenger: messenger, media: media, maxWidth: 150, maxHeight: 150),
                _reactions(context),
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
        constraints: BoxConstraints(maxWidth: width * 0.8),
        child: Column(
          crossAxisAlignment: align,
          children: [
            GestureDetector(
              onLongPress: () => _menu(context),
              child: Container(
                margin: const EdgeInsets.only(top: 3),
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
                    if (authorLine != null) Align(alignment: Alignment.centerLeft, child: authorLine),
                    if (quote != null) _quoteBox(context, fg),
                    if (media != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: GestureDetector(
                          onLongPress: () => _menu(context),
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => MediaFullScreen(messenger: messenger, media: media),
                          )),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: MediaView(key: ValueKey(media.id), messenger: messenger, media: media, maxWidth: width * 0.65, maxHeight: 360),
                          ),
                        ),
                      ),
                    if (m.text.isNotEmpty)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(m.text, style: t.bodyLarge?.copyWith(color: fg)),
                      ),
                    const SizedBox(height: 2),
                    meta,
                  ],
                ),
              ),
            ),
            _reactions(context),
          ],
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
                    key: ValueKey(ref.id),
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => Navigator.pop(context, ref),
                    onLongPress: () => _remove(ref),
                    child: Center(child: MediaView(key: ValueKey(ref.id), messenger: widget.messenger, media: ref, maxWidth: 88, maxHeight: 88)),
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
