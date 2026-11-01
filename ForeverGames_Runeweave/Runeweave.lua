--------------------------
--  Runeweave
--------------------------
-- A game for one on a board of runes of the six schools of magic: swap two runes next to each
-- other to line up three or more of a school, and they are cleared, the runes above fall into
-- their place and new ones come in from the top. Lines of four, five and lines that cross make
-- runes of power. Every rune cleared fills the ley meter, and each time it is full the weave
-- surges: three more moves, and every point after it is worth one more time as much. The game
-- is over when the moves run out. Every board is laid out from the match's chance (Board.lua),
-- so a race or the day's challenge gives everyone the same board and the same runes falling.
--
-- A move is a swap: "s", the square counted from 0 along the rows from the top left, and "r"
-- for the rune to its right or "d" for the one below it. The rules play the swap out to the
-- end, and the event it leaves behind is every step of it, for the view to play back (View.lua).
--
-- Runeweave is an addon of its own, not a part of Forever Games: it knows the engine only by
-- what ForeverGamesAPI has (Engine/API.lua). Its strings are in Locales/enUS.lua, its pictures
-- and sounds in Images/ and Sounds/, made by Tools/make_runeweave.py.

--- @type string, table
local ADDON, own = ...
local engine = ForeverGamesAPI
local L = engine.L
local Board = own.Board

-- Moves to begin with, and how many more each surge gives
local MOVES = 20
local SURGE_MOVES = 3
-- Runes the ley meter takes to fill at the first level, and how many more at each one after
local LEY, LEY_MORE = 25, 10
-- The most points kept
local MOST = 99999999

own.MOVES, own.SURGE_MOVES = MOVES, SURGE_MOVES

--- How many runes fill the ley meter at a level
--- @param level integer
--- @return integer
function own.Need(level)
  return LEY + LEY_MORE * (level - 1)
end

--- @class RuneweaveState
--- @field board integer[] Board.Value of every square
--- @field moves integer Left to make
--- @field swaps integer Made so far
--- @field score integer
--- @field level integer What points are multiplied by
--- @field ley integer Runes in the ley meter towards the next level
--- @field over boolean

--- @return RuneweaveState
local function newState(_, random)
  return {
    board = Board.Make(random),
    moves = MOVES,
    swaps = 0,
    score = 0,
    level = 1,
    ley = 0,
    over = false,
  }
end

local function validate(state, seat, move)
  if seat ~= 1 then
    return false, "not_your_turn"
  end
  local a, b = Board.Swap(move)
  if state.over or not a or not Board.Works(state.board, a, b) then
    return false, "invalid_move"
  end
  return true
end

--- @param state RuneweaveState
local function apply(state, _, move, random)
  local a, b = Board.Swap(move)
  local play = Board.Play(state.board, a, b, state.level, random)
  state.swaps = state.swaps + 1
  state.moves = state.moves - 1
  state.score = math.min(MOST, state.score + play.points)
  -- The ley meter fills with every rune cleared, and surges as often as it is full
  play.level, play.ley = state.level, state.ley
  play.surges = 0
  state.ley = state.ley + play.count
  while state.ley >= own.Need(state.level) do
    state.ley = state.ley - own.Need(state.level)
    state.level = state.level + 1
    state.moves = state.moves + SURGE_MOVES
    play.surges = play.surges + 1
  end
  if state.moves <= 0 then
    state.over = true
  end
  return play
end

engine.Games.Register({
  id = "runeweave",
  name = L["game_runeweave"],
  description = L["game_runeweave_description"],
  genre = "solo",
  icon = "Interface\\AddOns\\ForeverGames_Runeweave\\Images\\icon",
  plugin = ADDON,
  version = 1,
  seats = 1,
  howto = {
    { heading = L["howto_goal"], text = L["runeweave_howto_goal"] },
    { heading = L["howto_controls"], text = L["runeweave_howto_controls"] },
    { heading = L["runeweave_howto_power"], text = L["runeweave_howto_power_text"] },
    { heading = L["howto_scoring"], text = L["runeweave_howto_scoring"] },
    { heading = L["runeweave_howto_surge"], text = L["runeweave_howto_surge_text"] },
    { heading = L["howto_end"], text = L["runeweave_howto_end"] },
  },
  clock = "move",
  newState = newState,
  turn = function()
    return 1
  end,
  validate = validate,
  apply = apply,
  moves = function(state)
    if state.over then
      return {}
    end
    return Board.Moves(state.board)
  end,
  result = function(state)
    return state.over and { winner = 1, detail = "runeweave_out" } or nil
  end,
  progress = function(state)
    if state.over then
      return L["runeweave_progress_over"]:format(own.commas(state.score), state.level)
    end
    return L["runeweave_progress"]:format(own.commas(state.score), state.moves)
  end,
  record = function(state)
    if state.over then
      return { { key = "score", value = state.score } }
    end
    return nil
  end,
  -- Raced for points, on the same board, and the rival's score after each move shown as it goes
  raceFor = { key = "score", show = function(value)
    return L["runeweave_points"]:format(own.commas(value))
  end },
  ghost = { marks = true },
  -- The day's board, the same for the whole guild
  daily = {
    score = function(state)
      return state.score
    end,
  },
  createView = own.CreateView,
})
