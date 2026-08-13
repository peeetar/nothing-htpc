#!/usr/bin/env python3
"""
Home-button daemon.

Watches all gamepads for the guide/home button (BTN_MODE).
HOLD for 0.7s  -> POST /home to the launcher backend, which kills
                  the foreground app and drops back to the launcher.
Short press    -> ignored. A guide button is easy to brush against,
                  and this one kills whatever you are watching; the
                  hold makes it deliberate. Apps that use the guide
                  button themselves also keep working.

The TV remote's Exit key does the same job via daemon/cecd.py, so
the controller is optional.

Requires: python3-evdev, and the user in the `input` group
(or run as a system service).

Optional, like cecd.py, and for the same reason: without evdev there is no
gamepad, and no gamepad is a normal state — the TV remote does this job over
CEC and the controller is documented as optional. So a missing module is one
line and a clean exit, not a traceback in the middle of the session log where
it reads like the box failed to start.
"""

import sys
import time
import urllib.request
from select import select

try:
    from evdev import InputDevice, ecodes, list_devices
except ImportError:
    print("homebutton: python3-evdev not installed — no gamepad home button",
          flush=True)
    sys.exit(0)

HOLD_SECONDS = 0.7
BACKEND = "http://127.0.0.1:8484/home"


def go_home():
    try:
        urllib.request.urlopen(
            urllib.request.Request(BACKEND, method="POST"), timeout=2
        )
        print("home")
    except Exception as e:
        print(f"backend unreachable: {e}")


def gamepads():
    devs = []
    for path in list_devices():
        try:
            d = InputDevice(path)
            caps = d.capabilities().get(ecodes.EV_KEY, [])
            if ecodes.BTN_MODE in caps:
                devs.append(d)
                print(f"watching {d.name} ({path})")
        except (PermissionError, OSError):
            pass
    return devs


def main():
    devices = {}
    pressed_at = {}
    fired = set()
    last_scan = 0.0

    while True:
        # Rescan for controllers every 5s (hotplug, dongle wake).
        if time.monotonic() - last_scan > 5:
            for d in gamepads():
                devices[d.fd] = d
            last_scan = time.monotonic()

        if not devices:
            time.sleep(1)
            continue

        r, _, _ = select(list(devices), [], [], 0.1)
        now = time.monotonic()

        for fd in r:
            dev = devices[fd]
            try:
                for ev in dev.read():
                    if ev.type == ecodes.EV_KEY and ev.code == ecodes.BTN_MODE:
                        if ev.value == 1:
                            pressed_at[fd] = now
                        elif ev.value == 0:
                            pressed_at.pop(fd, None)
                            fired.discard(fd)
            except OSError:
                devices.pop(fd, None)  # unplugged

        # Fire on hold threshold while still held.
        for fd, t0 in list(pressed_at.items()):
            if fd not in fired and now - t0 >= HOLD_SECONDS:
                fired.add(fd)
                go_home()


if __name__ == "__main__":
    main()
