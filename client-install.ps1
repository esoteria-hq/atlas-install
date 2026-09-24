# Atlas THIN-CLIENT one-line installer (Windows) — server mode, ADR-097; the
# Windows client, ADR-1003. The PowerShell twin of client-install.sh: the same
# steps, the same stamps, the same environment switches, so the app's
# self-update (apps/desktop/src/main/self-update.ts + update-handshake.ts) drives
# both installers through one contract.
#
#   $env:ATLAS_CLIENT_TOKEN='<token>'; irm https://atlas.esoteria.ai/install.ps1 | iex
#
# The server URL defaults to the public door (https://atlas.esoteria.ai) — the
# token is the only thing esoteria hands you.
#
# What lands on the PC: Atlas.exe and its resources under
# %LOCALAPPDATA%\Programs\Atlas (per-user, no admin), the native helper it
# spawns for the Right-Ctrl dictation door and meeting capture
# (%USERPROFILE%\.atlas\bin\atlas-capture-helper.exe), %USERPROFILE%\.atlas\
# client.json pointing at YOUR Atlas server, a Start Menu shortcut, and a
# per-user Run entry so Atlas starts at sign-in. No harness code, no prompts,
# no skills, no API keys, no Node — the agent runs on esoteria's server.
#
# Environment (identical to the Mac installer's):
#   ATLAS_SERVER_URL        optional — your Atlas server (default: the public door)
#   ATLAS_CLIENT_TOKEN      required — your personal bearer token (shown once)
#   ATLAS_APP_DIR           where Atlas goes (default: %LOCALAPPDATA%\Programs\Atlas)
#   ATLAS_INSTALL_REPO      public installer repo (default: esoteria-hq/atlas-install)
#   ATLAS_INSTALL_BASE_URL  asset-host override (TESTING — flat http server)
#   ATLAS_CLIENT_NO_LAUNCH=1  install but don't open / autostart (TESTING)
#   ATLAS_PREFETCH_ONLY=1   download + verify the payload into ~/.atlas/staging
#                           and stop (ADR-939 — the app runs this the moment an
#                           update is announced, so the click downloads nothing)
#   ATLAS_SELF_UPDATE=1     set by the app: write the phase / relaunch stamps,
#                           wait for the app to quit itself at `ready`.
#
# THE UPDATE HANDSHAKE (see the Mac installer's header + update-handshake.ts):
#   ~/.atlas/update-phase     one word: check / download / verify / ready /
#                             install / launch / failed. `ready` is the CONTRACT:
#                             the payload is verified and extracted, the app may
#                             quit and let its files be replaced.
#   ~/.atlas/update-relaunch  "the launch you are about to do is an update
#                             finishing" — the app opens its window on it.
# Both are written ONLY under ATLAS_SELF_UPDATE=1.

# RUN AS ITS OWN PROCESS (ADR-1414). `irm … | iex` runs this text INSIDE the
# owner's own PowerShell window: every `exit` below closed that window — so a
# wrong token or an unreachable server flashed its red line and vanished, and
# the success line went the same way — and the `Stop` preference and the trap
# stayed behind in their session. Under iex there is no script file
# ($PSCommandPath is empty), so this fetches the installer again, from where
# the one-liner's /install.ps1 points (infra/server/Caddyfile), and runs it as
# a child in this same window; `return` (not `exit`) then hands the window back.
if (-not $PSCommandPath) {
  & {
    $repo = if ($env:ATLAS_INSTALL_REPO) { $env:ATLAS_INSTALL_REPO } else { "esoteria-hq/atlas-install" }
    $src = if ($env:ATLAS_INSTALL_BASE_URL) { "$($env:ATLAS_INSTALL_BASE_URL)/client-install.ps1" } else { "https://raw.githubusercontent.com/$repo/main/client-install.ps1" }
    $self = Join-Path ([IO.Path]::GetTempPath()) ("atlas-install-" + [Guid]::NewGuid().ToString("N") + ".ps1")
    try {
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
      Invoke-WebRequest -Uri $src -OutFile $self -UseBasicParsing
    } catch {
      Write-Host "Could not download the Atlas installer ($src): $($_.Exception.Message)" -ForegroundColor Red
      return
    }
    try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $self }
    finally {
      Remove-Item $self -ErrorAction SilentlyContinue
      # The token the one-liner put in this window's environment has done its
      # job: every program started from here would otherwise inherit it.
      Remove-Item Env:ATLAS_CLIENT_TOKEN -ErrorAction SilentlyContinue
    }
  }
  return
}

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # Invoke-WebRequest's progress bar is the slow part of a download in PS5

# WINDOWS POWERSHELL'S OWN MODULES (found by the windows-client job, 2026-09-24).
# A PowerShell 7 ancestor (the terminal the one-liner was pasted into, a CI
# step, anything it started) hands down ITS module path, and Windows PowerShell
# then cannot load its own script-module cmdlets: `Get-FileHash` "is not
# recognized" and the install stops at the checksum. Under Windows PowerShell,
# the path is its own: the user's modules, Program Files', and $PSHOME's.
if ($PSVersionTable.PSEdition -ne "Core") {
  $env:PSModulePath = @(
    (Join-Path ([Environment]::GetFolderPath("MyDocuments")) "WindowsPowerShell\Modules"),
    (Join-Path $env:ProgramFiles "WindowsPowerShell\Modules"),
    (Join-Path $PSHOME "Modules")
  ) -join ";"
}
# PowerShell 7.4+ turns a NONZERO NATIVE EXIT into a terminating error while
# ErrorActionPreference is Stop. This script reads exit codes itself (the
# helper probe below is allowed to fail and be reported), so an exit code must
# stay a value, not an exception.
$PSNativeCommandUseErrorActionPreference = $false

function ts    { (Get-Date).ToString("HH:mm:ss") }
function ok    { param($m) Write-Host "$(ts) [ok] $m" }
function warn  { param($m) Write-Host "$(ts) [!] $m" -ForegroundColor Yellow }
function step  { param($m) Write-Host ""; Write-Host "$(ts) ==> $m" -ForegroundColor Cyan }
# `fail` runs `finish` ITSELF (ADR-1398). bash's `trap on_exit EXIT` sees
# every exit; PowerShell's `trap` sees only errors, never `exit` — so a failure
# here used to skip the `failed` stamp (the app sat on "Updating" for its
# 30-minute backstop) and the reopen (a self-update that had already quit Atlas
# left the owner with none). `finish` is defined below; nothing calls `fail`
# before it is.
function fail  { param($m) Write-Host "$(ts) [x] $m" -ForegroundColor Red; $script:Status = 1; finish; exit 1 }

# ── Paths + names ────────────────────────────────────────────────────────────
$AtlasStateDir = Join-Path $env:USERPROFILE ".atlas"
$PhaseFile     = Join-Path $AtlasStateDir "update-phase"
$RelaunchFile  = Join-Path $AtlasStateDir "update-relaunch"
$StagingDir    = Join-Path $AtlasStateDir "staging"
$LogDir        = Join-Path $AtlasStateDir "logs"
$HelperName    = "atlas-capture-helper.exe"
$HelperDir     = Join-Path $AtlasStateDir "bin"
$HelperDest    = Join-Path $HelperDir $HelperName
$Repo          = if ($env:ATLAS_INSTALL_REPO) { $env:ATLAS_INSTALL_REPO } else { "esoteria-hq/atlas-install" }
$DefaultServer = "https://atlas.esoteria.ai"
$ZipAsset      = "atlas-client-win.zip"
$ShaAsset      = "atlas-client-win.zip.sha256"
$RunKeyName    = "Atlas"
$LoginBootFlag = "--atlas-login-boot"   # apps/desktop/src/main/platform.ts LOGIN_BOOT_FLAG

$SelfUpdate = $env:ATLAS_SELF_UPDATE -eq "1"

# Run the helper's no-op subcommand and hand back its exit code. Never throws:
# a helper that cannot start is a REPORTED failure (the caller keeps whatever
# helper was already installed), not a dead install.
function probe_helper { param($exe)
  try {
    & $exe exclude-screen-capture 2>&1 | Out-Null
    return $LASTEXITCODE
  } catch {
    return 1
  }
}

# Never fatal: an unwritable ~/.atlas must cost the owner a progress word, not their update.
function phase { param($word)
  if (-not $SelfUpdate) { return }
  try { New-Item -ItemType Directory -Force -Path $AtlasStateDir | Out-Null; Set-Content -Path $PhaseFile -Value $word -NoNewline -ErrorAction SilentlyContinue } catch {}
}
function stamp_relaunch {
  if (-not $SelfUpdate) { return }
  try { New-Item -ItemType Directory -Force -Path $AtlasStateDir | Out-Null; Set-Content -Path $RelaunchFile -Value ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")) -ErrorAction SilentlyContinue } catch {}
}

# Atlas's home: per-user Programs, no admin, the same place every per-user
# Electron app (Slack, Discord, VS Code user setup) lives.
$AppDir = if ($env:ATLAS_APP_DIR) { $env:ATLAS_APP_DIR } else { Join-Path $env:LOCALAPPDATA "Programs\Atlas" }
$ExePath = Join-Path $AppDir "Atlas.exe"

# NOT FROM INSIDE THE APP (ADR-1398). A process's current directory is an open
# handle on that folder, and Windows will not move a folder held that way. The
# in-app Update starts this script with Atlas's own directory — $AppDir, when
# the Start Menu shortcut or the launch below opened it — so the park further
# down failed on every such update, AFTER the app had quit for it. Set-Location
# moves PowerShell's view; [Environment]::CurrentDirectory moves the process's.
if ($SelfUpdate) {
  Set-Location -LiteralPath $env:USERPROFILE
  [Environment]::CurrentDirectory = $env:USERPROFILE
}

# Start Atlas without the install's secrets and switches (ADR-1398): launchd
# gives the Mac's a clean environment, but Start-Process hands down ours, so
# every process the new app spawns carried the token, and its next background
# prefetch ran as a self-update, writing the phase stamps.
function start_atlas {
  foreach ($v in "ATLAS_CLIENT_TOKEN", "ATLAS_SERVER_URL", "ATLAS_SELF_UPDATE", "ATLAS_PREFETCH_ONLY") {
    Remove-Item "Env:$v" -ErrorAction SilentlyContinue
  }
  Start-Process -FilePath $ExePath -WorkingDirectory $AppDir
}

# ── Which Atlas is running ──────────────────────────────────────────────────
# `Get-Process Atlas` names the MAIN process and its Chromium children alike
# (Electron's helpers on Windows are all Atlas.exe); the main one is the one
# whose parent is not Atlas. Good enough for quit / verify: we act on all of
# them, and all of them exit with the main one.
$RunStarted = Get-Date
function atlas_procs { Get-Process -Name "Atlas" -ErrorAction SilentlyContinue }
function atlas_stale_procs { atlas_procs | Where-Object { $_.StartTime -lt $RunStarted } }
function atlas_gone { param([int]$tries)
  while ($tries -gt 0) {
    if (-not (atlas_procs)) { return $true }
    Start-Sleep -Milliseconds 200
    $tries--
  }
  return -not (atlas_procs)
}

# Ask nicely (the app quits itself at `ready` under a self-update), then
# insist (CloseMainWindow → WM_CLOSE), then compel (Stop-Process).
function quit_atlas {
  if (-not (atlas_procs)) { return $true }
  if ($SelfUpdate -and (atlas_gone 150)) { return $true }   # ~30 s for the self-quit
  atlas_procs | ForEach-Object { try { $_.CloseMainWindow() | Out-Null } catch {} }
  if (atlas_gone 25) { return $true }
  atlas_procs | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {} }
  return (atlas_gone 15)
}

# ── One exit path for the whole run ─────────────────────────────────────────
$Tmp = $null
$script:Status = 1
function finish {
  if ($Tmp -and (Test-Path $Tmp)) { Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue }
  if ($script:Status -ne 0) { phase "failed" } else { Remove-Item $PhaseFile -ErrorAction SilentlyContinue }
  if ($script:Status -ne 0 -and $SelfUpdate -and -not (atlas_procs) -and (Test-Path $ExePath)) {
    warn "the update did not finish - reopening the Atlas that is still installed"
    stamp_relaunch
    try { start_atlas } catch {}
  }
}
trap { warn $_; $script:Status = 1; finish; exit 1 }

# THE FIRST STAMP, as early as a finish path exists to clear it again.
phase "check"

if ($env:ATLAS_INSTALL_BASE_URL) {
  $ZipUrl = "$($env:ATLAS_INSTALL_BASE_URL)/$ZipAsset"
  $ShaUrl = "$($env:ATLAS_INSTALL_BASE_URL)/$ShaAsset"
} else {
  $ZipUrl = "https://github.com/$Repo/releases/latest/download/$ZipAsset"
  $ShaUrl = "https://github.com/$Repo/releases/latest/download/$ShaAsset"
}

Write-Host "==============================================================="
Write-Host "  Atlas - thin client installer (Windows, server mode)"
Write-Host "==============================================================="

# ── [1/5] Sanity ────────────────────────────────────────────────────────────
step "[1/5] Sanity"
if (-not ($IsWindows -or $env:OS -eq "Windows_NT")) { fail "this installer is for Windows (for a Mac: bash -c `"`$(curl -fsSL $DefaultServer/install)`")" }
if ([Environment]::Is64BitOperatingSystem -ne $true) { fail "Atlas needs 64-bit Windows" }
ok "Windows $([Environment]::OSVersion.Version)"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$ServerUrl = if ($env:ATLAS_SERVER_URL) { $env:ATLAS_SERVER_URL } else { $DefaultServer }
$ServerUrl = $ServerUrl.TrimEnd('/')
$Token = $env:ATLAS_CLIENT_TOKEN
if (-not $Token -and [Environment]::UserInteractive) {
  $secure = Read-Host -Prompt "Your access token (never echoed)" -AsSecureString
  $Token = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}
if ($ServerUrl -notmatch '^https?://') { fail "ATLAS_SERVER_URL must start with http:// or https://" }
if (-not $Token) { fail "ATLAS_CLIENT_TOKEN is required (esoteria gives you this once)" }
$ServerHost = ($ServerUrl -replace '^https?://', '') -replace '[:/].*$', ''
if ($ServerHost -match '^\d{1,3}(\.\d{1,3}){3}$') {
  fail "ATLAS_SERVER_URL points at a raw IP ($ServerHost). The app blocks raw IPs; use the public door ($DefaultServer) or the server's .ts.net name."
}
ok "server + token provided"

# Reach the server BEFORE downloading ~200 MB. /gateway/health needs no token
# and proves DNS, TLS and the gateway (the Mac installer's note explains why
# not /health).
try {
  Invoke-WebRequest -Uri "$ServerUrl/gateway/health" -UseBasicParsing -TimeoutSec 10 | Out-Null
} catch {
  fail "can't reach $ServerUrl (GET /gateway/health failed: $($_.Exception.Message)). Check the address, and that you're on a network that can see it."
}
ok "server reachable"

# ── [2/5] Download + verify the app ─────────────────────────────────────────
step "[2/5] Download Atlas"
$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("atlas-install-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null

function sha_of { param($p) (Get-FileHash -Algorithm SHA256 -Path $p).Hash.ToLowerInvariant() }

# THE NETWORK IS NOT ALLOWED TO STALL THE SWAP (ADR-1014, the Mac installer's
# rule; ADR-1414 here). Invoke-WebRequest has no connect timeout, no retry and
# no resume, and in Windows PowerShell 5.1 it crawls through a large file.
# curl.exe ships in every Windows 10 1803+ and does all three, so it is the
# fetch; Invoke-WebRequest is the fallback on a Windows without it. Returns
# whether the file landed; the caller words the failure.
$CurlExe = Join-Path $env:SystemRoot "System32\curl.exe"
function fetch { param([string]$Url, [string]$Out, [switch]$Small, [switch]$Resume)
  if (Test-Path $CurlExe) {
    $net = if ($Small) { @("--connect-timeout", "5", "--retry", "1", "--retry-delay", "1", "--max-time", "15") }
           else { @("--connect-timeout", "8", "--retry", "3", "--retry-delay", "2") }
    $cont = if ($Resume) { @("-C", "-") } else { @() }
    # Continue, and stderr dropped: Windows PowerShell 5.1 turns a native
    # program's stderr into ERRORS when its own output is redirected (a
    # self-update's is, to a log), and under Stop the first retry warning
    # would kill the install.
    $ErrorActionPreference = "Continue"
    & $CurlExe -fsSL @net @cont -o $Out $Url 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
  }
  try {
    if ($Small) { Invoke-WebRequest -Uri $Url -OutFile $Out -UseBasicParsing -TimeoutSec 15 }
    else { Invoke-WebRequest -Uri $Url -OutFile $Out -UseBasicParsing }
    return $true
  } catch { return $false }
}

# Land the published payload in the STAGE, verified, fetching only what the
# stage does not already hold (ADR-939). Both the prefetch and the install go
# through this one function: one URL, one verify, one resume path.
function stage_payload {
  New-Item -ItemType Directory -Force -Path $StagingDir | Out-Null
  $script:Staged = Join-Path $StagingDir $ZipAsset
  $stagedSha = Join-Path $StagingDir $ShaAsset
  $part = "$script:Staged.part"
  phase "download"
  $shaFile = Join-Path $Tmp $ShaAsset
  if (-not (fetch -Url $ShaUrl -Out $shaFile -Small)) {
    # A stage the prefetch verified against the PUBLISHED checksum (kept beside
    # it) is still that payload: install it rather than fail the Update the
    # owner pressed. A prefetch has nothing to install, so it fails.
    if ($env:ATLAS_PREFETCH_ONLY -ne "1" -and (Test-Path $script:Staged) -and (Test-Path $stagedSha)) {
      $kept = ((Get-Content $stagedSha -Raw) -split '\s+')[0].ToLowerInvariant()
      if ($kept -match '^[0-9a-f]{64}$' -and (sha_of $script:Staged) -eq $kept) {
        warn "could not reach the release server for the checksum - installing the payload the prefetch verified ($script:Staged)"
        return
      }
    }
    fail "checksum download failed: $ShaUrl"
  }
  $want = ((Get-Content $shaFile -Raw) -split '\s+')[0].ToLowerInvariant()
  if ($want -notmatch '^[0-9a-f]{64}$') { fail "the published checksum is not a SHA-256: $want" }
  if ((Test-Path $script:Staged) -and ((sha_of $script:Staged) -eq $want)) {
    Copy-Item -Force $shaFile $stagedSha
    ok "payload already staged + SHA-256 verified ($script:Staged)"
    return
  }
  Remove-Item $script:Staged, $stagedSha -ErrorAction SilentlyContinue
  $started = Get-Date
  # A .part from an interrupted run resumes (GitHub honours ranges); if that
  # fails for any reason, start over rather than fail.
  if ((Test-Path $part) -and -not (fetch -Url $ZipUrl -Out $part -Resume)) { Remove-Item $part -ErrorAction SilentlyContinue }
  if (-not (Test-Path $part) -or ((sha_of $part) -ne $want)) {
    Remove-Item $part -ErrorAction SilentlyContinue
    if (-not (fetch -Url $ZipUrl -Out $part)) { Remove-Item $part -ErrorAction SilentlyContinue; fail "download failed: $ZipUrl" }
  }
  phase "verify"
  if ((sha_of $part) -ne $want) { Remove-Item $part -ErrorAction SilentlyContinue; fail "checksum mismatch - refusing to install" }
  Move-Item -Force $part $script:Staged
  # The checksum this stage was verified against, for the fallback above.
  Copy-Item -Force $shaFile $stagedSha
  $mb = [math]::Round((Get-Item $script:Staged).Length / 1MB)
  ok "downloaded ${mb} MB in $([int]((Get-Date) - $started).TotalSeconds)s + SHA-256 verified"
}
stage_payload

if ($env:ATLAS_PREFETCH_ONLY -eq "1") {
  ok "prefetch complete - the payload waits in $StagingDir for the next Update"
  $script:Status = 0; finish; exit 0
}

$Extract = Join-Path $Tmp "extract"
Expand-Archive -Path $script:Staged -DestinationPath $Extract -Force
$NewApp = Get-ChildItem -Path $Extract -Directory | Where-Object { Test-Path (Join-Path $_.FullName "Atlas.exe") } | Select-Object -First 1
if (-not $NewApp) { fail "the bundle is missing Atlas.exe (stale release? try again shortly)" }

# READY — the payload is verified and extracted; the live app is now the only
# thing in the way. The app polls for this word and quits on it.
phase "ready"
if (atlas_procs) {
  if (quit_atlas) { ok "quit the running Atlas" }
  else { warn "an Atlas process would not exit; the new build will be installed, but quit Atlas by hand if the check at the end says the wrong build is live" }
} else {
  ok "no running Atlas at the swap (it quit itself, or was never up)"
}

# Park the old install OUT of the way (Windows locks files of running
# processes, so a rename fails loudly if the quit above did not take).
phase "install"
if (Test-Path $AppDir) {
  $Park = Join-Path $AtlasStateDir "previous.noindex"
  New-Item -ItemType Directory -Force -Path $Park | Out-Null
  $stamp = (Get-Date).ToString("yyyyMMddHHmmss")
  # Retried for ~10 s (ADR-1398): the app's helpers are killed WITH it but let
  # go of their files a moment later, and antivirus holds a just-used exe
  # briefly — either one fails a single attempt.
  $parked = $false
  for ($i = 0; $i -lt 20 -and -not $parked; $i++) {
    try { Move-Item -Path $AppDir -Destination (Join-Path $Park "Atlas.prev.$stamp") -ErrorAction Stop; $parked = $true }
    catch { $why = $_.Exception.Message; Start-Sleep -Milliseconds 500 }
  }
  if (-not $parked) { fail "could not move the old Atlas aside ($why) - is it still running?" }
  warn "existing Atlas parked in $Park"
  # Keep the newest 2 parks (the Mac installer's PARK_KEEP).
  Get-ChildItem -Path $Park -Directory | Sort-Object Name -Descending | Select-Object -Skip 2 | ForEach-Object { Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue }
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $AppDir) | Out-Null
Move-Item -Path $NewApp.FullName -Destination $AppDir
ok "installed $AppDir"
Remove-Item -Recurse -Force $StagingDir -ErrorAction SilentlyContinue

# Settings > Apps > Installed apps (ADR-1414): without this key Atlas was on the
# PC and in no list, with no way off it but deleting folders by hand. Per-user
# (HKCU), like the rest of the install; the uninstaller ships in resources.
$UninstallScript = Join-Path $AppDir "resources\client-uninstall.ps1"
if (Test-Path $UninstallScript) {
  try {
    $key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Atlas"
    New-Item -Path $key -Force | Out-Null
    $version = (Get-Item $ExePath).VersionInfo.ProductVersion
    $kb = [int]((Get-ChildItem $AppDir -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1KB)
    $entry = @{
      DisplayName = "Atlas"; DisplayVersion = "$version"; Publisher = "esoteria"
      DisplayIcon = "$ExePath,0"; InstallLocation = $AppDir; URLInfoAbout = "https://esoteria.ai"
      UninstallString = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$UninstallScript`""
    }
    foreach ($name in $entry.Keys) { New-ItemProperty -Path $key -Name $name -Value $entry[$name] -PropertyType String -Force | Out-Null }
    foreach ($name in "NoModify", "NoRepair") { New-ItemProperty -Path $key -Name $name -Value 1 -PropertyType DWord -Force | Out-Null }
    New-ItemProperty -Path $key -Name "EstimatedSize" -Value $kb -PropertyType DWord -Force | Out-Null
    ok "listed in Settings > Apps (uninstall from there)"
  } catch {
    warn "could not list Atlas in Settings > Apps ($($_.Exception.Message))"
  }
}

# ── [3/5] The native helper ─────────────────────────────────────────────────
# Three features die without it: the Right-Ctrl dictation door, meeting
# auto-detect, meeting recording. The app prefers the copy inside its own
# resources\bin (staged by packaging/afterPack.cjs); ~/.atlas/bin is the
# fallback the Mac installer keeps too.
step "[3/5] Dictation + meeting helper"
$HelperSrc = Join-Path $AppDir "resources\bin\$HelperName"
$HelperOk = $false
if (Test-Path $HelperSrc) {
  New-Item -ItemType Directory -Force -Path $HelperDir | Out-Null
  # THE STAGED NAME KEEPS ITS .exe. The Mac installer stages "<name>.new" and
  # runs it, because on Unix only the exec bit decides what is runnable — on
  # Windows the EXTENSION does, so a file called "atlas-capture-helper.exe.new"
  # cannot be launched at all ("the system cannot find all the information
  # required", CI's first real installer run). Rename-on-success still gives
  # the same atomicity, and it still never clobbers a working helper: a copy
  # over a RUNNING exe is refused by the file lock, which is the hazard this
  # dance exists for.
  $staged = Join-Path $HelperDir "atlas-capture-helper.new.exe"
  Remove-Item $staged -ErrorAction SilentlyContinue
  Copy-Item -Force $HelperSrc $staged
  # Prove it runs before it becomes the live path: `exclude-screen-capture`
  # is the documented no-op (exit 0, no output, nothing to grant).
  if ((probe_helper $staged) -eq 0) {
    Move-Item -Force $staged $HelperDest
    ok "installed $HelperDest (Right-Ctrl dictation + meeting capture)"
    $HelperOk = $true
  } else {
    Remove-Item $staged -ErrorAction SilentlyContinue
    warn "the helper shipped in this build will not run on this PC - left the previous one alone."
  }
} else {
  warn "this Atlas build shipped without the native helper."
}
if (-not $HelperOk -and (Test-Path $HelperDest)) {
  if ((probe_helper $HelperDest) -eq 0) { ok "kept the working helper already at $HelperDest"; $HelperOk = $true }
}
if (-not $HelperOk) {
  warn "consequence: the Right Ctrl key won't start dictation (it falls back to Ctrl+Shift+Space), and meeting recording + detection stay off."
}

# ── [4/5] Connection config ─────────────────────────────────────────────────
step "[4/5] Connect to your Atlas"
New-Item -ItemType Directory -Force -Path $AtlasStateDir | Out-Null
$Config = Join-Path $AtlasStateDir "client.json"
$json = @{ server_url = $ServerUrl; token = $Token } | ConvertTo-Json
[IO.File]::WriteAllText($Config, $json + "`n", (New-Object Text.UTF8Encoding($false)))
# Owner-only ACL — the Windows 0600.
try {
  $acl = Get-Acl $Config
  $acl.SetAccessRuleProtection($true, $false)
  $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
  $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($me, "FullControl", "Allow")))
  Set-Acl $Config $acl
  ok "wrote $Config (owner-only)"
} catch {
  ok "wrote $Config"
}

# ── [5/5] Autostart + launch ────────────────────────────────────────────────
step "[5/5] Launch"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
if ($env:ATLAS_CLIENT_NO_LAUNCH -eq "1") {
  ok "skipping launch (ATLAS_CLIENT_NO_LAUNCH=1)"
  Write-Host "start manually with: `"$ExePath`""
  $script:Status = 0; finish; exit 0
}

# Start at sign-in: the per-user Run key (no admin, no Task Scheduler). The
# login-boot flag is how the app tells this launch (menubar-quiet by design)
# from the owner opening it (first-run.ts isUserLaunch).
try {
  New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name $RunKeyName -Value "`"$ExePath`" $LoginBootFlag" -PropertyType String -Force | Out-Null
  ok "registered to start at sign-in (HKCU Run\$RunKeyName)"
} catch {
  warn "could not register Atlas to start at sign-in ($($_.Exception.Message)). Atlas still works - open it yourself after a reboot."
}

# A Start Menu shortcut, so "Atlas" is one Start-menu search away. The app
# rewrites it on launch carrying its AppUserModelID (win-notify.ts, ADR-1401) —
# WScript.Shell cannot set one, and Windows shows no toasts without it.
try {
  $programs = [Environment]::GetFolderPath("Programs")
  $lnk = Join-Path $programs "Atlas.lnk"
  $wsh = New-Object -ComObject WScript.Shell
  $sc = $wsh.CreateShortcut($lnk)
  $sc.TargetPath = $ExePath
  $sc.WorkingDirectory = $AppDir
  $sc.IconLocation = "$ExePath,0"
  $sc.Description = "Atlas"
  $sc.Save()
  ok "Start Menu shortcut: $lnk"
} catch {
  warn "could not create the Start Menu shortcut ($($_.Exception.Message))"
}

phase "launch"
stamp_relaunch
# Quit every Atlas that predates this run (a survivor holds Electron's
# single-instance lock and the new build would exit to it).
$stale = atlas_stale_procs
if ($stale) {
  warn "an Atlas from before this update is still running - quitting it"
  $stale | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {} }
  Start-Sleep -Milliseconds 800
}
start_atlas

# VERIFY, don't assume: the process serving the owner must be the build just
# installed — one that started AFTER this run began, from $ExePath.
$verified = $false
for ($i = 0; $i -lt 40; $i++) {
  $fresh = atlas_procs | Where-Object { $_.StartTime -ge $RunStarted }
  $paths = @($fresh | ForEach-Object { try { $_.Path } catch { $null } } | Where-Object { $_ })
  if ($paths -contains $ExePath) { $verified = $true; break }
  Start-Sleep -Milliseconds 250
}
if ($verified) {
  ok "verified: the running Atlas is $ExePath"
} elseif (atlas_stale_procs) {
  warn "THE ATLAS ON SCREEN IS THE OLD BUILD - it would not quit, so the new one could not start."
} else {
  warn "Atlas did not come up within 10 s."
}

# The closing tells the truth about what was verified (ADR-1414, the Mac
# installer's rule): the cheerful line under a failed verify is the same
# failure one paragraph later. Exit stays 0 either way — every file IS
# installed, and the remedy is a restart, not a reinstall.
Write-Host ""
if ($verified) {
  Write-Host "Done. Atlas is opening - its icon is in the system tray (under the ^ by the clock if Windows tucked it away)." -ForegroundColor Green
  Write-Host "Your assistant runs on esoteria's server in your own private profile;"
  Write-Host "this PC holds only the app and your connection file ($Config)."
  if ($HelperOk) { Write-Host "Hold the Right Ctrl key and talk to dictate; press Alt+Shift+Space to ask." }
  else { Write-Host "Press Ctrl+Shift+Space to dictate (the Right Ctrl key needs the helper, which did not install); press Alt+Shift+Space to ask." }
} else {
  Write-Host "Installed, but Atlas is NOT running the new build yet." -ForegroundColor Yellow
  Write-Host "Everything is on disk - this is the last step, and it takes 20 seconds:"
  Write-Host "  1. Quit every Atlas: right-click its tray icon > Quit"
  Write-Host "  2. Open Atlas from the Start Menu"
  Write-Host "If it still won't start, send esoteria the folder $LogDir"
}
$script:Status = 0
finish
exit 0
