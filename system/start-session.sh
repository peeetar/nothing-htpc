#!/usr/bin/env bash
# Runs inside the cage Wayland session. Everything started here
# inherits WAYLAND_DISPLAY, so launched apps render fullscreen.
set -u

HTPC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# HTPC_DEBUG=1 (dev-session.sh sets it) tags every background process's output
# with its name and turns on Chromium's stderr log, so one terminal shows the
# whole session. It costs a `read` loop per daemon, which is why it is off on
# the Pi by default: under systemd, journald already tags by unit and the box
# has 1GB to spend on stream buffers, not on four idle bash loops.
DEBUG="${HTPC_DEBUG:-}"
[ "$DEBUG" = "0" ] && DEBUG=""

# tag NAME CMD... — run in the background, prefixing each output line.
tag() {
  local name="$1"; shift
  if [ -n "$DEBUG" ]; then
    "$@" 2>&1 | while IFS= read -r line; do printf '%s | %s\n' "$name" "$line"; done &
  else
    "$@" &
  fi
}

# python -u: without it, a piped stdout is block-buffered and log lines arrive
# in 8K clumps long after the thing they describe.
PY=(python3 -u)

# --- the video layer --------------------------------------------------------
#
# mpv starts FIRST and stays running for the whole session, idle when nothing
# is on. Two reasons it is not launched per-channel any more:
#
#   1. cage raises the newest window, so the UI has to be the newest window.
#      mpv first, Chromium second, and the page composites on top.
#   2. Starting a player per channel is what put a black frame between the
#      menu and the picture. Idle mpv has nothing to start.
#
# It draws no UI of its own — no OSC, no OSD, no default keybindings. Every
# pixel of interface is the page above it. shim.lua handles only the things
# that are awkward to see from the other side of an IPC socket: a stream that
# fails, and a retry.
export MPV_IPC_SOCKET="${MPV_IPC_SOCKET:-${XDG_RUNTIME_DIR:-/tmp}/htpc-mpv.sock}"
rm -f "$MPV_IPC_SOCKET"

MPV_ARGS=(
  --idle=yes
  --input-ipc-server="$MPV_IPC_SOCKET"
  --fullscreen
  --no-osc --no-osd-bar --osd-level=0
  --no-input-default-bindings
  --input-vo-keyboard=no
  --keep-open=no
  --force-window=yes
  --background-color='#000000'
  --script="$HTPC_DIR/cabletv/shim.lua"
  # A 1GB box cannot buffer like a desktop. These are the numbers the old
  # cabletv.sh arrived at and they are still the right ones.
  --cache=yes
  --demuxer-max-bytes=32MiB
  --demuxer-max-back-bytes=16MiB
  --hwdec=auto-safe
)

if command -v mpv >/dev/null; then
  tag mpv mpv "${MPV_ARGS[@]}"
else
  echo "session | mpv is not installed — TV and MOVIES will not play" >&2
fi

# Backend (launches/kills apps, and bridges the page to mpv's IPC socket)
tag server "${PY[@]}" "$HTPC_DIR/server/server.py"

# Home-button daemon (hold guide button -> return to launcher)
tag homebtn "${PY[@]}" "$HTPC_DIR/daemon/homebutton.py"

# HDMI-CEC: TV remote -> key events, TV standby -> back to launcher.
# Exits quietly on hardware with no CEC line, so this is safe everywhere.
tag cecd "${PY[@]}" "$HTPC_DIR/daemon/cecd.py"

# Spotify Connect endpoint (phone is the remote) — optional
if command -v spotifyd >/dev/null; then
  tag spotifyd spotifyd --no-daemon
elif [ -n "$DEBUG" ]; then
  echo "session | spotifyd not installed — MUSIC will show nothing playing"
fi

sleep 1

# Kiosk browser = the launcher UI. When this exits, the session ends.
#
# The memory flags are not superstition on a 1GB Pi 3B+: the launcher is one
# static page, but Chromium will still reserve a few hundred MB it never
# needs, and that is memory mpv wants for stream buffers. One renderer, no
# background machinery, small JS heap — the page is a clock and six tiles.
CHROME_ARGS=(
  --kiosk "http://127.0.0.1:8484"
  --noerrdialogs
  --disable-session-crashed-bubble
  --disable-features=TranslateUI
  --autoplay-policy=no-user-gesture-required
  --ozone-platform=wayland
  --process-per-site
  --renderer-process-limit=1
  --disable-dev-shm-usage
  --disable-extensions
  --disable-sync
  --disable-background-networking
  --disable-component-update
  --js-flags="--max-old-space-size=64"
  # Transparency. The page is composited over mpv, so where the UI paints
  # nothing the video has to show through. This is the load-bearing and
  # least-proven part of the whole architecture (see REMODEL.md): Chromium
  # normally composites onto an opaque surface, and whether it will hand
  # Wayland an ARGB one is a per-platform question.
  #
  # If the picture never appears and the UI sits on black, this is why. The
  # documented fallback is to stop asking for transparency and give mpv a
  # geometry the page reserves instead — the UI code is identical either way,
  # which is what makes being wrong here cheap.
  --enable-transparent-visuals
  --default-background-color=00000000
)

if [ -n "$DEBUG" ]; then
  # Sends the page's console.log/errors to stderr, which is how a launcher
  # JS exception becomes visible on a box with no devtools.
  CHROME_ARGS+=(--enable-logging=stderr --log-level=0)
  echo "session | chromium ${CHROME_ARGS[*]}"
  # A pipeline cannot be exec'd away, so this branch ends the script itself —
  # falling through would start a second, untagged Chromium.
  chromium "${CHROME_ARGS[@]}" 2>&1 \
    | while IFS= read -r line; do printf 'chromium | %s\n' "$line"; done
  rc=${PIPESTATUS[0]}
  echo "session | chromium exited with status $rc — session over"
  exit "$rc"
fi

exec chromium "${CHROME_ARGS[@]}"
