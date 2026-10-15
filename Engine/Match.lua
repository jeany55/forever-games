--------------------------
--  Match model
--------------------------
-- A match is an id, its players and an ordered log of entries. The game state is never stored,
-- it is always derived by replaying the log, which is what makes resyncing clients a matter of
-- exchanging the log entries one of them is missing.
--
-- That goes for games of chance as well: the dice are worked out from the match id and the moves
-- in the log (Engine/Random.lua), so replaying the log rolls them again the way they fell. The
-- day's challenge (Engine/Daily.lua) works them out from the date and the game instead, so that
-- everyone who plays it that day is dealt the same.
--
-- A log entry is a move string owned by the game, or one of the engine's own entries:
--   !s         everyone has accepted and the game begins. Only in matches of more than two,
--              where it is the first entry and nothing can be played before it. Two players
--              don't need it: there the game is on as soon as the one challenge is accepted
--   !r<seat>   the seat resigns. With more than two playing the others carry on without them,
--              until only one is left. In a game played together they carry on down to the last
--   !d<seat>   the seat offers a draw. Only on their own turn, and it stands until the opponent
--              answers it by moving, which turns it down. Only in matches of two
--   !a<seat>   the seat accepts the opponent's draw offer, on their own turn
-- Everything but a resignation is appended by the player whose turn it is (the start by whoever
-- set the match up), so the clients can't all be adding to the log at the same moment.
--
-- A game played together (GameDefinition.together) has no turns to say whose a move is, so there
-- the seat is written in front of it: "2cfk" is seat 2 playing "cfk". And there the clients do
-- add to the log at the same moment, which the session sorts out (Session:onMoveTogether).
--
-- A match of one is a game the player plays alone. Its log never leaves the client, which is
-- what lets a move be taken back: the log is cut short by an entry (Match.Truncate).
--
-- That goes for a race as well (Engine/Race.lua), where somebody else plays the same deal on
-- their own: each has a match of one with the same id, so the same chance, and nothing but how
-- each run went is sent.
--
-- So is a match against the computer, which plays every seat but the player's (`computers`, see
-- Engine/Computer.lua). Its moves are made on the player's client and go in the log like anyone
-- else's, and nothing about the match is ever sent: it is the player's own, the same as a game
-- for one.
--
-- The computer can also take some of the seats at a table of people. Every client knows which
-- seats are its, but only one of them plays those: the host's, for as long as the host is in the
-- game, and after that the first seat of whoever still is (Match.Driver). That is something the
-- log says, so all of them agree on it without talking about it. The computer's moves are sent
-- to the others like the moves of whoever plays them, and the computer doesn't play on among
-- itself: once every person has left the game it is over.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @alias MatchStatus
--- |"incoming" # Challenge received, not answered yet
--- |"outgoing" # Challenge sent, not answered yet
--- |"active"
--- |"finished"
--- |"declined"

--- @class Match
--- @field id string
--- @field game string Game id
--- @field gameVersion number
--- @field players string[] Full player names by seat
--- @field options table<string, any>? What the rules were set to where that isn't what the game does by default, by option id
--- @field me number The local player's seat
--- @field host number? Seat of whoever set the match up, in matches of more than two
--- @field log string[]
--- @field status MatchStatus
--- @field seen table<number, number> How many log entries each of the others is known to have, by seat
--- @field accepted table<number, boolean>? Who has accepted so far, kept by the host until the game begins
--- @field gone table<number, boolean>? Players who no longer have the match and aren't sent anything
--- @field created number
--- @field updated number
--- @field unread boolean? Something happened that the player hasn't looked at yet
--- @field declineReason string?
--- @field hidden boolean? Kept only to answer repeated messages, not shown to the player
--- @field played number? Seconds a game for one has been played for, where the game is timed
--- @field bests table<string, boolean>? The records this match set, by key (GameRecord)
--- @field computers table<number, string>? The seats the computer plays, with the level it plays them at. Its name in `players` is Match.COMPUTER. At a table of people as well as alone against it
--- @field tallied boolean? A game against the computer that is over and counted, see Session:Tally
--- @field beaten boolean? A game against the computer the player was put out of by the computer, which is over for them (GameDefinition.beaten)
--- @field daily string? The day whose challenge this is, "2026-10-14" (Engine/Daily.lua). A game for one
--- @field score number|false? A day's challenge that is over: what it came to, false for nothing
--- @field shown number? How many log entries in the player has seen the game on screen: what came after is what they missed (Session:Missed)
--- @field race MatchRace? A game for one that is a race against somebody playing the same deal (Engine/Race.lua): both matches go by the same id, which is what deals it

--- @class MatchResult
--- @field winner number Seat of the winner, 0 for a draw
--- @field reason "win"|"draw"|"resign"
--- @field detail string? How the game says it ended, e.g. "checkmate"
--- @field all boolean? Nobody won over anybody: the players were on the same side and made it together

--- What a log entry did. Games add their own fields to moves, see GameDefinition.apply.
--- @class MatchEvent
--- @field kind "move"|"resign"|"offer"|"accept"|"start"
--- @field seat number Who did it
--- @field notation string? How to write a move down for the players, e.g. "Nxf3+"

--- @class Replay
--- @field state table
--- @field result MatchResult?
--- @field events MatchEvent[] One per log entry applied
--- @field offer number? Seat with a draw offer standing
--- @field draws boolean Whether draws can be offered in this match
--- @field seats number How many are playing
--- @field host number? Seat that starts the game, see Match.host
--- @field started boolean Whether the game has begun
--- @field out table<number, boolean> Seats that resigned
--- @field left number How many are still playing
--- @field chance number What dice and shuffles follow from, see Engine/Random.lua
--- @field people number How many seats people play that are still in the game, where the computer plays some of the others

--- @class MatchModel
local Match = {}
private.Match = Match

local ENGINE_ENTRY = "^!([rda])(%d)$"
Match.START = "!s"
-- What the computer's seats are down as in `players`. No player can be called that
Match.COMPUTER = "*"

-- Replayed states, kept out of the match table so they don't end up in SavedVariables
local cache = setmetatable({}, { __mode = "k" })
-- Replays of earlier positions, for looking back through a game. One per match, moved forward
-- an entry at a time while the player steps through.
local cursors = setmetatable({}, { __mode = "k" })
-- Copies of the replay every so many entries, taken as the cursor goes by them, so that going
-- back starts from the nearest one before rather than from the beginning. By match, then by how
-- many entries in
local snapshots = setmetatable({}, { __mode = "k" })
-- How many entries apart they are: a copy of a position costs about what a few moves do, a long
-- game of Words or Wormcraft takes hundreds of them to play out again
local SNAPSHOT_EVERY = 8

--- @param seat number
--- @return string
function Match.ResignEntry(seat)
  return "!r" .. seat
end

--- @param seat number
--- @return string
function Match.DrawOfferEntry(seat)
  return "!d" .. seat
end

--- @param seat number
--- @return string
function Match.DrawAcceptEntry(seat)
  return "!a" .. seat
end

--- @param entry string
--- @return boolean
function Match.IsResignation(entry)
  return entry:match("^!r%d$") ~= nil
end

--- @param entry string
--- @return boolean
function Match.IsDrawOffer(entry)
  return entry:sub(1, 2) == "!d"
end

--- Brings a match saved by an earlier version up to date
--- @param match Match
function Match.Upgrade(match)
  if not match.seen then
    -- There used to be only ever one other player
    match.seen = { [match.me == 1 and 2 or 1] = match.peerSeen or 0 }
    match.peerSeen = nil
  end
end

--- Whether the computer plays a seat
--- @param match Match
--- @param seat number
--- @return boolean
function Match.IsComputer(match, seat)
  return match.computers ~= nil and match.computers[seat] ~= nil
end

--- How well the computer plays a match: at the hardest of the levels it plays its seats at
--- @param match Match
--- @return string? nil if it doesn't play in it
function Match.Level(match)
  local hardest, rank = nil, 0
  for _, level in pairs(match.computers or {}) do
    for index, known in ipairs(private.Computer.LEVELS) do
      if known == level and index > rank then
        hardest, rank = level, index
      end
    end
  end
  return hardest
end

--- How well the computer plays each seat it takes, in seat order
--- @param match Match
--- @return string[]
function Match.Levels(match)
  local levels = {}
  for seat = 1, #match.players do
    levels[#levels + 1] = match.computers and match.computers[seat] or nil
  end
  return levels
end

--- Whether the computer plays any seat of the match: alone against the player, or at a table of
--- people
--- @param match Match
--- @return boolean
function Match.HasComputers(match)
  return match.computers ~= nil and next(match.computers) ~= nil
end

--- Whether the match is the player's against the computer and nobody else
--- @param match Match
--- @return boolean
function Match.IsComputerMatch(match)
  return Match.HasComputers(match) and Match.IsLocal(match)
end

--- Whether the match is the local player's alone, with nobody else to tell about it: a game for
--- one, or against the computer
--- @param match Match
--- @return boolean
function Match.IsLocal(match)
  for seat = 1, #match.players do
    if seat ~= match.me and not Match.IsComputer(match, seat) then
      return false
    end
  end
  return true
end

--- Seats of everyone but the local player, in seat order
--- @param match Match
--- @return number[]
function Match.Others(match)
  local seats = {}
  for seat = 1, #match.players do
    if seat ~= match.me then
      seats[#seats + 1] = seat
    end
  end
  return seats
end

--- @param match Match
--- @param name string Full player name
--- @return number? seat nil if they aren't playing
function Match.SeatOf(match, name)
  -- Not every seat is known while a challenge is still coming in
  for seat, player in pairs(match.players) do
    if player == name then
      return seat
    end
  end
  return nil
end

--- Seat of whoever the challenge came from
--- @param match Match
--- @return number
function Match.Inviter(match)
  if match.host then
    return match.host
  end
  local other = match.me == 1 and 2 or 1
  return match.status == "incoming" and other or match.me
end

--- The seat whose client plays the computer's seats: the host's while the host is in the game,
--- and the first of the people still in it after that. Every client works it out from the log,
--- so they all come to the same one
--- @param match Match
--- @return number? nil if the computer plays no seat, or no person is left in the game
function Match.Driver(match)
  if not Match.HasComputers(match) then
    return nil
  end
  local host = match.host or match.me
  if not Match.IsOut(match, host) then
    return host
  end
  for seat = 1, #match.players do
    if not Match.IsComputer(match, seat) and not Match.IsOut(match, seat) then
      return seat
    end
  end
  return nil
end

--- Applies one entry to a replayed state. Returns false with an error code if the entry is illegal.
--- @param game GameDefinition
--- @param replay Replay
--- @param entry string
--- @return boolean, string?
local function step(game, replay, entry)
  if replay.result then
    return false, "finished"
  end

  if entry == Match.START then
    if replay.started then
      return false, "invalid_move"
    end
    replay.started = true
    replay.events[#replay.events + 1] = { kind = "start", seat = replay.host }
    return true
  end
  if not replay.started then
    return false, "not_started"
  end

  local kind, who = entry:match(ENGINE_ENTRY)
  if kind then
    local seat = tonumber(who)
    if seat < 1 or seat > replay.seats or replay.out[seat] then
      return false, "invalid_move"
    end
    if kind == "r" then
      replay.out[seat] = true
      replay.left = replay.left - 1
      replay.events[#replay.events + 1] = { kind = "resign", seat = seat }
      if replay.people and not replay.computers[seat] then
        replay.people = replay.people - 1
        if replay.people == 0 and replay.left > 1 then
          -- The computer doesn't play on among itself: nobody won a game everyone walked out of
          replay.result = { winner = 0, reason = "resign" }
          return true
        end
      end
      -- A game played together isn't won by being the last one in it: whoever is left plays on
      if replay.left > 1 or (game.together and replay.left > 0) then
        if game.drop then
          game.drop(replay.state, seat)
        end
        local result = game.result(replay.state)
        if result then
          replay.result = { winner = result.winner, reason = result.winner == 0 and "draw" or "win", detail = result.detail, all = result.all }
        end
        return true
      end
      -- Alone, there is nobody left to have won
      replay.result = { winner = 0, reason = "resign" }
      for last = 1, replay.seats do
        if not replay.out[last] then
          replay.result.winner = last
        end
      end
      return true
    end

    if not replay.draws or game.turn(replay.state) ~= seat then
      return false, "invalid_move"
    end
    if kind == "d" then
      if replay.offer then
        return false, "invalid_move"
      end
      replay.offer = seat
      replay.events[#replay.events + 1] = { kind = "offer", seat = seat }
    else
      if not replay.offer or replay.offer == seat then
        return false, "invalid_move"
      end
      replay.result = { winner = 0, reason = "draw", detail = "agreement" }
      replay.events[#replay.events + 1] = { kind = "accept", seat = seat }
    end
    return true
  end

  if not private.Codec.IsSafeField(entry) or entry:sub(1, 1) == "!" then
    return false, "invalid_move"
  end

  local seat, move
  if game.together then
    seat, move = tonumber(entry:sub(1, 1)), entry:sub(2)
    if not seat or seat < 1 or seat > replay.seats or move == "" then
      return false, "invalid_move"
    end
  else
    seat, move = game.turn(replay.state), entry
  end
  if replay.out[seat] then
    return false, "invalid_move"
  end
  local ok, err = game.validate(replay.state, seat, move)
  if not ok then
    return false, err or "invalid_move"
  end

  -- Every move stirs what the dice come from, the one being made included
  replay.chance = private.Random.Stir(replay.chance, entry)
  local event = game.apply(replay.state, seat, move, private.Random.New(replay.chance)) or {}
  event.kind, event.seat = "move", seat
  replay.events[#replay.events + 1] = event
  if replay.offer and replay.offer ~= seat then
    -- Playing on is how a draw offer is turned down
    replay.offer = nil
  end

  local result = game.result(replay.state)
  if result then
    replay.result = { winner = result.winner, reason = result.winner == 0 and "draw" or "win", detail = result.detail, all = result.all }
  end
  return true
end

--- @param match Match
--- @param game GameDefinition
--- @return Replay
local function newReplay(match, game)
  local seats = #match.players
  local chance = private.Random.Seed(match.daily and private.Daily.Seed(match.game, match.daily) or match.id)
  local people = nil
  if Match.HasComputers(match) then
    people = seats
    for _ in pairs(match.computers) do
      people = people - 1
    end
  end
  return {
    state = game.newState(seats, private.Random.New(chance), private.Games.Rules(game.options, match.options)),
    chance = chance,
    events = {},
    -- A match started before the game learned about draws is played out the way it started, the
    -- opponent may still be on the version that doesn't know them
    draws = game.draws == true and not game.together and match.gameVersion == game.version and seats == 2,
    seats = seats,
    host = match.host,
    -- Only a crowd has to be gathered first
    started = seats <= 2,
    out = {},
    left = seats,
    people = people,
    computers = match.computers or {},
  }
end

--- Replays the log. Entries that fail validation (a corrupted save) end the replay early.
--- @param match Match
--- @return Replay?
local function replayOf(match)
  local cached = cache[match]
  if cached then
    return cached
  end

  local game = private.Games.Get(match.game)
  if not game then
    return nil
  end

  local replay = newReplay(match, game)
  for index, entry in ipairs(match.log) do
    if not step(game, replay, entry) then
      for i = #match.log, index, -1 do
        match.log[i] = nil
      end
      break
    end
  end

  cache[match] = replay
  return replay
end

--- @param match Match
--- @return table? state nil if the game isn't installed
function Match.State(match)
  local replay = replayOf(match)
  return replay and replay.state
end

--- The position as the local player may see it. A game with something to hide (the cards in
--- another player's hand) says what that leaves, see GameDefinition.visible. Once the game is
--- over there are no secrets left and everyone sees everything.
--- @param match Match
--- @param count number? How many log entries in, the game as it stands if left out
--- @return table? state nil if the game isn't installed
function Match.Visible(match, count)
  local game = private.Games.Get(match.game)
  local state = Match.StateAt(match, count or #match.log)
  if not state or not game.visible or Match.Result(match) then
    return state
  end
  return game.visible(state, match.me)
end

--- @param match Match
--- @return MatchResult?
function Match.Result(match)
  local replay = replayOf(match)
  return replay and replay.result
end

--- A replay that can be played on without touching the one it was copied from. What it did on
--- the way there is left behind: a cursor is only ever asked where it got to
--- @param replay Replay
--- @return Replay
local function copyReplay(replay)
  local copy = private.Tables.Shallow(replay)
  copy.state, copy.out, copy.events = private.Tables.Copy(replay.state), private.Tables.Copy(replay.out), {}
  return copy
end

--- The position after the first `count` log entries, for looking back through a game. The table is
--- reused by the next call for the same match, so draw from it and don't keep it. Going forward
--- from the last position asked for plays the entries in between, going back starts again from
--- the nearest snapshot before it
--- @param match Match
--- @param count number
--- @return table? state nil if the game isn't installed
function Match.StateAt(match, count)
  if count >= #match.log then
    return Match.State(match)
  end
  local game = private.Games.Get(match.game)
  if not game then
    return nil
  end

  local kept = snapshots[match] or {}
  snapshots[match] = kept
  local cursor = cursors[match]
  if not cursor or cursor.count > count then
    local nearest = count - count % SNAPSHOT_EVERY
    while nearest > 0 and not kept[nearest] do
      nearest = nearest - SNAPSHOT_EVERY
    end
    if nearest > 0 then
      cursor = { count = nearest, replay = copyReplay(kept[nearest]) }
    else
      cursor = { count = 0, replay = newReplay(match, game) }
    end
    cursors[match] = cursor
  end
  while cursor.count < count do
    cursor.count = cursor.count + 1
    step(game, cursor.replay, match.log[cursor.count])
    if cursor.count % SNAPSHOT_EVERY == 0 and not kept[cursor.count] then
      kept[cursor.count] = copyReplay(cursor.replay)
    end
  end
  return cursor.replay.state
end

--- What each log entry did, in log order
--- @param match Match
--- @return MatchEvent[]
function Match.Events(match)
  local replay = replayOf(match)
  return replay and replay.events or {}
end

--- Seat whose draw offer is waiting for an answer
--- @param match Match
--- @return number?
function Match.DrawOffer(match)
  local replay = replayOf(match)
  if not replay or replay.result or match.status ~= "active" then
    return nil
  end
  return replay.offer
end

--- Whether the local player could offer a draw right now
--- @param match Match
--- @return boolean
function Match.CanOfferDraw(match)
  local replay = replayOf(match)
  return replay ~= nil and replay.draws and not replay.offer and Match.IsMyTurn(match)
end

--- Whether there is a draw offer the local player could accept right now
--- @param match Match
--- @return boolean
function Match.CanAcceptDraw(match)
  local offer = Match.DrawOffer(match)
  return offer ~= nil and offer ~= match.me and Match.IsMyTurn(match)
end

--- Whether the local player is the only one playing
--- @param match Match
--- @return boolean
function Match.IsSolo(match)
  return #match.players == 1
end

--- Whether the game has begun. A match of more than two is active for those who accepted it
--- before everyone has, with nothing to play yet
--- @param match Match
--- @return boolean
function Match.Started(match)
  if #match.players <= 2 then
    return true
  end
  local replay = replayOf(match)
  return replay ~= nil and replay.started
end

--- Whether a player resigned
--- @param match Match
--- @param seat number
--- @return boolean
function Match.IsOut(match, seat)
  local replay = replayOf(match)
  return replay ~= nil and replay.out[seat] == true
end

--- Whether the match is of a game without turns, where everyone moves whenever they like
--- @param match Match
--- @return boolean
function Match.IsTogether(match)
  local game = private.Games.Get(match.game)
  return game ~= nil and game.together == true
end

--- Seat that moves next, nil once the game is over and in a game played together, where it is
--- nobody's turn in particular
--- @param match Match
--- @return number?
function Match.Turn(match)
  local replay = replayOf(match)
  if not replay or replay.result or match.status ~= "active" or not replay.started then
    return nil
  end
  local game = private.Games.Get(match.game)
  if game.together then
    return nil
  end
  return game.turn(replay.state)
end

--- @param match Match
--- @return boolean
function Match.IsMyTurn(match)
  return Match.Turn(match) == match.me
end

--- Whether the local player may move right now: on their turn, and at any time in a game played
--- together
--- @param match Match
--- @return boolean
function Match.CanMove(match)
  if not Match.IsTogether(match) then
    return Match.IsMyTurn(match)
  end
  local replay = replayOf(match)
  return match.status == "active" and replay.started and not replay.result and not replay.out[match.me]
end

--- How a move of the local player is written in the log
--- @param match Match
--- @param move string
--- @return string
function Match.MoveEntry(match, move)
  return Match.IsTogether(match) and match.me .. move or move
end

--- A number that stands for the first `count` entries of the log: two logs that give the same one
--- begin the same way. How the players of a game played together find out that they don't
--- @param match Match
--- @param count number
--- @return number
function Match.Digest(match, count)
  local digest = private.Random.Seed(match.id)
  for index = 1, count do
    digest = private.Random.Stir(digest, match.log[index])
  end
  return digest
end

--- Validates an entry against the current state and appends it to the log
--- @param match Match
--- @param entry string
--- @return boolean, string?
function Match.Append(match, entry)
  local replay = replayOf(match)
  if not replay then
    return false, "unknown_game"
  end

  local ok, err = step(private.Games.Get(match.game), replay, entry)
  if not ok then
    -- A rejected step can't have touched the state, games validate before applying
    return false, err
  end

  match.log[#match.log + 1] = entry
  if replay.result then
    match.status = "finished"
  end
  return true
end

--- Drops every log entry after the first `length`
--- @param match Match
--- @param length number
function Match.Truncate(match, length)
  for i = #match.log, length + 1, -1 do
    match.log[i] = nil
  end
  cache[match] = nil
  cursors[match] = nil
  snapshots[match] = nil
  if match.status == "finished" and not Match.Result(match) then
    match.status = "active"
  end
end
