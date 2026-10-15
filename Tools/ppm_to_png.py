#!/usr/bin/env python3
"""Makes PNGs of the PPM pictures Tools/render_view.lua draws, bigger and with Doom's pixels as
tall as they were on its screen (320 by 200 shown at 4 by 3), and with --sheet, one picture of
them all, two across, to look at together.

    python3 Tools/ppm_to_png.py <folder> [--scale 3] [--sheet sheet.png]

Only the standard library is used.
"""
import argparse
import struct
import zlib
from pathlib import Path

ASPECT = 1.2


def read(path):
    raw = path.read_bytes()
    parts = raw.split(b"\n", 3)
    width, height = map(int, parts[1].split())
    body = parts[3]
    return width, height, [[body[(y * width + x) * 3:(y * width + x) * 3 + 3] for x in range(width)] for y in range(height)]


def scaled(width, height, rows, scale):
    wide, tall = int(width * scale), int(height * scale * ASPECT)
    return wide, tall, [[rows[y * height // tall][x * width // wide] for x in range(wide)] for y in range(tall)]


def write(path, width, height, rows):
    raw = b"".join(b"\0" + b"".join(row) for row in rows)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    path.write_bytes(png + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("folder", type=Path)
    parser.add_argument("--scale", type=float, default=3)
    parser.add_argument("--sheet", type=Path, default=None)
    args = parser.parse_args()
    shots = []
    for path in sorted(args.folder.glob("*.ppm"), key=lambda each: int("".join(c for c in each.stem if c.isdigit()) or 0)):
        width, height, rows = scaled(*read(path), args.scale)
        write(path.with_suffix(".png"), width, height, rows)
        shots.append((width, height, rows))
    if args.sheet and shots:
        width, height = shots[0][0], shots[0][1]
        gap, across = 4, 2
        down = (len(shots) + across - 1) // across
        black = b"\0\0\0"
        sheet = [[black] * (across * (width + gap)) for _ in range(down * (height + gap))]
        for index, (_, _, rows) in enumerate(shots):
            left, top = index % across * (width + gap), index // across * (height + gap)
            for y, row in enumerate(rows):
                sheet[top + y][left:left + width] = row
        write(args.sheet, len(sheet[0]), len(sheet), sheet)


if __name__ == "__main__":
    main()
