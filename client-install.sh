#!/usr/bin/env bash
#
# Atlas THIN-CLIENT one-line installer (macOS) — server mode, ADR-097;
# public HTTPS door (spec 2026-08-07).
#
#   ATLAS_CLIENT_TOKEN='<token>' \
#   bash -c "$(curl -fsSL https://atlas.esoteria.ai/install)"
#
# The server URL defaults to the public door (https://atlas.esoteria.ai) — the
# token is the only thing esoteria hands you. Legacy tailnet installs may still
# pass ATLAS_SERVER_URL='http://<name>.ts.net:8443' explicitly.
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
#   ATLAS_SERVER_URL        optional — your Atlas server (default: the public
#                           door https://atlas.esoteria.ai; tailnet URLs OK)
#   ATLAS_CLIENT_TOKEN      required — your personal bearer token (shown once)
#   ATLAS_APP_DIR           where Atlas.app goes (default: /Applications when
#                           writable, else ~/Applications)
#   ATLAS_INSTALL_REPO      public installer repo (default: esoteria-hq/atlas-install)
#   ATLAS_INSTALL_BASE_URL  asset-host override (TESTING — flat http server)
#   ATLAS_CLIENT_NO_LAUNCH=1  install but don't open / autostart (TESTING)
#   ATLAS_PREFETCH_ONLY=1   download + verify the payload into ~/.atlas/staging
#                           and stop — install nothing, launch nothing. The app
#                           runs this in the background the moment an update is
#                           announced, so that the click later has nothing left
#                           to download (ADR-939).
#   ATLAS_SILENT_UPDATE=1   with ATLAS_SELF_UPDATE=1: an update nobody pressed
#                           (ADR-1424) — the app runs it at a quiet moment (a
#                           login boot, the owner away, the owner's own Quit).
#                           Installs ONLY the stage a prefetch verified, with no
#                           network at all; writes no relaunch stamp (the app
#                           writes one itself when it wants its window back);
#                           and a failure reopens Atlas the way launchd starts
#                           it at login — no window. Add ATLAS_CLIENT_NO_LAUNCH=1
#                           for the Quit moment: nothing is launched or
#                           reopened, and an Atlas still running at the swap (the
#                           owner reopened it) is never quit — the update waits.
#   ATLAS_QUIT_GRACE_TRIES  how many 0.2 s polls the self-quit gets (default 150,
#                           ~30 s). TESTING only.

set -euo pipefail

# ASCII-only status glyphs: multi-byte unicode (✓ ⚠ › ═) mojibakes in
# non-UTF-8 terminals and made a working install read as garbled/failed.
# Every status line carries a clock. Until 2026-09-03 the self-update log had
# none, and the only way to learn that an update had spent 176 of its 188
# seconds downloading was to read the timestamp out of a parked bundle's name.
ts()    { date +%H:%M:%S; }
bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
ok()    { printf "%s \033[32m[ok]\033[0m %s\n" "$(ts)" "$*"; }
warn()  { printf "%s \033[33m[!]\033[0m %s\n" "$(ts)" "$*"; }
fail()  { printf "%s \033[31m[x]\033[0m %s\n" "$(ts)" "$*"; exit 1; }
step()  { printf "\n%s \033[1;34m==>\033[0m \033[1m%s\033[0m\n" "$(ts)" "$*"; }

# ── The update handshake (2026-08-24) ───────────────────────────────────────
# Two stamp files that only matter when a RUNNING Atlas spawned this script
# (ATLAS_SELF_UPDATE=1). They exist because of two measured field bugs; the full
# story is in apps/desktop/src/main/update-handshake.ts, the short version:
#
#   $PHASE_FILE     what this script is doing, one word. The app polls it and
#                   stays on screen saying so. `ready` is a CONTRACT: the
#                   payload is downloaded, SHA-verified and extracted, so the
#                   app may now quit and let its own bundle be replaced. Before
#                   this, the app quit 400 ms after the click — i.e. BEFORE the
#                   117 MB / 113-second download — and the owner watched an
#                   empty screen for two minutes.
#
#   $RELAUNCH_FILE  "the launch you are about to do is an update finishing".
#                   The app relaunches through launchd, which is indistinguish-
#                   able from a login boot, and a login boot is menubar-quiet by
#                   design — so the update reopened Atlas with NO WINDOW and the
#                   owner read it as a failed relaunch. The new build reads this
#                   stamp once and opens its window.
#
# Both are written ONLY under ATLAS_SELF_UPDATE=1: a plain curl-pipe install has
# no app waiting on them, and a stamp nobody reads is a stamp that goes stale.
ATLAS_STATE_DIR="$HOME/.atlas"
PHASE_FILE="$ATLAS_STATE_DIR/update-phase"
RELAUNCH_FILE="$ATLAS_STATE_DIR/update-relaunch"
# THE STAGE (ADR-939): where a prefetched payload waits for the click. The
# download was ~94% of an update's wall clock (176 s of 188 s measured
# 2026-09-03) and it did not start until the owner pressed Update. Now the app
# runs this script with ATLAS_PREFETCH_ONLY=1 as soon as the manifest announces
# a newer version, the tarball lands here verified, and the install run finds
# it. The stage is keyed by CONTENT, not by version: the install always fetches
# the published .sha256 (86 bytes) and trusts the stage only if it matches, so
# a release re-cut under the same number is still downloaded fresh.
STAGING_DIR="$ATLAS_STATE_DIR/staging"
# SILENT (ADR-1424) — see ATLAS_SILENT_UPDATE above. Only ever under a
# self-update: the flag means "the app asked for this at a quiet moment".
SILENT=0
if [ "${ATLAS_SELF_UPDATE:-}" = "1" ] && [ "${ATLAS_SILENT_UPDATE:-}" = "1" ]; then SILENT=1; fi
QUIT_GRACE_TRIES="${ATLAS_QUIT_GRACE_TRIES:-150}"

# Never fatal: `set -e` is on, and an unwritable ~/.atlas must cost the owner a
# progress word, not their update.
phase() {
  [ "${ATLAS_SELF_UPDATE:-}" = "1" ] || return 0
  mkdir -p "$ATLAS_STATE_DIR" 2>/dev/null || return 0
  printf '%s\n' "$1" > "$PHASE_FILE" 2>/dev/null || true
}

stamp_relaunch() {
  [ "${ATLAS_SELF_UPDATE:-}" = "1" ] || return 0
  # A silent install's window is the APP's call (it stamps before quitting when
  # the owner had the window open); the installer never invents one.
  [ "$SILENT" = "1" ] && return 0
  mkdir -p "$ATLAS_STATE_DIR" 2>/dev/null || return 0
  date -u +%Y-%m-%dT%H:%M:%SZ > "$RELAUNCH_FILE" 2>/dev/null || true
}

REPO="${ATLAS_INSTALL_REPO:-esoteria-hq/atlas-install}"
DEFAULT_SERVER_URL="https://atlas.esoteria.ai"
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
# `-a` IS THE WHOLE FIX OF 2026-09-02 AND MUST NOT BE DROPPED (ADR-913). BSD
# pgrep/pkill exclude the calling process AND ALL ITS ANCESTORS by default (man
# pgrep). A self-update runs this script as a CHILD of the Atlas it has to quit,
# so without -a every scan below answered "no Atlas running" while one was on
# screen: the quit gate waited for nobody, `ready` lived for milliseconds and
# the app never saw the word it quits on, the bundle swapped under a live
# process, and the kickstarted new build lost the single-instance lock to the
# survivor half a second before the verify caught it alive. Pinned by
# apps/desktop/tests/self_update_ancestor.test.ts against a real ancestor.
atlas_pids() { pgrep -a -x Atlas 2>/dev/null || true; }

# ── Which BUILD is running, when both live at the same path ─────────────────
# The verify at the end of [5/5] compares the running process's executable PATH
# against the one just installed. That was never able to catch the failure it
# was written for: this script REPLACES the bundle underneath a live process,
# so the old build keeps reporting `/Applications/Atlas.app/Contents/MacOS/Atlas`
# — byte-identical to the expected path — and the check passes it.
#
# Measured 2026-08-28 on the operator's Mac (0.10.0 -> 0.11.0): the app was
# hand-launched rather than started by launchd, so `launchctl kickstart -k` had
# no live job to kill; the fresh 0.11.0 it started lost Electron's
# single-instance lock to the surviving 0.10.0 and exited; and this script
# printed "[ok] verified: the running Atlas is …" about the OLD process. The
# owner sat on "Restarting…" until they quit by hand.
#
# START TIME is the signal that path cannot be: the build this run installed
# cannot have been running BEFORE this run began.
RUN_STARTED_EPOCH="$(date +%s)"

# Unix epoch at which $1 (a pid) started, or "" when it cannot be read. macOS
# `ps -o lstart=` prints "Wed Aug 26 13:08:11 2026"; `date -j -f` parses it back.
# %e (space-padded day) matches that format where %d would not.
atlas_start_epoch() {
  local started
  started="$(ps -p "$1" -o lstart= 2>/dev/null || true)"
  [ -n "$started" ] || return 0
  date -j -f '%a %b %e %T %Y' "$started" +%s 2>/dev/null || true
}

# Pids of Atlas processes that were already running when this script started —
# i.e. cannot be the build it just installed. An UNREADABLE start time is NOT
# reported: the remediation below quits what this lists, and killing a process
# on a failed date parse would be worse than the stale check this replaces.
atlas_stale_pids() {
  local pid epoch
  for pid in $(atlas_pids); do
    epoch="$(atlas_start_epoch "$pid")"
    [ -n "$epoch" ] || continue
    if [ "$epoch" -lt "$RUN_STARTED_EPOCH" ]; then printf '%s\n' "$pid"; fi
  done
  return 0
}

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
  # Self-update (ATLAS_SELF_UPDATE=1, set by apps/desktop/src/main/self-update.ts):
  # Atlas quits ITSELF, so give that self-quit time to land before escalating at
  # all. The osascript below, sent from this detached background process, can
  # hang on a TCC automation prompt it has no way to show (the invisible
  # 2026-08-14 update failure — the hang also kept the SIGTERM/SIGKILL rungs
  # below from ever running). AppleScript is the fallback for a wedged app,
  # never the first move against a healthy one.
  #
  # ~30s, not the ~10s this was: the app used to quit within 400 ms of spawning
  # this script and was therefore long gone by the time we got here, so the
  # grace was never actually spent. Under the handshake it only STARTS quitting
  # when it reads `ready` — written on the line just above this call — so the
  # whole of the app's shutdown (probe interval + the 400 ms IPC drain + tearing
  # down the pollers, tap helper and windows) now has to fit inside this window.
  # Overrunning it would escalate straight to the osascript rung this design
  # exists to avoid.
  if [ "${ATLAS_SELF_UPDATE:-}" = "1" ] && atlas_gone "$QUIT_GRACE_TRIES"; then return 0; fi
  osascript -e 'tell application "Atlas" to quit' >/dev/null 2>&1 || true
  if atlas_gone 25; then return 0; fi   # ~5s for a graceful Electron shutdown
  pkill -a -x Atlas 2>/dev/null || true # SIGTERM
  if atlas_gone 15; then return 0; fi   # ~3s
  pkill -a -9 -x Atlas 2>/dev/null || true
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

# ── The parking lot has a size limit now ────────────────────────────────────
# Parks used to be "never deleted" — and on one Mac that reached 4.3 GB across
# 15 bundles in three weeks, silently, in a Spotlight-invisible directory.
# Keep the newest PARK_KEEP entries (enough for a one-step rollback plus one)
# and drop the rest. Newest means the name's trailing date +%Y%m%d%H%M%S
# stamp, NOT the raw name: "atlas-client.prev.*" sorts after
# "Atlas.app.prev.*" in ASCII, so a raw-name sort would keep a months-old
# legacy park over yesterday's bundle.
PARK_KEEP=2
prune_park() {
  local park="$HOME/.atlas/previous.noindex" entry n=0
  [ -d "$park" ] || return 0
  while IFS= read -r entry; do
    case "$entry" in ''|.|..|*/*) continue ;; esac
    n=$((n + 1))
    if [ "$n" -gt "$PARK_KEEP" ]; then
      rm -rf "$park/${entry:?}"
      warn "dropped old parked bundle $entry (keeping the newest $PARK_KEEP)"
    fi
  done < <(ls -1 "$park" 2>/dev/null | awk -F. '{ print $NF "\t" $0 }' | sort -r | cut -f2-)
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

# ── One EXIT trap for the whole run ─────────────────────────────────────────
# TMP cleanup, plus the flip side of the app quitting itself for a self-update:
# if this script then dies half-way (server unreachable, download 404, checksum
# mismatch), the user is left with NO Atlas running and nothing to tell them
# why. On a failed self-update, reopen whatever build is still installed at
# APP_PATH — the download/verify failures all happen BEFORE the park/swap, so
# that is almost always the old build, intact.
TMP=""
on_exit() {
  local status=$?
  [ -n "$TMP" ] && rm -rf "$TMP"
  # The phase file describes a RUN, and this run is over. On the way out it says
  # WHICH way it went, because the app may still be sitting in front of it: it
  # only quits at `ready`, so every failure before that leaves a live Atlas
  # waiting on a word. Without this it waits ~30 minutes (the app's stuck
  # backstop) before admitting anything is wrong — for a download that failed in
  # ten seconds. A stale `download` would be worse still, so success clears.
  if [ "$status" -ne 0 ]; then
    phase failed
  else
    rm -f "$PHASE_FILE" 2>/dev/null || true
  fi
  # Never on the Quit moment (silent + ATLAS_CLIENT_NO_LAUNCH, ADR-1424): the
  # owner closed Atlas on purpose, and a failed update nobody pressed is no
  # reason to open it on them.
  local quit_moment=0
  if [ "$SILENT" = "1" ] && [ "${ATLAS_CLIENT_NO_LAUNCH:-}" = "1" ]; then quit_moment=1; fi
  if [ "$status" -ne 0 ] && [ "${ATLAS_SELF_UPDATE:-}" = "1" ] && [ "$quit_moment" = "0" ] \
     && [ -z "$(atlas_pids)" ] && [ -d "$APP_PATH" ]; then
    warn "the update did not finish — reopening the Atlas that is still installed"
    if [ "$SILENT" = "1" ]; then
      # Nobody pressed anything, so nobody is waiting for a window: bring Atlas
      # back the way it runs at login (launchd, menubar-quiet). The login-boot
      # flag keeps even the `open` fallback quiet (first-run.ts isUserLaunch).
      launchctl kickstart "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1 \
        || open -g "$APP_PATH" --args --atlas-login-boot 2>/dev/null || true
    else
      # `open` brings Atlas to the front; it does NOT give it a window, because a
      # launch with setup already done is menubar-quiet. An owner whose update
      # just failed is the last person who should be left looking at nothing, so
      # the reopen carries the same stamp a successful relaunch does.
      stamp_relaunch
      open "$APP_PATH" 2>/dev/null || true
    fi
  fi
}
trap on_exit EXIT

# THE FIRST STAMP, as early as an EXIT handler exists to clear it again. The app
# treats "no phase file within 3 seconds" as "this installer predates the
# handshake" and quits immediately, the old way — so this must be written before
# anything slow, and it must not be written anywhere the trap could not undo it.
phase check

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

# The public door is the DEFAULT: the token is the only thing a new client is
# given. An explicit ATLAS_SERVER_URL still wins, which is what keeps legacy
# tailnet installs working unchanged.
SERVER_URL="${ATLAS_SERVER_URL:-$DEFAULT_SERVER_URL}"
# Strip trailing slashes ONCE, here, before anything concatenates a path onto
# this. `https://atlas.esoteria.ai/` is what a human copies out of a browser, and
# it turns the reachability probe below into `…ai//gateway/health` (404 on Caddy
# -> the install fails against a perfectly healthy server) and lands the same
# double slash in every URL the app builds from client.json.
while [[ "$SERVER_URL" == */ ]]; do SERVER_URL="${SERVER_URL%/}"; done
TOKEN="${ATLAS_CLIENT_TOKEN:-}"
if [[ -z "$TOKEN" && -r /dev/tty ]]; then
  printf "Your access token (never echoed): "
  read -rs TOKEN < /dev/tty
  echo ""
fi
[[ "$SERVER_URL" =~ ^https?:// ]] || fail "ATLAS_SERVER_URL must start with http:// or https://"
[[ -n "$TOKEN" ]] || fail "ATLAS_CLIENT_TOKEN is required (esoteria gives you this once)"

# The desktop UI's Content-Security-Policy (connect-src) allows only the public
# door + *.ts.net names (+ loopback) — a RAW IP produces an install that looks healthy
# (curl/health returns 200, background pollers connect) but whose UI can never
# reach the server and shows "You're offline". Resolve the known server IP to
# its MagicDNS name; reject any other raw IP rather than ship a broken install.
SERVER_HOST="${SERVER_URL#*://}"; SERVER_HOST="${SERVER_HOST%%[:/]*}"
if [[ "$SERVER_HOST" == "100.111.77.47" ]]; then
  SERVER_URL="${SERVER_URL/100.111.77.47/atlas-server-1.tailc0f037.ts.net}"
  warn "using the server's MagicDNS name instead of its raw IP (the app blocks raw IPs): $SERVER_URL"
elif [[ "$SERVER_HOST" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  fail "ATLAS_SERVER_URL points at a raw IP ($SERVER_HOST). The app blocks raw IPs, so an IP install can't connect from the UI even though the server is up. Use the public door ($DEFAULT_SERVER_URL) or, for a legacy tailnet install, the server's .ts.net name."
fi
ok "server + token provided"

# Legacy tailnet installs ONLY (the URL is a tailnet name): Tailscale must be on
# this Mac to reach the server. The public door needs nothing installed.
if [[ "$SERVER_URL" == *"ts.net"* || "$SERVER_URL" == *"://100."* ]]; then
  if ! command -v tailscale >/dev/null && [ ! -d "/Applications/Tailscale.app" ]; then
    warn "your server address looks like Tailscale, but Tailscale isn't installed."
    warn "install it from https://tailscale.com/download (or the Mac App Store),"
    warn "sign in with the invite esoteria sent you, then relaunch Atlas."
  else
    ok "tailscale present"
  fi
fi

# Reach the server BEFORE downloading 113 MB and writing config. Without this,
# an unreachable server produces the exact failure the raw-IP guard above exists
# to prevent: every line prints [ok], the app launches, and the only symptom is a
# UI stuck on "You're offline" with nothing explaining why.
#
# The public door makes this reachable-looking-but-not case ordinary rather than
# exotic: the default URL is a real hostname that may simply have no DNS yet, so
# an install that used to fail fast on a missing ATLAS_SERVER_URL would instead
# succeed into a dead client.
#
# GET /gateway/health, NOT /health. The daemon exempts its own /health
# (auth.ts EXEMPT_EXACT) but the GATEWAY sits in front on 8443 and gates it —
# measured against the live server 2026-08-08: /health 401 without a bearer,
# /gateway/health 200. Probing /health here would have made every tokenless
# install fail its own reachability check on a perfectly healthy server.
# /gateway/health needs no token and proves the whole path: DNS, TLS, Caddy,
# gateway.
# A SILENT install touches no network (ADR-1424): it installs a stage that was
# verified when it landed, at a moment the network may well be down (a login
# boot before Wi-Fi joins). The probe below is for installs that download.
if [ "$SILENT" != "1" ] && ! curl -fsS -m 10 -o /dev/null "$SERVER_URL/gateway/health" 2>/dev/null; then
  if [[ "$SERVER_URL" == "$DEFAULT_SERVER_URL" ]]; then
    fail "can't reach $SERVER_URL — the public door isn't answering yet.
  If esoteria gave you a server address, pass it explicitly:
    ATLAS_SERVER_URL='http://<name>.ts.net:8443' ATLAS_CLIENT_TOKEN='<token>' bash -c \"\$(curl -fsSL $DEFAULT_SERVER_URL/install)\"
  Otherwise the door is still being set up — ask esoteria before retrying."
  fi
  fail "can't reach $SERVER_URL (GET /gateway/health failed).
  Check the address is right, that you're on the network that can see it, and
  — for a .ts.net address — that Tailscale is running and signed in."
fi
ok "server reachable"

# ── [2/5] Download + verify the app ─────────────────────────────────────────
step "[2/5] Download Atlas"
TMP=$(mktemp -d)   # cleaned up by on_exit (the single EXIT trap above)
# THE 113 SECONDS. 117 MB over the owner's connection, measured 2026-08-24, and
# ~99% of the wall clock of an update (verify + extract + install together were
# under 2 s). It is also the only part of this script the app is still alive
# for, which is why it gets its own word. Since ADR-939 this step is usually a
# one-second checksum fetch: the payload was staged by a prefetch run while the
# owner was still deciding.
# Land the published payload in $STAGING_DIR, verified, fetching only what the
# stage does not already hold. Both the prefetch run and the install run go
# through this one function, so there is exactly one URL, one verify and one
# resume path. Sets STAGED_TARBALL.
sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
# THE NETWORK IS NOT ALLOWED TO STALL THE SWAP (ADR-1014). On 2026-09-06 the
# 0.15.0 → 0.15.1 update spent 76 s — twice, once in the prefetch and once on
# the click — inside the curl for the 100-byte .sha256, on a flaky link, before
# it even looked at the payload the prefetch had already verified. A bare curl
# has no connect timeout: one dead address costs the TCP timeout, ~75 s. Every
# fetch below carries a connect timeout and retries, the checksum fetch a hard
# ceiling as well; and when the checksum cannot be fetched at all, a stage the
# prefetch verified against the PUBLISHED checksum (kept beside it as
# $SHA_ASSET) is still that payload, and the install proceeds from it instead
# of failing — the version the owner pressed Update on. A prefetch gets no such
# fallback: it exists to fetch, and has nothing to install.
CURL_NET=(--connect-timeout 8 --retry 3 --retry-delay 2)
CURL_SMALL=(--connect-timeout 5 --retry 1 --retry-delay 1 --max-time 15)
stage_payload() {
  mkdir -p "$STAGING_DIR"
  STAGED_TARBALL="$STAGING_DIR/$TARBALL_ASSET"
  STAGED_SHA="$STAGING_DIR/$SHA_ASSET"
  local part="$STAGED_TARBALL.part" want
  if [ "$SILENT" = "1" ]; then
    # SILENT (ADR-1424): the stage the prefetch verified against the published
    # checksum (kept beside it), or nothing. Never a download: this runs when
    # nobody asked, so it must be seconds long and must not spend the owner's
    # bandwidth on a payload nobody knows is still the latest.
    phase verify
    local kept
    kept="$(cut -d' ' -f1 "$STAGED_SHA" 2>/dev/null || true)"
    if [[ -f "$STAGED_TARBALL" && "$kept" =~ ^[0-9a-f]{64}$ ]] \
       && [[ "$(sha_of "$STAGED_TARBALL")" == "$kept" ]]; then
      ok "installing the staged payload ($STAGED_TARBALL) — silent, no network"
      return 0
    fi
    fail "nothing verified is staged — a silent install never downloads"
  fi
  phase download
  if ! curl -fsSL "${CURL_SMALL[@]}" -o "$TMP/$SHA_ASSET" "$SHA_URL"; then
    if [[ "${ATLAS_PREFETCH_ONLY:-}" != "1" ]] && [[ -f "$STAGED_TARBALL" && -f "$STAGED_SHA" ]] \
       && [[ "$(cut -d' ' -f1 "$STAGED_SHA")" =~ ^[0-9a-f]{64}$ ]] \
       && [[ "$(sha_of "$STAGED_TARBALL")" == "$(cut -d' ' -f1 "$STAGED_SHA")" ]]; then
      warn "could not reach the release server for the checksum — installing the payload the prefetch verified ($STAGED_TARBALL)"
      return 0
    fi
    fail "checksum download failed: $SHA_URL"
  fi
  want="$(cut -d' ' -f1 "$TMP/$SHA_ASSET")"
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || fail "the published checksum is not a SHA-256: $(head -c 120 "$TMP/$SHA_ASSET")"
  if [[ -f "$STAGED_TARBALL" ]] && [[ "$(sha_of "$STAGED_TARBALL")" == "$want" ]]; then
    cp -f "$TMP/$SHA_ASSET" "$STAGED_SHA"
    ok "payload already staged + SHA-256 verified ($STAGED_TARBALL)"
    return 0
  fi
  rm -f "$STAGED_TARBALL" "$STAGED_SHA"
  # A .part from an interrupted run resumes (GitHub honours ranges); if the
  # server will not, or the resume fails for any reason, start over rather
  # than fail — the payload is what matters, not the saved seconds.
  local started
  started="$(date +%s)"
  if [[ -f "$part" ]]; then
    curl -fsSL "${CURL_NET[@]}" -C - -o "$part" "$TARBALL_URL" || rm -f "$part"
  fi
  if [[ ! -f "$part" ]]; then
    curl -fsSL "${CURL_NET[@]}" -o "$part" "$TARBALL_URL" || { rm -f "$part"; fail "download failed: $TARBALL_URL"; }
  fi
  phase verify
  if [[ "$(sha_of "$part")" != "$want" ]]; then
    rm -f "$part"
    fail "checksum mismatch — refusing to install"
  fi
  mv -f "$part" "$STAGED_TARBALL"
  # The checksum this stage was verified against, so a later click can trust
  # the stage when the release server is out of reach (see above).
  cp -f "$TMP/$SHA_ASSET" "$STAGED_SHA"
  ok "downloaded $(du -h "$STAGED_TARBALL" | cut -f1 | tr -d ' ') in $(( $(date +%s) - started ))s + SHA-256 verified"
}
stage_payload

if [[ "${ATLAS_PREFETCH_ONLY:-}" == "1" ]]; then
  ok "prefetch complete — the payload waits in $STAGING_DIR for the next Update"
  exit 0
fi

tar -xzf "$STAGED_TARBALL" -C "$TMP"
[[ -d "$TMP/atlas-client/Atlas.app" ]] || fail "the bundle is missing Atlas.app (stale release? try again shortly)"

mkdir -p "$APP_DIR"
# READY — and this line is the whole point of the handshake. Everything that can
# fail before the swap has now not failed: the tarball is downloaded, its SHA
# matched, it extracted, and Atlas.app is really inside it. From here the live
# bundle is in the way and nothing else is. The app polls for this word and
# quits on it, which is why quit_atlas below usually finds nothing to do.
phase ready
# Quit a running Atlas BEFORE anything moves, whatever directory it was launched
# from — a live process holding an inode we are about to park is the whole of
# defect 1. Unconditional (not gated on `-d $APP_PATH`) because the running build
# may live somewhere else entirely, e.g. an older ~/Applications install.
QUIT_GATE_PIDS="$(atlas_pids | tr '\n' ' ')"
if [ "$SILENT" = "1" ] && [ "${ATLAS_CLIENT_NO_LAUNCH:-}" = "1" ]; then
  # THE QUIT MOMENT (ADR-1424). Atlas is exiting on the owner's own Quit and
  # started this on its way out. Wait for that exit — but never push: an Atlas
  # still here after the grace is one the owner opened again, and quitting it
  # would read as a crash. It keeps the stage; the next quiet moment installs.
  if atlas_gone "$QUIT_GRACE_TRIES"; then
    ok "Atlas has quit — swapping in the staged build"
  else
    fail "Atlas is running again — leaving the update staged for the next quiet moment"
  fi
elif [ -n "$(printf '%s' "$QUIT_GATE_PIDS" | tr -d '[:space:]')" ]; then
  if quit_atlas; then
    ok "quit the running Atlas (was pids: $QUIT_GATE_PIDS)"
  else
    warn "an Atlas process would not exit even after SIGKILL (pids: $(atlas_pids | tr '\n' ' '))."
    warn "the new build will be installed, but quit Atlas by hand and re-run this installer"
    warn "if the check at the end says the wrong build is live."
  fi
else
  # SAY the skip. Under ATLAS_SELF_UPDATE=1 an empty gate is the normal, happy
  # case — the app quit itself at `ready`, exactly as designed. But a run where
  # the app did NOT quit and this gate still found nothing is a contradiction,
  # and on 2026-08-28 it happened with no line in the log to prove which way it
  # went. A skip that prints is a skip that can be diagnosed.
  ok "no running Atlas at the swap (it quit itself, or was never up)"
fi
if [[ -d "$APP_PATH" ]]; then
  # Park OUT of /Applications: a parked bundle there haunts Spotlight and
  # Launchpad as a ghost "Atlas" (blank-icon helper apps included — field
  # find 2026-07-12). ~/.atlas/previous.noindex is invisible to Spotlight
  # (.noindex); prune_park below keeps only the newest $PARK_KEEP.
  PARK="$HOME/.atlas/previous.noindex"
  mkdir -p "$PARK"
  mv "$APP_PATH" "$PARK/Atlas.app.prev.$(date +%Y%m%d%H%M%S)"
  warn "existing Atlas.app parked in $PARK (newest $PARK_KEEP kept)"
fi
# ditto preserves the bundle's code signature (cp -R can break it on the
# framework symlinks), and the tarball extracts onto tmpfs, so copy properly.
phase install
ditto "$TMP/atlas-client/Atlas.app" "$APP_PATH"
ok "installed $APP_PATH"
# The stage has done its job. Left behind, a 99 MB tarball of the build now
# in /Applications would sit there until the next release; cleared, the next
# prefetch starts from nothing, which is exactly the state it expects.
rm -rf "$STAGING_DIR"

# The previous layout (~/atlas-client, raw electron via npm) is superseded —
# move it aside so nothing points at it.
if [[ -d "$HOME/atlas-client" ]]; then
  PARK="$HOME/.atlas/previous.noindex"
  mkdir -p "$PARK"
  mv "$HOME/atlas-client" "$PARK/atlas-client.prev.$(date +%Y%m%d%H%M%S)"
  warn "old-style install ~/atlas-client parked in $PARK (superseded by Atlas.app)"
fi

# Unconditional (not tied to whether THIS run parked anything): the lots that
# actually hit 4.3 GB were filled by installs that predate the retention, so
# the first run of this script has to be the one that cleans them up.
prune_park

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
  HELPER_OK=0
fi

# "we didn't install one" is NOT the same as "you don't have one" — the two
# branches above deliberately leave a previously-installed, working helper in
# place, and the closing advice has to describe the Mac's actual state rather
# than this run's. Without this, a reinstall of an older build told a user whose
# globe key works fine that dictation and meeting capture were off, and hid the
# Accessibility instructions that are the real remaining step.
if [ "$HELPER_OK" != "1" ] && [ -x "$HELPER_DEST" ] \
   && "$HELPER_DEST" exclude-screen-capture >/dev/null 2>&1; then
  ok "kept the working helper already at $HELPER_DEST"
  HELPER_OK=1
elif [ "$HELPER_OK" != "1" ]; then
  warn "consequence: the 🌐 globe key won't start dictation (it falls back to"
  warn "Option-Shift-Space), and meeting recording + meeting detection stay off."
  warn "Ask esoteria for a build published after 2026-08-06, then re-run this installer."
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
  <!-- ADR-1014: launchd refuses to respawn a job within 10 s of its last exit
       unless told otherwise, and a self-update is exactly that: Atlas quits
       itself for the swap, and the kickstart a few seconds later was
       "service spawn deferred by 8 seconds due to throttle" (unified log,
       2026-09-06 11:03:28). One second is the floor launchd accepts. -->
  <key>ThrottleInterval</key><integer>1</integer>
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
# `bootout` is ASYNCHRONOUS: it returns as soon as the teardown is queued, and a
# `bootstrap` issued while the old label is still going away fails with EBUSY /
# "Input/output error (5)". Swallowing that with `|| true` and printing [ok]
# anyway is the same class of lie this rewrite exists to kill — the user would be
# told Atlas starts at login when the label never loaded. Retry, then BELIEVE
# `launchctl print`, not an exit code.
launchd_loaded() { launchctl print "$SERVICE_TARGET" >/dev/null 2>&1; }
for _ in 1 2 3 4 5 6 7 8 9 10; do
  launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
  if launchd_loaded; then break; fi
  sleep 0.3
done
# `kickstart -k` is the line that actually starts the NEW binary. `bootstrap`
# alone is a silent no-op when the label is already loaded — so on every
# reinstall it loaded nothing, started nothing, and still fell through to the
# "[ok] Atlas starts at login" below. -k kills whatever the label is running and
# restarts it from the plist we just wrote.
if launchd_loaded; then
  ok "registered to start at login ($PLIST_LABEL)"
else
  warn "could not register Atlas to start at login (launchctl bootstrap failed)."
  warn "Atlas still works — you'll just have to open it yourself after a reboot."
  warn "Fix it later with: launchctl bootstrap gui/\$(id -u) \"$PLIST\""
fi
# THE STAMP THAT GIVES THE UPDATE ITS WINDOW BACK. Written before the launch,
# never after: the app reads it during its own startup, so a stamp written after
# kickstart is a stamp written after the only read of it. See the handshake note
# at the top of this file for why a relaunched Atlas would otherwise come back
# invisible.
phase launch
stamp_relaunch
# Deliberately NOT an [ok] "Atlas started" here: whether Atlas started, and
# whether the thing that started is the build we just installed, is not known
# until the verify below. Claiming it here is the shape of the bug.
#
# `kickstart -k` restarts the LAUNCHD JOB. When the live Atlas was opened by
# hand (Dock, Finder, `open`) it is not that job, so -k kills nothing, and the
# instance this starts loses Electron's single-instance lock to the survivor and
# exits — the 2026-08-28 failure. quit_stale_atlas below is the answer to that.
start_atlas() {
  if ! launchctl kickstart -k "$SERVICE_TARGET" >/dev/null 2>&1; then
    warn "launchctl could not start Atlas — opening it directly instead"
    open "$APP_PATH" || warn "could not open $APP_PATH — start Atlas from $APP_DIR"
  fi
}

# Quit every Atlas that predates this run — the survivors holding the
# single-instance lock. Same ladder as quit_atlas, aimed by pid rather than by
# name, so a NEW build that has already started is never signalled.
quit_stale_atlas() {
  local pids
  pids="$(atlas_stale_pids | tr '\n' ' ')"
  [ -n "$(printf '%s' "$pids" | tr -d '[:space:]')" ] || return 1
  warn "an Atlas from before this update is still running (pids: $pids) — quitting it"
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true            # SIGTERM
  local tries=25                            # ~5s for a graceful Electron exit
  while [ "$tries" -gt 0 ] && [ -n "$(atlas_stale_pids)" ]; do sleep 0.2; tries=$((tries - 1)); done
  if [ -n "$(atlas_stale_pids)" ]; then
    # shellcheck disable=SC2086
    kill -9 $(atlas_stale_pids | tr '\n' ' ') 2>/dev/null || true
    tries=10
    while [ "$tries" -gt 0 ] && [ -n "$(atlas_stale_pids)" ]; do sleep 0.2; tries=$((tries - 1)); done
  fi
  [ -z "$(atlas_stale_pids)" ]
}

start_atlas

# VERIFY, don't assume — the check whose absence let defect 1 ship. Everything
# above can print [ok] while the process actually serving the user is the build
# we just parked in ~/.atlas/previous.noindex/.
#
# PATH IS NOT ENOUGH, and that is the 2026-08-28 fix. We just replaced the
# bundle under a live process, so the OLD build answers with the very path we
# are about to compare against and sails through. `atlas_fresh_paths` answers
# the question this check was always asking — "is the process serving the user
# the one I just installed?" — by dropping every pid that was already running
# when this script began. A build installed at 14:19 cannot have started at
# 13:08 the previous day.
EXPECTED_BIN="$APP_PATH/Contents/MacOS/Atlas"

# Executable paths of Atlas processes started SINCE this run began.
atlas_fresh_paths() {
  local pid path stale
  stale="$(atlas_stale_pids | tr '\n' ' ')"
  for pid in $(atlas_pids); do
    case " $stale " in *" $pid "*) continue ;; esac
    path="$(ps -ww -o comm= -p "$pid" 2>/dev/null || true)"
    if [ -n "$path" ]; then printf '%s\n' "$path"; fi
  done
  return 0
}

# Up to ~10s for Electron to be up. Run twice: if the first pass finds only
# processes that predate this run, the survivor is holding the single-instance
# lock and the build we installed cannot start until it goes — so quit it and
# kickstart again rather than reporting a success the owner will not see.
RUNNING=""
for attempt in 1 2; do
  for _ in $(seq 1 40); do
    RUNNING="$(atlas_fresh_paths)"
    if printf '%s\n' "$RUNNING" | grep -Fxq "$EXPECTED_BIN"; then break; fi
    sleep 0.25
  done
  if printf '%s\n' "$RUNNING" | grep -Fxq "$EXPECTED_BIN"; then break; fi
  [ "$attempt" = "1" ] || break
  quit_stale_atlas || break
  start_atlas
done
# What the owner is actually looking at, fresh or not — the failure branches
# below report on the whole picture, not only on what this run started.
RUNNING_ALL="$(atlas_running_paths)"
# grep -Fx (exact whole line), never a substring test: "$HOME/Applications/
# Atlas.app/…" CONTAINS "/Applications/Atlas.app/…", so a substring match would
# call the wrong build a pass.
LAUNCH_VERIFIED=0
if printf '%s\n' "$RUNNING" | grep -Fxq "$EXPECTED_BIN"; then
  LAUNCH_VERIFIED=1
  ok "verified: the running Atlas is $EXPECTED_BIN"
  STRAYS="$(printf '%s\n' "$RUNNING_ALL" | grep -Fxv "$EXPECTED_BIN" | grep -v '^$' || true)"
  if [ -n "$STRAYS" ]; then
    warn "another Atlas is ALSO running, from: $(printf '%s' "$STRAYS" | tr '\n' ' ')"
    warn "quit it (menu bar orb -> Quit) so only the new build is live."
  fi
elif [ -n "$(atlas_stale_pids)" ]; then
  # The one the path check could never name: the new build never came up, and
  # what the owner is looking at is the build we just parked. Say THAT, because
  # "did not start" would send them looking for a launch failure that is really
  # a process that would not leave.
  warn "THE ATLAS ON SCREEN IS THE OLD BUILD — it would not quit, so the new one could not start."
  warn "  still running (from before this update): $(atlas_stale_pids | tr '\n' ' ')"
  warn "  installed: $EXPECTED_BIN"
  warn "Quit Atlas (menu bar orb -> Quit) and open it again; the new build is already in place."
elif [ -z "$(printf '%s' "$RUNNING_ALL" | tr -d '[:space:]')" ]; then
  warn "Atlas did not start within 10s."
else
  warn "THE RUNNING ATLAS IS NOT THE ONE JUST INSTALLED."
  warn "  running:   $(printf '%s' "$RUNNING_ALL" | tr '\n' ' ')"
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
