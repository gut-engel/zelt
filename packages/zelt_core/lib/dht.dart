import 'dart:typed_data';

import 'address.dart';
import 'bytes.dart';
import 'constants.dart';
import 'crypto.dart';

/// Kademlia-style routing table of relay-capable nodes. Entries hold only a
/// node address and onion key, never a user identity or contact key.
class DhtTable {
  final Uint8List selfId;
  final List<List<RelayInfo>> _buckets = List.generate(257, (_) => []);

  DhtTable(Uint8List selfNodePk) : selfId = nodeId(selfNodePk);

  static Uint8List nodeId(Uint8List nodePk) => Crypto.sha256Sync(nodePk);

  static int _sharedPrefix(Uint8List a, Uint8List b) {
    for (var i = 0; i < a.length; i++) {
      final x = a[i] ^ b[i];
      if (x != 0) {
        var bits = 0;
        for (var m = 0x80; m > 0 && (x & m) == 0; m >>= 1) {
          bits++;
        }
        return i * 8 + bits;
      }
    }
    return a.length * 8;
  }

  int get size => _buckets.fold(0, (n, b) => n + b.length);

  List<RelayInfo> get all => [for (final b in _buckets) ...b];

  /// Adds or refreshes a node. Full buckets keep their older entries, which
  /// makes it harder to flood the table with fresh sybils.
  void add(RelayInfo r) {
    final id = nodeId(r.nodePk);
    if (bytesEqual(id, selfId)) return;
    final b = _buckets[_sharedPrefix(id, selfId)];
    final i = b.indexWhere((x) => bytesEqual(x.nodePk, r.nodePk));
    if (i >= 0) {
      b.removeAt(i);
      b.add(r);
    } else if (b.length < dhtK) {
      b.add(r);
    }
  }

  void remove(Uint8List nodePk) {
    for (final b in _buckets) {
      b.removeWhere((x) => bytesEqual(x.nodePk, nodePk));
    }
  }

  List<RelayInfo> closest(Uint8List target, [int k = dhtK]) =>
      closestOf(all, target, k);

  static List<RelayInfo> closestOf(Iterable<RelayInfo> nodes, Uint8List target, int k) {
    final scored = [
      for (final n in nodes) (n, _xor(nodeId(n.nodePk), target)),
    ]..sort((a, b) => compareBytes(a.$2, b.$2));
    return [for (final s in scored.take(k)) s.$1];
  }

  static Uint8List _xor(Uint8List a, Uint8List b) {
    final o = Uint8List(a.length);
    for (var i = 0; i < a.length; i++) {
      o[i] = a[i] ^ b[i];
    }
    return o;
  }
}
