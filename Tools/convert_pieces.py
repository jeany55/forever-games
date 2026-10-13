#!/usr/bin/env python3
"""Turns the ChessCraft "classic" piece PNGs into the TGA textures the addon ships.

    python3 Tools/convert_pieces.py <folder with w-king.png ...> Images/Chess

The game client only reads power of two TGA (or BLP) textures and doesn't build mipmaps for them,
so each piece is written at several sizes and the board picks the one closest to what it draws.
Only the standard library is used: the PNGs are decoded and resampled by hand.
"""
import struct
import sys
import zlib
from pathlib import Path

SIZES = (64, 128, 256)
# Empty space left around the largest piece, as a fraction of the texture
MARGIN = 0.04
PIECES = {"king": "K", "queen": "Q", "rook": "R", "bishop": "B", "knight": "N", "pawn": "P"}


def read_png(path):
    """Returns (width, height, rows) with rows as lists of straight alpha (r, g, b, a) tuples."""
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{path} is not a PNG"
    position, compressed, header = 8, b"", None
    while position < len(data):
        length, kind = struct.unpack(">I4s", data[position : position + 8])
        body = data[position + 8 : position + 8 + length]
        position += length + 12
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            compressed += body

    width, height, depth, color, _, _, interlace = header
    assert depth == 8 and interlace == 0 and color in (4, 6), f"{path}: unsupported PNG variant"
    channels = 4 if color == 6 else 2
    stride = width * channels
    raw = zlib.decompress(compressed)

    rows, previous = [], bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        kind, line = raw[start], bytearray(raw[start + 1 : start + 1 + stride])
        for i in range(stride):
            left = line[i - channels] if i >= channels else 0
            up = previous[i]
            corner = previous[i - channels] if i >= channels else 0
            if kind == 1:
                line[i] = (line[i] + left) & 255
            elif kind == 2:
                line[i] = (line[i] + up) & 255
            elif kind == 3:
                line[i] = (line[i] + (left + up) // 2) & 255
            elif kind == 4:
                estimate = left + up - corner
                distances = (abs(estimate - left), abs(estimate - up), abs(estimate - corner))
                nearest = (left, up, corner)[distances.index(min(distances))]
                line[i] = (line[i] + nearest) & 255
        previous = line
        if channels == 4:
            rows.append([tuple(line[x * 4 : x * 4 + 4]) for x in range(width)])
        else:
            rows.append([(line[x * 2],) * 3 + (line[x * 2 + 1],) for x in range(width)])
    return width, height, rows


def bounds(rows):
    """Box around everything that isn't transparent: left, top, right, bottom (exclusive)."""
    xs = [x for row in rows for x, pixel in enumerate(row) if pixel[3] > 8]
    ys = [y for y, row in enumerate(rows) if any(pixel[3] > 8 for pixel in row)]
    return min(xs), min(ys), max(xs) + 1, max(ys) + 1


def weights(source_start, source_length, size):
    """For each output pixel, the source pixels it covers and how much of each."""
    scale = source_length / size
    table = []
    for index in range(size):
        low, high = source_start + index * scale, source_start + (index + 1) * scale
        covered = []
        for source in range(int(low), int(high) + 1):
            overlap = min(high, source + 1) - max(low, source)
            if overlap > 1e-9:
                covered.append((source, overlap / scale))
        table.append(covered)
    return table


def resample(rows, box, size):
    """Area averages the square `box` of the image down to size x size, on premultiplied colour."""
    width, height = len(rows[0]), len(rows)
    left, top, side = box

    def at(x, y):
        if 0 <= x < width and 0 <= y < height:
            r, g, b, a = rows[y][x]
            return (r * a, g * a, b * a, a)
        return (0, 0, 0, 0)

    columns, lines = weights(left, side, size), weights(top, side, size)
    needed = sorted({source for covered in lines for source, _ in covered})
    squeezed = {
        y: [tuple(sum(at(x, y)[c] * w for x, w in covered) for c in range(4)) for covered in columns] for y in needed
    }

    result = []
    for covered in lines:
        line = []
        for x in range(size):
            r, g, b, a = (sum(squeezed[y][x][c] * w for y, w in covered) for c in range(4))
            if a < 0.5:
                # Black rather than white, so filtering doesn't put a pale fringe on the outlines
                line.append((0, 0, 0, 0))
            else:
                line.append(tuple(min(255, round(v / a)) for v in (r, g, b)) + (min(255, round(a)),))
        result.append(line)
    return result


def write_tga(path, rows):
    size = len(rows)
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, size, size, 32, 8)
    body = bytearray()
    for row in reversed(rows):
        for r, g, b, a in row:
            body += bytes((b, g, r, a))
    path.write_bytes(header + body)


def main(source, target):
    source, target = Path(source), Path(target)
    images = {}
    for color in "wb":
        for name, letter in PIECES.items():
            images[color + letter] = read_png(source / f"{color}-{name}.png")

    # One crop for every piece, so they keep their sizes relative to each other
    width, height, _ = next(iter(images.values()))
    assert all(image[0] == width and image[1] == height == width for image in images.values())
    reach = 0
    for _, _, rows in images.values():
        left, top, right, bottom = bounds(rows)
        reach = max(reach, width / 2 - left, right - width / 2, height / 2 - top, bottom - height / 2)
    side = 2 * reach / (1 - 2 * MARGIN)
    box = (width / 2 - side / 2, height / 2 - side / 2, side)

    for size in SIZES:
        (target / str(size)).mkdir(parents=True, exist_ok=True)
        for name, (_, _, rows) in images.items():
            write_tga(target / str(size) / f"{name}.tga", resample(rows, box, size))
    print(f"cropped to {side:.0f}px of {width}px, wrote {len(images) * len(SIZES)} textures")


if __name__ == "__main__":
    main(*sys.argv[1:3])
