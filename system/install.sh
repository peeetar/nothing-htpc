#!/usr/bin/env bash
# nothing-htpc installer — Phase 1 of PACKAGING.md.
#
# Turns a fresh Raspberry Pi OS Lite install into the HTPC. Idempotent: run
# it again after a git pull. Everything it does is also written out in
# README.md, so nothing here is a black box.
#
#   sudo ./system/install.sh              install / update
#   ./system/install.sh --dry-run         print what it would do
#   ./system/install.sh --check           audit a box that is already set up
#
# The box runs THIS CHECKOUT, in place. Nothing is copied to /opt or anywhere
# else: the systemd unit is pointed at wherever you cloned the repo, and
# everything inside it finds its siblings by relative path. So `git pull` is
# the whole update procedure, and moving the clone means re-running this.
#
# It deliberately does NOT: touch server/config.json (edit it, or drop a
# server/config.local.json beside it — that one is untracked and wins),
# install any media client, or reboot you.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY=0
CHECK=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --check)   CHECK=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# The user the session runs as: whoever invoked sudo, not root.
HTPC_USER="${SUDO_USER:-$(id -un)}"
HTPC_UID="$(id -u "$HTPC_USER")"

# peerflix and webtorrent are gone with the July 2026 remodel: torrent
# streaming is TorrServer now, a single static Go binary that apt does not
# carry. It is optional — live TV, news, weather and music all work without
# it, only MOVIES and SHOWS need it — so it is not in this list and step 6
# just says whether it is running. See README.md.
PKGS=(cage chromium mpv foot htop python3 python3-evdev v4l-utils playerctl
      pipewire pipewire-audio wireplumber fonts-dejavu-core git curl)

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILED=1; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

run() {
  if [ "$DRY" = 1 ]; then printf '    would run: %s\n' "$*"; else "$@"; fi
}

# Can the session user actually read the checkout? Since the box runs the repo
# where it stands, a clone somewhere that user cannot reach is now a real
# failure mode, and it presents as a blank screen. Only drop privileges when
# we have them — otherwise sudo would sit there wanting a password.
repo_readable() {
  if [ "$(id -u)" = 0 ] && [ "$HTPC_USER" != root ]; then
    sudo -u "$HTPC_USER" test -r "$REPO/server/server.py" 2>/dev/null
  elif [ "$HTPC_USER" = "$(id -un)" ]; then
    test -r "$REPO/server/server.py"
  else
    return 0   # cannot tell from here; --check as root will say for sure
  fi
}

boot_config() {
  # Bookworm moved this out from under /boot. Both still exist in the wild.
  if [ -f /boot/firmware/config.txt ]; then echo /boot/firmware/config.txt
  elif [ -f /boot/config.txt ];       then echo /boot/config.txt
  else echo ""; fi
}

# ---------------------------------------------------------------- check ----
if [ "$CHECK" = 1 ]; then
  FAILED=0
  step "Hardware"
  if grep -qi raspberry /proc/device-tree/model 2>/dev/null; then
    ok "$(tr -d '\0' < /proc/device-tree/model)"
  else
    warn "not a Raspberry Pi — CEC and hardware decode checks will fail"
  fi
  mem=$(( $(sed -n 's/^MemTotal: *\([0-9]*\).*/\1/p' /proc/meminfo) / 1024 ))
  [ "$mem" -ge 900 ] && ok "${mem}MB RAM" || warn "${mem}MB RAM is very tight"

  step "Packages"
  for p in "${PKGS[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 && ok "$p" || bad "$p missing"
  done

  step "Graphics + CEC"
  cfg=$(boot_config)
  if [ -n "$cfg" ] && grep -q '^dtoverlay=vc4-kms-v3d' "$cfg"; then
    ok "vc4-kms-v3d enabled in $cfg"
  else
    bad "vc4-kms-v3d not enabled — no display, no /dev/cec0"
  fi
  [ -e /dev/cec0 ] && ok "/dev/cec0 present" || bad "/dev/cec0 missing"
  compgen -G "/dev/dri/card*" >/dev/null && ok "DRM device present" \
                                         || bad "no /dev/dri/card* — cage has nothing to draw on"
  [ -e /dev/video10 ] && ok "V4L2 H.264 decoder present" \
                      || warn "/dev/video10 missing — software decode only"

  step "Permissions"
  for g in input video render; do
    id -nG "$HTPC_USER" | tr ' ' '\n' | grep -qx "$g" \
      && ok "$HTPC_USER in $g" || bad "$HTPC_USER not in $g"
  done
  [ -w /dev/uinput ] && ok "/dev/uinput writable" \
    || warn "/dev/uinput not writable by this shell — TV remote may be dead"

  step "Install"
  ok "repo: $REPO"
  for f in server/server.py launcher/index.html launcher/app.js \
           launcher/theme.js launcher/theme.json system/start-session.sh \
           daemon/homebutton.py daemon/cecd.py cabletv/shim.lua \
           cabletv/channels.m3u; do
    [ -f "$REPO/$f" ] && ok "$f" || bad "$f missing from the checkout"
  done
  if [ -f "$REPO/server/config.local.json" ]; then
    ok "server/config.local.json (untracked override, wins over config.json)"
  else
    [ -f "$REPO/server/config.json" ] && ok "server/config.json" \
                                      || bad "server/config.json missing"
  fi
  if repo_readable; then
    ok "$HTPC_USER can read the repo"
  else
    bad "$HTPC_USER cannot read $REPO — the session will not start"
  fi
  systemctl is-enabled htpc-session >/dev/null 2>&1 \
    && ok "htpc-session enabled" || bad "htpc-session not enabled"
  systemctl is-active htpc-session >/dev/null 2>&1 \
    && ok "htpc-session running" || warn "htpc-session not running"
  if curl -sf --max-time 2 http://127.0.0.1:8484/config >/dev/null; then
    ok "backend answering on :8484"
  else
    warn "backend not answering (expected if the session is stopped)"
  fi

  step "Service identity"
  svc=/etc/systemd/system/htpc-session.service
  if [ -f "$svc" ]; then
    u=$(sed -n 's/^User=//p' "$svc")
    r=$(sed -n 's/.*XDG_RUNTIME_DIR=\/run\/user\///p' "$svc")
    [ "$u" = "$HTPC_USER" ] && ok "User=$u" || bad "User=$u but you are $HTPC_USER"
    [ "$r" = "$HTPC_UID" ] && ok "XDG_RUNTIME_DIR uid $r" \
      || bad "XDG_RUNTIME_DIR uid $r but $HTPC_USER is $HTPC_UID (this is the 217/USER crash-loop)"
    # The unit is the only file that knows where the repo is; if the clone
    # moved, this is the line that still points at the old place.
    unit_start=$(sed -n 's/^ExecStart=.*-- //p' "$svc")
    if [ "$unit_start" = "$REPO/system/start-session.sh" ]; then
      ok "ExecStart points at this checkout"
    elif [ -x "$unit_start" ]; then
      warn "ExecStart points at $unit_start, not this checkout ($REPO) — that clone is the one running"
    else
      bad "ExecStart points at $unit_start, which is not executable — re-run this installer"
    fi
  else
    bad "$svc not installed"
  fi

  echo
  [ "${FAILED:-0}" = 0 ] && echo "All good." || echo "Problems found — see ✗ above."
  exit "${FAILED:-0}"
fi

# -------------------------------------------------------------- install ----
if [ "$DRY" = 0 ] && [ "$(id -u)" != 0 ]; then
  echo "needs root: sudo $0" >&2
  exit 1
fi

echo "Installing nothing-htpc"
echo "  repo:  $REPO  (run in place — nothing is copied)"
echo "  user:  $HTPC_USER (uid $HTPC_UID)"
[ "$DRY" = 1 ] && echo "  MODE:  dry run, nothing will change"

step "1/6 Packages"
run apt-get update
run apt-get install -y "${PKGS[@]}"

step "2/6 Boot config"
cfg=$(boot_config)
if [ -z "$cfg" ]; then
  warn "no config.txt found — not a Pi? skipping display/CEC setup"
else
  # vc4-kms-v3d gives us the DRM device cage needs AND /dev/cec0. Without it
  # the session restart-loops with no output, which looks like a dead Pi.
  if grep -q '^dtoverlay=vc4-kms-v3d' "$cfg"; then
    ok "vc4-kms-v3d already set"
  else
    run bash -c "printf '\n# nothing-htpc: DRM output for cage + HDMI-CEC\ndtoverlay=vc4-kms-v3d\n' >> '$cfg'"
    ok "added vc4-kms-v3d to $cfg (needs reboot)"
  fi
  # 1080p output has no business reserving 128MB for a GPU that only decodes.
  if grep -q '^gpu_mem=' "$cfg"; then
    ok "gpu_mem already set: $(grep '^gpu_mem=' "$cfg")"
  else
    run bash -c "printf 'gpu_mem=96\n' >> '$cfg'"
    ok "set gpu_mem=96"
  fi
fi

step "3/6 Groups and input devices"
run usermod -aG input,video,render,audio "$HTPC_USER"
run install -m 0644 "$REPO/system/99-htpc-input.rules" /etc/udev/rules.d/
run bash -c "echo uinput > /etc/modules-load.d/uinput.conf"
run modprobe uinput
run udevadm control --reload
ok "groups + udev rules (group changes apply after reboot)"

step "4/6 Files"
# Nothing is copied: the service runs this checkout where it stands. All this
# step has to guarantee is that the bits git does not reliably carry (exec
# permissions) are set, and that the session user can actually get here.
run chmod +x "$REPO/system/"*.sh "$REPO/daemon/"*.py
ok "scripts executable"

if repo_readable; then
  ok "$HTPC_USER can read $REPO"
else
  bad "$HTPC_USER cannot read $REPO"
  echo "    The session runs as $HTPC_USER and needs to read the clone. Either move"
  echo "    the repo somewhere that user can reach, or chmod a+rx the path to it."
  [ "$DRY" = 0 ] && exit 1
fi
if [ -f "$REPO/server/config.local.json" ]; then
  ok "server/config.local.json present — it overrides config.json and git ignores it"
fi

step "5/6 Service"
# Rewrite the three machine-specific lines rather than trusting the checked-in
# defaults: a username/uid mismatch is the 217/USER crash-loop in the README,
# and ExecStart is the only place that records where the repo lives.
unit=/etc/systemd/system/htpc-session.service
if [ "$DRY" = 1 ]; then
  echo "    would install $unit with User=$HTPC_USER, uid $HTPC_UID"
  echo "    would point ExecStart at $REPO/system/start-session.sh"
else
  sed -e "s|^User=.*|User=$HTPC_USER|" \
      -e "s|^Environment=XDG_RUNTIME_DIR=.*|Environment=XDG_RUNTIME_DIR=/run/user/$HTPC_UID|" \
      -e "s|^ExecStart=.*|ExecStart=/usr/bin/cage -d -- $REPO/system/start-session.sh|" \
      "$REPO/system/htpc-session.service" > "$unit"
  ok "installed $unit for $HTPC_USER, running $REPO"
fi
run systemctl daemon-reload
run systemctl disable getty@tty1
run systemctl enable htpc-session
run systemctl set-default graphical.target

step "6/6 SD card wear"
# Chromium's cache and the systemd journal are the two things that write
# constantly to a card that does not enjoy it.
run mkdir -p /etc/systemd/journald.conf.d
run bash -c "printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=16M\n' > /etc/systemd/journald.conf.d/htpc.conf"
ok "journal moved to RAM"

echo
if [ "$DRY" = 1 ]; then
  echo "Dry run complete — nothing changed."
else
  echo "Done. Reboot to land on the launcher:  sudo reboot"
  echo "Afterwards, audit it with:             $REPO/system/install.sh --check"
  echo "To update later:                       git -C $REPO pull  &&  sudo systemctl restart htpc-session"
fi
