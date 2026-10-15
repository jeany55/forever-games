#!/usr/bin/env python3
"""Writes Data/Minimaps.lua: the file id of every tile of the client's minimap for the two old
continents, from the community's list of the client's files (github.com/wowdev/wow-listfile,
community-listfile.csv). The client finds these by id only: their names aren't in its own index.

Tiles with ids from 300000 up are from after the original game (Outland's continent is apart,
but the Eastern Kingdoms gained tiles later, Quel'Thalas, Gilneas, ...): they are kept, marked
later, as the client in front of us may or may not have them.

    python3 make_minimaps.py <community-listfile.csv>
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
FOLDERS = {"azeroth": "Azeroth", "kalimdor": "Kalimdor"}
LATER = 300000
PATTERN = re.compile(r"^(\d+);world/minimaps/(azeroth|kalimdor)/map(\d+)_(\d+)\.blp$", re.I)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    tiles = {name: [] for name in FOLDERS.values()}
    with open(sys.argv[1], encoding="utf-8", errors="replace") as listfile:
        for line in listfile:
            match = PATTERN.match(line.strip())
            if match:
                file_id, folder, col, row = match.groups()
                tiles[FOLDERS[folder.lower()]].append((int(col), int(row), int(file_id)))
    out = HERE / "Data" / "Minimaps.lua"
    out.parent.mkdir(exist_ok=True)
    with open(out, "w", newline="\n") as lua:
        lua.write("-- Made by make_minimaps.py from the community listfile: the minimap's tiles by\n")
        lua.write("-- continent, col * 100 + row = file id, negative where it is from after the original game\n")
        lua.write("local _, ns = ...\nns.MINIMAPS = {\n")
        for name, found in tiles.items():
            found.sort()
            lua.write(f"  {name} = {{\n")
            for start in range(0, len(found), 8):
                part = found[start:start + 8]
                lua.write("    " + " ".join(f"[{c * 100 + r}] = {i if i < LATER else -i}," for c, r, i in part) + "\n")
            lua.write("  },\n")
        lua.write("}\n")
    for name, found in tiles.items():
        later = sum(1 for _, _, i in found if i >= LATER)
        print(f"{name}: {len(found)} tiles, {later} of them later")
    print(out)


if __name__ == "__main__":
    main()
