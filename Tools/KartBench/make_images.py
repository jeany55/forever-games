"""Pictures for Kart Bench (Tools/KartBench), which are made rather than kept in the repository.

Writes Tools/KartBench/Images/:
  track1024.tga, track2048.tga, track4096.tga  the same circuit seen from above at three sizes, to
      tell what the client will load and how sharp the road is close up. Off the road the picture
      is see-through, for the grass drawn under it
  grass.tga  a tile of grass that repeats, for when the client's own can't be had
  kart.tga   a kart from behind, pale so that it can be tinted
  sky.tga    a sky with clouds and far hills, a quarter turn of it, that repeats round. Its bottom
      row is HORIZON, which KartBench.lua fades the far ground into

The circuit is the one KartBench.lua drives round: a closed curve around the middle of a square
1024 units across, its distance from the middle r(a) = R (1 + A cos 2a + B sin(3a + C)). Both
work out how far a point is from the middle of the road the same way, so keep them alike. The
courses with hills, which the game will have too, are made by Tools/make_course.py.

Usage: python3 Tools/KartBench/make_images.py [only-this-size, 0 for only the sky]
"""

import math
import struct
import sys
from pathlib import Path

WORLD = 1024
R, A, B, C = 360.0, 0.18, 0.10, 0.6
HALF, CURB, SHOULDER = 26.0, 4.0, 12.0
BAND = HALF + CURB + SHOULDER
CURB_LENGTH, DASH_LENGTH = 8.0, 14.0

OUT = Path(__file__).resolve().parent / "Images"


def radius(a):
    return R * (1 + A * math.cos(2 * a) + B * math.sin(3 * a + C))


def slope(a):
    return R * (-2 * A * math.sin(2 * a) + 3 * B * math.cos(3 * a + C))


def across(x, y):
    """How far (x, y) is from the middle of the road, outwards positive, and how far round it is"""
    dx, dy = x - WORLD / 2, y - WORLD / 2
    a = math.atan2(dy, dx)
    r = radius(a)
    s = slope(a) / r
    return (math.hypot(dx, dy) - r) / math.sqrt(1 + s * s), a


def grain(x, y, salt):
    h = (x * 73856093) ^ (y * 19349663) ^ (salt * 83492791)
    h = (h ^ (h >> 13)) * 1274126177
    return ((h ^ (h >> 16)) & 255) / 255.0


def clamp(v):
    return 0 if v < 0 else 255 if v > 255 else int(v)


def mix(c1, c2, t):
    return tuple(p + (q - p) * t for p, q in zip(c1, c2))


ASPHALT = (62, 62, 68)
LINE = (225, 225, 210)
RED, WHITE = (200, 40, 36), (235, 235, 235)
DIRT = (128, 100, 66)


def road(s, a, px, x, y):
    """The colour and coverage of a point of the circuit"""
    d = abs(s)
    run = a * R
    if d < HALF:
        g = (grain(x, y, 1) - 0.5) * 18
        colour = tuple(v + g for v in ASPHALT)
        # The start line, a band of black and white squares across the road
        if abs(run) < 6:
            square = (math.floor(s / 4) + math.floor(run / 4)) % 2
            colour = WHITE if square else (20, 20, 20)
        elif d < 0.9 and math.floor(run / DASH_LENGTH) % 2 == 0:
            colour = LINE
        elif abs(d - (HALF - 2.5)) < 0.6:
            colour = LINE
        edge = min(1.0, max(0.0, (d - HALF) / px + 0.5))
        if edge > 0:
            colour = mix(colour, RED, edge)
        return colour, 1.0
    if d < HALF + CURB:
        colour = RED if math.floor(run / CURB_LENGTH) % 2 == 0 else WHITE
        g = (grain(x, y, 2) - 0.5) * 10
        return tuple(v + g for v in colour), 1.0
    fade = 1 - (d - HALF - CURB) / SHOULDER
    g = (grain(x, y, 3) - 0.5) * 40
    return tuple(v + g for v in DIRT), max(0.0, fade) ** 1.5


def track(size):
    px = WORLD / size
    step = 8
    margin = step * px * 1.5
    empty = bytes(size * 4)
    rows = []
    for py in range(size):
        y = (py + 0.5) * px
        row = None
        for cx in range(0, size, step):
            s, _ = across((cx + step / 2) * px, y)
            if abs(s) > BAND + margin:
                continue
            if row is None:
                row = bytearray(size * 4)
            for qx in range(cx, min(size, cx + step)):
                s, a = across((qx + 0.5) * px, y)
                if abs(s) >= BAND:
                    continue
                colour, cover = road(s, a, px, qx, py)
                at = qx * 4
                row[at:at + 4] = bytes((clamp(colour[2]), clamp(colour[1]), clamp(colour[0]), clamp(cover * 255)))
        rows.append(bytes(row) if row else empty)
    return rows


def grass(size=256):
    period = 16

    def lattice(i, j):
        return grain(i % period, j % period, 7)

    def smooth(x, y):
        i, j = math.floor(x), math.floor(y)
        fx, fy = x - i, y - j
        fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
        top = lattice(i, j) + (lattice(i + 1, j) - lattice(i, j)) * fx
        bottom = lattice(i, j + 1) + (lattice(i + 1, j + 1) - lattice(i, j + 1)) * fx
        return top + (bottom - top) * fy

    rows = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            n = smooth(x * period / size, y * period / size)
            fine = grain(x, y, 9)
            g = 0.75 + 0.35 * n + 0.15 * (fine - 0.5)
            r, gr, b = 52 * g, 112 * g, 40 * g
            row += bytes((clamp(b), clamp(gr), clamp(r), 255))
        rows.append(bytes(row))
    return rows


def kart(size=64):
    """From behind: a body, two fat back wheels, and the driver's helmet above"""
    def inside_box(x, y, left, top, right, bottom, round_=0):
        if x < left or x > right or y < top or y > bottom:
            return False
        cx = min(max(x, left + round_), right - round_)
        cy = min(max(y, top + round_), bottom - round_)
        return math.hypot(x - cx, y - cy) <= round_

    rows = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            u, v = (x + 0.5) / size, (y + 0.5) / size
            colour, cover = (0, 0, 0), 0
            if inside_box(u, v, 0.04, 0.62, 0.26, 0.98, 0.05) or inside_box(u, v, 0.74, 0.62, 0.96, 0.98, 0.05):
                colour, cover = (34, 34, 38), 255
                if abs(v - 0.8) < 0.012 or abs(v - 0.7) < 0.012:
                    colour = (60, 60, 66)
            elif inside_box(u, v, 0.18, 0.5, 0.82, 0.86, 0.06):
                shine = 1 - abs(u - 0.5)
                colour, cover = tuple(170 + 80 * shine for _ in range(3)), 255
                if abs(v - 0.8) < 0.03 and abs(u - 0.5) < 0.12:
                    colour = (60, 60, 60)
            elif math.hypot(u - 0.5, v - 0.36) < 0.16:
                colour, cover = (230, 230, 230), 255
                if abs(v - 0.36) < 0.04 and abs(u - 0.5) < 0.12:
                    colour = (40, 40, 60)
            elif inside_box(u, v, 0.3, 0.46, 0.7, 0.54):
                colour, cover = (90, 90, 96), 255
            row += bytes((clamp(colour[2]), clamp(colour[1]), clamp(colour[0]), cover))
        rows.append(bytes(row))
    return rows


SKY_TOP, HORIZON = (58, 108, 196), (175, 205, 235)
HILLS_FAR, HILLS_NEAR = (120, 160, 170), (78, 128, 92)


def sky(width=1024, height=256):
    """Clouds from noise that wraps across, thinning towards the horizon, and two ridges of hills"""
    def lattice(i, j, period, salt):
        return grain(i % period, j, salt)

    def smooth(x, y, period, salt):
        i, j = math.floor(x), math.floor(y)
        fx, fy = x - i, y - j
        fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
        top = lattice(i, j, period, salt) + (lattice(i + 1, j, period, salt) - lattice(i, j, period, salt)) * fx
        bottom = lattice(i, j + 1, period, salt) + (lattice(i + 1, j + 1, period, salt) - lattice(i, j + 1, period, salt)) * fx
        return top + (bottom - top) * fy

    def clouds(u, v):
        total, amount, period = 0.0, 0.5, 6
        for octave in range(5):
            total += amount * smooth(u * period, v * period * 0.35, period, 20 + octave)
            amount, period = amount / 2, period * 2
        return total

    def ridge(u, waves, base, rise):
        return base + rise * sum(math.sin(2 * math.pi * (k * u + phase)) / k for k, phase in waves)

    rows = []
    for y in range(height):
        row = bytearray()
        v = y / (height - 1)
        for x in range(width):
            u = x / width
            colour = mix(SKY_TOP, HORIZON, v ** 1.6)
            density = clouds(u, v) - 0.6 + 0.12 * (1 - v)
            cover = min(1.0, max(0.0, density * 3.5)) * (1 - v ** 3)
            if cover > 0:
                lit = mix((255, 255, 255), (205, 215, 232), min(1.0, max(0.0, (density - 0.1) * 2)))
                colour = mix(colour, lit, cover)
            far = ridge(u, ((2, 0.1), (3, 0.6), (5, 0.3), (9, 0.8)), 0.86, 0.035)
            near = ridge(u, ((1, 0.4), (4, 0.15), (7, 0.7), (11, 0.2)), 0.92, 0.03)
            if v > near:
                colour = mix(HILLS_NEAR, HORIZON, ((v - near) / (1 - near)) ** 2)
            elif v > far:
                colour = mix(HILLS_FAR, HORIZON, 0.35 + 0.65 * ((v - far) / (1 - far)) ** 2)
            if y >= height - 2:
                colour = HORIZON
            row += bytes((clamp(colour[2]), clamp(colour[1]), clamp(colour[0]), 255))
        rows.append(bytes(row))
    return rows


def write_tga(path, rows):
    height, width = len(rows), len(rows[0]) // 4
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, width, height, 32, 8)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as out:
        out.write(header)
        # Rows are written bottom up
        for row in reversed(rows):
            out.write(row)
    print(path)


def main():
    only = int(sys.argv[1]) if len(sys.argv) > 1 else None
    for size in (1024, 2048, 4096):
        if only is None or only == size:
            write_tga(OUT / f"track{size}.tga", track(size))
    if only is None:
        write_tga(OUT / "grass.tga", grass())
        write_tga(OUT / "kart.tga", kart())
    if only is None or only == 0:
        write_tga(OUT / "sky.tga", sky())


if __name__ == "__main__":
    main()
