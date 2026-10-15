#!/usr/bin/env python3
"""Adds a stitched panorama (Tools/GeoBench, stitch.py) to the places Where in Azeroth deals,
and writes the catalogue the game reads.

    Tools/GeoBench/python.sh ../places.py add <pano> <id>    a stitched panorama as place <id>: c3 for
                                                             your capture 3, bob3 for a friend's
    Tools/GeoBench/python.sh ../places.py list
    Tools/GeoBench/python.sh ../places.py write                 Games/Where/Places.lua again

Tools/places.json is the catalogue, in the order places were added: a place is only ever added
at its end, because the game deals by that order (Engine/Places.lua) and every player has to
deal the same places from the same seed. To take one out or change where one is, bump the
game's version in Games/Where.lua.

The panorama's pictures go into the addon of places, ForeverGames_Places/Images/<id>_<n>.blp, a
BLP each (Tools/blp.py), and what the game needs to know of each place into
Games/Where/Places.lua: where it is, and how its panorama is cut and how far up and down it goes.
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
CATALOGUE = HERE / "places.json"
PACK = ROOT / "ForeverGames_Places" / "Images"
LUA = ROOT / "Games" / "Where" / "Places.lua"


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
    with open(LUA, "w", newline="\n") as out:
        out.write("-- Every place Where in Azeroth deals, in the order they were added: written by\n")
        out.write("-- Tools/places.py from Tools/places.json, run that again rather than change this.\n")
        out.write("-- Only ever added to at the end, see Engine/Places.lua.\n\n")
        out.write("--- @type nil, ForeverGamesPrivate\nlocal _, private = ...\n\n")
        out.write("private.WherePlaces = {\n")
        for place in places:
            out.write("  " + lua(place) + ",\n")
        out.write("}\n")
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
    if len(sys.argv) >= 2 and sys.argv[1] == "add" and len(sys.argv) == 4:
        add(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 2 and sys.argv[1] == "list":
        for place in load():
            print(f"{place['id']:24} {place['zone']} / {place.get('subzone') or ''}  ({place['continent']}: {place['x']}, {place['y']})")
    elif len(sys.argv) == 2 and sys.argv[1] == "write":
        write(for_game(load()))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
