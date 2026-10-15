"""What make_images.py and stitch.py share: writing a panorama's pictures, and the list of every
panorama there is (Images/panos.json) as the bench reads it (Images/Panos.lua).

A panorama is `tiles` pictures side by side, Images/<file>_<n>.tga, all the way round from
where it was taken: its left edge is where the camera first looked, it goes round clockwise, and
its rows go from `top` to `bottom`, heights on a cylinder of radius 1 (the tangent of how far
above the horizon).
"""
import json
import os
import struct
from pathlib import Path

HERE = Path(__file__).resolve().parent
# Somewhere else for trying the scripts out
IMAGES = Path(os.environ.get("GEOBENCH_IMAGES", HERE / "Images"))


def write_tga(path, width, height, rows, bits=24):
    """`rows` top down, each width * 3 bytes of BGR (or * 4 of BGRA for 32 bits)"""
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, width, height, bits, 8 if bits == 32 else 0)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as out:
        out.write(header)
        # Bottom up, as the client reads them
        for row in reversed(rows):
            out.write(row)


def lua(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(round(value, 6)) if isinstance(value, float) else str(value)
    if isinstance(value, str):
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'
    if isinstance(value, (list, tuple)):
        return "{ " + ", ".join(lua(v) for v in value) + " }"
    if isinstance(value, dict):
        return "{ " + ", ".join(f"{k} = {lua(v)}" for k, v in value.items() if v is not None) + " }"
    raise TypeError(value)


def register(entry):
    """Adds a panorama to the list, or replaces the one of the same name, and writes Panos.lua"""
    listing = IMAGES / "panos.json"
    panos = json.loads(listing.read_text()) if listing.exists() else []
    panos = [p for p in panos if p["name"] != entry["name"]] + [entry]
    # The test pictures first, then the captures by number
    panos.sort(key=lambda p: (not p["name"].startswith("test"), p.get("capture", 0), p["name"]))
    IMAGES.mkdir(parents=True, exist_ok=True)
    listing.write_text(json.dumps(panos, indent=1))
    with open(IMAGES / "Panos.lua", "w", newline="\n") as out:
        out.write("-- Made by make_images.py and stitch.py from panos.json: every panorama there is\n")
        out.write("local _, ns = ...\nns.panos = {\n")
        for pano in panos:
            out.write("  " + lua(pano) + ",\n")
        out.write("}\n")
