#!/usr/bin/env python3
"""
Home-button daemon.

Watches all gamepads for the guide/home button (BTN_MODE).
HOLD for 0.7s  -> POST /home to the launcher backend, which kills
                  the foreground app and drops back to the launcher.
Short press    -> ignored, so Steam Big Picture keeps its normal
                  guide-button behavior.

Requires: python3-evdev, and the user in the `input` group
(or run as a system service).
"""

import time
import urllib.request
from select import select

from evdev import InputDevice, ecodes, list_devices

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
