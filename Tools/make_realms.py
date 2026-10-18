#!/usr/bin/env python3
"""Draws what CarcassonneWoW is played with (Games/Realms.lua), its icon, and makes its sounds.

    python3 Tools/make_realms.py Images Sounds [previews]

Writes Images/Realms/<letter>.tga, one for each sort of tile, A to X, seen from above the way
it is drawn before it is turned: Elwynn Forest, with grass and oaks for its fields, dirt roads,
Stormwind's blue roofs inside grey walls for its towns, an abbey of pale stone after Northshire's,
and a few cottages where roads meet. A town with a banner flies a blue and gold one.

Also Images/Realms/footman.tga, a footman to tint in a player's colour, with its shadow;
spot.tga, the ring that marks where a footman may go; square.tga, the light round a square a tile
fits on; and Images/Icons/realms.tga.

The sounds, Sounds/realms<Name><take>.ogg, are a wooden tile laid on a table, a footman put down,
and a chime for something scored. They need ffmpeg. The drawing and sound helpers are
Tools/make_mancala.py's. Pass a third folder to also get PNG copies of the pictures there.

What each tile has on it, and where, is Games/Realms.lua's TILES: the slots a town or a road
reaches decide the shapes here (SHAPES, by hand), and the spots where footmen stand are read from
the Lua so that no oak grows under one.
"""
import math
import random
import re
import sys
from pathlib import Path

from make_mancala import (
    add,
    clamp,
    finish,
    fbm,
    marimba,
    mix,
    note,
    render_square,
    ring,
    smoothstep,
    tick,
    value_noise,
    write,
    write_sound,
)

SIZE = 256
SAMPLES = 2

# What is drawn on each sort of tile. Towns: "cap" against one side, "band" across from side to
# side, "corner" filling the north west, "three" on every side but the south, "full". Roads:
# "straight" across, "curve" round a corner (by the two sides it joins), "stub" from a side to the
# middle. Games/Realms.lua's TILES has the same towns and roads on the same slots
SHAPES = {
    "A": {"abbey": True, "roads": [("stub", "s")]},
    "B": {"abbey": True},
    "C": {"towns": [("full",)], "banner": (0.27, 0.3)},
    "D": {"towns": [("cap", "n")], "roads": [("straight", "we")]},
    "E": {"towns": [("cap", "n")]},
    "F": {"towns": [("band", "we")], "banner": (0.2, 0.5)},
    "G": {"towns": [("band", "ns")]},
    "H": {"towns": [("cap", "e"), ("cap", "w")]},
    "I": {"towns": [("cap", "n"), ("cap", "e")]},
    "J": {"towns": [("cap", "n")], "roads": [("curve", "es")]},
    "K": {"towns": [("cap", "n")], "roads": [("curve", "sw")]},
    "L": {"towns": [("cap", "n")], "roads": [("stub", "e"), ("stub", "s"), ("stub", "w")], "village": True},
    "M": {"towns": [("corner",)], "banner": (0.12, 0.13)},
    "N": {"towns": [("corner",)]},
    "O": {"towns": [("corner",)], "roads": [("curve", "es")], "banner": (0.12, 0.13)},
    "P": {"towns": [("corner",)], "roads": [("curve", "es")]},
    "Q": {"towns": [("three",)], "banner": (0.2, 0.2)},
    "R": {"towns": [("three",)]},
    "S": {"towns": [("three",)], "roads": [("stub", "s")], "banner": (0.2, 0.2)},
    "T": {"towns": [("three",)], "roads": [("stub", "s")]},
    "U": {"roads": [("straight", "ns")]},
    "V": {"roads": [("curve", "sw")]},
    "W": {"roads": [("stub", "e"), ("stub", "s"), ("stub", "w")], "village": True},
    "X": {"roads": [("stub", "n"), ("stub", "e"), ("stub", "s"), ("stub", "w")], "village": True},
}

# Elwynn: its grass, from shade to sun, and the flowers in it
GRASS_DARK, GRASS, GRASS_LIGHT = (46, 92, 34), (76, 134, 48), (122, 170, 64)
FLOWERS = [(240, 220, 90), (250, 250, 240), (200, 150, 220)]
# Packed dirt, its worn middle, and its edges
DIRT, DIRT_LIGHT, DIRT_EDGE = (150, 116, 76), (178, 146, 100), (96, 74, 48)
# Stormwind: pale walls, cobbles, blue slate roofs and a few grey ones
WALL, WALL_DARK, WALL_TOP = (196, 190, 174), (120, 114, 104), (226, 222, 208)
COBBLE, COBBLE_DARK = (122, 112, 98), (84, 78, 70)
ROOFS = [(46, 78, 142), (58, 92, 160), (40, 66, 120), (70, 104, 168), (88, 90, 104)]
# The banner: royal blue and gold
BLUE, GOLD = (34, 62, 156), (232, 188, 64)
# The abbey's slate and stone, a cottage's roof and walls, and an oak
SLATE, STONE = (74, 80, 102), (206, 200, 184)
THATCH, PLASTER, TIMBER = (156, 76, 52), (226, 214, 186), (96, 62, 40)
LEAVES_DARK, LEAVES, LEAVES_LIGHT = (28, 70, 26), (52, 108, 36), (104, 156, 58)
SHADOW = (0, 0, 0)

ROAD_HALF = 0.052
WALL_WIDTH = 0.04
# The middle of the tile, where roads meet in a village
MIDDLE = (0.5, 0.5)
# Where the road into an abbey or a town with a road out of it stops
ABBEY_DOOR, GATE = 0.66, 0.6


#############################
# Shapes
#############################
# Everything is measured on the tile from its top left corner, x right and y down, 0 to 1. A
# shape says how far inside it a point is, below zero outside


def turn_point(x, y, side):
    """A point seen as though the side were north: shapes are drawn for the north and turned"""
    if side == "n":
        return x, y
    if side == "e":
        return y, 1 - x
    if side == "s":
        return 1 - x, 1 - y
    return 1 - y, x


# A town against one side: how far above the side the middle of its wall's circle is, and how big
# the circle is, for it to go through both corners and come CAP_DEPTH into the tile
CAP_DEPTH = 0.3
CAP_ABOVE = (0.25 - CAP_DEPTH**2) / (2 * CAP_DEPTH)
CAP_RADIUS = CAP_DEPTH + CAP_ABOVE


def town_inside(shape, x, y):
    """How far inside a town a point is, below zero outside, and how far along its wall it is"""
    kind = shape[0]
    if kind == "full":
        return 1.0, 0.0
    if kind == "cap":
        u, v = turn_point(x, y, shape[1])
        # A circle above the side through both its corners, so that the wall meets the edge
        # there and joins the wall of the town on the next tile, coming 0.3 down in the middle
        return CAP_RADIUS - math.hypot(u - 0.5, v + CAP_ABOVE), math.atan2(u - 0.5, v + CAP_ABOVE) * CAP_RADIUS
    if kind == "band":
        u, v = (x, y) if shape[1] == "we" else (y, x)
        return 0.3 + 0.2 * (2 * u - 1) ** 2 - abs(v - 0.5), u
    if kind == "corner":
        # From the north east corner to the south west, bowed in towards the north west
        bow = 1 - 0.1 * (1 - (x - y) ** 2)
        return (bow - (x + y)) / math.sqrt(2), (x - y) / math.sqrt(2)
    # On every side but the south, coming down to 0.6 in the middle
    edge = 1 - 0.4 * math.sqrt(max(0.0, 1 - (2 * x - 1) ** 2))
    return edge - y, x * 1.3


# Where a round tower stands on a town's wall, by its shape
TOWERS = {"cap": [(0.5, 0.3)], "three": [(0.22, 0.669), (0.78, 0.669)], "corner": [(0.45, 0.45)], "band": [], "full": []}


TOWER_HALF = 0.046


def tower_at(dx, dy):
    """A square watchtower of the wall's stone from above: battlements round its top, a hatch in
    its middle, and its shadow down and to the right. None off it"""
    edge = TOWER_HALF - max(abs(dx), abs(dy))
    if edge < 0:
        if TOWER_HALF - max(abs(dx - 0.016), abs(dy - 0.016)) > 0:
            return SHADOW, 0.4
        return None
    if edge < 0.004:
        return WALL_DARK, 1.0
    if edge < 0.016:
        # Merlons and the gaps between them, round the edge
        along = dx if abs(dy) > abs(dx) else dy
        merlon = (along / (2 * TOWER_HALF) * 5 + 10) % 1 < 0.55
        lit = 1.08 if (dx < 0 and abs(dx) >= abs(dy)) or (dy < 0 and abs(dy) > abs(dx)) else 0.9
        return tuple(c * lit for c in (WALL_TOP if merlon else WALL_DARK)), 1.0
    if max(abs(dx), abs(dy)) < 0.011:
        return (70, 54, 40), 1.0
    floor = 0.9 + 0.1 * value_noise(dx * 300 + 50, dy * 300)
    return tuple(c * floor for c in mix(WALL, WALL_DARK, 0.15)), 1.0


def towers_of(shape):
    kind = shape[0]
    found = []
    for tx, ty in TOWERS[kind]:
        if kind == "cap":
            # Drawn for the north, turned to its side
            side = shape[1]
            for _ in range("nesw".index(side)):
                tx, ty = 1 - ty, tx
        found.append((tx, ty))
    return found


def segment_distance(x, y, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    t = clamp(((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy))
    return math.hypot(x - ax - t * dx, y - ay - t * dy)


SIDE_MIDDLES = {"n": (0.5, 0.0), "e": (1.0, 0.5), "s": (0.5, 1.0), "w": (0.0, 0.5)}


def road_distance(road, kind, x, y):
    """How far a point is from the middle of a road"""
    form = road[0]
    if form == "straight":
        return abs(y - 0.5) if road[1] == "we" else abs(x - 0.5)
    if form == "curve":
        cx, cy = (1.0, 1.0) if road[1] == "es" else (0.0, 1.0)
        return abs(math.hypot(x - cx, y - cy) - 0.5)
    sx, sy = SIDE_MIDDLES[road[1]]
    shapes = SHAPES[kind]
    if shapes.get("abbey"):
        end = (0.5, ABBEY_DOOR)
    elif shapes.get("towns"):
        end = (0.5, GATE) if not shapes.get("village") else MIDDLE
    else:
        end = MIDDLE
    return segment_distance(x, y, sx, sy, end[0], end[1])


#############################
# Painting
#############################


# How far in from a tile's edge anything that would show where one tile stops and the next begins
# fades out: the grass's light and shade, a road's ragged edge
EDGE_FADE = 0.08


def hashed(ix, iy, salt=0):
    return (math.sin(ix * 127.1 + iy * 311.7 + salt * 74.7) * 43758.5453) % 1.0


def grass(x, y, kind):
    """Grass with sun and shade moving over it, a fine blade texture and the odd flower"""
    offset = ord(kind) * 3.1
    # The broad light and shade goes even towards the edges, where it meets the next tile's
    tone = mix((0.47,), (fbm(x * 5 + offset, y * 5),), smoothstep(0.0, EDGE_FADE, min(x, y, 1 - x, 1 - y)))[0]
    blades = value_noise(x * 90 + offset, y * 90)
    color = mix(GRASS_DARK, GRASS_LIGHT, clamp(0.15 + 0.75 * tone + 0.18 * (blades - 0.5)))
    # Flowers, a few to a patch
    cx, cy = math.floor(x * 34), math.floor(y * 34)
    if hashed(cx, cy, ord(kind)) > 0.93:
        fx, fy = cx + 0.5 + 0.3 * (hashed(cx, cy, 1) - 0.5), cy + 0.5 + 0.3 * (hashed(cx, cy, 2) - 0.5)
        if math.hypot(x * 34 - fx, y * 34 - fy) < 0.2:
            color = FLOWERS[int(hashed(cx, cy, 3) * len(FLOWERS))]
    return color


def town_depth(towns, x, y):
    """How far inside the town a point is, and how far along its wall. Where two towns of a tile
    meet, the wall between them is halfway"""
    measured = sorted((town_inside(town, x, y) for town in towns), reverse=True)
    depth, along = measured[0]
    if len(measured) > 1 and measured[1][0] >= 0:
        depth = (measured[0][0] - measured[1][0]) / 2
    return depth, along


# Houses stand on a grid of blocks, a tenth of a tile across, never nearer a tile's edge than
# LANE: every edge where two towns meet is a street, whichever way either tile is turned
HOUSE_CELL = 0.1
LANE = 0.014
# The cobbles: square setts on a grid that fits a tile exactly, so that turned any way it meets
# the grid of the next tile
SETTS = 36


def house_at(ix, iy, kind):
    """The house of a block of town, if it has one: its middle, half its width and height, which
    way its ridge runs and its roof. None for a block that is empty, or where a house would cross
    the wall or the edge of the tile"""
    key = (kind, ix, iy)
    if key in HOUSES:
        return HOUSES[key]
    seed = ord(kind)
    house = None
    if hashed(ix, iy, seed + 9) <= 0.94:
        cell = HOUSE_CELL
        half_w = cell * (0.36 + 0.1 * hashed(ix, iy, seed + 1))
        half_h = cell * (0.26 + 0.12 * hashed(ix, iy, seed + 2))
        if hashed(ix, iy, seed + 5) > 0.5:
            half_w, half_h = half_h, half_w
        cx = (ix + 0.5) * cell + (cell / 2 - half_w - 0.008) * (2 * hashed(ix, iy, seed + 3) - 1)
        cy = (iy + 0.5) * cell + (cell / 2 - half_h - 0.008) * (2 * hashed(ix, iy, seed + 4) - 1)
        # Clear of the tile's edges
        cx = max(LANE + half_w, min(1 - LANE - half_w, cx))
        cy = max(LANE + half_h, min(1 - LANE - half_h, cy))
        towns = SHAPES[kind].get("towns", [])
        clear = WALL_WIDTH + 0.014
        corners = [(cx + sx * half_w, cy + sy * half_h) for sx in (-1, 0, 1) for sy in (-1, 0, 1)]
        if towns and all(town_depth(towns, px, py)[0] > clear for px, py in corners):
            color = ROOFS[int(hashed(ix, iy, seed) * len(ROOFS))]
            house = (cx, cy, half_w, half_h, half_w > half_h, color)
    HOUSES[key] = house
    return house


HOUSES = {}


def cobbles(x, y):
    """Square setts, each its own shade, with dark joints between"""
    gx, gy = x * SETTS, y * SETTS
    ix, iy = math.floor(gx), math.floor(gy)
    fx, fy = gx - ix, gy - iy
    if min(fx, fy, 1 - fx, 1 - fy) < 0.09:
        return tuple(c * 0.78 for c in COBBLE_DARK)
    shade = 0.3 + 0.55 * hashed(ix, iy, 23) + 0.15 * (value_noise(x * 400, y * 400) - 0.5)
    # A little light on the top left of each sett
    if fx < 0.3 or fy < 0.3:
        shade += 0.12
    return mix(COBBLE_DARK, COBBLE, clamp(shade))


def roof(x, y, kind):
    """Inside a town: houses of every size with gabled roofs of blue slate, in cobbled lanes, each
    casting a shadow down and to the right"""
    ix, iy = math.floor(x / HOUSE_CELL), math.floor(y / HOUSE_CELL)
    shadowed = False
    for dx in (-1, 0):
        for dy in (-1, 0):
            house = house_at(ix + dx, iy + dy, kind)
            if not house:
                continue
            cx, cy, half_w, half_h, along_x, color = house
            u, v = x - cx, y - cy
            if abs(u) < half_w and abs(v) < half_h and dx == 0 and dy == 0:
                edge = min(half_w - abs(u), half_h - abs(v))
                if edge < 0.004:
                    return tuple(c * 0.45 for c in color)
                # Lit on the side of the ridge towards the top left
                across = v / half_h if along_x else u / half_w
                light = 1.22 if across < 0 else 0.74
                if abs(across) < 0.07:
                    light = 1.4
                rows = (u if not along_x else v) * 160
                slates = 0.9 + 0.1 * (math.floor(rows) % 2) + 0.06 * (value_noise(x * 300, y * 300) - 0.5)
                return tuple(c * light * slates for c in color)
            if abs(u - 0.014) < half_w and abs(v - 0.014) < half_h:
                shadowed = True
    color = cobbles(x, y)
    return tuple(c * 0.62 for c in color) if shadowed else color


def banner(x, y, at):
    """A blue banner edged in gold, hanging point down, with a gold chevron. None off it"""
    u, v = (x - at[0]) / 0.09, (y - at[1]) / 0.09
    if abs(u) > 0.62 or v < -0.8:
        return None
    bottom = 0.75 - 0.55 * abs(u)
    if v > bottom:
        if v < bottom + 0.14 and abs(u) < 0.6:
            return (0, 0, 0), 0.35
        return None
    edge = min(0.62 - abs(u), v + 0.8, bottom - v)
    if edge < 0.12:
        return GOLD, 1.0
    if abs(v - 0.05 - (0.4 - abs(u)) * 0.8) < 0.11 and abs(u) < 0.45:
        return GOLD, 1.0
    return mix(BLUE, (60, 96, 200), clamp(0.5 - u * 0.5)), 1.0


def abbey(x, y):
    """Northshire's abbey from above: a cross of slate roofs on pale walls, a bell tower at the
    door end. None off it"""
    cx, cy = 0.5, 0.44
    u, v = x - cx, y - cy
    nave = abs(u) < 0.11 and abs(v) < 0.2
    transept = abs(u) < 0.2 and abs(v + 0.04) < 0.07
    tower = abs(u) < 0.075 and abs(v - 0.2) < 0.075
    if not (nave or transept or tower):
        # Its shadow, down and to the right
        su, sv = u - 0.025, v - 0.025
        if (abs(su) < 0.11 and abs(sv) < 0.2) or (abs(su) < 0.2 and abs(sv + 0.04) < 0.07) or (abs(su) < 0.075 and abs(sv - 0.2) < 0.075):
            return SHADOW, 0.35
        return None
    if tower:
        edge = 0.075 - max(abs(u), abs(v - 0.2))
        if edge < 0.012:
            return STONE, 1.0
        # A little pyramid roof
        lit = 1.2 if (u < 0 and abs(u) > abs(v - 0.2)) or (v - 0.2 < 0 and abs(v - 0.2) >= abs(u)) else 0.75
        return tuple(c * lit for c in SLATE), 1.0
    if nave and transept:
        edge = 1.0
    elif nave:
        edge = min(0.11 - abs(u), 0.2 - abs(v))
    else:
        edge = min(0.2 - abs(u), 0.07 - abs(v + 0.04))
    if edge < 0.012:
        return STONE, 1.0
    # Ridges along the nave and the transept, lit from the top left
    if transept and not (nave and abs(u) < 0.11 and abs(v + 0.04) > 0.07):
        lit = 1.2 if v + 0.04 < 0 else 0.78
        if nave and abs(u) < abs(v + 0.04) * 1.5:
            lit = 1.2 if u < 0 else 0.78
    else:
        lit = 1.2 if u < 0 else 0.78
    slates = 0.93 + 0.07 * (math.floor(((v if lit else u)) * 70) % 2)
    return tuple(c * lit * slates for c in SLATE), 1.0


def cottage(x, y):
    """A cottage where roads meet: a red tiled roof on plaster and timber. None off it"""
    u, v = x - MIDDLE[0], y - MIDDLE[1]
    half_w, half_h = 0.1, 0.075
    if abs(u) < half_w and abs(v) < half_h:
        edge = min(half_w - abs(u), half_h - abs(v))
        if edge < 0.012:
            return TIMBER, 1.0
        lit = 1.2 if v < 0 else 0.76
        if abs(v) < 0.006:
            lit = 1.35
        tiles = 0.92 + 0.08 * (math.floor(u * 80) % 2)
        return tuple(c * lit * tiles for c in THATCH), 1.0
    if abs(u - 0.02) < half_w and abs(v - 0.02) < half_h:
        return SHADOW, 0.35
    return None


def oak(x, y, tree):
    """An oak's crown from above, lit from the top left, and its shadow. None off it"""
    tx, ty, radius = tree
    distance = math.hypot(x - tx, y - ty)
    lumps = 0.12 * math.sin(math.atan2(y - ty, x - tx) * 7 + tx * 30)
    edge = radius * (1 + lumps * 0.5)
    if distance < edge:
        nx, ny = (x - tx) / radius, (y - ty) / radius
        light = clamp(0.55 - 0.45 * (nx + ny) * 0.7 + 0.25 * (value_noise(x * 70, y * 70) - 0.5))
        return mix(LEAVES_DARK, LEAVES_LIGHT, light), 1.0
    if math.hypot(x - tx - radius * 0.35, y - ty - radius * 0.35) < edge:
        return SHADOW, 0.3
    return None


def spots(lua):
    """Where footmen stand on each sort of tile, from Games/Realms.lua"""
    found, kind = {}, None
    for line in lua.splitlines():
        start = re.match(r"^  ([A-X]) = \{", line)
        if start:
            kind = start.group(1)
            found[kind] = []
        for x, y in re.findall(r"at = \{ ([\d.]+), ([\d.]+) \}", line):
            if kind:
                found[kind].append((float(x), float(y)))
    return found


def oaks(kind, footmen):
    """A few oaks in the fields of a tile: never on a road, in a town, under a building, over the
    edge or where a footman stands"""
    rng = random.Random(ord(kind) * 13)
    shapes = SHAPES[kind]
    trees = []
    for _ in range(60):
        if len(trees) >= 3:
            break
        radius = rng.uniform(0.055, 0.08)
        x, y = rng.uniform(radius + 0.04, 1 - radius - 0.04), rng.uniform(radius + 0.04, 1 - radius - 0.04)
        if any(town_inside(town, x, y)[0] > -radius - 0.05 for town in shapes.get("towns", [])):
            continue
        if any(road_distance(road, kind, x, y) < radius + ROAD_HALF + 0.03 for road in shapes.get("roads", [])):
            continue
        if (shapes.get("abbey") and math.hypot(x - 0.5, y - 0.46) < radius + 0.27) or (shapes.get("village") and math.hypot(x - 0.5, y - 0.5) < radius + 0.15):
            continue
        if any(math.hypot(x - fx, y - fy) < radius + 0.08 for fx, fy in footmen):
            continue
        if any(math.hypot(x - tx, y - ty) < radius + tr + 0.02 for tx, ty, tr in trees):
            continue
        trees.append((x, y, radius))
    return trees


def tile_painter(kind, footmen):
    shapes = SHAPES[kind]
    towns = shapes.get("towns", [])
    roads = shapes.get("roads", [])
    trees = oaks(kind, footmen)

    def paint(px, py):
        # render_square hands over -1 to 1
        x, y = (px + 1) / 2, (py + 1) / 2
        color = grass(x, y, kind)

        for tree in trees:
            leaf = oak(x, y, tree)
            if leaf:
                color = mix(color, leaf[0], leaf[1])

        # Roads: a ragged edge of trodden grass, the dirt, two ruts and the odd pebble
        nearest = min((road_distance(road, kind, x, y) for road in roads), default=9.0)
        ragged = nearest + 0.012 * (value_noise(x * 40, y * 40) - 0.5) * smoothstep(0.0, EDGE_FADE, min(x, y, 1 - x, 1 - y))
        if ragged < ROAD_HALF + 0.014:
            if ragged > ROAD_HALF - 0.006:
                color = mix(color, DIRT_EDGE, 0.75 * smoothstep(ROAD_HALF + 0.014, ROAD_HALF - 0.004, ragged))
            else:
                grit = value_noise(x * 120, y * 120)
                color = mix(DIRT, DIRT_LIGHT, clamp(0.45 + 0.4 * (grit - 0.5)))
                if abs(nearest - ROAD_HALF * 0.5) < 0.007:
                    color = mix(color, DIRT_EDGE, 0.35)
                px_, py_ = math.floor(x * 70), math.floor(y * 70)
                if hashed(px_, py_, 17) > 0.9 and math.hypot(x * 70 - px_ - 0.5, y * 70 - py_ - 0.5) < 0.3:
                    color = mix(color, (170, 164, 150), 0.8)

        if shapes.get("village"):
            house = cottage(x, y)
            if house:
                color = mix(color, house[0], house[1])
        if shapes.get("abbey"):
            building = abbey(x, y)
            if building:
                color = mix(color, building[0], building[1])

        # Towns: the walls along their edges with battlements on the outside, round towers on them,
        # roofs within, and between two towns that meet at a corner a wall too
        if towns:
            depth, along = town_depth(towns, x, y)
            if -0.018 < depth <= 0:
                # The wall's shadow on the grass
                color = mix(color, SHADOW, 0.5 * (1 + depth / 0.018))
            elif depth > 0:
                if depth < WALL_WIDTH:
                    block = (math.floor(along * 90) + math.floor(depth * 160)) % 2
                    stone = WALL if block else mix(WALL, WALL_DARK, 0.25)
                    # The walkway along the top, and the battlements outside it
                    if WALL_WIDTH * 0.45 < depth < WALL_WIDTH * 0.85:
                        stone = mix(WALL_TOP, WALL, 0.3 * value_noise(x * 200, y * 200))
                    elif depth <= WALL_WIDTH * 0.45:
                        merlon = (along * 55) % 1 < 0.55
                        stone = WALL_TOP if merlon else WALL_DARK
                    if depth < 0.005:
                        stone = WALL_DARK
                    color = stone
                    # The gate the road comes in by
                    if roads and abs(x - 0.5) < 0.035 and y > 0.5 and not shapes.get("village"):
                        color = (44, 34, 26) if abs(x - 0.5) < 0.026 else WALL_DARK
                elif depth < WALL_WIDTH + 0.014:
                    color = mix(roof(x, y, kind), SHADOW, 0.4)
                else:
                    color = roof(x, y, kind)
            for town in towns:
                for tx, ty in towers_of(town):
                    tower = tower_at(x - tx, y - ty)
                    if tower:
                        color = mix(color, tower[0], tower[1])
        flag = shapes.get("banner")
        if flag:
            mark = banner(x, y, flag)
            if mark:
                color = mix(color, mark[0], mark[1])
        return tuple(clamp(c / 255) * 255 for c in color), 1.0

    return paint


MEEPLE = [
    (0.0, -0.4), (0.12, -0.38), (0.5, -0.22), (0.6, -0.12), (0.56, -0.02), (0.26, -0.04), (0.28, 0.12),
    (0.52, 0.64), (0.46, 0.7), (0.14, 0.7), (0.0, 0.42), (-0.14, 0.7), (-0.46, 0.7), (-0.52, 0.64),
    (-0.28, 0.12), (-0.26, -0.04), (-0.56, -0.02), (-0.6, -0.12), (-0.5, -0.22), (-0.12, -0.38),
]
HEAD = (0.0, -0.56, 0.2)


def polygon_distance(x, y, points):
    """Signed distance to a polygon, below zero inside"""
    best, inside = 9.0, False
    count = len(points)
    for index in range(count):
        ax, ay = points[index]
        bx, by = points[(index + 1) % count]
        best = min(best, segment_distance(x, y, ax, ay, bx, by))
        if (ay > y) != (by > y) and x < (bx - ax) * (y - ay) / (by - ay) + ax:
            inside = not inside
    return -best if inside else best


def meeple(x, y):
    """How far outside the footman a point is, his corners rounded off"""
    body = polygon_distance(x, y, MEEPLE)
    head = math.hypot(x - HEAD[0], y - HEAD[1]) - HEAD[2]
    # A smooth join between the head and the shoulders
    k = 0.08
    h = clamp(0.5 + 0.5 * (head - body) / k)
    joined = head * (1 - h) + body * h - k * h * (1 - h)
    return joined - 0.035


def footman(x, y):
    """A footman, white to be tinted: a wooden figure with rounded edges lit from the top left,
    dark round his edge, with a shadow at his feet"""
    y = y * 1.08 + 0.02
    distance = meeple(x, y)
    if distance > 0:
        shadow = ((x - 0.08) / 0.62) ** 2 + ((y - 0.76) / 0.13) ** 2 < 1
        outline = clamp(1 - distance / 0.03)
        if outline > 0:
            return (20, 16, 12), outline
        return (0, 0, 0), 0.4 if shadow else 0.0
    # A bevel: the slope of the edge towards the light is lit, away from it shaded
    e = 0.01
    gx = meeple(x + e, y) - meeple(x - e, y)
    gy = meeple(x, y + e) - meeple(x, y - e)
    length = math.hypot(gx, gy) or 1.0
    bevel = smoothstep(0.0, 0.1, -distance)
    facing = (-gx - gy) / length / math.sqrt(2)
    light = 0.82 + (1 - bevel) * 0.35 * facing + 0.12 * clamp(-(x + y) * 0.4)
    grain = 0.97 + 0.03 * value_noise(x * 30, y * 8)
    shade = clamp(light * grain, 0, 1.05) * 242
    if distance > -0.02:
        shade *= 0.55
    return (min(255, shade), min(255, shade), min(255, shade)), 1.0


def spot(x, y):
    """A ring of light, white to be tinted"""
    distance = math.hypot(x, y)
    ring_glow = math.exp(-((distance - 0.62) / 0.12) ** 2)
    inner = 0.25 * smoothstep(0.62, 0.2, distance)
    return (255, 255, 255), clamp(ring_glow + inner)


def square(x, y):
    """The light round the inside of a square, white to be tinted"""
    edge = 1 - max(abs(x), abs(y))
    return (255, 255, 255), clamp(math.exp(-(edge / 0.09) ** 2) * 0.95 + 0.08)


def icon_painter(footmen):
    tile = tile_painter("D", footmen["D"])

    def paint(x, y):
        corner = max(abs(x), abs(y))
        if corner > 0.96:
            return (0, 0, 0), 0.0
        color, _ = tile(x * 0.98, y * 0.98)
        return color, 1.0

    return paint


#############################
# Sounds
#############################


def lay(rng):
    """A wooden tile laid down on a table: a dull knock and a short slide"""
    pitch = rng.uniform(0.9, 1.1)
    knock = ring([(150 * pitch, 0.8, 0.05), (410 * pitch, 0.45, 0.025), (930 * pitch, 0.2, 0.012)], 0.2, rng)
    slide = [rng.uniform(-1, 1) * 0.05 * math.exp(-i / 900) for i in range(2500)]
    return add(add(slide, knock, at=0.012), tick(0.004, 0.001, rng), at=0.012, gain=0.4)


def put(rng):
    """A small wooden figure set down: a light tap"""
    pitch = rng.uniform(0.9, 1.15)
    tap = ring([(620 * pitch, 0.6, 0.02), (1500 * pitch, 0.4, 0.012), (3100 * pitch, 0.15, 0.006)], 0.1, rng)
    return add(tap, tick(0.003, 0.0008, rng), gain=0.5)


def chime(rng):
    """Something scored: a rising pair of notes"""
    sound = marimba(note("G5"), rng)
    return add(sound, marimba(note("D6"), rng), at=0.09, gain=0.8)


if __name__ == "__main__":
    images = Path(sys.argv[1])
    sounds_folder = Path(sys.argv[2])
    preview = Path(sys.argv[3]) if len(sys.argv) > 3 else None
    only = sys.argv[4:] if len(sys.argv) > 4 else None
    lua = (Path(__file__).resolve().parent.parent / "Games" / "Realms.lua").read_text()
    footmen = spots(lua)
    rng = random.Random(5)
    if not only:
        for take in range(1, 4):
            write_sound(sounds_folder, "Lay%d" % take, finish(lay(rng), 0.5), prefix="realms")
            write_sound(sounds_folder, "Footman%d" % take, finish(put(rng), 0.35), prefix="realms")
        write_sound(sounds_folder, "Score1", finish(chime(rng), 0.4), prefix="realms")
        write(images / "Icons" / "realms.tga", render_square(64, icon_painter(footmen)), preview)
        write(images / "Realms" / "footman.tga", render_square(128, footman), preview)
        write(images / "Realms" / "spot.tga", render_square(64, spot), preview)
        write(images / "Realms" / "square.tga", render_square(128, square), preview)
    for kind in sorted(SHAPES):
        if only and kind not in only:
            continue
        write(images / "Realms" / (kind + ".tga"), render_square(SIZE, tile_painter(kind, footmen[kind]), SAMPLES), preview)
        print(kind, flush=True)
