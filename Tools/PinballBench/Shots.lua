--------------------------
--  Pinball Bench: shots
--------------------------
-- Tries the table from the terminal, without the client: what each flipper's shot hits for every
-- moment it can be flipped at, how far each pull of the plunger sends the ball, and whether balls
-- thrown about the table at random ever get stuck or out of it. For changing the table or the
-- settings and seeing at once whether the shots can still be made.
--
--   lua Tools/PinballBench/Shots.lua [folder with Table.lua] [setting=value ...]
--
-- from the repository's folder, after python3 Tools/make_pinball.py <folder>.

local folder = arg[1] or "ForeverGames_Pinball/Images"
local ns = {}
local function load(path)
  assert(loadfile(path))("PinballBench", ns)
end
load("Engine/Physics.lua")
load(folder .. "/Table.lua")
load("ForeverGames_Pinball/Build.lua")

local tune = {}
for key, value in pairs(ns.DEFAULTS) do
  tune[key] = value
end
for name, material in pairs(ns.Table.materials) do
  tune[name .. ".bounce"], tune[name .. ".friction"] = material.bounce, material.friction
end
for index = 2, #arg do
  local key, value = arg[index]:match("^([%w%.]+)=([%d%.%-]+)$")
  assert(key and tune[key] ~= nil, "no such setting: " .. arg[index])
  tune[key] = tonumber(value)
end

--- What a ball does first that counts as a shot, within `seconds`
local GOALS = {
  { kind = "pass", name = "rampWire", what = "RAMP" },
  { kind = "hold", name = "saucer", what = "saucer" },
  { kind = "enter", name = "spinner", what = "left orbit" },
  { kind = "enter", name = "rightOrbit", what = "right orbit" },
  { kind = "hit", role = "standup", what = "standup" },
  { kind = "hit", role = "target", what = "target" },
  { kind = "enter", role = "rollover", pattern = "^lane%d", what = "lane" },
  { kind = "enter", name = "drain", what = "drain" },
}

local function watch(world, seconds, onTick)
  local first, bumpers, ramp
  world.onEvent = function(kind, made)
    if not made or first then
      return
    end
    if kind == "kick" and made.game.role == "bumper" then
      bumpers = (bumpers or 0) + 1
    end
    if kind == "cross" and made.name == "rampIn" then
      ramp = true
    end
    for _, goal in ipairs(GOALS) do
      if kind == goal.kind and (goal.name == nil or goal.name == made.name) and (goal.role == nil or goal.role == made.game.role)
        and (goal.pattern == nil or (made.name or ""):find(goal.pattern)) then
        first = goal.what
        return
      end
    end
  end
  for tick = 1, seconds * world.hz do
    if onTick then
      onTick(tick)
    end
    world:Tick()
    if first then
      break
    end
  end
  local text = first or (ramp and "ramp, fell back" or "nothing")
  if bumpers then
    text = text .. (" (%d bumpers)"):format(bumpers)
  end
  return text, first
end

-- Each flipper, the ball rolling down its inlane, flipped at a moment after it was let go
print("Flipper shots: the ball let go at the top of the inlane, flipped that many ms later")
local start = { left = { 71, 700 }, right = { 2 * ns.Table.middle - 71, 700 } }
for _, side in ipairs({ "left", "right" }) do
  local line = {}
  local counts = {}
  for delay = 800, 1500, 20 do
    local world, named = ns.Build(tune)
    local paddle = named[side .. "Flipper"]
    world:AddBall(start[side][1], start[side][2], ns.Table.ball)
    local text, first = watch(world, 3, function(tick)
      if tick == delay then
        world:Hold(paddle, true)
      elseif tick == delay + 300 then
        world:Hold(paddle, false)
      end
    end)
    counts[first or "nothing"] = (counts[first or "nothing"] or 0) + 1
    line[#line + 1] = ("  %s %4d ms: %s"):format(side, delay, text)
  end
  print(table.concat(line, "\n"))
  local summary = {}
  for what, count in pairs(counts) do
    summary[#summary + 1] = what .. " " .. count
  end
  table.sort(summary)
  print("  " .. side .. ": " .. table.concat(summary, ", "))
end

-- The shot players aim: the ball caught on the held flipper, let go, and flipped again as it rolls
-- down it, the later the nearer the tip it is hit
print("\nFrom a cradle: the ball caught on the held flipper, let go, flipped again that many ms later")
for _, side in ipairs({ "left", "right" }) do
  local line = {}
  for delay = 0, 700, 20 do
    local world, named = ns.Build(tune)
    local paddle = named[side .. "Flipper"]
    local ball = world:AddBall(start[side][1], start[side][2], ns.Table.ball)
    world:Hold(paddle, true)
    for _ = 1, 2500 do
      world:Tick()
    end
    local cradled = math.abs(ball.vx) + math.abs(ball.vy) < 30
    world:Hold(paddle, false)
    -- How the ball leaves the flipper: the first moment it is going up faster than it ever is
    -- again, the angle from straight up (to the right is more), and where that line crosses the
    -- ramp's mouth
    local fastest, aim = 0, nil
    local text = watch(world, 3, function(tick)
      if tick == delay + 1 then
        world:Hold(paddle, true)
      elseif tick == delay + 300 then
        world:Hold(paddle, false)
      end
      local speed = math.sqrt(ball.vx * ball.vx + ball.vy * ball.vy)
      if tick > delay and tick < delay + 120 and ball.vy < 0 and speed > fastest then
        fastest = speed
        aim = ("%+3.0f deg %4.0f mm/s, crosses y=600 at x=%3.0f"):format(math.deg(math.atan2(ball.vx, -ball.vy)), speed,
          ball.x + ball.vx * (600 - ball.y) / ball.vy)
      end
    end)
    line[#line + 1] = ("    %3d ms: %-28s %s"):format(delay, cradled and text or "not cradled", aim or "")
  end
  print("  " .. side .. "\n" .. table.concat(line, "\n"))
end

print("\nThe plunger, pulled back that far")
for pull = 0.3, 1.001, 0.1 do
  local world = ns.Build(tune)
  local ball = world:AddBall(ns.Table.start[1], ns.Table.start[2], ns.Table.ball)
  world:Tick()
  world:Launch(ball, 0, -tune.plunger * pull)
  local highest = ball.y
  local text = watch(world, 4, function()
    highest = math.min(highest, ball.y)
  end)
  print(("  %3d%%: %s, as high as y = %d"):format(pull * 100 + 0.5, text, highest))
end

-- Balls thrown about at random, flippers going when a ball is near: lost, stuck, or out
print("\nBalls thrown about at random for 20 seconds each, flipping when one comes near")
local seed = 12345
local function random()
  seed = (seed * 1103515245 + 12345) % 2147483648
  return seed / 2147483648
end
local stuck, out, drained, throws = 0, 0, 0, 200
for _ = 1, throws do
  local world, named = ns.Build(tune)
  local ball = world:AddBall(60 + random() * 360, 180 + random() * 500, ns.Table.ball)
  world:Launch(ball, (random() - 0.5) * 4000, (random() - 0.5) * 4000)
  local still, gone = 0, false
  world.onEvent = function(kind, made)
    if kind == "enter" and made and made.name == "drain" then
      gone = true
    elseif kind == "hold" then
      world:Ride(ball, named.wellWire, tune.wellKick)
    elseif kind == "hit" and made and made.game and made.game.role == "target" then
      world:Enable(made, false)
    end
  end
  for tick = 1, 20 * world.hz do
    for _, paddle in ipairs(world.paddles) do
      local dx, dy = ball.x - paddle.x1, ball.y - paddle.y1
      world:Hold(paddle, ball.layer == 1 and dy < 30 and dy > -60 and dx * dx + dy * dy < 100 * 100 and (tick % 600) < 200)
    end
    world:Tick()
    if gone then
      drained = drained + 1
      break
    end
    if ball.x < 0 or ball.x > ns.Table.width or ball.y < 0 or ball.y > ns.Table.height + 20 then
      out = out + 1
      print(("  out of the table at %.0f, %.0f"):format(ball.x, ball.y))
      break
    end
    local inShooter = ball.x > 464 and ball.y > 900
    if not ball.held and not ball.rail and not inShooter and ball.vx * ball.vx + ball.vy * ball.vy < 20 * 20 then
      still = still + 1
      if still > 3 * world.hz then
        stuck = stuck + 1
        print(("  stuck at %.0f, %.0f on layer %d"):format(ball.x, ball.y, ball.layer))
        break
      end
    else
      still = 0
    end
  end
end
print(("  %d throws: %d lost down the drain, %d stuck, %d out of the table"):format(throws, drained, stuck, out))

-- The wires: each ridden from its start, as fast as the game puts a ball on it, and where the ball
-- gets off, how fast, and how long it took
print("\nThe wires, ridden from their starts")
for _, ride in ipairs({ { "rampWire", 600 }, { "rampWire", 350 }, { "wellWire", tune.wellKick }, { "wellWire", 1400 } }) do
  local world, named = ns.Build(tune)
  local rail = named[ride[1]]
  local ball = world:AddBall(0, 0, ns.Table.ball)
  local ending
  world.onEvent = function(kind, _, _, extra)
    if kind == "off" then
      ending = extra
    end
  end
  world:Ride(ball, rail, ride[2])
  local slowest = math.huge
  local ticks = 0
  while ball.rail and ticks < 10 * world.hz do
    world:Tick()
    ticks = ticks + 1
    if ball.rail then
      slowest = math.min(slowest, ball.speed)
    end
  end
  print(("  %s at %4d mm/s: off %s at %.0f, %.0f, %4.0f mm/s, after %.2f s, slowest %.0f mm/s"):format(ride[1], ride[2],
    ending == 1 and "its end" or ending == -1 and "its start" or "nowhere", ball.x, ball.y,
    math.sqrt(ball.vx * ball.vx + ball.vy * ball.vy), ticks / world.hz, slowest))
end
