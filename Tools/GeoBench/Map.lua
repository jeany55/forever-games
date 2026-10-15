--------------------------
--  Geo Bench: the map to guess on
--------------------------
-- The client's own map art, as its world map draws it (C_Map.GetMapArtLayers and
-- GetMapArtLayerTextures: a grid of tiles), in a window of our own rather than the world map's,
-- to tell whether a game can put its guesses on it: zooming and dragging it about, the zone
-- under the cursor lit up as the world map lights it (GetMapHighlightInfoAtPosition) and named,
-- going into that zone and back out.
--
-- Clicking guesses: the guess and where you really are are put into the world's yards by the
-- client (GetWorldPosFromMapPos) and how far apart they are said, with what a round of the game
-- would score for it. Where you are is shown twice: once where the client puts you on this map
-- (GetPlayerMapPosition), once from your place in the world put back onto it
-- (GetMapPosFromWorldPos), which is how the game would show the answer on any map. They should
-- be the same spot.
--
--   /geobench map [mapID]     your own map if none is said
--
-- Click to guess, drag to move, the wheel zooms, Shift-click goes into the zone under the cursor,
-- right-click goes out to the map it is in.

local _, ns = ...
local say = ns.say
local floor, min, max, abs, sqrt, exp = math.floor, math.min, math.max, math.abs, math.sqrt, math.exp

local MAX_ZOOM = 6
-- How far the cursor moves before a click is a drag
local DRAG = 4
-- GeoGuessr's curve: 5000 for spot on, falling away over a tenth of the map's size
local BEST, FALLOFF = 5000, 10

local frame = ns.frame
local canvas = CreateFrame("Frame", nil, frame)
canvas:SetPoint("TOPLEFT")
canvas:Hide()
local tiles = {}
local highlight = canvas:CreateTexture(nil, "ARTWORK")
highlight:SetBlendMode("ADD")
local function pin(r, g, b, size)
  local outer = canvas:CreateTexture(nil, "OVERLAY", nil, 1)
  outer:SetColorTexture(0, 0, 0, 1)
  local inner = canvas:CreateTexture(nil, "OVERLAY", nil, 2)
  inner:SetColorTexture(r, g, b, 1)
  return { outer = outer, inner = inner, size = size }
end
local pins = { here = pin(0.2, 0.9, 1, 9), answer = pin(1, 0.85, 0.2, 13), guess = pin(1, 0.3, 0.25, 11) }
local line = canvas:CreateLine(nil, "OVERLAY")
line:SetColorTexture(1, 1, 1, 0.9)

local map

local function showPin(p, x, y)
  if not x then
    p.outer:Hide()
    p.inner:Hide()
    return
  end
  -- The size stays the same on the screen whatever the zoom
  local size = p.size / map.zoom
  local px, py = x * map.width, -y * map.height
  p.outer:SetSize(size, size)
  p.outer:SetPoint("CENTER", canvas, "TOPLEFT", px, py)
  p.inner:SetSize(size * 0.6, size * 0.6)
  p.inner:SetPoint("CENTER", canvas, "TOPLEFT", px, py)
  p.outer:Show()
  p.inner:Show()
end

local function call(f, ...)
  return select(2, ns.call(f, ...))
end

--- The continent a map is in, or the map itself
local function continentOf(mapID)
  local id = mapID
  for _ = 1, 10 do
    local info = call(C_Map.GetMapInfo, id)
    if not info then
      return mapID
    end
    if info.mapType == Enum.UIMapType.Continent or not info.parentMapID or info.parentMapID == 0 then
      return id
    end
    id = info.parentMapID
  end
  return id
end

--- The window's corner of the canvas and its scale, for the zoom and where it was dragged to
local function arrange()
  local m = map
  local scale = m.fit * m.zoom
  local width, height = m.width * scale, m.height * scale
  local frameW, frameH = m.width * m.fit, m.height * m.fit
  -- Never more of an edge than it has to show
  m.x = min(0, max(frameW - width, m.x))
  m.y = min(0, max(frameH - height, m.y))
  canvas:SetScale(scale)
  canvas:ClearAllPoints()
  canvas:SetPoint("TOPLEFT", frame, "TOPLEFT", m.x / scale, -m.y / scale)
  line:SetThickness(2 / m.zoom)
  showPin(pins.here, m.hereX, m.hereY)
  showPin(pins.answer, m.answerX, m.answerY)
  showPin(pins.guess, m.guessX, m.guessY)
end

--- Where the cursor is on the map, 0 to 1 across and down
local function under()
  local x, y = ns.cursor()
  local scale = map.fit * map.zoom
  return (x - map.x) / scale / map.width, (y - map.y) / scale / map.height
end

local load

local mode = {}

function mode.start(mapID)
  local layers = call(C_Map.GetMapArtLayers, mapID)
  local layer = layers and layers[1]
  local textures = call(C_Map.GetMapArtLayerTextures, mapID, 1)
  local info = call(C_Map.GetMapInfo, mapID)
  if not layer or not textures then
    say(("|cffff4040No map art for map %s|r"):format(tostring(mapID)))
    ns.finish()
    return
  end
  local fit = ns.window(layer.layerWidth, layer.layerHeight)
  map = { id = mapID, name = info and info.name or "?", width = layer.layerWidth, height = layer.layerHeight, fit = fit,
    zoom = 1, x = 0, y = 0, continent = continentOf(mapID) }
  canvas:SetSize(layer.layerWidth, layer.layerHeight)
  local cols = math.ceil(layer.layerWidth / layer.tileWidth)
  local rows = math.ceil(layer.layerHeight / layer.tileHeight)
  local loaded = 0
  for index = 1, max(#tiles, cols * rows) do
    local tile = tiles[index]
    if index <= cols * rows then
      if not tile then
        tile = canvas:CreateTexture(nil, "BACKGROUND")
        tiles[index] = tile
      end
      local col, row = (index - 1) % cols, floor((index - 1) / cols)
      tile:SetSize(layer.tileWidth, layer.tileHeight)
      tile:SetPoint("TOPLEFT", canvas, "TOPLEFT", col * layer.tileWidth, -row * layer.tileHeight)
      if tile:SetTexture(textures[index], nil, nil, "TRILINEAR") ~= false then
        loaded = loaded + 1
      end
      tile:Show()
    elseif tile then
      tile:Hide()
    end
  end
  -- Where you are, the client's way and from the world's
  local here = ns.where()
  map.here = here
  local position = call(C_Map.GetPlayerMapPosition, mapID, "player")
  if position then
    map.hereX, map.hereY = position:GetXY()
  end
  if here.continent and here.worldX then
    local _, _, onMap = ns.call(C_Map.GetMapPosFromWorldPos, here.continent, CreateVector2D(here.worldX, here.worldY), mapID)
    if onMap then
      local x, y = onMap:GetXY()
      if x >= 0 and x <= 1 and y >= 0 and y <= 1 then
        map.answerX, map.answerY = x, y
      end
    end
  end
  local cw, ch = call(C_Map.GetMapWorldSize, map.continent)
  map.continentSize = cw and ch and sqrt(cw * cw + ch * ch)
  local w, h = call(C_Map.GetMapWorldSize, mapID)
  map.size = w and h and sqrt(w * w + h * h)
  ns.note("map", { mapID = mapID, name = map.name, width = map.width, height = map.height, tiles = cols * rows, loaded = loaded,
    layers = #layers, continent = map.continent, hereX = map.hereX, hereY = map.hereY, answerX = map.answerX,
    answerY = map.answerY, size = map.size, continentSize = map.continentSize, where = here })
  say(("Map %d %s: %dx%d in %d tiles of %dx%d, %d loaded; %s layers; continent map %s"):format(mapID, map.name, map.width,
    map.height, cols * rows, layer.tileWidth, layer.tileHeight, loaded, tostring(#layers), tostring(map.continent)))
  if map.hereX and map.answerX then
    say(("  you on it: by the map %.4f, %.4f; from the world %.4f, %.4f"):format(map.hereX, map.hereY, map.answerX, map.answerY))
  end
  line:Hide()
  highlight:Hide()
  canvas:Show()
  arrange()
end

function mode.stop()
  canvas:Hide()
  map = nil
end

local function guess(x, y)
  local m = map
  m.guessX, m.guessY = x, y
  local _, continent, world = ns.call(C_Map.GetWorldPosFromMapPos, m.id, CreateVector2D(x, y))
  local here = m.here
  local words
  if not continent then
    words = "the client can't put that in the world"
  elseif continent ~= here.continent or not here.worldX then
    words = ("that's on another continent (%s, you're on %s): no points"):format(tostring(continent), tostring(here.continent))
  else
    local gx, gy = world:GetXY()
    local dx, dy = gx - here.worldX, gy - here.worldY
    local yards = sqrt(dx * dx + dy * dy)
    local function score(size)
      return size and floor(BEST * exp(-FALLOFF * yards / size) + 0.5)
    end
    words = ("%d yards out: %s points on a continent round, %s on a round of %s"):format(floor(yards + 0.5),
      tostring(score(m.continentSize)), tostring(score(m.size)), m.name)
  end
  if m.answerX then
    line:SetStartPoint("TOPLEFT", canvas, x * m.width, -y * m.height)
    line:SetEndPoint("TOPLEFT", canvas, m.answerX * m.width, -m.answerY * m.height)
    line:Show()
  end
  m.said = words
  ns.note("guess", { mapID = m.id, x = x, y = y, words = words, continent = continent, worldX = world and world.x, worldY = world and world.y })
  say("Guess: " .. words)
  arrange()
end

function mode.update()
  local m = map
  if not m then
    return
  end
  if m.grab then
    local x, y = ns.cursor()
    if abs(x - m.grab[1]) + abs(y - m.grab[2]) > DRAG then
      m.dragged = true
    end
    if m.dragged then
      m.x, m.y = m.grab[3] + x - m.grab[1], m.grab[4] + y - m.grab[2]
      arrange()
    end
  end
  local x, y = under()
  local inside = x >= 0 and x <= 1 and y >= 0 and y <= 1
  if m.lastX ~= x or m.lastY ~= y then
    m.lastX, m.lastY = x, y
    local zone = inside and call(C_Map.GetMapInfoAtPosition, m.id, x, y)
    m.zoneName = zone and zone.mapID ~= m.id and zone.name or nil
    local fileID, atlas, px, py, tw, th, sx, sy
    if inside then
      fileID, atlas, px, py, tw, th, sx, sy = call(C_Map.GetMapHighlightInfoAtPosition, m.id, x, y)
    end
    if inside and ((fileID and fileID > 0) or atlas) then
      highlight:ClearAllPoints()
      highlight:SetTexCoord(0, px, 0, py)
      if atlas then
        highlight:SetAtlas(atlas, true)
        highlight:SetPoint("CENTER", canvas, "TOPLEFT", (sx + 0.5 * tw) * m.width, -(sy + 0.5 * th) * m.height)
      else
        highlight:SetTexture(fileID, nil, nil, "TRILINEAR")
        highlight:SetSize(max(1, tw * m.width), max(1, th * m.height))
        highlight:SetPoint("TOPLEFT", canvas, "TOPLEFT", sx * m.width, -sy * m.height)
      end
      highlight:Show()
    else
      highlight:Hide()
    end
  end
  ns.readout(("%s (map %d)%s   zoom %.1f\n%s\n%s"):format(m.name, m.id,
    inside and ("   %.3f, %.3f%s"):format(x, y, m.zoneName and ("   " .. m.zoneName) or "") or "", m.zoom,
    m.said or "click to guess where you are",
    "drag moves, wheel zooms, Shift-click goes in, right-click goes out, Escape stops"))
end

function mode.wheel(delta)
  local m = map
  if not m then
    return
  end
  local x, y = ns.cursor()
  local before = m.fit * m.zoom
  m.zoom = max(1, min(MAX_ZOOM, m.zoom * 1.25 ^ delta))
  local after = m.fit * m.zoom
  -- Zoomed on whatever is under the cursor
  m.x = x - (x - m.x) * after / before
  m.y = y - (y - m.y) * after / before
  arrange()
end

function mode.down(button)
  local m = map
  if m and button == "LeftButton" then
    local x, y = ns.cursor()
    m.grab, m.dragged = { x, y, m.x, m.y }, false
  end
end

function mode.up(button)
  local m = map
  if not m then
    return
  end
  if button == "RightButton" then
    local info = call(C_Map.GetMapInfo, m.id)
    if info and info.parentMapID and info.parentMapID > 0 then
      load(info.parentMapID)
    end
    return
  end
  if button ~= "LeftButton" then
    return
  end
  local dragged = m.dragged
  m.grab, m.dragged = nil, false
  if dragged then
    return
  end
  local x, y = under()
  if x < 0 or x > 1 or y < 0 or y > 1 then
    return
  end
  if IsShiftKeyDown() then
    local zone = call(C_Map.GetMapInfoAtPosition, m.id, x, y)
    if zone and zone.mapID ~= m.id then
      load(zone.mapID)
    end
    return
  end
  guess(x, y)
end

function load(mapID)
  ns.begin(mode, mapID)
end

ns.commands.map = {
  usage = "[mapID]",
  run = function(words)
    local mapID = tonumber(words[2]) or call(C_Map.GetBestMapForUnit, "player")
    if not mapID then
      say("|cffff4040The client doesn't say what map you're on|r")
      return true
    end
    load(mapID)
    return true
  end,
}
