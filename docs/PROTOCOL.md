# zelt protocol, v1

This describes what the code in `packages/zelt_core/lib/` implements. Constants live in
`packages/zelt_core/lib/constants.dart`; changing any of them breaks wire compatibility.

## Primitives

| Use | Primitive | Source |
| --- | --- | --- |
| Key agreement | X25519 | `package:cryptography` |
| Post-quantum KEM | ML-KEM-768 (FIPS 203) | `package:pqcrypto` |
| KDF / MAC / hash | HKDF-SHA256, HMAC-SHA256, SHA-256 | `package:cryptography` |
| AEAD | ChaCha20-Poly1305 (IETF, 12-byte nonce) | `package:cryptography` |
| Stream cipher (onion layers) | ChaCha20, single-use keys, zero nonce | `package:cryptography` |
| PIN stretching | Argon2id, 64 MiB, 3 passes | `package:cryptography` |

No primitive is implemented in this repository.

**About package:pqcrypto (ML-KEM-768),** as checked for v0.4.3:

- It implements final FIPS 203, not the round-3 Kyber draft: `(K, r) = G(m ‖ H(ek))`
  with no pre-hashing of `m`, implicit rejection with `J(z ‖ c)` (SHAKE256), `K`
  used directly, and the encapsulation-key modulus check and decapsulation-key hash
  check in place.
- `test/mlkem_kat_test.dart` checks it against NIST ACVP vectors (key generation,
  encapsulation, decapsulation including implicit rejection, and both key checks).
- It is pure Dart, with no FFI and no dependencies. It is maintained (release
  2026-10-09) but has had no independent audit.
- It is **not fully constant-time.** Message decoding (`_msgFromPoly`) and encoding
  (`_polyFromMsg`) branch on secret bits, and some reductions use `%` on secret
  values (the KyberSlash class of issue). Decapsulation picks its result with a
  branchless mask. In zelt each contact decapsulates once, on a ciphertext inside
  the pairing-authenticated envelope, so an attacker cannot submit the many chosen
  ciphertexts these timing attacks need. This should still be reported upstream.

## Keys

Each install generates:

- **Identity key** (X25519). Only ever leaves the phone inside a pairing QR code.
- **Node key** (X25519). The relay's onion key; published with its address. Never
  linked to the identity on the wire.
- **Relay secret** (32 bytes). Derives token credentials (see below).

## Pairing

Both phones show a QR code `zelt:1:<base64url>` and scan each other's:

```
idPub(32) ephPub(32) seed(32) name(str)
relays: n(u8) × RelayInfo(51)
cred:   has(u8) [slot(u16) epoch(u32) key(32)]     # for the owner's relay
grants: n(u8) × Credential(93)                      # tokens on other mailbox relays
```

`RelayInfo = family(1) ip(16) port(2) nodePk(32)`.

The side with the lexicographically lower identity key is the **initiator**.
Both compute

```
rk0 = HKDF(ikm = DH(id,id') ‖ DH(eph,eph') ‖ DH(id_I,eph_R) ‖ DH(eph_I,id_R) ‖ seed_I ‖ seed_R,
           salt = id_I ‖ id_R ‖ eph_I ‖ eph_R, info = "zelt/pair/v1")
```

The seeds only ever travel optically, so `rk0` stays secret against an observer
who records all traffic, even one who later breaks X25519.

From `rk0`, per direction (`i2r`, `r2i`): a mailbox key, an envelope key and a
delete key (`HKDF(rk0, "zelt/conv/{mbox,env,del}/{dir}")`).

The **safety number** is 60 digits derived from both identity keys; friends
compare it in person.

The credential in a QR code covers indices `[0, 2048)` for sending to the owner and
`[2048, 4096)` for the scanner's own use of that relay as a mailbox.

## Hybrid handshake (before the ratchet)

Sealed with the envelope keys, kind `0`:

```
Hello = hasPk(u8) [kemPk] hasCt(u8) [kemCt] AddressInfo
```

1. Each side sends `Hello{AddressInfo}` as soon as it knows a mailbox of the other.
2. The initiator includes its ML-KEM-768 public key.
3. The responder encapsulates, sets `root = HKDF(ss, salt = rk0, "zelt/hybrid/v1")`,
   initialises its ratchet as Bob with its pairing ephemeral key, and answers with
   the ciphertext. It keeps resending that until it decrypts a ratchet message from
   the initiator.
4. The initiator decapsulates, initialises as Alice (`DHr` = responder's pairing
   ephemeral key) and immediately sends an `update` message, which confirms the
   handshake.

Messages typed before this completes are kept in the outbox and sealed afterwards.

## Double Ratchet

Signal's Double Ratchet with X25519, `KDF_RK = HKDF(dh, salt = rk, "zelt/dr/rk")`,
chain `HMAC(ck, 0x02)` and message key `HMAC(ck, 0x01)`, then
`HKDF(mk, "zelt/dr/mk")` → 32-byte key and 12-byte nonce. Header
`dhPub(32) pn(u32) n(u32)` is authenticated as AD together with both identity keys.
Up to 1000 skipped keys per step and 2000 in total; keys are deleted as soon as
they are used.

So both sides can send first, the responder starts with a pre-chain
`HKDF(root, "zelt/dr/pre")`, which is also the initiator's first receiving chain.

Ratchet plaintext:

```
type(u8) msgId(16) body
  1 text:           timestamp(u64) text(str)
  2 receipt:        n(u8) × msgId(16)
  3 update:         AddressInfo
  4 update request: –
```

`AddressInfo = relays[] mailboxes[] (Credential grants) relayCreds[] (Credential) known[] (≤24 RelayInfo)`.
`known` carries the other relays the sender has reached recently, so friends' relay lists stay in sync
(setting "Share known relays with friends", on by default).

## Envelopes and mailboxes

A **blob** is exactly 7168 bytes: `nonce(12) ‖ AEAD(envKey, kind(u8) ‖ len(u16) ‖ content ‖ zero pad)`.
The envelope hides the ratchet header from relays.

Mailbox ID: `HMAC(mboxKey, "mb" ‖ epoch)[0:16]`, with `epoch = unixtime / 1 day`.
The recipient polls the current epoch and the 7 before it (the TTL).

Delete key: `HMAC(delKey, SHA-256(blob))`. The relay stores `SHA-256(deleteKey)`.

## Onion packets

Each packet is exactly 8192 bytes: `eph(32) mac(16) routing(7 × 120) payload(7304)`.

Slot (120 bytes): `cmd(1) delayMs(u32) nextAddr(19) nextPk(32) nextEph(32) nextMac(16) extra(16)`.
Commands are `relay`, `deliver` (run the payload command here) and `toClient`
(`extra` = connection cookie ‖ SURB id).

Each hop computes `s = X25519(nodeKey, eph)` and derives keys with
`HKDF(s, "zelt/sphinx/v1")`: a MAC key, a header stream key, a payload stream key
and a replay tag. It checks the MAC over the routing info, rejects replayed tags,
decrypts `routing ‖ 0^120`, reads its slot and decrypts one payload layer.
Senders compute filler so the header never shrinks. For `deliver`, the slot's
`extra` holds `SHA-256(payload)[0:16]`, checked by the final hop.

This is *Sphinx-style*, not textbook Sphinx: per-hop ephemeral keys travel inside
the encrypted routing info instead of being derived by blinding, and the payload
uses a per-hop stream cipher instead of a wide-block cipher. Intermediate hops
cannot detect payload tagging, but the final hop and the end-to-end AEAD do.

**SURBs** (single-use reply blocks, `firstHop(51) ‖ header(888)`) let a relay
answer a client it cannot identify. The client keeps one registered link to an
*entry* relay, which is the SURB's last hop.

### Payload commands (executed by the last hop)

| Code | Command | Body |
| --- | --- | --- |
| 1 | store | mailboxId(16) token(24) deleteTag(32) blob |
| 2 | fetch | n(u8) × SURB, m(u16) × mailboxId |
| 3 | delete | n(u8) × (mailboxId, hash, deleteKey) |
| 4 | drop | cover traffic |
| 5 | tokenReq | SURB → public credential |
| 6 | dhtFind | SURB, target(32) → up to 8 RelayInfo |
| 7 | handoff | mailboxId deleteTag expiresAt(u64) blob |

Every reply carries `type last(u8) partners(≤2 RelayInfo)`. The partners are where
the relay hands off its blobs on a clean shutdown, so recipients know where to look
when the relay disappears.

## Links

TCP, with a server-authenticated handshake: the client sends an ephemeral X25519
key and the server answers with its own. Then
`keys = HKDF(DH(ce, nodePk) ‖ DH(ce, se), salt = ce ‖ se ‖ nodePk)`. Only the
holder of the advertised node key can read the link, and the client stays
anonymous. Every frame is `AEAD(type(1) ‖ body padded to 8200)`, 8217 bytes on
the wire.

## Send tokens

A relay derives `key(slot, epoch) = HMAC(relaySecret, "tok" ‖ slot ‖ epoch)`, where
an epoch is 7 days and a key is valid for 4 epochs. A **credential**
`(relay, slot, epoch, key, [next, end))` is a batch of 4096 one-time tokens.
Token *i* for a blob is `slot ‖ epoch ‖ i ‖ HMAC(key, i ‖ SHA-256(blob))[0:16]`.
The relay checks the MAC and keeps the spent indices in RAM.

- Each contact gets its own slot on your relay. The QR code or `update`
  messages carry it.
- Recipients sub-delegate ranges of their credentials to their senders
  (`AddressInfo.mailboxes`).
- Strangers get a small public slot (`tokenReq`). Public slots share a 2 MB pool.

## Relay rules

RAM only. 12 MB hard cap, 512 KB per contact slot, 128 KB per public slot,
2 MB for all public slots together, 4 MB for handed-off blobs. TTL 7 days. When a
cap is hit, the oldest blob in that scope goes first.

## Delivery

1. The sender seals once and keeps the blob in its encrypted outbox.
2. It picks up to 3 of the recipient's mailbox relays, distinct by node key, and
   sends a byte-identical `store` to each over its own fresh onion path. Middle
   hops are random active peers, chosen anew for every packet. If the first hop
   does not answer, it rebuilds the route.
3. The recipient fetches from every mailbox relay it advertised within the TTL.
   It hashes each blob and checks the seen set (kept for the TTL plus a day)
   *before* decrypting, then deletes the copy on that relay.
4. Receipts are ordinary ratchet messages. When one arrives, the sender asks all
   copy holders to delete.
5. Without a receipt after the retry window (about 1 min / 1.5 min / 4.5 min for
   fast, normal and paranoid), it resends the same blob to a new set of relays,
   with exponential backoff. Duplicates are caught by the seen set, and then by
   the ratchet counter.

## Peers and discovery

Target: 12 active peers. Friends' relay addresses come first, then manual
entries, then the DHT. No source and no IP range (/16 IPv4, /32 IPv6) may supply
more than 3. The rule is relaxed only when it would leave fewer peers than hops,
and the app shows a warning then. The 4 oldest healthy peers are anchors; one
other peer rotates per hour.

**History:** every relay ever learned stays in the encrypted state, even after
the contact who shared it is deleted (`history` source). Unverified relays are
pinged in small batches, at most once per 10 minutes each. If no verified peer
is left, zelt walks the whole history, ignoring failure cool-downs, until one
answers. Only relays reached in the last 30 minutes are used as hops.

**DHT:** Kademlia-style table (`k = 8`, `alpha = 3`), keyed by `SHA-256(nodePk)`.
Relays announce themselves to peers over a link frame and are added after a ping
check. Lookups run as `dhtFind` commands over onion paths, so DHT nodes never see
the querier's IP.

## Delay and cover traffic

| Mode | Per-hop delay |
| --- | --- |
| Fast | 0–20 ms |
| Normal | 100–500 ms |
| Paranoid | 1–5 s, released on whole-second batch boundaries |

Cover traffic options:

- **Off:** no dummy packets.
- **Low:** dummy `drop` packets at exponentially distributed gaps, with a 30 s mean.
- **Constant:** one packet every 2 s. A queued real packet goes out if there is
  one, otherwise a dummy.

## Answers to the open design questions (v1)

1. **First launch:** peers come from a friend's QR code, or from a relay address
   added by hand (for example an always-on node). There are no hard-coded entry
   points and no community list.
2. **Too few peers:** zelt sends with the peers it has (a shorter path) and shows a
   warning. It does not wait.
3. **Relay address sharing:** friends sync relay lists. Each update carries the
   sender's own relay addresses plus up to 24 relays it has reached recently
   (`known`). Received relays are tagged `via:<contact>` and still count toward
   the per-source diversity cap. This spreads useful relays quickly, but friends
   learn which relays you can reach. You can turn it off in settings. Updates go
   out automatically when your addresses or reachable relays change.
4. **Remote pairing:** not in v1. Pairing is in person only.
5. **Scope:** 1:1 text, up to 6000 bytes per message. No groups or files.
6. **Platform:** Flutter for Android, with Linux and Windows builds. A headless relay runs on any Dart VM
   (`packages/zelt_core/bin/zelt_relay.dart`).
7. **Name:** zelt, its own project.

## Known limitations

- A fetch sends all of a recipient's current mailbox IDs together, so a mailbox
  relay can tell that they belong to one recipient. It still cannot tell who that
  recipient is. IDs rotate daily.
- A relay learns which of its operator's contacts' slots a token came from.
- Spent-token sets live in RAM, so a relay restart lets an index be reused once.
  The per-slot quotas still bound the damage.
- No wide-block payload cipher yet (see Onion packets).
- On Android the network code runs in the app process, kept alive by a foreground
  service. If the system kills the process, relay data is lost by design, and the
  3-copy rule covers it.
- No external review yet. Do not rely on this for anything that matters until it
  has had one.
