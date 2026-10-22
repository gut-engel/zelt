import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:zelt_core/address.dart';
import 'package:zelt_core/constants.dart';
import '../app_state.dart';
import 'widgets.dart';

class NetworkScreen extends StatefulWidget {
  const NetworkScreen({super.key});

  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<NetworkScreen> {
  List<RelayInfo> _mine = [];

  @override
  void initState() {
    super.initState();
    _loadMine();
  }

  Future<void> _loadMine() async {
    final r = await context.read<AppState>().m.myRelayInfos();
    if (mounted) setState(() => _mine = r);
  }

  Future<void> _addPeer() async {
    final ctl = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add a relay'),
        content: TextField(
          controller: ctl,
          decoration: const InputDecoration(hintText: 'zelt-relay:IP:PORT/KEY'),
          maxLines: 3,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Add')),
        ],
      ),
    );
    if (v == null || !mounted) return;
    try {
      context.read<AppState>().m.addManualPeer(RelayInfo.parseShareString(v));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Not a relay address: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = context.watch<AppState>().m;
    final s = m.status;
    final t = Theme.of(context);
    final peers = m.peers.known.values.toList()
      ..sort((a, b) => (m.peers.active.contains(b.relay.key) ? 1 : 0) - (m.peers.active.contains(a.relay.key) ? 1 : 0));

    Widget stat(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(value, style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Network'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: () { _loadMine(); m.pollNow(); })],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addPeer,
        icon: const Icon(Icons.add),
        label: const Text('Add relay'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  stat('Active peers', '${s.activePeers} / $targetPeers'),
                  stat('Known relays', '${s.knownPeers}'),
                  stat('Hops per message', '${s.hops}'),
                  stat('Your mailbox relays', '${s.mailboxRelays}'),
                  stat('Entry relay', s.entry?.addr.toString() ?? 'none'),
                  stat('DHT table', '${s.dhtSize} nodes'),
                ],
              ),
            ),
          ),
          if (s.tooFewPeers)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Fewer peers than hops: zelt sends with the peers it has and keeps '
                'looking. Pair with more friends or add an always-on relay.',
                style: TextStyle(color: t.colorScheme.tertiary),
              ),
            ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Your relay', style: t.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  stat('Status', !s.relayRunning ? 'off' : (s.relayReachable ? 'reachable' : 'not reached yet')),
                  stat('Blobs held (RAM)', '${s.storedBlobs}'),
                  stat('Memory used', '${formatBytes(s.storedBytes)} of ${formatBytes(relayCapBytes)}'),
                  stat('Packets relayed', '${m.node.stats.packetsRelayed}'),
                  if (_mine.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('Addresses (tap to copy)', style: t.textTheme.labelMedium),
                    for (final r in _mine)
                      InkWell(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: r.toShareString()));
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(r.addr.toString(), style: const TextStyle(fontFamily: 'monospace')),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Peers', style: t.textTheme.titleMedium),
          for (final p in peers)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                m.peers.active.contains(p.relay.key) ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                color: p.healthy ? t.colorScheme.primary : t.colorScheme.error,
              ),
              title: Text(p.relay.addr.toString(), style: const TextStyle(fontFamily: 'monospace')),
              subtitle: Text(
                '${p.sources.map((s) => m.contacts[s]?.name ?? s).join(', ')}'
                '${p.failures > 0 ? ' · ${p.failures} failures' : ''}'
                '${p.lastOk != null ? ' · ok ${shortTime(p.lastOk!)}' : ''}',
              ),
            ),
          const SizedBox(height: 16),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Log'),
            children: [
              for (final l in m.logLines.reversed.take(100))
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(l, style: t.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
