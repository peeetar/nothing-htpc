# cabletv/

Two files. That is the whole directory now.

```
channels.m3u   the live TV dial — owner-chosen numbers, never reassigned
shim.lua       mpv-side failure handling. Draws nothing.
```

Until July 2026 this folder held a 2,105-line Lua script that drew an entire
1990s cable box in ASS subtitles: a banner, a keypad, animated analog static,
and teletext pages for news, weather, films and series. All of that is HTML
now, in `launcher/`. What is left here is the part that has to live next to
mpv, because mpv is what learns about it first.

The folder name stayed because the layout is load-bearing — `server.py` and
`start-session.sh` find things by relative path.

## channels.m3u

The live dial, and the only place channel numbers still exist. The clean split
took them away from everything else: films, series, news and weather are
screens in the launcher, not pages you tune to, so 990–999 is no longer
reserved for teletext and is simply free.

```
#EXTINF:-1 tvg-chno="3",Sitel
https://teve.mk/tvstanici/s1/playlist.m3u8
```

`tvg-chno` is a fixed identity chosen by the owner. **Never renumber an
existing channel**; add at a free number. Gaps are fine — tuning an empty
number shows the "no signal" indicator, which is a black screen and three
dots, not static.

An entry with no `tvg-chno` is skipped rather than auto-numbered: a channel
with no identity would move every time the file was edited.

Parsed by `server/channels.py`, served to the launcher at `GET /channels`, and
browsed on the TV screen through the **channel list** — Ⓐ slides it in over the
picture, ▲ ▼ moves, Ⓐ tunes, Ⓑ dismisses. The list draws
`channel-list-rows` rows at a time and windows the rest, so the length of this
file is not a cost to the UI. Order on screen is this file sorted by number,
which is the only ordering that exists.

Codec no longer matters here. The Pi's H.264-only ceiling is gone (13 August
2026) — both x86 targets decode everything in hardware, so a 1080p HEVC
channel is as good as an H.264 one.

## The lineup, rebuilt 13 August 2026

**53 channels, every one probed and working**, in five blocks:

| Range | What |
|---|---|
| 1–29 | Macedonia |
| 30–39 | Greece |
| 40–49 | World news |
| 50–59 | Music |
| 60–89 | Cartoons and kids |

The goal was **geo-free**: everything here answers from an ordinary European
connection with no VPN, no user-agent games and no referrer header. Streams
that only worked with a browser user-agent were rejected rather than worked
around — mpv would need the header carried through this file, and the channel
would break again the next time the operator tightened it.

### What "working" means here

A URL counts only if the playlist parses, **a variant under it answers, and a
segment under that answers**. That last hop is the whole point: a master
playlist over a dead origin returns 200 and shows black, which is
indistinguishable from a broken box at the sofa. Checking only the top level
is how a channel list full of dead channels looks healthy.

### Dead entries keep their number and lose their URL

A number is an identity: deleting channel 9 today and re-adding it in
September would land it somewhere else. So an entry with no working source
keeps its `#EXTINF` line and has its URL commented out, with a note saying
what was tried.

`server/channels.py` skips an `#EXTINF` whose URL is commented, so a reserved
number costs nothing and **never shows up as a black channel**. Putting one
back is uncommenting a line, or pasting a new URL under it.

Four requested channels are in that state:

- **MRT 1** and **Telma** — no working public source of any kind. The CDN that
  carried half the Macedonian dial (`vipottbpkstream.vip.hr`) now refuses
  connections outright, `teve.mk`'s `s1`/`s2` subdomains went with it, and the
  MRT 1 URLs still in circulation carry a 30-minute signed token. Telma is not
  in iptv-org at all and its own site exposes no playlist URL to a plain GET.
- **ERT1 / ERT2 / ERT3** — genuinely geo-fenced to Greece. Their CDN 307s to
  `msvdn.net`, which answers 401 "Content blocked by security policy". ERT
  News on the same CDN is open, which is how you can tell it is policy and not
  breakage.
- **Cartoon Network / Boomerang / Adult Swim** — no free feed exists anywhere.
  Warner keeps them behind a TV-provider login.

This is constraint 18 in the ordinary course of business — these are public
endpoints, they are weather, and a dead one costs a comment rather than a
rebuild.

### To re-probe

Checks all three levels, the way the lineup was built:

```bash
python3 - <<'PY'
import concurrent.futures as cf, sys, urllib.parse, urllib.request
sys.path.insert(0, "server"); import channels

def get(url, n=200_000):
    req = urllib.request.Request(url, headers={"user-agent": "libmpv"})
    with urllib.request.urlopen(req, timeout=12) as r:
        return r.read(n), r.geturl()

def first(body, base):
    for line in body.decode("utf-8", "replace").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            return urllib.parse.urljoin(base, line)

def probe(c):
    try:
        body, final = get(c["url"])
        if not body.lstrip().startswith(b"#EXTM3U"):
            return c, "not a playlist"
        child = first(body, final)
        if not child:
            return c, "empty playlist"
        cbody, cfinal = get(child, 64_000)
        if cbody.lstrip().startswith(b"#EXTM3U"):      # master -> variant
            g = first(cbody, cfinal)
            if not g:
                return c, "empty variant"
            cbody, _ = get(g, 32_000)
        return c, "live" if len(cbody) >= 512 else "empty segment"
    except Exception as e:
        return c, "%s: %s" % (type(e).__name__, str(e)[:40])

rows = channels.load()
with cf.ThreadPoolExecutor(max_workers=12) as ex:
    for c, why in sorted(ex.map(probe, rows), key=lambda r: r[0]["no"]):
        print("%4d %-24s %s" % (c["no"], c["name"][:24], why))
PY
```

## shim.lua

mpv runs for the whole session — started by `start-session.sh` with `--idle`,
an IPC socket, no OSC, no OSD and no default keybindings — and the launcher
composites over it. It is told what to play through `server.py`'s IPC bridge,
so the UI never needs a script here.

This file therefore **draws nothing**. If you find yourself writing an `ass_`
function in it, the change belongs in `launcher/` instead.

What it does handle is the three things that are awkward to see from the far
side of a socket, because mpv knows them first:

- a stream that fails to open, or dies mid-play
- retrying a dead live channel every 12 s (`HTPC_RETRY_SECONDS`)
- publishing which of those happened, as `user-data/htpc`, so `/player/state`
  returns it in the same round trip as position and cache state

The UI could poll for all of it, but discovering four seconds late that a
channel died is worse than being told.

Handlers are wrapped in `guard()` (a `pcall`). There are no format strings
left in here — the bug that once froze the whole box was a `:format()`
argument-count mismatch raised inside a key handler — but the rule that scar
earned is cheap to keep.

## Testing without a display

```bash
# syntax
luac5.4 -p cabletv/shim.lua

# run mpv the way the session does, then drive it over the socket
rm -f /tmp/htpc-t.sock
mpv --vo=null --ao=null --idle=yes --no-config \
    --input-ipc-server=/tmp/htpc-t.sock --script=cabletv/shim.lua &

MPV_IPC_SOCKET=/tmp/htpc-t.sock python3 - <<'PY'
import sys; sys.path.insert(0, "server")
import mpvipc
print(mpvipc.state())
mpvipc.load("http://127.0.0.1:1/nope.m3u8")   # fails on purpose
import time; time.sleep(4)
print(mpvipc.get("user-data/htpc"))           # -> failed: True
PY
```

Unix socket paths max out at 108 characters — a socket under a deep scratch
directory fails with "Could not create IPC socket" and nothing else.

`test/run-all.sh` covers the bridge against a fake mpv, so a real one is only
needed when changing this file.

## What is not here any more

`cabletv.lua`, `cabletv.sh`, `input.conf`, `gen_static.py`, `fonts/`,
`ee3resolve.py`, `torrentstream.sh` and `library.tsv`. All recoverable from
git history, or from the `pre-remodel` tag. `REMODEL.md` says why each one
went.
