#!/usr/bin/env bash
#
# Atlas THIN-CLIENT one-line installer (macOS) — server mode, ADR-097.
#
#   ATLAS_SERVER_URL='http://<server>:8443' ATLAS_CLIENT_TOKEN='<token>' \
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/esoteria-hq/atlas-install/main/client-install.sh)"
#
# What lands on the Mac is a real app: Atlas.app (packaged by scripts/
# package-client.sh — a signed-identity Electron bundle with its own Dock
# icon), the small native helper it spawns for the globe-key dictation door
# and meeting capture (~/.atlas/bin/atlas-capture-helper), plus
# ~/.atlas/client.json pointing at YOUR Atlas server. No harness
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
HELPER_NAME="atlas-capture-helper"
# WHERE THE DESKTOP LOOKS, and nowhere else: apps/desktop/src/main/index.ts
# builds NATIVE_HELPER_PATH from homedir() directly and is the only process that
# ever spawns this binary. Same literal as scripts/build-native-helper.sh.
HELPER_DIR="$HOME/.atlas/bin"
HELPER_DEST="$HELPER_DIR/$HELPER_NAME"

# ── Quitting Atlas, for real ────────────────────────────────────────────────
# This is the load-bearing half of a REINSTALL, and the line it replaces was not.
# The old code was `osascript -e '…quit' >/dev/null 2>&1 || true; sleep 1`: when
# the quit failed — no Apple-events permission, the app still launching, a hung
# window — the failure was swallowed, the still-live process kept executing from
# the bundle this script then `mv`s into ~/.atlas/previous.noindex/, and the
# install ran to the end printing [ok] on every line while the OLD build was the
# one actually running. Confirmed on a Mac 2026-08-05:
#   lsof -p "$(pgrep -x Atlas)" | grep MacOS/Atlas
# still resolved into previous.noindex/ after a "successful" install. A reinstall
# that silently keeps the old build is worse than one that fails outright,
# because it looks like it worked — hence the verify at the end of [5/5].

# `-x Atlas` matches the MAIN process only. The Electron children are named
# "Atlas Helper", "Atlas Helper (Renderer)" and friends; they exit with their
# parent and are never ours to signal directly.
atlas_pids() { pgrep -x Atlas 2>/dev/null || true; }

# Poll (never a blind sleep) until no Atlas is left. $1 = tries, 0.2s apart.
atlas_gone() {
  local tries="$1"
  while [ "$tries" -gt 0 ]; do
    if [ -z "$(atlas_pids)" ]; then return 0; fi
    sleep 0.2
    tries=$((tries - 1))
  done
  [ -z "$(atlas_pids)" ]
}

# Ask nicely, then insist, then compel — and only report success once the
# process is actually gone. Returns non-zero if something survived all three.
quit_atlas() {
  if [ -z "$(atlas_pids)" ]; then return 0; fi
  osascript -e 'tell application "Atlas" to quit' >/dev/null 2>&1 || true
  if atlas_gone 25; then return 0; fi   # ~5s for a graceful Electron shutdown
  pkill -x Atlas 2>/dev/null || true    # SIGTERM
  if atlas_gone 15; then return 0; fi   # ~3s
  pkill -9 -x Atlas 2>/dev/null || true
  atlas_gone 10                         # ~2s
}

# Full paths of every running Atlas, one per line. macOS `ps -o comm=` prints the
# executable's ABSOLUTE path, which is exactly the question "which build is live".
# `-ww` because plain `ps` truncates to the window width for its default format;
# measured 2026-08-06 that a single `-o comm=` field with an explicit -p is NOT
# truncated even at 177 characters, but the flag is free and the alternative is
# re-deriving that. A truncated path would fail the exact match below and cry
# wolf on every install with a long home directory.
atlas_running_paths() {
  local pid path
  for pid in $(atlas_pids); do
    path="$(ps -ww -o comm= -p "$pid" 2>/dev/null || true)"
    if [ -n "$path" ]; then printf '%s\n' "$path"; fi
  done
  return 0
}

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

# ── [2/5] Download + verify the app ─────────────────────────────────────────
step "[2/5] Download Atlas"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/$TARBALL_ASSET" "$TARBALL_URL" || fail "download failed: $TARBALL_URL"
curl -fsSL -o "$TMP/$SHA_ASSET" "$SHA_URL" || fail "checksum download failed: $SHA_URL"
(cd "$TMP" && shasum -a 256 -c "$SHA_ASSET" >/dev/null) || fail "checksum mismatch — refusing to install"
ok "downloaded + SHA-256 verified"

tar -xzf "$TMP/$TARBALL_ASSET" -C "$TMP"
[[ -d "$TMP/atlas-client/Atlas.app" ]] || fail "the bundle is missing Atlas.app (stale release? try again shortly)"

mkdir -p "$APP_DIR"
# Quit a running Atlas BEFORE anything moves, whatever directory it was launched
# from — a live process holding an inode we are about to park is the whole of
# defect 1. Unconditional (not gated on `-d $APP_PATH`) because the running build
# may live somewhere else entirely, e.g. an older ~/Applications install.
if [ -n "$(atlas_pids)" ]; then
  if quit_atlas; then
    ok "quit the running Atlas"
  else
    warn "an Atlas process would not exit even after SIGKILL (pids: $(atlas_pids | tr '\n' ' '))."
    warn "the new build will be installed, but quit Atlas by hand and re-run this installer"
    warn "if the check at the end says the wrong build is live."
  fi
fi
if [[ -d "$APP_PATH" ]]; then
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

# ── [3/5] The native helper ─────────────────────────────────────────────────
# WHY THIS STEP EXISTS (defect 2, found on a fresh Mac 2026-08-05). Atlas spawns
# a small Swift binary from ~/.atlas/bin/atlas-capture-helper and nothing else
# ever put one there, so every tester install logged `Fn door could not arm
# (helper_missing)` and `meeting detector: capture helper not installed`. Three
# features were dead on arrival and only one of them said so out loud:
#   • the 🌐 / globe key — the DEFAULT dictation key (ADR-354) — silently fell
#     back to Option-Shift-Space, so the documented key just did nothing;
#   • meeting recording (the Record button);
#   • unscheduled-meeting detection.
# We ship the binary PREBUILT inside atlas-client.tar.gz rather than building it
# here: the thin tarball carries no Swift sources, and asking a tester to install
# Command Line Tools (multi-GB, its own consent dialog) to get their dictation
# key working is not an install. The helper does NOT need to share Atlas.app's
# signing identity — macOS keys the Accessibility grant to the app that SPAWNS
# it, and an ad-hoc helper under the ai.esoteria.atlas app is the combination
# that has been verified working.
step "[3/5] Dictation + meeting helper"
HELPER_SRC="$TMP/atlas-client/$HELPER_NAME"
if [[ -f "$HELPER_SRC" ]]; then
  mkdir -p "$HELPER_DIR"
  # Stage under a temp name and PROVE it runs before it becomes the live path:
  # `cp` over a running helper fails with ETXTBSY, `mv` is atomic, and a bad new
  # binary must never clobber a working old one.
  cp "$HELPER_SRC" "$HELPER_DEST.new"
  chmod +x "$HELPER_DEST.new"
  xattr -d com.apple.quarantine "$HELPER_DEST.new" 2>/dev/null || true
  # `exclude-screen-capture` is the helper's documented no-op subcommand: exit 0,
  # no output, no TCC grant needed. So it tests exactly what can still be wrong
  # at this point — CPU architecture, a signature the kernel rejects, quarantine
  # — and nothing that depends on permissions the user hasn't granted yet.
  if "$HELPER_DEST.new" exclude-screen-capture >/dev/null 2>&1; then
    mv -f "$HELPER_DEST.new" "$HELPER_DEST"
    ok "installed $HELPER_DEST (globe-key dictation + meeting capture)"
    HELPER_OK=1
  else
    rm -f "$HELPER_DEST.new"
    warn "the helper shipped in this build will not run on this Mac (wrong CPU architecture,"
    warn "or a signature macOS rejects) — left the previous one alone rather than break it."
    warn "Tell esoteria: this is a packaging problem on our side, not a fault on your Mac."
    HELPER_OK=0
  fi
else
  warn "this Atlas build shipped without the native helper (older release)."
  warn "consequence: the 🌐 globe key won't start dictation (it falls back to"
  warn "Option-Shift-Space), and meeting recording + meeting detection stay off."
  warn "Ask esoteria for a build published after 2026-08-06, then re-run this installer."
  HELPER_OK=0
fi

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
SERVICE_TARGET="gui/$(id -u)/$PLIST_LABEL"
# Bootout by SERVICE TARGET, not by plist path: a label loaded from an older
# install path is only reachable this way, and a stale label left loaded is
# exactly what made the next `bootstrap` do nothing.
launchctl bootout "$SERVICE_TARGET" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
# `kickstart -k` is the line that actually starts the NEW binary. `bootstrap`
# alone is a silent no-op when the label is already loaded — so on every
# reinstall it loaded nothing, started nothing, and still fell through to the
# "[ok] Atlas starts at login" below. -k kills whatever the label is running and
# restarts it from the plist we just wrote.
ok "registered to start at login ($PLIST_LABEL)"
# Deliberately NOT an [ok] "Atlas started" here: whether Atlas started, and
# whether the thing that started is the build we just installed, is not known
# until the verify below. Claiming it here is the shape of the bug.
if ! launchctl kickstart -k "$SERVICE_TARGET" >/dev/null 2>&1; then
  warn "launchctl could not start Atlas — opening it directly instead"
  open "$APP_PATH" || warn "could not open $APP_PATH — start Atlas from $APP_DIR"
fi

# VERIFY, don't assume — the check whose absence let defect 1 ship. Everything
# above can print [ok] while the process actually serving the user is the build
# we just parked in ~/.atlas/previous.noindex/.
EXPECTED_BIN="$APP_PATH/Contents/MacOS/Atlas"
RUNNING=""
for _ in $(seq 1 40); do          # up to ~10s for Electron to be up
  RUNNING="$(atlas_running_paths)"
  if printf '%s\n' "$RUNNING" | grep -Fxq "$EXPECTED_BIN"; then break; fi
  sleep 0.25
done
# grep -Fx (exact whole line), never a substring test: "$HOME/Applications/
# Atlas.app/…" CONTAINS "/Applications/Atlas.app/…", so a substring match would
# call the wrong build a pass.
LAUNCH_VERIFIED=0
if printf '%s\n' "$RUNNING" | grep -Fxq "$EXPECTED_BIN"; then
  LAUNCH_VERIFIED=1
  ok "verified: the running Atlas is $EXPECTED_BIN"
  STRAYS="$(printf '%s\n' "$RUNNING" | grep -Fxv "$EXPECTED_BIN" | grep -v '^$' || true)"
  if [ -n "$STRAYS" ]; then
    warn "another Atlas is ALSO running, from: $(printf '%s' "$STRAYS" | tr '\n' ' ')"
    warn "quit it (menu bar orb -> Quit) so only the new build is live."
  fi
elif [ -z "$(printf '%s' "$RUNNING" | tr -d '[:space:]')" ]; then
  warn "Atlas did not start within 10s."
else
  warn "THE RUNNING ATLAS IS NOT THE ONE JUST INSTALLED."
  warn "  running:   $(printf '%s' "$RUNNING" | tr '\n' ' ')"
  warn "  installed: $EXPECTED_BIN"
fi

echo ""
# The closing has to tell the truth about the state we actually verified. The
# old script always printed the cheerful banner; printing it under a failed
# verify would just be the same lie one paragraph later. Exit stays 0 either
# way — every file IS installed, and the remedy is a restart, not a reinstall.
if [ "$LAUNCH_VERIFIED" = "1" ]; then
  bold "Done. Atlas is opening — the orb is in your menu bar, and Atlas is in your Dock."
  echo "Your assistant runs on esoteria's server in your own private profile;"
  echo "this Mac holds only the app and your connection file (~/.atlas/client.json)."
else
  bold "Installed, but Atlas is NOT running the new build yet."
  echo "Everything is on disk — this is the last step, and it takes 20 seconds:"
  echo "  1. Quit every Atlas: click the menu bar orb > Quit  (or run: pkill -x Atlas)"
  echo "  2. Open Atlas from $APP_DIR"
  echo "If it still won't start, send esoteria the last lines of ~/.atlas/logs/client.err"
fi

# ── One thing macOS will not do for you ─────────────────────────────────────
# The helper being installed is only half of the globe key. The CGEventTap it
# opens needs the Accessibility grant, and macOS attaches that grant to the app
# that SPAWNS the helper — Atlas — not to the helper itself. Nothing in this
# script can grant it; only the user can, in System Settings. Until 2026-08-06
# the installer said nothing at all about this, so the honest end state of a
# successful install was still a dictation key that did nothing.
if [ "${HELPER_OK:-0}" = "1" ]; then
  echo ""
  bold "One last thing — turn the globe key on (30 seconds, only you can do it):"
  echo "  1. System Settings > Privacy & Security > Accessibility > turn ON \"Atlas\""
  echo "     (this is what lets Atlas see the 🌐 globe key. Without it, dictation"
  echo "     falls back to Option-Shift-Space and the globe key does nothing.)"
  echo "  2. System Settings > Keyboard > \"Press 🌐 key to\" > Do Nothing"
  echo "     (otherwise macOS also pops its own panel every time you talk to Atlas.)"
  echo "  3. Quit and reopen Atlas so the grant takes effect."
  echo ""
  echo "If a later Atlas update turns the globe key off again, step 1 is the fix:"
  echo "macOS ties that permission to the exact build, so a new build asks again."
fi
