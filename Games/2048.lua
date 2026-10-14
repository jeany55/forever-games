--------------------------
--  2048
--------------------------
-- The sliding puzzle with the numbers, for one player. On a board of four by four squares lie
-- tiles worth 2, 4, 8 and so on, two of them to begin with. A move pushes all of them one way,
-- as far as they go: up, down, left or right. Two tiles worth the same that run into each other
-- become one worth both, and that is what the move scores. A tile is only made of two once in a
-- move: of four 2s in a row the outer two and the inner two become a 4 each, they don't all
-- become an 8, and of three it is the two nearest the edge they were pushed to that join. After
-- every move a new tile turns up on a square that is free, a 2 nine times in ten and a 4
-- otherwise. A move that wouldn't change anything isn't one.
--
-- The tile to make is 2048. Making it is not the end: the game notes that it was made and goes
-- on for as long as there is a move left, for whoever wants to see how far they get. It ends
-- when the board is full and no two tiles that are worth the same lie next to each other, won if
-- 2048 was made on the way and lost if not.
--
-- The board can also be three or five squares each way. On three there isn't the room for a
-- 2048, a tile of 1024 would need all nine squares to go exactly right, so there the tile to
-- make is 256.
--
-- The squares are numbered along the rows, from 1 in the top left corner, and the state keeps
-- what lies on each as a number, 0 for nothing. A move is the way the tiles are pushed: "u",
-- "d", "l" or "r".

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L

-- Which way a move pushes: across and down
local WAYS = { u = { 0, -1 }, d = { 0, 1 }, l = { -1, 0 }, r = { 1, 0 } }
local SIZES, USUAL_SIZE = { 3, 4, 5 }, 4
-- The tile to make, by how many squares the board has each way
local TARGETS = { [3] = 256, [4] = 2048, [5] = 2048 }
-- One new tile in this many is a 4
local FOUR_IN = 10
-- What the best a player ever did is kept under, with the size of the board after it
local SCORE_KEY, TILE_KEY = "score", "tile"

--- @class TwentyFortyEightState
--- @field size number How many squares the board has each way
--- @field cells number[] What the tile on each square is worth, 0 for none
--- @field score number Everything the tiles that were made are worth
--- @field moves number How many the player has made
--- @field best number What the biggest tile there ever was is worth
--- @field target number The tile to make
--- @field reached boolean It was made
--- @field over boolean There is no move left

--- @class TwentyFortyEightSlide
--- @field from number The square a tile was on
--- @field to number The square it went to, the same one if it stayed
--- @field value number What it was worth
--- @field merged boolean? It became one with another tile there

--- @class TwentyFortyEightEvent: MatchEvent
--- @field way string The move
--- @field slides TwentyFortyEightSlide[] Every tile that was on the board, moved or not
--- @field merges { at: number, value: number }[] The squares two tiles became one on, and what that one is worth
--- @field spawn { at: number, value: number } The tile that turned up afterwards
--- @field gained number What the move scored
--- @field reached boolean? This was the move that made the tile to make
--- @field over boolean? And after this one there is none left

-----------------------------
-- Rules
-----------------------------

-- The squares of every row or column, by size and way, from the edge the tiles are pushed to
local lineCache = {}

--- @param size number
--- @param way string
--- @return number[][]
local function linesOf(size, way)
  local key = size .. way
  local lines = lineCache[key]
  if lines then
    return lines
  end
  lines = {}
  local across, down = WAYS[way][1], WAYS[way][2]
  for index = 1, size do
    local line = {}
    for step = 1, size do
      -- Counted back from the edge: against the way the tiles go
      local column, row = index, index
      if across ~= 0 then
        column = across > 0 and size - step + 1 or step
      else
        row = down > 0 and size - step + 1 or step
      end
      line[step] = (row - 1) * size + column
    end
    lines[index] = line
  end
  lineCache[key] = lines
  return lines
end

--- Whether pushing the tiles one way would change anything: one of them has room to go, or
--- runs into another that is worth the same
--- @param state TwentyFortyEightState
--- @param way string
--- @return boolean
local function shifts(state, way)
  local cells = state.cells
  for _, line in ipairs(linesOf(state.size, way)) do
    local room, last = false, 0
    for _, square in ipairs(line) do
      local value = cells[square]
      if value == 0 then
        room = true
      elseif room or value == last then
        return true
      else
        last = value
      end
    end
  end
  return false
end

--- @param state TwentyFortyEightState
--- @return boolean Whether there is anything left to do
local function canMove(state)
  return shifts(state, "u") or shifts(state, "l") or shifts(state, "d") or shifts(state, "r")
end

--- Puts a new tile on a square that is free
--- @param state TwentyFortyEightState
--- @param random Random
--- @return { at: number, value: number }
local function spawn(state, random)
  local free = {}
  for square, value in ipairs(state.cells) do
    if value == 0 then
      free[#free + 1] = square
    end
  end
  local at = free[random:Roll(#free)]
  local value = random:Roll(FOUR_IN) == 1 and 4 or 2
  state.cells[at] = value
  state.best = math.max(state.best, value)
  return { at = at, value = value }
end

--- @param seats number
--- @param random Random
--- @param rules table<string, any>?
--- @return TwentyFortyEightState
local function newState(_, random, rules)
  local size = rules and rules.size or USUAL_SIZE
  --- @type TwentyFortyEightState
  local state = { size = size, cells = {}, score = 0, moves = 0, best = 0, target = TARGETS[size], reached = false, over = false }
  for square = 1, size * size do
    state.cells[square] = 0
  end
  spawn(state, random)
  spawn(state, random)
  return state
end

--- @param state TwentyFortyEightState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  if seat ~= 1 then
    return false, "not_your_turn"
  elseif not WAYS[move] or state.over or not shifts(state, move) then
    return false, "invalid_move"
  end
  return true
end

--- Every way the tiles can be pushed that changes something
--- @param state TwentyFortyEightState
--- @return string[]
local function moves(state)
  local list = {}
  for _, way in ipairs({ "u", "d", "l", "r" }) do
    if shifts(state, way) then
      list[#list + 1] = way
    end
  end
  return list
end

--- @param state TwentyFortyEightState
--- @param seat number
--- @param move string
--- @param random Random
--- @return TwentyFortyEightEvent
local function apply(state, _, move, random)
  local cells, after = state.cells, {}
  for square = 1, #cells do
    after[square] = 0
  end

  local slides, merges, gained = {}, {}, 0
  for _, line in ipairs(linesOf(state.size, move)) do
    -- How many squares of the line are taken so far, and the tile on the last of them if it
    -- can still be joined: one that was made in this move can't
    local taken, open = 0, nil
    for _, square in ipairs(line) do
      local value = cells[square]
      if value > 0 then
        if open and open.value == value then
          local at = line[taken]
          after[at] = value * 2
          open.merged = true
          slides[#slides + 1] = { from = square, to = at, value = value, merged = true }
          merges[#merges + 1] = { at = at, value = value * 2 }
          gained = gained + value * 2
          state.best = math.max(state.best, value * 2)
          open = nil
        else
          taken = taken + 1
          after[line[taken]] = value
          open = { from = square, to = line[taken], value = value }
          slides[#slides + 1] = open
        end
      end
    end
  end

  state.cells = after
  state.score = state.score + gained
  state.moves = state.moves + 1
  --- @type TwentyFortyEightEvent
  local event = { way = move, slides = slides, merges = merges, gained = gained, spawn = spawn(state, random) }
  if not state.reached and state.best >= state.target then
    state.reached, event.reached = true, true
  end
  if not canMove(state) then
    state.over, event.over = true, true
  end
  return event
end

--- @param state TwentyFortyEightState
--- @return { winner: number }?
local function result(state)
  if state.over then
    return { winner = state.reached and 1 or 0 }
  end
  return nil
end

-----------------------------
-- View
-----------------------------
-- The board in the middle, on a grid of tiles that slide (GUI/SlideGrid.lua): everything that
-- moves on it is the grid's doing, from what a move says happened. To its left what the game
-- keeps count of, to its right four arrows for whoever would rather click.
--
-- The tiles are pushed with the arrow keys or with W, A, S and D while the cursor is over the
-- game, by dragging across the board, or with the arrows next to it. A push that wouldn't move
-- anything makes the tiles lean that way and come back.
--
-- A move is shown as it was made, and one that is taken back is shown backwards: the new tile
-- goes away, the others slide back and those that had become one come apart again.

local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\2048\\"
local TRAY = { 0.17, 0.15, 0.13, 0.94 }
local SLOT = { 0.36, 0.32, 0.28 }
local INK_DARK, INK_LIGHT, INK_GOLD = { 0.36, 0.31, 0.27 }, { 1, 0.98, 0.95 }, { 1, 0.86, 0.35 }
-- How tiles look by what they are worth, from 2 up: their colour, the colour of the number on
-- them and how strong the light around them is. The first eleven are the ones the game is
-- known by, warm and brighter all the way to 2048. Past it they go on through the cold colours
-- to 131072, which is as far as a board of four by four can ever get
local LOOKS = {
  { color = { 0.93, 0.89, 0.85 }, ink = INK_DARK },
  { color = { 0.93, 0.87, 0.76 }, ink = INK_DARK },
  { color = { 0.95, 0.69, 0.47 }, ink = INK_LIGHT },
  { color = { 0.96, 0.58, 0.39 }, ink = INK_LIGHT },
  { color = { 0.96, 0.49, 0.37 }, ink = INK_LIGHT },
  { color = { 0.96, 0.37, 0.23 }, ink = INK_LIGHT },
  { color = { 0.93, 0.81, 0.45 }, ink = INK_LIGHT, glow = 0.14 },
  { color = { 0.93, 0.8, 0.38 }, ink = INK_LIGHT, glow = 0.2 },
  { color = { 0.93, 0.78, 0.31 }, ink = INK_LIGHT, glow = 0.26 },
  { color = { 0.93, 0.77, 0.25 }, ink = INK_LIGHT, glow = 0.32 },
  { color = { 0.93, 0.76, 0.18 }, ink = INK_LIGHT, glow = 0.42 },
  { color = { 0.36, 0.76, 0.5 }, ink = INK_LIGHT, glow = 0.3 },
  { color = { 0.2, 0.68, 0.66 }, ink = INK_LIGHT, glow = 0.3 },
  { color = { 0.25, 0.56, 0.88 }, ink = INK_LIGHT, glow = 0.32 },
  { color = { 0.42, 0.44, 0.9 }, ink = INK_LIGHT, glow = 0.34 },
  { color = { 0.62, 0.38, 0.86 }, ink = INK_LIGHT, glow = 0.36 },
  { color = { 0.82, 0.32, 0.68 }, ink = INK_LIGHT, glow = 0.38 },
}
-- And whatever a bigger board gets to after that
local LOOK_BEYOND = { color = { 0.2, 0.18, 0.17 }, ink = INK_GOLD, glow = 0.3 }

-- Room around everything, and how wide the strips either side of the board are at least and at most
local MARGIN, GUTTER_MIN, GUTTER_MAX = 8, 86, 150
-- The part of the board's side that lies between two tiles
local GAP = 0.024
local STAT_HEIGHT, STAT_GAP, STAT_WIDEST = 38, 6, 130
local ARROW_MIN, ARROW_MAX, ARROW_GAP = 22, 40, 2
-- The arrows in the order they are made, and how far the picture of one, which points right, is turned
local ARROWS = {
  { way = "u", turn = math.pi / 2 },
  { way = "l", turn = math.pi },
  { way = "r", turn = 0 },
  { way = "d", turn = -math.pi / 2 },
}
local KEYS = { UP = "u", DOWN = "d", LEFT = "l", RIGHT = "r", W = "u", S = "d", A = "l", D = "r" }
-- Seconds an arrow stays lit after the key that goes with it
local LIT = 0.14
local SLIDE_SOUND, MERGE_SOUND, BIG_SOUND = "cardSlide", "chipsCollide", "IG_ABILITY_ICON_DROP"
local REFUSE_SOUND, OVER_SOUND = "IG_MAINMENU_OPTION_CHECKBOX_OFF", "IG_QUEST_LOG_ABANDON_QUEST"
-- The fanfare, and what to play on a client that doesn't have it
local REACHED_SOUND, REACHED_SOUND_ELSE = "UI_EPICLOOT_TOAST", "IG_QUEST_LIST_COMPLETE"
-- A tile worth this much or more lands with more of a thud
local BIG = 256
-- Seconds from the last tile landing to the words that say the game is over
local OVER_AFTER = 0.45
local OVER_COLOR = { 0.92, 0.9, 0.86 }

--- @class TwentyFortyEightView: GameViewObject
--- @field stage Frame
--- @field grid SlideGrid
--- @field effects Effects
--- @field tray Frame What the board lies on
--- @field slots Texture[] The squares of the board, as many as were ever needed
--- @field score Frame
--- @field best Frame
--- @field tile Frame
--- @field arrows table<string, Button> By the move they make
--- @field hint FontString
--- @field size number How many squares each way the board is laid out for
--- @field view GameView? What was last asked for
--- @field latest TwentyFortyEightEvent? The move that led to what is shown, to show it backwards if it is taken back
local View = {}
View.__index = View

--- How a tile looks, for the grid
--- @param value number
--- @return string text, number[] color, number[] ink, number? glow
local function style(value)
  local look = LOOKS[math.floor(math.log(value) / math.log(2) + 0.5)] or LOOK_BEYOND
  return tostring(value), look.color, look.ink, look.glow
end

--- An arrow to click
--- @param parent Frame
--- @param turn number How far the picture is turned
--- @return Button button Lit(on) lights it up without it being pressed, Fit(size) says how big it is
local function newArrow(parent, turn)
  local Widgets = private.Widgets
  local button = Widgets.Panel(parent, "Button")
  local arrow = button:CreateTexture(nil, "ARTWORK")
  arrow:SetTexture(private.Tiles.ARROW)
  arrow:SetRotation(turn)
  button.usable = true

  local function look()
    local on = button.usable and (button.pressed or button.lit)
    if on then
      button:SetBackdropColor(1, 0.82, 0, 0.3)
    elseif button.usable and button.hovered then
      button:SetBackdropColor(1, 1, 1, 0.14)
    else
      button:SetBackdropColor(0, 0, 0, 0.4)
    end
    button:SetBackdropBorderColor(1, 1, 1, (button.usable and button.hovered) and 0.35 or 0.1)
    local bright = (on or (button.usable and button.hovered)) and 1 or 0.78
    arrow:SetVertexColor(bright, bright, bright, button.usable and 1 or 0.3)
    arrow:ClearAllPoints()
    arrow:SetPoint("CENTER", 0, (button.usable and button.pressed) and -1 or 0)
  end

  button:SetScript("OnEnter", function()
    button.hovered = true
    look()
  end)
  button:SetScript("OnLeave", function()
    button.hovered = false
    look()
  end)
  button:SetScript("OnMouseDown", function()
    button.pressed = true
    look()
  end)
  button:SetScript("OnMouseUp", function()
    button.pressed = false
    look()
  end)
  button:SetScript("OnHide", function()
    button.pressed, button.hovered, button.lit = false, false, false
    look()
  end)

  --- @param on boolean
  function button:Lit(on)
    self.lit = on
    look()
  end

  --- @param usable boolean Whether there is anything to push
  function button:Usable(usable)
    if self.usable ~= usable then
      self.usable = usable
      look()
    end
  end

  --- @param size number
  function button:Fit(size)
    self:SetSize(size, size)
    arrow:SetSize(size * 0.62, size * 0.62)
  end

  look()
  return button
end

--- @param stage Frame
--- @return TwentyFortyEightView
local function createView(stage)
  --- @type TwentyFortyEightView
  local self = setmetatable({ stage = stage, slots = {}, arrows = {}, size = USUAL_SIZE, width = 0, height = 0 }, View)
  local Widgets = private.Widgets

  -- Takes the keys while the cursor is anywhere over the game, and times what the view itself animates
  local keys = CreateFrame("Frame", nil, stage)
  keys:SetAllPoints()
  self.animator = Widgets.Animator(keys)
  Widgets.Keys(keys, function(key)
    local way = KEYS[key]
    if not way or not self:push(way) then
      return false
    end
    self:light(way)
    return true
  end)

  self.tray = Widgets.Panel(stage)
  self.tray:SetBackdropColor(unpack(TRAY))
  self.grid = private.SlideGrid.New(self.tray, { art = IMAGES, style = style })
  self.grid:Swipes(function(across, down)
    for way, towards in pairs(WAYS) do
      if towards[1] == across and towards[2] == down then
        self:push(way)
      end
    end
  end, function()
    -- A click on the board does nothing, so it says what would
    self:light()
  end)

  self.score = Widgets.Stat(stage, L["stat_score"], GUTTER_MIN - MARGIN, STAT_HEIGHT)
  self.best = Widgets.Stat(stage, L["stat_best"], GUTTER_MIN - MARGIN, STAT_HEIGHT)
  self.tile = Widgets.Stat(stage, L["2048_stat_tile"], GUTTER_MIN - MARGIN, STAT_HEIGHT)

  for _, made in ipairs(ARROWS) do
    local button = newArrow(stage, made.turn)
    button:SetScript("OnClick", function()
      self:push(made.way)
    end)
    self.arrows[made.way] = button
  end
  self.hint = stage:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  self.hint:SetJustifyH("CENTER")
  self.hint:SetText(L["2048_hint"])

  self.effects = private.Effects.New(stage)
  return self
end

--- Pushes the tiles one way, or says that they don't go
--- @param way string
--- @return boolean Whether there was a game to push them in
function View:push(way)
  local view = self.view
  if not view or not view.canMove then
    return false
  end
  if shifts(view.state, way) then
    view.submit(way)
  else
    self.grid:Nudge(WAYS[way][1], WAYS[way][2])
    private.Widgets.PlaySound(REFUSE_SOUND)
  end
  return true
end

--- Lights an arrow up for a moment: the one a key stands for, or all of them to say what there is
--- @param way string? All four if left out
function View:light(way)
  local lit = {}
  for name, button in pairs(self.arrows) do
    if not way or name == way then
      lit[#lit + 1] = button
      button:Lit(true)
    end
  end
  self.animator:Play(way and LIT or LIT * 3, function() end, {
    onDone = function()
      for _, button in ipairs(lit) do
        button:Lit(false)
      end
    end,
  })
end

--- Lays everything out for the room there is and the board the game is played on
function View:arrange()
  local width, height, size = self.width, self.height, self.size
  local stage, grid = self.stage, self.grid
  local gutter = math.max(GUTTER_MIN, math.min(GUTTER_MAX, math.floor(width * 0.18)))
  local room = math.floor(math.min(height - MARGIN * 2, width - (gutter + MARGIN) * 2))
  local gap = math.max(3, math.floor(room * GAP))
  local side = math.max(8, math.floor((room - gap * (size + 1)) / size))
  local board = side * size + gap * (size + 1)
  local left, top = math.floor((width - board) / 2), math.floor((height - board) / 2)

  self.tray:SetSize(board, board)
  self.tray:ClearAllPoints()
  self.tray:SetPoint("TOPLEFT", stage, "TOPLEFT", left, -top)
  grid:Arrange(size, size, side, gap)
  grid.frame:ClearAllPoints()
  grid.frame:SetPoint("TOPLEFT", self.tray, "TOPLEFT", gap, -gap)
  -- Where the grid begins on the stage, for what drifts up from a tile
  self.originX, self.originY = left + gap, top + gap

  for square = 1, math.max(size * size, #self.slots) do
    local slot = self.slots[square]
    if not slot then
      slot = self.tray:CreateTexture(nil, "ARTWORK")
      slot:SetTexture(private.Tiles.CELL)
      slot:SetVertexColor(unpack(SLOT))
      self.slots[square] = slot
    end
    slot:SetShown(square <= size * size)
    if square <= size * size then
      local x, y = grid:Center(square)
      slot:SetSize(side, side)
      slot:ClearAllPoints()
      slot:SetPoint("CENTER", grid.frame, "TOPLEFT", x, -y)
    end
  end

  -- What is kept count of, down the strip on the left
  local strip = left - MARGIN * 2
  for index, stat in ipairs({ self.score, self.best, self.tile }) do
    stat:SetSize(math.min(STAT_WIDEST, strip), STAT_HEIGHT)
    stat:ClearAllPoints()
    stat:SetPoint("TOP", stage, "TOPLEFT", math.floor(left / 2), -(top + (index - 1) * (STAT_HEIGHT + STAT_GAP)))
  end

  -- The arrows in a cross, in the middle of the strip on the right
  local arrow = math.max(ARROW_MIN, math.min(ARROW_MAX, math.floor(strip / 3) - ARROW_GAP))
  local pitch = arrow + ARROW_GAP
  local middleX, middleY = width - math.floor(left / 2), math.floor(height / 2)
  for way, button in pairs(self.arrows) do
    button:Fit(arrow)
    button:ClearAllPoints()
    button:SetPoint("CENTER", stage, "TOPLEFT", middleX + WAYS[way][1] * pitch, -(middleY + WAYS[way][2] * pitch))
  end
  self.hint:SetWidth(strip)
  self.hint:ClearAllPoints()
  self.hint:SetPoint("TOP", stage, "TOPLEFT", middleX, -(middleY + pitch * 1.5 + MARGIN))
end

--- @param width number
--- @param height number
function View:Layout(width, height)
  self.width, self.height = width, height
  -- The grid keeps its tiles, and has them where they belong at once
  self:arrange()
end

--- Says what the game keeps count of
function View:tally()
  local view = self.view
  --- @type TwentyFortyEightState
  local state = view.state
  local Widgets = private.Widgets
  self.score:Set(state.score)
  -- The best there was follows the score once it is beaten
  local best, mine = view.best(SCORE_KEY .. state.size)
  best = math.max(best or 0, state.score)
  self.best:Set(best > 0 and best or L["stat_none"])
  self.best:Tint((mine and best > 0) and Widgets.GOLD or nil)
  self.tile:Set(math.max(view.best(TILE_KEY .. state.size) or 0, state.best))
end

--- The game is over: says so across the board
--- @param after number? Seconds to wait first. At once for a game that was over before it was looked at
function View:finish(after)
  local view = self.view
  --- @type TwentyFortyEightState
  local state = view.state
  local best, mine = view.best(SCORE_KEY .. state.size)
  local words = L["2048_final"]:format(state.score)
  if mine and best == state.score and best > 0 then
    words = words .. "  " .. L["new_best"]
  end
  local color = state.reached and private.Widgets.GOLD or OVER_COLOR
  self.effects:Banner(L["2048_over"], words, { color = color, delay = after, instant = after == nil })
end

--- Shows a move being made
--- @param event TwentyFortyEightEvent
function View:play(event)
  local view = self.view
  --- @type TwentyFortyEightState
  local state = view.state
  local Widgets, grid, effects = private.Widgets, self.grid, self.effects
  local landed = grid:Animate({ moves = event.slides, merges = event.merges, appear = { event.spawn } }, state.cells)

  -- What the move scored drifts up from where it was made
  local biggest = 0
  for _, merge in ipairs(event.merges) do
    local x, y = grid:Center(merge.at)
    local size = math.max(11, math.floor(grid.side * 0.24))
    effects:Float("+" .. merge.value, self.originX + x, self.originY + y - grid.side * 0.3, { size = size, delay = landed })
    biggest = math.max(biggest, merge.value)
  end
  Widgets.PlaySound(biggest > 0 and MERGE_SOUND or SLIDE_SOUND)
  if biggest >= BIG then
    Widgets.PlaySound(BIG_SOUND)
  end

  if event.reached then
    -- Something to look at that is over by itself: the game goes on under it
    local middle = grid.frame:GetWidth() / 2
    local words, size = L["2048_reached"]:format(state.target), math.max(24, math.floor(grid.side * 0.7))
    effects:Confetti(landed)
    effects:Float(words, self.originX + middle, self.originY + middle, { size = size, delay = landed })
    Widgets.PlaySound(SOUNDKIT[REACHED_SOUND] and REACHED_SOUND or REACHED_SOUND_ELSE)
  end
  if event.over then
    Widgets.PlaySound(OVER_SOUND)
    self:finish(landed + OVER_AFTER)
  end
end

--- Shows a move being taken back: what it did, the other way round
--- @param event TwentyFortyEightEvent
function View:unplay(event)
  local back = {}
  for index, slide in ipairs(event.slides) do
    back[index] = { from = slide.to, to = slide.from, value = slide.value }
  end
  self.grid:Animate({ moves = back, vanish = { event.spawn.at } }, self.view.state.cells)
  private.Widgets.PlaySound(SLIDE_SOUND)
end

--- @param view GameView
function View:Update(view)
  local before = self.view
  self.view = view
  --- @type TwentyFortyEightState
  local state = view.state
  local sameGame = before ~= nil and before.match.id == view.match.id
  local taken, latest = sameGame and before.ply == view.ply + 1, self.latest
  --- @type TwentyFortyEightEvent?
  local event = view.played
  local shown = view.events[view.ply]
  self.latest = (shown and shown.slides) and shown or nil

  if state.size ~= self.size then
    self.size = state.size
    self:arrange()
  end

  if not sameGame then
    self.effects:Clear()
    self.grid:Set(state.cells)
  elseif view.changed then
    if self.effects:HasBanner() then
      self.effects:Clear()
    end
    if event and event.slides then
      self:play(event)
    elseif taken and latest then
      self:unplay(latest)
    else
      self.grid:Set(state.cells)
    end
  end

  self:tally()
  for _, button in pairs(self.arrows) do
    button:Usable(view.canMove)
  end
  -- A game that was over before it was looked at says so without making an entrance
  if state.over and not self.effects:HasBanner() then
    self:finish()
  end
end

private.Games.Register({
  id = "2048",
  name = L["game_2048"],
  description = L["game_2048_description"],
  genre = "solo",
  icon = "Interface\\AddOns\\ForeverGames\\Images\\Icons\\2048",
  version = 1,
  seats = 1,
  undo = true,
  options = {
    {
      id = "size",
      name = L["2048_option_size"],
      description = L["2048_option_size_tip"],
      choices = SIZES,
      default = USUAL_SIZE,
      label = function(value)
        return L["2048_option_size_label"]:format(value, value)
      end,
    },
  },
  newState = newState,
  turn = function()
    return 1
  end,
  validate = validate,
  apply = apply,
  moves = moves,
  result = result,
  progress = function(state)
    return L["2048_progress"]:format(state.score, state.best)
  end,
  record = function(state)
    return {
      { key = SCORE_KEY .. state.size, value = state.score },
      { key = TILE_KEY .. state.size, value = state.best },
    }
  end,
  createView = createView,
})
