#!/usr/bin/env bash
# Launch cable TV mode. Wired to the LIVE TV tile via server/config.json.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CABLETV_DIR="$DIR"

# mpv picks up OSD fonts from its config fonts dir — install ours once
FONTDIR="$HOME/.config/mpv/fonts"
mkdir -p "$FONTDIR"
cp -n "$DIR/fonts/"*.ttf "$FONTDIR/" 2>/dev/null

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
  --demuxer-max-bytes=64MiB \
  --network-timeout=10 \
  --stream-lavf-o=reconnect_streamed=1 \
  --title="CABLE TV" \
  --script="$DIR/cabletv.lua"
