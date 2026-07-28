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

# Backend (launches/kills apps)
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
