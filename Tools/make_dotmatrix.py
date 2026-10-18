#!/usr/bin/env python3
"""Draws the dot-matrix display's letters (GUI/DotMatrix.lua): a score display made of dots, the
kind pinball machines have had since the nineties.

    python3 Tools/make_dotmatrix.py Images/DotMatrix [png folder]

Writes small.tga, the letters 5 dots wide and 7 tall, and big.tga, the same letters with every dot
of them four (10 by 14), each a sheet of 8 by 8 cells in the order of CHARS, the letters lit in
white for the display to colour; and dot.tga, one unlit dot, which the display repeats behind them.
Only the standard library is used. Pass a second folder to also get PNG copies.
"""
import math
import struct
import sys
import zlib
from pathlib import Path

# The characters there are, in the order of their cells; GUI/DotMatrix.lua has the same
CHARS = " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!?.,:;'\"-+/%#&()*=<>_$@[]"

# Each letter 5 wide and 7 tall, "#" a lit dot
GLYPHS = {
    " ": [".....", ".....", ".....", ".....", ".....", ".....", "....."],
    "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
    "C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
    "D": ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."],
    "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
    "F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
    "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####"],
    "H": ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "I": [".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "J": ["..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."],
    "K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
    "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
    "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
    "N": ["#...#", "#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#"],
    "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
    "Q": [".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"],
    "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
    "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
    "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
    "U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "V": ["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
    "W": ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#."],
    "X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
    "Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
    "Z": ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
    "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
    "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
    "3": ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
    "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
    "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
    "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
    "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
    "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
    "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
    "!": ["..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#.."],
    "?": [".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.."],
    ".": [".....", ".....", ".....", ".....", ".....", ".##..", ".##.."],
    ",": [".....", ".....", ".....", ".....", ".##..", "..#..", ".#..."],
    ":": [".....", ".##..", ".##..", ".....", ".##..", ".##..", "....."],
    ";": [".....", ".##..", ".##..", ".....", ".##..", "..#..", ".#..."],
    "'": ["..#..", "..#..", ".#...", ".....", ".....", ".....", "....."],
    '"': [".#.#.", ".#.#.", ".....", ".....", ".....", ".....", "....."],
    "-": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
    "+": [".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."],
    "/": [".....", "....#", "...#.", "..#..", ".#...", "#....", "....."],
    "%": ["##...", "##..#", "...#.", "..#..", ".#...", "#..##", "...##"],
    "#": [".#.#.", ".#.#.", "#####", ".#.#.", "#####", ".#.#.", ".#.#."],
    "&": [".##..", "#..#.", "#.#..", ".#...", "#.#.#", "#..#.", ".##.#"],
    "(": ["...#.", "..#..", ".#...", ".#...", ".#...", "..#..", "...#."],
    ")": [".#...", "..#..", "...#.", "...#.", "...#.", "..#..", ".#..."],
    "*": [".....", "..#..", "#.#.#", ".###.", "#.#.#", "..#..", "....."],
    "=": [".....", ".....", "#####", ".....", "#####", ".....", "....."],
    "<": ["...#.", "..#..", ".#...", "#....", ".#...", "..#..", "...#."],
    ">": [".#...", "..#..", "...#.", "....#", "...#.", "..#..", ".#..."],
    "_": [".....", ".....", ".....", ".....", ".....", ".....", "#####"],
    "$": ["..#..", ".####", "#.#..", ".###.", "..#.#", "####.", "..#.."],
    "@": [".###.", "#...#", "#.###", "#.#.#", "#.###", "#....", ".###."],
    "[": [".###.", ".#...", ".#...", ".#...", ".#...", ".#...", ".###."],
    "]": [".###.", "...#.", "...#.", "...#.", "...#.", "...#.", ".###."],
}

# Pixels a dot takes in the pictures, and how much of that the dot is across
DOT = 16
FILL = 0.78
SHEET = 1024
CELLS = 8


def dot(px, py):
    """How lit a pixel of a dot's square is: a round dot, a soft edge"""
    cx = cy = DOT / 2
    r = DOT * FILL / 2
    d = math.hypot(px + 0.5 - cx, py + 0.5 - cy)
    return max(0.0, min(1.0, r + 0.5 - d))


def sheet(scale):
    """The letters with every dot of them `scale` by `scale` dots, each in a cell of the sheet with
    a dot's gap round it on the right and below"""
    cell = SHEET // CELLS
    across, down = (5 + 1) * scale, (7 + 1) * scale
    size = cell // max(across, down)
    pixels = bytearray(SHEET * SHEET * 4)
    for index, char in enumerate(CHARS):
        rows = GLYPHS[char]
        ox, oy = (index % CELLS) * cell, (index // CELLS) * cell
        for gy in range(7 * scale):
            for gx in range(5 * scale):
                if rows[gy // scale][gx // scale] != "#":
                    continue
                for py in range(size):
                    for px in range(size):
                        alpha = dot(px * DOT / size, py * DOT / size)
                        if alpha <= 0:
                            continue
                        x, y = ox + gx * size + px, oy + gy * size + py
                        i = (y * SHEET + x) * 4
                        pixels[i:i + 4] = bytes((255, 255, 255, int(alpha * 255)))
    return pixels, size


def write_tga(path, width, height, pixels):
    """Uncompressed 32 bit TGA, its rows written bottom up as the other tools write them"""
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, width, height, 32, 8)
    data = bytearray(len(pixels))
    data[0::4], data[1::4], data[2::4], data[3::4] = pixels[2::4], pixels[1::4], pixels[0::4], pixels[3::4]
    stride = width * 4
    body = b"".join(bytes(data[y * stride:(y + 1) * stride]) for y in reversed(range(height)))
    Path(path).write_bytes(header + body)


def write_png(path, width, height, pixels):
    """Orange on black, as the display shows it, which is easier to look at than white on nothing"""
    shown = bytearray(width * height * 4)
    shown[0::4] = bytes(a for a in pixels[3::4])
    shown[1::4] = bytes(a * 140 // 255 for a in pixels[3::4])
    shown[2::4] = bytes(a * 30 // 255 for a in pixels[3::4])
    shown[3::4] = b"\xff" * (width * height)
    pixels = shown
    rows = b"".join(b"\x00" + bytes(pixels[y * width * 4:(y + 1) * width * 4]) for y in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    Path(path).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(rows, 6)) + chunk(b"IEND", b""))


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    png = Path(sys.argv[2]) if len(sys.argv) > 2 else None
    assert all(char in GLYPHS for char in CHARS)
    for name, scale in (("small", 1), ("big", 2)):
        pixels, size = sheet(scale)
        write_tga(out / f"{name}.tga", SHEET, SHEET, pixels)
        if png:
            png.mkdir(parents=True, exist_ok=True)
            write_png(png / f"{name}.png", SHEET, SHEET, pixels)
        print(out / f"{name}.tga", f"{size} px a dot")
    # One unlit dot, a pale one the display tints to its own colour, very faint
    pixels = bytearray(DOT * DOT * 4)
    for py in range(DOT):
        for px in range(DOT):
            i = (py * DOT + px) * 4
            pixels[i:i + 4] = bytes((255, 255, 255, int(dot(px, py) * 255)))
    write_tga(out / "dot.tga", DOT, DOT, pixels)
    print(out / "dot.tga")


if __name__ == "__main__":
    main()
