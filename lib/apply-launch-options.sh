#!/usr/bin/env bash
# Writes Titanfall 2's Steam launch options at a moment Steam isn't running.
#
# Steam keeps launch options in memory and writes them back to localconfig.vdf when it saves or
# exits, so they can only be edited while Steam is closed. On the Steam Frame, Steam is the
# device's shell and can't be closed from a terminal, so install.sh leaves the change pending here
# and enables tf2vr-frame-launch-options.service, a systemd user service that runs this at login,
# before the Steam session starts. The next restart of the device applies it.
#
#   apply-launch-options.sh            apply the pending change, if Steam isn't running
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

if pgrep -x steam >/dev/null 2>&1; then
  log "Steam is already running; leaving '$action' for the next restart"
  exit 0
fi

case "$action" in
  set)   cmd=set-launch-options ;;
  clear) cmd=clear-launch-options ;;
  *)     log "unknown pending action '$action'"; exit 1 ;;
esac

if changed=$(python3 "$HERE/tf2vr_frame.py" "$cmd" "$steam" "$launcher"); then
  log "$action launch options: ${changed:-already done}"
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
