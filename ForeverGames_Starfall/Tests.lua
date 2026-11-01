-- Starfall's own tests, run with Forever Games' (lua Tests/RunTests.lua Starfall). The checks every
-- game is put through (Tests/EveryGame.lua) are run on it as well, EveryGame_starfall: the same
-- sky from the same seed, every shot replaying the same on another client, the day's sky and races.
--
-- Handed the tests to add to, the engine to load, and what Forever Games' tests are written with.
-- Not listed in the .toc, so the game client never loads it.
return function(tests, loadEngine, helpers)
  local equal = helpers.equal
  local World, Client, openWindow = helpers.World, helpers.Client, helpers.openWindow

  local function starfall()
    local private = loadEngine()
    return private.plugins.ForeverGames_Starfall, private.Games.Get("starfall"), private
  end

  --- A night from a seed
  local function night(seed)
    local own, game, private = starfall()
    return game.newState(1, private.Random.New(seed), {}), own, game, private
  end

  function tests.StarfallLaysOutEveryPatternWithConstellationsAndWisps()
    local own, _, private = starfall()
    local Board = own.Board
    for _, pattern in ipairs(Board.PATTERNS) do
      for seed = 1, 4 do
        local stones, groups = Board.Make(private.Random.New(seed * 101), pattern)
        local label = pattern .. " " .. seed
        assert(#stones >= 40 and #stones <= 160, label .. ": " .. #stones .. " stones")
        assert(#groups >= 4, label .. ": " .. #groups .. " constellations")
        local kinds = { stone = 0, star = 0, wisp = 0 }
        for index, stone in ipairs(stones) do
          kinds[stone.kind] = kinds[stone.kind] + 1
          for other = index + 1, #stones do
            local dx, dy = stones[other].x - stone.x, stones[other].y - stone.y
            assert(dx * dx + dy * dy >= 20 * 20, label .. ": two stones on top of each other")
          end
          assert(stone.y > Board.LAUNCH_Y + 60, label .. ": a stone in front of the crescent")
        end
        equal(2, kinds.wisp, label .. ": wisps")
        local stars = 0
        for _, group in ipairs(groups) do
          stars = stars + #group.stars
          equal(2 * (#group.stars - 1), #group.lines, label .. ": every star of a constellation joined")
        end
        equal(stars, kinds.star, label .. ": every star in a constellation")
      end
    end
  end

  function tests.StarfallTakesOnlyAimsWrittenOneWay()
    local state, _, game = night(1)
    equal(true, (game.validate(state, 1, "a900")))
    equal(true, (game.validate(state, 1, "a0")))
    equal(true, (game.validate(state, 1, "a1800")))
    equal(false, (game.validate(state, 1, "a1801")), "past straight right")
    equal(false, (game.validate(state, 1, "a0900")), "a leading nought")
    equal(false, (game.validate(state, 1, "a-5")))
    equal(false, (game.validate(state, 1, "s900")))
    equal(false, (game.validate(state, 2, "a900")), "nobody else")
  end

  function tests.StarfallShotLightsWhatItTouchesAndTakesItAway()
    local state, own, game, private = night(7)
    local before = state.stars
    local shot = game.apply(state, 1, "a900", private.Random.New(3))
    assert(#shot.lit > 0, "a shot straight down touches something")
    for _, index in ipairs(shot.lit) do
      equal(true, state.gone[index], "a lit stone is gone")
    end
    local firsts = 0
    for _, touch in ipairs(shot.touches) do
      firsts = firsts + (touch.first and 1 or 0)
    end
    equal(#shot.lit - #shot.freed, firsts - 0 + (function()
      -- A stone freed that had been touched before was lit by its touch, not by being freed
      local count = 0
      for _, freed in ipairs(shot.freed) do
        for _, touch in ipairs(shot.touches) do
          if touch.stone == freed.stone and touch.first then
            count = count + 1
            break
          end
        end
      end
      return -count
    end)(), "every stone lit was touched, or freed")
    equal(before - 1 + (shot.well and 1 or 0), state.stars, "a star spent, unless the Moonwell caught it")
    equal(1, state.shots)
    assert(state.score >= shot.points and shot.points > 0, "points")
    -- The flight ends below the sky
    local path = shot.flights[1].path
    assert(path[#path] > own.Board.SKY_HEIGHT, "the star fell out of the sky")
  end

  function tests.StarfallFliesTheSameOnAnotherClient()
    local state, _, game, private = night(11)
    local other = night(11)
    for _, aim in ipairs({ "a700", "a1100", "a900", "a40" }) do
      local mine = game.apply(state, 1, aim, private.Random.New(#aim))
      local theirs = game.apply(other, 1, aim, private.Random.New(#aim))
      equal(#mine.touches, #theirs.touches, aim)
      equal(mine.ticks, theirs.ticks, aim)
    end
    equal(state.score, other.score)
  end

  function tests.StarfallScoresChainsAndWakesConstellations()
    local state, own = night(5)
    local Board = own.Board
    -- Every star of the first constellation but one already gone, and the last struck now
    local group = state.constellations[1]
    for index = 2, #group.stars do
      state.gone[group.stars[index]] = true
    end
    local last = state.stones[group.stars[1]]
    -- Every other stone out of the way, so that only the last star can be touched, and the other
    -- constellations awake already
    for index, stone in ipairs(state.stones) do
      if stone ~= last then
        state.gone[index] = true
      end
    end
    for index = 2, #state.constellations do
      state.constellations[index].woken = true
    end
    local hit
    for aim = 0, Board.AIMS, 5 do
      local shot = Board.Fly(state.stones, state.gone, aim, -1000)
      if #shot.lit == 1 then
        hit = aim
        break
      end
    end
    assert(hit, "an aim that strikes the last star")
    local shot = Board.Shoot(state, hit)
    equal(1, #shot.woken, "the constellation woke")
    equal(true, group.woken)
    equal(Board.POINTS.star + Board.WOKEN * #group.stars, shot.points)
  end

  function tests.StarfallIsWonWithEveryStarLitAndTheRestPaysOut()
    local state, own, game, private = night(9)
    for index, stone in ipairs(state.stones) do
      state.gone[index] = stone.kind == "star" or nil
    end
    -- Bring one star back, alone in the sky, and strike it
    local target
    for index, stone in ipairs(state.stones) do
      if stone.kind == "star" then
        target = index
      end
    end
    for index in ipairs(state.stones) do
      state.gone[index] = index ~= target or nil
    end
    local aim
    for try = 0, own.Board.AIMS, 5 do
      if #own.Board.Fly(state.stones, state.gone, try, -1000).lit == 1 then
        aim = try
        break
      end
    end
    assert(aim, "an aim that strikes it")
    local shot = game.apply(state, 1, "a" .. aim, private.Random.New(1))
    equal(true, state.over)
    equal(1, game.result(state).winner)
    equal("starfall_won", game.result(state).detail)
    equal(state.stars * own.Board.UNSPENT, shot.bonus)
    equal(state.score, game.record(state)[1].value)
    equal(state.score, game.daily.score(state))
  end

  function tests.StarfallEndsAtDawnWhenTheStarsRunOut()
    local state, _, game, private = night(2)
    state.stars = 1
    -- A shot straight along the top into the wall, which can't light every star
    local shot = game.apply(state, 1, "a0", private.Random.New(1))
    if not shot.well then
      equal(true, state.over)
      equal(0, game.result(state).winner)
      equal("starfall_dawn", game.result(state).detail)
      equal(0, #game.moves(state, 1))
    end
  end

  -----------------------------
  -- On screen
  -----------------------------

  local function settle(seconds)
    for _ = 1, math.floor(seconds / 0.02) do
      for _, frame in ipairs(Client.Find(function(widget)
        return widget.scripts.OnUpdate ~= nil and widget:IsVisible()
      end)) do
        frame:Fire("OnUpdate", 0.02)
      end
    end
  end

  function tests.StarfallIsPlayedOnScreen()
    local world = World.New()
    world.seed = 1
    local player = world:AddPlayer("Alice-Realm")
    local MainFrame = openWindow(player)
    local match = assert(player.session:Invite({}, "starfall"))
    MainFrame.Open(match.id)
    settle(0.1)

    -- Space fires the star at the aim the crescent has, wherever the mouse or the arrows turned it
    Client.over = true
    local keys = Client.Find(function(widget)
      return widget.scripts.OnKeyDown ~= nil and widget:IsVisible()
    end)
    assert(#keys > 0, "something takes the keys")
    for _, frame in ipairs(keys) do
      frame:Fire("OnKeyDown", "RIGHT")
    end
    for _, frame in ipairs(keys) do
      frame:Fire("OnKeyDown", "SPACE")
    end
    equal(1, #match.log, "the shot was made")
    equal(true, match.log[1]:match("^a%d+$") ~= nil, "an aim")
    Client.sounds = {}
    settle(12)
    local heard = {}
    for _, sound in ipairs(Client.sounds) do
      heard[sound] = true
    end
    equal(true, heard.chime, "a chime for a stone lit")
    equal(true, heard.pop, "and a pop as it went")
    -- Ready for the next
    for _, frame in ipairs(keys) do
      frame:Fire("OnKeyDown", "SPACE")
    end
    equal(2, #match.log, "the next shot")
  end
end
