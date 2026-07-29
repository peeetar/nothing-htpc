#!/usr/bin/env python3
"""
channels.m3u reader.

Live TV is the only place channel numbers still exist. The clean split took
them away from everything else — movies, shows, news and weather are screens
now — but `tvg-chno` inside cabletv/channels.m3u remains what it always was:
an owner-chosen identity. Numbers are never reassigned and gaps are fine.
990-999 used to be reserved for teletext and is now simply free.

Parsing is by hand rather than by library because an m3u is two lines per
entry and the file is edited by a person, so the failure this has to survive
is a typo, not a malformed spec.
"""

import os
import re
from pathlib import Path

HTPC_DIR = Path(__file__).resolve().parent.parent
M3U = Path(os.environ.get("HTPC_CHANNELS", HTPC_DIR / "cabletv" / "channels.m3u"))

_CHNO_RE = re.compile(r'tvg-chno="(\d+)"')
_NAME_RE = re.compile(r',\s*(.+?)\s*$')


def load(path=None):
    """-> [{"no": int, "name": str, "url": str}], sorted by number.

    Entries without a number are skipped rather than auto-assigned: a channel
    with no identity would move every time the file was edited, and the whole
    point of tvg-chno is that 101 is always 101.
    """
    p = Path(path or M3U)
    if not p.exists():
        return []

    out, pending = [], None
    for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#EXTM3U"):
            continue
        if line.startswith("#EXTINF"):
            m = _CHNO_RE.search(line)
            n = _NAME_RE.search(line)
            pending = {
                "no": int(m.group(1)) if m else None,
                "name": n.group(1) if n else "",
            }
        elif line.startswith("#"):
            continue                      # a comment, including geo-block notes
        elif pending:
            if pending["no"] is not None:
                out.append({**pending, "url": line})
            pending = None

    out.sort(key=lambda c: c["no"])
    return out


def find(no, path=None):
    return next((c for c in load(path) if c["no"] == no), None)


if __name__ == "__main__":
    for c in load():
        print("%4d  %-28s %s" % (c["no"], c["name"][:28], c["url"][:60]))
