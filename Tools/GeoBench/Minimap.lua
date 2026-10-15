--------------------------
--  Geo Bench: the ground from above
--------------------------
-- The client's minimap is a picture from above of every tile of its terrain (533 1/3 yards
-- across, 64 by 64 to a continent), and every one of them is a picture an addon can show by its
-- file id (Data/Minimaps.lua, from the community's list of the client's files). A round of
-- "where is this, seen from above" would need nothing shipped.
--
-- This shows the tiles round the one you stand on, with you on them where UnitPosition says, to
-- tell whether the tiles load, which way round they are, and whether the sums putting you on
-- them are right. Arrows walk the view a tile at a time.
--
--   /geobench minimap [n]        n by n tiles round you, 3 if not said
--   /geobench minimap random     n by n round a tile of the original game's, any
--
-- The ids are never tried blind: only those the list has, and only the original game's for
-- random (see Data/Minimaps.lua).

local _, ns = ...
local say = ns.say
local floor, min, max = math.floor, math.min, math.max

local SIZE = 256
local FOLDERS = { [0] = "Azeroth", [1] = "Kalimdor" }

function ns.minimapFolder(instance)
  return FOLDERS[instance]
end

--- The file id of a tile, nil if there isn't one (or only a later one when `original`)
function ns.minimapTile(instance, col, row, original)
  local folder = FOLDERS[instance]
  local tiles = folder and ns.MINIMAPS and ns.MINIMAPS[folder]
  local id = tiles and col and row and tiles[col * 100 + row]
  if not id or (original and id < 0) then
    return nil
  end
  return math.abs(id)
end

local frame = ns.frame
local tiles = {}
local you = frame:CreateTexture(nil, "OVERLAY")
local dot = frame:CreateTexture(nil, "OVERLAY", nil, -1)
dot:SetColorTexture(0, 0, 0, 0.8)
dot:SetSize(12, 12)

local view

local function draw()
  local v = view
  local n, scale = v.n, v.scale
  local size = SIZE * scale
  local half = floor(n / 2)
  local loaded, missing = 0, 0
  for index = 1, max(#tiles, n * n) do
    local tile = tiles[index]
    if index <= n * n then
      if not tile then
        tile = { texture = frame:CreateTexture(nil, "ARTWORK"), label = ns.cover:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall") }
        tiles[index] = tile
      end
      local across, down = (index - 1) % n, floor((index - 1) / n)
      local col, row = v.col - half + across, v.row - half + down
      local id = ns.minimapTile(v.instance, col, row)
      local t = tile.texture
      t:SetSize(size, size)
      t:SetPoint("TOPLEFT", frame, "TOPLEFT", across * size, -down * size)
      if id and t:SetTexture(id) ~= false then
        loaded = loaded + 1
        t:Show()
      else
        if id then
          missing = missing + 1
        end
        t:Hide()
      end
      tile.label:SetPoint("TOPLEFT", frame, "TOPLEFT", across * size + 3, -down * size - 3)
      tile.label:SetText(("%d_%d%s"):format(col, row, id and "" or " none"))
      tile.label:Show()
    elseif tile then
      tile.texture:Hide()
      tile.label:Hide()
    end
  end
  -- You, if you are on one of them
  local here = v.here
  local onCol = here.unitB and (32 - here.unitB / ns.TILE)
  local onRow = here.unitA and (32 - here.unitA / ns.TILE)
  local across = onCol and onCol - (v.col - half)
  local down = onRow and onRow - (v.row - half)
  if not v.random and across and across >= 0 and across < n and down >= 0 and down < n then
    local x, y = across * size, -down * size
    dot:SetPoint("CENTER", frame, "TOPLEFT", x, y)
    dot:Show()
    if you:SetTexture("Interface\\Minimap\\MinimapArrow") ~= false then
      you:SetSize(40, 40)
      if here.facing then
        you:SetRotation(here.facing)
      end
    else
      you:SetColorTexture(0.2, 0.9, 1, 1)
      you:SetSize(5, 5)
    end
    you:SetPoint("CENTER", frame, "TOPLEFT", x, y)
    you:Show()
  else
    dot:Hide()
    you:Hide()
  end
  if not v.noted then
    v.noted = true
    ns.note("minimap", { instance = v.instance, col = v.col, row = v.row, n = n, loaded = loaded, missing = missing,
      random = v.random, onCol = onCol, onRow = onRow, where = here })
  end
  ns.readout(("%s, tiles %d_%d round the middle: %d loaded%s%s\n%s"):format(FOLDERS[v.instance] or "?", v.col, v.row,
    loaded, missing > 0 and (", |cffff4040%d didn't load|r"):format(missing) or "",
    across and not v.random and (" - you are at %.2f, %.2f of tile %d_%d"):format(onCol % 1, onRow % 1, floor(onCol), floor(onRow)) or "",
    "arrows walk a tile, Escape stops"))
end

local mode = {}

function mode.start(n, random)
  local here = ns.where()
  if not ns.MINIMAPS then
    say("|cffff4040No Data/Minimaps.lua: run make_minimaps.py|r")
    ns.finish()
    return
  end
  local instance, col, row = here.instance, here.tileCol, here.tileRow
  if random then
    -- Any tile of the original game's, on either continent
    instance = math.random(0, 1)
    local choices = {}
    for key, id in pairs(ns.MINIMAPS[FOLDERS[instance]]) do
      if id > 0 then
        choices[#choices + 1] = key
      end
    end
    local key = choices[math.random(#choices)]
    col, row = floor(key / 100), key % 100
  elseif not FOLDERS[instance] then
    say(("|cffff4040Instance %s isn't one of the two continents|r"):format(tostring(instance)))
    ns.finish()
    return
  end
  local scale = ns.window(n * SIZE, n * SIZE)
  view = { n = n, scale = scale, here = here, instance = instance, col = col, row = row, random = random }
  draw()
end

function mode.stop()
  for _, tile in ipairs(tiles) do
    tile.texture:Hide()
    tile.label:Hide()
  end
  you:Hide()
  dot:Hide()
  view = nil
end

local STEPS = { LEFT = { -1, 0 }, RIGHT = { 1, 0 }, UP = { 0, -1 }, DOWN = { 0, 1 } }

function mode.key(key, down)
  local step = STEPS[key]
  if not step or not view then
    return false
  end
  if down then
    view.col, view.row = view.col + step[1], view.row + step[2]
    draw()
  end
  return true
end

ns.commands.minimap = {
  usage = "[n] | random [n]",
  run = function(words)
    local random = words[2] and words[2]:lower() == "random"
    local n = tonumber(words[random and 3 or 2]) or 3
    n = max(1, min(9, floor(n)))
    ns.begin(mode, n, random)
    return true
  end,
}
