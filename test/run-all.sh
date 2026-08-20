#!/usr/bin/env bash
# Everything that can be checked without a Pi, a TV or a CEC line.
#
#   test/run-all.sh
#
# What this cannot cover, and never claims to (CLAUDE.md):
# HDMI-CEC, V4L2 hardware decode, thermal throttling, power delivery — and now
# also the transparent-Chromium-over-mpv layering, which needs a real cage
# session on real hardware. Do not "fix" any of those based on what this says.
set -u

HTPC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HTPC_DIR" || exit 1
rc=0

step() { printf '\n=== %s\n' "$1"; }

step "syntax"
python3 -m py_compile server/*.py daemon/*.py || rc=1
bash -n system/*.sh test/*.sh || rc=1
# A missing checker used to be indistinguishable from a passing one: this
# loop simply fell through and the run still said ALL GREEN, so shim.lua was
# never compiled on any machine without luac. Say so instead.
lua_found=""
for lua in luac5.4 luac5.3 luac; do
  if command -v "$lua" >/dev/null 2>&1; then lua_found="$lua"; break; fi
done
if [ -n "$lua_found" ]; then
  "$lua_found" -p cabletv/shim.lua && echo "  ok   cabletv/shim.lua" || rc=1
else
  echo "  !    no luac — cabletv/shim.lua NOT syntax-checked (dnf/apt install lua5.4)"
fi

# config.local.json is the file the box actually loads (server.py prefers it),
# so leaving it out meant the one config that matters was never validated.
python3 -c "import json, pathlib
for f in ('server/config.json', 'server/config.local.json', 'server/config.vm.json',
          'launcher/theme.json'):
    if not pathlib.Path(f).exists():
        print('  -    %s (absent)' % f); continue
    json.load(open(f))
    print('  ok   %s' % f)" || rc=1

step "backend unit + HTTP tests"
python3 -m unittest discover -s test -q || rc=1

step "UI render tests"
# These are the tests that catch the failure that matters here — a JS
# exception during boot leaves a black screen, which looks exactly like a
# working box showing a black screen. Skipping them silently on a machine
# with no browser turns the whole suite into a syntax checker wearing a
# green tick, so a skip is a failure unless it is asked for.
if bash test/test_ui.sh | tee /tmp/htpc-ui-$$.log; then
  grep -q '^SKIP:' /tmp/htpc-ui-$$.log && {
    echo "  !    UI render tests did not run"
    [ -n "${HTPC_ALLOW_NO_UI_TESTS:-}" ] || rc=1
  }
else
  rc=1
fi
rm -f /tmp/htpc-ui-$$.log

step "theme coverage"
# Every screen has to be reachable from the theme's copy block, or a string
# somewhere is hardcoded English that a reskin cannot reach.
python3 - <<'PY' || rc=1
import json, re, pathlib
theme = json.load(open("launcher/theme.json"))
app = pathlib.Path("launcher/app.js").read_text()
missing = [k for k in ("tv", "movies", "shows", "news", "weather", "music")
           if k not in theme["copy"]["tiles"]]
print("  ok   all tiles named in copy" if not missing else "  FAIL missing copy: %s" % missing)
# A literal colour is a value a reskin cannot reach — and this used to look
# only at app.js, for six-digit hexes only, which is two ways of missing the
# ten `#000` mask stops sitting in index.html under a header that says "a
# literal colour in this stylesheet is a bug".
HEX = re.compile(r'#(?:[0-9A-Fa-f]{3,4}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})\b')
bad = {}
for name in ("app.js", "index.html", "theme.js"):
    found = HEX.findall(pathlib.Path("launcher", name).read_text())
    if found:
        bad[name] = sorted(set(found))
for name in ("app.js", "theme.js"):
    print("  ok   no hardcoded colours in %s" % name) if name not in bad \
        else print("  FAIL hardcoded colours in %s: %s" % (name, bad[name]))
# index.html is allowed exactly one: --mask-opaque, the opaque stop of a mask
# gradient, which is the number 1 wearing a colour's clothes and is defined
# once with a comment saying so. A second literal is a real one.
KNOWN_HTML_HEXES = 1
n_html = len(HEX.findall(pathlib.Path("launcher/index.html").read_text()))
if n_html <= KNOWN_HTML_HEXES:
    print("  ok   index.html hex literals: %d (known mask stops, cap %d)"
          % (n_html, KNOWN_HTML_HEXES))
else:
    print("  FAIL index.html grew a hex literal: %d > %d" % (n_html, KNOWN_HTML_HEXES))
raise SystemExit(1 if missing or bad.keys() - {"index.html"} or n_html > KNOWN_HTML_HEXES else 0)
PY

printf '\n'
if [ "$rc" -eq 0 ]; then echo "ALL GREEN"; else echo "FAILURES ABOVE"; fi
exit "$rc"
