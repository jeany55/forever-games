--------------------------
--  Pinball: the rules
--------------------------
-- A game of pinball on the table, as much of Tools/PinballBench/DESIGN.md as is built: what scores,
-- what lights what, the quests, the raid, the spells. Everything here happens in a tick of the
-- physics (Engine/Physics.lua), from what the world says and the moves the player makes, so a
-- game played again from its moves comes out the same, score and all. These are the rules of a
-- ball rolling, played out many times a second in the view (Machine.lua); Forever Games' own
-- rules for the game (Pinball.lua) only hear how it ended.
--
-- What there is:
--   levels       experience for every shot, a level every so much of it, 1 to 60. Every tenth
--                level is a talent point, collected at the saucer (the trainer)
--   top lanes    roll through all three to raise the bonus multiplier, up to 5x. The flippers move
--                the lit lanes left and right. A plunge into the lane that is flashing is the
--                skill shot
--   quests       eight, one after another: the drop targets light the next at the saucer, the
--                saucer starts it, and it has to be done in time (QUESTS)
--   raid         three quests done light the raid at the saucer: three balls, the ramp a jackpot,
--                three jackpots light the super jackpot at the saucer
--   extra ball   every tenth ramp lights it on the ramp
--   ball save    for a while after every plunge, and at the start of the raid
--   kickback     lit at the start, and by the drop targets or 25 spins of the spinner
--   bonus        at the end of every ball, for what was made in it, times the multiplier
--   tilt         more than three nudges in three seconds: the flippers die until the ball is gone
--   spells       two of the classes' actives, on keys for now, each with its cooldown: Frost Nova
--                freezes every ball on the playfield where it is for a moment, then lets it drop;
--                Shield Wall raises the post between the flippers for a while
--
-- A game can also stand idle (NewGame's idle): no ball, nothing scored, only the flippers working,
-- for the machine waiting to be played.
--
-- What happens that is worth showing or hearing is told to ns.Cue(what, ...), which the bench
-- sets: the rules know nothing of lights, pictures or sounds.

local _, ns = ...

local floor, min, max, abs, pi = math.floor, math.min, math.max, math.abs, math.pi

ns.Rules = {}
local Rules = ns.Rules

-- Points, and experience, for what is made
local POINTS = {
  bumper = 130, sling = 10, target = 750, bank = 7500, spin = 120, ramp = 5000, saucer = 2500,
  rollover = 500, lanes = 10000, kickback = 1000, inlane = 1000, outlane = 2500, standup = 1500,
  orbit = 4000, combo = 15000, skillShot = 50000, jackpot = 250000, superJackpot = 1000000,
  questDone = 100000, extraBall = 25000, talent = 20000,
}
local XP = {
  bumper = 4, sling = 1, target = 15, bank = 60, spin = 1, ramp = 60, saucer = 20, rollover = 8,
  lanes = 60, standup = 20, orbit = 50, combo = 120, skillShot = 250, jackpot = 400, superJackpot = 1200,
  questDone = 500, inlane = 10, outlane = 10,
}
local BALLS = 3
local HIGHEST = 60
-- Seconds two orbits may be apart and still make a combo
local COMBO_SECONDS = 3

-- The quests, in order: what has to be made, how many, and in how long
local QUESTS = {
  { name = "KILL 10 DEFIAS", shot = "bumper", count = 10, seconds = 30 },
  { name = "DEEPRUN TRAM", shot = "ramp", count = 2, seconds = 30 },
  { name = "GNOLL PAWS", shot = "spin", count = 30, seconds = 30 },
  { name = "HOGGER", shot = "standup", count = 3, seconds = 30 },
  { name = "WESTFALL PATROL", shot = "orbit", count = 3, seconds = 35 },
  { name = "THE DEFIAS BROTHERHOOD", shot = "target", count = 6, seconds = 35 },
  { name = "THE NIGHT WATCH", shot = "lane", count = 4, seconds = 35 },
  { name = "ONYXIA'S SCALE", shot = "ramp", count = 3, seconds = 40 },
}
Rules.QUESTS = QUESTS

--- @type table The game being played, set by NewGame
local game
local tune

local function cue(what, ...)
  if ns.Cue then
    ns.Cue(what, ...)
  end
end

local function seconds(count)
  return floor(count * game.world.hz + 0.5)
end

local function after(ticks, run)
  table.insert(game.timers, { tick = game.world.tick + ticks, run = run })
end

-- What holds a ball Frost Nova froze, in the place of the hole that holds one
local FROZEN = { kind = "frost", name = "frost" }
Rules.FROZEN = FROZEN

--- How much experience a level takes to reach from the one before
local function needed(level)
  return 150 + level * 35
end

local function award(what, times)
  times = times or 1
  game.score = game.score + (POINTS[what] or 0) * times
  if game.tilted then
    return
  end
  local xp = (XP[what] or 0) * times
  if xp <= 0 or game.level >= HIGHEST then
    return
  end
  game.xp = game.xp + xp
  while game.level < HIGHEST and game.xp >= needed(game.level + 1) do
    game.xp = game.xp - needed(game.level + 1)
    game.level = game.level + 1
    if game.level % 10 == 0 then
      game.talents = game.talents + 1
      cue("talentLit", game.level)
    else
      cue("levelUp", game.level)
    end
  end
end

--- How far into the ten levels to the next talent point the player is, 0 to 1
function Rules.TierProgress(state)
  local within = state.level % 10
  return (within + state.xp / needed(state.level + 1)) / 10
end

--- A ball in the shooter lane, on the plunger, or sent up it at once
local function serve(launch)
  local start = ns.Table.start
  local world = game.world
  -- Further down the lane for every ball already in it, so they don't sit inside each other
  local y = start[2]
  for _, other in ipairs(world.balls) do
    if abs(other.x - start[1]) < 2 and abs(other.y - y) < ns.Table.ball * 2 then
      y = y - ns.Table.ball * 2 - 1
    end
  end
  local ball = world:AddBall(start[1], y, ns.Table.ball)
  if launch then
    world:Launch(ball, 0, -tune.plunger * launch)
  end
  cue("ballServe")
  return ball
end

local function newBall()
  game.saveUntil, game.tilted, game.warnings = nil, false, {}
  game.made = { ramps = 0, orbits = 0, targets = 0, bumpers = 0, lanes = 0 }
  -- The skill shot: one of the lanes flashing until the plunged ball reaches the lanes or misses
  game.skillLane = 1 + game.world.tick % 3
  serve()
end

local function endQuest(done)
  local quest = game.quest
  if not quest then
    return
  end
  game.quest = nil
  if done then
    game.questsDone = game.questsDone + 1
    award("questDone")
    cue("questComplete", quest.name, game.questsDone)
    if game.questsDone % 3 == 0 and not game.raid then
      game.raidLit = true
      cue("raidLit")
    end
  else
    cue("questFailed", quest.name)
  end
end

--- Counts a shot towards the quest running, if it is that quest's
local function progress(shot, times)
  local quest = game.quest
  if not quest or quest.shot ~= shot then
    return
  end
  quest.made = min(quest.count, quest.made + (times or 1))
  cue("questStep", quest.name, quest.made, quest.count)
  if quest.made >= quest.count then
    endQuest(true)
  end
end

local function endRaid()
  game.raid = nil
  cue("raidOver")
end

--- What a ball that went down the drain leaves: another ball, a ball saved, the next ball or the
--- end of the game
local function drained(ball)
  local world = game.world
  world:RemoveBall(ball)
  cue("drain", #world.balls)
  if game.keep then
    serve(0.85 + (world.tick % 7) / 50)
    return
  end
  if #world.balls > 0 then
    if game.raid and #world.balls == 1 then
      endRaid()
    end
    return
  end
  if game.saveUntil and world.tick <= game.saveUntil and not game.tilted then
    cue("ballSave")
    serve(0.9)
    return
  end
  if game.raid then
    endRaid()
  end
  endQuest(false)
  -- The bonus, unless the table was tilted
  local made = game.made
  local bonus = (made.ramps * 5000 + made.orbits * 3000 + made.targets * 750 + made.bumpers * 100 + made.lanes * 1000
    + game.level * 1000) * game.multiplier
  if game.tilted then
    bonus = 0
  end
  game.score = game.score + bonus
  cue("bonus", bonus, game.multiplier, made)
  game.multiplier = 1
  if game.extraBalls > 0 then
    game.extraBalls = game.extraBalls - 1
    cue("shootAgain")
    newBall()
    return
  end
  if game.ball >= BALLS then
    game.over = true
    cue("gameOver", game.score)
    return
  end
  game.ball = game.ball + 1
  cue("nextBall", game.ball)
  newBall()
end

local function resetTargets()
  for index = 1, 3 do
    game.world:Enable(game.named["target" .. index], true)
  end
  cue("targetsReset")
end

local function laneMade(index)
  if game.skillLane then
    local skill = game.skillLane == index
    game.skillLane = nil
    if skill then
      award("skillShot")
      cue("skillShot")
    end
  end
  progress("lane")
  game.made.lanes = game.made.lanes + 1
  if game.lanes[index] then
    award("rollover")
    return
  end
  game.lanes[index] = true
  award("rollover")
  if game.lanes[1] and game.lanes[2] and game.lanes[3] then
    game.lanes = {}
    award("lanes")
    game.multiplier = min(5, game.multiplier + 1)
    cue("multiplier", game.multiplier)
  end
end

local function orbitMade(side)
  award("orbit")
  game.made.orbits = game.made.orbits + 1
  progress("orbit")
  -- The other orbit soon after is a combo
  local last = game.lastOrbit
  if last and last.side ~= side and game.world.tick - last.tick < seconds(COMBO_SECONDS) then
    award("combo")
    cue("combo")
    game.lastOrbit = nil
  else
    game.lastOrbit = { side = side, tick = game.world.tick }
  end
  cue("orbit", side)
end

local function saucer(ball)
  award("saucer")
  cue("saucerIn")
  local hold = tune.saucerSeconds
  if game.talents > 0 then
    -- The trainer: a talent point is learned
    game.talents = game.talents - 1
    award("talent")
    cue("talent", game.level)
    hold = hold + 1
  elseif game.raid and game.raid.superLit then
    game.raid.superLit = false
    game.raid.jackpots = 0
    award("superJackpot")
    cue("superJackpot")
    hold = hold + 1
  elseif game.raidLit then
    game.raidLit = false
    game.raid = { jackpots = 0 }
    game.saveUntil = game.world.tick + seconds(15)
    cue("multiball")
    -- Two more balls, one after the other
    after(seconds(1), function()
      serve(0.95)
    end)
    after(seconds(2), function()
      serve(0.95)
    end)
    hold = hold + 1.5
  elseif game.questLit and not game.quest then
    game.questLit = false
    local quest = QUESTS[(game.questsStarted % #QUESTS) + 1]
    game.questsStarted = game.questsStarted + 1
    game.quest = { name = quest.name, shot = quest.shot, count = quest.count, made = 0,
      ends = game.world.tick + seconds(quest.seconds + hold) }
    cue("questStart", quest.name, quest.count)
    hold = hold + 1
  end
  after(seconds(hold), function()
    -- Up the Moonwell's glass tube, onto its wire, and round to the right inlane
    game.world:Ride(ball, game.named.wellWire, tune.wellKick)
    cue("saucerKick")
  end)
end

--- What the world says, as the rules hear it
local function heard(kind, made, ball, extra)
  if kind == "touch" then
    cue("ballHit", extra)
    return
  end
  if not made then
    return
  end
  local shape = made.game
  local role, name = shape and shape.role, made.name
  if kind == "hit" then
    if role == "target" and made.active then
      game.world:Enable(made, false)
      award("target")
      game.made.targets = game.made.targets + 1
      progress("target")
      cue("targetDrop", name)
      local down = 0
      for index = 1, 3 do
        down = down + (game.named["target" .. index].active and 0 or 1)
      end
      if down == 3 then
        award("bank")
        game.kickback = true
        game.questLit = true
        cue("bank")
        after(seconds(1), resetTargets)
      end
    elseif role == "standup" then
      award("standup")
      progress("standup")
      cue("standup", name)
    elseif role == "flipper" then
      cue("flipperHit", extra)
    elseif name == "centerPost" then
      cue("shieldBlock", extra)
    elseif role == "rail" or role == "gate" or role == "ramp" then
      cue("railHit", extra)
    elseif role == "post" or role == "sling" then
      if not made.kick then
        cue("rubberHit", extra)
      end
    end
    return
  end
  if kind == "kick" and role == "bumper" then
    award("bumper")
    game.made.bumpers = game.made.bumpers + 1
    progress("bumper")
    cue("bumper", name)
  elseif kind == "kick" and role == "sling" then
    award("sling")
    cue("sling", name)
  elseif kind == "enter" and role == "spinner" then
    local spins = max(1, floor(abs(ball.vy) / 150))
    award("spin", spins)
    progress("spin", spins)
    game.spins = game.spins + spins
    if game.spins >= 25 then
      game.spins = game.spins - 25
      if not game.kickback then
        game.kickback = true
        cue("kickbackLit")
      end
    end
    cue("spinner", spins)
    if ball.vy < 0 then
      orbitMade("left")
    end
  elseif kind == "enter" and role == "orbit" then
    if ball.vy < 0 then
      orbitMade("right")
    end
  elseif kind == "enter" and role == "rollover" then
    local lane = name:match("^lane(%d)")
    if lane then
      laneMade(tonumber(lane))
    elseif name:find("Inlane") then
      award("inlane")
      cue("rollover", name)
    else
      award("outlane")
      cue("outlane", name)
    end
  elseif kind == "cross" and name == "rampIn" and extra == 1 then
    cue("rampEnter")
  elseif kind == "pass" and name == "rampWire" then
    award("ramp")
    game.ramps = game.ramps + 1
    game.made.ramps = game.made.ramps + 1
    progress("ramp")
    if game.raid then
      game.raid.jackpots = game.raid.jackpots + 1
      award("jackpot")
      cue("jackpot", game.raid.jackpots)
      if game.raid.jackpots >= 3 then
        game.raid.superLit = true
      end
    elseif game.extraLit then
      game.extraLit = false
      game.extraBalls = game.extraBalls + 1
      award("extraBall")
      cue("extraBall")
    else
      cue("rampMade", game.ramps)
    end
    if game.ramps % 10 == 0 then
      game.extraLit = true
    end
  elseif kind == "board" then
    cue("wireOn", name)
  elseif kind == "off" then
    cue("wireOff", name, extra)
  elseif kind == "hold" and role == "saucer" then
    saucer(ball)
  elseif kind == "enter" and role == "kickback" and game.kickback and not game.keep then
    game.kickback = false
    award("kickback")
    game.world:Launch(ball, 0, -tune.kickback)
    cue("kickback")
  elseif kind == "enter" and role == "drain" then
    ball.drained = true
  elseif kind == "enter" and role == "plunger" then
    game.inShooter = ball
  elseif kind == "leave" and role == "plunger" then
    if game.inShooter == ball then
      game.inShooter = nil
    end
    -- Plunged: the ball is saved for a while
    if ball.vy < 0 and not game.saveUntil then
      game.saveUntil = game.world.tick + seconds(tune.saveSeconds)
    end
  end
end

--- Starts a game
--- @param settings table The bench's settings
--- @param options table robot, keep (balls kept on the table for measuring), replaying, hz
--- @return table game
function Rules.NewGame(settings, options)
  tune = settings
  local world, named = ns.Build(tune, options.hz)
  local paddles = { left = {}, right = {} }
  for _, paddle in ipairs(world.paddles) do
    local side = paddle.game.side
    table.insert(paddles[side], paddle)
  end
  game = {
    world = world,
    named = named,
    paddles = paddles,
    inputs = {},
    queue = {},
    timers = {},
    score = 0,
    ball = 1,
    over = false,
    lanes = {},
    ramps = 0,
    spins = 0,
    xp = 0,
    level = 1,
    talents = 0,
    multiplier = 1,
    questsStarted = 0,
    questsDone = 0,
    extraBalls = 0,
    kickback = true,
    robot = options.robot,
    keep = options.keep,
    replaying = options.replaying,
    wasReplay = options.replaying and true or nil,
    hz = world.hz,
    warnings = {},
    made = { ramps = 0, orbits = 0, targets = 0, bumpers = 0, lanes = 0 },
    -- When each spell can be cast again, and when it was last, in ticks
    spellReady = {},
    spellCast = {},
    -- What the robot did last with each side's flippers, and when
    robotAt = { left = -1e9, right = -1e9 },
  }
  world.onEvent = heard
  if options.idle then
    game.idle, game.over = true, true
  elseif options.keep then
    for _ = 1, options.keep do
      serve(0.8 + #world.balls * 0.03)
    end
  else
    newBall()
  end
  return game
end

--- How far the plunger is pulled back now, 0 to 1
function Rules.Pulled(state)
  return state.pull and min(1, (state.world.tick - state.pull) / floor(tune.pullSeconds * state.world.hz + 0.5)) or 0
end

-- What each move does, when its tick comes
local ACTIONS = {}
Rules.ACTIONS = ACTIONS

local function hold(side, held)
  for _, paddle in ipairs(game.paddles[side]) do
    game.world:Hold(paddle, held)
  end
end

--- The flipper buttons also move the lit top lanes along: the left to the left, the right to the right
local function laneChange(way)
  local lanes = game.lanes
  if way < 0 then
    game.lanes = { lanes[2], lanes[3], lanes[1] }
  else
    game.lanes = { lanes[3], lanes[1], lanes[2] }
  end
end

function ACTIONS.leftDown()
  if not game.tilted then
    hold("left", true)
    laneChange(-1)
    cue("flipperUp", "left")
  end
end
function ACTIONS.leftUp()
  if game.paddles.left[1].held then
    cue("flipperDown", "left")
  end
  hold("left", false)
end
function ACTIONS.rightDown()
  if not game.tilted then
    hold("right", true)
    laneChange(1)
    cue("flipperUp", "right")
  end
end
function ACTIONS.rightUp()
  if game.paddles.right[1].held then
    cue("flipperDown", "right")
  end
  hold("right", false)
end
function ACTIONS.plungerDown()
  game.pull = game.world.tick
  cue("plungerPull")
end
function ACTIONS.plungerUp()
  if not game.pull then
    return
  end
  local pulled = Rules.Pulled(game)
  game.pull = nil
  local ball = game.inShooter
  if ball and not ball.held then
    game.world:Launch(ball, 0, -tune.plunger * pulled)
  end
  cue("plungerRelease", pulled)
end

local function nudge(vx, vy)
  if game.tilted then
    return
  end
  game.world:Nudge(vx * tune.nudge, vy * tune.nudge)
  -- More than three in three seconds tilts the table
  local now = game.world.tick
  local recent = {}
  for _, at in ipairs(game.warnings) do
    if now - at < seconds(3) then
      recent[#recent + 1] = at
    end
  end
  recent[#recent + 1] = now
  game.warnings = recent
  if #recent > 3 and not game.keep then
    game.tilted = true
    hold("left", false)
    hold("right", false)
    endQuest(false)
    cue("tilt")
  elseif #recent >= 2 then
    cue("tiltWarning", #recent)
  else
    cue("nudge")
  end
end

function ACTIONS.nudgeLeft()
  nudge(1, -0.4)
end
function ACTIONS.nudgeRight()
  nudge(-1, -0.4)
end
function ACTIONS.nudgeUp()
  nudge(0, -1)
end
--- Whether a spell can be cast now, its cooldown over
local function ready(spell)
  return not game.over and game.world.tick >= (game.spellReady[spell] or 0)
end

function ACTIONS.frost()
  local world = game.world
  if not ready("frost") then
    return
  end
  game.spellReady.frost = world.tick + seconds(tune.frostCooldown)
  game.spellCast.frost = world.tick
  -- Every ball rolling on the playfield, but not one in the shooter lane, held where it is
  local frozen = {}
  for _, ball in ipairs(world.balls) do
    if not ball.held and not ball.rail and ball.layer == 1 and ball ~= game.inShooter then
      ball.held, ball.vx, ball.vy = FROZEN, 0, 0
      frozen[#frozen + 1] = ball
    end
  end
  cue("frostNova", #frozen)
  after(seconds(tune.frostSeconds), function()
    for _, ball in ipairs(frozen) do
      if ball.held == FROZEN then
        world:Launch(ball, 0, 0)
      end
    end
    cue("frostEnd", #frozen)
  end)
end
function ACTIONS.post()
  local post = game.named.centerPost
  if post.active or not ready("wall") then
    return
  end
  local world = game.world
  game.spellReady.wall = world.tick + seconds(tune.wallCooldown)
  game.spellCast.wall = world.tick
  world:Enable(post, true)
  cue("shieldWall")
  after(seconds(tune.wallSeconds), function()
    world:Enable(post, false)
    cue("shieldDown")
  end)
end

--- How each spell stands: how many seconds until it can be cast again (0 when it can), out of how
--- long its cooldown is, and how many seconds it has still to run if it is running
function Rules.Spells(state)
  local world = state.world
  local out = {}
  for _, spell in ipairs({ { "frost", tune.frostCooldown, tune.frostSeconds }, { "wall", tune.wallCooldown, tune.wallSeconds } }) do
    local name, cooldown, lasts = spell[1], spell[2], spell[3]
    local readyAt, castAt = state.spellReady[name] or 0, state.spellCast[name]
    local running = castAt and lasts - (world.tick - castAt) / world.hz or 0
    out[name] = { left = max(0, (readyAt - world.tick) / world.hz), cooldown = cooldown, running = max(0, running),
      lasts = lasts }
  end
  return out
end
function ACTIONS.kickback()
  game.kickback = true
  cue("kickbackLit")
end
function ACTIONS.ball()
  serve(0.85)
end

--- The robot's moves for this tick: a side's flippers go up when a ball comes down towards one of
--- them, and the plunger is pulled for a ball in the shooter lane
local function robot(tick)
  local world = game.world
  for side, paddles in pairs(game.paddles) do
    local at = game.robotAt[side]
    if paddles[1].held then
      if tick - at > seconds(0.15) then
        game.queue[#game.queue + 1] = side .. "Up"
        game.robotAt[side] = tick
      end
    elseif tick - at > seconds(0.2) then
      local go = false
      for _, paddle in ipairs(paddles) do
        for _, ball in ipairs(world.balls) do
          if ball.layer == 1 and not ball.held and ball.vy > -200 then
            local dx, dy = ball.x - paddle.x1, ball.y - paddle.y1
            local reach = paddle.length + ball.r + 18
            local towards = side == "left" and dx > -15 or dx < 15
            if towards and dy < 40 and dy > -70 and dx * dx + dy * dy < reach * reach then
              go = true
            end
          end
        end
      end
      if go then
        game.queue[#game.queue + 1] = side .. "Down"
        game.robotAt[side] = tick
      end
    end
  end
  local ball = game.inShooter
  if ball and abs(ball.vy) < 1 and not game.pull then
    game.robotPull = (game.robotPull or 0) + 1
    if game.robotPull > seconds(0.4) then
      game.queue[#game.queue + 1] = "plungerDown"
      game.robotPull = 0
      game.robotLet = tick + seconds(0.7 + (tick % 5) / 25)
    end
  end
  if game.pull and game.robotLet and tick >= game.robotLet then
    game.queue[#game.queue + 1] = "plungerUp"
    game.robotLet = nil
  end
end

--- Everything that goes in at a tick: the balls lost in the last, the moves, the timers
function Rules.BeforeTick(tick)
  local world = game.world
  for index = #world.balls, 1, -1 do
    local ball = world.balls[index]
    if ball.drained then
      drained(ball)
    end
  end
  if game.replaying then
    local inputs = game.replaying.inputs
    while game.replayAt <= #inputs and inputs[game.replayAt].tick == tick do
      ACTIONS[inputs[game.replayAt].action]()
      game.replayAt = game.replayAt + 1
    end
  else
    if game.robot then
      robot(tick)
    end
    for index, action in ipairs(game.queue) do
      game.queue[index] = nil
      game.inputs[#game.inputs + 1] = { tick = tick, action = action }
      ACTIONS[action]()
    end
  end
  local timers = game.timers
  local index = 1
  while index <= #timers do
    local timer = timers[index]
    if timer.tick <= tick then
      table.remove(timers, index)
      timer.run()
    else
      index = index + 1
    end
  end
  if game.quest and tick >= game.quest.ends then
    endQuest(false)
  end
end
