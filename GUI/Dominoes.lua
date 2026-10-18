--------------------------
--  Dominoes
--------------------------
-- Domino tiles, for any game played with them (Engine/Bones.lua): a tile that can lie at any
-- angle, face up or face down, be lifted off the table, lit up, turned over and sent flying
-- from one place to another; and the line of play laid out on a table of any shape.
--
-- A tile is drawn from parts rather than one picture of each: its body, a block of ivory, ebony
-- or jade with a line across its middle and a brass pin in it, and the pips put on it one at a
-- time. The pips are where the body is turned to, so a tile can turn smoothly from standing in
-- a hand to lying in the line, and they stay round and sharp however big it is drawn. The body
-- comes lying down and standing up, each lit from the top left (Tools/make_dominoes.py), and
-- is only ever turned the little way from the nearer of the two, so the light stays where the
-- light is on everything else.
--
-- What the tiles look like is the player's to choose in the options (Dominoes.SetStyle), and
-- every tile on screen changes the moment they do.
--
-- Places are measured from the top left of the frame a tile is made in, y going down, and the
-- size of a tile is its unit: the width of a tile, half its length. Its angle is the way its
-- second end lies from its first: 0 lying with the first end on the left, pi / 2 standing with
-- the first end on top.
--
-- Nothing here knows any rules. See Games/Dominoes.lua.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class Dominoes
local Dominoes = {}
private.Dominoes = Dominoes

local Bones = private.Bones
local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\Dominoes\\"

-- The looks to choose from, in the order the options show them
Dominoes.STYLES = { "ivory", "ebony", "jade", "sapphire", "coloured" }
Dominoes.STYLE = "ivory"
-- What each looks like: the body it is made of, and the colour of its pips. Pips coloured by
-- their number, as the bigger sets have them, for the last: from one to twelve
local LOOKS = {
  ivory = { body = "ivory", pips = { 0.09, 0.08, 0.07 } },
  ebony = { body = "ebony", pips = { 0.97, 0.95, 0.9 } },
  jade = { body = "jade", pips = { 1, 0.86, 0.5 } },
  sapphire = { body = "sapphire", pips = { 0.95, 0.96, 1 } },
  coloured = {
    body = "ivory",
    numbered = {
      { 0.16, 0.55, 0.88 }, { 0.15, 0.6, 0.27 }, { 0.84, 0.18, 0.16 }, { 0.5, 0.3, 0.13 },
      { 0.48, 0.24, 0.72 }, { 0.92, 0.52, 0.06 }, { 0.05, 0.6, 0.6 }, { 0.85, 0.25, 0.55 },
      { 0.35, 0.35, 0.38 }, { 0.6, 0.6, 0.1 }, { 0.2, 0.25, 0.6 }, { 0.6, 0.1, 0.1 },
    },
  },
}
Dominoes.HIDDEN = Bones.HIDDEN

-- How much of the side of its picture a tile's length fills: the rest is room for it to turn in
-- (Tools/make_dominoes.py). The light round a tile and its shadow are drawn as big as its body
local FILL = 224 / 256
-- Pictures come in two sizes, the bigger for a tile drawn longer than this many pixels
local BIG_PIXELS = 150
-- How big a pip is, as a part of a tile's width, and the pips of the biggest numbers
local PIP, PIP_SMALL = 0.17, 0.13
-- How much bigger a tile is drawn lifted all the way, and how far its shadow falls then and
-- when it lies on the table, as parts of its width
local LIFT_GROW, SHADOW_LIFTED, SHADOW_LYING = 0.1, 0.32, 0.07
-- How dark the shadow is, lying and lifted
local SHADOW_DARK, SHADOW_LIFTED_DARK = 0.5, 0.32
-- A tile that can't be played now
local DIMMED = 0.55

-- Where the pips go on an end, in parts of the tile's width from the middle of the end, for a
-- tile standing up: x to the right, y down
local NEAR = 0.26
local PIP_SPOTS = {
  [0] = {},
  { { 0, 0 } },
  { { -NEAR, -NEAR }, { NEAR, NEAR } },
  { { -NEAR, -NEAR }, { 0, 0 }, { NEAR, NEAR } },
  { { -NEAR, -NEAR }, { NEAR, -NEAR }, { -NEAR, NEAR }, { NEAR, NEAR } },
  { { -NEAR, -NEAR }, { NEAR, -NEAR }, { 0, 0 }, { -NEAR, NEAR }, { NEAR, NEAR } },
  { { -NEAR, -NEAR }, { NEAR, -NEAR }, { -NEAR, 0 }, { NEAR, 0 }, { -NEAR, NEAR }, { NEAR, NEAR } },
  { { -NEAR, -NEAR }, { NEAR, -NEAR }, { -NEAR, 0 }, { 0, 0 }, { NEAR, 0 }, { -NEAR, NEAR }, { NEAR, NEAR } },
  { { -NEAR, -NEAR }, { 0, -NEAR }, { NEAR, -NEAR }, { -NEAR, 0 }, { NEAR, 0 }, { -NEAR, NEAR }, { 0, NEAR }, { NEAR, NEAR } },
  {
    { -NEAR, -NEAR }, { 0, -NEAR }, { NEAR, -NEAR },
    { -NEAR, 0 }, { 0, 0 }, { NEAR, 0 },
    { -NEAR, NEAR }, { 0, NEAR }, { NEAR, NEAR },
  },
}
-- Ten to twelve: three across and four down, with the gaps left where they are on a real set
do
  local FAR = 0.3
  local rows = { -FAR, -FAR / 3, FAR / 3, FAR }
  local function grid(skip)
    local spots = {}
    for row, y in ipairs(rows) do
      for column = -1, 1 do
        if not skip[row .. ":" .. column] then
          spots[#spots + 1] = { column * NEAR, y }
        end
      end
    end
    return spots
  end
  PIP_SPOTS[10] = grid({ ["2:0"] = true, ["3:0"] = true })
  PIP_SPOTS[11] = grid({ ["2:0"] = true })
  PIP_SPOTS[12] = grid({})
end

--- Where the pips of a number go on an end, for a tile standing up
--- @param pips number
--- @return number[][] Pairs of x and y in parts of the tile's width from the middle of the end
function Dominoes.PipSpots(pips)
  return PIP_SPOTS[pips] or {}
end

-- Every tile there is, to be shown a look the player chose. Forgotten with the tile
local tiles = setmetatable({}, { __mode = "k" })

--- The look the player chose, the usual one if they never did or chose one that has gone
--- @return string
function Dominoes.Style()
  local addon = ForeverGames
  local chosen = addon and addon.db and addon.db.profile.dominoStyle
  return LOOKS[chosen] and chosen or Dominoes.STYLE
end

--- Makes a look the one tiles have, and turns every tile on screen to it
--- @param style string
function Dominoes.SetStyle(style)
  ForeverGames.db.profile.dominoStyle = style
  for tile in pairs(tiles) do
    if not tile.style then
      tile:paint()
    end
  end
end

-----------------------------
-- A tile
-----------------------------

--- Where a tile is: its middle, its size and the way it lies
--- @class DominoPlace
--- @field x number From the left of the frame it is in
--- @field y number Down from its top
--- @field unit number Its width, half its length
--- @field angle number Radians, see above

--- @class Domino
--- @field frame Button Takes the clicks, on the tile itself as it lies
--- @field tile string? What is on it, the end nearer its first end first, or Dominoes.HIDDEN for its back. Nil for no tile
--- @field style string? A look of its own, whatever the player chose: for a picture of one of them to choose from
--- @field x number
--- @field y number
--- @field unit number
--- @field angle number
--- @field lift number How far it is lifted off the table, from 0 lying on it to 1
--- @field squash number How wide it is drawn across the screen, from 1 down to 0 halfway through being turned over
--- @field rise number Pixels it stands up out of its place, as a tile in a hand that can be played does
--- @field dim boolean
--- @field loose boolean? Something else puts it where it is (GUI/Drag.lua, carrying it): it is drawn where it is put
local Domino = {}
Domino.__index = Domino
Dominoes.Domino = Domino

--- A tile, hidden until it is given something to be
--- @param parent Frame Where it lies
--- @return Domino
function Dominoes.New(parent)
  --- @type Domino
  local self = setmetatable({
    parent = parent,
    x = 0,
    y = 0,
    unit = 10,
    angle = 0,
    lift = 0,
    squash = 1,
    rise = 0,
    dim = false,
    pips = {},
  }, Domino)
  local frame = CreateFrame("Button", nil, parent)
  frame:Hide()
  frame.domino = self
  self.frame = frame
  self.shadow = frame:CreateTexture(nil, "BACKGROUND")
  self.shadow:SetTexture(IMAGES .. "shadow")
  self.light = frame:CreateTexture(nil, "BORDER")
  self.light:SetTexture(IMAGES .. "glow")
  self.light:SetBlendMode("ADD")
  self.light:Hide()
  self.breathing = private.Widgets.Pulse(self.light)
  self.body = frame:CreateTexture(nil, "ARTWORK")
  tiles[self] = true
  return self
end

--- Shows a tile, or hides it
--- @param tile string? What is on it, as it lies; Dominoes.HIDDEN for its back, nil for nothing
--- @param style string? A look of its own, whatever the player chose
function Domino:Set(tile, style)
  if tile == self.tile and style == self.style then
    return
  end
  self.tile, self.style = tile, style
  self.frame:SetShown(tile ~= nil)
  self:paint()
end

--- Puts it somewhere
--- @param x number
--- @param y number
--- @param unit number
--- @param angle number
function Domino:Place(x, y, unit, angle)
  self.x, self.y, self.unit, self.angle = x, y, unit, angle
  self:paint()
end

--- @return DominoPlace
function Domino:Where()
  return { x = self.x, y = self.y, unit = self.unit, angle = self.angle }
end

--- Lifts it off the table, or puts it back down
--- @param lift number From 0, lying on it, to 1
function Domino:SetLift(lift)
  self.lift = lift
  self:paint()
end

--- Stands it up out of its place, or back into it
--- @param rise number Pixels
function Domino:SetRise(rise)
  if self.rise ~= rise then
    self.rise = rise
    self:paint()
  end
end

--- @param dim boolean It can't be played: darker than the rest
function Domino:SetDim(dim)
  if self.dim ~= dim then
    self.dim = dim
    self:paint()
  end
end

--- Lights it up round its edge
--- @param color number[]? Red, green, blue and how strong; nil for no light
--- @param breathe boolean? Swelling and dimming, to draw the eye
function Domino:SetLight(color, breathe)
  local light = self.light
  if not color then
    light:Hide()
    self.breathing:Stop()
    self.lit = nil
    return
  end
  light:SetVertexColor(color[1], color[2], color[3], color[4] or 1)
  light:Show()
  local key = breathe and "breathe" or "still"
  if self.lit ~= key then
    self.lit = key
    if breathe then
      self.breathing:Play()
    else
      self.breathing:Stop()
    end
  end
end

--- The look it has now
--- @return table
function Domino:look()
  return LOOKS[self.style or Dominoes.Style()] or LOOKS[Dominoes.STYLE]
end

--- The picture of its body
--- @param face boolean
--- @param lying boolean
--- @param pixels number How long it is on screen
--- @return string
function Domino:bodyTexture(face, lying, pixels)
  local size = pixels > BIG_PIXELS and "256" or "128"
  return IMAGES .. self:look().body .. (face and "Face" or "Back") .. (lying and "H" or "V") .. size
end

--- @param index number
--- @return Texture
function Domino:pip(index)
  local pip = self.pips[index]
  if not pip then
    pip = self.frame:CreateTexture(nil, "OVERLAY")
    self.pips[index] = pip
  end
  return pip
end

--- Draws it where it is, the way it is
function Domino:paint()
  local frame = self.frame
  if not self.tile then
    return
  end
  local unit = self.unit * (1 + LIFT_GROW * self.lift)
  local side = 2 * unit
  local angle, squash = self.angle, self.squash
  frame:SetSize(side, side)
  if not self.loose then
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", self.parent, "TOPLEFT", self.x, self.rise - self.y)
  end

  local cos, sin = math.cos(angle), math.sin(angle)
  local lying = math.abs(cos) >= math.abs(sin)
  -- Only the tile itself takes the mouse, not the room round it
  local inset = side / 4
  if lying then
    frame:SetHitRectInsets(0, 0, inset, inset)
  else
    frame:SetHitRectInsets(inset, inset, 0, 0)
  end
  -- What is left to turn from lying or standing, which the light stays put through
  local base = lying and 0 or math.pi / 2
  local turned = angle - base - math.pi * math.floor((angle - base) / math.pi + 0.5)
  local pictured = side / FILL
  local scale = frame:GetEffectiveScale() or 1
  local face = self.tile ~= Bones.HIDDEN
  local shade = self.dim and DIMMED or 1

  local body = self.body
  body:SetTexture(self:bodyTexture(face, lying, side * scale))
  body:SetSize(pictured * squash, pictured)
  body:ClearAllPoints()
  body:SetPoint("CENTER")
  body:SetRotation(-turned)
  body:SetVertexColor(shade, shade, shade)

  local fall = unit * (SHADOW_LYING + (SHADOW_LIFTED - SHADOW_LYING) * self.lift)
  self.shadow:SetSize(pictured * squash, pictured)
  self.shadow:ClearAllPoints()
  self.shadow:SetPoint("CENTER", fall * 0.6, -fall)
  self.shadow:SetRotation(-angle)
  self.shadow:SetAlpha(SHADOW_DARK + (SHADOW_LIFTED_DARK - SHADOW_DARK) * self.lift)
  self.light:SetSize(pictured * 1.2 * squash, pictured * 1.2)
  self.light:ClearAllPoints()
  self.light:SetPoint("CENTER")
  self.light:SetRotation(-angle)

  local used = 0
  if face then
    local look = self:look()
    local file = IMAGES .. (unit * scale > 22 and "pip64" or "pip32")
    -- The pips are laid out for a tile standing up, and turned the way this one lies
    local turn = angle - math.pi / 2
    local turnCos, turnSin = math.cos(turn), math.sin(turn)
    for half = 1, 2 do
      local pips = select(half, Bones.Ends(self.tile))
      local along = (half == 1 and -0.5 or 0.5) * unit
      local middleX, middleY = cos * along, sin * along
      local size = (pips > 9 and PIP_SMALL or PIP) * unit
      local color = look.numbered and look.numbered[pips] or look.pips
      for _, spot in ipairs(Dominoes.PipSpots(pips)) do
        used = used + 1
        local pip = self:pip(used)
        local x = middleX + (spot[1] * turnCos - spot[2] * turnSin) * unit
        local y = middleY + (spot[1] * turnSin + spot[2] * turnCos) * unit
        pip:SetTexture(file)
        pip:SetSize(size * squash, size)
        pip:ClearAllPoints()
        pip:SetPoint("CENTER", x * squash, -y)
        pip:SetVertexColor(color[1] * shade, color[2] * shade, color[3] * shade)
        pip:Show()
      end
    end
  end
  for index = used + 1, #self.pips do
    self.pips[index]:Hide()
  end
end

--- Moves it from where it is to somewhere else, over time
--- @param animator table Widgets.Animator, whose Stop puts it straight there
--- @param to DominoPlace
--- @param seconds number
--- @param options { delay: number?, ease: (fun(progress: number): number)?, arc: number?, reveal: string?, onStart: fun()?, onDone: fun()? }? arc lifts it on the way, from 0 to 1 at the highest. reveal turns it over halfway to show that tile
function Domino:Move(animator, to, seconds, options)
  options = options or {}
  local from
  local ease = options.ease or private.Widgets.Ease.inOut
  local arc, reveal, revealed = options.arc or 0, options.reveal, false
  animator:Play(seconds, function(progress)
    local along = ease(progress)
    local turn = to.angle - from.angle
    -- The short way round
    turn = turn - 2 * math.pi * math.floor(turn / (2 * math.pi) + 0.5)
    self.x = from.x + (to.x - from.x) * along
    self.y = from.y + (to.y - from.y) * along
    self.unit = from.unit + (to.unit - from.unit) * along
    self.angle = from.angle + turn * along
    self.lift = arc * math.sin(math.pi * progress)
    if reveal then
      -- Turned over about the middle of the way: squeezed to nothing and opened out again
      self.squash = math.abs(math.cos(math.pi * progress))
      if progress >= 0.5 and not revealed then
        revealed = true
        self.tile = reveal
      end
    end
    if progress >= 1 then
      self.angle, self.squash, self.lift = to.angle, 1, 0
    end
    self:paint()
  end, {
    delay = options.delay,
    onStart = function()
      from = self:Where()
      if options.onStart then
        options.onStart()
      end
    end,
    onDone = options.onDone,
  })
end

--- Turns it over where it lies, to show what is on it
--- @param animator table
--- @param tile string
--- @param seconds number
--- @param options { delay: number?, onDone: fun()? }?
function Domino:Reveal(animator, tile, seconds, options)
  options = options or {}
  local revealed = false
  animator:Play(seconds, function(progress)
    self.squash = math.abs(math.cos(math.pi * progress))
    self.lift = 0.5 * math.sin(math.pi * progress)
    if progress >= 0.5 and not revealed then
      revealed = true
      self.tile = tile
    end
    if progress >= 1 then
      self.squash, self.lift = 1, 0
    end
    self:paint()
  end, { delay = options.delay, onDone = options.onDone })
end

-----------------------------
-- The line of play
-----------------------------
-- The line starts in the middle of the table with its first tile lying across, a double
-- standing. Each arm goes out from it along the middle row, the left arm to the left and the
-- right to the right, a double standing across it as doubles are laid. An arm that gets to
-- the edge of the table turns, the right one down and the left one up, with a tile standing
-- on its end at the corner, and comes back along a row of its own, snaking on from edge to
-- edge for as long as it has to. Rows are two tiles' widths apart.
--
-- Everything is in units, from the middle of the first tile, y going down: the table it is
-- drawn on scales it to fit (Dominoes.Fit).

--- Where a tile of the line lies
--- @class DominoSpot
--- @field tile string As it lies, its first end the one laid against the line
--- @field x number
--- @field y number
--- @field angle number
--- @field side string? Bones.LEFT or Bones.RIGHT, nil for the first tile
--- @field index number? Where it is in its arm, from the first tile out

--- @class DominoSnake
--- @field first DominoSpot?
--- @field left DominoSpot[]
--- @field right DominoSpot[]
--- @field bounds number[] Left, top, right and bottom of all of it

--- @param angle number
--- @return number, number How far a tile lying that way reaches from its middle, across and down
local function reach(angle)
  local lying = math.abs(math.cos(angle)) >= math.abs(math.sin(angle))
  if lying then
    return 1, 0.5
  end
  return 0.5, 1
end

--- Where every tile of a line lies
--- @param line BonesLine
--- @param across number How many units wide the table is: an arm turns before it goes past the edge
--- @return DominoSnake
function Dominoes.Snake(line, across)
  local snake = { left = {}, right = {}, bounds = { 0, 0, 0, 0 } }
  if not line.first then
    return snake
  end
  local half = math.pi / 2
  local doubled = Bones.IsDouble(line.first)
  snake.first = { tile = line.first, x = 0, y = 0, angle = doubled and half or 0 }
  local start = doubled and 0.5 or 1
  local limit = math.max(across / 2, start + 2)
  local arms = { { tiles = line.left, side = Bones.LEFT, out = -1 }, { tiles = line.right, side = Bones.RIGHT, out = 1 } }
  for _, arm in ipairs(arms) do
    local spots = snake[arm.side == Bones.LEFT and "left" or "right"]
    -- Where the open end is, which way the arm goes along its row, and whether it is turning
    local endX, endY, way, down, turning = arm.out * start, 0, arm.out, arm.out, false
    for index, tile in ipairs(arm.tiles) do
      local spot = { tile = tile, side = arm.side, index = index }
      if turning then
        -- Out of the corner and back the other way along the next row
        way = -way
        spot.x, spot.y, spot.angle = endX + way * 0.5, endY + down * 0.5, way > 0 and 0 or math.pi
        endX, endY = endX + way * 1.5, endY + down * 0.5
        turning = false
      else
        local double = Bones.IsDouble(tile)
        local need = double and 1 or 2
        if math.abs(endX + way * need) > limit then
          -- Into the corner, standing on its end
          spot.x, spot.y, spot.angle = endX + way * 0.5, endY + down * 0.5, down > 0 and half or -half
          endX, endY = endX + way * 0.5, endY + down * 1.5
          turning = true
        elseif double then
          spot.x, spot.y, spot.angle = endX + way * 0.5, endY, half
          endX = endX + way
        else
          spot.x, spot.y, spot.angle = endX + way, endY, way > 0 and 0 or math.pi
          endX = endX + way * 2
        end
      end
      spots[index] = spot
    end
  end
  local bounds = snake.bounds
  local function grow(spot)
    local reachX, reachY = reach(spot.angle)
    bounds[1], bounds[2] = math.min(bounds[1], spot.x - reachX), math.min(bounds[2], spot.y - reachY)
    bounds[3], bounds[4] = math.max(bounds[3], spot.x + reachX), math.max(bounds[4], spot.y + reachY)
  end
  bounds[1], bounds[2], bounds[3], bounds[4] = math.huge, math.huge, -math.huge, -math.huge
  grow(snake.first)
  for _, spot in ipairs(snake.left) do
    grow(spot)
  end
  for _, spot in ipairs(snake.right) do
    grow(spot)
  end
  return snake
end

--- Where a tile would lie in a line if it were laid on an end of it
--- @param line BonesLine
--- @param tile string
--- @param side string? Nil for a line with nothing in it
--- @param across number
--- @return DominoSpot
function Dominoes.SpotFor(line, tile, side, across)
  local copy = Bones.CopyLine(line)
  Bones.Lay(copy, tile, side)
  local snake = Dominoes.Snake(copy, across)
  if not side or not line.first then
    return snake.first
  end
  local arm = snake[side == Bones.LEFT and "left" or "right"]
  return arm[#arm]
end

--- How big a unit is drawn for a line to fit a table, and where its middle is
--- @param bounds number[] Of the line, Dominoes.Snake's
--- @param width number Of the table, in pixels
--- @param height number
--- @param most number The biggest a unit may be
--- @return number unit, number middleX, number middleY The unit in pixels, and the middle of the line in units
function Dominoes.Fit(bounds, width, height, most)
  local wide, high = bounds[3] - bounds[1], bounds[4] - bounds[2]
  local unit = math.min(most, width / math.max(wide, 1), height / math.max(high, 1))
  return unit, (bounds[1] + bounds[3]) / 2, (bounds[2] + bounds[4]) / 2
end
