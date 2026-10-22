import 'dart:io';
import 'dart:typed_data';

import 'bytes.dart';

/// An IP endpoint, encoded in exactly 19 bytes: family(1) ip(16) port(2).
class NodeAddr {
  final InternetAddress ip;
  final int port;

  NodeAddr(this.ip, this.port);

  static const encodedSize = 19;

  factory NodeAddr.parse(String s) {
    final i = s.lastIndexOf(':');
    if (i < 0) throw FormatException('missing port in $s');
    var host = s.substring(0, i);
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    final ip = InternetAddress.tryParse(host);
    if (ip == null) throw FormatException('bad ip $host');
    return NodeAddr(ip, int.parse(s.substring(i + 1)));
  }

  Uint8List encode() {
    final out = Uint8List(encodedSize);
    final raw = ip.rawAddress;
    out[0] = ip.type == InternetAddressType.IPv6 ? 6 : 4;
    out.setAll(1, raw);
    out[17] = (port >> 8) & 0xff;
    out[18] = port & 0xff;
    return out;
  }

  factory NodeAddr.decode(List<int> b) {
    if (b.length < encodedSize) throw const FormatException('short addr');
    final fam = b[0];
    final InternetAddress ip;
    if (fam == 4) {
      ip = InternetAddress.fromRawAddress(Uint8List.fromList(b.sublist(1, 5)));
    } else if (fam == 6) {
      ip = InternetAddress.fromRawAddress(
        Uint8List.fromList(b.sublist(1, 17)),
        type: InternetAddressType.IPv6,
      );
    } else {
      throw const FormatException('bad addr family');
    }
    return NodeAddr(ip, (b[17] << 8) | b[18]);
  }

  bool get isV6 => ip.type == InternetAddressType.IPv6;

  /// Coarse network range used by the diversity rule: /16 for IPv4,
  /// /32 for IPv6.
  String get range {
    final r = ip.rawAddress;
    return isV6 ? 'v6:${hex(r.sublist(0, 4))}' : 'v4:${r[0]}.${r[1]}';
  }

  bool get isLoopback => ip.isLoopback;

  @override
  String toString() => isV6 ? '[${ip.address}]:$port' : '${ip.address}:$port';

  @override
  bool operator ==(Object other) =>
      other is NodeAddr && other.toString() == toString();

  @override
  int get hashCode => toString().hashCode;
}

/// A relay node: where to reach it and the X25519 key it peels onions with.
/// Never contains a user identity.
class RelayInfo {
  final NodeAddr addr;
  final Uint8List nodePk;

  RelayInfo(this.addr, this.nodePk);

  static const encodedSize = NodeAddr.encodedSize + 32;

  String get id => hex(nodePk);

  Uint8List encode() => concat([addr.encode(), nodePk]);

  factory RelayInfo.decode(List<int> b) => RelayInfo(
    NodeAddr.decode(b),
    Uint8List.fromList(b.sublist(NodeAddr.encodedSize, encodedSize)),
  );

  /// Human-shareable form, e.g. for adding an always-on node by hand.
  String toShareString() => 'zelt-relay:$addr/${b64(nodePk)}';

  factory RelayInfo.parseShareString(String s) {
    var t = s.trim();
    if (t.startsWith('zelt-relay:')) t = t.substring('zelt-relay:'.length);
    final slash = t.lastIndexOf('/');
    if (slash < 0) throw const FormatException('expected addr/key');
    final pk = unb64(t.substring(slash + 1));
    if (pk.length != 32) throw const FormatException('bad node key');
    return RelayInfo(NodeAddr.parse(t.substring(0, slash)), pk);
  }

  Map<String, dynamic> toJson() => {'a': addr.toString(), 'k': b64(nodePk)};

  factory RelayInfo.fromJson(Map<String, dynamic> j) =>
      RelayInfo(NodeAddr.parse(j['a']), unb64(j['k']));

  /// Identity is the (address, key) pair; one node can listen on several
  /// addresses.
  String get key => '$addr/$id';

  @override
  bool operator ==(Object other) => other is RelayInfo && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => '$addr(${id.substring(0, 8)})';
}
