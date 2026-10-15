--------------------------
--  Race
--------------------------
-- A game for one against somebody else: both play the same deal of it, each on their own and
-- whenever they like, and whoever took less time wins. Every game that is only ever played
-- alone, keeps the time it is played for (`clock`) and remembers the best the player ever did
-- (`record`) can be raced, and nothing more is asked of it. One that isn't to be says so (`raced`).
--
-- A race is a game for one like any other on each side, with what is known about the race kept
-- with it (MatchRace). Both matches go by the same id, the one the challenge came with, and a
-- match takes its chance from its id (Engine/Match.lua): so the two players are dealt the same
-- cards, the same field of mines, the same monastery, and the same moves turn up the same things
-- for both. Nothing of either game is sent while it is played, only how it went once it is over.
--
-- The time a run is raced for is the time the game keeps as its record for it (a GameRecord
-- that is `lower`), so a game that wouldn't count a run, as Sudoku doesn't one with a hint in
-- it, doesn't count it here either. A run that ended without such a record didn't finish, like a
-- death in Freedoom, and loses to any that did. Two that didn't finish are even.
--
-- The challenge (RAC, see Engine/Codec.lua) says which game and how its rules are set, and is
-- answered like any other with ACC or DEC. Whoever sent it can play at once. Then each player's
-- run is told to the other once it is over, as a short log of its own: first how long it took,
-- in hundredths of a second, or "-" for a run that didn't finish, and after that its ghost in
-- pieces. Between the two of them it travels on MOV, ACK and SYN, the way a match's log does,
-- and is offered again until the other has all of it (Engine/Session.lua).
--
-- A game can give the race a ghost (`ghost`): where the player was every so often as they
-- played, which goes to the rival with the time and is shown to them while they race it. The
-- engine knows nothing of what a sample says. The view takes them as it goes (RaceView.sample),
-- the engine keeps one for every `every` seconds of the clock, sends them with the time, and
-- hands the rival's view all of them once they have arrived (RaceView.ghost). A ghost is kept
-- short, so that it goes in a handful of messages under what the client lets an addon send:
-- what doesn't fit is left off its end.
--
-- Like the session, nothing in here touches the WoW API.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- What a game keeps of a run for the other racer to race against
--- @class GameGhost
--- @field every number Seconds of the clock between two samples of where the player is. Two or four a second is plenty
--- @field course (fun(options: table<string, any>): string[])? For a game whose every run by the same rules is the same course, whatever its deal (a map, not a field of mines): the log of a run by these rules that got to the end. The run that set the player's best can then be sent to somebody to race as it is (InviteSetup.best)

--- What a game for one that is raced against somebody keeps of the race. The match is the
--- player's own like any game for one: only its id, which the deal comes from, is the rival's too
--- @class MatchRace
--- @field rival string Full name of whoever the race is against
--- @field unanswered boolean? The local player challenged the rival, who hasn't answered yet. Their run isn't told until they do
--- @field declined string? The rival turned the race down, or no longer has it: why, the way a DEC says it, "declined" if it doesn't. The game goes on as a game for one
--- @field trail string? The ghost of the local player's run so far, its samples joined by "+", for a game that has one
--- @field samples number? How many samples there are in it
--- @field run string[]? What the rival is told about the local player's run once it is over: how long it took, then its ghost in pieces
--- @field told number How much of `run` the rival is known to have
--- @field heard string[] What the rival has told about their run so far, in order
--- @field length number? How long their run is in all, once they started telling it

--- What a view of a race is shown of it, see GameView.race
--- @class RaceView
--- @field rival string Who the race is against, as their name is shown
--- @field theirs number|false|nil How many seconds the rival's run took, false if it didn't finish, nil while that isn't known
--- @field ghost string[]? For a game with a ghost: the samples of the rival's run, one for every `every` seconds of it, once all of it has arrived
--- @field sample (fun(text: string): boolean)? For a game with a ghost: where the player is now, for the ghost of their own run. Letters, digits and "-", ".", "=" or "_", no longer than Race.SAMPLE_MOST. Call it as often as you like, one is kept for every `every` seconds of the clock

--- @class Race
local Race = {}
private.Race = Race

-- A run that didn't finish
local NONE = "-"
-- Longest a sample may be, and the most of a ghost that is kept, all of its samples together
Race.SAMPLE_MOST = 32
local GHOST_MOST = 4000
-- How much of a ghost goes in one message, see Codec.MAX_LENGTH
local PIECE = 200
-- The most entries a rival's run is taken to have: its time, and the pieces of a ghost that fit
local RUN_MOST = 1 + math.ceil(GHOST_MOST / (PIECE - Race.SAMPLE_MOST))
-- The slowest time that is taken, in hundredths of a second: more than anyone plays for
local SLOWEST = 999999999
local SAMPLE = "^[%w%-%.=_]+$"
local TIME = "^%d+$"

--- Whether a game can be raced
--- @param game GameDefinition?
--- @return boolean
function Race.Has(game)
  return game ~= nil and private.Games.IsSolo(game) and game.clock ~= nil and game.record ~= nil and game.raced ~= false
end

--- What a run of a game came to once it is over: the time the game keeps as its record for it
--- @param game GameDefinition
--- @param state table
--- @param seconds number It was played for
--- @param result MatchResult?
--- @return number|false|nil hundredths Of a second, false for a run that didn't finish, nil for one that isn't over
function Race.Time(game, state, seconds, result)
  if not result then
    return nil
  end
  for _, record in ipairs(game.record(state, seconds, result) or {}) do
    if record.lower and type(record.value) == "number" and record.value == record.value then
      return math.max(0, math.min(SLOWEST, math.floor(record.value * 100 + 0.5)))
    end
  end
  return false
end

--- Keeps where the player is now for the ghost of their run, if a sample is due: one for every
--- `every` seconds of the clock, the same one again for any that were passed over
--- @param race MatchRace
--- @param ghost GameGhost
--- @param seconds number How long the game has been played for
--- @param text string
--- @return boolean kept False for a sample that doesn't read right, and for one there is no more room for
function Race.Sample(race, ghost, seconds, text)
  if type(text) ~= "string" or #text > Race.SAMPLE_MOST or not text:match(SAMPLE) then
    return false
  end
  local due = math.floor(seconds / ghost.every) + 1
  while (race.samples or 0) < due do
    local trail = race.trail and (race.trail .. "+" .. text) or text
    if #trail > GHOST_MOST then
      return false
    end
    race.trail, race.samples = trail, (race.samples or 0) + 1
  end
  return true
end

--- What the rival is told about a run: how long it took, then its ghost in pieces that each go
--- in a message, cut between samples
--- @param time number|false Hundredths of a second, false for a run that didn't finish
--- @param trail string? Its ghost
--- @return string[]
function Race.Run(time, trail)
  local run = { time and tostring(time) or NONE }
  local rest = trail
  while rest and rest ~= "" do
    -- At the last "+" that leaves the piece short enough. There always is one, samples are short
    local cut = #rest > PIECE and rest:sub(1, PIECE + 1):match("^.*()%+") or #rest + 1
    run[#run + 1] = rest:sub(1, cut - 1)
    rest = rest:sub(cut + 1)
  end
  return run
end

--- Whether an entry of a rival's run reads right where it is
--- @param n number Which entry it is
--- @param total number How many the rival says there are
--- @param entry string
--- @return boolean
function Race.Takes(n, total, entry)
  if total < n or total > RUN_MOST then
    return false
  end
  if n == 1 then
    return entry == NONE or (entry:match(TIME) ~= nil and #entry <= #tostring(SLOWEST))
  end
  for sample in (entry .. "+"):gmatch("([^+]*)%+") do
    if #sample > Race.SAMPLE_MOST or not sample:match(SAMPLE) then
      return false
    end
  end
  return true
end

--- @param entry string?
--- @return number|false|nil
local function timeOf(entry)
  if entry == nil then
    return nil
  end
  return entry ~= NONE and tonumber(entry) or false
end

--- How long the local player's run took
--- @param race MatchRace
--- @return number|false|nil hundredths Of a second, false if it didn't finish, nil while it is on
function Race.Mine(race)
  return timeOf(race.run and race.run[1])
end

--- How long the rival's run took, as far as they have told
--- @param race MatchRace
--- @return number|false|nil hundredths Of a second, false if it didn't finish, nil while that isn't known
function Race.Theirs(race)
  return timeOf(race.heard[1])
end

-- The rival's ghost, read once from what they sent, by race
local ghosts = setmetatable({}, { __mode = "k" })

--- The samples of the rival's run, once all of it has arrived
--- @param race MatchRace
--- @return string[]? nil while some of it is still to come, and for a run without a ghost
function Race.Ghost(race)
  if not race.length or race.length < 2 or #race.heard < race.length then
    return nil
  end
  local ghost = ghosts[race]
  if not ghost then
    ghost = {}
    for sample in (table.concat(race.heard, "+", 2) .. "+"):gmatch("([^+]*)%+") do
      ghost[#ghost + 1] = sample
    end
    ghosts[race] = ghost
  end
  return ghost
end

--- Who won a race, once both runs are known: the quicker of two that finished, either one that
--- finished over one that didn't
--- @param race MatchRace
--- @return "won"|"lost"|"drawn"|nil nil while a run is still on, or not told yet
function Race.Outcome(race)
  local mine, theirs = Race.Mine(race), Race.Theirs(race)
  if mine == nil or theirs == nil then
    return nil
  end
  if mine == theirs then
    return "drawn"
  elseif theirs == false or (mine ~= false and mine < theirs) then
    return "won"
  end
  return "lost"
end

--- Whether there is nothing left for the two of them to tell each other: both runs are over and
--- each has all of the other's
--- @param race MatchRace
--- @return boolean
function Race.Settled(race)
  local told = race.run ~= nil and race.told >= #race.run
  return told and race.length ~= nil and #race.heard >= race.length
end

--- Whether the race is on between the two of them: taken up, and neither turned down nor gone
--- @param race MatchRace
--- @return boolean
function Race.On(race)
  return not race.unanswered and not race.declined
end
