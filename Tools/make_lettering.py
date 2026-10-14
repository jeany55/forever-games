#!/usr/bin/env python3
"""Draws the letters the tiles of Fourtiles and Words are written in (GUI/Lettering.lua).

    python3 Tools/make_lettering.py Lexend-SemiBold.ttf .

The client won't draw text in a font an addon brings along: it knows the file is there, but its
text only comes from fonts that are part of the game. Pictures it draws from an addon's folder,
so the letters are pictures instead. Every character in CHARACTERS is drawn white from the font
into a grid of squares, in Images/Lettering/<side of the picture>.tga at a few sizes, and how far
each moves the pen along goes to GUI/LetteringGlyphs.lua.

The font is Lexend SemiBold, from https://github.com/googlefonts/lexend (fonts/lexend/ttf),
under the SIL Open Font License 1.1 (Images/Lettering/Lexend-OFL.txt). Only the standard library
is used: the font is read and its outlines filled here. Pass a third folder to also get PNG
copies there.
"""
import struct
import sys
import zlib
from pathlib import Path

CHARACTERS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789·"
COLUMNS = 8
# The sides of the squares a character is drawn in, one picture for each
SQUARES = (16, 32, 64)
# How large the em is and how far down the square the baseline lies, as fractions of its side
EM, BASELINE = 0.72, 0.78
# How many rows every row of pixels is cut into while filling, and how many lines a curve is
SAMPLES = 16
STEPS = 8


class Font:
    """Just enough of a TrueType font to draw its outlines"""

    def __init__(self, data):
        self.data = data
        count = self.u16(4)
        self.tables = {}
        for index in range(count):
            tag, _, offset, _ = struct.unpack_from(">4sIII", data, 12 + 16 * index)
            self.tables[tag.decode()] = offset
        head, hhea = self.tables["head"], self.tables["hhea"]
        self.units = self.u16(head + 18)
        self.long_loca = self.i16(head + 50) == 1
        self.ascent, self.descent = self.i16(hhea + 4), -self.i16(hhea + 6)
        self.metrics = self.u16(hhea + 34)
        self.glyphs = self.u16(self.tables["maxp"] + 4)
        self.cmap = self.read_cmap()

    def u16(self, at):
        return struct.unpack_from(">H", self.data, at)[0]

    def i16(self, at):
        return struct.unpack_from(">h", self.data, at)[0]

    def read_cmap(self):
        """Characters to glyphs, from the Windows Unicode table of format 4"""
        cmap = self.tables["cmap"]
        for index in range(self.u16(cmap + 2)):
            platform, encoding, offset = struct.unpack_from(">HHI", self.data, cmap + 4 + 8 * index)
            table = cmap + offset
            if platform == 3 and encoding == 1 and self.u16(table) == 4:
                segments = self.u16(table + 6) // 2
                ends = table + 14
                starts = ends + 2 * segments + 2
                deltas = starts + 2 * segments
                ranges = deltas + 2 * segments
                mapping = {}
                for segment in range(segments):
                    end, start = self.u16(ends + 2 * segment), self.u16(starts + 2 * segment)
                    delta, offset = self.u16(deltas + 2 * segment), self.u16(ranges + 2 * segment)
                    for code in range(start, min(end, 0xFFFE) + 1):
                        if offset == 0:
                            glyph = (code + delta) & 0xFFFF
                        else:
                            glyph = self.u16(ranges + 2 * segment + offset + 2 * (code - start))
                            glyph = (glyph + delta) & 0xFFFF if glyph else 0
                        mapping[chr(code)] = glyph
                return mapping
        raise SystemExit("the font has no Unicode table of format 4")

    def advance(self, glyph):
        return self.u16(self.tables["hmtx"] + 4 * min(glyph, self.metrics - 1))

    def where(self, glyph):
        loca = self.tables["loca"]
        if self.long_loca:
            start, end = struct.unpack_from(">II", self.data, loca + 4 * glyph)
        else:
            start, end = (2 * value for value in struct.unpack_from(">HH", self.data, loca + 2 * glyph))
        return self.tables["glyf"] + start, end - start

    def contours(self, glyph):
        """The outline of a glyph, as closed lists of (x, y, on the curve)"""
        at, length = self.where(glyph)
        if length == 0:
            return []
        count = self.i16(at)
        if count < 0:
            return self.composite(at + 10)
        ends = [self.u16(at + 10 + 2 * index) for index in range(count)]
        at += 10 + 2 * count
        at += 2 + self.u16(at)
        points = ends[-1] + 1
        flags = []
        while len(flags) < points:
            flag = self.data[at]
            at += 1
            flags.append(flag)
            if flag & 8:
                flags.extend([flag] * self.data[at])
                at += 1
        coordinates = []
        for short, same in ((2, 16), (4, 32)):
            value, values = 0, []
            for flag in flags:
                if flag & short:
                    step = self.data[at]
                    at += 1
                    value += step if flag & same else -step
                elif not flag & same:
                    value += self.i16(at)
                    at += 2
                values.append(value)
            coordinates.append(values)
        xs, ys = coordinates
        result, first = [], 0
        for end in ends:
            result.append([(xs[index], ys[index], bool(flags[index] & 1)) for index in range(first, end + 1)])
            first = end + 1
        return result

    def composite(self, at):
        """A glyph put together from others, each moved and perhaps scaled"""
        result = []
        while True:
            flags, glyph = struct.unpack_from(">HH", self.data, at)
            at += 4
            if flags & 1:
                dx, dy = struct.unpack_from(">hh", self.data, at)
                at += 4
            else:
                dx, dy = struct.unpack_from(">bb", self.data, at)
                at += 2
            a, b, c, d = 1.0, 0.0, 0.0, 1.0
            if flags & 8:
                a = d = self.i16(at) / 16384
                at += 2
            elif flags & 0x40:
                a, d = self.i16(at) / 16384, self.i16(at + 2) / 16384
                at += 4
            elif flags & 0x80:
                a, b, c, d = (self.i16(at + 2 * index) / 16384 for index in range(4))
                at += 8
            if not flags & 2:
                raise SystemExit("a glyph put together from matched points isn't supported")
            for contour in self.contours(glyph):
                result.append([(a * x + c * y + dx, b * x + d * y + dy, on) for x, y, on in contour])
            if not flags & 0x20:
                return result


def lines(contour):
    """A contour of on and off curve points as straight lines, its curves cut into STEPS"""
    # Between two points off the curve lies one on it, halfway
    full = []
    for index, point in enumerate(contour):
        full.append(point)
        after = contour[(index + 1) % len(contour)]
        if not point[2] and not after[2]:
            full.append(((point[0] + after[0]) / 2, (point[1] + after[1]) / 2, True))
    start = next(index for index, point in enumerate(full) if point[2])
    full = full[start:] + full[:start] + [full[start]]
    points = [full[0][:2]]
    index = 1
    while index < len(full):
        point = full[index]
        if point[2]:
            points.append(point[:2])
            index += 1
            continue
        # A curve from the point before, bent towards this one, to the one after
        a, c = full[index - 1], full[index + 1]
        for step in range(1, STEPS + 1):
            t = step / STEPS
            points.append(((1 - t) ** 2 * a[0] + 2 * (1 - t) * t * point[0] + t * t * c[0], (1 - t) ** 2 * a[1] + 2 * (1 - t) * t * point[1] + t * t * c[1]))
        index += 2
    return [(points[i], points[i + 1]) for i in range(len(points) - 1)]


def fill(edges, width, height):
    """How much of every pixel lies inside, by the non-zero rule: rows of 0 to 1"""
    coverage = [[0.0] * width for _ in range(height)]
    for row in range(height):
        for sample in range(SAMPLES):
            y = row + (sample + 0.5) / SAMPLES
            crossings = []
            for (x0, y0), (x1, y1) in edges:
                if (y0 <= y < y1) or (y1 <= y < y0):
                    crossings.append((x0 + (y - y0) * (x1 - x0) / (y1 - y0), 1 if y1 > y0 else -1))
            crossings.sort()
            winding = 0
            for index, (x, direction) in enumerate(crossings):
                was = winding
                winding += direction
                if was == 0 and winding != 0:
                    left = x
                elif was != 0 and winding == 0:
                    span(coverage[row], left, x, 1 / SAMPLES)
    return coverage


def span(row, left, right, amount):
    """Adds what lies between left and right to a row of pixels, parts of a pixel too"""
    left, right = max(left, 0.0), min(right, float(len(row)))
    if right <= left:
        return
    first, last = int(left), min(int(right), len(row) - 1)
    if first == last:
        row[first] += (right - left) * amount
        return
    row[first] += (first + 1 - left) * amount
    for pixel in range(first + 1, last):
        row[pixel] += amount
    row[last] += (right - last) * amount


def draw(font, square):
    """The picture of every character at one size, and how far each moves the pen, in ems"""
    side = square * COLUMNS
    picture = [[0.0] * side for _ in range(side)]
    scale = square * EM / font.units
    advances = {}
    for index, character in enumerate(CHARACTERS):
        glyph = font.cmap.get(character, 0)
        advance = font.advance(glyph)
        advances[character] = advance / font.units
        # The pen's box is in the middle of the square, and the baseline BASELINE of the way down
        left = (square - advance * scale) / 2
        edges = []
        for contour in font.contours(glyph):
            for (x0, y0), (x1, y1) in lines(contour):
                edges.append(((left + x0 * scale, square * BASELINE - y0 * scale), (left + x1 * scale, square * BASELINE - y1 * scale)))
        cell = fill(edges, square, square)
        column, row = index % COLUMNS, index // COLUMNS
        for y in range(square):
            for x in range(square):
                picture[row * square + y][column * square + x] = min(1.0, cell[y][x])
    return picture, advances


def write_tga(path, picture):
    side = len(picture)
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, side, side, 32, 8)
    body = bytearray()
    # Rows are written bottom up
    for row in reversed(picture):
        for value in row:
            body += bytes((255, 255, 255, round(255 * value)))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(header + body)


def write_png(path, picture):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    side = len(picture)
    # Dark on light, which is easier to look at than white on nothing
    raw = b"".join(b"\x00" + bytes(255 - round(255 * value) for value in row) for row in picture)
    head = struct.pack(">IIBBBBB", side, side, 8, 0, 0, 0, 0)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", head) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def lua_string(character):
    return '"' + ("\\" + character if character in '"\\' else character) + '"'


def write_glyphs(path, font, advances):
    lines_out = [
        "--------------------------",
        "--  Lettering glyphs",
        "--------------------------",
        "-- Where every character is in the pictures of Images/Lettering and how far it moves the pen.",
        "-- Written by Tools/make_lettering.py, don't edit it by hand.",
        "",
        "--- @type nil, ForeverGamesPrivate",
        "local _, private = ...",
        "",
        "private.LetteringGlyphs = {",
        "  -- The sides of the squares a character is drawn in, one picture for each: Images/Lettering/<side * columns>",
        "  squares = { " + ", ".join(str(square) for square in SQUARES) + " },",
        "  columns = %d," % COLUMNS,
        "  -- How large the em is and how far down a square the baseline lies, as fractions of its side",
        "  em = %s," % EM,
        "  baseline = %s," % BASELINE,
        "  -- How far above and below the baseline a line of text reaches, in ems",
        "  ascent = %.4f," % (font.ascent / font.units),
        "  descent = %.4f," % (font.descent / font.units),
        "  space = %.4f," % (font.advance(font.cmap.get(" ", 0)) / font.units),
        "  -- Each character: which square it is in, from 0, and how far it moves the pen, in ems",
        "  glyphs = {",
    ]
    for index, character in enumerate(CHARACTERS):
        lines_out.append("    [%s] = { %d, %.4f }," % (lua_string(character), index, advances[character]))
    lines_out += ["  },", "}", ""]
    path.write_text("\n".join(lines_out))


def main(font_path, target, preview=None):
    font = Font(Path(font_path).read_bytes())
    target = Path(target)
    advances = None
    for square in SQUARES:
        picture, advances = draw(font, square)
        side = square * COLUMNS
        write_tga(target / "Images" / "Lettering" / ("%d.tga" % side), picture)
        if preview:
            write_png(Path(preview) / ("lettering_%d.png" % side), picture)
    write_glyphs(target / "GUI" / "LetteringGlyphs.lua", font, advances)
    print("wrote the lettering, %d characters at %d sizes" % (len(CHARACTERS), len(SQUARES)))


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    main(*sys.argv[1:4])
