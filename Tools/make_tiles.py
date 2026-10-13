#!/usr/bin/env python3
"""Draws what games with lettered tiles are played with (GUI/Tiles.lua), and their icon.

    python3 Tools/make_tiles.py Images

Writes the blank Images/Tiles/<size>/tile.tga that letters are written on, at the sizes a board
picks from, and next to them the white pictures that get tinted: glow.tga that lies around a
tile, cell.tga for a square of the board, star.tga for its middle and arrow.tga for which way a
word is being typed. Also Images/Icons/words.tga. Only the standard library is used. Pass a
second folder to also get PNG copies there, which are easier to look at than TGA.
"""
import math
import struct
import sys
import zlib
from pathlib import Path

SIZES = (64, 128, 256)
SAMPLES = 4
# Half the side of a tile and how round its corners are, in a picture from -1 to 1
TILE, CORNER = 0.88, 0.2
BONE = (240, 225, 190)
SLATE = (34, 38, 48)
GOLD = (255, 209, 70)
INK = (58, 34, 14)
# The strokes of a W, in a box from -1 to 1 with y pointing down
W = [(-0.52, -0.4), (-0.27, 0.42), (0, -0.12), (0.27, 0.42), (0.52, -0.4)]


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


def in_polygon(x, y, points):
    inside = False
    for i in range(len(points)):
        (x1, y1), (x2, y2) = points[i], points[i - 1]
        if (y1 > y) != (y2 > y) and x < x1 + (y - y1) * (x2 - x1) / (y2 - y1):
            inside = not inside
    return inside


def tile(x, y):
    """A tile of bone, lit from the top left, with a little shadow under it"""
    distance = rounded(x, y, TILE, CORNER)
    if distance > 0:
        shadow = rounded(x - 0.03, y - 0.07, TILE, CORNER)
        return (0, 0, 0), 0.45 * clamp(1 - shadow / 0.1) if shadow > 0 else 0.45
    # Paler towards the top, and a rim that catches the light on two sides and loses it on the others
    color = mix(BONE, (255, 250, 232), 0.5 * clamp(0.5 - y / 2) ** 2)
    color = mix(color, (196, 170, 120), 0.35 * clamp(0.5 + y / 2) ** 3)
    rim = clamp(1 + distance / 0.14)
    if rim > 0:
        light = (-x - y) / math.sqrt(2)
        color = mix(color, (255, 255, 250) if light > 0 else (120, 88, 48), rim**1.5 * 0.75 * min(1, abs(light) * 1.6))
    if distance > -0.03:
        color = mix(color, (84, 58, 30), 0.55)
    return color, 1.0


def glow(x, y):
    """Light around a tile, in a picture that is drawn half as large again as the tile"""
    distance = rounded(x * 1.5, y * 1.5, TILE, CORNER)
    if distance <= 0:
        return (255, 255, 255), 0.55 + 0.45 * clamp(1 + distance / 0.25)
    return (255, 255, 255), clamp(1 - distance / 0.5) ** 2


def cell(x, y):
    """A square of the board: dished, darker towards its edges"""
    distance = rounded(x, y, 0.94, 0.12)
    if distance > 0:
        return (0, 0, 0), 0.0
    depth = clamp(-distance / 0.5)
    light = (-x - y) / 2
    shade = 0.74 + 0.26 * depth**0.6 + 0.07 * light * (1 - depth)
    value = round(255 * clamp(shade))
    return (value, value, value), 1.0


def star(x, y):
    """A star of four points"""
    points = []
    for k in range(8):
        reach = 0.92 if k % 2 == 0 else 0.36
        points.append((reach * math.cos(math.radians(45 * k)), reach * math.sin(math.radians(45 * k))))
    return (255, 255, 255), 1.0 if in_polygon(x, y, points) else 0.0


def arrow(x, y):
    """Points right"""
    return (255, 255, 255), 1.0 if in_polygon(x, y, [(-0.55, -0.3), (0.05, -0.3), (0.05, -0.7), (0.75, 0), (0.05, 0.7), (0.05, 0.3), (-0.55, 0.3)]) else 0.0


def icon(x, y):
    """A tile with a W on it and a star in its corner, on slate"""
    color, alpha = tile(x / 0.92, y / 0.92)
    color = mix(SLATE, color, alpha) if alpha < 1 else color
    if alpha >= 1:
        stroke = min(to_segment(x, y - 0.02, W[i], W[i + 1]) for i in range(len(W) - 1))
        color = mix(color, INK, clamp((0.105 - stroke) / 0.02))
    if star((x - 0.55) / 0.36, (y - 0.55) / 0.36)[1] > 0:
        color = GOLD
    return color, 1.0


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


target = Path(sys.argv[1])
preview = Path(sys.argv[2]) if len(sys.argv) > 2 else None
for size in SIZES:
    write(target / "Tiles" / str(size) / "tile.tga", render(size, tile), preview)
for name, paint, size in (("glow", glow, 128), ("cell", cell, 64), ("star", star, 64), ("arrow", arrow, 64)):
    write(target / "Tiles" / (name + ".tga"), render(size, paint), preview)
write(target / "Icons" / "words.tga", render(64, icon), preview)
