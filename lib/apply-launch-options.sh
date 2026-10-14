#!/usr/bin/env bash
# Writes Titanfall 2's Steam launch options at a moment Steam isn't running.
#
# Steam keeps launch options in memory and writes them back to localconfig.vdf when it saves or
# exits, so they can only be edited while Steam is closed. On the Steam Frame, Steam is the
# device's shell and can't be closed from a terminal, so install.sh leaves the change pending here
# and enables tf2vr-frame-launch-options.service, a systemd user service that runs this at login,
# before the Steam session starts. The next restart of the device applies it.
#
#   apply-launch-options.sh                      apply the pending change, if Steam isn't running
#   apply-launch-options.sh --after-steam-exits  at shutdown: wait for Steam to exit, then apply
#
# Login alone isn't enough: on some devices Steam's session starts before systemd user services,
# so the service also runs at shutdown (ExecStop), after Steam has saved and exited.
#
# The pending file holds three lines: set|clear, the Steam folder, the launcher path.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PENDING="$HERE/pending"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tf2vr-frame"
UNIT=tf2vr-frame-launch-options.service

mkdir -p "$LOG_DIR"
exec >> "$LOG_DIR/launch-options.log" 2>&1
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

[ -f "$PENDING" ] || exit 0
{ read -r action; read -r steam; read -r launcher; } < "$PENDING"

steam_running() { pgrep -x steam >/dev/null 2>&1 || pgrep -x steamwebhelper >/dev/null 2>&1; }

when=login
if [ "${1:-}" = --after-steam-exits ]; then
  when=shutdown
  for _ in $(seq 1 120); do steam_running || break; sleep 1; done
fi
if steam_running; then
  log "$when: Steam is running ($(pgrep -a -x steam | head -n 1)); leaving '$action' for later"
  exit 0
fi
# Steam may still be finishing its last write of localconfig.vdf
[ "$when" = shutdown ] && sleep 2

case "$action" in
  set)   cmd=set-launch-options ;;
  clear) cmd=clear-launch-options ;;
  *)     log "unknown pending action '$action'"; exit 1 ;;
esac

if changed=$(python3 "$HERE/tf2vr_frame.py" "$cmd" "$steam" "$launcher"); then
  log "$when: $action launch options: ${changed:-already done}"
  rm -f "$PENDING"
else
  log "$action launch options failed"
  exit 1
fi

if [ "$action" = clear ]; then
  # Uninstalled: the launcher was only kept so the game still started until now
  rm -f "$launcher"
  rmdir "$(dirname "$launcher")" 2>/dev/null
  systemctl --user disable "$UNIT" >/dev/null 2>&1
  rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$UNIT"
  rm -rf "$HERE"
fi
exit 0
