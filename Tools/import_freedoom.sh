#!/bin/bash
# Makes ForeverGames_Freedoom, the addon of Freedoom's maps that Forever Games loads when a game
# of Freedoom is played: every map of the first episode, the pictures they are drawn with, the
# status bar and the sounds (which take ffmpeg), from freedoom1.wad. Its icon goes into Forever Games itself, to be shown before.
# And Run, the addon's own map, made by Tools/make_run.py and drawn in Freedoom's pictures.
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
    extra=(--icon BIGDOOR2 Images/Icons/freedoom.tga --hud freedoom_hud "$OUT/Hud.lua" --sounds "$OUT/Sounds")
  fi
  python3 -I Tools/import_wad.py "$WAD" "E1M$map" "freedoom_e1m$map" "$OUT/Images" "$OUT/Maps/E1M$map.lua" \
    --global --addon-path "$ADDON_PATH" "${extra[@]}"
done
RUN_WAD=$(mktemp --suffix=.wad)
python3 -I Tools/make_run.py "$RUN_WAD"
python3 -I Tools/import_wad.py "$WAD" RUN freedoom_run "$OUT/Images" "$OUT/Maps/Run.lua" --pwad "$RUN_WAD" --sky SKY2 \
  --global --addon-path "$ADDON_PATH"
rm -f "$RUN_WAD"
