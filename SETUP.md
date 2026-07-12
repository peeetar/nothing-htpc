# Nothing-Style HTPC — Setup Guide

A controller-only home theater PC: minimal Debian, a custom
dot-matrix launcher as the shell, Jellyfin for movies + free IPTV,
Navidrome/Spotify for music, Steam Big Picture for gaming, full
HDMI-CEC, wake-from-suspend with the controller.

Hardware: Ryzen CPU + Radeon Vega 56, 8BitDo Ultimate 2C (use the
2.4GHz USB dongle — required for wake), Pulse-Eight USB-CEC adapter.

---

## 1. Base OS

Install **Debian 13 netinstall**, deselect every desktop environment
(only "standard system utilities" + SSH). Create user `htpc`.

```bash
sudo apt update
sudo apt install -y cage chromium python3 python3-evdev \
    cec-utils mesa-vulkan-drivers firmware-amd-graphics \
    pipewire pipewire-audio wireplumber curl unzip
sudo usermod -aG input,video,audio htpc
```

Vega 56 works out of the box with the open `amdgpu` driver —
hardware video decode (VAAPI) included.

## 2. Install this project

```bash
sudo mkdir -p /opt/htpc
sudo cp -r launcher server daemon system /opt/htpc/
sudo chmod +x /opt/htpc/system/start-session.sh
sudo chown -R htpc:htpc /opt/htpc
```

Edit `/opt/htpc/server/config.json`:
- set your latitude/longitude for weather
- adjust app commands (see sections below)

Boot straight into the launcher:

```bash
sudo cp /opt/htpc/system/htpc-session.service /etc/systemd/system/
# check that `id htpc` shows uid 1000; if not, fix XDG_RUNTIME_DIR in the unit
sudo systemctl disable getty@tty1
sudo systemctl enable htpc-session
sudo systemctl set-default graphical.target
sudo reboot
```

You should land on the black launcher with the dot-matrix clock.
Navigate with the controller D-pad, open with A, and **hold the
home/guide button ~1 second from inside any app to return here**.
(A short press is ignored so Steam keeps its own guide-button menu.)

## 3. STREAMING + LIVE TV — Jellyfin

Server runs on your NAS (Docker image `jellyfin/jellyfin` or the
native package for your NAS OS). Point libraries at your movie/show
folders.

**Free IPTV:** in Jellyfin Dashboard → Live TV → Tuner Devices, add
an **M3U Tuner** with the iptv-org playlist URL, e.g.
`https://iptv-org.github.io/iptv/index.m3u` (or a per-country list
like `.../countries/mk.m3u`). Add the XMLTV guide from the same
project if you want EPG. Thousands of legally free, publicly
available channels, maintained on GitHub — updates itself.

**Client on the HTPC:** Jellyfin Media Player (TV mode = fully
gamepad/remote navigable):

```bash
# .deb from https://github.com/jellyfin/jellyfin-media-player/releases
sudo apt install ./jellyfinmediaplayer_*.deb
```

First run: sign into your NAS server (one-time keyboard moment).
Both the STREAMING and LIVE TV tiles open this client; Live TV is a
row inside Jellyfin's home screen.

## 4. MUSIC — Navidrome + Spotify

**Navidrome** stays on the NAS. On the HTPC install **Feishin**
(Subsonic-compatible, clean dark UI):

```bash
# AppImage from https://github.com/jeffvli/feishin/releases
mkdir -p ~/apps && mv Feishin-*.AppImage ~/apps/feishin && chmod +x ~/apps/feishin
```

Set the MUSIC tile command to `["/home/htpc/apps/feishin"]`.

**Spotify:** run `spotifyd` (already started by the session script if
installed). The HTPC appears as a **Spotify Connect** device — pick
it from your phone, audio plays on the TV. No on-screen Spotify UI to
fight with a controller; your phone is the remote. Install: grab the
binary from https://github.com/Spotifyd/spotifyd/releases into
`/usr/local/bin`, add your credentials or use zeroconf discovery.

## 5. GAMING — Steam Big Picture

```bash
sudo dpkg --add-architecture i386 && sudo apt update
sudo apt install -y steam-installer gamescope
```

The GAMING tile runs `steam -gamepadui`. For a smoother compositor
inside the session, change the command to:

```json
["gamescope", "-e", "-f", "--", "steam", "-gamepadui"]
```

Inside Steam, a *short* press of the guide button opens Steam's own
overlay as normal; *holding* it returns to the launcher.

## 6. HDMI-CEC

Desktop GPUs (your Vega 56 included) do not wire the CEC pin, so a
**Pulse-Eight USB-CEC adapter** goes inline on the HDMI cable.

```bash
sudo cp /opt/htpc/system/cec-tv.sh /usr/lib/systemd/system-sleep/
sudo chmod +x /usr/lib/systemd/system-sleep/cec-tv.sh
```

Result: suspend puts the TV on standby; wake turns the TV on and
switches it to the HTPC input. Test manually with
`echo "on 0" | cec-client -s -d 1`.

## 7. Wake with the controller

1. BIOS: enable *USB wake / wake from S3*, disable *ErP/deep sleep*.
2. Use the 8BitDo **2.4GHz dongle** (Bluetooth generally can't wake).
3. Install the udev rule:

```bash
sudo cp /opt/htpc/system/99-wake-controller.rules /etc/udev/rules.d/
sudo udevadm control --reload
```

4. Verify after replug: `cat /sys/bus/usb/devices/*/power/wakeup`
   should show `enabled` for the dongle.

Suspend behavior: map a long-press somewhere (e.g. a SETTINGS tile
entry running `systemctl suspend`) or just let the TV remote's CEC
standby propagate. Any controller button then wakes the whole chain:
PC → CEC → TV on → launcher in ~3 seconds.

## 8. Updates without breakage

Everything here is either Debian stable, a static AppImage, or your
own code — nothing Kodi-style layered on add-ons. `apt upgrade` is
safe; Jellyfin server updates happen on the NAS independently of the
client. The launcher itself has zero dependencies beyond a browser.

## Idle footprint

cage + chromium kiosk + two small Python processes ≈ 500–700 MB RAM,
~0% CPU at the menu. With `amdgpu` power management the Vega 56 idles
low; the box is silent at the launcher.

## Troubleshooting

- **Black screen on boot:** `journalctl -u htpc-session -b` — usually
  a wrong uid in `XDG_RUNTIME_DIR` or missing `--ozone-platform=wayland`.
- **App opens behind the launcher:** cage shows the newest window on
  top; if an app spawns a splash first, add a small `sleep` wrapper.
- **Controller not seen by the browser:** press any button once —
  the Gamepad API only exposes pads after first input.
- **CEC does nothing:** check `cec-client -l` lists the Pulse-Eight;
  some TVs need CEC enabled in their own settings (Anynet+/Bravia
  Sync/Simplink — every brand renames it).
