#!/usr/bin/env bash
# Run the whole HTPC session from a git clone, on any Linux desktop, without
# installing the systemd unit. Same clone, same paths, same code the box runs.
#
# Inside an existing Wayland session cage nests itself in an ordinary window,
# so the kiosk is testable on the dev machine — no VM, no free TTY. From a
# bare TTY it takes over the screen exactly like the real service does.
#
#   ./system/dev-session.sh            # real apps   (server/config.json)
#   ./system/dev-session.sh --vm       # stand-ins   (server/config.vm.json)
#   ./system/dev-session.sh --check    # preflight only, start nothing
#   ./system/dev-session.sh --quiet    # no tagging/tee, like the real service
#
# Unlike the deployed service this is a debugging harness: it syntax-checks
# everything first, prints what each tile will actually run and whether that
# binary exists, and then streams every process's stdout/stderr to this
# terminal tagged with its name (and to a log file). A tile that opens and
# closes again has to leave a reason behind — that is the whole point.
#
# Ctrl+C, or closing the window, ends the session.
set -u

HTPC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VM=0 CHECK_ONLY=0 QUIET=0
LOG="${HTPC_LOG:-${TMPDIR:-/tmp}/htpc-dev-$(date +%Y%m%d-%H%M%S).log}"

for arg in "$@"; do
  case "$arg" in
    --vm)     VM=1 ;;
    --check)  CHECK_ONLY=1 ;;
    --quiet)  QUIET=1 ;;
    --log=*)  LOG="${arg#--log=}" ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# --- output -----------------------------------------------------------------
if [ -t 1 ]; then
  R=$'\e[31m'; Y=$'\e[33m'; G=$'\e[32m'; D=$'\e[2m'; B=$'\e[1m'; Z=$'\e[0m'
else
  R=; Y=; G=; D=; B=; Z=
fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$Z" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$Z" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$R" "$Z" "$*"; PROBLEMS=$((PROBLEMS + 1)); }
hdr()  { printf '\n%s%s%s\n' "$B" "$*" "$Z"; }
PROBLEMS=0

if [ "$QUIET" = 0 ] && [ "$CHECK_ONLY" = 0 ]; then
  # Everything below — including cage, chromium, the daemons and any app the
  # launcher starts — lands in both the terminal and the log.
  mkdir -p "$(dirname "$LOG")"
  exec > >(tee -a "$LOG") 2>&1
fi

hdr "nothing-htpc dev session"
say "  repo    $HTPC_DIR"
say "  commit  $(git -C "$HTPC_DIR" describe --always --dirty 2>/dev/null || echo 'not a git checkout')"
say "  host    $(uname -srm)  $(id -un)@$(hostname 2>/dev/null || echo '?')"
[ "$QUIET" = 0 ] && [ "$CHECK_ONLY" = 0 ] && say "  log     $LOG"

# --- config -----------------------------------------------------------------
if [ "$VM" = 1 ]; then
  # Exported, not copied over config.json — the real config stays intact.
  export HTPC_CONFIG="$HTPC_DIR/server/config.vm.json"
elif [ -f "$HTPC_DIR/server/config.local.json" ]; then
  # Same precedence server.py uses when nothing is exported.
  export HTPC_CONFIG="$HTPC_DIR/server/config.local.json"
else
  export HTPC_CONFIG="$HTPC_DIR/server/config.json"
fi
say "  config  ${HTPC_CONFIG#"$HTPC_DIR"/}$([ "$VM" = 1 ] && echo '  (stand-in apps)')"

# Verbose backend + tagged per-process output (read by server.py and
# start-session.sh). --quiet runs the session exactly as the service does.
if [ "$QUIET" = 0 ]; then
  export HTPC_DEBUG=1
else
  say "  ${D}quiet mode: no tagging, no log file, no HTTP log${Z}"
fi

# --- syntax -----------------------------------------------------------------
# Cheap, and it turns "the session died on startup" into one line naming a
# file and a line number.
hdr "syntax"
if python3 -m py_compile "$HTPC_DIR/server/"*.py "$HTPC_DIR"/daemon/*.py 2>&1; then
  ok "python (server, daemons)"
else
  bad "python syntax error above"
fi

if bash -n "$HTPC_DIR"/system/*.sh 2>&1; then
  ok "bash (system/*.sh)"
else
  bad "bash syntax error above"
fi

if command -v luac5.4 >/dev/null; then
  if luac5.4 -p "$HTPC_DIR/cabletv/shim.lua" 2>&1; then
    ok "lua (shim.lua)"
  else
    bad "shim.lua does not compile — mpv would run with no failure handling"
  fi
else
  warn "luac5.4 not installed — shim.lua unchecked (dnf/apt install lua5.4)"
fi

# The theme is the whole UI's source of truth; a trailing comma in it is a
# black screen on the TV and nothing in the journal.
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" \
     "$HTPC_DIR/launcher/theme.json" 2>&1; then
  ok "json (launcher/theme.json)"
else
  bad "theme.json is not valid JSON — the launcher would load to a black screen"
fi

# cage execs this directly, so a missing exec bit kills the session before a
# single line is printed — and git only carries the bit if it was committed.
if [ ! -x "$HTPC_DIR/system/start-session.sh" ]; then
  if chmod +x "$HTPC_DIR/system/start-session.sh" 2>/dev/null; then
    warn "start-session.sh was not executable — fixed (commit the mode: git update-index --chmod=+x)"
  else
    bad "start-session.sh is not executable and chmod failed — cage cannot start it"
  fi
fi

if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$HTPC_CONFIG" 2>&1; then
  ok "$(basename "$HTPC_CONFIG") parses"
else
  bad "$(basename "$HTPC_CONFIG") is not valid JSON — every tile will fail"
fi

# --- tiles ------------------------------------------------------------------
# The failure this exists for: a command that starts fine but exits at once,
# because its binary is missing or a path in it does not exist here. Commands
# are shown expanded, exactly as server.py will run them — $HTPC_DIR and all.
hdr "tiles"
while IFS=$'\t' read -r id kind payload; do
  case "$kind" in
    view)
      say "  $(printf '%-10s' "$id") ${D}view '$payload' — launches no process${Z}" ;;
    none)
      say "  $(printf '%-10s' "$id") ${D}no command configured${Z}" ;;
    cmd)
      say "  $(printf '%-10s' "$id") $payload"
      set -f            # split the command on spaces, but never glob it
      set -- $payload
      set +f
      bin="$1"
      if ! command -v "$bin" >/dev/null; then
        bad "$id: '$bin' is not installed"
      fi
      for word in "$@"; do
        case "$word" in
          /*) [ -e "$word" ] || bad "$id: '$word' does not exist on this machine" ;;
        esac
      done ;;
  esac
done < <(python3 - "$HTPC_CONFIG" "$HTPC_DIR" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
root = sys.argv[2]
def expand(arg):  # same one substitution server.py does, and only that one
    return arg.replace("${HTPC_DIR}", root).replace("$HTPC_DIR", root)
for a in cfg.get("apps", []):
    i = a.get("id", "?")
    if a.get("view"):
        print("%s\tview\t%s" % (i, a["view"]))
    elif a.get("command"):
        print("%s\tcmd\t%s" % (i, " ".join(expand(x) for x in a["command"])))
    else:
        print("%s\tnone\t" % i)
PY
)

# --- tools ------------------------------------------------------------------
hdr "tools"
KIOSK=1
if command -v cage >/dev/null; then
  ok "cage  ${D}$(cage --version 2>&1 | head -1)${Z}"
else
  warn "cage missing — falling back to backend-only"
  KIOSK=0
fi

# Fedora ships the binary as chromium-browser, Debian as chromium. Probing
# only one of them reported "missing" on a machine that had it.
CHROMIUM=""
for c in chromium chromium-browser google-chrome google-chrome-stable; do
  command -v "$c" >/dev/null && CHROMIUM="$c" && break
done
if [ -n "$CHROMIUM" ]; then
  ok "$CHROMIUM  ${D}$("$CHROMIUM" --version 2>&1 | head -1)${Z}"
else
  warn "chromium missing — falling back to backend-only"
  KIOSK=0
fi
for bin in mpv playerctl foot spotifyd; do
  if command -v "$bin" >/dev/null; then
    ok "$bin  ${D}$("$bin" --version 2>&1 | head -1)${Z}"
  else
    warn "$bin not installed"
  fi
done

# --- environment ------------------------------------------------------------
hdr "environment"
say "  WAYLAND_DISPLAY  ${WAYLAND_DISPLAY:-${D}(none — bare TTY / DRM backend)${Z}}"
say "  XDG_RUNTIME_DIR  ${XDG_RUNTIME_DIR:-${R}unset — cage will fail${Z}}"
say "  DISPLAY          ${DISPLAY:-${D}(none)${Z}}"
if ! python3 - 2>/dev/null <<'PY'
import socket
s = socket.socket()
try:
    s.bind(("127.0.0.1", 8484))
finally:
    s.close()
PY
then
  bad "port 8484 is already in use — an old session is still running"
  say "     ${D}fix: pkill -f server/server.py${Z}"
else
  ok "port 8484 free"
fi

hdr "$([ "$PROBLEMS" = 0 ] && echo "${G}preflight clean${Z}" || echo "${R}$PROBLEMS problem(s) above${Z}")"

if [ "$CHECK_ONLY" = 1 ]; then
  exit $((PROBLEMS > 0))
fi

# --- run --------------------------------------------------------------------
if [ "$KIOSK" = 0 ]; then
  say
  say "  Fedora: sudo dnf install cage chromium mpv foot"
  say "  Debian: sudo apt install cage chromium mpv foot"
  say
  say "Backend-only — open http://127.0.0.1:8484 in a browser."
  say "(Gamepad, weather and the whole UI work there; only the kiosk shell is"
  say " missing, and launched apps land in your normal desktop.)"
  hdr "session output"
  # exec so Ctrl+C reaches the backend directly (it kills the running app on
  # the way out); the tee above stays attached across the exec.
  exec python3 -u "$HTPC_DIR/server/server.py"
fi

# Nested under a compositor wlroots needs the Wayland backend; on a bare TTY it
# picks DRM by itself. Software rendering keeps it working on VM/dev GPUs.
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
  export WLR_BACKENDS=wayland
  export WLR_RENDERER=pixman
  export WLR_NO_HARDWARE_CURSORS=1
  say "  wlroots          backend=wayland renderer=pixman (nested)"
fi

# start-session.sh backgrounds its daemons, so when cage goes away they are
# orphaned — on a dev machine there is no unit cgroup to sweep them up, and the
# next run then fails with "port 8484 is already in use". Matching on this
# clone's absolute paths kills exactly the processes this script started, and
# nothing belonging to another clone on the same machine. SIGTERM, not KILL: the backend
# handles it by taking the running app down with it.
cleanup() {
  local left=0 p
  for p in server/server.py daemon/homebutton.py daemon/cecd.py; do
    if pkill -f -- "$HTPC_DIR/$p" 2>/dev/null; then
      say "  stopped $p"
      left=1
    fi
  done
  [ "$left" = 1 ] && sleep 0.5
  for p in server/server.py daemon/homebutton.py daemon/cecd.py; do
    pkill -KILL -f -- "$HTPC_DIR/$p" 2>/dev/null
  done
  say ""
  hdr "session ended"
  [ "$QUIET" = 0 ] && say "  full log: $LOG"
  return 0
}
trap cleanup EXIT

hdr "session output  ${D}(name | line)${Z}"
cage -- "$HTPC_DIR/system/start-session.sh"
rc=$?
say "cage exited with status $rc"
exit $rc
