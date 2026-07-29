#!/usr/bin/env python3
"""
Turn an `ee3:<id>` from library.tsv into a URL mpv can open.

This is the Pi's half of the on-demand backend and it is stdlib-only on
purpose (constraint 7 — the Pi has no pip packages). All it does is talk to
server/movieapi.py, which runs on the LXC and holds the ee3 session.

    $ ee3resolve.py ee3:6f2a91c        -> prints a URL, exit 0
    $ ee3resolve.py --library          -> rewrites library.tsv in place
    $ ee3resolve.py --library 45       -> ... giving up after 45 s

Failures print one sentence to stderr and exit non-zero; that sentence is
what cabletv.lua puts on the banner, so it has to read like something a
person on a sofa can act on.

Env:
  EE3_API   base URL of the daemon (default http://192.168.1.16:1209)
"""

import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

DIR = Path(os.environ.get("CABLETV_DIR") or Path(__file__).resolve().parent)
API = os.environ.get("EE3_API", "http://192.168.1.16:1209").rstrip("/")

# Longer than the daemon's own EE3_RESOLVE_TIMEOUT (90s), so a slow cache
# comes back as the daemon's real message rather than as a local timeout.
TIMEOUT = float(os.environ.get("EE3_TIMEOUT", "120"))


def _get(path, timeout=TIMEOUT):
    """GET, returning (status, body-bytes). HTTP errors are values, not raises —
    the daemon puts the useful sentence in the body of a 4xx/5xx."""
    url = API + path
    ctx = ssl.create_default_context() if url.startswith("https") else None
    try:
        with urllib.request.urlopen(url, timeout=timeout, context=ctx) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except urllib.error.URLError as e:
        raise SystemExit("ee3 daemon unreachable at %s (%s)" % (API, e.reason))
    except OSError as e:
        raise SystemExit("ee3 daemon unreachable at %s (%s)" % (API, e))


def _detail(status, body):
    """FastAPI puts the message in {"detail": ...}; fall back to raw text."""
    try:
        obj = json.loads(body.decode("utf-8", "replace"))
    except ValueError:
        return "HTTP %d" % status
    d = obj.get("detail", obj)
    if isinstance(d, list) and d:          # pydantic validation errors
        d = d[0].get("msg", d[0])
    return str(d) if d else "HTTP %d" % status


def resolve(ref):
    movie_id = ref[4:] if ref.startswith("ee3:") else ref
    if not movie_id:
        raise SystemExit("empty ee3 id")
    status, body = _get("/resolve/" + urllib.parse.quote(movie_id, safe=""))
    if status != 200:
        raise SystemExit(_detail(status, body))
    try:
        url = (json.loads(body.decode("utf-8", "replace")) or {}).get("url")
    except ValueError:
        raise SystemExit("daemon sent non-JSON")
    if not url:
        raise SystemExit("daemon returned no url")
    return url


LIBRARY_TIMEOUT = float(os.environ.get("EE3_LIBRARY_TIMEOUT", "300"))


def refresh_library(dest, timeout=None):
    # Paging the whole catalogue takes a while, so the default deadline is
    # generous: this is normally run by hand or from cron. cabletv.lua passes
    # a shorter one, because there it *is* run with a TV waiting on it.
    status, body = _get("/library.tsv", timeout=timeout or LIBRARY_TIMEOUT)
    if status != 200:
        raise SystemExit(_detail(status, body))
    text = body.decode("utf-8", "replace")
    if "\tee3:" not in text:
        raise SystemExit("daemon returned an empty library — is it logged in? "
                         "(curl %s/health)" % API)
    tmp = dest.with_suffix(".tsv.tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(dest)                      # atomic: mpv may be reading it
    n = sum(1 for l in text.splitlines() if l and not l.startswith("#"))
    return n


def main(argv):
    if len(argv) < 2 or len(argv) > 3 or argv[1] in ("-h", "--help"):
        sys.stderr.write(__doc__)
        return 2
    if argv[1] in ("--library", "--refresh-library"):
        dest = DIR / "library.tsv"
        try:
            timeout = float(argv[2]) if len(argv) == 3 else None
        except ValueError:
            raise SystemExit("--library takes a number of seconds, not %r" % argv[2])
        n = refresh_library(dest, timeout)
        sys.stderr.write("wrote %d titles to %s\n" % (n, dest))
        return 0
    if len(argv) != 2:
        sys.stderr.write(__doc__)
        return 2
    print(resolve(argv[1]))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except SystemExit:
        raise
    except Exception as e:                 # never a traceback on the TV
        sys.stderr.write("%s\n" % e)
        sys.exit(1)
