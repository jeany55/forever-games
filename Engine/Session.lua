--------------------------
--  Session
--------------------------
-- Owns every match the player is part of and the protocol that keeps the clients in agreement.
-- Nothing in here touches the WoW API, everything it needs is passed in through `env` so the
-- whole protocol can be exercised from the command line (see Tests/).
--
-- There is no server and no delivery guarantee: another player may be offline, in an instance
-- where addon messages are blocked, or may have lost their saved data in a crash. So nothing is
-- ever "sent and forgotten". Each match tracks how much of the log every other player is known
-- to have and anything they are missing is offered again until they acknowledge it.
--
-- Players are trusted to the extent friends playing board games are: every entry is validated
-- against the rules, but a longer valid log from another player is accepted as the truth.
--
-- A match of more than two works the same way between every pair of its players, with two
-- things on top. It is set up by a host, who challenges everyone and starts the game once they
-- have all accepted: until then there is nothing to play, and one of them declining calls it
-- off. And to keep the talk down a player only makes sure the others get what they don't have
-- yet as far as that player knows: an entry that arrives from someone is taken to be reaching
-- the rest from them as well. Whoever turns out to be missing something asks for it, from
-- everyone, when they log in or can be reached again.
--
-- A match that has been waiting on someone for a long time checks in with them now and then,
-- which is how it comes out that they never got the move, or no longer have the match at all.
--
-- A game played together has no turns, so its players do add to the log at the same moment, and
-- go on adding to it while they can't reach each other. Nothing of that is thrown away. Between
-- any two of them it is the log of the lower seat that stands: the other takes it an entry at a
-- time, and puts whatever it had there instead back on top, as far as that is still legal. And
-- since logs that part ways are nothing unusual there, the players don't take each other's word
-- for how much they have in common: every count comes with a number that stands for the log up
-- to there, and they start over from the beginning when those differ. See Session:onMoveTogether.
--
-- A game for one is a match like any other with nobody else in it: there is no challenge, it is
-- never anyone's turn but the player's, and nothing about it is ever sent. It doesn't count as
-- waiting on the player either, a game nobody else is in can wait for as long as it likes.
--
-- The day's challenge (Engine/Daily.lua) is a game for one like any other, dealt the way it is
-- dealt for everyone that day. It is played once a day and through to the end: nothing is taken
-- back, and it can't be thrown away while it is on. What it came to is worked out the moment it
-- is over, for the guild's board.
--
-- A game against the computer is the player's alone in the same way: nothing about it is sent,
-- and it waits on nobody. The computer's moves are made here, a little thinking at a time
-- whenever whoever shows the match asks for it (Session:Think), and go in the log like anyone's.
-- The player may take a move back, the computer's answer to it with it, where the game allows
-- that. How each game against it went is counted, by how well it played (Session:Tally).
--
-- The computer can take seats at a table of people too, for a game of more than two. The host
-- challenges the people and says which seats are the computer's and how well it plays them. Once
-- the game is on the host's client plays those seats (Match.Driver), whether or not the game is
-- on screen (Session:Drive), and sends the computer's moves to the others like its own. A game
-- like that is everybody's, and goes like any other game of people: nothing is taken back, and
-- it isn't counted with the games against the computer.
--
-- A game for two can also be left open to whoever wants it: the player links it in chat, and the
-- first one to click the link asks for it. Asking is as good as accepting, so the challenge that
-- comes back is on at once. Whoever asks too late, or for a game that was never open, is told so.
--
-- A game for one can be raced against somebody (Engine/Race.lua): a challenge to a game each of
-- them plays alone, with nobody's turn but their own. Whoever sends it plays at once, and whoever
-- takes it up whenever they like. Once a run is over it is told to the other, offered again the
-- way moves are until they have it all, and whoever comes back finds out how the other did.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class SessionEnv
--- @field me string Full name of the local player
--- @field matches table<string, Match> Persisted matches by id
--- @field send fun(target: string, text: string): boolean Returns false if the message could not be sent right now
--- @field now fun(): number
--- @field random fun(max: number): number
--- @field notify fun(event: string, match: Match)
--- @field records table<string, table<string, number>>? The best the player ever did at the games played alone, by game id and key. Persisted. Forgotten with the session if left out
--- @field ghosts table<string, table<string, string>>? For a game with a ghost (GameDefinition.ghost): the run that set each of those bests, its samples joined by "+", by game id and key. Persisted. Forgotten with the session if left out
--- @field offers table<string, Offer>? The games the player linked in chat that nobody took yet, by game id. Persisted. Forgotten with the session if left out
--- @field onRefused (fun(host: string, gameId: string, reason: string))? Called when a game the player asked for isn't to be had
--- @field takes (fun(sender: string): boolean)? Whether the player takes challenges from this player. From everyone if left out
--- @field clock (fun(): number)? Milliseconds from some time or other, for the computer to tell how long it has been thinking. Without it the computer thinks until it knows, however long that takes
--- @field versus table<string, table<string, VersusTally>>? How the player's games against the computer went, by game id and level. Persisted. Forgotten with the session if left out
--- @field log (fun(...: string))? Where to say that something went wrong that the player needn't be bothered with
--- @field today (fun(): string)? The date in UTC, "2026-10-14", for the day's challenge. Without it there is none
--- @field dailies table<string, string>? The last day the player took on each game's challenge, by game id. Persisted. Forgotten with the session if left out

--- How the games against the computer at one level went
--- @class VersusTally
--- @field won number
--- @field drawn number
--- @field lost number

--- A game that is open to whoever clicks its link first
--- @class Offer
--- @field options table<string, any>? How the rules are set, nil for the usual way
--- @field seat number? The seat the player asked for, nil to leave it to chance
--- @field expires number

--- @class Session
--- @field env SessionEnv
--- @field peers table<string, { attempts: number, nextTry: number }> Retry backoff per player
--- @field pendingSync table<string, table<number, boolean>> Seats that still have to be told our log length, by match id
--- @field offered table<string, table<number, number>> Highest log entry already on its way to each seat, by match id
--- @field gathering table<string, table> Challenges that have yet to say who everyone playing is, by match id
--- @field checkedIn table<string, number> When the player a match is waiting on was last asked how much of it they have, by match id
--- @field mended table<string, table<number, number>> When a log that had parted ways with a seat's without it showing was last set right from the start, by match id
--- @field asked table<string, { host: string, game: string, expires: number }> Games the player asked for by clicking a link and hasn't heard about yet, by the id they gave them
--- @field thinking table<string, { ply: number, thinker: Thinker }> What the computer is deciding on in each game against it, by match id, and how long the log was when it started
--- @field waits table<string, { ply: number, waited: number }> For how many seconds the computer has seemed to think about its move, in each game of people it plays seats in off screen, by match id
--- @field pendingRace table<string, boolean> Races whose rival still has to be told how much of their run there is here, by match id
--- @field runOffered table<string, number> How far into the local player's run of a race what is on its way to the rival goes, by match id
local Session = {}
Session.__index = Session
private.Session = Session

local Codec = private.Codec
local Computer = private.Computer
local Daily = private.Daily
local Games = private.Games
local Match = private.Match
local Race = private.Race
local Random = private.Random

local RETRY_BASE = 30
local RETRY_MAX = 600
-- Entries offered per attempt, keeps a long resync under the addon message throttle
local PUSH_LIMIT = 8
local MAX_OPEN_PER_PEER = 5
-- How long a match waits on someone before asking them whether they have everything
local CHECK_IN = 60 * 60
local DAY = 24 * 60 * 60
local KEEP_FINISHED = 30 * DAY
local KEEP_DECLINED = 7 * DAY
-- How long a game linked in chat stays open to whoever clicks the link
local OFFER_LIFETIME = 60 * 60
-- How long a challenge that was asked for is accepted without asking the player again
local ASK_WINDOW = 60

--- @param env SessionEnv
--- @return Session
function Session.New(env)
  for _, match in pairs(env.matches) do
    Match.Upgrade(match)
  end
  env.records = env.records or {}
  env.ghosts = env.ghosts or {}
  env.offers = env.offers or {}
  env.versus = env.versus or {}
  env.dailies = env.dailies or {}
  return setmetatable({ env = env, peers = {}, pendingSync = {}, offered = {}, gathering = {}, checkedIn = {}, mended = {}, asked = {}, thinking = {}, waits = {}, pendingRace = {}, runOffered = {} }, Session)
end

-----------------------------
-- Helpers
-----------------------------

--- @param match Match
--- @param event string
--- @param unread boolean? Marks the match as having news the player hasn't seen
function Session:touch(match, event, unread)
  match.updated = self.env.now()
  if unread then
    match.unread = true
  end
  self.env.notify(event, match)
end

--- @param match Match
--- @param seat number Who to send to
--- @param type string
--- @param ... string|number
--- @return boolean
function Session:send(match, seat, type, ...)
  return self.env.send(match.players[seat], Codec.Encode(type, match.id, ...))
end

--- Tells a player how many log entries there are here, or how many of theirs. In a game played
--- together that comes with what the log is up to there, see Match.Digest
--- @param match Match
--- @param seat number
--- @param type "ACK"|"SYN"
--- @param count number
--- @return boolean
function Session:sendCount(match, seat, type, count)
  if Match.IsTogether(match) then
    return self:send(match, seat, type, count, Match.Digest(match, count))
  end
  return self:send(match, seat, type, count)
end

--- What to tell the player about an entry someone else, or the computer, just added
--- @param match Match
--- @param entry string
--- @return string
local function eventFor(match, entry)
  if match.status == "finished" then
    return "finished"
  end
  if entry == Match.START then
    return "started"
  end
  return Match.IsDrawOffer(entry) and "draw" or "moved"
end

--- Seats of the players who are sent what happens in a match
--- @param match Match
--- @return number[]
local function peersOf(match)
  local seats = {}
  for _, seat in ipairs(Match.Others(match)) do
    if not (match.gone and match.gone[seat]) and not Match.IsComputer(match, seat) then
      seats[#seats + 1] = seat
    end
  end
  return seats
end

--- The last entry a player is offered in one go, given how many they have. With more than two
--- playing the stretches end on fixed entries, which lets whoever receives them acknowledge a
--- whole stretch at once instead of every entry of it.
--- @param match Match
--- @param seen number
--- @return number
local function stretchEnd(match, seen)
  if #match.players == 2 then
    return seen + PUSH_LIMIT
  end
  return (math.floor(seen / PUSH_LIMIT) + 1) * PUSH_LIMIT
end

--- Offers a player the log entries they are missing. Entries already on their way are not
--- sent again, otherwise every acknowledgement during a long resync would repeat the rest of it.
--- @param match Match
--- @param seat number
--- @param restart boolean? Offer everything unacknowledged again, for retries
--- @return boolean sent False if a message could not be sent
function Session:pushLog(match, seat, restart)
  local offered = self.offered[match.id]
  if not offered then
    offered = {}
    self.offered[match.id] = offered
  end

  local seen = match.seen[seat] or 0
  local first = seen
  if not restart then
    first = math.max(first, offered[seat] or 0)
  end
  local last = math.min(#match.log, stretchEnd(match, seen))
  local together = Match.IsTogether(match)
  for n = first + 1, last do
    if not self:send(match, seat, "MOV", n, #match.log, match.log[n], together and Match.Digest(match, n - 1) or nil) then
      return false
    end
    offered[seat] = n
  end
  return true
end

--- Offers everyone what they are missing
--- @param match Match
function Session:pushAll(match)
  for _, seat in ipairs(peersOf(match)) do
    self:pushLog(match, seat)
  end
end

--- Challenges whoever sits in a seat. A match of more than two says who everyone is, in as many
--- messages as that takes.
--- @param match Match
--- @param seat number
--- @return boolean sent
function Session:sendInvite(match, seat)
  local type, fields = "INV", { match.game, match.gameVersion, match.me }
  local game = Games.Get(match.game)
  local options = {}
  options[#options + 1] = game and Games.EncodeOptions(game, match.options) or nil
  options[#options + 1] = Codec.EncodeComputers(match.computers)
  if #options > 0 then
    fields[#fields + 1] = table.concat(options, "+")
  end
  if #match.players == 2 then
    return self:send(match, seat, type, unpack(fields))
  end

  fields[#fields + 1], fields[#fields + 2] = #match.players, seat
  for other, name in ipairs(match.players) do
    -- The computer's seats were said with the rules
    if other ~= match.me and other ~= seat and not Match.IsComputer(match, other) then
      if #Codec.Encode(type, match.id, unpack(fields)) + #tostring(other) + #name + 2 > Codec.MAX_LENGTH then
        if not self:send(match, seat, type, unpack(fields)) then
          return false
        end
        type, fields = "WHO", {}
      end
      fields[#fields + 1], fields[#fields + 2] = other, name
    end
  end
  return self:send(match, seat, type, unpack(fields))
end

--- The players who are missing something only we can give them: a challenge they haven't
--- answered, or log entries
--- @param match Match
--- @return number[] seats
function Session:Behind(match)
  local seats = {}
  for _, seat in ipairs(peersOf(match)) do
    local behind
    if match.status == "outgoing" then
      behind = not (match.accepted and match.accepted[seat])
    else
      behind = (match.status == "active" or match.status == "finished") and (match.seen[seat] or 0) < #match.log
    end
    if behind then
      seats[#seats + 1] = seat
    end
  end
  return seats
end

--- Whether anyone is missing something only we can give them
--- @param match Match
--- @return boolean
function Session:IsPending(match)
  return #self:Behind(match) > 0
end

--- Whether the match is waiting on the local player
--- @param match Match
--- @return boolean
function Session:NeedsAttention(match)
  -- A race is the player's own game, but a challenge to one, and how the rival did, are news
  if match.race and not match.hidden then
    return match.status == "incoming" or match.unread == true
  end
  if match.hidden or Match.IsLocal(match) then
    return false
  end
  return match.status == "incoming" or match.unread == true or Match.IsMyTurn(match)
end

--- @return number
function Session:AttentionCount()
  local count = 0
  for _, match in pairs(self.env.matches) do
    if self:NeedsAttention(match) then
      count = count + 1
    end
  end
  return count
end

--- Matches to show, the ones waiting on the player first and then most recent first
--- @return Match[]
function Session:List()
  local list = {}
  for _, match in pairs(self.env.matches) do
    if not match.hidden then
      list[#list + 1] = match
    end
  end
  table.sort(list, function(a, b)
    local attentionA, attentionB = self:NeedsAttention(a), self:NeedsAttention(b)
    if attentionA ~= attentionB then
      return attentionA
    end
    if a.updated ~= b.updated then
      return a.updated > b.updated
    end
    return a.id < b.id
  end)
  return list
end

--- Everyone the player has a game with on their list, or had: whoever they played last first
--- @return { name: string, ago: number }[] Full names, and how many seconds ago their last game together was touched
function Session:Opponents()
  local now, last = self.env.now(), {}
  for _, match in pairs(self.env.matches) do
    if not match.hidden then
      for seat, name in pairs(match.players) do
        if seat ~= match.me and not Match.IsComputer(match, seat) then
          last[name] = math.max(last[name] or 0, match.updated or 0)
        end
      end
      if match.race then
        last[match.race.rival] = math.max(last[match.race.rival] or 0, match.updated or 0)
      end
    end
  end
  local list = {}
  for name, updated in pairs(last) do
    list[#list + 1] = { name = name, ago = math.max(0, now - updated) }
  end
  table.sort(list, function(a, b)
    if a.ago ~= b.ago then
      return a.ago < b.ago
    end
    return a.name < b.name
  end)
  return list
end

--- @param id string
--- @return Match?
function Session:Get(id)
  return self.env.matches[id]
end

-----------------------------
-- Local actions
-----------------------------

--- @param peer string
--- @return number
function Session:openMatchesWith(peer)
  local count = 0
  for _, match in pairs(self.env.matches) do
    local seat = Match.SeatOf(match, peer)
    local racing = match.race ~= nil and match.race.rival == peer and not match.race.declined
    if not match.hidden and match.status ~= "finished" and match.status ~= "declined" and ((seat and seat ~= match.me) or racing) then
      count = count + 1
    end
  end
  return count
end

--- Starts a game for one. There is nobody to ask, so it is on at once
--- @param game GameDefinition
--- @param options table<string, any>? How the rules are set, the usual way if left out
--- @param daily string? The day whose challenge it is
--- @param race MatchRace? The race it is a run in
--- @return Match
function Session:startSolo(game, options, daily, race)
  local match = self:newSolo(game, options)
  match.daily, match.race = daily, race
  self.env.matches[match.id] = match
  self.env.notify("changed", match)
  return match
end

--- A new game for one, not yet on the player's list
--- @param game GameDefinition
--- @param options table<string, any>? How the rules are set, the usual way if left out
--- @return Match
function Session:newSolo(game, options)
  local now = self.env.now()
  --- @type Match
  return {
    id = string.format("%x%06x", now, self.env.random(0xFFFFFF)),
    game = game.id,
    gameVersion = game.version,
    players = { self.env.me },
    options = Games.Chosen(game, options),
    me = 1,
    log = {},
    status = "active",
    seen = {},
    created = now,
    updated = now,
  }
end

-----------------------------
-- The day's challenge
-----------------------------

--- The date it is now, in UTC
--- @return string?
function Session:Today()
  return self.env.today and self.env.today()
end

--- The match of a day's challenge at a game, if the player still has it
--- @param gameId string
--- @param date string
--- @return Match?
function Session:DailyMatch(gameId, date)
  for _, match in pairs(self.env.matches) do
    if match.daily == date and match.game == gameId and not match.hidden then
      return match
    end
  end
  return nil
end

--- Whether the player has had their go at today's challenge at a game, whether or not they still
--- have the match
--- @param gameId string
--- @return boolean
function Session:PlayedToday(gameId)
  local today = self:Today()
  return today ~= nil and self.env.dailies[gameId] == today
end

--- Today's challenge at a game: the one the player is playing, or played and still has, or a new
--- one if they haven't had their go at it yet
--- @param gameId string
--- @return Match?, string? error
function Session:Daily(gameId)
  local game = Games.Get(gameId)
  local today = self:Today()
  if not Daily.Has(game) or not today then
    return nil, "no_daily"
  end
  local match = self:DailyMatch(gameId, today)
  if match then
    return match
  end
  if self.env.dailies[gameId] == today then
    return nil, "daily_played"
  end
  self.env.dailies[gameId] = today
  return self:startSolo(game, game.daily.rules, today)
end

--- Works out what a day's challenge came to once it is over, the once
--- @param match Match
function Session:scoreDaily(match)
  local game = Games.Get(match.game)
  local result = match.daily and match.score == nil and Daily.Has(game) and Match.Result(match)
  if not result then
    return
  end
  match.score = Daily.Score(game, Match.State(match), match.played or 0, result)
  self.env.notify("daily", match)
end

--- How well the computer is to play each of the seats it takes, as a game is set up
--- @param computer { levels: string[]?, level: string?, count: number? }
--- @return string[]? nil if that isn't something it can do
local function levelsOf(computer)
  -- A list of its own, to be seated from
  local levels = type(computer.levels) == "table" and { unpack(computer.levels) } or {}
  if #levels == 0 then
    local count = computer.count or 1
    if type(count) ~= "number" or count < 1 then
      return nil
    end
    levels = {}
    for index = 1, count do
      levels[index] = computer.level or Computer.DEFAULT_LEVEL
    end
  end
  for _, level in ipairs(levels) do
    if not Computer.IsLevel(level) then
      return nil
    end
  end
  return levels
end

--- Starts a game against the computer. It is on at once, there is nobody to ask
--- @param game GameDefinition
--- @param setup InviteSetup
--- @return Match?, string? error
function Session:startComputer(game, setup)
  if not Computer.Plays(game) then
    return nil, "no_computer"
  end
  local levels = levelsOf(setup.computer)
  if not levels or not Games.CanSeat(game, #levels + 1) then
    return nil, "player_count"
  end

  local now, seats = self.env.now(), #levels + 1
  local players, computers, mySeat = {}, {}, nil
  if seats == 2 and (setup.seat == 1 or setup.seat == 2) then
    mySeat = setup.seat
  else
    mySeat = self.env.random(seats)
  end
  for seat = 1, seats do
    players[seat] = seat == mySeat and self.env.me or Match.COMPUTER
    computers[seat] = seat ~= mySeat and table.remove(levels, 1) or nil
  end
  --- @type Match
  local match = {
    id = string.format("%x%06x", now, self.env.random(0xFFFFFF)),
    game = game.id,
    gameVersion = game.version,
    players = players,
    computers = computers,
    options = Games.Chosen(game, Games.ForPlayers(game, setup.options, seats)),
    me = mySeat,
    log = {},
    status = "active",
    seen = {},
    created = now,
    updated = now,
  }
  if seats > 2 then
    -- Everyone is there already: the game begins as it is set up
    match.host = mySeat
    assert(Match.Append(match, Match.START))
  end
  self.env.matches[match.id] = match
  self.env.notify("changed", match)
  return match
end

--- How a game is to be set up
--- @class InviteSetup
--- @field options table<string, any>? How the rules are set, by option id. The usual way if left out
--- @field seat number? For a game of two, the seat the local player takes. At random if left out
--- @field id string? The id of a match that was asked for, which it goes by
--- @field computer { levels: string[]?, level: string?, count: number? }? The computer plays too: how well it plays each seat it takes, or how well it plays (Computer.DEFAULT_LEVEL if left out) and in how many seats (one if left out). With nobody challenged the game is against it alone, and with people it sits at the table with them. Which seat is which is drawn like everyone's
--- @field best boolean? A race is challenged with the run that set the player's best by these rules, its time and its ghost, rather than with one they play for it (Session:BestToRace)

--- Challenges one player, or several to a game for more than two. With nobody to challenge it
--- starts a game for one, where the game is one, or against the computer, where that is asked for.
--- The computer can sit with the people challenged as well, in a game for more than two. One
--- player challenged to a game for one is challenged to race it, see Session:startRace
--- @param targets string|string[] Full player names
--- @param gameId string
--- @param setup InviteSetup?
--- @return Match?, string? error
function Session:Invite(targets, gameId, setup)
  setup = setup or {}
  local game = Games.Get(gameId)
  if not game then
    return nil, "unknown_game"
  end
  if type(targets) ~= "table" then
    targets = { targets }
  end
  if #targets == 0 and setup.computer then
    return self:startComputer(game, setup)
  end
  if #targets == 0 then
    if Games.CanSeat(game, 1) then
      return self:startSolo(game, setup.options)
    end
    return nil, "no_target"
  end
  local invited = {}
  for _, target in ipairs(targets) do
    -- Names travel between colons when there are more than two to tell about
    if type(target) ~= "string" or target == "" or target:find(":", 1, true) then
      return nil, "no_target"
    end
    if target == self.env.me then
      return nil, "self_invite"
    end
    if invited[target] then
      return nil, "same_player"
    end
    invited[target] = true
  end
  if #targets == 1 and not Games.CanSeat(game, 2) and Race.Has(game) and not setup.computer then
    return self:startRace(game, targets[1], setup)
  end
  local levels, computers = {}, 0
  if setup.computer then
    if not Computer.Plays(game) then
      return nil, "no_computer"
    end
    levels = levelsOf(setup.computer)
    if not levels then
      return nil, "player_count"
    end
    computers = #levels
  end
  if not Games.CanSeat(game, #targets + computers + 1) then
    return nil, "player_count"
  end
  for _, target in ipairs(targets) do
    if self:openMatchesWith(target) >= MAX_OPEN_PER_PEER then
      return nil, "too_many_matches"
    end
  end

  local now = self.env.now()
  local players, mySeat
  if #targets == 1 and computers == 0 then
    mySeat = (setup.seat == 1 or setup.seat == 2) and setup.seat or self.env.random(2)
    players = { mySeat == 1 and self.env.me or targets[1], mySeat == 1 and targets[1] or self.env.me }
  else
    -- Everyone sits somewhere at random, and so does the computer
    players = { self.env.me, unpack(targets) }
    for _ = 1, computers do
      players[#players + 1] = Match.COMPUTER
    end
    for index = #players, 2, -1 do
      local other = self.env.random(index)
      players[index], players[other] = players[other], players[index]
    end
    for seat, name in ipairs(players) do
      mySeat = name == self.env.me and seat or mySeat
    end
  end
  local id = setup.id or string.format("%x%06x", now, self.env.random(0xFFFFFF))

  --- @type Match
  local match = {
    id = id,
    game = game.id,
    gameVersion = game.version,
    players = players,
    options = Games.Chosen(game, setup.options),
    me = mySeat,
    log = {},
    status = "outgoing",
    seen = {},
    created = now,
    updated = now,
  }
  if #players > 2 then
    match.host, match.accepted = mySeat, {}
  end
  for seat, name in ipairs(players) do
    if name == Match.COMPUTER then
      match.computers = match.computers or {}
      match.computers[seat] = table.remove(levels, 1)
    end
  end
  self.env.matches[id] = match
  for _, seat in ipairs(peersOf(match)) do
    self:sendInvite(match, seat)
  end
  self.env.notify("changed", match)
  return match
end

-----------------------------
-- Games linked in chat
-----------------------------

--- Leaves a game for two open to whoever asks for it first. Linking the same game again sets
--- it up anew.
--- @param gameId string
--- @param setup { options: table<string, any>?, seat: number? }? As for a challenge
--- @return GameDefinition?, string? error
function Session:Offer(gameId, setup)
  setup = setup or {}
  local game = Games.Get(gameId)
  if not game then
    return nil, "unknown_game"
  end
  if not Games.CanSeat(game, 2) then
    return nil, "player_count"
  end
  self.env.offers[game.id] = {
    options = Games.Chosen(game, setup.options),
    seat = (setup.seat == 1 or setup.seat == 2) and setup.seat or nil,
    expires = self.env.now() + OFFER_LIFETIME,
  }
  return game
end

--- @param gameId string
--- @return Offer? The game of that kind the player has open, if there is one
function Session:Offered(gameId)
  local offer = self.env.offers[gameId]
  if offer and offer.expires <= self.env.now() then
    self.env.offers[gameId] = nil
    return nil
  end
  return offer
end

--- Asks a player for the game they linked in chat
--- @param host string Full name of whoever linked it
--- @param gameId string
--- @return boolean, string? error
function Session:Ask(host, gameId)
  local game = Games.Get(gameId)
  if not game then
    return false, "unknown_game"
  end
  if host == self.env.me then
    return false, "self_invite"
  end
  if self:openMatchesWith(host) >= MAX_OPEN_PER_PEER then
    return false, "too_many_matches"
  end

  local now = self.env.now()
  for id, asked in pairs(self.asked) do
    if asked.expires <= now then
      self.asked[id] = nil
    elseif asked.host == host and asked.game == game.id then
      -- Clicked twice, the answer to the first is still on its way
      return true
    end
  end

  local id = string.format("%x%06x", now, self.env.random(0xFFFFFF))
  if not self.env.send(host, Codec.Encode("ASK", id, game.id, game.version)) then
    return false, "not_sent"
  end
  self.asked[id] = { host = host, game = game.id, expires = now + ASK_WINDOW }
  return true
end

--- A game the player asked for isn't to be had
--- @param id string
--- @param reason string
function Session:refused(id, reason)
  local asked = self.asked[id]
  self.asked[id] = nil
  if self.env.onRefused then
    self.env.onRefused(asked.host, asked.game, reason)
  end
end

--- Someone clicked a link to a game of ours
--- @param sender string
--- @param message Message
function Session:onAsk(sender, message)
  local function refuse(reason)
    self.env.send(sender, Codec.Encode("DEC", message.id, reason))
  end

  local game = Games.Get(message.game)
  local offer = game and self:Offered(game.id)
  if not game or not offer then
    -- Taken by someone quicker, run out, or never there: anyone can type what a link says
    return refuse("closed")
  end
  if game.version ~= message.gameVersion then
    return refuse("version")
  end
  local match, err = self:Invite(sender, game.id, { options = offer.options, seat = offer.seat, id = message.id })
  if not match then
    return refuse(err == "too_many_matches" and "busy" or "closed")
  end
  self.env.offers[game.id] = nil
end

--- @param id string
--- @return boolean, string? error
function Session:Accept(id)
  local match = self.env.matches[id]
  if not match or match.status ~= "incoming" then
    return false, "no_match"
  end
  local inviter = Match.Inviter(match)
  match.status = "active"
  match.unread = nil
  -- If this is lost the inviter keeps repeating the challenge and gets the acceptance then
  if match.race then
    self:sendRival(match, "ACC")
  else
    self:send(match, inviter, "ACC")
  end
  self:touch(match, "changed")
  return true
end

--- Declines a challenge. The match is kept hidden for a while so a repeated challenge can be
--- declined again instead of showing up a second time.
--- @param id string
--- @return boolean, string? error
function Session:Decline(id)
  local match = self.env.matches[id]
  if not match or match.status ~= "incoming" then
    return false, "no_match"
  end
  local inviter = Match.Inviter(match)
  match.status = "declined"
  match.hidden = true
  match.unread = nil
  if match.race then
    self:sendRival(match, "DEC")
  else
    self:send(match, inviter, "DEC")
  end
  self:touch(match, "changed")
  return true
end

--- Adds an entry of the local player's to a match that is being played
--- @param id string
--- @param entry string
--- @return boolean, string? error
function Session:appendOwn(id, entry)
  local match = self.env.matches[id]
  if not match or match.status ~= "active" then
    return false, "no_match"
  end
  local ok, err = Match.Append(match, entry)
  if not ok then
    return false, err
  end
  match.unread = nil
  self:pushAll(match)
  self:record(match)
  self:scoreDaily(match)
  self:finishRun(match)
  self:beaten(match)
  self:Tally(match)
  self:touch(match, "changed")
  return true
end

--- @param id string
--- @param move string
--- @return boolean, string? error
function Session:Move(id, move)
  local match = self.env.matches[id]
  if not match or match.status ~= "active" then
    return false, "no_match"
  end
  if not Match.CanMove(match) then
    return false, "not_your_turn"
  end
  if type(move) ~= "string" or move:sub(1, 1) == "!" then
    return false, "invalid_move"
  end
  return self:appendOwn(id, Match.MoveEntry(match, move))
end

--- @param id string
--- @return boolean, string? error
function Session:Resign(id)
  local match = self.env.matches[id]
  if not match or match.status ~= "active" or not Match.Started(match) or Match.IsOut(match, match.me) then
    return false, "no_match"
  end
  if Match.IsComputerMatch(match) and not Match.Result(match) then
    -- The computer doesn't play on among itself: the game is over once the player is out of it
    self.thinking[id] = nil
    local ok, err = Match.Append(match, Match.ResignEntry(match.me))
    if not ok then
      return false, err
    end
    match.status = "finished"
    self:Tally(match)
    self:touch(match, "changed")
    return true
  end
  return self:appendOwn(id, Match.ResignEntry(match.me))
end

--- Offers the opponent a draw. Only on the local player's turn, the offer travels with the move
--- they make next and is turned down by the opponent playing on.
--- @param id string
--- @return boolean, string? error
function Session:OfferDraw(id)
  local match = self.env.matches[id]
  if not match or not Match.CanOfferDraw(match) then
    return false, "no_draw"
  end
  return self:appendOwn(id, Match.DrawOfferEntry(match.me))
end

--- @param id string
--- @return boolean, string? error
function Session:AcceptDraw(id)
  local match = self.env.matches[id]
  if not match or not Match.CanAcceptDraw(match) then
    return false, "no_draw"
  end
  return self:appendOwn(id, Match.DrawAcceptEntry(match.me))
end

-----------------------------
-- Records and the clock
-----------------------------
-- A game played alone has nobody to beat but the player's own best. A game that says what is
-- worth remembering (GameDefinition.record) has it kept here, and one that is timed
-- (GameDefinition.clock) has its seconds counted by whoever shows it: the session only keeps them.
-- A game with a ghost (GameDefinition.ghost) has every run kept as it is played, raced or not
-- (Sample), and the run that set a best kept with it, for the player to race next time (Ghost).

--- Remembers whatever of a game for one is the best the player ever did
--- @param match Match
function Session:record(match)
  local game = Games.Get(match.game)
  if not game or not game.record or not Match.IsSolo(match) then
    return
  end
  local records = game.record(Match.State(match), match.played or 0, Match.Result(match))
  for _, record in ipairs(records or {}) do
    local bests = self.env.records[game.id] or {}
    self.env.records[game.id] = bests
    local best = bests[record.key]
    local better = best == nil or (record.lower and record.value < best) or (not record.lower and record.value > best)
    if better then
      bests[record.key] = record.value
      match.bests = match.bests or {}
      match.bests[record.key] = true
      if game.ghost then
        -- The run that set it goes with it: a best without one has none, not an older one's
        local trail = match.race and match.race.trail or match.trail
        local ghosts = self.env.ghosts[game.id] or {}
        self.env.ghosts[game.id] = ghosts
        ghosts[record.key] = trail
      end
    end
  end
end

--- The best the player ever did at a game
--- @param gameId string
--- @param key string See GameRecord
--- @return number? nil if there is none yet
function Session:Best(gameId, key)
  local bests = self.env.records[gameId]
  return bests and bests[key]
end

--- The run that set the best the player ever did at a game with a ghost, its samples
--- @param gameId string
--- @param key string See GameRecord
--- @return string[]? nil if there is none
function Session:Ghost(gameId, key)
  local ghosts = self.env.ghosts[gameId]
  local trail = ghosts and ghosts[key]
  if not trail then
    return nil
  end
  local samples = {}
  for sample in (trail .. "+"):gmatch("([^+]*)%+") do
    samples[#samples + 1] = sample
  end
  return samples
end

--- Whether it was this match that set a record
--- @param match Match
--- @param key string
--- @return boolean
function Session:SetBest(match, key)
  return match.bests ~= nil and match.bests[key] == true
end

--- How long a game for one has been played for
--- @param match Match
--- @return number seconds
function Session:Elapsed(match)
  return match.played or 0
end

--- Counts time spent playing a game for one that is timed. Nothing is said about it: a clock
--- that is shown is asked for the time, it isn't told
--- @param id string
--- @param seconds number
function Session:Spend(id, seconds)
  local match = self.env.matches[id]
  local game = match and Games.Get(match.game)
  if not game or not game.clock or not Match.IsSolo(match) or match.status ~= "active" then
    return
  end
  if game.clock == "open" or #match.log > 0 then
    match.played = (match.played or 0) + seconds
  end
end

--- How long the log of a game against the computer is to be once the player's last move is
--- taken back: whatever the computer did since goes with it, and so does a draw offer the
--- player made with it
--- @param match Match
--- @return number? nil if the player hasn't moved yet
local function beforeLastMove(match)
  local events = Match.Events(match)
  for index = #events, 1, -1 do
    local event = events[index]
    if event.seat == match.me and event.kind == "move" then
      local cut = index - 1
      while cut > 0 and events[cut].seat == match.me and events[cut].kind == "offer" do
        cut = cut - 1
      end
      return cut
    end
  end
  return nil
end

--- Whether the local player can take their last move back: in a game they play alone that
--- allows it, or against the computer where the game does, and not once it is over
--- @param match Match
--- @return boolean
function Session:CanUndo(match)
  local game = Games.Get(match.game)
  if not game or match.status ~= "active" then
    return false
  end
  if Match.IsComputerMatch(match) then
    return Computer.TakesBack(game) and beforeLastMove(match) ~= nil
  end
  -- Neither the day's challenge nor a race: what a move turned up could be looked at and tried again
  return game.undo == true and Match.IsSolo(match) and not match.daily and not match.race and #match.log > 0
end

--- Takes the local player's last move back
--- @param id string
--- @return boolean, string? error
function Session:Undo(id)
  local match = self.env.matches[id]
  if not match then
    return false, "no_match"
  end
  if not self:CanUndo(match) then
    return false, "no_undo"
  end
  self.thinking[id] = nil
  Match.Truncate(match, Match.IsComputerMatch(match) and beforeLastMove(match) or #match.log - 1)
  self:touch(match, "changed")
  return true
end

-----------------------------
-- The computer
-----------------------------

--- The seat the computer is to move in, in a game it plays in that waits on it here: against
--- the player, or at a table of people where this client plays the computer's seats
--- @param match Match
--- @return number? nil if it isn't the computer's move, or it is somebody else's client's to make
function Session:ComputerTurn(match)
  if match.status ~= "active" or Match.Driver(match) ~= match.me then
    return nil
  end
  local turn = Match.Turn(match)
  return turn and Match.IsComputer(match, turn) and turn or nil
end

--- Whether the computer knows what it is going to do and is only waiting to be let do it
--- @param match Match
--- @return boolean
function Session:ComputerReady(match)
  local thought = self.thinking[match.id]
  return thought ~= nil and thought.ply == #match.log and thought.thinker.done
end

--- Makes the computer's move, or answers the player's draw offer. A move that turns out not to
--- be legal after all is put right with one that is: the game goes on whatever the computer did
--- @param match Match
--- @param seat number
--- @param thinker Thinker
function Session:computerMoves(match, seat, thinker)
  local game = Games.Get(match.game)
  local log = self.env.log
  if thinker.failed and log then
    log("computer", match.game, "failed:", thinker.failed)
  end
  local offer = Match.DrawOffer(match)
  local entry = thinker.move
  if offer and offer ~= seat and thinker.score and thinker.score <= 0 then
    -- No better off playing on than settling for a draw
    entry = Match.DrawAcceptEntry(seat)
  end
  local ok, err = false, "no_move"
  if entry then
    ok, err = Match.Append(match, entry)
  end
  if not ok then
    if log then
      log("computer", match.game, "played", tostring(entry), "which was refused:", tostring(err))
    end
    for _, move in ipairs(game.moves and game.moves(Match.State(match), seat) or {}) do
      ok = Match.Append(match, move)
      if ok then
        break
      end
    end
    if not ok then
      ok = Match.Append(match, Match.ResignEntry(seat))
    end
  end
  self:beaten(match)
  self:Tally(match)
  if Match.IsLocal(match) then
    self:touch(match, "changed")
    return
  end
  -- At a table of people it is a move like theirs
  self:pushAll(match)
  local entry = match.log[#match.log]
  local event = eventFor(match, entry)
  self:touch(match, event, event ~= "moved" or Match.CanMove(match))
end

--- Ends a game the computer plays in once the people in it are all out of it: the computer
--- doesn't play on among itself. Every client of a table of people comes to that from the log
--- @param match Match
function Session:beaten(match)
  local game = Games.Get(match.game)
  if match.status ~= "active" or not Match.HasComputers(match) or not game or not game.beaten then
    return
  end
  local state = Match.State(match)
  for seat = 1, #match.players do
    if not Match.IsComputer(match, seat) and not Match.IsOut(match, seat) and not game.beaten(state, seat) then
      return
    end
  end
  self.thinking[match.id] = nil
  match.status, match.beaten = "finished", true
end

--- Lets the computer think about its move in a game against it, if it is the computer's move
--- @param id string
--- @param ms number? For how long it may think now, until it knows if left out
--- @param ready boolean? Whether it may make the move once it knows it. Otherwise it waits with it, for whoever shows the match to be done showing the move before
--- @return boolean thinking Whether the computer is still to move
function Session:Think(id, ms, ready)
  local match = self.env.matches[id]
  local seat = match and self:ComputerTurn(match)
  if not seat then
    self.thinking[id] = nil
    return false
  end
  -- Of the games against the computer alone only the one being looked at is thought about: what
  -- was half thought out for another goes. A table of people is waiting on it whatever is
  if Match.IsLocal(match) then
    for other in pairs(self.thinking) do
      local that = self.env.matches[other]
      if other ~= id and (not that or Match.IsLocal(that)) then
        self.thinking[other] = nil
      end
    end
  end
  local thought = self.thinking[id]
  if not thought or thought.ply ~= #match.log then
    local game = Games.Get(match.game)
    local state = Match.State(match)
    -- Only ever what its own seat may see, on a copy it can do what it likes with
    local seen = Computer.Copy(game.visible and game.visible(state, seat) or state)
    local seed = Random.Stir(Random.Seed(match.id), "computer" .. #match.log)
    local offer = Match.DrawOffer(match)
    local thinker = Computer.Think(game, seen, seat, match.computers[seat], seed, offer ~= nil and offer ~= seat)
    thought = { ply = #match.log, thinker = thinker }
    self.thinking[id] = thought
  end
  if not thought.thinker:Run(ms, self.env.clock) or not ready then
    return true
  end
  self.thinking[id] = nil
  self:computerMoves(match, seat, thought.thinker)
  return self:ComputerTurn(match) ~= nil
end

--- Lets the computer think about its moves at the tables of people this client plays its seats
--- at, one table at a time, whether or not any of them is on screen. Each move waits until the
--- computer has seemed to think about it for a while, so that the people at the table see them
--- come one after the other
--- @param elapsed number Seconds since this was last called
--- @param ms number? For how long the computer may think now, until it knows if left out
--- @param shown string? The match on screen, whoever shows it lets the computer think there
function Session:Drive(elapsed, ms, shown)
  local ids = {}
  for id, match in pairs(self.env.matches) do
    -- Every frame, so what can't be one is passed over first
    if Match.HasComputers(match) and id ~= shown and not Match.IsLocal(match) and self:ComputerTurn(match) then
      ids[#ids + 1] = id
    end
  end
  for id in pairs(self.waits) do
    if not self.env.matches[id] or not self:ComputerTurn(self.env.matches[id]) then
      self.waits[id] = nil
    end
  end
  -- The one that has waited longest
  table.sort(ids, function(a, b)
    return self.env.matches[a].updated < self.env.matches[b].updated or (self.env.matches[a].updated == self.env.matches[b].updated and a < b)
  end)
  local id = ids[1]
  if not id then
    return
  end
  local match = self.env.matches[id]
  local wait = self.waits[id]
  if not wait or wait.ply ~= #match.log then
    wait = { ply = #match.log, waited = 0 }
    self.waits[id] = wait
  end
  wait.waited = wait.waited + elapsed
  self:Think(id, ms, wait.waited >= Computer.Pause(Games.Get(match.game)))
end

--- Plays the computer's moves until it is the player's turn again or the game is over, thinking
--- for as long as that takes. For the tests, and for anything that can't wait a frame at a time
--- @param id string
function Session:ThinkThrough(id)
  while self:Think(id, nil, true) do
  end
end

--- Counts a game against the computer that is over, once
--- @param match Match
function Session:Tally(match)
  if match.tallied or match.status ~= "finished" or not Match.IsComputerMatch(match) then
    return
  end
  local result, level = Match.Result(match), Match.Level(match)
  local how = "lost"
  if result and result.winner == match.me then
    how = "won"
  elseif result and result.winner == 0 and result.reason ~= "resign" then
    how = "drawn"
  end
  local byLevel = self.env.versus[match.game] or {}
  self.env.versus[match.game] = byLevel
  local tally = byLevel[level] or { won = 0, drawn = 0, lost = 0 }
  byLevel[level] = tally
  tally[how] = tally[how] + 1
  match.tallied = true
end

--- How the player's games against the computer went, at a level
--- @param gameId string
--- @param level string
--- @return VersusTally
function Session:Versus(gameId, level)
  local tally = self.env.versus[gameId] and self.env.versus[gameId][level]
  return { won = tally and tally.won or 0, drawn = tally and tally.drawn or 0, lost = tally and tally.lost or 0 }
end

--- Whether the local player can walk away from a match without resigning it first: it is over,
--- for everyone or for them, it never began, or nobody else is playing it
--- @param match Match
--- @return boolean
function Session:CanForget(match)
  if match.status == "incoming" then
    return false
  end
  if match.race and match.status == "active" and Race.On(match.race) then
    -- A race that is on is given up rather than thrown away, and the rival told it didn't finish
    return false
  end
  if Match.IsSolo(match) then
    -- The day's challenge is given up, which counts, rather than thrown away and played again
    return not match.daily or match.status ~= "active"
  end
  if Match.IsComputerMatch(match) and match.status == "active" then
    -- Walking away from a game against it would be a way of never losing one
    return beforeLastMove(match) == nil
  end
  return match.status ~= "active" or not Match.Started(match) or Match.IsOut(match, match.me)
end

--- Removes a match from the list. Withdraws the challenge if the game hasn't begun, matches
--- in progress have to be resigned first.
--- @param id string
--- @return boolean, string? error
function Session:Forget(id)
  local match = self.env.matches[id]
  if not match then
    return false, "no_match"
  end
  if not self:CanForget(match) then
    return false, "match_in_progress"
  end
  self.thinking[id] = nil
  if match.race then
    self:forgetRace(match)
    return true
  end

  if match.status == "outgoing" or (match.status == "active" and not Match.Started(match)) then
    -- The host calls it off for everyone, anyone else tells the host they are out after all
    for _, seat in ipairs(match.status == "outgoing" and peersOf(match) or { match.host }) do
      self:send(match, seat, "DEC")
    end
    match.status = "declined"
    match.hidden = true
    self:touch(match, "changed")
  else
    -- Players who still send something for it are told it is gone
    self.env.matches[id] = nil
    self.env.notify("changed", match)
  end
  return true
end

-----------------------------
-- What the player missed
-----------------------------
-- A player who comes back to a game finds it moved on: one move, or in a game for six a round
-- of everyone's. The window shows them those one after the other before the game as it stands,
-- which takes knowing how far they had seen it. That is kept with the match, so it is the same
-- after a /reload.

--- How far the player has seen a game on screen, as a number of log entries
--- @param match Match
--- @return number
function Session:Seen(match)
  if match.shown then
    return math.min(match.shown, #match.log)
  end
  -- A match from before this was kept: they saw it at least as far as their own last move
  local events = Match.Events(match)
  for index = #events, 1, -1 do
    if events[index].seat == match.me and events[index].kind ~= "start" then
      return index
    end
  end
  return 0
end

--- The player has seen a game on screen this far
--- @param id string
--- @param count number Log entries
function Session:Saw(id, count)
  local match = self.env.matches[id]
  if match then
    -- A log that was cut short since (a move taken back) was seen no further than it goes now
    match.shown = math.min(math.max(self:Seen(match), count), #match.log)
  end
end

--- How many moves of the others' the player hasn't seen yet
--- @param match Match
--- @return number missed, number seen How far they had seen it, as a number of log entries
function Session:Missed(match)
  local seen, missed = self:Seen(match), 0
  local events = Match.Events(match)
  for index = seen + 1, #events do
    if events[index].kind == "move" and events[index].seat ~= match.me then
      missed = missed + 1
    end
  end
  return missed, seen
end

--- @param id string
function Session:MarkRead(id)
  local match = self.env.matches[id]
  if match and match.unread then
    match.unread = nil
    self.env.notify("changed", match)
  end
end

-----------------------------
-- Races
-----------------------------
-- A race is a game for one on each side that goes by the same id, with the rival kept on it
-- rather than in a seat (MatchRace, Engine/Race.lua). What the two of them say about it is
-- between them alone: the challenge and its answer, and then each one's run, which is a log of
-- its own that only ever goes the one way. It is offered a stretch at a time, as the log of a
-- crowd is, and the rival answers the end of each stretch with how much of it they have.

--- Sends the rival of a race something about it
--- @param match Match
--- @param type string
--- @param ... string|number
--- @return boolean
function Session:sendRival(match, type, ...)
  return self.env.send(match.race.rival, Codec.Encode(type, match.id, ...))
end

--- Challenges the rival to the race, again for as long as they haven't answered
--- @param match Match
--- @return boolean sent
function Session:sendRace(match)
  local game = Games.Get(match.game)
  return self:sendRival(match, "RAC", match.game, match.gameVersion, game and Games.EncodeOptions(game, match.options) or nil)
end

--- Challenges somebody to race a game for one. The player's own game of it is on at once, and
--- the rival plays the same deal whenever they take the race up
--- @param game GameDefinition
--- @param rival string Full name
--- @param setup InviteSetup
--- @return Match?, string? error
function Session:startRace(game, rival, setup)
  if self:openMatchesWith(rival) >= MAX_OPEN_PER_PEER then
    return nil, "too_many_matches"
  end
  local race = { rival = rival, unanswered = true, told = 0, heard = {} }
  local match
  if setup.best then
    local trail
    match, trail = self:bestRun(game, setup.options)
    if not match then
      return nil, "no_best"
    end
    -- Over before it is sent: the rival has the run to hear as soon as they take the race up
    race.run = Race.Run(Race.Time(game, Match.State(match), match.played, Match.Result(match)) or false, trail)
    match.race = race
    self.env.matches[match.id] = match
    self.env.notify("changed", match)
  else
    match = self:startSolo(game, setup.options, nil, race)
  end
  self:sendRace(match)
  return match
end

-- A game whose every run by the same rules is the same course, whatever its deal (GameGhost.course),
-- can have the run that set the player's best sent to somebody to race as it is, rather than
-- played again for them. What is sent is all a race ever tells about a run: its time and its
-- ghost. The player's side of the race is a game for one that is over already, the course's way
-- to the end in its log and the best's time on its clock.

--- The run that set the player's best at a game by these rules, as a game for one that got to
--- the end, not yet on their list, and its ghost
--- @param game GameDefinition
--- @param options table<string, any>?
--- @return Match?, string? trail nil if the game's runs aren't all the one course, or the player has no best with a ghost by these rules
function Session:bestRun(game, options)
  local course = game.ghost and game.ghost.course
  if not course or not Race.Has(game) then
    return nil
  end
  local match = self:newSolo(game, options)
  for _, entry in ipairs(course(match.options) or {}) do
    if not Match.Append(match, entry) then
      return nil
    end
  end
  local result = Match.Result(match)
  if not result then
    return nil
  end
  for _, record in ipairs(game.record(Match.State(match), 0, result) or {}) do
    if record.lower then
      local best = self:Best(game.id, record.key)
      local trail = self.env.ghosts[game.id] and self.env.ghosts[game.id][record.key]
      if not best or not trail then
        return nil
      end
      match.played = best
      return match, trail
    end
  end
  return nil
end

--- How long the run that set the player's best at a game by these rules took, if it can be sent
--- to somebody to race as it is (InviteSetup.best)
--- @param gameId string
--- @param options table<string, any>?
--- @return number? seconds
function Session:BestToRace(gameId, options)
  local game = Games.Get(gameId)
  local match = game and self:bestRun(game, options)
  return match and match.played
end

--- Keeps where the player is now for the ghost of their run, in a game for one that has one
--- (GameDefinition.ghost): for the rival to race in a race, and for the player to race next time
--- if it is their best. Only one sample is kept for every so many seconds of the clock, so it can
--- be called as often as the view likes
--- @param id string
--- @param text string What the game makes of where the player is
--- @return boolean kept
function Session:Sample(id, text)
  local match = self.env.matches[id]
  local game = match and Games.Get(match.game)
  if not game or not game.ghost or not Match.IsSolo(match) or match.status ~= "active" then
    return false
  end
  -- A run in a race is kept for the rival as well, any other only for the player
  local race = match.race
  return Race.Sample((race and not race.declined) and race or match, game.ghost, match.played or 0, text)
end

--- Works out how a run went once it is over, the once, and tells the rival
--- @param match Match
function Session:finishRun(match)
  local race, game = match.race, Games.Get(match.game)
  local result = race and not race.run and game and Match.Result(match)
  if not result then
    return
  end
  race.run = Race.Run(Race.Time(game, Match.State(match), match.played or 0, result) or false, race.trail)
  race.trail, race.samples = nil, nil
  self:pushRun(match)
end

--- Offers the rival the next stretch of the local player's run they don't have yet. What is
--- on its way already isn't sent again, see Session:pushLog
--- @param match Match
--- @param restart boolean? Offer everything they haven't answered again, for retries
--- @return boolean sent False if a message could not be sent
function Session:pushRun(match, restart)
  local race = match.race
  local run = race.run
  if not run or not Race.On(race) then
    return true
  end
  local first = restart and race.told or math.max(race.told, self.runOffered[match.id] or 0)
  local last = math.min(#run, (math.floor(race.told / PUSH_LIMIT) + 1) * PUSH_LIMIT)
  for n = first + 1, last do
    if not self:sendRival(match, "MOV", n, #run, run[n]) then
      return false
    end
    self.runOffered[match.id] = n
  end
  return true
end

--- Tries again with whatever the rival of a race is missing: the challenge while they haven't
--- answered it, and the local player's run once it is over. And asks after theirs now and then
--- while it doesn't come, the way a match that is waiting on someone checks in with them
--- @param match Match
--- @param now number
--- @param force boolean? Ignore the backoff
--- @return boolean attempted Whether anything was sent that wants an answer
function Session:flushRace(match, now, force)
  local race = match.race
  if race.declined or match.status == "incoming" or match.status == "declined" then
    return false
  end
  local waiting = not race.unanswered and not (race.length and #race.heard >= race.length)
  if waiting and now - math.max(match.updated or 0, self.checkedIn[match.id] or 0) >= CHECK_IN then
    self.checkedIn[match.id] = now
    self:sendRival(match, "SYN", #race.heard)
  end
  local peer = self.peers[race.rival]
  if not force and peer and peer.nextTry > now then
    return false
  end
  if race.unanswered then
    self:sendRace(match)
    return true
  end
  local tried = false
  if self.pendingRace[match.id] then
    tried = true
    if self:sendRival(match, "SYN", #race.heard) then
      self.pendingRace[match.id] = nil
    end
  end
  if race.run and race.told < #race.run then
    tried = true
    self:pushRun(match, true)
  end
  return tried
end

--- Takes a race off the player's list. One the rival never answered is called off; one whose
--- rival is still to hear how the run went is kept out of sight until they have
--- @param match Match
function Session:forgetRace(match)
  local race = match.race
  if race.unanswered then
    -- Kept for a while, to turn down whatever the rival says about it after all
    self:sendRival(match, "DEC")
    match.status, match.hidden = "declined", true
    self:touch(match, "changed")
  elseif Race.On(race) and race.run and race.told < #race.run then
    match.hidden = true
    self:touch(match, "changed")
  else
    self.env.matches[match.id] = nil
    self.env.notify("changed", match)
  end
end

--- Somebody challenged the player to a race
--- @param sender string
--- @param message Message
function Session:onRace(sender, message)
  local function refuse(reason)
    self.env.send(sender, Codec.Encode("DEC", message.id, reason))
  end

  local game = Games.Get(message.game)
  -- A game whose addon isn't here can't be played here any more than one that isn't at all
  if not game or not Games.Offered(game) then
    return refuse("nogame")
  end
  -- A game that can't be raced here is from a version that could
  if game.version ~= message.gameVersion or not Race.Has(game) then
    return refuse("version")
  end
  local options, understood = Games.DecodeOptions(game, message.options)
  if not understood then
    return refuse("version")
  end
  if self.env.takes and not self.env.takes(sender) then
    return refuse("strangers")
  end
  if self:openMatchesWith(sender) >= MAX_OPEN_PER_PEER then
    return refuse("busy")
  end

  local now = self.env.now()
  --- @type Match
  local match = {
    id = message.id,
    game = game.id,
    gameVersion = game.version,
    players = { self.env.me },
    options = options,
    me = 1,
    log = {},
    status = "incoming",
    seen = {},
    created = now,
    updated = now,
    race = { rival = sender, told = 0, heard = {} },
  }
  self.env.matches[match.id] = match
  self:touch(match, "invite", true)
end

--- The rival challenged the player to a race they have already: they didn't hear the answer
--- @param match Match
function Session:onRaceAgain(match)
  if match.status == "declined" then
    self:sendRival(match, "DEC")
  elseif match.status ~= "incoming" then
    self:sendRival(match, "ACC")
  end
end

--- The rival took the race up, or said something that means they did even if the answer itself
--- got lost. The run is theirs to hear from now on
--- @param match Match
function Session:raceAccepted(match)
  local race = match.race
  if not race.unanswered then
    return
  end
  race.unanswered = nil
  self:touch(match, "accepted", true)
  self:pushRun(match)
end

--- The rival turned the race down, called it off, or no longer has it
--- @param match Match
--- @param message Message
function Session:onRaceDecline(match, message)
  local race = match.race
  if match.status == "incoming" then
    -- The challenge was withdrawn
    self.env.matches[match.id] = nil
    self.env.notify("cancelled", match)
  elseif race.unanswered then
    race.unanswered, race.declined = nil, message.reason or "declined"
    self:touch(match, "declined", true)
  elseif message.reason == "gone" and not race.declined then
    -- Nothing more goes to them, and nothing more is coming. Only news where how they did was
    -- still to come
    race.declined = "gone"
    if Race.Theirs(race) == nil then
      self:touch(match, "declined", true)
    else
      self.env.notify("changed", match)
    end
  end
end

--- An entry of the rival's run arrived
--- @param match Match
--- @param message Message
function Session:onRunEntry(match, message)
  local race = match.race
  local heard, n = race.heard, message.n
  if n > #heard + 1 then
    -- Something in between went missing, ask for it
    self:sendRival(match, "SYN", #heard)
    return
  end
  local added = n == #heard + 1
  if added then
    if not Race.Takes(n, message.total, message.entry) then
      return
    end
    heard[n], race.length = message.entry, message.total
  end
  if n == message.total or n % PUSH_LIMIT == 0 then
    self:sendRival(match, "ACK", #heard)
  end
  if added and (n == 1 or n == race.length) then
    -- How they did is news, and so is their ghost being all there to race against
    self:touch(match, n == 1 and "raced" or "changed", n == 1)
  end
end

--- The rival said how much of the local player's run they have, and with a SYN asks how much
--- of theirs there is here
--- @param match Match
--- @param message Message
--- @param wantsReply boolean
function Session:onRunCount(match, message, wantsReply)
  local race = match.race
  local run = race.run or {}
  -- Asked for, or a count that went backwards, what was sent didn't stick
  local restart = wantsReply or message.n < race.told
  race.told = math.min(message.n, #run)
  if race.told < #run then
    self:pushRun(match, restart)
  end
  if wantsReply then
    self:sendRival(match, "ACK", #race.heard)
  end
  self.env.notify("changed", match)
end

--- Handles whatever the rival of a race says about it
--- @param match Match
--- @param message Message
function Session:onRaceMessage(match, message)
  local race = match.race
  if message.type == "DEC" then
    return self:onRaceDecline(match, message)
  end
  if message.type ~= "ACC" and message.type ~= "MOV" and message.type ~= "ACK" and message.type ~= "SYN" then
    return
  end
  if match.status == "declined" then
    -- Turned down or called off here, and they are still racing
    self:sendRival(match, "DEC", "gone")
    return
  end
  if race.declined or match.status == "incoming" then
    return
  end
  self:raceAccepted(match)
  if message.type == "MOV" then
    self:onRunEntry(match, message)
  elseif message.type ~= "ACC" then
    self:onRunCount(match, message, message.type == "SYN")
  end
end

-----------------------------
-- Delivery
-----------------------------

--- Retries everything a player hasn't acknowledged. Players that stay silent are retried less
--- and less often.
--- @param force boolean? Ignore the backoff
function Session:Flush(force)
  local now = self.env.now()
  local attempted = {}

  for id, match in pairs(self.env.matches) do
    if match.race and self:flushRace(match, now, force) then
      attempted[match.race.rival] = true
    end
    local turn = Match.Turn(match)
    -- The computer's move is up to whoever's client plays its seats
    local holder = turn and Match.IsComputer(match, turn) and Match.Driver(match) or turn
    if holder and holder ~= match.me and now - math.max(match.updated or 0, self.checkedIn[id] or 0) >= CHECK_IN then
      -- Asked once and not again until the next time round, whether or not it gets through
      self.checkedIn[id] = now
      self:send(match, holder, "SYN", #match.log)
    end

    local sync = match.status == "active" and self.pendingSync[id] or {}
    local behind = {}
    for _, seat in ipairs(self:Behind(match)) do
      behind[seat] = true
    end

    for _, seat in ipairs(peersOf(match)) do
      local peerName = match.players[seat]
      local peer = self.peers[peerName]
      if (sync[seat] or behind[seat]) and (force or not peer or peer.nextTry <= now) then
        attempted[peerName] = true
        if match.status == "outgoing" then
          self:sendInvite(match, seat)
        else
          if sync[seat] and self:sendCount(match, seat, "SYN", #match.log) then
            sync[seat] = nil
          end
          self:pushLog(match, seat, true)
        end
      end
    end
  end

  for peerName in pairs(attempted) do
    local peer = self.peers[peerName] or { attempts = 0, nextTry = 0 }
    peer.attempts = peer.attempts + 1
    peer.nextTry = now + math.min(RETRY_BASE * 2 ^ (peer.attempts - 1), RETRY_MAX)
    self.peers[peerName] = peer
  end
end

--- Has every match in progress announce how much of it this player has, so that whatever they
--- are missing is sent again
--- @param crowdsOnly boolean? Only matches of more than two
function Session:askAround(crowdsOnly)
  for id, match in pairs(self.env.matches) do
    if match.status == "active" and not (crowdsOnly and #match.players == 2) then
      local sync = {}
      -- Before the game begins only the host has anything to say
      for _, seat in ipairs(Match.Started(match) and peersOf(match) or { match.host }) do
        sync[seat] = true
      end
      self.pendingSync[id] = sync
    end
    -- A race has a rival to tell how much of their run there is here, for as long as either of
    -- them has something left to hear
    if match.race and not crowdsOnly and match.status ~= "incoming" and match.status ~= "declined" then
      self.pendingRace[id] = Race.On(match.race) and not Race.Settled(match.race) or nil
    end
  end
end

--- Call on login. Announces the state of every match in progress, so that moves made while this
--- player was away, or lost by this client in a crash, are sent again.
function Session:Hello()
  self:Prune()
  self:askAround()
  self:Flush(true)
end

--- Retry right away, for when there is reason to think messages will get through again
--- @param peerName string? Only this player, everyone if omitted
function Session:Wake(peerName)
  if peerName then
    self.peers[peerName] = nil
    self:Flush()
  else
    -- Out of reach, this player may have missed what the others in a bigger match took to be
    -- reaching them from someone else
    self:askAround(true)
    self:Flush(true)
  end
end

--- Backs off from a player known to be offline
--- @param peerName string
function Session:PeerOffline(peerName)
  self.peers[peerName] = { attempts = 0, nextTry = self.env.now() + RETRY_MAX }
  for id, asked in pairs(self.asked) do
    if asked.host == peerName then
      self:refused(id, "offline")
    end
  end
end

--- Drops matches nobody will look at again
function Session:Prune()
  local now = self.env.now()
  for id, match in pairs(self.env.matches) do
    local age = now - (match.updated or 0)
    if (match.status == "declined" and age > KEEP_DECLINED) or (match.status == "finished" and age > KEEP_FINISHED) then
      self.env.matches[id] = nil
    end
  end
  for gameId, offer in pairs(self.env.offers) do
    if offer.expires <= now then
      self.env.offers[gameId] = nil
    end
  end
end

-----------------------------
-- Remote messages
-----------------------------

--- @param sender string
--- @param message Message
function Session:onInvite(sender, message)
  local function refuse(reason)
    self.env.send(sender, Codec.Encode("DEC", message.id, reason))
  end

  local game = Games.Get(message.game)
  -- A game whose addon isn't here can't be played here any more than one that isn't at all
  if not game or not Games.Offered(game) then
    return refuse("nogame")
  end
  if game.version ~= message.gameVersion then
    return refuse("version")
  end
  local seats = message.seats or 2
  local mySeat = message.mine or (message.seat == 1 and 2 or 1)
  if message.seat < 1 or message.seat > seats or mySeat < 1 or mySeat > seats or mySeat == message.seat then
    return
  end
  if (message.seats and seats < 3) or not Games.CanSeat(game, seats) then
    return
  end
  -- Rules this client can't play by come from a version of the game it doesn't have
  local options, understood = Games.DecodeOptions(game, message.options)
  if not understood then
    return refuse("version")
  end
  -- The computer only ever sits with a crowd, and never in the seat of anyone challenged
  local computers = message.computers
  if computers and (not message.seats or not Computer.Plays(game)) then
    return refuse("version")
  end
  for seat, level in pairs(computers or {}) do
    if seat > seats or seat == message.seat or seat == mySeat then
      return
    end
    if not Computer.IsLevel(level) then
      return refuse("version")
    end
  end
  local now = self.env.now()
  -- A game the player asked for by clicking a link is one they want, whoever linked it
  local asked = not message.seats and self.asked[message.id]
  local wanted = asked and asked.host == sender and asked.game == game.id and asked.expires > now
  if not wanted and self.env.takes and not self.env.takes(sender) then
    return refuse("strangers")
  end
  if self:openMatchesWith(sender) >= MAX_OPEN_PER_PEER then
    return refuse("busy")
  end

  --- @type Match
  local match = {
    id = message.id,
    game = game.id,
    gameVersion = game.version,
    players = { [message.seat] = sender, [mySeat] = self.env.me },
    options = options,
    computers = computers,
    me = mySeat,
    log = {},
    status = "incoming",
    seen = {},
    created = now,
    updated = now,
  }
  for seat in pairs(computers or {}) do
    match.players[seat] = Match.COMPUTER
  end
  if not message.seats then
    self.env.matches[match.id] = match
    if wanted then
      -- The player asked for this game, there is nothing left to answer
      self.asked[match.id] = nil
      match.status = "active"
      self:send(match, message.seat, "ACC")
      self:touch(match, "joined")
      return
    end
    self:touch(match, "invite", true)
    return
  end

  -- It only becomes a challenge to answer once it is known who else is playing
  match.host = message.seat
  self.gathering[match.id] = { match = match, seats = seats }
  self:onRoster(sender, match.id, message.names)
end

--- More of who is playing a match of more than two
--- @param sender string
--- @param id string
--- @param names table<number, string> Full player names by seat
function Session:onRoster(sender, id, names)
  local gathering = self.gathering[id]
  local match = gathering and gathering.match
  if not match or match.players[match.host] ~= sender then
    return
  end

  for seat, name in pairs(names) do
    if seat <= gathering.seats and not match.players[seat] and not Match.SeatOf(match, name) then
      match.players[seat] = name
    end
  end
  for seat = 1, gathering.seats do
    if not match.players[seat] then
      return
    end
  end

  self.gathering[id] = nil
  match.created, match.updated = self.env.now(), self.env.now()
  self.env.matches[id] = match
  self:touch(match, "invite", true)
end

--- A player accepted the challenge, or started playing, which means they accepted even if the
--- acceptance itself got lost. With more than two the game begins once they all have.
--- @param match Match
--- @param seat number
function Session:markAccepted(match, seat)
  if match.status ~= "outgoing" then
    return
  end
  if match.accepted then
    match.accepted[seat] = true
    if #self:Behind(match) > 0 then
      self.env.notify("changed", match)
      return
    end
    match.accepted = nil
  end

  match.status = "active"
  if match.host then
    Match.Append(match, Match.START)
    self:pushAll(match)
  end
  self:touch(match, "accepted", true)
end

--- An entry that arrived was added to the log
--- @param match Match
--- @param seat number Who it came from
--- @param n number
function Session:arrived(match, seat, n)
  -- Whoever sent it is taken to be sending it to everyone else too. Not in a game played
  -- together: where it ends up in their logs is another matter there
  if not Match.IsTogether(match) then
    for _, other in ipairs(Match.Others(match)) do
      match.seen[other] = math.max(match.seen[other] or 0, n)
    end
  end
  match.seen[seat] = n
  self:beaten(match)

  local event = eventFor(match, match.log[n])
  -- With more than two playing, most moves leave it someone else's turn: those aren't news
  local news = #match.players == 2 or event ~= "moved" or Match.CanMove(match)
  self:touch(match, event, news)
end

--- Tells a player how much of the log there is here, in answer to an entry of theirs. With more
--- than two playing only the end of a stretch is answered, see stretchEnd.
--- @param match Match
--- @param seat number
--- @param message Message
function Session:acknowledge(match, seat, message)
  if #match.players == 2 or message.n == message.total or message.n % PUSH_LIMIT == 0 then
    self:send(match, seat, "ACK", #match.log)
  end
end

--- @param match Match
--- @param seat number Who it came from
--- @param message Message
function Session:onMove(match, seat, message)
  self:markAccepted(match, seat)
  if match.status ~= "active" and match.status ~= "finished" then
    return
  end

  local n, entry = message.n, message.entry
  local length = #match.log

  if n > length + 1 then
    -- We are missing entries in between, ask for them
    self:send(match, seat, "SYN", length)
    return
  end

  if n == length + 1 then
    if Match.Append(match, entry) then
      self:arrived(match, seat, n)
    end
    self:acknowledge(match, seat, message)
    return
  end

  if match.log[n] == entry then
    match.seen[seat] = math.max(match.seen[seat] or 0, n)
    self:acknowledge(match, seat, message)
    return
  end

  -- The logs disagree, which happens when one side lost data in a crash and played on, or when
  -- two players acted at the same moment. The longer log wins. A tie between two players goes
  -- to seat 1, and among more to the entry that sorts first, which is the same whoever compares:
  -- so every client reaches the same answer without talking about it.
  -- Whoever's log gives way keeps the resignations it had, see below
  local theirsWins = message.total > length
  if message.total == length then
    if #match.players == 2 then
      theirsWins = match.me == 2
    else
      theirsWins = entry < match.log[n]
    end
  end
  if theirsWins then
    local previous = {}
    for i = n, length do
      previous[#previous + 1] = match.log[i]
    end
    Match.Truncate(match, n - 1)
    self.offered[match.id] = nil
    -- The others may have what was just dropped, they get this instead
    for _, other in ipairs(Match.Others(match)) do
      if other ~= seat then
        match.seen[other] = math.min(match.seen[other] or 0, n - 1)
      end
    end
    if Match.Append(match, entry) then
      match.seen[seat] = n
      -- A resignation says whose it is, and stands whatever was played before it: one that was
      -- made at the same moment goes back on top. A move doesn't say whose it is, it was made
      -- from a position that is gone and goes with it
      for _, old in ipairs(previous) do
        if Match.IsResignation(old) then
          Match.Append(match, old)
        end
      end
      self:beaten(match)
      self:touch(match, eventFor(match, match.log[#match.log]), true)
    else
      for _, old in ipairs(previous) do
        Match.Append(match, old)
      end
    end
    self:send(match, seat, "ACK", #match.log)
    self:pushAll(match)
  else
    match.seen[seat] = n - 1
    self:pushLog(match, seat, true)
  end
end

--- A player told us how many entries they have
--- @param match Match
--- @param seat number
--- @param message Message
--- @param wantsReply boolean
function Session:onCount(match, seat, message, wantsReply)
  self:markAccepted(match, seat)
  if match.status ~= "active" and match.status ~= "finished" then
    return
  end

  local length = #match.log
  -- A request for missing entries, or a count that went backwards, means what was sent didn't stick
  local restart = wantsReply or message.n < (match.seen[seat] or 0)
  match.seen[seat] = math.min(message.n, length)
  if message.n < length then
    self:pushLog(match, seat, restart)
  elseif wantsReply then
    self:send(match, seat, "ACK", length)
  elseif message.n > length then
    self:send(match, seat, "SYN", length)
  end
  self.env.notify("changed", match)
end

--- The log of a game played together turned out to differ from another player's somewhere
--- before the place a message of theirs was about. Where isn't known, so the one whose log gives
--- way is sent the other from the start, or from as far as they were last known to agree: the
--- entry they part ways at shows up on the way. Once in a while is enough, everything else that
--- was already on its way would only say the same again.
--- @param match Match
--- @param seat number
function Session:mend(match, seat)
  local mended = self.mended[match.id] or {}
  self.mended[match.id] = mended
  local now = self.env.now()
  if mended[seat] and now - mended[seat] < RETRY_BASE then
    return
  end
  mended[seat] = now

  if seat < match.me then
    self:sendCount(match, seat, "SYN", 0)
    return
  end
  if (match.seen[seat] or 0) >= #match.log then
    -- They were taken to have all of it
    match.seen[seat] = 0
  end
  self:pushLog(match, seat, true)
end

--- An entry of a game played together arrived. See the top of the file for how logs that were
--- added to at the same moment, or while the players couldn't reach each other, become one.
--- @param match Match
--- @param seat number Who it came from
--- @param message Message
function Session:onMoveTogether(match, seat, message)
  self:markAccepted(match, seat)
  if match.status ~= "active" and match.status ~= "finished" then
    return
  end

  local n, entry = message.n, message.entry
  local length = #match.log
  if n > length + 1 then
    self:sendCount(match, seat, "SYN", length)
    return
  end
  if message.digest ~= Match.Digest(match, n - 1) then
    self:mend(match, seat)
    return
  end
  -- Everything before the entry is the same here and there
  match.seen[seat] = math.max(match.seen[seat] or 0, n - 1)

  local answer = #match.players == 2 or n == message.total or n % PUSH_LIMIT == 0
  if n == length + 1 then
    if Match.Append(match, entry) then
      self:arrived(match, seat, n)
      if answer then
        self:sendCount(match, seat, "ACK", n)
      end
    end
    return
  end

  if match.log[n] == entry then
    match.seen[seat] = math.max(match.seen[seat], n)
    if answer then
      self:sendCount(match, seat, "ACK", n)
    end
    return
  end

  if seat > match.me then
    -- This log stands and they have yet to find out what it has here. It is on its way, or will
    -- be when it is next tried again
    match.seen[seat] = n - 1
    self:pushLog(match, seat)
    return
  end

  -- Theirs stands. What was here from this entry on goes back on top of it: it was played without
  -- knowing of theirs, and only what theirs has made illegal is lost
  local previous = {}
  for i = n, length do
    previous[#previous + 1] = match.log[i]
  end
  Match.Truncate(match, n - 1)
  self.offered[match.id] = nil
  for _, other in ipairs(Match.Others(match)) do
    match.seen[other] = math.min(match.seen[other] or 0, n - 1)
  end
  local taken = Match.Append(match, entry)
  if taken then
    match.seen[seat] = n
  end
  for _, old in ipairs(previous) do
    Match.Append(match, old)
  end
  self:touch(match, eventFor(match, entry), true)
  if taken and answer then
    self:sendCount(match, seat, "ACK", n)
  end
  if n >= message.total then
    -- That was all they had. Before that, every entry of theirs still to come would only send
    -- what is on top back down again
    self:pushAll(match)
  end
end

--- A player of a game played together told us how many entries they have, or how many of ours
--- @param match Match
--- @param seat number
--- @param message Message
--- @param wantsReply boolean
function Session:onCountTogether(match, seat, message, wantsReply)
  self:markAccepted(match, seat)
  if match.status ~= "active" and match.status ~= "finished" then
    return
  end

  local length = #match.log
  if message.n > length then
    -- More than there is here, so there is no telling whether it begins the same way. They can
    -- tell from what there is here
    self:sendCount(match, seat, wantsReply and "ACK" or "SYN", length)
  elseif message.digest ~= Match.Digest(match, message.n) then
    self:mend(match, seat)
  else
    if wantsReply then
      match.seen[seat] = message.n
    else
      -- Answers to entries come one by one and not always in order
      match.seen[seat] = math.max(match.seen[seat] or 0, message.n)
    end
    if message.n < length then
      self:pushLog(match, seat, wantsReply)
    elseif wantsReply then
      self:sendCount(match, seat, "ACK", length)
    end
  end
  self.env.notify("changed", match)
end

--- A player in a match of more than two no longer has it
--- @param match Match
--- @param seat number
function Session:onGone(match, seat)
  match.gone = match.gone or {}
  match.gone[seat] = true
  -- They can't play on without it, which takes them out of the game. Everyone who finds out
  -- adds the same entry, so it doesn't matter who gets to tell the others first
  if match.status == "active" and not Match.IsOut(match, seat) and Match.Append(match, Match.ResignEntry(seat)) then
    self:beaten(match)
    self:pushAll(match)
    self:touch(match, eventFor(match, match.log[#match.log]), true)
  else
    self.env.notify("changed", match)
  end
end

--- @param match Match
--- @param seat number Who it came from
--- @param message Message
function Session:onDecline(match, seat, message)
  if match.status == "outgoing" then
    match.status = "declined"
    match.declineReason = message.reason
    match.declinedBy = seat
    -- One player short, a game for more than two is off for the rest as well
    for _, other in ipairs(peersOf(match)) do
      if other ~= seat then
        self:send(match, other, "DEC")
      end
    end
    self:touch(match, "declined", true)
  elseif match.status == "incoming" then
    -- The challenge was withdrawn
    if seat == Match.Inviter(match) then
      self.env.matches[match.id] = nil
      self.env.notify("cancelled", match)
    end
  elseif match.status == "active" and not Match.Started(match) then
    -- Accepted, and then called off before everyone else had
    if seat == match.host then
      match.status = "declined"
      match.declineReason = "off"
      self:touch(match, "declined", true)
    end
  elseif message.reason == "gone" then
    if #match.players > 2 then
      self:onGone(match, seat)
    elseif match.status == "active" then
      -- The opponent no longer has this match, stop offering it to them
      match.status = "declined"
      match.declineReason = "gone"
      self:touch(match, "declined", true)
    elseif match.status == "finished" then
      match.seen[seat] = #match.log
      self.env.notify("changed", match)
    end
  end
end

--- Handles a payload received from another player
--- @param sender string Full player name
--- @param text string
function Session:Receive(sender, text)
  local message = Codec.Decode(text)
  if not message or sender == self.env.me then
    return
  end

  -- Hearing from someone means they are reachable again
  self.peers[sender] = nil

  local match = self.env.matches[message.id]
  -- The rival of a race has no seat in the player's game of it, see Session:onRaceMessage
  if message.type == "RAC" then
    if not match then
      self:onRace(sender, message)
    elseif match.race and match.race.rival == sender and not match.race.unanswered then
      self:onRaceAgain(match)
    end
    return
  end
  if match and match.race then
    if match.race.rival == sender then
      self:onRaceMessage(match, message)
    end
    return
  end
  local seat = match and Match.SeatOf(match, sender)
  if match and (not seat or seat == match.me) then
    return
  end

  if message.type == "ASK" then
    -- Asked twice, the challenge that answered the first time is on its way already
    if not match then
      self:onAsk(sender, message)
    end
    return
  end

  if message.type == "WHO" then
    if not match then
      self:onRoster(sender, message.id, message.names)
    end
    return
  end

  if message.type == "INV" then
    if not match then
      self:onInvite(sender, message)
    elseif match.status == "active" or match.status == "finished" then
      self:send(match, seat, "ACC")
    elseif match.status == "declined" then
      self:send(match, seat, "DEC")
    end
    return
  end

  if not match then
    local asked = self.asked[message.id]
    if message.type ~= "DEC" then
      self.env.send(sender, Codec.Encode("DEC", message.id, "gone"))
    elseif asked and asked.host == sender then
      self:refused(message.id, message.reason or "closed")
    end
    return
  end

  if match.status == "declined" and message.type ~= "DEC" then
    -- They are still playing a match that was withdrawn or ended on this side
    self:send(match, seat, "DEC", "gone")
    return
  end

  if message.type == "ACC" then
    self:markAccepted(match, seat)
  elseif message.type == "DEC" then
    self:onDecline(match, seat, message)
  elseif message.type == "MOV" then
    if Match.IsTogether(match) then
      self:onMoveTogether(match, seat, message)
    else
      self:onMove(match, seat, message)
    end
  elseif message.type == "ACK" or message.type == "SYN" then
    if Match.IsTogether(match) then
      self:onCountTogether(match, seat, message, message.type == "SYN")
    else
      self:onCount(match, seat, message, message.type == "SYN")
    end
  end
end
