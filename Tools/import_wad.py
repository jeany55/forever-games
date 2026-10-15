#!/usr/bin/env python3
"""Turns a map of a Doom WAD into a sector map for the engine (Engine/SectorMap.lua), with the
pictures it is drawn with.

    python3 Tools/import_wad.py freedoom1.wad E1M1 freedoom_e1m1 Images/Freedoom Games/Maps/FreedoomE1M1.lua \
        --icon BIGDOOR2 Images/Icons/freedoom.tga

Freedoom's own maps go into an addon of their own that Forever Games loads when a game of it is
played, made by Tools/import_freedoom.sh.

Any map made for Doom will do: one of Freedoom's, or one drawn in a Doom map editor (SLADE,
Ultimate Doom Builder) for a game of the addon's own. What a game made of the map is up to the
game: the engine only knows sectors, lines and pictures.

Writes the map as Lua, registered under the id given (SectorMap.Register), and every picture the
map uses as a TGA under the folder given: walls/<NAME>.tga for the walls, put together from
their patches, and flats/<NAME>.tga for floors and ceilings. Every picture used is taken, the
other frames of one that is animated (Doom's own list of those, ANIMATIONS) and the other face of
a switch (SW1... and SW2...), and the sky. The client only takes pictures whose sides are
powers of two, so a wall or flat that isn't is stretched to the next one up, a pixel at a time:
the map still says how many pixels it really is, which is what it is measured in.

Whatever stands in the map comes with it too, of the kinds of thing Doom has that the tool knows
(KINDS, taken from Doom's own tables): how big each is, whether it is in the way, hangs from the
ceiling or can be picked up, and its sprites, under sprites/<LUMP>.tga, every frame it is
animated through from every side it has. A sprite is drawn from its own offsets, so it isn't
stretched but put in the corner of a picture big enough for it. The monsters come with every
frame they have, for whatever game plays them to go through. Besides those, the kinds that turn
up during play (DROPPED, what a monster leaves behind) and the sprites that aren't things at all
(EFFECTS: smoke, blood and fireballs, and the player's weapons). And with --hud, Doom's status bar, its numbers, keys, faces and the small font messages are
written in, under hud/, as a set of pictures of their own (SectorMap.RegisterPictures). With
--sounds, Doom's sound effects (SOUNDS) go into a folder as Ogg Vorbis, each as loud as it is
heard close by, a way off and far off (1, 2 and 3: the client plays a file as loud as it is, so how
far away something is heard is a choice of file). That takes ffmpeg; without it the sounds are left
out, and say so.

Only the standard library is used. Pass --preview <folder> to also get PNG copies there, which
are easier to look at than TGA.
"""
import argparse
import shutil
import struct
import subprocess
import tempfile
import wave
import zlib
from pathlib import Path

# Doom's animated pictures: the first and last frame of each, every frame in between in the
# order the WAD has them. They change every 8 tics
ANIMATED_FLATS = [("NUKAGE1", "NUKAGE3"), ("FWATER1", "FWATER4"), ("SWATER1", "SWATER4"), ("LAVA1", "LAVA4"),
                  ("BLOOD1", "BLOOD3"), ("RROCK05", "RROCK08"), ("SLIME01", "SLIME04"), ("SLIME05", "SLIME08"),
                  ("SLIME09", "SLIME12")]
ANIMATED_WALLS = [("BLODGR1", "BLODGR4"), ("SLADRIP1", "SLADRIP3"), ("BLODRIP1", "BLODRIP4"), ("FIREWALA", "FIREWALL"),
                  ("GSTFONT1", "GSTFONT3"), ("FIRELAVA", "FIRELAV3"), ("FIREMAG1", "FIREMAG3"), ("FIREBLU1", "FIREBLU2"),
                  ("ROCKRED1", "ROCKRED3"), ("BFALL1", "BFALL4"), ("SFALL1", "SFALL4"), ("WFALL1", "WFALL4"),
                  ("DBRAIN1", "DBRAIN4")]
ANIMATION_TICS = 8
SKY_FLAT = "F_SKY1"

# Doom's kinds of thing, by the number the map gives them: the sprite, the frames it goes through
# in turn and how many tics each lasts, which frames light themselves (or all of them), how far it
# reaches from its middle and how tall it is, and what it is: in the way ("solid"), hanging from
# the ceiling, something to pick up. The ones nobody sees (player starts, teleport exits) and the
# monsters aren't here
def kind(sprite, frames="A", tics=0, bright="", radius=20, height=16, *flags):
    return {"sprite": sprite, "frames": frames, "tics": tics, "bright": bright, "radius": radius, "height": height,
            "solid": "solid" in flags, "hanging": "hanging" in flags, "pickup": "pickup" in flags, "monster": "monster" in flags}


KINDS = {
    # Health and armour
    2011: kind("STIM", "A", 0, "", 20, 16, "pickup"),
    2012: kind("MEDI", "A", 0, "", 20, 16, "pickup"),
    2014: kind("BON1", "ABCDCB", 6, "", 20, 16, "pickup"),
    2015: kind("BON2", "ABCDCB", 6, "", 20, 16, "pickup"),
    2013: kind("SOUL", "ABCDCB", 6, "*", 20, 16, "pickup"),
    83: kind("MEGA", "ABCD", 6, "*", 20, 16, "pickup"),
    2018: kind("ARM1", "AB", 6, "B", 20, 16, "pickup"),
    2019: kind("ARM2", "AB", 6, "B", 20, 16, "pickup"),
    # Powers
    2022: kind("PINV", "ABCD", 6, "*", 20, 16, "pickup"),
    2023: kind("PSTR", "A", 0, "*", 20, 16, "pickup"),
    2024: kind("PINS", "ABCD", 6, "*", 20, 16, "pickup"),
    2025: kind("SUIT", "A", 0, "*", 20, 16, "pickup"),
    2026: kind("PMAP", "ABCDCB", 6, "*", 20, 16, "pickup"),
    2045: kind("PVIS", "AB", 6, "A", 20, 16, "pickup"),
    # Keys
    5: kind("BKEY", "AB", 10, "B", 20, 16, "pickup"),
    6: kind("YKEY", "AB", 10, "B", 20, 16, "pickup"),
    13: kind("RKEY", "AB", 10, "B", 20, 16, "pickup"),
    40: kind("BSKU", "AB", 10, "B", 20, 16, "pickup"),
    39: kind("YSKU", "AB", 10, "B", 20, 16, "pickup"),
    38: kind("RSKU", "AB", 10, "B", 20, 16, "pickup"),
    # Ammunition and weapons
    2007: kind("CLIP", "A", 0, "", 20, 16, "pickup"),
    2048: kind("AMMO", "A", 0, "", 20, 16, "pickup"),
    2008: kind("SHEL", "A", 0, "", 20, 16, "pickup"),
    2049: kind("SBOX", "A", 0, "", 20, 16, "pickup"),
    2010: kind("ROCK", "A", 0, "", 20, 16, "pickup"),
    2046: kind("BROK", "A", 0, "", 20, 16, "pickup"),
    2047: kind("CELL", "A", 0, "", 20, 16, "pickup"),
    17: kind("CELP", "A", 0, "", 20, 16, "pickup"),
    8: kind("BPAK", "A", 0, "", 20, 16, "pickup"),
    2001: kind("SHOT", "A", 0, "", 20, 16, "pickup"),
    82: kind("SGN2", "A", 0, "", 20, 16, "pickup"),
    2002: kind("MGUN", "A", 0, "", 20, 16, "pickup"),
    2003: kind("LAUN", "A", 0, "", 20, 16, "pickup"),
    2004: kind("PLAS", "A", 0, "", 20, 16, "pickup"),
    2005: kind("CSAW", "A", 0, "", 20, 16, "pickup"),
    2006: kind("BFUG", "A", 0, "", 20, 16, "pickup"),
    # Lights, columns and trees
    2028: kind("COLU", "A", 0, "*", 16, 48, "solid"),
    2035: kind("BAR1", "AB", 6, "", 10, 42, "solid"),
    70: kind("FCAN", "ABC", 4, "*", 16, 16, "solid"),
    34: kind("CAND", "A", 0, "*", 20, 16),
    35: kind("CBRA", "A", 0, "*", 16, 16, "solid"),
    44: kind("TBLU", "ABCD", 4, "*", 16, 16, "solid"),
    45: kind("TGRN", "ABCD", 4, "*", 16, 16, "solid"),
    46: kind("TRED", "ABCD", 4, "*", 16, 16, "solid"),
    55: kind("SMBT", "ABCD", 4, "*", 16, 16, "solid"),
    56: kind("SMGT", "ABCD", 4, "*", 16, 16, "solid"),
    57: kind("SMRT", "ABCD", 4, "*", 16, 16, "solid"),
    85: kind("TLMP", "ABCD", 4, "*", 16, 16, "solid"),
    86: kind("TLP2", "ABCD", 4, "*", 16, 16, "solid"),
    48: kind("ELEC", "A", 0, "", 16, 16, "solid"),
    30: kind("COL1", "A", 0, "", 16, 16, "solid"),
    31: kind("COL2", "A", 0, "", 16, 16, "solid"),
    32: kind("COL3", "A", 0, "", 16, 16, "solid"),
    33: kind("COL4", "A", 0, "", 16, 16, "solid"),
    36: kind("COL5", "AB", 14, "", 16, 16, "solid"),
    37: kind("COL6", "A", 0, "", 16, 16, "solid"),
    41: kind("CEYE", "ABCB", 6, "*", 16, 16, "solid"),
    42: kind("FSKU", "ABC", 6, "*", 16, 16, "solid"),
    43: kind("TRE1", "A", 0, "", 16, 16, "solid"),
    54: kind("TRE2", "A", 0, "", 32, 16, "solid"),
    47: kind("SMIT", "A", 0, "", 16, 16, "solid"),
    25: kind("POL1", "A", 0, "", 16, 16, "solid"),
    26: kind("POL6", "AB", 8, "", 16, 16, "solid"),
    27: kind("POL4", "A", 0, "", 16, 16, "solid"),
    28: kind("POL2", "A", 0, "", 16, 16, "solid"),
    29: kind("POL3", "AB", 6, "*", 16, 16, "solid"),
    # What is left of the fallen
    10: kind("PLAY", "W"),
    12: kind("PLAY", "W"),
    15: kind("PLAY", "N"),
    18: kind("POSS", "L"),
    19: kind("SPOS", "L"),
    20: kind("TROO", "M"),
    21: kind("SARG", "N"),
    22: kind("HEAD", "L"),
    24: kind("POL5", "A"),
    79: kind("POB1", "A"),
    80: kind("POB2", "A"),
    81: kind("BRS1", "A"),
    # Monsters: every frame they have, what they do with them is the game's
    3004: kind("POSS", "ABCDEFGHIJKLMNOPQRSTU", 0, "F", 20, 56, "solid", "monster"),
    9: kind("SPOS", "ABCDEFGHIJKLMNOPQRSTU", 0, "F", 20, 56, "solid", "monster"),
    3001: kind("TROO", "ABCDEFGHIJKLMNOPQRSTU", 0, "", 20, 56, "solid", "monster"),
    3002: kind("SARG", "ABCDEFGHIJKLMN", 0, "", 30, 56, "solid", "monster"),
    58: kind("SARG", "ABCDEFGHIJKLMN", 0, "", 30, 56, "solid", "monster"),
    3006: kind("SKUL", "ABCDEFGHIJK", 0, "ABCD", 16, 56, "solid", "monster"),
    3003: kind("BOSS", "ABCDEFGHIJKLMNO", 0, "", 24, 64, "solid", "monster"),
    # Hanging from the ceiling
    49: kind("GOR1", "ABCB", 10, "", 16, 68, "solid", "hanging"),
    50: kind("GOR2", "A", 0, "", 16, 84, "solid", "hanging"),
    51: kind("GOR3", "A", 0, "", 16, 84, "solid", "hanging"),
    52: kind("GOR4", "A", 0, "", 16, 68, "solid", "hanging"),
    53: kind("GOR5", "A", 0, "", 16, 52, "solid", "hanging"),
    59: kind("GOR2", "A", 0, "", 20, 84, "hanging"),
    60: kind("GOR4", "A", 0, "", 20, 68, "hanging"),
    61: kind("GOR3", "A", 0, "", 20, 52, "hanging"),
    62: kind("GOR5", "A", 0, "", 20, 52, "hanging"),
    63: kind("GOR1", "ABCB", 10, "", 20, 68, "hanging"),
}

# Kinds that aren't in a map but turn up in it: what monsters drop
DROPPED = [2007, 2001]
# Sprites of what isn't a thing of the map: the player, for a rival's ghost to be drawn with, fireballs, the flash of a teleport, a barrel going up, the smoke of a bullet on a wall, blood,
# the player's weapons and their flashes, and what the rocket launcher, the plasma gun and the BFG fire and how that bursts. Every
# frame there is of them
EFFECTS = ["PLAY", "BAL1", "BAL7", "TFOG", "BEXP", "PUFF", "BLUD", "PUNG", "SAWG", "PISG", "PISF", "SHTG", "SHTF", "CHGG", "CHGF",
           "MISG", "MISF", "MISL", "PLSG", "PLSF", "PLSS", "PLSE", "BFGG", "BFGF", "BFS1", "BFE1", "BFE2"]

# Doom's sound effects that are used, by their names without the DS, and how loud each of the three
# files of one is
SOUNDS = """pistol shotgn sawup sawidl sawful sawhit rlaunc rxplod firsht firxpl pstart pstop doropn dorcls bdopn
bdcls swtchn swtchx plpain pldeth slop punch itemup wpnup oof telept posit1 posit2 posit3 bgsit1 bgsit2 sgtsit
brssit sgtatk claw posact bgact dmact popain dmpain podth1 podth2 podth3 bgdth1 bgdth2 sgtdth brsdth sklatk
getpow plasma bfg barexp noway stnmov""".split()
LOUDNESS = [1.0, 0.55, 0.25]


def sounds(wad, folder):
    """Doom's sounds as Ogg Vorbis files, three of each: how many were written"""
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        print("warning: no ffmpeg, so no sounds: install it and run this again")
        return 0
    folder.mkdir(parents=True, exist_ok=True)
    written = 0
    with tempfile.TemporaryDirectory() as scratch:
        for name in SOUNDS:
            raw = wad.named("DS" + name.upper())
            if raw is None:
                print(f"warning: no sound {name}")
                continue
            # Doom's own: a format, the rate, how many samples, then the samples, eight bits and
            # unsigned, with sixteen of padding at either end
            _, rate, count = struct.unpack_from("<HHI", raw, 0)
            samples = raw[8 + 16:8 + count - 16]
            plain = Path(scratch) / (name + ".wav")
            with wave.open(str(plain), "wb") as out:
                out.setnchannels(1)
                out.setsampwidth(1)
                out.setframerate(rate)
                out.writeframes(samples)
            for level, loudness in enumerate(LOUDNESS, 1):
                path = folder / f"{name}{level}.ogg"
                subprocess.run([ffmpeg, "-loglevel", "error", "-y", "-i", str(plain), "-filter:a", f"volume={loudness}", "-ar", "22050",
                                "-c:a", "libvorbis", "-q:a", "3", str(path)], check=True)
                written += 1
    return written


# Doom's status bar: its back, the big red numbers and the small ones, the keys, the faces and
# the font messages are written in
HUD = ["STBAR", "STARMS", "STTMINUS", "STTPRCNT", "STFDEAD0", "STFGOD0"]
HUD += [f"STTNUM{digit}" for digit in range(10)] + [f"STYSNUM{digit}" for digit in range(10)] + [f"STGNUM{digit}" for digit in range(10)]
HUD += [f"STKEYS{key}" for key in range(9)]
HUD += [f"{face}{level}" for level in range(5) for face in ("STFTL", "STFTR", "STFOUCH", "STFEVL", "STFKILL")]
HUD = [name if not name.startswith(("STFTL", "STFTR")) else name + "0" for name in HUD]
HUD += [f"STFST{level}{look}" for level in range(5) for look in range(3)]
HUD += [f"STCFN{code:03d}" for code in range(33, 96)]
# And the screen a map is finished with: the episode's map behind, the map's name and "finished",
# what was killed, picked up and found, the time and the par, and their big numbers
HUD += ["WIMAP0", "WIF", "WIOSTK", "WIOSTI", "WISCRT2", "WITIME", "WIPAR", "WIPCNT", "WICOLON", "WIMINUS", "WISUCKS"]
HUD += [f"WILV0{map}" for map in range(9)] + [f"WINUM{digit}" for digit in range(10)]


class Wad:
    def __init__(self, path):
        self.files = []
        self.lumps = []
        self.add(path)

    def add(self, path):
        """Another WAD's lumps after this one's, as Doom loads a PWAD over its IWAD"""
        data = Path(path).read_bytes()
        kind, count, offset = struct.unpack_from("<4sii", data, 0)
        if kind not in (b"IWAD", b"PWAD"):
            raise SystemExit(f"{path} is not a WAD")
        self.files.append(data)
        for index in range(count):
            position, size, name = struct.unpack_from("<ii8s", data, offset + 16 * index)
            self.lumps.append((name.rstrip(b"\0").decode("ascii", "replace").upper(), position, size, len(self.files) - 1))

    def index(self, name, start=0):
        for index in range(start, len(self.lumps)):
            if self.lumps[index][0] == name:
                return index
        return None

    def read(self, index):
        _, position, size, file = self.lumps[index]
        return self.files[file][position:position + size]

    def named(self, name):
        index = self.index(name)
        return None if index is None else self.read(index)

    def between(self, first, last):
        """Lumps between markers, by name: the later of two with the same name wins, as in Doom"""
        found, inside = {}, False
        for index, (name, _, size, _) in enumerate(self.lumps):
            if name in first:
                inside = True
            elif name in last:
                inside = False
            elif inside and size > 0:
                found[name] = index
        return found


def name8(raw):
    return raw.rstrip(b"\0").decode("ascii", "replace").upper()


def records(raw, form):
    size = struct.calcsize(form)
    return [struct.unpack_from(form, raw, offset) for offset in range(0, len(raw) - size + 1, size)]


def offsets(raw):
    """How far left and up of where a patch is put its top left corner is: its width, height and those"""
    return struct.unpack_from("<hhhh", raw, 0)


def picture(raw):
    """A patch: its columns of posts, as rows of palette indexes, None where it is clear"""
    width, height, _, _ = struct.unpack_from("<hhhh", raw, 0)
    rows = [[None] * width for _ in range(height)]
    for column in range(width):
        (offset,) = struct.unpack_from("<i", raw, 8 + column * 4)
        top = -1
        while raw[offset] != 255:
            delta, length = raw[offset], raw[offset + 1]
            # Tall patches count a post's top from the last one's when it is no lower down
            top = top + delta if delta <= top else delta
            for row in range(length):
                if 0 <= top + row < height:
                    rows[top + row][column] = raw[offset + 3 + row]
            offset += length + 4
    return rows


def textures(wad):
    """Every wall picture the WAD defines, by name: its size and its patches"""
    names = [name8(raw) for (raw,) in records(wad.named("PNAMES")[4:], "<8s")]
    found = {}
    for lump in ("TEXTURE1", "TEXTURE2"):
        raw = wad.named(lump)
        if raw is None:
            continue
        (count,) = struct.unpack_from("<i", raw, 0)
        for index in range(count):
            (offset,) = struct.unpack_from("<i", raw, 4 + index * 4)
            name, _, width, height, _, patches = struct.unpack_from("<8sihhih", raw, offset)
            placed = [struct.unpack_from("<hhhhh", raw, offset + 22 + 10 * part)[:3] for part in range(patches)]
            found[name8(name)] = (width, height, [(x, y, names[patch]) for x, y, patch in placed])
    return found


def compose(definition, patches, cache):
    width, height, placed = definition
    rows = [[None] * width for _ in range(height)]
    for left, top, name in placed:
        if name not in cache:
            cache[name] = picture(patches[name]) if name in patches else []
        for y, row in enumerate(cache[name]):
            if 0 <= top + y < height:
                for x, colour in enumerate(row):
                    if colour is not None and 0 <= left + x < width:
                        rows[top + y][left + x] = colour
    return rows


def power(size):
    side = 1
    while side < size:
        side *= 2
    return side


def write(path, rows, palette, preview, pad=False):
    """As a TGA of sides that are powers of two, stretched a pixel at a time where it isn't. Or
    padded, the picture in its top left corner and nothing in the rest"""
    width, height = len(rows[0]), len(rows)
    wide, tall = power(width), power(height)
    clear = any(colour is None for row in rows for colour in row)
    pixels = []
    for y in range(tall):
        if pad:
            row = rows[y] if y < height else []
        else:
            row = rows[y * height // tall]
        for x in range(wide):
            if pad:
                colour = row[x] if x < len(row) else None
            else:
                colour = row[x * width // wide]
            if colour is None:
                pixels.append((0, 0, 0, 0))
            else:
                pixels.append(palette[colour] + (255,))
    path.parent.mkdir(parents=True, exist_ok=True)
    # TGA rows run bottom to top
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, wide, tall, 32, 8)
    body = b"".join(bytes((b, g, r, a)) for y in reversed(range(tall)) for (r, g, b, a) in pixels[y * wide:(y + 1) * wide])
    path.write_bytes(header + body)
    if preview:
        raw = b"".join(b"\x00" + b"".join(bytes(pixel) for pixel in pixels[y * wide:(y + 1) * wide]) for y in range(tall))

        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

        png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", wide, tall, 8, 6, 0, 0, 0))
        png += chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
        preview.mkdir(parents=True, exist_ok=True)
        (preview / (path.parent.name + "_" + path.stem + ".png")).write_bytes(png)
    return clear


def frames(sequences, order, used):
    """Every frame of each animation one of the pictures used is in, and how they go"""
    animations = []
    for first, last in sequences:
        if first not in order or last not in order:
            continue
        start, end = order.index(first), order.index(last)
        sequence = order[start:end + 1]
        if any(name in used for name in sequence):
            used.update(sequence)
            animations.append(sequence)
    return animations


def lua(value, indent=""):
    if isinstance(value, dict):
        def key(name):
            if isinstance(name, int):
                return f"[{name}]"
            return name if name.isidentifier() else "[" + lua(name) + "]"

        if all(not isinstance(item, dict) and (not isinstance(item, (list, tuple)) or all(isinstance(each, (int, float, str)) for each in item)) for item in value.values()):
            # A record of plain values, one to a line
            return "{ " + ", ".join(f"{key(name)} = {lua(item)}" for name, item in value.items()) + " }"
        inner = indent + "  "
        parts = [f"{inner}{key(name)} = {lua(item, inner)}," for name, item in value.items()]
        return "{\n" + "\n".join(parts) + "\n" + indent + "}"
    if isinstance(value, (list, tuple)):
        if all(isinstance(item, (int, float, str)) for item in value):
            return "{ " + ", ".join(lua(item) for item in value) + " }"
        inner = indent + "  "
        return "{\n" + "\n".join(f"{inner}{lua(item, inner)}," for item in value) + "\n" + indent + "}"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if isinstance(value, float):
        return repr(round(value, 4))
    return str(value)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("wad")
    parser.add_argument("map", help="E1M1, MAP01 and so on")
    parser.add_argument("id", help="What the map is registered as, e.g. freedoom_e1m1")
    parser.add_argument("images", help="Folder for the pictures, e.g. Images/Freedoom")
    parser.add_argument("out", help="The Lua file to write the map to")
    parser.add_argument("--addon-path", default=None, help="The pictures' folder as the client knows it, Interface\\AddOns\\ForeverGames\\<images> if left out")
    parser.add_argument("--sky", default=None, help="The sky's picture, SKY1 for E1 maps and SKY1 to SKY3 by MAPxx if left out")
    parser.add_argument("--global", dest="out_global", action="store_true", help="Write the map (and the status bar) for an addon of its own, loaded on demand: into ForeverGamesSectorMaps (and ForeverGamesSectorPictures), where SectorMap finds them, rather than registered with the addon")
    parser.add_argument("--sounds", type=Path, default=None, help="Also write Doom's sound effects into this folder, as Ogg Vorbis (takes ffmpeg)")
    parser.add_argument("--hud", nargs=2, metavar=("ID", "PATH"), default=None, help="Also write the status bar's pictures, and a Lua file registering them under an id, e.g. freedoom_hud Games/Maps/FreedoomHud.lua")
    parser.add_argument("--icon", nargs=2, metavar=("PICTURE", "PATH"), default=None, help="Also write a 64 pixel icon of the middle of a wall picture, e.g. BIGDOOR2 Images/Icons/freedoom.tga")
    parser.add_argument("--pwad", type=Path, default=None, help="A WAD of the map's own (Tools/mapkit.py makes them), read over the main one, as Doom loads a PWAD: the map from it, the pictures from either")
    parser.add_argument("--preview", type=Path, default=None)
    args = parser.parse_args()

    wad = Wad(args.wad)
    if args.pwad:
        wad.add(args.pwad)
    at = wad.index(args.map.upper())
    if at is None:
        raise SystemExit(f"No {args.map} in {args.wad}")
    lump = {}
    for index in range(at + 1, min(at + 12, len(wad.lumps))):
        lump[wad.lumps[index][0]] = wad.read(index)
    for needed in ("THINGS", "LINEDEFS", "SIDEDEFS", "VERTEXES", "SEGS", "SSECTORS", "NODES", "SECTORS"):
        if needed not in lump:
            raise SystemExit(f"{args.map} has no {needed}: only maps in Doom's own format are read, built with their nodes")

    vertices = [coordinate for x, y in records(lump["VERTEXES"], "<hh") for coordinate in (x, y)]
    sectors = [{"floor": floor, "ceiling": ceiling, "floorPicture": name8(floorPicture), "ceilingPicture": name8(ceilingPicture),
                "light": light, "special": special, "tag": tag}
               for floor, ceiling, floorPicture, ceilingPicture, light, special, tag in records(lump["SECTORS"], "<hh8s8shhh")]
    sides = [{"x": x, "y": y, "upper": name8(upper), "lower": name8(lower), "middle": name8(middle), "sector": sector + 1}
             for x, y, upper, lower, middle, sector in records(lump["SIDEDEFS"], "<hh8s8s8sh")]
    lines = []
    for start, end, flags, special, tag, front, back in records(lump["LINEDEFS"], "<HHhhhHH"):
        line = {"from": start + 1, "to": end + 1, "flags": flags, "special": special, "tag": tag, "front": front + 1}
        if back != 0xFFFF:
            line["back"] = back + 1
        lines.append(line)
    segs = [{"from": start + 1, "to": end + 1, "line": line + 1, "back": direction == 1, "offset": offset}
            for start, end, _, line, direction, offset in records(lump["SEGS"], "<HHhHhh")]
    subsectors = [{"count": count, "first": first + 1} for count, first in records(lump["SSECTORS"], "<HH")]

    def child(value):
        # A subsector is marked by the top bit, and is counted negative here
        return -((value & 0x7FFF) + 1) if value & 0x8000 else value + 1

    nodes = [{"x": x, "y": y, "dx": dx, "dy": dy, "frontBox": [top, bottom, left, right], "backBox": [top2, bottom2, left2, right2],
              "front": child(front), "back": child(back)}
             for x, y, dx, dy, top, bottom, left, right, top2, bottom2, left2, right2, front, back in records(lump["NODES"], "<hhhhhhhhhhhhHH")]
    things = [{"x": x, "y": y, "angle": angle, "type": kind, "flags": flags} for x, y, angle, kind, flags in records(lump["THINGS"], "<hhhhh")]

    sky = args.sky
    if sky is None:
        number = int(args.map[3:]) if args.map.upper().startswith("MAP") else 0
        sky = "SKY1" if number < 12 else "SKY2" if number < 21 else "SKY3"

    # What is drawn with what: the walls and their other faces, the floors and their frames
    walls = {side[part] for side in sides for part in ("upper", "lower", "middle")} - {"-", ""}
    walls |= {"SW2" + name[3:] for name in walls if name.startswith("SW1")}
    walls.add(sky)
    flats = {sector[part] for sector in sectors for part in ("floorPicture", "ceilingPicture")} - {SKY_FLAT}

    palette = [tuple(wad.named("PLAYPAL")[index * 3:index * 3 + 3]) for index in range(256)]
    defined = textures(wad)
    patches = {name: wad.read(index) for name, index in wad.between({"P_START", "PP_START"}, {"P_END", "PP_END"}).items()}
    raw_flats = {name: wad.read(index) for name, index in wad.between({"F_START", "FF_START"}, {"F_END", "FF_END"}).items()}
    wall_order = list(defined)
    flat_order = list(raw_flats)
    animations = frames(ANIMATED_WALLS, wall_order, walls) + frames(ANIMATED_FLATS, flat_order, flats)

    images = Path(args.images)
    folder = args.addon_path or "Interface\\AddOns\\ForeverGames\\" + str(images).replace("/", "\\")
    pictures, cache, size = {}, {}, 0
    for name in sorted(walls):
        if name not in defined:
            print(f"warning: no wall picture {name}")
            continue
        rows = compose(defined[name], patches, cache)
        path = images / "walls" / (name + ".tga")
        clear = write(path, rows, palette, args.preview)
        size += path.stat().st_size
        pictures[name] = {"width": len(rows[0]), "height": len(rows), "clear": clear}
    floors = {}
    for name in sorted(flats):
        if name not in raw_flats or len(raw_flats[name]) < 4096:
            print(f"warning: no flat {name}")
            continue
        raw = raw_flats[name]
        path = images / "flats" / (name + ".tga")
        write(path, [list(raw[row * 64:row * 64 + 64]) for row in range(64)], palette, args.preview)
        size += path.stat().st_size
        floors[name] = {"width": 64, "height": 64}

    # Whatever stands about, of the kinds known, every frame of it from every side
    sprite_lumps = {name: wad.read(index) for name, index in wad.between({"S_START", "SS_START"}, {"S_END", "SS_END"}).items()}
    kinds, sprite_frames, sprite_pictures = {}, {}, {}

    def export(sprite, letter):
        """A frame of a sprite, from every side it has: whether there was one"""
        nonlocal size
        frame = sprite + letter
        if frame in sprite_frames:
            return True
        # One picture for every side, or one for each of eight, a picture standing for two
        # sides where its name says so, mirrored for the second
        views = [None] * 9
        for lump in sprite_lumps:
            if lump.startswith(frame) and len(lump) in (6, 8):
                views[int(lump[5])] = (lump, False)
            if len(lump) == 8 and lump[:4] == sprite and lump[6] == letter:
                views[int(lump[7])] = (lump, True)
        if views[0]:
            rotations = [[views[0][0], False]]
        elif all(views[1:]):
            rotations = [[lump, flip] for lump, flip in views[1:]]
        else:
            return False
        sprite_frames[frame] = rotations
        for lump, _ in rotations:
            if lump in sprite_pictures:
                continue
            width, height, left, top = offsets(sprite_lumps[lump])
            path = images / "sprites" / (lump + ".tga")
            write(path, picture(sprite_lumps[lump]), palette, args.preview, pad=True)
            size += path.stat().st_size
            sprite_pictures[lump] = {"width": width, "height": height, "left": left, "top": top,
                                     "fileWidth": power(width), "fileHeight": power(height)}
        return True

    for number in [thing["type"] for thing in things] + DROPPED:
        known = KINDS.get(number)
        if not known or number in kinds:
            continue
        missing = [letter for letter in sorted(set(known["frames"])) if not export(known["sprite"], letter)]
        if missing:
            print(f"warning: no sprite {known['sprite']} {''.join(missing)} for thing {number}")
        else:
            kinds[number] = known
    for sprite in EFFECTS:
        letters = sorted({lump[4] for lump in sprite_lumps if lump.startswith(sprite) and len(lump) >= 6})
        if not letters:
            print(f"warning: no sprite {sprite}")
        for letter in letters:
            export(sprite, letter)

    if args.hud:
        hud_id, hud_path = args.hud
        hud = {}
        for name in HUD:
            index = wad.index(name)
            if index is None:
                print(f"warning: no status bar picture {name}")
                continue
            raw = wad.read(index)
            width, height, left, top = offsets(raw)
            path = images / "hud" / (name + ".tga")
            write(path, picture(raw), palette, args.preview, pad=True)
            size += path.stat().st_size
            hud[name] = {"width": width, "height": height, "left": left, "top": top, "fileWidth": power(width), "fileHeight": power(height)}
        out_hud = Path(hud_path)
        out_hud.parent.mkdir(parents=True, exist_ok=True)
        header = (f"-- Doom's status bar from {Path(args.wad).name}: its back, numbers, keys, faces and font.\n"
                  f"-- Written by Tools/import_wad.py: run that again rather than change this.\n\n")
        pictures_set = lua({'folder': folder + chr(92) + 'hud', 'pictures': hud})
        if args.out_global:
            out_hud.write_text(header + f"ForeverGamesSectorPictures = ForeverGamesSectorPictures or {{}}\nForeverGamesSectorPictures[{lua(hud_id)}] = {pictures_set}\n")
        else:
            out_hud.write_text(header + "--- @type nil, ForeverGamesPrivate\nlocal _, private = ...\n\n" + f"private.SectorMap.RegisterPictures({lua(hud_id)}, {pictures_set})\n")

    if args.sounds:
        print(f"{sounds(wad, args.sounds)} sound files in {args.sounds}")

    if args.icon:
        name, path = args.icon
        rows = compose(defined[name.upper()], patches, cache)
        side = min(len(rows), len(rows[0]))
        top, left = (len(rows) - side) // 2, (len(rows[0]) - side) // 2
        square = [[rows[top + y * side // 64][left + x * side // 64] for x in range(64)] for y in range(64)]
        write(Path(path), square, palette, args.preview)

    data = {
        "name": args.map.upper(),
        "source": (args.pwad or Path(args.wad)).name,
        "folder": folder,
        "sky": sky,
        "skyFlat": SKY_FLAT,
        "animationTics": ANIMATION_TICS,
        "vertices": vertices,
        "sectors": sectors,
        "sides": sides,
        "lines": lines,
        "segs": segs,
        "subsectors": subsectors,
        "nodes": nodes,
        "things": things,
        "walls": pictures,
        "flats": floors,
        "animations": animations,
        "kinds": dict(sorted(kinds.items())),
        "spriteFrames": sprite_frames,
        "sprites": sprite_pictures,
    }
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    header = (f"-- {args.map.upper()} of {(args.pwad or Path(args.wad)).name}, as a sector map (Engine/SectorMap.lua).\n"
              f"-- Written by Tools/import_wad.py: run that again rather than change this.\n\n")
    if args.out_global:
        out.write_text(header + f"ForeverGamesSectorMaps = ForeverGamesSectorMaps or {{}}\nForeverGamesSectorMaps[{lua(args.id)}] = {lua(data)}\n")
    else:
        out.write_text(header + "--- @type nil, ForeverGamesPrivate\nlocal _, private = ...\n\n" + f"private.SectorMap.Register({lua(args.id)}, {lua(data)})\n")
    print(f"{out}: {len(sectors)} sectors, {len(lines)} lines, {len(nodes)} nodes, {len(kinds)} kinds of thing; "
          f"{len(pictures)} walls, {len(floors)} flats and {len(sprite_pictures)} sprites, {size / 1e6:.1f} MB of pictures in {images}")


if __name__ == "__main__":
    main()
