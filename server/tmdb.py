#!/usr/bin/env python3
"""
TMDB enrichment — credits and user reviews for the detail screen.

OPTIONAL, AND THE ONLY THING IN THIS PROJECT THAT WANTS AN API KEY.

Cinemeta hands over a director, a writer and three cast members for free, and
that is what the detail screen shows when there is no key. It does not carry a
producer and it has no reviews at all, so the fuller panel — five cast, the
producer, and three user reviews with star ratings — needs TMDB, and TMDB
answers 401 to everything without a key.

That is a deliberate exception, not a drift. CLAUDE.md keeps keys out of the
box because an OAuth flow on a device with no keyboard is a trap; a TMDB v3
key is none of that — it is a free string in a config file, it never expires,
it needs no user consent and no refresh. Everything here degrades to nothing
when it is absent.

Where the key goes, in precedence order:
  TMDB_API_KEY in the environment
  "tmdb_key" in server/config.local.json   <- untracked, survives git pull

Cinemeta already gives us `moviedb_id`, so no search step is needed: the TMDB
id arrives with the catalogue row.
"""

import json
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.themoviedb.org/3"
TIMEOUT = 8.0
TTL = 86400.0        # a day; credits do not change and reviews barely do

_cache = {}
_lock = threading.Lock()


def _key_from_config():
    """Read tmdb_key out of whichever config the session is using.

    Imported lazily and defensively: this module must never be the reason
    server.py fails to start, and a missing or malformed config is simply
    "no key" rather than an exception.
    """
    for name in ("config.local.json", "config.json"):
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name)
        try:
            with open(path) as f:
                value = json.load(f).get("tmdb_key")
            if value:
                return str(value).strip()
        except (OSError, ValueError, AttributeError):
            continue
    return ""


API_KEY = os.environ.get("TMDB_API_KEY", "").strip() or _key_from_config()


def available():
    return bool(API_KEY)


def _get(path, **params):
    params["api_key"] = API_KEY
    url = "%s/%s?%s" % (API, path.lstrip("/"), urllib.parse.urlencode(params))
    req = urllib.request.Request(url, headers={"accept": "application/json"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.loads(r.read(4_000_000).decode("utf-8", "replace"))


def _cached(key, produce):
    now = time.monotonic()
    with _lock:
        hit = _cache.get(key)
        if hit and now - hit[0] < TTL:
            return hit[1]
    value = produce()
    with _lock:
        _cache[key] = (now, value)
    return value


def _kind_path(kind):
    return "tv" if kind in ("show", "series", "tv") else "movie"


def credits(kind, tmdb_id, cast_limit=5):
    """-> {"director": [...], "producer": [...], "writer": [...], "cast": [...]}

    Crew jobs are matched by `job`, not by department: the Writing department
    contains story, screenplay, characters and novel credits, and listing all
    of them turns one line into five.
    """
    if not API_KEY or not tmdb_id:
        return {}

    def produce():
        data = _get("%s/%s/credits" % (_kind_path(kind), tmdb_id))
        crew = data.get("crew") or []

        def by_job(*jobs):
            out = []
            for c in crew:
                if c.get("job") in jobs and c.get("name") and c["name"] not in out:
                    out.append(c["name"])
            return out

        return {
            "director": by_job("Director")[:3],
            # "Producer" only. Executive/co/associate producers are a crowd,
            # and this is one line on a TV.
            "producer": by_job("Producer")[:3],
            "writer": by_job("Screenplay", "Writer", "Story")[:3],
            "cast": [c["name"] for c in (data.get("cast") or [])
                     if c.get("name")][:cast_limit],
        }

    try:
        return _cached(("credits", kind, tmdb_id, cast_limit), produce)
    except (urllib.error.URLError, urllib.error.HTTPError, ValueError, TimeoutError):
        # Enrichment is a bonus. A detail screen with three cast members from
        # Cinemeta is fine; one that fails to open is not.
        return {}


def reviews(kind, tmdb_id, limit=3):
    """-> [{"author": str, "rating": 0-10 or None, "text": str}]

    Only reviews that carry a score are kept, and they are ordered by how
    highly rated they are — the panel draws stars, so a review with no rating
    has nothing to draw and would read as zero.
    """
    if not API_KEY or not tmdb_id:
        return []

    def produce():
        data = _get("%s/%s/reviews" % (_kind_path(kind), tmdb_id))
        out = []
        for r in (data.get("results") or []):
            details = r.get("author_details") or {}
            rating = details.get("rating")
            content = (r.get("content") or "").strip()
            if rating is None or not content:
                continue
            out.append({
                "author": details.get("username") or r.get("author") or "",
                "rating": float(rating),
                # Reviews run to thousands of words. The panel fades out the
                # bottom of whatever it is given, so this is about not shipping
                # 40KB of prose to a 1GB box, not about layout.
                "text": content[:900],
            })
        out.sort(key=lambda r: -r["rating"])
        return out[:limit]

    try:
        return _cached(("reviews", kind, tmdb_id, limit), produce)
    except (urllib.error.URLError, urllib.error.HTTPError, ValueError, TimeoutError):
        return []


if __name__ == "__main__":
    import sys
    if not API_KEY:
        sys.exit("no TMDB key — set TMDB_API_KEY or tmdb_key in config.local.json")
    tid = sys.argv[1] if len(sys.argv) > 1 else "157336"
    print(json.dumps(credits("movie", tid), indent=2, ensure_ascii=False))
    for r in reviews("movie", tid):
        print("%-18s %4.1f  %s" % (r["author"], r["rating"], r["text"][:70]))
