#!/usr/bin/env python3
"""Adds a stitched panorama (Tools/GeoBench, stitch.py) to the places Where in Azeroth deals,
and writes the pack of places the game reads.

    Tools/GeoBench/python.sh ../places.py add <pano> <id>    a stitched panorama as place <id>: c3 for
                                                             your capture 3, bob3 for a friend's
    Tools/GeoBench/python.sh ../places.py list
    Tools/GeoBench/python.sh ../places.py write              ForeverGames_Where_Places/Places.lua again

Places come in packs, addons of their own named ForeverGames_Where_<Name>. Without --pack it is
ForeverGames_Where_Places, the one that comes with the game. With --pack <Name> before the rest
it is ForeverGames_Where_<Name>, which is made, .toc and all, the first time a place is added to
it: a folder to drop into Interface/AddOns next to ForeverGames_Where, and its places are dealt
along with every other pack's.

    Tools/GeoBench/python.sh ../places.py --pack Bob add bob3 bobsfarm

Tools/places.json is the catalogue of ForeverGames_Where_Places, Tools/places_<Name>.json that of
another pack, in the order places were added: a place is only ever added at its end, because the
game deals by that order (Engine/Places.lua) and every player has to deal the same places from
the same seed. The game's version is worked out from which places there are, so two players
with other packs, or another place in one, are told they are on other versions.

The panorama's pictures go into the pack's Images/<id>_<n>.blp, a BLP each (Tools/blp.py), and
what the game needs to know of each place into its Places.lua: where it is, and how its panorama
is cut and how far up and down it goes.
"""
import json
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
import blp  # noqa: E402

BENCH = HERE / "GeoBench" / "Images"
# The pack being worked on, ForeverGames_Where_Places unless --pack says another (main)
NAME = "Places"
ADDON = "ForeverGames_Where_Places"
CATALOGUE = HERE / "places.json"
FOLDER = ROOT / ADDON
PACK = FOLDER / "Images"
LUA = FOLDER / "Places.lua"


def use_pack(name):
    global NAME, ADDON, CATALOGUE, FOLDER, PACK, LUA
    if not re.fullmatch(r"[A-Z][A-Za-z0-9]{0,31}", name):
        sys.exit("A pack's name is a capital letter then letters or digits, as in Bob or Northrend")
    NAME, ADDON = name, f"ForeverGames_Where_{name}"
    CATALOGUE = HERE / ("places.json" if name == "Places" else f"places_{name}.json")
    FOLDER = ROOT / ADDON
    PACK = FOLDER / "Images"
    LUA = FOLDER / "Places.lua"


TOC = """## Interface: 16001
## Title: Forever Games: Where in Azeroth, {name}
## Notes: Places for Where in Azeroth to take you, and their panoramas
## Version: 1.0.0
## Dependencies: ForeverGames_Where
## Group: ForeverGames
## IconTexture: Interface\\AddOns\\ForeverGames_Where\\Images\\icon

Places.lua
"""


def load():
    return json.loads(CATALOGUE.read_text()) if CATALOGUE.exists() else []


def lua(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return repr(round(value, 5))
    if isinstance(value, str):
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if isinstance(value, list):
        return "{ " + ", ".join(lua(v) for v in value) + " }"
    if isinstance(value, dict):
        return "{ " + ", ".join(f"{k} = {lua(v)}" for k, v in value.items() if v is not None) + " }"
    raise TypeError(value)


def for_game(places):
    """What the game is told of each place: not which panorama it was made from"""
    return [{k: v for k, v in p.items() if k not in ("capture", "source")} for p in places]


def write(places):
    LUA.parent.mkdir(parents=True, exist_ok=True)
    toc = FOLDER / f"{ADDON}.toc"
    if not toc.exists():
        toc.write_text(TOC.format(name=NAME), newline="\n")
        print(toc)
    with open(LUA, "w", newline="\n") as out:
        out.write(f"-- The places of {ADDON} for Where in Azeroth to deal, in the order they were added:\n")
        out.write(f"-- written by Tools/places.py from Tools/{CATALOGUE.name}, run that again rather than change\n")
        out.write("-- this. Only ever added to at the end, see Engine/Places.lua.\n\n")
        out.write("local ADDON = ...\n\n")
        out.write('ForeverGamesAPI.Places.AddPack("where", ADDON, {\n')
        for place in places:
            out.write("  " + lua(place) + ",\n")
        out.write("})\n")
    print(LUA)


def add(name, place_id):
    if not re.fullmatch(r"[a-z][a-z0-9]{1,23}", place_id):
        sys.exit("A place's id is a lower case letter then letters or digits, 2 to 24 of them")
    places = load()
    if any(p["id"] == place_id for p in places):
        sys.exit(f"There is a place {place_id} already")
    panos = json.loads((BENCH / "panos.json").read_text())
    # A bare number is one of your own captures
    name = f"c{name}" if name.isdigit() else name
    pano = next((p for p in panos if p["name"] == name), None)
    if not pano:
        sys.exit(f"There is no panorama {name}: stitch it first (Tools/GeoBench/python.sh stitch.py)")
    if any(p.get("source") == name for p in places):
        sys.exit(f"{name} is a place already")
    PACK.mkdir(parents=True, exist_ok=True)
    for tile in range(1, pano["tiles"] + 1):
        source = BENCH / f"{pano['file']}_{tile}.tga"
        rgb = np.asarray(Image.open(source).convert("RGB"))
        blp.write_blp(PACK / f"{place_id}_{tile}.blp", rgb)
    entry = {
        "id": place_id,
        "continent": int(pano["continent"]),
        "x": round(float(pano["worldX"]), 1),
        "y": round(float(pano["worldY"]), 1),
        "mapID": int(pano["mapID"]),
        "zone": pano.get("zone"),
        "subzone": pano.get("subzone") or None,
        "pano": {
            "tiles": pano["tiles"], "width": pano["width"], "height": pano["height"],
            "top": round(pano["top"], 5), "bottom": round(pano["bottom"], 5),
            "facing": round(float(pano["facing"]), 4) if pano.get("facing") is not None else None,
            "sky": pano["sky"], "ground": pano["ground"],
        },
        "source": name,
    }
    places.append(entry)
    CATALOGUE.write_text(json.dumps(places, indent=1))
    write(for_game(places))
    print(f"{place_id}: {entry['zone']} / {entry['subzone']}, {pano['tiles']} pictures in {PACK}")


def main():
    args = sys.argv[1:]
    if len(args) >= 2 and args[0] == "--pack":
        use_pack(args[1])
        args = args[2:]
    if len(args) == 3 and args[0] == "add":
        add(args[1], args[2])
    elif args == ["list"]:
        for place in load():
            print(f"{place['id']:24} {place['zone']} / {place.get('subzone') or ''}  ({place['continent']}: {place['x']}, {place['y']})")
    elif args == ["write"]:
        write(for_game(load()))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
