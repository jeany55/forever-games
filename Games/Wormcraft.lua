--------------------------
--  Wormcraft
--------------------------
-- Artillery for two to four, the way Worms played it: every player has a squad on a hilly island,
-- and they take turns to walk one of them about, aim and let fly, until only one squad is left.
-- Here the squads are of a class, which every player picks for themselves when the game begins,
-- and what they throw at each other is Warcraft's: fireballs, grenades the engineers make,
-- explosive sheep, a blizzard out of the sky. What a squad has to throw grows as the game goes
-- on, the way a character learns spells: everybody is a level higher every round (LEVELS), and
-- crates drop from a zeppelin between turns with something better still in them, the rarer the
-- better (LOOT). Every class has one thing of its own besides (CLASSES).
--
-- The island is columns of ground, COLUMN wide, each a list of the stretches of it that are
-- solid. That is all a crater has to change: an explosion cuts a circle out of the columns it
-- reaches, and whatever stood on what is gone falls. Places are measured from the top left
-- corner of the world, across and down, in SUB parts of a unit so that things can go slower
-- than a unit at a time.
--
-- A turn is one move, and all of it: which of the squad goes, how they walked and jumped, what
-- they fired and how, and where they ran to after. Every client plays that out again, tick by
-- tick, the way the player who made it saw it happen (Sim), and has to come out with the same
-- island and the same squads. So nothing in here measures with anything but whole numbers: the
-- angles go by a table of sines in whole numbers, and every division is rounded down. The client's
-- own math.sin isn't the same on every computer, and the smallest difference grows with every
-- tick until a grenade lands somewhere else. Whatever is left to chance in a turn comes from
-- numbers the state carries (Sim.New), not from the engine's dice, which are only rolled once the
-- move is known and the player has to see what happens while they are still making it.
--
-- A move is the slot of whoever goes, 1 to 4, then what they did a tick at a time:
--   R<n> L<n> W<n>  walk right, walk left or stand for n ticks
--   J B X           jump forwards, flip backwards, or set off what is waiting to be (a sheep)
--   F<id>[.<n>...]  fire a weapon (WEAPONS), with what it is aimed with: "Ffb.45.80" is a fireball
--                   at 45 degrees with 80 of 100 power. Angles go round from 0 pointing right
--                   through 90 straight up. Whatever is aimed at a place is given that place
--   U<id>[.<n>...]  use something that doesn't end the turn, the same way
--   S               end the turn
-- "2R30JW12Ffb.45.80L20" is the second of the squad walking right for a second, jumping, waiting
-- and firing, then running back the way they came. Before that, every player picks a class with
-- "c" and its name, "cMAGE", in seat order.
--
-- The computer plays whichever squads nobody else does (Engine/Computer.lua), picking its class
-- and making its turns like anyone: how it decides on them is Brain's, further down. A game the
-- player started alone before that, with the computer's squads part of the game itself, is
-- still played out the way it was then (`alone`), the player's client making every move.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Tables = private.Tables

-- The world, in units
local WIDTH, HEIGHT, COLUMN = 1024, 512, 4
local COLUMNS = WIDTH / COLUMN
-- Parts of a unit, and ticks in a second
local SUB, TPS = 256, 30
-- In parts of a unit a tick, and a tick squared
local GRAVITY, WIND_PULL, FASTEST = 80, 2, 6000
-- How fast something leaves at full power
local LAUNCH = 4200
-- Where the sea is to begin with, and how much it rises every turn once it is sudden death
local SEA, RISE = 472, 10

-- A body is this tall and this round, in units: it is hit within ROUND of its middle
local TALL, ROUND = 13, 8
-- A step up that is walked, and a step down that is walked rather than fallen
local CLIMB, DROP = 6, 8
local JUMP_X, JUMP_Y, FLIP_X, FLIP_Y = 300, 1100, 150, 1600
-- Faster than this a body lands hurt, by a point for every so much faster. And it bounces
local SAFE_FALL, FALL_HURTS, BOUNCES = 1800, 40, 1500
-- Seconds of the turn to run in, after firing, and at most to wait for everything to settle
local RETREAT, SETTLE = 3, 20
-- What a health crate gives, how many crates there are at most, and the chance of one in a hundred
local MEND, CRATES, CRATE_CHANCE, HEALTH_CHANCE = 30, 5, 40, 40
-- How close a unit has to come to a crate to take it, and to a trap to set it off
local TAKE, TRIP = 12, 18
-- How far apart the squads begin
local APART = 56
-- A move as long as this would no longer fit in a message
local LONGEST = 190

local CLASS, SLOTS = "c", 4
local TEAM_COLORS = { "red", "blue", "green", "yellow" }

-- Sines of whole degrees, as parts of 1024
local SINES = {
  [0] = 0, 18, 36, 54, 71, 89, 107, 125, 143, 160, 178, 195, 213, 230, 248, 265, 282, 299, 316, 333, 350, 367, 384,
  400, 416, 433, 449, 465, 481, 496, 512, 527, 543, 558, 573, 587, 602, 616, 630, 644, 658, 672, 685, 698, 711, 724,
  737, 749, 761, 773, 784, 796, 807, 818, 828, 839, 849, 859, 868, 878, 887, 896, 904, 912, 920, 928, 935, 943, 949,
  956, 962, 968, 974, 979, 984, 989, 994, 998, 1002, 1005, 1008, 1011, 1014, 1016, 1018, 1020, 1022, 1023, 1023, 1024,
  1024,
}

--- Whatever is aimed. Every kind of weapon is played out by Sim:fire, and `aim` says what the
--- player gives it: an angle ("angle"), an angle and power ("power"), and a fuse with them
--- ("fuse"), or a place ("target"). Something `utility` leaves the turn going. A `radius` is the
--- crater's, in units, and those hurt by it are hurt more the nearer they are to the middle of it
--- @class WormcraftWeapon
--- @field id string
--- @field kind string
--- @field aim "none"|"angle"|"power"|"fuse"|"target"
--- @field icon string
--- @field utility boolean?
--- @field wind boolean? Blown about by the wind
--- @field radius number?
--- @field damage number|number[]?
--- @field knock number? How hard those hurt are thrown, at the middle of it
--- @field range number? How far away a place can be aimed at, anywhere if left out

--- @type table<string, WormcraftWeapon>
local WEAPONS = {
  fb = { kind = "shell", aim = "power", wind = true, radius = 24, damage = 45, knock = 2400, icon = "Spell_Fire_FlameBolt" },
  gr = { kind = "grenade", aim = "fuse", radius = 24, damage = 45, knock = 2400, bounce = 2, icon = "INV_Misc_Bomb_08" },
  tg = { kind = "grenade", aim = "fuse", radius = 18, damage = 30, knock = 1800, bounce = 2, cluster = 5, icon = "INV_Misc_Bomb_05" },
  hg = { kind = "grenade", aim = "power", fuse = 3, radius = 56, damage = 100, knock = 4200, bounce = 4, icon = "Spell_Holy_HolyBolt" },
  ms = { kind = "shot", aim = "angle", spread = { -3, 0, 3 }, radius = 5, damage = 15, knock = 1200, icon = "Ability_UpgradeMoonGlaive" },
  hs = { kind = "melee", aim = "none", damage = 30, knockX = 1400, knockY = 2000, icon = "Ability_Rogue_Ambush" },
  et = { kind = "trap", aim = "none", radius = 22, damage = 40, knock = 2200, icon = "Spell_Fire_SelfDestruct" },
  sc = { kind = "charge", aim = "none", fuse = 5, radius = 40, damage = 70, knock = 3200, icon = "INV_Misc_Bomb_02" },
  sh = { kind = "sheep", aim = "none", fuse = 8, radius = 32, damage = 60, knock = 2800, icon = "Spell_Nature_Polymorph" },
  bz = { kind = "strike", aim = "target", drops = 5, spread = 24, every = 4, radius = 14, damage = 22, knock = 1500, picture = "shard", icon = "Spell_Frost_IceStorm" },
  rf = { kind = "strike", aim = "target", drops = 8, spread = 16, every = 3, radius = 10, damage = 14, knock = 900, jitter = 300, picture = "flame", icon = "Spell_Shadow_RainOfFire" },
  kd = { kind = "kodo", aim = "target", radius = 30, damage = 45, knock = 2600, hits = 5, icon = "Ability_Mount_Kodo_01" },
  inf = { kind = "strike", aim = "none", drops = 14, every = 6, radius = 22, damage = 30, knock = 2000, anywhere = true, picture = "meteor", icon = "Spell_Shadow_SummonInfernal" },
  mp = { kind = "dig", aim = "angle", utility = true, length = 64, radius = 10, icon = "INV_Pick_02" },
  tp = { kind = "teleport", aim = "target", utility = true, icon = "INV_Misc_Rune_01" },
  rs = { kind = "skip", aim = "none", icon = "Spell_Nature_Sleep" },
  -- Of a class each
  ch = { kind = "dash", aim = "none", damage = 30, knockX = 2600, knockY = 1800, ticks = 32, speed = 3, icon = "Ability_Warrior_Charge" },
  ds = { kind = "shield", aim = "none", utility = true, icon = "Spell_Holy_DivineIntervention" },
  as = { kind = "shot", aim = "angle", spread = { 0 }, radius = 6, damage = 45, knock = 3000, icon = "INV_Spear_07" },
  bs = { kind = "melee", aim = "none", damage = 45, knockX = 800, knockY = 900, icon = "Ability_BackStab" },
  ph = { kind = "heal", aim = "none", utility = true, heal = 25, icon = "Spell_Holy_PrayerOfHealing02" },
  cl = { kind = "chain", aim = "angle", damage = { 30, 20, 10 }, reach = 120, knock = 800, icon = "Spell_Nature_ChainLightning" },
  bl = { kind = "teleport", aim = "target", utility = true, range = 200, icon = "Spell_Arcane_Blink" },
  dl = { kind = "drain", aim = "none", damage = 25, reach = 160, icon = "Spell_Shadow_LifeDrain02" },
  cf = { kind = "cat", aim = "none", utility = true, icon = "Ability_Druid_CatForm" },
}
for id, weapon in pairs(WEAPONS) do
  weapon.id = id
end
-- The order they are offered in
local ARSENAL = { "fb", "gr", "tg", "hg", "ms", "hs", "et", "sc", "sh", "bz", "rf", "kd", "inf", "mp", "tp" }

-- Every class's own, and how many times a game it can be used. The colours are the client's, for
-- a client that doesn't say
local CLASSES = {
  WARRIOR = { signature = "ch", charges = 3, color = { 0.78, 0.61, 0.43 } },
  PALADIN = { signature = "ds", charges = 2, color = { 0.96, 0.55, 0.73 } },
  HUNTER = { signature = "as", charges = 3, color = { 0.67, 0.83, 0.45 } },
  ROGUE = { signature = "bs", charges = 3, color = { 1, 0.96, 0.41 } },
  PRIEST = { signature = "ph", charges = 2, color = { 1, 1, 1 } },
  SHAMAN = { signature = "cl", charges = 3, color = { 0, 0.44, 0.87 } },
  MAGE = { signature = "bl", charges = 3, color = { 0.41, 0.8, 0.94 } },
  WARLOCK = { signature = "dl", charges = 3, color = { 0.58, 0.51, 0.79 } },
  DRUID = { signature = "cf", charges = 3, color = { 1, 0.49, 0.04 } },
}
local CLASS_ORDER = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

-- What every squad knows at each level, and how many times. Less than nothing is for as often as
-- they like. Everybody is a level higher every round, up to the last of these
local LEVELS = {
  { fb = -1, gr = -1, ms = -1, hs = -1, rs = -1 },
  { tg = 1, et = 2 },
  { sc = 1, sh = 1 },
  { bz = 1, mp = 2 },
  { rf = 1, kd = 1 },
}
-- What a crate that isn't health has in it: how rare first, and then one of those
local LOOT = {
  { rarity = "uncommon", weight = 50, items = { "tg", "et", "sc", "mp" } },
  { rarity = "rare", weight = 30, items = { "sh", "bz", "tp" } },
  { rarity = "epic", weight = 15, items = { "rf", "kd" } },
  { rarity = "legendary", weight = 5, items = { "hg", "inf" } },
}

local THEMES = { "elwynn", "durotar", "winterspring", "steppes" }
local RANDOM_THEME = "random"
-- Who is in a squad, given out to them by the dice
local NAMES = {
  "Leeroy", "Mankrik", "Chuck", "Stabby", "Bob", "Thunderfury", "Grizzle", "Tinkerbolt", "Moonsong", "Grom",
  "Ragnar", "Fizzle", "Nibbles", "Skullsmash", "Pugsley", "Bubbles", "Gnomeregan", "Sprocket", "Brewster",
  "Lightbringer", "Hogger", "Murky", "Gazlowe", "Krokk", "Wicker", "Snuffles", "Tauren Tim", "Pyrotechnic",
  "Stormy", "Mittens", "Sir Squeak", "Jenkins", "Barnaby", "Dottie", "Gloria", "Blixx",
}

--- @class WormcraftUnit
--- @field team number The seat whose it is
--- @field slot number Which of the squad it is
--- @field name string
--- @field x number Where its feet are, in parts of a unit
--- @field y number
--- @field vx number How fast it goes, in parts of a unit a tick
--- @field vy number
--- @field air boolean In the air, rather than standing on something
--- @field facing number 1 to the right, -1 to the left
--- @field hp number
--- @field alive boolean
--- @field shield boolean? Nothing hurts it until its squad's next turn

--- A thing lying about between turns: a crate, a trap or a grave. In a turn, also whatever flies
--- @class WormcraftBody
--- @field kind string
--- @field x number
--- @field y number
--- @field vx number
--- @field vy number
--- @field air boolean
--- @field loot string? What a crate has in it: "health", or a weapon
--- @field rarity string? And how rare that is
--- @field armed number? A trap is set once this is nothing, and goes off this many ticks after it is
--- @field team number? A grave's

--- @class WormcraftTeam
--- @field class string? Who they are, once they have said
--- @field out boolean Gone, all of them dead or the player resigned
--- @field next number The slot that goes next unless the player says otherwise
--- @field arsenal table<string, number> How many of each they have left, less than nothing for always

--- @class WormcraftState
--- @field seats number
--- @field squad number How many each player has
--- @field health number What each of them starts with
--- @field turnTime number Seconds to make a move in, before firing
--- @field suddenDeath number The round the sea starts to rise in, never if nothing
--- @field theme string What the island looks like (THEMES)
--- @field seed number Where what is left to chance in a turn comes from
--- @field columns number[][] What is solid in each column, the top and the bottom of every stretch of it, from the top down
--- @field sea number How far down the sea begins
--- @field wind number -10 to 10, how hard and which way it blows
--- @field teams WormcraftTeam[] By seat
--- @field units WormcraftUnit[]
--- @field bodies WormcraftBody[]
--- @field turn number Whose it is
--- @field turns number How many there have been
--- @field round number
--- @field level number
--- @field picking boolean The players are still saying which class they are
--- @field outcome { winner: number, detail: string? }?

-----------------------------
-- Whole numbers
-----------------------------

--- @param degrees number Whole
--- @return number The sine, as parts of 1024
local function sine(degrees)
  degrees = degrees % 360
  if degrees <= 90 then
    return SINES[degrees]
  elseif degrees <= 180 then
    return SINES[180 - degrees]
  elseif degrees <= 270 then
    return -SINES[degrees - 180]
  end
  return -SINES[360 - degrees]
end

--- @param degrees number
--- @return number
local function cosine(degrees)
  return sine(degrees + 90)
end

--- @param a number
--- @param b number
--- @return number
local function div(a, b)
  return math.floor(a / b)
end

--- The square root, rounded down. The client's square root is the same everywhere, it has to be
--- rounded correctly
--- @param value number
--- @return number
local function root(value)
  return math.floor(math.sqrt(value))
end

--- @param value number
--- @param low number
--- @param high number
--- @return number
local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

-----------------------------
-- The island
-----------------------------

--- Whether a point is in the ground
--- @param columns number[][]
--- @param x number In units
--- @param y number
--- @return boolean
local function solidIn(columns, x, y)
  local spans = columns[div(x, COLUMN) + 1]
  if not spans then
    return false
  end
  for index = 1, #spans, 2 do
    if y < spans[index] then
      return false
    end
    if y < spans[index + 1] then
      return true
    end
  end
  return false
end

--- Cuts a stretch out of a column
--- @param spans number[]
--- @param top number
--- @param bottom number Where the cut ends, the first row that stays
local function cut(spans, top, bottom)
  local kept = {}
  for index = 1, #spans, 2 do
    local from, to = spans[index], spans[index + 1]
    if to <= top or from >= bottom then
      kept[#kept + 1], kept[#kept + 2] = from, to
    else
      if from < top then
        kept[#kept + 1], kept[#kept + 2] = from, top
      end
      if to > bottom then
        kept[#kept + 1], kept[#kept + 2] = bottom, to
      end
    end
  end
  for index = 1, math.max(#spans, #kept) do
    spans[index] = kept[index]
  end
end

--- Cuts a round hole in the island
--- @param columns number[][]
--- @param x number In units
--- @param y number
--- @param radius number
--- @return number first, number last The columns it reached, counted from 1
local function carve(columns, x, y, radius)
  local first, last = math.max(1, div(x - radius, COLUMN) + 1), math.min(COLUMNS, div(x + radius, COLUMN) + 1)
  for index = first, last do
    local away = (index - 1) * COLUMN + COLUMN / 2 - x
    if away * away < radius * radius then
      local half = root(radius * radius - away * away)
      cut(columns[index], y - half, y + half + 1)
    end
  end
  return first, last
end

--- How far down the ground starts in a column, the top of the island there
--- @param columns number[][]
--- @param column number Counted from 1
--- @return number? nil if there is nothing there at all
local function surface(columns, column)
  return columns[column] and columns[column][1]
end

--- Raises an island out of the sea
--- @param random Random
--- @return number[][]
local function raise(random)
  -- The height of the ground at every column edge, by halving the distance between two heights
  -- and putting the one in the middle somewhere near halfway between them, again and again
  local heights = { [0] = 180 + random:Roll(200), [COLUMNS] = 180 + random:Roll(200) }
  local step, reach = COLUMNS, 150
  while step > 1 do
    local half = step / 2
    for left = 0, COLUMNS - step, step do
      local middle = div(heights[left] + heights[left + step], 2)
      heights[left + half] = clamp(middle + random:Roll(reach * 2 + 1) - reach - 1, 90, HEIGHT - 20)
    end
    step, reach = half, math.max(2, div(reach * 11, 20))
  end
  local columns = {}
  for column = 1, COLUMNS do
    columns[column] = { div(heights[column - 1] + heights[column], 2), HEIGHT }
  end

  -- Caves in it
  for _ = 1, 2 + random:Roll(3) do
    local column = 12 + random:Roll(COLUMNS - 24)
    local top = surface(columns, column)
    if top and top < SEA - 90 then
      local radius = 18 + random:Roll(20)
      carve(columns, (column - 1) * COLUMN, top + radius + 20 + random:Roll(SEA - top - radius * 2 - 40), radius)
    end
  end
  -- And ledges over it
  for _ = 1, random:Roll(3) do
    local first, wide = random:Roll(COLUMNS - 30), 8 + random:Roll(16)
    local y, thick = 90 + random:Roll(150), 10 + random:Roll(8)
    for column = first, first + wide do
      local top = surface(columns, column)
      if top and top > y + thick + 40 then
        table.insert(columns[column], 1, y + thick)
        table.insert(columns[column], 1, y)
      end
    end
  end
  return columns
end

-----------------------------
-- Rules
-----------------------------

--- @param players number One for a game played alone from before the computer was the engine's: the other squads are the computer's then, as many as `bots` says
--- @param random Random
--- @param rules table<string, any>?
--- @return WormcraftState
local function newState(players, random, rules)
  rules = rules or {}
  local alone = players == 1
  local seats = alone and 1 + (rules.bots or 1) or players
  local theme = rules.map or RANDOM_THEME
  if theme == RANDOM_THEME then
    theme = THEMES[random:Roll(#THEMES)]
  end
  --- @type WormcraftState
  local state = {
    seats = seats,
    alone = alone or nil,
    skill = alone and (rules.skill or "medium") or nil,
    squad = rules.squad or 3,
    health = rules.health or 100,
    turnTime = rules.time or 45,
    suddenDeath = rules.sudden or 10,
    theme = theme,
    seed = random:Roll(2147483646),
    sea = SEA,
    wind = 0,
    teams = {},
    units = {},
    bodies = {},
    turn = 1,
    turns = 0,
    round = 1,
    level = 1,
    picking = true,
  }
  state.columns = raise(random)

  local names = random:Shuffle({ unpack(NAMES) })
  for seat = 1, seats do
    state.teams[seat] = { out = false, next = 1, arsenal = {} }
    for id, charges in pairs(LEVELS[1]) do
      state.teams[seat].arsenal[id] = charges
    end
  end
  -- Everybody somewhere they can stand, a squad at a time round the table, nobody too near anybody
  for slot = 1, state.squad do
    for seat = 1, seats do
      local placed = false
      for try = 1, 400 do
        local column = 4 + random:Roll(COLUMNS - 8)
        local top = surface(state.columns, column)
        local level = top and top < state.sea - 30
        local flat = level and math.abs((surface(state.columns, column - 1) or HEIGHT) - top) <= CLIMB and math.abs((surface(state.columns, column + 1) or HEIGHT) - top) <= CLIMB
        local x = (column - 1) * COLUMN + COLUMN / 2
        local clear = flat
        for _, other in ipairs(state.units) do
          -- Further and further is good enough, the island might be small
          clear = clear and math.abs(div(other.x, SUB) - x) >= APART - div(try, 10)
        end
        if clear then
          state.units[#state.units + 1] = {
            team = seat,
            slot = slot,
            name = names[#state.units % #names + 1],
            x = x * SUB + SUB / 2,
            y = (top - 1) * SUB + SUB / 2,
            vx = 0,
            vy = 0,
            air = false,
            facing = x < WIDTH / 2 and 1 or -1,
            hp = state.health,
            alive = true,
          }
          placed = true
          break
        end
      end
      assert(placed, "Wormcraft found nowhere to stand")
    end
  end
  -- The computer's squads know who they are from the start
  if alone then
    for seat = 2, seats do
      local class = CLASS_ORDER[random:Roll(#CLASS_ORDER)]
      local team = state.teams[seat]
      team.class, team.computer = class, true
      team.arsenal[CLASSES[class].signature] = CLASSES[class].charges
    end
  end
  return state
end

--- The units of a squad, by slot
--- @param state WormcraftState
--- @param seat number
--- @return WormcraftUnit[]
local function squadOf(state, seat)
  local squad = {}
  for _, unit in ipairs(state.units) do
    if unit.team == seat then
      squad[unit.slot] = unit
    end
  end
  return squad
end

--- The next of a squad still standing, after a slot
--- @param state WormcraftState
--- @param seat number
--- @param slot number
--- @return number? nil if there is nobody left
local function nextAlive(state, seat, slot)
  local squad = squadOf(state, seat)
  for step = 1, state.squad do
    local next = (slot + step - 1) % state.squad + 1
    if squad[next] and squad[next].alive then
      return next
    end
  end
  return nil
end

--- The seat whose turn comes after one, and whether that went round the table to get there
--- @param state WormcraftState
--- @param seat number
--- @return number? seat, boolean round
local function nextSeat(state, seat)
  for step = 1, state.seats do
    local next = (seat + step - 1) % state.seats + 1
    if not state.teams[next].out then
      return next, next <= seat
    end
  end
  return nil, false
end

--- Gives every squad what a level teaches
--- @param state WormcraftState
--- @param level number
local function learn(state, level)
  for _, team in ipairs(state.teams) do
    for id, charges in pairs(LEVELS[level] or {}) do
      local had = team.arsenal[id] or 0
      team.arsenal[id] = (charges < 0 or had < 0) and -1 or had + charges
    end
  end
end

--- Takes squads that have nobody left out of the game, and says who won once one is left
--- @param state WormcraftState
local function count(state)
  local standing, last = 0, nil
  for seat, team in ipairs(state.teams) do
    if not team.out then
      local anybody = false
      for _, unit in ipairs(state.units) do
        anybody = anybody or (unit.team == seat and unit.alive)
      end
      team.out = not anybody
    end
    if not team.out then
      standing, last = standing + 1, seat
    end
  end
  if standing <= 1 and not state.picking then
    state.outcome = { winner = last or 0, detail = last and "last" or "nobody" }
  elseif state.alone and state.teams[1].out then
    -- Alone, the game is lost with the player's squad, however many of the computer's are left
    state.outcome = { winner = last, detail = "beaten" }
  end
end

--- Hands the turn on, and with it whatever comes between turns: the wind, a crate, the sea
--- @param state WormcraftState
--- @param random Random
--- @return table happened What the view should show: `level` if everybody went up one, `crate` if one dropped
local function pass(state, random)
  local happened = {}
  -- The sea first: whoever it takes doesn't get a turn
  if state.suddenDeath > 0 and state.round >= state.suddenDeath then
    state.sea = state.sea - RISE
    happened.rise = true
    for _, unit in ipairs(state.units) do
      if unit.alive and div(unit.y, SUB) >= state.sea then
        unit.alive, unit.hp = false, 0
      end
    end
    for index = #state.bodies, 1, -1 do
      if div(state.bodies[index].y, SUB) >= state.sea then
        table.remove(state.bodies, index)
      end
    end
  end
  count(state)
  if state.outcome then
    return happened
  end
  local seat, round = nextSeat(state, state.turn)
  state.turn, state.turns = seat, state.turns + 1
  if round then
    state.round = state.round + 1
    if state.level < #LEVELS then
      state.level = state.level + 1
      learn(state, state.level)
      happened.level = state.level
    end
  end
  for _, unit in ipairs(state.units) do
    if unit.team == seat then
      unit.shield = nil
    end
  end
  state.wind = random:Roll(21) - 11

  local crates = 0
  for _, body in ipairs(state.bodies) do
    crates = crates + (body.kind == "crate" and 1 or 0)
  end
  if crates < CRATES and random:Roll(100) <= CRATE_CHANCE then
    for _ = 1, 20 do
      local column = 3 + random:Roll(COLUMNS - 6)
      local top = surface(state.columns, column)
      if top and top < state.sea - 10 then
        --- @type WormcraftBody
        local crate = { kind = "crate", x = ((column - 1) * COLUMN + COLUMN / 2) * SUB, y = (top - 1) * SUB + SUB / 2, vx = 0, vy = 0, air = false }
        if random:Roll(100) <= HEALTH_CHANCE then
          crate.loot, crate.rarity = "health", "health"
        else
          local roll, tier = random:Roll(100), LOOT[1]
          for _, option in ipairs(LOOT) do
            if roll > 0 then
              tier = option
            end
            roll = roll - option.weight
          end
          crate.loot, crate.rarity = tier.items[random:Roll(#tier.items)], tier.rarity
        end
        state.bodies[#state.bodies + 1] = crate
        happened.crate = crate
        break
      end
    end
  end

  -- Whoever has been waiting longest goes next, unless the player picks somebody else
  local team, squad = state.teams[seat], squadOf(state, seat)
  if not (squad[team.next] and squad[team.next].alive) then
    team.next = nextAlive(state, seat, team.next) or 1
  end
  return happened
end

-----------------------------
-- A turn, tick by tick
-----------------------------
-- The same for the player making a move, for every client that plays it out again and for the
-- view showing it: a copy of the state, one tick at a time. What a tick does is given to Step:
-- nothing, "R", "L", "J", "B", "X" or "S" as in a move, or what is fired or used.

--- @class WormcraftInput
--- @field use string Weapon id
--- @field args number[]
--- @field fire boolean Fired, rather than used: it ends the turn

--- @class WormcraftHappening Something for the view to show
--- @field kind string "boom", "hurt", "die", "drown", "take", "fire", "shot", "heal", "blink", "dig", "splash"
--- @field x number?
--- @field y number?

--- @class WormcraftSim
--- @field state WormcraftState Its own copy, which it changes as it goes
--- @field unit WormcraftUnit Who is going
--- @field team WormcraftTeam
--- @field phase "aim"|"retreat"|"settle"|"done"
--- @field ticks number How many it has played
--- @field used number Ticks gone of the time to make the move in
--- @field left number Ticks still to run in, after firing
--- @field waited number Ticks it has waited for everything to settle
--- @field moving WormcraftBody[] What flies about, besides units
--- @field queue { at: number, weapon: WormcraftWeapon, x: number, vx: number }[] What is still to fall out of the sky
--- @field random Random
--- @field happened WormcraftHappening[]? What happened since the view last looked, nil where nobody looks
--- @field fired string? What was fired, once it was
--- @field cat boolean? Faster this turn
--- @field shaken boolean The ground changed this tick
local Sim = {}
Sim.__index = Sim

--- @param state WormcraftState Copied, not changed
--- @param slot number Who goes
--- @param watched boolean? Keep what happens for a view
--- @return WormcraftSim
function Sim.New(state, slot, watched)
  local own = Tables.Copy(state)
  local self = setmetatable({
    state = own,
    team = own.teams[own.turn],
    phase = "aim",
    ticks = 0,
    used = 0,
    left = 0,
    waited = 0,
    moving = {},
    queue = {},
    random = private.Random.New(private.Random.Stir(own.seed, "turn" .. own.turns)),
    happened = watched and {} or nil,
    shaken = false,
  }, Sim)
  self.unit = squadOf(own, own.turn)[slot]
  return self
end

--- @param kind string
--- @param fields table?
function Sim:tell(kind, fields)
  if self.happened then
    fields = fields or {}
    fields.kind = kind
    self.happened[#self.happened + 1] = fields
  end
end

--- @param x number In parts of a unit
--- @param y number
--- @return boolean
function Sim:solid(x, y)
  return solidIn(self.state.columns, div(x, SUB), div(y, SUB))
end

--- Whether a body standing with its feet on a row has room there
--- @param x number In units
--- @param y number
--- @param tall number
--- @return boolean
function Sim:room(x, y, tall)
  local columns = self.state.columns
  return not solidIn(columns, x, y) and not solidIn(columns, x, y - div(tall, 2)) and not solidIn(columns, x, y - tall)
end

--- Whether something is standing on the ground: there is ground right under its feet
--- @param body table
--- @return boolean
function Sim:standing(body)
  return solidIn(self.state.columns, div(body.x, SUB), div(body.y, SUB) + 1)
end

--- Hurts a unit, and ends the turn if it was the one going
--- @param unit WormcraftUnit
--- @param amount number
function Sim:hurt(unit, amount)
  if not unit.alive or unit.shield or amount <= 0 then
    return
  end
  unit.hp = math.max(0, unit.hp - amount)
  self:tell("hurt", { unit = unit, amount = amount })
  if unit == self.unit and (self.phase == "aim" or self.phase == "retreat") then
    self.phase = "settle"
  end
  if unit.hp <= 0 then
    self:kill(unit)
  end
end

--- @param unit WormcraftUnit
--- @param drowned boolean?
function Sim:kill(unit, drowned)
  if not unit.alive then
    return
  end
  unit.alive, unit.hp = false, 0
  self:tell(drowned and "drown" or "die", { unit = unit, x = unit.x, y = unit.y })
  if not drowned then
    --- @type WormcraftBody
    local grave = { kind = "grave", x = unit.x, y = unit.y, vx = div(unit.vx, 2), vy = unit.vy, air = true, team = unit.team }
    self.state.bodies[#self.state.bodies + 1] = grave
  end
  if unit == self.unit and self.phase ~= "done" then
    self.phase = "settle"
  end
end

--- Throws something, unit or body
--- @param body table
--- @param vx number
--- @param vy number
local function throw(body, vx, vy)
  body.vx, body.vy = clamp(body.vx + vx, -FASTEST, FASTEST), clamp(body.vy + vy, -FASTEST, FASTEST)
  body.air = true
end

--- An explosion: a crater, and everybody near it hurt and thrown away from it
--- @param x number In parts of a unit
--- @param y number
--- @param radius number In units
--- @param damage number
--- @param knock number
function Sim:explode(x, y, radius, damage, knock)
  carve(self.state.columns, div(x, SUB), div(y, SUB), radius)
  self.shaken = true
  self:tell("boom", { x = x, y = y, radius = radius })
  local reach = (radius + ROUND + 2) * SUB

  --- How near the middle something is, and which way it is from it
  --- @return number? share Of what the middle gets, as parts of the reach. nil if it is out of reach
  local function near(body, tall)
    local dx, dy = body.x - x, body.y - div(tall * SUB, 2) - y
    local away = root(dx * dx + dy * dy)
    if away >= reach then
      return nil
    end
    if away == 0 then
      dx, dy, away = 0, -1, 1
    end
    return reach - away, dx, dy, away
  end

  for _, unit in ipairs(self.state.units) do
    if unit.alive then
      local share, dx, dy, away = near(unit, TALL)
      if share then
        if not unit.shield then
          local thrown = div(knock * share, reach)
          throw(unit, div(thrown * dx, away), div(thrown * dy, away) - div(thrown, 3))
        end
        self:hurt(unit, div(damage * share, reach))
      end
    end
  end
  local bodies = self.state.bodies
  for index = #bodies, 1, -1 do
    local body = bodies[index]
    local share, dx, dy, away = near(body, 4)
    if share then
      if body.kind == "crate" then
        table.remove(bodies, index)
        self:tell("smash", { x = body.x, y = body.y })
      elseif body.kind == "trap" then
        body.armed = 0
        body.fuse = math.min(body.fuse or 4, 4)
      else
        local thrown = div(knock * share, reach)
        throw(body, div(thrown * dx, away), div(thrown * dy, away) - div(thrown, 3))
      end
    end
  end
  for _, body in ipairs(self.moving) do
    if body.kind == "grenade" or body.kind == "charge" or body.kind == "sheep" then
      local share, dx, dy, away = near(body, 4)
      if share then
        local thrown = div(knock * share, reach)
        throw(body, div(thrown * dx, away), div(thrown * dy, away) - div(thrown, 3))
      end
    end
  end
end

--- Moves something through the air for a tick, a little at a time so that it goes through nothing
--- @param body table
--- @param tall number How tall it is, in units
--- @param pull number? Of the wind
--- @param sensitive boolean? It stops at whoever it flies into
--- @return string? what "ground" if it came down on something, "wall" if it went into the side of something, "roof" if it hit something going up, "unit" for somebody
--- @return number? x Where it hit, in parts of a unit
--- @return number? y
function Sim:fly(body, tall, pull, sensitive)
  body.vy = math.min(FASTEST, body.vy + GRAVITY)
  body.vx = clamp(body.vx + (pull or 0), -FASTEST, FASTEST)
  local steps = div(math.max(math.abs(body.vx), math.abs(body.vy)), SUB * 2) + 1
  local startX, startY = body.x, body.y
  local columns = self.state.columns
  local function clear(column, row)
    return not solidIn(columns, column, row) and (tall <= 2 or (not solidIn(columns, column, row - tall) and not solidIn(columns, column, row - div(tall, 2))))
  end
  for step = 1, steps do
    local toX, toY = startX + div(body.vx * step, steps), startY + div(body.vy * step, steps)
    local column, row = div(toX, SUB), div(toY, SUB)
    if not clear(column, row) then
      local fromColumn, fromRow = div(body.x, SUB), div(body.y, SUB)
      local across, down = clear(column, fromRow), clear(fromColumn, row)
      if down and not across then
        return "wall", toX, toY
      elseif body.vy > 0 then
        return "ground", toX, toY
      elseif body.vy < 0 and not down then
        return "roof", toX, toY
      end
      return "wall", toX, toY
    end
    body.x, body.y = toX, toY
    if sensitive and self:hits(body) then
      return "unit", toX, toY
    end
  end
  return nil
end

--- Brings something that came down onto the ground to rest on it, its feet on the row above
--- @param body table
function Sim:settle(body)
  local column, row = div(body.x, SUB), div(body.y, SUB)
  local columns = self.state.columns
  for _ = 1, CLIMB * 2 do
    if not solidIn(columns, column, row) then
      break
    end
    row = row - 1
  end
  for _ = 1, 3 do
    if solidIn(columns, column, row + 1) then
      break
    end
    row = row + 1
  end
  body.y = row * SUB + SUB / 2
  return solidIn(columns, column, row + 1)
end

--- A tick of a unit in the air
--- @param unit WormcraftUnit
function Sim:fall(unit)
  local speed = unit.vy
  local hit = self:fly(unit, TALL)
  if hit == "ground" then
    if speed > SAFE_FALL then
      self:hurt(unit, div(speed - SAFE_FALL, FALL_HURTS))
    end
    local landed = self:settle(unit)
    if speed > BOUNCES or math.abs(unit.vx) > BOUNCES then
      unit.vy, unit.vx = -div(speed, 3), div(unit.vx, 2)
    elseif landed then
      unit.vx, unit.vy, unit.air = 0, 0, false
    else
      -- Came down on the edge of something, and off it
      unit.vx, unit.vy = 0, 0
    end
  elseif hit == "wall" then
    unit.vx = -div(unit.vx, 2)
  elseif hit == "roof" then
    unit.vy = 0
  end
end

--- A unit walks a step, or a few for somebody quick. Up what isn't too steep, down what isn't too
--- far, and off the edge of anything else
--- @param unit table
--- @param way number 1 right, -1 left
--- @param steps number
--- @return boolean walked False if there was a wall
function Sim:walk(unit, way, steps)
  unit.facing = way
  local columns = self.state.columns
  for _ = 1, steps do
    local x, y = div(unit.x, SUB) + way, div(unit.y, SUB)
    local moved = false
    for up = 0, CLIMB do
      if self:room(x, y - up, TALL) then
        if solidIn(columns, x, y - up + 1) then
          unit.x, unit.y, moved = unit.x + way * SUB, (y - up) * SUB + SUB / 2, true
        elseif up == 0 then
          local down = nil
          for drop = 1, DROP do
            if solidIn(columns, x, y + drop + 1) then
              down = drop
              break
            end
            if solidIn(columns, x, y + drop) then
              break
            end
          end
          unit.x, moved = unit.x + way * SUB, true
          if down then
            unit.y = (y + down) * SUB + SUB / 2
          else
            unit.air, unit.vx, unit.vy = true, 0, 0
            return true
          end
        end
        if moved then
          break
        end
      end
    end
    if not moved then
      return false
    end
  end
  return true
end

--- Whether a place is somewhere a unit could be put down: nothing solid where it would stand
--- @param x number In units
--- @param y number
--- @return boolean
function Sim:open(x, y)
  return x >= 0 and x < WIDTH and y > 0 and y < self.state.sea and self:room(x, y, TALL)
end

--- The middle of a unit, where things are fired from
--- @param unit WormcraftUnit
--- @return number x, number y In parts of a unit
local function middleOf(unit)
  return unit.x, unit.y - div(TALL * SUB, 2)
end

--- The living unit nearest a point, but not one of these
--- @param x number
--- @param y number
--- @param reach number In parts of a unit
--- @param except table<WormcraftUnit, boolean>
--- @param team number? Not of this squad either
--- @return WormcraftUnit?
function Sim:nearest(x, y, reach, except, team)
  local best, nearest = nil, reach * reach
  for _, unit in ipairs(self.state.units) do
    if unit.alive and not except[unit] and unit.team ~= team then
      local mx, my = middleOf(unit)
      local away = (mx - x) * (mx - x) + (my - y) * (my - y)
      if away <= nearest then
        best, nearest = unit, away
      end
    end
  end
  return best
end

--- A straight line from a unit, as far as the first thing in the way
--- @param from WormcraftUnit
--- @param angle number
--- @return number x, number y Where it stopped
--- @return WormcraftUnit? hit Who it stopped at, nil for the ground or nothing at all
function Sim:trace(from, angle)
  local x, y = middleOf(from)
  local dx, dy = div(cosine(angle) * 2 * SUB, 1024), -div(sine(angle) * 2 * SUB, 1024)
  for _ = 1, 400 do
    x, y = x + dx, y + dy
    if x < -SUB * 20 or x > (WIDTH + 20) * SUB or y > self.state.sea * SUB then
      return x, y, nil
    end
    if self:solid(x, y) then
      return x, y, nil
    end
    for _, unit in ipairs(self.state.units) do
      if unit ~= from and unit.alive then
        local mx, my = middleOf(unit)
        if (mx - x) * (mx - x) + (my - y) * (my - y) <= ROUND * ROUND * SUB * SUB then
          return x, y, unit
        end
      end
    end
  end
  return x, y, nil
end

--- Strikes whoever stands in front of a unit, near enough to hit
--- @param weapon WormcraftWeapon
--- @return boolean hit
function Sim:strike(weapon)
  local unit, hit = self.unit, false
  for _, other in ipairs(self.state.units) do
    if other ~= unit and other.alive then
      local dx, dy = (other.x - unit.x) * unit.facing, math.abs(other.y - unit.y)
      if dx >= -2 * SUB and dx <= (ROUND * 2 + 2) * SUB and dy <= TALL * SUB then
        if not other.shield then
          throw(other, weapon.knockX * unit.facing, -weapon.knockY)
        end
        self:hurt(other, weapon.damage)
        hit = true
      end
    end
  end
  self:tell("strike", { unit = unit, hit = hit })
  return hit
end

--- Fires or uses something. Returns false if it couldn't be, and then nothing was used up
--- @param weapon WormcraftWeapon
--- @param args number[]
--- @return boolean
function Sim:fire(weapon, args)
  local unit, state = self.unit, self.state
  local kind = weapon.kind
  local x, y = middleOf(unit)
  local angle = args[1] or 0
  if weapon.aim == "angle" or weapon.aim == "power" or weapon.aim == "fuse" then
    unit.facing = cosine(angle) < 0 and -1 or (cosine(angle) > 0 and 1 or unit.facing)
  end

  if kind == "shell" or kind == "grenade" then
    local power = args[2] or 50
    local speed = div(LAUNCH * power, 100)
    -- Out of the unit's hands, a little way along where it is aimed
    local startX, startY = x + div(cosine(angle) * 12 * SUB, 1024), y - div(sine(angle) * 12 * SUB, 1024)
    --- @type WormcraftBody
    local body = { kind = kind, weapon = weapon, x = startX, y = startY, vx = div(cosine(angle) * speed, 1024), vy = -div(sine(angle) * speed, 1024), air = true, age = 0 }
    if kind == "grenade" then
      body.fuse = (weapon.fuse or args[3] or 3) * TPS
    end
    self.moving[#self.moving + 1] = body
  elseif kind == "shot" or kind == "chain" then
    for _, spread in ipairs(weapon.spread or { 0 }) do
      local hitX, hitY, hit = self:trace(unit, angle + spread)
      self:tell("shot", { fromX = x, fromY = y, x = hitX, y = hitY, chain = kind == "chain" })
      if kind == "shot" then
        if hit then
          if not hit.shield then
            local dx = cosine(angle + spread)
            local dy = -sine(angle + spread)
            throw(hit, div(weapon.knock * dx, 1024), div(weapon.knock * dy, 1024) - div(weapon.knock, 3))
          end
          self:hurt(hit, weapon.damage)
        elseif self:solid(hitX, hitY) then
          self:explode(hitX, hitY, weapon.radius, div(weapon.damage, 2), div(weapon.knock, 2))
        end
      elseif hit then
        -- And on from whoever it hit to whoever is nearest them, never the same one twice
        local struck, at = { [unit] = true }, hit
        for index, damage in ipairs(weapon.damage) do
          struck[at] = true
          if not at.shield then
            throw(at, 0, -weapon.knock)
          end
          self:hurt(at, damage)
          local nextUnit = weapon.damage[index + 1] and self:nearest(at.x, at.y, weapon.reach * SUB, struck)
          if not nextUnit then
            break
          end
          local fromX, fromY = middleOf(at)
          local toX, toY = middleOf(nextUnit)
          self:tell("shot", { fromX = fromX, fromY = fromY, x = toX, y = toY, chain = true })
          at = nextUnit
        end
      end
    end
  elseif kind == "melee" then
    self:strike(weapon)
  elseif kind == "dash" then
    self.dash = { weapon = weapon, left = weapon.ticks }
  elseif kind == "trap" or kind == "charge" then
    --- @type WormcraftBody
    local body = { kind = kind, x = unit.x, y = unit.y, vx = 0, vy = 0, air = true, team = unit.team }
    if kind == "trap" then
      body.id = weapon.id
      body.armed = 2 * TPS
      state.bodies[#state.bodies + 1] = body
    else
      body.weapon, body.fuse = weapon, weapon.fuse * TPS
      self.moving[#self.moving + 1] = body
    end
  elseif kind == "sheep" then
    self.moving[#self.moving + 1] = { kind = "sheep", weapon = weapon, x = unit.x + unit.facing * 8 * SUB, y = unit.y, vx = 0, vy = 0, air = true, facing = unit.facing, fuse = weapon.fuse * TPS }
  elseif kind == "strike" then
    local target = args[1] or 0
    for drop = 1, weapon.drops do
      local at
      if weapon.anywhere then
        at = 8 + self.random:Roll(WIDTH - 16)
      else
        at = target + (drop - 1 - div(weapon.drops - 1, 2)) * weapon.spread - (weapon.drops % 2 == 0 and div(weapon.spread, 2) or 0)
      end
      local drift = weapon.jitter and self.random:Roll(weapon.jitter * 2 + 1) - weapon.jitter - 1 or 0
      if weapon.anywhere then
        drift = self.random:Roll(1201) - 601
      end
      self.queue[#self.queue + 1] = { at = self.ticks + (drop - 1) * weapon.every, weapon = weapon, x = at * SUB, vx = drift }
    end
  elseif kind == "kodo" then
    self.moving[#self.moving + 1] = { kind = "kodo", weapon = weapon, x = (args[1] or 0) * SUB, y = -40 * SUB, vx = 0, vy = 600, air = true, hits = 0 }
  elseif kind == "dig" then
    local toX, toY = cosine(angle), -sine(angle)
    for along = 0, weapon.length, 6 do
      carve(state.columns, div(x + div(toX * along * SUB, 1024), SUB), div(y + div(toY * along * SUB, 1024), SUB), weapon.radius)
    end
    self.shaken = true
    self:tell("dig", { x = x, y = y, angle = angle, length = weapon.length })
  elseif kind == "teleport" then
    local toX, toY = args[1] or -1, args[2] or -1
    local dx, dy = toX - div(unit.x, SUB), toY - div(unit.y, SUB)
    local far = weapon.range and dx * dx + dy * dy > weapon.range * weapon.range
    if far or not self:open(toX, toY) then
      return false
    end
    self:tell("blink", { fromX = unit.x, fromY = unit.y, x = toX * SUB + SUB / 2, y = toY * SUB + SUB / 2 })
    unit.x, unit.y, unit.vx, unit.vy, unit.air = toX * SUB + SUB / 2, toY * SUB + SUB / 2, 0, 0, true
  elseif kind == "shield" then
    unit.shield = true
    self:tell("shield", { unit = unit })
  elseif kind == "heal" then
    for _, other in ipairs(squadOf(state, unit.team)) do
      if other.alive then
        other.hp = other.hp + weapon.heal
        self:tell("heal", { unit = other, amount = weapon.heal })
      end
    end
  elseif kind == "drain" then
    local victim = self:nearest(x, y, weapon.reach * SUB, { [unit] = true }, unit.team)
    if not victim then
      return false
    end
    local toX, toY = middleOf(victim)
    self:tell("shot", { fromX = toX, fromY = toY, x = x, y = y, drain = true })
    self:hurt(victim, weapon.damage)
    unit.hp = unit.hp + weapon.damage
    self:tell("heal", { unit = unit, amount = weapon.damage })
  elseif kind == "cat" then
    self.cat = true
    self:tell("shift", { unit = unit })
  end
  self:tell("fire", { weapon = weapon.id, unit = unit })
  return true
end

--- What falls out of the sky, when its tick comes
function Sim:drop()
  for index = #self.queue, 1, -1 do
    local drop = self.queue[index]
    if drop.at <= self.ticks then
      table.remove(self.queue, index)
      self.moving[#self.moving + 1] = { kind = "drop", weapon = drop.weapon, x = drop.x, y = -30 * SUB, vx = drop.vx, vy = 400, air = true, age = 0 }
    end
  end
end

--- Whether a shell has flown into somebody
--- @param body table
--- @return boolean
function Sim:hits(body)
  for _, unit in ipairs(self.state.units) do
    if unit.alive and (unit ~= self.unit or body.age > 4) then
      local mx, my = middleOf(unit)
      if (mx - body.x) * (mx - body.x) + (my - body.y) * (my - body.y) <= ROUND * ROUND * SUB * SUB then
        return true
      end
    end
  end
  return false
end

--- Sets off what flies, and takes it away
--- @param body table
function Sim:blow(body)
  local weapon = body.weapon
  body.gone = true
  self:explode(body.x, body.y, weapon.radius, weapon.damage, weapon.knock)
  if weapon.cluster then
    for piece = 1, weapon.cluster do
      local spread = (piece - 1 - div(weapon.cluster - 1, 2)) * 350 + self.random:Roll(201) - 101
      self.moving[#self.moving + 1] = { kind = "shell", weapon = { radius = 10, damage = 18, knock = 1200 }, bomblet = true, x = body.x, y = body.y - 4 * SUB, vx = spread, vy = -1400 - self.random:Roll(500), air = true, age = 10 }
    end
  end
end

--- A tick of everything that flies
function Sim:flyAll()
  local pull = self.state.wind * WIND_PULL
  for _, body in ipairs(self.moving) do
    if not body.gone then
      local kind = body.kind
      body.age = (body.age or 0) + 1
      if kind == "shell" or kind == "drop" then
        local hit, x, y = self:fly(body, 1, body.weapon.wind and pull or 0, true)
        if hit then
          body.x, body.y = x, y
          self:blow(body)
        end
      elseif kind == "kodo" then
        local hit, x, y = self:fly(body, 1)
        if hit then
          body.x, body.y = x, y
          body.hits = body.hits + 1
          self:explode(x, y, body.weapon.radius, body.weapon.damage, body.weapon.knock)
          body.vy = 500
          if body.hits >= body.weapon.hits then
            body.gone = true
          end
        end
      elseif kind == "grenade" or kind == "charge" then
        if body.air then
          local speed = body.vy
          local hit = self:fly(body, 1)
          local bounce = body.weapon.bounce or 3
          if hit == "ground" then
            local landed = self:settle(body)
            if speed < 500 and math.abs(body.vx) < 300 then
              body.vx, body.vy, body.air = 0, 0, not landed
            else
              body.vy, body.vx = -div(speed, bounce), div(body.vx * 3, 4)
              body.y = body.y - SUB
            end
          elseif hit == "wall" then
            body.vx = -div(body.vx, bounce)
          elseif hit == "roof" then
            body.vy = div(-body.vy, bounce)
          end
        elseif not self:standing(body) then
          body.air = true
        end
        body.fuse = body.fuse - 1
        if body.fuse <= 0 then
          self:blow(body)
        end
      elseif kind == "sheep" then
        if body.air then
          self:fall(body)
        elseif not self:standing(body) then
          body.air = true
        elseif body.age % 2 == 0 and not self:walk(body, body.facing, 1) then
          throw(body, body.facing * 300, -JUMP_Y)
          if body.bumps and body.bumps > 3 then
            body.facing = -body.facing
            body.bumps = 0
          end
          body.bumps = (body.bumps or 0) + 1
        end
        body.fuse = body.fuse - 1
        if body.fuse <= 0 or body.blown then
          self:blow(body)
        end
      end
      if not body.gone and div(body.y, SUB) > self.state.sea + 8 then
        body.gone = true
        self:tell("splash", { x = body.x, y = self.state.sea * SUB })
      elseif not body.gone and (body.x < -200 * SUB or body.x > (WIDTH + 200) * SUB) then
        body.gone = true
      end
    end
  end
  for index = #self.moving, 1, -1 do
    if self.moving[index].gone then
      table.remove(self.moving, index)
    end
  end
end

--- A tick of everything lying about: falling if what it lay on is gone, traps going off
function Sim:lieAll()
  local bodies = self.state.bodies
  for index = #bodies, 1, -1 do
    local body = bodies[index]
    -- A trap that went off smashes the crates near it, and the list is shorter than it was
    if body then
      self:lie(bodies, index, body)
    end
  end
end

--- A tick of one thing lying about
--- @param bodies table[]
--- @param index number Where it is among them
--- @param body table
function Sim:lie(bodies, index, body)
  if body.air then
    local hit = self:fly(body, 2)
    if hit == "ground" then
      body.vx, body.vy = 0, 0
      body.air = not self:settle(body)
    elseif hit == "wall" then
      body.vx = -div(body.vx, 2)
    elseif hit == "roof" then
      body.vy = 0
    end
  elseif self.shaken and not self:standing(body) then
    body.air = true
  end
  if body.kind == "trap" then
    if body.armed > 0 then
      body.armed = body.armed - 1
    elseif not body.fuse then
      for _, unit in ipairs(self.state.units) do
        local dx, dy = unit.x - body.x, unit.y - body.y
        if unit.alive and dx * dx + dy * dy <= TRIP * TRIP * SUB * SUB then
          body.fuse = TPS
          self:tell("trip", { x = body.x, y = body.y })
          break
        end
      end
    else
      body.fuse = body.fuse - 1
      if body.fuse <= 0 then
        table.remove(bodies, index)
        local weapon = WEAPONS[body.id]
        self:explode(body.x, body.y - 2 * SUB, weapon.radius, weapon.damage, weapon.knock)
      end
    end
  end
  if bodies[index] == body and div(body.y, SUB) > self.state.sea + 8 then
    table.remove(bodies, index)
    self:tell("splash", { x = body.x, y = self.state.sea * SUB })
  end
end

--- A tick of every unit: falling, landing, drowning, taking crates
function Sim:standAll()
  local state = self.state
  for _, unit in ipairs(state.units) do
    if unit.alive then
      if unit.air then
        self:fall(unit)
      elseif self.shaken and not self:standing(unit) then
        unit.air = true
      end
      if div(unit.y, SUB) >= state.sea then
        self:kill(unit, true)
      elseif unit.x < -60 * SUB or unit.x > (WIDTH + 60) * SUB then
        self:kill(unit, true)
      end
    end
  end
  for _, unit in ipairs(state.units) do
    if unit.alive then
      for index = #state.bodies, 1, -1 do
        local body = state.bodies[index]
        local dx, dy = unit.x - body.x, unit.y - body.y
        if body.kind == "crate" and dx * dx + dy * dy <= TAKE * TAKE * SUB * SUB then
          table.remove(state.bodies, index)
          if body.loot == "health" then
            unit.hp = unit.hp + MEND
            self:tell("heal", { unit = unit, amount = MEND })
          else
            local arsenal = state.teams[unit.team].arsenal
            arsenal[body.loot] = (arsenal[body.loot] or 0) < 0 and -1 or (arsenal[body.loot] or 0) + 1
          end
          self:tell("take", { unit = unit, loot = body.loot, rarity = body.rarity })
        end
      end
    end
  end
end

--- Whether nothing moves any more, and nothing is still to go off
--- @return boolean
function Sim:still()
  if #self.moving > 0 or #self.queue > 0 or self.dash then
    return false
  end
  for _, unit in ipairs(self.state.units) do
    if unit.alive and unit.air then
      return false
    end
  end
  for _, body in ipairs(self.state.bodies) do
    if body.air or body.fuse then
      return false
    end
  end
  return true
end

--- Plays a tick
--- @param input string|WormcraftInput|nil What the player did in it
--- @return boolean? used For something fired or used: whether it was. What wasn't did nothing at all
function Sim:Step(input)
  if self.phase == "done" then
    return
  end
  local used = nil
  local unit, playing = self.unit, self.phase == "aim" or self.phase == "retreat"
  self.ticks = self.ticks + 1
  self.shaken = false

  if playing and unit.alive and input then
    local quick = self.cat and 2 or 1
    if type(input) == "table" then
      local weapon = WEAPONS[input.use]
      local arsenal = self.team.arsenal
      local allowed = weapon and arsenal[input.use] and arsenal[input.use] ~= 0 and self.phase == "aim" and not self.dash
      if allowed and (weapon.utility or not unit.air) and self:fire(weapon, input.args) then
        used = true
        if arsenal[input.use] > 0 then
          arsenal[input.use] = arsenal[input.use] - 1
        end
        if weapon.kind == "skip" then
          self.phase = "settle"
        elseif not weapon.utility then
          self.fired, self.phase, self.left = input.use, "retreat", RETREAT * TPS
        end
      end
    elseif input == "S" then
      self.phase = "settle"
    elseif input == "X" then
      for _, body in ipairs(self.moving) do
        if body.kind == "sheep" then
          body.blown = true
        end
      end
    elseif not unit.air and not self.dash then
      if input == "R" or input == "L" then
        self:walk(unit, input == "R" and 1 or -1, quick)
      elseif input == "J" then
        throw(unit, unit.facing * div(JUMP_X * (self.cat and 3 or 2), 2), -JUMP_Y)
      elseif input == "B" then
        throw(unit, -unit.facing * FLIP_X, -FLIP_Y)
      end
    end
  end

  local dash = self.dash
  if dash then
    dash.left = dash.left - 1
    local hit = false
    for _, other in ipairs(self.state.units) do
      if other ~= unit and other.alive and math.abs(other.x - unit.x) <= ROUND * 2 * SUB and math.abs(other.y - unit.y) <= TALL * SUB then
        hit = true
      end
    end
    if hit then
      self:strike(dash.weapon)
      self.dash = nil
    elseif dash.left <= 0 or unit.air or not unit.alive or not self:walk(unit, unit.facing, dash.weapon.speed) then
      self.dash = nil
    end
  end

  self:drop()
  self:flyAll()
  self:lieAll()
  self:standAll()
  -- What moved off something that was there a moment ago has nothing under it either
  if self.shaken then
    self:lieAll()
    self:standAll()
  end

  if self.phase == "aim" then
    self.used = self.used + 1
    if self.used >= self.state.turnTime * TPS then
      self.phase = "settle"
    end
  elseif self.phase == "retreat" then
    self.left = self.left - 1
    if self.left <= 0 then
      self.phase = "settle"
    end
  end
  if self.phase == "settle" then
    self.waited = self.waited + 1
    if self:still() or self.waited >= SETTLE * TPS then
      self:finish()
    end
  end
  return used
end

--- Ends the turn: whatever is still about is put down where it is, and the next squad goes
function Sim:finish()
  local state = self.state
  self.phase = "done"
  self.moving, self.queue, self.dash = {}, {}, nil
  for _, unit in ipairs(state.units) do
    unit.vx, unit.vy = 0, 0
    if unit.air then
      unit.air = false
      self:settle(unit)
    end
  end
  for _, body in ipairs(state.bodies) do
    body.vx, body.vy, body.fuse = 0, 0, nil
    if body.air then
      body.air = false
      self:settle(body)
    end
  end
  local team = self.team
  if self.unit then
    team.next = nextAlive(state, state.turn, self.unit.slot) or team.next
  end
  self.passed = pass(state, self.random)
end

-----------------------------
-- Moves
-----------------------------

--- Reads a move: who goes, and what they do tick by tick
--- @param move string
--- @return number? slot nil if it can't be read
--- @return (string|WormcraftInput)[]? inputs In runs: { input, ticks } for walking and standing, else one tick each
function private.WormcraftDecode(move)
  local slot = tonumber(move:sub(1, 1))
  if not slot or #move > LONGEST then
    return nil
  end
  local inputs, at = {}, 2
  while at <= #move do
    local letter = move:sub(at, at)
    if letter == "R" or letter == "L" or letter == "W" then
      local ticks = move:match("^%d+", at + 1)
      if not ticks or tonumber(ticks) < 1 then
        return nil
      end
      inputs[#inputs + 1] = { letter ~= "W" and letter or false, tonumber(ticks) }
      at = at + 1 + #ticks
    elseif letter == "J" or letter == "B" or letter == "X" or letter == "S" then
      inputs[#inputs + 1] = { letter, 1 }
      at = at + 1
    elseif letter == "F" or letter == "U" then
      local id = move:match("^%l+", at + 1)
      if not id or not WEAPONS[id] or (letter == "U") ~= (WEAPONS[id].utility == true) then
        return nil
      end
      at = at + 1 + #id
      local args = {}
      while true do
        local number = move:match("^%.%-?%d+", at)
        if not number then
          break
        end
        args[#args + 1] = tonumber(number:sub(2))
        at = at + #number
      end
      inputs[#inputs + 1] = { { use = id, args = args, fire = letter == "F" }, 1 }
    else
      return nil
    end
  end
  return slot, inputs
end
local decode = private.WormcraftDecode

--- Whether what a weapon is given makes sense for it
--- @param weapon WormcraftWeapon
--- @param args number[]
--- @return boolean
local function aimable(weapon, args)
  local aim = weapon.aim
  if aim == "none" then
    return #args == 0
  elseif aim == "angle" then
    return #args == 1 and args[1] >= 0 and args[1] < 360
  elseif aim == "power" then
    return #args == 2 and args[1] >= 0 and args[1] < 360 and args[2] >= 1 and args[2] <= 100
  elseif aim == "fuse" then
    return #args == 3 and args[1] >= 0 and args[1] < 360 and args[2] >= 1 and args[2] <= 100 and args[3] >= 1 and args[3] <= 5
  elseif aim == "target" then
    local wanted = weapon.kind == "teleport" and 2 or 1
    return #args == wanted and args[1] >= 0 and args[1] < WIDTH and (wanted == 1 or (args[2] >= 0 and args[2] < HEIGHT))
  end
  return false
end

--- @param state WormcraftState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  if state.outcome then
    return false, "finished"
  end
  -- Alone, the player makes the computer's moves too, or their client does
  if seat ~= (state.alone and 1 or state.turn) then
    return false, "not_your_turn"
  end
  seat = state.turn
  local team = state.teams[seat]
  if state.picking then
    local class = move:match("^" .. CLASS .. "(%u+)$")
    if not class or not CLASSES[class] or team.class then
      return false, "invalid_move"
    end
    return true
  end
  local slot, inputs = decode(move)
  local unit = slot and squadOf(state, seat)[slot]
  if not unit or not unit.alive then
    return false, "invalid_move"
  end
  local aiming, running, fired, used = 0, 0, false, {}
  for _, input in ipairs(inputs) do
    local what, ticks = input[1], input[2]
    if type(what) == "table" then
      local weapon = WEAPONS[what.use]
      local had = team.arsenal[what.use]
      used[what.use] = (used[what.use] or 0) + 1
      if fired or not had or (had >= 0 and used[what.use] > had) or not aimable(weapon, what.args) then
        return false, "invalid_move"
      end
      fired = not weapon.utility
    end
    if fired and type(what) ~= "table" then
      running = running + ticks
    else
      aiming = aiming + ticks
    end
  end
  if aiming > state.turnTime * TPS or running > RETREAT * TPS then
    return false, "invalid_move"
  end
  return true
end

--- Plays a turn out from a state, the way every client does: what the player did, tick by tick,
--- and then whatever is left to happen without them
--- @param state WormcraftState Copied, not changed
--- @param slot number
--- @param inputs table[] As decoded
--- @param watched boolean?
--- @param stop (fun(sim: WormcraftSim): boolean)? Stop as soon as this says so
--- @return WormcraftSim
local function play(state, slot, inputs, watched, stop)
  local sim = Sim.New(state, slot, watched)
  for _, input in ipairs(inputs) do
    local what, ticks = input[1], input[2]
    for _ = 1, ticks do
      if sim.phase ~= "aim" and sim.phase ~= "retreat" then
        break
      end
      sim:Step(what or nil)
      if stop and stop(sim) then
        return sim
      end
    end
  end
  for _ = 1, (RETREAT + SETTLE) * TPS + 2 do
    if sim.phase == "done" then
      break
    end
    if sim.phase == "aim" or sim.phase == "retreat" then
      sim.phase = "settle"
    end
    sim:Step(nil)
    if stop and stop(sim) then
      return sim
    end
  end
  if sim.phase ~= "done" then
    sim:finish()
  end
  return sim
end

-- The state every move was made from, for a view to play it out again. Only the last few are
-- kept, nobody watches further back than their own last turn
local films = setmetatable({}, { __mode = "k" })

--- @param state WormcraftState
--- @param seat number
--- @param move string
--- @return table event
local function apply(state, seat, move)
  seat = state.turn
  local team = state.teams[seat]
  if state.picking then
    local class = move:sub(2)
    team.class = class
    local own = CLASSES[class]
    team.arsenal[own.signature] = own.charges
    local next = nil
    for other = seat + 1, state.seats do
      if not next and not state.teams[other].out and not state.teams[other].class then
        next = other
      end
    end
    if next then
      state.turn = next
    else
      state.picking = false
      state.turn = nextSeat(state, 0) or 1
      count(state)
    end
    return { class = class, notation = class, team = seat }
  end

  local before = Tables.Copy(state)
  local slot, inputs = decode(move)
  local sim = play(state, slot, inputs)

  -- The state is the engine's: the sim's copy is put back into it
  for key in pairs(state) do
    state[key] = nil
  end
  for key, value in pairs(sim.state) do
    state[key] = value
  end

  local event = { before = before, slot = slot, inputs = inputs, passed = sim.passed, team = seat }
  local kept = films[state] or {}
  films[state] = kept
  kept[#kept + 1] = event
  if #kept > state.seats + 1 then
    table.remove(kept, 1).before = nil
  end
  return event
end

--- How the game ended, for the engine: by seat, and alone either won or not
--- @param state WormcraftState
--- @return { winner: number, detail: string? }?
local function result(state)
  local outcome = state.outcome
  if outcome and state.alone then
    return { winner = outcome.winner == 1 and 1 or 0, detail = outcome.winner == 1 and "last" or (outcome.winner == 0 and "nobody" or "beaten") }
  end
  return outcome
end

--- A player resigned: their squad is gone
--- @param state WormcraftState
--- @param seat number
local function drop(state, seat)
  local team = state.teams[seat]
  team.out = true
  for _, unit in ipairs(state.units) do
    if unit.team == seat then
      unit.alive, unit.hp = false, 0
    end
  end
  if state.picking then
    if state.turn == seat then
      local next = nil
      for other = 1, state.seats do
        if not next and not state.teams[other].out and not state.teams[other].class then
          next = other
        end
      end
      if next then
        state.turn = next
      else
        state.picking = false
        state.turn = nextSeat(state, 0) or 1
      end
    end
    return
  end
  if state.turn == seat then
    count(state)
    if not state.outcome then
      state.turn = nextSeat(state, seat) or seat
    end
  end
end

-- Everything a squad can have, in the order a list of moves goes through them: what is learned
-- and found, then what a class has of its own
local EVERY_WEAPON = { unpack(ARSENAL) }
EVERY_WEAPON[#EVERY_WEAPON + 1] = "rs"
for _, class in ipairs(CLASS_ORDER) do
  EVERY_WEAPON[#EVERY_WEAPON + 1] = CLASSES[class].signature
end

--- A few of the turns a squad could have, nothing like all of them: the turn passed where they
--- stand, or after a walk and a jump, and every weapon they have fired a few ways, from where
--- they stand and from a little way off, at the others where it is aimed at a place. Alone,
--- the player makes the computer's turns too, so it is whoever's turn it is
--- @param state WormcraftState
--- @param seat number
--- @return string[]
local function moves(state, seat)
  local list, listed = {}, {}
  local function offer(move)
    if not listed[move] and validate(state, seat, move) then
      listed[move] = true
      list[#list + 1] = move
    end
  end
  local team = state.turn
  if state.picking then
    for _, class in ipairs(CLASS_ORDER) do
      offer(CLASS .. class)
    end
    return list
  end

  local arsenal = state.teams[team].arsenal
  local squad = squadOf(state, team)
  for slot = 1, state.squad do
    local unit = squad[slot]
    if unit and unit.alive then
      local x, y = div(unit.x, SUB), div(unit.y, SUB)
      offer(slot .. "S")
      offer(slot .. "R30JS")
      offer(slot .. "L30BS")
      -- Where the others are, for whatever comes down on a place
      local targets = {}
      for _, other in ipairs(state.units) do
        if other.alive and other.team ~= team then
          targets[#targets + 1] = { clamp(div(other.x, SUB), 0, WIDTH - 1), clamp(div(other.y, SUB) - 40, 0, HEIGHT - 1) }
        end
      end
      for _, id in ipairs(EVERY_WEAPON) do
        local had, weapon = arsenal[id], WEAPONS[id]
        if had and had ~= 0 then
          local aims = {}
          if weapon.aim == "none" then
            aims = { "" }
          elseif weapon.aim == "angle" then
            aims = { ".0", ".180", ".45" }
          elseif weapon.aim == "power" then
            aims = { ".45.70", ".135.70", ".60.40" }
          elseif weapon.aim == "fuse" then
            aims = { ".45.60.3", ".135.60.2" }
          elseif weapon.kind == "teleport" then
            -- Not too far for a blink
            aims = { "." .. clamp(x + 80, 0, WIDTH - 1) .. "." .. clamp(y - 20, 0, HEIGHT - 1), "." .. clamp(x - 80, 0, WIDTH - 1) .. "." .. clamp(y - 20, 0, HEIGHT - 1) }
            if not weapon.range then
              for _, target in ipairs(targets) do
                aims[#aims + 1] = "." .. target[1] .. "." .. target[2]
              end
            end
          else
            for _, target in ipairs(targets) do
              aims[#aims + 1] = "." .. target[1]
            end
          end
          for _, aim in ipairs(aims) do
            if weapon.utility then
              -- It doesn't end the turn, so something has to
              offer(slot .. "U" .. id .. aim .. "S")
              offer(slot .. "U" .. id .. aim .. "R20S")
            elseif weapon.kind == "sheep" then
              offer(slot .. "F" .. id .. aim .. "W30X")
            else
              offer(slot .. "F" .. id .. aim)
              offer(slot .. "R24F" .. id .. aim .. "L15")
            end
          end
        end
      end
    end
  end
  return list
end

-----------------------------
-- The computer
-----------------------------
-- A squad of the computer's makes its moves the way a player would if they could try every shot
-- first and see where it lands: it plays shots out on a copy of the island, the same way the
-- turn will be played out, and picks the one that does the most harm to the others and the
-- least to itself. How good it is (SKILLS) is how many it tries and how well it aims what it
-- picked: the easiest only ever throws fireballs and grenades and arrows, from where it stands,
-- and its hand shakes. Its moves are written down like any other, so nothing it does is ever
-- worked out again: the engine has it think them through (COMPUTER below), or in a game played
-- alone from before, the view does.
--
-- It thinks a few hundred ticks at a time (Brain:Think), so that it can be spread over frames.
-- Nothing in here needs to come out the same on another client: the move does, and only the
-- move is kept.

--- How good a computer squad is. `kinds` is what it fires, `angles` what it tries to lob things
--- at, `halvings` how closely it works out the power for one, `targets` how many of the nearest
--- of the others it aims at, `walks` where it tries going first, and the rest how much it misses
--- by: up to so many degrees and so much power either way, and from how many of the best it
--- picks one
local SKILLS = {
  easy = { kinds = { shell = true, grenade = true, shot = true }, angles = { 35, 55 }, halvings = 5, targets = 1, walks = { 0 }, wobble = 7, push = 14, among = 3, everyone = false },
  medium = { kinds = { shell = true, grenade = true, shot = true, chain = true, melee = true, drain = true, dash = true, strike = true, kodo = true, sheep = true, heal = true }, angles = { 25, 45, 65 }, halvings = 7, targets = 2, walks = { 0 }, wobble = 2, push = 5, among = 1, everyone = false },
  hard = { kinds = { shell = true, grenade = true, shot = true, chain = true, melee = true, drain = true, dash = true, strike = true, kodo = true, sheep = true, heal = true, charge = true, shield = true }, angles = { 20, 40, 58, 75 }, halvings = 6, targets = 2, walks = { 0, -45, 45 }, wobble = 0, push = 1, among = 1, everyone = true },
}
local SKILL_ORDER = { "easy", "medium", "hard" }
-- What a round of its thinking counts as to the engine: reason enough to look at the clock
local CLOCK_TICKS = 4
-- How long it looks as though it aims before it fires, and how many ticks it plays out at a time
local PONDER, THOUGHT = 20, 600

--- @class WormcraftBrain
--- @field state WormcraftState
--- @field skill table
--- @field seat number
--- @field dice Random Where its hand shakes to
--- @field work number Ticks played out since it last stopped to let a frame by
--- @field move string? What it decided on, once it has
local Brain = {}
Brain.__index = Brain

--- @param state WormcraftState Whose turn it is is the computer's
--- @param skill string? How good it is, the skill a game played alone was set up with if left out
--- @return WormcraftBrain
function Brain.New(state, skill)
  local self = setmetatable({ state = state, seat = state.turn, skill = SKILLS[skill or state.skill] or SKILLS.medium, work = 0 }, Brain)
  self.dice = private.Random.New(private.Random.Stir(state.seed, "brain" .. state.turns))
  self.thread = coroutine.create(function()
    return self:decide()
  end)
  return self
end

--- Thinks for a while. Returns the move once it knows it
--- @return string?
function Brain:Think()
  if self.move then
    return self.move
  end
  local ok, move = coroutine.resume(self.thread)
  if not ok then
    -- Whatever went wrong, the turn is rested rather than the game stuck
    self.failed = move
    self.move = self.state.teams[self.seat].next .. "Frs"
  elseif coroutine.status(self.thread) == "dead" then
    self.move = move
  end
  return self.move
end

--- Thinks until it knows
--- @return string
function Brain:Decide()
  local move = nil
  while not move do
    move = self:Think()
  end
  return move
end

--- Plays a move out, and lets a frame by now and then
--- @param slot number
--- @param inputs table[]
--- @param stop (fun(sim: WormcraftSim): boolean)?
--- @return WormcraftSim
function Brain:try(slot, inputs, stop)
  local sim = play(self.state, slot, inputs, stop ~= nil, stop)
  self.work = self.work + sim.ticks
  if self.work >= THOUGHT and coroutine.running() then
    self.work = 0
    coroutine.yield()
  end
  return sim
end

--- How good what happened was for the computer: what the others lost, and what it did
--- @param sim WormcraftSim
--- @return number
function Brain:worth(sim)
  local worth = 0
  for index, unit in ipairs(self.state.units) do
    local after = sim.state.units[index]
    if unit.alive then
      local lost = unit.hp - after.hp
      if unit.team == self.seat then
        worth = worth - lost * 1.5 - (after.alive and 0 or 60)
      else
        worth = worth + lost + (after.alive and 0 or 40)
      end
    end
  end
  return worth
end

--- Where a shot first goes off, when the squad member who fires it has done what they do first
--- @param slot number
--- @param before table[]
--- @param input WormcraftInput
--- @return number? x In units, nil if it went nowhere
function Brain:landing(slot, before, input)
  local inputs = { unpack(before) }
  inputs[#inputs + 1] = { input, 1 }
  local landed = nil
  self:try(slot, inputs, function(sim)
    for _, what in ipairs(sim.happened) do
      if what.kind == "boom" or what.kind == "splash" then
        landed = what.x / SUB
        return true
      end
    end
    sim.happened = {}
    return false
  end)
  return landed
end

--- Works out how hard to throw something at an angle to get it to a place
--- @param slot number
--- @param before table[]
--- @param weapon WormcraftWeapon
--- @param angle number
--- @param x number Where it should come down, in units
--- @param from number Where it is thrown from
--- @return WormcraftInput
function Brain:lob(slot, before, weapon, angle, x, from)
  local low, high, way = 1, 100, x >= from and 1 or -1
  local function input(power)
    local args = { angle, power }
    if weapon.aim == "fuse" then
      args[3] = 3
    end
    return { use = weapon.id, args = args, fire = true }
  end
  for _ = 1, self.skill.halvings do
    local power = div(low + high, 2)
    local landed = self:landing(slot, before, input(power))
    if landed and (landed - x) * way > 0 then
      high = power
    else
      low = power
    end
  end
  return input(div(low + high, 2))
end

--- Everything worth trying for one of the squad from where they stand after `before`
--- @param slot number
--- @param before table[]
--- @param unit WormcraftUnit Where they are by then
--- @return WormcraftInput[] candidates, table<WormcraftInput, table[]> after What to do after firing each
function Brain:options(slot, before, unit)
  local skill, team = self.skill, self.state.teams[self.seat]
  local x, y = unit.x / SUB, unit.y / SUB - TALL / 2
  -- The others, nearest first
  local others = {}
  for _, other in ipairs(self.state.units) do
    if other.alive and other.team ~= self.seat then
      others[#others + 1] = other
    end
  end
  table.sort(others, function(a, b)
    return math.abs(a.x - unit.x) < math.abs(b.x - unit.x)
  end)
  local targets = {}
  for index = 1, math.min(skill.targets, #others) do
    targets[index] = others[index]
  end
  if not skill.everyone and #others > 0 then
    -- Not always the nearest: anybody at all, for one that doesn't think hard
    targets[1] = others[self.dice:Roll(#others)]
  end

  local found = {}
  local function add(input)
    found[#found + 1] = input
  end
  local hurt = 0
  for _, mate in ipairs(squadOf(self.state, self.seat)) do
    hurt = hurt + (mate.alive and math.max(0, self.state.health - mate.hp) or 0)
  end
  local ids = {}
  for id, charges in pairs(team.arsenal) do
    if charges ~= 0 and skill.kinds[WEAPONS[id].kind] then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local weapon = WEAPONS[id]
    local kind = weapon.kind
    for _, target in ipairs(targets) do
      local tx, ty = target.x / SUB, target.y / SUB - TALL / 2
      if kind == "shell" or kind == "grenade" then
        for _, elevation in ipairs(skill.angles) do
          local angle = tx >= x and elevation or 180 - elevation
          add(self:lob(slot, before, weapon, angle, tx, x))
        end
      elseif kind == "shot" or kind == "chain" then
        local angle = math.floor(math.deg(math.atan2(y - ty, tx - x)) + 0.5) % 360
        add({ use = id, args = { angle }, fire = true })
      elseif (kind == "melee" or kind == "dash") and math.abs(tx - x) < (kind == "dash" and 90 or 20) then
        add({ use = id, args = {}, fire = true, face = tx >= x and 1 or -1 })
      elseif kind == "strike" and not weapon.anywhere or kind == "kodo" then
        add({ use = id, args = { clamp(math.floor(tx), 0, WIDTH - 1) }, fire = true })
      elseif kind == "sheep" and math.abs(tx - x) < 160 then
        add({ use = id, args = {}, fire = true, face = tx >= x and 1 or -1, blow = clamp(math.floor(math.abs(tx - x) * 2), 10, RETREAT * TPS - 2) })
      elseif kind == "charge" and math.abs(tx - x) < 24 then
        add({ use = id, args = {}, fire = true, flee = tx >= x and -1 or 1 })
      end
    end
    if kind == "drain" then
      add({ use = id, args = {}, fire = true })
    elseif kind == "strike" and weapon.anywhere then
      add({ use = id, args = {}, fire = true })
    elseif kind == "heal" and hurt >= 40 then
      add({ use = id, args = {}, fire = false, first = true })
    elseif kind == "shield" and unit.hp < self.state.health / 2 then
      add({ use = id, args = {}, fire = false, first = true })
    end
  end
  return found
end

--- What it would be to do: the move, as runs of inputs
--- @param before table[] Walking first
--- @param choice table What is fired, and how
--- @param after table[]? Running after
--- @param unit WormcraftUnit
--- @return table[]
local function movement(before, choice, after, unit)
  local inputs = { unpack(before) }
  if choice.face and choice.face ~= unit.facing then
    -- A step the other way, to face whoever it is
    inputs[#inputs + 1] = { choice.face > 0 and "R" or "L", 1 }
  end
  inputs[#inputs + 1] = { false, PONDER }
  inputs[#inputs + 1] = { { use = choice.use, args = choice.args, fire = choice.fire }, 1 }
  if choice.blow then
    inputs[#inputs + 1] = { false, choice.blow }
    inputs[#inputs + 1] = { "X", 1 }
  elseif choice.flee then
    inputs[#inputs + 1] = { choice.flee > 0 and "R" or "L", RETREAT * TPS - 2 }
  end
  for _, run in ipairs(after or {}) do
    inputs[#inputs + 1] = run
  end
  return inputs
end

--- Writes inputs down as a move
--- @param slot number
--- @param inputs table[]
--- @return string
local function spell(slot, inputs)
  local parts = { tostring(slot) }
  for _, run in ipairs(inputs) do
    local what, ticks = run[1], run[2]
    if type(what) == "table" then
      local text = (what.fire and "F" or "U") .. what.use
      for _, arg in ipairs(what.args) do
        text = text .. "." .. arg
      end
      parts[#parts + 1] = text
    elseif what == "J" or what == "B" or what == "X" or what == "S" then
      parts[#parts + 1] = what
    elseif ticks > 0 then
      parts[#parts + 1] = (what or "W") .. ticks
    end
  end
  return table.concat(parts)
end

--- Thinks it all through
--- @return string move
function Brain:decide()
  local state, skill = self.state, self.skill
  local team = state.teams[self.seat]
  local slots = {}
  if skill.everyone then
    for slot, unit in pairs(squadOf(state, self.seat)) do
      if unit.alive then
        slots[#slots + 1] = slot
      end
    end
    table.sort(slots)
  else
    slots[1] = team.next
  end

  --- @type { worth: number, slot: number, inputs: table[], before: table[], choice: table, unit: WormcraftUnit }[]
  local tried = {}
  for _, slot in ipairs(slots) do
    for _, walk in ipairs(skill.walks) do
      local before = walk ~= 0 and { { walk > 0 and "R" or "L", math.abs(walk) } } or {}
      -- Where they are once they have walked there
      local unit = squadOf(state, self.seat)[slot]
      if walk ~= 0 then
        local walked = self:try(slot, before, function(sim)
          return sim.ticks >= math.abs(walk)
        end)
        unit = walked.unit
      end
      if unit.alive and not unit.air then
        for _, choice in ipairs(self:options(slot, before, unit)) do
          if choice.first then
            -- Something that leaves the turn going, and then whatever is best after it
            local used = { unpack(before) }
            used[#used + 1] = { { use = choice.use, args = {}, fire = false }, 1 }
            for _, then_ in ipairs(self:options(slot, used, unit)) do
              if not then_.first then
                local inputs = movement(used, then_, nil, unit)
                tried[#tried + 1] = { worth = self:worth(self:try(slot, inputs)) + 10, slot = slot, inputs = inputs, before = used, choice = then_, unit = unit }
              end
            end
          else
            local inputs = movement(before, choice, nil, unit)
            tried[#tried + 1] = { worth = self:worth(self:try(slot, inputs)), slot = slot, inputs = inputs, before = before, choice = choice, unit = unit }
          end
        end
      end
    end
  end
  table.sort(tried, function(a, b)
    return a.worth > b.worth
  end)
  local best = tried[math.min(#tried, self.dice:Roll(skill.among))]
  if not best or best.worth < 0 then
    -- Nothing it could do would do it any good
    return team.next .. "W" .. PONDER .. "Frs"
  end

  -- Then, as good as it is at aiming, its hand shakes
  local choice = best.choice
  local args = { unpack(choice.args) }
  local weapon = WEAPONS[choice.use]
  if weapon.aim == "angle" or weapon.aim == "power" or weapon.aim == "fuse" then
    args[1] = (args[1] + self.dice:Roll(skill.wobble * 2 + 1) - skill.wobble - 1) % 360
  end
  if weapon.aim == "power" or weapon.aim == "fuse" then
    args[2] = clamp(args[2] + self.dice:Roll(skill.push * 2 + 1) - skill.push - 1, 1, 100)
  end
  local shaken = { use = choice.use, args = args, fire = choice.fire, face = choice.face, blow = choice.blow, flee = choice.flee }

  -- And it gets out of the way, if there is a way that is better than standing there
  local inputs, worth = movement(best.before, shaken, nil, best.unit), nil
  if not choice.flee and not choice.blow and skill.among == 1 then
    worth = self:worth(self:try(best.slot, inputs))
    for _, way in ipairs({ "L", "R" }) do
      local running = movement(best.before, shaken, { { way, RETREAT * TPS - 2 } }, best.unit)
      local ran = self:worth(self:try(best.slot, running))
      if ran > worth then
        inputs, worth = running, ran
      end
    end
  end
  return spell(best.slot, inputs)
end

-- What the engine's computer knows about Wormcraft: everything of it is in the brain. Its levels
-- are the brain's skills, and it picks a class at random. A turn is never taken back, the wind
-- and the crates would come out another way
local COMPUTER = {
  takeback = false,
  pause = 0.8,
  think = function(seen, seat, brain)
    if seen.picking then
      return CLASS .. CLASS_ORDER[brain.random:Roll(#CLASS_ORDER)]
    end
    local squad = Brain.New(seen, brain.level.skill)
    while true do
      local move = squad:Think()
      if move then
        return move
      end
      -- Its own thinking goes a few hundred ticks at a time: this is where a frame goes by
      brain:Spend(CLOCK_TICKS)
    end
  end,
  levels = { easy = { skill = "easy" }, medium = { skill = "medium" }, hard = { skill = "hard" } },
}

-- For the view and the tests
private.Wormcraft = {
  Sim = Sim,
  WEAPONS = WEAPONS,
  ARSENAL = ARSENAL,
  CLASSES = CLASSES,
  CLASS_ORDER = CLASS_ORDER,
  LEVELS = LEVELS,
  LOOT = LOOT,
  THEMES = THEMES,
  WIDTH = WIDTH,
  HEIGHT = HEIGHT,
  COLUMN = COLUMN,
  SUB = SUB,
  TPS = TPS,
  TALL = TALL,
  RETREAT = RETREAT,
  LONGEST = LONGEST,
  LAUNCH = LAUNCH,
  GRAVITY = GRAVITY,
  WIND_PULL = WIND_PULL,
  TEAM_COLORS = TEAM_COLORS,
  sine = sine,
  cosine = cosine,
  solid = solidIn,
  squadOf = squadOf,
  copy = Tables.Copy,
  decode = decode,
  newState = newState,
  validate = validate,
  result = result,
  Brain = Brain,
  SKILL_ORDER = SKILL_ORDER,
  apply = apply,
  drop = drop,
  films = films,
}

-----------------------------
-- View
-----------------------------
-- The island fits the window, in a viewport (GUI/Viewport.lua) that the wheel zooms in on and the
-- mouse drags about, and that follows whatever is going on while it is zoomed in. Everything on
-- it is placed at its units times `scale`. What is shown is always a state: the match's own, or
-- the copy a Sim plays a turn out in. That is how a turn the player is making is shown while it
-- is made, and how the turns the others made since the player last looked are played out again
-- for them, one after the other (`queue`). A turn is only sent once it is over, so a turn that
-- isn't finished when the game is left is begun again.
--
-- Over the island: whose turn it is, how long is left of it, the wind, and the round. Under it,
-- what the squad has to fire, by icon, with how many are left.

local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\Wormcraft\\"
local SPRITES = IMAGES .. "sprites"
local GLOW = "Interface\\AddOns\\ForeverGames\\Images\\glow"
local ICONS = "Interface\\Icons\\"
local FLAT = "Interface\\Buttons\\WHITE8X8"
local CLASS_PICTURES = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"
-- The sheet is this many pictures each way (Tools/make_wormcraft.py), and where each is in it
local SHEET = 8
local PICTURES = {
  WARRIOR = { 0, 0 }, PALADIN = { 2, 0 }, HUNTER = { 4, 0 }, ROGUE = { 6, 0 },
  PRIEST = { 0, 1 }, SHAMAN = { 2, 1 }, MAGE = { 4, 1 }, WARLOCK = { 6, 1 },
  DRUID = { 0, 2 }, RECRUIT = { 2, 2 }, grave = { 4, 2 }, health = { 5, 2 }, crate = { 6, 2 }, trap = { 7, 2 },
  fb = { 0, 3 }, gr = { 1, 3 }, tg = { 2, 3 }, hg = { 3, 3 }, charge = { 4, 3 }, sheep = { 5, 3 }, bomblet = { 7, 3 },
  shard = { 0, 4 }, flame = { 1, 4 }, meteor = { 2, 4 }, kodo = { 3, 4 }, crosshair = { 4, 4 },
}
-- How big things are drawn, in units: bigger than they are, so that they can be seen
local DRAWN = { unit = 22, small = 12, kodo = 40, meteor = 22, crosshair = 12 }
local TEAM_RGB = {
  red = { 1, 0.35, 0.3 },
  blue = { 0.4, 0.62, 1 },
  green = { 0.4, 0.9, 0.4 },
  yellow = { 1, 0.86, 0.25 },
}
-- The colours of loot by how rare it is, as the client shows them
local RARITY_RGB = {
  health = { 1, 0.35, 0.35 },
  uncommon = { 0.12, 1, 0 },
  rare = { 0, 0.44, 0.87 },
  epic = { 0.64, 0.21, 0.93 },
  legendary = { 1, 0.5, 0 },
}
local SEA_RGB = { 0.1, 0.28, 0.52 }
local HUD_HEIGHT, BAR_HEIGHT, SLOT_SIZE, SLOT_GAP = 24, 44, 34, 3
local WIND_WIDTH = 120
-- How close the view goes to whoever's turn it is, how close it can go, and how fast it follows
local FOLLOW_ZOOM, MAX_ZOOM, FOLLOW_SPEED = 2.2, 4, 5
-- How far the crosshair is from the middle of a unit, how fast the aim turns in degrees a tick,
-- and how many ticks it takes to get to full power
local CROSSHAIR, AIM_STEP, CHARGE_TICKS = 28, 1, 36
-- How long the computer may think for in a frame, in milliseconds, and how long it looks as though
-- it thinks at least, in seconds
local THINK_MS, PONDER_SECONDS = 10, 0.8
-- Ticks of a turn played out again in a frame at most, and how many times as fast as it was made
local MOST_TICKS, REPLAY_SPEED = 6, 1.5
-- What a move may be at most, keeping some back for what still has to go in it
local ROOM_TO_WALK, ROOM_TO_FIRE = LONGEST - 40, LONGEST - 14
local KEYS = {
  LEFT = "left", A = "left", RIGHT = "right", D = "right", UP = "up", W = "up", DOWN = "down", S = "down",
  SPACE = "fire", ENTER = "jump", BACKSPACE = "flip", TAB = "next", Q = "previous", E = "following",
}
local SOUNDS = { boom = "dieThrow", fire = "IG_ABILITY_ICON_DROP", take = "IG_BACKPACK_OPEN", die = "IG_QUEST_FAILED", level = "LEVELUP", turn = "READY_CHECK" }

--- @class WormcraftLive The turn the player is making
--- @field sim WormcraftSim
--- @field slot number
--- @field started boolean The clock is going: something was done
--- @field tokens string[] What was done so far, written down
--- @field run string? What the last ticks were spent doing: "R", "L" or "W"
--- @field ticks number And for how many
--- @field pending (string|WormcraftInput)[] What is to happen in the next ticks, one each
--- @field charging number? The power the shot will have, while it is wound up
--- @field submitted boolean

--- @class WormcraftReplay A turn somebody else made, played out again
--- @field sim WormcraftSim
--- @field event table
--- @field index number Which of its inputs is next
--- @field left number Ticks still to go of it

--- @class WormcraftView: GameViewObject
local View = {}
View.__index = View

--- @param class string
--- @return string
local function className(class)
  return LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class] or L["warcraftstein_class_" .. class]
end

--- @param class string
--- @return number[]
local function classColor(class)
  local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
  return color and { color.r, color.g, color.b } or CLASSES[class].color
end

--- The class of the character the player is on, or a warrior
--- @return string
local function ownClass()
  local class = UnitClass and select(2, UnitClass("player"))
  return CLASSES[class] and class or "WARRIOR"
end

--- Shows a picture of the sheet on a texture
--- @param texture Texture
--- @param picture number[]
--- @param flipped boolean? Facing left
local function showPicture(texture, picture, flipped)
  local left, top = picture[1] / SHEET, picture[2] / SHEET
  local right, bottom = left + 1 / SHEET, top + 1 / SHEET
  if flipped then
    left, right = right, left
  end
  texture:SetTexCoord(left, right, top, bottom)
end

--- A square button with an icon in it
--- @param parent Frame
--- @param size number
--- @return Button
local function createSlot(parent, size)
  local button = private.Widgets.Panel(parent, "Button")
  button:SetSize(size, size)
  button.icon = button:CreateTexture(nil, "ARTWORK")
  button.icon:SetPoint("TOPLEFT", 2, -2)
  button.icon:SetPoint("BOTTOMRIGHT", -2, 2)
  button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  local hover = button:CreateTexture(nil, "HIGHLIGHT")
  hover:SetAllPoints()
  hover:SetColorTexture(1, 0.82, 0, 0.2)
  button.count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  button.count:SetPoint("BOTTOMRIGHT", -2, 2)
  return button
end

--- @param stage Frame
--- @return WormcraftView
local function createView(stage)
  local Widgets = private.Widgets
  local self = setmetatable({ stage = stage, scale = 1, queue = {}, choices = {}, fx = {}, pools = {}, held = {}, wasAt = {} }, View)
  self.width, self.height = 0, 0

  local viewport = private.Viewport.New(stage, {
    maxZoom = MAX_ZOOM,
    onSettle = function(zoom)
      self:sizeLabels(zoom)
    end,
  })
  self.viewport = viewport
  local world = viewport.content
  world:EnableMouse(true)
  self.world = world
  -- For whoever finds the frame and wants to know what is on it
  world.wormcraft = self
  self.sky = world:CreateTexture(nil, "BACKGROUND")
  self.sky:SetAllPoints()
  self.sea = world:CreateTexture(nil, "OVERLAY", nil, -2)
  self.sea:SetColorTexture(SEA_RGB[1], SEA_RGB[2], SEA_RGB[3], 0.78)
  self.surf = world:CreateTexture(nil, "OVERLAY", nil, -1)
  self.surf:SetColorTexture(0.6, 0.8, 1, 0.55)
  self.ground, self.edges, self.units, self.labels, self.things = {}, {}, {}, {}, {}
  self.crosshair = world:CreateTexture(nil, "OVERLAY", nil, 3)
  self.crosshair:SetTexture(SPRITES)
  showPicture(self.crosshair, PICTURES.crosshair)
  self.crosshair:Hide()
  self.gauge = world:CreateLine(nil, "OVERLAY", nil, 2)
  self.gauge:SetColorTexture(1, 0.6, 0.1, 0.9)
  self.gauge:Hide()

  world:SetScript("OnMouseDown", function(_, button)
    if not self:click(button) then
      viewport:Grab(button)
    end
  end)

  -- Keys, while the cursor is over the game
  local ticker = CreateFrame("Frame", nil, stage)
  ticker:SetAllPoints()
  self.ticker = ticker
  Widgets.Keys(ticker, function(key)
    return self:press(key)
  end)
  ticker:SetScript("OnKeyUp", function(_, key)
    self:release(key)
  end)
  ticker:SetScript("OnHide", function()
    self.held = {}
  end)
  ticker:SetScript("OnUpdate", function(_, elapsed)
    self:advance(elapsed)
  end)

  -- Over the island
  local hud = CreateFrame("Frame", nil, stage)
  hud:SetHeight(HUD_HEIGHT)
  self.hud = hud
  self.status = hud:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  self.status:SetPoint("LEFT", 4, 0)
  self.status:SetJustifyH("LEFT")
  self.clock = hud:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  self.clock:SetPoint("LEFT", self.status, "RIGHT", 10, 0)
  self.round = hud:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  self.round:SetPoint("RIGHT", -4, 0)
  local wind = Widgets.Panel(hud)
  wind:SetSize(WIND_WIDTH, 12)
  wind:SetPoint("CENTER", hud, "CENTER", 0, 0)
  wind.fill = wind:CreateTexture(nil, "ARTWORK")
  wind.fill:SetHeight(8)
  wind.label = hud:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  wind.label:SetPoint("RIGHT", wind, "LEFT", -6, 0)
  wind.label:SetText(L["wormcraft_wind"])
  self.wind = wind

  -- Under it
  local bar = CreateFrame("Frame", nil, stage)
  bar:SetHeight(BAR_HEIGHT)
  self.bar = bar
  self.slots = {}
  self.hint = bar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  self.hint:SetJustifyH("RIGHT")
  self.hint:SetJustifyV("MIDDLE")

  -- On the island, but not in it: who is left of every squad, and what is said
  self.squads = {}
  for seat = 1, 4 do
    local row = CreateFrame("Frame", nil, viewport.frame)
    row:SetSize(150, 14)
    row:SetPoint("BOTTOMLEFT", 6, 6 + (4 - seat) * 16)
    row:SetFrameLevel(viewport.frame:GetFrameLevel() + 5)
    row.back = row:CreateTexture(nil, "BACKGROUND")
    row.back:SetPoint("TOPLEFT", 64, -2)
    row.back:SetPoint("BOTTOMRIGHT", 0, 2)
    row.back:SetColorTexture(0, 0, 0, 0.55)
    row.fill = row:CreateTexture(nil, "ARTWORK")
    row.fill:SetPoint("TOPLEFT", row.back, "TOPLEFT")
    row.fill:SetPoint("BOTTOMLEFT", row.back, "BOTTOMLEFT")
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT")
    row.name:SetWidth(60)
    row.name:SetJustifyH("LEFT")
    row:Hide()
    self.squads[seat] = row
  end
  self.said = viewport.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  self.said:SetPoint("TOP", 0, -10)
  self.said:Hide()
  self.saidLeft = 0

  self:createPicker()
  self.effects = private.Effects.New(stage)
  return self
end

--- Builds where a class is picked: a button for every class, over the island
function View:createPicker()
  local picker = CreateFrame("Frame", nil, self.viewport.frame)
  picker:SetAllPoints()
  picker:SetFrameLevel(self.viewport.frame:GetFrameLevel() + 8)
  picker:EnableMouse(true)
  local shade = picker:CreateTexture(nil, "BACKGROUND")
  shade:SetAllPoints()
  shade:SetColorTexture(0, 0, 0, 0.6)
  local row = CreateFrame("Frame", nil, picker)
  row:SetSize(#CLASS_ORDER * 44 - 6, 38)
  row:SetPoint("CENTER")
  picker.row = row
  picker.title = picker:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  picker.title:SetPoint("BOTTOM", row, "TOP", 0, 14)
  picker.detail = picker:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  picker.detail:SetPoint("TOP", row, "BOTTOM", 0, -14)
  picker.detail:SetWidth(380)
  self.picks = {}
  for index, class in ipairs(CLASS_ORDER) do
    local pick = createSlot(row, 38)
    pick:SetPoint("LEFT", (index - 1) * 44, 0)
    local where = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if where then
      pick.icon:SetTexture(CLASS_PICTURES)
      pick.icon:SetTexCoord(where[1], where[2], where[3], where[4])
    else
      pick.icon:SetTexture(ICONS .. WEAPONS[CLASSES[class].signature].icon)
    end
    pick:SetScript("OnClick", function()
      local view = self.view
      if view and view.canMove and view.state.picking then
        view.submit(CLASS .. class)
      end
    end)
    pick:SetScript("OnEnter", function(button)
      local own = WEAPONS[CLASSES[class].signature]
      local color = classColor(class)
      GameTooltip:SetOwner(button, "ANCHOR_TOP")
      GameTooltip:SetText(className(class), color[1], color[2], color[3])
      GameTooltip:AddLine(L["wormcraft_weapon_" .. own.id], 1, 0.82, 0)
      GameTooltip:AddLine(L["wormcraft_weapon_" .. own.id .. "_tip"], 1, 1, 1, true)
      GameTooltip:AddLine(L["wormcraft_charges"]:format(CLASSES[class].charges), 0.7, 0.7, 0.7)
      GameTooltip:Show()
    end)
    pick:SetScript("OnLeave", GameTooltip_Hide)
    self.picks[class] = pick
  end
  picker:Hide()
  self.picker = picker
end

-----------------------------
-- Drawing
-----------------------------

--- A region of a kind, made the first time it is asked for
--- @param name string Which pool
--- @param index number
--- @param make fun(): Region
--- @return Region
function View:pooled(name, index, make)
  local pool = self.pools[name] or {}
  self.pools[name] = pool
  if not pool[index] then
    pool[index] = make()
  end
  return pool[index]
end

--- Hides what is left of a pool after the first so many
--- @param name string
--- @param used number
function View:hideRest(name, used)
  for index, region in ipairs(self.pools[name] or {}) do
    if index > used then
      region:Hide()
    end
  end
end

--- Puts a region with its bottom middle at a place of the world
--- @param region Region
--- @param x number In units
--- @param y number
--- @param size number
function View:stand(region, x, y, size)
  local scale = self.scale
  region:ClearAllPoints()
  region:SetPoint("BOTTOM", self.world, "TOPLEFT", x * scale, -y * scale)
  region:SetSize(size * scale, size * scale)
end

--- Puts a region with its middle at a place of the world
function View:center(region, x, y, width, height)
  local scale = self.scale
  region:ClearAllPoints()
  region:SetPoint("CENTER", self.world, "TOPLEFT", x * scale, -y * scale)
  region:SetSize(width * scale, (height or width) * scale)
end

--- Draws the ground of the island
--- @param state WormcraftState
function View:drawGround(state)
  local scale, world = self.scale, self.world
  local theme = state.theme
  local rock, top = IMAGES .. theme, IMAGES .. theme .. "_edge"
  local used, edges = 0, 0
  for column, spans in ipairs(state.columns) do
    local left = (column - 1) * COLUMN
    for index = 1, #spans, 2 do
      local from, to = spans[index], math.min(spans[index + 1], HEIGHT)
      if to > from then
        used = used + 1
        local texture = self:pooled("ground", used, function()
          return world:CreateTexture(nil, "BORDER")
        end)
        if texture.theme ~= theme then
          texture.theme = theme
          texture:SetTexture(rock, "REPEAT", "REPEAT")
        end
        texture:ClearAllPoints()
        texture:SetPoint("TOPLEFT", world, "TOPLEFT", left * scale, -from * scale)
        texture:SetSize(COLUMN * scale, (to - from) * scale)
        texture:SetTexCoord(left / 128, (left + COLUMN) / 128, from / 128, to / 128)
        texture:Show()
        -- What grows on top of it, where nothing lies on top of that
        if index == 1 or spans[index - 1] < from - 4 then
          edges = edges + 1
          local edge = self:pooled("edges", edges, function()
            return world:CreateTexture(nil, "BORDER", nil, 1)
          end)
          if edge.theme ~= theme then
            edge.theme = theme
            edge:SetTexture(top, "REPEAT", "CLAMP")
          end
          edge:ClearAllPoints()
          edge:SetPoint("TOPLEFT", world, "TOPLEFT", left * scale, -(from - 7) * scale)
          edge:SetSize(COLUMN * scale, 14 * scale)
          edge:SetTexCoord(left / 128, (left + COLUMN) / 128, 0, 0.875)
          edge:Show()
        end
      end
    end
  end
  self:hideRest("ground", used)
  self:hideRest("edges", edges)
  if self.skyTheme ~= theme then
    self.skyTheme = theme
    self.sky:SetTexture(IMAGES .. theme .. "_sky")
  end
end

--- What a thing that flies or lies about looks like
--- @param body table
--- @return number[] picture, number size
local function lookOf(body)
  local kind = body.kind
  if kind == "crate" then
    return body.loot == "health" and PICTURES.health or PICTURES.crate, DRAWN.small
  elseif kind == "kodo" then
    return PICTURES.kodo, DRAWN.kodo
  elseif kind == "drop" then
    local picture = body.weapon.picture
    return PICTURES[picture], picture == "meteor" and DRAWN.meteor or DRAWN.small
  elseif kind == "shell" and body.bomblet then
    return PICTURES.bomblet, 8
  elseif kind == "sheep" then
    return { 5 + (div(body.age or 0, 6) % 2), 3 }, DRAWN.small + 2
  end
  local id = body.weapon and body.weapon.id
  return PICTURES[id] or PICTURES[kind] or PICTURES.bomblet, kind == "grave" and DRAWN.small + 2 or DRAWN.small
end

--- Draws everybody and everything on the island where they are now
--- @param state WormcraftState
--- @param sim WormcraftSim?
function View:drawBodies(state, sim)
  local world = self.world
  local going = sim and sim.unit
  for index, unit in ipairs(state.units) do
    local sprite = self:pooled("units", index, function()
      local texture = world:CreateTexture(nil, "ARTWORK", nil, 2)
      texture:SetTexture(SPRITES)
      return texture
    end)
    local label = self:pooled("labels", index, function()
      local text = world:CreateFontString(nil, "OVERLAY")
      text:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
      return text
    end)
    local aura = self:pooled("auras", index, function()
      local texture = world:CreateTexture(nil, "ARTWORK", nil, 1)
      texture:SetTexture(GLOW)
      texture:SetBlendMode("ADD")
      return texture
    end)
    if unit.alive then
      local x, y = unit.x / SUB, unit.y / SUB
      local class = state.teams[unit.team].class or "RECRUIT"
      local picture = PICTURES[class]
      -- A step every so often, while they go somewhere
      local stepping = self.wasAt[index] and self.wasAt[index] ~= unit.x and div(sim and sim.ticks or 0, 5) % 2 == 1
      self.wasAt[index] = unit.x
      showPicture(sprite, stepping and { picture[1] + 1, picture[2] } or picture, unit.facing < 0)
      self:stand(sprite, x, y + 1, DRAWN.unit)
      sprite:Show()
      local color = TEAM_RGB[TEAM_COLORS[unit.team]]
      label:SetText(unit.name .. "\n" .. unit.hp)
      label:SetTextColor(color[1], color[2], color[3])
      label:ClearAllPoints()
      label:SetPoint("BOTTOM", world, "TOPLEFT", x * self.scale, -(y - DRAWN.unit) * self.scale)
      label:Show()
      if unit.shield or unit == going then
        local tint = unit.shield and { 1, 0.85, 0.3 } or { 1, 1, 1 }
        aura:SetVertexColor(tint[1], tint[2], tint[3], unit.shield and 0.8 or 0.35)
        self:center(aura, x, y - TALL / 2, DRAWN.unit * 1.6)
        aura:Show()
      else
        aura:Hide()
      end
    else
      sprite:Hide()
      label:Hide()
      aura:Hide()
    end
  end

  local used = 0
  local function draw(body)
    used = used + 1
    local sprite = self:pooled("things", used, function()
      local texture = world:CreateTexture(nil, "ARTWORK", nil, 3)
      texture:SetTexture(SPRITES)
      return texture
    end)
    local glow = self:pooled("thingGlows", used, function()
      local texture = world:CreateTexture(nil, "ARTWORK", nil, 0)
      texture:SetTexture(GLOW)
      texture:SetBlendMode("ADD")
      return texture
    end)
    local picture, size = lookOf(body)
    showPicture(sprite, picture, (body.facing or 1) < 0)
    local x, y = body.x / SUB, body.y / SUB
    if body.kind == "crate" or body.kind == "grave" or body.kind == "trap" or body.kind == "charge" or body.kind == "sheep" or body.kind == "kodo" then
      self:stand(sprite, x, y + 1, size)
    else
      self:center(sprite, x, y, size)
    end
    sprite:Show()
    local rarity = body.kind == "crate" and RARITY_RGB[body.rarity]
    if rarity then
      glow:SetVertexColor(rarity[1], rarity[2], rarity[3], 0.9)
      self:center(glow, x, y - 5, size * 2)
      glow:Show()
    else
      glow:Hide()
    end
  end
  for _, body in ipairs(state.bodies) do
    draw(body)
  end
  for _, body in ipairs(sim and sim.moving or {}) do
    draw(body)
  end
  self:hideRest("things", used)
  self:hideRest("thingGlows", used)
end

--- Draws the sea, rising towards where it is if it has just risen
--- @param level number
function View:drawSea(level)
  local scale = self.scale
  self.seaLevel = level
  self.sea:ClearAllPoints()
  self.sea:SetPoint("TOPLEFT", self.world, "TOPLEFT", 0, -level * scale)
  self.sea:SetPoint("BOTTOMRIGHT")
  self.surf:ClearAllPoints()
  self.surf:SetPoint("TOPLEFT", self.world, "TOPLEFT", 0, -(level - 1) * scale)
  self.surf:SetSize(WIDTH * scale, 2 * scale)
end

--- The state on show, and the sim it is in if there is one
--- @return WormcraftState?, WormcraftSim?
function View:showing()
  local sim = (self.replay and self.replay.sim) or (self.live and self.live.sim)
  if sim then
    return sim.state, sim
  end
  return self.view and self.view.state, nil
end

--- Draws all of it again
function View:redraw()
  local state, sim = self:showing()
  if not state or self.scale <= 0 then
    return
  end
  self:drawGround(state)
  self:drawBodies(state, sim)
  self:drawSea(state.sea)
  self:aim()
end

--- Sizes the names over everybody so that they read the same at every zoom
--- @param zoom number
function View:sizeLabels(zoom)
  local size = math.max(5, math.floor(11 / zoom + 0.5))
  for _, label in ipairs(self.pools.labels or {}) do
    label:SetFont(STANDARD_TEXT_FONT, size, "OUTLINE")
  end
end

-----------------------------
-- What happens, shown
-----------------------------

--- Starts something that fades away: `step` is called with how far along it is, 0 to 1, every frame
--- @param seconds number
--- @param step fun(progress: number)
--- @param done fun()?
function View:fade(seconds, step, done)
  self.fx[#self.fx + 1] = { age = 0, life = seconds, step = step, done = done }
  step(0)
end

--- A glow that grows and fades
--- @param x number In units
--- @param y number
--- @param size number
--- @param color number[]
--- @param seconds number
function View:flare(x, y, size, color, seconds)
  local world = self.world
  local texture = nil
  for _, spare in ipairs(self.pools.flares or {}) do
    texture = texture or (not spare.busy and spare or nil)
  end
  if not texture then
    texture = world:CreateTexture(nil, "OVERLAY", nil, 1)
    texture:SetTexture(GLOW)
    texture:SetBlendMode("ADD")
    self.pools.flares = self.pools.flares or {}
    table.insert(self.pools.flares, texture)
  end
  texture.busy = true
  texture:SetVertexColor(color[1], color[2], color[3])
  texture:Show()
  self:fade(seconds, function(progress)
    self:center(texture, x, y, size * (0.6 + progress * 0.8))
    texture:SetAlpha(1 - progress)
  end, function()
    texture.busy = false
    texture:Hide()
  end)
end

--- Words that drift up from a place: what somebody lost or gained
--- @param text string
--- @param x number
--- @param y number
--- @param color number[]
function View:float(text, x, y, color)
  local label = nil
  for _, spare in ipairs(self.pools.floats or {}) do
    label = label or (not spare.busy and spare or nil)
  end
  if not label then
    label = self.world:CreateFontString(nil, "OVERLAY", nil)
    self.pools.floats = self.pools.floats or {}
    table.insert(self.pools.floats, label)
  end
  label.busy = true
  label:SetFont(STANDARD_TEXT_FONT, math.max(7, math.floor(14 / self.viewport.zoom)), "OUTLINE")
  label:SetText(text)
  label:SetTextColor(color[1], color[2], color[3])
  label:Show()
  self:fade(1.2, function(progress)
    label:ClearAllPoints()
    label:SetPoint("CENTER", self.world, "TOPLEFT", x * self.scale, -(y - 26 - progress * 18) * self.scale)
    label:SetAlpha(progress > 0.6 and (1 - progress) / 0.4 or 1)
  end, function()
    label.busy = false
    label:Hide()
  end)
end

--- A line between two places that fades: a shot, a bolt of lightning
function View:streak(fromX, fromY, toX, toY, color)
  local line = nil
  for _, spare in ipairs(self.pools.streaks or {}) do
    line = line or (not spare.busy and spare or nil)
  end
  if not line then
    line = self.world:CreateLine(nil, "OVERLAY", nil, 1)
    self.pools.streaks = self.pools.streaks or {}
    table.insert(self.pools.streaks, line)
  end
  line.busy = true
  line:SetColorTexture(color[1], color[2], color[3], 1)
  line:SetThickness(math.max(1, 1.5 * self.scale))
  line:SetStartPoint("TOPLEFT", self.world, fromX * self.scale, -fromY * self.scale)
  line:SetEndPoint("TOPLEFT", self.world, toX * self.scale, -toY * self.scale)
  line:Show()
  self:fade(0.45, function(progress)
    line:SetAlpha(1 - progress)
  end, function()
    line.busy = false
    line:Hide()
  end)
end

--- Says something across the top of the island for a while
--- @param text string
--- @param color number[]?
function View:say(text, color)
  color = color or private.Widgets.GOLD
  self.said:SetText(text)
  self.said:SetTextColor(color[1], color[2], color[3])
  self.said:SetAlpha(1)
  self.said:Show()
  self.saidLeft = 3
end

--- @param name string
function View:sound(name)
  private.Widgets.PlaySound(SOUNDS[name])
end

--- Shows what a sim says happened since it was last asked
--- @param sim WormcraftSim
function View:show(sim)
  local happened = sim.happened
  if not happened or #happened == 0 then
    return
  end
  sim.happened = {}
  local ground = false
  for _, what in ipairs(happened) do
    local kind = what.kind
    if kind == "boom" then
      ground = true
      local x, y = what.x / SUB, what.y / SUB
      self:flare(x, y, what.radius * 3.2, { 1, 0.55, 0.15 }, 0.55)
      self:flare(x, y, what.radius * 1.6, { 1, 0.95, 0.7 }, 0.3)
      self.effects:Jolt(self.viewport.frame, math.min(6, what.radius / 6))
      self:sound("boom")
    elseif kind == "dig" then
      ground = true
    elseif kind == "hurt" then
      self:float("-" .. what.amount, what.unit.x / SUB, what.unit.y / SUB, TEAM_RGB[TEAM_COLORS[what.unit.team]])
    elseif kind == "heal" then
      self:float("+" .. what.amount, what.unit.x / SUB, what.unit.y / SUB, private.Widgets.GREEN)
    elseif kind == "die" or kind == "drown" then
      self:say(L["wormcraft_" .. kind]:format(what.unit.name), TEAM_RGB[TEAM_COLORS[what.unit.team]])
      self:sound("die")
    elseif kind == "shot" then
      local color = what.chain and { 0.6, 0.8, 1 } or (what.drain and { 0.5, 1, 0.3 } or { 1, 0.95, 0.7 })
      self:streak(what.fromX / SUB, what.fromY / SUB, what.x / SUB, what.y / SUB, color)
    elseif kind == "blink" then
      self:flare(what.fromX / SUB, what.fromY / SUB - TALL / 2, 30, { 0.6, 0.5, 1 }, 0.5)
      self:flare(what.x / SUB, what.y / SUB - TALL / 2, 30, { 0.6, 0.5, 1 }, 0.5)
    elseif kind == "shield" or kind == "shift" then
      self:flare(what.unit.x / SUB, what.unit.y / SUB - TALL / 2, 40, kind == "shield" and { 1, 0.85, 0.3 } or { 1, 0.6, 0.1 }, 0.6)
    elseif kind == "take" then
      local color = RARITY_RGB[what.rarity] or private.Widgets.GOLD
      if what.loot ~= "health" then
        self:say(L["wormcraft_took"]:format(what.unit.name, L["wormcraft_weapon_" .. what.loot]), color)
      end
      self:sound("take")
      self.stale = true
    elseif kind == "splash" then
      self:flare(what.x / SUB, what.y / SUB, 18, { 0.5, 0.75, 1 }, 0.4)
    elseif kind == "fire" then
      self:sound("fire")
    end
  end
  if ground then
    self:drawGround(sim.state)
  end
  if self.stale then
    self.stale = nil
    self:refresh()
  end
end

--- Says what came between the turns: a level, a crate, the sea
--- @param passed table?
function View:between(passed)
  if not passed then
    return
  end
  if passed.level then
    local learned = {}
    for _, id in ipairs(ARSENAL) do
      if LEVELS[passed.level][id] then
        learned[#learned + 1] = L["wormcraft_weapon_" .. id]
      end
    end
    self:say(L["wormcraft_level"]:format(passed.level, table.concat(learned, ", ")))
    self:sound("level")
  elseif passed.rise then
    self:say(L["wormcraft_rise"], { 0.5, 0.75, 1 })
  end
  if passed.crate then
    local x, y = passed.crate.x / SUB, passed.crate.y / SUB
    self:flare(x, y - 5, 40, RARITY_RGB[passed.crate.rarity] or { 1, 1, 1 }, 0.9)
  end
end

-----------------------------
-- Aiming
-----------------------------

--- What the player has picked to fire, in the match on show
--- @return table choice weapon, elevation (degrees above level), fuse
function View:choice()
  local id = self.view and self.view.match.id or ""
  local choice = self.choices[id]
  if not choice then
    choice = { weapon = "fb", elevation = 30, fuse = 3 }
    self.choices[id] = choice
  end
  return choice
end

--- The angle a unit aims at: the elevation, on the side it faces
--- @param unit WormcraftUnit
--- @param elevation number
--- @return number
local function angleFor(unit, elevation)
  return (unit.facing > 0 and elevation or 180 - elevation) % 360
end

--- Shows where the player is aiming, if they are
function View:aim()
  local live = self.live
  local unit = live and live.sim.unit
  local choice = self:choice()
  local weapon = WEAPONS[choice.weapon]
  local aiming = unit and unit.alive and live.sim.phase == "aim" and weapon and (weapon.aim == "angle" or weapon.aim == "power" or weapon.aim == "fuse")
  if not aiming then
    self.crosshair:Hide()
    self.gauge:Hide()
    return
  end
  local angle = angleFor(unit, choice.elevation)
  local x, y = unit.x / SUB, unit.y / SUB - TALL / 2
  local cx, cy = x + cosine(angle) * CROSSHAIR / 1024, y - sine(angle) * CROSSHAIR / 1024
  self:center(self.crosshair, cx, cy, DRAWN.crosshair)
  self.crosshair:Show()
  if live.charging then
    local reach = CROSSHAIR * live.charging / 100
    local scale = self.scale
    self.gauge:SetThickness(math.max(2, 3 * scale))
    self.gauge:SetStartPoint("TOPLEFT", self.world, x * scale, -y * scale)
    self.gauge:SetEndPoint("TOPLEFT", self.world, (x + cosine(angle) * reach / 1024) * scale, -(y - sine(angle) * reach / 1024) * scale)
    self.gauge:SetColorTexture(1, 1 - live.charging / 130, 0.1, 0.9)
    self.gauge:Show()
  else
    self.gauge:Hide()
  end
end

--- Where the cursor is on the island, in units
--- @return number x, number y
function View:pointer()
  local viewport = self.viewport
  local x, y = viewport:cursor()
  return (x - viewport.x) / viewport.zoom / self.scale, (y - viewport.y) / viewport.zoom / self.scale
end

-----------------------------
-- Playing a turn
-----------------------------

--- Whether the player is making a turn that has begun, so the squad can't be changed any more
--- @return boolean
function View:going()
  return self.live ~= nil and self.live.started
end

--- Gets the player's turn ready, with whoever of the squad they want to go
--- @param slot number?
function View:ready(slot)
  local view = self.view
  local state = view.state
  slot = slot or state.teams[view.seat].next
  self.live = { sim = Sim.New(state, slot, true), slot = slot, started = false, tokens = {}, ticks = 0, pending = {}, submitted = false }
  local unit = self.live.sim.unit
  self.viewport:ZoomTo(math.max(self.viewport:goal(), FOLLOW_ZOOM), unit.x / SUB * self.scale, unit.y / SUB * self.scale)
  self:redraw()
end

--- What the move written so far would be
--- @param live WormcraftLive
--- @return string
local function written(live)
  local text = live.slot .. table.concat(live.tokens)
  if live.run then
    text = text .. live.run .. live.ticks
  end
  return text
end

--- Writes down what a tick of the turn was spent doing
--- @param live WormcraftLive
--- @param input string|WormcraftInput|nil
local function record(live, input)
  local function close()
    if live.run then
      live.tokens[#live.tokens + 1] = live.run .. live.ticks
      live.run, live.ticks = nil, 0
    end
  end
  if type(input) == "table" then
    close()
    local text = (input.fire and "F" or "U") .. input.use
    for _, arg in ipairs(input.args) do
      text = text .. "." .. arg
    end
    live.tokens[#live.tokens + 1] = text
  elseif input == "J" or input == "B" or input == "X" or input == "S" then
    close()
    live.tokens[#live.tokens + 1] = input
  else
    local letter = input or "W"
    if letter ~= live.run then
      close()
      live.run = letter
    end
    live.ticks = live.ticks + 1
  end
end

--- What the player does in the next tick of their turn, from what they pressed and hold
--- @param live WormcraftLive
--- @return string|WormcraftInput|nil
function View:intend(live)
  local sim = live.sim
  local long = #written(live)
  if #live.pending > 0 then
    local input = table.remove(live.pending, 1)
    -- Nothing that would make the move too long to send
    if type(input) == "table" or long < ROOM_TO_WALK then
      return input
    end
    return nil
  end
  local choice = self:choice()
  local held = self.held
  if sim.phase == "aim" then
    if held.up and not held.down then
      choice.elevation = math.min(90, choice.elevation + AIM_STEP)
    elseif held.down and not held.up then
      choice.elevation = math.max(-90, choice.elevation - AIM_STEP)
    end
    if live.charging then
      live.charging = math.min(100, live.charging + 100 / CHARGE_TICKS)
      if live.charging >= 100 then
        return self:shoot(live)
      end
      return nil
    end
  end
  local limit = sim.phase == "aim" and ROOM_TO_WALK or LONGEST - 8
  if long < limit or live.run == "R" or live.run == "L" then
    if held.left and not held.right then
      return "L"
    elseif held.right and not held.left then
      return "R"
    end
  end
  return nil
end

--- The shot the player has wound up, let go
--- @param live WormcraftLive
--- @return WormcraftInput?
function View:shoot(live)
  local choice = self:choice()
  local weapon = WEAPONS[choice.weapon]
  local unit = live.sim.unit
  local power = math.max(1, math.min(100, math.floor((live.charging or 100) + 0.5)))
  live.charging = nil
  local angle = angleFor(unit, choice.elevation)
  local args
  if weapon.aim == "power" then
    args = { angle, power }
  elseif weapon.aim == "fuse" then
    args = { angle, power, choice.fuse }
  elseif weapon.aim == "angle" then
    args = { angle }
  else
    args = {}
  end
  return { use = weapon.id, args = args, fire = not weapon.utility }
end

--- Starts the clock of the player's turn, if it hasn't been
function View:start()
  local live = self.live
  if live and not live.started then
    live.started = true
    self:refresh()
  end
end

--- Plays a tick of the player's turn
function View:tickLive()
  local live = self.live
  local sim = live.sim
  if sim.phase == "aim" or sim.phase == "retreat" then
    local input = self:intend(live)
    -- What was fired has to fit in the move, or isn't fired at all
    if type(input) == "table" and #written(live) + 24 > LONGEST then
      input = nil
    end
    local used = sim:Step(input)
    -- Whatever couldn't be fired did nothing, which is the same as standing there
    record(live, (type(input) ~= "table" or used) and input or nil)
    if used then
      self:refresh()
    end
  else
    sim:Step(nil)
  end
  self:show(sim)
  if sim.phase == "done" and not live.submitted then
    live.submitted = true
    self:between(sim.passed)
    self.view.submit(written(live))
  end
end

--- Plays a tick of a turn somebody else made
function View:tickReplay()
  local replay = self.replay
  local sim = replay.sim
  if sim.phase == "aim" or sim.phase == "retreat" then
    local inputs = replay.event.inputs
    while replay.left <= 0 and inputs[replay.index] do
      replay.left = inputs[replay.index][2]
      replay.index = replay.index + 1
    end
    if replay.left > 0 then
      replay.left = replay.left - 1
      sim:Step(inputs[replay.index - 1][1] or nil)
    else
      sim.phase = "settle"
      sim:Step(nil)
    end
  else
    sim:Step(nil)
  end
  replay.ticks = replay.ticks + 1
  if sim.phase ~= "done" and replay.ticks > (self.view.state.turnTime + RETREAT + SETTLE) * TPS + 10 then
    sim:finish()
  end
  self:show(sim)
  if sim.phase == "done" then
    self:between(sim.passed)
    self:nextReplay()
  end
end

--- Plays the next of the turns the player hasn't seen, or shows the game as it stands
function View:nextReplay()
  local event = table.remove(self.queue, 1)
  if event and event.before then
    self.replay = { sim = Sim.New(event.before, event.slot, true), event = event, index = 1, left = 0, ticks = 0 }
    local unit = self.replay.sim.unit
    if unit then
      self.viewport:ZoomTo(math.max(self.viewport:goal(), FOLLOW_ZOOM), unit.x / SUB * self.scale, unit.y / SUB * self.scale)
    end
  else
    self.replay = nil
    self.queue = {}
  end
  self:redraw()
  if not self.replay then
    self:begin()
  end
  self:refresh()
  if not self.replay then
    self:conclude(true)
  end
end

--- Gets the player's turn ready if it is theirs and there is nothing left to show them first.
--- Alone, the computer's turns are the player's to make too: it starts thinking about them
function View:begin()
  local view = self.view
  local state = view.state
  if self.replay or self.live or self.brain or not view.canMove or state.picking or state.outcome then
    return
  end
  if state.turn == view.seat then
    self:ready()
    self:sound("turn")
  elseif state.alone then
    self.brain, self.pondered = Brain.New(state), 0
  end
end

--- Who a squad is: the player's name, or the computer's and the class
--- @param seat number
--- @return string
function View:teamName(seat)
  local view = self.view
  local team = view.state.teams[seat]
  local computer = team and (team.computer or (view.computers and view.computers[seat]))
  if computer and team.class then
    return L["wormcraft_computer"]:format(className(team.class))
  end
  return view.names[seat] or ""
end

--- Whether there is a turn still being shown, which the next one has to wait for
--- @return boolean
function View:Busy()
  return self.replay ~= nil or #self.queue > 0
end

--- Lets the computer think for a while, and makes its move once it knows and has looked as though
--- it thought about it
--- @param elapsed number
function View:ponder(elapsed)
  local brain = self.brain
  self.pondered = self.pondered + elapsed
  -- As long as a frame can spare, where the client says how long that has been
  local clock = debugprofilestop
  local began = clock and clock()
  local move = nil
  for _ = 1, clock and 400 or 4 do
    move = brain:Think()
    if move or (clock and clock() - began > THINK_MS) then
      break
    end
  end
  if move and self.pondered >= PONDER_SECONDS then
    self.brain = nil
    self.view.submit(move)
  end
end

--- Plays out at once what is left of the turns being shown
function View:skip()
  while self.replay do
    local replay = self.replay
    for _ = 1, 4000 do
      if self.replay ~= replay then
        break
      end
      replay.sim.happened = nil
      self:tickReplay()
    end
    if self.replay == replay then
      self:nextReplay()
    end
  end
end

--- @param elapsed number
function View:advance(elapsed)
  if not self.view then
    return
  end
  local live, replay = self.live, self.replay
  local running = replay or (live and live.started and not live.submitted)
  if self.brain and not self.replay then
    self:ponder(elapsed)
  end
  if live and live.submitted then
    live.waited = (live.waited or 0) + elapsed
    if live.waited > 5 then
      -- The engine would have had it by now: it was turned down. The turn is made again
      self.live = nil
      self:begin()
      self:refresh()
    end
  end
  if running then
    self.spare = (self.spare or 0) + elapsed * (replay and REPLAY_SPEED or 1)
    local ticks = 0
    while self.spare >= 1 / TPS and ticks < MOST_TICKS do
      self.spare = self.spare - 1 / TPS
      ticks = ticks + 1
      if self.replay then
        self:tickReplay()
      elseif self.live and not self.live.submitted then
        self:tickLive()
      end
    end
    if ticks >= MOST_TICKS then
      self.spare = 0
    end
    local state, sim = self:showing()
    if state then
      self:drawBodies(state, sim)
      if math.abs((self.seaLevel or state.sea) - state.sea) > 0 then
        self:drawSea(state.sea)
      end
    end
    self:follow(elapsed)
  else
    self.spare = 0
  end
  self:aim()

  for index = #self.fx, 1, -1 do
    local fx = self.fx[index]
    fx.age = fx.age + elapsed
    local progress = math.min(1, fx.age / fx.life)
    fx.step(progress)
    if progress >= 1 then
      table.remove(self.fx, index)
      if fx.done then
        fx.done()
      end
    end
  end
  if self.saidLeft > 0 then
    self.saidLeft = self.saidLeft - elapsed
    self.said:SetAlpha(math.min(1, self.saidLeft / 0.6))
    if self.saidLeft <= 0 then
      self.said:Hide()
    end
  end
  self:tock()
end

--- Keeps whatever matters most in sight, while the view is zoomed in
--- @param elapsed number
function View:follow(elapsed)
  local viewport = self.viewport
  if viewport.grab or viewport.move or viewport.zoom <= 1.01 then
    return
  end
  local _, sim = self:showing()
  if not sim then
    return
  end
  local target = sim.moving[1] or (sim.unit and sim.unit.alive and sim.unit)
  if not target then
    return
  end
  local x, y = target.x / SUB, target.y / SUB
  local zoom = viewport.zoom
  -- Where the middle of the window is on the island now
  local middleX = (viewport.width / 2 - viewport.x) / zoom / self.scale
  local middleY = (viewport.height / 2 - viewport.y) / zoom / self.scale
  local along = math.min(1, elapsed * FOLLOW_SPEED)
  local toX, toY = middleX + (x - middleX) * along, middleY + (y - middleY) * along
  viewport:ZoomTo(zoom, toX * self.scale, toY * self.scale, true)
end

-----------------------------
-- Input
-----------------------------

--- Picks something to fire, if the squad has any of it
--- @param id string
function View:pick(id)
  local view = self.view
  if not view or not view.canMove or view.state.picking then
    return
  end
  local had = view.state.teams[view.seat].arsenal[id]
  local live = self.live
  if live then
    had = live.sim.team.arsenal[id]
  end
  if had and had ~= 0 then
    self:choice().weapon = id
    if live then
      live.charging = nil
    end
    self:refresh()
  end
end

--- Picks the next or the one before of what the squad has
--- @param way number
function View:cycle(way)
  local list = self:offered()
  local choice = self:choice()
  for index, id in ipairs(list) do
    if id == choice.weapon then
      local next = list[(index - 1 + way) % #list + 1]
      self:pick(next)
      return
    end
  end
  if list[1] then
    self:pick(list[1])
  end
end

--- What a squad has to fire, in the order it is offered: class's own last but one, resting last
--- @param team WormcraftTeam
--- @return string[]
local function arsenalOf(team)
  local list = {}
  for _, id in ipairs(ARSENAL) do
    if team.arsenal[id] and team.arsenal[id] ~= 0 then
      list[#list + 1] = id
    end
  end
  local own = team.class and CLASSES[team.class].signature
  if own and team.arsenal[own] and team.arsenal[own] ~= 0 then
    list[#list + 1] = own
  end
  if team.arsenal.rs then
    list[#list + 1] = "rs"
  end
  return list
end

--- What the squad on show has to fire
--- @return string[]
function View:offered()
  local view = self.view
  if not view then
    return {}
  end
  local state = self:showing()
  local seat = state.picking and view.seat or (self.live and view.seat or state.turn)
  return arsenalOf(state.teams[seat])
end

--- A key went down while the cursor was over the game. Returns whether it was used
--- @param key string
--- @return boolean
function View:press(key)
  local view = self.view
  if not view then
    return false
  end
  if self.replay then
    if key == "SPACE" or key == "ESCAPE" then
      self:skip()
      return true
    end
    return false
  end
  local live = self.live
  if not live or live.submitted or not view.canMove then
    return false
  end
  local sim = live.sim
  local fuse = tonumber(key)
  if fuse and fuse >= 1 and fuse <= 5 then
    self:choice().fuse = fuse
    self:refresh()
    return true
  end
  local action = KEYS[key]
  if not action then
    return false
  end
  if action == "next" then
    if not live.started then
      local slot = view.state.teams[view.seat].next
      local nextSlot = nextAlive(view.state, view.seat, live.slot)
      self:ready(nextSlot or slot)
      self:refresh()
    end
    return true
  elseif action == "previous" or action == "following" then
    self:cycle(action == "previous" and -1 or 1)
    return true
  end
  self:start()
  if action == "left" or action == "right" or action == "up" or action == "down" then
    self.held[action] = true
  elseif action == "jump" or action == "flip" then
    live.pending[#live.pending + 1] = action == "jump" and "J" or "B"
  elseif action == "fire" then
    if sim.phase == "retreat" then
      live.pending[#live.pending + 1] = "X"
    elseif sim.phase == "aim" then
      local weapon = WEAPONS[self:choice().weapon]
      if weapon.aim == "power" or weapon.aim == "fuse" then
        live.charging = live.charging or 0
      elseif weapon.aim ~= "target" then
        live.charging = 100
        live.pending[#live.pending + 1] = self:shoot(live)
      else
        self:say(L["wormcraft_click"])
      end
    end
  end
  return true
end

--- @param key string
function View:release(key)
  local action = KEYS[key]
  if action then
    self.held[action] = nil
  end
  local live = self.live
  if action == "fire" and live and live.charging and live.sim.phase == "aim" then
    live.pending[#live.pending + 1] = self:shoot(live)
  end
end

--- A click on the island: a place to aim at, for what is aimed at places. Returns whether it was
--- @param button string
--- @return boolean
function View:click(button)
  local live, view = self.live, self.view
  if self.replay and button == "RightButton" then
    self:skip()
    return true
  end
  if button ~= "LeftButton" or not live or live.submitted or not view.canMove or live.sim.phase ~= "aim" then
    return false
  end
  local weapon = WEAPONS[self:choice().weapon]
  if weapon.aim ~= "target" then
    return false
  end
  local x, y = self:pointer()
  x, y = math.floor(x), math.floor(y)
  if x < 0 or x >= WIDTH or y < 0 or y >= HEIGHT then
    return false
  end
  local args = weapon.kind == "teleport" and { x, y } or { x }
  if weapon.kind == "teleport" then
    local unit = live.sim.unit
    local dx, dy = x - div(unit.x, SUB), y - div(unit.y, SUB)
    if not live.sim:open(x, y) or (weapon.range and dx * dx + dy * dy > weapon.range * weapon.range) then
      self:say(L["wormcraft_cant_go"], private.Widgets.RED)
      return true
    end
  end
  self:start()
  live.pending[#live.pending + 1] = { use = weapon.id, args = args, fire = not weapon.utility }
  return true
end

-----------------------------
-- Around the island
-----------------------------

--- Shows how long is left of the turn being made or played out again
function View:tock()
  local _, sim = self:showing()
  if sim and sim.phase == "aim" then
    local left = math.max(0, sim.state.turnTime - div(sim.used, TPS))
    self.clock:SetText(left)
    self.clock:SetTextColor(left <= 5 and 1 or 1, left <= 5 and 0.3 or 1, left <= 5 and 0.25 or 1)
  elseif sim and sim.phase == "retreat" then
    self.clock:SetText(math.max(0, math.ceil(sim.left / TPS)))
    self.clock:SetTextColor(1, 0.82, 0)
  else
    self.clock:SetText("")
  end
end

--- Brings everything round the island up to date
function View:refresh()
  local view = self.view
  if not view then
    return
  end
  local state, sim = self:showing()
  local Widgets = private.Widgets

  -- Whose turn
  local status
  if state.outcome then
    status = ""
  elseif state.picking then
    status = state.turn == view.seat and L["wormcraft_pick"] or L["wormcraft_picking"]:format(self:teamName(state.turn))
  elseif self.replay then
    status = L["wormcraft_replay"]:format(self:teamName(state.turn), sim.unit and sim.unit.name or "")
  elseif self.live then
    status = L["wormcraft_your_turn"]:format(self.live.sim.unit.name)
    if not self.live.started then
      status = status .. "  " .. L["wormcraft_ready"]
    end
  else
    local computer = self.brain or (view.computers and view.computers[state.turn])
    status = L[computer and "wormcraft_thinking" or "wormcraft_their_turn"]:format(self:teamName(state.turn))
  end
  self.status:SetText(status)
  self.round:SetText(L["wormcraft_round"]:format(state.round, state.level))

  -- The wind, from the middle out to the side it blows to
  local wind = self.wind
  local half = (WIND_WIDTH - 4) / 2
  local reach = math.max(1, half * math.abs(state.wind) / 10)
  wind.fill:ClearAllPoints()
  wind.fill:SetWidth(reach)
  if state.wind >= 0 then
    wind.fill:SetPoint("LEFT", wind, "CENTER", 0, 0)
    wind.fill:SetColorTexture(0.4, 0.7, 1, 0.9)
  else
    wind.fill:SetPoint("RIGHT", wind, "CENTER", 0, 0)
    wind.fill:SetColorTexture(1, 0.55, 0.3, 0.9)
  end
  wind.fill:SetShown(state.wind ~= 0)

  -- The squads, and how much they have left between them
  for seat, row in ipairs(self.squads) do
    local team = state.teams[seat]
    row:SetShown(team ~= nil)
    if team then
      local health, most = 0, 0
      for _, unit in ipairs(state.units) do
        if unit.team == seat then
          health, most = health + unit.hp, most + state.health
        end
      end
      local color = TEAM_RGB[TEAM_COLORS[seat]]
      row.name:SetText(self:teamName(seat))
      row.name:SetTextColor(color[1], color[2], color[3])
      row.fill:SetColorTexture(color[1], color[2], color[3], team.out and 0.25 or 0.9)
      row.fill:SetWidth(math.max(0.01, 86 * math.min(1, health / math.max(1, most))))
      row:SetAlpha(team.out and 0.5 or 1)
    end
  end

  -- What there is to fire
  local list = self:offered()
  local choice = self:choice()
  local mine = self.live ~= nil
  local team = state.teams[(state.picking or mine) and view.seat or state.turn]
  for index, id in ipairs(list) do
    local slot = self.slots[index]
    if not slot then
      slot = createSlot(self.bar, SLOT_SIZE)
      slot:SetScript("OnClick", function(button)
        self:pick(button.id)
      end)
      slot:SetScript("OnEnter", function(button)
        local weapon = WEAPONS[button.id]
        GameTooltip:SetOwner(button, "ANCHOR_TOP")
        GameTooltip:SetText(L["wormcraft_weapon_" .. weapon.id])
        GameTooltip:AddLine(L["wormcraft_weapon_" .. weapon.id .. "_tip"], 1, 1, 1, true)
        GameTooltip:AddLine(L["wormcraft_aim_" .. weapon.aim], 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
      end)
      slot:SetScript("OnLeave", GameTooltip_Hide)
      self.slots[index] = slot
    end
    slot.id = id
    slot:ClearAllPoints()
    slot:SetPoint("LEFT", (index - 1) * (SLOT_SIZE + SLOT_GAP), 0)
    slot.icon:SetTexture(ICONS .. WEAPONS[id].icon)
    local charges = team.arsenal[id] or 0
    slot.count:SetText(charges > 0 and charges or "")
    local chosen = mine and id == choice.weapon
    slot:SetBackdropBorderColor(chosen and 1 or 0.4, chosen and 0.82 or 0.4, chosen and 0 or 0.4, chosen and 1 or 0.6)
    slot.icon:SetDesaturated(not mine)
    slot:Show()
  end
  for index = #list + 1, #self.slots do
    self.slots[index]:Hide()
  end

  local weapon = WEAPONS[choice.weapon]
  local hint
  if self.replay then
    hint = L["wormcraft_hint_replay"]
  elseif mine and weapon then
    hint = L["wormcraft_hint"]
    if weapon.aim == "fuse" then
      hint = hint .. "\n" .. L["wormcraft_hint_fuse"]:format(choice.fuse)
    elseif weapon.aim == "target" then
      hint = hint .. "\n" .. L["wormcraft_hint_target"]
    elseif not self.live.started then
      hint = hint .. "\n" .. L["wormcraft_hint_tab"]
    end
  else
    hint = ""
  end
  self.hint:SetText(hint)

  -- Who they are, while they are still saying
  local picker = self.picker
  picker:SetShown(state.picking == true and not state.outcome)
  if state.picking then
    local mineToPick = view.canMove and state.turn == view.seat
    picker.title:SetText(mineToPick and L["wormcraft_pick"] or L["wormcraft_picking"]:format(self:teamName(state.turn)))
    picker.row:SetShown(mineToPick)
    picker.detail:SetText(mineToPick and L["wormcraft_pick_detail"] or "")
    local own = ownClass()
    for class, pick in pairs(self.picks) do
      local color = class == own and Widgets.GOLD or { 1, 1, 1 }
      pick:SetBackdropBorderColor(color[1], color[2], color[3], class == own and 1 or 0.15)
    end
  end
end

--- @param width number
--- @param height number
function View:Layout(width, height)
  self.width, self.height = width, height
  local room = height - HUD_HEIGHT - BAR_HEIGHT
  local scale = math.max(0.05, math.min(width / WIDTH, room / HEIGHT))
  self.scale = scale
  local fieldWidth, fieldHeight = WIDTH * scale, HEIGHT * scale
  self.hud:ClearAllPoints()
  self.hud:SetPoint("BOTTOM", self.stage, "TOP", 0, -HUD_HEIGHT)
  self.hud:SetWidth(fieldWidth)
  local viewport = self.viewport
  viewport.frame:ClearAllPoints()
  viewport.frame:SetPoint("TOP", self.stage, "TOP", 0, -HUD_HEIGHT)
  viewport:SetSize(fieldWidth, fieldHeight)
  viewport:SetContentSize(fieldWidth, fieldHeight)
  self.bar:ClearAllPoints()
  self.bar:SetPoint("TOP", viewport.frame, "BOTTOM", 0, -4)
  self.bar:SetWidth(fieldWidth)
  self.hint:ClearAllPoints()
  self.hint:SetPoint("RIGHT", self.bar, "RIGHT", 0, 0)
  self.hint:SetWidth(math.max(120, fieldWidth * 0.36))
  self:redraw()
  self:sizeLabels(viewport.zoom)
end

--- @param view GameView
function View:Update(view)
  local before = self.view
  self.view = view
  local id = view.match.id
  local another = not before or before.match.id ~= id
  if another then
    self.live, self.replay, self.queue, self.brain = nil, nil, {}, nil
    self.effects:Clear()
    self.held = {}
    self.viewport:Fit(true)
  end

  if another or view.changed then
    self.brain = nil
    if self.live and not self.live.submitted then
      -- Something came in the middle of the turn: somebody resigned
      self.live = nil
    elseif self.live then
      self.live = nil
    end
    self.replay, self.queue = nil, {}
    -- A turn somebody else made is played out again in front of the player: the one that just
    -- came in, and each of those they missed, which the window hands over one after the other
    local event = view.played
    if event and event.before and event.team ~= view.seat then
      self.queue[1] = event
    end
    if #self.queue > 0 then
      self:nextReplay()
    end
    self:redraw()
  end

  -- The player's turn, ready to begin as soon as they do something
  self:begin()
  self:refresh()
  self:conclude(not another and view.played ~= nil)
end

--- Says who won, once the game is over and the last of it has been played out
--- @param seen boolean The player saw it end, rather than finding it over
function View:conclude(seen)
  local view = self.view
  local outcome = view.state.outcome
  if not outcome or self.replay or self.effects:HasBanner() then
    return
  end
  local winner = outcome.winner
  local title = winner == 0 and L["wormcraft_nobody"] or (winner == view.seat and L["wormcraft_won"] or L["wormcraft_lost"]:format(self:teamName(winner)))
  self.effects:Banner(title, nil, { instant = not seen, color = winner ~= 0 and TEAM_RGB[TEAM_COLORS[winner]] or nil })
  if winner == view.seat and seen then
    self.effects:Confetti()
  end
end

private.Games.Register({
  id = "wormcraft",
  name = L["game_wormcraft"],
  description = L["game_wormcraft_description"],
  genre = "strategy",
  icon = "Interface\\AddOns\\ForeverGames\\Images\\Icons\\wormcraft",
  version = 1,
  seats = { 2, 3, 4 },
  options = {
    -- The computer's squads in a game played alone from before the computer was the engine's.
    -- Only ever offered to a game for one, which this no longer is: they are here for the games
    -- that were set up with them, to be played out the way they were
    {
      id = "bots",
      name = L["wormcraft_option_bots"],
      description = L["wormcraft_option_bots_tip"],
      choices = { 1, 2, 3 },
      default = 1,
      alone = true,
    },
    {
      id = "skill",
      name = L["wormcraft_option_skill"],
      description = L["wormcraft_option_skill_tip"],
      choices = SKILL_ORDER,
      default = "medium",
      alone = true,
      label = function(value)
        return L["wormcraft_skill_" .. value]
      end,
    },
    {
      id = "squad",
      name = L["wormcraft_option_squad"],
      description = L["wormcraft_option_squad_tip"],
      choices = { 2, 3, 4 },
      default = 3,
    },
    {
      id = "health",
      name = L["wormcraft_option_health"],
      description = L["wormcraft_option_health_tip"],
      choices = { 50, 100, 150, 200 },
      default = 100,
    },
    {
      id = "time",
      name = L["wormcraft_option_time"],
      description = L["wormcraft_option_time_tip"],
      choices = { 30, 45, 60 },
      default = 45,
      label = function(value)
        return L["wormcraft_option_seconds"]:format(value)
      end,
    },
    {
      id = "sudden",
      name = L["wormcraft_option_sudden"],
      description = L["wormcraft_option_sudden_tip"],
      choices = { 6, 10, 15, 0 },
      default = 10,
      label = function(value)
        return value == 0 and L["wormcraft_option_never"] or L["wormcraft_option_round"]:format(value)
      end,
    },
    {
      id = "map",
      name = L["wormcraft_option_map"],
      description = L["wormcraft_option_map_tip"],
      choices = { RANDOM_THEME, "elwynn", "durotar", "winterspring", "steppes" },
      default = RANDOM_THEME,
      label = function(value)
        return L["wormcraft_map_" .. value]
      end,
    },
  },
  howto = {
    { heading = L["howto_goal"], text = L["wormcraft_howto_goal"] },
    { heading = L["wormcraft_howto_class"], text = L["wormcraft_howto_class_text"] },
    { heading = L["howto_turn"], text = L["wormcraft_howto_turn"] },
    { heading = L["wormcraft_howto_firing"], text = L["wormcraft_howto_firing_text"] },
    { heading = L["wormcraft_howto_spells"], text = L["wormcraft_howto_spells_text"] },
    {
      heading = L["howto_end"],
      -- Whether the sea rises at all
      text = function(rules)
        return L[rules.sudden == 0 and "wormcraft_howto_end_never" or "wormcraft_howto_end_sudden"]
      end,
    },
  },
  newState = newState,
  turn = function(state)
    -- Alone, every move is the player's to make, the computer's too
    return state.alone and 1 or state.turn
  end,
  validate = validate,
  apply = apply,
  moves = moves,
  result = result,
  drop = drop,
  beaten = function(state, seat)
    local team = state.teams[seat]
    return not state.picking and team ~= nil and team.out == true
  end,
  computer = COMPUTER,
  createView = createView,
  seatLabel = function(seat)
    return L["wormcraft_team_" .. TEAM_COLORS[seat]]
  end,
})
