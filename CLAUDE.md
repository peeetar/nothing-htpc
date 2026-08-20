# CLAUDE.md — nothing-htpc

Context for AI coding agents working on this repo. Read fully before changing
anything.

**This file was rewritten on 30 July 2026, when the remodel landed on main, and
retargeted on 13 August 2026, when the Raspberry Pi was dropped.**
[REMODEL.md](REMODEL.md) is the decision record for both and explains *why*
each thing below is the way it is. The last commit of the old design is tagged
`pre-remodel`.

## What this is

A home theater box ("cable box + streaming box"). Boots with no desktop
environment straight into a custom launcher. Owner: petar.

## Target hardware — read this before optimising anything

**The Raspberry Pi 3B+ is out of the picture as of 13 August 2026.** Do not
reintroduce its constraints. Two targets now, in this order:

1. **A Fedora x86_64 Lenovo laptop** (Ryzen 7 PRO 5850U, integrated Radeon) —
   the development *and* acceptance machine. The box is taken to production
   ready here, not on the target. This is why `dev-session.sh` matters as much
   as `start-session.sh`, and why "works on the laptop" is now a meaningful
   claim rather than a half-test.
2. **An AMD-GPU HTPC** — production. Everything is installed and ported there
   once it is finished on the laptop.

Both run `amdgpu` and the same VA-API decode path, so what holds on one very
likely holds on the other. `install.sh` detects `dnf` or `apt` and uses that
distro's package names — do not reintroduce a hardcoded `apt-get`.

Both decode H.264, HEVC, VP9 and AV1 in hardware, both have real RAM, and both
run Steam. That inverts three years of assumptions:

- **The playback envelope is a preference, not a correctness rule.** 2160p and
  HEVC/VP9/AV1 are allowed by default. `HTPC_MAX_HEIGHT` and
  `HTPC_ALLOW_HEVC` exist to *tighten* the envelope on weak hardware, never to
  loosen it. Nothing is ever dropped for being outside it — it sorts last.
- **`theme.json`'s reduced profile is `lite`, not `pi3`.** It is a generic
  low-power fallback kept because the profile *mechanism* is worth having, not
  a description of a board anyone still owns.
- **GAMING is a real tile again** and launches Steam Big Picture inside
  gamescope. It was cut in July 2026 for the Pi's sake; the tile model was
  deliberately kept general enough to take it back, and in August 2026 it did.

**Keyboard first.** Gamepad testing is deferred, so every function on every
screen must be reachable from a keyboard. A feature that only a controller can
reach is not finished. See constraint 30.

## Architecture (do not restructure)

```
boot → systemd (system/htpc-session.service, Conflicts=getty@tty1)
     → cage (Wayland kiosk)
     → system/start-session.sh
         ├─ mpv --idle --input-ipc-server=…    video, BOTTOM layer
         │    └─ cabletv/shim.lua              failure/retry only, draws NOTHING
         ├─ chromium --kiosk (transparent)     ALL UI, TOP layer
         ├─ server/server.py                   backend on 127.0.0.1:8484
         ├─ daemon/homebutton.py               evdev: HOLD guide 0.7s → POST /home
         ├─ daemon/cecd.py                     HDMI-CEC → uinput keys; standby → /home
         └─ spotifyd (if installed)            Spotify Connect endpoint

GAMING tile → POST /launch/gaming → system/gamescope-session.sh
                                      └─ gamescope → steam -gamepadui
```

**One page draws every pixel — except a game.** `launcher/index.html` +
`app.js` render HOME, TV, MOVIES, SHOWS, NEWS, WEATHER and MUSIC. mpv runs for
the whole session and is never restarted per channel — that is what removes the
black frame between menu and picture. GAMING is the single tile that starts a
process, because a game needs the display and cannot be drawn into a page.

**Order matters.** cage raises the newest window, so mpv must start before
Chromium.

**A web page cannot open a unix socket**, so `server.py` bridges to mpv's IPC:
`POST /player/load`, `POST /player/stop`, `GET /player/state`.

**The folder layout is load-bearing.** Service, scripts and server find each
other by relative path (`system/`, `server/`, `launcher/`, `daemon/`,
`cabletv/`, `test/`). Never flatten, rename, or move these directories —
including `cabletv/`, which now holds only `channels.m3u` and `shim.lua`.

**There is no deploy step and no install prefix.** The box runs the checkout
where it stands; `install.sh` copies nothing. Every component locates itself
from its own file. The single exception is `ExecStart=` in
`htpc-session.service`, which systemd requires to be absolute — `install.sh`
rewrites that line, alongside `User=` and `XDG_RUNTIME_DIR=`. Never
reintroduce `/opt/htpc` or any fixed path; updating the box is `git pull` +
restart.

## Hard-won constraints (violating these reintroduces solved bugs)

1. `htpc-session.service` runs `User=petar`, `XDG_RUNTIME_DIR=/run/user/1000`.
   A username/uid mismatch crash-loops with `status=217/USER`. `install.sh`
   rewrites both from the invoking user; keep that working and keep the
   comment explaining it.
2. cage needs a DRM device and the user needs to be in `video`/`render`. On
   AMD that is `amdgpu` and it is there by default; on the laptop the same is
   true of `i915`/`xe`. Keep the two commented `WLR_RENDERER=pixman` lines in
   the unit for VMs and broken GPUs. (This constraint used to be about
   `dtoverlay=vc4-kms-v3d` on the Pi. `install.sh` still knows how to write
   that line when it finds a Pi boot config, which is harmless and costs
   nothing to leave in.)
3. **`theme.json` is the single source of truth for the UI.** Colour, type,
   spacing, motion, layout and every user-facing string. A hex value or an
   English word in `app.js` or the stylesheet is a bug — it is a value a
   reskin cannot reach — and `test/run-all.sh` fails the build for both.
4. **`cabletv/shim.lua` draws nothing.** If a change wants an `ass_` function,
   it belongs in `launcher/`. Handlers stay wrapped in `guard()` (pcall): a
   raise inside a handler once froze the whole box.
5. **The display dot-matrix face is Latin-only.** Content here is Macedonian
   Cyrillic and Greek. Never hand a possibly-non-Latin string to `dotSVG()` —
   it renders as blank spaces, which is exactly how the news screen lost its
   Greek source name. Use `heading()`, which falls back to the body font.
6. `server.py` and everything it imports is **stdlib-only.** The original
   reason was that the Pi had no pip packages; the reason it survives the Pi
   is better — no venv, no lockfile, no build step, and `git pull` is the
   whole update. Music shells out to `playerctl`; the catalogue talks plain
   HTTP to the Stremio addon protocol. Keep it that way.
7. Launcher artifacts: no localStorage/sessionStorage, no external font CDNs
   (dot glyphs are drawn, not typed). Weather = Open-Meteo, no key.
8. Channel numbers in `channels.m3u` (`tvg-chno`) are stable identities chosen
   by the owner. **Never renumber existing channels**; add at free numbers.
   990–999 is no longer reserved — teletext is gone. An entry with no number
   is skipped, never auto-assigned.
9. Volume is deliberately not controllable anywhere — that is the TV's job via
   HDMI-CEC. `cecd.py` ignores CEC volume keys on purpose.
10. **The playback envelope is a preference now, not a correctness rule.**
    Both x86 targets decode HEVC, VP9 and AV1 in hardware, so `stremio.py`
    allows 2160p and every modern codec by default. `HTPC_MAX_HEIGHT` and
    `HTPC_ALLOW_HEVC` **tighten** it for weak hardware; they are not there to
    loosen it. Nothing is ever *dropped* for being outside the envelope — it
    sorts last and the picker flags it `HEAVY`, because if every copy of a
    film is a 4K remux then playing one badly beats "no streams found".
    Ranking is: inside the envelope, then seeder bucket, then resolution, then
    raw seeders. The bucketing is the load-bearing part — ranking on the raw
    count lets 2,140 seeders beat 2,100 and decide a resolution jump, while
    still letting 1,200 beat 6, which is the difference between a film that
    plays and one that does not.
11. `daemon/cecd.py` must never be able to take the session down. It exits
    quietly when `cec-ctl` or `/dev/cec0` is absent, degrades to
    power-sync-only when `/dev/uinput` is unwritable, and retries forever with
    backoff. It taps keys (press+release) rather than tracking CEC
    press/release state: a dropped RELEASED would wedge the box behind an
    autorepeating arrow. Keep all three properties.
12. There is no suspend. `cec-tv.sh` is a manual on/off/status helper, and TV
    standby means "return to launcher". Don't reintroduce systemd-sleep hooks.
13. **GAMING is back (13 August 2026) and is the only tile that starts a
    process.** `system/gamescope-session.sh` runs Steam Big Picture
    (`-gamepadui`) inside gamescope, because the session is a cage kiosk with
    no window manager and bare Steam would get no fullscreen, no resolution
    control and no controller focus. It probes for both binaries rather than
    assuming them (same rule as constraint 25) and covers the Flatpak Steam.
    Launching it stops mpv first — otherwise a channel keeps its audio under
    a game whose picture has covered it. Tuning is environment, not config:
    `HTPC_GAME_RES`, `HTPC_GAME_REFRESH`, `HTPC_GAMESCOPE_ARGS`.

    **Steam is fatal to miss; gamescope is not.** Exiting 127 for a missing
    gamescope meant the tile did nothing at all on a box with a perfectly good
    Steam — strictly the worse outcome, since bare Big Picture is still usable
    with a controller. A missing gamescope is now a loud warning and a
    degraded launch.
14. **Views are stacked and cross-dissolved**, with the incoming one fading up
    over a still-opaque outgoing one. A symmetric crossfade dips through black
    at 50% and defeats the whole point. No veil on view transitions.
15. Music is spotifyd's MPRIS interface via `playerctl` (subprocess, so
    `server.py` stays stdlib-only) — deliberately not the Spotify Web API,
    which would drag in a client ID, an OAuth flow and a stored refresh token
    for a box with no keyboard. Needs a spotifyd `full` build (`dbus_mpris`)
    and `use_mpris = true`.

    **Poll cadence is three states, not two**: 1s on the music view, 6s
    anywhere else *while a player is connected*, and **stopped entirely** when
    nothing is connected and the music view is not up. The last one matters —
    the old loop polled every 6s forever, so a box with no phone paired ran
    `playerctl` ten times a minute all day and filled the journal with "No
    players found". Entering MUSIC restarts the loop, because that is the only
    moment a player can be discovered from a standing start. "Connected" means
    a player exists, not that it is playing: a paused session still belongs on
    the home strip.
16. Cover art is proxied through `/music/art` rather than linked, so the canvas
    the halftone is read off stays untainted. Keep the proxy.
17. **Nothing a launched app prints may be discarded.** `server.py` pipes each
    app's stdout+stderr through a pump thread tagged `[<tile id>]`, and a
    reaper logs the exit code and duration. Restoring `DEVNULL` brings back the
    original bug: a tile that opened and closed with no trace.
18. **Public endpoints are weather, not infrastructure.** `torrentio.strem.io`
    stopped resolving entirely while `strem.io` stayed up; the Greek news feed
    has broken three times (pressdisplay → in.gr → thestival). Both are
    therefore *lists* with failover, configured by env
    (`HTPC_STREAM_ADDONS`) — one dead host costs a retry, not a rebuild.
19. The `/news` proxy takes a URL from the page, so it keeps a **host
    allowlist** in `feeds.py`. Without it, it is an open relay for anything on
    the box's network.
20. **The TMDB key is the one permitted exception to "no API keys".** It is
    optional, free, non-expiring, and needs no OAuth; everything degrades to
    Cinemeta's keyless data without it. Do not add a second keyed service
    without a comparably strong argument.
21. **There is no demo mode.** Every Ⓐ press is a real action, and failures
    show the backend's actual message. `?fixtures=1` is an explicit developer
    flag that stands in for HTTP calls a laptop cannot make — it never fakes a
    launch or a stream. Don't reintroduce a "would launch X" path.
22. **The detail panel's bottom half is kind-dependent, and only ever one of
    the two.** A film gets reviews; a show gets a season tab strip and an
    episode list. Reviews are not fetched for a series at all — that half of
    the panel is spent. An episode is played by the id Cinemeta already
    carries (`tt11198330:1:3`), which is exactly what the stream addons index
    series by, so nothing resolves a title twice.
23. **Long text scrolls; it is never clipped and faded.** A review taller than
    its panel crawls up at `review-scroll-px-per-s` and holds at both ends,
    and nothing advances to the next review until it has. The clip-and-fade
    this replaced ate the end of every review worth reading. Same rule as the
    news marquee: px/s against the measured overflow, so length changes the
    duration and never the speed.
24. **Long lists are windowed, not scrolled.** The channel list, the episode
    chooser and the stream picker render `channel-list-rows` /
    `detail-episode-rows` / `source-list-rows` rows and move the window with
    the cursor. A show with 700 episodes, a hundred-channel m3u and a film
    with ninety torrents must each cost what eight rows cost. This began as
    the 1 GB budget; it survives the Pi because it is also the only way a
    cursor stays instant, and because a wall of ninety rows is unreadable from
    a sofa whatever the machine can afford to draw.
25. **Never hardcode `chromium` (or any tool's binary name).** Debian calls it
    `chromium`, Fedora calls the same thing `chromium-browser`.
    `start-session.sh` and `dev-session.sh` probe the same list in the same
    order; a preflight that finds a browser the session then cannot is worse
    than no preflight. Chromium exiting *is* the end of the session, so
    getting this wrong looks like the box refusing to boot. The same rule now
    covers `gamescope` and `steam` in `gamescope-session.sh` — and Steam has
    three plausible names, one of which is a Flatpak.
26. **mpv's video output is left alone on the box and overridden nowhere
    else but `HTPC_MPV_VO_ARGS`.** In a nested, software-rendered cage the
    default gpu-next dies on an assertion in `vo_x11_init` — on the first
    `loadfile`, not at startup, so it presents as a broken stream. Measured:
    default dies on play, `wlshm` cannot hold an idle window, and
    `--vo=gpu --gpu-api=opengl --gpu-context=wayland` survives both. Do not
    "simplify" this to one VO for everything; on a real box mpv's own choice
    is the one that gets hardware decode.
27. **A socket file is not a running process.** mpv's IPC socket outlives
    mpv, so `mpvipc.available()` connects rather than calling `os.path.exists`,
    and a refused connection reports "player is not running" — the same
    sentence as no socket at all. Reverting either turns a killed session into
    a UI that draws a channel bar over a picture nothing is producing, and
    into two mysterious test failures after any kiosk run.
28. **The channel list slides in over the picture and never replaces it.**
    That is the payoff of the one transparent page: a menu over live video,
    with no black frame and nothing restarted. Red marks the channel that is
    on, the glow marks the row the cursor is over, and they are usually
    different rows — which is the clearest illustration in the product of why
    the accent is spent on state and never on focus.
29. **A failed stream offers the other copies; it never ends at a message.**
    A torrent is not a channel — the copy the ranking picked can simply not be
    there, and the only useful answer is the next copy. So a failed `/play`
    shows the backend's sentence *and* opens the stream picker under it. The
    picker is the channel list's twin on purpose: same windowing, same two
    markers, mirrored to come in from the right because it belongs to the
    detail panel rather than to the picture.

    The page never handles an infoHash or a magnet. `GET /streams/<kind>/<id>`
    hands back a row index per stream and `POST /play` takes that index back,
    which is what keeps resolving — and TorrServer — entirely server-side.
    The list is cached for `HTPC_STREAM_TTL` (5 min) so that an index still
    means the same stream when the choice comes back; an index out of range is
    an error and never a clamp, because silently playing something other than
    the selected row is the one behaviour a picker must not have.
30. **Every function is reachable from the keyboard.** Gamepad testing is
    deferred, so the keyboard is the primary input, not a fallback. Intents
    (`onNav`, `onOk`, `onBack`, `onDigit`, `onHome`, `onSources`) are routed by
    whichever view is up — there is no per-screen key handling anywhere, and a
    new screen gets input by joining that routing rather than by adding a
    listener. `onHome` posts `/home` like the gamepad and CEC paths do, so all
    three take the identical route rather than three near-copies. Handled keys
    call `preventDefault()`: this is a fixed viewport, and the default arrow
    and space behaviour scrolls the whole UI out from under the cursor.
31. **A successful `/launch` only means the process started.** That is a much
    weaker claim than it reads as — a missing Steam exits 127 a tenth of a
    second later. The launcher therefore watches `/status` for ~3s and reports
    an early death with its exit code. Without it the TV says RUNNING and then
    sits on the launcher, which is the original tile-that-opens-and-shuts bug
    wearing a toast.
32. **Whether the page is composited over mpv is a capability, not an
    assumption** — `HTPC_UI_TRANSPARENT`, reported to the page as
    `/config` → `ui.transparent`.

    Measured 13 August 2026, and it is the reason this exists: under a nested
    cage Chromium logs *"Server doesn't support zcr_alpha_compositing_v1"* and
    its surface never gets an alpha channel, so the TV screen's transparent
    body composited against nothing and rendered as **the browser's white
    default** — over a Sitel stream that was decoding happily at 854x480
    behind it. White reads as a crash, which makes it the worst of the
    available failures and much worse than black.

    `dev-session.sh` therefore sets `HTPC_UI_TRANSPARENT=0` whenever it nests,
    and additionally runs mpv **on the host desktop** rather than inside cage
    (`HTPC_NO_MPV=1` tells `start-session.sh` to leave it alone), so live TV
    can actually be developed here: UI in the cage window, picture beside it.
    That is not the product — it is the only arrangement in which the product
    can be worked on before the AMD box exists.

    A real kiosk boot still defaults to transparent. **That path remains the
    one load-bearing unproven piece of the architecture**, and it is now known
    to fail in at least one real configuration rather than merely being
    untested. `?opaque=1` forces it off for a quick look.
33. **The session starts TorrServer** if it can find one and nothing is
    already answering on 8090. Until August 2026 nothing did, so a box with
    the binary sitting in `~/.local/bin` still answered every Ⓐ press with
    "torrserver is not running" — an accurate message about a problem the
    session could simply have avoided. It is probed, not assumed (constraint
    25); it is optional and non-fatal, since only MOVIES and SHOWS touch it;
    and `dev-session.sh` starts its own so that cleanup kills exactly the
    process it started rather than pattern-matching for somebody else's.
    `TORRSERVER_URL` being set means "somebody else owns it" — do not start
    one then.
34. **Which file inside a torrent gets played is matched by name, never by
    arithmetic.** Torrentio's `fileIdx` counts the torrent's *whole* file
    list; TorrServer's `id` counts *its own* listing of the same torrent, and
    on a season pack the two drift apart. `stremio.py` assumed they differed
    by one. Measured 20 August 2026 against live Torrentio and TorrServer:
    asking for Sherlock S01E01 sent `fileIdx` 8 as index 9, and TorrServer's
    ninth file is S03E03 — **the box played the wrong episode while every
    layer reported success**, which is the worst shape a bug can take here.

    Torrentio states the file outright in `behaviorHints.filename` and
    repeats its path as the second line of `title`, so nothing has to be
    counted. `_pick_file()` matches on the basename, falls back to the SxxExx
    in the id it was asked for, and **returns nothing when neither matches** —
    TorrServer then serves the largest file, which is right for the
    single-file torrent most films are and, for a pack, is at least not a
    confident wrong answer. Do not reintroduce an index computed from
    `fileIdx`.
35. **The TV screen is the passthrough surface for everything mpv plays, and
    only live TV owns the dial.** `tv.mode` is what separates the two. A
    successful `/play` used to call `showView("tv")` with the dial still
    live, so `tvEnter()` → `tvShow()` → `tvLoad()` tuned a channel over the
    film 450 ms after it started — with `tvEnter()` fetching the channel list
    first when it was empty, so it fired on every path. **MOVIES and SHOWS had
    therefore never played a film to the end.** In `ondemand` mode nothing
    touches the player: the bar carries the title instead of a number, no row
    in the channel list is marked live, and the list still opens over the
    picture (constraint 28) because switching to live TV has to stay one press
    away. Anything that means "a channel is on" — zapping, the keypad, a pick
    off the list — goes through `tvShow()`, which is the one place that sets
    the mode back.
36. **`/config` sends the page only what the page reads.** It used to send the
    whole config file, which handed the browser the TMDB key — a key the page
    has no use for, because every TMDB call is made in `tmdb.py`. The bind is
    loopback-only so nothing off-box could ask, but a secret that is never
    sent cannot leak from somewhere nobody thought to look. Add a key to
    `PUBLIC_CONFIG_KEYS` deliberately or not at all.

## Design language

Pure black `#000`, ink `#EDEDED`, exactly one red accent `#D71921`. Dot-matrix
for display text, letterspaced uppercase mono for labels, body font for
content (and body copy is the one place the UI is not uppercase — Cyrillic and
Greek are unreadable in caps at couch distance). Generous emptiness, no
gradients, no shadows except the white selection glow, no rounded cards. Red
marks *state*, never focus — focus is the glow. If a change makes it look like
a modern streaming app, it's wrong.

## How to test changes (no display needed)

```bash
test/run-all.sh          # syntax + 67 backend tests + 113 UI render tests
test/test_ui.sh --shots /tmp/shots     # writes a PNG per screen
system/dev-session.sh --check          # preflight: syntax, tools, port
system/dev-session.sh --vm             # whole kiosk, nested in a window
```

The UI tests load the real launcher in headless Chromium and assert what each
screen drew — the only way to catch the failure that matters here, where a JS
exception during boot leaves a black screen that looks exactly like a working
box showing a black screen. `?view=`, `?sel=`, `?detail=1`, `?list=1` (the TV
screen's channel list) and `?sources=1` (the stream picker) navigate without a
gamepad.

**The laptop is now the acceptance machine**, so most of what used to be
"untestable off the box" is testable: the kiosk, the layering, the picker and
the whole UI can be driven here. What is still genuinely untestable on a
laptop, and must never be "fixed" from desktop behaviour:

- **HDMI-CEC** — needs a real CEC line and a real TV.
- **The GAMING tile end to end** — gamescope nested inside a nested cage is
  not a sensible thing to run. The launch path, the probing and the failure
  reporting are all testable; a game actually rendering is not.
- **The transparent-Chromium-over-mpv layering on the production box.** It now
  works on the laptop, which is a real result and retires most of the risk,
  but the AMD box has a different GL stack. If the UI appears on black with no
  video there, that is the suspect — the documented fallback is mpv into a
  page-reserved region, which keeps all the UI code.

## Deployment

- Install/update is `system/install.sh` (idempotent; `--dry-run`, `--check`).
  It installs the unit, permissions and boot config only — no file copying.
  Re-run after moving the clone; `--check` flags a stale `ExecStart`.
- Config precedence is `HTPC_CONFIG` env > `server/config.local.json` >
  `server/config.json`. **`config.local.json` is untracked and is where the
  box's own settings live** — coordinates, the TMDB key — so they survive a
  `git pull`. Never put a real key in the tracked `config.json`.
- TorrServer is optional and not installed by `install.sh`; only MOVIES and
  SHOWS need it. A debrid key in `TORRENTIO_OPTS` removes BitTorrent from the
  box entirely and is the cheapest available upgrade — with one, every stream
  in the picker is a direct HTTPS link and marked `DIRECT`.
- Steam and gamescope are also not installed by `install.sh`. The GAMING tile
  says which one is missing and how to install it, on the TV and in the
  journal, which is better than a preflight that fails an unrelated install.
- Packaging as a flashable image is an open question with a written decision:
  see PACKAGING.md. **It needs revisiting** — it was written for pi-gen and
  the target is now x86.

## Conventions

- Keep everything runnable from a fresh `git clone` + README steps. No build
  step, no bundlers, no package.json. Single-file components.
- Update README.md, cabletv/README.md and `install.sh` when behaviour or
  install steps change; the READMEs are the owner's runbook and install.sh is
  where knowledge about the box accumulates.
- Commit style: short imperative subject, body explains the *why* when fixing
  a gotcha. Future maintainers rely on it.
- When adding channels from user-provided m3u playlists: extract name + URL
  only, strip quality/geo tags from names, assign the next free number unless
  told otherwise, note geo-blocked entries with a comment.
