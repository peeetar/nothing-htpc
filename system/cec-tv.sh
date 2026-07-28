#!/usr/bin/env bash
# TV control over the Pi's own HDMI-CEC line. No adapter — the 3B+ has a real
# CEC pin, which is a large part of why this box can be a Pi at all.
#
#   cec-tv.sh on       wake the TV and switch it to this input
#   cec-tv.sh off      put the TV on standby
#   cec-tv.sh status   what the TV says about itself
#
# Day-to-day CEC is handled by daemon/cecd.py; this is for scripts, for the
# shutdown hook, and for checking whether CEC works at all. There is no
# suspend/resume hook any more: the Pi has no S3 sleep to hook into.
#
# Needs: apt install v4l-utils, and dtoverlay=vc4-kms-v3d (default on
# Raspberry Pi OS Bookworm and later) so that /dev/cec0 exists.
set -u

DEV="${CEC_DEV:-/dev/cec0}"

if [ ! -e "$DEV" ]; then
  echo "$DEV missing — is vc4-kms-v3d enabled in /boot/firmware/config.txt?" >&2
  exit 1
fi

# Register as a playback device so we have a logical address to send from.
cec-ctl -d "$DEV" --playback --osd-name "${CEC_OSD_NAME:-HTPC}" >/dev/null

phys_addr() {
  cec-ctl -d "$DEV" --show-topology 2>/dev/null \
    | sed -n 's/.*Physical Address *: *\([0-9a-f.]*\).*/\1/p' | head -1
}

case "${1:-}" in
  on)
    cec-ctl -d "$DEV" --to 0 --image-view-on
    sleep 4   # a TV mid-wake ignores the input switch
    cec-ctl -d "$DEV" --active-source "phys-addr=$(phys_addr)"
    ;;
  off)
    cec-ctl -d "$DEV" --to 0 --standby
    ;;
  status)
    cec-ctl -d "$DEV" --show-topology
    cec-ctl -d "$DEV" --to 0 --give-device-power-status
    ;;
  *)
    echo "usage: $0 {on|off|status}" >&2
    exit 2
    ;;
esac
