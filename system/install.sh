#!/usr/bin/env bash
# nothing-htpc installer — Phase 1 of PACKAGING.md.
#
# Turns a fresh minimal Linux install into the HTPC. Idempotent: run it again
# after a git pull. Everything it does is also written out in README.md, so
# nothing here is a black box.
#
# Targets x86_64 since 13 August 2026 — a Fedora laptop for development, an
# AMD-GPU box in production. The Raspberry Pi branches below are kept because
# they cost nothing and are keyed off the presence of a Pi boot config, so on
# x86 they simply do not fire. See the appendix in README.md.
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
# streaming is TorrServer now, a single static Go binary that no distro
# carries. It is not in the package lists for that reason — it has its own
# step, which fetches the release binary, because "install this by hand
# first" is not something the box can ask of whoever is using it. Only MOVIES
# and SHOWS need it; live TV, news, weather and music are unaffected if the
# download fails, so the step warns and carries on. See README.md.
#
# Two package lists, because the same software has different names in each
# ecosystem and the box is developed on Fedora and deployed on whatever the
# HTPC ends up running. This is constraint 25 again in a different costume:
# assuming one distro's name for a thing is how a working machine reports
# itself broken. `chromium` vs `chromium-browser` is the same package.
#
# gamescope and steam are deliberately NOT here. The GAMING tile reports
# which of them is missing, on the TV and in the journal, which is better
# than making an unrelated install fail — and on a dev laptop neither is
# wanted anyway.
detect_pm() {
  if   command -v dnf     >/dev/null; then echo dnf
  elif command -v apt-get >/dev/null; then echo apt
  else echo ""; fi
}
PM="$(detect_pm)"

# libva-utils is `vainfo`, which is the only way to answer "is this box
# actually decoding in hardware" rather than guessing from the fact that it
# plays. mesa-va-drivers is the VA-API driver amdgpu needs — see the freeworld
# note in step 1.
PKGS_APT=(cage chromium mpv foot htop python3 python3-evdev v4l-utils playerctl
          pipewire pipewire-audio wireplumber fonts-dejavu-core git curl
          libva-utils mesa-va-drivers)
PKGS_DNF=(cage chromium mpv foot htop python3 python3-evdev v4l-utils playerctl
          pipewire pipewire-pulseaudio wireplumber dejavu-sans-fonts git curl
          libva-utils mesa-va-drivers)

case "$PM" in
  dnf) PKGS=("${PKGS_DNF[@]}") ;;
  *)   PKGS=("${PKGS_APT[@]}") ;;
esac

# Is one package installed? Asked the way the local package manager answers.
pkg_installed() {
  case "$PM" in
    dnf) rpm -q "$1" >/dev/null 2>&1 ;;
    apt) dpkg -s "$1" >/dev/null 2>&1 ;;
    *)   return 1 ;;
  esac
}

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILED=1; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Every step's commands go through here, and a failure is recorded rather
# than shrugged off. There is no `set -e` on purpose — several steps below are
# allowed to fail (disable getty@tty1 is generator-instantiated on Fedora and
# returns non-zero doing nothing) and aborting the whole install on those
# would be worse. But the opposite was true until 20 August 2026: run() never
# looked at an exit code at all, so a failed `dnf install` still ended with
# "Done. Reboot to land on the launcher" on a box with no browser — and since
# Chromium exiting *is* the end of the session, that reads as a box refusing
# to boot rather than as a package that did not install.
STEP_FAILED=0
run() {
  if [ "$DRY" = 1 ]; then printf '    would run: %s\n' "$*"; return 0; fi
  # rc captured before anything else can clobber $? — inside `if ! "$@"` it is
  # already the negation's status and always reads 0.
  local rc=0
  "$@" || rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "failed (exit $rc): $*"
    STEP_FAILED=1
    return 1
  fi
}

# For the handful of commands whose failure is genuinely not a problem.
run_ok() {
  if [ "$DRY" = 1 ]; then printf '    would run: %s\n' "$*"; return 0; fi
  "$@" || true
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

# TorrServer, if this box has one. The same four places start-session.sh
# probes, in the same order (constraint 25) — a check that finds a binary the
# session then cannot is worse than no check.
find_torrserver() {
  local t
  for t in torrserver TorrServer "$HOME/.local/bin/torrserver" /usr/local/bin/torrserver; do
    if command -v "$t" >/dev/null 2>&1; then command -v "$t"; return 0; fi
  done
  return 1
}

# The release asset for this machine. TorrServer publishes one static binary
# per arch and nothing else has to be resolved.
torrserver_asset() {
  case "$(uname -m)" in
    x86_64)         echo TorrServer-linux-amd64 ;;
    aarch64|arm64)  echo TorrServer-linux-arm64 ;;
    armv7l|armv6l)  echo TorrServer-linux-arm7 ;;
    *)              echo "" ;;
  esac
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
    ok "$(tr -d '\0' < /proc/device-tree/model) (retired target — see README appendix)"
  else
    ok "$(uname -m) — $(sed -n 's/^model name[ \t]*: *//p' /proc/cpuinfo | head -1)"
  fi
  ok "package manager: ${PM:-none found}"
  mem=$(( $(sed -n 's/^MemTotal: *\([0-9]*\).*/\1/p' /proc/meminfo) / 1024 ))
  [ "$mem" -ge 1800 ] && ok "${mem}MB RAM" || warn "${mem}MB RAM is tight — try ?profile=lite"

  step "Packages"
  if [ -z "$PM" ]; then
    warn "no apt or dnf — cannot check packages on this distro"
  else
    for p in "${PKGS[@]}"; do
      pkg_installed "$p" && ok "$p" || bad "$p missing"
    done
  fi

  step "Graphics + CEC"
  # The DRM device is the only hard requirement: without it cage has nothing
  # to draw on and the session restart-loops with no output, which looks
  # exactly like a dead box.
  compgen -G "/dev/dri/card*" >/dev/null && ok "DRM device present" \
                                         || bad "no /dev/dri/card* — cage has nothing to draw on"
  cfg=$(boot_config)
  if [ -n "$cfg" ]; then
    # Only meaningful on a Pi, and only a Pi has this file.
    grep -q '^dtoverlay=vc4-kms-v3d' "$cfg" \
      && ok "vc4-kms-v3d enabled in $cfg" \
      || bad "vc4-kms-v3d not enabled — no display, no /dev/cec0"
  fi
  # CEC is a warning, not a failure: x86 needs a Pulse-Eight adapter, and
  # without one the box is keyboard-driven and entirely fine.
  [ -e /dev/cec0 ] && ok "/dev/cec0 present" \
    || warn "/dev/cec0 missing — no TV remote (needs a CEC adapter on x86)"
  if [ -e /dev/video10 ]; then
    ok "V4L2 H.264 decoder present"
  elif command -v vainfo >/dev/null; then
    vainfo 2>/dev/null | grep -q VAProfile \
      && ok "VA-API hardware decode available" \
      || warn "vainfo reports no profiles — software decode only"
  else
    warn "cannot tell if hardware decode works — install libva-utils for vainfo"
  fi

  step "Permissions"
  for g in input video render; do
    id -nG "$HTPC_USER" | tr ' ' '\n' | grep -qx "$g" \
      && ok "$HTPC_USER in $g" || bad "$HTPC_USER not in $g"
  done
  [ -w /dev/uinput ] && ok "/dev/uinput writable" \
    || warn "/dev/uinput not writable by this shell — TV remote may be dead"

  step "Install"
  ok "repo: $REPO"
  # Every file the session actually opens. The short version of this list
  # passed a checkout with no stremio.py in it, which then 500s on MOVIES —
  # a manifest that only names the entry point is not a manifest.
  for f in server/server.py server/channels.py server/feeds.py \
           server/mpvipc.py server/stremio.py server/tmdb.py \
           launcher/index.html launcher/app.js \
           launcher/theme.js launcher/theme.json system/start-session.sh \
           system/gamescope-session.sh \
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
  # Only MOVIES and SHOWS need this, so it is a warning — but a silent one is
  # how "torrserver is not running" became the answer to every A press on a
  # film with no hint anywhere that the box could have said so first.
  if ts_have="$(find_torrserver)"; then
    ok "torrserver installed: $ts_have"
    curl -sf --max-time 2 -o /dev/null http://127.0.0.1:8090/echo \
      && ok "torrserver answering on :8090" \
      || warn "torrserver not answering (expected if the session is stopped)"
  else
    warn "torrserver not installed — MOVIES and SHOWS cannot play (re-run this installer)"
  fi

  step "Conflicts"
  # `set-default graphical.target` + `disable getty@tty1` does NOT disable a
  # display manager. On a Workstation install GDM and the kiosk both want tty1
  # and the DRM device, and which one wins is a race. Fedora Server or a
  # minimal install is the intended target; this is the check that says so.
  dm_found=""
  for dm in gdm sddm lightdm lxdm xdm greetd; do
    systemctl is-enabled "$dm" >/dev/null 2>&1 && dm_found="$dm" && break
  done
  if [ -n "$dm_found" ]; then
    bad "$dm_found is enabled — it will fight htpc-session for tty1 and the GPU"
    echo "    fix: sudo systemctl disable $dm_found   (this box is a kiosk, not a desktop)"
  else
    ok "no display manager enabled"
  fi
  if [ "$(systemctl get-default 2>/dev/null)" = "graphical.target" ]; then
    ok "default target is graphical.target"
  else
    warn "default target is $(systemctl get-default 2>/dev/null) — re-run this installer"
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

step "1/7 Packages"
case "$PM" in
  dnf)
    run dnf install -y "${PKGS[@]}"
    ;;
  apt)
    run apt-get update
    run apt-get install -y "${PKGS[@]}"
    ;;
  *)
    warn "no apt or dnf found — install these yourself: ${PKGS[*]}"
    ;;
esac

# Fedora ships Mesa with the patent-encumbered decoders stripped out, so
# stock mesa-va-drivers gives amdgpu a VA-API that cannot do H.264 or HEVC —
# and mpv's `--hwdec=auto-safe` does not complain, it just falls back to
# software and burns CPU on exactly the 1080p HEVC channels this box is for.
# The replacement lives in RPM Fusion, which this script will not enable for
# you: that is a third-party repo and enabling one behind someone's back is
# not a thing an installer should do.
if [ "$PM" = dnf ] && ! rpm -q mesa-va-drivers-freeworld >/dev/null 2>&1; then
  warn "Fedora's mesa-va-drivers has the codecs stripped out. For hardware"
  warn "H.264/HEVC decode, enable RPM Fusion and swap in the freeworld build:"
  warn "  sudo dnf install \\"
  warn "    https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-\$(rpm -E %fedora).noarch.rpm"
  warn "  sudo dnf swap mesa-va-drivers mesa-va-drivers-freeworld"
  warn "Check afterwards with: vainfo | grep -E 'H264|HEVC'"
fi

step "2/7 Boot config"
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

step "3/7 Groups and input devices"
run usermod -aG input,video,render,audio "$HTPC_USER"
run install -m 0644 "$REPO/system/99-htpc-input.rules" /etc/udev/rules.d/
run bash -c "echo uinput > /etc/modules-load.d/uinput.conf"
run_ok modprobe uinput      # absent on some kernels; only the TV remote wants it
run udevadm control --reload
ok "groups + udev rules (group changes apply after reboot)"

step "4/7 Files"
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

step "5/7 Service"
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
# Generator-instantiated on Fedora: returns non-zero having done nothing, and
# the unit's own Conflicts=getty@tty1.service covers it regardless.
run_ok systemctl disable getty@tty1
run systemctl enable htpc-session
run systemctl set-default graphical.target

step "6/7 TorrServer"
# MOVIES and SHOWS resolve a magnet and then need something to turn it into
# an HTTP stream. Without a debrid key that something has to run on the box,
# and no distro packages it — so until this step existed, a fresh install
# answered every A press on a film with "torrserver is not running". Accurate,
# and useless to anyone without a terminal.
#
# Non-fatal on purpose: this is the one step that needs the network to reach
# GitHub, and live TV, news, weather, music and gaming do not care whether it
# worked. A failure here warns and the install continues.
if ts_have="$(find_torrserver)"; then
  ok "torrserver already installed: $ts_have"
elif [ -z "$(torrserver_asset)" ]; then
  warn "no TorrServer build for $(uname -m) — MOVIES and SHOWS will not play"
elif ! command -v curl >/dev/null; then
  warn "curl missing — cannot fetch TorrServer; MOVIES and SHOWS will not play"
elif [ "$DRY" = 1 ]; then
  echo "    would download $(torrserver_asset) to /usr/local/bin/torrserver"
else
  ts_url="https://github.com/YouROK/TorrServer/releases/latest/download/$(torrserver_asset)"
  ts_tmp="$(mktemp)"
  # Downloaded to a temp file and only moved into place once it looks like a
  # binary: a half-written or HTML-error-page "torrserver" on PATH is worse
  # than none, because start-session.sh would then start it and it would fail
  # somewhere much less obvious than here.
  if curl -fsSL --max-time 180 -o "$ts_tmp" "$ts_url" \
     && [ -s "$ts_tmp" ] && head -c 4 "$ts_tmp" | grep -q ELF; then
    install -m 0755 "$ts_tmp" /usr/local/bin/torrserver
    ok "installed /usr/local/bin/torrserver ($(du -h /usr/local/bin/torrserver | cut -f1))"
  else
    warn "could not fetch TorrServer from $ts_url — MOVIES and SHOWS will not"
    warn "play until it is installed; everything else is unaffected"
  fi
  rm -f "$ts_tmp"
fi

step "7/7 Flash wear"
# Chromium's cache and the systemd journal are the two things that write
# constantly to a card that does not enjoy it.
#
# But this used to fire unconditionally, and on the AMD box that is actively
# harmful: Storage=volatile throws away the journal at every reboot, and the
# journal is exactly what you need to read after a kiosk that flickers back to
# the launcher. So it is now what its heading always claimed — a measure for
# removable media, applied when the root filesystem is on some.
# findmnt can hand back a subvolume ("/dev/nvme0n1p3[/root]"), and turning a
# partition into its parent disk by chopping digits gets nvme and mmcblk
# wrong. lsblk knows the answer outright.
root_src="$(findmnt -no SOURCE / 2>/dev/null | sed 's|\[.*||')"
root_dev="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1)"
[ -n "$root_dev" ] || root_dev="$(lsblk -no KNAME "$root_src" 2>/dev/null | head -1)"
if [ -n "$root_dev" ] && [ "$(cat "/sys/block/$root_dev/removable" 2>/dev/null)" = 1 ]; then
  run mkdir -p /etc/systemd/journald.conf.d
  run bash -c "printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=16M\n' > /etc/systemd/journald.conf.d/htpc.conf"
  ok "root is on removable media ($root_dev) — journal moved to RAM"
elif [ -f /etc/systemd/journald.conf.d/htpc.conf ]; then
  warn "root is not removable but the journal is still volatile —"
  warn "  rm /etc/systemd/journald.conf.d/htpc.conf to keep logs across reboots"
else
  ok "root is on fixed storage ($root_dev) — journal left on disk, where a"
  ok "  post-mortem of a crash-looping session can still be read"
fi

echo
if [ "$DRY" = 1 ]; then
  echo "Dry run complete — nothing changed."
elif [ "$STEP_FAILED" = 1 ]; then
  echo "FINISHED WITH ERRORS — see the ✗ lines above."
  echo "The box is very likely not bootable into the launcher yet. Fix those,"
  echo "then re-run this installer (it is idempotent) and audit with:"
  echo "                                       $REPO/system/install.sh --check"
  exit 1
else
  echo "Done. Reboot to land on the launcher:  sudo reboot"
  echo "Afterwards, audit it with:             $REPO/system/install.sh --check"
  echo "To update later:                       git -C $REPO pull  &&  sudo systemctl restart htpc-session"
fi
