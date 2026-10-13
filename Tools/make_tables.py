#!/usr/bin/env python3
"""Draws what the games that aren't played on a plain grid are played on, and with.

    python3 Tools/make_tables.py Images

Writes the Images/Board/backgammon.tga table and the Images/Icons/backgammon.tga that goes with
it, and the noughts and crosses of Tic Tac Toe as Images/Marks/<size>/<x or o>.tga at the sizes
the board picks from. Only the standard library is used. Pass a second folder to also get PNG
copies there, which are easier to look at than TGA.
"""
import math
import struct
import sys
import zlib
from pathlib import Path

SIZES = (64, 128, 256)
SAMPLES = 4

# The backgammon table, measured in checkers. Games/Backgammon.lua lays the checkers out by the
# same numbers
EDGE = 0.45
HOME = 6
BAR_WIDTH = 1.1
TRAY_GAP, TRAY_WIDTH = 0.3, 1.3
STACK = 5
MIDDLE = 1.8
WIDTH = EDGE + HOME + BAR_WIDTH + HOME + TRAY_GAP + TRAY_WIDTH + EDGE
HEIGHT = EDGE + STACK + MIDDLE + STACK + EDGE
# How far a point reaches into the table, and how wide it is where it starts
POINT_LENGTH, POINT_WIDTH = STACK + 0.15, 0.9

WOOD, WOOD_DARK = (150, 104, 62), (88, 56, 30)
FELT = (30, 96, 62)
POINT_COLORS = ((214, 190, 142), (118, 52, 40))

# The marks of Tic Tac Toe: colour, and how thick the stroke is in a square from -1 to 1
CROSS, NOUGHT = (84, 178, 246), (250, 146, 62)
STROKE = 0.17


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def grain(x, y):
    """Wood, with the grain running across"""
    waves = math.sin(y * 17 + 3 * math.sin(x * 1.7)) * 0.5 + math.sin(y * 41 + x * 3) * 0.5
    return mix(WOOD, WOOD_DARK, 0.2 + 0.12 * waves)


def table(u, v):
    """The backgammon table at a point from 0 to 1 across and down"""
    x, y = u * WIDTH, v * HEIGHT
    fields = ((EDGE, EDGE + HOME), (EDGE + HOME + BAR_WIDTH, EDGE + 2 * HOME + BAR_WIDTH))
    tray = (WIDTH - EDGE - TRAY_WIDTH, WIDTH - EDGE)

    inside = None
    for left, right in fields + (tray,):
        if left <= x <= right and EDGE <= y <= HEIGHT - EDGE:
            inside = (left, right)
    if not inside:
        color = grain(x, y)
        # The rim catches the light from the top left
        rim = min(x, y, WIDTH - x, HEIGHT - y)
        if rim < 0.08:
            color = mix(color, (255, 236, 200) if min(x, y) < 0.08 else (0, 0, 0), 0.3)
        return color, 1.0

    left, right = inside
    color = FELT
    if inside == tray:
        color = mix(FELT, (0, 0, 0), 0.35)
        # Each player's checkers come off into their own half
        if abs(y - HEIGHT / 2) < 0.12:
            return grain(x, y), 1.0
    else:
        column = math.floor(x - left)
        centre = left + column + 0.5
        for top in (True, False):
            depth = (y - EDGE) if top else (HEIGHT - EDGE - y)
            if 0 <= depth <= POINT_LENGTH:
                reach = POINT_WIDTH / 2 * (1 - depth / POINT_LENGTH)
                if abs(x - centre) <= reach:
                    shade = POINT_COLORS[(column + (0 if top else 1)) % 2]
                    # A thin dark line around each point lifts it off the felt
                    color = mix(shade, (0, 0, 0), 0.35) if abs(x - centre) > reach - 0.035 else shade

    # The playing surface lies a little below the wood around it
    shadow = min(x - left, y - EDGE)
    if shadow < 0.14:
        color = mix(color, (0, 0, 0), 0.45 * (1 - shadow / 0.14))
    return color, 1.0


def checker(x, y, base):
    """A flat round piece for the icon, in a square from -1 to 1"""
    distance = math.hypot(x, y)
    if distance > 1:
        return None
    return mix(base, (0, 0, 0), 0.45) if distance > 0.84 else mix(base, (255, 255, 255), 0.12 * (1 - distance))


def icon(x, y):
    """Two points of the table with a checker on each"""
    for cx, cy, base in ((-0.42, 0.5, (236, 232, 220)), (0.42, -0.5, (200, 40, 36))):
        color = checker((x - cx) / 0.4, (y - cy) / 0.4, base)
        if color:
            return color, 1.0
    for centre, top, shade in ((-0.42, True, POINT_COLORS[1]), (0.42, False, POINT_COLORS[0])):
        depth = (y + 1) if top else (1 - y)
        if abs(x - centre) <= 0.4 * (1 - depth / 1.7):
            return shade, 1.0
    return mix(FELT, (0, 0, 0), 0.2 * abs(x)), 1.0


def stroke(distance, color):
    """A rounded stroke seen from above: lighter along its middle, clear outside"""
    if distance > STROKE:
        # A soft shadow under it
        return (0, 0, 0), max(0.0, 0.3 * (1 - (distance - STROKE) / 0.06))
    return mix(color, (255, 255, 255), 0.28 * (1 - distance / STROKE) ** 2), 1.0


def cross(x, y):
    # Both strokes at once: turned an eighth, the nearer of the two is along an axis
    along, away = (x + y) / math.sqrt(2), (x - y) / math.sqrt(2)
    reach = 0.74
    distances = []
    for a, b in ((along, away), (away, along)):
        distances.append(math.hypot(max(0.0, abs(a) - reach), b))
    return stroke(min(distances), CROSS)


def nought(x, y):
    return stroke(abs(math.hypot(x, y) - 0.6), NOUGHT)


def render(width, height, paint, square=False):
    """Rows of (r, g, b, a). `paint` gets a point from 0 to 1 across and down, or in a square from -1 to 1"""
    rows = []
    for py in range(height):
        row = []
        for px in range(width):
            red = green = blue = alpha = 0.0
            for i in range(SAMPLES):
                for j in range(SAMPLES):
                    x, y = (px + (i + 0.5) / SAMPLES) / width, (py + (j + 0.5) / SAMPLES) / height
                    color, a = paint(x * 2 - 1, y * 2 - 1) if square else paint(x, y)
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
# The table is wider than it is high and the texture isn't: the game draws it at its own shape
write(target / "Board" / "backgammon.tga", render(512, 512, table), preview)
write(target / "Icons" / "backgammon.tga", render(64, 64, icon, square=True), preview)
for size in SIZES:
    write(target / "Marks" / str(size) / "x.tga", render(size, size, cross, square=True), preview)
    write(target / "Marks" / str(size) / "o.tga", render(size, size, nought, square=True), preview)
