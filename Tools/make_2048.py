#!/usr/bin/env python3
"""Draws what 2048 is played with (Games/2048.lua, on GUI/SlideGrid.lua), and its icon.

    python3 Tools/make_2048.py Images

Writes Images/2048/<size>/tile.tga at the sizes a board picks from: a tile in white with its
light and shade painted in greys, for the game to tint by what it is worth and write a number on.
Also Images/Icons/2048.tga, four tiles that spell the game's name. Only the standard library is
used. Pass a second folder to also get PNG copies there, which are easier to look at than TGA.
"""
import math
import struct
import sys
import zlib
from pathlib import Path

SIZES = (64, 128, 256)
SAMPLES = 4
# Half the side of a tile and how round its corners are, in a picture from -1 to 1
TILE, CORNER = 0.95, 0.2
# How far up the tile sits from the middle of its picture, which leaves room for its edge and
# the shadow under it
LIFT = 0.045
SLATE = (34, 38, 48)
# The four tiles of the icon, in the colours the game gives to 2, 8, 64 and 2048, and what is
# written on them
ICON_TILES = (
    ((238, 228, 218), (119, 110, 101), "2"),
    ((242, 177, 121), (255, 255, 255), "0"),
    ((246, 94, 59), (255, 255, 255), "4"),
    ((237, 194, 46), (255, 255, 255), "8"),
)
# The strokes of the digits, in a box from -1 to 1 with y pointing down
DIGITS = {
    "2": [[(-0.5, -0.62), (0.5, -0.62), (0.5, 0), (-0.5, 0), (-0.5, 0.62), (0.5, 0.62)]],
    "0": [[(-0.5, -0.62), (0.5, -0.62), (0.5, 0.62), (-0.5, 0.62), (-0.5, -0.62)]],
    "4": [[(-0.5, -0.62), (-0.5, 0.05), (0.5, 0.05)], [(0.5, -0.62), (0.5, 0.62)]],
    "8": [[(-0.5, -0.62), (0.5, -0.62), (0.5, 0.62), (-0.5, 0.62), (-0.5, -0.62)], [(-0.5, 0), (0.5, 0)]],
}


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def clamp(value):
    return max(0.0, min(1.0, value))


def rounded(x, y, half, corner):
    """How far a point is outside a square with round corners, below zero inside it"""
    dx, dy = abs(x) - half + corner, abs(y) - half + corner
    return math.hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - corner


def to_segment(x, y, a, b):
    (ax, ay), (bx, by) = a, b
    t = clamp(((x - ax) * (bx - ax) + (y - ay) * (by - ay)) / ((bx - ax) ** 2 + (by - ay) ** 2))
    return math.hypot(x - ax - t * (bx - ax), y - ay - t * (by - ay))


def tile(x, y):
    """A tile to tint: white, a little darker towards the bottom, with an edge that gives it
    some thickness and a thin shadow under it"""
    face = rounded(x, y + LIFT, TILE - LIFT, CORNER)
    if face <= 0:
        # Lit from above: brightest just under the top edge
        shade = 1.0 - 0.07 * clamp((y + 1) / 2)
        shade += 0.05 * clamp(1 + face / 0.07) * clamp(-y)
        return (255 * clamp(shade),) * 3, 1.0
    body = rounded(x, y, TILE, CORNER)
    if body <= 0:
        # The edge that shows under the face
        return (198, 198, 198), 1.0
    return (0, 0, 0), 0.0


def icon(x, y):
    """Four tiles in a square on slate, with 2, 0, 4 and 8 on them"""
    column, row = (0 if x < 0 else 1), (0 if y < 0 else 1)
    color, ink, digit = ICON_TILES[row * 2 + column]
    # Where the point is on its own tile, from -1 to 1
    tx, ty = (x - (column - 0.5) * 0.92) / 0.42, (y - (row - 0.5) * 0.92) / 0.42
    shade, alpha = tile(tx, ty)
    if alpha <= 0:
        return SLATE, 1.0
    painted = tuple(color[i] * shade[i] / 255 for i in range(3))
    stroke = min(to_segment(tx, ty + LIFT, a, b) for line in DIGITS[digit] for a, b in zip(line, line[1:]))
    return mix(painted, ink, clamp((0.15 - stroke) / 0.05)), 1.0


def render(size, paint):
    """Rows of (r, g, b, a) from a function of a point in a square from -1 to 1"""
    rows = []
    for py in range(size):
        row = []
        for px in range(size):
            red = green = blue = alpha = 0.0
            for i in range(SAMPLES):
                for j in range(SAMPLES):
                    x = (px + (i + 0.5) / SAMPLES) / size * 2 - 1
                    y = (py + (j + 0.5) / SAMPLES) / size * 2 - 1
                    color, a = paint(x, y)
                    red, green, blue, alpha = red + color[0] * a, green + color[1] * a, blue + color[2] * a, alpha + a
            if alpha > 0:
                row.append((round(red / alpha), round(green / alpha), round(blue / alpha), round(255 * alpha / SAMPLES**2)))
            else:
                # White where nothing is, so that a tile shrunk on screen doesn't get a dark rim
                row.append((255, 255, 255, 0))
        rows.append(row)
    return rows


def write(path, rows, preview):
    size = len(rows)
    path.parent.mkdir(parents=True, exist_ok=True)
    # TGA rows run bottom to top
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, size, size, 32, 8)
    path.write_bytes(header + b"".join(bytes((b, g, r, a)) for row in reversed(rows) for (r, g, b, a) in row))
    if preview:
        raw = b"".join(b"\x00" + b"".join(bytes(pixel) for pixel in row) for row in rows)

        def chunk(kind, body):
            return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

        png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
        png += chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
        preview.mkdir(parents=True, exist_ok=True)
        (preview / (path.parent.name + "_" + path.stem + ".png")).write_bytes(png)


target = Path(sys.argv[1])
preview = Path(sys.argv[2]) if len(sys.argv) > 2 else None
for size in SIZES:
    write(target / "2048" / str(size) / "tile.tga", render(size, tile), preview)
write(target / "Icons" / "2048.tga", render(64, icon), preview)
