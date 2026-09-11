#!/usr/bin/env python3
"""Photograph the framebuffer through the wire, not the glass.

The 7-inch P4's backlight is gated by a power rail we have not cracked, so the panel is
often dark even when the firmware is drawing a perfectly good screen. `fbdump` prints the
framebuffer back over the console; this reads that, reconstructs the image, and writes a
PNG. So a kiosk screen can be verified — its layout, its text, its colours — with the lamp
behind the glass switched off entirely.

    ./fbshot.py out.png [columns] [--cmd "kiosk home"]

With --cmd it sends that console command first (draw the screen), then dumps. Default
width is 96 physical columns, upscaled on the way to PNG so the 5x7 text stays legible.
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ch340 import CH340Serial

HEXSET = set("0123456789abcdef")


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    out = argv[1]
    cols = "96"
    pre_cmd = None
    i = 2
    while i < len(argv):
        if argv[i] == "--cmd":
            pre_cmd = argv[i + 1]
            i += 2
        else:
            cols = argv[i]
            i += 1

    with CH340Serial(115200, timeout=0.3) as port:
        if pre_cmd:
            port.reset_input_buffer()
            port.write((pre_cmd + "\n").encode())
            time.sleep(1.2)
        port.reset_input_buffer()
        port.write(("fbdump " + cols + "\n").encode())
        buf = b""
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            chunk = port.read(4096)
            if chunk:
                buf += chunk
                if b"FBEND" in buf:
                    break
            else:
                time.sleep(0.02)

    lines = buf.decode("utf-8", "replace").splitlines()
    start = next((k for k, l in enumerate(lines) if l.startswith("FBDUMP")), None)
    if start is None:
        print("no FBDUMP header in reply", file=sys.stderr)
        return 1
    parts = lines[start].split()
    width = int(parts[1])
    rows = []
    for l in lines[start + 1:]:
        if l.startswith("FBEND"):
            break
        l = l.strip()
        if len(l) >= width * 6 and set(l[:width * 6]) <= HEXSET:
            rows.append(l[:width * 6])
    if not rows:
        print("no pixel rows parsed", file=sys.stderr)
        return 1

    ppm = bytearray(("P6\n%d %d\n255\n" % (width, len(rows))).encode())
    for l in rows:
        for x in range(width):
            base = x * 6
            ppm += bytes((int(l[base:base + 2], 16),
                          int(l[base + 2:base + 4], 16),
                          int(l[base + 4:base + 6], 16)))
    ppm_path = out + ".ppm"
    with open(ppm_path, "wb") as f:
        f.write(ppm)
    # Upscale on conversion so the small dump is readable; sips is always present.
    subprocess.run(["sips", "-s", "format", "png", "--resampleWidth", "960",
                    ppm_path, "--out", out], capture_output=True, check=True)
    os.remove(ppm_path)
    print("wrote %s (%dx%d framebuffer)" % (out, width, len(rows)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
