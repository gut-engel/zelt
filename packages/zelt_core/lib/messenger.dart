import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random, max, min, pow;
import 'dart:math' as math show log;
import 'dart:typed_data';

import 'address.dart';
import 'bytes.dart';
import 'constants.dart';
import 'crypto.dart';
import 'envelope.dart';
import 'groups.dart';
import 'invite.dart';
import 'media.dart';
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
  /// Mean time between fallback mailbox polls (foreground). Delivery itself
  /// rides on watches; polls only catch what a watch missed and check that
  /// mailbox relays are alive.
  final Duration poll;

  /// Mean time between fallback polls in the background.
  final Duration pollBackground;

  /// Mean time between watch renewals (foreground / background). A watch
  /// lives [watchLifetimeFactor] times as long, so they always overlap.
  final Duration watch;
  final Duration watchBackground;
  final Duration tick;
  final Duration hello;
  final Duration request;
  final Duration retry;
  final Duration discovery;
  final Duration update;
  final Duration announce;
  final Duration coverLowMean;
  final Duration coverConstant;

  static const watchLifetimeFactor = 4;

  const Timings({
    this.poll = const Duration(seconds: 30),
    this.pollBackground = const Duration(seconds: 120),
    this.watch = const Duration(seconds: 20),
    this.watchBackground = const Duration(seconds: 60),
    this.tick = const Duration(seconds: 5),
    this.hello = const Duration(seconds: 20),
    this.request = const Duration(seconds: 8),
    this.retry = const Duration(seconds: 15),
    this.discovery = const Duration(minutes: 3),
    this.update = const Duration(hours: 12),
    this.announce = const Duration(minutes: 30),
    this.coverLowMean = const Duration(seconds: 30),
    this.coverConstant = const Duration(seconds: 1),
  });
}

/// Delivery target: a message should reach the recipient within this time.
const Duration deliveryBudget = Duration(seconds: 10);

/// Mixing delay allowed on one delivery (sender path + watch reply path),
/// leaving the rest of [deliveryBudget] for the network and processing.
const int mixBudgetMs = 6000;

/// An incoming media transfer being reassembled (RAM only; after a restart
/// the missing parts are requested again).
class _Transfer {
  final String contactId;
  MediaRef? ref;
  final int total;
  final Map<int, Uint8List> parts = {};
  DateTime lastActivity = DateTime.now();
  DateTime? lastRequest;
  int requests = 0;
  _Transfer(this.contactId, this.total);

  int get buffered => parts.values.fold(0, (n, p) => n + p.length);
  List<int> get missing => [for (var i = 0; i < total; i++) if (!parts.containsKey(i)) i];
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

  /// Open invite texts (see invite.dart), by invite ID.
  final Map<String, PendingInvite> invites = {};

  /// Invite mailbox IDs on the relay being polled or watched.
  final Map<String, PendingInvite> _inviteIds = {};

  /// Media bytes (the app sets an encrypted store).
  MediaStore media = MemoryMediaStore();

  /// The user's own sticker library, newest last.
  final List<MediaRef> stickers = [];

  /// Group chats (see groups.dart), by group ID.
  final Map<String, Group> groups = {};

  /// Media we passed on in a group before its bytes were here: who gets them
  /// once they are.
  final Map<String, Set<String>> _forwardPending = {};

  /// Blobs we failed to decrypt (logged once each).
  final Set<String> _undecryptable = {};

  /// Opaque app data kept with the state (backup settings).
  Map<String, dynamic> appData = {};

  void setAppData(String key, Object? value) {
    if (value == null) {
      appData.remove(key);
    } else {
      appData[key] = value;
    }
    _changed();
  }

  final Map<String, _Transfer> _transfers = {};
  final Set<String> _haveMedia = {};
  final Map<String, DateTime> _lastServed = {};
  final Map<String, (DateTime, int)> _servedThisHour = {};

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

  /// A group message, or an invitation to a group, arrived.
  void Function(Group g, Message? m)? onIncomingGroup;

  /// This identity was restored on another device, which now holds the
  /// sessions: this one stopped and must not be used any more.
  bool superseded = false;
  void Function()? onSuperseded;

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

  /// The token of the code currently holding [_locked].
  Object? _lockHolder;

  /// Serialises ratchet and receive state changes. Reentrant: code running
  /// inside the current holder's call runs directly. Each acquisition has its
  /// own token, so a timer or detached future that merely inherited the zone
  /// of an earlier (or the current) holder waits its turn instead of
  /// slipping past the lock.
  Future<T> _locked<T>(Future<T> Function() f) {
    final z = Zone.current[_lockKey];
    if (z != null && identical(z, _lockHolder)) return f();
    final c = Completer<T>();
    _lock = _lock.then((_) async {
      final token = Object();
      _lockHolder = token;
      try {
        c.complete(await runZoned(f, zoneValues: {_lockKey: token}));
      } catch (e, st) {
        c.completeError(e, st);
      } finally {
        _lockHolder = null;
      }
    });
    return c.future;
  }

  /// Zone for background work: carries no lock token (so it queues for
  /// [_locked] like any other caller) and logs errors nobody awaited.
  late final Zone _bg = Zone.root.fork(
    specification: ZoneSpecification(
      handleUncaughtError: (self, parent, zone, e, st) => log('background task failed: $e'),
    ),
  );

  /// Starts [f] outside any lock holder's zone: it queues for the lock like
  /// any other caller instead of running alongside the holder.
  void _detach(Future<void> Function() f) => _bg.run(() => unawaited(f()));

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
    'invites': [for (final i in invites.values) i.toJson()],
    'stickers': [for (final s in stickers) s.toJson()],
    if (groups.isNotEmpty) 'groups': [for (final g in groups.values) g.toJson()],
    if (appData.isNotEmpty) 'app': appData,
    if (superseded) 'superseded': true,
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
    for (final i in j['invites'] ?? []) {
      final inv = PendingInvite.fromJson(i);
      m.invites[inv.id] = inv;
    }
    m.stickers.addAll([for (final s in j['stickers'] ?? []) MediaRef.fromJson(s)]);
    for (final g in j['groups'] ?? []) {
      final group = Group.fromJson(g);
      m.groups[group.id] = group;
    }
    m.appData = Map<String, dynamic>.of(j['app'] as Map<String, dynamic>? ?? {});
    m.superseded = j['superseded'] == true;
    m._advertised = {...(j['advertised'] as List? ?? []).cast<String>()};
    m.node.certs.loadJson(j['certs'] as List? ?? []);
    if (j['peers'] != null) m.peers.loadJson(j['peers']);
    return m;
  }

  /// What a backup holds: everything needed to carry on, minus what is
  /// rebuilt anyway (outbox, dedup table, open invites, onion-key
  /// certificates) and minus every session secret: ratchets and pending key
  /// exchanges are left out, so a backup never contains message keys. A
  /// restore starts new sessions ([restore]).
  Map<String, dynamic> backupJson() {
    final j = toJson();
    for (final k in const ['outbox', 'seen', 'invites', 'certs', 'advertised', 'superseded']) {
      j.remove(k);
    }
    j['contacts'] = [
      for (final c in j['contacts'] as List)
        Map<String, dynamic>.of(c as Map<String, dynamic>)
          ..remove('ratchet')
          ..remove('kemPk')
          ..remove('kemSk')
          ..remove('kemCt')
          ..remove('lhs')
          ..remove('lus')
          ..remove('lur')
          ..remove('peerConfirmed'),
    ];
    return j;
  }

  /// A messenger from a backup ([backupJson]), with new sessions started
  /// for every contact.
  static Future<Messenger> restore(
    Map<String, dynamic> backup, {
    Timings timings = const Timings(),
    InternetAddress? bindAddress,
    bool advertiseLoopback = false,
  }) async {
    final m = await load(backup, timings: timings, bindAddress: bindAddress, advertiseLoopback: advertiseLoopback);
    await m.restartSessions();
    m.log('restored from a backup: ${m.contacts.length} contacts, ${m.groups.length} groups');
    return m;
  }

  // --- Lifecycle -------------------------------------------------------

  /// v1 outbox entries hold one sealed blob; recover the inner content so it
  /// can be re-sealed per relay.
  Future<void> _migrateOutbox() async {
    for (final o in outbox.toList()) {
      final legacy = o.legacyBlob;
      if (legacy == null || o.inner != null) continue;
      final c = contacts[o.contactId];
      final opened = c == null ? null : await Envelope.open(c.keys.envOut, legacy);
      if (opened == null) {
        outbox.remove(o);
        continue;
      }
      o.inner = Envelope.inner(opened.$1, opened.$2);
      o.legacyBlob = null;
    }
  }

  Future<void> start() async {
    if (_started || superseded) return;
    _started = true;
    await _migrateOutbox();
    await node.start(relay: settings.relay);
    // Timers and background work live in [_bg]: errors nobody awaits (a
    // relay that vanished mid-request) are logged, not thrown at the caller.
    await _bg.run(() async {
      peers.refresh(minRequired: settings.hops);
      await _refreshMailboxes();
      _schedulePoll();
      _scheduleWatch();
      node.onEntryChanged = _rewatchAll;
      _rewatchAll();
      _timers.add(Timer.periodic(timings.tick, (_) => _maintenance()));
      _setupCover();
      unawaited(_maintenance());
      unawaited(pollNow());
    });
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
    _watchTimer?.cancel();
    _rewatchSoon?.cancel();
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
    final (session, _) = await _newPairingHalf();
    return session;
  }

  Future<(PairingSession, PairingCode)> _newPairingHalf() async {
    final eph = await Crypto.x25519Generate();
    final seed = randomBytes(32);
    final relays = (await node.localRelayInfos()).take(3).toList();
    int? slot;
    int? epoch;
    Uint8List? slotKey;
    if (relays.isNotEmpty) {
      // The scanner gets the whole slot on our relay: half to send to us, half
      // for its own mailbox use (whatever it delegates is carved from the tree).
      slot = nextSlot++;
      epoch = tokenEpochOf(DateTime.now());
      slotKey = await node.issuer.keyFor(slot, epoch);
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
      credSlot: slot,
      credEpoch: epoch,
      credKey: slotKey,
      grants: grants,
    );
    _changed();
    return (PairingSession(eph, seed, slot ?? 0, code.encode()), code);
  }

  // --- Invite texts ----------------------------------------------------

  /// A one-time invite text: the first friend who uses it within [validity]
  /// is added; nobody after that, and nobody once it expired.
  Future<PendingInvite> createInvite({Duration validity = inviteValidity}) async {
    final (session, code) = await _newPairingHalf();
    if (code.relays.isEmpty && code.grants.isEmpty) {
      throw StateError('no mailbox relay yet: wait until zelt is connected');
    }
    final inviteId = randomBytes(16);
    final inviteKey = await Crypto.x25519Generate();
    // Whole seconds: the text carries the expiry with that precision.
    final expires = DateTime.fromMillisecondsSinceEpoch(
      (DateTime.now().add(validity).millisecondsSinceEpoch ~/ 1000) * 1000,
    );
    final text = InviteCode(inviteId: inviteId, invitePub: inviteKey.pub, expiresAt: expires, code: code).encode();
    final inv = PendingInvite(
      inviteId: inviteId,
      inviteKey: inviteKey,
      expiresAt: expires,
      eph: session.eph,
      seed: session.seed,
      slot: session.slot,
      text: text,
      keys: await InviteKeys.derive(session.seed, inviteId),
    );
    invites[inv.id] = inv;
    await save();
    log('invite created, valid until ${expires.toIso8601String().substring(11, 19)}');
    _rewatchAll(); // watch the invite's mailbox IDs
    return inv;
  }

  /// Lets an invite expire within [grace] (never later than before).
  void shortenInvite(String id, Duration grace) {
    final inv = invites[id];
    if (inv == null) return;
    final t = DateTime.now().add(grace);
    if (t.isBefore(inv.expiresAt)) inv.expiresAt = t;
    _changed();
  }

  void cancelInvite(String id) {
    if (invites.remove(id) == null) return;
    _inviteIds.removeWhere((_, v) => v.id == id);
    _changed();
  }

  void _pruneInvites(DateTime now) {
    final before = invites.length;
    invites.removeWhere((_, i) => i.expiredAt(now));
    if (invites.length != before) {
      _inviteIds.removeWhere((_, v) => !invites.containsKey(v.id));
      log('${before - invites.length} invite(s) expired unused');
      _changed();
    }
  }

  /// Uses a friend's invite text. Returns the new contact; it becomes ready
  /// once the inviter's device accepts the join request.
  Future<Contact> acceptInvite(String text, {String? name}) async {
    final inv = InviteCode.parse(text);
    if (inv.expiredAt(DateTime.now())) throw const FormatException('this invite has expired');
    final (session, mine) = await _newPairingHalf();
    final eph = await Crypto.x25519Generate();
    final dh = await Crypto.x25519(eph, inv.invitePub);
    final join = PendingJoin(
      inviteId: inv.inviteId,
      key: await InviteKeys.joinKey(dh, inv.code.seed, inv.inviteId, eph.pub),
      ephPub: eph.pub,
      content: mine.toBytes(),
      expiresAt: inv.expiresAt,
      keys: await InviteKeys.derive(inv.code.seed, inv.inviteId),
    );
    final c = await completePairingWith(session, inv.code, name: name, join: join);
    return c;
  }

  /// Stores fresh copies of our join request in the inviter's mailboxes.
  Future<void> _sendJoin(Contact c) async {
    final j = c.pendingJoin;
    if (j == null) return;
    final now = DateTime.now();
    if (!now.isBefore(j.expiresAt)) {
      c.pendingJoin = null;
      log('invite from ${c.name} expired before it was accepted');
      _changed();
      return;
    }
    j.lastSent = now;
    final epoch = mailboxEpochOf(now);
    final byNode = <String, Credential>{};
    for (final g in c.theirMailboxes) {
      if (g.usable(now)) byNode.putIfAbsent(hex(g.relay.nodePk), () => g);
    }
    final grants = byNode.values.toList()..shuffle(_rng);
    final results = await Future.wait(grants.take(copiesPerMessage).map((g) async {
      final relay = node.isSelf(g.relay) ? g.relay : (peers.resolve(g.relay.nodePk) ?? g.relay);
      final mailboxId = await Envelope.mailboxId(j.keys.mbox, epoch, relay.nodePk);
      final blob = await JoinBlob.seal(j.key, j.ephPub, j.inviteId, j.content);
      final hash = await Crypto.sha256(blob);
      final deleteTag = await Envelope.deleteTag(await Envelope.deleteKey(j.keys.del, hash));
      return _sendOnion(relay, StoreCmd(mailboxId, await g.take(hash), deleteTag, blob).encode());
    }));
    log('join request to ${c.name}: ${results.where((x) => x).length}/${grants.length} copies stored');
    _changed();
  }

  /// A join request arrived for one of our invites. Returns the delete entry,
  /// or null if it is not a valid request for a live invite.
  Future<DeleteEntry?> _onJoin(PendingInvite inv, Uint8List mailboxId, Uint8List blob) async {
    final hash = await Crypto.sha256(blob);
    final del = DeleteEntry(mailboxId, hash, await Envelope.deleteKey(inv.keys.del, hash));
    final ephPub = JoinBlob.ephOf(blob);
    if (ephPub == null) return null;
    final content = await JoinBlob.open(
      await InviteKeys.joinKey(await Crypto.x25519(inv.inviteKey, ephPub), inv.seed, inv.inviteId, ephPub),
      inv.inviteId,
      blob,
    );
    if (content == null) return null;
    // Checked after decryption, in the lock: exactly one activation.
    if (invites[inv.id] != inv) return del;
    if (inv.expiredAt(DateTime.now())) {
      cancelInvite(inv.id);
      log('rejected a join request for an expired invite');
      return del;
    }
    final PairingCode theirs;
    try {
      final r = ByteReader(content);
      theirs = PairingCode.read(r);
      if (r.remaining != 0) throw const FormatException('trailing bytes');
    } on FormatException {
      return del;
    }
    // Both sides scanned each other at the same time: the invite of the
    // lower identity key wins on both devices, so ours yields.
    final mutual = contacts[hex(theirs.idPub)];
    if (mutual?.pendingJoin != null && compareBytes(identity.id.pub, theirs.idPub) > 0) {
      cancelInvite(inv.id);
      log('both scanned at once: using ${mutual!.name}\'s code');
      return del;
    }
    // Used up: forget the invite (and save that) before pairing, so a crash
    // or a second request can never activate it again.
    cancelInvite(inv.id);
    await save();
    log('invite used by ${theirs.name.isEmpty ? 'a friend' : theirs.name}');
    // Outside the receive lock.
    _detach(() => completePairingWith(PairingSession(inv.eph, inv.seed, inv.slot, inv.text), theirs));
    return del;
  }

  /// Called after scanning the friend's code. Our own code must have been
  /// (or still be) shown to them from the same [session].
  Future<Contact> completePairing(PairingSession session, String scanned, {String? name}) =>
      completePairingWith(session, PairingCode.parse(scanned), name: name);

  Future<Contact> completePairingWith(PairingSession session, PairingCode theirs, {String? name, PendingJoin? join}) async {
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
      pendingJoin: join,
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
        Credential.fromSlotKey(r0, theirs.credSlot!, theirs.credEpoch!, theirs.credKey!, next: 0, end: half),
      );
      _addHeld(Credential.fromSlotKey(r0, theirs.credSlot!, theirs.credEpoch!, theirs.credKey!, next: half));
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
    _rewatchAll(); // the new contact's mailbox IDs
    await _refreshMailboxes();
    _changed();
    if (join != null) await _sendJoin(c);
    unawaited(_handshakeTick(c, force: true));
    return c;
  }

  void deleteContact(String id) {
    contacts.remove(id);
    outbox.removeWhere((o) => o.contactId == id);
    peers.removeSource(id);
    _changed();
  }

  /// Marks a chat as private: it is hidden behind the duress PIN.
  void setContactPrivate(String id, bool v) {
    final c = contacts[id];
    if (c == null || c.private == v) return;
    c.private = v;
    _changed();
  }

  void setGroupPrivate(String id, bool v) {
    final g = groups[id];
    if (g == null || g.private == v) return;
    g.private = v;
    _changed();
  }

  void renameContact(String id, String name) {
    contacts[id]?.name = name;
    _changed();
  }

  /// Verifying a contact also sends them our profile picture; un-verifying
  /// takes it back.
  void setVerified(String id, bool v) {
    final c = contacts[id];
    if (c == null) return;
    c.verified = v;
    _changed();
    _detach(() => _syncAvatar(c));
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

  bool _needsHello(Contact c) =>
      !c.ready ||
      (!c.keys.initiator && !c.peerConfirmed) ||
      (c.peerResetAt != null && DateTime.now().difference(c.peerResetAt!) < _announceReset);

  /// How long hellos keep announcing a session the contact restarted.
  static const _announceReset = Duration(minutes: 10);

  Future<void> _handshakeTick(Contact c, {bool force = false}) async {
    if (!_started) return;
    final j = c.pendingJoin;
    if (j != null && (j.lastSent == null || DateTime.now().difference(j.lastSent!) >= timings.hello)) {
      await _sendJoin(c);
    }
    if (!_needsHello(c)) return;
    if (c.theirMailboxes.isEmpty) return;
    final last = c.lastHelloSent;
    if (!force && last != null && DateTime.now().difference(last) < timings.hello) return;
    c.lastHelloSent = DateTime.now();
    final hello = Hello(
      kemPk: c.keys.initiator && !c.ready ? c.kemPk : null,
      kemCt: !c.keys.initiator ? c.kemCt : null,
      info: await _addressInfoFor(c),
      epoch: c.epoch,
      raisedBy: c.epoch == 0 ? 0 : (c.epochMine ? Hello.raisedBySender : Hello.raisedByReceiver),
    );
    final item = OutItem(
      id: hex(randomBytes(16)),
      contactId: c.id,
      handshake: true,
      needsReceipt: false,
      inner: Envelope.inner(Envelope.kindHandshake, hello.encode()),
    );
    await _dispatch(item);
    _changed();
  }

  Future<void> _onHello(Contact c, Hello h) async {
    // A hello from an older session (delayed, or replayed) changes nothing;
    // one from a newer session means the friend restarted it (a restore).
    if (h.epoch < c.epoch) {
      log('ignored a hello from an older session with ${c.name}');
      return;
    }
    if (h.epoch > c.epoch) {
      if (h.raisedBy == Hello.raisedByReceiver) {
        // The friend answers a restart "we" made, but not on this device:
        // this identity was restored elsewhere. Competing for the sessions
        // would break both devices, so this one stops for good.
        _supersede(c);
        return;
      }
      await _resetSession(c, h.epoch);
    }
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
      final slotKey = await node.issuer.keyFor(c.slot, k.epoch);
      creds.add(Credential.fromSlotKey(k.relay, k.slot, k.epoch, slotKey, next: half));
    }
    for (final rec in _currentMailboxes()) {
      if (rec.own) {
        if (relays.isEmpty) continue;
        final k = await node.issuer.issue(relays.first, c.slot);
        final slotKey = await node.issuer.keyFor(c.slot, k.epoch);
        mbox.add(Credential.fromSlotKey(k.relay, k.slot, k.epoch, slotKey, next: 0, end: half));
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
        _rewatchAll();
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
          _addHeld(c.withRelay(t));
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

  /// Queues a text message, optionally answering [replyTo] (a message ID in
  /// this chat). Returns the stored [Message].
  Future<Message> sendText(String contactId, String text, {String? replyTo}) async {
    final c = contacts[contactId];
    if (c == null) throw StateError('unknown contact');
    if (utf8.encode(text).length > maxTextBytes) throw ArgumentError('message too long');
    final id = randomBytes(16);
    final now = DateTime.now();
    final m = Message(id: hex(id), outgoing: true, text: text, time: now, replyTo: _replyIn(c.messages, replyTo));
    c.messages.add(m);
    final chat = _chatFor(m);
    final item = OutItem(id: hex(id), contactId: c.id, pending: chat.encode());
    outbox.add(item);
    _changed();
    if (c.ready) {
      await _seal(c, item);
      await _dispatch(item);
    }
    return m;
  }

  /// Only an existing message of the same chat can be answered.
  static String? _replyIn(List<Message> msgs, String? id) =>
      id != null && msgs.any((m) => m.id == id) ? id : null;

  /// The wire form of one of our own messages (text, image or sticker),
  /// identical every time it is built: resending after a session reset, and
  /// re-signing a group post, give the same bytes.
  static ChatMsg _chatFor(Message m) {
    final media = m.media;
    final type = media == null
        ? MsgType.text
        : media.kind == MediaKind.sticker
        ? MsgType.sticker
        : MsgType.image;
    return ChatMsg(
      type,
      unhex(m.id),
      timestamp: (m.sentAt ?? m.time).millisecondsSinceEpoch,
      text: type == MsgType.sticker ? '' : m.text,
      media: media,
      replyTo: m.replyTo == null ? null : unhex(m.replyTo!),
    );
  }

  /// Reacts to a message in a chat with one emoji ('' removes our reaction).
  Future<void> react(String contactId, String messageId, String emoji) async {
    final c = contacts[contactId];
    if (c == null) throw StateError('unknown contact');
    if (!ChatMsg.validReaction(emoji)) throw ArgumentError('not a reaction');
    final msg = c.messages.where((m) => m.id == messageId).firstOrNull;
    if (msg == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    msg.react(Message.me, emoji, now);
    _changed();
    await _enqueue(c, ChatMsg(MsgType.reaction, randomBytes(16), timestamp: now, target: unhex(messageId), text: emoji));
  }

  // --- Images and stickers --------------------------------------------

  Future<void> _enqueue(Contact c, ChatMsg chat, {String? groupMsg}) async {
    final item = OutItem(id: hex(chat.id), contactId: c.id, pending: chat.encode(), groupMsg: groupMsg);
    outbox.add(item);
    _changed();
    if (c.ready) {
      await _seal(c, item);
      await _dispatch(item);
    }
  }

  static MediaRef _checkedRef(Uint8List bytes, MediaKind kind, int width, int height) {
    final format = MediaFormat.sniff(bytes);
    if (format == null || !MediaFormat.allowed(kind, format)) throw ArgumentError('unsupported format');
    final ref = MediaRef(
      hash: CryptoSync.sha256(bytes),
      size: bytes.length,
      kind: kind,
      format: format,
      width: width,
      height: height,
    );
    // Same limits a receiver applies.
    final w = ByteWriter();
    ref.write(w);
    MediaRef.read(ByteReader(w.toBytes()));
    return ref;
  }

  Future<void> _store(String hash, Uint8List bytes) async {
    await media.write(hash, bytes);
    _haveMedia.add(hash);
  }

  Future<bool> hasMedia(String hash) async {
    if (_haveMedia.contains(hash)) return true;
    final ok = await media.has(hash);
    if (ok) _haveMedia.add(hash);
    return ok;
  }

  /// Fraction of an incoming transfer received so far (null: none running).
  double? mediaProgress(String hash) {
    final t = _transfers[hash];
    return t == null ? null : t.parts.length / t.total;
  }

  void _rememberSent(Contact c, String hash) {
    c.sentMedia
      ..remove(hash)
      ..add(hash);
    if (c.sentMedia.length > 1000) c.sentMedia.removeAt(0);
  }

  /// Sends a WebP the app already scaled and re-encoded (metadata stripped).
  Future<Message> sendImage(
    String contactId,
    Uint8List webp, {
    required int width,
    required int height,
    String caption = '',
    String? replyTo,
  }) async {
    final c = contacts[contactId];
    if (c == null) throw StateError('unknown contact');
    if (utf8.encode(caption).length > maxTextBytes ~/ 2) throw ArgumentError('caption too long');
    final ref = _checkedRef(webp, MediaKind.image, width, height);
    await _store(ref.id, webp);
    final id = randomBytes(16);
    final now = DateTime.now();
    final m = Message(id: hex(id), outgoing: true, text: caption, time: now, media: ref, replyTo: _replyIn(c.messages, replyTo));
    c.messages.add(m);
    _rememberSent(c, ref.id);
    await _enqueue(c, _chatFor(m));
    await _sendChunks(c, ref.id, webp);
    return m;
  }

  /// Adds a sticker (normalised WebP from the app) to our library.
  Future<MediaRef> addSticker(Uint8List bytes, {required int width, required int height}) async {
    final ref = _checkedRef(bytes, MediaKind.sticker, width, height);
    await _store(ref.id, bytes);
    stickers
      ..removeWhere((s) => s.id == ref.id)
      ..add(ref);
    _changed();
    return ref;
  }

  /// Adds a sticker someone sent us to our own library (once its bytes are here).
  Future<bool> saveSticker(MediaRef ref) async {
    if (ref.kind != MediaKind.sticker || !await hasMedia(ref.id)) return false;
    stickers
      ..removeWhere((s) => s.id == ref.id)
      ..add(ref);
    _changed();
    return true;
  }

  void removeSticker(String hash) {
    stickers.removeWhere((s) => s.id == hash);
    _changed();
  }

  /// Sets our profile picture (a square WebP the app made) and sends it to
  /// verified contacts.
  Future<MediaRef> setAvatar(Uint8List webp, {required int width, required int height}) async {
    final ref = _checkedRef(webp, MediaKind.avatar, width, height);
    await _store(ref.id, webp);
    settings.avatar = ref;
    _changed();
    for (final c in contacts.values.toList()) {
      _detach(() => _syncAvatar(c));
    }
    return ref;
  }

  /// Removes our profile picture; contacts who had it are told to drop it.
  void clearAvatar() {
    settings.avatar = null;
    _changed();
    for (final c in contacts.values.toList()) {
      _detach(() => _syncAvatar(c));
    }
  }

  /// Brings a contact to the picture they should have: ours if we verified
  /// them, none otherwise. The old hash is no longer served to them.
  Future<void> _syncAvatar(Contact c) async {
    if (!c.ready || contacts[c.id] != c) return;
    final want = c.verified ? settings.avatar : null;
    if (c.avatarSent == want?.id) return;
    final old = c.avatarSent;
    c.avatarSent = want?.id;
    if (old != null) c.sentMedia.remove(old);
    await _enqueue(c, ChatMsg(MsgType.avatar, randomBytes(16), media: want));
    log(want == null ? 'profile picture withdrawn from ${c.name}' : 'profile picture sent to ${c.name}');
    if (want == null) return;
    _rememberSent(c, want.id);
    final bytes = await media.read(want.id);
    if (bytes == null) return;
    _lastServed['${c.id}/${want.id}'] = DateTime.now();
    await _sendChunks(c, want.id, bytes);
  }

  /// Sends a sticker as its hash only; a friend without it asks us for it.
  Future<Message> sendSticker(String contactId, MediaRef ref, {String? replyTo}) async {
    final c = contacts[contactId];
    if (c == null) throw StateError('unknown contact');
    if (ref.kind != MediaKind.sticker || !await hasMedia(ref.id)) throw ArgumentError('unknown sticker');
    final id = randomBytes(16);
    final now = DateTime.now();
    final m = Message(id: hex(id), outgoing: true, text: '', time: now, media: ref, replyTo: _replyIn(c.messages, replyTo));
    // Before the message is added: a sticker we send is not "from them".
    final known = _stickerKnownBy(c, ref.id);
    c.messages.add(m);
    _rememberSent(c, ref.id);
    await _enqueue(c, _chatFor(m));
    if (!known) await _pushMedia(c, ref.id);
    return m;
  }

  /// A friend who sent a sticker to us, or got it from us (here or in a
  /// group), has it: it travels as its hash only.
  bool _stickerKnownBy(Contact c, String hash) =>
      c.sentMedia.contains(hash) ||
      c.messages.any((x) => !x.outgoing && x.media?.id == hash) ||
      groups.values.any((g) => g.messages.any((x) => x.via == c.id && x.media?.id == hash));

  /// Sends media bytes to a friend right away (no request round trip).
  Future<void> _pushMedia(Contact c, String hash) async {
    final bytes = await media.read(hash);
    if (bytes == null) return;
    // Counts as served: a request racing the push is not answered twice.
    _lastServed['${c.id}/$hash'] = DateTime.now();
    await _sendChunks(c, hash, bytes);
  }

  // --- Groups ----------------------------------------------------------

  String get _myId => hex(identity.id.pub);

  String _memberName() {
    final n = cleanName(settings.name, maxMemberNameBytes);
    return n.isEmpty ? 'Member ${_myId.substring(0, 4)}' : n;
  }

  /// Creates a group with us as its admin and invites [contactIds].
  Future<Group> createGroup(String name, Iterable<String> contactIds) async {
    final n = cleanName(name, maxGroupNameBytes);
    if (n.isEmpty) throw ArgumentError('the group needs a name');
    final key = await Crypto.ed25519Generate();
    final gid = randomBytes(16);
    final roster = await Roster.sign(
      key,
      groupId: gid,
      version: 1,
      name: n,
      members: [GroupMember(identity.id.pub, key.pub, _memberName())],
    );
    final g = Group(id: hex(gid), roster: roster, state: GroupState.member, signKey: key);
    groups[g.id] = g;
    log('group "$n" created');
    _changed();
    await inviteToGroup(g.id, contactIds);
    return g;
  }

  /// Admin: invites contacts. They become members once they accept.
  Future<void> inviteToGroup(String groupId, Iterable<String> contactIds) async {
    final g = groups[groupId];
    if (g == null || !g.isAdmin || !g.active || g.roster.closed) throw StateError('only the group admin can invite');
    final fresh = [
      for (final id in contactIds.toSet())
        if (contacts[id] != null && g.roster.member(id) == null && !g.pendingInvites.contains(id)) contacts[id]!,
    ];
    if (g.roster.members.length + g.pendingInvites.length + fresh.length > maxGroupMembers) {
      throw StateError('a group has at most $maxGroupMembers members');
    }
    for (final c in fresh) {
      g.pendingInvites.add(c.id);
      await _enqueue(c, ChatMsg(MsgType.groupInvite, randomBytes(16), payload: g.roster.encode()));
    }
    _changed();
  }

  /// Accepts an invitation: sends the admin our signing key for the group.
  Future<void> acceptGroupInvite(String groupId) async {
    final g = groups[groupId];
    if (g == null || g.state != GroupState.invited) return;
    final admin = contacts[g.invitedBy];
    if (admin == null) throw StateError('the friend who invited you is no longer a contact');
    // A fresh key for every membership: a re-joined group cannot be linked
    // to the earlier membership by its key.
    final key = await Crypto.ed25519Generate();
    g.signKey = key;
    g.state = GroupState.joining;
    _changed();
    await _enqueue(
      admin,
      ChatMsg(MsgType.groupJoin, randomBytes(16), payload: GroupJoin(g.roster.groupId, key.pub, _memberName()).encode()),
    );
  }

  /// Declines an invitation and forgets the group.
  Future<void> declineGroupInvite(String groupId) async {
    final g = groups[groupId];
    if (g == null || g.state != GroupState.invited) return;
    groups.remove(groupId);
    _changed();
    final admin = contacts[g.invitedBy];
    if (admin != null) await _enqueue(admin, ChatMsg(MsgType.groupLeave, randomBytes(16), payload: g.roster.groupId));
  }

  /// Leaves a group. The admin leaving closes it: members keep talking, but
  /// nobody can be added or removed any more.
  Future<void> leaveGroup(String groupId) async {
    final g = groups[groupId];
    if (g == null || !(g.state == GroupState.member || g.state == GroupState.joining)) return;
    if (g.isAdmin) {
      g.pendingInvites.clear();
      g.state = GroupState.left;
      await _updateRoster(g, g.roster.members.toList(), closed: true);
    } else {
      g.state = GroupState.left;
      _changed();
      final admin = contacts[g.roster.admin!.id];
      if (admin != null) await _enqueue(admin, ChatMsg(MsgType.groupLeave, randomBytes(16), payload: g.roster.groupId));
    }
    log('left group "${g.name}"');
  }

  /// Admin: removes a member (or withdraws an invitation).
  Future<void> removeFromGroup(String groupId, String memberId) async {
    final g = groups[groupId];
    if (g == null || !g.isAdmin || !g.active || g.roster.closed) throw StateError('only the group admin can remove members');
    if (memberId == _myId) return;
    g.pendingInvites.remove(memberId);
    _changed();
    if (g.roster.member(memberId) == null) return;
    // The removed member gets the new list too, so they know.
    await _updateRoster(g, g.roster.members.where((m) => m.id != memberId).toList(), alsoTo: [memberId]);
  }

  /// Admin: renames the group.
  Future<void> renameGroup(String groupId, String name) async {
    final g = groups[groupId];
    if (g == null || !g.isAdmin || !g.active || g.roster.closed) throw StateError('only the group admin can rename the group');
    final n = cleanName(name, maxGroupNameBytes);
    if (n.isEmpty || n == g.name) return;
    await _updateRoster(g, g.roster.members.toList(), name: n);
  }

  Future<void> _updateRoster(Group g, List<GroupMember> members, {String? name, bool closed = false, List<String> alsoTo = const []}) async {
    g.roster = await Roster.sign(
      g.signKey!,
      groupId: g.roster.groupId,
      version: g.roster.version + 1,
      name: name ?? g.roster.name,
      members: members,
      closed: closed,
    );
    _changed();
    final payload = g.roster.encode();
    final to = {for (final m in g.roster.members) m.id, ...alsoTo}..remove(_myId);
    for (final id in to) {
      final c = contacts[id];
      if (c != null) await _enqueue(c, ChatMsg(MsgType.groupRoster, randomBytes(16), payload: payload));
    }
  }

  /// Forgets a group we are no longer in (leave it first).
  void deleteGroup(String groupId) {
    final g = groups[groupId];
    if (g == null || g.state == GroupState.member || g.state == GroupState.joining) return;
    groups.remove(groupId);
    outbox.removeWhere((o) => o.groupMsg?.startsWith('$groupId/') ?? false);
    _changed();
  }

  void markGroupRead(String id) {
    final g = groups[id];
    if (g == null || g.unread == 0) return;
    g.unread = 0;
    _changed();
  }

  /// Members our posts go to: everyone else, except an admin who left.
  List<GroupMember> _recipients(Group g) => [
    for (final m in g.roster.members)
      if (m.id != _myId && !(g.roster.closed && bytesEqual(m.signPk, g.roster.adminSignPk))) m,
  ];

  Group _activeGroup(String id) {
    final g = groups[id];
    if (g == null || !g.active || g.signKey == null) throw StateError('not a member of this group');
    return g;
  }

  Future<Message> sendGroupText(String groupId, String text, {String? replyTo}) async {
    final g = _activeGroup(groupId);
    if (utf8.encode(text).length > maxTextBytes) throw ArgumentError('message too long');
    final m = Message(
      id: hex(randomBytes(16)),
      outgoing: true,
      text: text,
      time: DateTime.now(),
      replyTo: _replyIn(g.messages, replyTo),
      author: _myId,
    );
    g.messages.add(m);
    _changed();
    await _sendPost(g, _chatFor(m), m.id);
    return m;
  }

  Future<Message> sendGroupImage(
    String groupId,
    Uint8List webp, {
    required int width,
    required int height,
    String caption = '',
    String? replyTo,
  }) async {
    final g = _activeGroup(groupId);
    if (utf8.encode(caption).length > maxTextBytes ~/ 2) throw ArgumentError('caption too long');
    final ref = _checkedRef(webp, MediaKind.image, width, height);
    await _store(ref.id, webp);
    final m = Message(
      id: hex(randomBytes(16)),
      outgoing: true,
      text: caption,
      time: DateTime.now(),
      media: ref,
      replyTo: _replyIn(g.messages, replyTo),
      author: _myId,
    );
    g.messages.add(m);
    _changed();
    final to = await _sendPost(g, _chatFor(m), m.id);
    for (final c in to) {
      _rememberSent(c, ref.id);
      await _pushMedia(c, ref.id);
    }
    return m;
  }

  Future<Message> sendGroupSticker(String groupId, MediaRef ref, {String? replyTo}) async {
    final g = _activeGroup(groupId);
    if (ref.kind != MediaKind.sticker || !await hasMedia(ref.id)) throw ArgumentError('unknown sticker');
    final m = Message(
      id: hex(randomBytes(16)),
      outgoing: true,
      text: '',
      time: DateTime.now(),
      media: ref,
      replyTo: _replyIn(g.messages, replyTo),
      author: _myId,
    );
    g.messages.add(m);
    _changed();
    final to = await _sendPost(g, _chatFor(m), m.id);
    for (final c in to) {
      final known = _stickerKnownBy(c, ref.id);
      _rememberSent(c, ref.id);
      if (!known) await _pushMedia(c, ref.id);
    }
    return m;
  }

  Future<void> reactInGroup(String groupId, String messageId, String emoji) async {
    final g = _activeGroup(groupId);
    if (!ChatMsg.validReaction(emoji)) throw ArgumentError('not a reaction');
    final msg = g.messages.where((m) => m.id == messageId).firstOrNull;
    if (msg == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    msg.react(Message.me, emoji, now);
    _changed();
    await _sendPost(g, ChatMsg(MsgType.reaction, randomBytes(16), timestamp: now, target: unhex(messageId), text: emoji), null);
  }

  /// "groupId/messageId" to the message.
  Message? _groupMessage(String? key) {
    if (key == null) return null;
    final i = key.indexOf('/');
    final g = groups[key.substring(0, i)];
    final id = key.substring(i + 1);
    return g?.messages.where((m) => m.id == id).firstOrNull;
  }

  /// Signs [body] and sends it to every member we are paired with ([only]:
  /// just those). Returns the contacts it went to.
  Future<List<Contact>> _sendPost(Group g, ChatMsg body, String? msgId, {Set<String>? only}) async {
    final targets = [
      for (final m in _recipients(g))
        if (contacts[m.id] != null && (only == null || only.contains(m.id))) contacts[m.id]!,
    ];
    final post = await GroupPost.sign(g.signKey!, g.roster.groupId, body.encode(), [for (final c in targets) c.idPub]);
    g.markSeen(hex(body.id));
    final payload = post.encode();
    for (final c in targets) {
      await _enqueue(
        c,
        ChatMsg(MsgType.groupPost, randomBytes(16), payload: payload),
        groupMsg: msgId == null ? null : '${g.id}/$msgId',
      );
    }
    return targets;
  }

  Future<void> _onGroupInvite(Contact c, Uint8List payload) async {
    final Roster r;
    try {
      r = await Roster.decode(payload);
    } on FormatException catch (e) {
      log('bad group invite from ${c.name}: ${e.message}');
      return;
    }
    // Only the admin invites, to a group that still takes members.
    if (r.admin!.id != c.id || r.closed) return;
    final old = groups[r.id];
    if (old != null) {
      if (old.state == GroupState.member || old.state == GroupState.joining) return;
      if (!bytesEqual(old.roster.adminSignPk, r.adminSignPk)) return;
      if (old.state == GroupState.invited && r.version <= old.roster.version) return;
    }
    final g = Group(
      id: r.id,
      roster: r,
      state: GroupState.invited,
      invitedBy: c.id,
      private: c.private,
      messages: old?.messages,
      seenPosts: old?.seenPosts,
    );
    groups[g.id] = g;
    log('${c.name} invited us to group "${r.name}"');
    _changed();
    onIncomingGroup?.call(g, null);
  }

  Future<void> _onGroupJoin(Contact c, Uint8List payload) async {
    final GroupJoin j;
    try {
      j = GroupJoin.decode(payload);
    } on FormatException {
      return;
    }
    final g = groups[hex(j.groupId)];
    if (g == null || !g.isAdmin || !g.active || g.roster.closed) return;
    // Only someone we invited, once, with a key nobody else uses.
    if (!g.pendingInvites.remove(c.id)) return;
    if (g.roster.member(c.id) != null || g.roster.bySignPk(j.signPk) != null) return;
    if (g.roster.members.length >= maxGroupMembers) return;
    final name = cleanName(j.name, maxMemberNameBytes);
    log('${c.name} joined group "${g.name}"');
    await _updateRoster(g, [
      ...g.roster.members,
      GroupMember(c.idPub, j.signPk, name.isEmpty ? 'Member ${c.id.substring(0, 4)}' : name),
    ]);
  }

  Future<void> _onGroupLeave(Contact c, Uint8List payload) async {
    if (payload.length != 16) return;
    final g = groups[hex(payload)];
    if (g == null || !g.isAdmin || !g.active) return;
    if (g.pendingInvites.remove(c.id)) _changed();
    if (g.roster.member(c.id) == null || g.roster.closed) return;
    log('${c.name} left group "${g.name}"');
    await _updateRoster(g, g.roster.members.where((m) => m.id != c.id).toList());
  }

  Future<void> _onGroupRoster(Contact c, Uint8List payload) async {
    final Roster r;
    try {
      r = await Roster.decode(payload);
    } on FormatException {
      return;
    }
    final g = groups[r.id];
    // Only from the admin who made the group, and only newer lists.
    if (g == null || !bytesEqual(r.adminSignPk, g.roster.adminSignPk) || r.admin!.id != c.id) return;
    if (r.version <= g.roster.version) return;
    g.roster = r;
    final me = r.member(_myId);
    final mine = me != null && g.signKey != null && bytesEqual(me.signPk, g.signKey!.pub);
    if (g.state == GroupState.joining && mine) {
      g.state = GroupState.member;
      log('joined group "${r.name}"');
    } else if (g.state == GroupState.member && !mine) {
      g.state = GroupState.removed;
      log('removed from group "${r.name}"');
    }
    _changed();
  }

  Future<void> _onGroupPost(Contact c, Uint8List payload) async {
    final GroupPost p;
    final ChatMsg body;
    try {
      p = GroupPost.decode(payload);
      body = ChatMsg.decode(p.body);
    } on FormatException {
      return;
    }
    final g = groups[hex(p.groupId)];
    if (g == null || !g.active) return;
    if (!const {MsgType.text, MsgType.image, MsgType.sticker, MsgType.reaction}.contains(body.type)) return;
    final postId = hex(body.id);
    if (g.seenPosts.contains(postId)) return;
    // Signed by a member, delivered by a member: someone removed can neither
    // post nor pass posts on.
    final author = g.roster.bySignPk(p.authorSignPk);
    if (author == null || g.roster.member(c.id) == null) return;
    if (!await p.verify()) {
      log('group post with a bad signature from ${c.name}');
      return;
    }
    g.markSeen(postId);
    if (author.id != _myId) _applyPost(g, c, author, body);
    _changed();
    await _forwardPost(g, c, author, p, body.media, payload);
  }

  void _applyPost(Group g, Contact via, GroupMember author, ChatMsg body) {
    if (body.type == MsgType.reaction) {
      final msg = g.messages.where((x) => x.id == hex(body.target!)).firstOrNull;
      msg?.react(author.id, body.text, body.timestamp);
      return;
    }
    final id = hex(body.id);
    if (g.messages.any((x) => x.id == id)) return;
    final msg = Message(
      id: id,
      outgoing: false,
      text: body.text,
      time: DateTime.now(),
      sentAt: DateTime.fromMillisecondsSinceEpoch(body.timestamp),
      status: MsgStatus.delivered,
      media: body.media,
      replyTo: body.replyTo == null ? null : hex(body.replyTo!),
      author: author.id,
      via: via.id,
    );
    g.messages.add(msg);
    g.unread++;
    onIncomingGroup?.call(g, msg);
    final ref = body.media;
    if (ref != null) _detach(() => _expectMedia(via, ref));
  }

  /// Passes a new post on to the members we are paired with who may not
  /// have it (not the author, not who brought it, not those the author sent
  /// it to). Media follow as soon as we have the bytes.
  Future<void> _forwardPost(Group g, Contact from, GroupMember author, GroupPost p, MediaRef? ref, Uint8List payload) async {
    for (final m in _recipients(g)) {
      if (m.id == author.id || m.id == from.id || p.sentDirectlyTo(m.idPub)) continue;
      final c = contacts[m.id];
      if (c == null) continue;
      await _enqueue(c, ChatMsg(MsgType.groupPost, randomBytes(16), payload: payload));
      if (ref == null) continue;
      final known = ref.kind == MediaKind.sticker && _stickerKnownBy(c, ref.id);
      _rememberSent(c, ref.id);
      if (known) continue;
      if (await hasMedia(ref.id)) {
        await _pushMedia(c, ref.id);
      } else {
        _forwardPending.putIfAbsent(ref.id, () => {}).add(c.id);
      }
    }
  }

  // --- Session reset (restore from backup) ------------------------------

  /// Starts a new session with every contact. A backup holds no ratchet
  /// state (it never contains message keys), and a ratchet must never be
  /// used twice, so a restored device always starts afresh. The epoch is
  /// raised past anything used before; friends reset when they see it.
  Future<void> restartSessions() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final c in contacts.values.toList()) {
      await _resetSession(c, max(c.epoch + 1, now), mine: true);
    }
  }

  void _supersede(Contact c) {
    if (superseded) return;
    superseded = true;
    log('${c.name} has a newer session with this identity on another device: this device stops');
    _changed();
    onSuperseded?.call();
    _detach(() => stop(handoff: false));
  }

  Future<void> _resetSession(Contact c, int epoch, {bool mine = false}) async {
    c.epoch = epoch;
    c.epochMine = mine;
    c.peerResetAt = mine ? null : DateTime.now();
    c.ratchet = null;
    c.peerConfirmed = false;
    c.kemCt = null;
    c.lastHelloSent = null;
    if (c.keys.initiator) {
      final kem = await Crypto.kemGenerate();
      c.kemPk = kem.pk;
      c.kemSk = kem.sk;
    } else {
      c.kemPk = null;
      c.kemSk = null;
    }
    // Anything sealed for the old session is useless now; what was not
    // delivered goes again, sealed for the new one.
    outbox.removeWhere((o) => o.contactId == c.id && o.pending == null);
    await _requeueUndelivered(c);
    log('new session with ${c.name}');
    _changed();
  }

  Future<void> _requeueUndelivered(Contact c) async {
    final cutoff = DateTime.now().subtract(relayTtl);
    final queued = {for (final o in outbox) if (o.contactId == c.id) o.id};
    for (final m in c.messages) {
      if (!m.outgoing || m.status == MsgStatus.delivered || m.time.isBefore(cutoff) || queued.contains(m.id)) continue;
      outbox.add(OutItem(id: m.id, contactId: c.id, pending: _chatFor(m).encode()));
    }
    final pendingGroup = {for (final o in outbox) if (o.contactId == c.id && o.groupMsg != null) o.groupMsg};
    for (final g in groups.values) {
      if (!g.active || g.signKey == null || !_recipients(g).any((m) => m.id == c.id)) continue;
      for (final m in g.messages) {
        if (!m.outgoing || m.status == MsgStatus.delivered || m.time.isBefore(cutoff)) continue;
        if (pendingGroup.contains('${g.id}/${m.id}')) continue;
        await _sendPost(g, _chatFor(m), m.id, only: {c.id});
      }
    }
  }

  /// Chunks are sealed in order, then sent [_parallelChunks] at a time: one
  /// slow first hop no longer holds up every chunk behind it.
  Future<void> _sendChunks(Contact c, String hash, Uint8List bytes, [List<int> indices = const []]) async {
    final total = chunkCount(bytes.length);
    final which = indices.isEmpty ? [for (var i = 0; i < total; i++) i] : indices.where((i) => i < total).toSet().toList();
    final items = <OutItem>[];
    for (final i in which) {
      final start = i * mediaChunkSize;
      final data = Uint8List.sublistView(bytes, start, min(start + mediaChunkSize, bytes.length));
      final chat = ChatMsg(MsgType.mediaChunk, randomBytes(16),
          mediaHash: unhex(hash), chunkIndex: i, chunkTotal: total, chunkData: Uint8List.fromList(data));
      items.add(OutItem(id: hex(chat.id), contactId: c.id, pending: chat.encode()));
    }
    outbox.addAll(items);
    _changed();
    if (!c.ready) return;
    for (final o in items) {
      await _seal(c, o);
    }
    var next = 0;
    Future<void> worker() async {
      while (next < items.length) {
        final o = items[next++];
        if (outbox.contains(o)) await _dispatch(o);
      }
    }

    await Future.wait([for (var i = 0; i < _parallelChunks; i++) worker()]);
  }

  static const _parallelChunks = 4;

  /// An image or sticker message arrived: get its bytes unless we have them.
  Future<void> _expectMedia(Contact c, MediaRef ref) async {
    if (await hasMedia(ref.id)) return;
    final t = _transfers.putIfAbsent(ref.id, () => _Transfer(c.id, ref.chunks));
    if (t.contactId != c.id || t.total != ref.chunks) {
      _transfers[ref.id] = _Transfer(c.id, ref.chunks)..ref = ref;
    } else {
      t.ref = ref;
      // Early chunks that do not fit the reference are dropped.
      t.parts.removeWhere((i, p) => p.length != _chunkLen(ref, i));
    }
    final tr = _transfers[ref.id]!;
    if (await _tryComplete(tr)) return;
    if (ref.kind != MediaKind.sticker) return;
    // A sticker new to us usually has its bytes right behind it; ask the
    // sender only if none arrive (older versions send the hash only).
    _bg.createTimer(_stickerPushWait, () async {
      if (!_started || await hasMedia(ref.id)) return;
      final t = _transfers[ref.id];
      if (t != null && t.contactId == c.id && t.parts.isEmpty && t.lastRequest == null) await _requestMedia(c, t);
    });
  }

  static const _stickerPushWait = Duration(seconds: 6);

  static int _chunkLen(MediaRef ref, int i) =>
      i < ref.chunks - 1 ? mediaChunkSize : ref.size - mediaChunkSize * (ref.chunks - 1);

  Future<void> _onChunk(Contact c, ChatMsg m) async {
    final h = hex(m.mediaHash!);
    if (await hasMedia(h)) return;
    var t = _transfers[h];
    if (t == null) {
      // Arrived before its image message (paths differ): buffer a few, within
      // the contact's budget.
      if (_transfers.values.where((x) => x.contactId == c.id && x.ref == null).length >= 4) return;
      t = _transfers[h] = _Transfer(c.id, m.chunkTotal);
    }
    if (t.contactId != c.id || m.chunkTotal != t.total) return;
    final ref = t.ref;
    if (ref != null && m.chunkData!.length != _chunkLen(ref, m.chunkIndex)) return;
    final buffered = _transfers.values.where((x) => x.contactId == c.id).fold(0, (n, x) => n + x.buffered);
    if (buffered + m.chunkData!.length > maxBufferedPerContact) return;
    t.parts[m.chunkIndex] = m.chunkData!;
    t.lastActivity = DateTime.now();
    if (!await _tryComplete(t)) _changed();
  }

  Future<bool> _tryComplete(_Transfer t) async {
    final ref = t.ref;
    if (ref == null || t.parts.length < t.total) return false;
    final b = BytesBuilder(copy: false);
    for (var i = 0; i < t.total; i++) {
      b.add(t.parts[i]!);
    }
    final bytes = b.toBytes();
    if (bytes.length != ref.size || !bytesEqual(CryptoSync.sha256(bytes), ref.hash)) {
      log('media ${ref.id.substring(0, 8)} did not match its hash; asking again');
      t.parts.clear();
      return false;
    }
    _transfers.remove(ref.id);
    await _store(ref.id, bytes);
    log('${ref.kind.name} ${ref.id.substring(0, 8)} received (${bytes.length} bytes)');
    _changed();
    // Group members we passed the post on to get the bytes now.
    for (final id in _forwardPending.remove(ref.id) ?? const <String>{}) {
      final c = contacts[id];
      if (c != null) _detach(() => _pushMedia(c, ref.id));
    }
    return true;
  }

  Future<void> _requestMedia(Contact c, _Transfer t) async {
    final ref = t.ref;
    if (ref == null) return;
    t.lastRequest = DateTime.now();
    t.requests++;
    final missing = t.missing;
    final ask = missing.length == t.total ? <int>[] : missing.take(maxRequestIndices).toList();
    await _enqueue(c, ChatMsg(MsgType.mediaRequest, randomBytes(16), mediaHash: ref.hash, indices: ask));
  }

  /// A friend asks for media bytes: answered only for what we sent them, and
  /// rate-limited, so we cannot be used to fetch or flood.
  Future<void> _onMediaRequest(Contact c, ChatMsg m) async {
    final h = hex(m.mediaHash!);
    if (!c.sentMedia.contains(h)) return;
    final now = DateTime.now();
    final key = '${c.id}/$h';
    final last = _lastServed[key];
    if (last != null && now.difference(last) < const Duration(seconds: 10)) return;
    final bytes = await media.read(h);
    if (bytes == null) return;
    final n = m.indices.isEmpty ? chunkCount(bytes.length) : m.indices.length;
    final (start, used) = _servedThisHour[c.id] ?? (now, 0);
    final fresh = now.difference(start) > const Duration(hours: 1);
    final count = (fresh ? 0 : used) + n;
    if (count > maxServedChunksPerHour) {
      log('media request from ${c.name} refused: hourly limit');
      return;
    }
    _servedThisHour[c.id] = (fresh ? now : start, count);
    _lastServed[key] = now;
    log('serving ${h.substring(0, 8)} to ${c.name} ($n chunks)');
    await _sendChunks(c, h, bytes, m.indices);
  }

  /// Requests missing bytes for incomplete media (also after a restart),
  /// with backoff; drops stale buffers.
  Future<void> _mediaMaintenance(DateTime now) async {
    _transfers.removeWhere((_, t) =>
        now.difference(t.lastActivity) > (t.ref == null ? const Duration(minutes: 5) : const Duration(hours: 6)));
    List<Message> recent(List<Message> l) => l.length > 200 ? l.sublist(l.length - 200) : l;
    final wanted = <(Contact, MediaRef)>[
      for (final c in contacts.values)
        if (c.ready) ...[
          for (final msg in recent(c.messages))
            if (!msg.outgoing && msg.media != null) (c, msg.media!),
          if (c.shownAvatar != null) (c, c.shownAvatar!),
        ],
      // Group media come from whoever brought the post.
      for (final g in groups.values)
        if (g.active)
          for (final msg in recent(g.messages))
            if (!msg.outgoing && msg.media != null && (contacts[msg.via]?.ready ?? false)) (contacts[msg.via]!, msg.media!),
    ];
    for (final (c, ref) in wanted) {
      if (await hasMedia(ref.id)) continue;
      final t = _transfers.putIfAbsent(ref.id, () => _Transfer(c.id, ref.chunks)..ref = ref);
      if (t.contactId != c.id || t.requests >= 12) continue;
      final idle = now.difference(t.lastActivity);
      final backoff = Duration(seconds: 15 * (1 << min(t.requests, 6)));
      final lr = t.lastRequest;
      if (idle > const Duration(seconds: 15) && (lr == null || now.difference(lr) > backoff)) {
        await _requestMedia(c, t);
      }
    }
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
    o.inner = Envelope.inner(Envelope.kindRatchet, ct);
    o.pending = null;
    _changed();
  });

  Duration _retryWindow() => switch (settings.delay) {
    DelayMode.fast => timings.retry * 0.7,
    DelayMode.normal => timings.retry,
    DelayMode.paranoid => timings.retry * 1.5,
  };

  /// Sends up to three copies to three different mailbox relays of the
  /// recipient, each over its own onion path. Copies share no bytes: every
  /// relay gets its own mailbox ID and its own envelope nonce.
  Future<int> _dispatch(OutItem o) async {
    final c = contacts[o.contactId];
    if (c == null || o.inner == null || !_started) return 0;
    final now = DateTime.now();
    // In flight: the retry loop must not send it a second time meanwhile.
    o.nextTry = now.add(_retryWindow());
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

    final epoch = mailboxEpochOf(now);
    var sent = 0;
    final copies = <Copy>[];
    Future<Copy?> sendCopy(Credential g) async {
      final relay = node.isSelf(g.relay) ? g.relay : (peers.resolve(g.relay.nodePk) ?? g.relay);
      final mailboxId = await Envelope.mailboxId(c.keys.mboxOut, epoch, relay.nodePk);
      final blob = await Envelope.sealInner(c.keys.envOut, o.inner!);
      final hash = await Crypto.sha256(blob);
      final deleteTag = await Envelope.deleteTag(await Envelope.deleteKey(c.keys.delOut, hash));
      final token = await g.take(hash);
      final ok = await _sendOnion(relay, StoreCmd(mailboxId, token, deleteTag, blob).encode());
      return ok ? Copy(relay, mailboxId, hash) : null;
    }

    // Copies go out in parallel (a dead relay must not hold up the others);
    // failed ones are replaced from the remaining grants.
    var next = 0;
    while (sent < copiesPerMessage && next < grants.length) {
      final batch = grants.sublist(next, min(next + copiesPerMessage - sent, grants.length));
      next += batch.length;
      for (final cp in await Future.wait(batch.map(sendCopy))) {
        if (cp == null) continue;
        sent++;
        copies.add(cp);
      }
    }
    o.attempts++;
    o.copies.addAll(copies);
    o.nextTry = now.add(_retryWindow() * pow(2, min(o.attempts - 1, 5)).toDouble());
    log('${o.handshake ? 'hello' : 'message'} to ${c.name}: $sent/${grants.length} copies stored'
        '${copies.isEmpty ? '' : ' (${copies.map((x) => x.relay.addr).join(', ')})'}');
    if (sent > 0) {
      final m = c.messages.where((m) => m.id == o.id).firstOrNull ?? _groupMessage(o.groupMsg);
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

  /// Per-hop delay range for the current mode, capped so a whole delivery
  /// (hops on the sender's path plus hops on the reply path) stays within
  /// [mixBudgetMs] at any hop count.
  (int, int) get _delayRange {
    final (lo, hi) = switch (settings.delay) {
      DelayMode.fast => (0, 20),
      DelayMode.normal => (50, 250),
      DelayMode.paranoid => (300, 900),
    };
    final cap = mixBudgetMs ~/ (2 * settings.hops);
    return (min(lo, cap), min(hi, cap));
  }

  int _hopDelay() {
    final (lo, hi) = _delayRange;
    return lo + _rng.nextInt(hi - lo + 1);
  }

  int get _maxHopDelay => _delayRange.$2;

  bool _hasKey(RelayInfo r) => node.hopFor(r) != null;

  /// Middle hops are fresh random peers for every packet; [last] is the
  /// destination relay. Only relays with a valid onion-key certificate can
  /// be hops; null if [last] has none.
  List<Hop>? _route(RelayInfo last, {Iterable<Uint8List> exclude = const []}) {
    final end = node.hopFor(last, delayMs: _hopDelay());
    if (end == null) return null;
    // A relay on the internet cannot reach a private address: to a private
    // destination only private hops lead; otherwise private hops go first.
    final lastPublic = peers.isPublic(last);
    final mids = _travelOrder(peers.pick(
      settings.hops - 1,
      exclude: [last.nodePk, identity.node.pub, ...exclude],
      usable: (r) => _hasKey(r) && (lastPublic || !peers.isPublic(r)),
    ));
    return [
      for (final m in mids) node.hopFor(m, delayMs: _hopDelay())!,
      end,
    ];
  }

  /// Orders middle hops in travel direction so that no hop has to reach a
  /// private address from the public internet: private relays first.
  List<RelayInfo> _travelOrder(List<RelayInfo> mids) => [
    ...mids.where((r) => !peers.isPublic(r)),
    ...mids.where(peers.isPublic),
  ];

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
  /// [n] SURBs through fresh random paths ending at our entry relay, or null
  /// if there is no usable entry. Relays on the paths are added to [used].
  Future<List<Surb>?> _makeSurbs(
    RelayInfo target,
    int n,
    ReplyHandler onReply, {
    required Duration ttl,
    List<RelayInfo>? used,
  }) async {
    final entryCands = peers.entryCandidates(exclude: [target.nodePk]);
    var entry = await node.ensureEntry([...entryCands, target]);
    if (entry == null || node.hopFor(entry) == null) return null;
    // Replies travel target -> middle hops -> entry -> us. From a relay on the
    // internet they can only go on to public relays, so a private entry
    // cannot serve a public target: move the entry to a public relay.
    final targetPublic = peers.isPublic(target);
    if (targetPublic && !peers.isPublic(entry)) {
      final better = entryCands.where(peers.isPublic).toList();
      if (better.isEmpty) return null;
      node.dropEntry();
      entry = await node.ensureEntry(better);
      if (entry == null || node.hopFor(entry) == null || !peers.isPublic(entry)) return null;
    }
    final entryPublic = peers.isPublic(entry);
    final surbs = <Surb>[];
    for (var i = 0; i < n; i++) {
      final mids = _travelOrder(peers.pick(
        settings.hops - 1,
        exclude: [target.nodePk, entry.nodePk],
        usable: (r) => _hasKey(r) && (targetPublic ? peers.isPublic(r) : (entryPublic || !peers.isPublic(r))),
      ));
      final hops = [
        for (final m in mids) node.hopFor(m, delayMs: _hopDelay())!,
        node.hopFor(entry, delayMs: _hopDelay())!,
      ];
      used?.addAll(hops.map((h) => h.relay));
      surbs.add(await node.makeSurb(hops, onReply, ttl: ttl));
    }
    return surbs;
  }

  Future<List<ReplyMsg>> _request(
    RelayInfo target,
    int nSurbs,
    Uint8List Function(List<Surb> surbs) build,
  ) async {
    final replies = <ReplyMsg>[];
    final done = Completer<void>();
    final used = <RelayInfo>[];
    final surbs = await _makeSurbs(target, nSurbs, (r) {
      replies.add(r);
      if ((r.last || replies.length >= nSurbs) && !done.isCompleted) done.complete();
    }, ttl: _requestTimeout * 2, used: used);
    if (surbs == null) return [];
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
      for (final id in await Envelope.pollIds(c.keys.mboxIn, now, identity.node.pub)) {
        if (!bytesEqual(id, mailboxId)) continue;
        final rec = mailboxes.values.where((m) => m.own).firstOrNull ??
            MailboxRecord((await node.localRelayInfos()).first, own: true);
        await _pollRelay(rec, [id], {hex(id): c});
        return;
      }
    }
    for (final inv in invites.values.toList()) {
      for (final id in await Envelope.pollIds(inv.keys.mbox, now, identity.node.pub)) {
        if (!bytesEqual(id, mailboxId)) continue;
        _inviteIds[hex(id)] = inv;
        final rec = mailboxes.values.where((m) => m.own).firstOrNull ??
            MailboxRecord((await node.localRelayInfos()).first, own: true);
        await _pollRelay(rec, [id], const {});
        return;
      }
    }
  }

  bool _foreground = true;
  Timer? _pollTimer;

  // --- Watches: standing fetches at our mailbox relays -------------------

  Timer? _watchTimer;
  Timer? _rewatchSoon;
  final Set<String> _watching = {};
  final Map<String, int> _watchSurbsLeft = {};
  static const _relayWatchesPerId = 2;

  Duration get _watchMean => _foreground ? timings.watch : timings.watchBackground;

  Duration get _watchTtl {
    final t = _watchMean * Timings.watchLifetimeFactor;
    return t > maxWatchTtl ? maxWatchTtl : t;
  }

  /// Renews all watches at random (Poisson) times; gaps are capped well below
  /// a watch's lifetime, so watches always overlap. The rate never depends
  /// on whether mail is waiting.
  void _scheduleWatch() {
    _watchTimer?.cancel();
    if (!_started) return;
    final mean = _watchMean.inMilliseconds;
    final ms = (-math.log(1 - _rng.nextDouble()) * mean).round().clamp(mean ~/ 4, mean * 2);
    _watchTimer = Timer(Duration(milliseconds: ms), () {
      unawaited(_renewWatches());
      _scheduleWatch();
    });
  }

  /// Renews soon (debounced): after an entry change, new mailboxes or contacts.
  void _rewatchAll() {
    _rewatchSoon?.cancel();
    _rewatchSoon = Timer(const Duration(milliseconds: 300), () => unawaited(_renewWatches()));
  }

  Future<void> _renewWatches() async {
    if (!_started || (contacts.isEmpty && invites.isEmpty)) return;
    for (final rec in _currentMailboxes()) {
      if (rec.own || node.isSelf(rec.relay)) continue; // own relay: instant path
      unawaited(_watchRelay(rec));
    }
  }

  Future<void> _watchRelay(MailboxRecord rec) async {
    final k = rec.relay.id;
    if (!_watching.add(k)) return;
    try {
      final ttl = _watchTtl;
      final (ids, idMap) = await _idsFor(rec.relay.nodePk, DateTime.now());
      if (ids.isEmpty) return;
      var total = 0;
      for (final chunk in fetchBatches(ids)) {
        final surbs = await _makeSurbs(
          rec.relay,
          fetchSurbs,
          (r) => _onWatchReply(rec, r, idMap),
          ttl: ttl + _requestTimeout,
        );
        if (surbs == null) return;
        if (await _sendOnion(rec.relay, WatchCmd(ttl, surbs, chunk).encode())) total += surbs.length;
      }
      // The relay keeps the newest [_relayWatchesPerId] watches per mailbox.
      _watchSurbsLeft[k] = min((_watchSurbsLeft[k] ?? 0) + total, _relayWatchesPerId * fetchSurbs);
    } catch (e) {
      log('watch ${rec.relay.addr} failed: $e');
    } finally {
      _watching.remove(k);
    }
  }

  void _onWatchReply(MailboxRecord rec, ReplyMsg r, Map<String, Contact> idMap) {
    final k = rec.relay.id;
    if (r.partners.isNotEmpty) rec.partners = r.partners;
    rec.failures = 0;
    final left = (_watchSurbsLeft[k] ?? 1) - 1;
    _watchSurbsLeft[k] = left;
    // Replenish while one batch of SURBs is still left (jittered): the relay
    // holds two watches, so a burst (an image's chunks) drains through the
    // next batch instead of waiting a round trip for it.
    if (left <= fetchSurbs) {
      Timer(Duration(milliseconds: 200 + _rng.nextInt(1000)), () => unawaited(_watchRelay(rec)));
    }
    if (r.type != Reply.blob) return;
    unawaited(() async {
      final del = await _receive(r.blob!, r.mailboxId!, idMap);
      if (del == null) return;
      log('watch got 1 from ${rec.relay.addr}');
      await _sendOnion(rec.relay, DeleteCmd([del]).encode());
    }());
  }

  /// Foreground polls more often. The rate never depends on whether mail is
  /// waiting, so it reveals nothing about messages.
  void setForeground(bool fg) {
    if (fg == _foreground) return;
    _foreground = fg;
    if (fg) unawaited(pollNow());
    _schedulePoll();
    // Watch lifetimes depend on the mode: renew now with the new one.
    _rewatchAll();
    _scheduleWatch();
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
      if (contacts.isEmpty && invites.isEmpty) return;
      final now = DateTime.now();
      for (final rec in mailboxes.values.toList()) {
        final k = rec.relay.id;
        if (_pollingRelays.contains(k)) continue;
        if (_nextPoll[k]?.isAfter(now) ?? false) continue;
        _pollingRelays.add(k);
        unawaited(() async {
          // Mailbox IDs are per relay.
          final (ids, idMap) = await _idsFor(rec.relay.nodePk, now);
          await _pollRelay(rec, ids, idMap);
        }()
            .catchError((Object e) {
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

  /// Every contact's mailbox IDs on one relay, and which contact owns each.
  Future<(List<Uint8List>, Map<String, Contact>)> _idsFor(Uint8List relayPk, DateTime now) async {
    final idMap = <String, Contact>{};
    for (final c in contacts.values) {
      for (final id in await Envelope.pollIds(c.keys.mboxIn, now, relayPk)) {
        idMap[hex(id)] = c;
      }
    }
    final inviteIds = <Uint8List>[];
    for (final inv in invites.values) {
      if (inv.expiredAt(now)) continue;
      for (final id in await Envelope.pollIds(inv.keys.mbox, now, relayPk)) {
        _inviteIds[hex(id)] = inv;
        inviteIds.add(id);
      }
    }
    return ([for (final k in idMap.keys) unhex(k), ...inviteIds], idMap);
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
        // Stopped: replies still in flight are left on the relays.
        if (!_started) return null;
        final c = idMap[hex(mailboxId)];
        if (c == null) {
          final inv = _inviteIds[hex(mailboxId)];
          return inv == null ? null : _onJoin(inv, mailboxId, blob);
        }
        // Delete key for this copy: bound to its own blob hash.
        final hash = await Crypto.sha256(blob);
        final del = DeleteEntry(mailboxId, hash, await Envelope.deleteKey(c.keys.delIn, hash));

        final opened = await Envelope.open(c.keys.envIn, blob);
        if (opened == null) return null;
        final (kind, content) = opened;
        // The inviter answered: our join request has arrived.
        if (c.pendingJoin != null) c.pendingJoin = null;

        // Dedup on the inner content, before the ratchet: every relay copy
        // has a different envelope, so the blob hash cannot be used.
        final hk = hex(await Crypto.sha256(Envelope.inner(kind, content)));
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
          final Uint8List plain;
          try {
            plain = await c.ratchet!.decrypt(content, ad: _ad(c));
          } catch (e) {
            // Not for this session: a replay, garbage, or a message for the
            // device this identity was restored on. Never delete what we
            // cannot read: it may be someone else's to read.
            if (_undecryptable.length > 5000) _undecryptable.clear();
            if (_undecryptable.add(hk)) log('could not decrypt a message from ${c.name}; left on the relay');
            return null;
          }
          if (!c.keys.initiator && !c.peerConfirmed) {
            c.peerConfirmed = true;
            c.kemCt = null;
          }
          try {
            final msg = ChatMsg.decode(plain);
            msgId = hex(msg.id);
            await _onChat(c, msg);
          } catch (e) {
            // Decrypted (the ratchet moved on), but not understood: a newer
            // version's message type, or a bad one. Done with it; a receipt
            // (every message starts with type and ID) stops the resending.
            log('could not read a message from ${c.name}: $e');
            if (msgId == null && plain.length >= 17 && plain[0] != MsgType.receipt.index + 1) {
              msgId = hex(plain.sublist(1, 17));
              _queueReceipt(c, plain.sublist(1, 17));
            }
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
          replyTo: m.replyTo == null ? null : hex(m.replyTo!),
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
        _detach(() => _sendControl(c, MsgType.update));
      case MsgType.image || MsgType.sticker:
        final id = hex(m.id);
        if (c.messages.any((x) => x.id == id)) return;
        final msg = Message(
          id: id,
          outgoing: false,
          text: m.text,
          time: DateTime.now(),
          sentAt: DateTime.fromMillisecondsSinceEpoch(m.timestamp),
          status: MsgStatus.delivered,
          media: m.media,
          replyTo: m.replyTo == null ? null : hex(m.replyTo!),
        );
        c.messages.add(msg);
        c.unread++;
        onIncoming?.call(c, msg);
        log('${m.media!.kind.name} ${m.media!.id.substring(0, 8)} announced by ${c.name} (${m.media!.chunks} chunks)');
        _detach(() => _expectMedia(c, m.media!));
      case MsgType.mediaChunk:
        await _onChunk(c, m);
      case MsgType.mediaRequest:
        _detach(() => _onMediaRequest(c, m));
      case MsgType.avatar:
        c.theirAvatar = m.media;
        _changed();
        if (m.media != null) _detach(() => _expectMedia(c, m.media!));
      case MsgType.reaction:
        final msg = c.messages.where((x) => x.id == hex(m.target!)).firstOrNull;
        if (msg != null && msg.react(c.id, m.text, m.timestamp)) _changed();
      case MsgType.groupInvite:
        await _onGroupInvite(c, m.payload!);
      case MsgType.groupJoin:
        await _onGroupJoin(c, m.payload!);
      case MsgType.groupLeave:
        await _onGroupLeave(c, m.payload!);
      case MsgType.groupRoster:
        await _onGroupRoster(c, m.payload!);
      case MsgType.groupPost:
        await _onGroupPost(c, m.payload!);
    }
  }

  Future<void> _onReceipt(Contact c, String id) async {
    final i = outbox.indexWhere((o) => o.id == id && o.contactId == c.id);
    final msg = c.messages.where((m) => m.id == id).firstOrNull;
    if (msg != null) msg.status = MsgStatus.delivered;
    if (i < 0) return;
    final o = outbox.removeAt(i);
    // A group post is delivered once every member it went to has it.
    final gm = o.groupMsg;
    if (gm != null && !outbox.any((x) => x.groupMsg == gm)) _groupMessage(gm)?.status = MsgStatus.delivered;
    // Ask the relays to drop the remaining copies early.
    final byRelay = <String, (RelayInfo, List<DeleteEntry>)>{};
    for (final cp in o.copies) {
      final h = cp.hash;
      if (h == null) continue;
      final key = await Envelope.deleteKey(c.keys.delOut, h);
      byRelay.putIfAbsent(cp.relay.key, () => (cp.relay, [])).$2.add(DeleteEntry(cp.mailboxId, h, key));
    }
    for (final (r, entries) in byRelay.values) {
      unawaited(_sendOnion(r, DeleteCmd(entries).encode()));
    }
  }

  void _queueReceipt(Contact c, Uint8List msgId) {
    final list = _pendingReceipts.putIfAbsent(c.id, () => []);
    list.add(msgId);
    if (list.length == 1) {
      _bg.createTimer(const Duration(milliseconds: 300), () {
        final ids = _pendingReceipts.remove(c.id) ?? [];
        if (ids.isEmpty) return;
        for (var i = 0; i < ids.length; i += 200) {
          final part = ids.sublist(i, min(i + 200, ids.length));
          _detach(() => _sendControl(c, MsgType.receipt, receipts: part));
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
      _pruneInvites(now);
      await _mediaMaintenance(now);
      await _refreshMailboxes();
      for (final c in contacts.values.toList()) {
        await _handshakeTick(c);
        if (!c.ready) continue;
        await _syncAvatar(c);
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
      // Nothing reachable: walk the whole relay history until one answers,
      // in random order, small jittered batches, backing off while it fails.
      if (peers.pick(1).isEmpty && peers.known.isNotEmpty) {
        if (!now.isBefore(_nextResort)) {
          _nextResort = now.add(resortDelay(_resortRound++, _rng));
          for (final r in peers.lastResort(PeerManager.maxResortBatch)) {
            _jittered(() => node.ping(r));
          }
        }
      } else {
        _resortRound = 0;
        _nextResort = now;
      }
      await _syncRelaysIfChanged();
      // Keep hop candidates verified: a ping is a real connection attempt
      // and updates peer health through onLinkResult.
      for (final r in peers.toProbe(4)) {
        _jittered(() => node.ping(r));
      }
      // Re-confirm onion keys of a couple of peers we have not heard from
      // directly for a while (catches relays that restarted unseen).
      final stale = peers.activeRelays.where((r) {
        final t = node.certs.confirmed[r.id];
        return t == null || now.difference(t) > const Duration(minutes: 10);
      }).toList()
        ..shuffle(_rng);
      for (final r in stale.take(2)) {
        _jittered(() => node.ping(r));
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
      if (o.inner == null || o.nextTry.isAfter(now)) continue;
      if (!outbox.contains(o)) continue;
      await _dispatch(o);
    }
  }

  int _resortRound = 0;
  DateTime _nextResort = DateTime.fromMillisecondsSinceEpoch(0);

  /// Delay before the next last-resort batch: 5 s doubling to 5 min, ±20%.
  static Duration resortDelay(int round, Random rng) {
    final base = 5000 * (1 << round.clamp(0, 6));
    final capped = base > 300000 ? 300000 : base;
    return Duration(milliseconds: (capped * (0.8 + 0.4 * rng.nextDouble())).round());
  }

  /// Runs a probe after a random delay (up to 2 s), so probes do not line up
  /// with the maintenance tick.
  void _jittered(Future<Object?> Function() probe) {
    Timer(Duration(milliseconds: _rng.nextInt(2000)), () {
      if (_started) unawaited(probe());
    });
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
