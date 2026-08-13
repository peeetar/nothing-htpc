#!/usr/bin/env bash
# Steam Big Picture inside gamescope — what the GAMING tile launches.
#
# This is the one tile that starts a *process*. Every other screen is drawn by
# the launcher page over the idle mpv, which is why opening TV or MOVIES has no
# black frame; a game does not fit that model at all, so GAMING goes back
# through the launch machinery in server.py that was kept for exactly this.
#
# Why gamescope and not bare Steam: the session is a cage kiosk with no window
# manager, so a bare Steam gets no fullscreen, no resolution control and no
# controller focus handling. gamescope is a nested compositor that gives all
# three, and it is the same thing the Steam Deck runs. Nested inside cage it
# behaves like any other Wayland client.
#
# Everything this prints goes through server.py's per-tile pump (constraint 17)
# and lands in the journal tagged [gaming]. That is deliberate: the failures
# here — no gamescope, no Steam, a driver that will not start — all look
# identical from the sofa (the TV blinks and comes back to the launcher), and
# the log is the only place they differ.

set -u

say() { printf '%s\n' "$*"; }

# --- what we need ------------------------------------------------------------
#
# Probed, never assumed, for the same reason start-session.sh probes chromium:
# a hardcoded binary name is how a working box reads as a broken one. Steam is
# `steam` from RPM Fusion / Debian, and `steam-runtime` or the Flatpak on other
# installs.
GAMESCOPE=""
for g in gamescope; do
  command -v "$g" >/dev/null && GAMESCOPE="$g" && break
done

STEAM=""
for s in steam steam-runtime; do
  command -v "$s" >/dev/null && STEAM="$s" && break
done
if [ -z "$STEAM" ] && command -v flatpak >/dev/null; then
  if flatpak info com.valvesoftware.Steam >/dev/null 2>&1; then
    STEAM="flatpak-steam"
  fi
fi

if [ -z "$GAMESCOPE" ]; then
  say "gamescope is not installed — the GAMING tile needs it to give Steam a"
  say "fullscreen surface and controller focus inside the kiosk."
  say "  Fedora: sudo dnf install gamescope"
  say "  Debian: sudo apt install gamescope"
  exit 127
fi

if [ -z "$STEAM" ]; then
  say "Steam is not installed."
  say "  Fedora: sudo dnf install steam        (needs RPM Fusion nonfree)"
  say "  Debian: sudo apt install steam"
  say "  Either: flatpak install flathub com.valvesoftware.Steam"
  exit 127
fi

# --- how it is run -----------------------------------------------------------
#
# Output resolution is the TV's, so it is read from the environment rather than
# guessed: HTPC_GAME_RES=2560x1440 on a box that wants it. gamescope's -W/-H is
# the *output*, and -w/-h the internal render size; leaving the internal size
# alone lets a game pick its own and gamescope scale it, which is what makes an
# older title look right on a 4K panel.
RES="${HTPC_GAME_RES:-1920x1080}"
W="${RES%x*}"
H="${RES#*x}"
REFRESH="${HTPC_GAME_REFRESH:-60}"

GS_ARGS=(-W "$W" -H "$H" -r "$REFRESH" -f)
# --expose-wayland lets Steam and games see the compositor for HDR/VRR
# negotiation; harmless where they cannot use it.
GS_ARGS+=(--expose-wayland)
# Extra flags for a specific box (--hdr-enabled, --adaptive-sync, -F fsr)
# without editing this file.
if [ -n "${HTPC_GAMESCOPE_ARGS:-}" ]; then
  read -ra _extra <<< "$HTPC_GAMESCOPE_ARGS"
  GS_ARGS+=("${_extra[@]}")
fi

# -gamepadui is Big Picture — the couch interface, navigable entirely from a
# controller or the arrow keys, which is the only kind this box can use.
case "$STEAM" in
  flatpak-steam) STEAM_CMD=(flatpak run com.valvesoftware.Steam -gamepadui) ;;
  *)             STEAM_CMD=("$STEAM" -gamepadui) ;;
esac

say "gamescope: $(command -v "$GAMESCOPE")"
say "steam:     $STEAM"
say "output:    ${W}x${H}@${REFRESH}"
say "launching: $GAMESCOPE ${GS_ARGS[*]} -- ${STEAM_CMD[*]}"

# exec so that server.py's kill lands on gamescope itself rather than on a
# shell that would leave it orphaned and still holding the display.
exec "$GAMESCOPE" "${GS_ARGS[@]}" -- "${STEAM_CMD[@]}"
