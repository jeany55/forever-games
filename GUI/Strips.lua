--------------------------
--  Strips
--------------------------
-- A screen to draw a picture on a frame at a time, for a game that draws its own: a view from
-- inside a maze (GUI/SectorView.lua), anything else that is worked out pixel by pixel.
--
-- The client has no pixels to offer, only pictures to stretch. So the screen is a sheet of a
-- size of its own (320 by 200, say), and it is drawn on in pieces of it: a column of a picture,
-- a span along a row mapped onto a picture with all eight texture coordinates, a block of one
-- colour. A frame is drawn between Begin and Finish, and whatever isn't drawn again is hidden.
--
-- How many pieces there are is what costs, and moving a piece costs most (Tools/DoomBench,
-- which measured it: about 2.75 microseconds of Lua for each piece moved, a quarter of that for
-- one only shown another part of its picture). So pieces are never thrown away, the first piece
-- drawn in a frame is the texture the first one was the frame before, and nothing about it is
-- told the client again that is what it was: a view that hasn't changed costs next to nothing.
-- Whoever draws in the same order every frame gets the most out of that.
--
-- Pieces that overlap are drawn at levels (SetLevel), the higher over the lower: what is nearer
-- over what is further, say. Pieces at the same level shouldn't overlap, the client doesn't say
-- which of two it draws on top.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class StripsOptions
--- @field width number How many of its own pixels the sheet is across
--- @field height number And down
--- @field filter string? How pictures are sampled, "NEAREST" for pixels that stay square. Left to the client if it doesn't know it

--- @class StripsPiece
--- @field texture Texture
--- @field file string|false What it shows, false for a colour
--- @field left number
--- @field top number
--- @field width number
--- @field height number

--- @class Strips
--- @field frame Frame Laid over whatever it is put in. Size it, then Layout
--- @field width number
--- @field height number
--- @field used integer Pieces drawn so far this frame
--- @field drawn integer Pieces drawn the last frame
--- @field moved integer Of those, how many had to be moved
local Strips = {}
Strips.__index = Strips
private.Strips = Strips

-- How much bigger than its share every piece is drawn, in the screen's units, so that nothing
-- shows through between two that meet
local OVERLAP = 0.5
-- The levels pieces are drawn at, lowest first: the client's sublevels of a layer
local LOWEST, HIGHEST = -8, 7
Strips.LOWEST, Strips.HIGHEST = LOWEST, HIGHEST

--- @param parent Frame
--- @param options StripsOptions
--- @return Strips
function Strips.New(parent, options)
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetClipsChildren(true)
  local self = setmetatable({ frame = frame, pieces = {}, used = 0, shown = 0, drawn = 0, moved = 0, scaleX = 1, scaleY = 1,
    level = LOWEST, filter = options.filter }, Strips)
  self:Resize(options.width, options.height)
  return self
end

--- Changes how many pixels the sheet is
--- @param width number
--- @param height number
function Strips:Resize(width, height)
  self.width, self.height = width, height
  self:Layout()
end

--- Fits the sheet to the frame again, after the frame changed size
function Strips:Layout()
  local width, height = self.frame:GetSize()
  self.scaleX, self.scaleY = (width or 0) / self.width, (height or 0) / self.height
  -- Every piece is put where it goes, as big as it is, again the next time it is drawn
  for _, piece in ipairs(self.pieces) do
    piece.left, piece.width = nil, nil
  end
end

--- Makes pieces ahead of time, hidden, so that a frame that needs more than ever before doesn't
--- also have to make them. Some at a time
--- @param count integer As many as there should be
--- @param most integer? Made this time at most
function Strips:Reserve(count, most)
  local pieces = self.pieces
  for index = #pieces + 1, math.min(count, #pieces + (most or count)) do
    local texture = self.frame:CreateTexture(nil, "ARTWORK")
    texture:Hide()
    pieces[index] = { texture = texture }
  end
end

--- Starts a frame, drawing at the lowest level
function Strips:Begin()
  self.used, self.moved, self.level = 0, 0, LOWEST
end

--- Draws whatever comes next at another level, from LOWEST to HIGHEST
--- @param level integer
function Strips:SetLevel(level)
  self.level = math.max(LOWEST, math.min(HIGHEST, level))
end

--- Hides whatever wasn't drawn this frame
--- @return integer drawn How many pieces were
function Strips:Finish()
  local pieces, used = self.pieces, self.used
  for index = used + 1, self.shown do
    pieces[index].texture:Hide()
  end
  self.shown, self.drawn = used, used
  return used
end

--- The next piece, sat where it goes and showing a picture
--- @return StripsPiece
function Strips:place(left, top, right, bottom, file)
  local used = self.used + 1
  self.used = used
  local piece = self.pieces[used]
  if not piece then
    piece = { texture = self.frame:CreateTexture(nil, "ARTWORK"), file = nil }
    self.pieces[used] = piece
  end
  local texture = piece.texture
  if used > self.shown then
    texture:Show()
  end
  if piece.level ~= self.level then
    piece.level = self.level
    texture:SetDrawLayer("ARTWORK", self.level)
  end
  if piece.file ~= file then
    piece.file = file
    if file then
      if self.filter and not pcall(texture.SetTexture, texture, file, "REPEAT", "REPEAT", self.filter) then
        -- This client doesn't sample that way
        self.filter = nil
      end
      if not self.filter then
        texture:SetTexture(file, "REPEAT", "REPEAT")
      end
    else
      -- A colour isn't tinted
      texture:SetVertexColor(1, 1, 1)
    end
    piece.u0, piece.r, piece.a = nil, nil, nil
  end
  if piece.left ~= left or piece.top ~= top then
    piece.left, piece.top = left, top
    texture:SetPoint("TOPLEFT", self.frame, "TOPLEFT", left * self.scaleX, -top * self.scaleY)
    self.moved = self.moved + 1
  end
  local width, height = right - left, bottom - top
  if piece.width ~= width or piece.height ~= height then
    piece.width, piece.height = width, height
    texture:SetSize(width * self.scaleX + OVERLAP, height * self.scaleY + OVERLAP)
  end
  return piece
end

--- Tints a piece, the picture's own colours times these, and as much of it seen as alpha says
local function tint(piece, r, g, b, a)
  a = a or 1
  if piece.r ~= r or piece.g ~= g or piece.b ~= b or piece.a ~= a then
    piece.r, piece.g, piece.b, piece.a = r, g, b, a
    piece.texture:SetVertexColor(r, g, b, a)
  end
end

--- A piece of a picture, its edges level and upright: a column of a wall, say. Texture
--- coordinates go past 0 and 1 to show the picture again, it is tiled
--- @param left number Where on the sheet, in its pixels
--- @param top number
--- @param right number
--- @param bottom number
--- @param file string
--- @param u0 number Where in the picture its left edge is, from 0 to 1 across it
--- @param u1 number And its right
--- @param v0 number Its top, from 0 to 1 down the picture
--- @param v1 number And its bottom
--- @param r number Tint
--- @param g number
--- @param b number
--- @param a number? How much of it is seen, all of it if left out
function Strips:Quad(left, top, right, bottom, file, u0, u1, v0, v1, r, g, b, a)
  local piece = self:place(left, top, right, bottom, file)
  if piece.u0 ~= u0 or piece.u1 ~= u1 or piece.v0 ~= v0 or piece.v1 ~= v1 or piece.mapped then
    piece.u0, piece.u1, piece.v0, piece.v1, piece.mapped = u0, u1, v0, v1, false
    piece.texture:SetTexCoord(u0, u1, v0, v1)
  end
  tint(piece, r, g, b, a)
end

--- A piece of a picture mapped onto the sheet by where each of its corners is in the picture:
--- a span of floor along a row, say. Corners in the order the client takes them, top left,
--- bottom left, top right, bottom right
function Strips:Mapped(left, top, right, bottom, file, ulx, uly, llx, lly, urx, ury, lrx, lry, r, g, b)
  local piece = self:place(left, top, right, bottom, file)
  if piece.u0 ~= ulx or piece.u1 ~= uly or piece.v0 ~= urx or piece.v1 ~= ury or piece.lx ~= llx or piece.ly ~= lly
    or piece.rx ~= lrx or piece.ry ~= lry or not piece.mapped then
    piece.u0, piece.u1, piece.v0, piece.v1, piece.mapped = ulx, uly, urx, ury, true
    piece.lx, piece.ly, piece.rx, piece.ry = llx, lly, lrx, lry
    piece.texture:SetTexCoord(ulx, uly, llx, lly, urx, ury, lrx, lry)
  end
  tint(piece, r, g, b)
end

--- A block of one colour
function Strips:Fill(left, top, right, bottom, r, g, b, a)
  local piece = self:place(left, top, right, bottom, false)
  a = a or 1
  if piece.r ~= r or piece.g ~= g or piece.b ~= b or piece.a ~= a then
    piece.r, piece.g, piece.b, piece.a = r, g, b, a
    piece.texture:SetColorTexture(r, g, b, a)
  end
end
