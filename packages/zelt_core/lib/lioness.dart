import 'dart:typed_data';

import 'crypto.dart';

/// LIONESS wide-block cipher (Anderson & Biham), the payload cipher of the
/// Sphinx paper, built from ChaCha20 (stream) and keyed BLAKE2b (hash).
///
/// The whole block is one permutation: changing any bit of the input
/// changes every bit of the output unpredictably. A relay that tampers with a
/// payload therefore destroys it completely instead of leaving a mark a
/// colluding relay could recognise later (tagging attack).
///
/// Block = L (32 bytes) || R (rest). With per-hop keys K1..K4:
///   R ^= S(L ^ K1);  L ^= H(K2, R);  R ^= S(L ^ K3);  L ^= H(K4, R)
class Lioness {
  Lioness._();

  static const keyBytes = 128;
  static const _l = 32;

  static void _streamRound(Uint8List b, Uint8List k) {
    final key = Uint8List(_l);
    for (var i = 0; i < _l; i++) {
      key[i] = b[i] ^ k[i];
    }
    CryptoSync.xorStream(key, b, _l);
  }

  static void _hashRound(Uint8List b, Uint8List k) {
    final h = CryptoSync.blake2bMac(k, Uint8List.sublistView(b, _l));
    for (var i = 0; i < _l; i++) {
      b[i] ^= h[i];
    }
  }

  static (Uint8List, Uint8List, Uint8List, Uint8List) _split(Uint8List keys) {
    if (keys.length != keyBytes) throw ArgumentError('LIONESS needs 128 key bytes');
    return (
      Uint8List.sublistView(keys, 0, 32),
      Uint8List.sublistView(keys, 32, 64),
      Uint8List.sublistView(keys, 64, 96),
      Uint8List.sublistView(keys, 96, 128),
    );
  }

  /// Encrypts [block] in place.
  static void encrypt(Uint8List keys, Uint8List block) {
    final (k1, k2, k3, k4) = _split(keys);
    _streamRound(block, k1);
    _hashRound(block, k2);
    _streamRound(block, k3);
    _hashRound(block, k4);
  }

  /// Decrypts [block] in place.
  static void decrypt(Uint8List keys, Uint8List block) {
    final (k1, k2, k3, k4) = _split(keys);
    _hashRound(block, k4);
    _streamRound(block, k3);
    _hashRound(block, k2);
    _streamRound(block, k1);
  }
}
