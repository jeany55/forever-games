--------------------------
--  Number grid
--------------------------
-- A grid of squares to write figures into, for puzzles that are solved with a pencil: thin
-- lines between the squares and heavy ones between the boxes they are grouped in, a figure in
-- a square or a handful of small ones pencilled into it instead, squares washed in a colour to
-- point them out, and a frame around the one the player is on. It draws at whatever size it is
-- given.
--
-- The grid knows nothing about any puzzle. A game hands it what to write where and in which
-- colour, is told which square was clicked, and asks for a figure to pop into its square, for a
-- square to shake its head, or for squares to light up one after the other. Whatever is on the
-- move is only ever how the grid is drawn meanwhile: what it holds is always what it was last
-- told, and Settle puts it all there at once.
--
-- Squares are numbered row by row from the top left, starting at 1, the way a page is read.
--
-- With it come the keys to write with (NumberGrid.Key, NumberGrid.Pad): a pad of figures, each
-- of which can say something small about itself and be dimmed, and a row of tools under them,
-- which can be on or off. See Games/Sudoku.lua.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local Widgets = private.Widgets

--- @class NumberGridOptions
--- @field columns number
--- @field rows number
--- @field boxColumns number? How many squares wide a box is, the whole grid if left out
--- @field boxRows number?
--- @field noteColumns number? How many of the small figures go next to each other in a square, 3 if left out
--- @field paper number[]? Colour of the squares
--- @field paperOther number[]? Colour of the squares of every other box, to tell the boxes apart. The same as the rest if left out
--- @field line number[]? Colour of the lines between squares
--- @field heavy number[]? Colour of the lines between boxes, and around it all
--- @field cursor number[]? Colour of the frame around the square the player is on
--- @field note number[]? Colour of the small figures
--- @field strong number[]? Colour of the small figures that are pointed out, see SetNotes

--- @class NumberGridInput
--- @field onClick fun(square: number, button: string)? The player pressed a mouse button on a square
--- @field onHover fun(square: number?)? The cursor came onto this square, or with nil left the grid

--- @class NumberGridSquare
--- @field x number Where it is drawn: the distance of its top left corner from the grid's, right and down
--- @field y number
--- @field paper Texture
--- @field tint Texture Shown while the square is washed in a colour
--- @field holder Frame Carries the figure, so it can grow, shrink and be shaken
--- @field figure FontString
--- @field notes table<number, FontString> The small figures, made as they are needed, by where they sit
--- @field flash Texture? Lights the square up, made when it first is
--- @field scale number How large the figure is drawn right now, 1 when it is at rest
--- @field dx number How far aside it is drawn right now

--- @class NumberGrid
--- @field frame Frame
--- @field cell number Side of a square
--- @field squares NumberGridSquare[]
--- @field selected number? The square the cursor frame is around
--- @field enabled boolean Whether it takes clicks, see SetEnabled
local NumberGrid = {}
NumberGrid.__index = NumberGrid
private.NumberGrid = NumberGrid

local PAPER = { 0.1, 0.11, 0.14, 1 }
local LINE = { 0.32, 0.34, 0.4, 1 }
local HEAVY = { 0.62, 0.64, 0.7, 1 }
local CURSOR = { 1, 0.82, 0, 1 }
local NOTE = { 0.62, 0.64, 0.7 }
local STRONG = { 1, 0.82, 0 }
local WHITE = { 1, 1, 1 }
-- A figure and a small one, as fractions of the square
local FIGURE_SCALE, NOTE_SCALE = 0.62, 0.27
local SMALLEST_FONT = 7
-- Seconds a figure takes to pop into its square, and how small it starts out
local POP, POP_FROM = 0.24, 0.3
-- Seconds a square shakes for, how often it goes to and fro, and how far, as a fraction of it
local SHAKE, SHAKES, SHAKE_REACH = 0.42, 3, 0.12
-- Seconds a square is lit up for, and how much larger its figure gets meanwhile
local FLASH, FLASH_SWELL = 0.45, 0.22

--- @param parent Frame
--- @param options NumberGridOptions
--- @return NumberGrid
function NumberGrid.New(parent, options)
  --- @type NumberGrid
  local self = setmetatable({}, NumberGrid)
  self.columns, self.rows = options.columns, options.rows
  self.boxColumns, self.boxRows = options.boxColumns or options.columns, options.boxRows or options.rows
  self.noteColumns = options.noteColumns or 3
  self.noteColor, self.strongColor = options.note or NOTE, options.strong or STRONG
  self.cell, self.thin, self.thick = 0, 1, 2
  self.figures, self.inks, self.noted, self.tints = {}, {}, {}, {}
  self.squares = {}
  self.enabled = true

  local frame = CreateFrame("Frame", nil, parent)
  frame:EnableMouse(true)
  frame.numberGrid = self
  self.frame = frame

  -- The heavy lines are what shows of the grid between its boxes, the thin ones what shows of
  -- a box between its squares
  local heavy = frame:CreateTexture(nil, "BACKGROUND", nil, -3)
  heavy:SetAllPoints()
  heavy:SetColorTexture(unpack(options.heavy or HEAVY))
  self.boxes = {}
  for index = 1, (self.columns / self.boxColumns) * (self.rows / self.boxRows) do
    self.boxes[index] = frame:CreateTexture(nil, "BACKGROUND", nil, -2)
    self.boxes[index]:SetColorTexture(unpack(options.line or LINE))
  end

  local paper, paperOther = options.paper or PAPER, options.paperOther or options.paper or PAPER
  for square = 1, self.columns * self.rows do
    local column, row = (square - 1) % self.columns, math.floor((square - 1) / self.columns)
    local other = (math.floor(column / self.boxColumns) + math.floor(row / self.boxRows)) % 2 == 1
    --- @type NumberGridSquare
    local parts = { x = 0, y = 0, notes = {}, scale = 1, dx = 0 }
    parts.paper = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
    parts.paper:SetColorTexture(unpack(other and paperOther or paper))
    parts.tint = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
    parts.tint:Hide()
    parts.holder = CreateFrame("Frame", nil, frame)
    parts.figure = parts.holder:CreateFontString(nil, "OVERLAY")
    -- Nothing can be written without a font, whatever size the grid turns out to be
    parts.figure:SetFont(STANDARD_TEXT_FONT, SMALLEST_FONT, "")
    parts.figure:SetPoint("CENTER")
    self.squares[square] = parts
  end

  self.hover = frame:CreateTexture(nil, "BORDER", nil, 1)
  self.hover:SetColorTexture(1, 1, 1, 0.08)
  self.hover:Hide()
  self.press = frame:CreateTexture(nil, "BORDER", nil, 2)
  self.press:SetColorTexture(1, 1, 1, 0.14)
  self.press:Hide()
  -- The frame around the square the player is on: four edges of it
  self.cursorEdges = {}
  for index = 1, 4 do
    self.cursorEdges[index] = frame:CreateTexture(nil, "OVERLAY")
    self.cursorEdges[index]:SetColorTexture(unpack(options.cursor or CURSOR))
    self.cursorEdges[index]:Hide()
  end

  -- Whatever is on the move is run by a frame of its own: the grid's is busy watching the cursor
  self.motion = CreateFrame("Frame", nil, frame)
  self.motion:SetAllPoints()
  self.animator = Widgets.Animator(self.motion)
  self.motion:SetScript("OnHide", function()
    self.animator:Stop()
  end)

  frame:SetScript("OnMouseDown", function(_, button)
    local square = self.enabled and self:SquareAt(self:pointer()) or nil
    if square and self.input and self.input.onClick then
      self:place(self.press, square)
      self.press:Show()
      self.input.onClick(square, button)
    end
  end)
  frame:SetScript("OnMouseUp", function()
    self.press:Hide()
  end)
  frame:SetScript("OnUpdate", function()
    self:watch()
  end)
  frame:SetScript("OnHide", function()
    self.press:Hide()
    self:leave()
  end)
  return self
end

-----------------------------
-- Geometry
-----------------------------

--- How far along a square starts: the squares before it, and the lines between them
--- @param index number How many squares come before it in its row or column
--- @param box number How many squares a box is across that way
--- @return number
function NumberGrid:along(index, box)
  local heavy = math.floor(index / box)
  return self.thick + index * self.cell + heavy * self.thick + (index - heavy) * self.thin
end

--- The square at a point measured from the grid's top left corner, nil on a line or outside it
--- @param x number
--- @param y number
--- @return number?
function NumberGrid:SquareAt(x, y)
  if self.cell <= 0 then
    return nil
  end
  for square, parts in ipairs(self.squares) do
    if x >= parts.x and x < parts.x + self.cell and y >= parts.y and y < parts.y + self.cell then
      return square
    end
  end
  return nil
end

--- Where the middle of a square is, measured from the grid's top left corner
--- @param square number
--- @return number x, number y
function NumberGrid:CenterOf(square)
  local parts = self.squares[square]
  return parts.x + self.cell / 2, parts.y + self.cell / 2
end

--- Where the cursor is, measured from the grid's top left corner
--- @return number x, number y
function NumberGrid:pointer()
  local scale = self.frame:GetEffectiveScale()
  local x, y = GetCursorPosition()
  return x / scale - (self.frame:GetLeft() or 0), (self.frame:GetTop() or 0) - y / scale
end

--- Lays a texture over a square
--- @param texture Texture
--- @param square number
function NumberGrid:place(texture, square)
  local parts = self.squares[square]
  texture:ClearAllPoints()
  texture:SetPoint("TOPLEFT", self.frame, "TOPLEFT", parts.x, -parts.y)
  texture:SetSize(self.cell, self.cell)
end

--- Puts the figure of a square where it is right now: at rest in the middle of it, or wherever
--- what is being done to it has it
--- @param square number
function NumberGrid:pose(square)
  local parts = self.squares[square]
  local scale = parts.scale
  parts.holder:SetScale(scale)
  parts.holder:ClearAllPoints()
  -- A frame measures where it is by its own scale
  local x, y = parts.x + self.cell / 2 + parts.dx, parts.y + self.cell / 2
  parts.holder:SetPoint("CENTER", self.frame, "TOPLEFT", x / scale, -y / scale)
end

--- Puts the small figures of a square where they belong in it
--- @param square number
function NumberGrid:arrangeNotes(square)
  local parts = self.squares[square]
  local across = self.noteColumns
  local step = self.cell / across
  local size = math.max(SMALLEST_FONT, math.floor(self.cell * NOTE_SCALE))
  for index, note in pairs(parts.notes) do
    local column, row = (index - 1) % across, math.floor((index - 1) / across)
    note:SetFont(STANDARD_TEXT_FONT, size, "")
    note:ClearAllPoints()
    note:SetPoint("CENTER", self.frame, "TOPLEFT", parts.x + (column + 0.5) * step, -(parts.y + (row + 0.5) * step))
  end
end

function NumberGrid:arrange()
  local cell = self.cell
  local size = math.max(SMALLEST_FONT, math.floor(cell * FIGURE_SCALE))
  for square, parts in ipairs(self.squares) do
    local column, row = (square - 1) % self.columns, math.floor((square - 1) / self.columns)
    parts.x, parts.y = self:along(column, self.boxColumns), self:along(row, self.boxRows)
    self:place(parts.paper, square)
    self:place(parts.tint, square)
    if parts.flash then
      self:place(parts.flash, square)
    end
    parts.holder:SetSize(cell, cell)
    parts.figure:SetFont(STANDARD_TEXT_FONT, size, "")
    self:pose(square)
    self:arrangeNotes(square)
  end

  local across = self.columns / self.boxColumns
  for index, box in ipairs(self.boxes) do
    local column, row = (index - 1) % across * self.boxColumns, math.floor((index - 1) / across) * self.boxRows
    box:ClearAllPoints()
    box:SetPoint("TOPLEFT", self.frame, "TOPLEFT", self:along(column, self.boxColumns), -self:along(row, self.boxRows))
    box:SetSize(self.boxColumns * cell + (self.boxColumns - 1) * self.thin, self.boxRows * cell + (self.boxRows - 1) * self.thin)
  end
  self:placeCursor()
end

--- Puts the frame around the square the player is on
function NumberGrid:placeCursor()
  local parts = self.selected and self.squares[self.selected]
  for _, edge in ipairs(self.cursorEdges) do
    edge:SetShown(parts ~= nil)
  end
  if not parts then
    return
  end
  local cell, weight = self.cell, math.max(2, self.thick)
  local top, bottom, left, right = unpack(self.cursorEdges)
  for _, edge in ipairs(self.cursorEdges) do
    edge:ClearAllPoints()
  end
  top:SetPoint("TOPLEFT", self.frame, "TOPLEFT", parts.x, -parts.y)
  top:SetSize(cell, weight)
  bottom:SetPoint("TOPLEFT", self.frame, "TOPLEFT", parts.x, -(parts.y + cell - weight))
  bottom:SetSize(cell, weight)
  left:SetPoint("TOPLEFT", self.frame, "TOPLEFT", parts.x, -parts.y)
  left:SetSize(weight, cell)
  right:SetPoint("TOPLEFT", self.frame, "TOPLEFT", parts.x + cell - weight, -parts.y)
  right:SetSize(weight, cell)
end

-----------------------------
-- Public
-----------------------------

--- Fits the grid into this much room. Squares and lines are a whole number of units, so the
--- grid can come out a little smaller: read the result from grid.cell and the size of its frame.
--- @param width number
--- @param height number? As high as wide if left out
function NumberGrid:SetSize(width, height)
  height = height or width
  local roughly = math.min(width / self.columns, height / self.rows)
  local thin = math.max(1, math.floor(roughly / 45))
  local thick = thin + math.max(1, math.floor(roughly / 22))
  --- @param squares number
  --- @param box number
  --- @return number What the lines take up along one side
  local function lines(squares, box)
    local boxes = squares / box
    return (boxes + 1) * thick + (squares - boxes) * thin
  end
  local across, down = lines(self.columns, self.boxColumns), lines(self.rows, self.boxRows)
  local cell = math.max(1, math.floor(math.min((width - across) / self.columns, (height - down) / self.rows)))
  if cell == self.cell and thin == self.thin and thick == self.thick then
    return
  end
  self.cell, self.thin, self.thick = cell, thin, thick
  self.frame:SetSize(cell * self.columns + across, cell * self.rows + down)
  self:arrange()
end

--- @param input NumberGridInput
function NumberGrid:SetInput(input)
  self.input = input
end

--- Whether the player can do anything on the grid right now. One they can't doesn't take
--- clicks and doesn't light up under the cursor
--- @param enabled boolean
function NumberGrid:SetEnabled(enabled)
  if enabled == self.enabled then
    return
  end
  self.enabled = enabled
  if not enabled then
    self.press:Hide()
    self:leave()
  end
end

--- Writes into the squares
--- @param figures table<number, string|number> What stands in each square, nothing where it doesn't say. Copied, the caller can reuse the table
--- @param inks table<number, number[]>? The colour each is written in, white where it doesn't say. Colours are told apart by the table they are, not by what is in it
function NumberGrid:SetFigures(figures, inks)
  for square, parts in ipairs(self.squares) do
    local text = figures[square]
    if text ~= self.figures[square] then
      self.figures[square] = text
      parts.figure:SetText(text and tostring(text) or "")
    end
    local ink = inks and inks[square] or nil
    if ink ~= self.inks[square] then
      self.inks[square] = ink
      parts.figure:SetTextColor(unpack(ink or WHITE))
    end
  end
end

--- Pencils small figures into the squares
--- @param notes table<number, string> The figures pencilled into each square, one character each: "258". A figure sits where its number puts it, 1 in the top left corner. Copied
--- @param strong string? A figure to point out wherever it is pencilled in
function NumberGrid:SetNotes(notes, strong)
  for square, parts in ipairs(self.squares) do
    local wanted = notes[square] or ""
    -- A square only minds what is pointed out if it has it
    local key = wanted .. ((strong and wanted:find(strong, 1, true)) and ("!" .. strong) or "")
    if key ~= (self.noted[square] or "") then
      self.noted[square] = key
      local made = false
      for _, note in pairs(parts.notes) do
        note:Hide()
      end
      for figure in wanted:gmatch(".") do
        local index = tonumber(figure)
        local note = parts.notes[index]
        if not note then
          note = self.frame:CreateFontString(nil, "ARTWORK")
          note:SetFont(STANDARD_TEXT_FONT, SMALLEST_FONT, "")
          note:SetText(figure)
          parts.notes[index] = note
          made = true
        end
        note:SetTextColor(unpack(figure == strong and self.strongColor or self.noteColor))
        note:Show()
      end
      if made then
        self:arrangeNotes(square)
      end
    end
  end
end

--- Washes squares in a colour, to point them out
--- @param tints table<number, number[]> Colour with alpha by square. Copied. Colours are told apart by the table they are
function NumberGrid:SetTints(tints)
  for square, parts in ipairs(self.squares) do
    local tint = tints[square]
    if tint ~= self.tints[square] then
      self.tints[square] = tint
      if tint then
        parts.tint:SetColorTexture(unpack(tint))
      end
      parts.tint:SetShown(tint ~= nil)
    end
  end
end

--- Puts the frame around a square, or with nil takes it away
--- @param square number?
function NumberGrid:Select(square)
  if square == self.selected then
    return
  end
  self.selected = square
  self:placeCursor()
end

--- Makes the figure of a square pop into it, as if just written. Call it after SetFigures
--- @param square number
function NumberGrid:Pop(square)
  local parts = self.squares[square]
  self.animator:Play(POP, function(progress)
    parts.scale = POP_FROM + (1 - POP_FROM) * progress
    self:pose(square)
  end, { ease = Widgets.Ease.back })
end

--- Makes a square shake its head: what was written there is wrong, or nothing can be
--- @param square number
function NumberGrid:Shake(square)
  local parts = self.squares[square]
  self.animator:Play(SHAKE, function(progress)
    parts.dx = math.sin(progress * math.pi * 2 * SHAKES) * (1 - progress) * self.cell * SHAKE_REACH
    self:pose(square)
  end)
end

--- Lights a square up for a moment, its figure swelling with it. A row of them one after the
--- other is a sweep, all of them by how far they are from somewhere a wave
--- @param square number
--- @param color number[] With alpha: how bright it gets
--- @param delay number? Seconds to wait first
function NumberGrid:Flash(square, color, delay)
  local parts = self.squares[square]
  if not parts.flash then
    parts.flash = self.frame:CreateTexture(nil, "BORDER")
    parts.flash:SetBlendMode("ADD")
    parts.flash:Hide()
    self:place(parts.flash, square)
  end
  local flash = parts.flash
  self.animator:Play(FLASH, function(progress)
    flash:SetAlpha((color[4] or 1) * progress)
    parts.scale = 1 + FLASH_SWELL * progress
    self:pose(square)
  end, {
    delay = delay,
    ease = Widgets.Ease.swell,
    onStart = function()
      flash:SetColorTexture(color[1], color[2], color[3], 1)
      flash:SetAlpha(0)
      flash:Show()
    end,
    onDone = function()
      flash:Hide()
    end,
  })
end

--- Whether anything is still on the move
--- @return boolean
function NumberGrid:Busy()
  return self.animator:Busy()
end

--- Puts everything that is on the move the way it ends up, at once
function NumberGrid:Settle()
  self.animator:Stop()
end

-----------------------------
-- Mouse
-----------------------------

--- The cursor is no longer over any square
function NumberGrid:leave()
  self.hover:Hide()
  if self.over ~= nil then
    self.over = nil
    if self.input and self.input.onHover then
      self.input.onHover(nil)
    end
  end
end

--- Keeps up with the cursor: the square it is over is lit a little
function NumberGrid:watch()
  local over = self.enabled and self.input and self.frame:IsMouseOver() and self:SquareAt(self:pointer()) or nil
  if over == self.over then
    return
  end
  if not over then
    self:leave()
    return
  end
  self.over = over
  self:place(self.hover, over)
  self.hover:Show()
  if self.input.onHover then
    self.input.onHover(over)
  end
end

-----------------------------
-- Keys
-----------------------------

--- A key to press: a figure or a word, with something small said under it. It lights up under
--- the cursor and gives when pressed, and is never dead: one that can't do anything right now is
--- dimmed, and still tells whoever made it that it was pressed.
--- @param parent Frame
--- @param onClick fun(key: Button)
--- @return Button key Set(text, caption) says what is on it, Fit(width, height) sizes it, SetOn(on) and SetDim(dim) show how things stand, SetTip(title, text) is what it says when pointed at
function NumberGrid.Key(parent, onClick)
  local key = Widgets.Panel(parent, "Button")
  key.label = key:CreateFontString(nil, "OVERLAY")
  key.caption = key:CreateFontString(nil, "OVERLAY")
  -- Nothing can be written on it without a font, whatever size it turns out to be
  key.label:SetFont(STANDARD_TEXT_FONT, SMALLEST_FONT + 2, "")
  key.caption:SetFont(STANDARD_TEXT_FONT, SMALLEST_FONT, "")
  key.caption:SetTextColor(unpack(Widgets.GREY))

  local hover = key:CreateTexture(nil, "HIGHLIGHT")
  hover:SetAllPoints()
  hover:SetColorTexture(1, 0.82, 0, 0.14)
  local press = key:CreateTexture(nil, "ARTWORK")
  press:SetAllPoints()
  press:SetColorTexture(0, 0, 0, 0.35)
  press:Hide()
  key.press = press

  --- Puts what is written on it where it goes: a little lower while the key is held down
  --- @param down boolean
  local function seat(down)
    local captioned = (key.caption:GetText() or "") ~= ""
    local height = key:GetHeight()
    key.label:ClearAllPoints()
    key.label:SetPoint("CENTER", 0, (captioned and height * 0.12 or 0) - (down and 1 or 0))
    key.caption:ClearAllPoints()
    key.caption:SetPoint("BOTTOM", 0, math.max(2, height * 0.08) - (down and 1 or 0))
  end

  key:SetScript("OnMouseDown", function()
    press:Show()
    seat(true)
  end)
  key:SetScript("OnMouseUp", function()
    press:Hide()
    seat(false)
  end)
  key:SetScript("OnHide", function()
    press:Hide()
  end)
  key:SetScript("OnClick", function(self)
    onClick(self)
  end)
  key:SetScript("OnEnter", function(self)
    if self.tipTitle then
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:SetText(self.tipTitle)
      if self.tipText then
        GameTooltip:AddLine(self.tipText, 1, 1, 1, true)
      end
      GameTooltip:Show()
    end
  end)
  key:SetScript("OnLeave", GameTooltip_Hide)

  --- @param text string|number
  --- @param caption (string|number)? Something small under it
  function key:Set(text, caption)
    text, caption = tostring(text), caption and tostring(caption) or ""
    if text ~= self.label:GetText() then
      self.label:SetText(text)
    end
    if caption ~= (self.caption:GetText() or "") then
      self.caption:SetText(caption)
      seat(false)
    end
  end

  --- @param width number
  --- @param height number
  --- @param wordy boolean? It says a word rather than a figure, which is written smaller
  function key:Fit(width, height, wordy)
    self:SetSize(width, height)
    self.label:SetFont(STANDARD_TEXT_FONT, math.max(SMALLEST_FONT + 2, math.floor(height * (wordy and 0.3 or 0.46))), "")
    self.caption:SetFont(STANDARD_TEXT_FONT, math.max(SMALLEST_FONT, math.floor(height * 0.22)), "")
    seat(false)
  end

  --- Shows whether what the key turns on and off is on
  --- @param on boolean
  function key:SetOn(on)
    self.on = on
    self:SetBackdropBorderColor(1, on and 0.82 or 1, on and 0 or 1, on and 0.9 or 0.1)
    self:SetBackdropColor(on and 0.35 or 0, on and 0.27 or 0, 0, on and 0.6 or 0.4)
    self.label:SetTextColor(1, on and 0.82 or 1, on and 0 or 1)
  end

  --- Shows whether there is nothing for the key to do right now
  --- @param dim boolean
  function key:SetDim(dim)
    self.dim = dim
    self:SetAlpha(dim and 0.35 or 1)
  end

  --- @param title string?
  --- @param text string?
  function key:SetTip(title, text)
    self.tipTitle, self.tipText = title, text
  end

  key:SetOn(false)
  return key
end

--- A pad of keys: one for every figure there is to write, and a row of tools under them.
--- @param parent Frame
--- @param figures number How many figures, from 1
--- @param tools string[] What the tools are called, for telling them apart
--- @param onFigure fun(figure: number)
--- @param onTool fun(tool: string)
--- @return { frame: Frame, keys: Button[], tools: table<string, Button>, Layout: fun(self: table, across: number, size: number, gap: number): number, number } pad Layout puts the figures so many to a row at a size and returns how much room the pad takes
function NumberGrid.Pad(parent, figures, tools, onFigure, onTool)
  local pad = { frame = CreateFrame("Frame", nil, parent), keys = {}, tools = {} }
  for figure = 1, figures do
    pad.keys[figure] = NumberGrid.Key(pad.frame, function()
      onFigure(figure)
    end)
    pad.keys[figure]:Set(figure)
  end
  for _, tool in ipairs(tools) do
    pad.tools[tool] = NumberGrid.Key(pad.frame, function()
      onTool(tool)
    end)
  end

  --- @param across number How many figures to a row
  --- @param size number Side of a figure's key
  --- @param gap number
  --- @return number width, number height
  function pad:Layout(across, size, gap)
    local rows = math.ceil(figures / across)
    local width = across * size + (across - 1) * gap
    for figure, key in ipairs(self.keys) do
      local column, row = (figure - 1) % across, math.floor((figure - 1) / across)
      key:Fit(size, size)
      key:ClearAllPoints()
      key:SetPoint("TOPLEFT", self.frame, "TOPLEFT", column * (size + gap), -row * (size + gap))
    end
    -- The tools share the width of the pad between them
    local toolWidth = math.floor((width - (#tools - 1) * gap) / math.max(1, #tools))
    for index, tool in ipairs(tools) do
      local key = self.tools[tool]
      key:Fit(toolWidth, size, true)
      key:ClearAllPoints()
      key:SetPoint("TOPLEFT", self.frame, "TOPLEFT", (index - 1) * (toolWidth + gap), -rows * (size + gap))
    end
    local height = (rows + (#tools > 0 and 1 or 0)) * (size + gap) - gap
    self.frame:SetSize(width, height)
    return width, height
  end

  return pad
end
