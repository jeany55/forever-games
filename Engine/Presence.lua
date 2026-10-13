--------------------------
--  Presence
--------------------------
-- Keeps track of who is online with the addon right now, so the player can see who they could
-- challenge. On login and every few minutes the player says hi to their guild and to their online
-- friends, and everyone who has the addon answers.
--
--   HI      sender is online with the addon and wants to know who else is
--   HEY     answer to a HI that arrived as a whisper
--   HEY:G   answer to a HI that arrived on the guild channel
--
-- Like the session, nothing in here touches the WoW API.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @alias PresenceSource "guild"|"friend"|"other"

--- @class PresencePlayer
--- @field name string Full player name
--- @field source PresenceSource How the player is known
--- @field seen number When they were last heard from

--- @class PresenceEnv
--- @field me string Full name of the local player
--- @field now fun(): number
--- @field broadcast fun(text: string) Sends to the player's guild, does nothing without one
--- @field whisper fun(target: string, text: string)
--- @field greet (fun(target: string, text: string))? Whisper for greeting friends, may be delayed. Defaults to whisper
--- @field friends fun(): string[] Full names of the friends who are online
--- @field onChange fun() Called when the set of available players changes

--- @class Presence
--- @field env PresenceEnv
--- @field players table<string, PresencePlayer>
--- @field replied table<string, number> When each player was last answered
--- @field lastAnnounce number?
--- @field announcements number How many times this player has announced
local Presence = {}
Presence.__index = Presence
private.Presence = Presence

local HI = private.Codec.PROTOCOL_VERSION .. ":HI"
local HEY = private.Codec.PROTOCOL_VERSION .. ":HEY"
local HEY_GUILD = HEY .. ":G"

local ANNOUNCE_INTERVAL = 5 * 60
-- Right after login the friends list and guild may not be loaded yet, so the first few
-- announcements come quickly until somebody answers
local EAGER_INTERVAL = 45
local EAGER_ANNOUNCEMENTS = 4
-- Long enough to miss one announcement without being dropped
local EXPIRE_AFTER = 11 * 60
local REPLY_COOLDOWN = 30
-- Friends are greeted one whisper each, keep that well under the addon message throttle
local MAX_FRIENDS = 40

local SOURCE_ORDER = { guild = 1, friend = 2, other = 3 }

--- @param env PresenceEnv
--- @return Presence
function Presence.New(env)
  return setmetatable({ env = env, players = {}, replied = {}, announcements = 0 }, Presence)
end

--- @param name string
--- @param source PresenceSource
function Presence:mark(name, source)
  if name == self.env.me then
    return
  end

  local player = self.players[name]
  local changed = false
  if not player then
    player = { name = name, source = source }
    self.players[name] = player
    changed = true
  elseif SOURCE_ORDER[source] < SOURCE_ORDER[player.source] then
    player.source = source
    changed = true
  end
  player.seen = self.env.now()

  if changed then
    self.env.onChange()
  end
end

--- Tells the guild and online friends that this player is here, and asks who else is
function Presence:Announce()
  self.lastAnnounce = self.env.now()
  self.announcements = self.announcements + 1
  self.env.broadcast(HI)
  local greet = self.env.greet or self.env.whisper

  for index, name in ipairs(self.env.friends()) do
    if index > MAX_FRIENDS then
      break
    end
    if name ~= self.env.me then
      greet(name, HI)
    end
  end
end

--- Call regularly. Forgets players who went quiet and announces again when it is time.
function Presence:Tick()
  local now = self.env.now()
  local changed = false
  for name, player in pairs(self.players) do
    if now - player.seen > EXPIRE_AFTER then
      self.players[name] = nil
      changed = true
    end
  end
  if changed then
    self.env.onChange()
  end

  local eager = next(self.players) == nil and self.announcements < EAGER_ANNOUNCEMENTS
  if not self.lastAnnounce or now - self.lastAnnounce >= (eager and EAGER_INTERVAL or ANNOUNCE_INTERVAL) then
    self:Announce()
  end
end

--- Handles a received payload if it is a presence message
--- @param sender string Full player name
--- @param text string
--- @param viaGuild boolean Whether it arrived on the guild channel
--- @return boolean handled False if the payload is not about presence
function Presence:Handle(sender, text, viaGuild)
  if text ~= HI and text ~= HEY and text ~= HEY_GUILD then
    return false
  end
  if sender == self.env.me then
    return true
  end

  if text == HI then
    self:mark(sender, viaGuild and "guild" or "friend")
    local now = self.env.now()
    if not self.replied[sender] or now - self.replied[sender] >= REPLY_COOLDOWN then
      self.replied[sender] = now
      -- Answers always go back as whispers, so say which greeting is being answered
      self.env.whisper(sender, viaGuild and HEY_GUILD or HEY)
    end
  else
    self:mark(sender, text == HEY_GUILD and "guild" or "friend")
  end
  return true
end

--- Notes that a player is evidently online with the addon, e.g. because they just made a move
--- @param name string
function Presence:Touch(name)
  self:mark(name, "other")
end

--- @param name string
function Presence:Remove(name)
  if self.players[name] then
    self.players[name] = nil
    self.env.onChange()
  end
end

--- Available players, guildies first, then friends, then by name
--- @return PresencePlayer[]
function Presence:List()
  local list = {}
  for _, player in pairs(self.players) do
    list[#list + 1] = player
  end
  table.sort(list, function(a, b)
    if a.source ~= b.source then
      return SOURCE_ORDER[a.source] < SOURCE_ORDER[b.source]
    end
    return a.name < b.name
  end)
  return list
end

--- @return { total: number, guild: number, friend: number, other: number }
function Presence:Counts()
  local counts = { total = 0, guild = 0, friend = 0, other = 0 }
  for _, player in pairs(self.players) do
    counts.total = counts.total + 1
    counts[player.source] = counts[player.source] + 1
  end
  return counts
end
