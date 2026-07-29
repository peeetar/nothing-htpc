#!/usr/bin/env python3
"""
mpv IPC bridge.

The UI is a web page and a web page cannot open a unix socket, so every
"play this", "stop" and "what is happening" goes through server.py and lands
here. mpv runs from start-session.sh with --idle and --input-ipc-server, so
it is always alive and either idle or playing — which is what removes the
black frame between the launcher and a channel.

Protocol is one JSON object per line, replies tagged by request_id. Stdlib
`socket` and `json` only, so constraint 7 holds.

This is deliberately forgiving: mpv not being up yet is a normal state during
boot, not an error worth showing on the TV. Callers get a sentence and the UI
retries.
"""

import json
import os
import socket
import threading

SOCKET_PATH = os.environ.get(
    "MPV_IPC_SOCKET",
    os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "htpc-mpv.sock"))

TIMEOUT = float(os.environ.get("MPV_IPC_TIMEOUT", "5"))

_lock = threading.Lock()
_req_id = 0


class MpvError(Exception):
    """A sentence for the TV, not a traceback."""


def _next_id():
    global _req_id
    _req_id += 1
    return _req_id


def command(*args, timeout=TIMEOUT):
    """Send one command and return its `data`.

    Serialised behind a lock: mpv multiplexes by request_id, but reading a
    partial line from a shared socket in two threads does not multiplex at
    all, and the failure mode is a reply handed to the wrong caller.
    """
    if not os.path.exists(SOCKET_PATH):
        raise MpvError("player is not running")

    rid = _next_id()
    payload = json.dumps({"command": list(args), "request_id": rid}).encode() + b"\n"

    with _lock:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(timeout)
            s.connect(SOCKET_PATH)
            s.sendall(payload)
            buf = b""
            while True:
                chunk = s.recv(65536)
                if not chunk:
                    raise MpvError("player closed the connection")
                buf += chunk
                # mpv interleaves unsolicited events with replies; walk whole
                # lines and keep only the one carrying our request_id.
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    if not line.strip():
                        continue
                    try:
                        msg = json.loads(line)
                    except ValueError:
                        continue
                    if msg.get("request_id") != rid:
                        continue
                    if msg.get("error") not in (None, "success"):
                        raise MpvError("player: %s" % msg["error"])
                    return msg.get("data")
        except socket.timeout as e:
            raise MpvError("player did not answer") from e
        except (OSError, ConnectionError) as e:
            raise MpvError("cannot reach the player") from e
        finally:
            try:
                s.close()
            except (OSError, NameError):
                pass


def get(prop, default=None):
    try:
        return command("get_property", prop)
    except MpvError:
        return default


def load(url, *, mode="replace"):
    command("loadfile", url, mode)


def stop():
    command("stop")


def available():
    return os.path.exists(SOCKET_PATH)


def state():
    """Everything the channel bar and the transport need, in one round trip's
    worth of properties. Missing values are None rather than errors — the bar
    draws what it has."""
    if not available():
        return {"available": False}
    return {
        "available": True,
        "idle": bool(get("idle-active", True)),
        "paused": bool(get("pause", False)),
        "position": get("time-pos") or 0,
        "duration": get("duration") or 0,
        "buffering": bool(get("paused-for-cache", False)),
        "cache": get("cache-buffering-state") or 0,
        "path": get("path"),
        "title": get("media-title"),
    }
