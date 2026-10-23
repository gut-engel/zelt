import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:zelt_core/media.dart';
import 'package:zelt_core/models.dart';

import '../app_state.dart';
import '../media_view.dart';
import 'network_screen.dart';

Future<T?> push<T>(BuildContext context, Widget page) =>
    Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => page));

String shortTime(DateTime t) {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  if (now.difference(t).inHours < 24 && now.day == t.day) {
    return '${two(t.hour)}:${two(t.minute)}';
  }
  return '${two(t.day)}.${two(t.month)}.';
}

String formatBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// A contact's (or our own) profile picture, or the name's first letter
/// while there is none or it is still on its way. Decoded like every
/// received image (see media_view.dart).
class Avatar extends StatelessWidget {
  final String name;
  final double radius;
  final MediaRef? picture;
  const Avatar(this.name, {super.key, this.radius = 20, this.picture});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final letter = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    final initials = CircleAvatar(
      radius: radius,
      backgroundColor: s.primaryContainer,
      foregroundColor: s.onPrimaryContainer,
      child: Text(letter),
    );
    final p = picture;
    if (p == null) return initials;
    return ClipOval(
      child: SizedBox.square(
        dimension: radius * 2,
        child: FittedBox(
          fit: BoxFit.cover,
          child: MediaView(
            key: ValueKey(p.id),
            messenger: context.read<AppState>().m,
            media: p,
            maxWidth: radius * 2,
            maxHeight: radius * 2,
            placeholder: initials,
          ),
        ),
      ),
    );
  }
}

/// Peer count in the app bar.
class NetworkChip extends StatelessWidget {
  final VoidCallback onTap;
  const NetworkChip({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>().m.status;
    final scheme = Theme.of(context).colorScheme;
    final color = s.activePeers == 0
        ? scheme.error
        : s.tooFewPeers
        ? scheme.tertiary
        : scheme.primary;
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(Icons.hub_outlined, color: color, size: 18),
      label: Text('${s.activePeers}/12', style: TextStyle(color: color)),
    );
  }
}

/// Warns when the network is too small for the configured anonymity.
class NetworkBanner extends StatelessWidget {
  const NetworkBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final s = app.m.status;
    final String? text;
    if (s.activePeers == 0 && app.m.contacts.isEmpty) {
      text = null;
    } else if (s.activePeers == 0) {
      text = 'No reachable peers. Messages wait until a friend\'s relay or '
          'another node is reachable.';
    } else if (s.tooFewPeers) {
      text = 'Only ${s.activePeers} ${s.activePeers == 1 ? 'peer' : 'peers'} for ${s.hops} hops: messages use '
          'shorter paths, which is weaker anonymity.';
    } else if (s.lowDiversity) {
      text = 'Most peers come from one source. Pair with more friends to make '
          'routes more diverse.';
    } else {
      text = null;
    }
    if (text == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.tertiaryContainer,
      child: InkWell(
        onTap: () => push(context, const NetworkScreen()),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.info_outline, color: scheme.onTertiaryContainer, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(text, style: TextStyle(color: scheme.onTertiaryContainer)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Offers a verified update, with download progress.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final u = app.update;
    if (u == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final busy = app.updateProgress != null;
    return Material(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(Icons.system_update, color: scheme.onPrimaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('zelt ${u.version} is available', style: TextStyle(color: scheme.onPrimaryContainer)),
                  if (busy) ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(value: app.updateProgress == 0 ? null : app.updateProgress),
                  ] else if (app.updateMessage != null)
                    Text(app.updateMessage!, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            TextButton(onPressed: busy ? null : app.installUpdate, child: const Text('Update')),
          ],
        ),
      ),
    );
  }
}

/// A contact's safety number, in rows of four groups, for comparing with the
/// friend's screen.
class SafetyNumberCard extends StatelessWidget {
  final Contact contact;
  const SafetyNumberCard(this.contact, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final groups = contact.keys.safetyNumber.split(' ');
    final rows = [for (var i = 0; i < groups.length; i += 4) groups.skip(i).take(4).join('  ')];
    return Card(
      key: const Key('safetyNumber'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(r, style: t.textTheme.titleMedium?.copyWith(fontFamily: 'monospace')),
              ),
          ],
        ),
      ),
    );
  }
}
