# zelt protocol, v2

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
- **Relay identity** (Ed25519). Authenticates links and signs onion-key
  certificates. It is published with the relay's address (`RelayInfo.nodePk`) and
  never peels onions. It is unrelated to the user identity.
- **Onion keys** (X25519, relays only). Rotating keys that exist only in RAM (see
  Onion keys below).
- **Relay secret** (32 bytes). Derives token credentials (see below).

## Local storage (vault)

A random 256-bit master key encrypts the state (ChaCha20-Poly1305). `vault.json`
holds that master key wrapped twice:

```
pinWrapped = nonce ‖ AEAD(Argon2id(PIN, salt, 64 MiB, 3 passes), master)
v2 (Android): wrapped = Keystore-AES-256-GCM(pinWrapped)
v1 (desktop): wrapped = pinWrapped
```

The Keystore key is non-exportable and lives in StrongBox when the phone has it,
otherwise in the TEE. A copied vault is useless on any other device, because PIN
guesses can only be tested through that hardware key. v1 vaults are re-wrapped as
v2 on the next successful Android unlock.

Wrong PINs: 4 are free, then a 30 s delay, doubling up to 1 h between attempts. The
counter and lock time live in `vault.json`, so they survive restarts. Attempts are
serialised, and each one is recorded with its would-be delay *before* the PIN is
tested. Parallel guesses therefore cannot share one count, and killing the app
mid-check still counts the guess. Data is never wiped automatically. An attacker who can rewrite the app's files (root) can reset
the counter, but still has to guess through this device's Keystore.

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
who records all traffic, even one who later breaks X25519. That makes the QR code
itself the secret: whoever photographs it gets the seed and the relay addresses.
The pairing screen therefore sets Android's `FLAG_SECURE` (no screenshots, screen
recording or recent-apps thumbnail), hides the code after 90 s (it can be shown
again for the same session) and warns about photographs.

From `rk0`, per direction (`i2r`, `r2i`): a mailbox key, an envelope key and a
delete key (`HKDF(rk0, "zelt/conv/{mbox,env,del}/{dir}")`).

The **safety number** is 60 digits derived from both identity keys; friends
compare it in person.

The credential in a QR code covers indices `[0, 2048)` for sending to the owner and
`[2048, 4096)` for the scanner's own use of that relay as a mailbox.

### Invite texts (remote pairing)

The second way to add a friend: the inviter sends a one-time text over any
channel.

```
zelt-invite:1:b64( inviteId(16) invitePub(32) expires(u32, unix s) PairingCode )
```

`PairingCode` is the same body as the QR code; `invitePub` is a fresh X25519
key whose private half stays on the inviter's device. Whitespace in the text is
ignored (messengers wrap long lines).

The joiner pastes it, completes its side of the pairing exactly as after a QR
scan, and stores a **join request** in up to 3 of the inviter's mailboxes:

```
joinMbox = HKDF(seed_A, salt = inviteId, "zelt/invite/mbox")   # mailbox IDs, per relay and epoch as usual
joinDel  = HKDF(seed_A, salt = inviteId, "zelt/invite/del")    # delete keys
K        = HKDF(DH(eph_J, invitePub) ‖ seed_A, salt = inviteId ‖ eph_J, "zelt/invite/join/v1")
blob     = eph_J(32) ‖ nonce(12) ‖ ChaCha20-Poly1305(K, len ‖ PairingCode_J ‖ pad, aad = inviteId)
```

Every copy uses a fresh nonce, `eph_J` is fresh per accepted invite, and the
blob is `blobSize` bytes like every other blob. The request is resent every
hello interval until the inviter answers or the invite expires. Because `K` mixes
an exchange with the invite key, someone who reads the text after it was used
cannot open a recorded join request.

The inviter watches the invite's mailbox IDs while the invite is open. On the
first join request that decrypts and parses, it deletes the invite and **saves
that before** completing the pairing (so neither a second request nor a crash
can activate it again), then pairs with `PairingCode_J` as if it had scanned it.
The normal hybrid handshake follows. Invites live in the encrypted vault, survive
restarts and are dropped 15 minutes after creation; the inviter's clock decides,
and the joiner refuses texts that its own clock already sees as expired.

Security: the text is a secret, like the QR code, and the channel it travels
over carries it. Whoever reads it **before** the friend uses it can join in
their place. Friends should compare safety numbers afterwards. `rk0` gets the
invite seed from the text, so its post-quantum protection against a recorded
channel only comes from the ML-KEM handshake that follows, not from optical
secrecy as with QR codes.

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

Mailbox ID, **per relay**: `HMAC(mboxKey, "mb" ‖ epoch ‖ relayPk)[0:16]`, with
`epoch = unixtime / 1 day` and `relayPk` the relay's identity. Copies of one
message on different relays therefore get unrelated IDs. The recipient polls each
relay with that relay's IDs: the next epoch (for senders whose clock runs ahead),
the current one and the 7 before it (the TTL), so 9 IDs per contact and relay.

Every relay copy is sealed separately, with its own random nonce, so copies share
no bytes. Delete key: `HMAC(delKey, SHA-256(this copy's blob))`. The relay stores
`SHA-256(deleteKey)`, and the store token is bound to the same per-copy hash.

## Onion packets

Each packet is exactly 8192 bytes: `keyId(1) eph(32) mac(16) routing(7 × 120) payload(7303)`.
`keyId` names which of the hop's onion keys the layer is encrypted to. For a
`relay` slot, the next hop's key ID travels in `extra[0]`.

Slot (120 bytes): `cmd(1) delayMs(u32) nextAddr(19) nextPk(32) nextEph(32) nextMac(16) extra(16)`.
Commands are `relay`, `deliver` (run the payload command here) and `toClient`
(`extra` = connection cookie ‖ SURB id).

Each hop looks up the onion key named by `keyId` (unknown or retired: drop),
computes `s = X25519(onionKey, eph)` and derives 208 bytes with
`HKDF(s, "zelt/sphinx/v2")`: a MAC key (32), a header stream key (32), LIONESS
payload keys (128) and a replay tag (16). It checks the MAC over the routing info,
rejects replayed tags, decrypts `routing ‖ 0^120`, reads its slot and decrypts
one payload layer. Senders compute filler so the header never shrinks. For
`deliver`, the slot's `extra` holds `SHA-256(payload)[0:16]`, checked by the
final hop.

**Payload cipher: LIONESS.** Each hop decrypts one layer of LIONESS (Anderson &
Biham), the wide-block cipher of the Sphinx paper. It is built from ChaCha20 and
HMAC-SHA256 only. The block is `L` (32 bytes) ‖ `R` (7272 bytes), with keys
`K1..K4` (32 bytes each):

```
encrypt:  R ^= ChaCha20(L ^ K1);  L ^= HMAC(K2, R)[0:32];  R ^= ChaCha20(L ^ K3);  L ^= HMAC(K4, R)[0:32]
decrypt:  the same steps in reverse order
```

The sender wraps the last hop's layer first. SURB replies are decrypted by each
hop in path order, and the client undoes the layers from the end. Changing any
bit at any hop turns the payload into unrelated random bytes at every later hop
(tested in `sphinx_test.dart`), so relays cannot tag packets. The final hop's
digest check and the end-to-end AEAD reject the result.

This is *Sphinx-style*, not textbook Sphinx: per-hop ephemeral keys travel inside
the encrypted routing info instead of being derived by blinding.

### Test vectors

`packages/zelt_core/test/vectors/sphinx_v2.json` pins exact bytes for a 4-hop
forward packet (every hop's slot, replay tag and output hash) and a 3-hop SURB
with a reply. The inputs are fixed labels: onion private keys are
`SHA-256("onion-i")`, identities `SHA-256("identity-i")`, addresses
192.0.2.(i+1):47017, key IDs 10, 20, 30 and 40, and delays of 100·(i+1) ms. The
payload is ChaCha20(`SHA-256("payload")`). The builder's randomness is the
ChaCha20 keystream for key `SHA-256("zelt sphinx v2 test vector")` with a zero
nonce, consumed in this order: 32 bytes per hop for the ephemeral private keys
(hop order), then the last hop's routing padding. A SURB first takes its 8-byte
ID. `sphinx_vectors_test.dart` rebuilds everything and compares.

## Links

TCP, with a server-authenticated handshake. Each side first sends a preamble,
`"ZLT" ‖ protocolVersion(1)`. If the versions differ, the server answers with
its own preamble and closes, and the client reports which version the peer runs.
A v1 node sends no preamble and is refused the same way. Then:

```
client → server:  preamble ‖ ce                    (ephemeral X25519)
server → client:  preamble ‖ se ‖ sig              (ephemeral X25519, Ed25519 signature)
sig  = Ed25519(relay identity, "zelt/link/v2" ‖ preamble ‖ ce ‖ se ‖ identityPk)
keys = HKDF(DH(ce, se), salt = preamble ‖ ce ‖ se ‖ identityPk, info = "zelt/link/v2")
```

Only the holder of the identity named in the `RelayInfo` can produce the
signature. Both key shares are ephemeral, so the link has forward secrecy. The
version is bound into the keys, so a downgrade cannot be forced, and the client
stays anonymous. The identity key is never used for onion layers. Every frame is
`AEAD(type(1) ‖ body padded to 8200)`, 8217 bytes on the wire. Right after the
handshake, and after every rotation, the relay pushes its live onion-key
certificates (`onionKeys` frame, up to 4).

## Onion keys

Every relay has rotating X25519 onion keys, created at random and **kept only in
RAM**. Each is published in a certificate signed by the relay identity:

```
cert = relayPk(32) keyId(1) onionPk(32) validFrom(u32) validUntil(u32) sig(64)     (times in unix minutes)
sig  = Ed25519(identity, "zelt/onion-key/v2" ‖ relayPk ‖ keyId ‖ onionPk ‖ validFrom ‖ validUntil)
```

- **Lifetime:** 24 h, plus a 2 h overlap. The next key is published as soon as the
  current one starts, so senders always have it in time. Senders stop using a key
  10 minutes before it expires.
- **Replay cache:** one per key, a fixed 4 MiB hash table holding the first 8
  bytes of every replay tag. It never evicts, since eviction would allow replays
  again. It holds at most 250,000 tags; when it is full, the key retires early
  and a new one takes over. The cache disappears with its key at expiry, so at
  most 2–3 live keys use about 12 MiB.
- **Restart:** a restart creates fresh keys and forgets the old ones. A packet
  recorded before the restart can neither be replayed to that relay nor peeled
  by it later, even if its disk is seized (forward secrecy for routing).
- **Distribution:** certificates reach senders through the link (from the relay
  itself; this set replaces whatever the receiver stored for that relay),
  through friends' updates (`AddressInfo.certs`, up to 20, for own, mailbox and
  known relays) and through DHT replies. Second-hand certificates are verified
  against the identity they name.
- **Transition:** senders use only relays with a valid certificate. A sender
  holding stale keys for a restarted relay gets no reply. It then marks that
  relay's keys unconfirmed and re-checks them directly. A dropped link is also
  re-opened after a random 0.5–3 s, and every peer's keys are re-confirmed at
  least every 10 minutes. Expired keys are never used.

## Send tokens

A relay derives the slot key `K = HMAC(relaySecret, "tok" ‖ slot ‖ epoch)`,
where an epoch is 7 days and a key is valid for 4 epochs. `K` is the root of a
binary key tree of depth 12, whose 4096 leaves are one-time tokens:

```
child(k, bit) = HMAC(k, "zelt/tok/child" ‖ bit)
leaf_i        = the bits of i, most significant first, walked down from K
token_i       = slot ‖ epoch ‖ i ‖ HMAC(leaf_i, i ‖ SHA-256(blob))[0:16]
```

A **credential** `(relay, slot, epoch, next, end, nodes)` holds only the subtree
keys (`depth(u8) prefix(u16) key(32)`, at most 24) covering its range `[next, end)`.
So it **cannot mint tokens outside that range**, and neither can anything
delegated from it. Delegation (`carve`) hands out power-of-two blocks aligned to
their size, so a grant is usually a single subtree key: 97 bytes on the wire. The
relay derives `leaf_i` from its slot key with 12 HMACs, checks the MAC and keeps
the spent indices in RAM.

- Each contact gets its own slot on your relay. The QR code carries the slot
  key itself, since the scanner gets the whole slot: indices `[0, 2048)` to send
  to you and `[2048, 4096)` for its own mailbox use. `update` messages carry the
  two halves as separate credentials.
- Recipients sub-delegate ranges of their credentials to their senders
  (`AddressInfo.mailboxes`).
- Strangers get a small public slot (`tokenReq`). Public slots share a 2 MB pool.

## Relay rules

RAM only. 12 MB hard cap, 512 KB per contact slot, 128 KB per public slot,
2 MB for all public slots together, 4 MB for handed-off blobs. TTL 7 days. When a
cap is hit, the oldest blob in that scope goes first.

### What a relay restart loses

A relay keeps no state on disk except its identity key and token secret. A
restart, crash or kill loses everything else, by design:

| Lost | Consequence | What bounds it |
| --- | --- | --- |
| Stored blobs | Messages waiting there are gone | Every message has 3 copies on 3 relays, the sender keeps it until a receipt and retries through new relays, and handoff covers a clean exit |
| Onion keys and their replay caches | Packets encrypted to the old keys can no longer be processed | Nothing to bound: an old packet cannot be replayed (the key is gone) or peeled later. Senders re-learn the new keys (see Onion keys) |
| Spent-token sets | An already-spent token index can be accepted once more until its credential epoch expires (at most 4 × 7 days) | Only the legitimate holder of that credential's keys can mint it again. A recorded store packet cannot be replayed (new onion keys), and a token is bound to its blob's hash. A double spend only uses the holder's own slot quota (512 KB per contact slot, 128 KB per public slot, 2 MB for all public slots, 12 MB in total, oldest dropped first, 7-day TTL) |

## Delivery

1. The sender encrypts once with the ratchet and keeps the inner content
   (`kind ‖ ciphertext`) in its encrypted outbox.
2. It picks up to 3 of the recipient's mailbox relays, distinct by identity. For
   each, it seals a fresh envelope and sends a `store` under that relay's mailbox
   ID over its own fresh onion path. Middle hops are random active peers with a
   valid onion key, chosen anew for every packet. If the first hop does not
   answer, it rebuilds the route.
3. The recipient keeps a **watch** on every mailbox relay it advertised within
   the TTL: a standing fetch (`watch`, command 0x08) that carries 4 SURBs, a
   lifetime (at most 5 min) and at most 221 mailbox IDs (24 contacts at 9 IDs
   each; longer lists are split). The relay first answers with what is already
   waiting, then keeps the unused SURBs. When a blob is stored under a watched ID,
   it goes out at once through one of them, each SURB used at most once. A blob
   sent through a watch is not sent through watches again for 30 s, so a slow
   delete cannot cause a resend storm. A relay holds at most 1024 watches, at
   most 2 per mailbox ID (newest win), and forgets them all when relaying is
   switched off. Watches are renewed at random (Poisson) times, on average every
   20 s in the foreground and 60 s in the background, and live 4 times that, so
   they always overlap. A new one is also sent when SURBs run low. Plain fetches
   (4 SURBs per packet) still run every 30 s / 120 s on average as a fallback.
   It opens the envelope, hashes the inner content and checks the seen set (kept
   for the TTL plus a day) *before* the ratchet runs. Copies 2 and 3 end there.
   It then deletes the copy on that relay.
4. Receipts are ordinary ratchet messages. When one arrives, the sender asks all
   copy holders to delete.
5. Without a receipt after the retry window (about 10 s / 15 s / 22 s for
   fast, normal and paranoid), it re-seals the same inner content for a new set
   of relays, with exponential backoff. Duplicates are caught by the seen set, and then by
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
answers. Each pass uses a fresh random order, with at most 3 probes per batch,
each started after a random delay of up to 2 s. Batches are spaced 5 s apart,
doubling up to 5 min (±20%) while nothing answers, and the spacing resets as soon
as a relay answers. Routine probes are jittered the same way, so probes follow
no fixed order or cadence. Only relays reached in the last 30 minutes are used as
hops.

**DHT:** Kademlia-style table (`k = 8`, `alpha = 3`), keyed by `SHA-256(nodePk)`.
Relays announce themselves to peers over a link frame and are added after a ping
check. Lookups run as `dhtFind` commands over onion paths, so DHT nodes never see
the querier's IP.

## Delay and cover traffic

**Delivery budget: 10 s.** Every message must reach a watching recipient within
10 s. 6 s of that is the mixing budget: per-hop delays are capped at
`6000 / (2 × hops)` ms, so the sender's path plus the watch's reply path stay
within it at any hop count. The rest is left for the network and processing.
Relays cap any requested delay at 2 s.

| Mode | Per-hop delay | Measured (in-process test, 8 relays) |
| --- | --- | --- |
| Fast | 0–20 ms | under 0.1 s (3 hops) |
| Normal | 50–250 ms | 0.5–0.9 s (4 hops) |
| Paranoid | 300–900 ms (7 hops: up to 428 ms), rounded up to 100 ms boundaries so packets leave in batches | 1.8–3.2 s (4 and 7 hops) |

Cover traffic options:

- **Off:** no dummy packets.
- **Low:** dummy `drop` packets at exponentially distributed gaps, with a 30 s mean.
- **Constant:** one packet every second. A queued real packet goes out if there is
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
4. **Remote pairing:** by one-time invite text (see "Invite texts"), valid for
   15 minutes and one activation. In person stays the stronger option.
5. **Scope:** 1:1 text, up to 6000 bytes per message. No groups or files.
6. **Platform:** Flutter for Android, with Linux and Windows builds. A headless relay runs on any Dart VM
   (`packages/zelt_core/bin/zelt_relay.dart`).
7. **Name:** zelt, its own project.

## Known limitations

- A fetch sends all of a recipient's current mailbox IDs for that relay together,
  so a mailbox relay can tell that they belong to one recipient. It still cannot
  tell who that recipient is. IDs rotate daily, and copies on other relays use
  unrelated IDs and bytes. Relays can still correlate copies by timing.
- A relay learns which of its operator's contacts' slots a token came from.
- **The 10 s delivery budget limits mixing.** Per-hop delays are at most a few
  hundred milliseconds, which hides less than delays of seconds or minutes
  would. An observer of many links who sees a packet enter and another leave
  shortly after can link them more easily. Cover traffic (constant) helps; there
  is no mode that trades the 10 s target for stronger mixing.
- A mailbox relay sees when a watch is renewed. Renewals happen at random
  times, but a fresh watch also follows soon after its SURBs are used up, so a
  relay that served the blobs (and knows that already) sees the renewal too.
- A relay restart forgets its spent-token sets (see "What a relay restart
  loses").
- **The onion and link layers are X25519-only, not post-quantum.** Onion-key
  certificates are public. An attacker who records traffic today and later has a
  quantum computer could derive the onion private keys and peel recorded packets.
  That reveals each packet's route and the per-relay mailbox IDs it was stored
  under or fetched with, so who talked to which relay when. Message content stays
  protected: envelope keys come from `rk0`, whose QR seeds never touched the
  network, and the ratchet root mixes in ML-KEM-768. Making Sphinx post-quantum
  would need a KEM-based packet format with much larger headers.
- **The pairing QR code is the secret behind `rk0`.** Its seeds are what keep the
  root secret from someone who later breaks X25519. Anyone who photographs or
  films the code gets them, plus the owner's relay addresses. The app blocks
  screenshots and hides the code after 90 s, but it cannot stop a camera.
- **Relays run by one operator can still correlate copies by timing.** The 3
  copies of a message use unrelated mailbox IDs and share no bytes (one envelope
  nonce per relay), so their contents cannot link them. But an operator who sees
  stores for different IDs arrive at the same moment on several relays it runs
  can guess they belong together. Per-hop delays and cover traffic make this
  harder; they do not prevent it.
- On Android the network code runs in the app process, kept alive by a foreground
  service. If the system kills the process, relay data is lost by design, and the
  3-copy rule covers it.
- No external review yet. Do not rely on this for anything that matters until it
  has had one.
