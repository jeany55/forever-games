#!/usr/bin/env python3
"""Writes GUI/MapOverlays.lua: every explored-area picture of every map of the client, so that a
map drawn by GUI/MapView.lua shows the whole of it, explored or not, the same for every player.

The client keeps them in its WorldMapOverlay and WorldMapOverlayTile tables, which wago.tools
exports for each build; the world map draws only those a character has explored
(C_MapExplorationInfo.GetExploredMapTextures). An overlay belongs to a map's art (UiMapArtID,
which C_Map.GetMapArtID gives for a map), lies at an offset into it in the art's pixels, is cut
into tiles the size of the map's own (Blizzard_SharedMapDataProviders/MapExplorationDataProvider
lays them out), and names the area it shows. Overlays without tiles are left out.

    python3 make_map_overlays.py [build]
"""
import csv
import io
import sys
import urllib.request
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "GUI" / "MapOverlays.lua"
BUILD = "1.60.1.70374"
URL = "https://wago.tools/db2/{table}/csv?build={build}"


def table(name, build):
    # It turns away Python's own name for itself
    request = urllib.request.Request(URL.format(table=name, build=build), headers={"User-Agent": "curl/8"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return list(csv.DictReader(io.StringIO(response.read().decode("utf-8"))))


def main():
    build = sys.argv[1] if len(sys.argv) > 1 else BUILD
    overlays = table("WorldMapOverlay", build)
    tiles = defaultdict(list)
    for tile in table("WorldMapOverlayTile", build):
        if tile["LayerIndex"] == "0":
            tiles[tile["WorldMapOverlayID"]].append((int(tile["RowIndex"]), int(tile["ColIndex"]), int(tile["FileDataID"])))

    by_art = defaultdict(list)
    for overlay in overlays:
        found = sorted(tiles[overlay["ID"]])
        if not found:
            continue
        fields = [int(overlay[key]) for key in ("TextureWidth", "TextureHeight", "OffsetX", "OffsetY", "HitRectLeft",
                                                  "HitRectTop", "HitRectRight", "HitRectBottom", "AreaID_0")]
        by_art[int(overlay["UiMapArtID"])].append(fields + [file_id for _, _, file_id in found])

    with open(OUT, "w", newline="\n") as lua:
        lua.write("-- Every explored-area picture of every map, by the map's art (C_Map.GetMapArtID): written by\n")
        lua.write(f"-- Tools/make_map_overlays.py from the client's WorldMapOverlay tables, build {build}. Run that\n")
        lua.write("-- again rather than change this. Each is: width, height, left, top (in the art's pixels), the\n")
        lua.write("-- rectangle that names it (left, top, right, bottom), the area it shows (C_Map.GetAreaInfo), then\n")
        lua.write("-- its tiles' file ids a row at a time.\n\n")
        lua.write("--- @type nil, ForeverGamesPrivate\nlocal _, private = ...\n\nprivate.MapOverlays = {\n")
        for art in sorted(by_art):
            lua.write(f"  [{art}] = {{\n")
            for fields in sorted(by_art[art], key=lambda f: (f[3], f[2])):
                lua.write("    { " + ", ".join(str(value) for value in fields) + " },\n")
            lua.write("  },\n")
        lua.write("}\n")
    count = sum(len(found) for found in by_art.values())
    print(f"{OUT}: {count} overlays on {len(by_art)} maps")


if __name__ == "__main__":
    main()
