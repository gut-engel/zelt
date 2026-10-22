#!/bin/bash
# Tests scripts/install-linux.sh against a local release server signed with a
# throwaway key: install, update, downgrade refusal, tampered tarball,
# tampered manifest, wrong key, uninstall (with and without --purge).
#   scripts/test/install-linux-test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"
SERVER=""
trap '[ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null; rm -rf "$T"' EXIT
I="$ROOT/scripts/install-linux.sh"
SIGN() { (cd "$ROOT/packages/zelt_core" && dart run bin/zelt_sign.dart "$@" 2>/dev/null); }

KEY="$T/key"
PUB=$(SIGN keygen "$KEY" | tail -n1)
OTHER=$(SIGN keygen "$T/other" | tail -n1)

# A fake release: a bundle whose zelt binary is a script.
release() { # version build
  local v=$1 b=$2 d="$T/srv"
  rm -rf "$d" "$T/bundle" && mkdir -p "$d" "$T/bundle/data/flutter_assets" "$T/bundle/lib"
  printf '#!/bin/sh\necho zelt %s\n' "$v" > "$T/bundle/zelt" && chmod 755 "$T/bundle/zelt"
  printf '{"app_name":"zelt","version":"%s","build_number":"%s","package_name":"zelt"}' "$v" "$b" \
    > "$T/bundle/data/flutter_assets/version.json"
  cp "$ROOT/linux/zelt.svg" "$T/bundle/data/zelt.svg"
  tar -C "$T/bundle" -czf "$d/zelt-$v-linux-x64.tar.gz" .
  SIGN manifest "$KEY" "$d" "$v" "$b" >/dev/null
}

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
mkdir -p "$T/srv"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$T/srv" >/dev/null 2>&1 &
SERVER=$!
sleep 1

H="$T/home"
run() { env -i HOME="$H" PATH="/usr/bin:/bin" ZELT_BASE_URL="http://127.0.0.1:$PORT" ZELT_UPDATE_PUBKEY="$PUB" "$@"; }
pass=0; fail=0
check() { if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }
APP="$H/.local/share/zelt-app"
DESK="$H/.local/share/applications/dev.zelt.zelt.desktop"
build() { sed -n 's/.*"build_number":"\([0-9]*\)".*/\1/p' "$APP/data/flutter_assets/version.json"; }

# 1. Fresh install: app, launcher, icon, PATH link; the app dir is writable
#    by the user, which the self-updater needs.
release 1.0.0 1
out=$(run sh "$I" 2>&1 || true)
check "fresh install" '[[ "$out" == *"verified signed release 1.0.0 (build 1)"* ]] && [ "$("$APP/zelt")" = "zelt 1.0.0" ]'
check "desktop entry" 'grep -q "^Exec=\"$APP/zelt\"$" "$DESK" && grep -q "^Icon=dev.zelt.zelt$" "$DESK" && grep -q "^StartupWMClass=dev.zelt.zelt$" "$DESK"'
check "icon and PATH link" '[ -f "$H/.local/share/icons/hicolor/scalable/apps/dev.zelt.zelt.svg" ] && [ "$(readlink "$H/.local/bin/zelt")" = "$APP/zelt" ]'
check "app dir writable for self-update" '[ -w "$APP" ] && [ -w "$APP/zelt" ]'
if command -v desktop-file-validate >/dev/null; then
  check "desktop entry validates" 'desktop-file-validate "$DESK"'
fi

# 2. Update to a newer signed release.
release 1.1.0 3
out=$(run sh "$I" 2>&1 || true)
check "update to a newer release" '[ "$(build)" = 3 ] && [ "$("$APP/zelt")" = "zelt 1.1.0" ]'

# 3. An older signed release is refused unless forced.
release 1.0.5 2
out=$(run sh "$I" 2>&1 || true)
check "downgrade refused" '[[ "$out" == *"older than the installed build 3"* ]] && [ "$(build)" = 3 ]'
out=$(run ZELT_FORCE=1 sh "$I" 2>&1 || true)
check "downgrade with ZELT_FORCE=1" '[ "$(build)" = 2 ]'

# 4. Tampered tarball: checksum mismatch, installed app untouched.
release 1.2.0 4
printf 'x' >> "$T/srv/zelt-1.2.0-linux-x64.tar.gz"
out=$(run sh "$I" 2>&1 || true)
check "tampered tarball refused" '[[ "$out" == *"mismatch; refusing to install"* ]] && [ "$(build)" = 2 ]'

# 5. Tampered manifest: bad signature.
release 1.2.0 4
sed -i 's/"build": 4/"build": 5/' "$T/srv/zelt-update.json"
out=$(run sh "$I" 2>&1 || true)
check "tampered manifest refused" '[[ "$out" == *"NOT signed by the zelt update key"* ]] && [ "$(build)" = 2 ]'

# 6. Valid manifest, but signed by a key the installer does not trust.
release 1.2.0 4
out=$(run ZELT_UPDATE_PUBKEY="$OTHER" sh "$I" 2>&1 || true)
check "untrusted key refused" '[[ "$out" == *"NOT signed by the zelt update key"* ]] && [ "$(build)" = 2 ]'

# 7. The default pin is the real release key (same as the app's).
APPKEY=$(sed -n "s/^const updatePublicKey = '\(.*\)';/\1/p" "$ROOT/lib/app/update_key.dart")
check "installer pins the app's update key" 'grep -q "ZELT_UPDATE_PUBKEY:-$APPKEY}" "$I"'

# 8. Uninstall keeps the user's data; --purge with confirmation deletes it.
mkdir -p "$H/.local/share/dev.zelt.zelt/zelt" && echo secret > "$H/.local/share/dev.zelt.zelt/zelt/vault.json"
out=$(run sh "$I" uninstall < /dev/null 2>&1 || true)
check "uninstall keeps data" '[ ! -e "$APP" ] && [ ! -e "$DESK" ] && [ ! -e "$H/.local/bin/zelt" ] && [ -f "$H/.local/share/dev.zelt.zelt/zelt/vault.json" ]'
out=$(run setsid -w sh "$I" uninstall --purge < /dev/null 2>&1 || true)
check "purge without confirmation keeps data" '[ -f "$H/.local/share/dev.zelt.zelt/zelt/vault.json" ]'
out=$(run ZELT_PURGE_CONFIRM=delete setsid -w sh "$I" uninstall --purge < /dev/null 2>&1 || true)
check "purge with confirmation deletes data" '[ ! -e "$H/.local/share/dev.zelt.zelt" ]'

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
