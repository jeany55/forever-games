#!/usr/bin/env python3
"""Draws the white shapes the board toolkit tints to mark squares.

    python3 Tools/make_markers.py Images/Board

dot.tga is a filled circle and ring.tga a circle outline, both anti-aliased.
"""
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
            hits += inside((px * px + py * py) ** 0.5)
    return hits / (SAMPLES * SAMPLES)


def write(path, inside):
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 8)
    body = bytearray()
    for y in range(SIZE):
        for x in range(SIZE):
            body += bytes((255, 255, 255, round(255 * coverage(x, y, inside))))
    path.write_bytes(header + body)


target = Path(sys.argv[1])
target.mkdir(parents=True, exist_ok=True)
write(target / "dot.tga", lambda distance: distance <= 30)
write(target / "ring.tga", lambda distance: 25 <= distance <= 31)
