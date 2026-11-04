--------------------------
--  Runeweave: what is seen and heard
--------------------------
-- The board of runes in the middle, the moves left, the level and the ley meter on its left, and
-- the score, the chain and a rival on its right. While the player may move, a rune can be clicked
-- and then one next to it, dragged onto its neighbour, or picked up with the keys and swapped
-- with an arrow. A swap that would line nothing up is shown going there and coming back, and
-- is never sent. Left alone for a while, the board shows a swap that would do something.
--
-- A swap is played out whole by the rules the moment it is made (Board.Play), and what came of
-- it is the move's event: the board before it and every step after, each with what was cleared
-- and made and set off and where every rune fell from. The view plays that back: the two runes
-- trade places, the lines flare and vanish with a chime a step higher the further down the
-- chain they came, bolts and novas go off, the runes above fall and new ones drop in, and so
-- on to the end, after which the ley meter surges if it is full. A position that wasn't just
-- played (looking back, or a game loaded again) is drawn as it is.

local _, private = ...
private.Runeweave = private.Runeweave or {}
local own = private.Runeweave
local engine = private
local L = engine.L
local Board = own.Board

local floor, min, max, abs, sin, pi = math.floor, math.min, math.max, math.abs, math.sin, math.pi

local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\Runeweave\\"
local SOUNDS = "Interface\\AddOns\\ForeverGames\\Sounds\\Runeweave\\"

local SIZE = Board.SIZE
local School, Kind = Board.School, Board.Kind
-- A square of the board, the board and what is round it, in units
local CELL = 64
local BOARD = CELL * SIZE
local PANEL, MARGIN = 150, 16
local WIDTH, HEIGHT = BOARD + 2 * PANEL, BOARD + 2 * MARGIN
-- How big a rune is drawn in its square
local RUNE = 60
-- Seconds: two runes trading places, a step's lines flaring and going, and how long a rune takes
-- to fall one row (it falls faster the further it falls, as a thing dropped does)
local SWAP, CLEAR, FALL_ROW = 0.16, 0.32, 0.075
-- A swap that does nothing: there and back
local BAD = 0.32
-- The board shuffled: the runes going and the new order coming
local SHUFFLE = 0.7
-- Seconds left alone before the board shows a swap
local HINT = 7
-- How far the cursor has to move with the button held to have dragged, as a fraction of a square
local DRAG = 0.4
-- How much faster everything is played while the player holds the button or Space
local HURRY = 2.5
-- Colours: the light of each school, and the writing
local LIGHTS = {
  { 1, 0.45, 0.15 },
  { 0.45, 0.8, 1 },
  { 0.45, 1, 0.35 },
  { 1, 0.4, 1 },
  { 1, 0.9, 0.4 },
  { 0.7, 0.45, 1 },
}
local PRISM_LIGHT = { 1, 1, 1 }
local GOLD = { 1, 0.84, 0.3 }
local PALE = { 0.8, 0.82, 0.95 }
local LEY = { 0.35, 0.85, 1 }
-- The keys
local STEPS = { LEFT = { 0, -1 }, RIGHT = { 0, 1 }, UP = { -1, 0 }, DOWN = { 1, 0 }, A = { 0, -1 }, D = { 0, 1 }, W = { -1, 0 }, S = { 1, 0 } }
local KEYS_PICK = { SPACE = true, ENTER = true }

--- 1234567 as "1,234,567"
--- @param value number
--- @return string
local function commas(value)
  local text = tostring(floor(value))
  local made
  repeat
    text, made = text:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
  until made == 0
  return text
end
own.commas = commas

local function play(name)
  if engine.SoundOn() then
    PlaySoundFile(SOUNDS .. name .. ".ogg", "SFX")
  end
end

local function ease(progress)
  return 1 - (1 - progress) * (1 - progress)
end

local function smooth(progress)
  return progress * progress * (3 - 2 * progress)
end

--- The middle of a square, in the board's units from its top left
local function middle(square)
  local row, column = Board.Place(square)
  return (column + 0.5) * CELL, (row + 0.5) * CELL
end

local function lightOf(value)
  local school = School(value)
  return school > 0 and LIGHTS[school] or PRISM_LIGHT
end

local View = {}
View.__index = View

-----------------------------
-- Building
-----------------------------

--- A picture on the board, from a pool that grows as more are needed
local function pool(self, name, layer, sublevel, file, additive)
  local list = { used = 0 }
  self.pools[name] = list
  return function()
    list.used = list.used + 1
    local texture = list[list.used]
    if not texture then
      texture = self.canvas:CreateTexture(nil, layer, nil, sublevel)
      texture:SetTexture(IMAGES .. file)
      if additive then
        texture:SetBlendMode("ADD")
      end
      list[list.used] = texture
    end
    texture:SetVertexColor(1, 1, 1)
    texture:SetAlpha(1)
    texture:SetRotation(0)
    texture:Show()
    return texture
  end, list
end

--- Hides every picture of a pool, to be used again
local function release(list)
  for index = 1, list.used do
    list[index]:Hide()
  end
  list.used = 0
end

local function label(parent, size, color, justify)
  local text = parent:CreateFontString(nil, "OVERLAY")
  text.size = size
  text:SetFont(STANDARD_TEXT_FONT, size, "OUTLINE")
  text:SetTextColor(unpack(color or PALE))
  text:SetJustifyH(justify or "CENTER")
  return text
end

--- @param stage Frame
function own.CreateView(stage)
  local self = setmetatable({ stage = stage, pools = {}, scale = 1, cursor = 1, idle = 0, clock = 0 }, View)
  local frame = CreateFrame("Frame", nil, stage)
  frame:SetPoint("CENTER")
  self.frame = frame

  local back = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
  back:SetAllPoints()
  back:SetColorTexture(0.04, 0.03, 0.07, 0.92)

  local board = CreateFrame("Frame", nil, frame)
  board:SetClipsChildren(true)
  board:EnableMouse(true)
  -- So that the tests can find it among the window's frames
  board.runeweaveBoard = true
  self.board = board
  local canvas = CreateFrame("Frame", nil, board)
  canvas:SetAllPoints()
  self.canvas = canvas
  self.slab = canvas:CreateTexture(nil, "BACKGROUND")
  self.slab:SetAllPoints()
  self.slab:SetTexture(IMAGES .. "board")
  -- A thin edge of ley light round the board
  self.edges = {}
  for index = 1, 4 do
    local edge = frame:CreateTexture(nil, "BORDER")
    edge:SetColorTexture(0.45, 0.75, 1, 0.5)
    self.edges[index] = edge
  end

  -- The pictures there are many of: the runes and the marks of their power over them, the light
  -- of the ones that are going, bursts, bolts and sparks
  self.newGlow, self.glows = pool(self, "glows", "ARTWORK", -2, "glow", true)
  self.newRune, self.runes = pool(self, "runes", "ARTWORK", 0, "rune1")
  self.newMark, self.marks = pool(self, "marks", "ARTWORK", 2, "charged", true)
  self.newBurst, self.bursts = pool(self, "bursts", "OVERLAY", 1, "ring", true)
  self.newBeam, self.beams = pool(self, "beams", "OVERLAY", 2, "beam", true)
  self.newSpark, self.sparks = pool(self, "sparks", "OVERLAY", 3, "spark", true)
  self.effectsLive = {}

  -- The rune picked up, the keys' cursor and the swap the board suggests
  self.picked = canvas:CreateTexture(nil, "ARTWORK", nil, -4)
  self.picked:SetTexture(IMAGES .. "select")
  self.picked:SetBlendMode("ADD")
  self.picked:Hide()
  self.keysCursor = canvas:CreateTexture(nil, "OVERLAY", nil, 0)
  self.keysCursor:SetTexture(IMAGES .. "select")
  self.keysCursor:SetVertexColor(0.6, 0.9, 1)
  self.keysCursor:Hide()
  self.hints = {}
  for index = 1, 2 do
    local hint = canvas:CreateTexture(nil, "ARTWORK", nil, -3)
    hint:SetTexture(IMAGES .. "glow")
    hint:SetBlendMode("ADD")
    hint:Hide()
    self.hints[index] = hint
  end

  -- The left panel: moves, level, the ley meter
  self.movesTitle = label(frame, 12, PALE)
  self.movesTitle:SetText(L["runeweave_moves"])
  self.moves = label(frame, 34, GOLD)
  self.levelTitle = label(frame, 12, PALE)
  self.levelTitle:SetText(L["runeweave_level"])
  self.level = label(frame, 26, LEY)
  self.leyTitle = label(frame, 12, PALE)
  self.leyTitle:SetText(L["runeweave_ley"])
  self.leyBack = frame:CreateTexture(nil, "ARTWORK", nil, 0)
  self.leyBack:SetColorTexture(0.08, 0.1, 0.18, 1)
  self.leyFill = frame:CreateTexture(nil, "ARTWORK", nil, 1)
  self.leyFill:SetTexture(IMAGES .. "ley")
  self.leyGlow = frame:CreateTexture(nil, "ARTWORK", nil, 2)
  self.leyGlow:SetTexture(IMAGES .. "glow")
  self.leyGlow:SetBlendMode("ADD")
  self.leyGlow:SetVertexColor(unpack(LEY))
  self.leyCount = label(frame, 11, PALE)

  -- The right panel: the score, the best, the chain, a rival
  self.scoreTitle = label(frame, 12, PALE)
  self.scoreTitle:SetText(L["runeweave_score"])
  self.score = label(frame, 24, GOLD)
  self.best = label(frame, 10, PALE)
  self.movePoints = label(frame, 16, { 1, 1, 1 })
  self.chain = label(frame, 18, { 0.55, 1, 0.85 })
  self.rival = label(frame, 10, { 1, 0.6, 0.6 })
  self.rival:SetWordWrap(true)

  self.effects = engine.Effects.New(frame)
  local animated = CreateFrame("Frame", nil, frame)
  self.animator = engine.Widgets.Animator(animated)

  local ticker = CreateFrame("Frame", nil, stage)
  ticker:SetAllPoints()
  self.ticker = ticker
  ticker:SetScript("OnUpdate", function(_, elapsed)
    self:OnFrame(elapsed)
  end)
  engine.Widgets.Keys(ticker, function(key)
    return self:KeyDown(key)
  end)
  ticker:SetScript("OnKeyUp", function(_, key)
    if KEYS_PICK[key] then
      self.held = false
    end
  end)
  board:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" then
      self:Press()
    end
  end)
  board:SetScript("OnMouseUp", function(_, button)
    if button == "LeftButton" then
      self:Release()
    end
  end)
  return self
end

-----------------------------
-- Layout
-----------------------------

--- Puts a picture with its middle at a place on the board, so big
function View:Put(texture, x, y, width, height)
  local s = self.scale
  texture:ClearAllPoints()
  texture:SetPoint("CENTER", self.board, "TOPLEFT", x * s, -y * s)
  texture:SetSize(width * s, (height or width) * s)
end

function View:Layout(width, height)
  local s = min(width / WIDTH, height / HEIGHT)
  self.scale = s
  local frame = self.frame
  frame:SetSize(WIDTH * s, HEIGHT * s)
  self.board:ClearAllPoints()
  self.board:SetPoint("TOPLEFT", frame, "TOPLEFT", PANEL * s, -MARGIN * s)
  self.board:SetSize(BOARD * s, BOARD * s)
  local e = self.edges
  local line = max(1, s)
  e[1]:SetPoint("TOPLEFT", self.board, "TOPLEFT", -line, line)
  e[1]:SetPoint("BOTTOMRIGHT", self.board, "BOTTOMLEFT", 0, -line)
  e[2]:SetPoint("TOPLEFT", self.board, "TOPRIGHT", 0, line)
  e[2]:SetPoint("BOTTOMRIGHT", self.board, "BOTTOMRIGHT", line, -line)
  e[3]:SetPoint("BOTTOMLEFT", self.board, "TOPLEFT", 0, 0)
  e[3]:SetPoint("TOPRIGHT", self.board, "TOPRIGHT", 0, line)
  e[4]:SetPoint("TOPLEFT", self.board, "BOTTOMLEFT", 0, 0)
  e[4]:SetPoint("BOTTOMRIGHT", self.board, "BOTTOMRIGHT", 0, -line)

  for _, text in ipairs({ self.movesTitle, self.moves, self.levelTitle, self.level, self.leyTitle, self.leyCount, self.scoreTitle, self.score, self.best, self.movePoints, self.chain, self.rival }) do
    text:SetFont(STANDARD_TEXT_FONT, max(6, text.size * s), "OUTLINE")
  end
  local left = PANEL / 2 * s
  self.movesTitle:SetPoint("TOP", frame, "TOPLEFT", left, -24 * s)
  self.moves:SetPoint("TOP", frame, "TOPLEFT", left, -42 * s)
  self.levelTitle:SetPoint("TOP", frame, "TOPLEFT", left, -100 * s)
  self.level:SetPoint("TOP", frame, "TOPLEFT", left, -118 * s)
  self.leyTitle:SetPoint("TOP", frame, "TOPLEFT", left, -170 * s)
  -- The ley meter stands up the left panel, filling from the bottom
  self.leyBottom, self.leyHeight = HEIGHT - 50, HEIGHT - 50 - 192
  self.leyBack:ClearAllPoints()
  self.leyBack:SetPoint("BOTTOM", frame, "TOPLEFT", left, -self.leyBottom * s)
  self.leyBack:SetSize(30 * s, self.leyHeight * s)
  self.leyCount:SetPoint("TOP", frame, "TOPLEFT", left, -(self.leyBottom + 10) * s)

  local right = (PANEL + BOARD + PANEL / 2) * s
  self.scoreTitle:SetPoint("TOP", frame, "TOPLEFT", right, -24 * s)
  self.score:SetPoint("TOP", frame, "TOPLEFT", right, -40 * s)
  self.best:SetPoint("TOP", frame, "TOPLEFT", right, -70 * s)
  self.movePoints:SetPoint("TOP", frame, "TOPLEFT", right, -110 * s)
  self.chain:SetPoint("TOP", frame, "TOPLEFT", right, -134 * s)
  self.rival:SetPoint("BOTTOM", frame, "BOTTOMLEFT", right, 24 * s)
  self.rival:SetWidth((PANEL - 16) * s)

  if self.state then
    if self.anim then
      self:Frame()
      self:DrawLey(self.shownLey or self.state.ley, self.shownLevel or self.state.level)
    else
      self:Draw()
    end
  end
end

-----------------------------
-- Drawing
-----------------------------

--- A rune at a place on the board, so big and as see-through as asked
--- @param value integer
--- @param x number
--- @param y number
--- @param size number? 1 for as big as a rune is
--- @param alpha number?
--- @param bright number? Light laid over it, from 0 to 1
function View:Rune(value, x, y, size, alpha, bright)
  if value == 0 then
    return
  end
  size = (size or 1) * RUNE
  alpha = alpha or 1
  local kind = Kind(value)
  local rune = self.newRune()
  rune:SetTexture(IMAGES .. (kind == Board.PRISM and "prism" or ("rune" .. School(value))))
  rune:SetAlpha(alpha)
  self:Put(rune, x, y, size)
  if kind == Board.ROW or kind == Board.COLUMN or kind == Board.NOVA then
    local mark = self.newMark()
    mark:SetTexture(IMAGES .. (kind == Board.NOVA and "nova" or "charged"))
    if kind == Board.COLUMN then
      mark:SetRotation(pi / 2)
    end
    local light = lightOf(value)
    local pulse = 0.75 + 0.25 * sin(self.clock * 5 + x * 0.05 + y * 0.03)
    mark:SetVertexColor(0.6 + light[1] * 0.4, 0.6 + light[2] * 0.4, 0.6 + light[3] * 0.4)
    mark:SetAlpha(alpha * pulse)
    self:Put(mark, x, y, size * 1.15)
  end
  if kind ~= Board.PLAIN or (bright and bright > 0) then
    local glow = self.newGlow()
    local light = lightOf(value)
    glow:SetVertexColor(light[1], light[2], light[3])
    local amount = bright or 0
    if kind == Board.PRISM then
      amount = max(amount, 0.45 + 0.2 * sin(self.clock * 3))
      local hue = self.clock * 1.5 + x * 0.01
      glow:SetVertexColor(0.7 + 0.3 * sin(hue), 0.7 + 0.3 * sin(hue + 2.1), 0.7 + 0.3 * sin(hue + 4.2))
    elseif kind ~= Board.PLAIN then
      amount = max(amount, 0.35)
    end
    glow:SetAlpha(alpha * amount)
    self:Put(glow, x, y, size * 1.7)
  end
end

--- Takes every rune off the board, to be drawn again
function View:Clear()
  release(self.runes)
  release(self.marks)
  release(self.glows)
end

--- A board at rest
--- @param board integer[]
function View:DrawBoard(board)
  self:Clear()
  for square = 1, Board.SQUARES do
    local x, y = middle(square)
    self:Rune(board[square], x, y)
  end
end

--- The ley meter with so many runes in it at a level
function View:DrawLey(ley, level)
  self.shownLey, self.shownLevel = ley, level
  local s = self.scale
  local need = own.Need(level)
  local full = min(1, ley / need)
  local left = PANEL / 2 * s
  self.leyFill:ClearAllPoints()
  self.leyFill:SetPoint("BOTTOM", self.frame, "TOPLEFT", left, -(self.leyBottom - 2) * s)
  local height = max(0.5, (self.leyHeight - 4) * full)
  self.leyFill:SetSize(26 * s, height * s)
  self.leyFill:SetTexCoord(0, 1, 1 - full, 1)
  self.leyFill:SetShown(full > 0)
  self.leyGlow:ClearAllPoints()
  self.leyGlow:SetPoint("CENTER", self.frame, "TOPLEFT", left, -(self.leyBottom - 2 - height) * s)
  self.leyGlow:SetSize(70 * s, 40 * s)
  self.leyGlow:SetShown(full > 0)
  self.leyCount:SetText(floor(min(ley, need)) .. " / " .. need)
  self.level:SetText(level)
end

--- The score, the best and a rival
function View:DrawScore(score)
  self.score:SetText(commas(score))
  local view = self.view
  local best = view and view.best and view.best("score")
  self.best:SetText(best and L["runeweave_best"]:format(commas(best)) or "")
  local race = view and view.race
  if not race then
    self.rival:SetText("")
    return
  end
  local text
  if race.theirs then
    text = L["runeweave_rival"]:format(race.rival, commas(race.theirs))
  elseif race.ghost then
    -- Where they were after as many moves
    local swaps, theirs = self.state.swaps, nil
    for _, sample in ipairs(race.ghost) do
      local n, value = sample:match("^(%d+)=(%d+)$")
      if n and tonumber(n) <= swaps then
        theirs = { tonumber(n), tonumber(value) }
      end
    end
    if theirs then
      text = L["runeweave_rival_after"]:format(race.rival, theirs[1], commas(theirs[2]))
    end
  end
  self.rival:SetText(text or race.rival)
end

--- Everything as the position has it, nothing moving
function View:Draw()
  local state = self.state
  self:DrawBoard(state.board)
  self.powers = false
  for square = 1, Board.SQUARES do
    self.powers = self.powers or Kind(state.board[square]) ~= Board.PLAIN
  end
  self.moves:SetText(state.moves)
  self:DrawLey(state.ley, state.level)
  self:DrawScore(state.score)
  self:DrawMarks()
end

--- The rune picked up, the keys' cursor and the swap suggested
function View:DrawMarks()
  local can = self:CanMove()
  if can and self.selected then
    local x, y = middle(self.selected)
    self:Put(self.picked, x, y, CELL + 6)
    self.picked:SetVertexColor(unpack(lightOf(self.state.board[self.selected])))
    self.picked:Show()
  else
    self.picked:Hide()
  end
  if can and self.usingKeys then
    local x, y = middle(self.cursor)
    self:Put(self.keysCursor, x, y, CELL + 2)
    self.keysCursor:Show()
  else
    self.keysCursor:Hide()
  end
  for index, hint in ipairs(self.hints) do
    local square = can and self.hint and self.hint[index]
    if square then
      local x, y = middle(square)
      self:Put(hint, x, y, CELL * 1.6)
      hint:SetVertexColor(1, 1, 0.85)
      hint:Show()
    else
      hint:Hide()
    end
  end
end

-----------------------------
-- Swapping
-----------------------------

--- Whether the player may swap now
function View:CanMove()
  local view = self.view
  return view ~= nil and view.canMove and view.live and not self.anim and not self.bad and not self.state.over
end

--- Something done by the player: the suggestion goes, and the clock towards the next starts again
function View:Stir()
  self.idle = 0
  if self.hint then
    self.hint = nil
    self:DrawMarks()
  end
end

--- The square under the cursor, and where on the board it is in units
function View:SquareAtCursor()
  local x, y = GetCursorPosition()
  local scale = self.board:GetEffectiveScale()
  local left, top = self.board:GetLeft(), self.board:GetTop()
  if not left or not top then
    return nil
  end
  local ux, uy = (x / scale - left) / self.scale, (top - y / scale) / self.scale
  local row, column = floor(uy / CELL), floor(ux / CELL)
  return Board.Square(row, column), ux, uy
end

--- Two squares side by side or one above the other
local function beside(a, b)
  local ra, ca = Board.Place(a)
  local rb, cb = Board.Place(b)
  return abs(ra - rb) + abs(ca - cb) == 1
end

--- Swaps two runes if that does something, and shows them going there and back if it doesn't
function View:Try(a, b)
  self.selected = nil
  local move = Board.Write(a, b)
  if move and Board.Works(self.state.board, a, b) then
    self.view.submit(move)
    return
  end
  play("bad")
  self.bad = { a = a, b = b, t = 0 }
  self:DrawMarks()
end

function View:Press()
  self:Stir()
  if self.anim then
    -- Held down while a swap is played, it hurries it along. Not the press that dragged the swap
    -- in, which is still held as it starts
    self.anim.hurry = true
    return
  end
  if not self:CanMove() then
    return
  end
  self.usingKeys = false
  local square, x, y = self:SquareAtCursor()
  if square then
    self.press = { square = square, x = x, y = y }
  end
end

function View:Release()
  local press = self.press
  self.press = nil
  if not press or press.dragged or not self:CanMove() then
    return
  end
  local square = press.square
  if self.selected and self.selected ~= square and beside(self.selected, square) then
    self:Try(self.selected, square)
  elseif self.selected == square then
    self.selected = nil
  else
    self.selected = square
    play("pick")
  end
  self:DrawMarks()
end

--- While the button is held: dragged far enough one way, the rune is swapped that way
function View:Drag()
  local press = self.press
  if not press or press.dragged then
    return
  end
  if not IsMouseButtonDown("LeftButton") then
    self.press = nil
    return
  end
  local _, x, y = self:SquareAtCursor()
  if not x then
    return
  end
  local dx, dy = x - press.x, y - press.y
  if max(abs(dx), abs(dy)) < CELL * DRAG then
    return
  end
  press.dragged = true
  local row, column = Board.Place(press.square)
  local other
  if abs(dx) >= abs(dy) then
    other = Board.Square(row, column + (dx > 0 and 1 or -1))
  else
    other = Board.Square(row + (dy > 0 and 1 or -1), column)
  end
  if other then
    self:Try(press.square, other)
  end
end

function View:KeyDown(key)
  if key == "ESCAPE" then
    -- Only kept from closing the window while a rune is picked up
    if self.selected then
      self.selected = nil
      self:DrawMarks()
      return true
    end
    return false
  end
  if KEYS_PICK[key] then
    self:Stir()
    if self:CanMove() then
      if not self.usingKeys then
        self.usingKeys = true
      elseif self.selected == self.cursor then
        self.selected = nil
      else
        self.selected = self.cursor
        play("pick")
      end
      self:DrawMarks()
    else
      self.held = true
    end
    return true
  end
  local way = STEPS[key]
  if not way or not self:CanMove() then
    return false
  end
  self:Stir()
  local row, column = Board.Place(self.cursor)
  local there = Board.Square(row + way[1], column + way[2])
  if self.selected and self.usingKeys then
    if there then
      self.cursor = there
      self:Try(self.selected, there)
    end
  else
    -- The first arrow shows the cursor where it was, the rest move it
    if self.usingKeys and there then
      self.cursor = there
    end
    self.usingKeys = true
  end
  self:DrawMarks()
  return true
end

-----------------------------
-- A swap played back
-----------------------------

--- A ring of light bursting out from a place on the board and fading
function View:Burst(x, y, size, color, seconds)
  self.effectsLive[#self.effectsLive + 1] = { kind = "burst", x = x, y = y, size = size, color = color, seconds = seconds or 0.45, t = 0 }
end

--- A bolt across a row or down a column, or sparks over the squares a prism cleared
function View:Bolt(bolt, cleared)
  local x, y = middle(bolt.square)
  local light = PRISM_LIGHT
  if bolt.kind == Board.ROW or bolt.kind == Board.COLUMN then
    play("bolt")
    light = LIGHTS[School(self.anim.board[bolt.square])] or LEY
    self.effectsLive[#self.effectsLive + 1] = { kind = "beam", x = x, y = y, across = bolt.kind == Board.ROW, color = light, seconds = 0.4, t = 0 }
  elseif bolt.kind == Board.NOVA then
    play("nova")
    light = LIGHTS[School(self.anim.board[bolt.square])] or GOLD
    self:Burst(x, y, CELL * 5.5, light, 0.5)
    self:Burst(x, y, CELL * 3, { 1, 1, 1 }, 0.35)
  else
    play("prism")
    self:Burst(x, y, CELL * 4, PRISM_LIGHT, 0.6)
    for square, why in pairs(cleared) do
      if why == "power" then
        local sx, sy = middle(square)
        self.effectsLive[#self.effectsLive + 1] = { kind = "spark", x = sx, y = sy, fromX = x, fromY = y, color = lightOf(self.anim.board[square]), seconds = 0.35, t = 0 }
      end
    end
    if bolt.school == nil then
      self.effects:Float(L["runeweave_unravel"], (PANEL + BOARD / 2) * self.scale, (MARGIN + BOARD / 2) * self.scale, { size = max(12, floor(26 * self.scale)), color = { 1, 0.9, 1 } })
    end
  end
end

--- Draws the bursts, bolts and sparks, and lets go of those that are over
function View:DrawEffects(elapsed)
  release(self.bursts)
  release(self.beams)
  release(self.sparks)
  local keep = {}
  for _, effect in ipairs(self.effectsLive) do
    effect.t = effect.t + elapsed
    local p = min(1, effect.t / effect.seconds)
    if p < 1 then
      keep[#keep + 1] = effect
    end
    local c = effect.color
    if effect.kind == "burst" then
      local burst = self.newBurst()
      burst:SetVertexColor(c[1], c[2], c[3])
      burst:SetAlpha(1 - p)
      self:Put(burst, effect.x, effect.y, effect.size * (0.3 + 0.7 * ease(p)))
    elseif effect.kind == "beam" then
      local beam = self.newBeam()
      beam:SetVertexColor(c[1], c[2], c[3])
      beam:SetAlpha((1 - p) * (1 - p))
      local reach = BOARD * 2 * min(1, p * 4)
      local thick = CELL * (1.1 - 0.6 * p)
      if effect.across then
        beam:SetTexture(IMAGES .. "beam")
        self:Put(beam, effect.x, effect.y, reach, thick)
      else
        beam:SetTexture(IMAGES .. "beamDown")
        self:Put(beam, effect.x, effect.y, thick, reach)
      end
    elseif effect.kind == "spark" then
      local spark = self.newSpark()
      local q = ease(p)
      spark:SetVertexColor(c[1], c[2], c[3])
      spark:SetAlpha(1 - p * 0.6)
      self:Put(spark, effect.fromX + (effect.x - effect.fromX) * q, effect.fromY + (effect.y - effect.fromY) * q, CELL * 0.7)
    end
  end
  self.effectsLive = keep
end

--- Starts playing back a swap that led to the position
--- @param made RuneweavePlay
function View:StartPlay(made)
  local state = self.state
  local surged = made.surges or 0
  self.anim = {
    play = made,
    phase = "swap",
    t = 0,
    step = 0,
    board = made.start,
    score = state.score - made.points,
    ley = made.ley or 0,
    level = made.level or state.level,
    count = 0,
  }
  self.selected = nil
  self.press = nil
  self.moves:SetText(state.moves - surged * own.SURGE_MOVES)
  self:DrawScore(self.anim.score)
  self:DrawLey(self.anim.ley, self.anim.level)
  self.movePoints:SetText("")
  self.chain:SetText("")
  self:DrawMarks()
  play("swap")
  self:Frame()
end

--- Moves on to the next step's lines, or to the end
function View:NextStep()
  local anim = self.anim
  local made = anim.play
  anim.step = anim.step + 1
  anim.t = 0
  local step = made.steps[anim.step]
  if not step then
    if made.shuffled and anim.phase ~= "shuffle" then
      anim.phase = "shuffle"
      play("shuffle")
      self.effects:Float(L["runeweave_shuffle"], (PANEL + BOARD / 2) * self.scale, (MARGIN + BOARD / 2) * self.scale, { size = max(10, floor(18 * self.scale)), color = PALE })
      return
    end
    self:Done()
    return
  end
  anim.phase = "clear"
  anim.board = step.before
  -- What went off and what it was worth, as it flares
  play("match" .. min(step.cascade, 8))
  for _, bolt in ipairs(step.bolts) do
    self:Bolt(bolt, step.cleared)
  end
  if #step.made > 0 then
    play("made")
  end
  for _, line in ipairs(step.lines) do
    local x, y = 0, 0
    for _, square in ipairs(line.cells) do
      local cx, cy = middle(square)
      x, y = x + cx, y + cy
    end
    x, y = x / #line.cells, y / #line.cells
    local light = lightOf(step.before[line.cells[1]])
    self.effects:Float(commas(line.points), (PANEL + x) * self.scale, (MARGIN + y) * self.scale, { size = max(9, floor((14 + min(10, step.cascade * 2)) * self.scale)), color = light })
  end
  for square in pairs(step.cleared) do
    local x, y = middle(square)
    self:Burst(x, y, CELL * 1.3, lightOf(step.before[square]), 0.35)
  end
  anim.score = anim.score + step.points
  anim.count = anim.count + step.count
  anim.points = (anim.points or 0) + step.points
  self:DrawScore(anim.score)
  self:DrawLey(min(anim.ley + anim.count, own.Need(anim.level)), anim.level)
  self.movePoints:SetText("+" .. commas(anim.points))
  self.chain:SetText(step.cascade > 1 and L["runeweave_chain"]:format(step.cascade) or "")
  if step.cascade > 2 then
    self.effects:Float(L["runeweave_chain"]:format(step.cascade), (PANEL + BOARD / 2) * self.scale, (MARGIN + BOARD * 0.3) * self.scale, { size = max(12, floor((18 + step.cascade * 2) * self.scale)), color = { 0.55, 1, 0.85 } })
  end
end

--- How long the runes of a step take to fall, the furthest of them
local function fallTime(step)
  local longest = 0
  for square = 1, Board.SQUARES do
    local row = Board.Place(square)
    longest = max(longest, row - step.from[square])
  end
  return longest > 0 and FALL_ROW * math.sqrt(longest) * 2.2 or 0
end

--- The runes where they are now, as far as the play has got
function View:Frame()
  local anim = self.anim
  local made = anim.play
  self:Clear()
  if anim.phase == "swap" then
    local p = smooth(min(1, anim.t / SWAP))
    local ax, ay = middle(made.a)
    local bx, by = middle(made.b)
    for square = 1, Board.SQUARES do
      if square ~= made.a and square ~= made.b then
        local x, y = middle(square)
        self:Rune(made.start[square], x, y)
      end
    end
    self:Rune(made.start[made.a], ax + (bx - ax) * p, ay + (by - ay) * p, 1 + 0.12 * sin(p * pi))
    self:Rune(made.start[made.b], bx + (ax - bx) * p, by + (ay - by) * p, 1 - 0.08 * sin(p * pi))
  elseif anim.phase == "clear" then
    local step = made.steps[anim.step]
    local p = min(1, anim.t / CLEAR)
    local new = {}
    for _, rune in ipairs(step.made) do
      new[rune.square] = rune.value
    end
    for square = 1, Board.SQUARES do
      local x, y = middle(square)
      local value = step.before[square]
      if new[square] then
        -- The rune of power that takes its place, swelling into it
        if p < 0.45 then
          self:Rune(value, x, y, 1 + 0.2 * sin(p / 0.45 * pi), 1, p / 0.45)
        else
          local q = (p - 0.45) / 0.55
          self:Rune(new[square], x, y, 0.7 + 0.3 * ease(q) + 0.15 * sin(q * pi), 1, 1 - q)
        end
      elseif step.cleared[square] then
        if p < 0.4 then
          self:Rune(value, x, y, 1 + 0.18 * sin(p / 0.4 * pi * 0.5), 1, p / 0.4)
        else
          local q = (p - 0.4) / 0.6
          self:Rune(value, x, y, 1.18 * (1 - q), 1 - q * q, 1)
        end
      else
        self:Rune(value, x, y)
      end
    end
  elseif anim.phase == "fall" then
    local step = made.steps[anim.step]
    for square = 1, Board.SQUARES do
      local row, column = Board.Place(square)
      local from = step.from[square]
      local drop = row - from
      local y
      if drop > 0 then
        local seconds = FALL_ROW * math.sqrt(drop) * 2.2
        local q = min(1, anim.t / seconds)
        y = (from + (row - from) * q * q + 0.5) * CELL
      else
        y = (row + 0.5) * CELL
      end
      -- A little bounce as it lands
      local land = drop > 0 and anim.t > FALL_ROW * math.sqrt(drop) * 2.2 and min(1, (anim.t - FALL_ROW * math.sqrt(drop) * 2.2) / 0.12) or 1
      local squash = 1 - 0.08 * sin(land * pi)
      self:Rune(step.after[square], (column + 0.5) * CELL, y, squash)
    end
  elseif anim.phase == "shuffle" then
    local p = min(1, anim.t / SHUFFLE)
    local last = made.steps[#made.steps]
    local before = last and last.after or made.start
    for square = 1, Board.SQUARES do
      local x, y = middle(square)
      if p < 0.5 then
        local q = p / 0.5
        self:Rune(before[square], x, y, 1 - smooth(q), 1, q)
      else
        local q = (p - 0.5) / 0.5
        self:Rune(made.shuffled[square], x, y, smooth(q), 1, 1 - q)
      end
    end
  end
end

--- Moves a play on by a frame
function View:Advance(elapsed)
  local anim = self.anim
  local hurry = (self.held or (anim.hurry and IsMouseButtonDown("LeftButton"))) and HURRY or 1
  anim.t = anim.t + elapsed * hurry
  local made = anim.play
  if anim.phase == "swap" and anim.t >= SWAP then
    self:NextStep()
  elseif anim.phase == "clear" and anim.t >= CLEAR then
    local step = made.steps[anim.step]
    anim.phase = "fall"
    anim.t = 0
    anim.fall = fallTime(step)
  elseif anim.phase == "fall" and anim.t >= anim.fall + 0.12 then
    play("land")
    self:NextStep()
  elseif anim.phase == "shuffle" and anim.t >= SHUFFLE then
    self:Done()
  end
  if self.anim then
    self:Frame()
  end
end

--- The play is over: the ley meter surges if it filled, and the position is drawn as it is
function View:Done()
  local anim = self.anim
  local made = anim.play
  local state = self.state
  self.anim = nil
  self:Draw()
  self.movePoints:SetText(made.points > 0 and ("+" .. commas(made.points)) or "")
  if (made.surges or 0) > 0 then
    play("surge")
    local extra = made.surges * own.SURGE_MOVES
    self.effects:Float(L["runeweave_surge"]:format(extra), (PANEL / 2) * self.scale, 80 * self.scale, { size = max(10, floor(16 * self.scale)), color = LEY })
    self.effects:Float(L["runeweave_level_up"]:format(state.level), (PANEL + BOARD / 2) * self.scale, (MARGIN + BOARD / 2) * self.scale, { size = max(14, floor(30 * self.scale)), color = LEY })
    self.effects:Flash({ 0.3, 0.7, 1 }, 0.4)
    -- The meter empties down to what was left over
    local from = own.Need(made.level or 1)
    self.animator:Play(0.5, function(progress)
      if not self.anim then
        local level = progress < 0.5 and (made.level or 1) or state.level
        local value = progress < 0.5 and from * (1 - progress * 2) or state.ley * (progress - 0.5) * 2
        self:DrawLey(value, level)
      end
    end, {
      onDone = function()
        if not self.anim then
          self:DrawLey(state.ley, state.level)
        end
      end,
    })
  end
  self:Ended(true)
end

--- The game over, said once it is
--- @param now boolean? It ended just now, rather than before it was looked at
function View:Ended(now)
  local state = self.state
  if not state.over then
    return
  end
  if now then
    play("over")
    local _, set = self.view.best and self.view.best("score")
    if set then
      self.effects:Confetti()
    end
  end
  self.effects:Banner(L["runeweave_over"], L["runeweave_over_text"]:format(commas(state.score), state.level), { instant = not now, delay = now and 0.4 or nil })
end

-----------------------------
-- Every frame
-----------------------------

function View:OnFrame(elapsed)
  if not self.state then
    return
  end
  self.clock = self.clock + elapsed
  if self.anim then
    self:Advance(elapsed)
  elseif self.bad then
    -- There and back
    local bad = self.bad
    bad.t = bad.t + elapsed
    local p = min(1, bad.t / BAD)
    local reach = p < 0.5 and smooth(p * 2) * 0.45 or smooth((1 - p) * 2) * 0.45
    local ax, ay = middle(bad.a)
    local bx, by = middle(bad.b)
    local board = self.state.board
    self:Clear()
    for square = 1, Board.SQUARES do
      if square ~= bad.a and square ~= bad.b then
        local x, y = middle(square)
        self:Rune(board[square], x, y)
      end
    end
    self:Rune(board[bad.a], ax + (bx - ax) * reach, ay + (by - ay) * reach)
    self:Rune(board[bad.b], bx + (ax - bx) * reach, by + (ay - by) * reach)
    if p >= 1 then
      self.bad = nil
      self:Draw()
    end
  else
    if self.press then
      self:Drag()
    end
    if self:CanMove() then
      self.idle = self.idle + elapsed
      if self.idle >= HINT and not self.hint then
        local list = Board.Moves(self.state.board)
        if #list > 0 then
          local a, b = Board.Swap(list[self.state.swaps % #list + 1])
          self.hint = { a, b }
          self:DrawMarks()
        end
      end
    end
    -- The runes of power shimmer, so a board with any is drawn again now and then
    self.shimmer = (self.shimmer or 0) + elapsed
    if self.shimmer > 0.05 and self.powers then
      self.shimmer = 0
      self:DrawBoard(self.state.board)
    end
  end
  self:DrawEffects(elapsed)
  local pulse = 0.55 + 0.45 * sin(self.clock * 4)
  for _, hint in ipairs(self.hints) do
    hint:SetAlpha(pulse * 0.8)
  end
  self.picked:SetAlpha(0.7 + 0.3 * sin(self.clock * 6))
  self.leyGlow:SetAlpha(0.6 + 0.4 * sin(self.clock * 2.5))
end

function View:Busy()
  return self.anim ~= nil
end

function View:Update(view)
  self.view = view
  local state = view.state
  local key = view.match.id .. ":" .. view.ply
  local played = view.played
  if key == self.shown then
    -- Nothing new: only whether the player may swap
    if not self.anim then
      self:DrawMarks()
    end
    return
  end
  self.shown = key
  if self.anim then
    self.anim = nil
  end
  self.animator:Stop()
  self.bad = nil
  self.hint = nil
  self.idle = 0
  self.effectsLive = {}
  self.effects:Clear()
  self.selected = nil
  -- The rules' own table is the engine's: the view keeps a copy
  self.state = engine.Tables.Copy(state)
  if played and played.steps and played.start then
    if view.sample and view.live then
      view.sample(state.swaps .. "=" .. state.score)
    end
    self:StartPlay(played)
  else
    self:Draw()
    self:Ended(false)
  end
end
