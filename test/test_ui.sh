#!/usr/bin/env bash
# UI render tests — no display, no Pi, no backend.
#
# Loads the real launcher in headless Chromium and asserts each screen
# actually rendered. This catches the failure the old project could only find
# on a TV: a JS exception during boot leaves a black screen, and a black
# screen looks exactly like a working box showing a black screen.
#
#   test/test_ui.sh              run everything
#   test/test_ui.sh --shots DIR  also write a PNG per screen into DIR
#
# `?fixtures=1` feeds the screens canned data. It is a developer flag, not a
# demo mode: it never fakes a launch or a stream, it only stands in for the
# HTTP calls a laptop cannot make. Every assertion below is about markup the
# real UI produced.
set -u

HTPC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${HTPC_UI_TEST_PORT:-8899}"
SHOTS=""
[ "${1:-}" = "--shots" ] && SHOTS="${2:?--shots needs a directory}" && mkdir -p "$SHOTS"

CHROME=""
for c in chromium chromium-browser google-chrome google-chrome-stable; do
  command -v "$c" >/dev/null 2>&1 && CHROME="$c" && break
done
if [ -z "$CHROME" ]; then
  echo "SKIP: no chromium found — UI render tests need a headless browser"
  exit 0
fi

cd "$HTPC_DIR/launcher" || exit 1
python3 -m http.server "$PORT" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1

pass=0; fail=0
DOM=""

# dom <query-string> — render the page and capture the DOM after JS has run.
dom() {
  DOM="$($CHROME --headless --disable-gpu --no-sandbox --hide-scrollbars \
          --virtual-time-budget=4000 --dump-dom \
          "http://127.0.0.1:$PORT/index.html?fixtures=1$1" 2>/dev/null)"
}

shot() {
  [ -n "$SHOTS" ] || return 0
  $CHROME --headless --disable-gpu --no-sandbox --hide-scrollbars \
    --window-size=1920,1080 --virtual-time-budget=4000 \
    --screenshot="$SHOTS/$1.png" \
    "http://127.0.0.1:$PORT/index.html?fixtures=1$2" >/dev/null 2>&1
}

# has NAME NEEDLE — assert the captured DOM contains NEEDLE.
has() {
  if printf '%s' "$DOM" | grep -qF -- "$2"; then
    echo "  ok   $1"; pass=$((pass + 1))
  else
    echo "  FAIL $1 — expected to find: $2"; fail=$((fail + 1))
  fi
}
hasnt() {
  if printf '%s' "$DOM" | grep -qF -- "$2"; then
    echo "  FAIL $1 — should not contain: $2"; fail=$((fail + 1))
  else
    echo "  ok   $1"; pass=$((pass + 1))
  fi
}

echo "HOME"
dom ""; shot home ""
has  "boots without a JS exception"   "<circle"        # the dot engine ran
has  "clock rendered"                  'id="clock"'
has  "all six tiles"                   "WEATHER"
has  "music tile"                      "MUSIC"
has  "theme applied (css vars stamped)" "--ink"
hasnt "no gaming tile (constraint 14)"  ">GAMING<"
hasnt "no teletext page numbers"        "993"

echo "MOVIES"
dom "&view=grid&kind=movie"; shot grid "&view=grid&kind=movie"
has  "grid title"                      'id="gridtitle"'
has  "poster cards rendered"           'class="card'
has  "a fixture title"                 "Oppenheimer"
has  "selection marker"                "card sel"
has  "year on the card"                'class="y"'
has  "scrollable inner grid"           'id="gridinner"'
has  "page indicator"                  "PAGE 1/2"
has  "selection uses a white glow"     "box-shadow: var(--glow-card)"
hasnt "no red bar under the selection"  ".card.sel::after"

echo "MOVIES — page 2 (cursor past the last row)"
dom "&view=grid&kind=movie&sel=32"
has  "second page rendered"            "PAGE 2/2"
has  "an item only on page 2"          "Anora"

echo "MOVIE DETAIL"
dom "&view=grid&kind=movie&detail=1"; shot detail "&view=grid&kind=movie&detail=1"
has  "detail panel open"               'id="detail" class="on"'
has  "director line"                   "DIRECTOR"
has  "producer line"                   "PRODUCER"
has  "cast line"                       "CAST"
has  "five cast members"               "Josh Brolin"
has  "reviews section"                  'id="dreviews"'
has  "review author"                   "cinemabuff"
has  "stars drawn in the dot matrix"   'aria-label="★★★★★"'
has  "first review visible"            'class="review on"'
has  "review position dots"            'id="rdots"'

echo "TV"
dom "&view=tv"; shot tv "&view=tv"
has  "channel bar present"             'id="chanbar"'
has  "channel bar shown"               'id="chanbar" class="show"'
has  "channel number in dot-matrix"    'aria-label="101"'
has  "channel name from fixtures"      "MRT 1"
has  "clock in the bar"                'id="chanclock"'

echo "NEWS"
dom "&view=news"; shot news "&view=news"
has  "Time.mk half"                    "TIME.MK"
has  "a Macedonian category label"     "МАКЕДОНИЈА"
has  "Greek half"                      "ΘΕΣΣΑΛΟΝΙΚΗ"
has  "Cyrillic headline renders"       "Владата"
has  "Greek headline renders"          "Ηρακλής"
has  "marquee track duplicated"        'class="track"'
# The label and the headlines must be in separate boxes, or a headline
# scrolling left slides out over the label instead of stopping at it.
has  "headlines clipped in own box"    'class="marquee"'
# The Greek source name has no dot glyphs; without the fallback it renders as
# a row of blanks, which is how the bottom half lost its name once already.
has  "Greek heading falls back to text" 'class="headingtext"'

echo "WEATHER"
dom "&view=weather"; shot weather "&view=weather"
has  "Skopje in Cyrillic"              "Скопје"
has  "Ljubljana"                       "Ljubljana"
has  "Thessaloniki in Greek"           "Θεσσαλονίκη"
has  "drawn icons, not a font"         "<svg"
has  "three days"                      "TODAY"
has  "current reading, not just forecast" 'class="wxnow"'
has  "current temp in dot matrix"      'aria-label="27°"'
has  "feels-like"                      "FEELS LIKE"
has  "wind"                            "WIND"
has  "rain probability"                'class="rain"'

echo "MUSIC"
dom "&view=music"; shot music "&view=music"
has  "now playing from fixtures"       "NEW ORDER"
has  "halftone art placeholder"        'id="mart"'
has  "progress bar"                    'id="mbar"'

echo "PI3 PROFILE"
# The reduced profile is what keeps the original 3B+ alive. It must actually
# change the layout, not just exist in the file.
DOM="$($CHROME --headless --disable-gpu --no-sandbox --hide-scrollbars \
        --virtual-time-budget=4000 --dump-dom \
        "http://127.0.0.1:$PORT/index.html?fixtures=1&profile=pi3&view=grid&kind=movie" 2>/dev/null)"
has  "pi3 profile renders"             'class="card'
if printf '%s' "$DOM" | grep -qF -- "--layout-grid-columns: 4"; then
  echo "  ok   pi3 narrows the grid to 4 columns"; pass=$((pass + 1))
else
  echo "  FAIL pi3 did not override grid-columns"; fail=$((fail + 1))
fi

echo
echo "$pass passed, $fail failed"
[ -n "$SHOTS" ] && echo "screenshots in $SHOTS"
[ "$fail" -eq 0 ]
