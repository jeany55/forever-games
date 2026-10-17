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

--- Where the words of a length that begin with some letters are in a list. For a game whose
--- computer puts words together a letter at a time: each letter more only narrows down where
--- the words with the letters before it are, so it hands that on to look within. Names aren't
--- asked about, there are few enough of them to try every one, see Lexicon.Named
--- @param list string
--- @param prefix string
--- @param length number How long the words are
--- @param low number? Where to look from, the first of them if left out
--- @param high number? And up to, the last if left out
--- @return number? first Nil if there are none
--- @return number? last
function Lexicon.Span(list, prefix, length, low, high)
  local from = lists[list]
  local packed = from and from.packed[length]
  local size = #prefix
  if not packed or size > length then
    return nil
  end
  low, high = low or 1, high or #packed / length
  --- The beginning of the word at an index, as long as the prefix
  local function beginning(index)
    local start = (index - 1) * length + 1
    return packed:sub(start, start + size - 1)
  end
  -- The words are in order, and so are the beginnings of them: the first that isn't before it
  local bottom, top = low, high + 1
  while bottom < top do
    local middle = math.floor((bottom + top) / 2)
    if beginning(middle) < prefix then
      bottom = middle + 1
    else
      top = middle
    end
  end
  if bottom > high or beginning(bottom) ~= prefix then
    return nil
  end
  local first = bottom
  -- And the first after it that is
  top = high + 1
  while bottom < top do
    local middle = math.floor((bottom + top) / 2)
    if beginning(middle) <= prefix then
      bottom = middle + 1
    else
      top = middle
    end
  end
  return first, bottom - 1
end

--- How many words of a length a list packs, for a game that picks one of them by its place: the
--- word to find in Games/Wordle.lua. Names aren't counted
--- @param list string
--- @param length number
--- @return number
function Lexicon.Size(list, length)
  local from = lists[list]
  local packed = from and from.packed[length]
  return packed and #packed / length or 0
end

--- A word of a length a list packs, by its place in their order, see Lexicon.Size
--- @param list string
--- @param length number
--- @param index number From 1
--- @return string? nil where there is none
function Lexicon.At(list, length, index)
  if index < 1 or index > Lexicon.Size(list, length) or index ~= math.floor(index) then
    return nil
  end
  local packed = lists[list].packed[length]
  return packed:sub((index - 1) * length + 1, index * length)
end

--- Every word of a list that was added as a name, in order
--- @param list string
--- @return string[]
function Lexicon.Named(list)
  local from, words = lists[list], {}
  for word in pairs(from and from.named or {}) do
    words[#words + 1] = word
  end
  table.sort(words)
  return words
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
