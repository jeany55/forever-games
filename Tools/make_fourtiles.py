#!/usr/bin/env python3
"""Makes the puzzles of Fourtiles (Games/Fourtiles.lua), and draws its icon and its tiles.

    python3 Tools/make_fourtiles.py puzzles enable1.txt scowl/final Lexicon/Fourtiles.lua
    python3 Tools/make_fourtiles.py icon .
    python3 Tools/make_fourtiles.py tiles .

A puzzle is five words cut into four tiles each, of two to four letters. Whatever a player can
put together from one to four of the twenty tiles counts if it is a word, so the tool also
counts how many of those there are: the game would take far too long to find that out itself.

Two lists go in. What counts as a word is ENABLE, the same list Tools/make_words.py packs: one
lower case word a line. The five words themselves have to be ones people know, which ENABLE
doesn't tell, so they come from SCOWL (http://wordlist.aspell.net, the folder `final` of its
download), whose lists are sorted by how common their words are.

A puzzle is only kept if
- no two of its tiles are the same,
- its five words are the only ones that take four tiles,
- no word can be put together from two different numbers of tiles, so what it is worth doesn't
  depend on how it was found, and
- the top rank can be reached with everyday words alone.

Whatever `puzzles` writes is part of the rules of the game. After running it again, give the
game a new version: Tests/RunTests.lua won't pass until then. Only the standard library is used.
For `icon` and `tiles`, pass a second folder to also get PNG copies there.

The tiles are three white pictures the game tints, cut in nine like a window pane so the corners
stay round however wide or tall a tile is drawn (Widgets.Slices): body.tga, a tile darker towards
its foot, gloss.tga, the light along its top, and ring.tga, the line around a picked one.
"""
import itertools
import math
import random
import re
import struct
import sys
import zlib
from pathlib import Path

# ---------------------------------------------------------------- puzzles

PUZZLES = 1000
SEED = 4
TILES_A_WORD = 4
SHORTEST_TILE, LONGEST_TILE = 2, 4
SHORTEST_WORD, LONGEST_WORD = 8, 12
# How common the five words have to be, and what counts as an everyday word, in SCOWL's sizes
TARGET_SIZES = (10, 20)
EVERYDAY_SIZES = (10, 20, 35, 40, 50)
# The same as in Games/Fourtiles.lua: what a word of so many tiles is worth, what finding all
# five of the long ones adds, and the score the top rank begins at
POINTS = {1: 1, 2: 2, 3: 4, 4: 8}
BONUS = 40
TOP_RANK = 100
# How far over the top rank everyday words have to take a puzzle
SLACK = 15
# How many puzzles a word may turn up in
REPEATS = 2

HEADER = """\
--------------------------
--  Fourtiles puzzles
--------------------------
-- {count} puzzles for Games/Fourtiles.lua. Each is its five words, cut into the tiles they are
-- played with, and then how many words there are to find of one, two and three tiles. Written by
-- Tools/make_fourtiles.py, don't edit it by hand: the numbers are only right for the word list
-- they were counted with (Lexicon/English.lua).

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @type string[]
private.FourtilesPuzzles = {{
"""


def scowl(final, sizes):
    words = set()
    for kind in ("english-words", "american-words"):
        for size in sizes:
            source = final / f"{kind}.{size}"
            if source.exists():
                words |= {word for word in source.read_text(encoding="latin-1").split() if re.fullmatch("[a-z]+", word)}
    return words


def cuts(length):
    """Every way to cut a word of this length into its tiles, as their lengths."""
    sizes = range(SHORTEST_TILE, LONGEST_TILE + 1)
    return [cut for cut in itertools.product(sizes, repeat=TILES_A_WORD) if sum(cut) == length]


def words_in(tiles, lexicon, prefixes):
    """Every word that can be put together from the tiles, with the numbers of tiles it takes."""
    found = {}

    def extend(used, text, count):
        if count and text in lexicon:
            found.setdefault(text, set()).add(count)
        if count == TILES_A_WORD:
            return
        for index, tile in enumerate(tiles):
            if not used >> index & 1 and text + tile in prefixes:
                extend(used | 1 << index, text + tile, count + 1)

    extend(0, "", 0)
    return found


def make_puzzles(enable, final, target):
    lexicon = {word for word in Path(enable).read_text(encoding="ascii").split() if len(word) >= 2}
    prefixes = {word[:end] for word in lexicon for end in range(1, len(word) + 1)}
    final = Path(final)
    everyday = scowl(final, EVERYDAY_SIZES) & lexicon
    candidates = sorted(word for word in scowl(final, TARGET_SIZES) & lexicon if SHORTEST_WORD <= len(word) <= LONGEST_WORD)

    rng = random.Random(SEED)
    used = {}
    puzzles = []
    while len(puzzles) < PUZZLES:
        words = rng.sample(candidates, 5)
        if any(used.get(word, 0) >= REPEATS for word in words):
            continue
        cut_words = []
        for word in words:
            parts, at = [], 0
            for size in rng.choice(cuts(len(word))):
                parts.append(word[at : at + size])
                at += size
            cut_words.append(parts)
        tiles = [tile for parts in cut_words for tile in parts]
        if len(set(tiles)) < len(tiles):
            continue
        found = words_in(tiles, lexicon, prefixes)
        if any(len(counts) > 1 for counts in found.values()):
            continue
        sizes = {word: next(iter(counts)) for word, counts in found.items()}
        if {word for word, size in sizes.items() if size == TILES_A_WORD} != set(words):
            continue
        if BONUS + sum(POINTS[size] for word, size in sizes.items() if word in everyday) < TOP_RANK + SLACK:
            continue
        for word in words:
            used[word] = used.get(word, 0) + 1
        tally = [sum(1 for size in sizes.values() if size == count) for count in (1, 2, 3)]
        puzzles.append(" ".join(".".join(parts) for parts in cut_words).upper() + " " + ".".join(map(str, tally)))

    lines = [HEADER.format(count=len(puzzles))]
    lines += [f'  "{puzzle}",\n' for puzzle in puzzles]
    lines.append("}\n")
    Path(target).write_text("".join(lines), encoding="ascii")
    print(f"{len(puzzles)} puzzles in {target}, from {len(used)} of {len(candidates)} words")


# ---------------------------------------------------------------- icon

SIZE = 64
SAMPLES = 4
CORNER = 9
BACKGROUND = (34, 38, 48)
BONE = (240, 225, 190)
SHADE = (196, 176, 138)
GOLD = (255, 209, 70)
INK = (58, 34, 14)
# Four tiles, two by two, and how round their corners are
TILE, GAP, ROUND = 25, 4, 4
# What is written on them, in letters five dots wide and seven high
WRITTEN = (("FO", "UR"), ("TI", "LE"))
PICKED = (1, 0)
LETTERS = {
    "F": ("#####", "#....", "#....", "####.", "#....", "#....", "#...."),
    "O": (".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."),
    "U": ("#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."),
    "R": ("####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"),
    "T": ("#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."),
    "I": (".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."),
    "L": ("#....", "#....", "#....", "#....", "#....", "#....", "#####"),
    "E": ("#####", "#....", "#....", "####.", "#....", "#....", "#####"),
}


def inside(px, py, left, top, width, height, corner):
    """Whether a point lies in a box with round corners."""
    nx, ny = min(max(px, left + corner), left + width - corner), min(max(py, top + corner), top + height - corner)
    return (px - nx) ** 2 + (py - ny) ** 2 <= corner**2


def colour_at(px, py):
    """The colour of a point of the picture, and whether there is anything there at all."""
    if not inside(px, py, 0, 0, SIZE, SIZE, CORNER):
        return None
    first = (SIZE - 2 * TILE - GAP) / 2
    for row in range(2):
        for column in range(2):
            left, top = first + column * (TILE + GAP), first + row * (TILE + GAP)
            if not inside(px, py, left, top, TILE, TILE, ROUND):
                continue
            # Two letters, a dot apart
            text = WRITTEN[row][column]
            x, y = int(px - left - (TILE - 11) / 2), int(py - top - (TILE - 7) / 2 + 1)
            if 0 <= y < 7 and 0 <= x < 11 and x != 5 and px - left >= (TILE - 11) / 2 and py - top >= (TILE - 7) / 2 - 1:
                if LETTERS[text[x // 6]][y][x % 6] == "#":
                    return INK
            if py - top > TILE - 3:
                return SHADE
            return GOLD if (column, row) == PICKED else BONE
    return BACKGROUND


def write_tga(path, rows):
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, len(rows), len(rows), 32, 8)
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
    head = struct.pack(">IIBBBBB", len(rows), len(rows), 8, 6, 0, 0, 0)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", head) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def make_icon(target, preview=None):
    rows = []
    for y in range(SIZE):
        row = []
        for x in range(SIZE):
            total, hits = [0, 0, 0], 0
            for i in range(SAMPLES):
                for j in range(SAMPLES):
                    colour = colour_at(x + (i + 0.5) / SAMPLES, y + (j + 0.5) / SAMPLES)
                    if colour:
                        hits += 1
                        for channel in range(3):
                            total[channel] += colour[channel]
            row.append(tuple(round(value / max(hits, 1)) for value in total) + (round(255 * hits / SAMPLES**2),))
        rows.append(row)
    write_tga(Path(target) / "Images" / "Icons" / "fourtiles.tga", rows)
    if preview:
        write_png(Path(preview) / "fourtiles.png", rows)
    print("wrote the icon of Fourtiles")


# ---------------------------------------------------------------- tiles

PANE = 64
# How round the corners are, inside the quarter of the picture at each edge that the game keeps
# from stretching (Widgets.Slices)
RADIUS = 14
RING = 3


def outside(px, py):
    """How far a point is outside the tile, below zero inside it, in pixels of the picture"""
    half = PANE / 2
    dx, dy = abs(px - half) - half + RADIUS, abs(py - half) - half + RADIUS
    return math.hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - RADIUS


def body(px, py, distance):
    """Lighter at the top, and a darker lip along its foot"""
    shade = 1 - 0.14 * py / PANE
    if py > PANE / 2 and distance > -4:
        shade *= 0.66
    return shade, 1.0


def gloss(px, py, distance):
    """A bright rim along the top that fades down the sides, and a faint sheen over the top half"""
    top = max(0.0, 1 - py / (PANE / 2))
    alpha = 0.06 * top
    if distance > -2.5:
        alpha = max(alpha, 0.4 * top**1.5)
    return 1.0, alpha


def ring(px, py, distance):
    return 1.0, 1.0 if distance > -RING else 0.0


def make_tiles(target, preview=None):
    for name, paint in (("body", body), ("gloss", gloss), ("ring", ring)):
        rows = []
        for y in range(PANE):
            row = []
            for x in range(PANE):
                value = alpha = 0.0
                for i in range(SAMPLES):
                    for j in range(SAMPLES):
                        px, py = x + (i + 0.5) / SAMPLES, y + (j + 0.5) / SAMPLES
                        distance = outside(px, py)
                        if distance <= 0:
                            shade, a = paint(px, py, distance)
                            value, alpha = value + shade * a, alpha + a
                grey = round(255 * value / alpha) if alpha > 0 else 255
                row.append((grey, grey, grey, round(255 * alpha / SAMPLES**2)))
            rows.append(row)
        write_tga(Path(target) / "Images" / "Fourtiles" / (name + ".tga"), rows)
        if preview:
            write_png(Path(preview) / ("fourtiles_" + name + ".png"), rows)
    print("wrote the tiles of Fourtiles")


if __name__ == "__main__":
    if len(sys.argv) >= 5 and sys.argv[1] == "puzzles":
        make_puzzles(*sys.argv[2:5])
    elif len(sys.argv) >= 3 and sys.argv[1] == "icon":
        make_icon(*sys.argv[2:4])
    elif len(sys.argv) >= 3 and sys.argv[1] == "tiles":
        make_tiles(*sys.argv[2:4])
    else:
        raise SystemExit(__doc__)
