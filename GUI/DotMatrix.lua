--------------------------
--  DotMatrix
--------------------------
-- A display made of dots, the kind pinball machines have had since the nineties: 128 dots across
-- and 32 down, glowing orange, every dot that isn't lit still faintly there. What it shows is
-- words and boxes, set out in whole dots, so that whatever moves on it jumps a dot at a time the
-- way it does on a real one.
--
-- It is drawn afresh whenever the game likes, usually every frame: Begin, then Text and Box for
-- what is on it now, then Finish, which puts away whatever was shown before and isn't any more.
-- A letter is one picture, drawn by Tools/make_dotmatrix.py in two sizes: "small", 5 dots wide
-- and 7 tall, and "big", every dot of those four. Characters it has no letter for are shown as
-- spaces, and small letters as capitals.
--
-- Nothing here knows any game.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class DotMatrix
--- @field frame Frame
--- @field columns integer
--- @field rows integer
--- @field dot number How big a dot is on screen
local DotMatrix = {}
DotMatrix.__index = DotMatrix
private.DotMatrix = DotMatrix

-- The characters there are, in the order of their cells in the pictures; Tools/make_dotmatrix.py
-- has the same
local CHARS = " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!?.,:;'\"-+/%#&()*=<>_$@[]"
local CELL_OF = {}
for index = 1, #CHARS do
  CELL_OF[CHARS:sub(index, index)] = index - 1
end
-- How the pictures are laid out: 8 by 8 cells on a sheet 1024 across, each letter at the top left of
-- its cell with a gap of a dot on its right and below it, 96 by 128 of the cell's 128
local SHEET, CELLS, CELL = 1024, 8, 128
local FONTS = {
  small = { across = 6, down = 8 },
  big = { across = 12, down = 16 },
}
-- How bright a dot that isn't lit is, and how far a lit one glows round it
local UNLIT, GLOW_ALPHA, GLOW_SIZE = 0.09, 0.32, 1.6

local DEFAULT_IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\DotMatrix\\"

--- @param parent Frame
--- @param options { columns: integer?, rows: integer?, color: number[]?, images: string? }?
--- @return DotMatrix
function DotMatrix.New(parent, options)
  options = options or {}
  local display = setmetatable({
    columns = options.columns or 128,
    rows = options.rows or 32,
    color = options.color or { 1, 0.48, 0.1 },
    images = options.images or DEFAULT_IMAGES,
    dot = 2,
    pieces = {},
    used = 0,
  }, DotMatrix)
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetClipsChildren(true)
  display.frame = frame
  local back = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
  back:SetAllPoints()
  back:SetColorTexture(0.02, 0.012, 0.008, 1)
  -- Every dot, unlit, as one picture of a dot repeated
  local unlit = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
  unlit:SetAllPoints()
  unlit:SetTexture(display.images .. "dot", "REPEAT", "REPEAT")
  unlit:SetTexCoord(0, display.columns, 0, display.rows)
  local c = display.color
  unlit:SetVertexColor(c[1], c[2], c[3], UNLIT)
  display.unlit = unlit
  display:SetDot(2)
  return display
end

--- Sets how big a dot is on screen, and so how big the display is
--- @param size number
function DotMatrix:SetDot(size)
  self.dot = size
  self.frame:SetSize(self.columns * size, self.rows * size)
end

--- How many dots across a line of text is, in a font
--- @param text string
--- @param font string? "small" if not said
--- @return integer
function DotMatrix.Width(text, font)
  local across = FONTS[font or "small"].across
  -- The last letter's gap isn't part of the line
  return #text > 0 and #text * across - across / 6 or 0
end

local function piece(self)
  self.used = self.used + 1
  local made = self.pieces[self.used]
  if not made then
    made = { lit = self.frame:CreateTexture(nil, "ARTWORK"), glow = self.frame:CreateTexture(nil, "BORDER") }
    made.glow:SetBlendMode("ADD")
    self.pieces[self.used] = made
  end
  return made
end

--- Starts showing something else: whatever is shown next replaces what was
function DotMatrix:Begin()
  self.used = 0
end

--- A picture of dots at a place on the display, a dot's size times `across` by `down`
local function place(self, made, x, y, across, down, brightness)
  local size, c = self.dot, self.color
  local lit, glow = made.lit, made.glow
  lit:ClearAllPoints()
  lit:SetPoint("TOPLEFT", self.frame, "TOPLEFT", x * size, -y * size)
  lit:SetSize(across * size, down * size)
  lit:SetVertexColor(c[1], c[2], c[3], brightness)
  lit:Show()
  -- The glow is the same picture, larger, faint, and added to what is under it
  local grow = (GLOW_SIZE - 1) * size / 2
  glow:ClearAllPoints()
  glow:SetPoint("TOPLEFT", self.frame, "TOPLEFT", x * size - grow, -y * size + grow)
  glow:SetSize(across * size + 2 * grow, down * size + 2 * grow)
  glow:SetVertexColor(c[1], c[2], c[3], brightness * GLOW_ALPHA)
  glow:Show()
end

--- Writes a line of text, its top `y` dots down. `x` is where its left edge is, or its middle or
--- right edge as `align` says. Positions are rounded to whole dots
--- @param text string
--- @param x number
--- @param y number
--- @param font string? "small" or "big", "small" if not said
--- @param align string? "left", "center" or "right", "left" if not said
--- @param brightness number? 0 to 1, 1 if not said
--- @return integer width How many dots across it is
function DotMatrix:Text(text, x, y, font, align, brightness)
  font = font or "small"
  text = tostring(text):upper()
  local shape = FONTS[font]
  local width = DotMatrix.Width(text, font)
  if align == "center" then
    x = x - width / 2
  elseif align == "right" then
    x = x - width
  end
  x, y = math.floor(x + 0.5), math.floor(y + 0.5)
  local file = self.images .. font
  for index = 1, #text do
    local cell = CELL_OF[text:sub(index, index)]
    local left = x + (index - 1) * shape.across
    -- Spaces, and letters wholly off the display, need nothing drawn
    if cell and cell > 0 and left + shape.across > 0 and left < self.columns then
      local made = piece(self)
      local u, v = (cell % CELLS) * CELL / SHEET, math.floor(cell / CELLS) * CELL / SHEET
      local u2, v2 = u + 96 / SHEET, v + 128 / SHEET
      for _, texture in ipairs({ made.lit, made.glow }) do
        texture:SetTexture(file)
        texture:SetTexCoord(u, u2, v, v2)
      end
      place(self, made, left, y, shape.across, shape.down, brightness or 1)
    end
  end
  return width
end

--- A rectangle of lit dots, `across` by `down` of them, its top left corner at x, y
--- @param x number
--- @param y number
--- @param across number
--- @param down number
--- @param brightness number?
function DotMatrix:Box(x, y, across, down, brightness)
  x, y = math.floor(x + 0.5), math.floor(y + 0.5)
  across, down = math.floor(across + 0.5), math.floor(down + 0.5)
  if across <= 0 or down <= 0 then
    return
  end
  local made = piece(self)
  for _, texture in ipairs({ made.lit, made.glow }) do
    texture:SetTexture(self.images .. "dot", "REPEAT", "REPEAT")
    texture:SetTexCoord(0, across, 0, down)
  end
  place(self, made, x, y, across, down, brightness or 1)
end

--- A picture made of dots: a row of characters for each row of dots, top first, where any but a
--- space or a "." is lit. Each run of lit dots along a row is drawn as one box
--- @param rows string[]
--- @param x number Its left edge
--- @param y number Its top
--- @param brightness number?
function DotMatrix:Bitmap(rows, x, y, brightness)
  for row, line in ipairs(rows) do
    local from
    for column = 1, #line + 1 do
      local char = line:sub(column, column)
      local lit = char ~= "" and char ~= " " and char ~= "."
      if lit and not from then
        from = column
      elseif not lit and from then
        self:Box(x + from - 1, y + row - 1, column - from, 1, brightness)
        from = nil
      end
    end
  end
end

--- Puts away what was shown before and isn't now
function DotMatrix:Finish()
  for index = self.used + 1, #self.pieces do
    local made = self.pieces[index]
    if made.lit:IsShown() then
      made.lit:Hide()
      made.glow:Hide()
    end
  end
end
