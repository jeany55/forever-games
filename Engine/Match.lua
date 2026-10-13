--------------------------
--  Match model
--------------------------
-- A match is an id, two players and an ordered log of entries. The game state is never stored,
-- it is always derived by replaying the log, which is what makes resyncing two clients a matter
-- of exchanging the log entries one of them is missing.
--
-- A log entry is either a move string owned by the game or "!r<seat>" for a resignation.

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

--- @class MatchModel
local Match = {}
private.Match = Match

local RESIGN = "^!r([12])$"

-- Replayed states, kept out of the match table so they don't end up in SavedVariables
local cache = setmetatable({}, { __mode = "k" })

--- @param seat number
--- @return string
function Match.ResignEntry(seat)
  return "!r" .. seat
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
--- @param replay { state: table, result: MatchResult? }
--- @param entry string
--- @return boolean, string?
local function step(game, replay, entry)
  if replay.result then
    return false, "finished"
  end

  local resigned = tonumber(entry:match(RESIGN))
  if resigned then
    replay.result = { winner = resigned == 1 and 2 or 1, reason = "resign" }
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

  game.apply(replay.state, seat, entry)
  local result = game.result(replay.state)
  if result then
    replay.result = { winner = result.winner, reason = result.winner == 0 and "draw" or "win", detail = result.detail }
  end
  return true
end

--- Replays the log. Entries that fail validation (a corrupted save) end the replay early.
--- @param match Match
--- @return { state: table, result: MatchResult? }?
local function replayOf(match)
  local cached = cache[match]
  if cached then
    return cached
  end

  local game = private.Games.Get(match.game)
  if not game then
    return nil
  end

  local replay = { state = game.newState() }
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
  if match.status == "finished" and not Match.Result(match) then
    match.status = "active"
  end
end
