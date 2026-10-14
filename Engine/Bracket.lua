--------------------------
--  Bracket
--------------------------
-- A tourney of duels, for any game played two at a time by however many turn up: everyone is
-- drawn into pairs, every duel of a round is played at once, and the winners meet in the next
-- round until one is left. What a duel is and how it is won is the game's, this only says who
-- meets whom.
--
-- When the players don't halve all the way down to one, some of them go through the first
-- round without playing, as many as it takes. Nobody goes through after that, unless somebody
-- left and their opponent has nobody to meet.
--
-- A round is sent as member numbers with a "." between duels, "3-5.7.2-9": of a pair the first
-- goes first, and one on their own goes through without playing.
--
-- Like the rooms, nothing in here touches the WoW API.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class Bracket
local Bracket = {}
private.Bracket = Bracket

--- @class BracketDuel
--- @field a number Goes first
--- @field b number? Nobody: `a` goes through without playing
--- @field winner number? 0 if the duel was decided with nobody going through

--- The first round
--- @param players number[] In the order they are seeded, shuffled for a draw
--- @return BracketDuel[]
function Bracket.Draw(players)
  local size = 1
  while size < #players do
    size = size * 2
  end
  local duels = {}
  for index = 1, size - #players do
    duels[#duels + 1] = { a = players[index], winner = players[index] }
  end
  for index = size - #players + 1, #players, 2 do
    duels[#duels + 1] = { a = players[index], b = players[index + 1] }
  end
  return duels
end

--- The round after this one, in the order of the bracket so that it stays one
--- @param duels BracketDuel[] All decided
--- @param random fun(max: number): number Who goes first in a duel
--- @param present (fun(n: number): boolean)? Whether a winner is still there to play on
--- @return BracketDuel[]? next Nil once the tourney is over
--- @return number? champion Once it is over: who won it, nil if nobody did
function Bracket.Next(duels, random, present)
  local winners = {}
  for _, duel in ipairs(duels) do
    local winner = duel.winner
    if winner and winner ~= 0 and (not present or present(winner)) then
      winners[#winners + 1] = winner
    end
  end
  if #winners <= 1 then
    return nil, winners[1]
  end
  local nextDuels = {}
  for index = 1, #winners, 2 do
    local a, b = winners[index], winners[index + 1]
    if b and random(2) == 2 then
      a, b = b, a
    end
    nextDuels[#nextDuels + 1] = { a = a, b = b, winner = not b and a or nil }
  end
  return nextDuels
end

--- @param duels BracketDuel[]
--- @return string
function Bracket.Encode(duels)
  local entries = {}
  for _, duel in ipairs(duels) do
    entries[#entries + 1] = duel.b and (duel.a .. "-" .. duel.b) or tostring(duel.a)
  end
  return table.concat(entries, ".")
end

--- @param text string?
--- @return BracketDuel[]? Nil if it isn't a round
function Bracket.Decode(text)
  local duels = {}
  for entry in (text or ""):gmatch("[^.]+") do
    local a, b = entry:match("^(%d+)%-(%d+)$")
    a = tonumber(a or entry:match("^(%d+)$"))
    if not a then
      return nil
    end
    b = tonumber(b)
    duels[#duels + 1] = { a = a, b = b, winner = not b and a or nil }
  end
  return #duels > 0 and duels or nil
end

--- @param duel BracketDuel
--- @param n number One of the two
--- @return number? The other
function Bracket.OtherOf(duel, n)
  if n == duel.a then
    return duel.b
  end
  return duel.a
end

--- Who meets whom, by member
--- @param duels BracketDuel[]
--- @return table<number, BracketDuel>
function Bracket.ByPlayer(duels)
  local of = {}
  for _, duel in ipairs(duels) do
    of[duel.a] = duel
    if duel.b then
      of[duel.b] = duel
    end
  end
  return of
end

--- How many are still in the tourney
--- @param duels BracketDuel[]
--- @return number
function Bracket.Left(duels)
  local count = 0
  for _, duel in ipairs(duels) do
    if duel.winner then
      count = count + (duel.winner ~= 0 and 1 or 0)
    else
      count = count + (duel.b and 2 or 1)
    end
  end
  return count
end

--- Whether a round is the last: one duel, with two in it
--- @param duels BracketDuel[]
--- @return boolean
function Bracket.IsFinal(duels)
  return #duels == 1 and duels[1].b ~= nil
end

--- Whether every duel of a round is decided
--- @param duels BracketDuel[]
--- @return boolean
function Bracket.Decided(duels)
  for _, duel in ipairs(duels) do
    if not duel.winner then
      return false
    end
  end
  return true
end
