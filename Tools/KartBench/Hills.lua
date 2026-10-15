--------------------------
--  Kart Bench: hills
--------------------------
-- A course with hills in it, to tell whether it can be drawn quickly enough and how it looks:
-- the engine's own course (Engine/Course.lua, made by Tools/make_course.py) drawn by its terrain
-- view (GUI/TerrainView.lua), both copied in by install.sh. This file only drives round it.
--
-- Karts stand on the ground. A kart that goes over a crest faster than it can fall leaves the
-- ground, and each course has a kicker that throws them into the air.
--
--   /kartbench hills [options]       the camera drives round by itself, measured
--   /kartbench hilldrive [options]   you drive, Escape stops
--
-- Options as for plane and drive, and: course <name> (tanaris if not said, or meadow), bands <n>
-- (how many bands across, 16), ground own|client (the course's picture over the client's own
-- ground, tried first, or with its own ground in it), strips (hills' outlines in strips, as a
-- client without masks draws them). rows <n> is how many rows below the horizon, as for plane.

local _, ns = ...
local say = ns.say
local min, max, abs = math.min, math.max, math.abs
local cos, sin, atan2 = math.cos, math.sin, math.atan2

local COURSE = "tanaris"
-- How quickly a kart falls, units a second each second, and how quickly the camera rises and falls after it
local GRAVITY, CAMERA_FOLLOWS = 150, 8
local BANDS = 16
-- How far round from the start line to count crossing it
local LINE = 100

-- The views made so far, by bands and whether they cut outlines with masks, and the one in use
local views = {}
local view

--- Puts the karts on the ground, or in the air over it
local function lift(bench, elapsed)
  local course = bench.course
  for _, kart in ipairs(bench.karts) do
    if kart.x then
      local ground = course:Height(kart.x, kart.y)
      if not kart.z then
        kart.z, kart.vz = ground, 0
      elseif kart.air then
        kart.vz = kart.vz - GRAVITY * elapsed
        kart.z = kart.z + kart.vz * elapsed
        if kart.z <= ground then
          kart.z, kart.vz, kart.air = ground, 0, false
        end
      else
        -- Following the ground it would rise or fall this fast. If that is falling faster than it
        -- can, it flies on instead
        local climb = (ground - kart.z) / elapsed
        if climb < kart.vz - GRAVITY * elapsed * 1.5 then
          kart.air = true
          kart.vz = kart.vz - GRAVITY * elapsed
          kart.z = kart.z + kart.vz * elapsed
        else
          kart.z, kart.vz = ground, climb
        end
      end
    end
  end
end

--- Where the camera is and which way it looks, after moving everything on by `elapsed`: the
--- karts round the road by themselves, and the one driven as it is driven
local function move(bench, elapsed)
  local course = bench.course
  for index, kart in ipairs(bench.karts) do
    if not (index == 1 and bench.car) then
      kart.progress = kart.progress + kart.speed * elapsed
      kart.x, kart.y, kart.heading = course:Along(kart.progress, kart.side)
    end
  end

  local car = bench.car
  if not car then
    local mine = bench.karts[1]
    local x, y = course:Along(mine.progress - ns.CAMERA_BACK, 0)
    return x, y, atan2(mine.y - y, mine.x - x)
  end

  -- Driven: off the road the kart can't go fast, and it turns only as it moves
  local driving, keys = ns.DRIVING, bench.keys
  local top = course:OnRoad(car.offset) and driving.top or driving.grassTop
  if keys.up then
    car.speed = min(max(top, car.speed), car.speed + driving.accelerate * elapsed)
  elseif keys.down then
    car.speed = max(-20, car.speed - driving.brake * elapsed)
  elseif car.speed > 0 then
    car.speed = max(0, car.speed - driving.coast * elapsed)
  else
    car.speed = min(0, car.speed + driving.coast * elapsed)
  end
  if car.speed > top then
    car.speed = max(top, car.speed - 90 * elapsed)
  end
  local steer = (keys.left and -1 or 0) + (keys.right and 1 or 0)
  local grip = min(1, abs(car.speed) / 30) * (car.speed < 0 and -1 or 1)
  car.heading = car.heading + steer * driving.turn * grip * elapsed
  local world = course.world
  car.x = min(world + 150, max(-150, car.x + cos(car.heading) * car.speed * elapsed))
  car.y = min(world + 150, max(-150, car.y + sin(car.heading) * car.speed * elapsed))

  -- Across the line forwards starts a lap and ends the last, backwards spoils it
  local was = car.progress
  car.progress, car.offset, car.hint = course:Locate(car.x, car.y, car.hint)
  local length = course.length
  if was > length - LINE and car.progress < LINE and course:OnRoad(car.offset) then
    if bench.lapStart then
      local lap = bench.time - bench.lapStart
      bench.best = bench.best and min(bench.best, lap) or lap
      say(("Lap %.2f s (best %.2f s)"):format(lap, bench.best))
    end
    bench.lapStart = bench.time
  elseif was < LINE and car.progress > length - LINE then
    bench.lapStart = nil
  end

  local mine = bench.karts[1]
  mine.x, mine.y, mine.heading = car.x, car.y, car.heading
  -- The camera swings round behind the kart, or with no lag is fixed behind it
  local lag = bench.options.lag
  bench.camHeading = lag > 0 and ns.turnTowards(bench.camHeading, car.heading, min(1, elapsed * lag)) or car.heading
  local heading = bench.camHeading
  return car.x - cos(heading) * ns.CAMERA_BACK, car.y - sin(heading) * ns.CAMERA_BACK, heading
end

--- The karts, as things for the view to draw: the first `models` of them the client's models (your
--- character, a creature's display, or a racer's mount), the rest pictures
local function setupKarts(bench)
  local o, course = bench.options, bench.course
  bench.things = {}
  for index = 1, o.karts do
    local colour = ns.COLOURS[(index - 1) % #ns.COLOURS + 1]
    local kart = { progress = (index - 1) * 20, side = index == 1 and 0 or (index % 2 == 0 and -11 or 11),
      speed = ns.SPEED * (index == 1 and 1 or 0.94 + 0.12 * ((index * 37) % 11) / 10) }
    kart.x, kart.y, kart.heading = course:Along(kart.progress, kart.side)
    local thing = { alpha = o.ghost and 0.5 or 1 }
    if index <= o.models then
      thing.size, thing.animation = ns.MODEL_SIZE, 5
      thing.display = o.display or (o.mounts and ns.racer(index)) or nil
      thing.unit = not thing.display and "player" or nil
    else
      thing.size, thing.sprite, thing.colour = ns.KART_SIZE, ns.IMAGES .. "kart", colour
    end
    kart.thing = thing
    bench.karts[index] = kart
    bench.things[index] = thing
  end
  if bench.drives then
    local x, y, heading = course:Along(-20, 0)
    local progress, offset, hint = course:Locate(x, y)
    bench.car = { x = x, y = y, heading = heading, speed = 0, progress = progress, offset = offset, hint = hint }
    bench.camHeading = heading
    pcall(ns.frame.EnableKeyboard, ns.frame, true)
  end
end

local function start(bench)
  local o = bench.options
  local course = ns.Course and ns.Course.Load(o.course or COURSE)
  if not course then
    say(("No course %s: run Tools/KartBench/install.sh to make it"):format(o.course or COURSE))
    return
  end
  bench.course = course
  bench.bands = max(2, min(96, o.bands or BANDS))
  bench.drives = bench.kind == "hilldrive"
  bench.endless = bench.drives or o.endless

  local key = bench.bands .. (o.strips and " strips" or "")
  view = views[key]
  if not view then
    view = ns.TerrainView.New(ns.frame, { width = ns.WIDTH, height = ns.HEIGHT, horizon = ns.HORIZON, focal = ns.FOCAL,
      folder = ns.IMAGES, bands = bench.bands, masks = not o.strips })
    views[key] = view
  end
  view.filter = o.nearest and "NEAREST" or nil
  view.options.ground = o.ground
  view:Rows(o.rows, 132, ns.CAMERA_HEIGHT)
  view:Layout(bench.scale)
  local loaded = view:SetCourse(course)
  bench.loaded.track, bench.loaded.tile = loaded.overlay, loaded.tile
  setupKarts(bench)
  bench.camZ = nil
  view.split.cast, view.split.fill, view.split.things, view.split.frames = 0, 0, 0, 0
end

local function update(bench, elapsed)
  if not bench.course then
    return 0
  end
  local camX, camY, heading = move(bench, elapsed)
  lift(bench, elapsed)
  for _, kart in ipairs(bench.karts) do
    local thing = kart.thing
    thing.x, thing.y, thing.z, thing.heading = kart.x, kart.y, kart.z, kart.heading
  end
  -- The camera rides above the kart it follows, and never inside a hill
  local mine = bench.karts[1]
  local wanted = max(mine.z + ns.CAMERA_HEIGHT, bench.course:Height(camX, camY) + 4)
  bench.camZ = bench.camZ and bench.camZ + (wanted - bench.camZ) * min(1, elapsed * CAMERA_FOLLOWS) or wanted
  bench.camera = bench.camera or {}
  local camera = bench.camera
  camera.x, camera.y, camera.z, camera.heading = camX, camY, bench.camZ, heading
  local drawn = view:Draw(camera, bench.things)
  -- What the scenes found the first time they were drawn
  if view.calibration and view.calibration ~= bench.told then
    bench.told = view.calibration
    say(view.calibration)
  end
  return drawn
end

local function describe(bench)
  local o = bench.options
  local karts = o.models > 0 and ("%d karts, %d of them models"):format(o.karts, o.models) or ("%d karts"):format(o.karts)
  local split = view and view.split
  local times = split and split.frames > 0 and ("\n[rays %.2f ms, cells %.2f ms, things %.2f ms]"):format(split.cast / split.frames,
    split.fill / split.frames, split.things / split.frames) or ""
  local ground = view and (view.client and "client ground" or "own ground") or ""
  return ("%s %s, %d rows by %d bands (%d cells), %s, %s%s%s%s"):format(bench.kind, bench.course and bench.course.name or "?",
    view and #view.edges - 1 or 0, bench.bands or 0, view and view.cellCount or 0, ground, karts,
    view and not view.masked and ", strips" or "", bench.drives and ", lag " .. o.lag or "", times)
end

-- The run whose karts are drawn, to hide them when it stops
local shown

local mode = {
  start = function(bench)
    shown = bench
    start(bench)
  end,
  update = update,
  describe = describe,
  hide = function()
    if view then
      view:Hide()
      for _, thing in ipairs(shown and shown.things or {}) do
        view:Forget(thing)
      end
    end
  end,
}
ns.modes.hills, ns.modes.hilldrive = mode, mode

for _, name in ipairs({ "hills", "hilldrive" }) do
  ns.commands[name] = {
    usage = "[options, course <name>, bands <n>, ground own|client, strips]: " .. (name == "hills" and "a course with hills in it" or "and you drive"),
    run = function(words)
      local options = ns.parse(words, 2)
      if not options then
        return false
      end
      options.kind = name
      ns.start(options)
      if name == "hilldrive" then
        say("Arrows or WASD to drive, Escape to stop")
      end
      return true
    end,
  }
end
