# zelt

A messenger with no servers, no accounts and no directory. Every phone can also
be a relay for its friends. Messages travel through 3–7 onion-encrypted hops
(4 by default), wait in relay RAM, and only the recipient can read them.

Built with Flutter for Android, Linux and Windows. The protocol core (`packages/zelt_core/lib/`) is pure Dart
with no Flutter imports, so the same code also runs a headless always-on relay.

See [docs/PROTOCOL.md](docs/PROTOCOL.md) for the wire format and design choices.

## Features

- Adding a friend takes one action by one person: scan their QR code in person
  (one use, 10 minutes), or paste their one-time invite text (one use,
  15 minutes). Both devices are linked; a safety number lets you check.
- A hybrid X25519 + ML-KEM-768 root, then the Double Ratchet.
- Fixed-size 8 KB Sphinx-style onion packets, with reply blocks for fetching.
- Each message is stored on 3 relays, with dedup before decrypting, delivery
  receipts, early delete and retry through new relays.
- RAM-only relay: 12 MB cap, per-contact quotas, 7-day TTL, anonymous send tokens,
  and handoff to partners on a clean exit.
- Friend-first peer selection with a diversity rule, a Kademlia DHT fallback
  queried over onion paths, and warnings when the network is too small.
- Friends sync their relay lists, and every relay ever seen is kept. If nothing
  is reachable, zelt probes the whole history until one relay answers.
- Light, dark or system theme.
- Delay modes (fast, normal, paranoid) and cover traffic (off, low, constant).
- An encrypted vault with an Argon2id-stretched PIN, and no cloud backup.

## Layout

```
packages/zelt_core/lib/   protocol (pure Dart): sphinx, link, ratchet, pairing,
                          tokens, relay_store, dht, peers, node, messenger, vault
packages/zelt_core/bin/   zelt_relay.dart (headless relay), zelt_peer.dart (USB test peer)
lib/app/         Flutter UI and the Android service bridge
relay/           Dockerfile for the public relay
scripts/         install-relay.sh (public relay installer), relay_test_deploy.sh
android/         foreground service (ZeltService.kt), manifest
test/            unit, end-to-end (several nodes on localhost) and widget tests
```

## Install

- **Android:** download `zelt-<version>-android-arm64.apk` from the
  [latest release](https://github.com/gut-engel/zelt/releases/latest) and open it.
- **Linux (x86_64):**

  ```sh
  curl -fsSL https://raw.githubusercontent.com/gut-engel/zelt/main/scripts/install-linux.sh | sh
  ```

  Installs into `~/.local/share/zelt-app` with an app-menu entry, an icon and a
  `zelt` command in `~/.local/bin`. Before installing anything, it checks the
  release manifest's Ed25519 signature against the pinned zelt update key (the
  same key the app checks) and the tarball's SHA-256. It needs no root, and since
  you own the install directory, zelt updates itself from signed releases.
  Running the line again also updates; `-s -- uninstall` removes the app and
  keeps your data, and `-s -- uninstall --purge` also deletes your data after
  you type `delete`.
- **Windows:** unpack `zelt-<version>-windows-x64.zip` somewhere you can write to
  (for example your user folder) and run `zelt.exe`; it updates itself there.

## Build

```sh
flutter pub get
flutter test                 # widget tests
(cd packages/zelt_core && dart test)   # protocol, crypto and multi-node end-to-end tests
flutter build apk --release  # needs the Android SDK
```

The release build is currently signed with the debug key. Set up a real signing
config in `android/app/build.gradle.kts` before distributing it.

## Run a public relay

Every relay makes zelt work for more people, especially phones behind mobile
CGNAT, which cannot accept connections. If you have a server with a public IP
address, Docker and git, run:

```sh
curl -fsSL https://raw.githubusercontent.com/gut-engel/zelt/main/scripts/install-relay.sh | sh
```

The installer asks for the port, the public address(es) to advertise (it shows
what it detected), other relays to announce to, a memory limit and whether to
update automatically. It then builds the relay from this repository and runs it
as an unprivileged, read-only container that restarts on its own. It prints a
`zelt-relay:…` string and a QR code of it, drawn by the relay itself (no extra
tools): scan it in the app under Network → Scan relay QR, or paste the string
under Settings → Network and peers → Add relay. `… | sh -s -- share` shows both
again. Friends' apps pass it on automatically.

- **Firewall:** open the TCP port you chose (47017 by default). The installer
  tells you how and never changes it itself.
- **Updates:** with auto-update on, a systemd timer (or cron) checks GitHub
  hourly or daily. Relays **only build signed releases**: the newest `vX.Y.Z`
  tag whose SSH signature verifies against the release key pinned in the
  installer (`git verify-tag`). An unsigned or wrongly signed tag is refused, and
  the running version stays. The updater script updates along with the relay,
  and the relay key survives updates. `ZELT_REF=vX.Y.Z` pins a release (still
  verified). Opt out, e.g. for a fork or development, with `ZELT_VERIFY=0
  ZELT_REF=main` (builds unverified code; not recommended), or pin your own key
  with `ZELT_SIGNERS=/path/to/allowed_signers`.
- **Verifying by hand:** `scripts/allowed_signers` holds the same public key:
  `git -c gpg.ssh.allowedSignersFile=scripts/allowed_signers verify-tag vX.Y.Z`.
  The first `curl … | sh` itself trusts GitHub's TLS; check the script before
  running it if that matters to you.
- **Commands:** use the same one-liner plus `-s -- <command>`: `configure`
  (change settings), `update`, `check`, `status`, `share`, `logs`, `restart`,
  `remove`, `remove --purge`.
- **Manual update:** `… | sh -s -- update` installs the newest signed release
  now. `update v1.2.3` installs exactly that (verified) release, and
  `update --force` rebuilds even if it is already running. `check` shows the
  installed and the newest signed release and verifies its signature, without
  installing anything.
- **No silent downgrades:** the installed version is recorded. If the newest
  tag found is older (for example because newer tags were deleted from the
  repository), auto-update and a plain `update` refuse and keep the running
  relay. Only a named `update vX.Y.Z` goes back, with a warning.
- **Settings** are saved in `~/.config/zelt-relay/relay.env`. For unattended
  installs, set `ZELT_YES=1` plus any of `ZELT_PORT`, `ZELT_PUBLIC_IP`,
  `ZELT_PEERS`, `ZELT_MEMORY`, `ZELT_AUTO_UPDATE`, `ZELT_UPDATE_EVERY`,
  `ZELT_SCHEDULER=cron`.
- **Privacy:** messages only ever pass through as fixed-size encrypted blobs,
  kept in RAM (12 MB cap, 7 days at most). The only file is the relay's own key,
  in the Docker volume `zelt-relay-data`.

To do it by hand:

```sh
docker build -t zelt-relay -f relay/Dockerfile .
docker run -d --name zelt-relay --restart unless-stopped --network host \
  --read-only --cap-drop ALL -v zelt-relay-data:/data \
  zelt-relay --port 47017 --public-ip <your public IP>
```

Or without Docker, as a single binary:

```sh
cd packages/zelt_core && dart compile exe bin/zelt_relay.dart -o zelt_relay
./zelt_relay --port 47017 --public-ip <your public IP>
```

At least one reachable relay is required when every phone is behind CGNAT or a
stateful IPv6 firewall. Hole punching (TCP and UDP over IPv6) was tested between
a home network and a mobile hotspot and did not get through.

## Testing against a phone over USB

`packages/zelt_core/bin/zelt_peer.dart` runs a messenger plus three relays on 127.0.0.1 that echo
every message back. Debug and profile builds show a "Paste code (debug)" button
on the pairing screen; release builds pair by camera only.

```sh
for p in 47100 47101 47102 47103; do adb reverse tcp:$p tcp:$p; done
(cd packages/zelt_core && dart run bin/zelt_peer.dart --state peer.json --control peer.cmd)
# phone code -> peer:  adb exec-out screencap -p > s.png; echo "pair $(zbarimg -q --raw s.png)" >> peer.cmd
# peer code -> phone:  adb shell input text "<PAIRCODE from the log>"
echo "send hello" >> peer.cmd; echo status >> peer.cmd
```

## Trying it

1. Install on two phones on the same Wi-Fi. Relaying is on by default.
2. On both phones, open **Add friend**, scan each other's code, then compare the
   safety numbers.
3. The chat shows "Setting up encryption…" until the post-quantum handshake
   finishes, which takes one round trip.

With only two phones there are fewer peers than hops. The app says so, and
messages go out over shorter paths. Add an always-on relay or more friends for
real anonymity.

## Status

This is an unaudited first implementation. The threat model and the known
limitations are in docs/PROTOCOL.md.

## Android: background, Doze and battery

**What the code does** (`android/`, `lib/app/app_state.dart`, `packages/zelt_core/lib/messenger.dart`):

- While unlocked, zelt runs a **foreground service** (`ZeltService`, type
  `specialUse`, `START_STICKY`) with a minimal-priority "zelt is running"
  notification. The relay and all network code run in the app process; the
  service only keeps that process at foreground priority. Locking the app stops
  the service and the relay.
- It holds **no wake locks** and does **not** ask to be exempted from battery
  optimisation. It requests no permissions beyond those in the manifest (network,
  camera for QR codes, foreground service, notifications, installing its own
  signed updates).
- **Mailbox watches**: each of your mailbox relays holds a standing request with
  a few anonymous reply paths, so a message is pushed to you the moment it is
  stored (target: under 10 s end to end, in every delay mode). Watches are
  renewed at random (Poisson) times, on average every 20 s in the foreground
  and 60 s in the background, with plain polls every 30 s / 120 s as a
  fallback. The rate never depends on whether mail is waiting. Messages that
  land on your own relay are picked up at once.
- **Cover traffic** (setting): off; low, with dummy packets at random times about
  every 30 s on average; or constant, one packet every second.

**What to expect from Android.** This depends on the device and is not under the
app's control:

- A foreground-service process keeps network access in Doze, but without a wake
  lock the CPU may sleep while the screen is off. Polls and relaying then happen
  late, during Android's maintenance windows, and delivery can take minutes.
- Some manufacturers kill background apps regardless. The Blackview A52 Pro asked
  to put zelt on its "clean-free" list on first launch. Allow it if you want zelt
  to keep relaying with the screen locked.
- If the process is killed, relay data in RAM is lost by design. The 3-copy rule
  and the sender's retries cover it.
- Observed on the Blackview A52 Pro (Android 13, screen on, app in the
  background): messages arrived and showed a content-free notification.

**Data use** (every link frame is 8,217 bytes; a watch renewal is one packet
up, about 8 KB; a poll is one fetch up and at least one reply down, about 16 KB;
incoming messages add one packet each):

| | per mailbox relay | typical (3 mailbox relays) |
| --- | --- | --- |
| Foreground (watch 20 s + poll 30 s mean) | ~3.5 MB/h | ~10 MB/h |
| Background (watch 60 s + poll 120 s mean) | ~1 MB/h | ~3 MB/h |
| Cover traffic, low | | ~1 MB/h (~24 MB/day) |
| Cover traffic, constant | | ~30 MB/h (~710 MB/day) |
| Relaying for others | depends on friends' traffic | |

Watches deliver faster than the old 5 s polling did, at less than a third of
its data.

## License

[AGPL-3.0](LICENSE). If you run a modified relay or ship a modified app, publish
your changes.
