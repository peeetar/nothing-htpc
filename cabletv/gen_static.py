#!/usr/bin/env python3
"""Generate one analog-TV noise field as raw BGRA for mpv's overlay-add.

Usage: gen_static.py WIDTH HEIGHT OUTFILE

Writes a single headerless W*H BGRA buffer. Two things are deliberate:

* The field is taller than the screen. cabletv.lua draws every static frame
  from a random pixel offset into this one buffer, so a few hundred spare
  rows are worth hundreds of thousands of distinct-looking frames. The old
  scheme wrote N whole frames and cycled them, and a 4-frame cycle at 8fps
  reads as a looping texture rather than as noise - that is what made the
  static look fake.
* The noise is colored, one independent random byte per channel per pixel.
  This is the "colored / fine" variant of AliKHaliliT/Analog-TV-Noise-Effect
  (isColor: true, grainSize: 1). Equal R=G=B grayscale noise reads as a flat
  gray shimmer on an LCD; the color speckle is what an untuned analog tuner
  actually looks like.

Stdlib only (constraint: the HTPC has no pip packages), and generated in row
chunks so peak memory stays near a megabyte instead of the ~20MB a whole
1080p field would need on a 1GB Pi.
"""
import os
import sys

CHUNK_ROWS = 64


def main():
    w, h, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    tmp = out + ".tmp"
    with open(tmp, "wb") as f:
        left = h
        while left > 0:
            rows = min(CHUNK_ROWS, left)
            n = w * rows
            rnd = os.urandom(n * 3)
            buf = bytearray(b"\xff" * (n * 4))   # pre-fills the alpha channel
            buf[0::4] = rnd[0:n]                 # B
            buf[1::4] = rnd[n:2 * n]             # G
            buf[2::4] = rnd[2 * n:3 * n]         # R
            f.write(buf)
            left -= rows
    # mpv mmaps this file; swapping it in whole means a reader can never see
    # a half-written field.
    os.replace(tmp, out)


if __name__ == "__main__":
    main()
