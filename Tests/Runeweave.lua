-- Runeweave's own tests, run with the rest (lua Tests/RunTests.lua Runeweave). The checks
-- every game is put through (Tests/EveryGame.lua) are run on it as well, EveryGame_runeweave:
-- the same board from the same seed, every swap replaying the same on another client, the day's
-- board and races.
--
-- Handed the tests to add to, the engine to load, and what the tests in RunTests.lua are written with.
return function(tests, loadEngine, helpers)
  local equal = helpers.equal
  local World, Client, openWindow = helpers.World, helpers.Client, helpers.openWindow

  local function runeweave()
    local private = loadEngine()
    return private.Runeweave, private.Games.Get("runeweave"), private
  end

  --- A game from a seed
  local function game(seed)
    local own, definition, private = runeweave()
    return definition.newState(1, private.Random.New(seed), {}), own, definition, private
  end

  --- A board with no line on it and none to be made by a swap, the schools 3 to 6 in squares of
  --- two by two, with runes put on it where a test says: { [square] = value }
  local function quiet(Board, runes)
    local board = {}
    for square = 1, Board.SQUARES do
      local row, column = Board.Place(square)
      board[square] = 3 + column % 2 + 2 * (row % 2)
    end
    for square, value in pairs(runes or {}) do
      board[square] = value
    end
    return board
  end

  --- Two tables with the same in them, a level deep
  local function same(expected, actual, label)
    for key, value in pairs(expected) do
      equal(value, actual[key], (label or "table") .. " at " .. tostring(key))
    end
    for key in pairs(actual) do
      assert(expected[key] ~= nil, (label or "table") .. ": more at " .. tostring(key))
    end
  end

  local function count(list)
    local n = 0
    for _ in pairs(list) do
      n = n + 1
    end
    return n
  end

  function tests.RuneweaveLaysOutABoardWithNoLineAndASwap()
    local own, _, private = runeweave()
    local Board = own.Board
    for seed = 1, 30 do
      local board = Board.Make(private.Random.New(seed))
      equal(Board.SQUARES, #board)
      equal(0, #Board.Groups(board), "no line on a fresh board")
      equal(true, Board.CanMove(board), "and a swap to make")
      for _, value in ipairs(board) do
        assert(value >= 1 and value <= Board.SCHOOLS, "a plain rune of a school: " .. value)
      end
    end
    equal(false, Board.CanMove(quiet(Board)), "the quiet board has no swap")
  end

  function tests.RuneweaveTakesOnlySwapsWrittenOneWay()
    local own = runeweave()
    local Board = own.Board
    local function swap(move)
      return table.concat({ Board.Swap(move) }, ",")
    end
    equal("1,2", swap("s0r"))
    equal("1,9", swap("s0d"))
    equal("63,64", swap("s62r"))
    equal("", swap("s7r"), "off the right")
    equal("", swap("s56d"), "off the bottom")
    equal("", swap("s63d"))
    equal("", swap("s64r"))
    equal("", swap("s01r"), "a leading nought")
    equal("", swap("s1l"))
    equal("", swap("x1r"))
    equal("s0r", Board.Write(2, 1))
    equal("s3d", Board.Write(4, 12))
    equal(nil, Board.Write(8, 9), "the end of one row and the start of the next aren't side by side")

    local state, _, definition = game(1)
    local moves = definition.moves(state, 1)
    assert(#moves > 0)
    equal(true, (definition.validate(state, 1, moves[1])))
    equal(false, (definition.validate(state, 2, moves[1])), "nobody else")
    -- A swap that lines nothing up isn't one
    local listed = {}
    for _, move in ipairs(moves) do
      listed[move] = true
    end
    for index = 0, Board.SQUARES - 1 do
      for _, way in ipairs({ "r", "d" }) do
        local move = "s" .. index .. way
        if Board.Swap(move) then
          equal(listed[move] == true, (definition.validate(state, 1, move)), move)
        end
      end
    end
  end

  function tests.RuneweaveMakesRunesOfPower()
    local own, _, private = runeweave()
    local Board = own.Board
    local Value, Square = Board.Value, Board.Square
    local random = private.Random.New(5)

    -- Four along the bottom: the rune moved down into it becomes a charged one
    local board = quiet(Board, { [Square(7, 0)] = 1, [Square(7, 1)] = 1, [Square(7, 2)] = 2, [Square(7, 3)] = 1, [Square(6, 2)] = 1 })
    local play = Board.Play(board, Square(6, 2), Square(7, 2), 1, random)
    local first = play.steps[1]
    equal(1, #first.made)
    equal(Square(7, 2), first.made[1].square, "made where the rune was moved to")
    equal(Value(1, Board.ROW), first.made[1].value, "it bolts along the row the four lay in")
    equal(3, count(first.cleared))
    equal(Board.LINE * 2, first.points, "a four is worth 100")

    -- Four down a column: bolting down it
    board = quiet(Board, { [Square(2, 4)] = 1, [Square(3, 4)] = 1, [Square(4, 4)] = 2, [Square(5, 4)] = 1, [Square(4, 3)] = 1 })
    play = Board.Play(board, Square(4, 3), Square(4, 4), 1, random)
    equal(Value(1, Board.COLUMN), play.steps[1].made[1].value)
    equal(Square(4, 4), play.steps[1].made[1].square)

    -- An L: a nova where the lines cross
    board = quiet(Board, { [Square(4, 0)] = 1, [Square(4, 1)] = 1, [Square(5, 2)] = 1, [Square(6, 2)] = 1, [Square(4, 3)] = 1, [Square(4, 2)] = 2 })
    -- Moving the 1 at (4,3) left into (4,2) makes 1,1,1 across and 1,1,1 down from (4,2)
    play = Board.Play(board, Square(4, 2), Square(4, 3), 1, random)
    equal(Value(1, Board.NOVA), play.steps[1].made[1].value)
    equal(Square(4, 2), play.steps[1].made[1].square)

    -- Five in a row: a prism
    board = quiet(Board, { [Square(0, 0)] = 2, [Square(0, 1)] = 2, [Square(0, 2)] = 1, [Square(0, 3)] = 2, [Square(0, 4)] = 2, [Square(1, 2)] = 2 })
    play = Board.Play(board, Square(0, 2), Square(1, 2), 1, random)
    equal(Value(0, Board.PRISM), play.steps[1].made[1].value)
    equal(Square(0, 2), play.steps[1].made[1].square)
    equal(Board.LINE * 3, play.steps[1].points)
  end

  function tests.RuneweaveSetsRunesOfPowerOff()
    local own, _, private = runeweave()
    local Board = own.Board
    local Value, Square = Board.Value, Board.Square
    local random = private.Random.New(8)

    -- A charged rune cleared in a line clears its whole row
    local board = quiet(Board, { [Square(3, 0)] = 1, [Square(3, 1)] = Value(1, Board.ROW), [Square(3, 2)] = 2, [Square(2, 2)] = 1 })
    local play = Board.Play(board, Square(2, 2), Square(3, 2), 1, random)
    local first = play.steps[1]
    equal(1, #first.bolts)
    equal(Board.ROW, first.bolts[1].kind)
    for column = 0, 7 do
      assert(first.cleared[Square(3, column)], "the whole row cleared: " .. column)
    end
    equal(8, count(first.cleared))
    equal(Board.LINE + Board.POWER * 5, first.points, "the line, and five more runes by the bolt")

    -- A nova clears everything within two steps
    board = quiet(Board, { [Square(4, 3)] = 1, [Square(4, 4)] = Value(1, Board.NOVA), [Square(4, 5)] = 2, [Square(3, 5)] = 1 })
    play = Board.Play(board, Square(3, 5), Square(4, 5), 1, random)
    equal(13, count(play.steps[1].cleared), "a diamond of thirteen squares round it, the line inside it")

    -- A charged rune in the way of another's bolt goes off too
    board = quiet(Board, { [Square(6, 0)] = 1, [Square(6, 1)] = Value(1, Board.ROW), [Square(6, 2)] = 2, [Square(5, 2)] = 1, [Square(6, 6)] = Value(2, Board.COLUMN) })
    play = Board.Play(board, Square(5, 2), Square(6, 2), 1, random)
    equal(2, #play.steps[1].bolts, "the bolt set the other off")
    for row = 0, 7 do
      assert(play.steps[1].cleared[Square(row, 6)], "its column cleared as well")
    end

    -- A prism swapped with a rune clears its whole school
    board = quiet(Board, { [Square(0, 0)] = Value(0, Board.PRISM) })
    local fours = 0
    for _, value in ipairs(board) do
      fours = fours + (value == 4 and 1 or 0)
    end
    play = Board.Play(board, Square(0, 0), Square(0, 1), 1, random)
    first = play.steps[1]
    equal(Board.PRISM, first.bolts[1].kind)
    equal(4, first.bolts[1].school)
    equal(fours + 1, count(first.cleared), "every 4 and the prism")

    -- Two prisms: the whole board
    board = quiet(Board, { [Square(5, 5)] = Value(0, Board.PRISM), [Square(5, 6)] = Value(0, Board.PRISM) })
    play = Board.Play(board, Square(5, 5), Square(5, 6), 1, random)
    equal(Board.SQUARES, count(play.steps[1].cleared))
  end

  function tests.RuneweaveRefillsAndPlaysOnToTheEndOfTheChain()
    local own, _, private = runeweave()
    local Board = own.Board
    for seed = 1, 40 do
      local random = private.Random.New(seed)
      local board = Board.Make(random)
      local moves = Board.Moves(board)
      local a, b = Board.Swap(moves[random:Roll(#moves)])
      local play = Board.Play(board, a, b, 2, random)
      assert(#play.steps >= 1)
      equal(0, #Board.Groups(board), "nothing left lined up")
      equal(true, Board.CanMove(board), "and a swap to make")
      local total = 0
      for index, step in ipairs(play.steps) do
        equal(index, step.cascade)
        total = total + step.points
        -- Every rune falls from above, or from where it was
        for square = 1, Board.SQUARES do
          local row = Board.Place(square)
          assert(step.from[square] <= row, "nothing falls up")
          assert(step.after[square] ~= 0, "no gaps")
        end
        if index > 1 then
          same(play.steps[index - 1].after, step.before, "a step starts where the one before ended")
        end
      end
      equal(total, play.points)
      if play.shuffled then
        same(play.shuffled, board)
      else
        same(play.steps[#play.steps].after, board)
      end
    end
  end

  function tests.RuneweaveShufflesABoardWithNoSwap()
    local own, _, private = runeweave()
    local Board = own.Board
    local board = quiet(Board)
    local shuffled = Board.Shuffle(board, private.Random.New(3))
    equal(0, #Board.Groups(shuffled))
    equal(true, Board.CanMove(shuffled))
    local had, has = {}, {}
    for square = 1, Board.SQUARES do
      had[board[square]] = (had[board[square]] or 0) + 1
      has[shuffled[square]] = (has[shuffled[square]] or 0) + 1
    end
    same(had, has, "the same runes")
  end

  function tests.RuneweaveSurgesWhenTheLeyMeterFills()
    local state, own, definition, private = game(4)
    state.ley = own.Need(1) - 1
    local moves = state.moves
    local play = definition.apply(state, 1, definition.moves(state, 1)[1], private.Random.New(1))
    assert(play.surges >= 1)
    equal(1 + play.surges, state.level)
    equal(moves - 1 + own.SURGE_MOVES * play.surges, state.moves)
    assert(state.ley < own.Need(state.level))
    equal(1, play.level, "the play says what the level was")
    -- The next move's points are worth more
    local before = state.score
    play = definition.apply(state, 1, definition.moves(state, 1)[1], private.Random.New(2))
    equal(0, play.points % state.level, "multiplied by the level")
    equal(before + play.points, state.score)
  end

  function tests.RuneweaveEndsWhenTheMovesRunOut()
    local state, _, definition, private = game(6)
    state.moves = 1
    equal(nil, definition.result(state))
    definition.apply(state, 1, definition.moves(state, 1)[1], private.Random.New(1))
    if state.moves == 0 then
      equal(true, state.over)
      equal(1, definition.result(state).winner)
      equal("runeweave_out", definition.result(state).detail)
      equal(state.score, definition.record(state)[1].value)
      equal(state.score, definition.daily.score(state))
      equal(0, #definition.moves(state, 1))
      equal(false, (definition.validate(state, 1, "s0r")))
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

  function tests.RuneweaveIsPlayedOnScreen()
    local world = World.New()
    world.seed = 1
    local player = world:AddPlayer("Alice-Realm")
    local MainFrame = openWindow(player)
    local match = assert(player.session:Invite({}, "runeweave"))
    MainFrame.Open(match.id)
    settle(0.1)
    local own = player.private.Runeweave
    local Board = own.Board
    local state = player.private.Match.State(match)

    Client.over = true
    local keys = Client.Find(function(widget)
      return widget.scripts.OnKeyDown ~= nil and widget:IsVisible()
    end)
    assert(#keys > 0, "something takes the keys")
    local function press(key)
      for _, frame in ipairs(keys) do
        frame:Fire("OnKeyDown", key)
      end
    end
    --- Walks the keys' cursor to the top left and on to a square, picks it up and swaps it a way
    local function swapByKeys(square, way)
      press("ESCAPE")
      local row, column = Board.Place(square)
      -- The first shows the cursor where it was, the rest take it to the top left
      for _ = 1, 8 do
        press("UP")
        press("LEFT")
      end
      for _ = 1, column do
        press("RIGHT")
      end
      for _ = 1, row do
        press("DOWN")
      end
      press("SPACE")
      press(way)
    end

    -- A swap that does nothing is shown and not made
    local idle
    for a = 1, Board.SQUARES do
      local row, column = Board.Place(a)
      local right = Board.Square(row, column + 1)
      if right and not Board.Works(state.board, a, right) and not idle then
        idle = a
      end
    end
    Client.sounds = {}
    swapByKeys(idle, "RIGHT")
    equal(0, #match.log, "not made")
    settle(0.5)
    local heard = {}
    for _, sound in ipairs(Client.sounds) do
      heard[sound] = true
    end
    equal(true, heard.bad, "the swap that does nothing")

    -- One that does
    local a, b = Board.Swap(Board.Moves(state.board)[1])
    Client.sounds = {}
    swapByKeys(a, b == a + 1 and "RIGHT" or "DOWN")
    equal(1, #match.log, "the swap was made")
    equal(Board.Write(a, b), match.log[1])
    settle(6)
    heard = {}
    for _, sound in ipairs(Client.sounds) do
      heard[sound] = true
    end
    equal(true, heard.swap, "the runes trade places")
    equal(true, heard.match, "a chime for the line")
    equal(true, heard.land, "and the runes falling into place")

    -- Ready for the next, which the board suggests when left alone
    state = player.private.Match.State(match)
    local next = Board.Moves(state.board)
    a, b = Board.Swap(next[1])
    swapByKeys(a, b == a + 1 and "RIGHT" or "DOWN")
    equal(2, #match.log, "the next swap")
  end

  function tests.RuneweaveIsPlayedToTheEndOnScreen()
    local world = World.New()
    world.seed = 3
    local player = world:AddPlayer("Alice-Realm")
    local MainFrame = openWindow(player)
    local match = assert(player.session:Invite({}, "runeweave"))
    MainFrame.Open(match.id)
    settle(0.1)
    local Board = player.private.Runeweave.Board
    local game = player.private.Games.Get("runeweave")
    local pick = player.private.Random.New(9)
    Client.sounds = {}
    -- Swaps made by clicking one rune and then the other, until the moves run out
    local boards = Client.Find(function(widget)
      return widget.runeweaveBoard and widget:IsVisible()
    end)
    equal(1, #boards, "the board takes the mouse")
    local board = boards[1]
    local function click(square)
      -- The fake client has every frame's left edge at 0 and its top at its height
      local row, column = Board.Place(square)
      local side = board:GetHeight() / Board.SIZE
      Client.cursor = { (column + 0.5) * side, board:GetHeight() - (row + 0.5) * side }
      board:Fire("OnMouseDown", "LeftButton")
      board:Fire("OnMouseUp", "LeftButton")
    end
    for _ = 1, 200 do
      local state = player.private.Match.State(match)
      if state.over then
        break
      end
      local moves = game.moves(state, 1)
      local a, b = Board.Swap(moves[pick:Roll(#moves)])
      local before = #match.log
      click(a)
      click(b)
      equal(before + 1, #match.log, "the swap was made by clicking")
      settle(8)
    end
    local heard = {}
    for _, sound in ipairs(Client.sounds) do
      heard[sound] = true
    end
    equal(true, heard.over, "the game over")
    local state = player.private.Match.State(match)
    equal(true, state.over, "played to the end")
  end
end
