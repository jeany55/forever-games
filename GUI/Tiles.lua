--------------------------
--  Tiles
--------------------------
-- Lettered tiles, for any game played with them: a tile of bone with a letter on it and, small
-- in its corner, what the letter is worth, both in Lexend (GUI/Lettering.lua). The letters are
-- drawn on rather than painted into the tile, at the size of picture that suits how large they
-- are on screen, so a tile is sharp however far a board is zoomed in on.
--
-- Nothing here knows any rules. See Games/Words.lua, and Tools/make_tiles.py for the pictures,
-- which also come with a few white ones for a game to tint: the light around a tile, a square of
-- a board, a star and an arrow.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class Tiles
local Tiles = {}
private.Tiles = Tiles

local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\Tiles\\"
Tiles.GLOW, Tiles.CELL, Tiles.STAR, Tiles.ARROW = IMAGES .. "glow", IMAGES .. "cell", IMAGES .. "star", IMAGES .. "arrow"
-- How much bigger than its tile the light around it is drawn
Tiles.GLOW_SCALE = 1.5

-- Sizes of the letter and of what it is worth, as fractions of the tile's side
local LETTER, VALUE = 0.58, 0.25
local SMALLEST_FONT = 6
local INK = { 0.2, 0.11, 0.04 }
-- A letter that isn't the tile's own: one a blank stands for
local STOOD = { 0.5, 0.18, 0.62 }

--- @class Tile: Frame
--- @field side number
--- @field letter LetteringLine
--- @field value LetteringLine
--- @field body Texture

--- How many screen pixels a tile covers, for picking a texture of the right size
--- @param tile Tile
--- @return number
local function pixels(tile)
  local height = 768
  if GetPhysicalScreenSize then
    height = select(2, GetPhysicalScreenSize()) or height
  end
  return tile.side * tile:GetEffectiveScale() * height / 768
end

--- @param parent Frame
--- @return Tile
function Tiles.New(parent)
  --- @type Tile
  local tile = CreateFrame("Frame", nil, parent)
  tile.side = 0
  tile.body = tile:CreateTexture(nil, "ARTWORK")
  tile.body:SetAllPoints()
  tile.letter = private.Lettering.New(tile, SMALLEST_FONT)
  tile.value = private.Lettering.New(tile, SMALLEST_FONT)

  --- Draws it at another size
  --- @param side number
  function tile:Fit(side)
    if side == self.side then
      return
    end
    self.side = side
    self:SetSize(side, side)
    self.letter:SetFontSize(math.max(SMALLEST_FONT, math.floor(side * LETTER)))
    self.letter:ClearAllPoints()
    self.letter:SetPoint("CENTER", -side * 0.03, side * 0.02)
    self.value:SetFontSize(math.max(SMALLEST_FONT, math.floor(side * VALUE)))
    self.value:ClearAllPoints()
    self.value:SetPoint("BOTTOMRIGHT", -side * 0.13, side * 0.11)
    self:Sharpen()
  end

  --- Picks the picture that suits the size it is on screen now, after whatever it lies on was zoomed
  function tile:Sharpen()
    local path = IMAGES .. private.Board.TextureSize(pixels(self)) .. "\\tile"
    if path ~= self.path then
      self.path = path
      self.body:SetTexture(path)
    end
    self.letter:Sharpen()
    self.value:Sharpen()
  end

  --- @param letter string? What is written on it, nothing for a tile seen blank
  --- @param value number? What it is worth, nothing for a tile that is worth nothing
  --- @param stood boolean? The letter is one a blank stands for
  function tile:Set(letter, value, stood)
    self.letter:SetText(letter or "")
    self.letter:SetTextColor(unpack(stood and STOOD or INK))
    self.value:SetText(value and value > 0 and tostring(value) or "")
    self.value:SetTextColor(unpack(INK))
  end

  --- Colours the tile itself, for one that should stand out from the others
  --- @param color number[]? Its own if left out
  function tile:Tint(color)
    self.body:SetVertexColor(unpack(color or { 1, 1, 1 }))
  end

  return tile
end
