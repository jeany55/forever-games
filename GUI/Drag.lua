--------------------------
--  Drag
--------------------------
-- Carrying something from one part of a game to another: a tile from a rack onto a board, back
-- again, or to another place in the rack. A board moves its own pieces about by itself
-- (GUI/Board.lua), this is for whatever has to cross from one widget to the next.
--
-- A game makes one of these over everything it draws and tells it where things can be put down:
-- its targets. Whatever the player may pick up says so when the button goes down on it, with
-- Carry. From there on a picture of it follows the cursor, the targets get to show where it
-- would land, and letting go over one of them hands it over. Anywhere else it goes back to where
-- it came from.
--
-- A thing can be dragged, or picked up with a click and put down with another: a click is a
-- drag that went nowhere, and leaves the thing in hand. Any other button puts it back.
--
-- Nothing here knows what is carried or what a place to put it down is. Both are the game's own
-- values, handed back to it as they were given.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- Somewhere things can be put down
--- @class DragTarget
--- @field region Region The cursor has to be over it
--- @field clip Region? And over this one too, for a region that is partly out of sight (the window of a GUI/Viewport.lua)
--- @field spot fun(item: any): any? Where in it the thing carried would land if it were let go right now, nil if it can't go there. Asked every frame, so it has to be cheap
--- @field onHover fun(item: any, spot: any?)? Where it would land has changed, nil when that is nowhere in this target any more
--- @field onDrop fun(item: any, spot: any) It was let go there

--- What is carried looks like
--- @class DragLook
--- @field texture string? A picture of it
--- @field width number? How big the picture is drawn, before being lifted
--- @field height number?
--- @field puppet Region? For what one picture doesn't show: something of the game's own that is moved about instead. It has to belong to the frame things are carried on (drag.frame), and is shown and hidden as needed
--- @field from Region? Where it is picked up from: out of sight while it is carried, and where it goes back to
--- @field onReturn fun(item: any)? It was put back, and has got there

--- @class Drag
--- @field frame Frame
local Drag = {}
Drag.__index = Drag
private.Drag = Drag

-- Something carried is drawn a little larger, as if lifted
local LIFT = 1.15
-- Seconds it takes to go back where it came from
local RETURN = 0.18
-- How far the cursor has to travel with the button held before a click becomes a drag
local DRAG_DISTANCE = 4

--- @param parent Frame Everything things are carried across
--- @return Drag
function Drag.New(parent)
  --- @type Drag
  local self = setmetatable({ targets = {} }, Drag)
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetAllPoints()
  frame:SetFrameLevel(parent:GetFrameLevel() + 50)
  -- Only in the way of the mouse while something is in hand: the next click is then ours
  frame:EnableMouse(false)
  self.frame = frame
  self.texture = frame:CreateTexture(nil, "OVERLAY")
  self.texture:Hide()
  self.shown = self.texture

  frame:SetScript("OnUpdate", function(_, elapsed)
    self:advance(elapsed)
  end)
  frame:SetScript("OnMouseDown", function(_, button)
    if not self.item then
      return
    end
    if button == "LeftButton" then
      self:drop()
    else
      self:Cancel()
    end
  end)
  frame:SetScript("OnHide", function()
    self:Cancel(true)
  end)
  return self
end

-----------------------------
-- Geometry
-----------------------------

--- Where a point of the screen is, measured from the bottom left corner of the frame
--- @param x number In screen pixels
--- @param y number
--- @return number x, number y
function Drag:inside(x, y)
  local scale = self.frame:GetEffectiveScale()
  return x / scale - (self.frame:GetLeft() or 0), y / scale - (self.frame:GetBottom() or 0)
end

--- Whether the cursor is over a region
--- @param region Region
--- @return boolean
local function over(region)
  local left, top = region:GetLeft(), region:GetTop()
  if not left or not top then
    return false
  end
  -- A region measures itself by its own scale, which needn't be ours
  local scale = region:GetEffectiveScale()
  local x, y = GetCursorPosition()
  x, y = x / scale, y / scale
  return x >= left and x <= left + region:GetWidth() and y <= top and y >= top - region:GetHeight()
end

--- The target the thing carried would land in right now, and where in it
--- @return DragTarget?, any?
function Drag:find()
  for _, target in ipairs(self.targets) do
    if over(target.region) and (not target.clip or over(target.clip)) then
      local spot = target.spot(self.item)
      if spot ~= nil then
        return target, spot
      end
    end
  end
  return nil
end

--- Tells the targets where the thing carried would land, if that has changed
--- @param target DragTarget?
--- @param spot any?
function Drag:hover(target, spot)
  local was = self.over
  if target == was and spot == self.spot then
    return
  end
  self.over, self.spot = target, spot
  if was and was ~= target and was.onHover then
    was.onHover(self.item, nil)
  end
  if target and target.onHover then
    target.onHover(self.item, spot)
  end
end

--- Puts the picture where it is carried to
--- @param x number From the frame's bottom left corner
--- @param y number
function Drag:show(x, y)
  local shown = self.shown
  shown:ClearAllPoints()
  shown:SetPoint("CENTER", self.frame, "BOTTOMLEFT", x, y)
  shown:Show()
end

--- Nothing is in hand any more
--- @param look DragLook
function Drag:finish(look)
  self.shown:Hide()
  if look.from then
    look.from:SetAlpha(1)
  end
end

--- Lets go of the thing carried, wherever the cursor is
function Drag:drop()
  local target, spot = self:find()
  if not target then
    self:Cancel()
    return
  end
  local item, look = self.item, self.look
  self:hover(nil)
  self.item, self.look = nil, nil
  self.frame:EnableMouse(false)
  self:finish(look)
  target.onDrop(item, spot)
end

--- @param elapsed number
function Drag:advance(elapsed)
  local back = self.back
  if back then
    back.elapsed = back.elapsed + elapsed
    local left = (1 - math.min(1, back.elapsed / RETURN)) ^ 3
    self:show(back.toX + (back.fromX - back.toX) * left, back.toY + (back.fromY - back.toY) * left)
    if back.elapsed >= RETURN then
      self:land()
    end
  end
  if not self.item then
    return
  end

  local screenX, screenY = GetCursorPosition()
  local x, y = self:inside(screenX, screenY)
  self.x, self.y = x, y
  self:show(x, y)
  self:hover(self:find())

  if self.held then
    if not self.moved and math.abs(x - self.startX) + math.abs(y - self.startY) > DRAG_DISTANCE then
      self.moved = true
    end
    if not IsMouseButtonDown("LeftButton") then
      self.held = false
      -- Let go where it was picked up, it was a click: it stays in hand until the next one
      if self.moved then
        self:drop()
      end
    end
  end
end

--- What was on its way back has got there
function Drag:land()
  local back = self.back
  if not back then
    return
  end
  self.back = nil
  self:finish(back.look)
  if back.look.onReturn then
    back.look.onReturn(back.item)
  end
end

-----------------------------
-- Public
-----------------------------

--- Somewhere things can be put down. Where targets lie over each other, the one added first is
--- asked first, and the next one only if the thing can't go there
--- @param target DragTarget
function Drag:AddTarget(target)
  self.targets[#self.targets + 1] = target
end

--- Picks something up. Call it when the left button goes down on the thing: it is then dragged
--- for as long as the button is held, or stays in hand if the button is let go at once. Called
--- with no button held, it is in hand from the start
--- @param item any What it is, for the targets
--- @param look DragLook
function Drag:Carry(item, look)
  self:Cancel(true)
  self:land()
  self.item, self.look = item, look
  self.held, self.moved = IsMouseButtonDown("LeftButton") and true or false, false
  self.startX, self.startY = self:inside(GetCursorPosition())
  self.shown = look.puppet or self.texture
  if not look.puppet then
    self.texture:SetTexture(look.texture)
    self.texture:SetSize(look.width * LIFT, look.height * LIFT)
  end
  if look.from then
    look.from:SetAlpha(0)
  end
  self.frame:EnableMouse(true)
  self:advance(0)
end

--- @return any? What is in hand
function Drag:Carrying()
  return self.item
end

--- Puts what is in hand back where it came from
--- @param instant boolean? Without showing it going there
function Drag:Cancel(instant)
  local item, look = self.item, self.look
  if not item then
    return
  end
  self:hover(nil)
  self.item, self.look = nil, nil
  self.frame:EnableMouse(false)

  local from = look.from
  local toX, toY = nil, nil
  if from and not instant then
    local centreX, centreY = from:GetCenter()
    if centreX then
      local scale = from:GetEffectiveScale()
      toX, toY = self:inside(centreX * scale, centreY * scale)
    end
  end
  self.back = { item = item, look = look, fromX = self.x or 0, fromY = self.y or 0, toX = toX, toY = toY, elapsed = 0 }
  if not toX then
    self:land()
  end
end
