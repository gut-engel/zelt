#!/usr/bin/env bash
# Maintainer release: test, build, sign, tag, publish.
#
#   scripts/release.sh VERSION BUILD [-y]      (make publish runs it)
#
# 1. Refuses unless: on main, clean tree, the tag is new, the signing keys are
#    in ~/.config/zelt-signing, the app embeds that update key's public half,
#    the release SSH key matches scripts/allowed_signers and the installer pin,
#    and BUILD is higher than the build of the latest published release.
# 2. Runs every test suite and builds Android (signed APKs) and Linux.
# 3. Creates an SSH-signed tag vVERSION, verifies it, pushes main and the tag.
# 4. Waits for the Windows CI build of exactly that commit, downloads it.
# 5. Signs the update manifest locally (the key never leaves this machine),
#    verifies everything, and creates the GitHub release.
# -y skips the confirmation before pushing.
set -euo pipefail

V="${1:?usage: release.sh VERSION BUILD [-y]}"
B="${2:?usage: release.sh VERSION BUILD [-y]}"
YES="${3:-}"
TAG="v$V"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGNING_DIR="${SIGNING_DIR:-$HOME/.config/zelt-signing}"
DIST="$ROOT/dist/$V"
REPO="gut-engel/zelt"
cd "$ROOT"

say() { printf '\n== %s\n' "$*"; }
die() { printf 'release: %s\n' "$*" >&2; exit 1; }

say "preflight"
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version '$V' is not X.Y.Z"
[[ "$B" =~ ^[0-9]+$ ]] && [ "$B" -ge 1 ] && [ "$B" -lt 1000 ] || die "build '$B' must be 1..999 (Android adds 1000 x ABI)"
[ "$(git branch --show-current)" = main ] || die "not on main"
[ -z "$(git status --porcelain)" ] || die "working tree not clean"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG exists locally"
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 && die "tag $TAG exists on origin"
for f in zelt-release.jks keystore.properties update-signing.key release-ssh release-ssh.pub; do
  [ -f "$SIGNING_DIR/$f" ] || die "missing $SIGNING_DIR/$f"
done
command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || die "gh is not logged in"

pub=$(cd packages/zelt_core && dart run bin/zelt_sign.dart pubkey "$SIGNING_DIR/update-signing.key" 2>/dev/null | tail -n1)
grep -qF "'$pub'" lib/app/update_key.dart || die "lib/app/update_key.dart does not embed the public half of update-signing.key"
ssh_pub=$(awk '{print $1" "$2}' "$SIGNING_DIR/release-ssh.pub")
grep -qF "$ssh_pub" scripts/allowed_signers || die "release-ssh.pub is not in scripts/allowed_signers"
grep -qF "$ssh_pub" scripts/install-relay.sh || die "release-ssh.pub is not pinned in scripts/install-relay.sh"
grep -q "^version: $V+$B\$" pubspec.yaml || die "pubspec.yaml version is not $V+$B"

# The last published manifest (verified) must have a lower build number,
# or no app would ever install this release.
tmpd=$(mktemp -d)
trap 'rm -rf "$tmpd"' EXIT
if gh release download -R "$REPO" -p 'zelt-update.json*' -D "$tmpd" 2>/dev/null; then
  last=$(cd packages/zelt_core && dart run bin/zelt_sign.dart verify-manifest "$pub" "$tmpd/zelt-update.json" 2>/dev/null | sed -n 's/^build //p')
  [ -n "$last" ] || die "the latest published manifest does not verify"
  [ "$B" -gt "$last" ] || die "build $B is not higher than the published build $last"
  echo "latest published build: $last"
fi

say "tests"
make check
bash scripts/test/install-relay-verify-test.sh

say "build Android + Linux"
make dist

say "signed tag $TAG"
git -c user.signingkey="$SIGNING_DIR/release-ssh.pub" -c gpg.format=ssh tag -s "$TAG" -m "zelt $V"
git -c gpg.ssh.allowedSignersFile=scripts/allowed_signers verify-tag "$TAG" 2>&1 | grep -q 'Good "git" signature' ||
  { git tag -d "$TAG"; die "tag signature does not verify against scripts/allowed_signers"; }
SHA=$(git rev-parse "$TAG^{commit}")

if [ "$YES" != -y ]; then
  read -r -p "push main and $TAG ($SHA) to origin? [y/N] " a
  [ "$a" = y ] || { git tag -d "$TAG"; die "aborted (tag removed)"; }
fi
git push origin main
git push origin "$TAG"

say "waiting for the Windows build of $SHA"
run=""
for _ in $(seq 60); do
  run=$(gh run list -R "$REPO" --workflow windows.yml --json databaseId,headSha \
    --jq ".[] | select(.headSha == \"$SHA\") | .databaseId" | head -n1)
  [ -n "$run" ] && break
  sleep 10
done
[ -n "$run" ] || die "no Windows workflow run for $SHA"
gh run watch -R "$REPO" "$run" --exit-status --interval 30 >/dev/null || die "Windows build failed: gh run view $run"
gh run download -R "$REPO" "$run" -n windows-x64 -D "$tmpd/win"
[ "$(tr -d '\r\n ' < "$tmpd/win/commit.txt")" = "$SHA" ] || die "Windows artifact was not built from $SHA"
cp "$tmpd/win/zelt-$V-windows-x64.zip" "$DIST/"

say "sign and verify the update manifest"
make sign
make verify
(cd "$DIST" && sha256sum zelt-* > SHA256SUMS)

say "GitHub release $TAG"
notes="$tmpd/notes.md"
{
  echo "zelt $V"
  echo
  echo "Android: install the APK for your phone (arm64 for almost all current phones)."
  echo "Linux: unpack the tarball and run \`./zelt\`. Windows: unpack the zip and run \`zelt.exe\`."
  echo "Installed apps update themselves: every file is listed with its SHA-256 in"
  echo "\`zelt-update.json\`, which is signed with the zelt update key (Ed25519,"
  echo "public key \`$pub\`). The tag is SSH-signed (see \`scripts/allowed_signers\`)."
  echo
  echo "Relays installed with the one-line installer pick up this release on their own."
  echo
  echo '```'
  cat "$DIST/SHA256SUMS"
  echo '```'
} > "$notes"
gh release create "$TAG" -R "$REPO" --verify-tag --title "zelt $V" --notes-file "$notes" "$DIST"/*
echo "released $TAG"
