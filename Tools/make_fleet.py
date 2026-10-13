#!/usr/bin/env python3
"""Draws what Battleship is played on, and with.

    python3 Tools/make_fleet.py Images

Writes the sea as Images/Board/sea.tga with the light that plays over it as
Images/Board/glints.tga, the five ships seen from above as Images/Fleet/<size>/<name>.tga, the
pegs for a hit and a miss as Images/Marks/<size>/<hit or miss>.tga and Images/Icons/battleship.tga.
Only the standard library is used. Pass a second folder to also get PNG copies there, which are
easier to look at than TGA.

A ship lies with its bow to the right in a texture four times as wide as high, whatever its
length: the game draws it back at its own shape, and turned a quarter to stand up. <size> is the
height, half of what the pegs come in, since a square of a ten by ten board is small.
"""
import math
import struct
import sys
import zlib
from pathlib import Path

PEG_SIZES = (64, 128, 256)
SHIP_SIZES = (32, 64, 128)
SAMPLES = 4
# The sea is all soft shapes but for its grid, fewer samples will do
SEA_SAMPLES = 3
GRID = 10

DEEP, SHALLOW = (5, 30, 70), (16, 96, 138)
LIGHT = (120, 220, 215)
GRID_LINE = (170, 226, 244)
STEEL, STEEL_DARK, STEEL_LIGHT = (132, 144, 156), (52, 60, 70), (196, 206, 214)
DECK = (86, 92, 100)
HULL_BLACK = (62, 74, 88)
FOAM = (220, 240, 250)

# The ships: how long in squares, half the width of the hull, where along it the bow starts to
# narrow and how sharply, and how round the stern is
SHIPS = {
    "carrier": dict(length=5, beam=0.36, bow=0.8, point=1.5, stern=0.05),
    "battleship": dict(length=4, beam=0.31, bow=0.62, point=1.7, stern=0.1),
    "cruiser": dict(length=3, beam=0.27, bow=0.58, point=1.6, stern=0.12),
    "submarine": dict(length=3, beam=0.22, bow=0.7, point=2.2, stern=0.34),
    "destroyer": dict(length=2, beam=0.24, bow=0.5, point=1.5, stern=0.14),
}
# How far a ship stays from the ends of its squares
ENDS = 0.1


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def clamp(value):
    return max(0.0, min(1.0, value))


def caustic(x, y, time):
    """The net of light the sun throws through waves, from 0 to 1. After the water turbulence
    shader by joltz0r"""
    px, py = x - 250, y - 250
    ix, iy = px, py
    total = 1.0
    for n in range(5):
        t = time * (1 - 3.5 / (n + 1))
        ix, iy = px + math.cos(t - ix) + math.sin(t + iy), py + math.sin(t - iy) + math.cos(t + ix)
        across, down = math.sin(ix + t) or 1e-9, math.cos(iy + t) or 1e-9
        total += 1 / math.hypot(px * 0.005 / across, py * 0.005 / down)
    return clamp(abs(1.17 - (total / 5) ** 1.4) ** 8)


def sea(u, v):
    """The sea at a point from 0 to 1 across and down: deep water lit from the top left, with the
    grid the game is played on drawn into it"""
    swell = 0.5 + 0.25 * math.sin(u * 5.1 + 2 * math.sin(v * 3.3)) + 0.25 * math.sin(v * 6.7 - u * 2.9)
    depth = clamp(0.62 - 0.38 * (u + v) / 2 + 0.3 * (swell - 0.5))
    color = mix(DEEP, SHALLOW, depth)
    color = mix(color, LIGHT, 0.42 * caustic(u * 9.5, v * 9.5, 0.6))
    # A second, finer net lying deeper
    color = mix(color, LIGHT, 0.14 * caustic(u * 21 + 3, v * 21 + 7, 2.3))

    # Darker towards the edges, as if the light fell on the middle
    edge = min(u, v, 1 - u, 1 - v)
    color = mix(color, (0, 8, 24), 0.4 * (1 - clamp(edge / 0.12)) ** 2)

    for along in (u, v):
        line = abs(along * GRID - round(along * GRID))
        frame = round(along * GRID) in (0, GRID)
        width = 0.05 if frame else 0.022
        if line < width:
            color = mix(color, GRID_LINE, 0.55 if frame else 0.3)
    return color, 1.0


def glints(u, v):
    """Light to add over the sea. It fades in and out there, which makes the water move"""
    strength = caustic(u * 9.5 + 1.7, v * 9.5 + 0.9, 1.9)
    edge = min(u, v, 1 - u, 1 - v)
    return (190, 240, 245), 0.5 * strength * clamp(edge / 0.06)


def half_width(kind, along):
    """Half the width of a hull at a point from 0 at the stern to 1 at the tip of the bow"""
    if along < 0 or along > 1:
        return -1.0
    width = kind["beam"]
    if along < kind["stern"]:
        width *= math.sqrt(1 - (1 - along / kind["stern"]) ** 2)
    if along > kind["bow"]:
        width *= 1 - ((along - kind["bow"]) / (1 - kind["bow"])) ** kind["point"]
    return width


def box(x, y, left, right, half):
    return left <= x <= right and abs(y) <= half


def turret(x, y, centre, radius, forward):
    """A gun turret seen from above with its barrels, None outside it"""
    barrel = 2.3 * radius
    reach = (x - centre) * (1 if forward else -1)
    for offset in (-0.4 * radius, 0.4 * radius):
        if 0 <= reach <= barrel and abs(y - offset) <= 0.13 * radius:
            return STEEL_DARK
    distance = math.hypot(x - centre, y)
    if distance <= radius:
        return mix(STEEL_LIGHT, STEEL, distance / radius) if distance < 0.8 * radius else STEEL_DARK
    return None


def deck(name, x, y, length):
    """What stands on the deck of a ship at a point, x in squares from the stern and y from the
    middle line. None for bare deck"""
    if name == "carrier":
        # A flight deck with its lines, and the island to one side
        if box(x, y, 2.75, 3.45, 0.33) and y > 0.17:
            return STEEL_LIGHT if box(x, y - 0.25, 2.85, 3.35, 0.045) else STEEL
        if abs(y) < 0.018 and 0.35 < x < 4.3 and int(x * 5) % 2 == 0:
            return (232, 236, 228)
        if abs(abs(y + 0.03) - 0.2) < 0.012 and 0.3 < x < 3.9:
            return (214, 196, 110)
        return DECK
    if name == "battleship":
        for centre, radius, forward in ((0.62, 0.15, False), (1.05, 0.13, False), (2.5, 0.14, True), (2.95, 0.15, True)):
            color = turret(x, y, centre, radius, forward)
            if color:
                return color
        if box(x, y, 1.35, 2.2, 0.17):
            return STEEL_LIGHT if box(x, y, 1.55, 2.0, 0.09) else STEEL_DARK
    if name == "cruiser":
        for centre, radius, forward in ((0.6, 0.13, False), (2.05, 0.13, True)):
            color = turret(x, y, centre, radius, forward)
            if color:
                return color
        if box(x, y, 0.95, 1.7, 0.15):
            return STEEL_LIGHT if box(x, y, 1.1, 1.5, 0.08) else STEEL_DARK
    if name == "submarine":
        # The conning tower, and nothing else to catch the eye
        tower = math.hypot((x - 1.45) / 0.36, y / 0.1)
        if tower <= 1:
            return mix((92, 104, 116), HULL_BLACK, tower**2)
    if name == "destroyer":
        color = turret(x, y, 1.25, 0.11, True)
        if color:
            return color
        if box(x, y, 0.5, 1.0, 0.13):
            return STEEL_LIGHT if box(x, y, 0.6, 0.85, 0.07) else STEEL_DARK
    return None


def ship(name):
    """A painter for one of the ships, bow to the right, over a point from 0 to 1 across and down"""
    kind = SHIPS[name]
    length = kind["length"]
    hull = length - 2 * ENDS

    def paint(u, v):
        x, y = u * length, v - 0.5
        along = (x - ENDS) / hull
        inside = half_width(kind, along) - abs(y)
        if inside < 0:
            # Its shadow on the water, a little down and to the right, and foam along the sides
            shadow = half_width(kind, (x - 0.03 - ENDS) / hull) - abs(y - 0.05)
            if shadow >= 0:
                return (0, 6, 16), 0.42
            return FOAM, 0.32 * clamp(1 + inside / 0.05) ** 2

        base = HULL_BLACK if name == "submarine" else STEEL
        # Rounded across: light along the middle, and more of it on the side the sun is on
        across = y / max(kind["beam"], 1e-9)
        color = mix(base, STEEL_LIGHT, 0.34 * (1 - across * across) - 0.16 * across)
        on_deck = deck(name, x - ENDS, y, hull)
        if on_deck:
            color = on_deck if name != "carrier" or on_deck != DECK else mix(DECK, color, 0.25)
        if inside < 0.035:
            color = mix(color, (16, 22, 30), 0.75)
        return color, 1.0

    return paint


def peg(x, y, base, radius):
    """A round peg in a square from -1 to 1, lit from the top left. None outside it"""
    distance = math.hypot(x, y) / radius
    if distance > 1:
        return None
    shine = max(0.0, 1 - math.hypot(x + 0.3 * radius, y + 0.32 * radius) / (0.6 * radius))
    color = mix(base, (255, 255, 255), 0.6 * shine**2)
    return mix(color, (0, 0, 0), 0.5) if distance > 0.84 else color


def hit(x, y):
    """A red peg with fire around it"""
    color = peg(x, y, (214, 40, 30), 0.4)
    if color:
        return color, 1.0
    distance = math.hypot(x, y)
    # Flames lick further out some ways than others
    reach = 0.74 + 0.16 * math.sin(math.atan2(y, x) * 7 + 1)
    glow = clamp(1 - (distance - 0.38) / (reach - 0.38))
    return mix((255, 96, 20), (255, 224, 110), glow), 0.85 * glow**1.3


def miss(x, y):
    """A white peg, and the ring of the splash around it"""
    color = peg(x, y, (232, 240, 246), 0.26)
    if color:
        return color, 1.0
    distance = math.hypot(x, y)
    shadow = max(0.0, 0.35 * (1 - (math.hypot(x, y - 0.03) - 0.24) / 0.08)) if distance < 0.36 else 0.0
    ring = clamp(1 - abs(distance - 0.56) / 0.07)
    return ((0, 0, 0), shadow) if shadow > 0.6 * ring else (FOAM, 0.6 * ring)


def icon(x, y):
    """A ship at sea, a shot that went wide and one that didn't"""
    u, v = (x + 1) / 2, (y + 1) / 2
    color, _ = sea(u * 0.3 + 0.2, v * 0.3 + 0.3)
    paint = ship("battleship")
    # The ship lies across the lower half, four squares long in a picture not two wide
    over, alpha = paint((x + 0.94) / 1.88, (y - 0.38) / 0.47 + 0.5)
    if 0 <= (x + 0.94) / 1.88 <= 1 and abs((y - 0.38) / 0.47) <= 0.5 and alpha > 0:
        color = mix(color, over, alpha)
    for paint, cx, cy, size in ((hit, 0.36, -0.42, 0.52), (miss, -0.5, -0.48, 0.44)):
        over, alpha = paint((x - cx) / size, (y - cy) / size)
        color = mix(color, over, alpha)
    return color, 1.0


def render(width, height, paint, square=False, samples=SAMPLES):
    """Rows of (r, g, b, a). `paint` gets a point from 0 to 1 across and down, or in a square from -1 to 1"""
    rows = []
    for py in range(height):
        row = []
        for px in range(width):
            red = green = blue = alpha = 0.0
            for i in range(samples):
                for j in range(samples):
                    x, y = (px + (i + 0.5) / samples) / width, (py + (j + 0.5) / samples) / height
                    color, a = paint(x * 2 - 1, y * 2 - 1) if square else paint(x, y)
                    red, green, blue, alpha = red + color[0] * a, green + color[1] * a, blue + color[2] * a, alpha + a
            if alpha > 0:
                row.append((round(red / alpha), round(green / alpha), round(blue / alpha), round(255 * alpha / samples**2)))
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
write(target / "Board" / "sea.tga", render(512, 512, sea, samples=SEA_SAMPLES), preview)
write(target / "Board" / "glints.tga", render(256, 256, glints, samples=SEA_SAMPLES), preview)
write(target / "Icons" / "battleship.tga", render(64, 64, icon, square=True), preview)
for size in SHIP_SIZES:
    for name in SHIPS:
        write(target / "Fleet" / str(size) / (name + ".tga"), render(size * 4, size, ship(name)), preview)
for size in PEG_SIZES:
    write(target / "Marks" / str(size) / "hit.tga", render(size, size, hit, square=True), preview)
    write(target / "Marks" / str(size) / "miss.tga", render(size, size, miss, square=True), preview)
