# REMODEL — the Nothing-UI rebuild

Decisions taken 29 July 2026, before any code was written. This document is
the brief; CLAUDE.md still describes the box as it is *today* and gets
rewritten when this lands, not before.

## Why

The cable-TV half of the box is a 1990s pastiche drawn in ASS subtitles by a
2,105-line Lua script. The launcher half is a Nothing-styled dot-matrix UI
drawn in a browser. They share no code, no colours, no type and no motion, and
the retro half is the one the owner stopped wanting. This rebuild makes the
whole product one UI, drawn by one renderer, driven by one theme file.

## Decisions (locked)

| Question | Answer |
|---|---|
| Where the UI is drawn | **Chromium, transparent, composited above mpv** |
| Navigation model | **Clean split** — numbers belong to live TV only |
| `cabletv.lua` | **Minimal shim**, draws nothing |
| Typography | **Dot-matrix display face, clean mono body** |
| Static / noise | **Deleted.** Black + a minimal dot indicator |
| Movie backend | **Stremio protocol, self-hosted torrenting** |
| Posters | **Yes** — the on-demand UI is poster-first |
| Motion | **Expressive** — dots and glyphs animate |
| Theme file | **`theme.json`** → CSS custom properties + JS |
| Theme file covers | tokens, layout, motion **and copy** |
| Hardware | x86-first design, Pi 3B+ keeps working via a reduced profile |
| Gaming | Designed for, not built. Tile model stays general |
| Rollout | **New branch, big-bang, delete the old on merge** |

## Architecture after

```
boot → systemd (system/htpc-session.service, Conflicts=getty@tty1)
     → cage (Wayland kiosk)
     → system/start-session.sh
         ├─ mpv --idle --input-ipc-server=…/mpv.sock   ← video, BOTTOM layer
         │     └─ cabletv/shim.lua   (no drawing; failure/retry/zap only)
         ├─ chromium --kiosk (transparent bg)          ← ALL UI, TOP layer
         ├─ server/server.py         127.0.0.1:8484
         ├─ daemon/homebutton.py
         ├─ daemon/cecd.py
         └─ spotifyd
```

The browser cannot open a unix socket, so **`server.py` is the IPC bridge**:
`POST /player/load`, `POST /player/stop`, `GET /player/state` marshal JSON
onto mpv's socket. `socket` and `json` are stdlib, so constraint 7 survives
intact.

The single foreground-app model is gone for media. mpv is always running and
always idle-or-playing; the launcher is always up on top. There is no launch,
no veil and no black frame between the menu and a channel — the same property
MUSIC has today (constraint 15), extended to everything.

## Screens

```
HOME
 ├─ TV       live channels only. Zapping, keypad, channel bar.
 ├─ MOVIES   poster grid → detail → play
 ├─ SHOWS    poster grid → detail → play
 ├─ WEATHER  Skopje / Ljubljana / Θεσσαλονίκη, 3 days
 ├─ NEWS     Time.mk over Θεσσαλονίκη, categorised, autoscrolling
 └─ MUSIC    unchanged (spotifyd via playerctl)
```

No 99x numbers anywhere. `channels.m3u` keeps its `tvg-chno` numbering and
those numbers stay owner-chosen identities (constraint 9 survives for live
channels); 990–999 stops being reserved because teletext no longer exists.

### The live-TV channel bar

Full-width strip across the bottom, hairline rule above it, one row:

```
├─────────────────────────────────────┤
│ ███                                 │
│ ███ 101   MRT 1              21:04  │
└─────────────────────────────────────┘
```

Number in the dot-matrix display face, name in body mono, clock right-aligned.
Fades after ~5 s as the old banner did. No EPG — the box has no guide data and
adding an XMLTV source is out of scope for this rebuild.

### News

Two halves, split at the horizontal midline.

- **Top: TIME.MK.** Title, then rows of category boxes scrolling left. One row
  per category, each carrying that category's headlines.
  `https://time.mk/rss/{sport,skopje,makedonija,kultura,svet,ekonomija}` —
  all six verified live on 29 July 2026 and titled in Macedonian by the feed
  itself, so the category labels come from the source rather than from us.
- **Bottom: Θεσσαλονίκη.** Same treatment.

Headlines are still never wrapped — the old one-row rule (constraint 9) was
right and survives as a marquee rule. Autoscroll speed is a motion token.

## Backend

Three layers, all off-the-shelf, replacing ~900 lines of bespoke scraping:

| Layer | Was | Becomes |
|---|---|---|
| Catalogue + metadata | `server/movieapi.py` scraping ee3.me behind a login | **Cinemeta** — `v3-cinemeta.strem.io`. No auth, no key. Poster, plot, runtime, rating, genres |
| Stream resolution | `/resolve/{id}` → torrentio → magnet | **Torrentio direct** — `torrentio.strem.fun/stream/movie/{imdb}.json`. `infoHash` + `fileIdx`, ranked. A *list* of addons, not one (see below) |
| Torrent → HTTP | `torrentstream.sh` + peerflix/webtorrent (Node) | **TorrServer** — one static Go binary, HTTP API, built for streaming playback |

This deletes the ee3 session, the credentials-in-env-file handling, the LXC
daemon and the whole `library.tsv` cache-and-sync dance (constraint 19 becomes
moot — there is no cache file, the catalogue is a live HTTP call with an
in-memory TTL). The Pi-side client can be stdlib-only, so the "one piece
allowed pip dependencies" exemption ends with it.

Playback envelope still applies on the Pi profile: H.264, 1080p (constraint
11). On x86 hardware that filter relaxes; it becomes a profile value, not a
law baked into a query string.

## theme.json

One file. A loader stamps the token half onto `:root` as CSS custom properties
and hands the rest to JS. No build step, hand-editable, `_note` keys for
documentation the way `config.json` already does it.

```
theme.json
├─ tokens    colour, type scale, spacing scale, rules, radii
├─ motion    durations, easing curves, autoscroll speeds, fade timings
├─ layout    bar height, grid columns, poster aspect, panel widths
├─ copy      every user-facing string, so wording and localisation live here
└─ profiles  overrides — `pi3` cuts motion, blur and posters-in-flight
```

Changing this file restyles the product. That is the acceptance test: a
plausible second theme should be reachable by editing nothing else.

### Type

Two roles, per the Nothing house style itself:

- **Display** — dot-matrix. Clock, channel numbers, headings, big labels.
  Latin-only is acceptable here; these are numbers and short uppercase words.
- **Body** — a mono/grotesk with **full Cyrillic + Greek coverage**. Headlines,
  synopses, city names, everything that carries content.

Constraint 8 still holds: no external font CDNs. The body face ships in the
repo as woff2. Press Start 2P and the ASS font-install dance go away with the
Lua UI.

## What gets deleted on merge

- `cabletv/cabletv.lua` — 2,105 lines, replaced by a shim of roughly 150
- `cabletv/gen_static.py` and the BGRA frame cache (constraint 6 dies with it)
- `cabletv/input.conf` and `cabletv/fonts/`
- `server/movieapi.py`, `cabletv/ee3resolve.py`, `cabletv/torrentstream.sh`
- `cabletv/library.tsv` and its sync logic

Recoverable from git history. Nothing is deleted until the new path plays a
channel, browses a poster grid and draws the weather.

## Risks, in order

1. **Transparent Chromium over mpv under cage.** The whole architecture rests
   on it and it is unproven here. This is step 0 of the branch: prove the
   layering end-to-end on real hardware before building anything on top. If it
   fails, the fallback is mpv rendering into a region the page reserves, driven
   over the same IPC bridge — the UI code survives either way, which is why
   the spike is cheap to be wrong about.
2. **The Pi 3B+ profile.** Posters, expressive dot animation and a browser
   compositing over video on 1 GB is the tightest this project has ever been.
   The reduced profile is not a nicety; it is what keeps the current box alive.
3. **Greek news sourcing.** `thestival.gr` now answers Cloudflare's
   "Just a moment…" challenge (403) instead of RSS — the third Greek source to
   break, after pressdisplay and in.gr, and the Greek half of 991 has been
   silently empty on the box since. `makthes.gr` (Εφημερίδα Μακεδονία) works:
   200, 50 items, items carry images. But it publishes **no `<category>`
   tags and no section feeds**, so the bottom half cannot be categorised the
   way Time.mk's can. Open question — see below.
4. **Torrentio without debrid** returns magnets, so TorrServer has to actually
   download on the box. Seeking into an unbuffered film stays a worse
   experience than a direct HTTPS link. A debrid key remains the cheapest
   available upgrade and the design should keep that door open — the stream
   URL is a stream URL either way.
5. **Public stream addons are weather, not infrastructure.**
   `torrentio.strem.io` — the address every guide still gives — had stopped
   resolving on every public resolver by 29 July 2026, while `strem.io`
   itself stayed up. `torrentio.strem.fun` answers and returns 77 streams for
   a test title, so the addon is alive and the hostname moved. That is the
   same failure the Greek news source has had three times, so `stremio.py`
   takes a **list** of addons and tries them in order
   (`HTPC_STREAM_ADDONS`), defaulting to `torrentio.strem.fun` then
   `comet.elfhosted.com`. One dead host costs a retry, not a rebuild.

## Open questions

- **Greek news categories.** Either (a) run the bottom half uncategorised as a
  single ΘΕΣΣΑΛΟΝΙΚΗ row, (b) derive a category from each item's URL slug,
  which is guesswork, or (c) find a categorised Thessaloniki source. Not
  blocking — the layout works either way, the bottom half just has one row
  instead of several.
- **Hardware.** Pi 3B+ for now. If a box gets bought, the OptiPlex 3050
  (7th-gen, HD 630 — hardware VP9 and HEVC Main10) beats the 7040 (6th-gen,
  HD 530) for a difference that is not worth saving. If gaming via gamescope
  is genuinely coming, neither Mini competes with the Ryzen 7 / Vega 56 tower
  that already exists.

## Status

**Merged to main on 30 July 2026.** Built and green on a dev machine;
**nothing has run on the Pi yet.** The last commit of the old design is tagged
`pre-remodel` — `git checkout pre-remodel` is the whole rollback.

Done:

- `launcher/theme.json` — tokens, motion, layout, copy, and a `pi3` profile,
  loaded by `launcher/theme.js` and stamped onto `:root`
- `launcher/index.html` + `launcher/app.js` — HOME, TV, MOVIES, SHOWS, NEWS,
  WEATHER, MUSIC. No hardcoded colour or string survives in the JS; the test
  suite fails the build if one appears
- `server/stremio.py` — Cinemeta catalogue and Torrentio streams, multi-addon,
  ranked to the playback envelope. Verified live: real 2026 catalogue, and
  ranking picks 1080p x264 with 2081 seeders over the 4K AV1 copies that head
  the raw list
- `server/mpvipc.py` — the IPC bridge. Verified end to end against a real mpv:
  socket, `loadfile`, and the shim reporting a failed stream back
- `server/feeds.py` — RSS proxy with a host allowlist
- `server/channels.py` — parses the real 25-channel `channels.m3u`
- `cabletv/shim.lua` — 2,105 lines down to one file that draws nothing
- `system/start-session.sh` — mpv first (idle, IPC), Chromium second, on top
- `test/` — 36 backend tests, 33 UI render tests, syntax and theme-coverage
  checks. `test/run-all.sh` is the whole thing

Not done:

- **The layering spike.** Chromium's transparency over mpv under cage is
  wired up and unproven; it is risk 1 and it needs the actual box
- TorrServer is not installed or tested anywhere
- SHOWS uses the movie catalogue path end to end but series stream selection
  (which episode file) is untested
- No screen has been driven with a real gamepad or a real TV remote

Done since, on merge: the old code is deleted (`cabletv.lua`, `cabletv.sh`,
`input.conf`, `gen_static.py`, `fonts/`, `ee3resolve.py`, `torrentstream.sh`,
`library.tsv`, `movieapi.py`, `ee3-api.service`), and README.md,
cabletv/README.md, CLAUDE.md, install.sh, dev-session.sh and both configs
describe the new world.

The original plan said nothing would be deleted until the new path played a
channel on the Pi. That order was reversed at the owner's request so the box
could be configured from a clean `main` — which means **the Pi's next
`git pull` lands code that has never run on it.** `pre-remodel` exists for
exactly that reason.

## Constraints from CLAUDE.md that this rebuild retires

3, 4, 5, 6 (all cabletv.lua / ASS / static), 19 and 20 (library.tsv cache and
teletext compositing), and the teletext half of 9. Everything else stands —
notably 1 (uid/XDG_RUNTIME_DIR), 2 (vc4-kms-v3d), 7 (stdlib-only on the Pi),
8 (no CDNs, no storage), 10 (no volume control, ever), 12 (cecd.py can never
take the session down), 13 (no suspend), 15 (no veil between views), 16–17
(music via playerctl, art proxied) and 18 (nothing an app prints is discarded).
