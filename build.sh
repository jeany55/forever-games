#!/bin/bash
# Packages the addon and the addons that come with it (every ForeverGames_* folder: Freedoom and its
# maps, the places of Where in Azeroth) into .release/ForeverGames-<version>.zip, ready to unzip
# into Interface/AddOns. The same zip is for the Forever client and retail: each addon has a toc
# for each (retail picks the *_Standard.toc).
# Run from the repository root.
set -e

VERSION=$(grep '^## Version:' ForeverGames.toc | grep -o '[0-9]*\.[0-9]*\.[0-9]*')
OUT=".release"
ZIP="ForeverGames-${VERSION}.zip"

rm -rf "$OUT"
mkdir -p "$OUT/ForeverGames"
cp -r ForeverGames.toc ForeverGames_Standard.toc embeds.xml ./*.lua Engine Games GUI Lexicon Images Sounds Libs Locales LICENSE "$OUT/ForeverGames/"
# The addons that go along with it, each a folder of its own beside it
COMPANIONS=$(ls -d ForeverGames_*/ | tr -d /)
cp -r $COMPANIONS "$OUT/"

(cd "$OUT" && zip -qr "$ZIP" ForeverGames $COMPANIONS)
(cd "$OUT" && rm -rf ForeverGames $COMPANIONS)
echo "$OUT/$ZIP"
