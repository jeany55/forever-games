-- Runs the engine tests from the terminal: lua Tests/RunTests.lua
--
-- The engine (Engine/ and the rules half of Games/) has no WoW dependencies, so instead of
-- mocking the game client each test builds a couple of simulated players and wires their
-- sessions together through a fake network that can drop messages or take a player offline.

local ADDON_NAME = "ForeverGames"
local ENGINE_FILES = { "Engine/Codec.lua", "Engine/Games.lua", "Engine/Match.lua", "Engine/Session.lua", "Engine/Presence.lua", "Games/TicTacToe.lua", "Games/Chess.lua" }

-- Rendering is never exercised here
STANDARD_TEXT_FONT = "font"

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
