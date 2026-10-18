--------------------------
--  Pinball: the machine
--------------------------
-- The pinball machine on screen, for the game (Pinball.lua) and for the bench that tries it out
-- (Tools/PinballBench): the table and its cabinet, the lamps, the dot-matrix display in the
-- backbox, the sounds, what the class spells look like and the bar they are cast from, and the
-- machine calling to be played while it waits. Everything it shows follows what the rules
-- (Rules.lua) say happened (ns.Cue).
--
-- The whole machine is built in 3D and rendered ahead of time (Tools/pinball_blender.py, by
-- Tools/make_pinball.py into Images/): the cabinet, the backbox at its far end with the display's
-- glass in it, and the table seen from above the player's end as Space Cadet showed its table.
-- Everything that moves or lights up is a picture of its own at each of its places, and only
-- where things are has to be worked out, by the camera the pictures were drawn from.
--
-- There is one machine, made the first time it is asked for (Machine.New) inside the frame it is
-- shown in. What uses it says how big it may be (Machine.Layout), starts games on it
-- (Machine.Start: a game, or idle, waiting to be played), passes it the keys (Machine.KeyDown,
-- Machine.KeyUp), and moves it on every frame (Machine.Tick). What it needs from whoever uses it
-- comes with New:
--   tune         the settings the table plays with (Build.lua's DEFAULTS)
--   soundOn      whether sounds are to be played
--   L            the strings, the game's own from the locale
--   highScores   a list of { name, score }, best first, for a machine that keeps its own and has
--                a high score signed with initials (the bench). Without it, best() says the
--                best score there is, for the display to show
--   best         as above
--   canStart     whether Enter starts a game, which the machine then does itself
--   onOver       called with the game when a game is over (not one played by the robot)
--   onView       called with "cabinet" or "close" when the player switches what is shown
--   dotImages    where the display's letters are, if not where the engine keeps them

local ADDON, ns = ...
local Rules, LightShow = ns.Rules, ns.LightShow
local Shows = LightShow.Shows
-- The display, a part of the view side, looked for when the machine is made
local DotMatrix

local IMAGES = "Interface\\AddOns\\" .. ADDON .. "\\Images\\"
local FX = IMAGES .. "FX\\"

local floor, min, max, abs, sqrt, pi = math.floor, math.min, math.max, math.abs, math.sqrt, math.pi
local sin, cos = math.sin, math.cos

local Machine = {}
ns.Machine = Machine

-- How wide the panel beside the machine is, with the spells and the keys
local PANEL = 250
Machine.PANEL = PANEL
-- How high the middle of a ball is over what it rolls on
local BALL_HEIGHT = 13.5
-- How long the machine shows the game that just ended before it goes back to waiting
local GAME_OVER_SECONDS = 6
-- Seconds between the machine's tunes while it waits, and before the first
local CALL_EVERY, FIRST_CALL = 50, 14
-- How many high scores a machine that keeps its own keeps
local HIGH_SCORES = 4
local LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
-- Below this height the machine is shown closer in, the backbox cut off above its display, unless
-- the player chose otherwise
local CLOSE_BELOW = 760

-- The keys the machine plays with. Whoever uses it adds its own
local KEYS = {
  LSHIFT = "left", Z = "left", LEFT = "left",
  RSHIFT = "right", ["/"] = "right", RIGHT = "right",
  SPACE = "plunger", DOWN = "plunger",
  X = "nudgeLeft", ["."] = "nudgeRight", UP = "nudgeUp",
  ["1"] = "frost", ["2"] = "post",
  ENTER = "start", V = "view",
}
Machine.KEYS = KEYS

local function commas(number)
  number = floor(number)
  if BreakUpLargeNumbers then
    return BreakUpLargeNumbers(number)
  end
  local text = tostring(number)
  return (text:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end
Machine.commas = commas

-- What the machine is shown on, made by New
local board, playfield, shade, chill, display, panel, helpText
local layers = { bands = {}, slots = {} }
--- @type table What the machine was made with (New)
local options
local tune

--- @type table? The game being played on it (Rules.NewGame)
local game
local view = { scale = 1, balls = {}, lamps = {}, lines = {}, mode = "auto", flippers = {} }
Machine.view = view

local function hz()
  return game.world.hz
end

local function seconds(count)
  return floor(count * hz() + 0.5)
end

local function L(key)
  return options.L[key] or key
end

-- Sounds
-----------------------------
-- Played as the rules say what happened. The same sound is never started more than once in
-- QUIET seconds, and the ball's knocks against rails and rubber only when they were hard
local QUIET = 0.045
local soundAt = {}
local muted = false

local function play(event)
  if muted or not options.soundOn() or not ns.Sounds then
    return
  end
  local sound = ns.Sounds[event]
  if not sound then
    return
  end
  local now = GetTime()
  if soundAt[event] and now - soundAt[event] < QUIET then
    return
  end
  soundAt[event] = now
  if sound.files and #sound.files > 0 then
    local file = sound.files[math.random(#sound.files)]
    pcall(PlaySoundFile, ns.SOUND_FOLDER .. file .. ".ogg", "SFX")
  end
  if sound.kit then
    pcall(PlaySound, sound.kit, "SFX")
  end
end

-----------------------------
-- Lights
-----------------------------
-- Every lamp of the table, the bumpers' caps, the flashers, the speakers' rings in the backbox and
-- the start button are lamps of one light show. What each lamp means is set from the game every
-- frame (lightsFromGame); the shows the rules' news sets off play over that
local lights

-- The lamps of the cabinet, which Tools/pinball_blender.py lights, where they are about on the table
local CABINET_LAMPS = {
  { name = "speakerLeft", x = 40, y = -160 },
  { name = "speakerRight", x = 472, y = -160 },
  { name = "start", x = 60, y = 1070 },
}

local function lampNames(filter)
  local names = {}
  for _, lamp in ipairs(ns.Table.lamps) do
    if not filter or lamp.name:find(filter) then
      names[#names + 1] = lamp.name
    end
  end
  return names
end

local function makeLights()
  local list = {}
  for _, lamp in ipairs(ns.Table.lamps) do
    list[#list + 1] = { name = lamp.name, x = lamp.x, y = lamp.y }
  end
  for _, shape in ipairs(ns.Table.shapes) do
    if shape.role == "bumper" then
      list[#list + 1] = { name = shape.name, x = shape.x, y = shape.y }
    end
  end
  for _, flasher in ipairs(ns.Table.flashers or {}) do
    list[#list + 1] = { name = flasher.name, x = flasher.x, y = flasher.y }
  end
  for _, lamp in ipairs(CABINET_LAMPS) do
    list[#list + 1] = lamp
  end
  lights = LightShow.New(list)
end

local function flashers(names, times, seconds_, priority)
  lights:Play(Shows.Flash(names, times), GetTime(), seconds_, priority or 6)
end

local ALL_FLASHERS = { "flashLeft", "flashRight", "flashRamp", "flashWell", "speakerLeft", "speakerRight" }
local SPEAKERS = { "speakerLeft", "speakerRight" }

--- What the table does while nobody is playing it: sweeps, chases and sparkles, round and round
local function attractShow()
  local inserts = lampNames()
  local ring = lampNames("^quest")
  return Shows.Cycle({
    { light = Shows.Sweep(lights.lamps, "up", 1.2, 90, inserts), seconds = 1.4 },
    { light = Shows.Sweep(lights.lamps, "down", 1.2, 90, inserts), seconds = 1.4 },
    { light = Shows.Chase(ring, 10, 2), seconds = 2 },
    { light = Shows.Sweep(lights.lamps, "right", 1, 80, inserts, 2), seconds = 2 },
    { light = Shows.Sparkle(1.5, 7, inserts), seconds = 2.5 },
    { light = Shows.Ripple(238, 450, 500, 80, inserts), seconds = 1.6 },
  })
end

local function blinkIf(name, on, period)
  lights:Set(name, on and "blink" or false, period or 0.3, GetTime())
end

--- Sets every lamp's own state from what is going on in the game
local function lightsFromGame()
  local now = GetTime()
  if game.idle then
    -- Waiting to be played: the start button blinking, the speakers breathing
    lights:Set("start", "blink", 0.8, now)
    lights:Set("speakerLeft", "pulse", 3, now)
    lights:Set("speakerRight", "pulse", 3, now)
    return
  end
  lights:Set("start", game.over and "blink" or false, 0.8, now)
  lights:Set("speakerLeft", false)
  lights:Set("speakerRight", false)
  local quest = game.quest
  local shot = quest and quest.shot
  for i = 1, 3 do
    local skill = game.skillLane == i
    lights:Set("lane" .. i, skill and "blink" or game.lanes[i] or false, skill and 0.15 or 0.5, now)
    lights:Set("target" .. i, not game.named["target" .. i].active or (shot == "target" and "blink"), 0.4, now)
  end
  local saucerCalls = game.talents > 0 or game.raidLit or (game.questLit and not quest) or (game.raid and game.raid.superLit)
  lights:Set("saucer", saucerCalls and "blink" or "pulse", saucerCalls and 0.25 or 2.4, now)
  local rampCalls = game.raid or game.extraLit or shot == "ramp"
  lights:Set("ramp", rampCalls and "blink" or "pulse", rampCalls and 0.2 or 1.6, now)
  local comboFrom = game.lastOrbit and game.world.tick - game.lastOrbit.tick < seconds(3) and game.lastOrbit.side
  blinkIf("spinner", shot == "spin" or shot == "orbit" or comboFrom == "right", 0.25)
  blinkIf("rightOrbit", shot == "orbit" or comboFrom == "left", 0.25)
  blinkIf("standup1", shot == "standup", 0.3)
  blinkIf("standup2", shot == "standup", 0.3)
  lights:Set("kickback", game.kickback)
  lights:Set("leftOutlane", game.kickback)
  local saving = game.saveUntil and game.world.tick <= game.saveUntil
  lights:Set("shootAgain", saving and "blink" or game.extraBalls > 0 or game.named.centerPost.active, saving and 0.35 or 0.5, now)
  local progress = Rules.TierProgress(game) * 5
  for i = 1, 5 do
    local lit = i <= floor(progress)
    lights:Set("level" .. i, lit or (i == floor(progress) + 1 and "blink"), 0.6, now)
  end
  for i = 1, 8 do
    local doing = quest and i == game.questsStarted % 8 or (quest and game.questsStarted % 8 == 0 and i == 8)
    lights:Set("quest" .. i, i <= game.questsDone or (doing and "blink"), 0.3, now)
  end
  for n = 2, 5 do
    lights:Set("bonus" .. n .. "x", game.multiplier >= n)
  end
  blinkIf("extraBall", game.extraLit, 0.4)
  blinkIf("jackpot", game.raid, 0.18)
  blinkIf("superJackpot", game.raid and game.raid.superLit, 0.15)
  lights:Set("raid", game.raid and "on" or game.raidLit and "blink" or false, 0.3, now)
  -- The Moonwell's tube glows while a ball rides up it
  local riding = false
  for _, ball in ipairs(game.world.balls) do
    riding = riding or (ball.rail and ball.rail.name == "wellWire" and ball.along < 160)
  end
  lights:Set("flashWell", riding)
end

-----------------------------
-- The display
-----------------------------
-- What the dot-matrix display shows: the score and how the game stands, and over it, for a while,
-- whatever the rules have news of. A message is drawn afresh every frame by its own function, `t`
-- seconds after it began, so it can move and flash
local messages = {}

-- Little pictures in dots, a row of characters for each row, "#" lit
local ICONS = {
  flake = { "#...#...#", ".#..#..#.", "..#.#.#..", "...###...", "#########", "...###...", "..#.#.#..", ".#..#..#.",
    "#...#...#" },
  shield = { "#########", "#.......#", "#..###..#", "#..###..#", "#...#...#", "#...#...#", ".#..#..#.", ".#.....#.",
    "..#...#..", "...#.#...", "....#...." },
  moon = { "....####...", "..###......", ".###.......", ".##........", "###........", "###........", "###........",
    "###........", ".##........", ".###.......", "..###......", "....####..." },
}

--- An icon twice as big, every dot four
local function doubled(rows)
  local out = {}
  for _, row in ipairs(rows) do
    local wide = row:gsub(".", "%0%0")
    out[#out + 1] = wide
    out[#out + 1] = wide
  end
  return out
end
ICONS.bigFlake, ICONS.bigShield, ICONS.bigMoon = doubled(ICONS.flake), doubled(ICONS.shield), doubled(ICONS.moon)

local function message(seconds_, priority, draw)
  local now = GetTime()
  -- One of a higher priority showing keeps this one waiting behind it; the same or lower is replaced
  for index = #messages, 1, -1 do
    if messages[index].priority <= priority then
      table.remove(messages, index)
    end
  end
  table.insert(messages, { from = now, til = now + seconds_, priority = priority, draw = draw })
  table.sort(messages, function(a, b)
    return a.priority > b.priority
  end)
end

--- Two lines, a big one and a small one under it, the big one flashing for its first moments
local function headline(big, small, seconds_, priority, flash)
  message(seconds_ or 2, priority or 2, function(t)
    local lit = not flash or t > 0.8 or (t * 8) % 2 < 1.3
    if lit then
      display:Text(big, 64, small and 2 or 9, "big", "center")
    end
    if small then
      display:Text(small, 64, 22, "small", "center")
    end
  end)
end

--- A line coming in from the right and going out to the left, over a second line
local function scroller(text, small, seconds_, priority)
  local width = DotMatrix.Width(text, "big")
  message(seconds_ or 3, priority or 2, function(t)
    local x = 128 - (t / (seconds_ or 3)) * (128 + width)
    display:Text(text, x, 2, "big", "left")
    if small then
      display:Text(small, 64, 22, "small", "center")
    end
  end)
end

local function highScores()
  return options.highScores and options.highScores() or {}
end

--- What the display goes round while the machine waits: each scene, and how long it is shown
local ATTRACT = {
  { seconds = 4, draw = function(t)
    -- The table's name by the moon, a band of light passing over it
    display:Bitmap(ICONS.moon, 4, 4, 0.9)
    local sweep = (t * 50) % 160 - 20
    display:Text("MOONGLADE", 74, 2, "big", "center")
    display:Box(floor(sweep), 0, 3, 32, 0.25)
    display:Text("A PINBALL TABLE", 74, 23, "small", "center", 0.8)
  end },
  { seconds = 3, skip = function()
    return not options.canStart
  end, draw = function(t)
    display:Text("PRESS", 64, 0, "small", "center")
    display:Text("START", 64, 8, "big", "center", (t * 2) % 1 < 0.7 and 1 or 0.35)
    display:Text("ENTER OR R", 64, 25, "small", "center")
  end },
  { seconds = 3, skip = function()
    return not options.best or not options.best()
  end, draw = function()
    display:Text("YOUR BEST", 64, 1, "small", "center")
    display:Text(commas(options.best() or 0), 64, 11, "big", "center")
  end },
  { seconds = 3, skip = function()
    return #highScores() == 0
  end, draw = function()
    local best = highScores()[1]
    display:Text("GRAND CHAMPION", 64, 1, "small", "center")
    display:Text(best and best.name or "", 64, 8, "big", "center")
    display:Text(best and commas(best.score) or "", 64, 25, "small", "center")
  end },
  { seconds = 4, skip = function()
    return #highScores() < 2
  end, draw = function()
    display:Text("HIGHEST SCORES", 64, 0, "small", "center", 0.8)
    for index = 2, min(4, #highScores()) do
      local entry = highScores()[index]
      local y = 1 + (index - 1) * 8
      display:Text(("%d %s"):format(index, entry.name), 4, y, "small", "left")
      display:Text(commas(entry.score), 124, y, "small", "right")
    end
  end },
  { seconds = 3, skip = function()
    return not view.lastScore
  end, draw = function()
    display:Text("LAST GAME", 64, 1, "small", "center")
    display:Text(commas(view.lastScore or 0), 64, 11, "big", "center")
  end },
  { seconds = 3, draw = function(t)
    display:Text("FREE PLAY", 64, 3, "big", "center")
    display:Text("REPLAY AT 1,000,000", 64, 23, "small", "center")
  end },
  { seconds = 9, draw = function(t)
    local text = "SHOOT THE RAMP TO RIDE THE CORKSCREW  -  THE MOONWELL TRAINS YOUR TALENTS  -  1 FROST NOVA  2 SHIELD WALL"
    local width = DotMatrix.Width(text, "small")
    display:Text(text, 128 - t / 9 * (128 + width), 12, "small", "left")
    display:Bitmap(ICONS.moon, 1, 1, 0.5)
  end },
}

local function attractScene(now)
  local total = 0
  for _, scene in ipairs(ATTRACT) do
    if not (scene.skip and scene.skip()) then
      total = total + scene.seconds
    end
  end
  local t = (now - (view.idleSince or now)) % total
  for _, scene in ipairs(ATTRACT) do
    if not (scene.skip and scene.skip()) then
      if t < scene.seconds then
        scene.draw(t)
        return
      end
      t = t - scene.seconds
    end
  end
end

--- The initials of a new high score being entered
local function entryScene(now)
  local entry = view.entry
  local title = entry.done and "THANK YOU" or ((now % 4) < 2.5 and "ENTER YOUR INITIALS" or commas(entry.score))
  display:Text(title, 64, 0, "small", "center")
  for index = 1, 3 do
    local letter = entry.letters[index]
    local shown = index < entry.at or entry.done or (index == entry.at and (now * 3) % 1 < 0.7)
    local x = 64 + (index - 2) * 16
    if index <= entry.at or entry.done then
      display:Text(shown and LETTERS:sub(letter, letter) or " ", x, 9, "big", "center")
    end
    display:Box(x - 5, 27, 10, 1, index == entry.at and not entry.done and 1 or 0.4)
  end
end

local function scoreScene(now)
  local world = game.world
  if game.idle then
    attractScene(now)
    return
  end
  if game.over then
    display:Text("GAME OVER", 64, 2, "big", "center")
    display:Text(commas(game.score), 64, 22, "small", "center")
    return
  end
  display:Text(commas(game.score), 64, 4, "big", "center")
  local quest = game.quest
  if quest then
    local left = max(0, (quest.ends - world.tick) / world.hz)
    display:Text(("%s %d/%d"):format(quest.name, quest.made, quest.count), 1, 24, "small", "left")
    display:Text(("%d"):format(left), 127, 24, "small", "right")
  elseif game.keep then
    display:Text(("ROBOT  %d BALLS"):format(#world.balls), 64, 24, "small", "center")
  else
    display:Text(("BALL %d"):format(game.ball), 1, 24, "small", "left")
    display:Text(("LEVEL %d"):format(game.level), 127, 24, "small", "right")
    if game.multiplier > 1 then
      display:Text(("%dX"):format(game.multiplier), 64, 24, "small", "center")
    end
  end
  -- The spells running, in the corners over the score
  local spells = Rules.Spells(game)
  if spells.frost.running > 0 then
    display:Bitmap(ICONS.flake, 1, 1, (now * 4) % 1 < 0.75 and 1 or 0.5)
  end
  if spells.wall.running > 0 then
    display:Bitmap(ICONS.shield, 118, 1, spells.wall.running > 2 and 1 or ((now * 5) % 1 < 0.5 and 1 or 0.3))
  end
  if game.tilted then
    display:Box(0, 0, 128, 32, 0.15)
    display:Text("TILT", 64, 9, "big", "center")
  end
end

local function drawDisplay()
  local now = GetTime()
  display:Begin()
  for index = #messages, 1, -1 do
    if now >= messages[index].til then
      table.remove(messages, index)
    end
  end
  local top = messages[1]
  if view.entry then
    entryScene(now)
  elseif top then
    top.draw(now - top.from)
  else
    scoreScene(now)
  end
  display:Finish()
end

-----------------------------
-- Drawing
-----------------------------
-- The table seen from above the player's end, the machine built and lit in 3D and drawn ahead of
-- time (Tools/pinball_blender.py), where everything that moves is a picture of it at each of its
-- places, and only where things are has to be worked out, by the camera the pictures were drawn
-- from: Art.tilt.camera takes a point of the table, and how high it is, to where it is in them.

--- How high the ramp's floor is where a ball on it is, along the middle of the ramp nearest it
local function rampHeight(x, y)
  local best, height = math.huge, 0
  for _, rampPath in ipairs(ns.Table.ramps or {}) do
    local p = rampPath.path
    for i = 1, #p - 5, 3 do
      local ax, ay, az, bx, by, bz = p[i], p[i + 1], p[i + 2], p[i + 3], p[i + 4], p[i + 5]
      local dx, dy = bx - ax, by - ay
      local length2 = dx * dx + dy * dy
      local t = length2 > 0 and max(0, min(1, ((x - ax) * dx + (y - ay) * dy) / length2)) or 0
      local px, py = ax + dx * t, ay + dy * t
      local d2 = (x - px) * (x - px) + (y - py) * (y - py)
      if d2 < best then
        best, height = d2, az + (bz - az) * t
      end
    end
  end
  return height
end

--- How high the underside of a ball is: on a wire as high as the wire, on the ramp its floor
local function ballFloor(ball)
  if ball.rail then
    return ball.z
  end
  return ball.layer == 2 and rampHeight(ball.x, ball.y) or 0
end

--- Where a point of the table is on the board, in the board's units from its top left corner, y
--- down; how many of them a millimetre of the table is there, across and down; and how far it is
--- from the camera (w), which says how big what is there is drawn
local function project(x, y, z)
  local p, k = ns.Art.tilt.camera, view.scale
  z = z or 0
  local w = p[9] * x + p[10] * y + p[11] * z + p[12]
  local u = (p[1] * x + p[2] * y + p[3] * z + p[4]) / w
  local v = (p[5] * x + p[6] * y + p[7] * z + p[8]) / w
  local w2 = w + p[9]
  local ax = (p[1] * (x + 1) + p[2] * y + p[3] * z + p[4]) / w2 - u
  local ay = (p[5] * (x + 1) + p[6] * y + p[7] * z + p[8]) / w2 - v
  local w3 = w + p[10]
  local bx = (p[1] * x + p[2] * (y + 1) + p[3] * z + p[4]) / w3 - u
  local by = (p[5] * x + p[6] * (y + 1) + p[7] * z + p[8]) / w3 - v
  return (u - view.left) * k, (v - view.top) * k, sqrt(ax * ax + ay * ay) * k, sqrt(bx * bx + by * by) * k, w
end

--- Shows a picture drawn for the machine where it was drawn to go: P is { file, x, y, w, h, u, v,
--- pw, ph }, the part of the file it is and where on the machine's picture that goes
local function placed(texture, p, dx, dy)
  local tilt, k = ns.Art.tilt, view.scale
  local file = tilt.files[p.file]
  texture:SetTexture(IMAGES .. p.file)
  texture:SetTexCoord(p.x / file.w, (p.x + p.w) / file.w, p.y / file.h, (p.y + p.h) / file.h)
  texture:ClearAllPoints()
  texture:SetPoint("TOPLEFT", board, "TOPLEFT", (p.u - view.left) * k + (dx or 0), -(p.v - view.top) * k - (dy or 0))
  texture:SetSize(max(0.5, p.pw * k), max(0.5, p.ph * k))
end

--- The one of a list of frames nearest `value` in its field `key`
local function nearest(frames, key, value)
  local best, off = frames[1], math.huge
  for _, candidate in ipairs(frames) do
    local d = abs(candidate[key] - value)
    if d < off then
      best, off = candidate, d
    end
  end
  return best
end

--- The frames over the board, made once the pictures say how many heights there are pictures of
local function makeLayers()
  if layers.made then
    return
  end
  layers.made = true
  local base = board:GetFrameLevel()
  local function layer(level)
    local made = CreateFrame("Frame", nil, board)
    made:SetAllPoints()
    made:SetFrameLevel(base + level)
    return made
  end
  local count = #ns.Art.tilt.over
  for k = 1, count do
    layers.bands[k] = layer(2 * k + 1)
    layers.slots[k] = layer(2 * k + 2)
  end
  layers.flashes = layer(2 * count + 4)
  layers.fx = layer(2 * count + 6)
  layers.wires = layer(2 * count + 10)
  display.frame:SetFrameLevel(base + 2 * count + 8)
end

--- Which of the frames between the heights a ball whose top is `top` mm high goes in: over every
--- height lower than its top, under the rest. 0 is the board itself, under them all
local function slotFor(top)
  local slot = 0
  for k, band in ipairs(ns.Art.tilt.over) do
    if band.height < top then
      slot = k
    end
  end
  return slot
end

--- The lines of what the ball meets, drawn once for each layout, and the wires' ways in the air
local function drawWires()
  for _, line in ipairs(view.lines) do
    line:Hide()
  end
  if not view.showWires then
    return
  end
  local count = 0
  local function segment(x1, y1, z1, x2, y2, z2, r, g, b)
    count = count + 1
    local line = view.lines[count] or layers.wires:CreateLine(nil, "OVERLAY")
    view.lines[count] = line
    line:SetColorTexture(r, g, b, 0.85)
    line:SetThickness(1.5)
    local ax, ay = project(x1, y1, z1)
    local bx, by = project(x2, y2, z2)
    line:SetStartPoint("TOPLEFT", board, ax, -ay)
    line:SetEndPoint("TOPLEFT", board, bx, -by)
    line:Show()
  end
  for _, made in ipairs(game.world.shapes) do
    local r, g, b = 0.9, 0.9, 1
    local raised = made.layers == 2
    if made.sensor then
      r, g, b = 1, 0.85, 0.2
    elseif raised then
      r, g, b = 0.3, 1, 0.5
    elseif made.kick then
      r, g, b = 1, 0.4, 0.3
    end
    local function z(x, y)
      return raised and rampHeight(x, y) or 0
    end
    if made.kind == "segment" then
      segment(made.x1, made.y1, z(made.x1, made.y1), made.x2, made.y2, z(made.x2, made.y2), r, g, b)
    elseif made.kind == "circle" then
      local steps = 12
      for k = 0, steps - 1 do
        local a1, a2 = 2 * pi * k / steps, 2 * pi * (k + 1) / steps
        local x1, y1 = made.x1 + made.r * cos(a1), made.y1 + made.r * sin(a1)
        local x2, y2 = made.x1 + made.r * cos(a2), made.y1 + made.r * sin(a2)
        segment(x1, y1, z(x1, y1), x2, y2, z(x2, y2), r, g, b)
      end
    elseif made.kind == "box" then
      segment(made.x1, made.y1, 0, made.x2, made.y1, 0, r, g, b)
      segment(made.x2, made.y1, 0, made.x2, made.y2, 0, r, g, b)
      segment(made.x2, made.y2, 0, made.x1, made.y2, 0, r, g, b)
      segment(made.x1, made.y2, 0, made.x1, made.y1, 0, r, g, b)
    end
  end
  for _, rail in ipairs(game.world.rails) do
    local p = rail.points
    for i = 1, #p - 5, 6 do
      local j = min(i + 6, #p - 2)
      segment(p[i], p[i + 1], p[i + 2], p[j], p[j + 1], p[j + 2], 0.3, 0.9, 1)
    end
  end
end

-----------------------------
-- The spells' light
-----------------------------
-- What the class spells look like when they are cast and while they run, made of the pictures of
-- Tools/make_pinball_fx.py: rings going out over the playfield, frost creeping over the glass,
-- snowflakes, ice round a frozen ball and splinters when it breaks; the shield over the post. Each
-- effect is a few textures and a function moving them, `t` seconds after it began, for as long as
-- it lasts; the textures are kept for the next one when it ends.
local effects = {}
local spare = {}

local function fxTexture(file, low)
  local key = (low and "low:" or "high:") .. file
  local list = spare[key]
  local texture = list and table.remove(list)
  if not texture then
    texture = low and board:CreateTexture(nil, "BORDER", nil, 7) or layers.fx:CreateTexture(nil, "ARTWORK")
    texture:SetTexture(FX .. file)
    texture:SetBlendMode("ADD")
    texture.key = key
  end
  texture:SetVertexColor(1, 1, 1, 1)
  texture:SetRotation(0)
  texture:Show()
  return texture
end

local function effect(seconds_, textures, update)
  effects[#effects + 1] = { from = GetTime(), seconds = seconds_, textures = textures, update = update }
end

local function runEffects(now)
  for index = #effects, 1, -1 do
    local e = effects[index]
    local t = now - e.from
    if t >= e.seconds or (e.update(t, e) == false) then
      for _, texture in ipairs(e.textures) do
        texture:Hide()
        spare[texture.key] = spare[texture.key] or {}
        table.insert(spare[texture.key], texture)
      end
      table.remove(effects, index)
    end
  end
end

--- Puts a texture flat on the table, round x, y, z, `r` mm out from there each way
local function onTable(texture, x, y, z, r)
  local px, py, across, down = project(x, y, z)
  texture:ClearAllPoints()
  texture:SetPoint("CENTER", board, "TOPLEFT", px, -py)
  texture:SetSize(max(0.5, 2 * r * across), max(0.5, 2 * r * down))
end

--- Puts a texture standing up, facing the camera, its middle at x, y, z, `mm` across
local function standing(texture, x, y, z, mm, dx, dy)
  local px, py, across = project(x, y, z)
  texture:ClearAllPoints()
  texture:SetPoint("CENTER", board, "TOPLEFT", px + (dx or 0), -py - (dy or 0))
  texture:SetSize(max(0.5, mm * across), max(0.5, mm * across))
end

--- A ring going out over the playfield from x, y, from r0 to r1 mm, fading as it goes
local function ringOut(file, x, y, r0, r1, seconds_, colour, z)
  local texture = fxTexture(file, true)
  texture:SetVertexColor(colour[1], colour[2], colour[3], 1)
  effect(seconds_, { texture }, function(t)
    local k = t / seconds_
    local eased = 1 - (1 - k) * (1 - k)
    onTable(texture, x, y, z or 0, r0 + (r1 - r0) * eased)
    texture:SetAlpha((1 - k) * (1 - k))
  end)
end

--- Bits flying out from x, y, z and falling, spinning, fading: splinters of ice or sparks
local function burst(file, x, y, z, count, mm, speed, seconds_, colour)
  local textures, ways = {}, {}
  for index = 1, count do
    textures[index] = fxTexture(file)
    textures[index]:SetVertexColor(colour[1], colour[2], colour[3], 1)
    local a = 2 * pi * (index + math.random() * 0.6) / count
    ways[index] = { cos(a) * speed * (0.6 + math.random() * 0.6), sin(a) * speed * (0.6 + math.random() * 0.6) + speed * 0.3,
      (math.random() - 0.5) * 12 }
  end
  effect(seconds_, textures, function(t)
    local px, py, across = project(x, y, z)
    for index, texture in ipairs(textures) do
      local way = ways[index]
      -- Screen pixels: out, and falling down the screen
      local ox, oy = way[1] * t * across, (way[2] * t - 260 * t * t) * across
      texture:ClearAllPoints()
      texture:SetPoint("CENTER", board, "TOPLEFT", px + ox, -py + oy)
      texture:SetSize(mm * across, mm * across * (file == "shard" and 2 or 1))
      texture:SetRotation(way[3] * t)
      texture:SetAlpha(max(0, 1 - t / seconds_))
    end
  end)
end

--- The part of the board the playfield takes up, for what is laid over all of it
local function playfieldBox()
  local x0, y0 = math.huge, math.huge
  local x1, y1 = -math.huge, -math.huge
  for _, corner in ipairs({ { 0, 0 }, { 512, 0 }, { 0, 1024 }, { 512, 1024 } }) do
    local px, py = project(corner[1], corner[2], 0)
    x0, y0, x1, y1 = min(x0, px), min(y0, py), max(x1, px), max(y1, py)
  end
  return x0, y0, x1, y1
end

local ICE = { 0.55, 0.85, 1 }
local GOLD = { 1, 0.78, 0.3 }
-- What is shown of the spells now: Frost Nova's frost and the balls it holds, the shield over the post
local spellsShown = { frost = nil, frozen = {}, shield = nil }

--- Frost creeping over the glass, and snowflakes drifting down it, while Frost Nova holds the balls
local function frostOver(seconds_)
  local glass = fxTexture("frost")
  glass:SetBlendMode("BLEND")
  local flakes = {}
  local x0, y0, x1, y1 = playfieldBox()
  for index = 1, 16 do
    local flake = fxTexture("flake")
    flake.start = { x0 + math.random() * (x1 - x0), y0 + math.random() * (y1 - y0) * 0.8, math.random() * 2 - 1, 6 + math.random() * 10 }
    flakes[index] = flake
  end
  local textures = { glass, unpack(flakes) }
  effect(seconds_ + 0.6, textures, function(t)
    local shown = spellsShown.frost
    -- In quickly, out as the ice breaks
    local level = min(1, t / 0.18)
    if shown and shown.til and GetTime() > shown.til then
      level = max(0, 1 - (GetTime() - shown.til) / 0.45)
      if level <= 0 then
        return false
      end
    end
    glass:ClearAllPoints()
    glass:SetPoint("TOPLEFT", board, "TOPLEFT", x0 - 10, -(y0 - 10))
    glass:SetPoint("BOTTOMRIGHT", board, "TOPLEFT", x1 + 10, -(y1 + 10))
    glass:SetAlpha(level * 0.85)
    chill:SetAlpha(level * 0.16)
    for _, flake in ipairs(flakes) do
      local s = flake.start
      flake:ClearAllPoints()
      flake:SetPoint("CENTER", board, "TOPLEFT", s[1] + sin(t * 1.3 + s[3] * 3) * 10, -(s[2] + t * 30 * (1 + s[3] * 0.3)))
      flake:SetSize(s[4] * view.scale * 2.2, s[4] * view.scale * 2.2)
      flake:SetRotation(t * s[3])
      flake:SetAlpha(level * 0.8)
    end
  end)
end

--- The shield over the post while Shield Wall holds it up: rising as it comes up, a glow on the
--- playfield round it, pulsing, and blinking as it is about to go
local function shieldOver(post)
  local emblem = fxTexture("shield")
  local glow = fxTexture("ring", true)
  local halo = fxTexture("glow", true)
  effect(tune.wallSeconds + 1, { emblem, glow, halo }, function(t)
    local shown = spellsShown.shield
    if not shown then
      return false
    end
    local now = GetTime()
    local level = min(1, t / 0.25)
    if shown.til and now > shown.til then
      level = max(0, 1 - (now - shown.til) / 0.35)
      if level <= 0 then
        return false
      end
    end
    local left = shown.ends - now
    if left < 2 and not shown.til then
      level = level * ((now * 6) % 1 < 0.6 and 1 or 0.35)
    end
    local struck = shown.struck and max(0, 1 - (now - shown.struck) / 0.4) or 0
    local pulse = 0.75 + 0.25 * sin(now * 5)
    local rise = (1 - min(1, t / 0.25)) * 18
    local size = 34 + 10 * struck + (1 - min(1, t / 0.25)) * 30
    standing(emblem, post.x1, post.y1, 46 - rise, size)
    emblem:SetAlpha(level * (pulse * 0.8 + struck))
    onTable(glow, post.x1, post.y1, 0, 24 + 6 * struck)
    glow:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 1)
    glow:SetAlpha(level * (0.45 * pulse + struck))
    onTable(halo, post.x1, post.y1, 0, 34)
    halo:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 1)
    halo:SetAlpha(level * (0.3 + struck * 0.6))
  end)
end

-----------------------------
-- The spell bar
-----------------------------
-- The two spells on buttons in the panel, as the game's own action bar has them: the icon, the key
-- that casts it, a shadow wiping down as it cools down with the seconds left on it, and a glow
-- round it while it runs, with a bar of how long it has still to run. A click casts it too, and
-- the mouse over it says what it does
local SPELLS = {
  { key = "frost", action = "frost", icon = "Interface\\Icons\\Spell_Frost_FrostNova", name = "pinball_frost", bind = "1",
    colour = ICE, tip = "pinball_frost_tip", about = "pinball_frost_about" },
  { key = "wall", action = "post", icon = "Interface\\Icons\\Ability_Warrior_ShieldWall", name = "pinball_wall", bind = "2",
    colour = GOLD, tip = "pinball_wall_tip", about = "pinball_wall_about" },
}
local spellBar = {}

--- Casts a spell, as its key does, if a game is being played
local function castFromBar(spell)
  if game and not game.over and not game.robot and not game.replaying and not view.entry then
    table.insert(game.queue, spell.action)
  end
end

--- The buttons of the spells, in the panel
local function makeSpellBar()
  for index, spell in ipairs(SPELLS) do
    local size = 48
    local button = CreateFrame("Button", nil, panel)
    button:SetSize(size, size)
    button:SetPoint("TOPLEFT", panel, "TOPLEFT", 26 + (index - 1) * 110, -30)
    button:RegisterForClicks("LeftButtonUp")
    button:SetScript("OnClick", function()
      castFromBar(spell)
    end)
    button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    button:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(L(spell.name), 1, 1, 1)
      GameTooltip:AddLine(L("pinball_spell_press"):format(spell.bind), 1, 0.82, 0)
      local lasts = spell.key == "frost" and tune.frostSeconds or tune.wallSeconds
      GameTooltip:AddLine(L(spell.about):format(lasts), nil, nil, nil, true)
      GameTooltip:AddLine(L("pinball_spell_cooldown"):format(spell.key == "frost" and tune.frostCooldown or tune.wallCooldown), 0.6, 0.6, 0.6)
      GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function()
      GameTooltip:Hide()
    end)
    local slot = button:CreateTexture(nil, "BACKGROUND")
    slot:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    slot:SetPoint("CENTER")
    slot:SetSize(size * 1.75, size * 1.75)
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture(spell.icon)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local cooling = button:CreateTexture(nil, "OVERLAY")
    cooling:SetColorTexture(0, 0, 0, 0.7)
    cooling:SetPoint("TOPLEFT")
    cooling:SetPoint("TOPRIGHT")
    local flash = button:CreateTexture(nil, "OVERLAY", nil, 2)
    flash:SetAllPoints()
    flash:SetColorTexture(1, 1, 1, 1)
    flash:SetBlendMode("ADD")
    flash:SetAlpha(0)
    local border = button:CreateTexture(nil, "OVERLAY", nil, 3)
    border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    border:SetBlendMode("ADD")
    border:SetPoint("CENTER")
    border:SetSize(size * 1.8, size * 1.8)
    border:SetVertexColor(spell.colour[1], spell.colour[2], spell.colour[3])
    border:SetAlpha(0)
    local count = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    count:SetPoint("CENTER")
    -- The key that casts it, big, in a dark badge on its corner
    local badge = button:CreateTexture(nil, "OVERLAY", nil, 4)
    badge:SetColorTexture(0, 0, 0, 0.75)
    badge:SetPoint("TOPLEFT", -6, 6)
    badge:SetSize(20, 20)
    local bind = button:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    bind:SetDrawLayer("OVERLAY", 5)
    bind:SetPoint("CENTER", badge, "CENTER", 0, 0)
    bind:SetText(spell.bind)
    local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOP", button, "BOTTOM", 0, -6)
    label:SetText(L(spell.name))
    local press = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    press:SetPoint("TOP", label, "BOTTOM", 0, -2)
    local tip = button:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    tip:SetPoint("TOP", press, "BOTTOM", 0, -2)
    tip:SetWidth(100)
    tip:SetText(L(spell.tip))
    local barBack = button:CreateTexture(nil, "ARTWORK")
    barBack:SetColorTexture(0, 0, 0, 0.6)
    barBack:SetPoint("TOPLEFT", tip, "BOTTOMLEFT", 6, -4)
    barBack:SetSize(88, 5)
    local bar = button:CreateTexture(nil, "OVERLAY")
    bar:SetColorTexture(spell.colour[1], spell.colour[2], spell.colour[3], 0.9)
    bar:SetPoint("LEFT", barBack, "LEFT")
    bar:SetHeight(5)
    spellBar[spell.key] = { icon = icon, cooling = cooling, flash = flash, border = border, count = count, bar = bar,
      barBack = barBack, size = size, press = press, spell = spell }
  end
end

--- Shows how each spell stands on its button
local function drawSpellBar(now)
  local spells = Rules.Spells(game)
  for key, button in pairs(spellBar) do
    local spell = spells[key]
    local castable = not game.over
    button.icon:SetDesaturated(not castable)
    -- What to do to cast it, or why it can't be now
    if not castable then
      button.press:SetText("|cffff7060" .. L("pinball_spell_no_game") .. "|r")
    elseif spell.running > 0 then
      button.press:SetText("|cff80ff80" .. L("pinball_spell_active") .. "|r")
    elseif spell.left > 0 then
      button.press:SetText("|cffa0a0a0" .. L("pinball_spell_cooling") .. "|r")
    else
      button.press:SetText(L("pinball_spell_ready"):format(button.spell.bind))
    end
    -- A flash as it comes off cooldown, ready again
    if spell.left > 0 then
      button.cooled = true
    elseif button.cooled and castable then
      button.cooled = nil
      button.castAt = now
    end
    if spell.left > 0 then
      button.cooling:SetHeight(max(0.5, button.size * spell.left / spell.cooldown))
      button.cooling:Show()
      button.count:SetText(spell.left >= 1 and ("%d"):format(math.ceil(spell.left)) or ("%.1f"):format(spell.left))
    else
      button.cooling:Hide()
      button.count:SetText("")
    end
    local running = spell.running > 0
    button.border:SetAlpha(running and (0.7 + 0.3 * sin(now * 8)) or 0)
    button.bar:SetShown(running)
    button.barBack:SetShown(running)
    if running then
      button.bar:SetWidth(max(0.5, 88 * spell.running / spell.lasts))
    end
    local flashed = button.castAt and now - button.castAt or 9
    button.flash:SetAlpha(max(0, 0.8 - flashed * 2.5))
  end
end

-----------------------------
-- What the rules say happened
-----------------------------
-- How the table answers: sounds, lights, flashers and the display. Nothing here changes the game
local GI_DIM = 0.55
local gi = { level = 1, target = 1 }

local function giDip(level, seconds_)
  gi.target, gi.until_ = level, GetTime() + seconds_
end

local CUES = {}

function CUES.bumper(name)
  play("bumper")
  lights:Play(Shows.Flash({ name }, 1 / 0.24), GetTime(), 0.12, 7)
end
function CUES.sling(name)
  play("sling")
  giDip(0.85, 0.06)
end
function CUES.flipperUp()
  play("flipperUp")
end
function CUES.flipperDown()
  play("flipperDown")
end
function CUES.railHit(speed)
  if (speed or 0) > 900 then
    play("railHit")
  end
end
function CUES.rubberHit(speed)
  if (speed or 0) > 500 then
    play("rubberHit")
  end
end
function CUES.ballHit(speed)
  if (speed or 0) > 300 then
    play("ballHit")
  end
end
function CUES.targetDrop()
  play("targetDrop")
end
function CUES.targetsReset()
  play("targetsReset")
end
function CUES.bank()
  play("coins")
  lights:Play(Shows.Chase(lampNames("^target"), 14), GetTime(), 0.8, 5)
  headline("QUEST READY", "SHOOT THE MOONWELL", 2, 2, true)
end
function CUES.standup(name)
  play("standup")
  lights:Play(Shows.Flash({ name }, 10), GetTime(), 0.3, 5)
end
function CUES.spinner(spins)
  play("spinner")
  -- Its picture turns half a turn for every spin
  game.spinTo = game.spinTo + spins * pi
end
function CUES.orbit(side)
  play("gate")
  lights:Play(Shows.Flash({ side == "left" and "spinner" or "rightOrbit" }, 12), GetTime(), 0.4, 5)
end
function CUES.combo()
  play("coins")
  flashers({ "flashLeft", "flashRight" }, 8, 0.5)
  headline("COMBO", "15,000", 1.6, 3, true)
end
function CUES.rollover(name)
  play("rollover")
  lights:Play(Shows.Flash({ name }, 10), GetTime(), 0.4, 5)
end
function CUES.outlane(name)
  play("rollover")
  lights:Play(Shows.Flash({ name }, 10), GetTime(), 0.5, 5)
end
function CUES.multiplier(times)
  play("coins")
  lights:Play(Shows.Chase(lampNames("^lane"), 15), GetTime(), 0.7, 5)
  headline(("BONUS %dX"):format(times), nil, 1.6, 2, true)
end
function CUES.skillShot()
  play("skillShot")
  flashers(ALL_FLASHERS, 10, 0.8)
  lights:Play(Shows.Flash(lampNames("^lane"), 10), GetTime(), 1, 6)
  headline("SKILL SHOT", "50,000", 2.2, 4, true)
end
function CUES.rampEnter()
  play("rampEnter")
end
function CUES.rampMade(count)
  play("rampMade")
  flashers({ "flashRamp" }, 8, 0.4)
  lights:Play(Shows.Sweep(lights.lamps, "up", 0.5, 70, lampNames()), GetTime(), 0.6, 4)
  headline("RAMP", ("%d MADE"):format(count), 1.4, 1)
end
function CUES.wireOn(name)
  play("wireRail")
  if name == "wellWire" then
    flashers({ "flashWell" }, 10, 0.5)
  end
end
function CUES.wireOff() end
function CUES.extraBall()
  play("extraBall")
  flashers(ALL_FLASHERS, 6, 1.2)
  lights:Play(Shows.Flash(lampNames(), 6), GetTime(), 1, 5)
  headline("EXTRA BALL", "SOULSTONE", 3, 5, true)
end
function CUES.saucerIn()
  play("saucerIn")
end
function CUES.saucerKick()
  play("saucerKick")
end
function CUES.questStart(name, count)
  play("questStart")
  lights:Play(Shows.Chase(lampNames("^quest"), 16, 3), GetTime(), 1, 5)
  scroller(name, "QUEST ACCEPTED", 3, 3)
end
function CUES.questStep(name, made, count)
  if made < count then
    headline(("%d/%d"):format(made, count), name, 0.9, 1)
  end
end
function CUES.questComplete(name)
  play("questComplete")
  flashers(ALL_FLASHERS, 8, 0.8)
  lights:Play(Shows.Sweep(lights.lamps, "down", 0.7, 90, lampNames()), GetTime(), 0.8, 5)
  headline("QUEST COMPLETE", name, 2.6, 4, true)
end
function CUES.questFailed(name)
  play("gameOver")
  headline("QUEST FAILED", name, 2, 3)
end
function CUES.raidLit()
  play("wings")
  headline("RAID IS LIT", "ONYXIA AWAITS", 2.4, 4, true)
end
function CUES.multiball()
  play("multiball")
  flashers(ALL_FLASHERS, 12, 2.5, 7)
  lights:Play(Shows.Chase(lampNames(), 30, 4), GetTime(), 2.5, 5)
  giDip(0.4, 0.8)
  scroller("ONYXIA'S LAIR", "RAID MULTIBALL", 3.5, 5)
end
function CUES.jackpot(count)
  play("jackpot")
  flashers(ALL_FLASHERS, 14, 1.2, 7)
  lights:Play(Shows.Flash(lampNames(), 12), GetTime(), 1, 6)
  headline("JACKPOT", "250,000", 2.2, 5, true)
end
function CUES.superJackpot()
  play("superJackpot")
  flashers(ALL_FLASHERS, 16, 2.5, 7)
  lights:Play(Shows.Ripple(238, 450, 600, 90, lampNames()), GetTime(), 2.5, 6)
  giDip(0.3, 0.5)
  headline("SUPER JACKPOT", "1,000,000", 3.5, 6, true)
end
function CUES.raidOver()
  headline("RAID OVER", nil, 1.5, 2)
end
function CUES.levelUp(level)
  play("levelUp")
  lights:Play(Shows.Ripple(238, 450, 700, 70, lampNames()), GetTime(), 1.4, 4)
  headline("DING!", ("LEVEL %d"):format(level), 1.8, 3, true)
end
function CUES.talentLit(level)
  play("levelUp")
  flashers({ "flashLeft", "flashRight" }, 6, 1)
  lights:Play(Shows.Ripple(238, 450, 700, 70, lampNames()), GetTime(), 1.4, 4)
  headline(("LEVEL %d"):format(level), "TALENT AT MOONWELL", 2.6, 4, true)
end
function CUES.talent(level)
  play("talent")
  flashers(ALL_FLASHERS, 8, 1)
  headline("TALENT LEARNED", "THE TRAINER IS PLEASED", 2.4, 4, true)
end
function CUES.kickback()
  play("kickback")
  flashers({ "flashLeft" }, 10, 0.4)
end
function CUES.kickbackLit()
  lights:Play(Shows.Flash({ "kickback", "leftOutlane" }, 8), GetTime(), 0.8, 5)
end
function CUES.plungerPull()
  play("plungerPull")
end
function CUES.plungerRelease(pulled)
  if pulled > 0.1 then
    play("plungerRelease")
  end
end
function CUES.ballServe()
  play("ballServe")
end
function CUES.ballSave()
  play("ballSave")
  lights:Play(Shows.Flash({ "shootAgain" }, 8), GetTime(), 1.2, 6)
  headline("BALL SAVED", "DIVINE INTERVENTION", 2.2, 4, true)
end
function CUES.drain(left)
  play("drain")
  if left == 0 then
    giDip(0.25, 0.9)
  end
end
function CUES.bonus(bonus, multiplier)
  if bonus > 0 then
    message(2.6, 3, function(t)
      display:Text("BONUS", 64, 2, "small", "center")
      display:Text(commas(floor(bonus * min(1, t / 1.6) / 10) * 10), 64, 11, "big", "center")
      if multiplier > 1 then
        display:Text(("%dX"):format(multiplier), 127, 2, "small", "right")
      end
    end)
  end
end
function CUES.shootAgain()
  play("extraBall")
  headline("SHOOT AGAIN", nil, 2, 3, true)
end
function CUES.nextBall(ball)
  headline(("BALL %d"):format(ball), nil, 1.5, 2)
end
function CUES.gameOver(score)
  play("gameOver")
  headline("GAME OVER", commas(score), 4, 3)
  lights:Play(attractShow(), GetTime(), nil, 0)
  view.overAt = GetTime()
  if not game.keep and not game.wasReplay then
    view.lastScore = score
  end
end
function CUES.tilt()
  play("tilt")
  giDip(0.2, 3)
  lights:Play(Shows.Dark(), GetTime(), 3, 8)
  headline("TILT", nil, 3, 6, true)
end
function CUES.tiltWarning(count)
  play("tiltWarning")
  headline("DANGER", count >= 3 and "ONE MORE AND IT TILTS" or nil, 1.2, 4, true)
end
function CUES.nudge()
  play("ballHit")
end

-- The spells: what each looks and sounds like, cast, running and over
function CUES.frostNova(count)
  play("frostNova")
  local now = GetTime()
  spellsShown.frost = { from = now }
  spellsShown.frozen = {}
  for _, ball in ipairs(game.world.balls) do
    if ball.held == Rules.FROZEN then
      spellsShown.frozen[#spellsShown.frozen + 1] = ball
      ringOut("nova", ball.x, ball.y, 8, 120, 0.55, ICE)
      ringOut("ring", ball.x, ball.y, 10, 190, 0.8, ICE)
    end
  end
  frostOver(tune.frostSeconds)
  flashers({ "flashWell" }, 12, 0.6, 7)
  lights:Play(Shows.Ripple(238, 600, 900, 110, lampNames()), now, 0.7, 5)
  giDip(0.6, tune.frostSeconds)
  if spellBar.frost then
    spellBar.frost.castAt = now
  end
  local frozen = count or #spellsShown.frozen
  message(tune.frostSeconds + 0.3, 4, function(t)
    if t < 0.7 then
      local lit = (t * 8) % 2 < 1.4
      if lit then
        display:Text("FROST NOVA", 64, 3, "big", "center")
      end
      display:Text(frozen == 1 and "THE BALL IS FROZEN" or ("%d BALLS FROZEN"):format(frozen), 64, 23, "small", "center")
      return
    end
    display:Bitmap(ICONS.bigFlake, 2, 4, 1)
    display:Bitmap(ICONS.bigFlake, 108, 4, 1)
    display:Text("FROZEN", 64, 5, "big", "center")
    local left = max(0, 1 - t / tune.frostSeconds)
    display:Box(28, 26, floor(72 * left + 0.5), 2, 0.9)
  end)
end
function CUES.frostEnd()
  play("frostEnd")
  if spellsShown.frost then
    spellsShown.frost.til = GetTime()
  end
  for _, ball in ipairs(spellsShown.frozen) do
    burst("shard", ball.x, ball.y, BALL_HEIGHT, 10, 7, 220, 0.6, ICE)
    ringOut("ring", ball.x, ball.y, 12, 70, 0.3, ICE)
  end
  spellsShown.frozen = {}
end
function CUES.shieldWall()
  play("shieldWall")
  local now = GetTime()
  local post = game.named.centerPost
  spellsShown.shield = { from = now, ends = now + tune.wallSeconds }
  shieldOver(post)
  ringOut("ring", post.x1, post.y1, 6, 110, 0.5, GOLD)
  burst("spark", post.x1, post.y1, 20, 10, 8, 160, 0.5, GOLD)
  flashers({ "flashLeft", "flashRight" }, 8, 0.6, 7)
  lights:Play(Shows.Flash({ "shootAgain", "leftInlane", "rightInlane" }, 10), now, 0.8, 6)
  if spellBar.wall then
    spellBar.wall.castAt = now
  end
  message(1.8, 4, function(t)
    local lit = t > 0.6 or (t * 8) % 2 < 1.4
    display:Bitmap(ICONS.shield, 1, 2, 1)
    display:Bitmap(ICONS.shield, 118, 2, 1)
    if lit then
      display:Text("SHIELD UP", 64, 2, "big", "center")
    end
    display:Text(("POST UP %d SECONDS"):format(tune.wallSeconds), 64, 23, "small", "center")
  end)
end
function CUES.shieldBlock()
  play("shieldBlock")
  local post = game.named.centerPost
  if spellsShown.shield then
    spellsShown.shield.struck = GetTime()
  end
  burst("spark", post.x1, post.y1, 22, 8, 7, 200, 0.4, GOLD)
  ringOut("ring", post.x1, post.y1, 8, 60, 0.3, GOLD)
  headline("BLOCKED", "SHIELD WALL", 0.9, 2, true)
end
function CUES.shieldDown()
  play("postDown")
  if spellsShown.shield then
    spellsShown.shield.til = GetTime()
  end
end

local cueQueue = {}

-- What the rules say goes into a queue, and is shown and heard in the frame. A game being played
-- again is heard too; one the robot plays for measuring is quieter: lights and the display only
ns.Cue = function(what, ...)
  cueQueue[#cueQueue + 1] = { what, ... }
end

local function runCues()
  muted = game.keep and not view.measuringShows
  for index = 1, #cueQueue do
    local cue = cueQueue[index]
    cueQueue[index] = nil
    local answer = CUES[cue[1]]
    if answer and lights then
      answer(unpack(cue, 2))
    end
  end
end

-----------------------------
-- Making ready to draw
-----------------------------
--- The textures for what is drawn, made once
local function makeTextures()
  view.made = true
  makeLayers()
  local tilt = ns.Art.tilt
  for _, paddle in ipairs(game.world.paddles) do
    view.flippers[paddle.name] = { picture = board:CreateTexture(nil, "ARTWORK", nil, 2) }
  end
  view.post = board:CreateTexture(nil, "ARTWORK", nil, 1)
  view.plunger = board:CreateTexture(nil, "ARTWORK", nil, 1)
  view.spinner = board:CreateTexture(nil, "ARTWORK", nil, 3)
  view.targets = {}
  for index = 1, 3 do
    view.targets[index] = board:CreateTexture(nil, "ARTWORK", nil, 1)
  end
  for _, lamp in ipairs(ns.Table.lamps) do
    local insert = board:CreateTexture(nil, "BORDER", nil, 1)
    insert:SetBlendMode("ADD")
    view.lamps[lamp.name] = { insert = insert, lamp = lamp }
  end
  view.bumpers = {}
  for _, shape in ipairs(ns.Table.shapes) do
    if shape.role == "bumper" then
      local lit = layers.flashes:CreateTexture(nil, "ARTWORK", nil, 4)
      lit:SetBlendMode("ADD")
      view.bumpers[shape.name] = { texture = lit, shape = shape }
    end
  end
  view.flashers = {}
  for name in pairs(tilt.flashers) do
    local texture = layers.flashes:CreateTexture(nil, "ARTWORK", nil, 0)
    texture:SetBlendMode("ADD")
    view.flashers[name] = { texture = texture }
  end
  view.overTiles = {}
end

--- Gets the pictures ready for the machine at the size the screen has room for: all of it, or
--- closer in, the backbox cut off above its display
local function layout()
  local art = ns.Art
  local tilt = art.tilt
  if not view.made then
    makeTextures()
  end
  local c, file = tilt.crop, tilt.files[tilt.background]
  local left, top, right, bottom = c[1], c[2], c[3], c[4]
  local d = tilt.dmd
  local room = view.room
  local close = view.mode == "close" or (view.mode == "auto" and room.height < CLOSE_BELOW)
  if close then
    top = max(top, d[2] - (d[4] - d[2]) * 0.35)
  end
  view.left, view.top = left, top
  view.scale = room.height / (bottom - top)
  if room.width then
    view.scale = min(view.scale, (room.width - PANEL) / (right - left))
  end
  local width, height = (right - left) * view.scale, (bottom - top) * view.scale
  view.used = width + PANEL
  playfield:SetTexture(IMAGES .. tilt.background)
  playfield:SetTexCoord(left / file.w, right / file.w, top / file.h, bottom / file.h)
  playfield:SetSize(width, height)
  -- What stands over a ball at each height, in tiles, only where there is something
  for k, band in ipairs(tilt.over) do
    view.overTiles[k] = view.overTiles[k] or {}
    for index, tile in ipairs(band.tiles) do
      local texture = view.overTiles[k][index] or layers.bands[k]:CreateTexture(nil, "ARTWORK")
      view.overTiles[k][index] = texture
      placed(texture, tile)
    end
  end
  board:SetSize(width, height)
  board:ClearAllPoints()
  -- In the middle of the room, the panel beside it on the right
  local spare = room.width and max(0, room.width - view.used) or 0
  board:SetPoint("TOPLEFT", view.parent, "TOPLEFT", floor(spare / 2), -floor(max(0, room.height - height) / 2))
  panel:ClearAllPoints()
  panel:SetPoint("TOPLEFT", board, "TOPRIGHT", 0, 0)
  panel:SetSize(PANEL, height)

  -- The display in the backbox, as big as fits its glass, a dot of it square, in its middle
  local dot = min((d[3] - d[1]) / display.columns, (d[4] - d[2]) / display.rows) * view.scale
  display:SetDot(dot)
  display.frame:ClearAllPoints()
  display.frame:SetPoint("CENTER", board, "TOPLEFT", ((d[1] + d[3]) / 2 - left) * view.scale,
    -((d[2] + d[4]) / 2 - top) * view.scale)
  view.showWires = view.wantWires

  -- What is lit: each lamp's light was drawn whole, its colour, its glow and what it lights round it
  for name, lamp in pairs(view.lamps) do
    local p = tilt.lamps[name]
    if p then
      placed(lamp.insert, p)
    end
    lamp.insert:SetShown(p ~= nil)
  end
  for name, bumper in pairs(view.bumpers) do
    placed(bumper.texture, tilt.bumpers[name])
  end
  for name, flash in pairs(view.flashers) do
    placed(flash.texture, tilt.flashers[name])
  end
  for index = 1, 3 do
    placed(view.targets[index], tilt.targets["target" .. index])
  end
  drawWires()
end

local function slotTextures(made, slot)
  local set = made.slots[slot]
  if not set then
    local parent = slot == 0 and board or layers.slots[slot]
    set = { shadow = parent:CreateTexture(nil, "ARTWORK", nil, 5), ball = parent:CreateTexture(nil, "ARTWORK", nil, 6) }
    local tilt = ns.Art.tilt
    for texture, s in pairs({ [set.ball] = tilt.ball, [set.shadow] = tilt.shadow }) do
      local file = tilt.files[s.file]
      texture:SetTexture(IMAGES .. s.file)
      texture:SetTexCoord(s.x / file.w, (s.x + s.w) / file.w, s.y / file.h, (s.y + s.h) / file.h)
    end
    made.slots[slot] = set
  end
  return set
end

local function getBall(index)
  local made = view.balls[index]
  if not made then
    made = { slots = {} }
    -- A ball on a wire throws its shadow down on the playfield, under everything; one Frost Nova
    -- holds is in a block of ice
    local tilt = ns.Art.tilt
    local file = tilt.files[tilt.shadow.file]
    made.ground = board:CreateTexture(nil, "ARTWORK", nil, 4)
    made.ground:SetTexture(IMAGES .. tilt.shadow.file)
    made.ground:SetTexCoord(tilt.shadow.x / file.w, (tilt.shadow.x + tilt.shadow.w) / file.w, tilt.shadow.y / file.h,
      (tilt.shadow.y + tilt.shadow.h) / file.h)
    made.ice = board:CreateTexture(nil, "ARTWORK", nil, 7)
    made.ice:SetTexture(FX .. "ice")
    view.balls[index] = made
  end
  return made
end

local function hideBall(made)
  for _, set in pairs(made.slots) do
    set.ball:Hide()
    set.shadow:Hide()
  end
  made.ground:Hide()
  made.ice:Hide()
end

local function drawBall(made, ball, now)
  local tilt, k = ns.Art.tilt, view.scale
  local floorHeight = ballFloor(ball)
  local slot = slotFor(floorHeight + 2 * BALL_HEIGHT - 1)
  for other, set in pairs(made.slots) do
    if other ~= slot then
      set.ball:Hide()
      set.shadow:Hide()
    end
  end
  local set = slotTextures(made, slot)
  local grow = ball.r * 2 / 27
  -- Each drawn as big as the ball is that far from the camera, its own point (ax, ay) over where
  -- it goes: the ball's middle, and the floor under it for the shadow
  local function put(texture, s, x, y, z)
    local px, py, _, _, w = project(x, y, z)
    local across = tilt.ballPx / w * k * grow * (s.mm / 27)
    local down = across * s.h / s.w
    texture:ClearAllPoints()
    texture:SetPoint("TOPLEFT", board, "TOPLEFT", px - s.ax / s.w * across, -(py - s.ay / s.h * down))
    texture:SetSize(across, down)
  end
  put(set.ball, tilt.ball, ball.x, ball.y, floorHeight + BALL_HEIGHT)
  set.ball:Show()
  if ball.rail and floorHeight > 1 then
    set.shadow:Hide()
    put(made.ground, tilt.shadow, ball.x, ball.y, 0)
    made.ground:SetAlpha(max(0.15, 0.6 - floorHeight / 300))
    made.ground:Show()
  else
    made.ground:Hide()
    put(set.shadow, tilt.shadow, ball.x, ball.y, floorHeight)
    set.shadow:Show()
  end
  if ball.held == Rules.FROZEN then
    local appear = spellsShown.frost and min(1, (now - spellsShown.frost.from) / 0.2) or 1
    standing(made.ice, ball.x, ball.y, BALL_HEIGHT, 2 * BALL_HEIGHT * 1.75 * (1.4 - 0.4 * appear))
    made.ice:SetAlpha(appear * (0.85 + 0.15 * sin(now * 9)))
    made.ice:Show()
  else
    made.ice:Hide()
  end
end

local function draw(elapsed)
  local world = game.world
  local tilt = ns.Art.tilt
  local now = GetTime()

  for _, paddle in ipairs(world.paddles) do
    local frames = tilt.flippers[paddle.name]
    if frames then
      placed(view.flippers[paddle.name].picture, nearest(frames.frames, "angle", paddle.angle))
    end
  end

  local index = 0
  for _, ball in ipairs(world.balls) do
    index = index + 1
    drawBall(getBall(index), ball, now)
  end
  for rest = index + 1, #view.balls do
    hideBall(view.balls[rest])
  end

  -- What rises and falls, and turns. The post comes up out of the playfield
  local post = game.named.centerPost
  view.post:SetShown(post.active)
  if post.active then
    local shown = spellsShown.shield
    local up = shown and min(1, (now - shown.from) / 0.12) or 1
    placed(view.post, tilt.post, 0, (1 - up) * 10 * view.scale)
    view.post:SetAlpha(up)
  end
  for i = 1, 3 do
    view.targets[i]:SetShown(game.named["target" .. i].active)
  end
  placed(view.plunger, nearest(tilt.plunger.frames, "pull", Rules.Pulled(game)))
  -- The spinner turns down to still, half a turn for every spin the rules counted
  if game.spinTo > game.spun then
    local step = min(game.spinTo - game.spun, elapsed * max(8, (game.spinTo - game.spun) * 3))
    game.spun = game.spun + step
  end
  placed(view.spinner, nearest(tilt.spinner.frames, "angle", game.spun % pi))

  -- The lamps, the bumpers' caps, the flashers and the table's own light
  if not game.keep or view.measuringShows then
    lightsFromGame()
  end
  for name, lamp in pairs(view.lamps) do
    lamp.insert:SetAlpha(lights:Glow(name, now, elapsed))
  end
  for name, bumper in pairs(view.bumpers) do
    bumper.texture:SetAlpha(lights:Glow(name, now, elapsed))
  end
  for name, flash in pairs(view.flashers) do
    flash.texture:SetAlpha(lights:Glow(name, now, elapsed))
  end
  lights:Tidy(now)
  if gi.until_ and now >= gi.until_ then
    gi.target, gi.until_ = 1, nil
  end
  gi.level = gi.level + (gi.target - gi.level) * min(1, elapsed / (gi.rate or 0.08))
  shade:SetAlpha((1 - gi.level) * GI_DIM)
  if not spellsShown.frost or (spellsShown.frost.til and now > spellsShown.frost.til + 0.5) then
    chill:SetAlpha(0)
  end

  runEffects(now)
  drawSpellBar(now)
  drawDisplay()
end

-----------------------------
-----------------------------
-- High scores
-----------------------------
--- Whether a score is good enough for the high scores of a machine that keeps its own
local function qualifies(score)
  local list = highScores()
  return options.highScores ~= nil and (#list < HIGH_SCORES or score > list[#list].score)
end

--- Starts entering the initials for a new high score
local function beginEntry(score)
  view.entry = { score = score, letters = { 1, 1, 1 }, at = 1 }
  play("fanfare")
  flashers(ALL_FLASHERS, 10, 1.5, 7)
  lights:Play(Shows.Sparkle(2, 9, lampNames()), GetTime(), 3, 5)
end

local function keyForEntry(action)
  local entry = view.entry
  if entry.done then
    return
  end
  if action == "left" or action == "right" then
    local letter = entry.letters[entry.at] + (action == "left" and -1 or 1)
    entry.letters[entry.at] = (letter - 1) % #LETTERS + 1
    play("letter")
  elseif action == "plunger" or action == "start" then
    play("letterChosen")
    if entry.at < 3 then
      entry.at = entry.at + 1
      entry.letters[entry.at] = entry.letters[entry.at - 1]
      return
    end
    local name = ""
    for index = 1, 3 do
      name = name .. LETTERS:sub(entry.letters[index], entry.letters[index])
    end
    local list = highScores()
    table.insert(list, { name = name, score = entry.score })
    table.sort(list, function(a, b)
      return a.score > b.score
    end)
    while #list > HIGH_SCORES do
      table.remove(list)
    end
    entry.done, entry.doneAt = true, GetTime()
    play("questComplete")
    flashers(ALL_FLASHERS, 8, 1)
  end
end

-----------------------------
-- Running
-----------------------------
--- While the machine waits: a tune from its speakers every so often, and its lights going with it
local function waiting(now)
  if now < (view.nextCall or 0) then
    return
  end
  view.calls = (view.calls or 0) + 1
  view.nextCall = now + CALL_EVERY
  play(view.calls % 2 == 1 and "attract1" or "attract2")
  flashers(ALL_FLASHERS, 6, 2.2, 6)
  lights:Play(Shows.Chase(lampNames(), 26, 3), now, 2.2, 5)
  -- The display shows the table's name, as the tune plays
  view.idleSince = now
end

--- Puts away what the spells were showing
local function clearEffects()
  local now = GetTime()
  for _, e in ipairs(effects) do
    e.from = now - e.seconds
  end
  runEffects(now)
  spellsShown.frost, spellsShown.frozen, spellsShown.shield = nil, {}, nil
  chill:SetAlpha(0)
end

--- Makes the machine inside a frame, the first time it is asked for. `with` is what it needs
--- from whoever uses it (see the top of this file)
--- @param parent Frame
--- @param with table
function Machine.New(parent, with)
  options, tune = with, with.tune
  if board then
    return Machine
  end
  DotMatrix = ns.DotMatrix
  view.parent = parent
  board = CreateFrame("Frame", nil, parent)
  board:SetClipsChildren(true)
  playfield = board:CreateTexture(nil, "BACKGROUND", nil, -7)
  playfield:SetPoint("TOPLEFT")
  -- The table's own lights dimmed, darkening everything under the lamps
  shade = board:CreateTexture(nil, "BACKGROUND", nil, -6)
  shade:SetAllPoints()
  shade:SetColorTexture(0, 0, 0, 1)
  shade:SetAlpha(0)
  -- The table's light turned icy by Frost Nova
  chill = board:CreateTexture(nil, "BACKGROUND", nil, -5)
  chill:SetAllPoints()
  chill:SetColorTexture(0.25, 0.5, 1, 1)
  chill:SetBlendMode("ADD")
  chill:SetAlpha(0)
  -- The display's letters are the engine's own, unless whoever uses the machine has them elsewhere
  display = DotMatrix.New(board, { images = options.dotImages })
  -- The panel beside the machine: the spells, and the keys
  panel = CreateFrame("Frame", nil, parent)
  helpText = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  helpText:SetPoint("BOTTOM", 0, 14)
  helpText:SetWidth(PANEL - 30)
  helpText:SetJustifyH("LEFT")
  helpText:SetText(L("pinball_keys"))
  Machine.panel, Machine.helpText = panel, helpText
  makeSpellBar()
  return Machine
end

--- Sets the keys shown under the spells
--- @param text string
function Machine.Help(text)
  helpText:SetText(text)
end

--- Fits the machine into this much room in its frame, the panel beside it: as tall as `height`,
--- and no wider than `width` if that is said. How wide it came to
--- @param width number?
--- @param height number
--- @return number
function Machine.Layout(width, height)
  view.room = { width = width, height = height }
  if game then
    layout()
  end
  return view.used or 0
end

--- Whether the machine is shown whole or closer in: "auto", "cabinet" or "close"
--- @param mode string
function Machine.SetView(mode)
  view.mode = mode
  if game then
    layout()
  end
end

--- The game on the machine
--- @return table?
function Machine.Game()
  return game
end

--- Starts a game on the machine (Rules.NewGame's options), or with `idle` the machine waiting to
--- be played: its lights running through their shows and the display through the high scores
--- @param with table
function Machine.Start(with)
  if not (ns.Art and ns.Art.tilt) then
    return false
  end
  cueQueue = {}
  messages = {}
  view.overAt, view.entry = nil, nil
  game = Rules.NewGame(tune, with)
  game.frames, game.physicsMs, game.drawMs, game.ticks = {}, {}, {}, 0
  game.spun, game.spinTo = 0, 0
  game.match = with.match
  if with.baseline then
    game.frozen = true
  end
  if with.replaying then
    game.replayAt = 1
  end
  if not lights then
    makeLights()
  end
  lights:StopAll()
  lights:Clear()
  gi.level, gi.target, gi.until_, gi.rate = 1, 1, nil, nil
  if view.room then
    layout()
  end
  clearEffects()
  local now = GetTime()
  if with.idle then
    lights:Play(attractShow(), now, nil, 0)
    view.idleSince = now
    view.nextCall = now + FIRST_CALL
    if with.over then
      -- The game that was played here is over: its score first
      view.lastScore = with.over
      headline("GAME OVER", commas(with.over), 4, 3)
    end
    if not view.poweredOn then
      -- Switched on: dark, the relays clattering, then the lights coming up
      view.poweredOn = true
      play("powerOn")
      gi.level, gi.rate = 0, 0.5
      lights:Play(Shows.Dark(), now, 0.7, 9)
      lights:Play(Shows.Sweep(lights.lamps, "up", 0.8, 120, lampNames()), now + 0.7, 0.9, 8)
    end
  elseif not with.keep and not with.replaying then
    if not view.hinted then
      view.hintAt = now + 2.7
    end
    play("gameStart")
    headline("BALL 1", "PULL THE PLUNGER", 2.5, 2, true)
    flashers(ALL_FLASHERS, 8, 0.8, 7)
    lights:Play(Shows.Sweep(lights.lamps, "up", 0.6, 100, lampNames()), now, 0.7, 4)
  elseif with.replaying then
    headline("REPLAY", "THE LAST GAME", 2, 2)
  end
  view.poweredOn = true
  return true
end

--- Shows a message on the display for a while
--- @param big string
--- @param small string?
--- @param seconds_ number?
function Machine.Headline(big, small, seconds_)
  headline(big, small, seconds_ or 3, 5)
end

--- Moves the machine on by `elapsed` seconds: the ball by the physics, and everything shown. How
--- long each took, in ms, and how many ticks the physics moved on, for measuring
--- @param elapsed number
--- @return number physicsMs, number drawMs, integer ticks
function Machine.Tick(elapsed)
  if not game then
    return 0, 0, 0
  end
  local now = GetTime()
  local began = debugprofilestop()
  local ticks = 0
  if not game.frozen then
    ticks = game.world:Advance(min(elapsed, 0.1), Rules.BeforeTick, seconds(0.1))
  end
  local physicsMs = debugprofilestop() - began
  began = debugprofilestop()
  runCues()
  draw(elapsed)
  local drawMs = debugprofilestop() - began
  if view.hintAt and now >= view.hintAt then
    view.hintAt, view.hinted = nil, true
    if not game.over then
      scroller("1 FROST NOVA   2 SHIELD WALL", "YOUR SPELLS", 4.5, 1)
    end
  end
  if game.idle then
    waiting(now)
  elseif game.over and not game.keep and not game.robot and not game.wasReplay and view.overAt then
    if not game.told then
      game.told = true
      if options.onOver then
        options.onOver(game)
      end
    end
    -- The game over: the initials of a high score, then back to waiting
    if view.entry then
      if view.entry.done and now - view.entry.doneAt > 2.5 then
        view.entry = nil
        Machine.Start({ idle = true })
      end
    elseif now - view.overAt > GAME_OVER_SECONDS then
      if qualifies(game.score) then
        beginEntry(game.score)
      else
        Machine.Start({ idle = true, over = options.highScores and nil or game.score })
      end
    end
  end
  return physicsMs, drawMs, ticks
end

local held = {}

--- A key pressed: whether the machine took it. Keys it doesn't know are left to whoever uses it
--- @param key string
--- @param action string? What the key is for, if whoever uses it knows better than KEYS
--- @return boolean
function Machine.KeyDown(key, action)
  action = action or KEYS[key]
  if not game or not action then
    return false
  end
  if held[key] then
    return true
  end
  held[key] = true
  if action == "view" then
    local close = view.mode == "close" or (view.mode == "auto" and view.room.height < CLOSE_BELOW)
    Machine.SetView(close and "cabinet" or "close")
    if options.onView then
      options.onView(view.mode)
    end
  elseif view.entry then
    keyForEntry(action)
  elseif action == "start" then
    if options.canStart then
      Machine.Start({})
    else
      return false
    end
  elseif game.idle and (action == "left" or action == "right") then
    -- The flippers work while the machine waits, as a real one's do
    table.insert(game.queue, action .. "Down")
  elseif game.replaying or game.robot or game.over then
    return action ~= "start"
  elseif action == "left" or action == "right" or action == "plunger" then
    table.insert(game.queue, action .. "Down")
  else
    table.insert(game.queue, action)
  end
  return true
end

--- A key let go
--- @param key string
--- @param action string?
function Machine.KeyUp(key, action)
  held[key] = nil
  action = action or KEYS[key]
  if game and not game.replaying and not game.robot and (action == "left" or action == "right" or action == "plunger") then
    -- Only let go when no other key for it is still down
    for other, otherAction in pairs(KEYS) do
      if otherAction == action and held[other] then
        return
      end
    end
    table.insert(game.queue, action .. "Up")
  end
end

--- Lets go of every key, as when the machine is hidden
function Machine.LetGo()
  for key in pairs(held) do
    Machine.KeyUp(key)
  end
  held = {}
end

--- Shows what the ball meets over the pictures, or stops
--- @param shown boolean
function Machine.ShowWalls(shown)
  view.wantWires = shown
  if game then
    layout()
  end
end

--- For the bench's measuring: whether the lights and the display are worked out for a game the
--- robot plays, and plays the attract show over them
--- @param shown boolean
function Machine.MeasureShows(shown)
  view.measuringShows = shown
  if shown and lights then
    lights:Play(attractShow(), GetTime(), nil, 0)
  end
end

--- Whether a game's moves came out exactly the same as the game they were taken from, said on the
--- display
--- @param same boolean
function Machine.Replayed(same)
  headline(same and "REPLAY EXACT" or "REPLAY DIFFERS", nil, 3, 5)
end
