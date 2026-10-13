--------------------------
--  Match model
--------------------------
-- A match is an id, two players and an ordered log of entries. The game state is never stored,
-- it is always derived by replaying the log, which is what makes resyncing two clients a matter
-- of exchanging the log entries one of them is missing.
--
-- A log entry is a move string owned by the game, or one of the engine's own entries:
--   !r<seat>   the seat resigns
--   !d<seat>   the seat offers a draw. Only on their own turn, and it stands until the opponent
--              answers it by moving, which turns it down
--   !a<seat>   the seat accepts the opponent's draw offer, on their own turn
-- Everything but a resignation is appended by the player whose turn it is, so the two clients
-- can't both be adding to the log at the same moment.

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
--- @field log string[]
--- @field status MatchStatus
--- @field peerSeen number How many log entries the opponent is known to have
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
--- @field kind "move"|"resign"|"offer"|"accept"
--- @field seat number Who did it
--- @field notation string? How to write a move down for the players, e.g. "Nxf3+"

--- @class Replay
--- @field state table
--- @field result MatchResult?
--- @field events MatchEvent[] One per log entry applied
--- @field offer number? Seat with a draw offer standing
--- @field draws boolean Whether draws can be offered in this match

--- @class MatchModel
local Match = {}
private.Match = Match

local ENGINE_ENTRY = "^!([rda])([12])$"

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

--- @param match Match
--- @return number
function Match.OpponentSeat(match)
  return match.me == 1 and 2 or 1
end

--- @param match Match
--- @return string
function Match.Opponent(match)
  return match.players[Match.OpponentSeat(match)]
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

  local kind, who = entry:match(ENGINE_ENTRY)
  if kind then
    local seat = tonumber(who)
    if kind == "r" then
      replay.result = { winner = seat == 1 and 2 or 1, reason = "resign" }
      replay.events[#replay.events + 1] = { kind = "resign", seat = seat }
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
  local ok, err = game.validate(replay.state, seat, entry)
  if not ok then
    return false, err or "invalid_move"
  end

  local event = game.apply(replay.state, seat, entry) or {}
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
  -- A match started before the game learned about draws is played out the way it started, the
  -- opponent may still be on the version that doesn't know them
  return { state = game.newState(), events = {}, draws = game.draws == true and match.gameVersion == game.version }
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
  return Match.DrawOffer(match) == Match.OpponentSeat(match) and Match.IsMyTurn(match)
end

--- Seat that moves next, nil once the game is over
--- @param match Match
--- @return number?
function Match.Turn(match)
  local replay = replayOf(match)
  if not replay or replay.result or match.status ~= "active" then
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
