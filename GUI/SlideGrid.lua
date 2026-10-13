--------------------------
--  Slide grid
--------------------------
-- Tiles that slide about on a grid, for games where the things on the squares travel: they are
-- pushed to one side, run into each other and become one, turn up out of nowhere. A board
-- (GUI/Board.lua) keeps a piece on every square and lets it glide home, which is no use when two
-- of them are on their way to the same square. Here a tile is a thing of its own that lies over
-- the grid, and can be anywhere on it, at any size and as see-through as it likes, whatever the
-- squares under it are doing.
--
-- A tile is a picture in white that is tinted, with something written on it, so it is sharp at
-- whatever size it is drawn. What a tile is worth is all the grid knows about it: the game says
-- how one that is worth so much looks (`style`), and the grid keeps the tiles, makes more as
-- they are needed and puts the ones that went away aside to be used again.
--
-- Squares are numbered along the rows, from 1 in the top left corner. Set puts a position on the
-- grid at once. Animate shows how it came about: which tiles went where, where those that
-- arrived became one, what appeared and what went away. Whatever is still on the move when
-- something else is asked for gets where it was going first, at once, so a player who is faster
-- than the tiles is never kept waiting and never sees them in the wrong place.
--
-- The grid can also be played on by dragging across it (Swipes), and shake its head at a move
-- that isn't one (Nudge).
--
-- Nothing here knows any rules. See Games/2048.lua.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class SlideGrid
--- @field frame Frame The tiles lie in it. Its OnUpdate and OnHide are taken
--- @field columns number
--- @field rows number
--- @field side number How long the side of a tile is
--- @field gap number How far the tiles lie apart
--- @field at table<number, Frame> The tile on each square, once everything has come to rest
--- @field spare Frame[] Tiles nobody needs at the moment
--- @field touch Frame? What takes the mouse, for a grid that is played on by dragging
--- @field press { x: number, y: number, swiped: boolean }? Where the button went down, while it is
--- @field style fun(value: any): string, number[], number[], number?
--- @field art string
local SlideGrid = {}
SlideGrid.__index = SlideGrid
private.SlideGrid = SlideGrid

-- Seconds a tile takes to get where it is going, however far that is
local SLIDE = 0.11
-- Seconds a tile that others became swells for, and by how much of its size
local POP, POP_SWELL = 0.17, 0.2
-- Seconds a tile takes to appear, and one that goes away to be gone
local GROW, SHRINK = 0.16, 0.1
-- A move that isn't one: for how long the tiles lean into it, and how far as a fraction of a tile
local NUDGE, NUDGE_REACH = 0.18, 0.09
-- How far the cursor has to travel with the button held to have said which way
local SWIPE_DISTANCE = 14
-- Frame levels, counted from the grid's: tiles at rest, tiles on their way, and what comes of them
local REST_LEVEL, MOVING_LEVEL, NEW_LEVEL = 1, 2, 3
-- Sizes of what is written on a tile as fractions of its side, by how many characters it is
local FIT = { 0.52, 0.5, 0.4, 0.32, 0.26, 0.22 }
local FIT_LONGER = 0.185
local SMALLEST_FONT = 6
-- The client has no size of nothing for a frame
local SMALLEST_SCALE = 0.01
-- How much bigger than its tile the light around it is drawn (GUI/Tiles.lua has the picture)
local GLOW_SCALE = 1.5

--- @param value any
--- @return boolean Whether it stands for a square with nothing on it
local function none(value)
  return value == nil or value == false or value == 0
end

--- @param parent Frame
--- @param options { art: string, style: fun(value: any): string, number[], number[], number? } `art` is the folder the picture of a tile is in, as <art><size>\tile at the sizes a board picks from (Board.TextureSize). `style` says how a tile worth something looks: what is written on it, the colour it is tinted, the colour of the writing and how strong the light around it is, from 0 to 1 or nothing for none
--- @return SlideGrid
function SlideGrid.New(parent, options)
  --- @type SlideGrid
  local self = setmetatable({ at = {}, spare = {}, columns = 0, rows = 0, side = 0, gap = 0, offX = 0, offY = 0 }, SlideGrid)
  self.art, self.style = options.art, options.style
  local frame = CreateFrame("Frame", nil, parent)
  frame.slideGrid = self
  self.frame = frame
  self.animator = private.Widgets.Animator(frame)
  -- Nothing goes on while nobody is looking: what was on its way has got there when it is shown again
  frame:SetScript("OnHide", function()
    self:Finish()
  end)
  return self
end

-----------------------------
-- Tiles
-----------------------------

--- How many screen pixels a tile covers, for picking a picture of the right size
--- @return number
function SlideGrid:pixels()
  local height = 768
  if GetPhysicalScreenSize then
    height = select(2, GetPhysicalScreenSize()) or height
  end
  return self.side * self.frame:GetEffectiveScale() * height / 768
end

--- Draws a tile where it is, at a size and as see-through as it is told
--- @param sprite Frame
--- @param scale number? 1 for the size tiles are
--- @param alpha number?
function SlideGrid:pose(sprite, scale, alpha)
  scale = math.max(SMALLEST_SCALE, scale or 1)
  if sprite.scale ~= scale then
    sprite.scale = scale
    sprite:SetScale(scale)
  end
  -- A frame that is scaled measures where it is anchored in its own, scaled, units
  sprite:ClearAllPoints()
  sprite:SetPoint("CENTER", self.frame, "TOPLEFT", (sprite.x + self.offX) / scale, -(sprite.y + self.offY) / scale)
  sprite:SetAlpha(alpha or 1)
end

--- Makes a tile look like what it is worth
--- @param sprite Frame
--- @param value any
function SlideGrid:paint(sprite, value)
  local side = self.side
  if sprite.side ~= side then
    sprite.side = side
    sprite:SetSize(side, side)
    sprite.glow:SetSize(side * GLOW_SCALE, side * GLOW_SCALE)
    sprite.font = nil
  end
  if sprite.path ~= self.path then
    sprite.path = self.path
    sprite.body:SetTexture(self.path)
  end
  if sprite.value == value and sprite.font then
    return
  end
  sprite.value = value
  local text, color, ink, glow = self.style(value)
  local size = math.max(SMALLEST_FONT, math.floor(side * (FIT[#text] or FIT_LONGER)))
  if sprite.font ~= size then
    sprite.font = size
    sprite.label:SetFont(STANDARD_TEXT_FONT, size, "")
  end
  sprite.label:SetText(text)
  sprite.label:SetTextColor(ink[1], ink[2], ink[3])
  sprite.body:SetVertexColor(color[1], color[2], color[3])
  sprite.glow:SetShown(glow ~= nil and glow > 0)
  if glow and glow > 0 then
    sprite.glow:SetVertexColor(color[1], color[2], color[3], glow)
  end
end

--- A tile to put on a square, a new one or one that was put aside
--- @param value any
--- @param square number
--- @param level number
--- @return Frame
function SlideGrid:acquire(value, square, level)
  local sprite = table.remove(self.spare)
  if not sprite then
    sprite = CreateFrame("Frame", nil, self.frame)
    sprite.glow = sprite:CreateTexture(nil, "BACKGROUND")
    sprite.glow:SetPoint("CENTER")
    sprite.glow:SetTexture(private.Tiles.GLOW)
    sprite.glow:SetBlendMode("ADD")
    sprite.body = sprite:CreateTexture(nil, "ARTWORK")
    sprite.body:SetAllPoints()
    sprite.label = sprite:CreateFontString(nil, "OVERLAY")
    sprite.label:SetPoint("CENTER", 0, 0)
    -- Nothing can be written without a font
    sprite.label:SetFont(STANDARD_TEXT_FONT, SMALLEST_FONT, "")
  end
  self:paint(sprite, value)
  sprite.x, sprite.y = self:Center(square)
  sprite:SetFrameLevel(self.frame:GetFrameLevel() + level)
  self:pose(sprite)
  sprite:Show()
  return sprite
end

--- Puts a tile aside
--- @param sprite Frame
function SlideGrid:release(sprite)
  sprite:Hide()
  self.spare[#self.spare + 1] = sprite
end

--- Makes what lies on the grid be a position and nothing else: every tile on its square, at
--- rest, saying what it is worth. Tiles that are right already are left as they are
--- @param cells table<number, any>
function SlideGrid:settle(cells)
  local level = self.frame:GetFrameLevel() + REST_LEVEL
  for square, sprite in pairs(self.at) do
    if square > self.columns * self.rows or none(cells[square]) then
      self:release(sprite)
      self.at[square] = nil
    end
  end
  for square = 1, self.columns * self.rows do
    local value, sprite = cells[square], self.at[square]
    if not none(value) then
      if sprite then
        self:paint(sprite, value)
        sprite.x, sprite.y = self:Center(square)
        sprite:SetFrameLevel(level)
        self:pose(sprite)
      else
        self.at[square] = self:acquire(value, square, REST_LEVEL)
      end
    end
  end
end

--- Lays what takes the mouse over the grid and the rim around it
function SlideGrid:spread()
  local touch = self.touch
  if touch then
    touch:ClearAllPoints()
    touch:SetPoint("TOPLEFT", self.frame, "TOPLEFT", -self.gap, self.gap)
    touch:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", self.gap, -self.gap)
  end
end

-----------------------------
-- Public
-----------------------------

--- Where the middle of a square is, right of and below the top left corner of the grid
--- @param square number
--- @return number x, number y
function SlideGrid:Center(square)
  local column, row = (square - 1) % self.columns, math.floor((square - 1) / self.columns)
  local pitch = self.side + self.gap
  return column * pitch + self.side / 2, row * pitch + self.side / 2
end

--- Says how big the grid is and how big its tiles are. What lies on it stays, on a grid of as
--- many squares, and is taken off one that isn't
--- @param columns number
--- @param rows number
--- @param side number How long the side of a tile is
--- @param gap number How far they lie apart
function SlideGrid:Arrange(columns, rows, side, gap)
  if columns == self.columns and rows == self.rows and side == self.side and gap == self.gap then
    return
  end
  self:Finish()
  local kept = {}
  if columns == self.columns and rows == self.rows then
    for square, sprite in pairs(self.at) do
      kept[square] = sprite.value
    end
  end
  self.columns, self.rows, self.side, self.gap = columns, rows, side, gap
  self.frame:SetSize(columns * (side + gap) - gap, rows * (side + gap) - gap)
  self.path = self.art .. private.Board.TextureSize(self:pixels()) .. "\\tile"
  self:spread()
  self:settle(kept)
end

--- Puts a position on the grid at once
--- @param cells table<number, any> What the tile on each square is worth, by square. nil, false or 0 for a square that has none
function SlideGrid:Set(cells)
  self:Finish()
  self:settle(cells)
end

--- Shows how a position came about. All of it is optional but the position it ends in, which
--- is what the grid shows when it is over whatever else it was told.
---
--- `moves` are the tiles that travel, each from a square to a square, and what they are worth on
--- the way: the tile on the square is taken, and where several leave the same square it comes
--- apart into as many. `merges` are the squares where the tiles that arrived become one, worth
--- something else, which swells for a moment. `appear` is what turns up once the others have
--- arrived, and `vanish` the squares whose tile goes away as they set out.
--- @param motion { moves: { from: number, to: number, value: any }[]?, merges: { at: number, value: any }[]?, appear: { at: number, value: any }[]?, vanish: number[]? }
--- @param cells table<number, any> The position afterwards, as for Set
--- @return number seconds Until the tiles that travel have arrived
function SlideGrid:Animate(motion, cells)
  self:Finish()
  local Ease = private.Widgets.Ease
  local animator, at = self.animator, self.at
  local level = self.frame:GetFrameLevel()

  local leaving = {}
  for _, square in ipairs(motion.vanish or {}) do
    if at[square] then
      leaving[#leaving + 1] = at[square]
      at[square] = nil
    end
  end

  -- Whoever travels leaves its square, and everything that doesn't stays where it is
  local movers, travels = {}, false
  for _, move in ipairs(motion.moves or {}) do
    local sprite = at[move.from]
    if sprite then
      at[move.from] = nil
      self:paint(sprite, move.value)
    else
      sprite = self:acquire(move.value, move.from, MOVING_LEVEL)
    end
    sprite:SetFrameLevel(level + MOVING_LEVEL)
    local toX, toY = self:Center(move.to)
    movers[#movers + 1] = { sprite = sprite, to = move.to, fromX = sprite.x, fromY = sprite.y, toX = toX, toY = toY }
    travels = travels or move.from ~= move.to
  end
  -- Only then do they take the squares they are going to: one of them may be another's
  local spent = {}
  for _, mover in ipairs(movers) do
    if at[mover.to] then
      spent[#spent + 1] = at[mover.to]
    end
    at[mover.to] = mover.sprite
  end

  -- What comes of them lies ready, and is shown when they get there
  local made, born = {}, {}
  for _, merge in ipairs(motion.merges or {}) do
    if at[merge.at] then
      spent[#spent + 1] = at[merge.at]
    end
    local sprite = self:acquire(merge.value, merge.at, NEW_LEVEL)
    sprite:Hide()
    at[merge.at], made[#made + 1] = sprite, sprite
  end
  for _, new in ipairs(motion.appear or {}) do
    if at[new.at] then
      spent[#spent + 1] = at[new.at]
    end
    local sprite = self:acquire(new.value, new.at, MOVING_LEVEL)
    sprite:Hide()
    at[new.at], born[#born + 1] = sprite, sprite
  end

  local landed = false
  -- The tiles have arrived: the ones that became one make way for it. Whichever of the things
  -- that wait for this comes first does it
  local function land()
    if landed then
      return
    end
    landed = true
    for _, sprite in ipairs(spent) do
      self:release(sprite)
    end
    for _, sprite in ipairs(made) do
      sprite:Show()
    end
  end

  local slide = travels and SLIDE or 0
  animator:Play(slide, function(progress)
    for _, mover in ipairs(movers) do
      local sprite = mover.sprite
      sprite.x = mover.fromX + (mover.toX - mover.fromX) * progress
      sprite.y = mover.fromY + (mover.toY - mover.fromY) * progress
      self:pose(sprite)
    end
  end, { ease = Ease.out, onDone = land })

  local after = 0
  if #leaving > 0 then
    animator:Play(SHRINK, function(progress)
      for _, sprite in ipairs(leaving) do
        self:pose(sprite, 1 - progress, 1 - progress)
      end
    end, {
      ease = Ease.into,
      onDone = function()
        for _, sprite in ipairs(leaving) do
          self:release(sprite)
        end
      end,
    })
    after = math.max(after, SHRINK - slide)
  end
  if #made > 0 then
    animator:Play(POP, function(progress)
      for _, sprite in ipairs(made) do
        self:pose(sprite, 1 + POP_SWELL * progress)
      end
    end, { delay = slide, ease = Ease.swell, onStart = land })
    after = math.max(after, POP)
  end
  if #born > 0 then
    animator:Play(GROW, function(progress)
      for _, sprite in ipairs(born) do
        self:pose(sprite, progress, math.min(1, progress * 2))
      end
    end, {
      delay = slide,
      ease = Ease.back,
      onStart = function()
        land()
        for _, sprite in ipairs(born) do
          sprite:Show()
        end
      end,
    })
    after = math.max(after, GROW)
  end
  -- And when all of it is over the grid shows the position, whatever it was told on the way
  animator:Play(0, function() end, {
    delay = slide + after,
    onDone = function()
      land()
      self:settle(cells)
    end,
  })
  return slide
end

--- The tiles lean one way and come back: a move that way isn't one
--- @param across number Which way: 1 for right, -1 for left
--- @param down number 1 for down, -1 for up
function SlideGrid:Nudge(across, down)
  self:Finish()
  local reach = self.side * NUDGE_REACH
  local function lean(progress)
    self.offX, self.offY = across * reach * progress, down * reach * progress
    for _, sprite in pairs(self.at) do
      self:pose(sprite)
    end
  end
  self.animator:Play(NUDGE, lean, {
    ease = private.Widgets.Ease.swell,
    onDone = function()
      lean(0)
    end,
  })
end

--- Whether anything is still on the move
--- @return boolean
function SlideGrid:Busy()
  return self.animator:Busy()
end

--- Takes everything that is on the move to where it was going, at once
function SlideGrid:Finish()
  self.animator:Stop()
end

--- Lets the grid be played on by dragging across it: press, pull one way, and that way is told
--- as soon as it is clear which it is. Pulling on without letting go tells the next one. A drag
--- may begin on the rim around the grid as well, as far out as the tiles lie apart.
--- @param onSwipe fun(across: number, down: number) Which way: 1, 0 for right, -1, 0 for left, 0, 1 for down and 0, -1 for up
--- @param onTap fun()? The grid was clicked without being pulled anywhere
function SlideGrid:Swipes(onSwipe, onTap)
  local touch = CreateFrame("Frame", nil, self.frame)
  touch:EnableMouse(true)
  self.touch = touch
  self:spread()

  --- @return number x, number y Where the cursor is, in the grid's units
  local function cursor()
    local x, y = GetCursorPosition()
    local scale = touch:GetEffectiveScale()
    return x / scale, y / scale
  end

  touch:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" then
      local x, y = cursor()
      self.press = { x = x, y = y, swiped = false }
    end
  end)
  touch:SetScript("OnUpdate", function()
    local press = self.press
    if not press then
      return
    end
    local x, y = cursor()
    local across, up = x - press.x, y - press.y
    if math.max(math.abs(across), math.abs(up)) >= SWIPE_DISTANCE then
      -- From here on it is another drag, for a player who goes on without letting go
      press.x, press.y, press.swiped = x, y, true
      if math.abs(across) >= math.abs(up) then
        onSwipe(across > 0 and 1 or -1, 0)
      else
        -- The screen is measured from the bottom up
        onSwipe(0, up > 0 and -1 or 1)
      end
    end
  end)
  touch:SetScript("OnMouseUp", function(_, button)
    local press = self.press
    if button == "LeftButton" and press then
      self.press = nil
      if not press.swiped and onTap then
        onTap()
      end
    end
  end)
  -- A button that is let go of while nobody is looking is never heard of
  touch:SetScript("OnHide", function()
    self.press = nil
  end)
end
