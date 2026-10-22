#!/bin/bash
# Tests install-relay.sh signature checks against a local repository with real
# SSH signatures. Docker is stubbed; nothing touches the system.
#   scripts/test/install-relay-verify-test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home"

# Docker stub: records calls, pretends builds succeed.
cat > "$T/bin/docker" <<STUB
#!/bin/sh
echo "docker \$*" >> "$T/docker.log"
case "\$1" in
  info) exit 0 ;;
  logs) echo "  zelt-relay:203.0.113.7:47017/KEY" ;;
  image) cat "$T/built" 2>/dev/null ;;
  build) for a in "\$@"; do case "\$a" in ZELT_REVISION=*) echo "\${a#ZELT_REVISION=}" > "$T/built" ;; esac; done ;;
esac
exit 0
STUB
chmod +x "$T/bin/docker"

# Keys: "release" (pinned in the test) and "other" (not trusted).
ssh-keygen -q -t ed25519 -N "" -C release -f "$T/release"
ssh-keygen -q -t ed25519 -N "" -C other -f "$T/other"
echo "zelt-release namespaces=\"git\" $(cat "$T/release.pub")" > "$T/allowed_signers"

# A repository with relay/Dockerfile and several tags.
R="$T/repo"
git init -q -b main "$R"
mkdir -p "$R/relay" && echo "FROM scratch" > "$R/relay/Dockerfile"
G="git -C $R -c user.name=t -c user.email=t@example.invalid -c gpg.format=ssh"
$G add -A && $G commit -q -m one
$G -c user.signingkey="$T/release.pub" tag -s v1.0.0 -m "good release"
echo 2 > "$R/f" && $G add -A && $G commit -q -m two
$G tag -a v1.1.0 -m "unsigned"                                   # newest tag, unsigned
echo 3 > "$R/f" && $G add -A && $G commit -q -m three          # unsigned main

run() { env -i HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" ZELT_YES=1 ZELT_SCHEDULER=cron \
  ZELT_REPO="file://$R" ZELT_PUBLIC_IP=203.0.113.7 ZELT_AUTO_UPDATE=0 ZELT_SIGNERS="$T/allowed_signers" "$@"; }
pass=0; fail=0
check() { if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }

# 1. Newest tag v1.1.0 is unsigned: refuse to build.
out=$(run sh "$ROOT/scripts/install-relay.sh" 2>&1 || true)
check "unsigned newest tag is refused" '[[ "$out" == *"NOT signed by the pinned zelt release key"* ]] && ! grep -q "docker build" "$T/docker.log" 2>/dev/null'

# 2. Pinned signed tag v1.0.0 builds that exact commit.
rm -rf "$T/home"; mkdir -p "$T/home"
out=$(run ZELT_REF=v1.0.0 sh "$ROOT/scripts/install-relay.sh" 2>&1 || true)
want=$(git -C "$R" rev-parse v1.0.0^{commit})
check "signed tag is verified and built" '[[ "$out" == *"verified signed release v1.0.0"* ]] && [ "$(cat "$T/built")" = "$want" ]'

# 3. A tag signed with another key is refused.
$G -c user.signingkey="$T/other.pub" tag -s v1.2.0 -m "wrong key"
rm -rf "$T/home"; mkdir -p "$T/home"
out=$(run ZELT_REF=v1.2.0 sh "$ROOT/scripts/install-relay.sh" 2>&1 || true)
check "tag signed by an untrusted key is refused" '[[ "$out" == *"NOT signed"* ]]'

# 4. Newest tag correctly signed again: chosen automatically.
$G -c user.signingkey="$T/release.pub" tag -s v1.3.0 -m "good again"
rm -rf "$T/home"; mkdir -p "$T/home"
out=$(run sh "$ROOT/scripts/install-relay.sh" 2>&1 || true)
check "newest signed tag is picked by default" '[[ "$out" == *"verified signed release v1.3.0"* ]]'

# 5. Auto-update: a newer but unsigned tag must not replace the running build.
before=$(cat "$T/built")
echo 4 > "$R/f" && $G add -A && $G commit -q -m four
$G tag -a v1.4.0 -m "unsigned update"
out=$(run ZELT_AUTO_UPDATE=1 sh "$T/home/.local/share/zelt-relay/src/scripts/install-relay.sh" auto-update 2>&1 || \
      run ZELT_AUTO_UPDATE=1 sh "$ROOT/scripts/install-relay.sh" auto-update 2>&1 || true)
check "unsigned update is not installed" '[ "$(cat "$T/built")" = "$before" ] && [[ "$out" == *"keeping the current version"* ]]'

# 6. Settings saved by the old installer (ZELT_REF=main, no ZELT_VERIFY) move
#    to signed releases instead of getting stuck.
git -C "$R" tag -d v1.4.0 >/dev/null   # leave v1.3.0 as the newest (signed) tag
rm -rf "$T/home"; mkdir -p "$T/home/.config/zelt-relay"
printf "ZELT_PORT='47017'\nZELT_PUBLIC_IP='203.0.113.7'\nZELT_REF='main'\nZELT_REPO='file://%s'\n" "$R" > "$T/home/.config/zelt-relay/relay.env"
out=$(env -i HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" ZELT_YES=1 ZELT_SCHEDULER=cron ZELT_AUTO_UPDATE=0 ZELT_SIGNERS="$T/allowed_signers" \
  sh "$ROOT/scripts/install-relay.sh" 2>&1 || true)
check "old 'main' setting migrates to signed releases" '[[ "$out" == *"verified signed release v1.3.0"* ]]'

# 7. The pinned key in the installer is the real release key.
check "installer pins the release key" 'grep -q "AAAAC3NzaC1lZDI1NTE5AAAAII4vO9juxw03g1ZPhkhqJxq5peudg73XknhfZgrnM+qi" "$ROOT/scripts/install-relay.sh"'

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
