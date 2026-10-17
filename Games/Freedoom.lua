--------------------------
--  Freedoom
--------------------------
-- The first episode of Freedoom (freedoom.github.io), a Doom made free to share, and Run, a map of
-- the addon's own that is one way through with no turnings (Tools/make_run.py): whichever map is
-- picked (the "map" option), on whichever of Doom's skills (the "skill" option), fight through it
-- to the exit, in the best time you can. It is the sector maps of the engine (Engine/SectorMap.lua) seen
-- through its view of them (GUI/SectorView.lua), and what this game adds is Doom's: how the
-- player walks, what the lines of a Doom map do when they are used or walked over (SPECIALS):
-- doors, lifts, a floor that lowers and the switch that ends the map, what can be picked up and
-- what that gives (PICKUPS), keys and the doors they open (LOCKS), the monsters and barrels and
-- how they live (MONSTERS, Engine/Actors.lua), the player's weapons (GUNS), and Doom's status bar.
--
-- The game has turns like any other as far as the engine knows, and two moves: "x", the player
-- got out, and "d", they died. Everything on the way is the view's business and happens many
-- times a second, so a game left and loaded again begins at the start, the doors shut.
--
-- It is in three parts: this one, the rules and the view; what the player carries
-- (Games/Freedoom/Carry.lua); and the world they play in, its doors and lifts, monsters and
-- weapons (Games/Freedoom/World.lua).
--
-- The maps and their pictures are made from Freedoom's freedoom1.wad by Tools/import_freedoom.sh,
-- under Freedoom's licence (ForeverGames_Freedoom/COPYING.txt), into an addon of their own that is
-- loaded the first time a game of Freedoom is shown (MAPS_ADDON). What a game needs to be played
-- by the rules, which map it is, is here: the maps are only for the view.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
-- The other parts of the game: what the player carries (Games/Freedoom/Carry.lua) and the world
-- they play in (Games/Freedoom/World.lua)
local Freedoom = private.Freedoom
local WEAPONS, newInventory, pickUp = Freedoom.WEAPONS, Freedoom.newInventory, Freedoom.pickUp
local GUNS, MONSTERS, HEIGHT, RADIUS = Freedoom.GUNS, Freedoom.MONSTERS, Freedoom.HEIGHT, Freedoom.RADIUS
local TWO_PI, EIGHTH, MOST_BOB, WEAPON_TOP = Freedoom.TWO_PI, Freedoom.EIGHTH, Freedoom.MOST_BOB, Freedoom.WEAPON_TOP
local damage, trigger, populate = Freedoom.damage, Freedoom.trigger, Freedoom.populate
local liveTic, gunTic, gunAct = Freedoom.liveTic, Freedoom.gunTic, Freedoom.gunAct

-- The maps there are to pick from, Run first and then the first episode's, and the addon they are in
local LEVELS = { "run", "e1m1", "e1m2", "e1m3", "e1m4", "e1m5", "e1m6", "e1m7", "e1m8", "e1m9" }
local MAPS_ADDON = "ForeverGames_Freedoom"
local EXIT, DEAD = "x", "d"
-- Doom's skills, the easiest first, and which of the things of a map are there on each (Doom's
-- thing flags: the two easiest, the middle one, the hardest). On the easiest the player also takes
-- half of every blow and gets twice the ammunition, as in Doom. Best times are kept for each skill,
-- the middle one's under the map alone, as they were before there were skills to pick
local SKILLS = { "baby", "easy", "medium", "hard" }
local SKILL_FLAGS = { baby = 1, easy = 1, medium = 2, hard = 4 }
local USUAL_SKILL = "medium"

--- @class FreedoomState
--- @field level string Which map, "run" or "e1m1" to "e1m9"
--- @field skill string One of SKILLS
--- @field map string The sector map's id
--- @field out boolean The player got to the exit
--- @field dead boolean? They didn't

--- @return FreedoomState
local function newState(_, _, rules)
  local level = rules and rules.map or LEVELS[1]
  local skill = rules and SKILL_FLAGS[rules.skill] and rules.skill or USUAL_SKILL
  return { level = level, skill = skill, map = "freedoom_" .. level, out = false }
end

--- What a map's best time (and the run that set it) is kept under: the map, and the skill
--- unless it is the middle one
--- @param state FreedoomState
--- @return string
local function recordKey(state)
  local level = state.level or LEVELS[1]
  if state.skill and state.skill ~= USUAL_SKILL then
    return level .. "_" .. state.skill
  end
  return level
end

local function validate(state, seat, move)
  if seat ~= 1 then
    return false, "not_your_turn"
  elseif state.out or state.dead or (move ~= EXIT and move ~= DEAD) then
    return false, "invalid_move"
  end
  return true
end

local function apply(state, _, move)
  if move == EXIT then
    state.out = true
  else
    state.dead = true
  end
  return { out = state.out }
end

local function moves(state)
  if state.out or state.dead then
    return {}
  end
  return { EXIT, DEAD }
end

local function result(state)
  if state.out then
    return { winner = 1 }
  end
  return state.dead and { winner = 0 } or nil
end

-----------------------------
-- View
-----------------------------
-- The screen is Doom's, 320 by 200 shown at 4 by 3 in the middle of the room there is: the view
-- above, 168 rows of it, and the status bar under it, with a line under that saying how to play.
-- Tab shows what drawing it costs, F5 switches between Doom's detail and low detail, which draws
-- half as many columns. While it is shown, what it says goes into the log every few seconds too
-- (private.Log, which is saved): the frames of that while on average and the worst of them, and
-- where the player was standing for that one, to draw the same again outside the game.
--
-- The view is only drawn again when something in it changed: the player moved or turned, a door
-- or lift moved, a thing came, went or showed another frame, a picture on a wall or floor moved
-- on (SectorMap.version). Standing still costs next to nothing. Messages are written at the top
-- of the view in Doom's font, and a pickup flashes the view gold and a blow red, as Doom's palette
-- did. The world lives 35 tics a second, whatever the frame rate; the player walks every frame.

local Widgets
-- Units a second walking and running, how fast the player turns, how far they reach to use
-- something, how fast they fall, and where the eye is, alive and dead
local WALK, RUN, TURN, REACH, FALL = 290, 580, 3.2, 64, 600
local EYE, DEAD_EYE = 41, 6
-- With the right mouse button held the mouse turns the player: radians for every pixel across
local MOUSE_TURN = 0.006
-- How many tics the screen shows the player dead before the game is over. Reaching the exit ends it
-- there and then: the clock stops at the exit
local DEAD_PAUSE = 70
local MARGIN, HINT_HEIGHT = 12, 22
local ASPECT = 4 / 3
local STATS_EVERY, LOG_EVERY = 0.25, 2
-- The view's textures are made ahead of time, this many a frame until there are this many
local RESERVE, RESERVE_A_FRAME = 3500, 250
-- The things of the map that are there only with others, and where a teleport lands
local MULTIPLAYER, TELEPORT_LANDING = 16, 14
-- What the floor of a sector does to whoever stands on it, by its special, every so many tics,
-- unless they wear the suit, for so long
local HURTING_FLOORS = { [4] = 20, [5] = 10, [7] = 5, [16] = 20 }
local HURT_EVERY, SUIT, SUIT_TICS = 32, 2025, 60 * 35
-- A thing is reached from this far below the player's feet, and up to as high as they are tall
local REACH_DOWN = 8
-- A tic, and how many the world may be behind before it skips ahead rather than catch up
local TIC, MOST_TICS = 1 / 35, 4

-- Doom's screen: how tall the view is over the status bar, and where everything on the bar is
local SCREEN_WIDTH, SCREEN_HEIGHT, VIEW_HEIGHT = 320, 200, 168
local BAR = {
  ammo = { 44, 171 }, health = { 90, 171 }, armor = { 221, 171 },
  arms = { 104, 168 }, slots = { 111, 172, 12, 10 }, face = { 143, 168 },
  keys = { 239, 171, 10 },
  -- The small counts of every kind of ammunition, what there is and the most there can be
  counts = { 288, 314, bullets = 173, shells = 179, rockets = 185, cells = 191 },
}
-- Messages last this long, the face looks about every so often, and grins, says ouch, looks
-- at whoever hurt it or grits its teeth for so many tics
local MESSAGE_TIME, LOOK_TIME = 4, 0.5
local GRIN_TICS, PAIN_TICS, RAMPAGE_TICS = 70, 35, 70
-- The gold of a pickup and the red of a blow, as much as there is at most of each, and how long a pickup's lasts
local GOLD, RED = { 1, 0.85, 0.35 }, { 1, 0, 0 }
local GOLD_ALPHA, RED_ALPHA, BONUS_TICS = 0.22, 0.6, 6
-- Doom's font has only these: the space between words is this wide
local FONT_FIRST, FONT_LAST, SPACE_WIDTH = 33, 95, 4
local HUD_PICTURES = "freedoom_hud"

-- Doom's sounds, in the maps' addon: each three times over, as loud as it is heard close by, a way
-- off and far off, and how far each of those reaches (the client can't make one quieter, so how far
-- away something is heard is which of them is played). Beyond the last nothing is heard. What
-- is picked up says so one of three ways: a weapon, a power, anything else
local SOUND = {
  folder = "Interface\\AddOns\\ForeverGames_Freedoom\\Sounds\\",
  reach = { 450, 850, 1200 },
  weapons = { [2001] = true, [82] = true, [2002] = true, [2003] = true, [2004] = true, [2005] = true, [2006] = true },
  powers = { [2013] = true, [83] = true, [2022] = true, [2023] = true, [2024] = true, [2025] = true, [2026] = true, [2045] = true },
  -- The finish screen's counting goes off every so many tics
  count = 4,
}

-- A race's ghost: the rival's run, shown as they played it, a see-through marine with their
-- name over its head. A sample of where the player is is taken every so often, and is five
-- letters (of the 64 a race lets a sample have): where across and up the map, to the nearest so
-- many units, two letters each, and which of 32 ways they face with whether they are firing in
-- the fifth. A ghost of the samples Engine/Race.lua keeps covers a run of five minutes and more
local GHOST = {
  every = 0.5, grid = 8, offset = 2048, ways = 32,
  letters = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_",
  -- How it looks, how far a sample may be from the next before it is a teleport rather than a
  -- walk, and how long it takes to fade once the run it is of is over (and to fall, if it died)
  alpha = 0.55, tint = { 0.6, 0.85, 1 }, jump = 400, fade = 1.5, fall = 1.2,
  -- Its name: how big it is written near and far, and from how near it is as big as it gets
  near = 160, smallest = 0.6, largest = 1.2,
}
-- The screen a map is finished with, Doom's intermission (its wi_stuff.c): where everything on
-- it goes, how fast the counts go up (two percent a tic, three seconds of the time), the par
-- times (Doom's for the first episode's maps), the kinds of thing that count as items, and the
-- special of a sector that is a secret. And where the lines under it are written, in Doom's font,
-- and how much bigger the name of a map is written that has no picture of its name, as Run hasn't
local FINISH = {
  statsX = 50, statsY = 50, timeX = 16, timeY = 168, titleY = 2, titleScale = 2,
  percentStep = 2, timeStep = 3,
  pars = { run = 90, e1m1 = 30, e1m2 = 75, e1m3 = 120, e1m4 = 90, e1m5 = 165, e1m6 = 180, e1m7 = 180, e1m8 = 30, e1m9 = 165 },
  items = { [2014] = true, [2015] = true, [2013] = true, [83] = true, [2022] = true, [2023] = true, [2024] = true, [2026] = true, [2045] = true },
  secret = 9,
  notesY = 128, notesGap = 12,
}

local GHOST_DIGIT, preciseTime = {}, nil
for index = 1, #GHOST.letters do
  GHOST_DIGIT[GHOST.letters:sub(index, index)] = index - 1
end

--- A time to the hundredth of a second, the way races show them
--- @param seconds number
--- @return string
function preciseTime(seconds)
  local hundredths = math.floor(seconds * 100 + 0.5)
  return private.Widgets.Time(math.floor(hundredths / 100)) .. (".%02d"):format(hundredths % 100)
end

--- Where the player is, as a sample of a ghost
--- @return string
local function ghostSample(x, y, angle, firing)
  local letters = GHOST.letters
  local function letter(value)
    return letters:sub(value + 1, value + 1)
  end
  local function across(value)
    local at = math.max(0, math.min(4095, math.floor(value / GHOST.grid + 0.5) + GHOST.offset))
    return letter(math.floor(at / 64)) .. letter(at % 64)
  end
  local way = math.floor(angle / TWO_PI * GHOST.ways + 0.5) % GHOST.ways
  return across(x) .. across(y) .. letter(way * 2 + (firing and 1 or 0))
end

--- And back
--- @return table? place { x, y, angle, firing }, nil for a sample that doesn't read right
local function ghostPlace(sample)
  if type(sample) ~= "string" or #sample ~= 5 then
    return nil
  end
  local digits = {}
  for index = 1, 5 do
    digits[index] = GHOST_DIGIT[sample:sub(index, index)]
    if not digits[index] then
      return nil
    end
  end
  local function across(high, low)
    return ((high * 64 + low) - GHOST.offset) * GHOST.grid
  end
  return { x = across(digits[1], digits[2]), y = across(digits[3], digits[4]), angle = math.floor(digits[5] / 2) / GHOST.ways * TWO_PI,
    firing = digits[5] % 2 == 1 }
end
Freedoom.GhostSample, Freedoom.GhostPlace = ghostSample, ghostPlace

-- Key: what it does to walking ahead, stepping right and turning left
local KEYS = {
  W = { 1, 0, 0 }, UP = { 1, 0, 0 },
  S = { -1, 0, 0 }, DOWN = { -1, 0, 0 },
  A = { 0, 0, 1 }, LEFT = { 0, 0, 1 },
  D = { 0, 0, -1 }, RIGHT = { 0, 0, -1 },
  Q = { 0, -1, 0 }, E = { 0, 1, 0 },
}
local FIRE = { LCTRL = true, RCTRL = true, CTRL = true, F = true }
-- The number keys and the weapons they change to, the first of them the player has
local SLOTS = { ["1"] = { "chainsaw", "fist" }, ["2"] = { "pistol" }, ["3"] = { "shotgun" }, ["4"] = { "chaingun" }, ["5"] = { "launcher" },
  ["6"] = { "plasma" }, ["7"] = { "bfg" } }
local USE, STATS, DETAIL = "SPACE", "TAB", "F5"

--- @class FreedoomView: GameViewObject
--- @field view GameView?
--- @field run FreedoomRun?
local View = {}
View.__index = View

--- Where a run begins: at the map's first player start, with whatever is lying about and lives
--- there where the map puts it
--- @param state FreedoomState
--- @return FreedoomRun
local function newRun(state)
  local Actors = private.Actors
  if not private.SectorMap.Has(state.map) then
    -- The maps are an addon of their own, loaded the first time one is wanted
    local load = C_AddOns and C_AddOns.LoadAddOn or LoadAddOn
    if load then
      pcall(load, MAPS_ADDON)
    end
    if not private.SectorMap.Has(state.map) then
      return nil
    end
  end
  local map = private.SectorMap.Load(state.map)
  local start
  local animated, here, totalItems, totalSecrets = {}, {}, 0, 0
  local kinds = map.data.kinds or {}
  local skill = SKILL_FLAGS[state.skill] or SKILL_FLAGS[USUAL_SKILL]
  for _, thing in ipairs(map.data.things) do
    if thing.type == 1 and not start then
      start = thing
    end
    local kind = kinds[thing.type]
    if kind and thing.flags % (skill * 2) >= skill and thing.flags % (MULTIPLAYER * 2) < MULTIPLAYER then
      if MONSTERS[thing.type] then
        here[#here + 1] = thing
      else
        local made = {
          x = thing.x, y = thing.y, angle = math.rad(thing.angle), radius = kind.radius, height = kind.height,
          solid = kind.solid, hanging = kind.hanging, kind = kind, type = thing.type,
          picture = kind.sprite .. kind.frames:sub(1, 1),
          bright = kind.bright == "*" or (kind.bright ~= "" and kind.bright:find(kind.frames:sub(1, 1), 1, true) ~= nil),
        }
        map:AddThing(made)
        if FINISH.items[thing.type] then
          totalItems = totalItems + 1
        end
        if #kind.frames > 1 and kind.tics > 0 then
          animated[#animated + 1] = made
        end
      end
    end
  end
  start = start or { x = 0, y = 0, angle = 0 }
  local player = { x = start.x, y = start.y, z = map:SectorAt(start.x, start.y).floor, angle = 0, radius = RADIUS, height = HEIGHT, solid = true,
    shootable = true }
  map:AddThing(player)
  map:Settle(player)
  local inventory = newInventory()
  local easiest = state.skill == SKILLS[1]
  inventory.ammoTimes = easiest and 2 or nil
  --- @type FreedoomRun
  for _, sector in ipairs(map.sectors) do
    if sector.special == FINISH.secret then
      totalSecrets = totalSecrets + 1
    end
  end
  local teleports = {}
  for _, thing in ipairs(map.data.things) do
    if thing.type == TELEPORT_LANDING then
      teleports[#teleports + 1] = { x = thing.x, y = thing.y, angle = math.rad(thing.angle), sector = map:SectorAt(thing.x, thing.y) }
    end
  end
  local run = {
    map = map, level = state.level, key = recordKey(state), halfDamage = easiest or nil, teleports = teleports, items = 0,
    totalItems = totalItems, secrets = 0, totalSecrets = totalSecrets,
    player = player, angle = math.rad(start.angle), inventory = inventory, animated = animated, actors = {}, tic = 0, time = 0,
    refire = 0, light = 0, gunY = WEAPON_TOP, gunMoving = 0, bonus = 0, hurt = 0, eye = EYE, bob = 0,
    shows = function()
      return false
    end,
  }
  run.gun = { sprite = GUNS.pistol.sprite, sequences = GUNS.pistol.sequences, run = run, act = gunAct }
  run.flash = { sprite = "PISF", sequences = GUNS.pistol.sequences, run = run, act = gunAct }
  Actors.Start(run.gun, "ready")
  populate(run, here)
  return run
end

--- @param stage Frame
--- @return FreedoomView
local function createView(stage)
  Widgets = private.Widgets
  local self = setmetatable({ stage = stage, runs = {}, down = {}, shown = 0, crossed = {}, touched = {}, look = 1, lookAt = 0,
    -- What each thing is saying right now, by the thing, the player's own included
    voices = setmetatable({}, { __mode = "k" }) }, View)

  self.border = Widgets.Panel(stage)
  self.box = CreateFrame("Frame", nil, stage)
  self.box:SetFrameLevel(self.border:GetFrameLevel() + 2)
  -- Clicks in the view are shots: they must not get through to the window and drag it about
  self.box:EnableMouse(true)
  self.screen = private.SectorView.New(self.box, { height = VIEW_HEIGHT })
  self.screen.frame:SetPoint("TOPLEFT")
  self.hud = private.Strips.New(self.box, { width = SCREEN_WIDTH, height = SCREEN_HEIGHT, filter = "NEAREST" })
  self.hud.frame:SetAllPoints()
  self.hud.frame:SetFrameLevel(self.screen.frame:GetFrameLevel() + 1)
  self.hint = stage:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  self.hint:SetText(L["freedoom_hint"])
  self.stats = self.hud.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  self.stats:SetPoint("TOPRIGHT", -6, -6)
  self.stats:SetJustifyH("RIGHT")
  self.stats:Hide()
  -- The name over a ghost's head, a frame of its own to be scaled with how near it is
  self.plate = CreateFrame("Frame", nil, self.hud.frame)
  self.plate:SetSize(1, 1)
  self.plate.name = self.plate:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  self.plate.name:SetPoint("BOTTOM")
  self.plate.name:SetTextColor(GHOST.tint[1], GHOST.tint[2], GHOST.tint[3])
  self.plate.name:SetShadowOffset(1, -1)
  self.plate:Hide()
  self.said = self.hud.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  self.said:SetPoint("CENTER", self.screen.frame, "CENTER")

  local ticker = CreateFrame("Frame", nil, stage)
  ticker:SetAllPoints()
  self.ticker = ticker
  Widgets.Keys(ticker, function(key)
    local run, view = self.run, self.view
    if not run or not view or not view.canMove or view.state.out or view.state.dead then
      return false
    end
    if key == USE then
      self:use()
    elseif key == STATS then
      self.stats:SetShown(not self.stats:IsShown())
    elseif key == DETAIL then
      self.screen:SetDetail(self.screen.detail == 1 and 2 or 1)
    elseif SLOTS[key] then
      self:choose(SLOTS[key])
    elseif KEYS[key] or FIRE[key] then
      self.down[key] = true
    else
      return false
    end
    return true
  end, true)
  ticker:SetScript("OnKeyUp", function(_, key)
    self.down[key] = nil
  end)
  ticker:SetScript("OnHide", function()
    self.down = {}
  end)
  ticker:SetScript("OnUpdate", function(_, elapsed)
    self:tick(math.min(elapsed, 0.1))
  end)
  return self
end

function View:Layout(width, height)
  local room = height - MARGIN * 3 - HINT_HEIGHT
  local wide = math.floor(math.min(width - MARGIN * 2, room * ASPECT))
  local tall = math.floor(wide / ASPECT)
  local left = math.floor((width - wide) / 2)
  self.border:SetSize(wide + 2, tall + 2)
  self.border:ClearAllPoints()
  self.border:SetPoint("TOPLEFT", self.stage, "TOPLEFT", left - 1, -(MARGIN - 1))
  self.box:SetSize(wide, tall)
  self.box:ClearAllPoints()
  self.box:SetPoint("TOPLEFT", self.stage, "TOPLEFT", left, -MARGIN)
  self.screen.frame:SetSize(wide, tall * VIEW_HEIGHT / SCREEN_HEIGHT)
  self.screen:Layout()
  self.hud:Layout()
  -- Everything is put where it goes again
  self.drawnAs = nil
  self.hint:ClearAllPoints()
  self.hint:SetPoint("TOP", self.box, "BOTTOM", 0, -MARGIN)
  self.hint:SetWidth(wide)
  self:draw()
end

function View:Update(view)
  self.view = view
  --- @type FreedoomState
  local state = view.state
  local id = view.match.id
  local run = self.runs[id]
  if not run then
    run = newRun(state)
    self.runs[id] = run
  end
  if not run then
    self.run = nil
    self.said:SetText(L["freedoom_missing"])
    return
  end
  if run ~= self.run then
    self.run = run
    self.down = {}
    self.drawnAs = nil
    self.screen:SetMap(run.map)
    local screen = self.screen
    run.shows = function(thing)
      return screen:Shows(thing)
    end
    run.sound = function(name, origin)
      self:sound(name, origin)
    end
    self.said:SetText("")
    self.message = nil
  end
  -- Getting out is shown by the screen a map is finished with, also one that was finished before
  -- it was looked at here (after a reload, or a best sent to race): its time without the counting
  if state.out and not run.finished then
    run.finished = { seconds = view.clock and view.clock() or 0, at = 0, recalled = true, banged = true }
  end
  self.said:SetText(state.dead and L["freedoom_dead"] or "")
  self.race = view.race
  self:raceGhost()
  self:draw()
end

--- The rival's ghost, once their run has arrived, in the map for as long as it lasts
function View:raceGhost()
  local run, race, view = self.run, self.race, self.view
  if run.finished or run.ghostOf == "race" then
    return
  end
  -- The rival's run once it has arrived, else the player's own best on the map
  local samples, name, of
  if race and race.ghost then
    samples, name, of = race.ghost, (race.rival or ""):match("^[^%-]+") or "", "race"
  elseif not run.ghostOf and view.ghost then
    samples, of = view.ghost(run.key), "best"
    local best = view.best and view.best(run.key)
    name = best and L["freedoom_ghost_best"]:format(preciseTime(best)) or ""
  end
  if not samples then
    return
  end
  if run.ghost then
    -- The rival's arrived while the player raced their own best: theirs it is
    run.map:RemoveThing(run.ghost)
    run.ghost, run.ghostTrail = nil, nil
  end
  local trail = {}
  for _, sample in ipairs(samples) do
    local place = ghostPlace(sample)
    if place then
      trail[#trail + 1] = place
    end
  end
  if #trail == 0 then
    return
  end
  run.ghostTrail, run.ghostOf = trail, of
  run.ghost = { x = trail[1].x, y = trail[1].y, angle = trail[1].angle, radius = RADIUS, height = HEIGHT, alpha = GHOST.alpha, tint = GHOST.tint,
    picture = "PLAYA", bright = true }
  run.map:AddThing(run.ghost)
  self.plate.name:SetText(name)
end

--- Where the ghost is now, on the race's clock: between two samples, walking, turning and
--- firing as the rival did. Once their run is over it stays where it ended, falls if they died
--- there, and fades away
function View:moveGhost()
  local run = self.run
  local ghost, trail = run.ghost, run.ghostTrail
  if not ghost then
    return
  end
  local seconds = self.view.clock and self.view.clock() or 0
  local at = seconds / GHOST.every + 1
  local index = math.floor(at)
  local x, y, angle, picture
  if index >= #trail then
    local last = trail[#trail]
    local over = seconds - (#trail - 1) * GHOST.every
    x, y, angle, picture = last.x, last.y, last.angle, "PLAYA"
    if run.ghostOf == "race" and self.race and self.race.theirs == false then
      -- Doom's player falling: seven frames, the last lying there
      local frame = math.min(7, math.floor(over / GHOST.fall * 7) + 1)
      picture = "PLAY" .. ("HIJKLMN"):sub(frame, frame)
    end
    ghost.alpha = GHOST.alpha * math.max(0, 1 - math.max(0, over - GHOST.fall) / GHOST.fade)
    if ghost.alpha <= 0 then
      run.map:RemoveThing(ghost)
      run.ghost = nil
      self.plate:Hide()
      return
    end
  else
    local from, to = trail[math.max(1, index)], trail[index + 1]
    local part = at - index
    if math.abs(to.x - from.x) + math.abs(to.y - from.y) > GHOST.jump then
      -- A teleport: there, not on the way
      part = part < 0.5 and 0 or 1
    end
    x, y = from.x + (to.x - from.x) * part, from.y + (to.y - from.y) * part
    angle = from.angle + ((to.angle - from.angle + math.pi) % TWO_PI - math.pi) * part
    if from.firing then
      picture = math.floor(seconds * 35 / 4) % 2 == 0 and "PLAYE" or "PLAYF"
    elseif to.x ~= from.x or to.y ~= from.y then
      local step = math.floor(seconds * 35 / 4) % 4 + 1
      picture = "PLAY" .. ("ABCD"):sub(step, step)
    else
      picture = "PLAYA"
    end
  end
  -- A ghost glows, whatever the light where it is
  ghost.angle, ghost.bright = angle % TWO_PI, true
  if ghost.picture ~= picture then
    ghost.picture = picture
    run.map:Changed()
  end
  if ghost.x ~= x or ghost.y ~= y then
    run.map:MoveThing(ghost, x, y)
  end
end

--- The ghost's name over its head, where it was last seen, written smaller the further it is
function View:placePlate()
  local ghost, plate, screen = self.run and self.run.ghost, self.plate, self.screen
  if not ghost or ghost.seenAt ~= screen.stamp or not ghost.seenDepth then
    plate:Hide()
    return
  end
  local frame = screen.frame
  local scale = math.max(GHOST.smallest, math.min(GHOST.largest, GHOST.near / ghost.seenDepth))
  plate:SetScale(scale)
  plate:ClearAllPoints()
  plate:SetPoint("BOTTOM", frame, "TOPLEFT", ghost.seenX * frame:GetWidth() / SCREEN_WIDTH / scale,
    (2 - ghost.seenTop * frame:GetHeight() / VIEW_HEIGHT) / scale)
  plate:SetAlpha(ghost.alpha / GHOST.alpha)
  plate:Show()
end

--- Says something at the top of the view for a while
--- @param text string
function View:say(text)
  self.message, self.messageUntil = text, (GetTime and GetTime() or 0) + MESSAGE_TIME
end

--- Plays one of Doom's sounds as it is heard from where the player is: loud close by, quieter
--- further off, not at all far away. Whatever said something before is cut short, as in Doom,
--- where everything has one voice. Only while the addon's sounds are on
--- @param name string
--- @param origin table? Where it is heard from, a thing or a point: the player's own if left out
function View:sound(name, origin)
  if not PlaySoundFile or (ForeverGames and ForeverGames.db and not ForeverGames.db.profile.sound) then
    return
  end
  local player = self.run.player
  local level = 1
  if origin and origin ~= player then
    local away = math.sqrt((origin.x - player.x) ^ 2 + (origin.y - player.y) ^ 2)
    level = nil
    for index, reach in ipairs(SOUND.reach) do
      if not level and away < reach then
        level = index
      end
    end
    if not level then
      return
    end
  end
  local voice = origin or player
  if self.voices[voice] and StopSound then
    StopSound(self.voices[voice])
  end
  local _, handle = PlaySoundFile(SOUND.folder .. name .. level .. ".ogg", "SFX")
  self.voices[voice] = handle
end

--- Whatever is in reach ahead, used: what doesn't open says so, a door that needs a key with a grunt
function View:use()
  local run = self.run
  if run.dead then
    return
  end
  local line, front = run.map:Trace(run.player.x, run.player.y, run.angle, REACH)
  if line and front then
    local done, colour = trigger(run, line, "use")
    if colour then
      self:say(L["freedoom_need_" .. colour])
      self:sound("oof")
    elseif not done then
      self:sound("noway")
    end
  elseif line then
    self:sound("noway")
  end
end

--- Changes to the first of some weapons the player has
--- @param names string[]
function View:choose(names)
  local inventory = self.run.inventory
  for _, name in ipairs(names) do
    if inventory.weapons[name] then
      if name ~= inventory.weapon then
        inventory.pending = name
      end
      return
    end
  end
end

--- Picks up whatever the player is standing on that can be
function View:pickUp()
  local run = self.run
  local map, player = run.map, run.player
  for _, thing in ipairs(map:Touching(player.x, player.y, player.radius, self.touched)) do
    local kind = thing.kind
    if kind and kind.pickup and thing.picture then
      local above = map:Bottom(thing) - player.z
      if above <= player.height and above >= -REACH_DOWN then
        local message, grin = pickUp(run.inventory, thing.type, thing.dropped)
        if message then
          map:RemoveThing(thing)
          thing.picture = nil
          self:say(L[message])
          self:sound(SOUND.weapons[thing.type] and "wpnup" or SOUND.powers[thing.type] and "getpow" or "itemup")
          run.bonus = BONUS_TICS
          if FINISH.items[thing.type] and not thing.dropped then
            run.items = run.items + 1
          end
          if thing.type == SUIT then
            run.suitUntil = run.tic + SUIT_TICS
          end
          if grin then
            run.grinUntil = run.tic + GRIN_TICS
          end
        end
      end
    end
  end
end

--- Walks, turns, lives the world's tics, moves the map along and draws it
--- @param elapsed number
function View:tick(elapsed)
  local run, view = self.run, self.view
  if not run or not view then
    return
  end
  -- A finished map stands still behind the screen that says how it went: nothing in it lives on
  -- to hurt the player who has left it
  if run.finished then
    self:draw()
    return
  end
  local map, player = run.map, run.player
  map:Tick(elapsed)

  local moving = false
  local playing = view.canMove and not view.state.out and not view.state.dead and not run.dead
  if playing then
    local ahead, aside, turn = 0, 0, 0
    local firing = IsMouseButtonDown ~= nil and IsMouseButtonDown("LeftButton") and self.box:IsMouseOver()
    for key in pairs(self.down) do
      -- A key that was let go of somewhere else is never heard of again
      if IsKeyDown and not IsKeyDown(key) then
        self.down[key] = nil
      elseif KEYS[key] then
        ahead, aside, turn = ahead + KEYS[key][1], aside + KEYS[key][2], turn + KEYS[key][3]
      elseif FIRE[key] then
        firing = true
      end
    end
    run.firing = firing
    run.firingSince = firing and (run.firingSince or run.tic) or nil
    if IsMouseButtonDown and IsMouseButtonDown("RightButton") then
      local across = GetCursorPosition() / self.screen.frame:GetEffectiveScale()
      run.angle = run.angle - (self.dragged and (across - self.dragged) * MOUSE_TURN or 0)
      self.dragged = across
      aside, turn = aside - turn, 0
    else
      self.dragged = nil
    end
    run.angle = (run.angle + turn * TURN * elapsed) % (math.pi * 2)
    player.angle = run.angle
    if ahead ~= 0 or aside ~= 0 then
      local speed = (IsShiftKeyDown and IsShiftKeyDown() and RUN or WALK) * elapsed
      local cos, sin = math.cos(run.angle), math.sin(run.angle)
      -- Right of the way the player faces is clockwise from it
      local dx, dy = (cos * ahead + sin * aside) * speed, (sin * ahead - cos * aside) * speed
      local crossed = self.crossed
      for index = #crossed, 1, -1 do
        crossed[index] = nil
      end
      local fromX, fromY = player.x, player.y
      moving = map:Slide(player, dx, dy, crossed)
      local behind = private.SectorMap.Behind
      for _, line in ipairs(crossed) do
        trigger(run, line, "walk", nil, not behind(line.x1, line.y1, line.dx, line.dy, fromX, fromY))
      end
    end
  else
    run.firing = false
  end
  map:Settle(player, FALL * elapsed)
  -- Where the player is, for the ghost of their run, and where the ghost they race is
  local sample = view.sample or (self.race and self.race.sample)
  if playing and sample then
    sample(ghostSample(player.x, player.y, run.angle, run.firing))
  end
  self:moveGhost()
  if not run.dead then
    self:pickUp()
  end
  -- The weapon and the eye bob while walking, and settle when standing
  run.bob = moving and math.min(MOST_BOB, run.bob + MOST_BOB * elapsed * 8) or math.max(0, run.bob - MOST_BOB * elapsed * 4)

  -- The world's tics
  run.time = run.time + elapsed
  local tics = 0
  while run.time >= TIC do
    run.time = run.time - TIC
    tics = tics + 1
    if tics <= MOST_TICS then
      self:worldTic()
    end
  end

  -- Things that are animated, on the map's clock
  local tic = map.clock * 35
  for _, thing in ipairs(run.animated) do
    if thing.picture then
      local kind = thing.kind
      local index = math.floor(tic / kind.tics) % #kind.frames + 1
      if index ~= thing.frame then
        thing.frame = index
        local letter = kind.frames:sub(index, index)
        thing.picture = kind.sprite .. letter
        thing.bright = kind.bright == "*" or (kind.bright ~= "" and kind.bright:find(letter, 1, true) ~= nil)
        if self.screen:Shows(thing) then
          map:Changed()
        end
      end
    end
  end
  self.screen.strips:Reserve(RESERVE, RESERVE_A_FRAME)

  if run.leaving and not run.finished and not view.state.out and view.canMove then
    -- The clock stops at the exit: what the map took is what it took to get there
    run.finished = { seconds = view.clock and view.clock() or 0, at = GetTime and GetTime() or 0 }
    view.submit(EXIT)
  end
  if run.dead and run.tic - run.dead > DEAD_PAUSE and not view.state.dead and view.canMove then
    view.submit(DEAD)
  end
  self:draw()
end

--- A tic of the world: the player's weapon, everything that lives, the flashes fading
function View:worldTic()
  local run = self.run
  run.tic = run.tic + 1
  gunTic(run)
  if liveTic(run) then
    run.map:Changed()
  end
  run.bonus = math.max(0, run.bonus - 1)
  run.hurt = math.max(0, run.hurt - 1)
  local player = run.player
  local sector = player.sector
  local hurts = sector and HURTING_FLOORS[sector.special]
  if hurts and not run.dead and run.tic % HURT_EVERY == 0 and player.z <= sector.floor and not (run.suitUntil and run.tic < run.suitUntil) then
    damage(run, player, nil, nil, hurts)
  end
  if sector and sector.special == FINISH.secret and not run.dead then
    -- A secret, found
    sector.special = 0
    run.secrets = run.secrets + 1
  end
  if run.dead then
    run.eye = math.max(DEAD_EYE, run.eye - 1)
    if run.gunMoving == 0 then
      run.gunMoving = -1
    end
  end
end

--- A picture of the status bar's, with its own offsets from where it is put, so many times as big
--- (once if left out). How wide it is put
function View:patch(name, x, y, scale)
  local picture = self.pictures.pictures[name]
  if not picture then
    return 0
  end
  scale = scale or 1
  local left, top = x - picture.left * scale, y - picture.top * scale
  self.hud:Quad(left, top, left + picture.width * scale, top + picture.height * scale, self.pictures.folder .. "\\" .. name,
    0, picture.width / picture.fileWidth, 0, picture.height / picture.fileHeight, 1, 1, 1)
  return picture.width * scale
end

--- A number, its last digit ending where it is put, in digits named prefix0 to prefix9
function View:number(value, x, y, prefix)
  value = math.max(0, math.floor(value))
  local width = self.pictures.pictures[prefix .. "0"].width
  repeat
    x = x - width
    self:patch(prefix .. (value % 10), x, y)
    value = math.floor(value / 10)
  until value == 0
end

--- Writes in Doom's font, which has only capitals, so many times as big (once if left out)
function View:write(text, x, y, scale)
  for index = 1, #text do
    local code = text:upper():byte(index)
    if code >= FONT_FIRST and code <= FONT_LAST then
      x = x + self:patch(("STCFN%03d"):format(code), x, y, scale)
    else
      x = x + SPACE_WIDTH * (scale or 1)
    end
  end
end

--- The face: how hurt the player is, dead, grinning at a new weapon, hurt badly, looking at
--- whoever hurt them, gritting their teeth while firing on and on, or looking about
function View:face(now)
  local run = self.run
  local inventory = run.inventory
  if run.dead then
    return "STFDEAD0"
  end
  local hurt = math.floor((100 - math.min(100, math.max(0, inventory.health))) * 5 / 101)
  if run.grinUntil and run.tic < run.grinUntil then
    return "STFEVL" .. hurt
  end
  if run.hurtTic and run.tic - run.hurtTic < PAIN_TICS then
    if run.hurtAmount > 20 then
      return "STFOUCH" .. hurt
    end
    local by = run.hurtBy
    if by and by ~= run.player then
      local off = (math.atan2(by.y - run.player.y, by.x - run.player.x) - run.angle + math.pi) % TWO_PI - math.pi
      if off > EIGHTH then
        return "STFTL" .. hurt .. "0"
      elseif off < -EIGHTH then
        return "STFTR" .. hurt .. "0"
      end
    end
    return "STFKILL" .. hurt
  end
  if run.firingSince and run.tic - run.firingSince > RAMPAGE_TICS then
    return "STFKILL" .. hurt
  end
  if now >= self.lookAt then
    self.look, self.lookAt = math.random(0, 2), now + LOOK_TIME
  end
  return "STFST" .. hurt .. self.look
end

--- The weapon in the player's hands, and its flash, over the bottom of the view
function View:drawGun()
  local run, map = self.run, self.run.map
  local sprites, frames = map.data.sprites, map.data.spriteFrames
  local sector = run.player.sector
  local swing = run.tic * TWO_PI / 64
  local x, y = 1 + run.bob * math.cos(swing), run.gunY + run.bob * math.abs(math.sin(swing))
  for index, actor in ipairs({ run.gun, run.flash }) do
    local frame = actor.sequence and actor.picture and frames[actor.picture]
    local picture = frame and sprites[frame[1][1]]
    if picture then
      self.hud:SetLevel(private.Strips.LOWEST + index - 1)
      local left, top = x - picture.left, y - picture.top + VIEW_HEIGHT / 2 - 100
      local bottom = math.min(top + picture.height, VIEW_HEIGHT)
      if bottom > top then
        -- Lit as the sector the player stands in is, close up, unless it lights itself
        local level = math.min(15, math.floor(sector.light / 16) + run.light)
        local light = actor.bright and 1 or (32 - math.max(0, math.min(31, (15 - level) * 4 - 23))) / 32
        self.hud:Quad(left, top, left + picture.width, bottom, map.data.folder .. "\\sprites\\" .. frame[1][1], 0, picture.width / picture.fileWidth,
          0, (bottom - top) / picture.fileHeight, light, light, light)
      end
    end
  end
end

--- A number in the finish screen's big digits, its last ending where it is put, at least so many
--- of them. Where the first begins
function View:bigNumber(x, y, value, digits)
  local width = self.pictures.pictures.WINUM0.width
  value = math.max(0, math.floor(value))
  for _ = 1, math.max(digits or 1, #tostring(value)) do
    x = x - width
    self:patch("WINUM" .. value % 10, x, y)
    value = math.floor(value / 10)
  end
  return x
end

--- A time in minutes and seconds the way Doom's finish screen shows it, ending where it is put
function View:bigTime(x, y, seconds)
  local pictures = self.pictures.pictures
  seconds = math.floor(seconds)
  if seconds > 61 * 59 then
    self:patch("WISUCKS", x - pictures.WISUCKS.width, y)
    return
  end
  local unit = 1
  repeat
    x = self:bigNumber(x, y, math.floor(seconds / unit) % 60, 2) - pictures.WICOLON.width
    unit = unit * 60
    if unit == 60 or math.floor(seconds / unit) > 0 then
      self:patch("WICOLON", x, y)
    end
  until math.floor(seconds / unit) == 0
end

--- Writes a line in Doom's font across the middle of the screen, so many times as big (once if
--- left out). How tall it is
function View:writeMiddle(text, y, scale)
  scale = scale or 1
  local width, height = 0, 0
  for index = 1, #text do
    local code = text:upper():byte(index)
    local picture = code >= FONT_FIRST and code <= FONT_LAST and self.pictures.pictures[("STCFN%03d"):format(code)]
    width = width + (picture and picture.width or SPACE_WIDTH)
    height = math.max(height, picture and picture.height or 0)
  end
  self:write(text, math.floor((SCREEN_WIDTH - width * scale) / 2), y, scale)
  return height * scale
end

--- The screen a map is finished with, Doom's: the episode's map behind, the map's name and that
--- it is finished, how much of what there was to kill, pick up and find, counting up one after
--- the other, then the time and the par. Under them, once they have counted up, the time to
--- the hundredth and how it stands: a new best or the best to beat, and the rival's in a race
function View:drawFinish()
  self.pictures = self.pictures or private.SectorMap.Pictures(HUD_PICTURES)
  if not self.pictures then
    return
  end
  local run, hud, pictures = self.run, self.hud, self.pictures.pictures
  local finished = run.finished
  hud:Begin()
  self:patch("WIMAP0", 0, 0)
  hud:SetLevel(private.Strips.LOWEST + 1)
  -- The first episode's maps have pictures of their names; any other has its name written
  local number = tonumber(run.level:match("^e1m(%d)$"))
  local title, done = number and pictures["WILV0" .. (number - 1)], pictures.WIF
  local tall
  if title then
    self:patch("WILV0" .. (number - 1), math.floor((SCREEN_WIDTH - title.width) / 2), FINISH.titleY)
    tall = title.height
  else
    tall = self:writeMiddle(L["freedoom_map_" .. run.level .. "_title"], FINISH.titleY, FINISH.titleScale)
  end
  if done then
    self:patch("WIF", math.floor((SCREEN_WIDTH - done.width) / 2), FINISH.titleY + math.floor(tall * 5 / 4))
  end

  -- What has counted up by now, each count after the last, a tic at a time
  local now = GetTime and GetTime() or 0
  local left = (now - finished.at) * 35
  local function counted(target, step)
    local value = math.min(target, math.floor(math.max(0, left) * step))
    left = left - target / step
    return value
  end
  local function percent(found, total)
    return total > 0 and math.floor(found * 100 / total) or 100
  end
  local lines = math.floor(pictures.WINUM0.height * 3 / 2)
  -- What was killed, picked up and found isn't known of a run that wasn't played here
  for index, row in ipairs(finished.recalled and {} or { { "WIOSTK", run.kills, run.totalKills }, { "WIOSTI", run.items, run.totalItems }, { "WISCRT2", run.secrets, run.totalSecrets } }) do
    local y = FINISH.statsY + (index - 1) * lines
    self:patch(row[1], FINISH.statsX, y)
    local x = SCREEN_WIDTH - FINISH.statsX
    self:patch("WIPCNT", x, y)
    self:bigNumber(x, y, counted(percent(row[2], row[3]), FINISH.percentStep))
  end
  self:patch("WITIME", FINISH.timeX, FINISH.timeY)
  self:bigTime(SCREEN_WIDTH / 2 - FINISH.timeX, FINISH.timeY, counted(finished.seconds, FINISH.timeStep))
  self:patch("WIPAR", SCREEN_WIDTH / 2 + FINISH.timeX, FINISH.timeY)
  self:bigTime(SCREEN_WIDTH - FINISH.timeX, FINISH.timeY, counted(FINISH.pars[run.level] or 0, FINISH.timeStep))

  -- Doom's counting goes off as the numbers go up, and once they have a bang
  if left <= 0 then
    if not finished.ticked or now - finished.ticked >= SOUND.count / 35 then
      finished.ticked = now
      self:sound("pistol")
    end
  elseif not finished.banged then
    finished.banged = true
    self:sound("barexp")
  end
  if left > 0 then
    local view, notes = self.view, {}
    notes[#notes + 1] = L["freedoom_finish_time"]:format(preciseTime(finished.seconds))
    local best, set
    if view.best then
      best, set = view.best(run.key)
    end
    if set then
      notes[#notes + 1] = L["freedoom_finish_best_new"]
    elseif best then
      notes[#notes + 1] = L["freedoom_finish_best"]:format(preciseTime(best))
    end
    local race = self.race
    if race and race.theirs ~= nil then
      local rival = (race.rival or ""):match("^[^%-]+") or ""
      notes[#notes + 1] = race.theirs and L["freedoom_finish_rival"]:format(rival, preciseTime(race.theirs)) or L["freedoom_finish_rival_out"]:format(rival)
    end
    for index, note in ipairs(notes) do
      self:writeMiddle(note, FINISH.notesY + (index - 1) * FINISH.notesGap)
    end
  end
  hud:Finish()
end

--- The status bar, and whatever is drawn over the view
function View:drawHud()
  self.pictures = self.pictures or private.SectorMap.Pictures(HUD_PICTURES)
  if not self.pictures then
    return
  end
  local hud, run = self.hud, self.run
  local inventory = run.inventory
  local now = GetTime and GetTime() or 0
  hud:Begin()
  self:drawGun()
  hud:SetLevel(private.Strips.LOWEST + 2)
  if run.hurt > 0 then
    hud:Fill(0, 0, SCREEN_WIDTH, VIEW_HEIGHT, RED[1], RED[2], RED[3], RED_ALPHA * math.min(8, math.floor((run.hurt + 7) / 8)) / 8)
  elseif run.bonus > 0 then
    hud:Fill(0, 0, SCREEN_WIDTH, VIEW_HEIGHT, GOLD[1], GOLD[2], GOLD[3], GOLD_ALPHA * run.bonus / BONUS_TICS)
  end
  hud:SetLevel(private.Strips.LOWEST)
  self:patch("STBAR", 0, VIEW_HEIGHT)
  hud:SetLevel(private.Strips.LOWEST + 3)
  local carried = WEAPONS[inventory.weapon].ammo
  if carried then
    self:number(inventory.ammo[carried], BAR.ammo[1], BAR.ammo[2], "STTNUM")
  end
  self:number(inventory.health, BAR.health[1], BAR.health[2], "STTNUM")
  self:patch("STTPRCNT", BAR.health[1], BAR.health[2])
  self:patch("STARMS", BAR.arms[1], BAR.arms[2])
  local owned = {}
  for name in pairs(inventory.weapons) do
    owned[WEAPONS[name].slot] = true
  end
  for slot = 2, 7 do
    local index = slot - 2
    self:patch((owned[slot] and "STYSNUM" or "STGNUM") .. slot, BAR.slots[1] + index % 3 * BAR.slots[3], BAR.slots[2] + math.floor(index / 3) * BAR.slots[4])
  end
  self:patch(self:face(now), BAR.face[1], BAR.face[2])
  self:number(inventory.armor, BAR.armor[1], BAR.armor[2], "STTNUM")
  self:patch("STTPRCNT", BAR.armor[1], BAR.armor[2])
  for index, colour in ipairs({ "blue", "yellow", "red" }) do
    local keys = inventory.keys
    local which = keys[colour .. "skull"] and index + 2 or keys[colour .. "card"] and index - 1
    if which then
      self:patch("STKEYS" .. which, BAR.keys[1], BAR.keys[2] + (index - 1) * BAR.keys[3])
    end
  end
  for _, kind in ipairs({ "bullets", "shells", "rockets", "cells" }) do
    self:number(inventory.ammo[kind], BAR.counts[1], BAR.counts[kind], "STYSNUM")
    self:number(inventory.max[kind], BAR.counts[2], BAR.counts[kind], "STYSNUM")
  end
  if self.message and now < self.messageUntil then
    self:write(self.message, 0, 1)
  end
  hud:Finish()
end

function View:draw()
  local run = self.run
  if not run or not self.screen.map then
    return
  end
  if run.finished then
    self.plate:Hide()
    self:drawFinish()
    return
  end
  local player, map, screen = run.player, run.map, self.screen
  -- What the view was drawn from: when all of it is the same, so is the view
  local as = self.drawnAs
  if not as then
    as = {}
    self.drawnAs = as
  end
  local z = player.z + run.eye + run.bob / 2 * math.sin(run.tic * TWO_PI / 20)
  local step = map:AnimationStep()
  local same = as.x == player.x and as.y == player.y and as.z == z and as.angle == run.angle and as.detail == screen.detail
    and as.version == map.version and as.light == run.light and (as.step == step or not screen.animates)
  local stats = screen.stats
  if not same then
    as.x, as.y, as.z, as.angle, as.detail, as.version, as.step, as.light = player.x, player.y, z, run.angle, screen.detail, map.version, step, run.light
    stats = screen:Draw({ x = player.x, y = player.y, z = z, angle = run.angle, light = run.light })
  end
  self:placePlate()
  self:drawHud()
  if self.stats:IsShown() then
    local now = GetTime and GetTime() or 0
    self:measure(stats, now, not same)
    if now - self.shown >= STATS_EVERY then
      self.shown = now
      self.stats:SetText(L["freedoom_stats"]:format(GetFramerate and GetFramerate() or 0, stats.pieces, stats.moved, stats.things, stats.ms,
        stats.wallsMs, stats.planesMs, stats.thingsMs, screen.detail == 1 and L["freedoom_detail_high"] or L["freedoom_detail_low"]))
    end
  end
end

--- Keeps count of what drawing costs, and logs it every few seconds: the frames there were, how
--- many of them were drawn and what those cost on average, and the worst of them
--- @param stats SectorViewStats
--- @param now number
--- @param drawn boolean The view was drawn this frame, rather than left as it was
function View:measure(stats, now, drawn)
  local sample = self.sample
  if not sample or now - sample.since > LOG_EVERY * 4 then
    -- Nothing was measured for a while: start again rather than count the time in between
    sample = { since = now, frames = 0, drawn = 0, ms = 0, walls = 0, planes = 0, things = 0, pieces = 0, moved = 0, garbage = 0 }
    self.sample = sample
  end
  sample.frames = sample.frames + 1
  if drawn then
    local run = self.run
    sample.drawn, sample.ms, sample.pieces, sample.moved = sample.drawn + 1, sample.ms + stats.ms, sample.pieces + stats.pieces, sample.moved + stats.moved
    sample.walls, sample.planes, sample.things = sample.walls + stats.wallsMs, sample.planes + stats.planesMs, sample.things + stats.thingsMs
    sample.garbage = sample.garbage + stats.garbage
    if not sample.worst or stats.ms > sample.worst then
      sample.worst, sample.worstPieces, sample.worstThings = stats.ms, stats.pieces, stats.things
      sample.x, sample.y, sample.angle = run.player.x, run.player.y, run.angle
    end
  end
  if now - sample.since >= LOG_EVERY and private.Log then
    local count = math.max(1, sample.drawn)
    local awake = 0
    for _, actor in ipairs(self.run.actors) do
      if actor.target then
        awake = awake + 1
      end
    end
    private.Log("freedoom", ("fps %.0f drawn %d%% ms %.1f (walls %.1f floors %.1f things %.1f) pieces %.0f moved %.0f kb %.1f awake %d, worst ms %.1f pieces %d things %d at %.0f %.0f facing %.0f, %s"):format(
      sample.frames / (now - sample.since), sample.drawn * 100 / sample.frames, sample.ms / count, sample.walls / count, sample.planes / count,
      sample.things / count, sample.pieces / count, sample.moved / count, sample.garbage / count, awake, sample.worst or 0, sample.worstPieces or 0,
      sample.worstThings or 0, sample.x or 0, sample.y or 0, math.deg(sample.angle or 0), self.screen.detail == 1 and "high" or "low"))
    self.sample = nil
  end
end

private.Games.Register({
  id = "freedoom",
  name = L["game_freedoom"],
  description = L["game_freedoom_description"],
  genre = "solo",
  icon = "Interface\\AddOns\\ForeverGames\\Images\\Icons\\freedoom",
  addon = MAPS_ADDON,
  version = 4,
  seats = 1,
  options = {
    {
      id = "map",
      name = L["freedoom_option_map"],
      description = L["freedoom_option_map_tip"],
      choices = LEVELS,
      default = LEVELS[1],
      label = function(value)
        return L["freedoom_map_" .. value]
      end,
    },
    {
      id = "skill",
      name = L["freedoom_option_skill"],
      description = L["freedoom_option_skill_tip"],
      choices = SKILLS,
      default = USUAL_SKILL,
      label = function(value)
        return L["freedoom_skill_" .. value]
      end,
    },
  },
  howto = {
    { heading = L["howto_goal"], text = L["freedoom_howto_goal"] },
    { heading = L["howto_controls"], text = L["freedoom_howto_controls"] },
    { heading = L["freedoom_howto_world"], text = L["freedoom_howto_world_text"] },
    { heading = L["howto_end"], text = L["freedoom_howto_end"] },
  },
  clock = "open",
  newState = newState,
  turn = function()
    return 1
  end,
  validate = validate,
  apply = apply,
  moves = moves,
  result = result,
  progress = function(state)
    local map = L["freedoom_map_" .. (state.level or LEVELS[1])]
    if state.skill and state.skill ~= USUAL_SKILL then
      return L["freedoom_progress_skill"]:format(map, L["freedoom_skill_" .. state.skill])
    end
    return map
  end,
  record = function(state, seconds)
    if state.out then
      return { { key = recordKey(state), value = seconds, lower = true } }
    end
    return nil
  end,
  createView = createView,
  -- Every map is the same whoever plays it, so a best can be raced as it is: the way to the end of
  -- one is getting out of it
  ghost = { every = GHOST.every, course = function()
    return { EXIT }
  end },
})
