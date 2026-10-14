-- The checks every game is put through, whoever wrote it: one test for each game there is,
-- EveryGame_<id>, so that a new game is checked the moment it is registered.
--
-- What a game is held to is what the engine takes on trust (Engine/Games.lua). Its rules are
-- replayed on every client from nothing but the log, so they must come out the same wherever
-- they run: the same seed deals the same game, and nothing in them asks the client for the time
-- or a random number of its own. While the rules run here those are taken away, and so is the
-- trigonometry for a game more than one plays, which isn't worked out the same on every computer.
-- Whatever the game shows the players by name has to be in the locale, and so does whatever it
-- says about how a game is going.
--
-- A game that lists its moves (GameDefinition.moves) is played out at random from a few seeds,
-- for every number of players it takes and with its options set this way and that, now and
-- then with somebody resigning from a crowd. Every move it lists has to be one it takes, one
-- that travels in a message, and asking about moves must never change the position. Where a
-- game ends, it has to end in a way the window can say. And the log it leaves has to replay to
-- the same position, from scratch, on a client that never saw it played, and at every point
-- along the way.
--
-- A game the computer plays (GameDefinition.computer) has it decide on moves at some of the
-- positions those games pass through, at every level: what it decides on has to be a move the
-- game takes, the same one every time from the same position, and deciding must never change
-- what it was shown. What the game tells it is held to account too: what it guesses at a hidden
-- position has to look from the seat exactly like what the seat sees, a copy has to be a copy,
-- and how good a position is has to be a number well short of a win. And it has to be able to
-- play a whole game against itself.

local MAX_PLIES = 300
local SEEDS = 3
-- How many of the moves listed in a position are put to validate
local SAMPLE = 30
-- In a crowd one in so many plies is somebody resigning instead
local RESIGN_ODDS = 40
-- How long a game the computer plays against itself may go on for
local COMPUTER_PLIES = 80

--- Writes a value out the same way every time, keys in order, so two can be compared
--- @param value any
--- @param path table<table, boolean>? The tables it is inside of, to catch one inside itself
--- @param out string[]?
--- @return string? Nil but from the outermost call
local function serialize(value, path, out)
  -- Only the outermost call puts it all together, every one inside it adds to the same list
  local outermost = out == nil
  out = out or {}
  path = path or {}
  local kind = type(value)
  if kind == "table" then
    assert(not path[value], "a table that contains itself")
    path[value] = true
    -- What a table reads as, what it reads through to included (Computer.Over)
    local keys, seen, from = {}, {}, value
    while type(from) == "table" do
      for key in pairs(from) do
        if not seen[key] then
          seen[key] = true
          keys[#keys + 1] = key
        end
      end
      local meta = getmetatable(from)
      from = meta and meta.__index
    end
    table.sort(keys, function(a, b)
      local ta, tb = type(a), type(b)
      if ta ~= tb then
        return ta < tb
      end
      if ta == "number" or ta == "string" then
        return a < b
      end
      return tostring(a) < tostring(b)
    end)
    out[#out + 1] = "{"
    for _, key in ipairs(keys) do
      serialize(key, path, out)
      out[#out + 1] = "="
      serialize(value[key], path, out)
      out[#out + 1] = ","
    end
    out[#out + 1] = "}"
    path[value] = nil
  elseif kind == "number" then
    out[#out + 1] = string.format("%.17g", value)
  elseif kind == "string" then
    out[#out + 1] = string.format("%q", value)
  else
    out[#out + 1] = tostring(kind == "function" and kind or value)
  end
  return outermost and table.concat(out) or nil
end

--- Every key the English locale has
--- @return table<string, boolean>
local function localeKeys()
  local file = assert(io.open("Locales/enUS.lua"))
  local text = file:read("*a")
  file:close()
  local keys = {}
  for key in text:gmatch('L%["([^"]+)"%]%s*=') do
    keys[key] = true
  end
  return keys
end

-- The tests' locale hands back the key it was asked for, so a string that is shaped like one is
-- what the game asked the locale for
local function looksLikeKey(text)
  return type(text) == "string" and text:match("^[%l%d_]+$") ~= nil and text:find("_", 1, true) ~= nil
end

-- What the rules may not ask the client
local CLIENT = {
  { math, "math", { "random", "randomseed" } },
  { os, "os", { "time", "clock", "date" } },
  { _G, "", { "time", "date", "random", "fastrandom", "GetTime", "GetServerTime", "GetTimePreciseSec", "debugprofilestop" } },
}
local TRIGONOMETRY = { math, "math", { "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "exp", "log", "log10", "pow", "sinh", "cosh", "tanh" } }

--- Runs something with what the rules may not ask for taken away
--- @param shared boolean The game is played by more than one, whose clients have to agree
--- @param run fun()
local function sandboxed(shared, run)
  local saved = {}
  local function forbid(group)
    local where, name, keys = group[1], group[2], group[3]
    for _, key in ipairs(keys) do
      saved[#saved + 1] = { where, key, rawget(where, key) }
      local called = (name ~= "" and name .. "." or "") .. key
      rawset(where, key, function()
        error("the rules asked for " .. called .. ", which another client would answer differently", 2)
      end)
    end
  end
  for _, group in ipairs(CLIENT) do
    forbid(group)
  end
  if shared then
    forbid(TRIGONOMETRY)
  end
  local ok, err = xpcall(run, debug.traceback)
  for index = #saved, 1, -1 do
    rawset(saved[index][1], saved[index][2], saved[index][3])
  end
  if not ok then
    error(err, 0)
  end
end

--- A match of so many players of a game, made the way the session makes one, with nothing played
--- @param private table
--- @param game GameDefinition
--- @param id string
--- @param seats number
--- @param chosen table<string, any>?
--- @return Match
local function newMatch(private, game, id, seats, chosen)
  local players = {}
  for seat = 1, seats do
    players[seat] = "Player" .. seat .. "-Realm"
  end
  local match = {
    id = id,
    game = game.id,
    gameVersion = game.version,
    players = players,
    options = private.Games.Chosen(game, private.Games.ForPlayers(game, chosen, seats)),
    me = 1,
    log = {},
    status = "active",
    seen = {},
    created = 0,
    updated = 0,
  }
  if seats > 2 then
    match.host = 1
    assert(private.Match.Append(match, private.Match.START))
  end
  return match
end

--- The same match on another table, so that it is replayed from scratch
--- @param match Match
--- @param length number? Only so many log entries of it
--- @return Match
local function again(match, length)
  local copy = {}
  for key, value in pairs(match) do
    copy[key] = value
  end
  copy.log, copy.status = {}, "active"
  for index = 1, length or #match.log do
    copy.log[index] = match.log[index]
  end
  return copy
end

--- Every way the rules can be set that a test plays: the usual way, and each option every way it
--- can be on its own
--- @param Games Games
--- @param game GameDefinition
--- @return table<string, any>[]
local function variants(Games, game)
  local list = { {} }
  for _, option in ipairs(game.options or {}) do
    for _, value in ipairs(Games.Choices(option)) do
      if value ~= option.default then
        list[#list + 1] = { [option.id] = value }
      end
    end
  end
  return list
end

--- @param keys table<string, boolean>
--- @param text any
--- @param what string
local function inLocale(keys, text, what)
  if looksLikeKey(text) and not keys[text] then
    error(what .. " is " .. text .. ", which the locale doesn't have", 0)
  end
end

--- What the game shows the players about itself has to be in the locale
--- @param private table
--- @param game GameDefinition
--- @param keys table<string, boolean>
local function checkNames(private, game, keys)
  local Games = private.Games
  inLocale(keys, game.name, "its name")
  inLocale(keys, game.description, "its description")
  if game.genre and not keys["genre_" .. game.genre] then
    error("its genre is " .. game.genre .. ", and the locale has no genre_" .. game.genre, 0)
  end
  for _, option in ipairs(game.options or {}) do
    inLocale(keys, option.name, "option " .. option.id .. "'s name")
    inLocale(keys, option.description, "option " .. option.id .. "'s description")
    for _, value in ipairs(Games.Choices(option)) do
      inLocale(keys, Games.OptionLabel(option, value), "option " .. option.id .. " set to " .. tostring(value))
    end
  end
  if game.seatLabel then
    for _, seats in ipairs(Games.SeatCounts(game)) do
      for seat = 1, seats do
        inLocale(keys, game.seatLabel(seat, seats), "seat " .. seat .. " of " .. seats)
      end
    end
  end
end

--- Checks a position that is being played: whose turn it is, and what each seat is shown of it
--- @param private table
--- @param game GameDefinition
--- @param match Match
--- @param state table
local function checkPosition(private, game, match, state)
  local seats = #match.players
  if not game.together then
    local turn = game.turn(state)
    assert(type(turn) == "number" and turn >= 1 and turn <= seats, "turn says it is seat " .. tostring(turn) .. "'s")
    assert(not private.Match.IsOut(match, turn), "turn says it is seat " .. turn .. "'s, who resigned")
  end
  if game.visible then
    for seat = 1, seats do
      local shown = game.visible(state, seat)
      assert(type(shown) == "table", "visible gave seat " .. seat .. " no table")
      assert(shown ~= state, "visible gave seat " .. seat .. " the state itself, not a copy")
    end
  end
end

--- What a game says about how it is going, and what it would have remembered of it
--- @param private table
--- @param game GameDefinition
--- @param match Match
--- @param keys table<string, boolean>
local function checkProgress(private, game, match, keys)
  local state, result = private.Match.State(match), private.Match.Result(match)
  if game.progress then
    local progress = game.progress(state)
    assert(progress == nil or type(progress) == "string", "progress gave a " .. type(progress))
    inLocale(keys, progress, "its progress")
  end
  if game.record and #match.players == 1 then
    local records = game.record(state, 60, result)
    assert(records == nil or type(records) == "table", "record gave a " .. type(records))
    for _, record in ipairs(records or {}) do
      assert(type(record.key) == "string" and record.key:match("^[%w_]+$"), "record gave a key of " .. tostring(record.key))
      assert(type(record.value) == "number" and record.value == record.value, "record gave " .. record.key .. " a value of " .. tostring(record.value))
    end
  end
end

--- A new game of every size and set every way deals the same twice from the same seed. Sizes
--- and settings take turns, a game that is dear to deal (an island to raise) is dealt no more
--- often than it has either
--- @param private table
--- @param game GameDefinition
--- @param keys table<string, boolean>
local function checkDeals(private, game, keys)
  local Games, Match = private.Games, private.Match
  local counts, list = Games.SeatCounts(game), variants(Games, game)
  for index = 1, math.max(#counts, #list) do
    local seats, chosen = counts[(index - 1) % #counts + 1], list[(index - 1) % #list + 1]
    do
      local where = string.format("%d players, rules %s", seats, Games.EncodeOptions(game, chosen) or "usual")
      local id = "deal" .. seats .. "x" .. index
      local first = newMatch(private, game, id, seats, chosen)
      local state = assert(Match.State(first), where .. ": no state")
      assert(Match.Result(first) == nil, where .. ": the game is over before it began")
      local dealt = serialize(state)
      assert(serialize(Match.State(newMatch(private, game, id, seats, chosen))) == dealt, where .. ": the same seed dealt another game")
      checkPosition(private, game, first, state)
      checkProgress(private, game, first, keys)
      assert(serialize(state) == dealt, where .. ": turn, visible or progress changed the state")
    end
  end
end

--- @param private table
--- @param game GameDefinition
--- @param match Match
--- @param keys table<string, boolean>
local function checkResult(private, game, match, keys)
  local result = private.Match.Result(match)
  if not result then
    return
  end
  local winner = result.winner
  assert(type(winner) == "number" and winner >= 0 and winner <= #match.players and winner == math.floor(winner), "the winner is seat " .. tostring(winner))
  if result.detail and not keys["result_" .. result.detail] then
    error("the game ended by " .. result.detail .. ", and the locale has no result_" .. result.detail, 0)
  end
end

--- Checks what a game tells the computer, in a position, and has it decide on a move there
--- @param private table
--- @param game GameDefinition
--- @param state table
--- @param seat number Whose move it is
--- @param level string
--- @param seed number
local function checkComputer(private, game, state, seat, level, seed)
  local Computer, computer = private.Computer, game.computer
  local before = serialize(state)
  local seen = game.visible and game.visible(state, seat) or Computer.Copy(state)
  local shown = serialize(seen)

  if game.visible and computer.guess then
    for try = 1, 3 do
      local world = computer.guess(seen, seat, private.Random.New(seed + try))
      assert(type(world) == "table" and world ~= seen, "guess gave no whole position of its own")
      assert(serialize(seen) == shown, "guessing changed what the seat sees")
      local looks = serialize(game.visible(world, seat))
      assert(looks == shown, "what it guessed doesn't look like what the seat sees:\n" .. looks .. "\n" .. shown)
      local again = computer.guess(seen, seat, private.Random.New(seed + try))
      assert(serialize(again) == serialize(world), "guessed something else from the same dice")
    end
  end
  if computer.copy then
    local list = game.moves(state, seat)
    local copy = computer.copy(state)
    assert(serialize(copy) == before, "a copy isn't the same as the position")
    game.apply(copy, seat, list[1], private.Random.New(seed))
    assert(serialize(state) == before, "a move on a copy changed the position it was copied from")
  end
  if computer.evaluate and not game.visible then
    local worth = computer.evaluate(state, seat)
    assert(type(worth) == "number" and worth == worth and math.abs(worth) < Computer.WIN / 4, "evaluate said " .. tostring(worth))
    assert(serialize(state) == before, "evaluate changed the position")
  end
  if computer.key and not game.visible then
    assert(type(computer.key(state)) == "string", "key gave no string")
    assert(computer.key(Computer.Copy(state)) == computer.key(state), "a copy of the position goes by another key")
  end

  local thinker = Computer.Think(game, seen, seat, level, seed)
  local move = thinker:Finish()
  assert(not thinker.failed, "it failed: " .. tostring(thinker.failed))
  assert(type(move) == "string", "it decided on " .. tostring(move))
  assert(serialize(seen) == shown, "deciding changed what it was shown")
  assert(serialize(state) == before, "deciding changed the position")
  local ok, err = game.validate(state, seat, move)
  assert(ok, "it decided on " .. move .. ", which the game refuses: " .. tostring(err))
  local shownAgain = game.visible and game.visible(state, seat) or Computer.Copy(state)
  local again = Computer.Think(game, shownAgain, seat, level, seed):Finish()
  assert(again == move, "it decided on " .. move .. " and then on " .. tostring(again) .. " from the same position")
end

--- Has the computer play every seat of a game at its easiest, as a match, until it is over
--- @param private table
--- @param game GameDefinition
--- @param seats number
--- @param keys table<string, boolean>
local function playItself(private, game, seats, keys)
  local Match, Computer = private.Match, private.Computer
  local id = string.format("%x%06x", 1800000000 + seats, seats)
  local match = newMatch(private, game, id, seats, {})
  for ply = 1, COMPUTER_PLIES do
    if Match.Result(match) then
      break
    end
    local seat = Match.Turn(match)
    local state = Match.State(match)
    local seen = Computer.Copy(game.visible and game.visible(state, seat) or state)
    local thinker = Computer.Think(game, seen, seat, "easy", ply)
    local move = thinker:Finish()
    if thinker.failed or type(move) ~= "string" then
      error(string.format("%d players, ply %d: the computer failed: %s", seats, ply, tostring(thinker.failed or move)), 0)
    end
    local ok, err = Match.Append(match, move)
    if not ok then
      local log = table.concat(match.log, " ")
      error(string.format("%d players, ply %d: the computer played %s, which was refused: %s\nlog: %s", seats, ply, move, tostring(err), log), 0)
    end
  end
  local ok, err = pcall(checkResult, private, game, match, keys)
  if not ok then
    error(string.format("%d players, against itself: %s", seats, tostring(err)), 0)
  end
end

--- Plays one game out at random, checking every position on the way
--- @param private table
--- @param game GameDefinition
--- @param seats number
--- @param seed number
--- @param keys table<string, boolean>
--- @param loadEngine fun(): table
--- @param looks table[] Where to put the positions for the computer to decide in, see checkComputer
local function playOut(private, game, seats, seed, keys, loadEngine, looks)
  local Games, Match, Codec, Random = private.Games, private.Match, private.Codec, private.Random
  local dice = Random.New(Random.Seed(game.id .. ":" .. seats .. ":" .. seed))

  -- The usual rules first, then every option set any way it can be
  local chosen = {}
  if seed > 1 then
    for _, option in ipairs(game.options or {}) do
      local choices = Games.Choices(option)
      chosen[option.id] = choices[dice:Roll(#choices)]
    end
  end
  local id = string.format("%x%06x", 1700000000 + seed, seats * 1000 + seed)
  local match = newMatch(private, game, id, seats, chosen)
  local shared = not Games.IsSolo(game)
  -- The most a move may be and still go in a message with everything else a MOV has
  local longest = Codec.MAX_LENGTH - #Codec.Encode("MOV", id, 99999, 99999, "", 2147483646)
  -- A few positions to look back at once it is over
  local marks, snapshots = {}, {}
  for _ = 1, 3 do
    marks[dice:Roll(MAX_PLIES)] = true
  end
  -- And one for the computer to decide on a move in, at a level for each game played out: any
  -- of the positions the game goes through, each as likely as the next however long it lasts
  local look = nil
  local level = private.Computer.LEVELS[(seed - 1) % #private.Computer.LEVELS + 1]

  local function fail(ply, text)
    local rules = Games.EncodeOptions(game, match.options) or "usual"
    error(string.format("%d players, seed %d, rules %s, ply %d: %s\nlog: %s", seats, seed, rules, ply, text, table.concat(match.log, " ")), 0)
  end

  for ply = 1, MAX_PLIES do
    if Match.Result(match) then
      break
    end
    local state = Match.State(match)
    local before = serialize(state)
    checkPosition(private, game, match, state)

    -- Whose move it is, and what they can do
    local seat, list
    if game.together then
      local order = {}
      for candidate = 1, seats do
        if not Match.IsOut(match, candidate) then
          order[#order + 1] = candidate
        end
      end
      dice:Shuffle(order)
      for _, candidate in ipairs(order) do
        local found = game.moves(state, candidate)
        if type(found) == "table" and #found > 0 then
          seat, list = candidate, found
          break
        end
      end
      if not seat then
        fail(ply, "nobody has a move, and the game isn't over")
      end
    else
      seat = game.turn(state)
      list = game.moves(state, seat)
      if type(list) ~= "table" or #list == 0 then
        fail(ply, "seat " .. seat .. " has no move, and the game isn't over")
      end
    end

    local listed = {}
    for _, move in ipairs(list) do
      if type(move) ~= "string" then
        fail(ply, "moves listed a " .. type(move))
      elseif listed[move] then
        fail(ply, "moves listed " .. move .. " twice")
      elseif not Codec.IsSafeField(move) or move:sub(1, 1) == "!" then
        fail(ply, "moves listed " .. move .. ", which can't go in the log")
      elseif shared and #move > longest - (game.together and 1 or 0) then
        fail(ply, "moves listed " .. move .. ", longer than a message has room for")
      end
      listed[move] = true
    end
    -- Every one of them where there are few, a good few of them where there are many
    local tried = #list <= SAMPLE and list or {}
    if #tried == 0 then
      for _ = 1, SAMPLE do
        tried[#tried + 1] = list[dice:Roll(#list)]
      end
    end
    for _, move in ipairs(tried) do
      local ok, err = game.validate(state, seat, move)
      if not ok then
        fail(ply, "moves listed " .. move .. " for seat " .. seat .. ", which validate refuses: " .. tostring(err))
      end
    end
    if serialize(state) ~= before then
      fail(ply, "asking about moves changed the state")
    end
    if game.computer and not game.together and dice:Roll(ply) == 1 then
      look = {
        state = private.Computer.Copy(state),
        seat = seat,
        level = level,
        seed = seed * 1000 + ply,
        where = string.format("%d players, seed %d, ply %d", seats, seed, ply),
      }
    end

    local entry
    local out = 0
    for candidate = 1, seats do
      out = out + (Match.IsOut(match, candidate) and 1 or 0)
    end
    if seats > 2 and seats - out > 1 and dice:Roll(RESIGN_ODDS) == 1 then
      -- Somebody walks away from it, not necessarily whoever's turn it is
      local leaving
      repeat
        leaving = dice:Roll(seats)
      until not Match.IsOut(match, leaving)
      entry = Match.ResignEntry(leaving)
    else
      local move = list[dice:Roll(#list)]
      entry = game.together and seat .. move or move
      if shared then
        local message = Codec.Decode(Codec.Encode("MOV", id, #match.log + 1, #match.log + 1, entry))
        if not message or message.entry ~= entry then
          fail(ply, "move " .. move .. " doesn't come out of a message the way it went in")
        end
      end
    end
    local ok, err = Match.Append(match, entry)
    if not ok then
      fail(ply, entry .. " was refused: " .. tostring(err))
    end
    local event = Match.Events(match)[#match.log]
    if game.history and event.kind == "move" and type(event.notation) ~= "string" then
      fail(ply, "the game keeps a move list, and " .. entry .. " has no notation")
    end
    if marks[ply] then
      snapshots[#match.log] = serialize(Match.State(match))
    end
    local fine, wrong = pcall(checkProgress, private, game, match, keys)
    if not fine then
      fail(ply, wrong)
    end
  end

  local ok, err = pcall(checkResult, private, game, match, keys)
  if not ok then
    fail(#match.log, err)
  end
  looks[#looks + 1] = look

  -- From scratch, here and on another client, it all comes out the same
  local final = serialize(Match.State(match))
  local outcome = serialize(Match.Result(match))
  if serialize(Match.State(again(match))) ~= final then
    fail(#match.log, "the log replays to another position")
  end
  local other = loadEngine()
  local elsewhere = again(match)
  if serialize(other.Match.State(elsewhere)) ~= final or serialize(other.Match.Result(elsewhere)) ~= outcome then
    fail(#match.log, "the log replays to another position on another client")
  end
  if #elsewhere.log ~= #match.log then
    fail(#match.log, "another client took only " .. #elsewhere.log .. " entries of the log")
  end
  for length, snapshot in pairs(snapshots) do
    if length < #match.log and serialize(Match.StateAt(match, length)) ~= snapshot then
      fail(length, "looking back gives another position than the one played")
    end
    -- Where a move can be taken back the log is cut short, and has to be where it was then
    local cut = again(match)
    Match.Truncate(cut, length)
    if serialize(Match.State(cut)) ~= snapshot then
      fail(length, "cut back to here, the log replays to another position than the one played")
    end
  end
end

--- Puts a game through everything above
--- @param private table The engine the game is registered with
--- @param game GameDefinition
--- @param keys table<string, boolean>
--- @param loadEngine fun(): table Another client, with the game registered too
local function checkGame(private, game, keys, loadEngine)
  checkNames(private, game, keys)
  local looks = {}
  sandboxed(not private.Games.IsSolo(game), function()
    checkDeals(private, game, keys)
    if game.moves then
      for _, seats in ipairs(private.Games.SeatCounts(game)) do
        for seed = 1, SEEDS do
          playOut(private, game, seats, seed, keys, loadEngine, looks)
        end
      end
    end
  end)
  if game.computer then
    -- The computer thinks on one client only, but it has to be as good as its word: the same
    -- move from the same position, which takes the client's own dice and clock away from it too
    sandboxed(false, function()
      for _, look in ipairs(looks) do
        local ok, err = pcall(checkComputer, private, game, look.state, look.seat, look.level, look.seed)
        if not ok then
          error(look.where .. ", the computer at " .. look.level .. ": " .. tostring(err), 0)
        end
      end
      -- The fewest it can be played by against the computer, and the most
      local counts = private.Games.SeatCounts(game)
      local fewest, most = counts[1] > 1 and counts[1] or counts[2], counts[#counts]
      playItself(private, game, fewest, keys)
      if most ~= fewest then
        playItself(private, game, most, keys)
      end
    end)
  end
end

-----------------------------
-- The checks, checked
-----------------------------
-- A game that is wrong in one way each, to see that it is caught. Without its fault it is a race
-- to five: each player in turn adds one or two, and whoever gets there wins.

--- @param fault table<string, any> What to put in place of the game's own
--- @return GameDefinition
local function faulty(fault)
  local game = {
    id = "faulty",
    name = "game_tictactoe",
    version = 1,
    seats = 2,
    newState = function()
      return { total = 0, turn = 1 }
    end,
    turn = function(state)
      return state.turn
    end,
    moves = function()
      return { "1", "2" }
    end,
    validate = function(state, seat, move)
      return seat == state.turn and (move == "1" or move == "2"), "invalid_move"
    end,
    apply = function(state, seat, move)
      state.total = state.total + tonumber(move)
      state.turn = 3 - seat
    end,
    result = function(state)
      return state.total >= 5 and { winner = 3 - state.turn } or nil
    end,
    createView = function() end,
  }
  for key, value in pairs(fault) do
    game[key] = value
  end
  return game
end

-- What is wrong with it, and what has to be said about that
local FAULTS = {
  Nothing = { {}, nil },
  IllegalMove = {
    {
      moves = function()
        return { "1", "2", "3" }
      end,
    },
    "which validate refuses",
  },
  MoveListedTwice = {
    {
      moves = function()
        return { "1", "1" }
      end,
    },
    "twice",
  },
  NoMoves = {
    {
      moves = function(state)
        return state.total < 3 and { "1" } or {}
      end,
    },
    "has no move",
  },
  RandomOfItsOwn = {
    {
      apply = function(state, seat)
        state.total = state.total + math.random(2)
        state.turn = 3 - seat
      end,
    },
    "math.random",
  },
  Clock = {
    {
      newState = function()
        return { total = 0, turn = 1, began = os.time() }
      end,
    },
    "os.time",
  },
  Trigonometry = {
    {
      apply = function(state, seat, move)
        state.total = state.total + math.floor(math.cos(0) * tonumber(move))
        state.turn = 3 - seat
      end,
    },
    "math.cos",
  },
  ValidateChangesState = {
    {
      validate = function(state, seat, move)
        state.asked = (state.asked or 0) + 1
        return seat == state.turn and (move == "1" or move == "2")
      end,
    },
    "changed the state",
  },
  MemoryOfItsOwn = {
    {
      apply = (function()
        local applied = 0
        return function(state, seat, move)
          applied = applied + 1
          state.total = state.total + tonumber(move)
          state.turn = 3 - seat
          state.applied = applied
        end
      end)(),
    },
    "another position",
  },
  ShowsTheStateItself = {
    {
      visible = function(state)
        return state
      end,
    },
    "the state itself",
  },
  NotInTheLocale = { { name = "game_faulty" }, "the locale doesn't have" },
  ComputerThatPlays = { { computer = {} }, nil },
  ComputerPlaysWhatIsntAMove = {
    {
      computer = {
        think = function()
          return "3"
        end,
      },
    },
    "which the game refuses",
  },
  ComputerWithDiceOfItsOwn = {
    {
      computer = {
        think = function()
          return math.random(2) == 1 and "1" or "2"
        end,
      },
    },
    "math.random",
  },
  ComputerChangesWhatItIsShown = {
    {
      computer = {
        think = function(state)
          state.total = state.total + 1
          return "1"
        end,
      },
    },
    "changed what it was shown",
  },
  ComputerCopyThatIsNone = {
    {
      computer = {
        copy = function(state)
          return state
        end,
      },
    },
    "changed the position it was copied from",
  },
  ComputerThinksTooMuchOfAPosition = {
    {
      computer = {
        evaluate = function()
          return 1e12
        end,
      },
    },
    "evaluate said",
  },
  ComputerGuessesWhatIsntThere = {
    {
      visible = function(state)
        return { total = state.total, turn = state.turn }
      end,
      computer = {
        guess = function(seen)
          return { total = seen.total + 1, turn = seen.turn }
        end,
      },
    },
    "doesn't look like what the seat sees",
  },
  EndsUnsaid = {
    {
      result = function(state)
        return state.total >= 5 and { winner = 3 - state.turn, detail = "faulty" } or nil
      end,
    },
    "result_faulty",
  },
}

--- @param tests table<string, fun()>
--- @param loadEngine fun(): table A fresh copy of the engine and every game
return function(tests, loadEngine)
  local keys = localeKeys()
  for _, listed in ipairs(loadEngine().Games.List()) do
    local gameId = listed.id
    tests["EveryGame_" .. gameId] = function()
      local private = loadEngine()
      checkGame(private, private.Games.Get(gameId), keys, loadEngine)
    end
  end

  for name, case in pairs(FAULTS) do
    local fault, said = case[1], case[2]
    tests["EveryGameCatches" .. name] = function()
      -- The same game on every client, a game with a memory of its own included
      local function load()
        local private = loadEngine()
        private.Games.Register(faulty(fault))
        return private
      end
      local private = load()
      local ok, err = pcall(checkGame, private, private.Games.Get("faulty"), keys, load)
      if said == nil then
        assert(ok, "a game with nothing wrong with it didn't pass: " .. tostring(err))
      else
        assert(not ok, "nothing was said about it")
        assert(tostring(err):find(said, 1, true), "what was said doesn't mention " .. said .. ": " .. tostring(err))
      end
    end
  end
end
