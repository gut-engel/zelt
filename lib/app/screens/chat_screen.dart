import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:zelt_core/constants.dart';
import 'package:zelt_core/models.dart';
import '../app_state.dart';
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

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty || _bytes > maxTextBytes) return;
    _text.clear();
    await _app.m.sendText(widget.contactId, t);
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
              itemBuilder: (_, i) => _Bubble(msgs[i]),
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
  const _Bubble(this.m);

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
              SelectableText(m.text, style: t.bodyLarge?.copyWith(color: fg)),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(shortTime(m.time), style: t.labelSmall?.copyWith(color: fg.withValues(alpha: 0.7))),
                  if (m.outgoing) ...[
                    const SizedBox(width: 4),
                    Tooltip(
                      message: tip,
                      child: Icon(icon, size: 14, color: fg.withValues(alpha: 0.7)),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
