-- CarcassonneWoW (Games/Realms.lua): the tiles there are and how their edges meet, towns, roads
-- and abbeys scored when they are finished and footmen sent home, who scores a group with
-- footmen of more than one player on it, what can't take a footman, the end of the game and its
-- fields, a player resigning, and what a tile laid somewhere would join being what laying it does.

local function equal(expected, actual, label)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", label or "value", tostring(expected), tostring(actual)), 2)
  end
end

return function(tests, loadEngine)
  --- @return table game, table rules, table private
  local function realms()
    local private = loadEngine()
    local game = private.Games.Get("realms")
    return game, game.rules, private
  end

  --- A game for so many with the start tile down, and the tiles to come set by hand: the first
  --- is the one drawn, the rest the bag
  local function dealt(game, private, seats, tiles, rules)
    local state = game.newState(seats, private.Random.New(7), rules or {})
    state.tile = tiles[1]
    state.bag = { unpack(tiles, 2) }
    return state
  end

  --- Plays a move that has to be legal
  local function play(game, private, state, seat, move)
    local ok, err = game.validate(state, seat, move)
    assert(ok, "move " .. move .. " was refused: " .. tostring(err))
    return game.apply(state, seat, move, private.Random.New(3))
  end

  function tests.RealmsTiles()
    local _, rules = realms()
    local total = 0
    for _, kind in ipairs(rules.KINDS) do
      local tile = rules.TILES[kind]
      total = total + tile.count
      local seen = {}
      for index, feature in ipairs(tile.features) do
        for _, slot in ipairs(feature.slots or {}) do
          assert(not seen[slot], kind .. ": slot " .. slot .. " is in two features")
          seen[slot] = index
        end
        for _, town in ipairs(feature.towns or {}) do
          equal("town", tile.features[town].kind, kind .. ": what field " .. index .. " touches")
        end
        assert(feature.at and feature.at[1] > 0 and feature.at[1] < 1 and feature.at[2] > 0 and feature.at[2] < 1, kind .. ": where a footman stands")
      end
      for slot = 0, 11 do
        assert(seen[slot], kind .. ": nothing at slot " .. slot)
      end
      -- A town takes a whole side, a road only ever the middle of one
      for side = 0, 3 do
        local middle = tile.features[seen[side * 3 + 1]].kind
        for place = 0, 2 do
          local kindHere = tile.features[seen[side * 3 + place]].kind
          if middle == "town" or kindHere == "town" then
            equal(middle, kindHere, kind .. ": side " .. side .. " half a town")
          end
          if place ~= 1 then
            assert(kindHere ~= "road", kind .. ": a road at the corner of side " .. side)
          end
        end
      end
    end
    equal(72, total, "tiles in the game")
    for slot = 0, 11 do
      equal(slot, rules.across(rules.across(slot)), "across and back")
    end
    equal(8, rules.across(0), "the west end of the north side meets the west end of the south")
    equal(10, rules.across(4), "the middle of the east side meets the middle of the west")
  end

  function tests.RealmsStart()
    local game, rules, private = realms()
    local state = game.newState(3, private.Random.New(1), {})
    equal(1, #state.tiles, "tiles down")
    equal("D", state.tiles[1].kind, "the start tile")
    equal(70, #state.bag, "tiles still to draw")
    assert(state.tile, "a tile is drawn for the first player")
    for seat = 1, 3 do
      equal(7, state.men[seat], "footmen")
      equal(0, state.scores[seat], "score")
    end
    -- The town is open to the north, the road at both ends
    local town = rules.groupOf(state, 1 * rules.SPAN + 1)
    equal(1, town.open, "the start town's open side")
    equal(2, rules.groupOf(state, 1 * rules.SPAN + 2).open, "the start road's ends")
  end

  function tests.RealmsFits()
    local game, rules, private = realms()
    local state = dealt(game, private, 2, { "E" })
    -- A town to the north of the start tile has to turn its wall south
    assert(rules.fits(state, "E", 0, -1, 2), "a town wall against a town wall")
    assert(not rules.fits(state, "E", 0, -1, 0), "a field against a town wall")
    assert(not rules.fits(state, "E", 5, 5, 0), "nowhere near the other tiles")
    assert(not rules.fits(state, "E", 0, 0, 0), "on top of a tile")
    -- The road leaves east: a straight road has to be turned across
    assert(rules.fits(state, "U", 1, 0, 1), "a road on to a road")
    assert(not rules.fits(state, "U", 1, 0, 0), "a field on to a road")
    local ok, err = game.validate(state, 1, "0.-1.0")
    assert(not ok and err == "realms_no_fit", "refused, as not fitting")
    ok, err = game.validate(state, 2, "0.-1.2")
    assert(not ok and err == "not_your_turn", "refused, as not their turn")
    for _, bad in ipairs({ "0.-1", "0.-1.4", "0.-1.2.0", "a.b.c", "-0.-1.2", "00.-1.2", "0.-1.2.9" }) do
      assert(not game.validate(state, 1, bad), bad .. " is not a move")
    end
  end

  function tests.RealmsTownScored()
    local game, rules, private = realms()
    local state = dealt(game, private, 2, { "E", "U", "U" })
    -- The first player closes the start town with a town of their own, and stands in it
    local event = play(game, private, state, 1, "0.-1.2.1")
    equal(1, #event.scored, "groups scored")
    local scoring = event.scored[1]
    equal("town", scoring.kind, "what was scored")
    equal(4, scoring.points, "two tiles of town")
    equal(1, #scoring.seats, "who scored it")
    equal(1, scoring.seats[1], "who scored it")
    equal(1, #scoring.footmen, "footmen home")
    equal(4, state.scores[1], "the first player's score")
    equal(7, state.men[1], "the footman is back")
    equal(0, #state.footmen, "footmen on the board")
    assert(rules.groupOf(state, 1 * rules.SPAN + 1).done, "the town is finished")
    equal(2, state.turn, "the second player's turn")
  end

  function tests.RealmsRoadScored()
    local game, rules, private = realms()
    local state = dealt(game, private, 2, { "W", "W", "U" })
    -- A village east of the start tile, its west road met by the start road
    play(game, private, state, 1, "1.0.0")
    state.tile = "W"
    -- The second player stands on the start road from a village to the west of it, which
    -- finishes it: three tiles from village to village
    local seen = {}
    local outlook = rules.preview(state, "W", -1, 0, 2)
    for feature, entry in ipairs(outlook) do
      if rules.TILES.W.features[feature].kind == "road" and #entry.groups > 0 then
        seen[#seen + 1] = feature
      end
    end
    equal(1, #seen, "one of the village's roads meets the start road")
    local event = play(game, private, state, 2, "-1.0.2." .. seen[1])
    local road
    for _, scoring in ipairs(event.scored) do
      if scoring.kind == "road" then
        road = scoring
      end
    end
    assert(road, "the road was scored")
    equal(3, road.points, "three tiles of road")
    equal(3, state.scores[2], "the second player's score")
  end

  function tests.RealmsAbbeyScored()
    local game, rules, private = realms()
    -- An abbey south of the start tile, then the eight round it
    local state = dealt(game, private, 2, { "B", "B", "B", "B", "B", "B", "B", "U", "U", "U" })
    play(game, private, state, 1, "0.1.0.1")
    equal(8 - 1, rules.groupOf(state, 2 * rules.SPAN + 1).open, "the abbey has the start tile above it")
    -- Abbeys all round it: fields meet fields however they are turned
    local spots = { { -1, 1 }, { 1, 1 }, { -1, 2 }, { 0, 2 }, { 1, 2 } }
    for index, spot in ipairs(spots) do
      state.tile = "B"
      play(game, private, state, index % 2 == 1 and 2 or 1, spot[1] .. "." .. spot[2] .. ".0")
    end
    equal(2, rules.groupOf(state, 2 * rules.SPAN + 1).open, "two corners still to come")
    equal(0, state.scores[1], "nothing scored yet")
    -- The two above the corners carry the start road on east and west
    state.tile = "U"
    play(game, private, state, state.turn, "1.0.1")
    state.tile = "U"
    local event = play(game, private, state, state.turn, "-1.0.1")
    local abbey
    for _, scoring in ipairs(event.scored) do
      if scoring.kind == "abbey" then
        abbey = scoring
      end
    end
    assert(abbey, "the abbey was scored")
    equal(9, abbey.points, "a whole abbey")
    assert(state.scores[1] >= 9, "the first player has it")
  end

  function tests.RealmsSharedTown()
    local game, rules, private = realms()
    -- Each player stands in a town of their own, then a tile joins the two
    local state = dealt(game, private, 2, { "E", "E", "U", "U" })
    -- North of the start town, so that it opens south: the start town's other side
    state.tile = "N"
    -- Turned so that the corner town faces south and east: (0,-1) south meets the start town
    local turn
    for candidate = 0, 3 do
      if rules.fits(state, "N", 0, -1, candidate) and rules.edgeOf("N", candidate, 1) == "t" then
        turn = candidate
      end
    end
    assert(turn, "a corner town that opens south and east")
    play(game, private, state, 1, "0.-1." .. turn .. ".1")
    -- A town east of that, facing west, for the second player: not joined yet
    state.tile = "E"
    local east = nil
    for candidate = 0, 3 do
      if rules.fits(state, "E", 1, -2, candidate) and rules.edgeOf("E", candidate, 2) == "t" then
        east = candidate
      end
    end
    -- Not next to anything there: lay the second player's town south east of it instead
    assert(not east, "nothing at 1,-2 to lay against")
    for candidate = 0, 3 do
      if rules.fits(state, "E", 1, -1, candidate) and rules.edgeOf("E", candidate, 3) == "t" then
        east = candidate
      end
    end
    assert(east, "a town that faces west at 1,-1")
    -- It joins the first player's town at once: it can't take a footman
    local ok, err = game.validate(state, 2, "1.-1." .. east .. ".1")
    assert(not ok and err == "realms_taken", "a town joined to one that has a footman")
    play(game, private, state, 2, "1.-1." .. east)
    equal(1, state.turn, "back to the first player")
  end

  function tests.RealmsMajority()
    local _, rules = realms()
    local group = { men = { [1] = 2, [3] = 2, [2] = 1 } }
    local list = rules.majority(group, 3)
    equal(2, #list, "a tie for most")
    equal(1, list[1], "first of them")
    equal(3, list[2], "second of them")
    equal(0, #rules.majority({ men = {} }, 3), "nobody")
  end

  function tests.RealmsFinalScoring()
    local game, rules, private = realms()
    -- One tile left: the first player stands in the start town's field, the second in an
    -- unfinished town of three sides. Then the start town is closed and the tiles run out
    local state = dealt(game, private, 2, { "R", "E", "E" })
    -- The road's south field, a farmer
    state.tile = "U"
    play(game, private, state, 1, "1.0.1.3")
    -- An unfinished town to the south of that, for the second player
    state.tile = "R"
    local turn
    for candidate = 0, 3 do
      if rules.fits(state, "R", 1, 1, candidate) then
        turn = turn or candidate
      end
    end
    assert(turn, "the town fits south of the road")
    play(game, private, state, 2, "1.1." .. turn .. ".1")
    -- The start town closed by a town north of it, the last tile
    state.tile = "E"
    state.bag = {}
    local event = play(game, private, state, 1, "0.-1.2")
    assert(event.final, "the game is over")
    assert(state.outcome, "and has an outcome")
    local field, town
    for _, scoring in ipairs(event.scored) do
      if scoring.kind == "field" then
        field = scoring
      elseif scoring.kind == "town" and scoring.final then
        town = scoring
      end
    end
    assert(town, "the unfinished town was scored")
    equal(1, town.points, "one tile of unfinished town")
    assert(field, "the field was scored")
    -- The south field of the start road touches no town, the north one the start town
    equal(true, field.points == 0 or field.points == 3, "a field is worth 3 a finished town")
  end

  function tests.RealmsFieldTouchesTown()
    local game, rules, private = realms()
    local state = dealt(game, private, 2, { "U", "E" })
    -- A farmer in the start tile's north field, by way of a road east of it
    state.tile = "U"
    local outlook = rules.preview(state, "U", 1, 0, 1)
    local north
    for feature, entry in ipairs(outlook) do
      local spec = rules.TILES.U.features[feature]
      if spec.kind == "field" then
        -- The north field of the start tile is feature 3 there
        for _, group in ipairs(entry.groups) do
          if group == 1 * rules.SPAN + 3 then
            north = feature
          end
        end
      end
    end
    assert(north, "a field of the road meets the start tile's north field")
    play(game, private, state, 1, "1.0.1." .. north)
    equal("E", state.tile, "the last tile drawn")
    state.bag = {}
    local event = play(game, private, state, 2, "0.-1.2")
    local field
    for _, scoring in ipairs(event.scored) do
      if scoring.kind == "field" then
        field = scoring
      end
    end
    assert(field, "the field was scored")
    equal(3, field.points, "one finished town")
    equal(1, field.seats[1], "for the first player")
    equal(3, state.scores[1], "the first player's score")
    equal(1, state.outcome.winner, "who won")
  end

  function tests.RealmsNoFields()
    local game, rules, private = realms()
    local state = dealt(game, private, 2, { "U" }, { fields = false })
    local ok, err = game.validate(state, 1, "1.0.1.2")
    assert(not ok and err == "realms_no_fields", "no footmen in fields")
    for _, move in ipairs(game.moves(state, 1)) do
      local x, y, turn, feature = rules.parse(move)
      if feature then
        assert(rules.TILES.U.features[feature].kind ~= "field", "listed " .. move .. ", a field")
      end
      assert(x and y and turn, "listed " .. move)
    end
  end

  function tests.RealmsResign()
    local game, rules, private = realms()
    local state = dealt(game, private, 3, { "U", "U", "U", "U" })
    play(game, private, state, 1, "1.0.1.1")
    equal(1, #state.footmen, "a footman on the road")
    game.drop(state, 1)
    equal(0, #state.footmen, "gone with its owner")
    assert(not next(rules.groupOf(state, 1 * rules.SPAN + 2).men), "nobody on the road")
    equal(2, state.turn, "still the second player's turn")
    game.drop(state, 2)
    equal(3, state.turn, "the third player's turn, the second resigned")
  end

  -- What preview says laying a tile would do has to be what laying it does
  function tests.RealmsPreviewMatchesPlay()
    local game, rules, private = realms()
    for seed = 1, 4 do
      local state = game.newState(3, private.Random.New(seed), {})
      local dice = private.Random.New(seed + 100)
      while not state.outcome do
        local list = game.moves(state, state.turn)
        local move = list[dice:Roll(#list)]
        local x, y, turn = rules.parse(move)
        local kind = state.tile
        local outlook = rules.preview(state, kind, x, y, turn)
        local event = game.apply(state, state.turn, move, dice)
        for feature, entry in ipairs(outlook) do
          local group = rules.groupOf(state, event.index * rules.SPAN + feature)
          local spec = rules.TILES[kind].features[feature]
          if spec.kind ~= "abbey" and not group.done then
            equal(group.open, entry.open, kind .. " " .. move .. " feature " .. feature .. ": open")
            equal(group.size, entry.size, kind .. " " .. move .. " feature " .. feature .. ": size")
            equal(group.banners, entry.banners, kind .. " " .. move .. " feature " .. feature .. ": banners")
          elseif spec.kind == "abbey" then
            equal(group.open, entry.open, kind .. " " .. move .. " abbey: open")
          end
        end
      end
    end
  end

  -- However a game goes, every tile is laid or put aside and every footman is somewhere
  function tests.RealmsWholeGame()
    local game, rules, private = realms()
    for seed = 1, 3 do
      local state = game.newState(4, private.Random.New(seed), {})
      local dice = private.Random.New(seed)
      local aside = 0
      while not state.outcome do
        local list = game.moves(state, state.turn)
        assert(#list > 0, "a tile was drawn that can't be laid")
        local event = game.apply(state, state.turn, list[dice:Roll(#list)], dice)
        aside = aside + #(event.aside or {})
        for seat = 1, 4 do
          local standing = 0
          for _, footman in ipairs(state.footmen) do
            standing = standing + (footman.seat == seat and 1 or 0)
          end
          equal(7, state.men[seat] + standing, "footmen of seat " .. seat)
        end
      end
      equal(72, #state.tiles + aside, "tiles laid or put aside")
      equal(0, #state.footmen, "every footman home at the end")
    end
  end

  -- The computer at its best beats itself at its worst more often than not
  function tests.RealmsComputerLevels()
    local game, _, private = realms()
    local Brain = private.Computer.Brain
    local wins = 0
    for seed = 1, 4 do
      local state = game.newState(2, private.Random.New(seed), {})
      local dice = private.Random.New(seed)
      local hard = seed % 2 + 1
      while not state.outcome do
        local seat = state.turn
        local brain = Brain.New(game, seat, seat == hard and "hard" or "easy", seed * 100 + #state.tiles)
        local move = game.computer.think(state, seat, brain)
        game.apply(state, seat, move, dice)
      end
      if state.outcome.winner == hard then
        wins = wins + 1
      end
    end
    assert(wins >= 3, "hard beat easy " .. wins .. " times out of 4")
  end
end
