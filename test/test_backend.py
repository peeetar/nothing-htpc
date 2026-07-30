#!/usr/bin/env python3
"""
Backend tests. Stdlib unittest, no pytest — the box has no pip packages and
the tests have to run on it (constraint 7).

    python3 -m unittest discover -s test -v
    python3 test/test_backend.py            # same thing

Nothing here touches the network. Feed parsing and stream ranking run against
captured fixtures, because the point of those tests is that a *particular*
malformed feed or a *particular* Torrentio title still parses — a live fetch
would test the publisher's uptime instead.

The HTTP tests start a real server on a scratch port and talk to it over
loopback, so routing, JSON shapes and the failure paths are exercised as the
launcher sees them.
"""

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

HTPC_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HTPC_DIR / "server"))

import channels          # noqa: E402
import feeds             # noqa: E402
import mpvipc            # noqa: E402
import stremio           # noqa: E402


# --- channels ----------------------------------------------------------------

M3U_SAMPLE = """#EXTM3U
#EXTINF:-1 tvg-chno="101" tvg-logo="x.png" group-title="MK",MRT 1
http://example.com/mrt1.m3u8
# a comment — geo-blocked outside MK
#EXTINF:-1 tvg-chno="103",Telma
http://example.com/telma.m3u8
#EXTINF:-1,No Number Here
http://example.com/orphan.m3u8
#EXTINF:-1 tvg-chno="102",Kanal 5
http://example.com/k5.m3u8
"""


class TestChannels(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile("w", suffix=".m3u", delete=False)
        self.tmp.write(M3U_SAMPLE)
        self.tmp.close()
        self.path = self.tmp.name

    def tearDown(self):
        os.unlink(self.path)

    def test_parses_and_sorts_by_number(self):
        got = channels.load(self.path)
        self.assertEqual([c["no"] for c in got], [101, 102, 103])
        self.assertEqual(got[0]["name"], "MRT 1")
        self.assertEqual(got[0]["url"], "http://example.com/mrt1.m3u8")

    def test_entry_without_a_number_is_skipped(self):
        """A channel with no tvg-chno has no identity — auto-assigning one
        would move it every time the file was edited."""
        self.assertNotIn("No Number Here", [c["name"] for c in channels.load(self.path)])

    def test_missing_file_is_empty_not_an_error(self):
        self.assertEqual(channels.load("/nonexistent/channels.m3u"), [])

    def test_real_repo_file_parses(self):
        got = channels.load()
        self.assertTrue(got, "cabletv/channels.m3u parsed to nothing")
        self.assertTrue(all(c["url"].startswith(("http", "av://", "rtmp")) for c in got),
                        "a channel has no usable URL")
        nos = [c["no"] for c in got]
        self.assertEqual(len(nos), len(set(nos)), "duplicate channel numbers")


# --- feeds -------------------------------------------------------------------

RSS_GOOD = b"""<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel><title>TIME.mk</title>
<item><title>\xd0\x92\xd0\xbb\xd0\xb0\xd0\xb4\xd0\xb0\xd1\x82\xd0\xb0 &amp; \xd0\xbc\xd0\xb5\xd1\x80\xd0\xba\xd0\xb8\xd1\x82\xd0\xb5</title><link>http://a/1</link></item>
<item><title><![CDATA[Vardar   win   the   derby]]></title><link>http://a/2</link></item>
</channel></rss>"""

# A real-world shape: CDATA, namespaces, and an entity that is not escaped.
RSS_MESSY = b"""<rss><channel>
<item><title><![CDATA[Bad & ugly]]></title></item>
<item><title>Unclosed & broken</title></item>
</channel></rss>"""

CLOUDFLARE = b"<!DOCTYPE html><html lang=\"en-US\"><head><title>Just a moment...</title>"


class TestFeeds(unittest.TestCase):
    def test_parses_titles_and_unescapes(self):
        items = feeds._parse_xml(RSS_GOOD)
        self.assertEqual(len(items), 2)
        self.assertIn("&", items[0]["title"])          # &amp; -> &
        self.assertEqual(items[1]["title"], "Vardar win the derby")

    def test_collapses_whitespace_to_one_line(self):
        """A headline is one row everywhere in this UI, never wrapped."""
        items = feeds._parse_xml(RSS_GOOD)
        self.assertNotIn("\n", items[1]["title"])
        self.assertNotIn("  ", items[1]["title"])

    def test_loose_parser_handles_what_elementtree_rejects(self):
        with self.assertRaises(Exception):
            feeds.ET.fromstring(RSS_MESSY.decode() + "<unclosed>")
        items = feeds._parse_loose(RSS_MESSY.decode())
        self.assertEqual([i["title"] for i in items], ["Bad & ugly", "Unclosed & broken"])

    def test_host_allowlist(self):
        """The proxy takes a URL from the page; without a leash it is an open
        relay for anything on the box's network."""
        self.assertTrue(feeds.allowed("https://time.mk/rss/sport"))
        self.assertTrue(feeds.allowed("https://www.makthes.gr/feed"))
        self.assertFalse(feeds.allowed("https://evil.example.com/feed"))
        self.assertFalse(feeds.allowed("http://127.0.0.1:8484/config"))
        self.assertFalse(feeds.allowed("not a url"))

    def test_disallowed_host_raises_before_any_request(self):
        with self.assertRaises(feeds.FeedError):
            feeds.fetch("https://evil.example.com/feed")

    def test_cloudflare_challenge_is_recognised(self):
        """thestival.gr answers 403 with a challenge page. A feed that is
        actually an HTML page must say so, not parse to zero headlines."""
        text = CLOUDFLARE.decode()
        self.assertIn("<html", text[:400].lower())


# --- stremio -----------------------------------------------------------------

class TestStremioRanking(unittest.TestCase):
    def rank(self, title):
        return stremio._stream_rank({"name": "Torrentio", "title": title})

    def test_prefers_more_seeders(self):
        many = self.rank("Film 1080p x264\n👤 400 💾 2GB")
        few = self.rank("Film 1080p x264\n👤 12 💾 2GB")
        self.assertLess(many, few)

    def test_oversized_sorts_last(self):
        """Constraint 11: 2160p is not 'better quality' on a 3B+, it is a
        slideshow. It sorts last but is not dropped — if it is the only copy,
        playing it badly beats 'no streams found'."""
        big = self.rank("Film 2160p HDR\n👤 900")
        ok = self.rank("Film 1080p x264\n👤 5")
        self.assertLess(ok, big)

    def test_hevc_deprioritised_when_not_allowed(self):
        hevc = self.rank("Film 1080p x265 HEVC\n👤 500")
        h264 = self.rank("Film 1080p x264\n👤 50")
        self.assertLess(h264, hevc)

    def test_unknown_resolution_is_not_excluded(self):
        self.assertEqual(self.rank("Film WEB-DL\n👤 30")[0], 0)

    def test_meta_row_shape(self):
        row = stremio._meta_row({
            "id": "tt1234567", "name": "Dune", "poster": "http://p/x.jpg",
            "releaseInfo": "2021", "imdbRating": "8.0", "runtime": "155 min",
            "description": " Spice. ", "genres": ["Sci-Fi"],
        })
        self.assertEqual(row["id"], "tt1234567")
        self.assertEqual(row["year"], "2021")
        self.assertEqual(row["runtime"], 155)      # "155 min" -> 155
        self.assertEqual(row["plot"], "Spice.")

    def test_runtime_parsing_survives_junk(self):
        self.assertEqual(stremio._minutes(None), 0)
        self.assertEqual(stremio._minutes(""), 0)
        self.assertEqual(stremio._minutes("1h 42min"), 1)   # first number wins
        self.assertEqual(stremio._minutes(142), 142)


# --- mpv IPC -----------------------------------------------------------------

class FakeMpv:
    """A unix socket that speaks just enough of mpv's IPC to test the bridge:
    one JSON object per line, replies tagged by request_id, and an unsolicited
    event injected first so the reader has to skip it."""

    def __init__(self, path, error=None):
        self.path = path
        self.error = error
        self.received = []
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        self.sock.listen(4)
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.running = True
        self.thread.start()

    def _serve(self):
        while self.running:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            try:
                data = conn.recv(65536)
                if not data:
                    continue
                req = json.loads(data.decode().strip().splitlines()[0])
                self.received.append(req["command"])
                # An event first: the bridge must skip anything without our id.
                conn.sendall(json.dumps({"event": "playback-restart"}).encode() + b"\n")
                reply = {"request_id": req["request_id"],
                         "error": self.error or "success", "data": "pong"}
                conn.sendall(json.dumps(reply).encode() + b"\n")
            except (ValueError, OSError, KeyError, IndexError):
                pass
            finally:
                conn.close()

    def close(self):
        self.running = False
        try:
            self.sock.close()
        except OSError:
            pass
        try:
            os.unlink(self.path)
        except OSError:
            pass


class TestMpvIPC(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "mpv.sock")
        self.old = mpvipc.SOCKET_PATH
        mpvipc.SOCKET_PATH = self.path

    def tearDown(self):
        mpvipc.SOCKET_PATH = self.old

    def test_no_socket_is_a_sentence_not_a_crash(self):
        """mpv not being up yet is normal during boot, not an error worth
        putting on the TV as a traceback."""
        with self.assertRaises(mpvipc.MpvError) as cm:
            mpvipc.command("get_property", "pause")
        self.assertIn("not running", str(cm.exception))

    def test_roundtrip_skips_events_and_returns_data(self):
        fake = FakeMpv(self.path)
        try:
            self.assertEqual(mpvipc.command("get_property", "pause"), "pong")
            self.assertEqual(fake.received[0], ["get_property", "pause"])
        finally:
            fake.close()

    def test_load_sends_loadfile(self):
        fake = FakeMpv(self.path)
        try:
            mpvipc.load("http://example.com/x.m3u8")
            self.assertEqual(fake.received[0],
                             ["loadfile", "http://example.com/x.m3u8", "replace"])
        finally:
            fake.close()

    def test_mpv_error_is_surfaced(self):
        fake = FakeMpv(self.path, error="property not found")
        try:
            with self.assertRaises(mpvipc.MpvError):
                mpvipc.command("get_property", "nope")
        finally:
            fake.close()

    def test_get_swallows_errors_and_returns_default(self):
        self.assertEqual(mpvipc.get("pause", "fallback"), "fallback")

    def test_state_when_unavailable(self):
        self.assertEqual(mpvipc.state(), {"available": False})


# --- HTTP --------------------------------------------------------------------

def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class TestServerHTTP(unittest.TestCase):
    """Starts the real server.py and talks to it over loopback."""

    @classmethod
    def setUpClass(cls):
        cls.port = free_port()
        env = dict(os.environ, HTPC_PORT=str(cls.port))
        cls.proc = subprocess.Popen(
            [sys.executable, str(HTPC_DIR / "server" / "server.py")],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for _ in range(100):
            try:
                cls.get("/config")
                return
            except Exception:
                time.sleep(0.05)
        out = ""
        try:
            cls.proc.kill()
            out = cls.proc.stdout.read()
        except Exception:
            pass
        raise AssertionError("server did not start:\n" + out)

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        try:
            cls.proc.wait(5)
        except subprocess.TimeoutExpired:
            cls.proc.kill()

    @classmethod
    def url(cls, path):
        return "http://127.0.0.1:%d%s" % (cls.port, path)

    @classmethod
    def get(cls, path):
        with urllib.request.urlopen(cls.url(path), timeout=5) as r:
            return r.status, json.loads(r.read())

    @classmethod
    def raw(cls, path):
        with urllib.request.urlopen(cls.url(path), timeout=5) as r:
            return r.status, r.read(), r.headers.get("Content-Type", "")

    @classmethod
    def post(cls, path, body=None):
        data = json.dumps(body).encode() if body is not None else b""
        req = urllib.request.Request(
            cls.url(path), data=data,
            headers={"content-type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_serves_the_ui(self):
        status, body, ctype = self.raw("/")
        self.assertEqual(status, 200)
        self.assertIn("text/html", ctype)
        self.assertIn(b"app.js", body)

    def test_serves_theme_and_module(self):
        """The UI is no longer one file — theme.json and app.js have to be
        reachable or the page loads to a black screen."""
        for path, expect in (("/theme.json", b"tokens"), ("/app.js", b"dotSVG"),
                             ("/theme.js", b"loadTheme")):
            status, body, _ = self.raw(path)
            self.assertEqual(status, 200, path)
            self.assertIn(expect, body, path)

    def test_theme_json_is_valid_and_complete(self):
        _, body, _ = self.raw("/theme.json")
        theme = json.loads(body)
        for section in ("tokens", "motion", "layout", "copy", "profiles"):
            self.assertIn(section, theme)
        for group in ("color", "font", "size", "track", "space", "line"):
            self.assertIn(group, theme["tokens"])

    def test_static_cannot_escape_the_launcher_directory(self):
        for attempt in ("/../server/config.json", "/..%2fserver%2fconfig.json",
                        "/../../etc/passwd"):
            try:
                status, _, _ = self.raw(attempt)
            except urllib.error.HTTPError as e:
                status = e.code
            self.assertNotEqual(status, 200, "path traversal served %s" % attempt)

    def test_channels(self):
        status, body = self.get("/channels")
        self.assertEqual(status, 200)
        self.assertIsInstance(body, list)
        if body:
            self.assertEqual(set(body[0]), {"no", "name", "url"})

    def test_news_rejects_a_host_not_on_the_allowlist(self):
        status, body = self.get("/news?url=https://evil.example.com/feed")
        self.assertEqual(status, 200)          # a broken source is a row, not a 5xx
        self.assertEqual(body["items"], [])
        self.assertIn("error", body)

    def test_news_without_a_url(self):
        status, body = self.get("/news")
        self.assertEqual(status, 200)
        self.assertIn("error", body)

    def test_player_state_without_mpv(self):
        status, body = self.get("/player/state")
        self.assertEqual(status, 200)
        self.assertFalse(body["available"])

    def test_player_load_without_a_url_is_a_sentence(self):
        status, body = self.post("/player/load", {})
        self.assertEqual(status, 400)
        self.assertFalse(body["ok"])
        self.assertEqual(body["msg"], "no url")

    def test_player_load_without_mpv_says_so(self):
        status, body = self.post("/player/load", {"url": "http://x/y.m3u8"})
        self.assertEqual(status, 502)
        self.assertIn("not running", body["msg"])

    def test_play_without_an_id(self):
        status, body = self.post("/play", {"kind": "movie"})
        self.assertEqual(status, 400)
        self.assertEqual(body["msg"], "no id")

    def test_unknown_launch_names_the_app(self):
        """No demo mode: a failure says what actually went wrong."""
        status, body = self.post("/launch/nope")
        self.assertEqual(status, 400)
        self.assertIn("nope", body["msg"])

    def test_home_works_without_mpv(self):
        """/home must never fail because the player is not up — it is the one
        button that has to always work."""
        status, body = self.post("/home")
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])

    def test_404_is_json(self):
        try:
            self.get("/nope")
            self.fail("expected 404")
        except urllib.error.HTTPError as e:
            self.assertEqual(e.code, 404)
            self.assertIn("error", json.loads(e.read()))


if __name__ == "__main__":
    unittest.main(verbosity=2)
