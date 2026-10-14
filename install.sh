#!/usr/bin/env bash
# Titanfall 2 VR (CircuitLord's TF2VR mod) played directly on a Steam Frame.
#
#   ./install.sh               install or update the mod and the Steam launch wrapper
#   ./install.sh --check       preflight checks only, change nothing
#   ./install.sh --force       reinstall the mod even if it is already up to date
#   ./install.sh --beta        use the mod's beta channel instead of the stable release
#   ./install.sh --uninstall   remove the mod files and the wrapper (campaign saves are kept)
#   ./install.sh --game DIR    the folder with Titanfall2.exe, if it isn't found automatically
#   ./install.sh --no-launch-options   never touch Steam's launch options
#   ./install.sh --restart     restart the device at the end without asking, if that's needed to
#                              set the launch options
#   ./install.sh --diagnose    print what's needed to debug the launch options (also saved to a file)
#
# Steam is never closed (on the Frame it is the device's shell). Steam rewrites its settings while
# it runs, so when it's running the launch options are set during the next restart, which the
# installer offers to do at the end.
#
# Run it on the Frame itself (desktop mode terminal, or over SSH). It works on any Steam Linux
# device, ARM64 or x86_64, because it never runs Windows programs itself: the one step that needs
# Wine (the mod's asset_patcher.exe) runs on the first launch from Steam, inside Steam's own
# FEX + Proton setup, through tf2vr-frame-launch.
#
# Installs the same files, from the same downloads with the same checksums, as
# CircuitLordVRModInstaller.exe on Windows. Set STEAM_DIR=/path/to/Steam if Steam isn't found.
#
# Internal: tf2vr-frame-launch calls `install.sh --finish --game DIR` after asset_patcher.exe ran.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

REPO_RAW="https://raw.githubusercontent.com/CircuitLord/CircuitLordVRModInstaller"
MANIFEST_URL="$REPO_RAW/main/manifest-v3.json"
APPID=1237970

STATE="${XDG_DATA_HOME:-$HOME/.local/share}/tf2vr-frame"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/tf2vr-frame"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/tf2vr-frame"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tf2vr-frame"
HELPER="$HERE/lib/tf2vr_frame.py"
LAUNCHER="$STATE/tf2vr-frame-launch"

MODE=install
FORCE=0
CHANNEL=stable
OPT_GAME=""
LAUNCH_OPTIONS=1
RESTART=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check)     MODE=check ;;
    --uninstall) MODE=uninstall ;;
    --finish)    MODE=finish ;;
    --diagnose)  MODE=diagnose ;;
    --force)     FORCE=1 ;;
    --beta)      CHANNEL=beta ;;
    --yes|-y)    ;;  # older versions closed Steam after asking; nothing to confirm any more
    --no-launch-options) LAUNCH_OPTIONS=0 ;;
    --restart)   RESTART=1 ;;
    --game)
      [ $# -ge 2 ] && [ -d "$2" ] || { echo "install.sh: --game needs the folder with Titanfall2.exe" >&2; exit 2; }
      OPT_GAME=$(readlink -f "$2")
      shift ;;
    -h|--help)   awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "install.sh: unknown option '$1' (try --help)" >&2; exit 2 ;;
  esac
  shift
done

fails=0
warns=0
ok()   { printf '  ok    %s\n' "$1"; }
warn() { printf '  WARN  %s\n' "$1"; warns=$((warns + 1)); }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }
die()  { printf '\nERROR: %s\n' "$1" >&2; exit 1; }
helper() { python3 "$HELPER" "$@"; }

# ------------------------------------------------------------ discovery --
# Nothing is assumed about where things are: Steam is looked for in its usual Linux locations
# (or STEAM_DIR), and Titanfall 2 in every library listed in Steam's libraryfolders.vdf, so it is
# found on internal storage, a microSD card or an external drive alike.
discover() {
  STEAM="" GAME="" PREFIX=""
  eval "$(helper find-game "${STEAM_DIR:-}")"
  if [ -n "$OPT_GAME" ]; then
    GAME=$OPT_GAME
    # Prefix of a game passed by hand: the compatdata next to its library, else the one found above
    local lib=${GAME%/steamapps/common/*}
    [ "$lib" != "$GAME" ] && [ -d "$lib/steamapps/compatdata/$APPID/pfx" ] && PREFIX="$lib/steamapps/compatdata/$APPID"
  fi
  PFX="$PREFIX/pfx"
}

# ------------------------------------------------------------ preflight --
preflight() {
  echo "Preflight:"
  local t arch
  for t in curl sha256sum python3; do
    command -v "$t" >/dev/null 2>&1 && ok "$t available" || fail "$t is not installed"
  done
  if command -v bsdtar >/dev/null 2>&1; then ok "bsdtar available"
  elif command -v cabextract >/dev/null 2>&1; then ok "cabextract available"
  else warn "neither bsdtar nor cabextract is installed - needed only if the VC++ runtime in the game's prefix is too old"
  fi

  arch=$(uname -m)
  case "$arch" in
    aarch64|arm64) ok "$arch (Steam Frame or other ARM device): Titanfall 2 runs through Steam's x86 emulation (FEX) and Proton" ;;
    x86_64)        ok "x86_64: Titanfall 2 runs through Steam's Proton" ;;
    *)             warn "$arch hasn't been considered by these scripts" ;;
  esac

  if [ -n "$STEAM" ]; then ok "Steam: $STEAM"
  else fail "Steam not found - run with STEAM_DIR=/path/to/Steam"
  fi
  if [ -n "$GAME" ] && [ -f "$GAME/Titanfall2.exe" ]; then
    ok "Titanfall 2: $GAME"
  elif [ -n "$GAME" ]; then
    fail "$GAME doesn't contain Titanfall2.exe"
  else
    fail "Titanfall 2 isn't installed in any Steam library - install it in Steam, or point at it with --game DIR"
  fi
  if [ -n "$PREFIX" ] && [ -f "$PFX/system.reg" ]; then
    ok "Wine prefix: $PREFIX"
  else
    fail "Titanfall 2 has no Wine prefix yet - start it once from Steam the normal way, sign in to the EA app, reach the main menu, then quit"
  fi
  if [ -n "$PREFIX" ] && [ -n "$(find "$PFX/drive_c/Program Files/Electronic Arts/EA Desktop" -maxdepth 3 -name EADesktop.exe -print -quit 2>/dev/null)" ]; then
    ok "EA app installed in the prefix"
  elif [ -n "$PREFIX" ]; then
    warn "EA app not found in the prefix - start Titanfall 2 once from Steam and sign in"
  fi
  if [ -f "$STATE/version" ]; then ok "Installed: $(cat "$STATE/version")"; else ok "Mod not installed yet"; fi
  if [ -f "$STATE/setup-pending" ]; then ok "Waiting for the first launch from Steam to finish setup"; fi
  # The first launch builds about 3 GB of game assets in ~/.local/share, then moves them into the game folder
  local free_kb
  free_kb=$(df -Pk "$HOME" 2>/dev/null | awk 'NR == 2 { print $4 }')
  if [ -n "$free_kb" ] && [ "$free_kb" -lt 4194304 ]; then
    fail "only $((free_kb / 1048576)) GB free in your home folder - the first launch needs about 4 GB. Free some space (uninstall a game, or clear Steam's shader cache) and run this again"
  elif [ -n "$free_kb" ]; then
    ok "free space: $((free_kb / 1048576)) GB"
  fi
}

# --------------------------------------------------- VC++ runtime (prefix) --
VCREDIST_URL="https://aka.ms/vs/17/release/vc_redist.x64.exe"
VC_DLLS="concrt140 msvcp140 msvcp140_1 msvcp140_2 msvcp140_atomic_wait msvcp140_codecvt_ids vcruntime140 vcruntime140_1"

vc_new_enough() { [ -n "$1" ] && [ "$(printf '%s\n14.40\n' "$1" | sort -V | head -n 1)" = "14.40" ]; }

# Titanfall2VR.dll is built with a recent MSVC and crashes (null read in MSVCP140.dll right after
# the plugin loads) against the 14.3x runtime the EA app installs into the prefix. Copy Microsoft's
# current x64 runtime DLLs out of vc_redist.x64.exe into the prefix, the way winetricks does, so
# no Windows program has to run for it. A copy is kept for tf2vr-frame-launch, which restores it
# if a Proton update replaces it.
ensure_vcredist() {
  echo
  echo "VC++ runtime in the prefix:"
  local sys32="$PFX/drive_c/windows/system32" version tmp dll cab
  version=$(helper vc-version "$sys32/msvcp140.dll")
  if vc_new_enough "$version" && compgen -G "$STATE/vcrt/*.dll" >/dev/null; then
    ok "msvcp140.dll $version"
    return
  fi
  mkdir -p "$CACHE"
  curl -fL --progress-bar -o "$CACHE/vc_redist.x64.exe" "$VCREDIST_URL" || die "couldn't download $VCREDIST_URL"
  tmp=$(mktemp -d "$CACHE/vcredist.XXXXXX")
  if command -v cabextract >/dev/null 2>&1 && cabextract -q -d "$tmp" -F a12 "$CACHE/vc_redist.x64.exe" 2>/dev/null; then
    cabextract -q -d "$tmp" "$tmp/a12" 2>/dev/null || true
  elif command -v bsdtar >/dev/null 2>&1; then
    # bsdtar only reads the first cabinet of the bundle, so cut each one out first
    helper split-cabs "$CACHE/vc_redist.x64.exe" "$tmp" || true
    for cab in "$tmp"/bundle*.cab; do
      bsdtar -xf "$cab" -C "$tmp" a12 2>/dev/null && break
    done
    [ -f "$tmp/a12" ] && bsdtar -xf "$tmp/a12" -C "$tmp" 2>/dev/null
  fi
  [ -f "$tmp/msvcp140.dll_amd64" ] || { rm -rf "$tmp"; die "couldn't unpack the VC++ runtime from vc_redist.x64.exe (needs bsdtar or cabextract)"; }
  rm -rf "$STATE/vcrt"
  mkdir -p "$STATE/vcrt"
  for dll in $VC_DLLS; do
    [ -f "$tmp/$dll.dll_amd64" ] && cp "$tmp/$dll.dll_amd64" "$STATE/vcrt/$dll.dll"
  done
  rm -rf "$tmp"
  version=$(helper vc-version "$STATE/vcrt/msvcp140.dll")
  vc_new_enough "$version" || die "the VC++ runtime from $VCREDIST_URL is ${version:-unreadable}, expected 14.40 or newer"
  for dll in "$STATE"/vcrt/*.dll; do
    rm -f "$sys32/$(basename "$dll")"   # may be a link to Proton's own copy; never write through it
    cp "$dll" "$sys32/"
  done
  ok "msvcp140.dll $version copied into the prefix"
}

# ------------------------------------------------------------ the mod --
# fetch <url> <sha256> <file>: download into the cache unless a verified copy is already there
fetch() {
  local url=$1 sha=$2 out=$3
  if [ -f "$out" ] && [ "$(sha256sum "$out" | cut -d' ' -f1)" = "$sha" ]; then
    ok "cached $(basename "$out")"
    return
  fi
  echo "  downloading $(basename "$out")..."
  curl -fL --progress-bar -o "$out.part" "$url"
  [ "$(sha256sum "$out.part" | cut -d' ' -f1)" = "$sha" ] || { rm -f "$out.part"; die "checksum mismatch for $url"; }
  mv "$out.part" "$out"
  ok "downloaded and verified $(basename "$out")"
}

core_files_present() {
  local f
  for f in Titanfall2VRLauncher.exe TF2VR/Northstar.dll TF2VR/plugins/Titanfall2VR.dll \
           TF2VR/tools/crash_monitor.exe TF2VR/tools/launch.json; do
    [ -f "$GAME/$f" ] || return 1
  done
  [ "$(helper check-loopback "$GAME/TF2VR/plugins/Titanfall2VR.dll" 2>/dev/null)" = patched ]
}

# Downloads the release, checks it, and stages it in $STATE/stage. The game folder isn't touched
# until asset_patcher.exe has built its files from the unmodified game, like the official installer.
stage_mod() {
  echo
  echo "Titanfall 2 VR mod ($CHANNEL):"
  local manifest mod_version mod_url mod_sha commit source ns_version ns_url ns_sha
  manifest=$(curl -fsSL "$MANIFEST_URL?t=$(date +%s)") || die "couldn't download $MANIFEST_URL"
  read -r mod_version mod_url mod_sha commit < <(CHANNEL=$CHANNEL python3 -c '
import json, os, sys
m = json.load(sys.stdin)
t = m["titanfall2vr"]
if os.environ["CHANNEL"] != "stable":
    t = next(c for c in t.get("channels", []) if c["id"] == os.environ["CHANNEL"])
print(t["version"], t["url"], t["sha256"], m["installer"]["commit"])' <<<"$manifest") || true
  [ -n "${commit:-}" ] || die "couldn't read the Titanfall 2 VR $CHANNEL entry from $MANIFEST_URL"

  # Northstar is pinned in the official installer's source; read it from the same release
  source=$(curl -fsSL "$REPO_RAW/$commit/src/Installer/Installers/Titanfall2Installer.cs") \
    || die "couldn't read the official installer's Northstar pin"
  ns_version=$(sed -n 's/.*NorthstarVersion = "\([^"]*\)".*/\1/p' <<<"$source")
  ns_url=$(sed -n 's/.*NorthstarUrl = "\([^"]*\)".*/\1/p' <<<"$source")
  ns_sha=$(sed -n 's/.*NorthstarSha256 = "\([^"]*\)".*/\1/p' <<<"$source")
  [ -n "$ns_version" ] && [ -n "$ns_url" ] && [ -n "$ns_sha" ] || die "couldn't find the Northstar pin in Titanfall2Installer.cs"

  WANTED="mod=$mod_version northstar=$ns_version"
  if [ "$FORCE" = 0 ] && [ "$(cat "$STATE/version" 2>/dev/null)" = "$WANTED" ] && core_files_present; then
    ok "up to date ($WANTED)"
    return 1
  fi
  if [ "$FORCE" = 0 ] && [ -f "$STATE/setup-pending" ] && [ "$(cat "$STATE/stage/version" 2>/dev/null)" = "$WANTED" ] \
     && stage_complete; then
    ok "$WANTED is downloaded and waiting for the first launch from Steam"
    return 0
  fi
  echo "  installing $WANTED"

  mkdir -p "$CACHE" "$STATE"
  local mod_zip="$CACHE/Titanfall2VR-$mod_version.zip" ns_zip="$CACHE/Northstar-$ns_version.zip"
  fetch "$mod_url" "$mod_sha" "$mod_zip"
  fetch "$ns_url" "$ns_sha" "$ns_zip"

  local stage="$STATE/stage" f state
  rm -rf "$stage" "$STATE/setup-pending"
  mkdir -p "$stage"
  helper extract "$mod_zip" "$stage/mod"
  helper extract "$ns_zip" "$stage/ns" NorthstarLauncher.exe R2Northstar/
  for f in mod/Titanfall2VR.dll mod/xr_probe.exe mod/crash_monitor.exe mod/launch.json mod/release.json \
           mod/asset_patcher.exe mod/patches/manifest.json ns/NorthstarLauncher.exe ns/R2Northstar/Northstar.dll; do
    [ -f "$stage/$f" ] || die "download is missing $f"
  done

  # The audio fix: see "Why is Titanfall2VR.dll patched?" in the README
  state=$(helper patch-loopback "$stage/mod/Titanfall2VR.dll") \
    || die "couldn't apply the audio fix to Titanfall2VR.dll $mod_version ($state). This mod version needs an update to these scripts; please open an issue."
  ok "audio fix applied to Titanfall2VR.dll (loopback capture -> default output device)"
  (cd "$stage" && find mod ns -type f) > "$stage/files.lst"
  printf '%s\n' "$WANTED" > "$stage/version"
  return 0
}

# Every downloaded file is still in the stage (an older version moved them out one by one)
stage_complete() {
  local f
  [ -f "$STATE/stage/files.lst" ] || return 1
  while IFS= read -r f; do
    [ -f "$STATE/stage/$f" ] || return 1
  done < "$STATE/stage/files.lst"
}

install_launcher() {
  echo
  echo "Steam launch wrapper:"
  mkdir -p "$STATE/lib" "$CONF_DIR" "$LOG_DIR"
  install -m755 "$HERE/tf2vr-frame-launch" "$LAUNCHER"
  install -m755 "$HERE/install.sh" "$STATE/install.sh"
  install -m644 "$HERE/lib/tf2vr_frame.py" "$STATE/lib/tf2vr_frame.py"
  install -m644 "$HERE/lib/setup_progress.exe" "$STATE/lib/setup_progress.exe"
  [ -f "$CONF_DIR/mode" ] || echo vr > "$CONF_DIR/mode"
  printf '%q %%command%%\n' "$LAUNCHER" > "$STATE/launch-options.txt"
  ok "$LAUNCHER"
}

# ------------------------------------------------------- launch options --
# Steam keeps launch options in memory and writes them back to localconfig.vdf whenever it saves
# or exits, so the file may only be edited while Steam isn't running. On the Steam Frame (and Steam
# Deck) Steam is the device's shell and closing it ends the session, so the installer never closes
# Steam: it edits the file only when Steam is already closed (for example over SSH while Steam is
# shut down), and otherwise prints the line to paste into Steam.
steam_running() { pgrep -x steam >/dev/null 2>&1 || pgrep -x steamwebhelper >/dev/null 2>&1; }

# Best effort: put the launch options line on the desktop clipboard, so it only needs pasting
copy_to_clipboard() {
  if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "$1" | wl-copy 2>/dev/null && return 0
  fi
  if [ -n "${DISPLAY:-}" ] && command -v xclip >/dev/null 2>&1; then
    printf '%s' "$1" | xclip -selection clipboard 2>/dev/null && return 0
  fi
  # KDE Plasma (SteamOS desktop mode)
  local q
  for q in qdbus qdbus6 qdbus-qt5; do
    command -v "$q" >/dev/null 2>&1 || continue
    "$q" org.kde.klipper /klipper setClipboardContents "$1" >/dev/null 2>&1 && return 0
  done
  return 1
}

BOOT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/tf2vr-frame-steamconfig"
UNIT_NAME=tf2vr-frame-launch-options.service
UNIT_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$UNIT_NAME"

# schedule_launch_options <set|clear>: have lib/apply-launch-options.sh make the change at the next
# login, before the Steam session starts, through a systemd user service. Returns 1 if it can't.
schedule_launch_options() {
  command -v systemctl >/dev/null 2>&1 || return 1
  mkdir -p "$BOOT_DIR" "$(dirname "$UNIT_FILE")"
  install -m755 "$HERE/lib/apply-launch-options.sh" "$BOOT_DIR/apply-launch-options.sh"
  install -m644 "$HERE/lib/tf2vr_frame.py" "$BOOT_DIR/tf2vr_frame.py"
  printf '%s\n%s\n%s\n' "$1" "$STEAM" "$LAUNCHER" > "$BOOT_DIR/pending"
  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Titanfall 2 VR: set Steam launch options while Steam is closed
# Steam must not be running while its config is edited. Try at login, before the Steam session
# starts; and at shutdown, after Steam has exited and saved its own config.
Before=gamescope-session.service gamescope-session-plus@steam.service graphical-session-pre.target graphical-session.target plasma-workspace.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$BOOT_DIR/apply-launch-options.sh
ExecStop=$BOOT_DIR/apply-launch-options.sh --after-steam-exits
TimeoutStopSec=150

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user enable "$UNIT_NAME" >/dev/null 2>&1 || { rm -f "$UNIT_FILE" "$BOOT_DIR/pending"; return 1; }
  # Start it now (Steam is running, so this changes nothing yet), so its stop step runs at this
  # shutdown, once Steam has exited
  systemctl --user start "$UNIT_NAME" >/dev/null 2>&1 || true
}

LAUNCH_OPTIONS_SET=0
LAUNCH_OPTIONS_PENDING=0
set_launch_options() {
  echo
  echo "Steam launch options:"
  [ "$LAUNCH_OPTIONS" = 1 ] || { ok "left alone (--no-launch-options)"; return; }
  if steam_running; then
    if helper check-launch-options "$STEAM" "$LAUNCHER" 2>/dev/null; then
      LAUNCH_OPTIONS_SET=1
      rm -f "$BOOT_DIR/pending"
      ok "launch options already set"
      return
    fi
    # Never close Steam: on the Frame it is the device's shell
    if schedule_launch_options set; then
      LAUNCH_OPTIONS_PENDING=1
      ok "Steam is running, so they'll be set automatically the next time the device restarts"
    else
      warn "Steam is running and can't be closed - paste the launch options into Steam (see below)"
    fi
    return
  fi
  local changed
  if changed=$(helper set-launch-options "$STEAM" "$LAUNCHER"); then
    LAUNCH_OPTIONS_SET=1
    rm -f "$BOOT_DIR/pending"
    if [ -n "$changed" ]; then ok "launch options set ($(wc -l <<<"$changed") Steam account(s))"
    else ok "launch options already set"
    fi
  else
    warn "couldn't set the launch options - set them in Steam (see below)"
  fi
}

# Uninstalling while Steam runs: leave a launcher that just starts the game, so Titanfall 2 keeps
# working until the launch options are cleared at the next restart.
PASSTHROUGH='#!/bin/sh
# Titanfall 2 VR was uninstalled: start the game normally until its launch options are cleared.
exec "$@"
'

clear_launch_options() {
  [ -n "$STEAM" ] || return 0
  if ! steam_running; then
    if helper clear-launch-options "$STEAM" "$LAUNCHER" >/dev/null; then
      ok "removed the launcher from Titanfall 2's launch options"
      systemctl --user disable "$UNIT_NAME" >/dev/null 2>&1 || true
      rm -rf "$BOOT_DIR" "$UNIT_FILE"
      return 0
    fi
  elif schedule_launch_options clear; then
    KEEP_PASSTHROUGH=1
    ok "Titanfall 2's launch options will be cleared the next time the device restarts (the game starts normally until then)"
    return 0
  fi
  KEEP_PASSTHROUGH=1
  warn "In Steam, remove '$LAUNCHER %command%' from Titanfall 2 -> Properties -> General -> Launch options (the game starts normally until then)"
}

# --------------------------------------------------------------- finish --
# place <source file> <path relative to the game folder>
# Files are hard-linked from the stage into the game folder rather than copied: a copy needs as
# much free space again as the assets take (about 3 GB). The stage stays whole until the end, so
# an attempt that stops part way can simply be run again. (A game on another drive gets copies.)
place() {
  mkdir -p "$(dirname "$GAME/$2")" \
    && rm -f "$GAME/$2" \
    && { ln "$1" "$GAME/$2" 2>/dev/null || cp -f "$1" "$GAME/$2"; } \
    || die "couldn't put $2 into $GAME. Free space: $(df -h --output=avail "$GAME" 2>/dev/null | tail -n 1 | tr -d ' ')"
  printf '%s\n' "$2" >> "$FILES"
}
place_tree() {
  local f
  while IFS= read -r -d '' f; do
    place "$f" "$2/${f#"$1"/}"
  done < <(find "$1" -type f -print0 | sort -z)
}

finish() {
  echo "Finishing the install:"
  local stage="$STATE/stage" f
  [ -n "$GAME" ] && [ -f "$GAME/Titanfall2.exe" ] || die "no Titanfall 2 folder given"
  [ -f "$stage/version" ] || die "nothing staged - run install.sh again"
  # Anything else that goes wrong below is reported with the command that failed
  trap 'printf "\nERROR: install step failed at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
  helper verify-assets "$stage/mod/patches/manifest.json" "$stage/assets" \
    || { tail -n 20 "$LOG_DIR/asset_patcher.log" 2>/dev/null >&2; die "asset_patcher.exe didn't build the game assets (see $LOG_DIR/asset_patcher.log)"; }
  ok "game assets built and verified"

  # Same layout as Titanfall2Installer.Install(); the vanilla Titanfall2.exe is never touched
  FILES="$stage/files.txt"
  : > "$FILES"
  place "$stage/ns/NorthstarLauncher.exe" Titanfall2VRLauncher.exe
  place_tree "$stage/ns/R2Northstar" TF2VR
  place "$stage/mod/Titanfall2VR.dll" TF2VR/plugins/Titanfall2VR.dll
  place "$stage/mod/xr_probe.exe" TF2VR/tools/xr_probe.exe
  place "$stage/mod/crash_monitor.exe" TF2VR/tools/crash_monitor.exe
  place "$stage/mod/launch.json" TF2VR/tools/launch.json
  place_tree "$stage/mod/mods" TF2VR/mods
  place_tree "$stage/assets" TF2VR
  sort -u "$FILES" -o "$FILES"

  # Files the previous version installed that this one doesn't
  if [ -f "$STATE/files.txt" ]; then
    local stale=0
    while IFS= read -r f; do
      case "$f" in ''|/*|*..*) continue ;; esac
      rm -f "$GAME/$f"
      rmdir -p --ignore-fail-on-non-empty "$(dirname "$GAME/$f")" 2>/dev/null || true
      stale=$((stale + 1))
    done < <(comm -23 "$STATE/files.txt" "$FILES")
    [ "$stale" = 0 ] || ok "removed $stale file(s) the previous version used"
  fi
  cp "$FILES" "$STATE/files.txt"
  printf '%s\n' "$GAME" > "$STATE/game-dir"
  cp "$stage/version" "$STATE/version"
  rm -rf "$stage" "$STATE/setup-pending"
  ok "installed $(wc -l < "$STATE/files.txt") files into $GAME ($(cat "$STATE/version"))"
}

# ----------------------------------------------------------- uninstall --
uninstall() {
  echo
  echo "Uninstalling:"
  local game f n=0
  game=$(cat "$STATE/game-dir" 2>/dev/null || printf '%s' "$GAME")
  if [ -f "$STATE/files.txt" ] && [ -n "$game" ]; then
    while IFS= read -r f; do
      case "$f" in ''|/*|*..*) continue ;; esac
      rm -f "$game/$f"
      rmdir -p --ignore-fail-on-non-empty "$(dirname "$game/$f")" 2>/dev/null || true
      n=$((n + 1))
    done < "$STATE/files.txt"
    ok "removed $n mod files from $game"
  fi
  KEEP_PASSTHROUGH=0
  clear_launch_options
  rm -rf "$STATE" "$CONF_DIR"
  if [ "$KEEP_PASSTHROUGH" = 1 ]; then
    mkdir -p "$STATE"
    printf '%s' "$PASSTHROUGH" > "$LAUNCHER"
    chmod 755 "$LAUNCHER"
  fi
  ok "removed the launch wrapper"
  echo "  Kept: campaign saves (in the Wine prefix), the VC++ runtime in the prefix, and Northstar logs under $game/TF2VR"
}

# ---------------------------------------------------------------- main --
diagnose() {
  set +e
  local cfg
  echo "== tf2vr-frame diagnostics $(date '+%F %T')"
  echo "arch: $(uname -m)  os: $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null)"
  echo "free space: home $(df -h --output=avail "$HOME" 2>/dev/null | tail -n 1 | tr -d ' ')   game folder $(df -h --output=avail "${GAME:-$HOME}" 2>/dev/null | tail -n 1 | tr -d ' ')"
  echo "steam root: ${STEAM:-not found}   game: ${GAME:-not found}"
  echo "steam processes:"; pgrep -a -x steam 2>/dev/null | cut -c1-200; pgrep -c steamwebhelper 2>/dev/null | sed 's/^/  steamwebhelper count: /'
  echo "localconfig.vdf files and Titanfall 2 launch options:"
  for cfg in "${STEAM:-/nonexistent}"/userdata/*/config/localconfig.vdf; do
    [ -f "$cfg" ] || continue
    echo "  $cfg ($(stat -c '%s bytes, modified %y' "$cfg"))"
    python3 - "$cfg" <<'PY2'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
for m in re.finditer(r'"1237970"\s*\{', text):
    depth, i = 1, m.end()
    while depth and i < len(text):
        depth += {"{": 1, "}": -1}.get(text[i], 0)
        i += 1
    block = text[m.start():i]
    lo = re.search(r'"LaunchOptions"\s*"((?:[^"\\]|\\.)*)"', block)
    print(f"    app block at offset {m.start()}: LaunchOptions = {lo.group(1) if lo else '(none)'}")
PY2
  done
  echo "pending change: $( { cat "$BOOT_DIR/pending" 2>/dev/null || echo none; } | tr '\n' ' ')"
  echo "service:"; systemctl --user status "$UNIT_NAME" --no-pager 2>&1 | head -n 12
  echo "user services that look like the Steam session:"
  systemctl --user list-units --all --no-pager --plain 2>/dev/null | grep -iE 'steam|gamescope|session' | cut -c1-120
  echo "launch-options.log:"; tail -n 20 "$LOG_DIR/launch-options.log" 2>/dev/null || echo "  (none)"
  echo "journal for the service (this boot):"
  journalctl --user -b -u "$UNIT_NAME" --no-pager 2>/dev/null | tail -n 20

  echo
  echo "== launching"
  echo "mode file: $(cat "$CONF_DIR/mode" 2>/dev/null || echo none)   setup pending: $([ -f "$STATE/setup-pending" ] && echo yes || echo no)"
  echo "launcher: $(ls -l "$LAUNCHER" 2>&1)"
  echo "installed mod version: $(cat "$STATE/stage/version" 2>/dev/null || echo unknown)"
  echo "prefix: ${PREFIX:-not found}"
  if [ -n "${GAME:-}" ]; then
    echo "mod files in the game folder:"
    local f
    for f in Titanfall2VRLauncher.exe TF2VR/Northstar.dll TF2VR/plugins/Titanfall2VR.dll \
             TF2VR/tools/crash_monitor.exe TF2VR/tools/launch.json; do
      echo "  $f: $(stat -c '%s bytes, %y' "$GAME/$f" 2>/dev/null || echo MISSING)"
    done
    for f in "$GAME"/{,bin/x64_retail/}{dxgi,d3d11}.dll; do [ -f "$f" ] && echo "  extra DirectX file: $f"; done
    echo "launch.json:"; head -c 1500 "$GAME/TF2VR/tools/launch.json" 2>/dev/null; echo
  fi
  if [ -f "$LOG_DIR/launch.log" ]; then
    # The game's own output goes to the same log; the launcher's lines start with [HH:MM:SS]
    echo "launch.log (last 60 lines):"; grep -vE 'LD_PRELOAD cannot be preloaded' "$LOG_DIR/launch.log" | tail -n 60 | cut -c1-2000
    echo "output.log, Steam/Proton/game output (last 40 lines, without the overlay noise):"
    grep -vE 'LD_PRELOAD cannot be preloaded|^ATTENTION: default value' "$LOG_DIR/output.log" 2>/dev/null | tail -n 40 | cut -c1-500
  else
    echo "launch.log: (none - Steam never ran the launcher)"
  fi
  echo "asset_patcher.log (last 15 lines):"; tail -n 15 "$LOG_DIR/asset_patcher.log" 2>/dev/null || echo "  (none)"
  if [ -n "${GAME:-}" ]; then
    local newest
    echo "engine.txt (last 60 lines):"
    tail -n 60 "$GAME/TF2VR/plugins/Titanfall2VR-data/engine.txt" 2>/dev/null || echo "  (none)"
    newest=$(ls -1t "$GAME"/TF2VR/logs/nslog*.txt 2>/dev/null | head -n 1)
    echo "newest Northstar log: ${newest:-(none)}"
    [ -n "$newest" ] && tail -n 60 "$newest"
    newest=$(ls -1td "$GAME"/TF2VR/crashes/*/ 2>/dev/null | head -n 1)
    echo "newest crash folder: ${newest:-(none)}"
    [ -n "$newest" ] && tail -n 20 "$newest/monitor.txt" 2>/dev/null
  fi
  echo "VR environment Steam gave the game (last launch):"
  grep 'VR environment:' "$LOG_DIR/launch.log" 2>/dev/null | tail -n 1
}

if [ "$MODE" = diagnose ]; then
  discover
  diagnose 2>&1 | tee "$HOME/tf2vr-frame-diagnostics.txt"
  echo
  echo "Saved to $HOME/tf2vr-frame-diagnostics.txt"
  exit 0
fi

if [ "$MODE" = finish ]; then
  GAME=$OPT_GAME
  finish
  exit 0
fi

discover
preflight

# Changing the install while Steam is starting the game (or building its assets on the first
# launch) pulls files out from under it
game_running() {
  pgrep -f '[\\/](Titanfall2|Titanfall2VRLauncher|EADesktop|asset_patcher|setup_progress)\.exe|tf2vr-frame-launch --inner' >/dev/null
}

case "$MODE" in
  check) ;;
  uninstall)
    game_running && die "Titanfall 2 is running or still setting up - quit it in Steam first (Steam button -> Exit game), then run this again"
    uninstall ;;
  install)
    [ "$fails" = 0 ] || die "fix the failed checks above first"
    game_running && die "Titanfall 2 is running or still setting up - quit it in Steam first (Steam button -> Exit game), then run this again"
    ensure_vcredist
    install_launcher
    if stage_mod; then
      touch "$STATE/setup-pending"
      ok "the first VR launch from Steam builds the game assets and finishes the install"
    fi
    set_launch_options
    ;;
esac

echo
if [ "$fails" -gt 0 ]; then
  echo "Done with $fails failure(s) and $warns warning(s)."
  exit 1
fi
echo "Done ($warns warning(s))."
if [ "$MODE" = install ]; then
  echo
  if [ "$LAUNCH_OPTIONS_SET" = 1 ]; then
    echo "All set. Put your headset on and press Play on Titanfall 2 in Steam."
  elif [ "$LAUNCH_OPTIONS_PENDING" = 1 ]; then
    cat <<EOF
Last step: restart the device. Titanfall 2's launch options are put in during the restart, while
Steam is closed (Steam rewrites its settings while it runs, so they can't be set before that).
After the restart, put your headset on and press Play on Titanfall 2.

EOF
  else
    line=$(cat "$STATE/launch-options.txt")
    copied=""
    copy_to_clipboard "$line" && copied=" (already copied to the clipboard: just paste it)"
    echo "Last step, in Steam: Titanfall 2 -> gear icon -> Properties -> General -> Launch options."
    echo "Set it to exactly this$copied:"
    echo
    echo "    $line"
    echo
    echo "It's also saved in $STATE/launch-options.txt. Then press Play."
  fi
  cat <<EOF
The first launch builds the mod's game assets before the game appears, which takes a few minutes.
For the normal game without VR: echo flat > $CONF_DIR/mode    (echo vr > ... to switch back)
Logs: $LOG_DIR/launch.log (Steam, Proton and game output: $LOG_DIR/output.log)
EOF
fi

if [ "$MODE" = install ] && [ "$LAUNCH_OPTIONS_PENDING" = 1 ]; then
  echo
  answer=n
  if [ "$RESTART" = 1 ]; then
    answer=y
  elif { : < /dev/tty; } 2>/dev/null; then
    printf 'Restart now? [Y/n] '
    read -r answer < /dev/tty || answer=n
    answer=${answer:-y}
  fi
  case "$answer" in
    [Yy]*)
      echo "Restarting..."
      sync
      systemctl reboot 2>/dev/null || loginctl reboot 2>/dev/null \
        || echo "Couldn't restart from here: use Steam menu -> Power -> Restart."
      ;;
    *) echo "Restart whenever you're ready: Steam menu -> Power -> Restart." ;;
  esac
fi
