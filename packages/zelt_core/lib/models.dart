import 'dart:typed_data';

import 'address.dart';
import 'bytes.dart';
import 'constants.dart';
import 'crypto.dart';
import 'pairing.dart';
import 'ratchet.dart';
import 'tokens.dart';

enum DelayMode { fast, normal, paranoid }

enum CoverMode { off, low, constant }

class Settings {
  int hops;
  DelayMode delay;
  CoverMode cover;
  bool relay;
  int port;
  String name;

  /// Pass the relays we know on to friends (keeps everyone's lists in sync).
  bool shareRelays;

  Settings({
    this.hops = defaultHops,
    this.delay = DelayMode.normal,
    this.cover = CoverMode.low,
    this.relay = true,
    this.port = defaultPort,
    this.name = '',
    this.shareRelays = true,
  });

  Map<String, dynamic> toJson() => {
    'hops': hops,
    'delay': delay.name,
    'cover': cover.name,
    'relay': relay,
    'port': port,
    'name': name,
    'shareRelays': shareRelays,
  };

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
    hops: (j['hops'] as int? ?? defaultHops).clamp(minHops, maxHops),
    delay: DelayMode.values.byName(j['delay'] ?? 'normal'),
    cover: CoverMode.values.byName(j['cover'] ?? 'low'),
    relay: j['relay'] ?? true,
    port: j['port'] ?? defaultPort,
    name: j['name'] ?? '',
    shareRelays: j['shareRelays'] ?? true,
  );
}

enum MsgStatus { queued, sent, delivered }

class Message {
  final String id;
  final bool outgoing;
  final String text;

  /// Local time: when we sent it, or when it arrived.
  final DateTime time;

  /// The sender's clock, for incoming messages.
  final DateTime? sentAt;
  MsgStatus status;

  Message({
    required this.id,
    required this.outgoing,
    required this.text,
    required this.time,
    this.sentAt,
    this.status = MsgStatus.queued,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'o': outgoing,
    't': text,
    'ts': time.millisecondsSinceEpoch,
    if (sentAt != null) 'sa': sentAt!.millisecondsSinceEpoch,
    's': status.name,
  };

  factory Message.fromJson(Map<String, dynamic> j) => Message(
    id: j['id'],
    outgoing: j['o'],
    text: j['t'],
    time: DateTime.fromMillisecondsSinceEpoch(j['ts']),
    sentAt: j['sa'] == null ? null : DateTime.fromMillisecondsSinceEpoch(j['sa']),
    status: MsgStatus.values.byName(j['s']),
  );
}

class Contact {
  final String id;
  String name;
  final Uint8List idPub;
  final ConversationKeys keys;
  bool verified;

  /// Our pairing ephemeral key; the responder's first ratchet key.
  final KeyPair25519 myEph;
  final Uint8List theirEph;

  /// Initiator only, until the handshake completes.
  Uint8List? kemPk;
  Uint8List? kemSk;

  /// Responder only: resent until the initiator is confirmed.
  Uint8List? kemCt;
  bool peerConfirmed;

  Ratchet? ratchet;

  List<RelayInfo> theirRelays;

  /// Token grants for sending to this contact's mailbox relays.
  List<Credential> theirMailboxes;

  /// Slot on our relay reserved for this contact (0 = none yet).
  int slot;

  DateTime? lastHelloSent;
  DateTime? lastUpdateSent;
  DateTime? lastUpdateRequest;
  int receivedSinceUpdate;
  int unread;
  final List<Message> messages;

  Contact({
    required this.id,
    required this.name,
    required this.idPub,
    required this.keys,
    required this.myEph,
    required this.theirEph,
    this.verified = false,
    this.kemPk,
    this.kemSk,
    this.kemCt,
    this.peerConfirmed = false,
    this.ratchet,
    List<RelayInfo>? theirRelays,
    List<Credential>? theirMailboxes,
    this.slot = 0,
    this.lastHelloSent,
    this.lastUpdateSent,
    this.lastUpdateRequest,
    this.receivedSinceUpdate = 0,
    this.unread = 0,
    List<Message>? messages,
  }) : theirRelays = theirRelays ?? [],
       theirMailboxes = theirMailboxes ?? [],
       messages = messages ?? [];

  bool get ready => ratchet != null;

  int tokensLeft(DateTime now) => theirMailboxes
      .where((g) => g.usable(now))
      .fold(0, (n, g) => n + g.remaining);

  Message? get lastMessage => messages.isEmpty ? null : messages.last;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'idPub': b64(idPub),
    'keys': keys.toJson(),
    'verified': verified,
    'myEph': myEph.toJson(),
    'theirEph': b64(theirEph),
    if (kemPk != null) 'kemPk': b64(kemPk!),
    if (kemSk != null) 'kemSk': b64(kemSk!),
    if (kemCt != null) 'kemCt': b64(kemCt!),
    'peerConfirmed': peerConfirmed,
    if (ratchet != null) 'ratchet': ratchet!.toJson(),
    'theirRelays': [for (final r in theirRelays) r.toJson()],
    'theirMailboxes': [for (final g in theirMailboxes) g.toJson()],
    'slot': slot,
    if (lastHelloSent != null) 'lhs': lastHelloSent!.millisecondsSinceEpoch,
    if (lastUpdateSent != null) 'lus': lastUpdateSent!.millisecondsSinceEpoch,
    if (lastUpdateRequest != null) 'lur': lastUpdateRequest!.millisecondsSinceEpoch,
    'rsu': receivedSinceUpdate,
    'unread': unread,
    'messages': [for (final m in messages) m.toJson()],
  };

  static DateTime? _t(dynamic v) => v == null ? null : DateTime.fromMillisecondsSinceEpoch(v);

  factory Contact.fromJson(Map<String, dynamic> j) => Contact(
    id: j['id'],
    name: j['name'],
    idPub: unb64(j['idPub']),
    keys: ConversationKeys.fromJson(j['keys']),
    verified: j['verified'] ?? false,
    myEph: KeyPair25519.fromJson(j['myEph']),
    theirEph: unb64(j['theirEph']),
    kemPk: j['kemPk'] == null ? null : unb64(j['kemPk']),
    kemSk: j['kemSk'] == null ? null : unb64(j['kemSk']),
    kemCt: j['kemCt'] == null ? null : unb64(j['kemCt']),
    peerConfirmed: j['peerConfirmed'] ?? false,
    ratchet: j['ratchet'] == null ? null : Ratchet.fromJson(j['ratchet']),
    theirRelays: [for (final r in j['theirRelays'] ?? []) RelayInfo.fromJson(r)],
    theirMailboxes: [for (final g in j['theirMailboxes'] ?? []) Credential.fromJson(g)],
    slot: j['slot'] ?? 0,
    lastHelloSent: _t(j['lhs']),
    lastUpdateSent: _t(j['lus']),
    lastUpdateRequest: _t(j['lur']),
    receivedSinceUpdate: j['rsu'] ?? 0,
    unread: j['unread'] ?? 0,
    messages: [for (final m in j['messages'] ?? []) Message.fromJson(m)],
  );
}

class Copy {
  final RelayInfo relay;
  final Uint8List mailboxId;
  Copy(this.relay, this.mailboxId);

  Map<String, dynamic> toJson() => {'r': relay.toJson(), 'm': b64(mailboxId)};
  factory Copy.fromJson(Map<String, dynamic> j) =>
      Copy(RelayInfo.fromJson(j['r']), unb64(j['m']));
}

/// An outgoing blob, kept (encrypted at rest) until its receipt arrives.
class OutItem {
  final String id;
  final String contactId;
  final bool handshake;
  final bool needsReceipt;

  /// Plaintext waiting for the ratchet (only before the handshake is done).
  Uint8List? pending;
  Uint8List? blob;
  Uint8List? hash;
  int attempts;
  DateTime nextTry;
  final List<Copy> copies;

  OutItem({
    required this.id,
    required this.contactId,
    this.handshake = false,
    this.needsReceipt = true,
    this.pending,
    this.blob,
    this.hash,
    this.attempts = 0,
    DateTime? nextTry,
    List<Copy>? copies,
  }) : nextTry = nextTry ?? DateTime.now(),
       copies = copies ?? [];

  Map<String, dynamic> toJson() => {
    'id': id,
    'c': contactId,
    'h': handshake,
    'r': needsReceipt,
    if (pending != null) 'p': b64(pending!),
    if (blob != null) 'b': b64(blob!),
    if (hash != null) 'x': b64(hash!),
    'a': attempts,
    'n': nextTry.millisecondsSinceEpoch,
    'cp': [for (final c in copies) c.toJson()],
  };

  factory OutItem.fromJson(Map<String, dynamic> j) => OutItem(
    id: j['id'],
    contactId: j['c'],
    handshake: j['h'] ?? false,
    needsReceipt: j['r'] ?? true,
    pending: j['p'] == null ? null : unb64(j['p']),
    blob: j['b'] == null ? null : unb64(j['b']),
    hash: j['x'] == null ? null : unb64(j['x']),
    attempts: j['a'] ?? 0,
    nextTry: DateTime.fromMillisecondsSinceEpoch(j['n']),
    copies: [for (final c in j['cp'] ?? []) Copy.fromJson(c)],
  );
}

/// One of our own mailbox relays.
class MailboxRecord {
  RelayInfo relay;
  final bool own;
  DateTime lastAdvertised;
  List<RelayInfo> partners;
  int failures;

  MailboxRecord(
    this.relay, {
    this.own = false,
    DateTime? lastAdvertised,
    List<RelayInfo>? partners,
    this.failures = 0,
  }) : lastAdvertised = lastAdvertised ?? DateTime.now(),
       partners = partners ?? [];

  Map<String, dynamic> toJson() => {
    'r': relay.toJson(),
    'o': own,
    'la': lastAdvertised.millisecondsSinceEpoch,
    'p': [for (final p in partners) p.toJson()],
    'f': failures,
  };

  factory MailboxRecord.fromJson(Map<String, dynamic> j) => MailboxRecord(
    RelayInfo.fromJson(j['r']),
    own: j['o'] ?? false,
    lastAdvertised: DateTime.fromMillisecondsSinceEpoch(j['la']),
    partners: [for (final p in j['p'] ?? []) RelayInfo.fromJson(p)],
    failures: j['f'] ?? 0,
  );
}

class SeenEntry {
  final DateTime expires;
  final String? contactId;
  final String? msgId;
  DateTime? lastReceipt;
  SeenEntry(this.expires, {this.contactId, this.msgId, this.lastReceipt});

  Map<String, dynamic> toJson() => {
    'e': expires.millisecondsSinceEpoch,
    if (contactId != null) 'c': contactId,
    if (msgId != null) 'm': msgId,
  };

  factory SeenEntry.fromJson(Map<String, dynamic> j) => SeenEntry(
    DateTime.fromMillisecondsSinceEpoch(j['e']),
    contactId: j['c'],
    msgId: j['m'],
  );
}

/// Keys generated once per install.
class Identity {
  final KeyPair25519 id;
  final KeyPair25519 node;
  final Uint8List relaySecret;
  Identity(this.id, this.node, this.relaySecret);

  static Future<Identity> generate() async => Identity(
    await Crypto.x25519Generate(),
    await Crypto.x25519Generate(),
    randomBytes(32),
  );

  Map<String, dynamic> toJson() => {
    'id': id.toJson(),
    'node': node.toJson(),
    'rs': b64(relaySecret),
  };

  factory Identity.fromJson(Map<String, dynamic> j) => Identity(
    KeyPair25519.fromJson(j['id']),
    KeyPair25519.fromJson(j['node']),
    unb64(j['rs']),
  );
}
