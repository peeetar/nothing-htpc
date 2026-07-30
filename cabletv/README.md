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
#EXTINF:-1 tvg-chno="101",MRT 1
http://example.com/mrt1.m3u8
```

`tvg-chno` is a fixed identity chosen by the owner. **Never renumber an
existing channel**; add at a free number. Gaps are fine — tuning an empty
number shows the "no signal" indicator, which is a black screen and three
dots, not static.

An entry with no `tvg-chno` is skipped rather than auto-numbered: a channel
with no identity would move every time the file was edited.

Parsed by `server/channels.py`, served to the launcher at `GET /channels`.

Prefer H.264. The Pi 3B+ has no HEVC, VP9 or AV1 hardware decoder and 1080p is
the ceiling (CLAUDE.md constraint 11). On x86 that relaxes.

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
channel died is worse than being told, and every poll on a 1 GB Pi is real
work.

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
