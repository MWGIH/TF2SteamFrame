#!/usr/bin/env bash
# Titanfall 2 VR (CircuitLord's TF2VR mod) played directly on a Steam Frame.
#
#   ./install.sh               install or update the mod and the Steam launch wrapper
#   ./install.sh --check       preflight checks only, change nothing
#   ./install.sh --force       reinstall the mod even if it is already up to date
#   ./install.sh --beta        use the mod's beta channel instead of the stable release
#   ./install.sh --uninstall   remove the mod files and the wrapper (campaign saves are kept)
#   ./install.sh --game DIR    the folder with Titanfall2.exe, if it isn't found automatically
#   ./install.sh --yes         close and reopen Steam without asking, to set the launch options
#   ./install.sh --no-launch-options   don't touch Steam's launch options; set them by hand
#
# At the end it sets Titanfall 2's Steam launch options to start the VR launcher. Steam only
# reads them at start and rewrites them on exit, so if Steam is running it asks to close Steam for
# a moment, and starts it again afterwards.
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
YES=0
LAUNCH_OPTIONS=1
while [ $# -gt 0 ]; do
  case "$1" in
    --check)     MODE=check ;;
    --uninstall) MODE=uninstall ;;
    --finish)    MODE=finish ;;
    --force)     FORCE=1 ;;
    --beta)      CHANNEL=beta ;;
    --yes|-y)    YES=1 ;;
    --no-launch-options) LAUNCH_OPTIONS=0 ;;
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
  if [ "$FORCE" = 0 ] && [ -f "$STATE/setup-pending" ] && [ "$(cat "$STATE/stage/version" 2>/dev/null)" = "$WANTED" ]; then
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
  printf '%s\n' "$WANTED" > "$stage/version"
  return 0
}

install_launcher() {
  echo
  echo "Steam launch wrapper:"
  mkdir -p "$STATE/lib" "$CONF_DIR" "$LOG_DIR"
  install -m755 "$HERE/tf2vr-frame-launch" "$LAUNCHER"
  install -m755 "$HERE/install.sh" "$STATE/install.sh"
  install -m644 "$HERE/lib/tf2vr_frame.py" "$STATE/lib/tf2vr_frame.py"
  [ -f "$CONF_DIR/mode" ] || echo vr > "$CONF_DIR/mode"
  printf '%q %%command%%\n' "$LAUNCHER" > "$STATE/launch-options.txt"
  ok "$LAUNCHER"
}

# ------------------------------------------------------- launch options --
steam_running() { pgrep -x steam >/dev/null 2>&1; }

# with_steam_closed <what for> <command...>: run a command that edits Steam's config while Steam
# is closed. Asks first, closes Steam, runs it, and starts Steam again. Returns 1 if not done.
with_steam_closed() {
  local why=$1 answer restart=0
  shift
  if steam_running; then
    if [ "$YES" = 0 ]; then
      if ! { : < /dev/tty; } 2>/dev/null; then
        warn "Steam is running, so it can't be closed to $why without asking (run again with --yes)"
        return 1
      fi
      printf '  Steam has to close for a moment to %s. Close Steam now? [Y/n] ' "$why"
      read -r answer < /dev/tty || answer=n
      case "$answer" in ''|[Yy]*) ;; *) return 1 ;; esac
    fi
    echo "  closing Steam..."
    steam -shutdown >/dev/null 2>&1 &
    for _ in $(seq 1 60); do steam_running || break; sleep 1; done
    if steam_running; then
      warn "Steam didn't close"
      return 1
    fi
    restart=1
  fi
  local rc=0
  "$@" || rc=$?
  if [ "$restart" = 1 ]; then
    echo "  starting Steam again..."
    setsid steam >/dev/null 2>&1 < /dev/null &
  fi
  return $rc
}

write_launch_options() {
  local changed
  changed=$(helper set-launch-options "$STEAM" "$LAUNCHER") || return 1
  if [ -n "$changed" ]; then ok "launch options set ($(wc -l <<<"$changed") Steam account(s))"
  else ok "launch options already set"
  fi
}

LAUNCH_OPTIONS_SET=0
set_launch_options() {
  echo
  echo "Steam launch options:"
  [ "$LAUNCH_OPTIONS" = 1 ] || { ok "left alone (--no-launch-options)"; return; }
  if with_steam_closed "set Titanfall 2's launch options" write_launch_options; then
    LAUNCH_OPTIONS_SET=1
  else
    warn "launch options not set - set them by hand (see below)"
  fi
}

clear_launch_options() {
  [ -n "$STEAM" ] || return 0
  if with_steam_closed "remove Titanfall 2's launch options" helper clear-launch-options "$STEAM" "$LAUNCHER" >/dev/null; then
    ok "removed the launcher from Titanfall 2's launch options"
  else
    warn "Remove '$LAUNCHER %command%' from Titanfall 2's launch options in Steam (Properties -> General), or it won't start"
  fi
}

# --------------------------------------------------------------- finish --
# place <source file> <path relative to the game folder>
place() {
  mkdir -p "$(dirname "$GAME/$2")"
  cp -f "$1" "$GAME/$2"
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
  clear_launch_options
  rm -rf "$STATE" "$CONF_DIR"
  ok "removed the launch wrapper"
  echo "  Kept: campaign saves (in the Wine prefix), the VC++ runtime in the prefix, and Northstar logs under $game/TF2VR"
}

# ---------------------------------------------------------------- main --
if [ "$MODE" = finish ]; then
  GAME=$OPT_GAME
  finish
  exit 0
fi

discover
preflight

case "$MODE" in
  check) ;;
  uninstall) uninstall ;;
  install)
    [ "$fails" = 0 ] || die "fix the failed checks above first"
    if pgrep -f '[\\/](Titanfall2|Titanfall2VRLauncher|EADesktop)\.exe' >/dev/null; then
      die "Titanfall 2 or the EA app is running - close them first"
    fi
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
  else
    echo "Last step, in Steam: Titanfall 2 -> Properties -> General -> Launch options, set exactly:"
    echo
    echo "    $(cat "$STATE/launch-options.txt")"
    echo
    echo "(also saved in $STATE/launch-options.txt to copy from). Then press Play."
  fi
  cat <<EOF
The first launch builds the mod's game assets before the game appears, which takes a few minutes.
For the normal game without VR: echo flat > $CONF_DIR/mode    (echo vr > ... to switch back)
Logs: $LOG_DIR/launch.log
EOF
fi
