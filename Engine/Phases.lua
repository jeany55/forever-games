--------------------------
--  Phases
--------------------------
-- What a game for a room (Engine/Rooms.lua) is played to: a clock. Party games go round the same
-- few steps, each for so long: a question is put and answered and the answer is shown; something
-- is picked, drawn and guessed at. Whoever is quickest about it gets the most. This keeps which
-- step a room is at, since when and until when, on every member's client the same, and works out
-- what being quick is worth.
--
-- A phase is a name of the game's own ("ask", "reveal", "draw") with the moment it began and the
-- moment it is due to end, both by the local client's clock: `phase`, `since` and `due` in the
-- room's state. The host decides when one phase ends and the next begins and says so, the others
-- start theirs when they hear it. That is a little after the host did, which a game for a room
-- takes in its stride.
--
-- Somebody who comes in while a game is on is told the phase it is at as anybody was, with how
-- far into it the host is (Phases.Ago) or how long it has left (Phases.Left), so that their clock
-- runs out when everyone else's does.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class Phases
local Phases = {}
private.Phases = Phases

--- @class PhaseState
--- @field phase string
--- @field since number? When it began
--- @field due number? When it is up, nil for a phase that waits for something else

--- Goes on to a phase
--- @param state PhaseState The room's
--- @param phase string
--- @param now number
--- @param seconds number? How long it lasts, nil for as long as it takes
--- @param ago number? How long ago it really began, for somebody who is only being told now
function Phases.Begin(state, phase, now, seconds, ago)
  state.phase, state.since = phase, now - (ago or 0)
  state.due = seconds and state.since + seconds or nil
end

--- Moves when the phase is up, without going on to another: it is to wait so long from now, or
--- with nil for as long as it takes
--- @param state PhaseState
--- @param now number
--- @param seconds number?
function Phases.Until(state, now, seconds)
  state.due = seconds and now + seconds or nil
end

--- Whether the phase is up
--- @param state PhaseState
--- @param now number
--- @param grace number? Seconds it is given on top, for a message that is on its way
--- @return boolean
function Phases.Due(state, now, grace)
  return state.due ~= nil and now >= state.due + (grace or 0)
end

--- @param state PhaseState
--- @param now number
--- @return number? Seconds the phase has left, nil if it isn't timed
function Phases.Left(state, now)
  return state.due and math.max(0, state.due - now) or nil
end

--- How long the phase has been on, in whole seconds: what somebody who comes in late is told, so
--- that their clock runs out with everyone else's
--- @param state PhaseState
--- @param now number
--- @return number
function Phases.Ago(state, now)
  return math.max(0, math.floor(now - (state.since or now)))
end

--- What being right is worth, by how quick about it somebody was: the most at once, less and
--- less as the time goes, and the least on the last moment
--- @param taken number Seconds it took them
--- @param seconds number They had
--- @param most number
--- @param least number
--- @return number
function Phases.Points(taken, seconds, most, least)
  local share = math.min(1, math.max(0, taken / seconds))
  return math.floor(most - (most - least) * share + 0.5)
end

--- How many of those in the room are in a set: have answered, have guessed it
--- @param room Room
--- @param set table<number, any> By member number
--- @return number count, number of Everyone in the room
function Phases.Count(room, set)
  local count = 0
  for n in pairs(room.members) do
    count = count + (set[n] and 1 or 0)
  end
  return count, room.count
end

--- Everyone in the room, whoever has the most first and the first in the room among those who
--- have as much
--- @param room Room
--- @return RoomMember[]
function Phases.Standings(room)
  local members = room:Members()
  table.sort(members, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.n < b.n
  end)
  return members
end
