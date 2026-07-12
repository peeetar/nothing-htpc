# nothing-htpc

A controller-only home theater PC with a Nothing-OS-inspired shell:
pure black, dot-matrix clock, one red dot, six tiles. No desktop
environment, no Kodi, nothing to break on update.

- **STREAMING / LIVE TV** — Jellyfin (server on the NAS) + free
  IPTV channels from the iptv-org GitHub playlist
- **MUSIC** — Feishin → Navidrome on the NAS; Spotify via
  spotifyd (the HTPC shows up as a Spotify Connect speaker,
  your phone is the remote)
- **GAMING** — Steam Big Picture (gamescope optional)
- **HDMI-CEC** — TV powers on/off and switches input with the PC
- **Controller-only** — wake from suspend with the gamepad; hold
  the guide/home button ~1s in any app to return to the launcher

Idle footprint is roughly 500–700 MB RAM and ~0% CPU at the menu.

## Hardware

| Part | Used here | Notes |
|---|---|---|
| PC | Ryzen + Radeon Vega 56 | any amdgpu-supported card works |
| Controller | 8BitDo Ultimate 2C | **use the 2.4GHz USB dongle** — needed for wake |
| CEC | Pulse-Eight USB-CEC adapter | desktop GPUs have no CEC pin on HDMI; this is mandatory for CEC |
| NAS | anything running Jellyfin + Navidrome | Docker or native |

## How it works

```
boot → systemd → cage (Wayland kiosk) → chromium --kiosk → launcher/index.html
                                   ↘ server.py  (:8484, launches/kills apps)
                                   ↘ homebutton.py (hold guide button → /home)
                                   ↘ spotifyd (Spotify Connect endpoint)
```

`server.py` reads `server/config.json`; each tile maps to a command.
Launching a tile kills the previous app's whole process group, so
there is always exactly one foreground app or the launcher.

Repo layout (**the folder structure is load-bearing** — the service,
script, and server all find each other by relative path):

```
launcher/index.html          the UI (also opens standalone in any browser)
server/server.py             backend
server/config.json           tiles + weather coords
server/config.vm.json        lightweight stand-in apps for VM testing
daemon/homebutton.py         hold-guide-to-go-home daemon
system/start-session.sh      what cage runs
system/htpc-session.service  boots straight into the kiosk
system/cec-tv.sh             suspend/wake hook → TV on/off via CEC
system/99-wake-controller.rules  lets the 8BitDo dongle wake the PC
```

---

# Install (bare metal)

## 0. BIOS

Enable *USB wake from S3* (sometimes "wake on USB"), disable
*ErP / deep sleep* so USB ports stay powered in suspend.

## 1. Debian

Install Debian 13 netinst. At software selection **uncheck** "Debian
desktop environment" and "GNOME"; **check** "SSH server" and
"standard system utilities".

> **Username matters.** This repo's service file says `User=petar`.
> Either create your user as `petar`, or edit
> `system/htpc-session.service` to your username — and make sure
> `XDG_RUNTIME_DIR=/run/user/1000` matches your `id`. If they don't
> match, the session crash-loops with `status=217/USER`.

## 2. Packages

```bash
sudo apt update
sudo apt install -y cage chromium python3 python3-evdev \
    cec-utils mesa-vulkan-drivers firmware-amd-graphics \
    pipewire pipewire-audio wireplumber git curl unzip
sudo usermod -aG input,video,audio petar
```

(`input` lets the home-button daemon read the controller, `video`
the display. Group changes need a re-login/reboot to apply.)

## 3. Install the project

```bash
git clone https://github.com/peeetar/nothing-htpc /home/petar/nothing-htpc
cd /home/petar/nothing-htpc
sudo mkdir -p /opt/htpc
sudo cp -r launcher server daemon system /opt/htpc/
sudo chmod +x /opt/htpc/system/start-session.sh
sudo chown -R petar:petar /opt/htpc
```

Edit `/opt/htpc/server/config.json`: set your latitude/longitude
(weather is open-meteo.com, no API key) and check the app commands.

## 4. Boot into the launcher

```bash
id petar   # confirm uid 1000 — if not, fix it in the service file first
sudo cp /opt/htpc/system/htpc-session.service /etc/systemd/system/
sudo systemctl disable getty@tty1
sudo systemctl enable htpc-session
sudo systemctl set-default graphical.target
sudo reboot
```

You should land on the dot-matrix clock. D-pad/arrow keys navigate,
A/Enter opens a tile, **holding the guide button ~1 second inside
any app returns home** (a short press is ignored so Steam keeps its
own guide-button overlay).

## 5. Streaming + Live TV (Jellyfin)

Server on the NAS (`jellyfin/jellyfin` in Docker or native package),
libraries pointed at your media folders.

Free IPTV: Dashboard → Live TV → Tuner Devices → add **M3U Tuner**
with `https://iptv-org.github.io/iptv/index.m3u` (or a per-country
list under `.../countries/`). Add iptv-org's XMLTV guide for EPG.

Client on the HTPC:

```bash
# .deb from https://github.com/jellyfin/jellyfin-media-player/releases
sudo apt install ./jellyfinmediaplayer_*.deb
```

First launch is the one time you need a keyboard: sign into the NAS
server. The STREAMING and LIVE TV tiles both open this client.

## 6. Music

Feishin (Navidrome client) as an AppImage:

```bash
mkdir -p ~/apps
# download from https://github.com/jeffvli/feishin/releases
chmod +x ~/apps/feishin
```

Point the MUSIC tile at it in config.json. For Spotify, install
spotifyd (https://github.com/Spotifyd/spotifyd/releases →
`/usr/local/bin/spotifyd`); the session script auto-starts it and
the HTPC appears as a Spotify Connect device on your phone.

## 7. Gaming

```bash
sudo dpkg --add-architecture i386 && sudo apt update
sudo apt install -y steam-installer gamescope
```

The GAMING tile runs `steam -gamepadui`. Smoother alternative in
config.json: `["gamescope", "-e", "-f", "--", "steam", "-gamepadui"]`.

## 8. HDMI-CEC

Put the Pulse-Eight adapter inline on the HDMI cable, then:

```bash
sudo cp /opt/htpc/system/cec-tv.sh /usr/lib/systemd/system-sleep/
sudo chmod +x /usr/lib/systemd/system-sleep/cec-tv.sh
# test: TV should power on
echo "on 0" | cec-client -s -d 1
```

Suspend now puts the TV on standby; wake turns it on and grabs the
input. If nothing happens, enable CEC on the TV itself (Samsung:
Anynet+, LG: Simplink, Sony: Bravia Sync — every brand renames it).

## 9. Controller wake

```bash
sudo cp /opt/htpc/system/99-wake-controller.rules /etc/udev/rules.d/
sudo udevadm control --reload
# replug the dongle, then verify:
grep -H . /sys/bus/usb/devices/*/power/wakeup
```

The 8BitDo dongle entry should say `enabled`. Any button press then
wakes the PC → CEC turns on the TV → launcher in a few seconds.

---

# Testing in a VM first (optional)

Everything except CEC, real suspend/wake, and GPU performance can be
validated in VirtualBox. Differences from bare metal, learned the
hard way:

1. **Graphics controller:** Settings → Display → **VBoxSVGA**, 3D
   acceleration **off**. The default VMSVGA controller's `vmwgfx`
   driver logs `*ERROR* ... unsupported hypervisor` and cage gets no
   display.
2. **Software rendering:** uncomment the two `WLR_RENDERER=pixman`
   lines in `htpc-session.service`, and add `--disable-gpu \` to the
   chromium flags in `start-session.sh`.
3. **Stand-in apps:** `sudo apt install mpv foot htop`, then
   `cp /opt/htpc/server/config.vm.json /opt/htpc/server/config.json`
   — tiles launch color bars / a test tone / htop instead of
   Steam and Jellyfin, exercising the full launch/kill/home loop.
4. Pass the controller through: Devices → USB → 8BitDo (needs the
   VirtualBox Extension Pack).
5. Skip `firmware-amd-graphics` / `mesa-vulkan-drivers` in the VM.
6. Shut down with Machine → ACPI Shutdown, not power-off, or the
   disk journal has to recover every boot.

---

# Troubleshooting (field notes)

**Flickering screen / boot loop.** The session is crash-restarting
every 2s. Switch to another terminal (**Ctrl+Alt+F2**), log in, and:

```bash
journalctl -u htpc-session -b --no-pager | tail -30
```

- `status=217/USER` → the `User=` in the service doesn't exist on
  this machine. Fix the name and the uid in `XDG_RUNTIME_DIR`,
  `systemctl daemon-reload && systemctl restart htpc-session`.
- `status=1` right after a PAM "session opened" line → cage started
  but its target is missing or broken. First suspect: **flat repo
  layout**. GitHub's drag-and-drop web uploader flattens folders;
  everything must live in `launcher/ server/ daemon/ system/`
  subdirectories exactly as in this repo.
- wlroots/EGL/DRM errors → graphics. On a VM, see the VM section;
  on hardware, check `ls /dev/dri` shows `card0` and that
  `firmware-amd-graphics` is installed.

**Debugging cage by hand:** log in *directly* as your user on a
spare tty (Ctrl+Alt+F3) — not via `su` from root, or libseat throws
`Could not take control of session` / tty permission-denied errors
that look scary but only mean the tty belongs to root.

```bash
export XDG_RUNTIME_DIR=/run/user/1000
cage -d -- /opt/htpc/system/start-session.sh
```

**Backend sanity check (no GUI needed):**

```bash
python3 /opt/htpc/server/server.py &
curl localhost:8484/status && curl -X POST localhost:8484/home
```

**App opens behind the launcher:** cage raises the newest window;
apps with splash screens may need a tiny sleep-wrapper.

**Controller dead in the launcher:** press any button once — the
browser Gamepad API only exposes pads after first input.

---

# Updating

The whole system is Debian stable + AppImages + this repo. To update
the launcher/config after editing on GitHub:

```bash
cd ~/nothing-htpc && git pull
sudo cp -r launcher server daemon system /opt/htpc/
sudo chown -R petar:petar /opt/htpc
sudo systemctl restart htpc-session
```
