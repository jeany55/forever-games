--------------------------
--  Geo Bench
--------------------------
-- Whether a game of guessing where in the world a picture was taken could be made in the client,
-- and how: a separate addon like Doom Bench and Kart Bench, installed with its own install.sh,
-- not part of Forever Games.
--
-- The client can't draw the world into a frame of its own, so the places are pictures: a ring of
-- screenshots taken from one spot, the camera turned a step between each (Capture.lua), stitched
-- into one panorama outside the game (stitch.py). The panorama is looked around in by drawing it
-- a column at a time, each the slice of the cylinder that column of the screen sees (Pano.lua).
-- The guess is made on the client's own map art (Map.lua), and how far out it was in yards comes
-- from where the map says it is in the world. Without any pictures of our own there is also the
-- client's minimap, a picture from above of every patch of ground (Minimap.lua).
--
--   /geobench probe                 which of what the game needs the client has, and what loads
--   /geobench where                 where you are, every way the client says so
--   /geobench capture [options]     a panorama from where you stand (Capture.lua)
--   /geobench captures              the panoramas taken so far
--   /geobench pano [name] [options] look around in a panorama (Pano.lua)
--   /geobench sweep                 the panorama viewer measured at a few column counts
--   /geobench map [mapID]           guess on the map (Map.lua)
--   /geobench minimap [n]           the ground from above around you (Minimap.lua)
--   /geobench stop                  or Escape

--- What the other files of the bench share with this one
local _, ns = ...
ns.commands = {}

ns.IMAGES = "Interface\\AddOns\\GeoBench\\Images\\"

local floor = math.floor

function ns.say(text)
  print("|cff40c0ffGeo Bench|r " .. text)
end
local say = ns.say

function ns.cvar(name)
  local ok, value = pcall(C_CVar.GetCVar, name)
  return ok and value or nil
end

--- Sets a cvar, and what it is now: the client keeps the old value for one it doesn't take
function ns.setCVar(name, value)
  pcall(C_CVar.SetCVar, name, tostring(value))
  return ns.cvar(name)
end

function ns.environment()
  local version, build = GetBuildInfo()
  local width, height = GetPhysicalScreenSize()
  return ("%s.%s, screen %dx%d, fov %s"):format(version, build, width, height, ns.cvar("cameraFov") or "?")
end

local function passed(ok, ...)
  if ok then
    return true, ...
  end
  return false
end

--- Calls something of the client's that may not be there or may fail: true and what it gave,
--- or only false
local function call(f, ...)
  if type(f) ~= "function" then
    return false
  end
  return passed(pcall(f, ...))
end
ns.call = call

-- The ground the client's terrain is cut into: 64 by 64 tiles of 533 1/3 yards, the middle of
-- the world at the corner between the 32nd and 33rd
ns.TILE = 1600 / 3

--- Where you are, every way the client says so. Nothing in it is guessed: what the client doesn't
--- answer is left out
function ns.where()
  local here = { zone = GetZoneText(), subzone = GetSubZoneText(), when = date("%Y-%m-%d %H:%M:%S") }
  local ok, mapID = call(C_Map.GetBestMapForUnit, "player")
  if ok and mapID then
    here.mapID = mapID
    local _, info = call(C_Map.GetMapInfo, mapID)
    here.mapName = info and info.name
    local _, position = call(C_Map.GetPlayerMapPosition, mapID, "player")
    if position then
      here.x, here.y = position:GetXY()
      local _, continent, world = call(C_Map.GetWorldPosFromMapPos, mapID, position)
      if continent and world then
        here.continent = continent
        here.worldX, here.worldY = world:GetXY()
      end
    end
    local _, width, height = call(C_Map.GetMapWorldSize, mapID)
    here.mapWidth, here.mapHeight = width, height
  end
  local _, a, b, c, instance = call(UnitPosition, "player")
  if a then
    here.unitA, here.unitB, here.unitZ, here.instance = a, b, c, instance
    -- The first is north, the second west, as the terrain's tiles have them
    here.tileCol = floor(32 - b / ns.TILE)
    here.tileRow = floor(32 - a / ns.TILE)
  end
  local _, facing = call(GetPlayerFacing)
  here.facing = facing
  return here
end

local function sayWhere(here)
  say(("%s / %s, map %s (%s) at %.4f, %.4f"):format(here.zone or "?", here.subzone or "", tostring(here.mapID),
    here.mapName or "?", here.x or -1, here.y or -1))
  say(("  map pos to world: continent %s, %.1f, %.1f; map is %s x %s yards"):format(tostring(here.continent),
    here.worldX or 0, here.worldY or 0, tostring(here.mapWidth), tostring(here.mapHeight)))
  say(("  UnitPosition: %.1f, %.1f, %.1f in instance %s; terrain tile map%s_%s; facing %s"):format(here.unitA or 0,
    here.unitB or 0, here.unitZ or 0, tostring(here.instance), tostring(here.tileCol), tostring(here.tileRow),
    here.facing and ("%.3f"):format(here.facing) or "?"))
end
ns.sayWhere = sayWhere

----------------------------------------------------------------------
-- The window the viewers draw in, and the readout over it
----------------------------------------------------------------------

local frame = CreateFrame("Frame", "GeoBenchFrame", UIParent)
frame:SetFrameStrata("DIALOG")
frame:SetPoint("CENTER")
frame:SetClipsChildren(true)
frame:EnableMouse(true)
frame:EnableMouseWheel(true)
frame:Hide()
tinsert(UISpecialFrames, "GeoBenchFrame")
local black = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
black:SetAllPoints()
black:SetColorTexture(0, 0, 0, 1)
local cover = CreateFrame("Frame", nil, frame)
cover:SetAllPoints()
cover:SetFrameLevel(frame:GetFrameLevel() + 100)
local readout = cover:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
readout:SetPoint("TOPLEFT", 10, -10)
readout:SetJustifyH("LEFT")
local shade = cover:CreateTexture(nil, "BORDER")
shade:SetPoint("TOPLEFT", readout, -6, 6)
shade:SetPoint("BOTTOMRIGHT", readout, 6, -6)
shade:SetColorTexture(0, 0, 0, 0.55)
ns.frame, ns.cover = frame, cover

function ns.readout(text)
  readout:SetText(text)
end

--- Sizes the window for a viewer: as much of the screen as `width` by `height` can have at
--- their shape, and how many of the window's own units one of the viewer's is
function ns.window(width, height)
  local scale = math.min(1, UIParent:GetWidth() * 0.92 / width, UIParent:GetHeight() * 0.88 / height)
  frame:SetSize(width * scale, height * scale)
  return scale
end

----------------------------------------------------------------------
-- Modes: one viewer at a time has the window
----------------------------------------------------------------------

ns.modes = {}
local current

--- Begins a mode: { start(args), update(elapsed), stop(), key(key), wheel(delta), down(button),
--- up(button) }, each but start left out if it has nothing to do
function ns.begin(mode, ...)
  if current then
    ns.finish()
  end
  current = mode
  readout:SetText("")
  frame:Show()
  pcall(frame.EnableKeyboard, frame, true)
  mode.start(...)
end

function ns.finish(why)
  local mode = current
  current = nil
  if mode and mode.stop then
    mode.stop()
  end
  pcall(frame.EnableKeyboard, frame, false)
  frame:Hide()
  if why then
    say(why)
  end
end

frame:SetScript("OnUpdate", function(_, elapsed)
  if current and current.update then
    current.update(elapsed)
  end
end)
frame:SetScript("OnKeyDown", function(self, key)
  if key == "ESCAPE" then
    pcall(self.SetPropagateKeyboardInput, self, false)
    ns.finish("Stopped")
    return
  end
  local taken = current and current.key and current.key(key, true)
  pcall(self.SetPropagateKeyboardInput, self, not taken)
end)
frame:SetScript("OnKeyUp", function(_, key)
  if current and current.key then
    current.key(key, false)
  end
end)
frame:SetScript("OnMouseWheel", function(_, delta)
  if current and current.wheel then
    current.wheel(delta)
  end
end)
frame:SetScript("OnMouseDown", function(_, button)
  if current and current.down then
    current.down(button)
  end
end)
frame:SetScript("OnMouseUp", function(_, button)
  if current and current.up then
    current.up(button)
  end
end)
frame:SetScript("OnHide", function()
  if current then
    ns.finish()
  end
end)

--- Where the cursor is over the window, in the window's own units from its top left corner
function ns.cursor()
  local x, y = GetCursorPosition()
  local scale = frame:GetEffectiveScale()
  return x / scale - frame:GetLeft(), frame:GetTop() - y / scale
end

----------------------------------------------------------------------
-- Measuring: how long frames take while something is drawn
----------------------------------------------------------------------

local WARMUP, MEASURE = 1, 4

--- Keeps what a viewer found in GeoBenchDB.notes, to be read after a /reload
function ns.note(kind, found)
  found.kind, found.when = kind, date("%Y-%m-%d %H:%M:%S")
  table.insert(GeoBenchDB.notes, found)
end

--- A measurement to feed each frame: true when it is done
function ns.measurement(name)
  return { name = name, clock = 0, frames = {}, lua = {}, stall = 0, phase = "warm" }
end

function ns.measure(m, elapsed, luaMs, pieces)
  m.clock = m.clock + elapsed
  m.pieces = math.max(m.pieces or 0, pieces or 0)
  if m.phase == "warm" then
    m.stall = math.max(m.stall, elapsed * 1000)
    if m.clock >= WARMUP then
      m.phase, m.clock = "measure", 0
    end
    return false
  end
  m.frames[#m.frames + 1] = elapsed * 1000
  m.lua[#m.lua + 1] = luaMs
  return m.clock >= MEASURE
end

function ns.result(m)
  table.sort(m.frames)
  local lua = 0
  for _, spent in ipairs(m.lua) do
    lua = lua + spent
  end
  local frameMs = m.frames[math.max(1, math.ceil(#m.frames * 0.5))] or 0
  local outcome = { name = m.name, frameMs = frameMs, frame95Ms = m.frames[math.max(1, math.ceil(#m.frames * 0.95))] or 0,
    luaMs = lua / math.max(1, #m.lua), stallMs = m.stall, frames = #m.frames, pieces = m.pieces,
    fps = #m.frames / MEASURE, when = date("%Y-%m-%d %H:%M:%S"), client = ns.environment() }
  table.insert(GeoBenchDB.results, outcome)
  say(("%s: %.0f fps (median frame %.1f ms, slowest 5%% %.1f ms), Lua %.2f ms, %d pieces, longest while loading %.0f ms"):format(
    outcome.name, outcome.fps, outcome.frameMs, outcome.frame95Ms, outcome.luaMs, outcome.pieces or 0, outcome.stallMs))
  return outcome
end

----------------------------------------------------------------------
-- What the client has
----------------------------------------------------------------------

local NEEDED = {
  { "Screenshot", Screenshot }, { "FlipCameraYaw", FlipCameraYaw }, { "SetUIVisibility", SetUIVisibility },
  { "GetCameraFOVDefaults", GetCameraFOVDefaults }, { "CameraZoomIn", CameraZoomIn }, { "CameraZoomOut", CameraZoomOut },
  { "GetCameraZoom", GetCameraZoom }, { "UnitPosition", UnitPosition }, { "GetPlayerFacing", GetPlayerFacing },
  { "C_Map.GetBestMapForUnit", C_Map.GetBestMapForUnit }, { "C_Map.GetPlayerMapPosition", C_Map.GetPlayerMapPosition },
  { "C_Map.GetWorldPosFromMapPos", C_Map.GetWorldPosFromMapPos }, { "C_Map.GetMapPosFromWorldPos", C_Map.GetMapPosFromWorldPos },
  { "C_Map.GetMapWorldSize", C_Map.GetMapWorldSize }, { "C_Map.GetMapArtLayers", C_Map.GetMapArtLayers },
  { "C_Map.GetMapArtLayerTextures", C_Map.GetMapArtLayerTextures }, { "C_Map.GetMapInfoAtPosition", C_Map.GetMapInfoAtPosition },
  { "C_Map.GetMapHighlightInfoAtPosition", C_Map.GetMapHighlightInfoAtPosition }, { "C_Map.GetMapChildrenInfo", C_Map.GetMapChildrenInfo },
  { "C_Map.GetMapRectOnMap", C_Map.GetMapRectOnMap }, { "CreateVector2D", CreateVector2D },
}

-- Pictures of the client's own to try, by id and by name. Loading screens and the minimap: the
-- minimap's by id come from Data/Minimaps.lua for the tile you stand on
local CLIENT_PICTURES = {
  { "loading screen Eastern Kingdoms by name", "Interface\\Glues\\LoadingScreens\\LoadScreenEasternKingdom" },
  { "loading screen Eastern Kingdoms by id", 131839 },
  { "loading screen Kalimdor by id", 131848 },
}

local probeTexture = frame:CreateTexture(nil, "ARTWORK")
probeTexture:SetSize(1, 1)

local function loads(file, ...)
  local ok, loaded = pcall(probeTexture.SetTexture, probeTexture, file, ...)
  if not ok then
    return "|cffff4040error|r"
  end
  return loaded == true and "loads" or loaded == false and "|cffff4040doesn't load|r" or "can't tell"
end

local function probe()
  local found = { when = date("%Y-%m-%d %H:%M:%S"), client = ns.environment(), functions = {}, pictures = {} }
  local missing = {}
  for _, needed in ipairs(NEEDED) do
    found.functions[needed[1]] = type(needed[2]) == "function"
    if type(needed[2]) ~= "function" then
      missing[#missing + 1] = needed[1]
    end
  end
  say(#missing == 0 and ("All %d functions the game needs are there"):format(#NEEDED)
    or ("|cffff4040Missing:|r %s"):format(table.concat(missing, ", ")))
  local ok, default, least, most = call(GetCameraFOVDefaults)
  say(("Field of view: now %s, default %s, you can set %s to %s"):format(ns.cvar("cameraFov") or "?",
    tostring(ok and default), tostring(least), tostring(most)))
  found.fov = { now = ns.cvar("cameraFov"), default = default, least = least, most = most }
  say(("Screenshots: format %s, quality %s; camera smoothing %s; zoom %s"):format(ns.cvar("screenshotFormat") or "?",
    ns.cvar("screenshotQuality") or "?", ns.cvar("cameraSmoothStyle") or "?", tostring(select(2, call(GetCameraZoom)))))
  local here = ns.where()
  sayWhere(here)
  found.where = here
  local function try(name, ...)
    local words = loads(...)
    found.pictures[name] = words
    say(("  %s: %s"):format(name, words))
  end
  say("Pictures:")
  try("own panorama, clamped", ns.IMAGES .. "test2048_1")
  try("own panorama, repeating", ns.IMAGES .. "test2048_1", "REPEAT", "CLAMP")
  try("own panorama 4096 tile 1", ns.IMAGES .. "test4096_1")
  for _, picture in ipairs(CLIENT_PICTURES) do
    try(picture[1], picture[2])
  end
  local id = ns.minimapTile and here.instance and ns.minimapTile(here.instance, here.tileCol, here.tileRow)
  if id then
    try(("minimap tile you're on by id %d"):format(id), id)
    try("minimap tile you're on by name", ("World\\Minimaps\\%s\\map%d_%d"):format(ns.minimapFolder(here.instance) or "?",
      here.tileCol, here.tileRow))
  else
    say(("  no minimap tile known for instance %s tile %s_%s"):format(tostring(here.instance), tostring(here.tileCol), tostring(here.tileRow)))
  end
  if here.mapID then
    local _, layers = call(C_Map.GetMapArtLayers, here.mapID)
    local _, textures = call(C_Map.GetMapArtLayerTextures, here.mapID, 1)
    local layer = layers and layers[1]
    if layer and textures and textures[1] then
      say(("  map art: %d layers, the first %dx%d in %dx%d tiles, %d textures"):format(#layers, layer.layerWidth,
        layer.layerHeight, layer.tileWidth, layer.tileHeight, #textures))
      try(("map art tile 1 (id %d)"):format(textures[1]), textures[1])
    else
      say("  |cffff4040no map art for your map|r")
    end
  end
  GeoBenchDB.probes[#GeoBenchDB.probes + 1] = found
  say("/reload to keep this in GeoBenchDB")
end

----------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(_, event, name)
  -- At every login and /reload, how to take a place, it being easy to forget
  if event == "PLAYER_LOGIN" then
    local taken = GeoBenchDB and GeoBenchDB.captures and #GeoBenchDB.captures or 0
    say(("|cffffd100/geobench capture|r to take a place: look level, then Enter. %d taken so far, /reload to keep them"):format(taken))
    return
  end
  if name == "GeoBench" then
    GeoBenchDB = GeoBenchDB or {}
    GeoBenchDB.results = GeoBenchDB.results or {}
    GeoBenchDB.probes = GeoBenchDB.probes or {}
    GeoBenchDB.captures = GeoBenchDB.captures or {}
    GeoBenchDB.notes = GeoBenchDB.notes or {}
    frame:UnregisterEvent("ADDON_LOADED")
  end
end)

local function usage()
  say("/geobench probe | where | capture [options] | captures | pano [name] [options] | sweep | map [mapID] | minimap [n] | stop")
  for name, command in pairs(ns.commands) do
    if command.usage then
      say(("  %s %s"):format(name, command.usage))
    end
  end
end

SLASH_GEOBENCH1 = "/geobench"
SlashCmdList.GEOBENCH = function(text)
  local words = {}
  for word in text:gmatch("%S+") do
    words[#words + 1] = word
  end
  local command = words[1] and words[1]:lower()
  if command == "probe" then
    probe()
  elseif command == "where" then
    sayWhere(ns.where())
  elseif command == "stop" then
    ns.finish("Stopped")
    if ns.commands.capture and ns.commands.capture.cancel then
      ns.commands.capture.cancel()
    end
  elseif command and ns.commands[command] then
    if not ns.commands[command].run(words) then
      usage()
    end
  else
    usage()
  end
end
