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
for lua in luac5.4 luac5.3 luac; do
  if command -v "$lua" >/dev/null 2>&1; then "$lua" -p cabletv/shim.lua || rc=1; break; fi
done
python3 -c "import json,sys
for f in ('server/config.json','launcher/theme.json'):
    json.load(open(f))
    print('  ok  ', f)" || rc=1

step "backend unit + HTTP tests"
python3 -m unittest discover -s test -q || rc=1

step "UI render tests"
bash test/test_ui.sh || rc=1

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
# A hex colour in app.js is a value a reskin cannot reach.
hexes = [h for h in re.findall(r'#[0-9A-Fa-f]{6}\b', app)]
print("  ok   no hardcoded colours in app.js" if not hexes
      else "  FAIL hardcoded colours in app.js: %s" % hexes)
raise SystemExit(1 if missing or hexes else 0)
PY

printf '\n'
if [ "$rc" -eq 0 ]; then echo "ALL GREEN"; else echo "FAILURES ABOVE"; fi
exit "$rc"
