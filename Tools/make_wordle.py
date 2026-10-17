#!/usr/bin/env python3
"""Picks the words Wordle (Games/Wordle.lua) hides, and draws its icon.

    python3 Tools/make_wordle.py words scowl/final Lexicon/Wordle.lua
    python3 Tools/make_wordle.py icon .

Any word of ENABLE can be guessed, the list Lexicon/English.lua already packs, and the tool reads
it from there. The word to find has to be one people know, which ENABLE doesn't tell, so those
come from SCOWL (http://wordlist.aspell.net, the folder `final` of its download), whose lists are
sorted by how common their words are, and only the words that are in both are kept. Of those a
word is left out
- if it is only another word with an S on the end (CATS, WISHES, CITIES) or an ED (BAKED,
  STOPPED, TRIED): a guess comes out the same as for the word it was made from, less the end,
- if it is a word with ING on the end made from a common one (GAZING, TOYING, but not STRING),
- if it is more or most of something (LAMER, HEFTIEST): an ER word whose EST is a word too,
- if it is one of a few that nobody wants to be handed as the day's word (BLOCKED below).

The Warcraft words are the names of Lexicon/Warcraft.lua of four to seven letters, less what
isn't a name to find: more than one of something (KODOS beside KODO) and what is written in
capitals in the middle (NPCS, WOTLK).

Whatever `words` writes is part of the rules of the game. After running it again, give Wordle a
new version: Tests/RunTests.lua won't pass until then. Only the standard library is used. For
`icon`, pass a second folder to also get a PNG copy there.
"""
import re
import struct
import sys
import zlib
from pathlib import Path

SHORTEST, LONGEST = 4, 7
# SCOWL's sizes the words to find are taken from, the most common first. The longer words are
# fewer at every size, so they reach a little further down
SIZES = {4: (10, 20, 35), 5: (10, 20, 35), 6: (10, 20, 35), 7: (10, 20, 35, 40)}
# Words that are common enough but no fun to be handed
BLOCKED = {
    "bitch", "bitchy", "boner", "booby", "boobs", "butt", "butts", "cock", "cocks", "crap", "crappy",
    "damn", "dick", "dicks", "dildo", "dyke", "fart", "farts", "fuck", "fucked", "fucker", "gook",
    "homo", "horny", "jizz", "kike", "nazi", "nazis", "negro", "nigga", "penis", "piss", "pissed",
    "porn", "porno", "pussy", "rape", "raped", "rapist", "semen", "sexy", "shit", "shitty", "slut",
    "sluts", "spic", "tits", "titty", "turd", "twat", "vagina", "whore", "wank", "wanker", "suicide",
    "murder", "incest", "pedophile", "lynch", "anal", "anus", "bondage", "bosom", "bowel", "breast",
    "crotch", "enema", "erotic", "feces", "fondle", "grope", "harlot", "kinky", "lesbian", "lewd",
    "lust", "midget", "molest", "nipple", "nude", "obscene", "orgy", "phallic", "queer", "raunchy",
    "rectum", "retard", "sadist", "sexual", "smut", "sperm", "spunk", "teat", "thong", "urine",
    "cripple", "junkie", "heroin", "racist", "gypsy", "spastic", "testes", "pubic", "scrotum",
}
# Words ending in ING that are things in their own right, kept however common what they were made
# from is
THINGS = {
    "morning", "evening", "ceiling", "pudding", "wedding", "building", "feeling", "meaning",
    "painting", "clothing", "earring", "ending", "outing", "setting", "sibling", "railing",
    "lining", "filling", "stuffing", "frosting", "icing", "awning", "herring", "farthing",
}

HEADER = """\
--------------------------
--  Wordle words
--------------------------
-- The words Games/Wordle.lua hides: everyday English words of {shortest} to {longest} letters,
-- {everyday} of them, and the names of Lexicon/Warcraft.lua that make words to find, {warcraft}
-- of them. Written by Tools/make_wordle.py, don't edit it by hand. What a guess may be is the
-- English list (Lexicon/English.lua), and the Warcraft one too in a game of Warcraft words.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local pack = private.Lexicon.Pack

"""


def enable(english):
    """Every word of the English list, read back out of how Lexicon/English.lua packs it."""
    words = set()
    for length, packed in re.findall(r'pack\("english", (\d+), "([A-Z]*)"\)', english.read_text(encoding="ascii")):
        length = int(length)
        words |= {packed[at : at + length].lower() for at in range(0, len(packed), length)}
    return words


def scowl(final, sizes):
    words = set()
    for kind in ("english-words", "american-words"):
        for size in sizes:
            source = final / f"{kind}.{size}"
            if source.exists():
                words |= {word for word in source.read_text(encoding="latin-1").split() if re.fullmatch("[a-z]+", word)}
    return words


def made_from(word, words, common):
    """Whether a word is only another with an S, an ED or an ING on the end, or more or most of
    something."""
    if word.endswith("s") and not word.endswith("ss"):
        if word[:-1] in words or (word.endswith("es") and word[:-2] in words):
            return True
        if word.endswith("ies") and word[:-3] + "y" in words:
            return True
    if word.endswith("ed"):
        stem = word[:-2]
        if stem in words or word[:-1] in words:
            return True
        if len(stem) > 2 and stem[-1] == stem[-2] and stem[:-1] in words:
            return True
        if word.endswith("ied") and word[:-3] + "y" in words:
            return True
    if word.endswith("ing") and word not in THINGS:
        stem = word[:-3]
        if len(stem) < 3:
            return False
        if stem in common or stem + "e" in common or (len(stem) > 2 and stem[-1] == stem[-2] and stem[:-1] in common):
            return True
    if word.endswith("er") and word[:-2] + "est" in words:
        return True
    if word.endswith("est") and word[:-3] + "er" in words:
        return True
    return False


def warcraft_names(source):
    """The names of Lexicon/Warcraft.lua, as they are written."""
    names = []
    for block in re.findall(r"\[\[(.*?)\]\]", source.read_text(encoding="utf-8"), re.S):
        names += block.split()
    return names


def letters(name):
    return re.sub("[^A-Z]", "", name.upper())


def warcraft_words(names):
    """The names that make a word to find, by their letters."""
    known = {letters(name) for name in names}
    found = set()
    for name in names:
        word = letters(name)
        if not SHORTEST <= len(word) <= LONGEST:
            continue
        # Capitals in the middle of a run of letters: an abbreviation, or more than one of them
        if re.search("[a-z][A-Z]", name) or re.fullmatch("[A-Z]+", name):
            continue
        if word.endswith("S") and word[:-1] in known:
            continue
        found.add(word)
    return found


def make_words(final, target):
    root = Path(__file__).resolve().parent.parent
    allowed = enable(root / "Lexicon" / "English.lua")
    # What a word ending in ING has to be made from to be left out
    stems = scowl(final, (10, 20, 35))
    everyday = {}
    for length in range(SHORTEST, LONGEST + 1):
        common = scowl(final, SIZES[length])
        everyday[length] = sorted(
            word
            for word in common
            if len(word) == length and word in allowed and word not in BLOCKED and not made_from(word, allowed, stems)
        )
    warcraft = {}
    for word in warcraft_words(warcraft_names(root / "Lexicon" / "Warcraft.lua")):
        warcraft.setdefault(len(word), []).append(word)

    out = [
        HEADER.format(
            shortest=SHORTEST,
            longest=LONGEST,
            everyday=sum(len(words) for words in everyday.values()),
            warcraft=sum(len(words) for words in warcraft.values()),
        )
    ]
    for length in range(SHORTEST, LONGEST + 1):
        out.append(f'pack("wordle", {length}, "{"".join(everyday[length]).upper()}")\n')
    out.append("\n")
    for length in range(SHORTEST, LONGEST + 1):
        out.append(f'pack("wordlewarcraft", {length}, "{"".join(sorted(warcraft.get(length, [])))}")\n')
    Path(target).write_text("".join(out), encoding="ascii")
    for length in range(SHORTEST, LONGEST + 1):
        print(f"{length} letters: {len(everyday[length])} everyday words, {len(warcraft.get(length, []))} Warcraft ones")


# ---------------------------------------------------------------- icon

ICON = 64
BACKGROUND = (18, 19, 24)
# The same as in Games/Wordle.lua: a letter that isn't in the word, one that is somewhere else,
# and one in the right place
ABSENT = (58, 58, 64)
PRESENT = (201, 160, 34)
CORRECT = (83, 141, 78)
# Four guesses, the last of them right
ROWS = (
    (ABSENT, PRESENT, ABSENT, ABSENT, ABSENT),
    (ABSENT, ABSENT, CORRECT, PRESENT, ABSENT),
    (PRESENT, ABSENT, CORRECT, ABSENT, CORRECT),
    (CORRECT, CORRECT, CORRECT, CORRECT, CORRECT),
)
TILE, GAP, CORNER = 10, 2, 2
SAMPLES = 4


def inside(px, py, left, top, side, corner):
    """Whether a point is on a square with round corners."""
    x = min(max(px, left + corner), left + side - corner)
    y = min(max(py, top + corner), top + side - corner)
    return (px - x) ** 2 + (py - y) ** 2 <= corner**2 and left <= px <= left + side and top <= py <= top + side


def make_icon(target, preview=None):
    width = len(ROWS[0]) * TILE + (len(ROWS[0]) - 1) * GAP
    height = len(ROWS) * TILE + (len(ROWS) - 1) * GAP
    left0, top0 = (ICON - width) / 2, (ICON - height) / 2
    rows = []
    for y in range(ICON):
        row = []
        for x in range(ICON):
            colour, cover = BACKGROUND, 0
            for row_index, guess in enumerate(ROWS):
                for column, tint in enumerate(guess):
                    left, top = left0 + column * (TILE + GAP), top0 + row_index * (TILE + GAP)
                    hits = sum(
                        inside(x + (sx + 0.5) / SAMPLES, y + (sy + 0.5) / SAMPLES, left, top, TILE, CORNER)
                        for sx in range(SAMPLES)
                        for sy in range(SAMPLES)
                    )
                    if hits:
                        colour, cover = tint, hits / SAMPLES**2
            mixed = tuple(round(c * cover + b * (1 - cover)) for c, b in zip(colour, BACKGROUND))
            row.append(mixed + (255,))
        rows.append(row)
    path = Path(target) / "Images" / "Icons" / "wordle.tga"
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, ICON, ICON, 32, 8)
    path.write_bytes(header + b"".join(bytes((b, g, r, a)) for row in reversed(rows) for (r, g, b, a) in row))
    if preview:

        def chunk(kind, body):
            return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

        raw = b"".join(b"\x00" + b"".join(bytes(pixel) for pixel in row) for row in rows)
        png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", ICON, ICON, 8, 6, 0, 0, 0))
        png += chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
        (Path(preview) / "wordle.png").write_bytes(png)
    print("wrote the icon")


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "words":
        make_words(Path(sys.argv[2]), sys.argv[3])
    elif len(sys.argv) >= 3 and sys.argv[1] == "icon":
        make_icon(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
    else:
        raise SystemExit(__doc__)
