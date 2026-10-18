--------------------------
--  Mancala
--------------------------
-- Kalah, the mancala most people know by that name. Each player has six pits along their side of
-- the board and a store at their right. A turn is picking up every seed in one of your pits and
-- sowing them one at a time into the pits after it, anticlockwise: along your side, into your
-- store, along your opponent's side, never into their store, and round again for as long as the
-- seeds last. The last seed decides what happens next. In your own store, you go again. In an
-- empty pit of your own, with seeds in the pit across from it, you take both. Once either side
-- has no seeds left, everything still on the other side goes to that side's store, and whoever
-- has more in their store wins.
--
-- A move is the pit sown from, "1" to "6" from the mover's left as they see the board.
--
-- Holes are numbered anticlockwise from the first player's leftmost pit: 1 to 6 are the first
-- player's pits and 7 their store, 8 to 13 the second player's pits and 14 their store. The pit
-- across from hole h is 14 - h.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L

local PITS = 6
local HOLES = 2 * (PITS + 1)

--- @class MancalaState
--- @field holes number[] Seeds in each hole
--- @field turn number
--- @field lone boolean? The last seed in an empty pit of your own is taken even with nothing across from it
--- @field outcome { winner: number }?

--- A capture: the last seed sown and what was across from it, into the store
--- @class MancalaCapture
--- @field at number Where the last seed came to rest
--- @field across number The pit across from it
--- @field seeds number Seeds taken, the last one with them

--- Seeds left on a side once the other is empty, going to that side's store
--- @class MancalaSweep
--- @field from number
--- @field to number
--- @field seeds number

--- @class MancalaEvent: MatchEvent
--- @field from number The hole sown from
--- @field before number[] Seeds in each hole before the move
--- @field stops number[] The hole each seed was sown into, in order
--- @field again boolean? The last seed went into the mover's store, and they go again
--- @field capture MancalaCapture?
--- @field sweeps MancalaSweep[]? The game ended, and these were left on the board

--- @param seat number
--- @return number
local function other(seat)
  return 3 - seat
end

--- @param seat number
--- @return number
local function storeOf(seat)
  return seat * (PITS + 1)
end

--- The hole of a seat's pit
--- @param seat number
--- @param pit number 1 to 6, from their left
--- @return number
local function holeOf(seat, pit)
  return (seat - 1) * (PITS + 1) + pit
end

--- Whose side a hole is on
--- @param hole number
--- @return number
local function ownerOf(hole)
  return hole <= PITS + 1 and 1 or 2
end

--- @param hole number A pit
--- @return number
local function acrossFrom(hole)
  return HOLES - hole
end

--- Seeds on a seat's side, not counting the store
--- @param holes number[]
--- @param seat number
--- @return number
local function sideOf(holes, seat)
  local count = 0
  for pit = 1, PITS do
    count = count + holes[holeOf(seat, pit)]
  end
  return count
end

--- Every hole the seeds of a pit would be sown into, in order
--- @param holes number[]
--- @param seat number
--- @param from number The hole
--- @return number[]
local function sowing(holes, seat, from)
  local skipped = storeOf(other(seat))
  local stops, at = {}, from
  for _ = 1, holes[from] do
    at = at % HOLES + 1
    if at == skipped then
      at = at % HOLES + 1
    end
    stops[#stops + 1] = at
  end
  return stops
end

--- What the last seed of a pit would do: go again, take seeds, or neither
--- @param holes number[]
--- @param seat number
--- @param from number The hole
--- @param lone boolean?
--- @return number last Where the last seed comes to rest
--- @return boolean again
--- @return number taken Seeds taken, the last one with them, 0 for none
local function outcomeOf(holes, seat, from, lone)
  local stops = sowing(holes, seat, from)
  local last = stops[#stops]
  if last == storeOf(seat) then
    return last, true, 0
  end
  if ownerOf(last) ~= seat then
    return last, false, 0
  end
  -- Empty before the last seed means the last seed is the only one there. Seeds sown all the way
  -- round land in the pit sown from too, which is empty by then
  local landed = 0
  for _, stop in ipairs(stops) do
    if stop == last then
      landed = landed + 1
    end
  end
  local before = last == from and 0 or holes[last]
  if before + landed ~= 1 then
    return last, false, 0
  end
  local across = holes[acrossFrom(last)]
  for _, stop in ipairs(stops) do
    if stop == acrossFrom(last) then
      across = across + 1
    end
  end
  if across == 0 and not lone then
    return last, false, 0
  end
  return last, false, across + 1
end

--- @param seats number
--- @param random Random
--- @param rules table<string, any>
--- @return MancalaState
local function newState(seats, random, rules)
  local holes = {}
  for hole = 1, HOLES do
    holes[hole] = hole % (PITS + 1) == 0 and 0 or rules.seeds
  end
  return { holes = holes, turn = 1, lone = rules.lone or nil }
end

--- @param state MancalaState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  local pit = tonumber(move)
  if not pit or pit < 1 or pit > PITS or pit ~= math.floor(pit) or tostring(pit) ~= move then
    return false, "invalid_move"
  end
  if seat ~= state.turn then
    return false, "not_your_turn"
  end
  if state.holes[holeOf(seat, pit)] == 0 then
    return false, "pit_empty"
  end
  return true
end

--- @param state MancalaState
--- @param seat number
--- @param move string
--- @return MancalaEvent
local function apply(state, seat, move)
  local holes = state.holes
  local pit = tonumber(move)
  local from = holeOf(seat, pit)
  local before = { unpack(holes) }
  local last, again, taken = outcomeOf(holes, seat, from, state.lone)
  local stops = sowing(holes, seat, from)

  holes[from] = 0
  for _, stop in ipairs(stops) do
    holes[stop] = holes[stop] + 1
  end
  --- @type MancalaEvent
  local event = { from = from, before = before, stops = stops, again = again or nil, notation = move }
  local store = storeOf(seat)
  if taken > 0 then
    local across = acrossFrom(last)
    holes[store] = holes[store] + holes[last] + holes[across]
    holes[last], holes[across] = 0, 0
    event.capture = { at = last, across = across, seeds = taken }
    event.notation = move .. "x" .. taken
  elseif again then
    event.notation = move .. "+"
  end

  -- Once a side is empty, what is left on the other goes to its owner
  if sideOf(holes, 1) == 0 or sideOf(holes, 2) == 0 then
    local sweeps = {}
    for hole = 1, HOLES do
      if hole % (PITS + 1) ~= 0 and holes[hole] > 0 then
        local to = storeOf(ownerOf(hole))
        sweeps[#sweeps + 1] = { from = hole, to = to, seeds = holes[hole] }
        holes[to] = holes[to] + holes[hole]
        holes[hole] = 0
      end
    end
    event.sweeps = sweeps
    local first, second = holes[storeOf(1)], holes[storeOf(2)]
    state.outcome = { winner = first > second and 1 or (second > first and 2 or 0) }
  end
  state.turn = again and seat or other(seat)
  return event
end

--- Every pit of the seat's with seeds in it
--- @param state MancalaState
--- @param seat number
--- @return string[]
local function moves(state, seat)
  local list = {}
  for pit = 1, PITS do
    if state.holes[holeOf(seat, pit)] > 0 then
      list[#list + 1] = tostring(pit)
    end
  end
  return list
end

-----------------------------
-- The computer
-----------------------------
-- Seeds in a store never leave it, so the store is most of what a position is worth, and more
-- than half of all the seeds in one is a game that is won however it goes on. Seeds still on a
-- player's side count for a little: once the other side runs dry they go to their owner, but
-- until then they can be taken.
--
-- It looks first at the moves that let it go again, from the pit nearest the store out, so as
-- not to spoil the next one; then at captures, the bigger the sooner. Going again doesn't end a
-- turn, so a position is never judged in the middle of one: it looks on until the turn is over.

-- What a seed is worth in a store, and on its owner's side of the board
local STORE, SIDE = 8, 1
-- A position won whatever happens, from the seat that has more than half
local SURE = 100000
-- Moves worth looking at first
local AGAIN, TAKE = 1000, 100

--- @param state MancalaState
--- @param seat number
--- @return number
local function standing(state, seat)
  local holes = state.holes
  local mine, theirs = holes[storeOf(seat)], holes[storeOf(other(seat))]
  local half = 0
  for hole = 1, HOLES do
    half = half + holes[hole]
  end
  half = half / 2
  if mine > half then
    return SURE + mine - theirs
  elseif theirs > half then
    return -SURE + mine - theirs
  end
  return STORE * (mine - theirs) + SIDE * (sideOf(holes, seat) - sideOf(holes, other(seat)))
end

local COMPUTER = {
  evaluate = standing,
  priority = function(state, move, seat)
    local from = holeOf(seat, tonumber(move))
    local _, again, taken = outcomeOf(state.holes, seat, from, state.lone)
    if again then
      return AGAIN + from
    end
    return taken > 0 and TAKE + taken or from
  end,
  noisy = function(state, move, seat)
    local _, again = outcomeOf(state.holes, seat, holeOf(seat, tonumber(move)), state.lone)
    return again
  end,
  key = function(state)
    return table.concat(state.holes, ",") .. ":" .. state.turn
  end,
  copy = function(state)
    return { holes = { unpack(state.holes) }, turn = state.turn, lone = state.lone, outcome = state.outcome }
  end,
  levels = {
    easy = { depth = 2, slip = 0.35, among = 3 },
    medium = { depth = 5, budget = 5000, slip = 0.08 },
    hard = { depth = 14, budget = 40000, quiet = 8 },
  },
}

-----------------------------
-- View
-----------------------------
-- A walnut board with the seeds as glass stones in its pits (GUI/Heaps.lua). Each player sees
-- their own side at the bottom, their store at the right. A move is played out the way it is
-- by hand: the seeds lifted and sown one at a time, what is taken swept into the store.
--
-- Pointing at a pit before playing it says what it would do: where the last seed lands, whether
-- that is another turn or what it takes.
--
-- The holes as the player sees them are slots, numbered the same way as the holes are for the
-- first player: 1 to 6 along the bottom from the left, 7 the store at the right, 8 to 13 along
-- the top from the right, 14 the store at the left.

local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\"
-- The board, in units. Tools/make_mancala.py draws it from the same numbers
local MARGIN_X, MARGIN_Y = 0.42, 0.5
local STORE_CELL, GAP, ROW_GAP = 0.96, 0.16, 0.2
local PIT_SIZE = 0.84
local STORE_WIDTH, STORE_HEIGHT = 0.86, 2.04
local WIDTH = 2 * MARGIN_X + 2 * STORE_CELL + 2 * GAP + PITS
local HEIGHT = 2 * MARGIN_Y + 2 + ROW_GAP
-- The shadow round the board in its texture, and how much of the texture it fills
local PAD = 0.22
local BOARD_ROWS = 392 / 512
-- A seed, in units, and how its looks are laid out in its textures: eight colours across, four
-- shapes down
local SEED = 0.31
local SEED_COLUMNS, SEED_ROWS = 8, 4
-- Lines of words above and below the board, and the room between them and it
local LINE_HEIGHT, LINE_GAP = 18, 4
-- How places are lit: a pit that can be played, the one pointed at, where its seeds would go
-- and where the last of them would land, what that would take, the pit the last move was made
-- from, and the store of the winner
local PLAYABLE = { 1, 0.84, 0.45, 0.22 }
local POINTED = { 1, 0.88, 0.5, 0.75 }
local PASSES = { 1, 1, 1, 0.13 }
local LANDS = { 1, 1, 1, 0.45 }
local AGAIN = { 0.45, 1, 0.5, 0.85, pulse = true }
local TAKES = { 1, 0.45, 0.25, 0.85, pulse = true }
local LAST = { 1, 1, 1, 0.16 }
local WINNER = { 1, 0.8, 0.3, 0.7, pulse = true }
-- While a move is played out: the store of a player who goes again, and what is being taken
local WENT_AGAIN = { 0.45, 1, 0.5, 0.9 }
local TAKING = { 1, 0.45, 0.25, 0.9 }
-- Seconds the store stays lit for going again
local AGAIN_LIT = 0.6
-- Seconds between a turn's seeds landing and what they take being swept up, and between that
-- and the end of the game sweeping up the rest
local TAKE_AFTER, SWEEP_AFTER, SWEEP_STAGGER = 0.12, 0.35, 0.07
local AGAIN_COLOR = { 0.55, 1, 0.55 }
local SOUNDS = { land = "mancalaSow", pour = "mancalaPour" }
local AGAIN_SOUND = "mancalaAgain"

--- The slot a hole is drawn in, for a player in a seat
--- @param hole number
--- @param seat number
--- @return number
local function slotOf(hole, seat)
  return (hole - 1 + (seat - 1) * (PITS + 1)) % HOLES + 1
end

--- The places of the board, by slot
--- @return table<number, HeapPlace>
local function places()
  local list = {}
  local firstX = MARGIN_X + STORE_CELL + GAP + 0.5
  local top, bottom = MARGIN_Y + 0.5, MARGIN_Y + 1.5 + ROW_GAP
  for pit = 1, PITS do
    list[pit] = {
      x = firstX + pit - 1,
      y = bottom,
      width = PIT_SIZE,
      height = PIT_SIZE,
      floor = 0.78,
      label = { x = firstX + pit - 1, y = HEIGHT - MARGIN_Y / 2 },
      glow = IMAGES .. "Mancala\\pit",
    }
    list[PITS + 1 + pit] = {
      x = firstX + PITS - pit,
      y = top,
      width = PIT_SIZE,
      height = PIT_SIZE,
      floor = 0.78,
      label = { x = firstX + PITS - pit, y = MARGIN_Y / 2 },
      glow = IMAGES .. "Mancala\\pit",
    }
  end
  local storeX = MARGIN_X + STORE_CELL / 2
  local storeTop = (HEIGHT - STORE_HEIGHT) / 2
  list[PITS + 1] = {
    x = WIDTH - storeX,
    y = HEIGHT / 2,
    width = STORE_WIDTH,
    height = STORE_HEIGHT,
    floor = 0.76,
    label = { x = WIDTH - storeX, y = HEIGHT - storeTop / 2 },
    glow = IMAGES .. "Mancala\\store",
  }
  list[HOLES] = {
    x = storeX,
    y = HEIGHT / 2,
    width = STORE_WIDTH,
    height = STORE_HEIGHT,
    floor = 0.76,
    label = { x = storeX, y = storeTop / 2 },
    glow = IMAGES .. "Mancala\\store",
  }
  return list
end

--- A seed's look, at a size
--- @param look number
--- @param pixels number
--- @return string, number[]
local function seedTexture(look, pixels)
  local column, row = (look - 1) % SEED_COLUMNS, math.floor((look - 1) / SEED_COLUMNS)
  local file = pixels > 36 and "seeds64" or "seeds32"
  local coords = { column / SEED_COLUMNS, (column + 1) / SEED_COLUMNS, row / SEED_ROWS, (row + 1) / SEED_ROWS }
  return IMAGES .. "Mancala\\" .. file, coords
end

--- @class MancalaView: GameViewObject
--- @field stage Frame
--- @field heaps Heaps
--- @field effects Effects
--- @field names FontString[] The opponent's above the board, the player's own below
--- @field note FontString What the last move did
--- @field preview FontString What the pit pointed at would do
--- @field pointed number? The slot pointed at
--- @field flash table<number, HeapHighlight>? Slots lit while a move is played out
--- @field width number The stage's
--- @field view GameView? What was last asked for
local View = {}
View.__index = View

--- @param stage Frame
--- @return MancalaView
local function createView(stage)
  local Widgets = private.Widgets
  --- @type MancalaView
  local self = setmetatable({ stage = stage, width = 0 }, View)

  self.heaps = private.Heaps.New(stage, {
    width = WIDTH,
    height = HEIGHT,
    places = places(),
    token = SEED,
    looks = SEED_COLUMNS * SEED_ROWS,
    textureFor = seedTexture,
    backdrop = {
      texture = IMAGES .. "Mancala\\board",
      coords = { 0, 1, 0, BOARD_ROWS },
      x = -PAD,
      y = -PAD,
      width = WIDTH + 2 * PAD,
      height = HEIGHT + 2 * PAD,
    },
    labelSize = 0.25,
    sounds = SOUNDS,
  })
  self.heaps:SetInput({
    pickable = function(slot)
      return self:playable(slot)
    end,
    onClick = function(slot)
      self:play(slot)
    end,
    onHover = function(slot)
      self.pointed = slot
      self:light()
    end,
  })
  -- The keys 1 to 6 play the pits from the left
  Widgets.Keys(self.heaps.frame, function(key)
    local slot = tonumber(key)
    if slot and slot >= 1 and slot <= PITS and self:playable(slot) then
      self:play(slot)
      return true
    end
    return false
  end)

  self.names = {}
  for index = 1, 2 do
    local name = Widgets.Label(stage, "GameFontHighlight")
    name:SetJustifyH("LEFT")
    self.names[index] = name
  end
  self.names[1]:SetPoint("BOTTOMLEFT", self.heaps.frame, "TOPLEFT", 0, LINE_GAP)
  self.names[2]:SetPoint("TOPLEFT", self.heaps.frame, "BOTTOMLEFT", 0, -LINE_GAP)
  self.note = Widgets.Label(stage, "GameFontHighlightSmall")
  self.note:SetPoint("BOTTOMRIGHT", self.heaps.frame, "TOPRIGHT", 0, LINE_GAP)
  self.note:SetTextColor(unpack(Widgets.GOLD))
  self.preview = Widgets.Label(stage, "GameFontHighlight")
  self.preview:SetPoint("TOPRIGHT", self.heaps.frame, "BOTTOMRIGHT", 0, -LINE_GAP)

  self.effects = private.Effects.New(stage)
  return self
end

--- @param width number
--- @param height number
function View:Layout(width, height)
  local room = height - 2 * (LINE_HEIGHT + LINE_GAP)
  -- The board's shadow needs a little room round it too
  self.heaps:SetSize(width * WIDTH / (WIDTH + 2 * PAD), room * HEIGHT / (HEIGHT + 2 * PAD))
  self.heaps.frame:ClearAllPoints()
  self.heaps.frame:SetPoint("CENTER")
  self.width, self.height = width, height
end

--- Whether the player may sow from a slot right now
--- @param slot number
--- @return boolean
function View:playable(slot)
  local view = self.view
  if not view or not view.canMove or slot < 1 or slot > PITS or self.heaps:Busy() then
    return false
  end
  return view.state.holes[holeOf(view.seat, slot)] > 0
end

--- @param slot number
function View:play(slot)
  self.pointed = nil
  self.heaps:SetEnabled(false)
  self.view.submit(tostring(slot))
end

--- Where a place is on the stage, for writing something there
--- @param slot number
--- @return number x, number y From the stage's top left corner
function View:spotOf(slot)
  local frame = self.heaps.frame
  local x, y = self.heaps:PointOf(slot)
  return (self.width - frame:GetWidth()) / 2 + x, (self.height - frame:GetHeight()) / 2 + y
end

--- Lights up the pits that can be played, and what the one pointed at would do
function View:light()
  local view = self.view
  --- @type MancalaState
  local state = view.state
  local seat = view.seat
  local lights = {}
  local text = ""

  local pointed = self.pointed
  if self.flash then
    for slot, color in pairs(self.flash) do
      lights[slot] = color
    end
  elseif pointed and self:playable(pointed) then
    local from = holeOf(seat, pointed)
    local last, again, taken = outcomeOf(state.holes, seat, from, state.lone)
    for _, hole in ipairs(sowing(state.holes, seat, from)) do
      lights[slotOf(hole, seat)] = PASSES
    end
    local landing = slotOf(last, seat)
    lights[landing] = again and AGAIN or (taken > 0 and TAKES or LANDS)
    if taken > 0 then
      lights[slotOf(acrossFrom(last), seat)] = TAKES
      text = L["mancala_preview_take"]:format(taken)
    elseif again then
      text = L["mancala_preview_again"]
    end
    lights[pointed] = POINTED
  elseif state.outcome then
    local winner = state.outcome.winner
    if winner ~= 0 then
      lights[slotOf(storeOf(winner), seat)] = WINNER
    end
  else
    -- Where the last move was made from, until the player's own turn
    local event = view.events and view.events[view.ply]
    if event and event.from and not view.canMove then
      lights[slotOf(event.from, seat)] = LAST
    end
  end
  for slot = 1, PITS do
    if not lights[slot] and self:playable(slot) then
      lights[slot] = PLAYABLE
    end
  end
  self.heaps:SetHighlights(lights)
  self.preview:SetText(text)
  self.preview:SetTextColor(unpack(text == L["mancala_preview_again"] and AGAIN_COLOR or private.Widgets.GOLD))
end

--- Plays a move out on the board: the seeds sown, what they take swept up, and at the end of the
--- game what is left
--- @param event MancalaEvent
function View:animate(event)
  local heaps, effects, seat = self.heaps, self.effects, self.view.seat
  local before = {}
  for hole = 1, HOLES do
    before[slotOf(hole, seat)] = event.before[hole]
  end
  heaps:Show(before)

  local stops = {}
  for index, hole in ipairs(event.stops) do
    stops[index] = slotOf(hole, seat)
  end
  local landed = heaps:Carry(slotOf(event.from, seat), stops)
  local store = slotOf(storeOf(event.seat), seat)
  local storeX, storeY = self:spotOf(store)
  local size = math.max(14, math.floor(heaps.unit * 0.32))
  local over = landed

  --- Lights slots up for a while, from a time into the move
  local function flash(slots, from, to)
    heaps:Then(from, function()
      self.flash = slots
      self:light()
    end)
    heaps:Then(to, function()
      if self.flash == slots then
        self.flash = nil
        self:light()
      end
    end)
  end

  if event.again then
    heaps:Then(landed, function()
      private.Widgets.PlaySound(AGAIN_SOUND)
    end)
    flash({ [store] = WENT_AGAIN }, landed, landed + AGAIN_LIT)
    effects:Float(L["mancala_again"], storeX, storeY, { color = AGAIN_COLOR, size = size, delay = landed })
  end
  local capture = event.capture
  if capture then
    local at = landed + TAKE_AFTER
    local swept = heaps:Gather(slotOf(capture.across, seat), store, { delay = at })
    over = math.max(swept, heaps:Gather(slotOf(capture.at, seat), store, { delay = at + 0.1, quiet = true }))
    effects:Float(L["mancala_took"]:format(capture.seeds), storeX, storeY, { size = size, delay = over })
    flash({ [slotOf(capture.at, seat)] = TAKING, [slotOf(capture.across, seat)] = TAKING, [store] = TAKING }, landed, over)
  end
  if event.sweeps then
    local at = over + SWEEP_AFTER
    for index, sweep in ipairs(event.sweeps) do
      -- One sound for the lot of them, they all go at once
      local options = { delay = at + (index - 1) * SWEEP_STAGGER, quiet = index > 1 }
      over = math.max(over, heaps:Gather(slotOf(sweep.from, seat), slotOf(sweep.to, seat), options))
    end
  end
  return over
end

--- @param view GameView
function View:Update(view)
  self.view = view
  --- @type MancalaState
  local state = view.state
  local heaps = self.heaps
  local seat = view.seat

  --- @type MancalaEvent?
  local event = view.played
  if view.changed then
    heaps:Stop()
    self.effects:Clear()
    self.flash = nil
  end
  local over = nil
  if event then
    over = self:animate(event)
    -- The pits that can be played light up once the seeds are all down
    heaps:Then(over, function()
      self:light()
    end)
  end
  local counts = {}
  for hole = 1, HOLES do
    counts[slotOf(hole, seat)] = state.holes[hole]
  end
  heaps:Show(counts)
  heaps:SetEnabled(view.canMove)

  -- A game the player has just won
  if event and state.outcome and state.outcome.winner == seat and (view.live or view.catching) then
    self.effects:Confetti(over)
  end

  local opponent = other(seat)
  self.names[1]:SetText(view.names[opponent] or "")
  self.names[2]:SetText(L["mancala_you"])
  local last = view.events and view.events[view.ply]
  local note = ""
  if last and last.from and last.seat ~= seat and not state.outcome then
    local name = view.names[last.seat] or ""
    if last.capture then
      note = L["mancala_captured"]:format(name, last.capture.seeds)
    elseif last.again then
      note = L["mancala_went_again"]:format(name)
    end
  end
  self.note:SetText(note)
  self:light()
end

--- @return boolean
function View:Busy()
  return self.heaps:Busy()
end

private.Games.Register({
  id = "mancala",
  name = L["game_mancala"],
  description = L["game_mancala_description"],
  genre = "strategy",
  icon = "Interface\\AddOns\\ForeverGames\\Images\\Icons\\mancala",
  version = 1,
  seats = 2,
  history = true,
  options = {
    {
      id = "seeds",
      name = L["mancala_option_seeds"],
      description = L["mancala_option_seeds_tip"],
      choices = { 3, 4, 5, 6 },
      default = 4,
    },
    { id = "lone", name = L["mancala_option_lone"], description = L["mancala_option_lone_tip"], default = false },
  },
  howto = {
    { heading = L["howto_goal"], text = L["mancala_howto_goal"] },
    { heading = L["howto_turn"], text = L["mancala_howto_turn"] },
    { heading = L["mancala_howto_again"], text = L["mancala_howto_again_text"] },
    {
      heading = L["mancala_howto_taking"],
      text = function(rules)
        return L[rules.lone and "mancala_howto_taking_lone" or "mancala_howto_taking_text"]
      end,
    },
    { heading = L["howto_end"], text = L["mancala_howto_end"] },
    { heading = L["howto_controls"], text = L["mancala_howto_controls"] },
  },
  newState = newState,
  turn = function(state)
    return state.turn
  end,
  validate = validate,
  apply = apply,
  moves = moves,
  result = function(state)
    return state.outcome
  end,
  tally = function(state)
    return { state.holes[storeOf(1)], state.holes[storeOf(2)] }
  end,
  computer = COMPUTER,
  createView = createView,
  -- Not the engine's business: for the tests and the view
  rules = { sowing = sowing, outcomeOf = outcomeOf, holeOf = holeOf, storeOf = storeOf, acrossFrom = acrossFrom },
})
