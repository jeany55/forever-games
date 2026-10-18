--------------------------
--  Physics
--------------------------
-- Balls rolling on a flat table, for a game played with them: pinball first, and anything else
-- where round things roll, bounce and get hit (pool, mini-golf, air hockey, pachinko).
--
-- A world is a table seen from above, measured in units (a pinball table counts millimetres), x
-- across to the right and y down, so gravity pulls towards the bottom, where the player is. What
-- the balls meet is of three kinds:
--   walls      a straight line between two points (Segment), or a round post (Circle). A wall can
--              be springy, give the ball a kick when it is hit hard enough (a pop bumper, a
--              slingshot), let the ball through from one side only (a gate), or be put away and
--              brought back (a drop target, a post that rises)
--   sensors    the same shapes, but felt rather than met: a ball rolls over them and the world
--              says so. A sensor can push a ball while it is on it (a ramp going uphill, a
--              magnet), hold a ball that comes to it slowly enough (a hole), or put the ball
--              on another layer of the table as it crosses (the mouth of a ramp)
--   paddles    a wall that turns about one end when it is held and back when it is let go,
--              thicker at that end than the other: a flipper
--   rails      a way through the air above the table, as high as it likes, that a ball rides
--              along and nothing else: a wire ramp, a corkscrew, a tube a ball is kicked up. A
--              ball gets on at a line sensor that says so, or when the game puts it on (Ride),
--              rides it pulled down the table and down towards the table, and gets off at its
--              end, or back at its start if it is too slow to climb it
-- Every ball is on one layer and every wall and sensor is on some, as a set of bits: a ball only
-- meets what is on its layer. A ramp is walls on a layer of their own, over the table's.
--
-- The world moves on in ticks of the same length, `hz` of them a second, whatever the screen
-- does: a game counts out as many ticks as the time that went by asks for, and the moves of the
-- player are put in between them. Two worlds made the same way that are given the same moves at
-- the same ticks come out the same, on any computer, so a game can be played back from its
-- moves alone. That is why nothing here uses math.sin, math.cos or anything else the client
-- works out its own way: only adding, taking away, multiplying, dividing and square roots,
-- which every computer does exactly alike, and sines of its own made from those.
--
-- A tick that would move the fastest ball more than a part of its size is cut into smaller steps,
-- so that no ball goes through a thin wall without touching it.

--- @type nil, ForeverGamesPrivate
local _, private = ...

local floor, sqrt, min, max, abs = math.floor, math.sqrt, math.min, math.max, math.abs

--- @class PhysicsShape
--- @field id integer In the order the shapes were made
--- @field kind string "segment", "circle", "box" or "paddle"
--- @field name string? What the game calls it, in what the world says of it
--- @field layers integer The layers it is on, as bits
--- @field sensor boolean? Felt, not met
--- @field active boolean Put away when false
--- @field bounce number How much of the speed it is hit with a ball keeps, 0 to 1
--- @field friction number How much it slows a ball rubbing along it
--- @field kick number? Speed it gives a ball that hits it hard enough, straight off it
--- @field trigger number? How hard is hard enough, the speed straight at it
--- @field oneWay boolean? A segment met only from the side its normal points to
--- @field push number[]? A sensor's pull on a ball while it is on it, x and y, in units a second each second
--- @field pull number? A circle sensor's pull towards its middle, the same
--- @field hole number? A circle sensor holds a ball that comes to it slower than this
--- @field front integer? A segment sensor puts a ball that crosses it to the front on this layer
--- @field back integer? And one that crosses it to the back on this one
--- @field rail PhysicsRail? A segment sensor puts a ball that crosses it to the front on this rail
--- @field x1 number
--- @field y1 number
--- @field x2 number?
--- @field y2 number?
--- @field nx number? A segment's normal, the left of the way from its first point to its second, y down
--- @field ny number?
--- @field length number?
--- @field r number? A circle's radius
--- @field game any Whatever the game keeps with it

--- @class PhysicsPaddle : PhysicsShape
--- @field length number From the middle of the end it turns on to the middle of the tip
--- @field base number Radius at the end it turns on
--- @field tip number Radius at the tip
--- @field rest number Angle it lies at when let go, radians, clockwise from pointing right, as y is down
--- @field up number Angle it lies at when held
--- @field speed number Fastest it turns, radians a second
--- @field accel number How quickly it gets to that, radians a second each second
--- @field fall number Fastest it turns back when let go
--- @field angle number Where it is
--- @field spin number How fast it turns now, radians a second, more clockwise
--- @field held boolean

--- @class PhysicsBall
--- @field id integer
--- @field x number
--- @field y number
--- @field vx number Units a second
--- @field vy number
--- @field r number
--- @field layer integer The one layer it is on, as a bit
--- @field held PhysicsShape? The hole it is held in
--- @field rail PhysicsRail? The rail it is riding
--- @field along number? How far along the rail it is
--- @field speed number? How fast it goes along the rail, below 0 going back
--- @field z number How high its underside is over the table: 0 but on a rail
--- @field on table<PhysicsShape, boolean> The sensors it is on
--- @field side table<PhysicsShape, number> Which side of each line sensor near it it was on last

--- @class PhysicsOptions
--- @field width number
--- @field height number
--- @field hz integer? Ticks a second, 1000 if not said
--- @field gravity number? Pull towards the bottom, units a second each second
--- @field cell number? How big the squares are that the world keeps its shapes in, to find what is near
--- @field roll number? How much of its speed a ball loses each second by rolling, 0 to 1
--- @field fastest number? No ball goes faster than this
--- @field radius number? The biggest a ball can be, so shapes are kept where any ball would touch them
--- @field felt number? A ball hitting a wall slower than this, straight at it, is only resting against it: it says nothing and rolls along it, 30 if not said
--- @field lift number? The pull down towards the table, which a ball climbing a rail goes against, units a second each second

--- @class PhysicsRail
--- @field id integer
--- @field name string?
--- @field points number[] x, y and z of each point in turn, z how high the ball's underside is there
--- @field at number[] How far along the rail each point is
--- @field length number How long it is
--- @field layer integer The layer a ball that gets off at its end is put on
--- @field back integer The layer a ball that rolls back off its start is put on
--- @field drag number How much of its speed a ball loses each second riding it
--- @field marks number[] How far along it each of its marks is, in order: the world says when a ball goes past one
--- @field game any Whatever the game keeps with it

--- @class PhysicsWorld
--- @field width number
--- @field height number
--- @field hz integer
--- @field tick integer How many ticks it has moved on
--- @field gravity number
--- @field roll number
--- @field fastest number
--- @field timeScale number How much of a tick of the game's time a tick is: below 1, everything is slowed
--- @field shapes PhysicsShape[]
--- @field paddles PhysicsPaddle[]
--- @field balls PhysicsBall[]
--- @field checks integer How many times a ball and a shape were tried against each other, since this was last set to 0
--- @field steps integer How many steps the ticks were cut into, the same
--- @field onEvent fun(kind: string, shape: PhysicsShape?, ball: PhysicsBall, speed: number?)? What the world has to say:
---   "hit" a ball hit a wall or paddle, with how hard, straight at it
---   "kick" and it was kicked off it
---   "enter", "leave" a ball came onto a sensor or went off it
---   "cross" a ball crossed a line sensor, with which way: 1 to the front, -1 to the back
---   "hold" a hole took a ball
---   "touch" two balls met (the shape is nil)
---   "board" a ball got on a rail (the rail is the shape), with how fast
---   "off" a ball got off a rail, with which end: 1 its end, -1 back at its start
---   "pass" a ball went past one of a rail's marks going along it, with which, the first 1
local Physics = {}
Physics.__index = Physics
private.Physics = Physics

local TAU = 6.283185307179586
local PI = TAU / 2

--- The sine of an angle in radians, the same on every computer
--- @param a number
--- @return number
local function sine(a)
  -- To between -pi and pi, then to between -pi/2 and pi/2, where the series is quickest
  a = a - TAU * floor(a / TAU + 0.5)
  if a > PI / 2 then
    a = PI - a
  elseif a < -PI / 2 then
    a = -PI - a
  end
  local a2 = a * a
  return a * (1 - a2 / 6 * (1 - a2 / 20 * (1 - a2 / 42 * (1 - a2 / 72 * (1 - a2 / 110 * (1 - a2 / 156))))))
end

--- @param a number
--- @return number
local function cosine(a)
  return sine(a + PI / 2)
end
Physics.Sin, Physics.Cos = sine, cosine

--- A world with nothing in it
--- @param options PhysicsOptions
--- @return PhysicsWorld
function Physics.New(options)
  local world = setmetatable({
    width = options.width,
    height = options.height,
    hz = options.hz or 1000,
    gravity = options.gravity or 0,
    roll = options.roll or 0,
    fastest = options.fastest or 1e9,
    radius = options.radius or 16,
    felt = options.felt or 30,
    lift = options.lift or 0,
    cell = options.cell or 32,
    timeScale = 1,
    tick = 0,
    shapes = {},
    paddles = {},
    rails = {},
    balls = {},
    nextBall = 0,
    checks = 0,
    steps = 0,
    left = 0,
    grid = {},
  }, Physics)
  world.columns = floor(world.width / world.cell) + 1
  world.rows = floor(world.height / world.cell) + 1
  return world
end

--- Keeps a shape in every square of the grid that a ball touching it could be in
local function file(world, shape, left, top, right, bottom)
  local reach, cell = world.radius, world.cell
  local c1 = max(0, floor((left - reach) / cell))
  local c2 = min(world.columns - 1, floor((right + reach) / cell))
  local r1 = max(0, floor((top - reach) / cell))
  local r2 = min(world.rows - 1, floor((bottom + reach) / cell))
  local grid = world.grid
  for row = r1, r2 do
    for column = c1, c2 do
      local key = row * world.columns + column + 1
      local list = grid[key]
      if not list then
        list = {}
        grid[key] = list
      end
      list[#list + 1] = shape
    end
  end
end

local function shape(world, kind, options)
  options = options or {}
  local made = {
    id = #world.shapes + 1,
    kind = kind,
    name = options.name,
    layers = options.layers or 1,
    sensor = options.sensor or nil,
    active = options.active ~= false,
    bounce = options.bounce or 0.5,
    friction = options.friction or 0.1,
    kick = options.kick,
    trigger = options.trigger or 0,
    oneWay = options.oneWay or nil,
    push = options.push,
    pull = options.pull,
    hole = options.hole,
    front = options.front,
    back = options.back,
    rail = options.rail,
    game = options.game,
  }
  world.shapes[made.id] = made
  return made
end

--- A straight wall, or sensor, from one point to another
--- @param x1 number
--- @param y1 number
--- @param x2 number
--- @param y2 number
--- @param options table? Any of PhysicsShape's fields that a game sets: name, layers, sensor, active, bounce, friction, kick, trigger, oneWay, front, back, and game, anything the game keeps with it
--- @return PhysicsShape
function Physics:Segment(x1, y1, x2, y2, options)
  local made = shape(self, "segment", options)
  local dx, dy = x2 - x1, y2 - y1
  local length = sqrt(dx * dx + dy * dy)
  made.x1, made.y1, made.x2, made.y2, made.length = x1, y1, x2, y2, length
  -- With y down, the left of the way along is (dy, -dx)
  made.nx, made.ny = dy / length, -dx / length
  file(self, made, min(x1, x2), min(y1, y2), max(x1, x2), max(y1, y2))
  return made
end

--- Walls from each point to the next
--- @param points number[] x and y of each point in turn
--- @param options table? As Segment's, for all of them
--- @return PhysicsShape[]
function Physics:Line(points, options)
  local made = {}
  for index = 1, #points - 3, 2 do
    made[#made + 1] = self:Segment(points[index], points[index + 1], points[index + 2], points[index + 3], options)
  end
  return made
end

--- A round post, or sensor
--- @param x number
--- @param y number
--- @param r number
--- @param options table? As Segment's, and push, pull and hole for a sensor
--- @return PhysicsShape
function Physics:Circle(x, y, r, options)
  local made = shape(self, "circle", options)
  made.x1, made.y1, made.r = x, y, r
  file(self, made, x - r, y - r, x + r, y + r)
  return made
end

--- A sensor over a rectangle, felt while a ball's middle is in it: the drain, a ramp's slope
--- @param left number
--- @param top number
--- @param right number
--- @param bottom number
--- @param options table? As Circle's
--- @return PhysicsShape
function Physics:Box(left, top, right, bottom, options)
  local made = shape(self, "box", options)
  made.sensor = true
  made.x1, made.y1, made.x2, made.y2 = left, top, right, bottom
  file(self, made, left, top, right, bottom)
  return made
end

--- A flipper
--- @param x number Where it turns
--- @param y number
--- @param options table As Segment's, and length, base, tip, rest, up, speed, accel and fall
--- @return PhysicsPaddle
function Physics:Paddle(x, y, options)
  local made = shape(self, "paddle", options)
  --- @cast made PhysicsPaddle
  made.x1, made.y1 = x, y
  made.length, made.base, made.tip = options.length, options.base, options.tip
  made.rest, made.up = options.rest, options.up
  made.speed, made.accel, made.fall = options.speed, options.accel, options.fall or options.speed
  made.angle, made.spin, made.held = options.rest, 0, false
  self.paddles[#self.paddles + 1] = made
  return made
end

--- A way through the air a ball rides along
--- @param points number[] x, y and z of each point in turn, z how high the ball's underside is there
--- @param options table? name, layer (where a ball gets off at the end, 1 if not said), back (where one rolling back off the start does, 1 if not said), drag, marks and game
--- @return PhysicsRail
function Physics:Rail(points, options)
  options = options or {}
  local at, length = { 0 }, 0
  for index = 4, #points - 2, 3 do
    local dx, dy, dz = points[index] - points[index - 3], points[index + 1] - points[index - 2], points[index + 2] - points[index - 1]
    length = length + sqrt(dx * dx + dy * dy + dz * dz)
    at[#at + 1] = length
  end
  local rail = {
    id = #self.rails + 1,
    name = options.name,
    points = points,
    at = at,
    length = length,
    layer = options.layer or 1,
    back = options.back or 1,
    drag = options.drag or 0,
    marks = options.marks or {},
    game = options.game,
  }
  self.rails[rail.id] = rail
  return rail
end

--- Puts a wall or sensor away, or brings it back
--- @param made PhysicsShape
--- @param active boolean
function Physics:Enable(made, active)
  made.active = active
end

--- Holds a paddle up, or lets it go
--- @param paddle PhysicsPaddle
--- @param held boolean
function Physics:Hold(paddle, held)
  paddle.held = held
end

--- @param x number
--- @param y number
--- @param r number
--- @param layer integer? 1 if not said
--- @return PhysicsBall
function Physics:AddBall(x, y, r, layer)
  self.nextBall = self.nextBall + 1
  local ball = { id = self.nextBall, x = x, y = y, z = 0, vx = 0, vy = 0, r = r, layer = layer or 1, on = {}, side = {} }
  self.balls[#self.balls + 1] = ball
  return ball
end

--- @param ball PhysicsBall
function Physics:RemoveBall(ball)
  for index, other in ipairs(self.balls) do
    if other == ball then
      table.remove(self.balls, index)
      return
    end
  end
end

--- Sets a ball going at that speed, out of a hole if it was held in one
--- @param ball PhysicsBall
--- @param vx number
--- @param vy number
function Physics:Launch(ball, vx, vy)
  ball.held = nil
  ball.vx, ball.vy = vx, vy
end

local say

--- Where along a rail a ball is: its place, and the way the rail goes there
local function onRail(ball)
  local rail, along = ball.rail, ball.along
  local at, p = rail.at, rail.points
  local index = ball.railIndex or 1
  while index < #at - 1 and along > at[index + 1] do
    index = index + 1
  end
  while index > 1 and along < at[index] do
    index = index - 1
  end
  ball.railIndex = index
  local span = at[index + 1] - at[index]
  local t = span > 0 and (along - at[index]) / span or 0
  t = t < 0 and 0 or (t > 1 and 1 or t)
  local i = index * 3 - 2
  local dx, dy, dz = p[i + 3] - p[i], p[i + 4] - p[i + 1], p[i + 5] - p[i + 2]
  ball.x, ball.y, ball.z = p[i] + dx * t, p[i + 1] + dy * t, p[i + 2] + dz * t
  return span > 0 and dx / span or 0, span > 0 and dy / span or 0, span > 0 and dz / span or 0
end

--- Puts a ball on a rail at its start, going along it at `speed`, out of a hole if it was held in one
--- @param ball PhysicsBall
--- @param rail PhysicsRail
--- @param speed number
function Physics:Ride(ball, rail, speed)
  ball.held = nil
  -- Off every sensor it was on, which it is above now
  for made in pairs(ball.on) do
    ball.on[made] = nil
    say(self, "leave", made, ball)
  end
  for made in pairs(ball.side) do
    ball.side[made] = nil
  end
  ball.rail, ball.along, ball.speed, ball.railIndex, ball.passed = rail, 0, speed, 1, 0
  ball.vx, ball.vy = 0, 0
  onRail(ball)
  say(self, "board", rail, ball, speed)
end

--- Gets a ball off its rail at one end, going on the way the rail went there, on the layer for that end
local function getOff(world, ball, ending)
  local rail = ball.rail
  local p = rail.points
  local i = ending == 1 and #p - 5 or 1
  local dx, dy = p[i + 3] - p[i], p[i + 4] - p[i + 1]
  local flat = sqrt(dx * dx + dy * dy)
  local speed = ball.speed < 0 and -ball.speed or ball.speed
  local way = ending == 1 and 1 or -1
  local j = ending == 1 and #p - 2 or 1
  ball.x, ball.y, ball.z = p[j], p[j + 1], 0
  ball.vx = flat > 0 and dx / flat * speed * way or 0
  ball.vy = flat > 0 and dy / flat * speed * way or 0
  ball.layer = ending == 1 and rail.layer or rail.back
  ball.rail, ball.along, ball.speed, ball.railIndex, ball.passed = nil, nil, nil, nil, nil
  say(world, "off", rail, ball, ending)
end

--- Moves a ball on along its rail by a step of `dt` seconds: pulled down the table, and down
--- towards it, which slows it climbing and speeds it falling
local function ride(world, ball, dt)
  local tx, ty, tz = onRail(ball)
  local speed = ball.speed + (world.gravity * ty - world.lift * tz) * dt
  speed = speed * (1 - ball.rail.drag * dt)
  ball.speed = speed
  ball.along = ball.along + speed * dt
  local marks = ball.rail.marks
  local next_ = ball.passed + 1
  if marks[next_] and ball.along >= marks[next_] then
    ball.passed = next_
    say(world, "pass", ball.rail, ball, next_)
  end
  if ball.along >= ball.rail.length then
    getOff(world, ball, 1)
  elseif ball.along <= 0 then
    getOff(world, ball, -1)
  else
    onRail(ball)
  end
end

--- Gives every ball that is rolling a knock, as the table being shoved does
--- @param vx number
--- @param vy number
function Physics:Nudge(vx, vy)
  for _, ball in ipairs(self.balls) do
    if not ball.held and not ball.rail then
      ball.vx, ball.vy = ball.vx + vx, ball.vy + vy
    end
  end
end

--- Where a paddle's tip is
--- @param paddle PhysicsPaddle
--- @return number x, number y
function Physics.Tip(paddle)
  return paddle.x1 + paddle.length * cosine(paddle.angle), paddle.y1 + paddle.length * sine(paddle.angle)
end

function say(world, kind, made, ball, speed)
  local listener = world.onEvent
  if listener then
    listener(kind, made, ball, speed)
  end
end

--- Turns a paddle on by a step of `dt` seconds, towards up while held and rest when not
local function turn(paddle, dt)
  local target = paddle.held and paddle.up or paddle.rest
  local way = target > paddle.angle and 1 or -1
  if paddle.angle == target then
    paddle.spin = 0
    return
  end
  local fastest = paddle.held and paddle.speed or paddle.fall
  -- Speeding up the way it has to go, from still or from going the other way
  local spin = paddle.spin * way
  spin = spin < 0 and 0 or spin
  spin = min(fastest, spin + paddle.accel * dt)
  local angle = paddle.angle + way * spin * dt
  if (angle - target) * way >= 0 then
    -- At the stop, where it is still
    paddle.angle, paddle.spin = target, 0
  else
    paddle.angle, paddle.spin = angle, way * spin
  end
end

--- Sends a ball off a wall it went into, by `depth` along the normal nx, ny, where the wall's
--- own speed there is wx, wy
local function bounce(world, ball, made, nx, ny, depth, wx, wy)
  ball.x, ball.y = ball.x + nx * depth, ball.y + ny * depth
  local rx, ry = ball.vx - wx, ball.vy - wy
  local into = rx * nx + ry * ny
  if into >= 0 then
    return
  end
  -- Straight off it as much as it bounces, and slowed along it by rubbing, never past still. A ball
  -- only resting against it rolls along it without rubbing: friction is in how it is hit
  local tx, ty = rx - into * nx, ry - into * ny
  local along = sqrt(tx * tx + ty * ty)
  local rub = -into > world.felt and made.friction * (1 + made.bounce) * -into or 0
  local keep = along > rub and (along - rub) / along or 0
  local out = -into * made.bounce
  ball.vx, ball.vy = wx + tx * keep + nx * out, wy + ty * keep + ny * out
  if -into >= world.felt then
    say(world, "hit", made, ball, -into)
  end
  if made.kick and -into >= made.trigger then
    ball.vx, ball.vy = ball.vx + nx * made.kick, ball.vy + ny * made.kick
    say(world, "kick", made, ball, -into)
  end
end

--- Where on a segment is nearest a point, as how far along it from 0 to 1
local function along(made, x, y)
  local t = ((x - made.x1) * (made.x2 - made.x1) + (y - made.y1) * (made.y2 - made.y1)) / (made.length * made.length)
  return t < 0 and 0 or (t > 1 and 1 or t)
end

local function feel(world, ball, made, touching)
  if made.front then
    -- A line: which side the ball's middle is on, while it is over the line and near it. Its side
    -- is forgotten as soon as it is anywhere else, so that only going through the line counts as
    -- crossing it, not going round its end
    local t = ((ball.x - made.x1) * (made.x2 - made.x1) + (ball.y - made.y1) * (made.y2 - made.y1)) / (made.length * made.length)
    local off = (ball.x - made.x1) * made.nx + (ball.y - made.y1) * made.ny
    if t >= 0 and t <= 1 and off < ball.r and off > -ball.r then
      local side = off >= 0 and 1 or -1
      local was = ball.side[made]
      if was and was ~= side then
        ball.layer = side == 1 and made.front or made.back
        say(world, "cross", made, ball, side)
        if made.rail and side == 1 then
          -- Onto the rail, as fast as it was going the way the rail starts
          local p = made.rail.points
          local dx, dy, dz = p[4] - p[1], p[5] - p[2], p[6] - p[3]
          local length = sqrt(dx * dx + dy * dy + dz * dz)
          local speed = (ball.vx * dx + ball.vy * dy) / length
          Physics.Ride(world, ball, made.rail, speed > 0 and speed or 0)
          return
        end
      end
      ball.side[made] = side
    else
      ball.side[made] = nil
    end
    return
  end
  local on = ball.on[made]
  if touching and not on then
    ball.on[made] = true
    say(world, "enter", made, ball)
  elseif on and not touching then
    ball.on[made] = nil
    say(world, "leave", made, ball)
  end
end

--- What a ball meets of one shape in a step
local function meet(world, ball, made, dt)
  world.checks = world.checks + 1
  local bx, by, r = ball.x, ball.y, ball.r
  if made.kind == "circle" then
    local dx, dy = bx - made.x1, by - made.y1
    local d2 = dx * dx + dy * dy
    local reach = r + made.r
    if made.sensor then
      -- Felt while the ball's middle is on it
      local touching = d2 < made.r * made.r
      if touching then
        local hole = made.hole
        if hole and ball.vx * ball.vx + ball.vy * ball.vy < hole * hole then
          ball.held, ball.x, ball.y, ball.vx, ball.vy = made, made.x1, made.y1, 0, 0
          say(world, "hold", made, ball)
          return
        end
        if made.pull and d2 > 0 then
          local d = sqrt(d2)
          ball.vx, ball.vy = ball.vx - dx / d * made.pull * dt, ball.vy - dy / d * made.pull * dt
        end
        if made.push then
          ball.vx, ball.vy = ball.vx + made.push[1] * dt, ball.vy + made.push[2] * dt
        end
      end
      feel(world, ball, made, touching)
      return
    end
    if d2 < reach * reach and d2 > 0 then
      local d = sqrt(d2)
      bounce(world, ball, made, dx / d, dy / d, reach - d, 0, 0)
    end
    return
  end

  if made.kind == "box" then
    local touching = bx >= made.x1 and bx <= made.x2 and by >= made.y1 and by <= made.y2
    if touching and made.push then
      ball.vx, ball.vy = ball.vx + made.push[1] * dt, ball.vy + made.push[2] * dt
    end
    feel(world, ball, made, touching)
    return
  end

  if made.kind == "segment" then
    local t = along(made, bx, by)
    local px, py = made.x1 + (made.x2 - made.x1) * t, made.y1 + (made.y2 - made.y1) * t
    local dx, dy = bx - px, by - py
    local d2 = dx * dx + dy * dy
    if made.sensor then
      feel(world, ball, made, d2 < r * r)
      return
    end
    if d2 < r * r and d2 > 0 then
      if made.oneWay and (bx - made.x1) * made.nx + (by - made.y1) * made.ny < 0 then
        return
      end
      local d = sqrt(d2)
      bounce(world, ball, made, dx / d, dy / d, r - d, 0, 0)
    end
    return
  end

  -- A paddle: the nearest point on the line through its middle, and how thick it is there
  --- @cast made PhysicsPaddle
  local cx, cy = made.x1, made.y1
  local ex, ey = made.ex, made.ey
  local lx, ly = ex - cx, ey - cy
  local t = ((bx - cx) * lx + (by - cy) * ly) / (made.length * made.length)
  t = t < 0 and 0 or (t > 1 and 1 or t)
  local px, py = cx + lx * t, cy + ly * t
  local thick = made.base + (made.tip - made.base) * t
  local dx, dy = bx - px, by - py
  local d2 = dx * dx + dy * dy
  local reach = r + thick
  if d2 < reach * reach and d2 > 0 then
    local d = sqrt(d2)
    local nx, ny = dx / d, dy / d
    -- How fast the paddle's edge goes where the ball touches it: turning about cx, cy
    local sx, sy = px + nx * thick - cx, py + ny * thick - cy
    bounce(world, ball, made, nx, ny, reach - d, -made.spin * sy, made.spin * sx)
  end
end

local candidates, seen = {}, {}

--- Moves everything on by one step of `dt` seconds
local function step(world, dt)
  for _, paddle in ipairs(world.paddles) do
    turn(paddle, dt)
    paddle.ex, paddle.ey = Physics.Tip(paddle)
  end
  local balls, grid, cell, columns = world.balls, world.grid, world.cell, world.columns
  local gravity, keep, fastest = world.gravity * dt, 1 - world.roll * dt, world.fastest
  for _, ball in ipairs(balls) do
    if ball.rail then
      ride(world, ball, dt)
    elseif not ball.held then
      ball.vy = ball.vy + gravity
      ball.vx, ball.vy = ball.vx * keep, ball.vy * keep
      local speed2 = ball.vx * ball.vx + ball.vy * ball.vy
      if speed2 > fastest * fastest then
        local slow = fastest / sqrt(speed2)
        ball.vx, ball.vy = ball.vx * slow, ball.vy * slow
      end
      ball.x, ball.y = ball.x + ball.vx * dt, ball.y + ball.vy * dt

      -- What is near, each shape once, in the order they were made
      local column = min(columns - 1, max(0, floor(ball.x / cell)))
      local row = min(world.rows - 1, max(0, floor(ball.y / cell)))
      local list = grid[row * columns + column + 1]
      local count = 0
      if list then
        for index = 1, #list do
          local made = list[index]
          if made.active and made.layers % (ball.layer * 2) >= ball.layer then
            count = count + 1
            candidates[count] = made
          end
        end
      end
      -- The sensors the ball was on and isn't near any more are left, and the lines it was by
      -- are forgotten
      for made in pairs(ball.on) do
        seen[made] = true
      end
      for made in pairs(ball.side) do
        seen[made] = true
      end
      for index = 1, count do
        local made = candidates[index]
        seen[made] = nil
        meet(world, ball, made, dt)
        if ball.held or ball.rail then
          break
        end
      end
      for made in pairs(seen) do
        seen[made] = nil
        ball.side[made] = nil
        if ball.on[made] and not ball.held then
          ball.on[made] = nil
          say(world, "leave", made, ball)
        end
      end
      if not ball.held and not ball.rail then
        for _, paddle in ipairs(world.paddles) do
          if paddle.active and paddle.layers % (ball.layer * 2) >= ball.layer then
            meet(world, ball, paddle, dt)
          end
        end
      end
    end
  end

  -- Balls against each other, all of the same weight
  for i = 1, #balls - 1 do
    local one = balls[i]
    for j = i + 1, #balls do
      local other = balls[j]
      if one.layer == other.layer and not (one.held and other.held) and not one.rail and not other.rail then
        local dx, dy = other.x - one.x, other.y - one.y
        local reach = one.r + other.r
        local d2 = dx * dx + dy * dy
        if d2 < reach * reach and d2 > 0 then
          local d = sqrt(d2)
          local nx, ny = dx / d, dy / d
          local apart = (reach - d) / 2
          if one.held then
            other.x, other.y = other.x + nx * apart * 2, other.y + ny * apart * 2
          elseif other.held then
            one.x, one.y = one.x - nx * apart * 2, one.y - ny * apart * 2
          else
            one.x, one.y = one.x - nx * apart, one.y - ny * apart
            other.x, other.y = other.x + nx * apart, other.y + ny * apart
          end
          local closing = (one.vx - other.vx) * nx + (one.vy - other.vy) * ny
          if closing > 0 then
            if one.held then
              other.vx, other.vy = other.vx + nx * closing * 2, other.vy + ny * closing * 2
            elseif other.held then
              one.vx, one.vy = one.vx - nx * closing * 2, one.vy - ny * closing * 2
            else
              one.vx, one.vy = one.vx - nx * closing, one.vy - ny * closing
              other.vx, other.vy = other.vx + nx * closing, other.vy + ny * closing
            end
            say(world, "touch", nil, one, closing)
          end
        end
      end
    end
  end
end

--- Moves everything on by one tick
function Physics:Tick()
  self.tick = self.tick + 1
  local dt = self.timeScale / self.hz
  -- As many steps as keep the fastest ball from going more than a third of its size in one
  local fastest, smallest = 0, self.radius
  for _, ball in ipairs(self.balls) do
    if not ball.held and not ball.rail then
      local speed2 = ball.vx * ball.vx + ball.vy * ball.vy
      fastest = speed2 > fastest and speed2 or fastest
      smallest = ball.r < smallest and ball.r or smallest
    end
  end
  local steps = max(1, floor(sqrt(fastest) * dt / (smallest / 3)) + 1)
  self.steps = self.steps + steps
  for _ = 1, steps do
    step(self, dt / steps)
  end
end

--- Moves the world on by as many ticks as `seconds` of time make, keeping what is left over for
--- the next time. Calls `before(tick)` ahead of each, for the moves to be put in
--- @param seconds number
--- @param before fun(tick: integer)?
--- @param most integer? No more ticks than this at once, however long it was
--- @return integer ticks How many it moved on
function Physics:Advance(seconds, before, most)
  self.left = self.left + seconds * self.hz
  local count = floor(self.left)
  if most and count > most then
    count, self.left = most, 0
  else
    self.left = self.left - count
  end
  for _ = 1, count do
    if before then
      before(self.tick + 1)
    end
    self:Tick()
  end
  return count
end

--- How far into the next tick the time given to Advance has got, 0 to 1, for drawing between ticks
--- @return number
function Physics:Between()
  return self.left
end
