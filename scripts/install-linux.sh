#!/bin/sh
# zelt for Linux: installs the latest release for this user, with a desktop
# entry, and leaves it able to update itself.
#
#   curl -fsSL https://raw.githubusercontent.com/gut-engel/zelt/main/scripts/install-linux.sh | sh
#
# Commands (same one-liner plus "-s -- <command>"):
#   install            install or update to the newest release (default)
#   uninstall          remove the app, its desktop entry and icon (keeps your data)
#   uninstall --purge  also delete your zelt identity, friends and messages
#
# Every download is verified before anything is installed: the release
# manifest (zelt-update.json) must carry a valid Ed25519 signature from the
# zelt update key pinned below (the same key the app checks), and the tarball
# must match the size and SHA-256 listed in it. The app is installed into a
# directory you own (~/.local/share/zelt-app), which is what lets it replace
# itself when a new signed release comes out. No root needed, none used.
#
# Environment: ZELT_VERSION=1.2.3 installs that release instead of the newest;
# ZELT_FORCE=1 allows installing an older version than the one installed.

set -eu

REPO_URL="https://github.com/gut-engel/zelt"
# Public half of the zelt update signing key (base64url, Ed25519). Pinned
# here, not downloaded, so a compromised download cannot change it.
UPDATE_PUBKEY="${ZELT_UPDATE_PUBKEY:-D1f8dCLPeqK-grDtQfrcqgzroywvGFTB73NDjUzvqhY}"
APP_ID="dev.zelt.zelt"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
APP_DIR="$DATA/zelt-app"
BIN_DIR="$HOME/.local/bin"
DESKTOP="$DATA/applications/$APP_ID.desktop"
ICON="$DATA/icons/hicolor/scalable/apps/$APP_ID.svg"
USER_DATA="$DATA/$APP_ID"

# Same icon as data/zelt.svg in the bundle (older bundles lack it).
ICON_SVG='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256"><rect width="256" height="256" rx="60" fill="#1e5b4f"/><path d="M128 72 L188 172 L68 172 Z" fill="none" stroke="#fff" stroke-width="22" stroke-linejoin="round"/></svg>'

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

base_url() {
  if [ -n "${ZELT_BASE_URL:-}" ]; then
    printf '%s\n' "$ZELT_BASE_URL"
  elif [ -n "${ZELT_VERSION:-}" ]; then
    printf '%s\n' "$ZELT_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "ZELT_VERSION must look like 1.2.3"
    printf '%s/releases/download/v%s\n' "$REPO_URL" "$ZELT_VERSION"
  else
    printf '%s/releases/latest/download\n' "$REPO_URL"
  fi
}

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required${2:+ ($2)}"; }

# base64url (unpadded) -> bytes on stdout.
b64u_decode() {
  s=$(printf '%s' "$1" | tr -d ' \n\r' | tr '_-' '/+')
  while [ $(( ${#s} % 4 )) -ne 0 ]; do s="$s="; done
  printf '%s' "$s" | base64 -d
}

# Verifies $1 (manifest) against $2 (its .sig) with the pinned key.
verify_manifest() {
  # Ed25519 SubjectPublicKeyInfo prefix + the raw 32-byte key.
  { printf '\060\052\060\005\006\003\053\145\160\003\041\000'; b64u_decode "$UPDATE_PUBKEY"; } > "$T/pub.der"
  [ "$(wc -c < "$T/pub.der")" -eq 44 ] || die "bad pinned key"
  openssl pkey -pubin -inform DER -in "$T/pub.der" -out "$T/pub.pem" 2>/dev/null || die "OpenSSL cannot read Ed25519 keys (OpenSSL 3 needed)"
  b64u_decode "$(cat "$2")" > "$T/sig.bin" 2>/dev/null || return 1
  [ "$(wc -c < "$T/sig.bin")" -eq 64 ] || return 1
  openssl pkeyutl -verify -pubin -inkey "$T/pub.pem" -rawin -in "$1" -sigfile "$T/sig.bin" >/dev/null 2>&1
}

# Field of the linux-x64 asset in the (already verified) manifest.
asset_field() {
  awk -v f="\"$1\"" '
    /"linux-x64"[[:space:]]*:/ { inside = 1; next }
    inside && /}/ { exit }
    inside && index($0, f) { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/[",[:space:]]/, ""); print; exit }
  ' "$T/zelt-update.json"
}

manifest_field() {
  sed -n "s/^  \"$1\": *\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}\$/\1/p" "$T/zelt-update.json" | head -n1
}

installed_build() {
  sed -n 's/.*"build_number":"\([0-9]*\)".*/\1/p' "$APP_DIR/data/flutter_assets/version.json" 2>/dev/null || true
}

check_libs() {
  missing=$(ldd "$APP_DIR/zelt" 2>/dev/null | awk '/not found/ {print $1}' | tr '\n' ' ')
  [ -z "$missing" ] && return
  say ""
  say "WARNING: missing system libraries: $missing"
  say "  Debian/Ubuntu: sudo apt install libgtk-3-0"
  say "  Fedora:        sudo dnf install gtk3"
  say "  Arch:          sudo pacman -S gtk3"
}

desktop_quote() {
  # Desktop Entry Exec quoting: wrap in quotes, escape \ " ` $.
  printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"`$]/\\&/g')"
}

cmd_install() {
  [ "$(id -u)" -ne 0 ] || die "run this as your normal user, not root (zelt installs per user so it can update itself)"
  [ "$(uname -s)" = Linux ] || die "this installer is for Linux"
  [ "$(uname -m)" = x86_64 ] || die "zelt releases are built for x86_64; $(uname -m) is not supported yet"
  need curl; need tar; need sha256sum; need openssl "OpenSSL 3"; need base64; need awk

  T=$(mktemp -d)
  trap 'rm -rf "$T"' EXIT INT TERM
  url=$(base_url)
  say "fetching the release manifest from $url"
  # Authenticity comes from the signature check below, not from the transport.
  curl -fsSL -o "$T/zelt-update.json" "$url/zelt-update.json" || die "could not download the manifest"
  curl -fsSL -o "$T/zelt-update.json.sig" "$url/zelt-update.json.sig" || die "could not download the signature"
  verify_manifest "$T/zelt-update.json" "$T/zelt-update.json.sig" ||
    die "the release manifest is NOT signed by the zelt update key; refusing to install"

  version=$(manifest_field version)
  build=$(manifest_field build)
  file=$(asset_field file)
  sha=$(asset_field sha256)
  size=$(asset_field size)
  printf '%s\n' "$file" | grep -Eq '^zelt-[0-9]+\.[0-9]+\.[0-9]+-linux-x64\.tar\.gz$' || die "manifest has no valid Linux file"
  printf '%s\n' "$sha" | grep -Eq '^[0-9a-f]{64}$' || die "manifest has no valid checksum"
  printf '%s\n' "$size$build" | grep -Eq '^[0-9]+$' || die "manifest has no valid size or build"
  say "verified signed release $version (build $build)"

  cur=$(installed_build)
  if [ -n "$cur" ] && [ "$build" -lt "$cur" ] && [ "${ZELT_FORCE:-0}" != 1 ]; then
    die "build $build is older than the installed build $cur (set ZELT_FORCE=1 to downgrade on purpose)"
  fi

  say "downloading $file"
  curl -fSL --progress-bar -o "$T/$file" "$url/$file" || die "download failed"
  [ "$(wc -c < "$T/$file")" -eq "$size" ] || die "size mismatch; refusing to install"
  [ "$(sha256sum "$T/$file" | cut -d' ' -f1)" = "$sha" ] || die "checksum mismatch; refusing to install"

  mkdir -p "$T/stage"
  tar -xzf "$T/$file" -C "$T/stage" --no-same-owner
  [ -x "$T/stage/zelt" ] || die "the archive has no zelt binary"

  if pgrep -u "$(id -u)" -x zelt >/dev/null 2>&1; then
    say "note: zelt is running; restart it to use the new version"
  fi
  mkdir -p "$DATA"
  rm -rf "$APP_DIR.new" "$APP_DIR.old"
  mv "$T/stage" "$APP_DIR.new"
  [ -d "$APP_DIR" ] && mv "$APP_DIR" "$APP_DIR.old"
  mv "$APP_DIR.new" "$APP_DIR"
  rm -rf "$APP_DIR.old"

  mkdir -p "$BIN_DIR" "$(dirname "$DESKTOP")" "$(dirname "$ICON")"
  ln -sfn "$APP_DIR/zelt" "$BIN_DIR/zelt"
  if [ -f "$APP_DIR/data/zelt.svg" ]; then
    cp "$APP_DIR/data/zelt.svg" "$ICON"
  else
    printf '%s\n' "$ICON_SVG" > "$ICON"
  fi
  cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=zelt
GenericName=Messenger
Comment=Serverless, accountless friend-relay messenger
Exec=$(desktop_quote "$APP_DIR/zelt")
TryExec=$APP_DIR/zelt
Icon=$APP_ID
Terminal=false
Categories=Network;InstantMessaging;Chat;
Keywords=messenger;chat;encrypted;
StartupNotify=true
StartupWMClass=$APP_ID
EOF
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$(dirname "$DESKTOP")" 2>/dev/null || true
  command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "$DATA/icons/hicolor" 2>/dev/null || true

  check_libs
  say ""
  say "zelt $version installed:"
  say "  app:      $APP_DIR (updates itself from signed releases)"
  say "  launcher: your app menu (zelt), or run: zelt"
  case ":$PATH:" in *":$BIN_DIR:"*) ;; *) say "  note: $BIN_DIR is not in your PATH; start it from the app menu or $APP_DIR/zelt" ;; esac
}

cmd_uninstall() {
  rm -rf "$APP_DIR" "$APP_DIR.new" "$APP_DIR.old"
  [ -L "$BIN_DIR/zelt" ] && rm -f "$BIN_DIR/zelt"
  rm -f "$DESKTOP" "$ICON"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$(dirname "$DESKTOP")" 2>/dev/null || true
  say "zelt removed (app, launcher, icon)"
  if [ "${1:-}" = --purge ]; then
    answer="${ZELT_PURGE_CONFIRM:-}"
    if [ -z "$answer" ] && { : < /dev/tty; } 2>/dev/null; then
      printf 'Delete your zelt identity, friends and messages in %s for good? Type "delete": ' "$USER_DATA" > /dev/tty
      read -r answer < /dev/tty || answer=""
    fi
    if [ "$answer" = delete ]; then
      case "$USER_DATA" in */"$APP_ID") rm -rf -- "$USER_DATA" && say "your zelt data was deleted" ;; esac
    else
      say "kept your data in $USER_DATA"
    fi
  else
    say "your identity, friends and messages are kept in $USER_DATA (uninstall --purge deletes them)"
  fi
}

main() {
  case "${1:-install}" in
    install | update) cmd_install ;;
    uninstall) shift; cmd_uninstall "$@" ;;
    *) die "unknown command '$1' (install, uninstall [--purge])" ;;
  esac
}

# Everything above only defines functions, so a partially downloaded script
# does nothing.
main "$@"
