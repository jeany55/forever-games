-- How well the computer plays Yacht-Z: plays a card alone at every level, as many times as asked,
-- and says what it scores on average, how often it makes 200, and how long it thinks for a move.
--
--   lua Tools/YachtBench.lua [games] [level...]
--
-- Run from the top of the addon. The numbers in Games/Yacht.lua's notes on the computer are
-- from 2000 games.

local ADDON_NAME = "ForeverGames"
local FILES = {
  "Engine/Codec.lua",
  "Engine/Random.lua",
  "Engine/Tables.lua",
  "Engine/Games.lua",
  "Engine/Daily.lua",
  "Engine/Race.lua",
  "Engine/Computer.lua",
  "Games/Yacht.lua",
}

local private = { L = setmetatable({}, {
  __index = function(_, key)
    return key
  end,
}) }
for _, file in ipairs(FILES) do
  assert(loadfile(file))(ADDON_NAME, private)
end

local game = private.Games.Get("yacht")
local Computer = private.Computer
local games = tonumber(arg[1]) or 500
local levels = { select(2, unpack(arg)) }
if #levels == 0 then
  levels = Computer.LEVELS
end

for _, level in ipairs(levels) do
  local sum, squares, made, moves, started = 0, 0, 0, 0, os.clock()
  for seed = 1, games do
    local random = private.Random.New(seed)
    local state = game.newState(1, random)
    local ply = 0
    while not state.over do
      ply = ply + 1
      local move = Computer.Think(game, Computer.Copy(state), 1, level, seed * 1000 + ply):Finish()
      assert(game.validate(state, 1, move), move)
      game.apply(state, 1, move, random)
    end
    local total = game.rules.totalOf(state, 1)
    sum, squares, moves = sum + total, squares + total * total, moves + ply
    made = made + (total >= 200 and 1 or 0)
  end
  local mean = sum / games
  local spread = math.sqrt(math.max(0, squares / games - mean * mean))
  print(string.format("%-7s %6.1f average (spread %.0f, error %.1f)  %3.0f%% made 200  %.1f ms a move", level, mean, spread, spread / math.sqrt(games), 100 * made / games, 1000 * (os.clock() - started) / moves))
end
