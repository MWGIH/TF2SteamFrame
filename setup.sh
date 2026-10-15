#!/usr/bin/env bash
# One-command install of Titanfall 2 VR on the Steam Frame. Paste into Konsole (desktop mode):
#
#   curl -fsSL https://raw.githubusercontent.com/MWGIH/TF2SteamFrame/main/setup.sh | bash
#
# Downloads (or updates) this repo in ~/TF2SteamFrame, then runs install.sh, which installs the mod
# and sets Titanfall 2's launch options at the next restart. Run the same command again to update.
# Options for install.sh go after `bash -s --`, e.g.  ... | bash -s -- --beta
set -euo pipefail

REPO=${TF2SF_REPO:-https://github.com/MWGIH/TF2SteamFrame}
BRANCH=${TF2SF_BRANCH:-main}
DIR=${TF2SF_DIR:-$HOME/TF2SteamFrame}

echo "Titanfall 2 VR for the Steam Frame and Steam Machine"
echo "Getting the installer into $DIR..."
if command -v git >/dev/null 2>&1; then
  if [ -d "$DIR/.git" ]; then
    git -C "$DIR" fetch -q origin "$BRANCH"
    git -C "$DIR" checkout -q "$BRANCH"
    git -C "$DIR" merge -q --ff-only "origin/$BRANCH"
  elif [ -e "$DIR" ] && [ ! -f "$DIR/install.sh" ]; then
    echo "ERROR: $DIR already exists and isn't this installer. Move it away, or set TF2SF_DIR=/another/folder." >&2
    exit 1
  else
    rm -rf "$DIR"
    git clone -q --branch "$BRANCH" "$REPO" "$DIR"
  fi
else
  if [ -e "$DIR" ] && [ ! -f "$DIR/install.sh" ]; then
    echo "ERROR: $DIR already exists and isn't this installer. Move it away, or set TF2SF_DIR=/another/folder." >&2
    exit 1
  fi
  tmp=$(mktemp -d)
  curl -fsSL "$REPO/archive/refs/heads/$BRANCH.tar.gz" | tar -xz -C "$tmp" --strip-components=1
  rm -rf "$DIR"
  mv "$tmp" "$DIR"
fi

cd "$DIR"
echo
# When piped from curl, the installer's questions are answered from the terminal, not the pipe
if { : < /dev/tty; } 2>/dev/null; then
  exec ./install.sh "$@" < /dev/tty
fi
exec ./install.sh "$@"
