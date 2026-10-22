import 'dart:convert';
import 'dart:typed_data';

import 'address.dart';
import 'bytes.dart';
import 'constants.dart';
import 'crypto.dart';

/// Anonymous send tokens.
///
/// A relay's slot key is K = HMAC(relaySecret, "tok" || slot || epoch). It is
/// the root of a binary key tree of depth 12 whose 4096 leaves are one-time
/// tokens: child = HMAC(parent, "zelt/tok/child" || bit), leaf i is reached by
/// the bits of i (most significant first). Token i for a blob is
/// (slot, epoch, i, HMAC(leaf_i, i || blobHash)). A credential carries only
/// the subtree keys covering its range, so it cannot mint tokens outside that
/// range; the relay derives leaf_i from K (12 HMACs), checks the MAC and that
/// i was not spent. It learns which slot (which of its operator's contacts,
/// or which anonymous public requester) a token came from, never who sent
/// the blob.
class Token {
  final int slot;
  final int epoch;
  final int index;
  final Uint8List mac;
  Token(this.slot, this.epoch, this.index, this.mac);

  static const encodedSize = 2 + 4 + 2 + 16;

  Uint8List encode() => (ByteWriter()
        ..u16(slot)
        ..u32(epoch)
        ..u16(index)
        ..bytes(mac))
      .toBytes();

  static Token decode(List<int> b) {
    final r = ByteReader(b);
    return Token(r.u16(), r.u32(), r.u16(), r.bytes(16));
  }
}

/// Depth of the token key tree: 2^12 = [tokensPerCredential] leaves.
const int tokenTreeDepth = 12;

Uint8List _child(Uint8List key, int bit) =>
    CryptoSync.hmac(key, [...utf8.encode('zelt/tok/child'), bit]);

/// Walks from a node key down to a descendant: [bits] low bits of [path],
/// most significant first.
Uint8List _descend(Uint8List key, int path, int bits) {
  var k = key;
  for (var b = bits - 1; b >= 0; b--) {
    k = _child(k, (path >> b) & 1);
  }
  return k;
}

/// The key for token index [i], from the slot (root) key. This is all a relay
/// needs to verify tokens.
Uint8List tokenLeafKey(Uint8List slotKey, int i) => _descend(slotKey, i, tokenTreeDepth);

/// A subtree of the token key tree: covers indices
/// [prefix << (12 - depth), (prefix + 1) << (12 - depth)).
class TokenNode {
  final int depth;
  final int prefix;
  final Uint8List key;
  TokenNode(this.depth, this.prefix, this.key);

  int get start => prefix << (tokenTreeDepth - depth);
  int get end => (prefix + 1) << (tokenTreeDepth - depth);
  bool covers(int i) => i >= start && i < end;

  static const encodedSize = 1 + 2 + 32;
}

/// A batch of tokens for one relay, or a delegated part of one.
///
/// Holds only the subtree keys for its range, so it cannot mint tokens for
/// indices outside [start, end), and anything carved from it is limited
/// the same way. The relay derives any leaf from its slot key.
class Credential {
  final RelayInfo relay;
  final int slot;
  final int epoch;
  final List<TokenNode> nodes;
  int next;
  final int end;

  Credential(this.relay, this.slot, this.epoch, this.nodes, {required this.next, required this.end});

  /// From the slot (root) key, restricted to [next, end).
  factory Credential.fromSlotKey(
    RelayInfo relay,
    int slot,
    int epoch,
    Uint8List slotKey, {
    int next = 0,
    int end = tokensPerCredential,
  }) {
    final root = TokenNode(0, 0, slotKey);
    return Credential(relay, slot, epoch, _cover(next, end, [root]), next: next, end: end);
  }

  /// The same credential, addressed to [r] (same relay identity).
  Credential withRelay(RelayInfo r) => Credential(r, slot, epoch, nodes, next: next, end: end);

  int get remaining => end - next;

  bool isValidAt(DateTime t) {
    final e = tokenEpochOf(t);
    return epoch <= e && epoch > e - tokenEpochWindow;
  }

  bool usable(DateTime t) => remaining > 0 && isValidAt(t);

  /// Key for the subtree (depth, prefix), if one of [have] contains it.
  static Uint8List? _keyFor(int depth, int prefix, List<TokenNode> have) {
    for (final n in have) {
      if (n.depth > depth) continue;
      if (prefix >> (depth - n.depth) != n.prefix) continue;
      return _descend(n.key, prefix, depth - n.depth);
    }
    return null;
  }

  /// Minimal set of subtrees covering [lo, hi), derived from [have].
  static List<TokenNode> _cover(int lo, int hi, List<TokenNode> have) {
    final out = <TokenNode>[];
    void add(int depth, int prefix) {
      final k = _keyFor(depth, prefix, have);
      if (k != null) {
        out.add(TokenNode(depth, prefix, k));
      } else if (depth < tokenTreeDepth) {
        // Not inside one of our subtrees as a whole: split.
        add(depth + 1, prefix * 2);
        add(depth + 1, prefix * 2 + 1);
      } else {
        throw StateError('index ${prefix} is outside this credential');
      }
    }

    var i = lo;
    while (i < hi) {
      var size = 1;
      while (size < tokensPerCredential && i % (size * 2) == 0 && i + size * 2 <= hi) {
        size *= 2;
      }
      final depth = tokenTreeDepth - size.bitLength + 1;
      add(depth, i ~/ size);
      i += size;
    }
    return out;
  }

  Future<Token> take(Uint8List blobHash) async {
    if (remaining <= 0) throw StateError('credential exhausted');
    final i = next++;
    final leaf = _keyFor(tokenTreeDepth, i, nodes);
    if (leaf == null) throw StateError('index $i outside credential');
    final mac = await Crypto.hmac(leaf, concat([_u16(i), blobHash]));
    return Token(slot, epoch, i, mac.sublist(0, 16));
  }

  /// Splits off [count] tokens (a power of two) for delegation, as one block
  /// aligned to its size so it is usually a single subtree key. Tokens
  /// skipped for alignment are not used.
  Credential? carve(int count) {
    if (count <= 0 || count & (count - 1) != 0) throw ArgumentError('count must be a power of two');
    final start = (next + count - 1) ~/ count * count;
    if (start + count > end) return null;
    final c = Credential(relay, slot, epoch, _cover(start, start + count, nodes), next: start, end: start + count);
    next = start + count;
    return c;
  }

  static const maxNodes = 2 * tokenTreeDepth;

  Uint8List encode() {
    final w = ByteWriter()
      ..bytes(relay.encode())
      ..u16(slot)
      ..u32(epoch)
      ..u16(next)
      ..u16(end)
      ..u8(nodes.length);
    for (final n in nodes) {
      w
        ..u8(n.depth)
        ..u16(n.prefix)
        ..bytes(n.key);
    }
    return w.toBytes();
  }

  static Credential decode(ByteReader r) {
    final relay = RelayInfo.decode(r.bytes(RelayInfo.encodedSize));
    final slot = r.u16();
    final epoch = r.u32();
    final next = r.u16();
    final end = r.u16();
    final n = r.u8();
    if (next > end || end > tokensPerCredential || n > maxNodes) {
      throw const FormatException('bad credential');
    }
    final nodes = <TokenNode>[];
    for (var i = 0; i < n; i++) {
      final depth = r.u8();
      final prefix = r.u16();
      if (depth > tokenTreeDepth || prefix >= (1 << depth)) throw const FormatException('bad token node');
      nodes.add(TokenNode(depth, prefix, r.bytes(32)));
    }
    return Credential(relay, slot, epoch, nodes, next: next, end: end);
  }

  Map<String, dynamic> toJson() => {
    'r': relay.toJson(),
    's': slot,
    'e': epoch,
    't': [for (final n in nodes) [n.depth, n.prefix, b64(n.key)]],
    'n': next,
    'x': end,
  };

  factory Credential.fromJson(Map<String, dynamic> j) {
    final relay = RelayInfo.fromJson(j['r']);
    if (j['t'] == null) {
      // Saved before the key tree: the stored key was the slot key.
      return Credential.fromSlotKey(relay, j['s'], j['e'], unb64(j['k']), next: j['n'], end: j['x']);
    }
    return Credential(
      relay,
      j['s'],
      j['e'],
      [for (final t in j['t'] as List) TokenNode(t[0] as int, t[1] as int, unb64(t[2] as String))],
      next: j['n'],
      end: j['x'],
    );
  }
}

Uint8List _u16(int v) => Uint8List.fromList([(v >> 8) & 0xff, v & 0xff]);

Uint8List _slotEpoch(int slot, int epoch) =>
    (ByteWriter()
          ..str('tok')
          ..u16(slot)
          ..u32(epoch))
        .toBytes();

/// Relay side: mints credentials and verifies tokens. Spent indices live in
/// RAM only.
class TokenIssuer {
  final Uint8List secret;
  final Map<String, Set<int>> _spent = {};
  int _nextPublic = firstPublicSlot;

  TokenIssuer(this.secret);

  Future<Uint8List> keyFor(int slot, int epoch) =>
      Crypto.hmac(secret, _slotEpoch(slot, epoch));

  Future<Credential> issue(RelayInfo self, int slot, {DateTime? now}) async {
    final e = tokenEpochOf(now ?? DateTime.now());
    return Credential.fromSlotKey(self, slot, e, await keyFor(slot, e));
  }

  /// A credential for an anonymous requester, in its own small public slot.
  Future<Credential> issuePublic(RelayInfo self) {
    final slot = _nextPublic;
    _nextPublic = _nextPublic >= 0xfffe ? firstPublicSlot : _nextPublic + 1;
    return issue(self, slot);
  }

  Future<bool> verifyAndSpend(Token t, Uint8List blobHash) async {
    final cur = tokenEpochOf(DateTime.now());
    if (t.epoch > cur || t.epoch <= cur - tokenEpochWindow) return false;
    if (t.index >= tokensPerCredential) return false;
    final leaf = tokenLeafKey(await keyFor(t.slot, t.epoch), t.index);
    final want = await Crypto.hmac(leaf, concat([_u16(t.index), blobHash]));
    if (!bytesEqual(want.sublist(0, 16), t.mac)) return false;
    final spent = _spent.putIfAbsent('${t.slot}/${t.epoch}', () => <int>{});
    if (!spent.add(t.index)) return false;
    _spent.removeWhere((k, _) {
      final e = int.parse(k.split('/')[1]);
      return e <= cur - tokenEpochWindow;
    });
    return true;
  }
}
