#!/usr/bin/env python3
"""
ee3 API daemon — the backend that fills library.tsv's url column.

RUNS ON THE LXC (192.168.1.16:1209), NOT ON THE PI. This is the one piece of
the project that is allowed pip dependencies: constraint 7 in CLAUDE.md keeps
server.py and gen_static.py stdlib-only because the Pi has no pip packages,
and constraint 11 has no room for a second daemon in 1GB. Putting this on its
own box is what buys the exemption — nothing in here is ever imported by
server.py. The Pi's half of this is cabletv/ee3resolve.py, which is stdlib.

Endpoints:
  GET /health              auth state, without leaking the password
  GET /movies              proxy of ee3's /api/movies (all query params pass)
  GET /resolve/{movie_id}  movie id -> a magnet URI the Pi can stream
  GET /library.tsv         the whole catalogue as cabletv/library.tsv

Credentials come from the environment (EE3_USERNAME / EE3_PASSWORD), or from
an env file named by EE3_ENV_FILE. Never hardcode them here — this file is
tracked and the box is a git checkout.

  $ pip install fastapi httpx uvicorn
  $ EE3_USERNAME=... EE3_PASSWORD=... python3 movieapi.py
"""

import asyncio
import json
import logging
import os
import re
import sys
import urllib.parse
from contextlib import asynccontextmanager
from typing import Optional

import httpx
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import PlainTextResponse

log = logging.getLogger("ee3")

BASE_URL = os.environ.get("EE3_BASE_URL", "https://ee3.me").rstrip("/")
LOGIN_URL = f"{BASE_URL}/login"

HOST = os.environ.get("EE3_HOST", "0.0.0.0")
PORT = int(os.environ.get("EE3_PORT", "1209"))

# How long /resolve is willing to spend before giving up. A TV is watching, so
# this is a real deadline, not a safety net: cabletv.lua shows "RESOLVING" for
# exactly this long.
#
# It used to be 90s because resolving meant asking ee3 to cache the torrent and
# polling until it had. It does not any more — /resolve now only asks torrentio
# for an infoHash and hands back a magnet, which is two GETs, and the *Pi* does
# the downloading. Seconds, not minutes.
RESOLVE_TIMEOUT = float(os.environ.get("EE3_RESOLVE_TIMEOUT", "25"))

# Pi 3B+ playback envelope (constraint 11): H.264 only, 1080p max. A 2160p
# HEVC remux is not "better quality" on this box, it is a slideshow — so the
# filter below is a correctness rule, not a preference.
MAX_HEIGHT = int(os.environ.get("EE3_MAX_HEIGHT", "1080"))
MAX_SIZE_GB = float(os.environ.get("EE3_MAX_SIZE_GB", "0") or 0)  # 0 = no cap

BROWSER_HEADERS = {
    "accept": "*/*",
    "accept-language": "en-US,en;q=0.9",
    "user-agent": (
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/120.0.0.0 Safari/537.36"
    ),
    "sec-gpc": "1",
}


def _load_env_file():
    """Read KEY=VALUE lines from EE3_ENV_FILE, without overriding real env."""
    path = os.environ.get("EE3_ENV_FILE")
    if not path:
        return
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip("'\""))
    except OSError as e:
        log.warning("EE3_ENV_FILE %s unreadable: %s", path, e)


_load_env_file()
USERNAME = os.environ.get("EE3_USERNAME", "")
PASSWORD = os.environ.get("EE3_PASSWORD", "")


# --- session ----------------------------------------------------------------
# follow_redirects is OFF on purpose and it is the whole bug fix. ee3 does not
# answer an expired session with 401/403 — /api/movies replies 303 to /login.
# With redirects followed, httpx chases that, returns 200 with the login page's
# HTML, and .json() blows up: an expired cookie looked like a parse error and
# the re-auth path could never fire. Unfollowed, the 303 is legible.
http_client: Optional[httpx.AsyncClient] = None
torrentio_client: Optional[httpx.AsyncClient] = None

_login_lock = asyncio.Lock()
_authed = False
# Bumped on every successful login. Callers capture it before a request and
# hand it back to login(), so N concurrent 303s cause one login, not N.
_auth_epoch = 0


def _is_auth_bounce(r: httpx.Response) -> bool:
    if r.status_code in (401, 403):
        return True
    if r.status_code in (301, 302, 303, 307, 308):
        return "/login" in r.headers.get("location", "")
    return False


async def _verify_session() -> bool:
    """Ask the API something small and see whether we get JSON or a bounce."""
    try:
        r = await http_client.get("/api/movies", params={"page": 1, "perPage": 1})
    except httpx.HTTPError as e:
        log.warning("session check failed: %s", e)
        return False
    return r.status_code == 200 and "json" in r.headers.get("content-type", "")


async def login(seen_epoch: Optional[int] = None) -> bool:
    """Log in, unless someone else already did it while we were queued."""
    global _authed, _auth_epoch

    async with _login_lock:
        if seen_epoch is not None and seen_epoch != _auth_epoch:
            return _authed  # another request re-authed us; don't stampede

        if not USERNAME or not PASSWORD:
            log.error("EE3_USERNAME / EE3_PASSWORD are not set — cannot log in")
            _authed = False
            return False

        headers = {
            "content-type": "application/x-www-form-urlencoded",
            "origin": BASE_URL,
            "referer": LOGIN_URL,
            # Marks this as a SvelteKit enhanced-form submit, which makes the
            # action reply with a JSON envelope instead of an HTML redirect.
            "x-sveltekit-action": "true",
        }
        try:
            r = await http_client.post(
                LOGIN_URL,
                data={"username": USERNAME, "password": PASSWORD},
                headers=headers,
            )
        except httpx.HTTPError as e:
            log.error("login request failed: %s", e)
            _authed = False
            return False

        # The old code treated any 200 as success. A SvelteKit action answers
        # BAD credentials with 200 and {"type":"failure"} — so a wrong password
        # was reported as "Login successful." and every later call 303'd.
        kind = ""
        if "json" in r.headers.get("content-type", ""):
            try:
                kind = (r.json() or {}).get("type", "")
            except ValueError:
                kind = ""
        if kind in ("failure", "error"):
            log.error("login rejected by ee3 (type=%s): %s", kind, r.text[:300])
            _authed = False
            return False
        if r.status_code >= 400:
            log.error("login failed [%s]: %s", r.status_code, r.text[:300])
            _authed = False
            return False

        # Cookie-setting is the point; verify rather than trust the status.
        _authed = await _verify_session()
        if _authed:
            _auth_epoch += 1
            log.info("authenticated as %s", USERNAME)
        else:
            log.error("login looked OK but the session still bounces to /login")
        return _authed


async def api(method: str, path: str, **kw) -> httpx.Response:
    """One ee3 API call, with exactly one re-login-and-retry on a bounce."""
    epoch = _auth_epoch
    if not _authed:
        await login(epoch)
        epoch = _auth_epoch

    headers = dict(kw.pop("headers", {}) or {})
    headers.setdefault("referer", f"{BASE_URL}/")
    headers.setdefault("sec-fetch-dest", "empty")
    headers.setdefault("sec-fetch-mode", "cors")
    headers.setdefault("sec-fetch-site", "same-origin")

    try:
        r = await http_client.request(method, path, headers=headers, **kw)
    except httpx.HTTPError as e:
        raise HTTPException(status_code=502, detail=f"ee3 unreachable: {e}")

    if _is_auth_bounce(r):
        log.info("session expired on %s %s — re-authenticating", method, path)
        if await login(epoch):
            try:
                r = await http_client.request(method, path, headers=headers, **kw)
            except httpx.HTTPError as e:
                raise HTTPException(status_code=502, detail=f"ee3 unreachable: {e}")
        if _is_auth_bounce(r):
            raise HTTPException(
                status_code=502,
                detail="ee3 rejected the session; check EE3_USERNAME/EE3_PASSWORD",
            )
    return r


def _json_or_502(r: httpx.Response, what: str):
    if r.status_code not in (200, 201):
        raise HTTPException(
            status_code=502, detail=f"{what}: ee3 said {r.status_code} {r.text[:200]}"
        )
    try:
        return r.json()
    except ValueError:
        raise HTTPException(status_code=502, detail=f"{what}: ee3 sent non-JSON")


@asynccontextmanager
async def lifespan(_app: FastAPI):
    global http_client, torrentio_client
    http_client = httpx.AsyncClient(
        base_url=BASE_URL, headers=BROWSER_HEADERS, timeout=20.0,
        follow_redirects=False,
    )
    # torrentio is a different origin; it must not see the ee3 cookie, and it
    # is slow enough to want its own timeout. BROWSER_HEADERS is load-bearing
    # here, not cosmetic — see STRICT_FILTER: no User-Agent means a Cloudflare
    # 403 that surfaces as a JSON parse error.
    torrentio_client = httpx.AsyncClient(
        headers=BROWSER_HEADERS, timeout=RESOLVE_TIMEOUT, follow_redirects=True,
    )
    # Startup login is best-effort. The LXC may boot before the network is up,
    # and a daemon that refuses to start is harder to debug than one that says
    # "not authenticated" on /health and retries on first use.
    try:
        await login()
    except Exception as e:  # never let startup take the daemon down
        log.error("startup login raised: %s", e)
    yield
    await http_client.aclose()
    await torrentio_client.aclose()


app = FastAPI(title="ee3 API daemon", lifespan=lifespan)


# --- torrentio ----------------------------------------------------------------
TORRENTIO = os.environ.get("EE3_TORRENTIO", "https://torrentio.strem.fun").rstrip("/")

# The filter chain, verbatim. `sort=seeders` first so that the single stream
# `limit=1` keeps is the best-seeded one — on a Pi pulling its own pieces, seed
# count is the difference between a film and a slideshow. The qualityfilter
# names everything to THROW AWAY, which is why 1080p is absent from it: 4k and
# 720p/480p are excluded by size and by constraint 11, cam/scr are unwatchable,
# and brremux/hdrall/dolbyvision/threed are all things a 3B+ cannot decode.
#
# Two traps live in this URL, both verified against the live service:
#   * The pipes stay LITERAL. httpx passes them through untouched and torrentio
#     wants them that way; percent-encoding them to %7C also works, so neither
#     is the thing that breaks.
#   * torrentio sits behind Cloudflare and answers a request with no User-Agent
#     with a 403 HTML page — which .json() then reports as a parse error, so it
#     reads like a torrentio outage rather than a blocked request. BROWSER_HEADERS
#     on torrentio_client is what stops that; never give that client bare headers.
STRICT_FILTER = ("sort=seeders|qualityfilter=4k,720p,480p,scr,cam,brremux,"
                 "hdrall,dolbyvision,dolbyvisionwithhdr,threed|limit=1")
# Rare and old titles often have nothing at all once the strict filter has run,
# and answering "no streams" for a film that has a perfectly good 720p rip is a
# worse outcome than playing the 720p rip. pick_stream still enforces the parts
# that are about what the box can DECODE, so this relaxes taste, not capability.
RELAXED_FILTER = "sort=seeders|limit=1"

# Both engines the Pi can run (peerflix, webtorrent) have DHT on, so these are
# only there to shorten the cold start — a magnet with no tracker has to find
# its first peer through the DHT alone, which on a domestic line is the slowest
# part of pressing OK. opentrackr is the one named in the spec; the rest are
# the standard public UDP trackers.
TRACKERS = (
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://open.demonii.com:1337/announce",
    "udp://tracker.torrent.eu.org:451/announce",
    "udp://exodus.desync.com:6969/announce",
)

# ee3 record id -> IMDb id. Deliberately loose: `tt` plus at least seven
# digits, because IMDb has run past eight and will keep going.
_TT = re.compile(r"tt\d{7,}")


def _torrentio_url(filt: str, imdb_id: str) -> str:
    return "%s/%s/stream/movie/%s.json" % (TORRENTIO, filt, imdb_id)


async def _torrentio(filt: str, imdb_id: str) -> list:
    """One torrentio query -> its streams list. An empty list is a normal
    answer (that is what the fallback exists for), not an error."""
    url = _torrentio_url(filt, imdb_id)
    try:
        r = await torrentio_client.get(url)
    except httpx.HTTPError as e:
        raise HTTPException(status_code=502, detail=f"torrentio unreachable: {e}")
    if r.status_code == 404:
        return []                       # torrentio's "nothing for this id"
    if r.status_code != 200:
        raise HTTPException(
            status_code=502,
            detail="torrentio said %d (a 403 here means the request lost its "
                   "User-Agent)" % r.status_code,
        )
    try:
        return (r.json() or {}).get("streams") or []
    except ValueError:
        raise HTTPException(status_code=502, detail="torrentio sent non-JSON")


def _magnet(info_hash: str, filename: Optional[str]) -> str:
    """infoHash -> a magnet URI peerflix/webtorrent can open.

    `dn` is percent-encoded because a release filename is full of spaces and
    the odd `&`; the trackers are left literal, which every magnet parser in
    use accepts and which keeps the URI readable in a log.
    """
    out = "magnet:?xt=urn:btih:" + info_hash
    if filename:
        out += "&dn=" + urllib.parse.quote(filename, safe="")
    for tr in TRACKERS:
        out += "&tr=" + tr
    return out


# --- stream selection --------------------------------------------------------
# Torrentio packs everything into one title string, e.g.
#   "Movie.Name.2019.1080p.BluRay.x264-GRP\n👤 42 💾 1.5 GB ⚙️ TPB"
_RES = [(2160, r"2160p|\b4k\b|uhd"), (1080, r"1080p"), (720, r"720p"), (480, r"480p")]
_BAD_CODEC = re.compile(r"x265|h\.?265|hevc|av1|vp9", re.I)
_SEEDERS = re.compile(r"👤\s*(\d+)")
_SIZE = re.compile(r"([\d.]+)\s*(GB|MB)", re.I)


def _describe(stream: dict) -> dict:
    text = "%s %s" % (stream.get("name") or "", stream.get("title") or "")
    low = text.lower()

    height = 0
    for h, pat in _RES:
        if re.search(pat, low):
            height = h
            break

    m = _SIZE.search(text)
    size_gb = 0.0
    if m:
        size_gb = float(m.group(1)) / (1024 if m.group(2).upper() == "MB" else 1)

    m = _SEEDERS.search(text)
    return {
        "infoHash": stream.get("infoHash"),
        "fileIdx": stream.get("fileIdx"),
        "filename": (stream.get("behaviorHints") or {}).get("filename"),
        "title": (stream.get("title") or "").split("\n")[0],
        "height": height,
        "size_gb": round(size_gb, 2),
        "seeders": int(m.group(1)) if m else 0,
        "hevc": bool(_BAD_CODEC.search(low)),
    }


def pick_stream(streams: list, max_height: int, allow_hevc: bool,
                max_size_gb: float) -> Optional[dict]:
    """Best stream this box can actually decode, or None.

    Unknown resolution is kept (plenty of releases just don't say) but ranks
    below anything labelled; unknown codec is assumed H.264, which is what the
    overwhelming majority of x264 scene releases are.
    """
    cands = [_describe(s) for s in streams if s.get("infoHash")]
    ok = [
        c for c in cands
        if (allow_hevc or not c["hevc"])
        and (c["height"] == 0 or c["height"] <= max_height)
        and (max_size_gb <= 0 or c["size_gb"] == 0 or c["size_gb"] <= max_size_gb)
    ]
    if not ok:
        return None
    # Highest allowed resolution first, then most seeders (a stream nobody is
    # sharing takes forever to cache), then smallest file.
    ok.sort(key=lambda c: (c["height"], c["seeders"], -c["size_gb"]), reverse=True)
    return ok[0]


# --- routes ------------------------------------------------------------------
@app.get("/health")
async def health():
    return {
        "ok": True,
        "authenticated": _authed,
        "username": USERNAME or None,
        "credentials_set": bool(USERNAME and PASSWORD),
        "base_url": BASE_URL,
        "max_height": MAX_HEIGHT,
        "torrentio": TORRENTIO,
        "resolves_to": "magnet",
    }


@app.get("/movies")
async def movies(request: Request):
    """Proxy of ee3's /api/movies.

    Every query param passes through: sort, page, perPage, genres, title,
    year_from, year_to, min_vote_count, min_rating, max_rating, min_runtime,
    max_runtime. Response is {items, totalItems, totalPages}.
    """
    params = dict(request.query_params)
    params.setdefault("page", "1")
    params.setdefault("perPage", "50")
    r = await api("GET", "/api/movies", params=params)
    return _json_or_502(r, "/movies")


async def imdb_id_for(movie_id: str) -> str:
    """ee3 record id -> IMDb tt-id.

    This hop exists because torrentio is indexed by IMDb id and ee3 is not.
    ee3's catalogue rows carry no imdb_id at all — as of July 2026 `tmdb_data`
    holds only title/release_date/poster_path/backdrop_path/vote_average/
    vote_count/overview/runtime — so the id has to come from somewhere else.

    `GET /api/torrent/{id}` is that somewhere: ee3 builds its own torrentio URL
    for the title, and that URL ends in `/stream/movie/tt#######.json`. Pulling
    the tt-id back out of it is not a hack so much as reading ee3's own answer
    to the same question. The explicit fields are checked first anyway, so the
    day ee3 starts sending an imdb_id this quietly gets a hop shorter.
    """
    info = _json_or_502(await api("GET", f"/api/torrent/{movie_id}"), "torrent lookup")

    for holder in (info, info.get("tmdb_data") or {}, info.get("external_ids") or {}):
        if not isinstance(holder, dict):
            continue
        for key in ("imdb_id", "imdbId", "imdb"):
            v = holder.get(key)
            if isinstance(v, str) and _TT.fullmatch(v.strip()):
                return v.strip()

    m = _TT.search(info.get("torrentioUrl") or "")
    if m:
        return m.group(0)
    # Last resort: the id is in that document somewhere, under a key nobody has
    # written down yet. Cheaper than being wrong about the shape of the JSON.
    m = _TT.search(json.dumps(info))
    if m:
        return m.group(0)

    raise HTTPException(
        status_code=404,
        detail=f"no IMDb id for {movie_id} — ee3 returned no torrentioUrl for it",
    )


@app.get("/resolve/{movie_id}")
async def resolve(
    movie_id: str,
    max_height: int = Query(MAX_HEIGHT),
    allow_hevc: bool = Query(False),
    max_size_gb: float = Query(MAX_SIZE_GB),
    imdb_id: Optional[str] = Query(None, description="skip the ee3 lookup"),
):
    """ee3 movie id -> a magnet URI the Pi streams for itself.

    Two hops now, and neither of them downloads anything:
      1. ee3 record id -> IMDb id            (imdb_id_for, one ee3 call)
      2. torrentio, strict then relaxed      -> infoHash -> magnet

    What this deliberately no longer does is ask ee3 to cache the torrent and
    poll `POST /api/torrent/{id}` for a `downloadUrl`. That put a whole film's
    worth of transfer on the LXC, made the viewer wait out someone else's
    caching queue, and expired. The Pi now takes the magnet and pulls its own
    pieces, which is also what makes seeking work: peerflix/webtorrent fetch
    on demand, so jumping forward fetches the pieces under the new position
    instead of waiting for the ones before it.

    Returns {"url": "magnet:?xt=urn:btih:..."} — or, if torrentio offered a
    plain HTTP stream instead of an infoHash, that URL directly. ee3resolve.py
    reads nothing but `url`; everything else here is for a human with curl.
    """
    imdb = (imdb_id or "").strip() or await imdb_id_for(movie_id)
    if not _TT.fullmatch(imdb):
        raise HTTPException(status_code=400, detail=f"not an IMDb id: {imdb!r}")

    offered, undecodable = 0, None
    for label, filt in (("strict", STRICT_FILTER), ("relaxed", RELAXED_FILTER)):
        streams = await _torrentio(filt, imdb)
        if not streams:
            continue
        offered += len(streams)

        # torrentio occasionally serves a ready-made HTTP stream rather than an
        # infoHash (debrid-backed entries do this). It needs no torrent client
        # at all, so it wins outright when it is on offer.
        direct = next((s for s in streams
                       if s.get("url") and not s.get("infoHash")), None)
        if direct:
            log.info("resolve %s (%s): direct url via %s", movie_id, imdb, label)
            return {"ok": True, "url": direct["url"], "kind": "url",
                    "imdb_id": imdb, "filter": label,
                    "stream": {"title": (direct.get("title") or "").split("\n")[0]}}

        chosen = pick_stream(streams, max_height, allow_hevc, max_size_gb)
        if not chosen:
            # Keep the first thing we had to turn down, so the eventual error
            # can say WHAT was wrong with it rather than just "nothing found".
            undecodable = undecodable or _describe(streams[0])
            continue

        magnet = _magnet(chosen["infoHash"], chosen["filename"])
        log.info("resolve %s (%s): %s %dp %s seeders=%d via %s", movie_id, imdb,
                 chosen["infoHash"][:8], chosen["height"],
                 chosen["filename"] or "?", chosen["seeders"], label)
        return {"ok": True, "url": magnet, "kind": "magnet",
                "imdb_id": imdb, "filter": label, "stream": chosen}

    if undecodable:
        raise HTTPException(
            status_code=409,
            detail="found %s but this box cannot decode it (needs H.264 <=%dp)"
                   % (undecodable["title"] or "a release", max_height),
        )
    raise HTTPException(
        status_code=404,
        detail=f"torrentio has nothing for {imdb} ({offered} streams offered)",
    )


def _clean(s) -> str:
    """library.tsv is tab-separated with no quoting, so tabs must not survive."""
    return re.sub(r"\s+", " ", str(s or "")).strip()


# TMDB serves images off this host with no API key and no auth, which is the
# only reason a poster url can live in a file the Pi reads. w342 is the
# smallest size that still looks like a poster in the 993 detail panel.
TMDB_IMG = os.environ.get("EE3_TMDB_IMG", "https://image.tmdb.org/t/p/w342")

# NOTE: as of July 2026 ee3's /api/movies returns tmdb_data with only
# poster_path, backdrop_path, title, release_date, vote_average and runtime —
# no overview. So this column ships empty and 993 prints NO SYNOPSIS. It is
# written this way because the day ee3 (or whatever replaces the enrichment)
# starts sending one, the panel fills in with no further work.
#
# A synopsis is free text on a line-oriented file: newlines and tabs are
# already gone via _clean, and this is what stops one film from owning the
# whole panel. Cut at a sentence end when there is one nearby.
OVERVIEW_MAX = int(os.environ.get("EE3_OVERVIEW_MAX", "480"))


def _overview(tmdb: dict) -> str:
    text = _clean(tmdb.get("overview"))
    if len(text) <= OVERVIEW_MAX:
        return text
    cut = text[:OVERVIEW_MAX]
    stop = max(cut.rfind(". "), cut.rfind("! "), cut.rfind("? "))
    if stop > OVERVIEW_MAX // 2:
        return cut[:stop + 1]
    return cut.rsplit(" ", 1)[0] + "..."


def _row(it: dict) -> Optional[str]:
    """One catalogue item -> one library.tsv line, or None if unusable.

    Eight columns now, and the four the player has always read come first:
    an older cabletv.lua reading this file still gets exactly what it did
    before, and a newer one gets a detail panel.
    """
    tmdb = it.get("tmdb_data") or {}
    title = _clean(tmdb.get("title") or it.get("title"))
    if not title or not it.get("id"):
        return None
    runtime = tmdb.get("runtime") or 0
    rating = tmdb.get("vote_average") or 0
    poster = _clean(tmdb.get("poster_path"))
    return "\t".join((
        "movie",
        title,
        _clean(tmdb.get("release_date"))[:4],
        "ee3:%s" % it["id"],
        str(int(runtime)) if runtime else "",
        ("%.1f" % float(rating)) if rating else "",
        (TMDB_IMG + poster) if poster.startswith("/") else poster,
        _overview(tmdb),
    ))


@app.get("/library.tsv", response_class=PlainTextResponse)
async def library_tsv(
    sort: str = Query("-tmdb_data.release_date"),
    min_vote_count: int = Query(10),
    limit: int = Query(2000, ge=1, le=20000),
    per_page: int = Query(200, ge=1, le=500),
):
    """The whole catalogue in cabletv/library.tsv's format.

    The url column holds `ee3:<id>`, not a real URL: these links are minted per
    playback and would be stale by the time anyone pressed OK. cabletv.lua
    resolves the id through this daemon at play time instead.

    The four columns after it (runtime, rating, poster, overview) are what
    993's detail panel draws. They are shipped in the same file on purpose:
    the panel has to redraw on every cursor move, and a per-title HTTP call
    from a Pi behind a d-pad would make scrolling feel broken.

        curl -s http://192.168.1.16:1209/library.tsv > cabletv/library.tsv
    """
    rows, page = [], 1
    while len(rows) < limit:
        params = {"page": page, "perPage": per_page, "sort": sort,
                  "min_vote_count": min_vote_count}
        data = _json_or_502(await api("GET", "/api/movies", params=params), "library")
        items = data.get("items") or []
        if not items:
            break
        for it in items:
            row = _row(it)
            if row:
                rows.append(row)
            if len(rows) >= limit:
                break
        if page >= int(data.get("totalPages") or page):
            break
        page += 1

    header = [
        "# nothing-htpc on-demand library index.",
        "#",
        "# GENERATED by server/movieapi.py (GET /library.tsv) — do not hand-edit,",
        "# regenerate. Columns:",
        "#   kind <TAB> title <TAB> year <TAB> url <TAB>",
        "#   runtime-minutes <TAB> rating <TAB> poster-url <TAB> overview",
        "# The last four may be empty; the first four never are.",
        "#",
        "# The url column is `ee3:<id>`, not a playable URL. ee3 mints a link per",
        "# playback, so a baked-in URL would be dead by the time the remote asked",
        "# for it; cabletv.lua calls ee3resolve.py on OK instead.",
        "#",
        "# %d titles, sort=%s, min_vote_count=%d" % (len(rows), sort, min_vote_count),
        "",
    ]
    return "\n".join(header + rows) + "\n"


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )
    if not USERNAME or not PASSWORD:
        log.warning("EE3_USERNAME / EE3_PASSWORD are unset — every call will 502")
    import uvicorn

    # "movieapi:app", not "server:app": server.py sits in this same directory,
    # so the old string imported the HTPC launcher backend and died on a
    # missing `app` attribute. reload=True is off — this is a service.
    uvicorn.run("movieapi:app", host=HOST, port=PORT, reload=False,
                log_level=os.environ.get("EE3_LOG", "info"))
    sys.exit(0)
