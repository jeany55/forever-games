#!/usr/bin/env python3
"""Draws the icon of Sudoku.

    python3 Tools/make_sudoku.py .

Writes Images/Icons/sudoku.tga: one box of a grid, three squares by three, with a few digits in
it. One is the white of what a puzzle comes with, one the blue of what the player wrote, in the
square they are on, and one the gold of a hint, the way Games/Sudoku.lua colours them. The grid
itself is all lines and figures, which the game draws without any texture.

Only the standard library is used. Pass a second folder to also get a PNG copy there.
"""
import struct
import sys
import zlib
from pathlib import Path

SIZE = 64
SAMPLES = 4
CORNER = 9
BACKGROUND = (28, 34, 52)
PAPER = (38, 44, 64)
SELECTED = (44, 82, 150)
LINE = (86, 94, 118)
HEAVY = (170, 176, 196)
GIVEN = (238, 238, 245)
WRITTEN = (115, 194, 255)
HINTED = (255, 209, 0)

# Where the box is, and how its squares and lines are laid out
MARGIN, BORDER, THIN, CELL = 5, 2, 1, 16

# The digits, five dots wide and seven high
DIGITS = {
    1: ("..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."),
    3: ("####.", "....#", "....#", ".###.", "....#", "....#", "####."),
    5: ("#####", "#....", "####.", "....#", "....#", "#...#", ".###."),
    7: ("#####", "....#", "...#.", "..#..", "..#..", ".#...", ".#..."),
    9: (".###.", "#...#", "#...#", ".####", "....#", "#...#", ".###."),
}
DOT = 2
# What stands in which square of the box, by column and row, and in which colour
FIGURES = {(0, 0): (5, GIVEN), (2, 0): (7, GIVEN), (1, 1): (3, WRITTEN), (0, 2): (1, GIVEN), (2, 2): (9, HINTED)}
CHOSEN = (1, 1)


def square(index):
    """Where a square starts along a side of the picture."""
    return MARGIN + BORDER + index * (CELL + THIN)


def picture():
    """Rows of (r, g, b), top row first, without the corners taken off."""
    rows = [[BACKGROUND] * SIZE for _ in range(SIZE)]
    side = 2 * BORDER + 3 * CELL + 2 * THIN

    def fill(left, top, width, height, colour):
        for y in range(top, top + height):
            for x in range(left, left + width):
                rows[y][x] = colour

    fill(MARGIN, MARGIN, side, side, HEAVY)
    fill(MARGIN + BORDER, MARGIN + BORDER, side - 2 * BORDER, side - 2 * BORDER, LINE)
    for column in range(3):
        for row in range(3):
            left, top = square(column), square(row)
            fill(left, top, CELL, CELL, SELECTED if (column, row) == CHOSEN else PAPER)
            if (column, row) in FIGURES:
                digit, colour = FIGURES[(column, row)]
                dots = DIGITS[digit]
                width, height = len(dots[0]) * DOT, len(dots) * DOT
                for y, line in enumerate(dots):
                    for x, dot in enumerate(line):
                        if dot == "#":
                            fill(left + (CELL - width) // 2 + x * DOT, top + (CELL - height) // 2 + y * DOT, DOT, DOT, colour)
    return rows


def coverage(x, y):
    """How much of a pixel lies inside the picture's rounded corners."""
    hits = 0
    for i in range(SAMPLES):
        for j in range(SAMPLES):
            px, py = x + (i + 0.5) / SAMPLES, y + (j + 0.5) / SAMPLES
            # The nearest point of the square the corners are rounded around
            nx, ny = min(max(px, CORNER), SIZE - CORNER), min(max(py, CORNER), SIZE - CORNER)
            hits += (px - nx) ** 2 + (py - ny) ** 2 <= CORNER**2
    return hits / SAMPLES**2


def write_tga(path, rows):
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 8)
    body = bytearray()
    # Rows are written bottom up
    for row in reversed(rows):
        for r, g, b, a in row:
            body += bytes((b, g, r, a))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(header + body)


def write_png(path, rows):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + bytes(value for pixel in row for value in pixel) for row in rows)
    head = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", head) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def main(target, preview=None):
    rows = [[colour + (round(255 * coverage(x, y)),) for x, colour in enumerate(row)] for y, row in enumerate(picture())]
    write_tga(Path(target) / "Images" / "Icons" / "sudoku.tga", rows)
    if preview:
        write_png(Path(preview) / "sudoku.png", rows)
    print("wrote the icon of Sudoku")


if __name__ == "__main__":
    main(*sys.argv[1:3])
