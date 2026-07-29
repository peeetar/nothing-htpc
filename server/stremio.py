#!/usr/bin/env python3
"""
Stremio-protocol catalogue and stream client.

This replaced server/movieapi.py, which logged into ee3.me, scraped its
private API and kept a session alive on a separate LXC box. The addon
protocol is plain JSON over HTTP with no auth and no keys, so all of that
went away and this file can live on the Pi under constraint 7 (stdlib only).

Three upstreams, none of which need an account:

  Cinemeta   v3-cinemeta.strem.io   catalogue + metadata + posters
  Torrentio  torrentio.strem.io     infoHash per title, ranked by seeders
  TorrServer 127.0.0.1:8090         turns an infoHash into an HTTP stream

The split matters: Cinemeta answers "what films exist and what do they look
like", Torrentio answers "where is this one", and TorrServer answers "give me
something mpv can open". Only the last one is heavy, and only the last one is
optional — with a debrid key in TORRENTIO_OPTS, Torrentio hands back direct
HTTPS URLs and TorrServer is never asked anything.

Nothing here caches to disk. cabletv/library.tsv was a cache that the box
rewrote and git kept fighting over; the catalogue is a live call with an
in-memory TTL instead.
"""

import json
import os
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

import tmdb

CINEMETA = os.environ.get("CINEMETA_URL", "https://v3-cinemeta.strem.io").rstrip("/")
TORRSERVER = os.environ.get("TORRSERVER_URL", "http://127.0.0.1:8090").rstrip("/")

# Stream addons, tried in order until one answers with streams.
#
# This is a list and not a constant on purpose. torrentio.strem.io — the
# address every guide still gives — stopped resolving entirely by July 2026
# while strem.io itself stayed up, and the same thing happened three times in
# a row to the Greek news source on the NEWS screen. Public endpoints for this
# kind of thing are weather, not infrastructure. One dead host must cost a
# retry, not a rebuild.
#
# Override with HTPC_STREAM_ADDONS as a comma-separated list.
STREAM_ADDONS = [
    u.strip().rstrip("/") for u in os.environ.get(
        "HTPC_STREAM_ADDONS",
        "https://torrentio.strem.fun,https://comet.elfhosted.com",
    ).split(",") if u.strip()
]

# Torrentio's config segment. Empty means public trackers and magnets. Put a
# debrid key here — "realdebrid=XXXX" — and it returns direct HTTPS links
# instead, which is the one upgrade that removes BitTorrent from the box.
TORRENTIO_OPTS = os.environ.get("TORRENTIO_OPTS", "").strip("/")

# Playback envelope. On the Pi this is a correctness rule, not a preference:
# a 2160p HEVC remux is a slideshow on a 3B+ (CLAUDE.md constraint 11). On
# x86 hardware it relaxes — it is a profile value, not a law.
MAX_HEIGHT = int(os.environ.get("HTPC_MAX_HEIGHT", "1080"))
ALLOW_HEVC = os.environ.get("HTPC_ALLOW_HEVC", "") not in ("", "0")

TIMEOUT = float(os.environ.get("HTPC_HTTP_TIMEOUT", "10"))
CATALOG_TTL = float(os.environ.get("HTPC_CATALOG_TTL", "900"))   # 15 min

_cache = {}
_cache_lock = threading.Lock()


class StremioError(Exception):
    """Carries a sentence a person on a sofa can act on — it goes straight to
    the TV as a toast, so it must never be a stack trace or an HTTP code."""


def _get(url, timeout=TIMEOUT):
    req = urllib.request.Request(url, headers={
        "user-agent": "nothing-htpc/1.0",
        "accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read(8_000_000).decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        raise StremioError("%s returned HTTP %d" % (_host(url), e.code)) from e
    except urllib.error.URLError as e:
        raise StremioError("cannot reach %s" % _host(url)) from e
    except (ValueError, TimeoutError) as e:
        raise StremioError("bad reply from %s" % _host(url)) from e


def _host(url):
    try:
        return urllib.parse.urlsplit(url).netloc or url
    except ValueError:
        return url


def _cached(key, ttl, produce):
    now = time.monotonic()
    with _cache_lock:
        hit = _cache.get(key)
        if hit and now - hit[0] < ttl:
            return hit[1]
    value = produce()
    with _cache_lock:
        _cache[key] = (now, value)
    return value


# --- catalogue ---------------------------------------------------------------

def _meta_row(m):
    """One Cinemeta meta -> the shape the poster grid draws.

    `id` is an IMDb id (tt0111161) and stays one all the way through: it is
    what Torrentio is asked about at play time, so nothing has to be resolved
    twice or stored between screens.
    """
    return {
        "id": m.get("imdb_id") or m.get("id"),
        "title": m.get("name") or "",
        "year": str(m.get("releaseInfo") or "")[:4],
        "poster": m.get("poster") or "",
        "rating": str(m.get("imdbRating") or ""),
        "runtime": _minutes(m.get("runtime")),
        "plot": (m.get("description") or "").strip(),
        "genres": m.get("genres") or [],
        # Cinemeta hands over TMDB's own id, so enriching a title needs no
        # search step — see server/tmdb.py.
        "tmdb_id": m.get("moviedb_id") or None,
    }


def _cinemeta_credits(m):
    """The credits Cinemeta gives away: a director, a writer, three cast.

    This is what the detail screen shows when there is no TMDB key. No
    producer, because Cinemeta does not carry one.
    """
    return {
        "director": list(m.get("director") or [])[:3],
        "writer": list(m.get("writer") or [])[:3],
        "cast": list(m.get("cast") or [])[:5],
    }


def _minutes(runtime):
    """Cinemeta gives runtime as a human string ("142 min"), not a number."""
    if not runtime:
        return 0
    m = re.search(r"(\d+)", str(runtime))
    return int(m.group(1)) if m else 0


def catalog(kind="movie", catalog_id="top", skip=0):
    """A page of the catalogue. kind is 'movie' or 'series'.

    The UI calls this 'show'; Stremio calls it 'series'. The translation
    happens here so the rest of the codebase only ever says one of them.
    """
    kind = "series" if kind in ("show", "series") else "movie"
    key = ("catalog", kind, catalog_id, skip)

    def produce():
        url = "%s/catalog/%s/%s%s.json" % (
            CINEMETA, kind, catalog_id, "/skip=%d" % skip if skip else "")
        data = _get(url)
        rows = [_meta_row(m) for m in (data.get("metas") or [])]
        return [r for r in rows if r["id"] and r["title"]]

    return _cached(key, CATALOG_TTL, produce)


def meta(kind, imdb_id):
    """Full metadata for one title — the detail screen's plot and runtime.

    The grid already carries enough to draw a card, so this is only fetched
    when something is selected. That is deliberate: the old design shipped
    every field for every title in one TSV because the cursor could not wait
    on the network, and a grid that pages 24 at a time does not have that
    problem.
    """
    kind = "series" if kind in ("show", "series") else "movie"
    key = ("meta", kind, imdb_id)

    def produce():
        data = _get("%s/meta/%s/%s.json" % (CINEMETA, kind, imdb_id))
        m = data.get("meta")
        if not m:
            raise StremioError("no metadata for %s" % imdb_id)
        row = _meta_row(m)

        # Credits from Cinemeta, then overwritten by TMDB's fuller set if a key
        # is configured. Reviews only ever come from TMDB — Cinemeta has none.
        row["credits"] = _cinemeta_credits(m)
        row["reviews"] = []
        if tmdb.available() and row.get("tmdb_id"):
            better = tmdb.credits(kind, row["tmdb_id"])
            if better:
                # Keep a Cinemeta value where TMDB returned an empty list, so
                # a partial TMDB reply cannot make the panel worse than the
                # keyless one.
                row["credits"] = {k: (better.get(k) or row["credits"].get(k) or [])
                                  for k in ("director", "producer", "writer", "cast")}
            row["reviews"] = tmdb.reviews(kind, row["tmdb_id"])
        return row

    return _cached(key, CATALOG_TTL, produce)


# --- streams -----------------------------------------------------------------

_HEIGHT_RE = re.compile(r"(\d{3,4})p")
_HEVC_RE = re.compile(r"\b(hevc|x265|h\.?265)\b", re.I)
_SEEDS_RE = re.compile(r"(?:👤|seeders?[:\s])\s*(\d+)", re.I)


def _stream_rank(s):
    """Sort key: playable first, then by seeders. Lower is better.

    Torrentio puts quality and seeder count in the human-readable `title`,
    not in fields, so this reads them out of the string. A title that does
    not say its resolution is assumed fine rather than excluded — being
    conservative here means rejecting every stream for some films.
    """
    text = "%s %s" % (s.get("name") or "", s.get("title") or "")
    height = 0
    m = _HEIGHT_RE.search(text)
    if m:
        height = int(m.group(1))
    too_big = height > MAX_HEIGHT
    hevc = bool(_HEVC_RE.search(text)) and not ALLOW_HEVC
    seeds = 0
    m = _SEEDS_RE.search(text)
    if m:
        seeds = int(m.group(1))
    # Unplayable candidates sort last rather than being dropped: if the only
    # copies of a film are HEVC, playing one badly beats "no streams found".
    return (1 if too_big else 0, 1 if hevc else 0, -seeds)


def streams(kind, imdb_id):
    """Ask each addon in turn; the first one with streams wins.

    Errors from a dead host are collected rather than raised, so the message
    that reaches the TV describes the whole attempt ("no streams found")
    rather than whichever host happened to be first in the list.
    """
    kind = "series" if kind in ("show", "series") else "movie"
    opts = "/" + TORRENTIO_OPTS if TORRENTIO_OPTS else ""
    problems = []

    for base in STREAM_ADDONS:
        url = "%s%s/stream/%s/%s.json" % (base, opts, kind, imdb_id)
        try:
            data = _get(url, timeout=max(TIMEOUT, 20))
        except StremioError as e:
            problems.append(str(e))
            continue
        out = data.get("streams") or []
        if out:
            return sorted(out, key=_stream_rank)
        problems.append("%s has nothing for this title" % _host(base))

    raise StremioError("no streams found (%s)" % "; ".join(problems[:2]))


def resolve(kind, imdb_id):
    """Pick the best stream and return a URL mpv can open.

    Two shapes come back from Torrentio and both are handled here so callers
    never have to care which one they got:

      `url`       already playable (a debrid link). Returned as-is.
      `infoHash`  a torrent. Handed to TorrServer, which returns an HTTP URL.
    """
    best = streams(kind, imdb_id)[0]

    if best.get("url"):
        return best["url"], _label(best)

    info_hash = best.get("infoHash")
    if not info_hash:
        raise StremioError("stream has neither a URL nor an infoHash")

    idx = best.get("fileIdx")
    magnet = "magnet:?xt=urn:btih:%s" % info_hash
    return torrserver_stream(magnet, idx), _label(best)


def _label(s):
    """The one line the UI shows about what it picked — quality and source."""
    return re.sub(r"\s+", " ", "%s %s" % (s.get("name") or "", s.get("title") or "")).strip()[:120]


# --- TorrServer --------------------------------------------------------------

def torrserver_stream(magnet, file_idx=None):
    """Add a magnet to TorrServer and return the HTTP URL of its video.

    TorrServer is a single static Go binary. peerflix and webtorrent were
    both Node, both spawned their own player by default, and webtorrent
    served the film at a path that had to be discovered by scraping an index
    page. This is one POST and one predictable URL.
    """
    body = json.dumps({"action": "add", "link": magnet, "save_to_db": False}).encode()
    req = urllib.request.Request(
        TORRSERVER + "/torrents", data=body,
        headers={"content-type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            info = json.loads(r.read(1_000_000).decode("utf-8", "replace"))
    except urllib.error.URLError as e:
        raise StremioError(
            "torrserver is not running on %s" % _host(TORRSERVER)) from e
    except (ValueError, urllib.error.HTTPError) as e:
        raise StremioError("torrserver rejected the magnet") from e

    h = info.get("hash") or info.get("Hash")
    if not h:
        raise StremioError("torrserver did not return a hash")

    q = {"link": h, "play": ""}
    if file_idx is not None:
        # Torrentio's fileIdx is 0-based; TorrServer's index is 1-based.
        q["index"] = int(file_idx) + 1
    return "%s/stream?%s" % (TORRSERVER, urllib.parse.urlencode(q))


def torrserver_available():
    try:
        with urllib.request.urlopen(TORRSERVER + "/echo", timeout=2):
            return True
    except Exception:
        return False


if __name__ == "__main__":
    import sys
    what = sys.argv[1] if len(sys.argv) > 1 else "catalog"
    try:
        if what == "catalog":
            for r in catalog(sys.argv[2] if len(sys.argv) > 2 else "movie")[:10]:
                print("%-44s %-6s %-5s %s" % (r["title"][:44], r["year"], r["rating"], r["id"]))
        elif what == "streams":
            for s in streams("movie", sys.argv[2])[:10]:
                print(_label(s))
        elif what == "resolve":
            url, label = resolve("movie", sys.argv[2])
            print(label)
            print(url)
    except StremioError as e:
        sys.exit("error: %s" % e)
