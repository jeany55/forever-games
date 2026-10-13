#!/usr/bin/env python3
"""Draws the white shapes the board toolkit tints to mark squares.

    python3 Tools/make_markers.py Images/Board

dot.tga is a filled circle and ring.tga a circle outline, both anti-aliased. favourite.tga is the
star the new game wizard marks a favourite game with.
"""
import math
import struct
import sys
from pathlib import Path

SIZE = 64
SAMPLES = 4


def coverage(x, y, inside):
    """How much of a pixel a shape covers, from a grid of samples"""
    hits = 0
    for i in range(SAMPLES):
        for j in range(SAMPLES):
            px, py = x + (i + 0.5) / SAMPLES - SIZE / 2, y + (j + 0.5) / SAMPLES - SIZE / 2
            hits += inside(px, py)
    return hits / (SAMPLES * SAMPLES)


def write(path, inside):
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 8)
    body = bytearray()
    for y in range(SIZE):
        for x in range(SIZE):
            body += bytes((255, 255, 255, round(255 * coverage(x, y, inside))))
    path.write_bytes(header + body)


def star(x, y, outer=30, inner=12.5):
    """Whether a point is in a five pointed star around the middle, one point up"""
    corners = []
    for index in range(10):
        angle, radius = math.pi * index / 5, inner if index % 2 else outer
        # Rows are written bottom up, so up is the way y grows
        corners.append((radius * math.sin(angle), radius * math.cos(angle) - 2))
    within = False
    for (x1, y1), (x2, y2) in zip(corners, corners[1:] + corners[:1]):
        if (y1 > y) != (y2 > y) and x < x1 + (y - y1) * (x2 - x1) / (y2 - y1):
            within = not within
    return within


target = Path(sys.argv[1])
target.mkdir(parents=True, exist_ok=True)
write(target / "dot.tga", lambda x, y: math.hypot(x, y) <= 30)
write(target / "ring.tga", lambda x, y: 25 <= math.hypot(x, y) <= 31)
write(target / "favourite.tga", star)
