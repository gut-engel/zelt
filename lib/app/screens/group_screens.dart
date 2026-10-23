import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/groups.dart';
import 'package:zelt_core/models.dart';
import '../app_state.dart';
import 'chat_screen.dart';
import 'widgets.dart';

/// One line about where a group stands.
String groupStatus(Group g) {
  final n = g.roster.members.length;
  return switch (g.state) {
    GroupState.invited => 'Invitation',
    GroupState.joining => 'Waiting for the admin to add you…',
    GroupState.member => g.roster.closed ? '$n members · closed (the admin left)' : '$n member${n == 1 ? '' : 's'}',
    GroupState.left => 'You left this group',
    GroupState.removed => 'You were removed from this group',
  };
}

class GroupAvatar extends StatelessWidget {
  final String name;
  final double radius;
  const GroupAvatar(this.name, {super.key, this.radius = 20});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: radius,
      backgroundColor: s.tertiaryContainer,
      foregroundColor: s.onTertiaryContainer,
      child: Icon(Icons.group, size: radius),
    );
  }
}

/// Picks contacts (for a new group, or to invite to one).
class _ContactPicker extends StatelessWidget {
  final List<Contact> contacts;
  final Set<String> selected;
  final void Function(String id, bool on) onChanged;
  const _ContactPicker({required this.contacts, required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    if (contacts.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('No friends to add. A group is made of friends you paired with.'),
      );
    }
    return Column(
      children: [
        for (final c in contacts)
          CheckboxListTile(
            key: Key('pick-${c.id}'),
            value: selected.contains(c.id),
            onChanged: (v) => onChanged(c.id, v ?? false),
            secondary: Avatar(c.name, picture: c.shownAvatar),
            title: Text(c.name),
          ),
      ],
    );
  }
}

class NewGroupScreen extends StatefulWidget {
  const NewGroupScreen({super.key});

  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  final _name = TextEditingController();
  final _selected = <String>{};
  bool _busy = false;
  String? _error;

  Future<void> _create() async {
    final app = context.read<AppState>();
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Give the group a name');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final g = await app.m.createGroup(_name.text, _selected);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ChatScreen.group(groupId: g.id)));
    } catch (e) {
      setState(() {
        _busy = false;
        _error = e is StateError ? e.message : (e is ArgumentError ? '${e.message}' : '$e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final contacts = app.m.contacts.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('New group')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              key: const Key('groupName'),
              controller: _name,
              maxLength: 40,
              decoration: InputDecoration(labelText: 'Group name', errorText: _error),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'You are the admin: only you can add or remove people. Members do not need to be '
              'friends with each other; their messages reach everyone through the members who are. '
              'Everyone sees the names the members chose for themselves.',
              style: t.textTheme.bodySmall,
            ),
          ),
          _ContactPicker(
            contacts: contacts,
            selected: _selected,
            onChanged: (id, on) => setState(() => on ? _selected.add(id) : _selected.remove(id)),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              key: const Key('createGroup'),
              onPressed: _busy ? null : _create,
              child: Text(_selected.isEmpty ? 'Create group' : 'Create and invite ${_selected.length}'),
            ),
          ),
        ],
      ),
    );
  }
}

class GroupInfoScreen extends StatelessWidget {
  final String groupId;
  const GroupInfoScreen({super.key, required this.groupId});

  Future<void> _rename(BuildContext context, Group g) async {
    final ctl = TextEditingController(text: g.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename group'),
        content: TextField(controller: ctl, autofocus: true, maxLength: 40),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty && context.mounted) {
      await _run(context, () => context.read<AppState>().m.renameGroup(g.id, name));
    }
  }

  Future<void> _invite(BuildContext context, Group g) async {
    final app = context.read<AppState>();
    final candidates = app.m.contacts.values
        .where((c) => g.roster.member(c.id) == null && !g.pendingInvites.contains(c.id))
        .toList();
    final selected = <String>{};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Invite friends'),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: _ContactPicker(
                contacts: candidates,
                selected: selected,
                onChanged: (id, on) => setState(() => on ? selected.add(id) : selected.remove(id)),
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Invite')),
          ],
        ),
      ),
    );
    if (ok == true && selected.isNotEmpty && context.mounted) {
      await _run(context, () => app.m.inviteToGroup(g.id, selected));
    }
  }

  Future<void> _run(BuildContext context, Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e is StateError ? e.message : '$e')));
      }
    }
  }

  Future<bool> _confirm(BuildContext context, String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final m = app.m;
    final g = m.groups[groupId];
    if (g == null) return const Scaffold();
    final t = Theme.of(context);
    final me = m.identity.id.pub;
    final admin = g.isAdmin && g.active && !g.roster.closed;
    return Scaffold(
      appBar: AppBar(
        title: Text(g.name),
        actions: [
          if (admin) IconButton(tooltip: 'Rename', icon: const Icon(Icons.edit_outlined), onPressed: () => _rename(context, g)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          Center(child: GroupAvatar(g.name, radius: 36)),
          const SizedBox(height: 8),
          Center(child: Text(groupStatus(g), style: t.textTheme.bodyMedium)),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('Members', style: t.textTheme.titleMedium),
          ),
          for (final member in g.roster.members)
            ListTile(
              leading: Avatar(member.name, picture: m.contacts[member.id]?.shownAvatar),
              title: Text(
                member.id == hex(me) ? 'You (${member.name})' : (m.contacts[member.id]?.name ?? member.name),
              ),
              subtitle: Text([
                if (bytesEqual(member.signPk, g.roster.adminSignPk)) 'Admin',
                if (member.id != hex(me) && m.contacts[member.id] == null) 'Not your friend: messages come through others',
                if (m.contacts[member.id] != null && m.contacts[member.id]!.name != member.name) 'Calls themselves ${member.name}',
              ].join(' · ')),
              trailing: admin && member.id != hex(me)
                  ? IconButton(
                      tooltip: 'Remove from group',
                      icon: const Icon(Icons.person_remove_outlined),
                      onPressed: () async {
                        if (await _confirm(context, 'Remove ${member.name}?', 'They get no new messages from this group.', 'Remove')) {
                          if (context.mounted) await _run(context, () => m.removeFromGroup(g.id, member.id));
                        }
                      },
                    )
                  : null,
            ),
          if (g.isAdmin)
            for (final id in g.pendingInvites)
              ListTile(
                leading: const Icon(Icons.hourglass_top),
                title: Text(m.contacts[id]?.name ?? 'A friend'),
                subtitle: const Text('Invited, has not joined yet'),
                trailing: admin
                    ? IconButton(
                        tooltip: 'Withdraw invitation',
                        icon: const Icon(Icons.close),
                        onPressed: () => _run(context, () => m.removeFromGroup(g.id, id)),
                      )
                    : null,
              ),
          if (admin)
            ListTile(
              key: const Key('inviteMore'),
              leading: const Icon(Icons.person_add_alt_1_outlined),
              title: const Text('Invite friends'),
              enabled: g.roster.members.length + g.pendingInvites.length < maxGroupMembers,
              onTap: () => _invite(context, g),
            ),
          const Divider(),
          SwitchListTile(
            key: const Key('groupPrivate'),
            secondary: const Icon(Icons.lock_outline),
            title: const Text('Private chat'),
            subtitle: const Text('Hidden when zelt is opened with the duress PIN'),
            value: g.private,
            onChanged: (v) => app.setPrivate(g.id, v),
          ),
          const Divider(),
          if (g.state == GroupState.member || g.state == GroupState.joining)
            ListTile(
              leading: Icon(Icons.logout, color: t.colorScheme.error),
              title: Text('Leave group', style: TextStyle(color: t.colorScheme.error)),
              subtitle: g.isAdmin ? const Text('As the admin, leaving closes the group: nobody can be added or removed any more.') : null,
              onTap: () async {
                if (await _confirm(context, 'Leave "${g.name}"?', 'You stop getting its messages.', 'Leave')) {
                  if (context.mounted) await _run(context, () => m.leaveGroup(g.id));
                }
              },
            )
          else if (g.state != GroupState.invited)
            ListTile(
              leading: Icon(Icons.delete_outline, color: t.colorScheme.error),
              title: Text('Delete group', style: TextStyle(color: t.colorScheme.error)),
              subtitle: const Text('Removes it and its messages from this device'),
              onTap: () async {
                if (await _confirm(context, 'Delete "${g.name}"?', 'Its messages are deleted from this device.', 'Delete')) {
                  m.deleteGroup(g.id);
                  if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
                }
              },
            ),
        ],
      ),
    );
  }
}
