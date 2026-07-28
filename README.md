# nothing-htpc

A controller-only home theater box with a Nothing-OS-inspired shell:
pure black, dot-matrix clock, one red dot, four tiles. No desktop
environment, no Kodi, nothing to break on update.

It runs on a **Raspberry Pi 3B+ cable-tied behind the TV**. No tower,
no fan, one HDMI cable and one power lead.

- **TV** — a real 1990s cable box: channel numbers, a keypad, static on
  dead channels, teletext. Live channels *and* the on-demand library live
  behind this one tile, both addressed by channel number — films are on
  993, series on 994 (see [cabletv/README.md](cabletv/README.md))
- **MUSIC** — a now-playing screen built into the launcher itself, not a
  separate app: the box is a Spotify Connect speaker, the phone picks the
  music, and the TV shows it with no black screen in between
- **HDMI-CEC** — the Pi has a real CEC line, so **the TV remote drives
  the whole thing**. Arrows and OK navigate the launcher; channel
  up/down and the number keys work in cable mode.
- **Controller optional** — an 8BitDo pad still works everywhere; hold
  the guide button ~1 s in any app to return to the launcher.

Idle footprint is roughly 400–500 MB of the Pi's 1 GB, and ~0 % CPU at
the menu.

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
`cabletv.sh` shrinks its buffers on small machines. It works, but there
is no headroom for a second heavy app.

## How it works

```
boot → systemd → cage (Wayland kiosk) → chromium --kiosk → launcher/index.html
                                   ↘ server.py    (:8484, launches/kills apps)
                                   ↘ homebutton.py (hold guide button → /home)
                                   ↘ cecd.py       (TV remote → keys, TV off → home)
                                   ↘ spotifyd      (Spotify Connect endpoint)
```

`server.py` reads `server/config.json`; each tile maps either to a
`command` (a process) or to a `view` (a screen inside the launcher page —
currently just MUSIC). Launching a tile kills the previous app's whole
process group, so there is always exactly one foreground app, or the
launcher. If a command is missing or fails, the launcher says so on
screen — there is no demo mode.

Repo layout (**the folder structure is load-bearing** — the service,
scripts and server all find each other by relative path):

```
launcher/index.html          the UI
server/server.py             backend
server/config.json           tiles + weather coords
server/config.local.json     optional, untracked, wins over the above
server/config.vm.json        stand-in apps for testing on a dev machine
daemon/homebutton.py         hold-guide-to-go-home daemon
daemon/cecd.py               HDMI-CEC: TV remote → uinput, TV standby → home
cabletv/                     old-school cable TV mode for the TV tile
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
weather (open-meteo.com, no API key); teletext page 992 is a separate,
fixed three-city forecast set in `cabletv/cabletv.lua` — and pick your app
commands. Either edit `server/config.json` directly, or
— better, since the repo is now live — copy it to
`server/config.local.json` and edit that. The backend prefers the
`.local` one when it exists and git ignores it, so your coordinates and
app choices survive every `git pull`.

Paths inside a tile's `command` can use `$HTPC_DIR`, which the backend
expands to the repo root:

```json
"command": ["bash", "$HTPC_DIR/cabletv/cabletv.sh"]
```

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
chmod +x system/*.sh cabletv/cabletv.sh daemon/*.py
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

| TV remote | Launcher | Cable mode |
|---|---|---|
| ◀ ▶ | move between tiles | keypad, teletext subpages, letter-jump on 993/994 |
| ▲ ▼ | — | teletext subpages, cursor on 993/994 |
| OK | open tile | select |
| Back | — | back |
| Exit / Menu | return to launcher (via `POST /home`) | return to launcher |
| Ch +/− | — | change channel |
| 0–9 | — | tune directly |
| Guide | — | teletext guide (999) |

Volume is deliberately absent: it is the TV's job, over its own remote.

**Power follow.** At startup the Pi wakes the TV and claims the input.
When the TV goes to standby the daemon returns to the launcher, which
kills whatever was streaming — no point pulling an IPTV stream at a dark
screen. The Pi itself stays up; it has no suspend to enter.

If `/dev/uinput` is not writable the daemon logs it and carries on doing
power follow only, so a permissions slip costs you the remote, not the box.

---

# Apps

## TV

One tile, `cabletv/`, which is its own thing entirely — channel numbers,
keypad, static, teletext. See [cabletv/README.md](cabletv/README.md).

Live channels live in `cabletv/channels.m3u`; free IPTV lists come from
[iptv-org](https://github.com/iptv-org/iptv). Prefer H.264 streams.

On-demand films and series are teletext pages 993 and 994, read from
`cabletv/library.tsv`. Highlight a row, press OK, mpv plays it — the same
loadfile path a channel uses. The file has four columns
(`kind, title, year, url`) and the player never learns where the titles came
from; whatever fills the file does the parsing.

### The on-demand backend

What fills it is `server/movieapi.py`, and **it does not run on the Pi.** It
is a FastAPI daemon that holds an ee3 session, and it lives on its own LXC at
`192.168.1.16:1209`. That separation is the point: `server.py` and
`gen_static.py` are stdlib-only because the Pi has no pip packages and no
room in 1GB for a second daemon, so anything with dependencies goes on
another box. Nothing on the Pi imports it — the Pi talks HTTP to it through
`cabletv/ee3resolve.py`, which is stdlib.

```
Pi                                  LXC 192.168.1.16:1209
  cabletv.lua  ── ee3resolve.py ──►   movieapi.py ──► ee3.me
                                                 └──► torrentio
```

| Endpoint | |
|---|---|
| `GET /health` | auth state (no password in the reply) |
| `GET /movies` | proxy of ee3's `/api/movies`; all filters pass through |
| `GET /resolve/{id}` | one movie id → a URL mpv can open |
| `GET /library.tsv` | the whole catalogue, ready for `cabletv/library.tsv` |

Credentials come from the environment, never the repo:

```bash
# on the LXC
pip install fastapi httpx uvicorn
printf 'EE3_USERNAME=you\nEE3_PASSWORD=secret\n' > server/ee3.env  # gitignored
chmod 600 server/ee3.env
EE3_ENV_FILE=server/ee3.env python3 server/movieapi.py
curl -s localhost:1209/health
```

`server/ee3-api.service` is a unit for it. On the Pi, refresh the catalogue
with `cabletv/ee3resolve.py --library` and set `EE3_API` if the daemon is not
at the default address.

`/resolve` filters what it offers to what a 3B+ can actually decode: H.264,
1080p max, no HEVC/VP9/AV1. That is the same constraint as everywhere else in
this project, applied at the point where a stream gets chosen — a 2160p HEVC
remux is not "better quality" on this box, it is a slideshow. Override per
call with `?max_height=` / `?allow_hevc=true` if you ever run it against
something bigger.

Prior to July 2026 there was a separate STREAMING tile running
`jellyfin-mpv-shim` as a phone-cast target. It is gone — the remote drives
everything now, so there is no longer a mode where you need a second
device in your hand to choose something to watch. Nothing stops you
putting it back on the APPS tile if you want casting again.

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
  tv         bash /home/petar/nothing-htpc/cabletv/cabletv.sh
  music      view 'music' — launches no process
```

Then it streams the whole session into the one terminal, tagged by
process, and to a log file (`--log=FILE`, otherwise `/tmp/htpc-dev-*.log`):

```
server | 21:04:11 [launch] tv -> bash /home/petar/nothing-htpc/cabletv/cabletv.sh
server | 21:04:11 [tv] bash: /home/petar/nothing-htpc/cabletv/cabletv.sh: No such file or directory
server | 21:04:11 [app] tv exited on its own after 0.0s (exit code 127)
server | 21:04:11 [app] tv died immediately — the [tv] lines above are why
```

**A tile that opens and closes again is this, every time.** The backend
used to send launched apps to `/dev/null`; now it relays their output
line by line, tagged with the tile id, and logs how and when they died —
on the Pi that lands in `journalctl -u htpc-session` too. `/status` also
carries a `last_exit` field with the id, exit code and how long it ran.

`HTPC_DEBUG=1` is what turns the tagging, the HTTP access log and
Chromium's `--enable-logging=stderr` on; dev-session sets it for you
(`--quiet` doesn't). `CABLETV_DEBUG=1` additionally puts mpv at
`--msg-level=all=v`, which is where stream and decoder failures show up.

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

Syntax checks, no display needed:

```bash
python3 -m py_compile server/server.py daemon/*.py cabletv/gen_static.py
bash -n system/*.sh cabletv/cabletv.sh
luac5.4 -p cabletv/cabletv.lua
python3 -c "import json; json.load(open('server/config.json'))"
```

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

**Cable TV static is choppy.** Every static frame is an uncompressed
screenful of BGRA handed to mpv — 8.3 MB at 1080p — so the frame rate is
straight memory bandwidth. `cabletv.sh` already drops to 15 fps on machines
under 1.5 GB; if you overrode `CABLETV_STATIC_FPS`, that is why. The noise
field itself is generated once per resolution into `~/.cache/cabletv/`
(12 MB at 1080p); delete it to force a regenerate.

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
   gamescope). It is gone from the launcher and the config — restore it by
   adding an app entry with id `gaming` and an icon in `launcher/index.html`.

None of the memory tuning hurts on a big machine; `cabletv.sh` detects
RAM and skips it.
