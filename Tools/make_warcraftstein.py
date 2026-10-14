#!/usr/bin/env python3
"""Draws the walls of Warcraftstein 3D (Games/Warcraftstein.lua), who lives between them, and its icon.

    python3 Tools/make_warcraftstein.py Images

Writes Images/Warcraftstein/<name>.tga: brick, stone and moss for the walls of the maze, and
portal for the way out of it. Then sprites, everything that stands in the maze side by side: the
four pictures of a kobold (standing, stepping, striking and dead), a bolt of magic, a potion for
health and one for power, and a totem. And weapons, what the player holds, ready and swung: a
sword, a bow, a staff and claws. Also Images/Icons/warcraftstein.tga, a look down a corridor. Only the standard library is used. Pass a
second folder to also get PNG copies there, which are easier to look at than TGA.

A wall is drawn a pixel at a time and never smoothed: the game shows it a column of the picture
at a time, as wide and as tall as the wall is near, and it is meant to look like it. A kobold is
shown the same way, so its picture is as tall as a wall is, with the floor at the foot of it and
nothing where the kobold isn't.
"""
import math
import struct
import sys
import zlib
from pathlib import Path

SIZE = 64
MORTAR = (58, 52, 50)
BRICK, BRICK_DARK = (150, 62, 46), (104, 40, 34)
STONE, STONE_DARK = (124, 124, 132), (72, 72, 82)
MOSS = (62, 112, 52)
ARCH = (86, 82, 96)
GLOW, GLOW_DEEP = (150, 235, 255), (28, 60, 150)


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def clamp(value):
    return max(0.0, min(1.0, value))


def noise(x, y, salt=0):
    """A number from 0 to 1 that is always the same for the same pixel"""
    n = (x * 374761393 + y * 668265263 + salt * 2147483647) & 0xFFFFFFFF
    n = ((n ^ (n >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((n ^ (n >> 16)) & 0xFFFF) / 0xFFFF


def blocks(x, y, width, height, salt):
    """Which block of a wall laid in courses a pixel is in, and how far it is from that
    block's edge, in pixels. Every other course is laid half a block along"""
    course = y // height
    along = (x + (width // 2 if course % 2 else 0)) % SIZE
    column = along // width
    edge = min(along % width, width - 1 - along % width, y % height, height - 1 - y % height)
    return noise(column, course, salt), edge


def brick(x, y):
    tone, edge = blocks(x, y, 16, 8, 1)
    if edge == 0 and (y % 8 == 7 or (x + (8 if (y // 8) % 2 else 0)) % 16 == 15):
        return mix(MORTAR, (0, 0, 0), 0.2 * noise(x, y, 2))
    color = mix(BRICK_DARK, BRICK, 0.35 + 0.65 * tone)
    return mix(color, (0, 0, 0), 0.18 * noise(x, y, 3) + (0.12 if edge == 0 else 0))


def stone(x, y):
    tone, edge = blocks(x, y, 32, 16, 4)
    if edge == 0 and (y % 16 == 15 or (x + (16 if (y // 16) % 2 else 0)) % 32 == 31):
        return mix(MORTAR, (0, 0, 0), 0.4)
    color = mix(STONE_DARK, STONE, 0.3 + 0.7 * tone)
    # Lit from above: the top of a block is a little brighter than the foot of it
    color = mix(color, (255, 255, 255), 0.1 * (1 - (y % 16) / 15))
    return mix(color, (0, 0, 0), 0.22 * noise(x, y, 5))


def moss(x, y):
    """Stone with something growing down it from the top and in every crack"""
    color = stone(x, y)
    _, edge = blocks(x, y, 32, 16, 4)
    patch = noise(x // 4, y // 4, 6) * 0.6 + noise(x // 2, y // 2, 7) * 0.4
    grown = clamp((patch - 0.35 - y / SIZE * 0.35) * 4) + (0.5 if edge <= 1 else 0) * noise(x, y, 8)
    return mix(color, mix(MOSS, (0, 0, 0), 0.4 * noise(x, y, 9)), clamp(grown))


def portal(x, y):
    """An arch of dark stone with light turning in it"""
    cx, cy = (x + 0.5) / SIZE * 2 - 1, (y + 0.5) / SIZE * 2 - 1
    # The opening: a round top on straight sides, down to the floor
    inside = abs(cx) < 0.62 and (cy > -0.2 or math.hypot(cx, cy + 0.2) < 0.62)
    if not inside:
        frame = abs(cx) < 0.8 and (cy > -0.2 or math.hypot(cx, cy + 0.2) < 0.8)
        if frame:
            return mix(ARCH, (0, 0, 0), 0.3 * noise(x // 2, y // 2, 10) + 0.15 * noise(x, y, 11))
        return mix(stone(x, y), (0, 0, 0), 0.35)
    radius, angle = math.hypot(cx, cy - 0.1), math.atan2(cy - 0.1, cx)
    swirl = 0.5 + 0.5 * math.sin(angle * 3 + radius * 9)
    light = clamp(1.1 - radius * 1.1) * 0.6 + swirl * 0.4
    return mix(GLOW_DEEP, GLOW, clamp(light + 0.12 * noise(x, y, 12) - 0.06))


def icon(x, y):
    """Down a corridor of brick to the way out at the end of it"""
    cx, cy = (x + 0.5) / SIZE * 2 - 1, (y + 0.5) / SIZE * 2 - 1
    reach = max(abs(cx), abs(cy))
    if reach < 0.22:
        return portal(int((cx / 0.22 * 0.6 + 1) / 2 * SIZE), int((cy / 0.22 * 0.6 + 1.1) / 2 * SIZE))
    depth = 1 / reach
    fog = clamp(1.25 - depth * 0.24)
    if abs(cx) >= abs(cy):
        # A wall to the side: along it by how deep, up it by how high
        color = brick(int(depth * 20) % SIZE, int((cy / abs(cx) + 1) * 16) % SIZE)
        return mix((0, 0, 0), color, fog * (1.0 if cx < 0 else 0.75))
    ground = (70, 62, 56) if cy > 0 else (44, 44, 54)
    return mix((0, 0, 0), ground, fog)


OUTLINE = (30, 22, 18)
FUR, FUR_PALE, EAR = (150, 116, 78), (196, 168, 124), (190, 120, 110)
CLOTH, BOOT = (92, 70, 52), (58, 44, 36)
WAX, FLAME, FLAME_CORE = (236, 226, 190), (255, 150, 40), (255, 240, 150)
WOOD, IRON, IRON_PALE = (120, 84, 50), (150, 152, 162), (214, 218, 228)
SKIN = (214, 160, 124)


class Canvas:
    """A picture with nothing on it to begin with, drawn on a shape at a time"""

    def __init__(self):
        self.pixels = {}

    def dot(self, x, y, color):
        if 0 <= x < SIZE and 0 <= y < SIZE:
            self.pixels[(x, y)] = color

    def ellipse(self, cx, cy, rx, ry, color, salt=0):
        """Lit from the top left, and a little rough"""
        for y in range(int(cy - ry) - 1, int(cy + ry) + 2):
            for x in range(int(cx - rx) - 1, int(cx + rx) + 2):
                across, down = (x + 0.5 - cx) / rx, (y + 0.5 - cy) / ry
                if across * across + down * down <= 1:
                    shade = across * 0.22 + down * 0.3 + 0.12 * (noise(x, y, salt) - 0.5)
                    self.dot(x, y, mix(color, (0, 0, 0) if shade > 0 else (255, 255, 255), clamp(abs(shade))))

    def box(self, left, top, right, bottom, color, salt=0):
        for y in range(top, bottom + 1):
            for x in range(left, right + 1):
                self.dot(x, y, mix(color, (0, 0, 0), 0.15 * noise(x, y, salt)))

    def line(self, x0, y0, x1, y1, width, color, salt=0):
        length = math.hypot(x1 - x0, y1 - y0)
        for y in range(int(min(y0, y1) - width) - 1, int(max(y0, y1) + width) + 2):
            for x in range(int(min(x0, x1) - width) - 1, int(max(x0, x1) + width) + 2):
                along = clamp(((x + 0.5 - x0) * (x1 - x0) + (y + 0.5 - y0) * (y1 - y0)) / (length * length))
                if math.hypot(x + 0.5 - x0 - along * (x1 - x0), y + 0.5 - y0 - along * (y1 - y0)) <= width / 2:
                    self.dot(x, y, mix(color, (0, 0, 0), 0.15 * noise(x, y, salt)))

    def rows(self):
        """With a dark line round everything, which is what makes it read from far away"""
        rows = []
        for y in range(SIZE):
            row = []
            for x in range(SIZE):
                color = self.pixels.get((x, y))
                if color:
                    row.append(tuple(round(clamp(c / 255) * 255) for c in color) + (255,))
                elif any((x + dx, y + dy) in self.pixels for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                    row.append(OUTLINE + (255,))
                else:
                    row.append((0, 0, 0, 0))
            rows.append(row)
        return rows


def pick(canvas, x0, y0, x1, y1):
    """A pickaxe, held at the first point with its head at the second"""
    canvas.line(x0, y0, x1, y1, 2.4, WOOD, 20)
    # The head lies across the handle
    length = math.hypot(x1 - x0, y1 - y0)
    acrossX, acrossY = -(y1 - y0) / length * 8, (x1 - x0) / length * 8
    canvas.line(x1 - acrossX, y1 - acrossY, x1 + acrossX, y1 + acrossY, 3.4, IRON, 21)
    canvas.dot(round(x1 - acrossX), round(y1 - acrossY), IRON_PALE)
    canvas.dot(round(x1 + acrossX), round(y1 + acrossY), IRON_PALE)


def kobold(pose):
    """A kobold seen from the front, a candle on its head and a pickaxe in its hand"""
    canvas = Canvas()
    if pose == "dead":
        # On its back, the candle rolled away and gone out
        pick(canvas, 30, 61, 52, 50)
        canvas.ellipse(34, 57, 15, 5, FUR, 30)
        canvas.box(26, 55, 40, 57, CLOTH, 31)
        canvas.ellipse(15, 56, 6, 5, FUR, 32)
        canvas.ellipse(10, 57, 3, 2, FUR_PALE, 33)
        canvas.ellipse(17, 50, 3, 3, EAR, 34)
        canvas.dot(14, 55, OUTLINE)
        canvas.dot(16, 53, OUTLINE)
        canvas.box(48, 59, 56, 61, WAX, 35)
        canvas.dot(57, 60, OUTLINE)
        return canvas.rows()

    step = pose == "step"
    up = -1 if step else 0
    # Legs and feet: one ahead of the other when it steps
    canvas.box(25, 52 + up, 29, 59 - (2 if step else 0), FUR, 40)
    canvas.box(34, 52 + up, 38, 59, FUR, 41)
    canvas.ellipse(26, 61 - (2 if step else 0), 4.5, 2.2, BOOT, 42)
    canvas.ellipse(37, 61, 4.5, 2.2, BOOT, 43)
    # The arm that holds nothing, behind the body
    canvas.ellipse(20, 44 + up, 3, 7, FUR, 44)
    canvas.ellipse(32, 44 + up, 10, 11, FUR, 45)
    canvas.box(24, 42 + up, 40, 52 + up, CLOTH, 46)
    canvas.box(24, 47 + up, 40, 48 + up, BOOT, 47)
    # Ears first, the head goes over where they are joined to it
    for side in (-1, 1):
        canvas.ellipse(32 + side * 10, 24 + up, 4, 6, FUR, 48)
        canvas.ellipse(32 + side * 10, 25 + up, 2, 4, EAR, 49)
    canvas.ellipse(32, 29 + up, 8, 7, FUR, 50)
    canvas.ellipse(32, 32 + up, 4.5, 3.2, FUR_PALE, 51)
    canvas.box(31, 30 + up, 32, 30 + up, OUTLINE)
    for side in (-1, 1):
        canvas.box(32 + side * 4 - 1, 26 + up, 32 + side * 4, 27 + up, FLAME_CORE)
        canvas.dot(32 + side * 4 - (1 if side < 0 else 0), 27 + up, OUTLINE)
    if pose == "swing":
        # Mouth open, and what teeth there are
        canvas.box(30, 33, 33, 34, OUTLINE)
        canvas.dot(31, 33, IRON_PALE)
    # The candle, which nobody takes
    canvas.box(30, 15 + up, 33, 22 + up, WAX, 52)
    canvas.ellipse(32, 11 + up, 2.4, 3.6, FLAME, 53)
    canvas.ellipse(32, 12 + up, 1.1, 1.8, FLAME_CORE, 54)
    # The arm with the pickaxe: at its side, or up and coming down
    if pose == "swing":
        canvas.ellipse(45, 36, 3, 7, FUR, 55)
        pick(canvas, 46, 32, 40, 8)
    else:
        canvas.ellipse(44, 44 + up, 3, 7, FUR, 55)
        pick(canvas, 45, 51 + up, 52, 26 + up)
    return canvas.rows()


def sword(swung):
    """What the player holds, seen from behind it: a hand low on the right and the blade going
    up from it, or across to the left once it has been swung"""
    canvas = Canvas()
    hand, guard, tip = ((46, 66), (39, 52), (10, 30)) if swung else ((52, 66), (46, 50), (36, 6))
    length = math.hypot(tip[0] - guard[0], tip[1] - guard[1])
    alongX, alongY = (tip[0] - guard[0]) / length, (tip[1] - guard[1]) / length
    canvas.line(guard[0], guard[1], tip[0], tip[1], 6, IRON, 60)
    canvas.line(guard[0], guard[1], tip[0] - alongX * 3, tip[1] - alongY * 3, 1.6, IRON_PALE, 61)
    canvas.line(guard[0] + alongY * 9, guard[1] - alongX * 9, guard[0] - alongY * 9, guard[1] + alongX * 9, 3.4, FLAME, 62)
    canvas.line(hand[0], hand[1], guard[0], guard[1], 4, WOOD, 63)
    canvas.ellipse((hand[0] + guard[0]) / 2 + 1, (hand[1] + guard[1]) / 2 + 2, 6, 5.5, SKIN, 64)
    return canvas.rows()


def bolt():
    """A ball of light at the height of the eye. White: the game gives it the colour of whoever cast it"""
    rows = []
    for y in range(SIZE):
        row = []
        for x in range(SIZE):
            away = math.hypot(x + 0.5 - 32, y + 0.5 - 32)
            alpha = clamp(1.5 - away / 6)
            bright = 255 if away < 4 else round(255 - 70 * clamp((away - 4) / 5))
            row.append((bright, bright, bright, round(alpha * 255)) if alpha > 0 else (0, 0, 0, 0))
        rows.append(row)
    return rows


def potion(liquid):
    """A round bottle on the floor"""
    canvas = Canvas()
    canvas.box(29, 41, 34, 47, (200, 220, 230), 70)
    canvas.box(29, 38, 34, 40, WOOD, 71)
    canvas.ellipse(32, 54, 8.5, 8, liquid, 72)
    canvas.box(27, 50, 28, 52, (255, 255, 255))
    return canvas.rows()


def totem():
    """A post with a face cut into it and a fire on top"""
    canvas = Canvas()
    canvas.box(26, 32, 37, 62, WOOD, 80)
    canvas.box(24, 60, 39, 62, BOOT, 81)
    canvas.box(26, 44, 37, 45, BOOT, 82)
    for side in (-1, 1):
        canvas.box(31 + side * 3, 36, 32 + side * 3, 38, FLAME_CORE)
        canvas.line(32 + side * 6, 28, 32 + side * 10, 22, 3, WOOD, 83)
    canvas.box(29, 41, 34, 41, OUTLINE)
    canvas.box(28, 50, 35, 51, (170, 60, 40), 84)
    canvas.box(28, 55, 35, 56, (60, 110, 150), 85)
    canvas.ellipse(32, 25, 5, 7.5, FLAME, 86)
    canvas.ellipse(32, 27, 2.4, 4, FLAME_CORE, 87)
    return canvas.rows()


def bow(loosed):
    """A bow held up on the right, an arrow on the string until it is let go"""
    canvas = Canvas()
    belly = 30 if loosed else 26
    # The stave, bent: a few straight pieces along it
    points = [(46 + (belly - 46) * math.sin(math.pi * t / 8), 6 + t * 7.4) for t in range(9)]
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        canvas.line(x0, y0, x1, y1, 3.4, WOOD, 90)
    if loosed:
        canvas.line(46, 6, 46, 65, 1, IRON_PALE, 91)
    else:
        canvas.line(46, 6, 56, 40, 1, IRON_PALE, 91)
        canvas.line(56, 40, 46, 65, 1, IRON_PALE, 91)
        canvas.line(56, 40, 14, 26, 1.8, FUR_PALE, 92)
        canvas.line(17, 27, 11, 25, 3.2, IRON, 93)
    canvas.ellipse(belly + 1, 36, 5, 6, SKIN, 94)
    return canvas.rows()


def staff(cast):
    """A staff with a stone at the head of it, held up or thrust ahead with the stone alight"""
    canvas = Canvas()
    hand, head = ((44, 66), (26, 24)) if cast else ((52, 66), (44, 14))
    canvas.line(hand[0], hand[1], head[0], head[1], 3.6, WOOD, 100)
    canvas.ellipse(hand[0] + (head[0] - hand[0]) * 0.3, hand[1] + (head[1] - hand[1]) * 0.3, 5.5, 5.5, SKIN, 101)
    if cast:
        for spoke in range(8):
            angle = spoke * math.pi / 4
            canvas.line(head[0], head[1], head[0] + math.cos(angle) * 11, head[1] + math.sin(angle) * 11, 1.4, (255, 255, 255))
    canvas.ellipse(head[0], head[1], 7 if cast else 4.5, 7 if cast else 4.5, (255, 255, 255) if cast else (200, 208, 230), 102)
    return canvas.rows()


def claws(swung):
    """A cat's paw, and what it leaves in the air when it has struck"""
    canvas = Canvas()
    paw = (28, 52) if swung else (46, 58)
    if swung:
        for claw in range(3):
            canvas.line(52 - claw * 9, 14 + claw * 3, 30 - claw * 9, 44 + claw * 3, 1.8, (255, 255, 255))
    canvas.ellipse(paw[0] + 4, paw[1] + 8, 9, 9, (196, 142, 72), 110)
    canvas.ellipse(paw[0], paw[1], 10, 8, (196, 142, 72), 111)
    for claw in range(3):
        x, y = paw[0] - 7 + claw * 6, paw[1] - 6 + abs(claw - 1) * 2
        canvas.line(x, y, x - 4, y - 9, 2.2, IRON_PALE, 112)
    return canvas.rows()


def beside(*pictures):
    """Several pictures as one, next to each other"""
    return [sum((picture[y] for picture in pictures), []) for y in range(SIZE)]


def render(paint):
    return [[tuple(round(clamp(c / 255) * 255) for c in paint(x, y)) + (255,) for x in range(SIZE)] for y in range(SIZE)]


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
for name, paint in (("brick", brick), ("stone", stone), ("moss", moss), ("portal", portal)):
    write(target / "Warcraftstein" / (name + ".tga"), render(paint), preview)
sprites = [kobold(pose) for pose in ("stand", "step", "swing", "dead")] + [bolt(), potion((200, 40, 44)), potion((50, 96, 224)), totem()]
write(target / "Warcraftstein" / "sprites.tga", beside(*sprites), preview)
weapons = [held(swung) for held in (sword, bow, staff, claws) for swung in (False, True)]
write(target / "Warcraftstein" / "weapons.tga", beside(*weapons), preview)
write(target / "Icons" / "warcraftstein.tga", render(icon), preview)
