#!/usr/bin/env bash
# Install to /usr/lib/systemd/system-sleep/cec-tv.sh (chmod +x).
# Requires cec-utils and a Pulse-Eight USB-CEC adapter
# (desktop GPUs have no CEC line on HDMI).
#
# pre  = going to sleep  -> put TV on standby
# post = waking up       -> turn TV on and grab the input

case "$1" in
  pre)
    echo "standby 0" | cec-client -s -d 1
    ;;
  post)
    # TV on, then make this device the active source (input switch)
    ( echo "on 0"; sleep 4; echo "as" ) | cec-client -s -d 1
    ;;
esac
exit 0
