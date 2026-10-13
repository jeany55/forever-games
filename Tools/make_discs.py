#!/usr/bin/env python3
"""Draws the round playing pieces shared by the games played with them, and those games' icons.

    python3 Tools/make_discs.py Images

Writes Images/Discs/<size>/<name>.tga for every colour, and crowned (<name>K) for the colours
checkers is played with, at the sizes the board picks from, the white Images/Board/disc.tga that gets tinted for holes,
the Images/Board/star.tga that Chinese Checkers is played on, and Images/Icons/<game>.tga.
Only the standard library is used. Pass a second folder to also get PNG copies there, which are
easier to look at than TGA.
"""
import math
import struct
import sys
import zlib
from pathlib import Path

SIZES = (64, 128, 256)
SAMPLES = 4
# Radius of a piece as a fraction of its square
RADIUS = 0.42
# Base colour of each piece, and of the crown on it for the ones that can be crowned
COLORS = {
    "red": ((200, 40, 36), (255, 214, 120)),
    "yellow": ((240, 196, 40), None),
    "black": ((44, 44, 48), None),
    "white": ((236, 232, 220), (150, 110, 40)),
    "green": ((52, 160, 70), None),
    "blue": ((48, 104, 210), None),
    "purple": ((146, 72, 190), None),
}
# How far the points of the star board reach, in a picture from -1 to 1
STAR_RADIUS = 0.97
WOOD = (166, 118, 72)
# A crown in a box from -1 to 1, y pointing down
CROWN = [(-0.8, 0.6), (-0.95, -0.45), (-0.45, 0.05), (0, -0.7), (0.45, 0.05), (0.95, -0.45), (0.8, 0.6)]


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def in_polygon(x, y, points):
    inside = False
    for i in range(len(points)):
        (x1, y1), (x2, y2) = points[i], points[i - 1]
        if (y1 > y) != (y2 > y) and x < x1 + (y - y1) * (x2 - x1) / (y2 - y1):
            inside = not inside
    return inside


def disc(x, y, base, crown):
    """Colour and alpha of a piece at a point, in a square from -1 to 1 with y pointing down"""
    distance = math.hypot(x, y) / (2 * RADIUS)
    if distance > 1:
        # A soft shadow, a little below the piece
        shadow = math.hypot(x, y - 0.05) / (2 * RADIUS)
        return (0, 0, 0), max(0.0, 0.35 * (1 - (shadow - 0.9) / 0.2)) if shadow < 1.1 else 0.0

    # Lit from the top left: a rim that catches the light, a dished middle
    light = (-x - y) / (2 * RADIUS) / math.sqrt(2)
    color = base
    if distance > 0.86:
        color = mix(base, (255, 255, 255) if light > 0 else (0, 0, 0), 0.28 * abs(light))
    elif distance > 0.8:
        color = mix(base, (0, 0, 0), 0.3)
    else:
        color = mix(base, (255, 255, 255) if light < 0 else (0, 0, 0), 0.12 * abs(light))
        color = mix(color, (255, 255, 255), 0.1 * (1 - distance / 0.8))
    if distance > 0.97:
        color = mix(color, (0, 0, 0), 0.5)

    if crown and in_polygon(x / (RADIUS * 1.05), y / (RADIUS * 1.05), CROWN):
        color = crown
    return color, 1.0


def hole(x, y):
    return (255, 255, 255), 1.0 if math.hypot(x, y) <= 2 * RADIUS else 0.0


def star_edge(x, y):
    """How far a point is outside a six pointed star with a point straight up, negative inside it"""
    edges = []
    for flip in (1, -1):
        # One of the two triangles the star is made of: inside means on the near side of all three edges
        corners = (math.radians(90 + 120 * k) for k in range(3))
        edges.append(max(-(x * math.cos(a) + flip * y * math.sin(a)) for a in corners) - STAR_RADIUS / 2)
    return min(edges)


def star(x, y):
    """The board Chinese Checkers is played on, without its holes: those are drawn by the game"""
    edge = star_edge(x, y)
    if edge > 0:
        return (0, 0, 0), 0.0
    # Grain running across, a darker rim and a bevel that catches the light from the top left
    grain = math.sin(y * 46 + 3 * math.sin(x * 5)) * 0.5 + math.sin(y * 113 + x * 9) * 0.5
    color = mix(WOOD, (96, 62, 34), 0.12 + 0.1 * grain)
    if edge > -0.035:
        color = mix(color, (60, 36, 18), 0.75)
    elif edge > -0.05:
        color = mix(color, (255, 236, 200) if star_edge(x + 0.01, y + 0.01) < edge else (0, 0, 0), 0.22)
    return color, 1.0


def star_icon(x, y):
    return star(x / 0.98, y / 0.98)[0] if star_edge(x / 0.98, y / 0.98) <= 0 else (28, 34, 52)


def around(names, distance, scale):
    """Pieces at the points of the star, going round from the bottom"""
    turns = (math.radians(90 + 60 * k) for k in range(len(names)))
    return [(name, distance * math.cos(a), distance * math.sin(a), scale) for name, a in zip(names, turns)]


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
                row.append((0, 0, 0, 0))
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


def placed(pieces, background):
    """An icon: pieces as (colour name, x, y, scale) on a background"""

    def paint(x, y):
        for name, cx, cy, scale in reversed(pieces):
            color, alpha = disc((x - cx) / scale, (y - cy) / scale, COLORS[name][0], None)
            if alpha >= 1:
                return color, 1.0
        return background(x, y), 1.0

    return paint


def checks(x, y):
    return (115, 82, 59) if (math.floor(x + 1) + math.floor(y + 1)) % 2 else (219, 204, 168)


def rack(x, y):
    # Empty holes where no piece sits
    near = min(math.hypot(x - cx, y - cy) for cx in (-0.6, 0, 0.6) for cy in (-0.6, 0, 0.6))
    return (16, 30, 66) if near < 0.24 else (38, 84, 168)


ICONS = {
    "connectfour": placed(
        [("red", -0.6, 0.6, 0.3), ("yellow", 0, 0.6, 0.3), ("red", 0.6, 0.6, 0.3), ("yellow", -0.6, 0, 0.3)]
        + [("red", 0, 0, 0.3), ("yellow", 0.6, 0, 0.3), ("red", 0.6, -0.6, 0.3)],
        rack,
    ),
    "reversi": placed(
        [("black", -0.5, -0.5, 0.52), ("white", 0.5, -0.5, 0.52), ("white", -0.5, 0.5, 0.52), ("black", 0.5, 0.5, 0.52)],
        lambda x, y: (20, 80, 44) if min(abs(x), abs(y)) < 0.04 else (36, 122, 66),
    ),
    "checkers": placed([("red", -0.5, 0.5, 0.56), ("white", 0.5, -0.5, 0.56)], checks),
    "chinesecheckers": placed(around(["red", "yellow", "green", "blue", "white", "purple"], 0.62, 0.34), star_icon),
}

target = Path(sys.argv[1])
preview = Path(sys.argv[2]) if len(sys.argv) > 2 else None
for size in SIZES:
    for name, (base, crown) in COLORS.items():
        write(target / "Discs" / str(size) / (name + ".tga"), render(size, lambda x, y: disc(x, y, base, None)), preview)
        if crown:
            write(target / "Discs" / str(size) / (name + "K.tga"), render(size, lambda x, y: disc(x, y, base, crown)), preview)
write(target / "Board" / "disc.tga", render(64, hole), preview)
write(target / "Board" / "star.tga", render(512, star), preview)
for name, paint in ICONS.items():
    write(target / "Icons" / (name + ".tga"), render(64, paint), preview)
