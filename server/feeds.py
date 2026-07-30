#!/usr/bin/env python3
"""
RSS reader for the NEWS screen.

The browser cannot fetch time.mk directly — no CORS header — so the page asks
server.py and server.py asks here. Routing it this way also gives the feeds
one cache instead of one per screen repaint.

Parsing is ElementTree with a regex fallback, both stdlib. Real-world RSS is
not reliably well-formed (CDATA in odd places, stray ampersands, a Cloudflare
HTML page served with an XML content type), and a news screen that goes blank
because one publisher broke their feed is worse than one that shows four
categories instead of five.

Sources, as of July 2026:
  time.mk        /rss/{makedonija,skopje,sport,kultura,svet,ekonomija}
                 — per-category feeds, titled in Macedonian by the source
  makthes.gr     Εφημερίδα Μακεδονία, Thessaloniki. One feed, no categories.

thestival.gr went behind a Cloudflare challenge and answers 403 to everything
that is not a browser; in.gr and pressdisplay broke before it. Any Greek
source here should be assumed temporary — hence ALLOWED_HOSTS below rather
than a hardcoded pair of URLs.
"""

import html
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

TTL = 600.0          # 10 minutes; a headline is not worth a request per view
TIMEOUT = 8.0
MAX_ITEMS = 12

# The proxy takes a URL from the page, so it needs a leash: without this it is
# an open relay that anything on the box's network could point anywhere.
ALLOWED_HOSTS = {
    "time.mk", "www.time.mk",
    "makthes.gr", "www.makthes.gr",
    "emakedonia.gr", "www.emakedonia.gr",
}

_cache = {}
_lock = threading.Lock()

_TAG_RE = re.compile(r"<[^>]+>")
_ITEM_RE = re.compile(r"<item\b.*?</item>", re.S | re.I)
_TITLE_RE = re.compile(
    r"<title\b[^>]*>\s*(?:<!\[CDATA\[(.*?)\]\]>|(.*?))\s*</title>", re.S | re.I)
_LINK_RE = re.compile(
    r"<link\b[^>]*>\s*(?:<!\[CDATA\[(.*?)\]\]>|(.*?))\s*</link>", re.S | re.I)


class FeedError(Exception):
    """One sentence, shown on the news screen in place of a row."""


def allowed(url):
    try:
        host = urllib.parse.urlsplit(url).netloc.lower()
    except ValueError:
        return False
    return host in ALLOWED_HOSTS


def _clean(text):
    """Strip tags and entities, collapse whitespace, keep it one line.

    A headline is never wrapped anywhere in this UI — it is one row, always.
    The old teletext page learned that when a wrapped headline got split
    across a subpage break, and the marquee has the same constraint for a
    different reason."""
    if not text:
        return ""
    text = html.unescape(_TAG_RE.sub(" ", text))
    return re.sub(r"\s+", " ", text).strip()


def _parse_xml(data):
    root = ET.fromstring(data)
    items = []
    # RSS 2.0 puts items under channel; Atom uses <entry> at the root.
    for node in root.iter():
        tag = node.tag.rsplit("}", 1)[-1].lower()
        if tag not in ("item", "entry"):
            continue
        title = link = ""
        for child in node:
            ctag = child.tag.rsplit("}", 1)[-1].lower()
            if ctag == "title" and not title:
                title = _clean(child.text or "")
            elif ctag == "link" and not link:
                link = _clean(child.text or "") or child.attrib.get("href", "")
        if title:
            items.append({"title": title, "link": link})
        if len(items) >= MAX_ITEMS:
            break
    return items


def _parse_loose(text):
    """Regex fallback for feeds ElementTree refuses. Deliberately dumb: find
    <item> blocks, take the first <title> in each."""
    items = []
    for block in _ITEM_RE.findall(text)[:MAX_ITEMS]:
        m = _TITLE_RE.search(block)
        if not m:
            continue
        title = _clean(m.group(1) or m.group(2) or "")
        if not title:
            continue
        lm = _LINK_RE.search(block)
        items.append({"title": title,
                      "link": _clean(lm.group(1) or lm.group(2) or "") if lm else ""})
    return items


def fetch(url):
    if not allowed(url):
        raise FeedError("feed host is not allowed")

    now = time.monotonic()
    with _lock:
        hit = _cache.get(url)
        if hit and now - hit[0] < TTL:
            return hit[1]

    req = urllib.request.Request(url, headers={
        # A plain urllib user-agent gets a 403 from more publishers every
        # year. This is not evasion, it is the minimum to be served at all.
        "user-agent": ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                       "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"),
        "accept": "application/rss+xml, application/xml, text/xml, */*",
    })
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            raw = r.read(4_000_000)
    except urllib.error.HTTPError as e:
        # 403 here almost always means a bot challenge, not a dead feed.
        raise FeedError("%s: HTTP %d" % (urllib.parse.urlsplit(url).netloc, e.code)) from e
    except (urllib.error.URLError, TimeoutError) as e:
        raise FeedError("cannot reach %s" % urllib.parse.urlsplit(url).netloc) from e

    text = raw.decode("utf-8", "replace")
    if "<html" in text[:400].lower():
        raise FeedError("%s served a web page, not a feed"
                        % urllib.parse.urlsplit(url).netloc)

    try:
        items = _parse_xml(raw)
    except ET.ParseError:
        items = _parse_loose(text)
    if not items:
        items = _parse_loose(text)
    if not items:
        raise FeedError("no headlines in the feed")

    result = {"items": items[:MAX_ITEMS]}
    with _lock:
        _cache[url] = (now, result)
    return result


if __name__ == "__main__":
    import sys
    for u in sys.argv[1:] or ["https://time.mk/rss/makedonija"]:
        try:
            for it in fetch(u)["items"]:
                print("%-14s %s" % (urllib.parse.urlsplit(u).path.rsplit("/", 1)[-1], it["title"]))
        except FeedError as e:
            print("%s: %s" % (u, e))
