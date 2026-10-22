import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

final Random _rng = Random.secure();

/// Cryptographically secure random bytes.
Uint8List randomBytes(int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = _rng.nextInt(256);
  }
  return out;
}

/// Uniform random int in [0, max).
int randomInt(int max) => _rng.nextInt(max);

Uint8List concat(List<List<int>> parts) {
  final b = BytesBuilder(copy: false);
  for (final p in parts) {
    b.add(p);
  }
  return b.toBytes();
}

bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var r = 0;
  for (var i = 0; i < a.length; i++) {
    r |= a[i] ^ b[i];
  }
  return r == 0;
}

void xorInto(Uint8List target, List<int> src, [int offset = 0]) {
  for (var i = 0; i < src.length && i + offset < target.length; i++) {
    target[i + offset] ^= src[i];
  }
}

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List unhex(String s) {
  final clean = s.replaceAll(RegExp(r'\s'), '');
  if (clean.length.isOdd) throw const FormatException('odd hex length');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');

Uint8List unb64(String s) {
  final pad = (4 - s.length % 4) % 4;
  return base64Url.decode(s + '=' * pad);
}

/// Lexicographic comparison.
int compareBytes(List<int> a, List<int> b) {
  final n = min(a.length, b.length);
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}

class ByteWriter {
  final BytesBuilder _b = BytesBuilder(copy: true);

  int get length => _b.length;

  void u8(int v) => _b.addByte(v & 0xff);

  void u16(int v) {
    _b.addByte((v >> 8) & 0xff);
    _b.addByte(v & 0xff);
  }

  void u32(int v) {
    u16((v >> 16) & 0xffff);
    u16(v & 0xffff);
  }

  void u64(int v) {
    u32((v ~/ 0x100000000) & 0xffffffff);
    u32(v & 0xffffffff);
  }

  void bytes(List<int> v) => _b.add(v);

  /// Length-prefixed (u16) bytes.
  void varBytes(List<int> v) {
    u16(v.length);
    _b.add(v);
  }

  void str(String s) => varBytes(utf8.encode(s));

  Uint8List toBytes() => _b.toBytes();

  /// Returns the content padded with zeros to exactly [size] bytes.
  Uint8List toPadded(int size) {
    final raw = _b.toBytes();
    if (raw.length > size) {
      throw StateError('content ${raw.length} exceeds $size bytes');
    }
    final out = Uint8List(size);
    out.setAll(0, raw);
    return out;
  }
}

class ByteReader {
  final Uint8List _d;
  int _o = 0;

  ByteReader(List<int> data)
    : _d = data is Uint8List ? data : Uint8List.fromList(data);

  int get remaining => _d.length - _o;
  int get offset => _o;

  void _need(int n) {
    if (_o + n > _d.length) throw const FormatException('truncated');
  }

  int u8() {
    _need(1);
    return _d[_o++];
  }

  int u16() {
    _need(2);
    final v = (_d[_o] << 8) | _d[_o + 1];
    _o += 2;
    return v;
  }

  int u32() => (u16() << 16) | u16();

  int u64() => u32() * 0x100000000 + u32();

  Uint8List bytes(int n) {
    _need(n);
    final v = Uint8List.fromList(_d.sublist(_o, _o + n));
    _o += n;
    return v;
  }

  Uint8List varBytes() => bytes(u16());

  String str() => utf8.decode(varBytes());

  Uint8List rest() => bytes(remaining);
}
