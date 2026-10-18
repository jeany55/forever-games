--------------------------
--  Pinball Bench
--------------------------
-- Tries out the pinball game of ForeverGames_Pinball on its own, outside Forever Games: a
-- separate addon like Doom Bench and Kart Bench, installed with its own install.sh, which copies
-- the game's table, rules and machine (Machine.lua) in beside this file. Here is only what the
-- bench adds to them: a window of its own as tall as the screen, a machine that keeps its own high
-- scores and has them signed with initials, the settings the table plays with, which can be
-- changed while it is played, the robot that plays it, and measuring what a frame costs.
--
-- Everything the player does goes in at a tick, and is kept: "replay" plays the last game again
-- from those alone, and says whether it came out exactly the same, which it has to on any computer
-- for a game to be played back or checked.
--
-- What makes the table feel the way it does can be changed while it is played ("set"), and is
-- kept between sessions: how hard gravity pulls, how fast the flippers are, how springy the
-- rubbers are. Tab shows what a frame costs, split into the physics and the drawing. What was
-- measured is kept for Tools/PinballBench/report.lua to read after a /reload.
--
--   /pinbench                   the machine, waiting to be played
--   /pinbench play              a game at once
--   /pinbench robot [balls n]   the bench plays itself, with that many balls on the table
--   /pinbench sweep             measures what a frame costs, the robot playing, with more balls and ticks
--   /pinbench set <name> <n>    changes a setting; /pinbench set with nothing lists them
--   /pinbench defaults          puts every setting back
--   /pinbench view              the whole machine, or closer in on the table
--   /pinbench sound             sounds on or off
--   /pinbench walls             shows what the ball meets over the pictures, or stops
--   /pinbench replay            plays the last game again from its moves
--   /pinbench scores            forgets the high scores
--   /pinbench stop              or Escape
--
-- Keys: Enter or R starts a game. Shift, Z and / or the arrows for the flippers (the left ones
-- work both left flippers), Space or Down to pull the plunger back and let go, X and . to nudge
-- left and right and Up to nudge forwards. 1 casts Frost Nova, 2 Shield Wall, 3 lights the
-- kickback, 4 adds a ball, V goes between the whole machine and closer in, Tab shows the
-- measurements.

local _, ns = ...
local Machine = ns.Machine

local floor, max = math.floor, math.max

local DEFAULTS = ns.DEFAULTS
-- What the sweep measures, the robot playing
local SWEEP = {
  { baseline = true },
  { balls = 1 },
  { balls = 3 },
  { balls = 6 },
  { balls = 12 },
  { balls = 3, hz = 500 },
  { balls = 3, hz = 2000 },
  { balls = 3, walls = true },
  { balls = 6, shows = true },
}
local WARMUP, MEASURE = 2, 5
-- The high scores a new machine has, to be beaten
local FIRST_SCORES = {
  { name = "MAL", score = 2500000 },
  { name = "TYR", score = 1500000 },
  { name = "CEN", score = 1000000 },
  { name = "REM", score = 500000 },
}
-- The keys the bench adds to the machine's
local KEYS = { R = "start", ["3"] = "kickback", ["4"] = "ball", TAB = "readout", ESCAPE = "stop" }

local function say(text)
  print("|cffff9a3cPinball Bench|r " .. text)
end

-----------------------------
-- The frame
-----------------------------
local frame = CreateFrame("Frame", "PinballBenchFrame", UIParent)
frame:SetFrameStrata("DIALOG")
frame:SetPoint("CENTER")
frame:Hide()
local back = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
back:SetAllPoints()
back:SetColorTexture(0.02, 0.02, 0.03, 0.97)
tinsert(UISpecialFrames, "PinballBenchFrame")
local readout
local walls = false

-----------------------------
-- Settings
-----------------------------
local tune = {}

local function loadSettings()
  PinballBenchDB = PinballBenchDB or {}
  PinballBenchDB.tune = PinballBenchDB.tune or {}
  -- What was measured, read by Tools/PinballBench/report.lua: every sweep, and every game played
  PinballBenchDB.sweeps = PinballBenchDB.sweeps or {}
  PinballBenchDB.games = PinballBenchDB.games or {}
  PinballBenchDB.results = nil
  if not PinballBenchDB.highScores then
    PinballBenchDB.highScores = {}
    for index, entry in ipairs(FIRST_SCORES) do
      PinballBenchDB.highScores[index] = { name = entry.name, score = entry.score }
    end
  end
  -- The same table the machine has, filled again
  for key in pairs(tune) do
    tune[key] = nil
  end
  for key, value in pairs(DEFAULTS) do
    tune[key] = value
  end
  for name, material in pairs(ns.Table.materials) do
    tune[name .. ".bounce"], tune[name .. ".friction"] = material.bounce, material.friction
  end
  for key, value in pairs(PinballBenchDB.tune) do
    if tune[key] ~= nil then
      tune[key] = value
    end
  end
end

local lastGame

--- The machine, made the first time it is shown
local function machine()
  if not Machine.panel then
    Machine.New(frame, {
      tune = tune,
      L = ns.L,
      soundOn = function()
        return PinballBenchDB.sound
      end,
      highScores = function()
        return PinballBenchDB.highScores
      end,
      canStart = true,
      dotImages = "Interface\\AddOns\\PinballBench\\Images\\DotMatrix\\",
      onView = function(mode)
        PinballBenchDB.view = mode
      end,
    })
    Machine.Help(ns.L.pinball_keys .. "\n3 kickback   4 another ball\nTab measurements   Esc close")
    readout = Machine.panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    readout:SetPoint("BOTTOMLEFT", Machine.helpText, "TOPLEFT", 0, 14)
    readout:SetWidth(Machine.PANEL - 30)
    readout:SetJustifyH("LEFT")
    Machine.SetView(PinballBenchDB.view or "cabinet")
  end
  return Machine
end

--- Sizes the window to the machine, as tall as the screen has room for
local function fit()
  local height = floor(UIParent:GetHeight() * 0.94)
  local width = Machine.Layout(nil, height)
  frame:SetSize(width, height)
end

-----------------------------
-- Measuring
-----------------------------
local function average(list)
  local total = 0
  for _, value in ipairs(list) do
    total = total + value
  end
  return #list > 0 and total / #list or 0
end

local function median(list, at)
  local sorted = {}
  for i, value in ipairs(list) do
    sorted[i] = value
  end
  table.sort(sorted)
  return sorted[max(1, math.ceil(#sorted * at))] or 0
end

local window
local showReadout = false

local function measured(elapsed, physicsMs, drawMs, ticks)
  local world = Machine.Game().world
  window = window or { frames = 0, seconds = 0, physics = 0, draw = 0, ticks = 0, at = 0 }
  local w = window
  w.frames, w.seconds, w.physics, w.draw, w.ticks = w.frames + 1, w.seconds + elapsed, w.physics + physicsMs, w.draw + drawMs, w.ticks + ticks
  w.at = w.at + elapsed
  if w.at < 0.25 then
    return
  end
  if showReadout then
    readout:SetText(("%.0f fps, frame %.1f ms\nphysics %.2f ms, drawing %.2f ms\n%.1f ticks, %.1f steps, %d checks a frame\n%d balls, hz %d, time x%.2f, tick %d")
      :format(w.frames / w.seconds, w.seconds / w.frames * 1000, w.physics / w.frames, w.draw / w.frames, w.ticks / w.frames,
        world.steps / w.frames, world.checks / w.frames, #world.balls, world.hz, world.timeScale, world.tick))
  else
    readout:SetText("")
  end
  world.steps, world.checks = 0, 0
  window = nil
end

local sweep

-- How many sweeps and games are kept, the oldest let go first
local KEEP_SWEEPS, KEEP_GAMES = 10, 30
-- Frames measured in a game at most, ten minutes of them at 60 a second
local MOST_FRAMES = 36000

local function cvar(name)
  local ok, value = pcall(C_CVar and C_CVar.GetCVar or GetCVar, name)
  return ok and value or "?"
end

--- What the measurements were taken on
local function environment()
  local version, build = GetBuildInfo()
  local width, height = GetPhysicalScreenSize()
  return {
    client = version .. "." .. build,
    screen = ("%dx%d"):format(width, height),
    uiScale = UIParent:GetEffectiveScale(),
    vsync = cvar("vsync"),
    maxFPS = cvar("maxFPS"),
    useMaxFPS = cvar("useMaxFPS"),
    view = Machine.view.mode,
    sound = PinballBenchDB.sound and true or false,
  }
end

local function keep(list, entry, most)
  table.insert(list, entry)
  while #list > most do
    table.remove(list, 1)
  end
end

local function settings()
  local copy = {}
  for key, value in pairs(tune) do
    copy[key] = value
  end
  return copy
end

--- Keeps what a game that was played cost and came to, for report.lua
local function logGame(done)
  if not done or done.keep or done.idle or done.logged or #done.frames < 60 then
    return
  end
  done.logged = true
  local slowest = 0
  for _, ms in ipairs(done.frames) do
    slowest = max(slowest, ms)
  end
  local physicsMost = 0
  for _, ms in ipairs(done.physicsMs) do
    physicsMost = max(physicsMost, ms)
  end
  local frameMs = median(done.frames, 0.5)
  keep(PinballBenchDB.games, {
    when = date("%Y-%m-%d %H:%M:%S"),
    seconds = floor(done.world.tick / done.world.hz),
    score = done.score,
    ball = done.ball,
    level = done.level,
    quests = done.questsDone,
    over = done.over,
    replay = done.wasReplay,
    replayedSame = done.replayedSame,
    moves = #done.inputs,
    frames = #done.frames,
    fps = frameMs > 0 and 1000 / frameMs or 0,
    frameMs = frameMs,
    frame95Ms = median(done.frames, 0.95),
    frameMostMs = slowest,
    physicsMs = average(done.physicsMs),
    physicsMostMs = physicsMost,
    drawMs = average(done.drawMs),
    ticks = done.ticks / max(1, #done.frames),
    environment = environment(),
    settings = settings(),
  }, KEEP_GAMES)
end

--- Before a game is started over another: the one that was being played is logged and kept to
--- be replayed
local function leaving()
  local game = Machine.Game()
  logGame(game)
  if game and not game.replaying and not game.keep and not game.idle and #game.inputs > 0 then
    lastGame = game
  end
end

local function start(options)
  if not (ns.Art and ns.Art.tilt) then
    say("There are no pictures of the table: Tools/PinballBench/install.sh makes them")
    return
  end
  machine()
  leaving()
  fit()
  if not Machine.Start(options) then
    return
  end
  fit()
  frame:Show()
  if not InCombatLockdown() then
    frame:EnableKeyboard(true)
  end
end

local function finishSweepRun()
  local run, game = sweep.run, Machine.Game()
  local result = {
    name = run.baseline and "baseline" or ("%d balls, hz %d%s%s"):format(run.balls, run.hz or tune.hz, run.walls and ", walls" or "",
      run.shows and ", lights and display" or ""),
    frameMs = median(game.frames, 0.5),
    frame95Ms = median(game.frames, 0.95),
    physicsMs = average(game.physicsMs),
    drawMs = average(game.drawMs),
    ticks = game.ticks / max(1, #game.frames),
    frames = #game.frames,
  }
  table.insert(sweep.record.results, result)
  table.insert(sweep.found, result)
  say(("%s: frame %.1f ms (%.0f fps), slowest 5%% %.1f ms, physics %.2f ms, drawing %.2f ms, %.1f ticks a frame"):format(result.name,
    result.frameMs, result.frameMs > 0 and 1000 / result.frameMs or 0, result.frame95Ms, result.physicsMs, result.drawMs, result.ticks))
end

local function nextSweepRun()
  local run = table.remove(sweep.queue, 1)
  if not run then
    local base = sweep.found[1] and sweep.found[1].frameMs or 0
    say(("Each against the frame with the table shown and nothing moving (%.1f ms):"):format(base))
    for i = 2, #sweep.found do
      local r = sweep.found[i]
      say(("  +%.1f ms  physics %.2f, drawing %.2f  %s"):format(r.frameMs - base, r.physicsMs, r.drawMs, r.name))
    end
    sweep.record.done = true
    say("/reload to keep these, for Tools/PinballBench/report.lua")
    Machine.MeasureShows(false)
    sweep = nil
    frame:Hide()
    return
  end
  sweep.run, sweep.clock = run, 0
  start({ robot = true, keep = run.baseline and 0 or run.balls, hz = run.hz, baseline = run.baseline })
  Machine.ShowWalls(run.walls)
  Machine.MeasureShows(run.shows)
end

frame:SetScript("OnUpdate", function(_, elapsed)
  local game = Machine.Game()
  if not game then
    return
  end
  -- A sweep measures once it has warmed up, a game played all the time
  local measuring = (sweep and sweep.clock >= WARMUP or not sweep) and #game.frames < MOST_FRAMES
  if sweep then
    sweep.clock = sweep.clock + elapsed
  end
  local physicsMs, drawMs, ticks = Machine.Tick(elapsed)
  if Machine.Game() ~= game then
    -- The machine went back to waiting
    return
  end
  if measuring and not game.idle then
    table.insert(game.frames, elapsed * 1000)
    table.insert(game.physicsMs, physicsMs)
    table.insert(game.drawMs, drawMs)
    game.ticks = game.ticks + ticks
  end
  measured(elapsed, physicsMs, drawMs, ticks)
  if game.replaying and game.world.tick >= game.replaying.endTick then
    game.frozen = true
    local same = game.score == game.replaying.score
    for i, ball in ipairs(game.world.balls) do
      local was = game.replaying.balls[i]
      same = same and was and was.x == ball.x and was.y == ball.y and was.vx == ball.vx and was.vy == ball.vy
    end
    same = same and #game.world.balls == #game.replaying.balls
    game.replayedSame = same
    say(same and "Replayed: the same, exactly" or "|cffff4040Replayed: NOT the same|r")
    Machine.Replayed(same)
    game.replaying = nil
  end
  if sweep and sweep.clock >= WARMUP + MEASURE then
    finishSweepRun()
    nextSweepRun()
  end
end)

frame:EnableKeyboard(false)
frame:SetScript("OnKeyDown", function(self, key)
  if InCombatLockdown() then
    return
  end
  local action = KEYS[key]
  local used = true
  if action == "stop" then
    frame:Hide()
  elseif action == "readout" then
    showReadout = not showReadout
  elseif action == "start" then
    start({})
  elseif action then
    used = Machine.KeyDown(key, action)
  else
    used = Machine.KeyDown(key)
    if not used and Machine.KEYS[key] == "start" then
      start({})
      used = true
    end
  end
  self:SetPropagateKeyboardInput(not used)
end)
frame:SetScript("OnKeyUp", function(_, key)
  Machine.KeyUp(key, KEYS[key])
end)
frame:SetScript("OnHide", function()
  Machine.LetGo()
  leaving()
  if sweep then
    say("Sweep stopped")
    sweep = nil
  end
  pcall(frame.EnableKeyboard, frame, false)
end)

--- Keeps what a game ended as, to compare a replay with
local function remember(done)
  local balls = {}
  for i, ball in ipairs(done.world.balls) do
    balls[i] = { x = ball.x, y = ball.y, vx = ball.vx, vy = ball.vy }
  end
  return { inputs = done.inputs, endTick = done.world.tick, score = done.score, balls = balls, hz = done.hz }
end

SLASH_PINBALLBENCH1 = "/pinbench"
SlashCmdList.PINBALLBENCH = function(text)
  local words = {}
  for word in (text or ""):gmatch("%S+") do
    words[#words + 1] = word
  end
  local command = (words[1] or ""):lower()
  local game = Machine.Game()
  if command == "" then
    start({ idle = true })
  elseif command == "play" then
    start({})
  elseif command == "robot" then
    local balls = tonumber(words[3] or words[2]) or 1
    start({ robot = true, keep = balls })
  elseif command == "sweep" then
    sweep = { queue = {}, found = {} }
    -- Kept from the start, so that a sweep that is stopped still has what it measured
    sweep.record = { when = date("%Y-%m-%d %H:%M:%S"), environment = environment(), settings = settings(), results = {} }
    keep(PinballBenchDB.sweeps, sweep.record, KEEP_SWEEPS)
    for _, run in ipairs(SWEEP) do
      sweep.queue[#sweep.queue + 1] = run
    end
    say("Sweep: the robot plays, " .. (WARMUP + MEASURE) .. " seconds each. Escape stops")
    nextSweepRun()
  elseif command == "set" then
    local name, value = words[2], tonumber(words[3])
    if not name then
      local names = {}
      for key in pairs(tune) do
        names[#names + 1] = key
      end
      table.sort(names)
      for _, key in ipairs(names) do
        say(("%s = %s%s"):format(key, tostring(tune[key]), PinballBenchDB.tune[key] ~= nil and " (changed)" or ""))
      end
      return
    end
    if tune[name] == nil or not value then
      say("No such setting, or not a number: /pinbench set lists them")
      return
    end
    PinballBenchDB.tune[name] = value
    tune[name] = value
    say(("%s = %s. A new game takes it"):format(name, tostring(value)))
    if frame:IsShown() and game and not game.keep and not game.idle then
      start({})
    end
  elseif command == "defaults" then
    PinballBenchDB.tune = {}
    loadSettings()
    say("Every setting is back as it was")
  elseif command == "walls" then
    walls = not walls
    Machine.ShowWalls(walls)
  elseif command == "view" then
    machine()
    local mode = Machine.view.mode == "close" and "cabinet" or "close"
    Machine.SetView(mode)
    PinballBenchDB.view = mode
    say(mode == "close" and "Closer in on the table" or "The whole machine")
    if frame:IsShown() then
      fit()
    end
  elseif command == "sound" then
    PinballBenchDB.sound = not PinballBenchDB.sound
    say(PinballBenchDB.sound and "Sounds on" or "Sounds off")
  elseif command == "replay" then
    local done = game and not game.replaying and not game.keep and not game.idle and #game.inputs > 0 and game or lastGame
    if not done then
      say("Play a game first")
      return
    end
    local kept = remember(done)
    start({ replaying = kept, hz = kept.hz })
  elseif command == "scores" then
    PinballBenchDB.highScores = nil
    loadSettings()
    say("The high scores are back to the machine's own")
  elseif command == "stop" then
    frame:Hide()
  else
    say("/pinbench, /pinbench play, robot [balls n], sweep, set [name n], defaults, view, sound, walls, replay, scores, stop")
  end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
-- A fight takes the keys back: going into it is the last moment the frame may still let them through
loader:RegisterEvent("PLAYER_REGEN_DISABLED")
loader:RegisterEvent("PLAYER_REGEN_ENABLED")
loader:SetScript("OnEvent", function(_, event, name)
  if event ~= "ADDON_LOADED" then
    frame:SetPropagateKeyboardInput(true)
    frame:EnableKeyboard(event == "PLAYER_REGEN_ENABLED" and frame:IsShown())
    return
  end
  if name == "PinballBench" then
    loadSettings()
    if PinballBenchDB.sound == nil then
      PinballBenchDB.sound = true
    end
    say(ns.Art and "ready: /pinbench" or "ready, without pictures (Tools/PinballBench/install.sh makes them)")
  end
end)
