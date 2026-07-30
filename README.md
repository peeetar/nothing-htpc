# nothing-htpc

A controller-only home theater box with a Nothing-OS-inspired shell:
pure black, dot-matrix type, one red accent, six screens. No desktop
environment, no Kodi, nothing to break on update.

It runs on a **Raspberry Pi 3B+ cable-tied behind the TV**. No tower,
no fan, one HDMI cable and one power lead.

**One page draws everything.** mpv runs underneath for the whole session,
idle when nothing is on, and the launcher is composited over it — so
opening a screen starts no process and there is never a black frame
between the menu and the picture.

- **TV** — live channels, zapped by number. A bar at the bottom carries
  the channel number, its name and the clock, then fades. Numbers live
  here and nowhere else (see [cabletv/README.md](cabletv/README.md))
- **MOVIES / SHOWS** — a poster grid over the Stremio addon protocol:
  Cinemeta for the catalogue, Torrentio for streams, TorrServer to play
  them. Five rows to a page, and a detail panel with credits and reviews
- **NEWS** — Time.mk by category across the top half, Θεσσαλονίκη across
  the bottom, headlines scrolling
- **WEATHER** — Skopje, Ljubljana and Θεσσαλονίκη: current conditions
  and three days each
- **MUSIC** — the box is a Spotify Connect speaker; the phone picks the
  music and the TV shows it
- **HDMI-CEC** — the Pi has a real CEC line, so **the TV remote drives
  the whole thing**. Arrows and OK navigate everywhere; the number keys
  tune channels.
- **Controller optional** — an 8BitDo pad works everywhere; hold the
  guide button ~1 s to return home.

Every colour, size, spacing, duration and user-facing string in the whole
UI comes from one file, [`launcher/theme.json`](launcher/theme.json).
Editing it restyles the product; nothing else should need touching.

Idle footprint is roughly 400–500 MB of the Pi's 1 GB, and ~0 % CPU at
the menu.

> **The July 2026 remodel replaced the retro cable-TV mode.** The 1990s
> pastiche — analog static, teletext pages, the ASS-drawn banner — is
> gone, along with the ee3 backend that fed it. [REMODEL.md](REMODEL.md)
> is the decision record. The last commit before it is tagged
> `pre-remodel`.

> Moving from the old x86 build? See [PACKAGING.md](PACKAGING.md) and the
> [x86 notes](#appendix-the-x86-tower-build) at the end. The Pulse-Eight
> CEC adapter, the suspend/wake hooks and the GAMING tile are all gone —
> the Pi has no S3 sleep and is not a games machine.

## Hardware

| Part | Used here | Notes |
|---|---|---|
| Computer | Raspberry Pi 3B+ | 1 GB RAM, quad A53 @1.4 GHz, HDMI 1.4 |
| Power | **5 V 2.5 A official supply** | see the warning below — this one matters |
| Cooling | heatsink, ideally a vented case | it will sit in still air behind a panel |
| Storage | 16 GB+ A1 microSD | or boot from USB |
| CEC | none — it is on the HDMI connector | the reason a Pi works here at all |
| Controller | 8BitDo Ultimate 2C (optional) | 2.4 GHz dongle or Bluetooth |
| NAS | anything running Jellyfin | Docker or native |

### Three things about the 3B+ that shape everything else

**Do not power it from the TV's USB port.** It is the obvious move when
you are hiding a Pi behind a TV, and it is wrong: TV USB ports supply
500–900 mA, the 3B+ wants 2.5 A. You get brownouts under load, which on
a Pi means corrupted SD cards rather than a clean crash. Use the real
supply. (It also means the Pi stays on when the TV is off — which is
what you want; CEC handles the rest, and idle draw is ~2 W.)

**No HEVC decoder.** The 3B+ decodes H.264 in hardware up to 1080p and
has nothing at all for H.265, VP9 or AV1. H.264 streams are smooth;
1080p HEVC will stutter no matter how you configure mpv. Prefer H.264
sources, and set your Jellyfin library to transcode to H.264 for this
client. Output tops out at 1080p — there is no 4K path here.

**1 GB of RAM, shared with the GPU.** This is why Chromium runs with a
64 MB JS heap and one renderer, why Feishin (Electron) is gone, and why
mpv's demuxer buffers are shrunk in `start-session.sh`. It works, but
there is no headroom for a second heavy app. `theme.json`'s `pi3` profile
is what keeps this machine viable — fewer posters in flight, less motion,
a narrower grid.

## How it works

```
boot → systemd → cage (Wayland kiosk)
                  ├─ mpv --idle --input-ipc-server   video, BOTTOM layer
                  │    └─ cabletv/shim.lua           failure/retry only, draws nothing
                  ├─ chromium --kiosk (transparent)  ALL UI, TOP layer
                  ├─ server.py    (:8484)            static UI, catalogue, mpv bridge
                  ├─ homebutton.py                   hold guide button → /home
                  ├─ cecd.py                         TV remote → keys, TV off → home
                  └─ spotifyd                        Spotify Connect endpoint
```

mpv starts **first** and Chromium **second**, because cage raises the
newest window and the UI has to be on top. mpv stays running for the
whole session and is never restarted per channel — that is what removes
the black frame.

A web page cannot open a unix socket, so `server.py` is the bridge:
`POST /player/load`, `POST /player/stop` and `GET /player/state` marshal
JSON onto mpv's IPC socket. It is still stdlib-only.

`server/config.json` no longer lists tiles — every screen is in the
launcher page. It carries the home screen's weather coordinates and an
optional TMDB key. The `apps` list and the launch/kill machinery stay for
whatever comes next (a gamescope tile is the expected one). If something
fails, the launcher says so on screen — there is no demo mode.

Repo layout (**the folder structure is load-bearing** — the service,
scripts and server all find each other by relative path):

```
launcher/index.html          markup + stylesheet (no literal values)
launcher/app.js              every screen, the dot-matrix engine, input
launcher/theme.js            loads theme.json onto :root as CSS variables
launcher/theme.json          THE ONE FILE — colour, type, spacing, motion,
                             layout, copy, and the pi3 hardware profile
server/server.py             backend: static UI, mpv bridge, endpoints
server/stremio.py            Cinemeta catalogue + Torrentio streams
server/tmdb.py               optional: credits and reviews (needs a key)
server/feeds.py              RSS proxy for the news screen
server/channels.py           channels.m3u parser
server/mpvipc.py             mpv IPC client
server/config.json           weather coords, optional tmdb_key
server/config.local.json     optional, untracked, wins over the above
server/config.vm.json        dev-machine config for dev-session.sh --vm
daemon/homebutton.py         hold-guide-to-go-home daemon
daemon/cecd.py               HDMI-CEC: TV remote → uinput, TV standby → home
cabletv/channels.m3u         the live dial
cabletv/shim.lua             mpv-side failure handling; draws nothing
test/run-all.sh              everything checkable without a Pi
system/install.sh            installer + `--check` auditor
system/dev-session.sh        run the whole thing on a dev machine
system/start-session.sh      what cage runs
system/htpc-session.service  boots straight into the kiosk
system/cec-tv.sh             manual TV on/off/status over CEC
system/99-htpc-input.rules   uinput + CEC device permissions
```

---

# Install

## The short way

Flash **Raspberry Pi OS Lite (64-bit)** with Raspberry Pi Imager. In
Imager's customisation screen set the hostname, your user, wifi and your
SSH key — that covers everything an install script should not be doing.

Then, over SSH:

```bash
git clone https://github.com/peeetar/nothing-htpc ~/nothing-htpc
cd ~/nothing-htpc
sudo ./system/install.sh
sudo reboot
```

That installs packages, writes the systemd unit with *your* username, uid
and *this clone's path*, sets up CEC and uinput permissions, enables
`vc4-kms-v3d`, and moves the journal to RAM.

**The box runs the clone, in place.** Nothing is copied to `/opt` or
anywhere else — the service is pointed at wherever you put the repo, and
everything inside it finds its siblings by relative path. Clone it to
`~/nothing-htpc`, to a USB stick, to `/opt/htpc` if you like the name; it
works the same. Two consequences worth knowing:

- Updating is `git pull` + `sudo systemctl restart htpc-session`. No
  redeploy step, and no way for the running copy to drift from the one
  you are editing.
- Moving or renaming the clone breaks the unit, because `ExecStart` is
  the one place that records the location. Re-run `install.sh` from the
  new path and it repoints itself. `--check` tells you if it is stale.

Preview it first with `./system/install.sh --dry-run`. Afterwards, audit
the box with:

```bash
./system/install.sh --check
```

which verifies the things that actually go wrong: `/dev/cec0` present,
groups right, service identity matching your uid, `ExecStart` pointing at
this checkout, backend answering.

Then set your latitude/longitude — this is the launcher's home-screen
weather (open-meteo.com, no API key). The WEATHER *screen* is a separate,
deliberately fixed three-city forecast set in `launcher/app.js`.

**Do not edit `server/config.json`.** The repo is live and runs in place,
so `git pull` would fight with local edits. Create
`server/config.local.json` instead — the backend prefers it when it
exists and git ignores it, so your settings survive every update:

```json
{
  "weather": { "lat": 41.9973, "lon": 21.4280 },
  "tmdb_key": "optional — see the Movies section"
}
```

If you ever add a tile that launches a process, paths in its `command`
can use `$HTPC_DIR`, which the backend expands to the repo root — so no
absolute path is baked in anywhere.

## The long way

Everything `install.sh` does, by hand, if you would rather see it:

```bash
sudo apt update
sudo apt install -y cage chromium mpv foot htop python3 python3-evdev \
    v4l-utils pipewire pipewire-audio wireplumber git curl
sudo usermod -aG input,video,render,audio "$USER"
echo uinput | sudo tee /etc/modules-load.d/uinput.conf
```

Add to `/boot/firmware/config.txt` (this is the file that moved out of
`/boot` in Bookworm — a lot of old guides are wrong about the path):

```
dtoverlay=vc4-kms-v3d
gpu_mem=96
```

`vc4-kms-v3d` is not optional. It provides the DRM device cage draws on
*and* `/dev/cec0`. Without it you get a black screen and a restart loop
that looks like a dead Pi.

There is no copy step — the clone stays where it is. All that's needed is
the udev rule and the exec bits git may not have carried:

```bash
sudo cp system/99-htpc-input.rules /etc/udev/rules.d/
chmod +x system/*.sh daemon/*.py test/*.sh
```

> **Three lines in the unit are machine-specific.** `User=petar` and
> `XDG_RUNTIME_DIR=/run/user/1000` must match your actual user and
> `id -u` — if they don't, the session crash-loops with `status=217/USER`.
> `ExecStart` must be the absolute path to *your* clone's
> `system/start-session.sh`; systemd will not take a relative one, so this
> is the only place in the project that names a location.
> `install.sh` rewrites all three for you; by hand, edit them.

```bash
sed -e "s|^User=.*|User=$USER|" \
    -e "s|^Environment=XDG_RUNTIME_DIR=.*|Environment=XDG_RUNTIME_DIR=/run/user/$(id -u)|" \
    -e "s|^ExecStart=.*|ExecStart=/usr/bin/cage -d -- $PWD/system/start-session.sh|" \
    system/htpc-session.service | sudo tee /etc/systemd/system/htpc-session.service
sudo systemctl disable getty@tty1
sudo systemctl enable htpc-session
sudo systemctl set-default graphical.target
sudo reboot
```

You should land on the dot-matrix clock.

---

# HDMI-CEC

This is the part the Pi does better than the tower it replaced: no
adapter, and the TV remote becomes the primary controller.

Check it works:

```bash
./system/cec-tv.sh status   # should list the TV
./system/cec-tv.sh on       # TV wakes, switches to this input
```

If nothing happens, enable CEC **on the TV** — every brand renames it
(Samsung: Anynet+, LG: Simplink, Sony: Bravia Sync, Philips: EasyLink).
It is off by default on many sets.

`daemon/cecd.py` then runs for the life of the session and does two things:

**TV remote → key events.** Incoming CEC button presses are replayed on a
uinput device, so they arrive at whatever is on screen as ordinary key
presses. Nothing in the launcher or in mpv knows CEC exists:

| TV remote | Home | Poster grid | Live TV |
|---|---|---|---|
| ◀ ▶ | move between tiles | move the cursor | — |
| ▲ ▼ | — | move a row, and page past the last one | change channel |
| OK | open | open the detail panel, then play | re-show the bar |
| Back | — | close the panel, then go back | stop and go back |
| Exit / Menu | — | return home (via `POST /home`) | return home |
| Ch +/− | — | — | change channel |
| 0–9 | — | — | tune directly |

One set of intents, routed by whichever screen is up — the gamepad, a
keyboard and the TV remote all arrive at the same four handlers.

Volume is deliberately absent: it is the TV's job, over its own remote.

**Power follow.** At startup the Pi wakes the TV and claims the input.
When the TV goes to standby the daemon returns to the launcher, which
kills whatever was streaming — no point pulling an IPTV stream at a dark
screen. The Pi itself stays up; it has no suspend to enter.

If `/dev/uinput` is not writable the daemon logs it and carries on doing
power follow only, so a permissions slip costs you the remote, not the box.

---

# Screens

None of these is an app. Every one is a screen in the launcher page, so
opening one starts no process and shows no black frame.

## TV

Live channels from `cabletv/channels.m3u`, tuned by number — the only
place numbers still exist. Free IPTV lists come from
[iptv-org](https://github.com/iptv-org/iptv); prefer H.264.

Zapping does not wait for streams: the number and the bar change on the
keypress, and the stream is not opened until the number has sat still for
450 ms, so you can run up the dial without sitting through a load per
channel. Three digits tune instantly, fewer after a two-second pause.

A dead channel shows black and a three-dot indicator, and `shim.lua`
retries it every 12 s. There is no static any more.

## Movies and Shows

A poster grid over the Stremio addon protocol. Three layers, none of
which needs an account:

| | |
|---|---|
| **Cinemeta** `v3-cinemeta.strem.io` | catalogue, posters, plot, runtime, rating, cast |
| **Torrentio** `torrentio.strem.fun` | `infoHash` per title, ranked by seeders |
| **TorrServer** `127.0.0.1:8090` | turns that into an HTTP stream mpv can open |

A page is five rows; the viewport shows the two that fit and scrolls, and
running off the bottom turns the page. Ⓐ opens a detail panel — year,
runtime, rating, synopsis, credits, and user reviews with star ratings —
and Ⓐ again plays.

Stream choice is filtered to what the box can actually decode: H.264,
1080p max, no HEVC/VP9/AV1 on the Pi. That is a correctness rule, not a
preference — a 2160p AV1 remux is a slideshow on a 3B+. Raise it with
`HTPC_MAX_HEIGHT` and `HTPC_ALLOW_HEVC=1` on better hardware.

**Stream addons are a list, not a constant.** `torrentio.strem.io` — the
address every guide still gives — stopped resolving entirely by July 2026
while `strem.io` itself stayed up. Set `HTPC_STREAM_ADDONS` to a
comma-separated list; the default is `torrentio.strem.fun` then
`comet.elfhosted.com`, and one dead host costs a retry.

### TorrServer

Optional — everything except MOVIES and SHOWS works without it. One
static Go binary, no Node, no `peerflix`:

```bash
curl -L -o /usr/local/bin/torrserver \
  https://github.com/YouROK/TorrServer/releases/latest/download/TorrServer-linux-arm7
chmod +x /usr/local/bin/torrserver
torrserver --port 8090 --path ~/.cache/torrserver &
```

Point elsewhere with `TORRSERVER_URL`.

**The cheapest upgrade available is a debrid account.** With a key in
`TORRENTIO_OPTS` (e.g. `realdebrid=XXXX`), Torrentio returns direct HTTPS
links instead of magnets and TorrServer is never asked anything — no
BitTorrent on the box at all, and seeking works properly.

### Reviews and full credits (optional TMDB key)

Cinemeta gives a director, a writer and three cast for free, and no
reviews. For the producer, five cast and three user reviews with star
ratings you need a TMDB key — the only key this project wants.

```bash
# server/config.local.json — untracked, survives git pull
{ "tmdb_key": "your-key-here" }
```

Free at [themoviedb.org](https://www.themoviedb.org/settings/api). It
does not expire and there is no OAuth flow, which is why it is an
acceptable exception on a box with no keyboard. Without it the panel
simply shows the keyless set and the reviews block does not render.

## News

Time.mk across the top half, one scrolling row per category
(`makedonija`, `skopje`, `sport`, `kultura`, `svet`, `ekonomija`), and
Θεσσαλονίκη across the bottom. Headlines are never wrapped — one row
each, always.

Feeds are proxied through `server.py` (`GET /news?url=`) because the
browser cannot fetch them directly, behind a host allowlist in
`server/feeds.py` so the proxy is not an open relay.

**Greek sources keep dying.** pressdisplay, then in.gr, then
thestival.gr — which went behind a Cloudflare challenge and answers 403
to anything that is not a browser. It is `makthes.gr` now, which works
but publishes no category tags, so the bottom half is one row rather than
several. Expect to change it again.

## Weather

Skopje, Ljubljana and Θεσσαλονίκη — three fixed identities in
`launcher/app.js`, deliberately *not* the box's own coordinates from
`config.json`. Current temperature, condition, feels-like and wind, plus
three days with highs, lows and rain probability. Open-Meteo, no key.

## Music

The MUSIC tile is **not an app**. It is a second screen inside the
launcher page, so opening it starts no process, waits on nothing, and
never shows a black frame — the music screen fades up over the menu in
one motion, and Back fades straight back.

```
launcher  ──Ⓐ on MUSIC──►  music screen  ──Ⓑ / Back / TV Exit──►  launcher
             (no launch, no veil, ~220ms crossfade)
```

Playback itself is Spotify Connect: you pick music in the Spotify app on
your phone, and this box is the speaker. The screen shows what is playing
— cover art rendered as a halftone dot grid in the launcher's own visual
language, title in dot-matrix, artist and album in mono, a progress
line — and offers the only three controls a TV remote needs: previous,
play/pause, next. **No volume**, as everywhere else here.

When something is playing, the home screen also carries a one-line
now-playing strip above the tiles, so you can see it without opening
anything.

### Setup

```bash
sudo apt install playerctl
```

spotifyd must expose MPRIS on the session bus — that is where the
metadata and the controls come from, and it means no Spotify API key, no
OAuth, and no developer app registration.

1. Install spotifyd from its releases page to `/usr/local/bin/`, using a
   **`full` build** (`aarch64` for 64-bit Pi OS). The `slim` builds are
   compiled without the `dbus_mpris` feature and will show up here as
   "nothing playing" forever, however well the audio works.
2. In `~/.config/spotifyd/spotifyd.conf`:

```ini
[global]
use_mpris = true
dbus_type = "session"
device_name = "HTPC"
```

`start-session.sh` launches spotifyd inside the cage session, so it
shares a session bus with the backend. Check it end to end with:

```bash
playerctl -p spotifyd metadata          # what the launcher reads
curl localhost:8484/music/status        # what it gets back
```

If `playerctl` is missing or spotifyd has no MPRIS, the music screen says
so plainly and the launcher stops polling rather than spawning a
`playerctl` every few seconds for nothing.

Navidrome is not wired up. The old Feishin plan is gone — Electron will
not run in 1 GB — and nothing has replaced it; if you want the NAS music
library on the TV, that is still an open decision.

---

# Testing without a TV

You do not need the Pi, a spare screen, or a VM to work on this.

```bash
./system/dev-session.sh          # real config
./system/dev-session.sh --vm     # stand-in apps: color bars, test tone, htop
./system/dev-session.sh --check  # preflight only — start nothing
./system/dev-session.sh --quiet  # run it exactly like the service does
```

Inside an existing Wayland session, **cage nests itself in an ordinary
window** — you get the whole kiosk, launcher and all, in a window on your
desktop. From a bare TTY it takes the screen like the real service does.

## What it prints

Unlike the deployed service, dev-session is a debugging harness. Before
starting anything it syntax-checks the Python, bash, Lua and JSON, then
prints every tile with the command it will actually run — `$HTPC_DIR`
already expanded, exactly as the backend will run it — and whether that
binary exists:

```
tiles
  (none — every screen is in the launcher page)
```

Then it streams the whole session into the one terminal, tagged by
process, and to a log file (`--log=FILE`, otherwise `/tmp/htpc-dev-*.log`):

```
server | 21:04:11 [server] listening on 127.0.0.1:8484  (debug=on)
mpv    | [shim] htpc shim loaded — this script draws no UI
server | 21:04:19 [player] load http://…/mrt1.m3u8 (live)
server | 21:04:20 [play] movie tt0816692 -> Torrentio 1080p x264 👤 2081
```

**A tile that opens and closes again is this, every time.** The backend
relays a launched process's output line by line, tagged with the tile id,
and logs how and when it died — on the Pi that lands in
`journalctl -u htpc-session` too. `/status` carries a `last_exit` field
with the id, exit code and how long it ran. (With the tile list empty
this matters less than it did, but the machinery is still there for
whatever gets added next.)

`HTPC_DEBUG=1` turns on the tagging, the HTTP access log and Chromium's
`--enable-logging=stderr`; dev-session sets it for you (`--quiet`
doesn't).

Two things dev-session cleans up that the service gets from systemd: it
kills the backend and daemons on the way out (so the next run does not
hit "port 8484 is already in use"), and it names any absolute path in a
tile's command that does not exist here — which is the normal reason a
tile dies instantly.

On Fedora: `sudo dnf install cage chromium mpv foot`.
On Debian/Ubuntu: `sudo apt install cage chromium mpv foot`.

`--vm` points the backend at `server/config.vm.json` through the
`HTPC_CONFIG` environment variable, so it never overwrites a deployed
`config.json`. If cage or chromium are missing the script falls back to
running just the backend, and you open `http://127.0.0.1:8484` in any
browser — everything except the kiosk shell works there.

### The test suite

Everything checkable without a Pi, a TV or a CEC line:

```bash
test/run-all.sh
```

That is syntax for every language in the repo, 36 backend tests
(`python3 -m unittest discover -s test`), and 56 UI render tests that
load the real launcher in headless Chromium and assert what each screen
drew — which is the only way to catch the failure mode that matters here,
where a JS exception during boot leaves a black screen that looks exactly
like a working box showing a black screen.

```bash
test/test_ui.sh --shots /tmp/shots     # also writes a PNG per screen
```

The UI tests use `?fixtures=1`, a developer flag that stands in for the
HTTP calls a laptop cannot make. It never fakes a launch or a stream.
`?view=`, `?sel=` and `?detail=1` navigate to a screen without a gamepad.

It also fails the build if a hex colour or an English string appears in
`app.js` — those belong in `theme.json`, and a value that is not in the
theme is a value a reskin cannot reach.

**What it cannot cover, and never claims to:** HDMI-CEC, V4L2 hardware
decode, thermal throttling, power delivery, and the transparent-Chromium-
over-mpv layering. Do not "fix" any of those based on what it says.

Backend smoke test:

```bash
python3 server/server.py &
curl localhost:8484/config
curl -X POST localhost:8484/launch/tv
curl -X POST localhost:8484/home
```

**What cannot be tested off the Pi:** HDMI-CEC (needs the real line and a
real TV), hardware video decode, and thermal behaviour. Do not "fix"
those based on what a desktop does.

---

# Troubleshooting (field notes)

**Flickering screen / boot loop.** The session is crash-restarting every
2 s. SSH in, or switch to another terminal (**Ctrl+Alt+F2**), and:

```bash
journalctl -u htpc-session -b --no-pager | tail -30
```

- `status=217/USER` → the `User=` in the service doesn't exist on this
  machine. Fix the name and the uid in `XDG_RUNTIME_DIR`, then
  `systemctl daemon-reload && systemctl restart htpc-session`.
  `install.sh --check` catches this specifically.
- `status=1` right after a PAM "session opened" line → cage started but
  its target is missing or broken. First suspect: **flat repo layout**.
  GitHub's drag-and-drop web uploader flattens folders; everything must
  live in `launcher/ server/ daemon/ system/ cabletv/` exactly as here.
- wlroots/EGL/DRM errors → `dtoverlay=vc4-kms-v3d` is missing from
  `/boot/firmware/config.txt`. Check `ls /dev/dri` shows a `card*`.

**Random corruption, SD card errors, reboots under load.** Power. See the
2.5 A warning above; `vcgencmd get_throttled` returning anything other
than `0x0` means undervoltage or thermal throttling has happened.

**Everything is sluggish after 20 minutes.** Thermal throttling — the
3B+ eases its clock down from around 60 °C and throttles hard by 80 °C,
and "behind a TV" is still air. `vcgencmd measure_temp`. A heatsink is
not optional in an enclosed space.

**TV remote does nothing.** In order: is CEC enabled on the TV; does
`cec-tv.sh status` see it; does `journalctl -u htpc-session | grep cecd`
show "cannot open /dev/uinput" (udev rule / `input` group / reboot after
`usermod`); is the Pi the active source. Many TVs only forward remote
keys to the input they are currently showing.

**Debugging cage by hand:** log in *directly* as your user on a spare tty
(Ctrl+Alt+F3) — not via `su` from root, or libseat throws `Could not take
control of session` errors that look alarming but only mean the tty
belongs to root.

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
cage -d -- $PWD/system/start-session.sh
```

**App opens behind the launcher:** cage raises the newest window; apps
with splash screens may need a tiny sleep-wrapper.

**Controller dead in the launcher:** press any button once — the browser
Gamepad API only exposes pads after first input.

**The UI is up but the picture never appears.** This is the one
architectural risk in the remodel. The page is composited over mpv and
relies on Chromium handing Wayland a transparent surface; if it does not,
you get the interface painted on black with the video invisible behind
it. Check mpv is actually running and playing:

```bash
ls -l "$XDG_RUNTIME_DIR/htpc-mpv.sock"
curl -s localhost:8484/player/state
```

If `state` reports a path and a moving position, the player is fine and
this is the layering. The documented fallback is to drop
`--enable-transparent-visuals` and give mpv a geometry the page reserves
instead — the UI code is identical either way. See
[REMODEL.md](REMODEL.md).

**MOVIES says "torrserver is not running".** It is optional and not
installed by `install.sh`. See the Movies section.

**MOVIES says "no streams found".** Usually the addon host, not the film.
`torrentio.strem.io` is dead; the default list is
`torrentio.strem.fun,comet.elfhosted.com`. Check with:

```bash
python3 server/stremio.py streams tt0816692
```

---

# Updating

```bash
cd ~/nothing-htpc && git pull
sudo ./system/install.sh          # idempotent; keeps your config.json
sudo systemctl restart htpc-session
```

Whether this stays the update path, or gets replaced by re-flashing a
built image, is the open question in [PACKAGING.md](PACKAGING.md).

---

# Appendix: the x86 tower build

The original target was a Ryzen + Vega 56 box running Debian 13. It still
works, with three differences:

1. **CEC needs a Pulse-Eight USB adapter** — desktop GPUs have no CEC pin
   on HDMI. `cec-tv.sh` and `cecd.py` talk to the kernel CEC API, which
   the Pulse-Eight adapter also exposes as `/dev/cec0`, so both should
   work against it unchanged — but this is untested since the move.
2. **Suspend/wake exists**, unlike on the Pi. The old setup suspended the
   PC and woke it from the 8BitDo dongle; the udev rule for that is kept,
   commented out, at the bottom of `system/99-htpc-input.rules`.
3. **GAMING** was a tile here (`steam -gamepadui`, optionally under
   gamescope). It is gone from the launcher and the config. The tile model
   is deliberately kept general enough to take it back: add an entry to
   `apps` in the config, an icon and a `TILES` row in `launcher/app.js`.

The x86 build is also where the remodel is most comfortable. Drop the
`pi3` profile, raise `HTPC_MAX_HEIGHT`, set `HTPC_ALLOW_HEVC=1`, and the
whole playback envelope in CLAUDE.md constraint 11 relaxes — those limits
are a 3B+ fact, not a design position.
