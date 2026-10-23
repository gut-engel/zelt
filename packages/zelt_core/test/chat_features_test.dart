@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zelt_core/bytes.dart';
import 'package:zelt_core/crypto.dart';
import 'package:zelt_core/groups.dart';
import 'package:zelt_core/messages.dart';
import 'package:zelt_core/messenger.dart';
import 'package:zelt_core/models.dart';
import 'package:zelt_core/node.dart';

import 'e2e_test.dart' show debugLogs, fastTimings, messenger, pair, relayNode, until;
import 'media_test.dart' show fakeWebp;

void main() {
  late List<Node> relays;
  final cleanup = <Messenger>[];

  setUp(() async {
    relays = [for (var i = 0; i < 5; i++) await relayNode()];
  });

  tearDown(() async {
    for (final m in cleanup) {
      await m.dispose();
    }
    cleanup.clear();
    debugLogs.clear();
    for (final r in relays) {
      await r.stop();
    }
  });

  Future<Messenger> started(Messenger m) async {
    cleanup.add(m);
    await m.start();
    for (final r in relays) {
      m.addManualPeer((await r.localRelayInfos()).first);
    }
    return m;
  }

  Future<(Contact, Contact)> friends(Messenger a, Messenger b) async {
    final (ab, ba) = await pair(a, b);
    await until(() => ab.ready && ba.ready, 'handshake ${a.settings.name}-${b.settings.name}');
    return (ab, ba);
  }

  test('replies and reactions travel with the message they belong to', () async {
    final a = await started(await messenger('alice'));
    final b = await started(await messenger('bob'));
    final (ab, ba) = await friends(a, b);
    final hi = await a.sendText(ab.id, 'hi');
    await until(() => ba.messages.any((m) => m.id == hi.id), 'hi');
    final reply = await b.sendText(ba.id, 'hello back', replyTo: hi.id);
    await until(() => ab.messages.any((m) => m.id == reply.id), 'reply');
    expect(ab.messages.firstWhere((m) => m.id == reply.id).replyTo, hi.id);
    // A reply to something that is not in the chat is sent as a plain message.
    final stray = await b.sendText(ba.id, 'x', replyTo: hex(randomBytes(16)));
    expect(stray.replyTo, isNull);

    await b.react(ba.id, hi.id, '👍');
    await until(() => ab.messages.firstWhere((m) => m.id == hi.id).shownReactions[ab.id] == '👍', 'reaction');
    await b.react(ba.id, hi.id, '❤️');
    await until(() => ab.messages.firstWhere((m) => m.id == hi.id).shownReactions[ab.id] == '❤️', 'changed');
    await b.react(ba.id, hi.id, '');
    await until(() => ab.messages.firstWhere((m) => m.id == hi.id).shownReactions.isEmpty, 'removed');
    expect(ba.messages.firstWhere((m) => m.id == hi.id).shownReactions, isEmpty);
    expect(() => b.react(ba.id, hi.id, 'not an emoji'), throwsArgumentError);
  });

  test('an older reaction never replaces a newer one', () {
    final m = Message(id: 'x', outgoing: false, text: '', time: DateTime.now());
    expect(m.react('a', '👍', 10), isTrue);
    expect(m.react('a', '😂', 5), isFalse);
    expect(m.react('a', '', 11), isTrue);
    expect(m.react('a', '👍', 9), isFalse);
    expect(m.shownReactions, isEmpty);
    final back = Message.fromJson(jsonDecode(jsonEncode(m.toJson())));
    expect(back.reactions['a'], ('', 11));
  });

  test('reactions accept emoji and refuse text', () {
    for (final ok in ['', '👍', '❤️', '👍🏽', '🏳️‍🌈', '😂']) {
      expect(ChatMsg.validReaction(ok), isTrue, reason: ok);
    }
    for (final bad in ['a', 'ok', '1', '👍\n', 'x' * 40, '\u0000']) {
      expect(ChatMsg.validReaction(bad), isFalse, reason: bad);
    }
  });

  test('older devices still read a reply as a plain message', () {
    final reply = ChatMsg(MsgType.text, randomBytes(16), timestamp: 1, text: 'hi', replyTo: randomBytes(16)).encode();
    // An old decoder reads type, id, timestamp and text, and stops there.
    final r = ByteReader(reply);
    r.u8();
    r.bytes(16);
    r.u64();
    expect(r.str(), 'hi');
    expect(ChatMsg.decode(reply).replyTo, isNotNull);
  });

  test('a group reaches members who are not friends with each other', () async {
    final a = await started(await messenger('admin'));
    final b = await started(await messenger('bea'));
    final c = await started(await messenger('cem'));
    final (ab, ba) = await friends(a, b);
    final (ac, ca) = await friends(a, c);
    // Bea and Cem are not paired.

    final g = await a.createGroup('Trip', [ab.id, ac.id]);
    await until(() => b.groups[g.id]?.state == GroupState.invited && c.groups[g.id]?.state == GroupState.invited, 'invites');
    await b.acceptGroupInvite(g.id);
    await c.acceptGroupInvite(g.id);
    await until(() => b.groups[g.id]!.active && c.groups[g.id]!.active, 'joined');
    expect(a.groups[g.id]!.roster.members.length, 3);
    expect(c.groups[g.id]!.roster.members.map((m) => m.name), containsAll(['admin', 'bea', 'cem']));

    // Bea's post reaches Cem through the admin, signed by Bea.
    final post = await b.sendGroupText(g.id, 'who brings snacks?');
    await until(() => c.groups[g.id]!.messages.any((m) => m.id == post.id), 'forwarded post');
    final got = c.groups[g.id]!.messages.firstWhere((m) => m.id == post.id);
    expect(got.author, hex(b.identity.id.pub));
    expect(got.via, ca.id);
    await until(() => a.groups[g.id]!.messages.any((m) => m.id == post.id), 'admin got it');
    await until(() => post.status == MsgStatus.delivered, 'delivered to the admin');

    // Cem replies and reacts; Bea gets both through the admin.
    final answer = await c.sendGroupText(g.id, 'me', replyTo: post.id);
    await c.reactInGroup(g.id, post.id, '🎉');
    await until(() => b.groups[g.id]!.messages.any((m) => m.id == answer.id), 'answer');
    expect(b.groups[g.id]!.messages.firstWhere((m) => m.id == answer.id).replyTo, post.id);
    await until(
      () => b.groups[g.id]!.messages.firstWhere((m) => m.id == post.id).shownReactions[hex(c.identity.id.pub)] == '🎉',
      'reaction',
    );

    // A photo from Bea: Cem gets the bytes from the admin.
    final pic = fakeWebp(20000);
    final photo = await b.sendGroupImage(g.id, pic, width: 640, height: 480, caption: 'menu');
    await until(() => c.groups[g.id]!.messages.any((m) => m.id == photo.id), 'photo message');
    final deadline = DateTime.now().add(const Duration(seconds: 40));
    while (!await c.hasMedia(photo.media!.id) && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    expect(await c.media.read(photo.media!.id), pic);

    // Each post shows once, however many ways it arrives.
    expect(c.groups[g.id]!.messages.where((m) => m.id == post.id).length, 1);
    expect(ca.messages, isEmpty, reason: 'group posts do not land in the 1:1 chat');

    // The admin removes Cem: he learns it and gets nothing new.
    await a.removeFromGroup(g.id, hex(c.identity.id.pub));
    await until(() => c.groups[g.id]!.state == GroupState.removed, 'removed');
    await until(() => b.groups[g.id]!.roster.members.length == 2, 'new list at Bea');
    final after = await b.sendGroupText(g.id, 'just us now');
    await until(() => a.groups[g.id]!.messages.any((m) => m.id == after.id), 'admin got it');
    await Future.delayed(const Duration(seconds: 2));
    expect(c.groups[g.id]!.messages.any((m) => m.id == after.id), isFalse);

    // Bea leaves.
    await b.leaveGroup(g.id);
    await until(() => a.groups[g.id]!.roster.members.length == 1, 'Bea left');
    expect(b.groups[g.id]!.state, GroupState.left);
  });

  test('a declined invitation is withdrawn at the admin', () async {
    final a = await started(await messenger('admin'));
    final b = await started(await messenger('bea'));
    final (ab, _) = await friends(a, b);
    final g = await a.createGroup('Book club', [ab.id]);
    await until(() => b.groups[g.id] != null, 'invite');
    await b.declineGroupInvite(g.id);
    expect(b.groups[g.id], isNull);
    await until(() => a.groups[g.id]!.pendingInvites.isEmpty, 'withdrawn');
  });

  test('group posts must be signed by a member and rosters by the admin', () async {
    final admin = await Crypto.ed25519Generate();
    final mallory = await Crypto.ed25519Generate();
    final gid = randomBytes(16);
    final me = GroupMember(randomBytes(32), admin.pub, 'admin');
    final roster = await Roster.sign(admin, groupId: gid, version: 1, name: 'g', members: [me]);
    expect((await Roster.decode(roster.encode())).version, 1);
    // Any change breaks the signature.
    final bytes = roster.encode();
    bytes[20] ^= 1;
    expect(() => Roster.decode(bytes), throwsFormatException);
    // A roster signed by someone else than the admin it names.
    final forged = await Roster.sign(mallory, groupId: gid, version: 2, name: 'g', members: [me]);
    expect(() => Roster.decode(forged.encode()), throwsFormatException, reason: 'admin key not a member');

    final body = ChatMsg(MsgType.text, randomBytes(16), timestamp: 1, text: 'hi').encode();
    final post = await GroupPost.sign(admin, gid, body, []);
    expect(await GroupPost.decode(post.encode()).verify(), isTrue);
    final other = GroupPost(gid, admin.pub, ChatMsg(MsgType.text, randomBytes(16), timestamp: 1, text: 'bye').encode(), post.sig, []);
    expect(await other.verify(), isFalse);
    // Too many members never fits in a message.
    expect(
      () => Roster.sign(admin, groupId: gid, version: 1, name: 'g', members: [
        for (var i = 0; i <= maxGroupMembers; i++) GroupMember(randomBytes(32), randomBytes(32), 'm$i'),
      ]),
      throwsArgumentError,
    );
  });

  test('a full roster and a maximal post fit into one message', () async {
    final admin = await Crypto.ed25519Generate();
    final members = [
      GroupMember(randomBytes(32), admin.pub, 'é' * 24),
      for (var i = 1; i < maxGroupMembers; i++) GroupMember(randomBytes(32), randomBytes(32), 'é' * 24),
    ];
    final roster = await Roster.sign(admin, groupId: randomBytes(16), version: 1, name: 'é' * 32, members: members);
    final rosterMsg = ChatMsg(MsgType.groupRoster, randomBytes(16), payload: roster.encode()).encode();
    final body = ChatMsg(MsgType.text, randomBytes(16), timestamp: 1, text: 'x' * 6000, replyTo: randomBytes(16)).encode();
    final post = await GroupPost.sign(admin, roster.groupId, body, [for (final m in members) m.idPub]);
    final postMsg = ChatMsg(MsgType.groupPost, randomBytes(16), payload: post.encode()).encode();
    // Ratchet plaintext limit: envelope content minus ratchet header and tag.
    const limit = 7137 - 40 - 16;
    expect(rosterMsg.length, lessThanOrEqualTo(limit));
    expect(postMsg.length, lessThanOrEqualTo(limit));
  });

  test('a restored device starts new sessions; nothing old is reused', () async {
    final a = await started(await messenger('alice'));
    final b = await started(await messenger('bob'));
    final (ab, ba) = await friends(a, b);
    final m1 = await a.sendText(ab.id, 'before the backup');
    await until(() => ba.messages.any((m) => m.id == m1.id) && m1.status == MsgStatus.delivered, 'first message');
    final g = await a.createGroup('g', [ab.id]);
    await until(() => b.groups[g.id] != null, 'invite');
    await b.acceptGroupInvite(g.id);
    await until(() => a.groups[g.id]!.roster.members.length == 2, 'joined');

    final backup = jsonDecode(jsonEncode(a.backupJson())) as Map<String, dynamic>;
    final text = jsonEncode(backup);
    expect(text.contains('"ratchet"'), isFalse, reason: 'no message keys in a backup');
    expect(backup['outbox'], isNull);
    final oldEpoch = ba.epoch;
    await a.stop(handoff: false);

    final a2 = await started(await Messenger.restore(backup, timings: fastTimings, bindAddress: InternetAddress.loopbackIPv4));
    debugLogs.add(a2);
    final a2b = a2.contacts[ab.id]!;
    expect(a2b.ready, isFalse);
    await until(() => a2b.ready && ba.ready && ba.epoch > oldEpoch, 'new session', max: const Duration(seconds: 60));
    expect(ba.epoch, a2b.epoch);
    final m2 = await a2.sendText(a2b.id, 'after the restore');
    await until(() => ba.messages.any((m) => m.id == m2.id), 'restored device sends');
    final m3 = await b.sendText(ba.id, 'welcome back');
    await until(() => a2b.messages.any((m) => m.id == m3.id), 'restored device receives');
    // History and groups came back.
    expect(a2b.messages.any((m) => m.id == m1.id), isTrue);
    final post = await b.sendGroupText(g.id, 'still here');
    await until(() => a2.groups[g.id]!.messages.any((m) => m.id == post.id), 'group still works');
  });

  test('the old device stops when its backup is restored elsewhere', () async {
    final a = await started(await messenger('alice'));
    final b = await started(await messenger('bob'));
    final (ab, ba) = await friends(a, b);
    final backup = jsonDecode(jsonEncode(a.backupJson())) as Map<String, dynamic>;
    var told = false;
    a.onSuperseded = () => told = true;
    // The old device keeps running while the backup comes back on a new one.
    final a2 = await started(await Messenger.restore(backup, timings: fastTimings, bindAddress: InternetAddress.loopbackIPv4));
    debugLogs.add(a2);
    final a2b = a2.contacts[ab.id]!;
    await until(() => a.superseded, 'old device notices', max: const Duration(seconds: 60));
    expect(told, isTrue);
    expect(a.toJson()['superseded'], isTrue, reason: 'it stays stopped after a restart');
    await until(() => a2b.ready && ba.ready && ba.epoch == a2b.epoch, 'new device holds the session', max: const Duration(seconds: 60));
    final m = await b.sendText(ba.id, 'only the new device');
    await until(() => a2b.messages.any((x) => x.id == m.id), 'new device receives');
    await Future.delayed(const Duration(seconds: 1));
    expect(ab.messages.any((x) => x.id == m.id), isFalse);
    final back = await a2.sendText(a2b.id, 'hi from the new phone');
    await until(() => ba.messages.any((x) => x.id == back.id), 'new device sends');
  });

  test('an older hello cannot reset a newer session', () async {
    final a = await started(await messenger('alice'));
    final b = await started(await messenger('bob'));
    final (ab, ba) = await friends(a, b);
    await a.restartSessions();
    await until(() => ab.ready && ba.ready && ba.epoch == ab.epoch && ab.epoch > 0, 'new session');
    final ratchet = ba.ratchet;
    // Anything still in flight from epoch 0 is ignored by the epoch check.
    expect(ba.epoch, greaterThan(0));
    await Future.delayed(const Duration(seconds: 2));
    expect(identical(ba.ratchet, ratchet), isTrue);
    final m = await b.sendText(ba.id, 'works');
    await until(() => ab.messages.any((x) => x.id == m.id), 'message');
  });

  test('message types are appended, never renumbered', () {
    // The index is the wire value: these must never change.
    expect(MsgType.avatar.index, 8);
    expect(MsgType.reaction.index, 9);
    expect(MsgType.groupPost.index, 14);
    expect(Uint8List(0), isEmpty);
  });
}
