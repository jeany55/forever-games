#!/bin/bash
# Packages Geo Bench for somebody else to take places with: the addon, without anybody's
# panoramas (only the smallest test picture, for /geobench probe), and how to go about it.
# Writes .release/GeoBench-capture.zip at the root of the repository.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT/.release/geobench"
rm -rf "$OUT"
mkdir -p "$OUT/GeoBench/Images" "$OUT/GeoBench/Data"
cp "$HERE/GeoBench.toc" "$HERE"/*.lua "$OUT/GeoBench/"
cp "$HERE/Data/Minimaps.lua" "$OUT/GeoBench/Data/"
cp "$HERE/Images/test2048_1.tga" "$OUT/GeoBench/Images/"
# Only the test picture is listed
python3 - "$HERE" "$OUT/GeoBench/Images/Panos.lua" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import panos
entries = [p for p in json.loads((panos.IMAGES / "panos.json").read_text()) if p["name"] == "test2048"]
with open(sys.argv[2], "w", newline="\n") as out:
    out.write("local _, ns = ...\nns.panos = {\n" + "".join("  " + panos.lua(p) + ",\n" for p in entries) + "}\n")
PY
cat > "$OUT/HOW TO TAKE PLACES.txt" <<'TXT'
Taking places for Where in Azeroth
==================================

1. Put the GeoBench folder in World of Warcraft\_classic_beta_\Interface\AddOns and restart
   the game. Turn on Geo Bench in the AddOns list if it isn't.

2. Go somewhere worth guessing, outdoors (not in a dungeon or instance), and stand still.
   Type /geobench capture. The interface hides and you go to first person: look level, with the
   far horizon along the yellow line, and press Enter. Don't move until it says
   "Captured #n" (about 15 seconds). Combat stops it. Everything is put back afterwards.

3. Type /reload every few places, and before changing character: that is when what you took
   is written down. Any character, any realm, as long as it's the same Battle.net account.

4. When you're done, send two things:
   - World of Warcraft\_classic_beta_\WTF\Account\<your account>\SavedVariables\GeoBench.lua
   - the WoWScrnShot_*.jpg files from World of Warcraft\_classic_beta_\Screenshots taken while
     capturing (12 a place; sending the whole folder is fine too)
   Zipped up together, any way you like.

Good places have something to go on, even if it's only the trees, the ground or the light.
Hard ones are welcome. Avoid deep indoors, and places where lots of people are walking about.
TXT
cd "$ROOT/.release" && rm -f GeoBench-capture.zip && (cd geobench && zip -qr ../GeoBench-capture.zip .) && rm -rf geobench
echo "$ROOT/.release/GeoBench-capture.zip"
