#!/usr/bin/env python3
"""Generate grayscale TV-static frames as raw BGRA for mpv's overlay-add.

Usage: gen_static.py WIDTH HEIGHT NFRAMES OUTDIR
Writes f0.raw .. fN.raw (w*h*4 bytes each). Uses slice assignment so a
full 1080p set generates in well under a second.
"""
import os
import sys

def main():
    w, h, n, out = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    os.makedirs(out, exist_ok=True)
    npx = w * h
    alpha = b"\xff" * npx
    for i in range(n):
        gray = os.urandom(npx)          # one random byte per pixel
        frame = bytearray(npx * 4)      # B G R A
        frame[0::4] = gray
        frame[1::4] = gray
        frame[2::4] = gray
        frame[3::4] = alpha
        with open(os.path.join(out, f"f{i}.raw"), "wb") as f:
            f.write(frame)

if __name__ == "__main__":
    main()
