-- FreeCell (Games/FreeCell.lua): Microsoft's deals, what may go where, how many cards may go
-- across at once, cards going home by themselves, the rest played out, and a game with nothing
-- left to move.

local function equal(expected, actual, label)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", label or "value", tostring(expected), tostring(actual)), 2)
  end
end

return function(tests, loadEngine)
  local RANKS = "A23456789TJQK"

  --- @return table game, table private
  local function freecell()
    local private = loadEngine()
    return private.Games.Get("freecell"), private
  end

  --- A position with nothing in it, to lay out by hand
  local function empty(game, private)
    local state = game.newState(1, private.Random.New(1))
    state.cells = { false, false, false, false }
    for column = 1, 8 do
      state.columns[column] = {}
    end
    return state
  end

  --- Every card is somewhere, and only once
  local function sound(state)
    local seen, count = {}, 0
    local function saw(card)
      assert(not seen[card], card .. " is on the table twice")
      seen[card], count = true, count + 1
    end
    for _, cell in ipairs(state.cells) do
      if cell then
        saw(cell)
      end
    end
    for _, cards in ipairs(state.columns) do
      for _, card in ipairs(cards) do
        saw(card)
      end
    end
    for suit, cards in pairs(state.homes) do
      for rank, card in ipairs(cards) do
        equal(RANKS:sub(rank, rank) .. suit, card, "home is built up from the ace")
        saw(card)
      end
    end
    equal(52, count, "cards on the table")
  end

  --- Sends home every card of a suit up to a rank
  local function homeTo(state, suit, rank)
    for at = 1, rank do
      state.homes[suit][at] = RANKS:sub(at, at) .. suit
    end
  end

  function tests.FreeCellDealsMicrosoftsDeals()
    local game, private = freecell()
    local first = private.FreeCell.Dealt(1)
    equal("JD 2D 9H JC 5D 7H 7C 5H", table.concat(first, " ", 1, 8), "the first row of game 1")
    equal("KD KC 9S 5S AD QC KH 3H", table.concat(first, " ", 9, 16), "and the second")
    equal("7D AD 5C 3S 5S 8C 2D AH", table.concat(private.FreeCell.Dealt(617), " ", 1, 8), "game 617")

    local state = game.newState(1, private.Random.New(3))
    sound(state)
    for column = 1, 8 do
      equal(column <= 4 and 7 or 6, #state.columns[column], "cards in column " .. column)
    end
    equal(state.columns[1][1], private.FreeCell.Dealt(state.deal)[1], "dealt across the columns, a row at a time")
    equal(state.columns[2][1], private.FreeCell.Dealt(state.deal)[2])
    equal(state.columns[1][2], private.FreeCell.Dealt(state.deal)[9])
    equal(state.deal, game.newState(1, private.Random.New(3)).deal, "the same deal from the same seed")
    equal(1, game.turn(state))
    equal(nil, game.result(state))
    equal("not_your_turn", select(2, game.validate(state, 2, "1a")))

    -- The one deal nobody can win is skipped over
    local function rolling(value)
      return { Roll = function()
        return value
      end }
    end
    equal(11981, game.newState(1, rolling(11981)).deal)
    equal(11983, game.newState(1, rolling(11982)).deal)
    equal(32000, game.newState(1, rolling(31999)).deal)
  end

  function tests.FreeCellMovesThroughTheCellsAndDownTheColumns()
    local game, private = freecell()
    local state = empty(game, private)
    state.columns[1] = { "9C", "KH", "QS" }
    state.columns[2] = { "KD" }
    state.columns[3] = { "4D", "JH" }
    state.columns[4] = { "JS" }
    state.cells[2] = "5C"

    local wrong = {
      ["32"] = "a jack on a king",
      ["41"] = "black on black",
      ["13"] = "a queen on a jack",
      ["11"] = "a card onto its own column",
      ["1b"] = "into a cell that is taken",
      ["a1"] = "out of a cell that is empty",
      ["b1"] = "a five on a queen",
      ["122"] = "a king doesn't go on a king",
      ["3f"] = "a jack home before its ace",
      ["9a"] = "a column there isn't",
      ["1e"] = "a cell there isn't",
      ["121"] = "one card written as if it were several",
      ["1202"] = "a number written another way",
      ["1a2"] = "more than one card into a cell",
      ["x"] = "nothing to play out",
      [""] = "nothing",
    }
    for move, why in pairs(wrong) do
      equal("invalid_move", select(2, game.validate(state, 1, move)), why)
    end

    equal(true, game.validate(state, 1, "31"), "the red jack on the black queen")
    local event = game.apply(state, 1, "31")
    equal("JH", table.concat(event.cards, ","))
    equal("9C,KH,QS,JH", table.concat(state.columns[1], ","))
    equal(true, game.validate(state, 1, "35"), "anything goes into an empty column")
    equal(true, game.validate(state, 1, "3a"))
    game.apply(state, 1, "3a")
    equal("4D", state.cells[1])
    equal(0, #state.columns[3])
    equal(true, game.validate(state, 1, "a5"), "and out again")
    equal("invalid_move", select(2, game.validate(state, 1, "b2")), "a five doesn't go on a king")
    equal(true, game.validate(state, 1, "b5"), "but into an empty column")
    equal(true, game.validate(state, 1, "132"), "a run of two, the queen and the jack, into an empty column")
    equal(2, state.moves)
  end

  function tests.FreeCellCarriesAsManyCardsAsTheCellsAndColumnsLeaveRoomFor()
    local game, private = freecell()
    local state = empty(game, private)
    local capacity = private.FreeCell.Capacity
    state.columns[1] = { "KS", "QH", "JC", "TD", "9S", "8H" }
    state.columns[2] = { "2C", "KC" }
    state.columns[3] = { "3C", "TH" }
    state.columns[4] = { "4C" }
    state.columns[5] = { "5C" }
    state.columns[6] = { "6C" }
    state.columns[7] = { "7C" }
    state.columns[8] = { "8C" }
    state.cells = { "AD", "2D", false, false }

    equal(3, capacity(state), "two cells free and no empty column: three cards")
    equal(true, game.validate(state, 1, "132"), "two cards, the nine and the eight, onto the ten")
    equal("invalid_move", select(2, game.validate(state, 1, "125")), "but not all five from the queen")
    equal("invalid_move", select(2, game.validate(state, 1, "133")), "and not a run onto a card that doesn't take its foot")

    state.columns[6] = {}
    equal(6, capacity(state), "an empty column doubles it")
    equal(3, capacity(state, "6"), "but not for cards going into it")
    equal(true, game.validate(state, 1, "125"), "the queen and all on it, five, onto the king")
    equal(true, game.validate(state, 1, "163"), "three into the empty column")
    equal("invalid_move", select(2, game.validate(state, 1, "164")), "but not four")
    local event = game.apply(state, 1, "125")
    equal("QH,JC,TD,9S,8H", table.concat(event.cards, ","))
    equal("2C,KC,QH,JC,TD,9S,8H", table.concat(state.columns[2], ","))
    equal("KS", table.concat(state.columns[1], ","))
  end

  function tests.FreeCellSendsHomeWhatNothingCouldStillWant()
    local game, private = freecell()
    local state = empty(game, private)
    homeTo(state, "S", 1)
    homeTo(state, "C", 1)
    state.columns[1] = { "AD", "KC" }
    state.columns[2] = { "3H" }
    state.cells[1] = "2C"

    -- Taking the king off the ace of diamonds lets it go home, and the two of clubs in its cell,
    -- a two, goes as well
    local event = game.apply(state, 1, "1b")
    equal("KC", table.concat(event.cards, ","))
    equal("2C,AD", table.concat(event.auto, ","), "the cells first, then the columns")
    equal(false, state.cells[1])
    equal(0, #state.columns[1])
    equal("3H", state.columns[2][1], "a three with no ace of its suit home stays")

    -- Once one goes, round again: the three follows the two once both black piles are at two
    state = empty(game, private)
    homeTo(state, "S", 2)
    homeTo(state, "C", 2)
    homeTo(state, "H", 2)
    homeTo(state, "D", 1)
    state.columns[1] = { "3H", "2D" }
    state.columns[2] = { "9C" }
    event = game.apply(state, 1, "2a")
    equal("2D,3H", table.concat(event.auto, ","))

    -- A card a column could still want stays where it is
    state = empty(game, private)
    homeTo(state, "H", 4)
    homeTo(state, "S", 2)
    homeTo(state, "C", 4)
    homeTo(state, "D", 2)
    state.columns[1] = { "5H" }
    state.columns[2] = { "KS", "9C" }
    event = game.apply(state, 1, "2a")
    equal(nil, event.auto, "the five of hearts could still go on a black six, and the spades are only at two")
    equal("5H", state.columns[1][1])
    equal(true, game.validate(state, 1, "1f"), "though it may be sent home by hand")
  end

  function tests.FreeCellPlaysTheRestOutOnceTheColumnsAreInOrder()
    local game, private = freecell()
    local state = empty(game, private)
    for _, suit in ipairs({ "S", "H", "D", "C" }) do
      homeTo(state, suit, 9)
    end
    state.columns[1] = { "KS", "QH", "TC" }
    state.columns[2] = { "KD", "JS", "TS" }
    state.columns[3] = { "KH", "JC" }
    state.cells = { "QS", "TH", "KC", false }
    state.columns[4] = { "JD", "TD" }
    state.columns[5] = { "QD", "JH" }
    state.columns[6] = { "QC" }
    sound(state)
    equal(true, private.FreeCell.CanFinish(state))
    equal(true, game.validate(state, 1, "x"))
    local event = game.apply(state, 1, "x")
    equal("TS,TH,TD,TC,JS,JH,JD,JC,QS,QH,QD,QC,KS,KH,KD,KC", table.concat(event.finished, ","), "lowest first")
    equal(1, game.result(state).winner)
    sound(state)

    state = empty(game, private)
    for _, suit in ipairs({ "S", "H", "D", "C" }) do
      homeTo(state, suit, 11)
    end
    state.columns[1] = { "QS", "KS" }
    state.columns[2] = { "KH", "QH", "KD", "QD", "KC", "QC" }
    equal(false, private.FreeCell.CanFinish(state), "a king on a queen of its own suit isn't in order")
  end

  function tests.FreeCellIsLostWithNothingLeftToMove()
    local game, private = freecell()
    local state = empty(game, private)
    -- Every cell full, nothing goes on anything, and nothing is next for home
    state.cells = { "9S", "9H", "9D", "8C" }
    state.columns = { { "AS", "KS" }, { "5D", "KH" }, { "AD", "KD" }, { "AC", "KC" }, { "2S", "4H" }, { "2H", "4S" }, { "2D", "4C" }, { "3S", "4D" } }
    equal(0, #game.moves(state))
    -- One move left, the ace of hearts home, and nothing after it
    state.columns[8][3] = "AH"
    equal("8f", table.concat(game.moves(state), ","))
    local event = game.apply(state, 1, "8f")
    equal(true, event.stuck)
    equal(0, game.result(state).winner)
    equal("freecell_stuck", game.result(state).detail)
    equal("finished", select(2, game.validate(state, 1, "d8")))
  end

  function tests.FreeCellIsPlayedThroughWithoutLosingACard()
    local game, private = freecell()
    for seed = 1, 12 do
      local state = game.newState(1, private.Random.New(seed))
      local dice = private.Random.New(seed + 100)
      local plies = 0
      while not game.result(state) and plies < 400 do
        local list = game.moves(state)
        -- Home first, then anything onto a column, then whatever there is
        local pick
        for _, move in ipairs(list) do
          if move == "x" or move:sub(2, 2) == "f" then
            pick = pick or move
          end
        end
        pick = pick or list[dice:Roll(#list)]
        for _, move in ipairs(list) do
          equal(true, (game.validate(state, 1, move)), "listed " .. move)
        end
        game.apply(state, 1, pick)
        sound(state)
        plies = plies + 1
      end
    end
  end
end
