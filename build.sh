#!/bin/bash
# Packages Forever Games and the two games that go along it into .release/, one zip each, ready to
# unzip into Interface/AddOns:
#
#   ForeverGames-<version>.zip                  the addon: ForeverGames
#   ForeverGames_Where-<version>.zip            Where in Azeroth: ForeverGames_Where and its packs of
#                                               places, ForeverGames_Where_Places and any other ForeverGames_Where_*
#   ForeverGames_Freedoom-<version>.zip         Freedoom: ForeverGames_Freedoom, ForeverGames_Freedoom_Maps
#
# Each is a project of its own on CurseForge, as Where's places and Freedoom's maps are big. The
# version in a name is the one in that addon's own toc. They're for WoW Forever only.
# Run from the repository root.
set -e

OUT=".release"

version() {
  grep '^## Version:' "$1" | grep -o '[0-9]*\.[0-9]*\.[0-9]*'
}

# zip <name> <folder>...: zips the folders, already copied into $OUT, as <name>.zip
pack() {
  local name=$1
  shift
  (cd "$OUT" && zip -qr "$name.zip" "$@" && rm -rf "$@")
  echo "$OUT/$name.zip"
}

rm -rf "$OUT"
mkdir -p "$OUT/ForeverGames"
cp -r ForeverGames.toc embeds.xml ./*.lua Engine Games GUI Lexicon Images Sounds Libs Locales LICENSE "$OUT/ForeverGames/"
pack "ForeverGames-$(version ForeverGames.toc)" ForeverGames

# Where in Azeroth with its places, and any other pack of places (ForeverGames_Where_<Name>)
WHERE=$(ls -d ForeverGames_Where ForeverGames_Where_*/ | tr -d /)
cp -r $WHERE "$OUT/"
pack "ForeverGames_Where-$(version ForeverGames_Where/ForeverGames_Where.toc)" $WHERE

cp -r ForeverGames_Freedoom ForeverGames_Freedoom_Maps "$OUT/"
pack "ForeverGames_Freedoom-$(version ForeverGames_Freedoom/ForeverGames_Freedoom.toc)" ForeverGames_Freedoom ForeverGames_Freedoom_Maps

# Anything else called ForeverGames_* would be left out of every zip
for folder in ForeverGames_*/; do
  case "${folder%/}" in
    ForeverGames_Where | ForeverGames_Where_* | ForeverGames_Freedoom | ForeverGames_Freedoom_Maps) ;;
    *) echo "build.sh: ${folder%/} isn't in any zip" >&2 && exit 1 ;;
  esac
done
