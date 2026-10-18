-- Pinball's own tests, run with Forever Games' (lua Tests/RunTests.lua Pinball). The checks every
-- game is put through (Tests/EveryGame.lua) are run on it as well, EveryGame_pinball.
--
-- Handed the tests to add to, the engine to load, and what Forever Games' tests are written with.
-- Not listed in the .toc, so the game client never loads it.
return function(tests, loadEngine, helpers)
  local equal = helpers.equal

  --- The game's own table (what the client gives the addon), with the settings the table plays with
  local function pinball()
    local private = loadEngine()
    local own = private.plugins.ForeverGames_Pinball
    local tune = {}
    for key, value in pairs(own.DEFAULTS) do
      tune[key] = value
    end
    for name, material in pairs(own.Table.materials) do
      tune[name .. ".bounce"], tune[name .. ".friction"] = material.bounce, material.friction
    end
    return own, tune, private
  end

  --- A game on the table with no ball served, and the rules moved on a tick at a time
  local function game(own, tune)
    local state = own.Rules.NewGame(tune, { keep = 0 })
    local function run(seconds)
      local world = state.world
      for _ = 1, math.floor(seconds * world.hz) do
        own.Rules.BeforeTick(world.tick + 1)
        world:Tick()
      end
    end
    return state, run
  end

  function tests.PinballsOneMoveIsTheScore()
    local _, _, private = pinball()
    local definition = private.Games.Get("pinball")
    local state = definition.newState(1, nil, {})
    equal(false, (definition.validate(state, 1, "x")), "only a score")
    equal(false, (definition.validate(state, 1, "s12a")), "a score of digits")
    equal(true, (definition.validate(state, 1, "s123450")), "a score")
    definition.apply(state, 1, "s123450")
    equal(123450, state.score, "kept")
    equal(1, definition.result(state).winner, "and the game over")
    equal(false, (definition.validate(state, 1, "s5")), "and nothing after it")
    equal(123450, definition.record(state)[1].value, "the score is the record")
  end

  function tests.PinballsRampWireRunsToTheLeftInlane()
    local own, tune = pinball()
    local state, run = game(own, tune)
    local world = state.world
    local ball = world:AddBall(0, 0, own.Table.ball)
    local passed, off
    local onEvent = world.onEvent
    world.onEvent = function(kind, made, b, extra)
      if kind == "pass" and made.name == "rampWire" then
        passed = true
      elseif kind == "off" then
        off = { x = b.x, y = b.y, layer = b.layer, ending = extra }
      end
      onEvent(kind, made, b, extra)
    end
    world:Ride(ball, state.named.rampWire, 900)
    run(4)
    equal(true, passed, "over its crest, which makes the ramp")
    equal(1, state.ramps, "counted")
    equal(1, off.ending, "off at the end of the wire")
    equal(1, off.layer, "onto the playfield")
    equal(true, off.x < 100 and off.y > 700, "down the left side, at " .. math.floor(off.x) .. ", " .. math.floor(off.y))
  end

  function tests.PinballsMoonwellShootsTheBallUpItsTubeToTheRightInlane()
    local own, tune = pinball()
    local state, run = game(own, tune)
    local world = state.world
    local saucer = state.named.saucer
    local ball = world:AddBall(saucer.x1, saucer.y1 - 30, own.Table.ball)
    world:Launch(ball, 0, 100)
    local off
    local onEvent = world.onEvent
    world.onEvent = function(kind, made, b, extra)
      if kind == "off" then
        off = { x = b.x, y = b.y, layer = b.layer, ending = extra }
      end
      onEvent(kind, made, b, extra)
    end
    local highest = 0
    for _ = 1, 40 do
      run(0.1)
      highest = math.max(highest, ball.z)
    end
    equal(true, highest > 120, "up the tube and over the ramp, " .. math.floor(highest) .. " mm up")
    equal(1, off.ending, "off at the end of the wire")
    equal(true, off.x > 380 and off.y > 700 and off.layer == 1, "down the right side, at " .. math.floor(off.x) .. ", "
      .. math.floor(off.y))
  end

  function tests.PinballsFrostNovaFreezesTheBallThenLetsItDrop()
    local own, tune = pinball()
    local state, run = game(own, tune)
    local world = state.world
    local ball = world:AddBall(238, 650, own.Table.ball)
    world:Launch(ball, 300, 800)
    run(0.05)
    table.insert(state.queue, "frost")
    run(0.01)
    local x, y = ball.x, ball.y
    equal(own.Rules.FROZEN, ball.held, "frozen")
    run(tune.frostSeconds - 0.1)
    equal(x, ball.x, "where it was")
    equal(y, ball.y, "where it was")
    run(0.2)
    equal(nil, ball.held, "let go")
    equal(true, ball.vy > 0, "and dropping")
    table.insert(state.queue, "frost")
    run(0.01)
    equal(nil, ball.held, "not again until it has cooled down")
  end

  function tests.PinballsShieldWallHoldsThePostUpForItsTime()
    local own, tune = pinball()
    local state, run = game(own, tune)
    local post = state.named.centerPost
    equal(false, post.active, "down")
    table.insert(state.queue, "post")
    run(0.01)
    equal(true, post.active, "up")
    run(tune.wallSeconds - 0.1)
    equal(true, post.active, "still up")
    run(0.2)
    equal(false, post.active, "down again")
    table.insert(state.queue, "post")
    run(0.01)
    equal(false, post.active, "not again until it has cooled down")
    run(tune.wallCooldown)
    table.insert(state.queue, "post")
    run(0.01)
    equal(true, post.active, "and then it can")
  end
end
