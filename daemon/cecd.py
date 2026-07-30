#!/usr/bin/env python3
"""
HDMI-CEC daemon (Raspberry Pi).

The Pi drives CEC over its own HDMI connector through the kernel CEC API
(/dev/cec0) — no Pulse-Eight adapter, which is the one part of the x86 build
this replaces outright.

Two jobs:

1. TV remote -> virtual keyboard. Incoming CEC user-control presses are
   replayed on a uinput device, so they arrive at whatever is on screen as
   ordinary key events. That means the launcher (arrows/Enter) and cable mode
   (arrows, PGUP/PGDN, digits, t, x, ESC) both respond to the TV remote with
   zero changes to either — the gamepad becomes optional.

2. Power/input follow. At startup: wake the TV and claim the input. On the
   TV going to standby: drop to the launcher, which kills whatever is
   streaming. The Pi has no S3 sleep, so there is nothing to suspend — the
   box just idles at ~2W with the TV off.

Everything here is best-effort: if cec-ctl is missing, /dev/cec0 does not
exist, or the TV ignores us, the daemon says so and gets out of the way. It
must never be able to take the session down with it.

Requires: v4l-utils (cec-ctl), python3-evdev, and write access to /dev/uinput.
"""

import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request

CEC_DEV = os.environ.get("CEC_DEV", "/dev/cec0")
OSD_NAME = os.environ.get("CEC_OSD_NAME", "HTPC")[:14]  # CEC caps this at 14
BACKEND_HOME = "http://127.0.0.1:8484/home"

try:
    from evdev import UInput, ecodes as e
except ImportError:
    print("cecd: python3-evdev not installed — no remote control", flush=True)
    sys.exit(0)


# CEC user-control code -> key to synthesise.
#
# These land on the bindings that already exist. Since the July 2026 remodel
# there is only one consumer — the launcher page reads arrows, Enter, Escape,
# Backspace, PageUp/PageDown and the digits, and routes them by whichever
# screen is up. mpv has no keybindings at all any more (it is started with
# --no-input-default-bindings and draws no UI), so nothing here has to care
# whether the box is on a channel or in a menu.
KEYMAP = {
    "select":        e.KEY_ENTER,
    "up":            e.KEY_UP,
    "down":          e.KEY_DOWN,
    "left":          e.KEY_LEFT,
    "right":         e.KEY_RIGHT,
    "channel-up":    e.KEY_PAGEUP,
    "channel-down":  e.KEY_PAGEDOWN,
    "channel up":    e.KEY_PAGEUP,
    "channel down":  e.KEY_PAGEDOWN,
    "electronic-program-guide": e.KEY_T,
    "guide":         e.KEY_T,
    "contents-menu": e.KEY_T,
    "number-0": e.KEY_0, "number-1": e.KEY_1, "number-2": e.KEY_2,
    "number-3": e.KEY_3, "number-4": e.KEY_4, "number-5": e.KEY_5,
    "number-6": e.KEY_6, "number-7": e.KEY_7, "number-8": e.KEY_8,
    "number-9": e.KEY_9,
    "number-entry-mode": e.KEY_X,
    "back":          e.KEY_ESC,
    "previous-channel": e.KEY_ESC,
}

# Keys that mean "get me out of here" — handled by the backend, not uinput,
# because returning home has to work even when the foreground app is wedged.
HOME_KEYS = {"exit", "root-menu", "setup-menu", "power-off-function"}

CAPS = {e.EV_KEY: sorted(set(KEYMAP.values()))}

# "ui-cmd: channel-up (0x30)" — name first, hex as fallback for odd builds.
UI_CMD_RE = re.compile(r"ui-cmd:\s*([a-z0-9 \-]+?)\s*(?:\(0x([0-9a-f]+)\))?\s*$", re.I)
HEX_FALLBACK = {
    "00": "select", "01": "up", "02": "down", "03": "left", "04": "right",
    "09": "root-menu", "0a": "setup-menu", "0b": "contents-menu", "0d": "exit",
    "20": "number-0", "21": "number-1", "22": "number-2", "23": "number-3",
    "24": "number-4", "25": "number-5", "26": "number-6", "27": "number-7",
    "28": "number-8", "29": "number-9",
    "30": "channel-up", "31": "channel-down", "53": "guide",
}


def log(msg):
    print(f"cecd: {msg}", flush=True)


def cec(*args, timeout=10):
    """Run cec-ctl. Returns stdout, or None if it failed — never raises."""
    try:
        r = subprocess.run(
            ["cec-ctl", "-d", CEC_DEV, *args],
            capture_output=True, text=True, timeout=timeout,
        )
        if r.returncode != 0:
            log(f"cec-ctl {' '.join(args)} -> rc={r.returncode} {r.stderr.strip()}")
            return None
        return r.stdout
    except subprocess.TimeoutExpired:
        log(f"cec-ctl {' '.join(args)} timed out")
    except OSError as err:
        log(f"cec-ctl {' '.join(args)} failed: {err}")
    return None


def go_home():
    try:
        urllib.request.urlopen(
            urllib.request.Request(BACKEND_HOME, method="POST"), timeout=2
        )
        log("-> home")
    except Exception as err:
        log(f"backend unreachable: {err}")


def claim_tv():
    """Announce ourselves, wake the TV, and switch it to our input."""
    # Register as a Playback device. Without this the TV has no reason to
    # send us anything, and we have no logical address to transmit from.
    cec("--playback", f"--osd-name={OSD_NAME}")
    cec("--to", "0", "--image-view-on")
    time.sleep(2)  # TVs ignore an input switch sent while still waking
    cec("--active-source", "phys-addr=" + physical_address())
    log(f"claimed input as '{OSD_NAME}'")


def physical_address():
    """Ask the adapter what address the TV gave us (e.g. 1.0.0.0)."""
    out = cec("--show-topology") or ""
    m = re.search(r"Physical Address\s*:\s*([0-9a-f]\.[0-9a-f]\.[0-9a-f]\.[0-9a-f])", out, re.I)
    return m.group(1) if m else "1.0.0.0"


def handle(cmd, ui):
    if cmd in HOME_KEYS:
        go_home()
        return
    key = KEYMAP.get(cmd)
    if key is None:
        return
    # Tap, rather than tracking press/release. The TV resends PRESSED while
    # the button is held, so repeat still works — and a RELEASED lost to a
    # noisy CEC line can never leave a key stuck down, which would wedge the
    # whole box behind an autorepeating arrow.
    ui.write(e.EV_KEY, key, 1)
    ui.syn()
    ui.write(e.EV_KEY, key, 0)
    ui.syn()


def monitor(ui):
    """Follow CEC traffic, translating it. Returns when the stream ends."""
    proc = subprocess.Popen(
        ["cec-ctl", "-d", CEC_DEV, "--monitor"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
    )
    for line in proc.stdout:
        line = line.strip()

        m = UI_CMD_RE.search(line)
        if m:
            name = (m.group(1) or "").strip().lower()
            if name not in KEYMAP and name not in HOME_KEYS and m.group(2):
                name = HEX_FALLBACK.get(m.group(2).lower().zfill(2), name)
            handle(name, ui)
            continue

        # TV went to standby: stop whatever is streaming. Nothing is watching.
        if "STANDBY" in line:
            log("TV standby")
            go_home()
        # TV came back and pointed at us again.
        elif "SET_STREAM_PATH" in line or "REQUEST_ACTIVE_SOURCE" in line:
            cec("--active-source", "phys-addr=" + physical_address())

    proc.wait()


def main():
    if not shutil.which("cec-ctl"):
        log("cec-ctl not found — apt install v4l-utils. Exiting.")
        return
    if not os.path.exists(CEC_DEV):
        log(f"{CEC_DEV} missing. On a Pi this means the vc4 KMS driver is not "
            f"active — check dtoverlay=vc4-kms-v3d in /boot/firmware/config.txt. "
            f"Exiting.")
        return

    try:
        ui = UInput(CAPS, name="htpc-cec-remote")
    except Exception as err:
        log(f"cannot open /dev/uinput ({err}) — remote keys disabled, "
            f"power sync only")
        ui = None

    claim_tv()

    backoff = 2
    while True:
        try:
            monitor(ui) if ui else time.sleep(3600)
        except Exception as err:
            log(f"monitor died: {err}")
        # cec-ctl exiting usually means the HDMI link dropped (TV off at the
        # wall). Retry forever, slowly — the TV will come back.
        time.sleep(backoff)
        backoff = min(backoff * 2, 60)


if __name__ == "__main__":
    main()
