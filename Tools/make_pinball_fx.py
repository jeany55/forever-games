#!/usr/bin/env python3
"""Draws the pictures of what the class spells look like on the pinball table, and the sparkle
round them, for Tools/PinballBench:

    python3 Tools/make_pinball_fx.py <folder>

Writes <folder>/<name>.tga, 32 bit with sides a power of two, white or tinted on clear, for the
bench to colour and to lay over the table, most of them added to what is under them:
  glow     a soft round light
  ring     a thin bright ring, for a wave going out over the playfield
  nova     a ring of ice with spikes of frost out of it: Frost Nova going off
  frost    frost creeping in from the edges, clear in the middle, laid over the whole table
  ice      a block of ice, laid over a ball Frost Nova holds
  flake    a snowflake
  shard    a splinter of ice, flying off a block that breaks
  shield   a knight's shield, the Shield Wall over the post between the flippers
  spark    a four-pointed spark
Nothing is made again if every picture is newer than this file. Only the standard library is used.
"""
import math
import random
import struct
import sys
from pathlib import Path

CHANCE = random.Random(11)


def write_tga(path, size, pixel):
    """pixel(u, v) -> r, g, b, a, each 0-1, u and v from 0 to 1 across and down, sampled at the
    middle of each pixel"""
    w, h = size
    rows = []
    for y in range(h - 1, -1, -1):
        row = bytearray()
        for x in range(w):
            r, g, b, a = pixel((x + 0.5) / w, (y + 0.5) / h)
            row += bytes((clip(b), clip(g), clip(r), clip(a)))
        rows.append(bytes(row))
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 8)
    Path(path).write_bytes(header + b"".join(rows))


def clip(value):
    return max(0, min(255, int(value * 255 + 0.5)))


def smooth(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def segment_distance(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - ax - dx * t, py - ay - dy * t)


GRID = [[CHANCE.random() for _ in range(64)] for _ in range(64)]


def value_noise(x, y):
    x0, y0 = math.floor(x), math.floor(y)
    fx, fy = x - x0, y - y0
    fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)

    def at(i, j):
        return GRID[j % 64][i % 64]

    top = at(x0, y0) + (at(x0 + 1, y0) - at(x0, y0)) * fx
    bottom = at(x0, y0 + 1) + (at(x0 + 1, y0 + 1) - at(x0, y0 + 1)) * fx
    return top + (bottom - top) * fy


def fbm(x, y, octaves=4):
    total, amount, scale = 0.0, 0.5, 1.0
    for _ in range(octaves):
        total += value_noise(x * scale, y * scale) * amount
        amount *= 0.5
        scale *= 2.03
    return total


def glow(u, v):
    d = math.hypot(u - 0.5, v - 0.5) * 2
    a = math.exp(-d * d * 4.5) * smooth(1.0, 0.85, d)
    return 1, 1, 1, a


def ring(u, v):
    d = math.hypot(u - 0.5, v - 0.5) * 2
    core = math.exp(-((d - 0.84) / 0.035) ** 2)
    halo = math.exp(-((d - 0.84) / 0.12) ** 2) * 0.45
    return 1, 1, 1, min(1.0, core + halo) * smooth(1.0, 0.97, d)


SPIKES = [(CHANCE.uniform(0, 2 * math.pi), CHANCE.uniform(0.08, 0.2), CHANCE.uniform(0.025, 0.05)) for _ in range(28)]


def nova(u, v):
    x, y = u - 0.5, v - 0.5
    d = math.hypot(x, y) * 2
    angle = math.atan2(y, x)
    wobble = 0.03 * math.sin(angle * 9) + 0.02 * math.sin(angle * 23 + 1.3)
    core = math.exp(-((d - 0.68 - wobble) / 0.05) ** 2)
    spike = 0.0
    for at, length, width in SPIKES:
        off = (angle - at + math.pi) % (2 * math.pi) - math.pi
        along = (d - 0.66) / length
        if 0 < along < 1:
            spike = max(spike, smooth(width * (1 - along), 0, abs(off) * d) * (1 - along * 0.6))
    inner = smooth(0.2, 0.68, d) * smooth(0.75, 0.6, d) * 0.25
    a = min(1.0, core + spike + inner) * smooth(1.0, 0.95, d)
    # White at the heart of the ice, blue at its edges
    t = min(1.0, core + spike)
    return 0.55 + 0.45 * t, 0.8 + 0.2 * t, 1, a


def frost(u, v):
    edge = min(u, v, 1 - u, 1 - v)
    # Further in along the corners, ragged with crystals
    reach = 0.1 + 0.09 * fbm(u * 7, v * 7) + 0.05 * (1 - abs(math.cos(u * math.pi * 2)) * abs(math.cos(v * math.pi * 2)))
    crystals = fbm(u * 26 + 3.1, v * 26 + 7.7, 3)
    amount = smooth(reach, reach * 0.25, edge)
    streak = abs(math.sin((u * 31 + v * 17) + fbm(u * 5, v * 5) * 9))
    a = amount * (0.55 + 0.45 * crystals) * (0.75 + 0.25 * streak)
    return 0.78, 0.9, 1, min(1.0, a * 1.2)


def ice(u, v):
    x, y = (u - 0.5) * 2, (v - 0.5) * 2
    # A block with rounded corners, a little taller than wide, as a cube seen from above the table
    p = 5
    shape = (abs(x) ** p + abs(y * 0.92) ** p) ** (1 / p)
    inside = smooth(0.98, 0.9, shape)
    rim = math.exp(-((shape - 0.9) / 0.06) ** 2)
    facet = max(math.exp(-(abs(x + y) / 0.035) ** 2), math.exp(-(abs(x - y * 0.4 - 0.2) / 0.03) ** 2) * 0.6)
    shine = math.exp(-(((x + 0.42) / 0.22) ** 2 + ((y + 0.48) / 0.12) ** 2))
    cloud = fbm(u * 6, v * 6)
    a = inside * (0.38 + 0.3 * cloud) + rim * 0.8 + facet * inside * 0.35 + shine * inside * 0.9
    t = min(1.0, rim + shine)
    return 0.7 + 0.3 * t, 0.88 + 0.12 * t, 1, min(1.0, a)


def flake(u, v):
    x, y = (u - 0.5) * 2, (v - 0.5) * 2
    best = 9.0
    for k in range(6):
        a = math.pi * k / 3
        ca, sa = math.cos(a), math.sin(a)
        best = min(best, segment_distance(x, y, 0, 0, 0.85 * ca, 0.85 * sa))
        for at, length in ((0.45, 0.28), (0.68, 0.18)):
            bx, by = at * ca, at * sa
            for turn in (-0.6, 0.6):
                ta = a + turn
                best = min(best, segment_distance(x, y, bx, by, bx + length * math.cos(ta), by + length * math.sin(ta)))
    line = smooth(0.09, 0.03, best)
    halo = math.exp(-(best / 0.16) ** 2) * 0.35
    return 1, 1, 1, min(1.0, line + halo)


def shard(u, v):
    x, y = (u - 0.5) * 2, (v - 0.5) * 2
    d = abs(x) / 0.35 + abs(y) / 0.95
    a = smooth(1.0, 0.7, d)
    return 0.85, 0.95, 1, a


def shield_distance(x, y):
    """How far a point is outside a heater shield, below zero inside: flat across the top, straight
    down the sides, then curving in to a point"""
    top, side, waist, point = -0.78, 0.66, 0.05, 0.92
    if y < waist:
        return max(top - y, abs(x) - side)
    # Below its waist it narrows along a quarter of an ellipse to the point
    t = (y - waist) / (point - waist)
    width = side * math.sqrt(max(0.0, 1 - t * t))
    return max(abs(x) - width, y - point)


def shield(u, v):
    x, y = (u - 0.5) * 2.2, (v - 0.5) * 2.2
    d = shield_distance(x, y)
    rim = math.exp(-((d + 0.05) / 0.045) ** 2)
    inside = smooth(0.0, -0.03, d)
    inner_rim = math.exp(-((d + 0.2) / 0.025) ** 2) * 0.7
    boss = math.exp(-((math.hypot(x, y + 0.08) - 0.16) / 0.035) ** 2) + smooth(0.12, 0.06, math.hypot(x, y + 0.08)) * 0.8
    cross = (smooth(0.05, 0.02, abs(x)) * smooth(0.0, -0.25, d) + smooth(0.05, 0.02, abs(y + 0.08)) * smooth(0.0, -0.25, d)) * 0.35
    halo = math.exp(-(max(0.0, d) / 0.12) ** 2) * 0.35 * (1 - inside)
    a = min(1.0, rim + inner_rim + boss * inside + cross + inside * 0.16 + halo)
    t = min(1.0, rim + boss)
    return 1, 0.75 + 0.25 * t, 0.3 + 0.5 * t, a


def spark(u, v):
    x, y = abs(u - 0.5) * 2, abs(v - 0.5) * 2
    star = max(smooth(0.12, 0.0, x * (0.3 + y)), smooth(0.12, 0.0, y * (0.3 + x)))
    core = math.exp(-(x * x + y * y) * 30)
    return 1, 1, 1, min(1.0, star * smooth(1.0, 0.6, max(x, y)) + core)


PICTURES = {
    "glow": ((64, 64), glow),
    "ring": ((256, 256), ring),
    "nova": ((256, 256), nova),
    "frost": ((256, 512), frost),
    "ice": ((128, 128), ice),
    "flake": ((64, 64), flake),
    "shard": ((32, 64), shard),
    "shield": ((256, 256), shield),
    "spark": ((64, 64), spark),
}


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    folder = Path(sys.argv[1])
    folder.mkdir(parents=True, exist_ok=True)
    me = Path(__file__).stat().st_mtime
    if all((folder / f"{name}.tga").exists() and (folder / f"{name}.tga").stat().st_mtime > me for name in PICTURES):
        return
    for name, (size, pixel) in PICTURES.items():
        write_tga(folder / f"{name}.tga", size, pixel)
        print(folder / f"{name}.tga")


if __name__ == "__main__":
    main()
