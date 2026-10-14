--------------------------
--  Warcraftstein 3D
--------------------------
-- A maze seen from inside it, for one player: walk it until the way out is found, past the
-- kobolds that live in it. It is drawn the way the shooters of the early nineties drew theirs.
-- What the player can do about the kobolds depends on their class (CLASSES), which is the one
-- of the character they are on unless they pick another.
--
-- The maze is a square of rooms with walls between them, laid out on a grid twice as fine: of
-- its squares the ones with an even column and an even row are rooms, the ones between two rooms
-- are either wall or a way through, and the rest is always wall. It is dug from the top left
-- room, so there is exactly one way from anywhere to anywhere, and then a few more walls are
-- taken out so that it isn't all dead ends. The way out is the room that is furthest to walk to
-- from the start, made a dead end if it isn't one: it is filled in with a portal, to be walked
-- into.
--
-- The state keeps what is on every square of the grid, numbered along the rows from 1 in the
-- top left corner: 0 for nothing, 1 to 3 for a kind of wall and 4 for the portal. Where the
-- player stands is measured in squares from that corner, across and down, and the way they face
-- as an angle that is 0 looking right and grows turning right.
--
-- The kobolds are asleep in rooms well away from where the player begins, and there are potions
-- in some of the others. The state only says which rooms.
--
-- The game has turns like any other as far as the engine knows, and only three moves. The first
-- is "c" and a class, "cMAGE": who the player is in there. It is a move so that the game is the
-- same one when it is loaded again on another character. Then "x", the player walked into the
-- portal, or "d", the kobolds got them first. Everything on the way there is the view's
-- business and happens many times a second, which is far too often to be written down. So the
-- engine is never told where the player is or how the kobolds are doing, and a game that is
-- left and loaded again begins at the start with all of them back in bed.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L

local SIZES, USUAL_SIZE = { 6, 9, 12 }, 9
local OPEN, PORTAL = 0, 4
-- How many kinds of wall there are, and how many squares each way a part of the maze built of
-- one of them is
local WALLS, ZONE = 3, 6
-- One wall in this many rooms is taken out again once the maze is dug
local LOOP_IN = 6
local STEPS = { { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } }
local EXIT, DEAD, CLASS = "x", "d", "c"
-- One kobold to this many rooms, none of them nearer to the start than this many squares' walk
local ROOMS_A_MOB, MOBS_FROM = 5, 8
-- And a potion for health and one for power to this many
local ROOMS_A_HEALTH, ROOMS_A_POWER = 9, 12

-----------------------------
-- Classes
-----------------------------
-- What a class is in the maze: how much it takes, what it strikes with (`attack`) and the one
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
-- What a character is that is of a class the maze doesn't know
local USUAL_CLASS = "WARRIOR"
-- What the best time is kept under, with the size of the maze after it
local TIME_KEY = "time"

--- @class WarcraftsteinState
--- @field size number How many rooms the maze has each way
--- @field side number How many squares its grid has each way
--- @field cells number[] What is on every square
--- @field start { x: number, y: number, facing: number } Where the player begins
--- @field mobs { x: number, y: number }[] Where the kobolds sleep
--- @field loot { x: number, y: number, kind: "health"|"power" }[] Where the potions are
--- @field class string? Who the player is, once they have said
--- @field found boolean The player is out
--- @field dead boolean The player never will be

-----------------------------
-- Rules
-----------------------------

--- @param seats number
--- @param random Random
--- @param rules table<string, any>?
--- @return WarcraftsteinState
local function newState(_, random, rules)
  local size = rules and rules.size or USUAL_SIZE
  local side = size * 2 + 1
  local cells = {}
  -- Which wall a part of the maze is built of: no two parts next to each other of the same
  local first = random:Roll(WALLS)
  local function wall(column, row)
    local zone = math.floor((column - 1) / ZONE) + math.floor((row - 1) / ZONE) * 2
    return (zone + first) % WALLS + 1
  end
  local function at(column, row)
    return (row - 1) * side + column
  end
  for row = 1, side do
    for column = 1, side do
      cells[at(column, row)] = wall(column, row)
    end
  end

  -- Dug from the first room: on into a room nobody was in yet for as long as there is one next
  -- door, back the way it came when there isn't
  local path = { { 2, 2 } }
  cells[at(2, 2)] = OPEN
  while #path > 0 do
    local here = path[#path]
    local ways = {}
    for _, step in ipairs(STEPS) do
      local column, row = here[1] + step[1] * 2, here[2] + step[2] * 2
      if column > 1 and column < side and row > 1 and row < side and cells[at(column, row)] ~= OPEN then
        ways[#ways + 1] = step
      end
    end
    if #ways == 0 then
      path[#path] = nil
    else
      local step = ways[random:Roll(#ways)]
      cells[at(here[1] + step[1], here[2] + step[2])] = OPEN
      cells[at(here[1] + step[1] * 2, here[2] + step[2] * 2)] = OPEN
      path[#path + 1] = { here[1] + step[1] * 2, here[2] + step[2] * 2 }
    end
  end

  -- The way the player looks to begin with: down the only way there is out of the first room
  local facing = cells[at(3, 2)] == OPEN and 0 or math.pi / 2

  -- A few ways round
  for _ = 1, math.floor(size * size / LOOP_IN) do
    -- A wall between two rooms: an odd column in an even row, or the other way round
    local along, between = random:Roll(size) * 2, random:Roll(size - 1) * 2 + 1
    if random:Roll(2) == 1 then
      cells[at(along, between)] = OPEN
    else
      cells[at(between, along)] = OPEN
    end
  end

  -- The way out is in the room that is furthest to walk to, by the shortest way there is now.
  -- Squares are gone through in the order they are reached, so the last room is that one
  local reached, from, exit = { { 2, 2 } }, { [at(2, 2)] = 0 }, nil
  -- How far the walk to every square is, and the rooms far enough away for a kobold
  local walk, dens, rooms = { [at(2, 2)] = 0 }, {}, {}
  local index = 1
  while reached[index] do
    local here = reached[index]
    if here[1] % 2 == 0 and here[2] % 2 == 0 then
      exit = here
      if walk[at(here[1], here[2])] >= MOBS_FROM then
        dens[#dens + 1] = here
      elseif index > 1 then
        rooms[#rooms + 1] = here
      end
    end
    for _, step in ipairs(STEPS) do
      local column, row = here[1] + step[1], here[2] + step[2]
      if cells[at(column, row)] == OPEN and not from[at(column, row)] then
        from[at(column, row)] = at(here[1], here[2])
        walk[at(column, row)] = walk[at(here[1], here[2])] + 1
        reached[#reached + 1] = { column, row }
      end
    end
    index = index + 1
  end
  -- It is to be a dead end, seen from one side only: every way into it but the one it was
  -- reached by is walled up again. Whatever lies behind one of those can be got to some other
  -- way, or it would be further still
  for _, step in ipairs(STEPS) do
    local column, row = exit[1] + step[1], exit[2] + step[2]
    if at(column, row) ~= from[at(exit[1], exit[2])] then
      cells[at(column, row)] = wall(column, row)
    end
  end
  cells[at(exit[1], exit[2])] = PORTAL

  -- Nobody sleeps in the portal, which is the last of the rooms that were reached
  if dens[#dens] == exit then
    dens[#dens] = nil
  end
  local mobs = {}
  for _ = 1, math.min(#dens, math.floor(size * size / ROOMS_A_MOB)) do
    local den = table.remove(dens, random:Roll(#dens))
    mobs[#mobs + 1] = { x = den[1] - 0.5, y = den[2] - 0.5 }
  end
  -- Potions in rooms nobody sleeps in, the ones near the start included
  for _, den in ipairs(dens) do
    rooms[#rooms + 1] = den
  end
  local loot = {}
  for _, potion in ipairs({ { "health", ROOMS_A_HEALTH }, { "power", ROOMS_A_POWER } }) do
    for _ = 1, math.min(#rooms, math.floor(size * size / potion[2])) do
      local room = table.remove(rooms, random:Roll(#rooms))
      loot[#loot + 1] = { x = room[1] - 0.5, y = room[2] - 0.5, kind = potion[1] }
    end
  end

  --- @type WarcraftsteinState
  return {
    size = size,
    side = side,
    cells = cells,
    start = { x = 1.5, y = 1.5, facing = facing },
    mobs = mobs,
    loot = loot,
    found = false,
    dead = false,
  }
end

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
--- @return number kind Wall for anywhere that isn't in the maze at all
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
    -- The maze has a wall all round, so there is always something. Should there not be, the
    -- look ends where the grid does
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
-- to show (SetTexCoord) and how tall to be. Walls further off are darker, and so are the ones
-- that face up or down the map, which is all the light there is. Floor and ceiling have no
-- picture, they are bands of one colour that get darker towards where they meet.
--
-- Whatever stands in the maze (a kobold, a potion, a bolt on its way, a totem) is a picture
-- that stands on the floor and always faces the player. It is drawn in the same columns the
-- walls are, a strip of its picture in each, and only in those where the wall behind it is
-- further away than it is, which is all it takes for one to be half hidden by a corner.
-- Several can be seen in one column, the nearer over the further: there are a few layers of
-- strips for that (LAYERS), and what is further away than there are layers for shares the one
-- at the back.
--
-- The player walks with W and S or the arrow keys, turns with A and D or the arrows, steps
-- sideways with Q and E, strikes with the space bar and does what their class can do with F,
-- for as long as a key is held and the cursor is over the game. With the cursor anywhere else
-- the maze stands still, kobolds and all. Nothing is drawn while nothing in it moves.
--
-- A kobold sleeps until it sees the player from near enough, or is hit, and wakes the ones
-- around it when it does. Then it comes for them: by the straight way while it sees them, and
-- by the shortest way through the maze when it doesn't (View:trail), until it hasn't seen them
-- for a good while. Near enough to the player it stops and swings its pickaxe at them, again
-- and again. A player nobody can see (a rogue) is only looked for where they were seen last.

local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\Warcraftstein\\"
local ICONS = "Interface\\Icons\\"
local PICTURES = { IMAGES .. "brick", IMAGES .. "stone", IMAGES .. "moss", IMAGES .. "portal" }
-- How many pixels a wall's picture is wide
local TEXELS = 64
-- Everything that stands in the maze, next to each other in one file: two pictures of a kobold
-- walking, one striking and one dead, a bolt, the potions and a totem. And how many pixels wide
-- the file is
local SPRITES, SPRITE_SHEET = IMAGES .. "sprites", 512
local STANDING, STRIKING, FALLEN, BOLT, TOTEM = 0, 2, 3, 4, 7
local POTIONS = { health = 5, power = 6 }
-- And everything the player can hold, ready and swung
local WEAPONS, WEAPON_SHEET = IMAGES .. "weapons", 512
-- Where the classes have their pictures, for the client that says where in it (CLASS_ICON_TCOORDS)
local CLASS_PICTURES = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"
-- How many things can be seen one behind the other in a column, and how near one is drawn at all
local LAYERS, NEAREST = 6, 0.15
-- How wide what is seen is for how tall, and how far to either side it reaches for every step
-- ahead: about 66 degrees from one edge to the other
local ASPECT, REACH = 1.6, 0.66
-- How wide a column is at most, and how many of them there are at least and at most
local SLICE, FEWEST, MOST = 3, 60, 240
-- Bands the ceiling and the floor are each made of
local BANDS = 12
local CEILING, FLOOR = { 0.2, 0.2, 0.26 }, { 0.34, 0.29, 0.25 }
-- How quickly it gets dark with distance, how dark it gets at most, and how much less light
-- there is on a wall that faces up or down the map
local FOG, DARKEST, FLANK = 0.3, 0.14, 0.7
-- Squares a second, how much of that going backwards, turns (in radians) a second, and how
-- near a wall the player can get
local WALK, BACKWARDS, TURN, GIRTH = 2.6, 0.6, 2.4, 0.22
-- The longest time a frame is taken to have lasted, so a hitch doesn't carry anyone through a wall
local LONGEST_FRAME = 0.1
-- Below what the player's health is shown in red, and how long what they hold is shown swung
local HEALTH_LOW, SWUNG = 30, 0.18
-- A kobold: what it starts with, squares a second, from how far it sees the player while it
-- sleeps and how far its waking is heard by others, how long it looks for a player it can't
-- see, how near it comes, what its blow takes off, how long it winds up for the first and how
-- long until every next, and how long it is shown striking and hurt
local KOBOLD = { health = 40, speed = 2.2, wakes = 7, calls = 4, looks = 10, reach = 0.95, hits = 12, windup = 0.35, every = 0.9, shown = 0.25, hurt = 0.2 }
-- A bolt: squares a second, how far it goes at a time, and how near it has to come to hit
local BOLT_SPEED, BOLT_STEP, BOLT_GIRTH = 10, 0.2, 0.35
-- How far a bolt that goes on to another kobold jumps
local CHAIN = 2.5
-- What a potion gives, and from how near it is picked up
local POTION, GRASP = { health = 35, power = 50 }, 0.45
-- How near two that walk get to each other, how far a kobold walks on one picture, and how
-- near to where it is going counts as there
local APART, STRIDE, THERE = 0.45, 0.35, 0.05
local HURT_TINT, FROZEN_TINT = { 1, 0.35, 0.35 }, { 0.5, 0.75, 1 }
local POWER_COLORS = { rage = { 0.78, 0.16, 0.16 }, mana = { 0.2, 0.42, 1 }, energy = { 1, 0.88, 0.2 } }
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
local STRIKE, CAST = "SPACE", "F"
local MARGIN, STAT_WIDTH, STAT_HEIGHT, BAR_WIDTH = 8, 80, 38, 150
local PICK_SIZE, PICK_GAP = 40, 6
-- The fanfare, and what to play on a client that doesn't have it
local FOUND_SOUND, FOUND_SOUND_ELSE = "UI_EPICLOOT_TOAST", "IG_QUEST_LIST_COMPLETE"

--- @class WarcraftsteinPose
--- @field x number
--- @field y number
--- @field facing number

--- Something that stands in the maze and is drawn there
--- @class WarcraftsteinThing
--- @field x number
--- @field y number
--- @field depth number? How far ahead of the player it was when it was last drawn
--- @field off number? And where across what is seen, from -1 at the left edge to 1 at the right
--- @field picture number? Which picture of the file it was shown as
--- @field tint number[]? In what colour, white if none
--- @field glows boolean? And whether it was as bright as it is from anywhere

--- @class WarcraftsteinMob: WarcraftsteinThing
--- @field health number
--- @field awake boolean It is after the player
--- @field dead boolean
--- @field toX number? Where it last saw the player
--- @field toY number?
--- @field lost number Seconds since it did
--- @field swing number? Seconds until its blow lands, while the player is within reach
--- @field struck number Seconds it is still shown striking
--- @field hurt number Seconds it is still shown hurt
--- @field frozen number Seconds it can still do nothing
--- @field walked number How far it has walked, for which picture of it to show

--- How a game is going, which the engine knows nothing of
--- @class WarcraftsteinRun
--- @field class string
--- @field spec WarcraftsteinClass
--- @field pose WarcraftsteinPose
--- @field health number
--- @field power number
--- @field mobs WarcraftsteinMob[]
--- @field loot WarcraftsteinThing[] The potions nobody drank yet
--- @field bolts WarcraftsteinThing[] The ones on their way
--- @field totem WarcraftsteinThing? The one that stands, if one does
--- @field buff WarcraftsteinAbility? What the player is for the moment
--- @field buffLeft number And for how many seconds more
--- @field cooldown number Seconds until the player can strike again
--- @field ready number Seconds until they can do what their class does again
--- @field swung number Seconds what they hold is still shown swung
--- @field trail table<number, number>? How far the walk to the player is from every square, see View:trail
--- @field trailTo number? The square that is counted from

--- @class WarcraftsteinView: GameViewObject
--- @field stage Frame
--- @field ticker Frame Takes the keys and the time
--- @field frame Frame What is seen, and what cuts off whatever is too tall for it
--- @field columns Texture[] As many as were ever needed
--- @field count number How many of them are in use
--- @field depths number[] How far away the wall in every column is
--- @field strips table<number, Texture>[] What things are drawn with, by layer and column. Made when first needed
--- @field lit Texture[] The ones that are showing
--- @field seen WarcraftsteinThing[] The things in front of the player, furthest first
--- @field stamp number Counts the times the maze was drawn
--- @field weapon Texture
--- @field veil Texture What everything is seen through while the player is something special
--- @field ceiling Texture[]
--- @field floor Texture[]
--- @field compass FontString
--- @field picker Frame Where the player says who they are
--- @field picks table<string, Button> By class
--- @field portrait Frame
--- @field health Frame
--- @field power Frame
--- @field ability Button
--- @field time Frame
--- @field best Frame
--- @field hint FontString
--- @field effects Effects
--- @field view GameView? What was last asked for
--- @field run WarcraftsteinRun? How the game on screen is going
--- @field pose WarcraftsteinPose? Where the player is in it
--- @field runs table<string, WarcraftsteinRun> And how every game that was looked at is going, by match
--- @field down table<string, boolean> The keys that are held
local View = {}
View.__index = View

--- The class of the character the player is on, as far as the maze knows it
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

--- Says what a class is in the maze, next to whatever the cursor is on
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
--- @return Frame bar Set(value, most) fills it, Tint(color) colours it
local function createBar(parent)
  local bar = private.Widgets.Panel(parent)
  local fill = bar:CreateTexture(nil, "ARTWORK")
  fill:SetPoint("TOPLEFT", 1, -1)
  fill:SetPoint("BOTTOMLEFT", 1, 1)
  local text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  text:SetPoint("CENTER")

  --- @param value number
  --- @param most number
  function bar:Set(value, most)
    -- Anything at all is shown as something: nobody is dead at 1
    value = math.ceil(value)
    if value == self.value and most == self.most and self.wide == self.filled then
      return
    end
    self.value, self.most, self.filled = value, most, self.wide
    fill:SetWidth(math.max(0.01, ((self.wide or 0) - 2) * value / most))
    fill:SetShown(value > 0)
    text:SetText(value)
  end

  --- @param color number[]
  function bar:Tint(color)
    fill:SetColorTexture(color[1], color[2], color[3], 0.85)
  end

  return bar
end

--- @param stage Frame
--- @return WarcraftsteinView
local function createView(stage)
  --- @type WarcraftsteinView
  local self = setmetatable({ stage = stage, columns = {}, count = 0, ceiling = {}, floor = {}, runs = {}, down = {} }, View)
  self.depths, self.strips, self.lit, self.seen, self.stamp = {}, {}, {}, {}, 0
  self.width, self.height = 0, 0
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
    if not (KEYS[key] or key == STRIKE or key == CAST) then
      return false
    end
    self.down[key] = true
    return true
  end)
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
  self.frame = CreateFrame("Frame", nil, self.border)
  self.frame:SetClipsChildren(true)
  for band = 1, BANDS do
    self.ceiling[band] = self.frame:CreateTexture(nil, "BACKGROUND")
    self.floor[band] = self.frame:CreateTexture(nil, "BACKGROUND")
    -- Brightest overhead and underfoot, dark where they meet far away
    local above, below = (BANDS - band + 1) / BANDS, band / BANDS
    self.ceiling[band]:SetColorTexture(CEILING[1] * above, CEILING[2] * above, CEILING[3] * above)
    self.floor[band]:SetColorTexture(FLOOR[1] * below, FLOOR[2] * below, FLOOR[3] * below)
  end
  self.compass = self.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  self.compass:SetPoint("TOP", 0, -6)
  -- Over everything that stands in the maze, under what the player holds
  self.veil = self.frame:CreateTexture(nil, "ARTWORK", nil, 7)
  self.veil:SetAllPoints()
  self.veil:Hide()
  self.weapon = self.frame:CreateTexture(nil, "OVERLAY")
  self.weapon:SetTexture(WEAPONS)

  self:createPicker()

  self.portrait = Widgets.Panel(stage)
  self.portrait:SetSize(STAT_HEIGHT, STAT_HEIGHT)
  self.portrait.face = self.portrait:CreateTexture(nil, "ARTWORK")
  self.portrait.face:SetPoint("TOPLEFT", 2, -2)
  self.portrait.face:SetPoint("BOTTOMRIGHT", -2, 2)
  self.health, self.power = createBar(stage), createBar(stage)

  local ability = Widgets.Panel(stage, "Button")
  ability:SetSize(STAT_HEIGHT, STAT_HEIGHT)
  ability.icon = ability:CreateTexture(nil, "ARTWORK")
  ability.icon:SetPoint("TOPLEFT", 2, -2)
  ability.icon:SetPoint("BOTTOMRIGHT", -2, 2)
  ability.wait = ability:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  ability.wait:SetPoint("CENTER")
  ability.key = ability:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  ability.key:SetPoint("BOTTOMRIGHT", -3, 3)
  ability.key:SetText(CAST)
  ability:SetScript("OnClick", function()
    if self.run and self.view.canMove then
      self:cast()
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

  self.time = Widgets.Stat(stage, L["stat_time"], STAT_WIDTH, STAT_HEIGHT)
  self.best = Widgets.Stat(stage, L["stat_best"], STAT_WIDTH, STAT_HEIGHT)
  self.hint = stage:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  self.hint:SetJustifyH("RIGHT")
  self.hint:SetText(L["warcraftstein_hint"])

  self.effects = private.Effects.New(stage)
  return self
end

--- Builds what the player says who they are with: a button for every class, over the maze
function View:createPicker()
  local Widgets = private.Widgets
  local picker = CreateFrame("Frame", nil, self.frame)
  picker:SetAllPoints()
  picker:SetFrameLevel(self.frame:GetFrameLevel() + 2)
  local shade = picker:CreateTexture(nil, "BACKGROUND")
  shade:SetAllPoints()
  shade:SetColorTexture(0, 0, 0, 0.8)
  -- Everything in it is laid out for a maze that is wide enough, and made smaller for one that isn't
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
    local pick = Widgets.Panel(row, "Button")
    pick:SetSize(PICK_SIZE, PICK_SIZE)
    pick:SetPoint("LEFT", (index - 1) * (PICK_SIZE + PICK_GAP), 0)
    local icon = pick:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", -2, 2)
    local where = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if where then
      icon:SetTexture(CLASS_PICTURES)
      icon:SetTexCoord(where[1], where[2], where[3], where[4])
    else
      -- No picture of it here: what it does stands in for what it is
      icon:SetTexture(ICONS .. CLASSES[class].ability.icon)
    end
    local hover = pick:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetColorTexture(1, 0.82, 0, 0.2)
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
  self.seenWidth, self.seenHeight = seenWidth, seenHeight

  self.border:SetSize(seenWidth + 2, seenHeight + 2)
  self.border:ClearAllPoints()
  self.border:SetPoint("TOPLEFT", stage, "TOPLEFT", left - 1, -(MARGIN - 1))
  self.frame:SetSize(seenWidth, seenHeight)
  self.frame:ClearAllPoints()
  self.frame:SetPoint("TOPLEFT", stage, "TOPLEFT", left, -MARGIN)

  local band = seenHeight / 2 / BANDS
  for index = 1, BANDS do
    for _, half in ipairs({ self.ceiling, self.floor }) do
      local top = (half == self.floor and seenHeight / 2 or 0) + (index - 1) * band
      -- A little more than its share, so nothing shows through between two of them
      half[index]:SetSize(seenWidth, band + 0.5)
      half[index]:ClearAllPoints()
      half[index]:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, -top)
    end
  end

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
  -- Whatever is to be seen of anything is shown again the next time the maze is drawn
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
  self.weapon:ClearAllPoints()
  self.weapon:SetPoint("BOTTOM", self.frame, "BOTTOM", seenWidth * 0.14, 0)
  self.picker.row:SetScale(math.min(1, seenWidth / (self.picker.row:GetWidth() + MARGIN * 4)))

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
  for _, widget in ipairs({ self.ability, self.time, self.best }) do
    widget:ClearAllPoints()
    widget:SetPoint("TOPLEFT", stage, "TOPLEFT", x, -below)
    x = x + widget:GetWidth() + MARGIN
  end
  self.hint:SetWidth(math.max(1, left + seenWidth - x))
  self.hint:ClearAllPoints()
  self.hint:SetPoint("RIGHT", stage, "TOPLEFT", left + seenWidth, -(below + STAT_HEIGHT / 2))
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
  -- How tall a wall one step away is: as tall as it is wide, like every square of the maze
  local tall = self.seenWidth / (2 * REACH)

  for index = 1, count do
    local column = self.columns[index]
    local off = 2 * (index - 0.5) / count - 1
    local distance, kind, across, flank = cast(state, pose.x, pose.y, aheadX + asideX * off, aheadY + asideY * off)
    self.depths[index] = distance
    if kind ~= column.kind then
      column.kind = kind
      column:SetTexture(PICTURES[kind])
    end

    -- A wall too tall to be seen whole shows the part of it that is level with the eye
    local height, top, bottom = tall / math.max(distance, 0.0001), 0, 1
    if height > seenHeight then
      local part = seenHeight / height
      height, top, bottom = seenHeight, 0.5 - part / 2, 0.5 + part / 2
    end
    column:SetHeight(height)
    -- One pixel of the picture across, from well inside it so that its neighbours don't run in
    local strip = math.floor(across * TEXELS)
    column:SetTexCoord((strip + 0.2) / TEXELS, (strip + 0.8) / TEXELS, top, bottom)
    local light = math.max(DARKEST, 1 / (1 + distance * FOG)) * (flank and FLANK or 1)
    column:SetVertexColor(light, light, light)
  end

  self:things(aheadX, aheadY, tall)

  local buff = run.buff
  local held = (buff and buff.holds or run.spec.holds) + (run.swung > 0 and 1 or 0)
  self.weapon:SetTexCoord((held * TEXELS + 0.5) / WEAPON_SHEET, ((held + 1) * TEXELS - 0.5) / WEAPON_SHEET, 0, 1)
  self.weapon:SetAlpha(buff and buff.hidden and 0.45 or 1)
  local veil = buff and buff.veil
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

--- Which picture of a kobold to show, and in what colour
--- @param mob WarcraftsteinMob
--- @return number picture, number[]? tint
local function looks(mob)
  if mob.dead then
    return FALLEN, nil
  end
  local tint = (mob.hurt > 0 and HURT_TINT) or (mob.frozen > 0 and FROZEN_TINT) or nil
  if mob.struck > 0 then
    return STRIKING, tint
  end
  return mob.awake and math.floor(mob.walked / STRIDE) % 2 or STANDING, tint
end

--- Draws everything that stands in the maze over the walls, wherever no wall is in front of it
--- @param aheadX number The way the player looks
--- @param aheadY number
--- @param tall number How tall a wall one step away is
function View:things(aheadX, aheadY, tall)
  local run, pose, seen, depths, lit = self.run, self.pose, self.seen, self.depths, self.lit
  local seenWidth, seenHeight, count, slice = self.seenWidth, self.seenHeight, self.count, self.slice
  local stamp = self.stamp + 1
  self.stamp = stamp

  -- The ones in front of the player and not off to either side of what is seen: a picture is
  -- as wide as a square of the maze, half of that to either side of where the thing stands
  local visible = 0
  --- @param thing WarcraftsteinThing
  --- @param picture number
  --- @param tint number[]?
  --- @param glows boolean?
  local function sight(thing, picture, tint, glows)
    local byX, byY = thing.x - pose.x, thing.y - pose.y
    local depth = byX * aheadX + byY * aheadY
    if depth > NEAREST then
      local off = (byY * aheadX - byX * aheadY) / (depth * REACH)
      if math.abs(off) < 1 + 0.5 / (depth * REACH) then
        visible = visible + 1
        seen[visible], thing.depth, thing.off = thing, depth, off
        thing.picture, thing.tint, thing.glows = picture, tint, glows
      end
    end
  end
  for _, potion in ipairs(run.loot) do
    sight(potion, POTIONS[potion.kind])
  end
  for _, mob in ipairs(run.mobs) do
    sight(mob, looks(mob))
  end
  if run.totem then
    sight(run.totem, TOTEM)
  end
  for _, bolt in ipairs(run.bolts) do
    sight(bolt, BOLT, bolt.attack.tint, true)
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
    local light = thing.glows and 1 or math.max(DARKEST, 1 / (1 + thing.depth * FOG))
    local tint = thing.tint
    local red, green, blue = light * (tint and tint[1] or 1), light * (tint and tint[2] or 1), light * (tint and tint[3] or 1)

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
        local texel = thing.picture * TEXELS + math.floor(across * TEXELS)
        strip:SetTexCoord((texel + 0.2) / SPRITE_SHEET, (texel + 0.8) / SPRITE_SHEET, top, bottom)
        strip:SetVertexColor(red, green, blue)
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

--- Whether going somewhere would be walking into a kobold that is up, or into the player
--- @param run WarcraftsteinRun
--- @param who WarcraftsteinMob? The kobold that is going, nil for the player
--- @param x number Where it is
--- @param y number
--- @param toX number Where to
--- @param toY number
--- @return boolean
local function crowded(run, who, x, y, toX, toY)
  local function near(otherX, otherY)
    local now = (toX - otherX) ^ 2 + (toY - otherY) ^ 2
    -- Getting away from each other is always allowed, or two that met would never part
    return now < APART * APART and now < (x - otherX) ^ 2 + (y - otherY) ^ 2
  end
  for _, mob in ipairs(run.mobs) do
    if mob ~= who and not mob.dead and near(mob.x, mob.y) then
      return true
    end
  end
  return who ~= nil and near(run.pose.x, run.pose.y)
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
  if ahead == 0 and aside == 0 and turn == 0 then
    return false, false
  end

  pose.facing = (pose.facing + turn * TURN * elapsed) % (math.pi * 2)
  local aheadX, aheadY = math.cos(pose.facing), math.sin(pose.facing)
  local far = WALK * (run.spec.speed or 1) * (run.buff and run.buff.speed or 1) * elapsed
  -- Nobody backs away from a kobold as quickly as it comes
  local byX = (aheadX * ahead * (ahead < 0 and BACKWARDS or 1) - aheadY * aside) * far
  local byY = (aheadY * ahead * (ahead < 0 and BACKWARDS or 1) + aheadX * aside) * far

  --- @type WarcraftsteinState
  local state = self.view.state
  -- Across and down each on their own, so that walking into a wall at an angle slides along it
  local hitX, hitY = blocked(state, pose.x + byX, pose.y), nil
  if not hitX and not crowded(run, nil, pose.x, pose.y, pose.x + byX, pose.y) then
    pose.x = pose.x + byX
  end
  hitY = blocked(state, pose.x, pose.y + byY)
  if not hitY and not crowded(run, nil, pose.x, pose.y, pose.x, pose.y + byY) then
    pose.y = pose.y + byY
  end
  return true, hitX == PORTAL or hitY == PORTAL
end

--- How far the walk to the player is from every square of the maze, which is what a kobold
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

--- Wakes the kobolds near one that just woke, and tells them where the player is
--- @param mob WarcraftsteinMob
function View:rouse(mob)
  local pose = self.pose
  for _, other in ipairs(self.run.mobs) do
    if not other.awake and not other.dead and (other.x - mob.x) ^ 2 + (other.y - mob.y) ^ 2 <= KOBOLD.calls ^ 2 then
      other.awake, other.lost, other.toX, other.toY = true, 0, pose.x, pose.y
    end
  end
end

--- Takes health off a kobold
--- @param mob WarcraftsteinMob
--- @param amount number
--- @param attack WarcraftsteinAttack? What with, if it was the player's own blow
function View:wound(mob, amount, attack)
  local run, pose = self.run, self.pose
  if mob.dead then
    return
  end
  mob.health, mob.hurt = mob.health - amount, KOBOLD.hurt
  if attack then
    if attack.drains then
      run.health = math.min(run.spec.health, run.health + amount * attack.drains)
    end
    if run.spec.gains then
      run.power = math.min(POWER, run.power + run.spec.gains.dealt)
    end
  end
  -- Whoever is hit knows where from, and says so
  local slept = not mob.awake
  mob.awake, mob.lost, mob.toX, mob.toY = true, 0, pose.x, pose.y
  if mob.health <= 0 then
    mob.dead, mob.awake = true, false
  end
  if slept then
    self:rouse(mob)
  end
end

--- The kobold right in front of the player, if one is near enough and nothing is in the way
--- @param reach number
--- @param wide number How far to either side of straight ahead it may stand
--- @return WarcraftsteinMob?, number? depth How far ahead it is
function View:target(reach, wide)
  local pose = self.pose
  local aheadX, aheadY = math.cos(pose.facing), math.sin(pose.facing)
  local nearest, found = reach, nil
  for _, mob in ipairs(self.run.mobs) do
    local byX, byY = mob.x - pose.x, mob.y - pose.y
    local depth = byX * aheadX + byY * aheadY
    if not mob.dead and depth > 0 and depth <= nearest and math.abs(byY * aheadX - byX * aheadY) <= wide then
      if sees(self.view.state, pose.x, pose.y, mob.x, mob.y) then
        nearest, found = depth, mob
      end
    end
  end
  return found, found and nearest
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
  -- Whoever strikes is seen
  local unseen = buff ~= nil and buff.hidden == true
  if buff and buff.breaks then
    run.buff, run.buffLeft = nil, 0
  end

  if attack.kind == "bolt" then
    local aheadX, aheadY = math.cos(pose.facing), math.sin(pose.facing)
    run.bolts[#run.bolts + 1] = { x = pose.x, y = pose.y, byX = aheadX, byY = aheadY, attack = attack }
    return true
  end
  local mob, depth = self:target(attack.reach, attack.wide)
  if mob then
    local amount = attack.hits
    if attack.close and depth < attack.close then
      amount = amount / 2
    end
    if attack.ambush and (unseen or not mob.awake) then
      amount = amount * attack.ambush
    end
    self:wound(mob, amount, attack)
  end
  return true
end

--- The player does the thing their class can do, if it is ready and they have the power for it
--- @return boolean done
function View:cast()
  local run, pose = self.run, self.pose
  local spec, ability = run.spec, run.spec.ability
  --- @type WarcraftsteinState
  local state = self.view.state
  if run.ready > 0 or run.power < (ability.cost or 0) then
    return false
  end

  local kind = ability.kind
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
        self:wound(mob, ability.hits, spec.attack)
        mob.frozen = math.max(mob.frozen, ability.freezes or 0)
      end
    end
  elseif kind == "buff" then
    run.buff, run.buffLeft = ability, ability.lasts
  elseif kind == "heal" then
    if run.health >= spec.health then
      return false
    end
    run.health = math.min(spec.health, run.health + ability.heals)
  elseif kind == "tap" then
    if run.health <= ability.takes or run.power >= POWER then
      return false
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
  return true
end

--- Moves the bolts that are on their way, until they meet a kobold or a wall
--- @param elapsed number
function View:fly(elapsed)
  local run = self.run
  --- @type WarcraftsteinState
  local state = self.view.state
  for index = #run.bolts, 1, -1 do
    local bolt = run.bolts[index]
    local left, spent = BOLT_SPEED * elapsed, false
    while left > 0 and not spent do
      local far = math.min(left, BOLT_STEP)
      left = left - far
      bolt.x, bolt.y = bolt.x + bolt.byX * far, bolt.y + bolt.byY * far
      spent = kindAt(state, bolt.x, bolt.y) ~= OPEN
      for _, mob in ipairs(run.mobs) do
        if not spent and not mob.dead and (mob.x - bolt.x) ^ 2 + (mob.y - bolt.y) ^ 2 < BOLT_GIRTH ^ 2 then
          spent = true
          self:wound(mob, bolt.attack.hits, bolt.attack)
          if bolt.attack.chain then
            self:chain(mob, bolt.attack)
          end
        end
      end
    end
    if spent then
      table.remove(run.bolts, index)
    end
  end
end

--- A bolt goes on from the kobold it hit to the nearest other one that kobold can see
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
    self:wound(found, attack.hits * attack.chain, attack)
  end
end

--- The totem that stands burns the nearest kobold it can see, every so often, until it is spent
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

--- What a kobold does in the time that passed
--- @param mob WarcraftsteinMob
--- @param elapsed number
--- @return boolean stirred There is something new to see of it
--- @return boolean struck Its blow landed on the player
function View:stir(mob, elapsed)
  local run, pose = self.run, self.pose
  --- @type WarcraftsteinState
  local state = self.view.state
  local stirred = mob.struck > 0 or mob.hurt > 0 or mob.frozen > 0
  mob.struck, mob.hurt = math.max(0, mob.struck - elapsed), math.max(0, mob.hurt - elapsed)
  if mob.dead then
    return stirred, false
  end
  if mob.frozen > 0 then
    mob.frozen, mob.swing = math.max(0, mob.frozen - elapsed), nil
    return true, false
  end

  local hidden = run.buff ~= nil and run.buff.hidden == true
  local away = math.sqrt((pose.x - mob.x) ^ 2 + (pose.y - mob.y) ^ 2)
  local seen = not hidden and (mob.awake or away <= KOBOLD.wakes) and sees(state, mob.x, mob.y, pose.x, pose.y)
  if seen then
    local slept = not mob.awake
    mob.awake, mob.lost, mob.toX, mob.toY = true, 0, pose.x, pose.y
    if slept then
      self:rouse(mob)
    end
  end
  if not mob.awake then
    return stirred, false
  end

  if seen and away <= KOBOLD.reach then
    mob.swing = (mob.swing or KOBOLD.windup) - elapsed
    if mob.swing > 0 then
      return stirred, false
    end
    mob.swing, mob.struck = KOBOLD.every, KOBOLD.shown
    return true, true
  end
  mob.swing = nil
  mob.lost = mob.lost + (seen and 0 or elapsed)
  if mob.lost > KOBOLD.looks then
    mob.awake = false
    return true, false
  end

  -- Straight for the player while they are in sight. Otherwise to the square next door that
  -- is nearer to them, or only to where they were seen last if they are nowhere to be seen
  local toX, toY = mob.toX, mob.toY
  if not seen and not hidden then
    local side, trail = state.side, self:trail()
    local square = math.floor(mob.y) * side + math.floor(mob.x) + 1
    local nearest = trail[square] or math.huge
    for _, next in ipairs({ square - 1, square + 1, square - side, square + side }) do
      if trail[next] and trail[next] < nearest then
        nearest = trail[next]
        toX, toY = (next - 1) % side + 0.5, math.floor((next - 1) / side) + 0.5
      end
    end
  end
  local byX, byY = toX - mob.x, toY - mob.y
  local left = math.sqrt(byX * byX + byY * byY)
  local far = math.min(left, KOBOLD.speed * elapsed)
  local x, y = mob.x, mob.y
  if left > THERE then
    byX, byY = byX / left * far, byY / left * far
    if not blocked(state, x + byX, y) and not crowded(run, mob, x, y, x + byX, y) then
      mob.x = x + byX
    end
    if not blocked(state, mob.x, y + byY) and not crowded(run, mob, mob.x, y, mob.x, y + byY) then
      mob.y = y + byY
    end
  end
  if mob.x == x and mob.y == y then
    -- Where the player was last seen and nobody there: nothing to stay up for
    if hidden then
      mob.awake = false
    end
    return stirred, false
  end
  mob.walked = mob.walked + far
  return true, false
end

--- Everything that happens in the maze in the time that passed
--- @param elapsed number
function View:live(elapsed)
  local view, run, ticker = self.view, self.run, self.ticker
  if not view or not run or not view.canMove then
    return
  end
  -- A key that was let go of somewhere else is never heard of again, and nothing happens to
  -- a player who isn't there to do anything about it
  if not ticker:IsMouseOver() then
    self.down = {}
    return
  end
  elapsed = math.min(elapsed, LONGEST_FRAME)
  local spec, health = run.spec, run.health

  local moved, out = self:walk(elapsed)
  local stirred = moved or run.swung > 0 or run.buff ~= nil or run.totem ~= nil or #run.bolts > 0
  run.cooldown, run.ready = math.max(0, run.cooldown - elapsed), math.max(0, run.ready - elapsed)
  run.swung, run.buffLeft = math.max(0, run.swung - elapsed), math.max(0, run.buffLeft - elapsed)
  if run.buffLeft == 0 then
    run.buff = nil
  end
  run.power = math.min(POWER, run.power + (spec.regen or 0) * elapsed)
  if self.down[CAST] and self:cast() then
    stirred = true
  end
  if self.down[STRIKE] and run.cooldown == 0 and self:strike() then
    stirred = true
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
      run[potion.kind] = math.min(most, run[potion.kind] + POTION[potion.kind])
      table.remove(run.loot, index)
      stirred = true
    end
  end

  local before = run.health
  for _, mob in ipairs(run.mobs) do
    local stirs, struck = self:stir(mob, elapsed)
    stirred = stirred or stirs
    if struck and not (run.buff and run.buff.immune) then
      run.health = math.max(0, run.health - KOBOLD.hits * (spec.armor or 1))
      if spec.gains then
        run.power = math.min(POWER, run.power + spec.gains.taken)
      end
    end
  end

  if stirred then
    self:render()
  end
  self:gauge()
  if run.health < before then
    self.effects:Flash({ 0.8, 0, 0, 0.35 }, 0.3)
  elseif run.health > health then
    self.effects:Flash({ 0.2, 0.9, 0.3, 0.2 }, 0.3)
  end
  if out or run.health == 0 then
    self.down = {}
    view.submit(out and EXIT or DEAD)
  end
end

--- Shows how the player is: their health, their power, and whether they can do their thing
function View:gauge()
  local run, ability = self.run, self.ability
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
--- @return WarcraftsteinRun
local function newRun(state)
  local spec = CLASSES[state.class]
  --- @type WarcraftsteinRun
  local run = {
    class = state.class,
    spec = spec,
    pose = { x = state.start.x, y = state.start.y, facing = state.start.facing },
    health = spec.health,
    power = spec.gains and 0 or POWER,
    mobs = {},
    loot = {},
    bolts = {},
    buffLeft = 0,
    cooldown = 0,
    ready = 0,
    swung = 0,
  }
  for index, den in ipairs(state.mobs) do
    run.mobs[index] = { x = den.x, y = den.y, health = KOBOLD.health, awake = false, dead = false, lost = 0, struck = 0, hurt = 0, frozen = 0, walked = 0 }
  end
  for index, potion in ipairs(state.loot) do
    run.loot[index] = { x = potion.x, y = potion.y, kind = potion.kind }
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
    if SetPortraitTexture then
      SetPortraitTexture(self.portrait.face, "player")
    end
  end
  local run = self.runs[id]
  if not run and state.class then
    run = newRun(state)
    self.runs[id] = run
  end
  if another or run ~= self.run then
    self.run, self.pose = run, run and run.pose
    if run then
      self.power:Tint(POWER_COLORS[run.spec.power])
      self.ability.icon:SetTexture(ICONS .. run.spec.ability.icon)
      self.ability.waits = nil
      self:gauge()
      self:render()
    end
  end
  for _, widget in ipairs({ self.health, self.power, self.ability }) do
    widget:SetShown(run ~= nil)
  end

  -- Nobody yet: the maze waits behind the question who
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
  version = 1,
  seats = 1,
  options = {
    {
      id = "size",
      name = L["warcraftstein_option_size"],
      description = L["warcraftstein_option_size_tip"],
      choices = SIZES,
      default = USUAL_SIZE,
      label = function(value)
        return L["warcraftstein_option_size_label"]:format(value, value)
      end,
    },
  },
  clock = "open",
  newState = newState,
  turn = function()
    return 1
  end,
  validate = validate,
  apply = apply,
  result = result,
  progress = function(state)
    return L["warcraftstein_progress"]:format(state.size, state.size)
  end,
  record = function(state, seconds)
    -- Only getting out has a time worth keeping
    if state.found then
      return { { key = TIME_KEY .. state.size, value = seconds, lower = true } }
    end
    return nil
  end,
  createView = createView,
})
