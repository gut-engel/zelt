import 'dart:typed_data';

import 'bytes.dart';
import 'crypto.dart';

/// Rotating onion keys.
///
/// A relay's long-term identity is an Ed25519 key (`RelayInfo.nodePk`). It
/// never peels onions. Onion layers are encrypted to short-lived X25519 keys
/// that exist only in the relay's RAM, each published in a certificate signed
/// by the identity:
///
///   cert = relayPk(32) keyId(1) onionPk(32) validFrom(u32) validUntil(u32) sig(64)
///   sig  = Ed25519(identity, "zelt/onion-key/v2" ‖ relayPk ‖ keyId ‖ onionPk ‖ from ‖ until)
///
/// Times are unix minutes. A restart creates fresh keys and forgets the old
/// ones, so a recorded packet can never be replayed to, or peeled by, that
/// relay later.
const Duration onionKeyLifetime = Duration(hours: 24);
const Duration onionKeyOverlap = Duration(hours: 2);

/// Senders stop using a key this long before it expires (in-flight margin).
const Duration onionKeyUseMargin = Duration(minutes: 10);

/// Replay tags kept per key. The set never evicts (eviction would re-enable
/// replays); when it is full the key retires early and a new one takes over.
/// Memory per key is fixed: a 2^19-slot table of 8-byte entries = 4 MiB.
const int maxReplayTagsPerKey = 250000;

int _minutes(DateTime t) => t.millisecondsSinceEpoch ~/ 60000;
DateTime _fromMinutes(int m) => DateTime.fromMillisecondsSinceEpoch(m * 60000);

class OnionKeyCert {
  final Uint8List relayPk;
  final int keyId;
  final Uint8List onionPk;
  final DateTime validFrom;
  final DateTime validUntil;
  final Uint8List sig;

  OnionKeyCert(this.relayPk, this.keyId, this.onionPk, this.validFrom, this.validUntil, this.sig);

  static const encodedSize = 32 + 1 + 32 + 4 + 4 + 64;

  static Uint8List _message(Uint8List relayPk, int keyId, Uint8List onionPk, DateTime from, DateTime until) =>
      (ByteWriter()
            ..str('zelt/onion-key/v2')
            ..bytes(relayPk)
            ..u8(keyId)
            ..bytes(onionPk)
            ..u32(_minutes(from))
            ..u32(_minutes(until)))
          .toBytes();

  static Future<OnionKeyCert> sign(SigningKey identity, int keyId, Uint8List onionPk, DateTime from, DateTime until) async {
    final sig = await Crypto.ed25519Sign(identity, _message(identity.pub, keyId, onionPk, from, until));
    return OnionKeyCert(identity.pub, keyId, onionPk, _fromMinutes(_minutes(from)), _fromMinutes(_minutes(until)), sig);
  }

  Future<bool> verify() => Crypto.ed25519Verify(relayPk, _message(relayPk, keyId, onionPk, validFrom, validUntil), sig);

  /// Usable by a sender at [now]: started, and not about to expire.
  bool usableAt(DateTime now) => !now.isBefore(validFrom) && now.isBefore(validUntil.subtract(onionKeyUseMargin));

  bool expiredAt(DateTime now) => !now.isBefore(validUntil);

  Uint8List encode() => (ByteWriter()
        ..bytes(relayPk)
        ..u8(keyId)
        ..bytes(onionPk)
        ..u32(_minutes(validFrom))
        ..u32(_minutes(validUntil))
        ..bytes(sig))
      .toBytes();

  static OnionKeyCert decode(ByteReader r) => OnionKeyCert(
    r.bytes(32),
    r.u8(),
    r.bytes(32),
    _fromMinutes(r.u32()),
    _fromMinutes(r.u32()),
    r.bytes(64),
  );

  String get relayId => hex(relayPk);

  Map<String, dynamic> toJson() => {'c': b64(encode())};
  factory OnionKeyCert.fromJson(Map<String, dynamic> j) => decode(ByteReader(unb64(j['c'])));
}

/// Per-key replay tags: an open-addressing hash set of 64-bit values in one
/// fixed [Uint64List], kept at most half full. Never evicts.
class ReplayFilter {
  final int max;
  final Uint64List _slots;
  final int _mask;
  int _size = 0;

  ReplayFilter({this.max = maxReplayTagsPerKey})
    : _slots = Uint64List(_capacityFor(max)),
      _mask = _capacityFor(max) - 1;

  static int _capacityFor(int max) {
    var c = 16;
    while (c < max * 2) {
      c <<= 1;
    }
    return c;
  }

  int get size => _size;
  bool get full => _size >= max;

  /// True if the tag is new (and records it). The first 8 tag bytes are
  /// kept: a false "replay" for a fresh packet has probability n / 2^64.
  bool checkAndAdd(Uint8List tag) {
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | tag[i];
    }
    if (v == 0) v = 1; // 0 marks an empty slot
    // The tag bytes are uniformly random (HKDF output), so they index well.
    var i = (v ^ (v >>> 29)) & _mask;
    while (true) {
      final cur = _slots[i];
      if (cur == 0) break;
      if (cur == v) return false;
      i = (i + 1) & _mask;
    }
    if (full) return false;
    _slots[i] = v;
    _size++;
    return true;
  }
}

class _LiveKey {
  final int id;
  final KeyPair25519 kp;
  final OnionKeyCert cert;
  final ReplayFilter replay;
  _LiveKey(this.id, this.kp, this.cert, int maxTags) : replay = ReplayFilter(max: maxTags);
}

/// Relay side: the live onion keys, in RAM only.
class OnionKeyring {
  final SigningKey identity;
  final int maxTags;
  final List<_LiveKey> _keys = [];
  void Function()? onRotate;

  OnionKeyring(this.identity, {this.maxTags = maxReplayTagsPerKey});

  List<OnionKeyCert> get certs => [for (final k in _keys) k.cert];

  /// The key senders should use now.
  OnionKeyCert? get currentCert {
    final t = DateTime.now();
    OnionKeyCert? best;
    for (final k in _keys) {
      if (k.cert.usableAt(t) && (best == null || k.cert.validFrom.isAfter(best.validFrom))) best = k.cert;
    }
    return best;
  }

  /// Keeps one key valid now and its successor published ahead; drops
  /// expired keys together with their replay sets. Call periodically.
  Future<void> maintain({DateTime? now}) async {
    final t = now ?? DateTime.now();
    final before = _keys.length;
    _keys.removeWhere((k) => k.cert.expiredAt(t) || k.replay.full);
    var changed = _keys.length != before;
    _LiveKey? current;
    for (final k in _keys) {
      if (!t.isBefore(k.cert.validFrom) && (current == null || k.cert.validFrom.isAfter(current.cert.validFrom))) {
        current = k;
      }
    }
    if (current == null) {
      current = await _add(t);
      changed = true;
    }
    final nextFrom = current.cert.validFrom.add(onionKeyLifetime);
    if (!_keys.any((k) => !k.cert.validFrom.isBefore(nextFrom))) {
      await _add(nextFrom);
      changed = true;
    }
    if (changed) onRotate?.call();
  }

  Future<_LiveKey> _add(DateTime from) async {
    final used = {for (final k in _keys) k.id};
    var id = randomInt(256);
    while (used.contains(id)) {
      id = (id + 1) % 256;
    }
    final kp = KeyPair25519.generateSync();
    final cert = await OnionKeyCert.sign(identity, id, kp.pub, from, from.add(onionKeyLifetime + onionKeyOverlap));
    final k = _LiveKey(id, kp, cert, maxTags);
    _keys.add(k);
    return k;
  }

  /// The private key and replay set for a key ID, if that key is live.
  (KeyPair25519, ReplayFilter)? lookup(int keyId) {
    for (final k in _keys) {
      if (k.id == keyId) return (k.kp, k.replay);
    }
    return null;
  }

  /// Forgets every key (clean shutdown).
  void wipe() => _keys.clear();
}

/// Client side: verified certificates of other relays.
class CertStore {
  final Map<String, List<OnionKeyCert>> _byRelay = {};

  /// When each relay last pushed its key set to us directly.
  final Map<String, DateTime> confirmed = {};

  /// Verifies and stores; returns true if [c] was new and valid.
  Future<bool> add(OnionKeyCert c, {DateTime? now}) async {
    final t = now ?? DateTime.now();
    if (c.expiredAt(t)) return false;
    final list = _byRelay.putIfAbsent(c.relayId, () => []);
    if (list.any((x) => bytesEqual(x.encode(), c.encode()))) return false;
    if (!await c.verify()) return false;
    list.add(c);
    list.removeWhere((x) => x.expiredAt(t));
    return true;
  }

  /// The relay itself sent its complete set of live keys (over an
  /// authenticated link): replace what we had, which drops keys a restart
  /// destroyed. Returns true if anything changed.
  Future<bool> replaceFor(Uint8List relayPk, List<OnionKeyCert> certs, {DateTime? now}) async {
    final t = now ?? DateTime.now();
    final fresh = <OnionKeyCert>[];
    for (final c in certs) {
      if (!bytesEqual(c.relayPk, relayPk) || c.expiredAt(t)) continue;
      if (await c.verify()) fresh.add(c);
    }
    if (fresh.isEmpty) return false;
    confirmed[hex(relayPk)] = t;
    final old = _byRelay[hex(relayPk)] ?? const <OnionKeyCert>[];
    final same = old.length == fresh.length && old.every((o) => fresh.any((f) => bytesEqual(f.encode(), o.encode())));
    _byRelay[hex(relayPk)] = fresh;
    return !same;
  }

  /// The newest certificate usable at [now] for this relay.
  OnionKeyCert? best(Uint8List relayPk, {DateTime? now}) {
    final t = now ?? DateTime.now();
    OnionKeyCert? best;
    for (final c in _byRelay[hex(relayPk)] ?? const <OnionKeyCert>[]) {
      if (!c.usableAt(t)) continue;
      if (best == null || c.validFrom.isAfter(best.validFrom)) best = c;
    }
    return best;
  }

  List<OnionKeyCert> of(Uint8List relayPk) => List.of(_byRelay[hex(relayPk)] ?? const []);

  void prune({DateTime? now}) {
    final t = now ?? DateTime.now();
    for (final l in _byRelay.values) {
      l.removeWhere((c) => c.expiredAt(t));
    }
    _byRelay.removeWhere((_, l) => l.isEmpty);
  }

  List<Map<String, dynamic>> toJson() => [for (final l in _byRelay.values) for (final c in l) c.toJson()];

  /// Loads persisted certificates (already verified when first stored).
  void loadJson(List<dynamic> j) {
    for (final e in j) {
      final c = OnionKeyCert.fromJson(e as Map<String, dynamic>);
      _byRelay.putIfAbsent(c.relayId, () => []).add(c);
    }
    prune();
  }
}
