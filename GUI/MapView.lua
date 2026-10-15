--------------------------
--  MapView
--------------------------
-- The client's own map of the world, in a window of a game's, to point at places on: for a game
-- that asks where somewhere is. It is drawn from the client's map art (C_Map.GetMapArtLayers and
-- GetMapArtLayerTextures, the tiles its world map is made of) and looked round in a Viewport:
-- the wheel zooms, dragging moves it.
--
-- Zooming goes on past the map's own detail into the zone under the cursor: turn the wheel on
-- far enough over Elwynn Forest on the Eastern Kingdoms and the map becomes Elwynn's, turn it
-- back out past the whole of Elwynn and it is the Eastern Kingdoms again, with Elwynn where it
-- was. The zone under the cursor is lit up as the world map lights it, and named.
--
-- What is pointed at is a place in the world (Engine/Places.lua), not a spot on one map: a click
-- is put into the world's yards by the client (GetWorldPosFromMapPos), and every pin is put back
-- onto whichever map is shown (GetMapPosFromWorldPos), so a guess made on Elwynn's map is where
-- it should be on the continent's. A pin off the map shown isn't shown.
--
-- Lines join pins, drawn out from one end to the other, and the view can be sent to show a few
-- places at once (Frame): a guess and where it should have been.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class MapViewOptions
--- @field map integer? The map it starts on, the world's if left out
--- @field onClick (fun(place: Place))? A click on the map, as a place in the world. Nothing is done with a click without it
--- @field onMap (fun(mapID: integer, name: string))? It went to another map

--- @class MapPin
--- @field place Place
--- @field color number[] r g b
--- @field size number Across, in the window's units, whatever the zoom
--- @field ring boolean? An outline rather than a dot
--- @field label string? Under it

--- @class MapView
--- @field frame Frame Size it with SetSize
--- @field mapID integer The map shown
local MapView = {}
MapView.__index = MapView
private.MapView = MapView

local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local BOARD = "Interface\\AddOns\\ForeverGames\\Images\\Board\\"
-- How much closer than the whole map it can be shown before the wheel goes into the zone under
-- the cursor
local MAX_ZOOM = 3
-- Seconds a change of map takes to fade across, and a line to be drawn
local FADE, DRAW = 0.25, 0.6
-- The world, if the client doesn't say
local WORLD = 947

local function call(f, ...)
  if type(f) ~= "function" then
    return nil
  end
  local result = { pcall(f, ...) }
  if not result[1] then
    return nil
  end
  return unpack(result, 2)
end

--- @param parent Frame
--- @param options MapViewOptions?
--- @return MapView
function MapView.New(parent, options)
  options = options or {}
  local viewport = private.Viewport.New(parent, { maxZoom = MAX_ZOOM })
  --- @type MapView
  local self = setmetatable({ viewport = viewport, frame = viewport.frame, width = 0, height = 0, pins = {}, lines = {},
    spare = {}, tiles = {}, onClick = options.onClick, onMap = options.onMap, locked = false }, MapView)
  self.mapID = options.map or call(C_Map.GetFallbackWorldMapID) or WORLD
  local content = viewport.content
  self.canvas = CreateFrame("Frame", nil, content)
  self.canvas:SetAllPoints()
  self.highlight = self.canvas:CreateTexture(nil, "ARTWORK")
  self.highlight:SetBlendMode("ADD")
  self.highlight:SetAlpha(0.7)
  -- Pins over the map, at the window's own scale so that they are the same size at any zoom,
  -- and the zone's name over everything
  self.overlay = CreateFrame("Frame", nil, self.frame)
  self.overlay:SetAllPoints()
  self.overlay:SetFrameLevel(content:GetFrameLevel() + 10)
  local over = CreateFrame("Frame", nil, self.frame)
  over:SetAllPoints()
  over:SetFrameLevel(content:GetFrameLevel() + 20)
  self.zoneName = over:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  self.zoneName:SetPoint("TOP", 0, -8)
  self.zoneName:SetShadowOffset(1, -1)
  self.fader = over:CreateTexture(nil, "BACKGROUND")
  self.fader:SetAllPoints()
  self.fader:SetColorTexture(0, 0, 0, 1)
  self.fader:SetAlpha(0)

  local frame = self.frame
  -- The viewport takes the wheel and the drag; the map takes the wheel past its zoom, and clicks
  frame:SetScript("OnMouseWheel", function(_, delta)
    self:wheel(delta)
  end)
  frame:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" then
      viewport:Grab(button)
    end
  end)
  frame:SetScript("OnMouseUp", function(_, button)
    self:release(button)
  end)
  local update = frame:GetScript("OnUpdate")
  frame:SetScript("OnUpdate", function(_, elapsed)
    update(_, elapsed)
    self:advance(elapsed)
  end)
  return self
end

-----------------------------
-- The map
-----------------------------

--- The map's size in its own art's pixels, and how its tiles go
local function layerOf(mapID)
  local layers = call(C_Map.GetMapArtLayers, mapID)
  return layers and layers[1]
end

--- Lays the art of a map into the canvas
function MapView:drawArt()
  local layer = layerOf(self.mapID)
  local textures = layer and call(C_Map.GetMapArtLayerTextures, self.mapID, 1)
  if not layer or not textures then
    for _, tile in ipairs(self.tiles) do
      tile:Hide()
    end
    return false
  end
  local width, height = self.contentWidth, self.contentHeight
  local scale = width / layer.layerWidth
  local cols, rows = math.ceil(layer.layerWidth / layer.tileWidth), math.ceil(layer.layerHeight / layer.tileHeight)
  for index = 1, max(#self.tiles, cols * rows) do
    local tile = self.tiles[index]
    if index <= cols * rows then
      if not tile then
        tile = self.canvas:CreateTexture(nil, "BACKGROUND")
        self.tiles[index] = tile
      end
      local col, row = (index - 1) % cols, floor((index - 1) / cols)
      -- The tiles at the right and bottom go past the map: only what is on it is shown
      local w = min(layer.tileWidth, layer.layerWidth - col * layer.tileWidth)
      local h = min(layer.tileHeight, layer.layerHeight - row * layer.tileHeight)
      tile:SetTexture(textures[index], nil, nil, "TRILINEAR")
      tile:SetTexCoord(0, w / layer.tileWidth, 0, h / layer.tileHeight)
      tile:SetSize(w * scale, h * scale)
      tile:ClearAllPoints()
      tile:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", col * layer.tileWidth * scale, -row * layer.tileHeight * scale)
      tile:Show()
    elseif tile then
      tile:Hide()
    end
  end
  return true
end

--- Fits the map's shape into the window, as big as it goes
function MapView:fit()
  local layer = layerOf(self.mapID)
  local aspect = layer and layer.layerWidth / layer.layerHeight or 1.5
  local width, height = self.width, self.width / aspect
  if height > self.height then
    width, height = self.height * aspect, self.height
  end
  self.contentWidth, self.contentHeight = width, height
  self.viewport:SetSize(self.width, self.height)
  self.viewport:SetContentSize(width, height)
end

--- Goes to another map: its art, its name, the pins where they are on it
--- @param mapID integer
--- @param zoom number? How close in to show it at first
--- @param x number? With this point of it in the middle, 0 to 1 across
--- @param y number?
function MapView:go(mapID, zoom, x, y)
  self.mapID = mapID
  self:fit()
  self:drawArt()
  self.viewport:ZoomTo(1, self.contentWidth / 2, self.contentHeight / 2, true)
  if zoom and x and y then
    self.viewport:ZoomTo(zoom, x * self.contentWidth, y * self.contentHeight, true)
    self.viewport:Fit()
  end
  self.highlight:Hide()
  self.hovered = nil
  self:placePins()
  local info = call(C_Map.GetMapInfo, mapID)
  if self.onMap then
    self.onMap(mapID, info and info.name or "")
  end
end

--- Crosses to another map, the old one fading out and the new one in
function MapView:cross(mapID, zoom, x, y)
  self.fade = { elapsed = 0, mapID = mapID, zoom = zoom, x = x, y = y }
end

-----------------------------
-- Where things are
-----------------------------

--- Where the cursor is on the map, 0 to 1 across and down it
function MapView:under()
  local viewport = self.viewport
  local x, y = viewport:cursor()
  local zoom = viewport.zoom
  return (x - viewport.x) / zoom / self.contentWidth, (y - viewport.y) / zoom / self.contentHeight
end

--- Where a place in the world is on the map shown, 0 to 1 across and down, nil if it isn't on it
--- @param place Place
--- @return number?, number?
function MapView:spot(place)
  local _, position = call(C_Map.GetMapPosFromWorldPos, place.continent, CreateVector2D(place.x, place.y), self.mapID)
  if not position then
    return nil, nil
  end
  local x, y = position:GetXY()
  if x < -0.001 or x > 1.001 or y < -0.001 or y > 1.001 then
    return nil, nil
  end
  return x, y
end

--- The place in the world a spot on the map shown is
--- @param x number 0 to 1 across
--- @param y number
--- @return Place?
function MapView:placeAt(x, y)
  local continent, world = call(C_Map.GetWorldPosFromMapPos, self.mapID, CreateVector2D(x, y))
  if not continent or not world then
    return nil
  end
  local wx, wy = world:GetXY()
  return { continent = continent, x = wx, y = wy }
end

-----------------------------
-- Pins and lines
-----------------------------

--- @param pin MapPin
local function makePin(self, pin)
  local textures = pin.textures
  if not textures then
    local shadow = self.overlay:CreateTexture(nil, "OVERLAY", nil, 1)
    shadow:SetTexture(BOARD .. "dot")
    shadow:SetVertexColor(0, 0, 0, 0.75)
    local body = self.overlay:CreateTexture(nil, "OVERLAY", nil, 2)
    body:SetTexture(BOARD .. (pin.ring and "ring" or "dot"))
    local label = self.overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetShadowOffset(1, -1)
    textures = { shadow = shadow, body = body, label = label }
    pin.textures = textures
  end
  textures.body:SetVertexColor(pin.color[1], pin.color[2], pin.color[3], 1)
  textures.label:SetText(pin.label or "")
  return textures
end

--- Where a spot on the map is in the window, right and down from its top left corner
--- @param x number 0 to 1 across the map
--- @param y number
--- @return number, number
function MapView:onScreen(x, y)
  local viewport = self.viewport
  return viewport.x + x * self.contentWidth * viewport.zoom, viewport.y + y * self.contentHeight * viewport.zoom
end

--- Puts every pin and line where it goes on the map shown, as the map is zoomed and moved
function MapView:placePins()
  local viewport = self.viewport
  for _, pin in pairs(self.pins) do
    local textures = makePin(self, pin)
    local x, y = self:spot(pin.place)
    pin.x, pin.y = x, y
    local shown = x ~= nil and (pin.alpha or 1) > 0
    for _, region in pairs(textures) do
      region:SetShown(shown)
    end
    if shown then
      local size = pin.size
      local px, py = self:onScreen(x, y)
      textures.shadow:SetSize(size * 1.35, size * 1.35)
      textures.shadow:SetPoint("CENTER", self.overlay, "TOPLEFT", px, -py - 1)
      textures.body:SetSize(size, size)
      textures.body:SetPoint("CENTER", self.overlay, "TOPLEFT", px, -py)
      textures.label:SetPoint("TOP", self.overlay, "TOPLEFT", px, -py - size * 0.6)
      local alpha = pin.alpha or 1
      textures.body:SetAlpha(alpha)
      textures.shadow:SetAlpha(alpha * 0.75)
      textures.label:SetAlpha(alpha)
    end
  end
  for _, line in ipairs(self.lines) do
    local from, to = self.pins[line.from], self.pins[line.to]
    local texture = line.texture
    if not texture then
      texture = self.overlay:CreateLine(nil, "OVERLAY")
      line.texture = texture
    end
    local drawn = line.drawn or 1
    if from and to and from.x and to.x and drawn > 0 then
      local fx, fy = self:onScreen(from.x, from.y)
      local tx, ty = self:onScreen(to.x, to.y)
      texture:SetStartPoint("TOPLEFT", self.overlay, fx, -fy)
      texture:SetEndPoint("TOPLEFT", self.overlay, fx + (tx - fx) * drawn, -(fy + (ty - fy) * drawn))
      texture:SetThickness(2.5)
      texture:SetColorTexture(line.color[1], line.color[2], line.color[3], 0.9)
      texture:Show()
    else
      texture:Hide()
    end
  end
  self.pinsAt = viewport.zoom .. ":" .. viewport.x .. ":" .. viewport.y
end

--- Puts a pin at a place, or moves the one of that name there; nil takes it away
--- @param name string
--- @param pin MapPin?
function MapView:SetPin(name, pin)
  local old = self.pins[name]
  if old and pin then
    pin.textures = old.textures
  elseif old then
    for _, region in pairs(old.textures or {}) do
      region:Hide()
    end
  end
  self.pins[name] = pin
  self:placePins()
end

--- Draws a line from one pin to another, out from the first over a moment unless `instant`
--- @param from string
--- @param to string
--- @param color number[]
--- @param instant boolean?
function MapView:Line(from, to, color, instant)
  local line = { from = from, to = to, color = color, drawn = instant and 1 or 0, texture = table.remove(self.spare) }
  self.lines[#self.lines + 1] = line
  if not instant then
    line.elapsed = 0
  end
  self:placePins()
end

--- Takes every pin and line away
function MapView:Clear()
  for _, pin in pairs(self.pins) do
    for _, region in pairs(pin.textures or {}) do
      region:Hide()
    end
  end
  for _, line in ipairs(self.lines) do
    if line.texture then
      line.texture:Hide()
      self.spare[#self.spare + 1] = line.texture
    end
  end
  self.pins, self.lines = {}, {}
end

--- Shows a few places at once, as close in as they all fit: on the map of the continent they are
--- on, for places all on one, or of the world
--- @param places Place[]
--- @param map integer? The map to show them on, rather than the continent's
function MapView:Frame(places, map)
  local mapID = map
  if not mapID then
    local continent = places[1] and places[1].continent
    for _, place in ipairs(places) do
      if place.continent ~= continent then
        continent = nil
      end
    end
    mapID = continent and self:continentMap(places[1]) or call(C_Map.GetFallbackWorldMapID) or WORLD
  end
  if mapID ~= self.mapID then
    self:go(mapID)
  end
  local left, right, top, bottom = 1, 0, 1, 0
  for _, place in ipairs(places) do
    local x, y = self:spot(place)
    if x then
      left, right, top, bottom = min(left, x), max(right, x), min(top, y), max(bottom, y)
    end
  end
  if right < left then
    self.viewport:Fit()
    return
  end
  -- A margin round them, and never closer than half of the map across
  local across = max(0.12, (right - left) * 1.5, (bottom - top) * 1.5 * self.contentHeight / self.contentWidth)
  self.viewport:ZoomTo(min(MAX_ZOOM, 1 / across), (left + right) / 2 * self.contentWidth, (top + bottom) / 2 * self.contentHeight)
end

--- The map of the continent a place is on
--- @param place Place
--- @return integer?
function MapView:continentMap(place)
  local world = call(C_Map.GetFallbackWorldMapID) or WORLD
  for _, child in ipairs(call(C_Map.GetMapChildrenInfo, world, Enum.UIMapType.Continent) or {}) do
    local _, position = call(C_Map.GetMapPosFromWorldPos, place.continent, CreateVector2D(place.x, place.y), child.mapID)
    local x, y
    if position then
      x, y = position:GetXY()
    end
    if x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
      return child.mapID
    end
  end
  return nil
end

-----------------------------
-- The mouse
-----------------------------

--- The wheel: closer and further on the map, and on past either end into the zone under the
--- cursor or out to the map this one is in
function MapView:wheel(delta)
  if self.fade then
    return
  end
  local viewport = self.viewport
  local zoom = viewport:goal()
  if delta > 0 and zoom >= MAX_ZOOM - 0.01 then
    local x, y = self:under()
    local zone = call(C_Map.GetMapInfoAtPosition, self.mapID, x, y)
    if zone and zone.mapID ~= self.mapID then
      self:cross(zone.mapID)
    end
    return
  elseif delta < 0 and zoom <= 1.01 then
    self:Out()
    return
  end
  viewport:Wheel(delta)
end

--- Out to the map this one is in, looking at where this one is on it
function MapView:Out()
  local info = call(C_Map.GetMapInfo, self.mapID)
  local parent = info and info.parentMapID
  if not parent or parent == 0 or not layerOf(parent) then
    return
  end
  local left, right, top, bottom = call(C_Map.GetMapRectOnMap, self.mapID, parent)
  local zoom, x, y
  if left and right > left then
    zoom = min(MAX_ZOOM, 1 / max(right - left, bottom - top))
    x, y = (left + right) / 2, (top + bottom) / 2
  end
  self:cross(parent, zoom, x, y)
end

function MapView:release(button)
  local viewport = self.viewport
  if button == "RightButton" then
    if not self.locked then
      self:Out()
    end
    return
  end
  if button ~= "LeftButton" then
    return
  end
  local dragged = viewport.dragged
  viewport.grab, viewport.dragged = nil, false
  if dragged or self.locked or not self.onClick then
    return
  end
  local x, y = self:under()
  if x < 0 or x > 1 or y < 0 or y > 1 then
    return
  end
  local place = self:placeAt(x, y)
  if place then
    self.onClick(place)
  end
end

--- @param elapsed number
function MapView:advance(elapsed)
  local fade = self.fade
  if fade then
    fade.elapsed = fade.elapsed + elapsed
    local half = FADE / 2
    if fade.elapsed < half then
      self.fader:SetAlpha(fade.elapsed / half)
    else
      if fade.mapID then
        self:go(fade.mapID, fade.zoom, fade.x, fade.y)
        fade.mapID = nil
      end
      local left = 1 - (fade.elapsed - half) / half
      self.fader:SetAlpha(max(0, left))
      if left <= 0 then
        self.fade = nil
      end
    end
  end
  local drawing = false
  for _, line in ipairs(self.lines) do
    if line.elapsed then
      line.elapsed = line.elapsed + elapsed
      local progress = min(1, line.elapsed / DRAW)
      line.drawn = 1 - (1 - progress) ^ 3
      if progress >= 1 then
        line.elapsed = nil
      end
      drawing = true
    end
  end
  local viewport = self.viewport
  if drawing or self.pinsAt ~= viewport.zoom .. ":" .. viewport.x .. ":" .. viewport.y then
    self:placePins()
  end
  -- What is under the cursor, lit up and named
  if self.frame:IsMouseOver() and not self.fade then
    local x, y = self:under()
    if x ~= self.lastX or y ~= self.lastY then
      self.lastX, self.lastY = x, y
      self:hover(x, y)
    end
  elseif self.hovered then
    self.hovered = nil
    self.highlight:Hide()
    self.zoneName:SetText(self.mapName or "")
  end
end

function MapView:hover(x, y)
  local inside = x >= 0 and x <= 1 and y >= 0 and y <= 1
  local zone = inside and call(C_Map.GetMapInfoAtPosition, self.mapID, x, y)
  local info = call(C_Map.GetMapInfo, self.mapID)
  self.mapName = info and info.name or ""
  self.zoneName:SetText(zone and zone.mapID ~= self.mapID and zone.name or self.mapName)
  local key = zone and zone.mapID
  if key == self.hovered then
    return
  end
  self.hovered = key
  local highlight = self.highlight
  local fileID, atlas, px, py, tw, th, sx, sy
  if inside then
    fileID, atlas, px, py, tw, th, sx, sy = call(C_Map.GetMapHighlightInfoAtPosition, self.mapID, x, y)
  end
  if (fileID and fileID > 0) or atlas then
    local width, height = self.contentWidth, self.contentHeight
    highlight:ClearAllPoints()
    highlight:SetTexCoord(0, px, 0, py)
    if atlas then
      highlight:SetAtlas(atlas, true)
      highlight:SetPoint("CENTER", self.canvas, "TOPLEFT", (sx + 0.5 * tw) * width, -(sy + 0.5 * th) * height)
    else
      highlight:SetTexture(fileID, nil, nil, "TRILINEAR")
      highlight:SetSize(max(1, tw * width), max(1, th * height))
      highlight:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", sx * width, -sy * height)
    end
    highlight:Show()
  else
    highlight:Hide()
  end
end

-----------------------------
-- Public
-----------------------------

--- @param width number
--- @param height number
function MapView:SetSize(width, height)
  if width == self.width and height == self.height then
    return
  end
  self.width, self.height = width, height
  self.frame:SetSize(width, height)
  self:fit()
  self:drawArt()
  self:placePins()
end

--- Shows a map, all of it
--- @param mapID integer
function MapView:Show(mapID)
  self:go(mapID)
end

--- Clicks no longer put anything down, and right-click no longer goes out
--- @param locked boolean
function MapView:Lock(locked)
  self.locked = locked
end
