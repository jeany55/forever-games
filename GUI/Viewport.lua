--------------------------
--  Viewport
--------------------------
-- A window onto something that can be looked at closer: a board with more squares than there is
-- room to show at a size worth looking at. The mouse wheel zooms in on whatever the cursor is
-- over and back out until it all fits again, and what doesn't fit can be dragged about. It never
-- shows more of its edges than it has to: what fits lies in the middle, and what doesn't can't
-- be pushed further than its own edge.
--
-- A game puts what it draws into `content` and says how big that is when it all fits. Zooming
-- scales the content, it isn't laid out again: nothing in it has to know. Whatever asks where
-- the cursor is by its own frame's scale (GUI/Board.lua does) goes on working zoomed.
--
-- The viewport takes the wheel wherever it is. Dragging is the game's to hand over, as it knows
-- which clicks are for its pieces: see Grab. While the player carries something a game may also
-- let the view follow the cursor to the edge, see EdgeScroll.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class ViewportOptions
--- @field maxZoom number? How many times its fitted size the content can be shown at, 3 if left out
--- @field onSettle fun(zoom: number)? The content has come to rest at another zoom, for drawing it sharper

--- @class Viewport
--- @field frame Frame The window
--- @field content Frame What is looked at, for the game to put its things in
--- @field zoom number How many times its fitted size the content is shown at right now
--- @field x number Where the content's top left corner is, right of the window's
--- @field y number And below it
--- @field dragged boolean The content came along since it was last taken hold of: that was a drag, not a click
local Viewport = {}
Viewport.__index = Viewport
private.Viewport = Viewport

local MAX_ZOOM = 3
-- How much closer one notch of the wheel goes
local STEP = 1.25
-- This near to fitting, it fits
local SNAP = 0.04
-- Seconds it takes to get where it is going
local GLIDE = 0.22
-- How far the cursor has to travel with the button held before the content comes along
local DRAG_DISTANCE = 4
-- How near an edge of the window the cursor has to be for EdgeScroll to move the view, and how
-- fast it then goes, in units a second
local EDGE, EDGE_SPEED = 32, 480

--- @param parent Frame
--- @param options ViewportOptions?
--- @return Viewport
function Viewport.New(parent, options)
  options = options or {}
  --- @type Viewport
  local self = setmetatable({ zoom = 1, x = 0, y = 0, dragged = false, width = 0, height = 0, contentWidth = 0, contentHeight = 0 }, Viewport)
  self.maxZoom, self.onSettle = options.maxZoom or MAX_ZOOM, options.onSettle
  self.settled = 1

  local frame = CreateFrame("Frame", nil, parent)
  if frame.SetClipsChildren then
    frame:SetClipsChildren(true)
  end
  frame:EnableMouse(true)
  frame:EnableMouseWheel(true)
  self.frame = frame
  self.content = CreateFrame("Frame", nil, frame)

  frame:SetScript("OnMouseWheel", function(_, delta)
    self:Wheel(delta)
  end)
  -- Only where the content doesn't cover the window: over it, the clicks are the game's
  frame:SetScript("OnMouseDown", function(_, button)
    self:Grab(button)
  end)
  frame:SetScript("OnUpdate", function(_, elapsed)
    self:advance(elapsed)
  end)
  frame:SetScript("OnHide", function()
    self.grab = nil
    self:arrive()
  end)
  return self
end

-----------------------------
-- Geometry
-----------------------------

--- Where the cursor is, right and down from the window's top left corner
--- @return number x, number y
function Viewport:cursor()
  local scale = self.frame:GetEffectiveScale()
  local x, y = GetCursorPosition()
  return x / scale - (self.frame:GetLeft() or 0), (self.frame:GetTop() or 0) - y / scale
end

--- The nearest place the content may be at a zoom
--- @param zoom number
--- @param x number
--- @param y number
--- @return number x, number y
function Viewport:clamp(zoom, x, y)
  --- @param room number
  --- @param size number
  --- @param at number
  local function along(room, size, at)
    if size <= room then
      return (room - size) / 2
    end
    return math.max(room - size, math.min(0, at))
  end
  return along(self.width, self.contentWidth * zoom, x), along(self.height, self.contentHeight * zoom, y)
end

--- Shows the content where it is
function Viewport:place()
  local content = self.content
  content:SetScale(self.zoom)
  content:ClearAllPoints()
  -- A frame is put where it goes by its own measure, which the scale has changed
  content:SetPoint("TOPLEFT", self.frame, "TOPLEFT", self.x / self.zoom, -self.y / self.zoom)
end

--- Where it is going, or where it is if it isn't going anywhere
--- @return number zoom, number x, number y
function Viewport:goal()
  local move = self.move
  if move then
    return move.toZoom, move.toX, move.toY
  end
  return self.zoom, self.x, self.y
end

--- Sets out for another zoom and place
--- @param zoom number
--- @param x number
--- @param y number
--- @param instant boolean?
function Viewport:glide(zoom, x, y, instant)
  x, y = self:clamp(zoom, x, y)
  self.move = { fromZoom = self.zoom, fromX = self.x, fromY = self.y, toZoom = zoom, toX = x, toY = y, elapsed = 0 }
  if instant then
    self:arrive()
  end
end

--- Gets it at once to wherever it is going
function Viewport:arrive()
  local move = self.move
  if move then
    self.move = nil
    self.zoom, self.x, self.y = move.toZoom, move.toX, move.toY
    self:place()
  end
  if self.zoom ~= self.settled then
    self.settled = self.zoom
    if self.onSettle then
      self.onSettle(self.zoom)
    end
  end
end

--- @param elapsed number
function Viewport:advance(elapsed)
  local grab = self.grab
  if grab then
    if not IsMouseButtonDown(grab.button) then
      self.grab = nil
      return
    end
    local x, y = self:cursor()
    if not grab.moved and math.abs(x - grab.cursorX) + math.abs(y - grab.cursorY) > DRAG_DISTANCE then
      grab.moved = true
    end
    if grab.moved then
      self.dragged = true
      self.x, self.y = self:clamp(self.zoom, grab.x + x - grab.cursorX, grab.y + y - grab.cursorY)
      self:place()
    end
    return
  end

  local move = self.move
  if not move then
    return
  end
  move.elapsed = move.elapsed + elapsed
  local progress = math.min(1, move.elapsed / GLIDE)
  if progress >= 1 then
    self:arrive()
    return
  end
  -- Fast at first and settling. Zoom is a matter of how many times, so it goes by ratio
  local eased = 1 - (1 - progress) ^ 3
  local along = eased
  if move.toZoom ~= move.fromZoom then
    self.zoom = move.fromZoom * (move.toZoom / move.fromZoom) ^ eased
    -- The place goes with the zoom, not with the time: that is what keeps the one point of the
    -- content that is to stay where it is from wandering off on the way
    along = (self.zoom - move.fromZoom) / (move.toZoom - move.fromZoom)
  end
  self.x, self.y = move.fromX + (move.toX - move.fromX) * along, move.fromY + (move.toY - move.fromY) * along
  self:place()
end

-----------------------------
-- Public
-----------------------------

--- How much room the window has
--- @param width number
--- @param height number
function Viewport:SetSize(width, height)
  self.width, self.height = width, height
  self.frame:SetSize(width, height)
  self:arrive()
  self.x, self.y = self:clamp(self.zoom, self.x, self.y)
  self:place()
end

--- How big the content is when it all fits. The game sees to it that it does: no bigger than the window
--- @param width number
--- @param height number
function Viewport:SetContentSize(width, height)
  self.contentWidth, self.contentHeight = width, height
  self.content:SetSize(width, height)
  self:arrive()
  self.x, self.y = self:clamp(self.zoom, self.x, self.y)
  self:place()
end

--- Turns the wheel: towards whatever the cursor is over, or back away from it
--- @param delta number Notches, forward is closer
function Viewport:Wheel(delta)
  local goal = self:goal()
  local zoom = math.max(1, math.min(self.maxZoom, goal * STEP ^ delta))
  if zoom < 1 + SNAP then
    zoom = 1
  end
  if zoom == goal then
    return
  end
  -- The point of the content under the cursor stays under it
  local x, y = self:cursor()
  local pointX, pointY = (x - self.x) / self.zoom, (y - self.y) / self.zoom
  self:glide(zoom, x - pointX * zoom, y - pointY * zoom)
end

--- Goes to a zoom with a point of the content in the middle of the window, or as near to it as
--- the edges allow
--- @param zoom number
--- @param x number The point, right and down from the content's top left corner at its fitted size
--- @param y number
--- @param instant boolean? Without gliding there
function Viewport:ZoomTo(zoom, x, y, instant)
  zoom = math.max(1, math.min(self.maxZoom, zoom))
  self:glide(zoom, self.width / 2 - x * zoom, self.height / 2 - y * zoom, instant)
end

--- Goes back to showing all of it
--- @param instant boolean?
function Viewport:Fit(instant)
  self:glide(1, 0, 0, instant)
end

--- Whether all of the content is in sight, or will be once it has got where it is going
--- @return boolean
function Viewport:Fits()
  return (self:goal()) == 1
end

--- Takes hold of the content: it follows the cursor until the button is let go. For a game to
--- call when a button went down on something of its own that it has no other use for
--- @param button string? The button that is held, the left one if left out
function Viewport:Grab(button)
  self:arrive()
  self.dragged = false
  local x, y = self:cursor()
  self.grab = { button = button or "LeftButton", cursorX = x, cursorY = y, x = self.x, y = self.y, moved = false }
end

--- Moves the view along while the cursor is near an edge of the window, to bring what lies
--- beyond it into reach. For a game to call every frame while the player carries something
--- @param elapsed number
function Viewport:EdgeScroll(elapsed)
  if self.grab or self.move then
    return
  end
  local x, y = self:cursor()
  if x < 0 or y < 0 or x > self.width or y > self.height then
    return
  end
  --- @param at number
  --- @param room number
  --- @return number Which way the content goes: towards the far edge if the cursor is at the near one
  local function pull(at, room)
    return (at < EDGE and 1 or 0) - (at > room - EDGE and 1 or 0)
  end
  local byX, byY = pull(x, self.width), pull(y, self.height)
  if byX == 0 and byY == 0 then
    return
  end
  local step = EDGE_SPEED * elapsed
  local toX, toY = self:clamp(self.zoom, self.x + byX * step, self.y + byY * step)
  if toX ~= self.x or toY ~= self.y then
    self.x, self.y = toX, toY
    self:place()
  end
end
