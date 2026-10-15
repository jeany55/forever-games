#!/bin/bash
# Packages the addon and Freedoom's maps into .release/ForeverGames-<version>.zip, ready to unzip
# into Interface/AddOns.
# Run from the repository root.
set -e

VERSION=$(grep '^## Version:' ForeverGames.toc | grep -o '[0-9]*\.[0-9]*\.[0-9]*')
OUT=".release"
ZIP="ForeverGames-${VERSION}.zip"

rm -rf "$OUT"
mkdir -p "$OUT/ForeverGames"
cp -r ForeverGames.toc embeds.xml ./*.lua Engine Games GUI Lexicon Images Sounds Libs Locales LICENSE "$OUT/ForeverGames/"
# Freedoom's maps go along as an addon of their own, loaded when a game of it is played
cp -r ForeverGames_Freedoom "$OUT/"

(cd "$OUT" && zip -qr "$ZIP" ForeverGames ForeverGames_Freedoom)
rm -rf "$OUT/ForeverGames" "$OUT/ForeverGames_Freedoom"
echo "$OUT/$ZIP"
