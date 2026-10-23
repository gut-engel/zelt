import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:zelt_core/models.dart';
import '../app_state.dart';
import 'chat_screen.dart';
import 'invite_screen.dart';
import 'network_screen.dart';
import 'pair_screen.dart';
import 'settings_screen.dart';
import 'widgets.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final m = app.m;
    final contacts = m.contacts.values.toList()
      ..sort((a, b) {
        final ta = a.lastMessage?.time ?? DateTime(2000);
        final tb = b.lastMessage?.time ?? DateTime(2000);
        return tb.compareTo(ta);
      });
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) app.moveToBackground();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('zelt'),
          actions: [
            NetworkChip(onTap: () => push(context, const NetworkScreen())),
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => push(context, const SettingsScreen()),
            ),
          ],
        ),
        body: Column(
          children: [
            const UpdateBanner(),
            const NetworkBanner(),
            Expanded(
              child: contacts.isEmpty
                  ? const _Empty()
                  : ListView.separated(
                      itemCount: contacts.length,
                      separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                      itemBuilder: (context, i) => _ContactTile(contacts[i]),
                    ),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          icon: const Icon(Icons.qr_code_2),
          label: const Text('Add friend'),
          onPressed: () => _addFriend(context),
        ),
      ),
    );
  }
}

class _ContactTile extends StatelessWidget {
  final Contact c;
  const _ContactTile(this.c);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final last = c.lastMessage;
    final subtitle = !c.ready
        ? 'Setting up encryption…'
        : last == null
        ? 'Paired. Say hello.'
        : '${last.outgoing ? 'You: ' : ''}${last.text.replaceAll('\n', ' ')}';
    return ListTile(
      leading: Avatar(c.name, picture: c.shownAvatar),
      title: Row(
        children: [
          Flexible(child: Text(c.name, overflow: TextOverflow.ellipsis)),
          if (c.verified) ...[
            const SizedBox(width: 4),
            Icon(Icons.verified, size: 16, color: t.colorScheme.primary),
          ],
        ],
      ),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: c.unread > 0
          ? Badge(label: Text('${c.unread}'))
          : last != null
          ? Text(shortTime(last.time), style: t.textTheme.bodySmall)
          : null,
      onTap: () => push(context, ChatScreen(contactId: c.id)),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.people_outline, size: 64, color: t.colorScheme.outline),
            const SizedBox(height: 16),
            Text('No friends yet', style: t.textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text(
              'zelt has no directory. Tap "Add friend": scan each other\'s QR codes '
              'in person, or send a one-time invite text. Each friend also becomes '
              'part of your network.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Two ways to add a friend: in person (QR codes) or a one-time invite text.
Future<void> _addFriend(BuildContext context) async {
  final page = await showModalBottomSheet<Widget>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.qr_code_2),
            title: const Text('In person'),
            subtitle: const Text('Scan each other\'s QR codes. The most secure way.'),
            onTap: () => Navigator.pop(ctx, const PairScreen()),
          ),
          ListTile(
            key: const Key('addByInvite'),
            leading: const Icon(Icons.link),
            title: const Text('With an invite text'),
            subtitle: const Text('Send a one-time text, valid for 15 minutes, or paste one you got.'),
            onTap: () => Navigator.pop(ctx, const InviteScreen()),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (page != null && context.mounted) await push(context, page);
}
