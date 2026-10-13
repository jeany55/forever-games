--------------------------
--  Board
--------------------------
-- A grid of squares with pieces on it, for any game played on one. It draws at whatever size it
-- is given, lets the player move a piece by dragging it or by clicking it and then where it
-- goes, shows where a picked up piece may go, and glides pieces between squares. Games where
-- pieces are put down rather than moved get the squares they may go on marked, and pieces that
-- drop into place or turn over.
--
-- The board knows nothing about rules. A game hands it the pieces to show and a few functions.
-- For pieces that move: which squares hold something the player may pick up, where a picked up
-- piece may go, and what to do once it has been put down, see Games/Chess.lua. For pieces that
-- are placed: where a click on a square puts one, and what to do then, see Games/Reversi.lua.
--
-- Squares are numbered row by row from the bottom left as the first player sees it, starting at
-- 0. Flipping the board turns it around for the player sitting opposite.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class BoardOptions
--- @field columns number
--- @field rows number
--- @field light number[]? Colour of the light squares
--- @field dark number[]? Colour of the dark squares, the bottom left one is dark. Give both the same colour for a plain board
--- @field lines number[]? Colour of a thin line drawn between the squares, for a plain board
--- @field inlay { texture: string, color: number[], scale: number }? Something drawn on every square under its piece, like the holes of a rack
--- @field mark number[]? Colour of the marks on squares a piece may go to
--- @field files string? One character per column, written along the bottom edge
--- @field ranks string? One character per row, written up the left edge
--- @field label number[]? Colour of the edge labels, for a board where the other square colour doesn't stand out

--- @class BoardInput
--- @field pickable (fun(square: number): boolean)? Whether the player may pick up what is on a square
--- @field targets (fun(square: number): table<number, any>)? Squares the piece on a square may go to, as keys
--- @field onMove fun(from: number, to: number, dropped: boolean)? A piece was put on one of its targets. dropped says it was dragged there, so it is already where it belongs and shouldn't glide
--- @field place (fun(square: number): number?)? For games where pieces are placed: the square a click on this one puts a piece on, nil for none. Usually the square itself, but a game may let the player point at a whole column. The squares that stand for themselves get marked
--- @field onPlace fun(square: number)? The player clicked to place a piece on this square
--- @field onCancel fun()? The player clicked away from what they were doing, or waved it off with another mouse button

--- @class Board
--- @field frame Frame
--- @field cell number Side of a square
local Board = {}
Board.__index = Board
private.Board = Board

local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\Board\\"
local DISCS = "Interface\\AddOns\\ForeverGames\\Images\\Discs\\"
-- Piece textures come in these sizes: the client only reads power of two textures and doesn't
-- build mipmaps for them
local TEXTURE_SIZES = { 64, 128, 256 }
local LIGHT = { 0.86, 0.80, 0.66 }
local DARK = { 0.45, 0.32, 0.23 }
local SELECTED = { 0.25, 0.7, 0.3, 0.55 }
local MARK = { 0.2, 0.75, 0.25, 0.85 }
-- Seconds a piece takes to glide to its square, or to the next square on its way there
local GLIDE = 0.18
-- Seconds a dropped piece takes to fall past the first square, it gets faster from there
local FALL = 0.14
-- Seconds a piece takes to turn over
local FLIP = 0.3
-- How narrow a piece gets while it turns over, it can't have no width at all
local FLIP_EDGE = 0.06
-- How far the cursor has to travel with the button held before a click becomes a drag
local DRAG_DISTANCE = 4
-- A piece being carried is drawn a little larger, as if lifted off the board
local CARRIED_SCALE = 1.15
local DOT_SCALE = 0.3
-- A piece that is where it belongs, as a distance from its square
local HERE = { 0, 0 }

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
  self.pieces, self.shown, self.tints, self.targets, self.glides, self.flips = {}, {}, {}, {}, {}, {}

  local frame = CreateFrame("Frame", nil, parent)
  frame:EnableMouse(true)
  self.frame = frame

  local light, dark = options.light or LIGHT, options.dark or DARK
  local inlay = options.inlay
  self.inlayScale = inlay and inlay.scale or 1
  if options.lines then
    -- Shows through between the squares, which are drawn a little smaller for it
    self.lines = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
    self.lines:SetAllPoints()
    self.lines:SetColorTexture(unpack(options.lines))
  end
  self.squares = {}
  for square = 0, self.count - 1 do
    local isDark = (square % self.columns + math.floor(square / self.columns)) % 2 == 0
    local parts = {}

    parts.background = frame:CreateTexture(nil, "BACKGROUND")
    parts.background:SetColorTexture(unpack(isDark and dark or light))

    if inlay then
      parts.inlay = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
      parts.inlay:SetTexture(inlay.texture)
      parts.inlay:SetVertexColor(unpack(inlay.color))
    end

    -- Colours the whole square: the selection, or whatever the game wants pointed out
    parts.tint = frame:CreateTexture(nil, "BORDER")
    parts.tint:Hide()

    -- Says the picked up piece may go here: a dot on an empty square, a ring around a piece
    parts.mark = frame:CreateTexture(nil, "ARTWORK", nil, 1)
    parts.mark:SetVertexColor(unpack(options.mark or MARK))
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
  self.labelColors = options.label and { options.label, options.label } or { light, dark }

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
  -- Room left around each square for the lines between them
  local inset = self.lines and math.max(1, math.floor(cell * 0.02)) or 0
  for square = 0, self.count - 1 do
    local parts = self.squares[square]
    local x, y = self:OffsetOf(square)

    parts.background:ClearAllPoints()
    parts.background:SetPoint("TOPLEFT", x + inset, -(y + inset))
    parts.background:SetSize(cell - 2 * inset, cell - 2 * inset)
    parts.tint:ClearAllPoints()
    parts.tint:SetPoint("TOPLEFT", x + inset, -(y + inset))
    parts.tint:SetSize(cell - 2 * inset, cell - 2 * inset)
    parts.mark:ClearAllPoints()
    parts.mark:SetPoint("CENTER", self.frame, "TOPLEFT", x + cell / 2, -(y + cell / 2))
    if parts.inlay then
      parts.inlay:ClearAllPoints()
      parts.inlay:SetPoint("CENTER", self.frame, "TOPLEFT", x + cell / 2, -(y + cell / 2))
      parts.inlay:SetSize(cell * self.inlayScale, cell * self.inlayScale)
    end

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
  -- With nothing picked up, the squares a piece may be placed on are marked the same way
  local place = self.enabled and self.selected == nil and self.input and self.input.place or nil
  for square = 0, self.count - 1 do
    local parts = self.squares[square]
    local tint = square == self.selected and SELECTED or self.tints[square]
    if tint then
      parts.tint:SetColorTexture(unpack(tint))
    end
    parts.tint:SetShown(tint ~= nil)

    local isTarget = self.targets[square] ~= nil or (place ~= nil and place(square) == square)
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

--- The size to use of a texture that comes in several, for drawing it at this many screen pixels
--- @param pixels number?
--- @return number
function Board.TextureSize(pixels)
  -- The smallest one that doesn't have to be stretched much: the client doesn't smooth a
  -- texture it shrinks a lot, and a small one blown up is blurry
  for _, size in ipairs(TEXTURE_SIZES) do
    if size >= (pixels or 0) * 0.85 then
      return size
    end
  end
  return TEXTURE_SIZES[#TEXTURE_SIZES]
end

--- A round playing piece from the shared set, see Tools/make_discs.py for what there is
--- @param name string
--- @param pixels number? Screen pixels it will be drawn at
--- @return string
function Board.Disc(name, pixels)
  return DISCS .. Board.TextureSize(pixels) .. "\\" .. name
end

--- A piece with a line of text next to it, for a score or a count of what was taken
--- @param parent Frame
--- @param height number
--- @return Frame tally Set(texture, text) fills it
function Board.Tally(parent, height)
  local tally = CreateFrame("Frame", nil, parent)
  tally:SetHeight(height)
  local icon = tally:CreateTexture(nil, "ARTWORK")
  icon:SetSize(height, height)
  icon:SetPoint("LEFT")
  local label = tally:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("LEFT", icon, "RIGHT", 4, 0)
  tally.label = label

  --- @param texture string
  --- @param text string
  function tally:Set(texture, text)
    icon:SetTexture(texture)
    label:SetText(text)
  end
  return tally
end

--- Fits the board into this much room. Squares are a whole number of units, so the board can
--- come out a little smaller: read the result from board.cell.
--- @param width number
--- @param height number? As high as wide if left out
function Board:SetSize(width, height)
  local cell = math.max(1, math.floor(math.min(width / self.columns, (height or width) / self.rows)))
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
  self:refreshMarks()
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
--- @param via number[]? Squares it stops at on the way, in order
function Board:Glide(square, from, via)
  local x, y = self:OffsetOf(square)
  local points = {}
  for index = 0, via and #via or 0 do
    local pointX, pointY = self:OffsetOf(index == 0 and from or via[index])
    points[#points + 1] = { pointX - x, pointY - y }
  end
  self:animate(square, points, GLIDE, false)
end

--- Makes the piece on a square fall into it from above the board. Call it after SetPieces
--- @param square number
function Board:Drop(square)
  local _, y = self:OffsetOf(square)
  local height = y + self.cell
  -- Falling from rest, the time goes with the square root of the height
  self:animate(square, { { 0, -height } }, FALL * math.sqrt(height / math.max(1, self.cell)), true)
end

--- Makes the piece on a square turn over into what it is now. Call it after SetPieces
--- @param square number
--- @param from any What it was before, as given to SetPieces
--- @param delay number? Seconds to wait first, to turn a row of pieces over one after the other
function Board:Flip(square, from, delay)
  local path = self.textureFor(from, self:pixels())
  self.flips[square] = { elapsed = -(delay or 0), turned = false }
  self.squares[square].piece:SetTexture(path)
end

--- @param square number
--- @param points number[][] Where it starts and where it stops on the way, as distances from its square
--- @param seconds number How long each stretch takes
--- @param falling boolean Whether it speeds up on the way instead of settling
function Board:animate(square, points, seconds, falling)
  self.glides[square] = { points = points, seconds = seconds, falling = falling, elapsed = 0 }
  -- Above the pieces it passes on the way
  self.squares[square].piece:SetDrawLayer("ARTWORK", 3)
  self:placePiece(square, points[1][1], points[1][2])
end

--- Puts every piece that is still moving or turning the way it ends up
function Board:StopGlides()
  for square in pairs(self.glides) do
    self.glides[square] = nil
    self.squares[square].piece:SetDrawLayer("ARTWORK", 2)
    self:placePiece(square)
  end
  for square in pairs(self.flips) do
    self.flips[square] = nil
    if self.shown[square] then
      self.squares[square].piece:SetTexture(self.shown[square])
    end
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
    if input.onCancel then
      input.onCancel()
    end
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
    local to = input.place and input.place(square)
    if to then
      input.onPlace(to)
    elseif input.onCancel then
      input.onCancel()
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
    self:animate(drag.square, { { x - self.cell / 2 - squareX, y - self.cell / 2 - squareY } }, GLIDE, false)
  end
end

--- @param elapsed number
function Board:onUpdate(elapsed)
  for square, glide in pairs(self.glides) do
    glide.elapsed = glide.elapsed + elapsed
    local stretch = math.floor(glide.elapsed / glide.seconds) + 1
    local from = glide.points[stretch]
    if not from then
      self.glides[square] = nil
      self.squares[square].piece:SetDrawLayer("ARTWORK", 2)
      self:placePiece(square)
    else
      local to = glide.points[stretch + 1] or HERE
      local progress = glide.elapsed / glide.seconds - (stretch - 1)
      -- A glide is fast at first and settles onto the square, a fall starts slow
      local left = glide.falling and 1 - progress ^ 2 or (1 - progress) ^ 3
      self:placePiece(square, to[1] + (from[1] - to[1]) * left, to[2] + (from[2] - to[2]) * left)
    end
  end

  for square, flip in pairs(self.flips) do
    flip.elapsed = flip.elapsed + elapsed
    local progress = math.max(0, flip.elapsed / FLIP)
    local piece = self.squares[square].piece
    if progress >= 1 then
      self.flips[square] = nil
      self:placePiece(square)
    else
      if progress >= 0.5 and not flip.turned then
        -- Edge on: from here it shows its other side
        flip.turned = true
        piece:SetTexture(self.shown[square])
      end
      piece:SetWidth(self.cell * math.max(FLIP_EDGE, math.abs(1 - 2 * progress)))
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
      if not useful and input.place then
        -- Light up where the piece would end up, which needn't be where the cursor is
        over = input.place(over)
        useful = over ~= nil
      end
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
