--------------------------
--  Starfall
--------------------------
-- A game for one in a sky full of moonstones: fire falling stars from the crescent at the top,
-- light every star of every constellation before they run out, and score what you can on the
-- way. Every night is laid out from the match's chance (Board.lua), so a race or the day's
-- challenge gives everyone the same sky.
--
-- A move is a shot: "a" and the aim, in tenths of a degree round from straight left to straight
-- right (Board.AIMS). The rules fly it out by the engine's physics, which comes out the same on
-- every computer, so a match is its aims and nothing else, and the event the move leaves behind
-- is the whole flight, for the view to play back (View.lua).
--
-- Starfall is an addon of its own, not a part of Forever Games: it knows the engine only by what
-- ForeverGamesAPI has (Engine/API.lua). Its strings are in Locales/enUS.lua, its pictures and
-- sounds in Images/ and Sounds/, made by Tools/make_starfall.py.

--- @type string, table
local ADDON, own = ...
local engine = ForeverGamesAPI
local L = engine.L
local Board = own.Board

-- Falling stars to begin a night with
local STARS = 12
-- The one move
local AIM = "^a(%d+)$"
-- The most points kept
local MOST = 99999999
-- The aims listed as moves, so many tenths of a degree apart
local LISTED = 20

--- @class StarfallState
--- @field stones StarfallStone[]
--- @field constellations StarfallConstellation[]
--- @field pattern string What the sky was laid out from
--- @field gone table<integer, boolean> The stones lit and gone
--- @field stars integer Falling stars left to fire
--- @field score integer
--- @field shots integer Fired so far
--- @field well integer Where the Moonwell is, Board.WellLeft
--- @field over boolean
--- @field outcome { winner: integer, detail: string }?

--- @return StarfallState
local function newState(_, random)
  local stones, constellations, pattern = Board.Make(random)
  return {
    stones = stones,
    constellations = constellations,
    pattern = pattern,
    gone = {},
    stars = STARS,
    score = 0,
    shots = 0,
    well = Board.NextWell(random),
    over = false,
  }
end

--- @return integer? The aim of a move, if it is one
local function aimOf(move)
  local digits = type(move) == "string" and #move <= 5 and move:match(AIM)
  local aim = digits and tonumber(digits)
  -- Written the one way, so that no shot can be written two
  if aim and aim <= Board.AIMS and tostring(aim) == digits then
    return aim
  end
  return nil
end

local function validate(state, seat, move)
  if seat ~= 1 then
    return false, "not_your_turn"
  elseif state.over or not aimOf(move) then
    return false, "invalid_move"
  end
  return true
end

--- @param state StarfallState
local function apply(state, _, move, random)
  local shot = Board.Shoot(state, aimOf(move))
  state.shots = state.shots + 1
  state.stars = state.stars - 1 + (shot.well and 1 or 0)
  state.score = math.min(MOST, state.score + shot.points)
  if Board.StarsLeft(state) == 0 then
    -- The night won: every star not fired is worth a fortune
    shot.bonus = state.stars * Board.UNSPENT
    state.score = math.min(MOST, state.score + shot.bonus)
    state.over = true
    state.outcome = { winner = 1, detail = "starfall_won" }
  elseif state.stars == 0 then
    state.over = true
    state.outcome = { winner = 0, detail = "starfall_dawn" }
  else
    state.well = Board.NextWell(random, state.well)
  end
  return shot
end

local function moves(state)
  if state.over then
    return {}
  end
  local list = {}
  for aim = 0, Board.AIMS, LISTED do
    list[#list + 1] = "a" .. aim
  end
  return list
end

engine.Games.Register({
  id = "starfall",
  name = L["game_starfall"],
  description = L["game_starfall_description"],
  genre = "solo",
  icon = "Interface\\AddOns\\ForeverGames_Starfall\\Images\\icon",
  plugin = ADDON,
  version = 1,
  seats = 1,
  howto = {
    { heading = L["howto_goal"], text = L["starfall_howto_goal"] },
    { heading = L["howto_controls"], text = L["starfall_howto_controls"] },
    { heading = L["starfall_howto_stones"], text = L["starfall_howto_stones_text"] },
    { heading = L["howto_scoring"], text = L["starfall_howto_scoring"] },
    { heading = L["starfall_howto_well"], text = L["starfall_howto_well_text"] },
    { heading = L["howto_end"], text = L["starfall_howto_end"] },
  },
  clock = "move",
  newState = newState,
  turn = function()
    return 1
  end,
  validate = validate,
  apply = apply,
  moves = moves,
  result = function(state)
    return state.outcome
  end,
  progress = function(state)
    if state.over then
      return L["starfall_progress_over"]:format(own.commas(state.score))
    end
    local left, all = Board.StarsLeft(state)
    return L["starfall_progress"]:format(all - left, all, state.stars)
  end,
  record = function(state)
    if state.over then
      return { { key = "score", value = state.score } }
    end
    return nil
  end,
  -- Raced for points, on the same sky, and the rival's score after each shot shown as it goes
  raceFor = { key = "score", show = function(value)
    return L["starfall_points"]:format(own.commas(value))
  end },
  ghost = { marks = true },
  -- The day's sky, the same for the whole guild
  daily = {
    score = function(state)
      return state.score
    end,
  },
  createView = own.CreateView,
})
