--------------------------
--  Pinball: the table
--------------------------
-- Makes the world the ball rolls in from the table (Images/Table.lua) and the settings: for the
-- game, for the bench that tries it out (Tools/PinballBench), and for Shots.lua there, which tries
-- shots from the terminal.

local _, ns = ...
local Physics = ns.Physics

-- What the table plays with, which the bench can change with "set". The materials' bounce and friction
-- come from the table, as "rubber.bounce" and the like
ns.DEFAULTS = {
  hz = 1000,
  gravity = 1500, -- mm/s each second down the table: a real one, tilted 6.5 degrees, is about 1100
  roll = 0.03, -- how much of its speed a ball loses each second rolling
  fastest = 7000, -- mm/s
  flipperSpeed = 40, -- radians a second at most, up
  flipperAccel = 25000, -- radians a second each second: a coil gets it to full speed in a couple of milliseconds
  flipperFall = 25, -- radians a second at most, back down
  bumperKick = 1400, -- mm/s a pop bumper adds
  slingKick = 1300,
  plunger = 4300, -- mm/s, pulled all the way back
  pullSeconds = 0.9, -- to pull it all the way back
  saucerKick = 1100,
  saucerSeconds = 1.2,
  kickback = 3400,
  nudge = 260, -- mm/s a nudge gives every ball
  lift = 9000, -- mm/s each second down towards the table, which a ball climbing the ramp or a wire goes against
  wellKick = 2300, -- mm/s the Moonwell kicks a ball up its tube
  frostSeconds = 1.5, -- how long Frost Nova holds the balls frozen where they are
  frostCooldown = 12, -- seconds from casting it to when it can be cast again
  wallSeconds = 10, -- how long Shield Wall keeps the post between the flippers up
  wallCooldown = 20,
  saveSeconds = 10, -- a ball lost this soon after it was plunged is given back
  rotation = 1, -- -1 turns the flippers' pictures the other way, if they turn wrong
}

--- A world with the table in it, and its shapes by name
--- @return PhysicsWorld, table<string, PhysicsShape>
function ns.Build(tune, hz)
  local table_ = ns.Table
  local world = Physics.New({ width = table_.width, height = table_.height, hz = hz or tune.hz, gravity = tune.gravity,
    roll = tune.roll, fastest = tune.fastest, radius = table_.ball + 2, cell = 32, lift = tune.lift })
  local named = {}
  -- The wires first, for the lines that put a ball on one to find
  for _, rail in ipairs(table_.rails or {}) do
    named[rail.name] = world:Rail(rail.points, { name = rail.name, layer = rail.layer, back = rail.back, drag = rail.drag,
      marks = rail.marks, game = rail })
  end
  for _, shape in ipairs(table_.shapes) do
    local material = shape.material
    local o = {
      name = shape.name,
      layers = shape.layers,
      sensor = shape.sensor,
      active = shape.active,
      bounce = shape.bounce or (material and tune[material .. ".bounce"]),
      friction = shape.friction or (material and tune[material .. ".friction"]),
      kick = shape.kick and (shape.role == "bumper" and tune.bumperKick or shape.role == "sling" and tune.slingKick or shape.kick),
      trigger = shape.trigger,
      oneWay = shape.oneWay,
      -- A slope pulls the ball down it as much more than the table does as it is steep
      push = shape.slope and { 0, shape.slope * tune.lift } or shape.push,
      rail = shape.rail and named[shape.rail],
      pull = shape.pull,
      hole = shape.hole,
      front = shape.front,
      back = shape.back,
      game = shape,
    }
    local made
    if shape.kind == "line" then
      made = world:Line(shape.points, o)
      made = #made == 1 and made[1] or made
    elseif shape.kind == "circle" then
      made = world:Circle(shape.x, shape.y, shape.r, o)
    elseif shape.kind == "box" then
      made = world:Box(shape.left, shape.top, shape.right, shape.bottom, o)
    elseif shape.kind == "paddle" then
      o.length, o.base, o.tip, o.rest, o.up = shape.length, shape.base, shape.tip, shape.rest, shape.up
      o.speed, o.accel, o.fall = tune.flipperSpeed, tune.flipperAccel, tune.flipperFall
      made = world:Paddle(shape.x, shape.y, o)
    end
    if shape.name then
      named[shape.name] = made
    end
  end
  return world, named
end
