--------------------------
--  Geo Bench: capture
--------------------------
-- A panorama from where you stand: a ring of screenshots, the camera turned the same step
-- between each, for stitch.py to put together. The client's interface is hidden for them (as
-- Alt+Z hides it, names over heads too), the camera brought in to first person so your own
-- character isn't in them, its smoothing turned off so it stays where it is turned, and the
-- field of view opened as wide as the client lets it, for more of the sky and the ground. All of
-- it is put back afterwards.
--
-- Before the screenshots you are shown a line across the middle of the screen: look level, so
-- that the far horizon lies along it, and press Enter. Escape gives up. Stand still: the
-- screenshots are taken a second apart, the client names them by the second they were taken in.
--
--   /geobench capture [shots <n>] [fov max|keep|<degrees>] [format tga|jpeg|png] [third] [now]
--
-- shots: how many round the ring, 12 if not said (a step of 30 degrees). format: the screenshots'
-- (the client's own setting is put back after), JPEG if not said: at the client's best quality
-- it is about 1.5 MB a screenshot where TGA is 11, and nothing of the difference survives the
-- stitching and the BLP the panorama ends up as. third: the camera left where it is rather than
-- in first person. now: no waiting for Enter.
--
-- What is kept for each, in GeoBenchDB.captures (it is written out on /reload or logging out):
-- where you were every way the client says (ns.where), the step, the field of view, the
-- screenshots' names by the time they were taken, and the same as one line for stitch.py.

local _, ns = ...
local say = ns.say

-- Seconds to let the client draw the turned view before the screenshot, and to give up waiting
-- for one
local SETTLE, TIMEOUT = 0.45, 4

-- Names over heads aren't the interface's: hiding it leaves them (an NPC's name was in the first
-- panorama), and so are the bubbles of what is said nearby (one was over Stormwind's canals), so
-- each is turned off for the screenshots and back after
local NAMES = { "UnitNameOwn", "UnitNameNPC", "UnitNameNonCombatCreatureName", "UnitNameFriendlyPlayerName",
  "UnitNameFriendlyPetName", "UnitNameFriendlyGuardianName", "UnitNameFriendlyTotemName", "UnitNameFriendlyMinionName",
  "UnitNameFriendlySpecialNPCName", "UnitNameEnemyPlayerName", "UnitNameEnemyPetName", "UnitNameEnemyGuardianName",
  "UnitNameEnemyTotemName", "UnitNameEnemyMinionName", "UnitNameHostleNPC", "UnitNameInteractiveNPC",
  "UnitNamePlayerGuild", "nameplateShowAll", "nameplateShowEnemies", "nameplateShowFriends", "nameplateShowFriendlyNpcs",
  "nameplateShowSelf", "chatBubbles", "chatBubblesParty" }

local driver = CreateFrame("Frame")
-- The guide is the interface's, hidden with it while the screenshots are taken
local guide = CreateFrame("Frame", nil, UIParent)
guide:SetAllPoints()
guide:SetFrameStrata("FULLSCREEN_DIALOG")
guide:Hide()
local line = guide:CreateTexture(nil, "OVERLAY")
line:SetColorTexture(1, 0.85, 0.2, 0.8)
line:SetPoint("LEFT", 0, 0)
line:SetPoint("RIGHT", 0, 0)
line:SetHeight(2)
local upright = guide:CreateTexture(nil, "OVERLAY")
upright:SetColorTexture(1, 0.85, 0.2, 0.8)
upright:SetSize(2, 40)
upright:SetPoint("CENTER")
local words = guide:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
words:SetPoint("TOP", 0, -120)
local wordsShade = guide:CreateTexture(nil, "ARTWORK")
wordsShade:SetPoint("TOPLEFT", words, -10, 8)
wordsShade:SetPoint("BOTTOMRIGHT", words, 10, -8)
wordsShade:SetColorTexture(0, 0, 0, 0.6)

local run

local function put(name, value)
  if value ~= nil then
    ns.setCVar(name, value)
  end
end

local function restore()
  local was = run.was
  pcall(SetUIVisibility, true)
  put("cameraFov", was.fov)
  put("cameraSmoothStyle", was.smooth)
  put("screenshotFormat", was.format)
  put("screenshotQuality", was.quality)
  for name, value in pairs(was.names) do
    put(name, value)
  end
  if was.zoom and was.zoom > 0.5 then
    pcall(CameraZoomOut, was.zoom)
  end
end

local function stop(why)
  if not run then
    return
  end
  guide:Hide()
  pcall(guide.EnableKeyboard, guide, false)
  driver:Hide()
  restore()
  run = nil
  if why then
    say(why)
  end
end

local function field(value)
  if type(value) == "number" then
    return value == math.floor(value) and tostring(value) or ("%.6f"):format(value)
  end
  return tostring(value or ""):gsub("[|;=]", " ")
end

local function keep()
  local here, shots = run.here, run.shots
  local names, called = {}, {}
  for index, shot in ipairs(shots) do
    names[index], called[index] = shot.done or shot.called, shot.called
  end
  local capture = { id = #GeoBenchDB.captures + 1, where = here, step = run.step, fov = run.fov,
    format = run.format, shots = shots, client = ns.environment(), facingAfter = select(2, ns.call(GetPlayerFacing)),
    third = run.third }
  local width, height = GetPhysicalScreenSize()
  local fields = {
    { "id", capture.id }, { "shots", #shots }, { "step", run.step }, { "fov", run.fov }, { "format", run.format },
    { "width", width }, { "height", height }, { "mapID", here.mapID }, { "mapName", here.mapName }, { "x", here.x },
    { "y", here.y }, { "continent", here.continent }, { "worldX", here.worldX }, { "worldY", here.worldY },
    { "instance", here.instance }, { "facing", here.facing }, { "zone", here.zone }, { "subzone", here.subzone },
    { "names", table.concat(names, ",") }, { "called", table.concat(called, ",") }, { "third", run.third and 1 or 0 },
  }
  local parts = {}
  for index, pair in ipairs(fields) do
    parts[index] = pair[1] .. "=" .. field(pair[2])
  end
  capture.line = table.concat(parts, "|")
  table.insert(GeoBenchDB.captures, capture)
  return capture
end

local function shoot()
  run.phase, run.clock = "settle", 0
  guide:Hide()
  pcall(guide.EnableKeyboard, guide, false)
  pcall(SetUIVisibility, false)
  for _, name in ipairs(NAMES) do
    local value = ns.cvar(name)
    if value ~= nil and run.was.names[name] == nil then
      run.was.names[name] = value
      ns.setCVar(name, 0)
    end
  end
  driver:Show()
end

-- Enter takes the screenshots, Escape gives up, everything else goes on to the game
guide:SetScript("OnKeyDown", function(self, key)
  if key == "ENTER" then
    pcall(self.SetPropagateKeyboardInput, self, false)
    shoot()
  elseif key == "ESCAPE" then
    pcall(self.SetPropagateKeyboardInput, self, false)
    stop("Capture given up")
  else
    pcall(self.SetPropagateKeyboardInput, self, true)
  end
end)

driver:Hide()
driver:RegisterEvent("SCREENSHOT_SUCCEEDED")
driver:RegisterEvent("SCREENSHOT_FAILED")
driver:SetScript("OnEvent", function(_, event)
  if run and run.phase == "waiting" then
    local shot = run.shots[#run.shots]
    shot.done = date("%m%d%y_%H%M%S")
    shot.failed = event == "SCREENSHOT_FAILED" or nil
    run.phase = "turn"
  end
end)

driver:SetScript("OnUpdate", function(_, elapsed)
  if not run then
    driver:Hide()
    return
  end
  run.clock = run.clock + elapsed
  if InCombatLockdown() then
    stop("|cffff4040Capture given up: you are in combat|r")
    return
  end
  if run.phase == "settle" then
    -- A second of its own for each, as the screenshots are named by the second
    if run.clock >= SETTLE and time() ~= run.lastSecond then
      run.lastSecond = time()
      run.shots[#run.shots + 1] = { called = date("%m%d%y_%H%M%S"), at = GetTime() }
      run.phase, run.clock = "waiting", 0
      Screenshot()
    end
  elseif run.phase == "waiting" then
    if run.clock >= TIMEOUT then
      run.shots[#run.shots].timedOut = true
      run.phase = "turn"
    end
  elseif run.phase == "turn" then
    FlipCameraYaw(run.step)
    if #run.shots >= run.count then
      local capture = keep()
      local failed = 0
      for _, shot in ipairs(capture.shots) do
        if shot.failed or shot.timedOut then
          failed = failed + 1
        end
      end
      local _, facing = ns.call(GetPlayerFacing)
      stop()
      say(("Captured #%d, %s%s: %d screenshots%s, %s degrees apart at field of view %s"):format(capture.id,
        capture.where.zone or "?", capture.where.subzone ~= "" and (" / " .. capture.where.subzone) or "",
        #capture.shots, failed > 0 and (" (|cffff4040%d failed|r)"):format(failed) or "", tostring(run and run.step or capture.step),
        tostring(capture.fov)))
      if facing and capture.where.facing and math.abs(facing - capture.where.facing) > 0.01 then
        say(("Your character turned with the camera (facing %.3f, was %.3f): that's fine, it came back round"):format(facing,
          capture.where.facing))
      end
      say("/reload (or log out) to write it out, then Tools/GeoBench/python.sh stitch.py")
    else
      run.phase, run.clock = "settle", 0
    end
  end
end)

local function start(options)
  if run then
    say("Already capturing: /geobench stop gives up")
    return
  end
  if InCombatLockdown() then
    say("|cffff4040Not in combat|r")
    return
  end
  if type(Screenshot) ~= "function" or type(FlipCameraYaw) ~= "function" then
    say("|cffff4040This client has no Screenshot or FlipCameraYaw for addons|r")
    return
  end
  ns.finish()
  local count = options.shots or 12
  run = { count = count, step = 360 / count, shots = {}, here = ns.where(), third = options.third, phase = "aim", clock = 0,
    was = { fov = ns.cvar("cameraFov"), smooth = ns.cvar("cameraSmoothStyle"), format = ns.cvar("screenshotFormat"),
      quality = ns.cvar("screenshotQuality"), names = {} } }
  local fov = options.fov or "max"
  if fov == "max" then
    local ok, _, _, most = ns.call(GetCameraFOVDefaults)
    fov = ok and most or nil
  elseif fov == "keep" then
    fov = nil
  end
  if fov then
    ns.setCVar("cameraFov", fov)
  end
  run.fov = tonumber(ns.cvar("cameraFov"))
  ns.setCVar("cameraSmoothStyle", 0)
  ns.setCVar("screenshotQuality", 10)
  run.format = ns.setCVar("screenshotFormat", options.format or "jpeg")
  if not options.third then
    local _, zoom = ns.call(GetCameraZoom)
    run.was.zoom = zoom
    pcall(CameraZoomIn, 50)
  end
  if options.now then
    shoot()
    return
  end
  words:SetText(("Look level: the far horizon along the line, the camera where you want the ring to start.\n%d screenshots, %s degrees apart, field of view %s. Stand still.\nEnter to take them, Escape to give up"):format(
    count, tostring(run.step), tostring(run.fov)))
  guide:Show()
  pcall(guide.EnableKeyboard, guide, true)
end

local function list()
  local captures = GeoBenchDB.captures
  if #captures == 0 then
    say("No captures yet: /geobench capture")
    return
  end
  for _, capture in ipairs(captures) do
    local here = capture.where
    say(("#%d %s / %s, map %s at %.3f, %.3f: %d shots at fov %s, %s"):format(capture.id, here.zone or "?", here.subzone or "",
      tostring(here.mapID), here.x or -1, here.y or -1, #capture.shots, tostring(capture.fov), here.when or "?"))
  end
end

ns.commands.capture = {
  usage = "[shots <n>] [fov max|keep|<degrees>] [format tga|jpeg|png] [third] [now]",
  run = function(words)
    local options, index = {}, 2
    while words[index] do
      local word, value = words[index]:lower(), words[index + 1]
      if word == "shots" and tonumber(value) and tonumber(value) >= 4 and tonumber(value) <= 72 then
        options.shots, index = math.floor(tonumber(value)), index + 2
      elseif word == "fov" and value and (value == "max" or value == "keep" or tonumber(value)) then
        options.fov, index = tonumber(value) or value, index + 2
      elseif word == "format" and value then
        options.format, index = value:lower(), index + 2
      elseif word == "third" or word == "now" then
        options[word], index = true, index + 1
      else
        return false
      end
    end
    start(options)
    return true
  end,
  cancel = function()
    stop("Capture given up")
  end,
}
ns.commands.captures = { run = function()
  list()
  return true
end }
