--------------------------
--  Chance
--------------------------
-- Dice and shuffled decks, for games that have them. Every client replays the same log and has
-- to come out with the same rolls, so nothing here is random at all: a match's chance is a
-- number that starts out from the match id and is stirred by every move made, and whatever a
-- game rolls or shuffles while it applies a move follows from that number alone. The client's
-- own math.random is never used, two clients wouldn't agree on what it says.
--
-- Because every move stirs it, nobody can tell what the dice will do further ahead than their
-- own next move. For that one move they could, by working it out instead of playing: chance in
-- these games is fair between friends, the way the rest of the engine is (see Engine/Session.lua).
--
-- The numbers come from a Lehmer generator (the "minimal standard" one), which only ever
-- multiplies numbers small enough to stay exact in the doubles Lua counts with.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class Random
--- @field value number
local Random = {}
Random.__index = Random
private.Random = Random

local MODULUS = 2147483647
local MULTIPLIER = 48271
-- Seeds that are close together give first numbers that are close together, so a few are
-- thrown away before any are used
local WARM_UP = 4

--- @param value number
--- @return number
local function advance(value)
  return math.fmod(value * MULTIPLIER, MODULUS)
end

--- Works a text into a seed, giving another seed. The same two always give the same one
--- @param seed number Whole, from 0 up to but not including the modulus
--- @param text string
--- @return number
function Random.Stir(seed, text)
  local value = seed
  for index = 1, #text do
    value = math.fmod(value * MULTIPLIER + text:byte(index) + 1, MODULUS)
  end
  -- The length too, so that stirring in "ab" isn't the same as "a" and then "b"
  return math.fmod(value * MULTIPLIER + #text + 1, MODULUS)
end

--- A seed to start from, out of nothing but a text
--- @param text string
--- @return number
function Random.Seed(text)
  return Random.Stir(0, text)
end

--- @param seed number
--- @return Random
function Random.New(seed)
  -- The generator can't start from nothing, it would stay there
  local self = setmetatable({ value = seed % (MODULUS - 1) + 1 }, Random)
  for _ = 1, WARM_UP do
    self.value = advance(self.value)
  end
  return self
end

--- A whole number from 1 to `max`, each as likely as the other
--- @param max number
--- @return number
function Random:Roll(max)
  self.value = advance(self.value)
  return math.floor((self.value - 1) / (MODULUS - 1) * max) + 1
end

--- Puts a list in a random order, in place
--- @generic T
--- @param list T[]
--- @return T[] list
function Random:Shuffle(list)
  for index = #list, 2, -1 do
    local other = self:Roll(index)
    list[index], list[other] = list[other], list[index]
  end
  return list
end
