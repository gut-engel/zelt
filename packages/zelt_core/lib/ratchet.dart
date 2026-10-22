import 'dart:typed_data';

import 'bytes.dart';
import 'crypto.dart';

/// Signal-style Double Ratchet (X25519, HKDF-SHA256, HMAC-SHA256 chains,
/// ChaCha20-Poly1305). Message keys are deleted as soon as they are used.
///
/// Initialisation differs slightly from Signal so that both sides can send
/// right after pairing: the responder ("Bob") starts with a pre-chain derived
/// from the root, and the initiator ("Alice") uses it as her first receiving
/// chain. The first real DH ratchet step happens when Bob receives Alice's
/// first message.
class Ratchet {
  static const maxSkip = 1000;
  static const maxStoredSkipped = 2000;
  static const headerSize = 32 + 4 + 4;

  Uint8List rk;
  KeyPair25519 dhs;
  Uint8List? dhr;
  Uint8List? cks;
  Uint8List? ckr;
  int ns = 0;
  int nr = 0;
  int pn = 0;
  // key: "<dh hex>:<n>" -> message key
  final Map<String, Uint8List> skipped;

  Ratchet._(
    this.rk,
    this.dhs,
    this.dhr,
    this.cks,
    this.ckr,
    this.ns,
    this.nr,
    this.pn,
    this.skipped,
  );

  static Future<Uint8List> _preChain(Uint8List root) =>
      Crypto.hkdf(root, info: 'zelt/dr/pre');

  /// Initiator. [bobPub] is the responder's initial ratchet public key.
  static Future<Ratchet> alice(Uint8List root, Uint8List bobPub) async {
    final dhs = await Crypto.x25519Generate();
    final (rk, cks) = await _kdfRk(root, await Crypto.x25519(dhs, bobPub));
    return Ratchet._(rk, dhs, bobPub, cks, await _preChain(root), 0, 0, 0, {});
  }

  /// Responder. [bobKey] is the key pair whose public half Alice holds.
  static Future<Ratchet> bob(Uint8List root, KeyPair25519 bobKey) async =>
      Ratchet._(root, bobKey, null, await _preChain(root), null, 0, 0, 0, {});

  static Future<(Uint8List, Uint8List)> _kdfRk(Uint8List rk, Uint8List dh) async {
    final o = await Crypto.hkdf(dh, salt: rk, info: 'zelt/dr/rk', length: 64);
    return (o.sublist(0, 32), o.sublist(32, 64));
  }

  static Future<(Uint8List, Uint8List)> _kdfCk(Uint8List ck) async {
    final next = await Crypto.hmac(ck, [2]);
    final mk = await Crypto.hmac(ck, [1]);
    return (next, mk);
  }

  static Future<(Uint8List, Uint8List)> _msgKey(Uint8List mk) async {
    final o = await Crypto.hkdf(mk, info: 'zelt/dr/mk', length: 44);
    return (o.sublist(0, 32), o.sublist(32, 44));
  }

  Uint8List _header(Uint8List dh, int pn, int n) => (ByteWriter()
        ..bytes(dh)
        ..u32(pn)
        ..u32(n))
      .toBytes();

  /// Returns header || ciphertext.
  Future<Uint8List> encrypt(Uint8List plaintext, {List<int> ad = const []}) async {
    final ck = cks;
    if (ck == null) throw StateError('no sending chain');
    final (next, mk) = await _kdfCk(ck);
    cks = next;
    final header = _header(dhs.pub, pn, ns);
    ns++;
    final (key, nonce) = await _msgKey(mk);
    final ct = await Crypto.seal(key, nonce, plaintext, aad: concat([ad, header]));
    return concat([header, ct]);
  }

  /// Decrypts header || ciphertext. State only changes if decryption
  /// succeeds; replays and forgeries throw.
  Future<Uint8List> decrypt(Uint8List msg, {List<int> ad = const []}) async {
    if (msg.length < headerSize + 16) throw const FormatException('short');
    final header = msg.sublist(0, headerSize);
    final r = ByteReader(header);
    final dh = r.bytes(32);
    final hpn = r.u32();
    final hn = r.u32();
    final ct = msg.sublist(headerSize);
    final aad = concat([ad, header]);

    final sk = '${hex(dh)}:$hn';
    final stored = skipped[sk];
    if (stored != null) {
      final (key, nonce) = await _msgKey(stored);
      final pt = await Crypto.open(key, nonce, ct, aad: aad);
      skipped.remove(sk);
      return pt;
    }

    final t = _copy();
    if (t.dhr == null || !bytesEqual(dh, t.dhr!)) {
      await t._skip(hpn);
      await t._dhRatchet(dh);
    }
    await t._skip(hn);
    final (next, mk) = await _kdfCk(t.ckr!);
    t.ckr = next;
    t.nr++;
    final (key, nonce) = await _msgKey(mk);
    final pt = await Crypto.open(key, nonce, ct, aad: aad);
    _commit(t);
    return pt;
  }

  Future<void> _skip(int until) async {
    if (ckr == null) return;
    if (until < nr) return;
    if (until - nr > maxSkip) throw const FormatException('too many skipped');
    while (nr < until) {
      final (next, mk) = await _kdfCk(ckr!);
      ckr = next;
      skipped['${hex(dhr!)}:$nr'] = mk;
      nr++;
    }
    while (skipped.length > maxStoredSkipped) {
      skipped.remove(skipped.keys.first);
    }
  }

  Future<void> _dhRatchet(Uint8List dh) async {
    pn = ns;
    ns = 0;
    nr = 0;
    dhr = dh;
    var (r1, c1) = await _kdfRk(rk, await Crypto.x25519(dhs, dh));
    rk = r1;
    ckr = c1;
    dhs = await Crypto.x25519Generate();
    var (r2, c2) = await _kdfRk(rk, await Crypto.x25519(dhs, dh));
    rk = r2;
    cks = c2;
  }

  Ratchet _copy() => Ratchet._(
    rk,
    dhs,
    dhr,
    cks,
    ckr,
    ns,
    nr,
    pn,
    Map.of(skipped),
  );

  void _commit(Ratchet t) {
    rk = t.rk;
    dhs = t.dhs;
    dhr = t.dhr;
    cks = t.cks;
    ckr = t.ckr;
    ns = t.ns;
    nr = t.nr;
    pn = t.pn;
    skipped
      ..clear()
      ..addAll(t.skipped);
  }

  Map<String, dynamic> toJson() => {
    'rk': b64(rk),
    'dhs': dhs.toJson(),
    if (dhr != null) 'dhr': b64(dhr!),
    if (cks != null) 'cks': b64(cks!),
    if (ckr != null) 'ckr': b64(ckr!),
    'ns': ns,
    'nr': nr,
    'pn': pn,
    'sk': {for (final e in skipped.entries) e.key: b64(e.value)},
  };

  factory Ratchet.fromJson(Map<String, dynamic> j) => Ratchet._(
    unb64(j['rk']),
    KeyPair25519.fromJson(j['dhs']),
    j['dhr'] == null ? null : unb64(j['dhr']),
    j['cks'] == null ? null : unb64(j['cks']),
    j['ckr'] == null ? null : unb64(j['ckr']),
    j['ns'],
    j['nr'],
    j['pn'],
    {
      for (final e in (j['sk'] as Map<String, dynamic>).entries)
        e.key: unb64(e.value as String),
    },
  );
}
