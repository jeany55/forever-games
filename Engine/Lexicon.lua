--------------------------
--  Word lists
--------------------------
-- What counts as a word, for games played with them. A list is filled from data files (Lexicon/)
-- and asked whether it has a word. Words are capital letters A to Z and nothing else.
--
-- There are two ways to fill one. A dictionary is far too many words to keep a table of, so it
-- is packed: all its words of one length written one after the other in alphabetical order, as a
-- single string that is searched by halving. That costs no more memory than the text itself.
-- A short list of names worth knowing something about is kept as a table instead, with how each
-- is properly written, what kind of thing it is and how much it is worth: see
-- Lexicon/Warcraft.lua.
--
-- The lists are part of the rules of any game that uses them. Players whose lists differ would
-- not agree on which moves are legal, so the lists never depend on the language the client runs
-- in, and a game has to count as a new version whenever one of its lists changes: Stamp gives a
-- number to notice that by.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- What is known about a name
--- @class LexiconEntry
--- @field name string As it is properly written, "Kael'thas"
--- @field group string What kind of thing it is
--- @field rank number How much it is worth to the game, 1 unless the data says otherwise

--- @class Lexicon
local Lexicon = {}
private.Lexicon = Lexicon

--- @type table<string, { packed: table<number, string>, named: table<string, LexiconEntry> }>
local lists = {}

--- @param list string
local function listOf(list)
  lists[list] = lists[list] or { packed = {}, named = {} }
  return lists[list]
end

--- Adds all the words of one length to a list
--- @param list string
--- @param length number
--- @param words string The words one after the other with nothing between them, in alphabetical order
function Lexicon.Pack(list, length, words)
  local into = listOf(list)
  assert(#words % length == 0 and not into.packed[length], "Bad words of length " .. length .. " for " .. list)
  into.packed[length] = words
end

--- Adds names to a list. The word a name is found under is its letters: "Kael'thas" is KAELTHAS
--- @param list string
--- @param group string What kind of thing they all are
--- @param names string The names as they are properly written, with blanks between them
--- @param rank number? How much they are worth, 1 if left out
function Lexicon.Names(list, group, names, rank)
  local into = listOf(list)
  for name in names:gmatch("%S+") do
    local word = name:upper():gsub("[^A-Z]", "")
    assert(#word >= 2 and not into.named[word], "Bad or repeated name for " .. list .. ": " .. name)
    into.named[word] = { name = name, group = group, rank = rank or 1 }
  end
end

--- @param list string
--- @param word string
--- @return boolean
function Lexicon.Has(list, word)
  local from = lists[list]
  if not from then
    return false
  end
  if from.named[word] then
    return true
  end
  local length = #word
  local packed = from.packed[length]
  if not packed then
    return false
  end
  local low, high = 1, #packed / length
  while low <= high do
    local middle = math.floor((low + high) / 2)
    local found = packed:sub((middle - 1) * length + 1, middle * length)
    if found == word then
      return true
    elseif found < word then
      low = middle + 1
    else
      high = middle - 1
    end
  end
  return false
end

--- What is known about a word that was added as a name
--- @param list string
--- @param word string
--- @return LexiconEntry?
function Lexicon.Entry(list, word)
  local from = lists[list]
  return from and from.named[word]
end

--- @param list string
--- @return number How many words it has. A name that is also among the packed words counts twice
function Lexicon.Count(list)
  local from, count = lists[list], 0
  for length, packed in pairs(from and from.packed or {}) do
    count = count + #packed / length
  end
  for _ in pairs(from and from.named or {}) do
    count = count + 1
  end
  return count
end

--- A number that is another one whenever the list would rule differently: with a word more or
--- less, or a name worth something else
--- @param list string
--- @return number
function Lexicon.Stamp(list)
  local from = lists[list]
  local stamp = private.Random.Seed(list)
  if not from then
    return stamp
  end
  local lengths, words = {}, {}
  for length in pairs(from.packed) do
    lengths[#lengths + 1] = length
  end
  table.sort(lengths)
  for _, length in ipairs(lengths) do
    stamp = private.Random.Stir(stamp, from.packed[length])
  end
  for word in pairs(from.named) do
    words[#words + 1] = word
  end
  table.sort(words)
  for _, word in ipairs(words) do
    stamp = private.Random.Stir(stamp, word .. from.named[word].rank)
  end
  return stamp
end
