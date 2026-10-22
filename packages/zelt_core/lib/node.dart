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
import 'onion.dart';
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

/// A standing fetch registered by a recipient (see WatchCmd).
class _Watch {
  final List<Surb> surbs;
  final DateTime expires;
  final List<String> ids;
  _Watch(this.surbs, this.expires, this.ids);
}

class NodeStats {
  int packetsIn = 0;
  int packetsRelayed = 0;
  int blobsStored = 0;
  int fetchesServed = 0;
  int watchesServed = 0;

  /// Packets dropped: unknown or retired onion key, bad MAC, or replay.
  int packetsRejected = 0;
  int inboundLinks = 0;
  DateTime? lastInbound;
}

/// One zelt node: an onion relay with a RAM-only mailbox store (when relaying
/// is on) and the client side that sends onions and receives SURB replies.
class Node {
  /// Long-term identity: authenticates links and signs onion-key certificates.
  final SigningKey identity;

  /// This relay's rotating onion keys (RAM only).
  final OnionKeyring keyring;

  /// Verified onion-key certificates of other relays.
  final CertStore certs = CertStore();

  /// New verified certificates arrived (from a link, gossip or the DHT).
  void Function()? onCerts;
  final TokenIssuer issuer;
  final RelayStore store = RelayStore();
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

  /// Our entry relay changed or was lost: SURBs made for the old one are
  /// useless, so watches must be renewed.
  void Function()? onEntryChanged;

  /// A relay announced itself to us and passed the reachability check.
  void Function(RelayInfo relay)? onAnnounce;

  void Function(String msg)? onLog;

  Node({
    required this.identity,
    required Uint8List relaySecret,
    this.port = defaultPort,
    InternetAddress? bindAddress,
    this.advertiseLoopback = false,
  }) : issuer = TokenIssuer(relaySecret),
       keyring = OnionKeyring(identity),
       dht = DhtTable(identity.pub),
       bindAddress = bindAddress ?? InternetAddress.anyIPv6;

  bool get relayEnabled => _relayEnabled;
  bool get relayRunning => _server != null;

  void _log(String m) => onLog?.call(m);

  Future<void> start({required bool relay}) async {
    _stopping = false;
    _janitor ??= Timer.periodic(const Duration(seconds: 30), (_) => _cleanup());
    keyring.onRotate = () {
      for (final l in _inbound.toList()) {
        unawaited(_sendCerts(l));
      }
    };
    await keyring.maintain();
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
      // Relaying off means off: drop every connection peers opened to us.
      for (final l in [..._inbound, ..._clients.values]) {
        l.close();
      }
      _inbound.clear();
      _clients.clear();
      _watches.clear();
      _watchesById.clear();
    }
  }

  Future<void> stop() async {
    _stopping = true;
    _janitor?.cancel();
    _janitor = null;
    await setRelay(false);
    // Onion keys never outlive the process run that made them.
    keyring.wipe();
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
      return [RelayInfo(NodeAddr(bindAddress, port), identity.pub)];
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
          out.add(RelayInfo(NodeAddr(a, port), identity.pub));
        }
      }
    } catch (e) {
      _log('interface list failed: $e');
    }
    if (advertiseLoopback && !out.any((r) => r.addr.isLoopback)) {
      out.add(RelayInfo(NodeAddr(InternetAddress.loopbackIPv4, port), identity.pub));
    }
    // IPv4 first: on a shared LAN it is the address most likely to work.
    out.sort((a, b) => (a.addr.isV6 ? 1 : 0) - (b.addr.isV6 ? 1 : 0));
    return out;
  }

  static bool _isUlaOrTemp(InternetAddress a) => (a.rawAddress[0] & 0xfe) == 0xfc;

  bool isSelf(RelayInfo r) => bytesEqual(r.nodePk, identity.pub);

  // --- Links -----------------------------------------------------------

  Future<void> _accept(Socket s) async {
    try {
      final link = (await Link.accept(s, identity)).start();
      _inbound.add(link);
      unawaited(_sendCerts(link));
      stats.inboundLinks++;
      stats.lastInbound = DateTime.now();
      link.frames.listen(
        (f) => _onServerFrame(link, f),
        onDone: () {
          _clients.removeWhere((_, l) => identical(l, link));
          _inbound.remove(link);
        },
      );
    } catch (e) {
      _log('accept failed: $e');
    }
  }

  /// Test hook: simulates network reachability (false = cannot connect).
  bool Function(RelayInfo r)? canDial;

  Future<Link> _link(RelayInfo r) {
    final dial = canDial;
    if (dial != null && !dial(r)) return Future.error(SocketException('unreachable (test)'));
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
        (fr) => _onClientFrame(l, fr, r),
        onDone: () {
          _out.remove(k);
          if (identical(l, _entryLink)) {
            _entryLink = null;
            entry = null;
            onEntryChanged?.call();
          }
          // The relay may have restarted with new onion keys: reconnect soon
          // (jittered) so it pushes its current set. Idle closes are ours.
          if (!_stopping && !_idleClosed.remove(l)) {
            Timer(Duration(milliseconds: 500 + randomInt(2500)), () {
              if (!_stopping) unawaited(ping(r));
            });
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

  void _onClientFrame(Link link, Frame f, RelayInfo from) {
    switch (f.type) {
      case FrameType.onionKeys:
        unawaited(_storeCerts(f.body, from));
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

  final Set<Link> _inbound = {};

  // Watches: newest last. Bounded: at most [_maxWatches] in total, the newest
  // [_watchesPerId] per mailbox ID; expired ones are dropped by the janitor.
  final List<_Watch> _watches = [];
  final Map<String, List<_Watch>> _watchesById = {};
  static const _maxWatches = 1024;
  static const _watchesPerId = 2;

  /// A blob sent through a watch is not sent through watches again for this
  /// long (the recipient's delete is on its way); fetches still return it.
  static const _watchResendAfter = Duration(seconds: 30);

  bool _watchSendable(StoredBlob b, DateTime now) {
    final t = b.watchSentAt;
    return t == null || now.difference(t) > _watchResendAfter;
  }

  void _addWatch(WatchCmd c) {
    final w = _Watch(List.of(c.surbs), DateTime.now().add(c.ttl), [for (final id in c.mailboxIds) hex(id)]);
    _watches.add(w);
    for (final id in w.ids) {
      final l = _watchesById.putIfAbsent(id, () => []);
      l.add(w);
      while (l.length > _watchesPerId) {
        _dropWatch(l.first);
      }
    }
    while (_watches.length > _maxWatches) {
      _dropWatch(_watches.first);
    }
  }

  void _dropWatch(_Watch w) {
    _watches.remove(w);
    for (final id in w.ids) {
      final l = _watchesById[id];
      l?.remove(w);
      if (l != null && l.isEmpty) _watchesById.remove(id);
    }
  }

  /// A blob was stored under [mailboxId]: if a recipient watches it, send it
  /// now through one of its SURBs (each SURB is used at most once).
  int watchMisses = 0;

  Future<void> _notifyWatch(Uint8List mailboxId, Uint8List blob) async {
    final now = DateTime.now();
    final stored = store.byHash(Crypto.sha256Sync(blob));
    if (stored != null && !_watchSendable(stored, now)) return;
    final l = _watchesById[hex(mailboxId)];
    if (l == null) {
      watchMisses++;
      return;
    }
    for (final w in l.reversed.toList()) {
      if (w.expires.isBefore(now)) {
        _dropWatch(w);
        continue;
      }
      if (w.surbs.isEmpty) continue;
      final surb = w.surbs.removeAt(0);
      if (w.surbs.isEmpty) _dropWatch(w);
      stored?.watchSentAt = now;
      stats.watchesServed++;
      await _reply(surb, ReplyMsg(Reply.blob, last: false, mailboxId: mailboxId, blob: blob));
      return;
    }
    watchMisses++;
  }
  final Set<Link> _idleClosed = {};
  bool _stopping = false;

  Future<void> _sendCerts(Link l) async {
    final cs = keyring.certs.take(maxCertsPerFrame).toList();
    if (cs.isEmpty) return;
    final w = ByteWriter()..u8(cs.length);
    for (final c in cs) {
      w.bytes(c.encode());
    }
    try {
      await l.send(Frame(FrameType.onionKeys, w.toPadded(1 + maxCertsPerFrame * OnionKeyCert.encodedSize)));
    } catch (_) {}
  }

  /// Certificates pushed by a relay we are connected to; only accepted for
  /// that relay's own identity.
  Future<void> _storeCerts(Uint8List body, RelayInfo from) async {
    try {
      final r = ByteReader(body);
      final list = [for (var i = r.u8().clamp(0, maxCertsPerFrame); i > 0; i--) OnionKeyCert.decode(r)];
      if (await certs.replaceFor(from.nodePk, list)) onCerts?.call();
    } catch (_) {}
  }

  /// Adds certificates learned second-hand (gossip, DHT); each is verified
  /// against the identity it names.
  Future<void> addCerts(Iterable<OnionKeyCert> cs) async {
    var added = false;
    for (final c in cs) {
      added |= await certs.add(c);
    }
    if (added) onCerts?.call();
  }

  /// A hop through [r] using its newest usable onion key, or null if none is
  /// known. Our own relay uses its live key directly.
  Hop? hopFor(RelayInfo r, {int delayMs = 0}) {
    final c = isSelf(r) ? keyring.currentCert : certs.best(r.nodePk);
    return c == null ? null : Hop.fromCert(r, c, delayMs: delayMs);
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
    final live = keyring.lookup(Sphinx.keyIdOf(packet));
    if (live == null) {
      stats.packetsRejected++; // unknown or retired onion key
      return;
    }
    final (onionKey, replay) = live;
    final p = await Sphinx.peel(onionKey, packet, replay);
    if (p == null) {
      stats.packetsRejected++;
      return;
    }
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

  /// Delays of 300 ms or more (paranoid mode) are rounded up to 100 ms
  /// boundaries so packets leave in batches; delays are capped to keep
  /// delivery within budget.
  static Duration _holdTime(int ms) {
    final capped = min(ms, 2000);
    if (capped < 300) return Duration(milliseconds: capped);
    final now = DateTime.now().millisecondsSinceEpoch;
    final due = now + capped;
    return Duration(milliseconds: (due ~/ 100 + 1) * 100 - now);
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
            unawaited(_notifyWatch(c.mailboxId, c.blob));
          }
        case Cmd.fetch:
          if (!_relayEnabled) return;
          stats.fetchesServed++;
          final c = FetchCmd.decode(r);
          await _serveFetch(c);
        case Cmd.watch:
          if (!_relayEnabled) return;
          final c = WatchCmd.decode(r);
          // Serve what is already waiting, keep the remaining SURBs.
          final now = DateTime.now();
          final (all, _) = store.fetch(c.mailboxIds, tokensPerCredential);
          final blobs = all.where((b) => _watchSendable(b, now)).take(c.surbs.length);
          final surbs = List.of(c.surbs);
          for (final b in blobs) {
            b.watchSentAt = now;
            stats.watchesServed++;
            await _reply(surbs.removeAt(0), ReplyMsg(Reply.blob, last: false, mailboxId: b.mailboxId, blob: b.blob));
          }
          if (surbs.isNotEmpty) _addWatch(WatchCmd(c.ttl, surbs, c.mailboxIds));
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
          final nodes = dht.closest(target);
          await _reply(
            surb,
            ReplyMsg(
              Reply.nodes,
              nodes: nodes,
              certs: [for (final n in nodes) ...certs.of(n.nodePk)].take(ReplyMsg.maxNodeCerts).toList(),
            ),
          );
        case Cmd.handoff:
          if (!_relayEnabled) return;
          final c = HandoffCmd.decode(r);
          final maxExp = DateTime.now().add(relayTtl);
          if (store.store(
            mailboxId: c.mailboxId,
            blob: c.blob,
            deleteTag: c.deleteTag,
            slot: 0xffff,
            pool: BlobPool.handoff,
            expiresAt: c.expiresAt.isAfter(maxExp) ? maxExp : c.expiresAt,
          )) {
            unawaited(_notifyWatch(c.mailboxId, c.blob));
          }
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
      certs: msg.certs,
    );
    try {
      await sendPacket(surb.firstHop, surb.packetWith(withPartners.encode()));
    } catch (e) {
      _log('reply failed: $e');
    }
  }

  // --- Client ----------------------------------------------------------

  bool get hasEntry => _entryLink != null && !_entryLink!.isClosed;

  /// Forgets the entry relay so the next [ensureEntry] picks a better one.
  /// The connection itself stays (it may carry other traffic).
  void dropEntry() {
    if (_entryLink == null) return;
    _entryLink = null;
    entry = null;
    onEntryChanged?.call();
  }

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
        onEntryChanged?.call();
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
    for (final w in _watches.where((w) => w.expires.isBefore(now)).toList()) {
      _dropWatch(w);
    }
    _surbs.removeWhere((_, p) => p.expires.isBefore(now));
    store.expire();
    unawaited(keyring.maintain());
    certs.prune();
    for (final e in _out.entries.toList()) {
      e.value.then((l) {
        if (identical(l, _entryLink)) return;
        if (now.difference(l.lastActivity) > const Duration(minutes: 2)) {
          _idleClosed.add(l);
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
