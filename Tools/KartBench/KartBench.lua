--------------------------
--  Kart Bench
--------------------------
-- Whether a kart racer could be drawn in the client, and how: a separate addon like Doom Bench,
-- installed with its own install.sh, not part of Forever Games.
--
-- The road is drawn the way the old consoles drew theirs: the ground is one flat picture seen
-- from above, and each row of the screen below the horizon is a line across it, so a row is one
-- texture mapped with all eight texture coordinates onto the stretch of the picture it sees.
-- Rows nearer the horizon see further and are thinner, so that what each sees of the ground
-- stays about as deep: rows are drawn from 1 pixel tall at the horizon to thicker at the bottom.
-- Rows never move, only what they show does, which Doom Bench found costs a quarter of moving.
--
-- Each row is two textures: the grass, a small picture repeated, and over it the circuit
-- (Images/track<size>, made by make_images.py), see-through off the road. "flat" leaves the grass
-- out. Then a sky turning with the camera (Images/sky), a haze over the far rows, and the karts: sprites
-- seen from behind, or the client's own 3D models (PlayerModel), the player's character unless a
-- creature's display id is given, to tell what a model costs and how one looks over the road.
--
-- The camera follows a kart round the circuit by itself for the measurements, and every frame is
-- recorded as Doom Bench records them: how long the whole frame took, and how long its own Lua.
-- The longest frame while warming up says how long the client stalled loading the pictures.
-- "drive" is the same with the kart yours to drive (arrows or WASD), for as long as you like,
-- to judge how it looks and feels; it is measured too, until Escape.
--
--   /kartbench sweep                everything, one after the other
--   /kartbench plane [options]      the camera drives round by itself
--   /kartbench drive [options]      you drive, Escape stops
--   /kartbench sizes                the three track pictures side by side, and which loaded
--   /kartbench baseline             nothing at all
--   /kartbench stop                 or Escape
--
-- Options, in any order: rows <n> (how many rows the ground is drawn in, 120 if not said),
-- size <1024|2048|4096> (the track picture, 2048), nearest (square pixels rather than smoothed),
-- flat (no grass under the track), karts <n> (8), models <n> (that many of the karts are 3D
-- models, yours first), display <id> (models of that creature rather than your character), mounts
-- (models of the racers, Finds.lua, rather than your character),
-- ghost (models and karts half see-through), endless (measured until
-- Escape rather than for a few seconds), lag <n> (how quickly the camera swings round behind
-- the kart you drive, 8 if not said, 0 for fixed behind it), grass own|client (the bench's grass
-- or the client's own Elwynn grass, which is tried first).

--- What the other files of the bench share with this one: its frame, and the modes they add
local _, ns = ...
ns.modes, ns.commands = {}, {}

local IMAGES = "Interface\\AddOns\\KartBench\\Images\\"
-- The client's own grass, tried in turn. Nothing of it is shipped: it is the game's
local CLIENT_GRASS = { "Tileset\\Elwynn\\ElwynnGrassBase", "Tileset\\Elwynn\\ElwynnGrass02",
  "Tileset\\Generic\\Grass01" }

-- The screen, and where on it the horizon is
local WIDTH, HEIGHT = 960, 600
local HORIZON = 200
local PLANE = HEIGHT - HORIZON
local FOCAL = WIDTH / 2 / math.tan(math.rad(72) / 2)

-- The circuit, as make_images.py has it: units of the 1024 the picture is across
local WORLD = 1024
local R, A, B, C = 360, 0.18, 0.10, 0.6
local HALF, CURB = 26, 4
-- How many units one tile of grass covers
local GRASS_TILE = 40
-- How far the ground is drawn, beyond which there is only haze
local FARTHEST = 2400

local CAMERA_HEIGHT, CAMERA_BACK = 14, 30
local KART_SIZE, MODEL_SIZE = 7, 10
-- Units a second round the circuit by itself, and driven
local SPEED = 75
local TOP, GRASS_TOP, ACCELERATE, BRAKE, COAST, TURN = 100, 35, 55, 120, 25, 2.2
-- The colour at the bottom of Images/sky, which the far ground fades into
local HAZE = { 175 / 255, 205 / 255, 235 / 255 }

-- Seconds to draw before measuring, and to measure for
local WARMUP, MEASURE = 2, 4
local READOUT_EVERY = 0.25
local DEFAULTS = { rows = 120, size = 2048, karts = 8, models = 0, lag = 8 }
local SWEEP = {
  { kind = "baseline" },
  { rows = 60 },
  { rows = 120 },
  { rows = 240 },
  { rows = 400 },
  { rows = 400, nearest = true },
  { rows = 120, flat = true },
  { rows = 120, size = 1024 },
  { rows = 120, size = 4096 },
  { rows = 120, karts = 32 },
  { rows = 120, models = 1 },
  { rows = 120, models = 4 },
  { rows = 120, models = 8 },
  { rows = 120, models = 16, karts = 16 },
  -- Hills (Hills.lua): rows below the horizon, by bands across
  { kind = "hills" },
  { kind = "hills", bands = 12 },
  { kind = "hills", bands = 24 },
  { kind = "hills", rows = 90 },
  { kind = "hills", models = 4 },
}
local COLOURS = {
  { 0.95, 0.25, 0.2 }, { 0.25, 0.55, 1 }, { 0.3, 0.85, 0.3 }, { 1, 0.85, 0.2 },
  { 0.8, 0.35, 0.95 }, { 1, 0.55, 0.15 }, { 0.2, 0.85, 0.85 }, { 0.95, 0.95, 0.95 },
}

local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local sin, cos, atan2, sqrt, pi = math.sin, math.cos, math.atan2, math.sqrt, math.pi

--- How far from the middle of the circuit the middle of the road is, a way round it
local function radius(a)
  return R * (1 + A * cos(2 * a) + B * sin(3 * a + C))
end

local function slope(a)
  return R * (-2 * A * sin(2 * a) + 3 * B * cos(3 * a + C))
end

--- Where on the circuit a way round it is, `side` units outwards of the middle of the road,
--- which way the road goes there, and how many units round it one radian of `a` is
local function along(a, side)
  local r, dr = radius(a), slope(a)
  local tx, ty = dr * cos(a) - r * sin(a), dr * sin(a) + r * cos(a)
  local length = sqrt(tx * tx + ty * ty)
  tx, ty = tx / length, ty / length
  return WORLD / 2 + r * cos(a) + side * ty, WORLD / 2 + r * sin(a) - side * tx, atan2(ty, tx), length
end

--- How far a point is from the middle of the road, and the way round the circuit it is
local function across(x, y)
  local dx, dy = x - WORLD / 2, y - WORLD / 2
  local a = atan2(dy, dx)
  local r = radius(a)
  local s = slope(a) / r
  return (sqrt(dx * dx + dy * dy) - r) / sqrt(1 + s * s), a
end

local function turnTowards(from, to, part)
  local difference = (to - from + pi) % (2 * pi) - pi
  return from + difference * part
end

local frame = CreateFrame("Frame", "KartBenchFrame", UIParent)
frame:SetFrameStrata("DIALOG")
frame:SetPoint("CENTER")
frame:SetClipsChildren(true)
frame:Hide()
tinsert(UISpecialFrames, "KartBenchFrame")
local black = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
black:SetAllPoints()
black:SetColorTexture(0, 0, 0, 1)
-- Models go over everything drawn on the frame, the readout over them
local stage = CreateFrame("Frame", nil, frame)
stage:SetAllPoints()
stage:SetFrameLevel(frame:GetFrameLevel() + 5)
local cover = CreateFrame("Frame", nil, frame)
cover:SetAllPoints()
cover:SetFrameLevel(frame:GetFrameLevel() + 100)
local readout = cover:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
readout:SetPoint("TOPLEFT", 10, -10)
readout:SetJustifyH("LEFT")
local shade = cover:CreateTexture(nil, "BORDER")
shade:SetPoint("TOPLEFT", readout, -6, 6)
shade:SetPoint("BOTTOMRIGHT", readout, 6, -6)
shade:SetColorTexture(0, 0, 0, 0.75)

local sky = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
local haze = frame:CreateTexture(nil, "ARTWORK", nil, 7)
-- The rows of ground, the sprites, the models and the pictures of `sizes`, kept from one run to the next
local rows, sprites, models, thumbnails = {}, {}, {}, {}

--- @class KartBenchRun
--- @field kind string "plane", "drive", "sizes" or "baseline"
--- @field options table
--- @field edges number[] Where each row of ground begins below the horizon, and the last ends
--- @field scale number Screen points to one of the bench's pixels
--- @field karts table[] Where each kart is: a, side, speed, and x, y, heading worked out each frame
--- @field car table? The kart being driven
--- @field keys table<string, boolean> Which controls are held
--- @field loaded table<string, any> What SetTexture said of each picture
--- @field phase string "ready", "warm" or "measure"
--- @field clock number Seconds into the phase
--- @field frames number[] Milliseconds every measured frame took
--- @field lua number[] Of which in drawing it, in Lua
--- @field time number Seconds since it began, for timing laps
--- @field stall number The longest frame while warming up, in milliseconds
--- @field shown number When the readout was last brought up to date
--- @field endless boolean? Measured until stopped, not for MEASURE seconds
--- @field drives boolean? The driving controls are taken, in a mode other than drive

--- @type KartBenchRun?
local run
local queue, found

local function say(text)
  print("|cff40c0ffKart Bench|r " .. text)
end
ns.frame, ns.stage, ns.cover, ns.readout, ns.say, ns.sky, ns.haze = frame, stage, cover, readout, say, sky, haze
ns.WIDTH, ns.HEIGHT, ns.HORIZON, ns.FOCAL, ns.IMAGES, ns.HAZE = WIDTH, HEIGHT, HORIZON, FOCAL, IMAGES, HAZE

local function cvar(name)
  local ok, value = pcall(C_CVar and C_CVar.GetCVar or GetCVar, name)
  return ok and value or "?"
end

local function environment()
  local version, build = GetBuildInfo()
  local width, height = GetPhysicalScreenSize()
  return ("%s.%s, screen %dx%d, vsync %s, maxFPS %s (on: %s)"):format(version, build, width, height,
    cvar("vsync"), cvar("maxFPS"), cvar("useMaxFPS"))
end

local function describe(bench)
  local mode = ns.modes[bench.kind]
  if mode then
    return mode.describe(bench)
  end
  if bench.kind == "baseline" or bench.kind == "sizes" then
    return bench.kind
  end
  local o = bench.options
  local karts = o.models > 0 and ("%d karts, %d of them models"):format(o.karts, o.models) or ("%d karts"):format(o.karts)
  return ("%s %d rows, track %d, %s, %s, %s%s"):format(bench.kind, #bench.edges - 1, o.size,
    o.nearest and "nearest" or "smooth", o.flat and "no grass" or "grass " .. (bench.grass or "?"), karts,
    (o.ghost and ", ghosts" or "") .. (bench.kind == "drive" and ", lag " .. o.lag or ""))
end

--- Sets a picture, sampled as asked if the client knows how. What SetTexture said of it: true
--- or false where the client tells whether there was such a picture, nil where it doesn't
local function picture(texture, file, wrap, filter)
  if filter then
    local ok, result = pcall(texture.SetTexture, texture, file, wrap, wrap, filter)
    if ok then
      return result
    end
  end
  return texture:SetTexture(file, wrap, wrap)
end

--- Where the rows of ground begin and end below the horizon: each 1 pixel tall or as tall as
--- keeps how deep it sees the same as the others, `count` of them or as near as can be
local function layout(count)
  local first = CAMERA_HEIGHT * FOCAL / FARTHEST
  local function rowsFor(k)
    local o, n = first, 0
    while o < PLANE do
      o, n = o + max(1, o * k), n + 1
    end
    return n
  end
  local low, high = 0, 4
  for _ = 1, 50 do
    local middle = (low + high) / 2
    if rowsFor(middle) > count then
      low = middle
    else
      high = middle
    end
  end
  local edges, o = { first }, first
  while o < PLANE do
    o = min(PLANE, o + max(1, o * high))
    edges[#edges + 1] = o
  end
  return edges
end

local function hideAll()
  for _, row in ipairs(rows) do
    row.ground:Hide()
    row.track:Hide()
  end
  for _, sprite in ipairs(sprites) do
    sprite:Hide()
  end
  for _, model in ipairs(models) do
    model:Hide()
  end
  for _, thumbnail in ipairs(thumbnails) do
    thumbnail.texture:Hide()
    thumbnail.label:Hide()
  end
  sky:Hide()
  haze:Hide()
  for _, mode in pairs(ns.modes) do
    mode.hide()
  end
  pcall(frame.EnableKeyboard, frame, false)
end

local function setModel(model)
  if model.display then
    model:SetDisplayInfo(model.display)
  else
    model:SetUnit("player")
  end
  pcall(model.SetAnimation, model, 5)
end

local function getModel(index)
  local model = models[index]
  if not model then
    model = CreateFrame("PlayerModel", nil, stage)
    model:SetScript("OnShow", setModel)
    pcall(model.SetScript, model, "OnModelLoaded", function()
      pcall(model.SetAnimation, model, 5)
    end)
    models[index] = model
  end
  return model
end

--- Gets everything a run draws ready: the rows, their pictures, the karts
local prepare

function prepare(bench)
  local scale = bench.scale
  local o = bench.options
  local filter = o.nearest and "NEAREST" or nil

  sky:ClearAllPoints()
  sky:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  sky:SetSize(WIDTH * scale, HORIZON * scale + 1)
  if picture(sky, IMAGES .. "sky", "REPEAT") == false then
    sky:SetColorTexture(0.35, 0.55, 0.85)
  end
  sky:SetVertexColor(1, 1, 1)
  sky:Show()

  haze:ClearAllPoints()
  haze:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -HORIZON * scale)
  haze:SetSize(WIDTH * scale, PLANE * 0.15 * scale)
  haze:SetColorTexture(1, 1, 1, 1)
  local r, g, b = HAZE[1], HAZE[2], HAZE[3]
  if not pcall(haze.SetGradient, haze, "VERTICAL", CreateColor(r, g, b, 0), CreateColor(r, g, b, 1)) then
    pcall(haze.SetGradientAlpha, haze, "VERTICAL", r, g, b, 0, r, g, b, 1)
  end
  haze:Show()

  local track = IMAGES .. "track" .. o.size
  local grass = IMAGES .. "grass"
  bench.grass = "own"
  if not o.flat and o.grass ~= "own" then
    local probe = rows[1] and rows[1].ground or frame:CreateTexture(nil, "BACKGROUND")
    rows[1] = rows[1] or { ground = probe, track = frame:CreateTexture(nil, "BORDER") }
    for _, file in ipairs(CLIENT_GRASS) do
      if picture(probe, file, "REPEAT", filter) == true then
        grass, bench.grass = file, file:match("[^\\]+$")
        break
      end
    end
  end

  local edges = bench.edges
  for index = 1, #edges - 1 do
    local row = rows[index] or { ground = frame:CreateTexture(nil, "BACKGROUND"), track = frame:CreateTexture(nil, "BORDER") }
    rows[index] = row
    local top, height = (HORIZON + edges[index]) * scale, (edges[index + 1] - edges[index]) * scale
    for _, texture in ipairs({ row.ground, row.track }) do
      texture:ClearAllPoints()
      texture:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -top)
      texture:SetSize(WIDTH * scale, height)
    end
    if o.flat then
      row.ground:SetColorTexture(0.2, 0.42, 0.16)
    else
      picture(row.ground, grass, "REPEAT", filter)
    end
    row.ground:Show()
    bench.loaded.track = picture(row.track, track, "CLAMP", filter)
    row.track:Show()
  end
  ns.setupKarts(bench)
end

--- The karts a run has, sprites or models, and the one driven if it is driven
function ns.setupKarts(bench)
  local o = bench.options
  for index = 1, o.karts do
    local colour = COLOURS[(index - 1) % #COLOURS + 1]
    local kart = { a = (index - 1) * 0.12, side = index == 1 and 0 or (index % 2 == 0 and -11 or 11),
      speed = SPEED * (index == 1 and 1 or 0.94 + 0.12 * ((index * 37) % 11) / 10) }
    if index <= o.models then
      local model = getModel(index)
      model.display = o.display or (o.mounts and ns.racer(index)) or nil
      model:SetAlpha(o.ghost and 0.5 or 1)
      pcall(model.SetModelAlpha, model, o.ghost and 0.5 or 1)
      kart.model = model
    else
      local sprite = sprites[index] or frame:CreateTexture(nil, "ARTWORK")
      sprites[index] = sprite
      sprite:SetTexture(IMAGES .. "kart")
      sprite:SetTexCoord(0, 1, 0, 1)
      sprite:SetVertexColor(colour[1], colour[2], colour[3])
      sprite:SetAlpha(o.ghost and 0.5 or 1)
      kart.sprite = sprite
    end
    bench.karts[index] = kart
  end

  if bench.kind == "drive" or bench.drives then
    local x, y, heading = along(-0.04, 0)
    bench.car = { x = x, y = y, heading = heading, speed = 0, a = -0.04 }
    bench.camHeading = heading
    pcall(frame.EnableKeyboard, frame, true)
  end
end

--- Where the camera is and which way it looks, after moving everything on by `elapsed`
local function move(bench, elapsed)
  local karts = bench.karts
  for index, kart in ipairs(karts) do
    if not (index == 1 and bench.car) then
      local _, _, _, length = along(kart.a, kart.side)
      kart.a = (kart.a + kart.speed * elapsed / length) % (2 * pi)
      kart.x, kart.y, kart.heading = along(kart.a, kart.side)
    end
  end

  local car = bench.car
  if not car then
    local mine = karts[1]
    local _, _, _, length = along(mine.a, 0)
    local x, y = along(mine.a - CAMERA_BACK / length, 0)
    return x, y, atan2(mine.y - y, mine.x - x)
  end

  -- Driven: off the road the kart can't go fast, and it turns only as it moves
  local keys = bench.keys
  local s, a = across(car.x, car.y)
  local top = abs(s) < HALF + CURB and TOP or GRASS_TOP
  if keys.up then
    car.speed = min(max(top, car.speed), car.speed + ACCELERATE * elapsed)
  elseif keys.down then
    car.speed = max(-20, car.speed - BRAKE * elapsed)
  elseif car.speed > 0 then
    car.speed = max(0, car.speed - COAST * elapsed)
  else
    car.speed = min(0, car.speed + COAST * elapsed)
  end
  if car.speed > top then
    car.speed = max(top, car.speed - 90 * elapsed)
  end
  local steer = (keys.left and -1 or 0) + (keys.right and 1 or 0)
  local grip = min(1, abs(car.speed) / 30) * (car.speed < 0 and -1 or 1)
  car.heading = car.heading + steer * TURN * grip * elapsed
  car.x = min(WORLD, max(0, car.x + cos(car.heading) * car.speed * elapsed))
  car.y = min(WORLD, max(0, car.y + sin(car.heading) * car.speed * elapsed))

  -- Across the line forwards starts a lap and ends the last, backwards spoils it
  local was = car.a
  _, car.a = across(car.x, car.y)
  if was < 0 and car.a >= 0 and was > -1 and abs(s) < HALF + CURB then
    if bench.lapStart then
      local lap = bench.time - bench.lapStart
      bench.best = bench.best and min(bench.best, lap) or lap
      say(("Lap %.2f s (best %.2f s)"):format(lap, bench.best))
    end
    bench.lapStart = bench.time
  elseif was >= 0 and car.a < 0 and was < 1 then
    bench.lapStart = nil
  end

  local mine = karts[1]
  if mine then
    mine.x, mine.y, mine.heading = car.x, car.y, car.heading
  end
  -- The camera swings round behind the kart, or with no lag is fixed behind it
  local lag = bench.options.lag
  bench.camHeading = lag > 0 and turnTowards(bench.camHeading, car.heading, min(1, elapsed * lag)) or car.heading
  local heading = bench.camHeading
  return car.x - cos(heading) * CAMERA_BACK, car.y - sin(heading) * CAMERA_BACK, heading
end

ns.move, ns.along, ns.across, ns.CAMERA_HEIGHT, ns.KART_SIZE, ns.MODEL_SIZE = move, along, across, CAMERA_HEIGHT, KART_SIZE, MODEL_SIZE
ns.CAMERA_BACK, ns.SPEED, ns.COLOURS, ns.turnTowards = CAMERA_BACK, SPEED, COLOURS, turnTowards
ns.DRIVING = { top = TOP, grassTop = GRASS_TOP, accelerate = ACCELERATE, brake = BRAKE, coast = COAST, turn = TURN }

local order = {}

--- One frame
local function draw(bench, camX, camY, heading)
  local scale = bench.scale
  local fx, fy = cos(heading), sin(heading)
  local rx, ry = -fy, fx

  -- The sky turns a quarter of its picture for every quarter turn, as Doom's does
  local u = heading / (pi / 2)
  sky:SetTexCoord(u, u + (2 * math.atan(WIDTH / 2 / FOCAL)) / (pi / 2), 0, 1)

  local edges = bench.edges
  local flat = bench.options.flat
  local near = CAMERA_HEIGHT * FOCAL / edges[1]
  local nearWide = near * (WIDTH / 2) / FOCAL
  for index = 1, #edges - 1 do
    local far, farWide = near, nearWide
    near = CAMERA_HEIGHT * FOCAL / edges[index + 1]
    nearWide = near * (WIDTH / 2) / FOCAL
    local ulx, uly = camX + fx * far - rx * farWide, camY + fy * far - ry * farWide
    local urx, ury = camX + fx * far + rx * farWide, camY + fy * far + ry * farWide
    local llx, lly = camX + fx * near - rx * nearWide, camY + fy * near - ry * nearWide
    local lrx, lry = camX + fx * near + rx * nearWide, camY + fy * near + ry * nearWide
    local row = rows[index]
    row.track:SetTexCoord(ulx / WORLD, uly / WORLD, llx / WORLD, lly / WORLD, urx / WORLD, ury / WORLD, lrx / WORLD, lry / WORLD)
    if not flat then
      row.ground:SetTexCoord(ulx / GRASS_TILE, uly / GRASS_TILE, llx / GRASS_TILE, lly / GRASS_TILE, urx / GRASS_TILE,
        ury / GRASS_TILE, lrx / GRASS_TILE, lry / GRASS_TILE)
    end
  end

  -- The karts, furthest first
  local seen = 0
  for _, kart in ipairs(bench.karts) do
    local dx, dy = kart.x - camX, kart.y - camY
    local depth = dx * fx + dy * fy
    local thing = kart.sprite or kart.model
    if depth > 4 then
      local size = (kart.model and MODEL_SIZE or KART_SIZE) * FOCAL / depth
      local x = WIDTH / 2 + (dx * rx + dy * ry) * FOCAL / depth
      local ground = HORIZON + CAMERA_HEIGHT * FOCAL / depth
      if size >= 2 and x + size > 0 and x - size < WIDTH then
        kart.depth, kart.screenX, kart.ground, kart.size = depth, x, ground, size
        -- Which way it is seen from: straight ahead in the middle of the screen, from further round off to the side
        kart.seenFrom = heading + atan2(dx * rx + dy * ry, depth)
        seen = seen + 1
        order[seen] = kart
      else
        thing:Hide()
      end
    else
      thing:Hide()
    end
  end
  for index = seen + 1, #order do
    order[index] = nil
  end
  table.sort(order, function(one, other)
    return one.depth > other.depth
  end)
  for rank, kart in ipairs(order) do
    local size = kart.size
    if kart.sprite then
      local sprite = kart.sprite
      sprite:SetDrawLayer("ARTWORK", min(6, -8 + rank))
      sprite:ClearAllPoints()
      sprite:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", (kart.screenX - size / 2) * scale, -kart.ground * scale)
      sprite:SetSize(size * scale, size * scale)
      sprite:Show()
    else
      local model = kart.model
      model:SetFrameLevel(stage:GetFrameLevel() + rank)
      model:ClearAllPoints()
      model:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", (kart.screenX - size / 2) * scale, -kart.ground * scale)
      model:SetSize(size * scale, size * scale)
      -- A model's facing turns anticlockwise seen from above, the map's headings clockwise; at pi it
      -- faces away from whoever it is seen by
      model:SetFacing(pi - (kart.heading - kart.seenFrom))
      model:Show()
    end
  end
  return seen
end

local function median(sorted, at)
  return sorted[math.max(1, math.ceil(#sorted * at))] or 0
end

local function result(bench)
  table.sort(bench.frames)
  local lua = 0
  for _, spent in ipairs(bench.lua) do
    lua = lua + spent
  end
  local frameMs = median(bench.frames, 0.5)
  return {
    name = describe(bench),
    kind = bench.kind,
    options = bench.options,
    rows = bench.edges and #bench.edges - 1,
    loaded = bench.loaded,
    grass = bench.grass,
    frameMs = frameMs,
    frame95Ms = median(bench.frames, 0.95),
    luaMs = lua / math.max(1, #bench.lua),
    stallMs = bench.stall,
    fps = frameMs > 0 and 1000 / frameMs or 0,
    frames = #bench.frames,
    best = bench.best,
  }
end

local function report(outcome)
  local loaded = outcome.loaded and outcome.loaded.track
  say(("%s: frame %.1f ms (%.0f fps), slowest 5%% %.1f ms, Lua %.2f ms, longest while loading %.0f ms%s"):format(
    outcome.name, outcome.frameMs, outcome.fps, outcome.frame95Ms, outcome.luaMs, outcome.stallMs,
    loaded == false and ", |cffff4040track picture didn't load|r" or ""))
end

local function conclude(results)
  local baseline = results[1] and results[1].kind == "baseline" and results[1].frameMs or 0
  say(("Each against the frame with nothing in it (%.1f ms):"):format(baseline))
  for _, outcome in ipairs(results) do
    if outcome.kind ~= "baseline" then
      say(("  +%.1f ms  %s"):format(outcome.frameMs - baseline, outcome.name))
    end
  end
  if baseline > 12 then
    say("The empty frame is slow: if vsync or maxFPS hold it back, the differences above hide in it")
  end
  say("/reload to keep these in KartBenchDB")
end

local start

function ns.start(options)
  queue, found = nil, nil
  start(options)
end

local function finish()
  local bench = run
  if not bench then
    return
  end
  run = nil
  hideAll()
  if #bench.frames > 0 then
    local outcome = result(bench)
    outcome.when = date("%Y-%m-%d %H:%M:%S")
    outcome.client = environment()
    table.insert(KartBenchDB.results, outcome)
    report(outcome)
    if found then
      table.insert(found, outcome)
    end
  end
  if queue then
    local following = table.remove(queue, 1)
    if following then
      start(following)
      return
    end
    conclude(found)
    queue, found = nil, nil
  end
  frame:Hide()
end

local stop

function ns.stop(why)
  stop(why)
end

function stop(why)
  queue, found = nil, nil
  if run and run.endless then
    finish()
  elseif run then
    hideAll()
    run = nil
  end
  if why then
    say(why)
  end
  frame:Hide()
end

local function showSizes(bench)
  local scale = bench.scale
  local across = WIDTH / 3
  for index, size in ipairs({ 1024, 2048, 4096 }) do
    local thumbnail = thumbnails[index]
    if not thumbnail then
      thumbnail = { texture = frame:CreateTexture(nil, "ARTWORK"), label = cover:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge") }
      thumbnails[index] = thumbnail
    end
    local texture = thumbnail.texture
    texture:ClearAllPoints()
    texture:SetPoint("TOPLEFT", frame, "TOPLEFT", ((index - 1) * across + 8) * scale, -150 * scale)
    texture:SetSize((across - 16) * scale, (across - 16) * scale)
    local loaded = texture:SetTexture(IMAGES .. "track" .. size)
    texture:Show()
    local words = loaded == true and "loaded" or loaded == false and "|cffff4040didn't load|r" or "can't tell"
    thumbnail.label:ClearAllPoints()
    thumbnail.label:SetPoint("TOP", texture, "BOTTOM", 0, -6)
    thumbnail.label:SetText(("%d: %s"):format(size, words))
    thumbnail.label:Show()
    say(("track%d %s"):format(size, words))
  end
  readout:SetText("The track pictures, as the client loaded them. Escape closes")
end

ns.picture, ns.layout = picture, layout

--- Begins a run
function start(options)
  if run then
    hideAll()
    run = nil
  end
  local scale = min(1, UIParent:GetWidth() * 0.9 / WIDTH, UIParent:GetHeight() * 0.85 / HEIGHT)
  frame:SetSize(WIDTH * scale, HEIGHT * scale)
  local o = {}
  for key, value in pairs(DEFAULTS) do
    o[key] = value
  end
  for key, value in pairs(options) do
    o[key] = value
  end
  -- The camera follows the first
  o.karts = max(1, o.karts, o.models)
  local bench = { kind = o.kind or "plane", options = o, scale = scale, karts = {}, keys = {}, loaded = {},
    phase = "ready", clock = 0, time = 0, frames = {}, lua = {}, stall = 0, shown = 0 }
  o.kind = nil
  bench.endless = bench.kind == "drive" or o.endless
  local mode = ns.modes[bench.kind]
  if mode then
    mode.start(bench)
  elseif bench.kind == "plane" or bench.kind == "drive" then
    bench.edges = layout(min(PLANE, o.rows))
    prepare(bench)
  elseif bench.kind == "sizes" then
    showSizes(bench)
  end
  run = bench
  if bench.kind ~= "sizes" and not (mode and mode.unmeasured) then
    readout:SetText(describe(bench) .. "\ngetting ready")
  end
  frame:Show()
end

frame:SetScript("OnUpdate", function(_, elapsed)
  local bench = run
  if not bench or bench.kind == "sizes" then
    return
  end
  local mode = ns.modes[bench.kind]
  -- A mode that isn't a measurement looks after itself
  if mode and mode.unmeasured then
    mode.update(bench, elapsed)
    return
  end
  if bench.phase == "ready" then
    -- The pictures load in the frame after they are first asked for
    bench.phase, bench.clock = "warm", 0
    return
  end
  local ms = elapsed * 1000
  if bench.phase == "measure" then
    table.insert(bench.frames, ms)
  else
    bench.stall = max(bench.stall, ms)
  end
  bench.time = bench.time + elapsed
  local began = debugprofilestop()
  local seen = 0
  if mode then
    seen = mode.update(bench, min(elapsed, 0.1))
  elseif bench.edges then
    local camX, camY, heading = move(bench, min(elapsed, 0.1))
    seen = draw(bench, camX, camY, heading)
  end
  local spent = debugprofilestop() - began
  bench.clock = bench.clock + elapsed
  if bench.phase == "measure" then
    table.insert(bench.lua, spent)
    if bench.clock >= MEASURE and not bench.endless then
      finish()
      return
    end
  elseif bench.clock >= WARMUP then
    bench.phase, bench.clock = "measure", 0
  end
  if bench.clock - bench.shown >= READOUT_EVERY or bench.clock < bench.shown then
    bench.shown = bench.clock
    local lap = ""
    if bench.car then
      local now = bench.lapStart and bench.time - bench.lapStart
      lap = ("\nspeed %d%s%s"):format(floor(bench.car.speed), now and ("   lap %.1f s"):format(now) or "   cross the line to start a lap",
        bench.best and ("   best %.2f s"):format(bench.best) or "")
    end
    readout:SetText(("%s\n%s: frame %.1f ms (%.0f fps), Lua %.2f ms, %d karts in view%s"):format(describe(bench),
      bench.phase, ms, 1 / math.max(elapsed, 0.0001), spent, seen, lap))
  end
end)

-- Driving: the controls are kept from the game while the bench has them, everything else isn't
local CONTROLS = { UP = "up", W = "up", DOWN = "down", S = "down", LEFT = "left", A = "left", RIGHT = "right", D = "right" }
ns.CONTROLS = CONTROLS

frame:SetScript("OnKeyDown", function(self, key)
  local bench = run
  if key == "ESCAPE" and bench then
    pcall(self.SetPropagateKeyboardInput, self, false)
    stop("Stopped")
    return
  end
  local mode = bench and ns.modes[bench.kind]
  if mode and mode.key and mode.key(bench, key) then
    pcall(self.SetPropagateKeyboardInput, self, false)
    return
  end
  local control = bench and (bench.kind == "drive" or bench.drives) and CONTROLS[key]
  if control then
    bench.keys[control] = true
  end
  pcall(self.SetPropagateKeyboardInput, self, not control)
end)

frame:SetScript("OnKeyUp", function(_, key)
  local control = CONTROLS[key]
  if control and run then
    run.keys[control] = nil
  end
end)

frame:SetScript("OnHide", function()
  if run then
    stop("Stopped")
  end
end)

frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, _, name)
  if name == "KartBench" then
    KartBenchDB = KartBenchDB or {}
    KartBenchDB.results = KartBenchDB.results or {}
    frame:UnregisterEvent("ADDON_LOADED")
  end
end)

local function usage()
  say("/kartbench sweep | plane [options] | drive [options] | sizes | baseline | stop")
  for name, command in pairs(ns.commands) do
    say(("/kartbench %s %s"):format(name, command.usage))
  end
  say("options: rows <n>, size <1024|2048|4096>, nearest, flat, karts <n>, models <n>, display <id>, mounts, strips, ghost, lag <n>, grass own|client")
end

--- The options in what was typed after the command, nil if something in it wasn't one
local function parse(words, from)
  local options, index = {}, from
  while words[index] do
    local word, value = words[index], tonumber(words[index + 1])
    if (word == "rows" or word == "karts" or word == "models" or word == "display" or word == "lag" or word == "bands") and value then
      options[word], index = floor(value), index + 2
    elseif word == "size" and (value == 1024 or value == 2048 or value == 4096) then
      options.size, index = value, index + 2
    elseif word == "nearest" or word == "flat" or word == "ghost" or word == "endless" or word == "mounts" or word == "strips" then
      options[word], index = true, index + 1
    elseif (word == "grass" or word == "ground") and (words[index + 1] == "own" or words[index + 1] == "client") then
      options[word], index = words[index + 1], index + 2
    elseif word == "course" and words[index + 1] then
      options.course, index = words[index + 1], index + 2
    else
      return nil
    end
  end
  return options
end
ns.parse = parse

SLASH_KARTBENCH1 = "/kartbench"
SlashCmdList.KARTBENCH = function(text)
  local words = {}
  for word in text:gmatch("%S+") do
    words[#words + 1] = word:lower()
  end
  local command = words[1]
  local options = parse(words, 2)
  if command == "sweep" then
    say(("Sweeping %d measurements, about %d seconds. Escape stops it"):format(#SWEEP, #SWEEP * (WARMUP + MEASURE)))
    queue, found = {}, {}
    for index = 2, #SWEEP do
      queue[#queue + 1] = SWEEP[index]
    end
    start(SWEEP[1])
  elseif (command == "plane" or command == "drive") and options then
    queue, found = nil, nil
    options.kind = command
    start(options)
    if command == "drive" then
      say("Arrows or WASD to drive, Escape to stop. Laps are timed from the chequered line")
    end
  elseif command == "sizes" or command == "baseline" then
    queue, found = nil, nil
    start({ kind = command })
  elseif command == "stop" then
    stop("Stopped")
  elseif ns.commands[command] and ns.commands[command].run(words) then
    queue, found = nil, nil
  else
    usage()
  end
end
