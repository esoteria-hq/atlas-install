#!/usr/bin/env bash
#
# Atlas THIN-CLIENT one-line installer (macOS) — server mode, ADR-097.
#
#   ATLAS_SERVER_URL='http://<server>:8443' ATLAS_CLIENT_TOKEN='<token>' \
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/esoteria-hq/atlas-install/main/client-install.sh)"
#
# This REPLACES the fat install for server-mode clients. What lands on the Mac
# is the Electron UI only (atlas-client.tar.gz, built by scripts/
# package-client.sh) plus ~/.atlas/client.json pointing at YOUR Atlas server.
# No harness code, no agent prompts, no skills, no API keys, no Python, no
# ffmpeg, no 16 GB requirement — the agent runs on esoteria's server, in your
# own isolated profile, and your Mac is the microphone + screen for it.
#
# Environment:
#   ATLAS_SERVER_URL        required — your Atlas server (from esoteria)
#   ATLAS_CLIENT_TOKEN      required — your personal bearer token (shown once)
#   ATLAS_CLIENT_DIR        install dir (default: $HOME/atlas-client)
#   ATLAS_INSTALL_REPO      public installer repo (default: esoteria-hq/atlas-install)
#   ATLAS_INSTALL_BASE_URL  asset-host override (TESTING — flat http server)
#   ATLAS_CLIENT_NO_LAUNCH=1  install but don't open / autostart (TESTING)

set -euo pipefail

bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
ok()    { printf "\033[32m✓\033[0m %s\n" "$*"; }
warn()  { printf "\033[33m⚠\033[0m %s\n" "$*"; }
fail()  { printf "\033[31m✗\033[0m %s\n" "$*"; exit 1; }
step()  { printf "\n\033[1;34m›\033[0m \033[1m%s\033[0m\n" "$*"; }

REPO="${ATLAS_INSTALL_REPO:-esoteria-hq/atlas-install}"
CLIENT_DIR="${ATLAS_CLIENT_DIR:-$HOME/atlas-client}"
TARBALL_ASSET="atlas-client.tar.gz"
SHA_ASSET="atlas-client.tar.gz.sha256"
PLIST_LABEL="com.esoteria.atlas.client"

if [[ -n "${ATLAS_INSTALL_BASE_URL:-}" ]]; then
  TARBALL_URL="$ATLAS_INSTALL_BASE_URL/$TARBALL_ASSET"
  SHA_URL="$ATLAS_INSTALL_BASE_URL/$SHA_ASSET"
else
  TARBALL_URL="https://github.com/$REPO/releases/latest/download/$TARBALL_ASSET"
  SHA_URL="https://github.com/$REPO/releases/latest/download/$SHA_ASSET"
fi

bold "═══════════════════════════════════════════════════════════════"
bold "  Atlas — thin client installer (server mode)"
bold "═══════════════════════════════════════════════════════════════"

# ── [1/5] Sanity ────────────────────────────────────────────────────────────
step "[1/5] Sanity"
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

# ── [2/5] Node (the only toolchain piece the client needs) ─────────────────
step "[2/5] Node.js"
if ! command -v npm >/dev/null; then
  if command -v brew >/dev/null; then
    brew install node
  else
    fail "Node.js is required (it runs the app shell). Install from https://nodejs.org and re-run."
  fi
fi
ok "node $(node --version)"

# ── [3/5] Download + verify the UI bundle ───────────────────────────────────
step "[3/5] Download Atlas client"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/$TARBALL_ASSET" "$TARBALL_URL" || fail "download failed: $TARBALL_URL"
curl -fsSL -o "$TMP/$SHA_ASSET" "$SHA_URL" || fail "checksum download failed: $SHA_URL"
(cd "$TMP" && shasum -a 256 -c "$SHA_ASSET" >/dev/null) || fail "checksum mismatch — refusing to install"
ok "downloaded + SHA-256 verified"

if [[ -d "$CLIENT_DIR" ]]; then
  mv "$CLIENT_DIR" "$CLIENT_DIR.prev.$(date +%Y%m%d%H%M%S)"
  warn "existing install moved aside (never deleted)"
fi
mkdir -p "$(dirname "$CLIENT_DIR")"
tar -xzf "$TMP/$TARBALL_ASSET" -C "$TMP"
mv "$TMP/atlas-client" "$CLIENT_DIR"
(cd "$CLIENT_DIR" && npm install --no-audit --no-fund >/dev/null)
ok "installed to $CLIENT_DIR"

# ── [4/5] Connection config ─────────────────────────────────────────────────
step "[4/5] Connect to your Atlas"
mkdir -p "$HOME/.atlas"
CONFIG="$HOME/.atlas/client.json"
umask 077
printf '{\n  "server_url": "%s",\n  "token": "%s"\n}\n' "$SERVER_URL" "$TOKEN" > "$CONFIG"
chmod 600 "$CONFIG"
ok "wrote $CONFIG (0600)"

# ── [5/5] Autostart + launch ────────────────────────────────────────────────
step "[5/5] Launch"
if [[ "${ATLAS_CLIENT_NO_LAUNCH:-}" == "1" ]]; then
  ok "skipping launch (ATLAS_CLIENT_NO_LAUNCH=1)"
  echo "start manually with: cd $CLIENT_DIR && npm start"
  exit 0
fi

PLIST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
mkdir -p "$HOME/Library/LaunchAgents"
# launchd runs with a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin); the electron
# shim's `#!/usr/bin/env node` needs node ON that PATH, but node from nodejs.org
# (/usr/local/bin), Homebrew (/opt/homebrew/bin), or nvm is NOT there — so the
# app silently fails to autostart with "env: node: No such file or directory".
# Pin the detected node dir into the agent's PATH so autostart finds it.
NODE_BIN_DIR="$(cd "$(dirname "$(command -v node)")" 2>/dev/null && pwd || echo /usr/local/bin)"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$PLIST_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$CLIENT_DIR/node_modules/.bin/electron</string>
    <string>$CLIENT_DIR</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$NODE_BIN_DIR:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/.atlas/logs/client.log</string>
  <key>StandardErrorPath</key><string>$HOME/.atlas/logs/client.err</string>
</dict>
</plist>
EOF
mkdir -p "$HOME/.atlas/logs"
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || warn "launchctl bootstrap failed — start manually: cd $CLIENT_DIR && npm start"
ok "Atlas starts at login"

echo ""
bold "Done. Atlas is opening — look for the orb in your menu bar."
echo "Your assistant runs on esoteria's server in your own private profile;"
echo "this Mac holds only the app and your connection file (~/.atlas/client.json)."
