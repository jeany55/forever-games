--------------------------
--  Warcraftstein 3D
--------------------------
-- The Scarlet Monastery seen from inside it, for one player: get through its halls to the portal
-- at the far end of them, past the Crusade and whatever haunts its graveyard, and past Herod, who
-- guards the portal and keeps it shut for as long as he stands. It is drawn the way the shooters
-- of the early nineties drew theirs. What the player can do depends on their class (CLASSES),
-- which is the one of the character they are on unless they pick another, and on the talents they
-- learn on the way (TALENTS): every kill is worth experience, and every level a talent point.
--
-- The monastery is a grid of squares, built as rooms joined by corridors (newState). Every room
-- is in one of the monastery's wings, which says what its walls look like, who is in it and what
-- stands about: the graveyard nearest the start, then the library, the cathedral, and last the
-- armory, where Herod is. The room the player starts in is a chapel, a sanctuary: nobody of the
-- Crusade is near it to begin with, nobody follows the player in or sees them there, and there
-- is no fighting in it either, only getting one's breath back. There is a fountain in the
-- middle of it, and the player begins just behind it. The state keeps what is on every square, numbered along the rows from 1
-- in the top left corner: 0 for nothing, else a kind of wall (NAVE to CRYPT, and SHRINE) or the
-- portal. Where
-- something stands is measured in squares from that corner, across and down, and the way the
-- player faces as an angle that is 0 looking right and grows turning right. The state also says
-- where everyone and everything is to begin with.
--
-- The game has turns like any other as far as the engine knows, and only three moves. The first
-- is "c" and a class, "cMAGE": who the player is in there. It is a move so that the game is the
-- same one when it is loaded again on another character. Then "x", the player walked into the
-- portal, or "d", the Crusade got them first. Everything on the way there is the view's business
-- and happens many times a second, which is far too often to be written down. So the engine is
-- never told where the player is, how the fight is going or what they learnt, and a game that is
-- left and loaded again begins at the start with everyone back where they were.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Tables = private.Tables

-- How many rooms the monastery has
local SIZES, USUAL_SIZE = { 6, 9, 12 }, 9
local OPEN = 0
-- The walls, each a picture (View): the bare arcade of the nave, a window, a banner, shelves,
-- arms on display and the rough stone of the crypt. The portal, which is walked into. And the
-- sanctuary's own, a window of the Light
local NAVE, WINDOW, BANNER, LIBRARY, ARMORY, CRYPT, PORTAL, SHRINE = 1, 2, 3, 4, 5, 6, 7, 8
local STEPS = { { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } }
local EXIT, DEAD, CLASS = "x", "d", "c"
-- What the best time is kept under, with how many rooms there were after it
local TIME_KEY = "rooms"
-- How many squares the monastery is each way: this many, and some more for every room
local SIDE, SIDE_A_ROOM = 13, 2
-- How many squares a room is each way, at least and at most, and how many places are tried for
-- every room before the monastery makes do with fewer
local ROOM_SMALLEST, ROOM_LARGEST, ROOM_TRIES = 3, 6, 600
-- One more way between two rooms for this many rooms, so that not every way is the only one
local LOOP_IN = 4
-- The wings, from the start on, and what the walls of a room in each are: mostly the first,
-- every third square the second
local WINGS = { "graveyard", "library", "cathedral", "armory" }
local SANCTUARY = "sanctuary"
local WING_WALLS = {
  sanctuary = { SHRINE, WINDOW },
  graveyard = { CRYPT, CRYPT },
  library = { LIBRARY, NAVE },
  cathedral = { WINDOW, BANNER },
  armory = { ARMORY, BANNER },
}
-- Who is found in each (FOES), and what stands in its corners besides a light
local WING_FOES = {
  graveyard = { "phantasm", "phantasm", "soldier" },
  library = { "adept", "monk", "soldier" },
  cathedral = { "soldier", "monk", "adept" },
  armory = { "defender", "soldier", "adept" },
}
local WING_DECOR = { sanctuary = "candelabra", graveyard = "tombstone", library = "lectern", cathedral = "flag", armory = "flag" }
local WING_LIGHT = { sanctuary = "candelabra", graveyard = "brazier", library = "candelabra", cathedral = "candelabra", armory = "brazier" }
-- One foe to this many squares of a room, at most this many in one: half as many in the rooms
-- near the start as in the ones far from it. None nearer the start than this many squares'
-- walk. And who keeps the portal with whom
local FOE_ROOM, FOE_MOST, SAFE_WALK = 7, 4, 10
local BOSS, BOSS_GUARDS = "herod", { "defender", "soldier" }
-- A potion for health for this many rooms, and one for power
local ROOMS_A_HEALTH, ROOMS_A_POWER = 1.5, 2

--- @class WarcraftsteinRoom
--- @field x number The square in its top left corner, counted from 0
--- @field y number
--- @field w number How many squares it is across
--- @field h number And down
--- @field wing string
--- @field far number How many squares' walk it is from the start to the middle of it

--- @class WarcraftsteinState
--- @field size number How many rooms there are
--- @field side number How many squares the grid has each way
--- @field cells number[] What is on every square
--- @field rooms WarcraftsteinRoom[] In the order they were built, the first the one the player starts in
--- @field start { x: number, y: number, facing: number } Where the player begins
--- @field mobs { x: number, y: number, kind: string }[] Who is where, by kind (FOES)
--- @field loot { x: number, y: number, kind: "health"|"power" }[] Where the potions are
--- @field decor { x: number, y: number, kind: string }[] What stands about: lights, tombstones, lecterns, flags
--- @field class string? Who the player is, once they have said
--- @field found boolean The player is out
--- @field dead boolean The player never will be

-----------------------------
-- Building the monastery
-----------------------------

--- @param seats number
--- @param random Random
--- @param rules table<string, any>?
--- @return WarcraftsteinState
local function newState(_, random, rules)
  local count = rules and rules.size or USUAL_SIZE
  local side = SIDE + count * SIDE_A_ROOM
  local cells = {}
  local function at(column, row)
    return row * side + column + 1
  end
  for square = 1, side * side do
    cells[square] = NAVE
  end

  -- The rooms, wherever there is room for them with a wall between every two
  --- @type WarcraftsteinRoom[]
  local rooms = {}
  local tries = 0
  while #rooms < count and tries < ROOM_TRIES do
    tries = tries + 1
    local spread = ROOM_LARGEST - ROOM_SMALLEST + 1
    local w, h = ROOM_SMALLEST + random:Roll(spread) - 1, ROOM_SMALLEST + random:Roll(spread) - 1
    local x, y = random:Roll(side - w - 2), random:Roll(side - h - 2)
    local clear = true
    for _, other in ipairs(rooms) do
      if x <= other.x + other.w and other.x <= x + w and y <= other.y + other.h and other.y <= y + h then
        clear = false
      end
    end
    if clear then
      rooms[#rooms + 1] = { x = x, y = y, w = w, h = h, wing = WINGS[1], far = 0 }
      for row = y, y + h - 1 do
        for column = x, x + w - 1 do
          cells[at(column, row)] = OPEN
        end
      end
    end
  end

  --- The middle of a room
  local function middle(room)
    return room.x + math.floor(room.w / 2), room.y + math.floor(room.h / 2)
  end
  --- A corridor from the middle of one room to the middle of another: along, then down, or the other way round
  local function dig(one, other)
    local column, row = middle(one)
    local toColumn, toRow = middle(other)
    local across = random:Roll(2) == 1
    for _ = 1, 2 do
      if across then
        while column ~= toColumn do
          column = column + (toColumn > column and 1 or -1)
          cells[at(column, row)] = OPEN
        end
      else
        while row ~= toRow do
          row = row + (toRow > row and 1 or -1)
          cells[at(column, row)] = OPEN
        end
      end
      across = not across
    end
  end
  -- Every room to the nearest of the ones before it, so they are all joined, and a few more
  for index = 2, #rooms do
    local column, row = middle(rooms[index])
    local nearest, best = math.huge, nil
    for other = 1, index - 1 do
      local otherColumn, otherRow = middle(rooms[other])
      local away = math.abs(otherColumn - column) + math.abs(otherRow - row)
      if away < nearest then
        nearest, best = away, rooms[other]
      end
    end
    dig(rooms[index], best)
  end
  for _ = 1, math.floor(#rooms / LOOP_IN) do
    local one, other = random:Roll(#rooms), random:Roll(#rooms)
    if one ~= other then
      dig(rooms[one], rooms[other])
    end
  end

  -- How far every square is to walk to from the start, which says which wing every room is in:
  -- the further, the deeper into the monastery. The furthest is the armory, and the way out
  local startColumn, startRow = middle(rooms[1])
  local walk, reached, index = { [at(startColumn, startRow)] = 0 }, { at(startColumn, startRow) }, 1
  while reached[index] do
    local square = reached[index]
    for _, next in ipairs({ square - 1, square + 1, square - side, square + side }) do
      if cells[next] == OPEN and not walk[next] then
        walk[next] = walk[square] + 1
        reached[#reached + 1] = next
      end
    end
    index = index + 1
  end
  local deepest, exit = 0, rooms[1]
  for _, room in ipairs(rooms) do
    room.far = walk[at(middle(room))]
    if room.far > deepest then
      deepest, exit = room.far, room
    end
  end
  for _, room in ipairs(rooms) do
    room.wing = WINGS[math.min(#WINGS, math.floor(room.far / math.max(1, deepest) * #WINGS) + 1)]
  end
  exit.wing = WINGS[#WINGS]
  rooms[1].wing = SANCTUARY

  -- The walls round a room are its wing's
  for _, room in ipairs(rooms) do
    local walls = WING_WALLS[room.wing]
    for row = room.y - 1, room.y + room.h do
      for column = room.x - 1, room.x + room.w do
        if cells[at(column, row)] ~= OPEN then
          cells[at(column, row)] = (column + row) % 3 == 0 and walls[2] or walls[1]
        end
      end
    end
  end
  -- The portal in the wall of the armory: the middle of a side if that is wall, or wherever
  -- along its sides it can be. Never in a corner, which can't be walked into
  local portal = nil
  local exitColumn, exitRow = middle(exit)
  local sides = {
    { exitColumn, exit.y - 1 },
    { exit.x + exit.w, exitRow },
    { exitColumn, exit.y + exit.h },
    { exit.x - 1, exitRow },
  }
  for column = exit.x, exit.x + exit.w - 1 do
    sides[#sides + 1] = { column, exit.y - 1 }
    sides[#sides + 1] = { column, exit.y + exit.h }
  end
  for row = exit.y, exit.y + exit.h - 1 do
    sides[#sides + 1] = { exit.x - 1, row }
    sides[#sides + 1] = { exit.x + exit.w, row }
  end
  -- Only where it is walked into from the armory and nowhere else, or there would be a way out
  -- round the back of Herod
  for _, place in ipairs(sides) do
    local square, open = at(place[1], place[2]), 0
    for _, next in ipairs({ -1, 1, -side, side }) do
      open = open + (cells[square + next] == OPEN and 1 or 0)
    end
    if not portal and cells[square] ~= OPEN and open == 1 then
      portal = square
    end
  end
  for _, place in ipairs(sides) do
    if not portal and cells[at(place[1], place[2])] ~= OPEN then
      portal = at(place[1], place[2])
    end
  end
  cells[portal] = PORTAL

  -- The player looks from the middle of the first room towards the room it was joined to, from
  -- a step back, past the fountain in the middle of it
  local nextColumn, nextRow = middle(rooms[2] or rooms[1])
  local facing = math.atan2(nextRow - startRow, nextColumn - startColumn) % (math.pi * 2)
  local quarter = math.floor(facing / (math.pi / 2) + 0.5) % 4
  facing = quarter * (math.pi / 2)
  local fountainColumn, fountainRow = startColumn, startRow
  startColumn, startRow = startColumn - STEPS[quarter + 1][1], startRow - STEPS[quarter + 1][2]

  -- What stands in a room's corners: a light in two of them, the wing's own in the others. Only
  -- in a corner that is one, with walls on both sides, so nothing stands in a way through
  local decor = { { x = fountainColumn + 0.5, y = fountainRow + 0.5, kind = "fountain" } }
  local taken = { [at(startColumn, startRow)] = true, [at(fountainColumn, fountainRow)] = true }
  local solid = { [at(fountainColumn, fountainRow)] = true }
  local open = 0
  for _, kind in ipairs(cells) do
    open = open + (kind == OPEN and 1 or 0)
  end
  --- Whether something standing on a square would leave somewhere that can't be got to round
  --- it and everything else that stands about, as it might in a small room
  local function cuts(square)
    solid[square] = true
    local start = at(startColumn, startRow)
    local seen, queue, index, count = { [start] = true }, { start }, 1, 0
    for _ in pairs(solid) do
      count = count + 1
    end
    while queue[index] do
      local here = queue[index]
      index = index + 1
      for _, next in ipairs({ here - 1, here + 1, here - side, here + side }) do
        if cells[next] == OPEN and not solid[next] and not seen[next] then
          seen[next] = true
          queue[#queue + 1] = next
        end
      end
    end
    solid[square] = nil
    return #queue ~= open - count
  end
  for _, room in ipairs(rooms) do
    local corners = {
      { room.x, room.y },
      { room.x + room.w - 1, room.y },
      { room.x + room.w - 1, room.y + room.h - 1 },
      { room.x, room.y + room.h - 1 },
    }
    for nth, corner in ipairs(corners) do
      local square, open = at(corner[1], corner[2]), 0
      for _, next in ipairs({ -1, 1, -side, side }) do
        open = open + (cells[square + next] == OPEN and 1 or 0)
      end
      if open <= 2 and not taken[square] and not cuts(square) then
        taken[square], solid[square] = true, true
        decor[#decor + 1] = { x = corner[1] + 0.5, y = corner[2] + 0.5, kind = nth % 2 == 1 and WING_LIGHT[room.wing] or WING_DECOR[room.wing] }
      end
    end
  end

  --- Somewhere in a room nobody is yet, at least so far from the start
  local function free(room, far)
    for _ = 1, room.w * room.h * 4 do
      local column, row = room.x + random:Roll(room.w) - 1, room.y + random:Roll(room.h) - 1
      if not taken[at(column, row)] and (walk[at(column, row)] or 0) >= (far or 0) then
        taken[at(column, row)] = true
        return column + 0.5, row + 0.5
      end
    end
    return nil
  end
  -- The Crusade in every room but the sanctuary, more of it the deeper in. Herod and his guards
  -- in the armory
  local mobs = {}
  for nth, room in ipairs(rooms) do
    local kinds = WING_FOES[room.wing]
    local party = {}
    if room == exit then
      party = { BOSS, BOSS_GUARDS[1], BOSS_GUARDS[2] }
    elseif nth > 1 then
      local deep = 0.5 + room.far / math.max(1, deepest) * 0.75
      for _ = 1, math.max(1, math.min(FOE_MOST, math.floor(room.w * room.h / FOE_ROOM * deep))) do
        party[#party + 1] = kinds[random:Roll(#kinds)]
      end
    end
    for _, kind in ipairs(party) do
      local x, y = free(room, SAFE_WALK)
      if x then
        mobs[#mobs + 1] = { x = x, y = y, kind = kind }
      end
    end
  end
  -- Potions here and there, never in the first room
  local loot = {}
  for _, potion in ipairs({ { "health", ROOMS_A_HEALTH }, { "power", ROOMS_A_POWER } }) do
    for _ = 1, math.floor(#rooms / potion[2]) do
      -- In another room if one is full
      local x, y = nil, nil
      for _ = 1, #rooms * 2 do
        if not x then
          x, y = free(rooms[random:Roll(#rooms - 1) + 1])
        end
      end
      if x then
        loot[#loot + 1] = { x = x, y = y, kind = potion[1] }
      end
    end
  end

  --- @type WarcraftsteinState
  return {
    size = count,
    side = side,
    cells = cells,
    rooms = rooms,
    start = { x = startColumn + 0.5, y = startRow + 0.5, facing = facing },
    mobs = mobs,
    loot = loot,
    decor = decor,
    found = false,
    dead = false,
  }
end

-----------------------------
-- Classes
-----------------------------
-- What a class is in the monastery: how much it takes, what it strikes with (`attack`) and the one
-- thing it can do besides (`ability`), which costs it some of its power. All of it is numbers
-- for the view to go by, there is no code here for any one class.
--
-- An attack is a blow at whatever is right in front ("melee"), a shot that is there at once
-- from far away and worth half from too close ("shot"), or a bolt that flies until it meets
-- something ("bolt"). An ability is a blow at everything around ("nova") or in sight ("volley"),
-- something the player is for a while ("buff"), health back ("heal"), health for power ("tap")
-- or a totem that fights on its own ("totem").

-- The first of the two pictures of everything the player can hold, in Images/Warcraftstein/weapons
local SWORD, BOW, STAFF, CLAWS = 0, 2, 4, 6
-- How much power there is at most. Rage starts at none and comes from blows, the others start full
local POWER = 100

--- @class WarcraftsteinAttack
--- @field kind "melee"|"shot"|"bolt"
--- @field hits number What it takes off
--- @field every number Seconds from one to the next
--- @field cost number? Power it takes
--- @field reach number? How far it goes, and for a melee or a shot how far to either side of straight ahead (`wide`)
--- @field splash number? Talent: half of it to everyone this near whoever it hits
--- @field pierce number? Talent: how many more it goes on through
--- @field slows number? Talent: seconds whoever it hits goes at half the speed
--- @field stuns number? Talent: the chance it stuns whoever it hits
--- @field wide number?
--- @field close number? A shot from nearer than this is worth half
--- @field ambush number? How many times as much it takes off someone who didn't see it coming
--- @field chain number? How much of it goes on to another kobold near the one it hit
--- @field drains number? How much of what it takes off the player gets as health
--- @field tint number[]? The colour of a bolt

--- @class WarcraftsteinAbility
--- @field id string Named L["warcraftstein_ability_" .. id]
--- @field icon string One of the client's own
--- @field kind "nova"|"volley"|"buff"|"heal"|"tap"|"totem"
--- @field every number Seconds until it can be done again
--- @field cost number? Power it takes
--- @field hits number? What it takes off whoever it reaches, or what a totem does a time
--- @field reach number? How far it reaches
--- @field freezes number? Seconds whoever it reaches can do nothing
--- @field lasts number? Seconds a buff or a totem is there for
--- @field immune boolean? Buff: nothing hurts the player
--- @field hidden boolean? Buff: no kobold sees the player
--- @field breaks boolean? Buff: over with the first blow the player strikes
--- @field speed number? Buff: how many times as fast the player walks
--- @field attack WarcraftsteinAttack? Buff: what the player strikes with meanwhile
--- @field holds number? Buff: and what they are shown holding
--- @field veil number[]? Buff: the colour everything is seen through
--- @field heals number? Heal: health it gives
--- @field takes number? Tap: health it takes
--- @field gives number? Tap: power it gives for that
--- @field wait number? Totem: seconds between its blows

--- @class WarcraftsteinClass
--- @field health number
--- @field color number[]
--- @field power "rage"|"mana"|"energy"
--- @field regen number? Power a second
--- @field gains { dealt: number, taken: number }? Power for every blow struck and taken
--- @field armor number? How much of a blow gets through
--- @field speed number? How many times as fast as others it walks
--- @field holds number
--- @field attack WarcraftsteinAttack
--- @field ability WarcraftsteinAbility
--- @field crit number? Talent: the chance a blow is twice as hard
--- @field leech number? Talent: health for every kill
--- @field dodge number? Talent: the chance a blow misses
--- @field thorns number? Talent: what a blow takes off whoever struck it
--- @field mend number? Talent: health a second
--- @field refund number? Talent: seconds off the wait for the ability for every kill
--- @field potency number? How much more a potion gives

--- @type table<string, WarcraftsteinClass>
local CLASSES = {
  WARRIOR = {
    health = 120,
    color = { 0.78, 0.61, 0.43 },
    power = "rage",
    gains = { dealt = 12, taken = 8 },
    armor = 0.7,
    holds = SWORD,
    attack = { kind = "melee", hits = 15, reach = 1.3, wide = 0.45, every = 0.45 },
    ability = { id = "whirlwind", icon = "Ability_Whirlwind", kind = "nova", cost = 30, every = 1, reach = 1.7, hits = 30 },
  },
  PALADIN = {
    health = 110,
    color = { 0.96, 0.55, 0.73 },
    power = "mana",
    regen = 4,
    armor = 0.85,
    holds = SWORD,
    attack = { kind = "melee", hits = 22, reach = 1.3, wide = 0.45, every = 0.65 },
    ability = { id = "shield", icon = "Spell_Holy_DivineIntervention", kind = "buff", cost = 40, every = 20, lasts = 4, immune = true, veil = { 1, 0.85, 0.3, 0.14 } },
  },
  HUNTER = {
    health = 100,
    color = { 0.67, 0.83, 0.45 },
    power = "mana",
    regen = 5,
    holds = BOW,
    attack = { kind = "shot", hits = 14, reach = 8, wide = 0.3, every = 0.6, close = 1.5 },
    ability = { id = "multishot", icon = "Ability_UpgradeMoonGlaive", kind = "volley", cost = 35, every = 4, reach = 8, hits = 14 },
  },
  ROGUE = {
    health = 90,
    color = { 1, 0.96, 0.41 },
    power = "energy",
    regen = 20,
    speed = 1.15,
    holds = SWORD,
    attack = { kind = "melee", hits = 8, reach = 1.2, wide = 0.45, every = 0.25, cost = 10, ambush = 3 },
    ability = { id = "stealth", icon = "Ability_Vanish", kind = "buff", cost = 40, every = 10, lasts = 8, hidden = true, breaks = true, veil = { 0.05, 0.05, 0.25, 0.3 } },
  },
  PRIEST = {
    health = 80,
    color = { 1, 1, 1 },
    power = "mana",
    regen = 5,
    holds = STAFF,
    attack = { kind = "bolt", hits = 14, every = 0.5, cost = 8, tint = { 1, 0.95, 0.6 } },
    ability = { id = "heal", icon = "Spell_Holy_Heal", kind = "heal", cost = 35, every = 1.5, heals = 40 },
  },
  SHAMAN = {
    health = 100,
    color = { 0, 0.44, 0.87 },
    power = "mana",
    regen = 5,
    holds = STAFF,
    attack = { kind = "bolt", hits = 13, every = 0.55, cost = 9, chain = 0.5, tint = { 0.55, 0.75, 1 } },
    ability = { id = "totem", icon = "Spell_Fire_SearingTotem", kind = "totem", cost = 30, every = 12, lasts = 12, reach = 4, hits = 8, wait = 1 },
  },
  MAGE = {
    health = 80,
    color = { 0.25, 0.78, 0.92 },
    power = "mana",
    regen = 6,
    holds = STAFF,
    attack = { kind = "bolt", hits = 20, every = 0.6, cost = 10, tint = { 1, 0.5, 0.15 } },
    ability = { id = "nova", icon = "Spell_Frost_FrostNova", kind = "nova", cost = 25, every = 8, reach = 2.5, hits = 5, freezes = 4 },
  },
  WARLOCK = {
    health = 90,
    color = { 0.53, 0.53, 0.93 },
    power = "mana",
    regen = 2,
    holds = STAFF,
    attack = { kind = "bolt", hits = 18, every = 0.6, cost = 10, drains = 0.25, tint = { 0.65, 0.3, 1 } },
    ability = { id = "tap", icon = "Spell_Shadow_BurningSpirit", kind = "tap", every = 1, takes = 15, gives = 30 },
  },
  DRUID = {
    health = 100,
    color = { 1, 0.49, 0.04 },
    power = "mana",
    regen = 5,
    holds = STAFF,
    attack = { kind = "bolt", hits = 14, every = 0.5, cost = 8, tint = { 0.4, 1, 0.3 } },
    ability = {
      id = "cat",
      icon = "Ability_Druid_CatForm",
      kind = "buff",
      cost = 30,
      every = 12,
      lasts = 8,
      speed = 1.5,
      holds = CLAWS,
      attack = { kind = "melee", hits = 11, reach = 1.2, wide = 0.45, every = 0.25 },
      veil = { 1, 0.6, 0.1, 0.08 },
    },
  },
}
-- The order they are offered in
local CLASS_ORDER = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
-- What a character is that is of a class the monastery doesn't know
local USUAL_CLASS = "WARRIOR"

-----------------------------
-- Talents
-----------------------------
-- Every class has three trees of three talents, the way the client has its own: a talent further
-- down a tree is only to be had with points enough spent in that tree already (TIER_NEEDS). The
-- first two in a tree take two points each to learn all of, the last one point. Every point
-- comes from a level, and every level from experience, which every kill is worth some of. All of
-- it is gone with the game: the next one begins at level 1 again.
--
-- A talent is numbers too: what it does to the class, a rank at a time (`mods`). "more" makes a
-- number that much bigger for every rank, as a share of it, "plus" adds to it. The numbers are
-- the class's (CLASSES), at the path given, and a few that only talents give (see
-- WarcraftsteinClass): a chance to hit twice as hard, health from every kill, and so on. What a
-- talent says it does is worked out from its mods, so it can't say anything else.

-- How many points have to be spent in a tree before a talent in each tier of it can be learnt
local TIER_NEEDS = { 0, 2, 4 }
-- What a number that a talent adds to is when the class doesn't have it
local UNTALENTED = { armor = 1, speed = 1 }
-- How much experience a level takes: this much for the first, and this much more for every next
local LEVEL_XP, LEVEL_MORE_XP = 30, 10

--- @class WarcraftsteinMod
--- @field [1] string Path to the number, e.g. "attack.hits"
--- @field [2] number How much for every rank
--- @field [3] "more"|"plus"

--- @class WarcraftsteinTalent
--- @field id string Named L["warcraftstein_talent_" .. id]
--- @field icon string One of the client's own
--- @field ranks number
--- @field mods WarcraftsteinMod[]

--- @class WarcraftsteinTree
--- @field id string Named L["warcraftstein_tree_" .. id]
--- @field talents WarcraftsteinTalent[] From the top of the tree down

--- @param id string
--- @param icon string
--- @param ranks number
--- @param ... WarcraftsteinMod
--- @return WarcraftsteinTalent
local function talent(id, icon, ranks, ...)
  return { id = id, icon = icon, ranks = ranks, mods = { ... } }
end

--- @type table<string, WarcraftsteinTree[]>
local TALENTS = {
  WARRIOR = {
    {
      id = "arms",
      talents = {
        talent("sharpened", "INV_Sword_27", 2, { "attack.hits", 0.15, "more" }),
        talent("sweeping", "Ability_Rogue_SliceDice", 2, { "attack.splash", 0.6, "plus" }),
        talent("mortal", "Ability_Warrior_SavageBlow", 1, { "crit", 0.25, "plus" }),
      },
    },
    {
      id = "fury",
      talents = {
        talent("flurry", "Ability_GhostWolf", 2, { "attack.every", -0.1, "more" }),
        talent("bloodthirst", "Spell_Nature_BloodLust", 2, { "leech", 4, "plus" }),
        talent("rampage", "Ability_Warrior_Rampage", 1, { "ability.cost", -10, "plus" }, { "refund", 1, "plus" }),
      },
    },
    {
      id = "protection",
      talents = {
        talent("toughness", "Spell_Holy_Devotion", 2, { "armor", -0.08, "plus" }),
        talent("block", "Ability_Defend", 2, { "dodge", 0.1, "plus" }),
        talent("laststand", "Spell_Holy_AshesToAshes", 1, { "health", 40, "plus" }, { "thorns", 8, "plus" }),
      },
    },
  },
  PALADIN = {
    {
      id = "holy",
      talents = {
        talent("intellect", "Spell_Holy_HolyBolt", 2, { "regen", 1.5, "plus" }),
        talent("healinglight", "Spell_Holy_HolyBolt", 2, { "mend", 1, "plus" }),
        talent("holyshield", "Spell_Holy_BlessingOfProtection", 1, { "ability.every", -8, "plus" }),
      },
    },
    {
      id = "protection",
      talents = {
        talent("redoubt", "Ability_Defend", 2, { "armor", -0.07, "plus" }),
        talent("reckoning", "Spell_Holy_BlessingOfStrength", 2, { "thorns", 6, "plus" }),
        talent("sanctuary", "Spell_Nature_LightningShield", 1, { "dodge", 0.15, "plus" }, { "health", 30, "plus" }),
      },
    },
    {
      id = "retribution",
      talents = {
        talent("command", "Ability_Warrior_InnerRage", 2, { "attack.hits", 0.12, "more" }),
        talent("vengeance", "Ability_Racial_Avatar", 2, { "crit", 0.08, "plus" }),
        talent("consecration", "Spell_Holy_InnerFire", 1, { "attack.splash", 1, "plus" }),
      },
    },
  },
  HUNTER = {
    {
      id = "beastmastery",
      talents = {
        talent("endurance", "Spell_Nature_Reincarnation", 2, { "health", 15, "plus" }),
        talent("swiftness", "Ability_Mount_JungleTiger", 2, { "speed", 0.08, "plus" }),
        talent("bestialwrath", "Ability_Druid_FerociousBite", 1, { "ability.every", -2, "plus" }, { "ability.hits", 10, "plus" }),
      },
    },
    {
      id = "marksmanship",
      talents = {
        talent("lethal", "Ability_SearingArrow", 2, { "crit", 0.08, "plus" }),
        talent("barrage", "Ability_UpgradeMoonGlaive", 2, { "ability.hits", 6, "plus" }),
        talent("trueshot", "Ability_TrueShot", 1, { "attack.pierce", 2, "plus" }),
      },
    },
    {
      id = "survival",
      talents = {
        talent("deflection", "Ability_Parry", 2, { "dodge", 0.08, "plus" }),
        talent("concussive", "Spell_Frost_Stun", 2, { "attack.slows", 1.5, "plus" }),
        talent("wyvern", "INV_Spear_02", 1, { "attack.stuns", 0.25, "plus" }),
      },
    },
  },
  ROGUE = {
    {
      id = "assassination",
      talents = {
        talent("malice", "Ability_Racial_BloodRage", 2, { "crit", 0.07, "plus" }),
        talent("lethality", "Ability_CriticalStrike", 2, { "attack.ambush", 1, "plus" }),
        talent("coldblood", "Spell_Ice_Lament", 1, { "leech", 6, "plus" }, { "crit", 0.15, "plus" }),
      },
    },
    {
      id = "combat",
      talents = {
        talent("reflexes", "Spell_Nature_Invisibilty", 2, { "dodge", 0.08, "plus" }),
        talent("bladeflurry", "Ability_Warrior_PunishingBlow", 2, { "attack.splash", 0.6, "plus" }),
        talent("adrenaline", "Spell_Shadow_ShadowWordDominate", 1, { "regen", 15, "plus" }),
      },
    },
    {
      id = "subtlety",
      talents = {
        talent("camouflage", "Ability_Stealth", 2, { "ability.lasts", 3, "plus" }),
        talent("deception", "INV_Mask_01", 2, { "ability.cost", -10, "plus" }),
        talent("preparation", "Spell_Shadow_AntiShadow", 1, { "refund", 3, "plus" }),
      },
    },
  },
  PRIEST = {
    {
      id = "discipline",
      talents = {
        talent("meditation", "Spell_Nature_Sleep", 2, { "regen", 1.5, "plus" }),
        talent("agility", "Ability_Hibernation", 2, { "ability.cost", -8, "plus" }),
        talent("spirittap", "Spell_Shadow_Requiem", 1, { "leech", 10, "plus" }),
      },
    },
    {
      id = "holy",
      talents = {
        talent("improvedhealing", "Spell_Holy_Heal02", 2, { "ability.heals", 12, "plus" }),
        talent("renew", "Spell_Holy_Renew", 2, { "mend", 1.2, "plus" }),
        talent("holyfire", "Spell_Holy_SearingLight", 1, { "attack.hits", 8, "plus" }, { "attack.splash", 0.8, "plus" }),
      },
    },
    {
      id = "shadow",
      talents = {
        talent("weaving", "Spell_Shadow_BlackPlague", 2, { "attack.hits", 0.12, "more" }),
        talent("mindflay", "Spell_Shadow_SiphonMana", 2, { "attack.slows", 1.5, "plus" }),
        talent("vampiric", "Spell_Shadow_UnsummonBuilding", 1, { "attack.drains", 0.2, "plus" }),
      },
    },
  },
  SHAMAN = {
    {
      id = "elemental",
      talents = {
        talent("concussion", "Spell_Fire_Fireball", 2, { "attack.hits", 0.1, "more" }),
        talent("lightningmastery", "Spell_Lightning_LightningBolt01", 2, { "attack.every", -0.08, "more" }),
        talent("elementalfury", "Spell_Fire_Volcano", 1, { "crit", 0.25, "plus" }),
      },
    },
    {
      id = "enhancement",
      talents = {
        talent("thundering", "Ability_ThunderBolt", 2, { "crit", 0.06, "plus" }),
        talent("totems", "Spell_Nature_EarthBindTotem", 2, { "ability.hits", 4, "plus" }, { "ability.lasts", 3, "plus" }),
        talent("stormstrike", "Spell_Holy_SealOfMight", 1, { "attack.chain", 0.5, "plus" }),
      },
    },
    {
      id = "restoration",
      talents = {
        talent("tidalfocus", "Spell_Frost_ManaRecharge", 2, { "ability.cost", -8, "plus" }),
        talent("healingway", "Spell_Nature_HealingWay", 2, { "mend", 1.2, "plus" }),
        talent("manatide", "Spell_Frost_SummonWaterElemental", 1, { "regen", 6, "plus" }),
      },
    },
  },
  MAGE = {
    {
      id = "arcane",
      talents = {
        talent("arcanefocus", "Spell_Holy_Devotion", 2, { "attack.cost", -2, "plus" }),
        talent("arcanemeditation", "Spell_Shadow_SiphonMana", 2, { "regen", 2, "plus" }),
        talent("arcanepower", "Spell_Nature_Lightning", 1, { "attack.hits", 0.4, "more" }),
      },
    },
    {
      id = "fire",
      talents = {
        talent("ignite", "Spell_Fire_Incinerate", 2, { "crit", 0.08, "plus" }),
        talent("impact", "Spell_Fire_MeteorStorm", 2, { "attack.stuns", 0.12, "plus" }),
        talent("flamestrike", "Spell_Fire_SelfDestruct", 1, { "attack.splash", 1.2, "plus" }),
      },
    },
    {
      id = "frost",
      talents = {
        talent("frostbite", "Spell_Frost_FrostArmor", 2, { "ability.freezes", 1, "plus" }),
        talent("permafrost", "Spell_Frost_Wisp", 2, { "attack.slows", 1.5, "plus" }),
        talent("icebarrier", "Spell_Ice_Lament", 1, { "health", 30, "plus" }, { "ability.every", -3, "plus" }),
      },
    },
  },
  WARLOCK = {
    {
      id = "affliction",
      talents = {
        talent("improveddrain", "Spell_Shadow_LifeDrain02", 2, { "attack.drains", 0.1, "plus" }),
        talent("siphon", "Spell_Shadow_Requiem", 2, { "mend", 1, "plus" }),
        talent("darkpact", "Spell_Shadow_DarkRitual", 1, { "ability.gives", 20, "plus" }, { "ability.takes", -10, "plus" }),
      },
    },
    {
      id = "demonology",
      talents = {
        talent("demonicembrace", "Spell_Shadow_Metamorphosis", 2, { "health", 15, "plus" }),
        talent("felconcentration", "Spell_Shadow_FingerOfDeath", 2, { "regen", 1.5, "plus" }),
        talent("soullink", "Spell_Shadow_GatherShadows", 1, { "armor", -0.25, "plus" }),
      },
    },
    {
      id = "destruction",
      talents = {
        talent("bane", "Spell_Shadow_DeathPact", 2, { "attack.every", -0.08, "more" }),
        talent("devastation", "Spell_Fire_FlameShock", 2, { "crit", 0.08, "plus" }),
        talent("ruin", "Spell_Shadow_ShadowWordPain", 1, { "attack.hits", 0.35, "more" }),
      },
    },
  },
  DRUID = {
    {
      id = "balance",
      talents = {
        talent("starlight", "Spell_Nature_AbolishMagic", 2, { "attack.every", -0.08, "more" }),
        talent("moonglow", "Spell_Nature_Sentinal", 2, { "attack.cost", -2, "plus" }),
        talent("naturesgrace", "Spell_Nature_NaturesBlessing", 1, { "crit", 0.25, "plus" }),
      },
    },
    {
      id = "feral",
      talents = {
        talent("ferocity", "INV_Misc_MonsterClaw_04", 2, { "ability.attack.hits", 0.15, "more" }),
        talent("feline", "Spell_Nature_SpiritWolf", 2, { "ability.speed", 0.1, "plus" }, { "ability.lasts", 2, "plus" }),
        talent("leader", "Spell_Nature_UnyeildingStamina", 1, { "leech", 6, "plus" }, { "ability.cost", -15, "plus" }),
      },
    },
    {
      id = "restoration",
      talents = {
        talent("furor", "Spell_Holy_BlessingOfStamina", 2, { "regen", 1.5, "plus" }),
        talent("regrowth", "Spell_Nature_ResistNature", 2, { "mend", 1.2, "plus" }),
        talent("swiftmend", "Spell_Nature_RavenForm", 1, { "health", 30, "plus" }, { "dodge", 0.1, "plus" }),
      },
    },
  },
}

--- What a class is with the talents learnt
--- @param class string
--- @param learned table<string, number> Ranks by talent id
--- @return WarcraftsteinClass
local function build(class, learned)
  local spec = Tables.Copy(CLASSES[class])
  for _, tree in ipairs(TALENTS[class]) do
    for _, known in ipairs(tree.talents) do
      local rank = learned[known.id] or 0
      for _, mod in ipairs(rank > 0 and known.mods or {}) do
        local owner, key = spec, nil
        for part in mod[1]:gmatch("[^.]+") do
          if key then
            owner = owner and owner[key]
          end
          key = part
        end
        if owner and mod[3] == "more" then
          owner[key] = owner[key] and owner[key] * (1 + mod[2] * rank)
        elseif owner then
          owner[key] = (owner[key] or UNTALENTED[key] or 0) + mod[2] * rank
        end
      end
    end
  end
  return spec
end

-- The numbers a talent changes that are said as a share: "10% faster" rather than "0.1 faster"
local SHARES = { crit = true, dodge = true, armor = true, speed = true, ["attack.stuns"] = true, ["attack.drains"] = true, ["attack.chain"] = true, ["ability.speed"] = true }

--- What a talent does at a rank, a line for every number it changes
--- @param known WarcraftsteinTalent
--- @param rank number
--- @return string
local function talentText(known, rank)
  local lines = {}
  for _, mod in ipairs(known.mods) do
    -- Said the way round that needs no minus sign: "10% faster" rather than "-10% slower"
    local value = math.abs(mod[2] * rank) * ((mod[3] == "more" or SHARES[mod[1]]) and 100 or 1)
    local key = "warcraftstein_mod_" .. mod[1]:gsub("%.", "_") .. "_" .. mod[3]
    lines[#lines + 1] = L[key]:format(string.format("%g", math.floor(value * 10 + 0.5) / 10))
  end
  return table.concat(lines, "\n")
end

--- How much experience it takes to get from a level to the next
--- @param level number
--- @return number
local function levelXp(level)
  return LEVEL_XP + LEVEL_MORE_XP * (level - 1)
end

-----------------------------
-- Foes
-----------------------------
-- Who the player meets in there, and what each is like: the first of its four pictures (in
-- Images/Warcraftstein/sprites: standing, stepping, striking, dead), what it starts with,
-- squares a second, from how far it sees the player while it waits, how near it comes, what its
-- blow takes off, how long it winds up for the first and how long until every next, and the
-- experience it is worth. Besides that a foe can cast from afar and keep its distance (`casts`),
-- take less of every blow (`armor`), be seen through (`ghostly`) and heal from what it takes
-- (`drains`). Herod (`boss`) keeps the portal shut while he stands, spins with his axe every so
-- often (`spins`) and is angrier still once he is hurt enough (`enrage`).

--- @class WarcraftsteinFoe
--- @field picture number
--- @field health number
--- @field speed number
--- @field wakes number
--- @field reach number
--- @field hits number
--- @field windup number
--- @field every number
--- @field xp number
--- @field casts { range: number, keep: number, hits: number, every: number, speed: number, tint: number[] }?
--- @field armor number?
--- @field ghostly boolean?
--- @field drains number?
--- @field boss boolean?
--- @field spins { every: number, lasts: number, hits: number, each: number, reach: number, speed: number }?
--- @field enrage number? The share of its health below which it is angry
--- @field yells boolean? Says something when it sees the player

--- @type table<string, WarcraftsteinFoe>
local FOES = {
  soldier = { picture = 8, health = 45, speed = 2.2, wakes = 7, reach = 0.95, hits = 12, windup = 0.35, every = 0.9, xp = 10, yells = true },
  monk = { picture = 12, health = 30, speed = 3, wakes = 8, reach = 0.85, hits = 7, windup = 0.2, every = 0.55, xp = 8, yells = true },
  adept = {
    picture = 16,
    health = 32,
    speed = 1.8,
    wakes = 9,
    reach = 0.95,
    hits = 6,
    windup = 0.5,
    every = 1.4,
    xp = 14,
    yells = true,
    casts = { range = 7, keep = 3.5, hits = 13, every = 2, speed = 5.5, tint = { 1, 0.45, 0.12 } },
  },
  defender = { picture = 20, health = 100, speed = 1.6, wakes = 6, reach = 1.1, hits = 20, windup = 0.6, every = 1.4, xp = 25, armor = 0.75, yells = true },
  herod = {
    picture = 24,
    health = 320,
    speed = 2,
    wakes = 6,
    reach = 1.25,
    hits = 24,
    windup = 0.5,
    every = 1.2,
    xp = 80,
    boss = true,
    spins = { every = 9, lasts = 2.5, hits = 10, each = 0.4, reach = 1.7, speed = 2.8 },
    enrage = 0.3,
  },
  phantasm = { picture = 28, health = 28, speed = 2.4, wakes = 8, reach = 0.9, hits = 9, windup = 0.3, every = 0.9, xp = 9, ghostly = true, drains = 0.5 },
}

-----------------------------
-- Moves
-----------------------------

--- @param state WarcraftsteinState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  if seat ~= 1 then
    return false, "not_your_turn"
  elseif state.found or state.dead then
    return false, "invalid_move"
  elseif not state.class then
    -- Nothing happens to anyone who isn't anyone yet
    return CLASSES[move:match("^" .. CLASS .. "(%u+)$") or ""] ~= nil, "invalid_move"
  elseif move ~= EXIT and move ~= DEAD then
    return false, "invalid_move"
  end
  return true
end

--- @param state WarcraftsteinState
--- @param seat number
--- @param move string
--- @return { found: boolean }
local function apply(state, _, move)
  if not state.class then
    state.class = move:sub(2)
    return { found = false }
  end
  state.found, state.dead = move == EXIT, move == DEAD
  return { found = state.found }
end

--- Every class to be, and once the player is somebody the two ways out of the monastery
--- @param state WarcraftsteinState
--- @return string[]
local function moves(state)
  if state.class then
    return { EXIT, DEAD }
  end
  local list = {}
  for _, class in ipairs(CLASS_ORDER) do
    list[#list + 1] = CLASS .. class
  end
  return list
end

--- @param state WarcraftsteinState
--- @return { winner: number }?
local function result(state)
  if state.found then
    return { winner = 1 }
  end
  return state.dead and { winner = 0 } or nil
end

--- What is on the square a point lies on
--- @param state WarcraftsteinState
--- @param x number
--- @param y number
--- @return number kind Wall for anywhere that isn't in the monastery at all
local function kindAt(state, x, y)
  local column, row = math.floor(x), math.floor(y)
  if column < 0 or row < 0 or column >= state.side or row >= state.side then
    return 1
  end
  return state.cells[row * state.side + column + 1]
end

--- Looks from a point along a line until something is in the way
--- @param state WarcraftsteinState
--- @param x number Where from
--- @param y number
--- @param towardsX number Which way. How long this is doesn't matter for what is hit, only for how far away it is said to be
--- @param towardsY number
--- @return number distance How many times the way given it is to what was hit
--- @return number kind What was hit
--- @return number across Where on its face, from 0 at one edge of the square to 1 at the other
--- @return boolean flank It was hit on a face that looks up or down the map rather than left or right
local function cast(state, x, y, towardsX, towardsY)
  local cells, side = state.cells, state.side
  local column, row = math.floor(x), math.floor(y)
  -- How far along the line it is from one line of the grid to the next, across and down, and
  -- how far to the first of each
  local perColumn = towardsX == 0 and math.huge or math.abs(1 / towardsX)
  local perRow = towardsY == 0 and math.huge or math.abs(1 / towardsY)
  local stepColumn, stepRow = towardsX < 0 and -1 or 1, towardsY < 0 and -1 or 1
  local toColumn = (towardsX < 0 and x - column or column + 1 - x) * perColumn
  local toRow = (towardsY < 0 and y - row or row + 1 - y) * perRow

  local flank, kind = false, nil
  repeat
    -- On to whichever line of the grid comes first
    if toColumn < toRow then
      toColumn, column, flank = toColumn + perColumn, column + stepColumn, false
    else
      toRow, row, flank = toRow + perRow, row + stepRow, true
    end
    -- The monastery has a wall all round, so there is always something. Should there not be,
    -- the look ends where the grid does
    kind = (column >= 0 and row >= 0 and column < side and row < side) and cells[row * side + column + 1] or 1
  until kind ~= OPEN

  local distance = flank and toRow - perRow or toColumn - perColumn
  local across = flank and x + distance * towardsX or y + distance * towardsY
  return distance, kind, across - math.floor(across), flank
end

--- Whether there is nothing but air between two points
--- @param state WarcraftsteinState
--- @param x number
--- @param y number
--- @param otherX number
--- @param otherY number
--- @return boolean
local function sees(state, x, y, otherX, otherY)
  if x == otherX and y == otherY then
    return true
  end
  return cast(state, x, y, otherX - x, otherY - y) >= 1
end

-----------------------------
-- View
-----------------------------
-- What the player sees is drawn the way Wolfenstein 3D drew it, a column of the screen at a
-- time: for every column a look along the floor says how far away the nearest wall is that way
-- and where on its face it was hit, and the column shows that strip of the wall's picture, as
-- tall as it is near. The client has no screen to paint on, only pictures to stretch, so every
-- column is one: a texture as wide as a column that is told each time which strip of which wall
-- to show (SetTexCoord) and how tall to be.
--
-- Floor and ceiling are drawn the other way round, a row at a time. Everything on one row of the
-- floor is as far away as everything else on it, and what of the floor lies along it is a
-- straight line across the map, from where the left edge of what is seen meets it to where the
-- right edge does. So a row is one picture of the floor, tiled, told which corners of the map
-- its corners are (SetTexCoord with all eight numbers), and the ceiling's rows the same, upside
-- down. A row is a few pixels tall, so the floor is bent a little at every row: nobody minds.
--
-- The light is the dark of the monastery, less the further off, and the warm light of every
-- brazier and candelabra on whatever is near it: walls, floor and everyone standing about. The
-- floor is lit only by how far off it is, a row being one colour.
--
-- Whatever stands in the monastery (the Crusade, a potion, a bolt on its way, a brazier) is a
-- picture that stands on the floor and always faces the player. It is drawn in the same columns
-- the walls are, a strip of its picture in each, and only in those where the wall behind it is
-- further away than it is, which is all it takes for one to be half hidden by a corner. Several
-- can be seen in one column, the nearer over the further: there are a few layers of strips for
-- that (LAYERS), and what is further away than there are layers for shares the one at the back.
--
-- The player walks with W and S or the arrow keys, turns with A and D or the arrows, steps
-- sideways with Q and E, strikes with the space bar, does what their class can do with F and
-- opens their talents with N, for as long as a key is held and the cursor is over the game.
-- With the right mouse button held the mouse turns them instead, and A and D step sideways, the
-- way the client itself has it. With the cursor anywhere else, or the talents open, the
-- monastery stands still, Crusade and all. Nothing is drawn while nothing in it moves.
--
-- Getting round a corner is made easy three ways: a corner that is only just in the way is
-- stepped round rather than stopped at, a player who walks into a wall at an angle and slides
-- along it is turned to face the way they are going, and what is seen is wide.
--
-- A foe waits until it sees the player from near enough, or is hit, and wakes the ones around
-- it that see it when it does. Then it comes for them: by the straight way while it sees them, and by the
-- shortest way through the monastery when it doesn't (View:trail), until it hasn't seen them for
-- a good while. Near enough it stops and strikes, again and again; one that casts stays back and
-- casts. A player nobody can see (a rogue, or anyone in the sanctuary) is only looked for where
-- they were seen last. Nobody of the Crusade sets foot in the sanctuary, and what they cast goes
-- out at its door.

local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\Warcraftstein\\"
local ICONS = "Interface\\Icons\\"
-- The walls by kind, and how many pixels one is wide
local PICTURES = {
  [NAVE] = IMAGES .. "nave",
  [WINDOW] = IMAGES .. "window",
  [BANNER] = IMAGES .. "banner",
  [LIBRARY] = IMAGES .. "library",
  [ARMORY] = IMAGES .. "armory",
  [CRYPT] = IMAGES .. "crypt",
  [PORTAL] = IMAGES .. "portal",
  [SHRINE] = IMAGES .. "shrine",
}
local WALL_TEXELS = 128
local FLOOR_PICTURE, CEILING_PICTURE = IMAGES .. "floor", IMAGES .. "ceiling"
-- Everything that stands about, eight to a row of one file, and how many pixels one is and how
-- many there are across and down the file
local SPRITES, TEXELS, SHEET = IMAGES .. "sprites", 64, 8
local BOLT, TOTEM, FALLEN, STRIKING, STANDING = 0, 3, 3, 2, 0
local POTIONS = { health = 1, power = 2 }
-- What stands about: its picture (and how many there are of it, one after the other), how
-- much light it gives and of what colour if not firelight, and how far from where it stands it
-- is in the way, in squares: about as far as its picture is wide, a pole being a pole
local HOLY_LIGHT = { 0.7, 0.88, 1.2 }
local DECOR = {
  fountain = { picture = 33, frames = 2, light = 1.4, color = HOLY_LIGHT, girth = 0.42 },
  brazier = { picture = 4, light = 1, girth = 0.2 },
  candelabra = { picture = 5, light = 0.8, girth = 0.08 },
  tombstone = { picture = 6, girth = 0.2 },
  lectern = { picture = 7, girth = 0.18 },
  flag = { picture = 32, girth = 0.05 },
}
-- And everything the player can hold, ready and swung
local WEAPONS, WEAPON_SHEET = IMAGES .. "weapons", 512
-- Where the classes have their pictures, for the client that says where in it (CLASS_ICON_TCOORDS)
local CLASS_PICTURES = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"
local BOOK_ICON = ICONS .. "INV_Misc_Book_09"
-- How many things can be seen one behind the other in a column, and how near one is drawn at all
local LAYERS, NEAREST = 6, 0.15
-- How wide what is seen is for how tall, and how far to either side it reaches for every step
-- ahead: about 77 degrees from one edge to the other, wide enough to see a way off to the side
-- before it is behind
local ASPECT, REACH = 1.6, 0.8
-- How wide a column is at most, and how many of them there are at least and at most
local SLICE, FEWEST, MOST = 3, 60, 240
-- How many pixels tall a row of the floor or ceiling is, and how far off the furthest row is
-- taken to be, which is too far to make anything out anyway
local ROW, FARTHEST = 3, 40
-- How quickly it gets dark with distance, how dark it gets at most, and how much less light
-- there is on a wall that faces up or down the map. The colour of the dark, and of firelight
local FOG, DARKEST, FLANK = 0.36, 0.08, 0.72
local DARK_LIGHT, FIRE_LIGHT = { 0.6, 0.6, 0.74 }, { 1.15, 0.78, 0.42 }
-- How far a light reaches, and how quickly it fades on the way
local LIGHT_RANGE, LIGHT_FADE = 6, 0.45
-- Squares a second, how much of that going backwards, turns (in radians) a second, and how
-- near a wall the player can get
local WALK, BACKWARDS, TURN, GIRTH = 2.6, 0.6, 3.6, 0.22
-- A turn begins at this much of that and takes this many seconds to get to all of it, so that
-- a tap on the key is a small correction and holding it gets round a corner in time
local TURN_START, TURN_RAMP = 0.4, 0.15
-- With the right mouse button held the mouse turns the player: radians for every pixel across
local MOUSE_TURN = 0.006
-- How much of a corner that alone is in the way the player is helped round, in squares
local CORNER = 0.3
-- How quickly someone walking along a wall they walked into at an angle is turned to look where
-- they are going, in radians a second, and from how far off straight ahead at most
local STEER, STEER_FROM = 1.8, 1.4
-- How far what the player holds sways as they walk, as a share of how tall what is seen is
local SWAY = 0.025
-- The longest time a frame is taken to have lasted, so a hitch doesn't carry anyone through a wall
local LONGEST_FRAME = 0.1
-- Below what the player's health is shown in red, and how long what they hold is shown swung
local HEALTH_LOW, SWUNG = 30, 0.18
-- How far the shout of one foe that wakes is heard by others, how long they look for a player
-- they can't see, how long a foe is shown striking and hurt, and how long a stun lasts
local CALLS, LOOKS, SHOWN, HURT, STUN = 4, 10, 0.25, 0.3, 1.2
-- How long something said stays written, and how long until anyone of the Crusade says something again
local SAID, QUIET = 3, 8
-- A bolt: squares a second, how far it goes at a time, and how near it has to come to hit
local BOLT_SPEED, BOLT_STEP, BOLT_GIRTH = 10, 0.2, 0.35
-- How far a bolt that goes on to another foe jumps
local CHAIN = 2.5
-- How much health a second the sanctuary gives back, the colour it is seen through, and how
-- long the fountain's water shows one picture
local SANCTUARY_MEND, SANCTUARY_VEIL, RIPPLE = 8, { 1, 0.85, 0.45, 0.07 }, 0.3
-- What a potion gives, and from how near it is picked up
local POTION, GRASP = { health = 35, power = 50 }, 0.45
-- How near two that walk get to each other, how far a foe walks on one picture, and how near
-- to where it is going counts as there
local APART, STRIDE, THERE = 0.45, 0.35, 0.05
-- The client's own sounds, by file: what each class's blow sounds like going and landing (a
-- buff's own blow, the cat's claws, sounds like MELEE_SOUNDS), and what doing each ability does
local STRIKE_SOUNDS = {
  WARRIOR = { 567936, 567880 },
  PALADIN = { 567938, 567880 },
  HUNTER = { 567674, 567672 },
  ROGUE = { 567937, 567880 },
  PRIEST = { 569719, 569402 },
  SHAMAN = { 568228, 568516 },
  MAGE = { 568765, 568461 },
  WARLOCK = { 568935, 569138 },
  DRUID = { 569151, 568008 },
}
local MELEE_SOUNDS = { 567937, 567880 }
local ABILITY_SOUNDS = { whirlwind = 568519, shield = 569738, multishot = 567673, stealth = 569423, heal = 569570,
  totem = 568641, nova = 569378, tap = 568426, cat = 568546 }
-- How the player sees that a blow or an ability went off: the view lights up in its colour this
-- much, for this long; and what a blow's own colour is if it has none
local CAST_GLOW, CAST_GLOW_SECONDS, STRIKE_COLOR = 0.16, 0.18, { 1, 0.95, 0.8 }
-- How far what the player holds is thrust up as they strike, as a share of how tall what is seen is
local THRUST = 0.05
-- How long until the player is told again why what they pressed didn't happen
local BALK_AGAIN = 1
local HURT_TINT, FROZEN_TINT, SLOWED_TINT, ANGRY_TINT = { 1, 0.35, 0.35 }, { 0.5, 0.75, 1 }, { 0.75, 0.95, 0.75 }, { 1, 0.6, 0.55 }
local POWER_COLORS = { rage = { 0.78, 0.16, 0.16 }, mana = { 0.2, 0.42, 1 }, energy = { 1, 0.88, 0.2 } }
local XP_COLOR = { 0.62, 0.32, 1 }
-- How many lines the Crusade has to say when it sees someone (L["warcraftstein_yell_" .. n])
local YELLS = 3
-- What a key does: steps ahead, steps to the right and turns to the right
local KEYS = {
  W = { 1, 0, 0 },
  UP = { 1, 0, 0 },
  S = { -1, 0, 0 },
  DOWN = { -1, 0, 0 },
  A = { 0, 0, -1 },
  LEFT = { 0, 0, -1 },
  D = { 0, 0, 1 },
  RIGHT = { 0, 0, 1 },
  Q = { 0, -1, 0 },
  E = { 0, 1, 0 },
}
local STRIKE, CAST, BOOK, CLOSE = "SPACE", "F", "N", "ESCAPE"
local MARGIN, STAT_WIDTH, STAT_HEIGHT, BAR_WIDTH = 8, 80, 38, 150
local PICK_SIZE, PICK_GAP = 40, 6
-- The talents: how wide a tree is, how big a talent and how far apart they are down a tree
local TREE_WIDTH, TREE_GAP, TALENT_SIZE, TIER_GAP = 120, 18, 40, 30
-- The fanfare, the ding and what to play on a client that doesn't have them
local FOUND_SOUND, FOUND_SOUND_ELSE, LEVEL_SOUND = "UI_EPICLOOT_TOAST", "IG_QUEST_LIST_COMPLETE", "LEVELUP"

--- @class WarcraftsteinPose
--- @field x number
--- @field y number
--- @field facing number

--- Something that stands in the monastery and is drawn there
--- @class WarcraftsteinThing
--- @field x number
--- @field y number
--- @field depth number? How far ahead of the player it was when it was last drawn
--- @field off number? And where across what is seen, from -1 at the left edge to 1 at the right
--- @field picture number? Which picture of the file it was shown as
--- @field first number? Something that stands about: the first of its pictures, which it is shown as one after the other
--- @field tint number[]? In what colour, white if none
--- @field glows boolean? And whether it was as bright as it is from anywhere
--- @field alpha number? And how much of it was to be seen

--- @class WarcraftsteinMob: WarcraftsteinThing
--- @field kind string
--- @field foe WarcraftsteinFoe
--- @field health number
--- @field awake boolean It is after the player
--- @field dead boolean
--- @field toX number? Where it last saw the player
--- @field toY number?
--- @field lost number Seconds since it did
--- @field swing number? Seconds until its blow lands, while the player is within reach
--- @field wait number Seconds until it casts again, or spins
--- @field spinning number Seconds Herod still spins
--- @field spun number Seconds until his spinning axe hits again
--- @field angry boolean
--- @field struck number Seconds it is still shown striking
--- @field hurt number Seconds it is still shown hurt
--- @field frozen number Seconds it can still do nothing
--- @field slowed number Seconds it still goes at half the speed
--- @field walked number How far it has walked, for which picture of it to show

--- A bolt on its way, the player's or a foe's
--- @class WarcraftsteinBolt: WarcraftsteinThing
--- @field byX number Which way it goes, a square long
--- @field byY number
--- @field speed number
--- @field attack WarcraftsteinAttack? The player's: what it does
--- @field hits number? A foe's: what it takes off
--- @field through number How many more foes it goes through
--- @field met table<WarcraftsteinMob, boolean> The ones it went through already

--- How a game is going, which the engine knows nothing of
--- @class WarcraftsteinRun
--- @field class string
--- @field spec WarcraftsteinClass What the class is with what has been learnt
--- @field learned table<string, number> Talent ranks by id
--- @field level number
--- @field xp number Towards the next level
--- @field points number Talent points not spent yet
--- @field pose WarcraftsteinPose
--- @field health number
--- @field power number
--- @field mobs WarcraftsteinMob[]
--- @field boss WarcraftsteinMob? Herod, while there is one
--- @field loot WarcraftsteinThing[] The potions nobody drank yet
--- @field decor WarcraftsteinThing[]
--- @field lights WarcraftsteinThing[] The ones of those that give light
--- @field bolts WarcraftsteinBolt[] The player's on their way
--- @field shots WarcraftsteinBolt[] And the Crusade's
--- @field totem WarcraftsteinThing? The one that stands, if one does
--- @field buff WarcraftsteinAbility? What the player is for the moment
--- @field buffLeft number And for how many seconds more
--- @field cooldown number Seconds until the player can strike again
--- @field ready number Seconds until they can do what their class does again
--- @field swung number Seconds what they hold is still shown swung
--- @field walked number How far they have walked, for how what they hold sways
--- @field sanctuary WarcraftsteinRoom The room the player started in
--- @field safe boolean The player is in it
--- @field ripple number Seconds the fountain has been running, for which picture of it to show
--- @field said number Seconds what was said last stays written
--- @field quiet number Seconds until the Crusade says anything again
--- @field dice Random For whatever is left to chance: a hit that is twice as hard, a blow dodged
--- @field trail table<number, number>? How far the walk to the player is from every square, see View:trail
--- @field trailTo number? The square that is counted from

--- @class WarcraftsteinView: GameViewObject
--- @field stage Frame
--- @field ticker Frame Takes the keys and the time
--- @field frame Frame What is seen, and what cuts off whatever is too tall for it
--- @field columns Texture[] As many as were ever needed
--- @field count number How many of them are in use
--- @field depths number[] How far away the wall in every column is
--- @field floors Texture[] The rows of the floor, from the middle down, as many as were ever needed
--- @field ceilings Texture[] And of the ceiling, from the middle up
--- @field rows number How many of each are in use
--- @field strips table<number, Texture>[] What things are drawn with, by layer and column. Made when first needed
--- @field lit Texture[] The ones that are showing
--- @field seen WarcraftsteinThing[] The things in front of the player, furthest first
--- @field near WarcraftsteinThing[] The lights near enough to the player to light anything they see
--- @field stamp number Counts the times the monastery was drawn
--- @field weapon Texture
--- @field veil Texture What everything is seen through while the player is something special
--- @field compass FontString
--- @field said FontString What the Crusade says
--- @field xp Texture How far the player is towards their next level
--- @field bossBar Frame Herod's health, while he is after the player
--- @field picker Frame Where the player says who they are
--- @field picks table<string, Button> By class
--- @field book Frame Where the player learns talents
--- @field tiles Button[][] By tree and tier
--- @field portrait Frame
--- @field health Frame
--- @field power Frame
--- @field ability Button
--- @field talents Button Opens the book
--- @field time Frame
--- @field best Frame
--- @field hint FontString
--- @field effects Effects
--- @field view GameView? What was last asked for
--- @field run WarcraftsteinRun? How the game on screen is going
--- @field pose WarcraftsteinPose? Where the player is in it
--- @field runs table<string, WarcraftsteinRun> And how every game that was looked at is going, by match
--- @field down table<string, boolean> The keys that are held
--- @field spin number How much of a full turn the player is turning at, see TURN_START
--- @field spun number And which way, right if more than nothing
--- @field dragged number? Where across the screen the cursor was the last time, while the mouse turns the player
local View = {}
View.__index = View

--- The class of the character the player is on, as far as the monastery knows it
--- @return string
local function ownClass()
  local class = UnitClass and select(2, UnitClass("player"))
  return CLASSES[class] and class or USUAL_CLASS
end

--- @param class string
--- @return string
local function className(class)
  return LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class] or L["warcraftstein_class_" .. class]
end

--- Says what a class is in the monastery, next to whatever the cursor is on
--- @param owner Frame
--- @param class string
local function describe(owner, class)
  local spec = CLASSES[class]
  GameTooltip:SetOwner(owner, "ANCHOR_TOP")
  GameTooltip:SetText(className(class), spec.color[1], spec.color[2], spec.color[3])
  GameTooltip:AddLine(L["warcraftstein_kit_" .. class], 1, 1, 1, true)
  GameTooltip:AddLine(L["warcraftstein_ability_line"]:format(CAST, L["warcraftstein_ability_" .. spec.ability.id]), 1, 0.82, 0, true)
  GameTooltip:Show()
end

--- A bar that is as full as there is of something, with the number on it
--- @param parent Frame
--- @return Frame bar Set(value, most, text) fills it, Tint(color) colours it
local function createBar(parent)
  local bar = private.Widgets.Panel(parent)
  local fill = bar:CreateTexture(nil, "ARTWORK")
  fill:SetPoint("TOPLEFT", 1, -1)
  fill:SetPoint("BOTTOMLEFT", 1, 1)
  local text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  text:SetPoint("CENTER")

  --- @param value number
  --- @param most number
  --- @param words string? What it says, the value if left out
  function bar:Set(value, most, words)
    -- Anything at all is shown as something: nobody is dead at 1
    value = math.ceil(value)
    if value == self.value and most == self.most and self.wide == self.filled then
      return
    end
    self.value, self.most, self.filled = value, most, self.wide
    fill:SetWidth(math.max(0.01, ((self.wide or 0) - 2) * math.min(1, value / most)))
    fill:SetShown(value > 0)
    text:SetText(words or value)
  end

  --- @param color number[]
  function bar:Tint(color)
    if color ~= self.tint then
      self.tint = color
      fill:SetColorTexture(color[1], color[2], color[3], 0.85)
    end
  end

  return bar
end

--- A square button with an icon in it
--- @param parent Frame
--- @param size number
--- @return Button
local function createIcon(parent, size)
  local button = private.Widgets.Panel(parent, "Button")
  button:SetSize(size, size)
  button.icon = button:CreateTexture(nil, "ARTWORK")
  button.icon:SetPoint("TOPLEFT", 2, -2)
  button.icon:SetPoint("BOTTOMRIGHT", -2, 2)
  -- Without the client's own border round every icon
  button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  local hover = button:CreateTexture(nil, "HIGHLIGHT")
  hover:SetAllPoints()
  hover:SetColorTexture(1, 0.82, 0, 0.2)
  return button
end

--- @param stage Frame
--- @return WarcraftsteinView
local function createView(stage)
  --- @type WarcraftsteinView
  local self = setmetatable({ stage = stage, columns = {}, count = 0, floors = {}, ceilings = {}, rows = 0, runs = {}, down = {}, pressed = {} }, View)
  self.depths, self.strips, self.lit, self.seen, self.near, self.stamp = {}, {}, {}, {}, {}, 0
  self.spin, self.spun = 0, 0
  self.width, self.height = 0, 0
  -- For whoever wants to know what the numbers are
  self.foes, self.trees = FOES, TALENTS
  local Widgets = private.Widgets

  local ticker = CreateFrame("Frame", nil, stage)
  ticker:SetAllPoints()
  self.ticker = ticker
  -- For whoever finds the frame and wants to know where the player is
  ticker.walker = self
  Widgets.Keys(ticker, function(key)
    local view = self.view
    if not view or not view.canMove then
      return false
    end
    if not view.state.class then
      -- Nobody yet: the key that strikes is as good as picking the class the player is anyway
      if key == STRIKE then
        view.submit(CLASS .. ownClass())
      end
      return key == STRIKE
    end
    if key == BOOK or (key == CLOSE and self.book:IsShown()) then
      self:openBook(key == BOOK and not self.book:IsShown())
      return true
    end
    if not (KEYS[key] or key == STRIKE or key == CAST) then
      return false
    end
    self.down[key] = true
    -- Pressed, rather than held: if nothing comes of it, the player is told why
    self.pressed[key] = true
    return true
  end, true)
  ticker:SetScript("OnKeyUp", function(_, key)
    self.down[key] = nil
  end)
  ticker:SetScript("OnHide", function()
    self.down = {}
  end)
  ticker:SetScript("OnUpdate", function(_, elapsed)
    self:tick()
    self:live(elapsed)
  end)

  self.border = Widgets.Panel(stage)
  -- A click in the view is not a grab at the window: it must not get through and drag it about
  self.border:EnableMouse(true)
  self.frame = CreateFrame("Frame", nil, self.border)
  self.frame:SetClipsChildren(true)
  local dark = self.frame:CreateTexture(nil, "BACKGROUND", nil, -8)
  dark:SetAllPoints()
  dark:SetColorTexture(0, 0, 0, 1)
  self.compass = self.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  self.compass:SetPoint("TOP", 0, -6)
  self.said = self.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  self.said:SetPoint("TOP", 0, -52)
  self.said:SetTextColor(1, 0.25, 0.2)
  self.said:Hide()
  -- Over everything that stands in the monastery, under what the player holds
  self.veil = self.frame:CreateTexture(nil, "ARTWORK", nil, 7)
  self.veil:SetAllPoints()
  self.veil:Hide()
  self.weapon = self.frame:CreateTexture(nil, "OVERLAY")
  self.weapon:SetTexture(WEAPONS)
  self.xp = self.frame:CreateTexture(nil, "OVERLAY", nil, 7)
  self.xp:SetPoint("BOTTOMLEFT")
  self.xp:SetHeight(3)
  self.xp:SetColorTexture(XP_COLOR[1], XP_COLOR[2], XP_COLOR[3], 0.9)
  self.bossBar = createBar(self.frame)
  self.bossBar:SetPoint("TOP", 0, -30)
  self.bossBar:Tint({ 0.75, 0.1, 0.1 })
  self.bossBar:Hide()

  self:createPicker()
  self:createBook()

  self.portrait = Widgets.Panel(stage)
  self.portrait:SetSize(STAT_HEIGHT, STAT_HEIGHT)
  self.portrait.face = self.portrait:CreateTexture(nil, "ARTWORK")
  self.portrait.face:SetPoint("TOPLEFT", 2, -2)
  self.portrait.face:SetPoint("BOTTOMRIGHT", -2, 2)
  self.portrait.level = self.portrait:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  self.portrait.level:SetPoint("BOTTOMLEFT", 2, 2)
  self.health, self.power = createBar(stage), createBar(stage)

  local ability = createIcon(stage, STAT_HEIGHT)
  ability.wait = ability:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  ability.wait:SetPoint("CENTER")
  ability.key = ability:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  ability.key:SetPoint("BOTTOMRIGHT", -3, 3)
  ability.key:SetText(CAST)
  ability:SetScript("OnClick", function()
    if self.run and self.view.canMove and not self.book:IsShown() then
      local done, why = self:cast()
      if not done then
        self:balk(why)
      end
      self:render()
      self:gauge()
    end
  end)
  ability:SetScript("OnEnter", function(button)
    if self.run then
      describe(button, self.run.class)
    end
  end)
  ability:SetScript("OnLeave", GameTooltip_Hide)
  self.ability = ability

  local talents = createIcon(stage, STAT_HEIGHT)
  talents.icon:SetTexture(BOOK_ICON)
  talents.points = talents:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  talents.points:SetPoint("TOPRIGHT", -3, -3)
  talents.key = talents:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  talents.key:SetPoint("BOTTOMRIGHT", -3, 3)
  talents.key:SetText(BOOK)
  talents.pulse = Widgets.Pulse(talents.icon)
  talents:SetScript("OnClick", function()
    if self.run and self.view.canMove then
      self:openBook(not self.book:IsShown())
    end
  end)
  talents:SetScript("OnEnter", function(button)
    GameTooltip:SetOwner(button, "ANCHOR_TOP")
    GameTooltip:SetText(L["warcraftstein_talents"])
    GameTooltip:AddLine(L["warcraftstein_talents_tip"], 1, 1, 1, true)
    GameTooltip:Show()
  end)
  talents:SetScript("OnLeave", GameTooltip_Hide)
  self.talents = talents

  self.time = Widgets.Stat(stage, L["stat_time"], STAT_WIDTH, STAT_HEIGHT)
  self.best = Widgets.Stat(stage, L["stat_best"], STAT_WIDTH, STAT_HEIGHT)
  self.hint = stage:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  self.hint:SetJustifyH("RIGHT")
  self.hint:SetText(L["warcraftstein_hint"])

  self.effects = private.Effects.New(stage)
  return self
end

--- Builds what the player says who they are with: a button for every class, over the monastery
function View:createPicker()
  local picker = CreateFrame("Frame", nil, self.frame)
  picker:SetAllPoints()
  picker:SetFrameLevel(self.frame:GetFrameLevel() + 2)
  local shade = picker:CreateTexture(nil, "BACKGROUND")
  shade:SetAllPoints()
  shade:SetColorTexture(0.05, 0.01, 0.01, 0.85)
  -- Everything in it is laid out for a monastery that is wide enough, and made smaller for one that isn't
  local row = CreateFrame("Frame", nil, picker)
  row:SetSize(#CLASS_ORDER * (PICK_SIZE + PICK_GAP) - PICK_GAP, PICK_SIZE)
  row:SetPoint("CENTER")
  picker.row = row
  local title = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("BOTTOM", row, "TOP", 0, 14)
  title:SetText(L["warcraftstein_pick"])
  picker.own = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  picker.own:SetPoint("TOP", row, "BOTTOM", 0, -14)

  self.picks = {}
  for index, class in ipairs(CLASS_ORDER) do
    local pick = createIcon(row, PICK_SIZE)
    pick:SetPoint("LEFT", (index - 1) * (PICK_SIZE + PICK_GAP), 0)
    local where = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if where then
      pick.icon:SetTexture(CLASS_PICTURES)
      pick.icon:SetTexCoord(where[1], where[2], where[3], where[4])
    else
      -- No picture of it here: what it does stands in for what it is
      pick.icon:SetTexture(ICONS .. CLASSES[class].ability.icon)
    end
    pick:SetScript("OnClick", function()
      local view = self.view
      if view and view.canMove and not view.state.class then
        view.submit(CLASS .. class)
      end
    end)
    pick:SetScript("OnEnter", function(button)
      describe(button, class)
    end)
    pick:SetScript("OnLeave", GameTooltip_Hide)
    self.picks[class] = pick
  end
  picker:Hide()
  self.picker = picker
end

--- Builds where talents are learnt: three trees side by side, three talents down each, over the
--- monastery, which waits while it is open
function View:createBook()
  local Widgets = private.Widgets
  local book = CreateFrame("Frame", nil, self.frame)
  book:SetAllPoints()
  book:SetFrameLevel(self.frame:GetFrameLevel() + 3)
  book:EnableMouse(true)
  local shade = book:CreateTexture(nil, "BACKGROUND")
  shade:SetAllPoints()
  shade:SetColorTexture(0.04, 0.02, 0.02, 0.88)

  local page = CreateFrame("Frame", nil, book)
  local tall = TALENT_SIZE * 3 + TIER_GAP * 2
  page:SetSize(TREE_WIDTH * 3 + TREE_GAP * 2, tall + 110)
  page:SetPoint("CENTER")
  book.page = page
  book.title = page:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  book.title:SetPoint("TOP", 0, 0)
  book.left = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  book.left:SetPoint("TOP", book.title, "BOTTOM", 0, -4)

  self.tiles = {}
  for tree = 1, 3 do
    local column = Widgets.Panel(page)
    column:SetSize(TREE_WIDTH, tall + 44)
    column:SetPoint("TOPLEFT", (tree - 1) * (TREE_WIDTH + TREE_GAP), -44)
    column:SetBackdropColor(0.12, 0.06, 0.05, 0.85)
    column.name = column:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    column.name:SetPoint("TOP", 0, -6)
    column.spent = column:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    column.spent:SetPoint("BOTTOM", 0, 5)
    self.tiles[tree] = { column = column }
    for tier = 1, 3 do
      local top = -26 - (tier - 1) * (TALENT_SIZE + TIER_GAP)
      if tier > 1 then
        -- What joins a talent to the one below it
        local join = column:CreateTexture(nil, "BORDER")
        join:SetSize(4, TIER_GAP)
        join:SetPoint("TOP", 0, top + TIER_GAP)
        self.tiles[tree]["join" .. tier] = join
      end
      local tile = createIcon(column, TALENT_SIZE)
      tile:SetPoint("TOP", 0, top)
      tile.rank = tile:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      tile.rank:SetPoint("BOTTOMRIGHT", 6, -5)
      tile.badge = tile:CreateTexture(nil, "OVERLAY")
      tile.badge:SetPoint("CENTER", tile.rank, "CENTER")
      tile.badge:SetSize(26, 14)
      tile.badge:SetColorTexture(0, 0, 0, 0.8)
      tile:SetScript("OnClick", function()
        self:learn(tree, tier)
      end)
      tile:SetScript("OnEnter", function(button)
        self:explain(button, tree, tier)
      end)
      tile:SetScript("OnLeave", GameTooltip_Hide)
      self.tiles[tree][tier] = tile
    end
  end

  local done = Widgets.Button(page, L["warcraftstein_talents_done"], 100)
  done:SetPoint("BOTTOM", 0, 0)
  done:SetScript("OnClick", function()
    self:openBook(false)
  end)
  book:Hide()
  self.book = book
end

--- Opens the talents, or closes them
--- @param open boolean
function View:openBook(open)
  if open and not self.run then
    return
  end
  self.book:SetShown(open)
  self.down = {}
  if open then
    self:fillBook()
  end
end

--- How many points have gone into a tree
--- @param run WarcraftsteinRun
--- @param tree number
--- @return number
local function spentIn(run, tree)
  local spent = 0
  for _, known in ipairs(TALENTS[run.class][tree].talents) do
    spent = spent + (run.learned[known.id] or 0)
  end
  return spent
end

--- Whether a talent can be learnt now, and if not why
--- @param run WarcraftsteinRun
--- @param tree number
--- @param tier number
--- @return boolean, string? why
local function learnable(run, tree, tier)
  local known = TALENTS[run.class][tree].talents[tier]
  if (run.learned[known.id] or 0) >= known.ranks then
    return false, nil
  elseif spentIn(run, tree) < TIER_NEEDS[tier] then
    return false, L["warcraftstein_talent_needs"]:format(TIER_NEEDS[tier], L["warcraftstein_tree_" .. TALENTS[run.class][tree].id])
  end
  return run.points > 0, nil
end

--- Shows the trees of the player's class, and how far they are down each
function View:fillBook()
  local run, book = self.run, self.book
  local color = run.spec.color
  book.title:SetText(L["warcraftstein_talents_of"]:format(className(run.class)))
  book.title:SetTextColor(color[1], color[2], color[3])
  book.left:SetText(L[run.points == 1 and "warcraftstein_talents_point" or "warcraftstein_talents_points"]:format(run.points))
  for tree, trees in ipairs(TALENTS[run.class]) do
    local tiles, spent = self.tiles[tree], spentIn(run, tree)
    tiles.column.name:SetText(L["warcraftstein_tree_" .. trees.id])
    tiles.column.spent:SetText(L["warcraftstein_talents_spent"]:format(spent))
    tiles.column:SetBackdropBorderColor(color[1], color[2], color[3], spent > 0 and 0.8 or 0.25)
    for tier, known in ipairs(trees.talents) do
      local tile, rank = tiles[tier], run.learned[known.id] or 0
      local can = learnable(run, tree, tier)
      local open = spent >= TIER_NEEDS[tier]
      tile.icon:SetTexture(ICONS .. known.icon)
      tile.icon:SetDesaturated(not open)
      tile.icon:SetVertexColor(open and 1 or 0.45, open and 1 or 0.45, open and 1 or 0.45)
      tile.rank:SetText(rank .. "/" .. known.ranks)
      -- Gold once it is all learnt, green while there is more to learn, grey while out of reach
      local edge = (rank >= known.ranks and private.Widgets.GOLD) or (can and private.Widgets.GREEN) or { 0.4, 0.4, 0.4 }
      tile:SetBackdropBorderColor(edge[1], edge[2], edge[3], 1)
      tile.rank:SetTextColor(edge[1], edge[2], edge[3])
      tile.can = can
      local join = tiles["join" .. tier]
      if join then
        local lit = open and private.Widgets.GOLD or { 0.3, 0.3, 0.3 }
        join:SetColorTexture(lit[1], lit[2], lit[3], 0.9)
      end
    end
  end
end

--- Says what a talent does, and what the next rank of it would
--- @param owner Frame
--- @param tree number
--- @param tier number
function View:explain(owner, tree, tier)
  local run = self.run
  if not run then
    return
  end
  local known = TALENTS[run.class][tree].talents[tier]
  local rank = run.learned[known.id] or 0
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:SetText(L["warcraftstein_talent_" .. known.id])
  GameTooltip:AddLine(L["warcraftstein_talent_rank"]:format(rank, known.ranks), 1, 1, 1)
  GameTooltip:AddLine(talentText(known, math.max(1, rank)), 1, 0.82, 0, true)
  if rank > 0 and rank < known.ranks then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L["warcraftstein_talent_next"], 1, 1, 1)
    GameTooltip:AddLine(talentText(known, rank + 1), 1, 0.82, 0, true)
  end
  local _, why = learnable(run, tree, tier)
  if why then
    GameTooltip:AddLine(why, 1, 0.3, 0.25, true)
  end
  GameTooltip:Show()
end

--- Learns a rank of a talent, if it can be learnt
--- @param tree number
--- @param tier number
--- @return boolean learnt
function View:learn(tree, tier)
  local run = self.run
  if not run or not self.view.canMove or not learnable(run, tree, tier) then
    return false
  end
  local known = TALENTS[run.class][tree].talents[tier]
  run.learned[known.id] = (run.learned[known.id] or 0) + 1
  run.points = run.points - 1
  local before = run.spec.health
  run.spec = build(run.class, run.learned)
  -- More health to be had is more health
  run.health = run.health + math.max(0, run.spec.health - before)
  if run.buff then
    run.buff = run.spec.ability
  end
  private.Widgets.PlaySound("IG_MAINMENU_OPTION_CHECKBOX_ON")
  self:fillBook()
  self:gauge()
  return true
end

--- Puts a strip of what is seen where its column is
--- @param strip Texture
--- @param index number
--- @param slice number How wide a column is
--- @param frame Frame
local function place(strip, index, slice, frame)
  -- A little more than its share, so nothing shows through between two of them
  strip:SetWidth(slice + 0.5)
  strip:ClearAllPoints()
  -- A wall is as far above the middle as below it: only how tall a column is ever changes
  strip:SetPoint("CENTER", frame, "LEFT", (index - 0.5) * slice, 0)
end

--- Lays everything out for the room there is
function View:arrange()
  local width, height, stage = self.width, self.height, self.stage
  local roomWidth, roomHeight = width - MARGIN * 2, height - MARGIN * 3 - STAT_HEIGHT
  local seenWidth = math.max(FEWEST, math.floor(math.min(roomWidth, roomHeight * ASPECT)))
  local seenHeight = math.floor(seenWidth / ASPECT)
  local left = math.floor((width - seenWidth) / 2)
  self.seenWidth, self.seenHeight, self.left = seenWidth, seenHeight, left

  self.border:SetSize(seenWidth + 2, seenHeight + 2)
  self.border:ClearAllPoints()
  self.border:SetPoint("TOPLEFT", stage, "TOPLEFT", left - 1, -(MARGIN - 1))
  self.frame:SetSize(seenWidth, seenHeight)
  self.frame:ClearAllPoints()
  self.frame:SetPoint("TOPLEFT", stage, "TOPLEFT", left, -MARGIN)

  -- Rows of the floor and ceiling, from the middle out
  local rows = math.ceil(seenHeight / 2 / ROW)
  for index = 1, math.max(rows, #self.floors) do
    for _, half in ipairs({ self.floors, self.ceilings }) do
      local band = half[index]
      if not band then
        band = self.frame:CreateTexture(nil, "BACKGROUND")
        band:SetTexture(half == self.floors and FLOOR_PICTURE or CEILING_PICTURE, "REPEAT", "REPEAT")
        half[index] = band
      end
      band:SetShown(index <= rows)
      band:SetSize(seenWidth, ROW + 0.5)
      band:ClearAllPoints()
      local below = half == self.floors and (index - 1) * ROW or -index * ROW
      band:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, -(seenHeight / 2 + below))
    end
  end
  self.rows = rows

  local count = math.max(FEWEST, math.min(MOST, math.floor(seenWidth / SLICE)))
  local slice = seenWidth / count
  self.count = count
  for index = 1, math.max(count, #self.columns) do
    local column = self.columns[index]
    if not column then
      column = self.frame:CreateTexture(nil, "ARTWORK")
      self.columns[index] = column
    end
    column:SetShown(index <= count)
    if index <= count then
      place(column, index, slice, self.frame)
    end
  end
  self.slice = slice
  -- Whatever is to be seen of anything is shown again the next time the monastery is drawn
  for _, strip in ipairs(self.lit) do
    strip:Hide()
    strip.lit = false
  end
  self.lit = {}
  for _, layer in pairs(self.strips) do
    for index, strip in pairs(layer) do
      if index <= count then
        place(strip, index, slice, self.frame)
      end
    end
  end
  self.weapon:SetSize(seenHeight * 0.7, seenHeight * 0.7)
  self.picker.row:SetScale(math.min(1, seenWidth / (self.picker.row:GetWidth() + MARGIN * 4)))
  self.book.page:SetScale(math.min(1, seenWidth / (self.book.page:GetWidth() + MARGIN * 4), seenHeight / (self.book.page:GetHeight() + MARGIN * 4)))
  self.bossBar.wide = math.floor(seenWidth * 0.45)
  self.bossBar:SetSize(self.bossBar.wide, 16)

  -- Underneath: who the player is and how they are, what they can do, the time, and the keys
  local below, x = MARGIN * 2 + seenHeight, left
  local half = (STAT_HEIGHT - 2) / 2
  self.portrait:ClearAllPoints()
  self.portrait:SetPoint("TOPLEFT", stage, "TOPLEFT", x, -below)
  x = x + STAT_HEIGHT + MARGIN
  for nth, bar in ipairs({ self.health, self.power }) do
    bar.wide = BAR_WIDTH
    bar:SetSize(BAR_WIDTH, half)
    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", stage, "TOPLEFT", x, -below - (nth - 1) * (half + 2))
  end
  x = x + BAR_WIDTH + MARGIN
  for _, widget in ipairs({ self.ability, self.talents, self.time, self.best }) do
    widget:ClearAllPoints()
    widget:SetPoint("TOPLEFT", stage, "TOPLEFT", x, -below)
    x = x + widget:GetWidth() + MARGIN
  end
  self.hint:SetWidth(math.max(1, left + seenWidth - x))
  self.hint:ClearAllPoints()
  self.hint:SetPoint("RIGHT", stage, "TOPLEFT", left + seenWidth, -(below + STAT_HEIGHT / 2))
end

--- How much light there is at a point that far from the player: the dark, and the fire of every
--- light near enough
--- @param x number
--- @param y number
--- @param distance number
--- @return number red, number green, number blue
function View:light(x, y, distance)
  local dark = math.max(DARKEST, 1 / (1 + distance * FOG))
  local red, green, blue = dark * DARK_LIGHT[1], dark * DARK_LIGHT[2], dark * DARK_LIGHT[3]
  for _, light in ipairs(self.near) do
    local away = (light.x - x) ^ 2 + (light.y - y) ^ 2
    if away < LIGHT_RANGE * LIGHT_RANGE then
      local amount, color = light.power / (1 + away * LIGHT_FADE), light.color or FIRE_LIGHT
      red, green, blue = red + amount * color[1], green + amount * color[2], blue + amount * color[3]
    end
  end
  return math.min(1, red), math.min(1, green), math.min(1, blue)
end

--- Draws what the player sees from where they are
function View:render()
  local view, run, pose = self.view, self.run, self.pose
  if not view or not run or self.count == 0 then
    return
  end
  --- @type WarcraftsteinState
  local state = view.state
  local aheadX, aheadY = math.cos(pose.facing), math.sin(pose.facing)
  -- To the right of the player, as far as the edge of what is seen is from the middle of it
  local asideX, asideY = -aheadY * REACH, aheadX * REACH
  local seenHeight, count = self.seenHeight, self.count
  -- How tall a wall one step away is: as tall as it is wide, like every square of the monastery
  local tall = self.seenWidth / (2 * REACH)

  -- The lights that can light anything that can be seen
  local near = self.near
  for index = #near, 1, -1 do
    near[index] = nil
  end
  for _, light in ipairs(run.lights) do
    if (light.x - pose.x) ^ 2 + (light.y - pose.y) ^ 2 < (FARTHEST / 3) ^ 2 then
      near[#near + 1] = light
    end
  end

  for index = 1, count do
    local column = self.columns[index]
    local off = 2 * (index - 0.5) / count - 1
    local towardsX, towardsY = aheadX + asideX * off, aheadY + asideY * off
    local distance, kind, across, flank = cast(state, pose.x, pose.y, towardsX, towardsY)
    self.depths[index] = distance
    if kind ~= column.kind then
      column.kind = kind
      column:SetTexture(PICTURES[kind] or PICTURES[NAVE])
    end

    -- A wall too tall to be seen whole shows the part of it that is level with the eye
    local height, top, bottom = tall / math.max(distance, 0.0001), 0, 1
    if height > seenHeight then
      local part = seenHeight / height
      height, top, bottom = seenHeight, 0.5 - part / 2, 0.5 + part / 2
    end
    column:SetHeight(height)
    -- One pixel of the picture across, from well inside it so that its neighbours don't run in
    local strip = math.floor(across * WALL_TEXELS)
    column:SetTexCoord((strip + 0.2) / WALL_TEXELS, (strip + 0.8) / WALL_TEXELS, top, bottom)
    -- Lit from just in front of the wall, where whatever lights it is
    local red, green, blue = self:light(pose.x + towardsX * distance * 0.98, pose.y + towardsY * distance * 0.98, distance)
    -- The portal and the window of the Light shine of themselves
    local shade = (kind == PORTAL and 1.6 or kind == SHRINE and 1.35 or 1) * (flank and FLANK or 1)
    column:SetVertexColor(math.min(1, red * shade), math.min(1, green * shade), math.min(1, blue * shade))
  end

  -- Floor and ceiling a row at a time, each row the stretch of the map from where the left edge
  -- of what is seen meets it to where the right one does, nearer and further
  for index = 1, self.rows do
    local nearer, further = index * ROW, math.max(0.5, (index - 1) * ROW)
    local close, far = tall / (2 * nearer), math.min(FARTHEST, tall / (2 * further))
    local leftX, leftY, rightX, rightY = aheadX - asideX, aheadY - asideY, aheadX + asideX, aheadY + asideY
    local farLeftX, farLeftY = pose.x + leftX * far, pose.y + leftY * far
    local farRightX, farRightY = pose.x + rightX * far, pose.y + rightY * far
    local closeLeftX, closeLeftY = pose.x + leftX * close, pose.y + leftY * close
    local closeRightX, closeRightY = pose.x + rightX * close, pose.y + rightY * close
    local dark = math.max(DARKEST, 1 / (1 + (close + far) / 2 * FOG))
    local floor, ceiling = self.floors[index], self.ceilings[index]
    floor:SetTexCoord(farLeftX, farLeftY, closeLeftX, closeLeftY, farRightX, farRightY, closeRightX, closeRightY)
    ceiling:SetTexCoord(closeLeftX, closeLeftY, farLeftX, farLeftY, closeRightX, closeRightY, farRightX, farRightY)
    floor:SetVertexColor(dark * DARK_LIGHT[1], dark * DARK_LIGHT[2], dark * DARK_LIGHT[3])
    ceiling:SetVertexColor(dark * DARK_LIGHT[1] * 0.8, dark * DARK_LIGHT[2] * 0.8, dark * DARK_LIGHT[3] * 0.8)
  end

  self:things(aheadX, aheadY, tall)

  -- What the player holds, swaying as they walk
  local buff = run.buff
  local held = (buff and buff.holds or run.spec.holds) + (run.swung > 0 and 1 or 0)
  self.weapon:SetTexCoord((held * TEXELS + 0.5) / WEAPON_SHEET, ((held + 1) * TEXELS - 0.5) / WEAPON_SHEET, 0, 1)
  self.weapon:SetAlpha(buff and buff.hidden and 0.45 or 1)
  local sway = run.walked * math.pi * 1.4
  self.weapon:ClearAllPoints()
  local thrust = run.swung / SWUNG * seenHeight * THRUST
  self.weapon:SetPoint("BOTTOM", self.frame, "BOTTOM", self.seenWidth * 0.14 + math.sin(sway) * seenHeight * SWAY, -math.abs(math.cos(sway)) * seenHeight * SWAY + thrust)
  local veil = buff and buff.veil or (run.safe and SANCTUARY_VEIL) or nil
  self.veil:SetShown(veil ~= nil)
  if veil then
    self.veil:SetColorTexture(veil[1], veil[2], veil[3], veil[4])
  end

  -- East is to the right of the map and south down it
  local quarter = math.floor(pose.facing / (math.pi / 2) + 0.5) % 4
  self.compass:SetText(L["warcraftstein_compass_" .. quarter])
end

--- @param one WarcraftsteinThing
--- @param other WarcraftsteinThing
--- @return boolean
local function further(one, other)
  return one.depth > other.depth
end

--- Which picture of a foe to show, and in what colour
--- @param mob WarcraftsteinMob
--- @return number picture, number[]? tint
local function looks(mob)
  local first = mob.foe.picture
  if mob.dead then
    return first + FALLEN, nil
  end
  local tint = (mob.hurt > 0 and HURT_TINT) or (mob.frozen > 0 and FROZEN_TINT) or (mob.slowed > 0 and SLOWED_TINT) or (mob.angry and ANGRY_TINT) or nil
  if mob.struck > 0 or mob.spinning > 0 then
    return first + STRIKING, tint
  end
  return first + (mob.awake and math.floor(mob.walked / STRIDE) % 2 or STANDING), tint
end

--- Draws everything that stands in the monastery over the walls, wherever no wall is in front of it
--- @param aheadX number The way the player looks
--- @param aheadY number
--- @param tall number How tall a wall one step away is
function View:things(aheadX, aheadY, tall)
  local run, pose, seen, depths, lit = self.run, self.pose, self.seen, self.depths, self.lit
  local seenWidth, seenHeight, count, slice = self.seenWidth, self.seenHeight, self.count, self.slice
  local stamp = self.stamp + 1
  self.stamp = stamp

  -- The ones in front of the player and not off to either side of what is seen: a picture is
  -- as wide as a square of the monastery, half of that to either side of where the thing stands
  local visible = 0
  --- @param thing WarcraftsteinThing
  --- @param picture number
  --- @param tint number[]?
  --- @param glows boolean?
  --- @param alpha number?
  local function sight(thing, picture, tint, glows, alpha)
    local byX, byY = thing.x - pose.x, thing.y - pose.y
    local depth = byX * aheadX + byY * aheadY
    if depth > NEAREST then
      local off = (byY * aheadX - byX * aheadY) / (depth * REACH)
      if math.abs(off) < 1 + 0.5 / (depth * REACH) then
        visible = visible + 1
        seen[visible], thing.depth, thing.off = thing, depth, off
        thing.picture, thing.tint, thing.glows, thing.alpha = picture, tint, glows, alpha
      end
    end
  end
  local moment = math.floor(run.ripple / RIPPLE)
  for _, item in ipairs(run.decor) do
    sight(item, item.first + (item.frames and moment % item.frames or 0), nil, item.light ~= nil)
  end
  for _, potion in ipairs(run.loot) do
    sight(potion, POTIONS[potion.kind])
  end
  for _, mob in ipairs(run.mobs) do
    local picture, tint = looks(mob)
    sight(mob, picture, tint, nil, mob.foe.ghostly and 0.7 or nil)
  end
  if run.totem then
    sight(run.totem, TOTEM)
  end
  for _, list in ipairs({ run.bolts, run.shots }) do
    for _, bolt in ipairs(list) do
      sight(bolt, BOLT, bolt.attack and bolt.attack.tint or bolt.tint, true)
    end
  end
  for index = #seen, visible + 1, -1 do
    seen[index] = nil
  end
  table.sort(seen, further)

  for order, thing in ipairs(seen) do
    local layer = math.max(1, LAYERS - (visible - order))
    local strips = self.strips[layer]
    if not strips then
      strips = {}
      self.strips[layer] = strips
    end
    -- As tall as a wall that far away, and as wide: cut off the same way if that is too tall
    local size = tall / thing.depth
    local left = (thing.off + 1) / 2 * seenWidth - size / 2
    local height, top, bottom = size, 0, 1
    if height > seenHeight then
      local part = seenHeight / height
      height, top, bottom = seenHeight, 0.5 - part / 2, 0.5 + part / 2
    end
    local red, green, blue = 1, 1, 1
    if not thing.glows then
      red, green, blue = self:light(thing.x, thing.y, thing.depth)
    end
    local tint = thing.tint
    if tint then
      red, green, blue = red * tint[1], green * tint[2], blue * tint[3]
    end
    local row, column = math.floor(thing.picture / SHEET), thing.picture % SHEET
    top, bottom = (row + top) / SHEET, (row + bottom) / SHEET

    for index = math.max(1, math.floor(left / slice) + 1), math.min(count, math.ceil((left + size) / slice)) do
      local across = ((index - 0.5) * slice - left) / size
      if across >= 0 and across < 1 and depths[index] > thing.depth then
        local strip = strips[index]
        if not strip then
          strip = self.frame:CreateTexture(nil, "ARTWORK", nil, layer)
          strip:SetTexture(SPRITES)
          place(strip, index, slice, self.frame)
          strip:Hide()
          strips[index] = strip
        end
        if not strip.lit then
          strip.lit = true
          strip:Show()
          lit[#lit + 1] = strip
        end
        strip.stamp, strip.shows = stamp, thing
        strip:SetHeight(height)
        local texel = column * TEXELS + math.floor(across * TEXELS)
        strip:SetTexCoord((texel + 0.2) / (TEXELS * SHEET), (texel + 0.8) / (TEXELS * SHEET), top, bottom)
        strip:SetVertexColor(red, green, blue, thing.alpha or 1)
      end
    end
  end

  -- Away with whatever showed something the last time and doesn't now
  local kept = 0
  for index = 1, #lit do
    local strip = lit[index]
    lit[index] = nil
    if strip.stamp == stamp then
      kept = kept + 1
      lit[kept] = strip
    else
      strip.lit = false
      strip:Hide()
    end
  end
end

--- What stands in the way of someone at a point, as wide as the player is
--- @param state WarcraftsteinState
--- @param x number
--- @param y number
--- @return number? kind Nothing if there is room
local function blocked(state, x, y)
  for _, corner in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
    local kind = kindAt(state, x + corner[1] * GIRTH, y + corner[2] * GIRTH)
    if kind ~= OPEN then
      return kind
    end
  end
  return nil
end

--- Whether going somewhere would be walking into a foe that is up or into the player, or for
--- a foe into something that stands about. The player goes round that instead, see `around`
--- @param run WarcraftsteinRun
--- @param who WarcraftsteinMob? The foe that is going, nil for the player
--- @param x number Where it is
--- @param y number
--- @param toX number Where to
--- @param toY number
--- @return boolean
local function crowded(run, who, x, y, toX, toY)
  local function near(otherX, otherY, apart)
    local now = (toX - otherX) ^ 2 + (toY - otherY) ^ 2
    -- Getting away from each other is always allowed, or two that met would never part
    return now < apart * apart and now < (x - otherX) ^ 2 + (y - otherY) ^ 2
  end
  for _, mob in ipairs(run.mobs) do
    if mob ~= who and not mob.dead and near(mob.x, mob.y, APART) then
      return true
    end
  end
  for _, item in ipairs(who and run.decor or {}) do
    if item.girth and near(item.x, item.y, item.girth + GIRTH) then
      return true
    end
  end
  return who ~= nil and near(run.pose.x, run.pose.y, APART)
end

--- How far to step aside to get round a corner that alone is in the way of a step across or
--- down the map: one that only one shoulder would catch on, and not by much
--- @param state WarcraftsteinState
--- @param x number
--- @param y number
--- @param byX number The step: one of the two is nothing
--- @param byY number
--- @return number asideX, number asideY Nothing if it is more than a corner
local function rounding(state, x, y, byX, byY)
  local far = math.abs(byX) + math.abs(byY)
  -- The same either way round: `along` is the way of the step, `across` what lies beside it
  local along, across = byX ~= 0 and x or y, byX ~= 0 and y or x
  local front = along + byX + byY + ((byX + byY) > 0 and GIRTH or -GIRTH)
  local function at(side)
    if byX ~= 0 then
      return kindAt(state, front, side)
    end
    return kindAt(state, side, front)
  end
  local low, high = at(across - GIRTH) ~= OPEN, at(across + GIRTH) ~= OPEN
  if low == high then
    return 0, 0
  end
  -- How far the shoulder that catches is into the square the corner belongs to
  local into = low and (math.floor(across - GIRTH) + 1 - (across - GIRTH)) or (across + GIRTH - math.floor(across + GIRTH))
  if into > CORNER then
    return 0, 0
  end
  local aside = (low and 1 or -1) * math.min(into + 0.001, far)
  if byX ~= 0 then
    return 0, aside
  end
  return aside, 0
end

--- A step the player takes, bent round whatever stands about that it would walk into: what of
--- it goes towards the middle of the thing is taken out, which leaves going along its edge. A
--- step that was all towards it goes round it to one side, the right unless it leant left
--- @param run WarcraftsteinRun
--- @param byX number
--- @param byY number
--- @return number byX, number byY
local function around(run, byX, byY)
  local pose = run.pose
  for _, item in ipairs(run.decor) do
    local reach = item.girth and item.girth + GIRTH
    if reach and (pose.x + byX - item.x) ^ 2 + (pose.y + byY - item.y) ^ 2 < reach * reach then
      local outX, outY = pose.x - item.x, pose.y - item.y
      local away = math.sqrt(outX * outX + outY * outY)
      if away < 0.0001 then
        outX, outY, away = 1, 0, 1
      end
      outX, outY = outX / away, outY / away
      local into = byX * outX + byY * outY
      if into < 0 then
        local far = math.sqrt(byX * byX + byY * byY)
        byX, byY = byX - outX * into, byY - outY * into
        local along = byX * -outY + byY * outX
        if math.sqrt(byX * byX + byY * byY) < far * 0.3 then
          local side = along < 0 and -1 or 1
          byX, byY = byX - outY * side * far * 0.7, byY + outX * side * far * 0.7
        end
      end
    end
  end
  return byX, byY
end

--- Whether a point is in the sanctuary
--- @param run WarcraftsteinRun
--- @param x number
--- @param y number
--- @return boolean
local function sheltered(run, x, y)
  local room = run.sanctuary
  return x >= room.x and x < room.x + room.w and y >= room.y and y < room.y + room.h
end

--- Says something across the top of what is seen, for a while
--- @param words string
--- @param color number[]?
function View:say(words, color)
  local said = self.said
  said:SetText(words)
  color = color or { 1, 0.25, 0.2 }
  said:SetTextColor(color[1], color[2], color[3])
  said:Show()
  self.run.said = SAID
end

--- Moves the player by what the keys that are held say, for the time that passed
--- @param elapsed number
--- @return boolean moved
--- @return boolean out They walked into the portal
function View:walk(elapsed)
  local run, pose = self.run, self.pose
  local ahead, aside, turn = 0, 0, 0
  for key in pairs(self.down) do
    -- A key that was let go of somewhere else is never heard of again
    if IsKeyDown and not IsKeyDown(key) then
      self.down[key] = nil
    elseif KEYS[key] then
      ahead, aside, turn = ahead + KEYS[key][1], aside + KEYS[key][2], turn + KEYS[key][3]
    end
  end
  -- With the right button held the mouse does the turning, and the keys that turn step aside
  local swing = 0
  if IsMouseButtonDown and IsMouseButtonDown("RightButton") then
    local across = GetCursorPosition() / self.frame:GetEffectiveScale()
    swing = self.dragged and (across - self.dragged) * MOUSE_TURN or 0
    self.dragged = across
    aside, turn = aside + turn, 0
  else
    self.dragged = nil
  end
  if turn == 0 then
    self.spin, self.spun = 0, 0
  end
  if ahead == 0 and aside == 0 and turn == 0 and swing == 0 then
    return false, false
  end

  if turn ~= 0 then
    -- Gently to begin with, and from the beginning again the other way
    local spin = self.spun == turn and self.spin or TURN_START
    self.spin, self.spun = math.min(1, spin + elapsed / TURN_RAMP), turn
    swing = swing + turn * TURN * self.spin * elapsed
  end
  pose.facing = (pose.facing + swing) % (math.pi * 2)
  local aheadX, aheadY = math.cos(pose.facing), math.sin(pose.facing)
  local far = WALK * (run.spec.speed or 1) * (run.buff and run.buff.speed or 1) * elapsed
  -- Nobody backs away from the Crusade as quickly as it comes
  local byX = (aheadX * ahead * (ahead < 0 and BACKWARDS or 1) - aheadY * aside) * far
  local byY = (aheadY * ahead * (ahead < 0 and BACKWARDS or 1) + aheadX * aside) * far
  byX, byY = around(run, byX, byY)

  --- @type WarcraftsteinState
  local state = self.view.state
  local x, y = pose.x, pose.y
  --- Goes to a point if there is room there
  --- @return boolean
  local function go(toX, toY)
    if blocked(state, toX, toY) or crowded(run, nil, pose.x, pose.y, toX, toY) then
      return false
    end
    pose.x, pose.y = toX, toY
    return true
  end
  -- Across and down each on their own, so that walking into a wall at an angle slides along
  -- it. And round a corner that is only just in the way, which is not a wall walked into
  local hitX = byX ~= 0 and blocked(state, pose.x + byX, pose.y) or nil
  if hitX and hitX ~= PORTAL then
    local roundX, roundY = rounding(state, pose.x, pose.y, byX, 0)
    if roundY ~= 0 and go(pose.x + roundX, pose.y + roundY) then
      hitX = nil
    end
  elseif byX ~= 0 then
    go(pose.x + byX, pose.y)
  end
  local hitY = byY ~= 0 and blocked(state, pose.x, pose.y + byY) or nil
  if hitY and hitY ~= PORTAL then
    local roundX, roundY = rounding(state, pose.x, pose.y, 0, byY)
    if roundX ~= 0 and go(pose.x + roundX, pose.y + roundY) then
      hitY = nil
    end
  elseif byY ~= 0 then
    go(pose.x, pose.y + byY)
  end

  -- Walking ahead into a wall and along it: turned to look the way that is being gone, unless
  -- the player is doing the turning or stepping aside on purpose
  if (hitX == nil) ~= (hitY == nil) and ahead > 0 and aside == 0 and swing == 0 and (pose.x ~= x or pose.y ~= y) then
    local off = (math.atan2(pose.y - y, pose.x - x) - pose.facing + math.pi) % (math.pi * 2) - math.pi
    if math.abs(off) <= STEER_FROM then
      pose.facing = (pose.facing + math.max(-STEER * elapsed, math.min(STEER * elapsed, off))) % (math.pi * 2)
    end
  end
  run.walked = run.walked + math.sqrt((pose.x - x) ^ 2 + (pose.y - y) ^ 2)

  -- The portal is shut while Herod stands
  local out = hitX == PORTAL or hitY == PORTAL
  if out and run.boss then
    if run.said <= 0 then
      self:say(L["warcraftstein_sealed"], private.Widgets.GOLD)
    end
    out = false
  end
  return true, out
end

--- How far the walk to the player is from every square of the monastery, which is what a foe
--- that can't see them goes by: from where it is to whichever square next to it is nearer.
--- Worked out again only when the player is on another square than the last time
--- @return table<number, number> trail By square, counted from 0 where the player is
function View:trail()
  local run, pose = self.run, self.pose
  --- @type WarcraftsteinState
  local state = self.view.state
  local side, cells = state.side, state.cells
  local start = math.floor(pose.y) * side + math.floor(pose.x) + 1
  if run.trailTo ~= start then
    local trail, reached, index = { [start] = 0 }, { start }, 1
    while reached[index] do
      local square = reached[index]
      for _, next in ipairs({ square - 1, square + 1, square - side, square + side }) do
        if cells[next] == OPEN and not trail[next] then
          trail[next] = trail[square] + 1
          reached[#reached + 1] = next
        end
      end
      index = index + 1
    end
    run.trail, run.trailTo = trail, start
  end
  return run.trail
end

--- A foe saw the player, or was hit: it wakes, it tells the ones around it, and someone of the
--- Crusade might well say something about it
--- @param mob WarcraftsteinMob
function View:rouse(mob)
  local run, pose = self.run, self.pose
  mob.awake, mob.lost, mob.toX, mob.toY = true, 0, pose.x, pose.y
  for _, other in ipairs(run.mobs) do
    local near = (other.x - mob.x) ^ 2 + (other.y - mob.y) ^ 2 <= CALLS * CALLS
    if not other.awake and not other.dead and near and sees(self.view.state, mob.x, mob.y, other.x, other.y) then
      other.awake, other.lost, other.toX, other.toY = true, 0, pose.x, pose.y
    end
  end
  if mob.foe.boss then
    self:say(L["warcraftstein_herod_aggro"])
  elseif mob.foe.yells and run.quiet <= 0 then
    run.quiet = QUIET
    self:say(L["warcraftstein_yell_" .. run.dice:Roll(YELLS)])
  end
end

--- Writes how much a blow took off over whoever took it, if they can be seen
--- @param mob WarcraftsteinMob
--- @param amount number
--- @param hard boolean It was twice as hard as it might have been
function View:tell(mob, amount, hard)
  for _, seen in ipairs(self.seen) do
    if seen == mob then
      local x = self.left + (mob.off + 1) / 2 * self.seenWidth
      local y = MARGIN + self.seenHeight / 2 - math.min(self.seenHeight / 2, self.seenWidth / (2 * REACH) / mob.depth * 0.3)
      self.effects:Float(tostring(math.floor(amount + 0.5)), x, y, { size = hard and 22 or 15, color = hard and { 1, 0.55, 0.1 } or { 1, 1, 1 } })
      return
    end
  end
end

--- The player gets experience, and a level and a point for every so much of it
--- @param xp number
function View:earn(xp)
  local run = self.run
  run.xp = run.xp + xp
  while run.xp >= levelXp(run.level) do
    run.xp, run.level, run.points = run.xp - levelXp(run.level), run.level + 1, run.points + 1
    self.effects:Float(L["warcraftstein_level"]:format(run.level), self.left + self.seenWidth / 2, MARGIN + self.seenHeight * 0.35, { size = 28 })
    private.Widgets.PlaySound(SOUNDKIT[LEVEL_SOUND] and LEVEL_SOUND or FOUND_SOUND_ELSE)
    self:say(L["warcraftstein_level_point"], private.Widgets.GOLD)
  end
end

--- Takes health off a foe
--- @param mob WarcraftsteinMob
--- @param amount number
--- @param attack WarcraftsteinAttack? What with, if it was the player's own
--- @param also boolean? It was more than the blow itself: something it splashed or jumped on to, or an ability. No chance of a harder hit, nothing more coming of it
function View:wound(mob, amount, attack, also)
  local run, spec = self.run, self.run.spec
  if mob.dead then
    return
  end
  local hard = false
  if attack and not also and (spec.crit or 0) > 0 and run.dice:Roll(1000) <= spec.crit * 1000 then
    amount, hard = amount * 2, true
  end
  amount = amount * (mob.foe.armor or 1)
  mob.health, mob.hurt = mob.health - amount, HURT
  if attack then
    self:tell(mob, amount, hard)
    if attack.drains then
      run.health = math.min(spec.health, run.health + amount * attack.drains)
    end
    if spec.gains then
      run.power = math.min(POWER, run.power + spec.gains.dealt)
    end
    if not also then
      mob.slowed = math.max(mob.slowed, attack.slows or 0)
      if (attack.stuns or 0) > 0 and run.dice:Roll(1000) <= attack.stuns * 1000 then
        mob.frozen = math.max(mob.frozen, STUN)
      end
      -- And half of it to everything near whoever took it
      if attack.splash then
        for _, other in ipairs(run.mobs) do
          if other ~= mob and (other.x - mob.x) ^ 2 + (other.y - mob.y) ^ 2 <= attack.splash ^ 2 then
            self:wound(other, amount / 2, attack, true)
          end
        end
      end
    end
  end
  if not mob.awake then
    self:rouse(mob)
  end
  mob.toX, mob.toY = self.pose.x, self.pose.y
  if mob.foe.enrage and not mob.angry and mob.health <= mob.foe.health * mob.foe.enrage then
    mob.angry = true
    self:say(L["warcraftstein_herod_enrage"])
  end
  if mob.health <= 0 then
    mob.dead, mob.awake = true, false
    run.health = math.min(spec.health, run.health + (spec.leech or 0))
    run.ready = math.max(0, run.ready - (spec.refund or 0))
    if mob == run.boss then
      run.boss = nil
      self:say(L["warcraftstein_herod_dies"], private.Widgets.GOLD)
    end
    self:earn(mob.foe.xp)
  end
end

--- The player is hit
--- @param amount number
--- @param from WarcraftsteinMob? Who by, if it was a blow
function View:hurt(amount, from)
  local run, spec = self.run, self.run.spec
  if run.safe or (run.buff and run.buff.immune) then
    return
  end
  if (spec.dodge or 0) > 0 and run.dice:Roll(1000) <= spec.dodge * 1000 then
    self.effects:Float(L["warcraftstein_dodge"], self.left + self.seenWidth / 2, MARGIN + self.seenHeight * 0.6, { size = 16, color = { 0.7, 0.9, 1 } })
    return
  end
  run.health = math.max(0, run.health - amount * (spec.armor or 1))
  if spec.gains then
    run.power = math.min(POWER, run.power + spec.gains.taken)
  end
  if from then
    if spec.thorns then
      self:wound(from, spec.thorns)
    end
    if from.foe.drains then
      from.health = math.min(from.foe.health, from.health + amount * from.foe.drains)
    end
  end
end

--- The foes in a line ahead of the player, nearest first, as far as nothing is in the way
--- @param reach number
--- @param wide number How far to either side of straight ahead one may stand
--- @return WarcraftsteinMob[]
function View:ahead(reach, wide)
  local pose = self.pose
  local aheadX, aheadY = math.cos(pose.facing), math.sin(pose.facing)
  local found = {}
  for _, mob in ipairs(self.run.mobs) do
    local byX, byY = mob.x - pose.x, mob.y - pose.y
    local depth = byX * aheadX + byY * aheadY
    if not mob.dead and depth > 0 and depth <= reach and math.abs(byY * aheadX - byX * aheadY) <= wide then
      if sees(self.view.state, pose.x, pose.y, mob.x, mob.y) then
        mob.depth = depth
        found[#found + 1] = mob
      end
    end
  end
  table.sort(found, function(one, other)
    return one.depth < other.depth
  end)
  return found
end

--- The player strikes with whatever they strike with, if they have the power for it
--- @return boolean struck
function View:strike()
  local run, pose = self.run, self.pose
  local buff = run.buff
  local attack = buff and buff.attack or run.spec.attack
  if run.power < (attack.cost or 0) then
    return false
  end
  run.power, run.cooldown, run.swung = run.power - (attack.cost or 0), attack.every, SWUNG
  local sounds = (buff and buff.attack) and MELEE_SOUNDS or STRIKE_SOUNDS[run.class] or MELEE_SOUNDS
  self:sound(sounds[1])
  if attack.kind == "bolt" then
    self:glow(attack.tint or STRIKE_COLOR)
  end
  -- Whoever strikes is seen
  local unseen = buff ~= nil and buff.hidden == true
  if buff and buff.breaks then
    run.buff, run.buffLeft = nil, 0
  end

  if attack.kind == "bolt" then
    local aheadX, aheadY = math.cos(pose.facing), math.sin(pose.facing)
    run.bolts[#run.bolts + 1] = { x = pose.x, y = pose.y, byX = aheadX, byY = aheadY, speed = BOLT_SPEED, attack = attack, through = attack.pierce or 0, met = {} }
    return true
  end
  local targets = self:ahead(attack.reach, attack.wide)
  for nth = 1, math.min(#targets, 1 + (attack.pierce or 0)) do
    local mob = targets[nth]
    local amount = attack.hits
    if attack.close and mob.depth < attack.close then
      amount = amount / 2
    end
    if attack.ambush and (unseen or not mob.awake) then
      amount = amount * attack.ambush
    end
    self:wound(mob, amount, attack)
  end
  if #targets > 0 then
    self:sound(sounds[2])
  end
  return true
end

--- The player does the thing their class can do, if it is ready and they have the power for it
--- @return boolean done
--- @return string? why Not, by its L key, for the player to be told
function View:cast()
  local run, pose = self.run, self.pose
  local spec, ability = run.spec, run.spec.ability
  --- @type WarcraftsteinState
  local state = self.view.state
  if run.ready > 0 then
    return false, "warcraftstein_not_ready"
  elseif run.power < (ability.cost or 0) then
    return false, "warcraftstein_no_" .. spec.power
  end

  local kind = ability.kind
  -- No fighting in the sanctuary: only what the player does for themselves
  if run.safe and kind ~= "heal" and kind ~= "buff" and kind ~= "tap" then
    return false, "warcraftstein_no_fighting"
  end
  if kind == "nova" or kind == "volley" then
    local aheadX, aheadY = math.cos(pose.facing), math.sin(pose.facing)
    for _, mob in ipairs(run.mobs) do
      local byX, byY = mob.x - pose.x, mob.y - pose.y
      local near = byX * byX + byY * byY <= ability.reach ^ 2
      if kind == "volley" then
        -- Only the ones that can be seen: ahead, and not off to either side
        local depth = byX * aheadX + byY * aheadY
        near = near and depth > 0 and math.abs(byY * aheadX - byX * aheadY) <= depth * REACH
      end
      if near and not mob.dead and sees(state, pose.x, pose.y, mob.x, mob.y) then
        mob.frozen = math.max(mob.frozen, ability.freezes or 0)
        self:wound(mob, ability.hits, spec.attack, true)
      end
    end
  elseif kind == "buff" then
    run.buff, run.buffLeft = ability, ability.lasts
  elseif kind == "heal" then
    if run.health >= spec.health then
      return false, "warcraftstein_full_health"
    end
    run.health = math.min(spec.health, run.health + ability.heals)
  elseif kind == "tap" then
    if run.health <= ability.takes then
      return false, "warcraftstein_too_hurt"
    elseif run.power >= POWER then
      return false, "warcraftstein_full_" .. spec.power
    end
    run.health, run.power = run.health - ability.takes, math.min(POWER, run.power + ability.gives)
  elseif kind == "totem" then
    -- A step ahead where there is room for it, or it would stand where nobody can see it
    local x, y = pose.x + math.cos(pose.facing) * 0.7, pose.y + math.sin(pose.facing) * 0.7
    if blocked(state, x, y) then
      x, y = pose.x, pose.y
    end
    run.totem = { x = x, y = y, left = ability.lasts, wait = 0 }
  end
  run.power, run.ready = run.power - (ability.cost or 0), ability.every
  -- Done, for all to see and hear: its name, and the view lit up in its colour
  self:sound(ABILITY_SOUNDS[ability.id])
  self:glow(ability.veil or STRIKE_COLOR)
  local name = L["warcraftstein_ability_" .. ability.id]:match("^(.-)%.") or ability.id
  self.effects:Float(name, self.left + self.seenWidth / 2, MARGIN + self.seenHeight * 0.45, { size = 20, color = private.Widgets.GOLD })
  return true
end

--- Says why what the player pressed didn't happen, unless they were told just that a moment ago
--- @param why string? What to say, by its L key
function View:balk(why)
  if not why or (why == self.balked and (self.balkLeft or 0) > 0) then
    return
  end
  self.balked, self.balkLeft = why, BALK_AGAIN
  self.effects:Float(L[why], self.left + self.seenWidth / 2, MARGIN + self.seenHeight * 0.6, { size = 16, color = { 1, 0.4, 0.3 } })
end

--- Plays one of the client's own sounds, if the player has sound on
--- @param file number?
function View:sound(file)
  if file and PlaySoundFile and ForeverGames.db.profile.sound then
    PlaySoundFile(file, "SFX")
  end
end

--- Lights the view up for a moment in a colour: something the player did went off
--- @param color number[]
function View:glow(color)
  self.effects:Flash({ color[1], color[2], color[3], CAST_GLOW }, CAST_GLOW_SECONDS)
end

--- Moves the bolts that are on their way, until they meet someone or a wall
--- @param elapsed number
function View:fly(elapsed)
  local run, pose = self.run, self.pose
  --- @type WarcraftsteinState
  local state = self.view.state
  for _, list in ipairs({ run.bolts, run.shots }) do
    for index = #list, 1, -1 do
      local bolt = list[index]
      local left, spent = bolt.speed * elapsed, false
      while left > 0 and not spent do
        local far = math.min(left, BOLT_STEP)
        left = left - far
        bolt.x, bolt.y = bolt.x + bolt.byX * far, bolt.y + bolt.byY * far
        spent = kindAt(state, bolt.x, bolt.y) ~= OPEN
        if not spent and bolt.attack then
          for _, mob in ipairs(run.mobs) do
            if not spent and not mob.dead and not bolt.met[mob] and (mob.x - bolt.x) ^ 2 + (mob.y - bolt.y) ^ 2 < BOLT_GIRTH ^ 2 then
              bolt.met[mob] = true
              self:sound((STRIKE_SOUNDS[run.class] or MELEE_SOUNDS)[2])
              self:wound(mob, bolt.attack.hits, bolt.attack)
              if bolt.attack.chain then
                self:chain(mob, bolt.attack)
              end
              spent = bolt.through <= 0
              bolt.through = bolt.through - 1
            end
          end
        elseif not spent and sheltered(run, bolt.x, bolt.y) then
          spent = true
        elseif not spent and (pose.x - bolt.x) ^ 2 + (pose.y - bolt.y) ^ 2 < BOLT_GIRTH ^ 2 then
          spent = true
          self:hurt(bolt.hits)
        end
      end
      if spent then
        table.remove(list, index)
      end
    end
  end
end

--- A bolt goes on from the foe it hit to the nearest other one that foe can see
--- @param from WarcraftsteinMob
--- @param attack WarcraftsteinAttack
function View:chain(from, attack)
  local nearest, found = CHAIN * CHAIN, nil
  for _, mob in ipairs(self.run.mobs) do
    local away = (mob.x - from.x) ^ 2 + (mob.y - from.y) ^ 2
    if mob ~= from and not mob.dead and away <= nearest and sees(self.view.state, from.x, from.y, mob.x, mob.y) then
      nearest, found = away, mob
    end
  end
  if found then
    self:wound(found, attack.hits * attack.chain, attack, true)
  end
end

--- The totem that stands burns the nearest foe it can see, every so often, until it is spent
--- @param elapsed number
function View:burn(elapsed)
  local run, ability = self.run, self.run.spec.ability
  local totem = run.totem
  totem.left, totem.wait = totem.left - elapsed, totem.wait - elapsed
  if totem.left <= 0 then
    run.totem = nil
  elseif totem.wait <= 0 then
    local nearest, found = ability.reach ^ 2, nil
    for _, mob in ipairs(run.mobs) do
      local away = (mob.x - totem.x) ^ 2 + (mob.y - totem.y) ^ 2
      if not mob.dead and away <= nearest and sees(self.view.state, totem.x, totem.y, mob.x, mob.y) then
        nearest, found = away, mob
      end
    end
    if found then
      totem.wait = ability.wait
      self:wound(found, ability.hits)
    end
  end
end

--- Where a foe that is after the player goes next: straight for them while they are in sight,
--- else to the square next door that is nearer to them, or only to where they were seen last
--- if they are nowhere to be seen
--- @param mob WarcraftsteinMob
--- @param seen boolean
--- @param hidden boolean
--- @return number x, number y
function View:heading(mob, seen, hidden)
  if seen then
    return self.pose.x, self.pose.y
  end
  local toX, toY = mob.toX or mob.x, mob.toY or mob.y
  if not hidden then
    local side, trail = self.view.state.side, self:trail()
    local square = math.floor(mob.y) * side + math.floor(mob.x) + 1
    local nearest = trail[square] or math.huge
    for _, next in ipairs({ square - 1, square + 1, square - side, square + side }) do
      if trail[next] and trail[next] < nearest then
        nearest = trail[next]
        toX, toY = (next - 1) % side + 0.5, math.floor((next - 1) / side) + 0.5
      end
    end
  end
  return toX, toY
end

--- Moves a foe towards a point, no further than it gets in the time
--- @param mob WarcraftsteinMob
--- @param toX number
--- @param toY number
--- @param far number How far it gets
--- @return boolean moved
function View:step(mob, toX, toY, far)
  --- @type WarcraftsteinState
  local state, run = self.view.state, self.run
  local byX, byY = toX - mob.x, toY - mob.y
  local left = math.sqrt(byX * byX + byY * byY)
  if left <= THERE then
    return false
  end
  far = math.min(left, far)
  byX, byY = byX / left * far, byY / left * far
  local x, y = mob.x, mob.y
  --- Whether there is room there for a foe, which there never is in the sanctuary
  local function room(toX, toY)
    return not blocked(state, toX, toY) and not sheltered(run, toX, toY) and not crowded(run, mob, mob.x, mob.y, toX, toY)
  end
  if room(x + byX, y) then
    mob.x = x + byX
  end
  if room(mob.x, y + byY) then
    mob.y = y + byY
  end
  if mob.x == x and mob.y == y then
    return false
  end
  mob.walked = mob.walked + far
  return true
end

--- What a foe does in the time that passed
--- @param mob WarcraftsteinMob
--- @param elapsed number
--- @return boolean stirred There is something new to see of it
function View:stir(mob, elapsed)
  local run, pose, foe = self.run, self.pose, mob.foe
  --- @type WarcraftsteinState
  local state = self.view.state
  local stirred = mob.struck > 0 or mob.hurt > 0 or mob.frozen > 0 or mob.slowed > 0
  mob.struck, mob.hurt = math.max(0, mob.struck - elapsed), math.max(0, mob.hurt - elapsed)
  mob.slowed = math.max(0, mob.slowed - elapsed)
  if mob.dead then
    return stirred
  end
  if mob.frozen > 0 then
    mob.frozen, mob.swing = math.max(0, mob.frozen - elapsed), nil
    return true
  end

  local hidden = run.safe or (run.buff ~= nil and run.buff.hidden == true)
  local away = math.sqrt((pose.x - mob.x) ^ 2 + (pose.y - mob.y) ^ 2)
  local seen = not hidden and (mob.awake or away <= foe.wakes) and sees(state, mob.x, mob.y, pose.x, pose.y)
  if seen then
    if not mob.awake then
      self:rouse(mob)
    end
    mob.lost, mob.toX, mob.toY = 0, pose.x, pose.y
  end
  if not mob.awake then
    return stirred
  end
  local pace = (mob.slowed > 0 and 0.5 or 1) * (mob.angry and 1.25 or 1)
  local often = mob.angry and 0.6 or 1
  mob.wait = mob.wait - elapsed

  -- Herod spins with his axe now and then, and comes on while he does
  local spins = foe.spins
  if spins and mob.spinning <= 0 and seen and away < spins.reach * 2.5 and mob.wait <= 0 then
    mob.spinning, mob.spun, mob.wait = spins.lasts, 0, spins.every * often
    self:say(L["warcraftstein_herod_spin"])
  end
  if mob.spinning > 0 then
    mob.spinning, mob.spun = mob.spinning - elapsed, mob.spun - elapsed
    if mob.spun <= 0 and away <= spins.reach then
      mob.spun = spins.each
      self:hurt(spins.hits, mob)
    end
    self:step(mob, pose.x, pose.y, spins.speed * pace * elapsed)
    return true
  end

  if seen and away <= foe.reach then
    mob.swing = (mob.swing or foe.windup) - elapsed
    if mob.swing > 0 then
      return stirred
    end
    mob.swing, mob.struck = foe.every * often, SHOWN
    self:hurt(foe.hits, mob)
    return true
  end
  mob.swing = nil

  -- One that casts does so from where it stands, and keeps the player at arm's length
  local casts = foe.casts
  if casts and seen and away <= casts.range then
    if mob.wait <= 0 then
      mob.wait, mob.struck = casts.every * often, SHOWN * 2
      local byX, byY = (pose.x - mob.x) / away, (pose.y - mob.y) / away
      run.shots[#run.shots + 1] = { x = mob.x, y = mob.y, byX = byX, byY = byY, speed = casts.speed, hits = casts.hits, tint = casts.tint }
      stirred = true
    end
    if away < casts.keep then
      return self:step(mob, mob.x * 2 - pose.x, mob.y * 2 - pose.y, foe.speed * pace * elapsed) or stirred
    end
    return stirred
  end

  mob.lost = mob.lost + (seen and 0 or elapsed)
  if mob.lost > LOOKS then
    mob.awake = false
    return true
  end
  local toX, toY = self:heading(mob, seen, hidden)
  if self:step(mob, toX, toY, foe.speed * pace * elapsed) then
    return true
  end
  -- Where the player was last seen and nobody there: nothing to stay up for
  if hidden then
    mob.awake = false
  end
  return stirred
end

--- Everything that happens in the monastery in the time that passed
--- @param elapsed number
function View:live(elapsed)
  local view, run, ticker = self.view, self.run, self.ticker
  if not view or not run or not view.canMove or self.book:IsShown() then
    return
  end
  -- A key that was let go of somewhere else is never heard of again, and nothing happens to
  -- a player who isn't there to do anything about it
  if not ticker:IsMouseOver() and not self.dragged then
    self.down = {}
    return
  end
  elapsed = math.min(elapsed, LONGEST_FRAME)
  local spec, health = run.spec, run.health

  local moved, out = self:walk(elapsed)
  local safe = sheltered(run, run.pose.x, run.pose.y)
  if safe and not run.safe then
    self:say(L["warcraftstein_sanctuary"], private.Widgets.GOLD)
  end
  local stirred = moved or run.swung > 0 or safe ~= run.safe
  run.safe = safe
  -- The fountain's water moves, which is only worth drawing while it can be seen
  local moment = math.floor(run.ripple / RIPPLE)
  run.ripple = run.ripple + elapsed
  if math.floor(run.ripple / RIPPLE) ~= moment then
    for _, seen in ipairs(self.seen) do
      stirred = stirred or seen.frames ~= nil
    end
  end
  stirred = stirred or run.buff ~= nil or run.totem ~= nil or #run.bolts > 0 or #run.shots > 0
  run.cooldown, run.ready = math.max(0, run.cooldown - elapsed), math.max(0, run.ready - elapsed)
  run.swung, run.buffLeft = math.max(0, run.swung - elapsed), math.max(0, run.buffLeft - elapsed)
  run.quiet = math.max(0, run.quiet - elapsed)
  if run.buffLeft == 0 then
    run.buff = nil
  end
  if run.said > 0 then
    run.said = run.said - elapsed
    self.said:SetAlpha(math.min(1, run.said * 2))
    self.said:SetShown(run.said > 0)
  end
  run.power = math.min(POWER, run.power + (spec.regen or 0) * elapsed)
  run.health = math.min(spec.health, run.health + ((spec.mend or 0) + (safe and SANCTUARY_MEND or 0)) * elapsed)
  local pressed = self.pressed
  self.pressed, self.balkLeft = {}, math.max(0, (self.balkLeft or 0) - elapsed)
  if self.down[CAST] then
    local done, why = self:cast()
    if done then
      stirred = true
    elseif pressed[CAST] then
      self:balk(why)
    end
  end
  if self.down[STRIKE] and safe then
    if pressed[STRIKE] then
      self:balk("warcraftstein_no_fighting")
    end
  elseif self.down[STRIKE] and run.cooldown == 0 then
    if self:strike() then
      stirred = true
    elseif pressed[STRIKE] then
      self:balk("warcraftstein_no_" .. spec.power)
    end
  end
  self:fly(elapsed)
  if run.totem then
    self:burn(elapsed)
  end

  -- What lies on the floor is drunk by walking over it, unless there is no room for it
  for index = #run.loot, 1, -1 do
    local potion = run.loot[index]
    local most = potion.kind == "health" and spec.health or POWER
    if run[potion.kind] < most and (potion.x - run.pose.x) ^ 2 + (potion.y - run.pose.y) ^ 2 < GRASP * GRASP then
      run[potion.kind] = math.min(most, run[potion.kind] + POTION[potion.kind] * (1 + (spec.potency or 0)))
      table.remove(run.loot, index)
      stirred = true
    end
  end

  local before = run.health
  for _, mob in ipairs(run.mobs) do
    stirred = self:stir(mob, elapsed) or stirred
  end

  if stirred then
    self:render()
  end
  self:gauge()
  if run.health < before then
    self.effects:Flash({ 0.8, 0, 0, 0.35 }, 0.3)
  elseif run.health > health + 1 then
    self.effects:Flash({ 0.2, 0.9, 0.3, 0.2 }, 0.3)
  end
  if out or run.health == 0 then
    self.down = {}
    view.submit(out and EXIT or DEAD)
  end
end

--- Shows how the player is: their health, power and level, and whether they can do their thing
function View:gauge()
  local run, ability, talents = self.run, self.ability, self.talents
  if not run then
    return
  end
  self.health:Set(run.health, run.spec.health)
  self.health:Tint(run.health <= HEALTH_LOW and private.Widgets.RED or private.Widgets.GREEN)
  self.power:Set(math.floor(run.power), POWER)
  local wait = math.ceil(run.ready)
  local can = wait == 0 and run.power >= (run.spec.ability.cost or 0)
  if wait ~= ability.waits or can ~= ability.can then
    ability.waits, ability.can = wait, can
    ability.wait:SetText(wait > 0 and wait or "")
    ability.icon:SetDesaturated(not can)
    ability.icon:SetVertexColor(can and 1 or 0.5, can and 1 or 0.5, can and 1 or 0.5)
  end
  if talents.shown ~= run.points then
    talents.shown = run.points
    talents.points:SetText(run.points > 0 and run.points or "")
    if run.points > 0 then
      talents.pulse:Play()
    else
      talents.pulse:Stop()
    end
  end
  self.portrait.level:SetText(run.level)
  self.xp:SetWidth(math.max(0.01, self.seenWidth * run.xp / levelXp(run.level)))
  local boss = run.boss
  self.bossBar:SetShown(boss ~= nil and boss.awake)
  if boss then
    self.bossBar:Set(boss.health, boss.foe.health, L["warcraftstein_herod"])
  end
end

--- Shows what the clock says by now
function View:tick()
  local view = self.view
  if not view then
    return
  end
  local seconds = math.floor(view.clock())
  if seconds ~= self.seconds then
    self.seconds = seconds
    self.time:Set(private.Widgets.Time(seconds), true)
  end
end

--- The game is over: says how across what the player saw
--- @param instant boolean? For a game that was over before it was looked at
function View:finish(instant)
  local view, Widgets = self.view, private.Widgets
  self.book:Hide()
  if view.state.dead then
    self.effects:Banner(L["warcraftstein_dead"], L["warcraftstein_dead_how"], { color = Widgets.RED, instant = instant })
    return
  end
  local time = Widgets.Time(view.clock())
  local _, mine = view.best(TIME_KEY .. view.state.size)
  local words = L["warcraftstein_out_in"]:format(time)
  if mine then
    words = words .. "  " .. L["new_best"]
  end
  self.effects:Banner(L["warcraftstein_out"], words, { instant = instant })
  if not instant then
    self.effects:Confetti()
  end
end

--- @param width number
--- @param height number
function View:Layout(width, height)
  self.width, self.height = width, height
  self:arrange()
  self:render()
  -- The bars are as full as they were of however wide they are now
  self:gauge()
end

--- How a game begins: the player at the start as who they said they are, everything else
--- where the state says it is
--- @param state WarcraftsteinState
--- @param id string The match's
--- @return WarcraftsteinRun
local function newRun(state, id)
  local spec = build(state.class, {})
  --- @type WarcraftsteinRun
  local run = {
    class = state.class,
    spec = spec,
    learned = {},
    level = 1,
    xp = 0,
    points = 0,
    pose = { x = state.start.x, y = state.start.y, facing = state.start.facing },
    health = spec.health,
    power = spec.gains and 0 or POWER,
    mobs = {},
    loot = {},
    decor = {},
    lights = {},
    bolts = {},
    shots = {},
    buffLeft = 0,
    cooldown = 0,
    ready = 0,
    swung = 0,
    walked = 0,
    said = 0,
    quiet = 0,
    sanctuary = state.rooms[1],
    safe = false,
    ripple = 0,
    dice = private.Random.New(private.Random.Seed(id)),
  }
  for index, start in ipairs(state.mobs) do
    local foe = FOES[start.kind]
    --- @type WarcraftsteinMob
    local mob = { x = start.x, y = start.y, kind = start.kind, foe = foe, health = foe.health, awake = false, dead = false, lost = 0, wait = 0, spinning = 0, spun = 0, angry = false, struck = 0, hurt = 0, frozen = 0, slowed = 0, walked = 0 }
    run.mobs[index] = mob
    if foe.boss then
      run.boss = mob
    end
  end
  for index, potion in ipairs(state.loot) do
    run.loot[index] = { x = potion.x, y = potion.y, kind = potion.kind }
  end
  for index, item in ipairs(state.decor) do
    local kind = DECOR[item.kind]
    run.decor[index] = { x = item.x, y = item.y, kind = item.kind, first = kind.picture, frames = kind.frames, light = kind.light, color = kind.color, girth = kind.girth, power = kind.light }
    if kind.light then
      run.lights[#run.lights + 1] = run.decor[index]
    end
  end
  return run
end

--- @param view GameView
function View:Update(view)
  local before = self.view
  self.view = view
  --- @type WarcraftsteinState
  local state = view.state
  local id = view.match.id
  local another = not before or before.match.id ~= id

  if another then
    self.effects:Clear()
    self.down, self.seconds = {}, nil
    self.book:Hide()
    self.said:Hide()
    if SetPortraitTexture then
      SetPortraitTexture(self.portrait.face, "player")
    end
  end
  local run = self.runs[id]
  if not run and state.class then
    run = newRun(state, id)
    self.runs[id] = run
  end
  if another or run ~= self.run then
    self.run, self.pose = run, run and run.pose
    if run then
      self.power:Tint(POWER_COLORS[run.spec.power])
      self.ability.icon:SetTexture(ICONS .. run.spec.ability.icon)
      self.ability.waits, self.talents.shown = nil, nil
      self:gauge()
      self:render()
    end
  end
  for _, widget in ipairs({ self.health, self.power, self.ability, self.talents, self.xp }) do
    widget:SetShown(run ~= nil)
  end

  -- Nobody yet: the monastery waits behind the question who
  local picker, own = self.picker, ownClass()
  picker:SetShown(not state.class)
  if not state.class then
    picker.own:SetText(L["warcraftstein_pick_own"]:format(className(own)))
    for class, pick in pairs(self.picks) do
      local color = class == own and private.Widgets.GOLD or { 1, 1, 1 }
      pick:SetBackdropBorderColor(color[1], color[2], color[3], class == own and 1 or 0.1)
    end
  end

  local Widgets = private.Widgets
  local best, mine = view.best(TIME_KEY .. state.size)
  self.best:Set(best and Widgets.Time(best) or L["stat_none"])
  self.best:Tint(mine and Widgets.GOLD or nil)
  self:tick()

  if (state.found or state.dead) and not self.effects:HasBanner() then
    local arrived = view.changed and view.played ~= nil
    if arrived and state.found then
      Widgets.PlaySound(SOUNDKIT[FOUND_SOUND] and FOUND_SOUND or FOUND_SOUND_ELSE)
    end
    self:finish(not arrived)
  end
end

private.Games.Register({
  id = "warcraftstein",
  name = L["game_warcraftstein"],
  description = L["game_warcraftstein_description"],
  genre = "solo",
  icon = "Interface\\AddOns\\ForeverGames\\Images\\Icons\\warcraftstein",
  version = 2,
  seats = 1,
  options = {
    {
      id = "size",
      name = L["warcraftstein_option_size"],
      description = L["warcraftstein_option_size_tip"],
      choices = SIZES,
      default = USUAL_SIZE,
      label = function(value)
        return L["warcraftstein_option_size_label"]:format(value)
      end,
    },
  },
  howto = {
    { heading = L["howto_goal"], text = L["warcraftstein_howto_goal"] },
    { heading = L["warcraftstein_howto_class"], text = L["warcraftstein_howto_class_text"] },
    { heading = L["howto_controls"], text = L["warcraftstein_howto_controls"] },
    { heading = L["warcraftstein_howto_monastery"], text = L["warcraftstein_howto_monastery_text"] },
    { heading = L["warcraftstein_howto_talents"], text = L["warcraftstein_howto_talents_text"] },
    { heading = L["howto_end"], text = L["warcraftstein_howto_end"] },
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
    return L["warcraftstein_progress"]:format(state.size)
  end,
  record = function(state, seconds)
    -- Only getting out has a time worth keeping
    if state.found then
      return { { key = TIME_KEY .. state.size, value = seconds, lower = true } }
    end
    return nil
  end,
  -- The day's maze, raced to the way out
  daily = {
    score = function(state, seconds)
      return state.found and seconds or nil
    end,
    lower = true,
    time = true,
  },
  createView = createView,
})
