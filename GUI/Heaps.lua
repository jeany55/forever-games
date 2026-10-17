--------------------------
--  Heaps
--------------------------
-- Places that hold any number of small things that are all alike to the rules: seeds in the
-- pits of a mancala board, stones in the rows of a game of Nim, chips in a pot. The rules only
-- ever say how many are where. This draws them as things of their own, each lying where it fell
-- with its shadow under it, in a heap that grows over itself once there are more than the floor
-- of the place has room for, and writes how many there are beside it.
--
-- A game says where its places are, in units of its own, and what a token looks like. Show
-- puts so many in each place, at once. Carry and Gather show them being moved: Carry picks up
-- what is in a place and drops it one at a time into the places it is carried over, the way seeds
-- are sown, and Gather sweeps what is in one place into another. Either way the tokens are where
-- they end up as soon as it is asked for, and only seem to get there over the next moments: the
-- counts written by the places go up as each token lands. Busy says whether any are still on
-- their way, and Stop puts them there at once.
--
-- A token keeps the look it was given for as long as it is on the board, wherever it is moved:
-- the same red stone that was sown is the one that is taken. Which look a new one gets is
-- nobody's business but the eye's.
--
-- A place can be a row instead of a heap: its tokens lie side by side in spots of their own,
-- from the left, each in a hollow it leaves behind when it goes, the way stones are laid out for
-- a game of Nim. The last to come is the rightmost, and the first to go.
--
-- The player can point at places and click them, for a game played by picking one, or at one
-- token of a row, for a game played by picking stones (SetInput). The game can light places up
-- (SetHighlights) and lift tokens a little off the board to show which a move would take
-- (SetRaised). And it can lay the board out anew (SetPlaces), for one whose places depend on how
-- the game was set up.
--
-- Nothing here knows any game. See Games/Mancala.lua and Games/Nim.lua.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- Somewhere tokens lie. Distances are in the game's units, from the top left corner
--- @class HeapPlace
--- @field x number Its middle
--- @field y number
--- @field width number How wide the place is: an oval, or a long one with round ends. Pointing anywhere on it is pointing at the place
--- @field height number
--- @field floor number? How much of that tokens come to rest on, 0.8 if left out: a bowl has sides
--- @field label { x: number, y: number }? Where how many it holds is written, if anywhere
--- @field glow string? Texture lighting it up when it is highlighted, stretched over it and a little past its edge (GLOW_OVER). A soft round one if left out
--- @field row number? Its tokens lie in this many spots side by side across it instead of in a heap, the first on the left
--- @field bed { texture: string, size: number }? For a row: something drawn in every spot under its token, so big in units: the hollow it lies in

--- @class HeapsOptions
--- @field width number Room the whole takes, in units
--- @field height number
--- @field places table<any, HeapPlace> By whatever the game calls them
--- @field token number Width of a token, in units
--- @field looks number How many different looks there are for a token
--- @field textureFor fun(look: number, pixels: number): string, number[]? A token's texture, for one drawn at this many screen pixels, and the part of it the token is in: left, right, top, bottom
--- @field backdrop { texture: string, coords: number[]?, x: number?, y: number?, width: number?, height: number? }? A picture under it all, where it says in units, over the whole if it doesn't
--- @field shadow string? Texture under every token, darkened. A soft round one if left out
--- @field labelSize number? Height of what is written by the places, in units
--- @field labelColor number[]?
--- @field sounds { land: string?, pour: string? }? What a token dropped into a place sounds like, and a heap of them swept into one
--- @field raised number[]? Colour of the light under a token that is lifted (SetRaised), warm white if left out

--- How a place is lit up: a colour with alpha, steady, or breathing to draw the eye
--- @class HeapHighlight: number[]
--- @field pulse boolean?

--- What the player can do with the mouse. For a row, `index` says which of its spots is pointed
--- at, from 1 on the left, whether there is a token in it or not. It is nil for a heap
--- @class HeapsInput
--- @field pickable fun(place: any, index: number?): boolean Whether clicking there does anything right now
--- @field onClick fun(place: any, index: number?)
--- @field onHover (fun(place: any?, index: number?))? The cursor came onto somewhere it can click, or with nil left it

--- @class HeapToken
--- @field look number
--- @field face Texture
--- @field shadow Texture
--- @field place any Where it is, or is on its way to
--- @field x number Where it lies in its place, in units from the place's middle
--- @field y number
--- @field level number How high up the heap, 0 on the floor
--- @field flying boolean? Still on its way there
--- @field halo Texture? The light under it while it is lifted, made the first time it is
--- @field raised boolean? It is to be lifted off the board (SetRaised)
--- @field raise number? How far it is lifted now, from 0 to 1

--- @class Heaps
--- @field frame Frame
--- @field unit number Pixels to a unit
local Heaps = {}
Heaps.__index = Heaps
private.Heaps = Heaps

local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\"
local SOFT = IMAGES .. "glow"
-- A token's shadow: how dark, how much bigger than the token, and how far down and right it
-- falls for every unit the token is above the board. The light comes from the top left
local SHADOW_ALPHA, SHADOW_SIZE, SHADOW_FALL = 0.55, 1.25, 0.08
local SHADOW_SPREAD = 0.35
-- Tokens in the air are drawn bigger by this much for every unit they are lifted
local LIFT_SCALE = 0.45
-- Heaps are drawn in this many layers, the floor at the bottom
local LEVELS = 15
-- How a token finds somewhere to lie: so many places tried, the roomiest taken. A little nearer
-- the middle counts for something, as a heap falls inwards
local TRIES, PULL = 28, 0.25
-- Two tokens nearer than this, as a part of a token, lie one on top of the other
local OVERLAP = 0.72

-- Carrying: seconds to lift what is in the place, between one place and the next, and for a
-- token to drop. A long way round goes quicker, so that it never takes much longer than this
local LIFT_SECONDS, STEP_SECONDS, DROP_SECONDS = 0.22, 0.24, 0.13
local STEP_FASTEST, CARRY_MOST = 0.1, 3.2
-- How high tokens are carried, and how far apart they are held, in tokens
local CARRY_HEIGHT, HAND_SPREAD = 0.5, 0.55
-- Gathering: seconds a token takes, and how much later each sets off than the one before
local GATHER_SECONDS, GATHER_STAGGER, GATHER_HEIGHT = 0.42, 0.025, 0.7
-- A count that changes swells for a moment
local SWELL = { 1.35, 0.74 }
local LABEL_COLOR = { 1, 0.93, 0.78 }
-- How much bigger than its place a highlight is drawn, so that its light falls on the rim
local GLOW_OVER = 1.18
-- How much of a place tokens lie on, unless it says
local FLOOR = 0.8
-- A token that is lifted to show it would be taken: how high, in units, and seconds it takes to
-- get there. And the light under it, how much bigger than it
local RAISE_HEIGHT, RAISE_SECONDS, HALO_SIZE = 0.16, 0.09, 1.7
local RAISED = { 1, 0.86, 0.55, 0.85 }
-- Gathered one at a time, a few tokens are let go of with a little more time between them
local GATHER_EACH = 0.07

--- @param parent Frame
--- @param options HeapsOptions
--- @return Heaps
function Heaps.New(parent, options)
  local Widgets = private.Widgets
  --- @type Heaps
  local self = setmetatable({ options = options, unit = 1, enabled = false }, Heaps)
  self.tokens, self.pool, self.parts, self.highlights, self.spare = {}, {}, {}, {}, {}

  local frame = CreateFrame("Frame", nil, parent)
  frame:EnableMouse(true)
  self.frame = frame
  self.animator = Widgets.Animator(frame)

  local backdrop = options.backdrop
  if backdrop then
    self.backdrop = frame:CreateTexture(nil, "BACKGROUND")
    self.backdrop:SetTexture(backdrop.texture)
    if backdrop.coords then
      self.backdrop:SetTexCoord(unpack(backdrop.coords))
    end
  end

  for place, spot in pairs(options.places) do
    self.parts[place] = self:makeParts(spot)
    self.tokens[place] = {}
  end

  -- Tokens in the air go over everything on the board, the counts included
  self.air = CreateFrame("Frame", nil, frame)
  self.air:SetAllPoints()
  self.air:SetFrameLevel(frame:GetFrameLevel() + 5)

  frame:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" and self.enabled and self.input and self.over ~= nil then
      self.input.onClick(self.over, self.overIndex)
    end
  end)
  -- The animator has the frame's OnUpdate: following the cursor, and lifting tokens, take one of
  -- their own. Neither is anything to wait for
  local pointer = CreateFrame("Frame", nil, frame)
  pointer:SetScript("OnUpdate", function(_, elapsed)
    self:point()
    self:lifting(elapsed or 0)
  end)
  frame:SetScript("OnHide", function()
    self.animator:Stop()
    self:hover(nil)
  end)
  return self
end

--- The widgets that draw a place: its light, what is written by it and the hollows of a row.
--- From those of a place there no longer is, where there are any
--- @param spot HeapPlace
--- @return table
function Heaps:makeParts(spot)
  local Widgets, frame = private.Widgets, self.frame
  local parts = table.remove(self.spare)
  if not parts then
    parts = { beds = {} }
    parts.glow = frame:CreateTexture(nil, "BORDER", nil, 2)
    parts.glow:SetBlendMode("ADD")
    parts.breathe = Widgets.Pulse(parts.glow)
  end
  parts.glow:SetTexture(spot.glow or SOFT)
  parts.glow:Hide()
  parts.shown = nil
  if spot.label and not parts.label then
    -- A frame of its own, over the tokens, for the swell
    local holder = CreateFrame("Frame", nil, frame)
    holder:SetFrameLevel(frame:GetFrameLevel() + 3)
    holder:SetSize(1, 1)
    local label = holder:CreateFontString(nil, "OVERLAY")
    label:SetFont(STANDARD_TEXT_FONT, 12, "")
    label:SetPoint("CENTER")
    label:SetTextColor(unpack(self.options.labelColor or LABEL_COLOR))
    label:SetShadowColor(0, 0, 0, 0.9)
    local swell = label:CreateAnimationGroup()
    for order, scale in ipairs(SWELL) do
      local grow = swell:CreateAnimation("Scale")
      grow:SetOrder(order)
      grow:SetDuration(order == 1 and 0.07 or 0.15)
      grow:SetScale(scale, scale)
      grow:SetSmoothing(order == 1 and "OUT" or "IN")
    end
    parts.holder, parts.label, parts.swell = holder, label, swell
  end
  if parts.holder then
    parts.holder:SetShown(spot.label ~= nil)
    parts.label:SetText("")
  end
  local beds = spot.row and spot.bed and spot.row or 0
  for index = 1, math.max(beds, #parts.beds) do
    local bed = parts.beds[index]
    if index <= beds then
      if not bed then
        bed = frame:CreateTexture(nil, "BORDER", nil, 0)
        parts.beds[index] = bed
      end
      bed:SetTexture(spot.bed.texture)
      bed:Show()
    else
      bed:Hide()
    end
  end
  return parts
end

-----------------------------
-- Geometry
-----------------------------

--- Where a point of the board is drawn, from its top left corner
--- @param x number In units
--- @param y number
--- @return number x, number y In pixels
function Heaps:pixel(x, y)
  return x * self.unit, y * self.unit
end

--- Where a place is drawn, in pixels from the top left corner: for writing something by it
--- @param place any
--- @return number x, number y
function Heaps:PointOf(place)
  local spot = self.options.places[place]
  return self:pixel(spot.x, spot.y)
end

--- How many screen pixels a token covers, for picking a texture of the right size
--- @return number
function Heaps:pixels()
  local height = 768
  if GetPhysicalScreenSize then
    height = select(2, GetPhysicalScreenSize()) or height
  end
  return self.options.token * self.unit * self.frame:GetEffectiveScale() * height / 768
end

--- The place at a point, in units, if the point is on one, and for a row which of its spots
--- @param x number
--- @param y number
--- @return any? place, number? index
function Heaps:placeAt(x, y)
  for place, spot in pairs(self.options.places) do
    local dx, dy = (x - spot.x) / (spot.width / 2), (y - spot.y) / (spot.height / 2)
    if spot.row then
      -- A row is a box, its spots side by side across it
      if math.abs(dx) <= 1 and math.abs(dy) <= 1 then
        return place, math.min(spot.row, math.floor((dx + 1) / 2 * spot.row) + 1)
      end
    elseif dx * dx + dy * dy <= 1.1 then
      return place, nil
    end
  end
  return nil, nil
end

--- Where the middle of a spot of a row is, from the middle of the row
--- @param spot HeapPlace
--- @param index number
--- @return number
local function along(spot, index)
  return (index - (spot.row + 1) / 2) * spot.width / spot.row
end

--- How far a point is from the edge of a place's floor, as a part of the way out from its middle:
--- below 1 on it. A long place is a box with round ends
--- @param spot HeapPlace
--- @param x number From its middle
--- @param y number
--- @return number
local function outward(spot, x, y)
  local halfWidth, halfHeight = spot.width / 2, spot.height / 2
  if halfHeight > halfWidth then
    local straight = halfHeight - halfWidth
    local along = math.max(0, math.abs(y) - straight)
    return math.sqrt(x * x + along * along) / halfWidth
  elseif halfWidth > halfHeight then
    local straight = halfWidth - halfHeight
    local along = math.max(0, math.abs(x) - straight)
    return math.sqrt(along * along + y * y) / halfHeight
  end
  return math.sqrt(x * x + y * y) / halfWidth
end

--- Somewhere in a place for a token to lie, as far from the others there as it can, and how high
--- up the heap that is
--- @param place any
--- @return number x, number y, number level
function Heaps:spotFor(place)
  local spot, size = self.options.places[place], self.options.token
  if spot.row then
    -- The next spot along. More than a row has room for lie on top of the last
    local index = #self.tokens[place] + 1
    return along(spot, math.min(index, spot.row)), 0, math.max(0, math.min(index - spot.row, LEVELS - 1))
  end
  -- The floor less half a token, so that none hangs over its edge
  local floor = spot.floor or FLOOR
  local room = { width = math.max(0.01, spot.width * floor - size), height = math.max(0.01, spot.height * floor - size) }
  -- Those still on their way there count too: tokens swept in together don't land on each other
  local lying = {}
  for _, token in ipairs(self.tokens[place]) do
    if token.x then
      lying[#lying + 1] = token
    end
  end
  local bestX, bestY, bestScore = 0, 0, -math.huge
  for _ = 1, TRIES do
    local x, y
    repeat
      x, y = (math.random() * 2 - 1) * room.width / 2, (math.random() * 2 - 1) * room.height / 2
    until outward(room, x, y) <= 1
    local nearest = size * 2
    for _, other in ipairs(lying) do
      nearest = math.min(nearest, math.sqrt((x - other.x) ^ 2 + (y - other.y) ^ 2))
    end
    local score = nearest - PULL * size * outward(room, x, y)
    if score > bestScore then
      bestX, bestY, bestScore = x, y, score
    end
  end
  -- On top of whatever it lands on
  local level = 0
  for _, other in ipairs(lying) do
    if math.sqrt((bestX - other.x) ^ 2 + (bestY - other.y) ^ 2) < size * OVERLAP then
      level = math.max(level, other.level + 1)
    end
  end
  return bestX, bestY, math.min(level, LEVELS - 1)
end

-----------------------------
-- Drawing
-----------------------------

--- A token, from those put away or a new one
--- @param look number
--- @return HeapToken
function Heaps:newToken(look)
  local token = table.remove(self.pool)
  if not token then
    token = {
      face = self.frame:CreateTexture(nil, "ARTWORK"),
      shadow = self.frame:CreateTexture(nil, "BORDER", nil, 1),
    }
    token.shadow:SetTexture(self.options.shadow or SOFT)
    token.shadow:SetVertexColor(0, 0, 0)
  end
  token.look, token.flying = look, nil
  self:dress(token)
  return token
end

--- Gives a token its texture, for the size it is drawn at
--- @param token HeapToken
function Heaps:dress(token)
  local path, coords = self.options.textureFor(token.look, self:pixels())
  token.face:SetTexture(path)
  if coords then
    token.face:SetTexCoord(unpack(coords))
  end
end

--- @param token HeapToken
function Heaps:putAway(token)
  token.face:Hide()
  token.shadow:Hide()
  if token.halo then
    token.halo:Hide()
  end
  token.place, token.raised, token.raise = nil, nil, nil
  self.pool[#self.pool + 1] = token
end

--- Draws a token somewhere, in units, so high above the board
--- @param token HeapToken
--- @param x number
--- @param y number
--- @param height number In units
--- @param level number? Its layer in a heap. In the air if left out
function Heaps:draw(token, x, y, height, level)
  local unit, size = self.unit, self.options.token
  local scale = 1 + LIFT_SCALE * height
  local face, shadow = token.face, token.shadow
  if level then
    face:SetParent(self.frame)
    face:SetDrawLayer("ARTWORK", level - 7)
  else
    face:SetParent(self.air)
    face:SetDrawLayer("OVERLAY", 7)
  end
  face:SetSize(size * scale * unit, size * scale * unit)
  face:ClearAllPoints()
  face:SetPoint("CENTER", self.frame, "TOPLEFT", x * unit, -(y - height) * unit)
  face:Show()

  -- The shadow stays on the board, falls further away and gets softer the higher the token is
  local fall = (SHADOW_FALL + height * SHADOW_SPREAD) * size
  local spread = SHADOW_SIZE * (1 + height * 0.6)
  shadow:SetSize(size * spread * unit, size * spread * unit)
  shadow:SetAlpha(SHADOW_ALPHA / (1 + height * 1.5))
  shadow:ClearAllPoints()
  shadow:SetPoint("CENTER", self.frame, "TOPLEFT", (x + fall) * unit, -(y + fall) * unit)
  shadow:Show()
end

--- Draws a token where it lies in its place, lifted off it as far as it is
--- @param token HeapToken
function Heaps:rest(token)
  local spot = self.options.places[token.place]
  local raise = token.raise or 0
  local x, y = spot.x + token.x, spot.y + token.y
  self:draw(token, x, y, RAISE_HEIGHT * raise, token.level)
  if raise > 0 and not token.halo then
    token.halo = self.frame:CreateTexture(nil, "BORDER", nil, 3)
    token.halo:SetTexture(SOFT)
    token.halo:SetBlendMode("ADD")
  end
  if token.halo then
    local unit, size = self.unit, self.options.token * HALO_SIZE
    local color = self.options.raised or RAISED
    token.halo:SetVertexColor(color[1], color[2], color[3], (color[4] or 1) * raise)
    token.halo:SetSize(size * unit, size * unit)
    token.halo:ClearAllPoints()
    token.halo:SetPoint("CENTER", self.frame, "TOPLEFT", x * unit, -y * unit)
    token.halo:SetShown(raise > 0)
  end
end

--- Takes a token's light away, for one on the move
--- @param token HeapToken
local function dim(token)
  token.raised, token.raise = nil, nil
  if token.halo then
    token.halo:Hide()
  end
end

--- Writes how many tokens have got to a place
--- @param place any
--- @param quiet boolean? Without the swell
function Heaps:count(place, quiet)
  local parts = self.parts[place]
  if not parts.label then
    return
  end
  local count = 0
  for _, token in ipairs(self.tokens[place]) do
    if not token.flying then
      count = count + 1
    end
  end
  if count == parts.shown then
    return
  end
  parts.shown = count
  parts.label:SetText(tostring(count))
  if not quiet then
    parts.swell:Stop()
    parts.swell:Play()
  end
end

--- Fits it all into this much room. Units are whole pixels, so it can come out a little smaller:
--- read the result from heaps.unit
--- @param width number
--- @param height number
function Heaps:SetSize(width, height)
  local options = self.options
  local unit = math.max(1, math.floor(math.min(width / options.width, height / options.height)))
  if unit == self.unit and self.sized then
    return
  end
  self.unit, self.sized = unit, true
  self.frame:SetSize(unit * options.width, unit * options.height)
  self:arrange()
end

--- Puts everything where it belongs at the size it is drawn at
function Heaps:arrange()
  local options, unit = self.options, self.unit
  local backdrop = options.backdrop
  if backdrop then
    self.backdrop:ClearAllPoints()
    self.backdrop:SetPoint("TOPLEFT", (backdrop.x or 0) * unit, -(backdrop.y or 0) * unit)
    self.backdrop:SetSize((backdrop.width or options.width) * unit, (backdrop.height or options.height) * unit)
  end
  local font = math.max(9, math.floor((options.labelSize or 0.3) * unit))
  for place, spot in pairs(options.places) do
    local parts = self.parts[place]
    parts.glow:ClearAllPoints()
    parts.glow:SetPoint("CENTER", self.frame, "TOPLEFT", spot.x * unit, -spot.y * unit)
    parts.glow:SetSize(spot.width * unit * GLOW_OVER, spot.height * unit * GLOW_OVER)
    if spot.label then
      parts.label:SetFont(STANDARD_TEXT_FONT, font, "")
      parts.label:SetShadowOffset(1, -1)
      parts.holder:ClearAllPoints()
      parts.holder:SetPoint("CENTER", self.frame, "TOPLEFT", spot.label.x * unit, -spot.label.y * unit)
    end
    if spot.row and spot.bed then
      for index = 1, spot.row do
        local bed = parts.beds[index]
        bed:SetSize(spot.bed.size * unit, spot.bed.size * unit)
        bed:ClearAllPoints()
        bed:SetPoint("CENTER", self.frame, "TOPLEFT", (spot.x + along(spot, index)) * unit, -spot.y * unit)
      end
    end
  end
  self.animator:Stop()
  for _, tokens in pairs(self.tokens) do
    for _, token in ipairs(tokens) do
      self:dress(token)
      self:rest(token)
    end
  end
end

-----------------------------
-- Public
-----------------------------

--- Puts so many tokens in each place, at once. Tokens already in a place stay where they lie, the
--- last to come are the first to go, and new ones fall wherever there is room
--- @param counts table<any, number> By place
function Heaps:Show(counts)
  local same = true
  for place, tokens in pairs(self.tokens) do
    same = same and #tokens == (counts[place] or 0)
  end
  if same then
    return
  end
  self.animator:Stop()
  for place, tokens in pairs(self.tokens) do
    local wanted = counts[place] or 0
    while #tokens > wanted do
      self:putAway(table.remove(tokens))
    end
    while #tokens < wanted do
      local token = self:newToken(math.random(self.options.looks))
      token.place = place
      token.x, token.y, token.level = self:spotFor(place)
      tokens[#tokens + 1] = token
      self:rest(token)
    end
    self:count(place, true)
  end
end

--- Lays the board out anew, with other places. Every token there was is taken away: Show puts
--- them back
--- @param places table<any, HeapPlace>
function Heaps:SetPlaces(places)
  self.animator:Stop()
  self:hover(nil)
  for place, tokens in pairs(self.tokens) do
    for _, token in ipairs(tokens) do
      self:putAway(token)
    end
    local parts = self.parts[place]
    parts.breathe:Stop()
    parts.glow:Hide()
    if parts.holder then
      parts.holder:Hide()
    end
    for _, bed in ipairs(parts.beds) do
      bed:Hide()
    end
    self.spare[#self.spare + 1] = parts
  end
  self.options.places = places
  self.tokens, self.parts, self.highlights = {}, {}, {}
  for place, spot in pairs(places) do
    self.parts[place] = self:makeParts(spot)
    self.tokens[place] = {}
  end
  if self.sized then
    self:arrange()
  end
end

--- How many tokens each place holds, those still on their way there included
--- @return table<any, number>
function Heaps:Counts()
  local counts = {}
  for place, tokens in pairs(self.tokens) do
    counts[place] = #tokens
  end
  return counts
end

--- Takes a token out of its place, leaving the others lying where they are
--- @param token HeapToken
local function lift(self, token)
  local tokens = self.tokens[token.place]
  for index, other in ipairs(tokens) do
    if other == token then
      table.remove(tokens, index)
      break
    end
  end
end

--- Puts a token into a place, where it will lie once it gets there
--- @param token HeapToken
--- @param place any
function Heaps:settleInto(token, place)
  token.place = place
  token.x, token.y, token.level = self:spotFor(place)
  token.flying = true
  local tokens = self.tokens[place]
  tokens[#tokens + 1] = token
end

--- A token has got where it was going
--- @param token HeapToken
--- @param sound string?
function Heaps:land(token, sound)
  token.flying = nil
  self:rest(token)
  self:count(token.place)
  private.Widgets.PlaySound(sound)
end

--- Picks up everything in a place and carries it over the others, dropping a token into each
--- place it comes to: the way seeds are sown. A place can come up more than once, for a way that
--- goes all the way round
--- @param from any
--- @param stops any[] Where each token goes, in order
--- @param options { delay: number? }?
--- @return number seconds How long it takes, from when it was asked for
function Heaps:Carry(from, stops, options)
  local delay = options and options.delay or 0
  local hand = {}
  for index = #self.tokens[from], 1, -1 do
    hand[#hand + 1] = self.tokens[from][index]
  end
  if #hand == 0 then
    return delay
  end
  local sounds = self.options.sounds or {}
  local places, size = self.options.places, self.options.token
  local step = math.max(STEP_FASTEST, math.min(STEP_SECONDS, (CARRY_MOST - LIFT_SECONDS) / #stops))

  -- Where each token was, and where it is held in the hand: in a little bunch round its middle
  local start, held = {}, {}
  for index, token in ipairs(hand) do
    local spot = places[from]
    start[index] = { spot.x + token.x, spot.y + token.y }
    local angle = index * 2.4
    local reach = HAND_SPREAD * size * math.sqrt(index - 1) * 0.6
    held[index] = { math.cos(angle) * reach, math.sin(angle) * reach * 0.7 }
    lift(self, token)
    dim(token)
    token.flying = true
  end
  -- Each one goes where it is going, in the order it is let go of. Any more than there are
  -- places for are put back
  local count = math.min(#hand, #stops)
  for index = 1, #hand do
    self:settleInto(hand[index], stops[index] or from)
    if index > count then
      self:land(hand[index])
    end
  end
  self:count(from)

  --- Where the hand is a time into the carrying
  local function handAt(time)
    local spot = places[from]
    if time <= LIFT_SECONDS then
      return spot.x, spot.y
    end
    local along = (time - LIFT_SECONDS) / step
    local stop = math.min(count, math.floor(along) + 1)
    local before = stop == 1 and spot or places[stops[stop - 1]]
    local after = places[stops[stop]]
    local progress = private.Widgets.Ease.inOut(math.min(1, along - (stop - 1)))
    return before.x + (after.x - before.x) * progress, before.y + (after.y - before.y) * progress
  end
  -- A token is let go of as the hand gets over its place
  local function letGo(index)
    return LIFT_SECONDS + index * step
  end
  local total = letGo(count) + DROP_SECONDS

  self.animator:Play(total - DROP_SECONDS, function(progress)
    local time = progress * (total - DROP_SECONDS)
    local handX, handY = handAt(time)
    local rise = math.min(1, time / LIFT_SECONDS)
    for index = 1, count do
      local token = hand[index]
      if time < letGo(index) and token.flying then
        local eased = private.Widgets.Ease.out(rise)
        local x = start[index][1] + (handX + held[index][1] - start[index][1]) * eased
        local y = start[index][2] + (handY + held[index][2] - start[index][2]) * eased
        self:draw(token, x, y, CARRY_HEIGHT * eased)
      end
    end
  end, { delay = delay })

  for index = 1, count do
    local token, spot = hand[index], places[stops[index]]
    local fromX, fromY
    self.animator:Play(DROP_SECONDS, function(progress)
      if not fromX then
        -- From wherever it is held as it is let go of
        local handX, handY = handAt(letGo(index))
        fromX, fromY = handX + held[index][1], handY + held[index][2]
      end
      local toX, toY = spot.x + token.x, spot.y + token.y
      local x, y = fromX + (toX - fromX) * progress, fromY + (toY - fromY) * progress
      self:draw(token, x, y, CARRY_HEIGHT * (1 - progress * progress))
    end, {
      delay = delay + letGo(index),
      onDone = function()
        self:land(token, sounds.land)
      end,
    })
  end
  return delay + total
end

--- Sweeps what is in one place into another, all of it or so many, each token on its own way
--- there a moment after the one before
--- @param from any
--- @param to any
--- @param options { delay: number?, count: number?, quiet: boolean?, each: boolean? }? quiet leaves the sound out, for one of many at once. each lets the tokens go one at a time, each with the sound of one landing
--- @return number seconds How long it takes, from when it was asked for
function Heaps:Gather(from, to, options)
  options = options or {}
  local delay = options.delay or 0
  local tokens = self.tokens[from]
  local count = math.min(options.count or #tokens, #tokens)
  if count == 0 then
    return delay
  end
  local sounds = self.options.sounds or {}
  local places = self.options.places
  local moving = {}
  for index = 1, count do
    moving[index] = tokens[#tokens - index + 1]
  end
  local starts = {}
  for index, token in ipairs(moving) do
    local spot = places[token.place]
    -- From as high as it was lifted
    starts[index] = { spot.x + token.x, spot.y + token.y, RAISE_HEIGHT * (token.raise or 0) }
    lift(self, token)
    dim(token)
    self:settleInto(token, to)
  end
  self:count(from)

  local spot = places[to]
  local stagger = options.each and GATHER_EACH or GATHER_STAGGER
  for index, token in ipairs(moving) do
    local start = starts[index]
    self.animator:Play(GATHER_SECONDS, function(progress)
      local eased = private.Widgets.Ease.inOut(progress)
      local x = start[1] + (spot.x + token.x - start[1]) * eased
      local y = start[2] + (spot.y + token.y - start[2]) * eased
      self:draw(token, x, y, start[3] * (1 - eased) + GATHER_HEIGHT * math.sin(progress * math.pi))
    end, {
      delay = delay + (index - 1) * stagger,
      onStart = index == 1 and not options.quiet and not options.each and function()
        private.Widgets.PlaySound(sounds.pour)
      end or nil,
      onDone = function()
        self:land(token, options.each and not options.quiet and sounds.land or nil)
      end,
    })
  end
  return delay + (count - 1) * stagger + GATHER_SECONDS
end

--- Does something once the tokens have got so far: plays a sound as they land, say. Stop does
--- it at once, and Busy waits for it
--- @param seconds number From now
--- @param action fun()
function Heaps:Then(seconds, action)
  self.animator:Play(0, function() end, { delay = seconds, onDone = action })
end

--- Whether any tokens are still on their way
--- @return boolean
function Heaps:Busy()
  return self.animator:Busy()
end

--- Puts every token that is on its way where it is going, at once
function Heaps:Stop()
  self.animator:Stop()
end

--- Lights places up
--- @param colors table<any, HeapHighlight> By place, the others aren't lit
function Heaps:SetHighlights(colors)
  for place, parts in pairs(self.parts) do
    local color = colors[place]
    local shown = self.highlights[place]
    if color ~= shown then
      self.highlights[place] = color
      if color then
        parts.glow:SetVertexColor(color[1], color[2], color[3], color[4] or 1)
        parts.glow:Show()
        -- A breath already under way is left alone, so that it doesn't skip a beat
        if color.pulse and not (shown and shown.pulse) then
          parts.breathe:Play()
        elseif not color.pulse then
          parts.breathe:Stop()
        end
      else
        parts.breathe:Stop()
        parts.glow:Hide()
      end
    end
  end
end

--- Lifts tokens a little off the board, with a light under them: the ones a move would take.
--- They rise and settle back smoothly
--- @param raised table<any, number> By place, how many of its last tokens: the rightmost of a row
function Heaps:SetRaised(raised)
  for place, tokens in pairs(self.tokens) do
    local count = raised[place] or 0
    for index, token in ipairs(tokens) do
      token.raised = not token.flying and index > #tokens - count or nil
    end
  end
end

--- Moves the tokens that are being lifted or let down a little further along
--- @param elapsed number Seconds since the last frame
function Heaps:lifting(elapsed)
  local step = elapsed / RAISE_SECONDS
  for _, tokens in pairs(self.tokens) do
    for _, token in ipairs(tokens) do
      local raise, target = token.raise or 0, token.raised and 1 or 0
      if raise ~= target and not token.flying then
        token.raise = raise < target and math.min(target, raise + step) or math.max(target, raise - step)
        self:rest(token)
      end
    end
  end
end

--- @param input HeapsInput
function Heaps:SetInput(input)
  self.input = input
end

--- Whether the player can click places right now
--- @param enabled boolean
function Heaps:SetEnabled(enabled)
  self.enabled = enabled
  if not enabled then
    self:hover(nil)
  end
end

--- @param place any?
--- @param index number?
function Heaps:hover(place, index)
  if place == self.over and index == self.overIndex then
    return
  end
  self.over, self.overIndex = place, index
  if self.input and self.input.onHover then
    self.input.onHover(place, index)
  end
end

--- Follows the cursor over the places that can be clicked
function Heaps:point()
  if not self.enabled or not self.input or not self.frame:IsMouseOver() then
    self:hover(nil)
    return
  end
  local scale = self.frame:GetEffectiveScale()
  local x, y = GetCursorPosition()
  x, y = x / scale - (self.frame:GetLeft() or 0), (self.frame:GetTop() or 0) - y / scale
  local place, index = self:placeAt(x / self.unit, y / self.unit)
  if place ~= nil and not self.input.pickable(place, index) then
    place, index = nil, nil
  end
  self:hover(place, index)
end
