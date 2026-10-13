--------------------------
--  Presence
--------------------------
-- Keeps track of who is online with the addon right now, so the player can see who they could
-- challenge. At login, when the window opens and whenever the player asks, they say hi to their
-- guild and to their online friends, and everyone who has the addon answers.
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
--- @field settled boolean? Whether the last refresh has been tidied up after
local Presence = {}
Presence.__index = Presence
private.Presence = Presence

local HI = private.Codec.PROTOCOL_VERSION .. ":HI"
local HEY = private.Codec.PROTOCOL_VERSION .. ":HEY"
local HEY_GUILD = HEY .. ":G"

-- How long players get to answer a refresh before the ones who didn't are dropped. Friends are
-- greeted one a second, so this has to cover a long friends list.
local ANSWER_WINDOW = 60
-- Shortest time between two refreshes
local REFRESH_COOLDOWN = 10
-- Someone in both the guild and the friends list is greeted twice, answer once
local REPLY_COOLDOWN = 5
local MAX_FRIENDS = 40

local SOURCE_ORDER = { guild = 1, friend = 2, other = 3 }

--- @param env PresenceEnv
--- @return Presence
function Presence.New(env)
  return setmetatable({ env = env, players = {}, replied = {} }, Presence)
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
  elseif source == "guild" and player.source ~= "guild" then
    -- Being a guildie is the one thing worth correcting, an opponent answering a greeting stays an opponent
    player.source = source
    changed = true
  end
  player.seen = self.env.now()

  if changed then
    self.env.onChange()
  end
end

--- Asks who is around: greets the guild, online friends and everyone already known. Players
--- who don't answer are dropped once they have had time to. Nothing calls this on a timer, it
--- runs at login, when the window opens and when the player asks for a refresh.
function Presence:Announce()
  self.lastAnnounce = self.env.now()
  self.settled = false
  self.env.broadcast(HI)
  local greet = self.env.greet or self.env.whisper

  local greeted = {}
  for index, name in ipairs(self.env.friends()) do
    if index > MAX_FRIENDS then
      break
    end
    if name ~= self.env.me then
      greeted[name] = true
      greet(name, HI)
    end
  end
  -- Guildies hear the broadcast, anyone else already listed has to be asked directly
  for name, player in pairs(self.players) do
    if player.source ~= "guild" and not greeted[name] then
      greet(name, HI)
    end
  end
end

--- Whether enough time has passed since the last refresh to ask again
--- @return boolean
function Presence:CanAnnounce()
  return not self.lastAnnounce or self.env.now() - self.lastAnnounce >= REFRESH_COOLDOWN
end

--- @return number? Seconds since the last refresh, nil if there hasn't been one
function Presence:SinceAnnounce()
  return self.lastAnnounce and self.env.now() - self.lastAnnounce
end

--- Call regularly. Once a refresh has had time to be answered, drops the players who stayed silent.
function Presence:Tick()
  if self.settled or not self.lastAnnounce or self.env.now() - self.lastAnnounce < ANSWER_WINDOW then
    return
  end
  self.settled = true

  local changed = false
  for name, player in pairs(self.players) do
    if player.seen < self.lastAnnounce then
      self.players[name] = nil
      changed = true
    end
  end
  if changed then
    self.env.onChange()
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
