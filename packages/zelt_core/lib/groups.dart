import 'dart:convert';
import 'dart:typed_data';

import 'bytes.dart';
import 'crypto.dart';
import 'models.dart';

/// Group chats, built on the pairwise channels.
///
/// A group has one admin (its creator) who is paired with every member. The
/// admin keeps the member list ([Roster]) and signs every version of it with
/// a key made for this group only. Each member also makes a signing key for
/// the group when joining; it signs their posts ([GroupPost]).
///
/// A post goes over the pairwise ratchet to every member its author is paired
/// with. Every member who receives a new post passes it on to the members it
/// is paired with that may not have it yet, so members who are not friends
/// with each other still get everything (at the latest through the admin, who
/// is paired with all). Signatures make passed-on posts as trustworthy as
/// direct ones: nobody can post in someone else's name, and only the admin
/// changes who is in the group.
///
/// Group keys are per group, so groups cannot be linked to each other or to a
/// device's relay identity.

const int maxGroupMembers = 32;
const int maxGroupNameBytes = 64;
const int maxMemberNameBytes = 48;

/// Member names and group names are short single lines.
String cleanName(String s, int maxBytes) {
  var out = s.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
  while (utf8.encode(out).length > maxBytes) {
    out = out.substring(0, out.length - 1);
  }
  return out;
}

class GroupMember {
  /// The member's identity key: the contact ID of anyone paired with them.
  final Uint8List idPub;

  /// Their signing key for this group.
  final Uint8List signPk;
  final String name;
  GroupMember(this.idPub, this.signPk, this.name);

  String get id => hex(idPub);

  void write(ByteWriter w) => w
    ..bytes(idPub)
    ..bytes(signPk)
    ..str(name);

  static GroupMember read(ByteReader r) {
    final id = r.bytes(32);
    final pk = r.bytes(32);
    final name = r.str();
    if (utf8.encode(name).length > maxMemberNameBytes) throw const FormatException('member name');
    return GroupMember(id, pk, name);
  }
}

/// Who is in a group, signed by its admin. Higher versions replace lower
/// ones; nothing else is accepted.
class Roster {
  final Uint8List groupId;
  final int version;
  final String name;
  final Uint8List adminSignPk;

  /// The admin left: nobody can join any more, posting still works.
  final bool closed;
  final List<GroupMember> members;
  final Uint8List sig;

  Roster._(this.groupId, this.version, this.name, this.adminSignPk, this.closed, this.members, this.sig);

  static const _label = 'zelt/group/roster/v1';

  static Uint8List _body(Uint8List groupId, int version, String name, Uint8List adminSignPk, bool closed, List<GroupMember> members) {
    final w = ByteWriter()
      ..bytes(utf8.encode(_label))
      ..bytes(groupId)
      ..u32(version)
      ..str(name)
      ..bytes(adminSignPk)
      ..u8(closed ? 1 : 0)
      ..u8(members.length);
    for (final m in members) {
      m.write(w);
    }
    return w.toBytes();
  }

  static Future<Roster> sign(
    SigningKey admin, {
    required Uint8List groupId,
    required int version,
    required String name,
    required List<GroupMember> members,
    bool closed = false,
  }) async {
    if (members.length > maxGroupMembers) throw ArgumentError('too many members');
    final n = cleanName(name, maxGroupNameBytes);
    final body = _body(groupId, version, n, admin.pub, closed, members);
    return Roster._(groupId, version, n, admin.pub, closed, members, await Crypto.ed25519Sign(admin, body));
  }

  String get id => hex(groupId);

  GroupMember? get admin => members.where((m) => bytesEqual(m.signPk, adminSignPk)).firstOrNull;

  GroupMember? member(String idHex) => members.where((m) => m.id == idHex).firstOrNull;

  GroupMember? bySignPk(Uint8List pk) => members.where((m) => bytesEqual(m.signPk, pk)).firstOrNull;

  Uint8List encode() {
    final w = ByteWriter()
      ..bytes(groupId)
      ..u32(version)
      ..str(name)
      ..bytes(adminSignPk)
      ..u8(closed ? 1 : 0)
      ..u8(members.length);
    for (final m in members) {
      m.write(w);
    }
    w.bytes(sig);
    return w.toBytes();
  }

  /// Parses and checks the signature and the limits.
  static Future<Roster> decode(Uint8List b) async {
    final roster = _parse(b);
    final body = _body(roster.groupId, roster.version, roster.name, roster.adminSignPk, roster.closed, roster.members);
    if (!await Crypto.ed25519Verify(roster.adminSignPk, body, roster.sig)) {
      throw const FormatException('roster signature');
    }
    return roster;
  }

  /// A roster from our own vault (checked when it arrived).
  static Roster decodeStored(Uint8List b) => _parse(b);

  static Roster _parse(Uint8List b) {
    final r = ByteReader(b);
    final groupId = r.bytes(16);
    final version = r.u32();
    final name = r.str();
    final adminPk = r.bytes(32);
    final closed = r.u8() == 1;
    final n = r.u8();
    if (n == 0 || n > maxGroupMembers) throw const FormatException('member count');
    if (utf8.encode(name).length > maxGroupNameBytes) throw const FormatException('group name');
    final members = [for (var i = 0; i < n; i++) GroupMember.read(r)];
    final sig = r.bytes(64);
    if (r.remaining != 0) throw const FormatException('trailing bytes');
    final ids = members.map((m) => m.id).toSet();
    final keys = members.map((m) => hex(m.signPk)).toSet();
    if (ids.length != n || keys.length != n) throw const FormatException('duplicate member');
    final roster = Roster._(groupId, version, name, adminPk, closed, members, sig);
    if (roster.admin == null) throw const FormatException('admin is not a member');
    return roster;
  }
}

/// A message in a group: a [ChatMsg]-encoded text, image, sticker or
/// reaction ([body]), signed by its author.
class GroupPost {
  final Uint8List groupId;
  final Uint8List authorSignPk;
  final Uint8List body;
  final Uint8List sig;

  /// Members the author sent it to directly (8-byte identity key prefixes).
  /// Not signed: it only saves passing it on twice.
  final List<Uint8List> direct;

  GroupPost(this.groupId, this.authorSignPk, this.body, this.sig, this.direct);

  static const _label = 'zelt/group/post/v1';

  static Uint8List _signed(Uint8List groupId, Uint8List body) =>
      concat([utf8.encode(_label), groupId, body]);

  static Future<GroupPost> sign(SigningKey author, Uint8List groupId, Uint8List body, List<Uint8List> directIds) async =>
      GroupPost(
        groupId,
        author.pub,
        body,
        await Crypto.ed25519Sign(author, _signed(groupId, body)),
        [for (final d in directIds) Uint8List.fromList(d.sublist(0, 8))],
      );

  Future<bool> verify() => Crypto.ed25519Verify(authorSignPk, _signed(groupId, body), sig);

  bool sentDirectlyTo(Uint8List idPub) => direct.any((d) => bytesEqual(d, idPub.sublist(0, 8)));

  Uint8List encode() {
    final w = ByteWriter()
      ..bytes(groupId)
      ..bytes(authorSignPk)
      ..varBytes(body)
      ..bytes(sig)
      ..u8(direct.length);
    for (final d in direct) {
      w.bytes(d);
    }
    return w.toBytes();
  }

  static GroupPost decode(Uint8List b) {
    final r = ByteReader(b);
    final groupId = r.bytes(16);
    final pk = r.bytes(32);
    final body = r.varBytes();
    final sig = r.bytes(64);
    final n = r.u8();
    if (n > maxGroupMembers) throw const FormatException('direct list');
    final direct = [for (var i = 0; i < n; i++) r.bytes(8)];
    if (r.remaining != 0) throw const FormatException('trailing bytes');
    return GroupPost(groupId, pk, body, sig, direct);
  }
}

/// A member asks to join (answering an invite): their signing key for the
/// group and the name they want the others to see.
class GroupJoin {
  final Uint8List groupId;
  final Uint8List signPk;
  final String name;
  GroupJoin(this.groupId, this.signPk, this.name);

  Uint8List encode() => (ByteWriter()
        ..bytes(groupId)
        ..bytes(signPk)
        ..str(name))
      .toBytes();

  static GroupJoin decode(Uint8List b) {
    final r = ByteReader(b);
    final j = GroupJoin(r.bytes(16), r.bytes(32), r.str());
    if (utf8.encode(j.name).length > maxMemberNameBytes || r.remaining != 0) throw const FormatException('join');
    return j;
  }
}

enum GroupState {
  /// Someone invited us; we have not answered yet.
  invited,

  /// We accepted; the admin has not added us yet.
  joining,
  member,

  /// We left, or declined.
  left,

  /// The admin removed us.
  removed,
}

class Group {
  final String id;
  Roster roster;
  GroupState state;

  /// Our signing key for this group (after accepting, or as its admin).
  SigningKey? signKey;

  /// Contact who invited us (the admin).
  final String? invitedBy;

  /// Admin only: contacts invited who have not joined yet.
  final Set<String> pendingInvites;

  /// Hidden behind the duress PIN, like a private contact.
  bool private;
  int unread;
  final List<Message> messages;

  /// Post IDs already handled (dedup of passed-on copies), newest last.
  final List<String> seenPosts;

  Group({
    required this.id,
    required this.roster,
    required this.state,
    this.signKey,
    this.invitedBy,
    Set<String>? pendingInvites,
    this.private = false,
    this.unread = 0,
    List<Message>? messages,
    List<String>? seenPosts,
  }) : pendingInvites = pendingInvites ?? {},
       messages = messages ?? [],
       seenPosts = seenPosts ?? [];

  String get name => roster.name;
  bool get isAdmin => signKey != null && bytesEqual(signKey!.pub, roster.adminSignPk);
  bool get active => state == GroupState.member;
  Message? get lastMessage => messages.isEmpty ? null : messages.last;

  void markSeen(String postId) {
    seenPosts.add(postId);
    if (seenPosts.length > 5000) seenPosts.removeRange(0, seenPosts.length - 5000);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'roster': b64(roster.encode()),
    'state': state.name,
    if (signKey != null) 'key': signKey!.toJson(),
    if (invitedBy != null) 'by': invitedBy,
    if (pendingInvites.isNotEmpty) 'pi': pendingInvites.toList(),
    if (private) 'private': true,
    'unread': unread,
    'messages': [for (final m in messages) m.toJson()],
    if (seenPosts.isNotEmpty) 'seen': seenPosts,
  };

  /// The roster was checked when it arrived; it is stored inside the vault.
  factory Group.fromJson(Map<String, dynamic> j) => Group(
    id: j['id'],
    roster: Roster.decodeStored(unb64(j['roster'])),
    state: GroupState.values.byName(j['state']),
    signKey: j['key'] == null ? null : SigningKey.fromJson(j['key']),
    invitedBy: j['by'],
    pendingInvites: {...(j['pi'] as List? ?? []).cast<String>()},
    private: j['private'] ?? false,
    unread: j['unread'] ?? 0,
    messages: [for (final m in j['messages'] ?? []) Message.fromJson(m)],
    seenPosts: (j['seen'] as List? ?? []).cast<String>(),
  );
}
