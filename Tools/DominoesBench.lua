-- How well the computer plays Dominoes: plays two levels against each other, as many matches as
-- asked with each taking the first seat in turn, and says how often each won, how many hands a
-- match took and how long it thinks for a move.
--
--   lua Tools/DominoesBench.lua [matches] [level] [level] [draw] [target]
--
-- Run from the top of the addon. "draw" plays the Draw game, and the target is 100 unless given.
-- The numbers in Games/Dominoes.lua's notes on the computer are from 200 to 400 matches.

local ADDON_NAME = "ForeverGames"
local FILES = {
  "Engine/Codec.lua",
  "Engine/Random.lua",
  "Engine/Tables.lua",
  "Engine/Bones.lua",
  "Engine/Games.lua",
  "Engine/Daily.lua",
  "Engine/Race.lua",
  "Engine/Computer.lua",
  "Games/Dominoes.lua",
}

local private = { L = setmetatable({}, {
  __index = function(_, key)
    return key
  end,
}) }
for _, file in ipairs(FILES) do
  assert(loadfile(file))(ADDON_NAME, private)
end

local game = private.Games.Get("dominoes")
local Computer = private.Computer
local matches = tonumber(arg[1]) or 200
local levels = { arg[2] or "easy", arg[3] or "medium" }
local rules = { draw = arg[4] == "draw", target = tonumber(arg[5]) or 100 }

local wins, hands, moves, started = { 0, 0 }, 0, 0, os.clock()
local thinking = { 0, 0 }
for index = 1, matches do
  local random = private.Random.New(index)
  local state = game.newState(2, random, rules)
  -- Which of the two levels sits in which seat: the first in seat 1 every other match
  local levelOf = index % 2 == 1 and { 1, 2 } or { 2, 1 }
  local ply = 0
  while not state.outcome do
    ply = ply + 1
    local seat = state.turn
    local seen = game.visible(state, seat)
    local clock = os.clock()
    local move = Computer.Think(game, seen, seat, levels[levelOf[seat]], index * 10000 + ply):Finish()
    thinking[levelOf[seat]] = thinking[levelOf[seat]] + os.clock() - clock
    assert(game.validate(state, seat, move), move)
    game.apply(state, seat, move, random)
    assert(ply < 2000, "a match that doesn't end")
  end
  local winner = state.outcome.winner
  if winner > 0 then
    wins[levelOf[winner]] = wins[levelOf[winner]] + 1
  end
  hands, moves = hands + state.hand, moves + ply
end

local function rate(count)
  local share = count / matches
  return 100 * share, 100 * math.sqrt(share * (1 - share) / matches)
end
local kind = rules.draw and "Draw" or "Block"
print(string.format("%s rules, to %d, %d matches, %.1f hands and %.0f moves a match", kind, rules.target, matches, hands / matches, moves / matches))
for which = 1, 2 do
  local share, error = rate(wins[which])
  local ms = 1000 * thinking[which] / (moves / 2)
  print(string.format("  %-7s won %5.1f%% (error %.1f)  %.2f ms a move", levels[which], share, error, ms))
end
