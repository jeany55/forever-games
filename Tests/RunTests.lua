-- Runs the engine tests from the terminal: lua Tests/RunTests.lua
--
-- The engine (Engine/ and the rules half of Games/) has no WoW dependencies, so instead of
-- mocking the game client each test builds a couple of simulated players and wires their
-- sessions together through a fake network that can drop messages or take a player offline.

local ADDON_NAME = "ForeverGames"
local ENGINE_FILES = { "Engine/Codec.lua", "Engine/Games.lua", "Engine/Match.lua", "Engine/Session.lua", "Engine/Presence.lua", "Games/TicTacToe.lua", "Games/Chess.lua" }

-- What the window needs on top of the engine, in load order. Only the tests that click through
-- the window load these, on top of the fake client in Tests/FakeClient.lua.
local GUI_FILES = { "GUI/Widgets.lua", "GUI/Board.lua", "GUI/MainFrame.lua" }
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
local World = {}
World.__index = World

function World.New()
  return setmetatable({ clock = 1000000, players = {}, sent = {}, queue = {}, seed = 0 }, World)
end

--- @param name string
--- @param matches table? Saved matches to start from
function World:AddPlayer(name, matches)
  local player = { name = name, online = true, blocked = false, events = {}, private = loadEngine() }
  player.matches = matches or {}
  player.session = player.private.Session.New({
    me = name,
    matches = player.matches,
    now = function()
      return self.clock
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
  bob.session:Receive("Alice-Realm", "1:INV:abc:backgammon:1:1")
  bob.session:Receive("Alice-Realm", "1:INV:abd:tictactoe:99:1")
  equal(nil, bob.matches.abc)
  equal(nil, bob.matches.abd)
  equal("1:DEC:abc:nogame", world.queue[1].text)
  equal("1:DEC:abd:version", world.queue[2].text)
  equal(nil, (alice.session:Invite("Bob-Realm", "backgammon")))
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
  ForeverGames = { db = { profile = { sound = true, window = { width = 920, height = 680, focus = false } } }, printed = {} }
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
  local big = board.width

  Client.Button("focus_on"):Fire("OnClick")
  assert(board.width > big, "focus should give the board the room the list had")
  Client.Button("focus_off"):Fire("OnClick")
  equal(big, board.width)

  ForeverGamesFrame:SetSize(764, 560)
  assert(board.width >= 8 * 30, "the board should stay usable in the smallest window, got " .. board.width)
  MainFrame.Refresh()
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

  local cells = Client.Find(function(widget)
    return widget.kind == "Button" and widget.mark ~= nil and widget:IsVisible()
  end)
  equal(9, #cells)
  assert(cells[1].width > 0, "cells should have been laid out")
  cells[5]:Fire("OnClick")
  equal("5", logOf(first, match.id))
  equal("X", cells[5].mark.text)
  cells[1]:Fire("OnClick")
  equal("5", logOf(first, match.id), "not on the opponent's turn")
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

-----------------------------
-- Runner
-----------------------------

local names = {}
for name in pairs(tests) do
  names[#names + 1] = name
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
