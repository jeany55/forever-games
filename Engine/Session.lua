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
-- A game for one is a match like any other with nobody else in it: there is no challenge, it is
-- never anyone's turn but the player's, and nothing about it is ever sent. It doesn't count as
-- waiting on the player either, a game nobody else is in can wait for as long as it likes.
--
-- A game for two can also be left open to whoever wants it: the player links it in chat, and the
-- first one to click the link asks for it. Asking is as good as accepting, so the challenge that
-- comes back is on at once. Whoever asks too late, or for a game that was never open, is told so.

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
--- @field offers table<string, Offer>? The games the player linked in chat that nobody took yet, by game id. Persisted. Forgotten with the session if left out
--- @field onRefused (fun(host: string, gameId: string, reason: string))? Called when a game the player asked for isn't to be had

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
--- @field asked table<string, { host: string, game: string, expires: number }> Games the player asked for by clicking a link and hasn't heard about yet, by the id they gave them
local Session = {}
Session.__index = Session
private.Session = Session

local Codec = private.Codec
local Games = private.Games
local Match = private.Match

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
  env.offers = env.offers or {}
  return setmetatable({ env = env, peers = {}, pendingSync = {}, offered = {}, gathering = {}, checkedIn = {}, asked = {} }, Session)
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

--- Seats of the players who are sent what happens in a match
--- @param match Match
--- @return number[]
local function peersOf(match)
  local seats = {}
  for _, seat in ipairs(Match.Others(match)) do
    if not (match.gone and match.gone[seat]) then
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
  for n = first + 1, last do
    if not self:send(match, seat, "MOV", n, #match.log, match.log[n]) then
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
  fields[#fields + 1] = game and Games.EncodeOptions(game, match.options)
  if #match.players == 2 then
    return self:send(match, seat, type, unpack(fields))
  end

  fields[#fields + 1], fields[#fields + 2] = #match.players, seat
  for other, name in ipairs(match.players) do
    if other ~= match.me and other ~= seat then
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
  if match.hidden or Match.IsSolo(match) then
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
        if seat ~= match.me then
          last[name] = math.max(last[name] or 0, match.updated or 0)
        end
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
    if not match.hidden and match.status ~= "finished" and match.status ~= "declined" and seat and seat ~= match.me then
      count = count + 1
    end
  end
  return count
end

--- Starts a game for one. There is nobody to ask, so it is on at once
--- @param game GameDefinition
--- @param options table<string, any>? How the rules are set, the usual way if left out
--- @return Match
function Session:startSolo(game, options)
  local now = self.env.now()
  --- @type Match
  local match = {
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
  self.env.matches[match.id] = match
  self.env.notify("changed", match)
  return match
end

--- Challenges one player, or several to a game for more than two. With nobody to challenge it
--- starts a game for one, where the game is one
--- @param targets string|string[] Full player names
--- @param gameId string
--- @param setup { options: table<string, any>?, seat: number?, id: string? }? How the rules are set, by option id, and for a game of two the seat the local player takes. The usual rules and a seat at random if left out. A match that was asked for goes by the id it was asked for with
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
  if not Games.CanSeat(game, #targets + 1) then
    return nil, "player_count"
  end
  for _, target in ipairs(targets) do
    if self:openMatchesWith(target) >= MAX_OPEN_PER_PEER then
      return nil, "too_many_matches"
    end
  end

  local now = self.env.now()
  local players, mySeat
  if #targets == 1 then
    mySeat = (setup.seat == 1 or setup.seat == 2) and setup.seat or self.env.random(2)
    players = { mySeat == 1 and self.env.me or targets[1], mySeat == 1 and targets[1] or self.env.me }
  else
    -- Everyone sits somewhere at random
    players = { self.env.me, unpack(targets) }
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
  self.env.matches[id] = match
  for _, seat in ipairs(Match.Others(match)) do
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
  self:send(match, inviter, "ACC")
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
  self:send(match, inviter, "DEC")
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
  if not Match.IsMyTurn(match) then
    return false, "not_your_turn"
  end
  if type(move) ~= "string" or move:sub(1, 1) == "!" then
    return false, "invalid_move"
  end
  return self:appendOwn(id, move)
end

--- @param id string
--- @return boolean, string? error
function Session:Resign(id)
  local match = self.env.matches[id]
  if not match or match.status ~= "active" or not Match.Started(match) or Match.IsOut(match, match.me) then
    return false, "no_match"
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

--- Whether the local player can take their last move back: only in a game they play alone
--- that allows it, and not once it is over
--- @param match Match
--- @return boolean
function Session:CanUndo(match)
  local game = Games.Get(match.game)
  return game ~= nil and game.undo == true and Match.IsSolo(match) and match.status == "active" and #match.log > 0
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
  Match.Truncate(match, #match.log - 1)
  self:touch(match, "changed")
  return true
end

--- Whether the local player can walk away from a match without resigning it first: it is over,
--- for everyone or for them, it never began, or nobody else is playing it
--- @param match Match
--- @return boolean
function Session:CanForget(match)
  if match.status == "incoming" then
    return false
  end
  if Match.IsSolo(match) then
    return true
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

  if match.status == "outgoing" or (match.status == "active" and not Match.Started(match)) then
    -- The host calls it off for everyone, anyone else tells the host they are out after all
    for _, seat in ipairs(match.status == "outgoing" and Match.Others(match) or { match.host }) do
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

--- @param id string
function Session:MarkRead(id)
  local match = self.env.matches[id]
  if match and match.unread then
    match.unread = nil
    self.env.notify("changed", match)
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
    local turn = Match.Turn(match)
    if turn and turn ~= match.me and now - math.max(match.updated or 0, self.checkedIn[id] or 0) >= CHECK_IN then
      -- Asked once and not again until the next time round, whether or not it gets through
      self.checkedIn[id] = now
      self:send(match, turn, "SYN", #match.log)
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
          if sync[seat] and self:send(match, seat, "SYN", #match.log) then
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
  if not game then
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
  if self:openMatchesWith(sender) >= MAX_OPEN_PER_PEER then
    return refuse("busy")
  end

  local now = self.env.now()
  --- @type Match
  local match = {
    id = message.id,
    game = game.id,
    gameVersion = game.version,
    players = { [message.seat] = sender, [mySeat] = self.env.me },
    options = options,
    me = mySeat,
    log = {},
    status = "incoming",
    seen = {},
    created = now,
    updated = now,
  }
  if not message.seats then
    self.env.matches[match.id] = match
    local asked = self.asked[match.id]
    if asked and asked.host == sender and asked.game == game.id and asked.expires > now then
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

--- What to tell the player about an entry someone else just added
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

--- An entry that arrived was added to the log
--- @param match Match
--- @param seat number Who it came from
--- @param n number
function Session:arrived(match, seat, n)
  -- Whoever sent it is taken to be sending it to everyone else too
  for _, other in ipairs(Match.Others(match)) do
    match.seen[other] = math.max(match.seen[other] or 0, n)
  end
  match.seen[seat] = n

  local event = eventFor(match, match.log[n])
  -- With more than two playing, most moves leave it someone else's turn: those aren't news
  local news = #match.players == 2 or event ~= "moved" or Match.IsMyTurn(match)
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
      self:touch(match, eventFor(match, entry), true)
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

--- A player in a match of more than two no longer has it
--- @param match Match
--- @param seat number
function Session:onGone(match, seat)
  match.gone = match.gone or {}
  match.gone[seat] = true
  -- They can't play on without it, which takes them out of the game. Everyone who finds out
  -- adds the same entry, so it doesn't matter who gets to tell the others first
  if match.status == "active" and not Match.IsOut(match, seat) and Match.Append(match, Match.ResignEntry(seat)) then
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
    for _, other in ipairs(Match.Others(match)) do
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
    self:onMove(match, seat, message)
  elseif message.type == "ACK" or message.type == "SYN" then
    self:onCount(match, seat, message, message.type == "SYN")
  end
end
