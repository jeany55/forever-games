#!/bin/bash
# Makes ForeverGames_Freedoom, the addon of Freedoom's maps that Forever Games loads when a game
# of Freedoom is played: every map of the first episode, the pictures they are drawn with and the
# status bar, from freedoom1.wad. Its icon goes into Forever Games itself, to be shown before.
#   Tools/import_freedoom.sh path/to/freedoom1.wad
# Run from the repository root.
set -e

WAD="$1"
OUT="ForeverGames_Freedoom"
ADDON_PATH='Interface\AddOns\ForeverGames_Freedoom\Images'

if [ ! -f "$WAD" ]; then
  echo "Usage: $0 path/to/freedoom1.wad" >&2
  exit 1
fi

rm -rf "$OUT/Images" "$OUT/Maps"
for map in 1 2 3 4 5 6 7 8 9; do
  extra=()
  if [ "$map" = 1 ]; then
    extra=(--icon BIGDOOR2 Images/Icons/freedoom.tga --hud freedoom_hud "$OUT/Hud.lua")
  fi
  python3 -I Tools/import_wad.py "$WAD" "E1M$map" "freedoom_e1m$map" "$OUT/Images" "$OUT/Maps/E1M$map.lua" \
    --global --addon-path "$ADDON_PATH" "${extra[@]}"
done
