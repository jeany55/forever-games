#!/usr/bin/env python3
"""Draws what Minesweeper is played with, and its icon.

    python3 Tools/make_minesweeper.py Images

Writes Images/Minesweeper/cover.tga, the raised tile that lies on a square nobody has opened yet,
and what can stand on a square as Images/Minesweeper/<size>/<name>.tga at the sizes the game picks
from: flag, mine, and wrong for a flag that turned out to mark nothing. Also
Images/Icons/minesweeper.tga. Only the standard library is used. Pass a second folder to also get
PNG copies there, which are easier to look at than TGA.

The field is thirty squares wide at its widest, so everything here is drawn bold enough to still
be told apart when a square is fifteen pixels across.
"""
import math
import struct
import sys
import zlib
from pathlib import Path

SIZES = (32, 64, 128)
COVER_SIZE = 64
SAMPLES = 4

# A tile seen from above, lit from the top left: its face, the edges that catch the light and the
# ones that don't, and how wide an edge is in a square from -1 to 1
FACE, LIT, SHADED = (104, 118, 146), (176, 190, 214), (48, 56, 76)
EDGE = 0.16
# What an opened square looks like in the game, for the icon. Games/Minesweeper.lua has the same
SUNK, LINES = (38, 42, 52), (16, 18, 24)
ONE = (92, 150, 255)

CLOTH, CLOTH_DARK = (226, 48, 44), (150, 22, 26)
POLE = (232, 226, 210)
FOOT = (30, 30, 36)
IRON, IRON_LIT = (30, 31, 38), (150, 154, 170)
CROSS = (255, 70, 60)
NOTHING = ((0, 0, 0), 0.0)


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def in_polygon(x, y, points):
    inside = False
    for i in range(len(points)):
        (x1, y1), (x2, y2) = points[i], points[i - 1]
        if (y1 > y) != (y2 > y) and x < x1 + (y - y1) * (x2 - x1) / (y2 - y1):
            inside = not inside
    return inside


def segment(x, y, x1, y1, x2, y2):
    """How far a point is from a stroke between two others"""
    dx, dy = x2 - x1, y2 - y1
    along = max(0.0, min(1.0, ((x - x1) * dx + (y - y1) * dy) / (dx * dx + dy * dy)))
    return math.hypot(x - x1 - along * dx, y - y1 - along * dy)


def cover(x, y):
    """A raised tile that fills its square, in a square from -1 to 1 with y pointing down"""
    reach = 1 - EDGE
    if abs(x) <= reach and abs(y) <= reach:
        # A little lighter towards the light
        return mix(FACE, LIT, 0.1 * (-(x + y) / (2 * reach) + 1) / 2), 1.0
    # The edges meet in mitres: above the diagonal that runs from the bottom left to the top
    # right they face the light
    lit = x + y < 0
    depth = (1 - max(abs(x), abs(y))) / EDGE
    return mix(LIT if lit else SHADED, FACE, 0.35 * depth), 1.0


def flag(x, y):
    """A flag on a pole with a foot, the cloth flying to the left"""
    cloth = [(0.16, -0.72), (0.16, 0.02), (-0.62, -0.35)]
    if in_polygon(x, y, cloth):
        return mix(CLOTH, CLOTH_DARK, max(0.0, min(1.0, (y + 0.72) / 0.74)) * 0.8), 1.0
    if 0.1 <= x <= 0.26 and -0.74 <= y <= 0.5:
        return POLE, 1.0
    if in_polygon(x, y, [(-0.5, 0.74), (0.62, 0.74), (0.44, 0.44), (-0.14, 0.44)]):
        return FOOT, 1.0
    # Dark round all of it, so that it stands off a tile of any colour
    near = min(
        segment(x, y, 0.18, -0.72, 0.18, 0.5),
        segment(x, y, 0.16, -0.72, -0.62, -0.35),
        segment(x, y, 0.16, 0.02, -0.62, -0.35),
        segment(x, y, -0.4, 0.6, 0.5, 0.6) - 0.1,
    )
    return (0, 0, 0), max(0.0, min(0.5, 0.5 * (1 - (near - 0.08) / 0.1)))


def mine(x, y):
    """An iron ball with spikes all round, the light on it from the top left"""
    distance = math.hypot(x, y)
    spike = min(segment(x, y, 0, 0, 0.8 * math.cos(math.pi * i / 4), 0.8 * math.sin(math.pi * i / 4)) for i in range(8))
    # The ones along the axes are a little longer than the ones between
    long = min(segment(x, y, -0.86, 0, 0.86, 0), segment(x, y, 0, -0.86, 0, 0.86))
    if distance <= 0.56:
        shine = max(0.0, 1 - math.hypot(x + 0.2, y + 0.2) / 0.3)
        return mix(mix(IRON, (0, 0, 0), 0.4 * distance / 0.56), IRON_LIT, shine**1.5), 1.0
    if spike <= 0.1 or long <= 0.1:
        return IRON, 1.0
    # A light rim, it lies on a dark square
    near = min(distance - 0.56, spike - 0.1, long - 0.1)
    return IRON_LIT, max(0.0, 0.75 * (1 - near / 0.09)) if near < 0.09 else 0.0


def wrong(x, y):
    """A flag that was planted where there was nothing, crossed out"""
    stroke = min(segment(x, y, -0.66, -0.66, 0.66, 0.66), segment(x, y, -0.66, 0.66, 0.66, -0.66))
    if stroke <= 0.13:
        return mix(CROSS, (255, 255, 255), 0.25 * (1 - stroke / 0.13)), 1.0
    if stroke <= 0.2:
        return (40, 0, 0), 0.8
    color, alpha = flag(x, y)
    return mix(color, (60, 60, 60), 0.45), alpha * 0.8


def one(x, y):
    """The figure 1, as it is written on a square next to a single mine"""
    stem = abs(x - 0.05) <= 0.16 and -0.6 <= y <= 0.6
    foot = abs(x - 0.05) <= 0.42 and 0.38 <= y <= 0.6
    nose = in_polygon(x, y, [(-0.11, -0.6), (-0.11, -0.22), (-0.42, -0.14), (-0.42, -0.4)])
    return stem or foot or nose


def over(top, bottom):
    """One thing painted on another that is solid"""
    color, alpha = top
    return mix(bottom[0], color, alpha), 1.0


def icon(x, y):
    """Four squares of a field: two still covered, one of them flagged, a number and a mine"""
    column, row = x >= 0, y >= 0
    # Each square in a picture of its own from -1 to 1
    u, v = (x - (0.5 if column else -0.5)) * 2, (y - (0.5 if row else -0.5)) * 2
    if column == row:
        tile = cover(u, v)
        return over(flag(u * 1.15, v * 1.15), tile) if not column else tile
    floor = (LINES if max(abs(u), abs(v)) > 0.94 else SUNK), 1.0
    if column:
        return over(mine(u * 1.2, v * 1.2), floor)
    return (ONE, 1.0) if one(u * 1.1, v * 1.1) else floor


def render(size, paint):
    """Rows of (r, g, b, a). `paint` gets a point in a square from -1 to 1, y pointing down"""
    rows = []
    for py in range(size):
        row = []
        for px in range(size):
            red = green = blue = alpha = 0.0
            for i in range(SAMPLES):
                for j in range(SAMPLES):
                    x, y = (px + (i + 0.5) / SAMPLES) / size, (py + (j + 0.5) / SAMPLES) / size
                    color, a = paint(x * 2 - 1, y * 2 - 1)
                    red, green, blue, alpha = red + color[0] * a, green + color[1] * a, blue + color[2] * a, alpha + a
            if alpha > 0:
                row.append((round(red / alpha), round(green / alpha), round(blue / alpha), round(255 * alpha / SAMPLES**2)))
            else:
                row.append((0, 0, 0, 0))
        rows.append(row)
    return rows


def write(path, rows, preview):
    width, height = len(rows[0]), len(rows)
    path.parent.mkdir(parents=True, exist_ok=True)
    # TGA rows run bottom to top
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, width, height, 32, 8)
    path.write_bytes(header + b"".join(bytes((b, g, r, a)) for row in reversed(rows) for (r, g, b, a) in row))
    if preview:
        raw = b"".join(b"\x00" + b"".join(bytes(pixel) for pixel in row) for row in rows)

        def chunk(kind, body):
            return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

        png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        png += chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
        preview.mkdir(parents=True, exist_ok=True)
        (preview / (path.parent.name + "_" + path.stem + ".png")).write_bytes(png)


target = Path(sys.argv[1])
preview = Path(sys.argv[2]) if len(sys.argv) > 2 else None
write(target / "Minesweeper" / "cover.tga", render(COVER_SIZE, cover), preview)
write(target / "Icons" / "minesweeper.tga", render(64, icon), preview)
for size in SIZES:
    for name, paint in (("flag", flag), ("mine", mine), ("wrong", wrong)):
        write(target / "Minesweeper" / str(size) / (name + ".tga"), render(size, paint), preview)
