--------------------------
--  Kart Bench: finds
--------------------------
-- What races could use of the client's own, side by side to look at: its mounts, the zones'
-- doodads and their ground.
--
-- Which displays are mounts comes from the client's own tables (CreatureDisplayInfo, whose
-- model is a CreatureModelData, whose file is a mount's), as wago.tools exports them for this
-- build, 1.60.1.70374, and the files' names from the community's list of the client's files
-- (github.com/wowdev/wow-listfile), as do the doodads and ground below. Every doodad's file is
-- one of the build's ModelFileData.
--
-- A display id is never tried blind: this client stops with ASSERT(fileDataID) when a model is
-- asked to show a display that has no model, and most ids between the ones it has are none.
--
--   /kartbench gallery <which>    mounts, racers, tanaris, gadgetzan, winterspring or ground. Left and right
--                                 turn the page, up and down bring models nearer and further
--
-- The racers are the mounts chosen to race on (the "mounts" option of plane, drive and hills).

local _, ns = ...
local floor, min, max = math.floor, math.min, math.max

-- The mounts' displays, by the model they show
local MOUNTS = {
  { "Raptor", 4806, 6469, 6470, 6471, 6472, 6473, 29102 },
  { "Raptor (war)", 14339, 14340, 14341, 14342, 14343, 14344, 14345, 14388, 15271, 15289, 119219, 125138 },
  { "Horse", 2402, 2404, 2405, 2408, 2409, 2410, 138880, 138881 },
  { "Horse (war)", 14337, 14338, 14582, 14583, 117614, 126921 },
  { "Ram", 2736, 2784, 2785, 2786, 2787 },
  { "Ram (war)", 14346, 14347, 14576, 14577, 14777 },
  { "Kodo", 11641, 12240, 12241, 12242, 12244, 12245, 12246, 12247, 145785 },
  { "Kodo (war)", 14348, 14349, 14578, 14579 },
  { "Mechanostrider", 6544, 6569, 9473, 9474, 9475, 9476, 10661, 10662, 10664, 10666, 10667 },
  { "Mechanostrider (gnome)", 6978, 6979 },
  { "Mechanostrider (war)", 14372, 14373, 14374, 14375, 14376, 14377, 14581 },
  { "Skeletal horse", 5228, 10670, 10671, 10672, 10673, 140366, 140881, 140883, 140884, 145022 },
  { "Deathcharger", 10718, 10719, 10720, 10721, 16937, 16938, 16939, 126452, 126453, 126454, 126455, 144570, 145406 },
  { "Wolf", 207, 247, 1166, 2320, 2326, 2327, 2328, 2833, 144674 },
  { "Wolf (war)", 14334, 14335, 14336, 14573, 14574, 14575, 14776 },
  { "Saber", 4805, 6079, 6080, 6442, 6443, 6444, 6447, 6448, 9695, 9714, 9952, 9991, 10426, 144018, 144390, 144509 },
  { "Saber (war)", 14329, 14330, 14331, 14332, 14333, 14632, 15290, 125139 },
  { "Qiraji battle tank", 15677, 15678, 15679, 15680, 15681, 124496, 124497, 124498, 124499, 124500, 124519 },
  { "Turtle", 17158 },
}

-- The racers: everyday mounts of the kinds chosen, one display for each skin, the swift ones (later
-- displays of the same skins) and those dressed for war left out
local RACERS = {
  { "Ram", 2736, 2784, 2785, 2786, 2787 },
  { "Mechanostrider", 6569, 9473, 9474, 9475, 9476 },
  { "Wolf", 207, 247, 1166, 2320, 2326, 2327, 2328 },
  { "Saber", 4805, 6079, 6080, 6442, 6443, 6444, 6448 },
  { "Turtle", 17158 },
}

--- { display id, kind } of every racer, a kind at a time in turn, so that a few karts are of
--- different kinds
local racers = {}
for round = 2, 8 do
  for _, kind in ipairs(RACERS) do
    if kind[round] then
      racers[#racers + 1] = { kind[round], kind[1] }
    end
  end
end

--- The display of the racer a kart is, by the kart's number
function ns.racer(index)
  return racers[(index - 1) % #racers + 1][1]
end

-- Files by their ids: models for the doodads, pictures for the ground
local GALLERIES = {
  tanaris = { models = true,
    { 202657, "Cactus 1" }, { 202658, "Cactus 2" }, { 202659, "Cactus 3" }, { 202660, "Cactus 4" },
    { 202661, "Cactus 5" }, { 202662, "Cactus 6" }, { 202677, "Rock 1" }, { 202679, "Rock 3" },
    { 202681, "Rock 5" }, { 202683, "Rock 7" }, { 202672, "Goblin wall" }, { 202676, "Goblin wall post" },
    { 202674, "Goblin wall curve" }, { 202687, "Water tower" }, { 307492, "Water tower, steel" },
    { 307576, "Oil tank" }, { 254405, "Bottle rocket" }, { 254420, "Large rocket" }, { 254409, "Crate" },
    { 254423, "Bomb pile" }, { 202670, "Holding pen" },
  },
  -- Goblin things for a town: Gadgetzan's own buildings can't be shown, being the client's other
  -- kind of model (WMO)
  gadgetzan = { models = true,
    { 197791, "Tent 1" }, { 197792, "Tent 2" }, { 197793, "Tent 3" }, { 197794, "Tent 4" }, { 197795, "Tent 5" },
    { 197796, "Tent 6" }, { 197797, "Tent 7" }, { 309145, "Guard tower 1" }, { 309146, "Guard tower 2" },
    { 307162, "Lamp post 1" }, { 307164, "Lamp post 2" }, { 307166, "Lamp post 3" }, { 307167, "Lamp post 4" },
    { 309569, "Signpost 1" }, { 309571, "Signpost 2" }, { 309722, "Signpost 3" }, { 330140, "Kezan signpost 1" },
    { 330141, "Kezan signpost 2" }, { 321180, "Billboard 1" }, { 322189, "Billboard 2" }, { 326714, "Billboard 3" },
    { 332767, "Smokestack" }, { 378620, "Smokestacks 1" }, { 378621, "Smokestacks 3" }, { 378622, "Smokestacks 4" },
    { 197767, "Machinery" }, { 197768, "Weathervane" }, { 197766, "Hut bottles" }, { 197789, "Shredder suit 1" },
    { 197790, "Shredder suit 2" }, { 197779, "Rocket cart 1" }, { 197780, "Rocket cart 2" }, { 197781, "Rocket cart 3" },
    { 197782, "Rocket cart 4" }, { 197783, "Rocket cart 5" }, { 197799, "TNT wagon" }, { 311649, "Battery machine" },
    { 328144, "Rock cutter" }, { 315224, "Crazy machine 1" }, { 317825, "Crazy machine 2" }, { 309721, "Crazy machine 3" },
    { 314504, "Crazy machine 4" }, { 309912, "Crazy machine 7" }, { 307336, "Fence 1" }, { 307340, "Fence 5" },
    { 322442, "Standing rocket" }, { 325249, "Warning sign 1" }, { 325250, "Warning sign 2" },
  },
  winterspring = { models = true,
    { 202876, "Tree 1" }, { 202877, "Tree 2" }, { 202878, "Tree 3" }, { 202857, "New tree 1" },
    { 202858, "New tree 2" }, { 202859, "New tree 5" }, { 202855, "Middle tree 1" }, { 202868, "Bush" },
    { 202873, "Fallen tree" }, { 202834, "Frozen waterfall 1" }, { 202836, "Frozen waterfall 3" },
    { 202839, "Furbolg tent" }, { 202841, "Furbolg totem" }, { 202845, "Rock 1" }, { 202848, "Rock 4" },
    { 202852, "Rock 8" }, { 202832, "Frostsaber rock" }, { 202884, "World tree root" },
  },
  ground = {
    { 188870, "Tanaris sand 1" }, { 188872, "Tanaris sand 2" }, { 188874, "Tanaris sand 3" },
    { 188855, "Tanaris cracked ground" }, { 188866, "Tanaris rock" }, { 188876, "Tanaris sand stones" },
    { 189053, "Winterspring snow" }, { 189051, "Winterspring snow ripples" }, { 189043, "Winterspring ice" },
    { 189049, "Winterspring rock and snow" }, { 189029, "Winterspring dirt" }, { 189035, "Winterspring ice 2" },
  },
}

local ACROSS, DOWN = 4, 3
local cells = {}
local zoom = 1

--------------------------------------------------------------------------------
-- Gallery

--- What a gallery shows: { id, name } for each, and whether they are models
local function items(which)
  if which == "mounts" then
    local list = { models = true, displays = true }
    for _, mount in ipairs(MOUNTS) do
      for index = 2, #mount do
        list[#list + 1] = { mount[index], mount[1] }
      end
    end
    return list
  elseif which == "racers" then
    local list = { models = true, displays = true }
    for _, kind in ipairs(RACERS) do
      for index = 2, #kind do
        list[#list + 1] = { kind[index], kind[1] }
      end
    end
    return list
  end
  return GALLERIES[which]
end

--- Points a cell's scene at its model from `distance` yards away, a little above it, turned `turn`
local function aimScene(cell, turn)
  local scene, distance = cell.scene, 12 * zoom
  scene:SetCameraPosition(math.cos(turn) * distance, math.sin(turn) * distance, distance * 0.45)
  -- Looking back at the model and a little down: by the directions it looks, to its right and up
  local yaw, pitch = turn + math.pi, 0.35
  local x, y, down, level = math.cos(yaw), math.sin(yaw), math.sin(pitch), math.cos(pitch)
  if scene.SetCameraOrientationByAxisVectors then
    scene:SetCameraOrientationByAxisVectors(x * level, y * level, -down, y, -x, 0, x * down, y * down, level)
  else
    scene:SetCameraOrientationByYawPitchRoll(yaw, pitch, 0)
  end
end

local function setCell(cell, item, list)
  cell.item, cell.since, cell.known = item, 0, nil
  cell.model:Hide()
  cell.texture:Hide()
  if cell.scene then
    cell.scene:Hide()
  end
  if not item then
    cell.label:Hide()
    return
  end
  if list.models and not list.displays and cell.scene then
    -- A model's file in a scene of its own, the camera going round it
    cell.actor:SetModelByFileID(item[1])
    cell.actor:SetPosition(0, 0, -2)
    aimScene(cell, 0.6)
    cell.scene:Show()
    cell.known = true
  elseif list.models then
    local model = cell.model
    pcall(model.ClearModel, model)
    model:Show()
    if list.displays then
      model:SetDisplayInfo(item[1])
    else
      model:SetModel(item[1])
    end
    pcall(model.SetCamDistanceScale, model, zoom)
    model:SetFacing(0.6)
  else
    cell.known = cell.texture:SetTexture(item[1], "REPEAT", "REPEAT")
    cell.texture:SetTexCoord(0, 2, 0, 2)
    cell.texture:Show()
  end
  cell.label:SetText(("%s\n%d"):format(item[2], item[1]))
  cell.label:Show()
end

local function showPage(bench)
  local gallery = bench.gallery
  local list = gallery.list
  local first = (gallery.page - 1) * ACROSS * DOWN
  for index = 1, ACROSS * DOWN do
    setCell(cells[index], list[first + index], list)
  end
  local pages = max(1, math.ceil(#list / (ACROSS * DOWN)))
  ns.readout:SetText(("%s, page %d of %d: left and right for more, up and down to zoom, Escape closes"):format(
    gallery.which, gallery.page, pages))
end

local function galleryStart(bench)
  local which = bench.options.which
  local list = items(which)
  bench.gallery = { which = which, list = list, page = 1, clock = 0 }
  KartBenchDB.gallery = KartBenchDB.gallery or {}
  KartBenchDB.gallery[which] = KartBenchDB.gallery[which] or {}
  local scale, frame = bench.scale, ns.frame
  local width, height = ns.WIDTH / ACROSS, (ns.HEIGHT - 50) / DOWN
  for index = 1, ACROSS * DOWN do
    local cell = cells[index]
    if not cell then
      cell = { model = CreateFrame("PlayerModel", nil, ns.stage), texture = frame:CreateTexture(nil, "ARTWORK"),
        label = ns.cover:CreateFontString(nil, "OVERLAY", "GameFontHighlight") }
      local ok, scene = pcall(CreateFrame, "ModelScene", nil, ns.stage)
      if ok and scene and scene.CreateActor then
        cell.scene, cell.actor = scene, scene:CreateActor()
        pcall(scene.SetCameraFieldOfView, scene, 0.9)
      end
      cells[index] = cell
    end
    local column, row = (index - 1) % ACROSS, floor((index - 1) / ACROSS)
    local left, top = column * width, 50 + row * height
    cell.model:ClearAllPoints()
    cell.model:SetPoint("TOPLEFT", frame, "TOPLEFT", (left + 4) * scale, -(top + 2) * scale)
    cell.model:SetSize((width - 8) * scale, (height - 30) * scale)
    if cell.scene then
      cell.scene:ClearAllPoints()
      cell.scene:SetAllPoints(cell.model)
    end
    local side = min(width - 16, height - 34)
    cell.texture:ClearAllPoints()
    cell.texture:SetPoint("TOP", frame, "TOPLEFT", (left + width / 2) * scale, -(top + 2) * scale)
    cell.texture:SetSize(side * scale, side * scale)
    cell.label:ClearAllPoints()
    cell.label:SetPoint("BOTTOM", frame, "TOPLEFT", (left + width / 2) * scale, -(top + height - 2) * scale)
  end
  pcall(frame.EnableKeyboard, frame, true)
  showPage(bench)
end

local function galleryUpdate(bench, elapsed)
  local gallery = bench.gallery
  gallery.clock = gallery.clock + elapsed
  local seen = KartBenchDB.gallery[gallery.which]
  for _, cell in ipairs(cells) do
    local item = cell.item
    if item and cell.scene and cell.scene:IsShown() then
      aimScene(cell, 0.6 + gallery.clock * 0.5)
    elseif item and gallery.list.models then
      cell.since = cell.since + elapsed
      cell.model:SetFacing(0.6 + gallery.clock * 0.5)
      if cell.known == nil then
        if cell.model:GetModelFileID() then
          cell.known = true
        elseif cell.since > 3 then
          cell.known = false
        end
      end
    end
    if item and cell.known ~= nil and seen[item[1]] == nil then
      seen[item[1]] = cell.known
      if cell.known == false then
        cell.label:SetText(("%s\n%d |cffff4040not found|r"):format(item[2], item[1]))
      end
    end
  end
end

ns.modes.gallery = {
  unmeasured = true,
  start = galleryStart,
  update = galleryUpdate,
  describe = function(bench)
    return "gallery " .. bench.options.which
  end,
  hide = function()
    for _, cell in ipairs(cells) do
      pcall(cell.model.ClearModel, cell.model)
      cell.model:Hide()
      if cell.scene then
        cell.scene:Hide()
      end
      cell.texture:Hide()
      cell.label:Hide()
      cell.item = nil
    end
  end,
  key = function(bench, key)
    local gallery = bench.gallery
    local pages = max(1, math.ceil(#gallery.list / (ACROSS * DOWN)))
    if key == "LEFT" or key == "RIGHT" then
      gallery.page = (gallery.page - 1 + (key == "LEFT" and -1 or 1)) % pages + 1
      showPage(bench)
      return true
    elseif key == "UP" or key == "DOWN" then
      zoom = min(8, max(0.1, zoom * (key == "UP" and 0.8 or 1.25)))
      for _, cell in ipairs(cells) do
        pcall(cell.model.SetCamDistanceScale, cell.model, zoom)
      end
      return true
    end
  end,
}

ns.commands.gallery = {
  usage = "mounts|racers|tanaris|gadgetzan|winterspring|ground: look at what races could use",
  run = function(words)
    local which = words[2]
    if which ~= "mounts" and which ~= "racers" and not GALLERIES[which] then
      return false
    end
    ns.start({ kind = "gallery", which = which })
    return true
  end,
}
