#!/bin/sh
# zelt relay installer: runs an always-on zelt relay in Docker on your server.
#
#   curl -fsSL https://raw.githubusercontent.com/OWNER/zelt/main/scripts/install-relay.sh | sh
#
# More commands (same one-liner, add "-s -- <command>"):
#   ... | sh -s -- update        pull the latest code, rebuild, restart (keeps the relay key)
#   ... | sh -s -- status        is it running?
#   ... | sh -s -- share         print the share string(s) to add in the app
#   ... | sh -s -- logs          follow the relay log
#   ... | sh -s -- remove        stop and delete the container
#   ... | sh -s -- remove --purge   also delete its key volume, image and source checkout
#
# Settings (environment variables):
#   ZELT_PORT=47017              TCP port the relay listens on
#   ZELT_PUBLIC_IP=ip[,ip]       public address(es) to advertise (auto-detected otherwise)
#   ZELT_REPO=<git url>          where to get the source (default: the official repo)
#   ZELT_REF=main                branch or tag to build
#
# What it does: clones the source into ~/.local/share/zelt-relay/src, builds the
# image from relay/Dockerfile, and runs it as an unprivileged, read-only
# container with host networking (so IPv4 and IPv6 both work). Message blobs stay
# in RAM; only the relay's key is kept, in the Docker volume "zelt-relay-data".
# It does not touch your firewall; it tells you which port to open.

set -eu

REPO="${ZELT_REPO:-https://github.com/OWNER/zelt.git}"
REF="${ZELT_REF:-main}"
PORT="${ZELT_PORT:-47017}"
SRC="${XDG_DATA_HOME:-$HOME/.local/share}/zelt-relay/src"
NAME="zelt-relay"
IMAGE="zelt-relay:latest"
VOLUME="zelt-relay-data"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker is not installed. See https://docs.docker.com/engine/install/"
  docker info >/dev/null 2>&1 || die "cannot talk to Docker. Run with sudo, or add your user to the 'docker' group."
}

fetch_source() {
  if [ -d "$SRC/.git" ]; then
    say "updating source in $SRC"
    git -C "$SRC" fetch --depth 1 origin "$REF"
    git -C "$SRC" checkout -q FETCH_HEAD
  elif command -v git >/dev/null 2>&1; then
    say "downloading source to $SRC"
    mkdir -p "$(dirname "$SRC")"
    git clone -q --depth 1 --branch "$REF" "$REPO" "$SRC"
  else
    command -v curl >/dev/null 2>&1 || die "need git or curl"
    say "downloading source archive to $SRC"
    web="${REPO%.git}"
    mkdir -p "$SRC"
    curl -fsSL "$web/archive/$REF.tar.gz" | tar -xz -C "$SRC" --strip-components=1
  fi
  [ -f "$SRC/relay/Dockerfile" ] || die "relay/Dockerfile not found in $SRC"
}

build_image() {
  say "building $IMAGE (first build takes a few minutes)"
  docker build -q -t "$IMAGE" -f "$SRC/relay/Dockerfile" "$SRC" >/dev/null
}

# Public addresses on this machine, without asking any outside service.
detect_ips() {
  if [ -n "${ZELT_PUBLIC_IP:-}" ]; then
    printf '%s\n' "$ZELT_PUBLIC_IP" | tr ',' '\n'
    return
  fi
  command -v ip >/dev/null 2>&1 || return 0
  ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 |
    grep -Ev '^(10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' || true
  ip -6 -o addr show scope global -temporary -deprecated 2>/dev/null | awk '{print $4}' | cut -d/ -f1 |
    grep -E '^[23]' || true
}

firewall_hint() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    say "ufw is active. Open the port with:  sudo ufw allow $PORT/tcp"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    say "firewalld is active. Open the port with:"
    say "  sudo firewall-cmd --permanent --add-port=$PORT/tcp && sudo firewall-cmd --reload"
  else
    say "Make sure TCP $PORT is reachable from the internet (cloud firewall / security group)."
  fi
}

run_container() {
  ips="$(detect_ips | sort -u)"
  if [ -z "$ips" ]; then
    die "no public IP address found on this machine (behind NAT?).
Set it explicitly and forward TCP $PORT to this machine, e.g.:
  ZELT_PUBLIC_IP=203.0.113.7 sh install-relay.sh"
  fi
  set -- --port "$PORT"
  for ip in $ips; do
    set -- "$@" --public-ip "$ip"
  done

  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker run -d --name "$NAME" \
    --restart unless-stopped \
    --network host \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --memory 256m \
    --pids-limit 100 \
    --log-opt max-size=1m --log-opt max-file=3 \
    -v "$VOLUME:/data" \
    "$IMAGE" "$@" >/dev/null
  say "relay started on TCP $PORT"
}

show_share() {
  i=0
  while [ $i -lt 15 ]; do
    out="$(docker logs "$NAME" 2>&1 | grep 'zelt-relay:' || true)"
    if [ -n "$out" ]; then
      say ""
      say "Add this in the zelt app under Settings > Network and peers > Add relay:"
      printf '%s\n' "$out" | sed 's/^ */  /'
      return
    fi
    i=$((i + 1))
    sleep 1
  done
  say "relay did not report its address yet; check:  docker logs $NAME"
}

cmd_install() {
  need_docker
  fetch_source
  build_image
  run_container
  show_share
  say ""
  firewall_hint
}

cmd_remove() {
  need_docker
  docker rm -f "$NAME" >/dev/null 2>&1 && say "container removed" || say "no container named $NAME"
  if [ "${1:-}" = "--purge" ]; then
    docker volume rm "$VOLUME" >/dev/null 2>&1 && say "key volume removed" || true
    docker image rm "$IMAGE" >/dev/null 2>&1 && say "image removed" || true
    case "$SRC" in
      */zelt-relay/src) rm -rf -- "$SRC" && say "source removed" ;;
    esac
  fi
}

main() {
  cmd="${1:-install}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    install | update) cmd_install ;;
    status) need_docker; docker ps --filter "name=^$NAME\$" --format '{{.Names}}: {{.Status}}' | grep . || say "not running" ;;
    share) need_docker; show_share ;;
    logs) need_docker; docker logs -f --tail 50 "$NAME" ;;
    remove) cmd_remove "$@" ;;
    *) die "unknown command '$cmd' (install, update, status, share, logs, remove [--purge])" ;;
  esac
}

# Everything above only defines functions, so a partially downloaded script
# does nothing.
main "$@"
