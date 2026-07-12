#!/usr/bin/env python3
"""
HTPC launcher backend.

Serves the launcher UI and launches/kills foreground apps.
Runs inside the cage Wayland session so launched apps inherit
WAYLAND_DISPLAY and appear fullscreen over the launcher.

Endpoints:
  GET  /            launcher UI
  GET  /config      apps + weather config (JSON)
  POST /launch/<id> kill current app, start the requested one
  POST /home        kill current app (return to launcher)
  GET  /status      what's currently running

Stdlib only — no dependencies.
"""

import json
import os
import signal
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
UI = ROOT.parent / "launcher" / "index.html"
CONFIG_PATH = ROOT / "config.json"
PORT = 8484

state_lock = threading.Lock()
current = {"proc": None, "id": None}


def load_config():
    with open(CONFIG_PATH) as f:
        return json.load(f)


def kill_current():
    with state_lock:
        proc = current["proc"]
        if proc and proc.poll() is None:
            try:
                # Kill the whole process group (apps often fork).
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                try:
                    proc.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
        current["proc"] = None
        current["id"] = None


def launch(app_id):
    cfg = load_config()
    app = next((a for a in cfg["apps"] if a["id"] == app_id), None)
    if not app:
        return False, f"unknown app '{app_id}'"
    cmd = app.get("command")
    if not cmd:
        return False, f"'{app_id}' has no command configured"
    kill_current()
    with state_lock:
        current["proc"] = subprocess.Popen(
            cmd,
            start_new_session=True,  # own process group -> clean kill
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        current["id"] = app_id
    return True, "ok"


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self._send(200, UI.read_bytes(), "text/html; charset=utf-8")
        elif self.path == "/config":
            self._send(200, load_config())
        elif self.path == "/status":
            with state_lock:
                running = current["proc"] is not None and current["proc"].poll() is None
                self._send(200, {"running": running, "app": current["id"] if running else None})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path.startswith("/launch/"):
            ok, msg = launch(self.path.split("/launch/", 1)[1])
            self._send(200 if ok else 400, {"ok": ok, "msg": msg})
        elif self.path == "/home":
            kill_current()
            self._send(200, {"ok": True})
        else:
            self._send(404, {"error": "not found"})

    def log_message(self, *args):
        pass  # keep journal quiet


if __name__ == "__main__":
    if not CONFIG_PATH.exists():
        sys.exit(f"missing {CONFIG_PATH}")
    print(f"launcher backend on :{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
