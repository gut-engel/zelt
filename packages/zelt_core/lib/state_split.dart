/// Private chats: the saved state in two parts.
///
/// Contacts and groups marked private, with everything that names them (the
/// messages waiting to go out to them, the dedup entries of what they sent),
/// form the private part. The vault keeps it apart, under a key that only
/// the real PIN opens; the duress PIN opens the rest only. Nothing in the
/// public part points at a private chat: relays a private contact told us
/// about stay known (they are needed to reach the network), but under the
/// anonymous `history` source.
class StateSplit {
  StateSplit._();

  /// Splits a full messenger state into (public, private).
  static (Map<String, dynamic>, Map<String, dynamic>) split(Map<String, dynamic> full) {
    final contacts = (full['contacts'] as List? ?? []).cast<Map<String, dynamic>>();
    final groups = (full['groups'] as List? ?? []).cast<Map<String, dynamic>>();
    final hidden = {for (final c in contacts) if (c['private'] == true) c['id'] as String};
    final hiddenGroups = {for (final g in groups) if (g['private'] == true) g['id'] as String};
    bool isHidden(Map<String, dynamic> o) {
      if (hidden.contains(o['c'])) return true;
      final gm = o['gm'] as String?;
      return gm != null && hiddenGroups.contains(gm.substring(0, gm.indexOf('/')));
    }

    final outbox = (full['outbox'] as List? ?? []).cast<Map<String, dynamic>>();
    final seen = (full['seen'] as Map<String, dynamic>? ?? {});
    final public = Map<String, dynamic>.of(full)
      ..['contacts'] = [for (final c in contacts) if (!hidden.contains(c['id'])) c]
      ..['groups'] = [for (final g in groups) if (!hiddenGroups.contains(g['id'])) _scrubGroup(g, hidden).$1]
      ..['outbox'] = [for (final o in outbox) if (!isHidden(o)) o]
      ..['seen'] = {
        for (final e in seen.entries)
          if (!hidden.contains((e.value as Map<String, dynamic>)['c'])) e.key: e.value,
      };
    if (full['peers'] != null) public['peers'] = _anonymisePeers(full['peers'] as Map<String, dynamic>, hidden);
    final private = <String, dynamic>{
      'contacts': [for (final c in contacts) if (hidden.contains(c['id'])) c],
      'groups': [for (final g in groups) if (hiddenGroups.contains(g['id'])) g],
      'outbox': [for (final o in outbox) if (isHidden(o)) o],
      'seen': {
        for (final e in seen.entries)
          if (hidden.contains((e.value as Map<String, dynamic>)['c'])) e.key: e.value,
      },
      // What was taken out of public groups, put back by [merge].
      'groupRefs': {
        for (final g in groups)
          if (!hiddenGroups.contains(g['id'])) g['id'] as String: ?_scrubGroup(g, hidden).$2,
      },
    };
    return (public, private);
  }

  /// The full state again: [public] plus any number of private parts (the
  /// private section and anything marked private while the duress PIN was
  /// used). Later parts win on the same contact or group.
  static Map<String, dynamic> merge(Map<String, dynamic> public, Iterable<Map<String, dynamic>> privates) {
    final full = Map<String, dynamic>.of(public);
    final contacts = <String, Map<String, dynamic>>{
      for (final c in (public['contacts'] as List? ?? []).cast<Map<String, dynamic>>()) c['id'] as String: c,
    };
    final groups = <String, Map<String, dynamic>>{
      for (final g in (public['groups'] as List? ?? []).cast<Map<String, dynamic>>()) g['id'] as String: g,
    };
    final outbox = [...(public['outbox'] as List? ?? []).cast<Map<String, dynamic>>()];
    final seen = Map<String, dynamic>.of(public['seen'] as Map<String, dynamic>? ?? {});
    for (final p in privates) {
      for (final c in (p['contacts'] as List? ?? []).cast<Map<String, dynamic>>()) {
        contacts[c['id'] as String] = c;
      }
      for (final g in (p['groups'] as List? ?? []).cast<Map<String, dynamic>>()) {
        groups[g['id'] as String] = g;
      }
      final ids = {for (final o in outbox) '${o['c']}/${o['id']}'};
      for (final o in (p['outbox'] as List? ?? []).cast<Map<String, dynamic>>()) {
        if (ids.add('${o['c']}/${o['id']}')) outbox.add(o);
      }
      seen.addAll(p['seen'] as Map<String, dynamic>? ?? {});
      for (final e in (p['groupRefs'] as Map<String, dynamic>? ?? {}).entries) {
        final g = groups[e.key];
        if (g != null) groups[e.key] = _unscrubGroup(g, e.value as Map<String, dynamic>);
      }
    }
    full['contacts'] = contacts.values.toList();
    full['groups'] = groups.values.toList();
    full['outbox'] = outbox;
    full['seen'] = seen;
    return full;
  }

  /// Peer sources naming a hidden contact become `history`.
  static Map<String, dynamic> _anonymisePeers(Map<String, dynamic> peers, Set<String> hidden) {
    if (hidden.isEmpty) return peers;
    String fix(String s) =>
        hidden.contains(s) || (s.startsWith('via:') && hidden.contains(s.substring(4))) ? 'history' : s;
    return Map<String, dynamic>.of(peers)
      ..['known'] = [
        for (final r in (peers['known'] as List? ?? []).cast<Map<String, dynamic>>())
          Map<String, dynamic>.of(r)..['s'] = {for (final s in (r['s'] as List).cast<String>()) fix(s)}.toList(),
      ];
  }

  /// A public group must not name a hidden contact outside its member list:
  /// who passed a post on, who invited us, whom we invited. Returns the
  /// scrubbed group and what was removed (null: nothing).
  static (Map<String, dynamic>, Map<String, dynamic>?) _scrubGroup(Map<String, dynamic> g, Set<String> hidden) {
    if (hidden.isEmpty) return (g, null);
    final out = Map<String, dynamic>.of(g);
    final refs = <String, dynamic>{};
    if (hidden.contains(out['by'])) refs['by'] = out.remove('by');
    final pi = (out['pi'] as List? ?? []).cast<String>();
    if (pi.any(hidden.contains)) {
      out['pi'] = [for (final id in pi) if (!hidden.contains(id)) id];
      refs['pi'] = [for (final id in pi) if (hidden.contains(id)) id];
    }
    final via = <String, String>{};
    out['messages'] = [
      for (final m in (out['messages'] as List? ?? []).cast<Map<String, dynamic>>())
        if (hidden.contains(m['via'])) (Map<String, dynamic>.of(m)..remove('via')) else m,
    ];
    for (final m in (g['messages'] as List? ?? []).cast<Map<String, dynamic>>()) {
      if (hidden.contains(m['via'])) via[m['id'] as String] = m['via'] as String;
    }
    if (via.isNotEmpty) refs['via'] = via;
    return (out, refs.isEmpty ? null : refs);
  }

  static Map<String, dynamic> _unscrubGroup(Map<String, dynamic> g, Map<String, dynamic> refs) {
    final out = Map<String, dynamic>.of(g);
    if (refs['by'] != null) out['by'] = refs['by'];
    if (refs['pi'] != null) out['pi'] = {...(out['pi'] as List? ?? []).cast<String>(), ...(refs['pi'] as List).cast<String>()}.toList();
    final via = (refs['via'] as Map<String, dynamic>? ?? {});
    if (via.isNotEmpty) {
      out['messages'] = [
        for (final m in (out['messages'] as List? ?? []).cast<Map<String, dynamic>>())
          via[m['id']] == null ? m : (Map<String, dynamic>.of(m)..['via'] = via[m['id']]),
      ];
    }
    return out;
  }
}
