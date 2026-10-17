-- Wordle (Games/Wordle.lua): what a guess says of its letters, which guesses may be made, hard
-- mode, how a game ends and what a run comes to, the words that can be hidden, and the game
-- played in the window.

local function equal(expected, actual, label)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", label or "value", tostring(expected), tostring(actual)), 2)
  end
end

return function(tests, loadEngine, helpers)
  local World, Client, openWindow = helpers.World, helpers.Client, helpers.openWindow

  --- A game of Wordle with the word to find set by hand
  --- @param answer string In capitals
  --- @param rules table?
  --- @return table game, table state, table private
  local function wordle(answer, rules)
    local private = loadEngine()
    local game = private.Games.Get("wordle")
    rules = private.Games.Rules(game.options, rules)
    rules.length = #answer
    local state = game.newState(1, private.Random.New(1), rules)
    state.answer = answer
    return game, state, private
  end

  function tests.WordleMarksEachLetterOfAGuess()
    local private = loadEngine()
    local mark = private.Wordle.Mark
    equal("ccccc", mark("CRANE", "CRANE"))
    equal("xxxxx", mark("CRANE", "SPLIT"))
    equal("ppppp", mark("ABCDE", "EABCD"))
    equal("xxpxc", mark("CRANE", "EERIE"), "an E in its place, and none left over for the other two")
    equal("pxcxp", mark("ABBEY", "BUBBA"), "the B in its place first, then the one B left, from the left")
    equal("cxxxp", mark("SPEED", "SABLE"), "an E somewhere")
    equal("ppxxx", mark("LEVEL", "ELBOW"))
  end

  function tests.WordleTakesOnlyWordsOfTheRightLength()
    local game, state = wordle("CRANE")
    equal(1, game.turn(state))
    equal(nil, game.result(state))
    equal(6, state.tries, "a guess more than the word has letters")
    local wrong = {
      ["cran"] = "wordle_short",
      ["cranes"] = "wordle_short",
      ["CRANE"] = "wordle_short",
      ["cr4ne"] = "wordle_short",
      [""] = "wordle_short",
      ["xqzvw"] = "wordle_not_word",
      ["thrall"] = "wordle_short",
    }
    for move, err in pairs(wrong) do
      equal(false, (game.validate(state, 1, move)), move)
      equal(err, select(2, game.validate(state, 1, move)), move)
    end
    equal("not_your_turn", select(2, game.validate(state, 2, "slate")))
    equal(true, game.validate(state, 1, "slate"))

    local event = game.apply(state, 1, "slate")
    equal("SLATE", event.guess)
    equal("xxcxc", event.marks)
    equal("slate", event.notation)
    equal("wordle_guessed", select(2, game.validate(state, 1, "slate")), "once is enough")
    equal(nil, game.result(state))
    event = game.apply(state, 1, "crane")
    equal(true, event.solved)
    equal(1, game.result(state).winner)
    equal("finished", select(2, game.validate(state, 1, "plane")))
    equal(0, #game.moves(state))
  end

  function tests.WordleIsLostOnceTheGuessesRunOut()
    local game, state = wordle("CRANE")
    for _, guess in ipairs({ "slate", "plane", "brine", "drone", "crone" }) do
      equal(true, game.validate(state, 1, guess), guess)
      game.apply(state, 1, guess)
      equal(nil, game.result(state))
    end
    local event = game.apply(state, 1, "grand")
    equal(true, event.out)
    equal(0, game.result(state).winner)
    equal("wordle_out", game.result(state).detail)
    equal(nil, game.record(state, 30), "nothing worth keeping")
  end

  function tests.WordleInHardModeUsesWhatWasFound()
    local game, state, private = wordle("CRANE", { hard = true })
    game.apply(state, 1, "trace")
    -- T x, R c, A c, C p, E c
    equal("xccpc", state.marks[1])
    equal("wordle_hard", select(2, game.validate(state, 1, "plane")), "the R has to stay where it was found")
    local miss = private.Wordle.Unused(state, "PLANE")
    equal("R", miss.letter)
    equal(2, miss.at)
    miss = private.Wordle.Unused(state, "BRAVE")
    equal("C", miss.letter, "the C has to be in it somewhere")
    equal(nil, miss.at)
    equal(true, game.validate(state, 1, "crane"))
    equal(nil, private.Wordle.Unused(state, "CRANE"))

    -- Twice found is twice needed
    game, state, private = wordle("EERIE", { hard = true })
    game.apply(state, 1, "geese")
    equal("xcpxc", state.marks[1])
    equal("E", private.Wordle.Unused(state, "BEEFY") and private.Wordle.Unused(state, "BEEFY").letter)
    equal("wordle_hard", select(2, game.validate(state, 1, "nerve")), "the second E is still needed somewhere")

    -- Without hard mode anything goes
    game, state = wordle("CRANE")
    game.apply(state, 1, "trace")
    equal(true, game.validate(state, 1, "plane"))
  end

  function tests.WordleListsGuessesThatCanBeMade()
    for _, rules in ipairs({ {}, { hard = true }, { words = "warcraft" }, { words = "warcraft", hard = true, length = 7 } }) do
      local private = loadEngine()
      local game = private.Games.Get("wordle")
      local state = game.newState(1, private.Random.New(9), private.Games.Rules(game.options, rules))
      local plies = 0
      while not game.result(state) do
        local list = game.moves(state)
        assert(#list > 0, "something to guess")
        for _, move in ipairs(list) do
          equal(true, (game.validate(state, 1, move)), move)
        end
        game.apply(state, 1, list[1])
        plies = plies + 1
      end
      assert(plies <= state.tries)
    end
  end

  function tests.WordleHidesWordsThatCanBeGuessed()
    local private = loadEngine()
    local Lexicon = private.Lexicon
    for _, length in ipairs({ 4, 5, 6, 7 }) do
      local everyday, warcraft = Lexicon.Size("wordle", length), Lexicon.Size("wordlewarcraft", length)
      assert(everyday > 1000, length .. " letters: only " .. everyday .. " everyday words")
      assert(warcraft > 20, length .. " letters: only " .. warcraft .. " Warcraft words")
      for index = 1, everyday do
        local word = Lexicon.At("wordle", length, index)
        assert(Lexicon.Has("english", word), word .. " can't be guessed")
      end
      for index = 1, warcraft do
        local word = Lexicon.At("wordlewarcraft", length, index)
        assert(Lexicon.Entry("warcraft", word), word .. " isn't a name of Azeroth")
      end
    end
    equal(nil, Lexicon.At("wordle", 5, 0))
    equal(nil, Lexicon.At("wordle", 5, Lexicon.Size("wordle", 5) + 1))
    equal(0, Lexicon.Size("wordle", 3))

    -- What is hidden is part of the rules: players with other lists wouldn't hide the same word
    -- for the day. After changing a list, give Wordle a new version (Games/Wordle.lua) and write
    -- that version and the new numbers here
    equal(1, private.Games.Get("wordle").version)
    equal(365510098, Lexicon.Stamp("english"), "the English list changed")
    equal(1614400711, Lexicon.Stamp("warcraft"), "the Warcraft list changed")
    equal(1564111640, Lexicon.Stamp("wordle"), "the everyday words to find changed")
    equal(1324231471, Lexicon.Stamp("wordlewarcraft"), "the Warcraft words to find changed")
  end

  function tests.WordleScoresFewerGuessesThenLessTime()
    local game, state, private = wordle("CRANE")
    local Wordle = private.Wordle
    game.apply(state, 1, "slate")
    game.apply(state, 1, "crane")
    local two = Wordle.Score(state, 80)
    local quick = Wordle.Score(state, 10)
    assert(quick > two, "the quicker the better")
    local _, three = wordle("CRANE")
    game.apply(three, 1, "slate")
    game.apply(three, 1, "plane")
    game.apply(three, 1, "crane")
    assert(two > Wordle.Score(three, 1), "a guess fewer beats any time")
    assert(Wordle.Score(three, 99999) > 0, "however long it took")
    local records = game.record(state, 80)
    equal("score5", records[1].key)
    equal(two, records[1].value)
    equal("score6wh", Wordle.ScoreKey(6, "warcraft", true))
    local raced = game.raceFor({ length = 5, words = "everyday", hard = false })
    equal("score5", raced.key)
    equal("string", type(raced.show(two)))
    equal(2, game.daily.score(state), "the day's word counts by its guesses")
    equal(nil, game.daily.score({ outcome = { winner = 0, detail = "wordle_out" }, guesses = {} }), "nothing for a word not found")
  end

  -----------------------------
  -- On screen
  -----------------------------

  --- Opens the window on a new game of Wordle
  local function wordleOnScreen()
    local world = World.New()
    world.seed = 1
    local player = world:AddPlayer("Alice-Realm")
    local MainFrame = openWindow(player)
    local match = assert(player.session:Invite({}, "wordle"))
    MainFrame.Open(match.id)
    return player, match, MainFrame
  end

  --- Presses a key with the cursor over the game
  local function press(key)
    Client.over = true
    local found = Client.Find(function(widget)
      return widget.scripts.OnKeyDown ~= nil and widget:IsVisible()
    end)
    for _, frame in ipairs(found) do
      frame:Fire("OnKeyDown", key)
    end
  end

  local function typeWord(word)
    for letter in word:gmatch(".") do
      press(letter:upper())
    end
  end

  --- Lets the tiles turn over
  local function settle()
    for _ = 1, 150 do
      for _, frame in ipairs(Client.Find(function(widget)
        return widget.scripts.OnUpdate ~= nil and widget:IsVisible()
      end)) do
        frame:Fire("OnUpdate", 0.02)
      end
    end
  end

  --- The letters showing on the tiles of the board, a row at a time
  local function tilesOnScreen()
    local found = Client.Find(function(widget)
      return widget.kind == "Frame" and widget.letter ~= nil and widget:IsVisible()
    end)
    local letters = {}
    for _, tile in ipairs(found) do
      letters[#letters + 1] = tile.letter
    end
    return table.concat(letters)
  end

  --- The key of the keyboard on screen showing a text
  local function keyOnScreen(text)
    local found = Client.Find(function(widget)
      return widget.kind == "FontString" and widget.text == text and widget.parent and widget.parent.kind == "Button" and widget:IsVisible()
    end)
    equal(1, #found, "keys saying " .. text)
    return found[1].parent
  end

  function tests.WindowPlaysWordle()
    local player, match = wordleOnScreen()
    local Match = player.private.Match
    local state = Match.State(match)
    equal("", tilesOnScreen(), "nothing typed yet")

    -- Typed with the keys, or clicked on the keyboard, and taken back with Backspace
    typeWord("sla")
    keyOnScreen("T"):Fire("OnClick")
    press("E")
    press("X")
    equal("SLATE", tilesOnScreen(), "no more letters than the word has")
    press("BACKSPACE")
    equal("SLAT", tilesOnScreen())

    -- What can't be guessed says why, and stays typed
    press("ENTER")
    equal(0, #match.log)
    equal(true, #Client.Find(function(widget)
      return widget.text == "wordle_short" and widget:IsVisible()
    end) == 1)
    press("Z")
    press("ENTER")
    equal(0, #match.log, "SLATZ isn't a word")
    equal(true, #Client.Find(function(widget)
      return widget.text == "wordle_not_word" and widget:IsVisible()
    end) == 1)

    -- A word is guessed, and its tiles turn over to show what it said
    press("BACKSPACE")
    press("E")
    local guess = state.answer == "SLATE" and "crane" or "slate"
    if guess == "crane" then
      for _ = 1, 5 do
        press("BACKSPACE")
      end
      typeWord(guess)
    end
    press("ENTER")
    equal(guess, match.log[1])
    settle()
    local marks = player.private.Wordle.Mark(state.answer, guess:upper())
    for index = 1, 5 do
      local letter = guess:sub(index, index):upper()
      local said = marks:sub(index, index)
      local found = Client.Find(function(widget)
        return widget.kind == "Frame" and widget.letter == letter and widget.said == said and widget:IsVisible()
      end)
      assert(#found >= 1, letter .. " shows what was said of it")
    end

    -- The word itself ends the game
    typeWord(state.answer:lower())
    press("ENTER")
    settle()
    equal(state.answer:lower(), match.log[2])
    equal(1, Match.Result(match).winner)
    equal(true, #Client.Find(function(widget)
      return widget.text == "wordle_quality_epic" and widget:IsVisible()
    end) == 1, "found in two")
  end
end
