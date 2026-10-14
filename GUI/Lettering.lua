--------------------------
--  Lettering
--------------------------
-- A line of text in Lexend, drawn a picture of a character at a time. The client won't write in
-- a font an addon brings along, only in its own, but it draws pictures from an addon's folder:
-- Tools/make_lettering.py draws the characters there are (GUI/LetteringGlyphs.lua) at a few
-- sizes, and each line picks the size that suits how large it is on screen.
--
-- Its frame stands in for a FontString: SetText (colour codes and all), SetTextColor, SetPoint,
-- GetStringWidth. The frame is as wide as the text and as tall as a line of it, so anchoring it
-- by its centre centres the text the way a FontString's would be. A character that isn't drawn
-- leaves a space.

--- @type nil, ForeverGamesPrivate
local _, private = ...

local Lettering = {}
private.Lettering = Lettering

local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\Lettering\\"

--- @class LetteringLine: Frame
--- @field text string
--- @field size number How large the em is
--- @field color number[]
--- @field shadow { color: number[], x: number, y: number }?
--- @field glyphs Texture[]
--- @field shadows Texture[]
--- @field path string? The picture the characters are drawn from now
--- @field textWidth number

--- How many screen pixels something this large covers
--- @param frame Frame
--- @param size number
--- @return number
local function pixels(frame, size)
  local height = 768
  if GetPhysicalScreenSize then
    height = select(2, GetPhysicalScreenSize()) or height
  end
  return size * frame:GetEffectiveScale() * height / 768
end

--- The picture to draw a line this large on screen from: the smallest that isn't shrunk much,
--- since the client doesn't smooth a picture it shrinks a lot
--- @param frame Frame
--- @param size number
--- @return string
local function pictureFor(frame, size)
  local glyphs = private.LetteringGlyphs
  local wanted = pixels(frame, size)
  local square = glyphs.squares[#glyphs.squares]
  for _, side in ipairs(glyphs.squares) do
    if side * glyphs.em >= wanted * 0.85 then
      square = side
      break
    end
  end
  return IMAGES .. square * glyphs.columns
end

--- Cuts a text with colour codes into its characters, each with the colour it is written in:
--- nil for the line's own
--- @param text string
--- @return { character: string, color: number[]? }[]
local function characters(text)
  local result, color, index = {}, nil, 1
  while index <= #text do
    local hex = text:match("^|c%x%x(%x%x%x%x%x%x)", index)
    if hex then
      color = { tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255 }
      index = index + 10
    elseif text:sub(index, index + 1) == "|r" then
      color = nil
      index = index + 2
    else
      -- A character is a byte, or a few of them for one beyond ASCII
      local character = text:match("^[\1-\127\194-\244][\128-\191]*", index)
      result[#result + 1] = { character = character, color = color }
      index = index + #character
    end
  end
  return result
end

--- @param parent Frame
--- @param size number? How large the em is, 12 if left out
--- @return LetteringLine
function Lettering.New(parent, size)
  --- @type LetteringLine
  local line = CreateFrame("Frame", nil, parent)
  line.text, line.size, line.color, line.glyphs, line.shadows = "", size or 12, { 1, 1, 1, 1 }, {}, {}

  --- Puts every character where it goes, from the picture that suits the size it is now
  function line:Draw()
    local glyphs = private.LetteringGlyphs
    local size = self.size
    local path = pictureFor(self, size)
    self.path = path
    -- A square of the picture, as large as it is drawn
    local square = size / glyphs.em
    local cut = 1 / glyphs.columns
    local top = glyphs.ascent * size - glyphs.baseline * square
    local x, count = 0, 0
    for _, part in ipairs(characters(self.text)) do
      local glyph = glyphs.glyphs[part.character]
      if glyph then
        count = count + 1
        local column, row = glyph[1] % glyphs.columns, math.floor(glyph[1] / glyphs.columns)
        local left = x + glyph[2] * size / 2 - square / 2
        for _, set in ipairs({ self.glyphs, self.shadows }) do
          local shadow = set == self.shadows and self.shadow
          if set == self.glyphs or shadow then
            local texture = set[count]
            if not texture then
              texture = self:CreateTexture(nil, "ARTWORK", nil, shadow and 0 or 1)
              set[count] = texture
            end
            if texture.path ~= path then
              texture.path = path
              texture:SetTexture(path)
            end
            texture:SetTexCoord(column * cut, (column + 1) * cut, row * cut, (row + 1) * cut)
            texture:SetSize(square, square)
            texture:ClearAllPoints()
            texture:SetPoint("TOPLEFT", self, "TOPLEFT", left + (shadow and shadow.x or 0), -top + (shadow and shadow.y or 0))
            local color = shadow and shadow.color or part.color or self.color
            texture:SetVertexColor(color[1], color[2], color[3], shadow and color[4] or (part.color and 1 or self.color[4] or 1))
            texture:Show()
          end
        end
        x = x + glyph[2] * size
      else
        x = x + glyphs.space * size
      end
    end
    for _, set in ipairs({ self.glyphs, self.shadows }) do
      for index = (set == self.shadows and not self.shadow) and 1 or count + 1, #set do
        set[index]:Hide()
      end
    end
    self.textWidth = x
    self:SetSize(math.max(1, x), (glyphs.ascent + glyphs.descent) * size)
  end

  --- @param text string?
  function line:SetText(text)
    text = text or ""
    if text ~= self.text then
      self.text = text
      self:Draw()
    end
  end

  --- @return string
  function line:GetText()
    return self.text
  end

  --- How large the em is
  --- @param size number
  function line:SetFontSize(size)
    if size ~= self.size then
      self.size = size
      self:Draw()
    end
  end

  --- @param red number
  --- @param green number
  --- @param blue number
  --- @param alpha number?
  function line:SetTextColor(red, green, blue, alpha)
    self.color = { red, green, blue, alpha or 1 }
    self:Draw()
  end

  --- A copy of the text under it, a little way off, the way a FontString casts a shadow
  --- @param color number[] With its alpha
  --- @param x number
  --- @param y number
  function line:SetShadow(color, x, y)
    self.shadow = { color = color, x = x, y = y }
    self:Draw()
  end

  --- @return number
  function line:GetStringWidth()
    return self.textWidth or 0
  end

  --- Picks the picture again, after what it lies on was zoomed
  function line:Sharpen()
    if pictureFor(self, self.size) ~= self.path then
      self:Draw()
    end
  end

  line:Draw()
  return line
end
