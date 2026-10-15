--------------------------
--  Doom Bench
--------------------------
-- How much drawing the client can take in a frame, to tell whether Doom could be shown in it. Not
-- part of Forever Games: a separate addon, installed with its own install.sh, which borrows
-- Warcraftstein's pictures from Forever Games to draw with.
--
-- Two ways of showing a frame of Doom are measured. "pixels" is the screen as a grid of
-- one-colour textures, every one recoloured (SetColorTexture) every frame, as if Doom's own
-- renderer drew the frame and every pixel of it were then copied out. That is the worst case,
-- the player turning; with a fraction only that much of the screen is recoloured a frame.
--
-- "hybrid" is Doom's draw calls shown as pictures the client stretches, the way Warcraftstein
-- shows its walls and floor. Half the textures are columns of wall, one of Doom's 320 pixels
-- wide and stacked several to a column when there are more than 320 of them, as Doom's upper,
-- lower and middle walls are: every frame each moves up or down, changes height, strip of its
-- picture (SetTexCoord) and light (SetVertexColor), and now and then picture. The other half
-- are spans of floor, one of Doom's 200 rows tall and several to a row, as Doom's visplanes
-- are: every frame each moves along its row, changes width, and is mapped onto the tiled floor
-- with all eight texture coordinates and lit. With "still" they are mapped and lit but not
-- moved, which tells what moving them costs.
--
-- Every measurement draws for a while first, then records each frame: how long its own Lua took
-- (debugprofilestop) and how long the whole frame took, the time from one OnUpdate to the next,
-- which is where the client's own layout and drawing show. "baseline" measures the frame with
-- nothing drawn in it, to tell those apart from everything else the client does. Results are
-- printed, and kept in DoomBenchDB, which the client writes on /reload or logout.
--
--   /doombench sweep                 everything, one after the other
--   /doombench pixels <w> <h> [part] a grid w by h, recolouring part of it (0 to 1) a frame
--   /doombench hybrid <n> [still]    n columns and spans
--   /doombench baseline              nothing at all
--   /doombench stop                  or Escape

local PICTURES = "Interface\\AddOns\\ForeverGames\\Images\\Warcraftstein\\"
local WALLS = { PICTURES .. "nave", PICTURES .. "window", PICTURES .. "library", PICTURES .. "crypt" }
local FLOOR = PICTURES .. "floor"
local WALL_TEXELS = 128
-- Doom's screen, in its pixels, and how large it is shown at most
local DOOM_WIDTH, DOOM_HEIGHT = 320, 200
local WIDTH, HEIGHT = 960, 600
-- Seconds to draw before measuring, and to measure for
local WARMUP, MEASURE = 1.5, 4
-- How many textures are made or placed a frame while getting ready, so that no frame takes long
local READY_A_FRAME = 4000
-- How long a frame may take for Doom's 35 tics a second, in milliseconds, and how long one
-- takes for a sweep to try nothing bigger of the same
local BUDGET, HOPELESS = 1000 / 35, 250
-- How often the numbers on the screen are brought up to date, in seconds
local READOUT_EVERY = 0.25
local SWEEP = {
  { "baseline" },
  { "pixels", 80, 50 },
  { "pixels", 160, 100 },
  { "pixels", 240, 150 },
  { "pixels", 320, 200 },
  { "pixels", 320, 200, 0.25 },
  { "hybrid", 500 },
  { "hybrid", 1000 },
  { "hybrid", 2000 },
  { "hybrid", 4000 },
  { "hybrid", 8000 },
  { "hybrid", 16000 },
  { "hybrid", 2000, "still" },
  { "hybrid", 8000, "still" },
}

local floor = math.floor

-- Numbers between 0 and 1, read in a different order every frame, standing in for whatever a
-- renderer would have worked out. Reading them costs about what reading a framebuffer would
local NOISE_SIZE = 4096
local NOISE = {}
for index = 1, NOISE_SIZE do
  NOISE[index] = math.random()
end
-- And 256 colours, as Doom has
local RED, GREEN, BLUE = {}, {}, {}
for index = 1, 256 do
  RED[index], GREEN[index], BLUE[index] = math.random(), math.random(), math.random()
end

local frame = CreateFrame("Frame", "DoomBenchFrame", UIParent)
frame:SetFrameStrata("DIALOG")
frame:SetPoint("CENTER")
frame:SetClipsChildren(true)
frame:Hide()
tinsert(UISpecialFrames, "DoomBenchFrame")
local black = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
black:SetAllPoints()
black:SetColorTexture(0, 0, 0, 1)
local cover = CreateFrame("Frame", nil, frame)
cover:SetAllPoints()
cover:SetFrameLevel(frame:GetFrameLevel() + 10)
local readout = cover:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
readout:SetPoint("TOPLEFT", 10, -10)
readout:SetJustifyH("LEFT")
local shade = cover:CreateTexture(nil, "BORDER")
shade:SetPoint("TOPLEFT", readout, -6, 6)
shade:SetPoint("BOTTOMRIGHT", readout, 6, -6)
shade:SetColorTexture(0, 0, 0, 0.75)

-- The textures of each kind, kept from one measurement to the next
local pixels, quads = {}, {}

--- @class BenchRun
--- @field kind string "pixels", "hybrid" or "baseline"
--- @field count integer How many textures
--- @field columns integer Of a hybrid's, how many are columns of wall: the rest are spans of floor
--- @field across integer? A grid's pixels across
--- @field down integer? And down
--- @field step integer Every this many of a grid's pixels is recoloured a frame
--- @field still boolean A hybrid's textures stay where they are
--- @field scaleX number How wide one of the run's pixels is on the screen
--- @field scaleY number And how tall
--- @field phase string "ready", "warm" or "measure"
--- @field ready integer How many textures are made and placed
--- @field clock number Seconds into the phase
--- @field tick integer Frames drawn
--- @field frames number[] Milliseconds every measured frame took
--- @field lua number[] Of which in drawing it, in Lua
--- @field shown number When the readout was last brought up to date

--- @type BenchRun?
local run
-- What a sweep has still to do, and what it found
local queue, found

local function say(text)
  print("|cffff4040Doom Bench|r " .. text)
end

local function cvar(name)
  local ok, value = pcall(C_CVar and C_CVar.GetCVar or GetCVar, name)
  return ok and value or "?"
end

--- What the client is and how its frame rate is held back, kept with every result
local function environment()
  local version, build = GetBuildInfo()
  local width, height = GetPhysicalScreenSize()
  return ("%s.%s, screen %dx%d, vsync %s, maxFPS %s (on: %s)"):format(version, build, width, height,
    cvar("vsync"), cvar("maxFPS"), cvar("useMaxFPS"))
end

local function describe(bench)
  if bench.kind == "pixels" then
    local part = bench.step > 1 and (", 1 in %d a frame"):format(bench.step) or ""
    return ("pixels %dx%d (%d textures%s)"):format(bench.across, bench.down, bench.count, part)
  elseif bench.kind == "hybrid" then
    return ("hybrid %d %s"):format(bench.count, bench.still and "still" or "moving")
  end
  return "baseline (nothing drawn)"
end

--- Where a column of wall is and what of which picture it shows, given three numbers between 0
--- and 1. It moves only when asked to
local function column(texture, index, a, b, c, scaleX, scaleY, move)
  if move then
    local top = floor(a * DOOM_HEIGHT)
    texture:SetPoint("TOPLEFT", frame, "TOPLEFT", ((index - 1) % DOOM_WIDTH) * scaleX, -top * scaleY)
    texture:SetHeight((1 + floor(b * (DOOM_HEIGHT - 1 - top))) * scaleY)
    if c < 0.05 then
      texture:SetTexture(WALLS[floor(c * 80) + 1], "REPEAT", "REPEAT")
    end
  end
  local strip = floor(c * WALL_TEXELS)
  texture:SetTexCoord((strip + 0.2) / WALL_TEXELS, (strip + 0.8) / WALL_TEXELS, a, a + b * 2)
  local light = 0.3 + b * 0.7
  texture:SetVertexColor(light, light, light)
end

--- And a span of floor: the stretch of the map it shows, from its left end to its right
local function span(texture, row, a, b, c, scaleX, scaleY, move)
  if move then
    local left = floor(a * DOOM_WIDTH)
    texture:SetPoint("TOPLEFT", frame, "TOPLEFT", left * scaleX, -((row - 1) % DOOM_HEIGHT) * scaleY)
    texture:SetWidth((1 + floor(b * (DOOM_WIDTH - 1 - left))) * scaleX)
  end
  local x, y, long = c * 64, a * 64, 1 + b * 6
  texture:SetTexCoord(x, y, x, y + 0.02, x + long, y + c, x + long, y + c + 0.02)
  local light = 0.2 + c * 0.8
  texture:SetVertexColor(light, light, light)
end

--- The three numbers a texture is drawn with this frame
local function noise(index, tick)
  local at = (index * 7 + tick * 13) % NOISE_SIZE + 1
  return NOISE[at], NOISE[at % NOISE_SIZE + 1], NOISE[(at + 1) % NOISE_SIZE + 1]
end

--- Makes and places some more of a run's textures
--- @return boolean ready All of them are
local function prepare(bench)
  if bench.kind == "baseline" then
    return true
  end
  local last = math.min(bench.count, bench.ready + READY_A_FRAME)
  for index = bench.ready + 1, last do
    if bench.kind == "pixels" then
      local texture = pixels[index] or frame:CreateTexture(nil, "ARTWORK")
      pixels[index] = texture
      local across, down = (index - 1) % bench.across, floor((index - 1) / bench.across)
      texture:SetSize(bench.scaleX, bench.scaleY)
      texture:SetPoint("TOPLEFT", frame, "TOPLEFT", across * bench.scaleX, -down * bench.scaleY)
      texture:SetColorTexture(0, 0, 0)
      texture:Show()
    else
      local texture = quads[index] or frame:CreateTexture(nil, "ARTWORK")
      quads[index] = texture
      local a, b, c = noise(index, 0)
      if index <= bench.columns then
        texture:SetDrawLayer("ARTWORK")
        texture:SetTexture(WALLS[index % #WALLS + 1], "REPEAT", "REPEAT")
        texture:SetWidth(bench.scaleX)
        column(texture, index, a, b, c, bench.scaleX, bench.scaleY, true)
      else
        texture:SetDrawLayer("BACKGROUND")
        texture:SetTexture(FLOOR, "REPEAT", "REPEAT")
        texture:SetHeight(bench.scaleY)
        span(texture, index - bench.columns, a, b, c, bench.scaleX, bench.scaleY, true)
      end
      texture:Show()
    end
  end
  bench.ready = last
  return last == bench.count
end

--- One frame of a run
local function draw(bench)
  local tick = bench.tick
  if bench.kind == "pixels" then
    local shift, step = tick * 37, bench.step
    for index = 1 + tick % step, bench.count, step do
      local colour = (index * 7 + shift) % 256 + 1
      pixels[index]:SetColorTexture(RED[colour], GREEN[colour], BLUE[colour])
    end
  elseif bench.kind == "hybrid" then
    local scaleX, scaleY, move, columns = bench.scaleX, bench.scaleY, not bench.still, bench.columns
    for index = 1, columns do
      local a, b, c = noise(index, tick)
      column(quads[index], index, a, b, c, scaleX, scaleY, move)
    end
    for index = columns + 1, bench.count do
      local a, b, c = noise(index, tick)
      span(quads[index], index - columns, a, b, c, scaleX, scaleY, move)
    end
  end
  bench.tick = tick + 1
end

local function hideAll(bench)
  local pool = bench.kind == "pixels" and pixels or quads
  for index = 1, bench.ready do
    pool[index]:Hide()
  end
end

local function median(sorted, at)
  return sorted[math.max(1, math.ceil(#sorted * at))] or 0
end

--- The numbers of a run that is over
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
    count = bench.count,
    still = bench.still,
    frameMs = frameMs,
    frame95Ms = median(bench.frames, 0.95),
    luaMs = lua / math.max(1, #bench.lua),
    fps = frameMs > 0 and 1000 / frameMs or 0,
    frames = #bench.frames,
  }
end

local function report(outcome)
  say(("%s: frame %.1f ms (%.0f fps), slowest 5%% %.1f ms, Lua %.1f ms"):format(outcome.name, outcome.frameMs,
    outcome.fps, outcome.frame95Ms, outcome.luaMs))
end

--- What a sweep comes to: the most of each kind that would keep up with Doom
local function conclude(results)
  local best = {}
  for _, outcome in ipairs(results) do
    local key = outcome.kind .. (outcome.still and " still" or "")
    if outcome.kind ~= "baseline" and outcome.frameMs <= BUDGET then
      if not best[key] or outcome.count > best[key].count then
        best[key] = outcome
      end
    end
  end
  say(("Keeps up with Doom's 35 a second (%.1f ms a frame or less):"):format(BUDGET))
  for _, key in ipairs({ "pixels", "hybrid", "hybrid still" }) do
    say(("  %s: %s"):format(key, best[key] and best[key].name or "none of those tried"))
  end
  if results[1] and results[1].kind == "baseline" and results[1].frameMs > 12 then
    say(("The frame takes %.1f ms with nothing in it: if the frame rate is held back (vsync, maxFPS), every number above is at least that"):format(results[1].frameMs))
  end
  say("/reload to keep these in DoomBenchDB")
end

local start

local function finish()
  local bench = run
  if not bench then
    return
  end
  run = nil
  hideAll(bench)
  local outcome = result(bench)
  outcome.when = date("%Y-%m-%d %H:%M:%S")
  outcome.client = environment()
  table.insert(DoomBenchDB.results, outcome)
  report(outcome)
  if found then
    table.insert(found, outcome)
    -- Nothing bigger of the same is worth waiting for. A grid as big recoloured less is
    local function bigger(step)
      local size = step[1] == "pixels" and step[2] * step[3] or step[2]
      return step[1] == outcome.kind and (step[3] == "still") == (outcome.still == true) and size > outcome.count
    end
    if outcome.frameMs > HOPELESS then
      while queue[1] and bigger(queue[1]) do
        say(("Skipped %s %s, as %s was already too slow"):format(queue[1][1], queue[1][2], outcome.name))
        table.remove(queue, 1)
      end
    end
    local following = table.remove(queue, 1)
    if following then
      start(unpack(following))
      return
    end
    conclude(found)
    queue, found = nil, nil
  end
  frame:Hide()
end

local function stop(why)
  if run then
    hideAll(run)
    run = nil
    say(why)
  end
  queue, found = nil, nil
  frame:Hide()
end

--- Begins a measurement, with the words it was asked for in
function start(kind, first, second, third)
  if run then
    hideAll(run)
    run = nil
  end
  local scale = math.min(1, UIParent:GetWidth() * 0.9 / WIDTH, UIParent:GetHeight() * 0.85 / HEIGHT)
  frame:SetSize(WIDTH * scale, HEIGHT * scale)
  local bench = { kind = kind, count = 0, columns = 0, step = 1, still = false, phase = "ready", ready = 0,
    clock = 0, tick = 0, frames = {}, lua = {}, shown = 0, scaleX = 1, scaleY = 1 }
  if kind == "pixels" then
    bench.across, bench.down = first, second
    bench.count = first * second
    bench.step = math.max(1, floor(1 / (third or 1) + 0.5))
    bench.scaleX, bench.scaleY = WIDTH * scale / first, HEIGHT * scale / second
  elseif kind == "hybrid" then
    bench.count = first
    bench.columns = floor(first / 2)
    bench.still = second == "still"
    bench.scaleX, bench.scaleY = WIDTH * scale / DOOM_WIDTH, HEIGHT * scale / DOOM_HEIGHT
  end
  run = bench
  readout:SetText(describe(bench) .. "\ngetting ready")
  frame:Show()
end

frame:SetScript("OnUpdate", function(_, elapsed)
  local bench = run
  if not bench then
    return
  end
  if bench.phase == "ready" then
    if prepare(bench) then
      bench.phase, bench.clock = "warm", 0
    end
    return
  end
  if bench.phase == "measure" then
    table.insert(bench.frames, elapsed * 1000)
  end
  local began = debugprofilestop()
  draw(bench)
  local spent = debugprofilestop() - began
  bench.clock = bench.clock + elapsed
  if bench.phase == "measure" then
    table.insert(bench.lua, spent)
    if bench.clock >= MEASURE then
      finish()
      return
    end
  elseif bench.clock >= WARMUP then
    bench.phase, bench.clock = "measure", 0
  end
  if bench.clock - bench.shown >= READOUT_EVERY or bench.clock < bench.shown then
    bench.shown = bench.clock
    readout:SetText(("%s\n%s: frame %.1f ms (%.0f fps), Lua %.1f ms"):format(describe(bench), bench.phase,
      elapsed * 1000, 1 / math.max(elapsed, 0.0001), spent))
  end
end)

frame:SetScript("OnHide", function()
  if run then
    stop("Stopped")
  end
end)

frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, _, name)
  if name == "DoomBench" then
    DoomBenchDB = DoomBenchDB or {}
    DoomBenchDB.results = DoomBenchDB.results or {}
    frame:UnregisterEvent("ADDON_LOADED")
  end
end)

local function usage()
  say("/doombench sweep | pixels <w> <h> [part] | hybrid <n> [still] | baseline | stop")
end

SLASH_DOOMBENCH1 = "/doombench"
SlashCmdList.DOOMBENCH = function(text)
  local words = {}
  for word in text:gmatch("%S+") do
    words[#words + 1] = word:lower()
  end
  local command = words[1]
  if command == "sweep" then
    say(("Sweeping %d measurements, about %d seconds. Escape stops it"):format(#SWEEP, #SWEEP * (WARMUP + MEASURE)))
    queue, found = {}, {}
    for index = 2, #SWEEP do
      queue[#queue + 1] = SWEEP[index]
    end
    start(unpack(SWEEP[1]))
  elseif command == "pixels" and tonumber(words[2]) and tonumber(words[3]) then
    queue, found = nil, nil
    start("pixels", floor(tonumber(words[2])), floor(tonumber(words[3])), tonumber(words[4]))
  elseif command == "hybrid" and tonumber(words[2]) then
    queue, found = nil, nil
    start("hybrid", floor(tonumber(words[2])), words[3])
  elseif command == "baseline" then
    queue, found = nil, nil
    start("baseline")
  elseif command == "stop" then
    stop("Stopped")
  else
    usage()
  end
end
