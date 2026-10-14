#!/bin/bash
# Packages the addon into .release/ForeverGames-<version>.zip, ready to unzip into Interface/AddOns.
# Run from the repository root.
set -e

VERSION=$(grep '^## Version:' ForeverGames.toc | grep -o '[0-9]*\.[0-9]*\.[0-9]*')
OUT=".release"
ZIP="ForeverGames-${VERSION}.zip"

rm -rf "$OUT"
mkdir -p "$OUT/ForeverGames"
cp -r ForeverGames.toc embeds.xml ./*.lua Engine Games GUI Lexicon Images Fonts Sounds Libs Locales LICENSE "$OUT/ForeverGames/"

(cd "$OUT" && zip -qr "$ZIP" ForeverGames)
rm -rf "$OUT/ForeverGames"
echo "$OUT/$ZIP"
