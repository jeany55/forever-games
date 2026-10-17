#!/bin/bash
# Makes what Freedoom is played with from freedoom1.wad: every map of the first episode into
# ForeverGames_Freedoom_Maps, the addon that is loaded when a game of Freedoom is played, and the
# pictures they are drawn with, the status bar, the sounds (which take ffmpeg) and the icon into
# ForeverGames_Freedoom, the game's own addon. And Run, the addon's own map, made by
# Tools/make_run.py and drawn in Freedoom's pictures.
#   Tools/import_freedoom.sh path/to/freedoom1.wad
# Run from the repository root.
set -e

WAD="$1"
OUT="ForeverGames_Freedoom"
MAPS="ForeverGames_Freedoom_Maps"
ADDON_PATH='Interface\AddOns\ForeverGames_Freedoom\Images'

if [ ! -f "$WAD" ]; then
  echo "Usage: $0 path/to/freedoom1.wad" >&2
  exit 1
fi

rm -rf "$OUT/Images" "$MAPS"/*.lua
for map in 1 2 3 4 5 6 7 8 9; do
  extra=()
  if [ "$map" = 1 ]; then
    extra=(--icon BIGDOOR2 "$OUT/Images/icon.tga" --hud freedoom_hud "$OUT/Hud.lua" --sounds "$OUT/Sounds")
  fi
  python3 -I Tools/import_wad.py "$WAD" "E1M$map" "freedoom_e1m$map" "$OUT/Images" "$MAPS/E1M$map.lua" \
    --global --addon-path "$ADDON_PATH" "${extra[@]}"
done
RUN_WAD=$(mktemp --suffix=.wad)
python3 -I Tools/make_run.py "$RUN_WAD"
python3 -I Tools/import_wad.py "$WAD" RUN freedoom_run "$OUT/Images" "$MAPS/Run.lua" --pwad "$RUN_WAD" --sky SKY2 \
  --global --addon-path "$ADDON_PATH"
rm -f "$RUN_WAD"
