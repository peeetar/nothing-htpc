# CABLE TV mode

Old-school cable zapping for the LIVE TV tile. mpv + one Lua script.

## Install
```bash
sudo apt install -y mpv
# repo already copied to /opt/htpc; nothing else needed.
# fonts auto-install to ~/.config/mpv/fonts on first launch.
```
The LIVE TV tile in server/config.json points at cabletv.sh.
Test standalone (VM or desktop): `bash /opt/htpc/cabletv/cabletv.sh`

## Controls
| Control | Action |
|---|---|
| R / L shoulder, dpad up/down | channel up / down |
| X | keypad (3x3 grid + 0/C/OK) |
| A | select digit |
| B | close keypad / leave teletext |
| digits (keyboard / future CEC remote) | direct tune, 3rd digit tunes instantly |
| dpad up/down in teletext | subpages |
| keyboard: PgUp/PgDn, x, Enter, Esc, t (=991), ctrl+q | same / guide / quit |

## Channels
Edit `channels.m3u`. `tvg-chno="N"` is the fixed channel number; gaps
are fine; tuning an empty number gives static, as nature intended.
Dead/buffering channels show animated static (silent) and auto-retry
every 12 s.

## Teletext
- 991 channel guide
- 992 ВЕСТИ — time.mk headlines (Macedonian)
- 993 NEWS — Kathimerini English headlines
Pages are rendered locally in Press Start 2P; feeds cached 5 min.
Audio from the last channel keeps playing under teletext, like the
real thing. Add pages in the TELETEXT table at the top of cabletv.lua.

## Notes
- The 8BitDo must be in XInput mode (its default) — mpv reads it via
  SDL (`--input-gamepad=yes`).
- input.conf REPLACES all mpv defaults: the player has exactly the
  buttons a cable box has, nothing else.
- Static frames are generated once per resolution into
  ~/.cache/cabletv/ (~50 MB at 1080p).
