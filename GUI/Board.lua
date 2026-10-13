--------------------------
--  Board
--------------------------
-- A grid of squares with pieces on it, for any game played on one. It draws at whatever size it
-- is given, lets the player move a piece by dragging it or by clicking it and then where it
-- goes, shows where a picked up piece may go, and glides pieces between squares.
--
-- The board knows nothing about rules. A game hands it the pieces to show and three functions:
-- which squares hold something the player may pick up, where a picked up piece may go, and what
-- to do once it has been put down. See Games/Chess.lua.
--
-- Squares are numbered row by row from the bottom left as the first player sees it, starting at
-- 0. Flipping the board turns it around for the player sitting opposite.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class BoardOptions
--- @field columns number
--- @field rows number
--- @field light number[]? Colour of the light squares
--- @field dark number[]? Colour of the dark squares, the bottom left one is dark
--- @field files string? One character per column, written along the bottom edge
--- @field ranks string? One character per row, written up the left edge

--- @class BoardInput
--- @field pickable (fun(square: number): boolean)? Whether the player may pick up what is on a square
--- @field targets (fun(square: number): table<number, any>)? Squares the piece on a square may go to, as keys
--- @field onMove fun(from: number, to: number, dropped: boolean)? A piece was put on one of its targets. dropped says it was dragged there, so it is already where it belongs and shouldn't glide
--- @field onClick fun(square: number)? A square was clicked that isn't part of moving a piece, for games where pieces are placed

--- @class Board
--- @field frame Frame
--- @field cell number Side of a square
local Board = {}
Board.__index = Board
private.Board = Board

local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\Board\\"
local LIGHT = { 0.86, 0.80, 0.66 }
local DARK = { 0.45, 0.32, 0.23 }
local SELECTED = { 0.25, 0.7, 0.3, 0.55 }
local MARK = { 0.2, 0.75, 0.25, 0.85 }
-- Seconds a piece takes to glide to its square
local GLIDE = 0.18
-- How far the cursor has to travel with the button held before a click becomes a drag
local DRAG_DISTANCE = 4
-- A piece being carried is drawn a little larger, as if lifted off the board
local CARRIED_SCALE = 1.15
local DOT_SCALE = 0.3

--- @param parent Frame
--- @param options BoardOptions
--- @return Board
function Board.New(parent, options)
  --- @type Board
  local self = setmetatable({}, Board)
  self.columns, self.rows = options.columns, options.rows
  self.count = self.columns * self.rows
  self.files, self.ranks = options.files, options.ranks
  self.cell = 0
  self.flipped = false
  self.enabled = false
  self.pieces, self.shown, self.tints, self.targets, self.glides = {}, {}, {}, {}, {}

  local frame = CreateFrame("Frame", nil, parent)
  frame:EnableMouse(true)
  self.frame = frame

  local light, dark = options.light or LIGHT, options.dark or DARK
  self.squares = {}
  for square = 0, self.count - 1 do
    local isDark = (square % self.columns + math.floor(square / self.columns)) % 2 == 0
    local parts = {}

    parts.background = frame:CreateTexture(nil, "BACKGROUND")
    parts.background:SetColorTexture(unpack(isDark and dark or light))

    -- Colours the whole square: the selection, or whatever the game wants pointed out
    parts.tint = frame:CreateTexture(nil, "BORDER")
    parts.tint:Hide()

    -- Says the picked up piece may go here: a dot on an empty square, a ring around a piece
    parts.mark = frame:CreateTexture(nil, "ARTWORK", nil, 1)
    parts.mark:SetVertexColor(unpack(MARK))
    parts.mark:Hide()

    parts.piece = frame:CreateTexture(nil, "ARTWORK", nil, 2)
    parts.piece:Hide()

    self.squares[square] = parts
  end

  self.hover = frame:CreateTexture(nil, "ARTWORK", nil, 0)
  self.hover:SetColorTexture(1, 1, 1, 0.15)
  self.hover:Hide()

  -- Edge labels sit in the corners of the squares along the edge, in the other square colour
  self.fileLabels, self.rankLabels = {}, {}
  for index = 1, self.files and self.columns or 0 do
    self.fileLabels[index] = frame:CreateFontString(nil, "BORDER")
  end
  for index = 1, self.ranks and self.rows or 0 do
    self.rankLabels[index] = frame:CreateFontString(nil, "BORDER")
  end
  self.labelColors = { light, dark }

  frame:SetScript("OnMouseDown", function(_, button)
    self:onMouseDown(button)
  end)
  frame:SetScript("OnMouseUp", function(_, button)
    self:onMouseUp(button)
  end)
  frame:SetScript("OnUpdate", function(_, elapsed)
    self:onUpdate(elapsed)
  end)
  frame:SetScript("OnHide", function()
    self:cancelDrag()
    self.hover:Hide()
  end)
  return self
end

-----------------------------
-- Geometry
-----------------------------

--- Where a square is drawn: the distance of its top left corner from the board's, right and down
--- @param square number
--- @return number x, number y
function Board:OffsetOf(square)
  local column, row = square % self.columns, math.floor(square / self.columns)
  if self.flipped then
    column, row = self.columns - 1 - column, self.rows - 1 - row
  end
  return column * self.cell, (self.rows - 1 - row) * self.cell
end

--- The square at a point measured from the board's top left corner, nil outside the board
--- @param x number
--- @param y number
--- @return number?
function Board:SquareAt(x, y)
  if self.cell <= 0 or x < 0 or y < 0 then
    return nil
  end
  local column, row = math.floor(x / self.cell), self.rows - 1 - math.floor(y / self.cell)
  if column >= self.columns or row < 0 then
    return nil
  end
  if self.flipped then
    column, row = self.columns - 1 - column, self.rows - 1 - row
  end
  return row * self.columns + column
end

--- Where the cursor is, measured from the board's top left corner
--- @return number x, number y
function Board:cursor()
  local scale = self.frame:GetEffectiveScale()
  local x, y = GetCursorPosition()
  return x / scale - (self.frame:GetLeft() or 0), (self.frame:GetTop() or 0) - y / scale
end

--- How many screen pixels a square covers, for picking a texture of the right size
--- @return number
function Board:pixels()
  local height = 768
  if GetPhysicalScreenSize then
    height = select(2, GetPhysicalScreenSize()) or height
  end
  return self.cell * self.frame:GetEffectiveScale() * height / 768
end

--- Puts a square's piece where it belongs, or somewhere else for one that is on the move
--- @param square number
--- @param dx number? Distance from its square
--- @param dy number?
--- @param scale number?
function Board:placePiece(square, dx, dy, scale)
  local piece = self.squares[square].piece
  local x, y = self:OffsetOf(square)
  local half = self.cell / 2
  piece:SetSize(self.cell * (scale or 1), self.cell * (scale or 1))
  piece:ClearAllPoints()
  piece:SetPoint("CENTER", self.frame, "TOPLEFT", x + half + (dx or 0), -(y + half + (dy or 0)))
end

function Board:layout()
  local cell = self.cell
  for square = 0, self.count - 1 do
    local parts = self.squares[square]
    local x, y = self:OffsetOf(square)

    parts.background:ClearAllPoints()
    parts.background:SetPoint("TOPLEFT", x, -y)
    parts.background:SetSize(cell, cell)
    parts.tint:ClearAllPoints()
    parts.tint:SetPoint("TOPLEFT", x, -y)
    parts.tint:SetSize(cell, cell)
    parts.mark:ClearAllPoints()
    parts.mark:SetPoint("CENTER", self.frame, "TOPLEFT", x + cell / 2, -(y + cell / 2))

    if not self.glides[square] and not (self.drag and self.drag.square == square) then
      self:placePiece(square)
    end
  end

  local font = math.max(8, math.floor(cell * 0.2))
  local inset = math.max(1, math.floor(cell * 0.05))
  for index, label in ipairs(self.fileLabels) do
    -- index counts along the bottom edge as drawn, so the letter depends on which way round the board is
    local column = self.flipped and self.columns - index or index - 1
    local bottomRow = self.flipped and self.rows - 1 or 0
    label:SetFont(STANDARD_TEXT_FONT, font, "")
    label:SetText(self.files:sub(column + 1, column + 1))
    label:SetTextColor(unpack(self.labelColors[(column + bottomRow) % 2 + 1]))
    label:ClearAllPoints()
    label:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMLEFT", index * cell - inset, inset)
  end
  for index, label in ipairs(self.rankLabels) do
    local row = self.flipped and self.rows - index or index - 1
    local leftColumn = self.flipped and self.columns - 1 or 0
    label:SetFont(STANDARD_TEXT_FONT, font, "")
    label:SetText(self.ranks:sub(row + 1, row + 1))
    label:SetTextColor(unpack(self.labelColors[(row + leftColumn) % 2 + 1]))
    label:ClearAllPoints()
    label:SetPoint("TOPLEFT", self.frame, "BOTTOMLEFT", inset, index * cell - inset)
  end

  self:refreshPieces()
  self:refreshMarks()
end

-----------------------------
-- Drawing
-----------------------------

function Board:refreshPieces()
  local pixels = self:pixels()
  for square = 0, self.count - 1 do
    local key = self.pieces[square]
    local path = key and self.textureFor(key, pixels) or nil
    local piece = self.squares[square].piece
    if path ~= self.shown[square] then
      self.shown[square] = path
      if path then
        piece:SetTexture(path)
      end
      piece:SetShown(path ~= nil)
    end
  end
end

--- Tints and target marks
function Board:refreshMarks()
  for square = 0, self.count - 1 do
    local parts = self.squares[square]
    local tint = square == self.selected and SELECTED or self.tints[square]
    if tint then
      parts.tint:SetColorTexture(unpack(tint))
    end
    parts.tint:SetShown(tint ~= nil)

    local isTarget = self.targets[square] ~= nil
    if isTarget then
      local occupied = self.pieces[square] ~= nil
      local size = self.cell * (occupied and 1 or DOT_SCALE)
      parts.mark:SetTexture(IMAGES .. (occupied and "ring" or "dot"))
      parts.mark:SetSize(size, size)
    end
    parts.mark:SetShown(isTarget)
  end
end

-----------------------------
-- Public
-----------------------------

--- Fits the board into a square of this side. Squares are a whole number of units, so the board
--- can come out a little smaller: read the result from board.cell.
--- @param side number
function Board:SetSize(side)
  local cell = math.max(1, math.floor(side / math.max(self.columns, self.rows)))
  if cell == self.cell then
    return
  end
  self.cell = cell
  self.frame:SetSize(cell * self.columns, cell * self.rows)
  self:layout()
end

--- Turns the board around, for the player whose pieces start at the top
--- @param flipped boolean
function Board:SetFlipped(flipped)
  if flipped == self.flipped then
    return
  end
  self.flipped = flipped
  self:StopGlides()
  self:layout()
end

--- @param pieces table<number, any> What is on each square. Copied, the caller can reuse the table
--- @param textureFor fun(key: any, pixels: number): string Texture for a piece drawn at this many screen pixels
function Board:SetPieces(pieces, textureFor)
  for square = 0, self.count - 1 do
    self.pieces[square] = pieces[square]
  end
  self.textureFor = textureFor
  if self.drag and not self.pieces[self.drag.square] then
    self:cancelDrag()
  end
  self:refreshPieces()
  self:refreshMarks()
end

--- Colours squares, to point out the last move for example
--- @param tints table<number, number[]> Colour with alpha by square. Kept, not copied
function Board:SetTints(tints)
  self.tints = tints
  self:refreshMarks()
end

--- @param input BoardInput
function Board:SetInput(input)
  self.input = input
end

--- Whether the player can do anything on the board right now
--- @param enabled boolean
function Board:SetEnabled(enabled)
  if enabled == self.enabled then
    return
  end
  self.enabled = enabled
  if not enabled then
    self:cancelDrag()
    self:Select(nil)
    self.hover:Hide()
  end
end

--- Picks a square's piece up or, with nil, puts down whatever is picked up
--- @param square number?
function Board:Select(square)
  if square == nil and self.selected == nil then
    return
  end
  self.selected = square
  local input = self.input
  self.targets = square and input and input.targets and input.targets(square) or {}
  self:refreshMarks()
end

--- Makes the piece on a square arrive there from another one. Call it after SetPieces: the board
--- always holds the position as it ends up, a glide only changes how it gets drawn meanwhile.
--- @param square number Where the piece is now
--- @param from number Where it should appear to come from
function Board:Glide(square, from)
  local x, y = self:OffsetOf(square)
  local fromX, fromY = self:OffsetOf(from)
  self:glideFrom(square, fromX - x, fromY - y)
end

--- @param square number
--- @param dx number Where it starts, as a distance from its square
--- @param dy number
function Board:glideFrom(square, dx, dy)
  self.glides[square] = { dx = dx, dy = dy, elapsed = 0 }
  -- Above the pieces it passes on the way
  self.squares[square].piece:SetDrawLayer("ARTWORK", 3)
  self:placePiece(square, dx, dy)
end

--- Puts every piece that is still on its way straight onto its square
function Board:StopGlides()
  for square in pairs(self.glides) do
    self.glides[square] = nil
    self.squares[square].piece:SetDrawLayer("ARTWORK", 2)
    self:placePiece(square)
  end
end

-----------------------------
-- Mouse
-----------------------------

--- Puts a carried piece back without moving it
function Board:cancelDrag()
  local drag = self.drag
  if not drag then
    return
  end
  self.drag = nil
  self.squares[drag.square].piece:SetDrawLayer("ARTWORK", 2)
  self:placePiece(drag.square)
end

--- @param button string
function Board:onMouseDown(button)
  local input = self.input
  if not self.enabled or not input then
    return
  end
  if button ~= "LeftButton" then
    -- Any other button means "never mind"
    self:cancelDrag()
    self:Select(nil)
    return
  end

  local x, y = self:cursor()
  local square = self:SquareAt(x, y)
  if not square then
    return
  end

  if self.selected and square ~= self.selected and self.targets[square] ~= nil then
    local from = self.selected
    self:Select(nil)
    input.onMove(from, square, false)
  elseif input.pickable and input.pickable(square) then
    -- Clicking the piece that is already picked up puts it down again, unless this turns into a drag
    local again = self.selected == square
    self:Select(square)
    self.drag = { square = square, x = x, y = y, carried = false, again = again }
  else
    self:Select(nil)
    if input.onClick then
      input.onClick(square)
    end
  end
end

--- @param button string
function Board:onMouseUp(button)
  local drag = self.drag
  if button ~= "LeftButton" or not drag then
    return
  end
  self.drag = nil

  if not drag.carried then
    if drag.again then
      self:Select(nil)
    end
    return
  end

  local x, y = self:cursor()
  local to = self:SquareAt(x, y)
  self.squares[drag.square].piece:SetDrawLayer("ARTWORK", 2)
  self:placePiece(drag.square)

  if to and to ~= drag.square and self.targets[to] ~= nil then
    self:Select(nil)
    self.input.onMove(drag.square, to, true)
  else
    -- Not somewhere it can go: back to its square from where it was let go, still picked up
    local squareX, squareY = self:OffsetOf(drag.square)
    self:glideFrom(drag.square, x - self.cell / 2 - squareX, y - self.cell / 2 - squareY)
  end
end

--- @param elapsed number
function Board:onUpdate(elapsed)
  for square, glide in pairs(self.glides) do
    glide.elapsed = glide.elapsed + elapsed
    local progress = math.min(1, glide.elapsed / GLIDE)
    if progress >= 1 then
      self.glides[square] = nil
      self.squares[square].piece:SetDrawLayer("ARTWORK", 2)
      self:placePiece(square)
    else
      -- Fast at first, settling onto the square
      local left = (1 - progress) ^ 3
      self:placePiece(square, glide.dx * left, glide.dy * left)
    end
  end

  if not self.enabled or not self.input then
    return
  end
  local x, y = self:cursor()
  local drag = self.drag

  if drag then
    if not IsMouseButtonDown("LeftButton") then
      -- The button was let go somewhere that didn't tell us
      self:cancelDrag()
    elseif not drag.carried and math.abs(x - drag.x) + math.abs(y - drag.y) > DRAG_DISTANCE then
      drag.carried = true
      self.glides[drag.square] = nil
      self.squares[drag.square].piece:SetDrawLayer("OVERLAY", 7)
    end
    if drag.carried and self.drag then
      local squareX, squareY = self:OffsetOf(drag.square)
      self:placePiece(drag.square, x - self.cell / 2 - squareX, y - self.cell / 2 - squareY, CARRIED_SCALE)
    end
  end

  -- Light up the square under the cursor when clicking or dropping there would do something
  local input = self.input
  local over = self:SquareAt(x, y)
  local useful = false
  if over then
    if self.drag and self.drag.carried then
      useful = self.targets[over] ~= nil
    else
      useful = self.targets[over] ~= nil or (input.pickable ~= nil and input.pickable(over))
    end
  end
  if useful then
    local squareX, squareY = self:OffsetOf(over)
    self.hover:ClearAllPoints()
    self.hover:SetPoint("TOPLEFT", squareX, -squareY)
    self.hover:SetSize(self.cell, self.cell)
  end
  self.hover:SetShown(useful)
end
