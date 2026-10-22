import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'address.dart';
import 'bytes.dart';
import 'constants.dart';
import 'crypto.dart';
import 'onion.dart';

/// The other side speaks a different protocol version.
class IncompatiblePeer implements Exception {
  final int? theirVersion;
  IncompatiblePeer(this.theirVersion);
  @override
  String toString() => theirVersion == null
      ? 'peer runs an incompatible zelt version (v1 or not zelt)'
      : 'peer runs zelt protocol v$theirVersion, we run v$protocolVersion';
}

/// Handshake preamble: "ZLT" + protocol version byte.
final Uint8List _magic = Uint8List.fromList([0x5a, 0x4c, 0x54]);
Uint8List get _preamble => Uint8List.fromList([..._magic, protocolVersion]);

int? _versionOf(Uint8List preamble) =>
    bytesEqual(preamble.sublist(0, 3), _magic) ? preamble[3] : null;

/// onionKeys: a relay pushes its current onion-key certificates (on connect
/// and after every rotation): count(1) + up to [maxCertsPerFrame] certs.
enum FrameType { packet, register, clientDelivery, announce, ping, pong, pad, onionKeys }

const int maxCertsPerFrame = 4;

class Frame {
  final FrameType type;
  final Uint8List body;
  Frame(this.type, this.body);

  static const bodySize = 8 + packetSize;
  static const plainSize = 1 + bodySize;
  static const wireSize = plainSize + 16;

  factory Frame.packet(Uint8List p) => Frame(FrameType.packet, p);
  factory Frame.ping() => Frame(FrameType.ping, Uint8List(0));
  factory Frame.pong() => Frame(FrameType.pong, Uint8List(0));
}

/// An encrypted, server-authenticated TCP link between two nodes.
///
/// Handshake (v2): both sides send "ZLT" + protocol version; a mismatch ends
/// the connection with [IncompatiblePeer]. The client sends an ephemeral
/// X25519 key `ce`; the server answers with its own `se` and an Ed25519
/// signature by its long-term identity over the transcript:
///   sig = Sign(identity, "zelt/link/v2" ‖ preamble ‖ ce ‖ se ‖ identityPk)
/// Keys = HKDF(DH(ce, se), salt = preamble ‖ ce ‖ se ‖ identityPk). Only the
/// holder of the identity named in the [RelayInfo] can complete it, both key
/// shares are ephemeral (forward secrecy), the client stays anonymous, and the
/// identity key is never used for onion layers. Every frame has the same size.
class Link {
  final Socket _socket;
  final Uint8List _txKey;
  final Uint8List _rxKey;
  int _txCtr = 0;
  int _rxCtr = 0;
  final _frames = StreamController<Frame>();
  Future<void> _txChain = Future.value();
  Future<void> _rxChain = Future.value();
  final _buf = BytesBuilder(copy: false);
  bool _closed = false;
  final bool outbound;
  final String remote;
  DateTime lastActivity = DateTime.now();

  Link._(this._socket, this._txKey, this._rxKey, this.outbound, Uint8List? initial)
    : remote = '${_socket.remoteAddress.address}:${_socket.remotePort}' {
    if (initial != null && initial.isNotEmpty) _onData(initial);
  }

  Stream<Frame> get frames => _frames.stream;
  bool get isClosed => _closed;

  static Uint8List _nonce(int ctr) {
    final n = Uint8List(12);
    var c = ctr;
    for (var i = 11; i >= 4; i--) {
      n[i] = c & 0xff;
      c >>= 8;
    }
    return n;
  }

  static Uint8List _transcript(Uint8List ce, Uint8List se, Uint8List identityPk) =>
      concat([utf8.encode('zelt/link/v$protocolVersion'), _preamble, ce, se, identityPk]);

  static Future<(Uint8List, Uint8List)> _keys(Uint8List ee, Uint8List ce, Uint8List se, Uint8List identityPk) async {
    final k = await Crypto.hkdf(
      ee,
      salt: concat([_preamble, ce, se, identityPk]),
      info: 'zelt/link/v$protocolVersion',
      length: 64,
    );
    return (k.sublist(0, 32), k.sublist(32, 64));
  }

  /// A first hop that does not answer within [timeout] is skipped and the
  /// route rebuilt, so keep this short (delivery budget).
  static Future<Link> connect(
    RelayInfo r, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final s = await Socket.connect(r.addr.ip, r.addr.port, timeout: timeout);
    s.done.catchError((_) {}).ignore();
    try {
      s.setOption(SocketOption.tcpNoDelay, true);
      final ce = await Crypto.x25519Generate();
      s.add(concat([_preamble, ce.pub]));
      final reader = _SocketReader(s);
      final v = _versionOf(await reader.read(4).timeout(timeout));
      if (v != protocolVersion) throw IncompatiblePeer(v);
      final se = await reader.read(32).timeout(timeout);
      final sig = await reader.read(64).timeout(timeout);
      if (!await Crypto.ed25519Verify(r.nodePk, _transcript(ce.pub, se, r.nodePk), sig)) {
        throw const SocketException('relay failed to prove its identity');
      }
      final rest = reader.detach();
      final (c2s, s2c) = await _keys(await Crypto.x25519(ce, se), ce.pub, se, r.nodePk);
      return Link._(s, c2s, s2c, true, rest);
    } catch (_) {
      s.destroy();
      rethrow;
    }
  }

  static Future<Link> accept(
    Socket s,
    SigningKey identity, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    s.done.catchError((_) {}).ignore();
    try {
      s.setOption(SocketOption.tcpNoDelay, true);
      final reader = _SocketReader(s);
      final v = _versionOf(await reader.read(4).timeout(timeout));
      if (v != protocolVersion) {
        // Tell a zelt peer of another version what we speak, then hang up.
        if (v != null) s.add(_preamble);
        await s.flush().catchError((_) {});
        throw IncompatiblePeer(v);
      }
      final ce = await reader.read(32).timeout(timeout);
      final rest = reader.detach();
      final se = await Crypto.x25519Generate();
      final sig = await Crypto.ed25519Sign(identity, _transcript(ce, se.pub, identity.pub));
      s.add(concat([_preamble, se.pub, sig]));
      final (c2s, s2c) = await _keys(await Crypto.x25519(se, ce), ce, se.pub, identity.pub);
      return Link._(s, s2c, c2s, false, rest);
    } catch (_) {
      s.destroy();
      rethrow;
    }
  }

  /// Must be called once after construction to start receiving.
  Link start() {
    final sub = _SocketReader._subs.remove(_socket)!;
    sub.onData(_onData);
    sub.onError((Object _) => close());
    sub.onDone(close);
    sub.resume();
    return this;
  }

  void _onData(Uint8List d) {
    lastActivity = DateTime.now();
    _buf.add(d);
    if (_buf.length < Frame.wireSize) return;
    final all = _buf.takeBytes();
    var off = 0;
    while (all.length - off >= Frame.wireSize) {
      final chunk = Uint8List.sublistView(all, off, off + Frame.wireSize);
      off += Frame.wireSize;
      final copy = Uint8List.fromList(chunk);
      _rxChain = _rxChain.then((_) => _decrypt(copy));
    }
    if (off < all.length) _buf.add(all.sublist(off));
  }

  Future<void> _decrypt(Uint8List wire) async {
    if (_closed) return;
    try {
      final plain = CryptoSync.open(_rxKey, _nonce(_rxCtr++), wire);
      final t = plain[0];
      if (t >= FrameType.values.length) return;
      final type = FrameType.values[t];
      final len = _bodyLen(type);
      _frames.add(Frame(type, Uint8List.sublistView(plain, 1, 1 + len)));
    } catch (_) {
      close();
    }
  }

  static int _bodyLen(FrameType t) => switch (t) {
    FrameType.packet => packetSize,
    FrameType.register => 8,
    FrameType.clientDelivery => 8 + payloadSize,
    FrameType.announce => RelayInfo.encodedSize,
    FrameType.ping || FrameType.pong || FrameType.pad => 0,
    FrameType.onionKeys => 1 + maxCertsPerFrame * OnionKeyCert.encodedSize,
  };

  Future<void> send(Frame f) {
    if (_closed) return Future.error(const SocketException('link closed'));
    final next = _txChain.then((_) async {
      if (_closed) throw const SocketException('link closed');
      final plain = Uint8List(Frame.plainSize);
      plain[0] = f.type.index;
      plain.setAll(1, f.body);
      // Padding stays random-looking on the wire because it is encrypted.
      final wire = CryptoSync.seal(_txKey, _nonce(_txCtr++), plain);
      _socket.add(wire);
      lastActivity = DateTime.now();
    });
    _txChain = next.catchError((_) {});
    return next;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _socket.destroy();
    _frames.close();
  }
}

/// Reads a fixed-size prefix from a socket, then pauses so [Link] can take
/// over the same subscription (a socket stream can only be listened once).
class _SocketReader {
  static final Map<Socket, StreamSubscription<Uint8List>> _subs = {};
  final Socket _s;
  final _buf = BytesBuilder();
  Completer<void>? _wait;
  Object? _err;
  late final StreamSubscription<Uint8List> _sub;

  _SocketReader(this._s) {
    _sub = _s.listen(
      (d) {
        _buf.add(d);
        _wake();
      },
      onError: (Object e) {
        _err = e;
        _wake();
      },
      onDone: () {
        _err ??= const SocketException('closed');
        _wake();
      },
    );
  }

  void _wake() {
    final w = _wait;
    _wait = null;
    w?.complete();
  }

  Future<Uint8List> read(int n) async {
    while (_buf.length < n) {
      if (_err != null) throw _err!;
      _wait = Completer<void>();
      await _wait!.future;
    }
    final all = _buf.takeBytes();
    _buf.add(all.sublist(n));
    return all.sublist(0, n);
  }

  Uint8List detach() {
    _sub.pause();
    _subs[_s] = _sub;
    return _buf.takeBytes();
  }
}
