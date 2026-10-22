import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random, min, pow;
import 'dart:math' as math show log;
import 'dart:typed_data';

import 'address.dart';
import 'bytes.dart';
import 'constants.dart';
import 'crypto.dart';
import 'envelope.dart';
import 'messages.dart';
import 'models.dart';
import 'node.dart';
import 'onion.dart';
import 'pairing.dart';
import 'peers.dart';
import 'protocol.dart';
import 'ratchet.dart';
import 'sphinx.dart';
import 'tokens.dart';

/// Timing knobs. Production defaults; tests shrink them.
class Timings {
  /// Mean time between mailbox polls while the app is in the foreground.
  final Duration poll;

  /// Mean time between polls in the background.
  final Duration pollBackground;
  final Duration tick;
  final Duration hello;
  final Duration request;
  final Duration retry;
  final Duration discovery;
  final Duration update;
  final Duration announce;
  final Duration coverLowMean;
  final Duration coverConstant;

  const Timings({
    this.poll = const Duration(seconds: 5),
    this.pollBackground = const Duration(seconds: 30),
    this.tick = const Duration(seconds: 5),
    this.hello = const Duration(seconds: 45),
    this.request = const Duration(seconds: 8),
    this.retry = const Duration(seconds: 90),
    this.discovery = const Duration(minutes: 3),
    this.update = const Duration(hours: 12),
    this.announce = const Duration(minutes: 30),
    this.coverLowMean = const Duration(seconds: 30),
    this.coverConstant = const Duration(seconds: 2),
  });
}

/// A pairing in progress: our half of the QR exchange.
class PairingSession {
  final KeyPair25519 eph;
  final Uint8List seed;
  final int slot;
  final String code;
  PairingSession(this.eph, this.seed, this.slot, this.code);
}

class NetworkStatus {
  final int activePeers;
  final int knownPeers;
  final int hops;
  final bool lowDiversity;
  final bool relayRunning;
  final bool relayReachable;
  final int mailboxRelays;
  final int storedBlobs;
  final int storedBytes;
  final int dhtSize;
  final RelayInfo? entry;

  NetworkStatus({
    required this.activePeers,
    required this.knownPeers,
    required this.hops,
    required this.lowDiversity,
    required this.relayRunning,
    required this.relayReachable,
    required this.mailboxRelays,
    required this.storedBlobs,
    required this.storedBytes,
    required this.dhtSize,
    required this.entry,
  });

  /// Fewer peers than hops: messages go out with a shorter path.
  bool get tooFewPeers => activePeers < hops - 1;
}

/// The messenger: contacts, pairing, the handshake, sending with three
/// copies, fetching, dedup, receipts, retries, peer discovery and cover
/// traffic. Owns one [Node].
class Messenger {
  final Identity identity;
  final Settings settings;
  final Timings timings;
  final Node node;
  final PeerManager peers = PeerManager();
  final Map<String, Contact> contacts = {};
  final List<OutItem> outbox = [];
  final Map<String, SeenEntry> seen = {};
  final List<Credential> held = [];
  final Map<String, MailboxRecord> mailboxes = {};
  int nextSlot = 1;

  final _changes = StreamController<void>.broadcast();
  final _log = <String>[];
  final List<Timer> _timers = [];
  final Random _rng = Random.secure();
  final Map<String, List<Uint8List>> _pendingReceipts = {};
  final List<(RelayInfo, Uint8List)> _txQueue = [];
  Future<void> _lock = Future.value();
  bool _started = false;
  DateTime _lastDiscovery = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastAnnounce = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _coverTimer;
  Timer? _saveTimer;

  /// Persist hook, called (debounced) whenever state changes.
  Future<void> Function(Map<String, dynamic> state)? onSave;

  /// Mirrors every log line (e.g. to logcat or stdout).
  void Function(String line)? onLogLine;

  /// A text message arrived.
  void Function(Contact c, Message m)? onIncoming;

  Messenger({
    required this.identity,
    required this.settings,
    this.timings = const Timings(),
    InternetAddress? bindAddress,
    bool advertiseLoopback = false,
  }) : node = Node(
         identity: identity.node,
         relaySecret: identity.relaySecret,
         port: settings.port,
         bindAddress: bindAddress,
         advertiseLoopback: advertiseLoopback,
       ) {
    peers.selfPk = identity.node.pub;
    peers.allowLoopback = bindAddress?.isLoopback ?? false;
    node.onLinkResult = (r, ok) => ok ? peers.markOk(r) : peers.markFail(r);
    node.handoffPartners = _handoffPartners;
    node.onAnnounce = (r) {};
    node.onStored = _onLocalStore;
    node.onCerts = _onCerts;
    node.onLog = log;
  }

  Stream<void> get changes => _changes.stream;
  List<String> get logLines => List.unmodifiable(_log);

  void log(String m) {
    final line = '${DateTime.now().toIso8601String().substring(11, 19)} $m';
    _log.add(line);
    onLogLine?.call(line);
    if (_log.length > 300) _log.removeAt(0);
  }

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), save);
  }

  Future<void> save() async {
    _saveTimer?.cancel();
    await onSave?.call(toJson());
  }

  static const _lockKey = #zeltMessengerLock;

  /// Serialises ratchet and receive state changes. Reentrant: code already
  /// holding the lock runs directly.
  Future<T> _locked<T>(Future<T> Function() f) {
    if (Zone.current[_lockKey] == this) return f();
    final c = Completer<T>();
    _lock = _lock.then((_) async {
      try {
        c.complete(await runZoned(f, zoneValues: {_lockKey: this}));
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  // --- Persistence -----------------------------------------------------

  Map<String, dynamic> toJson() => {
    'v': 1,
    'identity': identity.toJson(),
    'settings': settings.toJson(),
    'contacts': [for (final c in contacts.values) c.toJson()],
    'outbox': [for (final o in outbox) o.toJson()],
    'seen': {for (final e in seen.entries) e.key: e.value.toJson()},
    'held': [for (final h in held) h.toJson()],
    'mailboxes': [for (final m in mailboxes.values) m.toJson()],
    'nextSlot': nextSlot,
    'advertised': _advertised.toList(),
    'certs': node.certs.toJson(),
    'peers': peers.toJson(),
  };

  /// Restores a saved messenger (migrating older saved formats).
  static Future<Messenger> load(
    Map<String, dynamic> j, {
    Timings timings = const Timings(),
    InternetAddress? bindAddress,
    bool advertiseLoopback = false,
  }) async {
    final copy = Map<String, dynamic>.of(j);
    copy['identity'] = (await Identity.load(j['identity'])).toJson();
    return fromJson(copy, timings: timings, bindAddress: bindAddress, advertiseLoopback: advertiseLoopback);
  }

  /// Restores a messenger saved in the current format.
  static Messenger fromJson(
    Map<String, dynamic> j, {
    Timings timings = const Timings(),
    InternetAddress? bindAddress,
    bool advertiseLoopback = false,
  }) {
    final m = Messenger(
      identity: Identity(
        KeyPair25519.fromJson(j['identity']['id']),
        SigningKey.fromJson(j['identity']['relayId']),
        unb64(j['identity']['rs']),
      ),
      settings: Settings.fromJson(j['settings']),
      timings: timings,
      bindAddress: bindAddress,
      advertiseLoopback: advertiseLoopback,
    );
    for (final c in j['contacts'] ?? []) {
      final contact = Contact.fromJson(c);
      m.contacts[contact.id] = contact;
    }
    m.outbox.addAll([for (final o in j['outbox'] ?? []) OutItem.fromJson(o)]);
    for (final e in (j['seen'] as Map<String, dynamic>? ?? {}).entries) {
      m.seen[e.key] = SeenEntry.fromJson(e.value);
    }
    m.held.addAll([for (final h in j['held'] ?? []) Credential.fromJson(h)]);
    for (final r in j['mailboxes'] ?? []) {
      final rec = MailboxRecord.fromJson(r);
      m.mailboxes[rec.relay.id] = rec;
    }
    m.nextSlot = j['nextSlot'] ?? 1;
    m._advertised = {...(j['advertised'] as List? ?? []).cast<String>()};
    m.node.certs.loadJson(j['certs'] as List? ?? []);
    if (j['peers'] != null) m.peers.loadJson(j['peers']);
    return m;
  }

  // --- Lifecycle -------------------------------------------------------

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await node.start(relay: settings.relay);
    peers.refresh(minRequired: settings.hops);
    await _refreshMailboxes();
    _schedulePoll();
    _timers.add(Timer.periodic(timings.tick, (_) => _maintenance()));
    _setupCover();
    unawaited(_maintenance());
    unawaited(pollNow());
  }

  /// Clean shutdown: hands stored relay blobs to partners, then stops.
  Future<void> stop({bool handoff = true}) async {
    if (!_started) return;
    _started = false;
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    _coverTimer?.cancel();
    _pollTimer?.cancel();
    if (handoff) await _handoff();
    await node.stop();
    await save();
  }

  Future<void> dispose() async {
    await stop(handoff: false);
    await _changes.close();
  }

  Future<void> applySettings() async {
    settings.hops = settings.hops.clamp(minHops, maxHops);
    if (node.relayEnabled != settings.relay) {
      if (!settings.relay) await _handoff();
      await node.setRelay(settings.relay);
      await _refreshMailboxes(force: true);
    }
    _setupCover();
    _changed();
  }

  NetworkStatus get status => NetworkStatus(
    activePeers: peers.active.length,
    knownPeers: peers.known.length,
    hops: settings.hops,
    lowDiversity: peers.lowDiversity,
    relayRunning: node.relayRunning,
    relayReachable: _relayReachable,
    mailboxRelays: _currentMailboxes().length,
    storedBlobs: node.store.count,
    storedBytes: node.store.totalBytes,
    dhtSize: node.dht.size,
    entry: node.entry,
  );

  bool get _relayReachable {
    final t = node.stats.lastInbound;
    return node.relayRunning && t != null && DateTime.now().difference(t) < const Duration(days: 1);
  }

  Future<List<RelayInfo>> myRelayInfos() => node.localRelayInfos();

  void addManualPeer(RelayInfo r) {
    peers.add(r, 'manual');
    peers.refresh(minRequired: settings.hops);
    _changed();
    unawaited(_maintenance());
  }

  // --- Pairing ---------------------------------------------------------

  Future<PairingSession> newPairingSession() async {
    final eph = await Crypto.x25519Generate();
    final seed = randomBytes(32);
    final relays = (await node.localRelayInfos()).take(3).toList();
    int? slot;
    Credential? cred;
    if (relays.isNotEmpty) {
      slot = nextSlot++;
      cred = await node.issuer.issue(relays.first, slot);
    }
    final grants = <Credential>[];
    for (final rec in _currentMailboxes().where((m) => !m.own).take(2)) {
      final g = _bestHeld(rec.relay.nodePk)?.carve(64);
      if (g != null) grants.add(g);
    }
    final code = PairingCode(
      idPub: identity.id.pub,
      ephPub: eph.pub,
      seed: seed,
      name: settings.name,
      relays: relays,
      credSlot: cred?.slot,
      credEpoch: cred?.epoch,
      credKey: cred?.key,
      grants: grants,
    ).encode();
    _changed();
    return PairingSession(eph, seed, slot ?? 0, code);
  }

  /// Called after scanning the friend's code. Our own code must have been
  /// (or still be) shown to them from the same [session].
  Future<Contact> completePairing(PairingSession session, String scanned, {String? name}) async {
    final theirs = PairingCode.parse(scanned);
    final keys = await ConversationKeys.derive(
      myId: identity.id,
      myEph: session.eph,
      mySeed: session.seed,
      theirs: theirs,
    );
    final id = hex(theirs.idPub);
    final old = contacts[id];
    if (old != null) peers.removeSource(id);
    final c = Contact(
      id: id,
      name: (name?.trim().isNotEmpty ?? false)
          ? name!.trim()
          : (theirs.name.isNotEmpty ? theirs.name : 'Friend ${id.substring(0, 6)}'),
      idPub: theirs.idPub,
      keys: keys,
      myEph: session.eph,
      theirEph: theirs.ephPub,
      slot: session.slot,
      messages: old?.messages,
    );
    if (keys.initiator) {
      final kem = await Crypto.kemGenerate();
      c.kemPk = kem.pk;
      c.kemSk = kem.sk;
    }
    outbox.removeWhere((o) => o.contactId == id);
    contacts[id] = c;

    for (final r in theirs.relays) {
      peers.add(r, id);
    }
    c.theirRelays = theirs.relays;
    if (theirs.credKey != null && theirs.relays.isNotEmpty) {
      final r0 = theirs.relays.first;
      const half = tokensPerCredential ~/ 2;
      c.theirMailboxes.add(
        Credential(r0, theirs.credSlot!, theirs.credEpoch!, theirs.credKey!, next: 0, end: half),
      );
      _addHeld(Credential(r0, theirs.credSlot!, theirs.credEpoch!, theirs.credKey!, next: half));
    }
    // Mailbox grants are last hops only; they never enter our own routing,
    // so a contact cannot hand us their friends' relays as peers.
    c.theirMailboxes.addAll(theirs.grants.where((g) => _usableAddr(g.relay)));
    peers.refresh(minRequired: settings.hops);
    // Their relays push onion-key certificates when we connect.
    for (final r in theirs.relays) {
      unawaited(node.ping(r));
    }
    log('paired with ${c.name} (${keys.initiator ? 'initiator' : 'responder'})');
    await _refreshMailboxes();
    _changed();
    unawaited(_handshakeTick(c, force: true));
    return c;
  }

  void deleteContact(String id) {
    contacts.remove(id);
    outbox.removeWhere((o) => o.contactId == id);
    peers.removeSource(id);
    _changed();
  }

  void renameContact(String id, String name) {
    contacts[id]?.name = name;
    _changed();
  }

  void setVerified(String id, bool v) {
    contacts[id]?.verified = v;
    _changed();
  }

  void markRead(String id) {
    final c = contacts[id];
    if (c == null || c.unread == 0) return;
    c.unread = 0;
    _changed();
  }

  // --- Handshake -------------------------------------------------------

  /// A relay address from another device that could possibly work here.
  bool _usableAddr(RelayInfo r) =>
      peers.allowLoopback || !(r.addr.ip.isLoopback || r.addr.ip.isLinkLocal);

  Uint8List _ad(Contact c) =>
      c.keys.initiator ? concat([identity.id.pub, c.idPub]) : concat([c.idPub, identity.id.pub]);

  bool _needsHello(Contact c) => !c.ready || (!c.keys.initiator && !c.peerConfirmed);

  Future<void> _handshakeTick(Contact c, {bool force = false}) async {
    if (!_needsHello(c)) return;
    if (c.theirMailboxes.isEmpty) return;
    final last = c.lastHelloSent;
    if (!force && last != null && DateTime.now().difference(last) < timings.hello) return;
    c.lastHelloSent = DateTime.now();
    final hello = Hello(
      kemPk: c.keys.initiator && !c.ready ? c.kemPk : null,
      kemCt: !c.keys.initiator ? c.kemCt : null,
      info: await _addressInfoFor(c),
    );
    final blob = await Envelope.seal(c.keys.envOut, Envelope.kindHandshake, hello.encode());
    final item = OutItem(
      id: hex(randomBytes(16)),
      contactId: c.id,
      handshake: true,
      needsReceipt: false,
      blob: blob,
      hash: await Crypto.sha256(blob),
    );
    await _dispatch(item);
    _changed();
  }

  Future<void> _onHello(Contact c, Hello h) async {
    await _applyInfo(c, h.info);
    if (h.kemPk != null && !c.keys.initiator) {
      if (!c.ready) {
        final (ct, ss) = await Crypto.kemEncapsulate(h.kemPk!);
        final root = await hybridRoot(c.keys.rk0, ss);
        c.ratchet = await Ratchet.bob(root, c.myEph);
        c.kemCt = ct;
        log('handshake done with ${c.name} (responder)');
        await _flushPending(c);
      }
      if (!c.peerConfirmed) await _handshakeTick(c, force: true);
    }
    if (h.kemCt != null && c.keys.initiator && !c.ready && c.kemSk != null) {
      final ss = await Crypto.kemDecapsulate(c.kemSk!, h.kemCt!);
      final root = await hybridRoot(c.keys.rk0, ss);
      c.ratchet = await Ratchet.alice(root, c.theirEph);
      c.kemSk = null;
      log('handshake done with ${c.name} (initiator)');
      // Confirms the handshake to the responder.
      await _sendControl(c, MsgType.update);
      await _flushPending(c);
    }
    if (c.keys.initiator && !c.ready) await _handshakeTick(c);
    _changed();
  }

  Future<void> _flushPending(Contact c) async {
    for (final o in outbox.where((o) => o.contactId == c.id && o.pending != null).toList()) {
      await _seal(c, o);
      o.nextTry = DateTime.now();
    }
    unawaited(_retryDue());
  }

  // --- Address info ----------------------------------------------------

  Credential? _bestHeld(Uint8List nodePk) {
    final now = DateTime.now();
    Credential? best;
    for (final h in held) {
      if (!bytesEqual(h.relay.nodePk, nodePk) || !h.usable(now)) continue;
      if (best == null || h.remaining > best.remaining) best = h;
    }
    return best;
  }

  void _addHeld(Credential c) {
    final dup = held.any(
      (h) => bytesEqual(h.relay.nodePk, c.relay.nodePk) &&
          h.slot == c.slot &&
          h.epoch == c.epoch &&
          h.end == c.end,
    );
    if (!dup) held.add(c);
    final now = DateTime.now();
    held.removeWhere((h) => !h.isValidAt(now) || h.remaining <= 0);
  }

  Future<AddressInfo> _addressInfoFor(Contact c) async {
    final relays = (await node.localRelayInfos()).take(3).toList();
    final mbox = <Credential>[];
    final creds = <Credential>[];
    const half = tokensPerCredential ~/ 2;
    if (relays.isNotEmpty) {
      if (c.slot == 0) c.slot = nextSlot++;
      final k = await node.issuer.issue(relays.first, c.slot);
      creds.add(Credential(k.relay, k.slot, k.epoch, k.key, next: half));
    }
    for (final rec in _currentMailboxes()) {
      if (rec.own) {
        if (relays.isEmpty) continue;
        final k = await node.issuer.issue(relays.first, c.slot);
        mbox.add(Credential(k.relay, k.slot, k.epoch, k.key, next: 0, end: half));
      } else {
        final g = _bestHeld(rec.relay.nodePk)?.carve(128);
        if (g != null) mbox.add(g);
      }
    }
    final known = settings.shareRelays
        ? peers
              .shareable(AddressInfo.maxKnown)
              .where((r) => !c.theirRelays.any((t) => bytesEqual(t.nodePk, r.nodePk)))
              .toList()
        : <RelayInfo>[];
    // Certificates: ours first, then the mailbox relays, then known relays.
    final certs = <OnionKeyCert>[
      ...node.keyring.certs,
      for (final g in mbox) if (!node.isSelf(g.relay)) ...node.certs.of(g.relay.nodePk),
      for (final r in known) ...node.certs.of(r.nodePk),
    ];
    _sentRelaySig[c.id] = await _relaySig();
    return AddressInfo(
      relays: relays,
      mailboxes: mbox,
      relayCreds: creds,
      known: known,
      certs: certs.take(AddressInfo.maxCerts).toList(),
    );
  }

  Future<void> _applyInfo(Contact c, AddressInfo info) async {
    if (info.relays.isNotEmpty) c.theirRelays = info.relays;
    for (final r in info.relays) {
      peers.add(r, c.id);
    }
    for (final r in info.known) {
      if (!node.isSelf(r)) peers.add(r, 'via:${c.id}');
    }
    await node.addCerts(info.certs);
    for (final g in info.mailboxes) {
      if (!_usableAddr(g.relay)) continue;
      final dup = c.theirMailboxes.any(
        (x) => bytesEqual(x.relay.nodePk, g.relay.nodePk) &&
            x.slot == g.slot &&
            x.epoch == g.epoch &&
            x.end == g.end,
      );
      if (!dup) c.theirMailboxes.add(g);
    }
    final now = DateTime.now();
    c.theirMailboxes.removeWhere((g) => !g.isValidAt(now) || g.remaining <= 0);
    for (final k in info.relayCreds) {
      _addHeld(k);
    }
    peers.refresh(minRequired: settings.hops);
    await _refreshMailboxes();
  }

  /// The mailbox relays we currently advertise (node key ids). Older ones
  /// stay in [mailboxes] and keep being polled until their blobs expire.
  Set<String> _advertised = {};
  String? _advertisedAddrs;

  List<MailboxRecord> _currentMailboxes() =>
      [for (final id in _advertised) if (mailboxes[id] != null) mailboxes[id]!];

  bool _refreshing = false;
  String? _lastOwnAddrs;

  /// Chooses our mailbox relays: our own relay if it is reachable, relays we
  /// hold tokens for, and public tokens from peers if we have too few.
  Future<void> _refreshMailboxes({bool force = false}) async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final now = DateTime.now();
      final chosen = <String, MailboxRecord>{};
      final own = await node.localRelayInfos();
      final others = <Credential>[];
      // 2: reachability is per network; forget it when our addresses change.
      final addrKey = own.map((r) => r.addr.toString()).join(',');
      if (_lastOwnAddrs != null && _lastOwnAddrs != addrKey) {
        node.stats.lastInbound = null;
        log('network changed: $addrKey');
      }
      _lastOwnAddrs = addrKey;
      for (final h in held) {
        if (!h.usable(now) || node.isSelf(h.relay)) continue;
        final ip = h.relay.addr.ip;
        if (!peers.allowLoopback && (ip.isLoopback || ip.isLinkLocal)) continue;
        final rec = peers.known.values.where((p) => bytesEqual(p.relay.nodePk, h.relay.nodePk));
        if (rec.isNotEmpty && !rec.any((p) => p.healthy)) continue;
        if (others.any((o) => bytesEqual(o.relay.nodePk, h.relay.nodePk))) continue;
        others.add(h);
      }
      if (own.isNotEmpty && (_relayReachable || others.length < copiesPerMessage)) {
        chosen[own.first.id] = (mailboxes[own.first.id] ?? MailboxRecord(own.first, own: true))
          ..relay = own.first;
      }
      for (final h in others) {
        if (chosen.length >= maxMailboxRelays) break;
        final r = peers.resolve(h.relay.nodePk) ?? h.relay;
        chosen[r.id] = (mailboxes[r.id] ?? MailboxRecord(r))..relay = r;
      }

      final before = _advertised;
      final after = chosen.keys.toSet();
      final addrs = chosen.values.map((m) => m.relay.key).join(',');
      final addrsChanged = addrs != _advertisedAddrs;
      _advertisedAddrs = addrs;
      _advertised = after;
      for (final rec in chosen.values) {
        rec.lastAdvertised = now;
        mailboxes[rec.relay.id] = rec;
      }
      if (!peers.allowLoopback) {
        mailboxes.removeWhere((_, m) => !m.own && (m.relay.addr.ip.isLoopback || m.relay.addr.ip.isLinkLocal));
      }
      // Keep polling old mailboxes for the TTL, then forget them.
      mailboxes.removeWhere(
        (_, m) => now.difference(m.lastAdvertised) > relayTtl + const Duration(days: 1),
      );
      final changed = force || addrsChanged || before.length != after.length || !before.containsAll(after);
      if (changed) {
        log('mailbox relays: ${chosen.values.map((m) => m.relay).join(', ')}');
        for (final c in contacts.values) {
          if (c.ready) {
            unawaited(_sendControl(c, MsgType.update));
          } else {
            unawaited(_handshakeTick(c, force: true));
          }
        }
        _changed();
      }
      if (chosen.length < copiesPerMessage) unawaited(_requestPublicCreds(copiesPerMessage - chosen.length));
    } finally {
      _refreshing = false;
    }
  }

  DateTime _lastPublicReq = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _requestPublicCreds(int n) async {
    if (DateTime.now().difference(_lastPublicReq) < timings.hello) return;
    _lastPublicReq = DateTime.now();
    final have = {for (final h in held) h.relay.id};
    final targets = peers.activeRelays.where((r) => !have.contains(r.id)).take(n).toList();
    var got = false;
    for (final t in targets) {
      final replies = await _request(t, 1, (s) => surbCmd(Cmd.tokenReq, s.first));
      for (final r in replies) {
        final c = r.credential;
        if (r.type == Reply.credential && c != null && bytesEqual(c.relay.nodePk, t.nodePk)) {
          _addHeld(Credential(t, c.slot, c.epoch, c.key, next: c.next, end: c.end));
          got = true;
        }
      }
    }
    log('public tokens: ${got ? 'received' : 'none'} from ${targets.map((t) => t.addr).join(', ')}');
    if (got) {
      _changed();
      await _refreshMailboxes();
    }
  }

  // --- Sending ---------------------------------------------------------

  /// Queues a text message. Returns the stored [Message].
  Future<Message> sendText(String contactId, String text) async {
    final c = contacts[contactId];
    if (c == null) throw StateError('unknown contact');
    if (utf8.encode(text).length > maxTextBytes) throw ArgumentError('message too long');
    final id = randomBytes(16);
    final now = DateTime.now();
    final m = Message(id: hex(id), outgoing: true, text: text, time: now);
    c.messages.add(m);
    final chat = ChatMsg(MsgType.text, id, timestamp: now.millisecondsSinceEpoch, text: text);
    final item = OutItem(id: hex(id), contactId: c.id, pending: chat.encode());
    outbox.add(item);
    _changed();
    if (c.ready) {
      await _seal(c, item);
      await _dispatch(item);
    }
    return m;
  }

  Future<void> _sendControl(Contact c, MsgType type, {List<Uint8List> receipts = const []}) async {
    final id = randomBytes(16);
    final chat = switch (type) {
      MsgType.update => ChatMsg(type, id, info: await _addressInfoFor(c)),
      MsgType.receipt => ChatMsg(type, id, receiptFor: receipts),
      _ => ChatMsg(type, id),
    };
    if (type == MsgType.update) {
      c.lastUpdateSent = DateTime.now();
      c.receivedSinceUpdate = 0;
    }
    final item = OutItem(
      id: hex(id),
      contactId: c.id,
      pending: chat.encode(),
      needsReceipt: type != MsgType.receipt,
    );
    if (item.needsReceipt) outbox.add(item);
    if (!c.ready) return;
    await _seal(c, item);
    await _dispatch(item);
    _changed();
  }

  Future<void> _seal(Contact c, OutItem o) => _locked(() async {
    if (o.pending == null || c.ratchet == null) return;
    final ct = await c.ratchet!.encrypt(o.pending!, ad: _ad(c));
    o.blob = await Envelope.seal(c.keys.envOut, Envelope.kindRatchet, ct);
    o.hash = await Crypto.sha256(o.blob!);
    o.pending = null;
    _changed();
  });

  Duration _retryWindow() => switch (settings.delay) {
    DelayMode.fast => timings.retry * 0.7,
    DelayMode.normal => timings.retry,
    DelayMode.paranoid => timings.retry * 3,
  };

  /// Sends up to three byte-identical copies to three different mailbox
  /// relays of the recipient, each over its own onion path.
  Future<int> _dispatch(OutItem o) async {
    final c = contacts[o.contactId];
    if (c == null || o.blob == null) return 0;
    final now = DateTime.now();
    final prev = {for (final cp in o.copies) cp.relay.id};
    final byNode = <String, Credential>{};
    for (final g in c.theirMailboxes) {
      if (!g.usable(now)) continue;
      final k = hex(g.relay.nodePk);
      if (!byNode.containsKey(k) || g.remaining > byNode[k]!.remaining) byNode[k] = g;
    }
    final grants = byNode.values.toList()..shuffle(_rng);
    // Prefer relays we did not use last time, then healthy ones.
    grants.sort((a, b) {
      final pa = prev.contains(hex(a.relay.nodePk)) ? 1 : 0;
      final pb = prev.contains(hex(b.relay.nodePk)) ? 1 : 0;
      return pa - pb;
    });

    final mailboxId = await Envelope.mailboxId(c.keys.mboxOut, mailboxEpochOf(now));
    final deleteKey = await Envelope.deleteKey(c.keys.delOut, o.hash!);
    final deleteTag = await Envelope.deleteTag(deleteKey);
    var sent = 0;
    final copies = <Copy>[];
    for (final g in grants) {
      if (sent >= copiesPerMessage) break;
      final relay = node.isSelf(g.relay) ? g.relay : (peers.resolve(g.relay.nodePk) ?? g.relay);
      final token = await g.take(o.hash!);
      final cmd = StoreCmd(mailboxId, token, deleteTag, o.blob!);
      final ok = await _sendOnion(relay, cmd.encode());
      if (ok) {
        sent++;
        copies.add(Copy(relay, mailboxId));
      }
    }
    o.attempts++;
    o.copies.addAll(copies);
    o.nextTry = now.add(_retryWindow() * pow(2, min(o.attempts - 1, 5)).toDouble());
    log('${o.handshake ? 'hello' : 'message'} to ${c.name}: $sent/${grants.length} copies stored'
        '${copies.isEmpty ? '' : ' (${copies.map((x) => x.relay.addr).join(', ')})'}');
    if (sent > 0) {
      final m = c.messages.where((m) => m.id == o.id).firstOrNull;
      if (m != null && m.status == MsgStatus.queued) m.status = MsgStatus.sent;
    } else {
      log('no usable mailbox relay for ${c.name}');
      if (c.ready && c.tokensLeft(now) == 0) _maybeRequestUpdate(c);
    }
    _changed();
    return sent;
  }

  void _maybeRequestUpdate(Contact c) {
    final last = c.lastUpdateRequest;
    if (last != null && DateTime.now().difference(last) < const Duration(minutes: 10)) return;
    c.lastUpdateRequest = DateTime.now();
    unawaited(_sendControl(c, MsgType.updateRequest));
  }

  int _hopDelay() => switch (settings.delay) {
    DelayMode.fast => _rng.nextInt(20),
    DelayMode.normal => 100 + _rng.nextInt(401),
    DelayMode.paranoid => 1000 + _rng.nextInt(4001),
  };

  int get _maxHopDelay => switch (settings.delay) {
    DelayMode.fast => 20,
    DelayMode.normal => 500,
    DelayMode.paranoid => 6000,
  };

  bool _hasKey(RelayInfo r) => node.hopFor(r) != null;

  /// Middle hops are fresh random peers for every packet; [last] is the
  /// destination relay. Only relays with a valid onion-key certificate can
  /// be hops; null if [last] has none.
  List<Hop>? _route(RelayInfo last, {Iterable<Uint8List> exclude = const []}) {
    final end = node.hopFor(last, delayMs: _hopDelay());
    if (end == null) return null;
    final mids = peers.pick(
      settings.hops - 1,
      exclude: [last.nodePk, identity.node.pub, ...exclude],
      usable: _hasKey,
    );
    return [
      for (final m in mids) node.hopFor(m, delayMs: _hopDelay())!,
      end,
    ];
  }

  /// Sends [payload] to [last] over an onion path. If the first hop does not
  /// answer, the route is rebuilt with other peers.
  Future<bool> _sendOnion(RelayInfo last, Uint8List payload, {List<RelayInfo>? used}) async {
    if (node.isSelf(last)) {
      // Our own relay: nobody to hide from, deliver locally. The relay may stop
      // while the packet is being built, so this can fail like any send.
      if (!node.relayRunning) return false;
      try {
        final hop = node.hopFor(last);
        if (hop == null) return false;
        await node.sendPacket(last, await Sphinx.forward([hop], payload));
        return true;
      } catch (_) {
        return false;
      }
    }
    final tried = <Uint8List>[];
    for (var attempt = 0; attempt < 3; attempt++) {
      final hops = _route(last, exclude: tried);
      if (hops == null) {
        log('no valid onion key for ${last.addr} yet');
        return false;
      }
      final pkt = await Sphinx.forward(hops, payload);
      try {
        await _transmit(hops.first.relay, pkt);
        used?.addAll(hops.map((h) => h.relay));
        return true;
      } catch (_) {
        tried.add(hops.first.relay.nodePk);
        if (hops.length == 1) return false;
      }
    }
    return false;
  }

  Future<void> _transmit(RelayInfo first, Uint8List pkt) async {
    if (settings.cover == CoverMode.constant) {
      _txQueue.add((first, pkt));
      return;
    }
    await node.sendPacket(first, pkt);
  }

  // --- Cover traffic ---------------------------------------------------

  void _setupCover() {
    _coverTimer?.cancel();
    _coverTimer = null;
    if (!_started) return;
    switch (settings.cover) {
      case CoverMode.off:
        _flushTxQueue();
      case CoverMode.low:
        _flushTxQueue();
        _scheduleLowCover();
      case CoverMode.constant:
        _coverTimer = Timer.periodic(timings.coverConstant, (_) => _coverTick());
    }
  }

  void _flushTxQueue() {
    for (final (r, p) in _txQueue) {
      node.sendPacket(r, p).ignore();
    }
    _txQueue.clear();
  }

  void _scheduleLowCover() {
    // Exponential gaps: dummies at random, memoryless times.
    final mean = timings.coverLowMean.inMilliseconds;
    final ms = (-math.log(1 - _rng.nextDouble()) * mean).round().clamp(500, mean * 5);
    _coverTimer = Timer(Duration(milliseconds: ms), () async {
      await _sendDummy();
      if (_started && settings.cover == CoverMode.low) _scheduleLowCover();
    });
  }

  /// Constant rate: each tick sends one real packet if one is queued,
  /// otherwise a dummy, so an observer sees the same rate either way.
  Future<void> _coverTick() async {
    if (_txQueue.isNotEmpty) {
      final (r, p) = _txQueue.removeAt(0);
      try {
        await node.sendPacket(r, p);
      } catch (_) {}
      return;
    }
    await _sendDummy();
  }

  Future<void> _sendDummy() async {
    final targets = peers.activeRelays.where(_hasKey).toList();
    if (targets.isEmpty) return;
    final last = targets[_rng.nextInt(targets.length)];
    final hops = _route(last);
    if (hops == null) return;
    try {
      await node.sendPacket(hops.first.relay, await Sphinx.forward(hops, dropCmd()));
    } catch (_) {}
  }

  // --- Requests over SURBs ---------------------------------------------

  Duration get _requestTimeout =>
      timings.request + Duration(milliseconds: settings.hops * 2 * _maxHopDelay + 1000);

  /// Sends a command to [target] carrying [nSurbs] reply blocks and collects
  /// replies until one is marked last, all SURBs are used, or timeout.
  Future<List<ReplyMsg>> _request(
    RelayInfo target,
    int nSurbs,
    Uint8List Function(List<Surb> surbs) build,
  ) async {
    final entryCands = peers.entryCandidates(exclude: [target.nodePk]);
    final entry = await node.ensureEntry([...entryCands, target]);
    if (entry == null) return [];
    final entryHop = node.hopFor(entry);
    if (entryHop == null) return [];
    final replies = <ReplyMsg>[];
    final done = Completer<void>();
    final surbs = <Surb>[];
    final used = <RelayInfo>[];
    for (var i = 0; i < nSurbs; i++) {
      final mids = peers.pick(settings.hops - 1, exclude: [target.nodePk, entry.nodePk], usable: _hasKey);
      final hops = [
        for (final m in mids) node.hopFor(m, delayMs: _hopDelay())!,
        node.hopFor(entry, delayMs: _hopDelay())!,
      ];
      used.addAll(hops.map((h) => h.relay));
      surbs.add(await node.makeSurb(hops, (r) {
        replies.add(r);
        if ((r.last || replies.length >= nSurbs) && !done.isCompleted) done.complete();
      }, ttl: _requestTimeout * 2));
    }
    final ok = await _sendOnion(target, build(surbs), used: used);
    if (!ok) return [];
    try {
      await done.future.timeout(_requestTimeout);
    } on TimeoutException {
      // Return whatever arrived.
    }
    if (replies.isEmpty) {
      // One of these relays may have restarted with new onion keys: have
      // maintenance re-confirm their keys directly.
      for (final r in used) {
        node.certs.confirmed.remove(r.id);
      }
    }
    return replies;
  }

  // --- Receiving -------------------------------------------------------

  DateTime _lastCertKick = DateTime.fromMillisecondsSinceEpoch(0);

  /// New onion keys can unblock pending handshakes and queued messages.
  void _onCerts() {
    if (!_started) return;
    final now = DateTime.now();
    if (now.difference(_lastCertKick) < const Duration(seconds: 2)) return;
    _lastCertKick = now;
    for (final c in contacts.values.where(_needsHello)) {
      unawaited(_handshakeTick(c, force: true));
    }
    unawaited(_retryDue());
    _changed();
  }

  /// A blob landed on our own relay. If it is for one of our mailboxes, take
  /// it right away instead of waiting for the next poll.
  Future<void> _onLocalStore(Uint8List mailboxId) async {
    if (!_started) return;
    final now = DateTime.now();
    for (final c in contacts.values) {
      for (final id in await Envelope.pollIds(c.keys.mboxIn, now)) {
        if (!bytesEqual(id, mailboxId)) continue;
        final rec = mailboxes.values.where((m) => m.own).firstOrNull ??
            MailboxRecord((await node.localRelayInfos()).first, own: true);
        await _pollRelay(rec, [id], {hex(id): c});
        return;
      }
    }
  }

  bool _foreground = true;
  Timer? _pollTimer;

  /// Foreground polls more often. The rate never depends on whether mail is
  /// waiting, so it reveals nothing about messages.
  void setForeground(bool fg) {
    if (fg == _foreground) return;
    _foreground = fg;
    if (fg) unawaited(pollNow());
    _schedulePoll();
  }

  /// Exponentially distributed gaps (a Poisson process): no fixed schedule an
  /// observer could lock onto.
  void _schedulePoll() {
    _pollTimer?.cancel();
    if (!_started) return;
    final mean = (_foreground ? timings.poll : timings.pollBackground).inMilliseconds;
    final ms = (-math.log(1 - _rng.nextDouble()) * mean).round().clamp(mean ~/ 10, mean * 4);
    _pollTimer = Timer(Duration(milliseconds: ms), () {
      unawaited(pollNow());
      _schedulePoll();
    });
  }

  /// Mailbox relays with a fetch in flight; each relay is polled on its own
  /// so a dead mailbox never holds up a working one.
  final Set<String> _pollingRelays = {};
  final Map<String, DateTime> _nextPoll = {};

  /// Fetches from every mailbox relay we advertised within the TTL.
  /// Mailboxes that do not answer are retried with exponential backoff.
  Future<void> pollNow() async {
    if (!_started) return;
    try {
      final idMap = <String, Contact>{};
      for (final c in contacts.values) {
        for (final id in await Envelope.pollIds(c.keys.mboxIn, DateTime.now())) {
          idMap[hex(id)] = c;
        }
      }
      if (idMap.isEmpty) return;
      final ids = [for (final k in idMap.keys) unhex(k)];
      final now = DateTime.now();
      for (final rec in mailboxes.values.toList()) {
        final k = rec.relay.id;
        if (_pollingRelays.contains(k)) continue;
        if (_nextPoll[k]?.isAfter(now) ?? false) continue;
        _pollingRelays.add(k);
        unawaited(_pollRelay(rec, ids, idMap).catchError((Object e) {
          log('poll ${rec.relay.addr} failed: $e');
        }).whenComplete(() {
          _pollingRelays.remove(k);
          final backoff = rec.failures == 0
              ? Duration.zero
              : timings.poll * (1 << min(rec.failures, 5));
          _nextPoll[k] = DateTime.now().add(backoff);
        }));
      }
    } catch (e) {
      log('poll failed: $e');
    }
  }

  Future<void> _pollRelay(MailboxRecord rec, List<Uint8List> ids, Map<String, Contact> idMap) async {
    if (rec.own || node.isSelf(rec.relay)) {
      if (!node.relayRunning) return;
      var more = true;
      while (more) {
        final (blobs, m) = node.fetchLocal(ids, 16);
        more = m;
        for (final b in blobs) {
          final del = await _receive(b.blob, b.mailboxId, idMap);
          if (del != null) node.store.delete(del.mailboxId, del.hash, del.deleteKey);
        }
        if (blobs.isEmpty) break;
      }
      return;
    }
    final targets = [rec.relay];
    var answered = false;
    // Index loop: partners get appended while we iterate.
    for (var t = 0; t < targets.length; t++) {
      final target = targets[t];
      for (final chunk in fetchBatches(ids)) {
        for (var round = 0; round < 5; round++) {
          final replies = await _request(target, fetchSurbs, (s) => FetchCmd(s, chunk).encode());
          if (replies.isEmpty) break;
          answered = true;
          final n = replies.where((r) => r.type == Reply.blob).length;
          if (n > 0) log('fetched $n from ${target.addr}');
          if (target == rec.relay) {
            final ps = replies.expand((r) => r.partners).toList();
            if (ps.isNotEmpty) rec.partners = ps;
          }
          final deletes = <DeleteEntry>[];
          for (final r in replies) {
            if (r.type != Reply.blob) continue;
            final del = await _receive(r.blob!, r.mailboxId!, idMap);
            if (del != null) deletes.add(del);
          }
          if (deletes.isNotEmpty) {
            unawaited(_sendOnion(target, DeleteCmd(deletes.take(DeleteCmd.maxEntries).toList()).encode()));
          }
          final last = replies.any((r) => r.last);
          if (last || replies.length < fetchSurbs) break;
        }
      }
      if (!answered && target == rec.relay && rec.partners.isNotEmpty) {
        // The relay is gone; it may have handed its blobs to its partners.
        targets.addAll(rec.partners.where((p) => !node.isSelf(p)));
      }
    }
    rec.failures = answered ? 0 : rec.failures + 1;
    if (!answered) log('mailbox ${rec.relay.addr} did not answer');
  }

  /// Handles one fetched blob. Returns the delete entry for the relay it
  /// came from, or null if it is not ours.
  Future<DeleteEntry?> _receive(Uint8List blob, Uint8List mailboxId, Map<String, Contact> idMap) =>
      _locked(() async {
        final c = idMap[hex(mailboxId)];
        if (c == null) return null;
        final hash = await Crypto.sha256(blob);
        final hk = hex(hash);
        final del = DeleteEntry(mailboxId, hash, await Envelope.deleteKey(c.keys.delIn, hash));

        // Dedup before decrypting: copies 2 and 3 end here.
        final s = seen[hk];
        if (s != null) {
          if (s.msgId != null &&
              (s.lastReceipt == null ||
                  DateTime.now().difference(s.lastReceipt!) > timings.hello)) {
            s.lastReceipt = DateTime.now();
            _queueReceipt(c, unhex(s.msgId!));
          }
          return del;
        }

        final opened = await Envelope.open(c.keys.envIn, blob);
        if (opened == null) return null;
        final (kind, content) = opened;
        // Sent from the responder's pre-chain before our half of the
        // handshake finished: leave it on the relay and fetch it again later.
        if (kind == Envelope.kindRatchet && c.ratchet == null) return null;
        String? msgId;
        if (kind == Envelope.kindHandshake) {
          try {
            await _onHello(c, Hello.decode(content));
          } catch (e) {
            log('bad hello from ${c.name}: $e');
          }
        } else if (kind == Envelope.kindRatchet) {
          try {
            final plain = await c.ratchet!.decrypt(content, ad: _ad(c));
            if (!c.keys.initiator && !c.peerConfirmed) {
              c.peerConfirmed = true;
              c.kemCt = null;
            }
            final msg = ChatMsg.decode(plain);
            msgId = hex(msg.id);
            await _onChat(c, msg);
          } catch (e) {
            // Replay caught by the ratchet counter, or garbage.
            log('ratchet rejected a message from ${c.name}');
          }
        }
        seen[hk] = SeenEntry(
          DateTime.now().add(relayTtl + const Duration(days: 1)),
          contactId: c.id,
          msgId: msgId,
          lastReceipt: msgId != null ? DateTime.now() : null,
        );
        _changed();
        return del;
      });

  Future<void> _onChat(Contact c, ChatMsg m) async {
    if (m.type != MsgType.receipt) {
      _queueReceipt(c, m.id);
      c.receivedSinceUpdate++;
    }
    switch (m.type) {
      case MsgType.text:
        final id = hex(m.id);
        if (c.messages.any((x) => x.id == id)) return;
        final msg = Message(
          id: id,
          outgoing: false,
          text: m.text,
          time: DateTime.now(),
          sentAt: DateTime.fromMillisecondsSinceEpoch(m.timestamp),
          status: MsgStatus.delivered,
        );
        c.messages.add(msg);
        c.unread++;
        onIncoming?.call(c, msg);
      case MsgType.receipt:
        for (final r in m.receiptFor) {
          await _onReceipt(c, hex(r));
        }
      case MsgType.update:
        await _applyInfo(c, m.info!);
      case MsgType.updateRequest:
        unawaited(_sendControl(c, MsgType.update));
    }
  }

  Future<void> _onReceipt(Contact c, String id) async {
    final i = outbox.indexWhere((o) => o.id == id && o.contactId == c.id);
    final msg = c.messages.where((m) => m.id == id).firstOrNull;
    if (msg != null) msg.status = MsgStatus.delivered;
    if (i < 0) return;
    final o = outbox.removeAt(i);
    // Ask the relays to drop the remaining copies early.
    final key = await Envelope.deleteKey(c.keys.delOut, o.hash!);
    final byRelay = <String, (RelayInfo, List<DeleteEntry>)>{};
    for (final cp in o.copies) {
      byRelay.putIfAbsent(cp.relay.key, () => (cp.relay, [])).$2.add(DeleteEntry(cp.mailboxId, o.hash!, key));
    }
    for (final (r, entries) in byRelay.values) {
      unawaited(_sendOnion(r, DeleteCmd(entries).encode()));
    }
  }

  void _queueReceipt(Contact c, Uint8List msgId) {
    final list = _pendingReceipts.putIfAbsent(c.id, () => []);
    list.add(msgId);
    if (list.length == 1) {
      Timer(const Duration(milliseconds: 300), () {
        final ids = _pendingReceipts.remove(c.id) ?? [];
        if (ids.isEmpty) return;
        for (var i = 0; i < ids.length; i += 200) {
          unawaited(_sendControl(c, MsgType.receipt, receipts: ids.sublist(i, min(i + 200, ids.length))));
        }
      });
    }
  }

  // --- Maintenance -----------------------------------------------------

  bool _maintaining = false;

  Future<void> _maintenance() async {
    if (_maintaining || !_started) return;
    _maintaining = true;
    try {
      final now = DateTime.now();
      peers.refresh(minRequired: settings.hops);
      if (now.difference(_lastDiscovery) > timings.discovery || peers.active.isEmpty) {
        _lastDiscovery = now;
        unawaited(_discover());
      }
      if (node.relayRunning && now.difference(_lastAnnounce) > timings.announce) {
        _lastAnnounce = now;
        unawaited(_announce());
      }
      await _refreshMailboxes();
      for (final c in contacts.values.toList()) {
        await _handshakeTick(c);
        if (!c.ready) continue;
        final lu = c.lastUpdateSent;
        if (lu == null || now.difference(lu) > timings.update || c.receivedSinceUpdate >= 40) {
          await _sendControl(c, MsgType.update);
        }
        if (c.tokensLeft(now) < 20) _maybeRequestUpdate(c);
      }
      await _retryDue();
      seen.removeWhere((_, s) => s.expires.isBefore(now));
      if (node.hasEntry == false && peers.active.isNotEmpty) {
        await node.ensureEntry(peers.entryCandidates());
      }
      // Nothing reachable: walk the whole relay history until one answers.
      if (peers.pick(1).isEmpty && peers.known.isNotEmpty) {
        for (final r in peers.lastResort(4)) {
          unawaited(node.ping(r));
        }
      }
      await _syncRelaysIfChanged();
      // Keep hop candidates verified: a ping is a real connection attempt
      // and updates peer health through onLinkResult.
      for (final r in peers.toProbe(4)) {
        unawaited(node.ping(r));
      }
      // Re-confirm onion keys of a couple of peers we have not heard from
      // directly for a while (catches relays that restarted unseen).
      final stale = peers.activeRelays.where((r) {
        final t = node.certs.confirmed[r.id];
        return t == null || now.difference(t) > const Duration(minutes: 10);
      }).toList()
        ..shuffle(_rng);
      for (final r in stale.take(2)) {
        unawaited(node.ping(r));
      }
    } catch (e) {
      log('maintenance: $e');
    } finally {
      _maintaining = false;
    }
  }

  Future<void> _retryDue() async {
    final now = DateTime.now();
    for (final o in outbox.toList()) {
      if (o.blob == null || o.nextTry.isAfter(now)) continue;
      if (!outbox.contains(o)) continue;
      await _dispatch(o);
    }
  }

  /// Per contact: the relay-list signature we last sent them.
  final Map<String, String> _sentRelaySig = {};
  final Map<String, DateTime> _lastRelaySync = {};

  Future<String> _relaySig() async {
    final own = await node.localRelayInfos();
    final shared = settings.shareRelays ? peers.shareable(AddressInfo.maxKnown) : <RelayInfo>[];
    return [...own.map((r) => r.key), '|', ...(shared.map((r) => r.key).toList()..sort())].join(',');
  }

  /// Sends an update to every friend whose copy of our relay list (own
  /// addresses plus relays we can reach) is out of date, at most once per
  /// [Timings.hello] per friend.
  Future<void> _syncRelaysIfChanged() async {
    final sig = await _relaySig();
    final now = DateTime.now();
    for (final c in contacts.values.where((c) => c.ready)) {
      if (_sentRelaySig[c.id] == sig) continue;
      final last = _lastRelaySync[c.id];
      if (last != null && now.difference(last) < timings.hello) continue;
      _lastRelaySync[c.id] = now;
      log('relays changed, syncing with ${c.name}');
      await _sendControl(c, MsgType.update);
    }
  }

  List<RelayInfo> _handoffPartners() {
    final anchors = peers.known.values.where((p) => p.healthy && p.lastOk != null).toList()
      ..sort((a, b) => a.firstSeen.compareTo(b.firstSeen));
    final out = <RelayInfo>[];
    for (final a in anchors) {
      if (out.any((o) => bytesEqual(o.nodePk, a.relay.nodePk))) continue;
      out.add(a.relay);
      if (out.length >= maxPartners) break;
    }
    return out;
  }

  /// On a clean exit the relay passes its blobs on to 2–3 peers, each blob
  /// over its own onion path, never as one bulk transfer.
  Future<void> _handoff() async {
    if (!node.relayRunning || node.store.count == 0) return;
    final partners = _handoffPartners();
    final blobs = node.drainForHandoff();
    if (partners.isEmpty) return;
    log('handing ${blobs.length} blobs to ${partners.length} partners');
    final saved = settings.cover;
    settings.cover = CoverMode.off;
    var i = 0;
    for (final b in blobs) {
      final p = partners[i++ % partners.length];
      await _sendOnion(p, HandoffCmd(b.mailboxId, b.deleteTag, b.expiresAt, b.blob).encode());
    }
    settings.cover = saved;
  }

  Future<void> _announce() async {
    final me = (await node.localRelayInfos()).firstOrNull;
    if (me == null) return;
    for (final p in peers.activeRelays) {
      node.dht.add(p);
      await node.announceTo(p, me);
    }
  }

  /// DHT fallback: only when friends cannot supply enough peers. Queries go
  /// over onion paths through known peers, so DHT nodes never see our IP.
  Future<void> _discover() async {
    if (peers.active.length >= targetPeers || peers.active.isEmpty) return;
    final target = randomBytes(32);
    final asked = <String>{};
    var cands = [...peers.activeRelays, ...node.dht.all];
    for (var round = 0; round < 3; round++) {
      final batch = _closest(cands, target).where((r) => !asked.contains(r.id)).take(dhtAlpha).toList();
      if (batch.isEmpty) break;
      final results = await Future.wait([
        for (final b in batch)
          _request(b, 1, (s) => surbCmd(Cmd.dhtFind, s.first, target)),
      ]);
      asked.addAll(batch.map((b) => b.id));
      var found = 0;
      for (final replies in results) {
        for (final r in replies) {
          await node.addCerts(r.certs);
          for (final n in r.nodes) {
            if (node.isSelf(n)) continue;
            if (!peers.known.containsKey(n.key)) found++;
            peers.add(n, 'dht');
            if (node.relayRunning) node.dht.add(n);
            cands.add(n);
          }
        }
      }
      if (found == 0) break;
    }
    peers.refresh(minRequired: settings.hops);
    _changed();
  }

  List<RelayInfo> _closest(List<RelayInfo> nodes, Uint8List target) {
    final seenIds = <String>{};
    final uniq = [for (final n in nodes) if (seenIds.add(n.id)) n];
    uniq.sort((a, b) {
      final da = _dist(a, target);
      final db = _dist(b, target);
      return compareBytes(da, db);
    });
    return uniq;
  }

  Uint8List _dist(RelayInfo r, Uint8List t) {
    final id = Crypto.sha256Sync(r.nodePk);
    return Uint8List.fromList([for (var i = 0; i < 32; i++) id[i] ^ t[i]]);
  }
}
