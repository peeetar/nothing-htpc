#!/usr/bin/env bash
# torrentstream.sh — magnet URI -> a local HTTP stream mpv can open.
#
# The Pi does its own downloading. server/movieapi.py used to ask ee3 to cache
# a whole film and hand back an http link, which meant waiting out someone
# else's queue for a link that then expired; /resolve returns a magnet now and
# this is what turns that magnet back into something with a URL.
#
# IT DOES NOT LAUNCH A PLAYER. `webtorrent --mpv` and `peerflix --mpv` both
# spawn a SECOND mpv, and the entire cable UI - banner, static, the Back button,
# the transport bar - lives inside the Lua script running in the FIRST one.
# cage raises the newest window, so a second mpv would cover the cable box with
# a bare player that Back cannot get out of. Instead this runs the engine in
# server mode and cabletv.lua does `loadfile` into the mpv it already has.
#
#   torrentstream.sh <magnet> <port>   run the engine (execs; does not return)
#   torrentstream.sh --probe <port>    print the stream URL, or exit 1 if the
#                                      engine is not serving yet
#   torrentstream.sh --engine          print which engine is installed
#
# Engines, in preference order:
#   peerflix     lighter, and serves the film at "/" - one less thing to guess
#   webtorrent   maintained, but serves at /<infoHash>/<idx>/<name>, so --probe
#                has to read the index page to find out where the film is
set -u

CACHE="${CABLETV_TORRENT_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/cabletv/torrent}"

engine() {
  if command -v peerflix   >/dev/null 2>&1; then echo peerflix;   return 0; fi
  if command -v webtorrent >/dev/null 2>&1; then echo webtorrent; return 0; fi
  return 1
}

# --- --engine ---------------------------------------------------------------
if [ "${1:-}" = "--engine" ]; then
  engine || { echo "no torrent streamer installed" >&2; exit 1; }
  exit 0
fi

# --- --probe ----------------------------------------------------------------
# Asks the engine's own server where the film is, rather than assuming, so the
# same probe works whichever engine started. Prints one URL on stdout.
if [ "${1:-}" = "--probe" ]; then
  PORT="${2:?port}"
  BASE="http://127.0.0.1:$PORT"
  BODY="$(mktemp)"; trap 'rm -f "$BODY"' EXIT
  # -r 0-0 keeps this to a single byte: the probe runs every couple of seconds
  # and must not pull film data or disturb the engine's piece priorities.
  read -r CODE CTYPE <<<"$(curl -sS -m 4 -r 0-0 -o "$BODY" \
                             -w '%{http_code} %{content_type}' "$BASE/" 2>/dev/null)"
  case "$CODE" in 200|206) ;; *) exit 1 ;; esac

  case "$CTYPE" in
    text/html*)
      # webtorrent: "/" is an index of <a href="/<infoHash>/<idx>/<name>">.
      # Take the first entry that is not the index itself.
      REL="$(sed -n 's/.*href="\([^"]*\)".*/\1/p' "$BODY" \
             | grep -v '^/\?$' | head -n1)"
      [ -n "$REL" ] || exit 1
      case "$REL" in http*) echo "$REL" ;; /*) echo "$BASE$REL" ;;
                     *) echo "$BASE/$REL" ;; esac
      ;;
    *)
      # peerflix: "/" IS the film (largest file), already the right content type.
      echo "$BASE/"
      ;;
  esac
  exit 0
fi

# --- run --------------------------------------------------------------------
MAGNET="${1:?usage: torrentstream.sh <magnet> <port>}"
PORT="${2:-8888}"

ENGINE="$(engine)" || {
  echo "no torrent streamer: install peerflix (npm i -g peerflix)" >&2
  exit 1
}

# One film on disk at a time. A 3B+ streams to its SD card, and two or three
# 1080p rips left behind will fill it - which shows up as a box that has
# stopped working, a long way from anything that mentions torrents.
rm -rf -- "$CACHE"
mkdir -p "$CACHE" || { echo "cannot write $CACHE" >&2; exit 1; }

echo "torrentstream: $ENGINE on port $PORT, cache $CACHE" >&2

# exec, so the process cabletv.lua kills IS the engine. Without it the engine
# is a grandchild of mpv's subprocess and survives the abort, seeding a film
# nobody is watching until the box reboots.
case "$ENGINE" in
  peerflix)
    # --quiet: peerflix's default is a redrawing terminal UI, and this stderr
    # goes to the session console (constraint 18) - it would scroll the log
    # away. Real errors are still printed.
    exec peerflix "$MAGNET" --port "$PORT" --path "$CACHE" --quiet
    ;;
  webtorrent)
    exec webtorrent download "$MAGNET" --port "$PORT" --out "$CACHE" --quiet
    ;;
esac
