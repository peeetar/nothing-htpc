#!/usr/bin/env bash
# Runs inside the cage Wayland session. Everything started here
# inherits WAYLAND_DISPLAY, so launched apps render fullscreen.
set -u

HTPC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Backend (launches/kills apps)
python3 "$HTPC_DIR/server/server.py" &

# Home-button daemon (hold guide button -> return to launcher)
python3 "$HTPC_DIR/daemon/homebutton.py" &

# Spotify Connect endpoint (phone is the remote) — optional
command -v spotifyd >/dev/null && spotifyd --no-daemon &

sleep 1

# Kiosk browser = the launcher UI. When this exits, the session ends.
exec chromium \
  --kiosk "http://127.0.0.1:8484" \
  --noerrdialogs \
  --disable-session-crashed-bubble \
  --disable-features=TranslateUI \
  --autoplay-policy=no-user-gesture-required \
  --ozone-platform=wayland
