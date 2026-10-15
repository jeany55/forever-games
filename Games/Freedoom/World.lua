--------------------------
--  Freedoom: the world
--------------------------
-- One of the parts of Freedoom (Games/Freedoom.lua): what goes on in a map while it is played.
-- Doors, lifts and switches and what the lines of a map set off; the monsters, barrels and what
-- flies and bursts, living 35 tics a second; and the player's weapons. The view (in
-- Games/Freedoom.lua) runs it a tic at a time and draws it.

--- @type nil, ForeverGamesPrivate
local _, private = ...
-- What the parts of Freedoom share, and the tests are let see
local Freedoom = private.Freedoom or {}
private.Freedoom = Freedoom
local WEAPONS, newInventory, pickUp, unlocks = Freedoom.WEAPONS, Freedoom.newInventory, Freedoom.pickUp, Freedoom.unlocks

-----------------------------
-- Doors, lifts and switches
-----------------------------
-- What the lines of a Doom map do (SPECIALS), by the number the map gives them, which is Doom's:
-- doors that open and shut by themselves or stay open or shut, floors that go down or up to the
-- height of one beside them, lifts that go down and come back up, stairs that build themselves,
-- teleports, lights and the way out. A line is set off by being used ("use", working the door it
-- is on; "switch", flipping its switch), walked over ("walk") or shot ("shoot"), once or again and
-- again, and what it sets going is the sector behind it for a door worked by hand and every
-- sector with the line's tag for everything else. A monster sets off a few of them too, by
-- walking over them (MONSTER_LINES). Doom's speeds and waits are its own, 35 tics a second.

-- Doom's player: as wide and tall as this
local RADIUS, HEIGHT = 16, 56
-- Units a second: doors, fast doors, floors, fast floors, lifts, fast lifts, a floor that rises
-- slowly and changes as it does, stairs and fast stairs
local DOOR, BLAZE, FLOOR, TURBO, LIFT, FAST_LIFT, PLATFORM, STAIRS, FAST_STAIRS = 70, 280, 35, 140, 140, 280, 17.5, 8.75, 140
-- Seconds a door stays open, a lift down, a switch flipped, and a door that shuts for a while shut
local DOOR_WAIT, LIFT_WAIT, SWITCH_BACK, SHUT_WAIT = 150 / 35, 105 / 35, 1, 30
-- How far a door stops under the ceiling beside it
local DOOR_GAP = 4

--- @class FreedoomThing: SectorMapThing
--- @field kind table What it is, from the map: { sprite, frames, tics, bright, pickup, ... }
--- @field type integer The number the map gives its kind
--- @field dropped boolean? A monster dropped it

--- @class FreedoomRun
--- @field map SectorMap The map as it is in this game: doors that open, lifts that go down
--- @field player FreedoomThing The player, a thing of the map that isn't drawn
--- @field angle number
--- @field inventory FreedoomInventory
--- @field animated FreedoomThing[] Things that go through frames of their own, on the map's clock
--- @field actors FreedoomActor[] Things that live: monsters, barrels, what flies and bursts
--- @field teleports table[] Where teleports go: { x, y, angle, sector }
--- @field tic integer Tics the world has had
--- @field leaving number? Seconds since the player got to an exit
--- @field dead integer? The tic the player died on
--- @field level string Which map, "run" or "e1m1" to "e1m9"
--- @field key string What its best time is kept under: the map and the skill (see Games/Freedoom.lua)
--- @field halfDamage boolean? The player takes half of every blow: the easiest skill, as in Doom

-- Made later, with what lives: the flash of a teleport
local teleportFlash

--- Lets a sound be heard: one of Doom's, by its name (or one of several, as it happens), from
--- where something is, or the player's own if from nowhere. What hears it is the view's (run.sound)
local function sound(run, name, origin)
  if name and run.sound then
    if type(name) == "table" then
      name = name[math.random(#name)]
    end
    run.sound(name, origin)
  end
end

--- Where a sector's sounds come from: the middle of it
local function middle(sector)
  if not sector.middle then
    local left, right, bottom, top = math.huge, -math.huge, math.huge, -math.huge
    for _, line in ipairs(sector.lines) do
      left, right = math.min(left, line.left), math.max(right, line.right)
      bottom, top = math.min(bottom, line.bottom), math.max(top, line.top)
    end
    sector.middle = { x = (left + right) / 2, y = (bottom + top) / 2 }
  end
  return sector.middle
end

--- Whether anybody is in or at the edge of a sector, for a door that would shut on them: the
--- player, or a monster
--- @param run FreedoomRun
--- @param sector SectorMapSector
local function touches(run, sector)
  local map = run.map
  local lines = {}
  for thing in pairs(sector.things) do
    if thing.solid and thing.shootable then
      return true
    end
  end
  for _, thing in ipairs({ run.player, unpack(run.actors) }) do
    if thing.solid and thing.shootable and thing.sector then
      map:Check(thing.x, thing.y, thing.radius, lines, thing)
      for _, line in ipairs(lines) do
        if line.front.sector == sector or (line.back and line.back.sector == sector) then
          return true
        end
      end
    end
  end
  return false
end

--- A door: "raise" opens it and shuts it again after a while (and goes back up if anybody is
--- under it), "open" leaves it open, "close" shuts it, "closeWhile" shuts it for a while
--- @param run FreedoomRun
--- @param sector SectorMapSector
--- @param how string
--- @param speed number
local function door(run, sector, how, speed)
  local map = run.map
  local top = (map:Neighbouring(sector, "ceiling") or sector.ceiling) - DOOR_GAP
  local fast = speed > DOOR
  local function open(after)
    sound(run, fast and "bdopn" or "doropn", middle(sector))
    map:Move(sector, "ceiling", top, { speed = speed, onArrive = after })
  end
  local function close(after)
    sound(run, fast and "bdcls" or "dorcls", middle(sector))
    map:Move(sector, "ceiling", sector.floor, {
      speed = speed,
      canMove = function(_, height)
        return height - sector.floor >= HEIGHT or not touches(run, sector)
      end,
      onBlocked = function()
        door(run, sector, how == "close" and "open" or how, speed)
      end,
      onArrive = after,
    })
  end
  if how == "raise" then
    open(function()
      map:Move(sector, "ceiling", top, { speed = speed, delay = DOOR_WAIT, onArrive = function()
        close()
      end })
    end)
  elseif how == "open" then
    open()
  elseif how == "close" then
    close()
  elseif how == "closeWhile" then
    close(function()
      map:Move(sector, "ceiling", sector.floor, { speed = speed, delay = SHUT_WAIT, onArrive = function()
        open()
      end })
    end)
  end
end

--- The height a floor goes to: the lowest or highest floor beside it (that, plus 8), the next
--- floor up from it, the lowest ceiling beside it, or so many units up
local function floorTarget(map, sector, to)
  local floor = sector.floor
  if to == "lowest" then
    return math.min(floor, map:Neighbouring(sector, "floor") or floor)
  elseif to == "highest" or to == "highest8" then
    local highest = map:Neighbouring(sector, "floor", true) or floor
    return to == "highest8" and highest ~= floor and highest + 8 or highest
  elseif to == "next" then
    local next
    for _, other in ipairs(map:Neighbours(sector)) do
      if other.floor > floor and (not next or other.floor < next) then
        next = other.floor
      end
    end
    return next or floor
  elseif to == "ceiling" then
    return math.min(sector.ceiling, map:Neighbouring(sector, "ceiling") or sector.ceiling)
  end
  return floor + to
end

--- A floor going somewhere, once. With change it takes the floor of the sector on the line's
--- side, and whatever that sector does, as Doom's rising platforms do
local function floor(run, sector, to, speed, line, change)
  local map = run.map
  if map:Moving(sector, "floor") then
    return
  end
  if change and line then
    sector.floorPicture, sector.special = line.front.sector.floorPicture, 0
    map:Changed()
  end
  sound(run, "stnmov", middle(sector))
  map:Move(sector, "floor", floorTarget(map, sector, to), { speed = speed, onArrive = function()
    sound(run, "pstop", middle(sector))
  end })
end

--- A lift: down to the lowest floor beside it, a while there, and back up
local function lift(run, sector, speed)
  local map = run.map
  if map:Moving(sector, "floor") then
    return
  end
  local was = sector.floor
  sound(run, "pstart", middle(sector))
  map:Move(sector, "floor", floorTarget(map, sector, "lowest"), {
    speed = speed,
    onArrive = function()
      sound(run, "pstop", middle(sector))
      map:Move(sector, "floor", was, { speed = speed, delay = LIFT_WAIT, onArrive = function()
        sound(run, "pstop", middle(sector))
      end })
    end,
  })
end

--- A lift that goes up and down for ever, between the lowest and the highest floor beside it,
--- until it is stopped
local function perpetual(run, sector, start)
  local map = run.map
  sector.perpetual = start
  if not start then
    return
  end
  local low, high = floorTarget(map, sector, "lowest"), math.max(sector.floor, floorTarget(map, sector, "highest"))
  local function go(to)
    if not sector.perpetual then
      return
    end
    map:Move(sector, "floor", to, { speed = LIFT, delay = map:Moving(sector, "floor") and 0 or LIFT_WAIT, onArrive = function()
      go(to == low and high or low)
    end })
  end
  go(sector.floor > low and low or high)
end

--- Stairs: the sector rises a step, then the one beyond it with the same floor two, and on
local function stairs(run, sector, step, speed)
  local map = run.map
  if map:Moving(sector, "floor") then
    return
  end
  local height, picture, done = sector.floor, sector.floorPicture, { [sector] = true }
  local at = sector
  repeat
    height = height + step
    map:Move(at, "floor", height, { speed = speed })
    local beyond
    for _, line in ipairs(at.lines) do
      local back = line.back and line.back.sector
      if line.front.sector == at and back and back.floorPicture == picture and not done[back] then
        beyond = back
        break
      end
    end
    at = beyond
    if at then
      done[at] = true
    end
  until not at
end

--- A sector's light: a number, or the brightest or dimmest beside it
local function light(run, sector, to)
  local map = run.map
  if to == "brightest" or to == "dimmest" then
    local found
    for _, other in ipairs(map:Neighbours(sector)) do
      if not found or (to == "brightest" and other.light > found) or (to == "dimmest" and other.light < found) then
        found = other.light
      end
    end
    to = found or sector.light
  end
  sector.light = to
  map:Changed()
end

--- Somebody steps into a teleport and out at its other end, a flash where they were and where
--- they are: the first teleport landing in a sector with the line's tag
local function teleport(run, line, actor)
  for _, landing in ipairs(run.teleports) do
    if landing.sector.tag == line.tag then
      local map = run.map
      teleportFlash(run, actor.x, actor.y)
      map:MoveThing(actor, landing.x, landing.y)
      if actor.z then
        actor.z = landing.sector.floor
      end
      if actor == run.player then
        run.angle = landing.angle
      else
        actor.angle = landing.angle
      end
      teleportFlash(run, landing.x + math.cos(landing.angle) * 20, landing.y + math.sin(landing.angle) * 20)
      return true
    end
  end
  return false
end

--- Shows a switch the other way: SW1 pictures for SW2 and back, on whichever part of the wall it is
local function flip(side)
  for _, part in ipairs({ "upper", "middle", "lower" }) do
    local name = side[part]
    local prefix = name:sub(1, 3)
    if prefix == "SW1" or prefix == "SW2" then
      side[part] = (prefix == "SW1" and "SW2" or "SW1") .. name:sub(4)
    end
  end
end

-- Kinds of special, each what it does to a sector: a door, a floor, a lift, stairs, a light
local function doing(what, ...)
  local how = { ... }
  return function(run, sector, line)
    if what == door then
      door(run, sector, how[1], how[2])
    elseif what == floor then
      floor(run, sector, how[1], how[2], line, how[3])
    elseif what == lift then
      lift(run, sector, how[1])
    elseif what == perpetual then
      perpetual(run, sector, how[1])
    elseif what == stairs then
      stairs(run, sector, how[1], how[2])
    elseif what == light then
      light(run, sector, how[1])
    end
  end
end

-- Each special: how it is set off, whether it can be again, what it does, and to the sector
-- behind the line ("hand") rather than the tagged ones. Or "teleport", or "exit"
local SPECIALS = {}
local function special(numbers, how, again, effect, hand)
  for _, number in ipairs(numbers) do
    SPECIALS[number] = { how = how, again = again, effect = effect, hand = hand }
  end
end
-- Doors worked by hand, keyed or not, fast or not, staying open or not
special({ 1, 26, 27, 28 }, "use", true, doing(door, "raise", DOOR), true)
special({ 31, 32, 33, 34 }, "use", false, doing(door, "open", DOOR), true)
special({ 117 }, "use", true, doing(door, "raise", BLAZE), true)
special({ 118 }, "use", false, doing(door, "open", BLAZE), true)
-- Doors worked from somewhere else
special({ 4 }, "walk", false, doing(door, "raise", DOOR))
special({ 90 }, "walk", true, doing(door, "raise", DOOR))
special({ 2 }, "walk", false, doing(door, "open", DOOR))
special({ 86 }, "walk", true, doing(door, "open", DOOR))
special({ 3 }, "walk", false, doing(door, "close", DOOR))
special({ 75 }, "walk", true, doing(door, "close", DOOR))
special({ 16 }, "walk", false, doing(door, "closeWhile", DOOR))
special({ 76 }, "walk", true, doing(door, "closeWhile", DOOR))
special({ 108 }, "walk", false, doing(door, "raise", BLAZE))
special({ 105 }, "walk", true, doing(door, "raise", BLAZE))
special({ 109 }, "walk", false, doing(door, "open", BLAZE))
special({ 106 }, "walk", true, doing(door, "open", BLAZE))
special({ 110 }, "walk", false, doing(door, "close", BLAZE))
special({ 107 }, "walk", true, doing(door, "close", BLAZE))
special({ 29 }, "switch", false, doing(door, "raise", DOOR))
special({ 63 }, "switch", true, doing(door, "raise", DOOR))
special({ 103 }, "switch", false, doing(door, "open", DOOR))
special({ 61 }, "switch", true, doing(door, "open", DOOR))
special({ 50 }, "switch", false, doing(door, "close", DOOR))
special({ 42 }, "switch", true, doing(door, "close", DOOR))
special({ 111 }, "switch", false, doing(door, "raise", BLAZE))
special({ 114 }, "switch", true, doing(door, "raise", BLAZE))
special({ 112, 133, 135, 137 }, "switch", false, doing(door, "open", BLAZE))
special({ 115, 99, 134, 136 }, "switch", true, doing(door, "open", BLAZE))
special({ 113 }, "switch", false, doing(door, "close", BLAZE))
special({ 116 }, "switch", true, doing(door, "close", BLAZE))
special({ 46 }, "shoot", true, doing(door, "open", DOOR))
-- Floors
special({ 38 }, "walk", false, doing(floor, "lowest", FLOOR))
special({ 82 }, "walk", true, doing(floor, "lowest", FLOOR))
special({ 23 }, "switch", false, doing(floor, "lowest", FLOOR))
special({ 60 }, "switch", true, doing(floor, "lowest", FLOOR))
special({ 19 }, "walk", false, doing(floor, "highest", FLOOR))
special({ 83 }, "walk", true, doing(floor, "highest", FLOOR))
special({ 102 }, "switch", false, doing(floor, "highest", FLOOR))
special({ 45 }, "switch", true, doing(floor, "highest", FLOOR))
special({ 36 }, "walk", false, doing(floor, "highest8", TURBO))
special({ 98 }, "walk", true, doing(floor, "highest8", TURBO))
special({ 71 }, "switch", false, doing(floor, "highest8", TURBO))
special({ 70 }, "switch", true, doing(floor, "highest8", TURBO))
special({ 5 }, "walk", false, doing(floor, "ceiling", FLOOR))
special({ 91 }, "walk", true, doing(floor, "ceiling", FLOOR))
special({ 101 }, "switch", false, doing(floor, "ceiling", FLOOR))
special({ 64 }, "switch", true, doing(floor, "ceiling", FLOOR))
special({ 24 }, "shoot", false, doing(floor, "ceiling", FLOOR))
special({ 119 }, "walk", false, doing(floor, "next", FLOOR))
special({ 128 }, "walk", true, doing(floor, "next", FLOOR))
special({ 18 }, "switch", false, doing(floor, "next", FLOOR))
special({ 69 }, "switch", true, doing(floor, "next", FLOOR))
special({ 130 }, "walk", false, doing(floor, "next", TURBO))
special({ 129 }, "walk", true, doing(floor, "next", TURBO))
special({ 131 }, "switch", false, doing(floor, "next", TURBO))
special({ 132 }, "switch", true, doing(floor, "next", TURBO))
special({ 58 }, "walk", false, doing(floor, 24, FLOOR))
special({ 92 }, "walk", true, doing(floor, 24, FLOOR))
special({ 22 }, "walk", false, doing(floor, "next", PLATFORM, true))
special({ 95 }, "walk", true, doing(floor, "next", PLATFORM, true))
special({ 20 }, "switch", false, doing(floor, "next", PLATFORM, true))
special({ 68 }, "switch", true, doing(floor, "next", PLATFORM, true))
special({ 47 }, "shoot", false, doing(floor, "next", PLATFORM, true))
special({ 59 }, "walk", false, doing(floor, 24, PLATFORM, true))
special({ 93 }, "walk", true, doing(floor, 24, PLATFORM, true))
special({ 15 }, "switch", false, doing(floor, 24, PLATFORM, true))
special({ 66 }, "switch", true, doing(floor, 24, PLATFORM, true))
-- Lifts
special({ 10 }, "walk", false, doing(lift, LIFT))
special({ 88 }, "walk", true, doing(lift, LIFT))
special({ 21 }, "switch", false, doing(lift, LIFT))
special({ 62 }, "switch", true, doing(lift, LIFT))
special({ 121 }, "walk", false, doing(lift, FAST_LIFT))
special({ 120 }, "walk", true, doing(lift, FAST_LIFT))
special({ 122 }, "switch", false, doing(lift, FAST_LIFT))
special({ 123 }, "switch", true, doing(lift, FAST_LIFT))
special({ 53 }, "walk", false, doing(perpetual, true))
special({ 87 }, "walk", true, doing(perpetual, true))
special({ 54 }, "walk", false, doing(perpetual, false))
special({ 89 }, "walk", true, doing(perpetual, false))
-- Stairs
special({ 8 }, "walk", false, doing(stairs, 8, STAIRS))
special({ 7 }, "switch", false, doing(stairs, 8, STAIRS))
special({ 100 }, "walk", false, doing(stairs, 16, FAST_STAIRS))
special({ 127 }, "switch", false, doing(stairs, 16, FAST_STAIRS))
-- Lights
special({ 35 }, "walk", false, doing(light, 35))
special({ 79 }, "walk", true, doing(light, 35))
special({ 139 }, "switch", true, doing(light, 35))
special({ 13 }, "walk", false, doing(light, 255))
special({ 81 }, "walk", true, doing(light, 255))
special({ 138 }, "switch", true, doing(light, 255))
special({ 12 }, "walk", false, doing(light, "brightest"))
special({ 80 }, "walk", true, doing(light, "brightest"))
special({ 104 }, "walk", false, doing(light, "dimmest"))
-- Teleports, for anybody or only for monsters, and the ways out
special({ 39, 125 }, "walk", false, "teleport")
special({ 97, 126 }, "walk", true, "teleport")
special({ 11, 51 }, "switch", false, "exit")
special({ 52, 124 }, "walk", false, "exit")
-- What a monster sets off by walking over it, and what only a monster does
local MONSTER_LINES = { [4] = true, [10] = true, [88] = true, [39] = true, [97] = true, [125] = true, [126] = true }
local MONSTERS_ONLY = { [125] = true, [126] = true }

--- Sets off whatever a line does, if it is done that way, hasn't been done for good already and
--- whoever does it has the key for it. The player, unless a monster is said to
--- @param run FreedoomRun
--- @param line SectorMapLine
--- @param how "use"|"walk"|"shoot"
--- @param actor FreedoomThing? Who: a monster, or the player if left out
--- @param fromFront boolean? Walked over from the front of the line, which a teleport only works from
--- @return boolean done
--- @return string? colour The key it needed, that the player hasn't got
local function trigger(run, line, how, actor, fromFront)
  local special = SPECIALS[line.special]
  actor = actor or run.player
  local monster = actor ~= run.player
  if not special or (special.how == "switch" and "use" or special.how) ~= how then
    return false
  end
  if (monster and not MONSTER_LINES[line.special]) or (not monster and MONSTERS_ONLY[line.special]) then
    return false
  end
  if not monster then
    local open, colour = unlocks(run.inventory, line.special)
    if not open then
      return false, colour
    end
  end
  local effect = special.effect
  if effect == "teleport" then
    if not fromFront or not teleport(run, line, actor) then
      return false
    end
  elseif effect == "exit" then
    run.leaving = run.leaving or 0
  elseif special.hand then
    if not line.back then
      return false
    end
    effect(run, line.back.sector, line)
  else
    for _, sector in ipairs(run.map:Tagged(line.tag)) do
      effect(run, sector, line)
    end
  end
  if special.how == "switch" then
    sound(run, effect == "exit" and "swtchx" or "swtchn", { x = (line.x1 + line.x2) / 2, y = (line.y1 + line.y2) / 2 })
    flip(line.front)
    run.map:Changed()
    if special.again then
      run.map:After(SWITCH_BACK, function()
        flip(line.front)
        run.map:Changed()
      end)
    end
  end
  if not special.again then
    line.special = 0
  end
  return true
end

-----------------------------
-- What lives in the map
-----------------------------
-- Doom's monsters and barrels, and the fireballs, rockets, smoke and blood that come of them, each an
-- actor (Engine/Actors.lua) and a thing of the map, living 35 tics a second, with Doom's numbers
-- (its info.c) and its ways (p_enemy.c): a monster stands until it sees the player or hears a
-- shot from the rooms around it, then walks at them a few steps at a time in one of eight ways,
-- opening the doors in its way, and every so often attacks, the more often the nearer it is. A
-- monster that is hurt may flinch, and turns on whoever hurt it, even another monster. Everything
-- that is left to chance is, as in Doom, a number up to 255.

local Actors = private.Actors
local TWO_PI, EIGHTH = math.pi * 2, math.pi / 4
local MELEE_RANGE, MISSILE_RANGE = 64, 2048
-- A monster turns on whoever hurt it for this many of its steps before it may turn on another
local GRUDGE = 100
-- The ways a monster walks, east first and round anticlockwise, and none
local NO_DIRECTION = 8
local DIAGONAL = math.sqrt(0.5)
local DIRECTIONS = { { 1, 0 }, { DIAGONAL, DIAGONAL }, { 0, 1 }, { -DIAGONAL, DIAGONAL }, { -1, 0 }, { -DIAGONAL, -DIAGONAL }, { 0, -1 }, { DIAGONAL, -DIAGONAL } }
local EAST, NORTH, WEST, SOUTH = 0, 2, 4, 6
-- The way back, and the way between two
local function opposite(direction)
  return direction == NO_DIRECTION and NO_DIRECTION or (direction + 4) % 8
end
-- Shots go wide by up to this much for every point of chance either way: a monster's, and the player's when not aimed
local MONSTER_SPREAD, PLAYER_SPREAD = TWO_PI / 4096, TWO_PI / 16384
-- What a barrel or a rocket going up does to whatever is this near
local BLAST = 128
-- How far above the feet of whoever fires it a missile sets out, how tall any of them is, and how
-- far one may go either way in a tic before it goes half as far twice instead, so as not to go
-- past whatever is in its way (Doom's P_XYMovement)
local FLIGHT = { z = 32, height = 8, half = 15 }
-- How the player's missiles are aimed: as far ahead as they look for something in line, and how
-- far to either side they look again when there is nothing (Doom's 1 << 26 of its angles). And
-- the tracers of the BFG's ball when it bursts, aimed the same way: how many, spread over how
-- wide, and how many blows each deals whatever it finds
local AIM = { range = 1024, aside = TWO_PI / 64, tracers = 40, spread = math.pi / 2, blows = 15 }
-- A lost soul charges at this many units a tic, and rises or sinks this much a step to meet whoever it is after
local CHARGE_SPEED, CHARGE_DAMAGE, FLOAT_SPEED = 20, 3, 4
-- Doom's boss: when the last of them on the map it guards falls, the floors with this tag go down
local BOSS_MAP, BOSS_TAG = "e1m8", 666

local function chance()
  return math.random(0, 255)
end

--- Frames that each last as long and do the same, one after the other
local function walking(letters, tics, action)
  local steps = {}
  for index = 1, #letters do
    steps[index] = { letters:sub(index, index), tics, action }
  end
  steps.next = "chase"
  return steps
end

local STAND = { { "A", 10, "look" }, { "B", 10, "look" }, next = "stand" }
-- What a monster says: when it sees the player, now and then as it walks, when it is hurt and
-- when it dies, and as it goes for them up close
local DEMON_SOUNDS = { see = "sgtsit", active = "dmact", pain = "dmpain", death = "sgtdth", attack = "sgtatk" }
local DEMON = {
  stand = STAND,
  chase = walking("AABBCCDD", 2, "chase"),
  melee = { { "E", 8, "face" }, { "F", 8, "face" }, { "G", 8, "bite" }, next = "chase" },
  pain = { { "H", 2 }, { "H", 2, "pain" }, next = "chase" },
  die = { { "I", 8 }, { "J", 8, "scream" }, { "K", 4 }, { "L", 4, "fall" }, { "M", 4 }, { "N", -1 } },
}
local GIBBED = { { "M", 5 }, { "N", 5, "gib" }, { "O", 5, "fall" }, { "P", 5 }, { "Q", 5 }, { "R", 5 }, { "S", 5 }, { "T", 5 }, { "U", -1 } }

-- Monsters by the kind the map gives them: health, units a step, the chance of flinching when hurt,
-- what they drop when they die, and their states
local MONSTERS = {
  -- The former human with a pistol
  [3004] = {
    health = 20, speed = 8, pain = 200, drop = 2007,
    sounds = { see = { "posit1", "posit2", "posit3" }, active = "posact", pain = "popain", death = { "podth1", "podth2", "podth3" } },
    sequences = {
      stand = STAND,
      chase = walking("AABBCCDD", 4, "chase"),
      missile = { { "E", 10, "face" }, { "F", 8, "pistol", true }, { "E", 8 }, next = "chase" },
      pain = { { "G", 3 }, { "G", 3, "pain" }, next = "chase" },
      die = { { "H", 5 }, { "I", 5, "scream" }, { "J", 5, "fall" }, { "K", 5 }, { "L", -1 } },
      gib = GIBBED,
    },
  },
  -- With a shotgun
  [9] = {
    health = 30, speed = 8, pain = 170, drop = 2001,
    sounds = { see = { "posit1", "posit2", "posit3" }, active = "posact", pain = "popain", death = { "podth1", "podth2", "podth3" } },
    sequences = {
      stand = STAND,
      chase = walking("AABBCCDD", 3, "chase"),
      missile = { { "E", 10, "face" }, { "F", 10, "shotgun", true }, { "E", 10 }, next = "chase" },
      pain = { { "G", 3 }, { "G", 3, "pain" }, next = "chase" },
      die = { { "H", 5 }, { "I", 5, "scream" }, { "J", 5, "fall" }, { "K", 5 }, { "L", -1 } },
      gib = GIBBED,
    },
  },
  -- The imp: claws up close, fireballs from afar
  [3001] = {
    health = 60, speed = 8, pain = 200,
    sounds = { see = { "bgsit1", "bgsit2" }, active = "bgact", pain = "popain", death = { "bgdth1", "bgdth2" } },
    sequences = {
      stand = STAND,
      chase = walking("AABBCCDD", 3, "chase"),
      melee = { { "E", 8, "face" }, { "F", 8, "face" }, { "G", 6, "claw" }, next = "chase" },
      missile = { { "E", 8, "face" }, { "F", 8, "face" }, { "G", 6, "claw" }, next = "chase" },
      pain = { { "H", 2 }, { "H", 2, "pain" }, next = "chase" },
      die = { { "I", 8 }, { "J", 8, "scream" }, { "K", 6 }, { "L", 6, "fall" }, { "M", -1 } },
      gib = { { "N", 5 }, { "O", 5, "gib" }, { "P", 5 }, { "Q", 5, "fall" }, { "R", 5 }, { "S", 5 }, { "T", 5 }, { "U", -1 } },
    },
  },
  -- The demon: it bites, fast
  [3002] = { health = 150, speed = 10, pain = 180, sequences = DEMON, sounds = DEMON_SOUNDS },
  -- The spectre: a demon nobody sees well
  [58] = { health = 150, speed = 10, pain = 180, shadow = true, sequences = DEMON, sounds = DEMON_SOUNDS },
  -- The lost soul: a burning skull that flies, and charges
  [3006] = {
    -- Doom doesn't count a lost soul among the kills
    health = 100, speed = 8, pain = 256, floats = true, uncounted = true,
    sounds = { active = "dmact", pain = "dmpain", death = "firxpl", attack = "sklatk" },
    sequences = {
      stand = { { "A", 10, "look", true }, { "B", 10, "look", true }, next = "stand" },
      chase = { { "A", 6, "chase", true }, { "B", 6, "chase", true }, next = "chase" },
      missile = { { "C", 10, "face", true }, { "D", 4, "charge", true }, next = "charging" },
      charging = { { "C", 4, nil, true }, { "D", 4, nil, true }, next = "charging" },
      pain = { { "E", 3, nil, true }, { "E", 3, "pain", true }, next = "chase" },
      die = { { "F", 6, nil, true }, { "G", 6, "scream", true }, { "H", 6, nil, true }, { "I", 6, "fall", true }, { "J", 6 }, { "K", 6 } },
    },
  },
  -- The baron: claws close up, green fireballs from afar, and a great deal of health
  [3003] = {
    health = 1000, speed = 8, pain = 50, boss = true,
    sounds = { see = "brssit", active = "dmact", pain = "dmpain", death = "brsdth" },
    sequences = {
      stand = STAND,
      chase = walking("AABBCCDD", 3, "chase"),
      melee = { { "E", 8, "face" }, { "F", 8, "face" }, { "G", 8, "bruise" }, next = "chase" },
      missile = { { "E", 8, "face" }, { "F", 8, "face" }, { "G", 8, "bruise" }, next = "chase" },
      pain = { { "H", 2 }, { "H", 2, "pain" }, next = "chase" },
      die = { { "I", 8 }, { "J", 8, "scream" }, { "K", 8 }, { "L", 8, "fall" }, { "M", 8 }, { "N", 8, "bossDeath" }, { "O", -1 } },
    },
  },
  -- A barrel, which goes up when it is shot enough
  [2035] = {
    health = 20, barrel = true,
    sounds = { death = "barexp" },
    sequences = {
      stand = { { "A", 6 }, { "B", 6 }, next = "stand" },
      die = { sprite = "BEXP", { "A", 5, nil, true }, { "B", 5, "scream", true }, { "C", 5, nil, true }, { "D", 10, "explode", true }, { "E", 10, nil, true } },
    },
  },
}

-- What comes of a shot: smoke where it hit a wall (less of it close up), blood where it hit
-- somebody, more the harder; a fireball, flying and bursting; the flash of a teleport
local PUFF = { puff = { { "A", 4, nil, true }, { "B", 4 }, { "C", 4 }, { "D", 4 } }, near = { { "C", 4 }, { "D", 4 } } }
local BLOOD = { much = { { "A", 8 }, { "B", 8 }, { "C", 8 } }, some = { { "B", 8 }, { "C", 8 } }, little = { { "C", 8 } } }
local FIREBALL = {
  fly = { { "A", 4, nil, true }, { "B", 4, nil, true }, next = "fly" },
  burst = { { "C", 6, nil, true }, { "D", 6, nil, true }, { "E", 6, nil, true } },
}
local TELEPORT = { flash = {} }
for index, letter in ipairs({ "A", "B", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J" }) do
  TELEPORT.flash[index] = { letter, 6, nil, true }
end

-- What is fired rather than shot, by monsters and by the player: its sprite and how it flies and
-- bursts, units a tic, how wide it is, and how hard it hits. A rocket goes up as a barrel does
-- where it hits; the tracers of the BFG's ball go out from whoever fired it as it bursts, and
-- leave a green flash on whatever they found (tracer)
local MISSILES = {
  imp = { sprite = "BAL1", sequences = FIREBALL, speed = 10, radius = 6, damage = 3, launch = "firsht", bang = "firxpl" },
  baron = { sprite = "BAL7", sequences = FIREBALL, speed = 15, radius = 6, damage = 8, launch = "firsht", bang = "firxpl" },
  rocket = {
    sprite = "MISL", speed = 20, radius = 11, damage = 20, launch = "rlaunc", bang = "barexp",
    sequences = {
      fly = { { "A", 1, nil, true }, next = "fly" },
      burst = { { "B", 8, "explode", true }, { "C", 6, nil, true }, { "D", 4, nil, true } },
    },
  },
  plasma = {
    sprite = "PLSS", speed = 25, radius = 13, damage = 5, launch = "plasma", bang = "firxpl",
    sequences = {
      fly = { { "A", 6, nil, true }, { "B", 6, nil, true }, next = "fly" },
      burst = {
        sprite = "PLSE", { "A", 4, nil, true }, { "B", 4, nil, true }, { "C", 4, nil, true }, { "D", 4, nil, true }, { "E", 4, nil, true },
      },
    },
  },
  bfg = {
    sprite = "BFS1", speed = 25, radius = 13, damage = 100, bang = "rxplod",
    sequences = {
      fly = { { "A", 4, nil, true }, { "B", 4, nil, true }, next = "fly" },
      burst = {
        sprite = "BFE1", { "A", 8, nil, true }, { "B", 8, nil, true }, { "C", 8, "spray", true }, { "D", 8, nil, true }, { "E", 8, nil, true },
        { "F", 8, nil, true },
      },
    },
    tracer = { flash = { { "A", 8, nil, true }, { "B", 8, nil, true }, { "C", 8, nil, true }, { "D", 8, nil, true } } },
  },
}

--- @class FreedoomActor: FreedoomThing, Actor
--- @field info table? A monster's or barrel's, from MONSTERS
--- @field health number?
--- @field shootable boolean?
--- @field target FreedoomThing? Who a monster is after
--- @field movedir integer
--- @field movecount integer Steps before it thinks again about which way to go
--- @field reaction integer Tics before it may attack
--- @field threshold integer
--- @field ambush boolean It waits to see the player, rather than come at a shot it hears
--- @field missile table? It is a shot, from MISSILES
--- @field source FreedoomThing? Who fired it
--- @field charging boolean? A lost soul flying at whoever it is after
--- @field momx number?
--- @field momy number?
--- @field momz number?

local ACTIONS = {}

local function act(actor, action)
  ACTIONS[action](actor.run, actor)
end

local function shootable(thing)
  return thing.shootable == true
end

--- Puts something that lives into the map
--- @return FreedoomActor
local function spawn(run, actor, sprite, sequences, first)
  actor.sprite, actor.sequences, actor.run, actor.act = sprite, sequences, run, act
  actor.angle = actor.angle or 0
  actor.radius, actor.height = actor.radius or 1, actor.height or 1
  run.map:AddThing(actor)
  run.actors[#run.actors + 1] = actor
  Actors.Start(actor, first)
  return actor
end

local function distance(one, other)
  return math.sqrt((one.x - other.x) ^ 2 + (one.y - other.y) ^ 2)
end

--- Whether one thing sees another, from three quarters of the way up it, Doom's way
local function sees(run, looking, seen)
  local map = run.map
  local bottom = map:Bottom(seen)
  return map:Sees(looking.x, looking.y, map:Bottom(looking) + looking.height * 3 / 4, seen.x, seen.y, bottom, bottom + seen.height)
end

local function puff(run, x, y, z, near)
  spawn(run, { x = x, y = y, z = z + (chance() - chance()) / 64, momz = 1 }, "PUFF", PUFF, near and "near" or "puff")
end

local function blood(run, x, y, z, amount)
  spawn(run, { x = x, y = y, z = z + (chance() - chance()) / 64, momz = 2 }, "BLUD", BLOOD, amount > 12 and "much" or amount >= 9 and "some" or "little")
end

function teleportFlash(run, x, y)
  local flash = spawn(run, { x = x, y = y }, "TFOG", TELEPORT, "flash")
  sound(run, "telept", flash)
end

local damage

--- Something dies: a monster falls and drops what it carried, a barrel goes up
local function kill(run, target, source)
  if not target.info.barrel and not target.info.uncounted then
    run.kills = run.kills + 1
  end
  target.shootable, target.health = false, math.min(target.health or 0, 0)
  target.target = source
  local sequences = target.info.sequences
  local gib = sequences.gib and target.health < -target.info.health
  Actors.Start(target, gib and "gib" or "die")
  local drop = target.info.drop
  local kind = drop and run.map.data.kinds[drop]
  if kind then
    run.map:AddThing({
      x = target.x, y = target.y, angle = 0, radius = kind.radius, height = kind.height, kind = kind, type = drop, dropped = true,
      picture = kind.sprite .. kind.frames:sub(1, 1),
    })
  end
end

--- What a shot along the map hits: blood and hurt from somebody, smoke from a wall or a barrel
--- @return FreedoomThing? hit
local function shoot(run, shooter, angle, range, amount)
  local map = run.map
  run.shot = run.shot or {}
  local shot = map:Shoot(shooter.x, shooter.y, map:Bottom(shooter) + shooter.height / 2 + 8, angle, range, shooter, shootable, run.shot)
  local hit = shot.thing
  if hit then
    if hit.info and hit.info.barrel then
      puff(run, shot.x, shot.y, shot.z, range <= MELEE_RANGE + 1)
    else
      blood(run, shot.x, shot.y, shot.z, amount)
    end
    damage(run, hit, shooter, shooter, amount)
  else
    puff(run, shot.x, shot.y, shot.z, range <= MELEE_RANGE + 1)
    -- A wall the player shoots may do something
    if shot.line and shooter == run.player then
      trigger(run, shot.line, "shoot")
    end
  end
  return hit
end

--- Hurts whatever can be hurt near a point, less the further it is, if it can be seen from there
local function blast(run, from, source, amount)
  local map = run.map
  local around = {}
  for _, thing in ipairs(map:Touching(from.x, from.y, amount, around)) do
    if thing.shootable then
      local away = math.max(0, math.max(math.abs(thing.x - from.x), math.abs(thing.y - from.y)) - thing.radius)
      if away < amount then
        local bottom = map:Bottom(from)
        local thingBottom = map:Bottom(thing)
        if map:Sees(from.x, from.y, bottom + from.height / 2, thing.x, thing.y, thingBottom, thingBottom + thing.height) then
          damage(run, thing, from, source, amount - away)
        end
      end
    end
  end
end

--- Turns to face something
local function face(actor, target)
  actor.angle = math.atan2(target.y - actor.y, target.x - actor.x) % TWO_PI
end

--- The player, if a monster sees them: all round it, or only in front of it unless they are close
local function lookForPlayer(run, monster, allAround)
  local player = run.player
  if not player.shootable or not sees(run, monster, player) then
    return nil
  end
  if not allAround then
    local off = (math.atan2(player.y - monster.y, player.x - monster.x) - monster.angle + math.pi) % TWO_PI - math.pi
    if math.abs(off) > math.pi / 2 and distance(monster, player) > MELEE_RANGE then
      return nil
    end
  end
  return player
end

local function inMelee(run, monster)
  local target = monster.target
  return target ~= nil and distance(monster, target) < MELEE_RANGE - 20 + target.radius and sees(run, monster, target)
end

--- Doom's P_CheckMissileRange: the nearer, the likelier, never before the monster is ready
local function mayShoot(run, monster)
  if not sees(run, monster, monster.target) then
    return false
  end
  if monster.justHit then
    monster.justHit = false
    return true
  end
  if monster.reaction > 0 then
    return false
  end
  local away = distance(monster, monster.target) - 64
  if not monster.info.sequences.melee then
    away = away - 128
  end
  return chance() >= math.min(200, away)
end

--- A step the way the monster is walking, opening a door that is in the way
local function step(run, monster)
  if monster.movedir == NO_DIRECTION then
    return false
  end
  local way, speed = DIRECTIONS[monster.movedir + 1], monster.info.speed
  local fromX, fromY = monster.x, monster.y
  local moved, touched = run.map:TryMoveThing(monster, fromX + way[1] * speed, fromY + way[2] * speed, monster.info.floats)
  if moved then
    -- Over a line that does something a monster may set off
    local behind = private.SectorMap.Behind
    for _, line in ipairs(touched) do
      if line.special ~= 0 and behind(line.x1, line.y1, line.dx, line.dy, fromX, fromY) ~= behind(line.x1, line.y1, line.dx, line.dy, monster.x, monster.y) then
        trigger(run, line, "walk", monster, not behind(line.x1, line.y1, line.dx, line.dy, fromX, fromY))
      end
    end
    return true
  end
  local opened = false
  for _, line in ipairs(touched) do
    if line.special == 1 and line.back then
      door(run, line.back.sector, "raise", DOOR)
      opened = true
    end
  end
  if opened then
    monster.movedir = NO_DIRECTION
  end
  return opened
end

local function tryWalk(run, monster)
  if not step(run, monster) then
    return false
  end
  monster.movecount = chance() % 16
  return true
end

--- Doom's P_NewChaseDir: straight at the target if it can, else round about it
local function newChaseDir(run, monster)
  local target = monster.target
  local old = monster.movedir
  local back = opposite(old)
  local dx, dy = target.x - monster.x, target.y - monster.y
  local first = dx > 10 and EAST or dx < -10 and WEST or NO_DIRECTION
  local second = dy < -10 and SOUTH or dy > 10 and NORTH or NO_DIRECTION
  if first ~= NO_DIRECTION and second ~= NO_DIRECTION then
    monster.movedir = (dy < 0 and (dx > 0 and 7 or 5)) or (dx > 0 and 1 or 3)
    if monster.movedir ~= back and tryWalk(run, monster) then
      return
    end
  end
  if chance() > 200 or math.abs(dy) > math.abs(dx) then
    first, second = second, first
  end
  if first == back then
    first = NO_DIRECTION
  end
  if second == back then
    second = NO_DIRECTION
  end
  for _, way in ipairs({ first, second, old }) do
    if way ~= NO_DIRECTION then
      monster.movedir = way
      if tryWalk(run, monster) then
        return
      end
    end
  end
  local from, to, by = 0, 7, 1
  if chance() % 2 == 1 then
    from, to, by = 7, 0, -1
  end
  for way = from, to, by do
    if way ~= back then
      monster.movedir = way
      if tryWalk(run, monster) then
        return
      end
    end
  end
  if back ~= NO_DIRECTION then
    monster.movedir = back
    if tryWalk(run, monster) then
      return
    end
  end
  monster.movedir = NO_DIRECTION
end

--- Something flying goes on to a point if it can: whoever is in its way there is hit by it, and a
--- wall or anything else solid stops it
--- @return boolean moved
local function advance(run, flier, x, y)
  local map = run.map
  run.near = run.near or {}
  for _, thing in ipairs(map:Touching(x, y, flier.radius, run.near)) do
    if thing ~= flier and thing ~= flier.source and thing.shootable then
      local bottom = map:Bottom(thing)
      if flier.z + flier.height > bottom and flier.z < bottom + thing.height then
        local hard = flier.missile and flier.missile.damage or CHARGE_DAMAGE
        damage(run, thing, flier, flier.source or flier, (chance() % 8 + 1) * hard)
        return false
      end
    end
  end
  return (map:TryMoveThing(flier, x, y, true))
end

--- A missile goes up where it is: it stops, and bursts for a little more or less time
local function burst(missile)
  sound(missile.run, missile.missile and missile.missile.bang, missile)
  missile.momx, missile.momy, missile.momz = 0, 0, 0
  Actors.Start(missile, "burst")
  missile.tics = math.max(1, missile.tics - chance() % 4)
end

--- Doom's P_AimLineAttack: the first thing that can be shot in line with an angle from somebody,
--- up or down as far as a shot of theirs would be aimed, and the slope up or down to it
--- @return FreedoomThing? target
--- @return number slope
local function aim(run, shooter, angle)
  local map = run.map
  local z = map:Bottom(shooter) + shooter.height / 2 + 8
  run.aimed = run.aimed or {}
  local shot = map:Shoot(shooter.x, shooter.y, z, angle, AIM.range, shooter, shootable, run.aimed)
  if not shot.thing then
    return nil, 0
  end
  return shot.thing, (shot.z - z) / shot.distance
end

--- A missile, fired by a monster at whoever it is after, or by the player the way they face. The
--- player's is Doom's P_SpawnPlayerMissile: aimed up or down at whatever is in line with the way
--- they face, or failing that a little to one side of it or the other, and fired level when there
--- is nothing to aim at. As Doom's P_CheckMissileSpawn has it, a missile sets out half a tic's
--- flight ahead, and bursts there and then on whatever is already in its way: a rocket fired at a
--- wall up close goes up in the face of whoever fired it
--- @param target FreedoomThing? Who it is fired at, the player's aim if left out
local function spawnMissile(run, source, missile, target)
  local map = run.map
  local angle, slope
  if target then
    angle = math.atan2(target.y - source.y, target.x - source.x)
    slope = (map:Bottom(target) - map:Bottom(source) - FLIGHT.z) / math.max(1, distance(source, target))
  else
    angle = run.angle
    target, slope = aim(run, source, angle)
    for _, aside in ipairs({ AIM.aside, -AIM.aside }) do
      if not target then
        angle = run.angle + aside
        target, slope = aim(run, source, angle)
      end
    end
    if not target then
      angle, slope = run.angle, 0
    end
  end
  local shot = spawn(run, {
    x = source.x, y = source.y, z = map:Bottom(source) + FLIGHT.z, angle = angle % TWO_PI,
    radius = missile.radius, height = FLIGHT.height, missile = missile, source = source,
    momx = math.cos(angle) * missile.speed, momy = math.sin(angle) * missile.speed, momz = slope * missile.speed,
  }, missile.sprite, missile.sequences, "fly")
  sound(run, missile.launch, shot)
  shot.tics = math.max(1, shot.tics - chance() % 4)
  if not advance(run, shot, shot.x + shot.momx / 2, shot.y + shot.momy / 2) then
    burst(shot)
  end
end

function ACTIONS.look(run, monster)
  monster.threshold = 0
  local heard = monster.sector.soundTarget
  local target
  if heard and heard.shootable and (not monster.ambush or sees(run, monster, heard)) then
    target = heard
  end
  target = target or lookForPlayer(run, monster, false)
  if target then
    monster.target = target
    sound(run, monster.info.sounds.see, monster)
    Actors.Start(monster, "chase")
  end
end

--- A monster that flies rises or sinks a little towards whoever it is after
local function float(run, monster)
  local target, map = monster.target, run.map
  if not target or not monster.z then
    return
  end
  local off = (map:Bottom(target) + target.height / 2) - (monster.z + monster.height / 2)
  if math.abs(off) > FLOAT_SPEED then
    local _, floor, ceiling = map:Check(monster.x, monster.y, monster.radius, nil, monster)
    monster.z = math.max(floor, math.min(ceiling - monster.height, monster.z + (off > 0 and FLOAT_SPEED or -FLOAT_SPEED)))
    map:Changed()
  end
end

function ACTIONS.chase(run, monster)
  if monster.info.floats then
    float(run, monster)
  end
  if monster.reaction > 0 then
    monster.reaction = monster.reaction - 1
  end
  if monster.threshold > 0 then
    monster.threshold = (monster.target and monster.target.shootable) and monster.threshold - 1 or 0
  end
  -- Turned towards the way it walks, an eighth at a time
  if monster.movedir ~= NO_DIRECTION then
    local snapped = math.floor(monster.angle / EIGHTH + 1e-6) * EIGHTH
    local off = (snapped - monster.movedir * EIGHTH + math.pi) % TWO_PI - math.pi
    if off > 1e-6 then
      snapped = snapped - EIGHTH
    elseif off < -1e-6 then
      snapped = snapped + EIGHTH
    end
    monster.angle = snapped % TWO_PI
  end
  local target = monster.target
  if not target or not target.shootable then
    target = lookForPlayer(run, monster, true)
    if target then
      monster.target = target
    else
      monster.target = nil
      Actors.Start(monster, "stand")
    end
    return
  end
  if monster.justAttacked then
    monster.justAttacked = false
    newChaseDir(run, monster)
    return
  end
  local sequences = monster.info.sequences
  if sequences.melee and inMelee(run, monster) then
    sound(run, monster.info.sounds.attack, monster)
    Actors.Start(monster, "melee")
    return
  end
  if sequences.missile and monster.movecount == 0 and mayShoot(run, monster) then
    Actors.Start(monster, "missile")
    monster.justAttacked = true
    return
  end
  monster.movecount = monster.movecount - 1
  if monster.movecount < 0 or not step(run, monster) then
    newChaseDir(run, monster)
  end
  if chance() < 3 then
    sound(run, monster.info.sounds.active, monster)
  end
end

function ACTIONS.face(_, monster)
  if monster.target then
    face(monster, monster.target)
  end
end

function ACTIONS.pistol(run, monster)
  if not monster.target then
    return
  end
  sound(run, "pistol", monster)
  face(monster, monster.target)
  shoot(run, monster, monster.angle + (chance() - chance()) * MONSTER_SPREAD, MISSILE_RANGE, (chance() % 5 + 1) * 3)
end

function ACTIONS.shotgun(run, monster)
  if not monster.target then
    return
  end
  sound(run, "shotgn", monster)
  face(monster, monster.target)
  for _ = 1, 3 do
    shoot(run, monster, monster.angle + (chance() - chance()) * MONSTER_SPREAD, MISSILE_RANGE, (chance() % 5 + 1) * 3)
  end
end

function ACTIONS.claw(run, monster)
  if not monster.target then
    return
  end
  face(monster, monster.target)
  if inMelee(run, monster) then
    sound(run, "claw", monster)
    damage(run, monster.target, monster, monster, (chance() % 8 + 1) * 3)
  else
    spawnMissile(run, monster, MISSILES.imp, monster.target)
  end
end

function ACTIONS.bruise(run, monster)
  if not monster.target then
    return
  end
  face(monster, monster.target)
  if inMelee(run, monster) then
    sound(run, "claw", monster)
    damage(run, monster.target, monster, monster, (chance() % 8 + 1) * 10)
  else
    spawnMissile(run, monster, MISSILES.baron, monster.target)
  end
end

--- A lost soul flies at whoever it is after, until it hits them or anything else
function ACTIONS.charge(run, soul)
  local target = soul.target
  if not target then
    return
  end
  face(soul, target)
  sound(run, soul.info.sounds.attack, soul)
  local map = run.map
  local away = math.max(1, distance(soul, target))
  soul.charging = true
  soul.momx, soul.momy = math.cos(soul.angle) * CHARGE_SPEED, math.sin(soul.angle) * CHARGE_SPEED
  soul.momz = (map:Bottom(target) + target.height / 2 - map:Bottom(soul)) / (away / CHARGE_SPEED)
end

--- The last of the bosses fell: on the map they guard the way on opens
function ACTIONS.bossDeath(run, boss)
  if run.level ~= BOSS_MAP then
    return
  end
  for _, actor in ipairs(run.actors) do
    if actor ~= boss and actor.type == boss.type and actor.shootable then
      return
    end
  end
  for _, sector in ipairs(run.map:Tagged(BOSS_TAG)) do
    floor(run, sector, "lowest", FLOOR)
  end
end

function ACTIONS.bite(run, monster)
  if not monster.target then
    return
  end
  face(monster, monster.target)
  if inMelee(run, monster) then
    damage(run, monster.target, monster, monster, (chance() % 10 + 1) * 4)
  end
end

function ACTIONS.pain(run, monster)
  sound(run, monster.info.sounds.pain, monster)
end

function ACTIONS.scream(run, monster)
  sound(run, monster.info.sounds.death, monster)
end

--- Torn apart
function ACTIONS.gib(run, monster)
  sound(run, "slop", monster)
end

function ACTIONS.fall(_, monster)
  monster.solid = false
end

--- A barrel or a rocket goes up, and hurts everybody about it, on behalf of whoever shot the
--- barrel or fired the rocket, which may be themselves
function ACTIONS.explode(run, thing)
  blast(run, thing, thing.missile and thing.source or thing.target, BLAST)
end

--- The BFG's ball bursts: its tracers go out across a quarter turn about the way it was fired,
--- each aimed from whoever fired it as a shot of theirs would be, and whatever each finds is hurt
--- badly, a green flash on it
function ACTIONS.spray(run, ball)
  local source, map = ball.source, run.map
  if not source then
    return
  end
  for index = 0, AIM.tracers - 1 do
    local target = aim(run, source, ball.angle - AIM.spread / 2 + AIM.spread / AIM.tracers * index)
    if target then
      spawn(run, { x = target.x, y = target.y, z = map:Bottom(target) + target.height / 4 }, "BFE2", ball.missile.tracer, "flash")
      local amount = 0
      for _ = 1, AIM.blows do
        amount = amount + chance() % 8 + 1
      end
      damage(run, target, source, source, amount)
    end
  end
end

--- A missile's flight for a tic, or a lost soul's: it bursts on whatever it hits, wall, floor,
--- ceiling or somebody
local function fly(run, missile)
  local momx, momy = missile.momx, missile.momy
  local goes = (math.abs(momx) > FLIGHT.half or math.abs(momy) > FLIGHT.half) and 2 or 1
  for _ = 1, goes do
    if not advance(run, missile, missile.x + momx / goes, missile.y + momy / goes) then
      return false
    end
  end
  missile.z = missile.z + missile.momz
  local sector = missile.sector
  return missile.z > sector.floor and missile.z + missile.height < sector.ceiling
end

local playerDies

--- Somebody is hurt: the player through their armour, a monster flinching now and then and
--- turning on whoever did it, anything with no health left dying
function damage(run, target, inflictor, source, amount)
  if not target.shootable then
    return
  end
  if target == run.player then
    local inventory = run.inventory
    if run.halfDamage then
      amount = math.floor(amount / 2)
    end
    if inventory.armorClass > 0 then
      local saved = math.floor(amount / (inventory.armorClass == 1 and 3 or 2))
      if inventory.armor <= saved then
        saved, inventory.armorClass = inventory.armor, 0
      end
      inventory.armor = inventory.armor - saved
      amount = amount - saved
    end
    inventory.health = math.max(0, inventory.health - amount)
    run.hurt = math.min(100, (run.hurt or 0) + amount)
    run.hurtBy, run.hurtAmount, run.hurtTic = source, amount, run.tic
    if inventory.health <= 0 then
      sound(run, "pldeth", run.player)
      playerDies(run)
    elseif amount > 0 then
      sound(run, "plpain", run.player)
    end
    return
  end
  if target.charging then
    target.charging, target.momx, target.momy, target.momz = false, 0, 0, 0
  end
  target.health = target.health - amount
  if target.health <= 0 then
    kill(run, target, source)
    return
  end
  if target.info.barrel then
    return
  end
  if chance() < target.info.pain then
    target.justHit = true
    Actors.Start(target, "pain")
  end
  target.reaction = 0
  if target.threshold == 0 and source and source ~= target and source.shootable then
    target.target, target.threshold = source, GRUDGE
    if target.sequence == "stand" then
      Actors.Start(target, "chase")
    end
  end
end

function playerDies(run)
  run.dead = run.tic
  run.player.shootable, run.player.solid = false, false
  run.inventory.pending = nil
end

--- Puts in the monsters and barrels of the map that are there at the player's skill
local function populate(run, things)
  run.kills, run.totalKills = 0, 0
  for _, thing in ipairs(things) do
    local info = MONSTERS[thing.type]
    local kind = run.map.data.kinds[thing.type]
    if info and kind then
      if not info.barrel and not info.uncounted then
        run.totalKills = run.totalKills + 1
      end
      spawn(run, {
        x = thing.x, y = thing.y, angle = math.rad(thing.angle), radius = kind.radius, height = kind.height, solid = true, shootable = true,
        kind = kind, type = thing.type, info = info, health = info.health, movedir = NO_DIRECTION, movecount = 0, reaction = 8, threshold = 0,
        ambush = thing.flags % 16 >= 8, shadow = info.shadow,
        -- What flies is where it is, not on the floor
        z = info.floats and run.map:SectorAt(thing.x, thing.y).floor or nil,
      }, kind.sprite, info.sequences, "stand")
    end
  end
end

--- One tic of what lives: everything takes its step, what flies flies, what has had its time goes
--- @return boolean seen Something the player saw the last frame changed
local function liveTic(run)
  local actors, map, seen = run.actors, run.map, false
  for index = #actors, 1, -1 do
    local actor = actors[index]
    local before = actor.picture
    if actor.missile and actor.sequence == "fly" then
      if not fly(run, actor) then
        burst(actor)
      end
    elseif actor.charging then
      if not fly(run, actor) then
        -- Whatever it hit, it stops, and looks about again
        actor.charging, actor.momx, actor.momy, actor.momz = false, 0, 0, 0
        actor.z = math.max(actor.sector.floor, math.min(actor.z, actor.sector.ceiling - actor.height))
        if actor.shootable then
          Actors.Start(actor, "stand")
        end
      end
    elseif actor.momz and actor.z and not actor.info then
      actor.z = actor.z + actor.momz
    end
    if not actor.removed then
      Actors.Tick(actor)
    end
    if actor.removed then
      map:RemoveThing(actor)
      table.remove(actors, index)
    elseif actor.picture ~= before then
      seen = seen or run.shows(actor)
    end
  end
  return seen
end

-----------------------------
-- The player's weapons
-----------------------------
-- What the player holds, drawn over the view as Doom drew it, and what firing it does (Doom's
-- p_pspr.c): a weapon goes through states like a monster does, its flash beside it, and is
-- lowered out of sight and the next raised when the player changes to another. Firing lights up
-- the room and is heard in the rooms around. A shot the player keeps firing goes a little wide,
-- the first is true; whatever is in line with it above or below is aimed at. The rocket
-- launcher, the plasma gun and the BFG fire missiles instead, which fly as a monster's fireballs
-- do (MISSILES), aimed the same way.

-- Where a weapon is held, and where it goes down to; how fast it goes down and comes up
local WEAPON_TOP, WEAPON_BOTTOM, WEAPON_SPEED = 32, 128, 6
-- How much a weapon and the eye bob about while walking, at most
local MOST_BOB = 16

local READY = { { "A", 1, "ready" }, next = "ready" }
local GUNS = {
  fist = {
    sprite = "PUNG",
    sequences = { ready = READY, fire = { { "B", 4 }, { "C", 4, "punch" }, { "D", 5 }, { "C", 4 }, { "B", 5, "refire" }, next = "ready" } },
  },
  chainsaw = {
    sprite = "SAWG",
    sequences = {
      ready = { { "C", 4, "ready" }, { "D", 4, "ready" }, next = "ready" },
      fire = { { "A", 4, "saw" }, { "B", 4, "saw" }, { "B", 0, "refire" }, next = "ready" },
    },
  },
  pistol = {
    sprite = "PISG",
    sequences = {
      ready = READY,
      fire = { { "A", 4 }, { "B", 6, "pistol" }, { "C", 4 }, { "B", 5, "refire" }, next = "ready" },
      flash = { sprite = "PISF", { "A", 7, "light", true } },
    },
  },
  shotgun = {
    sprite = "SHTG",
    sequences = {
      ready = READY,
      fire = { { "A", 3 }, { "A", 7, "shotgun" }, { "B", 5 }, { "C", 5 }, { "D", 4 }, { "C", 5 }, { "B", 5 }, { "A", 3 }, { "A", 7, "refire" }, next = "ready" },
      flash = { sprite = "SHTF", { "A", 4, "light", true }, { "B", 3, "brighter", true } },
    },
  },
  chaingun = {
    sprite = "CHGG",
    sequences = {
      ready = READY,
      fire = { { "A", 4, "chaingun" }, { "B", 4, "chaingun" }, { "B", 0, "refire" }, next = "ready" },
      flash = { sprite = "CHGF", { "A", 5, "light", true } },
      flash2 = { sprite = "CHGF", { "B", 5, "brighter", true } },
    },
  },
  launcher = {
    sprite = "MISG",
    sequences = {
      ready = READY,
      fire = { { "B", 8, "gunFlash" }, { "B", 12, "rocket" }, { "B", 0, "refire" }, next = "ready" },
      flash = {
        sprite = "MISF", { "A", 3, "light", true }, { "B", 4, nil, true }, { "C", 4, "brighter", true }, { "D", 4, "brighter", true },
      },
    },
  },
  plasma = {
    sprite = "PLSG",
    sequences = {
      ready = READY,
      fire = { { "A", 3, "plasma" }, { "B", 20, "refire" }, next = "ready" },
      flash = { sprite = "PLSF", { "A", 4, "light", true } },
      flash2 = { sprite = "PLSF", { "B", 4, "light", true } },
    },
  },
  bfg = {
    sprite = "BFGG",
    sequences = {
      ready = READY,
      fire = { { "A", 20, "hum" }, { "B", 10, "gunFlash" }, { "B", 10, "bfg" }, { "B", 20, "refire" }, next = "ready" },
      flash = { sprite = "BFGF", { "A", 11, "light", true }, { "B", 6, "brighter", true } },
    },
  },
}
-- Which weapon the player turns to when the one they hold runs dry: the first they have and can
-- fire, in Doom's order (P_CheckAmmo), which leaves the rocket launcher and the BFG until nothing
-- but the fist is left, for what they might do up close
local FALLBACK = { "plasma", "chaingun", "shotgun", "pistol", "chainsaw", "launcher", "bfg", "fist" }

local GUN_ACTIONS = {}

local function gunAct(gun, action)
  GUN_ACTIONS[action](gun.run, gun)
end

local function canFire(inventory, name)
  local ammo = WEAPONS[name].ammo
  return inventory.weapons[name] and (not ammo or inventory.ammo[ammo] >= (WEAPONS[name].uses or 1))
end

--- Fires if there is something to fire, else changes to something that can
local function fire(run)
  local inventory = run.inventory
  if not canFire(inventory, inventory.weapon) then
    for _, name in ipairs(FALLBACK) do
      if canFire(inventory, name) then
        inventory.pending = name
        break
      end
    end
    return
  end
  Actors.Start(run.gun, "fire")
  -- Every shot is heard, a punch too
  run.map:Noise(run.player.sector, run.player)
end

local function flash(run, sequence)
  local gun = run.flash
  gun.sequences = GUNS[run.inventory.weapon].sequences
  Actors.Start(gun, sequence or "flash")
end

local function use(run)
  local weapon = WEAPONS[run.inventory.weapon]
  local ammo = weapon.ammo
  if ammo then
    run.inventory.ammo[ammo] = math.max(0, run.inventory.ammo[ammo] - (weapon.uses or 1))
  end
end

local function gunShot(run, accurate)
  local spread = accurate and 0 or (chance() - chance()) * PLAYER_SPREAD
  shoot(run, run.player, run.angle + spread, MISSILE_RANGE, 5 * (chance() % 3 + 1))
end

function GUN_ACTIONS.ready(run, gun)
  local inventory = run.inventory
  if inventory.weapon == "chainsaw" and gun.step == 1 then
    -- Its engine, idling
    sound(run, "sawidl", run.player)
  end
  if run.dead or (inventory.pending and inventory.pending ~= inventory.weapon) then
    run.gunMoving = -1
    return
  end
  if run.firing then
    fire(run)
  end
end

function GUN_ACTIONS.refire(run)
  local inventory = run.inventory
  if run.firing and not run.dead and (not inventory.pending or inventory.pending == inventory.weapon) then
    run.refire = run.refire + 1
    fire(run)
  else
    run.refire = 0
    if not canFire(inventory, inventory.weapon) then
      fire(run)
    end
  end
end

function GUN_ACTIONS.pistol(run)
  use(run)
  sound(run, "pistol")
  flash(run)
  gunShot(run, run.refire == 0)
end

function GUN_ACTIONS.shotgun(run)
  use(run)
  sound(run, "shotgn")
  flash(run)
  for _ = 1, 7 do
    gunShot(run, false)
  end
end

function GUN_ACTIONS.chaingun(run, gun)
  if not canFire(run.inventory, "chaingun") then
    return
  end
  use(run)
  sound(run, "pistol")
  flash(run, gun.step == 1 and "flash" or "flash2")
  gunShot(run, run.refire == 0)
end

--- The flash of a weapon whose shot comes later: the rocket launcher's and the BFG's
function GUN_ACTIONS.gunFlash(run)
  flash(run)
end

function GUN_ACTIONS.rocket(run)
  use(run)
  spawnMissile(run, run.player, MISSILES.rocket)
end

--- The plasma gun flashes one way or the other, as it happens
function GUN_ACTIONS.plasma(run)
  use(run)
  flash(run, chance() % 2 == 0 and "flash" or "flash2")
  spawnMissile(run, run.player, MISSILES.plasma)
end

--- The BFG's hum as it gathers itself
function GUN_ACTIONS.hum(run)
  sound(run, "bfg")
end

function GUN_ACTIONS.bfg(run)
  use(run)
  spawnMissile(run, run.player, MISSILES.bfg)
end

local function closeIn(run, range, amount)
  local hit = shoot(run, run.player, run.angle + (chance() - chance()) * PLAYER_SPREAD, range, amount)
  if hit then
    run.angle = math.atan2(hit.y - run.player.y, hit.x - run.player.x) % TWO_PI
  end
  return hit
end

function GUN_ACTIONS.punch(run)
  if closeIn(run, MELEE_RANGE, (chance() % 10 + 1) * 2 * (run.inventory.powers.berserk and 10 or 1)) then
    sound(run, "punch")
  end
end

function GUN_ACTIONS.saw(run)
  sound(run, closeIn(run, MELEE_RANGE + 1, 2 * (chance() % 10 + 1)) and "sawhit" or "sawful", run.player)
end

function GUN_ACTIONS.light(run)
  run.light = 1
end

function GUN_ACTIONS.brighter(run)
  run.light = 2
end

--- A tic of the player's weapon: up, down, or going through its states
local function gunTic(run)
  local gun, inventory = run.gun, run.inventory
  if run.gunMoving == -1 then
    run.gunY = run.gunY + WEAPON_SPEED
    if run.gunY >= WEAPON_BOTTOM then
      run.gunY = WEAPON_BOTTOM
      if run.dead then
        return
      end
      inventory.weapon = inventory.pending or inventory.weapon
      inventory.pending = nil
      gun.sprite, gun.sequences = GUNS[inventory.weapon].sprite, GUNS[inventory.weapon].sequences
      if inventory.weapon == "chainsaw" then
        sound(run, "sawup", run.player)
      end
      Actors.Start(gun, "ready")
      run.gunMoving = 1
    end
    return
  elseif run.gunMoving == 1 then
    run.gunY = run.gunY - WEAPON_SPEED
    if run.gunY <= WEAPON_TOP then
      run.gunY, run.gunMoving = WEAPON_TOP, 0
    end
    return
  end
  Actors.Tick(gun)
  if run.flash.sequence then
    Actors.Tick(run.flash)
    if not run.flash.sequence then
      run.light = 0
    end
  end
end

-- For the tests
-- For the tests
Freedoom.Specials, Freedoom.Trigger = SPECIALS, trigger
function Freedoom.Damage(run, target, amount)
  damage(run, target, nil, nil, amount)
end

-- What the view needs of the world
Freedoom.GUNS, Freedoom.MONSTERS, Freedoom.HEIGHT, Freedoom.RADIUS = GUNS, MONSTERS, HEIGHT, RADIUS
Freedoom.TWO_PI, Freedoom.EIGHTH, Freedoom.MOST_BOB, Freedoom.WEAPON_TOP = TWO_PI, EIGHTH, MOST_BOB, WEAPON_TOP
Freedoom.damage, Freedoom.trigger, Freedoom.populate = damage, trigger, populate
Freedoom.liveTic, Freedoom.gunTic, Freedoom.gunAct = liveTic, gunTic, gunAct
