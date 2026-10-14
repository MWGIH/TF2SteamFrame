#!/usr/bin/env bash
# End-to-end test of tf2vr-frame-launch against a fake Steam command line and a fake Proton.
# Nothing Windows runs: the fake proton records what it was asked to run and imitates the
# processes the launcher watches (EADesktop.exe, crash_monitor.exe, asset_patcher.exe).
#   bash tests/test_launch.sh
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'pkill -f "$T/" 2>/dev/null; pkill -f "^C:.Program Files.Electronic Arts" 2>/dev/null; rm -rf "$T"' EXIT

export HOME="$T/home" XDG_DATA_HOME="" XDG_CONFIG_HOME="" XDG_STATE_HOME="" XDG_CACHE_HOME=""
unset XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME
STATE="$HOME/.local/share/tf2vr-frame"
LOG="$HOME/.local/state/tf2vr-frame/launch.log"
CALLS="$T/proton-calls"
GAME="$T/sdcard/steamapps/common/Titanfall2"
COMPAT="$T/home/.local/share/Steam/steamapps/compatdata/1237970"
PROTON_DIR="$T/steam/steamapps/common/Proton - Experimental"
mkdir -p "$GAME" "$COMPAT/pfx/drive_c/windows/system32" "$PROTON_DIR/files/bin" "$STATE/lib" "$T/bin"
touch "$GAME/Titanfall2.exe"

pass=0
ok()   { echo "ok   $1"; pass=$((pass + 1)); }
fail() { echo "FAIL $1"; echo "--- launch.log:"; cat "$LOG" 2>/dev/null; echo "--- proton calls:"; cat "$CALLS" 2>/dev/null; exit 1; }

# --- fake Steam pieces ------------------------------------------------------------------------
# reaper and the container entry point just run what follows their "--"
cat > "$T/bin/reaper" <<'EOF'
#!/usr/bin/env bash
while [ "$1" != -- ]; do shift; done; shift; exec "$@"
EOF
cp "$T/bin/reaper" "$T/bin/_v2-entry-point"

cat > "$PROTON_DIR/proton" <<EOF
#!/usr/bin/env bash
# fake Proton: log the call, then imitate the program
printf '%s' "\$1" >> "$CALLS"; shift
printf ' |%s' "\$@" >> "$CALLS"; printf ' ContentId=%s TF2VR_OPENXR=%s\n' "\${ContentId:-}" "\${TF2VR_OPENXR:-}" >> "$CALLS"
case "\$1" in
  *EADesktop.exe)
    mkdir -p "\$STEAM_COMPAT_DATA_PATH/pfx/drive_c/ProgramData/EA Desktop/Logs"
    ( sleep 1; echo "onAuthSuccessUpdated" >> "\$STEAM_COMPAT_DATA_PATH/pfx/drive_c/ProgramData/EA Desktop/Logs/EADesktop.log" ) &
    exec -a 'C:\\Program Files\\Electronic Arts\\EA Desktop\\EA Desktop\\EADesktop.exe' sleep 30 ;;
  *setup_progress.exe)
    # As on the Steam Frame, \`proton run\` returns at once while the program keeps running: the
    # build finishes a few seconds later and the log's last line says so. A Wine process then
    # lingers, as one that would keep \`proton run\` waiting elsewhere.
    out=\$(printf '%s' "\$7" | sed 's/^Z://; s|\\\\|/|g')
    plog=\$(printf '%s' "\$2" | sed 's/^Z://; s|\\\\|/|g')
    (
      ( exec -a 'Z:\\stage\\setup_progress.exe' sleep 4 )
      mkdir -p "\$out/mods/x"; printf 'built' > "\$out/mods/x/file.txt"
      printf 'asset_patcher exit code 0\r\n' > "\$plog"
      exec sleep 30
    ) >/dev/null 2>&1 &
    ;;
  *crash_monitor.exe)
    g=\$(dirname "\$1"); g=\$(dirname "\$(dirname "\$g")")
    mkdir -p "\$g/TF2VR/crashes/s1"; echo "process_exit pid=1 code=0" > "\$g/TF2VR/crashes/s1/monitor.txt"
    exec -a 'Z:\\game\\TF2VR\\tools\\crash_monitor.exe' sleep 2 ;;
  *Titanfall2.exe) echo "flat game ran" >> "$CALLS" ;;
esac
EOF
cat > "$PROTON_DIR/files/bin/wineserver" <<EOF
#!/usr/bin/env bash
echo "wineserver \$*" >> "$CALLS"
pkill -f 'sleep 30' 2>/dev/null || true
EOF
chmod +x "$T/bin/"* "$PROTON_DIR/proton" "$PROTON_DIR/files/bin/wineserver"

export STEAM_COMPAT_DATA_PATH="$COMPAT" SteamGameId=1237970
steam_cmd=("$T/bin/reaper" SteamLaunch AppId=1237970 -- "$T/bin/_v2-entry-point" --verb=waitforexitandrun --
           "$PROTON_DIR/proton" waitforexitandrun "$GAME/Titanfall2.exe")

# --- install what install.sh would have staged --------------------------------------------------
install -m755 "$REPO/tf2vr-frame-launch" "$STATE/tf2vr-frame-launch"
install -m755 "$REPO/install.sh" "$STATE/install.sh"
install -m644 "$REPO/lib/tf2vr_frame.py" "$STATE/lib/tf2vr_frame.py"
install -m644 "$REPO/lib/setup_progress.exe" "$STATE/lib/setup_progress.exe"
S="$STATE/stage"
mkdir -p "$S/mod/patches" "$S/mod/mods/Titanfall2VR.Cockpit" "$S/ns/R2Northstar/plugins"
for f in asset_patcher.exe xr_probe.exe crash_monitor.exe Titanfall2VR.dll; do echo "$f" > "$S/mod/$f"; done
echo '{"arguments": ["-profile={profile}", "-w", "{width}"], "vrArguments": ["+fps_max", "0"]}' > "$S/mod/launch.json"
echo mod > "$S/mod/mods/Titanfall2VR.Cockpit/mod.json"
echo ns > "$S/ns/NorthstarLauncher.exe"; echo dll > "$S/ns/R2Northstar/Northstar.dll"
printf '{"outputs": {"mods/x/file.txt": "%s"}}' "$(printf built | sha256sum | cut -d' ' -f1)" > "$S/mod/patches/manifest.json"
echo "mod=1.0.17 northstar=1.31.13" > "$S/version"
touch "$STATE/setup-pending"
L="$STATE/tf2vr-frame-launch"

# --- 1. flat mode leaves Steam's command alone ----------------------------------------------------
"$L" "${steam_cmd[@]}" -flat
grep -q "flat game ran" "$CALLS" || fail "flat mode runs Titanfall2.exe"
grep -q -- "-flat" "$CALLS" && fail "-flat is not passed to the game"
ok "-flat starts the normal game, without the -flat switch"
: > "$CALLS"

# --- 2. first VR launch: setup job, finish, then VR ---------------------------------------------
start=$SECONDS
"$L" "${steam_cmd[@]}" +map sp_crashsite || fail "first launch exits 0"
[ $((SECONDS - start)) -lt 25 ] || fail "setup doesn't wait for a Wine session that stays up after the build"
grep -q '^run |.*setup_progress.exe |Z:.*asset_patcher.log |Z:.*asset_patcher.exe |apply |Z:.*Titanfall2' "$CALLS" || fail "asset_patcher.exe runs through Steam's proton, under the progress window, with the game folder"
[ ! -e "$STATE/setup-pending" ] || fail "setup-pending is cleared"
[ -f "$GAME/TF2VR/mods/x/file.txt" ] && [ -f "$GAME/Titanfall2VRLauncher.exe" ] && [ -f "$GAME/TF2VR/plugins/Titanfall2VR.dll" ] \
  || fail "finish places the mod in the game folder"
ok "first launch builds the assets inside Steam's runtime and installs the mod"
grep -q '^run |C:\\Program Files\\Electronic Arts\\EA Desktop\\EA Desktop\\EADesktop.exe' "$CALLS" || fail "EA app started"
line=$(grep 'crash_monitor.exe' "$CALLS") || fail "crash_monitor.exe started"
case "$line" in
  "run |$GAME/TF2VR/tools/crash_monitor.exe |Z:"*"\\TF2VR |Z:"*"\\Titanfall2VRLauncher.exe |-profile=TF2VR |-w |1280 |+fps_max |0 |+map |sp_crashsite ContentId=Origin.OFR.50.0001456 TF2VR_OPENXR=1") ;;
  *) fail "crash_monitor.exe arguments: $line" ;;
esac
ok "VR launch: EA app, then crash_monitor.exe -> Titanfall2VRLauncher.exe with launch.json args and Steam's extra args"
grep -q '^wineserver -k' "$CALLS" || fail "session ended after the game"
ok "Wine session is ended after the game exits"
grep -q "Titanfall2.exe" <(grep -v "flat game" "$CALLS" | grep -v asset_patcher | grep -v crash_monitor) && fail "Titanfall2.exe itself is never run in VR mode"
: > "$CALLS"

# --- 3. later launches skip setup -------------------------------------------------------------
"$L" "${steam_cmd[@]}" || fail "second launch exits 0"
grep -q asset_patcher "$CALLS" && fail "setup runs only once"
grep -q crash_monitor "$CALLS" || fail "second launch starts VR"
ok "later launches go straight to VR"
: > "$CALLS"

# --- 4. mode file ------------------------------------------------------------------------------
mkdir -p "$HOME/.config/tf2vr-frame"
echo flat > "$HOME/.config/tf2vr-frame/mode"
"$L" "${steam_cmd[@]}"
grep -q "flat game ran" "$CALLS" || fail "mode file switches to flat"
ok "the mode file set to flat starts the normal game"
rm "$HOME/.config/tf2vr-frame/mode"
: > "$CALLS"

# --- 5. Steam starting the game through the EA app link (as on the Steam Frame) ------------------
url='steam2ea://launchgame/1237970?platform=steam&theme=tf2'
link_cmd=("${steam_cmd[@]:0:${#steam_cmd[@]}-1}" "$url")
STEAM_COMPAT_INSTALL_PATH="$GAME" "$L" "${link_cmd[@]}" || fail "EA-link launch exits 0"
grep -q crash_monitor "$CALLS" || fail "EA-link launch starts VR"
grep -q steam2ea "$CALLS" && fail "the EA link is not run in VR mode"
ok "a steam2ea:// launch goes to VR, using the game folder from Proton's environment"
: > "$CALLS"
STEAM_COMPAT_INSTALL_PATH="$GAME" "$L" "${link_cmd[@]}" -flat
grep -q "|steam2ea://" "$CALLS" || fail "flat EA-link launch runs the link unchanged"
grep -q -- "-flat" "$CALLS" && fail "-flat is not passed on an EA-link launch"
ok "-flat on a steam2ea:// launch runs Steam's command unchanged"
: > "$CALLS"

# --- 6. a command line without proton is passed through untouched ------------------------------
"$L" /bin/true something-else || fail "unknown command lines run unchanged"
grep -q "nor the EA app link is in Steam's command line" "$LOG" || fail "unknown command line is logged"
ok "a command line without Titanfall2.exe runs unchanged"

echo "$pass checks passed"
