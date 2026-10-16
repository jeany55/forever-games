--------------------------
--  MapView
--------------------------
-- The client's own map of the world, in a window of a game's, to point at places on: for a game
-- that asks where somewhere is. It is drawn from the client's map art (C_Map.GetMapArtLayers and
-- GetMapArtLayerTextures, the tiles its world map is made of) and looked round in a Viewport:
-- the wheel zooms, dragging moves it.
--
-- All of every map is shown, explored or not: the pictures the world map lays over its art for
-- the places a character has been are drawn for every place there is (GUI/MapOverlays.lua, from
-- the client's own tables), so no player sees more of it than another. The area under the
-- cursor is named, Goldshire as well as Elwynn Forest.
--
-- Zooming goes on past the map's own detail into the zone under the cursor: turn the wheel on
-- far enough over Elwynn Forest on the Eastern Kingdoms and the map becomes Elwynn's, turn it
-- back out past the whole of Elwynn and it is the Eastern Kingdoms again, with Elwynn where it
-- was. It is one map, looked at closer: the continent goes on closing in until Elwynn fills the
-- window just as its own map does, and then its own map fades in over it, and going out the
-- continent comes in under Elwynn where Elwynn was and draws back. The zone under the cursor is
-- lit up as the world map lights it. Along the top, the maps this one is in, for going straight
-- out to any of them.
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
--- @field trail boolean? The maps this one is in along the top, to go out to with a click

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

local floor, min, max, abs, ceil = math.floor, math.min, math.max, math.abs, math.ceil
local BOARD = "Interface\\AddOns\\ForeverGames\\Images\\Board\\"
-- How much closer than the whole map it can be shown before the wheel goes into the zone under
-- the cursor, and how much closer a notch of the wheel goes
local MAX_ZOOM, STEP = 3, 1.5
-- Seconds the map gone from takes to fade, and a line to be drawn
local FADE, DRAW = 0.25, 0.6
-- The world, if the client doesn't say
local WORLD = 947
-- Where the fields of an overlay are (GUI/MapOverlays.lua)
local O_WIDTH, O_HEIGHT, O_LEFT, O_TOP, O_HIT_LEFT, O_HIT_TOP, O_HIT_RIGHT, O_HIT_BOTTOM, O_AREA, O_FILES = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
-- How many maps out the trail goes at most, and what is between them
local TRAIL, TRAIL_HEIGHT, TRAIL_BETWEEN = 5, 18, " \194\187 "

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

--- What a map's art is drawn on: its tiles and its overlays. There are two, the map shown and
--- the one it came from, still fading
--- @param parent Frame
local function newArt(parent)
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetAllPoints()
  return { frame = frame, tiles = {}, patches = {} }
end

--- @param parent Frame
--- @param options MapViewOptions?
--- @return MapView
function MapView.New(parent, options)
  options = options or {}
  local viewport = private.Viewport.New(parent, { maxZoom = MAX_ZOOM, step = STEP })
  --- @type MapView
  local self = setmetatable({ viewport = viewport, frame = viewport.frame, width = 0, height = 0, pins = {}, lines = {},
    spare = {}, onClick = options.onClick, onMap = options.onMap, locked = false, crumbs = {} }, MapView)
  self.mapID = options.map or call(C_Map.GetFallbackWorldMapID) or WORLD
  local content = viewport.content
  local level = content:GetFrameLevel()
  self.arts = { newArt(content), newArt(content) }
  self.art = self.arts[1]
  self.arts[2].frame:Hide()
  -- The map gone from, kept where it was in the window while it fades, over the new one
  self.behind = CreateFrame("Frame", nil, self.frame)
  self.behind:SetAllPoints()
  self.behind:SetFrameLevel(level + 5)
  local lit = CreateFrame("Frame", nil, content)
  lit:SetAllPoints()
  lit:SetFrameLevel(level + 3)
  self.lit = lit
  self.highlight = lit:CreateTexture(nil, "ARTWORK")
  self.highlight:SetBlendMode("ADD")
  self.highlight:SetAlpha(0.7)
  -- Pins over the map, at the window's own scale so that they are the same size at any zoom,
  -- and the name of what is under the cursor over everything
  self.overlay = CreateFrame("Frame", nil, self.frame)
  self.overlay:SetAllPoints()
  self.overlay:SetFrameLevel(level + 10)
  local over = CreateFrame("Frame", nil, self.frame)
  over:SetAllPoints()
  over:SetFrameLevel(level + 20)
  self.over = over
  self.zoneName = over:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  self.zoneName:SetShadowOffset(1, -1)
  if options.trail then
    self.trail = CreateFrame("Frame", nil, over)
    self.trail:SetPoint("TOPLEFT", 4, -4)
    self.trail:SetHeight(TRAIL_HEIGHT)
    local back = self.trail:CreateTexture(nil, "BACKGROUND")
    back:SetAllPoints()
    back:SetColorTexture(0, 0, 0, 0.55)
    -- The name of what is under the cursor goes to the foot of the map, out of the trail's way
    self.zoneName:SetPoint("BOTTOM", 0, 8)
  else
    self.zoneName:SetPoint("TOP", 0, -8)
  end

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

--- The overlays of a map's art, the whole of what can be explored of it
--- @param mapID integer
--- @return table[]?
local function overlaysOf(mapID)
  local art = call(C_Map.GetMapArtID, mapID)
  return art and private.MapOverlays and private.MapOverlays[art]
end

--- @param art table
--- @param list table[] Its tiles or its patches
--- @param index integer
--- @param layer string
--- @return Texture
local function texture(art, list, index, layer)
  local tile = list[index]
  if not tile then
    tile = art.frame:CreateTexture(nil, layer)
    list[index] = tile
  end
  return tile
end

--- Lays the art of a map into the canvas: its tiles, and over them every overlay of it, cut into
--- tiles the size of the map's own as the world map cuts them
--- (Blizzard_SharedMapDataProviders/MapExplorationDataProvider.lua)
function MapView:drawArt()
  local art = self.art
  local layer = layerOf(self.mapID)
  local textures = layer and call(C_Map.GetMapArtLayerTextures, self.mapID, 1)
  local tiles, patches = 0, 0
  if layer and textures then
    -- The pictures are only set when the map changes, as growing the window lays them out again
    -- every frame
    local fresh = art.mapID ~= self.mapID
    art.mapID = self.mapID
    local scale = self.contentWidth / layer.layerWidth
    local tw, th = layer.tileWidth, layer.tileHeight
    --- Puts a picture in, `w` by `h` of its `fw` by `fh` at (x, y) of the art
    local function lay(tile, file, x, y, w, h, fw, fh)
      if fresh then
        tile:SetTexture(file, nil, nil, "TRILINEAR")
      end
      tile:SetTexCoord(0, w / fw, 0, h / fh)
      tile:SetSize(w * scale, h * scale)
      tile:ClearAllPoints()
      tile:SetPoint("TOPLEFT", art.frame, "TOPLEFT", x * scale, -y * scale)
      tile:Show()
    end
    local cols, rows = ceil(layer.layerWidth / tw), ceil(layer.layerHeight / th)
    for index = 1, cols * rows do
      local col, row = (index - 1) % cols, floor((index - 1) / cols)
      -- The tiles at the right and bottom go past the map: only what is on it is shown
      local w = min(tw, layer.layerWidth - col * tw)
      local h = min(th, layer.layerHeight - row * th)
      tiles = tiles + 1
      lay(texture(art, art.tiles, tiles, "BACKGROUND"), textures[index], col * tw, row * th, w, h, tw, th)
    end
    --- How much of a picture at the end of an overlay is on it, and how big its file is: the
    --- next power of two, at least 16
    local function last(size, tile)
      local used = size % tile
      used = used == 0 and tile or used
      local file = 16
      while file < used do
        file = file * 2
      end
      return used, file
    end
    for _, patch in ipairs(overlaysOf(self.mapID) or {}) do
      local across, down = ceil(patch[O_WIDTH] / tw), ceil(patch[O_HEIGHT] / th)
      for j = 1, down do
        local h, fh = th, th
        if j == down then
          h, fh = last(patch[O_HEIGHT], th)
        end
        for k = 1, across do
          local file = patch[O_FILES + (j - 1) * across + k - 1]
          if file then
            local w, fw = tw, tw
            if k == across then
              w, fw = last(patch[O_WIDTH], tw)
            end
            patches = patches + 1
            lay(texture(art, art.patches, patches, "BORDER"), file, patch[O_LEFT] + tw * (k - 1),
              patch[O_TOP] + th * (j - 1), w, h, fw, fh)
          end
        end
      end
    end
  end
  for index = tiles + 1, #art.tiles do
    art.tiles[index]:Hide()
  end
  for index = patches + 1, #art.patches do
    art.patches[index]:Hide()
  end
  return tiles > 0
end

--- How big a map is shown when it all fits the window, as big as it goes in its own shape
--- @param mapID integer
--- @return number width, number height
function MapView:fitted(mapID)
  local layer = layerOf(mapID)
  local aspect = layer and layer.layerWidth / layer.layerHeight or 1.5
  local width, height = self.width, self.width / aspect
  if height > self.height then
    width, height = self.height * aspect, self.height
  end
  return width, height
end

--- Fits the map's shape into the window, as big as it goes
function MapView:fit()
  local width, height = self:fitted(self.mapID)
  self.contentWidth, self.contentHeight = width, height
  self.viewport:SetSize(self.width, self.height)
  self.viewport:SetContentSize(width, height)
end

--- Sets the map gone from fading, where it is in the window, over the one coming in
function MapView:fadeOut()
  local old, viewport = self.art, self.viewport
  local zoom = viewport.zoom
  local frame = old.frame
  frame:SetParent(self.behind)
  frame:SetFrameLevel(self.behind:GetFrameLevel() + 1)
  frame:SetScale(zoom)
  frame:ClearAllPoints()
  frame:SetSize(self.contentWidth, self.contentHeight)
  frame:SetPoint("TOPLEFT", self.behind, "TOPLEFT", viewport.x / zoom, -viewport.y / zoom)
  frame:SetAlpha(1)
  self.fading = { art = old, elapsed = 0 }
  -- The other one is now the map's own
  local art = self.arts[1] == old and self.arts[2] or self.arts[1]
  frame = art.frame
  frame:SetParent(self.viewport.content)
  frame:SetFrameLevel(self.viewport.content:GetFrameLevel() + 1)
  frame:SetScale(1)
  frame:ClearAllPoints()
  frame:SetAllPoints()
  frame:SetAlpha(1)
  frame:Show()
  self.art = art
end

--- The map gone from is gone
function MapView:faded()
  local fading = self.fading
  if fading then
    self.fading = nil
    fading.art.frame:Hide()
  end
end

--- Goes to another map: its art, its name, the pins where they are on it
--- @param mapID integer
--- @param zoom number? How close in to show it at first
--- @param x number? With this point of it in the middle, 0 to 1 across
--- @param y number?
--- @param fade boolean? The map it was showing fades out over it, rather than going at once
function MapView:go(mapID, zoom, x, y, fade)
  self:faded()
  if fade then
    self:fadeOut()
  end
  self.mapID = mapID
  self:fit()
  self:drawArt()
  self.viewport:ZoomTo(1, self.contentWidth / 2, self.contentHeight / 2, true)
  if zoom and x and y then
    self.viewport:ZoomTo(zoom, x * self.contentWidth, y * self.contentHeight, true)
    self.viewport:Fit()
  end
  self:arrived()
end

--- What goes with being on another map: its name and the trail to it, the pins where they are
--- on it, and telling the game
function MapView:arrived()
  self.highlight:Hide()
  self.hovered, self.lastX, self.lastY = nil, nil, nil
  local info = call(C_Map.GetMapInfo, self.mapID)
  self.mapName = info and info.name or ""
  self.zoneName:SetText(self.mapName)
  self:drawTrail()
  self:placePins()
  if self.onMap then
    self.onMap(self.mapID, self.mapName)
  end
end

--- Where the content of another map is to be put to show it just as the map shown shows it now,
--- for the one to come in exactly over the other
--- @param mapID integer
--- @param inside boolean Whether the other map lies inside this one, rather than this inside it
--- @return number? zoom, number? x, number? y
function MapView:matching(mapID, inside)
  local child, parent = mapID, self.mapID
  if not inside then
    child, parent = self.mapID, mapID
  end
  local left, right, top, bottom = call(C_Map.GetMapRectOnMap, child, parent)
  if not left or not right or right <= left or not bottom or bottom <= top then
    return nil
  end
  local viewport = self.viewport
  if inside then
    -- The zone as its own map would show it all, in the middle of the window
    local width, height = self:fitted(mapID)
    local zoom = width / ((right - left) * self.contentWidth)
    return zoom, (self.width - width) / 2 - left * self.contentWidth * zoom,
      (self.height - height) / 2 - top * self.contentHeight * zoom
  end
  -- The map it is in, with this one where it is now
  local width, height = self:fitted(mapID)
  local zoom = viewport.zoom * self.contentWidth / ((right - left) * width)
  return zoom, viewport.x - left * width * zoom, viewport.y - top * height * zoom
end

--- Into a zone of the map shown: the map closes in until the zone fills the window just as its
--- own map does, then that comes in over it
--- @param mapID integer
function MapView:dive(mapID)
  local zoom, x, y = self:matching(mapID, true)
  if not zoom then
    self:go(mapID, nil, nil, nil, true)
    return
  end
  self.diving = mapID
  self.viewport:GlideTo(zoom, x, y)
end

--- Out to a map this one is in, the parent if not said: it comes in under this one where this
--- one is, then draws back, to all of it or as far as one notch of the wheel goes
--- @param mapID integer?
--- @param all boolean? All of it
function MapView:Out(mapID, all)
  if self.diving then
    return
  end
  if not mapID then
    local info = call(C_Map.GetMapInfo, self.mapID)
    mapID = info and info.parentMapID
  end
  if not mapID or mapID == 0 or mapID == self.mapID or not layerOf(mapID) then
    return
  end
  local zoom, x, y = self:matching(mapID, false)
  self:faded()
  self:fadeOut()
  self.mapID = mapID
  self:fit()
  self:drawArt()
  local viewport = self.viewport
  if zoom then
    viewport:GlideTo(zoom, x, y, true)
  end
  self:arrived()
  if all or not zoom then
    viewport:Fit()
    return
  end
  -- Drawing back from the point of it under the cursor, or from the middle if it isn't over it
  local to = max(1, min(MAX_ZOOM, zoom / STEP))
  local cx, cy = viewport:cursor()
  if cx < 0 or cy < 0 or cx > self.width or cy > self.height then
    cx, cy = self.width / 2, self.height / 2
  end
  local px, py = (cx - viewport.x) / zoom, (cy - viewport.y) / zoom
  viewport:glide(to, cx - px * to, cy - py * to)
end

-----------------------------
-- The trail
-----------------------------

--- The maps this one is in that have art, outermost first, then this one
--- @return table[] { mapID, name }
function MapView:chain()
  local chain, id = {}, self.mapID
  while id and id ~= 0 and #chain < TRAIL do
    local info = call(C_Map.GetMapInfo, id)
    if not info then
      break
    end
    if id == self.mapID or layerOf(id) then
      table.insert(chain, 1, { mapID = id, name = info.name or "" })
    end
    id = info.parentMapID
  end
  return chain
end

--- @param index integer
--- @return Button
function MapView:crumb(index)
  local crumb = self.crumbs[index]
  if crumb then
    return crumb
  end
  crumb = CreateFrame("Button", nil, self.trail)
  crumb:SetHeight(TRAIL_HEIGHT)
  crumb.label = crumb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  crumb.label:SetPoint("LEFT")
  crumb.between = self.trail:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  crumb.between:SetText(TRAIL_BETWEEN)
  crumb:SetScript("OnClick", function()
    if crumb.mapID and crumb.mapID ~= self.mapID then
      self:Out(crumb.mapID, true)
    end
  end)
  crumb:SetScript("OnEnter", function()
    if crumb.mapID ~= self.mapID then
      crumb.label:SetTextColor(1, 1, 1)
    end
  end)
  crumb:SetScript("OnLeave", function()
    self:tintCrumb(crumb)
  end)
  self.crumbs[index] = crumb
  return crumb
end

--- A map out from this one is a link, gold; this one is white
function MapView:tintCrumb(crumb)
  if crumb.mapID == self.mapID then
    crumb.label:SetTextColor(1, 1, 1)
  else
    crumb.label:SetTextColor(1, 0.82, 0)
  end
end

--- Lays the trail out to the map shown
function MapView:drawTrail()
  local trail = self.trail
  if not trail then
    return
  end
  local chain = self:chain()
  local x = 6
  for index, link in ipairs(chain) do
    local crumb = self:crumb(index)
    crumb.mapID = link.mapID
    crumb.label:SetText(link.name)
    self:tintCrumb(crumb)
    crumb.between:ClearAllPoints()
    if index > 1 then
      crumb.between:SetPoint("LEFT", trail, "LEFT", x, 0)
      crumb.between:Show()
      x = x + (crumb.between:GetStringWidth() or 0)
    else
      crumb.between:Hide()
    end
    local width = (crumb.label:GetStringWidth() or 0) + 2
    crumb:SetWidth(width)
    crumb:ClearAllPoints()
    crumb:SetPoint("LEFT", trail, "LEFT", x, 0)
    crumb:Show()
    x = x + width
  end
  for index = #chain + 1, #self.crumbs do
    self.crumbs[index]:Hide()
    self.crumbs[index].between:Hide()
  end
  trail:SetWidth(x + 6)
  trail:SetShown(#chain > 1)
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

--- Whether the map shown is the whole world (or more), rather than a continent or a part of one
--- @return boolean
function MapView:isWorld()
  local info = call(C_Map.GetMapInfo, self.mapID)
  local kind, kinds = info and info.mapType, Enum.UIMapType
  return kind ~= nil and (kind == kinds.World or kind == kinds.Cosmic)
end

--- The place in the world a spot on the map shown is
--- @param x number 0 to 1 across
--- @param y number
--- @return Place?
function MapView:placeAt(x, y)
  -- The world's own map spans both continents, but the client puts any spot of it on one of
  -- them: a guess made there could be on the wrong continent and worth nothing
  if self:isWorld() then
    return nil
  end
  local continent, world = call(C_Map.GetWorldPosFromMapPos, self.mapID, CreateVector2D(x, y))
  if not continent or not world then
    return nil
  end
  local wx, wy = world:GetXY()
  return { continent = continent, x = wx, y = wy }
end

--- The map of what is at a spot of the map shown, closer: a zone of it, or a city drawn on it.
--- The client has cities in the continent rather than in the zone round them (Stormwind City
--- isn't in Elwynn Forest), so what the map this one is in has there, if it is smaller than this
--- @param x number 0 to 1 across
--- @param y number
--- @return table? info With mapID and name
function MapView:zoneAt(x, y)
  if x < 0 or x > 1 or y < 0 or y > 1 then
    return nil
  end
  local zone = call(C_Map.GetMapInfoAtPosition, self.mapID, x, y)
  if zone and zone.mapID ~= self.mapID then
    return zone
  end
  local info = call(C_Map.GetMapInfo, self.mapID)
  local parent = info and info.parentMapID
  local place = parent and parent ~= 0 and self:placeAt(x, y)
  if not place then
    return nil
  end
  local _, position = call(C_Map.GetMapPosFromWorldPos, place.continent, CreateVector2D(place.x, place.y), parent)
  if not position then
    return nil
  end
  local around = call(C_Map.GetMapInfoAtPosition, parent, position:GetXY())
  if not around or around.mapID == self.mapID or around.mapID == parent then
    return nil
  end
  local zoom = self:matching(around.mapID, true)
  return zoom and zoom > 1 and around or nil
end

--- The name of the area of the map shown at a spot, by its overlays: the smallest whose naming
--- rectangle it is in
--- @param x number 0 to 1 across
--- @param y number
--- @return string?
function MapView:areaAt(x, y)
  local layer = layerOf(self.mapID)
  local overlays = layer and overlaysOf(self.mapID)
  if not overlays then
    return nil
  end
  local px, py = x * layer.layerWidth, y * layer.layerHeight
  local best, size
  for _, patch in ipairs(overlays) do
    if px >= patch[O_HIT_LEFT] and px <= patch[O_HIT_RIGHT] and py >= patch[O_HIT_TOP] and py <= patch[O_HIT_BOTTOM] then
      local area = (patch[O_HIT_RIGHT] - patch[O_HIT_LEFT]) * (patch[O_HIT_BOTTOM] - patch[O_HIT_TOP])
      if patch[O_AREA] > 0 and (not size or area < size) then
        best, size = patch[O_AREA], area
      end
    end
  end
  local name = best and call(C_Map.GetAreaInfo, best)
  return name ~= "" and name or nil
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
--- cursor or out to the map this one is in. In goes into the zone as soon as a notch would show
--- it as big as its own map does, or would go past as close as this map goes
function MapView:wheel(delta)
  if self.diving then
    return
  end
  local viewport = self.viewport
  local zoom = viewport:goal()
  if delta > 0 then
    local zone = self:zoneAt(self:under())
    if zone and layerOf(zone.mapID) then
      local into = self:matching(zone.mapID, true)
      if not into or zoom * STEP >= into or zoom * STEP > MAX_ZOOM + 0.01 then
        self:dive(zone.mapID)
        return
      end
    end
    if zoom >= MAX_ZOOM - 0.01 then
      return
    end
  elseif zoom <= 1.01 then
    self:Out()
    return
  end
  viewport:Wheel(delta)
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
    return
  end
  -- A spot of the whole world is no place: the click goes into the continent there instead
  local zone = self:zoneAt(x, y)
  if zone then
    self:dive(zone.mapID)
  end
end

--- @param elapsed number
function MapView:advance(elapsed)
  local viewport = self.viewport
  -- Closed in on a zone as far as its own map shows it: that comes in over it
  if self.diving and not viewport.move then
    local mapID = self.diving
    self.diving = nil
    self:go(mapID, nil, nil, nil, true)
  end
  local fading = self.fading
  if fading then
    fading.elapsed = fading.elapsed + elapsed
    local left = 1 - fading.elapsed / FADE
    fading.art.frame:SetAlpha(max(0, left * left))
    if left <= 0 then
      self:faded()
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
  if drawing or self.pinsAt ~= viewport.zoom .. ":" .. viewport.x .. ":" .. viewport.y then
    self:placePins()
  end
  -- What is under the cursor, lit up and named
  if self.frame:IsMouseOver() and not self.diving then
    local x, y = self:under()
    if x ~= self.lastX or y ~= self.lastY then
      self.lastX, self.lastY = x, y
      self:hover(x, y)
    end
  elseif self.hovered ~= nil then
    self.hovered, self.lastX, self.lastY = nil, nil, nil
    self.highlight:Hide()
    self.zoneName:SetText(self.mapName or "")
  end
end

--- Names what is under the cursor, a zone of the map shown or an area of it, and lights the zone up
function MapView:hover(x, y)
  local inside = x >= 0 and x <= 1 and y >= 0 and y <= 1
  local zone = self:zoneAt(x, y)
  local area = inside and not zone and self:areaAt(x, y)
  self.zoneName:SetText(zone and zone.name or area or self.mapName or "")
  local key = zone and zone.mapID or false
  if key == self.hovered then
    return
  end
  self.hovered = key
  local highlight = self.highlight
  local fileID, atlas, px, py, tw, th, sx, sy
  if zone then
    fileID, atlas, px, py, tw, th, sx, sy = call(C_Map.GetMapHighlightInfoAtPosition, self.mapID, x, y)
  end
  if (fileID and fileID > 0) or atlas then
    local width, height = self.contentWidth, self.contentHeight
    highlight:ClearAllPoints()
    highlight:SetTexCoord(0, px, 0, py)
    if atlas then
      highlight:SetAtlas(atlas, true)
      highlight:SetPoint("CENTER", self.lit, "TOPLEFT", (sx + 0.5 * tw) * width, -(sy + 0.5 * th) * height)
    else
      highlight:SetTexture(fileID, nil, nil, "TRILINEAR")
      highlight:SetSize(max(1, tw * width), max(1, th * height))
      highlight:SetPoint("TOPLEFT", self.lit, "TOPLEFT", sx * width, -sy * height)
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
  -- The map going is gone, and a zone being gone into is matched to the window again: what it
  -- was matched to is going
  self:faded()
  local diving = self.diving
  self.diving = nil
  self.width, self.height = width, height
  self.frame:SetSize(width, height)
  self:fit()
  self:drawArt()
  self:placePins()
  if diving then
    self:dive(diving)
  end
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
