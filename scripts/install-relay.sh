#!/bin/sh
# zelt relay installer: runs an always-on zelt relay in Docker on your server
# and keeps it up to date with the GitHub repository.
#
#   curl -fsSL https://raw.githubusercontent.com/gut-engel/zelt/main/scripts/install-relay.sh | sh
#
# It asks a few questions (port, public address, auto-update), saves the answers
# to ~/.config/zelt-relay/relay.env and starts the relay. More commands (same
# one-liner, add "-s -- <command>"):
#   configure      ask the questions again and restart with the new settings
#   update [vX.Y.Z] [--force]
#                  install the newest signed release now (or that release),
#                  rebuild, restart (keeps the relay key); --force rebuilds even
#                  if that version is already running
#   check          show the installed and the newest signed release (installs nothing)
#   status         container state, running revision, auto-update schedule
#   share          print the share string(s) to add in the app
#   logs           follow the relay log
#   restart        restart the container with the saved settings
#   remove         stop and delete the container and the update schedule
#   remove --purge also delete the key volume, image, source checkout and settings
#
# Unattended install: set ZELT_YES=1 (or run without a terminal) and pass any of
#   ZELT_PORT, ZELT_PUBLIC_IP, ZELT_PEERS, ZELT_MEMORY, ZELT_AUTO_UPDATE (1/0),
#   ZELT_UPDATE_EVERY (hourly/daily), ZELT_REPO, ZELT_REF
# as environment variables. ZELT_SCHEDULER=cron uses cron instead of systemd.
#
# Signed releases only: by default the relay is built from the newest release
# tag vX.Y.Z whose SSH signature verifies against the zelt release key pinned
# below (git verify-tag). ZELT_REF=vX.Y.Z pins a specific (still verified)
# tag. Opting out, e.g. for a fork or development, builds an unverified branch:
#   ZELT_VERIFY=0 ZELT_REF=main ...      (not recommended)
# A fork can pin its own key with ZELT_SIGNERS=/path/to/allowed_signers.
#
# What it does: clones the source into ~/.local/share/zelt-relay/src, builds the
# image from relay/Dockerfile, and runs it as an unprivileged, read-only
# container with host networking (IPv4 and IPv6). Message blobs stay in RAM; only
# the relay's key is kept, in the Docker volume "zelt-relay-data". Auto-update
# compares the image's git revision with GitHub and rebuilds only when it changed.
# It never touches your firewall; it tells you which port to open.

set -eu

NAME="zelt-relay"
IMAGE="zelt-relay:latest"
VOLUME="zelt-relay-data"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/zelt-relay"
SRC="$DATA_HOME/src"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/zelt-relay"
CONF="$CONF_DIR/relay.env"
UNIT="zelt-relay-update"
VERSION_FILE="$DATA_HOME/version"
WANT_TAG=""

# The zelt release signing key (SSH Ed25519). Pinned here, not read from the
# repository, so a compromised repository cannot change what is trusted.
ALLOWED_SIGNERS='zelt-release namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII4vO9juxw03g1ZPhkhqJxq5peudg73XknhfZgrnM+qi zelt-release'
CRON_TAG="# zelt-relay-update"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- Settings ------------------------------------------------------------------

load_config() {
  # Saved settings first, then the environment wins.
  _env_port="${ZELT_PORT:-}"; _env_ip="${ZELT_PUBLIC_IP:-}"; _env_peers="${ZELT_PEERS:-}"
  _env_mem="${ZELT_MEMORY:-}"; _env_au="${ZELT_AUTO_UPDATE:-}"; _env_every="${ZELT_UPDATE_EVERY:-}"
  _env_repo="${ZELT_REPO:-}"; _env_ref="${ZELT_REF:-}"; _env_verify="${ZELT_VERIFY:-}"
  # shellcheck disable=SC1090
  [ -f "$CONF" ] && . "$CONF"
  ZELT_PORT="${_env_port:-${ZELT_PORT:-47017}}"
  ZELT_PUBLIC_IP="${_env_ip:-${ZELT_PUBLIC_IP:-}}"
  ZELT_PEERS="${_env_peers:-${ZELT_PEERS:-}}"
  ZELT_MEMORY="${_env_mem:-${ZELT_MEMORY:-256m}}"
  ZELT_AUTO_UPDATE="${_env_au:-${ZELT_AUTO_UPDATE:-1}}"
  ZELT_UPDATE_EVERY="${_env_every:-${ZELT_UPDATE_EVERY:-hourly}}"
  ZELT_REPO="${_env_repo:-${ZELT_REPO:-https://github.com/gut-engel/zelt.git}}"
  # Settings saved before signed releases existed tracked "main" by default;
  # that now means "newest signed release".
  if [ -z "$_env_ref" ] && [ -z "${ZELT_VERIFY:-}" ] && [ "${ZELT_REF:-}" = main ]; then ZELT_REF=signed; fi
  ZELT_REF="${_env_ref:-${ZELT_REF:-signed}}"
  ZELT_VERIFY="${_env_verify:-${ZELT_VERIFY:-1}}"
}

q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

save_config() {
  mkdir -p "$CONF_DIR"
  umask 077
  {
    say "# zelt relay settings. Edit, then run: install-relay.sh restart"
    say "ZELT_PORT=$(q "$ZELT_PORT")"
    say "ZELT_PUBLIC_IP=$(q "$ZELT_PUBLIC_IP")"
    say "ZELT_PEERS=$(q "$ZELT_PEERS")"
    say "ZELT_MEMORY=$(q "$ZELT_MEMORY")"
    say "ZELT_AUTO_UPDATE=$(q "$ZELT_AUTO_UPDATE")"
    say "ZELT_UPDATE_EVERY=$(q "$ZELT_UPDATE_EVERY")"
    say "ZELT_REPO=$(q "$ZELT_REPO")"
    say "ZELT_REF=$(q "$ZELT_REF")"
    say "ZELT_VERIFY=$(q "$ZELT_VERIFY")"
  } > "$CONF"
}

interactive() {
  [ "${ZELT_YES:-0}" != 1 ] && [ -r /dev/tty ] && [ -w /dev/tty ] && { : < /dev/tty; } 2>/dev/null
}

# ask VAR "Question" — default is VAR's current value; answers come from the tty
# because stdin is the script itself under "curl | sh".
ask() {
  _var="$1"; _q="$2"
  eval "_def=\${$_var}"
  printf '%s [%s]: ' "$_q" "$_def" > /dev/tty
  IFS= read -r _ans < /dev/tty || _ans=""
  [ -n "$_ans" ] && eval "$_var=\$_ans"
  return 0
}

ask_yn() {
  _var="$1"; _q="$2"
  eval "_def=\${$_var}"
  [ "$_def" = 1 ] && _hint="Y/n" || _hint="y/N"
  printf '%s [%s]: ' "$_q" "$_hint" > /dev/tty
  IFS= read -r _ans < /dev/tty || _ans=""
  case "$_ans" in
    [Yy]*) eval "$_var=1" ;;
    [Nn]*) eval "$_var=0" ;;
  esac
  return 0
}

valid_port() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

configure() {
  [ -z "$ZELT_PUBLIC_IP" ] && ZELT_PUBLIC_IP="$(detect_ips | paste -sd, -)"
  if interactive; then
    say "" > /dev/tty
    say "zelt relay setup (press Enter to keep the value in brackets)" > /dev/tty
    while :; do
      ask ZELT_PORT "TCP port"
      valid_port "$ZELT_PORT" && break
      say "  please enter a number from 1 to 65535" > /dev/tty
      ZELT_PORT=47017
    done
    [ -n "$ZELT_PUBLIC_IP" ] || say "  no public address detected (behind NAT? then forward the port and enter your public IP)" > /dev/tty
    ask ZELT_PUBLIC_IP "Public IP address(es) to advertise, comma-separated"
    ask ZELT_PEERS "Other relays to announce to (zelt-relay:... strings, optional)"
    ask ZELT_MEMORY "Memory limit for the container"
    ask_yn ZELT_AUTO_UPDATE "Update automatically from GitHub"
    if [ "$ZELT_AUTO_UPDATE" = 1 ]; then
      while :; do
        ask ZELT_UPDATE_EVERY "Check for updates hourly or daily"
        case "$ZELT_UPDATE_EVERY" in hourly | daily) break ;; esac
        say "  please answer hourly or daily" > /dev/tty
        ZELT_UPDATE_EVERY=hourly
      done
    fi
    say "" > /dev/tty
    say "  port: $ZELT_PORT   public: ${ZELT_PUBLIC_IP:-none}   memory: $ZELT_MEMORY" > /dev/tty
    [ "$ZELT_AUTO_UPDATE" = 1 ] && say "  auto-update: $ZELT_UPDATE_EVERY, signed releases from $ZELT_REPO" > /dev/tty \
      || say "  auto-update: off" > /dev/tty
    _ok=1
    ask_yn _ok "Continue"
    [ "$_ok" = 1 ] || die "aborted"
  fi
  valid_port "$ZELT_PORT" || die "invalid port '$ZELT_PORT'"
  [ -n "$ZELT_PUBLIC_IP" ] || die "no public IP address found (behind NAT?). Forward TCP $ZELT_PORT and set ZELT_PUBLIC_IP."
  save_config
  say "settings saved to $CONF"
}

# Public addresses on this machine, without asking any outside service.
detect_ips() {
  command -v ip >/dev/null 2>&1 || return 0
  {
    ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 |
      grep -Ev '^(10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' || true
    ip -6 -o addr show scope global -temporary -deprecated 2>/dev/null | awk '{print $4}' | cut -d/ -f1 |
      grep -E '^[23]' || true
  } | sort -u
}

# --- Docker ----------------------------------------------------------------------

need_tools() {
  command -v docker >/dev/null 2>&1 || die "Docker is not installed. See https://docs.docker.com/engine/install/"
  docker info >/dev/null 2>&1 || die "cannot talk to Docker. Run with sudo, or add your user to the 'docker' group."
  command -v git >/dev/null 2>&1 || die "git is not installed (needed to fetch and update the source)."
  if [ "${ZELT_VERIFY:-1}" = 1 ]; then
    command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen is needed to verify release signatures (install openssh-client)."
  fi
}

signers_file() {
  if [ -n "${ZELT_SIGNERS:-}" ]; then
    printf '%s\n' "$ZELT_SIGNERS"
    return
  fi
  mkdir -p "$DATA_HOME"
  printf '%s\n' "$ALLOWED_SIGNERS" > "$DATA_HOME/allowed_signers"
  printf '%s\n' "$DATA_HOME/allowed_signers"
}

valid_tag() { printf '%s\n' "$1" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; }

installed_tag() { cat "$VERSION_FILE" 2>/dev/null || true; }

# True if version $1 is older than $2.
older_than() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]; }

# The tag to build: one asked for on the command line, the pinned ZELT_REF, or
# the newest vX.Y.Z.
target_tag() {
  if [ -n "$WANT_TAG" ]; then
    printf '%s\n' "$WANT_TAG"
    return
  fi
  if [ "$ZELT_REF" != signed ]; then
    printf '%s\n' "$ZELT_REF"
    return
  fi
  git ls-remote --tags --refs "$ZELT_REPO" 'v*' 2>/dev/null | awk '{print $2}' | sed 's#refs/tags/##' |
    grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1
}

# Fetches tag $1 into the checkout (without checking it out) and verifies its
# signature against the pinned key.
fetch_verified_tag() {
  if [ -d "$SRC/.git" ]; then
    git -C "$SRC" remote set-url origin "$ZELT_REPO"
    git -C "$SRC" fetch -q --depth 1 --force origin "refs/tags/$1:refs/tags/$1" || return 1
  else
    mkdir -p "$DATA_HOME"
    git clone -q --depth 1 --no-checkout --branch "$1" "$ZELT_REPO" "$SRC" || return 1
  fi
  git -C "$SRC" -c gpg.format=ssh -c "gpg.ssh.allowedSignersFile=$(signers_file)" verify-tag "$1" >/dev/null 2>&1
}

fetch_source() {
  if [ "$ZELT_VERIFY" != 1 ]; then
    if [ -n "$WANT_TAG" ]; then ZELT_REF="$WANT_TAG"; fi
    say "WARNING: signature verification is OFF (ZELT_VERIFY=0); building unverified $ZELT_REF"
    if [ -d "$SRC/.git" ]; then
      git -C "$SRC" remote set-url origin "$ZELT_REPO"
      git -C "$SRC" fetch -q --depth 1 origin "$ZELT_REF"
      git -C "$SRC" checkout -q --force FETCH_HEAD
    else
      mkdir -p "$DATA_HOME"
      git clone -q --depth 1 --branch "$ZELT_REF" "$ZELT_REPO" "$SRC"
    fi
  else
    tag="$(target_tag)"
    [ -n "$tag" ] || die "no signed release (vX.Y.Z tag) found in $ZELT_REPO yet"
    valid_tag "$tag" || die "'$tag' is not a release tag (vX.Y.Z)"
    cur="$(installed_tag)"
    # Anti-rollback: only an explicit request may go back to an older release.
    if [ -z "$WANT_TAG" ] && [ -n "$cur" ] && older_than "$tag" "$cur"; then
      die "newest release found ($tag) is older than the installed $cur; tags may have been removed. Refusing to downgrade (to do it on purpose: update $tag)"
    fi
    fetch_verified_tag "$tag" || die "release $tag is NOT signed by the pinned zelt release key (or could not be fetched); refusing to build it"
    git -C "$SRC" checkout -q --force "refs/tags/$tag"
    if [ -n "$cur" ] && older_than "$tag" "$cur"; then say "WARNING: downgrading from $cur to $tag, as requested"; fi
    say "verified signed release $tag"
    BUILT_TAG="$tag"
  fi
  [ -f "$SRC/relay/Dockerfile" ] || die "relay/Dockerfile not found in $SRC"
}

build_image() {
  rev="$(git -C "$SRC" rev-parse HEAD)"
  say "building $IMAGE at ${rev%"${rev#????????????}"} (first build takes a few minutes)"
  docker build -q --build-arg "ZELT_REVISION=$rev" -t "$IMAGE" -f "$SRC/relay/Dockerfile" "$SRC" >/dev/null
}

running_revision() {
  docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$IMAGE" 2>/dev/null || true
}

run_container() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker run -d --name "$NAME" \
    --restart unless-stopped \
    --network host \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --memory "$ZELT_MEMORY" \
    --pids-limit 100 \
    --log-opt max-size=1m --log-opt max-file=3 \
    -e "ZELT_PORT=$ZELT_PORT" \
    -e "ZELT_PUBLIC_IP=$ZELT_PUBLIC_IP" \
    -e "ZELT_PEERS=$ZELT_PEERS" \
    -v "$VOLUME:/data" \
    "$IMAGE" >/dev/null
  say "relay running on TCP $ZELT_PORT"
  if [ -n "${BUILT_TAG:-}" ]; then
    mkdir -p "$DATA_HOME"
    printf '%s\n' "$BUILT_TAG" > "$VERSION_FILE"
  elif [ "$ZELT_VERIFY" != 1 ]; then
    rm -f "$VERSION_FILE"
  fi
}

show_share() {
  i=0
  while [ $i -lt 20 ]; do
    logs="$(docker logs "$NAME" 2>&1 || true)"
    out="$(printf '%s\n' "$logs" | grep 'zelt-relay:' | tail -n 8 || true)"
    if [ -n "$out" ]; then
      say ""
      say "Add this in the zelt app under Settings > Network and peers > Add relay:"
      printf '%s\n' "$out" | sed 's/^ */  /'
      say ""
      say "Or scan it in the app (Network > Scan relay QR):"
      # The relay draws its own QR code (no extra tools needed).
      qr="$(printf '%s\n' "$logs" | sed -n '/-----BEGIN ZELT RELAY QR-----/,/-----END ZELT RELAY QR-----/p' |
        grep -v -- '-----' | tail -n 60)"
      if [ -n "$qr" ]; then
        printf '%s\n' "$qr"
      elif command -v qrencode >/dev/null 2>&1; then
        qrencode -t ansiutf8 -m 2 "$(printf '%s\n' "$out" | head -n1 | sed 's/^ *//')"
      else
        say "(this relay image is too old to draw a QR code; run: ... | sh -s -- update)"
      fi
      return
    fi
    i=$((i + 1))
    sleep 1
  done
  say "relay did not report its address yet; check:  docker logs $NAME"
}

firewall_hint() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    say "ufw is active. Open the port with:  sudo ufw allow $ZELT_PORT/tcp"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    say "firewalld is active. Open the port with:"
    say "  sudo firewall-cmd --permanent --add-port=$ZELT_PORT/tcp && sudo firewall-cmd --reload"
  else
    say "Make sure TCP $ZELT_PORT is reachable from the internet (cloud firewall / security group)."
  fi
}

# --- Auto-update schedule ----------------------------------------------------------

# The scheduled job runs the copy of this script inside the source checkout, so
# the updater itself is updated along with the relay.
update_cmd() { printf '/bin/sh %s auto-update' "$SRC/scripts/install-relay.sh"; }

have_systemd() {
  [ "${ZELT_SCHEDULER:-auto}" != cron ] && [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1
}

schedule_remove() {
  if have_systemd; then
    if [ "$(id -u)" = 0 ]; then
      systemctl disable --now "$UNIT.timer" >/dev/null 2>&1 || true
      rm -f "/etc/systemd/system/$UNIT.service" "/etc/systemd/system/$UNIT.timer"
      systemctl daemon-reload >/dev/null 2>&1 || true
    else
      systemctl --user disable --now "$UNIT.timer" >/dev/null 2>&1 || true
      rm -f "$HOME/.config/systemd/user/$UNIT.service" "$HOME/.config/systemd/user/$UNIT.timer"
      systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
  fi
  if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then
    crontab -l 2>/dev/null | grep -vF "$CRON_TAG" | crontab -
  fi
}

schedule_install() {
  schedule_remove
  [ "$ZELT_AUTO_UPDATE" = 1 ] || { say "auto-update: off"; return; }
  if have_systemd; then
    if [ "$(id -u)" = 0 ]; then dir=/etc/systemd/system; sc="systemctl"
    else dir="$HOME/.config/systemd/user"; sc="systemctl --user"; fi
    mkdir -p "$dir"
    cat > "$dir/$UNIT.service" <<EOF
[Unit]
Description=Update the zelt relay from GitHub when a new revision exists

[Service]
Type=oneshot
Environment=HOME=$HOME
ExecStart=$(update_cmd)
EOF
    cat > "$dir/$UNIT.timer" <<EOF
[Unit]
Description=Check for zelt relay updates

[Timer]
OnCalendar=$ZELT_UPDATE_EVERY
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    if ! { $sc daemon-reload && $sc enable --now "$UNIT.timer"; } >/dev/null 2>&1; then
      say "warning: could not enable the systemd timer ($sc enable --now $UNIT.timer)."
      say "  Retry with ZELT_SCHEDULER=cron, or run updates yourself with: ... | sh -s -- update"
      return 0
    fi
    say "auto-update: $ZELT_UPDATE_EVERY via systemd timer $UNIT.timer"
    if [ "$(id -u)" != 0 ] && command -v loginctl >/dev/null 2>&1 &&
      ! loginctl show-user "$(id -un)" -p Linger 2>/dev/null | grep -q yes; then
      say "  note: user timers stop when you log out. Keep them running with:"
      say "    sudo loginctl enable-linger $(id -un)"
    fi
  elif command -v crontab >/dev/null 2>&1; then
    m=$(( $(od -An -N1 -tu1 /dev/urandom | tr -d ' ') % 60 ))
    [ "$ZELT_UPDATE_EVERY" = daily ] && spec="$m 4 * * *" || spec="$m * * * *"
    { crontab -l 2>/dev/null || true; say "$spec $(update_cmd) >/dev/null 2>&1 $CRON_TAG"; } | crontab -
    say "auto-update: $ZELT_UPDATE_EVERY via cron"
  else
    say "auto-update: no systemd or cron found; run '... | sh -s -- update' yourself now and then"
  fi
}

# --- Commands ------------------------------------------------------------------------

cmd_install() {
  need_tools
  load_config
  configure
  fetch_source
  build_image
  run_container
  schedule_install
  show_share
  say ""
  firewall_hint
}

cmd_update() {
  force=0
  for a in "$@"; do
    case "$a" in
      --force) force=1 ;;
      v*) valid_tag "$a" || die "'$a' is not a release version (vX.Y.Z)"; WANT_TAG="$a" ;;
      *) die "usage: update [vX.Y.Z] [--force]" ;;
    esac
  done
  need_tools
  load_config
  [ -f "$CONF" ] || die "not installed yet; run the installer first"
  fetch_source
  if [ "$force" = 0 ] && [ "$(git -C "$SRC" rev-parse HEAD)" = "$(running_revision)" ] &&
    docker ps -q --filter "name=^$NAME\$" | grep -q .; then
    say "already running ${BUILT_TAG:-this revision}; nothing to do (update --force rebuilds anyway)"
    if [ -n "${BUILT_TAG:-}" ]; then
      mkdir -p "$DATA_HOME"
      printf '%s\n' "$BUILT_TAG" > "$VERSION_FILE"
    fi
    return 0
  fi
  build_image
  run_container
  docker image prune -f --filter "label=org.opencontainers.image.title=zelt relay" >/dev/null 2>&1 || true
}

# Shows what an update would install, verified, without installing anything.
cmd_check() {
  command -v git >/dev/null 2>&1 || die "git is required"
  load_config
  cur="$(installed_tag)"
  say "installed: ${cur:-unknown} (revision $(running_revision 2>/dev/null || true))"
  if [ "$ZELT_VERIFY" != 1 ]; then
    say "signature verification is OFF; tracking $ZELT_REF unverified"
    return
  fi
  tag="$(target_tag)"
  if [ -z "$tag" ]; then
    say "no signed release found in $ZELT_REPO"
    return 1
  fi
  if ! valid_tag "$tag" || ! fetch_verified_tag "$tag"; then
    say "newest release: $tag (NOT signed by the pinned release key; it will not be installed)"
    return 1
  fi
  say "newest signed release: $tag (signature verified)"
  if [ -z "$cur" ] || older_than "$cur" "$tag"; then
    say "update available: run this installer with '-s -- update'"
  elif older_than "$tag" "$cur"; then
    say "WARNING: the newest release found is older than the installed one; tags may have been removed"
  else
    say "up to date"
  fi
}

# Scheduled: rebuild only if GitHub has a revision we are not running.
cmd_auto_update() {
  need_tools
  load_config
  [ "$ZELT_AUTO_UPDATE" = 1 ] || exit 0
  if [ "$ZELT_VERIFY" = 1 ]; then
    tag="$(target_tag)"
    [ -n "$tag" ] || { say "no signed release found; keeping the current version"; exit 0; }
    # Commit the tag points to (peeled), compared with the running image.
    remote="$(git ls-remote "$ZELT_REPO" "refs/tags/$tag^{}" "refs/tags/$tag" 2>/dev/null | head -n1 | cut -f1)"
  else
    remote="$(git ls-remote "$ZELT_REPO" "refs/heads/$ZELT_REF" "refs/tags/$ZELT_REF" 2>/dev/null | head -n1 | cut -f1)"
  fi
  [ -n "$remote" ] || { say "could not reach $ZELT_REPO"; exit 0; }
  [ "$remote" = "$(running_revision)" ] && exit 0
  say "$(date -u +%FT%TZ) updating zelt relay to $remote"
  # fetch_source verifies the signature and stops before building if it fails.
  ( fetch_source ) || { say "update not verified; keeping the current version"; exit 0; }
  if [ "$ZELT_VERIFY" = 1 ]; then BUILT_TAG="$tag"; fi
  build_image
  run_container
  docker image prune -f --filter "label=org.opencontainers.image.title=zelt relay" >/dev/null 2>&1 || true
}

cmd_status() {
  need_tools
  load_config
  docker ps --filter "name=^$NAME\$" --format '{{.Names}}: {{.Status}}' | grep . || say "not running"
  say "version: $(installed_tag) (revision $(running_revision))"
  say "settings: $CONF"
  if have_systemd && { systemctl list-timers "$UNIT.timer" 2>/dev/null; systemctl --user list-timers "$UNIT.timer" 2>/dev/null; } | grep -q "$UNIT"; then
    say "auto-update: systemd timer $UNIT.timer"
  elif command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then
    say "auto-update: cron"
  else
    say "auto-update: off"
  fi
}

cmd_remove() {
  command -v docker >/dev/null 2>&1 || die "Docker is not installed"
  schedule_remove
  docker rm -f "$NAME" >/dev/null 2>&1 && say "container removed" || say "no container named $NAME"
  if [ "${1:-}" = "--purge" ]; then
    docker volume rm "$VOLUME" >/dev/null 2>&1 && say "key volume removed" || true
    docker image rm "$IMAGE" >/dev/null 2>&1 && say "image removed" || true
    case "$DATA_HOME" in */zelt-relay) rm -rf -- "$DATA_HOME" && say "source removed" ;; esac
    case "$CONF_DIR" in */zelt-relay) rm -rf -- "$CONF_DIR" && say "settings removed" ;; esac
  fi
}

main() {
  cmd="${1:-install}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    install) cmd_install ;;
    configure) need_tools; load_config; configure; [ -d "$SRC/.git" ] || fetch_source
               [ -n "$(running_revision)" ] || build_image; run_container; schedule_install; show_share ;;
    update) cmd_update "$@"; show_share ;;
    check) cmd_check ;;
    auto-update) cmd_auto_update ;;
    restart) need_tools; load_config; run_container ;;
    status) cmd_status ;;
    share) need_tools; show_share ;;
    logs) need_tools; docker logs -f --tail 50 "$NAME" ;;
    remove) cmd_remove "$@" ;;
    *) die "unknown command '$cmd' (install, configure, update [vX.Y.Z] [--force], check, status, share, logs, restart, remove [--purge])" ;;
  esac
}

# Everything above only defines functions, so a partially downloaded script
# does nothing.
main "$@"
