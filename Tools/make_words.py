#!/usr/bin/env python3
"""Packs a list of English words into Lexicon/English.lua, the way Engine/Lexicon.lua reads it.

    python3 Tools/make_words.py enable1.txt Lexicon/English.lua

The list is ENABLE (Enhanced North American Benchmark Lexicon), which is in the public domain:
one lower case word a line, as found at https://github.com/dolph/dictionary. Words too long for
a board are left out. Only the standard library is used.

Whatever this writes is part of the rules of the games that use it. After running it again on
another list, give those games a new version: Tests/RunTests.lua won't pass until then.
"""
import re
import sys
from pathlib import Path

# The longest word there is room for
LONGEST = 15
SHORTEST = 2

HEADER = """\
--------------------------
--  English
--------------------------
-- The words of ENABLE (Enhanced North American Benchmark Lexicon, public domain) of {shortest} to
-- {longest} letters, {count} of them. Written by Tools/make_words.py, don't edit it by hand.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local pack = private.Lexicon.Pack

"""


def main():
    source, target = Path(sys.argv[1]), Path(sys.argv[2])
    by_length = {}
    for line in source.read_text(encoding="ascii").split():
        if not re.fullmatch("[a-z]+", line):
            raise SystemExit(f"Not a word: {line!r}")
        if SHORTEST <= len(line) <= LONGEST:
            by_length.setdefault(len(line), set()).add(line.upper())

    count = sum(len(words) for words in by_length.values())
    lines = [HEADER.format(shortest=SHORTEST, longest=LONGEST, count=count)]
    for length in sorted(by_length):
        lines.append(f'pack("english", {length}, "{"".join(sorted(by_length[length]))}")\n')
    target.write_text("".join(lines), encoding="ascii")
    print(f"{count} words in {target}")


if __name__ == "__main__":
    main()
