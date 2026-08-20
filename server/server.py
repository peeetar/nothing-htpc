#!/usr/bin/env python3
"""
HTPC launcher backend.

Serves the launcher UI and launches/kills foreground apps.
Runs inside the cage Wayland session so launched apps inherit
WAYLAND_DISPLAY and appear fullscreen over the launcher.

Endpoints:
  GET  /              launcher UI (and its module assets)
  GET  /config        apps + weather config (JSON)
  POST /launch/<id>   kill current app, start the requested one
  POST /home          kill current app (return to launcher)
  GET  /status        what's currently running
  GET  /music/status  what spotifyd is playing (via playerctl/MPRIS)
  GET  /music/art     album art, proxied so the page can dither it on canvas
  POST /music/<cmd>   playpause | next | previous
  GET  /channels      live TV channels from cabletv/channels.m3u
  GET  /catalog/<k>   movie|show catalogue from Cinemeta
  GET  /meta/<k>/<id> one title's full metadata
  GET  /streams/<k>/<id>  every stream on offer, ranked — the source picker
  POST /play          resolve a title through Torrentio and hand it to mpv
                      (body may carry an `index` from /streams)
  POST /player/load   play a URL (live TV)
  POST /player/stop   back to idle
  GET  /player/state  position, buffering, what is loaded
  GET  /news?url=     RSS proxy — the page cannot fetch time.mk itself

Stdlib only — no dependencies. The music endpoints shell out to playerctl
rather than importing a D-Bus binding, and the catalogue talks to the Stremio
addon protocol over plain HTTP, which keeps that true.

The player endpoints exist because a web page cannot open a unix socket. mpv
runs beside this process with --idle and an IPC socket; the UI is composited
above it, so there is no launch and no black frame between menu and picture.
"""

import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import channels as channels_mod       # noqa: E402
import feeds                          # noqa: E402
import mpvipc                         # noqa: E402
import stremio                        # noqa: E402

ROOT = Path(__file__).resolve().parent
# The repo root, found from this file rather than configured. Everything the
# box runs lives under it, so the checkout works wherever it happens to sit —
# ~/nothing-htpc, /opt/htpc, a USB stick — with no path baked in anywhere.
HTPC_DIR = ROOT.parent
LAUNCHER = HTPC_DIR / "launcher"
UI = LAUNCHER / "index.html"

# The UI is no longer one file: it is index.html plus the theme and the module
# that reads it. Only these extensions are served, and only from launcher/ —
# a path is resolved and then checked to be inside that directory, so `..`
# cannot walk out of it.
STATIC_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js":   "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".css":  "text/css; charset=utf-8",
    ".svg":  "image/svg+xml",
    ".woff2": "font/woff2",
    ".png":  "image/png",
}


def static_file(path):
    """-> (bytes, content-type) or (None, None). Never escapes launcher/."""
    rel = path.lstrip("/") or "index.html"
    ext = os.path.splitext(rel)[1].lower()
    if ext not in STATIC_TYPES:
        return None, None
    try:
        target = (LAUNCHER / rel).resolve()
        target.relative_to(LAUNCHER.resolve())
    except (ValueError, OSError):
        return None, None
    if not target.is_file():
        return None, None
    return target.read_bytes(), STATIC_TYPES[ext]


def _config_path():
    """HTPC_CONFIG > config.local.json > config.json.

    config.json is tracked and carries the defaults. Since the box runs the
    checkout in place, `git pull` would fight with local edits to it — so an
    untracked config.local.json, if present, wins and is never touched by an
    update.
    """
    env = os.environ.get("HTPC_CONFIG")
    if env:
        return Path(env)
    local = ROOT / "config.local.json"
    return local if local.exists() else ROOT / "config.json"


CONFIG_PATH = _config_path()
# The tracked defaults, whatever CONFIG_PATH ended up being. load_config()
# falls back to this for `apps` alone — see the note there.
DEFAULT_CONFIG_PATH = ROOT / "config.json"
# 8484 everywhere real. HTPC_PORT exists so the test suite can start a second
# server on a scratch port without colliding with a running session.
PORT = int(os.environ.get("HTPC_PORT") or 8484)

# HTPC_DEBUG=1 adds HTTP request lines and per-poll music noise. Everything
# else below logs unconditionally: a foreground app that dies on its own used
# to leave no trace at all, which is unreadable both here and in the journal.
DEBUG = os.environ.get("HTPC_DEBUG", "") not in ("", "0")

_log_lock = threading.Lock()


def log(tag, msg):
    """One line per event on stderr: '12:00:01 [tag] msg'.

    stderr, not stdout, so piping the session through a prefixer or a tee
    cannot interleave a half-written line, and unbuffered so the line shows
    up while the thing it describes is still happening.
    """
    stamp = time.strftime("%H:%M:%S")
    with _log_lock:
        sys.stderr.write("%s [%s] %s\n" % (stamp, tag, msg))
        sys.stderr.flush()


def dlog(tag, msg):
    if DEBUG:
        log(tag, msg)


state_lock = threading.Lock()
# "done" is set by the reaper thread once the process has been waited on;
# kill_current() waits on it instead of calling proc.wait() itself, so the two
# threads never race over the same child.
current = {"proc": None, "id": None, "done": None, "t0": 0.0}
# Why the last app went away — surfaced on /status so a failed launch is
# diagnosable without reading the console.
last_exit = {"id": None, "code": None, "seconds": None, "killed": False}

# --- music ------------------------------------------------------------------
# spotifyd exposes MPRIS on the session bus (needs a "full" build and
# use_mpris = true). playerctl reads and drives it, so nothing here needs a
# Spotify API key, an OAuth dance, or a pip package.
PLAYERCTL = shutil.which("playerctl")
PLAYER = os.environ.get("HTPC_PLAYER", "spotifyd")

# Bumped whenever /home is called. The launcher's music view watches this so
# that the TV remote's Exit key closes it — cecd.py posts /home for Exit, and
# an in-page view has no process for that to kill.
home_seq = 0

_art = {"url": None, "data": None, "ctype": None}
_art_lock = threading.Lock()

# Unit separator: cannot occur in a track title, unlike every punctuation
# character a band has ever put in one.
_FMT = "\x1f".join("{{%s}}" % f for f in (
    "status", "artist", "title", "album", "position",
    "mpris:length", "mpris:artUrl",
))


def _pctl(args, timeout=3):
    if not PLAYERCTL:
        return None
    try:
        r = subprocess.run(
            [PLAYERCTL, "-p", PLAYER, *args],
            capture_output=True, text=True, timeout=timeout,
        )
    except (subprocess.TimeoutExpired, OSError) as e:
        log("music", "playerctl %s: %s" % (" ".join(args), e))
        return None
    if r.returncode != 0:
        # Almost always "No player could handle this command" — i.e. spotifyd
        # is not running, or is a slim build with no dbus_mpris.
        dlog("music", "playerctl %s -> %d: %s"
                      % (" ".join(args), r.returncode, r.stderr.strip()))
        return None
    return r.stdout.strip()


def music_status():
    out = _pctl(["metadata", "--format", _FMT])
    if not out:
        # No playerctl, no spotifyd, or nothing loaded. `available` tells the
        # launcher whether to keep polling or give up for good.
        return {"available": bool(PLAYERCTL), "playing": False,
                "status": None, "home_seq": home_seq}

    fields = (out.split("\x1f") + [""] * 7)[:7]
    status, artist, title, album, pos, length, art_url = (f.strip() for f in fields)

    def secs(v):
        try:
            return int(v) / 1_000_000.0   # MPRIS is microseconds
        except (TypeError, ValueError):
            return 0.0

    return {
        "available": True,
        "status": status or None,
        "playing": status == "Playing",
        "artist": artist, "title": title, "album": album,
        "position": secs(pos), "length": secs(length),
        "art": art_url.startswith(("http://", "https://")),
        "home_seq": home_seq,
    }


def music_art():
    """Fetch cover art and hand it back same-origin.

    Proxied rather than linked so the page can read the pixels off a canvas
    to dither it — a cross-origin image would taint the canvas.
    """
    url = _pctl(["metadata", "--format", "{{mpris:artUrl}}"])
    if not url or not url.startswith(("http://", "https://")):
        return None, None
    with _art_lock:
        if _art["url"] == url:
            return _art["data"], _art["ctype"]
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            ctype = r.headers.get("Content-Type", "image/jpeg")
            data = r.read(4_000_000)
    except Exception as e:
        log("music", "cover art fetch failed (%s): %s" % (url.split("/")[2], e))
        return None, None
    with _art_lock:
        _art.update(url=url, data=data, ctype=ctype)
    return data, ctype


# Does the compositor actually put this page over mpv?
#
# The architecture rests on a transparent Chromium composited above an idle
# mpv, and that is not something the page can find out for itself. Measured on
# 13 August 2026: under a nested cage, Chromium logs "Server doesn't support
# zcr_alpha_compositing_v1" and its surface stays opaque — so a transparent
# body composites against nothing and renders as the browser's WHITE default.
# The TV screen was white with a perfectly healthy stream playing behind it,
# which is the worst possible failure because it reads as a crash.
#
# So it becomes a switch rather than an assumption. `1` keeps the intended
# behaviour; `0` makes the TV view opaque, which loses the video but keeps a
# readable, obviously-working UI. dev-session.sh sets 0 when it nests, because
# that is exactly where it is known not to work.
UI_TRANSPARENT = os.environ.get("HTPC_UI_TRANSPARENT", "1") not in ("", "0")


def load_config():
    with open(CONFIG_PATH) as f:
        cfg = json.load(f)
    # config.local.json wins key by key, which is the point of it — but a
    # local file that simply does not mention `apps` was never asking to hide
    # every tile that launches a process, and silently losing GAMING is not
    # something the box can explain on a TV. An explicitly empty list still
    # hides them: that is a decision, an absent key is an omission.
    if "apps" not in cfg and Path(CONFIG_PATH) != DEFAULT_CONFIG_PATH:
        try:
            with open(DEFAULT_CONFIG_PATH) as f:
                base = json.load(f)
            if base.get("apps"):
                cfg["apps"] = base["apps"]
                log("config", "no `apps` in %s — inherited %d from config.json"
                    % (os.path.basename(CONFIG_PATH), len(base["apps"])))
        except (OSError, ValueError):
            pass
    # Runtime facts the page cannot discover, merged over the file. Not stored
    # in config.json: this is a property of the session it is running in, not
    # of the box, and it changes between a kiosk boot and a nested dev run.
    cfg["ui"] = {"transparent": UI_TRANSPARENT}
    return cfg


# Only what the page actually reads. The whole config used to go over the
# wire, which handed the browser the TMDB key — a key the page has no use for
# (every TMDB call is made here, in tmdb.py) and therefore no business
# holding. The bind is 127.0.0.1 so nothing off-box could ask, but a secret
# that is not sent cannot leak from a place nobody thought to look.
PUBLIC_CONFIG_KEYS = ("weather", "ui")


def public_config():
    cfg = load_config()
    return {k: cfg[k] for k in PUBLIC_CONFIG_KEYS if k in cfg}


def kill_current():
    with state_lock:
        proc, done = current["proc"], current["done"]
        app_id, t0 = current["id"], current["t0"]
        current.update(proc=None, id=None, done=None, t0=0.0)

    # Signalling outside the lock: a well-behaved app takes a moment to go
    # away, and /status should stay answerable while it does.
    if proc is None or done is None or done.is_set():
        return
    log("app", "killing %s (pid %d) after %.1fs" % (app_id, proc.pid, time.monotonic() - t0))
    last_exit.update(id=app_id, killed=True)
    try:
        # Kill the whole process group (apps often fork).
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        if not done.wait(4):
            log("app", "%s ignored SIGTERM after 4s -> SIGKILL" % app_id)
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            if not done.wait(2):
                log("app", "%s survived SIGKILL — check for a stuck kernel wait" % app_id)
    except ProcessLookupError:
        pass  # already gone between the check and the signal


def _pump(app_id, pipe):
    """Relay an app's own output, line by line, tagged with its tile id.

    This is the whole point of the exercise: mpv's "Failed to open" and
    bash's "No such file or directory" used to go to /dev/null, so a tile
    that opened and closed immediately left nothing to read anywhere.
    """
    try:
        for raw in iter(pipe.readline, b""):
            log(app_id, raw.decode("utf-8", "replace").rstrip("\r\n"))
    except (OSError, ValueError):
        pass
    finally:
        try:
            pipe.close()
        except OSError:
            pass


def _reap(app_id, proc, done, t0):
    code = proc.wait()
    dt = time.monotonic() - t0
    done.set()

    with state_lock:
        was_current = current["proc"] is proc
        if was_current:
            current.update(proc=None, id=None, done=None, t0=0.0)

    if not was_current:
        # kill_current() already claimed it; it logs its own line.
        last_exit.update(id=app_id, code=code, seconds=round(dt, 1), killed=True)
        return

    last_exit.update(id=app_id, code=code, seconds=round(dt, 1), killed=False)
    how = "exit code %d" % code if code >= 0 else "signal %d" % -code
    log("app", "%s exited on its own after %.1fs (%s)" % (app_id, dt, how))
    if dt < 3:
        log("app", "%s died immediately — the [%s] lines above are why"
                   % (app_id, app_id))


def _expand(cmd):
    """Substitute $HTPC_DIR / ${HTPC_DIR} in a config command.

    This is how config.json points at things inside the repo without knowing
    where the repo is. Only this one name is expanded — no general shell
    expansion, so an mpv URL like av://lavfi:... passes through untouched.
    """
    return [arg.replace("${HTPC_DIR}", str(HTPC_DIR)).replace("$HTPC_DIR", str(HTPC_DIR))
            for arg in cmd]


def _child_env(cfg=None):
    # Launched apps get HTPC_DIR, so a script wired into a tile can find its
    # siblings without having a path baked into it.
    #
    # `weather` in config.json is NOT handed down: it is the box's own
    # location, for the launcher's home screen only. The WEATHER screen is a
    # fixed three-city forecast with its own list in launcher/app.js.
    env = dict(os.environ)
    env["HTPC_DIR"] = str(HTPC_DIR)
    return env


def _preflight(app_id, cmd):
    """Warn about the two failures that look identical from the TV: a missing
    binary, and a command whose script argument is not where it says.

    Runs on the expanded command, so a $HTPC_DIR path that does not exist
    means the checkout is incomplete, not that a path is stale."""
    if not shutil.which(cmd[0]) and "/" not in cmd[0]:
        log("launch", "warning: %s: '%s' is not on PATH" % (app_id, cmd[0]))
    for arg in cmd:
        if arg.startswith("/") and not os.path.exists(arg):
            log("launch", "warning: %s: '%s' does not exist" % (app_id, arg))


def launch(app_id):
    # The launcher has no demo mode: whatever goes wrong here is what the
    # user reads on the TV, so every failure returns a sentence, not a 500.
    try:
        cfg = load_config()
    except (OSError, ValueError) as e:
        log("launch", "config unreadable: %s" % e)
        return False, f"config.json unreadable: {e}"
    app = next((a for a in cfg.get("apps", []) if a.get("id") == app_id), None)
    if not app:
        log("launch", "unknown app '%s' (have: %s)"
                      % (app_id, ", ".join(a.get("id", "?") for a in cfg.get("apps", []))))
        return False, f"unknown app '{app_id}'"
    cmd = app.get("command")
    if not cmd:
        log("launch", "'%s' has no command (view=%s)" % (app_id, app.get("view")))
        return False, f"'{app_id}' has no command configured"

    cmd = _expand(cmd)
    log("launch", "%s -> %s" % (app_id, " ".join(cmd)))
    _preflight(app_id, cmd)
    kill_current()

    # Whatever was playing stops before the app takes the display. mpv is
    # always alive under the launcher, so without this a channel keeps its
    # audio going underneath a game — the picture is covered, the sound is
    # not. Same reasoning as /home. A player that is not up is not an error.
    try:
        mpvipc.stop()
    except mpvipc.MpvError:
        pass

    done = threading.Event()
    t0 = time.monotonic()
    with state_lock:
        try:
            proc = subprocess.Popen(
                cmd,
                start_new_session=True,  # own process group -> clean kill
                env=_child_env(cfg),
                stdin=subprocess.DEVNULL,
                # Merged and drained by _pump below. Never DEVNULL: an app's
                # last words before it dies are the only diagnosis available.
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
        except FileNotFoundError:
            log("launch", "%s: %s is not installed" % (app_id, cmd[0]))
            return False, f"{cmd[0]} is not installed"
        except OSError as e:
            log("launch", "%s: could not start %s: %s" % (app_id, cmd[0], e))
            return False, f"could not start {cmd[0]}: {e}"
        current.update(proc=proc, id=app_id, done=done, t0=t0)

    log("launch", "%s started, pid %d" % (app_id, proc.pid))
    threading.Thread(target=_pump, args=(app_id, proc.stdout), daemon=True).start()
    threading.Thread(target=_reap, args=(app_id, proc, done, t0), daemon=True).start()
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
        path, _, query = self.path.partition("?")
        q = urllib.parse.parse_qs(query)

        if path in ("/", "/index.html"):
            self._send(200, UI.read_bytes(), "text/html; charset=utf-8")
        elif path == "/channels":
            self._send(200, channels_mod.load())
        elif path.startswith("/catalog/"):
            kind = path.split("/catalog/", 1)[1]
            try:
                self._send(200, stremio.catalog(kind, skip=int(q.get("skip", ["0"])[0])))
            except (stremio.StremioError, ValueError) as e:
                log("catalog", "%s: %s" % (kind, e))
                self._send(502, {"ok": False, "msg": str(e)})
        elif path.startswith("/meta/"):
            parts = path.split("/")
            if len(parts) != 4:
                self._send(400, {"ok": False, "msg": "usage: /meta/<kind>/<id>"})
                return
            try:
                self._send(200, stremio.meta(parts[2], parts[3]))
            except stremio.StremioError as e:
                self._send(502, {"ok": False, "msg": str(e)})
        elif path.startswith("/streams/"):
            # The stream picker's list. Separate from /play on purpose: /play
            # commits to something, this only says what is on offer, so the
            # panel can be opened and closed without a magnet being minted.
            parts = path.split("/")
            if len(parts) != 4:
                self._send(400, {"ok": False, "msg": "usage: /streams/<kind>/<id>"})
                return
            try:
                self._send(200, {"streams": stremio.stream_rows(parts[2], parts[3])})
            except stremio.StremioError as e:
                log("streams", "%s %s: %s" % (parts[2], parts[3], e))
                self._send(502, {"ok": False, "msg": str(e)})
        elif path == "/player/state":
            self._send(200, mpvipc.state())
        elif path == "/news":
            url = (q.get("url") or [""])[0]
            try:
                self._send(200, feeds.fetch(url))
            except feeds.FeedError as e:
                # 200 with an error field, not a 5xx: the news screen draws
                # one row per source and a broken source is a row that says
                # so, not a screen that fails to open.
                log("news", "%s: %s" % (url or "(no url)", e))
                self._send(200, {"items": [], "error": str(e)})
        elif path == "/config":
            # A missing or unparseable config is a JSON error, not a dropped
            # socket: every other path here reports its failure and this one
            # used to take the connection down with a traceback instead.
            try:
                self._send(200, public_config())
            except (OSError, ValueError) as e:
                log("config", "%s: %s" % (CONFIG_PATH, e))
                self._send(500, {"error": "config is missing or not valid JSON"})
        elif path == "/status":
            with state_lock:
                running = current["proc"] is not None and current["proc"].poll() is None
                self._send(200, {
                    "running": running,
                    "app": current["id"] if running else None,
                    # Why the last app went away — a tile that opened and shut
                    # again is readable over HTTP, not just on the console.
                    "last_exit": dict(last_exit),
                })
        elif path == "/music/status":
            self._send(200, music_status())
        elif path == "/music/art":
            data, ctype = music_art()
            if data:
                self._send(200, data, ctype)
            else:
                self._send(404, {"error": "no art"})
        else:
            body, ctype = static_file(path)
            if body is not None:
                self._send(200, body, ctype)
            else:
                self._send(404, {"error": "not found"})

    def _body(self):
        """Read a JSON request body. An unparseable one is {} — every caller
        below validates the fields it needs anyway, and a 400 with a sentence
        beats a traceback in the journal."""
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return {}
        if n <= 0:
            return {}
        try:
            return json.loads(self.rfile.read(min(n, 1_000_000)) or b"{}")
        except (ValueError, OSError):
            return {}

    def do_POST(self):
        global home_seq
        path = self.path.partition("?")[0]

        if path == "/player/load":
            body = self._body()
            url = body.get("url")
            if not url:
                self._send(400, {"ok": False, "msg": "no url"})
                return
            try:
                mpvipc.load(url)
                log("player", "load %s (%s)" % (url[:90], body.get("kind") or "?"))
                self._send(200, {"ok": True})
            except mpvipc.MpvError as e:
                log("player", "load failed: %s" % e)
                self._send(502, {"ok": False, "msg": str(e)})
            return

        if path == "/player/stop":
            try:
                mpvipc.stop()
                self._send(200, {"ok": True})
            except mpvipc.MpvError as e:
                self._send(502, {"ok": False, "msg": str(e)})
            return

        if path == "/play":
            body = self._body()
            kind, title_id = body.get("kind", "movie"), body.get("id")
            if not title_id:
                self._send(400, {"ok": False, "msg": "no id"})
                return
            try:
                # Torrentio is asked at play time, never at browse time: a
                # stream URL minted now is stale in minutes, so baking one
                # into the catalogue would guarantee a dead link by the time
                # anyone pressed OK.
                #
                # `index` is a row from /streams — absent means "the ranking's
                # own pick", which is what Ⓐ on the detail panel sends. It is
                # only ever set when the owner opened the picker and chose
                # something else, usually because the first one would not play.
                index = body.get("index", 0)
                url, label = stremio.resolve(kind, title_id, index)
                log("play", "%s %s [%s] -> %s" % (kind, title_id, index, label))
                mpvipc.load(url)
                self._send(200, {"ok": True, "msg": label})
            except (stremio.StremioError, mpvipc.MpvError) as e:
                log("play", "%s %s failed: %s" % (kind, title_id, e))
                self._send(502, {"ok": False, "msg": str(e)})
            return

        if path.startswith("/launch/"):
            ok, msg = launch(path.split("/launch/", 1)[1])
            self._send(200 if ok else 400, {"ok": ok, "msg": msg})
        elif path == "/home":
            log("home", "return to launcher")
            kill_current()
            # Whatever was playing stops too. /home means "return to the
            # launcher", and mpv left playing under a menu is audio from a
            # channel nobody can see. Failures are ignored: mpv not being up
            # is not a reason for the home button to report an error.
            try:
                mpvipc.stop()
            except mpvipc.MpvError:
                pass
            home_seq += 1
            self._send(200, {"ok": True})
        elif path.startswith("/music/"):
            cmd = path.split("/music/", 1)[1]
            if cmd not in ("playpause", "next", "previous"):
                self._send(400, {"ok": False, "msg": f"unknown music command '{cmd}'"})
            elif not PLAYERCTL:
                self._send(400, {"ok": False, "msg": "playerctl is not installed"})
            else:
                ok = _pctl([cmd]) is not None
                self._send(200, {"ok": ok, "msg": "ok" if ok else "no player running"})
        else:
            self._send(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        # Quiet by default (the music view polls once a second and would bury
        # everything else); HTPC_DEBUG=1 turns the access log back on.
        dlog("http", "%s %s" % (self.command, self.path))


def startup_report():
    log("server", "listening on 127.0.0.1:%d  (debug=%s)" % (PORT, "on" if DEBUG else "off"))
    log("server", "root:   %s" % HTPC_DIR)
    log("server", "config: %s" % CONFIG_PATH)
    log("server", "ui:     %s%s" % (UI, "" if UI.exists() else "  MISSING"))
    log("server", "playerctl: %s" % (PLAYERCTL or "not installed — MUSIC will read as unavailable"))
    try:
        cfg = load_config()
    except (OSError, ValueError) as e:
        log("server", "config is unreadable: %s — every launch will fail" % e)
        return
    for app in cfg.get("apps", []):
        app_id = app.get("id", "?")
        if app.get("view"):
            log("server", "  %-10s view %s (launches nothing)" % (app_id, app["view"]))
            continue
        cmd = app.get("command")
        if not cmd:
            log("server", "  %-10s no command" % app_id)
            continue
        cmd = _expand(cmd)
        log("server", "  %-10s %s" % (app_id, " ".join(cmd)))
        _preflight(app_id, cmd)


def _shutdown(sig, _frame):
    # Without this a Ctrl+C on a dev machine leaves the foreground app running
    # with no launcher in front of it. (Under systemd the cgroup would clean
    # up, but the app is in its own session, so being explicit is free.)
    log("server", "%s — killing current app and exiting" % signal.Signals(sig).name)
    kill_current()
    sys.exit(0)


if __name__ == "__main__":
    if not CONFIG_PATH.exists():
        sys.exit(f"missing {CONFIG_PATH}")
    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)
    startup_report()
    try:
        httpd = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    except OSError as e:
        sys.exit("cannot bind 127.0.0.1:%d: %s (another session already running?)" % (PORT, e))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log("server", "interrupted — killing current app")
        kill_current()
