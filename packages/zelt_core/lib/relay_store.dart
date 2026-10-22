import 'dart:collection';
import 'dart:typed_data';

import 'bytes.dart';
import 'constants.dart';
import 'crypto.dart';

enum BlobPool { contact, public, handoff }

class StoredBlob {
  final Uint8List mailboxId;
  final Uint8List blob;
  final Uint8List hash;
  final Uint8List deleteTag;
  final int slot;
  final BlobPool pool;
  final DateTime expiresAt;

  StoredBlob(
    this.mailboxId,
    this.blob,
    this.hash,
    this.deleteTag,
    this.slot,
    this.pool,
    this.expiresAt,
  );

  int get size => blob.length;
}

/// RAM-only mailbox store. Nothing here is ever written to disk.
///
/// Rules: hard cap [relayCapBytes]; per-slot quota; separate caps for the
/// public and handoff pools; TTL expiry; when a cap is hit the oldest blobs
/// in that scope are dropped first.
class RelayStore {
  final int capBytes;
  final Duration ttl;

  // Insertion order == age order.
  final LinkedHashMap<String, StoredBlob> _byHash = LinkedHashMap();
  final Map<String, Set<String>> _byMailbox = {};
  final Map<int, int> _slotBytes = {};
  final Map<BlobPool, int> _poolBytes = {};
  int _total = 0;

  RelayStore({this.capBytes = relayCapBytes, this.ttl = relayTtl});

  int get totalBytes => _total;
  int get count => _byHash.length;
  int get mailboxCount => _byMailbox.length;

  int _slotQuota(int slot) =>
      slot >= firstPublicSlot ? publicSlotQuotaBytes : slotQuotaBytes;

  bool store({
    required Uint8List mailboxId,
    required Uint8List blob,
    required Uint8List deleteTag,
    required int slot,
    BlobPool pool = BlobPool.contact,
    DateTime? expiresAt,
  }) {
    expire();
    final hash = Crypto.sha256Sync(blob);
    final hk = hex(hash);
    if (_byHash.containsKey(hk)) return true;
    final b = StoredBlob(
      Uint8List.fromList(mailboxId),
      Uint8List.fromList(blob),
      hash,
      Uint8List.fromList(deleteTag),
      slot,
      pool,
      expiresAt ?? DateTime.now().add(ttl),
    );
    _byHash[hk] = b;
    _byMailbox.putIfAbsent(hex(mailboxId), () => {}).add(hk);
    _slotBytes[slot] = (_slotBytes[slot] ?? 0) + b.size;
    _poolBytes[pool] = (_poolBytes[pool] ?? 0) + b.size;
    _total += b.size;

    _dropOldestWhile(
      () => (_slotBytes[slot] ?? 0) > _slotQuota(slot),
      (x) => x.slot == slot,
    );
    if (pool == BlobPool.public) {
      _dropOldestWhile(
        () => (_poolBytes[BlobPool.public] ?? 0) > publicTotalQuotaBytes,
        (x) => x.pool == BlobPool.public,
      );
    }
    if (pool == BlobPool.handoff) {
      _dropOldestWhile(
        () => (_poolBytes[BlobPool.handoff] ?? 0) > handoffQuotaBytes,
        (x) => x.pool == BlobPool.handoff,
      );
    }
    _dropOldestWhile(() => _total > capBytes, (_) => true);
    return _byHash.containsKey(hk);
  }

  void _dropOldestWhile(bool Function() over, bool Function(StoredBlob) match) {
    while (over()) {
      final victim = _byHash.entries.firstWhere(
        (e) => match(e.value),
        orElse: () => throw StateError('quota accounting broken'),
      );
      _remove(victim.key);
    }
  }

  void _remove(String hk) {
    final b = _byHash.remove(hk);
    if (b == null) return;
    final mk = hex(b.mailboxId);
    final set = _byMailbox[mk];
    set?.remove(hk);
    if (set != null && set.isEmpty) _byMailbox.remove(mk);
    _slotBytes[b.slot] = (_slotBytes[b.slot] ?? 0) - b.size;
    if (_slotBytes[b.slot]! <= 0) _slotBytes.remove(b.slot);
    _poolBytes[b.pool] = (_poolBytes[b.pool] ?? 0) - b.size;
    _total -= b.size;
  }

  /// Returns up to [max] blobs for the given mailboxes, oldest first, and
  /// whether more remain.
  (List<StoredBlob>, bool) fetch(List<Uint8List> mailboxIds, int max) {
    expire();
    final hits = <StoredBlob>[];
    for (final id in mailboxIds) {
      for (final hk in _byMailbox[hex(id)] ?? const <String>{}) {
        hits.add(_byHash[hk]!);
      }
    }
    return (hits.take(max).toList(), hits.length > max);
  }

  /// Early delete, authorized by the preimage of the stored delete tag.
  bool delete(Uint8List mailboxId, Uint8List hash, Uint8List deleteKey) {
    final hk = hex(hash);
    final b = _byHash[hk];
    if (b == null || !bytesEqual(b.mailboxId, mailboxId)) return false;
    if (!bytesEqual(Crypto.sha256Sync(deleteKey), b.deleteTag)) return false;
    _remove(hk);
    return true;
  }

  void expire() {
    final now = DateTime.now();
    final dead = [
      for (final e in _byHash.entries)
        if (e.value.expiresAt.isBefore(now)) e.key,
    ];
    dead.forEach(_remove);
  }

  /// Everything, for handoff on shutdown. Clears the store.
  List<StoredBlob> drain() {
    final all = _byHash.values.toList();
    _byHash.clear();
    _byMailbox.clear();
    _slotBytes.clear();
    _poolBytes.clear();
    _total = 0;
    return all;
  }
}
