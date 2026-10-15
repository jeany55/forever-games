-- Runs the engine tests from the terminal: lua Tests/RunTests.lua
--
-- The engine (Engine/ and the rules half of Games/) has no WoW dependencies, so instead of
-- mocking the game client each test builds a couple of simulated players and wires their
-- sessions together through a fake network that can drop messages or take a player offline.

local ADDON_NAME = "ForeverGames"
local ENGINE_FILES = {
  "Engine/Codec.lua",
  "Engine/Random.lua",
  "Engine/Tables.lua",
  "Engine/Grid.lua",
  "Engine/Deck.lua",
  "Engine/Games.lua",
  "Engine/Daily.lua",
  "Engine/Race.lua",
  "Engine/Computer.lua",
  "Engine/Match.lua",
  "Engine/Session.lua",
  "Engine/Presence.lua",
  "Engine/Rooms.lua",
  "Engine/Phases.lua",
  "Engine/Bracket.lua",
  "Lexicon/Sketch.lua",
  "Games/Sketch.lua",
  "Lexicon/Trivia.lua",
  "Games/Trivia.lua",
  "Games/TicTacToe.lua",
  "Games/Chess.lua",
  "Games/ConnectFour.lua",
  "Games/Reversi.lua",
  "Games/Checkers.lua",
  "Games/ChineseCheckers.lua",
  "Games/Backgammon.lua",
  "Games/Yacht.lua",
  "Games/CrazyEights.lua",
  "Games/Battleship.lua",
  "Engine/Lexicon.lua",
  "Lexicon/English.lua",
  "Lexicon/Warcraft.lua",
  "Games/Words.lua",
  "Games/Solitaire.lua",
  "Games/Minesweeper.lua",
  "Games/2048.lua",
  "Games/Sudoku.lua",
  "Lexicon/Fourtiles.lua",
  "Games/Fourtiles.lua",
  "Games/Warcraftstein.lua",
  "Engine/SectorMap.lua",
  "Engine/Actors.lua",
  "Engine/Course.lua",
  "Games/Freedoom/Carry.lua",
  "Games/Freedoom/World.lua",
  "Games/Freedoom.lua",
  "Games/Wormcraft.lua",
  "Engine/Places.lua",
  "Tests/WherePlaces.lua",
  "Games/Where.lua",
}

-- What the window needs on top of the engine, in load order. Only the tests that click through
-- the window load these, on top of the fake client in Tests/FakeClient.lua.
local GUI_FILES = { "GUI/Widgets.lua", "GUI/LetteringGlyphs.lua", "GUI/Lettering.lua", "GUI/Effects.lua", "GUI/Dice.lua", "GUI/SlideGrid.lua", "GUI/NumberGrid.lua", "GUI/Board.lua", "GUI/Cards.lua", "GUI/CardTable.lua", "GUI/Viewport.lua", "GUI/Drag.lua", "GUI/Tiles.lua", "GUI/MainFrame.lua" }
local Client = dofile("Tests/FakeClient.lua")

--- Loads a fresh copy of the engine, the way the client would for one player
--- @return table private
local function loadEngine()
  local private = { L = setmetatable({}, {
    __index = function(_, key)
      return key
    end,
  }) }
  for _, file in ipairs(ENGINE_FILES) do
    assert(loadfile(file))(ADDON_NAME, private)
  end
  return private
end

-----------------------------
-- Simulated world
-----------------------------

--- @class World
--- @field clock number
--- @field players table<string, table>
--- @field sent string[] Every message that was delivered, as "from>to text"
--- @field prepare (fun(private: table))? Called with the engine of every player who joins, to register a game only a test has
local World = {}
World.__index = World

function World.New()
  return setmetatable({ clock = 1000000, players = {}, sent = {}, queue = {}, seed = 0, today = "2026-10-14" }, World)
end

--- @param name string
--- @param matches table? Saved matches to start from
function World:AddPlayer(name, matches)
  local player = { name = name, online = true, blocked = false, events = {}, refused = {}, private = loadEngine() }
  player.matches = matches or {}
  if self.prepare then
    self.prepare(player.private)
  end
  player.session = player.private.Session.New({
    me = name,
    matches = player.matches,
    now = function()
      return self.clock
    end,
    today = function()
      return self.today
    end,
    random = function(max)
      self.seed = self.seed + 1
      return (self.seed % max) + 1
    end,
    notify = function(event, match)
      player.events[#player.events + 1] = event .. ":" .. match.id
      if player.onEvent then
        player.onEvent(event, match)
      end
    end,
    onRefused = function(host, gameId, reason)
      player.refused[#player.refused + 1] = host .. ":" .. gameId .. ":" .. reason
    end,
    takes = function(sender)
      return not player.knows or player.knows[sender] == true
    end,
    send = function(target, text)
      if player.blocked then
        return false
      end
      self.queue[#self.queue + 1] = { from = name, to = target, text = text }
      return true
    end,
  })
  self.players[name] = player
  return player
end

--- Delivers queued messages until the network is quiet. Messages to offline players are lost.
--- @param drop (fun(message: table): boolean)? Return true to lose a message
function World:Deliver(drop)
  local guard = 0
  while #self.queue > 0 do
    guard = guard + 1
    assert(guard < 1000, "Message storm, the protocol is not converging")
    local message = table.remove(self.queue, 1)
    local target = self.players[message.to]
    if target and target.online and not (drop and drop(message)) then
      self.sent[#self.sent + 1] = message.from .. ">" .. message.to .. " " .. message.text
      target.session:Receive(message.from, message.text)
    end
  end
end

--- Advances time and lets everyone retry, like the in game ticker does
--- @param seconds number
function World:Tick(seconds)
  self.clock = self.clock + seconds
  for _, player in pairs(self.players) do
    if player.online then
      player.session:Flush()
    end
  end
  self:Deliver()
end

--- Simulates a relog, optionally restoring older saved data
--- @param player table
--- @param matches table?
function World:Relog(player, matches)
  local fresh = self:AddPlayer(player.name, matches or player.matches)
  fresh.session:Hello()
  self:Deliver()
  return fresh
end

-----------------------------
-- Assertions
-----------------------------

local function equal(expected, actual, label)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", label or "value", tostring(expected), tostring(actual)), 2)
  end
end

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, inner in pairs(value) do
    result[key] = copy(inner)
  end
  return result
end

--- Starts an accepted match between two fresh players
--- @return World, table alice, table bob, string id, table first, table second
local function startedMatch()
  local world = World.New()
  local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  local match = assert(alice.session:Invite("Bob-Realm", "tictactoe"))
  world:Deliver()
  assert(bob.session:Accept(match.id))
  world:Deliver()
  local first = match.me == 1 and alice or bob
  local second = first == alice and bob or alice
  return world, alice, bob, match.id, first, second
end

--- Plays alternating moves starting with `first`
local function play(world, id, first, second, moves)
  for index, move in ipairs(moves) do
    local player = index % 2 == 1 and first or second
    local ok, err = player.session:Move(id, move)
    assert(ok, "Move " .. move .. " rejected: " .. tostring(err))
    world:Deliver()
  end
end

local function logOf(player, id)
  return table.concat(player.matches[id].log, ",")
end

-----------------------------
-- Tests
-----------------------------

local tests = {}

function tests.CodecRoundTrip()
  local Codec = loadEngine().Codec
  local message = Codec.Decode(Codec.Encode("MOV", "abc123", 3, 4, "5"))
  equal("MOV", message.type)
  equal("abc123", message.id)
  equal(3, message.n)
  equal(4, message.total)
  equal("5", message.entry)
end

function tests.CodecRejectsGarbage()
  local Codec = loadEngine().Codec
  for _, text in ipairs({ "", "hello", "2:MOV:a:1:1:5", "1:MOV:a:0:1:5", "1:MOV:a:x:1:5", "1:NOPE:a", "1:INV:a:tictactoe", "1:ACK:a:-1" }) do
    equal(nil, Codec.Decode(text), "Decode(" .. text .. ")")
  end
  equal(nil, Codec.Decode(string.rep("1", 300)))
end

function tests.InviteAcceptAndWin()
  local world, alice, bob, id, first, second = startedMatch()
  equal("active", alice.matches[id].status)
  equal("active", bob.matches[id].status)
  equal(true, first.private.Match.IsMyTurn(first.matches[id]))
  equal(false, second.private.Match.IsMyTurn(second.matches[id]))

  play(world, id, first, second, { "1", "4", "2", "5", "3" })

  for _, player in ipairs({ alice, bob }) do
    local match = player.matches[id]
    equal("finished", match.status)
    equal("1,4,2,5,3", logOf(player, id))
    local result = player.private.Match.Result(match)
    equal(1, result.winner)
    equal("win", result.reason)
    equal(false, player.session:IsPending(match), "nothing left to deliver")
  end
end

function tests.Draw()
  local world, _, bob, id, first, second = startedMatch()
  play(world, id, first, second, { "1", "2", "3", "5", "4", "6", "8", "7", "9" })
  local result = bob.private.Match.Result(bob.matches[id])
  equal(0, result.winner)
  equal("draw", result.reason)
end

function tests.IllegalMovesAreRejected()
  local world, _, _, id, first, second = startedMatch()
  local ok, err = second.session:Move(id, "1")
  equal(false, ok)
  equal("not_your_turn", err)

  play(world, id, first, second, { "5" })
  ok, err = second.session:Move(id, "5")
  equal(false, ok)
  equal("cell_taken", err)

  for _, move in ipairs({ "0", "10", "x", "1.5", "01", "!r1" }) do
    ok = second.session:Move(id, move)
    equal(false, ok, "move " .. move)
  end
  equal("5", logOf(second, id))
end

function tests.RemoteCheatingIsIgnored()
  local world, _, _, id, first, second = startedMatch()
  play(world, id, first, second, { "5" })
  -- The first player tries to move twice in a row, onto a taken cell and then off the board
  second.session:Receive(first.name, "1:MOV:" .. id .. ":2:2:5")
  second.session:Receive(first.name, "1:MOV:" .. id .. ":2:2:12")
  -- Somebody else tries to move in this match
  second.session:Receive("Mallory-Realm", "1:MOV:" .. id .. ":2:2:1")
  world:Deliver()
  equal("5", logOf(second, id))
end

function tests.MoveMadeWhileOpponentOfflineArrivesLater()
  local world, _, _, id, first, second = startedMatch()
  second.online = false
  assert(first.session:Move(id, "5"))
  world:Deliver()
  equal("", logOf(second, id))
  equal(true, first.session:IsPending(first.matches[id]))

  world:Tick(30)
  equal("", logOf(second, id))

  second.online = true
  world:Tick(600)
  equal("5", logOf(second, id))
  equal(false, first.session:IsPending(first.matches[id]))
end

function tests.MoveMadeDuringLockdownIsSentAfterwards()
  local world, _, _, id, first, second = startedMatch()
  first.blocked = true
  assert(first.session:Move(id, "5"))
  world:Deliver()
  equal("", logOf(second, id))

  first.blocked = false
  first.session:Wake()
  world:Deliver()
  equal("5", logOf(second, id))
end

function tests.LoginDeliversMovesMadeWhileAway()
  local world, _, _, id, first, second = startedMatch()
  second.online = false
  assert(first.session:Move(id, "5"))
  world:Deliver()

  second.online = true
  second = world:Relog(second)
  equal("5", logOf(second, id))
  equal(true, second.private.Match.IsMyTurn(second.matches[id]))
end

function tests.LostAcceptIsRecovered()
  local world = World.New()
  local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  local match = assert(alice.session:Invite("Bob-Realm", "tictactoe"))
  world:Deliver()
  bob.session:Accept(match.id)
  world:Deliver(function(message)
    return message.text:find(":ACC:") ~= nil
  end)
  equal("outgoing", alice.matches[match.id].status)

  world:Tick(30)
  equal("active", alice.matches[match.id].status)
end

function tests.InviteToOfflinePlayerArrivesLater()
  local world = World.New()
  local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  bob.online = false
  local match = assert(alice.session:Invite("Bob-Realm", "tictactoe"))
  world:Deliver()
  equal(nil, bob.matches[match.id])

  bob.online = true
  world:Tick(30)
  equal("incoming", bob.matches[match.id].status)
  equal(1, bob.session:AttentionCount())
end

function tests.DeclineSticksEvenIfTheInviteIsRepeated()
  local world = World.New()
  local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  local match = assert(alice.session:Invite("Bob-Realm", "tictactoe"))
  world:Deliver()
  bob.session:Decline(match.id)
  world:Deliver(function(message)
    return message.text:find(":DEC:") ~= nil
  end)
  equal("outgoing", alice.matches[match.id].status)
  equal(0, #bob.session:List())

  world:Tick(30)
  equal("declined", alice.matches[match.id].status)
  equal(0, #bob.session:List())
  equal(0, bob.session:AttentionCount())
end

function tests.WithdrawnInviteDisappears()
  local world = World.New()
  local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  local match = assert(alice.session:Invite("Bob-Realm", "tictactoe"))
  world:Deliver()
  assert(alice.session:Forget(match.id))
  world:Deliver()
  equal(nil, bob.matches[match.id])
  equal(0, #alice.session:List())
end

function tests.UnknownGameIsDeclined()
  local world = World.New()
  local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  bob.session:Receive("Alice-Realm", "1:INV:abc:mahjong:1:1")
  bob.session:Receive("Alice-Realm", "1:INV:abd:tictactoe:99:1")
  equal(nil, bob.matches.abc)
  equal(nil, bob.matches.abd)
  equal("1:DEC:abc:nogame", world.queue[1].text)
  equal("1:DEC:abd:version", world.queue[2].text)
  equal(nil, (alice.session:Invite("Bob-Realm", "mahjong")))
  equal(nil, (alice.session:Invite("Alice-Realm", "tictactoe")))
end

function tests.Resign()
  local world, _, _, id, first, second = startedMatch()
  play(world, id, first, second, { "5" })
  -- Resigning doesn't require it to be your turn
  assert(first.session:Resign(id))
  world:Deliver()
  for _, player in ipairs({ first, second }) do
    local result = player.private.Match.Result(player.matches[id])
    equal("finished", player.matches[id].status)
    equal(2, result.winner)
    equal("resign", result.reason)
  end
  equal(false, second.session:Move(id, "1"))
end

function tests.DuplicateMovesAreHarmless()
  local world, _, _, id, first, second = startedMatch()
  play(world, id, first, second, { "5", "1" })
  second.session:Receive(first.name, "1:MOV:" .. id .. ":1:2:5")
  second.session:Receive(first.name, "1:MOV:" .. id .. ":1:2:5")
  world:Deliver()
  equal("5,1", logOf(second, id))
  equal("5,1", logOf(first, id))
end

function tests.CrashRecoveryRestoresLostMoves()
  local world, _, _, id, first, second = startedMatch()
  play(world, id, first, second, { "5" })
  local snapshot = copy(second.matches)
  play(world, id, second, first, { "1", "9" })

  -- The second player crashes and comes back with data from before their own move
  second = world:Relog(second, snapshot)
  equal("5,1,9", logOf(second, id))
  equal("5,1,9", logOf(first, id))
end

function tests.DivergedLogsConverge()
  local world, _, _, id, first, second = startedMatch()
  play(world, id, first, second, { "5" })
  local snapshot = copy(second.matches)
  play(world, id, second, first, { "1", "9" })

  -- The second player crashes while the first is offline, then plays a different move
  first.online = false
  second = world:Relog(second, snapshot)
  assert(second.session:Move(id, "3"))
  world:Deliver()
  equal("5,3", logOf(second, id))

  -- The longer log wins once they see each other again
  first.online = true
  world:Tick(30)
  world:Tick(600)
  equal("5,1,9", logOf(first, id))
  equal("5,1,9", logOf(second, id))
  equal(false, first.session:IsPending(first.matches[id]))
  equal(false, second.session:IsPending(second.matches[id]))
end

function tests.SimultaneousResignAndMoveConverge()
  local world, _, _, id, first, second = startedMatch()
  play(world, id, first, second, { "5" })
  -- Both act before either message arrives
  assert(second.session:Move(id, "1"))
  assert(first.session:Resign(id))
  world:Deliver()
  world:Tick(30)
  equal(logOf(first, id), logOf(second, id))
  -- Seat 1 wins the tie, so the resignation stands
  equal("5,!r1", logOf(first, id))
  equal("finished", second.matches[id].status)
end

function tests.ForgottenMatchStopsRetries()
  local world, _, _, id, first, second = startedMatch()
  play(world, id, first, second, { "1", "4", "2", "5" })
  second.online = false
  assert(first.session:Move(id, "3"))
  world:Deliver()

  -- The loser's data is gone entirely when they return
  second.online = true
  second = world:Relog(second, {})
  world:Tick(30)
  equal(false, first.session:IsPending(first.matches[id]))
end

function tests.ResyncDoesNotFloodTheNetwork()
  local world, _, _, id, first, second = startedMatch()
  local snapshot = copy(second.matches)
  play(world, id, first, second, { "1", "2", "3", "5", "4", "6", "8", "7", "9" })

  -- The second player loses the whole game and has to be sent all of it again
  local before = #world.sent
  second = world:Relog(second, snapshot)
  for _ = 1, 5 do
    world:Tick(600)
  end
  equal("1,2,3,5,4,6,8,7,9", logOf(second, id))
  local used = #world.sent - before
  assert(used <= 30, "Resending 9 moves took " .. used .. " messages")
end

-----------------------------
-- Presence
-----------------------------

--- A handful of players who can hear each other, some sharing a guild
--- @param guildOf table<string, string?>
--- @param friendsOf table<string, string[]>
local function presenceWorld(guildOf, friendsOf)
  local world = { clock = 5000, queue = {}, players = {}, changes = {} }
  local Presence = loadEngine().Presence

  for name in pairs(guildOf) do
    world.changes[name] = 0
    world.players[name] = Presence.New({
      me = name,
      now = function()
        return world.clock
      end,
      broadcast = function(text)
        for other, guild in pairs(guildOf) do
          if guild and guild == guildOf[name] then
            world.queue[#world.queue + 1] = { from = name, to = other, text = text, viaGuild = true }
          end
        end
      end,
      whisper = function(target, text)
        world.queue[#world.queue + 1] = { from = name, to = target, text = text, viaGuild = false }
      end,
      friends = function()
        return friendsOf[name] or {}
      end,
      onChange = function()
        world.changes[name] = world.changes[name] + 1
      end,
    })
  end

  function world:Deliver()
    local guard = 0
    while #self.queue > 0 do
      guard = guard + 1
      assert(guard < 1000, "Presence messages are not settling")
      local message = table.remove(self.queue, 1)
      if self.players[message.to] then
        self.players[message.to]:Handle(message.from, message.text, message.viaGuild)
      end
    end
  end
  return world
end

local function names(presence)
  local list = {}
  for _, player in ipairs(presence:List()) do
    list[#list + 1] = player.name .. "=" .. player.source
  end
  return table.concat(list, " ")
end

function tests.PresenceFindsGuildiesAndFriends()
  local world = presenceWorld(
    { Alice = "Knights", Bob = "Knights", Carol = false, Dave = "Other" },
    { Alice = { "Carol", "Bob" } }
  )
  world.players.Alice:Announce()
  world:Deliver()

  equal("Bob=guild Carol=friend", names(world.players.Alice))
  equal("Alice=guild", names(world.players.Bob))
  equal("Alice=friend", names(world.players.Carol))
  equal("", names(world.players.Dave))

  local counts = world.players.Alice:Counts()
  equal(2, counts.total)
  equal(1, counts.guild)
  equal(1, counts.friend)
  equal(2, world.changes.Alice, "one change per player found")
end

function tests.PresenceDoesNothingUntilAsked()
  local world = presenceWorld({ Alice = "Knights", Bob = "Knights" }, {})
  for _ = 1, 10 do
    world.clock = world.clock + 600
    world.players.Alice:Tick()
  end
  equal(0, #world.queue, "nothing is sent on a timer")
  equal(true, world.players.Alice:CanAnnounce())

  world.players.Alice:Announce()
  equal(false, world.players.Alice:CanAnnounce(), "refreshing has a cooldown")
  world.clock = world.clock + 10
  equal(true, world.players.Alice:CanAnnounce())
end

function tests.PresenceRefreshDropsPlayersWhoDoNotAnswer()
  local world = presenceWorld({ Alice = "Knights", Bob = "Knights", Carol = false }, { Alice = { "Carol" } })
  world.players.Alice:Announce()
  world:Deliver()
  equal("Bob=guild Carol=friend", names(world.players.Alice))

  -- Nobody is dropped just because time passes
  world.clock = world.clock + 3600
  world.players.Alice:Tick()
  equal("Bob=guild Carol=friend", names(world.players.Alice))

  -- Bob logs off without a word, then Alice refreshes
  world.players.Bob = nil
  world.players.Alice:Announce()
  world:Deliver()
  world.clock = world.clock + 30
  world.players.Alice:Tick()
  equal("Bob=guild Carol=friend", names(world.players.Alice), "still inside the time to answer")
  world.clock = world.clock + 31
  world.players.Alice:Tick()
  equal("Carol=friend", names(world.players.Alice))
end

function tests.PresenceRefreshAsksOpponentsToo()
  -- Erin is neither a guildie nor a friend, Alice only knows her from a game
  local world = presenceWorld({ Alice = false, Erin = false }, {})
  world.players.Alice:Touch("Erin")
  world.clock = world.clock + 100
  world.players.Alice:Announce()
  world:Deliver()
  world.clock = world.clock + 61
  world.players.Alice:Tick()
  equal("Erin=other", names(world.players.Alice))
end

function tests.PresenceLeavesGameMessagesAlone()
  local world = presenceWorld({ Alice = "Knights", Bob = "Knights" }, {})
  equal(false, world.players.Alice:Handle("Bob", "1:MOV:abc:1:1:5", false))
  equal(true, world.players.Alice:Handle("Bob", "1:HI", true))
  world.players.Alice:Remove("Bob")
  equal("", names(world.players.Alice))
  world.players.Alice:Touch("Erin")
  equal("Erin=other", names(world.players.Alice))
end

-----------------------------
-- Chess
-----------------------------

--- Plays a line from the starting position, asserting every move is legal
--- @param line string Space separated moves
--- @return table state, table chess
local function chessAfter(line)
  local chess = loadEngine().Games.Get("chess")
  local state = chess.newState()
  for move in line:gmatch("%S+") do
    local seat = chess.turn(state)
    local ok, err = chess.validate(state, seat, move)
    assert(ok, "Move " .. move .. " rejected: " .. tostring(err))
    chess.apply(state, seat, move)
  end
  return state, chess
end

local function square(name)
  return (name:byte(1) - 97) + (tonumber(name:sub(2)) - 1) * 8
end

function tests.ChessCountsTheRightNumberOfPositions()
  local chess = loadEngine().Games.Get("chess")
  local function perft(state, depth)
    local count = 0
    for move in pairs(state.legal) do
      if depth == 1 then
        count = count + 1
      else
        local nextState = copy(state)
        chess.apply(nextState, nextState.turn, move)
        count = count + perft(nextState, depth - 1)
      end
    end
    return count
  end
  -- Known values for the starting position
  equal(20, perft(chess.newState(), 1))
  equal(400, perft(chess.newState(), 2))
  equal(8902, perft(chess.newState(), 3))
end

function tests.ChessCheckmate()
  local state, chess = chessAfter("f2f3 e7e5 g2g4 d8h4")
  local result = chess.result(state)
  equal(2, result.winner)
  equal("checkmate", result.detail)
  equal(false, (chess.validate(state, 1, "a2a3")))
end

function tests.ChessCastling()
  local state, chess = chessAfter("e2e4 e7e5 g1f3 b8c6 f1c4 f8c5 e1g1")
  equal("K", state.board[square("g1")])
  equal("R", state.board[square("f1")])
  equal(nil, state.board[square("h1")])
  equal(nil, state.board[square("e1")])

  -- Not once the king has moved, even if it went back
  state = chessAfter("e2e4 e7e5 g1f3 b8c6 f1c4 f8c5 e1e2 d7d6 e2e1 d6d5")
  equal(false, (chess.validate(state, 1, "e1g1")))

  -- Not through an attacked square: the bishop on e2 covers f1
  state = chessAfter("g1f3 b7b6 g2g3 c8a6 f1g2 a6e2")
  equal(nil, state.legal["e1g1"])
  state = chessAfter("g1f3 b7b6 g2g3 c8a6 f1g2 a6b7")
  assert(state.legal["e1g1"], "castling should be possible here")
end

function tests.ChessEnPassant()
  local state, chess = chessAfter("e2e4 a7a6 e4e5 d7d5 e5d6")
  equal("P", state.board[square("d6")])
  equal(nil, state.board[square("d5")])
  equal(nil, state.board[square("e5")])

  -- Only on the very next move
  state = chessAfter("e2e4 a7a6 e4e5 d7d5 a2a3 a6a5")
  equal(false, (chess.validate(state, 1, "e5d6")))
end

function tests.ChessPromotion()
  local line = "a2a4 b7b5 a4b5 a7a6 b5a6 c8b7 a6b7 b8c6"
  local state, chess = chessAfter(line)
  equal(false, (chess.validate(state, 1, "b7a8")), "a promotion must name the piece")
  equal(false, (chess.validate(state, 1, "b7a8k")))
  state = chessAfter(line .. " b7a8n")
  equal("N", state.board[square("a8")])
  state = chessAfter(line .. " b7a8q")
  equal("Q", state.board[square("a8")])
end

function tests.ChessPinnedPieceCannotMove()
  local state, chess = chessAfter("e2e4 e7e5 d1h5")
  equal(false, (chess.validate(state, 2, "f7f6")))
  equal(true, (chess.validate(state, 2, "g7g6")))
  equal(false, (chess.validate(state, 1, "h5f7")), "not white's turn")
end

function tests.ChessStalemate()
  local state, chess = chessAfter(
    "e2e3 a7a5 d1h5 a8a6 h5a5 h7h5 h2h4 a6h6 a5c7 f7f6 c7d7 e8f7 d7b7 d8d3 b7b8 d3h7 b8c8 f7g6 c8e6"
  )
  local result = chess.result(state)
  equal(0, result.winner)
  equal("stalemate", result.detail)
end

function tests.ChessThreefoldRepetition()
  local state, chess = chessAfter("g1f3 g8f6 f3g1 f6g8 g1f3 g8f6 f3g1")
  equal(nil, chess.result(state))
  state = chessAfter("g1f3 g8f6 f3g1 f6g8 g1f3 g8f6 f3g1 f6g8")
  equal("repetition", chess.result(state).detail)
end

function tests.ChessMatchBetweenTwoPlayers()
  local world = World.New()
  local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  local match = assert(alice.session:Invite("Bob-Realm", "chess"))
  world:Deliver()
  assert(bob.session:Accept(match.id))
  world:Deliver()
  local white = match.me == 1 and alice or bob
  local black = white == alice and bob or alice
  play(world, match.id, white, black, { "f2f3", "e7e5", "g2g4", "d8h4" })

  for _, player in ipairs({ alice, bob }) do
    local result = player.private.Match.Result(player.matches[match.id])
    equal("finished", player.matches[match.id].status)
    equal(2, result.winner)
    equal("checkmate", result.detail)
  end
end

-----------------------------
-- More games
-----------------------------

--- Plays a line of any game from its starting position, asserting every move is legal
--- @param id string Game id
--- @param line string Space separated moves
--- @return table state, table game, table[] events What each move did
local function gameAfter(id, line)
  local private = loadEngine()
  local game, random = private.Games.Get(id), private.Random.New(1)
  local state, events = game.newState(2, random), {}
  for move in line:gmatch("%S+") do
    local seat = game.turn(state)
    local ok, err = game.validate(state, seat, move)
    assert(ok, "Move " .. move .. " rejected: " .. tostring(err))
    events[#events + 1] = game.apply(state, seat, move, random)
  end
  return state, game, events
end

--- Counts the positions a number of moves deep, the usual check on a move generator
--- @param game table
--- @param state table
--- @param depth number
--- @param movesOf fun(state: table): string[]
--- @return number
local function countPositions(game, state, depth, movesOf)
  if depth == 0 then
    return 1
  end
  local count = 0
  for _, move in ipairs(movesOf(state)) do
    local after = copy(state)
    game.apply(after, game.turn(after), move)
    count = count + countPositions(game, after, depth - 1, movesOf)
  end
  return count
end

function tests.ConnectFourFourInAColumnWins()
  local state, game, events = gameAfter("connectfour", "4 5 4 5 4 5")
  equal(nil, game.result(state))
  equal(3, events[1].square, "the first disc lands at the bottom of the column")
  equal(10, events[3].square, "the next one on top of it")

  state = gameAfter("connectfour", "4 5 4 5 4 5 4")
  equal(1, game.result(state).winner)
  table.sort(state.line)
  equal("3,10,17,24", table.concat(state.line, ","))
end

function tests.ConnectFourLinesRunEveryWay()
  local state, game = gameAfter("connectfour", "1 1 2 2 3 3 4")
  equal(1, game.result(state).winner, "along a row")
  state = gameAfter("connectfour", "1 2 2 3 4 3 3 4 5 4 4")
  equal(1, game.result(state).winner, "up a diagonal")
  state = gameAfter("connectfour", "7 6 6 5 4 5 5 4 3 4 4")
  equal(1, game.result(state).winner, "down a diagonal")
  -- The last disc may be anywhere in the line, not only at its end
  state = gameAfter("connectfour", "1 1 2 2 4 4 3")
  equal(1, game.result(state).winner)
end

function tests.ConnectFourRejectsBadMoves()
  local state, game = gameAfter("connectfour", "3 3 3 3 3 3")
  local ok, err = game.validate(state, 1, "3")
  equal(false, ok)
  equal("column_full", err)
  equal(false, (game.validate(state, 2, "4")), "not yellow's turn")
  for _, move in ipairs({ "0", "8", "x", "1.5", "01" }) do
    equal(false, (game.validate(state, 1, move)), move)
  end
end

function tests.ConnectFourFullRackIsADraw()
  local state, game = gameAfter(
    "connectfour",
    "6 6 5 4 6 1 7 1 4 4 3 5 4 4 3 1 1 3 4 5 3 2 2 1 2 2 7 5 5 2 3 3 1 2 7 7 5 7 7 6 6 6"
  )
  equal(0, game.result(state).winner)
end

--- @param state table Reversi position
--- @return string[]
local function reversiMoves(state)
  local moves = {}
  for target in pairs(state.legal) do
    moves[#moves + 1] = string.char(97 + target % 8) .. (math.floor(target / 8) + 1)
  end
  table.sort(moves)
  return moves
end

function tests.ReversiCountsTheRightNumberOfPositions()
  local reversi = loadEngine().Games.Get("reversi")
  equal("c4,d3,e6,f5", table.concat(reversiMoves(reversi.newState()), ","))
  -- Known values for the starting position
  equal(244, countPositions(reversi, reversi.newState(), 4, reversiMoves))
  equal(1396, countPositions(reversi, reversi.newState(), 5, reversiMoves))
end

function tests.ReversiTurnsTrappedDiscsOver()
  local state, game, events = gameAfter("reversi", "d3")
  equal(1, state.board[square("d4")], "the disc in between changes sides")
  equal(4, state.counts[1])
  equal(1, state.counts[2])
  equal(square("d4"), events[1].flipped[1])
  equal("d3", events[1].notation)
  equal(2, game.turn(state))

  equal(false, (game.validate(state, 2, "a1")), "a disc has to trap something")
  equal(false, (game.validate(state, 2, "d3")), "not on a square that is taken")
  equal(false, (game.validate(state, 1, "c3")), "not black's turn")
  equal(false, (game.validate(state, 2, "i9")))
end

function tests.ReversiPlayerWithNoMoveSitsOut()
  local state, game, events = gameAfter("reversi", "f5 f6 f7 g7 c4 f8 h8 h6")
  equal(nil, game.result(state))
  equal(2, game.turn(state), "black can't place anywhere, so white goes again")
  equal(1, state.passed)
  equal(true, events[#events].passed)
  equal(false, (game.validate(state, 1, "a1")))

  -- Once white has moved it is black's turn like any other
  local move = reversiMoves(state)[1]
  game.apply(state, 2, move)
  if game.turn(state) == 1 then
    equal(nil, state.passed)
  end
end

function tests.ReversiEndsWhenNobodyCanMove()
  local state, game = gameAfter("reversi", "f5 d6 c5 f4 e7 f6 g5 e6 e3")
  equal(13, state.counts[1])
  equal(0, state.counts[2])
  equal(1, game.result(state).winner)
end

function tests.ReversiPassBetweenTwoPlayers()
  local world = World.New()
  world.seed = 1
  local black, white = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  local match = assert(black.session:Invite("Bob-Realm", "reversi"))
  equal(1, match.me)
  world:Deliver()
  assert(white.session:Accept(match.id))
  world:Deliver()
  play(world, match.id, black, white, { "f5", "f6", "f7", "g7", "c4", "f8", "h8", "h6" })

  for _, player in ipairs({ black, white }) do
    equal(2, player.private.Match.Turn(player.matches[match.id]))
  end
  equal(false, (black.session:Move(match.id, "a1")))
  local again = reversiMoves(white.private.Match.State(white.matches[match.id]))[1]
  assert(white.session:Move(match.id, again))
  world:Deliver()
  equal(logOf(white, match.id), logOf(black, match.id))
  equal(9, #black.matches[match.id].log)
end

--- @param state table Checkers position
--- @return string[]
local function checkersMoves(state)
  local moves = {}
  for move in pairs(state.legal) do
    moves[#moves + 1] = move
  end
  table.sort(moves)
  return moves
end

function tests.CheckersCountsTheRightNumberOfPositions()
  local checkers = loadEngine().Games.Get("checkers")
  equal("10-14,10-15,11-15,11-16,12-16,9-13,9-14", table.concat(checkersMoves(checkers.newState()), ","))
  -- Known values for the starting position
  equal(302, countPositions(checkers, checkers.newState(), 3, checkersMoves))
  equal(1469, countPositions(checkers, checkers.newState(), 4, checkersMoves))
  equal(7361, countPositions(checkers, checkers.newState(), 5, checkersMoves))
end

function tests.CheckersTakingIsCompulsory()
  local state, game, events = gameAfter("checkers", "11-15 22-18")
  equal("15-22", table.concat(checkersMoves(state), ","), "with a jump on, nothing else is allowed")
  equal(false, (game.validate(state, 1, "9-13")))
  equal(false, (game.validate(state, 2, "15-22")), "not white's turn")
  equal("11-15", events[1].notation)

  state, game, events = gameAfter("checkers", "11-15 22-18 15-22")
  equal("15x22", events[3].notation)
  equal(1, #events[3].captured)
  equal(nil, state.board[events[3].captured[1]], "the piece jumped over is gone")
  equal("25-18,26-17", table.concat(checkersMoves(state), ","), "white has to take back, either way")
end

function tests.CheckersJumpsGoOnInOneMove()
  local line = "11-15 21-17 9-14 22-18 15-22"
  local state, game = gameAfter("checkers", line)
  equal(false, (game.validate(state, 2, "25-18")), "a piece that can jump again has to")
  assert(state.legal["25-18-9"], "the double jump should be on")

  local events
  state, game, events = gameAfter("checkers", line .. " 25-18-9")
  equal("25x18x9", events[#events].notation)
  equal(2, #events[#events].captured)
  equal(3, #events[#events].path)
  local pieces = { r = 0, w = 0 }
  for _, piece in pairs(state.board) do
    pieces[piece] = pieces[piece] + 1
  end
  equal(10, pieces.r)
  equal(11, pieces.w)
end

function tests.CheckersCrownsAManOnTheFarRow()
  local state, game, events = gameAfter("checkers", "10-15 22-18 15-22 26-17 9-13 31-26 13-22-31")
  equal(true, events[#events].crowned)
  local king
  for at, piece in pairs(state.board) do
    if piece == "R" then
      king = at
    end
  end
  equal(events[#events].to, king)
  equal(7, math.floor(king / 8), "on the row furthest from where red set out")

  -- A king goes backwards too
  game.apply(state, 2, checkersMoves(state)[1])
  local backwards = false
  for _, move in pairs(state.legal) do
    backwards = backwards or (move.path[1] == king and move.path[2] < king)
  end
  equal(true, backwards)
end

function tests.CheckersPlayerWithoutAMoveLoses()
  local state, game = gameAfter(
    "checkers",
    "11-15 23-19 12-16 19-12 9-14 27-23 6-9 22-17 9-13 31-27 13-22-31 21-17 14-21 24-19 31-24 30-26 21-30 32-27 24-31-22 23-18"
      .. " 15-24 28-19 22-15-24 29-25 30-21"
  )
  equal(1, game.result(state).winner)
end

--- A checkers position with nothing left but a king each, in opposite corners, red to move
--- @return table state, table checkers
local function twoKings()
  local checkers = loadEngine().Games.Get("checkers")
  local state = checkers.newState()
  -- Put together by hand, a game takes a long time to get here
  state.board = { [0] = "R", [63] = "W" }
  state.positions = {}
  state.legal = { ["4-8"] = { path = { 0, 9 }, captures = {} } }
  return state, checkers
end

function tests.CheckersDrawsByRepetition()
  local state, checkers = twoKings()
  equal(true, checkers.draws, "and by agreement, which is the engine's business")

  -- Going back and forth, the position after the first move comes up again every four moves
  local shuffle = { "4-8", "29-25", "8-4", "25-29" }
  for index = 1, 8 do
    local move = shuffle[(index - 1) % 4 + 1]
    assert(checkers.validate(state, checkers.turn(state), move), move)
    checkers.apply(state, checkers.turn(state), move)
  end
  equal(nil, checkers.result(state))
  checkers.apply(state, checkers.turn(state), "4-8")
  equal(0, checkers.result(state).winner)
  equal("repetition", checkers.result(state).detail)
end

function tests.CheckersDrawsAfterFortyQuietMoves()
  local state, checkers = twoKings()
  state.quiet = 78
  checkers.apply(state, 1, "4-8")
  equal(nil, checkers.result(state))
  checkers.apply(state, 2, "29-25")
  equal("forty", checkers.result(state).detail)

  -- A man moving starts the count again
  state = gameAfter("checkers", "11-15")
  equal(0, state.quiet)
end

-----------------------------
-- Draw offers and history
-----------------------------

--- Starts an accepted chess match
--- @return World, table white, table black, string id
local function startedChess()
  local world = World.New()
  local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  local match = assert(alice.session:Invite("Bob-Realm", "chess"))
  world:Deliver()
  assert(bob.session:Accept(match.id))
  world:Deliver()
  local white = match.me == 1 and alice or bob
  return world, white, white == alice and bob or alice, match.id
end

function tests.DrawOfferedAndAccepted()
  local world, white, black, id = startedChess()
  equal(false, (black.session:OfferDraw(id)), "only on your own turn")
  assert(white.session:OfferDraw(id))
  equal(false, (white.session:OfferDraw(id)), "one offer at a time")
  world:Deliver()
  equal("draw:" .. id, black.events[#black.events])
  equal(1, black.private.Match.DrawOffer(black.matches[id]))
  equal(false, (black.session:AcceptDraw(id)), "not before the offerer has moved")
  equal(false, (white.session:AcceptDraw(id)), "not your own offer")

  play(world, id, white, black, { "e2e4" })
  assert(black.session:AcceptDraw(id))
  world:Deliver()
  for _, player in ipairs({ white, black }) do
    local result = player.private.Match.Result(player.matches[id])
    equal("finished", player.matches[id].status)
    equal(0, result.winner)
    equal("agreement", result.detail)
    equal("!d1,e2e4,!a2", logOf(player, id))
  end
end

function tests.DrawOfferIsTurnedDownByPlayingOn()
  local world, white, black, id = startedChess()
  assert(white.session:OfferDraw(id))
  play(world, id, white, black, { "e2e4", "e7e5" })
  equal(nil, white.private.Match.DrawOffer(white.matches[id]))
  equal(false, (white.session:AcceptDraw(id)))
  -- And can be made again
  assert(white.session:OfferDraw(id))
  world:Deliver()
  equal("active", black.matches[id].status)
end

function tests.NoDrawOffersWhereTheGameHasNone()
  local world, _, _, id, first = startedMatch()
  equal(false, (first.session:OfferDraw(id)))
  -- Nor from an opponent who sends one anyway
  local match = first.matches[id]
  equal(false, (first.private.Match.Append(match, "!d" .. match.me)))
  world:Deliver()
end

function tests.NoDrawOffersInMatchesFromBeforeTheGameHadThem()
  local world, white, _, id = startedChess()
  white.matches[id].gameVersion = 1
  local fresh = world:Relog(white)
  equal(false, (fresh.session:OfferDraw(id)))
  assert(fresh.session:Move(id, "e2e4"))
end

function tests.EventsDescribeMoves()
  local world, white, black, id = startedChess()
  play(world, id, white, black, { "e2e4", "d7d5", "e4d5", "d8d5", "g1f3", "d5e5", "f1e2", "c8g4", "e1g1" })
  local Match = black.private.Match
  local events = Match.Events(black.matches[id])
  local written = {}
  for index, event in ipairs(events) do
    equal("move", event.kind)
    equal(index % 2 == 1 and 1 or 2, event.seat)
    written[index] = event.notation
  end
  equal("e4 d5 exd5 Qxd5 Nf3 Qe5+ Be2 Bg4 O-O", table.concat(written, " "))
  equal("p", events[3].captured)
  equal(square("h1"), events[9].rook.from)
  equal(square("f1"), events[9].rook.to)
end

function tests.NotationSaysWhichPieceWhenTwoCouldMove()
  local state, chess = chessAfter("g1f3 a7a6 b1c3 a6a5 f3d4 a5a4")
  equal("Ndb5", chess.apply(state, 1, "d4b5").notation)
  state = chessAfter("a2a4 a7a6 h2h4 a6a5 a1a3 b7b6 h1h3 b6b5")
  equal("Rab3", chess.apply(state, 1, "a3b3").notation)
  state = chessAfter("f2f3 e7e5 g2g4")
  equal("Qh4#", chess.apply(state, 2, "d8h4").notation)
  -- En passant takes a pawn that isn't on the square moved to
  state = chessAfter("e2e4 a7a6 e4e5 d7d5")
  local event = chess.apply(state, 1, "e5d6")
  equal("exd6", event.notation)
  equal("p", event.captured)
  equal(square("d5"), event.capturedAt)
end

function tests.EarlierPositionsCanBeLookedAt()
  local world, white, black, id = startedChess()
  play(world, id, white, black, { "e2e4", "e7e5", "g1f3" })
  local Match, match = white.private.Match, white.matches[id]

  equal("P", Match.StateAt(match, 0).board[square("e2")])
  equal("P", Match.StateAt(match, 1).board[square("e4")])
  equal(nil, Match.StateAt(match, 1).board[square("e5")])
  equal("p", Match.StateAt(match, 2).board[square("e5")])
  -- Going back again, and all the way forward
  equal(nil, Match.StateAt(match, 1).board[square("e5")])
  equal("N", Match.StateAt(match, 3).board[square("f3")])
  -- Looking back doesn't disturb the game itself
  equal("N", Match.State(match).board[square("f3")])
  play(world, id, black, white, { "b8c6" })
  equal("n", Match.State(match).board[square("c6")])
end

-----------------------------
-- Window
-----------------------------

--- Gives a player the main window, the way Core.lua wires it up in the client
--- @param player table
--- @return table MainFrame
local function openWindow(player)
  Client.Install()
  ForeverGames = { db = { profile = { sound = true, window = { width = 920, height = 680, scale = 100 } } }, printed = {} }
  function ForeverGames:Print(text)
    self.printed[#self.printed + 1] = text
  end

  local private = player.private
  local nothing = function() end
  private.ICON = "icon"
  private.session = player.session
  private.Transport = {
    DisplayName = function(name)
      return name
    end,
    IsLocked = function()
      return false
    end,
  }
  private.Wizard = { Init = nothing, Reset = nothing, Refresh = nothing, Open = nothing, Close = nothing }
  function private.Wizard.IsOpen()
    return false
  end
  private.presence = { Announce = nothing }
  function private.presence:Counts()
    return { total = 0, guild = 0, friend = 0, other = 0 }
  end
  function private.presence:CanAnnounce()
    return false
  end
  function private.presence:SinceAnnounce()
    return 100
  end

  for _, file in ipairs(GUI_FILES) do
    assert(loadfile(file))(ADDON_NAME, private)
  end
  player.onEvent = function()
    private.MainFrame.Refresh()
  end
  return private.MainFrame
end

--- The board of the game on screen
local function shownBoard()
  local found = Client.Find(function(widget)
    return widget.scripts.OnMouseDown and widget.scripts.OnUpdate and widget:IsVisible()
  end)
  assert(#found == 1, "Expected one board on screen, found " .. #found)
  return found[1]
end

--- Moves the cursor onto a chess square
--- @param board table
--- @param name string
--- @param flipped boolean Whether black is at the bottom
local function pointAt(board, name, flipped)
  local cell = board.width / 8
  local column, row = name:byte(1) - 97, tonumber(name:sub(2)) - 1
  if flipped then
    column, row = 7 - column, 7 - row
  end
  Client.cursor = { (column + 0.5) * cell, (row + 0.5) * cell }
end

local function press(board)
  Client.mouseDown = true
  board:Fire("OnMouseDown", "LeftButton")
end

local function release(board)
  Client.mouseDown = false
  board:Fire("OnMouseUp", "LeftButton")
end

--- Lets time pass on the board, so glides finish
local function settle(board)
  for _ = 1, 30 do
    board:Fire("OnUpdate", 0.02)
  end
end

--- Starts a chess match where the player with the window has the white pieces
--- @return World, table white, table black, string id, table MainFrame
local function chessOnScreen()
  local world = World.New()
  world.seed = 1
  local white, black = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  local match = assert(white.session:Invite("Bob-Realm", "chess"))
  equal(1, match.me)
  world:Deliver()
  assert(black.session:Accept(match.id))
  world:Deliver()
  local MainFrame = openWindow(white)
  MainFrame.Open(match.id)
  return world, white, black, match.id, MainFrame
end

function tests.WindowWithNoGamesSaysWhatItIsAndWhoMadeIt()
  local alone = World.New():AddPlayer("Alice-Realm")
  openWindow(alone).Open()

  -- The texts are their keys here
  for _, key in ipairs({ "empty_title", "empty_text", "empty_version", "empty_created", "empty_thanks", "empty_disclaimer" }) do
    local shown = Client.Find(function(widget)
      return type(widget.text) == "string" and widget.text:find(key, 1, true) ~= nil and widget:IsVisible()
    end)
    equal(1, #shown, key)
  end

  -- The wisp on the logo goes around, shedding motes, a shine runs over its letters and the cloud
  -- of light behind it drifts, without tripping over anything
  local moving = Client.Find(function(widget)
    return widget:GetScript("OnUpdate") ~= nil and widget:IsVisible()
  end)
  assert(#moving >= 1, "something should be moving")
  for _ = 1, 400 do
    for _, widget in ipairs(moving) do
      widget:Fire("OnUpdate", 0.02)
    end
  end

  -- A player who would rather the logo kept still can say so in the options
  local home = ForeverGamesFrame.home
  for _, moved in ipairs({ home.wisp, home.shimmer, home.nebula }) do
    equal(true, moved:IsVisible())
  end
  ForeverGames.db.profile.wisp = false
  alone.private.MainFrame.Refresh()
  for _, moved in ipairs({ home.wisp, home.shimmer, home.nebula }) do
    equal(false, moved:IsVisible())
  end
end

function tests.WindowOpensOnItsFrontPageWhateverGamesThereAre()
  local world = World.New()
  local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  local challenge = assert(bob.session:Invite("Alice-Realm", "chess"))
  world:Deliver()
  local alone = assert(alice.session:Invite({}, "solitaire"))
  local MainFrame = openWindow(alice)
  MainFrame.Open()

  --- @return table[] The games listed, from the top
  local function rows()
    return Client.Find(function(widget)
      return widget.kind == "Button" and widget.matchId ~= nil and widget:IsVisible()
    end)
  end
  --- @param text string
  --- @return number How many visible buttons say so
  local function buttons(text)
    return #Client.Find(function(widget)
      return widget.kind == "Button" and widget.text == text and widget:IsVisible()
    end)
  end

  -- No game is picked for the player: the games are listed under the logo, the challenge first
  equal(false, MainFrame.IsViewing(challenge.id))
  equal(false, MainFrame.IsViewing(alone.id))
  equal(1, buttons("new_game"))
  equal(0, buttons("home"))
  equal(2, #rows())
  equal(challenge.id, rows()[1].matchId)
  equal("list_challenge", rows()[1].status.text)
  equal(true, rows()[1].marker:IsShown())
  -- A game that is being played is opened, not resigned from the list
  equal(0, buttons("give_up"))

  -- Going on is with the game that waits on the player
  Client.Button("continue_game"):Fire("OnClick")
  equal(true, MainFrame.IsViewing(challenge.id))
  equal(0, buttons("new_game"))
  Client.Button("home"):Fire("OnClick")
  equal(false, MainFrame.IsViewing(challenge.id))

  -- The challenge is answered where it is listed, and taking it up is playing it
  equal(1, buttons("decline"))
  Client.Button("accept"):Fire("OnClick")
  world:Deliver()
  equal("active", alice.matches[challenge.id].status)
  equal(true, MainFrame.IsViewing(challenge.id))
  equal(0, buttons("next_waiting"), "nothing else waits on the player")

  -- Another challenge is a click away from the game that is on screen
  local second = assert(bob.session:Invite("Alice-Realm", "checkers"))
  world:Deliver()
  Client.Button("next_waiting"):Fire("OnClick")
  equal(true, MainFrame.IsViewing(second.id))
  Client.Button("decline"):Fire("OnClick")
  world:Deliver()

  -- Closed and opened again the window is where it was left
  MainFrame.Select(alone.id)
  MainFrame.Toggle()
  MainFrame.Toggle()
  equal(true, MainFrame.IsViewing(alone.id))

  -- With nobody waiting, going on is with the game that was looked at last
  assert(alice.session:Resign(challenge.id))
  world:Deliver()
  MainFrame.Home()
  Client.Button("continue_game"):Fire("OnClick")
  equal(true, MainFrame.IsViewing(alone.id))

  -- A game that is given up leaves the player at the front page
  Client.Button("give_up"):Fire("OnClick")
  equal(false, MainFrame.IsViewing(alone.id))
  equal(1, buttons("new_game"))

  -- Who is around is said in a box of its own, where something turns while that is being asked
  local presence = ForeverGamesFrame.home.presence
  equal("presence_none", presence.title.text)
  equal(true, presence.dot:IsVisible())
  equal(false, presence.spinner:IsVisible())
  function alice.private.presence:SinceAnnounce()
    return 2
  end
  MainFrame.Refresh()
  equal("presence_looking", presence.title.text)
  equal(false, presence.dot:IsVisible())
  equal(true, presence.spinner:IsVisible())
  for _ = 1, 60 do
    presence.spinner:Fire("OnUpdate", 0.02)
  end
end

function tests.WindowPlaysChessByClickingAndDragging()
  local world, white, black, id = chessOnScreen()
  local board = shownBoard()
  assert(board.width >= 8 * 40, "the board should make use of the window, got " .. board.width)

  -- Click the pawn, then where it goes
  pointAt(board, "e2")
  press(board)
  release(board)
  equal("", logOf(white, id), "picking a piece up isn't a move")
  pointAt(board, "e4")
  press(board)
  release(board)
  equal("e2e4", logOf(white, id))
  equal("IG_ABILITY_ICON_DROP", Client.sounds[#Client.sounds])
  settle(board)

  -- Not on the opponent's turn
  pointAt(board, "d2")
  press(board)
  release(board)
  pointAt(board, "d4")
  press(board)
  release(board)
  equal("e2e4", logOf(white, id))

  world:Deliver()
  assert(black.session:Move(id, "e7e5"))
  world:Deliver()
  settle(board)

  -- Drag the knight out
  pointAt(board, "g1")
  press(board)
  board:Fire("OnUpdate", 0.02)
  pointAt(board, "f3")
  board:Fire("OnUpdate", 0.02)
  release(board)
  equal("e2e4,e7e5,g1f3", logOf(white, id))
  world:Deliver()
  assert(black.session:Move(id, "b8c6"))
  world:Deliver()

  -- Dropped somewhere it can't go, it comes back
  pointAt(board, "f3")
  press(board)
  board:Fire("OnUpdate", 0.02)
  pointAt(board, "f6")
  board:Fire("OnUpdate", 0.02)
  release(board)
  settle(board)
  equal("e2e4,e7e5,g1f3,b8c6", logOf(white, id))
end

function tests.WindowStepsBackThroughAGame()
  local world, white, black, id, MainFrame = chessOnScreen()
  local board = shownBoard()
  play(world, id, white, black, { "e2e4", "e7e5" })

  local moves = Client.Find(function(widget)
    return widget.kind == "Button" and widget.ply ~= nil and widget:IsVisible()
  end)
  equal(2, #moves)
  equal("e4", moves[1].text.text)
  equal("e5", moves[2].text.text)

  Client.Button("<"):Fire("OnClick")
  -- An earlier position is for looking at, not for playing from
  pointAt(board, "d2")
  press(board)
  release(board)
  pointAt(board, "d4")
  press(board)
  release(board)
  equal("e2e4,e7e5", logOf(white, id))

  Client.Button("<<"):Fire("OnClick")
  Client.Button(">"):Fire("OnClick")
  moves[2]:Fire("OnClick")
  pointAt(board, "d2")
  press(board)
  release(board)
  pointAt(board, "d4")
  press(board)
  release(board)
  equal("e2e4,e7e5,d2d4", logOf(white, id), "back at the end the game goes on")

  -- News brings the window back to the game as it stands
  world:Deliver()
  Client.Button("<<"):Fire("OnClick")
  assert(black.session:Move(id, "e5d4"))
  world:Deliver()
  settle(board)
  pointAt(board, "d1")
  press(board)
  release(board)
  pointAt(board, "d4")
  press(board)
  release(board)
  equal("e2e4,e7e5,d2d4,e5d4,d1d4", logOf(white, id))
  MainFrame.Refresh()
end

function tests.WindowAsksWhatAPawnPromotesTo()
  local world, white, black, id = chessOnScreen()
  local board = shownBoard()
  play(world, id, white, black, { "a2a4", "b7b5", "a4b5", "a7a6", "b5a6", "c8b7", "a6b7", "b8c6" })
  local before = logOf(white, id)

  local function choices()
    return Client.Find(function(widget)
      return widget.kind == "Button" and widget.piece ~= nil and widget:IsVisible()
    end)
  end
  equal(0, #choices())

  pointAt(board, "b7")
  press(board)
  release(board)
  pointAt(board, "a8")
  press(board)
  release(board)
  equal(before, logOf(white, id), "nothing is played until a piece is chosen")
  equal(4, #choices())

  -- Clicking away takes it back
  choices()[1].parent.parent:Fire("OnClick")
  equal(0, #choices())
  equal(before, logOf(white, id))

  pointAt(board, "b7")
  press(board)
  board:Fire("OnUpdate", 0.02)
  pointAt(board, "a8")
  board:Fire("OnUpdate", 0.02)
  release(board)
  choices()[4]:Fire("OnClick")
  equal(before .. ",b7a8n", logOf(white, id))
  equal(0, #choices())
end

function tests.WindowOffersAndAcceptsDraws()
  local world, white, black, id, MainFrame = chessOnScreen()
  Client.Button("offer_draw"):Fire("OnClick")
  equal("!d1", logOf(white, id))
  equal("status_draw_offering", MainFrame.Describe(white.matches[id]))
  play(world, id, white, black, { "e2e4" })
  equal("status_their_turn_draw", MainFrame.Describe(white.matches[id]))

  -- The other side of it
  play(world, id, black, white, { "e7e5" })
  assert(white.session:Move(id, "g1f3"))
  world:Deliver()
  assert(black.session:OfferDraw(id))
  assert(black.session:Move(id, "b8c6"))
  world:Deliver()
  equal("status_draw_offered", MainFrame.Describe(white.matches[id]))
  Client.Button("accept_draw"):Fire("OnClick")
  world:Deliver()
  equal("finished", black.matches[id].status)
  equal("status_draw (result_agreement)", MainFrame.Describe(white.matches[id]))
end

function tests.WindowGivesTheBoardTheRoomItHas()
  local _, _, _, _, MainFrame = chessOnScreen()
  local board = shownBoard()
  local normal = board.width

  ForeverGamesFrame:SetSize(1400, 1000)
  assert(board.width > normal, "a bigger window should mean a bigger board")

  ForeverGamesFrame:SetSize(764, 560)
  assert(board.width >= 8 * 30, "the board should stay usable in the smallest window, got " .. board.width)
  MainFrame.Refresh()
end

function tests.ListPutsMatchesNeedingAttentionFirst()
  local world, alice, _, id, first = startedMatch()
  world.clock = world.clock + 10
  local other = assert(alice.session:Invite("Carol-Realm", "tictactoe"))
  alice.session:MarkRead(id)
  local list = alice.session:List()
  equal(2, #list)
  if first == alice then
    equal(id, list[1].id, "my turn sorts first even though it is older")
  else
    equal(other.id, list[1].id)
  end
end

--- Starts a match of some game where the player with the window moves first
--- @param game string Game id
--- @return World, table first, table second, string id, table MainFrame
local function gameOnScreen(game)
  local world = World.New()
  world.seed = 1
  local first, second = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  local match = assert(first.session:Invite("Bob-Realm", game))
  equal(1, match.me)
  world:Deliver()
  assert(second.session:Accept(match.id))
  world:Deliver()
  local MainFrame = openWindow(first)
  MainFrame.Open(match.id)
  return world, first, second, match.id, MainFrame
end

--- Clicks a square of a board that isn't turned around, counted from the bottom left
--- @param board table
--- @param column number From 0
--- @param row number From 0
--- @param columns number How many the board has
--- @param button string?
local function clickSquare(board, column, row, columns, button)
  local cell = board.width / columns
  Client.cursor = { (column + 0.5) * cell, (row + 0.5) * cell }
  board:Fire("OnUpdate", 0.02)
  if button then
    board:Fire("OnMouseDown", button)
    return
  end
  press(board)
  release(board)
end

--- The moves in the move list, in the order they were made
--- @return table[]
local function listedMoves()
  local moves = Client.Find(function(widget)
    return widget.kind == "Button" and widget.ply ~= nil and widget:IsVisible()
  end)
  table.sort(moves, function(a, b)
    return a.ply < b.ply
  end)
  return moves
end

function tests.WindowPlaysTicTacToe()
  local world = World.New()
  world.seed = 1
  local first, second = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  local match = assert(first.session:Invite("Bob-Realm", "tictactoe"))
  world:Deliver()
  assert(second.session:Accept(match.id))
  world:Deliver()
  openWindow(first).Open(match.id)

  local board = shownBoard()
  assert(board.width >= 3 * 60, "the board should make use of the window, got " .. board.width)
  equal(board.width, board.height)

  -- Cells are counted from the top left, the middle one is the fifth
  clickSquare(board, 1, 1, 3)
  equal("5", logOf(first, match.id))
  equal("IG_ABILITY_ICON_DROP", Client.sounds[#Client.sounds])
  local crosses = Client.Find(function(widget)
    return widget.kind == "Texture" and widget.shown and tostring(widget.texture):match("Marks.-x$") ~= nil
  end)
  equal(1, #crosses, "a cross where the player clicked")
  settle(board)

  clickSquare(board, 0, 2, 3)
  equal("5", logOf(first, match.id), "not on the opponent's turn")
  world:Deliver()
  assert(second.session:Move(match.id, "1"))
  world:Deliver()
  clickSquare(board, 0, 2, 3)
  equal("5,1", logOf(first, match.id), "nor on a square that is taken")
  clickSquare(board, 2, 2, 3)
  equal("5,1,3", logOf(first, match.id), "the top right one is the third")
end

function tests.WindowPlaysConnectFourByPointingAtAColumn()
  local world, red, yellow, id = gameOnScreen("connectfour")
  local board = shownBoard()
  assert(board.width >= 7 * 40, "the rack should make use of the window, got " .. board.width)
  equal(board.width / 7 * 6, board.height, "seven columns by six rows")

  -- Anywhere in the column will do, the disc falls to the bottom
  clickSquare(board, 3, 5, 7)
  equal("4", logOf(red, id))
  equal("chipsCollide", Client.sounds[#Client.sounds])
  settle(board)

  -- Not on the opponent's turn
  clickSquare(board, 0, 0, 7)
  equal("4", logOf(red, id))

  world:Deliver()
  assert(yellow.session:Move(id, "4"))
  world:Deliver()
  settle(board)

  -- On a disc that is already there, the next one goes on top
  clickSquare(board, 3, 0, 7)
  equal("4,4,4", logOf(red, id))
  equal(3, red.private.Match.State(red.matches[id]).heights[4])
end

function tests.WindowPlaysReversiByPlacingDiscs()
  local world, black, white, id = gameOnScreen("reversi")
  local board = shownBoard()

  -- Only where a disc traps something
  clickSquare(board, 0, 0, 8)
  equal("", logOf(black, id))
  clickSquare(board, 3, 2, 8)
  equal("d3", logOf(black, id))
  settle(board)
  equal("d3", listedMoves()[1].text.text)

  world:Deliver()
  assert(white.session:Move(id, "c3"))
  world:Deliver()
  settle(board)
  clickSquare(board, 1, 2, 8)
  equal("d3,c3,b3", logOf(black, id))
end

function tests.WindowShowsAReversiPlayerSittingOut()
  local world, black, white, id, MainFrame = gameOnScreen("reversi")
  local board = shownBoard()
  local function notes()
    return Client.Find(function(widget)
      return widget.text == "reversi_passed" and widget:IsVisible()
    end)
  end

  play(world, id, black, white, { "f5", "f6", "f7", "g7", "c4", "f8", "h8" })
  equal(0, #notes())
  assert(white.session:Move(id, "h6"))
  world:Deliver()
  settle(board)
  equal(1, #notes(), "the board says why it isn't black's turn")
  equal("status_their_turn", MainFrame.Describe(black.matches[id]))

  -- Black can't place anything meanwhile
  for column = 0, 7 do
    for row = 0, 7 do
      clickSquare(board, column, row, 8)
    end
  end
  equal(8, #black.matches[id].log)

  local state = white.private.Match.State(white.matches[id])
  local again = string.char(97 + next(state.legal) % 8) .. (math.floor(next(state.legal) / 8) + 1)
  assert(white.session:Move(id, again))
  world:Deliver()

  -- White's two moves in a row are on a line each, with a gap where black's would have been
  local moves = listedMoves()
  equal(9, #moves)
  equal(again, moves[9].text.text)
  local row = moves[9].parent
  assert(row.moves[2] == moves[9], "white's move belongs in white's column")
  equal(false, row.moves[1]:IsShown())
  assert(moves[8].parent ~= row and moves[8].parent.moves[2] == moves[8])
  assert(moves[7].parent == moves[8].parent, "the line before has a move from each")
end

--- Clicks the square checkers players know by a number, on a board with red at the bottom
--- @param board table
--- @param number number 1 to 32
--- @param button string?
local function clickChecker(board, number, button)
  local row = math.floor((number - 1) / 4)
  clickSquare(board, 2 * (3 - (number - 1) % 4) + row % 2, row, 8, button)
end

function tests.WindowPlaysCheckersOneJumpAtATime()
  local world, red, white, id = gameOnScreen("checkers")
  local board = shownBoard()

  clickChecker(board, 10)
  clickChecker(board, 15)
  equal("10-15", logOf(red, id))
  equal("chipsCollide", Client.sounds[#Client.sounds])
  settle(board)
  world:Deliver()
  assert(white.session:Move(id, "22-18"))
  world:Deliver()
  settle(board)

  -- With a piece to take, the others stay where they are
  clickChecker(board, 9)
  clickChecker(board, 13)
  equal("10-15,22-18", logOf(red, id))
  clickChecker(board, 15)
  clickChecker(board, 22)
  equal("10-15,22-18,15-22", logOf(red, id))
  equal("IG_BACKPACK_CLOSE", Client.sounds[#Client.sounds])
  equal("15x22", listedMoves()[3].text.text)
  world:Deliver()

  play(world, id, white, red, { "26-17", "9-13", "31-26" })
  settle(board)
  local before = logOf(red, id)

  -- A double jump: the first hop alone isn't a move yet
  clickChecker(board, 13)
  clickChecker(board, 22)
  equal(before, logOf(red, id))
  settle(board)
  -- Halfway there the piece can only go on, nothing else can be picked up
  clickChecker(board, 12)
  clickChecker(board, 16)
  equal(before, logOf(red, id))

  -- Any other mouse button takes the piece back to where it started
  clickChecker(board, 13)
  clickChecker(board, 22)
  clickChecker(board, 22, "RightButton")
  clickChecker(board, 31)
  equal(before, logOf(red, id), "back at the start the second hop isn't on offer")

  clickChecker(board, 13)
  clickChecker(board, 22)
  clickChecker(board, 31)
  equal(before .. ",13-22-31", logOf(red, id))
  settle(board)
  world:Deliver()
  equal(logOf(red, id), logOf(white, id))
end

function tests.WindowShowsTheOpponentsCheckersJumps()
  local world, red, white, id = gameOnScreen("checkers")
  local board = shownBoard()
  play(world, id, red, white, { "11-15", "21-17", "9-14", "22-18", "15-22" })
  settle(board)

  -- Two pieces go in one move, and the window shows what is left
  assert(white.session:Move(id, "25-18-9"))
  world:Deliver()
  equal("IG_BACKPACK_CLOSE", Client.sounds[#Client.sounds])
  settle(board)
  local tallies = Client.Find(function(widget)
    return widget.kind == "FontString" and widget.text == "x 2" and widget:IsVisible()
  end)
  equal(1, #tallies, "white has taken two")
  equal("25x18x9", listedMoves()[6].text.text)
end

function tests.WindowShowsCheckersFromTheOtherSide()
  local world, red, white, id = gameOnScreen("checkers")
  play(world, id, red, white, { "11-15", "21-17", "9-14", "22-18" })

  -- White has the window this time, and sees the board turned around
  local MainFrame = openWindow(white)
  MainFrame.Open(id)
  local board = shownBoard()
  assert(red.session:Move(id, "15-22"))
  world:Deliver()
  settle(board)

  --- Moves the cursor onto a square by its number
  --- @param number number
  local function point(number)
    local row = math.floor((number - 1) / 4)
    local cell = board.width / 8
    Client.cursor = { (7 - (2 * (3 - (number - 1) % 4) + row % 2) + 0.5) * cell, (7 - row + 0.5) * cell }
    board:Fire("OnUpdate", 0.02)
  end
  point(25)
  press(board)
  release(board)
  point(18)
  press(board)
  release(board)
  equal(5, #white.matches[id].log, "one hop of two isn't a move")
  settle(board)

  -- The second hop can be dragged like any move
  press(board)
  board:Fire("OnUpdate", 0.02)
  point(9)
  release(board)
  equal("25-18-9", white.matches[id].log[6])
  world:Deliver()
  equal(logOf(white, id), logOf(red, id))
end

-----------------------------
-- Finding a game
-----------------------------

--- @param games table[]
--- @return string Their ids, in order
local function idsOf(games)
  local ids = {}
  for index, game in ipairs(games) do
    ids[index] = game.id
  end
  return table.concat(ids, ",")
end

function tests.GamesAreFoundByWordAndGenre()
  local Games = loadEngine().Games
  local everything = idsOf(Games.List())
  equal(everything, idsOf(Games.Search()))
  equal(everything, idsOf(Games.Search("  ")))
  equal("casual,strategy,dice,cards,words,solo", table.concat(Games.Genres(), ","))

  -- The tests see the names of the strings rather than the strings, which is as good to search
  equal("chess", idsOf(Games.Search("chess")))
  equal("chess", idsOf(Games.Search("CHESS")), "in any case")
  equal("chess", idsOf(Games.Search("description chess")), "every word has to be there, wherever")
  equal("", idsOf(Games.Search("chess reversi")))
  equal("chess,reversi,checkers,chinesecheckers,battleship,wormcraft", idsOf(Games.Search("strategy")), "a genre's name finds its games")
  equal("tictactoe,connectfour", idsOf(Games.Search(nil, "casual")))
  equal("connectfour", idsOf(Games.Search("four", "casual")))
  equal("", idsOf(Games.Search("chess", "casual")))
  equal("crazyeights,solitaire", idsOf(Games.Search(nil, "cards")), "a game for one goes with the others like it")
  equal("", idsOf(Games.Search("%a+")), "what is typed is looked for as it is")

  -- By how many are playing
  local alone = "yacht,solitaire,minesweeper,2048,sudoku,fourtiles,warcraftstein,freedoom,where"
  equal(alone, idsOf(Games.Search(nil, nil, 1)), "the games for one: the computer's are games for two and more")
  equal("words,fourtiles", idsOf(Games.Search(nil, "words", 2)), "one that is played alone or by two is found either way")
  equal("chinesecheckers,crazyeights,words,wormcraft", idsOf(Games.Search(nil, nil, 3)), "three stands for any more than two")
  equal("chinesecheckers,wormcraft", idsOf(Games.Search(nil, "strategy", 3)))
  equal("", idsOf(Games.Search(nil, "solo", 2)))

  for _, game in ipairs(Games.List()) do
    assert(game.genre, game.id .. " should say what kind of game it is")
  end
end

--- Opens the new game wizard for a player, on its own without the window around it
--- @param player table
--- @return table Wizard
local function openWizard(player)
  Client.Install()
  CANCEL, BACK = "Cancel", "Back"
  local private = player.private
  private.ICON = "icon"
  private.session = player.session
  ForeverGames = { db = { profile = { sound = true, favourites = {} } } }
  private.Transport = {
    Normalize = function(name)
      return name ~= "" and name or nil
    end,
    DisplayName = function(name)
      return name
    end,
    PlayerName = function()
      return player.name
    end,
  }
  private.presence = {}
  function private.presence:List()
    return {}
  end
  function UnitIsPlayer()
    return false
  end

  for _, file in ipairs({ "GUI/Widgets.lua", "GUI/Wizard.lua" }) do
    assert(loadfile(file))(ADDON_NAME, private)
  end
  private.Wizard.Init(UIParent, function() end)
  private.Wizard.Open()
  return private.Wizard
end

-- The wizard's table of who plays, for the tests to read and click
local seating = {}

--- The table of who plays in the wizard, a seat at a time from the player's own: who sits there,
--- and what can be clicked on the seat in brackets
--- @return string, table[] cards
function seating.Shown()
  local cards = Client.Find(function(widget)
    return widget.kind == "Button" and widget.remove ~= nil and widget.action ~= nil and widget:IsVisible()
  end)
  local said = {}
  for index, card in ipairs(cards) do
    said[index] = card.name.text .. (card.action:IsVisible() and (" [" .. card.action.label.text .. "]") or "")
  end
  return table.concat(said, ", "), cards
end

--- Clicks a button of the wizard's that says something on a label of its own
--- @param text string
--- @param nth number? Which of the ones saying it, the first if left out
function seating.Click(text, nth)
  local found = Client.Find(function(widget)
    return widget.kind == "Button" and widget.label ~= nil and widget.label.text == text and widget:IsVisible()
  end)
  assert(found[nth or 1], "no button saying " .. text)
  found[nth or 1]:Fire("OnClick")
end

--- The buttons that say how many seats the wizard's table has, by what they say
--- @return table<string, table>
function seating.Sizes()
  local sizes = {}
  for _, widget in ipairs(Client.Find(function(widget)
    return widget.kind == "Button" and widget.label ~= nil and widget.parent ~= nil and widget.parent.cards ~= nil and widget:IsVisible()
  end)) do
    sizes[widget.label.text] = widget
  end
  return sizes
end

--- The games on offer in the wizard, in reading order
--- @return table[]
local function offeredGames()
  local games = {}
  for _, card in ipairs(Client.Find(function(widget)
    return widget.kind == "Button" and widget.game ~= nil and widget:IsVisible()
  end)) do
    games[#games + 1] = card.game
  end
  return games
end

--- Clicks one of the buttons that narrow the games down
--- @param text string What it says
local function clickGenre(text)
  local found = Client.Find(function(widget)
    return widget.kind == "Button" and widget.label ~= nil and widget.label.text == text and widget:IsVisible()
  end)
  equal(1, #found, "buttons saying " .. text)
  found[1]:Fire("OnClick")
end

function tests.WizardNarrowsTheGamesDown()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  world:AddPlayer("Bob-Realm")
  local wizard = openWizard(alice)
  -- The games for a room are listed with the rest
  local count = #alice.private.Games.List() + #alice.private.Rooms.Games()
  equal(count, #offeredGames())

  local search = Client.Find(function(widget)
    return widget.kind == "EditBox" and widget.scripts.OnEnterPressed and widget:IsVisible()
  end)[1]
  local function type(text)
    search:SetText(text)
    search:Fire("OnTextChanged", true)
  end
  local function nothingFound()
    return #Client.Find(function(widget)
      return widget.text == "wizard_no_games" and widget:IsVisible()
    end) == 1
  end

  type("chess")
  equal(1, #offeredGames())
  equal("chess", idsOf(offeredGames()))
  equal(false, nothingFound())
  type("no such game")
  equal(0, #offeredGames())
  equal(true, nothingFound())
  type("")
  equal(count, #offeredGames())

  -- Those for any number but one aren't set up here: they have a window of their own
  clickGenre("genre_party")
  equal("sketch,trivia", idsOf(offeredGames()))
  clickGenre("genre_solo")
  equal(0, #offeredGames())
  clickGenre("wizard_all_games")
  type("sketch")
  equal("sketch", idsOf(offeredGames()))
  local opened = 0
  alice.private.Party = {
    Open = function()
      opened = opened + 1
    end,
  }
  search:Fire("OnEnterPressed")
  equal(1, opened)
  equal(false, wizard.IsOpen())
  wizard.Open()
  type("")

  -- By genre, on top of whatever is typed
  clickGenre("genre_casual")
  equal("connectfour,tictactoe", idsOf(offeredGames()), "by name")
  type("chess")
  equal(0, #offeredGames())
  clickGenre("wizard_all_games")
  equal(1, #offeredGames())

  -- Enter takes the only game left, and from there it is the wizard as before
  search:Fire("OnEnterPressed")
  equal(0, #offeredGames())
  local name = Client.Find(function(widget)
    return widget.kind == "EditBox" and widget ~= search and widget:IsVisible()
  end)[1]
  name:SetText("Bob-Realm")
  Client.Button("wizard_send"):Fire("OnClick")
  local started
  for _, match in pairs(alice.matches) do
    started = match
  end
  equal("chess", started.game)
  equal("outgoing", started.status)
end

function tests.WizardKeepsFavouritesFirst()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local wizard = openWizard(alice)
  local favourites = ForeverGames.db.profile.favourites
  local byName = {}
  for _, game in ipairs(alice.private.Games.List()) do
    byName[#byName + 1] = game.id
  end
  for _, game in ipairs(alice.private.Rooms.Games()) do
    byName[#byName + 1] = game.id
  end
  table.sort(byName)
  equal(table.concat(byName, ","), idsOf(offeredGames()), "by name until something is starred")

  --- Clicks the star on a game's card
  local function star(id)
    local found = Client.Find(function(widget)
      return widget.kind == "Button" and widget.parent.game ~= nil and widget.parent.game.id == id and widget:IsVisible()
    end)
    equal(1, #found, "stars on " .. id)
    found[1]:Fire("OnClick")
  end

  clickGenre("wizard_favourites")
  equal(0, #offeredGames())
  equal(1, #Client.Find(function(widget)
    return widget.text == "wizard_no_favourites" and widget:IsVisible()
  end))
  clickGenre("wizard_favourites")

  star("words")
  star("chess")
  equal(true, favourites.words)
  equal("chess,words,2048", idsOf({ unpack(offeredGames(), 1, 3) }), "the starred ones lead")
  clickGenre("wizard_favourites")
  equal("chess,words", idsOf(offeredGames()))
  clickGenre("wizard_more_players")
  equal("words", idsOf(offeredGames()), "on top of each other")
  clickGenre("wizard_more_players")
  star("words")
  equal(nil, favourites.words, "nothing is kept of a star taken back")
  equal("chess", idsOf(offeredGames()))

  -- All is every game again, and so is opening the wizard another time
  clickGenre("wizard_all_games")
  equal(#byName, #offeredGames())
  clickGenre("wizard_two_players")
  local forTwo = #alice.private.Games.Search(nil, nil, 2) + #alice.private.Rooms.Games()
  equal(forTwo, #offeredGames(), "all but the ones only played alone, or only by more")
  wizard.Open()
  equal(#byName, #offeredGames())
  equal("chess", offeredGames()[1].id, "a favourite stays one")
end

function tests.WizardFitsItsCardsToTheWindow()
  local world = World.New()
  local wizard = openWizard(world:AddPlayer("Alice-Realm"))
  -- The room the games get in a window of 920, the size it comes in, and of 764, the smallest
  local columns, width = wizard.FitCards(920 - 36 - 8)
  equal(3, columns)
  equal(true, 3 * width + 2 * 12 <= 920 - 36 - 8, "nothing sticks out")
  equal(2, (wizard.FitCards(764 - 36 - 8)))
  equal(1, (wizard.FitCards(100)), "never none")
  equal(6, (wizard.FitCards(1920 - 36 - 8)))
end

function tests.ListsSayWhenThereIsMoreToScrollTo()
  Client.Install()
  local private = loadEngine()
  assert(loadfile("GUI/Widgets.lua"))(ADDON_NAME, private)
  local list = private.Widgets.List(UIParent, 100, 20, function(content)
    return CreateFrame("Frame", nil, content)
  end)
  list.frame:SetSize(100, 60)
  local function thumb()
    return Client.Find(function(widget)
      return widget.kind == "Texture" and widget.parent == list.frame
    end)[1]
  end

  list:Update({ 1, 2, 3 }, function() end)
  equal(false, thumb():IsShown(), "everything fits")
  list:Update({ 1, 2, 3, 4, 5, 6 }, function() end)
  equal(true, thumb():IsShown())
  equal(30, thumb().height, "half of it is in view")

  list.frame:Fire("OnMouseWheel", -1)
  equal(20, list.frame:GetVerticalScroll())
  for _ = 1, 10 do
    list.frame:Fire("OnMouseWheel", -1)
  end
  equal(60, list.frame:GetVerticalScroll(), "no further than the end")
  list:Update({ 1 }, function() end)
  equal(0, list.frame:GetVerticalScroll())
  equal(false, thumb():IsShown())
end

-----------------------------
-- More than two players
-----------------------------

--- Sets up a match that everyone has yet to accept
--- @param count number How many play
--- @param gameId string? Chinese Checkers if left out
--- @return World, table[] players In seat order, string id, table host
local function invitedCrowd(count, gameId)
  local world = World.New()
  local everyone, others = {}, {}
  for index, name in ipairs({ "Alice-Realm", "Bob-Realm", "Carol-Realm", "Dave-Realm", "Erin-Realm", "Frank-Realm" }) do
    if index <= count then
      everyone[index] = world:AddPlayer(name)
      others[#others + 1] = index > 1 and name or nil
    end
  end
  local host = everyone[1]
  local match = assert(host.session:Invite(others, gameId or "chinesecheckers"))
  world:Deliver()

  local seated = {}
  for seat, name in ipairs(match.players) do
    seated[seat] = world.players[name]
  end
  return world, seated, match.id, host
end

--- Starts a match that everyone accepted
--- @param count number
--- @param gameId string? Chinese Checkers if left out
--- @return World, table[] players In seat order, string id, table host
local function startedCrowd(count, gameId)
  local world, seated, id, host = invitedCrowd(count, gameId)
  for _, player in ipairs(seated) do
    if player ~= host then
      assert(player.session:Accept(id))
    end
  end
  world:Deliver()
  return world, seated, id, host
end

--- Every move the player to move has in a game of Chinese Checkers, as the game writes them
--- @param game table
--- @param state table
--- @return string[]
local function marbleMoves(game, state)
  local moves = {}
  for from = 1, 121 do
    if state.board[from] == state.turn then
      for to = 1, 121 do
        if game.validate(state, state.turn, from .. "-" .. to) then
          moves[#moves + 1] = from .. "-" .. to
        end
      end
    end
  end
  return moves
end

--- Has whoever's turn it is make the first move they have
--- @param world World
--- @param seated table[]
--- @param id string
--- @return table player Who moved
local function moveSomething(world, seated, id)
  -- Everyone has their own copy of the engine, and it only keeps up with its own player's matches
  local player
  for _, candidate in ipairs(seated) do
    local match = candidate.online and candidate.matches[id]
    if match and candidate.private.Match.IsMyTurn(match) then
      player = candidate
    end
  end
  assert(player, "nobody who is around thinks it is their turn")
  local move = marbleMoves(player.private.Games.Get("chinesecheckers"), player.private.Match.State(player.matches[id]))[1]
  local ok, err = player.session:Move(id, move)
  assert(ok, tostring(err) .. " for " .. tostring(move) .. " by " .. player.name)
  world:Deliver()
  return player
end

function tests.CodecCarriesWhoIsPlaying()
  local Codec = loadEngine().Codec
  local invite = Codec.Decode(Codec.Encode("INV", "abc", "chinesecheckers", 1, 2, 4, 3, 1, "Quets Al-Realm", 4, "Bøb-Realm"))
  equal(2, invite.seat)
  equal(4, invite.seats)
  equal(3, invite.mine)
  equal("Quets Al-Realm", invite.names[1])
  equal("Bøb-Realm", invite.names[4])
  equal(nil, invite.names[2])

  local who = Codec.Decode(Codec.Encode("WHO", "abc", 5, "Erin-Realm"))
  equal("Erin-Realm", who.names[5])

  -- A challenge between two says nothing of the kind, the way it never did
  equal(nil, Codec.Decode("1:INV:abc:chess:2:1").seats)
  local garbage = { "1:INV:a:x:1:1:3", "1:INV:a:x:1:1:3:2:1", "1:INV:a:x:1:1:3:2:1:A:1:B", "1:WHO:a", "1:WHO:a:1", "1:WHO:a:x:A", "1:WHO:a:0:A" }
  for _, text in ipairs(garbage) do
    equal(nil, Codec.Decode(text), "Decode(" .. text .. ")")
  end
end

function tests.GamesSayHowManyCanPlay()
  local Games = loadEngine().Games
  equal("2", table.concat(Games.SeatCounts(Games.Get("chess")), ","))
  equal("2,3,4,6", table.concat(Games.SeatCounts(Games.Get("chinesecheckers")), ","))
  equal(true, Games.CanSeat(Games.Get("chinesecheckers"), 6))
  equal(false, Games.CanSeat(Games.Get("chinesecheckers"), 5))
  equal(false, Games.CanSeat(Games.Get("chess"), 3))

  -- A game for more than two has to say what happens when one of them resigns
  local nothing = function() end
  local definition = { id = "crowd", name = "Crowd", version = 1, seats = { 2, 3 }, newState = nothing, turn = nothing }
  definition.validate, definition.apply, definition.result, definition.createView = nothing, nothing, nothing, nothing
  equal(false, (pcall(Games.Register, definition)))
  definition.drop = nothing
  equal(true, (pcall(Games.Register, definition)))
end

function tests.InviteNeedsARightNumberOfPlayers()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local function errorOf(targets, game)
    return select(2, alice.session:Invite(targets, game))
  end
  equal("player_count", errorOf({ "Bob-Realm", "Carol-Realm" }, "chess"))
  equal("player_count", errorOf({ "B-Realm", "C-Realm", "D-Realm", "E-Realm" }, "chinesecheckers"))
  equal("same_player", errorOf({ "Bob-Realm", "Bob-Realm" }, "chinesecheckers"))
  equal("self_invite", errorOf({ "Bob-Realm", "Alice-Realm" }, "chinesecheckers"))
  equal("no_target", errorOf({}, "chinesecheckers"))
  equal("no_target", errorOf({ "Bob-Realm", "" }, "chinesecheckers"))
  equal(nil, next(alice.matches))

  -- Two can play it too, and that is a challenge like any other
  local match = assert(alice.session:Invite({ "Bob-Realm" }, "chinesecheckers"))
  equal(nil, match.host)
  equal("Bob-Realm", world.queue[1].to)
  equal("1:INV:" .. match.id .. ":chinesecheckers:1:" .. match.me, world.queue[1].text)
end

function tests.CrowdStartsOnceEveryoneHasAccepted()
  local world, seated, id, host = invitedCrowd(3)
  local guests = {}
  for seat, player in ipairs(seated) do
    local match = player.matches[id]
    equal(seat, match.me, player.name .. " knows where they sit")
    equal(seated[1].name .. "," .. seated[2].name .. "," .. seated[3].name, table.concat(match.players, ","))
    equal(host.matches[id].me, match.host)
    if player ~= host then
      guests[#guests + 1] = player
      equal("incoming", match.status)
      equal("invite:" .. id, player.events[#player.events])
    end
  end
  equal("outgoing", host.matches[id].status)

  -- With one of them in there is nothing to play yet, for anybody
  assert(guests[1].session:Accept(id))
  world:Deliver()
  equal("outgoing", host.matches[id].status)
  equal("active", guests[1].matches[id].status)
  equal(false, guests[1].private.Match.Started(guests[1].matches[id]))
  equal(nil, guests[1].private.Match.Turn(guests[1].matches[id]))
  equal(false, guests[1].session:Resign(id), "there is nothing to resign from yet")
  local awaited = host.session:Behind(host.matches[id])
  equal(1, #awaited)
  equal(guests[2].name, host.matches[id].players[awaited[1]], "the host knows who it is waiting for")

  assert(guests[2].session:Accept(id))
  world:Deliver()
  for _, player in ipairs(seated) do
    equal("active", player.matches[id].status)
    equal("!s", logOf(player, id))
    equal(true, player.private.Match.Started(player.matches[id]))
    equal(1, player.private.Match.Turn(player.matches[id]))
    equal(false, player.session:IsPending(player.matches[id]), player.name .. " has nothing left to deliver")
  end
  local told = table.concat(host.events, ",")
  assert(told:find("accepted:" .. id, 1, true), "the host is told the game is on: " .. told)
  equal("started:" .. id, guests[1].events[#guests[1].events])
end

function tests.CrowdIsCalledOffWhenSomeoneDeclines()
  local world, seated, id, host = invitedCrowd(4)
  local guests = {}
  for _, player in ipairs(seated) do
    guests[#guests + 1] = player ~= host and player or nil
  end
  assert(guests[1].session:Accept(id))
  world:Deliver()
  assert(guests[2].session:Decline(id))
  world:Deliver()

  equal("declined", host.matches[id].status)
  equal(guests[2].name, host.matches[id].players[host.matches[id].declinedBy])
  -- Whoever was in already is told, whoever hadn't answered just sees it go
  equal("declined", guests[1].matches[id].status)
  equal("off", guests[1].matches[id].declineReason)
  equal(nil, guests[3].matches[id])
  equal("cancelled:" .. id, guests[3].events[#guests[3].events])

  world:Tick(700)
  equal(0, #world.queue)
  equal(false, host.session:IsPending(host.matches[id]))
end

function tests.CrowdHostCanWithdrawAndGuestsCanLeave()
  local world, seated, id, host = invitedCrowd(3)
  local guests = {}
  for _, player in ipairs(seated) do
    guests[#guests + 1] = player ~= host and player or nil
  end
  assert(guests[1].session:Accept(id))
  world:Deliver()

  -- A guest who is in can change their mind while the game hasn't begun, which calls it off
  equal(true, guests[1].session:CanForget(guests[1].matches[id]))
  assert(guests[1].session:Forget(id))
  world:Deliver()
  equal("declined", host.matches[id].status)
  equal(nil, guests[2].matches[id])

  local again = assert(host.session:Invite({ guests[1].name, guests[2].name }, "chinesecheckers"))
  world:Deliver()
  assert(guests[2].session:Accept(again.id))
  world:Deliver()
  assert(host.session:Forget(again.id))
  world:Deliver()
  equal(nil, guests[1].matches[again.id])
  equal("declined", guests[2].matches[again.id].status)
  equal(true, host.matches[again.id].hidden)
end

function tests.CrowdLostAcceptanceIsRecovered()
  local world, seated, id, host = invitedCrowd(3)
  for _, player in ipairs(seated) do
    if player ~= host then
      assert(player.session:Accept(id))
    end
  end
  -- Nothing the guests say gets through
  world:Deliver(function(message)
    return message.text:find(":ACC:") ~= nil
  end)
  equal("outgoing", host.matches[id].status)

  world:Tick(31)
  for _, player in ipairs(seated) do
    equal("!s", logOf(player, id), player.name)
  end
end

function tests.CrowdMovesReachEveryone()
  local world, seated, id = startedCrowd(3)
  for turn = 1, 9 do
    local before = #world.sent
    local player = moveSomething(world, seated, id)
    equal(seated[(turn - 1) % 3 + 1].name, player.name, "they move in turn")
    -- The move to each of the others and their word that they have it, nothing more
    equal(4, #world.sent - before, "messages for move " .. turn)
  end
  for _, player in ipairs(seated) do
    equal(logOf(seated[1], id), logOf(player, id))
    equal(10, #player.matches[id].log)
    equal(false, player.session:IsPending(player.matches[id]))
  end
  equal(1, seated[2].private.Match.Turn(seated[2].matches[id]))

  world:Tick(700)
  equal(0, #world.queue)

  -- Only the player whose turn it has become is told there is news
  equal(true, seated[1].session:NeedsAttention(seated[1].matches[id]))
  equal(false, seated[2].session:NeedsAttention(seated[2].matches[id]))
  equal(false, seated[3].session:NeedsAttention(seated[3].matches[id]))
end

function tests.CrowdPlayerWhoWasAwayCatchesUpFromWhoeverIsAround()
  local world, seated, id = startedCrowd(3)
  -- The third player is away for the first two moves, and whoever made the first is gone again
  -- by the time they are back
  seated[3].online = false
  moveSomething(world, seated, id)
  moveSomething(world, seated, id)
  seated[1].online = false
  equal("!s", logOf(seated[3], id))

  seated[3].online = true
  seated[3] = world:Relog(seated[3])
  equal(logOf(seated[2], id), logOf(seated[3], id))
  equal(3, #seated[3].matches[id].log)
  equal(3, seated[3].private.Match.Turn(seated[3].matches[id]))

  -- And what they play next reaches the one who is away now
  local player = moveSomething(world, seated, id)
  equal(seated[3].name, player.name)
  seated[1].online = true
  world:Relog(seated[1])
  equal(logOf(seated[3], id), logOf(world.players[seated[1].name], id))
end

function tests.CrowdPlayerOutOfReachAsksAroundAfterwards()
  local world, seated, id = startedCrowd(3)
  -- Someone in an instance hears nothing, and the mover logs off before a retry
  local deaf = seated[3].name
  assert(seated[1].session:Move(id, "112-103"))
  world:Deliver(function(message)
    return message.to == deaf
  end)
  seated[1].online = false
  equal("!s", logOf(seated[3], id))
  world:Tick(700)
  equal("!s", logOf(seated[3], id), "nobody who is around knows they are missing it")

  seated[3].session:Wake()
  world:Deliver()
  equal("!s,112-103", logOf(seated[3], id))
end

function tests.CrowdTakesResignationsMadeAtTheSameMoment()
  local world, seated, id = startedCrowd(4)
  local Match = seated[1].private.Match
  -- Whoever is to move moves, and two others resign, all before any of it gets anywhere
  local mover
  for _, player in ipairs(seated) do
    if Match.IsMyTurn(player.matches[id]) then
      mover = player
    end
  end
  local move = marbleMoves(mover.private.Games.Get("chinesecheckers"), Match.State(mover.matches[id]))[1]
  assert(mover.session:Move(id, move))
  local quitters = {}
  for _, player in ipairs(seated) do
    if player ~= mover and #quitters < 2 then
      assert(player.session:Resign(id))
      quitters[#quitters + 1] = player
    end
  end
  world:Deliver()

  for _, player in ipairs(seated) do
    equal(logOf(seated[1], id), logOf(player, id), player.name .. " has the same log")
    for _, quitter in ipairs(quitters) do
      equal(true, player.private.Match.IsOut(player.matches[id], quitter.matches[id].me), player.name .. " knows " .. quitter.name .. " resigned")
    end
  end
end

function tests.CrowdResyncDoesNotFloodTheNetwork()
  local world, seated, id = startedCrowd(6)
  seated[6].online = false
  for _ = 1, 20 do
    -- Five players take turns while the sixth is away: their turn is skipped by nobody, so the
    -- others can only get so far. Twenty entries is more than fits in one go
    if seated[1].private.Match.Turn(seated[1].matches[id]) == 6 then
      break
    end
    moveSomething(world, seated, id)
  end
  equal(6, #seated[1].matches[id].log)

  seated[6].online = true
  local before = #world.sent
  seated[6] = world:Relog(seated[6])
  equal(logOf(seated[1], id), logOf(seated[6], id))
  -- Asking five players, getting five entries from each and answering each of them once
  local sent = #world.sent - before
  assert(sent <= 5 + 5 * 5 + 5, "catching up took " .. sent .. " messages")
end

function tests.CrowdLongCatchUpIsAnsweredOnceAStretch()
  -- Two players pass the turn back and forth while the third sits out, with a game that lets them
  local world = World.New()
  local seated = { world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm"), world:AddPlayer("Carol-Realm") }
  local function teach(player)
    player.private.Games.Register({
      id = "counting",
      name = "Counting",
      version = 1,
      seats = { 2, 3 },
      newState = function()
        return { turn = 1, moves = 0 }
      end,
      turn = function(state)
        return state.turn
      end,
      validate = function()
        return true
      end,
      apply = function(state)
        state.moves = state.moves + 1
        -- The third player only gets a turn once the other two have had twenty each
        state.turn = state.moves >= 40 and 3 or state.turn % 2 + 1
      end,
      result = function() end,
      drop = function() end,
      createView = function() end,
    })
  end
  for _, player in ipairs(seated) do
    teach(player)
  end
  world.seed = 5
  local match = assert(seated[1].session:Invite({ "Bob-Realm", "Carol-Realm" }, "counting"))
  local id = match.id
  world:Deliver()
  local bySeat = {}
  for seat, name in ipairs(match.players) do
    bySeat[seat] = world.players[name]
  end
  for _, player in ipairs(bySeat) do
    player.session:Accept(id)
  end
  world:Deliver()

  bySeat[3].online = false
  for move = 1, 40 do
    assert(bySeat[(move - 1) % 2 + 1].session:Move(id, "m" .. move))
    world:Deliver()
  end
  equal(41, #bySeat[1].matches[id].log)

  bySeat[1].online = false
  local before = #world.sent
  local back = world:AddPlayer(bySeat[3].name, bySeat[3].matches)
  teach(back)
  back.session:Hello()
  world:Deliver()
  equal(logOf(bySeat[2], id), logOf(back, id))
  local answers = 0
  for index = before + 1, #world.sent do
    if world.sent[index]:find(back.name .. ">" .. bySeat[2].name .. " 1:ACK:", 1, true) then
      answers = answers + 1
    end
  end
  -- Forty moves after the start, in stretches of eight: each is answered once, and so is the last entry
  equal(6, answers)
end

function tests.MatchThatStandsStillChecksInWithWhoeverItWaitsFor()
  local world, alice, bob, id, first, second = startedMatch()
  play(world, id, first, second, { "5" })
  -- The player whose turn it is loses their saved games. Nothing is owed to them, so nothing is sent
  second = world:Relog(second, {})
  local before = #world.sent
  world:Tick(700)
  world:Tick(700)
  equal("active", first.matches[id].status)
  equal(0, #world.sent - before)

  world:Tick(3600)
  equal("declined", first.matches[id].status)
  equal("gone", first.matches[id].declineReason)
  equal(2, #world.sent - before, "one question, one answer")

  -- Someone who is simply taking their time is asked no more than that either
  local otherWorld, _, _, otherId, mover = startedMatch()
  play(otherWorld, otherId, mover, mover, { "5" })
  before = #otherWorld.sent
  otherWorld:Tick(3600)
  equal(2, #otherWorld.sent - before)
  otherWorld:Tick(700)
  equal(2, #otherWorld.sent - before)
  equal("active", mover.matches[otherId].status)
end

function tests.CrowdPlaysOnWhenSomeoneResigns()
  local world, seated, id = startedCrowd(3)
  moveSomething(world, seated, id)
  -- Not their turn, which doesn't matter
  assert(seated[3].session:Resign(id))
  world:Deliver()

  for _, player in ipairs(seated) do
    local match = player.matches[id]
    equal("active", match.status)
    equal(true, player.private.Match.IsOut(match, 3))
    equal(2, player.private.Match.Turn(match))
    local marbles = 0
    for _ in pairs(player.private.Match.State(match).board) do
      marbles = marbles + 1
    end
    equal(20, marbles, "their marbles come off the board")
  end
  equal(false, seated[3].session:Resign(id), "only once")
  equal(false, seated[3].session:NeedsAttention(seated[3].matches[id]))

  -- The two who are left take turns, and the one who resigned still sees how it goes
  equal(seated[2].name, moveSomething(world, seated, id).name)
  equal(seated[1].name, moveSomething(world, seated, id).name)
  equal(seated[2].name, moveSomething(world, seated, id).name)
  equal(logOf(seated[1], id), logOf(seated[3], id))

  assert(seated[1].session:Resign(id))
  world:Deliver()
  for _, player in ipairs(seated) do
    equal("finished", player.matches[id].status)
    equal(2, player.private.Match.Result(player.matches[id]).winner)
    equal("resign", player.private.Match.Result(player.matches[id]).reason)
  end
end

function tests.CrowdForgetsAPlayerWhoRemovedTheMatch()
  local world, seated, id = startedCrowd(3)
  moveSomething(world, seated, id)
  assert(seated[3].session:Resign(id))
  world:Deliver()
  equal(true, seated[3].session:CanForget(seated[3].matches[id]))
  equal(false, seated[1].session:CanForget(seated[1].matches[id]))
  equal("match_in_progress", select(2, seated[1].session:Forget(id)))
  assert(seated[3].session:Forget(id))
  equal(nil, seated[3].matches[id])

  -- Each of the others finds out the next time they send them something, and that is the last
  moveSomething(world, seated, id)
  equal(true, seated[2].matches[id].gone[3])
  moveSomething(world, seated, id)
  equal(true, seated[1].matches[id].gone[3])
  local before = #world.sent
  moveSomething(world, seated, id)
  moveSomething(world, seated, id)
  for index = before + 1, #world.sent do
    assert(not world.sent[index]:find(seated[3].name, 1, true), "still talking to them: " .. world.sent[index])
  end
  world:Tick(700)
  equal(0, #world.queue)
  equal(logOf(seated[1], id), logOf(seated[2], id))
end

function tests.CrowdPlayerWhoLostTheMatchIsOutOfIt()
  local world, seated, id = startedCrowd(3)
  moveSomething(world, seated, id)
  -- The second player's saved games are gone, with their turn coming up
  seated[2] = world:Relog(seated[2], {})
  world:Tick(700)
  equal(false, seated[1].private.Match.IsOut(seated[1].matches[id], 2), "nobody knows yet")
  -- A game that stands still for long enough asks whoever it is waiting for
  world:Tick(3600)
  equal(seated[3].name, moveSomething(world, seated, id).name)

  for _, seat in ipairs({ 1, 3 }) do
    local match = seated[seat].matches[id]
    equal("active", match.status)
    equal(true, seated[seat].private.Match.IsOut(match, 2))
    equal(logOf(seated[1], id), logOf(seated[seat], id))
  end
  world:Tick(700)
  equal(0, #world.queue)
end

function tests.CrowdSimultaneousResignAndMoveConverge()
  local world, seated, id = startedCrowd(3)
  -- The first player moves in the same moment the third resigns
  assert(seated[1].session:Move(id, "112-103"))
  assert(seated[3].session:Resign(id))
  world:Deliver()
  world:Tick(31)
  world:Tick(61)

  local log = logOf(seated[1], id)
  for _, player in ipairs(seated) do
    equal(log, logOf(player, id), player.name)
    equal(false, player.session:IsPending(player.matches[id]))
  end
  -- Neither of the two was lost for good: one of them just has to be done again
  assert(log == "!s,112-103,!r3" or log == "!s,!r3", log)
end

function tests.CrowdTooBigForOneMessageIsToldInSeveral()
  local world = World.New()
  local names = { "Alice-Realm" }
  for index = 2, 6 do
    -- As long as names get, on a realm with a long name
    names[index] = string.rep(string.char(96 + index), 12) .. " Tøø-TheVeryLongestRealmNameThereCouldPossiblyEverBe"
  end
  local players = {}
  for index, name in ipairs(names) do
    players[index] = world:AddPlayer(name)
  end
  local match = assert(players[1].session:Invite({ unpack(names, 2) }, "chinesecheckers"))
  local longest = 0
  for _, message in ipairs(world.queue) do
    longest = math.max(longest, #message.text)
  end
  assert(longest <= 255, "a message of " .. longest .. " bytes")
  assert(#world.queue > 5, "expected the players to be told in more than one message each")
  world:Deliver()

  for index = 2, 6 do
    local theirs = players[index].matches[match.id]
    equal("incoming", theirs.status)
    equal(table.concat(match.players, "|"), table.concat(theirs.players, "|"))
    assert(players[index].session:Accept(match.id))
  end
  world:Deliver()
  equal("!s", logOf(players[4], match.id))
end

function tests.MatchesSavedBeforeThereWereCrowdsStillWork()
  local world, alice, bob, id, first, second = startedMatch()
  play(world, id, first, second, { "5", "1" })
  -- The way a match was saved when there was only ever one opponent
  local saved = copy(bob.matches)
  saved[id].peerSeen, saved[id].seen = 2, nil
  bob = world:Relog(bob, saved)
  equal(nil, bob.matches[id].peerSeen)
  equal(2, bob.matches[id].seen[bob.matches[id].me == 1 and 2 or 1])
  equal(false, bob.session:IsPending(bob.matches[id]))

  alice = world.players["Alice-Realm"]
  local mover = first.name == "Bob-Realm" and bob or alice
  assert(mover.session:Move(id, "9"))
  world:Deliver()
  equal("5,1,9", logOf(alice, id))
  equal("5,1,9", logOf(bob, id))
end

-----------------------------
-- Chinese Checkers
-----------------------------

function tests.ChineseCheckersStartsWithTenMarblesEach()
  local game = loadEngine().Games.Get("chinesecheckers")
  for _, seats in ipairs({ 2, 3, 4, 6 }) do
    local state = game.newState(seats)
    local marbles = {}
    for hole, seat in pairs(state.board) do
      assert(hole >= 1 and hole <= 121, "hole " .. hole)
      marbles[seat] = (marbles[seat] or 0) + 1
    end
    equal(seats, #marbles)
    for seat = 1, seats do
      equal(10, marbles[seat], "marbles of seat " .. seat .. " of " .. seats)
    end
  end

  -- The first player's point is the bottom one, across from the top
  local state = game.newState(2)
  for hole = 112, 121 do
    equal(1, state.board[hole])
  end
  for hole = 1, 10 do
    equal(2, state.board[hole])
  end
  equal("Red", ({ chinesecheckers_red = "Red" })[game.seatLabel(1, 2)])
  equal("chinesecheckers_blue", game.seatLabel(2, 2))
  equal("chinesecheckers_green", game.seatLabel(2, 3))
  equal("chinesecheckers_yellow", game.seatLabel(2, 6))
end

function tests.ChineseCheckersOpensWithFourteenMoves()
  local game = loadEngine().Games.Get("chinesecheckers")
  local moves = marbleMoves(game, game.newState(2))
  -- The front row steps forward either way, the row behind it hops over it either way
  local steps = "112-103,112-104,113-104,113-105,114-105,114-106,115-106,115-107"
  local hops = "116-103,116-105,117-104,117-106,118-105,118-107"
  equal(steps .. "," .. hops, table.concat(moves, ","))
  for _, seats in ipairs({ 3, 4, 6 }) do
    equal(14, #marbleMoves(game, game.newState(seats)), "with " .. seats)
  end
  equal(false, (game.validate(game.newState(2), 2, "7-16")), "not out of turn")
  equal(false, (game.validate(game.newState(2), 1, "7-16")), "not someone else's marble")
  equal(false, (game.validate(game.newState(2), 1, "121-103")), "not just anywhere")
  equal(false, (game.validate(game.newState(2), 1, "nonsense")))
end

function tests.ChineseCheckersHopsGoOnAsLongAsThereIsSomethingToHopOver()
  local game = loadEngine().Games.Get("chinesecheckers")
  local state = game.newState(2)
  -- A lone marble with stepping stones leading up the middle of the board, two rows apart
  state.board = { [117] = 1, [113] = 1, [91] = 2, [1] = 2 }
  local moves = table.concat(marbleMoves(game, state), ",")
  assert(moves:find("117-104", 1, true), "over one: " .. moves)
  assert(moves:find("117-79", 1, true), "and on over the next: " .. moves)

  local event = game.apply(state, 1, "117-79")
  equal("117,104,79", table.concat(event.path, ","))
  equal(1, state.board[79])
  equal(nil, state.board[117])
  equal(1, state.board[113], "nothing is ever taken")
  equal(2, state.board[91])
  equal(2, state.turn)
end

function tests.ChineseCheckersMarbleThatArrivedStaysThere()
  local game = loadEngine().Games.Get("chinesecheckers")
  local state = game.newState(2)
  -- One marble in the front row of the point it is headed for, the rest of the point empty
  state.board = { [8] = 1, [121] = 1, [60] = 2 }
  for _, move in ipairs(marbleMoves(game, state)) do
    local from, to = move:match("(%d+)%-(%d+)")
    if from == "8" then
      assert(tonumber(to) <= 10, "left the point with " .. move)
    end
  end
  equal(true, (game.validate(state, 1, "8-4")))
  equal(false, (game.validate(state, 1, "8-17")))
end

function tests.ChineseCheckersIsWonByFillingThePointAcross()
  local game = loadEngine().Games.Get("chinesecheckers")
  local state = game.newState(2)
  -- Nine of the first player's marbles are home, one hole is left to fill
  state.board = { [112] = 2, [16] = 1 }
  for hole = 1, 10 do
    state.board[hole] = hole ~= 7 and 1 or nil
  end
  equal(nil, game.result(state))
  game.apply(state, 1, "16-7")
  equal(1, game.result(state).winner)

  -- A marble someone left behind in the point doesn't keep it from being won
  state = game.newState(2)
  state.board = { [112] = 2, [16] = 1 }
  for hole = 1, 10 do
    state.board[hole] = hole ~= 7 and (hole == 1 and 2 or 1) or nil
  end
  game.apply(state, 1, "16-7")
  equal(1, game.result(state).winner)

  -- But it takes a marble of their own
  state = game.newState(2)
  equal(nil, game.result(state), "the point starts out full of the other player's")
end

function tests.ChineseCheckersGoesRoundTheTable()
  local game = loadEngine().Games.Get("chinesecheckers")
  local state = game.newState(4)
  local order = {}
  for _ = 1, 6 do
    order[#order + 1] = state.turn
    game.apply(state, state.turn, marbleMoves(game, state)[1])
  end
  equal("1,2,3,4,1,2", table.concat(order, ","))

  -- Whoever resigns is passed over from then on, and it moves on if it was their turn
  equal(3, state.turn)
  game.drop(state, 3)
  equal(4, state.turn)
  game.drop(state, 1)
  game.apply(state, 4, marbleMoves(game, state)[1])
  equal(2, state.turn)
  game.apply(state, 2, marbleMoves(game, state)[1])
  equal(4, state.turn)
end

function tests.ChineseCheckersMatchBetweenThreePlayers()
  local world, seated, id = startedCrowd(3)
  -- Played until the first player only has to step into the last hole of the point across
  for _, player in ipairs(seated) do
    local state = player.private.Match.State(player.matches[id])
    for hole, seat in pairs(state.board) do
      if seat == 1 then
        state.board[hole] = nil
      end
    end
    for hole = 1, 10 do
      state.board[hole] = hole ~= 7 and 1 or nil
    end
    state.board[16] = 1
  end
  assert(seated[1].session:Move(id, "16-7"))
  world:Deliver()
  for _, player in ipairs(seated) do
    equal("finished", player.matches[id].status)
    equal(1, player.private.Match.Result(player.matches[id]).winner)
    equal("win", player.private.Match.Result(player.matches[id]).reason)
  end
  equal("finished:" .. id, seated[2].events[#seated[2].events])
end

-----------------------------
-- More than two players, in the window
-----------------------------

-- The same star the game lays out, to find its holes on screen with
local STAR_REACH, STAR_ROW = 8.6, math.sqrt(3) / 2
local starHoles = {}
for z = -8, 8 do
  for x = -8, 8 do
    local y = -x - z
    if math.min(x, y, z) >= -4 or math.max(x, y, z) <= 4 then
      starHoles[#starHoles + 1] = { x, z }
    end
  end
end

--- Moves the cursor onto a hole of the star
--- @param board table
--- @param hole number
--- @param point number The point that is at the bottom
local function pointAtHole(board, hole, point)
  local x, z = starHoles[hole][1], starHoles[hole][2]
  for _ = 1, point do
    x, z = x + z, -x
  end
  local cell = board.height / (2 * STAR_REACH)
  Client.cursor = { (STAR_REACH * STAR_ROW + x + z / 2) * cell, board.height - (STAR_REACH + z * STAR_ROW) * cell }
end

local function clickHole(board, hole, point)
  pointAtHole(board, hole, point)
  board:Fire("OnUpdate", 0.02)
  press(board)
  release(board)
end

--- What the window says about the game on screen
--- @param text string
--- @return boolean
local function says(text)
  return #Client.Find(function(widget)
    return widget.text == text and widget:IsVisible()
  end) > 0
end

function tests.WindowPlaysChineseCheckers()
  local world, seated, id = startedCrowd(3)
  local MainFrame = openWindow(seated[1])
  MainFrame.Open(id)
  local board = shownBoard()
  assert(board.height >= 17 * 20, "the star should make use of the window, got " .. board.height)
  equal(true, says("status_your_turn"))
  equal(true, says("chinesecheckers_you"))
  equal(true, says(seated[2].name))
  equal(true, says(seated[3].name))

  -- Pick a marble up, then where it goes: a hop over the row in front
  clickHole(board, 117, 0)
  equal("!s", logOf(seated[1], id), "picking a marble up isn't a move")
  clickHole(board, 104, 0)
  equal("!s,117-104", logOf(seated[1], id))
  equal("IG_ABILITY_ICON_DROP", Client.sounds[#Client.sounds])
  settle(board)
  equal(true, says("status_their_turn"))

  -- Not while it is someone else's turn
  clickHole(board, 112, 0)
  clickHole(board, 103, 0)
  equal("!s,117-104", logOf(seated[1], id))

  world:Deliver()
  moveSomething(world, seated, id)
  equal(true, says("status_their_turn"), "the third player is next, not us")
  moveSomething(world, seated, id)
  equal(true, says("status_your_turn"))

  -- Dragged
  pointAtHole(board, 112, 0)
  board:Fire("OnUpdate", 0.02)
  press(board)
  board:Fire("OnUpdate", 0.02)
  pointAtHole(board, 103, 0)
  board:Fire("OnUpdate", 0.02)
  release(board)
  equal("112-103", seated[1].matches[id].log[5])
end

function tests.WindowTurnsTheStarToFaceEachPlayer()
  local world, seated, id = startedCrowd(3)
  moveSomething(world, seated, id)
  local MainFrame = openWindow(seated[2])
  MainFrame.Open(id)
  local board = shownBoard()
  local state = seated[2].private.Match.State(seated[2].matches[id])
  local move = marbleMoves(seated[2].private.Games.Get("chinesecheckers"), state)[1]
  local from, to = move:match("(%d+)%-(%d+)")

  -- Their point is the second one round the board, and for them it is at the bottom
  pointAtHole(board, tonumber(from), 2)
  local low = Client.cursor[2]
  assert(low < board.height / 3, "their marbles should be at the bottom, got " .. low .. " of " .. board.height)
  clickHole(board, tonumber(from), 2)
  clickHole(board, tonumber(to), 2)
  equal(move, seated[2].matches[id].log[3])
  equal(true, says("you_are"))
end

function tests.WindowShowsACrowdGathering()
  local world, seated, id, host = invitedCrowd(3)
  local guests = {}
  for _, player in ipairs(seated) do
    guests[#guests + 1] = player ~= host and player or nil
  end
  local MainFrame = openWindow(guests[1])
  MainFrame.Open(id)
  equal(true, says("status_incoming"))
  equal(true, says("with_players"))

  Client.Button("accept"):Fire("OnClick")
  world:Deliver()
  equal("active", guests[1].matches[id].status)
  -- In, with the others still to answer: nothing to play and nothing to resign from
  equal(2, #Client.Find(function(widget)
    return widget.text == "status_gathering" and widget:IsVisible()
  end), "said under the title and where the board will be")
  equal(0, #Client.Find(function(widget)
    return widget.scripts.OnMouseDown and widget.scripts.OnUpdate and widget:IsVisible()
  end), "no board yet")
  Client.Button("leave")

  assert(guests[2].session:Accept(id))
  world:Deliver()
  shownBoard()
  Client.Button("resign")

  -- Resigned, they can watch the others play on or take the game off their list
  assert(guests[1].session:Resign(id))
  world:Deliver()
  equal(true, says("status_you_left"))
  Client.Button("remove"):Fire("OnClick")
  equal(nil, guests[1].matches[id])
end

function tests.WizardPicksSeveralPlayersForACrowd()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  openWizard(alice)
  function alice.private.presence:List()
    local list = {}
    for index, name in ipairs({ "Bob-Realm", "Carol-Realm", "Dave-Realm" }) do
      list[index] = { name = name, source = "friend" }
    end
    return list
  end
  for _, card in ipairs(Client.Find(function(widget)
    return widget.kind == "Button" and widget.game ~= nil and widget.game.id == "chinesecheckers" and widget:IsVisible()
  end)) do
    equal("players_choice", card.players.text, "the count, and no more")
    equal(true, card.computer:IsShown(), "that the computer plays it is a cog")
    card:Fire("OnClick")
  end

  local function row(name)
    return Client.Find(function(widget)
      return widget.kind == "Button" and widget.player == name and widget.source ~= nil and widget:IsVisible()
    end)[1]
  end
  local send = Client.Button("wizard_send")
  equal(false, send.enabled)

  row("Bob-Realm"):Fire("OnClick")
  equal(true, send.enabled, "two can play")
  row("Carol-Realm"):Fire("OnClick")
  equal(true, send.enabled, "so can three")
  row("Dave-Realm"):Fire("OnClick")
  equal(true, send.enabled)

  -- Someone who isn't on the list, by name. That makes five, which the game isn't for
  local name = Client.Find(function(widget)
    return widget.kind == "EditBox" and widget.scripts.OnTextChanged and widget:IsVisible()
  end)[1]
  name:SetText("Erin-Realm")
  name:Fire("OnTextChanged", true)
  equal(false, send.enabled)
  name:Fire("OnEnterPressed")
  equal("", name:GetText())
  equal(false, send.enabled)
  equal(nil, next(alice.matches), "Enter adds a player, it doesn't send")

  -- Clicking a player again takes them out
  row("Dave-Realm"):Fire("OnClick")
  equal(true, send.enabled)
  send:Fire("OnClick")
  local started
  for _, match in pairs(alice.matches) do
    started = match
  end
  equal("chinesecheckers", started.game)
  local playing = { unpack(started.players) }
  table.sort(playing)
  equal("Alice-Realm,Bob-Realm,Carol-Realm,Erin-Realm", table.concat(playing, ","))
end

-----------------------------
-- Chance
-----------------------------

--- @param random table
--- @param count number
--- @param sides number
--- @return string The rolls, run together
local function rollsOf(random, count, sides)
  local rolls = {}
  for index = 1, count do
    rolls[index] = random:Roll(sides)
  end
  return table.concat(rolls)
end

function tests.ChanceIsTheSameForEveryone()
  local Random = loadEngine().Random
  local seed = Random.Seed("f4240000001")
  equal(rollsOf(Random.New(seed), 30, 6), rollsOf(Random.New(seed), 30, 6))
  -- Written down, so that a change to how numbers are made doesn't go unnoticed: two versions
  -- of the addon that roll differently can't play each other
  equal("263263412322", rollsOf(Random.New(seed), 12, 6))

  assert(rollsOf(Random.New(Random.Seed("f4240000002")), 30, 6) ~= rollsOf(Random.New(seed), 30, 6), "another match, other dice")
  assert(Random.Stir(seed, "24-18.13-11") ~= Random.Stir(seed, "24-18.13-10"), "every move stirs it")
  assert(Random.Stir(Random.Stir(seed, "a"), "b") ~= Random.Stir(Random.Stir(seed, "b"), "a"), "in the order they were made")
  assert(Random.Stir(Random.Stir(seed, "a"), "b") ~= Random.Stir(seed, "ab"))
  equal(Random.Stir(seed, "13-7.8-7"), Random.Stir(seed, "13-7.8-7"))
end

function tests.ChanceIsEven()
  local Random = loadEngine().Random
  --- @param counts number[]
  --- @param expected number
  --- @param label string
  local function even(counts, expected, label)
    for value, count in ipairs(counts) do
      local close = math.abs(count - expected) < expected * 0.12
      assert(close, label .. ": " .. value .. " came up " .. count .. " times, not about " .. expected)
    end
  end

  -- A long run of rolls
  local faces, doubles = { 0, 0, 0, 0, 0, 0 }, 0
  local random = Random.New(42)
  for _ = 1, 6000 do
    local first, second = random:Roll(6), random:Roll(6)
    faces[first], faces[second] = faces[first] + 1, faces[second] + 1
    doubles = doubles + (first == second and 1 or 0)
  end
  even(faces, 2000, "one after the other")
  even({ doubles }, 1000, "doubles")

  -- The first roll after each of a run of moves that are almost the same, which is how a game uses it
  faces = { 0, 0, 0, 0, 0, 0 }
  local seed = Random.Seed("abc")
  for move = 1, 6000 do
    local face = Random.New(Random.Stir(seed, "13-" .. move)):Roll(6)
    faces[face] = faces[face] + 1
  end
  even(faces, 1000, "move by move")

  -- Seeds next to each other
  faces = { 0, 0, 0, 0, 0, 0 }
  for neighbour = 0, 5999 do
    local face = Random.New(neighbour):Roll(6)
    faces[face] = faces[face] + 1
  end
  even(faces, 1000, "seed by seed")

  -- A shuffle keeps every card and puts each of them anywhere
  local first = { 0, 0, 0, 0, 0 }
  for deal = 1, 5000 do
    local cards = Random.New(deal):Shuffle({ 1, 2, 3, 4, 5 })
    first[cards[1]] = first[cards[1]] + 1
    table.sort(cards)
    equal("12345", table.concat(cards))
  end
  even(first, 1000, "shuffled")
end

-----------------------------
-- Backgammon
-----------------------------

--- A position set up by hand. Points are counted the way each player counts their own
--- @param white table Checkers by point, with `bar` and `off`
--- @param red table
--- @param turn number
--- @param dice number[] Higher first
--- @return table state, table game, table random
local function backgammonAt(white, red, turn, dice)
  local private = loadEngine()
  local game = private.Games.Get("backgammon")
  local state = game.newState(2, private.Random.New(1))
  for seat, placed in ipairs({ white, red }) do
    for point = 1, 24 do
      state.points[seat][point] = placed[point] or 0
    end
    state.bar[seat], state.off[seat] = placed.bar or 0, placed.off or 0
  end
  state.turn, state.dice = turn, dice
  game.rules.assess(state)
  return state, game, private.Random.New(7)
end

--- The start of the game with a roll of the test's choosing, white to play
--- @param dice number[]
--- @return table state, table game, table random
local function backgammonStart(dice)
  local start = { [24] = 2, [13] = 5, [8] = 3, [6] = 5 }
  return backgammonAt(start, start, 1, dice)
end

--- A whole turn for whoever is to move: the first step there is, until the roll is played
--- @param game table
--- @param state table
--- @param choose (fun(count: number): number)? Which of the steps on offer to take, the first if left out
--- @return string move
local function backgammonTurn(game, state, choose)
  local steps = {}
  while true do
    local offered = {}
    for from, targets in pairs(game.rules.continuations(state, steps)) do
      for to in pairs(targets) do
        offered[#offered + 1] = { from = from, to = to }
      end
    end
    if #offered == 0 then
      break
    end
    table.sort(offered, function(a, b)
      if a.from ~= b.from then
        return a.from > b.from
      end
      return a.to > b.to
    end)
    steps[#steps + 1] = offered[choose and choose(#offered) or 1]
  end
  local parts = {}
  for index, step in ipairs(steps) do
    parts[index] = step.from .. "-" .. step.to
  end
  return table.concat(parts, ".")
end

function tests.TablesCopyIsWholeAndKeepsWhatIsShared()
  local Tables = loadEngine().Tables
  local shared = { 1, 2 }
  local under = { looked = 3 }
  local original = { a = shared, b = shared, nested = { deep = { "x" } }, over = setmetatable({}, { __index = under }), n = 5 }
  original.self = original
  local copied = Tables.Copy(original)
  assert(copied ~= original and copied.nested ~= original.nested and copied.nested.deep ~= original.nested.deep)
  equal("x", copied.nested.deep[1])
  equal(copied.a, copied.b, "what was shared still is")
  assert(copied.a ~= shared, "but it is a copy of its own")
  equal(copied, copied.self, "and a table in itself is too")
  equal(3, copied.over.looked, "a table that read through to another still does")
  equal(7, Tables.Copy(7))
  copied.nested.deep[1] = "y"
  equal("x", original.nested.deep[1], "the original isn't touched")

  local shallow = Tables.Shallow(original)
  assert(shallow ~= original)
  equal(original.nested, shallow.nested, "a shallow copy shares the tables in it")
end

function tests.GridNumbersSquaresTheWayTheBoardDrawsThem()
  local Grid = loadEngine().Grid
  local board = Grid.New(8)
  equal(board, Grid.New(8, 8), "one board of a size")
  equal(64, board.squares)
  equal("a1", board:Name(0))
  equal("h1", board:Name(7))
  equal("a2", board:Name(8))
  equal("h8", board:Name(63))
  for square = 0, 63 do
    equal(square, board:Parse(board:Name(square)))
  end
  for _, wrong in ipairs({ "i1", "a9", "a0", "a01", "A1", "a", "", "a1 " }) do
    equal(nil, board:Parse(wrong), wrong)
  end
  local sea = Grid.New(10)
  equal(99, sea:Parse("j10"))
  equal(nil, sea:Parse("j11"))
  equal(nil, sea:Parse("k1"))

  local wide = Grid.New(7, 6)
  equal(41, wide.squares - 1)
  equal(nil, wide:Square(7, 0))
  equal(nil, wide:Square(0, 6))
  equal(15, wide:Square(1, 2))
  local column, row = wide:Coordinates(15)
  equal("1,2", column .. "," .. row)
  equal(16, wide:Step(15, 1, 0))
  equal(nil, wide:Step(13, 1, 0), "a step off the right edge doesn't come back on the left")
  equal(nil, wide:Step(0, -1, 0))
  equal(3, wide:Distance(0, wide:Square(3, 2)))
end

function tests.GridLinesAndWhatIsAround()
  local Grid = loadEngine().Grid
  local board = Grid.New(8)
  equal("1,2,3,4,5,6,7", table.concat(board:Ray(0, 1, 0), ","))
  equal("9,18,27,36,45,54,63", table.concat(board:Ray(0, 1, 1), ","))
  equal("", table.concat(board:Ray(7, 1, 0), ","), "nothing past the edge")
  equal(board:Ray(0, 1, 0), board:Ray(0, 1, 0), "worked out once")
  local rays = board:Rays(27, Grid.AROUND)
  equal(8, #rays)
  equal(board:Ray(27, -1, -1), rays[8])

  local corner = board:Around(0, Grid.AROUND)
  table.sort(corner)
  equal("1,8,9", table.concat(corner, ","))
  local jumps = board:Around(0, Grid.KNIGHT)
  table.sort(jumps)
  equal("10,17", table.concat(jumps, ","))
  equal(8, #board:Around(27, Grid.AROUND))

  -- Four in a row on a Connect Four rack, and the longest line through a square
  local rack = Grid.New(7, 6)
  equal(69, #rack:Windows(4, Grid.LINES))
  local discs = { [0] = true, [8] = true, [16] = true, [24] = true, [1] = true }
  local line = rack:Line(16, Grid.LINES, function(square)
    return discs[square] == true
  end, 4)
  table.sort(line)
  equal("0,8,16,24", table.concat(line, ","))
  equal(nil, rack:Line(1, Grid.LINES, function(square)
    return discs[square] == true
  end, 4), "two in a row isn't four")

  -- Spreading out from a square over the empty ones, the way Minesweeper opens a field
  local small = Grid.New(4)
  local walls = { [2] = true, [6] = true, [10] = true, [14] = true }
  local depths = {}
  local reached = Grid.Spread({ 0 }, function(square, depth)
    depths[square] = depth
    local onward = {}
    for _, other in ipairs(small:Around(square, Grid.STRAIGHT)) do
      if not walls[other] then
        onward[#onward + 1] = other
      end
    end
    return onward
  end)
  equal(8, #reached, "only the two columns this side of the wall")
  equal(0, reached[1])
  equal(4, depths[13], "the far corner is four steps away")
  for index = 2, #reached do
    assert(depths[reached[index]] >= depths[reached[index - 1]], "nearest first")
  end
end

function tests.DeckIsTheSameDealEverywhere()
  local private = loadEngine()
  local Deck, Random = private.Deck, private.Random
  local deck = Deck.New()
  equal(52, #deck)
  equal("AS", deck[1])
  equal("KC", deck[52])
  local seen = {}
  for _, card in ipairs(deck) do
    assert(Deck.IsCard(card), card)
    assert(not seen[card], "once each")
    seen[card] = true
  end
  -- Written down: a deck that comes out in another order deals every old match differently
  local shuffled = Deck.Shuffled(Random.New(Random.Seed("f4240000001")))
  equal("KD,6S,5S,4S,QD", table.concat({ unpack(shuffled, 1, 5) }, ","))

  local hands, top = { {}, {}, {} }, { unpack(shuffled) }
  Deck.Deal(shuffled, hands, 2)
  equal(46, #shuffled)
  equal(2, #hands[3])
  equal(top[52] .. "," .. top[49], hands[1][1] .. "," .. hands[1][2], "one each from the top, and round again")

  equal(1, Deck.Rank("AS"))
  equal(13, Deck.Rank("KD"))
  equal(13, Deck.Rank("AS", Deck.ACE_HIGH))
  equal(true, Deck.IsRed("TD"))
  equal(false, Deck.IsRed("TC"))
  equal(false, Deck.IsCard("1S"))
  equal(false, Deck.IsCard(Deck.HIDDEN))
  equal("?,?,?", table.concat(Deck.Backs(3), ","))
  equal(2, Deck.Find({ "AS", "QH" }, "QH"))
  equal(nil, Deck.Find({ "AS" }, "QH"))
  equal(49, #Deck.Unseen({ "AS", "QH" }, { "KC" }))
  equal("AS,9S,TH,2D,KD", table.concat(Deck.Sort({ "KD", "TH", "AS", "2D", "9S" }), ","))
end

function tests.DeckSaysWhoTakesATrick()
  local Deck = loadEngine().Deck
  local hand = { "2H", "KS", "AH", "5C" }
  equal(4, #Deck.Playable(hand, {}), "anything to lead")
  equal("2H,AH", table.concat(Deck.Playable(hand, { "9H" }), ","), "the suit led if there is one")
  equal(4, #Deck.Playable(hand, { "9D" }), "anything with none of it")

  equal(3, Deck.Winner({ "9H", "2S", "AH", "KH" }), "the ace is high")
  equal(1, Deck.Winner({ "9H", "AS", "AD" }), "off suit takes nothing")
  equal(2, Deck.Winner({ "9H", "2S", "AH" }, { trump = "S" }), "a trump takes it")
  equal(3, Deck.Winner({ "9H", "2S", "3S" }, { trump = "S" }), "the higher trump")

  -- Euchre: the jack of trump is the best card there is, and the other jack of its colour is a
  -- trump too, the second best
  local function suitOf(card, trump)
    local partner = { S = "C", C = "S", H = "D", D = "H" }
    if card:sub(1, 1) == "J" and card:sub(2, 2) == partner[trump] then
      return trump
    end
    return card:sub(2, 2)
  end
  local function rankOf(card, trump)
    if card:sub(1, 1) == "J" then
      return card:sub(2, 2) == trump and 20 or (suitOf(card, trump) == trump and 19 or Deck.Rank(card, Deck.ACE_HIGH))
    end
    return Deck.Rank(card, Deck.ACE_HIGH)
  end
  local euchre = { trump = "H", suitOf = suitOf, rankOf = rankOf }
  equal(3, Deck.Winner({ "AH", "KH", "JD" }, euchre), "the left bower beats the ace of trump")
  equal(2, Deck.Winner({ "JD", "JH" }, euchre), "the right bower beats the left")
  equal("JD", Deck.Playable({ "JD", "AD" }, { "9H" }, euchre)[1], "the left bower follows trump")
  equal(1, #Deck.Playable({ "JD", "AD" }, { "9H" }, euchre), "and isn't a diamond")
end

function tests.PhasesKeepTheRoomsClock()
  local Phases = loadEngine().Phases
  local state = { phase = "idle" }
  Phases.Begin(state, "ask", 100, 15)
  equal("ask", state.phase)
  equal(15, Phases.Left(state, 100))
  equal(5, Phases.Left(state, 110))
  equal(0, Phases.Left(state, 200))
  equal(false, Phases.Due(state, 114))
  equal(true, Phases.Due(state, 115))
  equal(false, Phases.Due(state, 116, 2), "given a little longer for what is on its way")
  equal(10, Phases.Ago(state, 110.7))

  -- Somebody told late runs out with everyone else
  local late = { phase = "idle" }
  Phases.Begin(late, "ask", 500, 15, 10)
  equal(5, Phases.Left(late, 500))

  Phases.Begin(state, "held", 120)
  equal(nil, Phases.Left(state, 120), "waits for as long as it takes")
  equal(false, Phases.Due(state, 1000))
  Phases.Until(state, 130, 5)
  equal(true, Phases.Due(state, 135))
  Phases.Until(state, 130, nil)
  equal(false, Phases.Due(state, 135))

  equal(1000, Phases.Points(0, 10, 1000, 500))
  equal(750, Phases.Points(5, 10, 1000, 500))
  equal(500, Phases.Points(60, 10, 1000, 500))
end

--- What a match looks like, everything in it written out in order, to compare two of them
--- @param value any
--- @return string
local function written(value)
  if type(value) ~= "table" then
    return tostring(value)
  end
  local keys = {}
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = tostring(key) .. "=" .. written(value[key])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

function tests.DailyChallengeIsDealtTheSameForEveryone()
  local world = World.New()
  local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  local Match, Theirs = alice.private.Match, bob.private.Match
  local mine = assert(alice.session:Daily("solitaire"))
  local theirs = assert(bob.session:Daily("solitaire"))
  assert(mine.id ~= theirs.id, "each their own match")
  equal("2026-10-14", mine.daily)
  equal(written(Match.State(mine)), written(Theirs.State(theirs)), "the same deal")
  local other = assert(alice.session:Invite({}, "solitaire"))
  assert(written(Match.State(other)) ~= written(Match.State(mine)), "a game of their own is dealt as ever")
  local minesweeper = assert(alice.session:Daily("minesweeper"))
  equal("intermediate", Match.State(minesweeper).level, "played by the day's rules")
  equal(mine, alice.session:Daily("solitaire"), "the one go, gone back to")

  -- The same moves turn up the same cards
  for _ = 1, 3 do
    assert(alice.session:Move(mine.id, "d"))
    assert(bob.session:Move(theirs.id, "d"))
  end
  equal(written(Match.State(mine)), written(Theirs.State(theirs)))
  equal(false, alice.session:CanUndo(mine), "nothing is taken back")
  assert(alice.session:Move(other.id, "d"))
  equal(true, alice.session:CanUndo(other), "as a game of their own can")
  equal(false, (alice.session:Forget(mine.id)), "or thrown away while it is on")
  equal(nil, mine.score)

  -- Given up, it counts for what it came to
  local scored = {}
  alice.onEvent = function(event, match)
    if event == "daily" then
      scored[#scored + 1] = match.score
    end
  end
  assert(alice.session:Resign(mine.id))
  equal("finished", mine.status)
  equal(Match.State(mine).score, mine.score)
  equal(1, #scored, "said the once")
  assert(alice.session:Forget(mine.id))
  local again, err = alice.session:Daily("solitaire")
  equal(nil, again, "one go a day")
  equal("daily_played", err)
  equal(true, alice.session:PlayedToday("solitaire"))

  -- Tomorrow is another deal
  world.today = "2026-10-15"
  local tomorrow = assert(alice.session:Daily("solitaire"))
  assert(written(Match.State(tomorrow)) ~= written(Theirs.State(theirs)))
  equal(nil, (alice.session:Daily("chess")), "only a game for one is the day's challenge")
end

function tests.DailyChallengeWithNothingToShowForIt()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local match = assert(alice.session:Daily("minesweeper"))
  assert(alice.session:Resign(match.id))
  equal(false, match.score, "a field that wasn't cleared has no time")
end

--- Players on a guild channel, each with the board of the day's challenges
--- @param names string[]
--- @return table<string, table> boards By name, with `sent` for what each said
local function dailyGuild(names)
  local boards, clock = {}, { now = 5000 }
  for _, name in ipairs(names) do
    local private = loadEngine()
    local player = { name = name, changes = 0 }
    player.board = private.Daily.New({
      me = name,
      now = function()
        return clock.now
      end,
      today = function()
        return "2026-10-14"
      end,
      broadcast = function(text)
        for other, them in pairs(boards) do
          if other ~= name and not them.away then
            them.board:Handle(name, text)
          end
        end
      end,
      whisper = function(target, text)
        if not boards[target].away then
          boards[target].board:Handle(name, text)
        end
      end,
      onChange = function()
        player.changes = player.changes + 1
      end,
    })
    boards[name] = player
  end
  return boards, clock
end

function tests.DailyBoardGoesRoundTheGuild()
  local guild, clock = dailyGuild({ "Alice", "Bob", "Carol", "Dan", "Erin" })
  local alice, bob, carol, dan = guild.Alice.board, guild.Bob.board, guild.Carol.board, guild.Dan.board
  local erin = guild.Erin
  erin.away = true
  alice:Post("2026-10-14", "minesweeper", 95)
  bob:Post("2026-10-14", "minesweeper", 80)
  carol:Post("2026-10-14", "minesweeper", false)
  carol:Post("2026-10-14", "2048", 3000)

  local board = dan:Board("2026-10-14", "minesweeper")
  equal(3, #board)
  equal("Bob", board[1].name, "the quickest first")
  equal(1, board[1].place)
  equal(2, board[2].place)
  equal(false, board[3].score, "and whoever came to nothing last")
  equal(nil, board[3].place)
  equal(95, dan:Mine("2026-10-14", "minesweeper") or 95)
  equal(nil, dan:Mine("2026-10-14", "minesweeper"), "Dan hasn't played")

  -- Somebody who wasn't there when they were said asks, and is told
  erin.away = false
  equal(0, #erin.board:Board("2026-10-14", "minesweeper"))
  assert(erin.board:Ask("2026-10-14"))
  equal(false, erin.board:Ask("2026-10-14"), "not again at once")
  equal(3, #erin.board:Board("2026-10-14", "minesweeper"))
  equal(3000, erin.board:Board("2026-10-14", "2048")[1].score)
  clock.now = clock.now + 61
  assert(erin.board:Ask("2026-10-14"), "a while later it may")

  -- Ties share a place, more is better at a game played for points
  alice:Post("2026-10-14", "2048", 3000)
  bob:Post("2026-10-14", "2048", 5000)
  local points = dan:Board("2026-10-14", "2048")
  equal("Bob", points[1].name)
  equal(2, points[2].place)
  equal(2, points[3].place)

  -- Nonsense is ignored
  local before = guild.Dan.changes
  for _, text in ipairs({ "1:DAY:2026-10-14:chess:5", "1:DAY:yesterday:2048:5", "1:DAY:2026-10-14:2048:-5", "1:DAY:2026-10-14:2048:1e9", "1:DAY:2026-10-14:2048:3.5", "1:DAY:2026-10-14:nope:5", "1:DAY:2026-10-14" }) do
    equal(true, dan:Handle("Mallory", text), text)
  end
  equal(before, guild.Dan.changes, "nothing new came of it")
  equal(nil, dan.env.boards["2026-10-14"].chess)
  equal(false, dan:Handle("Mallory", "1:HI"), "what isn't about the day's games is left alone")

  -- Only the last week is kept
  dan.env.boards["2026-09-01"] = { minesweeper = { Bob = 1 } }
  dan.env.boards["2026-10-15"] = { minesweeper = { Bob = 1 } }
  dan:Prune()
  equal(nil, dan.env.boards["2026-09-01"])
  equal(nil, dan.env.boards["2026-10-15"], "nor a day that hasn't come yet")
  assert(dan.env.boards["2026-10-14"])
end

function tests.LookingBackStartsFromThePositionsKeptOnTheWay()
  local private = loadEngine()
  local Match, Random = private.Match, private.Random
  local game = private.Games.Get("reversi")
  local match = {
    id = "f00000000001",
    game = "reversi",
    gameVersion = game.version,
    players = { "Alice-Realm", "Bob-Realm" },
    me = 1,
    log = {},
    status = "active",
    seen = {},
    created = 0,
    updated = 0,
  }
  local dice = Random.New(7)
  while not Match.Result(match) do
    local state = Match.State(match)
    local moves = game.moves(state, game.turn(state))
    assert(Match.Append(match, moves[dice:Roll(#moves)]))
  end
  local length = #match.log
  assert(length > 50, "a long game to look back through")

  -- Every position written down the slow way: from nothing, on a match of its own
  local truth = {}
  for count = 0, length do
    local fresh = { id = match.id, game = match.game, gameVersion = match.gameVersion, players = match.players, me = 1, log = { unpack(match.log, 1, count) }, status = "active", seen = {}, created = 0, updated = 0 }
    truth[count] = written(Match.State(fresh))
  end

  -- Stepping back from the end a move at a time plays no more than a few moves for each step
  local applied, apply = 0, game.apply
  game.apply = function(...)
    applied = applied + 1
    return apply(...)
  end
  equal(truth[length - 1], written(Match.StateAt(match, length - 1)))
  applied = 0
  for count = length - 2, 0, -1 do
    equal(truth[count], written(Match.StateAt(match, count)), "stepping back to " .. count)
  end
  assert(applied <= 8 * length, "played " .. applied .. " moves over again stepping back through " .. length)

  -- And anywhere at all, in any order, is where the game was then
  for _ = 1, 60 do
    local count = dice:Roll(length) - 1
    equal(truth[count], written(Match.StateAt(match, count)), "looking at " .. count)
  end
  game.apply = apply

  -- A log cut short and played on another way forgets what it kept of the way it went before
  local played = match.log[21]
  Match.Truncate(match, 20)
  local state = Match.State(match)
  local other = nil
  for _, move in ipairs(game.moves(state, game.turn(state))) do
    if move ~= played then
      other = other or move
    end
  end
  assert(other, "another move to make")
  assert(Match.Append(match, other))
  for _ = 1, 5 do
    assert(Match.Append(match, game.moves(Match.State(match), game.turn(Match.State(match)))[1]))
  end
  local fresh = { id = match.id, game = match.game, gameVersion = match.gameVersion, players = match.players, me = 1, log = { unpack(match.log, 1, 24) }, status = "active", seen = {}, created = 0, updated = 0 }
  equal(written(Match.State(fresh)), written(Match.StateAt(match, 24)))
end

function tests.BackgammonStartsWithADieEach()
  local private = loadEngine()
  local game = private.Games.Get("backgammon")
  local starters = { 0, 0 }
  for deal = 1, 60 do
    local state = game.newState(2, private.Random.New(deal))
    assert(state.dice[1] > state.dice[2], "the opening roll is never doubles, and the higher die comes first")
    equal(2, state.playable, "both dice of an opening roll can always be played")
    starters[state.turn] = starters[state.turn] + 1
    for seat = 1, 2 do
      local checkers, pips = 0, 0
      for point = 1, 24 do
        checkers, pips = checkers + state.points[seat][point], pips + state.points[seat][point] * point
      end
      equal(15, checkers)
      equal(167, pips)
    end
  end
  assert(starters[1] > 15 and starters[2] > 15, "either player may come to start")
end

function tests.BackgammonMovesByTheDice()
  local state, game = backgammonStart({ 6, 1 })
  local function legal(move)
    return (game.validate(state, 1, move))
  end
  equal(true, legal("13-7.8-7"), "making a point")
  equal(true, legal("8-7.13-7"), "in either order")
  equal(true, legal("13-7.7-6"), "one checker by both dice")
  equal(false, legal("24-18.18-17"), "not by way of a closed point")
  equal(false, legal("13-7"), "both dice have to be played when they can be")
  equal(false, legal("13-7.8-7.6-5"))
  equal(false, legal("13-8.8-7"), "not by a number that wasn't rolled")
  equal(false, legal("13-7.13-7"), "each die once")
  equal(false, legal("7-1.8-7"), "nothing there to move")
  equal(false, legal("6-7.13-7"), "never backwards")
  equal(false, legal("13-07.8-7"))
  equal(false, legal(""))
  equal(false, (game.validate(state, 2, "13-7.8-7")), "not red's turn")

  -- Red has five on their six point, which is white's nineteen
  state = backgammonStart({ 5, 1 })
  equal(false, legal("24-19.6-5"), "a point held by two or more is closed")
  equal(true, legal("13-8.6-5"))

  state = backgammonStart({ 3, 3 })
  equal(4, state.playable, "doubles are played four times")
  equal(true, legal("24-21.24-21.13-10.13-10"))
  equal(true, legal("13-10.10-7.7-4.13-10"), "one checker as far as it goes")
  equal(false, legal("13-10.10-7.7-4.4-1"), "but not onto the point red starts with two on")
  equal(false, legal("24-21.24-21.13-10"))
  equal(false, legal("24-21.24-21"))
end

function tests.BackgammonHitsGoToTheBar()
  -- A red checker alone on white's six point
  local state, game, random = backgammonAt({ [10] = 1, [3] = 14 }, { [19] = 1, [1] = 14 }, 1, { 4, 3 })
  local event = game.apply(state, 1, "10-6.6-3", random)
  equal(true, event.steps[1].hit)
  equal(false, event.steps[2].hit)
  equal(1, state.bar[2])
  equal(0, state.points[2][19])
  equal("10/6* 6/3", event.notation)

  -- Red comes in before moving anything else, and not onto white's three point: it is closed
  state, game = backgammonAt({ [3] = 15 }, { bar = 1, [1] = 14 }, 2, { 4, 3 })
  equal(false, (game.validate(state, 2, "1-0")), "nothing moves while a checker is on the bar")
  equal(false, (game.validate(state, 2, "25-22.22-18")), "that is where white's fifteen are")
  equal(true, (game.validate(state, 2, "25-21.21-18")))
  equal(true, (game.validate(state, 2, "25-21.1-0")) == false, "and nothing is borne off with a checker that far back")
end

function tests.BackgammonSitsOutATurnThatCantBePlayed()
  -- White has every point of their home closed and red has a checker on the bar
  local closed = { [1] = 2, [2] = 2, [3] = 2, [4] = 2, [5] = 2, [6] = 2, [13] = 3 }
  local state, game, random = backgammonAt(closed, { bar = 1, [1] = 14 }, 1, { 2, 1 })
  local event = game.apply(state, 1, "13-11.13-12", random)
  equal(1, state.turn, "red can't come in whatever the roll, it is white again")
  assert(#state.skipped >= 1, "red sat out")
  equal(2, state.skipped[1].seat)
  equal(table.concat(state.skipped[1].dice), table.concat(event.dice), "what red rolled is what was rolled next")
  assert(state.playable > 0)
  equal(nil, game.result(state))
end

function tests.BackgammonPlaysAsMuchOfTheRollAsItCan()
  -- White's back checker is hemmed in. The other can go by the six or by the four, and by
  -- neither after the other: it has to be the six
  local state, game = backgammonAt({ [24] = 1, [10] = 1, off = 13 }, { [5] = 2, [7] = 2, [6] = 11 }, 1, { 6, 4 })
  equal(1, state.playable)
  equal(6, state.must)
  equal(true, (game.validate(state, 1, "10-4")))
  equal(false, (game.validate(state, 1, "10-6")), "the higher die when it is only one of them")
  local options = game.rules.continuations(state, {})
  equal(true, options[10][4])
  equal(nil, options[10][6])
  equal(nil, options[24])

  -- The four could be played by either checker, but by the front one it would leave no way to
  -- play the three
  state, game = backgammonAt({ [10] = 1, [5] = 1, off = 13 }, { [18] = 2, [23] = 2, [1] = 11 }, 1, { 4, 3 })
  equal(2, state.playable)
  equal(true, (game.validate(state, 1, "10-6.6-3")))
  equal(false, (game.validate(state, 1, "5-1")), "not half a roll when all of it can be played")
  options = game.rules.continuations(state, {})
  equal(nil, options[5], "the checker that can't be followed up isn't on offer")
  equal(true, options[10][6])
end

function tests.BackgammonBearsOffOnceEveryoneIsHome()
  local state, game, random = backgammonAt({ [6] = 2, [3] = 1, off = 12 }, { [1] = 15 }, 1, { 6, 5 })
  equal(true, (game.validate(state, 1, "6-0.6-1")), "off by the six, along by the five")
  equal(false, (game.validate(state, 1, "6-0.6-0")), "a five doesn't bear off from the six point")
  equal(false, (game.validate(state, 1, "6-0.3-0")), "nor from the three with a checker still behind it")

  -- A roll that is more than it takes bears off from the back, and only from there
  state, game = backgammonAt({ [4] = 1, [2] = 1, off = 13 }, { [1] = 15 }, 1, { 6, 5 })
  equal(true, (game.validate(state, 1, "4-0.2-0")))
  equal(false, (game.validate(state, 1, "2-0.4-0")))

  -- Not while a checker is still on its way home
  state, game = backgammonAt({ [7] = 1, [2] = 1, off = 13 }, { [1] = 15 }, 1, { 2, 1 })
  equal(false, (game.validate(state, 1, "2-0.7-6")))
  equal(true, (game.validate(state, 1, "7-6.2-0")), "but as soon as it is")

  -- The last one off wins. Red hasn't borne anything off: a gammon
  state, game, random = backgammonAt({ [1] = 1, off = 14 }, { [1] = 15 }, 1, { 6, 5 })
  local event = game.apply(state, 1, "1-0", random)
  equal(1, game.result(state).winner)
  equal("gammon", game.result(state).detail)
  equal("1/off", event.notation)
  equal(nil, event.dice[1], "nobody rolls again")

  state, game, random = backgammonAt({ [1] = 1, off = 14 }, { [1] = 14, bar = 1 }, 1, { 6, 5 })
  game.apply(state, 1, "1-0", random)
  equal("backgammon", game.result(state).detail, "with a red checker still on the bar")

  state, game, random = backgammonAt({ [1] = 1, off = 14 }, { [1] = 3, off = 12 }, 1, { 6, 5 })
  game.apply(state, 1, "1-0", random)
  equal(nil, game.result(state).detail, "an ordinary win")
end

function tests.BackgammonPlaysThroughToTheEnd()
  local private = loadEngine()
  local game, Random = private.Games.Get("backgammon"), private.Random
  for match = 1, 25 do
    local chance = Random.Seed("match" .. match)
    local state = game.newState(2, Random.New(chance))
    -- Players who move at random, each game differently
    local whim = Random.New(match)
    local turns = 0
    while not game.result(state) do
      local seat = game.turn(state)
      local move = backgammonTurn(game, state, function(count)
        return whim:Roll(count)
      end)
      assert(game.validate(state, seat, move), "turn " .. turns .. " of match " .. match .. ": " .. move)
      chance = Random.Stir(chance, move)
      game.apply(state, seat, move, Random.New(chance))
      turns = turns + 1
      assert(turns < 2000, "the game should end")

      for owner = 1, 2 do
        local checkers = state.bar[owner] + state.off[owner]
        for point = 1, 24 do
          checkers = checkers + state.points[owner][point]
          assert(state.points[owner][point] == 0 or state.points[3 - owner][25 - point] == 0, "two colours on a point")
        end
        equal(15, checkers, "checkers of seat " .. owner)
      end
    end
    equal(15, state.off[game.result(state).winner])
  end
end

--- Starts a match of some game between two fresh players
--- @param gameId string
--- @param luck number? Where the world's own dice start from, which is what the match gets its id from
--- @return World, table[] seated The players by seat, string id
local function startedGame(gameId, luck)
  local world = World.New()
  world.seed = luck or 0
  local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  local match = assert(alice.session:Invite("Bob-Realm", gameId))
  world:Deliver()
  assert(bob.session:Accept(match.id))
  world:Deliver()
  local seated = { [match.me] = alice, [3 - match.me] = bob }
  return world, seated, match.id
end

--- Everything about a position, written out to compare
--- @param value any
--- @return string
local function written(value)
  if type(value) ~= "table" then
    return tostring(value)
  end
  local keys = {}
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local parts = {}
  for index, key in ipairs(keys) do
    parts[index] = tostring(key) .. "=" .. written(value[key])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

function tests.BackgammonRollsTheSameDiceForBothPlayers()
  local world, seated, id = startedGame("backgammon")
  local rolled = {}
  for _ = 1, 40 do
    local states = {}
    for seat, player in ipairs(seated) do
      states[seat] = player.private.Match.State(player.matches[id])
    end
    equal(written(states[1]), written(states[2]), "both players have the same position and the same roll to play")
    if seated[1].matches[id].status ~= "active" then
      break
    end
    rolled[#rolled + 1] = states[1].dice[1] .. states[1].dice[2]

    local mover = seated[states[1].turn]
    assert(mover.session:Move(id, backgammonTurn(mover.private.Games.Get("backgammon"), states[states[1].turn])))
    world:Deliver()
    equal(logOf(seated[1], id), logOf(seated[2], id))
  end

  -- Losing the saved game and getting it back from the opponent brings the same dice back with it
  local before = written(seated[1].private.Match.State(seated[1].matches[id]))
  local returned = world:Relog(seated[1], {})
  world:Tick(60)
  world:Tick(60)
  if returned.matches[id] then
    equal(before, written(returned.private.Match.State(returned.matches[id])))
  end

  -- Another match is another game
  local _, others, otherId = startedGame("backgammon", 5)
  assert(otherId ~= id)
  local again = {}
  for index = 1, 12 do
    local state = others[1].private.Match.State(others[1].matches[otherId])
    again[index] = state.dice[1] .. state.dice[2]
    local mover = others[state.turn]
    assert(mover.session:Move(otherId, backgammonTurn(mover.private.Games.Get("backgammon"), state)))
    _:Deliver()
  end
  assert(table.concat(again) ~= table.concat(rolled, "", 1, 12), "the same dice in two different matches")
end

-----------------------------
-- Backgammon on screen
-----------------------------

-- The table as Games/Backgammon.lua lays it out, in checkers
local TABLE_WIDTH, TABLE_HEIGHT = 15.6, 12.7
local TABLE_EDGE, TABLE_BAR = 0.45, 1.1

--- Moves the cursor onto a point of the table, as the player whose window it is counts them
--- @param board table
--- @param point number 25 for the bar, 0 for where checkers are borne off to
local function pointAtPoint(board, point)
  local cell = board.width / TABLE_WIDTH
  local x, y
  if point == 25 then
    x, y = TABLE_EDGE + 6 + TABLE_BAR / 2, TABLE_HEIGHT / 2 + 0.75
  elseif point == 0 then
    x, y = TABLE_WIDTH - TABLE_EDGE - 0.6, TABLE_HEIGHT - 2
  else
    local top = point > 12
    local column = top and point - 13 or 12 - point
    x = TABLE_EDGE + column + 0.5 + (column >= 6 and TABLE_BAR or 0)
    y = top and TABLE_EDGE + 1.2 or TABLE_HEIGHT - TABLE_EDGE - 1.2
  end
  Client.cursor = { x * cell, board.height - y * cell }
  board:Fire("OnUpdate", 0.02)
end

--- @param board table
--- @param point number
--- @param button string?
local function clickPoint(board, point, button)
  pointAtPoint(board, point)
  if button then
    board:Fire("OnMouseDown", button)
    return
  end
  press(board)
  release(board)
end

--- What the player has the dice in hand with: the table, there to click. Nil if they haven't
--- @return table?
local function diceInHand()
  local prompts = Client.Find(function(widget)
    return widget.text == "dice_roll" and widget:IsVisible()
  end)
  return prompts[1] and prompts[1]:GetParent()
end

--- Clicks to throw the dice in hand
local function throwDice()
  local hand = assert(diceInHand(), "Expected dice in hand")
  hand:Fire("OnMouseDown", "LeftButton")
  hand:Fire("OnMouseUp", "LeftButton")
end

--- Lets time pass for the dice on a table, so that they come to rest
--- @param surface table What they lie on
local function letDiceRoll(surface)
  local frames = Client.Find(function(widget)
    return widget.parent == surface and widget.scripts.OnUpdate ~= nil
  end)
  for _, frame in ipairs(frames) do
    for _ = 1, 60 do
      frame:Fire("OnUpdate", 0.02)
    end
  end
end

--- The dice to be seen, left to right as they lie
--- @return number[] faces
--- @return table[] textures
local function diceOnTable()
  local textures = Client.Find(function(widget)
    return widget.kind == "Texture" and widget:IsVisible() and (widget.texture or ""):match("Dice\\%a+%d$") ~= nil
  end)
  local faces = {}
  for index, texture in ipairs(textures) do
    faces[index] = tonumber(texture.texture:match("%d$"))
  end
  return faces, textures
end

--- Starts a game of backgammon and opens the window of whoever won the opening roll
--- @param held boolean? Leave the opening roll in their hand, rather than throw it
--- @return World, table mover, table opponent, string id, table state
local function backgammonOnScreen(held)
  local world, seated, id = startedGame("backgammon")
  local state = seated[1].private.Match.State(seated[1].matches[id])
  local mover = seated[state.turn]
  local MainFrame = openWindow(mover)
  MainFrame.Open(id)
  if not held then
    throwDice()
  end
  return world, mover, seated[3 - state.turn], id, mover.private.Match.State(mover.matches[id])
end

function tests.WindowHasBackgammonDiceThrownFromTheHand()
  local world, mover, opponent, id, state = backgammonOnScreen(true)
  local board = shownBoard()
  local high, low = state.dice[1], state.dice[2]
  local hand = assert(diceInHand(), "the opening roll waits in the hand of whoever won it")
  clickPoint(board, 13)
  clickPoint(board, 13 - high)
  equal(false, Client.Button("backgammon_undo").enabled, "nothing is played before the dice are thrown")

  hand:Fire("OnMouseDown", "LeftButton")
  equal("dieShuffle", Client.sounds[#Client.sounds], "shaken for as long as the button is held")
  equal(nil, diceInHand())
  hand:Fire("OnMouseUp", "LeftButton")
  equal("dieShuffle", Client.stopped[#Client.stopped], "the rattle stops as they leave the hand")
  equal(false, hand:IsVisible())
  letDiceRoll(board)
  equal("dieThrow", Client.sounds[#Client.sounds], "they are heard landing")
  equal(high .. "," .. low, table.concat(diceOnTable(), ","), "and come to rest on what was rolled")

  -- The die a checker was moved by is used up
  clickPoint(board, 13)
  clickPoint(board, 13 - high)
  letDiceRoll(board)
  local _, dice = diceOnTable()
  assert(dice[1]:GetAlpha() < 1, "the die played is told apart")
  equal(1, dice[2]:GetAlpha())
  clickPoint(board, 13)
  clickPoint(board, 13 - low)
  Client.Button("backgammon_play"):Fire("OnClick")

  -- The opponent's roll is thrown for them, there is nothing to click
  equal(nil, diceInHand())
  letDiceRoll(board)
  local theirs = mover.private.Match.State(mover.matches[id])
  equal(theirs.dice[1] .. "," .. theirs.dice[2], table.concat(diceOnTable(), ",", 1, 2))

  -- And when their move comes, the next roll is the player's to throw
  world:Deliver()
  local game = opponent.private.Games.Get("backgammon")
  assert(opponent.session:Move(id, backgammonTurn(game, opponent.private.Match.State(opponent.matches[id]))))
  world:Deliver()
  letDiceRoll(board)
  assert(diceInHand(), "the player's roll waits in their hand")
  throwDice()
  equal(nil, diceInHand())
end

function tests.WindowPlaysBackgammonACheckerAtATime()
  local world, mover, opponent, id, state = backgammonOnScreen()
  local board = shownBoard()
  assert(board.width >= 15 * 20, "the table should make use of the window, got " .. board.width)
  equal(true, says("status_your_turn"))
  local play, undo = Client.Button("backgammon_play"), Client.Button("backgammon_undo")
  equal(false, play.enabled, "nothing to send yet")
  equal(false, undo.enabled)

  -- The opening roll is never doubles: a checker from the mid point by each die
  local high, low = state.dice[1], state.dice[2]
  clickPoint(board, 13)
  clickPoint(board, 13 - high)
  equal("", logOf(mover, id), "one checker isn't the turn")
  equal("chipsCollide", Client.sounds[#Client.sounds])
  equal(true, undo.enabled)
  equal(false, play.enabled)

  -- Taken back with the button, made again, and the other one taken back with the right mouse button
  undo:Fire("OnClick")
  equal(false, undo.enabled)
  clickPoint(board, 13)
  clickPoint(board, 13 - high)
  clickPoint(board, 13)
  clickPoint(board, 13 - low)
  equal(true, play.enabled)
  clickPoint(board, 1, "RightButton")
  equal(false, play.enabled)
  equal(true, undo.enabled)

  -- Dragged this time
  pointAtPoint(board, 13)
  press(board)
  board:Fire("OnUpdate", 0.02)
  pointAtPoint(board, 13 - low)
  release(board)
  equal(true, play.enabled)
  equal("", logOf(mover, id), "and still nothing is sent before the player says so")

  play:Fire("OnClick")
  equal("13-" .. (13 - high) .. ".13-" .. (13 - low), logOf(mover, id))
  settle(board)
  equal(false, play:IsVisible(), "no buttons while it is the other player's turn")
  world:Deliver()
  equal(logOf(mover, id), logOf(opponent, id))

  -- Nothing to pick up while waiting
  clickPoint(board, 13)
  clickPoint(board, 12)
  equal(1, #mover.matches[id].log)
end

function tests.WindowLetsAnotherBackgammonCheckerBePickedUpInstead()
  local _, mover, _, id, state = backgammonOnScreen()
  local board = shownBoard()
  local high, low = state.dice[1], state.dice[2]
  -- With a checker from the mid point in hand, a click on the eight point isn't a move it can
  -- make: it picks one up from there
  clickPoint(board, 13)
  clickPoint(board, 8)
  equal(false, Client.Button("backgammon_undo").enabled)
  clickPoint(board, 8 - low)
  equal(true, Client.Button("backgammon_undo").enabled)
  clickPoint(board, 13)
  clickPoint(board, 13 - high)
  Client.Button("backgammon_play"):Fire("OnClick")
  equal("8-" .. (8 - low) .. ".13-" .. (13 - high), logOf(mover, id))
end

function tests.WindowMovesABackgammonCheckerByBothDice()
  local _, mover, _, id, state = backgammonOnScreen()
  local board = shownBoard()
  local high, low = state.dice[1], state.dice[2]
  -- The point both dice away from a back checker is open on the opening roll unless it is the
  -- opponent's six point or their bar point
  local from = 24
  local blocked = { [19] = true, [17] = true, [13] = false }
  if blocked[from - high - low] then
    from = 13
  end
  clickPoint(board, from)
  clickPoint(board, from - high - low)
  local play = Client.Button("backgammon_play")
  if play.enabled then
    play:Fire("OnClick")
    local log = logOf(mover, id)
    local to = from - high - low
    local first = from .. "-" .. (from - high) .. "." .. (from - high) .. "-" .. to
    local second = from .. "-" .. (from - low) .. "." .. (from - low) .. "-" .. to
    assert(log == first or log == second, "one checker moved by both dice, got " .. log)
  else
    -- Both ways there were closed, which leaves the checker where it was
    equal(false, Client.Button("backgammon_undo").enabled)
  end
end

-----------------------------
-- Yacht
-----------------------------

function tests.YachtScoresEveryBox()
  local game = loadEngine().Games.Get("yacht")
  local scoreOf = game.rules.scoreOf
  local function scores(dice, card)
    local parts = {}
    for _, id in ipairs({ "1", "2", "3", "4", "5", "6", "3k", "4k", "fh", "ss", "ls", "y", "c" }) do
      parts[#parts + 1] = id .. "=" .. scoreOf(dice, id, card or {})
    end
    return table.concat(parts, " ")
  end
  equal("1=0 2=4 3=9 4=0 5=0 6=0 3k=13 4k=0 fh=25 ss=0 ls=0 y=0 c=13", scores({ 3, 2, 3, 2, 3 }))
  equal("1=1 2=2 3=3 4=4 5=0 6=6 3k=0 4k=0 fh=0 ss=30 ls=0 y=0 c=16", scores({ 6, 1, 3, 2, 4 }), "four in a row with one more")
  equal("1=0 2=2 3=3 4=4 5=5 6=6 3k=0 4k=0 fh=0 ss=30 ls=40 y=0 c=20", scores({ 2, 3, 4, 5, 6 }))
  equal("1=0 2=0 3=0 4=0 5=5 6=24 3k=29 4k=29 fh=0 ss=0 ls=0 y=0 c=29", scores({ 6, 6, 5, 6, 6 }))
  equal("1=0 2=0 3=0 4=20 5=0 6=0 3k=20 4k=20 fh=0 ss=0 ls=0 y=50 c=20", scores({ 4, 4, 4, 4, 4 }), "a yacht isn't a full house")
  equal("1=0 2=0 3=0 4=20 5=0 6=0 3k=20 4k=20 fh=25 ss=30 ls=40 y=50 c=20", scores({ 4, 4, 4, 4, 4 }, { y = 0 }), "until the yacht box is filled, even with nothing")
end

function tests.YachtRollsAgainKeepingWhatIsKept()
  local private = loadEngine()
  local game = private.Games.Get("yacht")
  local random = private.Random.New(7)
  local state = game.newState(1, random)
  equal(5, #state.dice)
  equal(1, state.rolls)
  for _, face in ipairs(state.dice) do
    assert(face >= 1 and face <= 6)
  end

  equal(false, (game.validate(state, 1, "r11111")), "keeping everything isn't a roll")
  equal(false, (game.validate(state, 1, "r1010")))
  equal(false, (game.validate(state, 1, "r10102")))
  equal(false, (game.validate(state, 1, "sxx")))
  equal(false, (game.validate(state, 2, "r00000")))
  local kept = { state.dice[1], state.dice[4] }
  equal(true, (game.validate(state, 1, "r10010")))
  local event = game.apply(state, 1, "r10010", random)
  equal("10010", event.kept)
  equal(kept[1] .. "," .. kept[2], state.dice[1] .. "," .. state.dice[4])
  equal(2, state.rolls)
  game.apply(state, 1, "r00000", random)
  equal(false, (game.validate(state, 1, "r00000")), "three rolls a turn")
  equal(true, (game.validate(state, 1, "sc")))

  local total = state.dice[1] + state.dice[2] + state.dice[3] + state.dice[4] + state.dice[5]
  event = game.apply(state, 1, "sc", random)
  equal("c", event.box)
  equal(total, event.scored)
  equal(total, state.card.c)
  equal(2, state.turn)
  equal(1, state.rolls, "the next turn's dice are rolled already")
  equal(false, (game.validate(state, 1, "sc")), "a box is filled once")
  equal(total, game.rules.totalOf(state))
  equal("yacht_progress", game.progress(state))
end

function tests.YachtEarnsItsBonuses()
  local private = loadEngine()
  local game = private.Games.Get("yacht")
  local random = private.Random.New(3)
  local state = game.newState(1, random)

  -- Three of each upper face is the 63 that earns 35
  state.card = { ["1"] = 3, ["2"] = 6, ["3"] = 9, ["4"] = 12, ["5"] = 15 }
  state.dice = { 6, 6, 6, 1, 2 }
  local event = game.apply(state, 1, "s6", random)
  equal(18, event.scored)
  equal(true, event.upper)
  equal(63 + 35, game.rules.totalOf(state))

  -- A yacht, then another: 100 more, and it fits the full house
  state.dice = { 2, 2, 2, 2, 2 }
  event = game.apply(state, 1, "sy", random)
  equal(50, event.scored)
  equal(nil, event.extra)
  state.dice = { 5, 5, 5, 5, 5 }
  event = game.apply(state, 1, "sfh", random)
  equal(25, event.scored)
  equal(100, event.extra)
  equal(100, state.bonus)
  equal(63 + 35 + 50 + 25 + 100, game.rules.totalOf(state))

  -- Not after a yacht box filled with nothing
  state = game.newState(1, random)
  state.card.y = 0
  state.dice = { 3, 3, 3, 3, 3 }
  event = game.apply(state, 1, "s3", random)
  equal(nil, event.extra)
  equal(0, state.bonus)
end

function tests.YachtIsPlayedThroughThirteenTurns()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local session, Match, game = alice.session, alice.private.Match, alice.private.Games.Get("yacht")
  local match = assert(session:Invite({}, "yacht"))
  local boxes = { "y", "ls", "ss", "fh", "4k", "3k", "c", "6", "5", "4", "3", "2", "1" }
  for turn, box in ipairs(boxes) do
    equal(turn, Match.State(match).turn)
    assert(session:Move(match.id, "r10100"))
    assert(session:Move(match.id, "r00000"))
    equal(nil, game.result(Match.State(match)))
    assert(session:Move(match.id, "s" .. box))
  end
  local state = Match.State(match)
  equal(true, state.over)
  equal(false, (game.validate(state, 1, "r00000")))
  equal(false, (game.validate(state, 1, "s1")))
  local total = game.rules.totalOf(state)
  equal(total >= 200 and 1 or 0, game.result(state).winner)
  equal(total, session:Best("yacht", "score"))
  equal("yacht_final", game.progress(state))
end

-----------------------------
-- Yacht on screen
-----------------------------

--- Starts a game of Yacht and opens it
--- @return table player, string id
local function yachtOnScreen()
  local world = World.New()
  world.seed = 5
  local player = world:AddPlayer("Alice-Realm")
  local MainFrame = openWindow(player)
  local match = assert(player.session:Invite({}, "yacht"))
  MainFrame.Open(match.id)
  return player, match.id
end

--- What the dice lie on: the felt
--- @return table
local function yachtFelt()
  local found = Client.Find(function(widget)
    return (widget.text == "yacht_turn" or widget.text == "yacht_card_full") and widget:IsVisible()
  end)
  equal(1, #found, "the turn written on the felt")
  return found[1]:GetParent()
end

--- The row of the card for a box, or for what is added up
--- @param id string
--- @return table
local function yachtRow(id)
  local found = Client.Find(function(widget)
    return widget.text == "yacht_row_" .. id and widget:IsVisible()
  end)
  equal(1, #found, "rows for " .. id)
  return found[1]:GetParent()
end

--- The dice there are to click, in order
--- @return table[]
local function yachtDiceButtons()
  return Client.Find(function(widget)
    return widget.kind == "Button" and widget.scripts.OnClick ~= nil and widget.parent ~= nil and widget.parent.parent == yachtFelt() and widget:IsVisible()
  end)
end

--- Lets time pass for everything that moves over the game, beside the dice
local function yachtTime()
  letDiceRoll(yachtFelt():GetParent())
end

function tests.WindowPlaysYacht()
  local player, id = yachtOnScreen()
  local Match = player.private.Match
  local felt = yachtFelt()
  local roll = Client.Button("yacht_roll")
  equal(false, roll.enabled, "the first roll is in hand")
  equal(true, diceInHand() ~= nil)
  equal("", yachtRow("c").value.text, "nothing to score before the dice are thrown")

  throwDice()
  equal("", yachtRow("c").value.text, "nor while they are in the air")
  letDiceRoll(felt)
  local state = Match.State(player.matches[id])
  local dice = state.dice
  equal(table.concat(dice, ","), table.concat(diceOnTable(), ","))
  equal(tostring(dice[1] + dice[2] + dice[3] + dice[4] + dice[5]), yachtRow("c").value.text, "what the dice would score")
  equal(true, roll.enabled)
  equal(true, says("yacht_hint_keep"))

  -- Kept dice stay as they are, the rest are picked up and shaken while the button is held
  local buttons = yachtDiceButtons()
  equal(5, #buttons)
  buttons[2]:Fire("OnClick")
  buttons[5]:Fire("OnClick")
  roll:Fire("OnMouseDown", "LeftButton")
  equal("dieShuffle", Client.sounds[#Client.sounds])
  equal("", logOf(player, id), "nothing is rolled before the button is let go")
  equal("", yachtRow("c").value.text)
  roll:Fire("OnMouseUp", "LeftButton")
  equal("r01001", logOf(player, id))
  letDiceRoll(felt)
  state = Match.State(player.matches[id])
  equal(dice[2] .. "," .. dice[5], state.dice[2] .. "," .. state.dice[5])
  equal(table.concat(state.dice, ","), table.concat(diceOnTable(), ","))

  -- Let back onto the felt, a die is rolled again
  yachtDiceButtons()[2]:Fire("OnClick")
  roll:Fire("OnMouseDown", "LeftButton")
  roll:Fire("OnMouseUp", "LeftButton")
  equal("r01001,r00001", logOf(player, id))
  letDiceRoll(felt)
  equal(false, roll.enabled, "three rolls a turn")
  equal(true, says("yacht_hint_score"))
  equal(0, #yachtDiceButtons(), "nothing left to keep")

  state = Match.State(player.matches[id])
  local chance = state.dice[1] + state.dice[2] + state.dice[3] + state.dice[4] + state.dice[5]
  yachtRow("c"):Fire("OnClick")
  equal("r01001,r00001,sc", logOf(player, id))
  equal(tostring(chance), yachtRow("c").value.text)
  equal(tostring(chance), yachtRow("total").value.text)
  equal(true, diceInHand() ~= nil, "the next turn's roll waits in hand")
  local stage = yachtFelt():GetParent()
  for _ = 1, 3 do
    for _, frame in ipairs(Client.Find(function(widget)
      return widget.parent == stage and widget.scripts.OnUpdate ~= nil
    end)) do
      frame:Fire("OnUpdate", 0.02)
    end
  end
  equal(true, says("+" .. chance), "what was scored drifts up from the card")
  yachtRow("1"):Fire("OnClick")
  equal("r01001,r00001,sc", logOf(player, id), "and nothing is scored before it is thrown")
end

function tests.WindowSaysWhenTheYachtCardIsFull()
  local player, id = yachtOnScreen()
  for _, box in ipairs({ "1", "2", "3", "4", "5", "6", "3k", "4k", "fh", "ss", "ls", "y" }) do
    throwDice()
    letDiceRoll(yachtFelt())
    yachtRow(box):Fire("OnClick")
  end
  throwDice()
  letDiceRoll(yachtFelt())
  yachtRow("c"):Fire("OnClick")
  equal(13, #player.matches[id].log)
  yachtTime()
  local total = player.private.Games.Get("yacht").rules.totalOf(player.private.Match.State(player.matches[id]))
  equal(true, says(total >= 200 and "yacht_won" or "yacht_over"))
  equal(nil, diceInHand())
  equal(0, #Client.Find(function(widget)
    return widget.kind == "Button" and (widget.text == "yacht_roll" or widget.text == "yacht_no_rolls") and widget:IsVisible()
  end), "no button to roll with")
end

-----------------------------
-- Crazy Eights
-----------------------------

--- A position set up by hand
--- @param hands string[][] By seat
--- @param pile string[] The card on top last
--- @param deck string[] The next card to be drawn last
--- @param turn number?
--- @return table state, table game, table random
local function crazyEightsAt(hands, pile, deck, turn)
  local private = loadEngine()
  local game = private.Games.Get("crazyeights")
  local state = game.newState(#hands, private.Random.New(1))
  state.hands, state.pile, state.deck = hands, pile, deck
  state.suit, state.turn = pile[#pile]:sub(2, 2), turn or 1
  return state, game, private.Random.New(3)
end

--- Every card of a position, wherever it is
--- @param state table
--- @return string[] Sorted
local function allCards(state)
  local cards = { unpack(state.deck) }
  for _, card in ipairs(state.pile) do
    cards[#cards + 1] = card
  end
  for _, hand in ipairs(state.hands) do
    for _, card in ipairs(hand) do
      cards[#cards + 1] = card
    end
  end
  table.sort(cards)
  return cards
end

--- A move for whoever's turn it is: the first card that goes, calling its own suit with an
--- eight, or a card from the deck, or nothing
--- @param game table
--- @param state table
--- @return string
local function crazyEightsMove(game, state)
  local seat = game.turn(state)
  for _, card in ipairs(state.hands[seat]) do
    for _, move in ipairs({ card, card .. card:sub(2, 2) }) do
      if game.validate(state, seat, move) then
        return move
      end
    end
  end
  return game.validate(state, seat, "d") and "d" or "p"
end

function tests.CrazyEightsDealsEveryoneAHand()
  local private = loadEngine()
  local game = private.Games.Get("crazyeights")
  local tops = {}
  for seats = 2, 6 do
    for deal = 1, 20 do
      local state = game.newState(seats, private.Random.New(deal * 31 + seats))
      for seat = 1, seats do
        equal(seats == 2 and 7 or 5, #state.hands[seat], "cards dealt to each of " .. seats)
      end
      local cards = allCards(state)
      equal(52, #cards)
      for index = 2, #cards do
        assert(cards[index] ~= cards[index - 1], "the same card twice: " .. cards[index])
      end
      equal(1, #state.pile)
      assert(state.pile[1]:sub(1, 1) ~= "8", "the pile never starts with an eight")
      equal(state.pile[1]:sub(2, 2), state.suit)
      equal(1, state.turn)
      tops[state.pile[1]] = true
    end
  end
  local different = 0
  for _ in pairs(tops) do
    different = different + 1
  end
  assert(different > 30, "the deck should come out differently every time, got " .. different .. " starting cards in 100 deals")
end

function tests.CrazyEightsFollowsSuitOrRank()
  local state, game, random = crazyEightsAt({ { "QH", "5S", "QC", "8D" }, { "2H", "9C" } }, { "7H" }, { "3C", "4D" })
  local function check(move)
    return game.validate(state, state.turn, move)
  end
  equal(true, (check("QH")), "the same suit")
  local ok, err = check("QC")
  equal(false, ok)
  equal("card_doesnt_match", err)
  ok, err = check("5S")
  equal("card_doesnt_match", err)
  equal(false, (check("KH")), "not a card that isn't in the hand")
  equal(false, (check("2H")), "nor one in somebody else's")
  equal(false, (check("QHS")), "only an eight calls a suit")
  equal(false, (check("8D")), "and an eight has to")
  equal(false, (check("1H")))
  equal(false, (check("QX")))
  equal(false, (check("")))
  equal(false, (game.validate(state, 2, "2H")), "not out of turn")

  local event = game.apply(state, 1, "QH", random)
  equal("QH", event.card)
  equal(nil, event.called)
  equal("QH", state.pile[#state.pile])
  equal(3, #state.hands[1])
  equal(2, state.turn)
  equal(false, (check("9C")))
  equal(true, (check("2H")))

  -- Rank matches too, and changes the suit to follow
  state = crazyEightsAt({ { "QC", "5S" }, { "2H", "9C" } }, { "QH" }, { "3C" })
  equal(true, (check("QC")))
  game.apply(state, 1, "QC", random)
  equal("C", state.suit)
  equal(true, (check("9C")))
  equal(false, (check("2H")))
end

function tests.CrazyEightsEightsGoOnAnythingAndCallASuit()
  local state, game, random = crazyEightsAt({ { "8D", "5S" }, { "2H", "9C", "KD" } }, { "7H" }, { "3C", "4D" })
  equal(true, (game.validate(state, 1, "8DC")))
  equal(true, (game.validate(state, 1, "8DD")), "its own suit as well")
  local event = game.apply(state, 1, "8DC", random)
  equal("8D", event.card)
  equal("C", event.called)
  equal("C", state.suit)
  equal("8D", state.pile[#state.pile])

  equal(false, (game.validate(state, 2, "KD")), "the suit of the eight itself doesn't count, the one called does")
  equal(false, (game.validate(state, 2, "2H")))
  equal(true, (game.validate(state, 2, "9C")))
end

function tests.CrazyEightsDrawsWhenNothingGoes()
  -- The card on top of the deck is the last one. This one can't be played either
  local state, game, random = crazyEightsAt({ { "5S", "6S" }, { "2H", "9C" } }, { "7H" }, { "KH", "4D" })
  local ok, err = game.validate(state, 1, "p")
  equal(false, ok)
  equal("draw_first", err)
  local event = game.apply(state, 1, "d", random)
  equal(true, event.drew)
  equal(true, event.passed, "nothing to play even now: the turn moves on by itself")
  equal(nil, event.card, "what was drawn is nobody else's business")
  equal("5S,6S,4D", table.concat(state.hands[1], ","))
  equal(2, state.turn)

  -- This one can: the turn stays, to play it or anything else, or to pass
  state, game, random = crazyEightsAt({ { "5S", "6S" }, { "2H", "9C" } }, { "7H" }, { "4D", "KH" })
  event = game.apply(state, 1, "d", random)
  equal(false, event.passed)
  equal(1, state.turn)
  equal(true, state.drew)
  ok, err = game.validate(state, 1, "d")
  equal(false, ok, "one card a turn")
  equal("cant_draw", err)
  equal(true, (game.validate(state, 1, "KH")))
  equal(true, (game.validate(state, 1, "p")))
  game.apply(state, 1, "p", random)
  equal(2, state.turn)
  equal(false, state.drew)
  equal(nil, game.result(state))

  -- Drawing is allowed with a card in hand that could have been played
  state, game, random = crazyEightsAt({ { "5H", "6S" }, { "2H", "9C" } }, { "7H" }, { "4D", "KC" })
  equal(true, (game.validate(state, 1, "d")))
  event = game.apply(state, 1, "d", random)
  equal(false, event.passed, "and then the turn is still the player's")
  equal(true, (game.validate(state, 1, "5H")))
end

function tests.CrazyEightsShufflesThePileBackIn()
  local state, game, random = crazyEightsAt({ { "5S", "6S" }, { "2H", "9C" } }, { "3D", "4C", "JD", "KH", "7H" }, {})
  local before = table.concat(allCards(state), ",")
  local event = game.apply(state, 1, "d", random)
  equal(true, event.shuffled)
  equal("7H", table.concat(state.pile, ","), "the card on top stays where it is")
  equal(3, #state.deck)
  equal(3, #state.hands[1])
  equal(before, table.concat(allCards(state), ","), "no card is lost or made")

  -- With nothing under the top card either, there is nothing to draw. Then a turn can be
  -- passed just like that, and once everyone has in a row the game is stuck
  state, game, random = crazyEightsAt({ { "5S" }, { "2C" } }, { "7H" }, {})
  equal(false, (game.validate(state, 1, "d")))
  equal(true, (game.validate(state, 1, "p")))
  game.apply(state, 1, "p", random)
  equal(nil, game.result(state))
  game.apply(state, 2, "p", random)
  equal(0, game.result(state).winner)
  equal("blocked", game.result(state).detail)
end

function tests.CrazyEightsIsWonByPlayingTheLastCard()
  local state, game, random = crazyEightsAt({ { "5H" }, { "2H", "9C" }, { "3S" } }, { "7H" }, { "4D" })
  equal(nil, game.result(state))
  game.apply(state, 1, "5H", random)
  equal(1, game.result(state).winner)

  -- A player who resigns gives their cards back and is passed over from then on
  state, game, random = crazyEightsAt({ { "5H", "6H" }, { "2H", "9C" }, { "3H", "4H" } }, { "7H" }, { "4D" })
  game.drop(state, 2)
  equal(0, #state.hands[2])
  equal("2H,9C", table.concat({ state.deck[2], state.deck[1] }, ","), "under the deck, not on top of it")
  equal("4D", state.deck[#state.deck])
  game.apply(state, 1, "5H", random)
  equal(3, state.turn)
  game.apply(state, 3, "3H", random)
  equal(1, state.turn)

  -- Resigning on your own turn hands it on
  state, game = crazyEightsAt({ { "5H", "6H" }, { "2H", "9C" }, { "3H", "4H" } }, { "7H" }, { "4D" })
  game.drop(state, 1)
  equal(2, state.turn)
end

function tests.CrazyEightsShowsAPlayerOnlyTheirOwnCards()
  local state, game = crazyEightsAt({ { "5H", "6S" }, { "2H", "9C", "KD" }, { "3S" } }, { "JD", "7H" }, { "4D", "QS" }, 2)
  local seen = game.visible(state, 2)
  equal("2H,9C,KD", table.concat(seen.hands[2], ","))
  equal("?,?", table.concat(seen.hands[1], ","), "how many the others hold, not what")
  equal("?", table.concat(seen.hands[3], ","))
  equal("?,?", table.concat(seen.deck, ","))
  equal("JD,7H", table.concat(seen.pile, ","), "what was played was played in the open")
  equal("H", seen.suit)
  equal(2, seen.turn)

  -- What a player sees is a copy: nothing done to it reaches the game
  seen.hands[2][1], seen.pile[1] = "AS", "AS"
  equal("2H", state.hands[2][1])
  equal("JD", state.pile[1])
  equal("5H,6S", table.concat(state.hands[1], ","))

  -- What the game says about a move is seen by everyone. It never names a card that was drawn
  local written = {}
  for key, value in pairs(game.apply(state, 2, "d", loadEngine().Random.New(1))) do
    written[#written + 1] = key .. "=" .. tostring(value)
  end
  table.sort(written)
  equal("drew=true,passed=false,shuffled=false", table.concat(written, ","))
end

function tests.CrazyEightsIsPlayedByACrowdWhoEachSeeTheirOwnHand()
  local world, seated, id = startedCrowd(4, "crazyeights")
  local moves = 0
  while seated[1].matches[id].status == "active" do
    -- Everyone has the same game, and is shown a different one
    local states = {}
    for seat, player in ipairs(seated) do
      local Match = player.private.Match
      states[seat] = written(Match.State(player.matches[id]))
      local seen = Match.Visible(player.matches[id])
      for other, hand in ipairs(seen.hands) do
        for _, card in ipairs(hand) do
          equal(other == seat, card ~= "?", "seat " .. seat .. " looking at the hand of seat " .. other)
        end
      end
      for _, card in ipairs(seen.deck) do
        equal("?", card)
      end
    end
    for seat = 2, #seated do
      equal(states[1], states[seat], "the game as seat " .. seat .. " has it")
    end

    local mover
    for _, player in ipairs(seated) do
      if player.private.Match.IsMyTurn(player.matches[id]) then
        mover = player
      end
    end
    local game = mover.private.Games.Get("crazyeights")
    assert(mover.session:Move(id, crazyEightsMove(game, mover.private.Match.State(mover.matches[id]))))
    world:Deliver()
    moves = moves + 1
    assert(moves < 3000, "the game should end")
  end

  -- When it is over the cards are on the table
  for seat, player in ipairs(seated) do
    equal("finished", player.matches[id].status, "seat " .. seat)
    local Match = player.private.Match
    equal(written(Match.State(player.matches[id])), written(Match.Visible(player.matches[id])))
    equal(logOf(seated[1], id), logOf(player, id))
  end
end

function tests.CrazyEightsGoesOnWhenSomeoneResigns()
  local world, seated, id = startedCrowd(3, "crazyeights")
  local Match = seated[1].private.Match
  local before = #Match.State(seated[1].matches[id]).deck
  assert(seated[2].session:Resign(id))
  world:Deliver()
  for _, player in ipairs(seated) do
    local state = player.private.Match.State(player.matches[id])
    equal("active", player.matches[id].status)
    equal(0, #state.hands[2])
    equal(before + 5, #state.deck)
    equal(52, #allCards(state))
  end
  -- The two who are left play it out
  local moves = 0
  while seated[1].matches[id].status == "active" do
    local state = Match.State(seated[1].matches[id])
    local mover = seated[state.turn]
    assert(state.turn ~= 2, "whoever resigned has no more turns")
    local game = mover.private.Games.Get("crazyeights")
    assert(mover.session:Move(id, crazyEightsMove(game, mover.private.Match.State(mover.matches[id]))))
    world:Deliver()
    moves = moves + 1
    assert(moves < 3000, "the game should end")
  end
end

-----------------------------
-- Crazy Eights on screen
-----------------------------

--- The cards of the player's own hand on screen that show a face, left to right
--- @return table[]
local function handOnScreen()
  return Client.Find(function(widget)
    local inHand = widget.kind == "Button" and widget.scripts.OnEnter ~= nil
    return inHand and widget.card ~= nil and widget.card ~= "?" and widget:IsVisible()
  end)
end

--- The backs on screen that are in somebody's hand
--- @return table[]
local function backsOnScreen()
  return Client.Find(function(widget)
    return widget.kind == "Button" and widget.card == "?" and widget.scripts.OnEnter ~= nil and widget:IsVisible()
  end)
end

--- The deck, which is the one card on the table that is seen from the back and isn't in a hand
--- @return table
local function deckOnScreen()
  local found = Client.Find(function(widget)
    local single = widget.kind == "Button" and widget.SetPlayable ~= nil and widget.count ~= nil
    return single and widget.scripts.OnClick ~= nil and widget:IsVisible()
  end)
  assert(#found == 1, "Expected one deck, found " .. #found)
  return found[1]
end

--- @param card string
--- @return table The card of the player's hand showing that face
local function cardOnScreen(card)
  for _, button in ipairs(handOnScreen()) do
    if button.card == card then
      return button
    end
  end
  error("no " .. card .. " in the hand on screen")
end

function tests.WindowPlaysCrazyEights()
  local world, first, second, id = gameOnScreen("crazyeights")
  local Match, game = first.private.Match, first.private.Games.Get("crazyeights")
  local match = first.matches[id]
  equal(7, #handOnScreen(), "the player's own cards, face up")
  equal(7, #backsOnScreen(), "and the opponent's from the back")
  equal(true, says("status_your_turn"))

  -- Whatever was dealt: play a card if one goes, or draw
  local played = 0
  for _ = 1, 40 do
    if match.status ~= "active" then
      break
    end
    local state = Match.State(match)
    if state.turn ~= match.me then
      local before = #match.log
      for _, button in ipairs(handOnScreen()) do
        button:Fire("OnClick")
      end
      deckOnScreen():Fire("OnClick")
      equal(before, #match.log, "nothing can be played or drawn out of turn")
      assert(second.session:Move(id, crazyEightsMove(game, second.private.Match.State(second.matches[id]))))
      world:Deliver()
    else
      local move = crazyEightsMove(game, state)
      local before = #match.log
      if move == "d" then
        equal(true, deckOnScreen().playable)
        deckOnScreen():Fire("OnClick")
        equal("d", match.log[before + 1])
        equal("cardSlide", Client.sounds[#Client.sounds])
      elseif move == "p" then
        Client.Button("crazyeights_pass"):Fire("OnClick")
        equal("p", match.log[before + 1])
      elseif #move == 3 then
        -- An eight: nothing is sent until a suit is called
        cardOnScreen(move:sub(1, 2)):Fire("OnClick")
        equal(before, #match.log)
        equal(true, says("crazyeights_call"))
        local suits = Client.Find(function(widget)
          return widget.kind == "Button" and widget.suit == move:sub(3, 3) and widget:IsVisible()
        end)
        equal(1, #suits)
        suits[1]:Fire("OnClick")
        equal(move, match.log[before + 1])
      else
        -- A card that doesn't go isn't played by clicking it
        for _, button in ipairs(handOnScreen()) do
          if not game.validate(state, match.me, button.card) and button.card:sub(1, 1) ~= "8" then
            button:Fire("OnClick")
          end
        end
        equal(before, #match.log)
        cardOnScreen(move):Fire("OnClick")
        equal(move, match.log[before + 1])
        equal("cardPlace", Client.sounds[#Client.sounds])
        played = played + 1
      end
      world:Deliver()
      equal(logOf(first, id), logOf(second, id))
    end
    -- What is on screen is what the player holds, and as many backs as the opponent does
    if match.status == "active" then
      local state = Match.State(match)
      equal(#state.hands[match.me], #handOnScreen())
      equal(#state.hands[3 - match.me], #backsOnScreen())
      equal(tostring(#state.deck), tostring(deckOnScreen().count:GetText()))
    end
  end
  assert(played > 0, "at least one card should have been played by clicking it")
end

function tests.WindowDealsCrazyEightsOut()
  local world, first, second, id, MainFrame = gameOnScreen("crazyeights")
  local state = first.private.Match.State(first.matches[id])
  local hand, backs, deck = handOnScreen(), backsOnScreen(), deckOnScreen()
  local piles = Client.Find(function(widget)
    return widget.kind == "Button" and widget.card == state.pile[1] and widget.SetPlayable ~= nil
  end)
  equal(1, #piles)

  --- @param cards table[]
  --- @return number How many of them can be seen
  local function arrived(cards)
    local count = 0
    for _, card in ipairs(cards) do
      count = count + (card:GetAlpha() > 0 and 1 or 0)
    end
    return count
  end
  equal(0, arrived(hand), "nobody holds anything before the deal")
  equal(0, arrived(backs))
  equal(0, arrived(piles))
  equal(tostring(#state.deck + 14), tostring(deck.count:GetText()), "all but the first card are still in the deck")

  -- A card at a time, the player's hand and the opponent's filling up together
  local flights = Client.Find(function(widget)
    return widget.flights ~= nil and widget:IsVisible()
  end)
  equal(1, #flights)
  local partly = false
  for _ = 1, 100 do
    flights[1]:Fire("OnUpdate", 0.05)
    local mine, theirs = arrived(hand), arrived(backs)
    assert(math.abs(mine - theirs) <= 1, "dealt in turn, not a hand at a time: " .. mine .. " and " .. theirs)
    partly = partly or (mine > 0 and mine < 7)
    if mine < 7 then
      equal(0, arrived(piles), "the card for the pile is turned up last")
    end
  end
  equal(true, partly, "it takes a while")
  equal(7, arrived(hand))
  equal(7, arrived(backs))
  equal(1, arrived(piles))
  equal(tostring(#state.deck), tostring(deck.count:GetText()))
  equal("cardSlide", Client.sounds[#Client.sounds])
  equal(false, flights[1].flights:Busy())

  -- Once is enough: looking at the game again doesn't deal it again
  MainFrame.Select(nil)
  MainFrame.Select(id)
  equal(7, arrived(handOnScreen()))
  equal(false, flights[1].flights:Busy())

  -- Neither does a game that someone has already played in
  local other = assert(first.session:Invite("Bob-Realm", "crazyeights"))
  world:Deliver()
  assert(second.session:Accept(other.id))
  world:Deliver()
  local mover = first.private.Match.IsMyTurn(other) and first or second
  local game = mover.private.Games.Get("crazyeights")
  assert(mover.session:Move(other.id, crazyEightsMove(game, mover.private.Match.State(mover.matches[other.id]))))
  world:Deliver()
  MainFrame.Select(other.id)
  equal(false, flights[1].flights:Busy())
end

function tests.WindowTurnsTheCardsOverWhenCrazyEightsIsOver()
  local world, first, second, id = gameOnScreen("crazyeights")
  equal(7, #backsOnScreen())
  assert(second.session:Resign(id))
  world:Deliver()
  equal("finished", first.matches[id].status)
  equal(0, #backsOnScreen(), "no secrets once the game is over")
end

-----------------------------
-- Battleship
-----------------------------

-- A fleet along the left edge, a ship to a row from the bottom, and one down the right edge, a
-- ship to a column
local FLEET_ROWS, FLEET_COLUMNS = "a1h.a2h.a3h.a4h.a5h", "j1v.i1v.h1v.g1v.f1v"

function tests.BattleshipBeginsWithBothFleets()
  local private = loadEngine()
  local game = private.Games.Get("battleship")
  local state = game.newState(2, private.Random.New(1))
  equal(1, game.turn(state))
  equal("not_your_turn", select(2, game.validate(state, 2, FLEET_COLUMNS)))
  equal("invalid_move", select(2, game.validate(state, 1, "a1")), "no firing before the fleets are down")

  local wrong = {
    ["a1h.a2h.a3h.a4h"] = "a ship short",
    ["a1h.a2h.a3h.a4h.a5h.a6h"] = "a ship too many",
    ["g1h.a2h.a3h.a4h.a5h"] = "a carrier sticking out over the edge",
    ["a7v.a2h.a3h.a4h.a5h"] = "and over the top",
    ["a1h.a1v.a3h.a4h.a5h"] = "two ships on one square",
    ["a1h.a2h.a3h.a4h.a11h"] = "a square there isn't",
    ["a1h.a2h.a3h.a4h.a05h"] = "a square written another way",
    ["a1h.a2h.a3h.a4h.a5x"] = "a ship lying no way at all",
    ["a1h.a2h.a3h.a4h.a5h."] = "something after the last ship",
  }
  for move, why in pairs(wrong) do
    equal(false, (game.validate(state, 1, move)), why)
  end

  equal(true, (game.validate(state, 1, "f1h.g2h.h3h.h4h.i5h")), "right up to the edge is fine")
  local event = game.apply(state, 1, FLEET_ROWS)
  equal(true, event.placed)
  equal(nil, event.square, "where a fleet lies is nobody else's business")
  equal(2, game.turn(state))
  equal(nil, game.result(state))
  game.apply(state, 2, FLEET_COLUMNS)
  equal(1, game.turn(state), "whoever put their fleet down first fires first")
  equal(5, state.afloat[1])
  equal(1, state.decks[1][4], "the carrier is five long")
  equal(nil, state.decks[1][5])
  equal(1, state.decks[2][49], "and stands four squares up from j1")
  equal(5, state.decks[2][15])
  equal("invalid_move", select(2, game.validate(state, 1, FLEET_ROWS)), "a fleet is put down once")
end

function tests.BattleshipShotsHitMissAndSink()
  local state, game, events = gameAfter("battleship", FLEET_ROWS .. " " .. FLEET_COLUMNS .. " f1 f5 a10")
  equal(true, events[3].hit)
  equal(2, events[3].target)
  equal(5, events[3].square)
  equal(nil, events[3].sunk)
  equal("hit", state.shots[2][5])
  equal(false, events[4].hit, "the sea of the one fired at is what counts, not the shooter's own")
  equal("miss", state.shots[1][45])
  equal(true, events[5].hit == false and state.shots[2][90] == "miss")
  equal(2, game.turn(state))

  equal("already_fired", select(2, game.validate(state, 2, "f5")))
  equal(true, (game.validate(state, 2, "f1")), "what the other player fired at is still open to this one")
  equal("invalid_move", select(2, game.validate(state, 2, "k1")))
  equal("invalid_move", select(2, game.validate(state, 2, "a0")))
  equal("invalid_move", select(2, game.validate(state, 2, "a11")))
  equal("not_your_turn", select(2, game.validate(state, 1, "f2")))

  game.apply(state, 2, "j10")
  local sinking = game.apply(state, 1, "f2")
  equal(5, sinking.sunk, "both squares of the destroyer")
  equal(true, state.fleets[2][5].sunk)
  equal(4, state.afloat[2])
  equal(5, state.afloat[1])
  equal(nil, game.result(state))
end

function tests.BattleshipIsWonBySinkingTheWholeFleet()
  local shots, wide = {}, {}
  for column, length in ipairs({ 2, 3, 3, 4, 5 }) do
    for row = 1, length do
      shots[#shots + 1] = string.char(101 + column) .. row
    end
  end
  for index = 0, 15 do
    wide[#wide + 1] = string.char(97 + index % 10) .. (6 + math.floor(index / 10))
  end
  local moves = { FLEET_ROWS, FLEET_COLUMNS }
  for index = 1, 16 do
    moves[#moves + 1] = shots[index]
    moves[#moves + 1] = wide[index]
  end
  local state, game = gameAfter("battleship", table.concat(moves, " "))
  equal(nil, game.result(state))
  equal(1, state.afloat[2])
  local last = game.apply(state, 1, shots[17])
  equal(1, last.sunk)
  equal(1, game.result(state).winner)
  equal(5, state.afloat[1], "not a scratch on the winner")
end

function tests.BattleshipShowsAPlayerOnlyTheShipsThatWentDown()
  local state, game = gameAfter("battleship", FLEET_ROWS .. " " .. FLEET_COLUMNS .. " f1 a1 f2 j10 j1")
  local seen = game.visible(state, 1)
  equal(0, seen.fleets[1][1].square, "their own fleet, all of it")
  equal(1, seen.fleets[1][1].hits)
  equal(1, seen.decks[1][0])
  equal(5, seen.fleets[2][5].square, "of the other one, the destroyer that went down")
  equal(5, seen.decks[2][15])
  for index = 1, 4 do
    equal(nil, seen.fleets[2][index].square, "not where the rest of them are")
    equal(nil, seen.fleets[2][index].hits, "nor which of them was hit")
    equal(false, seen.fleets[2][index].sunk)
  end
  equal(5, seen.fleets[2][1].size, "how long each is, is no secret")
  equal(nil, seen.decks[2][9])
  equal("hit", seen.shots[2][9], "what a shot did, is told")
  equal(4, seen.afloat[2])

  local theirs = game.visible(state, 2)
  equal(nil, theirs.fleets[1][1].square)
  equal(nil, next(theirs.decks[1]))
  equal(9, theirs.fleets[2][1].square)

  -- What a player sees is a copy: nothing done to it reaches the game
  seen.shots[2][50], seen.fleets[1][1].square = "hit", 77
  equal(nil, state.shots[2][50])
  equal(0, state.fleets[1][1].square)
end

function tests.BattleshipMatchBetweenTwoPlayers()
  local world, seated, id = startedGame("battleship")
  local Match = seated[2].private.Match
  assert(seated[1].session:Move(id, FLEET_ROWS))
  world:Deliver()
  equal(nil, Match.Visible(seated[2].matches[id]).fleets[1][1].square, "the fleet that was sent is not shown to whoever it was sent to")
  equal(false, (seated[2].session:Move(id, "a1")))
  assert(seated[2].session:Move(id, FLEET_COLUMNS))
  world:Deliver()

  -- A shot is answered on the spot, the other player doesn't have to be there for it
  seated[2].online = false
  assert(seated[1].session:Move(id, "j1"))
  local mine = seated[1].private.Match.Visible(seated[1].matches[id])
  equal("hit", mine.shots[2][9])
  equal(nil, mine.fleets[2][1].square)
  seated[2].online = true
  world:Tick(60)
  equal(logOf(seated[1], id), logOf(seated[2], id))
  equal("hit", Match.Visible(seated[2].matches[id]).shots[2][9])

  -- Once the game is over there is nothing left to hide
  assert(seated[2].session:Resign(id))
  world:Deliver()
  equal(9, seated[1].private.Match.Visible(seated[1].matches[id]).fleets[2][1].square)
end

--- Makes the client's dice fall a given way, for a fleet that is put down at random
--- @param rolls number[]
--- @return fun() restore Gives the dice back
local function riggedDice(rolls)
  local real, rolled = math.random, 0
  math.random = function(...)
    rolled = rolled + 1
    return rolls[rolled] or real(...)
  end
  return function()
    math.random = real
  end
end

--- The two seas on screen: the player's own and the other player's
--- @return table fleet, table waters
local function seasOnScreen()
  local found = Client.Find(function(widget)
    return widget.scripts.OnMouseDown and widget.scripts.OnUpdate and widget:IsVisible()
  end)
  assert(#found == 2, "Expected two seas on screen, found " .. #found)
  return found[1], found[2]
end

--- @param sea table
--- @param kind string "Fleet" for ships, "hit" or "miss" for pegs
--- @return number How many of them are drawn on a sea
local function countOn(sea, kind)
  return #Client.Find(function(widget)
    local drawn = widget.kind == "Texture" and widget.parent == sea and widget.shown
    return drawn and tostring(widget.texture):find(kind, 1, true) ~= nil
  end)
end

--- Starts a game of Battleship where the player with the window has their fleet along the left
--- edge to begin with, and is the first to put it down
--- @return World, table first, table second, string id
local function battleshipOnScreen()
  -- Each ship lying across (2), on the first square of a row
  local restore = riggedDice({ 2, 1, 2, 11, 2, 21, 2, 31, 2, 41 })
  local world, first, second, id = gameOnScreen("battleship")
  restore()
  return world, first, second, id
end

function tests.WindowArrangesAFleetAndDeploysIt()
  local world, first, second, id = battleshipOnScreen()
  local fleet, waters = seasOnScreen()
  assert(fleet.width > waters.width * 2, "the sea the fleet is arranged on is the large one")
  assert(fleet.width >= 10 * 28, "and makes use of the window, got " .. fleet.width)
  equal(5, countOn(fleet, "Fleet"))
  equal(0, countOn(waters, "Fleet"))
  local deploy, rotate = Client.Button("battleship_deploy"), Client.Button("battleship_rotate")
  equal(true, deploy.enabled)
  equal(false, rotate.enabled, "nothing in hand to turn")

  -- A click picks the carrier up. Standing up it doesn't fit beside the battleship
  clickSquare(fleet, 0, 0, 10)
  equal(5, countOn(fleet, "Fleet"), "in hand, it is seen where it would go")
  Client.cursor = { -5, -5 }
  fleet:Fire("OnUpdate", 0.02)
  equal(4, countOn(fleet, "Fleet"), "which is nowhere with the cursor off the sea")
  equal(false, deploy.enabled, "not with a ship still in hand")
  equal(true, rotate.enabled)
  equal(true, says("battleship_place"))
  clickSquare(fleet, 3, 0, 10, "RightButton")
  clickSquare(fleet, 3, 0, 10)
  equal(false, deploy.enabled, "d1 and up runs into the battleship on d2")

  -- Pointing at the top row, it goes as far up as it fits
  clickSquare(fleet, 9, 9, 10)
  equal(true, deploy.enabled)
  equal(false, rotate.enabled)
  equal("", logOf(first, id), "nothing is sent while the fleet is being arranged")
  deploy:Fire("OnClick")
  equal("j6v.a2h.a3h.a4h.a5h", logOf(first, id))
  equal(0, #Client.Find(function(widget)
    return widget.kind == "Button" and widget.text == "battleship_deploy" and widget:IsVisible()
  end), "and that is that")
  equal(true, says("battleship_waiting"))
  equal(5, countOn(fleet, "Fleet"))

  -- A click on a ship does nothing any more
  clickSquare(fleet, 0, 1, 10)
  equal(5, countOn(fleet, "Fleet"))
  world:Deliver()
  equal("j6v.a2h.a3h.a4h.a5h", logOf(second, id))
end

function tests.WindowDrawsUpAnotherFleetAtRandom()
  local world, first, second, id = battleshipOnScreen()
  local game = first.private.Games.Get("battleship")
  for _ = 1, 20 do
    Client.Button("battleship_random"):Fire("OnClick")
  end
  Client.Button("battleship_deploy"):Fire("OnClick")
  local log = logOf(first, id)
  assert(log ~= "" and log ~= FLEET_ROWS, "another fleet than the one it began with, got " .. log)
  equal(true, (game.validate(game.newState(2), 1, log)))
end

function tests.WindowLetsTheSecondPlayerArrangeWhileWaiting()
  local world = World.New()
  world.seed = 1
  local first, second = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  local match = assert(first.session:Invite("Bob-Realm", "battleship"))
  world:Deliver()
  assert(second.session:Accept(match.id))
  world:Deliver()
  local restore = riggedDice({ 2, 1, 2, 11, 2, 21, 2, 31, 2, 41 })
  openWindow(second).Open(match.id)
  restore()

  local fleet = seasOnScreen()
  local deploy = Client.Button("battleship_deploy")
  equal(false, deploy.enabled, "the other player sends theirs first")
  equal(true, says("battleship_ready_early"))
  clickSquare(fleet, 0, 4, 10)
  clickSquare(fleet, 8, 9, 10)
  equal(false, deploy.enabled)

  assert(first.session:Move(match.id, FLEET_COLUMNS))
  world:Deliver()
  equal(true, deploy.enabled)
  deploy:Fire("OnClick")
  equal(FLEET_COLUMNS .. ",a1h.a2h.a3h.a4h.i10h", logOf(second, match.id), "arranged the way it was left")
end

function tests.WindowFiresAtTheOtherSea()
  local world, first, second, id = battleshipOnScreen()
  local fleet, waters = seasOnScreen()
  Client.Button("battleship_deploy"):Fire("OnClick")
  world:Deliver()
  clickSquare(waters, 0, 0, 10)
  equal(FLEET_ROWS, logOf(first, id), "no firing until both fleets are down")
  assert(second.session:Move(id, FLEET_COLUMNS))
  world:Deliver()
  assert(waters.width > fleet.width * 2, "now the sea to fire at is the large one")
  equal(true, says("status_your_turn"))

  -- f1 is the stern of their destroyer
  clickSquare(waters, 5, 0, 10)
  equal(FLEET_ROWS .. "," .. FLEET_COLUMNS .. ",f1", logOf(first, id))
  equal("dieThrow", Client.sounds[#Client.sounds])
  equal(1, countOn(waters, "hit"))
  equal(true, says("battleship_you_hit"))
  equal(0, countOn(waters, "Fleet"), "a hit doesn't show the ship")
  clickSquare(waters, 5, 1, 10)
  equal(3, #first.matches[id].log, "not on the other player's turn")

  world:Deliver()
  assert(second.session:Move(id, "j10"))
  world:Deliver()
  equal("cardSlide", Client.sounds[#Client.sounds])
  equal(1, countOn(fleet, "miss"))
  equal(true, says("battleship_they_missed"))

  clickSquare(waters, 5, 0, 10)
  equal(4, #first.matches[id].log, "nor at a square that was fired at before")
  clickSquare(waters, 5, 1, 10)
  equal(5, #first.matches[id].log)
  equal(2, countOn(waters, "hit"))
  equal(1, countOn(waters, "Fleet"), "a ship that went down is there to see")
  equal(true, says("battleship_you_sank"))
end

function tests.WindowChangesTheSeasOverAndShowsTheOtherFleetInTheEnd()
  local world, first, second, id = battleshipOnScreen()
  local fleet, waters = seasOnScreen()
  Client.Button("battleship_deploy"):Fire("OnClick")
  world:Deliver()
  assert(second.session:Move(id, FLEET_COLUMNS))
  world:Deliver()
  assert(waters.width > fleet.width)

  -- A click on the small one, which a button lies over
  local swap = Client.Find(function(widget)
    return widget.kind == "Button" and widget.text == nil and widget.scripts.OnClick and widget.scripts.OnEnter and widget:IsVisible()
  end)
  equal(1, #swap)
  swap[1]:Fire("OnClick")
  assert(fleet.width > waters.width, "the player's own sea, for a closer look")
  swap[1]:Fire("OnClick")
  assert(waters.width > fleet.width)

  equal(0, countOn(waters, "Fleet"))
  assert(second.session:Resign(id))
  world:Deliver()
  equal(5, countOn(waters, "Fleet"), "no secrets once the game is over")
end

-----------------------------
-- Word lists
-----------------------------

function tests.LexiconFindsPackedWordsAndNames()
  local Lexicon = loadEngine().Lexicon
  Lexicon.Pack("pets", 3, "CATDOGEEL")
  Lexicon.Names("pets", "hero", "Kael'thas Yogg-Saron", 2)
  Lexicon.Names("pets", "bird", "Anzu")

  for _, word in ipairs({ "CAT", "DOG", "EEL", "KAELTHAS", "YOGGSARON", "ANZU" }) do
    equal(true, Lexicon.Has("pets", word), word)
  end
  for _, word in ipairs({ "COW", "CA", "ATD", "CATS", "", "Kael'thas", "cat" }) do
    equal(false, Lexicon.Has("pets", word), word)
  end
  equal(false, Lexicon.Has("nothing", "CAT"))

  local entry = Lexicon.Entry("pets", "KAELTHAS")
  equal("Kael'thas", entry.name)
  equal("hero", entry.group)
  equal(2, entry.rank)
  equal(1, Lexicon.Entry("pets", "ANZU").rank)
  equal(nil, Lexicon.Entry("pets", "CAT"), "a packed word is only a word")
  equal(6, Lexicon.Count("pets"))
  equal(false, pcall(Lexicon.Names, "pets", "bird", "Anzu"), "the same name twice is a mistake in the data")
end

function tests.LexiconStampChangesWithWhatAListRules()
  local function stamp(change)
    local Lexicon = loadEngine().Lexicon
    Lexicon.Pack("pets", 3, "CATDOG")
    Lexicon.Names("pets", "bird", "Anzu")
    change(Lexicon)
    return Lexicon.Stamp("pets")
  end
  local plain = stamp(function() end)
  equal(plain, stamp(function() end))
  equal(plain, stamp(function(Lexicon)
    Lexicon.Names("other", "bird", "Rukhmar")
  end))
  for label, change in pairs({
    ["another length"] = function(Lexicon)
      Lexicon.Pack("pets", 4, "BEAR")
    end,
    ["another name"] = function(Lexicon)
      Lexicon.Names("pets", "bird", "Rukhmar")
    end,
    ["a name worth more"] = function(Lexicon)
      Lexicon.Names("pets", "bird", "Rukhmar", 2)
    end,
  }) do
    assert(plain ~= stamp(change), label)
  end
  assert(stamp(function(Lexicon)
    Lexicon.Names("pets", "bird", "Rukhmar")
  end) ~= stamp(function(Lexicon)
    Lexicon.Names("pets", "bird", "Rukhmar", 2)
  end))
end

function tests.EnglishHasItsWords()
  local Lexicon = loadEngine().Lexicon
  equal(168551, Lexicon.Count("english"))
  -- The first and the last of a length, and something of every length in between
  local words = { "AA", "YO", "AAH", "ZOO", "QUEST", "ZYZZYVA", "ZYZZYVAS", "ABANDONED", "AARDVARKS", "ZYGOMORPHIC" }
  words[#words + 1] = "UNCOPYRIGHTABLE"
  words[#words + 1] = "DERMATOGLYPHICS"
  for _, word in ipairs({ "TREE", "HOUSES", "FARMERS", "THUNDERING", "QUARTERSTAFF", "KINDERGARTNER", "RESPONSIBILITY" }) do
    words[#words + 1] = word
  end
  for _, word in ipairs(words) do
    equal(true, Lexicon.Has("english", word), word)
  end
  for _, word in ipairs({ "STORMWIND", "ZZ", "A", "QUESTT", "UEST", "COUNTERREVOLUTIONARIES" }) do
    equal(false, Lexicon.Has("english", word), word)
  end
end

function tests.WarcraftNamesAreWordsForTheBoard()
  -- Loaded by hand, to look at every name as it is added
  local private = { L = {} }
  for _, file in ipairs({ "Engine/Random.lua", "Engine/Lexicon.lua" }) do
    assert(loadfile(file))(ADDON_NAME, private)
  end
  local strings = assert(io.open("Locales/enUS.lua")):read("*a")
  local add, count, groups = private.Lexicon.Names, 0, {}
  private.Lexicon.Names = function(list, group, names, rank)
    equal("warcraft", list)
    assert(rank == nil or rank == 2, "ranks are 1 and 2")
    for name in names:gmatch("%S+") do
      local letters = name:gsub("[^%a]", "")
      assert(#letters >= 3 and #letters <= 15, name .. " doesn't fit")
      assert(not name:find("[^%a'%-]"), name .. " has something in it that isn't a letter")
      count = count + 1
    end
    groups[group] = true
    add(list, group, names, rank)
  end
  assert(loadfile("Lexicon/Warcraft.lua"))(ADDON_NAME, private)

  assert(count > 700, "most of the list is missing")
  for group in pairs(groups) do
    assert(strings:find('L["words_group_' .. group .. '"]', 1, true), "no name for the group " .. group)
  end
  local Lexicon = private.Lexicon
  equal(2, Lexicon.Entry("warcraft", "THRALL").rank)
  equal(2, Lexicon.Entry("warcraft", "THUNDERFURY").rank)
  equal("item", Lexicon.Entry("warcraft", "THUNDERFURY").group)
  equal(1, Lexicon.Entry("warcraft", "STORMWIND").rank)
  equal("Kael'thas", Lexicon.Entry("warcraft", "KAELTHAS").name)
  equal(true, Lexicon.Has("warcraft", "DPS"))
end

-----------------------------
-- Words with Warcraft
-----------------------------

--- @param text string
--- @return string[] Its characters, one tile each
local function tilesOf(text)
  local tiles = {}
  for tile in text:gmatch(".") do
    tiles[#tiles + 1] = tile
  end
  return tiles
end

--- A position set up by hand
--- @param racks string[] By seat, the tiles held written as one word
--- @param bag string? The next tile to be drawn last
--- @param lying table<string, string>? Words on the board already, by the move that would lay them without its dot: aD8 = "HOUSE"
--- @return table state, table game, table random
local function wordsAt(racks, bag, lying)
  local private = loadEngine()
  local game = private.Games.Get("words")
  local state = game.newState(#racks, private.Random.New(1))
  state.bag, state.board = tilesOf(bag or ""), {}
  for seat, rack in ipairs(racks) do
    state.racks[seat] = tilesOf(rack)
  end
  for from, word in pairs(lying or {}) do
    local column, row = from:byte(2) - 65, tonumber(from:sub(3)) - 1
    for index = 1, #word do
      local across = from:sub(1, 1) == "a"
      state.board[(row + (across and 0 or index - 1)) * 15 + column + (across and index - 1 or 0)] = word:sub(index, index)
    end
  end
  return state, game, private.Random.New(3)
end

--- @param rack string[]
--- @return string The tiles of a rack in alphabetical order, as one word
local function held(rack)
  local tiles = { unpack(rack) }
  table.sort(tiles)
  return table.concat(tiles)
end

function tests.WordsListsGoWithItsVersion()
  local private = loadEngine()
  -- The word lists are rules. If this fails one of them has changed: players on the old list
  -- and on the new one mustn't meet, so give the game in Games/Words.lua a new version, and then
  -- write that version and the new numbers here
  equal(1, private.Games.Get("words").version)
  equal(365510098, private.Lexicon.Stamp("english"), "the English list changed")
  equal(1614400711, private.Lexicon.Stamp("warcraft"), "the Warcraft list changed")
end

function tests.WordsDealsEveryoneSevenTiles()
  local private = loadEngine()
  local game = private.Games.Get("words")
  for _, seats in ipairs({ 2, 3, 4 }) do
    local state = game.newState(seats, private.Random.New(5))
    local all = { unpack(state.bag) }
    for seat = 1, seats do
      equal(7, #state.racks[seat])
      equal(0, state.scores[seat])
      for _, tile in ipairs(state.racks[seat]) do
        all[#all + 1] = tile
      end
    end
    equal(104, #all)
    equal(104 - 7 * seats, #state.bag)
    local text = held(all)
    equal(12, select(2, text:gsub("E", "")))
    equal(1, select(2, text:gsub("Q", "")))
    equal(2, select(2, text:gsub("_", "")))
    equal(1, game.turn(state))
    equal(nil, game.result(state))
  end

  local one, other = game.newState(2, private.Random.New(5)), game.newState(2, private.Random.New(5))
  equal(table.concat(one.bag), table.concat(other.bag), "the same chance deals the same tiles")
  assert(table.concat(one.bag) ~= table.concat(game.newState(2, private.Random.New(6)).bag))
end

function tests.WordsFirstWordLiesOnTheMiddle()
  local state, game, random = wordsAt({ "HOUSEXY", "AAAAAAA" }, "TTTTTTTTT")
  equal("words_off_centre", select(2, game.validate(state, 1, "aA1.HOUSE")))
  equal("words_off_centre", select(2, game.validate(state, 1, "aI8.HOUSE")))
  equal("words_too_short", select(2, game.validate(state, 1, "aH8.H")))
  equal("not_your_turn", select(2, game.validate(state, 2, "aH8.AA")))
  equal(true, game.validate(state, 1, "dH4.HOUSE"))
  equal(true, game.validate(state, 1, "aD8.HOUSE"))

  local event = game.apply(state, 1, "aD8.HOUSE", random)
  -- H3 O1 U1 doubled S1 E1, and the middle square doubles the word
  equal(16, event.score)
  equal(16, state.scores[1])
  equal("D8 HOUSE +16", event.notation)
  equal(1, #event.words)
  equal("HOUSE", event.words[1].text)
  equal(7 * 15 + 3, event.words[1].square)
  equal(true, event.words[1].across)
  equal("H", state.board[7 * 15 + 3])
  equal("E", state.board[7 * 15 + 7])
  equal(2, game.turn(state))
end

function tests.WordsDrawsBackUpToSeven()
  local state, game, random = wordsAt({ "HOUSEXY", "AAAAAAA" }, "ZTTTTTTQJ")
  local event = game.apply(state, 1, "aD8.HOUSE", random)
  equal(5, event.drew)
  equal("JQTTTXY", held(state.racks[1]))
  equal("ZTTT", table.concat(state.bag))
  equal(false, event.allTiles)
  for _, value in pairs(event) do
    assert(type(value) ~= "string" or not value:find("[JQ]"), "what was drawn is nobody else's business")
  end
end

function tests.WordsRejectsWhatCantBeLaid()
  local state, game = wordsAt({ "HOUSEXY", "AAAAAAA" }, "TTTTTTTTT")
  for move, err in pairs({
    ["aD8.HORSE"] = "words_not_held",
    ["aD8.HOUSS"] = "words_not_held",
    ["aD8.HOUsE"] = "words_not_held",
    ["aD8.HOUXE"] = "words_not_a_word",
    ["aD8.HO_SE"] = "invalid_move",
    ["aD8._HOUSE"] = "invalid_move",
    ["aD8.HOUSE_"] = "invalid_move",
    ["aL8.HOUSE"] = "invalid_move",
    ["dH12.HOUSE"] = "invalid_move",
    ["aD0.HOUSE"] = "invalid_move",
    ["aD08.HOUSE"] = "invalid_move",
    ["aD16.HOUSE"] = "invalid_move",
    ["aP8.HOUSE"] = "invalid_move",
    ["bD8.HOUSE"] = "invalid_move",
    ["aD8.HOU5E"] = "invalid_move",
    ["aD8."] = "invalid_move",
    ["aD8HOUSE"] = "invalid_move",
    ["x."] = "invalid_move",
    ["x.he"] = "invalid_move",
    ["x.HH"] = "words_not_held",
    ["pp"] = "invalid_move",
  }) do
    local ok, code = game.validate(state, 1, move)
    equal(false, ok, move)
    equal(err, code, move)
  end
end

function tests.WordsJoinWhatIsOnTheBoard()
  local state, game, random = wordsAt({ "ONSTXYZ", "AAAAAAA" }, "", { aD8 = "HOUSE" })
  equal("words_not_joined", select(2, game.validate(state, 1, "aA1.ON")))
  equal("words_not_joined", select(2, game.validate(state, 1, "aD10.ON")))
  equal("words_not_joined", select(2, game.validate(state, 1, "aA1.N")))
  equal("invalid_move", select(2, game.validate(state, 1, "aD8.ON")), "not onto tiles that lie there")
  equal("invalid_move", select(2, game.validate(state, 1, "dE7.NO")))
  equal("words_not_a_word", select(2, game.validate(state, 1, "aC8.X")), "XHOUSE")
  equal("words_not_a_word", select(2, game.validate(state, 1, "aE9.ZN")), "the words made the other way count too")
  equal(true, game.validate(state, 1, "dE7.N"), "NO, down to a tile that lies there")
  equal(true, game.validate(state, 1, "dF7.S_N"), "SUN, through one")
  equal("invalid_move", select(2, game.validate(state, 1, "dE7.N_")), "a move is written from its first tile to its last")
  equal("invalid_move", select(2, game.validate(state, 1, "dE8._N")))
  equal(true, game.validate(state, 1, "aI8.S"), "onto the end of a word")
  equal(true, game.validate(state, 1, "dI8.S"), "which is the same move either way")

  -- ON under HO: O tripled and N make ON for 4, H and the tripled O make HO for 6, O and N make ON for 2
  local event = game.apply(state, 1, "aD9.ON", random)
  equal(12, event.score)
  equal(3, #event.words)
  equal("ON", event.words[1].text)
  equal(4, event.words[1].score)
  equal("HO", event.words[2].text)
  equal(false, event.words[2].across)
  equal(7 * 15 + 3, event.words[2].square)
  equal(6, event.words[2].score)
  equal(2, event.words[3].score)
  equal("D9 ON +12", event.notation)
end

function tests.WordsCountsASquareOnlyOnce()
  local state, game, random = wordsAt({ "SSSSSSS", "AAAAAAA" }, "", { aD8 = "HOUSE" })
  local event = game.apply(state, 1, "aI8.S", random)
  equal("HOUSES", event.words[1].text)
  equal(8, event.score, "neither the doubled U nor the middle square again")
  equal(1, #event.words)
end

function tests.WordsBlanksStandForAnyLetterAndScoreNothing()
  local state, game, random = wordsAt({ "HOU_EXY", "SAAAAAA" }, "")
  equal("words_not_held", select(2, game.validate(state, 1, "aD8.HOUSE")))
  local event = game.apply(state, 1, "aD8.HOUsE", random)
  equal(14, event.score)
  equal("HOUSE", event.words[1].text)
  equal("s", state.board[7 * 15 + 6])
  equal("XY", held(state.racks[1]))

  -- It is worth nothing to whoever builds on it either: U S E S, with the blank's square not counted again
  event = game.apply(state, 2, "aI8.S", random)
  equal(7, event.score)
end

function tests.WordsFromAzerothAreWorthMore()
  local state, game, random = wordsAt({ "QUESTXY", "JAINAXY" }, "")
  local event = game.apply(state, 1, "aD8.QUEST", random)
  -- Q10 U1 E1 doubled S1 T1, the word doubled, and 5 for being one of ours
  equal(35, event.score)
  equal("slang", event.words[1].lore.group)
  equal("Quest", event.words[1].lore.name)

  state, game, random = wordsAt({ "JAINAXY", "AAAAAAA" }, "")
  equal("words_not_a_word", select(2, game.validate(state, 1, "aD8.JAINX")))
  event = game.apply(state, 1, "aD8.JAINA", random)
  -- J8 A1 I1 doubled N1 A1, the word doubled, and 15 for a name everyone knows
  equal(41, event.score)
  equal(2, event.words[1].lore.rank)
  equal(41, event.words[1].score)

  state, game, random = wordsAt({ "PSLFGXY", "AAAAAAA" }, "", { aD8 = "HOUSE" })
  event = game.apply(state, 1, "dD9.PS", random)
  equal("HPS", event.words[1].lore.name)
  -- H3 P3 tripled S1 and 5
  equal(18, event.score)
  state, game, random = wordsAt({ "STORMWI", "AAAAAAA" }, "", { aK8 = "ND" })
  event = game.apply(state, 1, "aD8.STORMWI", random)
  equal("STORMWIND", event.words[1].text)
  equal("city", event.words[1].lore.group)
  equal(true, event.allTiles)
end

function tests.WordsLayingAllSevenTilesIsABonus()
  local state, game, random = wordsAt({ "FARMERS", "AAAAAAA" }, "TTT")
  local event = game.apply(state, 1, "aB8.FARMERS", random)
  -- F4 A1 doubled R1 M3 E1 doubled R1 S1, the word doubled, and 50
  equal(78, event.score)
  equal(true, event.allTiles)
  equal(3, event.drew)
  equal(nil, game.result(state), "three tiles drawn, the game goes on")
end

function tests.WordsSwapsTilesForOthers()
  local state, game, random = wordsAt({ "QQQAEI_", "AAAAAAA" }, "TTTTTTT")
  equal(true, game.validate(state, 1, "x.QQ_"))
  equal("words_not_held", select(2, game.validate(state, 1, "x.QQQQ")))
  local event = game.apply(state, 1, "x.QQ_", random)
  equal(3, event.swapped)
  equal("AEIQTTT", held(state.racks[1]), "new tiles first, none of those given back")
  equal("QQTTTT_", held(state.bag))
  equal(0, state.scores[1])
  equal(2, game.turn(state))
  equal("words_swapped", event.notation)

  state, game = wordsAt({ "QQQAEI_", "AAAAAAA" }, "TTTTTT")
  equal("words_cant_swap", select(2, game.validate(state, 1, "x.Q")))
end

function tests.WordsEndsWhenSomeoneRunsOutOfTiles()
  local state, game, random = wordsAt({ "ON", "QZAAAAA" }, "", { aD8 = "HOUSE" })
  state.scores = { 10, 40 }
  local event = game.apply(state, 1, "aD9.ON", random)
  -- What the other is left holding, Q10 Z8 and five As: taken from them and given to whoever went out
  equal(23, event.settled[1])
  equal(-23, event.settled[2])
  equal(10 + 12 + 23, state.scores[1])
  equal(40 - 23, state.scores[2])
  local result = game.result(state)
  equal(1, result.winner)
  equal("words_out", result.detail)

  state, game, random = wordsAt({ "ON", "QZAAAAA" }, "T", { aD8 = "HOUSE" })
  game.apply(state, 1, "aD9.ON", random)
  equal(nil, game.result(state), "not while there is a tile to draw")
  equal("T", held(state.racks[1]))
end

function tests.WordsEndsWhenNobodyLaysAnything()
  local state, game, random = wordsAt({ "QAAAAAA", "ZAAAAAA" }, "TTTTTTTT")
  state.scores = { 30, 30 }
  game.apply(state, 1, "p", random)
  game.apply(state, 2, "x.Z", random)
  local event = game.apply(state, 1, "p", random)
  equal(nil, game.result(state))
  equal(nil, event.settled)
  equal(true, event.passed)
  event = game.apply(state, 2, "p", random)
  equal(-16, event.settled[1])
  equal(-7, event.settled[2])
  local result = game.result(state)
  equal(2, result.winner, "everyone loses what they hold, and that was the Q")
  equal("words_passes", result.detail)

  -- Laying something starts the count again
  state, game, random = wordsAt({ "ONAAAAA", "AAAAAAA" }, "", { aD8 = "HOUSE" })
  for _, move in ipairs({ "p", "p", "aD9.ON", "p", "p", "p" }) do
    game.apply(state, game.turn(state), move, random)
  end
  equal(nil, game.result(state))
  game.apply(state, game.turn(state), "p", random)
  equal(1, game.result(state).winner)

  state, game, random = wordsAt({ "AAAAAAA", "AAAAAAA" }, "")
  for _ = 1, 4 do
    game.apply(state, game.turn(state), "p", random)
  end
  equal(0, game.result(state).winner, "level is a draw")
end

function tests.WordsShowsNobodyTheBagOrAnotherRack()
  local state, game = wordsAt({ "HOUSEXY", "QZAAAAA", "TTT" }, "JK", { aD8 = "HOUSE" })
  local seen = game.visible(state, 2)
  equal("QZAAAAA", table.concat(seen.racks[2]))
  equal("???????", table.concat(seen.racks[1]))
  equal("???", table.concat(seen.racks[3]))
  equal("??", table.concat(seen.bag))
  equal("H", seen.board[7 * 15 + 3])
  equal(state.scores, seen.scores)
  equal("HOUSEXY", table.concat(state.racks[1]), "the game itself is left alone")
  equal("JK", table.concat(state.bag))
end

function tests.WordsGoesOnWithoutAPlayerWhoResigned()
  local state, game, random = wordsAt({ "AAAAAAA", "QZ", "EEEEEEE" }, "TT")
  state.scores = { 5, 90, 5 }
  game.apply(state, 1, "p", random)
  game.drop(state, 2)
  equal(3, game.turn(state), "their turn goes to the next player")
  equal("ZQTT", table.concat(state.bag), "their tiles are under the bag")
  equal(0, #state.racks[2])
  game.drop(state, 1)
  equal(3, game.turn(state))

  state, game, random = wordsAt({ "AAAAAAA", "QZ", "EEEEEEA" }, "")
  state.scores = { 5, 90, 5 }
  game.drop(state, 2)
  for _ = 1, 4 do
    game.apply(state, game.turn(state), "p", random)
  end
  equal(0, game.result(state).winner, "whoever resigned can't win, however far ahead")
end

function tests.WordsIsPlayedBetweenTwoPlayers()
  local world = World.New()
  local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  local match = assert(alice.session:Invite("Bob-Realm", "words"))
  world:Deliver()
  assert(bob.session:Accept(match.id))
  world:Deliver()
  local id = match.id
  local first = match.me == 1 and alice or bob
  local second = first == alice and bob or alice
  local Match = first.private.Match

  local mine, theirs = Match.Visible(first.matches[id]), Match.Visible(second.matches[id])
  equal(7, #mine.racks[1])
  assert(not table.concat(mine.racks[1]):find("?", 1, true), "a player sees their own tiles")
  equal("???????", table.concat(mine.racks[2]))
  equal("???????", table.concat(theirs.racks[1]))
  equal(table.concat(mine.racks[1]), table.concat(second.private.Match.State(second.matches[id]).racks[1]), "both were dealt the same")

  equal(false, (second.session:Move(id, "p")), "not out of turn")
  equal(false, (first.session:Move(id, "aH8.QQQQQQQ")))
  assert(first.session:Move(id, "x." .. table.concat(mine.racks[1], "", 1, 3)))
  world:Deliver()
  equal(logOf(first, id), logOf(second, id))
  equal(table.concat(Match.State(first.matches[id]).bag), table.concat(second.private.Match.State(second.matches[id]).bag))

  play(world, id, second, first, { "p", "p", "p" })
  local result = Match.Result(first.matches[id])
  equal("words_passes", result.detail)
  equal(result.winner, second.private.Match.Result(second.matches[id]).winner)
  assert(not table.concat(Match.Visible(first.matches[id]).racks[2]):find("?", 1, true), "no secrets once the game is over")
end

function tests.WordsIsPlayedByACrowd()
  local world, seated, id = startedCrowd(3, "words")
  local Match = seated[1].private.Match
  for _ = 1, 6 do
    local turn = Match.Turn(seated[1].matches[id])
    local mover
    for _, player in ipairs(seated) do
      if player.matches[id].me == turn then
        mover = player
      end
    end
    assert(mover.session:Move(id, "p"))
    world:Deliver()
  end
  for _, player in ipairs(seated) do
    equal("words_passes", player.private.Match.Result(player.matches[id]).detail)
    equal(logOf(seated[1], id), logOf(player, id))
  end
end

-----------------------------
-- Viewport
-----------------------------

--- A window 300 wide and 200 high onto something 200 square, so it fits with room at the sides.
--- The fake client has every frame's bottom left corner in that of the screen
--- @param options table?
--- @return table viewport
local function viewportOnScreen(options)
  Client.Install()
  local private = {}
  assert(loadfile("GUI/Viewport.lua"))(ADDON_NAME, private)
  local viewport = private.Viewport.New(UIParent, options)
  viewport:SetSize(300, 200)
  viewport:SetContentSize(200, 200)
  return viewport
end

--- Puts the cursor on a point of a viewport's window, right and down from its top left corner
local function pointAt(viewport, x, y)
  Client.cursor = { x, viewport.height - y }
end

--- Lets time pass, so whatever is on its way gets there
local function wait(frame)
  for _ = 1, 30 do
    frame:Fire("OnUpdate", 0.02)
  end
end

local function near(expected, actual, label)
  if math.abs(expected - actual) > 0.0001 then
    error(string.format("%s: expected %s, got %s", label or "value", tostring(expected), tostring(actual)), 2)
  end
end

function tests.ViewportZoomsInOnWhatIsUnderTheCursor()
  local settled = {}
  local viewport = viewportOnScreen({
    onSettle = function(zoom)
      settled[#settled + 1] = zoom
    end,
  })
  equal(1, viewport.zoom)
  equal(50, viewport.x, "what fits lies in the middle")
  equal(0, viewport.y)

  -- Over the middle of the content
  pointAt(viewport, 150, 100)
  viewport.frame:Fire("OnMouseWheel", 3)
  equal(false, viewport:Fits())
  equal(1, viewport.zoom, "it glides there")
  for _ = 1, 4 do
    viewport.frame:Fire("OnUpdate", 0.02)
    assert(viewport.zoom > 1 and viewport.zoom < 1.25 ^ 3)
    near(100, (150 - viewport.x) / viewport.zoom, "the point under the cursor stays there on the way")
    near(100, (100 - viewport.y) / viewport.zoom)
  end
  wait(viewport.frame)
  near(1.25 ^ 3, viewport.zoom)
  near(100, (150 - viewport.x) / viewport.zoom)
  near(100, (100 - viewport.y) / viewport.zoom)

  viewport.frame:Fire("OnMouseWheel", 10)
  wait(viewport.frame)
  equal(3, viewport.zoom, "no closer than that")
  viewport.frame:Fire("OnMouseWheel", 1)
  equal(nil, viewport.move)

  viewport.frame:Fire("OnMouseWheel", -20)
  wait(viewport.frame)
  equal(1, viewport.zoom)
  equal(50, viewport.x)
  equal(0, viewport.y)
  equal(true, viewport:Fits())
  near(1.25 ^ 3, settled[1])
  equal(3, settled[2])
  equal(1, settled[3])
  equal(3, #settled)
end

function tests.ViewportZoomsAsFarAsItIsTold()
  local viewport = viewportOnScreen({ maxZoom = 1.5 })
  pointAt(viewport, 150, 100)
  viewport.frame:Fire("OnMouseWheel", 5)
  wait(viewport.frame)
  equal(1.5, viewport.zoom)
  -- One notch back is so nearly all of it that it is all of it
  viewport.frame:Fire("OnMouseWheel", -2)
  wait(viewport.frame)
  equal(1, viewport.zoom)
end

function tests.ViewportIsDraggedAboutButNotPastItsEdges()
  local viewport = viewportOnScreen()
  pointAt(viewport, 150, 100)
  Client.mouseDown = true
  viewport:Grab()
  pointAt(viewport, 250, 150)
  viewport.frame:Fire("OnUpdate", 0.02)
  equal(50, viewport.x, "what fits stays where it is")
  equal(0, viewport.y)
  Client.mouseDown = false
  viewport.frame:Fire("OnUpdate", 0.02)

  viewport:ZoomTo(2, 100, 100, true)
  equal(2, viewport.zoom)
  equal(-50, viewport.x)
  equal(-100, viewport.y)

  pointAt(viewport, 150, 100)
  Client.mouseDown = true
  viewport.frame:Fire("OnMouseDown", "RightButton")
  pointAt(viewport, 152, 101)
  viewport.frame:Fire("OnUpdate", 0.02)
  equal(-50, viewport.x, "a click that slipped isn't a drag")
  pointAt(viewport, 180, 120)
  viewport.frame:Fire("OnUpdate", 0.02)
  equal(-20, viewport.x)
  equal(-80, viewport.y)
  pointAt(viewport, 1000, -1000)
  viewport.frame:Fire("OnUpdate", 0.02)
  equal(0, viewport.x, "its left edge at the window's, and no further")
  equal(-200, viewport.y, "and its bottom edge")

  Client.mouseDown = false
  viewport.frame:Fire("OnUpdate", 0.02)
  pointAt(viewport, 150, 100)
  viewport.frame:Fire("OnUpdate", 0.02)
  equal(0, viewport.x, "let go")
end

function tests.ViewportGoesWhereItIsSent()
  local viewport = viewportOnScreen()
  viewport:ZoomTo(2, 0, 0)
  equal(1, viewport.zoom)
  equal(false, viewport:Fits())
  wait(viewport.frame)
  equal(2, viewport.zoom)
  equal(0, viewport.x, "a corner can't come to the middle, only as near as the edges allow")
  equal(0, viewport.y)

  viewport:ZoomTo(2, 150, 50)
  wait(viewport.frame)
  equal(2, viewport.zoom)
  equal(-100, viewport.x)
  equal(0, viewport.y)

  viewport:ZoomTo(50, 100, 100, true)
  equal(3, viewport.zoom)
  viewport:Fit(true)
  equal(1, viewport.zoom)
  equal(50, viewport.x)

  -- Hidden on the way, it is there when it is next seen
  viewport:ZoomTo(2, 100, 100)
  viewport.frame:Fire("OnHide")
  equal(2, viewport.zoom)
  equal(-50, viewport.x)
end

function tests.ViewportKeepsToItsEdgesWhenItsRoomChanges()
  local viewport = viewportOnScreen()
  viewport:ZoomTo(2, 200, 200, true)
  equal(-100, viewport.x)
  equal(-200, viewport.y)
  viewport:SetSize(500, 450)
  equal(50, viewport.x, "narrower than the window now")
  equal(25, viewport.y, "and less high")
  viewport:SetContentSize(450, 450)
  -- What was zoomed in on before it all fitted, not wherever the middle had to go meanwhile
  equal(-312.5, viewport.x, "wider again: what was in the middle comes back there")
  equal(-450, viewport.y, "as near as the edge allows, with no gap left at it")
end

function tests.ViewportShowsTheSamePartWhenTheWindowIsResized()
  local viewport = viewportOnScreen()
  viewport:SetSize(200, 200)
  viewport:SetContentSize(200, 200)
  viewport:ZoomTo(2, 60, 140, true)
  equal(-20, viewport.x)
  equal(-180, viewport.y)

  -- The window and the board in it are drawn half as big again, the way a game lays itself out
  -- in a window dragged bigger: still zoomed in on the same spot
  viewport:SetSize(300, 300)
  viewport:SetContentSize(300, 300)
  equal(2, viewport.zoom)
  equal(-30, viewport.x)
  equal(-270, viewport.y)
end

function tests.ViewportFollowsTheCursorToAnEdge()
  local viewport = viewportOnScreen()
  pointAt(viewport, 5, 100)
  viewport:EdgeScroll(0.05)
  equal(50, viewport.x, "nothing lies beyond the edge of what fits")

  viewport:ZoomTo(2, 100, 100, true)
  pointAt(viewport, 150, 100)
  viewport:EdgeScroll(0.05)
  equal(-50, viewport.x)
  pointAt(viewport, 5, 100)
  viewport:EdgeScroll(0.05)
  equal(-26, viewport.x, "at the left edge, what lies to the left comes into sight")
  equal(-100, viewport.y)
  viewport:EdgeScroll(1)
  equal(0, viewport.x)
  pointAt(viewport, 295, 195)
  viewport:EdgeScroll(0.05)
  equal(-24, viewport.x)
  equal(-124, viewport.y)
  pointAt(viewport, -5, 100)
  viewport:EdgeScroll(0.05)
  equal(-24, viewport.x, "not with the cursor somewhere else altogether")
end

-----------------------------
-- Drag
-----------------------------

--- Something to carry things across, 400 wide and 300 high, with a tile to pick up. The fake
--- client has every region's bottom left corner in that of the screen
--- @return table drag, table tile, table log What the targets were told, in order
local function dragOnScreen()
  Client.Install()
  local private = {}
  assert(loadfile("GUI/Drag.lua"))(ADDON_NAME, private)
  local stage = CreateFrame("Frame", nil, UIParent)
  stage:SetSize(400, 300)
  local drag = private.Drag.New(stage)
  drag.frame:SetSize(400, 300)
  local tile = stage:CreateTexture()
  tile:SetSize(40, 40)
  return drag, tile, {}
end

--- A place to put things down, as big as it is said to be, that has a left half and a right one
--- @return table target
local function dropTarget(drag, log, name, width, height, refuses)
  local region = CreateFrame("Frame", nil, drag.frame.parent)
  region:SetSize(width, height)
  local target = {
    region = region,
    spot = function(item)
      if item == refuses then
        return nil
      end
      return Client.cursor[1] < width / 2 and "left" or "right"
    end,
    onHover = function(item, spot)
      log[#log + 1] = name .. " hover " .. item .. " " .. tostring(spot)
    end,
    onDrop = function(item, spot)
      log[#log + 1] = name .. " drop " .. item .. " " .. spot
    end,
  }
  drag:AddTarget(target)
  return target
end

--- @return table look
local function lookOf(tile, log)
  return {
    texture = "tile",
    width = 40,
    height = 40,
    from = tile,
    onReturn = function(item)
      log[#log + 1] = "returned " .. item
    end,
  }
end

function tests.DragIsOnlyInTheWayOfTheMouseWhileSomethingIsInHand()
  local drag, tile, log = dragOnScreen()
  dropTarget(drag, log, "rack", 100, 100)
  equal(false, drag.frame:IsMouseEnabled(), "it lies over everything, clicks have to get past it")

  Client.cursor, Client.mouseDown = { 20, 50 }, false
  drag:Carry("Q", lookOf(tile, log))
  equal(true, drag.frame:IsMouseEnabled(), "the next click puts it down")
  drag.frame:Fire("OnMouseDown", "LeftButton")
  equal(false, drag.frame:IsMouseEnabled())

  drag:Carry("Q", lookOf(tile, log))
  drag:Cancel(true)
  equal(false, drag.frame:IsMouseEnabled())
end

function tests.DragCarriesAThingToATarget()
  local drag, tile, log = dragOnScreen()
  dropTarget(drag, log, "rack", 100, 100)

  Client.cursor, Client.mouseDown = { 300, 250 }, true
  drag:Carry("Q", lookOf(tile, log))
  equal("Q", drag:Carrying())
  equal(0, tile:GetAlpha(), "what is carried isn't where it was as well")
  equal(true, drag.texture:IsShown())
  equal(40 * 1.15, drag.texture.width)
  equal(0, #log)

  Client.cursor = { 20, 50 }
  drag.frame:Fire("OnUpdate", 0.02)
  Client.cursor = { 30, 50 }
  drag.frame:Fire("OnUpdate", 0.02)
  Client.cursor = { 80, 50 }
  drag.frame:Fire("OnUpdate", 0.02)
  equal("rack hover Q left,rack hover Q right", table.concat(log, ","), "told once for each place it would land")

  Client.mouseDown = false
  drag.frame:Fire("OnUpdate", 0.02)
  equal("rack hover Q nil", log[3])
  equal("rack drop Q right", log[4])
  equal(4, #log)
  equal(nil, drag:Carrying())
  equal(1, tile:GetAlpha())
  equal(false, drag.texture:IsShown())
end

function tests.DragPutsAThingBackThatWasLetGoNowhere()
  local drag, tile, log = dragOnScreen()
  dropTarget(drag, log, "rack", 100, 100)

  Client.cursor, Client.mouseDown = { 20, 20 }, true
  drag:Carry("Q", lookOf(tile, log))
  Client.cursor = { 300, 250 }
  drag.frame:Fire("OnUpdate", 0.02)
  equal("rack hover Q left,rack hover Q nil", table.concat(log, ","))
  Client.mouseDown = false
  drag.frame:Fire("OnUpdate", 0.02)

  equal(nil, drag:Carrying())
  equal(2, #log, "on its way back")
  equal(0, tile:GetAlpha())
  equal(true, drag.texture:IsShown())
  wait(drag.frame)
  equal("returned Q", log[3])
  equal(1, tile:GetAlpha())
  equal(false, drag.texture:IsShown())
end

function tests.DragPicksUpWithAClickAndPutsDownWithAnother()
  local drag, tile, log = dragOnScreen()
  dropTarget(drag, log, "rack", 100, 100)

  Client.cursor, Client.mouseDown = { 300, 250 }, true
  drag:Carry("Q", lookOf(tile, log))
  Client.cursor = { 301, 251 }
  drag.frame:Fire("OnUpdate", 0.02)
  Client.mouseDown = false
  drag.frame:Fire("OnUpdate", 0.02)
  equal("Q", drag:Carrying(), "a click leaves it in hand")

  Client.cursor = { 80, 50 }
  drag.frame:Fire("OnUpdate", 0.02)
  equal("Q", drag:Carrying(), "and it goes along without a button held")
  drag.frame:Fire("OnMouseDown", "LeftButton")
  equal("rack drop Q right", log[#log])
  equal(nil, drag:Carrying())

  -- Any other button is a change of mind
  Client.cursor, Client.mouseDown = { 300, 250 }, false
  drag:Carry("Z", lookOf(tile, log))
  equal("Z", drag:Carrying(), "in hand from the start with no button held")
  Client.cursor = { 80, 50 }
  drag.frame:Fire("OnUpdate", 0.02)
  drag.frame:Fire("OnMouseDown", "RightButton")
  equal(nil, drag:Carrying())
  equal("rack hover Z nil", log[#log])
  wait(drag.frame)
  equal("returned Z", log[#log])

  drag.frame:Fire("OnMouseDown", "LeftButton")
  equal("returned Z", log[#log], "nothing in hand, nothing to put down")
end

function tests.DragAsksTheTargetsInTurn()
  local drag, tile, log = dragOnScreen()
  local board = dropTarget(drag, log, "board", 200, 200, "Z")
  dropTarget(drag, log, "table", 400, 300)
  -- Only the corner of the board is in sight
  board.clip = CreateFrame("Frame", nil, UIParent)
  board.clip:SetSize(50, 50)

  Client.cursor, Client.mouseDown = { 20, 20 }, false
  drag:Carry("Q", lookOf(tile, log))
  equal("board hover Q left", log[#log])
  Client.cursor = { 120, 120 }
  drag.frame:Fire("OnUpdate", 0.02)
  equal("table hover Q left", log[#log], "the board is there, but not to be seen")
  equal("board hover Q nil", log[#log - 1])
  drag:Cancel(true)
  equal("returned Q", log[#log])

  Client.cursor = { 20, 20 }
  drag:Carry("Z", lookOf(tile, log))
  equal("table hover Z left", log[#log], "what the board won't have lands on what lies under it")
  drag.frame:Fire("OnMouseDown", "LeftButton")
  equal("table drop Z left", log[#log])
end

function tests.DragLetsGoWhenItIsHiddenOrSomethingElseIsPickedUp()
  local drag, tile, log = dragOnScreen()
  dropTarget(drag, log, "rack", 100, 100)
  local other = drag.frame.parent:CreateTexture()

  Client.cursor, Client.mouseDown = { 300, 250 }, true
  drag:Carry("Q", lookOf(tile, log))
  drag.frame:Fire("OnHide")
  equal(nil, drag:Carrying())
  equal("returned Q", log[#log], "at once, there is nobody to show it to")
  equal(1, tile:GetAlpha())

  drag:Carry("Q", lookOf(tile, log))
  drag:Cancel()
  equal(0, tile:GetAlpha(), "on its way back")
  drag:Carry("Z", lookOf(other, log))
  equal(1, tile:GetAlpha(), "the one before is back where it was")
  equal(0, other:GetAlpha())
  equal("Z", drag:Carrying())
  equal("returned Q,returned Q", table.concat(log, ","))
end

-----------------------------
-- Words with Warcraft on screen
-----------------------------

--- A game of Words on screen, with the tiles everyone holds and the bag set by hand for both players
--- @param racks string[] By seat, the tiles held written as one word
--- @param bag string? The next tile to be drawn last
--- @return World, table first, table second, string id
local function wordsOnScreen(racks, bag)
  local world, first, second, id, MainFrame = gameOnScreen("words")
  for _, player in ipairs({ first, second }) do
    local state = player.private.Match.State(player.matches[id])
    state.bag = tilesOf(bag or "")
    for seat, rack in ipairs(racks) do
      state.racks[seat] = tilesOf(rack)
    end
  end
  MainFrame.Refresh()
  return world, first, second, id
end

--- The parts of the game on screen that tests point at
--- @return table
local function wordsWidgets()
  local function one(test, what)
    local found = Client.Find(test)
    assert(#found == 1, "Expected one " .. what .. ", found " .. #found)
    return found[1]
  end
  return {
    board = one(function(widget)
      return widget.wordsBoard
    end, "board"),
    window = one(function(widget)
      return widget.wordsWindow
    end, "window"),
    rack = one(function(widget)
      return widget.wordsRack
    end, "rack"),
    note = one(function(widget)
      return widget.wordsNote
    end, "note"),
    box = one(function(widget)
      return widget.kind == "EditBox" and widget.scripts.OnChar
    end, "box to type in"),
    -- What things are carried on is the one frame that minds the mouse and isn't the board or its window
    drag = one(function(widget)
      local scripts = widget.scripts
      return scripts.OnMouseDown and scripts.OnHide and scripts.OnUpdate and not scripts.OnMouseUp and not widget.wordsWindow
    end, "frame to carry things on"),
    effects = one(function(widget)
      return widget.wordsEffects
    end, "frame for what moves"),
  }
end

--- The tiles in the rack, in the order they lie
--- @return table[] tiles, string letters With "_" for a blank
local function rackOnScreen()
  local tiles = Client.Find(function(widget)
    return widget.wordsHeld and widget:IsVisible()
  end)
  table.sort(tiles, function(a, b)
    return a.index < b.index
  end)
  local letters = {}
  for index, tile in ipairs(tiles) do
    letters[index] = tile.letter.text ~= "" and tile.letter.text or "_"
  end
  return tiles, table.concat(letters)
end

--- @return string The letters of the tiles in the rack in alphabetical order, whatever order they lie in
local function heldOnScreen()
  local letters = tilesOf(select(2, rackOnScreen()))
  table.sort(letters)
  return table.concat(letters)
end

--- The tiles on the board, as "D8=Q E8=U": the ones only laid out so far in brackets
--- @return string
local function boardOnScreen()
  local tiles = Client.Find(function(widget)
    return widget.wordsSquare and widget:IsVisible()
  end)
  table.sort(tiles, function(a, b)
    return a.wordsSquare < b.wordsSquare
  end)
  local said = {}
  for index, tile in ipairs(tiles) do
    local name = string.char(65 + tile.wordsSquare % 15) .. (math.floor(tile.wordsSquare / 15) + 1)
    said[index] = tile.laid and ("(" .. name .. "=" .. tile.letter.text .. ")") or (name .. "=" .. tile.letter.text)
  end
  return table.concat(said, " ")
end

--- Puts the cursor on a square, named the way players say it
local function overSquare(widgets, name)
  local cell = widgets.board.width / 15
  local column, row = name:byte(1) - 65, tonumber(name:sub(2)) - 1
  Client.cursor = { (column + 0.5) * cell, widgets.board.height - (row + 0.5) * cell }
end

--- Drags the first tile in the rack that shows a letter to a square
local function dragTile(widgets, letter, name)
  local tiles, letters = rackOnScreen()
  local at = assert(letters:find(letter, 1, true), "no " .. letter .. " in " .. letters)
  Client.cursor, Client.mouseDown = { 5, 5 }, true
  tiles[at]:Fire("OnMouseDown", "LeftButton")
  overSquare(widgets, name)
  widgets.drag:Fire("OnUpdate", 0.02)
  Client.mouseDown = false
  widgets.drag:Fire("OnUpdate", 0.02)
end

--- Clicks a square of the board
local function clickBoard(widgets, name, button)
  overSquare(widgets, name)
  Client.mouseDown = true
  widgets.board:Fire("OnMouseDown", button or "LeftButton")
  Client.mouseDown = false
  widgets.window:Fire("OnUpdate", 0.02)
  widgets.board:Fire("OnMouseUp", button or "LeftButton")
end

local function typeWord(widgets, word)
  for letter in word:gmatch(".") do
    widgets.box:Fire("OnChar", letter)
  end
end

function tests.WindowLaysOutTilesAndPlaysThem()
  local world, first, second, id = wordsOnScreen({ "QUESTXY", "AAAAAAA" }, "ZZZZZEEEEE")
  local widgets = wordsWidgets()
  local play = Client.Button("words_play")
  assert(widgets.board.width >= 15 * 16, "the board should make use of the window, got " .. widgets.board.width)
  equal("EQSTUXY", heldOnScreen())
  equal("", boardOnScreen())
  equal(false, play.enabled)
  equal(true, widgets.note.text:find("words_hint", 1, true) ~= nil)

  dragTile(widgets, "Q", "D8")
  equal("(D8=Q)", boardOnScreen())
  equal("ESTUXY", heldOnScreen())
  equal(false, play.enabled, "one tile is no word")
  equal(true, widgets.note.text:find("err_words_off_centre", 1, true) ~= nil)
  assert(#Client.sounds > 0, "a tile is heard going down")

  dragTile(widgets, "U", "E8")
  dragTile(widgets, "E", "F8")
  dragTile(widgets, "S", "G8")
  equal(true, widgets.note.text:find("err_words_off_centre", 1, true) ~= nil)
  dragTile(widgets, "T", "H8")
  equal("(D8=Q) (E8=U) (F8=E) (G8=S) (H8=T)", boardOnScreen())
  equal("XY", heldOnScreen())
  equal("words_play_for", play.text)
  equal(true, play.enabled)
  assert(widgets.note.text:find("Quest  35", 1, true), "what it would make, the way it is properly written: " .. widgets.note.text)
  assert(widgets.note.text:find("words_group_slang", 1, true))
  equal("", logOf(first, id), "nothing is sent while tiles are laid out")

  play:Fire("OnClick")
  world:Deliver()
  equal("aD8.QUEST", logOf(first, id))
  equal(logOf(first, id), logOf(second, id))
  equal(true, says("0"), "the score counts up from where it was")
  for _ = 1, 5 do
    wait(widgets.effects)
  end
  equal("D8=Q E8=U F8=E G8=S H8=T", boardOnScreen())
  equal(7, #rackOnScreen(), "drawn back up")
  equal("EEEEEXY", heldOnScreen())
  equal("EEEEE", select(2, rackOnScreen()):sub(3), "the new tiles after the ones that were kept")
  equal(false, Client.Button("words_play").enabled)
  equal(true, says("35"), "the score")
end

--- Takes away what the player typed last, the way the box nobody sees notices it
local function backspace(widgets)
  widgets.box.text = ""
  widgets.box:Fire("OnTextChanged", true)
end

--- @return boolean Whether a visible button says this
local function hasButton(text)
  return #Client.Find(function(widget)
    return widget.kind == "Button" and widget.text == text and widget:IsVisible()
  end) > 0
end

function tests.WindowTypesAWordOntoTheBoard()
  local world, first, second, id = wordsOnScreen({ "HOU_EXY", "AAAAAAA" }, "TTTTTSNAAA")
  local widgets = wordsWidgets()
  typeWord(widgets, "ho")
  equal("", boardOnScreen(), "typing goes nowhere without a square to start from")

  clickBoard(widgets, "D8")
  typeWord(widgets, "hOus")
  equal("(D8=H) (E8=O) (F8=U) (G8=S)", boardOnScreen(), "a blank stands for the letter nobody holds")
  equal("EXY", heldOnScreen())
  typeWord(widgets, "z")
  typeWord(widgets, "5")
  equal("(D8=H) (E8=O) (F8=U) (G8=S)", boardOnScreen(), "no Z to lay, and no blank left")
  typeWord(widgets, "e")
  assert(widgets.note.text:find("HOUSE  14", 1, true), widgets.note.text)

  backspace(widgets)
  backspace(widgets)
  equal("(D8=H) (E8=O) (F8=U)", boardOnScreen())
  equal("E_", select(2, rackOnScreen()):sub(-2), "taken back, they are at the end of the rack")
  typeWord(widgets, "se")
  equal("(D8=H) (E8=O) (F8=U) (G8=S) (H8=E)", boardOnScreen())

  widgets.box:Fire("OnEnterPressed")
  world:Deliver()
  equal("aD8.HOUsE", logOf(first, id))
  equal(logOf(first, id), logOf(second, id))
  for _ = 1, 5 do
    wait(widgets.effects)
  end
  equal("D8=H E8=O F8=U G8=S H8=E", boardOnScreen())

  -- Not the player's turn, but the tiles can be laid out all the same: down, and past what lies there
  equal("AAANSXY", heldOnScreen())
  clickBoard(widgets, "F7")
  clickBoard(widgets, "F7")
  typeWord(widgets, "sn")
  equal("(F7=S) D8=H E8=O F8=U G8=S H8=E (F9=N)", boardOnScreen())
  assert(widgets.note.text:find("SUN  ", 1, true), widgets.note.text)
  equal(false, Client.Button("words_play_for").enabled, "to be played when the turn comes")
  equal(true, Client.Button("words_recall").enabled)
  widgets.box:Fire("OnEnterPressed")
  equal("aD8.HOUsE", logOf(first, id))

  -- A third click takes the arrow away again
  Client.Button("words_recall"):Fire("OnClick")
  equal("D8=H E8=O F8=U G8=S H8=E", boardOnScreen())
  clickBoard(widgets, "A1")
  clickBoard(widgets, "A1")
  clickBoard(widgets, "A1")
  typeWord(widgets, "a")
  equal("D8=H E8=O F8=U G8=S H8=E", boardOnScreen())
  clickBoard(widgets, "A1")
  widgets.box:Fire("OnEscapePressed")
  typeWord(widgets, "a")
  equal("D8=H E8=O F8=U G8=S H8=E", boardOnScreen(), "nor is there one after Escape")

  -- Typing stops at the edge of the board
  clickBoard(widgets, "N1")
  typeWord(widgets, "aaa")
  equal("(N1=A) (O1=A) D8=H E8=O F8=U G8=S H8=E", boardOnScreen())
  backspace(widgets)
  typeWord(widgets, "n")
  equal("(N1=A) (O1=N) D8=H E8=O F8=U G8=S H8=E", boardOnScreen())
end

function tests.WindowSaysWhatIsWrongWithTheTilesLaidOut()
  local _, first, _, id = wordsOnScreen({ "HOU_EXY", "AAAAAAA" }, "TTTTTTTTT")
  local widgets = wordsWidgets()
  local function note(text)
    return widgets.note.text:find(text, 1, true) ~= nil
  end

  dragTile(widgets, "H", "H8")
  dragTile(widgets, "O", "I9")
  equal(true, note("err_words_one_line"))
  equal(false, Client.Button("words_play").enabled)

  -- A tile that was laid is picked up from where it lies and put somewhere else
  overSquare(widgets, "I9")
  Client.mouseDown = true
  widgets.board:Fire("OnMouseDown", "LeftButton")
  equal("(H8=H)", boardOnScreen(), "in hand, it isn't on its square")
  overSquare(widgets, "J8")
  widgets.drag:Fire("OnUpdate", 0.02)
  Client.mouseDown = false
  widgets.drag:Fire("OnUpdate", 0.02)
  equal("(H8=H) (J8=O)", boardOnScreen())
  equal(true, note("err_words_gap"))

  -- Not onto a square that has one already: it goes back where it was
  overSquare(widgets, "J8")
  Client.mouseDown = true
  widgets.board:Fire("OnMouseDown", "LeftButton")
  overSquare(widgets, "H8")
  widgets.drag:Fire("OnUpdate", 0.02)
  Client.mouseDown = false
  widgets.drag:Fire("OnUpdate", 0.02)
  equal("(H8=H) (J8=O)", boardOnScreen())

  dragTile(widgets, "X", "I8")
  equal(true, note("words_not_word"), "HXO")
  equal(false, Client.Button("words_play").enabled)

  -- Any other button puts a tile back in the rack
  clickBoard(widgets, "I8", "RightButton")
  equal("(H8=H) (J8=O)", boardOnScreen())
  equal("EUXY_", heldOnScreen())

  -- A blank asks what it is to be
  local function letters()
    return Client.Find(function(widget)
      return widget.wordsLetter and widget:IsVisible()
    end)
  end
  equal(0, #letters())
  dragTile(widgets, "_", "I8")
  equal(26, #letters())
  equal("(H8=H) (I8=) (J8=O)", boardOnScreen())
  equal(false, Client.Button("words_play").enabled, "not before it has a letter")
  letters()[1]:Fire("OnClick")
  equal(0, #letters())
  equal("(H8=H) (I8=A) (J8=O)", boardOnScreen())
  equal(true, note("HAO  10"), "H3, nothing for the blank and O1 doubled, on the middle square: " .. widgets.note.text)
  equal(true, Client.Button("words_play_for").enabled)

  Client.Button("words_recall"):Fire("OnClick")
  equal("", boardOnScreen())
  equal("EHOUXY_", heldOnScreen())
  equal(false, Client.Button("words_recall").enabled)
  equal("", logOf(first, id))
end

function tests.WindowSwapsTilesAndPasses()
  local world, first, second, id = wordsOnScreen({ "QQQAEIO", "AAAAAAA" }, "TTTTTTTT")
  local widgets = wordsWidgets()
  dragTile(widgets, "A", "H8")
  Client.Button("words_swap"):Fire("OnClick")
  equal("", boardOnScreen(), "the tiles that were laid out are back in the rack")
  equal(true, widgets.note.text == "words_swap_pick")
  equal(false, Client.Button("words_swap_n").enabled, "nothing picked yet")
  equal(false, Client.Button("words_pass").enabled)

  local tiles, letters = rackOnScreen()
  tiles[letters:find("Q")]:Fire("OnMouseDown", "LeftButton")
  equal(nil, select(2, rackOnScreen()):find("%("), "picked, a tile stays in the rack")
  tiles[letters:find("I")]:Fire("OnMouseDown", "LeftButton")
  tiles[letters:find("O")]:Fire("OnMouseDown", "LeftButton")
  tiles[letters:find("O")]:Fire("OnMouseDown", "LeftButton")
  equal(true, Client.Button("words_swap_n").enabled)
  Client.Button("words_swap_n"):Fire("OnClick")
  world:Deliver()
  local swapped = tilesOf(logOf(first, id):match("^x%.(%u%u)$") or "")
  table.sort(swapped)
  equal("IQ", table.concat(swapped))
  equal(logOf(first, id), logOf(second, id))
  equal("AEOQQTT", heldOnScreen())
  equal(false, Client.Button("words_pass").enabled, "the turn went with it")

  -- Thinking better of it
  assert(second.session:Move(id, "p"))
  world:Deliver()
  Client.Button("words_swap"):Fire("OnClick")
  tiles = rackOnScreen()
  tiles[1]:Fire("OnMouseDown", "LeftButton")
  Client.Button("words_cancel"):Fire("OnClick")
  equal(true, hasButton("words_recall"))
  equal(true, hasButton("words_play"))

  -- Passing takes two clicks
  local log = logOf(first, id)
  Client.Button("words_pass"):Fire("OnClick")
  equal(log, logOf(first, id))
  Client.Button("words_pass_sure"):Fire("OnClick")
  world:Deliver()
  equal(log .. ",p", logOf(first, id))
  equal(true, hasButton("words_pass"))
end

function tests.WindowWontSwapFromANearlyEmptyBag()
  wordsOnScreen({ "QQQAEIO", "AAAAAAA" }, "TTTTTT")
  equal(false, Client.Button("words_swap").enabled)
  equal(true, Client.Button("words_pass").enabled)
end

function tests.WindowShowsWhatTheOthersPlay()
  local world, first, second, id = wordsOnScreen({ "QQQAEIO", "THRALLX" }, "TTTTTTTTTT")
  local widgets = wordsWidgets()
  dragTile(widgets, "A", "H8")
  dragTile(widgets, "E", "A1")
  Client.Button("words_pass"):Fire("OnClick")
  Client.Button("words_pass_sure"):Fire("OnClick")
  world:Deliver()
  equal("(A1=E) (H8=A)", boardOnScreen(), "what was laid out stays where it is")

  assert(second.session:Move(id, "aD8.THRALL"))
  world:Deliver()
  equal("(A1=E) D8=T E8=H F8=R G8=A H8=L I8=L", boardOnScreen())
  equal("AIOQQQ", heldOnScreen(), "all but the tile whose square was taken")
  local floats = Client.Find(function(widget)
    return widget.wordsFloat and widget.text and widget.text:find("Thrall", 1, true)
  end)
  equal(1, #floats, "a name everybody knows is announced")
  assert(floats[1].text:find("+33", 1, true), floats[1].text)
  for _ = 1, 6 do
    wait(widgets.effects)
  end
  equal(true, says("33"))
  equal(false, floats[1]:IsShown())
  equal(true, Client.Button("words_pass").enabled)

  -- A word joined to it is played like any other
  Client.Button("words_recall"):Fire("OnClick")
  clickBoard(widgets, "G9")
  typeWord(widgets, "i")
  assert(widgets.note.text:find("AI  ", 1, true), widgets.note.text)
  Client.Button("words_recall"):Fire("OnClick")
  equal("D8=T E8=H F8=R G8=A H8=L I8=L", boardOnScreen())

  assert(second.session:Resign(id))
  world:Deliver()
  equal(false, hasButton("words_play"), "nothing to play in a game that is over")
  equal("AEIOQQQ", heldOnScreen())
end

function tests.WindowListsLongMovesOnALineEach()
  local world, _, second, id = wordsOnScreen({ "QQQAEIO", "THRALLX" }, "TTTTTTTTTT")
  Client.Button("words_pass"):Fire("OnClick")
  Client.Button("words_pass_sure"):Fire("OnClick")
  world:Deliver()
  assert(second.session:Move(id, "aD8.THRALL"))
  world:Deliver()

  -- A word and its score don't fit half a line, so each move has one, saying whose it is
  local moves = listedMoves()
  equal(2, #moves)
  assert(moves[1].parent ~= moves[2].parent, "a line each")
  assert(moves[2].parent.moves[1] == moves[2], "on the whole line, not in the second player's column")
  assert(moves[2].text.text:find("^Bob[^:]*: D8 THRALL"), "says who made it: " .. moves[2].text.text)
  equal(false, moves[2].parent.moves[2]:IsShown())
end

function tests.WindowShowsAnotherPlayersMoveOnlyOnce()
  local world, _, second, id = wordsOnScreen({ "QQQAEIO", "THRALLX" }, "TTTTTTTTTT")
  local widgets = wordsWidgets()
  Client.Button("words_pass"):Fire("OnClick")
  Client.Button("words_pass_sure"):Fire("OnClick")
  world:Deliver()
  assert(second.session:Move(id, "aD8.THRALL"))
  world:Deliver()
  for _ = 1, 6 do
    wait(widgets.effects)
  end
  local function announced()
    return #Client.Find(function(widget)
      return widget.wordsFloat and widget.text and widget.text:find("Thrall", 1, true) and widget:IsShown()
    end)
  end
  local function hidden()
    return #Client.Find(function(widget)
      return widget.wordsSquare and widget:IsVisible() and widget:GetAlpha() < 1
    end)
  end
  equal(0, announced())

  -- Whatever the player does with their own tiles, the move before isn't played out again
  Client.Button("words_shuffle"):Fire("OnClick")
  equal(0, announced(), "not on shuffling")
  equal(0, hidden(), "and the tiles of it stay where they are")
  dragTile(widgets, "A", "J8")
  equal(0, announced(), "nor on laying a tile out")
  equal(0, hidden())
  Client.Button("words_recall"):Fire("OnClick")
  equal(0, announced(), "nor on taking it back")
  equal("D8=T E8=H F8=R G8=A H8=L I8=L", boardOnScreen())
  equal(true, says("33"), "and the score isn't counted up again")
end

function tests.WindowFocusesOnTheGameAndBackOut()
  local world, _, second, id = wordsOnScreen({ "QQQAEIO", "THRALLX" }, "TTTTTTTTTT")
  local widgets = wordsWidgets()
  local focus = Client.Button("words_focus")
  equal(true, focus:IsVisible())
  focus:Fire("OnClick")
  wait(widgets.window)
  equal(true, says("words_whole"), "it says it goes back out")
  assert((widgets.board.scale or 1) > 1.5, "zoomed in, got " .. tostring(widgets.board.scale))

  -- A window made bigger keeps the zoom, and what is beside the board moves out with it
  local panel = Client.Find(function(widget)
    return widget.wordsPlate == 1
  end)[1]:GetParent()
  local function panelLeft()
    return panel.anchors[1][4]
  end
  local zoomed, before, side = widgets.board.scale, panelLeft(), widgets.window.width
  local width, height = ForeverGamesFrame:GetWidth(), ForeverGamesFrame:GetHeight()
  ForeverGamesFrame:SetSize(1400, 1000)
  wait(widgets.window)
  assert(widgets.window.width > side, "a bigger board")
  near(zoomed, widgets.board.scale, "the zoom")
  equal(true, says("words_whole"))
  assert(panelLeft() > before, "the side moved over")
  ForeverGamesFrame:SetSize(width, height)
  wait(widgets.window)
  equal(side, widgets.window.width)
  near(zoomed, widgets.board.scale, "the zoom, back again")

  Client.Button("words_whole"):Fire("OnClick")
  wait(widgets.window)
  equal(1, widgets.board.scale)
  equal(true, says("words_focus"))

  -- Even while it isn't the player's turn, or after the end
  Client.Button("words_pass"):Fire("OnClick")
  Client.Button("words_pass_sure"):Fire("OnClick")
  world:Deliver()
  assert(second.session:Resign(id))
  world:Deliver()
  equal(false, hasButton("words_play"))
  equal(true, hasButton("words_focus"))
end

function tests.WindowKeepsTheRackInThePlayersOrder()
  local _, _, _, _ = wordsOnScreen({ "ABCDEFG", "AAAAAAA" }, "TTTTTTTT")
  local widgets = wordsWidgets()
  local tiles, before = rackOnScreen()
  -- With the board out of the way: the fake client has everything in the same corner of the screen
  widgets.window:SetSize(1, 1)

  Client.cursor, Client.mouseDown = { 5, 5 }, true
  tiles[1]:Fire("OnMouseDown", "LeftButton")
  Client.cursor = { widgets.rack.width - 2, 5 }
  widgets.drag:Fire("OnUpdate", 0.02)
  equal(before:sub(2), select(2, rackOnScreen()), "in hand, it isn't in the rack")
  Client.mouseDown = false
  widgets.drag:Fire("OnUpdate", 0.02)
  equal(before:sub(2) .. before:sub(1, 1), select(2, rackOnScreen()), "let go at the far end, that is where it now lies")

  tiles = rackOnScreen()
  Client.cursor, Client.mouseDown = { 60, 5 }, true
  tiles[7]:Fire("OnMouseDown", "LeftButton")
  Client.cursor = { 1, 5 }
  widgets.drag:Fire("OnUpdate", 0.02)
  Client.mouseDown = false
  widgets.drag:Fire("OnUpdate", 0.02)
  equal(before, select(2, rackOnScreen()), "and back to the front")

  -- Let go over nothing, it is back where it was
  Client.cursor, Client.mouseDown = { 5, 5 }, true
  tiles = rackOnScreen()
  tiles[3]:Fire("OnMouseDown", "LeftButton")
  Client.cursor = { 5000, 5000 }
  widgets.drag:Fire("OnUpdate", 0.02)
  Client.mouseDown = false
  widgets.drag:Fire("OnUpdate", 0.02)
  equal(before, select(2, rackOnScreen()))

  Client.sounds = {}
  Client.Button("words_shuffle"):Fire("OnClick")
  equal("ABCDEFG", heldOnScreen())
  equal("dieShuffle", Client.sounds[1])
end

function tests.AnimatorRunsThingsOverTime()
  Client.Install()
  local private = {}
  assert(loadfile("GUI/Widgets.lua"))(ADDON_NAME, private)
  local frame = CreateFrame("Frame")
  local animator = private.Widgets.Animator(frame)
  local log = {}
  local function say(text)
    return function(progress)
      log[#log + 1] = text .. (progress and (" " .. progress) or "")
    end
  end

  equal(false, animator:Busy())
  animator:Play(0.2, say("a"), { onStart = say("a starts"), onDone = say("a done") })
  animator:Play(0.1, say("b"), { delay = 0.15, onDone = say("b done") })
  equal(true, animator:Busy())
  frame:Fire("OnUpdate", 0.1)
  equal("a starts,a 0.5", table.concat(log, ","))
  frame:Fire("OnUpdate", 0.1)
  equal("a 1,b 0.5,a done", table.concat(log, ",", 3))
  frame:Fire("OnUpdate", 0.1)
  equal("b 1,b done", table.concat(log, ",", 6))
  equal(false, animator:Busy())

  -- Stopped, everything is taken to its end, whatever that starts included
  log = {}
  animator:Play(1, say("c"), {
    delay = 5,
    onStart = say("c starts"),
    onDone = function()
      animator:Play(1, say("d"))
    end,
  })
  animator:Stop()
  equal("c starts,c 1,d 1", table.concat(log, ","))
  equal(false, animator:Busy())
end

function tests.DragMovesAboutWhateverTheGameGivesIt()
  local drag, tile, log = dragOnScreen()
  dropTarget(drag, log, "rack", 100, 100)
  local puppet = CreateFrame("Frame", nil, drag.frame)
  puppet:Hide()

  Client.cursor, Client.mouseDown = { 300, 250 }, true
  drag:Carry("Q", { puppet = puppet, from = tile })
  equal(true, puppet:IsShown())
  equal(false, drag.texture:IsShown())
  Client.cursor = { 20, 50 }
  drag.frame:Fire("OnUpdate", 0.02)
  Client.mouseDown = false
  drag.frame:Fire("OnUpdate", 0.02)
  equal("rack drop Q left", log[#log])
  equal(false, puppet:IsShown())
end

-----------------------------
-- Games for one
-----------------------------

function tests.GameForOneBeginsAtOnceAndIsNeverSent()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  world:AddPlayer("Bob-Realm")
  local Match = alice.private.Match

  local match = assert(alice.session:Invite({}, "solitaire"))
  equal("active", match.status)
  equal(1, #match.players)
  equal(1, match.me)
  equal(true, Match.IsSolo(match))
  equal(true, Match.Started(match))
  equal(true, Match.IsMyTurn(match))
  equal("changed:" .. match.id, alice.events[#alice.events])

  -- Always the player's turn, which is no reason to keep reminding them
  equal(false, alice.session:NeedsAttention(match))
  equal(0, alice.session:AttentionCount())
  equal(false, alice.session:IsPending(match))
  equal(1, #alice.session:List())

  assert(alice.session:Move(match.id, "d"))
  alice.session:Hello()
  world:Tick(100000)
  equal(0, #world.sent, "nothing about it is anybody else's business")
  equal(0, #world.queue)

  -- It can't be played against anyone, and a game for two can't be played alone
  equal("player_count", select(2, alice.session:Invite("Bob-Realm", "solitaire")))
  equal("no_target", select(2, alice.session:Invite({}, "chess")))
end

function tests.GameForOneLetsMovesBeTakenBack()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local Match = alice.private.Match
  local match = assert(alice.session:Invite({}, "solitaire"))
  local id = match.id
  local top = Match.State(match).stock[24]

  equal(false, alice.session:CanUndo(match), "nothing to take back yet")
  equal("no_undo", select(2, alice.session:Undo(id)))
  assert(alice.session:Move(id, "d"))
  assert(alice.session:Move(id, "d"))
  equal(2, #Match.State(match).waste)
  equal(2, Match.State(match).moves)

  equal(true, alice.session:CanUndo(match))
  assert(alice.session:Undo(id))
  equal("d", logOf(alice, id))
  equal(1, #Match.State(match).waste)
  equal(top, Match.State(match).waste[1])
  equal(1, Match.State(match).moves, "a move taken back was never made")
  assert(alice.session:Undo(id))
  equal(0, #Match.State(match).waste)
  equal(top, Match.State(match).stock[24], "the same card is on top again")
  equal("no_undo", select(2, alice.session:Undo(id)))
  equal("no_match", select(2, alice.session:Undo("nope")))

  -- A game played alone can be walked away from at any time
  assert(alice.session:Move(id, "d"))
  equal(true, alice.session:CanForget(match))
  assert(alice.session:Forget(id))
  equal(nil, alice.matches[id])
end

function tests.GameForOneCanBeResigned()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local match = assert(alice.session:Invite({}, "solitaire"))
  assert(alice.session:Resign(match.id))
  equal("finished", match.status)
  local result = alice.private.Match.Result(match)
  equal(0, result.winner, "nobody is left to have won")
  equal("resign", result.reason)
  equal(false, alice.session:CanUndo(match), "what is over is over")
end

function tests.MovesCanOnlyBeTakenBackInAGameForOne()
  local _, alice, _, id, first = startedMatch()
  assert(first.session:Move(id, "5"))
  equal("no_undo", select(2, first.session:Undo(id)))
  equal(false, alice.session:CanUndo(alice.matches[id]))
end

-----------------------------
-- Solitaire
-----------------------------

--- A game of solitaire to try the rules on, dealt from a seed
--- @param seed number?
--- @return table game, table state, table private
local function solitaire(seed)
  local private = loadEngine()
  local game = private.Games.Get("solitaire")
  return game, game.newState(1, private.Random.New(seed or 1)), private
end

--- Every card of a game of solitaire, wherever it is
--- @param state table
--- @return string[]
local function solitaireCards(state)
  local cards = {}
  local function add(pile)
    for _, card in ipairs(pile) do
      cards[#cards + 1] = card
    end
  end
  add(state.stock)
  add(state.waste)
  for _, pile in pairs(state.homes) do
    add(pile)
  end
  for _, column in ipairs(state.columns) do
    add(column.cards)
  end
  table.sort(cards)
  return cards
end

local SOLITAIRE_RANKS = "A23456789TJQK"

--- Checks that a position is one the rules allow: all the cards, each once, the piles they go
--- home on built up in suit and what is face up in the columns built down in turn about
--- @param state table
local function solitaireIsSound(state)
  local cards = solitaireCards(state)
  equal(52, #cards)
  for index = 2, #cards do
    assert(cards[index] ~= cards[index - 1], cards[index] .. " is there twice")
  end
  for suit, pile in pairs(state.homes) do
    for rank, card in ipairs(pile) do
      equal(SOLITAIRE_RANKS:sub(rank, rank) .. suit, card)
    end
  end
  local red = { H = true, D = true }
  for _, column in ipairs(state.columns) do
    assert(column.down >= 0 and column.down <= math.max(0, #column.cards - 1), "a column always shows its top card")
    for index = column.down + 2, #column.cards do
      local under, over = column.cards[index - 1], column.cards[index]
      equal(SOLITAIRE_RANKS:find(under:sub(1, 1), 1, true), SOLITAIRE_RANKS:find(over:sub(1, 1), 1, true) + 1, "one lower on " .. under)
      assert(red[under:sub(2, 2)] ~= red[over:sub(2, 2)], over .. " on " .. under .. " isn't turn about")
    end
  end
end

--- The move a player who isn't thinking very hard would make, nil when they would give up
--- @param game table
--- @param state table
--- @param idle number How many cards they have turned since they last did anything else
--- @return string?
local function solitaireMove(game, state, idle)
  local function goes(move)
    return game.validate(state, 1, move)
  end
  if goes("a") then
    return "a"
  end
  for _, from in ipairs({ "1", "2", "3", "4", "5", "6", "7", "w" }) do
    if goes(from .. "f") then
      return from .. "f"
    end
  end
  -- Whatever uncovers a card
  for from, column in ipairs(state.columns) do
    local up = #column.cards - column.down
    if up > 0 and column.down > 0 then
      for to = 1, 7 do
        local move = from .. to .. (up > 1 and up or "")
        if goes(move) then
          return move
        end
      end
    end
  end
  for to = 1, 7 do
    if goes("w" .. to) then
      return "w" .. to
    end
  end
  if goes("d") and idle < #state.stock + #state.waste + 2 then
    return "d"
  end
  return nil
end

--- A position with nothing in it, to lay out by hand
--- @param game table
--- @return table
local function emptySolitaire(game)
  local state = game.newState(1, loadEngine().Random.New(1))
  state.stock, state.waste = {}, {}
  for column = 1, 7 do
    state.columns[column] = { cards = {}, down = 0 }
  end
  return state
end

function tests.SolitaireDealsSevenColumnsAndAStock()
  local game, state, private = solitaire(5)
  equal(1, game.turn(state))
  equal(nil, game.result(state))
  equal(24, #state.stock)
  equal(0, #state.waste)
  for column = 1, 7 do
    equal(column, #state.columns[column].cards)
    equal(column - 1, state.columns[column].down, "only the top card is face up")
  end
  for _, suit in ipairs({ "S", "H", "D", "C" }) do
    equal(0, #state.homes[suit])
  end
  solitaireIsSound(state)

  local same = game.newState(1, private.Random.New(5))
  equal(table.concat(state.stock, ","), table.concat(same.stock, ","), "the same deal from the same seed")
  local other = game.newState(1, private.Random.New(6))
  assert(table.concat(state.stock, ",") ~= table.concat(other.stock, ","), "and another from another")
  equal("not_your_turn", select(2, game.validate(state, 2, "d")))
end

function tests.SolitaireTurnsTheStockAndGoesThroughItAgain()
  local game, state = solitaire(2)
  local order = {}
  for turned = 1, 24 do
    equal(true, game.validate(state, 1, "d"))
    local event = game.apply(state, 1, "d")
    order[turned] = event.drew
    equal(event.drew, state.waste[turned])
  end
  equal(0, #state.stock)
  equal(24, #state.waste)

  state.score = 130
  local event = game.apply(state, 1, "d")
  equal(true, event.again)
  equal(24, #state.stock)
  equal(0, #state.waste)
  equal(30, state.score, "going through it again costs a hundred")
  equal(order[1], game.apply(state, 1, "d").drew, "in the order it was gone through before")
  equal(order[2], game.apply(state, 1, "d").drew)
  solitaireIsSound(state)

  state.stock, state.waste = {}, {}
  equal("invalid_move", select(2, game.validate(state, 1, "d")), "nothing left to turn")
end

function tests.SolitaireBuildsColumnsDownInTurnAbout()
  local game = solitaire()
  local state = emptySolitaire(game)
  state.columns[1] = { cards = { "9C", "KH", "QS" }, down = 1 }
  state.columns[2] = { cards = { "KD" }, down = 0 }
  state.columns[3] = { cards = { "4D", "JH" }, down = 1 }
  state.columns[4] = { cards = { "JS" }, down = 0 }
  state.waste = { "5C", "JD" }

  local wrong = {
    ["32"] = "a jack on a king",
    ["42"] = "and the other jack",
    ["41"] = "black on black",
    ["13"] = "a queen on a jack",
    ["35"] = "anything but a king into an empty column",
    ["11"] = "a card onto its own column",
    ["133"] = "a card that lies face down",
    ["322"] = "and one that is turned over only afterwards",
    ["w22"] = "more than one card of the waste",
    ["121"] = "one card written as if it were several",
    ["1202"] = "a number written another way",
    ["w8"] = "a column there isn't",
    ["s1"] = "a card of the stock",
    ["5f"] = "a card that isn't there",
    ["wf"] = "a jack home before its ace",
    ["Sf"] = "a card that is home already",
    ["S1"] = "a card from a pile that has none",
    ["x"] = "nonsense",
    [""] = "nothing",
  }
  for move, why in pairs(wrong) do
    equal("invalid_move", select(2, game.validate(state, 1, move)), why)
  end

  -- The jack of hearts on the queen of spades, which turns over the card it lay on
  equal(true, game.validate(state, 1, "31"))
  local event = game.apply(state, 1, "31")
  equal("JH", table.concat(event.cards, ","))
  equal("4D", event.turned)
  equal("9C,KH,QS,JH", table.concat(state.columns[1].cards, ","))
  equal(0, state.columns[3].down)
  equal(5, state.score, "five for the card turned over")

  -- The cards built on each other move together, onto a king or into a column that is empty
  equal(true, game.validate(state, 1, "122"), "from the queen up")
  equal("invalid_move", select(2, game.validate(state, 1, "152")), "but only a king goes into an empty column")
  equal(true, game.validate(state, 1, "153"))
  event = game.apply(state, 1, "153")
  equal("KH,QS,JH", table.concat(event.cards, ","))
  equal("9C", event.turned)
  equal("9C", table.concat(state.columns[1].cards, ","))
  equal("KH,QS,JH", table.concat(state.columns[5].cards, ","))
  equal(10, state.score)

  -- The waste gives up its top card, for five
  equal("invalid_move", select(2, game.validate(state, 1, "w5")), "a jack on a jack")
  state.columns[6] = { cards = { "QC" }, down = 0 }
  equal(true, game.validate(state, 1, "w6"))
  game.apply(state, 1, "w6")
  equal("5C", table.concat(state.waste, ","))
  equal("QC,JD", table.concat(state.columns[6].cards, ","))
  equal(15, state.score)
  equal(3, state.moves)
end

function tests.SolitaireSendsCardsHomeAndBringsThemBack()
  local game = solitaire()
  local state = emptySolitaire(game)
  state.columns[1] = { cards = { "7C", "AH" }, down = 1 }
  state.columns[2] = { cards = { "3S" }, down = 0 }
  state.columns[3] = { cards = { "2S", "AS" }, down = 0 }
  state.waste = { "2H" }

  equal("invalid_move", select(2, game.validate(state, 1, "wf")), "the two waits for its ace")
  equal("invalid_move", select(2, game.validate(state, 1, "3f2")), "one card at a time")
  game.apply(state, 1, "1f")
  equal("AH", table.concat(state.homes.H, ","))
  equal(15, state.score, "ten for the ace and five for the card under it")
  equal(true, game.validate(state, 1, "wf"))
  game.apply(state, 1, "wf")
  equal("AH,2H", table.concat(state.homes.H, ","))
  equal(25, state.score)

  -- A card that is home can be brought back to a column, at a price
  equal(true, game.validate(state, 1, "H2"), "the red two on the black three")
  equal("invalid_move", select(2, game.validate(state, 1, "H3")), "but not on the ace")
  game.apply(state, 1, "H2")
  equal("3S,2H", table.concat(state.columns[2].cards, ","))
  equal("AH", table.concat(state.homes.H, ","))
  equal(10, state.score)
  game.apply(state, 1, "H1")
  equal("invalid_move", select(2, game.validate(state, 1, "H1")))
  equal(0, state.score, "never to below nothing")
  equal(nil, game.result(state))
end

function tests.SolitaireIsWonByTheLastCardHome()
  local game = solitaire()
  local state = emptySolitaire(game)
  for _, suit in ipairs({ "S", "H", "D", "C" }) do
    for rank = 1, 13 do
      state.homes[suit][rank] = SOLITAIRE_RANKS:sub(rank, rank) .. suit
    end
  end
  table.remove(state.homes.D)
  state.columns[4] = { cards = { "KD" }, down = 0 }
  solitaireIsSound(state)
  equal(nil, game.result(state))
  game.apply(state, 1, "4f")
  equal(1, game.result(state).winner)
end

function tests.SolitaireOffersToPlayTheRestOut()
  local game = solitaire()
  local state = emptySolitaire(game)
  -- Everything is home but the queens and kings of two suits
  for _, suit in ipairs({ "S", "H", "D", "C" }) do
    for rank = 1, (suit == "S" or suit == "H") and 11 or 13 do
      state.homes[suit][rank] = SOLITAIRE_RANKS:sub(rank, rank) .. suit
    end
  end
  state.columns[1] = { cards = { "KH", "KS", "QH" }, down = 1 }
  state.stock = { "QS" }
  state.score = 100
  solitaireIsSound(state)
  equal("invalid_move", select(2, game.validate(state, 1, "a")), "not while something lies face down")

  state.columns[1].down = 0
  equal(true, game.validate(state, 1, "a"), "what is left in the stock can be got at")
  local event = game.apply(state, 1, "a")
  equal("QS,QH,KS,KH", table.concat(event.finished, ","), "lowest first, so each has something to go on")
  equal(1, game.result(state).winner)
  equal(140, state.score, "ten for each of them")
  equal(0, #state.stock + #state.waste + #state.columns[1].cards)
  solitaireIsSound(state)
  equal("invalid_move", select(2, game.validate(state, 1, "a")), "nothing left to send")
end

function tests.SolitaireIsPlayedThroughWithoutLosingACard()
  local won, played = 0, 0
  for seed = 1, 60 do
    local game, state = solitaire(seed)
    local idle = 0
    while not game.result(state) do
      local move = solitaireMove(game, state, idle)
      if not move then
        break
      end
      idle = move == "d" and idle + 1 or 0
      local event = game.apply(state, 1, move)
      played = played + 1
      solitaireIsSound(state)
      if event.turned then
        local turned = false
        for _, column in ipairs(state.columns) do
          turned = turned or column.cards[#column.cards] == event.turned
        end
        equal(true, turned, "the card turned over is on top of its column")
      end
      assert(played < 100000, "the game should end")
    end
    if game.result(state) then
      won = won + 1
      equal(52, #state.homes.S + #state.homes.H + #state.homes.D + #state.homes.C)
      assert(state.score > 0)
    end
  end
  assert(won > 0, "some deals come out even for a player who isn't thinking")
end

-----------------------------
-- Card table
-----------------------------

--- A card table on its own, with cards of 40 by 60 and three piles: a column that fans out
--- downwards, a pile next to it and one further along
--- @return table felt, table frame, string[] log What the player did, as the table told the game
local function tableOnItsOwn()
  Client.Install()
  ForeverGames = { db = { profile = { sound = true } } }
  local private = {}
  for _, file in ipairs({ "GUI/Widgets.lua", "GUI/Cards.lua", "GUI/CardTable.lua" }) do
    assert(loadfile(file))(ADDON_NAME, private)
  end
  local felt = private.CardTable.New(CreateFrame("Frame", nil, UIParent))
  felt:SetSize(400, 300, 40, 60)
  felt:Pile("column", { x = 10, y = 10, fan = { 0, 0.5 }, downFan = { 0, 0.25 } })
  felt:Pile("pile", { x = 110, y = 10 })
  felt:Pile("far", { x = 310, y = 10, press = true })

  local log = {}
  felt.onDrop = function(from, index, to)
    log[#log + 1] = "drop " .. from .. " " .. index .. " " .. to
  end
  felt.onClick = function(pile, index)
    log[#log + 1] = "click " .. pile .. " " .. tostring(index)
  end
  felt.onRightClick = function(pile, index)
    log[#log + 1] = "right " .. pile .. " " .. tostring(index)
  end
  return felt, felt.frame, log
end

--- Moves the cursor to a point of a card table, measured from its top left corner
--- @param frame table
--- @param x number
--- @param y number
local function pointAtTable(frame, x, y)
  Client.cursor = { x, frame.height - y }
end

--- Lets time pass on a card table
--- @param frame table
--- @param seconds number
local function passTime(frame, seconds)
  for _ = 1, math.floor(seconds / 0.02 + 0.5) do
    frame:Fire("OnUpdate", 0.02)
  end
end

--- Presses the button on a card or an empty place, where it is
--- @param frame table
--- @param region table
--- @param x number
--- @param y number
local function pressOnTable(frame, region, x, y)
  pointAtTable(frame, x, y)
  Client.mouseDown = true
  region:Fire("OnMouseDown", "LeftButton")
  frame:Fire("OnUpdate", 0.02)
end

--- Lets the button go again
--- @param frame table
local function letGoOnTable(frame)
  Client.mouseDown = false
  frame:Fire("OnUpdate", 0.02)
end

function tests.CardTableLaysCardsOutInPiles()
  local felt, frame = tableOnItsOwn()
  equal(400, frame.width)
  felt:Set({ column = { cards = { "AS", "2H", "3C" }, down = 1 }, pile = { cards = { "KD" } } })
  equal(false, felt:Busy(), "what wasn't there before is simply there")

  -- A card's place is its middle: the first of the column, then a quarter of a card further for
  -- the one face down and half a card for the one face up
  local ace, two, three, king = felt.sprites.AS, felt.sprites["2H"], felt.sprites["3C"], felt.sprites.KD
  equal("30,40", ace.x .. "," .. ace.y)
  equal("30,55", two.x .. "," .. two.y)
  equal("30,85", three.x .. "," .. three.y)
  equal("130,40", king.x .. "," .. king.y)
  assert(ace.picture.texture:find("back$"), "face down is seen from the back")
  assert(two.picture.texture:find("2H$"))
  equal(40, two.width)
  equal(60, two.height)
  equal(true, ace:IsShown())

  -- Saying it again changes nothing
  felt:Set({ column = { cards = { "AS", "2H", "3C" }, down = 1 }, pile = { cards = { "KD" } } })
  equal(false, felt:Busy())

  -- A card that is no longer on the table is taken off it, and can come back
  felt:Set({ column = { cards = { "AS", "2H", "3C" }, down = 1 } })
  equal(nil, felt.sprites.KD)
  equal(false, king:IsShown())
  felt:Set({ column = { cards = { "AS", "2H", "3C" }, down = 1 }, pile = { cards = { "KD" } } })
  equal(true, felt.sprites.KD:IsShown())
end

function tests.CardTableKeepsALongPileWithinItsRoom()
  local felt = tableOnItsOwn()
  felt:Pile("column", { room = 90 })
  local cards = {}
  for index = 1, 4 do
    cards[index] = index .. "S"
  end
  felt:Set({ column = { cards = cards } })
  equal(130, felt.sprites["4S"].y, "three steps of half a card fit")

  for index = 5, 10 do
    cards[index] = index .. "S"
  end
  felt:Set({ column = { cards = cards } }, { instant = true })
  equal(130, felt.sprites["10S"].y, "nine don't: the cards lie closer together")
  equal(50, felt.sprites["2S"].y)

  -- Only so many on top are spread out
  felt:Pile("pile", { fan = { 0.5, 0 }, spread = 2 })
  felt:Set({ pile = { cards = { "AD", "2D", "3D", "4D" } } }, { instant = true })
  equal(130, felt.sprites.AD.x)
  equal(130, felt.sprites["3D"].x, "all but the last two lie on each other")
  equal(150, felt.sprites["4D"].x)
end

function tests.CardTableShowsWhatChanged()
  local felt, frame = tableOnItsOwn()
  felt:Set({ column = { cards = { "AS", "2H", "3C" }, down = 2 } })
  local ace, two, three = felt.sprites.AS, felt.sprites["2H"], felt.sprites["3C"]
  local sounds = #Client.sounds

  -- The three goes to the other pile, which turns the two over
  local position = { column = { cards = { "AS", "2H" }, down = 1 }, pile = { cards = { "3C" } } }
  felt:Set(position, { sound = "cardPlace" })
  equal(true, felt:Busy())
  equal(sounds + 1, #Client.sounds)
  equal("cardPlace", Client.sounds[#Client.sounds])
  assert(two.picture.texture:find("back$"), "not turned over yet")

  frame:Fire("OnUpdate", 0.06)
  assert(three.x > 30 and three.x < 130, "the three is on its way, at " .. three.x)
  assert(three:GetAlpha() == 1)
  -- Asked for again halfway, nothing starts over
  local halfway = three.x
  felt:Set(position, { sound = "cardPlace" })
  equal(halfway, three.x)
  equal(sounds + 1, #Client.sounds)

  local narrowest = two.width
  for _ = 1, 30 do
    frame:Fire("OnUpdate", 0.02)
    narrowest = math.min(narrowest, two.width)
  end
  equal(false, felt:Busy())
  equal("130,40", three.x .. "," .. three.y)
  assert(narrowest < 10, "the two was seen edge on as it turned, got as narrow as " .. narrowest)
  equal(40, two.width)
  assert(two.picture.texture:find("2H$"))
  assert(ace.picture.texture:find("back$"))

  -- A move taken back is the same thing the other way round
  felt:Set({ column = { cards = { "AS", "2H", "3C" }, down = 2 } })
  equal(true, felt:Busy())
  passTime(frame, 1)
  equal("30,70", three.x .. "," .. three.y)
  assert(two.picture.texture:find("back$"))

  -- All at once when that is what is wanted
  felt:Set(position, { instant = true })
  equal(false, felt:Busy())
  equal(130, three.x)
  assert(two.picture.texture:find("2H$"))
end

function tests.CardTableSendsCardsOffOneAfterTheOther()
  local felt, frame = tableOnItsOwn()
  felt:Set({ pile = { cards = { "AS", "2S", "3S", "4S" }, down = 4 } })
  local sounds = #Client.sounds
  felt:Set({ pile = { cards = { "AS" }, down = 1 }, column = { cards = { "4S", "3S", "2S" }, down = 2 } }, { sequence = { "4S", "3S", "2S" }, gap = 0.1, sound = "cardSlide" })

  --- @return number How many of them have left the pile
  local function left()
    local count = 0
    for _, id in ipairs({ "2S", "3S", "4S" }) do
      count = count + (felt.sprites[id].x < 130 and 1 or 0)
    end
    return count
  end
  frame:Fire("OnUpdate", 0.05)
  equal(1, left())
  equal(sounds + 1, #Client.sounds, "heard as it goes")
  frame:Fire("OnUpdate", 0.1)
  equal(2, left())
  frame:Fire("OnUpdate", 0.1)
  equal(3, left())
  equal(sounds + 3, #Client.sounds)
  passTime(frame, 1)
  equal(false, felt:Busy())
  assert(felt.sprites["2S"].picture.texture:find("2S$"), "the last one turned over on the way")
  assert(felt.sprites["3S"].picture.texture:find("back$"))

  -- Stopped, everything is where it belongs
  felt:Set({ pile = { cards = { "AS", "2S", "3S", "4S" }, down = 4 } }, { sequence = { "2S", "3S", "4S" } })
  equal(true, felt:Busy())
  felt:Stop()
  equal(false, felt:Busy())
  equal(130, felt.sprites["4S"].x)
end

function tests.CardTableLetsThePlayerCarryCards()
  local felt, frame, log = tableOnItsOwn()
  local asked = {}
  felt.canLift = function(pile, index)
    return pile == "column" and index >= 2
  end
  felt.canDrop = function(from, index, to)
    asked[#asked + 1] = from .. " " .. index .. " " .. to
    return to == "pile"
  end
  felt:Set({ column = { cards = { "AS", "2H", "3C" }, down = 1 }, pile = { cards = { "KD" } } })
  local ace, two, three, king = felt.sprites.AS, felt.sprites["2H"], felt.sprites["3C"], felt.sprites.KD

  -- A click is a click
  pressOnTable(frame, three, 30, 85)
  letGoOnTable(frame)
  equal("click column 3", log[#log])
  equal(1, #log)

  -- A card that may not be picked up stays where it is, however far the cursor goes
  pressOnTable(frame, ace, 30, 40)
  pointAtTable(frame, 130, 40)
  frame:Fire("OnUpdate", 0.02)
  equal(30, ace.x)
  letGoOnTable(frame)
  equal("click column 1", log[#log])

  -- Taken hold of near its corner, the two is carried by that corner, and the three with it
  pressOnTable(frame, two, 20, 45)
  pointAtTable(frame, 60, 65)
  frame:Fire("OnUpdate", 0.02)
  equal("70,75", two.x .. "," .. two.y)
  equal("70,105", three.x .. "," .. three.y)
  equal(30, ace.x)
  equal(false, king.target == true, "not over anything yet")

  -- Over the pile it would land on, the pile lights up
  pointAtTable(frame, 110, 30)
  frame:Fire("OnUpdate", 0.02)
  equal(true, king.target)
  equal(true, king.light:IsShown())
  equal("column 2 pile", asked[#asked])
  letGoOnTable(frame)
  equal("drop column 2 pile", log[#log])
  equal(false, king.target)
  -- The game made nothing of it, so back they go
  equal(true, felt:Busy())
  passTime(frame, 0.5)
  equal("30,55", two.x .. "," .. two.y)
  equal("30,85", three.x .. "," .. three.y)

  -- Let go over a pile that won't have it, or over nothing, the game isn't even told
  local drops = #log
  for _, where in ipairs({ { 330, 40 }, { 220, 250 } }) do
    pressOnTable(frame, three, 30, 85)
    pointAtTable(frame, where[1], where[2])
    frame:Fire("OnUpdate", 0.02)
    equal(where[1], three.x)
    letGoOnTable(frame)
    passTime(frame, 0.5)
    equal(30, three.x)
  end
  equal(drops, #log)
  equal("column 3 far", asked[#asked])

  -- When the game does make something of it, the cards go on from where they were let go
  felt.onDrop = function()
    felt:Set({ column = { cards = { "AS" } }, pile = { cards = { "KD", "2H", "3C" } } })
  end
  pressOnTable(frame, two, 30, 55)
  pointAtTable(frame, 120, 50)
  frame:Fire("OnUpdate", 0.02)
  letGoOnTable(frame)
  assert(two.x > 100 and two.x <= 130, "from where it was dropped, not from the column: " .. two.x)
  passTime(frame, 0.5)
  equal("130,40", two.x .. "," .. two.y)
  equal("130,40", three.x .. "," .. three.y)
  assert(ace.picture.texture:find("AS$"), "and the ace was turned over")

  -- The other button puts back what is in hand, and is a click of its own otherwise
  felt.canLift = function()
    return true
  end
  pressOnTable(frame, three, 130, 40)
  pointAtTable(frame, 200, 200)
  frame:Fire("OnUpdate", 0.02)
  equal(200, three.x)
  three:Fire("OnMouseDown", "RightButton")
  passTime(frame, 0.5)
  equal(130, three.x)
  Client.mouseDown = false
  frame:Fire("OnUpdate", 0.02)
  three:Fire("OnMouseDown", "RightButton")
  equal("right pile 3", log[#log])

  -- An empty place is clicked like a card, and a table that is put away lets go of everything
  pressOnTable(frame, felt.piles.far.place, 330, 40)
  letGoOnTable(frame)
  equal("click far nil", log[#log])
  pressOnTable(frame, three, 130, 40)
  pointAtTable(frame, 200, 200)
  frame:Fire("OnUpdate", 0.02)
  frame:Hide()
  equal(130, three.x)
  frame:Show()
  letGoOnTable(frame)
  equal("click far nil", log[#log], "nothing is dropped when the table comes back")
end

function tests.CardTableLightsUpWhatCanBeTaken()
  local felt = tableOnItsOwn()
  felt.canLift = function(pile, index)
    return pile == "column" and index == 2
  end
  felt:Set({ column = { cards = { "AS", "2H" } }, far = { cards = { "KD", "QD" } } })
  local function lit(region)
    region:Fire("OnEnter")
    local shown = region.light:IsShown()
    region:Fire("OnLeave")
    equal(false, region.light:IsShown())
    return shown
  end
  equal(false, lit(felt.sprites.AS))
  equal(true, lit(felt.sprites["2H"]))
  equal(true, lit(felt.sprites.QD), "the top of a pile that is there to be clicked")
  equal(false, lit(felt.sprites.KD))
  equal(false, lit(felt.piles.pile.place))
  felt:Set({})
  equal(true, lit(felt.piles.far.place), "and its place when it is empty")
end

function tests.CardTableShakesOffACardAndThrowsThemAllAbout()
  local felt, frame = tableOnItsOwn()
  felt:Set({ column = { cards = { "AS", "2H" } }, pile = { cards = { "KD" } } })
  felt:Refuse("2H")
  felt:Refuse("nope")
  passTime(frame, 1)
  equal("30,70", felt.sprites["2H"].x .. "," .. felt.sprites["2H"].y, "a shake of the head leaves it where it was")

  felt:Fountain({ "KD", "2H", "AS", "nope" }, 0.2)
  equal(true, felt:Busy())
  frame:Fire("OnUpdate", 0.1)
  equal(130, felt.sprites.KD.x, "not before it is time")
  local moved, gone = false, false
  for _ = 1, 3000 do
    frame:Fire("OnUpdate", 0.02)
    moved = moved or felt.sprites.KD.x ~= 130
    gone = gone or felt.sprites.KD:GetAlpha() == 0
    assert(felt.sprites.KD.y <= 300 - 30 + 0.001, "a card bounces off the bottom of the table")
    if not felt:Busy() then
      break
    end
  end
  equal(true, moved)
  equal(true, gone, "off the table and out of sight")
  equal(false, felt:Busy(), "it comes to an end")
  for _, id in ipairs({ "AS", "2H", "KD" }) do
    equal(1, felt.sprites[id]:GetAlpha())
  end
  equal("130,40", felt.sprites.KD.x .. "," .. felt.sprites.KD.y, "and everything is back where it was")

  -- A click on a card is enough of it
  felt:Fountain({ "KD", "2H", "AS" })
  passTime(frame, 0.5)
  equal(true, felt:Busy())
  felt.sprites.AS:Fire("OnMouseDown", "LeftButton")
  equal(false, felt:Busy())
  equal("30,40", felt.sprites.AS.x .. "," .. felt.sprites.AS.y)
end

-----------------------------
-- 2048
-----------------------------

--- A game of 2048 with the tiles where a test wants them
--- @param rows string[] What lies on the board, a row at a time: "2 . 4 4"
--- @return table game, table state, table private
local function slidingGame(rows)
  local private = loadEngine()
  local game = private.Games.Get("2048")
  local state = game.newState(1, private.Random.New(1), { size = #rows })
  state.best = 0
  for row, text in ipairs(rows) do
    local column = 0
    for word in text:gmatch("%S+") do
      column = column + 1
      state.cells[(row - 1) * #rows + column] = tonumber(word) or 0
      state.best = math.max(state.best, tonumber(word) or 0)
    end
    equal(#rows, column, "tiles in row " .. row)
  end
  return game, state, private
end

--- What lies on a board of 2048, written the way slidingGame reads it
--- @param state table
--- @param without number? A square to leave out: the one the new tile turned up on
--- @return string
local function slidingRows(state, without)
  local rows = {}
  for row = 1, state.size do
    local words = {}
    for column = 1, state.size do
      local square = (row - 1) * state.size + column
      local value = state.cells[square]
      words[column] = (value == 0 or square == without) and "." or tostring(value)
    end
    rows[row] = table.concat(words, " ")
  end
  return table.concat(rows, "/")
end

--- Pushes the tiles of a game of 2048 and says what came of it, the new tile aside
--- @param game table
--- @param state table
--- @param way string
--- @param private table
--- @param seed number?
--- @return string rows, table event
local function slidingPush(game, state, way, private, seed)
  equal(true, (game.validate(state, 1, way)), "pushing " .. way)
  local event = game.apply(state, 1, way, private.Random.New(seed or 1))
  return slidingRows(state, event.spawn.at), event
end

--- Works a position out from the one before and what a move says happened, the way a view
--- would have to: nothing of it is taken from the position that came of the move
--- @param before number[]
--- @param event table
--- @return number[]
local function slidingFollow(before, event)
  local after, left = {}, {}
  for square = 1, #before do
    after[square] = 0
    left[square] = before[square]
  end
  local arrived, joined = {}, {}
  for _, slide in ipairs(event.slides) do
    equal(slide.value, left[slide.from], "a tile sets out from where one lies")
    left[slide.from] = 0
    arrived[slide.to] = (arrived[slide.to] or 0) + 1
    joined[slide.to] = (joined[slide.to] or 0) + (slide.merged and 1 or 0)
    after[slide.to] = slide.merged and -1 or slide.value
  end
  for square = 1, #before do
    equal(0, left[square], "every tile is accounted for")
    equal(arrived[square] == 2 and 2 or 0, joined[square] or 0, "tiles that share a square became one, and no others")
  end
  for _, merge in ipairs(event.merges) do
    equal(-1, after[merge.at], "two tiles met where one was made")
    equal(2, arrived[merge.at])
    after[merge.at] = merge.value
  end
  for square = 1, #before do
    assert(after[square] >= 0, "every pair that met became a tile")
    assert((arrived[square] or 0) <= 2, "never more than two")
  end
  equal(0, after[event.spawn.at], "the new tile turns up on a free square")
  after[event.spawn.at] = event.spawn.value
  return after
end

--- What a player who looks a little ahead would push next in a game of 2048: whatever keeps
--- the most squares free and the biggest tile in its corner
--- @param game table
--- @param state table
--- @param private table
--- @param depth number? How many moves ahead to look, 2 if left out
--- @param chance number? What the match's chance has come to (slidingChance), for a player who works out which tiles will turn up where instead of guessing
--- @return string? way Nothing when there is no move left
local function slidingMove(game, state, private, depth, chance)
  local best, bestWorth = nil, nil
  for index, way in ipairs({ "l", "u", "r", "d" }) do
    if game.validate(state, 1, way) then
      local after = copy(state)
      local stirred = chance and private.Random.Stir(chance, way)
      local event = game.apply(after, 1, way, private.Random.New(stirred or index + after.moves))
      local free = 0
      for _, value in ipairs(after.cells) do
        free = free + (value == 0 and 1 or 0)
      end
      local worth = event.gained + free * 12 + (after.cells[1] == after.best and after.best or 0) - (after.over and 10000 or 0)
      if (depth or 2) > 1 and not after.over then
        worth = worth + (select(2, slidingMove(game, after, private, (depth or 2) - 1, stirred)) or 0) * 0.9
      end
      if not bestWorth or worth > bestWorth then
        best, bestWorth = way, worth
      end
    end
  end
  return best, bestWorth
end

--- What the chance of a match has come to with the moves made in it (Engine/Random.lua): the
--- tile a move brings follows from it and the move
--- @param private table
--- @param match table
--- @return number
local function slidingChance(private, match)
  local chance = private.Random.Seed(match.id)
  for _, entry in ipairs(match.log) do
    chance = private.Random.Stir(chance, entry)
  end
  return chance
end

function tests.TwentyFortyEightBeginsWithTwoTiles()
  local private = loadEngine()
  local game = private.Games.Get("2048")
  equal(1, game.seats)
  equal(true, private.Games.IsSolo(game))
  equal(true, game.undo)
  equal(nil, game.clock, "nobody is in a hurry")

  for size, target in pairs({ [3] = 256, [4] = 2048, [5] = 2048 }) do
    for seed = 1, 20 do
      local state = game.newState(1, private.Random.New(seed), { size = size })
      equal(size * size, #state.cells)
      local tiles = 0
      for _, value in ipairs(state.cells) do
        assert(value == 0 or value == 2 or value == 4, "a 2 or a 4, got " .. value)
        tiles = tiles + (value > 0 and 1 or 0)
      end
      equal(2, tiles)
      equal(0, state.score)
      equal(target, state.target)
      equal(false, state.reached)
      equal(nil, game.result(state))
      assert(state.best == 2 or state.best == 4)
    end
  end
  -- Four by four unless it says otherwise, and for whoever is handed no rules at all
  equal(16, #game.newState(1, private.Random.New(1), private.Games.Rules(game.options)).cells)
  equal(16, #game.newState(1, private.Random.New(1)).cells)
  equal(1, game.turn({}))
end

function tests.TwentyFortyEightPushesTilesAsFarAsTheyGo()
  local board = { ". 2 . .", ". . . 4", "8 . . .", ". . 16 ." }
  local function pushed(way)
    local game, state, private = slidingGame(board)
    local rows, event = slidingPush(game, state, way, private)
    equal(way, event.way)
    equal(0, event.gained)
    equal(0, #event.merges)
    equal(4, #event.slides, "every tile is spoken for")
    equal(0, state.score)
    equal(1, state.moves)
    return rows
  end
  equal("2 . . ./4 . . ./8 . . ./16 . . .", pushed("l"))
  equal(". . . 2/. . . 4/. . . 8/. . . 16", pushed("r"))
  equal("8 2 16 4/. . . ./. . . ./. . . .", pushed("u"))
  equal(". . . ./. . . ./. . . ./8 2 16 4", pushed("d"))

  -- Tiles that aren't worth the same only queue up
  local game, state, private = slidingGame({ ". 2 4 2", "4 . . 8", ". . . .", ". . . ." })
  equal("2 4 2 ./4 8 . ./. . . ./. . . .", (slidingPush(game, state, "l", private)))
end

function tests.TwentyFortyEightMakesOneTileOfTwoOnceAMove()
  local function pushed(rows, way)
    local game, state, private = slidingGame(rows)
    local after, event = slidingPush(game, state, way, private)
    equal(event.gained, state.score)
    return after, event, state
  end
  -- Of four the same it is two pairs, not one tile of everything
  local rows, event, state = pushed({ "2 2 2 2", ". . . .", ". . . .", ". . . ." }, "l")
  equal("4 4 . ./. . . ./. . . ./. . . .", rows)
  equal(8, event.gained)
  equal(2, #event.merges)
  equal(4, state.best)
  -- Of three it is the two nearest the edge they are pushed to
  equal("4 2 . ./. . . ./. . . ./. . . .", (pushed({ "2 2 2 .", ". . . .", ". . . .", ". . . ." }, "l")))
  equal(". . 2 4/. . . ./. . . ./. . . .", (pushed({ "2 2 2 .", ". . . .", ". . . .", ". . . ." }, "r")))
  -- What was made in a move isn't made into more by the same move
  rows, event = pushed({ "4 . 2 2", ". . . .", ". . . .", ". . . ." }, "l")
  equal("4 4 . ./. . . ./. . . ./. . . .", rows)
  equal(4, event.gained)
  rows, event = pushed({ "2 2 4 8", ". . . .", ". . . .", ". . . ." }, "r")
  equal(". 4 4 8/. . . ./. . . ./. . . .", rows)
  -- Across a gap, and up and down as well
  rows, event, state = pushed({ "16 . 2", ". . .", "16 . 2" }, "d")
  equal(". . ./. . ./32 . 4", rows)
  equal(36, event.gained)
  equal(36, state.score)
  equal(32, state.best)
  equal("32 . 4/. . ./. . .", (pushed({ "16 . 2", ". . .", "16 . 2" }, "u")))

  -- The move says all of it: which tiles went where, which of them became one
  local _, told = pushed({ ". 2 . 2", ". . . .", "4 . . .", ". . . ." }, "l")
  equal(3, #told.slides)
  local seen = {}
  for _, slide in ipairs(told.slides) do
    seen[#seen + 1] = slide.from .. ">" .. slide.to .. "=" .. slide.value .. (slide.merged and "!" or "")
  end
  table.sort(seen)
  equal("2>1=2!,4>1=2!,9>9=4", table.concat(seen, ","))
  equal(1, told.merges[1].at)
  equal(4, told.merges[1].value)
end

function tests.TwentyFortyEightRefusesAMoveThatChangesNothing()
  local game, state = slidingGame({ "2 4 . .", "4 . . .", ". . . .", ". . . ." })
  equal(false, (game.validate(state, 1, "l")), "everything is as far left as it goes")
  equal("invalid_move", select(2, game.validate(state, 1, "u")))
  equal(true, (game.validate(state, 1, "r")))
  equal(true, (game.validate(state, 1, "d")))
  equal("not_your_turn", select(2, game.validate(state, 2, "r")))
  for _, move in ipairs({ "", "x", "ll", "L", "left", "1" }) do
    equal("invalid_move", select(2, game.validate(state, 1, move)), "nothing is written " .. move)
  end
  -- A full line can still go if two of its tiles are worth the same
  game, state = slidingGame({ "2 4 8", "2 8 4", "4 2 8" })
  equal(false, (game.validate(state, 1, "l")))
  equal(false, (game.validate(state, 1, "r")))
  equal(true, (game.validate(state, 1, "u")))
  equal(true, (game.validate(state, 1, "d")))

  -- And the engine doesn't take one from the player either
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local match = assert(alice.session:Invite({}, "2048"))
  local refused = 0
  for _, way in ipairs({ "u", "d", "l", "r" }) do
    if not game.validate(alice.private.Match.State(match), 1, way) then
      equal("invalid_move", select(2, alice.session:Move(match.id, way)))
      refused = refused + 1
    end
  end
  equal(0, #match.log)
  assert(refused < 4, "there is always something to do at first")
end

function tests.TwentyFortyEightPutsANewTileOnAFreeSquare()
  local twos, fours, squares = 0, 0, {}
  local game, start, private = slidingGame({ "2 . . .", ". . . .", ". . . .", ". . . ." })
  for seed = 1, 600 do
    local state = copy(start)
    local _, event = slidingPush(game, state, "r", private, seed)
    assert(event.spawn.at ~= 4, "not where the tile went")
    equal(event.spawn.value, state.cells[event.spawn.at])
    squares[event.spawn.at] = true
    twos = twos + (event.spawn.value == 2 and 1 or 0)
    fours = fours + (event.spawn.value == 4 and 1 or 0)
  end
  equal(600, twos + fours)
  assert(fours > 30 and fours < 95, "one in ten is a 4, got " .. fours .. " of 600")
  local reached = 0
  for _ in pairs(squares) do
    reached = reached + 1
  end
  equal(15, reached, "anywhere that is free")

  -- With one square left that is where it goes
  local state
  game, state, private = slidingGame({ "2 4 8", "16 32 64", ". 128 256" })
  local _, event = slidingPush(game, state, "l", private)
  equal(9, event.spawn.at)
end

function tests.TwentyFortyEightGoesOnPastItsTileAndEndsWhenNothingMoves()
  -- Making the tile is noted, once, and is not the end
  local game, state, private = slidingGame({ "1024 1024 . .", ". . . .", ". . . .", ". . . ." })
  local _, event = slidingPush(game, state, "l", private)
  equal(true, event.reached)
  equal(true, state.reached)
  equal(2048, state.best)
  equal(2048, state.score)
  equal(nil, game.result(state), "the game goes on")
  equal(nil, event.over)
  state.cells = { 2048, 2048, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  _, event = slidingPush(game, state, "l", private)
  equal(nil, event.reached, "only the first time")
  equal(4096, state.best)
  equal(true, state.reached)
  equal(nil, game.result(state))

  -- On the small board it is 256
  game, state, private = slidingGame({ "128 128 .", ". . .", ". . ." })
  _, event = slidingPush(game, state, "r", private)
  equal(true, event.reached)

  -- No square free and no two neighbours the same: over, and lost without the tile
  local last = { "8 16 8", "32 8 16", ". 64 32" }
  game, state, private = slidingGame(last)
  equal(nil, game.result(state))
  _, event = slidingPush(game, state, "l", private)
  equal(true, event.over)
  equal(true, state.over)
  equal(0, game.result(state).winner)
  for _, way in ipairs({ "u", "d", "l", "r" }) do
    equal(false, (game.validate(state, 1, way)), "nothing moves any more")
  end
  -- Won if it was made on the way
  game, state, private = slidingGame(last)
  state.reached = true
  slidingPush(game, state, "l", private)
  equal(1, game.result(state).winner)
  -- A full board isn't over while two neighbours are worth the same
  game, state, private = slidingGame({ "8 16 8", "32 8 16", ". 64 8" })
  _, event = slidingPush(game, state, "l", private)
  equal(nil, event.over)
  equal(nil, game.result(state))
end

function tests.TwentyFortyEightSaysWhatItIsPlayedOn()
  local private = loadEngine()
  local Games, game = private.Games, private.Games.Get("2048")
  equal(4, Games.Rules(game.options).size)
  equal(3, Games.Rules(game.options, { size = 3 }).size)
  equal(4, Games.Rules(game.options, { size = 7 }).size, "only the boards there are")
  equal(nil, Games.EncodeOptions(game, { size = 4 }), "the usual board goes without saying")
  equal("size=5", Games.EncodeOptions(game, { size = 5 }))
  equal(5, Games.DecodeOptions(game, "size=5").size)
  equal(false, select(2, Games.DecodeOptions(game, "size=9")))
  equal("2048_option_size_label", Games.OptionLabel(game.options[1], 3))
  equal(1, #Games.DescribeOptions(game, { size = 3 }))
  equal(0, #Games.DescribeOptions(game, nil))
  equal("2048_progress", game.progress(game.newState(1, private.Random.New(1))))

  -- The board is kept with the match
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local small = assert(alice.session:Invite({}, "2048", { options = { size = 3 } }))
  equal(9, #alice.private.Match.State(small).cells)
  equal(3, small.options.size)
  local usual = assert(alice.session:Invite({}, "2048", { options = { size = 4 } }))
  equal(16, #alice.private.Match.State(usual).cells)
  equal(nil, usual.options)
end

function tests.TwentyFortyEightComesOutTheSameFromTheSameLog()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local Match, game = alice.private.Match, alice.private.Games.Get("2048")
  local match = assert(alice.session:Invite({}, "2048"))
  for _ = 1, 60 do
    local way = slidingMove(game, Match.State(match), alice.private, 1)
    if not way then
      break
    end
    assert(alice.session:Move(match.id, way))
  end
  assert(#match.log >= 40, "a game lasts a while")
  local played = slidingRows(Match.State(match))

  -- Whoever is handed the same match comes out with the same tiles in the same places
  local other = World.New():AddPlayer("Alice-Realm", { [match.id] = copy(match) })
  equal(played, slidingRows(other.private.Match.State(other.matches[match.id])))
  local elsewhere = assert(alice.session:Invite({}, "2048"))
  for _, way in ipairs(match.log) do
    if not alice.session:Move(elsewhere.id, way) then
      break
    end
  end
  assert(played ~= slidingRows(Match.State(elsewhere)), "and another match is another game")

  -- A move taken back and made again brings the same tile to the same square
  local last = match.log[#match.log]
  local spawn = Match.Events(match)[#match.log].spawn
  assert(alice.session:Undo(match.id))
  assert(played ~= slidingRows(Match.State(match)))
  assert(alice.session:Move(match.id, last))
  equal(played, slidingRows(Match.State(match)))
  equal(spawn.at, Match.Events(match)[#match.log].spawn.at)
  equal(spawn.value, Match.Events(match)[#match.log].spawn.value)
end

function tests.TwentyFortyEightIsPlayedThroughWithoutLosingATile()
  local private = loadEngine()
  local game = private.Games.Get("2048")
  local ways = { "l", "u", "r", "d" }
  local ended, merged = 0, 0
  for seed = 1, 40 do
    local size = 3 + seed % 3
    local dice = private.Random.New(seed)
    local state = game.newState(1, private.Random.New(seed + 1000), { size = size })
    local thinks = seed % 4 == 0
    local played = 0
    while not game.result(state) do
      -- Some think and some push any old way
      local way = thinks and slidingMove(game, state, private, 1) or nil
      while not way or not game.validate(state, 1, way) do
        way = ways[dice:Roll(4)]
      end
      local before, score = copy(state.cells), state.score
      local sum = 0
      for _, value in ipairs(before) do
        sum = sum + value
      end
      local event = game.apply(state, 1, way, private.Random.New(seed * 100000 + played))
      played = played + 1

      -- What the move says happened is what happened, to the last tile
      local follows = slidingFollow(before, event)
      local after, biggest = 0, 0
      for square, value in ipairs(state.cells) do
        equal(follows[square], value, "square " .. square .. " after " .. way)
        after, biggest = after + value, math.max(biggest, value)
        assert(value == 0 or math.log(value) / math.log(2) % 1 < 1e-9, "tiles are powers of two")
      end
      equal(sum + event.spawn.value, after, "nothing is lost and only the new tile is added")
      local gained = 0
      for _, merge in ipairs(event.merges) do
        gained = gained + merge.value
      end
      equal(gained, event.gained)
      equal(score + gained, state.score)
      equal(played, state.moves)
      equal(biggest, state.best)
      equal(state.best >= state.target, state.reached)
      merged = merged + #event.merges
      assert(played < 200000, "the game should end")
    end
    ended = ended + 1
    equal(state.reached and 1 or 0, game.result(state).winner)
    for _, way in ipairs(ways) do
      equal(false, (game.validate(state, 1, way)))
    end
  end
  equal(40, ended, "every game ends")
  assert(merged > 1000)
end

function tests.TwentyFortyEightKeepsTheBestOfEveryBoard()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local session, Match, game = alice.session, alice.private.Match, alice.private.Games.Get("2048")
  equal(nil, session:Best("2048", "score4"))

  --- Plays a match until it has scored something
  local function scoring(match)
    while Match.State(match).score == 0 do
      assert(session:Move(match.id, slidingMove(game, Match.State(match), alice.private, 1)))
    end
    return Match.State(match)
  end
  local match = assert(session:Invite({}, "2048"))
  local state = scoring(match)
  equal(state.score, session:Best("2048", "score4"), "asked after every move: a game given up half way still counts")
  equal(state.best, session:Best("2048", "tile4"))
  equal(true, session:SetBest(match, "score4"))
  equal(nil, session:Best("2048", "score3"), "every board has its own")

  local small = assert(session:Invite({}, "2048", { options = { size = 3 } }))
  local smallState = scoring(small)
  equal(smallState.score, session:Best("2048", "score3"))
  equal(smallState.best, session:Best("2048", "tile3"))
  equal(state.score, session:Best("2048", "score4"))

  -- A move taken back doesn't take the best back with it
  assert(session:Undo(match.id))
  assert(Match.State(match).score < state.score)
  equal(state.score, session:Best("2048", "score4"))
  assert(session:Resign(match.id))
  equal(state.score, session:Best("2048", "score4"))
end

-----------------------------
-- 2048 on screen
-----------------------------

--- A grid of sliding tiles on its own, three by three with tiles of 40 lying 10 apart, so that
--- the middle of a square is 20, 70 or 120 across and down
--- @return table grid, table frame, table private
local function gridOnItsOwn()
  Client.Install()
  ForeverGames = { db = { profile = { sound = true } } }
  local private = {}
  for _, file in ipairs({ "GUI/Widgets.lua", "GUI/Board.lua", "GUI/Tiles.lua", "GUI/SlideGrid.lua" }) do
    assert(loadfile(file))(ADDON_NAME, private)
  end
  local grid = private.SlideGrid.New(CreateFrame("Frame", nil, UIParent), {
    art = "art\\",
    style = function(value)
      return tostring(value), { 1, 1, 1 }, { 0, 0, 0 }, value >= 100 and 0.5 or nil
    end,
  })
  grid:Arrange(3, 3, 40, 10)
  return grid, grid.frame, private
end

--- The tiles a grid shows, as "square=value" in the order of the squares, wherever they are
--- on their way to
--- @param grid table
--- @return string
local function gridTiles(grid)
  local tiles = {}
  for square = 1, grid.columns * grid.rows do
    local sprite = grid.at[square]
    if sprite then
      tiles[#tiles + 1] = square .. "=" .. sprite.value
    end
  end
  return table.concat(tiles, " ")
end

--- How many tiles of a grid can be seen, whether it knows about them or not
--- @param grid table
--- @return number
local function gridShown(grid)
  return #Client.Find(function(widget)
    return widget.parent == grid.frame and widget.label ~= nil and widget:IsVisible()
  end)
end

--- Checks that a grid has come to rest on a position: a tile on every square that has one,
--- where it belongs and at its size, and no other anywhere
--- @param grid table
--- @param cells number[]
local function gridRestsOn(grid, cells)
  local count = 0
  for square = 1, grid.columns * grid.rows do
    local sprite, value = grid.at[square], cells[square]
    if not value or value == 0 then
      equal(nil, sprite, "nothing on square " .. square)
    else
      count = count + 1
      assert(sprite, "a tile on square " .. square)
      equal(value, sprite.value, "square " .. square)
      equal(tostring(value), sprite.label.text)
      local x, y = grid:Center(square)
      equal(x .. "," .. y, sprite.x .. "," .. sprite.y, "where the tile of square " .. square .. " is")
      equal(1, sprite.scale)
      equal(1, sprite:GetAlpha())
      equal(true, sprite:IsVisible())
    end
  end
  equal(count, gridShown(grid), "tiles to be seen")
end

function tests.LetteringDrawsACharacterAtATime()
  Client.Install()
  local private = {}
  for _, file in ipairs({ "GUI/LetteringGlyphs.lua", "GUI/Lettering.lua" }) do
    assert(loadfile(file))(ADDON_NAME, private)
  end
  local glyphs = private.LetteringGlyphs
  local count = 0
  for _ in pairs(glyphs.glyphs) do
    count = count + 1
  end
  equal(true, count <= glyphs.columns * glyphs.columns, "every character has a square of its own")
  local line = private.Lettering.New(CreateFrame("Frame", nil, UIParent), 20)
  local function shown(set)
    local count = 0
    for _, texture in ipairs(set) do
      count = count + (texture.shown and 1 or 0)
    end
    return count
  end

  -- As wide as the characters move the pen, a space for one there is no picture of
  line:SetText("ab|cff808080·|rZ9?")
  equal("ab|cff808080·|rZ9?", line:GetText())
  equal(5, shown(line.glyphs), "the colour codes and the ? aren't characters drawn")
  local wide = (glyphs.glyphs.a[2] + glyphs.glyphs.b[2] + glyphs.glyphs["·"][2] + glyphs.glyphs.Z[2] + glyphs.glyphs["9"][2] + glyphs.space) * 20
  assert(math.abs(line:GetStringWidth() - wide) < 1e-6)
  equal((glyphs.ascent + glyphs.descent) * 20, line.height)
  -- The dot in its own colour, the others in the line's
  line:SetTextColor(1, 0.5, 0)
  equal("1,0.5,0,1", table.concat(line.glyphs[1].color, ","))
  equal(string.format("%.3f", 0x80 / 255), string.format("%.3f", line.glyphs[3].color[1]))
  equal(0, shown(line.shadows))

  -- A shadow is another of each, and fewer characters hide what isn't needed
  line:SetShadow({ 0, 0, 0, 0.6 }, 0, -1)
  equal(5, shown(line.shadows))
  line:SetText("ok")
  equal(2, shown(line.glyphs))
  equal(2, shown(line.shadows))

  -- The smallest picture that isn't shrunk much, the largest when none is large enough. The
  -- screen is 1080 pixels high, so a size of 14 is 20 pixels
  local paths = {}
  for _, size in ipairs({ 8, 14, 40, 200 }) do
    line:SetFontSize(size)
    paths[#paths + 1] = line.glyphs[1].texture:match("(%d+)$")
  end
  equal("128,256,512,512", table.concat(paths, ","))
end

function tests.SlideGridPutsTilesOnItsSquares()
  local grid, frame = gridOnItsOwn()
  equal(140, frame.width)
  equal(140, frame.height)
  equal("20,20", table.concat({ grid:Center(1) }, ","))
  equal("120,70", table.concat({ grid:Center(6) }, ","))
  equal(0, gridShown(grid))

  grid:Set({ [1] = 2, [5] = 128, [9] = 0, [3] = false })
  equal(false, grid:Busy(), "it is simply there")
  equal("1=2 5=128", gridTiles(grid))
  gridRestsOn(grid, { [1] = 2, [5] = 128 })
  equal("art\\64\\tile", grid.at[1].body.texture, "the picture that suits its size")
  equal(false, grid.at[1].glow:IsShown())
  equal(true, grid.at[5].glow:IsShown(), "as the style says")

  -- Another position uses the tiles there are, and puts aside what it has no use for
  local kept = grid.at[1]
  grid:Set({ [1] = 4, [2] = 2 })
  equal(kept, grid.at[1])
  equal("4", kept.label.text)
  gridRestsOn(grid, { [1] = 4, [2] = 2 })
  equal(0, #grid.spare, "the one it had no use for on one square is the one it needed on another")
  grid:Set({ [1] = 4 })
  equal(1, #grid.spare)
  grid:Set({ 2, 2, 2, 2 })
  equal(0, #grid.spare, "and what was put aside is taken back out")
  grid:Set({})
  equal(0, gridShown(grid))
  equal(4, #grid.spare)

  -- A bigger tile is the same tiles drawn bigger, what is written on them included
  grid:Set({ [2] = 2, [9] = 16384 })
  local small, long = grid.at[2].font, grid.at[9].font
  assert(long < small, "a long number is written smaller to fit")
  grid:Arrange(3, 3, 120, 20)
  equal(400, frame.width)
  gridRestsOn(grid, { [2] = 2, [9] = 16384 })
  equal(120, grid.at[2].width)
  assert(grid.at[2].font > small and grid.at[9].font > long)
  equal("art\\256\\tile", grid.at[2].body.texture, "from a bigger picture")
  -- On a grid of other squares nothing of it means anything any more
  grid:Arrange(4, 4, 40, 10)
  equal(0, gridShown(grid))
  equal("", gridTiles(grid))
end

function tests.SlideGridSlidesTilesTogetherAndMakesOneOfThem()
  local grid, frame = gridOnItsOwn()
  grid:Set({ [1] = 2, [3] = 2, [4] = 8 })
  local first, second, still = grid.at[1], grid.at[3], grid.at[4]
  local after = { [1] = 4, [4] = 8, [8] = 2 }
  local landed = grid:Animate({
    moves = { { from = 1, to = 1, value = 2 }, { from = 3, to = 1, value = 2 }, { from = 4, to = 4, value = 8 } },
    merges = { { at = 1, value = 4 } },
    appear = { { at = 8, value = 2 } },
  }, after)
  assert(landed > 0 and landed < 0.3, "a slide is quick")
  equal(true, grid:Busy())
  equal(3, gridShown(grid), "what comes of it isn't there yet")

  -- Both tiles are on the table until they meet, the one that travels getting there fast at first
  frame:Fire("OnUpdate", landed / 4)
  assert(second.x < 120 and second.x > 20, "on its way, at " .. second.x)
  assert(second.x < 85, "more than a quarter of the way in a quarter of the time")
  equal(20, first.x)
  equal(70, still.y)
  equal(true, first:IsVisible() and second:IsVisible())
  equal(3, gridShown(grid))

  -- When they have arrived there is one tile in their place, which swells, and then the new one grows
  frame:Fire("OnUpdate", landed * 0.75 + 0.02)
  equal(false, first:IsVisible() or second:IsVisible(), "the two that met are gone")
  local made, born = grid.at[1], grid.at[8]
  equal(4, made.value)
  equal(true, made:IsVisible())
  equal(true, born:IsVisible())
  assert(born.scale < 1 and born.scale > 0, "the new one is growing, at " .. born.scale)
  frame:Fire("OnUpdate", 0.05)
  assert(made.scale > 1, "the tile that was made swells, at " .. made.scale)
  assert(born.scale > 0.9, "and the new one is nearly there, at " .. born.scale)
  equal(true, grid:Busy())
  passTime(frame, 1)
  equal(false, grid:Busy())
  gridRestsOn(grid, after)
  equal(still, grid.at[4], "a tile that stayed is the tile it was")
  equal(2, #grid.spare)

  -- The other way round: a tile comes apart into two, and one goes away
  grid:Animate({
    moves = { { from = 1, to = 1, value = 2 }, { from = 1, to = 3, value = 2 }, { from = 4, to = 4, value = 8 } },
    vanish = { 8 },
  }, { [1] = 2, [3] = 2, [4] = 8 })
  equal(4, gridShown(grid), "two where one was, and the one that is leaving")
  frame:Fire("OnUpdate", 0.04)
  assert(born.scale < 1, "going")
  assert(grid.at[3].x > 20 and grid.at[3].x < 120)
  passTime(frame, 1)
  gridRestsOn(grid, { [1] = 2, [3] = 2, [4] = 8 })

  -- Whatever it was told on the way, it ends on the position it was given
  local astray = { { from = 7, to = 9, value = 64 }, { from = 1, to = 2, value = 2 }, { from = 4, to = 2, value = 8 } }
  grid:Animate({ moves = astray }, { [5] = 16 })
  passTime(frame, 1)
  gridRestsOn(grid, { [5] = 16 })
end

function tests.SlideGridGetsThereAtOnceWhenAskedForMore()
  local grid, frame = gridOnItsOwn()
  grid:Set({ [1] = 2, [2] = 2 })
  local first = { [1] = 4, [9] = 2 }
  local function push()
    grid:Animate({
      moves = { { from = 1, to = 1, value = 2 }, { from = 2, to = 1, value = 2 } },
      merges = { { at = 1, value = 4 } },
      appear = { { at = 9, value = 2 } },
    }, first)
  end

  -- Finish takes everything to its end, and so does putting another position on
  push()
  frame:Fire("OnUpdate", 0.02)
  grid:Finish()
  equal(false, grid:Busy())
  gridRestsOn(grid, first)
  grid:Set({ [1] = 2, [2] = 2 })
  push()
  grid:Set({ [5] = 8 })
  equal(false, grid:Busy())
  gridRestsOn(grid, { [5] = 8 })

  -- The next move starts from where the last one ends, not from where its tiles had got to
  grid:Set({ [1] = 2, [2] = 2 })
  push()
  frame:Fire("OnUpdate", 0.02)
  local second = { [3] = 4, [9] = 2, [4] = 2 }
  local across = { { from = 1, to = 3, value = 4 }, { from = 9, to = 9, value = 2 } }
  grid:Animate({ moves = across, appear = { { at = 4, value = 2 } } }, second)
  equal(true, grid:Busy())
  equal(4, grid.at[3].value)
  equal(20, grid.at[3].x, "setting out from the square the last move left it on")
  equal(2, gridShown(grid), "nothing of the move before is left lying about")
  passTime(frame, 1)
  gridRestsOn(grid, second)

  -- Resizing doesn't wait either, and hiding it leaves nothing hanging in the air
  push = function()
    local back = { { from = 3, to = 1, value = 4 }, { from = 4, to = 4, value = 2 }, { from = 9, to = 7, value = 2 } }
    grid:Animate({ moves = back }, { [1] = 4, [4] = 2, [7] = 2 })
  end
  push()
  grid:Arrange(3, 3, 60, 10)
  equal(false, grid:Busy())
  gridRestsOn(grid, { [1] = 4, [4] = 2, [7] = 2 })
  equal(30, grid.at[1].x)
  grid:Set(second)
  push()
  frame:Hide()
  equal(false, grid:Busy())
  frame:Show()
  gridRestsOn(grid, { [1] = 4, [4] = 2, [7] = 2 })
end

function tests.SlideGridLeansIntoAMoveThatIsNotOne()
  local grid, frame = gridOnItsOwn()
  local cells = { [1] = 2, [5] = 4 }
  grid:Set(cells)
  local anchored = {}
  local sprite = grid.at[5]
  function sprite:SetPoint(_, _, _, x, y)
    anchored[#anchored + 1] = { x, y }
  end

  grid:Nudge(-1, 0)
  equal(true, grid:Busy())
  passTime(frame, 0.08)
  local leant = anchored[#anchored]
  assert(leant[1] < 70 and leant[1] > 60, "a little to the left, at " .. leant[1])
  equal(-70, leant[2])
  passTime(frame, 1)
  equal(false, grid:Busy())
  equal("70,-70", table.concat(anchored[#anchored], ","), "and back")
  gridRestsOn(grid, cells)

  -- One after the other, each from where the tiles belong
  grid:Nudge(0, 1)
  frame:Fire("OnUpdate", 0.08)
  grid:Nudge(0, -1)
  frame:Fire("OnUpdate", 0.08)
  leant = anchored[#anchored]
  equal(70, leant[1])
  assert(leant[2] > -70, "up, at " .. leant[2])
  grid:Finish()
  equal("70,-70", table.concat(anchored[#anchored], ","))
end

function tests.SlideGridIsPlayedOnByDragging()
  local grid = gridOnItsOwn()
  local swiped, taps = {}, 0
  grid:Swipes(function(across, down)
    swiped[#swiped + 1] = across .. "," .. down
  end, function()
    taps = taps + 1
  end)
  local touch = grid.touch
  local function drag(x, y, button)
    Client.cursor = { 100, 100 }
    touch:Fire("OnMouseDown", button or "LeftButton")
    touch:Fire("OnUpdate", 0.02)
    Client.cursor = { 100 + x, 100 + y }
    touch:Fire("OnUpdate", 0.02)
    touch:Fire("OnMouseUp", button or "LeftButton")
  end

  drag(30, 4)
  drag(-30, -9)
  -- The screen is measured from the bottom up
  drag(5, 40)
  drag(-12, -25)
  equal("1,0 -1,0 0,-1 0,1", table.concat(swiped, " "))
  equal(0, taps)

  -- Not far enough to have said anything is a click, and the other button is nothing at all
  drag(5, -6)
  equal(4, #swiped)
  equal(1, taps)
  drag(40, 0, "RightButton")
  equal(4, #swiped)
  equal(1, taps)

  -- Pulling on without letting go is the next move, told once each
  Client.cursor = { 100, 100 }
  touch:Fire("OnMouseDown", "LeftButton")
  Client.cursor = { 130, 100 }
  touch:Fire("OnUpdate", 0.02)
  touch:Fire("OnUpdate", 0.02)
  equal(5, #swiped)
  Client.cursor = { 132, 60 }
  touch:Fire("OnUpdate", 0.02)
  touch:Fire("OnMouseUp", "LeftButton")
  equal("1,0 0,1", table.concat(swiped, " ", 5))
  equal(1, taps, "what was pulled isn't a click as well")

  -- A button let go of while nobody was looking is forgotten
  touch:Fire("OnMouseDown", "LeftButton")
  touch:Hide()
  touch:Show()
  Client.cursor = { 300, 300 }
  touch:Fire("OnUpdate", 0.02)
  equal(6, #swiped)
end

--- Opens the window on a new game of 2048
--- @param size number? How many squares each way, the usual four if left out
--- @param seed number?
--- @return table player, string id, table MainFrame
local function slidingOnScreen(size, seed)
  local world = World.New()
  world.seed = seed or 1
  local player = world:AddPlayer("Alice-Realm")
  local MainFrame = openWindow(player)
  -- Whatever is asked is answered with a yes
  function StaticPopup_Show(which, _, _, data)
    StaticPopupDialogs[which].OnAccept(nil, data)
  end
  local match = assert(player.session:Invite({}, "2048", { options = { size = size } }))
  MainFrame.Open(match.id)
  return player, match.id, MainFrame
end

--- The grid of the game on screen, and the stage it is played on
--- @return table grid, table frame, table stage
local function shownGrid()
  local found = Client.Find(function(widget)
    return widget.slideGrid ~= nil and widget:IsVisible()
  end)
  equal(1, #found, "grids on screen")
  return found[1].slideGrid, found[1], found[1].parent.parent
end

--- Lets time pass for everything of the game on screen
--- @param seconds number
local function slidingTime(seconds)
  local _, _, stage = shownGrid()
  local ticking = Client.Find(function(widget)
    local inside = widget.parent
    while inside and inside ~= stage do
      inside = inside.parent
    end
    return inside == stage and widget.scripts.OnUpdate ~= nil and widget:IsVisible()
  end)
  for _ = 1, math.floor(seconds / 0.02 + 0.5) do
    for _, widget in ipairs(ticking) do
      widget:Fire("OnUpdate", 0.02)
    end
  end
end

--- Presses a key with the cursor over the game on screen
--- @param key string
--- @return boolean Whether the game kept it to itself
local function slidingKey(key)
  local _, _, stage = shownGrid()
  local found = Client.Find(function(widget)
    return widget.parent == stage and widget.scripts.OnKeyDown ~= nil
  end)
  equal(1, #found, "what takes the keys")
  found[1]:Fire("OnKeyDown", key)
  return found[1].propagates == false
end

--- The arrow of the game on screen that pushes one way
--- @param way string
--- @return table
local function slidingArrow(way)
  local _, _, stage = shownGrid()
  local found = Client.Find(function(widget)
    return widget.kind == "Button" and widget.parent == stage and widget.Lit ~= nil and widget:IsVisible()
  end)
  equal(4, #found, "arrows next to the board")
  return found[({ u = 1, l = 2, r = 3, d = 4 })[way]]
end

--- Drags across the board of the game on screen
--- @param way string
local function slidingDrag(way)
  local grid = shownGrid()
  local towards = ({ u = { 0, 30 }, d = { 0, -30 }, l = { -30, 0 }, r = { 30, 0 } })[way]
  Client.cursor = { 200, 200 }
  grid.touch:Fire("OnMouseDown", "LeftButton")
  Client.cursor = { 200 + towards[1], 200 + towards[2] }
  grid.touch:Fire("OnUpdate", 0.02)
  grid.touch:Fire("OnMouseUp", "LeftButton")
end

--- Pushes the tiles of the game on screen the way a player would, a different way every time
--- @param way string
--- @param turn number
local function slidingPlay(way, turn)
  if turn % 3 == 0 then
    equal(true, slidingKey(({ u = "UP", d = "DOWN", l = "LEFT", r = "RIGHT" })[way]))
  elseif turn % 3 == 1 then
    slidingArrow(way):Fire("OnClick")
  else
    slidingDrag(way)
  end
end

--- A way the tiles of a position can't be pushed, if there is one
--- @param game table
--- @param state table
--- @return string?
local function slidingStuck(game, state)
  for _, way in ipairs({ "l", "u", "r", "d" }) do
    if not game.validate(state, 1, way) then
      return way
    end
  end
  return nil
end

function tests.WindowShows2048TilesSliding()
  local player, id = slidingOnScreen()
  local Match, game = player.private.Match, player.private.Games.Get("2048")
  local match = player.matches[id]
  local grid, frame = shownGrid()

  -- Nobody to play against: the game, how it is going, and what is kept count of
  equal(true, says("game_2048"))
  equal(true, says("2048_progress"))
  equal(false, says("status_your_turn"))
  equal(true, says("stat_score") and says("stat_best") and says("2048_stat_tile"))
  equal(true, says("2048_hint"))
  equal(true, says("stat_none"), "no best yet")
  equal(false, Client.Button("undo").enabled, "nothing to take back yet")
  equal(false, grid:Busy(), "the tiles are simply there")
  equal(4, grid.columns)
  gridRestsOn(grid, Match.State(match).cells)
  equal(2, gridShown(grid))

  -- A push sets them sliding: for a moment they are on their way, then where the game has them
  local way = slidingMove(game, Match.State(match), player.private)
  local before = copy(Match.State(match).cells)
  equal(true, slidingKey(({ u = "UP", d = "DOWN", l = "LEFT", r = "RIGHT" })[way]))
  equal(way, logOf(player, id))
  local event = Match.Events(match)[1]
  equal(true, grid:Busy())
  equal("cardSlide", Client.sounds[#Client.sounds])
  local moving
  for _, slide in ipairs(event.slides) do
    moving = moving or (slide.from ~= slide.to and slide or nil)
  end
  local sprite = grid.at[moving.to]
  local fromX, fromY = grid:Center(moving.from)
  local toX, toY = grid:Center(moving.to)
  equal(fromX .. "," .. fromY, sprite.x .. "," .. sprite.y, "it sets out from where it lay")
  frame:Fire("OnUpdate", 0.03)
  local between = (sprite.x - fromX) * (toX - sprite.x) + (sprite.y - fromY) * (toY - sprite.y)
  assert(between > 0, "on its way from one square to the other")
  equal(false, grid.at[event.spawn.at]:IsVisible(), "the new tile waits for the others to arrive")
  equal(#event.slides, gridShown(grid))
  slidingTime(1)
  equal(false, grid:Busy())
  gridRestsOn(grid, Match.State(match).cells)
  equal(true, Client.Button("undo").enabled)
  assert(before[moving.from] == moving.value)

  -- Nothing starts over when the window only looks again
  player.private.MainFrame.Refresh()
  player.private.MainFrame.Refresh()
  equal(false, grid:Busy())
  gridRestsOn(grid, Match.State(match).cells)
end

function tests.WindowPlays2048WithKeysArrowsAndDrags()
  local player, id = slidingOnScreen()
  local Match, game = player.private.Match, player.private.Games.Get("2048")
  local match = player.matches[id]
  local grid = shownGrid()

  -- Every way of pushing makes the move it stands for, however fast one follows the other
  local merges, floated = 0, false
  for turn = 1, 90 do
    local state = Match.State(match)
    local way = slidingMove(game, state, player.private, 1)
    slidingPlay(way, turn)
    equal(turn, #match.log, "a move for every push")
    equal(way, match.log[turn])
    local event = Match.Events(match)[turn]
    merges = merges + #event.merges
    if #event.merges > 0 then
      equal("chipsCollide", Client.sounds[#Client.sounds - (event.merges[1].value >= 256 and 1 or 0)])
      slidingTime(0.3)
      floated = floated or says("+" .. event.merges[1].value)
    end
    -- Some are left the time to finish and some are not: either way the tiles end up right
    if turn % 4 == 0 then
      slidingTime(0.6)
      equal(false, grid:Busy())
      gridRestsOn(grid, Match.State(match).cells)
    elseif turn % 4 == 1 then
      slidingTime(0.04)
    end
    equal(tostring(Match.State(match).score), Client.Find(function(widget)
      return widget.caption ~= nil and widget.caption.text == "stat_score" and widget:IsVisible()
    end)[1].value.text, "the score is kept up with")
  end
  assert(merges > 20, "tiles were made")
  equal(true, floated, "what a move scores drifts up from it")
  slidingTime(2)
  gridRestsOn(grid, Match.State(match).cells)

  -- W, A, S and D are the arrows, any other key is none of the game's business
  local state = Match.State(match)
  local way = slidingMove(game, state, player.private, 1)
  equal(true, slidingKey(({ u = "W", d = "S", l = "A", r = "D" })[way]))
  equal(91, #match.log)
  equal(way, match.log[91])
  equal(false, slidingKey("SPACE"))
  equal(false, slidingKey("1"))
  equal(91, #match.log)
  -- The arrow a key stands for lights up for a moment
  equal(true, slidingArrow(way).lit)
  slidingTime(0.5)
  equal(false, slidingArrow(way).lit)

  -- Not while the cursor is somewhere else, and not in combat
  Client.over = false
  equal(false, slidingKey("LEFT"))
  equal(false, slidingKey("UP"))
  Client.over, Client.combat = true, true
  equal(false, slidingKey("LEFT"))
  equal(false, slidingKey("UP"))
  Client.combat = false
  equal(91, #match.log)

  -- A click on the board that goes nowhere shows what there is to push with
  grid.touch:Fire("OnMouseDown", "LeftButton")
  grid.touch:Fire("OnMouseUp", "LeftButton")
  equal(91, #match.log)
  equal(true, slidingArrow("u").lit and slidingArrow("d").lit)
  slidingTime(1)
  equal(false, slidingArrow("u").lit)

  -- The best follows the score, and is this game's
  equal(Match.State(match).score, player.session:Best("2048", "score4"))
  local best = Client.Find(function(widget)
    return widget.caption ~= nil and widget.caption.text == "stat_best" and widget:IsVisible()
  end)[1]
  equal(tostring(Match.State(match).score), best.value.text)
  equal(false, says("stat_none"))
end

function tests.WindowNudgesA2048MoveThatChangesNothing()
  local player, id = slidingOnScreen()
  local Match, game = player.private.Match, player.private.Games.Get("2048")
  local match = player.matches[id]
  local grid = shownGrid()

  -- Push into a corner until one way is closed
  local stuck = slidingStuck(game, Match.State(match))
  local turns = 0
  while not stuck do
    turns = turns + 1
    slidingPlay(turns % 2 == 0 and "l" or "u", turns)
    stuck = slidingStuck(game, Match.State(match))
    assert(turns < 50, "tiles pushed into a corner get stuck there")
  end
  slidingTime(1)
  local made = #match.log
  local cells = Match.State(match).cells

  for turn = 1, 3 do
    local sounds = #Client.sounds
    slidingPlay(stuck, turn)
    equal(made, #match.log, "no move is made")
    equal(0, #ForeverGames.printed, "and nothing is said about it in chat")
    equal(true, grid:Busy(), "the tiles lean into it instead")
    equal(sounds + 1, #Client.sounds)
    equal("IG_MAINMENU_OPTION_CHECKBOX_OFF", Client.sounds[#Client.sounds])
    slidingTime(0.5)
    equal(false, grid:Busy())
    gridRestsOn(grid, cells)
  end
  -- The key was the game's all the same: the character doesn't walk off because of it
  equal(true, slidingKey(({ u = "UP", d = "DOWN", l = "LEFT", r = "RIGHT" })[stuck]))

  -- A nudge that is still going doesn't hold a real move up
  slidingPlay(stuck, 1)
  local way = slidingMove(game, Match.State(match), player.private, 1)
  slidingPlay(way, 2)
  equal(made + 1, #match.log)
  slidingTime(1)
  gridRestsOn(grid, Match.State(match).cells)
end

function tests.WindowTakesA2048MoveBack()
  local player, id = slidingOnScreen()
  local Match, game = player.private.Match, player.private.Games.Get("2048")
  local match = player.matches[id]
  local grid, frame = shownGrid()

  local positions = { copy(Match.State(match).cells) }
  local turn = 0
  -- Until two tiles have just become one
  while turn < 3 or #Match.Events(match)[turn].merges == 0 do
    turn = turn + 1
    slidingPlay(slidingMove(game, Match.State(match), player.private, 1), turn)
    positions[turn + 1] = copy(Match.State(match).cells)
    assert(turn < 60, "sooner or later two tiles meet")
  end
  slidingTime(1)
  local event = Match.Events(match)[turn]
  local merge = event.merges[1]
  local made = grid.at[merge.at]
  local tiles = gridShown(grid)

  -- Undo shows the move backwards: the new tile goes, the one that was made comes apart
  Client.Button("undo"):Fire("OnClick")
  equal(turn - 1, #match.log)
  equal(true, grid:Busy())
  equal("cardSlide", Client.sounds[#Client.sounds])
  equal(tiles + #event.merges, gridShown(grid), "two again where there was one")
  equal(merge.value / 2, made.value)
  frame:Fire("OnUpdate", 0.04)
  slidingTime(1)
  equal(false, grid:Busy())
  gridRestsOn(grid, positions[turn])
  equal(tiles + #event.merges - 1, gridShown(grid))

  -- And again, faster than the tiles, all the way to the beginning
  for back = turn - 1, 1, -1 do
    Client.Button("undo"):Fire("OnClick")
    equal(back - 1, #match.log)
    if back % 2 == 0 then
      slidingTime(1)
      gridRestsOn(grid, positions[back])
    end
  end
  slidingTime(1)
  gridRestsOn(grid, positions[1])
  equal(2, gridShown(grid))
  equal(false, Client.Button("undo").enabled)

  -- The same push brings the same tile back to the same square
  slidingPlay(match.log[1] or slidingMove(game, Match.State(match), player.private, 1), 0)
  slidingTime(1)
  gridRestsOn(grid, Match.State(match).cells)
end

function tests.WindowFits2048IntoTheRoomItHas()
  for _, size in ipairs({ 3, 4, 5 }) do
    local player, id = slidingOnScreen(size)
    local Match, game = player.private.Match, player.private.Games.Get("2048")
    local match = player.matches[id]
    local grid, frame, stage = shownGrid()
    equal(size, grid.columns)
    equal(size, grid.rows)
    for turn = 1, 12 do
      slidingPlay(slidingMove(game, Match.State(match), player.private, 1), turn)
    end

    local function fits()
      local tray = frame.parent
      assert(tray.width <= stage.width - 2 * 86 and tray.height <= stage.height, "the board leaves room either side of it")
      equal(tray.width, tray.height)
      assert(frame.width < tray.width and frame.width > tray.width * 0.9, "the tiles fill the board")
      assert(grid.side >= 36, "tiles big enough to read, got " .. grid.side)
      equal(grid.side, math.floor(grid.side), "on whole pixels")
      local x, y = grid:Center(size * size)
      assert(x + grid.side / 2 <= frame.width and y + grid.side / 2 <= frame.height)
      for _, way in ipairs({ "u", "l", "r", "d" }) do
        local arrow = slidingArrow(way)
        assert(arrow.width >= 22 and arrow.width == arrow.height, "arrows big enough to hit")
      end
      local stats = Client.Find(function(widget)
        return widget.caption ~= nil and widget.parent == stage and widget:IsVisible()
      end)
      equal(3, #stats)
      for _, stat in ipairs(stats) do
        assert(stat.width >= 70 and stat.width <= (stage.width - tray.width) / 2, "what is kept count of fits next to the board")
      end
      equal(false, grid:Busy(), "the tiles are simply there, not on their way")
      gridRestsOn(grid, Match.State(match).cells)
    end

    slidingTime(1)
    local normal = grid.side
    fits()
    -- Resized in the middle of a move
    slidingPlay(slidingMove(game, Match.State(match), player.private, 1), 1)
    equal(true, grid:Busy())
    ForeverGamesFrame:SetSize(1500, 1100)
    assert(grid.side > normal * 1.4, "a bigger window should mean bigger tiles")
    fits()
    assert(grid.at[next(grid.at)].body.texture:find("256\\tile$"), "drawn from a bigger picture")
    ForeverGamesFrame:SetSize(764, 560)
    assert(grid.side < normal)
    fits()
  end
end

function tests.WindowCelebrates2048AndSaysWhenItIsOver()
  local player, id, MainFrame = slidingOnScreen(3, 3)
  local Match, game = player.private.Match, player.private.Games.Get("2048")
  local match = player.matches[id]
  local grid, _, stage = shownGrid()
  equal(256, Match.State(match).target)
  --- What someone who means to get there pushes next: on a board this small that takes knowing
  --- which tiles are coming, and the log says
  local function careful()
    return slidingMove(game, Match.State(match), player.private, 4, slidingChance(player.private, match))
  end

  --- How many pieces of paper are in the air
  local function papers()
    return #Client.Find(function(widget)
      local paper = widget.kind == "Texture" and widget.texture == "Interface\\Buttons\\WHITE8X8"
      return paper and widget.parent.parent == stage and widget:IsVisible()
    end)
  end

  -- Play it like someone who means to get there, until the tile is made
  local turn = 0
  while not Match.State(match).reached do
    assert(match.status == "active", "the tile should be made before the board is full, after " .. turn .. " moves")
    turn = turn + 1
    slidingPlay(careful(), turn)
    if not Match.State(match).reached then
      equal(0, papers())
    end
  end
  equal(true, Match.Events(match)[turn].reached)
  equal("UI_EPICLOOT_TOAST", Client.sounds[#Client.sounds])
  equal("active", match.status, "which is not the end")
  slidingTime(0.6)
  assert(papers() > 20, "paper rains down")
  equal(true, says("2048_reached"))
  equal(false, says("2048_over"))

  -- And the game goes on under it, right away
  slidingPlay(careful(), 0)
  equal(turn + 1, #match.log)
  turn = turn + 1
  slidingTime(5)
  equal(0, papers(), "the show is over by itself")
  equal(false, says("2048_reached"))
  gridRestsOn(grid, Match.State(match).cells)

  -- Until nothing moves any more
  while match.status == "active" do
    turn = turn + 1
    slidingPlay(slidingMove(game, Match.State(match), player.private, 1), turn)
    equal(0, papers(), "once is enough")
  end
  local state = Match.State(match)
  equal(true, state.over)
  equal(1, Match.Result(match).winner, "won, for having made the tile")
  equal("IG_QUEST_LOG_ABANDON_QUEST", Client.sounds[#Client.sounds])
  equal(true, says("status_won_with"))
  equal(false, says("2048_over"), "the last tile lands first")
  slidingTime(2)
  equal(true, says("2048_over"))
  equal(true, says("2048_final  new_best"), "the best this board was ever played")
  gridRestsOn(grid, state.cells)

  -- Nothing moves any more, by any means
  local made = #match.log
  for _, way in ipairs({ "u", "d", "l", "r" }) do
    slidingArrow(way):Fire("OnClick")
    slidingDrag(way)
    equal(false, grid:Busy(), "not even a nudge")
    equal(false, slidingArrow(way).usable, "and the arrows say so")
  end
  equal(false, slidingKey("LEFT"), "and the keys are the character's again")
  equal(made, #match.log)
  equal(0, #Client.Find(function(widget)
    return widget.kind == "Button" and widget.text == "undo" and widget:IsVisible()
  end))

  -- Another game is played on a clean board of the same size, and the best is there to beat
  Client.Button("play_again"):Fire("OnClick")
  equal(2, #player.session:List())
  equal(false, MainFrame.IsViewing(id))
  equal(false, says("2048_over"))
  grid = shownGrid()
  equal(3, grid.columns)
  equal(2, gridShown(grid))
  local best = Client.Find(function(widget)
    return widget.caption ~= nil and widget.caption.text == "stat_best" and widget:IsVisible()
  end)[1]
  equal(tostring(state.score), best.value.text)

  -- Looking at the one that is over again finds it the way it ended, without the entrance
  MainFrame.Open(id)
  equal(true, says("2048_over"))
  equal(true, says("2048_final  new_best"))
  equal(false, grid:Busy())
  gridRestsOn(grid, state.cells)
  equal(0, papers())
  MainFrame.Refresh()
  equal(true, says("2048_over"))
end

function tests.WindowSaysWhenA2048GameIsLost()
  local player, id, MainFrame = slidingOnScreen(3, 2)
  local Match = player.private.Match
  local match = player.matches[id]
  local grid = shownGrid()

  -- Pushed about without a thought the small board is full in no time
  local ways, turn = { "l", "u", "r", "d" }, 0
  while match.status == "active" do
    turn = turn + 1
    slidingPlay(ways[turn % 4 + 1], turn)
    assert(turn < 4000, "the game should end")
  end
  local state = Match.State(match)
  equal(false, state.reached)
  equal(0, Match.Result(match).winner)
  equal(true, says("status_solo_lost_with"), "lost, which isn't giving up")
  slidingTime(2)
  equal(true, says("2048_over"))
  gridRestsOn(grid, state.cells)

  -- A game that was given up says nothing across the board
  local other = assert(player.session:Invite({}, "2048"))
  MainFrame.Open(other.id)
  equal(false, says("2048_over"))
  equal(4, grid.columns, "the board of the game that is looked at")
  slidingPlay("l", 0)
  slidingPlay("u", 1)
  slidingPlay("r", 2)
  Client.Button("give_up"):Fire("OnClick")
  equal(nil, player.matches[other.id])
  equal(true, MainFrame.IsViewing(id) or not says("2048_over"))
end

-----------------------------
-- Solitaire on screen
-----------------------------

--- Opens the window on a new game of solitaire
--- @return table player, string id, table MainFrame
local function solitaireOnScreen()
  local world = World.New()
  world.seed = 1
  local player = world:AddPlayer("Alice-Realm")
  local MainFrame = openWindow(player)
  -- Whatever is asked is answered with a yes
  function StaticPopup_Show(which, _, _, data)
    StaticPopupDialogs[which].OnAccept(nil, data)
  end
  local match = assert(player.session:Invite({}, "solitaire"))
  MainFrame.Open(match.id)
  return player, match.id, MainFrame
end

--- Whether the game on screen offers to play itself out
--- @return boolean
local function finishOffered()
  return #Client.Find(function(widget)
    return widget.kind == "Button" and widget.text == "solitaire_finish" and widget:IsVisible()
  end) == 1
end

--- The card table of the game on screen
--- @return table felt, table frame
local function shownTable()
  local found = Client.Find(function(widget)
    return widget.cardTable ~= nil and widget:IsVisible()
  end)
  equal(1, #found, "card tables on screen")
  return found[1].cardTable, found[1]
end

--- Clicks a card of the table on screen, or the place of a pile that has none
--- @param pile string
local function clickPile(pile)
  local felt, frame = shownTable()
  passTime(frame, 2)
  local held = felt.piles[pile].held
  local region = #held > 0 and felt.sprites[held[#held]] or felt.piles[pile].place
  local spot = felt.piles[pile].spots[math.max(1, #held)]
  pressOnTable(frame, region, spot.x, spot.y)
  letGoOnTable(frame)
end

--- Drags a card of the table on screen, and whatever lies on it, onto another pile
--- @param card string
--- @param pile string
local function dragCard(card, pile)
  local felt, frame = shownTable()
  passTime(frame, 2)
  local sprite = felt.sprites[card]
  local spots = felt.piles[pile].spots
  pressOnTable(frame, sprite, sprite.x, sprite.y)
  pointAtTable(frame, spots[#spots].x, spots[#spots].y)
  frame:Fire("OnUpdate", 0.02)
  letGoOnTable(frame)
end

--- Makes a move of solitaire the way a player would: clicking the stock, dragging cards
--- @param state table
--- @param move string
local function playOnScreen(state, move)
  if move == "d" then
    clickPile("s")
  elseif move == "a" then
    Client.Button("solitaire_finish"):Fire("OnClick")
  else
    local from, to, count = move:sub(1, 1), move:sub(2, 2), tonumber(move:sub(3)) or 1
    local cards = from == "w" and state.waste or (state.homes[from] or state.columns[tonumber(from)].cards)
    dragCard(cards[#cards - count + 1], to == "f" and cards[#cards]:sub(2, 2) or to)
  end
end

function tests.WindowDealsSolitaireOut()
  local player, id = solitaireOnScreen()
  local state = player.private.Match.State(player.matches[id])
  local felt, frame = shownTable()

  equal(true, says("game_solitaire"), "nobody to play against, nobody named")
  equal(false, says("status_your_turn"))
  equal(true, says("solitaire_progress"))
  equal(true, says("solitaire_tally"))
  equal(false, Client.Button("undo").enabled, "nothing to take back yet")
  equal(false, finishOffered())

  -- Everything starts in the stock, and is dealt from there a card at a time
  equal(true, felt:Busy())
  local stockY = felt.piles.s.spots[1].y
  local function dealt()
    local count = 0
    for column = 1, 7 do
      for _, card in ipairs(state.columns[column].cards) do
        count = count + (felt.sprites[card].y > stockY + felt.cardHeight / 2 and 1 or 0)
      end
    end
    return count
  end
  equal(0, dealt())
  local partly = false
  for _ = 1, 200 do
    frame:Fire("OnUpdate", 0.02)
    local count = dealt()
    partly = partly or (count > 0 and count < 28)
  end
  equal(true, partly, "it takes a while")
  equal(28, dealt())
  equal(false, felt:Busy())
  equal("cardSlide", Client.sounds[#Client.sounds])

  -- Seven columns side by side with their top cards face up, and the stock face down
  for column = 1, 7 do
    local cards = state.columns[column].cards
    for index, card in ipairs(cards) do
      local sprite = felt.sprites[card]
      equal(felt.piles[tostring(column)].spots[index].x, sprite.x)
      assert(sprite.x + sprite.width / 2 <= frame.width and sprite.y + sprite.height / 2 <= frame.height, "on the table")
      assert(sprite.picture.texture:find((index == #cards and card or "back") .. "$"), card .. " lies the wrong way up")
    end
    if column > 1 then
      assert(felt.sprites[cards[1]].x >= felt.sprites[state.columns[column - 1].cards[1]].x + felt.cardWidth, "columns don't overlap")
    end
  end
  for _, card in ipairs(state.stock) do
    assert(felt.sprites[card].picture.texture:find("back$"))
  end

  -- Once is enough: looking at the game again doesn't deal it again
  ForeverGamesFrame:Hide()
  ForeverGamesFrame:Show()
  equal(false, select(1, shownTable()):Busy())
end

function tests.WindowPlaysSolitaire()
  local player, id, MainFrame = solitaireOnScreen()
  local Match, game = player.private.Match, player.private.Games.Get("solitaire")
  local match = player.matches[id]
  local felt, frame = shownTable()
  passTime(frame, 4)

  -- Clicking the stock turns a card
  local top = Match.State(match).stock[24]
  clickPile("s")
  equal("d", logOf(player, id))
  equal(true, felt:Busy())
  passTime(frame, 1)
  equal(felt.piles.w.spots[1].x, felt.sprites[top].x)
  assert(felt.sprites[top].picture.texture:find(top .. "$"), "turned over on the way")
  equal(true, Client.Button("undo").enabled)

  -- And Undo turns it back
  Client.Button("undo"):Fire("OnClick")
  equal("", logOf(player, id))
  passTime(frame, 1)
  equal(felt.piles.s.spots[24].x, felt.sprites[top].x)
  assert(felt.sprites[top].picture.texture:find("back$"))
  equal(false, Client.Button("undo").enabled)

  -- A card that has nowhere to go isn't moved by clicking it, and neither is one face down
  local state = Match.State(match)
  for column = 1, 7 do
    local cards = state.columns[column].cards
    local stuck = true
    for _, to in ipairs({ "f", "1", "2", "3", "4", "5", "6", "7" }) do
      stuck = stuck and not game.validate(state, 1, column .. to)
    end
    if stuck then
      clickPile(tostring(column))
    end
    if column > 1 then
      local sprite = felt.sprites[cards[1]]
      pressOnTable(frame, sprite, sprite.x, sprite.y)
      pointAtTable(frame, 5, 5)
      frame:Fire("OnUpdate", 0.02)
      letGoOnTable(frame)
    end
  end
  equal("", logOf(player, id))

  -- Play on, a deal after the other, until one comes out
  local deals, dragged = 0, 0
  while match.status ~= "finished" do
    deals = deals + 1
    assert(deals < 200, "some deal should come out")
    local idle = 0
    while match.status == "active" do
      state = Match.State(match)
      local move = solitaireMove(game, state, idle)
      if not move then
        break
      end
      idle = move == "d" and idle + 1 or 0
      local before = #match.log
      playOnScreen(state, move)
      equal(move, match.log[before + 1], "what was done on screen is the move that was made")
      dragged = dragged + (#move > 1 and 1 or 0)
      equal(match.status == "active" and game.validate(Match.State(match), 1, "a") == true, finishOffered())
    end
    if match.status == "active" then
      -- Stuck: another deal, in place of this one
      local old = match.id
      Client.Button("start_another"):Fire("OnClick")
      equal(nil, player.matches[old], "the game given up for it is gone")
      match = player.session:List()[1]
      equal("active", match.status)
      equal(0, #match.log)
      equal(true, MainFrame.IsViewing(match.id))
      equal(1, #player.session:List())
    end
  end
  assert(dragged > 20, "cards were dragged about")

  -- Won: the table puts on a show, and comes to rest with everything home
  felt, frame = shownTable()
  equal("a", match.log[#match.log])
  equal(1, Match.Result(match).winner)
  equal(true, says("status_won_with"))
  equal("UI_EPICLOOT_TOAST", Client.sounds[#Client.sounds])
  equal(true, felt:Busy())
  local thrown = false
  for _ = 1, 4000 do
    frame:Fire("OnUpdate", 0.02)
    thrown = thrown or felt.fountain ~= nil
    if not felt:Busy() then
      break
    end
  end
  equal(true, thrown)
  equal(false, felt:Busy())
  for _, suit in ipairs({ "S", "H", "D", "C" }) do
    equal(13, #felt.piles[suit].held)
    equal(felt.piles[suit].spots[1].x, felt.sprites["K" .. suit].x)
  end

  -- Nothing moves any more, and what is offered is another game
  local before = #match.log
  clickPile("S")
  dragCard("KH", "1")
  equal(before, #match.log)
  equal(false, finishOffered())
  equal(0, #Client.Find(function(widget)
    return widget.kind == "Button" and widget.text == "undo" and widget:IsVisible()
  end))
  Client.Button("play_again"):Fire("OnClick")
  equal(2, #player.session:List(), "the game that was won stays in the list")
  equal(false, MainFrame.IsViewing(match.id))
  Client.Button("give_up"):Fire("OnClick")
  equal(1, #player.session:List())
  -- With the game gone the player is back at the front page, where the other can be cleared away
  equal(false, MainFrame.IsViewing(match.id))
  Client.Button("remove"):Fire("OnClick")
  equal(0, #player.session:List())
end

function tests.WindowAsksBeforeGivingUpAGameThatIsUnderWay()
  local player, id = solitaireOnScreen()
  local asked = {}
  function StaticPopup_Show(which, text)
    asked[#asked + 1] = which .. " " .. text
  end
  clickPile("s")
  equal("d", logOf(player, id))
  Client.Button("give_up"):Fire("OnClick")
  Client.Button("start_another"):Fire("OnClick")
  equal("FOREVERGAMES_GIVE_UP give_up_confirm,FOREVERGAMES_GIVE_UP start_another_confirm", table.concat(asked, ","))
  assert(player.matches[id], "and nothing happens until the answer is yes")
  equal(1, #player.session:List())
end

function tests.WindowShowsTheGuildBoardBesideTheDaysChallenge()
  local world = World.New()
  local player = world:AddPlayer("Alice-Realm")
  local MainFrame = openWindow(player)
  local said = {}
  player.private.daily = player.private.Daily.New({
    me = "Alice-Realm",
    now = function()
      return world.clock
    end,
    today = function()
      return world.today
    end,
    broadcast = function(text)
      said[#said + 1] = text
    end,
    whisper = function() end,
    boards = { ["2026-10-14"] = { solitaire = { ["Bob-Realm"] = 455, ["Carol-Realm"] = 120 } } },
    onChange = function() end,
  })
  local match = assert(player.session:Daily("solitaire"))
  MainFrame.Open(match.id)

  local function shown(text)
    return #Client.Find(function(widget)
      return widget.text == text and widget:IsVisible()
    end)
  end
  equal(1, shown("daily_today"), "it says it is today's")
  equal(1, shown("daily_board"))
  equal(1, shown("Bob-Realm"))
  equal(1, shown("Carol-Realm"))
  equal(1, shown("daily_board_playing"))
  equal("1:DAYS:2026-10-14", said[1], "the guild is asked how they did")
  equal(1, shown("give_up"))
  equal(0, shown("start_another"), "there is no other go at it")
  equal(0, shown("undo"))

  -- Given up, it is over and goes up with everyone's
  local asked = {}
  function StaticPopup_Show(which, text, _, proceed)
    asked[#asked + 1] = which .. " " .. text
    proceed()
  end
  Client.Button("give_up"):Fire("OnClick")
  equal("FOREVERGAMES_GIVE_UP daily_give_up_confirm", table.concat(asked, ","))
  equal("finished", match.status)
  equal(0, match.score)
  player.private.daily:Post(match.daily, match.game, match.score)
  MainFrame.Refresh()
  equal(1, shown("Alice-Realm"))
  equal(1, shown("daily_board_count"))
  equal(1, shown("daily_new_game"), "a game of their own instead")
  equal("1:DAY:2026-10-14:solitaire:0", said[#said])
end

function tests.WindowShowsTheMovesMissedOneAfterAnother()
  local world = World.New()
  local players = { world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm"), world:AddPlayer("Carol-Realm") }
  local alice = players[1]
  local id = assert(alice.session:Invite({ "Bob-Realm", "Carol-Realm" }, "chinesecheckers")).id
  world:Deliver()
  for index = 2, 3 do
    assert(players[index].session:Accept(id))
    world:Deliver()
  end
  local Match, game = alice.private.Match, alice.private.Games.Get("chinesecheckers")
  --- Whoever's turn it is makes the first move there is, until it is Alice's
  local function untilAlice()
    local made = 0
    while true do
      local match = alice.matches[id]
      local seat = Match.Turn(match)
      local player
      for _, candidate in ipairs(players) do
        if candidate.name == match.players[seat] then
          player = candidate
        end
      end
      if player == alice then
        return made
      end
      local theirs = player.matches[id]
      assert(player.session:Move(id, game.moves(player.private.Match.State(theirs), seat)[1]))
      world:Deliver()
      made = made + 1
    end
  end
  untilAlice()
  -- What the board is asked to show: how far in, the move to show being made, and whether that
  -- is one of those Alice missed
  local shown = {}
  local createView = game.createView
  game.createView = function(stage)
    local view = createView(stage)
    local update = view.Update
    view.Update = function(self, asked)
      if asked.changed then
        shown[#shown + 1] = asked.ply .. (asked.played and "+" or "") .. (asked.catching and "c" or "") .. (asked.live and "l" or "")
      end
      return update(self, asked)
    end
    return view
  end
  local MainFrame = openWindow(alice)
  MainFrame.Open(id)
  local match = alice.matches[id]
  local detail = ForeverGamesFrame.detail
  equal(#match.log, match.shown, "the game as it stands is what Alice saw")
  assert(alice.session:Move(id, game.moves(Match.State(match), match.me)[1]))
  world:Deliver()

  -- Alice looks away, and the others move
  MainFrame.Home()
  equal(2, untilAlice())
  local seen = match.shown
  shown = {}
  equal(seen + 2, #match.log)
  MainFrame.Open(id)
  equal("missed_note", detail.note:GetText())
  equal(true, detail.skip:IsShown())
  equal(seen, match.shown, "nothing new seen yet: the position she left it at")

  -- A move at a time, each on screen a while
  detail:Fire("OnUpdate", 0.3)
  equal(seen, match.shown, "the first of them waits its turn")
  detail:Fire("OnUpdate", 0.7)
  equal(seen + 1, match.shown, "Bob's move")
  equal("missed_note", detail.note:GetText())
  detail:Fire("OnUpdate", 1)
  equal(seen + 2, match.shown, "and Carol's, in the game as it stands")
  assert(detail.note:GetText() ~= "missed_note", "that was all of them")
  equal(false, detail.skip:IsShown())
  -- From where she left it, which the board still shows
  equal(string.format("%d+c,%d+l", seen + 1, seen + 2), table.concat(shown, ","), "each made in front of her")

  -- Away again, and Space goes straight to the game as it stands
  assert(alice.session:Move(id, game.moves(Match.State(match), match.me)[1]))
  world:Deliver()
  MainFrame.Home()
  untilAlice()
  MainFrame.Open(id)
  equal("missed_note", detail.note:GetText())
  Client.over = true
  local keys = detail.keys
  equal(true, keys:IsShown())
  keys:Fire("OnKeyDown", "SPACE")
  Client.over = nil
  equal(#match.log, match.shown)
  equal(false, detail.skip:IsShown())
  equal(false, keys.propagates, "the key was the window's")
  equal(false, keys:IsShown(), "and from now on the game's own")

  -- A single move missed is only shown being made, as ever
  assert(alice.session:Move(id, game.moves(Match.State(match), match.me)[1]))
  world:Deliver()
  MainFrame.Home()
  local bob = players[2].matches[id]
  if Match.Turn(bob) == bob.me then
    assert(players[2].session:Move(id, game.moves(players[2].private.Match.State(bob), bob.me)[1]))
    world:Deliver()
  end
  MainFrame.Open(id)
  assert(detail.note:GetText() ~= "missed_note")
end

function tests.WindowFitsSolitaireIntoTheRoomItHas()
  local player, id = solitaireOnScreen()
  local state = player.private.Match.State(player.matches[id])
  local felt, frame = shownTable()
  passTime(frame, 4)
  local normal = felt.cardWidth

  local function fits()
    for card, sprite in pairs(felt.sprites) do
      local inside = sprite.x - felt.cardWidth / 2 >= 0 and sprite.x + felt.cardWidth / 2 <= frame.width
      assert(inside and sprite.y - felt.cardHeight / 2 >= 0 and sprite.y + felt.cardHeight / 2 <= frame.height, card .. " is off the table")
    end
    equal(52, #state.stock + 28)
  end
  fits()

  ForeverGamesFrame:SetSize(1400, 1000)
  assert(felt.cardWidth > normal, "a bigger window should mean bigger cards")
  equal(false, felt:Busy(), "which are simply there, not on their way")
  fits()
  ForeverGamesFrame:SetSize(764, 560)
  assert(felt.cardWidth >= 40, "the cards should stay usable in the smallest window, got " .. felt.cardWidth)
  fits()
end

function tests.WindowListsAGameForOneByItsName()
  local player, id, MainFrame = solitaireOnScreen()
  local match = player.matches[id]
  equal("solitaire_progress", MainFrame.Describe(match))
  -- The games are listed on the front page
  MainFrame.Home()
  local rows = Client.Find(function(widget)
    return widget.kind == "Button" and widget.matchId == id and widget:IsVisible()
  end)
  equal(1, #rows)
  equal("game_solitaire", rows[1].name.text)
  equal("solitaire_progress", rows[1].status.text)
  equal(false, rows[1].marker:IsShown(), "it isn't waiting on the player the way an opponent would be")

  assert(player.session:Resign(id))
  equal("status_gave_up", MainFrame.Describe(match))
end

function tests.WizardStartsAGameForOneAtOnce()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local Wizard = openWizard(alice)
  local cards = Client.Find(function(widget)
    return widget.kind == "Button" and widget.game ~= nil and widget.game.id == "solitaire" and widget:IsVisible()
  end)
  equal(1, #cards)
  equal("players_solo", cards[1].players.text)
  equal("genre_cards", cards[1].genre.text)

  cards[1]:Fire("OnClick")
  equal(false, Wizard.IsOpen(), "nobody to pick")
  local started
  for _, match in pairs(alice.matches) do
    started = match
  end
  equal("solitaire", started.game)
  equal("active", started.status)
  equal(0, #world.queue)
end

-----------------------------
-- Game options
-----------------------------

function tests.OptionsAreWrittenDownOnlyWhereTheyDiffer()
  local Games = loadEngine().Games
  local words = Games.Get("words")
  equal(nil, Games.EncodeOptions(words, nil))
  equal(nil, Games.EncodeOptions(words, { lore = 5, bingo = 50 }), "the usual rules are nothing to send")
  equal("lore=10+bingo=100", Games.EncodeOptions(words, { bingo = 100, lore = 10, legend = 15 }))
  equal("azeroth=0", Games.EncodeOptions(words, { azeroth = false }))
  equal(nil, Games.EncodeOptions(words, { lore = 7, nonsense = 1 }), "what an option can't be is left the way it was")

  local chosen, understood = Games.DecodeOptions(words, "lore=10+bingo=100")
  equal(true, understood)
  equal(10, chosen.lore)
  equal(100, chosen.bingo)
  equal(nil, chosen.legend)
  equal(false, Games.DecodeOptions(words, "azeroth=0").azeroth)
  equal(true, select(2, Games.DecodeOptions(words, nil)))
  equal(nil, (Games.DecodeOptions(words, "lore=5")), "the default, spelled out, is still the usual rules")
  for _, bad in ipairs({ "lore=7", "nonsense=1", "lore", "lore=10+lore=20", "azeroth=yes" }) do
    equal(false, select(2, Games.DecodeOptions(words, bad)), bad)
  end
  equal(false, select(2, Games.DecodeOptions(Games.Get("chess"), "lore=10")), "a game without options has none to set")

  local rules = Games.Rules(words.options, { lore = 20, blanks = 3 })
  equal(20, rules.lore)
  equal(2, rules.blanks)
  equal(true, rules.azeroth)
  equal(1, #Games.DescribeOptions(words, { lore = 20 }))
  equal(1, #Games.DescribeOptions(words, { azeroth = false, lore = 20 }), "a bonus for words that aren't in the game isn't worth a line")
  equal(0, #Games.DescribeOptions(words, nil))
end

function tests.CodecCarriesTheRules()
  local Codec = loadEngine().Codec
  local invite = Codec.Decode("1:INV:abc:words:1:2:lore=10+bingo=100")
  equal("lore=10+bingo=100", invite.options)
  equal(2, invite.seat)
  equal(nil, invite.seats)

  invite = Codec.Decode(Codec.Encode("INV", "abc", "words", 1, 2, "azeroth=0", 3, 1, 3, "Carol-Realm"))
  equal("azeroth=0", invite.options)
  equal(3, invite.seats)
  equal(1, invite.mine)
  equal("Carol-Realm", invite.names[3])

  equal(nil, Codec.Decode("1:INV:abc:words:1:2").options)
end

function tests.ChallengeComesWithItsRules()
  local world = World.New()
  local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  local match = assert(alice.session:Invite("Bob-Realm", "words", { options = { lore = 20, bingo = 50, blanks = 4 }, seat = 2 }))
  equal(2, match.me, "the seat that was asked for")
  equal(20, match.options.lore)
  equal(nil, match.options.bingo, "only what differs is kept")
  world:Deliver()
  equal("Alice-Realm>Bob-Realm 1:INV:" .. match.id .. ":words:1:2:lore=20+blanks=4", world.sent[1])

  local theirs = bob.matches[match.id]
  equal("incoming", theirs.status)
  equal(20, theirs.options.lore)
  equal(4, theirs.options.blanks)
  assert(bob.session:Accept(match.id))
  world:Deliver()
  for _, player in ipairs({ alice, bob }) do
    local state = player.private.Match.State(player.matches[match.id])
    equal(20, state.rules.lore)
    equal(15, state.rules.legend)
    equal(4, state.rules.blanks)
    equal(106 - 14, #state.bag, "two more blanks in the bag")
  end

  -- The usual rules travel the way a challenge always did, for clients from before there were any
  local plain = assert(alice.session:Invite("Bob-Realm", "words", { seat = 1 }))
  world:Deliver()
  equal("Alice-Realm>Bob-Realm 1:INV:" .. plain.id .. ":words:1:1", world.sent[#world.sent])
  equal(nil, bob.matches[plain.id].options)
  equal(1, plain.me)

  -- For more than two as well
  world:AddPlayer("Carol-Realm")
  local crowd = assert(alice.session:Invite({ "Bob-Realm", "Carol-Realm" }, "words", { options = { azeroth = false } }))
  world:Deliver()
  equal(false, bob.matches[crowd.id].options.azeroth)
  equal(false, world.players["Carol-Realm"].matches[crowd.id].options.azeroth)
end

function tests.RulesThisClientDoesNotKnowAreDeclined()
  local world = World.New()
  local bob = world:AddPlayer("Bob-Realm")
  bob.session:Receive("Alice-Realm", "1:INV:abc:words:1:1:lore=10+wild=1")
  equal(nil, bob.matches.abc)
  equal("Bob-Realm>Alice-Realm 1:DEC:abc:version", world.queue[1].from .. ">" .. world.queue[1].to .. " " .. world.queue[1].text)
  world.queue = {}
  bob.session:Receive("Alice-Realm", "1:INV:abd:chess:1:1:lore=10")
  equal(nil, bob.matches.abd)
end

function tests.SessionKnowsWhoWasPlayedLast()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  world:AddPlayer("Bob-Realm")
  world:AddPlayer("Carol-Realm")
  assert(alice.session:Invite("Bob-Realm", "tictactoe"))
  world.clock = world.clock + 3 * 24 * 60 * 60
  assert(alice.session:Invite("Carol-Realm", "tictactoe"))
  assert(alice.session:Invite({}, "solitaire"))
  world.clock = world.clock + 60
  local opponents = alice.session:Opponents()
  equal(2, #opponents)
  equal("Carol-Realm", opponents[1].name)
  equal(60, opponents[1].ago)
  equal("Bob-Realm", opponents[2].name)
  equal(3 * 24 * 60 * 60 + 60, opponents[2].ago)
end

function tests.WordsBonusesAreWhatTheGameWasSetUpWith()
  local private = loadEngine()
  local game = private.Games.Get("words")
  --- @param chosen table?
  --- @param rack string
  --- @param move string
  --- @return table? event, string? err
  local function played(chosen, rack, move)
    local state = game.newState(2, private.Random.New(1), private.Games.Rules(game.options, chosen))
    state.bag, state.board = tilesOf("TTT"), {}
    state.racks[1] = tilesOf(rack)
    local ok, err = game.validate(state, 1, move)
    if not ok then
      return nil, err
    end
    return game.apply(state, 1, move, private.Random.New(3))
  end

  -- F4 A1 doubled R1 M3 E1 doubled R1 S1, the word doubled: 28 before the bonus
  equal(78, played(nil, "FARMERS", "aB8.FARMERS").score)
  equal(128, played({ bingo = 100 }, "FARMERS", "aB8.FARMERS").score)
  local plain = played({ bingo = 0 }, "FARMERS", "aB8.FARMERS")
  equal(28, plain.score)
  equal(false, plain.allTiles, "nothing to make a fuss about")

  -- A name everybody knows, and one that is only known
  local usual = played(nil, "THRALLX", "aD8.THRALL")
  local legend = played({ legend = 50 }, "THRALLX", "aD8.THRALL")
  equal(35, legend.score - usual.score)
  equal(usual.score - 15, played({ legend = 0 }, "THRALLX", "aD8.THRALL").score)
  equal(usual.score, played({ lore = 20 }, "THRALLX", "aD8.THRALL").score, "a legend gets its own bonus, not the other")
  local known = played(nil, "BAINEXY", "aD8.BAINE")
  equal(15, played({ lore = 20 }, "BAINEXY", "aD8.BAINE").score - known.score)
  equal(1, known.words[1].lore.rank, "Baine is from Azeroth, and no legend")

  -- Without Azeroth its names aren't words at all
  equal("words_not_a_word", select(2, played({ azeroth = false }, "JAINAXY", "aD8.JAINA")))
  equal(true, played(nil, "JAINAXY", "aD8.JAINA") ~= nil)
  equal(nil, played({ azeroth = false }, "FARMERS", "aB8.FARMERS").words[1].lore)

  for _, blanks in ipairs({ 0, 2, 4 }) do
    local state = game.newState(2, private.Random.New(5), private.Games.Rules(game.options, { blanks = blanks }))
    local all = { unpack(state.bag) }
    for seat = 1, 2 do
      for _, tile in ipairs(state.racks[seat]) do
        all[#all + 1] = tile
      end
    end
    equal(102 + blanks, #all)
    equal(blanks, select(2, table.concat(all):gsub("_", "")))
  end
end

function tests.CheckersTakingCanBeLeftToThePlayer()
  local private = loadEngine()
  local game = private.Games.Get("checkers")
  local state, random = game.newState(2, private.Random.New(1), { forced = false }), private.Random.New(1)
  for move in ("11-15 22-18"):gmatch("%S+") do
    game.apply(state, game.turn(state), move, random)
  end
  equal(true, (game.validate(state, 1, "15-22")), "the jump is still on")
  equal(true, (game.validate(state, 1, "9-13")), "and so is anything else")
  equal(true, #checkersMoves(state) > 1)

  state = game.newState(2, private.Random.New(1), { forced = true })
  for move in ("11-15 22-18"):gmatch("%S+") do
    game.apply(state, game.turn(state), move, random)
  end
  equal("15-22", table.concat(checkersMoves(state), ","))
end

function tests.BattleshipHitCanFireAgain()
  local private = loadEngine()
  local game = private.Games.Get("battleship")
  for _, again in ipairs({ true, false }) do
    local state = game.newState(2, private.Random.New(1), { again = again })
    game.apply(state, 1, FLEET_ROWS)
    game.apply(state, 2, FLEET_COLUMNS)
    equal(true, game.apply(state, 1, "f1").hit)
    equal(again and 1 or 2, game.turn(state))
    if again then
      equal(false, game.apply(state, 1, "a10").hit)
      equal(2, game.turn(state), "a miss hands the turn over as ever")
    end
  end
end

function tests.CrazyEightsDealsAsManyCardsAsAsked()
  local private = loadEngine()
  local game = private.Games.Get("crazyeights")
  equal(7, #game.newState(2, private.Random.New(1)).hands[1])
  equal(7, #game.newState(2, private.Random.New(1), { dealt = 0 }).hands[2])
  equal(5, #game.newState(4, private.Random.New(1), { dealt = 0 }).hands[4])
  equal(5, #game.newState(2, private.Random.New(1), { dealt = 5 }).hands[1])
  local state = game.newState(6, private.Random.New(1), { dealt = 8 })
  equal(8, #state.hands[6])
  equal(52 - 48 - 1, #state.deck)
end

--- The buttons of a line of the rules in the wizard, by what they say
--- @param name string What the line is about
--- @return table<string, table> buttons, string on The one that is chosen
local function ruleChoices(name)
  local row = Client.Find(function(widget)
    return widget.choices ~= nil and widget.name ~= nil and widget.name.text == name and widget:IsVisible()
  end)[1]
  assert(row, "no line of the rules about " .. name)
  local buttons, on = {}, nil
  for _, choice in ipairs(row.choices) do
    if choice:IsVisible() then
      buttons[choice.label.text] = choice
      on = choice.picked and choice.label.text or on
    end
  end
  return buttons, on
end

--- @param id string
local function pickGame(id)
  Client.Find(function(widget)
    return widget.kind == "Button" and widget.game ~= nil and widget.game.id == id and widget:IsVisible()
  end)[1]:Fire("OnClick")
end

function tests.WizardSetsTheRulesOfAGame()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local bob = world:AddPlayer("Bob-Realm")
  local wizard = openWizard(alice)
  pickGame("words")
  equal(true, says("words_option_lore"))
  local _, on = ruleChoices("words_option_lore")
  equal("+5", on)
  local buttons = ruleChoices("words_option_lore")
  buttons["+20"]:Fire("OnClick")
  equal("+20", select(2, ruleChoices("words_option_lore")))
  ruleChoices("words_option_bingo")["option_off"]:Fire("OnClick")
  ruleChoices("wizard_turn")["wizard_turn_2"]:Fire("OnClick")

  -- Without the words from Azeroth there is nothing to say about what they are worth
  ruleChoices("words_option_azeroth")["option_off"]:Fire("OnClick")
  equal(false, says("words_option_lore"))
  equal(false, says("words_option_legend"))
  equal(true, says("words_option_blanks"))
  ruleChoices("words_option_azeroth")["option_on"]:Fire("OnClick")
  equal("+20", select(2, ruleChoices("words_option_lore")), "set the way it was")

  local name = Client.Find(function(widget)
    return widget.kind == "EditBox" and widget.scripts.OnTextChanged and widget:IsVisible()
  end)[1]
  name:SetText("Bob-Realm")
  Client.Button("wizard_send"):Fire("OnClick")
  world:Deliver()
  local started
  for _, match in pairs(alice.matches) do
    started = match
  end
  equal(2, started.me)
  equal(20, started.options.lore)
  equal(0, started.options.bingo)
  equal(nil, started.options.azeroth)
  equal(20, bob.matches[started.id].options.lore)

  -- The next one starts out the same way, and can be put back
  wizard.Open()
  pickGame("words")
  equal("+20", select(2, ruleChoices("words_option_lore")))
  equal("wizard_seat_random", select(2, ruleChoices("wizard_turn")), "the seat is asked for anew every time")
  Client.Button("wizard_reset"):Fire("OnClick")
  equal("+5", select(2, ruleChoices("words_option_lore")))
  equal("+50", select(2, ruleChoices("words_option_bingo")))
  equal(0, #Client.Find(function(widget)
    return widget.kind == "Button" and widget.text == "wizard_reset" and widget:IsVisible()
  end), "nothing left to put back")

  -- A game that names its seats offers them by name, one without options says so
  wizard.Open()
  pickGame("chess")
  local sides = ruleChoices("wizard_seat")
  assert(sides["chess_white"] and sides["chess_black"] and sides["wizard_seat_random"])
  equal(false, says("wizard_no_options"), "which side to take is something to set")
  sides["chess_black"]:Fire("OnClick")
  name:SetText("Bob-Realm")
  Client.Button("wizard_send"):Fire("OnClick")
  for _, match in pairs(alice.matches) do
    if match.game == "chess" then
      equal(2, match.me)
    end
  end

  -- With more than two the seats are drawn
  wizard.Open()
  pickGame("chinesecheckers")
  equal(true, says("wizard_seat"), "two can play it")
  for _, player in ipairs({ "Bob-Realm", "Carol-Realm" }) do
    name:SetText(player)
    name:Fire("OnEnterPressed")
  end
  equal(false, says("wizard_seat"))
  equal(true, says("wizard_no_options"))
end

function tests.WizardOffersWhoWasPlayedLastFirst()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  for _, name in ipairs({ "Bob-Realm", "Carol-Realm", "Dave-Realm", "Erin-Realm", "Frank-Realm" }) do
    world:AddPlayer(name)
  end
  -- Dave is someone Alice played a while ago and who isn't around, Carol a guildie she played today
  assert(alice.session:Invite("Dave-Realm", "tictactoe"))
  world.clock = world.clock + 5 * 24 * 60 * 60
  assert(alice.session:Invite("Carol-Realm", "tictactoe"))
  openWizard(alice)
  function alice.private.presence:List()
    return {
      { name = "Bob-Realm", source = "guild" },
      { name = "Carol-Realm", source = "guild" },
      { name = "Erin-Realm", source = "friend" },
    }
  end
  pickGame("chess")

  --- @return string What the list says from the top, headers in brackets
  local function shown()
    local lines = {}
    for _, row in ipairs(Client.Find(function(widget)
      return widget.kind == "Button" and widget.header ~= nil and widget.source ~= nil and widget:IsVisible()
    end)) do
      lines[#lines + 1] = row.player or (row.computer and "computer") or ("[" .. row.header.text .. "]")
    end
    return table.concat(lines, " ")
  end
  local function row(player)
    return Client.Find(function(widget)
      return widget.kind == "Button" and widget.player == player and widget.source ~= nil and widget:IsVisible()
    end)[1]
  end
  local name = Client.Find(function(widget)
    return widget.kind == "EditBox" and widget.scripts.OnTextChanged and widget:IsVisible()
  end)[1]
  local function type(text)
    name:SetText(text)
    name:Fire("OnTextChanged", true)
  end
  local send = Client.Button("wizard_send")

  equal("[wizard_recent] Carol-Realm Dave-Realm [wizard_guild] Bob-Realm [wizard_friends] Erin-Realm", shown())
  equal("source_guild  -  wizard_played_today", row("Carol-Realm").source.text)
  equal("wizard_played_days", row("Dave-Realm").source.text)
  equal(false, send.enabled)

  -- Narrowed down by what they are
  clickGenre("wizard_guild")
  equal("[wizard_recent] Carol-Realm [wizard_guild] Bob-Realm", shown())
  clickGenre("wizard_friends")
  equal("[wizard_friends] Erin-Realm", shown())
  clickGenre("wizard_recent")
  equal("[wizard_recent] Carol-Realm Dave-Realm", shown())
  clickGenre("wizard_all_games")

  -- And by name. Down to one, that is who the challenge would go to
  type("er")
  equal("[wizard_friends] Erin-Realm", shown())
  equal(true, row("Erin-Realm").selected:IsShown())
  equal(true, send.enabled)

  -- Someone who isn't on the list can be had by name
  type("Frank-Realm")
  equal("[wizard_by_name] Frank-Realm", shown())
  equal(true, send.enabled)
  -- Enter picks, it is the button that sends
  name:Fire("OnEnterPressed")
  equal("", name:GetText())
  equal(2, (function()
    local count = 0
    for _ in pairs(alice.matches) do
      count = count + 1
    end
    return count
  end)(), "nothing was sent")
  equal("[wizard_chosen_also] Frank-Realm [wizard_recent] Carol-Realm Dave-Realm [wizard_guild] Bob-Realm [wizard_friends] Erin-Realm", shown())

  -- A click on someone else and it is them instead
  row("Bob-Realm"):Fire("OnClick")
  equal(true, row("Bob-Realm").selected:IsShown())
  equal(nil, row("Frank-Realm"))
  send:Fire("OnClick")
  local challenged = {}
  for _, match in pairs(alice.matches) do
    if match.game == "chess" then
      challenged[#challenged + 1] = match.players[match.me == 1 and 2 or 1]
    end
  end
  equal("Bob-Realm", table.concat(challenged, ","))
end

function tests.WindowSaysWhatRulesAChallengeComesWith()
  local world = World.New()
  local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  local match = assert(alice.session:Invite("Bob-Realm", "words", { options = { bingo = 100 } }))
  world:Deliver()
  local MainFrame = openWindow(bob)
  MainFrame.Open(match.id)
  local message = Client.Find(function(widget)
    return widget.text ~= nil and widget.text:find("rules_custom", 1, true) and widget.text:find("status_incoming", 1, true) and widget:IsVisible()
  end)
  equal(1, #message, "the challenge says it comes with rules of its own")

  -- And a rematch is played by them again
  Client.Button("accept"):Fire("OnClick")
  world:Deliver()
  assert(bob.session:Resign(match.id))
  world:Deliver()
  Client.Button("rematch"):Fire("OnClick")
  local again
  for id, other in pairs(bob.matches) do
    again = id ~= match.id and other or again
  end
  equal(100, again.options.bingo)
end

-----------------------------
-- Minesweeper
-----------------------------

--- A game of minesweeper to try the rules on
--- @param level string?
--- @return table game, table state, table private
local function minesweeper(level)
  local private = loadEngine()
  local game = private.Games.Get("minesweeper")
  return game, game.newState(1, private.Random.New(1), private.Games.Rules(game.options, { level = level })), private
end

--- A field with its mines where a test wants them, as if the first square had been opened
--- @param level string?
--- @param mines number[] The squares they are under
--- @return table game, table state, table private
local function minefield(level, mines)
  local game, state, private = minesweeper(level)
  state.laid, state.mines = true, #mines
  for _, square in ipairs(mines) do
    state.mine[square] = true
  end
  return game, state, private
end

--- Makes a move that has to be legal
--- @return table event
local function sweep(game, state, move, random)
  local ok, err = game.validate(state, 1, move)
  assert(ok, move .. " should be legal: " .. tostring(err))
  return game.apply(state, 1, move, random)
end

--- Checks that a position adds up: what it counts is what is there, nothing is both open and
--- flagged, every number is right and no mine is open in a game that isn't lost
--- @param state table
local function minesweeperIsSound(state)
  local columns, total = state.columns, state.columns * state.rows
  local mines, opened, flags = 0, 0, 0
  for square = 0, total - 1 do
    mines = mines + (state.mine[square] and 1 or 0)
    flags = flags + (state.flag[square] and 1 or 0)
    if state.open[square] then
      opened = opened + 1
      assert(not state.flag[square], "square " .. square .. " is open and flagged")
      assert(not state.mine[square], "a mine is open at " .. square)
      local around = 0
      for down = -1, 1 do
        for across = -1, 1 do
          local column, row = square % columns + across, math.floor(square / columns) + down
          local onField = column >= 0 and column < columns and row >= 0 and row < state.rows
          around = around + ((onField and state.mine[row * columns + column]) and 1 or 0)
        end
      end
      equal(around, state.open[square], "the number at " .. square)
    end
  end
  equal(state.laid and state.mines or 0, mines, "mines in the field")
  equal(opened, state.opened, "squares counted as open")
  equal(flags, state.flags, "flags counted")
  for key in pairs(state.mine) do
    assert(key >= 0 and key < total, "a mine off the field")
  end
end

function tests.MinesweeperComesInThreeSizes()
  local game, state, private = minesweeper()
  equal(true, private.Games.IsSolo(game))
  equal("solo", game.genre)
  equal("move", game.clock)
  equal(nil, game.undo, "a mine that went off can't be taken back")
  equal("beginner", state.level)
  equal("9x9 10", state.columns .. "x" .. state.rows .. " " .. state.mines)
  equal(false, state.laid)
  equal(nil, next(state.mine), "no mines until the first square is opened")
  equal(nil, game.result(state))
  equal("minesweeper_progress", game.progress(state))
  minesweeperIsSound(state)

  local _, intermediate = minesweeper("intermediate")
  equal("16x16 40", intermediate.columns .. "x" .. intermediate.rows .. " " .. intermediate.mines)
  local _, expert = minesweeper("expert")
  equal("30x16 99", expert.columns .. "x" .. expert.rows .. " " .. expert.mines)
  local _, usual = minesweeper("impossible")
  equal("beginner", usual.level, "what it can't be set to is the usual")
  equal("beginner", game.newState(1, private.Random.New(1)).level, "and so is nothing at all")

  -- How hard it is travels the way any option does
  equal(nil, private.Games.EncodeOptions(game, { level = "beginner" }))
  equal("level=expert", private.Games.EncodeOptions(game, { level = "expert" }))
  equal("expert", private.Games.DecodeOptions(game, "level=expert").level)
  equal("minesweeper_level_expert", private.Games.OptionLabel(game.options[1], "expert"))
  equal("option_line", private.Games.DescribeOptions(game, { level = "expert" })[1])
end

function tests.MinesweeperLaysItsMinesAroundTheFirstSquare()
  for _, level in ipairs({ "beginner", "intermediate", "expert" }) do
    for seed = 1, 12 do
      local game, state, private = minesweeper(level)
      local total = state.columns * state.rows
      -- In a corner, on an edge and in the middle
      local first = ({ 0, state.columns - 1, total - 1, math.floor(total / 2) + 3, state.columns * 2 })[seed % 5 + 1]
      local event = sweep(game, state, "r" .. first, private.Random.New(seed))
      equal(true, event.laid)
      equal(true, state.laid)
      minesweeperIsSound(state)
      equal(0, state.open[first], "nothing touches the square the game began with")
      assert(#event.opened >= 4, "it opens a patch, not a square")
      equal(first, event.opened[1])
      equal(0, event.depths[1])
      equal(#event.opened, state.opened)
      equal(#event.opened, #event.depths)
      for index = 2, #event.depths do
        assert(event.depths[index] >= event.depths[index - 1], "the opening spreads outward")
      end
    end
  end
end

function tests.MinesweeperIsTheSameGameFromTheSameSeed()
  local function field(seed, first)
    local game, state, private = minesweeper("intermediate")
    sweep(game, state, "r" .. first, private.Random.New(seed))
    local mines = {}
    for square = 0, state.columns * state.rows - 1 do
      mines[#mines + 1] = state.mine[square] and "*" or "."
    end
    return table.concat(mines)
  end
  equal(field(7, 100), field(7, 100))
  assert(field(7, 100) ~= field(8, 100), "another seed, another field")
  assert(field(7, 100) ~= field(7, 30), "and another first square as well")

  -- Through the engine, where a match is replayed from its log every time it is looked at
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local match = assert(alice.session:Invite({}, "minesweeper", { options = { level = "expert" } }))
  assert(alice.session:Move(match.id, "f3"))
  assert(alice.session:Move(match.id, "r200"))
  local Match = alice.private.Match
  local state = Match.State(match)
  equal("expert", state.level)
  equal(true, state.flag[3])
  local copied = copy(match)
  local again = Match.State(copied)
  assert(again ~= state)
  for square = 0, 479 do
    equal(state.mine[square], again.mine[square], "the mine at " .. square)
    equal(state.open[square], again.open[square], "what is open at " .. square)
  end
  local events = Match.Events(match)
  equal("f", events[1].action)
  equal(true, events[2].laid)
  equal("minesweeper_progress", alice.private.Games.Get("minesweeper").progress(state))
end

function tests.MinesweeperOpensSquaresAndFloodsFromTheEmptyOnes()
  -- Mines in the top right corner and in the middle of the left edge of a nine by nine field
  local game, state = minefield("beginner", { 80, 36 })
  local event = sweep(game, state, "r79")
  equal("r", event.action)
  equal(79, event.square)
  equal("79", table.concat(event.opened, ","), "a number opens only itself")
  equal(1, state.open[79])
  equal(1, state.opened)
  equal(nil, game.result(state))

  -- An empty square opens everything up to the numbers around the mines
  event = sweep(game, state, "r0")
  equal(0, event.opened[1])
  equal(0, event.depths[1])
  equal(81 - 2, state.opened, "all of it but the mines")
  equal(8, event.depths[#event.depths], "the far corner is eight steps away")
  equal(true, event.won)
  equal(1, game.result(state).winner)
  minesweeperIsSound(state)
  -- Nothing is left to do but flag what is left, which is done for the player
  equal("36,80", (function()
    local swept = { unpack(event.swept) }
    table.sort(swept)
    return table.concat(swept, ",")
  end)())
  equal(36, event.swept[1], "nearest where the move was made first")
  equal(true, state.flag[80])
  equal(2, state.flags)
  equal(false, (game.validate(state, 1, "r80")), "over is over")
  equal(false, (game.validate(state, 1, "f80")))
end

function tests.MinesweeperFloodLeavesFlagsStanding()
  local game, state = minefield("beginner", { 80 })
  local planted = sweep(game, state, "f40")
  equal("f", planted.action)
  equal(true, planted.planted)
  equal(1, state.flags)
  equal(1, state.moves)
  local event = sweep(game, state, "r0")
  equal(nil, state.open[40], "a flag keeps its square shut")
  equal(81 - 2, state.opened)
  equal(nil, event.won, "which leaves one still to open")
  equal(nil, game.result(state))

  local taken = sweep(game, state, "f40")
  equal(false, taken.planted)
  equal(0, state.flags)
  equal(nil, state.flag[40])
  event = sweep(game, state, "r40")
  equal(true, event.won)
  equal("80", table.concat(event.swept, ","))
  minesweeperIsSound(state)
end

function tests.MinesweeperRejectsWhatCantBeDone()
  local game, state = minefield("beginner", { 80, 36 })
  sweep(game, state, "r79")
  sweep(game, state, "f80")
  local wrong = { "r79", "f79", "r80", "c80", "c0", "r81", "r-1", "r", "x3", "r03", "r3 ", "f1.0", "c79x", "", "r" .. string.rep("9", 20) }
  for _, move in ipairs(wrong) do
    local ok, err = game.validate(state, 1, move)
    equal(false, ok, "'" .. move .. "' should be rejected")
    equal("invalid_move", err)
  end
  equal("not_your_turn", select(2, game.validate(state, 2, "r0")))
  -- A chord takes exactly as many flags as the number says, and something to open
  sweep(game, state, "f70")
  equal(false, (game.validate(state, 1, "c79")), "two flags on a one")
  sweep(game, state, "f70")
  equal(true, (game.validate(state, 1, "c79")))
  sweep(game, state, "f80")
  equal(false, (game.validate(state, 1, "c79")), "none")
  equal(true, (game.validate(state, 1, "r0")))
  equal(true, (game.validate(state, 1, "f0")))
end

function tests.MinesweeperChordsOpenTheRestAroundANumber()
  -- One mine in the corner at the bottom left. Its neighbours are opened one at a time
  local game, state = minefield("beginner", { 0, 80 })
  sweep(game, state, "r10")
  equal(1, state.open[10])
  equal(false, (game.validate(state, 1, "c10")), "not without its flag")
  sweep(game, state, "f0")
  local event = sweep(game, state, "c10")
  equal("c", event.action)
  equal(10, event.square)
  equal(1, event.depths[1], "a chord begins a step from its number")
  equal(79 - 1, #event.opened, "the rest of the field, flooded from around it")
  equal(true, event.won)
  equal(nil, event.exploded)
  equal(79, state.opened)
  equal(true, state.flag[80])
  minesweeperIsSound(state)

  -- A flag on the wrong square, and the chord opens the mine
  game, state = minefield("beginner", { 0, 80 })
  sweep(game, state, "r10")
  sweep(game, state, "f1")
  event = sweep(game, state, "c10")
  equal(0, event.exploded)
  equal(0, state.hit)
  equal(0, game.result(state).winner)
  equal("80", table.concat(event.mines, ","))
  equal("8", table.concat(event.reach, ","))
  equal("1", table.concat(event.wrong, ","))
  assert(#event.opened > 0, "what had no mine was opened all the same")
  equal(nil, state.open[1], "though not what was flagged")
end

function tests.MinesweeperIsLostByOpeningAMine()
  local game, state, private = minefield("beginner", { 40, 41, 0, 80, 8 })
  sweep(game, state, "r31")
  sweep(game, state, "f41")
  sweep(game, state, "f72")
  local event = sweep(game, state, "r40")
  equal(40, event.exploded)
  equal(0, #event.opened)
  equal(40, state.hit)
  equal(0, game.result(state).winner)
  equal("0,8,80", table.concat(event.mines, ","), "every other mine nobody flagged, nearest first")
  equal("4,4,4", table.concat(event.reach, ","))
  equal("72", table.concat(event.wrong, ","))
  equal(false, (game.validate(state, 1, "r1")), "over is over")
  equal(false, (game.validate(state, 1, "f1")))
  equal(nil, game.record(state, 12, game.result(state)), "nothing to remember of a game that was lost")
  equal(3, state.mines - state.flags)

  -- Lost through the engine: the window says it is over, not that the player gave up
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local match = assert(alice.session:Invite({}, "minesweeper"))
  assert(alice.session:Move(match.id, "r40"))
  local field = alice.private.Match.State(match)
  local mine = next(field.mine)
  assert(alice.session:Move(match.id, "r" .. mine))
  equal("finished", match.status)
  equal(0, alice.private.Match.Result(match).winner)
  equal(false, alice.session:CanUndo(match))
  equal(nil, alice.session:Best("minesweeper", "beginner"))
  equal(true, private ~= nil)
end

function tests.MinesweeperKeepsTheBestTimeOfEachLevel()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local session, Match = alice.session, alice.private.Match

  --- Plays a game through without ever guessing: the test can see the mines
  local function win(level, seconds)
    local match = assert(session:Invite({}, "minesweeper", { options = { level = level } }))
    session:Spend(match.id, 30)
    equal(0, session:Elapsed(match), "the clock starts with the first move")
    assert(session:Move(match.id, "r0"))
    local state = Match.State(match)
    for square = 0, state.columns * state.rows - 1 do
      state = Match.State(match)
      if not state.mine[square] and not state.open[square] then
        if state.opened + 1 == state.columns * state.rows - state.mines then
          session:Spend(match.id, seconds)
        end
        assert(session:Move(match.id, "r" .. square))
      end
    end
    equal("finished", match.status)
    equal(1, Match.Result(match).winner)
    return match
  end

  equal(nil, session:Best("minesweeper", "beginner"))
  local first = win("beginner", 50)
  equal(50, session:Best("minesweeper", "beginner"))
  equal(true, session:SetBest(first, "beginner"))
  equal(nil, session:Best("minesweeper", "expert"), "every level has its own")
  local slower = win("beginner", 70)
  equal(50, session:Best("minesweeper", "beginner"), "less is better")
  equal(false, session:SetBest(slower, "beginner"))
  local faster = win("beginner", 20)
  equal(20, session:Best("minesweeper", "beginner"))
  equal(true, session:SetBest(faster, "beginner"))
  win("expert", 300)
  equal(300, session:Best("minesweeper", "expert"))
  equal(20, session:Best("minesweeper", "beginner"))
end

function tests.MinesweeperIsPlayedThroughWithoutLosingCount()
  local won, lost = 0, 0
  for seed = 1, 18 do
    local level = ({ "beginner", "intermediate", "expert" })[seed % 3 + 1]
    local game, state, private = minesweeper(level)
    local luck = private.Random.New(seed)
    local total = state.columns * state.rows
    -- Careful for most of the game and reckless now and then, so that both ends are seen
    local reckless = seed % 2 == 0
    for turn = 1, 2000 do
      if game.result(state) then
        break
      end
      local moves = {}
      for square = 0, total - 1 do
        for _, kind in ipairs({ "r", "f", "c" }) do
          local move = kind .. square
          local safe = kind ~= "r" or not state.mine[square] or (reckless and turn > 25)
          if game.validate(state, 1, move) and safe and (kind ~= "f" or turn % 4 == 0) then
            moves[#moves + 1] = move
          end
        end
      end
      assert(#moves > 0, "a game that isn't over has a move")
      local before = state.opened
      local event = sweep(game, state, moves[luck:Roll(#moves)], private.Random.New(seed * 1000 + turn))
      equal(turn, state.moves)
      equal(state.opened - before, #(event.opened or {}), "the event says what was opened")
      if not event.exploded then
        minesweeperIsSound(state)
      end
      if event.won or event.exploded then
        assert(game.result(state), "and that it is over")
      end
    end
    local result = assert(game.result(state), "seed " .. seed .. " never ended")
    if result.winner == 1 then
      won = won + 1
      equal(total - state.mines, state.opened)
      equal(state.mines, state.flags, "every mine has its flag in the end")
      equal(state.level, game.record(state, 9, result)[1].key)
      equal(true, game.record(state, 9, result)[1].lower)
    else
      lost = lost + 1
      equal(true, state.mine[state.hit])
    end
  end
  assert(won > 0 and lost > 0, "both ways a game can end should come up: " .. won .. " won, " .. lost .. " lost")
end

-----------------------------
-- Minesweeper on screen
-----------------------------

--- Opens the window on a new game of minesweeper
--- @param level string?
--- @return table player, string id, table MainFrame
local function minesweeperOnScreen(level)
  local world = World.New()
  world.seed = 1
  local player = world:AddPlayer("Alice-Realm")
  local MainFrame = openWindow(player)
  function StaticPopup_Show(which, _, _, data)
    StaticPopupDialogs[which].OnAccept(nil, data)
  end
  local match = assert(player.session:Invite({}, "minesweeper", { options = { level = level } }))
  MainFrame.Open(match.id)
  return player, match.id, MainFrame
end

--- The field on screen: the board it is drawn on, and its frame
--- @return table board, table frame
local function shownField()
  local frame = shownBoard()
  return assert(frame.board, "the board on screen isn't a field"), frame
end

--- Lets time pass for everything on screen that does something with it
--- @param seconds number
local function fieldTime(seconds)
  -- Only what the game put on its stage: the window around it keeps the clock, which a test sets itself
  local stage = shownBoard().parent
  local ticking = Client.Find(function(widget)
    return widget.scripts.OnUpdate ~= nil and widget.parent == stage and widget:IsVisible()
  end)
  for _ = 1, math.floor(seconds / 0.02 + 0.5) do
    for _, widget in ipairs(ticking) do
      widget:Fire("OnUpdate", 0.02)
    end
  end
end

--- Clicks a square of the field on screen
--- @param square number
--- @param button string? The left one if left out
local function clickField(square, button)
  local board, frame = shownField()
  clickSquare(frame, square % board.columns, math.floor(square / board.columns), board.columns, button)
end

--- Whether a square of the field on screen still has its cover on
--- @param square number
--- @return boolean
local function covered(square)
  local board = shownField()
  return board.squares[square].inlay.color[4] > 0
end

--- What the field on screen shows, a character a square from the bottom left: "#" covered, "F"
--- flagged, "*" a mine, "X" a wrong flag, the number of an open square and "." for none
--- @return string
local function fieldShown()
  local board = shownField()
  local shown = {}
  for square = 0, board.columns * board.rows - 1 do
    local piece, label = board.pieces[square], board.labels[square]
    local sign = ({ flag = "F", mine = "*", wrong = "X" })[piece or ""]
    shown[#shown + 1] = sign or (covered(square) and "#" or (label and tostring(label) or "."))
  end
  return table.concat(shown)
end

--- What the field on screen should show for a position once nothing is on its way any more
--- @param state table
--- @return string
local function fieldOf(state)
  local lost = state.outcome and state.outcome.winner == 0
  local shown = {}
  for square = 0, state.columns * state.rows - 1 do
    local sign = "#"
    if state.open[square] then
      sign = state.open[square] > 0 and tostring(state.open[square]) or "."
    elseif state.flag[square] then
      sign = (lost and not state.mine[square]) and "X" or "F"
    elseif lost and state.mine[square] then
      sign = "*"
    end
    shown[#shown + 1] = sign
  end
  return table.concat(shown)
end

--- What a box over the field says
--- @param title string
--- @return string
local function statSays(title)
  local found = Client.Find(function(widget)
    return widget.caption ~= nil and widget.caption.text == title and widget:IsVisible()
  end)
  equal(1, #found, "boxes called " .. title)
  return found[1].value.text
end

--- @param name string
--- @return number How often a sound was played
local function heard(name)
  local count = 0
  for _, sound in ipairs(Client.sounds) do
    count = count + (sound == name and 1 or 0)
  end
  return count
end

function tests.WindowShowsAMinefield()
  local player, id = minesweeperOnScreen()
  local board, frame = shownField()
  local state = player.private.Match.State(player.matches[id])
  equal(9, board.columns)
  equal(9, board.rows)
  equal(string.rep("#", 81), fieldShown(), "every square covered")
  equal(true, says("game_minesweeper"))
  equal(true, says("minesweeper_progress"))
  equal(false, says("status_your_turn"))
  equal("10", statSays("minesweeper_mines"))
  equal("0:00", statSays("stat_time"))
  equal("stat_none", statSays("stat_best"))
  equal(0, #Client.Find(function(widget)
    return widget.kind == "Button" and widget.text == "undo" and widget:IsVisible()
  end), "nothing can be taken back")
  equal(false, state.laid)

  -- The first click opens a patch, which ripples outward rather than being there at once
  Client.sounds = {}
  clickField(40)
  equal("r40", logOf(player, id))
  state = player.private.Match.State(player.matches[id])
  assert(state.opened > 8)
  equal(string.rep("#", 81), fieldShown(), "nothing of it yet")
  local partly = false
  for _ = 1, 100 do
    fieldTime(0.02)
    local shown = select(2, fieldShown():gsub("#", "#"))
    partly = partly or (shown < 81 and shown > 81 - state.opened)
  end
  equal(true, partly, "it takes a while")
  equal(fieldOf(state), fieldShown())
  equal(false, covered(40))
  equal(1, heard("cardSlide") + heard("IG_MAINMENU_OPTION_CHECKBOX_ON"))
  assert(frame.width > 0 and frame.width == board.cell * 9)

  -- The numbers are written in their colours
  for square = 0, 80 do
    local label = board.squares[square].label
    local number = state.open[square]
    if number and number > 0 then
      equal(tostring(number), label.text)
      assert(board.inks[square], "a number has a colour")
    end
  end

  -- The clock runs from the first move on, and only while the game is looked at
  ForeverGamesFrame.detail:Fire("OnUpdate", 61)
  fieldTime(0.02)
  equal("1:01", statSays("stat_time"))

  -- Looking at it again changes nothing
  ForeverGamesFrame:Hide()
  ForeverGamesFrame:Show()
  equal(fieldOf(state), fieldShown())
end

function tests.WindowFlagsAndChordsAMinefield()
  local player, id = minesweeperOnScreen()
  local Match, match = player.private.Match, player.matches[id]
  clickField(40)
  fieldTime(2)
  local state = Match.State(match)
  local board, frame = shownField()

  -- A right click plants a flag, which pops in, and another takes it away again
  local mine = nil
  for square = 0, 80 do
    mine = mine or (state.mine[square] and square or nil)
  end
  Client.sounds = {}
  clickField(mine, "RightButton")
  equal("r40,f" .. mine, logOf(player, id))
  equal("flag", board.pieces[mine])
  equal(true, board.pops[mine] ~= nil, "it pops in")
  equal("9", statSays("minesweeper_mines"))
  equal(1, heard("chipsCollide"))
  settle(frame)
  equal(nil, board.pops[mine])
  equal(true, covered(mine))
  clickField(mine, "RightButton")
  equal(nil, board.pieces[mine])
  equal("10", statSays("minesweeper_mines"))
  equal(1, heard("IG_BACKPACK_CLOSE"))

  -- A left click on a flag does nothing but say so, and neither does a right click on an open square
  clickField(mine, "RightButton")
  local moves = #match.log
  Client.sounds = {}
  clickField(mine)
  equal(moves, #match.log)
  equal(1, heard("IG_MAINMENU_OPTION_CHECKBOX_OFF"))
  fieldTime(0.04)
  assert(board.tints[mine], "the square lights up")
  fieldTime(1)
  equal(nil, board.tints[mine], "for a moment")
  clickField(40, "RightButton")
  equal(moves, #match.log)
  equal(2, heard("IG_MAINMENU_OPTION_CHECKBOX_OFF"))
  fieldTime(1)

  -- Pointing at a number shows what it is about
  local number, waiting = nil, nil
  for square = 0, 80 do
    if not number and (state.open[square] or 0) > 0 then
      local hidden, flags = {}, 0
      for other = 0, 80 do
        local across, down = math.abs(other % 9 - square % 9), math.abs(math.floor(other / 9) - math.floor(square / 9))
        local near = math.max(across, down) == 1
        if near and state.flag[other] then
          flags = flags + 1
        elseif near and not state.open[other] then
          hidden[#hidden + 1] = other
        end
      end
      if flags == 0 and #hidden > 0 then
        number, waiting = square, hidden
      end
    end
  end
  assert(number, "there should be a number with nothing flagged around it")
  Client.cursor = { (number % 9 + 0.5) * board.cell, (math.floor(number / 9) + 0.5) * board.cell }
  frame:Fire("OnUpdate", 0.02)
  for _, square in ipairs(waiting) do
    assert(board.tints[square], "square " .. square .. " should be pointed out")
  end

  -- A chord on a number without its flags is refused, by the middle button as well
  Client.sounds = {}
  moves = #match.log
  press(frame)
  release(frame)
  frame:Fire("OnMouseDown", "MiddleButton")
  equal(moves, #match.log)
  equal(2, heard("IG_MAINMENU_OPTION_CHECKBOX_OFF"))
  fieldTime(1)
  Client.cursor = { -5, -5 }
  frame:Fire("OnUpdate", 0.02)
  equal(nil, next(board.tints), "nothing pointed out once the cursor is gone")
end

--- Plays the game on screen to the end by clicking, the mines being known to the test: flags a
--- mine, chords where that can be done and opens a safe square where not
--- @param player table
--- @param id string
--- @param withMiddle boolean Chord with the middle button rather than the left
--- @return number chords How many were made
local function clearFieldOnScreen(player, id, withMiddle)
  local Match, match = player.private.Match, player.matches[id]
  local game = player.private.Games.Get("minesweeper")
  local chords = 0
  for _ = 1, 600 do
    local state = Match.State(match)
    if match.status ~= "active" then
      break
    end
    local total = state.columns * state.rows
    local move = nil
    for square = 0, total - 1 do
      if not move and game.validate(state, 1, "c" .. square) then
        -- Only where the flags are right, which they are: the test planted them
        move = "c" .. square
      end
    end
    for square = 0, total - 1 do
      if not move and state.mine[square] and not state.flag[square] and state.moves % 3 == 0 then
        move = "f" .. square
      end
    end
    for square = 0, total - 1 do
      if not move and not state.mine[square] and game.validate(state, 1, "r" .. square) then
        move = "r" .. square
      end
    end
    local kind, square = move:sub(1, 1), tonumber(move:sub(2))
    local before = #match.log
    if kind == "f" then
      clickField(square, "RightButton")
    elseif kind == "c" and withMiddle then
      local board, frame = shownField()
      Client.cursor = { (square % board.columns + 0.5) * board.cell, (math.floor(square / board.columns) + 0.5) * board.cell }
      frame:Fire("OnUpdate", 0.02)
      frame:Fire("OnMouseDown", "MiddleButton")
    else
      clickField(square)
    end
    chords = chords + (kind == "c" and 1 or 0)
    equal(before + 1, #match.log, move .. " should have been played")
    equal(move, match.log[#match.log])
    -- Sometimes the next click comes before the last one has been shown to the end
    if before % 2 == 0 then
      fieldTime(1.5)
      equal(fieldOf(Match.State(match)), fieldShown(), "after " .. move)
    end
  end
  return chords
end

function tests.WindowPlaysMinesweeperToAWin()
  local player, id, MainFrame = minesweeperOnScreen()
  local Match, match = player.private.Match, player.matches[id]
  clickField(40)
  ForeverGamesFrame.detail:Fire("OnUpdate", 83)
  Client.sounds = {}
  local chords = clearFieldOnScreen(player, id, false)
  assert(chords > 0, "some of it should have been chords")
  equal("finished", match.status)
  local state = Match.State(match)
  equal(1, state.outcome.winner)
  equal("status_won_with", MainFrame.Describe(match))

  -- The mines that were left are flagged one after the other, under paper, and then it says so
  local board, frame = shownField()
  fieldTime(4)
  settle(frame)
  equal(fieldOf(state), fieldShown())
  equal(10, select(2, fieldShown():gsub("F", "F")))
  equal("0", statSays("minesweeper_mines"))
  equal(true, says("minesweeper_won"))
  equal(true, says("minesweeper_cleared_best"), "the first win is the best there is")
  equal("1:23", statSays("stat_best"))
  equal("1:23", statSays("stat_time"))
  equal(1, heard("IG_QUEST_LIST_COMPLETE"))
  equal(0, heard("dieThrow"))
  assert(heard("chipsCollide") > 0 and heard("cardSlide") + heard("IG_MAINMENU_OPTION_CHECKBOX_ON") > 0)
  ForeverGamesFrame.detail:Fire("OnUpdate", 30)
  fieldTime(0.1)
  equal("1:23", statSays("stat_time"), "the clock stops with the game")

  -- Nothing more to click
  local moves = #match.log
  clickField(0)
  clickField(0, "RightButton")
  equal(moves, #match.log)

  -- Another game: the words are gone, the field is covered again and the best time stays
  Client.Button("play_again"):Fire("OnClick")
  local another = nil
  for other in pairs(player.matches) do
    another = other ~= id and other or another
  end
  equal(true, MainFrame.IsViewing(another))
  equal(false, says("minesweeper_won"))
  equal(string.rep("#", 81), fieldShown())
  equal("10", statSays("minesweeper_mines"))
  equal("0:00", statSays("stat_time"))
  equal("1:23", statSays("stat_best"))

  -- A slower win is no record
  clickField(40)
  ForeverGamesFrame.detail:Fire("OnUpdate", 200)
  clearFieldOnScreen(player, another, true)
  fieldTime(4)
  equal(true, says("minesweeper_won"))
  equal(true, says("minesweeper_cleared_in"))
  equal(false, says("minesweeper_cleared_best"))
  equal("1:23", statSays("stat_best"))

  -- The one that was won first is still there to look at, with what it says across it at once
  MainFrame.Select(id)
  equal(true, says("minesweeper_won"))
  equal(true, says("minesweeper_cleared_best"))
  equal(fieldOf(state), fieldShown())
  equal(board, (shownField()))
end

function tests.WindowBlowsAMinefieldUp()
  local player, id, MainFrame = minesweeperOnScreen("intermediate")
  local Match, match = player.private.Match, player.matches[id]
  local board, frame = shownField()
  equal(16, board.columns)
  clickField(120)
  fieldTime(2)
  local state = Match.State(match)

  -- A flag where there is nothing, a flag where there is something, and then a mine
  local mines, safe = {}, nil
  for square = 0, 255 do
    if state.mine[square] then
      mines[#mines + 1] = square
    elseif not state.open[square] then
      safe = safe or square
    end
  end
  clickField(safe, "RightButton")
  clickField(mines[1], "RightButton")
  fieldTime(1)
  Client.sounds = {}
  local hit = mines[#mines]
  clickField(hit)
  equal("finished", match.status)
  state = Match.State(match)
  equal(0, state.outcome.winner)
  equal("status_solo_lost_with", MainFrame.Describe(match))

  -- The one that was hit goes off first, then the rest away from it, then the wrong flag is turned over
  fieldTime(0.02)
  equal("mine", board.pieces[hit])
  equal(false, covered(hit))
  assert(board.tints[hit], "the culprit is pointed out")
  equal(1, heard("dieThrow"))
  equal(1, heard("IG_QUEST_FAILED"))
  equal(false, says("minesweeper_lost"))
  local shownMines = select(2, fieldShown():gsub("%*", "*"))
  assert(shownMines < 39, "the others take their time, " .. shownMines .. " are there at once")
  equal("flag", board.pieces[safe], "the wrong flag is still a flag")
  local partly = false
  for _ = 1, 150 do
    fieldTime(0.02)
    local count = select(2, fieldShown():gsub("%*", "*"))
    partly = partly or (count > 1 and count < 39)
  end
  settle(frame)
  equal(true, partly)
  equal(fieldOf(state), fieldShown())
  equal(39, select(2, fieldShown():gsub("%*", "*")), "every mine but the one that was flagged")
  equal("wrong", board.pieces[safe])
  equal("flag", board.pieces[mines[1]])
  equal(true, covered(mines[1]))
  assert(board.tints[hit], "the culprit stays pointed out")
  equal(true, says("minesweeper_lost"))
  equal(true, says("minesweeper_cleared_some"))
  equal("38", statSays("minesweeper_mines"))
  equal("stat_none", statSays("stat_best"))
  equal(1, heard("dieThrow"), "once is enough")

  -- Nothing more to click, and nothing to take back
  local moves = #match.log
  clickField(0)
  clickField(0, "RightButton")
  equal(moves, #match.log)
  equal(false, player.session:CanUndo(match))

  -- A game of another size has a field of its own, and coming back shows this one as it ended
  local expert = assert(player.session:Invite({}, "minesweeper", { options = { level = "expert" } }))
  MainFrame.Select(expert.id)
  local wide = shownField()
  equal(30, wide.columns)
  equal(false, says("minesweeper_lost"))
  equal(string.rep("#", 480), fieldShown())
  equal("99", statSays("minesweeper_mines"))
  MainFrame.Select(id)
  equal(board, (shownField()))
  equal(true, says("minesweeper_lost"))
  equal(fieldOf(state), fieldShown())
  assert(board.tints[hit])
end

function tests.WindowShowsAMoveThatIsCutShortAsItEndsUp()
  local player, id = minesweeperOnScreen("expert")
  local Match, match = player.private.Match, player.matches[id]
  clickField(200)
  local state = Match.State(match)
  local board = shownField()
  equal(string.rep("#", 480), fieldShown())

  -- Hidden in the middle of it: there by the time it is looked at again
  fieldTime(0.1)
  local ticker = Client.Find(function(widget)
    return widget.scripts.OnHide ~= nil and widget.scripts.OnUpdate ~= nil and widget.parent == board.frame.parent
  end)
  assert(#ticker >= 1)
  for _, widget in ipairs(ticker) do
    widget:Fire("OnHide")
  end
  equal(fieldOf(state), fieldShown())

  -- The next click before the last one is over: nothing of the first is left behind
  local closed = nil
  for square = 0, 479 do
    closed = closed or ((not state.open[square] and not state.mine[square]) and square or nil)
  end
  if closed then
    clickField(closed)
    clickField(closed == 0 and 1 or 0, "RightButton")
    state = Match.State(match)
    fieldTime(3)
    equal(fieldOf(state), fieldShown())
  end
  -- Being told again and again that nothing changed starts nothing over
  local MainFrame = player.private.MainFrame
  MainFrame.Refresh()
  MainFrame.Refresh()
  equal(fieldOf(state), fieldShown())
end

function tests.WindowFitsAMinefieldIntoTheRoomItHas()
  for _, level in ipairs({ "beginner", "intermediate", "expert" }) do
    local player, id = minesweeperOnScreen(level)
    local board, frame = shownField()
    local stage = frame.parent
    clickField(board.columns + 1)
    fieldTime(2)
    local state = player.private.Match.State(player.matches[id])
    local normal = board.cell

    local function fits(least)
      equal(board.cell * board.columns, frame.width)
      equal(board.cell * board.rows, frame.height)
      local room = stage.width .. "x" .. stage.height
      assert(frame.width <= stage.width and frame.height + 38 <= stage.height, level .. " doesn't fit into " .. room)
      assert(board.cell >= least, level .. " squares are too small to play on: " .. board.cell)
      assert(board.cell <= 56, "nor are they ever huge")
      local boxes = Client.Find(function(widget)
        return widget.caption ~= nil and widget:IsVisible()
      end)
      equal(3, #boxes)
      assert(boxes[1].width * 3 <= stage.width, "the boxes fit side by side")
      equal(fieldOf(state), fieldShown())
    end
    fits(14)
    ForeverGamesFrame:SetSize(1800, 1300)
    assert(board.cell > normal, "a bigger window should mean bigger squares")
    fits(32)
    ForeverGamesFrame:SetSize(764, 560)
    fits(14)
  end
end

function tests.WizardSetsAGameForOneUpBeforeItBegins()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local Wizard = openWizard(alice)
  pickGame("minesweeper")
  equal(true, Wizard.IsOpen(), "there is something to choose first")
  equal(0, #alice.session:List())
  -- Somebody to race it against, or nobody (see WizardChallengesSomebodyToARace)
  equal(true, says("wizard_step_opponent"))
  equal(true, says("minesweeper_option_level"))
  equal("minesweeper_level_beginner", select(2, ruleChoices("minesweeper_option_level")))
  ruleChoices("minesweeper_option_level")["minesweeper_level_expert"]:Fire("OnClick")
  equal(true, says("wizard_solo_note"))
  Client.Button("wizard_play_alone"):Fire("OnClick")
  equal(false, Wizard.IsOpen())
  local started
  for _, match in pairs(alice.matches) do
    started = match
  end
  equal("minesweeper", started.game)
  equal("active", started.status)
  equal("expert", started.options.level)
  equal(30, alice.private.Match.State(started).columns)
  equal(0, #world.queue, "nothing is sent to anyone")

  -- The next one starts out set the same way, and a challenge is still called one
  Wizard.Open()
  pickGame("minesweeper")
  equal("minesweeper_level_expert", select(2, ruleChoices("minesweeper_option_level")))
  Client.Button("Back"):Fire("OnClick")
  pickGame("chess")
  equal(true, says("wizard_step_opponent"))
  equal(1, #Client.Find(function(widget)
    return widget.kind == "Button" and widget.text == "wizard_send" and widget:IsVisible()
  end))
  equal(1, #Client.Find(function(widget)
    return widget.kind == "EditBox" and widget.scripts.OnEnterPressed and widget:IsVisible()
  end), "with somebody to pick")
end

-----------------------------
-- What games for one share
-----------------------------

--- A game for one that is nothing but counting, to try what the engine does for such games on:
--- "u" counts one up, "w" wins it and "x" loses it
--- @param private table
--- @param shown table? Filled with what the view is asked to show
local function registerCounting(private, shown)
  private.Games.Register({
    id = "counting",
    name = "Counting",
    genre = "solo",
    version = 1,
    seats = 1,
    undo = true,
    clock = "move",
    newState = function()
      return { count = 0 }
    end,
    turn = function()
      return 1
    end,
    validate = function(_, _, move)
      return move == "u" or move == "w" or move == "x"
    end,
    apply = function(state, _, move)
      state.count = state.count + (move == "u" and 1 or 0)
      state.outcome = move ~= "u" and { winner = move == "w" and 1 or 0 } or nil
    end,
    result = function(state)
      return state.outcome
    end,
    progress = function()
      return "so far"
    end,
    record = function(state, seconds, result)
      local records = { { key = "score", value = state.count } }
      if result and result.winner == 1 then
        records[2] = { key = "time", value = seconds, lower = true }
      end
      return records
    end,
    createView = function()
      return {
        Layout = function() end,
        Update = function(_, view)
          shown.view = view
        end,
      }
    end,
  })
end

function tests.GameForOneIsTimedAndKeepsTheBest()
  local world = World.New()
  local records = {}
  local alice = world:AddPlayer("Alice-Realm")
  alice.session.env.records = records
  registerCounting(alice.private)
  local session = alice.session

  local match = assert(session:Invite({}, "counting"))
  equal(nil, session:Best("counting", "score"))
  session:Spend(match.id, 5)
  equal(0, session:Elapsed(match), "the clock starts with the first move")
  assert(session:Move(match.id, "u"))
  assert(session:Move(match.id, "u"))
  session:Spend(match.id, 5)
  session:Spend(match.id, 2.5)
  equal(7.5, session:Elapsed(match))
  equal(2, session:Best("counting", "score"))
  equal(true, session:SetBest(match, "score"))
  equal(nil, session:Best("counting", "time"), "only a game that was won has a time")
  assert(session:Move(match.id, "w"))
  equal(7.5, session:Best("counting", "time"))
  session:Spend(match.id, 5)
  equal(7.5, session:Elapsed(match), "what is over is off the clock")
  equal(2, records.counting.score, "kept where it is saved")

  -- Only what is better is kept: more of a score, less of a time
  local slower = assert(session:Invite({}, "counting"))
  assert(session:Move(slower.id, "u"))
  session:Spend(slower.id, 20)
  assert(session:Move(slower.id, "w"))
  equal(2, session:Best("counting", "score"))
  equal(7.5, session:Best("counting", "time"))
  equal(false, session:SetBest(slower, "score"))
  equal(false, session:SetBest(slower, "time"))
  local faster = assert(session:Invite({}, "counting"))
  for _ = 1, 3 do
    assert(session:Move(faster.id, "u"))
  end
  session:Spend(faster.id, 3)
  assert(session:Move(faster.id, "w"))
  equal(3, session:Best("counting", "score"))
  equal(3, session:Best("counting", "time"))
  equal(true, session:SetBest(faster, "time"))

  -- A game without any of it is left alone
  local other = assert(session:Invite({}, "solitaire"))
  assert(session:Move(other.id, "d"))
  session:Spend(other.id, 5)
  equal(0, session:Elapsed(other))
  session:Spend("nope", 5)
end

function tests.WindowTimesAGameForOneAndSaysHowItWasLost()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local shown = {}
  registerCounting(alice.private, shown)
  local MainFrame = openWindow(alice)
  local match = assert(alice.session:Invite({}, "counting"))
  MainFrame.Open(match.id)

  equal(0, shown.view.clock())
  ForeverGamesFrame.detail:Fire("OnUpdate", 2)
  equal(0, shown.view.clock(), "nothing played yet")
  assert(alice.session:Move(match.id, "u"))
  ForeverGamesFrame.detail:Fire("OnUpdate", 2)
  ForeverGamesFrame.detail:Fire("OnUpdate", 1)
  equal(3, shown.view.clock())
  local best, mine = shown.view.best("score")
  equal(1, best)
  equal(true, mine)
  equal(nil, (shown.view.best("time")))

  assert(alice.session:Move(match.id, "x"))
  equal("status_solo_lost_with", MainFrame.Describe(match), "lost, which isn't giving up")
  ForeverGamesFrame.detail:Fire("OnUpdate", 4)
  equal(3, shown.view.clock())

  local won = assert(alice.session:Invite({}, "counting"))
  assert(alice.session:Move(won.id, "w"))
  equal("status_won_with", MainFrame.Describe(won))
  local quit = assert(alice.session:Invite({}, "counting"))
  assert(alice.session:Resign(quit.id))
  equal("status_gave_up", MainFrame.Describe(quit))
end

--- Loads some of the window's building blocks on their own, over a fresh fake client
--- @param files string[]
--- @return table private
local function loadWidgets(files)
  Client.Install()
  ForeverGames = { db = { profile = { sound = true } } }
  local private = { L = setmetatable({}, {
    __index = function(_, key)
      return key
    end,
  }) }
  for _, file in ipairs(files) do
    assert(loadfile(file))(ADDON_NAME, private)
  end
  return private
end

function tests.KeysAreOnlyTakenUnderTheCursorAndOutOfCombat()
  local Widgets = loadWidgets({ "GUI/Widgets.lua" }).Widgets
  local frame = CreateFrame("Frame", nil, UIParent)
  local pressed = {}
  Widgets.Keys(frame, function(key)
    pressed[#pressed + 1] = key
    return key == "LEFT"
  end)
  equal(true, frame.keyboard)
  equal(true, frame.propagates)

  frame:Fire("OnKeyDown", "LEFT")
  equal(false, frame.propagates, "a key that was used goes no further")
  frame:Fire("OnKeyDown", "W")
  equal(true, frame.propagates, "any other does what it always does")
  equal("LEFT,W", table.concat(pressed, ","))

  Client.over = false
  frame:Fire("OnKeyDown", "LEFT")
  equal(true, frame.propagates, "not while the cursor is somewhere else")
  equal(2, #pressed)
  Client.over = true

  -- In combat every key is the game client's
  frame:Fire("OnKeyDown", "LEFT")
  equal(false, frame.propagates)
  frame:Fire("OnEvent", "PLAYER_REGEN_DISABLED")
  equal(true, frame.propagates)
  equal(false, frame.keyboard)
  Client.combat = true
  frame:Fire("OnKeyDown", "LEFT")
  equal(true, frame.propagates)
  equal(3, #pressed)
  Client.combat = false
  frame:Fire("OnEvent", "PLAYER_REGEN_ENABLED")
  equal(true, frame.keyboard)

  -- One that is made in combat waits for it to be over
  Client.combat = true
  local late = CreateFrame("Frame", nil, UIParent)
  Widgets.Keys(late, function()
    return true
  end)
  equal(nil, late.keyboard)
  Client.combat = false
  late:Fire("OnEvent", "PLAYER_REGEN_ENABLED")
  equal(true, late.keyboard)
  equal(true, late.propagates)
end

function tests.AnimatorEasesAndClocksAreWritten()
  local Widgets = loadWidgets({ "GUI/Widgets.lua" }).Widgets
  equal("0:00", Widgets.Time(0))
  equal("0:07", Widgets.Time(7.9))
  equal("12:34", Widgets.Time(754))
  equal("1:02:03", Widgets.Time(3723))

  for name, ease in pairs(Widgets.Ease) do
    equal(0, math.floor(ease(0) * 1000 + 0.5), name .. " starts where it was")
    equal(name == "swell" and 0 or 1000, math.floor(ease(1) * 1000 + 0.5), name .. " ends where it is going")
  end
  assert(Widgets.Ease.back(0.7) > 1, "past the end on the way")

  local frame = CreateFrame("Frame", nil, UIParent)
  local animator = Widgets.Animator(frame)
  local plain, eased = {}, {}
  animator:Play(1, function(progress)
    plain[#plain + 1] = progress
  end)
  animator:Play(1, function(progress)
    eased[#eased + 1] = progress
  end, { ease = Widgets.Ease.out })
  frame:Fire("OnUpdate", 0.5)
  frame:Fire("OnUpdate", 0.5)
  equal("0.5,1", table.concat(plain, ","))
  equal("0.875,1", table.concat(eased, ","))
  equal(false, animator:Busy())

  local stat = Widgets.Stat(UIParent, "stat_score", 80)
  stat:Set(12)
  equal("12", stat.value.text)
  equal("stat_score", stat.caption.text)
end

function tests.EffectsComeAndGo()
  local private = loadWidgets({ "GUI/Widgets.lua", "GUI/Effects.lua" })
  local stage = CreateFrame("Frame", nil, UIParent)
  stage:SetSize(400, 300)
  local effects = private.Effects.New(stage)
  effects.frame:SetSize(400, 300)
  equal(false, effects:Busy())

  effects:Confetti()
  effects:Flash({ 1, 0, 0 })
  effects:Jolt(stage)
  effects:Float("+8", 100, 100)
  effects:Float("+16", 120, 100, { delay = 0.1 })
  effects:Banner("status_won", "so far")
  equal(true, effects:Busy())
  equal(true, effects:HasBanner())
  for _ = 1, 250 do
    effects.frame:Fire("OnUpdate", 0.02)
  end
  equal(false, effects:Busy(), "it all comes to an end")
  equal(true, effects.title:IsVisible(), "but for the words")
  equal("status_won", effects.title.text)
  equal(false, effects.flash:IsShown())
  for _, paper in ipairs(effects.papers) do
    equal(false, paper:IsShown())
  end
  equal(2, #effects.floats, "one drifting number for each at a time")
  effects:Float("+4", 100, 100)
  equal(2, #effects.floats, "and they are used again")

  effects:Clear()
  equal(false, effects:Busy())
  equal(false, effects:HasBanner())
  equal(false, effects.title:IsShown())
  effects:Banner("status_solo_lost", nil, { instant = true })
  equal(false, effects:Busy())
  equal(true, effects.title:IsShown())
end

function tests.DiceAreThrownAndComeToRest()
  local private = loadWidgets({ "GUI/Widgets.lua", "GUI/Dice.lua" })
  local surface = CreateFrame("Frame", nil, UIParent)
  surface:SetSize(400, 300)
  local dice = private.Dice.New(surface)
  local function roll(key, faces, spent)
    local from = { x = 350, y = 150 }
    return { key = key, faces = faces, color = "red", x = 200, y = 150, from = from, size = 40, thrown = 2, spent = spent, glow = #faces > 2 }
  end
  local function settle()
    for _ = 1, 100 do
      dice.frame:Fire("OnUpdate", 0.02)
    end
  end
  local function shown()
    local faces = {}
    for index, die in ipairs(dice.dice) do
      faces[index] = die.face:IsShown() and tonumber(die.face.texture:match("%d$")) or 0
    end
    return table.concat(faces, ",")
  end

  -- Doubles: two are thrown, the other two put down once those have landed
  dice:Show(roll("a", { 4, 4, 4, 4 }))
  equal("4,4,4,4", shown(), "a roll that isn't thrown just lies there")
  dice:Throw(0.1)
  equal(true, dice:Busy())
  equal("0,0,0,0", shown(), "nothing is on the table until it is thrown")
  settle()
  equal(false, dice:Busy())
  equal("4,4,4,4", shown())
  equal("dieThrow", Client.sounds[#Client.sounds])
  for _, die in ipairs(dice.dice) do
    equal(false, die.glow:IsShown(), "the light of doubles goes out again")
  end

  -- Shown again, the same roll stays where it came to rest and only the die used up changes
  local rested = dice.dice[1].face.anchors[1][4]
  dice:Show(roll("a", { 4, 4, 4, 4 }, { true }))
  settle()
  equal(rested, dice.dice[1].face.anchors[1][4])
  assert(dice.dice[1].face:GetAlpha() < 1)
  equal(1, dice.dice[2].face:GetAlpha())

  -- In hand: they wait for the player, shake while the button is held and fly when it comes up
  dice:Show(roll("b", { 6, 2 }))
  local thrown = 0
  dice:Hold(function()
    thrown = thrown + 1
  end)
  equal(true, dice:Holding())
  equal(false, dice:Busy())
  dice.hand:Fire("OnMouseDown", "RightButton")
  equal(0, #Client.stopped, "only the left button shakes them")
  dice.hand:Fire("OnMouseDown", "LeftButton")
  equal("dieShuffle", Client.sounds[#Client.sounds])
  -- A table that goes away holds them still, still in hand
  dice.frame:Hide()
  equal("dieShuffle", Client.stopped[1])
  equal(true, dice:Holding())
  dice.frame:Show()
  dice.hand:Fire("OnMouseUp", "LeftButton")
  equal(0, thrown, "letting go of a button that went down before doesn't throw them")
  dice.hand:Fire("OnMouseDown", "LeftButton")
  dice.hand:Fire("OnMouseUp", "LeftButton")
  equal(1, thrown)
  equal(false, dice:Holding())
  equal(false, dice.hand:IsShown())
  settle()
  equal("6,2,0,0", shown())

  -- A new roll takes the place of one still in the air, and a hand still full is put away
  dice:Show(roll("c", { 3, 1 }))
  dice:Throw()
  dice:Show(roll("d", { 5, 5, 5, 5 }))
  equal(false, dice:Busy())
  equal("5,5,5,5", shown())
  dice:Hold(function() end)
  dice:Hide()
  equal(false, dice:Holding())
  equal("0,0,0,0", shown())
end

function tests.BoardTellsARightClickOnASquareAndColoursWhatItWrites()
  local private = loadWidgets({ "GUI/Widgets.lua", "GUI/Board.lua" })
  local board = private.Board.New(UIParent, { columns = 3, rows = 3, labelScale = 0.6 })
  board:SetSize(90)
  local right, waved = {}, {}
  local input = {
    onRightClick = function(square)
      right[#right + 1] = square
    end,
    onCancel = function(button)
      waved[#waved + 1] = button or "none"
    end,
  }
  board:SetInput(input)
  board:SetEnabled(true)

  -- The bottom left square is 0, the cursor is counted up from the bottom of the screen
  Client.cursor = { 45, 45 }
  board.frame:Fire("OnMouseDown", "RightButton")
  Client.cursor = { 75, 15 }
  board.frame:Fire("OnMouseDown", "RightButton")
  equal("4,2", table.concat(right, ","))
  board.frame:Fire("OnMouseDown", "MiddleButton")
  Client.cursor = { 200, 200 }
  board.frame:Fire("OnMouseDown", "RightButton")
  equal("MiddleButton,RightButton", table.concat(waved, ","), "anything else is still a wave off")
  input.onRightClick = nil
  Client.cursor = { 45, 45 }
  board.frame:Fire("OnMouseDown", "RightButton")
  equal(3, #waved)
  equal(2, #right)

  local blue = { 0.2, 0.4, 1 }
  local inks = {}
  board:SetLabels({ [4] = 3, [5] = 1 }, { [4] = blue })
  local label = board.squares[4].label
  function label:SetTextColor(r, g, b)
    inks[#inks + 1] = r .. "," .. g .. "," .. b
  end
  equal("3", label.text)
  board:SetLabels({ [4] = 3 }, { [4] = blue })
  equal(0, #inks, "nothing is done about what didn't change")
  board:SetLabels({ [4] = 2 })
  equal("2", label.text)
  equal("1,1,1", table.concat(inks, " "), "white unless it says otherwise")
  equal("", board.squares[5].label.text)
end

-----------------------------
-- Sudoku
-----------------------------

do
  local GRADES = { easy = 1, medium = 2, hard = 3, expert = 4 }
  -- What making a puzzle is held to. The work it may take, which is counted and so comes out the
  -- same wherever the tests run: what the game allows itself, and the one thing it was in the
  -- middle of when that ran out. And the time that takes, with a lot of room to spare for a
  -- machine that is busy: it is a few thousandths of a second for an easy puzzle and between
  -- ten and twenty for the others, with never more than about thirty
  local WORK_MOST, SECONDS_MOST = 8000 + 2500, 0.25

  --- A game of sudoku to try the rules on, made from a seed
  --- @param seed number?
  --- @param rules table?
  --- @return table game, table state, table private
  local function sudoku(seed, rules)
    local private = loadEngine()
    local game = private.Games.Get("sudoku")
    return game, game.newState(1, private.Random.New(seed or 1), rules), private
  end

  --- @param cell number
  --- @return string How moves name a square
  local function squareName(cell)
    return (math.floor((cell - 1) / 9) + 1) .. ((cell - 1) % 9 + 1)
  end

  --- @param cell number
  --- @return number row, number column, number box Where a square is, each counted from 0
  local function whereIs(cell)
    local row, column = math.floor((cell - 1) / 9), (cell - 1) % 9
    return row, column, math.floor(row / 3) * 3 + math.floor(column / 3)
  end

  --- @param one number
  --- @param other number
  --- @return boolean Whether two squares share a row, a column or a box
  local function sharesUnit(one, other)
    local row, column, box = whereIs(one)
    local otherRow, otherColumn, otherBox = whereIs(other)
    return row == otherRow or column == otherColumn or box == otherBox
  end

  --- @param state table
  --- @param from number? The first square to look at
  --- @return number? cell The first square that has nothing in it
  local function emptySquare(state, from)
    for cell = from or 1, 81 do
      if state.grid[cell] == 0 then
        return cell
      end
    end
    return nil
  end

  --- @param state table
  --- @param cell number
  --- @return number A digit that doesn't belong in a square
  local function wrongDigit(state, cell)
    return state.solution[cell] % 9 + 1
  end

  --- Whether a game of sudoku is what it should be whatever was done to it
  --- @param state table
  local function sudokuIsSound(state)
    local filled = 0
    for cell = 1, 81 do
      local digit = state.grid[cell]
      filled = filled + (digit ~= 0 and 1 or 0)
      if state.given[cell] or state.hinted[cell] then
        equal(state.solution[cell], digit, "what was filled in for the player stays")
      end
      for note = 1, 9 do
        assert(digit == 0 or not state.notes[(cell - 1) * 9 + note], "notes are only in empty squares")
      end
    end
    equal(filled, state.filled)
  end

  function tests.SudokuPuzzlesHaveOneSolutionAndAreAsHardAsTheySay()
    local private = loadEngine()
    local Sudoku, Random = private.Sudoku, private.Random
    local seeds = 40
    for _, level in ipairs(Sudoku.LEVELS) do
      local stock, squares = 0, 0
      for seed = 1, seeds do
        local started = os.clock()
        local puzzle, solution, made = Sudoku.Generate(Random.New(seed * 104729), level)
        local took = os.clock() - started
        assert(made.work <= WORK_MOST, level .. " " .. seed .. " took " .. made.work .. " to make")
        assert(took <= SECONDS_MOST, level .. " " .. seed .. " took " .. took .. " seconds to make")
        stock = stock + (made.stock and 1 or 0)

        local count, found = Sudoku.Count(puzzle)
        equal(1, count, level .. " " .. seed .. " solutions")
        equal(table.concat(solution), table.concat(found), "the solution it comes with is the one it has")
        equal(GRADES[level], Sudoku.Grade(puzzle), level .. " " .. seed .. " is as hard as it says")
        for cell = 1, 81 do
          assert(puzzle[cell] == 0 or puzzle[cell] == solution[cell])
          squares = squares + (puzzle[cell] ~= 0 and 1 or 0)
          if level == "easy" then
            equal(puzzle[cell] ~= 0, puzzle[82 - cell] ~= 0, "an easy one looks the same from the other side")
          end
        end
      end
      -- An easy one comes with a lot more to go on than the others
      if level == "easy" then
        equal(0, stock, "an easy puzzle is always made")
        assert(squares / seeds >= 36 and squares / seeds <= 40, "easy puzzles come with " .. squares / seeds)
      else
        assert(stock <= seeds / 2, "most " .. level .. " puzzles should be made, " .. stock .. " weren't")
        assert(squares / seeds >= 22 and squares / seeds <= 31, level .. " puzzles come with " .. squares / seeds)
      end
    end
  end

  function tests.SudokuPuzzlesFromStockAreSoundHoweverTheyAreMixed()
    local private = loadEngine()
    local Sudoku, Random = private.Sudoku, private.Random
    for _, level in ipairs(Sudoku.LEVELS) do
      local stock = Sudoku.AllStock()[level]
      assert(#stock >= 4, "a few to choose from")
      for index, puzzle in ipairs(stock) do
        equal(1, (Sudoku.Count(puzzle)), level .. " " .. index)
        equal(GRADES[level], Sudoku.Grade(puzzle), level .. " " .. index)
      end
      local seen = {}
      for seed = 1, 12 do
        local puzzle = Sudoku.Stock(Random.New(seed), level)
        equal(1, (Sudoku.Count(puzzle)))
        equal(GRADES[level], Sudoku.Grade(puzzle), "mixed up it is as hard as it was")
        seen[table.concat(puzzle)] = true
      end
      local different = 0
      for _ in pairs(seen) do
        different = different + 1
      end
      equal(12, different, "and never the same puzzle twice")
    end
  end

  function tests.SudokuSolverCountsSolutionsAndStopsAtTwo()
    local private = loadEngine()
    local Sudoku = private.Sudoku
    local puzzle, solution = Sudoku.Generate(private.Random.New(77), "medium")
    equal(1, (Sudoku.Count(puzzle)))
    equal(table.concat(solution), table.concat(select(2, Sudoku.Count(solution))), "a full grid is its own solution")

    -- Nothing to go on at all: as many as it is asked to count
    local empty = {}
    for cell = 1, 81 do
      empty[cell] = 0
    end
    equal(2, (Sudoku.Count(empty)))
    equal(5, (Sudoku.Count(empty, 5)))
    equal(nil, Sudoku.Grade(empty))

    -- A full grid with squares taken out from the bottom, until there is more than one way to
    -- finish it. How many there are is counted the slow and simple way to compare with
    local function count(grid, from)
      for cell = from, 81 do
        if grid[cell] == 0 then
          local total = 0
          for digit = 1, 9 do
            local fits = true
            for other = 1, 81 do
              fits = fits and (other == cell or not sharesUnit(other, cell) or grid[other] ~= digit)
            end
            if fits then
              grid[cell] = digit
              total = total + count(grid, cell + 1)
            end
          end
          grid[cell] = 0
          return total
        end
      end
      return 1
    end
    local holey, known, gone = { unpack(solution) }, 1, 0
    while known <= 3 do
      holey[81 - gone], gone = 0, gone + 1
      assert(gone < 40, "two whole rows gone leave more than one way")
      local before = known
      known = count({ unpack(holey) }, 1)
      assert(known >= before)
      equal(math.min(known, 2), (Sudoku.Count(holey)), gone .. " squares gone")
      equal(known == 1 and 1 or nil, Sudoku.Grade(holey) and 1, "more than one way is no puzzle")
    end
    equal(known, (Sudoku.Count(holey, 1000)), "every way is counted, and once")
    equal(3, (Sudoku.Count(holey, 3)), "up to as many as were asked for")
    local _, one = Sudoku.Count(holey, 1)
    for cell = 1, 81 do
      assert(holey[cell] == 0 or holey[cell] == one[cell], "a way to finish it leaves what is there")
    end
    equal(1, (Sudoku.Count(one)))

    -- A digit twice in a row can't be finished, and neither can a square nothing is left for
    local twice = { unpack(empty) }
    twice[1], twice[9] = 5, 5
    equal(0, (Sudoku.Count(twice)))
    equal(nil, Sudoku.Grade(twice))
    local stuck = { unpack(empty) }
    for column = 2, 9 do
      stuck[column] = column - 1
    end
    stuck[10] = 9
    equal(0, (Sudoku.Count(stuck)), "the first square can take neither 9 nor anything else")

    -- More to go on never makes a puzzle harder
    local hard = Sudoku.Generate(private.Random.New(5), "expert")
    local grade = Sudoku.Grade(hard)
    local _, answer = Sudoku.Count(hard)
    for cell = 1, 81 do
      if hard[cell] == 0 and cell % 4 == 0 then
        hard[cell] = answer[cell]
        local easier = Sudoku.Grade(hard)
        assert(easier <= grade, "a square more made it harder")
        grade = easier
      end
    end
  end

  function tests.SudokuIsTheSameGameFromTheSameSeed()
    local _, first = sudoku(7, { level = "hard" })
    local game, second, private = sudoku(7, { level = "hard" })
    equal(table.concat(first.grid), table.concat(second.grid))
    equal(table.concat(first.solution), table.concat(second.solution))
    local _, otherSeed = sudoku(8, { level = "hard" })
    local _, otherLevel = sudoku(7, { level = "easy" })
    assert(table.concat(first.grid) ~= table.concat(otherSeed.grid), "another seed, another puzzle")
    assert(table.concat(first.grid) ~= table.concat(otherLevel.grid), "another difficulty, another puzzle")

    -- Put together again, as it is whenever a move is taken back, it is the same puzzle and
    -- none of what was done to the one before
    local cell = emptySquare(second)
    game.apply(second, 1, squareName(cell) .. second.solution[cell])
    local again = game.newState(1, private.Random.New(7), { level = "hard" })
    equal(table.concat(first.grid), table.concat(again.grid))
    equal(0, again.grid[cell])
    equal(again.filled, first.filled)
  end

  function tests.SudokuIsSetUpTheWayItWasAskedFor()
    local game, state, private = sudoku(3)
    equal("medium", state.level, "unless somebody says otherwise")
    equal(true, state.check)
    equal(0, state.mistakes)
    equal(0, state.hints)
    equal(nil, game.result(state))
    equal(1, game.turn(state))
    equal("sudoku_progress", game.progress(state))
    equal(true, game.undo)
    equal("open", game.clock)
    sudokuIsSound(state)

    local Games = private.Games
    equal("level=expert+check=0", Games.EncodeOptions(game, { level = "expert", check = false }))
    equal("hard", Games.DecodeOptions(game, "level=hard").level)
    equal(false, select(2, Games.DecodeOptions(game, "level=silly")))
    equal("sudoku_level_easy", Games.OptionLabel(game.options[1], "easy"))

    local given = {}
    for _, level in ipairs(private.Sudoku.LEVELS) do
      local made = game.newState(1, private.Random.New(11), { level = level, check = false })
      equal(level, made.level)
      equal(false, made.check)
      given[level] = made.filled
      local count = 0
      for cell = 1, 81 do
        count = count + (made.given[cell] and 1 or 0)
        equal(made.given[cell] and made.solution[cell] or 0, made.grid[cell])
      end
      equal(made.filled, count)
    end
    assert(given.easy > given.medium and given.easy > given.hard and given.easy > given.expert, "an easy one comes with the most")
  end

  function tests.SudokuWritesRubsOutAndPencilsIn()
    local game, state = sudoku(4, { level = "easy" })
    local cell = emptySquare(state)
    local name, right = squareName(cell), state.solution[cell]
    local filled = state.filled

    -- A digit that is right
    equal(true, (game.validate(state, 1, name .. right)))
    local event = game.apply(state, 1, name .. right)
    equal(cell, event.cell)
    equal(right, event.digit)
    equal(0, event.was)
    equal(nil, event.wrong)
    equal(right, state.grid[cell])
    equal(filled + 1, state.filled)
    equal(0, state.mistakes)
    equal("invalid_move", select(2, game.validate(state, 1, name .. right)), "it is there already")

    -- One that isn't, written over it
    local wrong = wrongDigit(state, cell)
    event = game.apply(state, 1, name .. wrong)
    equal(true, event.wrong)
    equal(right, event.was)
    equal(wrong, state.grid[cell])
    equal(filled + 1, state.filled, "the square was full before")
    equal(1, state.mistakes)

    -- Rubbed out
    equal("sudoku_filled", select(2, game.validate(state, 1, "n" .. name .. "3")), "no notes in a square that has a digit")
    event = game.apply(state, 1, name .. "0")
    equal(0, event.digit)
    equal(wrong, event.was)
    equal(0, state.grid[cell])
    equal(filled, state.filled)
    equal(1, state.mistakes, "a mistake that was made stays made")
    equal("invalid_move", select(2, game.validate(state, 1, name .. "0")), "nothing there to rub out")

    -- Notes go in and come out again, and rubbing the square out takes them all
    event = game.apply(state, 1, "n" .. name .. "3")
    equal(3, event.note)
    equal(true, event.on)
    equal(true, state.notes[(cell - 1) * 9 + 3])
    game.apply(state, 1, "n" .. name .. "8")
    event = game.apply(state, 1, "n" .. name .. "3")
    equal(false, event.on)
    equal(nil, state.notes[(cell - 1) * 9 + 3])
    equal(filled, state.filled, "a note fills nothing")
    equal(true, (game.validate(state, 1, name .. "0")))
    game.apply(state, 1, name .. "0")
    equal(nil, state.notes[(cell - 1) * 9 + 8])
    game.apply(state, 1, "n" .. name .. "8")
    game.apply(state, 1, name .. right)
    equal(nil, state.notes[(cell - 1) * 9 + 8], "and so does writing a digit into it")
    sudokuIsSound(state)

    -- What the puzzle came with stays, and so does everything that isn't a move
    local given = nil
    for other = 1, 81 do
      given = given or (state.given[other] and other)
    end
    local fixed = squareName(given)
    for _, move in ipairs({ fixed .. "5", fixed .. "0", "n" .. fixed .. "5", "h" .. fixed }) do
      equal("sudoku_fixed", select(2, game.validate(state, 1, move)), move)
    end
    for _, move in ipairs({ "", "5", "55", "5555", "015", "105", "n110", "n11", "h1", "h115", "x115", "11a", "1 15" }) do
      equal("invalid_move", select(2, game.validate(state, 1, move)), "move " .. move)
    end
    equal("not_your_turn", select(2, game.validate(state, 2, name .. "0")))
  end

  function tests.SudokuTidiesTheNotesADigitMakesImpossible()
    for _, check in ipairs({ true, false }) do
      local game, state = sudoku(6, { level = "medium", check = check })
      local cell = emptySquare(state)
      local digit = state.solution[cell]
      -- A square in its row, one in its column, one in its box and one that has nothing to do with it
      local row, column, box = whereIs(cell)
      local near, far = {}, nil
      for other = 1, 81 do
        if other ~= cell and state.grid[other] == 0 then
          local otherRow, otherColumn, otherBox = whereIs(other)
          if otherRow == row then
            near.row = near.row or other
          elseif otherColumn == column then
            near.column = near.column or other
          elseif otherBox == box then
            near.box = near.box or other
          else
            far = far or other
          end
        end
      end
      local pencilled = { far }
      for _, other in pairs(near) do
        pencilled[#pencilled + 1] = other
      end
      for _, other in ipairs(pencilled) do
        game.apply(state, 1, "n" .. squareName(other) .. digit)
        game.apply(state, 1, "n" .. squareName(other) .. (digit % 9 + 1))
      end

      -- A wrong digit that is pointed out leaves the notes alone, it is about to go again
      local wrong = wrongDigit(state, cell)
      for _, other in ipairs(pencilled) do
        game.apply(state, 1, "n" .. squareName(other) .. wrong)
        game.apply(state, 1, "n" .. squareName(other) .. wrong)
      end
      local event = game.apply(state, 1, squareName(cell) .. digit)
      table.sort(event.cleared)
      local expected = {}
      for _, other in pairs(near) do
        expected[#expected + 1] = other
        equal(nil, state.notes[(other - 1) * 9 + digit])
        equal(true, state.notes[(other - 1) * 9 + digit % 9 + 1], "only the notes of that digit")
      end
      table.sort(expected)
      equal(table.concat(expected, ","), table.concat(event.cleared, ","))
      equal(true, state.notes[(far - 1) * 9 + digit], "and only where it matters")

      local other = near.row or near.column or near.box
      local theirs = wrongDigit(state, other)
      local third = nil
      for peer = 1, 81 do
        if not third and peer ~= other and peer ~= cell and sharesUnit(peer, other) and state.grid[peer] == 0 then
          third = peer
        end
      end
      game.apply(state, 1, "n" .. squareName(third) .. theirs)
      event = game.apply(state, 1, squareName(other) .. theirs)
      equal(true, event.wrong)
      equal(not check, event.cleared ~= nil, "a mistake nobody points out tidies up like any digit")
      equal(check or nil, state.notes[(third - 1) * 9 + theirs])
      sudokuIsSound(state)
    end
  end

  function tests.SudokuFillsASquareInWhenAsked()
    local game, state, private = sudoku(9, { level = "hard" })
    local cell = emptySquare(state)
    equal(cell, private.Sudoku.HintFor(state, cell), "the square the player is on")
    local event = game.apply(state, 1, "h" .. squareName(cell))
    equal(true, event.hint)
    equal(state.solution[cell], event.digit)
    equal(state.solution[cell], state.grid[cell])
    equal(1, state.hints)
    equal(0, state.mistakes)
    equal(true, state.hinted[cell])
    for _, move in ipairs({ squareName(cell) .. "0", squareName(cell) .. wrongDigit(state, cell), "h" .. squareName(cell) }) do
      equal("sudoku_fixed", select(2, game.validate(state, 1, move)), "it is there for good")
    end

    -- A wrong digit is something to put right, a right one isn't
    local other = emptySquare(state)
    game.apply(state, 1, squareName(other) .. wrongDigit(state, other))
    equal(other, private.Sudoku.HintFor(state, other))
    equal(true, (game.validate(state, 1, "h" .. squareName(other))))
    game.apply(state, 1, squareName(other) .. state.solution[other])
    equal("invalid_move", select(2, game.validate(state, 1, "h" .. squareName(other))))

    -- With the player on a square that needs nothing it is the one that leaves the least choice
    local best = private.Sudoku.HintFor(state, cell)
    assert(best and state.grid[best] == 0)
    local function choice(square)
      local seen, count = {}, 9
      for peer = 1, 81 do
        local digit = state.grid[peer]
        if peer ~= square and sharesUnit(peer, square) and digit ~= 0 and not seen[digit] then
          seen[digit], count = true, count - 1
        end
      end
      return count
    end
    for square = 1, 81 do
      assert(state.grid[square] ~= 0 or choice(square) >= choice(best), "square " .. square .. " leaves less choice")
    end
    equal(best, private.Sudoku.HintFor(state), "and so it is with the player on none")
    sudokuIsSound(state)
  end

  function tests.SudokuSaysWhatADigitCompletedAndIsWonByTheLast()
    local game, state, private = sudoku(12, { level = "easy" })
    local Sudoku = private.Sudoku
    equal("1,2,3,4,5,6,7,8,9", table.concat(Sudoku.Unit("r1"), ","))
    equal("3,12,21,30,39,48,57,66,75", table.concat(Sudoku.Unit("c3"), ","))
    equal("31,32,33,40,41,42,49,50,51", table.concat(Sudoku.Unit("b5"), ","))

    -- A digit twice in a unit is told on every square that has it
    local cell = emptySquare(state)
    local clash = nil
    for other = 1, 9 do
      local peer = math.floor((cell - 1) / 9) * 9 + other
      clash = clash or (state.given[peer] and peer)
    end
    equal(nil, next(Sudoku.Clashes(state.grid)))
    equal(9, Sudoku.Left(state.grid)[state.grid[clash]] + select(2, table.concat(state.grid):gsub(state.grid[clash], "")))
    game.apply(state, 1, squareName(cell) .. state.grid[clash])
    local clashes = Sudoku.Clashes(state.grid)
    equal(true, clashes[cell])
    equal(true, clashes[clash])
    game.apply(state, 1, squareName(cell) .. "0")
    equal(1, state.mistakes)

    -- Filled in from the top: every row is done by its last square, the columns and boxes
    -- as their last square comes
    local completed, moves = {}, 0
    for square = 1, 81 do
      if state.grid[square] == 0 then
        equal(nil, game.result(state))
        local event = game.apply(state, 1, squareName(square) .. state.solution[square])
        moves = moves + 1
        for _, unit in ipairs(event.units or {}) do
          assert(not completed[unit], unit .. " was done twice")
          completed[unit] = true
          for _, member in ipairs(Sudoku.Unit(unit)) do
            assert(state.grid[member] ~= 0, unit .. " was done before it was full")
          end
        end
        equal(emptySquare(state) == nil or nil, event.won)
      end
    end
    assert(moves > 30)
    for _, kind in ipairs({ "r", "c", "b" }) do
      for index = 1, 9 do
        -- One that came full isn't anything a move did
        local full = true
        for _, member in ipairs(Sudoku.Unit(kind .. index)) do
          full = full and state.given[member] == true
        end
        equal(not full, completed[kind .. index] == true, kind .. index)
      end
    end
    equal(1, game.result(state).winner)
    equal(81, state.filled)
    equal("invalid_move", select(2, game.validate(state, 1, "h11")), "nothing more to do")
    sudokuIsSound(state)

    -- Full but wrong isn't won, and a unit with a wrong digit in it isn't done where that is pointed out
    for _, check in ipairs({ true, false }) do
      local other = game.newState(1, private.Random.New(12), { level = "easy", check = check })
      local last, lastEvent = nil, nil
      for square = 1, 81 do
        if other.grid[square] == 0 then
          last = square
        end
      end
      for square = 1, 81 do
        if other.grid[square] == 0 then
          -- The last one gets the digit of another square of its row: full, with one twice
          local digit = square == last and other.solution[square % 9 == 0 and square - 1 or square + 1] or other.solution[square]
          lastEvent = game.apply(other, 1, squareName(square) .. digit)
        end
      end
      equal(81, other.filled)
      equal(nil, game.result(other))
      equal(nil, lastEvent.won)
      equal(nil, lastEvent.units, "a digit twice completes nothing")
      equal(true, lastEvent.wrong)
      lastEvent = game.apply(other, 1, squareName(last) .. other.solution[last])
      equal(true, lastEvent.won)
      equal(1, game.result(other).winner)
    end
  end

  function tests.SudokuIsPlayedThroughWithoutComingApart()
    for seed = 1, 6 do
      local level = ({ "easy", "medium", "hard", "expert" })[seed % 4 + 1]
      local game, state, private = sudoku(seed * 31, { level = level, check = seed % 2 == 0 })
      local dice = private.Random.New(seed)
      local given = table.concat(state.grid)
      local mistakes, done = 0, 0
      -- Anything at all, anywhere: whatever the rules let through leaves a game that is sound
      for _ = 1, 600 do
        local cell, digit = dice:Roll(81), dice:Roll(9)
        local kind = dice:Roll(10)
        local move = squareName(cell) .. digit
        if kind <= 2 then
          move = "n" .. move
        elseif kind == 3 then
          move = squareName(cell) .. "0"
        elseif kind == 4 and dice:Roll(6) == 1 then
          move = "h" .. squareName(cell)
        end
        if game.validate(state, 1, move) and not game.result(state) then
          local event = game.apply(state, 1, move)
          done = done + 1
          equal(cell, event.cell)
          assert(state.mistakes >= mistakes, "mistakes are never taken back")
          mistakes = state.mistakes
          sudokuIsSound(state)
        end
      end
      assert(done > 200, "most of it should have been allowed")
      for cell = 1, 81 do
        if given:sub(cell, cell) ~= "0" then
          equal(given:sub(cell, cell), tostring(state.grid[cell]), "what it came with is what it comes with")
        end
      end
      -- And however it was left, it can still be finished
      for cell = 1, 81 do
        if not game.result(state) and state.grid[cell] ~= state.solution[cell] then
          game.apply(state, 1, squareName(cell) .. state.solution[cell])
        end
      end
      equal(1, game.result(state).winner)
      sudokuIsSound(state)
    end
  end

  function tests.SudokuKeepsTheBestTimeForEachDifficulty()
    local world = World.New()
    local alice = world:AddPlayer("Alice-Realm")
    local session, Match = alice.session, alice.private.Match

    --- Plays a game to the end
    --- @param level string
    --- @param seconds number How long it takes
    --- @param hint boolean? Have a square filled in on the way
    --- @return table match
    local function solve(level, seconds, hint)
      local match = assert(session:Invite({}, "sudoku", { options = { level = level } }))
      equal(level ~= "medium" and level or nil, match.options and match.options.level)
      session:Spend(match.id, seconds)
      local state = Match.State(match)
      equal(level, state.level)
      for cell = 1, 81 do
        if state.grid[cell] == 0 then
          assert(session:Move(match.id, (hint and "h" or "") .. squareName(cell) .. (hint and "" or state.solution[cell])))
          hint = false
        end
      end
      equal("finished", match.status)
      equal(1, Match.Result(match).winner)
      return match
    end

    equal(nil, session:Best("sudoku", "easy"))
    local first = solve("easy", 90)
    equal(90, session:Best("sudoku", "easy"), "the clock runs from when the game is first looked at")
    equal(true, session:SetBest(first, "easy"))
    solve("easy", 120)
    equal(90, session:Best("sudoku", "easy"), "slower is no better")
    local faster = solve("easy", 45)
    equal(45, session:Best("sudoku", "easy"))
    equal(true, session:SetBest(faster, "easy"))

    -- Every difficulty has its own, and a game with a hint in it is nothing to beat
    equal(nil, session:Best("sudoku", "hard"))
    local helped = solve("hard", 10, true)
    equal(1, Match.State(helped).hints)
    equal(nil, session:Best("sudoku", "hard"))
    solve("hard", 300)
    equal(300, session:Best("sudoku", "hard"))
    equal(45, session:Best("sudoku", "easy"))

    -- A move taken back was never made: the puzzle is the same one, and the mistake is gone
    local match = assert(session:Invite({}, "sudoku"))
    local before = table.concat(Match.State(match).grid)
    local cell = emptySquare(Match.State(match))
    assert(session:Move(match.id, squareName(cell) .. wrongDigit(Match.State(match), cell)))
    equal(1, Match.State(match).mistakes)
    assert(session:Undo(match.id))
    equal(before, table.concat(Match.State(match).grid))
    equal(0, Match.State(match).mistakes)
    equal("sudoku_fixed", select(2, session:Move(match.id, "h" .. squareName(select(2, before:find("[1-9]"))))))
  end

  function tests.WizardSetsUpAGameForOne()
    local world = World.New()
    local alice = world:AddPlayer("Alice-Realm")
    local wizard = openWizard(alice)
    pickGame("sudoku")
    equal(true, wizard.IsOpen(), "there is something to choose first")
    -- and somebody to race it against, or nobody
    equal(true, says("wizard_who_race"))
    equal("sudoku_level_medium", select(2, ruleChoices("sudoku_option_level")))
    equal("option_on", select(2, ruleChoices("sudoku_option_check")))
    equal(false, says("wizard_seat"))
    equal(false, says("wizard_turn"))

    ruleChoices("sudoku_option_level")["sudoku_level_expert"]:Fire("OnClick")
    equal("sudoku_level_expert", select(2, ruleChoices("sudoku_option_level")))
    local play = Client.Button("wizard_play_alone")
    equal(true, play.enabled)
    play:Fire("OnClick")
    equal(false, wizard.IsOpen())
    local started
    for _, match in pairs(alice.matches) do
      started = match
    end
    equal("sudoku", started.game)
    equal("active", started.status)
    equal("expert", started.options.level)
    equal(nil, started.options.check)
    equal(0, #world.queue, "nothing is sent to anybody")

    -- The next one starts out set the same way, and a game against someone is still sent
    wizard.Open()
    pickGame("sudoku")
    equal("sudoku_level_expert", select(2, ruleChoices("sudoku_option_level")))
    Client.Button("Back"):Fire("OnClick")
    pickGame("chess")
    equal(true, says("wizard_who"))
    equal("wizard_send", Client.Button("wizard_send").text)
  end
end

-----------------------------
-- Sudoku on screen
-----------------------------

do
  --- Loads the grid and its keys on their own, over a fresh fake client
  --- @return table NumberGrid
  local function loadNumberGrid()
    Client.Install()
    ForeverGames = { db = { profile = { sound = true } } }
    local private = { L = setmetatable({}, {
      __index = function(_, key)
        return key
      end,
    }) }
    for _, file in ipairs({ "GUI/Widgets.lua", "GUI/NumberGrid.lua" }) do
      assert(loadfile(file))(ADDON_NAME, private)
    end
    return private.NumberGrid
  end

  --- Moves the cursor onto a square of a grid
  --- @param grid table
  --- @param square number
  local function pointAtSquare(grid, square)
    local x, y = grid:CenterOf(square)
    -- The cursor is counted up from the bottom of the screen, where every widget sits
    Client.cursor = { x, grid.frame.height - y }
  end

  --- @param grid table
  --- @param square number
  --- @param button string?
  local function clickOnGrid(grid, square, button)
    pointAtSquare(grid, square)
    grid.frame:Fire("OnMouseDown", button or "LeftButton")
    grid.frame:Fire("OnMouseUp", button or "LeftButton")
  end

  --- Lets time pass for whatever is on the move in a grid
  --- @param grid table
  --- @param seconds number
  local function passGridTime(grid, seconds)
    for _ = 1, math.floor(seconds / 0.02 + 0.5) do
      grid.motion:Fire("OnUpdate", 0.02)
    end
  end

  function tests.NumberGridDrawsFiguresNotesAndWhatIsPointedOut()
    local NumberGrid = loadNumberGrid()
    local grid = NumberGrid.New(UIParent, { columns = 9, rows = 9, boxColumns = 3, boxRows = 3 })
    equal(81, #grid.squares)
    grid:SetSize(400)
    assert(grid.cell >= 40 and grid.cell == math.floor(grid.cell), "whole squares that make use of the room, got " .. grid.cell)
    assert(grid.frame.width <= 400 and grid.frame.width > 400 - 9, "as large as fits, got " .. grid.frame.width)
    equal(grid.frame.width, grid.frame.height)
    assert(grid.thick > grid.thin, "the lines between boxes are the heavy ones")

    -- Squares lie in reading order, with more room between two boxes than between two squares
    local first, second, fourth, tenth = grid.squares[1], grid.squares[2], grid.squares[4], grid.squares[10]
    equal(grid.thick, first.x)
    equal(grid.thick, first.y)
    equal(first.x + grid.cell + grid.thin, second.x)
    equal(grid.squares[3].x + grid.cell + grid.thick, fourth.x)
    equal(first.y + grid.cell + grid.thin, tenth.y)
    equal(first.x, tenth.x)
    local last = grid.squares[81]
    equal(grid.frame.width, last.x + grid.cell + grid.thick)
    equal(1, grid:SquareAt(first.x, first.y))
    equal(81, grid:SquareAt(last.x + grid.cell - 1, last.y + grid.cell - 1))
    equal(nil, grid:SquareAt(first.x + grid.cell, first.y), "a line is no square")
    equal(nil, grid:SquareAt(-1, 5))
    equal(nil, grid:SquareAt(grid.frame.width + 1, 5))

    -- A grid that isn't square, without boxes
    local strip = NumberGrid.New(UIParent, { columns = 4, rows = 2 })
    strip:SetSize(200, 300)
    assert(strip.frame.width <= 200 and strip.frame.height < strip.frame.width)
    equal(5, strip:SquareAt(strip.squares[5].x, strip.squares[5].y))

    -- Figures in their colours. What didn't change isn't touched again
    local blue = { 0.4, 0.7, 1 }
    grid:SetFigures({ [1] = 5, [2] = "7" }, { [2] = blue })
    equal("5", first.figure.text)
    equal("7", second.figure.text)
    local writes = 0
    function first.figure:SetText()
      writes = writes + 1
    end
    function second.figure:SetTextColor()
      writes = writes + 1
    end
    grid:SetFigures({ [1] = 5, [2] = "7" }, { [2] = blue })
    equal(0, writes)
    grid:SetFigures({ [2] = "7" }, { [2] = blue })
    equal(1, writes, "a square that was emptied")

    -- Notes sit where their number puts them, three to a row, and are made as they are needed
    grid:SetNotes({ [3] = "159" })
    local notes = grid.squares[3].notes
    equal("1", notes[1].text)
    equal(true, notes[5]:IsShown())
    equal(nil, notes[2])
    local third = grid.squares[3]
    local function at(note)
      return note.anchors[1][4] - third.x, -note.anchors[1][5] - third.y
    end
    local oneX, oneY = at(notes[1])
    local fiveX, fiveY = at(notes[5])
    local nineX, nineY = at(notes[9])
    assert(oneX < fiveX and fiveX < nineX and oneY < fiveY and fiveY < nineY, "from the top left corner to the bottom right")
    assert(oneX > 0 and oneY > 0 and nineX < grid.cell and nineY < grid.cell, "inside their square")
    grid:SetNotes({ [3] = "19" }, "9")
    equal(false, notes[5]:IsShown())
    equal(true, notes[9]:IsShown())
    grid:SetNotes({})
    equal(false, notes[1]:IsShown())

    -- Washes, and the frame around the square the player is on
    local red, gold = { 1, 0, 0, 0.5 }, { 1, 0.8, 0, 0.3 }
    grid:SetTints({ [1] = red, [81] = gold })
    equal(true, first.tint:IsShown())
    equal(true, last.tint:IsShown())
    equal(false, second.tint:IsShown())
    grid:SetTints({ [81] = gold })
    equal(false, first.tint:IsShown())
    equal(false, grid.cursorEdges[1]:IsShown())
    grid:Select(10)
    equal(10, grid.selected)
    equal(true, grid.cursorEdges[1]:IsShown())
    equal(tenth.x, grid.cursorEdges[1].anchors[1][4])
    equal(-tenth.y, grid.cursorEdges[1].anchors[1][5])
    grid:Select(nil)
    equal(false, grid.cursorEdges[4]:IsShown())

    -- Resized, everything is where it belongs again
    grid:Select(10)
    grid:SetSize(820)
    assert(grid.cell > 80)
    equal(grid.squares[10].x, grid.cursorEdges[1].anchors[1][4])
    equal(grid.cell, grid.squares[10].paper.width)
  end

  function tests.NumberGridTellsClicksAndMovesWhatItIsAskedTo()
    local NumberGrid = loadNumberGrid()
    local grid = NumberGrid.New(UIParent, { columns = 9, rows = 9, boxColumns = 3, boxRows = 3 })
    grid:SetSize(450)
    local clicked, hovered = {}, {}
    grid:SetInput({
      onClick = function(square, button)
        clicked[#clicked + 1] = square .. button
      end,
      onHover = function(square)
        hovered[#hovered + 1] = square or "none"
      end,
    })

    clickOnGrid(grid, 1)
    clickOnGrid(grid, 81, "RightButton")
    pointAtSquare(grid, 41)
    grid.frame:Fire("OnMouseDown", "LeftButton")
    equal(true, grid.press:IsShown(), "a square gives while it is pressed")
    grid.frame:Fire("OnMouseUp", "LeftButton")
    equal(false, grid.press:IsShown())
    equal("1LeftButton,81RightButton,41LeftButton", table.concat(clicked, ","))

    -- The square under the cursor is lit, and the game is told once
    grid.frame:Fire("OnUpdate", 0.02)
    grid.frame:Fire("OnUpdate", 0.02)
    equal(true, grid.hover:IsShown())
    pointAtSquare(grid, 42)
    grid.frame:Fire("OnUpdate", 0.02)
    Client.cursor = { 2000, 2000 }
    grid.frame:Fire("OnUpdate", 0.02)
    equal(false, grid.hover:IsShown())
    equal("41,42,none", table.concat(hovered, ","))

    -- A grid that is off takes nothing
    pointAtSquare(grid, 5)
    grid.frame:Fire("OnUpdate", 0.02)
    grid:SetEnabled(false)
    equal(false, grid.hover:IsShown())
    clickOnGrid(grid, 5)
    equal(3, #clicked)
    grid:SetEnabled(true)

    -- A figure pops into its square: small at first, a little too large on the way, then as it is
    grid:SetFigures({ [5] = 3 })
    equal(false, grid:Busy())
    grid:Pop(5)
    equal(true, grid:Busy())
    local square = grid.squares[5]
    local smallest, largest = 1, 0
    for _ = 1, 30 do
      grid.motion:Fire("OnUpdate", 0.02)
      smallest, largest = math.min(smallest, square.scale), math.max(largest, square.scale)
    end
    assert(smallest < 0.6 and largest > 1, "from " .. smallest .. " past its size to " .. largest)
    equal(1, square.scale)
    equal(1, square.holder.scale)
    equal(false, grid:Busy())

    -- A square shakes its head and comes to rest where it was
    grid:Shake(5)
    local furthest = 0
    for _ = 1, 40 do
      grid.motion:Fire("OnUpdate", 0.02)
      furthest = math.max(furthest, math.abs(square.dx))
    end
    assert(furthest > 2, "it should be seen to move, got " .. furthest)
    assert(math.abs(square.dx) < 0.0001)
    equal(false, grid:Busy())

    -- Squares light up one after the other
    local glow = { 0.3, 0.9, 0.4, 0.5 }
    for index = 1, 9 do
      grid:Flash(index, glow, (index - 1) * 0.1)
    end
    equal(nil, grid.squares[9].flash and grid.squares[9].flash:IsShown() or nil, "not yet")
    passGridTime(grid, 0.2)
    equal(true, grid.squares[1].flash:IsShown())
    equal(false, grid.squares[9].flash:IsShown())
    assert(grid.squares[1].scale > 1, "its figure swells with it")
    passGridTime(grid, 0.5)
    equal(false, grid.squares[1].flash:IsShown())
    equal(true, grid:Busy())
    -- Settled, everything is as it ends up at once
    grid:Settle()
    equal(false, grid:Busy())
    for index = 1, 9 do
      equal(false, grid.squares[index].flash:IsShown())
      assert(math.abs(grid.squares[index].scale - 1) < 0.0001)
    end
    -- And hidden, nothing is left on its way
    grid:Pop(7)
    grid.motion:Fire("OnHide")
    equal(false, grid:Busy())
    equal(1, grid.squares[7].scale)
  end

  function tests.NumberPadLaysItsKeysOutAndSaysHowTheyStand()
    local NumberGrid = loadNumberGrid()
    local pressed = {}
    local pad = NumberGrid.Pad(UIParent, 9, { "notes", "erase" }, function(figure)
      pressed[#pressed + 1] = figure
    end, function(tool)
      pressed[#pressed + 1] = tool
    end)
    equal(9, #pad.keys)
    equal("7", pad.keys[7].label.text)

    -- Three to a row with the tools under them, or all in one row
    local width, height = pad:Layout(3, 40, 4)
    equal(3 * 40 + 2 * 4, width)
    equal(4 * 40 + 3 * 4, height)
    equal(width, pad.frame.width)
    equal(44, pad.keys[5].anchors[1][4])
    equal(-44, pad.keys[5].anchors[1][5])
    equal(-3 * 44, pad.tools.erase.anchors[1][5])
    equal(62, pad.tools.notes.width, "the tools share the width")
    equal(66, pad.tools.erase.anchors[1][4])
    width, height = pad:Layout(9, 30, 2)
    equal(9 * 30 + 8 * 2, width)
    equal(62, height)
    equal(0, pad.keys[9].anchors[1][5])

    pad.keys[4]:Fire("OnClick")
    pad.tools.notes:Fire("OnClick")
    equal("4,notes", table.concat(pressed, ","))

    -- A key gives while it is held, says something small about itself, and can be on or dimmed
    local key = pad.keys[4]
    key:Fire("OnMouseDown")
    equal(true, key.press:IsShown())
    key:Fire("OnMouseUp")
    equal(false, key.press:IsShown())
    key:Set(4, 6)
    equal("6", key.caption.text)
    key:Set(4)
    equal("", key.caption.text)
    key:SetDim(true)
    equal(0.35, key.alpha)
    key:Fire("OnClick")
    equal(3, #pressed, "a dimmed key still says it was pressed")
    key:SetDim(false)
    equal(1, key.alpha)
    pad.tools.notes:SetOn(true)
    equal(true, pad.tools.notes.on)
  end

  --- Opens the window on a new game of sudoku
  --- @param options table? How it is set up
  --- @return table player, string id, table MainFrame
  local function sudokuOnScreen(options)
    local world = World.New()
    world.seed = 1
    local player = world:AddPlayer("Alice-Realm")
    player.session.env.records = {}
    local MainFrame = openWindow(player)
    function StaticPopup_Show(which, _, _, data)
      StaticPopupDialogs[which].OnAccept(nil, data)
    end
    local match = assert(player.session:Invite({}, "sudoku", { options = options or { level = "easy" } }))
    MainFrame.Open(match.id)
    return player, match.id, MainFrame
  end

  --- The grid of the game on screen
  --- @return table grid
  local function shownGrid()
    local found = Client.Find(function(widget)
      return widget.numberGrid ~= nil and widget:IsVisible()
    end)
    equal(1, #found, "grids on screen")
    return found[1].numberGrid
  end

  --- A key of the pad on screen, by what it says
  --- @param text string|number
  --- @return table
  local function padKey(text)
    local found = Client.Find(function(widget)
      local isKey = widget.kind == "Button" and widget.label ~= nil and widget.caption ~= nil
      return isKey and widget.label.text == tostring(text) and widget:IsVisible()
    end)
    equal(1, #found, "keys saying " .. text)
    return found[1]
  end

  --- What one of the boxes over the grid says
  --- @param title string What it counts
  --- @return string
  local function statSays(title)
    local found = Client.Find(function(widget)
      return widget.caption ~= nil and widget.value ~= nil and widget.caption.text == title and widget:IsVisible()
    end)
    equal(1, #found, "boxes that count " .. title)
    return found[1].value.text
  end

  --- Presses a key of the keyboard with the cursor over the game
  --- @param key string
  --- @return boolean used Whether the game kept it
  local function typeKey(key)
    local found = Client.Find(function(widget)
      return widget.scripts.OnKeyDown ~= nil and widget:IsVisible()
    end)
    equal(1, #found, "frames that take keys")
    found[1]:Fire("OnKeyDown", key)
    return found[1].propagates == false
  end

  --- Lets time pass for everything on the stage of the game on screen
  --- @param seconds number
  local function passStageTime(seconds)
    local stage = shownGrid().frame.parent
    local moving = Client.Find(function(widget)
      local parent = widget.parent
      while parent and parent ~= stage do
        parent = parent.parent
      end
      return parent == stage and widget.scripts.OnUpdate ~= nil
    end)
    for _ = 1, math.floor(seconds / 0.02 + 0.5) do
      for _, widget in ipairs(moving) do
        widget:Fire("OnUpdate", 0.02)
      end
    end
  end

  --- @param cell number
  --- @return string How moves name a square
  local function squareName(cell)
    return (math.floor((cell - 1) / 9) + 1) .. ((cell - 1) % 9 + 1)
  end

  --- @param state table
  --- @param skip number? How many to pass over
  --- @return number cell A square that has nothing in it
  local function emptySquare(state, skip)
    skip = skip or 0
    for cell = 1, 81 do
      if state.grid[cell] == 0 then
        if skip == 0 then
          return cell
        end
        skip = skip - 1
      end
    end
    error("no empty square left")
  end

  function tests.WindowShowsASudoku()
    local player, id = sudokuOnScreen()
    local state = player.private.Match.State(player.matches[id])
    local grid = shownGrid()

    equal(true, says("game_sudoku"))
    equal(false, says("status_your_turn"))
    equal(true, says("sudoku_progress"))
    equal(false, Client.Button("undo").enabled, "nothing to take back yet")
    equal("sudoku_level_easy", statSays("sudoku_option_level"))
    equal("0:00", statSays("stat_time"))
    equal("0", statSays("sudoku_mistakes"))
    equal("stat_none", statSays("stat_best"), "no best time yet")
    equal(true, says("sudoku_notes"))
    equal(true, says("sudoku_erase"))
    equal(true, says("sudoku_hint"))

    -- What the puzzle came with is written, the rest is empty, and nothing is on the move
    local given = nil
    for cell = 1, 81 do
      equal(state.grid[cell] ~= 0 and tostring(state.grid[cell]) or "", grid.squares[cell].figure.text or "")
      given = given or (state.given[cell] and cell)
    end
    equal(false, grid:Busy())
    equal(nil, grid.selected)
    equal(false, grid.squares[given].tint:IsShown())

    -- The keys say how many of each digit are still to be written
    local left = player.private.Sudoku.Left(state.grid)
    for digit = 1, 9 do
      local key = padKey(digit)
      equal(left[digit] > 0 and tostring(left[digit]) or "", key.caption.text)
      equal(left[digit] <= 0, key.dim)
    end
    equal(false, padKey("sudoku_notes").on)
    equal("option_off", padKey("sudoku_notes").caption.text)

    -- The clock runs while the game is looked at
    ForeverGamesFrame.detail:Fire("OnUpdate", 61)
    passStageTime(0.02)
    equal("1:01", statSays("stat_time"))
  end

  function tests.WindowPlaysSudoku()
    local player, id, MainFrame = sudokuOnScreen()
    local Match = player.private.Match
    local match = player.matches[id]
    local state = Match.State(match)
    local grid = shownGrid()
    local cell = emptySquare(state)
    local right, wrong = state.solution[cell], state.solution[cell] % 9 + 1

    -- Nothing can be written before a square is picked: the keys say no
    padKey(right):Fire("OnClick")
    equal(true, typeKey(tostring(right)))
    equal("", logOf(player, id))
    equal("IG_MAINMENU_OPTION_CHECKBOX_OFF", Client.sounds[#Client.sounds])

    -- Clicking a square puts the player on it: it, its row, its column and its box are pointed out
    clickOnGrid(grid, cell)
    equal(cell, grid.selected)
    equal(true, grid.cursorEdges[1]:IsShown())
    local row, column = math.floor((cell - 1) / 9), (cell - 1) % 9
    local washed = 0
    for other = 1, 81 do
      local otherRow, otherColumn = math.floor((other - 1) / 9), (other - 1) % 9
      local sameBox = math.floor(otherRow / 3) == math.floor(row / 3) and math.floor(otherColumn / 3) == math.floor(column / 3)
      equal(otherRow == row or otherColumn == column or sameBox, grid.squares[other].tint:IsShown(), "square " .. other)
      washed = washed + (grid.squares[other].tint:IsShown() and 1 or 0)
    end
    equal(21, washed)
    assert(grid.tints[cell] ~= grid.tints[cell % 9 == 0 and cell - 1 or cell + 1], "the square itself stands out from the rest")

    -- A wrong digit pops in, shakes its head, turns red and is counted
    equal(true, typeKey(tostring(wrong)))
    equal(squareName(cell) .. wrong, logOf(player, id))
    state = Match.State(match)
    equal(tostring(wrong), grid.squares[cell].figure.text)
    equal(true, grid:Busy())
    local shook = 0
    for _ = 1, 40 do
      grid.motion:Fire("OnUpdate", 0.02)
      shook = math.max(shook, math.abs(grid.squares[cell].dx))
    end
    assert(shook > 1, "a wrong digit should shake")
    equal(false, grid:Busy())
    equal(1, grid.squares[cell].scale)
    equal("IG_QUEST_LOG_ABANDON_QUEST", Client.sounds[#Client.sounds])
    equal("1", statSays("sudoku_mistakes"))
    local wrongInk = grid.inks[cell]
    equal(true, Client.Button("undo").enabled)

    -- Every square that holds the same digit is pointed out with it, and one that clashes in red
    local sameTint, clashTint, clashes = nil, nil, player.private.Sudoku.Clashes(state.grid)
    for other = 1, 81 do
      if other ~= cell and state.grid[other] == wrong then
        assert(grid.squares[other].tint:IsShown(), "square " .. other .. " holds the same digit")
        if clashes[other] then
          clashTint = grid.tints[other]
        else
          sameTint = grid.tints[other]
        end
      end
    end
    assert(sameTint or clashTint, "the digit is somewhere else in the puzzle")
    assert(sameTint ~= clashTint)

    -- Backspace rubs it out, the right digit goes in from the pad, the same key takes it out again
    equal(true, typeKey("BACKSPACE"))
    equal("", grid.squares[cell].figure.text or "")
    equal("cardSlide", Client.sounds[#Client.sounds])
    equal(false, grid:Busy(), "nothing to show about a square rubbed out")
    equal(true, typeKey("DELETE"), "nothing left to rub out, which the square says")
    equal(true, grid:Busy())
    passGridTime(grid, 1)
    equal(2, #match.log)
    local before = tonumber(padKey(right).caption.text)
    padKey(right):Fire("OnClick")
    equal(squareName(cell) .. right, match.log[3])
    equal("cardPlace", Client.sounds[#Client.sounds])
    equal(before - 1, tonumber(padKey(right).caption.text) or 0)
    assert(grid.inks[cell] ~= wrongInk, "a right digit isn't red")
    local givenInk = nil
    for other = 1, 81 do
      givenInk = givenInk or (state.given[other] and grid.inks[other])
    end
    assert(grid.inks[cell] ~= givenInk, "and is told apart from what the puzzle came with")
    passGridTime(grid, 1)
    padKey(right):Fire("OnClick")
    equal(squareName(cell) .. "0", match.log[4])
    equal(true, typeKey("NUMPAD" .. right), "the number pad of the keyboard writes too")
    equal(squareName(cell) .. right, match.log[5])
    passGridTime(grid, 1)

    -- The arrow keys move from square to square, and around the edges
    clickOnGrid(grid, 1)
    equal(true, typeKey("LEFT"))
    equal(9, grid.selected)
    typeKey("UP")
    equal(81, grid.selected)
    typeKey("RIGHT")
    equal(73, grid.selected)
    typeKey("DOWN")
    equal(1, grid.selected)
    typeKey("DOWN")
    typeKey("RIGHT")
    equal(11, grid.selected)
    equal(false, typeKey("W"), "any other key is the game client's")
    equal(false, typeKey("ESCAPE"))
    Client.over = false
    equal(false, typeKey("LEFT"), "and so is every key while the cursor is somewhere else")
    equal(11, grid.selected)
    Client.over = true
    -- A right click and the player is on no square, an arrow starts from the middle
    clickOnGrid(grid, 20, "RightButton")
    equal(nil, grid.selected)
    typeKey("LEFT")
    equal(41, grid.selected)

    -- What the puzzle came with can't be written over: the square shakes its head
    local given = nil
    for other = 1, 81 do
      given = given or (state.given[other] and other)
    end
    clickOnGrid(grid, given)
    local moves = #match.log
    typeKey(tostring(state.solution[given] % 9 + 1))
    typeKey("BACKSPACE")
    padKey("sudoku_erase"):Fire("OnClick")
    equal(moves, #match.log)
    equal(true, grid:Busy())
    passGridTime(grid, 1)
    equal(0, #ForeverGames.printed, "what the game wouldn't allow was never asked of it")

    -- Notes: a key turns pencilling on and says so, digits are pencilled in and out again
    local other = emptySquare(Match.State(match))
    clickOnGrid(grid, other)
    equal(true, typeKey("N"))
    equal(true, padKey("sudoku_notes").on)
    equal("option_on", padKey("sudoku_notes").caption.text)
    typeKey("2")
    typeKey("NUMPAD7")
    padKey(5):Fire("OnClick")
    equal("n" .. squareName(other) .. "5", match.log[#match.log])
    local notes = grid.squares[other].notes
    equal(true, notes[2]:IsShown())
    equal(true, notes[5]:IsShown())
    equal(true, notes[7]:IsShown())
    equal("", grid.squares[other].figure.text or "")
    typeKey("2")
    equal(false, notes[2]:IsShown())
    equal(false, grid:Busy())
    -- Space turns it off again, and now a digit is written
    equal(true, typeKey("SPACE"))
    equal(false, padKey("sudoku_notes").on)
    padKey("sudoku_notes"):Fire("OnClick")
    equal(true, padKey("sudoku_notes").on)
    padKey("sudoku_notes"):Fire("OnClick")
    typeKey(tostring(Match.State(match).solution[other]))
    equal(false, notes[5]:IsShown(), "the notes make way for the digit")
    equal(tostring(Match.State(match).solution[other]), grid.squares[other].figure.text)
    passGridTime(grid, 1)

    -- Undo takes the digit back, puts the player on its square and brings the notes back
    clickOnGrid(grid, 1)
    Client.Button("undo"):Fire("OnClick")
    equal(other, grid.selected)
    equal("", grid.squares[other].figure.text or "")
    equal(true, notes[5]:IsShown())
    equal(true, grid:Busy(), "the square lights up to say what was taken back")
    passGridTime(grid, 1)
    equal(false, grid:Busy())

    -- A hint fills in the square the player is on, for good
    moves = #match.log
    padKey("sudoku_hint"):Fire("OnClick")
    equal("h" .. squareName(other), match.log[moves + 1])
    equal(tostring(Match.State(match).solution[other]), grid.squares[other].figure.text)
    assert(grid.inks[other] ~= grid.inks[cell] and grid.inks[other] ~= givenInk, "and shows it was")
    typeKey("BACKSPACE")
    equal(moves + 1, #match.log)
    passGridTime(grid, 1)

    -- Looked at again, nothing moves and the player is where they were
    ForeverGamesFrame:Hide()
    ForeverGamesFrame:Show()
    equal(other, shownGrid().selected)
    equal(false, grid:Busy())
    MainFrame.Refresh()
    equal(false, grid:Busy(), "being asked to show the same again starts nothing")
  end

  function tests.WindowCelebratesASudokuThatIsSolved()
    local player, id, MainFrame = sudokuOnScreen()
    local Match = player.private.Match
    local match = player.matches[id]
    local grid = shownGrid()
    ForeverGamesFrame.detail:Fire("OnUpdate", 125)

    -- Solved the way a player would: a click on the square and a key for the digit
    local state = Match.State(match)
    local swept, sounded = false, false
    local lastCell = nil
    for cell = 1, 81 do
      if state.grid[cell] == 0 then
        lastCell = cell
        clickOnGrid(grid, cell)
        equal(true, typeKey(tostring(state.solution[cell])))
        local event = Match.Events(match)[#match.log]
        if event.units and not event.won then
          -- A row, column or box that is done lights up from the square that finished it
          local far = player.private.Sudoku.Unit(event.units[1])
          far = far[1] == cell and far[9] or far[1]
          passGridTime(grid, 0.06)
          assert(grid.squares[cell].flash:IsShown(), "the square that finished it should be lit")
          equal(false, grid.squares[far].flash ~= nil and grid.squares[far].flash:IsShown(), "before the far end of it is")
          swept = true
          sounded = sounded or Client.sounds[#Client.sounds] == "IG_QUEST_LIST_COMPLETE"
        end
        if match.status == "active" then
          grid:Settle()
        end
        state = Match.State(match)
      end
    end
    equal(true, swept)
    equal(true, sounded)
    equal("finished", match.status)
    equal(1, Match.Result(match).winner)
    equal(true, says("status_won_with"))

    -- A wave goes over the grid, paper rains, and the words say how long it took
    equal("UI_EPICLOOT_TOAST", Client.sounds[#Client.sounds])
    equal(true, grid:Busy())
    equal(false, says("sudoku_solved"), "the words wait for the wave")
    passStageTime(0.3)
    assert(grid.squares[1].flash:IsShown() or grid.squares[2].flash:IsShown(), "the wave starts in the top left corner")
    -- And hasn't got to the far corner yet. A square the last digit had nothing to do with
    local far = nil
    for cell = 81, 60, -1 do
      local row, column = math.floor((cell - 1) / 9), (cell - 1) % 9
      local lastRow, lastColumn = math.floor((lastCell - 1) / 9), (lastCell - 1) % 9
      local sameBox = math.floor(row / 3) == math.floor(lastRow / 3) and math.floor(column / 3) == math.floor(lastColumn / 3)
      if not far and row ~= lastRow and column ~= lastColumn and not sameBox and row + column >= 12 then
        far = cell
      end
    end
    equal(false, grid.squares[far].flash ~= nil and grid.squares[far].flash:IsShown())
    passStageTime(0.5)
    equal(true, grid.squares[far].flash:IsShown(), "now it has")
    passStageTime(0.9)
    equal(true, says("sudoku_solved"))
    equal(true, says("sudoku_time_best"), "a first time is a best time")
    equal("2:05", statSays("stat_best"), "the best time is on show")
    equal("2:05", statSays("stat_time"))
    passStageTime(6)
    equal(false, grid:Busy())
    equal(true, says("sudoku_solved"), "the words stay")
    for cell = 1, 81 do
      equal(tostring(state.solution[cell]), grid.squares[cell].figure.text)
      equal(1, grid.squares[cell].scale)
      equal(false, grid.squares[cell].flash ~= nil and grid.squares[cell].flash:IsShown())
    end

    -- Nothing can be done to it any more
    local moves = #match.log
    clickOnGrid(grid, 5)
    equal(nil, grid.selected)
    equal(false, typeKey("5"))
    equal(false, typeKey("LEFT"))
    padKey(5):Fire("OnClick")
    padKey("sudoku_hint"):Fire("OnClick")
    padKey("sudoku_notes"):Fire("OnClick")
    equal(false, padKey("sudoku_notes").on)
    equal(true, padKey(5).dim)
    equal(moves, #match.log)
    equal(0, #Client.Find(function(widget)
      return widget.kind == "Button" and widget.text == "undo" and widget:IsVisible()
    end))

    -- Another game: the words are gone, and it is a puzzle of the same difficulty
    Client.Button("play_again"):Fire("OnClick")
    equal(2, #player.session:List())
    equal(false, MainFrame.IsViewing(id))
    equal(false, says("sudoku_solved"))
    equal("sudoku_level_easy", statSays("sudoku_option_level"))
    equal("0:00", statSays("stat_time"))
    equal("2:05", statSays("stat_best"), "with the time to beat")
    equal(false, shownGrid():Busy())
    -- And back at the one that is solved they are there at once
    MainFrame.Open(id)
    equal(true, says("sudoku_solved"))
    equal(true, says("sudoku_time_best"))
    equal(false, shownGrid():Busy())
    passStageTime(0.1)
    equal(true, says("sudoku_solved"))

    -- A game with a hint in it says so instead, and is no time to beat
    local hinted = assert(player.session:Invite({}, "sudoku", { options = { level = "easy" } }))
    MainFrame.Open(hinted.id)
    equal(false, says("sudoku_solved"))
    padKey("sudoku_hint"):Fire("OnClick")
    equal(1, #hinted.log, "with the player on no square it is the one that was closest")
    equal(Match.Events(hinted)[1].cell, shownGrid().selected)
    state = Match.State(hinted)
    for cell = 1, 81 do
      if state.grid[cell] == 0 then
        clickOnGrid(grid, cell)
        typeKey(tostring(state.solution[cell]))
      end
    end
    equal("finished", hinted.status)
    passStageTime(3)
    equal(true, says("sudoku_time_hints"))
    equal(false, says("sudoku_time_best"))
    equal(125, player.session:Best("sudoku", "easy"))
  end

  function tests.WindowFitsSudokuIntoTheRoomItHas()
    sudokuOnScreen()
    local grid = shownGrid()
    local stage = grid.frame.parent
    local pad = padKey(1).parent

    --- Where a widget is on the stage: left, top, right, bottom, counted from its top left corner
    local function box(widget)
      local anchor = widget.anchors[1]
      equal(stage, anchor[2])
      return anchor[4], -anchor[5], anchor[4] + widget.width, -anchor[5] + widget.height
    end
    --- Everything is on the stage, nothing lies over anything else, and it is in the middle
    --- @return boolean beside Whether the pad is next to the grid
    local function fits()
      local left, top, right, bottom = box(grid.frame)
      local padLeft, padTop, padRight, padBottom = box(pad)
      for _, edge in ipairs({ left, top, padLeft, padTop }) do
        assert(edge >= 0 and edge == math.floor(edge), "on the stage and on a whole unit, got " .. edge)
      end
      assert(right <= stage.width and padRight <= stage.width, "too wide for " .. stage.width)
      assert(bottom <= stage.height and padBottom <= stage.height, "too high for " .. stage.height)
      local beside = padLeft >= right
      assert(beside or padTop >= bottom, "the keys lie over the grid")
      local stats = Client.Find(function(widget)
        return widget.caption ~= nil and widget.value ~= nil and widget.parent == stage and widget:IsVisible()
      end)
      equal(4, #stats)
      local last = nil
      for _, stat in ipairs(stats) do
        local statLeft, statTop, statRight, statBottom = box(stat)
        assert(statLeft >= 0 and statRight <= stage.width and statTop >= 0, "the boxes are on the stage")
        assert(statBottom <= top, "and over the grid")
        assert(not last or statLeft >= last, "next to each other")
        last = statRight
      end
      local farRight = math.max(right, padRight)
      assert(math.abs(left - (stage.width - farRight)) <= 1, "as much room on the left as on the right")
      for digit = 1, 9 do
        assert(padKey(digit).width >= 20, "keys big enough to hit")
      end
      return beside
    end

    equal(true, fits(), "the window as it comes is wider than high")
    local usual = grid.cell
    ForeverGamesFrame:SetSize(1500, 1100)
    equal(true, fits())
    assert(grid.cell > usual * 1.3, "a bigger window should mean a bigger grid, got " .. grid.cell .. " from " .. usual)
    equal(false, grid:Busy(), "which is simply there")
    ForeverGamesFrame:SetSize(764, 560)
    fits()
    assert(grid.cell >= 26, "squares should stay usable in the smallest window, got " .. grid.cell)
    -- Higher than wide, the keys go under the grid
    ForeverGamesFrame:SetSize(764, 1100)
    equal(false, fits())
    assert(grid.frame.width > stage.width * 0.8, "and the grid gets the width")
  end

  function tests.SudokuFitsAnyStage()
    local world = World.New()
    local player = world:AddPlayer("Alice-Realm")
    openWindow(player)
    local stage = CreateFrame("Frame", nil, UIParent)
    local view = player.private.Games.Get("sudoku").createView(stage)
    for _, size in ipairs({ { 480, 380 }, { 380, 480 }, { 640, 640 }, { 2400, 1300 }, { 500, 1600 } }) do
      stage:SetSize(size[1], size[2])
      view:Layout(size[1], size[2])
      local grid, pad = view.grid.frame, view.pad.frame
      local left, top = grid.anchors[1][4], -grid.anchors[1][5]
      local padLeft, padTop = pad.anchors[1][4], -pad.anchors[1][5]
      local label = size[1] .. "x" .. size[2]
      assert(left >= 0 and top >= 46, "the grid is off a stage of " .. label)
      assert(left + grid.width <= size[1] and top + grid.height <= size[2], "the grid is off a stage of " .. label)
      assert(padLeft >= 0 and padLeft + pad.width <= size[1], "the keys are off a stage of " .. label)
      assert(padTop + pad.height <= size[2], "the keys are off a stage of " .. label)
      assert(padLeft >= left + grid.width or padTop >= top + grid.height, "the keys lie over the grid on " .. label)
      if size[1] ~= size[2] then
        equal(size[1] > size[2] and "beside" or "under", view.mode, label)
      end
      assert(view.grid.cell >= 22, "squares of " .. view.grid.cell .. " on " .. label)
      assert(grid.width >= math.min(size[1], size[2] - 46) * 0.6, "the grid makes use of " .. label)
    end
  end

  function tests.WindowKeepsWhereThePlayerWasInEverySudoku()
    local player, id, MainFrame = sudokuOnScreen()
    local Match = player.private.Match
    local grid = shownGrid()
    local first = emptySquare(Match.State(player.matches[id]), 3)
    clickOnGrid(grid, first)
    typeKey("N")
    typeKey("4")
    equal(true, padKey("sudoku_notes").on)

    -- Another game starts with the player on no square, writing digits
    local other = assert(player.session:Invite({}, "sudoku", { options = { level = "medium" } }))
    MainFrame.Open(other.id)
    equal(nil, grid.selected)
    equal(false, padKey("sudoku_notes").on)
    equal("sudoku_level_medium", statSays("sudoku_option_level"))
    for cell = 1, 81 do
      local digit = Match.State(other).grid[cell]
      equal(digit ~= 0 and tostring(digit) or "", grid.squares[cell].figure.text or "")
    end
    local second = emptySquare(Match.State(other), 7)
    clickOnGrid(grid, second)
    typeKey(tostring(Match.State(other).solution[second]))
    equal(true, grid:Busy())

    -- Back in the first nothing of the other is left over, and the player is where they were
    MainFrame.Open(id)
    equal(false, grid:Busy(), "what was on the move was about the other game")
    equal(first, grid.selected)
    equal(true, padKey("sudoku_notes").on)
    equal(true, grid.squares[first].notes[4]:IsShown())
    MainFrame.Open(other.id)
    equal(second, grid.selected)
    equal(false, padKey("sudoku_notes").on)
    equal(false, grid.squares[first].notes[4]:IsShown())

    -- A game that was given up shows no words and takes nothing
    assert(player.session:Resign(other.id))
    equal(false, says("sudoku_solved"))
    equal(nil, grid.selected)
    equal(false, typeKey("5"))
  end

  function tests.WindowLeavesMistakesAloneWhenAskedTo()
    local player, id = sudokuOnScreen({ level = "easy", check = false })
    local Match = player.private.Match
    local match = player.matches[id]
    local state = Match.State(match)
    local grid = shownGrid()
    equal("stat_none", statSays("sudoku_mistakes"))

    -- A wrong digit that clashes with nothing looks like any other
    local cell, wrong = nil, nil
    for other = 1, 81 do
      for digit = 1, 9 do
        if not cell and state.grid[other] == 0 and digit ~= state.solution[other] then
          local trial = { unpack(state.grid) }
          trial[other] = digit
          if not player.private.Sudoku.Clashes(trial)[other] then
            cell, wrong = other, digit
          end
        end
      end
    end
    assert(cell, "somewhere a wrong digit fits in")
    clickOnGrid(grid, cell)
    typeKey(tostring(wrong))
    equal(1, Match.State(match).mistakes)
    equal("cardPlace", Client.sounds[#Client.sounds], "it sounds like any other")
    local shook = 0
    for _ = 1, 40 do
      grid.motion:Fire("OnUpdate", 0.02)
      shook = math.max(shook, math.abs(grid.squares[cell].dx))
    end
    equal(0, shook)
    local ink = grid.inks[cell]
    local right = emptySquare(Match.State(match))
    clickOnGrid(grid, right)
    typeKey(tostring(state.solution[right]))
    equal(ink, grid.inks[right], "and is written like any other")
    equal("stat_none", statSays("sudoku_mistakes"), "nothing is counted out loud")
    grid:Settle()

    -- One that is twice in a row, column or box is marked all the same
    local clash = nil
    for other = 1, 81 do
      local sameRow = math.floor((other - 1) / 9) == math.floor((right - 1) / 9)
      clash = clash or (other ~= right and state.given[other] and sameRow and other)
    end
    typeKey(tostring(state.grid[clash]))
    equal(grid.tints[clash], grid.tints[cell] ~= grid.tints[clash] and grid.tints[clash] or nil)
    equal(true, grid.squares[clash].tint:IsShown())
    clickOnGrid(grid, cell)
    equal(grid.tints[clash], grid.tints[right], "both of them")
    assert(grid.tints[clash] ~= grid.tints[cell])
  end
end

-----------------------------
-- Games linked in chat
-----------------------------

function tests.CodecReadsAnAsk()
  local Codec = loadEngine().Codec
  local message = Codec.Decode(Codec.Encode("ASK", "abc123", "chess", 2))
  equal("ASK", message.type)
  equal("abc123", message.id)
  equal("chess", message.game)
  equal(2, message.gameVersion)
  equal(nil, Codec.Decode(Codec.Encode("ASK", "abc123", "chess")), "no version")
end

function tests.LinkedGameGoesToWhoeverAsksFirst()
  local world = World.New()
  local alice, bob, carol = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm"), world:AddPlayer("Carol-Realm")
  assert(alice.session:Offer("chess", { seat = 2 }))
  assert(alice.session:Offered("chess"))

  assert(bob.session:Ask("Alice-Realm", "chess"))
  -- Clicked again before the answer is there, which asks nothing new
  assert(bob.session:Ask("Alice-Realm", "chess"))
  world:Deliver()

  local id, match = next(bob.matches)
  equal("active", match.status, "asking is accepting")
  equal("active", alice.matches[id].status)
  equal(2, alice.matches[id].me, "the seat that was asked for")
  equal(1, match.me)
  equal("joined:" .. id, bob.events[#bob.events])
  equal(nil, next(bob.matches, id), "one game, however often it was clicked")
  for _, event in ipairs(bob.events) do
    assert(not event:find("^invite"), "there is nothing to answer")
  end
  equal(nil, alice.session:Offered("chess"), "taken")

  assert(bob.session:Move(id, "e2e4"))
  world:Deliver()
  equal("e2e4", logOf(alice, id))

  -- Too late
  assert(carol.session:Ask("Alice-Realm", "chess"))
  world:Deliver()
  equal(nil, next(carol.matches))
  equal("Alice-Realm:chess:closed", carol.refused[1])
end

function tests.LinkedGameIsPlayedByTheRulesItWasLinkedWith()
  local world = World.New()
  local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  local game = alice.private.Games.Get("checkers")
  local option = game.options[1]
  local Games = alice.private.Games
  local changed
  for _, value in ipairs(Games.Choices(option)) do
    if Games.Chosen(game, { [option.id] = value }) then
      changed = value
    end
  end
  assert(alice.session:Offer(game.id, { options = { [option.id] = changed } }))
  assert(bob.session:Ask("Alice-Realm", game.id))
  world:Deliver()
  local _, match = next(bob.matches)
  assert(changed ~= nil, "something to change")
  equal(changed, match.options[option.id])
end

function tests.LinkWithNoGameBehindItIsRefused()
  local world = World.New()
  local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  -- Anyone can type what a link says
  assert(bob.session:Ask("Alice-Realm", "chess"))
  world:Deliver()
  equal(nil, next(alice.matches))
  equal(nil, next(bob.matches))
  equal("Alice-Realm:chess:closed", bob.refused[1])

  -- An hour on the link is still in chat, the game isn't open any more
  assert(alice.session:Offer("chess"))
  world:Tick(60 * 60 + 1)
  assert(bob.session:Ask("Alice-Realm", "chess"))
  world:Deliver()
  equal(nil, next(bob.matches))
  equal(2, #bob.refused)

  equal("self_invite", select(2, alice.session:Ask("Alice-Realm", "chess")))
  equal("unknown_game", select(2, bob.session:Ask("Alice-Realm", "nosuchgame")))
  equal("player_count", select(2, alice.session:Offer("solitaire")), "a link is to a game for two")
end

function tests.LinkedGameOfSomeoneOfflineIsGivenUpOn()
  local world = World.New()
  local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  assert(alice.session:Offer("chess"))
  alice.online = false
  assert(bob.session:Ask("Alice-Realm", "chess"))
  world:Deliver()
  bob.session:PeerOffline("Alice-Realm")
  equal("Alice-Realm:chess:offline", bob.refused[1])

  -- A challenge from them later on is a challenge like any other, not something that was asked for
  alice.online = true
  local match = assert(alice.session:Invite("Bob-Realm", "chess"))
  world:Deliver()
  equal("incoming", bob.matches[match.id].status)
end

function tests.ChallengeNobodyAskedForIsStillAnswered()
  local world = World.New()
  local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  assert(alice.session:Offer("chess"))
  world:AddPlayer("Carol-Realm")
  assert(bob.session:Ask("Alice-Realm", "chess"))
  -- Someone else challenges them in the meantime
  local other = assert(world.players["Carol-Realm"].session:Invite("Bob-Realm", "chess"))
  world:Deliver()
  equal("incoming", bob.matches[other.id].status)
end

--- Loads Transport.lua over a fake client in a group on "Realm", where the player is "Jeany" to
--- the client's units and heard by their whole name
--- @return table Transport, table client What the test steers: what is sent, who is in the group, the clock
local function transportInAGroup()
  Client.Install()
  local client = { sent = {}, now = 100, group = {}, heard = {} }
  Enum = { SendAddonMessageResult = { Success = 0, TargetOffline = 1 } }
  C_ChatInfo = {
    RegisterAddonMessagePrefix = function() end,
    SendAddonMessage = function(_, text, chatType, target)
      client.sent[#client.sent + 1] = chatType .. " " .. (target or "") .. " " .. text
      return 0
    end,
  }
  C_FriendList = {
    ShowFriends = function() end,
    GetNumFriends = function()
      return 0
    end,
  }
  C_Timer = { After = function() end }
  function GetNormalizedRealmName()
    return "Realm"
  end
  function GetTime()
    return client.now
  end
  function UnitName()
    return "Jeany"
  end
  function IsInGuild()
    return false
  end
  function IsInRaid()
    return false
  end
  function IsInGroup()
    return true
  end
  function GetNumGroupMembers()
    return #client.group + 1
  end
  function UnitIsPlayer(unit)
    return unit == "target" or client.group[tonumber(unit:match("^party(%d+)$") or 0)] ~= nil
  end
  -- The client's units go by the first word of a name only
  function UnitFullName(unit)
    return unit == "target" and client.target or client.group[tonumber(unit:match("^party(%d+)$") or 0)]
  end
  function UnitInParty()
    return false
  end
  function UnitInRaid()
    return nil
  end
  local frame
  local create = CreateFrame
  function CreateFrame(...)
    frame = frame or create(...)
    return frame
  end
  local private = { Log = function() end }
  assert(loadfile("Transport.lua"))(ADDON_NAME, private)
  CreateFrame = create
  local Transport = private.Transport
  Transport.Init({
    onMessage = function(sender, text, _, channel)
      client.heard[#client.heard + 1] = sender .. " " .. text .. " " .. tostring(channel)
    end,
    onReachable = function() end,
    onOffline = function() end,
    onHeardAs = function(name)
      client.kept = name
    end,
  })
  function client.hear(sender, text, chatType)
    frame:GetScript("OnEvent")(frame, "CHAT_MSG_ADDON", "ForeverGames", text, chatType or "PARTY", sender)
  end
  return Transport, client
end

function tests.TransportKnowsThePlayerByTheNameTheyAreHeardBy()
  local Transport, client = transportInAGroup()
  equal("Jeany-Realm", Transport.PlayerName())

  -- Somebody else who starts the same is somebody else, saying something the player didn't
  client.hear("Jeany Other", "1:HI")
  equal("Jeany Other-Realm 1:HI GROUP", client.heard[1])
  equal(nil, Transport.HeardAs())

  -- The player's own message comes back by the whole of their name: that is them
  assert(Transport.BroadcastTo("GROUP", "1:ROOM:abc:OPEN:trivia:1:P:0"))
  client.hear("Jeany Beany", "1:ROOM:abc:OPEN:trivia:1:P:0")
  equal("Jeany-Realm 1:ROOM:abc:OPEN:trivia:1:P:0 GROUP", client.heard[2], "taken as the player's own")
  equal("Jeany Beany-Realm", Transport.HeardAs())
  equal("Jeany Beany-Realm", client.kept, "and kept for next time")
  equal(true, Transport.IsMe("Jeany Beany-Realm"))
  equal(true, Transport.IsMe("Jeany-Realm"))
  equal(false, Transport.IsMe("Jeany Other-Realm"))

  -- From then on whatever comes from that name is theirs, whatever it says
  client.hear("Jeany Beany", "1:ROOM:abc:A:1:1:122:0")
  equal("Jeany-Realm 1:ROOM:abc:A:1:1:122:0 GROUP", client.heard[3])
  equal("Jeany-Realm", Transport.Sender("Jeany Beany"))

  -- What somebody else says back a moment later isn't the player's, even word for word
  client.hear("Marvin Al", "1:ROOM:abc:OPEN:trivia:1:P:0")
  equal("Marvin Al-Realm 1:ROOM:abc:OPEN:trivia:1:P:0 GROUP", client.heard[4])
  equal("Jeany Beany-Realm", Transport.HeardAs())
end

function tests.TransportMakesTheNamesOfUnitsWhole()
  local Transport, client = transportInAGroup()
  client.group = { "Marvin", "Bob" }
  client.target = "Marvin"
  equal("Marvin-Realm", Transport.UnitPlayer("target"), "nobody heard yet who could be more of it")
  equal(false, Transport.Reaches("GROUP", "Marvin Al-Realm"))

  -- Once heard by the whole of their name, the target and the group member are known by it
  client.hear("Marvin Al", "1:ROOM:0:WHO")
  equal("Marvin Al-Realm", Transport.UnitPlayer("target"))
  equal(true, Transport.Reaches("GROUP", "Marvin Al-Realm"))
  equal("Bob-Realm", Transport.UnitPlayer("party2"), "a name of one word is all there is to it")
  equal("Marvin Al-Realm", Transport.Whole("Marvin"))
  equal("Marvin Al-Realm", Transport.Whole("Marvin Al-Realm"))

  -- Two who start the same can't be told apart from the first word
  client.hear("Marvin Bo", "1:ROOM:0:WHO", "WHISPER")
  equal("Marvin-Realm", Transport.UnitPlayer("target"))
  equal("Marvin Bo-Realm", Transport.Whole("Marvin Bo"))

  -- A name kept from last time is the player's from the start
  Transport.SetHeardAs("Jeany Beany-Realm")
  equal("Jeany-Realm", Transport.Sender("Jeany Beany"))
  Transport.SetHeardAs("Somebody Else-Realm")
  equal("Jeany Beany-Realm", Transport.HeardAs(), "never a name that isn't a longer one of the player's")
end

function tests.LinksInChatAreTurnedIntoLinks()
  local private = loadEngine()
  private.ADDON_NAME = ADDON_NAME
  assert(loadfile("Links.lua"))(ADDON_NAME, private)
  local Links = private.Links
  local chess = private.Games.Get("chess")

  local text = Links.Text(chess)
  equal("[Forever Games: " .. chess.name .. "]", text)
  local decorated = Links.Decorate("anyone for " .. text .. "?", "Quets Al-Realm")
  assert(decorated:find("^anyone for |c%x+|Haddon:ForeverGames:chess:Quets Al%-Realm|h%[Forever Games: " .. chess.name .. "%]|h|r%?$"), decorated)
  local host, gameId = Links.Parse(decorated:match("|H(.-)|h"))
  equal("Quets Al-Realm", host)
  equal("chess", gameId)

  equal(nil, Links.Decorate("nothing to see here", "Bob-Realm"))
  equal(nil, Links.Decorate("[Forever Games: No Such Game]", "Bob-Realm"))
  equal(nil, Links.Decorate("[Forever Games: " .. private.Games.Get("solitaire").name .. "]", "Bob-Realm"), "nobody to play it with")
  equal(nil, Links.Parse("addon:SomethingElse:chess:Bob-Realm"))
  equal(nil, Links.Parse("item:12345"))
end

function tests.WizardLinksAGameInChat()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  openWizard(alice)
  local linked, said
  alice.private.Links = {
    Insert = function(game)
      linked = game.id
    end,
  }
  function ForeverGames:Print(text)
    said = text
  end
  for _, card in ipairs(Client.Find(function(widget)
    return widget.kind == "Button" and widget.game ~= nil and widget.game.id == "chess" and widget:IsVisible()
  end)) do
    card:Fire("OnClick")
  end

  -- Nobody is picked, and nobody has to be
  equal(false, Client.Button("wizard_send").enabled)
  Client.Button("wizard_link"):Fire("OnClick")
  equal("chess", linked)
  equal("link_ready", said)
  assert(alice.session:Offered("chess"))
  equal(nil, next(alice.matches), "there is no game until someone asks")
  equal(false, alice.private.Wizard.IsOpen())
end

function tests.ChallengeFromAStrangerIsTurnedAway()
  local world = World.New()
  local alice, bob, carol = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm"), world:AddPlayer("Carol-Realm")
  -- Bob only plays with the players he knows, and Carol is the one he knows
  bob.knows = { ["Carol-Realm"] = true }

  local match = assert(alice.session:Invite("Bob-Realm", "chess"))
  world:Deliver()
  equal(nil, next(bob.matches), "Bob never hears of it")
  equal(0, #bob.events)
  equal("declined", alice.matches[match.id].status)
  equal("strangers", alice.matches[match.id].declineReason)

  -- Nothing is asked again of someone who said no
  local sent = #world.sent
  world:Tick(3600)
  equal(sent, #world.sent)

  local known = assert(carol.session:Invite("Bob-Realm", "chess"))
  world:Deliver()
  equal("incoming", bob.matches[known.id].status)
  equal("invite:" .. known.id, bob.events[1])
end

function tests.CrowdHostedByAStrangerIsTurnedAway()
  local world = World.New()
  local alice, bob, carol = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm"), world:AddPlayer("Carol-Realm")
  -- Who else sits at the table is the host's business, it is the host who has to be known
  bob.knows = { ["Carol-Realm"] = true }
  carol.knows = { ["Alice-Realm"] = true }

  local match = assert(alice.session:Invite({ "Bob-Realm", "Carol-Realm" }, "chinesecheckers"))
  world:Deliver()
  equal(nil, next(bob.matches))
  equal("declined", alice.matches[match.id].status)
  equal("strangers", alice.matches[match.id].declineReason)
  equal("Bob-Realm", alice.matches[match.id].players[alice.matches[match.id].declinedBy])
end

function tests.StrangerCanStillBeChallengedAndAskedForALinkedGame()
  local world = World.New()
  local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  bob.knows = {}

  -- Turning strangers away is about what they start, not about what Bob starts with them
  local match = assert(bob.session:Invite("Alice-Realm", "chess"))
  world:Deliver()
  assert(alice.session:Accept(match.id))
  world:Deliver()
  equal("active", bob.matches[match.id].status)

  -- Clicking a link is asking for the game, the challenge that comes back is wanted
  assert(alice.session:Offer("tictactoe"))
  assert(bob.session:Ask("Alice-Realm", "tictactoe"))
  world:Deliver()
  local linked
  for id, candidate in pairs(bob.matches) do
    if candidate.game == "tictactoe" then
      linked = id
    end
  end
  equal("active", bob.matches[linked].status)
  equal("active", alice.matches[linked].status)

  -- And a link Bob left in chat is open to whoever clicks it
  assert(bob.session:Offer("reversi"))
  assert(alice.session:Ask("Bob-Realm", "reversi"))
  world:Deliver()
  equal(nil, bob.session:Offered("reversi"))
  equal(0, #alice.refused)
end

-----------------------------
-- Games played together
-----------------------------
-- No game that ships is played without turns yet, so the tests bring one: a pool of letters that
-- whoever gets to one first takes. Taking "z" ends it.

--- @param private table
local function registerPool(private)
  private.Games.Register({
    id = "pool",
    name = "Pool",
    version = 1,
    seats = { 1, 2, 3 },
    together = true,
    undo = true,
    newState = function()
      return { taken = {}, count = 0 }
    end,
    validate = function(state, _, move)
      if not move:match("^%l$") then
        return false, "invalid_move"
      end
      return not state.taken[move], "taken"
    end,
    apply = function(state, seat, move)
      state.taken[move] = seat
      state.count = state.count + 1
      return { notation = move }
    end,
    result = function(state)
      return state.taken.z and { winner = 0, all = true } or nil
    end,
    progress = function(state)
      return state.count .. " taken"
    end,
    createView = function() end,
  })
end

--- Starts an accepted match of the pool
--- @param guests number? How many are asked to join, one if left out
--- @return World, string id, table ... The players, by seat
local function startedPool(guests)
  local world = World.New()
  world.prepare = registerPool
  local host, others, targets = world:AddPlayer("Alice-Realm"), {}, {}
  for index = 1, guests or 1 do
    others[index] = world:AddPlayer(({ "Bob-Realm", "Cleo-Realm" })[index])
    targets[index] = others[index].name
  end
  local match = assert(host.session:Invite(targets, "pool"))
  world:Deliver()
  for _, other in ipairs(others) do
    assert(other.session:Accept(match.id))
    world:Deliver()
  end
  local seated = {}
  for _, player in ipairs({ host, unpack(others) }) do
    seated[player.matches[match.id].me] = player
  end
  return world, match.id, unpack(seated)
end

--- The letters a log has taken, in alphabetical order
local function takenIn(player, id)
  local letters = {}
  for _, entry in ipairs(player.matches[id].log) do
    letters[#letters + 1] = entry:match("^%d(%l)$")
  end
  table.sort(letters)
  return table.concat(letters)
end

function tests.TogetherNeedsNoTurn()
  local private = loadEngine()
  registerPool(private)
  equal(true, private.Games.Get("pool").together)
  local ok = pcall(private.Games.Register, {
    id = "turnless",
    name = "Turnless",
    version = 1,
    seats = 2,
    newState = function() end,
    validate = function() end,
    apply = function() end,
    result = function() end,
    createView = function() end,
  })
  equal(false, ok, "a game with turns has to say whose it is")
end

function tests.TogetherAnyoneMovesAtAnyTime()
  local world, id, first, second = startedPool()
  local Match = first.private.Match
  equal(true, Match.CanMove(first.matches[id]))
  equal(true, Match.CanMove(second.matches[id]))
  equal(nil, Match.Turn(first.matches[id]), "it is nobody's turn in particular")

  assert(second.session:Move(id, "a"))
  world:Deliver()
  assert(second.session:Move(id, "b"))
  world:Deliver()
  assert(first.session:Move(id, "c"))
  world:Deliver()
  equal("2a,2b,1c", logOf(first, id))
  equal("2a,2b,1c", logOf(second, id))

  local events = Match.Events(first.matches[id])
  equal(2, events[1].seat)
  equal(1, events[3].seat)
  equal("c", events[3].notation)

  local ok, err = first.session:Move(id, "a")
  equal(false, ok)
  equal("taken", err)
  equal(false, (first.session:Move(id, "!r2")))
  equal(false, first.session:IsPending(first.matches[id]))
end

function tests.TogetherEntriesSayWhoseTheyAre()
  local _, id, first = startedPool()
  local Match = first.private.Match
  local match = first.matches[id]
  equal(false, (Match.Append(match, "a")), "no seat")
  equal(false, (Match.Append(match, "3a")), "nobody sits there")
  equal(false, (Match.Append(match, "0a")))
  equal(false, (Match.Append(match, "1")), "no move")
  equal(true, (Match.Append(match, "2a")))
  equal(2, Match.State(match).taken.a)
  equal(false, Match.CanOfferDraw(match))
end

function tests.TogetherWaitsOnNobody()
  local world, id, first, second = startedPool()
  second.session:MarkRead(id)
  first.session:MarkRead(id)
  equal(false, first.session:NeedsAttention(first.matches[id]))
  equal(false, second.session:NeedsAttention(second.matches[id]))

  assert(first.session:Move(id, "a"))
  world:Deliver()
  equal(false, first.session:NeedsAttention(first.matches[id]))
  equal(true, second.session:NeedsAttention(second.matches[id]), "there is something new to look at")
  second.session:MarkRead(id)
  equal(false, second.session:NeedsAttention(second.matches[id]))
end

function tests.TogetherMovesMadeAtTheSameMomentAllCount()
  local world, id, first, second = startedPool()
  assert(first.session:Move(id, "a"))
  world:Deliver()
  -- Both act before either message arrives
  assert(first.session:Move(id, "b"))
  assert(second.session:Move(id, "c"))
  world:Deliver()
  equal("1a,1b,2c", logOf(first, id))
  equal("1a,1b,2c", logOf(second, id))
  equal(false, first.session:IsPending(first.matches[id]))
  equal(false, second.session:IsPending(second.matches[id]))
end

function tests.TogetherTheSameMoveAtTheSameMomentCountsOnce()
  local world, id, first, second = startedPool()
  assert(first.session:Move(id, "a"))
  assert(second.session:Move(id, "a"))
  assert(second.session:Move(id, "b"))
  world:Deliver()
  world:Tick(30)
  equal(logOf(first, id), logOf(second, id))
  equal("ab", takenIn(first, id))
  equal(first.private.Match.State(first.matches[id]).taken.a, second.private.Match.State(second.matches[id]).taken.a)
end

function tests.TogetherPlayedApartComesTogether()
  local world, id, first, second = startedPool()
  assert(first.session:Move(id, "a"))
  world:Deliver()

  second.online = false
  for letter in ("bcd"):gmatch(".") do
    assert(first.session:Move(id, letter))
  end
  world:Deliver()
  second.online = true
  first.online = false
  for letter in ("efghij"):gmatch(".") do
    assert(second.session:Move(id, letter))
  end
  -- And one they both found
  assert(second.session:Move(id, "b"))
  world:Deliver()

  first.online = true
  for _ = 1, 6 do
    world:Tick(600)
  end
  equal(logOf(first, id), logOf(second, id))
  equal("abcdefghij", takenIn(first, id))
  equal(false, first.session:IsPending(first.matches[id]))
  equal(false, second.session:IsPending(second.matches[id]))
end

function tests.TogetherSurvivesACrash()
  local world, id, first, second = startedPool()
  assert(first.session:Move(id, "a"))
  world:Deliver()
  local snapshot = copy(second.matches)
  assert(second.session:Move(id, "b"))
  assert(first.session:Move(id, "c"))
  world:Deliver()

  -- The second player comes back with data from before, and finds something else
  first.online = false
  second = world:Relog(second, snapshot)
  assert(second.session:Move(id, "d"))
  world:Deliver()
  first.online = true
  for _ = 1, 4 do
    world:Tick(600)
  end
  equal(logOf(first, id), logOf(second, id))
  equal("abcd", takenIn(first, id), "what was lost in the crash comes back, and what was played after it stays")
end

function tests.TogetherNoticesLogsThatPartedWaysUnseen()
  local world, id, first, second = startedPool()
  assert(first.session:Move(id, "a"))
  world:Deliver()
  -- The second player loses what they had, and the first never hears of what they do next
  second = world:Relog(second, copy(second.matches))
  local Match = second.private.Match
  Match.Truncate(second.matches[id], 0)
  assert(Match.Append(second.matches[id], "2b"))
  equal("1a", logOf(first, id))
  equal("2b", logOf(second, id))
  equal(false, first.session:IsPending(first.matches[id]), "as far as the first player knows they have it all")

  -- One entry each, and neither would learn anything from being told so. What gives it away is
  -- that an entry arrives on top of a log that isn't the one it was played on
  assert(first.session:Move(id, "c"))
  world:Deliver()
  world:Tick(30)
  equal("1a,1c,2b", logOf(first, id))
  equal("1a,1c,2b", logOf(second, id))
end

function tests.TogetherCountsComeWithWhatTheLogIs()
  local world, id, first, second = startedPool()
  assert(first.session:Move(id, "a"))
  world:Deliver()
  local Codec, Match = first.private.Codec, first.private.Match
  local move = Codec.Decode(world.sent[#world.sent - 1]:match(" (.+)$"))
  equal("MOV", move.type)
  equal(Match.Digest(first.matches[id], 0), move.digest)
  local answer = Codec.Decode(world.sent[#world.sent]:match(" (.+)$"))
  equal("ACK", answer.type)
  equal(1, answer.n)
  equal(Match.Digest(first.matches[id], 1), answer.digest)
  assert(Match.Digest(first.matches[id], 0) ~= Match.Digest(first.matches[id], 1))

  -- A game with turns says no more than it used to
  local _, _, _, other, mover = startedMatch()
  assert(mover.session:Move(other, "5"))
  equal(nil, Codec.Decode("1:MOV:" .. other .. ":1:1:5").digest)
end

function tests.TogetherMoveAfterTheEndIsDropped()
  local world, id, first, second = startedPool()
  assert(first.session:Move(id, "z"))
  assert(second.session:Move(id, "a"))
  world:Deliver()
  world:Tick(30)
  equal("1z", logOf(first, id))
  equal("1z", logOf(second, id))
  equal("finished", second.matches[id].status)
  equal(false, second.private.Match.CanMove(second.matches[id]))
end

function tests.TogetherResignationStandsWhateverElseHappened()
  local world, id, first, second, third = startedPool(2)
  assert(third.session:Resign(id))
  assert(first.session:Move(id, "a"))
  assert(second.session:Move(id, "b"))
  world:Deliver()
  for _ = 1, 4 do
    world:Tick(600)
  end
  equal(logOf(first, id), logOf(second, id))
  equal(logOf(first, id), logOf(third, id))
  equal("ab", takenIn(first, id))
  equal(true, first.private.Match.IsOut(first.matches[id], 3))
  equal(false, third.private.Match.CanMove(third.matches[id]))
  equal(true, first.private.Match.CanMove(first.matches[id]))
end

function tests.TogetherIsPlayedOnByWhoeverIsLeft()
  local world, id, first, second = startedPool()
  assert(first.session:Resign(id))
  world:Deliver()
  equal("active", second.matches[id].status)
  equal(true, second.private.Match.CanMove(second.matches[id]))
  equal(false, first.private.Match.CanMove(first.matches[id]))
  assert(second.session:Move(id, "z"))
  world:Deliver()
  equal("finished", first.matches[id].status)
  equal(true, first.private.Match.Result(first.matches[id]).all)

  -- And once nobody is, it is over without anyone having made it
  local other, again, one, two = startedPool()
  assert(one.session:Resign(again))
  other:Deliver()
  assert(two.session:Resign(again))
  other:Deliver()
  equal("finished", one.matches[again].status)
  equal("resign", one.private.Match.Result(one.matches[again]).reason)
  equal(nil, one.private.Match.Result(one.matches[again]).all)
end

function tests.TogetherAloneCanBeTakenBack()
  local world = World.New()
  world.prepare = registerPool
  local alice = world:AddPlayer("Alice-Realm")
  local match = assert(alice.session:Invite({}, "pool"))
  assert(alice.session:Move(match.id, "a"))
  assert(alice.session:Move(match.id, "b"))
  equal("1a,1b", logOf(alice, match.id))
  assert(alice.session:Undo(match.id))
  equal("1a", logOf(alice, match.id))
  equal(0, #world.queue, "nothing is sent to anyone")
end

--- Has players take letters at random while the network loses messages and they come and go,
--- and checks that they end up with the same log and everything any of them took
--- @param guests number
--- @param seed number
local function poolStorm(guests, seed)
  local world, id, one, two, three = startedPool(guests)
  local players = { one, two, three }
  local state = seed
  local function roll(max)
    state = (state * 1103515245 + 12345) % 2147483648
    return math.floor(state / 65536) % max + 1
  end
  local function lossy()
    return roll(4) == 1
  end

  local wanted = {}
  for _ = 1, 60 do
    local player = players[roll(#players)]
    local action = roll(10)
    if action <= 6 then
      local letter = string.char(96 + roll(25))
      if player.session:Move(id, letter) then
        wanted[letter] = true
      end
    elseif action == 7 then
      player.online = not player.online
    elseif action == 8 then
      world:Deliver(lossy)
    else
      world:Tick(roll(600))
    end
  end

  for _, player in ipairs(players) do
    player.online = true
  end
  for _ = 1, 40 do
    world:Tick(600)
  end

  local letters = {}
  for letter in pairs(wanted) do
    letters[#letters + 1] = letter
  end
  table.sort(letters)
  local label = string.format("%d players, seed %d", #players, seed)
  for _, player in ipairs(players) do
    equal(logOf(players[1], id), logOf(player, id), label)
    equal(table.concat(letters), takenIn(player, id), label)
    equal(false, player.session:IsPending(player.matches[id]), label)
  end
end

function tests.TogetherConvergesWhateverTheNetworkDoes()
  for seed = 1, 60 do
    poolStorm(1, seed)
  end
end

function tests.TogetherConvergesAmongThreeAsWell()
  for seed = 1, 60 do
    poolStorm(2, seed)
  end
end

-----------------------------
-- Warcraftstein 3D
-----------------------------
-- In a block of its own, which keeps its helpers out of the chunk's locals: there is room for
-- only so many of those
do

--- The squares next to one, as indexes into the cells of the monastery
--- @param state table
--- @param square number
--- @return number[]
local function abbeyNeighbours(state, square)
  return { square - 1, square + 1, square - state.side, square + state.side }
end

--- The square a point is on
--- @param state table
--- @param x number
--- @param y number
--- @return number
local function abbeySquare(state, x, y)
  return math.floor(y) * state.side + math.floor(x) + 1
end

--- How far every square is to walk to from the start, going round whatever stands in the way,
--- and the way to the portal: the squares to cross, the portal last
--- @param state table
--- @return table<number, number> walk, number[] way
local function abbeyWalk(state)
  local solid = {}
  for _, item in ipairs(state.decor) do
    solid[abbeySquare(state, item.x, item.y)] = true
  end
  local start = abbeySquare(state, state.start.x, state.start.y)
  local walk, from, queue, portal = { [start] = 0 }, {}, { start }, nil
  local index = 1
  while queue[index] do
    local square = queue[index]
    index = index + 1
    for _, next in ipairs(abbeyNeighbours(state, square)) do
      if state.cells[next] == 7 then
        portal = portal or next
        from[next] = from[next] or square
      elseif state.cells[next] == 0 and not solid[next] and not walk[next] then
        walk[next], from[next] = walk[square] + 1, square
        queue[#queue + 1] = next
      end
    end
  end
  local way, square = {}, assert(portal, "the portal can be reached")
  while square ~= start do
    table.insert(way, 1, square)
    square = from[square]
  end
  return walk, way
end

function tests.WarcraftsteinBuildsAMonastery()
  local private = loadEngine()
  local game = private.Games.Get("warcraftstein")
  for _, size in ipairs({ 6, 9, 12 }) do
    for seed = 1, 30 do
      local state = game.newState(1, private.Random.New(seed), { size = size })
      local side = state.side
      equal(side * side, #state.cells)
      equal(size, #state.rooms, "as many rooms as were asked for")
      equal(nil, state.class, "nobody yet")

      local portals = 0
      for square, kind in ipairs(state.cells) do
        local column, row = (square - 1) % side, math.floor((square - 1) / side)
        assert(kind >= 0 and kind <= 8, "something that can be drawn on every square")
        if column == 0 or row == 0 or column == side - 1 or row == side - 1 then
          assert(kind >= 1 and kind <= 8, "a wall all round, the portal in it as likely as not")
        end
        portals = portals + (kind == 7 and 1 or 0)
      end
      equal(1, portals)

      -- Everywhere can be got to, round whatever stands about, and the portal from the armory
      local walk, way = abbeyWalk(state)
      for square, kind in ipairs(state.cells) do
        if kind == 0 then
          local solid = false
          for _, item in ipairs(state.decor) do
            solid = solid or abbeySquare(state, item.x, item.y) == square
          end
          assert(solid or walk[square], "nowhere that can't be got to")
        end
      end
      local last = state.rooms[1]
      for _, room in ipairs(state.rooms) do
        last = room.far > last.far and room or last
      end
      equal("sanctuary", state.rooms[1].wing, "the sanctuary first")
      equal("fountain", state.decor[1].kind, "with a fountain in it")
      local sanctuary = state.rooms[1]
      assert(state.start.x >= sanctuary.x and state.start.x < sanctuary.x + sanctuary.w and state.start.y >= sanctuary.y and state.start.y < sanctuary.y + sanctuary.h, "where the player begins")
      local fountainX, fountainY = state.start.x + math.cos(state.start.facing), state.start.y + math.sin(state.start.facing)
      equal(string.format("%.1f,%.1f", state.decor[1].x, state.decor[1].y), string.format("%.1f,%.1f", fountainX, fountainY), "right in front of them")
      equal("armory", last.wing, "and the armory last")
      local before = way[#way - 1]
      local column, row = (before - 1) % side, math.floor((before - 1) / side)
      assert(column >= last.x and column < last.x + last.w and row >= last.y and row < last.y + last.h, "the portal is in a wall of the armory")

      -- Herod in the armory, nobody in the first room, never two on one square
      local taken, herods = {}, 0
      local function inside(room, x, y)
        return x >= room.x and x < room.x + room.w and y >= room.y and y < room.y + room.h
      end
      for _, mob in ipairs(state.mobs) do
        local square = abbeySquare(state, mob.x, mob.y)
        equal(0, state.cells[square])
        equal(nil, taken[square], "a square to itself")
        taken[square] = true
        assert(not inside(state.rooms[1], mob.x, mob.y), "nobody where the player begins")
        -- Ten squares' walk from the middle of it, which the player is a step back from
        assert(walk[square] >= 9, "nor anywhere near it")
        if mob.kind == "herod" then
          herods = herods + 1
          assert(inside(last, mob.x, mob.y))
        end
      end
      equal(1, herods)
      local potions = { health = 0, power = 0 }
      for _, potion in ipairs(state.loot) do
        local square = abbeySquare(state, potion.x, potion.y)
        equal(0, state.cells[square])
        equal(nil, taken[square])
        taken[square] = true
        potions[potion.kind] = potions[potion.kind] + 1
      end
      equal(math.floor(size / 1.5), potions.health)
      equal(math.floor(size / 2), potions.power)
      for _, item in ipairs(state.decor) do
        local square = abbeySquare(state, item.x, item.y)
        equal(0, state.cells[square])
        assert(square ~= abbeySquare(state, state.start.x, state.start.y))
      end
      assert(#state.decor >= size, "something standing about in every room")
    end
  end

  local one, other = game.newState(1, private.Random.New(7), { size = 9 }), game.newState(1, private.Random.New(7), { size = 9 })
  equal(table.concat(one.cells), table.concat(other.cells), "the same monastery from the same seed")
  for index, mob in ipairs(one.mobs) do
    equal(mob.x .. "," .. mob.y .. mob.kind, other.mobs[index].x .. "," .. other.mobs[index].y .. other.mobs[index].kind, "and the same Crusade in it")
  end
end

function tests.WarcraftsteinEndsAtThePortal()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local Match, game = alice.private.Match, alice.private.Games.Get("warcraftstein")
  equal(true, alice.private.Games.IsSolo(game))
  local match = assert(alice.session:Invite({}, "warcraftstein", { options = { size = 6 } }))
  local state = Match.State(match)
  equal(6, state.size)
  equal(nil, game.result(state))
  equal(nil, game.record(state, 12))
  equal("warcraftstein_progress", game.progress(state))
  equal(false, (game.validate(state, 1, "y")))
  equal(false, (game.validate(state, 2, "x")))
  -- First of all the player says who they are, once
  equal(false, (game.validate(state, 1, "x")), "nobody gets out who was never in")
  equal(false, (game.validate(state, 1, "cGNOME")))
  equal(false, (game.validate(state, 1, "c")))
  assert(alice.session:Move(match.id, "cMAGE"))
  state = Match.State(match)
  equal("MAGE", state.class)
  equal(false, (game.validate(state, 1, "cROGUE")))
  equal(nil, game.result(state))

  world.clock = world.clock + 30
  assert(alice.session:Move(match.id, "x"))
  state = Match.State(match)
  equal(true, state.found)
  equal(1, game.result(state).winner)
  equal(false, (game.validate(state, 1, "x")), "only once")
  equal("finished", match.status)
  local record = game.record(state, 12)[1]
  equal("rooms6", record.key)
  equal(12, record.value)
  equal(true, record.lower)

  -- Or with the Crusade getting the player first, which is no time worth keeping
  match = assert(alice.session:Invite({}, "warcraftstein", { options = { size = 6 } }))
  assert(alice.session:Move(match.id, "cDRUID"))
  assert(alice.session:Move(match.id, "d"))
  state = Match.State(match)
  equal(true, state.dead)
  equal(false, state.found)
  equal(0, game.result(state).winner)
  equal(nil, game.record(state, 12))
  equal(false, (game.validate(state, 1, "x")), "nobody gets out after that")
  equal("finished", match.status)
end

--- Opens the window on a new game of Warcraftstein
--- @param size number?
--- @param class string|boolean|nil Who goes in: a warrior if left out, nobody yet if false
--- @return table player, table match, table walker The view of the game on screen
local function abbeyOnScreen(size, class)
  local world = World.New()
  world.seed = 3
  local player = world:AddPlayer("Alice-Realm")
  local MainFrame = openWindow(player)
  function StaticPopup_Show(which, _, _, data)
    StaticPopupDialogs[which].OnAccept(nil, data)
  end
  local match = assert(player.session:Invite({}, "warcraftstein", { options = { size = size } }))
  if class ~= false then
    assert(player.session:Move(match.id, "c" .. (class or "WARRIOR")))
  end
  MainFrame.Open(match.id)
  local found = Client.Find(function(widget)
    return widget.walker ~= nil and widget:IsVisible()
  end)
  equal(1, #found, "monasteries on screen")
  return player, match, found[1].walker
end

--- Holds keys down for a while in the monastery on screen, and lets go of them again
--- @param walker table
--- @param keys string[]
--- @param frames number
local function abbeyHold(walker, keys, frames)
  for _, key in ipairs(keys) do
    walker.ticker:Fire("OnKeyDown", key)
  end
  for _ = 1, frames do
    walker.ticker:Fire("OnUpdate", 0.02)
  end
  for _, key in ipairs(keys) do
    walker.ticker:Fire("OnKeyUp", key)
  end
end

--- How tall every column of the monastery on screen is, to tell one look from another
--- @param walker table
--- @return string
local function abbeySeen(walker)
  local heights = {}
  for index = 1, walker.count do
    heights[index] = string.format("%.1f", walker.columns[index].height)
  end
  return table.concat(heights, " ")
end

--- Stands the player a square away from a foe that waits, looking at it, with nobody else about
--- @param state table
--- @param walker table
--- @param kind string? What it is, a soldier if left out
--- @return table mob
local function abbeyMeet(state, walker, kind)
  local run = walker.run
  for _, item in ipairs(run.decor) do
    item.girth = nil
  end
  for _, mob in ipairs(run.mobs) do
    mob.dead = true
  end
  for _, mob in ipairs(run.mobs) do
    for _, step in ipairs({ { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } }) do
      if state.cells[abbeySquare(state, mob.x + step[1], mob.y + step[2])] == 0 and mob.kind ~= "herod" then
        local foe = walker.foes[kind or "soldier"]
        mob.dead, mob.kind, mob.foe, mob.health = false, kind or "soldier", foe, foe.health
        if run.boss and run.boss ~= mob then
          run.boss = nil
        end
        walker.pose.x, walker.pose.y = mob.x + step[1], mob.y + step[2]
        walker.pose.facing = math.atan2(-step[2], -step[1]) % (math.pi * 2)
        walker:render()
        return mob
      end
    end
  end
  error("nobody to meet")
end

--- The strips of what is seen that show something that stands in the monastery
--- @param walker table
--- @param thing table? Only the ones that show this
--- @return number
local function abbeyStrips(walker, thing)
  local strips, all = 0, 0
  for _, layer in pairs(walker.strips) do
    for index, strip in pairs(layer) do
      if strip:IsShown() then
        all = all + 1
        strips = strips + ((not thing or strip.shows == thing) and 1 or 0)
        assert(index <= walker.count)
        assert(strip.texture:find("sprites"))
        assert(strip.height > 0 and strip.height <= walker.frame.height, "never taller than what is seen")
      end
    end
  end
  equal(all, #walker.lit)
  return strips
end

function tests.WarcraftsteinDrawsWhatIsSeen()
  local player, match, walker = abbeyOnScreen(6)
  local state = player.private.Match.State(match)
  assert(walker.count >= 60, "columns to draw with")
  equal(state.start.x, walker.pose.x)

  local frame = walker.frame
  for index = 1, walker.count do
    local column = walker.columns[index]
    assert(column:IsVisible(), "every column in use is shown")
    assert(column.height > 0 and column.height <= frame.height, "a column is never taller than what is seen: " .. column.height)
    assert(column.texture and column.texture:find("Warcraftstein"), "every column shows a wall")
    assert(column.color[1] > 0 and column.color[1] <= 1, "and has some light on it")
  end
  -- Floor and ceiling, a row at a time from the middle out
  assert(walker.rows > 10)
  for index = 1, walker.rows do
    assert(walker.floors[index].texture:find("floor"))
    assert(walker.ceilings[index].texture:find("ceiling"))
    assert(walker.floors[index]:IsShown())
  end
  assert(walker.floors[walker.rows].color[1] > walker.floors[1].color[1], "the floor at the player's feet is lighter than far away")
  -- Firelight is warm: some wall near a light is redder than it is blue
  local warm = false
  for _ = 1, 4 do
    walker.pose.facing = walker.pose.facing + math.pi / 2
    walker:render()
    for index = 1, walker.count do
      warm = warm or walker.columns[index].color[1] > walker.columns[index].color[3] + 0.05
    end
  end
  assert(warm, "the lights in the room light it")
  walker.pose.facing = state.start.facing
  walker:render()

  -- Standing still nothing is drawn again, turning shows something else, and so does walking
  local before = abbeySeen(walker)
  walker.ticker:Fire("OnUpdate", 0.02)
  equal(before, abbeySeen(walker))
  abbeyHold(walker, { "D" }, 10)
  assert(abbeySeen(walker) ~= before, "turning changes what is seen")
  assert(walker.pose.facing ~= state.start.facing)
  equal(state.start.x, walker.pose.x, "turning goes nowhere")
  abbeyHold(walker, { "A" }, 10)
  abbeyHold(walker, { "W" }, 10)
  assert(walker.pose.x ~= state.start.x or walker.pose.y ~= state.start.y, "walking does")

  -- A key that is let go of stops, and so does one held when the cursor leaves
  local x, y = walker.pose.x, walker.pose.y
  abbeyHold(walker, {}, 10)
  equal(x .. "," .. y, walker.pose.x .. "," .. walker.pose.y)
  walker.ticker:Fire("OnKeyDown", "W")
  Client.over = false
  walker.ticker:Fire("OnUpdate", 0.02)
  Client.over = true
  walker.ticker:Fire("OnUpdate", 0.02)
  equal(x .. "," .. y, walker.pose.x .. "," .. walker.pose.y)
  walker.ticker:Fire("OnKeyUp", "W")
  equal(false, walker.ticker.propagates, "a key the game takes goes no further")
  walker.ticker:Fire("OnKeyDown", "X")
  equal(true, walker.ticker.propagates, "one that means nothing here is left to the client")

  -- Fewer columns in a smaller window, and none of the others left showing
  local count, rows = walker.count, walker.rows
  walker:Layout(300, 260)
  assert(walker.count < count, "fewer columns in less room")
  assert(walker.rows < rows)
  equal(false, walker.columns[count]:IsShown())
  equal(false, walker.floors[rows]:IsShown())
  assert(walker.columns[walker.count].height > 0)
end

function tests.WarcraftsteinNeverWalksThroughAWall()
  local player, match, walker = abbeyOnScreen(6)
  local state = player.private.Match.State(match)
  walker.run.health, walker.run.spec.health = 1e6, 1e6
  -- Leaning on every key in turn for a good while, wherever that leads
  local leans = { { "W" }, { "W", "D" }, { "S", "E" }, { "Q" }, { "W", "A" }, { "E", "W" }, { "S" }, { "W", "Q", "D" } }
  for round = 1, 40 do
    abbeyHold(walker, leans[(round - 1) % #leans + 1], 45)
    if match.status == "finished" then
      break
    end
    local pose = walker.pose
    for _, corner in ipairs({ { -0.2, -0.2 }, { 0.2, -0.2 }, { -0.2, 0.2 }, { 0.2, 0.2 } }) do
      equal(0, state.cells[abbeySquare(state, pose.x + corner[1], pose.y + corner[2])], "the player stands clear of every wall")
    end
  end
end

function tests.WarcraftsteinIsFoughtThroughToTheWayOut()
  local player, match, walker = abbeyOnScreen(6)
  local Match = player.private.Match
  local state = Match.State(match)
  local run = walker.run
  -- Nobody dies of it here: what is tried is getting there
  run.health, run.spec.health = 1e6, 1e6
  local _, way = abbeyWalk(state)
  local side = state.side

  local frames, herod = 0, run.boss
  for step, square in ipairs(way) do
    local x, y = (square - 1) % side + 0.5, math.floor((square - 1) / side) + 0.5
    while not Match.State(match).found do
      local pose = walker.pose
      local away = math.sqrt((x - pose.x) ^ 2 + (y - pose.y) ^ 2)
      if away < 0.1 and step < #way then
        break
      end
      -- Whoever is up and in sight comes first: gone up to, and struck
      local toX, toY, keys, nearest = x, y, { "W" }, math.huge
      for _, mob in ipairs(run.mobs) do
        local far = (mob.x - pose.x) ^ 2 + (mob.y - pose.y) ^ 2
        if mob.awake and not mob.dead and far < nearest and far < 36 then
          toX, toY, nearest = mob.x, mob.y, far
          keys = far > 1 and { "W", "SPACE" } or { "SPACE" }
        end
      end
      local off = (math.atan2(toY - pose.y, toX - pose.x) - pose.facing + math.pi) % (math.pi * 2) - math.pi
      if math.abs(off) > 0.08 then
        keys = { off > 0 and "D" or "A" }
      end
      abbeyHold(walker, keys, 1)
      frames = frames + 1
      assert(frames < 60000, "the way out is found some time")
    end
  end

  equal(true, Match.State(match).found)
  equal(true, herod.dead, "past Herod, who has to fall first")
  equal("finished", match.status)
  equal(true, walker.effects:HasBanner(), "it says so across what was seen")
  assert(run.level > 1, "with a level or two on the way")
  assert(player.session:Best("warcraftstein", "rooms6"), "and the time it took is kept")
  local x = walker.pose.x
  abbeyHold(walker, { "S" }, 10)
  equal(x, walker.pose.x, "nobody walks about in a game that is over")
  equal(true, walker.ticker.propagates)
end

function tests.WarcraftsteinShowsWhoIsThere()
  local player, match, walker = abbeyOnScreen(6)
  local state = player.private.Match.State(match)
  equal(#state.mobs, #walker.run.mobs)
  equal(#state.loot, #walker.run.loot)
  equal(#state.decor, #walker.run.decor)
  equal(120, walker.health.value)
  equal(0, walker.power.value, "no rage yet")

  local mob = abbeyMeet(state, walker)
  local near = abbeyStrips(walker, mob)
  assert(near > walker.count / 2, "one that is a square away fills most of what is seen: " .. near)
  -- Not through a wall: only the columns where the wall is further away than it is
  for _, layer in pairs(walker.strips) do
    for index, strip in pairs(layer) do
      if strip:IsShown() then
        assert(walker.depths[index] > strip.shows.depth)
      end
    end
  end
  -- Further away it is smaller, and behind the player it isn't there
  local x, y = walker.pose.x, walker.pose.y
  walker.pose.x, walker.pose.y = x + (x - mob.x) * 0.4, y + (y - mob.y) * 0.4
  walker:render()
  local far = abbeyStrips(walker, mob)
  assert(far > 0 and far < near, "smaller from further away")
  walker.pose.facing = (walker.pose.facing + math.pi) % (math.pi * 2)
  walker:render()
  equal(0, abbeyStrips(walker, mob), "nothing of what is behind")
  walker.pose.facing = (walker.pose.facing + math.pi) % (math.pi * 2)

  -- A phantasm is seen through
  mob.kind, mob.foe = "phantasm", walker.foes.phantasm
  walker:render()
  for _, strip in ipairs(walker.lit) do
    if strip.shows == mob then
      equal(0.7, strip.color[4])
    end
  end

  -- A potion is drawn the same way, in front of whoever is behind it
  local potion = walker.run.loot[1]
  potion.x, potion.y = (walker.pose.x + mob.x) / 2, (walker.pose.y + mob.y) / 2
  walker:render()
  assert(abbeyStrips(walker, potion) > 0)
  assert(abbeyStrips(walker, mob) > 0, "and whoever is behind it still is")

  -- And in a smaller window there are fewer columns to show it in
  walker:Layout(300, 260)
  local fewer = abbeyStrips(walker, mob)
  assert(fewer > 0)
end

function tests.WarcraftsteinFoesComeForThePlayer()
  local player, match, walker = abbeyOnScreen(6)
  local state = player.private.Match.State(match)
  local mob = abbeyMeet(state, walker)
  local run = walker.run
  equal(false, mob.awake)

  -- With the cursor somewhere else nothing happens at all
  Client.over = false
  abbeyHold(walker, {}, 50)
  Client.over = true
  equal(false, mob.awake)
  equal(120, run.health)

  -- It wakes, says so, comes up to the player and hits them, again and again. A warrior's
  -- armour takes some of every blow, and every blow makes them angrier
  abbeyHold(walker, {}, 5)
  equal(true, mob.awake)
  equal(true, walker.said:IsShown(), "the Crusade has something to say")
  abbeyHold(walker, {}, 40)
  local away = math.sqrt((mob.x - walker.pose.x) ^ 2 + (mob.y - walker.pose.y) ^ 2)
  assert(away <= 0.95 and away > 0.7, "as near as it comes: " .. away)
  equal("111.6", string.format("%.1f", run.health))
  equal(112, walker.health.value)
  equal(8, run.power)
  abbeyHold(walker, {}, 60)
  equal("103.2", string.format("%.1f", run.health))

  -- Three blows are the end of it: it lies where it fell and does nothing more
  abbeyHold(walker, { "SPACE" }, 2)
  equal(30, mob.health)
  equal(false, mob.dead)
  abbeyHold(walker, { "SPACE" }, 10)
  equal(30, mob.health, "a blow takes its time")
  abbeyHold(walker, { "SPACE" }, 45)
  equal(true, mob.dead)
  equal(10, run.xp, "and it was worth something")
  local health = run.health
  abbeyHold(walker, {}, 200)
  equal(health, run.health)
  assert(abbeyStrips(walker, mob) > 0, "still to be seen")
  equal("active", match.status)

  -- Backing away is slower than going at them
  local x, y = walker.pose.x, walker.pose.y
  abbeyHold(walker, { "S" }, 5)
  local back = math.sqrt((walker.pose.x - x) ^ 2 + (walker.pose.y - y) ^ 2)
  abbeyHold(walker, { "W" }, 5)
  assert(math.abs(walker.pose.x - x) + math.abs(walker.pose.y - y) < back * 0.75, "further forward than back")
end

function tests.WarcraftsteinFoesHuntThePlayer()
  local player, match, walker = abbeyOnScreen(6)
  local state = player.private.Match.State(match)
  local mob = abbeyMeet(state, walker)
  local run = walker.run
  -- One that wakes tells the ones around it that see it, and nobody behind a wall
  local other = run.mobs[#run.mobs] ~= mob and run.mobs[#run.mobs] or run.mobs[1]
  local behind = run.mobs[#run.mobs - 1] ~= mob and run.mobs[#run.mobs - 1] or run.mobs[2]
  other.dead, other.x, other.y = false, mob.x, mob.y
  behind.dead, behind.x, behind.y = false, mob.x, mob.y
  while state.cells[abbeySquare(state, behind.x, behind.y)] == 0 do
    behind.x = behind.x + 1
  end
  behind.x = behind.x + 1
  if state.cells[abbeySquare(state, behind.x, behind.y)] ~= 0 or (behind.x - mob.x) > 4 then
    behind.x = mob.x
    behind.dead = true
  end
  abbeyHold(walker, {}, 2)
  equal(true, mob.awake)
  equal(true, other.awake)
  if not behind.dead then
    equal(false, behind.awake, "nobody who didn't see it")
  end
  other.dead, behind.dead = true, true

  -- The player gone to where it can't see them: it comes after them through the monastery
  local trail = walker:trail()
  local fromMob = {}
  local queue, index = { abbeySquare(state, mob.x, mob.y) }, 1
  fromMob[queue[1]] = 0
  while queue[index] do
    local square = queue[index]
    index = index + 1
    for _, next in ipairs(abbeyNeighbours(state, square)) do
      if state.cells[next] == 0 and not fromMob[next] then
        fromMob[next] = fromMob[square] + 1
        queue[#queue + 1] = next
      end
    end
  end
  local sanctuary = state.rooms[1]
  local away = nil
  for square, steps in pairs(fromMob) do
    local x, y = (square - 1) % state.side + 0.5, math.floor((square - 1) / state.side) + 0.5
    local outside = not (x >= sanctuary.x and x < sanctuary.x + sanctuary.w and y >= sanctuary.y and y < sanctuary.y + sanctuary.h)
    if outside and steps >= 8 and steps <= 12 and (not away or square < away) then
      away = square
    end
  end
  assert(trail and away, "somewhere to go")
  walker.pose.x, walker.pose.y = (away - 1) % state.side + 0.5, math.floor((away - 1) / state.side) + 0.5
  abbeyHold(walker, {}, 1)
  local function walk()
    return walker:trail()[abbeySquare(state, mob.x, mob.y)]
  end
  local far = walk()
  assert(far >= 4)
  abbeyHold(walker, {}, 100)
  equal(true, mob.awake)
  assert(walk() <= far - 3, "nearer by the way there is: " .. walk() .. " from " .. far)
  -- Until it has them, or hasn't seen them for too long
  abbeyHold(walker, {}, 700)
  assert(run.health < 120 or not mob.awake)
  if far <= 16 then
    assert(run.health < 120, "which it has from this near")
  end
end

function tests.WarcraftsteinAdeptsCastFromAfar()
  local player, match, walker = abbeyOnScreen(9)
  local state = player.private.Match.State(match)
  local mob = abbeyMeet(state, walker, "adept")
  local run = walker.run
  -- Room to back away into: the player a step back from where they were
  abbeyHold(walker, {}, 2)
  equal(true, mob.awake)
  abbeyHold(walker, {}, 150)
  assert(run.health < 120, "something hit")
  local cast = false
  for _ = 1, 200 do
    abbeyHold(walker, {}, 1)
    cast = cast or #run.shots > 0
  end
  assert(cast, "bolts on their way")
  local away = math.sqrt((mob.x - walker.pose.x) ^ 2 + (mob.y - walker.pose.y) ^ 2)
  assert(away > 0.95, "and from further than arm's length when it can: " .. away)
end

function tests.WarcraftsteinHerodKeepsThePortal()
  local player, match, walker = abbeyOnScreen(6)
  local Match = player.private.Match
  local state = Match.State(match)
  local run = walker.run
  local herod = assert(run.boss)
  for _, mob in ipairs(run.mobs) do
    mob.dead = mob ~= herod
  end
  run.health, run.spec.health = 1e6, 1e6
  -- In front of the portal, walking into it: shut
  local _, way = abbeyWalk(state)
  local portal, before = way[#way], way[#way - 1]
  local side = state.side
  walker.pose.x, walker.pose.y = (before - 1) % side + 0.5, math.floor((before - 1) / side) + 0.5
  walker.pose.facing = math.atan2(math.floor((portal - 1) / side) + 0.5 - walker.pose.y, (portal - 1) % side + 0.5 - walker.pose.x)
  herod.frozen = 1000
  abbeyHold(walker, { "W" }, 30)
  equal("active", match.status, "not while Herod stands")
  equal(true, walker.said:IsShown())

  -- He comes for the player, spinning, and shows how he is
  herod.frozen, herod.x, herod.y = 0, walker.pose.x - math.cos(walker.pose.facing), walker.pose.y - math.sin(walker.pose.facing)
  if state.cells[abbeySquare(state, herod.x, herod.y)] ~= 0 then
    herod.x, herod.y = walker.pose.x, walker.pose.y
  end
  abbeyHold(walker, {}, 3)
  equal(true, herod.awake)
  equal(true, walker.bossBar:IsShown())
  equal(herod.foe.health, walker.bossBar.value)
  local spun = false
  for _ = 1, 100 do
    abbeyHold(walker, {}, 1)
    spun = spun or herod.spinning > 0
  end
  assert(spun, "Blades of Light!")
  assert(run.health < 1e6)

  -- Angry once he is hurt enough
  walker:wound(herod, herod.foe.health * 0.75)
  equal(true, herod.angry)
  -- And once he falls the portal opens
  walker:wound(herod, herod.health)
  equal(true, herod.dead)
  equal(nil, run.boss)
  abbeyHold(walker, {}, 1)
  equal(false, walker.bossBar:IsShown())
  assert(run.level > 1, "worth a level or two by himself")
  walker.pose.x, walker.pose.y = (before - 1) % side + 0.5, math.floor((before - 1) / side) + 0.5
  walker.pose.facing = math.atan2(math.floor((portal - 1) / side) + 0.5 - walker.pose.y, (portal - 1) % side + 0.5 - walker.pose.x)
  abbeyHold(walker, { "W" }, 30)
  equal(true, Match.State(match).found)
end

function tests.WarcraftsteinHasASanctuary()
  local player, match, walker = abbeyOnScreen(6)
  local state = player.private.Match.State(match)
  local run, sanctuary = walker.run, state.rooms[1]
  abbeyHold(walker, {}, 1)
  equal(true, run.safe, "the player begins in it")
  equal(true, walker.said:IsShown(), "and is told so")
  equal(true, walker.veil:IsShown(), "and sees it")
  -- The fountain in front of them, its water moving
  local fountain = run.decor[1]
  equal("fountain", fountain.kind)
  assert(abbeyStrips(walker, fountain) > 0, "to be seen")
  local first = fountain.picture
  for _, strip in ipairs(walker.lit) do
    if strip.shows == fountain then
      first = strip.shows.picture
    end
  end
  -- The water runs, one picture and then the other, and the fountain is there all along
  local shown = {}
  for _ = 1, 100 do
    abbeyHold(walker, {}, 1)
    assert(abbeyStrips(walker, fountain) > 0, "the fountain stays")
    shown[fountain.picture] = true
  end
  equal(true, shown[first], "the one picture")
  equal(true, shown[first == 33 and 34 or 33], "and the other")
  local pictures = 0
  for _ in pairs(shown) do
    pictures = pictures + 1
  end
  equal(2, pictures, "and no others")

  -- Nobody of the Crusade sees the player in here, nor hurts them, even right beside them
  local mob = run.mobs[1]
  for _, other in ipairs(run.mobs) do
    other.dead = other ~= mob
  end
  run.boss = nil
  mob.kind, mob.foe, mob.health = "soldier", walker.foes.soldier, walker.foes.soldier.health
  mob.x, mob.y = walker.pose.x + 0.8 * math.cos(walker.pose.facing + math.pi / 2), walker.pose.y + 0.8 * math.sin(walker.pose.facing + math.pi / 2)
  if state.cells[abbeySquare(state, mob.x, mob.y)] ~= 0 then
    mob.x, mob.y = walker.pose.x - 0.8 * math.cos(walker.pose.facing + math.pi / 2), walker.pose.y - 0.8 * math.sin(walker.pose.facing + math.pi / 2)
  end
  abbeyHold(walker, {}, 100)
  equal(false, mob.awake)
  equal(120, run.health)
  -- Nor is there any fighting: no blow, no whirlwind
  run.power = 100
  abbeyHold(walker, { "SPACE", "F" }, 20)
  equal(0, run.swung)
  equal(100, run.power)
  equal(45, mob.health)
  -- But health comes back quickly
  run.health = 50
  abbeyHold(walker, {}, 50)
  equal("58.0", string.format("%.1f", run.health))

  -- Nobody walks in, however much they would like to
  local door = nil
  for row = sanctuary.y - 1, sanctuary.y + sanctuary.h do
    for column = sanctuary.x - 1, sanctuary.x + sanctuary.w do
      local outside = column < sanctuary.x or row < sanctuary.y or column >= sanctuary.x + sanctuary.w or row >= sanctuary.y + sanctuary.h
      if outside and state.cells[row * state.side + column + 1] == 0 then
        door = door or { column + 0.5, row + 0.5 }
      end
    end
  end
  assert(door, "a way in")
  mob.x, mob.y, mob.awake = door[1], door[2], true
  for _ = 1, 50 do
    walker:step(mob, state.start.x, state.start.y, 0.1)
    assert(not (mob.x >= sanctuary.x and mob.x < sanctuary.x + sanctuary.w and mob.y >= sanctuary.y and mob.y < sanctuary.y + sanctuary.h), "not a foot inside")
  end
  -- And what is cast at the player goes out at the door
  run.shots[1] = { x = door[1], y = door[2], byX = (walker.pose.x - door[1]), byY = (walker.pose.y - door[2]), speed = 5, hits = 13, tint = { 1, 1, 1 } }
  local length = math.sqrt(run.shots[1].byX ^ 2 + run.shots[1].byY ^ 2)
  run.shots[1].byX, run.shots[1].byY = run.shots[1].byX / length, run.shots[1].byY / length
  local health = run.health
  abbeyHold(walker, {}, 60)
  equal(0, #run.shots)
  assert(run.health >= health)

  -- Out of it, it is a fight again, and the gold is gone
  walker.pose.x, walker.pose.y = door[1], door[2]
  abbeyHold(walker, {}, 1)
  equal(false, run.safe)
  equal(false, walker.veil:IsShown())
end

function tests.WarcraftsteinWalksRoundWhatStandsAbout()
  local player, match, walker = abbeyOnScreen(6)
  local state = player.private.Match.State(match)
  local pose, run = walker.pose, walker.run
  local fountain = run.decor[1]
  equal("fountain", fountain.kind)
  -- Straight at the fountain from where the player begins: round it and on, not stopped by it
  local x, y = pose.x, pose.y
  local aheadX, aheadY = math.cos(pose.facing), math.sin(pose.facing)
  local nearest = math.huge
  for _ = 1, 40 do
    abbeyHold(walker, { "W" }, 1)
    nearest = math.min(nearest, math.sqrt((pose.x - fountain.x) ^ 2 + (pose.y - fountain.y) ^ 2))
  end
  local gone = (pose.x - x) * aheadX + (pose.y - y) * aheadY
  assert(gone > 1.2, "past it: " .. gone)
  assert(nearest >= 0.42 + 0.22 - 0.01, "and never into it: " .. nearest)

  -- A candelabra is a pole: it is only in the way of whoever walks right into the pole
  for _, item in ipairs(run.decor) do
    if item.kind == "candelabra" then
      equal(true, item.girth < 0.1)
    end
  end
  -- Sideways along the edge of the fountain, nothing in the way at all
  pose.x, pose.y = fountain.x - aheadY * 0.7 - aheadX * 0.7, fountain.y + aheadX * 0.7 - aheadY * 0.7
  if state.cells[abbeySquare(state, pose.x, pose.y)] == 0 then
    local before = (pose.x - fountain.x) * aheadX + (pose.y - fountain.y) * aheadY
    abbeyHold(walker, { "W" }, 20)
    assert((pose.x - fountain.x) * aheadX + (pose.y - fountain.y) * aheadY > before + 0.6, "along it")
  end
end

function tests.WarcraftsteinEndsWithThePlayerDead()
  local player, match, walker = abbeyOnScreen(6)
  local Match = player.private.Match
  abbeyMeet(Match.State(match), walker)
  walker.run.health = 10
  abbeyHold(walker, {}, 200)
  equal(0, walker.run.health)
  equal(true, Match.State(match).dead)
  equal("finished", match.status)
  equal(0, Match.Result(match).winner)
  equal(true, walker.effects:HasBanner(), "it says so across what was seen")
  equal(nil, player.session:Best("warcraftstein", "rooms6"), "which is nothing to be proud of")
  equal(0, walker.health.value)
end

function tests.WarcraftsteinAsksWhoGoesIn()
  local player, match, walker = abbeyOnScreen(6, false)
  local Match = player.private.Match
  equal(true, walker.picker:IsShown())
  equal(nil, walker.run)
  equal(false, walker.health:IsShown())
  abbeyHold(walker, { "W" }, 5)
  equal(nil, Match.State(match).class, "walking isn't an answer")
  -- Space is: the class of the character, a warrior for one of a class the monastery doesn't know
  function UnitClass()
    return "Mage", "MAGE"
  end
  walker.ticker:Fire("OnKeyDown", "SPACE")
  UnitClass = nil
  equal("MAGE", Match.State(match).class)
  equal(false, walker.picker:IsShown())
  equal(80, walker.run.health)
  equal(100, walker.run.power)
  equal(true, walker.health:IsShown())
  assert(walker.ability.icon.texture:find("FrostNova"))

  -- Or a click on any of them
  player, match, walker = abbeyOnScreen(6, false)
  local picks = 0
  for _ in pairs(walker.picks) do
    picks = picks + 1
  end
  equal(9, picks)
  walker.picks.ROGUE:Fire("OnClick")
  equal("ROGUE", player.private.Match.State(match).class)
  equal(90, walker.run.health)
  walker.picks.MAGE:Fire("OnClick")
  equal("ROGUE", player.private.Match.State(match).class, "once")

  function UnitClass()
    return "Monk", "MONK"
  end
  player, match, walker = abbeyOnScreen(6, false)
  walker.ticker:Fire("OnKeyDown", "SPACE")
  UnitClass = nil
  equal("WARRIOR", player.private.Match.State(match).class)
end

function tests.WarcraftsteinEveryClassCanFight()
  for _, class in ipairs({ "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }) do
    local player, match, walker = abbeyOnScreen(6, class)
    local state = player.private.Match.State(match)
    local mob = abbeyMeet(state, walker)
    equal(class, walker.run.class)
    abbeyHold(walker, { "SPACE" }, 400)
    equal(true, mob.dead, class .. " gets the better of a soldier")
    assert(walker.run.health > 0, class .. " lives to tell of it")
    equal("active", match.status)
    abbeyHold(walker, {}, 100)
    equal(0, #walker.run.bolts, "nothing left in the air")
  end
end

function tests.WarcraftsteinClassesDoWhatTheyDo()
  --- @param class string
  --- @return table walker, table run, table mob
  local function meet(class)
    local player, match, walker = abbeyOnScreen(6, class)
    return walker, walker.run, abbeyMeet(player.private.Match.State(match), walker)
  end

  -- A warrior needs rage for it, and hits everything around
  local walker, run, mob = meet("WARRIOR")
  abbeyHold(walker, { "F" }, 2)
  equal(45, mob.health, "nothing without rage")
  equal(false, walker.ticker.propagates)
  run.power = 30
  abbeyHold(walker, { "F" }, 2)
  equal(15, mob.health)
  assert(run.power < 30)
  assert(run.ready > 0)
  equal(1, walker.ability.waits, "it says how long until the next")

  -- Nothing hurts a paladin for a while
  walker, run, mob = meet("PALADIN")
  abbeyHold(walker, { "F" }, 1)
  equal(60, run.power)
  abbeyHold(walker, {}, 150)
  equal(110, run.health)
  equal(true, mob.awake)
  abbeyHold(walker, {}, 100)
  assert(run.health < 110, "and then it does again")

  -- A hunter's arrow is worth half from this near, and all of it from further away
  walker, run, mob = meet("HUNTER")
  abbeyHold(walker, { "SPACE" }, 1)
  equal(38, mob.health)
  mob.frozen = 100
  walker.pose.x, walker.pose.y = walker.pose.x * 2 - mob.x, walker.pose.y * 2 - mob.y
  if walker.view.state.cells[abbeySquare(walker.view.state, walker.pose.x, walker.pose.y)] ~= 0 then
    walker.pose.x, walker.pose.y = (walker.pose.x + mob.x) / 2, (walker.pose.y + mob.y) / 2
  end
  abbeyHold(walker, { "F" }, 1)
  equal(24, mob.health, "everyone in sight")
  equal(65, math.floor(run.power))

  -- Nobody sees a rogue, and the first blow out of nowhere is worth three
  walker, run, mob = meet("ROGUE")
  abbeyHold(walker, { "F" }, 1)
  abbeyHold(walker, {}, 100)
  equal(false, mob.awake)
  equal(90, run.health)
  abbeyHold(walker, { "SPACE" }, 1)
  equal(21, mob.health)
  equal(nil, run.buff, "which is the end of hiding")
  equal(true, mob.awake)
  abbeyHold(walker, { "SPACE" }, 14)
  equal(13, mob.health, "and the next is worth one")

  -- A priest heals, but not what isn't hurt
  walker, run = meet("PRIEST")
  abbeyHold(walker, { "F" }, 1)
  equal(100, run.power)
  run.health = 20
  abbeyHold(walker, { "F" }, 1)
  equal(60, run.health)
  equal(65, math.floor(run.power))

  -- A shaman's totem fights on its own for as long as it stands
  walker, run, mob = meet("SHAMAN")
  mob.frozen = 1000
  abbeyHold(walker, { "F" }, 1)
  assert(run.totem, "a totem")
  assert(abbeyStrips(walker, run.totem) > 0, "to be seen")
  abbeyHold(walker, {}, 120)
  equal(21, mob.health, "three times in two seconds and a bit")
  abbeyHold(walker, {}, 600)
  equal(nil, run.totem)
  equal(true, mob.dead, "it was the end of that one")
  -- And their lightning jumps on to the next
  local other = run.mobs[#run.mobs] ~= mob and run.mobs[#run.mobs] or run.mobs[1]
  other.dead, other.frozen, other.x, other.y, other.foe, other.health = false, 1000, mob.x, mob.y, mob.foe, 45
  mob.health, mob.dead = 45, false
  abbeyHold(walker, { "SPACE" }, 12)
  equal("32,38.5", math.min(mob.health, other.health) .. "," .. math.max(mob.health, other.health))

  -- A mage freezes what is near
  walker, run, mob = meet("MAGE")
  abbeyHold(walker, { "F" }, 1)
  equal(40, mob.health)
  assert(mob.frozen > 3)
  abbeyHold(walker, {}, 150)
  equal(80, run.health, "and what is frozen does nothing")
  abbeyHold(walker, {}, 150)
  assert(run.health < 80, "until it thaws")

  -- A warlock trades health for mana, and gets some back from every bolt that lands
  walker, run, mob = meet("WARLOCK")
  abbeyHold(walker, { "F" }, 1)
  equal(90, run.health, "not with all the mana there is")
  run.power, mob.frozen = 0, 100
  abbeyHold(walker, { "F" }, 1)
  equal(75, run.health)
  equal(30, math.floor(run.power))
  abbeyHold(walker, { "SPACE" }, 12)
  equal(27, mob.health)
  equal("79.5", string.format("%.1f", run.health))

  -- A druid has claws for a while, and is quicker on its feet
  walker, run, mob = meet("DRUID")
  mob.frozen = 100
  abbeyHold(walker, { "F" }, 1)
  assert(run.buff)
  abbeyHold(walker, { "SPACE" }, 1)
  equal(34, mob.health)
  equal(0, #run.bolts)
  abbeyHold(walker, {}, 420)
  equal(nil, run.buff)
  abbeyHold(walker, { "SPACE" }, 1)
  equal(1, #run.bolts, "and bolts again after")
end

function tests.WarcraftsteinLevelsAndTalents()
  local player, match, walker = abbeyOnScreen(6)
  local state = player.private.Match.State(match)
  local run = walker.run
  equal(1, run.level)
  equal(0, run.points)

  -- A kill that tips it over is a level, and a point
  local mob = abbeyMeet(state, walker)
  run.xp = 25
  walker:wound(mob, 100, run.spec.attack)
  equal(2, run.level)
  equal(5, run.xp)
  equal(1, run.points)
  walker:gauge()
  equal(1, walker.talents.shown)

  -- N opens the book, and while it is open nothing happens
  local other = run.mobs[#run.mobs] ~= mob and run.mobs[#run.mobs] or run.mobs[1]
  other.dead, other.x, other.y = false, mob.x, mob.y
  walker.ticker:Fire("OnKeyDown", "N")
  equal(true, walker.book:IsShown())
  abbeyHold(walker, {}, 100)
  equal(false, other.awake, "the monastery waits")
  equal(120, run.health)

  -- A talent further down a tree needs points in it first
  equal(false, walker:learn(1, 2))
  equal(false, walker:learn(3, 3))
  equal(true, walker:learn(1, 1))
  equal(1, run.learned.sharpened)
  equal("17.25", string.format("%.2f", run.spec.attack.hits))
  equal(0, run.points)
  equal("1/2", walker.tiles[1][1].rank:GetText())
  equal(false, walker:learn(1, 1), "not without a point")
  run.points = 3
  equal(true, walker:learn(1, 1))
  equal(false, walker:learn(1, 1), "two ranks and no more")
  equal("19.5", string.format("%.1f", run.spec.attack.hits))
  equal(true, walker:learn(1, 2), "two in the tree open the next")
  equal(0.6, run.spec.attack.splash)
  equal(false, walker:learn(1, 3))
  equal(true, walker:learn(3, 1))
  equal("0.62", string.format("%.2f", run.spec.armor), "on top of the armour a warrior has anyway")
  walker:explain(walker.tiles[3][1], 3, 1)
  -- Escape closes it
  walker.ticker:Fire("OnKeyDown", "ESCAPE")
  equal(false, walker.book:IsShown())

  -- Every talent of every class can be learnt, and changes something
  for _, class in ipairs({ "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }) do
    player, match, walker = abbeyOnScreen(6, class)
    run = walker.run
    run.points = 15
    for tree, trees in ipairs(walker.trees[class]) do
      for tier, known in ipairs(trees.talents) do
        for rank = 1, known.ranks do
          local before = run.spec
          assert(walker:learn(tree, tier), class .. " " .. known.id .. " rank " .. rank)
          assert(before ~= run.spec, "learning makes the class anew")
          -- And every number it is about is another one now
          for _, mod in ipairs(known.mods) do
            local function find(spec)
              local value = spec
              for part in mod[1]:gmatch("[^.]+") do
                value = value and value[part]
              end
              return value
            end
            assert(find(run.spec) ~= nil and find(run.spec) ~= find(before), class .. " " .. known.id .. " changes " .. mod[1])
          end
        end
      end
    end
    equal(0, run.points)
    -- Everything learnt and all of it still a fight
    local mob = abbeyMeet(player.private.Match.State(match), walker)
    abbeyHold(walker, { "SPACE" }, 400)
    equal(true, mob.dead, class .. " with every talent")
  end
end

function tests.WarcraftsteinPotionsAreDrunk()
  local player, match, walker = abbeyOnScreen(6, "MAGE")
  local run = walker.run
  for _, item in ipairs(run.decor) do
    item.girth = nil
  end
  local potions = #run.loot
  local health, power
  for _, potion in ipairs(run.loot) do
    health = potion.kind == "health" and potion or health
    power = potion.kind == "power" and potion or power
  end
  -- Not by anyone who has no use for it. Out of the sanctuary, which gives health back by itself
  walker.pose.x, walker.pose.y = health.x, health.y
  abbeyHold(walker, {}, 2)
  equal(potions, #run.loot)
  run.health = 30
  abbeyHold(walker, {}, 2)
  equal(65, run.health)
  equal(potions - 1, #run.loot)
  equal(65, walker.health.value)

  run.power = 80
  power.x, power.y = walker.pose.x, walker.pose.y
  abbeyHold(walker, {}, 2)
  equal(100, run.power, "never more than there is room for")
  equal(potions - 2, #run.loot)
  equal("active", match.status)
end

function tests.WarcraftsteinGetsRoundCorners()
  local player, match, walker = abbeyOnScreen(9)
  local state = player.private.Match.State(match)
  local pose, side = walker.pose, state.side
  for _, mob in ipairs(walker.run.mobs) do
    mob.dead = true
  end
  walker.run.boss = nil
  walker.run.decor = {}
  local function open(column, row)
    return state.cells[row * side + column + 1] == 0
  end
  local function off(angle)
    return math.abs((pose.facing - angle + math.pi) % (math.pi * 2) - math.pi)
  end

  -- A turn begins gently and is soon as quick as it gets
  local facing = pose.facing
  abbeyHold(walker, { "D" }, 1)
  local first = (pose.facing - facing) % (math.pi * 2)
  assert(first > 0 and first < 3.6 * 0.02 * 0.6, "a tap is a small correction: " .. first)
  walker.ticker:Fire("OnKeyDown", "D")
  for _ = 1, 10 do
    walker.ticker:Fire("OnUpdate", 0.02)
  end
  local before = pose.facing
  walker.ticker:Fire("OnUpdate", 0.02)
  walker.ticker:Fire("OnKeyUp", "D")
  equal("0.072", string.format("%.3f", (pose.facing - before) % (math.pi * 2)), "all of it after a moment")

  -- The mouse turns with the right button held, and then the keys that turn step aside
  Client.mouseDown, Client.cursor = true, { 500, 300 }
  walker.ticker:Fire("OnUpdate", 0.02)
  facing = pose.facing
  Client.cursor = { 600, 300 }
  walker.ticker:Fire("OnUpdate", 0.02)
  equal("0.600", string.format("%.3f", (pose.facing - facing) % (math.pi * 2)))
  facing = pose.facing
  abbeyHold(walker, { "A" }, 5)
  abbeyHold(walker, { "D" }, 5)
  equal(facing, pose.facing, "no turning with the keys meanwhile")
  -- And goes on turning with the cursor off the game, for as long as the button is held
  Client.over, Client.cursor = false, { 500, 300 }
  walker.ticker:Fire("OnUpdate", 0.02)
  equal("5.683", string.format("%.3f", (pose.facing - facing) % (math.pi * 2)))
  Client.over, Client.mouseDown = true, false
  walker.ticker:Fire("OnUpdate", 0.02)
  equal(nil, walker.dragged)

  -- A corner that is only just in the way: a shoulder in the next square, the way to go beside it
  local found = false
  for row = 1, side - 3 do
    for column = 1, side - 3 do
      if not found and open(column, row) and open(column + 1, row) and open(column, row + 1) and not open(column + 1, row + 1) and open(column, row + 2) then
        found = true
        pose.x, pose.y, pose.facing = column + 1 - 0.22 + 0.1, row + 0.5, math.pi / 2
        abbeyHold(walker, { "W" }, 30)
        assert(pose.y > row + 1, "round it and on: " .. pose.y)
        assert(pose.x + 0.22 <= column + 1, "by stepping aside")
        -- But not one that is squarely in the way
        pose.x, pose.y, pose.facing = column + 1 - 0.22 + 0.4, row + 0.5, math.pi / 2
        abbeyHold(walker, { "W" }, 30)
        assert(pose.y < row + 1, "that is a wall")
      end
    end
  end
  equal(true, found, "a corner to try it at")

  -- Walked into at an angle, a wall is slid along, and the player turned to look where they go
  found = false
  for row = 1, side - 2 do
    for column = 1, side - 4 do
      local corridor = not found
      for along = column, column + 2 do
        corridor = corridor and open(along, row) and not open(along, row - 1) and not open(along, row + 1)
      end
      if corridor then
        found = true
        pose.x, pose.y, pose.facing = column + 0.3, row + 0.5, 0.5
        abbeyHold(walker, { "W" }, 8)
        equal("0.500", string.format("%.3f", pose.facing), "not before there is a wall")
        abbeyHold(walker, { "W" }, 25)
        assert(off(0) < 0.01, "along the corridor: " .. pose.facing)
        assert(pose.x > column + 1)
        -- Not while stepping sideways, which is meant
        pose.x, pose.y, pose.facing = column + 0.3, row + 0.5, 0.5
        abbeyHold(walker, { "W", "E" }, 30)
        equal("0.500", string.format("%.3f", pose.facing))
      end
    end
  end
  equal(true, found, "a corridor to try it in")
end
end

-----------------------------
-- Wormcraft
-----------------------------

--- Everything about a position that has to come out the same on every client
--- @param state table
--- @return string
local function wormDigest(state)
  local parts = {}
  for _, spans in ipairs(state.columns) do
    parts[#parts + 1] = table.concat(spans, ",")
  end
  for _, unit in ipairs(state.units) do
    parts[#parts + 1] = table.concat({ unit.x, unit.y, unit.hp, tostring(unit.alive), unit.facing }, ",")
  end
  for _, body in ipairs(state.bodies) do
    parts[#parts + 1] = body.kind .. body.x .. "," .. body.y .. (body.loot or "")
  end
  for seat, team in ipairs(state.teams) do
    local ids = {}
    for id, charges in pairs(team.arsenal) do
      ids[#ids + 1] = id .. charges
    end
    table.sort(ids)
    parts[#parts + 1] = seat .. tostring(team.out) .. team.next .. table.concat(ids)
  end
  parts[#parts + 1] = table.concat({ state.turn, state.turns, state.wind, state.round, state.level, state.sea }, "/")
  return table.concat(parts, ";")
end

--- A game of Wormcraft on a flat island, with everybody's class picked: the first squad stands
--- at 200 across, the second at 600, facing each other, and there is no wind
--- @param private table
--- @param level number? How far down the ground is, 300 if left out
--- @param squad number?
--- @return table state
local function wormFlat(private, level, squad)
  local Wormcraft = private.Wormcraft
  level = level or 300
  local state = Wormcraft.newState(2, private.Random.New(3), { squad = squad or 1 })
  for column = 1, #state.columns do
    state.columns[column] = { level, 512 }
  end
  for index, unit in ipairs(state.units) do
    unit.x = ((index % 2 == 1 and 200 or 600) + math.floor((index - 1) / 2) * 40) * 256 + 128
    unit.y = (level - 1) * 256 + 128
    unit.facing = index % 2 == 1 and 1 or -1
  end
  Wormcraft.apply(state, 1, "cMAGE")
  Wormcraft.apply(state, 2, "cWARRIOR")
  state.wind = 0
  return state
end

--- Plays a sim until the turn is over
--- @param sim table
--- @return number ticks
local function wormSettle(sim)
  local ticks = 0
  while sim.phase ~= "done" and ticks < 3000 do
    sim:Step(nil)
    ticks = ticks + 1
  end
  equal("done", sim.phase, "the turn comes to an end")
  return ticks
end

--- What a sim says happened, of one kind
--- @param sim table
--- @param kind string
--- @return table[]
local function wormHappened(sim, kind)
  local found = {}
  for _, what in ipairs(sim.happened) do
    if what.kind == kind then
      found[#found + 1] = what
    end
  end
  return found
end

function tests.WormcraftRaisesAnIsland()
  local private = loadEngine()
  local Wormcraft = private.Wormcraft
  for _, seats in ipairs({ 2, 3, 4 }) do
    for seed = 1, 25 do
      local state = Wormcraft.newState(seats, private.Random.New(seed), { squad = 4 })
      equal(seats * 4, #state.units, "a squad for every player")
      assert(state.theme == "elwynn" or state.theme == "durotar" or state.theme == "winterspring" or state.theme == "steppes")
      equal(true, state.picking, "nobody has said who they are yet")
      for _, spans in ipairs(state.columns) do
        for index = 1, #spans, 2 do
          assert(spans[index] < spans[index + 1], "every stretch of ground is some of it")
          assert(index == 1 or spans[index - 1] < spans[index], "from the top down, apart")
        end
      end
      for index, unit in ipairs(state.units) do
        local x, y = math.floor(unit.x / 256), math.floor(unit.y / 256)
        equal(true, Wormcraft.solid(state.columns, x, y + 1), "everybody stands on something")
        equal(false, Wormcraft.solid(state.columns, x, y), "and not in it")
        assert(y < state.sea - 20, "well out of the sea")
        for other = index + 1, #state.units do
          assert(math.abs(state.units[other].x - unit.x) >= 16 * 256, "nobody on top of anybody")
        end
        equal(100, unit.hp)
      end
    end
  end
  local one, other = Wormcraft.newState(2, private.Random.New(9), {}), Wormcraft.newState(2, private.Random.New(9), {})
  equal(wormDigest(one), wormDigest(other), "the same island from the same seed")
  equal("durotar", Wormcraft.newState(2, private.Random.New(9), { map = "durotar" }).theme)
  equal(6, #Wormcraft.newState(2, private.Random.New(9), { squad = 3 }).units)
end

function tests.WormcraftPicksClassesInTurn()
  local private = loadEngine()
  local Wormcraft = private.Wormcraft
  local game = private.Games.Get("wormcraft")
  local state = game.newState(3, private.Random.New(1), private.Games.Rules(game.options))
  equal(1, game.turn(state))
  equal(false, (game.validate(state, 1, "cGNOME")))
  equal(false, (game.validate(state, 1, "1W10")), "nobody plays before everybody has said who they are")
  equal(false, (game.validate(state, 2, "cMAGE")), "in seat order")
  assert(game.validate(state, 1, "cMAGE"))
  game.apply(state, 1, "cMAGE")
  equal("MAGE", state.teams[1].class)
  equal(3, state.teams[1].arsenal.bl, "with what their class can do")
  equal(nil, state.teams[2].arsenal.bl)
  equal(2, game.turn(state))
  game.apply(state, 2, "cMAGE")
  equal(3, game.turn(state), "two of the same is fine")
  game.drop(state, 3)
  equal(false, state.picking, "the one who left doesn't hold the others up")
  equal(1, game.turn(state))
  equal(nil, game.result(state))
  for _, unit in ipairs(state.units) do
    equal(unit.team ~= 3, unit.alive)
  end
  equal(-1, state.teams[1].arsenal.fb, "fireballs for as long as there are any")
  equal(nil, state.teams[1].arsenal.sh, "but sheep only from the third level on")
end

function tests.WormcraftReadsMoves()
  local private = loadEngine()
  local Wormcraft = private.Wormcraft
  local slot, inputs = Wormcraft.decode("2R30JW12Ffb.45.80L20X")
  equal(2, slot)
  equal(6, #inputs)
  equal("R", inputs[1][1])
  equal(30, inputs[1][2])
  equal("J", inputs[2][1])
  equal(false, inputs[3][1], "standing still")
  equal("fb", inputs[4][1].use)
  equal("45,80", table.concat(inputs[4][1].args, ","))
  equal(true, inputs[4][1].fire)
  equal("X", inputs[6][1])
  slot, inputs = Wormcraft.decode("1Ubl.300.-2")
  equal(-2, inputs[1][1].args[2])
  equal(false, inputs[1][1].fire)
  for _, bad in ipairs({ "", "R10", "1R", "1R0", "1Fzz.1", "1Ffb.", "1Q", "1Ffbx", "1Ufb.10.10" }) do
    equal(nil, (Wormcraft.decode(bad)), bad)
  end
  equal(nil, (Wormcraft.decode("1" .. string.rep("J", Wormcraft.LONGEST))), "too long to send")

  local state = wormFlat(private)
  local game = private.Games.Get("wormcraft")
  assert(game.validate(state, 1, "1R30W10Ffb.45.80L30"))
  assert(game.validate(state, 1, "1W1350"), "the whole turn spent standing about")
  equal(false, (game.validate(state, 1, "1W1351")), "but no more than the whole turn")
  equal(false, (game.validate(state, 1, "1Ffb.45.80L91")), "and only three seconds to run in after")
  equal(false, (game.validate(state, 2, "1W10")), "only on your turn")
  equal(false, (game.validate(state, 1, "2W10")), "with somebody of your own squad")
  equal(false, (game.validate(state, 1, "1Ffb.45.80Fgr.45.80.3")), "firing once")
  equal(false, (game.validate(state, 1, "1Ffb.45")), "aimed the way it is aimed")
  equal(false, (game.validate(state, 1, "1Ffb.45.101")))
  equal(false, (game.validate(state, 1, "1Fgr.45.50.6")))
  equal(false, (game.validate(state, 1, "1Fsh")), "not before it is learned")
  assert(game.validate(state, 1, "1Ubl.230.290Ubl.230.290Ubl.230.290W10"))
  equal(false, (game.validate(state, 1, "1Ubl.230.290Ubl.230.290Ubl.230.290Ubl.230.290")), "as often as there are charges")
  equal(false, (game.validate(state, 1, "1Uch")), "nor somebody else's class's")
end

function tests.WormcraftWalksJumpsAndFalls()
  local private = loadEngine()
  local Wormcraft = private.Wormcraft
  local state = wormFlat(private)
  local sim = Wormcraft.Sim.New(state, 1, true)
  local unit = sim.unit
  for _ = 1, 30 do
    sim:Step(nil)
  end
  equal(200 * 256 + 128, unit.x, "nobody moves who isn't moved")
  for _ = 1, 40 do
    sim:Step("R")
  end
  equal(240 * 256 + 128, unit.x, "a unit a tick")
  for _ = 1, 10 do
    sim:Step("L")
  end
  equal(-1, unit.facing)
  equal(230 * 256 + 128, unit.x)
  sim:Step("J")
  equal(true, unit.air)
  local ticks = 0
  while unit.air and ticks < 100 do
    sim:Step(nil)
    ticks = ticks + 1
  end
  assert(unit.x < 230 * 256 - 20 * 256, "jumps go forwards")
  equal(299 * 256 + 128, unit.y, "and come down again")
  equal(100, unit.hp)
  assert(state.units[1].x == 200 * 256 + 128, "the game's own state isn't changed by a sim")

  -- Up a step, but not up a wall
  state = wormFlat(private)
  for column = 56, 57 do
    state.columns[column] = { 295, 512 }
  end
  for column = 58, 62 do
    state.columns[column] = { 270, 512 }
  end
  sim = Wormcraft.Sim.New(state, 1, true)
  for _ = 1, 40 do
    sim:Step("R")
  end
  equal(294 * 256 + 128, sim.unit.y, "up a step")
  equal(227 * 256 + 128, sim.unit.x, "against the wall")

  -- Off the edge of something high, and hurt by the fall
  state = wormFlat(private, 400)
  for column = 40, 55 do
    state.columns[column] = { 150, 512 }
  end
  state.units[1].y = 149 * 256 + 128
  sim = Wormcraft.Sim.New(state, 1, true)
  ticks = 0
  while sim.phase == "aim" and ticks < 200 do
    sim:Step("R")
    ticks = ticks + 1
  end
  equal("settle", sim.phase, "being hurt ends the turn")
  wormSettle(sim)
  local fallen = sim.state.units[1]
  equal(399 * 256 + 128, fallen.y)
  assert(fallen.hp < 100 and fallen.hp > 40, "a long way down hurts, got " .. fallen.hp)

  -- And into the sea, where there is no island
  state = wormFlat(private)
  for column = 61, 139 do
    state.columns[column] = {}
  end
  sim = Wormcraft.Sim.New(state, 1, true)
  ticks = 0
  while sim.phase ~= "done" and ticks < 600 do
    sim:Step(sim.phase == "aim" and "R" or nil)
    ticks = ticks + 1
  end
  equal(false, sim.state.units[1].alive)
  equal(1, #wormHappened(sim, "drown"))
  equal(0, #sim.state.bodies, "no grave for somebody the sea took")
  equal(2, sim.state.outcome.winner)
end

function tests.WormcraftBlowsHolesInTheIsland()
  local private = loadEngine()
  local Wormcraft = private.Wormcraft
  local state = wormFlat(private)
  state.units[2].x = 280 * 256 + 128
  local sim = Wormcraft.Sim.New(state, 1, true)
  sim:Step({ use = "fb", args = { 15, 40 }, fire = true })
  equal("retreat", sim.phase)
  equal(Wormcraft.RETREAT * Wormcraft.TPS - 1, sim.left, "the tick it was fired in is the first of the three seconds to run")
  wormSettle(sim)
  local booms = wormHappened(sim, "boom")
  equal(1, #booms)
  local target = sim.state.units[2]
  assert(target.hp < 100 and target.hp >= 55, "hurt by it, got " .. target.hp)
  assert(target.x ~= 280 * 256 + 128 or target.y ~= 299 * 256 + 128, "and thrown about by it")
  equal(100, sim.state.units[1].hp, "the one who fired was far enough away")
  local hole = false
  for column = 1, #sim.state.columns do
    hole = hole or sim.state.columns[column][1] > 300
  end
  equal(true, hole, "with a crater")
  equal(2, sim.state.turn, "and it is the other one's turn")
  equal(-1, sim.state.teams[1].arsenal.fb, "fireballs aren't used up")

  -- A grenade bounces about and goes off when its fuse has burnt down
  state = wormFlat(private)
  sim = Wormcraft.Sim.New(state, 1, true)
  sim:Step({ use = "gr", args = { 60, 30, 2 }, fire = true })
  local ticks = 1
  while #wormHappened(sim, "boom") == 0 and ticks < 200 do
    sim:Step(nil)
    ticks = ticks + 1
  end
  equal(2 * Wormcraft.TPS, ticks, "two seconds of fuse")

  -- The wind blows a fireball along, but not a grenade
  local function landing(id, wind)
    local blown = wormFlat(private)
    blown.units[2].x = 1000 * 256
    blown.wind = wind
    local shot = Wormcraft.Sim.New(blown, 1, true)
    local args = id == "gr" and { 60, 50, 5 } or { 60, 50 }
    shot:Step({ use = id, args = args, fire = true })
    wormSettle(shot)
    return wormHappened(shot, "boom")[1].x
  end
  assert(landing("fb", 10) > landing("fb", 0) + 30 * 256, "a fireball goes with the wind")
  assert(landing("fb", -10) < landing("fb", 0) - 30 * 256)
  equal(landing("gr", 0), landing("gr", 10), "a grenade doesn't")

  -- A charge left behind goes off however far its owner ran
  state = wormFlat(private)
  sim = Wormcraft.Sim.New(state, 1, true)
  local learned = sim.team.arsenal
  learned.sc = 1
  sim:Step({ use = "sc", args = {}, fire = true })
  for _ = 1, 89 do
    sim:Step("L")
  end
  wormSettle(sim)
  equal(1, #wormHappened(sim, "boom"))
  equal(0, sim.state.teams[1].arsenal.sc, "used up")
  equal(100, sim.state.units[1].hp, "ran away in time")
end

function tests.WormcraftFiresEverything()
  local private = loadEngine()
  local Wormcraft = private.Wormcraft
  local game = private.Games.Get("wormcraft")
  local classes = { ch = "WARRIOR", ds = "PALADIN", as = "HUNTER", bs = "ROGUE", ph = "PRIEST", cl = "SHAMAN", bl = "MAGE", dl = "WARLOCK", cf = "DRUID" }
  for id, weapon in pairs(Wormcraft.WEAPONS) do
    local state = wormFlat(private, 300, 2)
    -- Somebody close enough to hit with anything
    state.units[2].x = 214 * 256 + 128
    state.units[2].facing = -1
    local class = classes[id]
    if class then
      state.teams[1].class = class
    end
    state.teams[1].arsenal[id] = 1
    local args = ({ none = {}, angle = { 0 }, power = { 10, 40 }, fuse = { 80, 10, 1 } })[weapon.aim]
    if weapon.kind == "grenade" and weapon.aim == "power" then
      -- Lobbed, so it doesn't bounce away before it goes off
      args = { 80, 10 }
    end
    if weapon.aim == "target" then
      args = weapon.kind == "teleport" and { 260, 290 } or { 214 }
    end
    local move = "1" .. (weapon.utility and "U" or "F") .. id .. (#args > 0 and "." .. table.concat(args, ".") or "")
    if weapon.kind == "sheep" then
      -- Set off as soon as it has got there
      move = move .. "W10X"
    end
    local ok, err = game.validate(state, 1, move)
    equal(true, ok, move .. " " .. tostring(err))
    local before = Wormcraft.copy(state)
    local event = game.apply(state, 1, move)
    equal(2, state.turn, id .. " ends the turn, one way or another")
    assert(event.before, "the turn can be played out again")
    if id ~= "rs" then
      equal(0, state.teams[1].arsenal[id], id .. " is used up")
    end
    local again = Wormcraft.copy(before)
    game.apply(again, 1, move)
    equal(wormDigest(state), wormDigest(again), id .. " comes out the same every time")
    local hurt = state.units[2].hp < 100 or not state.units[2].alive
    if weapon.kind ~= "teleport" and weapon.kind ~= "shield" and weapon.kind ~= "heal" and weapon.kind ~= "cat" and weapon.kind ~= "dig" and weapon.kind ~= "skip" and weapon.kind ~= "trap" and id ~= "inf" then
      equal(true, hurt, id .. " hurts whoever it hits")
    end
  end
end

function tests.WormcraftClassesDoWhatTheyDo()
  local private = loadEngine()
  local Wormcraft = private.Wormcraft
  -- Divine Shield: nothing hurts them until their next turn
  local state = wormFlat(private)
  state.units[2].x = 240 * 256 + 128
  local sim = Wormcraft.Sim.New(state, 1, true)
  sim.team.arsenal.ds = 1
  sim:Step({ use = "ds", args = {}, fire = false })
  equal(true, sim.unit.shield)
  equal("aim", sim.phase, "and it is still their turn")
  sim:Step({ use = "fb", args = { 0, 30 }, fire = true })
  wormSettle(sim)
  equal(100, sim.state.units[1].hp)
  assert(sim.state.units[2].hp < 100)
  equal(true, sim.state.units[1].shield, "while the others have their turn")

  -- Blink: only as far as it reaches, and only where there is room
  state = wormFlat(private)
  sim = Wormcraft.Sim.New(state, 1, true)
  sim:Step({ use = "bl", args = { 600, 200 }, fire = false })
  equal(3, sim.team.arsenal.bl, "too far: not used")
  sim:Step({ use = "bl", args = { 250, 350 }, fire = false })
  equal(3, sim.team.arsenal.bl, "in the ground: not used either")
  sim:Step({ use = "bl", args = { 300, 250 }, fire = false })
  equal(2, sim.team.arsenal.bl)
  equal(300, math.floor(sim.unit.x / 256))
  wormSettle(sim)

  -- Prayer of Healing, for everybody of the squad
  state = wormFlat(private, 300, 2)
  state.units[1].hp, state.units[3].hp = 40, 50
  sim = Wormcraft.Sim.New(state, 1, true)
  sim.team.arsenal.ph = 1
  sim:Step({ use = "ph", args = {}, fire = false })
  equal(65, sim.unit.hp)
  equal(75, sim.state.units[3].hp)

  -- Drain Life takes from the nearest of the others
  state = wormFlat(private)
  state.units[2].x = 300 * 256
  state.units[1].hp = 50
  sim = Wormcraft.Sim.New(state, 1, true)
  sim.team.arsenal.dl = 1
  sim:Step({ use = "dl", args = {}, fire = true })
  equal(75, sim.unit.hp)
  equal(75, sim.state.units[2].hp)

  -- Cat Form: twice as quick
  state = wormFlat(private)
  sim = Wormcraft.Sim.New(state, 1, true)
  sim.team.arsenal.cf = 1
  sim:Step({ use = "cf", args = {}, fire = false })
  for _ = 1, 20 do
    sim:Step("R")
  end
  equal(240 * 256 + 128, sim.unit.x)

  -- Charge runs into whoever is there, and throws them
  state = wormFlat(private)
  state.units[2].x = 260 * 256 + 128
  sim = Wormcraft.Sim.New(state, 1, true)
  sim.team.arsenal.ch = 1
  sim:Step({ use = "ch", args = {}, fire = true })
  wormSettle(sim)
  equal(70, sim.state.units[2].hp)
  assert(sim.state.units[2].x > 280 * 256, "thrown along")
end

function tests.WormcraftLevelsAndCrates()
  local private = loadEngine()
  local Wormcraft = private.Wormcraft
  local game = private.Games.Get("wormcraft")
  local state = wormFlat(private)
  equal(1, state.level)
  game.apply(state, 1, "1Frs")
  equal(1, state.level, "not before everybody has had a turn")
  local event = game.apply(state, 2, "1Frs")
  equal(2, state.round)
  equal(2, state.level)
  equal(2, event.passed.level)
  for seat = 1, 2 do
    equal(1, state.teams[seat].arsenal.tg, "learned at the second level")
    equal(2, state.teams[seat].arsenal.et)
  end
  for _ = 1, 20 do
    game.apply(state, state.turn, "1Frs")
  end
  equal(5, state.level, "up to the last level there is")
  equal(1, state.teams[1].arsenal.kd)
  local crates = 0
  for _, body in ipairs(state.bodies) do
    crates = crates + (body.kind == "crate" and 1 or 0)
    assert(body.rarity, "a crate says how rare what is in it is")
  end
  assert(crates > 0, "crates come down between turns")

  -- Walking into one takes it
  state = wormFlat(private)
  state.bodies = {
    { kind = "crate", x = 220 * 256, y = 299 * 256 + 128, vx = 0, vy = 0, air = false, loot = "hg", rarity = "legendary" },
    { kind = "crate", x = 240 * 256, y = 299 * 256 + 128, vx = 0, vy = 0, air = false, loot = "health", rarity = "health" },
  }
  state.units[1].hp = 50
  local sim = Wormcraft.Sim.New(state, 1, true)
  for _ = 1, 45 do
    sim:Step("R")
  end
  equal(0, #sim.state.bodies)
  equal(1, sim.team.arsenal.hg)
  equal(80, sim.unit.hp)
  equal(2, #wormHappened(sim, "take"))
end

function tests.WormcraftEndsInSuddenDeath()
  local private = loadEngine()
  local game = private.Games.Get("wormcraft")
  local state = wormFlat(private, 400)
  state.suddenDeath = 2
  local seaBefore = state.sea
  local turns = 0
  while not state.outcome and turns < 200 do
    game.apply(state, state.turn, "1Frs")
    turns = turns + 1
  end
  assert(state.sea < seaBefore, "the sea rose")
  equal(0, game.result(state).winner, "and took everybody at once")
  equal("nobody", game.result(state).detail)
  equal(false, (game.validate(state, state.turn, "1Frs")), "nothing after the end")
end

function tests.WormcraftTurnsComeOutTheSameEverywhere()
  local private = loadEngine()
  local Wormcraft = private.Wormcraft
  local game = private.Games.Get("wormcraft")
  local dice = private.Random.New(5)
  local state = game.newState(3, private.Random.New(11), { squad = 3 })
  for seat = 1, 3 do
    game.apply(state, seat, "c" .. Wormcraft.CLASS_ORDER[seat * 2])
  end
  local played = 0
  while not state.outcome and played < 40 do
    local team = state.teams[state.turn]
    local ids = {}
    for id, charges in pairs(team.arsenal) do
      local weapon = Wormcraft.WEAPONS[id]
      if charges ~= 0 and weapon.aim ~= "target" and not weapon.utility then
        ids[#ids + 1] = id
      end
    end
    table.sort(ids)
    local weapon = Wormcraft.WEAPONS[ids[dice:Roll(#ids)]]
    local args = ({ none = "", angle = "." .. dice:Roll(359), power = "." .. dice:Roll(359) .. "." .. dice:Roll(100), fuse = "." .. dice:Roll(359) .. "." .. dice:Roll(100) .. "." .. dice:Roll(5) })[weapon.aim]
    local move = team.next .. (dice:Roll(2) == 1 and "R" or "L") .. dice:Roll(60) .. "JW" .. dice:Roll(20) .. "F" .. weapon.id .. args .. "L" .. dice:Roll(80)
    assert(game.validate(state, state.turn, move))
    local before = Wormcraft.copy(state)
    local event = game.apply(state, state.turn, move)

    -- The engine's, and the view's playing it out again tick by tick from what it was before
    local sim = Wormcraft.Sim.New(event.before, event.slot, true)
    for _, input in ipairs(event.inputs) do
      for _ = 1, input[2] do
        if sim.phase == "aim" or sim.phase == "retreat" then
          sim:Step(input[1] or nil)
        end
      end
    end
    wormSettle(sim)
    equal(wormDigest(state), wormDigest(sim.state), "played out again, it comes out the same")
    game.apply(before, before.turn, move)
    equal(wormDigest(state), wormDigest(before))
    played = played + 1
  end
end

function tests.WormcraftIsPlayedByThree()
  local world, seated, id = startedCrowd(3, "wormcraft")
  local function stateOf(player)
    return player.private.Match.State(player.matches[id])
  end
  for seat, player in ipairs(seated) do
    assert(player.session:Move(id, "c" .. ({ "MAGE", "HUNTER", "PRIEST" })[seat]))
    world:Deliver()
  end
  for _, player in ipairs(seated) do
    equal(false, stateOf(player).picking)
  end
  assert(seated[1].session:Move(id, "1R20W10Ffb.30.60L20"))
  world:Deliver()
  assert(seated[2].session:Move(id, "1L20Fgr.150.50.3R10"))
  world:Deliver()
  local digest = wormDigest(stateOf(seated[1]))
  for _, player in ipairs(seated) do
    equal(digest, wormDigest(stateOf(player)), "everybody has the same island")
  end
  assert(seated[3].session:Resign(id))
  world:Deliver()
  for _, player in ipairs(seated) do
    equal(true, stateOf(player).teams[3].out)
    equal("active", player.matches[id].status, "the other two play on")
  end
end

--- Opens the window on a game of Wormcraft between Alice and Bob
--- @return table world, table alice, table bob, string id, table view The game on screen
local function wormcraftOnScreen()
  local world, alice, bob, id = gameOnScreen("wormcraft")
  local found = Client.Find(function(widget)
    return widget.wormcraft ~= nil
  end)
  equal(1, #found, "islands on screen")
  return world, alice, bob, id, found[1].wormcraft
end

--- Lets frames go by on the island
--- @param view table
--- @param frames number
local function wormFrames(view, frames)
  for _ = 1, frames do
    view.ticker:Fire("OnUpdate", 1 / 30)
  end
end

function tests.WindowPlaysWormcraft()
  local world, alice, bob, id, view = wormcraftOnScreen()
  local function stateOf(player)
    return player.private.Match.State(player.matches[id])
  end
  equal(true, view.picker:IsShown(), "classes first")
  view.picks.HUNTER:Fire("OnClick")
  world:Deliver()
  equal("HUNTER", stateOf(alice).teams[1].class)
  equal(true, view.picker:IsShown(), "while the other one picks")
  equal(false, view.picker.row:IsShown())
  assert(bob.session:Move(id, "cDRUID"))
  world:Deliver()
  equal(false, view.picker:IsShown())

  -- Alice's turn is ready, and waits for her to do something
  local live = assert(view.live, "a turn to make")
  equal(false, live.started)
  equal(1, live.slot)
  wormFrames(view, 30)
  equal(0, live.sim.ticks, "the clock doesn't go before she does")
  local ticker = view.ticker
  ticker:Fire("OnKeyDown", "TAB")
  equal(2, view.live.slot, "somebody else of the squad")
  live = view.live

  -- She walks, aims a little higher and fires
  local x = live.sim.unit.x
  ticker:Fire("OnKeyDown", "LEFT")
  wormFrames(view, 20)
  ticker:Fire("OnKeyUp", "LEFT")
  equal(true, live.started)
  assert(live.sim.unit.x ~= x or live.sim.unit.air, "she went somewhere")
  local elevation = view:choice().elevation
  ticker:Fire("OnKeyDown", "UP")
  wormFrames(view, 10)
  ticker:Fire("OnKeyUp", "UP")
  assert(view:choice().elevation > elevation, "aimed higher")
  ticker:Fire("OnKeyDown", "SPACE")
  wormFrames(view, 15)
  assert(live.charging and live.charging > 20, "winding it up")
  ticker:Fire("OnKeyUp", "SPACE")
  wormFrames(view, 2)
  equal("retreat", live.sim.phase)
  ticker:Fire("OnKeyDown", "RIGHT")
  wormFrames(view, 40)
  ticker:Fire("OnKeyUp", "RIGHT")
  for _ = 1, 2000 do
    if live.submitted then
      break
    end
    wormFrames(view, 1)
  end
  equal(true, live.submitted, "the turn is over and sent")
  world:Deliver()
  local log = alice.matches[id].log
  assert(log[#log]:match("^2L%d+W%d+Ffb%.%d+%.%d+W?%d*R%d+"), "what she did, written down: " .. log[#log])
  equal(wormDigest(stateOf(alice)), wormDigest(stateOf(bob)), "and it came out the same for Bob")
  equal(wormDigest(stateOf(alice)), wormDigest(live.sim.state), "as she saw it happen")
  equal(nil, view.live, "it is Bob's turn")
  equal(nil, view.replay, "her own turn isn't shown to her again")

  -- Bob's turn is played out again for her, until she skips the rest of it
  assert(bob.session:Move(id, stateOf(bob).teams[2].next .. "R10W5Fgr.60.40.3L20"))
  world:Deliver()
  assert(view.replay, "Bob's turn is shown")
  wormFrames(view, 10)
  ticker:Fire("OnKeyDown", "SPACE")
  equal(nil, view.replay)
  equal(wormDigest(stateOf(alice)), wormDigest(stateOf(bob)))
  assert(view.live, "and then it is hers again")

  -- What she has to fire is under the island: resting ends the turn
  local rest = nil
  for _, slot in ipairs(view.slots) do
    if slot:IsShown() and slot.id == "rs" then
      rest = slot
    end
  end
  assert(rest, "resting is offered")
  rest:Fire("OnClick")
  equal("rs", view:choice().weapon)
  ticker:Fire("OnKeyDown", "SPACE")
  ticker:Fire("OnKeyUp", "SPACE")
  wormFrames(view, 5)
  world:Deliver()
  equal(2, stateOf(alice).turn)
  assert(alice.matches[id].log[#alice.matches[id].log]:match("Frs$"))
end

function tests.WindowAimsWormcraftAtAPlace()
  local world, alice, bob, id, view = wormcraftOnScreen()
  view.picks.MAGE:Fire("OnClick")
  world:Deliver()
  assert(bob.session:Move(id, "cWARRIOR"))
  world:Deliver()
  local live = assert(view.live)
  local unit = live.sim.unit
  view:pick("bl")
  equal("bl", view:choice().weapon)

  -- Blink goes where she clicks, if there is room there and it isn't too far
  local function pointAt(x, y)
    local viewport = view.viewport
    Client.cursor = { viewport.x + x * view.scale * viewport.zoom, viewport.height - (viewport.y + y * view.scale * viewport.zoom) }
  end
  view.viewport.frame.height = view.viewport.height
  pointAt(unit.x / 256, unit.y / 256 + 40)
  view.world:Fire("OnMouseDown", "LeftButton")
  wormFrames(view, 2)
  equal(3, live.sim.team.arsenal.bl, "not into the ground")
  local toX, toY = math.floor(unit.x / 256) + 30, math.floor(unit.y / 256) - 40
  pointAt(toX + 0.5, toY + 0.5)
  view.world:Fire("OnMouseDown", "LeftButton")
  wormFrames(view, 2)
  equal(2, live.sim.team.arsenal.bl)
  equal("aim", live.sim.phase, "and her turn goes on")
end

function tests.WindowWritesDownOnlyWhatWormcraftFired()
  local world, alice, bob, id, view = wormcraftOnScreen()
  view.picks.HUNTER:Fire("OnClick")
  world:Deliver()
  assert(bob.session:Move(id, "cROGUE"))
  world:Deliver()
  local live = assert(view.live)
  local ticker = view.ticker
  view:pick("ms")
  -- In the air nothing is fired, and nothing of it is written down
  ticker:Fire("OnKeyDown", "ENTER")
  wormFrames(view, 2)
  equal(true, live.sim.unit.air)
  ticker:Fire("OnKeyDown", "SPACE")
  ticker:Fire("OnKeyUp", "SPACE")
  wormFrames(view, 2)
  equal("aim", live.sim.phase)
  for _ = 1, 100 do
    if not live.sim.unit.air then
      break
    end
    wormFrames(view, 1)
  end
  -- Back on the ground it is
  ticker:Fire("OnKeyDown", "SPACE")
  ticker:Fire("OnKeyUp", "SPACE")
  for _ = 1, 2000 do
    if live.submitted then
      break
    end
    wormFrames(view, 1)
  end
  world:Deliver()
  local log = alice.matches[id].log
  assert(log[#log]:match("^1JW%d+Fms%.%d+W%d+$"), "one shot: " .. log[#log])
  equal(2, alice.private.Match.State(alice.matches[id]).turn, "and the move was taken")
end

function tests.WormcraftIsPlayedAgainstTheComputer()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local session, Match = alice.session, alice.private.Match
  local match = assert(session:Invite({}, "wormcraft", { computer = { level = "easy", count = 2 }, options = { squad = 2 } }))
  equal(3, #match.players, "a squad of the player's and two of the computer's")
  local me = match.me

  -- Everyone picks a class in turn, the computer for its own squads
  session:ThinkThrough(match.id)
  equal(true, Match.State(match).picking)
  assert(session:Move(match.id, "cPRIEST"))
  session:ThinkThrough(match.id)
  local state = Match.State(match)
  equal(false, state.picking)
  for seat = 1, 3 do
    assert(state.teams[seat].class, "squad " .. seat .. " has a class")
  end

  -- Round to the player and back again, the computer's turns made by the computer
  equal(me, state.turn)
  assert(session:Move(match.id, state.teams[me].next .. "Frs"))
  session:ThinkThrough(match.id)
  state = Match.State(match)
  equal(me, state.turn, "round to the player again")
  equal(0, #world.queue, "and nothing was sent to anyone")

  -- Put out of it, the player has lost, whoever of the computer's is left
  for _, unit in ipairs(state.units) do
    if unit.team == me then
      unit.hp = 1
      unit.alive = unit.slot == state.teams[me].next
    end
  end
  state.wind = 0
  -- Straight down, at their own feet
  assert(session:Move(match.id, state.teams[me].next .. "Fgr.270.1.1"))
  equal("finished", match.status)
  equal(true, match.beaten)
  equal(nil, Match.Result(match), "the others haven't finished it among themselves")
  equal(1, session:Versus("wormcraft", "easy").lost)
  equal(nil, session:ComputerTurn(match))
end

function tests.WormcraftPlayedAloneBeforeStillPlaysOut()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local Wormcraft, Match = alice.private.Wormcraft, alice.private.Match
  local game = alice.private.Games.Get("wormcraft")
  -- The way a game alone was set up before the computer was the engine's
  local match = alice.session:startSolo(game, { bots = 2, skill = "easy" })
  equal(1, #match.players, "nobody else plays")
  local state = Match.State(match)
  equal(true, state.alone)
  equal(3, #state.teams, "a squad of the player's and two of the computer's")
  equal(nil, state.teams[1].class)
  for seat = 2, 3 do
    equal(true, state.teams[seat].computer)
    assert(state.teams[seat].class, "the computer knows who it is from the start")
    assert(state.teams[seat].arsenal[Wormcraft.CLASSES[state.teams[seat].class].signature], "and what its class can do")
  end
  assert(alice.session:Move(match.id, "cPRIEST"))
  state = Match.State(match)
  equal(false, state.picking, "only the player has to say")
  equal(1, state.turn)
  assert(alice.session:Move(match.id, "1Frs"))
  state = Match.State(match)
  equal(2, state.turn, "the computer's turn")
  equal(1, game.turn(state), "which the player's client makes")
  equal(true, Match.CanMove(match))

  -- Its moves are moves like any other
  for _ = 1, 2 do
    local brain = Wormcraft.Brain.New(Match.State(match))
    local move = brain:Decide()
    equal(nil, brain.failed)
    assert(alice.session:Move(match.id, move))
  end
  state = Match.State(match)
  equal(1, state.turn, "round to the player again")
  equal(0, #world.queue, "and nothing was sent to anyone")

  -- The game is lost with the player's squad, whoever of the computer's is left
  for _, unit in ipairs(state.units) do
    if unit.team == 1 then
      unit.hp = 1
    end
  end
  state.wind = 0
  for _, unit in ipairs(state.units) do
    unit.alive = unit.team ~= 1 or unit.slot == 1
  end
  -- Straight down, at their own feet
  assert(alice.session:Move(match.id, "1Fgr.270.1.1"))
  equal("finished", match.status)
  equal(0, Match.Result(match).winner)
  equal("beaten", Match.Result(match).detail)

  -- Another can't be started alone: the computer is asked for the way it is now
  equal("no_target", select(2, alice.session:Invite({}, "wormcraft", { options = match.options })))
end
function tests.WormcraftComputerGetsBetterWithSkill()
  local private = loadEngine()
  local Wormcraft = private.Wormcraft
  local game = private.Games.Get("wormcraft")
  local dealt = {}
  for _, skill in ipairs(Wormcraft.SKILL_ORDER) do
    dealt[skill] = 0
    for seed = 1, 6 do
      local state = game.newState(2, private.Random.New(seed * 5), private.Games.Rules(game.options, { squad = 2 }))
      game.apply(state, 1, "cMAGE")
      game.apply(state, 2, "cMAGE")
      game.apply(state, 1, "1Frs")
      equal(2, state.turn)
      local brain = Wormcraft.Brain.New(state, skill)
      local move = brain:Decide()
      equal(nil, brain.failed, skill)
      local ok, err = game.validate(state, 2, move)
      equal(true, ok, skill .. " " .. move .. " " .. tostring(err))
      local before = 0
      for _, unit in ipairs(state.units) do
        before = before + (unit.team == 1 and unit.hp or 0)
      end
      game.apply(state, 2, move)
      local after = 0
      for _, unit in ipairs(state.units) do
        after = after + (unit.team == 1 and unit.hp or 0)
      end
      dealt[skill] = dealt[skill] + before - after
    end
  end
  assert(dealt.hard > 0, "the best of it hurts somebody")
  assert(dealt.hard >= dealt.easy, ("and more than the worst: %d against %d"):format(dealt.hard, dealt.easy))
  assert(dealt.medium >= dealt.easy, ("medium %d, easy %d"):format(dealt.medium, dealt.easy))
end

function tests.WormcraftComputerThinksAFrameAtATime()
  local private = loadEngine()
  local Wormcraft = private.Wormcraft
  local game = private.Games.Get("wormcraft")
  local state = game.newState(2, private.Random.New(4), private.Games.Rules(game.options))
  game.apply(state, 1, "cMAGE")
  game.apply(state, 2, "cMAGE")
  game.apply(state, 1, "1Frs")
  local brain = Wormcraft.Brain.New(state, "hard")
  local thoughts = 1
  while not brain:Think() do
    thoughts = thoughts + 1
  end
  assert(thoughts > 5, "it took a while, a bit at a time")
  equal(brain.move, brain:Think(), "and then it knows")
  equal(brain.move, Wormcraft.Brain.New(state, "hard"):Decide(), "the same every time it is asked")
end

function tests.WormcraftKeepsWhatGamesPlayedAloneBeforeWereSetUpWith()
  local private = loadEngine()
  local Games = private.Games
  local game = Games.Get("wormcraft")
  equal(false, Games.CanSeat(game, 1), "the computer plays in seats of its own now")
  equal(true, Games.PlaysAlone(game))
  local rules = Games.Rules(game.options)
  local function ids(players)
    local found = {}
    for _, option in ipairs(Games.OptionsFor(game, rules, players)) do
      found[#found + 1] = option.id
    end
    return table.concat(found, ",")
  end
  equal("squad,health,time,sudden,map", ids(2))
  equal("squad,health,time,sudden,map", ids(4))
  -- A game alone from before still has them, to be played out with
  equal("bots,skill,squad,health,time,sudden,map", ids(1))
  equal(2, #Games.DescribeOptions(game, { bots = 3, squad = 4 }, 1))
  equal(1, #Games.DescribeOptions(game, { bots = 3, squad = 4 }, 2), "nobody is told about a computer that isn't there")
  local kept = Games.ForPlayers(game, { bots = 3, skill = "hard", squad = 4 }, 3)
  equal(nil, kept.bots)
  equal(nil, kept.skill)
  equal(4, kept.squad)
end
function tests.WizardWrapsWhatAnOptionCanBe()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  world:AddPlayer("Bob-Realm")
  openWizard(alice)
  pickGame("wormcraft")
  -- The computer is the engine's, and set up the engine's way
  equal(false, says("wormcraft_option_bots"), "no computer squads of the game's own")
  equal(false, says("wormcraft_option_skill"))
  seating.Click("wizard_add_computer")
  assert(seating.Sizes()["4"], "up to three squads besides the player's")
  equal("Alice-Realm, computer [computer_level_medium]", (seating.Shown()))
  local row = Client.Find(function(widget)
    return widget.choices ~= nil and widget.name ~= nil and widget.name.text == "wormcraft_option_map" and widget:IsVisible()
  end)[1]
  local lines, room = {}, 400 - 2 * 12
  for _, choice in ipairs(row.choices) do
    if choice:IsVisible() then
      local x, y = choice.anchors[1][2], choice.anchors[1][3]
      assert(x + choice.width <= room or x == 142 + 6, "every choice inside the rules, got " .. x + choice.width)
      lines[y] = true
    end
  end
  local count = 0
  for _ in pairs(lines) do
    count = count + 1
  end
  assert(count > 1, "what doesn't fit goes on the next line")
  assert(row.height > 30, "and the line is as tall as it takes")

  -- With somebody to play the computer sits at the table with them, and is still the engine's
  local box = Client.Find(function(widget)
    return widget.kind == "EditBox" and widget.scripts.OnEnterPressed and widget:IsVisible()
  end)[1]
  box:SetText("Bob-Realm")
  box:Fire("OnTextChanged", true)
  equal(false, says("wormcraft_option_bots"))
  equal("Alice-Realm, computer [computer_level_medium], Bob-Realm", (seating.Shown()))
  equal(true, says("wizard_summary_with_computer"))
end

function tests.WizardListsAnOptionWithTooManyChoicesToShow()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  openWizard(alice)
  pickGame("freedoom")
  local function mapRow()
    return Client.Find(function(widget)
      return widget.choices ~= nil and widget.name ~= nil and widget.name.text == "freedoom_option_map" and widget:IsVisible()
    end)[1]
  end
  local row = assert(mapRow(), "the map can be picked")
  for _, choice in ipairs(row.choices) do
    equal(false, choice:IsVisible(), "not with a button for every map, rows of them")
  end
  local dropdown = row.dropdown
  assert(dropdown and dropdown:IsVisible(), "but from a list")
  equal("freedoom_map_run", dropdown.label.text, "saying which is picked")
  equal(30, row.height, "one line tall")
  equal(false, dropdown.list:IsVisible(), "shut until it is clicked")
  dropdown:Fire("OnClick")
  assert(dropdown.list:IsVisible(), "open")
  local shown = {}
  for _, line in ipairs(dropdown.list.rows) do
    if line:IsVisible() then
      shown[#shown + 1] = line
    end
  end
  equal(10, #shown, "every map")
  equal("freedoom_map_e1m2", shown[3].label.text)
  shown[3]:Fire("OnClick")
  equal(false, dropdown.list:IsVisible(), "shut again once one is picked")
  equal("freedoom_map_e1m2", mapRow().dropdown.label.text, "and that one is picked")
  dropdown:Fire("OnClick")
  dropdown:Fire("OnClick")
  equal(false, dropdown.list:IsVisible(), "a second click shuts it too")
end

function tests.WindowPlaysWormcraftAgainstTheComputer()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local MainFrame = openWindow(alice)
  local Match = alice.private.Match
  local match = assert(alice.session:Invite({}, "wormcraft", { computer = { level = "easy" }, seat = 1, options = { squad = 2 } }))
  MainFrame.Open(match.id)
  local view = Client.Find(function(widget)
    return widget.wormcraft ~= nil
  end)[1].wormcraft
  local detail = Client.Find(function(widget)
    return widget.buttons ~= nil and widget.scripts.OnUpdate ~= nil
  end)[1]
  --- Lets frames go by, the window's and the game's, until something is so
  local function untilSo(done, label)
    for _ = 1, 4000 do
      if done() then
        return
      end
      detail:Fire("OnUpdate", 1 / 30)
      wormFrames(view, 1)
    end
    error("never: " .. label)
  end

  view.picks.WARLOCK:Fire("OnClick")
  untilSo(function()
    return not Match.State(match).picking
  end, "the computer picked its class too")
  equal(1, Match.State(match).turn)
  MainFrame.Refresh()
  local live = assert(view.live, "her turn")
  view:pick("rs")
  view.ticker:Fire("OnKeyDown", "SPACE")
  view.ticker:Fire("OnKeyUp", "SPACE")
  untilSo(function()
    return live.submitted
  end, "her turn made")
  MainFrame.Refresh()
  equal(2, Match.State(match).turn)
  equal(true, says("wormcraft_thinking"), "the computer thinks about its turn")
  untilSo(function()
    return Match.State(match).turn == 1
  end, "the computer made its turn")
  assert(view.replay, "which she sees played out")
  view.ticker:Fire("OnKeyDown", "SPACE")
  equal(nil, view.replay)
  assert(view.live, "and then it is her turn again")
end

-----------------------------
-- Fourtiles
-----------------------------

--- Every word there is in a puzzle, with how many tiles it takes and a move that spells it.
--- Tried one arrangement of tiles after the other, which is what the game itself has no time for
--- @param private table
--- @param state table
--- @param most number? The most tiles to try, four if left out
--- @return table<string, { size: number, move: string }>
local function fourtilesWords(private, state, most)
  local Lexicon, found = private.Lexicon, {}
  local function extend(text, move, used, size)
    if size > 0 and Lexicon.Has("english", text) then
      assert(not found[text] or found[text].size == size, text .. " takes two numbers of tiles")
      found[text] = found[text] or { size = size, move = move }
    end
    if size == (most or 4) then
      return
    end
    for tile = 1, #state.tiles do
      if not used[tile] then
        used[tile] = true
        extend(text .. state.tiles[tile], move .. string.char(96 + tile), used, size + 1)
        used[tile] = nil
      end
    end
  end
  extend("", "", {}, 0)
  return found
end

--- The move that spells one of the five words of a puzzle
local function fourtilesMove(state, word)
  local function extend(text, move, size)
    if text == word then
      return move
    elseif size == 4 or word:sub(1, #text) ~= text then
      return nil
    end
    for tile = 1, #state.tiles do
      if not move:find(string.char(96 + tile), 1, true) then
        local whole = extend(text .. state.tiles[tile], move .. string.char(96 + tile), size + 1)
        if whole then
          return whole
        end
      end
    end
    return nil
  end
  return assert(extend("", "", 0), word .. " can't be spelled")
end

function tests.FourtilesPuzzlesAreSound()
  local private = loadEngine()
  local Fourtiles, Lexicon = private.Fourtiles, private.Lexicon
  equal(1000, #private.FourtilesPuzzles)
  for _, puzzle in ipairs(private.FourtilesPuzzles) do
    local tiles, of, words, counts = Fourtiles.Parse(puzzle)
    equal(20, #tiles, puzzle)
    equal(5, #words, puzzle)
    equal(4, #counts, puzzle)
    local seen = {}
    for index, tile in ipairs(tiles) do
      assert(tile:match("^%u%u%u?%u?$") and not seen[tile], "bad or repeated tile in " .. puzzle)
      seen[tile] = true
      equal(math.ceil(index / 4), of[index], puzzle)
    end
    for _, word in ipairs(words) do
      assert(Lexicon.Has("english", word), word .. " isn't a word")
    end
    local state = { counts = counts }
    assert(Fourtiles.MostPoints(state) >= Fourtiles.RANKS[#Fourtiles.RANKS] + 15, "the top rank is out of reach in " .. puzzle)
  end
end

function tests.FourtilesIsPartOfItsPuzzles()
  local private = loadEngine()
  local stamp = private.Random.Seed("fourtiles")
  for _, puzzle in ipairs(private.FourtilesPuzzles) do
    stamp = private.Random.Stir(stamp, puzzle)
  end
  -- The puzzles and the words that count in them are part of the rules: players with others
  -- wouldn't agree on what was found. After changing either, give Fourtiles a new version
  -- (Games/Fourtiles.lua) and write that version and the new numbers here
  equal(1, private.Games.Get("fourtiles").version)
  equal(1428637885, stamp, "the puzzles changed")
  equal(365510098, private.Lexicon.Stamp("english"), "the English list changed")
end

function tests.FourtilesHasTheWordsItSaysItHas()
  local private = loadEngine()
  local game = private.Games.Get("fourtiles")
  local state = game.newState(1, private.Random.New(11))
  equal(20, #state.tiles)
  local shuffled = false
  for index = 1, 20 do
    shuffled = shuffled or state.of[index] ~= math.ceil(index / 4)
  end
  equal(true, shuffled, "the tiles of a word don't lie in a row")

  local words = fourtilesWords(private, state)
  local sizes, total = { 0, 0, 0, 0 }, 0
  for _, word in pairs(words) do
    sizes[word.size] = sizes[word.size] + 1
    total = total + 1
  end
  for size = 1, 4 do
    equal(state.counts[size], sizes[size], "words of " .. size .. " tiles")
  end
  equal(state.total, total)
  for _, word in ipairs(state.words) do
    equal(4, words[word].size)
  end

  -- Found to the last, the game is over without anyone calling it
  local score = 0
  for text, word in pairs(words) do
    equal(nil, game.result(state))
    assert(game.validate(state, 1, word.move), text)
    game.apply(state, 1, word.move)
    score = score + private.Fourtiles.POINTS[word.size]
  end
  equal(score + private.Fourtiles.BONUS, state.score)
  equal(private.Fourtiles.MostPoints(state), state.score)
  equal(1, game.result(state).winner)
end

function tests.FourtilesScoresWordsByTheirTiles()
  local private = loadEngine()
  local game, Fourtiles = private.Games.Get("fourtiles"), private.Fourtiles
  local state = game.newState(1, private.Random.New(3))
  equal("fourtiles_progress", game.progress(state))

  for _, bad in ipairs({ "", "aa", "abcde", "u", "A", "a1", "a b" }) do
    local ok, err = game.validate(state, 1, bad)
    equal(false, ok, bad)
    equal("invalid_move", err, bad)
  end

  local long = fourtilesMove(state, state.words[1])
  assert(game.validate(state, 1, long))
  local event = game.apply(state, 1, long)
  equal(state.words[1], event.word)
  equal(state.words[1]:lower(), event.notation, "written down in lower case, as it is on the tiles")
  equal(4, event.size)
  equal(8, event.points)
  equal(nil, event.bonus)
  equal(4, #event.tiles)
  equal(8, state.score)
  local ok, err = game.validate(state, 1, long)
  equal(false, ok)
  equal("fourtiles_found", err)
  -- The same tiles the other way round spell nothing
  ok, err = game.validate(state, 1, long:reverse())
  equal(false, ok)
  equal("fourtiles_not_word", err)

  ok, err = game.validate(state, 1, Fourtiles.WRAP_UP)
  equal(false, ok)
  equal("fourtiles_early", err)
  for index = 2, 5 do
    event = game.apply(state, 1, fourtilesMove(state, state.words[index]))
  end
  equal(true, event.bonus, "the last of the five")
  equal(5 * 8 + 40, state.score)
  equal(4, event.rank, "which takes the player up a rank")
  equal(false, Fourtiles.CanWrapUp(state), "the top rank is still to come")

  -- Short words make up the rest
  for text, word in pairs(fourtilesWords(private, state, 2)) do
    if state.score < 100 then
      assert(game.validate(state, 1, word.move), text)
      event = game.apply(state, 1, word.move)
      equal(word.size, event.points, "one tile is worth one and two are worth two")
    end
  end
  assert(state.score >= 100, "not enough short words")
  equal(5, event.rank)
  equal(true, Fourtiles.CanWrapUp(state))
  equal(nil, game.result(state), "it goes on until it is called done")
  assert(game.validate(state, 1, Fourtiles.WRAP_UP))
  equal(true, game.apply(state, 1, Fourtiles.WRAP_UP).done)
  equal(1, game.result(state).winner)
  equal(false, (game.validate(state, 1, Fourtiles.WRAP_UP)))

  -- Two who made it made it together
  local shared = game.newState(2, private.Random.New(3))
  shared.done = true
  equal(0, game.result(shared).winner)
  equal(true, game.result(shared).all)
end

function tests.FourtilesGathersTheWordsFoundAndShufflesTheRest()
  local world = World.New()
  local player = world:AddPlayer("Alice-Realm")
  openWindow(player)
  local private = player.private
  local game, Fourtiles = private.Games.Get("fourtiles"), private.Fourtiles
  local state = game.newState(1, private.Random.New(3))
  local stage = CreateFrame("Frame", nil, UIParent)
  local view = game.createView(stage)
  stage:SetSize(800, 600)
  view:Layout(800, 600)
  local function show(played, id)
    view:Update({ match = { id = id or "fourtiles" }, state = state, seat = 1, names = { "Alice" }, canMove = true, changed = true, played = played, submit = function() end })
    view.slide:Stop()
  end
  local function row(number)
    local parts = {}
    for place = (number - 1) * 4 + 1, number * 4 do
      parts[#parts + 1] = state.tiles[view.order[place]]
    end
    return table.concat(parts)
  end
  local function rest(from)
    local tiles = {}
    for place = from, 20 do
      tiles[#tiles + 1] = view.order[place]
    end
    table.sort(tiles)
    return table.concat(tiles, " ")
  end
  show()
  equal("1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20", table.concat(view.order, " "), "as they were dealt while nothing is found")
  equal(false, view.mix:IsShown(), "nothing found to leave be")

  -- Finding one of the five brings its tiles together on the top row, spelling it
  local event = game.apply(state, 1, fourtilesMove(state, state.words[2]))
  event.kind, event.seat = "move", 1
  show(event)
  equal(state.words[2], row(1))
  equal(true, view.mix:IsShown())
  for place, tile in ipairs(view.order) do
    local spot, anchor = view.spots[place], view.tiles[tile].anchors[1]
    equal(spot[1], anchor[4], "the tile has come to its place")
    equal(-spot[2], anchor[5], "the tile has come to its place")
  end

  -- A shuffle leaves it there and moves the others
  local others, moved = rest(5), false
  for _ = 1, 5 do
    local before = table.concat(view.order, " ")
    view:shuffle()
    view.slide:Stop()
    equal(state.words[2], row(1), "the word found stays where it is")
    equal(others, rest(5), "only the others are shuffled")
    moved = moved or table.concat(view.order, " ") ~= before
  end
  equal(true, moved, "the others are shuffled")

  -- Unless the box is ticked
  view.mix:Fire("OnClick")
  local mixed = false
  for _ = 1, 10 do
    view:shuffle()
    view.slide:Stop()
    mixed = mixed or row(1) ~= state.words[2]
  end
  equal(true, mixed, "with the box ticked the word found is shuffled too")
  view.mix:Fire("OnClick")
  view:shuffle()
  equal(state.words[2], row(1), "untick it, and the word found comes back together")

  -- The next one goes under it, and a match opened again is laid out the same way
  event = game.apply(state, 1, fourtilesMove(state, state.words[5]))
  event.kind, event.seat = "move", 1
  show(event)
  equal(state.words[2], row(1))
  equal(state.words[5], row(2))
  local again = game.createView(stage)
  again:Layout(800, 600)
  view = again
  show(nil, "another")
  equal(state.words[2], row(1), "opened again")
  equal(state.words[5], row(2), "opened again")
  local spelt = {}
  for index, tile in ipairs(Fourtiles.TilesOf(state, 3)) do
    spelt[index] = state.tiles[tile]
  end
  equal(state.words[3], table.concat(spelt), "a word's tiles are found in the order that spells it")
end

--- Starts a game of Fourtiles between two
--- @return World, table first, table second, string id
local function startedFourtiles()
  local world = World.New()
  local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  local match = assert(alice.session:Invite("Bob-Realm", "fourtiles"))
  world:Deliver()
  assert(bob.session:Accept(match.id))
  world:Deliver()
  local first = match.me == 1 and alice or bob
  return world, first, first == alice and bob or alice, match.id
end

function tests.FourtilesIsSolvedByTwoTogether()
  local world, first, second, id = startedFourtiles()
  local Match = first.private.Match
  local state = Match.State(first.matches[id])
  equal(table.concat(state.tiles, " "), table.concat(second.private.Match.State(second.matches[id]).tiles, " "), "the same puzzle for both")
  equal(true, Match.CanMove(first.matches[id]))
  equal(true, Match.CanMove(second.matches[id]))

  -- Each finds one at the same moment, and both look for a third
  assert(first.session:Move(id, fourtilesMove(state, state.words[1])))
  assert(second.session:Move(id, fourtilesMove(state, state.words[2])))
  assert(first.session:Move(id, fourtilesMove(state, state.words[3])))
  assert(second.session:Move(id, fourtilesMove(state, state.words[3])))
  world:Deliver()
  world:Tick(30)
  equal(logOf(first, id), logOf(second, id))
  for _, player in ipairs({ first, second }) do
    local shared = player.private.Match.State(player.matches[id])
    equal(3, #shared.list)
    equal(24, shared.score)
    equal(16, shared.by[1])
    equal(8, shared.by[2])
    equal(1, shared.found[state.words[3]].seat, "whose log stands found it first")
  end
  equal(false, first.session:IsPending(first.matches[id]))

  -- One of them leaving doesn't end it for the other
  assert(second.session:Resign(id))
  world:Deliver()
  equal("active", first.matches[id].status)
  assert(first.session:Move(id, fourtilesMove(state, state.words[4])))
  world:Deliver()
  equal(32, second.private.Match.State(second.matches[id]).score)
end

function tests.WizardStartsFourtilesAloneOrWithSomeone()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local bob = world:AddPlayer("Bob-Realm")
  local Wizard = openWizard(alice)
  pickGame("fourtiles")
  equal(true, Wizard.IsOpen(), "there is somebody to pick, or nobody")
  equal(true, says("wizard_step_opponent"))
  equal(false, says("wizard_turn"), "nobody goes first where there are no turns")
  Client.Button("wizard_play_alone"):Fire("OnClick")
  equal(false, Wizard.IsOpen())
  local alone
  for _, match in pairs(alice.matches) do
    alone = match
  end
  equal("fourtiles", alone.game)
  equal(1, #alone.players)
  equal("active", alone.status)
  equal(0, #world.queue, "nothing is sent to anyone")
  assert(alice.session:Move(alone.id, fourtilesMove(alice.private.Match.State(alone), alice.private.Match.State(alone).words[1])))
  equal(8, alice.private.Match.State(alone).score)

  -- With a name in the box it is a challenge like any other
  Wizard.Open()
  pickGame("fourtiles")
  local box = Client.Find(function(widget)
    return widget.kind == "EditBox" and widget.scripts.OnEnterPressed and widget:IsVisible()
  end)[1]
  box:SetText("Bob-Realm")
  box:Fire("OnTextChanged", true)
  Client.Button("wizard_send"):Fire("OnClick")
  world:Deliver()
  local invited
  for _, match in pairs(bob.matches) do
    invited = match
  end
  equal("fourtiles", invited.game)
  equal("incoming", invited.status)
end

--- The tiles of the game of Fourtiles on screen, by which tile of the puzzle each is
local function fourtilesOnScreen()
  local tiles = {}
  for _, button in ipairs(Client.Find(function(widget)
    return widget.kind == "Button" and widget.tile ~= nil and widget:IsVisible()
  end)) do
    tiles[button.tile] = button
  end
  return tiles
end

--- Clicks the tiles of a move one after the other
local function clickFourtiles(move)
  for letter in move:gmatch(".") do
    fourtilesOnScreen()[letter:byte() - 96]:Fire("OnClick")
  end
end

function tests.WindowPlaysFourtiles()
  local world, first, second, id, MainFrame = gameOnScreen("fourtiles")
  local state = first.private.Match.State(first.matches[id])
  local tiles = fourtilesOnScreen()
  equal(20, #tiles)
  equal(state.tiles[7]:lower(), tiles[7].label.text, "written in lower case, which is easier to read")
  -- Nothing is drawn that isn't put anywhere
  for _, tile in ipairs(tiles) do
    equal("CENTER", tile.label.anchors and tile.label.anchors[1][1], "the letters are in the middle of their tile")
  end
  equal(true, says("status_together") or says("fourtiles_progress"))
  equal(false, Client.Button("fourtiles_enter").enabled == true, "nothing to enter yet")

  -- A word is put together a tile at a time, and a tile clicked again comes out of it
  local move = fourtilesMove(state, state.words[2])
  clickFourtiles(move)
  equal("4", tiles[move:byte(4) - 96].number.text)
  fourtilesOnScreen()[move:byte(4) - 96]:Fire("OnClick")
  equal("", tiles[move:byte(4) - 96].number.text)
  Client.Button("fourtiles_enter"):Fire("OnClick")
  equal("", logOf(first, id), "three of its tiles are no word")
  equal(true, says("fourtiles_not_word"))
  fourtilesOnScreen()[move:byte(4) - 96]:Fire("OnClick")
  Client.Button("fourtiles_enter"):Fire("OnClick")
  world:Deliver()
  equal("1" .. move, logOf(first, id))
  equal("1" .. move, logOf(second, id))
  equal("", tiles[move:byte(1) - 96].number.text, "and the tray is empty again")

  -- Entered again it is only said to be found
  clickFourtiles(move)
  Client.Button("fourtiles_enter"):Fire("OnClick")
  equal("1" .. move, logOf(first, id))
  equal(true, says("fourtiles_found"))
  Client.Button("fourtiles_clear"):Fire("OnClick")

  -- What the other one finds turns up as well
  assert(second.session:Move(id, fourtilesMove(state, state.words[4])))
  world:Deliver()
  equal(true, says("fourtiles_they_found"))
  equal(16, first.private.Match.State(first.matches[id]).score)
  equal(0, #Client.Find(function(widget)
    return widget.kind == "Button" and widget.text == "fourtiles_wrap_up" and widget:IsVisible()
  end), "the game can't be called done before the five are found and the top rank reached")

  -- The two words found slid together, a row each in the order they were found
  local slide = Client.Find(function(widget)
    return widget.scripts.OnUpdate ~= nil and widget.parent == tiles[1].parent
  end)
  for _, frame in ipairs(slide) do
    frame:Fire("OnUpdate", 1)
  end
  local function spot(tile)
    local anchor = tile.anchors[1]
    return anchor[4] .. "," .. anchor[5]
  end
  local function rows()
    local byTop, tops = {}, {}
    for index, tile in ipairs(tiles) do
      local anchor = tile.anchors[1]
      if not byTop[anchor[5]] then
        byTop[anchor[5]], tops[#tops + 1] = {}, anchor[5]
      end
      table.insert(byTop[anchor[5]], { left = anchor[4], text = state.tiles[index] })
    end
    table.sort(tops, function(a, b)
      return a > b
    end)
    local text = {}
    for number, top in ipairs(tops) do
      table.sort(byTop[top], function(a, b)
        return a.left < b.left
      end)
      local parts = {}
      for _, tile in ipairs(byTop[top]) do
        parts[#parts + 1] = tile.text
      end
      text[number] = table.concat(parts)
    end
    return text
  end
  equal(state.words[2], rows()[1])
  equal(state.words[4], rows()[2])

  -- Shuffling moves the other tiles about and loses none. They slide to where they go, and none
  -- of them is anywhere yet before the slide is over
  local before, spots = {}, {}
  for index, tile in ipairs(tiles) do
    before[index] = spot(tile)
    spots[before[index]] = true
  end
  Client.Button("fourtiles_shuffle"):Fire("OnClick")
  local after = fourtilesOnScreen()
  for index = 1, 20 do
    equal(state.tiles[index]:lower(), after[index].label.text)
    equal(before[index], spot(after[index]), "it hasn't set off yet")
  end
  for _, frame in ipairs(slide) do
    frame:Fire("OnUpdate", 0.2)
  end
  local moving = 0
  for index = 1, 20 do
    moving = moving + (spots[spot(after[index])] and 0 or 1)
  end
  assert(moving > 0, "halfway there, tiles are between the places")
  for _, frame in ipairs(slide) do
    frame:Fire("OnUpdate", 1)
  end
  local taken = {}
  for index = 1, 20 do
    local at = spot(after[index])
    equal(true, spots[at], "every tile ends up in a place")
    equal(nil, taken[at], "and no two in the same one")
    taken[at] = true
  end
  equal(state.words[2], rows()[1], "the words found aren't shuffled")
  equal(state.words[4], rows()[2], "the words found aren't shuffled")
  MainFrame.Refresh()
end

function tests.WindowCallsFourtilesDoneWhenAskedTwice()
  local world, first, second, id = gameOnScreen("fourtiles")
  local private = first.private
  local state = private.Match.State(first.matches[id])
  local function wrap()
    return Client.Find(function(widget)
      return widget.kind == "Button" and (widget.text == "fourtiles_wrap_up" or widget.text == "fourtiles_wrap_up_again") and widget:IsVisible()
    end)[1]
  end

  for _, word in ipairs(state.words) do
    assert(first.session:Move(id, fourtilesMove(state, word)))
  end
  equal(nil, wrap(), "eighty points aren't the top rank")
  for _, word in pairs(fourtilesWords(private, state, 2)) do
    if state.score < 100 then
      assert(second.session:Move(id, word.move))
      world:Deliver()
    end
  end
  state = private.Match.State(first.matches[id])
  assert(state.score >= 100)
  equal("fourtiles_wrap_up", wrap().text)

  wrap():Fire("OnClick")
  equal("active", first.matches[id].status, "once is only asking")
  equal("fourtiles_wrap_up_again", wrap().text)
  wrap():Fire("OnClick")
  world:Deliver()
  equal("finished", first.matches[id].status)
  equal("finished", second.matches[id].status)
  equal(true, private.Match.Result(first.matches[id]).all)
  equal("status_won_with", private.MainFrame.Describe(first.matches[id]))
  equal(nil, wrap())
  -- Written across the board, once it has faded in
  equal(1, #Client.Find(function(widget)
    return widget.text == "fourtiles_done"
  end))
end

-----------------------------
-- Rooms
-----------------------------

--- A guild, a group and whoever is in neither, with rooms that talk to each other through a
--- network that says on a channel what was said on it to everyone who has it, the sender too
--- @class RoomWorld
local RoomWorld = {}
RoomWorld.__index = RoomWorld

function RoomWorld.New()
  return setmetatable({ clock = 5000, players = {}, order = {}, queue = {}, sent = {}, seed = 0 }, RoomWorld)
end

--- @param name string
--- @param channels table<string, boolean>? The channels the player has, none if left out
--- @param heardAs string? The name what they send comes from, if not the one they know themselves by
function RoomWorld:Add(name, channels, heardAs)
  local player = { name = name, channels = channels or {}, events = {}, online = true, private = loadEngine() }
  local from = heardAs or name
  player.from = from
  player.Sketch = player.private.Sketch
  player.Trivia = player.private.Trivia
  player.rooms = player.private.Rooms.New({
    me = name,
    now = function()
      return self.clock
    end,
    random = function(max)
      self.seed = self.seed + 1
      return (self.seed * 7) % max + 1
    end,
    broadcast = function(channel, text)
      if not player.channels[channel] then
        return false
      end
      self.queue[#self.queue + 1] = { from = from, channel = channel, text = text }
      return true
    end,
    send = function(target, text)
      self.queue[#self.queue + 1] = { from = from, to = target, text = text }
      return true
    end,
    onChannel = function(channel)
      return player.channels[channel] == true
    end,
    reaches = function(channel, other)
      return self.players[other] ~= nil and self.players[other].channels[channel] == true
    end,
    notify = function(event, subject)
      player.events[#player.events + 1] = event
      if event == "open" then
        player.heard = subject
      elseif event == "refused" then
        player.refused = subject
      end
    end,
  })
  self.players[from] = player
  self.order[#self.order + 1] = player
  return player
end

function RoomWorld:Deliver()
  local guard = 0
  while #self.queue > 0 do
    guard = guard + 1
    assert(guard < 5000, "Message storm in a room")
    local message = table.remove(self.queue, 1)
    self.sent[#self.sent + 1] = message.from .. ">" .. (message.to or message.channel) .. " " .. message.text
    for _, player in ipairs(self.order) do
      local hears = message.to == player.name or message.to == player.from or (message.channel and player.channels[message.channel])
      if hears and player.online then
        player.rooms:Handle(message.from, message.text, message.channel)
      end
    end
  end
end

--- Lets time pass, a quarter of a second at a time as the client would
--- @param seconds number
function RoomWorld:Run(seconds)
  self:Deliver()
  for _ = 1, math.ceil(seconds * 4) do
    self.clock = self.clock + 0.25
    for _, player in ipairs(self.order) do
      if player.online then
        player.rooms:Tick()
      end
    end
    self:Deliver()
  end
end

--- A room of Sketch that Alice opened for her guild, with Bob and Carol in it
--- @param heardAs table<string, string>? By first name, what the client says a player's messages come from
--- @return RoomWorld, table alice, table bob, table carol
local function sketchRoom(heardAs)
  heardAs = heardAs or {}
  local world = RoomWorld.New()
  local guild = { GUILD = true }
  local alice, bob = world:Add("Alice-Realm", guild, heardAs.Alice), world:Add("Bob-Realm", guild, heardAs.Bob)
  local carol = world:Add("Carol-Realm", guild, heardAs.Carol)
  local room = assert(alice.rooms:Open("sketch", "GUILD"))
  world:Run(1)
  for _, player in ipairs({ bob, carol }) do
    equal(room.id, player.heard.id, "heard of the room")
    assert(player.rooms:Join(room.id))
    world:Run(2)
  end
  return world, alice, bob, carol
end

--- Starts the game and has whoever is to draw pick the first thing on offer
--- @return table drawer, string word
local function sketchRound(world, players)
  local drawer
  for _, player in ipairs(players) do
    local room = player.rooms.room
    equal("pick", room.state.phase, player.name .. " knows a round began")
    if room.state.drawer == room.me then
      drawer = player
    end
  end
  drawer.Sketch.Choose(drawer.rooms.room, 1)
  world:Run(1)
  return drawer, drawer.rooms.room.state.word
end

local function scoresOf(player)
  local scores = {}
  for _, member in ipairs(player.rooms.room:Members()) do
    scores[#scores + 1] = member.name:sub(1, 1) .. member.score
  end
  return table.concat(scores, " ")
end

local function pictureOf(player)
  local lines = {}
  for _, stroke in ipairs(player.rooms.room.state.strokes) do
    lines[#lines + 1] = stroke.color .. stroke.width .. ":" .. table.concat(stroke.points, ",")
  end
  return table.concat(lines, " ")
end

function tests.RoomIsJoinedByWhoeverHearsOfIt()
  local world, alice, bob, carol = sketchRoom()
  for _, player in ipairs({ alice, bob, carol }) do
    equal(3, player.rooms.room.count, player.name .. " knows who is there")
    equal("Alice-Realm", player.rooms.room.host)
  end
  equal(2, bob.rooms.room.me)
  equal(3, carol.rooms.room.me)
  equal(false, bob.rooms.room.direct)

  -- Somebody who logs in later asks what there is
  local dave = world:Add("Dave-Realm", { GUILD = true })
  assert(dave.rooms:Look())
  world:Run(1)
  equal(1, #dave.rooms:Known())
  assert(dave.rooms:Join(dave.rooms:Known()[1].id))
  world:Run(2)
  equal(4, dave.rooms.room.count)
  equal(4, carol.rooms.room.count)

  carol.rooms:Leave()
  world:Run(1)
  equal(nil, carol.rooms.room)
  equal(3, alice.rooms.room.count)
  equal(3, dave.rooms.room.count)

  alice.rooms:Leave()
  world:Run(1)
  equal(nil, alice.rooms.room)
  equal(nil, bob.rooms.room, "the room goes with its host")
  equal("shut", bob.events[#bob.events] == "closed" and "shut")
end

function tests.RoomTakesInvitedGuestsOnly()
  local world, alice, bob = sketchRoom()
  local id = alice.rooms.room.id
  local erin, frank = world:Add("Erin-Realm"), world:Add("Frank-Realm")

  -- Frank got hold of the room somehow, nobody asked him
  frank.rooms:Handle("Alice-Realm", "1:ROOM:" .. id .. ":OPEN:sketch:1:G:0", nil)
  assert(frank.rooms:Join(id))
  world:Run(2)
  equal(nil, frank.rooms.room)
  equal("closed", frank.refused)

  assert(alice.rooms:Invite("Erin-Realm"))
  world:Run(1)
  equal(true, erin.heard.invited)
  assert(erin.rooms:Join(id))
  world:Run(3)
  equal(true, erin.rooms.room.direct, "a guest")
  equal(4, erin.rooms.room.count)
  equal(4, bob.rooms.room.count)

  -- A link lets in whoever clicks it, once there is one
  local gina = world:Add("Gina-Realm")
  assert(gina.rooms:Knock("Alice-Realm", "sketch"))
  world:Run(2)
  equal(nil, gina.rooms.room)
  equal("closed", gina.refused)
  equal("own_room", select(2, alice.rooms:Knock("Alice-Realm", "sketch")))
  equal("sketch", alice.rooms:Link().id)
  assert(gina.rooms:Knock("Alice-Realm", "sketch"))
  world:Run(3)
  equal(id, gina.rooms.room.id)
  equal("GUILD", gina.rooms.room.channel)
  equal(true, gina.rooms.room.direct)
  equal(5, bob.rooms.room.count)

  -- What the guest says reaches the guild through the host, and the other way round
  assert(alice.Sketch.Start(alice.rooms.room))
  -- Two guests to whisper on top of the guild
  world:Run(4)
  local drawer = sketchRound(world, { alice, bob, erin })
  equal(alice, drawer)
  -- The host whispers a guest everything, which takes a moment longer than saying it once
  world:Run(3)
  equal("draw", erin.rooms.room.state.phase)
  assert(erin.Sketch.Guess(erin.rooms.room, "a boat"))
  assert(bob.Sketch.Guess(bob.rooms.room, "a goat"))
  world:Run(4)
  local function said(player)
    local texts = {}
    for _, entry in ipairs(player.rooms.room.state.feed) do
      texts[#texts + 1] = entry.text
    end
    -- Two things said at the same moment are heard in one order here and in the other there
    table.sort(texts)
    return table.concat(texts, "|")
  end
  equal("a boat|a goat", said(bob))
  equal("a boat|a goat", said(alice))
  -- The guest hears their own guess at once and Bob's a moment later
  equal("a boat|a goat", said(erin))
end

function tests.RoomSendsNoFasterThanTheClientAllows()
  local world, alice = sketchRoom()
  world:Run(20)
  world.sent = {}
  for index = 1, 20 do
    alice.rooms.room:Say("G", "guess" .. index)
  end
  world:Deliver()
  equal(6, #world.sent, "what goes out at once")
  world:Run(10)
  assert(#world.sent > 10 and #world.sent < 20, "the rest follows as the allowance does")
  world:Run(30)
  equal(20, #world.sent)
end

function tests.SketchRoundIsGuessedAndScored()
  local world, alice, bob, carol = sketchRoom()
  local everyone = { alice, bob, carol }
  equal(false, (bob.Sketch.Start(bob.rooms.room)), "only the host starts")
  assert(alice.Sketch.Start(alice.rooms.room))
  world:Run(1)
  local drawer, word = sketchRound(world, everyone)
  equal(alice, drawer)
  for _, player in ipairs(everyone) do
    equal("draw", player.rooms.room.state.phase)
  end
  equal(nil, bob.rooms.room.state.word, "nobody is sent what it is")
  assert(bob.Sketch.Hint(bob.rooms.room):match("^[_ ]+$"))
  equal(false, (alice.Sketch.Guess(alice.rooms.room, word)), "whoever draws doesn't guess")

  local ok, right = bob.Sketch.Guess(bob.rooms.room, "certainly not this")
  equal(true, ok)
  equal(false, right)
  world:Run(1)
  equal("certainly not this", carol.rooms.room.state.feed[#carol.rooms.room.state.feed].text)

  -- However it is written
  ok, right = carol.Sketch.Guess(carol.rooms.room, " " .. word:upper() .. "! ")
  equal(true, right)
  world:Run(1)
  equal(true, alice.rooms.room.state.got[3])
  equal(false, (carol.Sketch.Guess(carol.rooms.room, word)), "once is enough")
  equal("draw", alice.rooms.room.state.phase, "Bob is still guessing")

  ok, right = bob.Sketch.Guess(bob.rooms.room, word)
  equal(true, right)
  world:Run(1)
  for _, player in ipairs(everyone) do
    equal("over", player.rooms.room.state.phase, "everyone got it")
    equal(word, player.rooms.room.state.word)
    equal("A4 B8 C10", scoresOf(player))
  end

  world:Run(8)
  for _, player in ipairs(everyone) do
    equal("pick", player.rooms.room.state.phase)
    equal(2, player.rooms.room.state.round)
    equal(2, player.rooms.room.state.drawer, "Bob draws next")
  end
  equal(3, #bob.rooms.room.state.choices)
  -- He doesn't pick, so he is given the first
  world:Run(16)
  equal("draw", carol.rooms.room.state.phase)
  -- And nobody gets it in time
  world:Run(82)
  equal("over", carol.rooms.room.state.phase)
  equal(bob.rooms.room.state.word, carol.rooms.room.state.word)
  equal("A4 B8 C10", scoresOf(carol))

  alice.Sketch.Stop(alice.rooms.room)
  world:Run(1)
  equal("idle", bob.rooms.room.state.phase)
  world:Run(20)
  equal("idle", bob.rooms.room.state.phase, "and it stays over")
end

function tests.SketchPictureArrivesAsItWasDrawn()
  local world, alice, bob, carol = sketchRoom()
  assert(alice.Sketch.Start(alice.rooms.room))
  world:Run(1)
  sketchRound(world, { alice, bob, carol })
  local Sketch, room = alice.Sketch, alice.rooms.room

  equal(false, bob.Sketch.Pen(bob.rooms.room, 1, 2, 10, 10), "only whoever draws draws")
  equal(true, Sketch.Pen(room, 2, 2, 10, 10))
  for step = 1, 150 do
    Sketch.Draw(room, 10 + step * 3, 10 + step % 50)
    if step % 40 == 0 then
      -- It is sent while it is drawn, not when it is done
      world:Run(1.25)
    end
  end
  Sketch.Lift(room)
  world:Run(3)
  equal(1, #bob.rooms.room.state.strokes, "one line, however many messages it came in")
  equal(302, #bob.rooms.room.state.strokes[1].points)
  equal(pictureOf(alice), pictureOf(bob))
  equal(pictureOf(alice), pictureOf(carol))

  -- A dot, off the sheet: it is put on its edge
  Sketch.Pen(room, 5, 3, 900, -4)
  Sketch.Lift(room)
  Sketch.Pen(room, 1, 1, 40, 40)
  Sketch.Draw(room, 60, 80)
  Sketch.Lift(room)
  world:Run(3)
  equal(3, #carol.rooms.room.state.strokes)
  equal("53:511,0", pictureOf(carol):match(" (%S+) "))
  equal(pictureOf(alice), pictureOf(carol))

  Sketch.Undo(room)
  world:Run(3)
  equal(2, #bob.rooms.room.state.strokes)
  equal(pictureOf(alice), pictureOf(bob))

  -- Somebody comes in late and asks for the picture
  local dave = world:Add("Dave-Realm", { GUILD = true })
  dave.rooms:Look()
  world:Run(1)
  assert(dave.rooms:Join(room.id))
  world:Run(12)
  equal("draw", dave.rooms.room.state.phase)
  equal(1, dave.rooms.room.state.drawer)
  equal(pictureOf(alice), pictureOf(dave))
  assert(dave.Sketch.TimeLeft(dave.rooms.room) < 80, "with the time that is left")

  Sketch.Clear(room)
  Sketch.Pen(room, 3, 1, 5, 5)
  Sketch.Draw(room, 9, 9)
  Sketch.Lift(room)
  world:Run(3)
  equal("31:5,5,9,9", pictureOf(dave))
  equal(pictureOf(alice), pictureOf(bob))
end

-- The client may say a player's name another way than the player does ("Jeany" is heard as
-- "Jeany Beany"): the room goes by how they are heard
function tests.SketchIsSeenWhenTheHostIsHeardByAnotherName()
  local world, alice, bob, carol = sketchRoom({ Alice = "Alice Smith-Realm", Bob = "Bob Jones-Realm" })
  equal("Alice Smith-Realm", bob.rooms.room.host)
  equal("Alice Smith-Realm", bob.rooms.room.members[1].name, "the host is who the host is heard as")
  assert(alice.Sketch.Start(alice.rooms.room))
  world:Run(1)
  local drawer, word = sketchRound(world, { alice, bob, carol })
  equal(alice, drawer)
  local Sketch, room = alice.Sketch, alice.rooms.room
  Sketch.Pen(room, 2, 2, 10, 10)
  Sketch.Draw(room, 60, 80)
  Sketch.Lift(room)
  world:Run(3)
  equal("22:10,10,60,80", pictureOf(bob), "the host's drawing gets there")
  equal(pictureOf(alice), pictureOf(carol))

  -- What Bob says himself is heard back by his other name, and is said once
  assert(bob.Sketch.Guess(bob.rooms.room, "certainly not this"))
  world:Run(1)
  local said = 0
  for _, entry in ipairs(bob.rooms.room.state.feed) do
    said = said + (entry.text == "certainly not this" and 1 or 0)
  end
  equal(1, said)
  local _, right = carol.Sketch.Guess(carol.rooms.room, word)
  equal(true, right)
  world:Run(1)
  equal(scoresOf(alice), scoresOf(bob))
  equal(scoresOf(alice), scoresOf(carol))
end

function tests.SketchSkipsWhoeverIsNotThere()
  local world, alice, bob, carol = sketchRoom()
  assert(alice.Sketch.Start(alice.rooms.room))
  world:Run(1)
  sketchRound(world, { alice, bob, carol })
  world:Run(82)
  equal("over", carol.rooms.room.state.phase)

  -- Bob's client is gone without a word, and it is his turn
  bob.online = false
  world:Run(8)
  equal(2, carol.rooms.room.state.drawer)
  equal("pick", carol.rooms.room.state.phase)
  world:Run(25)
  equal("over", carol.rooms.room.state.phase, "the host gives up on him")
  world:Run(8)
  equal(3, carol.rooms.room.state.round)
  equal(3, carol.rooms.room.state.drawer)
  -- And doesn't ask him again while he says nothing
  carol.Sketch.Choose(carol.rooms.room, 2)
  world:Run(82)
  world:Run(8)
  equal(4, alice.rooms.room.state.round)
  equal(1, alice.rooms.room.state.drawer)

  -- Whoever draws leaves in the middle of it
  alice.Sketch.Choose(alice.rooms.room, 1)
  world:Run(82)
  world:Run(8)
  equal(3, alice.rooms.room.state.drawer)
  carol.Sketch.Choose(carol.rooms.room, 1)
  world:Run(1)
  carol.rooms:Leave()
  world:Run(1)
  equal("over", alice.rooms.room.state.phase)
end

function tests.PartyPagesSetUpARoomAndPlayIt()
  local world = RoomWorld.New()
  local guild = { GUILD = true }
  local alice, bob = world:Add("Alice-Realm", guild), world:Add("Bob-Realm", guild)
  Client.Install()
  ForeverGames = { db = { profile = { sound = true } }, printed = {} }
  function ForeverGames:Print(text)
    self.printed[#self.printed + 1] = text
  end
  function UnitIsPlayer()
    return false
  end
  local private, linked = alice.private, nil
  private.ICON = "icon"
  private.rooms = alice.rooms
  private.Transport = {
    DisplayName = function(name)
      return name
    end,
    Normalize = function(name)
      return name ~= "" and name or nil
    end,
  }
  private.Links = {
    Insert = function(game)
      linked = game
    end,
  }
  local mainShown = false
  private.MainFrame = {
    Open = function()
      mainShown = true
    end,
    Hide = function()
      mainShown = false
    end,
    IsShown = function()
      return mainShown
    end,
    Refresh = function()
      private.Party.Refresh()
    end,
  }
  for _, file in ipairs({ "GUI/Widgets.lua", "GUI/Canvas.lua", "GUI/Party.lua" }) do
    assert(loadfile(file))(ADDON_NAME, private)
  end
  local Party = private.Party
  Party.Init(UIParent)
  Party.Open("sketch")
  equal(true, Party.IsOpen())

  -- Set up the way the wizard sets a game up: who for, and how it is played
  local function audience(text)
    return Client.Find(function(widget)
      return widget.label ~= nil and widget.label.text == text and widget:IsVisible()
    end)[1]
  end
  equal(1, audience("party_for_GUILD"):GetAlpha(), "Alice is in a guild")
  equal(0.45, audience("party_for_GROUP"):GetAlpha(), "and in no group")
  audience("party_for_GROUP"):Fire("OnClick")
  equal("party_summary_GUILD", Client.Find(function(widget)
    return widget.text == "party_summary_GUILD" and widget:IsVisible()
  end)[1].text, "a room can't be for a group she isn't in")
  audience("sketch_list_w"):Fire("OnClick")
  Client.Button("party_open_room"):Fire("OnClick")
  world:Run(1)
  local room = alice.rooms.room
  equal("w", room.state.list)
  equal("GUILD", room.channel)
  equal("w", ForeverGames.db.profile.rules.sketch.list, "and it is set up that way next time")
  assert(bob.rooms:Join(room.id))
  world:Run(2)
  Party.Refresh()

  -- Anyone at all can be let in by a link
  Client.Button("party_link"):Fire("OnClick")
  equal("sketch", linked.id)
  equal(true, room.linked)

  Client.Button("sketch_start"):Fire("OnClick")
  world:Run(1)
  Party.Refresh()
  equal("pick", bob.rooms.room.state.phase)
  local word = room.state.choices[2]
  Client.Button(word):Fire("OnClick")
  world:Run(1)
  Party.Refresh()
  equal(word, room.state.word)

  -- The sheet is the one thing on screen that takes the mouse down and watches it move
  local sheets = Client.Find(function(widget)
    return widget.scripts.OnMouseDown and widget.scripts.OnUpdate and widget.scripts.OnMouseUp and widget:IsVisible()
  end)
  equal(1, #sheets)
  local sheet = sheets[1]
  local scale = sheet.width / 512
  Client.cursor, Client.mouseDown = { 100 * scale, sheet.height - 50 * scale }, true
  sheet:Fire("OnMouseDown", "LeftButton")
  Client.cursor = { 200 * scale, sheet.height - 150 * scale }
  sheet:Fire("OnUpdate", 0.02)
  Client.mouseDown = false
  sheet:Fire("OnUpdate", 0.02)
  world:Run(2)
  equal("12:100,50,200,150", pictureOf(alice))
  equal("12:100,50,200,150", pictureOf(bob))

  -- Made small while it is her turn it stays small: she asked for it
  Client.Button("party_small"):Fire("OnClick")
  equal(false, mainShown, "the big window is out of the way")
  equal(true, Party.IsOpen())
  assert(Client.Button("party_grow"))
  world:Run(90)
  Party.Refresh()
  equal(2, room.state.drawer, "Bob's turn")
  equal(false, mainShown)

  -- On her next turn the room is whole again, and small after it
  world:Run(16 + 82 + 8)
  equal(1, room.state.drawer)
  Party.Refresh()
  equal(true, mainShown, "her turn")
  assert(Client.Button("party_small"))
  world:Run(16 + 82)
  Party.Refresh()
  equal(false, mainShown, "back in its corner")
  assert(Client.Button("party_grow"))

  -- Whole again by hand, and out of the room
  Client.Button("party_grow"):Fire("OnClick")
  equal(true, mainShown)
  Client.Button("party_close"):Fire("OnClick")
  world:Run(1)
  Party.Refresh()
  equal(nil, alice.rooms.room)
  equal(nil, bob.rooms.room)
  assert(Client.Button("party_open_room"), "back to setting one up")
end

--- A bracket of these many, drawn in order
--- @param count number
--- @return BracketDuel[]
local function drawOf(count)
  local players = {}
  for n = 1, count do
    players[n] = n
  end
  return loadEngine().Bracket.Draw(players)
end

function tests.BracketHalvesDownToOne()
  local Bracket = loadEngine().Bracket
  -- However many, whoever is left over goes through the first round, and every round after it
  -- is a power of two
  for count = 2, 40 do
    local duels = drawOf(count)
    local size = 1
    while size < count do
      size = size * 2
    end
    equal(size / 2, #duels, count .. " fill a bracket of " .. size)
    equal(count, Bracket.Left(duels))
    local seen = {}
    for _, duel in ipairs(duels) do
      for _, n in ipairs({ duel.a, duel.b }) do
        equal(nil, seen[n], "nobody is drawn twice")
        seen[n] = true
      end
    end

    -- The first of every pair wins, until one is left
    local rounds = 0
    while duels do
      rounds = rounds + 1
      for _, duel in ipairs(duels) do
        duel.winner = duel.winner or duel.a
      end
      equal(true, Bracket.Decided(duels))
      local champion
      duels, champion = Bracket.Next(duels, function()
        return 1
      end)
      if not duels then
        assert(champion, "somebody won")
      else
        for _, duel in ipairs(duels) do
          assert(duel.b, "nobody goes through after the first round")
        end
      end
    end
    equal(math.log(size) / math.log(2), rounds, count .. " take a round for every halving")
  end
end

function tests.BracketGoesOnWithoutWhoeverIsGone()
  local Bracket = loadEngine().Bracket
  local duels = drawOf(8)
  equal(false, Bracket.IsFinal(duels))
  equal(false, Bracket.Decided(duels))
  for _, duel in ipairs(duels) do
    duel.winner = duel.b
  end
  -- 2, 4, 6 and 8 won, and 4 left: 6 has nobody to meet and goes through
  local nextDuels = Bracket.Next(duels, function()
    return 1
  end, function(n)
    return n ~= 4
  end)
  equal("2-6.8", Bracket.Encode(nextDuels))
  equal(8, nextDuels[2].winner)
  equal(3, Bracket.Left(nextDuels))

  -- A duel won by nobody sends nobody through
  nextDuels[1].winner = 0
  equal(1, Bracket.Left(nextDuels))
  local after, champion = Bracket.Next(nextDuels, function()
    return 1
  end)
  equal(nil, after)
  equal(8, champion)
  equal(nil, select(2, Bracket.Next({ { a = 1, b = 2, winner = 0 } }, math.random)), "nobody won it")
end

function tests.BracketIsSentAsText()
  local Bracket = loadEngine().Bracket
  local duels = Bracket.Decode("3-5.7.2-9")
  equal(3, #duels)
  equal(5, duels[1].b)
  equal(nil, duels[1].winner)
  equal(7, duels[2].winner, "on their own goes through")
  equal("3-5.7.2-9", Bracket.Encode(duels))
  equal(duels[3], Bracket.ByPlayer(duels)[9])
  equal(2, Bracket.OtherOf(duels[3], 9))
  equal(nil, Bracket.OtherOf(duels[2], 7))
  equal(true, Bracket.IsFinal(Bracket.Decode("4-1")))
  equal(nil, Bracket.Decode(""))
  equal(nil, Bracket.Decode("3-x"))
  equal(nil, Bracket.Decode("3-5.-2"))
end

function tests.RoomTellsALongListInPieces()
  local world = RoomWorld.New()
  local guild = { GUILD = true }
  local alice, bob = world:Add("Alice-Realm", guild), world:Add("Bob-Realm", guild)
  local room = assert(alice.rooms:Open("sketch", "GUILD"))
  world:Run(1)
  assert(bob.rooms:Join(room.id))
  world:Run(5)

  local entries = {}
  for index = 1, 120 do
    entries[index] = index .. "/" .. ("x"):rep(index % 7)
  end
  local heard = {}
  local game = bob.private.Rooms.Game("sketch")
  local receive = game.receive
  game.receive = function(_, member, kind, fields)
    if kind == "LST" then
      equal("7", fields[1])
      equal("y", fields[2])
      for entry in fields[3]:gmatch("[^.]+") do
        heard[#heard + 1] = entry
      end
    end
  end
  local before = #world.sent
  room:TellList(room.members[bob.rooms.room.me], "LST", entries, 7, "y")
  world:Run(30)
  game.receive = receive
  equal(table.concat(entries, ","), table.concat(heard, ","), "all of it, in order")
  local pieces = 0
  for index = before + 1, #world.sent do
    local text = world.sent[index]
    if text:find(":LST:", 1, true) then
      pieces = pieces + 1
      equal(true, #text:match("^%S+ (.*)$") <= 255, "every piece fits in a message")
    end
  end
  equal(true, pieces > 1, "it took more than one")
end

function tests.RoomShufflesTheSameWayForTheSameRolls()
  local world = RoomWorld.New()
  local alice = world:Add("Alice-Realm", { GUILD = true })
  local room = assert(alice.rooms:Open("sketch", "GUILD"))
  local list = room:Shuffle({ 1, 2, 3, 4, 5, 6 })
  table.sort(list)
  equal("1,2,3,4,5,6", table.concat(list, ","), "nothing lost or doubled")
  world.seed = 0
  local first = table.concat(room:Shuffle({ "a", "b", "c", "d" }), "")
  world.seed = 0
  equal(first, table.concat(room:Shuffle({ "a", "b", "c", "d" }), ""))
end

--- Questions to ask in a test, whatever the real ones are
local TRIVIA_BANK = {
  g = {
    { "What colour is the sky on a clear day?", "Blue", "Green", "Red", "Purple" },
    { "Water boils at 100 degrees Celsius at sea level.", "True", "False" },
    { "How many legs has a spider?", "Eight", "Six", "Ten", "Four" },
  },
  w = {
    { "Who is the son of Durotan?", "Thrall", "Rexxar", "Garona", "Varok" },
    { "What is the capital of the night elves?", "Darnassus", "Ironforge", "Stormwind", "Undercity" },
    { "Arthas was a paladin before taking up Frostmourne.", "True", "False" },
  },
}

--- A room of Trivia that Alice opened for her guild, with as many more in it as are named, and
--- the questions above to ask
--- @param names string[]
--- @param rules table?
--- @param heardAs table<string, string>? By first name, what the client says a player's messages come from
--- @return RoomWorld, table[] players Alice first
local function triviaRoom(names, rules, heardAs)
  heardAs = heardAs or {}
  local world = RoomWorld.New()
  local guild = { GUILD = true }
  local players = { world:Add("Alice-Realm", guild, heardAs.Alice) }
  players[1].private.TriviaQuestions = TRIVIA_BANK
  for _, name in ipairs(names) do
    players[#players + 1] = world:Add(name .. "-Realm", guild, heardAs[name])
  end
  local room = assert(players[1].rooms:Open("trivia", "GUILD", rules or { pack = "m", count = 3, seconds = 10 }))
  world:Run(1)
  for index = 2, #players do
    equal(room.id, players[index].heard.id, "heard of the room")
    assert(players[index].rooms:Join(room.id))
    world:Run(1)
  end
  world:Run(10)
  return world, players
end

--- The player whose answer is the right one to the question that is up
--- @param host table
--- @return number
local function rightAnswer(host)
  return host.rooms.room.state.secret
end

--- Runs the clock until the question that is up can be answered
--- @param world RoomWorld
local function untilOpen(world)
  world:Run(3)
end

function tests.TriviaQuizIsAskedAndScored()
  local world, players = triviaRoom({ "Bob", "Carol" })
  local alice, bob, carol = players[1], players[2], players[3]
  local room = alice.rooms.room
  equal(false, (bob.Trivia.Start(bob.rooms.room)), "only the host starts")
  assert(alice.Trivia.Start(room))
  world:Run(0.25)

  -- Everybody has the same question, and nobody answers it before they could read it
  local asked = room.state.question
  for _, player in ipairs(players) do
    local state = player.rooms.room.state
    equal("ask", state.phase, player.name .. " was asked")
    equal(1, state.k)
    equal(3, state.total)
    equal(asked, state.question)
    equal(table.concat(room.state.answers, ","), table.concat(state.answers, ","))
    equal(false, player.Trivia.CanAnswer(player.rooms.room), "still reading")
  end
  equal(nil, bob.rooms.room.state.secret, "only the host knows the answer")
  local right = rightAnswer(alice)
  local wrong = right == 1 and 2 or 1
  equal(false, bob.Trivia.Answer(bob.rooms.room, right), "too soon")

  -- Bob gets it in a second, Carol gets it wrong, Alice never answers
  untilOpen(world)
  world:Run(1)
  assert(bob.Trivia.Answer(bob.rooms.room, right))
  equal(false, bob.Trivia.Answer(bob.rooms.room, wrong), "one answer each")
  assert(carol.Trivia.Answer(carol.rooms.room, wrong))
  world:Run(0.25)
  equal(2, (alice.Trivia.Answered(room)))
  equal("ask", room.state.phase, "the host waits for Alice")
  world:Run(11)
  for _, player in ipairs(players) do
    local state = player.rooms.room.state
    equal("reveal", state.phase, player.name .. " was told the answer")
    equal(right, state.right)
    equal(scoresOf(alice), scoresOf(player), player.name .. " counted the same")
  end
  local points = bob.rooms.room.state.gained[2]
  equal(true, points > 900 and points <= 1000, "quick is worth nearly all of it")
  equal("A0 B" .. points .. " C0", scoresOf(alice))
  equal(1, bob.rooms.room.state.streak)
  equal(0, carol.rooms.room.state.streak)

  -- Once everyone answered there is no use waiting
  world:Run(6)
  equal(2, room.state.k, "the next question")
  untilOpen(world)
  right = rightAnswer(alice)
  for _, player in ipairs(players) do
    assert(player.Trivia.Answer(player.rooms.room, right))
  end
  world:Run(0.5)
  equal("reveal", carol.rooms.room.state.phase)
  -- Bob had the last one right as well
  equal(true, bob.rooms.room.state.gained[2] > alice.rooms.room.state.gained[1])
  equal(scoresOf(alice), scoresOf(carol))

  -- And the last, after which it is over
  world:Run(6)
  equal(3, room.state.k)
  world:Run(25)
  for _, player in ipairs(players) do
    equal("over", player.rooms.room.state.phase, player.name .. " knows it is over")
  end
  equal("Bob-Realm", alice.Trivia.Standings(room)[1].name)

  -- And again, everyone with nothing
  assert(alice.Trivia.Start(room))
  world:Run(0.25)
  equal("A0 B0 C0", scoresOf(bob))
  equal(0, bob.rooms.room.state.streak)
end

function tests.TriviaCountsTheHostHeardByAnotherName()
  local world, players = triviaRoom({ "Bob" }, nil, { Alice = "Alice Smith-Realm", Bob = "Bob Jones-Realm" })
  local alice, bob = players[1], players[2]
  local room = alice.rooms.room
  assert(alice.Trivia.Start(room))
  world:Run(0.25)
  untilOpen(world)
  local right = rightAnswer(alice)
  assert(alice.Trivia.Answer(room, right))
  world:Run(0.25)
  equal(1, (bob.Trivia.Answered(bob.rooms.room)), "Bob knows Alice answered")
  assert(bob.Trivia.Answer(bob.rooms.room, right))
  world:Run(0.5)
  equal("reveal", bob.rooms.room.state.phase)
  equal(true, bob.rooms.room.members[1].score > 0, "the host's points count for the host")
  equal(scoresOf(alice), scoresOf(bob))
end

function tests.TriviaWorthLessTheLaterAndMoreInARow()
  local Trivia = loadEngine().Trivia
  equal(1000, Trivia.Points(0, 10, 0))
  equal(750, Trivia.Points(5000, 10, 0))
  equal(500, Trivia.Points(10000, 10, 0))
  equal(500, Trivia.Points(60000, 10, 0), "never less than the least")
  equal(1200, Trivia.Points(0, 10, 2))
  equal(1500, Trivia.Points(0, 10, 9), "a streak is only worth so much")
end

function tests.TriviaQuestionTooLongForOneMessage()
  local world, players = triviaRoom({ "Bob" })
  local alice, bob = players[1], players[2]
  local long = ("A question that goes on and on "):rep(8) .. "and ends?"
  alice.private.TriviaQuestions = { g = { { long, "Yes it does", "No", "Maybe", "Never" } } }
  assert(alice.Trivia.Start(alice.rooms.room, { pack = "g", count = 5, seconds = 10 }))
  world:Run(0.25)
  local state = bob.rooms.room.state
  equal("ask", state.phase)
  equal(long, state.question)
  equal(4, #state.answers)
  equal(1, state.total, "there is only the one to ask")
  local sent = 0
  for _, line in ipairs(world.sent) do
    sent = sent + (line:find(":Q:1:1:", 1, true) and 1 or 0)
  end
  equal(2, sent, "in two messages")
end

function tests.TriviaStopsForAFight()
  local world, players = triviaRoom({ "Bob" })
  local alice, bob = players[1], players[2]
  local room = alice.rooms.room
  assert(alice.Trivia.Start(room))
  untilOpen(world)
  local first = room.state.question
  assert(bob.Trivia.Answer(bob.rooms.room, rightAnswer(alice)))

  -- The pull: the question that was up counts for nothing
  alice.rooms:Fighting(true)
  world:Run(0.25)
  for _, player in ipairs(players) do
    local state = player.rooms.room.state
    equal("held", state.phase, player.name .. " knows it stopped")
    equal(1, state.next)
  end
  equal("A0 B0", scoresOf(bob))
  world:Run(30)
  equal("held", bob.rooms.room.state.phase, "nothing is asked in a fight")
  equal(false, (alice.Trivia.Start(room)), "nor is a quiz begun")

  -- It goes on a little while after the fight, unless another one comes first
  alice.rooms:Fighting(false)
  world:Run(2)
  alice.rooms:Fighting(true)
  world:Run(10)
  equal("held", bob.rooms.room.state.phase)
  alice.rooms:Fighting(false)
  world:Run(5.5)
  local state = bob.rooms.room.state
  equal("ask", state.phase)
  equal(1, state.k, "the question that counted for nothing is asked again")
  equal(true, state.question ~= first, "but another one")

  -- Bob's fights are his own
  bob.rooms:Fighting(true)
  world:Run(0.25)
  equal("ask", room.state.phase)

  -- Paused by hand, it goes on by hand: the end of a fight doesn't
  untilOpen(world)
  assert(bob.Trivia.Answer(bob.rooms.room, rightAnswer(alice)))
  assert(alice.Trivia.Answer(room, rightAnswer(alice)))
  world:Run(0.5)
  equal("reveal", room.state.phase)
  assert(alice.Trivia.Pause(room))
  world:Run(0.25)
  equal(2, bob.rooms.room.state.next, "after the one that was answered")
  equal(true, bob.rooms.room.members[2].score > 0, "which counted")
  alice.rooms:Fighting(true)
  alice.rooms:Fighting(false)
  world:Run(10)
  equal("held", bob.rooms.room.state.phase)
  assert(alice.Trivia.Resume(room))
  world:Run(0.25)
  equal("ask", bob.rooms.room.state.phase)
  equal(2, bob.rooms.room.state.k)
end

function tests.TriviaIsPlayedByWhoeverComesInLate()
  local world, players = triviaRoom({ "Bob" })
  local alice, bob = players[1], players[2]
  local room = alice.rooms.room
  assert(alice.Trivia.Start(room))
  untilOpen(world)
  assert(bob.Trivia.Answer(bob.rooms.room, rightAnswer(alice)))
  world:Run(0.25)

  local frank = world:Add("Frank-Realm", { GUILD = true })
  frank.rooms:Look()
  world:Run(1)
  assert(frank.rooms:Join(room.id))
  world:Run(1)
  local state = frank.rooms.room.state
  equal("ask", state.phase)
  equal(room.state.question, state.question)
  assert(state.picks[2], "he knows Bob answered")
  equal(true, frank.Trivia.CanAnswer(frank.rooms.room), "and answers himself")
  assert(frank.Trivia.Answer(frank.rooms.room, rightAnswer(alice)))
  assert(alice.Trivia.Answer(room, rightAnswer(alice)))
  world:Run(0.5)
  equal("reveal", state.phase)
  equal(scoresOf(alice), scoresOf(frank))
  equal(scoresOf(alice), scoresOf(bob))
  equal(true, room.members[3].score > 0)
end

function tests.TriviaIsShownTheAnswerByWhoeverComesInAfterIt()
  local world, players = triviaRoom({ "Bob" })
  local alice, bob = players[1], players[2]
  local room = alice.rooms.room
  assert(alice.Trivia.Start(room))
  untilOpen(world)
  assert(bob.Trivia.Answer(bob.rooms.room, rightAnswer(alice)))
  assert(alice.Trivia.Answer(room, rightAnswer(alice)))
  world:Run(0.5)
  equal("reveal", room.state.phase)

  local frank = world:Add("Frank-Realm", { GUILD = true })
  frank.rooms:Look()
  world:Run(1)
  assert(frank.rooms:Join(room.id))
  world:Run(1)
  local state = frank.rooms.room.state
  equal("reveal", state.phase)
  equal(room.state.right, state.right)
  equal(nil, frank.Trivia.TimeLeft(frank.rooms.room), "there is nothing left to answer")
  equal(false, frank.Trivia.CanAnswer(frank.rooms.room))
  equal(scoresOf(alice), scoresOf(frank), "he is told what everyone has, and that stands")

  world:Run(6)
  equal(2, state.k, "and he is asked the next with everyone")
  equal(room.state.question, state.question)
end

function tests.TriviaAsksWhatWasNotAskedLately()
  local world, players = triviaRoom({ "Bob" }, { pack = "w", count = 3, seconds = 10 })
  local alice = players[1]
  local room = alice.rooms.room
  local seen = {}
  for game = 1, 2 do
    assert(alice.Trivia.Start(room, game == 2 and { pack = "m", count = 3, seconds = 10 } or nil))
    for _ = 1, 3 do
      world:Run(0.25)
      local question = room.state.question
      equal(nil, seen[question], "asked once: " .. question)
      seen[question] = true
      world:Run(25)
    end
    equal("over", room.state.phase)
  end
  -- Three about Warcraft, then the three general ones nobody was asked yet
  local general = 0
  for _, entry in ipairs(TRIVIA_BANK.g) do
    general = general + (seen[entry[1]] and 1 or 0)
  end
  equal(3, general)
end

function tests.TriviaQuestionsAreFitToAsk()
  local bank = loadEngine().TriviaQuestions
  local seen = {}
  for _, pack in ipairs({ "g", "w" }) do
    local questions = bank[pack]
    equal(true, #questions >= 120, "enough questions in " .. pack .. ": " .. #questions)
    for _, entry in ipairs(questions) do
      local question = entry[1]
      local label = pack .. ": " .. tostring(question)
      equal(true, #entry == 3 or #entry == 5, "two or four answers to " .. label)
      equal(nil, seen[question], "asked twice: " .. label)
      seen[question] = true
      equal(true, #question <= 110, "short enough: " .. label)
      local answers = {}
      for index, text in ipairs(entry) do
        equal("string", type(text), label)
        equal(nil, text:find("[^\32-\126]"), "plain ASCII: " .. text)
        equal(nil, text:find("[:|]"), "no colons or bars: " .. text)
        equal(text, text:gsub("^%s+", ""):gsub("%s+$", ""), "no blanks around: " .. text)
        if index > 1 then
          equal(true, #text <= 28 and #text > 0, "an answer short enough: " .. text)
          equal(nil, answers[text:lower()], "the same answer twice in " .. label)
          answers[text:lower()] = true
        end
      end
      if #entry == 3 then
        equal(true, answers["true"] and answers["false"], "True and False to " .. label)
      end
    end
  end
end

function tests.TriviaPageAnswersAndShowsTheRightOne()
  local world, players = triviaRoom({ "Bob" })
  local alice, bob = players[1], players[2]
  Client.Install()
  ForeverGames = { db = { profile = { sound = true } }, printed = {} }
  function ForeverGames:Print(text)
    self.printed[#self.printed + 1] = text
  end
  local private = alice.private
  private.ICON = "icon"
  private.rooms = alice.rooms
  private.Transport = {
    DisplayName = function(name)
      return (name:gsub("%-.*", ""))
    end,
  }
  private.MainFrame = {
    Open = function() end,
    Hide = function() end,
    IsShown = function()
      return true
    end,
    Refresh = function()
      private.Party.Refresh()
    end,
  }
  for _, file in ipairs({ "GUI/Widgets.lua", "GUI/Party.lua" }) do
    assert(loadfile(file))(ADDON_NAME, private)
  end
  local Party = private.Party
  Party.Init(UIParent)
  Party.Open()
  Party.Refresh()
  local function shown(text)
    return #Client.Find(function(widget)
      return widget.text == text and widget:IsVisible()
    end) > 0
  end
  local room = alice.rooms.room
  equal(true, shown("trivia_rules_line"))
  Client.Button("trivia_start"):Fire("OnClick")
  world:Run(0.25)
  Party.Refresh()
  equal("ask", room.state.phase)
  equal(true, shown(room.state.question))
  equal(true, shown("trivia_get_ready"))

  -- Click the right answer, after Bob gets it wrong
  untilOpen(world)
  Party.Refresh()
  local right = rightAnswer(alice)
  assert(bob.Trivia.Answer(bob.rooms.room, right == 1 and 2 or 1))
  local buttons = Client.Find(function(widget)
    return widget.kind == "Button" and widget.text == nil and widget.index == right and widget:IsVisible()
  end)
  equal(1, #buttons, "the answer is there to click")
  buttons[1]:Fire("OnClick")
  world:Run(0.5)
  Party.Refresh()
  equal("reveal", room.state.phase)
  equal(true, shown("trivia_right"))
  equal(true, room.members[1].score > 0)
  equal(true, shown("trivia_pause"), "the host can stop it")

  -- Made small it stays out of the way of a fight
  Client.Button("party_small"):Fire("OnClick")
  Party.Refresh()
  equal(true, Party.IsOpen())
  Client.combat = true
  Party.Refresh()
  equal(false, Party.IsOpen())
  Client.combat = false
  Party.Refresh()
  equal(true, Party.IsOpen())
end

function tests.PartyPageShowsOnlyTheGameOfTheRoomItIsIn()
  local world, players = triviaRoom({ "Bob" })
  local alice = players[1]
  Client.Install()
  ForeverGames = { db = { profile = { sound = true } }, printed = {} }
  function ForeverGames:Print(text)
    self.printed[#self.printed + 1] = text
  end
  local private = alice.private
  private.ICON = "icon"
  private.rooms = alice.rooms
  private.Transport = {
    DisplayName = function(name)
      return (name:gsub("%-.*", ""))
    end,
  }
  private.MainFrame = {
    Open = function() end,
    Hide = function() end,
    IsShown = function()
      return true
    end,
    Refresh = function()
      private.Party.Refresh()
    end,
  }
  for _, file in ipairs({ "GUI/Widgets.lua", "GUI/Canvas.lua", "GUI/Party.lua" }) do
    assert(loadfile(file))(ADDON_NAME, private)
  end
  local Party = private.Party
  Party.Init(UIParent)
  Party.Open()
  Party.Refresh()
  local function shown(text)
    return #Client.Find(function(widget)
      return widget.text == text and widget:IsVisible()
    end) > 0
  end
  equal(true, shown("trivia_start"))

  -- Trivia is over, and the next room is for Sketch
  alice.rooms:Leave()
  world:Run(1)
  assert(alice.rooms:Open("sketch", "GUILD"))
  Party.Open()
  Party.Refresh()
  equal(false, shown("trivia_start"), "nothing of the quiz is left on the page")
  equal(false, shown("trivia_rules_line"))
  equal(true, shown("sketch_start"))
end

-----------------------------
-- The computer
-----------------------------
-- A race the tests bring along, for the computer to play: in turn everyone adds one or two to a
-- count, and whoever brings it to the goal wins. The one to move wins if they can leave the
-- count a multiple of three short of the goal, so how well the computer plays can be told
-- exactly. What else a test needs of it is set on the definition: draws, a brain that breaks,
-- something hidden.

do
local RACE_GOAL = 10

--- @param private table
--- @param changes table? What to put in place of the usual, by field. `computer` too
local function registerRace(private, changes)
  local game = {
    id = "race",
    name = "Race",
    version = 1,
    seats = { 2, 3, 4 },
    newState = function(seats)
      return { count = 0, turn = 1, seats = seats, out = {} }
    end,
    turn = function(state)
      return state.turn
    end,
    validate = function(state, seat, move)
      if seat ~= state.turn then
        return false, "not_your_turn"
      end
      return (move == "1" or move == "2") and state.count + tonumber(move) <= RACE_GOAL, "invalid_move"
    end,
    apply = function(state, seat, move)
      state.count = state.count + tonumber(move)
      state.last = seat
      repeat
        state.turn = state.turn % state.seats + 1
      until not state.out[state.turn]
      return { notation = move }
    end,
    moves = function(state)
      return state.count + 2 <= RACE_GOAL and { "1", "2" } or { "1" }
    end,
    result = function(state)
      return state.count == RACE_GOAL and { winner = state.last } or nil
    end,
    drop = function(state, seat)
      state.out[seat] = true
      if state.turn == seat then
        repeat
          state.turn = state.turn % state.seats + 1
        until not state.out[state.turn]
      end
    end,
    computer = {
      evaluate = function(state, seat)
        -- Whoever is to move is winning if the count isn't already a multiple of three short
        local winning = (RACE_GOAL - state.count) % 3 ~= 0
        return (state.turn == seat) == winning and 1 or -1
      end,
    },
    createView = function() end,
  }
  for key, value in pairs(changes or {}) do
    -- Taken out where it says false
    if value == false then
      game[key] = nil
    else
      game[key] = value
    end
  end
  private.Games.Register(game)
  return game
end

--- A player with nobody else around, and the race for them to play
--- @param changes table? See registerRace
--- @return World, table player
local function raceWorld(changes)
  local world = World.New()
  world.prepare = function(private)
    registerRace(private, changes)
  end
  return world, world:AddPlayer("Alice-Realm")
end

--- What the computer would play in a position, thinking it right through
--- @param private table
--- @param gameId string
--- @param state table
--- @param seat number
--- @param level string
--- @param seed number?
--- @return string
local function computerMove(private, gameId, state, seat, level, seed)
  local game = private.Games.Get(gameId)
  return private.Computer.Think(game, private.Computer.Copy(state), seat, level, seed or 1):Finish()
end

function tests.ComputerPlaysTheRaceWithoutFault()
  local private = loadEngine()
  registerRace(private)
  local game = private.Games.Get("race")
  -- From every count where there is a right move, hard finds it
  for count = 0, RACE_GOAL - 1 do
    local state = game.newState(2)
    state.count = count
    local move = computerMove(private, "race", state, 1, "hard", count)
    local winning = (RACE_GOAL - count) % 3 ~= 0
    if winning then
      equal(0, (RACE_GOAL - count - tonumber(move)) % 3, "hard leaves a multiple of three from " .. count)
    end
  end
end

function tests.ComputerTakesTheWinAndBlocksTheLoss()
  local private = loadEngine()
  local game = private.Games.Get("tictactoe")
  local function after(moves)
    local state = game.newState(2)
    for _, move in ipairs(moves) do
      game.apply(state, state.turn, move)
    end
    return state
  end
  for _, level in ipairs({ "medium", "hard" }) do
    for seed = 1, 5 do
      -- O to move, with three in a row there for the taking at 6, and X threatening 3 as well
      equal("6", computerMove(private, "tictactoe", after({ "1", "4", "2", "5", "9" }), 2, level, seed), level .. " takes the win")
      -- X threatens 1-2-3, O has nothing of its own
      equal("3", computerMove(private, "tictactoe", after({ "1", "5", "2" }), 2, level, seed), level .. " blocks")
    end
  end
end

function tests.ComputerOpensTicTacToeInTheMiddle()
  local private = loadEngine()
  local state = private.Games.Get("tictactoe").newState(2)
  for seed = 1, 5 do
    equal("5", computerMove(private, "tictactoe", state, 1, "hard", seed))
  end
end

--- Plays a game between two levels of the computer from scratch, nobody else involved
--- @param private table
--- @param gameId string
--- @param levels string[] By seat
--- @param seed number
--- @return number winner
local function computerAgainstItself(private, gameId, levels, seed)
  local game = private.Games.Get(gameId)
  local Random = private.Random
  local chance = Random.Seed("versus" .. seed)
  local state = game.newState(#levels, Random.New(chance), private.Games.Rules(game.options))
  for ply = 1, 400 do
    local outcome = game.result(state)
    if outcome then
      return outcome.winner
    end
    local seat = game.turn(state)
    local seen = game.visible and game.visible(state, seat) or state
    local move = assert(computerMove(private, gameId, seen, seat, levels[seat], Random.Stir(chance, "brain")))
    assert(game.validate(state, seat, move), levels[seat] .. " played " .. move .. ", which isn't legal")
    chance = Random.Stir(chance, move)
    game.apply(state, seat, move, Random.New(chance))
  end
  error("the game didn't end")
end

function tests.ComputerDrawsAgainstItselfAtTicTacToe()
  local private = loadEngine()
  for seed = 1, 6 do
    equal(0, computerAgainstItself(private, "tictactoe", { "hard", "hard" }, seed), "seed " .. seed)
  end
end

function tests.ComputerGetsBetterLevelByLevel()
  local private = loadEngine()
  local beaten = { easy = 0, medium = 0 }
  for _, weaker in ipairs({ "easy", "medium" }) do
    for seed = 1, 20 do
      local seats = seed % 2 == 0 and { "hard", weaker } or { weaker, "hard" }
      local winner = computerAgainstItself(private, "tictactoe", seats, seed)
      assert(winner == 0 or seats[winner] == "hard", weaker .. " beat hard, seed " .. seed)
      if winner ~= 0 then
        beaten[weaker] = beaten[weaker] + 1
      end
    end
  end
  assert(beaten.easy > beaten.medium, string.format("easy lost %d times to hard, medium %d", beaten.easy, beaten.medium))
  assert(beaten.easy >= 6, "easy only lost " .. beaten.easy .. " of 20")
end

function tests.ComputerDecidesTheSameAFrameAtATime()
  local private = loadEngine()
  local game = private.Games.Get("tictactoe")
  local state = game.newState(2)
  game.apply(state, 1, "1")
  local whole = computerMove(private, "tictactoe", state, 2, "hard", 42)

  -- A clock that moves on a millisecond every time it is looked at
  local now = 0
  local function clock()
    now = now + 1
    return now
  end
  local thinker = private.Computer.Think(game, private.Computer.Copy(state), 2, "hard", 42)
  local frames = 1
  while not thinker:Run(5, clock) do
    frames = frames + 1
    assert(frames < 100000, "never done")
  end
  assert(frames > 5, "it thought it all through in " .. frames .. " frames")
  equal(whole, thinker.move, "the move")
end

function tests.ComputerNeverChangesThePositionItIsShown()
  local private = loadEngine()
  local game = private.Games.Get("tictactoe")
  local state = game.newState(2)
  game.apply(state, 1, "5")
  local before = private.Computer.Copy(state)
  local thinker = private.Computer.Think(game, state, 2, "hard", 3)
  thinker:Finish()
  for cell = 1, 9 do
    equal(before.board[cell], state.board[cell], "cell " .. cell)
  end
  equal(before.turn, state.turn, "turn")
end

function tests.ComputerMatchIsPlayedOutWithoutSendingAnything()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local session = alice.session
  local Match = alice.private.Match
  local match = assert(session:Invite({}, "tictactoe", { computer = { level = "hard" }, seat = 2 }))
  equal("active", match.status)
  equal(2, match.me)
  equal(true, Match.IsComputer(match, 1))
  equal(true, Match.IsLocal(match))
  equal("hard", Match.Level(match))

  -- The computer goes first, and waits for nothing to
  equal(1, session:ComputerTurn(match))
  session:ThinkThrough(match.id)
  equal(1, #match.log)
  equal(true, Match.IsMyTurn(match))
  equal(false, session:NeedsAttention(match), "a game against the computer waits on nobody")

  local moves = alice.private.Games.Get("tictactoe").moves
  while match.status == "active" do
    assert(session:Move(match.id, moves(Match.State(match))[1]))
    session:ThinkThrough(match.id)
  end
  local result = Match.Result(match)
  assert(result.winner ~= 2, "the player won against hard")
  world:Tick(3600)
  world:Tick(3600)
  equal(0, #world.sent, "messages sent")
  equal(0, #session:Opponents(), "the computer is nobody to play again")
end

function tests.ComputerWaitsToBeLetMove()
  local world = World.New()
  local session = world:AddPlayer("Alice-Realm").session
  local match = assert(session:Invite({}, "tictactoe", { computer = {}, seat = 2 }))
  equal("medium", match.computers[1], "the level when none is asked for")
  equal(true, session:Think(match.id, nil, false))
  equal(true, session:ComputerReady(match))
  equal(0, #match.log, "it knows its move, and keeps it")
  equal(false, session:Think(match.id, nil, true))
  equal(1, #match.log)
  equal(false, session:Think(match.id, nil, true), "nothing to do on the player's turn")
end

function tests.ComputerAnswerIsTakenBackWithTheMove()
  local world = World.New()
  local session = world:AddPlayer("Alice-Realm").session
  local match = assert(session:Invite({}, "tictactoe", { computer = { level = "easy" }, seat = 1 }))
  equal(false, session:CanUndo(match), "nothing to take back")
  equal(true, session:CanForget(match), "nothing played, nothing to lose")
  assert(session:Move(match.id, "5"))
  session:ThinkThrough(match.id)
  assert(session:Move(match.id, match.log[2] == "1" and "9" or "1"))
  session:ThinkThrough(match.id)
  equal(4, #match.log)
  equal(false, session:CanForget(match), "walking away would be a way of never losing")

  assert(session:Undo(match.id))
  equal(2, #match.log, "the player's move and the computer's answer")
  assert(session:Undo(match.id))
  equal(0, #match.log)
  equal(false, session:CanUndo(match))

  -- Taken back while it is thinking, it thinks again about the position it is back to
  assert(session:Move(match.id, "1"))
  equal(true, session:Think(match.id, nil, false))
  assert(session:Undo(match.id))
  equal(false, session:Think(match.id, nil, true))
  equal(0, #match.log)
end

function tests.ComputerMatchCarriesOnAfterARelog()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local match = assert(alice.session:Invite({}, "tictactoe", { computer = { level = "hard" }, seat = 1 }))
  assert(alice.session:Move(match.id, "5"))
  alice.session:Think(match.id, nil, false)

  local again = world:Relog(alice)
  local saved = again.matches[match.id]
  equal(1, #saved.log, "what it hadn't played yet isn't kept")
  again.session:ThinkThrough(match.id)
  equal(2, #saved.log)
  equal(true, again.private.Match.IsMyTurn(saved))
end

function tests.ComputerGamesAreTalliedOnce()
  local world, alice = raceWorld()
  local session = alice.session
  for game = 1, 3 do
    local match = assert(session:Invite({}, "race", { computer = { level = "hard" }, seat = 1 }))
    if game == 3 then
      assert(session:Resign(match.id))
    else
      -- Seated first the player can win it: three, then whatever leaves a multiple of three
      local Match = alice.private.Match
      assert(session:Move(match.id, "1"))
      session:ThinkThrough(match.id)
      while match.status == "active" do
        local count = Match.State(match).count
        local move = (RACE_GOAL - count - 1) % 3 == 0 and "1" or "2"
        assert(session:Move(match.id, move))
        session:ThinkThrough(match.id)
      end
      equal(1, Match.Result(match).winner, "the player")
    end
    session:Tally(match)
  end
  local tally = session:Versus("race", "hard")
  equal(2, tally.won)
  equal(1, tally.lost)
  equal(0, tally.drawn)
  equal(0, session:Versus("race", "easy").won)
end

function tests.ComputerAcceptsADrawOnlyWhenItIsNoBetterOff()
  for _, case in ipairs({ { standing = -1, accepts = true }, { standing = 0, accepts = true }, { standing = 1, accepts = false } }) do
    local world, alice = raceWorld({
      seats = 2,
      draws = true,
      computer = {
        evaluate = function()
          return case.standing
        end,
        levels = { hard = { depth = 1 } },
      },
    })
    local session, Match = alice.session, alice.private.Match
    local match = assert(session:Invite({}, "race", { computer = { level = "hard" }, seat = 1 }))
    assert(session:OfferDraw(match.id))
    assert(session:Move(match.id, "1"))
    session:ThinkThrough(match.id)
    local result = Match.Result(match)
    if case.accepts then
      equal("agreement", result and result.detail, "standing " .. case.standing)
      equal("finished", match.status)
      equal(1, session:Versus("race", "hard").drawn)
    else
      equal(nil, result, "standing " .. case.standing)
      equal(3, #match.log, "turned down by playing on")
      equal(nil, Match.DrawOffer(match))
    end
  end
end

function tests.ComputerSeatsAsManyAsAreAskedFor()
  local world, alice = raceWorld()
  local session, Match = alice.session, alice.private.Match
  equal(nil, select(1, session:Invite({}, "race", { computer = { count = 4 } })), "five can't play")
  equal("player_count", select(2, session:Invite({}, "race", { computer = { count = 4 } })))
  equal("player_count", select(2, session:Invite({}, "race", { computer = { level = "genius" } })))

  local match = assert(session:Invite({}, "race", { computer = { level = "easy", count = 3 } }))
  equal(4, #match.players)
  local computers = 0
  for seat = 1, 4 do
    if Match.IsComputer(match, seat) then
      computers = computers + 1
      equal(Match.COMPUTER, match.players[seat])
    else
      equal("Alice-Realm", match.players[seat])
    end
  end
  equal(3, computers)
  equal(true, Match.Started(match), "everyone is there already")
  session:ThinkThrough(match.id)
  equal(true, Match.IsMyTurn(match))

  -- Out of it, the player has lost, and the computers don't play on among themselves
  assert(session:Resign(match.id))
  equal("finished", match.status)
  equal(nil, session:ComputerTurn(match))
  equal(1, session:Versus("race", "easy").lost)
  equal(0, #world.sent)
end

function tests.ComputerThatBreaksStillMoves()
  local logged = {}
  local world, alice = raceWorld({
    seats = 2,
    computer = {
      think = function()
        error("lost the thread")
      end,
    },
  })
  alice.session.env.log = function(...)
    logged[#logged + 1] = table.concat({ ... }, " ")
  end
  local match = assert(alice.session:Invite({}, "race", { computer = {}, seat = 2 }))
  alice.session:ThinkThrough(match.id)
  equal(1, #match.log, "the game goes on")
  equal("1", match.log[1], "with the first move there was")
  assert(logged[1] and logged[1]:find("lost the thread", 1, true), "what went wrong is said")
end

function tests.ComputerThatPlaysWhatIsNotAMoveIsPutRight()
  local world, alice = raceWorld({
    seats = 2,
    computer = {
      think = function()
        return "7"
      end,
    },
  })
  local match = assert(alice.session:Invite({}, "race", { computer = {}, seat = 2 }))
  alice.session:ThinkThrough(match.id)
  equal("1", match.log[1])
end

function tests.ComputerOnlySeesWhatItsSeatMay()
  local shown
  local world, alice = raceWorld({
    seats = 2,
    newState = function(seats)
      return { count = 0, turn = 1, seats = seats, out = {}, secrets = { "mine", "yours" } }
    end,
    visible = function(state, seat)
      local seen = { count = state.count, turn = state.turn, seats = state.seats, out = state.out, secrets = {} }
      seen.secrets[seat] = state.secrets[seat]
      return seen
    end,
    computer = {
      think = function(state, seat, brain)
        shown = state
        return (brain:Search(state, { "1", "2" }))
      end,
      guess = function(state, seat)
        local world = { count = state.count, turn = state.turn, seats = state.seats, out = {}, secrets = { "?", "?" } }
        world.secrets[seat] = state.secrets[seat]
        return world
      end,
    },
  })
  local match = assert(alice.session:Invite({}, "race", { computer = {}, seat = 1 }))
  assert(alice.session:Move(match.id, "1"))
  alice.session:ThinkThrough(match.id)
  equal("yours", shown.secrets[2])
  equal(nil, shown.secrets[1], "the player's secret")
  equal(2, #match.log)
end

function tests.WizardStartsAGameAgainstTheComputer()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local wizard = openWizard(alice)
  pickGame("tictactoe")
  equal("Alice-Realm, wizard_seat_open [wizard_add_computer]", (seating.Shown()))
  equal(false, Client.Button("wizard_send").enabled, "nobody in the other seat yet")

  seating.Click("wizard_add_computer")
  local shown, cards = seating.Shown()
  equal("Alice-Realm, computer [computer_level_medium]", shown)
  assert(cards[2].action.tip:find("computer_tally_none", 1, true), "nothing played against it yet")
  -- Clicked, it plays better
  seating.Click("computer_level_medium")
  equal("Alice-Realm, computer [computer_level_hard]", (seating.Shown()))
  equal(true, says("wizard_summary_computer"))
  ruleChoices("wizard_seat")["O"]:Fire("OnClick")
  local play = Client.Button("wizard_play")
  equal(true, play.enabled)
  play:Fire("OnClick")
  equal(false, wizard.IsOpen())

  local started = select(2, next(alice.matches))
  equal("tictactoe", started.game)
  equal(2, started.me)
  equal("hard", started.computers[1])
  equal(0, #world.sent)

  -- Next time it is there already, set the same way
  wizard.Open()
  pickGame("tictactoe")
  equal("Alice-Realm, computer [computer_level_hard]", (seating.Shown()))
  equal("O", select(2, ruleChoices("wizard_seat")))

  -- Typing a name is looking for somebody else to sit there instead
  local name = Client.Find(function(widget)
    return widget.kind == "EditBox" and widget.scripts.OnTextChanged and widget:IsVisible()
  end)[1]
  name:SetText("Bob-Realm")
  name:Fire("OnTextChanged", true)
  equal("Alice-Realm, Bob-Realm", (seating.Shown()))
  equal(true, Client.Button("wizard_send").enabled)

  -- A game the computer can't play doesn't offer it
  wizard.Open()
  pickGame("fourtiles")
  equal(false, says("wizard_add_computer"))
end

function tests.WizardSetsHowManySeatsTheComputerTakes()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  registerRace(alice.private)
  openWizard(alice)
  pickGame("race")
  local sizes = seating.Sizes()
  assert(sizes["2"] and sizes["3"] and sizes["4"], "every number it is for")
  equal(true, says("wizard_turn"), "between two there is a turn to choose")
  sizes["4"]:Fire("OnClick")
  equal("Alice-Realm, wizard_seat_open [wizard_add_computer], wizard_seat_open [wizard_add_computer], wizard_seat_open [wizard_add_computer]", (seating.Shown()))
  equal(false, says("wizard_turn"), "a crowd draws its seats")
  equal(true, says("wizard_table_drawn"))
  equal(false, Client.Button("wizard_send").enabled)
  for _ = 1, 3 do
    seating.Click("wizard_add_computer")
  end
  -- Each seat as good as it is set, round to the easiest after the hardest
  seating.Click("computer_level_medium", 2)
  seating.Click("computer_level_hard")
  equal("Alice-Realm, computer [computer_level_medium], computer [computer_level_easy], computer [computer_level_medium]", (seating.Shown()))
  equal(true, says("wizard_summary_computers"))
  Client.Button("wizard_play"):Fire("OnClick")
  local started = select(2, next(alice.matches))
  equal(4, #started.players)
  local levels = alice.private.Match.Levels(started)
  table.sort(levels)
  equal("easy,medium,medium", table.concat(levels, ","))
  equal("medium", alice.private.Match.Level(started), "the hardest of them")
end

-----------------------------
-- The computer at a table of people
-----------------------------

--- Alice challenges Bob to a race with the computer in some of the seats, and Bob accepts
--- @param computers number? How many seats the computer takes, two if left out
--- @return World, table alice, table bob, string id
local function mixedRace(computers)
  local world = World.New()
  world.prepare = function(private)
    -- With a view that draws nothing, for the window to have one to show
    registerRace(private, {
      createView = function()
        return { Layout = function() end, Update = function() end }
      end,
    })
  end
  local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
  local match = assert(alice.session:Invite({ "Bob-Realm" }, "race", { computer = { level = "easy", count = computers or 2 } }))
  world:Deliver()
  assert(bob.session:Accept(match.id))
  world:Deliver()
  return world, alice, bob, match.id
end

--- Delivers what is queued, making sure nothing is ever sent to one of the computer's seats
--- @param world World
local function deliverToPeople(world)
  for _, message in ipairs(world.queue) do
    assert(message.to ~= "*", "a message for the computer: " .. message.text)
  end
  world:Deliver()
end

--- Has whoever's turn it is in a race at a table of people move, the computer included where it
--- is the turn of a seat it plays, until somebody has to wait on something else
--- @param world World
--- @param players table[]
--- @param id string
--- @param stop (fun(): boolean)? Stops before the next move once it says so
local function playOn(world, players, id, stop)
  for _ = 1, 100 do
    local moved = false
    for _, player in ipairs(players) do
      local match = player.matches[id]
      if stop and stop() then
        return
      end
      if match and match.status == "active" and player.online then
        if player.private.Match.IsMyTurn(match) then
          assert(player.session:Move(id, "1"))
          moved = true
        elseif player.session:ComputerTurn(match) then
          assert(player.session:Think(id, nil, true) ~= nil)
          moved = true
        end
        deliverToPeople(world)
      end
    end
    if not moved then
      return
    end
  end
end

function tests.ComputerSitsAtATableOfPeople()
  local world, alice, bob, id = mixedRace()
  local mine, theirs = alice.matches[id], bob.matches[id]
  local Match = alice.private.Match
  equal(4, #mine.players)
  equal(table.concat(mine.players, ","), table.concat(theirs.players, ","), "everyone sits in the same seats")
  local computers = 0
  for seat = 1, 4 do
    equal(mine.computers[seat], theirs.computers[seat], "seat " .. seat)
    if Match.IsComputer(mine, seat) then
      computers = computers + 1
      equal(Match.COMPUTER, theirs.players[seat])
      equal("easy", theirs.computers[seat])
    end
  end
  equal(2, computers)
  equal("active", theirs.status)
  equal(Match.START, theirs.log[1], "the game began once the people had accepted")
  equal(false, Match.IsLocal(mine), "it is a game of people")
  equal(false, Match.IsComputerMatch(theirs))
  equal(mine.me, Match.Driver(mine), "the host plays the computer's seats")
  equal(mine.me, bob.private.Match.Driver(theirs), "and the guest knows")

  playOn(world, { alice, bob }, id)
  equal("finished", mine.status)
  equal(logOf(alice, id), logOf(bob, id))
  equal(Match.Result(mine).winner, bob.private.Match.Result(theirs).winner)
  local computerMoved = false
  for _, event in ipairs(Match.Events(mine)) do
    computerMoved = computerMoved or (event.kind == "move" and Match.IsComputer(mine, event.seat))
  end
  assert(computerMoved, "the computer played its seats")
  -- Not a game against the computer: nothing is counted with those
  equal(0, alice.session:Versus("race", "easy").lost + alice.session:Versus("race", "easy").won)
end

function tests.ComputerSeatsTravelWithTheRules()
  local private = loadEngine()
  local Codec = private.Codec
  equal("_c=2hard.5easy", Codec.EncodeComputers({ [5] = "easy", [2] = "hard" }))
  equal(nil, Codec.EncodeComputers(nil))
  equal(nil, Codec.EncodeComputers({}))

  local invite = Codec.Decode(Codec.Encode("INV", "abc", "race", 1, 1, "lore=10+_c=3hard", 4, 2))
  equal("lore=10", invite.options, "the rules of the game are what is left")
  equal("hard", invite.computers[3])
  equal(4, invite.seats)
  invite = Codec.Decode(Codec.Encode("INV", "abc", "race", 1, 1, "_c=3hard.4easy", 4, 2))
  equal(nil, invite.options)
  equal("easy", invite.computers[4])
  equal(nil, Codec.Decode("1:INV:abc:race:1:1:lore=10:4:2").computers)
  local garbage = { "1:INV:a:race:1:1:_c=:4:2", "1:INV:a:race:1:1:_c=x:4:2", "1:INV:a:race:1:1:_c=3hard.3easy:4:2", "1:INV:a:race:1:1:_c=0hard:4:2" }
  for _, text in ipairs(garbage) do
    equal(nil, Codec.Decode(text), "Decode(" .. text .. ")")
  end

  -- A client from before the computer sat with people takes it for a rule it doesn't have, and
  -- turns the challenge down as being from another version of the game
  equal(false, select(2, private.Games.DecodeOptions(private.Games.Get("chinesecheckers"), "_c=3hard")))
end

function tests.ChallengeThatSeatsTheComputerWronglyIsRefused()
  local world = World.New()
  world.prepare = function(private)
    registerRace(private)
  end
  local bob = world:AddPlayer("Bob-Realm")
  local function answer(text)
    world.queue = {}
    bob.session:Receive("Alice-Realm", text)
    return world.queue[1] and world.queue[1].text
  end
  equal(nil, answer("1:INV:m1:race:1:1:_c=2easy:3:2"), "in the seat of the one challenged")
  equal(nil, answer("1:INV:m2:race:1:1:_c=1easy:3:2"), "in the seat of the one challenging")
  equal(nil, answer("1:INV:m3:race:1:1:_c=5easy:3:2"), "in a seat there isn't")
  equal("1:DEC:m4:version", answer("1:INV:m4:race:1:1:_c=3genius:3:2"), "at a level there isn't")
  equal("1:DEC:m5:version", answer("1:INV:m5:race:1:1:_c=2easy"), "between two")
  equal(nil, next(bob.matches))

  -- A game the computer doesn't play is from another version, where it does
  world.queue = {}
  bob.session:Receive("Alice-Realm", "1:INV:m6:chinesecheckers:" .. bob.private.Games.Get("chinesecheckers").version .. ":1:_c=3easy:3:2")
  equal(nil, world.queue[1], "Chinese Checkers has a computer")
  equal("easy", bob.matches.m6.computers[3])
  equal(bob.private.Match.COMPUTER, bob.matches.m6.players[3])
end

function tests.ChallengeWithTheComputerIsCalledOffWithoutIt()
  local world = World.New()
  world.prepare = function(private)
    registerRace(private)
  end
  local alice = world:AddPlayer("Alice-Realm")
  world:AddPlayer("Bob-Realm")
  local carol = world:AddPlayer("Carol-Realm")
  -- Withdrawn by the host
  local match = assert(alice.session:Invite({ "Bob-Realm" }, "race", { computer = { count = 2 } }))
  deliverToPeople(world)
  assert(alice.session:Forget(match.id))
  deliverToPeople(world)
  equal(nil, world.players["Bob-Realm"].matches[match.id], "Bob is told")

  -- Declined by somebody, which calls it off for the rest
  match = assert(alice.session:Invite({ "Bob-Realm", "Carol-Realm" }, "race", { computer = {} }))
  deliverToPeople(world)
  assert(world.players["Bob-Realm"].session:Accept(match.id))
  deliverToPeople(world)
  assert(carol.session:Decline(match.id))
  deliverToPeople(world)
  equal("declined", alice.matches[match.id].status)
  equal("declined", world.players["Bob-Realm"].matches[match.id].status)
end

function tests.HostWhoLeavesHandsTheComputerOn()
  local world, alice, bob, id = mixedRace()
  local Match = bob.private.Match
  assert(alice.session:Resign(id))
  deliverToPeople(world)
  local theirs = bob.matches[id]
  equal("active", theirs.status, "Bob and the computer play on")
  equal(theirs.me, Match.Driver(theirs), "Bob's client plays the computer now")
  equal(theirs.me, alice.private.Match.Driver(alice.matches[id]), "as Alice's knows")
  equal(nil, alice.session:ComputerTurn(alice.matches[id]))

  playOn(world, { alice, bob }, id)
  equal("finished", theirs.status)
  equal(logOf(alice, id), logOf(bob, id), "Alice is still told how it went")
end

function tests.TableOfPeopleIsOverOnceThePeopleHaveLeft()
  local world, alice, bob, id = mixedRace()
  -- At the same moment, neither knowing of the other's
  assert(alice.session:Resign(id))
  assert(bob.session:Resign(id))
  deliverToPeople(world)
  equal(logOf(alice, id), logOf(bob, id))
  for _, player in ipairs({ alice, bob }) do
    local match = player.matches[id]
    equal("finished", match.status, player.name)
    local result = player.private.Match.Result(match)
    equal(0, result.winner, "the computer doesn't play on among itself")
    equal("resign", result.reason)
    equal(nil, player.session:ComputerTurn(match))
  end

  -- With one computer left it is the last one in the game, and has won it
  world, alice, bob, id = mixedRace(1)
  assert(alice.session:Resign(id))
  deliverToPeople(world)
  assert(bob.session:Resign(id))
  local match = bob.matches[id]
  local result = bob.private.Match.Result(match)
  equal(true, bob.private.Match.IsComputer(match, result.winner))
end

--- Plays a race at a table of people until it is the computer's move
--- @return table match The host's
local function untilTheComputer(world, alice, bob, id)
  playOn(world, { alice, bob }, id, function()
    return alice.session:ComputerTurn(alice.matches[id]) ~= nil
  end)
  local match = alice.matches[id]
  assert(alice.session:ComputerTurn(match), "the computer is to move")
  return match
end

function tests.ComputerAtATableMovesOffScreenAfterAPause()
  local world, alice, bob, id = mixedRace()
  local match = untilTheComputer(world, alice, bob, id)
  local before = #match.log
  -- Not while the window shows the game: the window sees to that
  alice.session:Drive(10, nil, id)
  equal(before, #match.log)
  -- And not on the spot
  alice.session:Drive(0.1)
  equal(before, #match.log, "it seems to think first")
  alice.session:Drive(5)
  equal(before + 1, #match.log, "and then moves")
  deliverToPeople(world)
  equal(before + 1, #bob.matches[id].log, "which Bob is sent")

  -- A game against the computer alone waits for the player to look at it
  local alone = assert(alice.session:Invite({}, "race", { computer = {}, seat = 2 }))
  alice.session:Drive(10)
  alice.session:Drive(10)
  equal(0, #alone.log)
end

function tests.WaitingOnTheComputerChecksInWithItsHost()
  local world, alice, bob, id = mixedRace()
  untilTheComputer(world, alice, bob, id)
  world.sent = {}
  world.clock = world.clock + 60 * 60 + 1
  bob.session:Flush()
  local checked = false
  for _, message in ipairs(world.queue) do
    assert(message.to ~= "*", "never the computer's seat")
    checked = checked or (message.from == "Bob-Realm" and message.to == "Alice-Realm" and message.text:find(":SYN:", 1, true) ~= nil)
  end
  assert(checked, "Bob asks Alice, whose client plays the computer")
end

function tests.ComputerAtATableIsChallengedAgainWithThePeople()
  local world, alice, bob, id = mixedRace()
  local MainFrame = openWindow(alice)
  MainFrame.Open(id)
  assert(alice.session:Resign(id))
  deliverToPeople(world)
  assert(bob.session:Resign(id))
  deliverToPeople(world)
  Client.Button("rematch"):Fire("OnClick")
  local again
  for _, other in pairs(alice.matches) do
    again = other.id ~= id and other or again
  end
  assert(again, "a new challenge")
  equal(4, #again.players)
  local computers = 0
  for seat, level in pairs(again.computers) do
    computers = computers + 1
    equal("easy", level, "seat " .. seat)
  end
  equal(2, computers)
  equal("outgoing", again.status)
end

function tests.WindowSaysWhoseClientPlaysTheComputer()
  local world, alice, bob, id = mixedRace()
  untilTheComputer(world, alice, bob, id)
  equal("status_computer_thinking", openWindow(alice).Describe(alice.matches[id]))
  equal("status_computer_elsewhere", openWindow(bob).Describe(bob.matches[id]))
end

function tests.WizardSeatsTheComputerWithPeople()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  openWizard(alice)
  function alice.private.presence:List()
    local list = {}
    for index, name in ipairs({ "Bob-Realm", "Carol-Realm" }) do
      list[index] = { name = name, source = "friend" }
    end
    return list
  end
  pickGame("chinesecheckers")
  local function row(name)
    return Client.Find(function(widget)
      return widget.kind == "Button" and widget.player == name and widget.source ~= nil and widget:IsVisible()
    end)[1]
  end
  row("Bob-Realm"):Fire("OnClick")
  equal("Alice-Realm, Bob-Realm", (seating.Shown()))
  seating.Sizes()["4"]:Fire("OnClick")
  equal("Alice-Realm, Bob-Realm, wizard_seat_open [wizard_add_computer], wizard_seat_open [wizard_add_computer]", (seating.Shown()))
  local send = Client.Button("wizard_send")
  equal(false, send.enabled)
  equal(true, says("wizard_seats_open"))

  -- The computer in one, taken out again, and put back
  seating.Click("wizard_add_computer")
  equal(true, says("wizard_seat_open_one"))
  select(2, seating.Shown())[3].remove:Fire("OnClick")
  equal(true, says("wizard_seats_open"))
  seating.Click("wizard_add_computer")

  -- Carol takes the last one
  row("Carol-Realm"):Fire("OnClick")
  equal("Alice-Realm, Bob-Realm, computer [computer_level_medium], Carol-Realm", (seating.Shown()))
  equal(true, says("wizard_summary_with_computer"))
  equal(true, send.enabled)
  send:Fire("OnClick")
  local started = select(2, next(alice.matches))
  equal(4, #started.players)
  local seats = 0
  for _ in pairs(started.computers) do
    seats = seats + 1
  end
  equal(1, seats)
  equal("outgoing", started.status, "a challenge like any other")
  local challenged = {}
  for _, message in ipairs(world.queue) do
    challenged[#challenged + 1] = message.to
    assert(message.text:find("_c=", 1, true), "the computer's seat goes with the challenge")
  end
  table.sort(challenged)
  equal("Bob-Realm,Carol-Realm", table.concat(challenged, ","))
end

function tests.WizardCardsSayHowManyPlayShortly()
  local world = World.New()
  openWizard(world:AddPlayer("Alice-Realm"))
  local function card(id)
    return Client.Find(function(widget)
      return widget.kind == "Button" and widget.game ~= nil and widget.game.id == id and widget:IsVisible()
    end)[1]
  end
  equal("players_range", card("crazyeights").players.text, "2 to 6, every number in between")
  equal("players_choice", card("chinesecheckers").players.text, "2, 3, 4 or 6")
  equal("players_exactly", card("chess").players.text)
  equal(true, card("chess").computer:IsShown())
  equal(false, card("fourtiles").computer:IsShown(), "the computer doesn't play it")
  equal(false, card("solitaire").computer:IsShown())
end

function tests.WizardSetsTheComputerUpAsItWasBeforeEachSeatHadItsOwn()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  registerRace(alice.private)
  openWizard(alice)
  ForeverGames.db.profile.computer = { race = { level = "hard", count = 2, chosen = true } }
  pickGame("race")
  equal("Alice-Realm, computer [computer_level_hard], computer [computer_level_hard]", (seating.Shown()))
  equal("hard", ForeverGames.db.profile.computer.race.level, "what was saved is left as it was")
  Client.Button("wizard_play"):Fire("OnClick")
  local levels = ForeverGames.db.profile.computer.race.levels
  equal("hard,hard", table.concat(levels, ","), "and saved the new way once played")
end

function tests.WizardTableGrowsForEveryonePicked()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  registerRace(alice.private)
  openWizard(alice)
  function alice.private.presence:List()
    local list = {}
    for index, name in ipairs({ "Bob-Realm", "Carol-Realm", "Dave-Realm", "Erin-Realm" }) do
      list[index] = { name = name, source = "friend" }
    end
    return list
  end
  pickGame("race")
  local function pick(name)
    Client.Find(function(widget)
      return widget.kind == "Button" and widget.player == name and widget.source ~= nil and widget:IsVisible()
    end)[1]:Fire("OnClick")
  end
  for _, name in ipairs({ "Bob-Realm", "Carol-Realm", "Dave-Realm" }) do
    pick(name)
  end
  equal("Alice-Realm, Bob-Realm, Carol-Realm, Dave-Realm", (seating.Shown()))
  equal(false, says("wizard_add_computer"), "no seat left for it")

  -- As many as the game is for, and not one more
  pick("Erin-Realm")
  equal(true, says("wizard_table_full"))
  equal("Alice-Realm, Bob-Realm, Carol-Realm, Dave-Realm", (seating.Shown()))
  seating.Sizes()["2"]:Fire("OnClick")
  equal(true, says("wizard_table_too_small"), "nobody picked is left out")
  equal("Alice-Realm, Bob-Realm, Carol-Realm, Dave-Realm", (seating.Shown()))

  -- Somebody taken out, there is room for the computer
  select(2, seating.Shown())[4].remove:Fire("OnClick")
  seating.Sizes()["4"]:Fire("OnClick")
  seating.Click("wizard_add_computer")
  equal("Alice-Realm, Bob-Realm, Carol-Realm, computer [computer_level_medium]", (seating.Shown()))
  -- And it gives the seat up again to whoever is picked
  pick("Erin-Realm")
  equal("Alice-Realm, Bob-Realm, Carol-Realm, Erin-Realm", (seating.Shown()))
  -- A smaller table has the computer leave, and the people stay
  pick("Erin-Realm")
  seating.Click("wizard_add_computer")
  seating.Sizes()["3"]:Fire("OnClick")
  equal("Alice-Realm, Bob-Realm, Carol-Realm", (seating.Shown()))
end

function tests.WindowPlaysTicTacToeAgainstTheComputer()
  local world = World.New()
  local alice = world:AddPlayer("Alice-Realm")
  local session = alice.session
  local match = assert(session:Invite({}, "tictactoe", { computer = { level = "easy" }, seat = 1 }))
  local MainFrame = openWindow(alice)
  MainFrame.Open(match.id)
  equal(true, says("versus"))
  equal(true, says("status_your_turn"))
  equal(false, Client.Button("take_back").enabled, "nothing to take back yet")

  local board = shownBoard()
  clickSquare(board, 1, 1, 3)
  equal("5", logOf(alice, match.id))
  equal(true, says("status_computer_thinking"))
  local detail = Client.Find(function(widget)
    return widget.buttons ~= nil and widget.scripts.OnUpdate ~= nil
  end)[1]

  -- It looks as though it thinks for a moment before it moves
  detail:Fire("OnUpdate", 0.1)
  equal(1, #match.log, "not on the spot")
  for _ = 1, 10 do
    detail:Fire("OnUpdate", 0.1)
  end
  equal(2, #match.log, "the computer answered")
  equal(true, says("status_your_turn"))

  -- Taken back, the computer's answer goes too
  local takeBack = Client.Button("take_back")
  equal(true, takeBack.enabled)
  takeBack:Fire("OnClick")
  equal(0, #match.log)
  equal(0, #world.sent)

  -- Played out, it can be played again, the other way round
  local moves = alice.private.Games.Get("tictactoe").moves
  while match.status == "active" do
    if alice.private.Match.IsMyTurn(match) then
      assert(session:Move(match.id, moves(alice.private.Match.State(match))[1]))
    end
    detail:Fire("OnUpdate", 1)
  end
  Client.Button("play_again"):Fire("OnClick")
  local again
  for _, other in pairs(alice.matches) do
    again = other ~= match and other or again
  end
  equal(2, again.me)
  equal("easy", again.computers[1])
end

function tests.RegistryRefusesAComputerItCantUse()
  local cases = {
    { { visible = function(state)
      return state
    end }, "guesses" },
    { { computer = { levels = { impossible = {} } } }, "no such thing" },
    { { computer = { evaluate = 3 } }, "evaluate isn't a function" },
    { { seats = 1 }, "no seat for the computer" },
    { { moves = false }, "neither moves nor think" },
  }
  for _, case in ipairs(cases) do
    local private = loadEngine()
    local ok, err = pcall(registerRace, private, case[1])
    assert(not ok, "registered all the same: " .. case[2])
    assert(tostring(err):find(case[2], 1, true), "said " .. tostring(err) .. ", not " .. case[2])
  end
end
end

-----------------------------
-- Sector maps
-----------------------------
do
  --- Two rooms side by side, 128 square each, through a line with a special on it: the west one
  --- with its floor at 0, the east one's at a height a test says, with tag 7. Cut by a node along
  --- the line between them
  --- @param private table
  --- @param floor number The east room's floor
  --- @param ceiling number? Its ceiling, 128 if left out
  --- @return SectorMap
  local function twoRooms(private, floor, ceiling)
    private.SectorMap.Register("two_rooms", {
      folder = "Rooms",
      skyFlat = "F_SKY1",
      vertices = { 0, 0, 128, 0, 256, 0, 256, 128, 128, 128, 0, 128 },
      sectors = {
        { floor = 0, ceiling = 128, floorPicture = "FLOOR", ceilingPicture = "FLOOR", light = 160, special = 0, tag = 0 },
        { floor = floor, ceiling = ceiling or 128, floorPicture = "FLOOR", ceilingPicture = "FLOOR", light = 160, special = 0, tag = 7 },
      },
      sides = {
        { x = 0, y = 0, upper = "-", lower = "-", middle = "WALL", sector = 1 },
        { x = 0, y = 0, upper = "-", lower = "-", middle = "WALL", sector = 1 },
        { x = 0, y = 0, upper = "-", lower = "-", middle = "WALL", sector = 2 },
        { x = 0, y = 0, upper = "-", lower = "-", middle = "WALL", sector = 2 },
        { x = 0, y = 0, upper = "-", lower = "-", middle = "WALL", sector = 2 },
        { x = 0, y = 0, upper = "-", lower = "-", middle = "WALL", sector = 1 },
        { x = 0, y = 0, upper = "WALL", lower = "WALL", middle = "-", sector = 2 },
        { x = 0, y = 0, upper = "WALL", lower = "WALL", middle = "-", sector = 1 },
      },
      lines = {
        { from = 1, to = 6, front = 1, flags = 1, special = 0, tag = 0 },
        { from = 6, to = 5, front = 2, flags = 1, special = 0, tag = 0 },
        { from = 5, to = 4, front = 3, flags = 1, special = 0, tag = 0 },
        { from = 4, to = 3, front = 4, flags = 1, special = 0, tag = 0 },
        { from = 3, to = 2, front = 5, flags = 1, special = 0, tag = 0 },
        { from = 2, to = 1, front = 6, flags = 1, special = 0, tag = 0 },
        { from = 2, to = 5, front = 7, back = 8, flags = 4, special = 88, tag = 7 },
      },
      segs = {
        { from = 1, to = 6, line = 1, back = false, offset = 0 },
        { from = 6, to = 5, line = 2, back = false, offset = 0 },
        { from = 2, to = 1, line = 6, back = false, offset = 0 },
        { from = 5, to = 2, line = 7, back = true, offset = 0 },
        { from = 5, to = 4, line = 3, back = false, offset = 0 },
        { from = 4, to = 3, line = 4, back = false, offset = 0 },
        { from = 3, to = 2, line = 5, back = false, offset = 0 },
        { from = 2, to = 5, line = 7, back = false, offset = 0 },
      },
      subsectors = { { first = 1, count = 4 }, { first = 5, count = 4 } },
      nodes = { { x = 128, y = 0, dx = 0, dy = 128, frontBox = { 128, 0, 128, 256 }, backBox = { 128, 0, 0, 128 }, front = -2, back = -1 } },
      things = { { x = 64, y = 64, angle = 0, type = 1, flags = 7 } },
      walls = { WALL = { width = 64, height = 64 } },
      flats = { FLOOR = { width = 64, height = 64 } },
      animations = { { "FLOOR", "FLOOR2" } },
      animationTics = 8,
      spriteFrames = { LAMPA = { { "LAMPA0", false } } },
      sprites = { LAMPA0 = { width = 16, height = 48, left = 8, top = 48, fileWidth = 16, fileHeight = 64 } },
    })
    return private.SectorMap.Load("two_rooms")
  end

  local function mapEngine()
    local private = {}
    assert(loadfile("Engine/SectorMap.lua"))(ADDON_NAME, private)
    return private
  end

  local function player(x, y)
    return { x = x, y = y, z = 0, radius = 16, height = 56 }
  end

  function tests.SectorMapFindsTheSectorEveryPointIsIn()
    local map = twoRooms(mapEngine(), 0)
    equal(1, map:SectorAt(10, 60).index, "west")
    equal(2, map:SectorAt(200, 60).index, "east")
    -- And for a real map: just in front of every seg is the sector it is seen from
    local private = mapEngine()
    assert(loadfile("ForeverGames_Freedoom/Maps/E1M1.lua"))(ADDON_NAME, private)
    local e1m1 = private.SectorMap.Load("freedoom_e1m1")
    for index, seg in ipairs(e1m1.segs) do
      local length = math.sqrt((seg.x2 - seg.x1) ^ 2 + (seg.y2 - seg.y1) ^ 2)
      local x = (seg.x1 + seg.x2) / 2 + (seg.y2 - seg.y1) / length * 0.5
      local y = (seg.y1 + seg.y2) / 2 - (seg.x2 - seg.x1) / length * 0.5
      assert(e1m1:SectorAt(x, y) == seg.front, "seg " .. index .. " looks into another sector")
    end
    -- And for Run, whose nodes Tools/mapkit.py built
    assert(loadfile("ForeverGames_Freedoom/Maps/Run.lua"))(ADDON_NAME, private)
    local run = private.SectorMap.Load("freedoom_run")
    for index, seg in ipairs(run.segs) do
      local length = math.sqrt((seg.x2 - seg.x1) ^ 2 + (seg.y2 - seg.y1) ^ 2)
      local x = (seg.x1 + seg.x2) / 2 + (seg.y2 - seg.y1) / length * 0.5
      local y = (seg.y1 + seg.y2) / 2 - (seg.x2 - seg.x1) / length * 0.5
      assert(run:SectorAt(x, y) == seg.front, "Run's seg " .. index .. " looks into another sector")
    end
  end

  function tests.SectorMapStepsUpAStepButNotAWall()
    local private = mapEngine()
    local map = twoRooms(private, 24)
    local walker = player(64, 64)
    map:Slide(walker, 128, 0)
    map:Settle(walker)
    equal(192, walker.x, "up a step of 24")
    equal(24, walker.z, "and stands on it")

    map = twoRooms(private, 25)
    walker = player(64, 64)
    map:Slide(walker, 128, 0)
    assert(walker.x <= 128 - 16 + 0.001, "not up a step of 25, got to " .. walker.x)

    map = twoRooms(private, 0, 50)
    walker = player(64, 64)
    map:Slide(walker, 128, 0)
    assert(walker.x <= 128 - 16 + 0.001, "not under a ceiling lower than it is tall, got to " .. walker.x)
  end

  function tests.SectorMapSlidesAlongAWall()
    local map = twoRooms(mapEngine(), 0)
    local walker = player(64, 64)
    map:Slide(walker, -100, 20)
    assert(walker.x >= 16 and walker.x < 24, "stopped at the wall, at " .. walker.x)
    assert(math.abs(walker.y - 84) < 1e-9, "and went along it, to " .. walker.y)
    local blocked = map:Check(10, 64, 16)
    assert(blocked, "nowhere in a wall to stand")
  end

  function tests.SectorMapSaysWhatLineWasWalkedOver()
    local map = twoRooms(mapEngine(), 0)
    local walker, crossed = player(64, 64), {}
    map:Slide(walker, 30, 0, crossed)
    equal(0, #crossed, "not over it yet")
    map:Slide(walker, 60, 0, crossed)
    equal(1, #crossed, "over it once")
    equal(7, crossed[1].index, "the line between the rooms")
    local line, front = map:Trace(100, 64, 0, 64)
    equal(7, line and line.index, "it is what is in reach")
    equal(false, front, "from behind it")
    line, front = map:Trace(160, 64, math.pi, 64)
    equal(true, front, "and from in front")
    equal(nil, (map:Trace(64, 64, 0, 20)), "out of reach")
    -- A walker that is one of the map's things, as the player is, all the same
    map = twoRooms(mapEngine(), 0)
    walker, crossed = player(64, 64), {}
    map:AddThing(walker)
    map:Slide(walker, 90, 0, crossed)
    equal(1, #crossed, "a thing walks over it too")
  end

  function tests.SectorMapMovesFloorsAndKeepsTime()
    local map = twoRooms(mapEngine(), 48)
    local east = map:Tagged(7)[1]
    equal(2, east.index, "found by its tag")
    equal(0, map:Neighbouring(east, "floor"), "the floor next to it")
    local arrived, timed = 0, 0
    map:Move(east, "floor", 0, { speed = 24, onArrive = function()
      arrived = arrived + 1
    end })
    map:After(1.5, function()
      timed = timed + 1
    end)
    map:Tick(1)
    equal(24, east.floor, "half way down")
    equal(0, map:Moving(east, "floor"), "and on its way")
    map:Tick(1)
    equal(0, east.floor, "all the way")
    equal(1, arrived, "and said so once")
    equal(1, timed, "the time came")
    equal(nil, map:Moving(east, "floor"), "and stopped")

    local blocked = false
    map:Move(east, "ceiling", 0, { speed = 64, canMove = function(_, height)
      return height >= 56
    end, onBlocked = function()
      blocked = true
    end })
    map:Tick(0.5)
    equal(96, east.ceiling, "on its way")
    map:Tick(0.5)
    equal(64, east.ceiling, "still room under it")
    assert(not blocked, "nothing in the way yet")
    map:Tick(0.5)
    equal(64, east.ceiling, "but not into whoever is there")
    assert(blocked, "and said so")

    map = twoRooms(mapEngine(), 0)
    equal("FLOOR", map:Frame("FLOOR"), "an animation's first frame")
    map:Tick(8 / 35)
    equal("FLOOR2", map:Frame("FLOOR"), "and the next")
    equal("WALL", map:Frame("WALL"), "what isn't animated stays")
  end

  function tests.SectorMapKeepsThingsInTheirPlace()
    local map = twoRooms(mapEngine(), 0)
    local lamp = { x = 100, y = 64, angle = 0, radius = 16, height = 48, solid = true }
    map:AddThing(lamp)
    equal(1, lamp.sector.index, "in the west room")
    local walker = player(40, 64)
    map:Slide(walker, 100, 0)
    assert(walker.x <= 100 - 32 + 0.001, "a solid thing is in the way, got to " .. walker.x)
    local touching = map:Touching(70, 64, 16, {})
    equal(1, #touching, "and is touched by whoever stands next to it")
    map:MoveThing(lamp, 200, 64)
    equal(2, lamp.sector.index, "moved to the east room")
    equal(0, #map:Touching(70, 64, 16, {}), "and isn't where it was")
    map:RemoveThing(lamp)
    equal(0, #map:Touching(200, 64, 16, {}), "gone")
    walker = player(40, 64)
    map:Slide(walker, 160, 0)
    equal(200, walker.x, "nothing in the way any more")

    local hanging = { x = 64, y = 30, angle = 0, radius = 16, height = 40, hanging = true }
    map:AddThing(hanging)
    equal(128 - 40, map:Bottom(hanging), "hangs from the ceiling")
    hanging.hanging = false
    equal(0, map:Bottom(hanging), "or stands on the floor")
  end

  --- What a view draws over the walls and floors, from where and facing which way, pieces counted
  local function drawnOver(private, map, x, angle)
    private.Strips = { New = function()
      return { frame = {}, Layout = function() end }
    end }
    assert(loadfile("GUI/SectorView.lua"))(ADDON_NAME, private)
    local view = private.SectorView.New({}, {})
    view:SetMap(map)
    local level, over = nil, 0
    local function piece()
      if level then
        over = over + 1
      end
    end
    view:Draw({ x = x, y = 64, z = 41, angle = angle }, {
      Begin = function() end,
      SetLevel = function(_, to) level = to end,
      Quad = piece,
      Mapped = piece,
      Finish = function() return 0 end,
    })
    return over
  end

  function tests.SectorViewHidesThingsBehindWalls()
    local private = mapEngine()
    local map = twoRooms(private, 0)
    map:AddThing({ x = 200, y = 64, angle = 0, radius = 16, height = 48, picture = "LAMPA" })
    assert(drawnOver(private, map, 40, 0) > 0, "seen across the rooms")
    equal(0, drawnOver(private, map, 40, math.pi), "not when looking away")
    map.sectors[2].floor = 128
    equal(0, drawnOver(private, map, 40, 0), "nor through a wall")
  end

  function tests.FreedoomPicksThingsUpByDoomsRules()
    local Freedoom = loadEngine().Freedoom
    local carried = Freedoom.NewInventory()
    equal(nil, (Freedoom.PickUp(carried, 2011)), "no stimpack for whoever is well")
    carried.health = 20
    equal("freedoom_got_medineed", (Freedoom.PickUp(carried, 2012)), "a medikit for whoever needs it")
    equal(45, carried.health, "25 more")
    equal("freedoom_got_stim", (Freedoom.PickUp(carried, 2011)))
    equal(55, carried.health)
    carried.health = 199
    Freedoom.PickUp(carried, 2014)
    Freedoom.PickUp(carried, 2014)
    equal(200, carried.health, "bonuses go up to 200 and no further")
    equal("freedoom_got_armor", (Freedoom.PickUp(carried, 2018)))
    equal(100, carried.armor)
    equal(nil, (Freedoom.PickUp(carried, 2018)), "no second vest")
    carried.ammo.bullets = 200
    equal(nil, (Freedoom.PickUp(carried, 2007)), "no bullets when full")
    Freedoom.PickUp(carried, 8)
    equal(400, carried.max.bullets, "a backpack carries twice as much")
    equal(210, carried.ammo.bullets, "and comes with some")
    local message, grin = Freedoom.PickUp(carried, 2001)
    equal("freedoom_got_shotgun", message)
    assert(grin, "a new weapon is worth a grin")
    equal(4 + 8, carried.ammo.shells, "and two clips of shells")
    assert(not Freedoom.Unlocks(carried, 26), "no blue key yet")
    assert(Freedoom.Unlocks(carried, 1), "a door without a lock opens")
    Freedoom.PickUp(carried, 40)
    assert(Freedoom.Unlocks(carried, 26), "the skull opens it as well as the card")
    assert(not Freedoom.Unlocks(carried, 28), "but not the red door")
  end

  function tests.ActorsGoThroughTheirStates()
    local private = mapEngine()
    assert(loadfile("Engine/Actors.lua"))(ADDON_NAME, private)
    local Actors = private.Actors
    local did = {}
    local actor = {
      sprite = "TROO",
      sequences = {
        stand = { { "A", 2, "look" }, { "B", 0 }, { "C", 1 }, next = "stand" },
        die = { { "D", 1, "scream" }, { "E", -1 } },
        burst = { sprite = "BEXP", { "A", 1 } },
      },
      act = function(self, action)
        did[#did + 1] = action
        if action == "scream" and self.turn then
          Actors.Start(self, "burst")
        end
      end,
    }
    Actors.Start(actor, "stand")
    equal("TROOA", actor.picture, "the first frame")
    equal("look", did[1], "and what it does")
    Actors.Tick(actor)
    equal("TROOA", actor.picture, "for two tics")
    Actors.Tick(actor)
    equal("TROOC", actor.picture, "a step of no time is gone straight past")
    Actors.Tick(actor)
    equal("TROOA", actor.picture, "round again")
    Actors.Start(actor, "die")
    Actors.Tick(actor)
    equal("TROOE", actor.picture, "down")
    for _ = 1, 10 do
      Actors.Tick(actor)
    end
    equal("TROOE", actor.picture, "and staying down")
    actor.turn = true
    Actors.Start(actor, "die")
    equal("BEXPA", actor.picture, "what an action does goes first, in another sprite")
    Actors.Tick(actor)
    assert(actor.removed, "and the end of it is the end of the thing")
    equal(nil, actor.picture)
  end

  function tests.SectorMapSeesShootsAndHears()
    local private = mapEngine()
    local map = twoRooms(private, 0)
    local imp = { x = 200, y = 64, angle = 0, radius = 20, height = 56, solid = true, shootable = true }
    map:AddThing(imp)
    assert(map:Sees(40, 64, 41, 200, 64, 0, 56), "across the rooms")
    local shot = map:Shoot(40, 64, 36, 0, 2048, nil, function(thing)
      return thing.shootable
    end, {})
    assert(shot.thing == imp, "a shot hits it")
    shot = map:Shoot(40, 64, 36, math.pi, 2048, nil, function()
      return true
    end, {})
    equal(nil, shot.thing, "not when fired the other way")
    assert(shot.x < 5 and shot.x > -1, "it stops at the wall, at " .. shot.x)

    -- The east room raised higher than the eye: the floor at the back of it can't be seen from
    -- below, but somebody standing on it can
    map = twoRooms(private, 60)
    assert(not map:Sees(40, 64, 41, 240, 64, 60, 62), "not the floor of it, from below")
    assert(map:Sees(40, 64, 41, 240, 64, 60, 116), "but a monster standing on it")

    -- Shot on a ledge higher than the gun, as Doom aimed
    map = twoRooms(private, 60)
    imp.x = 200
    map:AddThing(imp)
    shot = map:Shoot(40, 64, 36, 0, 2048, nil, function(thing)
      return thing.shootable
    end, {})
    assert(shot.thing == imp, "a monster on a ledge above is aimed at and hit")
    map:RemoveThing(imp)
    shot = map:Shoot(40, 64, 36, 0, 2048, nil, function()
      return true
    end, {})
    equal(nil, shot.thing, "with nothing there")
    assert(shot.x > 120 and shot.x < 128, "a level shot stops at the ledge's edge, at " .. shot.x)

    -- Heard across an open line, not a shut one
    map = twoRooms(private, 0)
    map:Noise(map.sectors[1], imp)
    assert(map.sectors[2].soundTarget == imp, "heard next door")
    map = twoRooms(private, 128)
    map:Noise(map.sectors[1], imp)
    equal(nil, map.sectors[2].soundTarget, "not through a shut door")
  end

  function tests.SectorMapWalksThingsDoomsWay()
    local private = mapEngine()
    local map = twoRooms(private, -40)
    local monster = { x = 100, y = 64, angle = 0, radius = 20, height = 56, solid = true }
    map:AddThing(monster)
    local moved = map:TryMoveThing(monster, 140, 64)
    assert(not moved, "not off a ledge it can't step back up")
    assert(map:TryMoveThing(monster, 140, 64, true), "unless it may")
    equal(2, monster.sector.index, "and is in the other room")
    map = twoRooms(private, 30)
    map:AddThing(monster)
    monster.x, monster.y = 100, 64
    map:MoveThing(monster, 100, 64)
    assert(not map:TryMoveThing(monster, 140, 64), "nor up a step too high")
  end

  function tests.FreedoomArmourTakesSomeOfABlow()
    local Freedoom = loadEngine().Freedoom
    local player = { shootable = true }
    local run = { player = player, inventory = Freedoom.NewInventory(), tic = 0 }
    Freedoom.Damage(run, player, 30)
    equal(70, run.inventory.health, "all of it without")
    run.inventory.armor, run.inventory.armorClass = 100, 1
    Freedoom.Damage(run, player, 30)
    equal(50, run.inventory.health, "a third of it with the green vest")
    equal(90, run.inventory.armor, "which wears down")
    run.inventory.armor, run.inventory.armorClass = 200, 2
    Freedoom.Damage(run, player, 30)
    equal(35, run.inventory.health, "half with the blue")
    Freedoom.Damage(run, player, 200)
    equal(0, run.inventory.health)
    assert(run.dead, "and dead")
    assert(not player.shootable, "past hurting")
  end

  --- Freedoom's view on the fake client, showing a game just begun on a map
  --- @param level string? "e1m1" if left out
  --- @param skill string? Doom's middle one if left out
  local function freedoomView(level, skill)
    Client.Install()
    local private = loadEngine()
    for _, file in ipairs({ "GUI/Widgets.lua", "GUI/Strips.lua", "GUI/SectorView.lua", "ForeverGames_Freedoom/Hud.lua" }) do
      assert(loadfile(file))(ADDON_NAME, private)
    end
    -- As the maps' own addon puts them, when it is loaded (Run only when it is played, to be quicker)
    if level == "run" then
      assert(loadfile("ForeverGames_Freedoom/Maps/Run.lua"))()
    end
    for map = 1, 9 do
      assert(loadfile("ForeverGames_Freedoom/Maps/E1M" .. map .. ".lua"))()
    end
    local game = private.Games.Get("freedoom")
    local stage = CreateFrame("Frame", nil, UIParent)
    local view = game.createView(stage)
    view:Layout(800, 600)
    local state = game.newState(1, nil, { map = level or "e1m1", skill = skill })
    view:Update({ match = { id = level or "m1" }, state = state, seat = 1, canMove = true, submit = function() end, changed = true })
    return view, private
  end

  function tests.FreedoomShowsAMapFinishedBeforeAsItsFinishScreen()
    local view, private = freedoomView("e1m2")
    local game = private.Games.Get("freedoom")
    local state = game.newState(1, nil, { map = "e1m2" })
    game.apply(state, 1, "x")
    view:Update({ match = { id = "sent" }, state = state, seat = 1, canMove = false, submit = function() end, changed = true, clock = function()
      return 48.9
    end })
    local finished = assert(view.run.finished, "the finish screen, not the map's start")
    equal(48.9, finished.seconds, "with the time it took")
    equal(true, finished.recalled, "and nothing counted that wasn't played here")
  end

  function tests.FreedoomPlaysEveryMapOfTheEpisode()
    -- Doom's scrolling walls are only for the look of them
    local cosmetic = { [48] = true }
    for map = 0, 9 do
      local level = map == 0 and "run" or "e1m" .. map
      local view, private = freedoomView(level)
      local run = view.run
      equal(level, run.level, "the map picked")
      for _, line in ipairs(run.map.lines) do
        assert(line.special == 0 or private.Freedoom.Specials[line.special] or cosmetic[line.special],
          level .. " has a line that does what nothing here does: " .. line.special)
      end
      local monsters = 0
      for _, actor in ipairs(run.actors) do
        monsters = monsters + ((actor.info and not actor.info.barrel) and 1 or 0)
      end
      assert(monsters > 0, level .. " has somebody in it")
      for _ = 1, 35 do
        view:tick(1 / 35)
      end
    end
  end

  function tests.FreedoomKeepsABestTimeForEveryMap()
    local game = loadEngine().Games.Get("freedoom")
    local state = game.newState(1, nil, { map = "e1m5" })
    equal("freedoom_e1m5", state.map)
    equal(nil, game.record(state, 100), "nothing kept for a map not got out of")
    state.out = true
    local records = game.record(state, 100)
    equal("e1m5", records[1].key, "kept under the map")
    assert(records[1].lower, "the less time the better")
    equal("run", game.newState(1, nil, {}).level, "Run unless another is picked")
  end

  function tests.FreedoomSkillsPutInFewerOrMoreAndKeepTheirOwnBests()
    local game = loadEngine().Games.Get("freedoom")
    local state = game.newState(1, nil, { map = "run", skill = "hard" })
    equal("hard", state.skill)
    equal("medium", game.newState(1, nil, { map = "run" }).skill, "Doom's middle skill unless another is picked")
    equal("medium", game.newState(1, nil, { map = "run", skill = "nightmare" }).skill, "and one there isn't")
    state.out = true
    equal("run_hard", game.record(state, 60)[1].key, "a best time for each skill")
    state.skill = "medium"
    equal("run", game.record(state, 60)[1].key, "the middle one's under the map alone, as before there were skills")

    local monsters = {}
    for _, skill in ipairs({ "baby", "easy", "medium", "hard" }) do
      local view, private = freedoomView("run", skill)
      local run = view.run
      local Freedoom = private.Freedoom
      local count = 0
      for _, actor in ipairs(run.actors) do
        count = count + ((actor.info and not actor.info.barrel) and 1 or 0)
      end
      monsters[skill] = count
      if skill == "baby" then
        -- Half of every blow, twice the ammunition
        local health = run.inventory.health
        Freedoom.damage(run, run.player, nil, nil, 20)
        equal(health - 10, run.inventory.health, "half of a blow on the easiest skill")
        local bullets = run.inventory.ammo.bullets
        Freedoom.PickUp(run.inventory, 2007)
        equal(bullets + 20, run.inventory.ammo.bullets, "a clip counts twice")
        equal("run_baby", run.key)
      elseif skill == "medium" then
        local health = run.inventory.health
        Freedoom.damage(run, run.player, nil, nil, 20)
        equal(health - 20, run.inventory.health, "all of it otherwise")
      end
    end
    equal(monsters.baby, monsters.easy, "the two easiest have the same monsters")
    assert(monsters.easy < monsters.medium and monsters.medium < monsters.hard,
      ("more monsters the harder: %d, %d, %d"):format(monsters.easy, monsters.medium, monsters.hard))
  end

  function tests.FreedoomRunIsTheFirstMapAndCanBeWalkedToTheExit()
    local view, private = freedoomView("run")
    local run = view.run
    local map, player = run.map, run.player
    equal("run", private.Games.Get("freedoom").options[1].default, "picked unless another is")
    -- Nobody in the way and nothing that hurts: only the map, to be walked through
    for _, actor in ipairs(run.actors) do
      map:RemoveThing(actor)
    end
    run.actors = {}
    player.shootable = false
    local submitted
    view.view.submit = function(move)
      submitted = move
    end
    view.draw = function() end
    -- The one way through, as somebody running it goes: through the doors, onto the lift and off it
    -- again at the top, and over the line that ends the map
    local route = {
      { 360, 192 }, { 440, 192 }, { 1216, 192 }, { 1216, 740 }, { 1280, 900 }, { 1500, 1024 }, { 1900, 1024 }, { 1980, 1024 },
      { 2112, 1024 }, { 2336, 992 }, { 2576, 1088 }, { 2768, 1264 }, { 2864, 1504 }, { 2864, 1776 }, { 2768, 2048 },
      { 2672, 2288 }, { 2656, 2500 }, { 2656, 2912 }, { 2912, 2912 }, { 2912, 3240 }, { 2912, 3330 }, { 2912, 3456 },
      { 2480, 3456 }, { 2368, 3456 }, { 1856, 3456 }, { 1856, 3712 }, { 2240, 3712 }, { 2240, 3968 }, { 1856, 3968 },
      { 1856, 4210 }, { 1856, 4870 }, { 1856, 4950 }, { 1856, 5900 }, { 1856, 5990 },
    }
    local shift = IsShiftKeyDown
    IsShiftKeyDown = function()
      return true
    end
    local tics, most = 0, 35 * 120
    for _, point in ipairs(route) do
      local x, y = point[1], point[2]
      local still = 0
      while not submitted and (player.x - x) ^ 2 + (player.y - y) ^ 2 > 20 ^ 2 do
        run.angle = math.atan2(y - player.y, x - player.x)
        view.down.W = true
        local fromX, fromY = player.x, player.y
        view:tick(1 / 35)
        tics = tics + 1
        assert(tics < most, ("stuck at %.0f, %.0f on the way to %d, %d"):format(player.x, player.y, x, y))
        -- In the way: a door to be opened, or a lift to wait for
        still = (player.x - fromX) ^ 2 + (player.y - fromY) ^ 2 < 1 and still + 1 or 0
        if still % 35 == 34 then
          view:use()
        end
      end
    end
    IsShiftKeyDown = shift
    equal("x", submitted, "out at the end")
    assert(tics < 35 * 60, "in under a minute of running, monsters aside: " .. tics / 35)
  end

  function tests.FreedoomGhostSamplesAreFiveLetters()
    local Freedoom = loadEngine().Freedoom
    for _, case in ipairs({ { -416, 256, 0, false }, { 3104.7, -2160.2, 2.5, true }, { 0, 0, 6.2, false } }) do
      local sample = Freedoom.GhostSample(case[1], case[2], case[3], case[4])
      equal(5, #sample, "five letters")
      assert(sample:match("^[%w%-_]+$"), "of those a race takes: " .. sample)
      local place = Freedoom.GhostPlace(sample)
      assert(math.abs(place.x - case[1]) <= 4 and math.abs(place.y - case[2]) <= 4, "where, to within half of 8 units")
      local off = (place.angle - case[3] + math.pi) % (2 * math.pi) - math.pi
      assert(math.abs(off) <= math.pi / 32 + 1e-9, "which way, to within half of a 32nd of a turn")
      equal(case[4], place.firing, "and whether firing")
    end
    equal(nil, Freedoom.GhostPlace("abc"), "too short")
    equal(nil, Freedoom.GhostPlace("ab+cd"), "a letter it doesn't take")
  end

  function tests.FreedoomRacesAGhostWithItsNameOverItsHead()
    local view, private = freedoomView()
    local run = view.run
    local player = run.player
    local Freedoom = private.Freedoom
    -- Bob's run: standing 160 ahead of where the player starts, then walking towards them
    local trail = {}
    for index = 0, 9 do
      trail[#trail + 1] = Freedoom.GhostSample(player.x + 160 - index * 8, player.y, math.pi, index == 9)
    end
    local seconds, kept = 0, {}
    local game = private.Games.Get("freedoom")
    view:Update({
      match = { id = "m1" }, state = game.newState(1, nil, {}), seat = 1, canMove = true, submit = function() end, changed = true,
      clock = function()
        return seconds
      end,
      race = {
        rival = "Bob-Realm", theirs = 42, ghost = trail,
        sample = function(text)
          kept[#kept + 1] = text
          return true
        end,
      },
    })
    local ghost = run.ghost
    assert(ghost, "Bob's ghost is in the map")
    equal("Bob", view.plate.name.text, "with his first name")
    for _ = 1, 35 do
      seconds = seconds + 1 / 35
      view:tick(1 / 35)
    end
    assert(#kept > 0, "the player's own run is kept as they go")
    assert(Freedoom.GhostPlace(kept[#kept]), "in samples that read back")
    assert(ghost.x < player.x + 160 and ghost.x > player.x + 80, "walking towards the player as Bob did, at " .. ghost.x)
    assert(ghost.picture:match("^PLAY[A-D]$"), "with a step of the marine's walk: " .. ghost.picture)
    assert(view.plate:IsShown(), "his name over his head")
    assert(ghost.alpha < 1, "seen through")

    -- Behind the player he isn't seen, and nor is his name
    run.angle = math.pi
    view:tick(1 / 35)
    assert(not view.plate:IsShown(), "not seen, no name")

    -- Once his run is over he fades away
    seconds = seconds + 10
    for _ = 1, 3 do
      view:tick(1 / 35)
    end
    equal(nil, run.ghost, "gone")
  end

  --- What the pictures of a Strips are right now, the ones shown
  local function picturesShown(strips)
    local shown = {}
    for index = 1, strips.used do
      local file = strips.pieces[index].file
      if file then
        shown[file:match("([^\\]+)$")] = true
      end
    end
    return shown
  end

  function tests.FreedoomFinishesAMapWithDoomsScreen()
    local view, private = freedoomView()
    local run = view.run
    local clock, seconds, submitted, setBest = 100, 83.456, nil, false
    GetTime = function()
      return clock
    end
    local game = private.Games.Get("freedoom")
    local state = game.newState(1, nil, { map = "e1m1" })
    local function show()
      view:Update({ match = { id = "m1" }, state = state, seat = 1, canMove = true, changed = true,
        submit = function(move)
          submitted = move
        end,
        clock = function()
          return seconds
        end,
        best = function()
          return 90, setBest
        end,
      })
    end
    show()
    assert(run.totalKills > 0 and run.totalItems > 0 and run.totalSecrets > 0, "there is something to kill, pick up and find")

    -- What is killed, picked up and found is counted
    local monster
    for _, actor in ipairs(run.actors) do
      if actor.info and not actor.info.barrel and not monster then
        monster = actor
      end
    end
    private.Freedoom.Damage(run, monster, 10000)
    equal(1, run.kills, "a kill")
    local secret
    for _, subsector in ipairs(run.map.subsectors) do
      if subsector.sector.special == 9 and not secret then
        secret = subsector
      end
    end
    local seg = run.map.segs[secret.first]
    local x, y = (seg.x1 + seg.x2) / 2, (seg.y1 + seg.y2) / 2
    -- Just inside the subsector, off the middle of its first seg
    local length = math.sqrt((seg.x2 - seg.x1) ^ 2 + (seg.y2 - seg.y1) ^ 2)
    x, y = x + (seg.y2 - seg.y1) / length * 2, y - (seg.x2 - seg.x1) / length * 2
    run.map:MoveThing(run.player, x, y)
    run.player.z = run.player.sector.floor
    view:worldTic()
    equal(1, run.secrets, "a secret found")
    view:worldTic()
    equal(1, run.secrets, "and only the once")

    -- At the exit the clock stops there and then
    run.leaving = 0
    view:tick(1 / 35)
    equal("x", submitted, "out at once")
    equal(83.456, run.finished.seconds, "the time it took to get there")
    seconds = seconds + 5
    state.out = true
    show()
    local shown = picturesShown(view.hud)
    assert(shown.WIMAP0 and shown.WILV00 and shown.WIF, "the episode's map, the map's name and that it is finished")
    assert(shown.WIOSTK and shown.WIOSTI and shown.WISCRT2 and shown.WITIME and shown.WIPAR, "what is counted")
    -- The tests' locale hands back its keys, so what is written is "FREEDOOM_FINISH_TIME" and the like
    assert(not shown.STCFN070, "nothing written under it while it counts up")
    clock = clock + 30
    view:draw()
    shown = picturesShown(view.hud)
    assert(shown.WINUM1 and shown.WINUM2 and shown.WINUM3 and shown.WICOLON, "the time counted up to 01:23")
    assert(shown.STCFN070, "and the lines under it written")
    assert(not shown.STCFN087, "the best to beat, not a new one (only FREEDOOM_FINISH_BEST_NEW has a W)")
    setBest = true
    show()
    assert(picturesShown(view.hud).STCFN087, "and a new best when it was one")
    GetTime = nil
  end

  function tests.FreedoomRunFinishesWithItsNameWritten()
    local view, private = freedoomView("run")
    local run = view.run
    local game = private.Games.Get("freedoom")
    local state = game.newState(1, nil, { map = "run" })
    run.finished = { seconds = 75, at = 0 }
    state.out = true
    view:Update({ match = { id = "run" }, state = state, seat = 1, canMove = true, changed = true, submit = function() end })
    local shown = picturesShown(view.hud)
    assert(shown.WIF and shown.WIMAP0, "finished, over the episode's map")
    assert(not shown.WILV00, "not E1M1's name")
    -- The tests' locale hands back its keys: FREEDOOM_MAP_RUN_TITLE, an R among it
    assert(shown.STCFN082, "its own name written")
  end

  function tests.FreedoomRacesTheBestRunThenTheRivals()
    local view, private = freedoomView()
    local run = view.run
    local player = run.player
    local Freedoom = private.Freedoom
    local function trail(ahead)
      local samples = {}
      for _ = 1, 6 do
        samples[#samples + 1] = Freedoom.GhostSample(player.x + ahead, player.y, math.pi, false)
      end
      return samples
    end
    local game = private.Games.Get("freedoom")
    local state, kept = game.newState(1, nil, {}), {}
    local update = {
      match = { id = "m1" }, state = state, seat = 1, canMove = true, changed = true, submit = function() end,
      clock = function()
        return 1
      end,
      best = function(key)
        equal("e1m1", key, "the best on the map")
        return 61.5, false
      end,
      ghost = function(key)
        equal("e1m1", key)
        return trail(100)
      end,
      sample = function(text)
        kept[#kept + 1] = text
        return true
      end,
    }
    view:Update(update)
    assert(run.ghost, "the player's own best run to race")
    equal("freedoom_ghost_best", view.plate.name.text, "called their best")
    view:tick(1 / 35)
    assert(#kept > 0, "the run is kept as it goes, raced or not")

    -- The rival's run arrives: that is the one raced now
    update.race = { rival = "Bob-Realm", theirs = 50, ghost = trail(200) }
    view:Update(update)
    equal("Bob", view.plate.name.text, "Bob's")
    view:tick(1 / 35)
    assert(run.ghost.x > player.x + 150, "where Bob was")
  end

  function tests.FreedoomIsHeardAsDoomIsFromWhereThingsAre()
    local view, private = freedoomView()
    local run = view.run
    local heard = {}
    PlaySoundFile = function(path)
      heard[#heard + 1] = path:match("([^\\]+)%.ogg$")
      return true, #heard
    end
    local function last()
      return heard[#heard]
    end

    -- The player's own, as loud as can be
    view:sound("pistol")
    equal("pistol1", last(), "the player's own close by")
    run.inventory.health = 50
    local stim
    for _, sector in ipairs(run.map.sectors) do
      for thing in pairs(sector.things) do
        if thing.type == 2011 then
          stim = thing
        end
      end
    end
    run.map:MoveThing(run.player, stim.x, stim.y)
    run.map:Settle(run.player)
    view:pickUp()
    equal("itemup1", last(), "a pickup")

    -- A monster: loud close by, quieter further, not at all far off
    local player = run.player
    view:sound("posit1", { x = player.x + 100, y = player.y })
    equal("posit11", last(), "close by")
    view:sound("posit1", { x = player.x + 1000, y = player.y })
    equal("posit13", last(), "far off")
    local count = #heard
    view:sound("posit1", { x = player.x + 5000, y = player.y })
    equal(count, #heard, "too far to hear")

    -- What the world says goes the same way: a door opening
    local door, nearest
    for _, line in ipairs(run.map.lines) do
      local away = math.abs((line.x1 + line.x2) / 2 - player.x) + math.abs((line.y1 + line.y2) / 2 - player.y)
      if line.special == 1 and line.back and (not nearest or away < nearest) then
        door, nearest = line, away
      end
    end
    -- Stood in front of it
    run.map:MoveThing(player, (door.x1 + door.x2) / 2 + door.dy / door.length * 40, (door.y1 + door.y2) / 2 - door.dx / door.length * 40)
    private.Freedoom.Trigger(run, door, "use")
    assert(last():match("^doropn[12]$"), "a door, heard from where it is: " .. tostring(last()))

    -- Using a wall with nothing to it is a grunt
    run.angle = 0
    for _ = 1, 20 do
      run.map:Slide(player, 32, 0)
    end
    view:use()
    equal("noway1", last(), "nothing to use there")

    -- And nothing at all with the sound off
    ForeverGames = { db = { profile = { sound = false } } }
    count = #heard
    view:sound("pistol")
    equal(count, #heard, "the addon's sound is off")
    ForeverGames, PlaySoundFile = nil, nil
  end

  function tests.FreedoomTeleportsFromTheFrontOnly()
    local view, private = freedoomView("e1m4")
    local run = view.run
    local line
    for _, each in ipairs(run.map.lines) do
      if (each.special == 97 or each.special == 39) and not line then
        line = each
      end
    end
    assert(line, "a teleport")
    local x, y = run.player.x, run.player.y
    assert(not private.Freedoom.Trigger(run, line, "walk", nil, false), "not from behind")
    equal(x, run.player.x, "and stayed where they were")
    assert(private.Freedoom.Trigger(run, line, "walk", nil, true), "from the front")
    local landed = false
    for _, landing in ipairs(run.teleports) do
      if landing.x == run.player.x and landing.y == run.player.y then
        landed = landing.sector.tag == line.tag
      end
    end
    assert(landed, "to where the teleport lands")
  end

  function tests.FreedoomViewDrawsOnlyWhatChanged()
    local view = freedoomView()
    local screen = view.screen
    local drawn = screen.stamp
    view:draw()
    equal(drawn, screen.stamp, "nothing changed, nothing drawn")
    view.run.angle = view.run.angle + 0.1
    view:draw()
    equal(drawn + 1, screen.stamp, "turned")
    view.run.map:Changed()
    view:draw()
    equal(drawn + 2, screen.stamp, "something in the map changed")
    view:draw()
    equal(drawn + 2, screen.stamp, "and not again")
  end

  function tests.FreedoomMonstersComeAtAShot()
    math.randomseed(7)
    local view = freedoomView()
    local run = view.run
    local map = run.map
    -- Into the room most monsters share, away from them
    local counts, busiest = {}, nil
    for _, actor in ipairs(run.actors) do
      if actor.info and not actor.info.barrel then
        counts[actor.sector] = (counts[actor.sector] or 0) + 1
        if not busiest or counts[actor.sector] > counts[busiest.sector] then
          busiest = actor
        end
      end
    end
    local placed
    for _, away in ipairs({ 256, 192, 128 }) do
      for turn = 0, 15 do
        local x, y = busiest.x + math.cos(turn * math.pi / 8) * away, busiest.y + math.sin(turn * math.pi / 8) * away
        if not placed and map:SectorAt(x, y) == busiest.sector and not map:Check(x, y, 16, nil, run.player) then
          placed = { x, y }
        end
      end
    end
    map:MoveThing(run.player, placed[1], placed[2])
    map:Settle(run.player)
    run.angle = math.atan2(busiest.y - placed[2], busiest.x - placed[1])
    view.down.F = true
    local health = run.inventory.health
    for _ = 1, 35 * 6 do
      view:tick(1 / 35)
    end
    local awake, dead = 0, 0
    for _, actor in ipairs(run.actors) do
      if actor.info and not actor.info.barrel then
        awake = awake + (actor.target and 1 or 0)
        dead = dead + (actor.shootable and 0 or 1)
      end
    end
    assert(awake > 0, "the shots were heard")
    assert(dead > 0, "and somebody was shot dead")
    assert(run.inventory.ammo.bullets < 50, "with bullets")
    assert(run.inventory.health < health, "and they shot back")
  end

  --- Freedoom's first map with nobody in it but the player and as many of its monsters as are
  --- asked for, each with 1000 health, who stand where they are put and only feel what is done to them
  local function freedoomAlone(count)
    local view, private = freedoomView()
    local run = view.run
    local kept = {}
    for _, actor in ipairs(run.actors) do
      if #kept < count and actor.info and not actor.info.barrel and not actor.info.floats then
        local still = { { "A", -1 } }
        local sequences = setmetatable({ stand = still, chase = still, pain = still }, { __index = actor.info.sequences })
        actor.info = setmetatable({ sequences = sequences }, { __index = actor.info })
        actor.sequences, actor.health = sequences, 1000
        private.Actors.Start(actor, "stand")
        kept[#kept + 1] = actor
      else
        run.map:RemoveThing(actor)
      end
    end
    run.actors = { unpack(kept) }
    return view, kept
  end

  --- Somewhere on the map, and a way to face from there, with nothing in the way as far ahead
  --- and as wide either side as asked, all on one floor; facing along the map's lines if asked
  local function freedoomOpen(run, far, wide, along)
    local map, player = run.map, run.player
    local function nothing()
      return false
    end
    for _, thing in ipairs(map.data.things) do
      local floor = map:SectorAt(thing.x, thing.y).floor
      if not map:Check(thing.x, thing.y, player.radius, nil, player) then
        for turn = 0, 15, along and 4 or 1 do
          local angle, open = turn * math.pi / 8, true
          for side = -4, 4 do
            local way = angle + wide * side / 4
            if map:Shoot(thing.x, thing.y, floor + 41, way, far + 64, player, nothing, {}).line then
              open = false
            end
            for ahead = 32, far, 32 do
              open = open and map:SectorAt(thing.x + math.cos(way) * ahead, thing.y + math.sin(way) * ahead).floor == floor
            end
          end
          if open then
            map:MoveThing(player, thing.x, thing.y)
            map:Settle(player)
            run.angle = angle
            return thing.x, thing.y, angle
          end
        end
      end
    end
    error("nowhere open enough")
  end

  --- Gives the player a weapon and something for it, changes to it with its number key and
  --- waits for it to come up
  local function freedoomArm(view, weapon, key, ammo, amount)
    local run = view.run
    run.inventory.weapons[weapon] = true
    run.inventory.ammo[ammo] = amount
    view.ticker:Fire("OnKeyDown", key)
    equal(weapon, run.inventory.pending, key .. " changes to it")
    for _ = 1, 70 do
      view:worldTic()
    end
    equal(weapon, run.inventory.weapon, "in hand")
    equal(0, run.gunMoving, "and up")
  end

  --- Fires once, and lets the world go on for so many tics
  local function freedoomFire(view, tics)
    view.run.firing = true
    view:worldTic()
    view.run.firing = false
    for _ = 1, tics do
      view:worldTic()
    end
  end

  function tests.FreedoomRocketGoesUpOnWhatItHits()
    math.randomseed(3)
    local view, monsters = freedoomAlone(2)
    local run = view.run
    local map = run.map
    local x, y, angle = freedoomOpen(run, 320, 0.4)
    local hit, beside = monsters[1], monsters[2]
    local cos, sin = math.cos(angle), math.sin(angle)
    map:MoveThing(hit, x + cos * 256, y + sin * 256)
    map:MoveThing(beside, x + cos * 256 - sin * 48, y + sin * 256 + cos * 48)
    freedoomArm(view, "launcher", "5", "rockets", 5)
    freedoomFire(view, 0)
    local at
    for _ = 1, 40 do
      view:worldTic()
      for _, actor in ipairs(run.actors) do
        if not at and actor.picture == "MISLB" then
          at = { x = actor.x, y = actor.y }
        end
      end
    end
    assert(at, "the rocket went up")
    equal(4, run.inventory.ammo.rockets, "a rocket fired")
    --- What a blast of 128 from where it went up does to somebody, Doom's way
    local function blast(monster)
      return 128 - math.max(0, math.max(math.abs(monster.x - at.x), math.abs(monster.y - at.y)) - monster.radius)
    end
    local struck, blasted = 1000 - hit.health, 1000 - beside.health
    assert(blasted > 0 and math.abs(blasted - blast(beside)) < 1e-6, "the one beside it caught in the blast, no more")
    local rocket = struck - blast(hit)
    assert(rocket >= 20 and rocket <= 160 and math.abs(rocket / 20 - math.floor(rocket / 20 + 0.5)) < 1e-6,
      "the one it hit took the rocket as well as the blast, " .. rocket)
    equal(100, run.inventory.health, "and nothing reached whoever fired it from that far")
  end

  function tests.FreedoomRocketUpCloseHurtsWhoeverFiredIt()
    math.randomseed(5)
    local view = freedoomAlone(0)
    local run = view.run
    local map, player = run.map, run.player
    local x, y, angle = freedoomOpen(run, 64, 0, true)
    local cos, sin = math.cos(angle), math.sin(angle)
    local wall = map:Shoot(x, y, player.z + 41, angle, 2048, player, function()
      return false
    end, {}).distance + 4
    local placed = false
    for back = 17, 31 do
      if not placed and not map:Check(x + cos * (wall - back), y + sin * (wall - back), player.radius, nil, player) then
        map:MoveThing(player, x + cos * (wall - back), y + sin * (wall - back))
        placed = true
      end
    end
    assert(placed, "right in front of a wall")
    freedoomArm(view, "launcher", "5", "rockets", 1)
    run.inventory.armor, run.inventory.armorClass = 200, 2
    freedoomFire(view, 40)
    equal(0, run.inventory.ammo.rockets, "the rocket fired")
    equal(100 - 64, run.inventory.health, "went up in their face, all 128 of it, half of that through the blue armour")
    equal(200 - 64, run.inventory.armor)
  end

  function tests.FreedoomPlasmaBurstsOnAWall()
    math.randomseed(9)
    local view = freedoomAlone(0)
    local run = view.run
    local map, player = run.map, run.player
    local x, y, angle = freedoomOpen(run, 128, 0.2)
    local wall = map:Shoot(x, y, player.z + 41, angle, 4096, player, function()
      return false
    end, {}).distance + 4
    freedoomArm(view, "plasma", "6", "cells", 20)
    freedoomFire(view, 0)
    equal(19, run.inventory.ammo.cells, "a cell a shot")
    assert(run.light > 0, "its flash lights the room")
    equal(player, player.sector.soundTarget, "and it is heard")
    local burst
    for _ = 1, 35 * 6 do
      view:worldTic()
      for _, actor in ipairs(run.actors) do
        if not burst and actor.picture and actor.picture:sub(1, 4) == "PLSE" then
          burst = math.sqrt((actor.x - x) ^ 2 + (actor.y - y) ^ 2)
        end
      end
    end
    assert(burst, "it burst")
    assert(burst <= wall and burst > wall - 64, "on the wall ahead")
    equal(0, #run.actors, "and was gone")
  end

  function tests.FreedoomBFGSpraysWhatIsInFront()
    math.randomseed(11)
    local view, monsters = freedoomAlone(3)
    local run = view.run
    local map = run.map
    local x, y, angle = freedoomOpen(run, 256, 0.5)
    for index, monster in ipairs(monsters) do
      local way = angle + (index - 2) * 0.35
      map:MoveThing(monster, x + math.cos(way) * 192, y + math.sin(way) * 192)
    end
    freedoomArm(view, "bfg", "7", "cells", 80)
    run.firing = true
    view:worldTic()
    run.firing = false
    local flashes = {}
    for _ = 1, 35 * 3 do
      view:worldTic()
      for _, actor in ipairs(run.actors) do
        if actor.picture and actor.picture:sub(1, 4) == "BFE2" then
          flashes[actor] = true
        end
      end
    end
    equal(40, run.inventory.ammo.cells, "forty cells a shot")
    for index, monster in ipairs(monsters) do
      assert(monster.health < 1000, "the tracers found monster " .. index)
    end
    assert(next(flashes), "and flashed green on them")
    equal(100, run.inventory.health, "and nothing came back at whoever fired it")
  end

  function tests.FreedoomTurnsToWhatCanFireInDoomsOrder()
    local view = freedoomAlone(0)
    local run = view.run
    local inventory = run.inventory
    --- Holding a weapon, with only these, fires: what it changes to
    local function dry(holding, weapons, ammo)
      inventory.weapons, inventory.weapon, inventory.pending = weapons, holding, nil
      for kind in pairs(inventory.ammo) do
        inventory.ammo[kind] = ammo[kind] or 0
      end
      run.gunMoving, run.gunY = 0, 32
      freedoomFire(view, 0)
      return inventory.pending
    end
    local all = { fist = true, pistol = true, launcher = true, plasma = true, bfg = true }
    equal("plasma", dry("bfg", all, { cells = 39, bullets = 50, rockets = 5 }), "the plasma gun first, from a BFG short of cells")
    local noPlasma = { fist = true, pistol = true, launcher = true, bfg = true }
    equal("pistol", dry("bfg", noPlasma, { cells = 39, bullets = 50, rockets = 5 }), "the pistol before the rocket launcher")
    equal("launcher", dry("bfg", noPlasma, { cells = 39, rockets = 5 }), "the launcher when nothing else has anything")
    equal("bfg", dry("launcher", noPlasma, { cells = 40 }), "the BFG after it")
    equal("fist", dry("launcher", noPlasma, { cells = 39 }), "and the fist when nothing fires")

    inventory.weapons, inventory.weapon, inventory.pending = { fist = true, pistol = true, plasma = true }, "pistol", nil
    view.ticker:Fire("OnKeyDown", "7")
    equal(nil, inventory.pending, "no BFG to change to")
    view.ticker:Fire("OnKeyDown", "6")
    equal("plasma", inventory.pending, "6 for the plasma gun")
  end

  function tests.FreedoomViewPicksUpAndUnlocks()
    local view = freedoomView()
    local run = view.run
    local map, walker = run.map, run.player
    assert(#run.animated > 0, "things that go through frames")

    -- Stood on a stimpack while hurt
    local stim
    for _, sector in ipairs(map.sectors) do
      for thing in pairs(sector.things) do
        if thing.type == 2011 then
          stim = thing
        end
      end
    end
    assert(stim, "a stimpack lies somewhere")
    run.inventory.health = 50
    walker.x, walker.y = stim.x, stim.y
    map:Settle(walker)
    view:tick(0.02)
    equal(60, run.inventory.health, "picked up")
    assert(not stim.sector, "and gone from the map")
    equal("freedoom_got_stim", view.message, "and said so")

    -- In front of a blue door
    local door
    for _, line in ipairs(map.lines) do
      if line.special == 26 and line.back then
        door = line
        break
      end
    end
    assert(door, "a blue door")
    local length = door.length
    local middleX, middleY = (door.x1 + door.x2) / 2, (door.y1 + door.y2) / 2
    walker.x, walker.y = middleX + door.dy / length * 40, middleY - door.dx / length * 40
    run.angle = math.atan2(-door.dx, door.dy) + math.pi
    map:Settle(walker)
    view:use()
    equal("freedoom_need_blue", view.message, "locked")
    equal(nil, map:Moving(door.back.sector, "ceiling"), "and shut")
    run.inventory.keys.bluecard = true
    view:use()
    assert(map:Moving(door.back.sector, "ceiling"), "the card opens it")
  end

  --- Draws from a point and checks that every pixel of the screen is drawn once, no more
  local function coverage(private, map, x, y, z, angle, detail)
    private.Strips = { New = function()
      return { frame = {}, Layout = function() end }
    end }
    assert(loadfile("GUI/SectorView.lua"))(ADDON_NAME, private)
    local view = private.SectorView.New({}, { detail = detail })
    view:SetMap(map)
    local grid, count, level = {}, 0, nil
    local function cover(left, top, right, bottom)
      count = count + 1
      if level then
        -- Things and what is seen through are drawn over the rest
        return
      end
      for row = top, bottom - 1 do
        for column = left, right - 1 do
          local key = row * 320 + column
          grid[key] = (grid[key] or 0) + 1
        end
      end
    end
    local sink = {
      Begin = function() end,
      SetLevel = function(_, to) level = to end,
      Quad = function(_, left, top, right, bottom) cover(left, top, right, bottom) end,
      Mapped = function(_, left, top, right, bottom) cover(left, top, right, bottom) end,
      Finish = function() return count end,
    }
    local stats = view:Draw({ x = x, y = y, z = z, angle = angle }, sink)
    for key = 0, 320 * 200 - 1 do
      local times = grid[key] or 0
      if times ~= 1 then
        error(string.format("pixel %d,%d drawn %d times from %d,%d facing %.2f", key % 320, math.floor(key / 320), times, x, y, angle), 2)
      end
    end
    return stats
  end

  function tests.SectorViewDrawsEveryPixelOnce()
    local private = mapEngine()
    local map = twoRooms(private, 24)
    for turn = 0, 15 do
      coverage(private, map, 40, 70, 41, turn * math.pi / 8)
      coverage(private, map, 200, 30, 65, turn * math.pi / 8, 2)
    end
    assert(loadfile("ForeverGames_Freedoom/Maps/E1M1.lua"))(ADDON_NAME, private)
    local e1m1 = private.SectorMap.Load("freedoom_e1m1")
    local looked = 0
    for _, thing in ipairs(e1m1.data.things) do
      if looked < 30 then
        looked = looked + 1
        local stats = coverage(private, e1m1, thing.x, thing.y, e1m1:SectorAt(thing.x, thing.y).floor + 41, math.rad(thing.angle))
        assert(stats.pieces > 0 and stats.segs > 0, "something was drawn")
      end
    end
    -- Run, from every other thing in it, looking every which way
    assert(loadfile("ForeverGames_Freedoom/Maps/Run.lua"))(ADDON_NAME, private)
    local run = private.SectorMap.Load("freedoom_run")
    for index, thing in ipairs(run.data.things) do
      if index % 2 == 0 then
        coverage(private, run, thing.x, thing.y, run:SectorAt(thing.x, thing.y).floor + 41, index * 1.3)
      end
    end
  end
end

-----------------------------
-- Races
-----------------------------

do
  --- A game for one that is a dash to the end, with a ghost of the way there: "w" gets there and
  --- "x" falls over on the way
  --- @param private table
  --- @param shown table? Filled with what the view is asked to show
  local function registerDash(private, shown)
    private.Games.Register({
      id = "dash",
      name = "Dash",
      genre = "solo",
      version = 1,
      seats = 1,
      clock = "open",
      ghost = { every = 0.5, course = function()
        return { "w" }
      end },
      newState = function()
        return {}
      end,
      turn = function()
        return 1
      end,
      validate = function(_, _, move)
        return move == "w" or move == "x"
      end,
      apply = function(state, _, move)
        state.outcome = { winner = move == "w" and 1 or 0 }
      end,
      result = function(state)
        return state.outcome
      end,
      record = function(_, seconds, result)
        if result and result.winner == 1 then
          return { { key = "time", value = seconds, lower = true } }
        end
        return nil
      end,
      createView = function()
        return {
          Layout = function() end,
          Update = function(_, view)
            shown.view = view
          end,
        }
      end,
    })
  end

  --- Two players with the games only the tests have, and Alice's challenge to Bob to race one
  --- @param gameId string? Counting if left out
  --- @param setup table? How it is set up
  --- @return World, table alice, table bob, Match mine, Match? theirs
  local function raced(gameId, setup)
    local world = World.New()
    world.prepare = function(private)
      registerCounting(private)
      registerDash(private)
    end
    local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
    local mine = assert(alice.session:Invite("Bob-Realm", gameId or "counting", setup))
    world:Deliver()
    return world, alice, bob, mine, bob.matches[mine.id]
  end

  --- Has a player play a game of counting: up so many times, then won or lost
  --- @param player table
  --- @param id string
  --- @param seconds number How long it takes
  --- @param last string "w" to win, "x" to lose
  local function count(player, id, seconds, last)
    assert(player.session:Move(id, "u"))
    player.session:Spend(id, seconds)
    assert(player.session:Move(id, last))
  end

  function tests.RaceIsTakenUpPlayedAndWonByTheQuicker()
    local world, alice, bob, mine, theirs = raced()
    local Race = alice.private.Race
    equal("active", mine.status, "whoever challenges plays at once")
    equal(true, mine.race.unanswered)
    equal("Bob-Realm", mine.race.rival)
    equal(1, #mine.players, "a game for one on each side")
    assert(theirs, "the challenge arrived")
    equal("incoming", theirs.status)
    equal("Alice-Realm", theirs.race.rival)
    equal(true, bob.session:NeedsAttention(theirs))
    equal(false, alice.session:NeedsAttention(mine))
    equal("Bob-Realm", alice.session:Opponents()[1].name)
    equal("Alice-Realm", bob.session:Opponents()[1].name)
    equal(false, (bob.session:Move(theirs.id, "u")), "nothing is played before it is taken up")

    -- Alice is done before Bob has answered: her time waits for him
    count(alice, mine.id, 7.5, "w")
    equal("finished", mine.status)
    equal(750, Race.Mine(mine.race))
    equal(0, #world.queue, "told nobody yet")

    assert(bob.session:Accept(theirs.id))
    world:Deliver()
    equal(nil, mine.race.unanswered)
    equal(750, Race.Theirs(theirs.race), "her time is there to beat")
    equal(1, mine.race.told)
    equal(nil, Race.Outcome(theirs.race), "while his run is on")
    equal(false, bob.session:CanForget(theirs), "a race that is on is given up, not thrown away")
    assert(bob.session:Move(theirs.id, "u"))
    equal(false, bob.session:CanUndo(theirs), "and nothing is taken back")
    bob.session:Spend(theirs.id, 9.25)
    assert(bob.session:Move(theirs.id, "w"))
    world:Deliver()
    equal(925, Race.Theirs(mine.race))
    equal("won", Race.Outcome(mine.race))
    equal("lost", Race.Outcome(theirs.race))
    equal(true, Race.Settled(mine.race))
    equal(true, Race.Settled(theirs.race))
    equal(true, alice.session:NeedsAttention(mine), "how Bob did is news to Alice")
    alice.session:MarkRead(mine.id)
    equal(false, alice.session:NeedsAttention(mine))
    equal(7.5, alice.session:Best("counting", "time"), "a run is a game like any other for the records")

    -- Only the times ever went anywhere, and once both are known nothing more is said
    for _, sent in ipairs(world.sent) do
      local entry = sent:match(":MOV:[^:]+:%d+:%d+:(.*)$")
      assert(entry == nil or entry:match("^%d+$"), "a move was sent: " .. sent)
    end
    local before = #world.sent
    world:Tick(2 * 3600)
    world:Tick(2 * 3600)
    equal(before, #world.sent, "nothing more to say")
    assert(alice.session:Forget(mine.id))
    equal(nil, alice.matches[mine.id], "gone once it is told")
  end

  function tests.RaceIsDealtTheSameForBoth()
    local world, alice, bob, mine, theirs = raced("minesweeper", { options = { level = "expert" } })
    equal("expert", theirs.options.level, "by the rules it was set up with")
    assert(bob.session:Accept(theirs.id))
    world:Deliver()
    local game = alice.private.Games.Get("minesweeper")
    local first = game.moves(alice.private.Match.State(mine), 1)[1]
    assert(alice.session:Move(mine.id, first))
    assert(bob.session:Move(theirs.id, first))
    equal(written(alice.private.Match.State(mine)), written(bob.private.Match.State(theirs)), "the same field of mines")
    equal(30, bob.private.Match.State(theirs).columns)

    -- Another race is another deal
    local other = assert(alice.session:Invite("Bob-Realm", "minesweeper", { options = { level = "expert" } }))
    assert(alice.session:Move(other.id, first))
    assert(written(alice.private.Match.State(other)) ~= written(alice.private.Match.State(mine)))

    -- A puzzle is dealt as soon as it begins
    local puzzles, setter, solver, puzzle, copy = raced("sudoku")
    assert(solver.session:Accept(copy.id))
    puzzles:Deliver()
    equal(written(setter.private.Match.State(puzzle)), written(solver.private.Match.State(copy)), "the same Sudoku")
  end

  function tests.RaceGoesOnWithEitherOfThemAway()
    local world = World.New()
    world.prepare = registerCounting
    local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
    local Race = alice.private.Race
    bob.online = false
    local id = assert(alice.session:Invite("Bob-Realm", "counting")).id
    world:Deliver()
    equal(nil, bob.matches[id], "lost on the way")
    bob.online = true
    world:Tick(31)
    local theirs = assert(bob.matches[id], "tried again")
    equal("incoming", theirs.status)

    -- Bob takes it up and plays it out while Alice is away: neither his answer nor his time get there
    alice.online = false
    assert(bob.session:Accept(id))
    count(bob, id, 4, "x")
    world:Deliver()
    equal(true, alice.matches[id].race.unanswered)
    equal(false, Race.Mine(theirs.race), "his run didn't finish")

    -- Alice comes back and asks again, which Bob answers, and his run follows
    alice.online = true
    alice = world:Relog(alice)
    local mine = alice.matches[id]
    equal(nil, mine.race.unanswered)
    world:Tick(1)
    equal(false, Race.Theirs(mine.race))

    -- She finishes while he is away, and he hears of it when he comes back
    bob.online = false
    count(alice, id, 3, "w")
    world:Deliver()
    equal(nil, Race.Theirs(theirs.race))
    bob.online = true
    bob = world:Relog(bob)
    theirs = bob.matches[id]
    equal(300, Race.Theirs(theirs.race))
    equal("won", Race.Outcome(mine.race))
    equal("lost", Race.Outcome(theirs.race))
    equal(true, Race.Settled(mine.race))

    -- A run that is over and taken off the list is still told to the rival
    local again = assert(alice.session:Invite("Bob-Realm", "counting")).id
    world:Deliver()
    assert(bob.session:Accept(again))
    world:Deliver()
    alice.online = false
    count(bob, again, 2, "w")
    world:Deliver()
    assert(bob.session:Forget(again))
    equal(true, bob.matches[again].hidden, "kept out of sight until she has it")
    equal(false, bob.session:NeedsAttention(bob.matches[again]))
    alice.online = true
    world:Tick(600)
    equal(200, Race.Theirs(alice.matches[again].race))
  end

  function tests.GameForOneKeepsTheGhostOfTheBestRun()
    local world = World.New()
    local alice = world:AddPlayer("Alice-Realm")
    registerDash(alice.private, {})
    local session = alice.session
    --- A run of the dash: where Alice is at every half second of it, then whether she gets there
    local function dash(seconds, at, gets)
      local match = assert(session:Invite({}, "dash"))
      for half = 0, seconds * 2 - 1 do
        session:Spend(match.id, half == 0 and 0 or 0.5)
        assert(session:Sample(match.id, at .. half), "kept as it goes")
      end
      session:Spend(match.id, 0.5)
      assert(session:Move(match.id, gets and "w" or "x"))
      return match
    end
    equal(nil, session:Ghost("dash", "time"), "no ghost before there is a best")
    dash(3, "a", true)
    local ghost = session:Ghost("dash", "time")
    equal(6, #ghost, "the run that set the best, a sample every half second")
    equal("a0", ghost[1])
    dash(2, "b", false)
    equal("a0", session:Ghost("dash", "time")[1], "a run that didn't get there doesn't make a best")
    dash(4, "c", true)
    equal("a0", session:Ghost("dash", "time")[1], "nor does a slower one")
    dash(2, "d", true)
    equal("d0", session:Ghost("dash", "time")[1], "a quicker one does")
    equal(4, #session:Ghost("dash", "time"))
    assert(session.env.ghosts.dash.time, "kept where it is saved")
  end

  function tests.RaceTakesAGhostAlongWithTheTime()
    local world, alice, bob, mine, theirs = raced("dash")
    local Race = alice.private.Race
    assert(bob.session:Accept(theirs.id))
    world:Deliver()
    equal(false, alice.session:Sample(mine.id, "a+b"), "a sample doesn't read right")
    equal(false, alice.session:Sample(mine.id, string.rep("y", Race.SAMPLE_MOST + 1)))
    equal(false, alice.session:Sample("nope", "a"))
    -- Four times a second for a long while: one is kept every half second, until there is no
    -- more room
    for step = 0, 800 do
      alice.session:Spend(mine.id, 0.25)
      alice.session:Sample(mine.id, string.format("p%03d", math.floor(step / 2)) .. string.rep("z", 26))
    end
    local samples = mine.race.samples
    assert(samples > 100 and samples < 200, "kept " .. tostring(samples))
    assert(#mine.race.trail <= 4000)
    assert(alice.session:Move(mine.id, "w"))
    local run = mine.race.run
    assert(#run > 16, "a run of " .. #run .. " is more than one stretch")

    -- One piece goes missing on the way, and is asked for again
    local dropped = false
    world:Deliver(function(message)
      if not dropped and message.text:find(":MOV:" .. mine.id .. ":5:", 1, true) then
        dropped = true
        return true
      end
      return false
    end)
    local ghost = Race.Ghost(theirs.race)
    assert(ghost, "the ghost came")
    equal(samples, #ghost)
    equal(table.concat(ghost, "+"), table.concat(run, "+", 2))
    equal(Race.Mine(mine.race), Race.Theirs(theirs.race))
    local moves = 0
    for _, sent in ipairs(world.sent) do
      assert(#sent:match(" (.*)$") <= 255, "too long for a message: " .. sent)
      moves = moves + (sent:find(":MOV:", 1, true) and 1 or 0)
    end
    assert(moves < #run * 2, #run .. " entries took " .. moves .. " messages")
    equal(nil, Race.Ghost(mine.race), "nothing of Bob's yet")
    assert(bob.session:Move(theirs.id, "x"))
    world:Deliver()
    equal(nil, Race.Ghost(mine.race), "a run that kept no ghost has none")
    equal("won", Race.Outcome(mine.race))
  end

  function tests.RaceCanBeTheRunThatSetTheBest()
    local world = World.New()
    world.prepare = function(private)
      registerCounting(private)
      registerDash(private)
    end
    local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
    local Race = alice.private.Race
    equal(nil, alice.session:BestToRace("dash"), "no best yet")
    equal("no_best", select(2, alice.session:Invite("Bob-Realm", "dash", { best = true })))
    local solo = assert(alice.session:Invite({}, "dash"))
    for half = 0, 5 do
      alice.session:Spend(solo.id, half == 0 and 0 or 0.5)
      alice.session:Sample(solo.id, "a" .. half)
    end
    alice.session:Spend(solo.id, 0.5)
    assert(alice.session:Move(solo.id, "w"))
    equal(3, alice.session:BestToRace("dash"))
    equal(nil, alice.session:BestToRace("counting"), "a game whose runs aren't one course can't")

    local mine = assert(alice.session:Invite("Bob-Realm", "dash", { best = true }))
    equal("finished", mine.status, "nothing for Alice to play")
    equal(3, mine.played)
    equal(300, Race.Mine(mine.race))
    equal(true, mine.race.unanswered)
    world:Deliver()
    local theirs = bob.matches[mine.id]
    equal("incoming", theirs.status)
    equal(nil, Race.Theirs(theirs.race), "told once Bob takes it up")
    assert(bob.session:Accept(theirs.id))
    world:Deliver()
    equal(300, Race.Theirs(theirs.race))
    local ghost = assert(Race.Ghost(theirs.race), "her best's ghost came with it")
    equal("a0+a1+a2+a3+a4+a5", table.concat(ghost, "+"))
    equal(3, alice.session:Best("dash", "time"), "sending it isn't another best")

    alice.session:Spend(theirs.id, 0)
    bob.session:Spend(theirs.id, 2)
    assert(bob.session:Move(theirs.id, "w"))
    world:Deliver()
    equal("lost", Race.Outcome(mine.race))
    equal("won", Race.Outcome(theirs.race))
  end

  function tests.GameThatNeedsAnAddonIsOnlyOfferedWithIt()
    local Games = loadEngine().Games
    local freedoom = Games.Get("freedoom")
    equal("ForeverGames_Freedoom", freedoom.addon, "Freedoom's maps are an addon of their own")
    assert(Games.Offered(freedoom), "taken to be there until the client says")
    Games.SetAddOnCheck(function(addon)
      return addon ~= "ForeverGames_Freedoom"
    end)
    assert(not Games.Offered(freedoom), "not without its maps")
    for _, game in ipairs(Games.Search()) do
      assert(game ~= freedoom, "so it isn't found")
    end
    for _, game in ipairs(Games.Search("freedoom")) do
      assert(game ~= freedoom, "not even by name")
    end
    assert(Games.Offered(Games.Get("minesweeper")), "a game that needs nothing is offered all the same")

    -- And a race at it is turned down as a game that isn't here
    local world = World.New()
    world.prepare = function(private)
      private.Games.SetAddOnCheck(function(addon)
        return addon ~= "ForeverGames_Freedoom"
      end)
    end
    local bob = world:AddPlayer("Bob-Realm")
    world.queue = {}
    bob.session:Receive("Alice-Realm", "1:RAC:r1:freedoom:" .. freedoom.version)
    equal("1:DEC:r1:nogame", world.queue[1] and world.queue[1].text)
  end

  function tests.RaceLeavesOutAGameThatSaysSo()
    local private = loadEngine()
    local Race, Games = private.Race, private.Games
    local minesweeper = Games.Get("minesweeper")
    assert(Race.Has(minesweeper), "a timed game for one can be raced")
    minesweeper.raced = false
    assert(not Race.Has(minesweeper), "unless it says it isn't to be")
    minesweeper.raced = nil
  end

  function tests.RaceChallengesThatDontReadRightAreTurnedDown()
    local Codec = loadEngine().Codec
    local plain = assert(Codec.Decode("1:RAC:abc:counting:1"))
    equal("counting", plain.game)
    equal(1, plain.gameVersion)
    equal(nil, plain.options)
    equal("level=expert", Codec.Decode("1:RAC:abc:minesweeper:1:level=expert").options)
    equal(nil, Codec.Decode("1:RAC:abc:counting"))
    equal(nil, Codec.Decode("1:RAC:abc:counting:one"))
    equal(nil, Codec.Decode("1:RAC:a b:counting:1"))
    equal(nil, Codec.Decode("2:RAC:abc:counting:1"), "another version of the protocol")

    local world = World.New()
    world.prepare = registerCounting
    local bob = world:AddPlayer("Bob-Realm")
    local Race = bob.private.Race
    --- What Bob says back to a message from Alice
    local function answer(text, from)
      world.queue = {}
      bob.session:Receive(from or "Alice-Realm", text)
      return world.queue[1] and world.queue[1].text
    end
    equal("1:DEC:r1:nogame", answer("1:RAC:r1:nope:1"))
    equal("1:DEC:r2:version", answer("1:RAC:r2:counting:2"), "another version of the game")
    equal("1:DEC:r3:version", answer("1:RAC:r3:minesweeper:1:level=impossible"), "rules it doesn't have")
    equal("1:DEC:r4:version", answer("1:RAC:r4:solitaire:1"), "a game that can't be raced")
    equal("1:DEC:r5:version", answer("1:RAC:r5:counting:1:_c=2hard"))
    bob.knows = {}
    equal("1:DEC:r6:strangers", answer("1:RAC:r6:counting:1"))
    bob.knows = nil
    equal(nil, next(bob.matches), "none of it was kept")

    -- A race, and what doesn't read right about the runs told in it
    equal(nil, answer("1:RAC:r7:counting:1"))
    assert(bob.session:Accept("r7"))
    local race = bob.matches.r7.race
    answer("1:MOV:r7:1:1:soon")
    answer("1:MOV:r7:1:99:120")
    answer("1:MOV:r7:2:2:p1")
    equal(0, #race.heard, "none of that was taken")
    equal(nil, answer("1:MOV:r7:1:1:120", "Mallory-Realm"), "nor anything from anyone else")
    equal(0, #race.heard)
    equal("1:ACK:r7:1", answer("1:MOV:r7:1:1:120"))
    equal(120, Race.Theirs(race))
    answer("1:MOV:r7:1:1:5")
    equal(120, Race.Theirs(race), "told once")
    equal("1:ACC:r7", answer("1:RAC:r7:counting:1"), "a challenge again is answered again")
    equal("1:DEC:r8:gone", answer("1:MOV:r8:1:1:120"), "a race that isn't there")
  end

  function tests.RaceTurnedDownCalledOffAndGivenUp()
    local world, alice, bob, mine, theirs = raced()
    local Race = alice.private.Race
    assert(bob.session:Decline(theirs.id))
    world:Deliver()
    equal("declined", mine.race.declined)
    equal("active", mine.status, "the game goes on, alone")
    assert(alice.session:Move(mine.id, "u"))
    equal(true, alice.session:CanForget(mine))
    world.queue = {}
    bob.session:Receive("Alice-Realm", "1:RAC:" .. mine.id .. ":counting:1")
    equal("1:DEC:" .. mine.id, world.queue[1].text, "turned down again rather than shown twice")
    world:Deliver()
    equal(true, theirs.hidden)

    -- Called off before it is answered
    local second = assert(alice.session:Invite("Bob-Realm", "counting"))
    world:Deliver()
    assert(bob.matches[second.id])
    assert(alice.session:Forget(second.id))
    world:Deliver()
    equal(nil, bob.matches[second.id], "withdrawn")
    equal(true, alice.matches[second.id].hidden)

    -- Given up, a run didn't finish, and loses to one that did
    local third = assert(alice.session:Invite("Bob-Realm", "counting")).id
    world:Deliver()
    assert(bob.session:Accept(third))
    world:Deliver()
    equal(false, (bob.session:Forget(third)))
    assert(bob.session:Resign(third))
    world:Deliver()
    equal(false, Race.Theirs(alice.matches[third].race))
    count(alice, third, 60, "w")
    world:Deliver()
    equal("won", Race.Outcome(alice.matches[third].race))
    equal("lost", Race.Outcome(bob.matches[third].race))

    -- Neither of two that didn't finish beats the other, nor two that are as quick
    local fourth = assert(alice.session:Invite("Bob-Realm", "counting")).id
    world:Deliver()
    assert(bob.session:Accept(fourth))
    count(alice, fourth, 5, "x")
    count(bob, fourth, 5, "x")
    world:Deliver()
    equal("drawn", Race.Outcome(alice.matches[fourth].race))
    local fifth = assert(alice.session:Invite("Bob-Realm", "counting")).id
    world:Deliver()
    assert(bob.session:Accept(fifth))
    count(alice, fifth, 5, "w")
    count(bob, fifth, 5, "w")
    world:Deliver()
    equal("drawn", Race.Outcome(bob.matches[fifth].race))

    -- One the rival no longer has stops being told
    local sixth = assert(alice.session:Invite("Bob-Realm", "counting")).id
    world:Deliver()
    assert(bob.session:Accept(sixth))
    world:Deliver()
    bob.matches[sixth] = nil
    count(alice, sixth, 5, "w")
    world:Deliver()
    equal("gone", alice.matches[sixth].race.declined)
    equal(true, alice.session:CanForget(alice.matches[sixth]))

    -- A game that can't be raced still can't be played by two
    equal("player_count", select(2, alice.session:Invite("Bob-Realm", "solitaire")))
  end

  function tests.WizardChallengesSomebodyToARace()
    local world = World.New()
    local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
    local wizard = openWizard(alice)
    local card = Client.Find(function(widget)
      return widget.kind == "Button" and widget.game ~= nil and widget.game.id == "minesweeper" and widget:IsVisible()
    end)[1]
    equal("players_race", card.players.text)
    pickGame("minesweeper")
    equal(true, says("wizard_who_race"))
    equal(true, says("wizard_race_hint"))
    equal("Alice-Realm", (seating.Shown()), "the player alone until somebody is picked")
    equal(true, says("wizard_summary_race_alone"))
    ruleChoices("minesweeper_option_level")["minesweeper_level_expert"]:Fire("OnClick")

    local box = Client.Find(function(widget)
      return widget.kind == "EditBox" and widget.scripts.OnEnterPressed and widget:IsVisible()
    end)[1]
    box:SetText("Bob-Realm")
    box:Fire("OnTextChanged", true)
    equal("Alice-Realm, Bob-Realm", (seating.Shown()))
    equal(true, says("wizard_table_race"))
    equal(true, says("wizard_summary_race"))
    equal(true, says("wizard_race_rules"), "Bob is shown the rules")
    equal(0, #Client.Find(function(widget)
      return widget.kind == "Button" and widget.text == "wizard_link" and widget:IsVisible()
    end), "a race isn't linked in chat")
    Client.Button("wizard_race"):Fire("OnClick")
    equal(false, wizard.IsOpen())
    world:Deliver()
    local mine, theirs
    for _, match in pairs(alice.matches) do
      mine = match
    end
    for _, match in pairs(bob.matches) do
      theirs = match
    end
    equal("active", mine.status)
    equal("Bob-Realm", mine.race.rival)
    equal(mine.id, theirs.id)
    equal("incoming", theirs.status)
    equal("expert", theirs.options.level, "by the rules it was set up with")
  end

  function tests.WizardSendsTheBestToRace()
    local world = World.New()
    local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
    local Race = alice.private.Race
    alice.session.env.records.freedoom = { run = 42.5, e1m1_hard = 80 }
    alice.session.env.ghosts.freedoom = { run = "abc+def" }
    openWizard(alice)
    pickGame("freedoom")
    local function bestShown()
      return #Client.Find(function(widget)
        return widget.kind == "Button" and widget.text == "wizard_race_best" and widget:IsVisible()
      end) == 1
    end
    equal(false, bestShown(), "nobody to send it to yet")
    local box = Client.Find(function(widget)
      return widget.kind == "EditBox" and widget.scripts.OnEnterPressed and widget:IsVisible()
    end)[1]
    box:SetText("Bob-Realm")
    box:Fire("OnTextChanged", true)
    equal(true, bestShown(), "the best on the Run")
    ruleChoices("freedoom_option_skill")["freedoom_skill_hard"]:Fire("OnClick")
    equal(false, bestShown(), "a best without a ghost isn't sent")
    ruleChoices("freedoom_option_skill")["freedoom_skill_medium"]:Fire("OnClick")
    Client.Button("wizard_race_best"):Fire("OnClick")
    world:Deliver()
    local mine, theirs
    for _, match in pairs(alice.matches) do
      mine = match
    end
    for _, match in pairs(bob.matches) do
      theirs = match
    end
    equal("finished", mine.status)
    equal(4250, Race.Mine(mine.race))
    equal("run", bob.private.Match.State(theirs).level, "on the map it was set")
    assert(bob.session:Accept(theirs.id))
    world:Deliver()
    equal(4250, Race.Theirs(theirs.race))
    equal("abc+def", table.concat(Race.Ghost(theirs.race), "+"))
  end

  function tests.BestSentToSomebodyWithoutTheGameSaysWhy()
    local world = World.New()
    local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
    bob.private.Games.SetAddOnCheck(function()
      return false
    end)
    local lacked = {}
    bob.session.env.lacks = function(game, sender)
      lacked[#lacked + 1] = game.id .. " from " .. sender
    end
    alice.session.env.records.freedoom = { run = 42.5 }
    alice.session.env.ghosts.freedoom = { run = "abc+def" }
    local MainFrame = openWindow(alice)
    local mine = assert(alice.session:Invite("Bob-Realm", "freedoom", { best = true }))
    world:Deliver()
    equal("nogame", mine.race.declined)
    equal("freedoom from Alice-Realm", lacked[1], "Bob is told what he is missing")
    equal(nil, next(bob.matches), "and has no game of it")
    equal("status_declined_addon", MainFrame.Describe(mine), "Alice is told why, not shown a game for one")
  end

  function tests.WindowShowsARaceFromTheChallengeToWhoWon()
    local shown = {}
    local world = World.New()
    world.prepare = function(private)
      registerCounting(private, shown)
    end
    local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
    local MainFrame = openWindow(bob)
    local id = assert(alice.session:Invite("Bob-Realm", "counting")).id
    world:Deliver()
    MainFrame.Open()
    local row = Client.Find(function(widget)
      return widget.kind == "Button" and widget.matchId == id and widget:IsVisible()
    end)[1]
    equal("Alice-Realm  |cff808080race_of|r", row.name.text)
    equal("list_challenge", row.status.text)
    equal(true, row.marker:IsShown(), "a challenge waits on the player")

    -- Taken up from the list, it is on screen at once
    Client.Button("accept"):Fire("OnClick")
    world:Deliver()
    equal("active", bob.matches[id].status)
    equal(nil, alice.matches[id].race.unanswered)
    equal(true, says("race_versus"))
    equal(true, says("race_board"))
    equal("Alice-Realm", shown.view.race.rival)
    equal(nil, shown.view.race.theirs)
    equal(nil, shown.view.race.sample, "a game without a ghost isn't asked for one")
    equal("status_race_progress", MainFrame.Describe(bob.matches[id]))
    equal(0, #Client.Find(function(widget)
      return widget.kind == "Button" and (widget.text == "undo" or widget.text == "start_another") and widget:IsVisible()
    end), "nothing taken back, nothing started over")

    -- Alice's time comes in while Bob plays, and he gives up
    count(alice, id, 7.5, "w")
    world:Deliver()
    equal(7.5, shown.view.race.theirs)
    function StaticPopup_Show(which, _, _, proceed)
      StaticPopupDialogs[which].OnAccept(nil, proceed)
    end
    Client.Button("give_up"):Fire("OnClick")
    world:Deliver()
    equal("status_race_lost_unfinished", MainFrame.Describe(bob.matches[id]))
    equal("status_race_won_unfinished", MainFrame.Describe(alice.matches[id]))
    local board = {}
    for _, line in ipairs(Client.Find(function(widget)
      return widget.score ~= nil and widget.place ~= nil and widget:IsVisible()
    end)) do
      board[#board + 1] = line.place.text .. " " .. line.name.text .. " " .. line.score.text
    end
    equal("1. Alice-Realm race_time, 2. Bob-Realm race_no_time", table.concat(board, ", "), "the quicker first")

    -- And again, the same race
    Client.Button("race_again"):Fire("OnClick")
    world:Deliver()
    local again = 0
    for _, match in pairs(alice.matches) do
      again = again + (match.status == "incoming" and match.race and 1 or 0)
    end
    equal(1, again)
  end

  function tests.WindowHandsTheViewOfARaceItsGhost()
    local shown = {}
    local world = World.New()
    world.prepare = function(private)
      registerDash(private, shown)
    end
    local alice, bob = world:AddPlayer("Alice-Realm"), world:AddPlayer("Bob-Realm")
    local MainFrame = openWindow(bob)
    local id = assert(alice.session:Invite("Bob-Realm", "dash")).id
    world:Deliver()
    assert(bob.session:Accept(id))
    world:Deliver()
    for step = 1, 6 do
      alice.session:Sample(id, "a" .. step)
      alice.session:Spend(id, 0.5)
    end
    assert(alice.session:Move(id, "w"))
    world:Deliver()
    MainFrame.Open(id)
    local race = shown.view.race
    equal(3, race.theirs)
    equal("a1+a2+a3+a4+a5+a6", table.concat(race.ghost, "+"), "where she was, every half second")
    equal(true, race.sample("b1"), "and where he is, for his own")
    ForeverGamesFrame.detail:Fire("OnUpdate", 0.5)
    equal(true, shown.view.race.sample("b2"))
    equal("b1+b2", bob.matches[id].race.trail)
  end
end

-----------------------------
-- Courses
-----------------------------
do
  --- A course round a circle of radius 200 about (300, 300), driven clockwise on the map (y is
  --- down), over ground 5x5 heights 100 apart that rise by 10 a cell to the east and 1 to the south
  local function circleCourse()
    local private = {}
    assert(loadfile("Engine/Course.lua"))(ADDON_NAME, private)
    local track, count = {}, 300
    for i = 0, count - 1 do
      local a = i / count * 2 * math.pi
      track[#track + 1] = 300 + 200 * math.cos(a)
      track[#track + 1] = 300 + 200 * math.sin(a)
    end
    local heights = {}
    for j = 0, 4 do
      for i = 0, 4 do
        heights[#heights + 1] = i * 10 + j
      end
    end
    private.Course.Register("circle", { name = "Circle", world = 400, size = 5, cell = 100, heights = heights, rise = 0.5,
      highest = 30, light = 0.8, spacing = 2 * math.pi * 200 / count, track = track, half = 20, curb = 4, shoulder = 10,
      pictures = {}, haze = { 1, 1, 1 }, things = {} })
    return private.Course.Load("circle")
  end

  local function near(expected, actual, within, label)
    if math.abs(expected - actual) > within then
      error(("%s: expected %s, got %s"):format(label, tostring(expected), tostring(actual)), 2)
    end
  end

  function tests.CourseFindsWhereOnTheRoadAlongPuts()
    local course = circleCourse()
    for _, progress in ipairs({ 0, 1, 333.3, 700, course.length - 1 }) do
      for _, offset in ipairs({ -15, 0, 9 }) do
        local x, y = course:Along(progress, offset)
        local found, side = course:Locate(x, y)
        near(0, (found - progress + course.length / 2) % course.length - course.length / 2, 0.5, "progress " .. progress)
        near(offset, side, 0.5, "offset at " .. progress)
      end
    end
  end

  function tests.CourseRightIsInsideAClockwiseCircle()
    local course = circleCourse()
    -- Going round clockwise as the map is seen, y down, the middle is on the right
    local x, y, heading = course:Along(0, 10)
    near(490, x, 0.01, "x")
    near(300, y, 0.5, "y")
    near(math.pi / 2, heading, 0.05, "heading south")
  end

  function tests.CourseLooksNearTheHintFirstAndEverywhereIfItIsWrong()
    local course = circleCourse()
    local x, y = course:Along(500, 3)
    local progress, offset, hint = course:Locate(x, y, 2)
    near(500, progress, 0.5, "found from a hint far off")
    near(3, offset, 0.5, "offset")
    local again = course:Locate(x + 1, y, hint)
    near(500, again, 2, "found from its own hint")
  end

  function tests.CourseHeightBetweenHeightsAndBeyondTheMap()
    local course = circleCourse()
    near(0, course:Height(0, 0), 1e-9, "corner")
    near(15 + 0.5, course:Height(150, 50), 1e-9, "between")
    near(40 + 4, course:Height(400, 400), 1e-9, "far corner")
    -- 20 units past the east edge, rising 0.5 a unit
    near(40 + 2 + 10, course:Height(420, 200), 1e-9, "beyond, rising")
    -- and never more than 30 above the edge
    near(40 + 2 + 30, course:Height(1000, 200), 1e-9, "beyond, as high as it goes")
  end

  function tests.CourseRoadIncludesItsCurbs()
    local course = circleCourse()
    equal(true, course:OnRoad(23.9))
    equal(true, course:OnRoad(-23.9))
    equal(false, course:OnRoad(24.1))
  end
end

-- The checks every game is put through, a test for each
dofile("Tests/EveryGame.lua")(tests, loadEngine)
-- Where in Azeroth, and the places, races and views it is built on
dofile("Tests/Where.lua")(tests, loadEngine)

-----------------------------
-- Runner
-----------------------------
-- Every test, or with words given on the command line only the ones whose names have one of
-- them in: lua Tests/RunTests.lua EveryGame_chess Codec
-- In a block of its own: a chunk has room for only so many locals, and the tests take most of them

do
local names = {}
for name in pairs(tests) do
  local wanted = #arg == 0
  for _, word in ipairs(arg) do
    wanted = wanted or name:find(word, 1, true) ~= nil
  end
  if wanted then
    names[#names + 1] = name
  end
end
table.sort(names)

local failures = 0
for _, name in ipairs(names) do
  local ok, err = xpcall(tests[name], debug.traceback)
  if ok then
    print("  ok    " .. name)
  else
    failures = failures + 1
    print("  FAIL  " .. name .. "\n" .. tostring(err))
  end
end

print(string.format("\n%d tests, %d failed", #names, failures))
os.exit(failures == 0 and 0 or 1)
end
