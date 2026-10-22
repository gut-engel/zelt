#!/bin/sh
# Temporary zelt relay on a server, for testing across networks.
#
#   ZELT_HOST=myserver scripts/relay_test_deploy.sh          deploy, auto-removes itself after 15 minutes
#   ZELT_HOST=myserver scripts/relay_test_deploy.sh remove   remove it right now
#   ZELT_HOST=myserver scripts/relay_test_deploy.sh status   show whether it is running and its share strings
#
# Settings (environment): ZELT_HOST (required, an ssh host from your ~/.ssh/config),
# ZELT_PORT (default 47017), ZELT_MINUTES (default 15).
#
# What it does on the server, and nothing else:
#   - creates ~/zelt-relay-test/ with the relay binary, its key file and its log
#   - starts that binary as your user (no root, no firewall changes, no cron/systemd)
#   - starts one background "sleep, then clean up" process
# Clean-up (automatic or "remove") only kills the relay process it started (checked by
# PID and command line) and deletes ~/zelt-relay-test/ (only if its marker file exists).
set -eu

HOST="${ZELT_HOST:?set ZELT_HOST to your server, e.g. ZELT_HOST=myserver $0}"
PORT="${ZELT_PORT:-47017}"
MINUTES="${ZELT_MINUTES:-15}"
SECONDS_LEFT="${ZELT_SECONDS:-$((MINUTES * 60))}"
DIR_NAME="zelt-relay-test"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/relay/zelt_relay"

# Runs on the server. Removes only the relay this script started and its folder.
REMOTE_CLEANUP='
D="$HOME/'"$DIR_NAME"'"
[ -f "$D/.zelt-relay-test" ] || { echo "nothing to remove"; exit 0; }
# Stop the pending auto-removal timer too (unless it is the one running us).
if [ -f "$D/timer.pid" ]; then
  T=$(cat "$D/timer.pid")
  if [ "$T" != "$$" ] && [ "$T" != "$PPID" ] && [ -r "/proc/$T/cmdline" ] && tr "\0" " " < "/proc/$T/cmdline" | grep -q "$D/cleanup.sh"; then
    kill "$T" 2>/dev/null || true
  fi
fi
if [ -f "$D/relay.pid" ]; then
  P=$(cat "$D/relay.pid")
  if [ -r "/proc/$P/cmdline" ] && tr "\0" " " < "/proc/$P/cmdline" | grep -q "$D/zelt_relay"; then
    kill "$P" 2>/dev/null || true
    sleep 1
    kill -9 "$P" 2>/dev/null || true
  fi
fi
rm -rf -- "$D"
echo "zelt test relay removed"
'

case "${1:-deploy}" in
  remove)
    printf '%s\n' "$REMOTE_CLEANUP" | ssh "$HOST" sh -s
    exit 0
    ;;
  status)
    ssh "$HOST" "D=\$HOME/$DIR_NAME; if [ -f \$D/relay.pid ] && kill -0 \$(cat \$D/relay.pid) 2>/dev/null; then echo running; grep 'zelt-relay:' \$D/relay.log; else echo 'not running'; fi"
    exit 0
    ;;
  deploy) ;;
  *) echo "usage: $0 [deploy|remove|status]" >&2; exit 64 ;;
esac

if [ ! -x "$BIN" ]; then
  echo "building relay binary..."
  (cd "$ROOT/packages/zelt_core" && dart compile exe bin/zelt_relay.dart -o "$BIN")
fi

ARCH=$(ssh "$HOST" uname -m)
if [ "$ARCH" != "x86_64" ]; then
  echo "server is $ARCH; this binary is x86_64. Build on the server instead." >&2
  exit 1
fi

echo "copying relay to $HOST:~/$DIR_NAME/ ..."
ssh "$HOST" "mkdir -p \$HOME/$DIR_NAME && touch \$HOME/$DIR_NAME/.zelt-relay-test"
scp -q "$BIN" "$HOST:$DIR_NAME/zelt_relay"

echo "starting relay on port $PORT, auto-removal in $SECONDS_LEFT seconds ..."
# shellcheck disable=SC2087
ssh "$HOST" sh -s <<EOF
set -eu
D="\$HOME/$DIR_NAME"
cd "\$D"
chmod 700 zelt_relay
nohup setsid "\$D/zelt_relay" --port $PORT --state "\$D/relay-key.json" > "\$D/relay.log" 2>&1 < /dev/null &
echo \$! > "\$D/relay.pid"
cat > "\$D/cleanup.sh" <<'CLEAN'
$REMOTE_CLEANUP
CLEAN
nohup setsid sh -c "sleep $SECONDS_LEFT; sh \"\$D/cleanup.sh\"" > /dev/null 2>&1 < /dev/null &
echo \$! > "\$D/timer.pid"
sleep 2
if kill -0 \$(cat "\$D/relay.pid") 2>/dev/null; then
  echo "relay running (pid \$(cat "\$D/relay.pid"))"
  grep 'zelt-relay:' "\$D/relay.log" || true
else
  echo "relay failed to start:"; cat "\$D/relay.log"
fi
EOF

echo
echo "Send me the zelt-relay:... line(s) above that use the server's PUBLIC address."
echo "If the server has a firewall, TCP $PORT must be reachable (this script does not change it)."
echo "Remove early with: ZELT_HOST=$HOST $0 remove"
