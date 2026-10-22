import 'dart:math';
import 'dart:typed_data';

import 'address.dart';
import 'bytes.dart';
import 'constants.dart';

class PeerRecord {
  RelayInfo relay;

  /// Where we learned about it: a contact id, "dht" or "manual".
  final Set<String> sources;
  final DateTime firstSeen;
  DateTime? lastOk;
  DateTime? lastFail;
  int failures;

  PeerRecord(
    this.relay,
    this.sources, {
    DateTime? firstSeen,
    this.lastOk,
    this.lastFail,
    this.failures = 0,
  }) : firstSeen = firstSeen ?? DateTime.now();

  String get primarySource => sources.isEmpty ? '?' : (sources.toList()..sort()).first;

  bool get healthy {
    if (failures < 3) return true;
    // Give failing peers another chance after a cool-down.
    final lf = lastFail;
    return lf == null || DateTime.now().difference(lf) > Duration(minutes: 5 * failures);
  }

  Map<String, dynamic> toJson() => {
    'r': relay.toJson(),
    's': sources.toList(),
    'f': firstSeen.millisecondsSinceEpoch,
    if (lastOk != null) 'ok': lastOk!.millisecondsSinceEpoch,
    if (lastFail != null) 'lf': lastFail!.millisecondsSinceEpoch,
    'n': failures,
  };

  factory PeerRecord.fromJson(Map<String, dynamic> j) => PeerRecord(
    RelayInfo.fromJson(j['r']),
    {...(j['s'] as List).cast<String>()},
    firstSeen: DateTime.fromMillisecondsSinceEpoch(j['f']),
    lastOk: j['ok'] == null ? null : DateTime.fromMillisecondsSinceEpoch(j['ok']),
    lastFail: j['lf'] == null ? null : DateTime.fromMillisecondsSinceEpoch(j['lf']),
    failures: j['n'] ?? 0,
  );
}

/// Holds up to [targetPeers] active peers, filled from friends first and the
/// DHT second, with the diversity rule: no single source or IP range may
/// supply more than a few peers, and a few long-lived peers stay put while
/// the rest rotate slowly.
class PeerManager {
  final Map<String, PeerRecord> known = {};
  List<String> active = [];
  bool lowDiversity = false;
  DateTime _lastRotate = DateTime.now();
  final Random _rng = Random.secure();

  /// Our own node key, never used as a hop.
  Uint8List? selfPk;

  /// Accept loopback relay addresses (tests and single-machine setups only).
  bool allowLoopback = false;

  void add(RelayInfo r, String source) {
    if (selfPk != null && bytesEqual(r.nodePk, selfPk!)) return;
    // A loopback or link-local address from another device can never work.
    if (!allowLoopback && (r.addr.ip.isLoopback || r.addr.ip.isLinkLocal)) return;
    final rec = known[r.key];
    if (rec != null) {
      rec.sources.add(source);
    } else {
      known[r.key] = PeerRecord(r, {source});
    }
  }

  /// A contact was deleted: its relays lose that source but stay in the
  /// history, so we never run out of relays to try.
  void removeSource(String source) {
    for (final rec in known.values) {
      final had = rec.sources.remove(source) | rec.sources.remove('via:$source');
      if (had && rec.sources.isEmpty) rec.sources.add('history');
    }
  }

  int _resortCursor = 0;

  /// Relays to probe when nothing is reachable: walks the whole history,
  /// ignoring failure cool-downs, a few at a time.
  List<RelayInfo> lastResort(int n) {
    final all = known.values.toList();
    if (all.isEmpty) return [];
    final out = <RelayInfo>[];
    for (var i = 0; i < n && i < all.length; i++) {
      out.add(all[(_resortCursor + i) % all.length].relay);
    }
    _resortCursor = (_resortCursor + n) % all.length;
    return out;
  }

  /// Relays worth telling friends about: reached recently, not loopback.
  List<RelayInfo> shareable(int max) {
    final good = known.values.where((r) => r.lastOk != null && r.healthy).toList()
      ..sort((a, b) => b.lastOk!.compareTo(a.lastOk!));
    final seen = <String>{};
    return [
      for (final r in good)
        if (seen.add(r.relay.id) && (allowLoopback || !r.relay.addr.ip.isLoopback)) r.relay,
    ].take(max).toList();
  }

  void markOk(RelayInfo r) {
    final rec = known[r.key];
    if (rec == null) return;
    rec.lastOk = DateTime.now();
    rec.failures = 0;
  }

  void markFail(RelayInfo r) {
    final rec = known[r.key];
    if (rec == null) return;
    rec.failures++;
    rec.lastFail = DateTime.now();
    if (!rec.healthy) active.remove(r.key);
  }

  List<RelayInfo> get activeRelays => [for (final k in active) known[k]!.relay];

  /// Best known address for a node key (healthy and recently used first).
  RelayInfo? resolve(Uint8List nodePk) {
    PeerRecord? best;
    for (final r in known.values) {
      if (!bytesEqual(r.relay.nodePk, nodePk)) continue;
      if (best == null || _score(r) > _score(best)) best = r;
    }
    return best?.relay;
  }

  int _score(PeerRecord r) =>
      (r.healthy ? 1 << 40 : 0) + (r.lastOk?.millisecondsSinceEpoch ?? 0) ~/ 1000;

  /// Recomputes the active set. Keeps anchors and current members, rotates
  /// one non-anchor at most once per [rotateEvery]. The diversity rule is
  /// only relaxed when it would leave fewer than [minRequired] peers, i.e.
  /// not enough to build a route at all (early network).
  void refresh({
    Duration rotateEvery = const Duration(hours: 1),
    int minRequired = defaultHops,
  }) {
    active.removeWhere((k) => !(known[k]?.healthy ?? false));

    // One active entry per node key, even if it has several addresses.
    final seenPk = <String>{};
    active = [
      for (final k in active)
        if (seenPk.add(known[k]!.relay.id)) k,
    ];

    final anchors = (known.values.where((r) => r.healthy && r.lastOk != null).toList()
          ..sort((a, b) => a.firstSeen.compareTo(b.firstSeen)))
        .take(anchorPeers)
        .map((r) => r.relay.key)
        .toSet();

    if (DateTime.now().difference(_lastRotate) > rotateEvery &&
        active.length >= targetPeers) {
      final rotatable = active.where((k) => !anchors.contains(k)).toList();
      if (rotatable.isNotEmpty) {
        active.remove(rotatable[_rng.nextInt(rotatable.length)]);
      }
      _lastRotate = DateTime.now();
    }

    for (final a in anchors) {
      if (!active.contains(a) && seenPk.add(known[a]!.relay.id)) active.add(a);
    }

    lowDiversity = false;
    _fill(seenPk, strict: true);
    if (active.length < minRequired) {
      final before = active.length;
      _fill(seenPk, strict: false);
      lowDiversity = active.length > before;
    }
  }

  void _fill(Set<String> seenPk, {required bool strict}) {
    final perSource = <String, int>{};
    final perRange = <String, int>{};
    for (final k in active) {
      final r = known[k]!;
      perSource.update(r.primarySource, (v) => v + 1, ifAbsent: () => 1);
      perRange.update(r.relay.addr.range, (v) => v + 1, ifAbsent: () => 1);
    }
    // Friends first, then the DHT and manual entries.
    final cands = known.values
        .where((r) => r.healthy && !active.contains(r.relay.key) && !seenPk.contains(r.relay.id))
        .toList()
      ..shuffle(_rng)
      ..sort((a, b) => _rank(a).compareTo(_rank(b)));
    for (final c in cands) {
      if (active.length >= targetPeers) break;
      if (seenPk.contains(c.relay.id)) continue;
      final s = c.primarySource;
      final g = c.relay.addr.range;
      if (strict &&
          ((perSource[s] ?? 0) >= maxPeersPerSource ||
              (perRange[g] ?? 0) >= maxPeersPerRange)) {
        continue;
      }
      active.add(c.relay.key);
      seenPk.add(c.relay.id);
      perSource[s] = (perSource[s] ?? 0) + 1;
      perRange[g] = (perRange[g] ?? 0) + 1;
    }
  }

  int _rank(PeerRecord r) {
    bool direct(String s) => s != 'dht' && s != 'manual' && s != 'history' && !s.startsWith('via:');
    if (r.sources.any(direct)) return 0;
    if (r.sources.contains('manual')) return 1;
    if (r.sources.any((s) => s.startsWith('via:'))) return 2;
    return 3;
  }

  /// Verified: we connected to it recently and it has not failed since.
  /// Only verified peers become hops; an unreachable hop silently eats
  /// packets and, worse, replies.
  bool verified(PeerRecord r) {
    final ok = r.lastOk;
    if (ok == null || r.failures > 0) return false;
    return DateTime.now().difference(ok) < verifiedFor;
  }

  Duration verifiedFor = const Duration(minutes: 30);

  final Map<String, DateTime> _lastProbe = {};

  /// Relays that need a reachability check: unverified active peers first,
  /// then any other known relay not probed within [reprobe].
  List<RelayInfo> toProbe(int n, {Duration reprobe = const Duration(minutes: 10)}) {
    final now = DateTime.now();
    bool due(PeerRecord r) {
      final t = _lastProbe[r.relay.key];
      return t == null || now.difference(t) > reprobe;
    }
    final out = <PeerRecord>[
      for (final k in active)
        if (!verified(known[k]!) && due(known[k]!)) known[k]!,
    ];
    final rest = known.values.where((r) => !active.contains(r.relay.key) && !verified(r) && r.healthy && due(r)).toList()
      ..sort((a, b) => _rank(a).compareTo(_rank(b)));
    out.addAll(rest);
    final pickd = out.take(n).toList();
    for (final r in pickd) {
      _lastProbe[r.relay.key] = now;
    }
    return [for (final r in pickd) r.relay];
  }

  /// [n] distinct random verified active peers, none of them in [exclude].
  List<RelayInfo> pick(int n, {Iterable<Uint8List> exclude = const []}) {
    final ex = {for (final e in exclude) hex(e)};
    final pool = [
      for (final k in active)
        if (verified(known[k]!) && !ex.contains(known[k]!.relay.id)) known[k]!.relay,
    ]..shuffle(_rng);
    return pool.take(n).toList();
  }

  /// Candidates to try as a first contact (entry relay), verified first.
  List<RelayInfo> entryCandidates({Iterable<Uint8List> exclude = const []}) {
    final ex = {for (final e in exclude) hex(e)};
    final all = [for (final k in active) known[k]!]..removeWhere((r) => ex.contains(r.relay.id));
    all.sort((a, b) => (verified(b) ? 1 : 0) - (verified(a) ? 1 : 0));
    return [for (final r in all) r.relay];
  }

  Map<String, dynamic> toJson() => {
    'known': [for (final r in known.values) r.toJson()],
    'active': active,
  };

  void loadJson(Map<String, dynamic> j) {
    known.clear();
    for (final r in (j['known'] as List? ?? [])) {
      final rec = PeerRecord.fromJson(r);
      final ip = rec.relay.addr.ip;
      if (!allowLoopback && (ip.isLoopback || ip.isLinkLocal)) continue;
      known[rec.relay.key] = rec;
    }
    active = [
      for (final k in (j['active'] as List? ?? []).cast<String>())
        if (known.containsKey(k)) k,
    ];
  }
}
