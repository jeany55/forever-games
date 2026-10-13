-- Runs the engine tests from the terminal: lua Tests/RunTests.lua
--
-- The engine (Engine/ and the rules half of Games/) has no WoW dependencies, so instead of
-- mocking the game client each test builds a couple of simulated players and wires their
-- sessions together through a fake network that can drop messages or take a player offline.

local ADDON_NAME = "ForeverGames"
local ENGINE_FILES = {
  "Engine/Codec.lua",
  "Engine/Games.lua",
  "Engine/Match.lua",
  "Engine/Session.lua",
  "Engine/Presence.lua",
  "Games/TicTacToe.lua",
  "Games/Chess.lua",
  "Games/ConnectFour.lua",
  "Games/Reversi.lua",
  "Games/Checkers.lua",
}

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
-- More games
-----------------------------

--- Plays a line of any game from its starting position, asserting every move is legal
--- @param id string Game id
--- @param line string Space separated moves
--- @return table state, table game, table[] events What each move did
local function gameAfter(id, line)
  local game = loadEngine().Games.Get(id)
  local state, events = game.newState(), {}
  for move in line:gmatch("%S+") do
    local seat = game.turn(state)
    local ok, err = game.validate(state, seat, move)
    assert(ok, "Move " .. move .. " rejected: " .. tostring(err))
    events[#events + 1] = game.apply(state, seat, move)
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

function tests.WindowPlaysConnectFourByPointingAtAColumn()
  local world, red, yellow, id = gameOnScreen("connectfour")
  local board = shownBoard()
  assert(board.width >= 7 * 40, "the rack should make use of the window, got " .. board.width)
  equal(board.width / 7 * 6, board.height, "seven columns by six rows")

  -- Anywhere in the column will do, the disc falls to the bottom
  clickSquare(board, 3, 5, 7)
  equal("4", logOf(red, id))
  equal("IG_BACKPACK_CLOSE", Client.sounds[#Client.sounds])
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
  equal("IG_ABILITY_ICON_DROP", Client.sounds[#Client.sounds])
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
  equal("casual,strategy", table.concat(Games.Genres(), ","))

  -- The tests see the names of the strings rather than the strings, which is as good to search
  equal("chess", idsOf(Games.Search("chess")))
  equal("chess", idsOf(Games.Search("CHESS")), "in any case")
  equal("chess", idsOf(Games.Search("description chess")), "every word has to be there, wherever")
  equal("", idsOf(Games.Search("chess reversi")))
  equal("chess,reversi,checkers", idsOf(Games.Search("strategy")), "a genre's name finds its games")
  equal("tictactoe,connectfour", idsOf(Games.Search(nil, "casual")))
  equal("connectfour", idsOf(Games.Search("four", "casual")))
  equal("", idsOf(Games.Search("chess", "casual")))
  equal("", idsOf(Games.Search("%a+")), "what is typed is looked for as it is")

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
  private.Transport = {
    Normalize = function(name)
      return name ~= "" and name or nil
    end,
    DisplayName = function(name)
      return name
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

--- Clicks one of the buttons that narrow the games down to a genre
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
  openWizard(alice)
  local count = #alice.private.Games.List()
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

  -- By genre, on top of whatever is typed
  clickGenre("genre_casual")
  equal("tictactoe,connectfour", idsOf(offeredGames()))
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
