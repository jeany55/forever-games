--------------------------
--  Pinball
--------------------------
-- Moonglade, a pinball machine: three balls for the best score you can make, on a table with a
-- ramp onto a wire that winds over the bumpers and down a corkscrew, the Moonwell that shoots the
-- ball up a glass tube onto a wire of its own, quests, a raid on Onyxia and two class spells. The
-- table, its rules and the machine it is shown on are this addon's other files: Images/Table.lua
-- and Build.lua (what the ball meets), Rules.lua (a game played on it, by the engine's physics)
-- and Machine.lua (everything seen and heard).
--
-- As far as Forever Games knows, the game has one move: "s" and the score, the game over with
-- that many points. Everything before it is the machine's business and happens a thousand times
-- a second, so a game left and loaded again begins again at the first ball. The best score is
-- kept, and can be raced, the higher winning. It isn't the day's challenge: the table is the same
-- every day, and the engine's day is a different deal each day.
--
-- Pinball is an addon of its own, not a part of Forever Games: it knows the engine only by what
-- ForeverGamesAPI has (Engine/API.lua), as any other addon that brings a game would. Its strings
-- are in Locales/enUS.lua, its pictures and sounds in Images/ and Sounds/, made by the tools in
-- the repository's Tools/ (make_pinball.py, make_pinball_fx.py, make_pinball_sounds.py).

--- @type string, table
local ADDON, own = ...
local engine = ForeverGamesAPI
local L = engine.L
local Machine = own.Machine

-- The one move: the game over, with its score
local SCORE = "^s(%d+)$"
-- Scores are kept and raced in whole points, no more than the engine keeps of a race (Engine/Race.lua)
local MOST = 9999999

--- @class PinballState
--- @field over boolean The last ball has gone
--- @field score number? What the game came to

--- @return PinballState
local function newState()
  return { over = false }
end

local function validate(state, seat, move)
  if seat ~= 1 then
    return false, "not_your_turn"
  elseif state.over or type(move) ~= "string" or #move > 12 or not move:match(SCORE) then
    return false, "invalid_move"
  end
  return true
end

local function apply(state, _, move)
  state.over = true
  state.score = math.min(MOST, tonumber(move:match(SCORE)))
  return { score = state.score }
end

local function moves(state)
  if state.over then
    return {}
  end
  return { "s0" }
end

local function result(state)
  return state.over and { winner = 1 } or nil
end

-----------------------------
-- View
-----------------------------
-- The machine in the window, as big as the room there is, the spells beside it. A game is played
-- on it while the match is on; once it is over, the machine stands waiting, its last score and the
-- best on its display.

--- The settings the table plays with: the machine's own, unchanged
local function tune()
  local made = {}
  for key, value in pairs(own.DEFAULTS) do
    made[key] = value
  end
  for name, material in pairs(own.Table.materials) do
    made[name .. ".bounce"], made[name .. ".friction"] = material.bounce, material.friction
  end
  return made
end

local View = {}
View.__index = View

local function createView(stage)
  local self = setmetatable({ stage = stage }, View)
  Machine.New(stage, {
    tune = tune(),
    L = L,
    soundOn = engine.SoundOn,
    best = function()
      local view = self.view
      return view and view.best and view.best("score")
    end,
    onOver = function(game)
      self:over(game)
    end,
    onView = function(mode)
      engine.Settings("pinball").view = mode
    end,
  })
  Machine.SetView(engine.Settings("pinball").view or "auto")
  local ticker = CreateFrame("Frame", nil, stage)
  ticker:SetAllPoints()
  self.ticker = ticker
  engine.Widgets.Keys(ticker, function(key)
    return self.view ~= nil and Machine.KeyDown(key)
  end, true)
  ticker:SetScript("OnKeyUp", function(_, key)
    Machine.KeyUp(key)
  end)
  ticker:SetScript("OnHide", function()
    Machine.LetGo()
  end)
  ticker:SetScript("OnUpdate", function(_, elapsed)
    Machine.Tick(elapsed)
  end)
  return self
end

function View:Layout(width, height)
  Machine.Layout(width, height)
end

function View:Update(view)
  self.view = view
  --- @type PinballState
  local state = view.state
  local id = view.match.id
  if state.over then
    -- Over: a game that just ended here shows its own end, and goes back to waiting by itself
    if self.playing ~= id and self.shown ~= id then
      Machine.Start({ idle = true, over = state.score })
    end
    self.shown = id
    return
  end
  if self.playing ~= id then
    if view.canMove and view.live then
      Machine.Start({ match = id })
      self.playing = id
    elseif self.shown ~= id then
      Machine.Start({ idle = true })
    end
    self.shown = id
  end
end

--- The machine's game is over: its score is the move
function View:over(game)
  local view = self.view
  if view and game.match == view.match.id and view.canMove and not view.state.over then
    view.submit("s" .. math.floor(math.max(0, game.score)))
  end
end

engine.Games.Register({
  id = "pinball",
  name = L["game_pinball"],
  description = L["game_pinball_description"],
  genre = "solo",
  icon = "Interface\\AddOns\\ForeverGames_Pinball\\Images\\icon",
  plugin = ADDON,
  version = 1,
  seats = 1,
  howto = {
    { heading = L["howto_goal"], text = L["pinball_howto_goal"] },
    { heading = L["howto_controls"], text = L["pinball_howto_controls"] },
    { heading = L["pinball_howto_shots"], text = L["pinball_howto_shots_text"] },
    { heading = L["pinball_howto_spells"], text = L["pinball_howto_spells_text"] },
    { heading = L["howto_end"], text = L["pinball_howto_end"] },
  },
  clock = "open",
  newState = newState,
  turn = function()
    return 1
  end,
  validate = validate,
  apply = apply,
  moves = moves,
  result = result,
  progress = function(state)
    if state.over then
      return L["pinball_progress_over"]:format(Machine.commas(state.score or 0))
    end
    return L["pinball_progress"]
  end,
  record = function(state)
    if state.over then
      return { { key = "score", value = state.score } }
    end
    return nil
  end,
  -- Raced for points, the higher the better: every game is on the same table
  raceFor = { key = "score", show = function(value)
    return L["pinball_points"]:format(Machine.commas(value))
  end },
  createView = createView,
})
