import 'dart:typed_data';

import 'address.dart';
import 'bytes.dart';
import 'constants.dart';
import 'crypto.dart';

/// Anonymous send tokens.
///
/// A relay hands out credentials: (slot, epoch, key) where
/// key = HMAC(relaySecret, slot || epoch). A credential is a compact batch
/// of [tokensPerCredential] one-time tokens. Token i for a blob is
/// (slot, epoch, i, HMAC(key, i || blobHash)). The relay recomputes the key,
/// checks the MAC and that i was not spent. It learns which slot (which of
/// its operator's contacts, or which anonymous public requester) the token
/// came from, never who sent the blob.
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

/// A batch of tokens for one relay, or a sub-range of one.
class Credential {
  final RelayInfo relay;
  final int slot;
  final int epoch;
  final Uint8List key;
  int next;
  final int end;

  Credential(
    this.relay,
    this.slot,
    this.epoch,
    this.key, {
    this.next = 0,
    this.end = tokensPerCredential,
  });

  int get remaining => end - next;

  bool isValidAt(DateTime t) {
    final e = tokenEpochOf(t);
    return epoch <= e && epoch > e - tokenEpochWindow;
  }

  bool usable(DateTime t) => remaining > 0 && isValidAt(t);

  Future<Token> take(Uint8List blobHash) async {
    if (remaining <= 0) throw StateError('credential exhausted');
    final i = next++;
    final mac = await Crypto.hmac(key, concat([_u16(i), blobHash]));
    return Token(slot, epoch, i, mac.sublist(0, 16));
  }

  /// Splits off [count] tokens for delegation to someone else.
  Credential? carve(int count) {
    if (remaining < count) return null;
    final c = Credential(relay, slot, epoch, key, next: next, end: next + count);
    next += count;
    return c;
  }

  static const encodedSize = RelayInfo.encodedSize + 2 + 4 + 32 + 2 + 2;

  Uint8List encode() => (ByteWriter()
        ..bytes(relay.encode())
        ..u16(slot)
        ..u32(epoch)
        ..bytes(key)
        ..u16(next)
        ..u16(end))
      .toBytes();

  static Credential decode(ByteReader r) {
    final relay = RelayInfo.decode(r.bytes(RelayInfo.encodedSize));
    final slot = r.u16();
    final epoch = r.u32();
    final key = r.bytes(32);
    final next = r.u16();
    final end = r.u16();
    if (next > end || end > tokensPerCredential) {
      throw const FormatException('bad credential range');
    }
    return Credential(relay, slot, epoch, key, next: next, end: end);
  }

  Map<String, dynamic> toJson() => {
    'r': relay.toJson(),
    's': slot,
    'e': epoch,
    'k': b64(key),
    'n': next,
    'x': end,
  };

  factory Credential.fromJson(Map<String, dynamic> j) => Credential(
    RelayInfo.fromJson(j['r']),
    j['s'],
    j['e'],
    unb64(j['k']),
    next: j['n'],
    end: j['x'],
  );
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
    return Credential(self, slot, e, await keyFor(slot, e));
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
    final key = await keyFor(t.slot, t.epoch);
    final want = await Crypto.hmac(key, concat([_u16(t.index), blobHash]));
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
