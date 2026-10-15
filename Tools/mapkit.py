"""Builds a Doom map from code, for maps of the addon's own that are written rather than drawn in
an editor: sectors given as their outlines, and the rest worked out the way an editor and a node
builder would. A map made with it is a WAD of its own (a PWAD), which Tools/import_wad.py turns
into a sector map with the pictures of the WAD it goes with (its --pwad).

    kit = Map()
    hall = kit.sector([(0, 0), (512, 0), (512, 256), (0, 256)], floor=0, ceiling=128,
                      floor_flat="FLOOR4_8", ceiling_flat="CEIL3_5", light=160, wall="STARTAN2")
    kit.thing(64, 128, 1, angle=0)
    kit.write("run.wad", "RUN")

What is worked out:

- Lines. Every edge of a sector's outline is a line; where two sectors' outlines meet along an
  edge it is one line between them with a side for each. Outlines meet along edges, not only at
  corners: a vertex of one lying on the edge of another splits that edge, so a corridor can open
  anywhere along a room's wall. A sector is its outline and any holes in it (a pillar is a hole;
  something standing in a room, a pool or a platform, is a hole filled by a sector of its own).
  Outlines go either way round.
- Pictures. A wall with nothing behind it shows the sector's wall picture. Where there is a
  sector behind, the wall that shows over or under the opening is the other sector's: its upper
  picture above (a door's face, the lintel of a doorway) and its lower picture below (the riser
  of a step or a lift). Pictures run on along a wall from line to line, as if the wall were one.
- A door's side faces out: the side a door is used from is the front of its line.
- Nodes, Doom's binary space partition: the map cut by lines into convex subsectors, with the
  segs that are their walls (build_nodes).

Only the standard library is used.
"""
import math
import struct

# Line flags, Doom's: in the way of everybody, of monsters, two-sided, the upper picture hanging
# from the ceiling and the lower (or middle) standing on the floor
IMPASSABLE, BLOCK_MONSTERS, TWO_SIDED, UPPER_UNPEGGED, LOWER_UNPEGGED = 1, 2, 4, 8, 16
# Thing flags: on which skills it is there (Doom's 1 and 2, 3, 4 and 5), and waiting to see the player
EASY, NORMAL, HARD, AMBUSH = 1, 2, 4, 8
ALL = EASY | NORMAL | HARD


class Sector:
    def __init__(self, loops, floor, ceiling, floor_flat, ceiling_flat, light, wall, upper, lower, special, tag, door, moves, peg):
        self.loops = loops
        self.floor, self.ceiling = floor, ceiling
        self.floor_flat, self.ceiling_flat = floor_flat, ceiling_flat
        self.light, self.special, self.tag = light, special, tag
        self.wall = wall
        self.upper = upper or wall
        self.lower = lower or wall
        self.door = door
        self.moves = moves or door
        self.peg = peg
        self.index = None


def area(points):
    return sum(x1 * y2 - x2 * y1 for (x1, y1), (x2, y2) in zip(points, points[1:] + points[:1])) / 2


def on_segment(point, start, end):
    """Whether a point lies on a segment, strictly between its ends"""
    (px, py), (x1, y1), (x2, y2) = point, start, end
    if (px - x1) * (y2 - y1) - (py - y1) * (x2 - x1) != 0:
        return False
    dot = (px - x1) * (x2 - x1) + (py - y1) * (y2 - y1)
    return 0 < dot < (x2 - x1) ** 2 + (y2 - y1) ** 2


def along(point, start, end):
    """How far along a segment a point on it is, 0 to 1"""
    (px, py), (x1, y1), (x2, y2) = point, start, end
    return ((px - x1) * (x2 - x1) + (py - y1) * (y2 - y1)) / ((x2 - x1) ** 2 + (y2 - y1) ** 2)


class Map:
    def __init__(self):
        self.sectors = []
        self.things = []
        # What a wall or line is told to be, by the stretch of wall it covers
        self.walls = []

    def sector(self, outline, floor, ceiling, floor_flat, ceiling_flat, light, wall, upper=None, lower=None, special=0, tag=0,
               holes=(), door=False, moves=False, peg=0):
        """A sector: its outline, any holes in it, its heights and pictures and light. Its wall is what
        its walls show, its upper and lower what shows over and under an opening into it from
        another sector (the wall if left out). A door's lines face out of it. A sector that moves
        (a door, a lift) shows its upper and lower pictures around every opening into it, and every
        sector beside it shows its own into it, whatever the heights are to begin with. Peg is line
        flags for its walls with nothing behind them (LOWER_UNPEGGED for a door's tracks)"""
        loops = [self._wound(outline, True)] + [self._wound(hole, False) for hole in holes]
        made = Sector(loops, floor, ceiling, floor_flat, ceiling_flat, light, wall, upper, lower, special, tag, door, moves, peg)
        self.sectors.append(made)
        return made

    @staticmethod
    def _wound(points, anticlockwise):
        points = [(int(x), int(y)) for x, y in points]
        if (area(points) > 0) != anticlockwise:
            points.reverse()
        return points

    def wall(self, start, end, facing=None, **what):
        """Tells the walls along a stretch what to be: the side facing a sector (else every side
        there) gets middle, upper, lower, x and y (its pictures and how they are moved), and the
        line special, tag and flags"""
        self.walls.append((tuple(start), tuple(end), facing, what))

    def thing(self, x, y, kind, angle=0, flags=ALL):
        self.things.append((int(x), int(y), int(angle), kind, flags))

    # The map as Doom has it

    def build(self):
        """Vertices, lines, sides and sectors, as lists of dicts"""
        for index, sector in enumerate(self.sectors):
            sector.index = index
        corners = sorted({point for sector in self.sectors for loop in sector.loops for point in loop})
        # Every edge, split where another outline's corner lies on it, with the sector on its left
        edges = {}
        for sector in self.sectors:
            for loop in sector.loops:
                for start, end in zip(loop, loop[1:] + loop[:1]):
                    cuts = sorted((point for point in corners if on_segment(point, start, end)), key=lambda point: along(point, start, end))
                    stops = [start] + cuts + [end]
                    for a, b in zip(stops, stops[1:]):
                        if (a, b) in edges:
                            raise ValueError(f"Two sectors on the same side of {a} {b}")
                        edges[(a, b)] = sector
        vertices, vertex_index = [], {}

        def vertex(point):
            if point not in vertex_index:
                vertex_index[point] = len(vertices)
                vertices.append(point)
            return vertex_index[point]

        lines, sides, done = [], [], set()
        for (a, b), sector in edges.items():
            if (a, b) in done:
                continue
            done.add((a, b))
            other = edges.get((b, a))
            if other is not None:
                done.add((b, a))
            # A line's front is on its right: from b to a for the sector on the left of a to b.
            # A door's lines face out of it
            front, back, start, end = sector, other, b, a
            if other is not None and sector.door and not other.door:
                front, back, start, end = other, sector, a, b
            line = {"from": vertex(start), "to": vertex(end), "flags": 0, "special": 0, "tag": 0, "front": None, "back": None}
            if back is None:
                line["flags"] = IMPASSABLE | front.peg
            else:
                line["flags"] = TWO_SIDED
            line["front"] = self._side(sides, front, back, start, end)
            if back is not None:
                line["back"] = self._side(sides, back, front, end, start)
            for wall_start, wall_end, facing, what in self.walls:
                if self._covers(wall_start, wall_end, start, end):
                    for key in ("special", "tag", "flags"):
                        if key in what:
                            line[key] = what[key] if key != "flags" else line["flags"] | what[key]
                    for side_key, side_sector in (("front", front), ("back", back)):
                        if line[side_key] is not None and (facing is None or facing is side_sector):
                            side = sides[line[side_key]]
                            for key in ("middle", "upper", "lower", "x", "y"):
                                if key in what:
                                    side[key] = what[key]
            lines.append(line)
        sectors = [{"floor": s.floor, "ceiling": s.ceiling, "floor_flat": s.floor_flat, "ceiling_flat": s.ceiling_flat, "light": s.light,
                    "special": s.special, "tag": s.tag} for s in self.sectors]
        return vertices, lines, sides, sectors

    @staticmethod
    def _covers(wall_start, wall_end, start, end):
        """Whether a stretch of wall takes in all of a line, either way along it"""
        def within(point):
            return point in (wall_start, wall_end) or on_segment(point, wall_start, wall_end)
        return within(start) and within(end)

    @staticmethod
    def _side(sides, sector, other, start, end):
        """The side of a line facing a sector, going from start to end with the sector on its right:
        its pictures, and moved along so that they run on from the line before on the same wall"""
        length = math.hypot(end[0] - start[0], end[1] - start[1])
        ux, uy = (end[0] - start[0]) / length, (end[1] - start[1]) / length
        x = round(start[0] * ux + start[1] * uy)
        if other is None:
            side = {"x": x, "y": 0, "upper": "-", "lower": "-", "middle": sector.wall}
        else:
            moving = other.moves or sector.moves
            upper = other.upper if other.ceiling < sector.ceiling or moving else "-"
            lower = other.lower if other.floor > sector.floor or moving else "-"
            side = {"x": x, "y": 0, "upper": upper, "lower": lower, "middle": "-"}
        side["sector"] = sector.index
        sides.append(side)
        return len(sides) - 1

    def write(self, path, name, picture=None):
        """Writes the map into a WAD of its own under a name (\"RUN\"), nodes and all, having checked that
        the nodes find every sector where it is, and a picture of it from above if asked (draw). Says
        how much there is of everything"""
        vertices, lines, sides, sectors = self.build()
        points = list(vertices)
        segs, subsectors, nodes = build_nodes(points, lines, sides)
        wrong = check(lines, sides, segs, subsectors, nodes, [sector.loops for sector in self.sectors])
        if wrong:
            raise RuntimeError(f"The nodes put {len(wrong)} points in the wrong sector, the first {wrong[0]}")
        if picture:
            draw(picture, points, lines, sides, sectors, self.things)
        lumps = [(name, b"")]
        lumps.append(("THINGS", b"".join(struct.pack("<hhhhh", *thing) for thing in self.things)))
        lumps.append(("LINEDEFS", b"".join(struct.pack("<HHhhhHH", line["from"], line["to"], line["flags"], line["special"], line["tag"], line["front"],
                                                       0xFFFF if line["back"] is None else line["back"]) for line in lines)))
        lumps.append(("SIDEDEFS", b"".join(struct.pack("<hh8s8s8sh", side["x"], side["y"], name8(side["upper"]),
                                                       name8(side["lower"]), name8(side["middle"]), side["sector"]) for side in sides)))
        lumps.append(("VERTEXES", b"".join(struct.pack("<hh", int(x), int(y)) for x, y in points)))
        lumps.append(("SEGS", b"".join(struct.pack("<HHhHhh", *seg) for seg in segs)))
        lumps.append(("SSECTORS", b"".join(struct.pack("<HH", *subsector) for subsector in subsectors)))
        lumps.append(("NODES", b"".join(struct.pack("<hhhhhhhhhhhhHH", *node) for node in nodes)))
        lumps.append(("SECTORS", b"".join(struct.pack("<hh8s8shhh", s["floor"], s["ceiling"], name8(s["floor_flat"]), name8(s["ceiling_flat"]),
                                                      s["light"], s["special"], s["tag"]) for s in sectors)))
        lumps.append(("REJECT", b""))
        lumps.append(("BLOCKMAP", b""))
        directory, body, offset = b"", b"", 12
        for lump_name, data in lumps:
            directory += struct.pack("<ii8s", offset, len(data), name8(lump_name))
            body += data
            offset += len(data)
        with open(path, "wb") as handle:
            handle.write(struct.pack("<4sii", b"PWAD", len(lumps), offset) + body + directory)
        return {"vertices": len(points), "lines": len(lines), "sides": len(sides), "sectors": len(sectors), "segs": len(segs),
                "subsectors": len(subsectors), "nodes": len(nodes), "things": len(self.things)}


def name8(name):
    return name.upper().encode("ascii")[:8].ljust(8, b"\0")


# Nodes

EPSILON = 1e-6


class Seg:
    __slots__ = ("x1", "y1", "x2", "y2", "line", "back", "offset", "sector")

    def __init__(self, x1, y1, x2, y2, line, back, offset, sector):
        self.x1, self.y1, self.x2, self.y2 = x1, y1, x2, y2
        self.line, self.back, self.offset, self.sector = line, back, offset, sector


def side_of(px, py, pdx, pdy, x, y):
    """Which side of a partition a point is on: more than nothing in front (its right), less behind"""
    return (x - px) * pdy - (y - py) * pdx


def build_nodes(points, lines, sides):
    """Cuts the map into convex subsectors by partition lines, as Doom's node builders do: the segs
    (each v1, v2, angle, line, back, offset), subsectors (count, first seg) and nodes (x, y, dx, dy,
    the front's box and the back's top, bottom, left, right, then front and back, a subsector
    marked by the top bit), the last node the root. Points is the map's vertices, and the
    vertices segs are cut at are added to it"""
    vertex_index = {point: index for index, point in enumerate(points)}

    def vertex(x, y):
        point = (int(round(x)), int(round(y)))
        if point not in vertex_index:
            vertex_index[point] = len(points)
            points.append(point)
        return vertex_index[point]

    segs = []
    for index, line in enumerate(lines):
        (x1, y1), (x2, y2) = points[line["from"]], points[line["to"]]
        segs.append(Seg(x1, y1, x2, y2, index, False, 0, sides[line["front"]]["sector"]))
        if line["back"] is not None:
            segs.append(Seg(x2, y2, x1, y1, index, True, 0, sides[line["back"]]["sector"]))

    out_segs, out_subsectors, out_nodes = [], [], []

    def classify(seg, px, py, pdx, pdy):
        a = side_of(px, py, pdx, pdy, seg.x1, seg.y1)
        b = side_of(px, py, pdx, pdy, seg.x2, seg.y2)
        scale = math.hypot(pdx, pdy)
        a, b = a / scale, b / scale
        if abs(a) < 0.01:
            a = 0
        if abs(b) < 0.01:
            b = 0
        if a >= 0 and b >= 0:
            if a == 0 and b == 0:
                # Along the partition: in front if it goes the same way
                return "front" if (seg.x2 - seg.x1) * pdx + (seg.y2 - seg.y1) * pdy > 0 else "back"
            return "front"
        if a <= 0 and b <= 0:
            return "back"
        return "split"

    def convex(group):
        if len({seg.sector for seg in group}) > 1:
            return False
        for seg in group:
            pdx, pdy = seg.x2 - seg.x1, seg.y2 - seg.y1
            for other in group:
                if other is not seg and classify(other, seg.x1, seg.y1, pdx, pdy) != "front":
                    return False
        return True

    def choose(group):
        best, best_cost = None, None
        tried = set()
        for seg in group:
            pdx, pdy = seg.x2 - seg.x1, seg.y2 - seg.y1
            key = (seg.line, seg.back)
            if key in tried:
                continue
            tried.add(key)
            front = back = splits = 0
            for other in group:
                where = classify(other, seg.x1, seg.y1, pdx, pdy)
                if where == "front":
                    front += 1
                elif where == "back":
                    back += 1
                else:
                    splits += 1
            if splits == 0 and (front == 0 or back == 0):
                continue
            cost = splits * 8 + abs(front - back) + (0 if pdx == 0 or pdy == 0 else 12)
            if best_cost is None or cost < best_cost:
                best, best_cost = (seg.x1, seg.y1, pdx, pdy), cost
        return best

    def cut(seg, px, py, pdx, pdy):
        """A seg crossing a partition, in two: its front part and its back part"""
        a = side_of(px, py, pdx, pdy, seg.x1, seg.y1)
        b = side_of(px, py, pdx, pdy, seg.x2, seg.y2)
        t = a / (a - b)
        at = points[vertex(seg.x1 + (seg.x2 - seg.x1) * t, seg.y1 + (seg.y2 - seg.y1) * t)]
        first = Seg(seg.x1, seg.y1, at[0], at[1], seg.line, seg.back, seg.offset, seg.sector)
        second = Seg(at[0], at[1], seg.x2, seg.y2, seg.line, seg.back, seg.offset + math.hypot(at[0] - seg.x1, at[1] - seg.y1), seg.sector)
        return (first, second) if a > 0 else (second, first)

    def box(group):
        xs = [x for seg in group for x in (seg.x1, seg.x2)]
        ys = [y for seg in group for y in (seg.y1, seg.y2)]
        return [int(math.ceil(max(ys))), int(math.floor(min(ys))), int(math.floor(min(xs))), int(math.ceil(max(xs)))]

    def build(group, depth=0):
        """A subsector (its number with the top bit) or a node (its number)"""
        if depth > 200:
            raise RuntimeError("The nodes go too deep: the map has a sector that isn't closed")
        if convex(group):
            first = len(out_segs)
            for seg in group:
                angle = int(round(math.atan2(seg.y2 - seg.y1, seg.x2 - seg.x1) / (2 * math.pi) * 65536)) & 0xFFFF
                out_segs.append((vertex(seg.x1, seg.y1), vertex(seg.x2, seg.y2), angle - 65536 if angle >= 32768 else angle, seg.line,
                                 1 if seg.back else 0, int(round(seg.offset))))
            out_subsectors.append((len(group), first))
            return (len(out_subsectors) - 1) | 0x8000
        partition = choose(group)
        if partition is None:
            raise RuntimeError(f"No way to cut {len(group)} segs of sectors {sorted({seg.sector for seg in group})} apart")
        px, py, pdx, pdy = partition
        front, back = [], []
        for seg in group:
            where = classify(seg, px, py, pdx, pdy)
            if where == "front":
                front.append(seg)
            elif where == "back":
                back.append(seg)
            else:
                ahead, behind = cut(seg, px, py, pdx, pdy)
                front.append(ahead)
                back.append(behind)
        front_box, back_box = box(front), box(back)
        right = build(front, depth + 1)
        left = build(back, depth + 1)
        out_nodes.append((int(px), int(py), int(pdx), int(pdy), *front_box, *back_box, right, left))
        return len(out_nodes) - 1

    # A back seg's offset is from the line's end, where its side begins: where the seg does
    build(segs)
    return out_segs, out_subsectors, out_nodes


def check(lines, sides, segs, subsectors, nodes, sector_loops, samples=24):
    """Finds the sector of points all over every sector by way of the nodes: where that isn't
    the sector they are in, as (x, y, sector, found)"""
    wrong = []

    def subsector_at(x, y):
        at = len(nodes) - 1
        if at < 0:
            return 0
        while True:
            px, py, pdx, pdy = nodes[at][:4]
            child = nodes[at][13] if side_of(px, py, pdx, pdy, x, y) <= 0 else nodes[at][12]
            if child & 0x8000:
                return child & 0x7FFF
            at = child

    def inside(x, y, loop):
        result = False
        for (x1, y1), (x2, y2) in zip(loop, loop[1:] + loop[:1]):
            if (y1 > y) != (y2 > y) and x < x1 + (y - y1) * (x2 - x1) / (y2 - y1):
                result = not result
        return result

    for index, loops in enumerate(sector_loops):
        outline = loops[0]
        xs, ys = [x for x, _ in outline], [y for _, y in outline]
        for i in range(1, samples):
            for j in range(1, samples):
                x = min(xs) + (max(xs) - min(xs)) * i / samples + 0.37
                y = min(ys) + (max(ys) - min(ys)) * j / samples + 0.21
                if inside(x, y, outline) and not any(inside(x, y, hole) for hole in loops[1:]):
                    _, first = subsectors[subsector_at(x, y)]
                    seg = segs[first]
                    line = lines[seg[3]]
                    found = sides[line["back"] if seg[4] else line["front"]]["sector"]
                    if found != index:
                        wrong.append((x, y, index, found))
    return wrong


def draw(path, vertices, lines, sides, sectors, things, scale=0.125):
    """A picture of the map from above, Doom's automap's way: walls white, steps grey, lines that do
    something yellow, sectors that hurt green; monsters red, pickups blue, the player white. For
    whoever makes a map, to look at"""
    import zlib
    xs = [x for x, _ in vertices]
    ys = [y for _, y in vertices]
    left, bottom = min(xs) - 64, min(ys) - 64
    width, height = int((max(xs) + 64 - left) * scale) + 1, int((max(ys) + 64 - bottom) * scale) + 1
    image = [[(16, 16, 16)] * width for _ in range(height)]

    def plot(x, y, colour):
        px, py = int((x - left) * scale), height - 1 - int((y - bottom) * scale)
        if 0 <= px < width and 0 <= py < height:
            image[py][px] = colour

    for line in lines:
        (x1, y1), (x2, y2) = vertices[line["from"]], vertices[line["to"]]
        if line["special"]:
            colour = (255, 220, 0)
        elif line["back"] is None:
            colour = (230, 230, 230)
        else:
            front, back = sectors[sides[line["front"]]["sector"]], sectors[sides[line["back"]]["sector"]]
            if front["special"] or back["special"]:
                colour = (60, 200, 60)
            elif front["floor"] != back["floor"]:
                colour = (130, 130, 150)
            elif front["ceiling"] != back["ceiling"]:
                colour = (70, 70, 90)
            else:
                continue
        steps = int(max(abs(x2 - x1), abs(y2 - y1)) * scale) + 1
        for step in range(steps + 1):
            plot(x1 + (x2 - x1) * step / steps, y1 + (y2 - y1) * step / steps, colour)
    for x, y, _, kind, _ in things:
        colour = (255, 255, 255) if kind == 1 else (255, 60, 60) if kind in (3004, 9, 3001, 3002, 58, 3006, 3003) else (80, 140, 255)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                plot(x + dx / scale, y + dy / scale, colour)
    raw = b"".join(b"\0" + bytes(c for pixel in row for c in pixel) for row in image)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw))
                     + chunk(b"IEND", b""))
