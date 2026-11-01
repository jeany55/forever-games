--------------------------
--  Starfall: the board, and a shot fired into it
--------------------------
-- The rules side of Starfall, with nothing in it that touches the game client: how a night's sky
-- of stones is laid out from the match's chance, and what happens when a falling star is fired
-- into it. Both run inside the game's rules, on every client that replays the match, so they use
-- nothing but `random` for chance and the engine's Physics for the flight, which comes out the
-- same on every computer (Engine/Physics.lua). A shot is worked out whole, the moment it is made,
-- and its flight is kept for the view to play back.
--
-- The sky is SKY_WIDTH by SKY_HEIGHT units, x to the right and y down. The star is fired from
-- the crescent at the top middle; walls close the sky at the sides and the top, and the bottom
-- is open: a star that falls out of it is spent, unless it falls into the Moonwell, a pool that
-- lies somewhere else along the bottom for every shot.
--
-- What is in the sky, each a round stone a star bounces off:
--   moonstones     pale stones, a few points each
--   stars          the stones of the constellations, each a handful of stars joined by faint
--                  lines. Light every star of every constellation to win the night
--   wisps          two to a night: a wisp that is hit flies off as a second falling star
-- A stone a star touches lights up, and every stone lit by a shot is gone once the shot is over.

local _, own = ...
local engine = ForeverGamesAPI
local Physics = engine.Physics

local Board = {}
own.Board = Board

local floor, sqrt, min, max = math.floor, math.sqrt, math.min, math.max
local sin, cos = Physics.Sin, Physics.Cos

-- The sky, in units
local SKY_WIDTH, SKY_HEIGHT = 640, 480
-- Where a star is fired from, how big it is and how fast it leaves
local LAUNCH_X, LAUNCH_Y = 320, 34
local STAR_RADIUS = 6
local LAUNCH_SPEED = 470
-- How big a stone is, and how close two may be, middle to middle
local STONE_RADIUS = 8
local SPACING = 21
-- Where stones may be laid: clear of the walls, of the crescent and of the bottom
local FIELD_LEFT, FIELD_RIGHT, FIELD_TOP, FIELD_BOTTOM = 24, 616, 104, 444
-- The Moonwell, how wide it is and the places along the bottom it can be
local WELL_WIDTH = 96
local WELL_PLACES = 9
-- The air: ticks a second, the pull down, and the most speed a star can have
local HZ = 240
local GRAVITY = 400
local FASTEST = 900
-- How springy stones and walls are
local STONE_BOUNCE, STONE_FRICTION = 0.66, 0.04
local WALL_BOUNCE, WALL_FRICTION = 0.75, 0.02
-- Samples of a flight, every so many ticks: 60 a second
local SAMPLE = 4
-- A stone touched again within this many ticks is the same touch, as a star rolling over it
local AGAIN = floor(HZ * 0.09)
-- A star that has lit nothing new for this long is caught somewhere: the stone it last touched
-- is taken away, then another every so often until it falls free
local STUCK, UNSTICK = HZ * 4, floor(HZ * 0.6)
-- And no shot lasts longer than this
local LONGEST = HZ * 40
-- How the aim is said: a whole number of tenths of a degree from straight down, the left first
local AIMS = 1800

-- Points: for a stone of each kind, a constellation woken (for each star in it), and every star
-- not fired once the night is won
local POINTS = { stone = 10, star = 100, wisp = 50 }
local WOKEN = 1000
local UNSPENT = 10000
-- Every so many stones lit in one shot raise what the shot is worth by one time again
local CHAIN = 5

-- The constellations, by the names they are known by in Moonglade's sky
local NAMES = { "owl", "stag", "bear", "wisp", "huntress", "raven", "sabre", "hippogryph", "tree", "moon", "dragon", "lantern" }

Board.SKY_WIDTH, Board.SKY_HEIGHT = SKY_WIDTH, SKY_HEIGHT
Board.LAUNCH_X, Board.LAUNCH_Y = LAUNCH_X, LAUNCH_Y
Board.STAR_RADIUS, Board.STONE_RADIUS = STAR_RADIUS, STONE_RADIUS
Board.LAUNCH_SPEED, Board.GRAVITY, Board.HZ, Board.SAMPLE = LAUNCH_SPEED, GRAVITY, HZ, SAMPLE
Board.WELL_WIDTH = WELL_WIDTH
Board.AIMS = AIMS
Board.CHAIN, Board.WOKEN, Board.UNSPENT = CHAIN, WOKEN, UNSPENT
Board.POINTS = POINTS

-----------------------------
-- Laying out the sky
-----------------------------
-- A night is laid out from a pattern, chosen and shaped by chance: rings, arcs, rows, waves and
-- lines of stones, always the same on the left as on the right, as a sky laid out by hand would
-- be. Stones too close to one already laid are left out, and so are those outside the field.

--- @param value number
--- @return number To the nearest half unit, so that a stone's place is short to write down
local function half(value)
  return floor(value * 2 + 0.5) / 2
end

--- A shape of stones, the one on the left mirrored to the right as well
--- @class StarfallSketch
--- @field points number[] x and y of each stone in turn
local Sketch = {}
Sketch.__index = Sketch

local function newSketch()
  return setmetatable({ points = {} }, Sketch)
end

--- A stone, and its mirror across the middle
function Sketch:Add(x, y)
  local points = self.points
  points[#points + 1], points[#points + 2] = x, y
  local mirror = SKY_WIDTH - x
  if mirror - x > 1 or x - mirror > 1 then
    points[#points + 1], points[#points + 2] = mirror, y
  end
end

--- Stones in a straight line, `count` of them, from one end to the other
function Sketch:Line(x1, y1, x2, y2, count)
  for index = 0, count - 1 do
    local t = count > 1 and index / (count - 1) or 0.5
    self:Add(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t)
  end
end

--- Stones along part of a circle, from angle a1 to a2 (radians, clockwise from the right, as y
--- is down), `count` of them
function Sketch:Arc(cx, cy, r, a1, a2, count)
  for index = 0, count - 1 do
    local a = a1 + (a2 - a1) * (count > 1 and index / (count - 1) or 0.5)
    self:Add(cx + r * cos(a), cy + r * sin(a))
  end
end

--- A whole ring, `count` stones round it, the first at angle `turn`
function Sketch:Ring(cx, cy, r, count, turn)
  for index = 0, count - 1 do
    local a = (turn or 0) + 6.283185307179586 * index / count
    self:Add(cx + r * cos(a), cy + r * sin(a))
  end
end

--- A row across from x1 to the middle, a stone every `gap`, with its mirror
function Sketch:Row(y, x1, gap)
  local x = x1
  while x <= SKY_WIDTH / 2 + 0.5 do
    self:Add(x, y)
    x = x + gap
  end
end

--- A wave across the whole sky: a stone every `gap` along it, rising and falling by `height`
--- every `period` units
function Sketch:Wave(y, height, period, gap, phase)
  local x = SKY_WIDTH / 2
  while x >= FIELD_LEFT do
    self:Add(x, y + height * sin(6.283185307179586 * (x - SKY_WIDTH / 2) / period + (phase or 0)))
    x = x - gap
  end
end

-- The patterns, each a function of the chance that shapes it and the sketch to draw on
local PATTERNS = {}

-- Rows of stones like a pachinko board's, every other row along by half, with gaps in places,
-- and rings in the gaps
function PATTERNS.rows(random, sketch)
  local gap = 44 + random:Roll(4) * 4
  local rows = 6 + random:Roll(2)
  local top = 124 + random:Roll(3) * 6
  local step = (FIELD_BOTTOM - 16 - top) / (rows - 1)
  local hole = random:Roll(rows)
  for row = 1, rows do
    if row ~= hole then
      sketch:Row(top + (row - 1) * step, row % 2 == 0 and SKY_WIDTH / 2 - gap * 6 or SKY_WIDTH / 2 - gap * 6.5, gap)
    end
  end
  local y = top + (hole - 1) * step
  sketch:Ring(SKY_WIDTH / 2 - 150 - random:Roll(3) * 10, y, 26, 7, 0.3)
  sketch:Ring(SKY_WIDTH / 2, y, 24, 6, 0)
end

-- Rings scattered over the sky, some with a stone in the middle
function PATTERNS.rings(random, sketch)
  local spots = { { 90, 170 }, { 210, 150 }, { 140, 270 }, { 260, 260 }, { 80, 380 }, { 200, 380 }, { 320, 340 }, { 320, 180 } }
  random:Shuffle(spots)
  for index = 1, 5 + random:Roll(2) do
    local spot = spots[index]
    local r = 30 + random:Roll(4) * 4
    local count = floor(r * 6.28 / 26)
    local x = spot[1] + random:Roll(5) * 4 - 12
    sketch:Ring(x, spot[2] + random:Roll(5) * 4 - 12, r, count, random:Roll(6) * 0.5)
    if random:Roll(2) == 1 then
      sketch:Add(x, spot[2])
    end
  end
  sketch:Row(FIELD_BOTTOM - 4, 40 + random:Roll(3) * 6, 46)
end

-- Chevrons, one inside the other, pointing up or down
function PATTERNS.chevrons(random, sketch)
  local count = 4 + random:Roll(2)
  local up = random:Roll(2) == 1
  local top = 130 + random:Roll(3) * 8
  local step = (FIELD_BOTTOM - 70 - top) / (count - 1)
  local spread = 240 + random:Roll(4) * 15
  for index = 1, count do
    local y = top + (index - 1) * step
    local tip = up and y or y + 60
    local foot = up and y + 60 or y
    sketch:Line(SKY_WIDTH / 2 - spread, foot, SKY_WIDTH / 2, tip, floor(spread / 24))
  end
  sketch:Row(FIELD_BOTTOM - 2, 50, 54)
end

-- Arches over the middle, one inside another, with columns at the sides
function PATTERNS.arches(random, sketch)
  local cx, cy = SKY_WIDTH / 2, FIELD_BOTTOM + 30 + random:Roll(3) * 10
  local arches = 3 + random:Roll(2)
  for index = 1, arches do
    local r = 110 + index * 58
    local reach = min(1.45, 1.2 + index * 0.05)
    local count = floor(r * reach * 2 / 24)
    sketch:Arc(cx, cy, r, -1.5707963 - reach, -1.5707963, floor(count / 2) + 1)
  end
  local x = 40 + random:Roll(3) * 6
  sketch:Line(x, 150, x, FIELD_BOTTOM - 10, 8)
end

-- Waves across the sky, one under another
function PATTERNS.waves(random, sketch)
  local count = 4 + random:Roll(2)
  local top = 136 + random:Roll(3) * 6
  local step = (FIELD_BOTTOM - 26 - top) / (count - 1)
  local period = 220 + random:Roll(4) * 30
  local height = 14 + random:Roll(3) * 6
  for index = 1, count do
    sketch:Wave(top + (index - 1) * step, height, period, 32 + random:Roll(3) * 2, index * 1.2)
  end
end

-- A diamond lattice, with a hole cut in its middle and a ring in the hole
function PATTERNS.lattice(random, sketch)
  local gap = 50 + random:Roll(3) * 6
  local top = 130 + random:Roll(3) * 6
  local y, row = top, 0
  local hx, hy = SKY_WIDTH / 2, (top + FIELD_BOTTOM) / 2
  while y <= FIELD_BOTTOM do
    local x = row % 2 == 0 and SKY_WIDTH / 2 or SKY_WIDTH / 2 - gap / 2
    while x >= FIELD_LEFT do
      local dx, dy = x - hx, y - hy
      if dx * dx + dy * dy > 75 * 75 then
        sketch:Add(x, y)
      end
      x = x - gap
    end
    y, row = y + gap * 0.55, row + 1
  end
  sketch:Ring(hx, hy, 40, 10, 0)
end

-- A crescent moon lying on its back in the middle, rows of stars over it and a ring in its lap
function PATTERNS.crescent(random, sketch)
  local cy = 250 + random:Roll(3) * 8
  local r = 150 + random:Roll(3) * 8
  -- The outer edge, then the inner, higher up and smaller, so that they meet at the horns
  sketch:Arc(SKY_WIDTH / 2, cy, r, 3.1415926 * 0.08, 3.1415926 * 0.5, 9)
  sketch:Arc(SKY_WIDTH / 2, cy - r * 0.3, r * 0.82, 3.1415926 * 0.12, 3.1415926 * 0.5, 7)
  sketch:Ring(SKY_WIDTH / 2, cy + r * 0.05, 30, 8, 0.4)
  sketch:Row(132 + random:Roll(3) * 4, 40, 46)
  sketch:Row(176 + random:Roll(3) * 4, 63, 46)
  sketch:Line(44, 250, 70, FIELD_BOTTOM - 4, 7)
end

-- Two spirals, one either side, a line of stones down the middle and rows above and below
function PATTERNS.spirals(random, sketch)
  local cx, cy = 165 + random:Roll(3) * 5, 280 + random:Roll(3) * 8
  local a, r = random:Roll(6) * 0.5, 16
  local grow = 15 + random:Roll(3) * 2
  while r < 120 do
    sketch:Add(cx + r * cos(a), cy + r * sin(a))
    -- Stones a spacing apart along the curve, whatever the radius
    local stepA = 24 / r
    a, r = a + stepA, r + stepA * grow
  end
  sketch:Line(SKY_WIDTH / 2, 150, SKY_WIDTH / 2, FIELD_BOTTOM - 20, 9)
  sketch:Row(126, 36, 50)
  sketch:Row(FIELD_BOTTOM - 2, 60, 50)
end

local ORDER = { "rows", "rings", "chevrons", "arches", "waves", "lattice", "crescent", "spirals" }
Board.PATTERNS = ORDER

--- The stones of a pattern, near ones and those outside the field left out, top to bottom
--- @return number[][] { x, y } of each
local function lay(sketch)
  local laid = {}
  local points = sketch.points
  for index = 1, #points - 1, 2 do
    local x, y = half(points[index]), half(points[index + 1])
    if x >= FIELD_LEFT and x <= FIELD_RIGHT and y >= FIELD_TOP and y <= FIELD_BOTTOM then
      local clear = true
      for _, other in ipairs(laid) do
        local dx, dy = other[1] - x, other[2] - y
        if dx * dx + dy * dy < SPACING * SPACING then
          clear = false
          break
        end
      end
      if clear then
        laid[#laid + 1] = { x, y }
      end
    end
  end
  table.sort(laid, function(a, b)
    if a[2] ~= b[2] then
      return a[2] < b[2]
    end
    return a[1] < b[1]
  end)
  return laid
end

--- Picks the constellations out of the stones: each grows from a stone far from the others' by
--- taking the nearest stone to any of its own, until it is as big as it was meant to be
--- @param stones StarfallStone[]
--- @param sizes integer[]
--- @return integer[][] The stones of each, by index
local function constellations(random, stones, sizes)
  local taken, found, middles = {}, {}, {}
  for _, size in ipairs(sizes) do
    -- A stone to start from: of a few tried, the one furthest from where the others started
    local best, bestFar = nil, -1
    for _ = 1, 12 do
      local index = random:Roll(#stones)
      if not taken[index] then
        local far = 1e9
        for _, middle in ipairs(middles) do
          local dx, dy = stones[index].x - middle[1], stones[index].y - middle[2]
          far = min(far, dx * dx + dy * dy)
        end
        if far > bestFar then
          best, bestFar = index, far
        end
      end
    end
    if best then
      local members = { best }
      taken[best] = true
      while #members < size do
        -- Any stone near one of its stars may join it, which makes branching shapes rather
        -- than only chains
        local near = {}
        for index, stone in ipairs(stones) do
          if not taken[index] then
            for _, member in ipairs(members) do
              local dx, dy = stone.x - stones[member].x, stone.y - stones[member].y
              if dx * dx + dy * dy < 62 * 62 then
                near[#near + 1] = index
                break
              end
            end
          end
        end
        if #near == 0 then
          break
        end
        local chosen = near[random:Roll(#near)]
        members[#members + 1] = chosen
        taken[chosen] = true
      end
      -- One too small to be a constellation is given back
      if #members >= 3 then
        table.sort(members)
        found[#found + 1] = members
        middles[#middles + 1] = { stones[best].x, stones[best].y }
      else
        for _, member in ipairs(members) do
          taken[member] = nil
        end
      end
    end
  end
  return found
end

--- The lines a constellation is drawn with: each star joined to the nearest of those joined
--- already, the shortest way to join them all
--- @param stones StarfallStone[]
--- @param members integer[]
--- @return integer[] Pairs of stones, by index
local function joins(stones, members)
  local lines, inside = {}, { [members[1]] = true }
  for _ = 2, #members do
    local bestA, bestB, bestD = nil, nil, 1e18
    for _, a in ipairs(members) do
      if inside[a] then
        for _, b in ipairs(members) do
          if not inside[b] then
            local dx, dy = stones[a].x - stones[b].x, stones[a].y - stones[b].y
            local d = dx * dx + dy * dy
            if d < bestD then
              bestA, bestB, bestD = a, b, d
            end
          end
        end
      end
    end
    inside[bestB] = true
    lines[#lines + 1], lines[#lines + 2] = bestA, bestB
  end
  return lines
end

--- @class StarfallStone
--- @field x number
--- @field y number
--- @field kind string "stone", "star" or "wisp"
--- @field group integer? The constellation a star is in

--- @class StarfallConstellation
--- @field name string Which, from NAMES
--- @field stars integer[] Its stones
--- @field lines integer[] Pairs of its stones joined by its lines
--- @field woken boolean Every star of it has been lit

--- A night's sky, from chance
--- @param random Random
--- @param pattern string? The pattern to lay out, chosen by chance if not said
--- @return StarfallStone[] stones, StarfallConstellation[] constellations, string pattern
function Board.Make(random, pattern)
  pattern = pattern or ORDER[random:Roll(#ORDER)]
  local sketch = newSketch()
  PATTERNS[pattern](random, sketch)
  local stones = {}
  for _, point in ipairs(lay(sketch)) do
    stones[#stones + 1] = { x = point[1], y = point[2], kind = "stone" }
  end
  -- Five or six constellations of three to five stars, some 20 stars in all
  local sizes = { 5, 4, 4, 4, 3 }
  if random:Roll(2) == 1 then
    sizes = { 4, 4, 3, 3, 3, 3 }
  end
  local groups = constellations(random, stones, sizes)
  local names = {}
  for index = 1, #NAMES do
    names[index] = NAMES[index]
  end
  random:Shuffle(names)
  local made = {}
  for index, members in ipairs(groups) do
    for _, member in ipairs(members) do
      stones[member].kind, stones[member].group = "star", index
    end
    made[index] = { name = names[index], stars = members, lines = joins(stones, members), woken = false }
  end
  -- Two wisps among the moonstones left, apart from each other
  local wisps = 0
  for _ = 1, 40 do
    if wisps == 2 then
      break
    end
    local index = random:Roll(#stones)
    local stone = stones[index]
    if stone.kind == "stone" and stone.y > 160 and (wisps == 0 or stone.x < SKY_WIDTH / 2 ~= (made.wispLeft or false)) then
      stone.kind = "wisp"
      made.wispLeft = stone.x < SKY_WIDTH / 2
      wisps = wisps + 1
    end
  end
  made.wispLeft = nil
  return stones, made, pattern
end

--- Where the Moonwell lies for a shot, its left edge
--- @param place integer 1 to WELL_PLACES
--- @return number
function Board.WellLeft(place)
  return 8 + (SKY_WIDTH - 16 - WELL_WIDTH) * (place - 1) / (WELL_PLACES - 1)
end

--- A place for the Moonwell, another than the one it was at
--- @param random Random
--- @param was integer?
--- @return integer
function Board.NextWell(random, was)
  local place = random:Roll(WELL_PLACES - (was and 1 or 0))
  if was and place >= was then
    place = place + 1
  end
  return place
end

-----------------------------
-- A shot
-----------------------------

--- The way a star leaves at an aim, as a speed across and down
--- @param aim integer 0 to AIMS, tenths of a degree from straight left along the top, round
---   through straight down to straight right
--- @return number vx, number vy
function Board.Launch(aim)
  -- From straight down, turned towards the left below the middle aim and the right above it
  local a = (aim - AIMS / 2) / 10 * 3.141592653589793 / 180
  return LAUNCH_SPEED * sin(a), LAUNCH_SPEED * cos(a)
end

--- The world a shot is flown in: the walls, and every stone still in the sky
--- @param stones StarfallStone[]
--- @param gone boolean[]
--- @return PhysicsWorld world, table<integer, PhysicsShape> shapes The stones' shapes, by index
function Board.World(stones, gone)
  local world = Physics.New({
    width = SKY_WIDTH,
    height = SKY_HEIGHT + 40,
    hz = HZ,
    gravity = GRAVITY,
    fastest = FASTEST,
    radius = STONE_RADIUS,
    felt = 1,
  })
  local wall = { bounce = WALL_BOUNCE, friction = WALL_FRICTION }
  world:Segment(0, SKY_HEIGHT + 40, 0, 0, wall)
  world:Segment(0, 0, SKY_WIDTH, 0, wall)
  world:Segment(SKY_WIDTH, 0, SKY_WIDTH, SKY_HEIGHT + 40, wall)
  local shapes = {}
  for index, stone in ipairs(stones) do
    if not gone[index] then
      shapes[index] = world:Circle(stone.x, stone.y, STONE_RADIUS, { bounce = STONE_BOUNCE, friction = STONE_FRICTION, game = index })
    end
  end
  return world, shapes
end

--- @class StarfallFlight
--- @field from integer The tick the star was fired or the wisp flew off
--- @field path number[] x and y every SAMPLE ticks from then, the last where it left the sky
--- @field well boolean? It fell into the Moonwell

--- @class StarfallTouch
--- @field at integer The tick
--- @field stone integer
--- @field first boolean? The touch that lit it
--- @field flight integer Which of the shot's flights touched it

--- @class StarfallShot
--- @field aim integer
--- @field flights StarfallFlight[] The star, and the wisps that flew off
--- @field touches StarfallTouch[] In order
--- @field freed { at: integer, stone: integer }[] Stones taken away to free a star caught on them
--- @field lit integer[] Every stone lit, in the order they were
--- @field ticks integer How long it lasted
--- @field well boolean A star fell into the Moonwell
--- @field woken integer[] The constellations it woke
--- @field points integer Everything it scored, the night's end aside
--- @field chain integer What it was worth times over

--- Fires a star at an aim and flies it out, without changing anything
--- @param stones StarfallStone[]
--- @param gone boolean[] The stones already taken away
--- @param aim integer
--- @param wellLeft number Where the Moonwell is
--- @return StarfallShot
function Board.Fly(stones, gone, aim, wellLeft)
  local world, shapes = Board.World(stones, gone)
  local shot = { aim = aim, flights = {}, touches = {}, freed = {}, lit = {}, well = false }
  local lit, last = {}, {}
  local flights, balls = shot.flights, {}
  local lastNew, lastTouched = 0, nil

  local function fly(x, y, vx, vy)
    local ball = world:AddBall(x, y, STAR_RADIUS)
    world:Launch(ball, vx, vy)
    flights[#flights + 1] = { from = world.tick, path = { half(x), half(y) } }
    ball.flight = #flights
    balls[#balls + 1] = ball
    return ball
  end

  world.onEvent = function(kind, made, ball)
    if kind ~= "hit" or not made or not made.game then
      return
    end
    local index, tick = made.game, world.tick
    lastTouched = index
    local before = last[index]
    last[index] = tick
    if before and tick - before <= AGAIN then
      return
    end
    local touch = { at = tick, stone = index, flight = ball.flight }
    shot.touches[#shot.touches + 1] = touch
    if not lit[index] then
      lit[index] = true
      touch.first = true
      shot.lit[#shot.lit + 1] = index
      lastNew = tick
      if stones[index].kind == "wisp" then
        -- The wisp flies off, the way the star came at it but turned about
        world:Enable(made, false)
        local stone = stones[index]
        local speed = sqrt(ball.vx * ball.vx + ball.vy * ball.vy)
        local vx = -ball.vx
        local vy = -ball.vy
        if vy > -60 then
          vy = -60 - speed * 0.3
        end
        fly(stone.x, stone.y, vx, vy)
      end
    end
  end

  fly(LAUNCH_X, LAUNCH_Y, Board.Launch(aim))
  while #balls > 0 and world.tick < LONGEST do
    world:Tick()
    local tick = world.tick
    for index = #balls, 1, -1 do
      local ball = balls[index]
      local flight = flights[ball.flight]
      if (tick - flight.from) % SAMPLE == 0 or ball.y > SKY_HEIGHT + STAR_RADIUS then
        local path = flight.path
        path[#path + 1], path[#path + 2] = half(ball.x), half(ball.y)
      end
      if ball.y > SKY_HEIGHT + STAR_RADIUS then
        if ball.x >= wellLeft and ball.x <= wellLeft + WELL_WIDTH then
          flight.well = true
          shot.well = true
        end
        world:RemoveBall(ball)
        table.remove(balls, index)
      end
    end
    -- Caught: the stone touched last goes, lit if it wasn't
    if #balls > 0 and tick - lastNew >= STUCK and (tick - lastNew - STUCK) % UNSTICK == 0 and lastTouched and shapes[lastTouched].active then
      world:Enable(shapes[lastTouched], false)
      shot.freed[#shot.freed + 1] = { at = tick, stone = lastTouched }
      if not lit[lastTouched] then
        lit[lastTouched] = true
        shot.lit[#shot.lit + 1] = lastTouched
      end
    end
  end
  -- Too long: whatever is still flying is let go where it is
  for _, ball in ipairs(balls) do
    local path = flights[ball.flight].path
    path[#path + 1], path[#path + 2] = half(ball.x), half(ball.y)
  end
  shot.ticks = world.tick
  return shot
end

--- Fires a star into a night and takes what it did: the stones it lit gone, the points, the
--- constellations it woke and the Moonwell
--- @param state StarfallState
--- @param aim integer
--- @return StarfallShot
function Board.Shoot(state, aim)
  local stones, gone = state.stones, state.gone
  local shot = Board.Fly(stones, gone, aim, Board.WellLeft(state.well))
  local points = 0
  for _, index in ipairs(shot.lit) do
    gone[index] = true
    points = points + POINTS[stones[index].kind]
  end
  shot.chain = 1 + floor(#shot.lit / CHAIN)
  points = points * shot.chain
  shot.woken = {}
  for index, group in ipairs(state.constellations) do
    if not group.woken then
      local all = true
      for _, star in ipairs(group.stars) do
        all = all and gone[star] or false
      end
      if all then
        group.woken = true
        shot.woken[#shot.woken + 1] = index
        points = points + WOKEN * #group.stars
      end
    end
  end
  shot.points = points
  return shot
end

--- How many stars are still to light
--- @param state StarfallState
--- @return integer left, integer all
function Board.StarsLeft(state)
  local left, all = 0, 0
  for index, stone in ipairs(state.stones) do
    if stone.kind == "star" then
      all = all + 1
      if not state.gone[index] then
        left = left + 1
      end
    end
  end
  return left, all
end
