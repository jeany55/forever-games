--------------------------
--  Pig
--------------------------
-- The dice game, as an example of a game in an addon of its own (API.md). On your turn you roll a
-- die as often as you like, and every roll is added to what you have this turn. Roll a one and
-- you lose it all and the turn passes. Hold, and what you have is banked. The first to bank the
-- target wins.
--
-- There are two moves: "r" rolls and "h" holds. The die is rolled by the engine's dice (the
-- `random` that apply is handed), so every player's client rolls the same.

-- Every addon is handed its name and a table of its own. The engine is ForeverGamesAPI
local ADDON = ...
local engine = ForeverGamesAPI
local L = engine.L

local ROLL, HOLD = "r", "h"
-- What a turn is held at by the computer, unless that would win
local COMPUTER_HOLDS_AT = 20

--- @class PigState
--- @field scores number[] What each seat has banked
--- @field turn number Whose turn it is
--- @field pot number What they have rolled this turn
--- @field target number
--- @field out table<number, boolean> Seats that resigned from a game for more than two
--- @field last number? The roll before, for the view

--- @param seats number
--- @param random Random
--- @param rules table<string, any> What every option is set to
--- @return PigState
local function newState(seats, _, rules)
  local scores = {}
  for seat = 1, seats do
    scores[seat] = 0
  end
  return { scores = scores, turn = 1, pot = 0, target = rules.target, out = {} }
end

--- The next seat after this one that is still playing
--- @param state PigState
--- @param seat number
--- @return number
local function nextSeat(state, seat)
  local count = #state.scores
  for step = 1, count do
    local candidate = (seat + step - 1) % count + 1
    if not state.out[candidate] then
      return candidate
    end
  end
  return seat
end

--- @param state PigState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  if seat ~= state.turn then
    return false, "not_your_turn"
  end
  if move == ROLL or (move == HOLD and state.pot > 0) then
    return true
  end
  return false, "invalid_move"
end

--- @param state PigState
--- @param seat number
--- @param move string
--- @param random Random
--- @return table event What the view is shown happening
local function apply(state, seat, move, random)
  if move == HOLD then
    state.scores[seat] = state.scores[seat] + state.pot
    state.pot, state.last = 0, nil
    if state.scores[seat] < state.target then
      state.turn = nextSeat(state, seat)
    end
    return { held = true }
  end
  local roll = random:Roll(6)
  state.last = roll
  if roll == 1 then
    state.pot = 0
    state.turn = nextSeat(state, seat)
  else
    state.pot = state.pot + roll
  end
  return { roll = roll }
end

--- Someone resigned from a game for three or four: the others play on without them
--- @param state PigState
--- @param seat number
local function drop(state, seat)
  state.out[seat] = true
  if state.turn == seat then
    state.pot, state.last = 0, nil
    state.turn = nextSeat(state, seat)
  end
end

--- @param state PigState
--- @return string[]
local function moves(state)
  return state.pot > 0 and { ROLL, HOLD } or { ROLL }
end

--- @param state PigState
--- @return { winner: number }?
local function result(state)
  for seat, score in ipairs(state.scores) do
    if score >= state.target then
      return { winner = seat }
    end
  end
  return nil
end

-----------------------------
-- The computer
-----------------------------
-- It holds at twenty, or as soon as that wins. A roll isn't to be taken back and tried again

local COMPUTER = {
  takeback = false,
  think = function(state, seat)
    local pot = state.pot
    if pot > 0 and (pot >= COMPUTER_HOLDS_AT or state.scores[seat] + pot >= state.target) then
      return HOLD
    end
    return ROLL
  end,
}

-----------------------------
-- View
-----------------------------
-- Everyone's score, what the player whose turn it is has rolled, and two buttons. Made from the
-- engine's widgets (GUI/Widgets.lua) like any game's.

--- @class PigView: GameViewObject
local View = {}
View.__index = View

--- @param stage Frame
--- @return PigView
local function createView(stage)
  local Widgets = engine.Widgets
  local self = setmetatable({ scores = {} }, View)
  self.rolled = Widgets.Label(stage, "GameFontNormalHuge")
  self.rolled:SetPoint("CENTER", 0, 60)
  self.pot = Widgets.Label(stage, "GameFontHighlightLarge")
  self.pot:SetPoint("TOP", self.rolled, "BOTTOM", 0, -12)
  self.roll = Widgets.Button(stage, L["pig_roll"], 100, 28)
  self.roll:SetPoint("TOPRIGHT", self.pot, "BOTTOM", -6, -20)
  self.roll:SetScript("OnClick", function()
    self.view.submit(ROLL)
  end)
  self.hold = Widgets.Button(stage, L["pig_hold"], 100, 28)
  self.hold:SetPoint("TOPLEFT", self.pot, "BOTTOM", 6, -20)
  self.hold:SetScript("OnClick", function()
    self.view.submit(HOLD)
  end)
  self.stage = stage
  return self
end

function View:Layout()
end

--- @param view GameView
function View:Update(view)
  self.view = view
  --- @type PigState
  local state = view.state
  for seat, score in ipairs(state.scores) do
    local label = self.scores[seat]
    if not label then
      label = engine.Widgets.Label(self.stage, "GameFontHighlight")
      label:SetPoint("TOPLEFT", 16, -16 - (seat - 1) * 20)
      self.scores[seat] = label
    end
    label:SetText(L["pig_score"]:format(view.names[seat] or "", score))
  end
  local event = view.played
  if event and event.roll == 1 then
    self.rolled:SetText(L["pig_bust"])
  elseif state.last then
    self.rolled:SetText(L["pig_rolled"]:format(state.last))
  else
    self.rolled:SetText("")
  end
  self.pot:SetText(L["pig_pot"]:format(state.pot))
  local mine = view.canMove and view.live and state.turn == view.seat
  self.roll:SetEnabled(mine)
  self.hold:SetEnabled(mine and state.pot > 0)
  if event and event.roll and view.fresh then
    engine.Widgets.PlaySound("IG_ABILITY_ICON_DROP")
  end
end

engine.Games.Register({
  id = "pig",
  name = L["game_pig"],
  description = L["game_pig_description"],
  genre = "dice",
  plugin = ADDON,
  version = 1,
  seats = { 2, 3, 4 },
  options = {
    {
      id = "target",
      name = L["pig_option_target"],
      description = L["pig_option_target_tip"],
      choices = { 50, 100 },
      default = 100,
    },
  },
  howto = {
    { heading = L["howto_goal"], text = L["pig_howto_goal"] },
    { heading = L["howto_turn"], text = L["pig_howto_turn"] },
  },
  newState = newState,
  turn = function(state)
    return state.turn
  end,
  validate = validate,
  apply = apply,
  moves = moves,
  result = result,
  drop = drop,
  computer = COMPUTER,
  createView = createView,
})
