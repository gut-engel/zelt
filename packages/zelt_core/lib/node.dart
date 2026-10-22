import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'address.dart';
import 'bytes.dart';
import 'constants.dart';
import 'crypto.dart';
import 'dht.dart';
import 'link.dart';
import 'protocol.dart';
import 'relay_store.dart';
import 'sphinx.dart';
import 'tokens.dart';

typedef ReplyHandler = void Function(ReplyMsg reply);

class _PendingSurb {
  final SurbSecret secret;
  final ReplyHandler onReply;
  final DateTime expires;
  _PendingSurb(this.secret, this.onReply, this.expires);
}

class NodeStats {
  int packetsIn = 0;
  int packetsRelayed = 0;
  int blobsStored = 0;
  int fetchesServed = 0;
  int inboundLinks = 0;
  DateTime? lastInbound;
}

/// One zelt node: an onion relay with a RAM-only mailbox store (when relaying
/// is on) and the client side that sends onions and receives SURB replies.
class Node {
  final KeyPair25519 key;
  final TokenIssuer issuer;
  final RelayStore store = RelayStore();
  final ReplayFilter replay = ReplayFilter();
  final DhtTable dht;
  final NodeStats stats = NodeStats();

  /// Bind address for the relay server.
  final InternetAddress bindAddress;

  /// Advertise loopback addresses (tests and single-machine setups).
  final bool advertiseLoopback;

  int port;
  bool _relayEnabled = false;
  ServerSocket? _server;

  final Map<String, Future<Link>> _out = {};
  final Map<String, Link> _clients = {};
  final Map<String, _PendingSurb> _surbs = {};
  final Map<String, Completer<void>> _pings = {};

  Link? _entryLink;
  RelayInfo? entry;
  Uint8List _cookie = randomBytes(8);

  Timer? _janitor;

  /// Called after every connection attempt so the peer manager can track
  /// peer health.
  void Function(RelayInfo relay, bool ok)? onLinkResult;

  /// Relays this node will hand its blobs to on shutdown; advertised in every
  /// reply so recipients know where to look.
  List<RelayInfo> Function() handoffPartners = () => const [];

  /// A blob was stored here (lets our own client react without polling).
  void Function(Uint8List mailboxId)? onStored;

  /// A relay announced itself to us and passed the reachability check.
  void Function(RelayInfo relay)? onAnnounce;

  void Function(String msg)? onLog;

  Node({
    required this.key,
    required Uint8List relaySecret,
    this.port = defaultPort,
    InternetAddress? bindAddress,
    this.advertiseLoopback = false,
  }) : issuer = TokenIssuer(relaySecret),
       dht = DhtTable(key.pub),
       bindAddress = bindAddress ?? InternetAddress.anyIPv6;

  bool get relayEnabled => _relayEnabled;
  bool get relayRunning => _server != null;

  void _log(String m) => onLog?.call(m);

  Future<void> start({required bool relay}) async {
    _janitor ??= Timer.periodic(const Duration(seconds: 30), (_) => _cleanup());
    await setRelay(relay);
  }

  Future<void> setRelay(bool on) async {
    _relayEnabled = on;
    if (on && _server == null) {
      try {
        _server = await ServerSocket.bind(
          bindAddress,
          port,
          v6Only: false,
          shared: false,
        );
        port = _server!.port;
        _server!.listen(_accept, onError: (Object e) => _log('server: $e'));
        _log('relay listening on port $port');
      } catch (e) {
        _log('relay bind failed: $e');
        _server = null;
      }
    } else if (!on && _server != null) {
      await _server!.close();
      _server = null;
      for (final l in _clients.values) {
        l.close();
      }
      _clients.clear();
    }
  }

  Future<void> stop() async {
    _janitor?.cancel();
    _janitor = null;
    await setRelay(false);
    for (final f in _out.values) {
      f.then((l) => l.close()).ignore();
    }
    _out.clear();
    _entryLink?.close();
    _entryLink = null;
    entry = null;
  }

  /// Addresses this relay can be reached at, one [RelayInfo] each.
  Future<List<RelayInfo>> localRelayInfos() async {
    if (_server == null) return [];
    if (bindAddress.isLoopback) {
      return [RelayInfo(NodeAddr(bindAddress, port), key.pub)];
    }
    final out = <RelayInfo>[];
    try {
      final ifs = await NetworkInterface.list(
        includeLoopback: advertiseLoopback,
        type: InternetAddressType.any,
      );
      for (final i in ifs) {
        for (final a in i.addresses) {
          if (a.isLinkLocal) continue;
          if (a.isLoopback && !advertiseLoopback) continue;
          if (a.type == InternetAddressType.IPv6 && _isUlaOrTemp(a)) continue;
          out.add(RelayInfo(NodeAddr(a, port), key.pub));
        }
      }
    } catch (e) {
      _log('interface list failed: $e');
    }
    if (advertiseLoopback && !out.any((r) => r.addr.isLoopback)) {
      out.add(RelayInfo(NodeAddr(InternetAddress.loopbackIPv4, port), key.pub));
    }
    // IPv4 first: on a shared LAN it is the address most likely to work.
    out.sort((a, b) => (a.addr.isV6 ? 1 : 0) - (b.addr.isV6 ? 1 : 0));
    return out;
  }

  static bool _isUlaOrTemp(InternetAddress a) => (a.rawAddress[0] & 0xfe) == 0xfc;

  bool isSelf(RelayInfo r) => bytesEqual(r.nodePk, key.pub);

  // --- Links -----------------------------------------------------------

  Future<void> _accept(Socket s) async {
    try {
      final link = (await Link.accept(s, key)).start();
      stats.inboundLinks++;
      stats.lastInbound = DateTime.now();
      link.frames.listen(
        (f) => _onServerFrame(link, f),
        onDone: () => _clients.removeWhere((_, l) => identical(l, link)),
      );
    } catch (e) {
      _log('accept failed: $e');
    }
  }

  Future<Link> _link(RelayInfo r) {
    final k = r.key;
    final existing = _out[k];
    if (existing != null) {
      return existing.then((l) {
        if (!l.isClosed) return l;
        _out.remove(k);
        return _link(r);
      });
    }
    final f = Link.connect(r).then((l) {
      l.start();
      l.frames.listen(
        (fr) => _onClientFrame(l, fr),
        onDone: () {
          _out.remove(k);
          if (identical(l, _entryLink)) {
            _entryLink = null;
            entry = null;
          }
        },
      );
      onLinkResult?.call(r, true);
      return l;
    });
    _out[k] = f;
    f.catchError((Object e) {
      _out.remove(k);
      onLinkResult?.call(r, false);
      throw e;
    }).ignore();
    return f;
  }

  void _onServerFrame(Link link, Frame f) {
    switch (f.type) {
      case FrameType.packet:
        stats.packetsIn++;
        _process(Uint8List.fromList(f.body));
      case FrameType.register:
        _clients[hex(f.body)] = link;
      case FrameType.announce:
        _onAnnounce(RelayInfo.decode(f.body));
      case FrameType.ping:
        link.send(Frame.pong()).ignore();
      default:
        break;
    }
  }

  void _onClientFrame(Link link, Frame f) {
    switch (f.type) {
      case FrameType.clientDelivery:
        _onDelivery(f.body.sublist(0, 8), Uint8List.fromList(f.body.sublist(8)));
      case FrameType.pong:
        for (final c in _pings.values.toList()) {
          if (!c.isCompleted) c.complete();
        }
      default:
        break;
    }
  }

  /// Checks that a relay is reachable and holds its node key.
  Future<bool> ping(RelayInfo r, {Duration timeout = const Duration(seconds: 5)}) async {
    try {
      final l = await _link(r);
      final id = hex(randomBytes(8));
      final c = Completer<void>();
      _pings[id] = c;
      await l.send(Frame.ping());
      await c.future.timeout(timeout);
      _pings.remove(id);
      // Also report success when an existing link was reused.
      onLinkResult?.call(r, true);
      return true;
    } catch (_) {
      onLinkResult?.call(r, false);
      return false;
    }
  }

  /// Tells another relay that we exist, so it can list us in its DHT table.
  Future<void> announceTo(RelayInfo target, RelayInfo me) async {
    try {
      final l = await _link(target);
      await l.send(Frame(FrameType.announce, me.encode()));
    } catch (_) {}
  }

  Future<void> _onAnnounce(RelayInfo r) async {
    if (isSelf(r)) return;
    if (await ping(r)) {
      dht.add(r);
      onAnnounce?.call(r);
    }
  }

  /// Sends a finished onion packet to its first hop.
  Future<void> sendPacket(RelayInfo first, Uint8List packet) async {
    if (isSelf(first) && relayRunning) {
      unawaited(_process(packet));
      return;
    }
    final l = await _link(first);
    await l.send(Frame.packet(packet));
  }

  // --- Relay -----------------------------------------------------------

  Future<void> _process(Uint8List packet) async {
    final p = await Sphinx.peel(key, packet, replay);
    if (p == null) return;
    switch (p.slot.cmd) {
      case SlotCmd.relay:
        stats.packetsRelayed++;
        final next = RelayInfo(p.slot.nextAddr!, p.slot.nextPk);
        final delay = _holdTime(p.slot.delayMs);
        Future.delayed(delay, () async {
          try {
            await sendPacket(next, p.next!);
          } catch (e) {
            _log('forward to $next failed');
          }
        });
      case SlotCmd.deliver:
        Future.delayed(_holdTime(p.slot.delayMs), () => _deliver(p.payload));
      case SlotCmd.toClient:
        final link = _clients[hex(p.slot.extra.sublist(0, 8))];
        if (link == null || link.isClosed) return;
        final body = concat([p.slot.extra.sublist(8, 16), p.payload]);
        Future.delayed(_holdTime(p.slot.delayMs), () {
          link.send(Frame(FrameType.clientDelivery, body)).ignore();
        });
    }
  }

  /// Delays of a second or more are rounded up to whole-second batches so
  /// packets leave in groups (paranoid mode).
  static Duration _holdTime(int ms) {
    final capped = min(ms, 60000);
    if (capped < 1000) return Duration(milliseconds: capped);
    final now = DateTime.now().millisecondsSinceEpoch;
    final due = now + capped;
    return Duration(milliseconds: (due ~/ 1000 + 1) * 1000 - now);
  }

  Future<void> _deliver(Uint8List payload) async {
    final r = ByteReader(payload);
    try {
      switch (r.u8()) {
        case Cmd.store:
          if (!_relayEnabled) return;
          final c = StoreCmd.decode(r);
          final h = await Crypto.sha256(c.blob);
          if (!await issuer.verifyAndSpend(c.token, h)) {
            _log('store rejected: bad token');
            return;
          }
          final pool = c.token.slot >= firstPublicSlot ? BlobPool.public : BlobPool.contact;
          if (store.store(
            mailboxId: c.mailboxId,
            blob: c.blob,
            deleteTag: c.deleteTag,
            slot: c.token.slot,
            pool: pool,
          )) {
            stats.blobsStored++;
            onStored?.call(c.mailboxId);
          }
        case Cmd.fetch:
          if (!_relayEnabled) return;
          stats.fetchesServed++;
          final c = FetchCmd.decode(r);
          await _serveFetch(c);
        case Cmd.delete:
          final c = DeleteCmd.decode(r);
          for (final e in c.entries) {
            store.delete(e.mailboxId, e.hash, e.deleteKey);
          }
        case Cmd.drop:
          break;
        case Cmd.tokenReq:
          if (!_relayEnabled) return;
          final surb = Surb.decode(r.bytes(Surb.encodedSize));
          final self = (await localRelayInfos()).firstOrNull;
          if (self == null) return;
          final cred = await issuer.issuePublic(self);
          await _reply(surb, ReplyMsg(Reply.credential, credential: cred));
        case Cmd.dhtFind:
          final surb = Surb.decode(r.bytes(Surb.encodedSize));
          final target = r.bytes(32);
          await _reply(surb, ReplyMsg(Reply.nodes, nodes: dht.closest(target)));
        case Cmd.handoff:
          if (!_relayEnabled) return;
          final c = HandoffCmd.decode(r);
          final maxExp = DateTime.now().add(relayTtl);
          store.store(
            mailboxId: c.mailboxId,
            blob: c.blob,
            deleteTag: c.deleteTag,
            slot: 0xffff,
            pool: BlobPool.handoff,
            expiresAt: c.expiresAt.isAfter(maxExp) ? maxExp : c.expiresAt,
          );
      }
    } catch (e) {
      _log('bad command: $e');
    }
  }

  Future<void> _serveFetch(FetchCmd c) async {
    if (c.surbs.isEmpty) return;
    final (blobs, more) = store.fetch(c.mailboxIds, c.surbs.length);
    if (blobs.isEmpty) {
      await _reply(c.surbs.first, ReplyMsg(Reply.empty));
      return;
    }
    for (var i = 0; i < blobs.length; i++) {
      final isLast = i == blobs.length - 1;
      await _reply(
        c.surbs[i],
        ReplyMsg(
          Reply.blob,
          last: isLast && !more,
          mailboxId: blobs[i].mailboxId,
          blob: blobs[i].blob,
        ),
      );
    }
  }

  /// Local mailbox access for this node's own client (no network needed).
  (List<StoredBlob>, bool) fetchLocal(List<Uint8List> ids, int max) =>
      store.fetch(ids, max);

  Future<void> _reply(Surb surb, ReplyMsg msg) async {
    final withPartners = ReplyMsg(
      msg.type,
      last: msg.last,
      partners: handoffPartners().take(maxPartners).toList(),
      mailboxId: msg.mailboxId,
      blob: msg.blob,
      credential: msg.credential,
      nodes: msg.nodes,
    );
    try {
      await sendPacket(surb.firstHop, surb.packetWith(withPartners.encode()));
    } catch (e) {
      _log('reply failed: $e');
    }
  }

  // --- Client ----------------------------------------------------------

  bool get hasEntry => _entryLink != null && !_entryLink!.isClosed;

  /// Keeps one registered connection to an entry relay; SURB replies come
  /// back through it.
  Future<RelayInfo?>? _entryAttempt;

  /// Concurrent callers share one attempt (each attempt registers a cookie).
  Future<RelayInfo?> ensureEntry(List<RelayInfo> candidates) {
    if (hasEntry) return Future.value(entry);
    return _entryAttempt ??= _connectEntry(candidates).whenComplete(() => _entryAttempt = null);
  }

  Future<RelayInfo?> _connectEntry(List<RelayInfo> candidates) async {
    for (final c in candidates) {
      if (isSelf(c)) continue;
      try {
        final l = await _link(c);
        _cookie = randomBytes(8);
        await l.send(Frame(FrameType.register, _cookie));
        _entryLink = l;
        entry = c;
        _log('entry relay: $c');
        return c;
      } catch (_) {}
    }
    return null;
  }

  /// Builds a SURB through [hops] (the last one must be [entry]).
  Future<Surb> makeSurb(
    List<Hop> hops,
    ReplyHandler onReply, {
    Duration ttl = const Duration(minutes: 2),
  }) async {
    final (surb, secret) = await Sphinx.surb(hops, _cookie);
    _surbs[hex(secret.id)] = _PendingSurb(secret, onReply, DateTime.now().add(ttl));
    return surb;
  }

  Future<void> _onDelivery(Uint8List surbId, Uint8List payload) async {
    final p = _surbs.remove(hex(surbId));
    if (p == null) return;
    try {
      final plain = await Sphinx.openReply(p.secret, payload);
      p.onReply(ReplyMsg.decode(plain));
    } catch (e) {
      _log('bad reply: $e');
    }
  }

  void _cleanup() {
    final now = DateTime.now();
    _surbs.removeWhere((_, p) => p.expires.isBefore(now));
    store.expire();
    replay.prune();
    for (final e in _out.entries.toList()) {
      e.value.then((l) {
        if (identical(l, _entryLink)) return;
        if (now.difference(l.lastActivity) > const Duration(minutes: 2)) {
          l.close();
          _out.remove(e.key);
        }
      }).ignore();
    }
  }

  /// Hands off stored blobs on a clean shutdown. Returns them and clears
  /// the store; the caller sends them on through onion paths.
  List<StoredBlob> drainForHandoff() => store.drain();
}
