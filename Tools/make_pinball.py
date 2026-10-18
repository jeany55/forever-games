#!/usr/bin/env python3
"""Writes out a pinball table (Tools/pinball_table.py) for the bench to play on.

    python3 Tools/make_pinball.py <folder> [--preview <png>] [--no-art] [--cache <folder>] [--quick]

Writes <folder>/Table.lua, what the physics meets (Engine/Physics.lua): every wall, post, sensor,
flipper and wire of the table, the lights set into it and what its materials are. With --preview,
also a picture of the shapes drawn plainly, from above, to check the table by eye.

Then the table's pictures: built in 3D and rendered by Blender (Tools/pinball_blender.py), which
has to be on the PATH as `blender`, over the playfield's print (Tools/pinball_art.py): the tilt*
pictures, and <folder>/Art.lua saying where everything in them goes. That takes several minutes, so
what it made is kept in the cache folder with a key
made from all it was made from, and only made again when that changes. --quick renders with fewer
samples, to look; --no-art leaves the pictures alone. The folder is ForeverGames_Pinball/Images,
the game's own; the cache is Tools/PinballBench/RenderCache unless --cache says.
Only the standard library is used here; Blender has its own Python.
"""
import math
import struct
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pinball_table  # noqa: E402


def lua(value, indent=""):
    """A Python value written as Lua"""
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "nil"
    if isinstance(value, (int, float)):
        if isinstance(value, float) and value.is_integer():
            return str(int(value))
        return repr(round(value, 6)) if isinstance(value, float) else str(value)
    if isinstance(value, str):
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if isinstance(value, (list, tuple)):
        if all(isinstance(item, (int, float)) and not isinstance(item, bool) for item in value):
            return "{ " + ", ".join(lua(item) for item in value) + " }"
        inner = indent + "  "
        return "{\n" + "".join(inner + lua(item, inner) + ",\n" for item in value) + indent + "}"
    if isinstance(value, dict):
        inner = indent + "  "
        parts = []
        for key in sorted(value):
            name = key if key.isidentifier() else "[" + lua(key) + "]"
            parts.append(f"{inner}{name} = {lua(value[key], inner)},\n")
        return "{\n" + "".join(parts) + indent + "}"
    raise TypeError(type(value))


def write_table(folder):
    table = dict(pinball_table.TABLE)
    table["shapes"] = pinball_table.shapes()
    table["lamps"] = pinball_table.lamps()
    table["flashers"] = pinball_table.flashers()
    table["rails"] = pinball_table.rails()
    text = ("-- Made by Tools/make_pinball.py from Tools/pinball_table.py: change those, not this\n"
            "local _, ns = ...\n"
            "ns.Table = " + lua(table) + "\n")
    path = Path(folder) / "Table.lua"
    path.write_text(text)
    print(path, len(table["shapes"]), "shapes")
    return table


def windows(path):
    """A path as the Windows Blender needs it"""
    import subprocess
    return subprocess.check_output(["wslpath", "-w", str(Path(path).resolve())]).decode().strip()


FONTS = {"label": "segoeuib.ttf", "title": "palab.ttf"}
# Where what Blender made is kept, beside the bench, out of the addon
CACHE = Path(__file__).resolve().parent / "PinballBench" / "RenderCache"


def render_tilt(folder, cache, quick=False):
    """Renders the tilted table in Blender, or takes it from the cache if nothing it is made from
    changed; copies its pictures into `folder` and returns what Art.tilt says of them"""
    import hashlib
    import json
    import shutil
    import subprocess
    import pinball_art

    if not shutil.which("blender"):
        print("No blender on the PATH: the tilted table isn't rendered")
        return None
    cache = Path(cache)
    cache.mkdir(parents=True, exist_ok=True)
    bare = cache / "playfieldBare.tga"
    pinball_art.make_bare(cache)
    table = dict(pinball_table.TABLE)
    table["shapes"] = pinball_table.shapes()
    table["lamps"] = pinball_table.lamps()
    table["flashers"] = pinball_table.flashers()
    table["rails"] = pinball_table.rails()
    table["supports"] = pinball_table.supports()
    table["corkscrew"] = pinball_table.CORKSCREW
    fonts = {}
    for role, name in FONTS.items():
        found = Path("/mnt/c/Windows/Fonts") / name
        fonts[role] = windows(found) if found.exists() else None
    scene = {"table": table, "colours": pinball_art.COLOURS, "playfield": windows(bare), "fonts": fonts}
    text = json.dumps(scene, sort_keys=True)
    script = Path(__file__).resolve().parent / "pinball_blender.py"
    key = hashlib.sha1(text.encode() + script.read_bytes() + bare.read_bytes() + (b"quick" if quick else b"")).hexdigest()
    out = cache / "out"
    stamp = cache / "key"
    if not (stamp.exists() and stamp.read_text() == key and (out / "tilt.json").exists()):
        out.mkdir(exist_ok=True)
        (cache / "scene.json").write_text(text)
        command = ["blender", "-b", "--factory-startup", "--python", windows(script), "--", windows(cache / "scene.json"),
                   windows(out), "--preview"] + (["--quick"] if quick else [])
        print("Rendering the tilted table in Blender, a few minutes")
        result = subprocess.run(command, capture_output=True, text=True)
        for line in result.stdout.splitlines():
            if line.startswith("PINBALL") or "Error" in line or "Traceback" in line:
                print(line)
        if not (out / "tilt.json").exists():
            print(result.stdout[-3000:], result.stderr[-3000:])
            raise SystemExit("Blender didn't finish the tilted table")
        stamp.write_text(key)
    else:
        print("The tilted table is as it was rendered last:", out)
    tilt = json.loads((out / "tilt.json").read_text())
    for name in tilt["files"]:
        shutil.copyfile(out / (name + ".tga"), Path(folder) / (name + ".tga"))
    return tilt


def read_tga(path):
    """A 32 bit TGA as width, height and RGBA rows, top first"""
    data = Path(path).read_bytes()
    width, height = struct.unpack("<HH", data[12:16])
    top_first = data[17] & 0x20
    pixels = data[18:18 + width * height * 4]
    rows = []
    for y in range(height):
        row = pixels[y * width * 4:(y + 1) * width * 4]
        rows.append(bytes(c for i in range(width) for c in (row[i * 4 + 2], row[i * 4 + 1], row[i * 4], row[i * 4 + 3])))
    return width, height, rows if top_first else rows[::-1]


def make_icon(folder, tilt, png=None, size=64):
    """The game's icon: the top of the table, the wire over the bumpers and the corkscrew, as
    rendered, made small. Written as <folder>/icon.tga, and as a PNG too where `png` says"""
    p = tilt["camera"]

    def to_pixel(x, y, z):
        w = p[8] * x + p[9] * y + p[10] * z + p[11]
        return (p[0] * x + p[1] * y + p[2] * z + p[3]) / w, (p[4] * x + p[5] * y + p[6] * z + p[7]) / w

    cx, cy = to_pixel(200, 255, 50)
    half = (to_pixel(340, 250, 0)[0] - to_pixel(60, 250, 0)[0]) / 2
    width, height, rows = read_tga(Path(folder) / (tilt["background"] + ".tga"))
    out = bytearray()
    for j in range(size):
        for i in range(size):
            total = [0, 0, 0]
            count = 0
            x0, y0 = cx - half + 2 * half * i / size, cy - half + 2 * half * j / size
            step = 2 * half / size / 4
            for dy in range(4):
                for dx in range(4):
                    x, y = int(x0 + dx * step), int(y0 + dy * step)
                    if 0 <= x < width and 0 <= y < height:
                        for c in range(3):
                            total[c] += rows[y][x * 4 + c]
                        count += 1
            out += bytes(int(t / max(1, count)) for t in total)
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, size, size, 32, 8)
    body = b"".join(bytes((out[(y * size + x) * 3 + 2], out[(y * size + x) * 3 + 1], out[(y * size + x) * 3], 255))
                    for y in range(size - 1, -1, -1) for x in range(size))
    (Path(folder) / "icon.tga").write_bytes(header + body)
    if png:
        write_png(png, size, size, out)
    print(Path(folder) / "icon.tga")


def write_png(path, width, height, pixels):
    rows = b"".join(b"\x00" + bytes(pixels[y * width * 3:(y + 1) * width * 3]) for y in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    Path(path).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(rows, 6)) + chunk(b"IEND", b""))


ROLE_COLOURS = {
    "rail": (200, 200, 210), "rubber": (240, 240, 240), "post": (240, 240, 240), "bumper": (255, 90, 60),
    "sling": (255, 200, 60), "target": (255, 60, 60), "gate": (90, 200, 255), "spinner": (200, 120, 255),
    "rollover": (255, 230, 120), "saucer": (80, 160, 255), "ramp": (90, 230, 120), "kickback": (255, 150, 40),
    "drain": (120, 40, 40), "plunger": (160, 160, 160), "flipper": (255, 255, 255),
}


def preview(table, path, scale=1):
    width, height = table["width"] * scale, table["height"] * scale
    pixels = bytearray([18, 22, 34] * (width * height))

    def dot(x, y, colour):
        x, y = int(x * scale), int(y * scale)
        if 0 <= x < width and 0 <= y < height:
            i = (y * width + x) * 3
            pixels[i:i + 3] = bytes(colour)

    def segment(x1, y1, x2, y2, colour):
        steps = int(max(abs(x2 - x1), abs(y2 - y1)) * scale * 2) + 1
        for k in range(steps + 1):
            dot(x1 + (x2 - x1) * k / steps, y1 + (y2 - y1) * k / steps, colour)

    def ring(x, y, r, colour):
        steps = int(r * scale * 8) + 8
        for k in range(steps):
            a = 2 * math.pi * k / steps
            dot(x + r * math.cos(a), y + r * math.sin(a), colour)

    for shape in table["shapes"]:
        colour = ROLE_COLOURS.get(shape.get("role"), (255, 0, 255))
        if shape.get("layers", 1) == 2:
            colour = tuple(c // 2 + 40 for c in colour)
        kind = shape["kind"]
        if kind == "line":
            p = shape["points"]
            for i in range(0, len(p) - 2, 2):
                segment(p[i], p[i + 1], p[i + 2], p[i + 3], colour)
        elif kind == "circle":
            ring(shape["x"], shape["y"], shape["r"], colour)
        elif kind == "box":
            l, t, r, b = shape["left"], shape["top"], shape["right"], shape["bottom"]
            for a in ((l, t, r, t), (r, t, r, b), (r, b, l, b), (l, b, l, t)):
                segment(*a, colour)
        elif kind == "paddle":
            for angle in (shape["rest"], shape["up"]):
                tx = shape["x"] + shape["length"] * math.cos(angle)
                ty = shape["y"] + shape["length"] * math.sin(angle)
                ring(shape["x"], shape["y"], shape["base"], colour)
                ring(tx, ty, shape["tip"], colour)
                segment(shape["x"], shape["y"], tx, ty, colour)
    for lamp in table["lamps"]:
        ring(lamp["x"], lamp["y"], lamp["r"], (255, 255, 0))
    sx, sy = table["start"]
    ring(sx, sy, table["ball"], (180, 255, 255))
    write_png(path, width, height, pixels)
    print(path)


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)
    folder = Path(args[0])
    folder.mkdir(parents=True, exist_ok=True)
    table = write_table(folder)
    if "--preview" in args:
        preview(table, args[args.index("--preview") + 1], 2)
    if "--no-art" not in args:
        import pinball_art
        cache = Path(args[args.index("--cache") + 1]) if "--cache" in args else CACHE
        tilt = render_tilt(folder, cache, "--quick" in args)
        if not tilt:
            raise SystemExit("The table can't be drawn without Blender")
        art = {"colours": {k: [round(c, 3) for c in v] for k, v in pinball_art.COLOURS.items()}, "tilt": tilt}
        make_icon(folder, tilt, Path(__file__).resolve().parent.parent / ".github" / "readme" / "icons" / "pinball.png")
        path = folder / "Art.lua"
        path.write_text("-- Made by Tools/make_pinball.py with Tools/pinball_art.py: change those, not this\n"
                        "local _, ns = ...\n"
                        "ns.Art = " + lua(art) + "\n")
        print(path)


if __name__ == "__main__":
    main()
