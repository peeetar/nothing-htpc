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
has  "all seven tiles"                 "WEATHER"
has  "music tile"                      "MUSIC"
has  "theme applied (css vars stamped)" "--ink"
# GAMING came back in August 2026 (it was cut in July). It is the only tile
# that launches a process rather than showing a view, which is exactly why the
# tile model was kept general enough to take it back.
has  "gaming tile is back"             ">GAMING<"
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
# A review longer than the panel scrolls inside it instead of being clipped at
# the fourth line. The moving element has to exist and the overflow has to have
# been measured — .more is only set when there is text past the bottom edge.
has  "review text is its own scroller" 'class="rtext"'
has  "long review detected as overflowing" 'class="rbody more'
has  "the end of a long review is present" "telling you that from its first shot"
# Movie detail must not grow a season chooser.
hasnt "no season tabs on a film"        'class="stab'

echo "SHOW DETAIL — season tabs and episode chooser"
dom "&view=grid&kind=show&detail=1"; shot show-detail "&view=grid&kind=show&detail=1"
has  "show detail panel open"          'id="detail" class="on"'
has  "a fixture show title"            "Severance"
has  "season label"                    "SEASON"
has  "season tabs rendered"            'class="stab'
has  "first season selected"           'class="stab sel"'
has  "episode list rendered"           'class="eprow'
has  "episode cursor"                  'class="eprow sel"'
has  "named episode"                   "The You You Are"
has  "episode number column"           'class="epno"'
has  "episode count"                   "EPISODE 1/9"
has  "show hints mention seasons"      "SEASON"
# The reviews block is the film half of the panel and must be put away.
hasnt "no reviews block on a show"      'class="review on"'

echo "MOVIE DETAIL — the stream picker"
dom "&view=grid&kind=movie&detail=1&sources=1"; shot sources "&view=grid&kind=movie&detail=1&sources=1"
has  "picker open"                     'id="sources" class="on"'
has  "picker heading in dot-matrix"    'aria-label="SOURCES"'
has  "a source row"                    'class="srcrow'
has  "cursor on a row"                 "srcrow sel"
has  "quality tag as dots"             'aria-label="1080P"'
has  "the indexer name"                "ThePirateBay"
has  "size column"                     "2.31 GB"
has  "seeder count"                    "2081"
has  "a debrid link is marked"         "DIRECT"
# A stream past the playback envelope is flagged, never hidden — if every copy
# is a 4K remux, playing one badly beats "no streams found".
has  "outside-envelope stream shown"   'class="srcrow outside"'
has  "and flagged rather than hidden"  "HEAVY"
has  "position counter"                'id="srccount"'
has  "picker hints"                    'id="srchints"'
# The picker is summoned over the panel; opening a film must not conjure it.
dom "&view=grid&kind=movie&detail=1"
hasnt "picker closed on a plain open"   'id="sources" class="on"'
has  "the panel says how to reach it"  "OTHER SOURCES"

echo "TV"
dom "&view=tv"; shot tv "&view=tv"
has  "channel bar present"             'id="chanbar"'
has  "channel bar shown"               'id="chanbar" class="show"'
has  "channel number in dot-matrix"    'aria-label="101"'
has  "channel name from fixtures"      "MRT 1"
has  "clock in the bar"                'id="chanclock"'
has  "the list is discoverable"        'id="barhint"'
# The TV screen only goes transparent where the compositor can actually blend
# it over mpv. Where it cannot, a transparent body paints the browser's WHITE
# default over a healthy stream — so the body must stay opaque unless told.
hasnt "body is not transparent here"    'class="transparent"'
# The list is summoned, not arrived at — entering TV shows the picture.
hasnt "channel list closed on entry"    'id="chanlist" class="on"'

echo "TV — the channel list"
dom "&view=tv&list=1"; shot channels "&view=tv&list=1"
has  "channel list open"               'id="chanlist" class="on"'
has  "list heading in dot-matrix"      'aria-label="CHANNELS"'
has  "a channel row"                   'class="chanrow'
has  "cursor on a row"                 "chanrow sel"
has  "the tuned channel is marked"     "live"
has  "channel numbers as dots"         'aria-label="103"'
has  "channel names"                   "KANAL 5"
has  "position counter"                'id="chancount"'

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

echo "LITE PROFILE"
# The reduced profile — `pi3` until the Pi stopped being a target in August
# 2026. Kept because the profile *mechanism* is what lets a weak box run this
# at all, and it has to actually change the layout rather than just exist in
# the file.
DOM="$($CHROME --headless --disable-gpu --no-sandbox --hide-scrollbars \
        --virtual-time-budget=4000 --dump-dom \
        "http://127.0.0.1:$PORT/index.html?fixtures=1&profile=lite&view=grid&kind=movie" 2>/dev/null)"
has  "lite profile renders"            'class="card'
if printf '%s' "$DOM" | grep -qF -- "--layout-grid-columns: 4"; then
  echo "  ok   lite narrows the grid to 4 columns"; pass=$((pass + 1))
else
  echo "  FAIL lite did not override grid-columns"; fail=$((fail + 1))
fi

echo
echo "$pass passed, $fail failed"
[ -n "$SHOTS" ] && echo "screenshots in $SHOTS"
[ "$fail" -eq 0 ]
