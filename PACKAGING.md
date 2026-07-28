# Should nothing-htpc ship as an OS image?

A decision doc, written when the box moved from a Ryzen tower to a Raspberry
Pi 3B+ hidden behind the TV. The trigger was a real annoyance: every rebuild
means walking the README again, and the README is now nine steps long.

**Short answer: write the install script now, generate an image from it later,
never build a distro.** The reasoning is below, including why the middle
option is tempting for the wrong reasons.

---

## What "installable in one go" could mean

| | What it is | Build effort | Maintenance | Boot to launcher | Recover from a bad change |
|---|---|---|---|---|---|
| **0. Status quo** | README, nine manual steps | none | none | ~35 s | edit files on the box |
| **1. Bootstrap script** | `install.sh` on Pi OS Lite | ~1 day | low | ~35 s | edit files on the box |
| **2. Custom image** | pi-gen stage → flashable `.img` | ~2–4 days | medium | ~30 s | re-flash, or edit on the box |
| **3. Buildroot / Yocto** | purpose-built Linux, read-only root | ~2–4 weeks | high | ~12 s | re-flash only |

The columns that decide it are the last two, not the first two.

---

## Option 1 — bootstrap script

`system/install.sh`: apt packages, systemd unit pointed at the clone,
udev rules, `config.txt` edits, group membership. Idempotent, re-runnable,
`--dry-run`. It deploys nothing — the box runs the checkout in place, so
updating is `git pull` and a service restart.

**For**
- Removes ~90 % of the repetition for ~5 % of the effort of an image.
- Everything stays inspectable and fixable *on the box*, over SSH, with the
  TV on. For a single-owner appliance this matters more than elegance.
- It is a strict prerequisite for option 2 anyway: pi-gen's custom stage is
  mostly "run this script in a chroot". Doing it first is not a detour.
- Keeps the repo's stated convention — no build step, no bundlers, runnable
  from a fresh `git clone`.

**Against**
- Still needs a working Raspberry Pi OS install first: Imager, first boot,
  SSH in, `git clone`, run script. Call it 20 minutes of babysitting.
- Does not pin package versions. A Pi OS point release can still move
  something under you (this is real: the `/boot` → `/boot/firmware` move in
  Bookworm broke every `config.txt` script in existence).

---

## Option 2 — custom image with pi-gen

pi-gen is the tool Raspberry Pi OS itself is built with. You add a
`stage-htpc` after stage2 (the Lite rootfs), containing a package list and a
`00-run.sh` that installs this repo. Output is a flashable `.img`. There is
also the newer `rpi-image-gen`, which is more declarative and worth
evaluating when you get here — pi-gen is the safer, better-documented
starting point today.

**For**
- Flash, boot, done. Genuine one-go install.
- Reproducible: the same image on a spare SD card is a known-good rollback,
  which is the single best answer to "I broke it and the TV is the only
  screen in the house".
- Raspberry Pi Imager already handles the parts an image is bad at — wifi
  credentials, hostname, user, SSH key, locale — through its customisation
  screen. **This kills the strongest argument against images.** You do not
  have to build a first-boot config UI.
- Version-pinnable: the image freezes a known-working package set.

**Against**
- The build needs a Docker host and ~10 GB scratch; it is not something you
  run casually from the couch.
- Two update paths now exist (`git pull` on the box vs. re-flash) and they
  drift. You need a rule for which one is authoritative.
- **Secrets must stay out.** This repo is public and the image would be a
  binary blob nobody diffs. Weather coordinates are harmless; the NAS
  address, Jellyfin credentials and Spotify login are not. They belong in a
  file the image reads at first boot, never in the image.

---

## Option 3 — Buildroot / Yocto

A purpose-built OS: kernel, busybox, cage, chromium, mpv, this repo. Nothing
else. Read-only root, boots in ~12 s, essentially immortal against SD
corruption.

**Against, decisively**
- Weeks of work, and the work never really ends — every mpv or Chromium bump
  is a cross-compile problem instead of an `apt upgrade`.
- Read-only root means no fixing anything on the box. Every change becomes a
  rebuild-and-reflash cycle on the dev machine.
- Chromium under Buildroot on ARM is a known ordeal.
- It buys ~20 seconds of boot time on a device that is going to be powered
  on permanently anyway, drawing 2 W behind the TV.

This is the right answer for a product with a thousand units in the field. It
is the wrong answer for one box.

---

## Recommendation

**Phase 1 — now.** `system/install.sh`, plus a `--check` mode that verifies a
running box (CEC device present, groups right, service enabled, config.txt
correct). Ship it, use it for the next two or three rebuilds, and let it
absorb the mistakes. The script is where knowledge about this box should
accumulate.

**Phase 2 — once the script has stopped changing.** Wrap the *same script*
in a pi-gen `stage-htpc`. Because the script is the payload, the image adds
packaging only, not a second source of truth. Definition of done: a fresh SD
card reaches the dot-matrix clock with no keyboard attached.

**Phase 3 — optional, probably never.** Read-only root with an overlay, `/var`
and the Chromium profile on tmpfs. Do this only if SD corruption actually
bites. It is a cheap add-on to an existing image, so there is no cost to
deferring it.

**Skip straight to Phase 2 if** you end up wanting a second box (bedroom TV),
or if you find yourself re-flashing more than about once a month. Both change
the arithmetic; neither is true today.

---

## Things the image has to solve that the script does not

- **First-boot identity** — hostname, wifi, user. Delegated to Pi Imager.
- **Per-box config** — weather coordinates, NAS address, the MUSIC tile
  choice. Should live in one file (`server/config.json` plus a small
  `local.env`), explicitly *not* baked in.
- **Secrets** — see above. Out of the image, out of the repo.
- **Update policy** — pick one and write it down: either the box is
  `git pull`-updated and the image is only for bare metal, or the image is
  authoritative and the box is never edited. Drift between these two is the
  most likely way this ends up confusing in a year.
- **SD wear** — Chromium's cache and journald are the two writers worth
  redirecting to tmpfs. Cheap in the image, fiddly by hand.

## Open questions

1. Does the box get a static IP / mDNS name for SSH? An image should decide.
2. Is a second Pi ever likely? If yes, Phase 2 moves up.
3. Where does `channels.m3u` live — baked in, or fetched? It changes far more
   often than anything else here, which argues for keeping it out of the image
   and pulling it on boot.
