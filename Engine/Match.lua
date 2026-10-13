--------------------------
--  Match model
--------------------------
-- A match is an id, its players and an ordered log of entries. The game state is never stored,
-- it is always derived by replaying the log, which is what makes resyncing clients a matter of
-- exchanging the log entries one of them is missing.
--
-- That goes for games of chance as well: the dice are worked out from the match id and the moves
-- in the log (Engine/Random.lua), so replaying the log rolls them again the way they fell.
--
-- A log entry is a move string owned by the game, or one of the engine's own entries:
--   !s         everyone has accepted and the game begins. Only in matches of more than two,
--              where it is the first entry and nothing can be played before it. Two players
--              don't need it: there the game is on as soon as the one challenge is accepted
--   !r<seat>   the seat resigns. With more than two playing the others carry on without them,
--              until only one is left
--   !d<seat>   the seat offers a draw. Only on their own turn, and it stands until the opponent
--              answers it by moving, which turns it down. Only in matches of two
--   !a<seat>   the seat accepts the opponent's draw offer, on their own turn
-- Everything but a resignation is appended by the player whose turn it is (the start by whoever
-- set the match up), so the clients can't all be adding to the log at the same moment.

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

--- @class MatchResult
--- @field winner number Seat of the winner, 0 for a draw
--- @field reason "win"|"draw"|"resign"
--- @field detail string? How the game says it ended, e.g. "checkmate"

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

--- @class MatchModel
local Match = {}
private.Match = Match

local ENGINE_ENTRY = "^!([rda])(%d)$"
Match.START = "!s"

-- Replayed states, kept out of the match table so they don't end up in SavedVariables
local cache = setmetatable({}, { __mode = "k" })
-- Replays of earlier positions, for looking back through a game. One per match, moved forward
-- an entry at a time while the player steps through.
local cursors = setmetatable({}, { __mode = "k" })

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
      if replay.left > 1 then
        game.drop(replay.state, seat)
        local result = game.result(replay.state)
        if result then
          replay.result = { winner = result.winner, reason = result.winner == 0 and "draw" or "win", detail = result.detail }
        end
        return true
      end
      for last = 1, replay.seats do
        if not replay.out[last] then
          replay.result = { winner = last, reason = "resign" }
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

  local seat = game.turn(replay.state)
  if replay.out[seat] then
    return false, "invalid_move"
  end
  local ok, err = game.validate(replay.state, seat, entry)
  if not ok then
    return false, err or "invalid_move"
  end

  -- Every move stirs what the dice come from, the one being made included
  replay.chance = private.Random.Stir(replay.chance, entry)
  local event = game.apply(replay.state, seat, entry, private.Random.New(replay.chance)) or {}
  event.kind, event.seat = "move", seat
  replay.events[#replay.events + 1] = event
  if replay.offer and replay.offer ~= seat then
    -- Playing on is how a draw offer is turned down
    replay.offer = nil
  end

  local result = game.result(replay.state)
  if result then
    replay.result = { winner = result.winner, reason = result.winner == 0 and "draw" or "win", detail = result.detail }
  end
  return true
end

--- @param match Match
--- @param game GameDefinition
--- @return Replay
local function newReplay(match, game)
  local seats = #match.players
  local chance = private.Random.Seed(match.id)
  return {
    state = game.newState(seats, private.Random.New(chance)),
    chance = chance,
    events = {},
    -- A match started before the game learned about draws is played out the way it started, the
    -- opponent may still be on the version that doesn't know them
    draws = game.draws == true and match.gameVersion == game.version and seats == 2,
    seats = seats,
    host = match.host,
    started = seats == 2,
    out = {},
    left = seats,
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

--- The position after the first `count` log entries, for looking back through a game. The table is
--- reused by the next call for the same match, so draw from it and don't keep it.
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

  local cursor = cursors[match]
  if not cursor or cursor.count > count then
    cursor = { count = 0, replay = newReplay(match, game) }
    cursors[match] = cursor
  end
  while cursor.count < count do
    cursor.count = cursor.count + 1
    step(game, cursor.replay, match.log[cursor.count])
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

--- Whether the game has begun. A match of more than two is active for those who accepted it
--- before everyone has, with nothing to play yet
--- @param match Match
--- @return boolean
function Match.Started(match)
  if #match.players == 2 then
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

--- Seat that moves next, nil once the game is over
--- @param match Match
--- @return number?
function Match.Turn(match)
  local replay = replayOf(match)
  if not replay or replay.result or match.status ~= "active" or not replay.started then
    return nil
  end
  return private.Games.Get(match.game).turn(replay.state)
end

--- @param match Match
--- @return boolean
function Match.IsMyTurn(match)
  return Match.Turn(match) == match.me
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
  if match.status == "finished" and not Match.Result(match) then
    match.status = "active"
  end
end
