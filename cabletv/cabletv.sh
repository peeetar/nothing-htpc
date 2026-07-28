#!/usr/bin/env bash
# Launch cable TV mode. Wired to the LIVE TV tile via server/config.json.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CABLETV_DIR="$DIR"

# mpv picks up OSD fonts from its config fonts dir — install ours once
FONTDIR="$HOME/.config/mpv/fonts"
mkdir -p "$FONTDIR"
cp -n "$DIR/fonts/"*.ttf "$FONTDIR/" 2>/dev/null

# The static used to be N whole frames in a per-resolution directory; it is
# one scrolled noise field now. Drop the old sets, which are ~50MB at 1080p
# and will never be read again. The glob only matches the old "1920x1080"
# layout, not the new noise-*.bgra files.
rm -rf "$HOME/.cache/cabletv/"[0-9]*x[0-9]* 2>/dev/null

# --- small-machine tuning -------------------------------------------------
# Under ~1.5GB means a Pi 3B+ or similar: the launcher's Chromium is already
# resident, and every MB spent here comes out of stream buffers. Decoding is
# the other half of it — the 3B+ has a hardware H.264 decoder and nothing at
# all for HEVC, so H.265 channels will drop frames whatever is set here.
MEM_KB=$(sed -n 's/^MemTotal: *\([0-9]*\).*/\1/p' /proc/meminfo 2>/dev/null || echo 0)
EXTRA=()
if [ "${MEM_KB:-0}" -gt 0 ] && [ "$MEM_KB" -lt 1572864 ]; then
  # Static costs a screenful of BGRA per tick (8.3MB at 1080p), read and then
  # uploaded, so the frame rate is straight memory bandwidth. 15 is the most
  # a 3B+ has to spare; the desktop default is 25.
  : "${CABLETV_STATIC_FPS:=15}"
  export CABLETV_STATIC_FPS
  # v4l2m2m is the Pi's stateful decoder; -copy pulls frames back into normal
  # memory, which the wayland vo needs. auto-safe will not pick it.
  : "${CABLETV_HWDEC:=v4l2m2m-copy}"
  EXTRA+=(
    --demuxer-max-bytes=24MiB
    --demuxer-max-back-bytes=8MiB
    --scale=bilinear --dscale=bilinear --dither=no
    --sigmoid-upscaling=no --correct-downscaling=no
  )
else
  : "${CABLETV_HWDEC:=auto-safe}"
  EXTRA+=(--demuxer-max-bytes=64MiB)
fi

# --- diagnostics ----------------------------------------------------------
# Launched by server.py, whose stdout/stderr this inherits, so everything
# printed here reaches the session console tagged [livetv].
for f in "$DIR/cabletv.lua" "$DIR/input.conf" "$DIR/channels.m3u"; do
  [ -r "$f" ] || { echo "cabletv: missing $f" >&2; exit 1; }
done
command -v mpv >/dev/null || { echo "cabletv: mpv is not installed" >&2; exit 1; }

# CABLETV_DEBUG=1 (or HTPC_DEBUG=1 from dev-session.sh) turns mpv's own
# reasons on: stream errors, decoder fallbacks and Lua tracebacks that
# otherwise scroll past at the default message level.
if [ -n "${CABLETV_DEBUG:-${HTPC_DEBUG:-}}" ] && [ "${CABLETV_DEBUG:-${HTPC_DEBUG:-}}" != "0" ]; then
  EXTRA+=(--msg-level=all=v --msg-time=yes)
  [ -n "${CABLETV_LOG:-}" ] && EXTRA+=(--log-file="$CABLETV_LOG")
  echo "cabletv: hwdec=$CABLETV_HWDEC mem=${MEM_KB}kB dir=$DIR" >&2
  echo "cabletv: channels=$(grep -c '^#EXTINF' "$DIR/channels.m3u" 2>/dev/null)" >&2
fi

exec mpv \
  --fs \
  --idle=yes \
  --force-window=yes \
  --no-osc \
  --no-osd-bar \
  --osd-level=0 \
  --input-default-bindings=no \
  --input-conf="$DIR/input.conf" \
  --input-gamepad=yes \
  --cursor-autohide=always \
  --cache=yes \
  --hwdec="$CABLETV_HWDEC" \
  --network-timeout=10 \
  --stream-lavf-o=reconnect_streamed=1 \
  --title="CABLE TV" \
  "${EXTRA[@]}" \
  --script="$DIR/cabletv.lua"
