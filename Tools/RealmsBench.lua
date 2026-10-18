-- How well the computer plays CarcassonneWoW: plays it against itself, two players at a time, as
-- many games as asked, each pair of games from the same deal with the seats swapped. Says how
-- often the first wins, what each scores on average, and how long each thinks for a move.
--
--   lua Tools/RealmsBench.lua [games] [first] [second]
--
-- A player is a level (easy, medium, hard), "random" for any move at all, or a level with some of
-- the computer's weights changed (Games/Realms.lua, TUNING): "hard:close=8,hand=3".
-- Run from the top of the addon.

local ADDON_NAME = "ForeverGames"
local FILES = {
  "Engine/Codec.lua",
  "Engine/Random.lua",
  "Engine/Tables.lua",
  "Engine/Games.lua",
  "Engine/Daily.lua",
  "Engine/Race.lua",
  "Engine/Computer.lua",
  "Games/Realms.lua",
}

local private = { L = setmetatable({}, {
  __index = function(_, key)
    return key
  end,
}) }
for _, file in ipairs(FILES) do
  assert(loadfile(file))(ADDON_NAME, private)
end

local game = private.Games.Get("realms")
local Brain = private.Computer.Brain
local TUNING = game.rules.TUNING
local USUAL = {}
for key, value in pairs(TUNING) do
  USUAL[key] = value
end

local games = tonumber(arg[1]) or 40
local players = { arg[2] or "hard", arg[3] or "easy" }

--- A player taken apart: its level and the weights it changes
--- @param text string
--- @return string level, table<string, number> weights
local function parse(text)
  local level, changes = text:match("^([^:]+):?(.*)$")
  local weights = {}
  for key, value in changes:gmatch("(%w+)=([%d%.]+)") do
    assert(USUAL[key], "no weight called " .. key)
    weights[key] = tonumber(value)
  end
  return level, weights
end

local specs = { { parse(players[1]) }, { parse(players[2]) } }
local wins, margin, thinking, moves, points = 0, 0, { 0, 0 }, { 0, 0 }, { 0, 0 }
for pair = 1, games / 2 do
  for swap = 0, 1 do
    local random = private.Random.New(pair)
    local state = game.newState(2, random, {})
    -- Seat 1 is the first player in the first game of the pair and the second in the other
    local who = swap == 0 and { 1, 2 } or { 2, 1 }
    local dice = private.Random.New(pair * 7 + swap)
    while not state.outcome do
      local seat = state.turn
      local player = who[seat]
      local level, weights = specs[player][1], specs[player][2]
      local started = os.clock()
      local move
      if level == "random" then
        local list = game.moves(state, seat)
        move = list[dice:Roll(#list)]
      else
        for key, value in pairs(USUAL) do
          TUNING[key] = weights[key] or value
        end
        move = game.computer.think(state, seat, Brain.New(game, seat, level, pair * 1000 + #state.tiles))
      end
      thinking[player] = thinking[player] + os.clock() - started
      moves[player] = moves[player] + 1
      assert(game.validate(state, seat, move), move)
      game.apply(state, seat, move, random)
    end
    local first = swap == 0 and 1 or 2
    if state.outcome.winner == first then
      wins = wins + 1
    elseif state.outcome.winner == 0 then
      wins = wins + 0.5
    end
    margin = margin + state.scores[first] - state.scores[3 - first]
    points[1], points[2] = points[1] + state.scores[first], points[2] + state.scores[3 - first]
  end
end
print(string.format("%s against %s: won %.1f of %d, %.1f to %.1f points on average; %.1f and %.1f ms a move", players[1], players[2], wins, games, points[1] / games, points[2] / games, 1000 * thinking[1] / moves[1], 1000 * thinking[2] / moves[2]))
