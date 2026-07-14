#!/usr/bin/env bash
#
# Atlas THIN-CLIENT one-line installer (macOS) — server mode, ADR-097.
#
#   ATLAS_SERVER_URL='http://<server>:8443' ATLAS_CLIENT_TOKEN='<token>' \
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/esoteria-hq/atlas-install/main/client-install.sh)"
#
# What lands on the Mac is a real app: Atlas.app (packaged by scripts/
# package-client.sh — a signed-identity Electron bundle with its own Dock
# icon) plus ~/.atlas/client.json pointing at YOUR Atlas server. No harness
# code, no agent prompts, no skills, no API keys, no Node, no npm, no
# 16 GB requirement — the agent runs on esoteria's server, in your own
# isolated profile, and your Mac is the microphone + screen for it.
#
# Environment:
#   ATLAS_SERVER_URL        required — your Atlas server (from esoteria)
#   ATLAS_CLIENT_TOKEN      required — your personal bearer token (shown once)
#   ATLAS_APP_DIR           where Atlas.app goes (default: /Applications when
#                           writable, else ~/Applications)
#   ATLAS_INSTALL_REPO      public installer repo (default: esoteria-hq/atlas-install)
#   ATLAS_INSTALL_BASE_URL  asset-host override (TESTING — flat http server)
#   ATLAS_CLIENT_NO_LAUNCH=1  install but don't open / autostart (TESTING)

set -euo pipefail

# ASCII-only status glyphs: multi-byte unicode (✓ ⚠ › ═) mojibakes in
# non-UTF-8 terminals and made a working install read as garbled/failed.
bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
ok()    { printf "\033[32m[ok]\033[0m %s\n" "$*"; }
warn()  { printf "\033[33m[!]\033[0m %s\n" "$*"; }
fail()  { printf "\033[31m[x]\033[0m %s\n" "$*"; exit 1; }
step()  { printf "\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n" "$*"; }

REPO="${ATLAS_INSTALL_REPO:-esoteria-hq/atlas-install}"
TARBALL_ASSET="atlas-client.tar.gz"
SHA_ASSET="atlas-client.tar.gz.sha256"
PLIST_LABEL="com.esoteria.atlas.client"

# Atlas.app's home: /Applications when this user can write it, else the
# per-user ~/Applications (always writable, no sudo either way).
if [[ -n "${ATLAS_APP_DIR:-}" ]]; then
  APP_DIR="$ATLAS_APP_DIR"
elif [[ -w /Applications ]]; then
  APP_DIR="/Applications"
else
  APP_DIR="$HOME/Applications"
fi
APP_PATH="$APP_DIR/Atlas.app"

if [[ -n "${ATLAS_INSTALL_BASE_URL:-}" ]]; then
  TARBALL_URL="$ATLAS_INSTALL_BASE_URL/$TARBALL_ASSET"
  SHA_URL="$ATLAS_INSTALL_BASE_URL/$SHA_ASSET"
else
  TARBALL_URL="https://github.com/$REPO/releases/latest/download/$TARBALL_ASSET"
  SHA_URL="https://github.com/$REPO/releases/latest/download/$SHA_ASSET"
fi

bold "==============================================================="
bold "  Atlas - thin client installer (server mode)"
bold "==============================================================="

# ── [1/4] Sanity ────────────────────────────────────────────────────────────
step "[1/4] Sanity"
[[ "$(uname -s)" == "Darwin" ]] || fail "the Atlas client installs only on macOS (got $(uname -s))"
ok "macOS"
command -v curl >/dev/null || fail "curl is required"
ok "curl"

SERVER_URL="${ATLAS_SERVER_URL:-}"
TOKEN="${ATLAS_CLIENT_TOKEN:-}"
if [[ -z "$SERVER_URL" && -r /dev/tty ]]; then
  printf "Atlas server URL (from esoteria, e.g. http://atlas-hq:8443): "
  read -r SERVER_URL < /dev/tty
fi
if [[ -z "$TOKEN" && -r /dev/tty ]]; then
  printf "Your access token (never echoed): "
  read -rs TOKEN < /dev/tty
  echo ""
fi
[[ "$SERVER_URL" =~ ^https?:// ]] || fail "ATLAS_SERVER_URL must start with http:// or https://"
[[ -n "$TOKEN" ]] || fail "ATLAS_CLIENT_TOKEN is required (esoteria gives you this once)"

# The desktop UI's Content-Security-Policy (connect-src) allows only *.ts.net
# names (+ loopback) — a RAW tailnet IP produces an install that looks healthy
# (curl/health returns 200, background pollers connect) but whose UI can never
# reach the server and shows "You're offline". Resolve the known server IP to
# its MagicDNS name; reject any other raw IP rather than ship a broken install.
SERVER_HOST="${SERVER_URL#*://}"; SERVER_HOST="${SERVER_HOST%%[:/]*}"
if [[ "$SERVER_HOST" == "100.111.77.47" ]]; then
  SERVER_URL="${SERVER_URL/100.111.77.47/atlas-server-1.tailc0f037.ts.net}"
  warn "using the server's MagicDNS name instead of its raw IP (the app only allows *.ts.net): $SERVER_URL"
elif [[ "$SERVER_HOST" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  fail "ATLAS_SERVER_URL points at a raw IP ($SERVER_HOST). Atlas needs the server's MagicDNS name (e.g. http://atlas-server-1.tailc0f037.ts.net:8443) — the app blocks raw IPs, so an IP install can't connect from the UI even though the server is up. Ask esoteria for the .ts.net address."
fi
ok "server + token provided"

# Tailscale is the usual path to the server (the URL is a tailnet name).
if [[ "$SERVER_URL" == *"ts.net"* || "$SERVER_URL" == *"://100."* ]]; then
  if ! command -v tailscale >/dev/null && [ ! -d "/Applications/Tailscale.app" ]; then
    warn "your server address looks like Tailscale, but Tailscale isn't installed."
    warn "install it from https://tailscale.com/download (or the Mac App Store),"
    warn "sign in with the invite esoteria sent you, then relaunch Atlas."
  else
    ok "tailscale present"
  fi
fi

# ── [2/4] Download + verify the app ─────────────────────────────────────────
step "[2/4] Download Atlas"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/$TARBALL_ASSET" "$TARBALL_URL" || fail "download failed: $TARBALL_URL"
curl -fsSL -o "$TMP/$SHA_ASSET" "$SHA_URL" || fail "checksum download failed: $SHA_URL"
(cd "$TMP" && shasum -a 256 -c "$SHA_ASSET" >/dev/null) || fail "checksum mismatch — refusing to install"
ok "downloaded + SHA-256 verified"

tar -xzf "$TMP/$TARBALL_ASSET" -C "$TMP"
[[ -d "$TMP/atlas-client/Atlas.app" ]] || fail "the bundle is missing Atlas.app (stale release? try again shortly)"

mkdir -p "$APP_DIR"
if [[ -d "$APP_PATH" ]]; then
  # Quit a running Atlas so the moved-aside bundle isn't the live one.
  osascript -e 'tell application "Atlas" to quit' >/dev/null 2>&1 || true
  sleep 1
  # Park OUT of /Applications: a parked bundle there haunts Spotlight and
  # Launchpad as a ghost "Atlas" (blank-icon helper apps included — field
  # find 2026-07-12). ~/.atlas/previous.noindex is invisible to Spotlight
  # (.noindex) and still never deleted.
  PARK="$HOME/.atlas/previous.noindex"
  mkdir -p "$PARK"
  mv "$APP_PATH" "$PARK/Atlas.app.prev.$(date +%Y%m%d%H%M%S)"
  warn "existing Atlas.app parked in $PARK (never deleted)"
fi
# ditto preserves the bundle's code signature (cp -R can break it on the
# framework symlinks), and the tarball extracts onto tmpfs, so copy properly.
ditto "$TMP/atlas-client/Atlas.app" "$APP_PATH"
ok "installed $APP_PATH"

# The previous layout (~/atlas-client, raw electron via npm) is superseded —
# move it aside so nothing points at it. Never deleted.
if [[ -d "$HOME/atlas-client" ]]; then
  PARK="$HOME/.atlas/previous.noindex"
  mkdir -p "$PARK"
  mv "$HOME/atlas-client" "$PARK/atlas-client.prev.$(date +%Y%m%d%H%M%S)"
  warn "old-style install ~/atlas-client parked in $PARK (superseded by Atlas.app)"
fi

# ── [3/4] Connection config ─────────────────────────────────────────────────
step "[3/4] Connect to your Atlas"
mkdir -p "$HOME/.atlas"
CONFIG="$HOME/.atlas/client.json"
umask 077
printf '{\n  "server_url": "%s",\n  "token": "%s"\n}\n' "$SERVER_URL" "$TOKEN" > "$CONFIG"
chmod 600 "$CONFIG"
ok "wrote $CONFIG (0600)"

# ── [4/4] Autostart + launch ────────────────────────────────────────────────
step "[4/4] Launch"
if [[ "${ATLAS_CLIENT_NO_LAUNCH:-}" == "1" ]]; then
  ok "skipping launch (ATLAS_CLIENT_NO_LAUNCH=1)"
  echo "start manually with: open \"$APP_PATH\""
  exit 0
fi

PLIST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
mkdir -p "$HOME/Library/LaunchAgents"
# A real .app binary — no node, no PATH gymnastics (the old layout's
# "env: node: No such file or directory" autostart failure went with them).
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$PLIST_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_PATH/Contents/MacOS/Atlas</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/.atlas/logs/client.log</string>
  <key>StandardErrorPath</key><string>$HOME/.atlas/logs/client.err</string>
</dict>
</plist>
EOF
mkdir -p "$HOME/.atlas/logs"
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || warn "launchctl bootstrap failed — start manually: open \"$APP_PATH\""
ok "Atlas starts at login"

echo ""
bold "Done. Atlas is opening — the orb is in your menu bar, and Atlas is in your Dock."
echo "Your assistant runs on esoteria's server in your own private profile;"
echo "this Mac holds only the app and your connection file (~/.atlas/client.json)."
