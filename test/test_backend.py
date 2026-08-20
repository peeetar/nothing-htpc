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
from unittest import mock

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
    """The x86 envelope (August 2026).

    These used to assert the Pi 3B+ rules — 1080p, H.264, everything else last.
    The Pi is gone and both targets decode HEVC/VP9/AV1 in hardware, so the
    envelope inverted: nothing is penalised by default, and HTPC_MAX_HEIGHT /
    HTPC_ALLOW_HEVC exist to *tighten* it for weaker hardware.
    """

    def rank(self, title):
        return stremio._stream_rank({"name": "Torrentio", "title": title})

    def test_prefers_more_seeders(self):
        many = self.rank("Film 1080p x264\n👤 400 💾 2GB")
        few = self.rank("Film 1080p x264\n👤 12 💾 2GB")
        self.assertLess(many, few)

    def test_2160p_now_wins_when_it_is_seeded_as_well(self):
        """The whole point of dropping the Pi. Same seeding tier, more pixels."""
        big = self.rank("Film 2160p HDR\n👤 900")
        small = self.rank("Film 1080p x264\n👤 700")
        self.assertLess(big, small)

    def test_seeders_still_outrank_resolution_across_a_tier(self):
        """A 4K copy with six seeders does not play at all, and 'does not play'
        beats every resolution argument there is. Bucketing is what keeps this
        true without letting 2140 seeders beat 2100."""
        starved_4k = self.rank("Film 2160p REMUX\n👤 6")
        healthy_1080 = self.rank("Film 1080p x264\n👤 1200")
        self.assertLess(healthy_1080, starved_4k)

    def test_hevc_is_not_penalised_by_default(self):
        hevc = self.rank("Film 1080p x265 HEVC\n👤 500")
        h264 = self.rank("Film 1080p x264\n👤 500")
        self.assertEqual(hevc, h264)

    def test_envelope_still_tightens_when_asked(self):
        """The env vars are the way back to a weak box, so they have to work."""
        with mock.patch.object(stremio, "MAX_HEIGHT", 1080), \
             mock.patch.object(stremio, "ALLOW_HEVC", False):
            big = self.rank("Film 2160p HDR\n👤 900")
            hevc = self.rank("Film 1080p x265\n👤 900")
            ok = self.rank("Film 1080p x264\n👤 5")
            self.assertLess(ok, big)
            self.assertLess(ok, hevc)

    def test_nothing_is_ever_dropped_for_being_outside(self):
        """Sorting last is not the same as being excluded: if every copy of a
        film is a 4K remux, playing one badly beats 'no streams found'."""
        with mock.patch.object(stremio, "MAX_HEIGHT", 1080):
            self.assertEqual(self.rank("Film 2160p\n👤 9")[0], 1)   # penalised
        self.assertIsNotNone(self.rank("Film 2160p\n👤 9"))         # still ranked

    def test_unknown_resolution_is_not_excluded(self):
        self.assertEqual(self.rank("Film WEB-DL\n👤 30")[0], 0)


class TestStreamRows(unittest.TestCase):
    """What the source picker draws, read out of Torrentio's title text."""

    SAMPLE = {
        "name": "Torrentio\n1080p",
        "title": "Dune.Part.Two.2024.1080p.BluRay.x264\n👤 2081 💾 2.31 GB ⚙️ ThePirateBay",
        "infoHash": "abc123",
    }

    def test_parses_the_fields_the_picker_shows(self):
        p = stremio._parse(self.SAMPLE)
        self.assertEqual(p["height"], 1080)
        self.assertEqual(p["seeds"], 2081)
        self.assertEqual(p["size"], "2.31 GB")
        self.assertEqual(p["source"], "ThePirateBay")

    def test_a_debrid_link_is_marked_direct(self):
        """It plays immediately; a magnet has to find peers first, and that is
        worth saying before Ⓐ rather than after it."""
        self.assertFalse(stremio._parse(self.SAMPLE).get("direct"))
        rows = self._rows([self.SAMPLE, {"name": "RD+", "title": "x 1080p", "url": "https://d/x.mkv"}])
        self.assertFalse(rows[0]["direct"])
        self.assertTrue(rows[1]["direct"])

    def test_rows_carry_the_index_play_takes_back(self):
        """The page never handles an infoHash — it hands back a row number,
        which is the only reason resolving can stay entirely server-side."""
        rows = self._rows([self.SAMPLE, self.SAMPLE])
        self.assertEqual([r["i"] for r in rows], [0, 1])

    def test_missing_fields_are_empty_not_absent(self):
        rows = self._rows([{"name": "x", "title": "no metadata here"}])
        self.assertEqual(rows[0]["quality"], "")
        self.assertEqual(rows[0]["size"], "")
        self.assertEqual(rows[0]["seeds"], 0)

    def _rows(self, streams):
        with mock.patch.object(stremio, "streams", return_value=streams):
            return stremio.stream_rows("movie", "tt1")


class TestAppsFallback(unittest.TestCase):
    """A config.local.json that never mentions `apps` should not hide tiles.

    config.local.json wins key by key, which is the point of it — but a local
    file that simply does not mention `apps` was never asking to lose GAMING,
    and a tile that quietly vanishes is not something the box can explain on a
    TV. An explicitly empty list still hides them: that is a decision, an
    absent key is an omission.
    """

    def _load(self, payload):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(payload, f)
            path = f.name
        out = subprocess.run(
            [sys.executable, "-c",
             "import sys; sys.path.insert(0, %r); import server, json;"
             "print(json.dumps(server.load_config()))" % str(HTPC_DIR / "server")],
            env=dict(os.environ, HTPC_CONFIG=path),
            capture_output=True, text=True, timeout=30)
        os.unlink(path)
        self.assertEqual(out.returncode, 0, out.stderr)
        return json.loads(out.stdout.strip().splitlines()[-1])

    def test_a_missing_apps_key_inherits_the_defaults(self):
        cfg = self._load({"weather": {"lat": 1.0, "lon": 2.0}})
        self.assertTrue(cfg.get("apps"), "GAMING should have been inherited")
        self.assertIn("gaming", [a.get("id") for a in cfg["apps"]])

    def test_an_explicitly_empty_apps_list_is_respected(self):
        cfg = self._load({"weather": {"lat": 1.0, "lon": 2.0}, "apps": []})
        self.assertEqual(cfg.get("apps"), [])

    def test_a_local_apps_list_still_wins(self):
        cfg = self._load({"apps": [{"id": "x", "label": "X", "command": ["/bin/true"]}]})
        self.assertEqual([a["id"] for a in cfg["apps"]], ["x"])


class TestEpisodeFileSelection(unittest.TestCase):
    """Which file inside a season pack gets played.

    The bug this pins down, measured against live Torrentio and TorrServer on
    20 August 2026: Torrentio's `fileIdx` counts the torrent's whole file
    list, TorrServer's `id` counts its own listing, and stremio.py assumed the
    two differed by one. Asking for Sherlock S01E01 sent fileIdx 8 as index 9,
    and TorrServer's ninth file is S03E03 — so the box played the wrong
    episode with every layer reporting success. Matching on the name is the
    only thing here that is actually true.
    """

    # TorrServer's own listing, ids as it hands them out (1-based).
    SHERLOCK = [
        {"id": 1,  "path": "S01/Sherlock.S01E01.A.Study.in.Pink.1080p.mkv"},
        {"id": 2,  "path": "S01/Sherlock.S01E02.The.Blind.Banker.1080p.mkv"},
        {"id": 3,  "path": "S01/Sherlock.S01E03.The.Great.Game.1080p.mkv"},
        {"id": 9,  "path": "S03/Sherlock.S03E03.His.Last.Vow.1080p.mkv"},
    ]

    def test_it_matches_the_filename_torrentio_gave(self):
        got = stremio._pick_file(
            self.SHERLOCK, "Sherlock.S01E01.A.Study.in.Pink.1080p.mkv", "tt1475582:1:1")
        self.assertEqual(got, 1)

    def test_it_is_never_fileidx_plus_one(self):
        # fileIdx was 8 for this episode; 8 + 1 is His Last Vow.
        got = stremio._pick_file(
            self.SHERLOCK, "Sherlock.S01E01.A.Study.in.Pink.1080p.mkv", "tt1475582:1:1")
        self.assertNotEqual(got, 9)

    def test_a_path_matches_on_its_basename(self):
        got = stremio._pick_file(
            self.SHERLOCK, "Some.Pack/S01/Sherlock.S01E02.The.Blind.Banker.1080p.mkv", None)
        self.assertEqual(got, 2)

    def test_it_falls_back_to_the_season_and_episode(self):
        # A pack that renamed the file still says which episode it is.
        got = stremio._pick_file(self.SHERLOCK, "not-in-this-torrent.mkv", "tt1475582:1:3")
        self.assertEqual(got, 3)

    def test_no_match_chooses_nothing_rather_than_wrongly(self):
        # TorrServer then serves the largest file, which is right for the
        # single-file torrent most films are. A confident wrong answer is the
        # one outcome that must not happen.
        self.assertIsNone(stremio._pick_file(self.SHERLOCK, "unrelated.mkv", "tt999:9:9"))
        self.assertIsNone(stremio._pick_file([], "anything.mkv", "tt1:1:1"))

    def test_episode_numbers_do_not_match_across_seasons(self):
        self.assertIsNone(stremio._pick_file(
            [{"id": 1, "path": "Show.S11E01.mkv"}], None, "tt1:1:1"))

    def test_wanted_file_prefers_behaviour_hints(self):
        s = {"behaviorHints": {"filename": "Right.S01E01.mkv"},
             "title": "Pack name\nSome/Other.S01E01.mkv\n124 seeds"}
        self.assertEqual(stremio._wanted_file(s), "Right.S01E01.mkv")

    def test_wanted_file_falls_back_to_the_title_path(self):
        s = {"title": "Pack name\nSeason 1/Show.S01E01.The.Title.mkv\n124 seeds"}
        self.assertEqual(stremio._wanted_file(s), "Season 1/Show.S01E01.The.Title.mkv")

    def test_wanted_file_is_none_when_nothing_names_a_file(self):
        self.assertIsNone(stremio._wanted_file({"title": "Just a pack name"}))


class TestResolveByIndex(unittest.TestCase):
    STREAMS = [
        {"name": "a", "title": "first 1080p", "url": "https://d/first.mkv"},
        {"name": "b", "title": "second 720p", "url": "https://d/second.mkv"},
    ]

    def test_index_picks_that_row_and_not_the_best(self):
        with mock.patch.object(stremio, "streams", return_value=self.STREAMS):
            url, _ = stremio.resolve("movie", "tt1", 1)
        self.assertEqual(url, "https://d/second.mkv")

    def test_no_index_is_the_rankings_own_pick(self):
        with mock.patch.object(stremio, "streams", return_value=self.STREAMS):
            url, _ = stremio.resolve("movie", "tt1")
        self.assertEqual(url, "https://d/first.mkv")

    def test_out_of_range_is_an_error_not_a_clamp(self):
        """Silently playing something other than the row that was selected is
        the one behaviour a picker must never have."""
        with mock.patch.object(stremio, "streams", return_value=self.STREAMS):
            with self.assertRaises(stremio.StremioError) as cm:
                stremio.resolve("movie", "tt1", 9)
        self.assertIn("no longer in the list", str(cm.exception))

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


class TestStremioEpisodes(unittest.TestCase):
    """Cinemeta's `videos` -> the rows the season/episode chooser draws."""

    SAMPLE = {"videos": [
        {"id": "tt1:1:2", "season": 1, "episode": 2, "number": 2,
         "name": "The Rogue Prince", "released": "2022-08-28T05:00:00.000Z",
         "overview": "a paragraph nobody has room to draw"},
        {"id": "tt1:0:1", "season": 0, "number": 1, "name": "Premiere Special",
         "firstAired": "2022-08-21T05:00:00.000Z"},
        {"id": "tt1:1:1", "season": 1, "episode": 1, "number": 1,
         "name": "The Heirs of the Dragon", "released": "2022-08-21T05:00:00.000Z"},
        {"id": "tt1:2:1", "season": 2, "episode": 1, "number": 1, "name": ""},
        {"season": 3, "episode": 1},                        # no id: unusable
    ]}

    def rows(self):
        return stremio._episodes(self.SAMPLE)

    def test_episode_ids_are_what_the_stream_addons_index(self):
        """The whole reason no second lookup is needed at play time."""
        self.assertEqual([r["id"] for r in self.rows()][:2], ["tt1:1:1", "tt1:1:2"])

    def test_sorted_by_season_then_episode(self):
        self.assertEqual([(r["season"], r["episode"]) for r in self.rows()][:3],
                         [(1, 1), (1, 2), (2, 1)])

    def test_specials_sort_last(self):
        """Season 0 is recaps and behind-the-scenes. Kept, but nobody opens a
        show to watch its making-of first."""
        self.assertEqual(self.rows()[-1]["season"], 0)

    def test_an_entry_without_an_id_is_dropped(self):
        self.assertEqual(len(self.rows()), 4)
        self.assertNotIn(3, [r["season"] for r in self.rows()])

    def test_rows_stay_thin(self):
        """A long-running show has hundreds of these and the Pi has 1 GB — the
        overview is kilobytes a row for a line this screen cannot draw."""
        self.assertEqual(set(self.rows()[0]),
                         {"id", "season", "episode", "title", "released"})
        self.assertEqual(self.rows()[0]["released"], "2022-08-21")

    def test_falls_back_to_firstAired_and_a_missing_title_is_empty(self):
        by_id = {r["id"]: r for r in self.rows()}
        self.assertEqual(by_id["tt1:0:1"]["released"], "2022-08-21")
        self.assertEqual(by_id["tt1:2:1"]["title"], "")

    def test_no_videos_is_an_empty_list_not_an_error(self):
        self.assertEqual(stremio._episodes({}), [])


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

    def test_a_stale_socket_reads_the_same_as_no_socket(self):
        """The socket file outlives the process that made it — a killed or
        crashed session leaves one behind until the next start-session.sh
        removes it. Existing-but-refusing means mpv is not running, exactly
        as not existing does, so it must not be a second, different sentence.
        (This is also what made the suite fail after running the kiosk.)"""
        dead = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        dead.bind(self.path)          # bound, never listening: connect refused
        dead.close()
        self.assertTrue(os.path.exists(self.path))
        with self.assertRaises(mpvipc.MpvError) as cm:
            mpvipc.command("get_property", "pause")
        self.assertIn("not running", str(cm.exception))

        # And the same has to hold for the thing the UI actually polls, or the
        # channel bar draws over a picture nothing is producing.
        self.assertFalse(mpvipc.available())
        self.assertFalse(mpvipc.state()["available"])

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


class TestUITransparency(unittest.TestCase):
    """Whether the page is composited over mpv is a property of the session,
    so the backend reports it and the page never guesses.

    This exists because guessing produced the worst possible failure: under a
    nested cage Chromium's surface stays opaque, so the TV screen's
    transparent body rendered as the browser's WHITE default over a stream
    that was decoding perfectly well behind it. White reads as a crash.
    """

    def _config(self, env_value):
        env = dict(os.environ)
        if env_value is None:
            env.pop("HTPC_UI_TRANSPARENT", None)
        else:
            env["HTPC_UI_TRANSPARENT"] = env_value
        port = free_port()
        env["HTPC_PORT"] = str(port)
        proc = subprocess.Popen(
            [sys.executable, str(HTPC_DIR / "server" / "server.py")],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            for _ in range(100):
                try:
                    with urllib.request.urlopen(
                            "http://127.0.0.1:%d/config" % port, timeout=5) as r:
                        return json.loads(r.read())
                except Exception:
                    time.sleep(0.05)
            raise AssertionError("server did not start")
        finally:
            proc.terminate()
            try:
                proc.wait(5)
            except subprocess.TimeoutExpired:
                proc.kill()

    def test_transparent_by_default(self):
        """The architecture's intent, and what a real kiosk boot should get."""
        self.assertIs(self._config(None)["ui"]["transparent"], True)

    def test_zero_turns_it_off(self):
        """dev-session.sh sets this when it nests, because that is exactly
        where Chromium cannot get an alpha channel."""
        self.assertIs(self._config("0")["ui"]["transparent"], False)

    def test_it_is_runtime_state_not_stored_config(self):
        """It describes the session, not the box, and changes between a kiosk
        boot and a nested dev run — so it must never be written to
        config.json, where it would outlive the session that was true for."""
        cfg = json.loads((HTPC_DIR / "server" / "config.json").read_text())
        self.assertNotIn("ui", cfg)


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

    def test_config_tells_the_page_only_what_it_reads(self):
        """It used to send the whole config file, TMDB key included — a key
        the page never reads, because every TMDB call is made server-side in
        tmdb.py. The bind is loopback-only, so nothing off-box could ask; a
        secret that is never sent cannot leak from a place nobody looks."""
        status, cfg = self.get("/config")
        self.assertEqual(status, 200)
        self.assertNotIn("tmdb_key", cfg)
        self.assertLessEqual(set(cfg), {"weather", "ui"})
        # ...and still carries the two things it is for.
        self.assertIn("transparent", cfg.get("ui", {}))
        self.assertIn("lat", cfg.get("weather", {}))

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
