import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'address.dart';
import 'bytes.dart';
import 'constants.dart';
import 'crypto.dart';

enum FrameType { packet, register, clientDelivery, announce, ping, pong, pad }

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
/// Handshake: the client sends an ephemeral X25519 key, the server answers
/// with its own. Keys come from DH(ce, server static) and DH(ce, se), so only
/// the holder of the node key named in the [RelayInfo] can read the link.
/// The client stays anonymous. Every frame has the same size on the wire.
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

  static Future<(Uint8List, Uint8List)> _keys(
    Uint8List es,
    Uint8List ee,
    Uint8List ce,
    Uint8List se,
    Uint8List sk,
  ) async {
    final k = await Crypto.hkdf(
      concat([es, ee]),
      salt: concat([ce, se, sk]),
      info: 'zelt/link/v1',
      length: 64,
    );
    return (k.sublist(0, 32), k.sublist(32, 64));
  }

  static Future<Link> connect(
    RelayInfo r, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final s = await Socket.connect(r.addr.ip, r.addr.port, timeout: timeout);
    s.done.catchError((_) {}).ignore();
    try {
      s.setOption(SocketOption.tcpNoDelay, true);
      final ce = await Crypto.x25519Generate();
      s.add(ce.pub);
      final (se, rest) = await _readExact(s, 32, timeout);
      final es = await Crypto.x25519(ce, r.nodePk);
      final ee = await Crypto.x25519(ce, se);
      final (c2s, s2c) = await _keys(es, ee, ce.pub, se, r.nodePk);
      return Link._(s, c2s, s2c, true, rest);
    } catch (_) {
      s.destroy();
      rethrow;
    }
  }

  static Future<Link> accept(
    Socket s,
    KeyPair25519 nodeKey, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    s.done.catchError((_) {}).ignore();
    try {
      s.setOption(SocketOption.tcpNoDelay, true);
      final (ce, rest) = await _readExact(s, 32, timeout);
      final se = await Crypto.x25519Generate();
      s.add(se.pub);
      final es = await Crypto.x25519(nodeKey, ce);
      final ee = await Crypto.x25519(se, ce);
      final (c2s, s2c) = await _keys(es, ee, ce, se.pub, nodeKey.pub);
      return Link._(s, s2c, c2s, false, rest);
    } catch (_) {
      s.destroy();
      rethrow;
    }
  }

  static Future<(Uint8List, Uint8List)> _readExact(
    Socket s,
    int n,
    Duration timeout,
  ) async {
    final r = _SocketReader(s);
    final head = await r.read(n).timeout(timeout);
    return (head, r.detach());
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
