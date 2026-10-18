--------------------------
--  Bones
--------------------------
-- Dominoes, for the rules of any game played with them: Block and Draw, All Fives, Mexican
-- Train. A domino (a bone, a tile) is two characters, the pips on each of its ends with the
-- fewer first: "35" for the three-five, "66" for the double six. A set goes up to a double of
-- some number, six for the usual set of twenty-eight, nine or twelve for the bigger ones, so a
-- number of pips is written as one character of Bones.PIPS: 0 to 9, then A, B and C for ten,
-- eleven and twelve. That is how games send them and how GUI/Dominoes.lua draws them. A tile
-- somebody isn't shown is Bones.HIDDEN, which they see the back of.
--
-- A set comes in the same order every time, from the double blank up: a game's match shuffles it
-- with its own dice (Engine/Random.lua) and every client gets the same deal.
--
-- The tiles played lie in a line on the table, the line of play, and each new one goes on one of
-- its two open ends with the end that matches it. A line is the tile it began with (`first`, its
-- ends as they lie, left then right) and two arms going out from it, each the tiles laid on that
-- side in the order they were: a tile in an arm is written the way it lies, the end it was laid
-- against first, so "53" on the left arm is a five-three laid against a five with its three left
-- open. The pips on an end are its number: an open end of five wants a tile with a five on it.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class Bones
local Bones = {}
private.Bones = Bones

-- The number of pips on an end, by where it is in this string, from nought
Bones.PIPS = "0123456789ABC"
Bones.HIDDEN = "?"
-- The usual set, double six
Bones.SIX = 6
Bones.LEFT, Bones.RIGHT = "l", "r"

--- A tile with these ends, the fewer pips first however they are given
--- @param a number
--- @param b number
--- @return string
function Bones.Tile(a, b)
  if b < a then
    a, b = b, a
  end
  return Bones.PIPS:sub(a + 1, a + 1) .. Bones.PIPS:sub(b + 1, b + 1)
end

--- The pips on an end written as a character
--- @param char string
--- @return number? nil for something that isn't one
local function pipsOf(char)
  local at = Bones.PIPS:find(char, 1, true)
  return at and at - 1 or nil
end

--- The pips on each end, in the order the tile is written
--- @param tile string
--- @return number, number
function Bones.Ends(tile)
  return pipsOf(tile:sub(1, 1)) or 0, pipsOf(tile:sub(2, 2)) or 0
end

--- Whether some text is a tile of a set up to a double of so many, written the usual way round
--- @param text string?
--- @param top number? Six if left out
--- @return boolean
function Bones.IsTile(text, top)
  if type(text) ~= "string" or #text ~= 2 then
    return false
  end
  local a, b = pipsOf(text:sub(1, 1)), pipsOf(text:sub(2, 2))
  return a ~= nil and b ~= nil and a <= b and b <= (top or Bones.SIX)
end

--- @param tile string
--- @return boolean
function Bones.IsDouble(tile)
  return tile:sub(1, 1) == tile:sub(2, 2)
end

--- How many pips there are on a tile, both ends together
--- @param tile string
--- @return number
function Bones.Pips(tile)
  local a, b = Bones.Ends(tile)
  return a + b
end

--- How many pips there are on all of some tiles: what is left in a hand counts against it
--- @param tiles string[]
--- @return number
function Bones.Count(tiles)
  local total = 0
  for _, tile in ipairs(tiles) do
    total = total + Bones.Pips(tile)
  end
  return total
end

--- Whether a tile has an end of so many pips
--- @param tile string
--- @param pips number
--- @return boolean
function Bones.Has(tile, pips)
  local a, b = Bones.Ends(tile)
  return a == pips or b == pips
end

--- The pips on the other end of a tile from one of so many
--- @param tile string
--- @param pips number One of its ends
--- @return number
function Bones.Other(tile, pips)
  local a, b = Bones.Ends(tile)
  return a == pips and b or a
end

--- A whole set, in the same order every time: from the double blank, each tile with the fewer
--- pips first
--- @param top number? The biggest double, six if left out
--- @return string[]
function Bones.Set(top)
  local set = {}
  for a = 0, top or Bones.SIX do
    for b = a, top or Bones.SIX do
      set[#set + 1] = Bones.Tile(a, b)
    end
  end
  return set
end

--- A whole set face down, shuffled with the match's dice: the boneyard tiles are drawn from
--- @param random Random
--- @param top number?
--- @return string[]
function Bones.Shuffled(random, top)
  return random:Shuffle(Bones.Set(top))
end

--- Deals tiles from the end of a pile, one to each hand at a time and round again
--- @param pile string[] What is dealt is taken off it
--- @param hands string[][] Each is added to
--- @param each number Tiles to each hand
function Bones.Deal(pile, hands, each)
  for _ = 1, each do
    for _, hand in ipairs(hands) do
      hand[#hand + 1] = table.remove(pile)
    end
  end
end

--- Where a tile is in a hand or a pile
--- @param tiles string[]
--- @param tile string
--- @return number? nil if it isn't there
function Bones.Find(tiles, tile)
  for index, held in ipairs(tiles) do
    if held == tile then
      return index
    end
  end
  return nil
end

--- So many tiles seen from the back, for what a player isn't shown of a hand or the boneyard
--- @param count number
--- @return string[]
function Bones.Backs(count)
  local backs = {}
  for index = 1, count do
    backs[index] = Bones.HIDDEN
  end
  return backs
end

--- The tiles of a set that aren't among some, in the set's own order: what could be in the hands
--- and the boneyard a player can't see
--- @param top number? The set's biggest double, six if left out
--- @param ... string[] The tiles they can see. Tiles in a line are written as they lie: either way round will do
--- @return string[]
function Bones.Unseen(top, ...)
  local known = {}
  for index = 1, select("#", ...) do
    for _, tile in ipairs((select(index, ...))) do
      if tile ~= Bones.HIDDEN then
        known[Bones.Tile(Bones.Ends(tile))] = true
      end
    end
  end
  local unseen = {}
  for _, tile in ipairs(Bones.Set(top)) do
    if not known[tile] then
      unseen[#unseen + 1] = tile
    end
  end
  return unseen
end

--- Puts tiles in the order a player would hold them: by the bigger end, then the smaller,
--- the most pips first
--- @param tiles string[] Sorted in place
--- @return string[] tiles
function Bones.Sort(tiles)
  table.sort(tiles, function(x, y)
    local xa, xb = Bones.Ends(x)
    local ya, yb = Bones.Ends(y)
    if xb ~= yb then
      return xb > yb
    end
    return xa > ya
  end)
  return tiles
end

--- Who holds the tile that goes down first in a game where that is the biggest double: the
--- biggest double anybody has or, where nobody has one, the tile with the most pips
--- @param hands string[][]
--- @return number seat, string tile Nil, nil for hands with nothing in them
function Bones.Opener(hands)
  local seat, best, worth = nil, nil, -1
  for owner, hand in ipairs(hands) do
    for _, tile in ipairs(hand) do
      -- Any double beats any other tile, and a bigger double a smaller one
      local value = Bones.IsDouble(tile) and 100 + Bones.Pips(tile) or Bones.Pips(tile)
      -- Between tiles of as many pips, the one with the bigger end
      value = value * 16 + select(2, Bones.Ends(tile))
      if value > worth then
        seat, best, worth = owner, tile, value
      end
    end
  end
  return seat, best
end

-----------------------------
-- The line of play
-----------------------------

--- @class BonesLine
--- @field first string? The tile it began with, written as it lies: its left end, then its right. Nil for a line nothing has been laid in
--- @field left string[] Laid on its left, going out from the first: each as it lies, the end laid against first
--- @field right string[] The same on its right

--- A line with nothing in it yet
--- @return BonesLine
function Bones.NewLine()
  return { left = {}, right = {} }
end

--- A copy of a line, to lay tiles in without changing the one it was copied from
--- @param line BonesLine
--- @return BonesLine
function Bones.CopyLine(line)
  return { first = line.first, left = { unpack(line.left) }, right = { unpack(line.right) } }
end

--- The open ends of a line
--- @param line BonesLine
--- @return number? left Nil for a line with nothing in it
--- @return number? right
function Bones.LineEnds(line)
  if not line.first then
    return nil, nil
  end
  local left, right = Bones.Ends(line.first)
  if #line.left > 0 then
    left = select(2, Bones.Ends(line.left[#line.left]))
  end
  if #line.right > 0 then
    right = select(2, Bones.Ends(line.right[#line.right]))
  end
  return left, right
end

--- Which ends of a line a tile could be laid on. Anything goes on a line with nothing in it
--- @param line BonesLine
--- @param tile string
--- @return boolean left, boolean right
function Bones.Fits(line, tile)
  local left, right = Bones.LineEnds(line)
  if not left then
    return true, true
  end
  return Bones.Has(tile, left), Bones.Has(tile, right)
end

--- Whether any of some tiles could be laid on a line
--- @param line BonesLine
--- @param tiles string[]
--- @return boolean
function Bones.AnyFits(line, tiles)
  for _, tile in ipairs(tiles) do
    local left, right = Bones.Fits(line, tile)
    if left or right then
      return true
    end
  end
  return false
end

--- Lays a tile on an end of a line, or down to begin it
--- @param line BonesLine Changed
--- @param tile string One that fits there
--- @param side string? Bones.LEFT or Bones.RIGHT, either for a line with nothing in it
--- @return string laid The tile as it lies, the end laid against first
function Bones.Lay(line, tile, side)
  if not line.first then
    line.first = tile
    return tile
  end
  local left, right = Bones.LineEnds(line)
  local against = side == Bones.LEFT and left or right
  -- Not checked: a tile that doesn't fit is the game's to refuse beforehand
  local laid = Bones.Ends(tile) == against and tile or tile:sub(2, 2) .. tile:sub(1, 1)
  local arm = side == Bones.LEFT and line.left or line.right
  arm[#arm + 1] = laid
  return laid
end

--- Every tile in a line, as they lie, from the left end to the right
--- @param line BonesLine
--- @return string[]
function Bones.LineTiles(line)
  local tiles = {}
  for index = #line.left, 1, -1 do
    tiles[#tiles + 1] = line.left[index]
  end
  if line.first then
    tiles[#tiles + 1] = line.first
  end
  for _, tile in ipairs(line.right) do
    tiles[#tiles + 1] = tile
  end
  return tiles
end

--- How many tiles there are in a line
--- @param line BonesLine
--- @return number
function Bones.LineLength(line)
  return (line.first and 1 or 0) + #line.left + #line.right
end
