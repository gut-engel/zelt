# zelt

A messenger with no servers, no accounts and no directory. Every phone can also
be a relay for its friends. Messages travel through 3–7 onion-encrypted hops
(4 by default), wait in relay RAM, and only the recipient can read them.

Android only, built with Flutter. The protocol core (`lib/core/`) is pure Dart
with no Flutter imports, so the same code also runs a headless always-on relay.

See [docs/PROTOCOL.md](docs/PROTOCOL.md) for the wire format and design choices.

## Features

- Pairing in person by scanning QR codes, with a safety number to compare.
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
`zelt-relay:…` string: share it, or add it in the app under Settings → Network
and peers → Add relay. Friends' apps pass it on automatically.

- **Firewall:** open the TCP port you chose (47017 by default). The installer
  tells you how and never changes it itself.
- **Updates:** with auto-update on, a systemd timer (or cron) checks GitHub
  hourly or daily and rebuilds only when a new revision exists. The updater
  script updates along with the relay. The relay key survives updates.
- **Commands:** use the same one-liner plus `-s -- <command>`: `configure`
  (change settings), `update`, `status`, `share`, `logs`, `restart`, `remove`,
  `remove --purge`.
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

## License

[AGPL-3.0](LICENSE). If you run a modified relay or ship a modified app, publish
your changes.
