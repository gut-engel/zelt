import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:zelt_core/address.dart';
import 'package:zelt_core/constants.dart';
import '../app_state.dart';
import 'scan_page.dart';
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

  void _add(String v) {
    try {
      final r = RelayInfo.parseShareString(v);
      context.read<AppState>().m.addManualPeer(r);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Relay ${r.addr} added')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Not a relay address: $e')));
    }
  }

  Future<void> _scanPeer() async {
    final v = await push<String>(
      context,
      const ScanPage(title: 'Scan relay QR code', prefixes: ['zelt-relay:']),
    );
    if (v != null && mounted) _add(v);
  }

  /// Shows one of our relay addresses as a QR code for a friend to scan.
  void _showQr(RelayInfo r) {
    final text = r.toShareString();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(r.addr.toString()),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: QrImageView(data: text, size: 240, backgroundColor: Colors.white),
            ),
            const SizedBox(height: 8),
            const Text('Friends add it under Network > Scan relay QR.', textAlign: TextAlign.center),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              Navigator.pop(ctx);
            },
            child: const Text('Copy'),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
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
    _add(v);
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
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (canScanQr) ...[
            FloatingActionButton.extended(
              heroTag: 'scanRelay',
              onPressed: _scanPeer,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan relay QR'),
            ),
            const SizedBox(height: 12),
          ],
          FloatingActionButton.extended(
            heroTag: 'addRelay',
            onPressed: _addPeer,
            icon: const Icon(Icons.add),
            label: const Text('Add relay'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 160),
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
                    Text('Addresses (tap for QR code)', style: t.textTheme.labelMedium),
                    for (final r in _mine)
                      InkWell(
                        onTap: () => _showQr(r),
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
