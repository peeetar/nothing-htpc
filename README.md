# nothing-htpc

A home theater box with a Nothing-OS-inspired shell: pure black,
dot-matrix type, one red accent, seven screens. No desktop environment,
no Kodi, nothing to break on update.

**Targets, as of 13 August 2026:** a Fedora x86_64 laptop, where it is
developed and taken to production ready, and an **AMD-GPU HTPC** it is
installed on once it is finished. The Raspberry Pi 3B+ it ran on through
July 2026 is retired — see [the note below](#the-pi-is-gone).

**One page draws everything except a game.** mpv runs underneath for the
whole session, idle when nothing is on, and the launcher is composited
over it — so opening a screen starts no process and there is never a
black frame between the menu and the picture.

- **TV** — live channels, zapped by number or picked off a channel list
  that slides in over the picture. A bar at the bottom carries the
  channel number, its name and the clock, then fades. Numbers live here
  and nowhere else (see [cabletv/README.md](cabletv/README.md))
- **MOVIES / SHOWS** — a poster grid over the Stremio addon protocol:
  Cinemeta for the catalogue, Torrentio for streams, TorrServer to play
  them. Five rows to a page, and a detail panel that carries credits and
  scrolling user reviews for a film, and a season/episode chooser for a
  show. If a stream will not play, a **source picker** lists every other
  copy — quality, size, seeders, indexer — and one press plays a
  different one
- **NEWS** — Time.mk by category across the top half, Θεσσαλονίκη across
  the bottom, headlines scrolling
- **WEATHER** — Skopje, Ljubljana and Θεσσαλονίκη: current conditions
  and three days each
- **MUSIC** — the box is a Spotify Connect speaker; the phone picks the
  music and the TV shows it
- **GAMING** — Steam Big Picture inside gamescope. The one tile that
  starts a process, because a game needs the display
- **Keyboard first** — every function on every screen has a key. The
  gamepad is not tested yet, so nothing is reachable only by controller.
  See [the key map](#the-keyboard)
- **HDMI-CEC** — where the box has a CEC line, **the TV remote drives the
  whole thing**. Arrows and OK navigate everywhere; the number keys tune
  channels.

Every colour, size, spacing, duration and user-facing string in the whole
UI comes from one file, [`launcher/theme.json`](launcher/theme.json).
Editing it restyles the product; nothing else should need touching.

> **The July 2026 remodel replaced the retro cable-TV mode.** The 1990s
> pastiche — analog static, teletext pages, the ASS-drawn banner — is
> gone, along with the ee3 backend that fed it. [REMODEL.md](REMODEL.md)
> is the decision record. The last commit before it is tagged
> `pre-remodel`.

## The Pi is gone

**13 August 2026.** The Raspberry Pi 3B+ is no longer a target. The box
is being finished on a Fedora x86_64 Lenovo laptop and then installed on
an AMD-GPU HTPC.

That is not just a hardware swap — three rules the Pi imposed have been
inverted, and the code and the docs say so now:

| Was, for the Pi | Is, for x86 |
|---|---|
| H.264 only, 1080p max, enforced in stream ranking | HEVC/VP9/AV1 and 2160p allowed by default; `HTPC_MAX_HEIGHT` and `HTPC_ALLOW_HEVC` now *tighten* the envelope rather than loosen it |
| `theme.json`'s `pi3` profile kept a 1 GB board alive | renamed `lite` — a generic low-power fallback, not a description of a board anyone owns |
| GAMING tile removed; "design for it, don't build it" | GAMING is back, launching Steam Big Picture in gamescope |

What did **not** change: no build step, stdlib-only backend, one themed
page, windowed lists, and every string still in `theme.json`. Most of
those were justified by the Pi originally and turned out to be worth
keeping on their own merits.

The one thing genuinely lost is HDMI-CEC-by-default. The Pi had a CEC
line on its HDMI connector; a laptop does not, and a desktop needs an
adapter. `cecd.py` exits quietly when there is no `/dev/cec0`, so
nothing breaks — the TV remote simply does not drive the box until it
runs somewhere with CEC.

## Hardware

| Part | Development | Production |
|---|---|---|
| Computer | Lenovo laptop, Fedora, Ryzen 7 PRO 5850U | AMD-GPU HTPC |
| Graphics | Radeon (integrated), `amdgpu` | Radeon, `amdgpu` |
| Video decode | VA-API — H.264, HEVC, VP9, AV1 | same |
| Output | laptop panel | TV over HDMI, 1080p or 2160p |
| CEC | none | HDMI, or a Pulse-Eight adapter |
| Gaming | not usable (nested gamescope) | gamescope + Steam |
| Controller | 8BitDo Ultimate 2C — **not yet tested** | same |
| NAS | anything running Jellyfin | Docker or native |

**The two machines share a graphics stack**, which is the useful part:
the same `amdgpu` driver, the same VA-API decode path, the same mpv video
output. What is proven on the laptop is very likely to hold on the box —
which is exactly why the laptop is now the acceptance machine and not
just a convenience.

Both decode everything in hardware and have real RAM, so the 1 GB budget
that shaped the original design is gone. The habits it produced — one
renderer, windowed lists, no Electron tiles — are kept because they are
good habits, not because they are still forced.

Run `./system/install.sh --check` on either one; it detects `dnf` or
`apt`, uses that distro's package names, and audits everything that
actually goes wrong.

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
                             layout, copy, and the `lite` hardware profile
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

Install a minimal x86_64 Linux with no desktop environment — Fedora
Server / Everything-minimal, or Debian with no tasksel desktop. The box
boots straight into the launcher, so a display manager is something to
avoid rather than configure.

Then:

```bash
git clone https://github.com/peeetar/nothing-htpc ~/nothing-htpc
cd ~/nothing-htpc
sudo ./system/install.sh
sudo reboot
```

That installs packages, writes the systemd unit with *your* username, uid
and *this clone's path*, sets up CEC and uinput permissions, and moves the
journal to RAM. (On a Raspberry Pi it also enables `vc4-kms-v3d`; it
detects that from the boot config and does nothing on x86.)

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

Where there is a CEC line, the TV remote becomes the primary controller.
On x86 that means a Pulse-Eight USB adapter — desktop and laptop GPUs
have no CEC pin on HDMI. Without one, `cecd.py` exits quietly and nothing
else changes; the keyboard drives everything.

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

| TV remote | Home | Poster grid | Detail panel | Live TV |
|---|---|---|---|---|
| ◀ ▶ | move between tiles | move the cursor | change season (shows) | — |
| ▲ ▼ | — | move a row, and page past the last one | change episode (shows) | change channel |
| OK | open (or launch, on GAMING) | open the detail panel | play (the episode, on a show) | open the channel list, then tune |
| Back | — | go back | close the panel | close the list, then stop and go back |
| Exit / Menu | — | return home (via `POST /home`) | return home | return home |
| Ch +/− | — | — | — | change channel |
| 0–9 | — | — | — | tune directly |

A film's detail panel has nothing to move through — its reviews scroll
themselves — so ◀ ▶ ▲ ▼ do nothing there on purpose.

Volume is deliberately absent: it is the TV's job, over its own remote.

**Power follow.** At startup the box wakes the TV and claims the input.
When the TV goes to standby the daemon returns to the launcher, which
kills whatever was streaming — no point pulling an IPTV stream at a dark
screen. The box itself stays up; there is no suspend here.

If `/dev/uinput` is not writable the daemon logs it and carries on doing
power follow only, so a permissions slip costs you the remote, not the box.

## The keyboard

**Gamepad testing is deferred, so the keyboard is the primary input.**
Every function on every screen has a key; nothing is reachable only by
controller. This is the whole map:

| Key | Does |
|---|---|
| `←` `→` `↑` `↓` | navigate — and `A` `D` `W` `S` do the same |
| `PageUp` / `PageDown` | up / down (what a TV remote's Ch +/− arrives as) |
| `Enter` or `Space` | OK — open, play, tune, launch, play/pause |
| `Esc` or `Backspace` | back, one layer at a time |
| `H` or `Home` | return to the launcher — kills a running app and stops the player |
| `O` or `F3` | open the **stream picker** on a film or episode |
| `0`–`9` | tune a channel directly, on TV |

Three things worth knowing:

- **Back peels one layer at a time.** On the poster grid that is: picker
  → detail panel → grid → home. Collapsing two at once is how a press
  meant for the picker also stops the film behind it.
- **`H` takes the same route as the gamepad and the TV remote** — all
  three `POST /home`, rather than three near-copies of the same idea.
- **The picker has its own key rather than sharing `Enter`.** `Enter`
  already means "play this" on a detail panel, and the picker is what you
  reach for when that did not work.

Internally there is one set of intents — `onNav`, `onOk`, `onBack`,
`onDigit`, `onHome`, `onSources` — routed by whichever screen is up. The
keyboard, the gamepad and the TV remote all arrive at those six handlers,
and no screen has a key listener of its own.

---

# Screens

All but one of these is a screen in the launcher page, so opening it
starts no process and shows no black frame. GAMING is the exception and
has to be — a game needs the display.

## TV

Live channels from `cabletv/channels.m3u`, tuned by number — the only
place numbers still exist.

**The lineup was rebuilt on 13 August 2026 to be geo-free**: 53 channels,
every one of them probed from this machine, answering with a playlist,
a variant *and* a segment. That last check is the one that matters — a
master playlist over a dead origin returns 200 and shows black, which is
indistinguishable from a broken box at the sofa.

| Range | What |
|---|---|
| 1–29 | Macedonia — Sitel, Kanal 5, TV21, Nasha TV and the nasatv.com.mk music bouquet |
| 30–39 | Greece — ERT News, ANT1, Alpha, Skai, Star |
| 40–49 | World news — BBC News, CNN, Al Jazeera English, France 24, DW, Euronews, Sky News, Bloomberg |
| 50–59 | Music — MTV, MTV 2, MTV Classic, MTV Biggest Pop, Vevo, Trace |
| 60–89 | Cartoons and kids — the Nickelodeon bouquet, the Disney trio, and a set of free FAST channels |

**Four requested channels are not there, and the file says why on the
line where each one would be.** MRT 1 and Telma have no working public
source of any kind right now — the CDN that carried half the Macedonian
dial (`vipottbpkstream.vip.hr`) simply refuses connections, and the URLs
still in circulation for MRT 1 carry a 30-minute signed token. ERT1/2/3
are genuinely geo-fenced to Greece (their CDN answers 401 "Content
blocked by security policy"; ERT News on the same CDN is open, which is
how you can tell it is policy and not breakage). Cartoon Network,
Boomerang and Adult Swim have no free feed anywhere — Warner keeps them
behind a TV-provider login.

Those entries keep their numbers with the URL commented out, so the dial
keeps its shape and each is one uncommented line away from coming back.
`server/channels.py` skips an `#EXTINF` whose URL is commented, so a
reserved number never shows up as a black channel. Adding sources is
exactly this: paste an m3u in chat, or put a URL on the line.

Zapping does not wait for streams: the number and the bar change on the
keypress, and the stream is not opened until the number has sat still for
450 ms, so you can run up the dial without sitting through a load per
channel. Three digits tune instantly, fewer after a two-second pause.

A dead channel shows black and a three-dot indicator, and `shim.lua`
retries it every 12 s. There is no static any more.

**The channel list.** Ⓐ slides the dial in from the left, over the
picture — which keeps playing behind it, because the launcher is one
transparent page and never has to replace the video to draw a menu. ▲ ▼
moves the cursor, Ⓐ tunes, Ⓑ puts it away without changing channel. Nine
rows are drawn at a time (`channel-list-rows`) and the window moves with
the cursor, so a hundred-channel m3u costs the same to draw as a
ten-channel one.

The red dot marks the channel that is **on**; the white glow marks the
one the cursor is **over**. They are usually different rows, which is the
whole reason the design language spends its one accent on state and never
on focus.

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
runtime, rating, synopsis and credits — and Ⓐ again plays.

**The bottom of the panel differs by kind**, because a film and a show
want different things there.

*A film* gets user reviews with star ratings, one at a time, held and
then cross-faded. A review longer than the panel **scrolls itself**: it
holds at the top long enough to start reading, crawls up at
`review-scroll-px-per-s`, holds at the bottom, and only then moves on to
the next one. It used to clip at the fourth line and fade the rest out,
which loses the end of every review worth reading.

*A show* gets its own dial instead: a **season tab strip** (◀ ▶) and the
**episodes of the open season** beneath it (▲ ▼), with names where
Cinemeta has them and `EPISODE n` where it does not. Specials — anything
Cinemeta files under season 0 — are kept but sort last. Ⓐ plays the
episode the cursor is on, not the show: every episode already carries the
id the stream addons index it by (`tt11198330:1:3`), so choosing one
costs no extra lookup. Seven rows are drawn at a time
(`detail-episode-rows`) and the window moves with the cursor, so a show
with 700 episodes draws as cheaply as one with eight.

### The source picker

**A torrent is not a channel.** The copy the ranking picked can simply
not be there, and the only useful answer to that is the next copy — so a
failed play does not end at a message. It shows the backend's actual
sentence *and* opens a picker underneath it listing every other copy of
that film or episode. `O` (or `F3`) opens it deliberately at any time.

Each row is one stream: its quality as a dot-matrix tag, the indexer it
came from, its size, and its seeder count. `DIRECT` marks a debrid link,
which plays immediately; everything else is a torrent that has to find
peers first, and that is worth knowing before you press Ⓐ rather than
after. `HEAVY` marks a stream outside the playback envelope.

Eight rows are drawn at a time (`source-list-rows`), the window moves
with the cursor, and a popular film comes back with ninety copies — so
this is the same windowing the channel list and the episode chooser use,
for the same reason. Red marks the source that is playing, the glow
marks the row the cursor is over.

The page never handles an infoHash or a magnet. `GET /streams/<kind>/<id>`
returns the ranked list with a row index each, and `POST /play` takes
that index back, which keeps resolving — and TorrServer — entirely on the
backend's side.

### What gets picked first

**The playback envelope is a preference now, not a correctness rule.**
Both x86 targets decode HEVC, VP9 and AV1 in hardware, so 2160p and every
modern codec are allowed by default. This is the reverse of the Pi rule
it replaced: `HTPC_MAX_HEIGHT` and `HTPC_ALLOW_HEVC=0` now **tighten**
the envelope for weak hardware.

Nothing is ever dropped for being outside it — it sorts last and the
picker flags it `HEAVY`, because if every copy of a film is a 4K remux
then playing one badly beats "no streams found".

Ranking is: inside the envelope, then seeder bucket, then resolution,
then raw seeders. The bucketing is the load-bearing part. Ranking on the
raw count lets 2,140 seeders beat 2,100 and decide a resolution jump —
a difference nobody can perceive deciding one everybody can — while
still letting 1,200 beat 6, which is the difference between a film that
plays and one that does not.

**Stream addons are a list, not a constant.** `torrentio.strem.io` — the
address every guide still gives — stopped resolving entirely by July 2026
while `strem.io` itself stayed up. Set `HTPC_STREAM_ADDONS` to a
comma-separated list; the default is `torrentio.strem.fun` then
`comet.elfhosted.com`, and one dead host costs a retry.

### TorrServer

Optional — everything except MOVIES and SHOWS works without it. One
static Go binary, no Node, no `peerflix`:

```bash
# x86_64 — no root needed
curl -L -o ~/.local/bin/torrserver \
  https://github.com/YouROK/TorrServer/releases/latest/download/TorrServer-linux-amd64
chmod +x ~/.local/bin/torrserver
torrserver --port 8090 --path ~/.local/share/torrserver &
```

Point elsewhere with `TORRSERVER_URL`. `curl 127.0.0.1:8090/echo` answers
with its version when it is up, which is the quickest way to tell a dead
TorrServer from a title with no streams.

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

Reviews are fetched for films only — a show spends that half of the
panel on its episodes, so asking TMDB about it would be a round trip for
something never drawn.

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

Navidrome is not wired up. The old Feishin plan died with the 1 GB
budget and nothing has replaced it; if you want the NAS music library on
the TV, that is still an open decision. (An Electron tile is now
*possible* on x86 — it is just still a bad idea in a kiosk with no
window manager.)

## Gaming

**Steam Big Picture inside gamescope**, and the only tile that starts a
process. It came back on 13 August 2026, having been cut in July when the
box was a Pi.

```bash
# Fedora — Steam needs RPM Fusion nonfree
sudo dnf install gamescope steam
# Debian
sudo apt install gamescope steam
# or the Flatpak, which system/gamescope-session.sh also finds
flatpak install flathub com.valvesoftware.Steam
```

Neither is installed by `install.sh`. If one is missing the tile says
which and how to install it — on the TV as a toast, and in the journal
tagged `[gaming]`.

**If you keep a `server/config.local.json`, the GAMING entry has to be in
it.** That file wins over `config.json` key by key, so an empty `apps`
there hides every tile that launches a process. The entry is three lines:

```json
"apps": [
  { "id": "gaming", "label": "GAMING",
    "command": ["${HTPC_DIR}/system/gamescope-session.sh"] }
]
```

**Why gamescope and not bare Steam.** The session is a cage kiosk with no
window manager, so bare Steam gets no fullscreen, no resolution control
and no controller focus handling. gamescope is a nested compositor that
provides all three, and it is what the Steam Deck runs.

Tuning is environment, not config, because it belongs to the display
rather than to the box:

| Variable | Default | For |
|---|---|---|
| `HTPC_GAME_RES` | `1920x1080` | gamescope's *output* size |
| `HTPC_GAME_REFRESH` | `60` | output refresh |
| `HTPC_GAMESCOPE_ARGS` | — | anything else: `--hdr-enabled`, `--adaptive-sync`, `-F fsr` |

Launching stops mpv first — otherwise a channel keeps its audio going
underneath a game whose picture has covered it. Exit / Menu (or `H`)
returns to the launcher and kills the session.

**This is the one thing that cannot be finished on the laptop.**
gamescope nested inside a nested cage is not a sensible thing to run. The
launch path, the binary probing and the failure reporting are all tested
here; a game actually rendering waits for the AMD box.

---

# Testing without a TV

You do not need the box, a spare screen, or a VM to work on this — and
since 13 August 2026 the laptop is the *acceptance* machine, not just a
convenience.

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
and logs how and when it died — under the service that lands in
`journalctl -u htpc-session` too. `/status` carries a `last_exit` field
with the id, exit code and how long it ran, and the launcher reads it for
~3 s after a launch so an early death reaches the TV as well as the log.
This is exactly how a missing gamescope presents. (The machinery is there for
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
`config.json`.

If cage or chromium are missing the script falls back to **backend-only**:
it starts the idle mpv and the backend, and you open
`http://127.0.0.1:8484` in any browser. Video plays in mpv's own window
rather than under the page. That is a real prototype of everything except
the one thing the kiosk exists to prove — the page compositing *over* the
video instead of beside it — and it is enough to develop every screen on
a laptop. (Backend-only used to skip mpv too, which made TV and MOVIES
resolve a stream, hand it to nothing, and report NO SIGNAL.)

### The test suite

Everything checkable without a TV, a CEC line or a graphics card:

```bash
test/run-all.sh
```

That is syntax for every language in the repo, 54 backend tests
(`python3 -m unittest discover -s test`), and 97 UI render tests that
load the real launcher in headless Chromium and assert what each screen
drew — which is the only way to catch the failure mode that matters here,
where a JS exception during boot leaves a black screen that looks exactly
like a working box showing a black screen.

```bash
test/test_ui.sh --shots /tmp/shots     # also writes a PNG per screen
```

The UI tests use `?fixtures=1`, a developer flag that stands in for the
HTTP calls a laptop cannot make. It never fakes a launch or a stream.
`?view=`, `?sel=`, `?detail=1`, `?list=1` (the channel list) and
`?sources=1` (the stream picker) navigate to a screen without a gamepad.

It also fails the build if a hex colour or an English string appears in
`app.js` — those belong in `theme.json`, and a value that is not in the
theme is a value a reskin cannot reach.

Backend smoke test — including the picker, against real Torrentio:

```bash
python3 server/server.py &
curl localhost:8484/config
curl localhost:8484/channels                     # 53 channels
curl localhost:8484/streams/movie/tt15239678     # every copy, ranked
curl -X POST localhost:8484/play \
  -H 'content-type: application/json' \
  -d '{"kind":"movie","id":"tt15239678","index":2}'   # play the third one
curl -X POST localhost:8484/launch/gaming
curl -X POST localhost:8484/home
```

**What still cannot be tested here, and never claims to be:** HDMI-CEC
(needs a real line and a real TV), hardware video decode on the AMD box,
a game actually rendering, and the transparent-Chromium-over-mpv layering
*on the production box*. Do not "fix" any of those from what a laptop
does.

---

# Troubleshooting (field notes)

**The session ends a second after it starts, with status 127.** Chromium
exiting *is* the end of the session, so a missing browser looks like the
box refusing to boot. `start-session.sh` probes `chromium`,
`chromium-browser`, `chromium-freeworld` and `google-chrome` in that
order — Debian and Raspberry Pi OS ship the first name, Fedora the
second. If it finds none it says so and exits 127 rather than letting the
shell's "command not found" be the only clue.

**The UI is there but a channel plays no picture, on a dev machine.**
Look for `vo_x11_init: Assertion !vo->x11 failed` in the log. mpv's
default `gpu-next` wants Vulkan; inside a nested, software-rendered cage
it gets `VK_ERROR_SURFACE_LOST_KHR`, walks its fallback chain to X11 and
dies on an assertion — and it does that on the *first file*, not at
startup, so it reads as a broken stream rather than a broken video
output. `dev-session.sh` sets `HTPC_MPV_VO_ARGS` to
`--vo=gpu --gpu-api=opengl --gpu-context=wayland --hwdec=no` whenever it
nests, which is the one combination that both idles and plays there.
(`wlshm` does not: it cannot even hold an idle window.) The Pi never sets
this — there mpv picks KMS/GL by itself and gets hardware decode with it.

**Everything says "player is not running" after a session was killed.**
mpv's socket file outlives mpv and is only cleared by the next
`start-session.sh` on the way up. That is handled: a socket that exists
but refuses a connection reports exactly what no socket reports, and
`/player/state` says unavailable rather than claiming a player that is
not there. If you see this, mpv really is not running — check the top of
the log for why.

**`ModuleNotFoundError: evdev`.** Optional, and only the gamepad's home
button and the CEC remote want it. Both daemons now say one line and get
out of the way instead of dumping a traceback into the session log.
`sudo dnf install python3-evdev` (or `sudo apt install python3-evdev`)
if you want the 8BitDo's guide button.

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

# Appendix: the Raspberry Pi build (retired)

Kept because the code still runs there and somebody may want to know why
half the design looks the way it does.

The box was a **Raspberry Pi 3B+** from July 2026 to 13 August 2026, and
three of its properties shaped everything:

1. **1 GB of RAM shared with the GPU.** This is why Chromium runs one
   renderer with a 64 MB JS heap, why mpv's demuxer buffers are shrunk in
   `start-session.sh`, why no Electron app was ever a tile, and why every
   long list in the UI is windowed rather than scrolled. All of those are
   kept — they turned out to be good design independent of the budget.
2. **H.264 only, 1080p max.** No hardware decode for HEVC, VP9 or AV1, so
   the stream ranking treated the envelope as a correctness rule. That is
   the one thing which fully inverted; see
   [What gets picked first](#what-gets-picked-first).
3. **A real CEC line on the HDMI connector**, which is the only reason a
   Pi made sense here at all. x86 needs a Pulse-Eight USB adapter, which
   also exposes `/dev/cec0`, so `cec-tv.sh` and `cecd.py` should work
   against it unchanged — untested.

To run this on a Pi again: `sudo ./system/install.sh` still writes
`dtoverlay=vc4-kms-v3d` into `/boot/firmware/config.txt` when it finds a
Pi boot config (mandatory — without it cage has no DRM device and there
is no `/dev/cec0`), then set `?profile=lite`, `HTPC_MAX_HEIGHT=1080` and
`HTPC_ALLOW_HEVC=0`. GAMING will report that gamescope is missing and
stay a dead tile, which is the correct outcome.

Before the Pi it was a Ryzen + Vega 56 tower on Debian 13. Its
suspend/wake udev rule is still there, commented out, at the bottom of
`system/99-htpc-input.rules`.
