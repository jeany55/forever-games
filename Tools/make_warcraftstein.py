#!/usr/bin/env python3
"""Draws Warcraftstein 3D (Games/Warcraftstein.lua): the Scarlet Monastery, who is in it, and its icon.

    python3 Tools/make_warcraftstein.py Images

Writes Images/Warcraftstein/<name>.tga. The walls are 128 pixels square, one bay of the
cathedral each, between two halves of a pillar under a pointed arch, so that a wall of them in a
row is an arcade: nave (bare stone), window (stained glass), banner (the Crusade's), library
(shelves of books), armory (a shield and swords), crypt (the graveyard's rough stone, without
the arcade), portal (the way out) and shrine (the sanctuary's: a window of the Light, candles
under it). Then floor and ceiling, which the game tiles: a
chequered floor, and the ribs of a vault.

Then sprites, everything that stands in the monastery, 64 pixels square each and eight to a row
of a 512 pixel square sheet. Row by row: a bolt of magic, a potion for health and one for power,
a totem, a brazier, a candelabra, a tombstone and a lectern; then a Scarlet soldier and a
Scarlet monk, an adept and a defender, Herod and a phantasm, four pictures of each (standing,
stepping, striking, dead); then a banner on a pole, and the sanctuary's fountain twice, its
water a moment apart. And weapons, what the player holds, ready
and swung: a sword, a bow, a staff and claws. Also Images/Icons/warcraftstein.tga, a look down
the nave. Only the standard library is used. Pass a second folder to also get PNG copies there,
which are easier to look at than TGA.

Everything is drawn a pixel at a time and never smoothed: the game shows a wall a column of the
picture at a time, as wide and as tall as it is near, and it is meant to look like it. A sprite
is shown the same way, so its picture is as tall as a wall is, with the floor at the foot of it
and nothing where there is nobody.
"""
import math
import struct
import sys
import zlib
from pathlib import Path

SIZE, WALL = 64, 128

# The cathedral: pale stone, red and gold
STONE, STONE_DARK, STONE_PALE = (206, 194, 168), (150, 138, 116), (232, 224, 204)
MORTAR = (122, 110, 92)
RED, RED_DARK, GOLD, GOLD_DARK = (176, 26, 30), (100, 12, 18), (232, 186, 76), (150, 108, 34)
WHITE = (238, 234, 222)
GLASS = [(206, 34, 40), (240, 184, 60), (52, 92, 200), (236, 120, 40), (250, 226, 140), (140, 20, 40), (80, 150, 210)]
LEAD = (34, 28, 30)
CRYPT, CRYPT_DARK, MOSS = (96, 96, 104), (54, 54, 62), (70, 104, 56)
GLOW, GLOW_DEEP = (170, 235, 255), (28, 60, 160)
TILE_PALE, TILE_RED = (198, 186, 160), (128, 48, 44)
RIB, VAULT = (132, 118, 98), (44, 38, 42)

OUTLINE = (26, 20, 20)
WAX, FLAME, FLAME_CORE = (236, 226, 190), (255, 150, 40), (255, 240, 150)
WOOD, WOOD_DARK, IRON, IRON_DARK, IRON_PALE = (120, 80, 46), (72, 44, 26), (150, 152, 162), (84, 86, 98), (214, 218, 228)
SKIN, SKIN_DARK = (222, 172, 136), (176, 124, 96)
CHAIN, PLATE = (128, 130, 140), (196, 198, 210)
GHOST, GHOST_DEEP = (200, 232, 255), (110, 160, 210)
BOOT, FUR_PALE = WOOD_DARK, (196, 168, 124)


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def clamp(value):
    return max(0.0, min(1.0, value))


def noise(x, y, salt=0):
    """A number from 0 to 1 that is always the same for the same pixel"""
    n = (x * 374761393 + y * 668265263 + salt * 2147483647) & 0xFFFFFFFF
    n = ((n ^ (n >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((n ^ (n >> 16)) & 0xFFFF) / 0xFFFF


def grain(color, x, y, salt, amount=0.12):
    """A little roughness, the same for the same pixel"""
    return mix(color, (0, 0, 0), amount * noise(x, y, salt) + amount * 0.5 * noise(x // 3, y // 3, salt + 1))


def blocks(x, y, width, height, period, salt):
    """Which block of a wall laid in courses a pixel is in, and how far it is from that
    block's edge, in pixels. Every other course is laid half a block along"""
    course = y // height
    along = (x + (width // 2 if course % 2 else 0)) % period
    column = along // width
    edge = min(along % width, width - 1 - along % width, y % height, height - 1 - y % height)
    return noise(column, course, salt), edge


def ashlar(x, y, salt=1):
    """Blocks of pale stone"""
    tone, edge = blocks(x, y, 32, 16, WALL, salt)
    if edge == 0:
        return grain(MORTAR, x, y, salt + 2, 0.2)
    color = mix(STONE_DARK, STONE, 0.45 + 0.55 * tone)
    color = mix(color, STONE_PALE, 0.12 * (1 - (y % 16) / 15))
    return grain(color, x, y, salt + 3)


# -----------------------------------------------------------------------------
# Walls: a bay of the arcade
# -----------------------------------------------------------------------------
# Half a pillar on either side, with a capital where the arch springs from it and a plinth at
# its foot, and a pointed arch between them. What is in the bay is up to the wall.
PILLAR, SPRING, PLINTH = 11, 70, 114


def arch(x, inset=0):
    """How far down the arch is above a column of the bay, measured from the top: two arcs that
    meet in a point in the middle"""
    radius, half = 70 - inset, 64 - PILLAR - inset
    centre = 64 - half + radius if x <= 64 else 64 + half - radius
    reach = radius * radius - (x + 0.5 - centre) ** 2
    if reach < 0:
        return WALL
    return SPRING - math.sqrt(reach)


def inside(x, y, inset=0):
    """Whether a pixel is in the bay, under the arch, this far in from its edges"""
    return PILLAR + inset <= x < WALL - PILLAR - inset and arch(x, inset) + inset * 0.3 <= y < PLINTH - inset


def bay(x, y, fill, salt=0):
    """A bay of the arcade with something in it"""
    edge = min(x, WALL - 1 - x)
    if y >= PLINTH:
        # The plinth that runs along the foot of every wall, red with a gold line along its top
        if y == PLINTH:
            return GOLD
        return grain(mix(RED_DARK, (40, 8, 10), (y - PLINTH) / 14), x, y, salt + 40)
    if edge < PILLAR:
        # Round, lit from in front: brightest down the middle of it, which is the edge of the bay
        light = math.cos(edge / PILLAR * math.pi / 2)
        color = mix(STONE_DARK, STONE_PALE, 0.25 + 0.75 * light)
        if SPRING - 6 <= y < SPRING:
            color = mix(GOLD_DARK, GOLD, light) if y != SPRING - 6 else STONE_PALE
        elif y >= PLINTH - 6:
            color = mix(color, STONE_DARK, 0.4)
        return grain(color, x, y, salt + 41, 0.08)
    top = arch(x)
    if y < top - 4:
        # The wall above the arch
        return mix(ashlar(x, y, salt + 5), STONE_DARK, 0.15)
    if y < top:
        # The moulding round the arch: lit along its top, in shadow along its foot
        return mix(STONE_PALE, STONE_DARK, (y - (top - 4)) / 4)
    color = fill(x, y)
    # The bay is set back: in shadow near the arch and the pillars
    shade = clamp(1 - min(y - top, edge - PILLAR) / 6) * 0.35
    return mix(color, (20, 14, 12), shade)


def nave(x, y):
    return bay(x, y, lambda x, y: mix(ashlar(x, y), STONE_DARK, 0.1))


def window(x, y):
    """Stained glass in two lights under a rose, between stone mullions"""

    def glass(x, y):
        if not inside(x, y, 12):
            return mix(ashlar(x, y), STONE_DARK, 0.1)
        if not inside(x, y, 14):
            return STONE_PALE
        # The rose at the top, petals of red and gold round a white heart
        rose = math.hypot(x + 0.5 - 64, y + 0.5 - 40)
        if rose < 15:
            if rose < 4:
                return (255, 246, 210)
            if abs(rose - 15) < 1.2 or abs(rose - 4) < 1:
                return LEAD
            petal = int((math.atan2(y + 0.5 - 40, x + 0.5 - 64) + math.pi) / (math.pi * 2) * 8)
            if abs(((math.atan2(y + 0.5 - 40, x + 0.5 - 64) + math.pi) / (math.pi * 2) * 8) - round((math.atan2(y + 0.5 - 40, x + 0.5 - 64) + math.pi) / (math.pi * 2) * 8)) < 0.08:
                return LEAD
            return mix(GLASS[petal % 2 and 1 or 0], (255, 255, 255), 0.25 * clamp(1 - rose / 15))
        if abs(rose - 16.5) < 1.5:
            return STONE_PALE
        # Below it, two lights either side of a mullion
        if 62 <= x <= 65 and y > 56:
            return mix(STONE_PALE, STONE_DARK, 0.2 if x > 63 else 0)
        if y > 56 and (x % 9 == 0 or y % 10 == 0):
            return LEAD
        pane = GLASS[int(noise(x // 9, y // 10, 7) * len(GLASS))]
        # Light comes through brightest in the middle of the window
        return mix(pane, (255, 250, 230), 0.1 + 0.2 * clamp(1 - abs(x - 64) / 40) + 0.15 * noise(x, y, 8))

    return bay(x, y, glass)


def emblem(x, y, cx, cy, size):
    """The Crusade's: a flame in white on a ring of gold. None where the pixel isn't on it"""
    away = math.hypot(x + 0.5 - cx, y + 0.5 - cy)
    if abs(away - size) < size * 0.18:
        return GOLD
    if away < size * 0.82:
        # A flame, round at the foot and pointed at the top
        dx, dy = (x + 0.5 - cx) / size, (y + 0.5 - cy) / size
        width = 0.42 * clamp((dy + 0.75) / 0.9) if dy < 0.15 else math.sqrt(max(0, 0.42 ** 2 - (dy - 0.15) ** 2 * 1.4))
        if abs(dx + 0.12 * math.sin(dy * 5)) < width:
            return WHITE
        return RED
    return None


def banner(x, y):
    """The Crusade's banner hanging in the bay"""

    def cloth(x, y):
        if 33 <= x <= 95 and 20 <= y <= 23:
            return IRON_DARK if 36 < x < 92 else GOLD
        if 38 <= x <= 90 and 23 < y <= 106:
            # Swallow-tailed at the foot
            if y > 92 and abs(x + 0.5 - 64) < (y - 92) * 1.4:
                return mix(ashlar(x, y), STONE_DARK, 0.1)
            if x - 38 < 3 or 90 - x < 3 or (y > 89 and y - 89 < 3 and abs(x + 0.5 - 64) >= (y - 92) * 1.4 + 3):
                return GOLD
            mark = emblem(x, y, 64, 54, 16)
            if mark:
                return mark
            folds = 0.12 * math.sin((x - 38) / 52 * math.pi * 3)
            return grain(mix(RED, (0, 0, 0) if folds > 0 else (255, 220, 200), abs(folds)), x, y, 9, 0.08)
        return mix(ashlar(x, y), STONE_DARK, 0.1)

    return bay(x, y, cloth)


def library(x, y):
    """Shelves of books in the bay, up to the arch"""

    def shelves(x, y):
        if not inside(x, y, 4):
            return grain(WOOD_DARK, x, y, 20)
        shelf = (y - 30) // 21
        within = (y - 30) % 21
        if y < 30 or within < 3:
            return grain(WOOD, x, y, 21) if within < 3 and y >= 30 else grain(mix(WOOD_DARK, (0, 0, 0), 0.4), x, y, 22)
        # Books of every size and colour, side by side
        position, book = PILLAR + 4, 0
        while position <= x:
            book += 1
            position += 4 + int(noise(book, shelf, 23) * 6)
        width = 4 + int(noise(book, shelf, 23) * 6)
        if x == position - 1:
            return (20, 14, 10)
        tall = 10 + int(noise(book, shelf, 24) * 8)
        if within < 21 - tall:
            return (24, 16, 12)
        color = [RED_DARK, (40, 70, 44), (40, 52, 100), (110, 70, 36), (90, 30, 70), (150, 120, 70)][int(noise(book, shelf, 25) * 6)]
        if within in (21 - tall + 3, 21 - 4):
            return GOLD_DARK
        light = 1 - abs((x - (position - width)) / max(1, width - 1) - 0.4)
        return grain(mix(color, (255, 255, 255), 0.15 * light), x, y, 26, 0.1)

    return bay(x, y, shelves)


def armory(x, y):
    """A shield with the Crusade on it over two crossed swords"""

    def arms(x, y):
        # The shield: square at the top, coming to a point at the foot
        half = 22 if y < 66 else 22 * clamp((104 - y) / 38) ** 0.8
        if 32 <= y <= 104 and abs(x + 0.5 - 64) < half:
            if abs(x + 0.5 - 64) > half - 3 or y < 35:
                return GOLD
            mark = emblem(x, y, 64, 60, 13)
            return mark or grain(RED, x, y, 30, 0.08)
        for direction in (-1, 1):
            # A blade from low on one side to high on the other, its hilt sticking out below
            dx, dy = x + 0.5 - (64 - direction * 34), y + 0.5 - 98
            along = (dx * direction * 0.72 - dy * 0.7)
            across = abs(dx * 0.7 + dy * direction * 0.72)
            if -12 < along < 84 and across < (2.6 if along > 0 else 1.6):
                if along < 0:
                    return grain(WOOD_DARK, x, y, 31)
                if along < 3:
                    return GOLD
                return mix(IRON, IRON_PALE, 0.6 if across < 1 else 0)
            if 0 <= along < 3 and across < 8:
                return GOLD
        return mix(ashlar(x, y), STONE_DARK, 0.1)

    return bay(x, y, arms)


def crypt(x, y):
    """Rough dark stone, with moss where the damp comes up and a niche with a skull in it"""
    tone, edge = blocks(x, y, 26, 20, WALL + 2, 50)
    color = grain(mix(CRYPT_DARK, CRYPT, 0.35 + 0.65 * tone), x, y, 51, 0.2)
    if edge == 0:
        color = grain(mix(CRYPT_DARK, (0, 0, 0), 0.4), x, y, 52)
    growth = noise(x // 4, y // 4, 53) * 0.6 + noise(x // 2, y // 2, 54) * 0.4 - (1 - y / WALL) * 0.9
    if growth > 0.05:
        color = mix(color, grain(MOSS, x, y, 55, 0.3), clamp(growth * 3))
    # The niche
    dx, dy = x + 0.5 - 64, y + 0.5 - 62
    if abs(dx) < 16 and (dy > -6 or math.hypot(dx, dy + 6) < 16) and dy < 22:
        color = mix((14, 12, 14), color, 0.12)
        skull = math.hypot(dx / 9, (dy - 10) / 8)
        if skull < 1 or (abs(dx) < 5 and 16 < dy < 21):
            eye = min(math.hypot(dx - 3.5, dy - 10), math.hypot(dx + 3.5, dy - 10))
            color = (20, 16, 16) if eye < 2.4 or (abs(dx) < 1 and 13 < dy < 15) else grain((220, 212, 190), x, y, 56)
    return color


def portal(x, y):
    """The way out: light turning in the arch, in a frame of gold"""

    def light(x, y):
        if not inside(x, y, 4):
            return GOLD if inside(x, y, 1) else STONE_PALE
        cx, cy = (x + 0.5 - 64) / 50, (y + 0.5 - 70) / 50
        radius, angle = math.hypot(cx, cy), math.atan2(cy, cx)
        swirl = 0.5 + 0.5 * math.sin(angle * 3 + radius * 9)
        glow = clamp(1.1 - radius * 1.1) * 0.6 + swirl * 0.4
        return mix(GLOW_DEEP, GLOW, clamp(glow + 0.12 * noise(x, y, 12) - 0.06))

    return bay(x, y, light)


def shrine(x, y):
    """The sanctuary: a window of the Light, a sun of gold and white glass, and candles below"""

    def light(x, y):
        if y >= 98 and inside(x, y, 6):
            # The ledge, and candles on it
            if y < 101:
                return grain(STONE_PALE, x, y, 90)
            for candle in (30, 46, 82, 98):
                if abs(x + 0.5 - candle) < 2 and y > 104:
                    return WAX
                if math.hypot(x + 0.5 - candle, y + 0.5 - 101) < 2.2:
                    return FLAME_CORE if math.hypot(x + 0.5 - candle, y + 0.5 - 101.5) < 1.2 else FLAME
            return mix(ashlar(x, y), STONE_DARK, 0.1)
        if not inside(x, y, 10):
            return mix(ashlar(x, y), STONE_PALE, 0.25)
        if not inside(x, y, 13):
            return GOLD
        # Rays of glass from a sun in the middle, gold and white by turns
        cx, cy = x + 0.5 - 64, y + 0.5 - 56
        away, angle = math.hypot(cx, cy), math.atan2(cy, cx)
        if away < 9:
            return (255, 252, 236)
        if abs(away - 9.5) < 1:
            return GOLD_DARK
        ray = (angle + math.pi) / (math.pi * 2) * 16
        if abs(ray - round(ray)) < 0.07 or abs(away - 30) < 0.8:
            return LEAD
        color = [(255, 214, 90), (255, 246, 214), (246, 186, 64), (255, 236, 170)][int(ray) % 4]
        return mix(color, (255, 255, 255), 0.35 * clamp(1 - away / 40) + 0.1 * noise(x, y, 91))

    return bay(x, y, light)


# -----------------------------------------------------------------------------
# Floor and ceiling, tiled across the monastery: one picture to a square of it
# -----------------------------------------------------------------------------


def floor(x, y):
    """Chequered stone, worn"""
    tile = (x // 32 + y // 32) % 2
    edge = min(x % 32, 31 - x % 32, y % 32, 31 - y % 32)
    color = TILE_RED if tile else TILE_PALE
    color = mix(color, (255, 255, 255) if tile == 0 else (200, 120, 110), 0.12 * noise(x // 32, y // 32, 60))
    if edge == 0:
        return grain(MORTAR, x, y, 61, 0.3)
    color = mix(color, (0, 0, 0), 0.12 if edge == 1 else 0)
    # Scuffs and a crack now and then
    if noise(x // 32, y // 32, 62) > 0.75 and abs((x % 32) - (y % 32) * 0.6 - 8) < 0.8:
        color = mix(color, (0, 0, 0), 0.35)
    return grain(color, x, y, 63, 0.14)


def ceiling(x, y):
    """The ribs of a vault crossing between bosses, and the shadow up between them"""
    u, v = x / WALL, y / WALL
    rib = min(abs(u - v), abs(u + v - 1), abs(u - 0.5) * 2, abs(v - 0.5) * 2, u, 1 - u, v, 1 - v)
    if rib < 0.03:
        # Lit along the middle of the rib, in shadow at its edges
        return grain(mix(RIB, mix(RIB, STONE_PALE, 0.4), 1 - rib / 0.03), x, y, 70, 0.1)
    if math.hypot(u - 0.5, v - 0.5) < 0.06:
        return GOLD
    # Darker up into the middle of every quarter, which is the highest
    depth = clamp(rib * 5)
    return grain(mix(mix(VAULT, (96, 82, 74), 0.6), VAULT, depth), x, y, 71, 0.12)


def icon(x, y):
    """Down the nave to the way out at the end of it"""
    cx, cy = (x + 0.5) / SIZE * 2 - 1, (y + 0.5) / SIZE * 2 - 1
    reach = max(abs(cx), abs(cy))
    if reach < 0.24:
        return portal(int((cx / 0.24 + 1) / 2 * WALL), int((cy / 0.24 + 1) / 2 * WALL))
    depth = 1 / reach
    fog = clamp(1.3 - depth * 0.2)
    if abs(cx) >= abs(cy):
        # A wall to the side: along it by how deep, up it by how high. Every other bay a window
        along = int(depth * 40) % WALL
        up = int((cy / abs(cx) + 1) / 2 * WALL) % WALL
        color = (window if int(depth * 40) // WALL % 2 else banner)(along, up)
        return mix((0, 0, 0), color, fog * (1.0 if cx < 0 else 0.8))
    plane = floor if cy > 0 else ceiling
    return mix((0, 0, 0), plane(int(cx / abs(cy) * depth * 20) % WALL, int(depth * 40) % WALL), fog)


# -----------------------------------------------------------------------------
# Sprites
# -----------------------------------------------------------------------------


class Canvas:
    """A picture with nothing on it to begin with, drawn on a shape at a time"""

    def __init__(self):
        self.pixels = {}

    def dot(self, x, y, color, alpha=255):
        x, y = int(x), int(y)
        if 0 <= x < SIZE and 0 <= y < SIZE:
            self.pixels[(x, y)] = (color, alpha)

    def ellipse(self, cx, cy, rx, ry, color, salt=0, alpha=255):
        """Lit from the top left, and a little rough"""
        for y in range(int(cy - ry) - 1, int(cy + ry) + 2):
            for x in range(int(cx - rx) - 1, int(cx + rx) + 2):
                across, down = (x + 0.5 - cx) / rx, (y + 0.5 - cy) / ry
                if across * across + down * down <= 1:
                    shade = across * 0.22 + down * 0.3 + 0.1 * (noise(x, y, salt) - 0.5)
                    self.dot(x, y, mix(color, (0, 0, 0) if shade > 0 else (255, 255, 255), clamp(abs(shade))), alpha)

    def box(self, left, top, right, bottom, color, salt=0, alpha=255):
        for y in range(int(top), int(bottom) + 1):
            for x in range(int(left), int(right) + 1):
                # Rounded a little, lit from the left
                light = 0.12 * (1 - (x - left) / max(1, right - left)) - 0.06
                self.dot(x, y, mix(mix(color, (255, 255, 255) if light > 0 else (0, 0, 0), abs(light)), (0, 0, 0), 0.12 * noise(x, y, salt)), alpha)

    def line(self, x0, y0, x1, y1, width, color, salt=0, alpha=255):
        length = max(0.01, math.hypot(x1 - x0, y1 - y0))
        for y in range(int(min(y0, y1) - width) - 1, int(max(y0, y1) + width) + 2):
            for x in range(int(min(x0, x1) - width) - 1, int(max(x0, x1) + width) + 2):
                along = clamp(((x + 0.5 - x0) * (x1 - x0) + (y + 0.5 - y0) * (y1 - y0)) / (length * length))
                if math.hypot(x + 0.5 - x0 - along * (x1 - x0), y + 0.5 - y0 - along * (y1 - y0)) <= width / 2:
                    self.dot(x, y, mix(color, (0, 0, 0), 0.12 * noise(x, y, salt)), alpha)

    def shape(self, test, color, salt=0, alpha=255):
        """Every pixel a test says is in it"""
        for y in range(SIZE):
            for x in range(SIZE):
                if test(x + 0.5, y + 0.5):
                    self.dot(x, y, mix(color, (0, 0, 0), 0.12 * noise(x, y, salt)), alpha)

    def rows(self, outline=True):
        """With a dark line round everything, which is what makes it read from far away"""
        rows = []
        for y in range(SIZE):
            row = []
            for x in range(SIZE):
                pixel = self.pixels.get((x, y))
                if pixel:
                    color, alpha = pixel
                    row.append(tuple(round(clamp(c / 255) * 255) for c in color) + (alpha,))
                elif outline and any(self.pixels.get((x + dx, y + dy), (0, 0))[1] == 255 for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                    row.append(OUTLINE + (255,))
                else:
                    row.append((0, 0, 0, 0))
            rows.append(row)
        return rows


def flame(canvas, cx, cy, size):
    canvas.ellipse(cx, cy, size * 0.55, size, FLAME, 80)
    canvas.ellipse(cx, cy + size * 0.25, size * 0.28, size * 0.55, FLAME_CORE, 81)


def tabard_mark(canvas, cx, cy, size):
    for y in range(int(cy - size) - 1, int(cy + size) + 2):
        for x in range(int(cx - size) - 1, int(cx + size) + 2):
            mark = emblem(x, y, cx, cy, size)
            if mark:
                canvas.dot(x, y, mark)


def person(pose, look):
    """Someone of the Crusade, from the front. `look` says how big they are and what they wear:
    scale, cloth (robe or tabard), under (mail, plate), head (helm, hood, bald), held (sword,
    mace, axe, fists, flame), shield"""
    canvas = Canvas()
    s, cx, ground = look["scale"], 32, 63
    wide = look.get("wide", 1.0)
    cloth, under = look["cloth"], look.get("under", look["cloth"])
    held = look.get("held")

    if pose == "dead":
        # Fallen on their back, feet towards whoever looks
        canvas.ellipse(34, ground - 5 * s, 20 * s * wide, 5.5 * s, under, 90)
        canvas.box(24, ground - 9 * s, 44, ground - 2, cloth, 91)
        if look.get("mark"):
            tabard_mark(canvas, 34, ground - 6 * s, 3.2 * s)
        head = look.get("head")
        canvas.ellipse(34 - 21 * s * wide, ground - 6 * s, 5.5 * s, 4.5 * s, IRON if head == "helm" else (RED if head == "hood" else SKIN), 92)
        if held in ("sword", "axe", "mace"):
            canvas.line(40, ground - 1, 60, ground - 7, 2.4, IRON, 93)
        if look.get("shield"):
            canvas.ellipse(16, ground - 3, 8 * s, 3 * s, RED, 94)
        return canvas.rows()

    step = pose == "step"
    bob = -1 if step else 0
    hip = ground - 17 * s + bob
    shoulder = hip - 18 * s
    neck = shoulder - 2 * s
    # Legs and boots, one lifted when stepping, and a monk's kick
    kick = pose == "swing" and held == "fists"
    for side in (-1, 1):
        lift = (3 * s if step and side < 0 else 0)
        foot = ground - lift
        if kick and side > 0:
            canvas.line(cx + 4 * s, hip + 2, cx + 16 * s, hip + 4 * s, 5 * s, look.get("legs", under), 95)
            canvas.ellipse(cx + 18 * s, hip + 4 * s, 3.5 * s, 3 * s, look.get("boots", WOOD_DARK), 96)
            continue
        canvas.box(cx + side * 4.5 * s * wide - 2.5 * s, hip, cx + side * 4.5 * s * wide + 2.5 * s, foot - 2 * s, look.get("legs", under), 97)
        canvas.ellipse(cx + side * 4.5 * s * wide, foot - 1.5 * s, 3.8 * s, 2 * s, look.get("boots", WOOD_DARK), 98)
    # A robe falls to the ankles
    if look.get("robe"):
        canvas.shape(lambda x, y: hip - 4 * s <= y <= ground - 3 * s and abs(x - cx) < (8 + (y - hip) * 0.25) * s * wide, cloth, 99)
        canvas.shape(lambda x, y: hip - 4 * s <= y <= ground - 3 * s and abs(x - cx) < 1.5 * s, look.get("trim", GOLD), 100)
    # The arm that holds nothing (or the shield), behind
    canvas.ellipse(cx - 11 * s * wide, shoulder + 8 * s, 3.2 * s, 8 * s, under, 101)
    # The body, and over it the tabard or robe
    canvas.ellipse(cx, shoulder + 9 * s, 10 * s * wide, 11 * s, under, 102)
    if look.get("tabard"):
        canvas.box(cx - 6 * s * wide, shoulder + 1, cx + 6 * s * wide, hip + 7 * s, cloth, 103)
        canvas.box(cx - 6 * s * wide, shoulder + 1, cx + 6 * s * wide, shoulder + 2, GOLD)
        tabard_mark(canvas, cx, shoulder + 9 * s, 4.2 * s)
    elif look.get("robe"):
        canvas.ellipse(cx, shoulder + 9 * s, 9.5 * s * wide, 10.5 * s, cloth, 104)
        canvas.box(cx - 8 * s * wide, hip - 3 * s, cx + 8 * s * wide, hip - 2 * s, look.get("sash", RED), 105)
    if look.get("pauldrons"):
        for side in (-1, 1):
            canvas.ellipse(cx + side * 10 * s * wide, shoulder + 2 * s, 5 * s, 3.5 * s, look["pauldrons"], 106)
    # The head
    head, hy = look.get("head"), neck - 6 * s
    if head == "hood":
        canvas.ellipse(cx, hy - 0.5 * s, 7.5 * s, 8 * s, cloth, 107)
        canvas.ellipse(cx, hy + 1 * s, 4.5 * s, 5 * s, (30, 14, 14), 108)
        for side in (-1, 1):
            canvas.dot(cx + side * 2 * s, hy + 0.5 * s, FLAME_CORE)
    else:
        canvas.ellipse(cx, hy, 6 * s, 6.8 * s, SKIN, 109)
        for side in (-1, 1):
            canvas.dot(cx + side * 2.2 * s, hy - 0.5 * s, OUTLINE)
        canvas.box(cx - 1.5 * s, hy + 3 * s, cx + 1.5 * s, hy + 3 * s, SKIN_DARK)
        if look.get("beard"):
            canvas.shape(lambda x, y: hy + 1.5 * s <= y <= hy + 9 * s and abs(x - cx) < (5.5 - (y - hy - 1.5 * s) * 0.45) * s, look["beard"], 110)
            canvas.box(cx - 1.5 * s, hy + 3 * s, cx + 1.5 * s, hy + 3.5 * s, (60, 20, 16))
        if head == "helm":
            canvas.shape(lambda x, y: y < hy - 0.5 * s and (x - cx) ** 2 / (6.6 * s) ** 2 + (y - hy) ** 2 / (7.4 * s) ** 2 <= 1, IRON, 111)
            canvas.box(cx - 0.7 * s, hy - 1 * s, cx + 0.7 * s, hy + 2.5 * s, IRON_DARK)
        elif head == "bald":
            canvas.dot(cx - 2 * s, hy - 4 * s, (255, 230, 210))
    # The arm that strikes, and what it holds
    if pose == "swing" and held not in ("fists",):
        hand = (cx + 10 * s * wide, shoulder - 6 * s)
        canvas.line(cx + 9 * s * wide, shoulder + 3 * s, hand[0], hand[1], 5 * s, under, 112)
    else:
        hand = (cx + 12 * s * wide, shoulder + 14 * s)
        canvas.ellipse(cx + 11.5 * s * wide, shoulder + 8 * s, 3.2 * s, 8 * s, under, 113)
    if held == "sword":
        tip = (hand[0] - 6 * s, hand[1] - 22 * s) if pose == "swing" else (hand[0] + 7 * s, hand[1] - 20 * s)
        canvas.line(hand[0], hand[1], tip[0], tip[1], 2.6 * s, IRON_PALE, 114)
        canvas.line(hand[0] - 3 * s, hand[1] - 1 * s, hand[0] + 3 * s, hand[1] + 1 * s, 1.8 * s, GOLD, 115)
    elif held == "mace":
        top = (hand[0] - 4 * s, hand[1] - 16 * s) if pose == "swing" else (hand[0] + 5 * s, hand[1] - 14 * s)
        canvas.line(hand[0], hand[1], top[0], top[1], 2 * s, WOOD, 116)
        canvas.ellipse(top[0], top[1], 4 * s, 4 * s, IRON, 117)
    elif held == "axe":
        if pose == "swing":
            # Spinning: the axe held out flat, and the air it cuts through
            for ring in (24, 28):
                canvas.shape(lambda x, y, ring=ring: abs(math.hypot((x - cx) / 1.0, (y - shoulder - 6 * s) * 2.6) - ring) < 0.8 and y > shoulder, IRON_PALE, 118, 170)
            canvas.line(cx, shoulder + 6 * s, cx + 26, shoulder + 6 * s, 2.6, WOOD, 119)
            canvas.shape(lambda x, y: abs(y - shoulder - 6 * s) < 7 and 26 < x - cx < 32 and abs(y - shoulder - 6 * s) < (x - cx - 24) * 1.4, IRON, 120)
        else:
            canvas.line(hand[0], hand[1] + 6, hand[0] + 2, hand[1] - 26 * s, 2.6, WOOD, 119)
            ax, ay = hand[0] + 2, hand[1] - 22 * s
            canvas.shape(lambda x, y: 0 < x - ax < 10 * s and abs(y - ay) < 3 + (x - ax) * 0.9, IRON, 120)
            canvas.shape(lambda x, y: 0 < ax - x < 6 * s and abs(y - ay) < 2 + (ax - x) * 0.6, IRON, 121)
    elif held == "flame":
        if pose == "swing":
            canvas.ellipse(hand[0] - 2, hand[1] - 4, 4.5, 4.5, (255, 160, 60), 122)
            canvas.ellipse(hand[0] - 2, hand[1] - 4, 2.4, 2.4, FLAME_CORE, 123)
        else:
            canvas.ellipse(hand[0], hand[1], 2.6, 2.6, FLAME, 124)
    elif held == "fists":
        canvas.ellipse(hand[0], hand[1], 2.6 * s, 2.6 * s, SKIN, 125)
    if look.get("shield"):
        # A kite shield in the other hand, in front of that side
        sx, sy, size = cx - 11 * s * wide, shoulder + 10 * s, look["shield"] * s
        canvas.shape(lambda x, y: abs(x - sx) < size * (1 if y < sy else clamp((sy + size * 1.6 - y) / (size * 1.6)) ** 0.8) and sy - size * 0.8 < y < sy + size * 1.6, GOLD, 126)
        canvas.shape(lambda x, y: abs(x - sx) < size * (1 if y < sy else clamp((sy + size * 1.6 - y) / (size * 1.6)) ** 0.8) - 1.5 and sy - size * 0.8 + 1.5 < y < sy + size * 1.6 - 2, RED, 127)
        tabard_mark(canvas, sx, sy + size * 0.2, size * 0.55)
    return canvas.rows()


SOLDIER = {"scale": 1.0, "cloth": RED, "under": CHAIN, "legs": CHAIN, "head": "helm", "held": "sword", "shield": 7, "tabard": True, "mark": True}
MONK = {"scale": 0.95, "cloth": WHITE, "under": WHITE, "legs": WHITE, "head": "bald", "held": "fists", "robe": True, "trim": RED, "sash": RED}
ADEPT = {"scale": 1.0, "cloth": RED, "under": RED_DARK, "legs": RED_DARK, "head": "hood", "held": "flame", "robe": True, "trim": GOLD, "sash": GOLD_DARK}
DEFENDER = {"scale": 1.15, "wide": 1.15, "cloth": RED, "under": PLATE, "legs": PLATE, "boots": IRON_DARK, "head": "helm", "held": "mace", "shield": 10, "tabard": True, "mark": True, "pauldrons": GOLD}
HEROD = {"scale": 1.3, "wide": 1.2, "cloth": RED_DARK, "under": (170, 40, 40), "legs": (150, 34, 34), "boots": IRON_DARK, "head": "bald", "beard": (200, 80, 30), "held": "axe", "tabard": True, "mark": True, "pauldrons": GOLD}


def phantasm(pose):
    """A ghost of the graveyard: no feet, and the wall shows through it"""
    canvas = Canvas()
    if pose == "dead":
        for wisp in range(6):
            canvas.ellipse(16 + wisp * 6, 54 - noise(wisp, 1, 130) * 10, 3, 2, GHOST, 131, 110)
        return canvas.rows(outline=False)
    lift = -2 if pose == "step" else 0
    canvas.shape(lambda x, y: 20 + lift <= y <= 56 + lift and abs(x - 32 - math.sin(y / 5) * (y - 30) / 12) < 6 + (y - 20 - lift) * 0.22 and not (y > 50 + lift and (x // 4) % 2), GHOST_DEEP, 132, 150)
    canvas.ellipse(32, 20 + lift, 8, 9, GHOST, 133, 190)
    for side in (-1, 1):
        canvas.ellipse(32 + side * 3, 19 + lift, 1.6, 2.2, (20, 30, 60), 0, 230)
    canvas.ellipse(32, 25 + lift, 2, 2.4 if pose == "swing" else 1, (20, 30, 60), 0, 230)
    reach = 14 if pose == "swing" else 10
    for side in (-1, 1):
        canvas.line(32 + side * 6, 30 + lift, 32 + side * reach, 40 + lift - (8 if pose == "swing" else 0), 3, GHOST, 134, 170)
    return canvas.rows(outline=False)


def fountain(moment):
    """Holy water: a wide basin, a bowl held up over it with water falling from its rim, and the
    Light above it all, shining. Two moments of it, for the water to move"""
    canvas = Canvas()
    # A glow behind the Light, seen through
    for ring in range(9, 0, -1):
        canvas.ellipse(32, 12, ring * 1.6, ring * 1.6, (255, 236, 160), 160, int(18 * (10 - ring)))
    canvas.ellipse(32, 12, 4.5, 4.5, (255, 252, 230), 161)
    for spoke in range(8):
        angle = spoke * math.pi / 4 + moment * math.pi / 8
        canvas.line(32 + math.cos(angle) * 6, 12 + math.sin(angle) * 6, 32 + math.cos(angle) * 10, 12 + math.sin(angle) * 10, 1.4, GOLD, 162)
    # The basin, the water in it, and the stone round it
    canvas.ellipse(32, 57, 30, 7, STONE_DARK, 163)
    canvas.box(3, 52, 61, 57, STONE, 164)
    canvas.ellipse(32, 52, 30, 5.5, STONE_PALE, 165)
    canvas.ellipse(32, 52, 26, 4, (60, 120, 200), 166)
    for ripple in range(7):
        x = 12 + ripple * 7 + (3 if moment else 0)
        canvas.box(x, 51 + (ripple + moment) % 2, x + 2, 51 + (ripple + moment) % 2, (200, 236, 255))
    # The bowl up on its pillar
    canvas.box(29, 30, 35, 51, STONE, 167)
    canvas.box(28, 48, 36, 50, GOLD_DARK)
    canvas.ellipse(32, 29, 13, 4, STONE_PALE, 168)
    canvas.ellipse(32, 28, 10.5, 2.4, (90, 160, 230), 169)
    # Water falling from both sides of the bowl into the basin
    for side in (-1, 1):
        for drop in range(10):
            t = (drop + (0.5 if moment else 0)) / 10
            x = 32 + side * (12 + t * 9)
            y = 29 + t * t * 22
            canvas.ellipse(x, y, 1.3, 1.6, (170, 220, 255), 170, 210)
    return canvas.rows()


def brazier():
    canvas = Canvas()
    for leg in (-1, 0, 1):
        canvas.line(32 + leg * 4, 40, 32 + leg * 11, 63, 2, IRON_DARK, 140)
    canvas.shape(lambda x, y: 34 <= y <= 42 and abs(x - 32) < 12 - (y - 34) * 0.6, IRON, 141)
    canvas.box(19, 33, 45, 34, GOLD_DARK)
    flame(canvas, 32, 24, 9)
    flame(canvas, 26, 28, 5)
    flame(canvas, 38, 27, 6)
    return canvas.rows()


def candelabra():
    canvas = Canvas()
    canvas.ellipse(32, 61, 7, 2.5, GOLD_DARK, 142)
    canvas.line(32, 60, 32, 22, 2, GOLD, 143)
    canvas.shape(lambda x, y: 20 <= y <= 23 and abs(abs(x - 32) - 8) < 2.5 + (23 - y) * 0.3 or (21 <= y <= 23 and abs(x - 32) < 9), GOLD, 144)
    for offset in (-9, 0, 9):
        top = 10 if offset == 0 else 13
        canvas.box(32 + offset - 1, top, 32 + offset + 1, 20, WAX, 145)
        flame(canvas, 32 + offset, top - 4, 3)
    return canvas.rows()


def tombstone():
    canvas = Canvas()
    canvas.shape(lambda x, y: abs(x - 32) < 12 and (y > 38 or math.hypot(x - 32, y - 38) < 12) and y < 61, CRYPT, 146)
    canvas.box(30, 32, 33, 50, CRYPT_DARK)
    canvas.box(26, 37, 37, 39, CRYPT_DARK)
    canvas.shape(lambda x, y: y > 55 and y < 63 and abs(x - 32) < 16 - (y - 55) * 0.3, MOSS, 147)
    return canvas.rows()


def lectern():
    canvas = Canvas()
    canvas.box(29, 40, 35, 61, WOOD, 148)
    canvas.box(23, 59, 41, 62, WOOD_DARK, 149)
    canvas.shape(lambda x, y: abs(x - 32) < 13 and 33 + (x - 19) * 0.1 <= y <= 40 + (x - 19) * 0.1, WOOD_DARK, 150)
    canvas.shape(lambda x, y: abs(x - 32) < 11 and 29 + abs(x - 32) * 0.18 <= y <= 34, WHITE, 151)
    canvas.box(31, 29, 32, 34, (120, 110, 100))
    canvas.box(26, 34, 38, 35, RED)
    return canvas.rows()


def banner_pole():
    canvas = Canvas()
    canvas.line(32, 63, 32, 6, 2, WOOD_DARK, 152)
    canvas.ellipse(32, 6, 2, 2, GOLD, 153)
    canvas.shape(lambda x, y: 22 <= x <= 44 and 9 <= y <= 40 and not (y > 34 and abs(x - 33) < (y - 34) * 1.6), RED, 154)
    canvas.box(22, 9, 44, 10, GOLD)
    tabard_mark(canvas, 33, 22, 7)
    canvas.ellipse(32, 62, 6, 2, IRON_DARK, 155)
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
    return [sum((picture[y] for picture in pictures), []) for y in range(len(pictures[0]))]


def below(*rows):
    """Several rows of pictures as one, one under the other"""
    return [row for picture in rows for row in picture]


def render(paint, size=SIZE):
    return [[tuple(round(clamp(c / 255) * 255) for c in paint(x, y)) + (255,) for x in range(size)] for y in range(size)]


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
for name in ("brick", "stone", "moss"):
    # What the maze was built of before it was a monastery
    (target / "Warcraftstein" / (name + ".tga")).unlink(missing_ok=True)
for name, paint in (("nave", nave), ("window", window), ("banner", banner), ("library", library), ("armory", armory), ("crypt", crypt), ("portal", portal), ("shrine", shrine), ("floor", floor), ("ceiling", ceiling)):
    write(target / "Warcraftstein" / (name + ".tga"), render(paint, WALL), preview)

POSES = ("stand", "step", "swing", "dead")
EMPTY = [[(0, 0, 0, 0)] * SIZE for _ in range(SIZE)]
sheet = below(
    beside(bolt(), potion((200, 40, 44)), potion((50, 96, 224)), totem(), brazier(), candelabra(), tombstone(), lectern()),
    beside(*(person(pose, SOLDIER) for pose in POSES), *(person(pose, MONK) for pose in POSES)),
    beside(*(person(pose, ADEPT) for pose in POSES), *(person(pose, DEFENDER) for pose in POSES)),
    beside(*(person(pose, HEROD) for pose in POSES), *(phantasm(pose) for pose in POSES)),
    beside(banner_pole(), fountain(0), fountain(1), *([EMPTY] * 5)),
    *([beside(*([EMPTY] * 8))] * 3),
)
write(target / "Warcraftstein" / "sprites.tga", sheet, preview)
weapons = [held(swung) for held in (sword, bow, staff, claws) for swung in (False, True)]
write(target / "Warcraftstein" / "weapons.tga", beside(*weapons), preview)
write(target / "Icons" / "warcraftstein.tga", render(icon), preview)
