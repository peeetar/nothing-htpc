# CABLE TV mode

Old-school cable zapping for the TV tile — live channels and an
on-demand library, both addressed by channel number. mpv + one Lua script.

## Install
```bash
sudo apt install -y mpv
# nothing else — this runs straight out of the checkout.
# fonts auto-install to ~/.config/mpv/fonts on first launch.
```
The TV tile in server/config.json points here as
`["bash", "$HTPC_DIR/cabletv/cabletv.sh"]` — server.py expands `$HTPC_DIR`
to the repo root, so no path is baked in.
Test standalone (VM or desktop): `bash cabletv/cabletv.sh` from the repo.

## Controls

Gamepad (8BitDo, XInput):

| Control | Action |
|---|---|
| R / L shoulder, dpad up/down | channel up / down |
| X | keypad (3x3 grid + 0/C/OK) |
| A | select digit |
| B | close keypad / stop a film / leave teletext / **leave cable mode** |
| dpad up/down in teletext | subpages, or the cursor on 993/994 |
| dpad left/right in teletext | jump initial letter on 993/994 |

Keyboard — the whole set, for testing on a desktop:

| Key | Action |
|---|---|
| `PgUp` / `PgDn` | channel up / down (hold to zap; nothing loads until you stop) |
| `↑` / `↓` | channel up / down, subpages in teletext, cursor on 993/994, move in the keypad |
| `←` / `→` | move in the keypad, jump initial letter on 993/994 |
| `0`-`9` | tune directly; 3rd digit tunes instantly, else 2 s after the last |
| `x` | open / close the keypad |
| `Enter` | press the highlighted keypad button |
| `Esc` | close keypad, leave teletext, then **quit** at the top level |
| `t` | teletext guide (999) |
| `q` / `Ctrl+q` / `Ctrl+c` | quit |

Esc backing all the way out quits mpv, which is how you get back to the
launcher — it is running underneath the whole time. In a dev session a
`ctrl+c` typed at the terminal will *not* reach mpv (server.py puts it in its
own process group), so use `q` or Esc in the window.

There is no volume control anywhere, on purpose. That is the TV's job.

## Channels
Edit `channels.m3u`. `tvg-chno="N"` is the fixed channel number; gaps
are fine; tuning an empty number gives static, as nature intended.
Dead/buffering channels show animated static (silent) and auto-retry
every 12 s.

Zapping does not wait for streams. The number and the banner change on the
keypress and the picture cuts to static, but the stream is not opened until
the number has sat still for 0.45 s — so you can run up the dial without
sitting through a load per channel. The old channel's audio keeps playing
under the static until then, which is also what stops fast zapping sounding
gappy. Zap away and back inside that window and the stream is never dropped.

## Teletext

990-999 is the reserved block. Tune to a page exactly as you tune to a
channel — type the three digits, or walk onto it with channel up/down.

| Page | |
|---|---|
| 991 | **ВЕСТИ / ΕΙΔΗΣΕΙΣ** — 1/2 МАКЕДОНИЈА (time.mk), 2/2 ΘΕΣΣΑΛΟΝΙΚΗ (thestival.gr) |
| 992 | **ВРЕМЕ / ΚΑΙΡΟΣ** — Skopje / Ljubljana / Thessaloniki, 3 days, Open-Meteo |
| 993 | **MOVIES** — the on-demand library |
| 994 | **TV SHOWS** — same, kind=show |
| 995-998 | free |
| 999 | **TV GUIDE** — the channel list (was 991 until July 2026) |

Pages render locally in Press Start 2P; news is cached 5 min, weather 15.
Audio from the last channel keeps playing under teletext, like the real
thing. Add pages in the TELETEXT table at the top of cabletv.lua.

### 991 — news

One language per subpage, 15 headlines, **one line each**. Long headlines
lose a trailing " - subtitle" clause first and are otherwise cut at a word
boundary with an ellipsis — never wrapped, because a wrapped headline used
to get split across the subpage break. Rows alternate cyan/white. Up/down
and left/right both turn the subpage.

A feed that fails takes down only its own subpage — 991 prints
`NOT AVAILABLE` under that language's heading and still shows the other.

### 992 — weather

Cities across, days down: three fixed cities (they are identities, like
channel numbers — edit `WX_CITIES` in cabletv.lua to change them) and three
days each, with a drawn icon per cell. Icons are ASS polygons, one shape per
event, so nothing depends on libass's fill rule; the eight shapes are sun,
sun+cloud, cloud, fog, drizzle, rain, snow and thunderstorm. Highs are
yellow, lows cyan. One request per city; the page appears when the slowest
answers, and two cities out of three is still a page.

### 993 / 994 — the library

A teletext index of films and series, which is what a 90s box would have
done with them. Rows come from `library.tsv` (tab-separated:
`kind, title, year, url`), sorted by title.

| Control | |
|---|---|
| dpad up/down, `↑`/`↓` | move the cursor; the subpage turns under it |
| dpad left/right, `←`/`→` | jump to the next / previous initial letter |
| A, `Enter` | play the highlighted row |
| B, `Esc` | stop and go back to the page |

Letter-jump is there because paging a few hundred titles eleven rows at a
time with a d-pad is unusable.

A row with an empty url says `NO SOURCE` on the banner and plays nothing.
Regenerate the whole file to fill it; unlike `channels.m3u`, nothing in it
is hand-maintained state.

#### Where the urls come from

The url column normally holds `ee3:<id>`, not a playable URL — ee3 mints a
link per playback, so anything baked into the file would be dead by the time
someone pressed OK. Pressing A on such a row runs `ee3resolve.py`, which asks
the daemon (`server/movieapi.py`, on the LXC at `192.168.1.16:1209`) for a
fresh one. The banner reads `RESOLVING - <title>` while that happens, and the
picture stays on static; the resolve is async, so channel-up still works and
zapping away cancels it rather than yanking you back a minute later.

If it fails you get one sentence on the banner — `NO STREAMS AVAILABLE`,
`EE3 DAEMON UNREACHABLE AT ...` — and the page you came from, not silent
static.

```bash
# refresh the catalogue (writes library.tsv atomically)
cabletv/ee3resolve.py --library

# resolve one id by hand, to see what the box would see
cabletv/ee3resolve.py ee3:6f2a91c
```

A plain `http(s)://` or `av://` url in that column still plays directly, so
the file is not tied to ee3.

| Env | |
|---|---|
| `EE3_API` | daemon base url (default `http://192.168.1.16:1209`) |
| `CABLETV_RESOLVE_SECONDS` | give up on a resolve after this long (default 130) |

A film is not a channel: when one ends or fails, you go back to the page
you picked it from instead of into the dead-channel retry loop.

## Notes
- The 8BitDo must be in XInput mode (its default) — mpv reads it via
  SDL (`--input-gamepad=yes`).
- input.conf REPLACES all mpv defaults: the player has exactly the
  buttons a cable box has, nothing else.
- The static is colored per-pixel noise, the "colored / fine" variant of
  [Analog-TV-Noise-Effect](https://github.com/AliKHaliliT/Analog-TV-Noise-Effect).
  One noise field is generated per resolution into `~/.cache/cabletv/`
  (6 MB at 720p, 12 MB at 1080p) and every frame is drawn from a random
  offset into it, so nothing visibly repeats. `CABLETV_STATIC_FPS`
  overrides the rate (25 default, 15 under 1.5 GB RAM).
- mpv composites raw overlays *above* script ASS overlays and there is no
  way to reorder them, so the static is drawn as tiles around the banner
  and keypad rather than over them. That is why the banner grows a black
  plate the moment static comes up: it is filling its own hole.
