import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import 'widgets.dart';

class ContactScreen extends StatelessWidget {
  final String contactId;
  const ContactScreen({super.key, required this.contactId});

  Future<void> _rename(BuildContext context, String current) async {
    final ctl = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(controller: ctl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty && context.mounted) {
      context.read<AppState>().m.renameContact(contactId, name);
    }
  }

  Future<void> _delete(BuildContext context, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove $name?'),
        content: const Text(
          'Deletes the conversation and keys on this device. To talk again you '
          'have to pair in person.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      context.read<AppState>().m.deleteContact(contactId);
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = context.watch<AppState>().m;
    final c = m.contacts[contactId];
    if (c == null) return const Scaffold();
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(c.name),
        actions: [
          IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _rename(context, c.name)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(child: Avatar(c.name, radius: 36)),
          const SizedBox(height: 24),
          Text('Safety number', style: t.textTheme.titleMedium),
          const SizedBox(height: 8),
          SafetyNumberCard(c),
          const SizedBox(height: 8),
          Text(
            'Compare this with ${c.name}\'s screen while you are together. If '
            'the numbers match, nobody swapped a code during pairing.',
            style: t.textTheme.bodySmall,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Numbers match'),
            value: c.verified,
            onChanged: (v) => m.setVerified(c.id, v),
          ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(c.ready ? Icons.lock : Icons.lock_clock),
            title: Text(c.ready ? 'End-to-end encrypted' : 'Handshake in progress'),
            subtitle: Text(
              c.ready
                  ? 'Double Ratchet over a hybrid X25519 + ML-KEM-768 root.'
                  : 'Waiting for ${c.name}\'s device to answer the post-quantum key exchange.',
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.inbox_outlined),
            title: Text('${c.theirMailboxes.map((g) => g.relay.id).toSet().length} mailbox relays known'),
            subtitle: Text('${c.tokensLeft(DateTime.now())} send tokens left'),
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: t.colorScheme.error),
            onPressed: () => _delete(context, c.name),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Remove friend'),
          ),
        ],
      ),
    );
  }
}
