--------------------------
--  PanoView
--------------------------
-- Looking round from where a panorama was taken: drag to turn and look up and down, the wheel to
-- look closer. For a game that takes the player somewhere and asks them where they are.
--
-- A panorama is the inside of a cylinder round where it was taken, its width all the way round
-- and its height from `top` to `bottom`: heights on a cylinder of radius 1, the tangent of how
-- far above the horizon. It is a few pictures side by side (`tiles`), as one picture can only be
-- so wide, its left edge where the camera first looked and going round clockwise.
-- Tools/GeoBench makes them from the client's own screenshots.
--
-- The screen is drawn in columns (GUI/Strips.lua), each the slice of the cylinder it sees: a
-- column `x` across from the middle sees the cylinder at an angle atan(x / f) from where the
-- player looks, where the cylinder is 1 / cos of that away, so its slice is that much taller.
-- Within a column the slice maps onto it straight, top to bottom: exact to within the column's
-- width. It is how Doom drew its walls. A column that crosses from one picture to the next is
-- drawn as two. Looking up and down moves the picture up and down rather than tilt it, which is
-- fine for as far as a panorama goes above and below the horizon.
--
-- Let go of while turning, the view carries on a little and slows. Nothing is drawn again that
-- hasn't changed: a view at rest costs nothing.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- What a panorama is, see above
--- @class Panorama
--- @field folder string Where its pictures are, ending in a backslash
--- @field file string Its pictures' names, before "_1", "_2", ...
--- @field tiles integer
--- @field top number
--- @field bottom number
--- @field facing number? Which way its left edge looks, as GetPlayerFacing has it: radians anticlockwise from north
--- @field sky number[]? Colour above where it reaches, r g b
--- @field ground number[]? And below

--- @class PanoViewOptions
--- @field fov number? Degrees across the view sees, 80 if left out
--- @field columns integer? How many columns it is drawn in, one for every 3 of its units across if left out
--- @field compass boolean? Shows which way the view looks across its top

--- @class PanoView
--- @field frame Frame Size it with SetSize
--- @field yaw number Radians round from the panorama's left edge, clockwise
--- @field fov number Degrees across, now
local PanoView = {}
PanoView.__index = PanoView
private.PanoView = PanoView

local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local atan, tan, cos, pi = math.atan, math.tan, math.cos, math.pi
local TAU = 2 * pi

local FOV, MIN_FOV, MAX_FOV = 80, 30, 100
-- How many of its units across one column is, if not said
local COLUMN = 3
-- How quickly the view gets to the zoom it is going to: part of the way left a second
local ZOOM_LEFT = 0.0005
-- How quickly a flung view slows, part of its speed kept a second, the fastest it is flung, and
-- the slowest it goes on turning at
local CARRY, MAX_FLING, STILL = 0.03, 7, 0.02
-- Radians a second the keys turn it, and units a second they look up and down
local TURN, TILT = 1.4, 260
-- How much a notch of the wheel looks closer
local WHEEL = 0.85
-- Seconds it takes to come into sight
local FADE = 0.35
-- How far in from the window's edge the panorama's top and bottom may come, a part of its height
local EDGE = 0.15
local POINTS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

--- @param parent Frame
--- @param options PanoViewOptions?
--- @return PanoView
function PanoView.New(parent, options)
  options = options or {}
  local frame = CreateFrame("Frame", nil, parent)
  frame:EnableMouse(true)
  frame:EnableMouseWheel(true)
  --- @type PanoView
  local self = setmetatable({ frame = frame, width = 0, height = 0, yaw = 0, shear = 0, fov = options.fov or FOV,
    goalFov = options.fov or FOV, speed = 0, keys = {}, columns = options.columns, dirty = true, alpha = 1 }, PanoView)
  self.strips = private.Strips.New(frame, { width = 1, height = 1 })
  self.strips.frame:SetPoint("TOPLEFT")
  if options.compass then
    self:makeCompass()
  end

  frame:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" then
      self:grab()
    end
  end)
  frame:SetScript("OnMouseUp", function(_, button)
    if button == "LeftButton" then
      self.held = nil
    end
  end)
  frame:SetScript("OnMouseWheel", function(_, delta)
    self:Zoom(WHEEL ^ delta)
  end)
  frame:SetScript("OnUpdate", function(_, elapsed)
    self:advance(math.min(elapsed, 0.1))
  end)
  frame:SetScript("OnHide", function()
    self.held, self.speed, self.keys = nil, 0, {}
  end)
  return self
end

-----------------------------
-- Geometry
-----------------------------

--- How far from the screen the picture is, in the view's units, for the field of view now
function PanoView:focal()
  return self.width / 2 / tan(math.rad(self.fov) / 2)
end

--- Where the cursor is, right and down from the view's top left corner
function PanoView:cursor()
  local scale = self.frame:GetEffectiveScale()
  local x, y = GetCursorPosition()
  return x / scale - (self.frame:GetLeft() or 0), (self.frame:GetTop() or 0) - y / scale
end

--- Keeps looking up and down within what the panorama has
function PanoView:clampShear()
  local pano = self.pano
  if not pano then
    return
  end
  local f, room = self:focal(), self.height * (0.5 - EDGE)
  local up, down = max(0, f * pano.top - room), max(0, -f * pano.bottom - room)
  self.shear = max(-up, min(down, self.shear))
end

-----------------------------
-- Drawing
-----------------------------

--- @param self PanoView
local function draw(self)
  local strips, pano = self.strips, self.pano
  local width, height = self.width, self.height
  strips:Begin()
  if not pano or width <= 0 or height <= 0 then
    strips:Finish()
    return
  end
  local f = self:focal()
  local tiles, files = pano.tiles, self.files
  local yaw, shear, middle = self.yaw, self.shear, height / 2
  local alpha = self.alpha
  -- Above and below where the picture reaches, its own colours
  local horizon = max(0, min(height, middle - shear))
  local sky, ground = pano.sky or { 0.45, 0.55, 0.65 }, pano.ground or { 0.2, 0.2, 0.18 }
  if horizon > 0 then
    strips:Fill(0, 0, width, horizon, sky[1] * alpha, sky[2] * alpha, sky[3] * alpha)
  end
  if horizon < height then
    strips:Fill(0, horizon, width, height, ground[1] * alpha, ground[2] * alpha, ground[3] * alpha)
  end
  strips:SetLevel(private.Strips.LOWEST + 1)
  local columns = self.columns or max(60, min(640, floor(width / COLUMN)))
  local across = width / columns
  local half = width / 2
  for c = 0, columns - 1 do
    local x0, x1 = c * across - half, (c + 1) * across - half
    local a0, a1 = yaw + atan(x0 / f), yaw + atan(x1 / f)
    local stretch = f / cos(atan((x0 + x1) / 2 / f))
    local y0, y1 = middle - stretch * pano.top - shear, middle - stretch * pano.bottom - shear
    -- Where round the panorama, counted in its pictures
    local u0, u1 = a0 / TAU * tiles, a1 / TAU * tiles
    local k = floor(u0)
    local edge = k + 1
    if u1 <= edge + 1e-9 then
      strips:Quad(x0 + half, y0, x1 + half, y1, files[k % tiles + 1], u0 - k, min(1, u1 - k), 0, 1, alpha, alpha, alpha)
    else
      -- Across into the next picture: two pieces, cut where it begins
      local xb = f * tan(edge / tiles * TAU - yaw)
      strips:Quad(x0 + half, y0, xb + half, y1, files[k % tiles + 1], u0 - k, 1, 0, 1, alpha, alpha, alpha)
      strips:Quad(xb + half, y0, x1 + half, y1, files[edge % tiles + 1], 0, min(1, u1 - edge), 0, 1, alpha, alpha, alpha)
    end
  end
  strips:Finish()
  if self.compass then
    self:drawCompass(f)
  end
end

-----------------------------
-- Compass
-----------------------------

function PanoView:makeCompass()
  local compass = CreateFrame("Frame", nil, self.frame)
  compass:SetFrameLevel(self.frame:GetFrameLevel() + 5)
  compass:SetPoint("TOP", 0, -6)
  compass:SetSize(260, 22)
  local back = compass:CreateTexture(nil, "BACKGROUND")
  back:SetAllPoints()
  back:SetColorTexture(0, 0, 0, 0.45)
  local mark = compass:CreateTexture(nil, "OVERLAY")
  mark:SetColorTexture(1, 0.82, 0, 1)
  mark:SetSize(2, 22)
  mark:SetPoint("CENTER")
  local labels = {}
  for index, point in ipairs(POINTS) do
    local label = compass:CreateFontString(nil, "ARTWORK", index % 2 == 1 and "GameFontHighlight" or "GameFontDisableSmall")
    label:SetText(point)
    labels[index] = label
  end
  self.compass = { frame = compass, labels = labels }
end

--- Puts each point of the compass where it is in the view, those behind the player out of sight
function PanoView:drawCompass(f)
  local compass = self.compass
  local facing = self.pano and self.pano.facing
  compass.frame:SetShown(facing ~= nil)
  if not facing then
    return
  end
  -- Clockwise from north, where the middle of the view looks
  local heading = (self.yaw - facing) % TAU
  local width = compass.frame:GetWidth()
  for index, label in ipairs(compass.labels) do
    local off = ((index - 1) * pi / 4 - heading + pi) % TAU - pi
    -- The compass shows a little more than the view does, spread across its width
    local seen = math.rad(self.fov) * 0.75
    if abs(off) < seen then
      label:SetPoint("CENTER", compass.frame, "CENTER", off / seen * width / 2, 0)
      label:SetAlpha(1 - (abs(off) / seen) ^ 2)
      label:Show()
    else
      label:Hide()
    end
  end
end

-----------------------------
-- Moving
-----------------------------

function PanoView:grab()
  local x, y = self:cursor()
  self.held = { x = x, y = y, yaw = self.yaw, shear = self.shear }
  self.speed = 0
end

--- @param elapsed number
function PanoView:advance(elapsed)
  if not self.pano then
    return
  end
  local yaw, shear, fov, alpha = self.yaw, self.shear, self.fov, self.alpha
  if abs(self.goalFov - self.fov) > 0.01 then
    self.fov = self.goalFov + (self.fov - self.goalFov) * ZOOM_LEFT ^ elapsed
    self:clampShear()
  end
  local held = self.held
  if held and not IsMouseButtonDown("LeftButton") then
    self.held, held = nil, nil
  end
  if held then
    local x, y = self:cursor()
    local f = self:focal()
    local before = self.yaw
    -- The point that was taken hold of stays under the cursor
    self.yaw = held.yaw - (atan((x - self.width / 2) / f) - atan((held.x - self.width / 2) / f))
    self.shear = held.shear + (held.y - y)
    self:clampShear()
    -- Turned the shorter way round, not across where the yaw starts again
    local turned = (self.yaw - before + pi) % TAU - pi
    self.speed = max(-MAX_FLING, min(MAX_FLING, turned / max(elapsed, 0.001) * 0.5 + self.speed * 0.5))
  else
    local keys = self.keys
    local turn = (keys.right and 1 or 0) - (keys.left and 1 or 0)
    local tilt = (keys.up and 1 or 0) - (keys.down and 1 or 0)
    if turn ~= 0 then
      self.yaw, self.speed = self.yaw + turn * TURN * elapsed, 0
    elseif abs(self.speed) > STILL then
      self.yaw = self.yaw + self.speed * elapsed
      self.speed = self.speed * CARRY ^ elapsed
    else
      self.speed = 0
    end
    if tilt ~= 0 then
      self.shear = self.shear - tilt * TILT * elapsed
      self:clampShear()
    end
  end
  if self.fading then
    self.fading = self.fading + elapsed
    self.alpha = min(1, self.fading / FADE)
    if self.alpha >= 1 then
      self.fading = nil
    end
  end
  self.yaw = self.yaw % TAU
  if self.dirty or self.yaw ~= yaw or self.shear ~= shear or self.fov ~= fov or self.alpha ~= alpha then
    self.dirty = false
    draw(self)
  end
end

-----------------------------
-- Public
-----------------------------

--- @param width number
--- @param height number
function PanoView:SetSize(width, height)
  self.width, self.height = width, height
  self.frame:SetSize(width, height)
  self.strips.frame:SetSize(width, height)
  self.strips:Resize(width, height)
  self:clampShear()
  self.dirty = true
end

--- Shows a panorama, looking where it begins (or `yaw` round from there), coming into sight
--- @param pano Panorama?
--- @param yaw number? Radians clockwise from its left edge
--- @return boolean loaded Whether every one of its pictures could be found
function PanoView:Show(pano, yaw)
  self.pano, self.dirty = pano, true
  self.yaw, self.shear, self.speed, self.held = yaw or 0, 0, 0, nil
  self.fov, self.goalFov = self.goalFov, self.goalFov
  if not pano then
    draw(self)
    return false
  end
  local files, loaded = {}, true
  for tile = 1, pano.tiles do
    files[tile] = pano.folder .. pano.file .. "_" .. tile
  end
  self.files = files
  -- Whether the client has them, asked of a texture of the view's own that isn't seen
  local probe = self.probe or self.frame:CreateTexture(nil, "BACKGROUND")
  self.probe = probe
  probe:Hide()
  for _, file in ipairs(files) do
    loaded = loaded and probe:SetTexture(file) ~= false
  end
  self.alpha, self.fading = 0, 0
  return loaded
end

--- Looks closer (less than 1) or further
--- @param by number
function PanoView:Zoom(by)
  self.goalFov = max(MIN_FOV, min(MAX_FOV, self.goalFov * by))
end

--- Turns and looks up and down from the keys, while they are held: "left", "right", "up", "down"
--- @param key string
--- @param down boolean
function PanoView:Key(key, down)
  self.keys[key] = down or nil
end

--- Goes back to looking where the panorama begins, as when it was first shown
function PanoView:Reset()
  self.yaw, self.shear, self.speed, self.goalFov, self.dirty = 0, 0, 0, FOV, true
end

--- Which way the view looks: degrees clockwise from north, nil for a panorama that doesn't say
--- @return number?
function PanoView:Heading()
  local facing = self.pano and self.pano.facing
  return facing and math.deg((self.yaw - facing) % TAU) or nil
end
