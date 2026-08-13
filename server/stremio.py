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

# Playback envelope.
#
# This used to be a correctness rule enforcing the Pi 3B+: 1080p, H.264 only,
# because a 2160p AV1 remux on a 3B+ is a slideshow rather than a film. The Pi
# is out of the picture (August 2026) and the targets are an x86_64 laptop now
# and an AMD-GPU box later, both of which decode HEVC, VP9 and AV1 in hardware.
# So it inverts: everything is allowed by default, and these exist to *tighten*
# the envelope for weaker hardware rather than to loosen it for better.
#
#   HTPC_MAX_HEIGHT=1080   cap the resolution
#   HTPC_ALLOW_HEVC=0      push HEVC/VP9/AV1 down the list
#
# Nothing is ever dropped for being outside the envelope — a stream that is
# only available as 2160p HEVC still plays, it just sorts last. With the
# stream picker the choice is the owner's anyway; this only decides what Ⓐ
# reaches for first.
MAX_HEIGHT = int(os.environ.get("HTPC_MAX_HEIGHT", "2160"))
ALLOW_HEVC = os.environ.get("HTPC_ALLOW_HEVC", "1") not in ("", "0")

TIMEOUT = float(os.environ.get("HTPC_HTTP_TIMEOUT", "10"))
CATALOG_TTL = float(os.environ.get("HTPC_CATALOG_TTL", "900"))   # 15 min
# Streams are cached far more briefly than the catalogue, and for a different
# reason: the picker hands back an *index* into this list, so the list has to
# still mean the same thing when the choice comes back. Long enough to browse
# and pick, short enough that a magnet is never minted from stale data.
STREAM_TTL = float(os.environ.get("HTPC_STREAM_TTL", "300"))     # 5 min

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


def _episodes(m):
    """Cinemeta's `videos` -> the rows the season/episode chooser draws.

    Every episode already carries the id Torrentio wants — "tt11198330:1:3",
    the show's IMDb id with a season and an episode glued on — so choosing one
    needs no second lookup and /play takes it unchanged.

    Season 0 is where Cinemeta files recaps, premiere specials and behind-the-
    scenes featurettes. They are real videos and they are kept, but they sort
    to the end: nobody opens a show to watch its making-of first.

    Deliberately thin. A long-running show has hundreds of these and the Pi
    has 1 GB, so an episode is a title and a date — the overview would be
    kilobytes per row for a line this screen has nowhere to draw.
    """
    out = []
    for v in m.get("videos") or []:
        number = v.get("episode", v.get("number"))
        season = v.get("season")
        if not v.get("id") or season is None or number is None:
            continue
        try:
            season, number = int(season), int(number)
        except (TypeError, ValueError):
            continue
        out.append({
            "id": v["id"],
            "season": season,
            "episode": number,
            "title": (v.get("name") or "").strip(),
            "released": (v.get("released") or v.get("firstAired") or "")[:10],
        })
    out.sort(key=lambda e: (e["season"] == 0, e["season"], e["episode"]))
    return out


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

        # A show's detail panel spends its bottom half on seasons and episodes
        # where a film's spends it on reviews, so only one of these is ever
        # worth fetching — and reviews of a series as a whole are the less
        # useful half of that trade.
        if kind == "series":
            row["episodes"] = _episodes(m)

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
            # Not for a series: its half of the panel is the episode chooser,
            # so this would be a TMDB round trip for something never drawn.
            if kind != "series":
                row["reviews"] = tmdb.reviews(kind, row["tmdb_id"])
        return row

    return _cached(key, CATALOG_TTL, produce)


# --- streams -----------------------------------------------------------------

_HEIGHT_RE = re.compile(r"(\d{3,4})p")
_HEVC_RE = re.compile(r"\b(hevc|x265|h\.?265|vp9|av1)\b", re.I)
_SEEDS_RE = re.compile(r"(?:👤|seeders?[:\s])\s*(\d+)", re.I)
_SIZE_RE = re.compile(r"(?:💾|size[:\s])\s*([\d.]+\s*[KMGT]i?B)", re.I)
_SOURCE_RE = re.compile(r"(?:⚙️|⚙)\s*([^\n]+)")


def _seed_bucket(seeds):
    """Seeders, coarsened.

    Ranking on the raw count makes a 2160p copy with 2,100 seeders lose to a
    720p one with 2,140 — a difference nobody can perceive deciding a
    difference everybody can. Bucketing means seeders decide only when they
    differ by an order of magnitude, and resolution decides inside a bucket.
    """
    if seeds >= 500:
        return 4
    if seeds >= 100:
        return 3
    if seeds >= 20:
        return 2
    if seeds >= 5:
        return 1
    return 0


def _parse(s):
    """Everything the picker draws about one stream, read out of its text.

    Torrentio puts quality, size, seeders and the indexer it came from in the
    human-readable `title` rather than in fields, so this is string work by
    necessity. Anything missing stays empty — the picker draws what it has,
    and a stream whose title does not state its resolution is treated as
    inside the envelope rather than excluded (being strict here rejects every
    copy of some films).
    """
    text = "%s %s" % (s.get("name") or "", s.get("title") or "")
    height = 0
    m = _HEIGHT_RE.search(text)
    if m:
        height = int(m.group(1))
    seeds = 0
    m = _SEEDS_RE.search(text)
    if m:
        seeds = int(m.group(1))
    size = ""
    m = _SIZE_RE.search(text)
    if m:
        size = re.sub(r"\s+", " ", m.group(1)).strip()
    source = ""
    m = _SOURCE_RE.search(s.get("title") or "")
    if m:
        source = m.group(1).strip()[:24]
    return {
        "height": height,
        "seeds": seeds,
        "size": size,
        "source": source,
        "efficient": bool(_HEVC_RE.search(text)),
    }


def _stream_rank(s):
    """Sort key, lower is better: inside the envelope, well seeded, then big.

    The envelope is a preference now rather than a filter (see MAX_HEIGHT
    above) — nothing is dropped, it only sorts last. Order of the keys is the
    argument: a stream nobody is seeding does not play at all, so seeders
    outrank resolution; within a seeding tier, more pixels wins.
    """
    p = _parse(s)
    too_big = p["height"] > MAX_HEIGHT
    wrong_codec = p["efficient"] and not ALLOW_HEVC
    return (1 if too_big else 0,
            1 if wrong_codec else 0,
            -_seed_bucket(p["seeds"]),
            -p["height"],
            -p["seeds"])


def streams(kind, imdb_id):
    """Ask each addon in turn; the first one with streams wins.

    Cached for STREAM_TTL, which is what makes the picker's indices mean
    anything: the list the UI drew and the list /play indexes into have to be
    the same list, or choosing the third row plays whatever has drifted into
    third place since.

    Errors from a dead host are collected rather than raised, so the message
    that reaches the TV describes the whole attempt ("no streams found")
    rather than whichever host happened to be first in the list.
    """
    kind = "series" if kind in ("show", "series") else "movie"
    key = ("streams", kind, imdb_id)

    def produce():
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
                for row in out:
                    # Which addon answered, so the picker can say where a
                    # stream came from even when the title does not.
                    row.setdefault("_addon", _host(base))
                return sorted(out, key=_stream_rank)
            problems.append("%s has nothing for this title" % _host(base))
        raise StremioError("no streams found (%s)" % "; ".join(problems[:2]))

    return _cached(key, STREAM_TTL, produce)


def stream_rows(kind, imdb_id):
    """The ranked stream list, thinned to what the picker draws.

    `i` is the index into the cached list and is what comes back to /play —
    the page never handles an infoHash or a magnet, which keeps the resolve
    step (and TorrServer) entirely on this side.
    """
    rows = []
    for i, s in enumerate(streams(kind, imdb_id)):
        p = _parse(s)
        rows.append({
            "i": i,
            "label": _label(s),
            "quality": ("%dp" % p["height"]) if p["height"] else "",
            "size": p["size"],
            "seeds": p["seeds"],
            "source": p["source"] or s.get("_addon", ""),
            # A debrid link plays straight away; a magnet has to be downloaded
            # by TorrServer first, and that is worth saying before Ⓐ.
            "direct": bool(s.get("url")),
            "outside": p["height"] > MAX_HEIGHT or (p["efficient"] and not ALLOW_HEVC),
        })
    return rows


def resolve(kind, imdb_id, index=0):
    """Turn the chosen stream into a URL mpv can open.

    `index` is a row from stream_rows — 0 (the ranking's own pick) unless the
    owner opened the picker and chose another. Out of range is an error with
    a sentence rather than a clamp: silently playing something other than the
    row that was selected is the one behaviour a picker must never have.

    Two shapes come back from the addons and both are handled here so callers
    never have to care which one they got:

      `url`       already playable (a debrid link). Returned as-is.
      `infoHash`  a torrent. Handed to TorrServer, which returns an HTTP URL.
    """
    found = streams(kind, imdb_id)
    try:
        index = int(index)
    except (TypeError, ValueError):
        index = 0
    if not 0 <= index < len(found):
        raise StremioError("that stream is no longer in the list")
    best = found[index]

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
