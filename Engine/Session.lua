--------------------------
--  Session
--------------------------
-- Owns every match the player is part of and the protocol that keeps both clients in agreement.
-- Nothing in here touches the WoW API, everything it needs is passed in through `env` so the
-- whole protocol can be exercised from the command line (see Tests/).
--
-- There is no server and no delivery guarantee: the opponent may be offline, in an instance where
-- addon messages are blocked, or may have lost their saved data in a crash. So nothing is ever
-- "sent and forgotten". Each match tracks how much of the log the opponent is known to have and
-- anything they are missing is offered again until they acknowledge it.
--
-- Players are trusted to the extent friends playing board games are: every entry is validated
-- against the rules, but a longer valid log from the opponent is accepted as the truth.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class SessionEnv
--- @field me string Full name of the local player
--- @field matches table<string, Match> Persisted matches by id
--- @field send fun(target: string, text: string): boolean Returns false if the message could not be sent right now
--- @field now fun(): number
--- @field random fun(max: number): number
--- @field notify fun(event: string, match: Match)

--- @class Session
--- @field env SessionEnv
--- @field peers table<string, { attempts: number, nextTry: number }> Retry backoff per opponent
--- @field pendingSync table<string, boolean> Matches that still need to announce their log length
--- @field offered table<string, number> Highest log entry already on its way to the opponent, by match id
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
local DAY = 24 * 60 * 60
local KEEP_FINISHED = 30 * DAY
local KEEP_DECLINED = 7 * DAY

--- @param env SessionEnv
--- @return Session
function Session.New(env)
  return setmetatable({ env = env, peers = {}, pendingSync = {}, offered = {} }, Session)
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
--- @param type string
--- @param ... string|number
--- @return boolean
function Session:send(match, type, ...)
  return self.env.send(Match.Opponent(match), Codec.Encode(type, match.id, ...))
end

--- Offers the opponent the log entries they are missing. Entries already on their way are not
--- sent again, otherwise every acknowledgement during a long resync would repeat the rest of it.
--- @param match Match
--- @param restart boolean? Offer everything unacknowledged again, for retries
--- @return boolean sent False if a message could not be sent
function Session:pushLog(match, restart)
  local first = match.peerSeen
  if not restart then
    first = math.max(first, self.offered[match.id] or 0)
  end
  local last = math.min(#match.log, match.peerSeen + PUSH_LIMIT)
  for n = first + 1, last do
    if not self:send(match, "MOV", n, #match.log, match.log[n]) then
      return false
    end
    self.offered[match.id] = n
  end
  return true
end

--- @param match Match
function Session:sendInvite(match)
  return self:send(match, "INV", match.game, match.gameVersion, match.me)
end

--- Whether the opponent is missing something only we can give them
--- @param match Match
--- @return boolean
function Session:IsPending(match)
  if match.status == "outgoing" then
    return true
  end
  return (match.status == "active" or match.status == "finished") and match.peerSeen < #match.log
end

--- Whether the match is waiting on the local player
--- @param match Match
--- @return boolean
function Session:NeedsAttention(match)
  if match.hidden then
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
    if not match.hidden and match.status ~= "finished" and match.status ~= "declined" and Match.Opponent(match) == peer then
      count = count + 1
    end
  end
  return count
end

--- Challenges another player
--- @param target string Full player name
--- @param gameId string
--- @return Match?, string? error
function Session:Invite(target, gameId)
  local game = Games.Get(gameId)
  if not game then
    return nil, "unknown_game"
  end
  if not target or target == "" then
    return nil, "no_target"
  end
  if target == self.env.me then
    return nil, "self_invite"
  end
  if self:openMatchesWith(target) >= MAX_OPEN_PER_PEER then
    return nil, "too_many_matches"
  end

  local now = self.env.now()
  local mySeat = self.env.random(2)
  local id = string.format("%x%06x", now, self.env.random(0xFFFFFF))

  --- @type Match
  local match = {
    id = id,
    game = game.id,
    gameVersion = game.version,
    players = { mySeat == 1 and self.env.me or target, mySeat == 1 and target or self.env.me },
    me = mySeat,
    log = {},
    status = "outgoing",
    peerSeen = 0,
    created = now,
    updated = now,
  }
  self.env.matches[id] = match
  self:sendInvite(match)
  self.env.notify("changed", match)
  return match
end

--- @param id string
--- @return boolean, string? error
function Session:Accept(id)
  local match = self.env.matches[id]
  if not match or match.status ~= "incoming" then
    return false, "no_match"
  end
  match.status = "active"
  match.unread = nil
  -- If this is lost the inviter keeps repeating the challenge and gets the acceptance then
  self:send(match, "ACC")
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
  match.status = "declined"
  match.hidden = true
  match.unread = nil
  self:send(match, "DEC")
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

  local ok, err = Match.Append(match, move)
  if not ok then
    return false, err
  end
  match.unread = nil
  self:pushLog(match)
  self:touch(match, "changed")
  return true
end

--- @param id string
--- @return boolean, string? error
function Session:Resign(id)
  local match = self.env.matches[id]
  if not match or match.status ~= "active" then
    return false, "no_match"
  end
  Match.Append(match, Match.ResignEntry(match.me))
  match.unread = nil
  self:pushLog(match)
  self:touch(match, "changed")
  return true
end

--- Removes a match from the list. Withdraws the challenge if it hasn't been answered, matches
--- in progress have to be resigned first.
--- @param id string
--- @return boolean, string? error
function Session:Forget(id)
  local match = self.env.matches[id]
  if not match then
    return false, "no_match"
  end
  if match.status == "active" or match.status == "incoming" then
    return false, "match_in_progress"
  end

  if match.status == "outgoing" then
    self:send(match, "DEC")
    match.status = "declined"
    match.hidden = true
    self:touch(match, "changed")
  else
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

--- Retries everything an opponent hasn't acknowledged. Opponents that stay silent are retried
--- less and less often.
--- @param force boolean? Ignore the backoff
function Session:Flush(force)
  local now = self.env.now()
  local attempted = {}

  for id, match in pairs(self.env.matches) do
    local needsSync = self.pendingSync[id] and match.status == "active"
    if needsSync or self:IsPending(match) then
      local peerName = Match.Opponent(match)
      local peer = self.peers[peerName]
      if force or not peer or peer.nextTry <= now then
        attempted[peerName] = true
        if match.status == "outgoing" then
          self:sendInvite(match)
        else
          if needsSync and self:send(match, "SYN", #match.log) then
            self.pendingSync[id] = nil
          end
          self:pushLog(match, true)
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

--- Call on login. Announces the state of every match in progress, so that moves made while this
--- player was away, or lost by this client in a crash, are sent again.
function Session:Hello()
  self:Prune()
  for id, match in pairs(self.env.matches) do
    if match.status == "active" then
      self.pendingSync[id] = true
    end
  end
  self:Flush(true)
end

--- Retry right away, for when there is reason to think messages will get through again
--- @param peerName string? Only this opponent, everyone if omitted
function Session:Wake(peerName)
  if peerName then
    self.peers[peerName] = nil
    self:Flush()
  else
    self:Flush(true)
  end
end

--- Backs off from an opponent known to be offline
--- @param peerName string
function Session:PeerOffline(peerName)
  self.peers[peerName] = { attempts = 0, nextTry = self.env.now() + RETRY_MAX }
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
  if message.seat ~= 1 and message.seat ~= 2 then
    return
  end
  if self:openMatchesWith(sender) >= MAX_OPEN_PER_PEER then
    return refuse("busy")
  end

  local now = self.env.now()
  local mySeat = message.seat == 1 and 2 or 1
  --- @type Match
  local match = {
    id = message.id,
    game = game.id,
    gameVersion = game.version,
    players = { mySeat == 1 and self.env.me or sender, mySeat == 1 and sender or self.env.me },
    me = mySeat,
    log = {},
    status = "incoming",
    peerSeen = 0,
    created = now,
    updated = now,
  }
  self.env.matches[match.id] = match
  self:touch(match, "invite", true)
end

--- The opponent started playing, which means they accepted even if the acceptance itself got lost
--- @param match Match
function Session:markAccepted(match)
  if match.status == "outgoing" then
    match.status = "active"
    self:touch(match, "accepted", true)
  end
end

--- @param match Match
--- @param message Message
function Session:onMove(match, message)
  self:markAccepted(match)
  if match.status ~= "active" and match.status ~= "finished" then
    return
  end

  local n, entry = message.n, message.entry
  local length = #match.log

  if n > length + 1 then
    -- We are missing entries in between, ask for them
    self:send(match, "SYN", length)
    return
  end

  if n == length + 1 then
    if Match.Append(match, entry) then
      match.peerSeen = n
      self:touch(match, match.status == "finished" and "finished" or "moved", true)
    end
    self:send(match, "ACK", #match.log)
    return
  end

  if match.log[n] == entry then
    match.peerSeen = math.max(match.peerSeen, n)
    self:send(match, "ACK", length)
    return
  end

  -- The logs disagree, which happens when one side lost data in a crash and played on, or when
  -- both acted at the same moment. The longer log wins and seat 1 wins a tie, so both clients
  -- reach the same answer without talking about it.
  local theirsWins = message.total > length or (message.total == length and match.me == 2)
  if theirsWins then
    local previous = {}
    for i = n, length do
      previous[#previous + 1] = match.log[i]
    end
    Match.Truncate(match, n - 1)
    self.offered[match.id] = nil
    if Match.Append(match, entry) then
      match.peerSeen = n
      self:touch(match, match.status == "finished" and "finished" or "moved", true)
    else
      for _, old in ipairs(previous) do
        Match.Append(match, old)
      end
    end
    self:send(match, "ACK", #match.log)
  else
    match.peerSeen = n - 1
    self:pushLog(match, true)
  end
end

--- The opponent told us how many entries they have
--- @param match Match
--- @param message Message
--- @param wantsReply boolean
function Session:onCount(match, message, wantsReply)
  self:markAccepted(match)
  if match.status ~= "active" and match.status ~= "finished" then
    return
  end

  local length = #match.log
  -- A request for missing entries, or a count that went backwards, means what was sent didn't stick
  local restart = wantsReply or message.n < match.peerSeen
  match.peerSeen = math.min(message.n, length)
  if message.n < length then
    self:pushLog(match, restart)
  elseif wantsReply then
    self:send(match, "ACK", length)
  elseif message.n > length then
    self:send(match, "SYN", length)
  end
  self.env.notify("changed", match)
end

--- @param match Match
--- @param message Message
function Session:onDecline(match, message)
  if match.status == "outgoing" then
    match.status = "declined"
    match.declineReason = message.reason
    self:touch(match, "declined", true)
  elseif match.status == "incoming" then
    -- The challenge was withdrawn
    self.env.matches[match.id] = nil
    self.env.notify("cancelled", match)
  elseif message.reason == "gone" then
    -- The opponent no longer has this match, stop offering it to them
    if match.status == "active" then
      match.status = "declined"
      match.declineReason = "gone"
      self:touch(match, "declined", true)
    elseif match.status == "finished" then
      match.peerSeen = #match.log
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
  if match and Match.Opponent(match) ~= sender then
    return
  end

  if message.type == "INV" then
    if not match then
      self:onInvite(sender, message)
    elseif match.status == "active" or match.status == "finished" then
      self:send(match, "ACC")
    elseif match.status == "declined" then
      self:send(match, "DEC")
    end
    return
  end

  if not match then
    if message.type ~= "DEC" then
      self.env.send(sender, Codec.Encode("DEC", message.id, "gone"))
    end
    return
  end

  if match.status == "declined" and message.type ~= "DEC" then
    -- They are still playing a match that was withdrawn or ended on this side
    self:send(match, "DEC", "gone")
    return
  end

  if message.type == "ACC" then
    self:markAccepted(match)
  elseif message.type == "DEC" then
    self:onDecline(match, message)
  elseif message.type == "MOV" then
    self:onMove(match, message)
  elseif message.type == "ACK" then
    self:onCount(match, message, false)
  elseif message.type == "SYN" then
    self:onCount(match, message, true)
  end
end
