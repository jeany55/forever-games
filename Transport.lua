--------------------------
--  Transport
--------------------------
-- Carries session payloads between players as whispered addon messages, and watches for the
-- signals that say whether a retry is worth it: addon chat lockdown lifting, a player coming
-- online, or a whisper bouncing because the player is offline.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class TransportHandlers
--- @field onMessage fun(sender: string, text: string, viaGuild: boolean)
--- @field onReachable fun(peer: string?) Messages may get through again, to this player or to everyone
--- @field onOffline fun(peer: string)

--- @class Transport
local Transport = {}
private.Transport = Transport

-- Addon message prefixes are limited to 16 characters
local PREFIX = "ForeverGames"
-- How long after a whisper a "player not found" system message is taken to be about that whisper
local BOUNCE_WINDOW = 5

--- @type TransportHandlers
local handlers

-- Result codes by value, for readable log lines
local RESULT_NAMES = {}
for name, value in pairs(Enum.SendAddonMessageResult or {}) do
  RESULT_NAMES[value] = name
end

--- @param result any
--- @return string
local function resultName(result)
  return RESULT_NAMES[result] or tostring(result)
end
local frame = CreateFrame("Frame")
-- Last time each player was whispered, by short name
local lastWhisper = {}

--- Turns a global format string like "%s has come online." into a pattern capturing its arguments
--- @param format string?
--- @return string?
local function toPattern(format)
  if type(format) ~= "string" then
    return nil
  end
  local pattern = format:gsub("[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0"):gsub("%%s", "(.-)")
  return "^" .. pattern .. "$"
end

local NOT_FOUND = toPattern(ERR_CHAT_PLAYER_NOT_FOUND_S)
local CAME_ONLINE = toPattern(ERR_FRIEND_ONLINE_SS)
local WENT_OFFLINE = toPattern(ERR_FRIEND_OFFLINE_S)

--- @param name string
--- @return string
local function shortName(name)
  return (name:match("^[^-]+") or name):lower()
end

--- @return string
local function realm()
  return GetNormalizedRealmName() or (GetRealmName() or ""):gsub("[%s%-]", "")
end

--- Full "Name-Realm" form of a player name. Typed names are fixed up to the capitalisation the
--- game uses, since names are compared exactly. Only plain ASCII names can be fixed this way.
--- @param name string?
--- @return string?
function Transport.Normalize(name)
  if type(name) ~= "string" then
    return nil
  end
  name = name:gsub("%s", "")
  if name == "" then
    return nil
  end

  local character, characterRealm = name:match("^([^-]+)-(.+)$")
  character = character or name
  if not character:find("[\128-\255]") then
    character = character:sub(1, 1):upper() .. character:sub(2):lower()
  end
  return character .. "-" .. (characterRealm or realm())
end

--- @return string
function Transport.PlayerName()
  return UnitName("player") .. "-" .. realm()
end

--- Player name for display, without the realm when it is the player's own
--- @param name string
--- @return string
function Transport.DisplayName(name)
  local character, characterRealm = name:match("^([^-]+)-(.+)$")
  if character and characterRealm == realm() then
    return character
  end
  return name
end

--- Whether addon messages are currently blocked, as they are inside instances
--- @return boolean
function Transport.IsLocked()
  return C_ChatInfo.InChatMessagingLockdown ~= nil and C_ChatInfo.InChatMessagingLockdown() == true
end

--- @param target string Full player name
--- @param text string
--- @return boolean sent
function Transport.Send(target, text)
  if Transport.IsLocked() then
    private.Log("send held, lockdown:", target, text)
    return false
  end

  lastWhisper[shortName(target)] = GetTime()
  local result = C_ChatInfo.SendAddonMessage(PREFIX, text, "WHISPER", target)
  private.Log("send", target, text, "->", resultName(result))
  if result == true or result == Enum.SendAddonMessageResult.Success then
    return true
  end
  if result == Enum.SendAddonMessageResult.TargetOffline then
    handlers.onOffline(target)
  end
  return false
end

--- Sends to everyone in the player's guild
--- @param text string
function Transport.Broadcast(text)
  if IsInGuild() and not Transport.IsLocked() then
    local result = C_ChatInfo.SendAddonMessage(PREFIX, text, "GUILD")
    private.Log("send GUILD", text, "->", resultName(result))
  end
end

--- @return string[] Full names of the friends who are online
function Transport.OnlineFriends()
  local names = {}
  for index = 1, C_FriendList.GetNumFriends() do
    local info = C_FriendList.GetFriendInfoByIndex(index)
    if info and info.connected and info.name then
      names[#names + 1] = Transport.Normalize(info.name)
    end
  end
  return names
end

--- Name from a "player not found" message, if it is the bounce of one of our own whispers
--- @param text string
--- @return string?
local function bouncedWhisper(text)
  if (issecretvalue and issecretvalue(text)) or type(text) ~= "string" or not NOT_FOUND then
    return nil
  end
  local name = text:match(NOT_FOUND)
  local sentAt = name and lastWhisper[shortName(name)]
  if sentAt and GetTime() - sentAt < BOUNCE_WINDOW then
    return name
  end
  return nil
end

--- @param text string
local function onSystemMessage(text)
  if (issecretvalue and issecretvalue(text)) or type(text) ~= "string" then
    return
  end

  local bounced = bouncedWhisper(text)
  if bounced then
    private.Log("whisper bounced, player not found:", bounced)
    handlers.onOffline(Transport.Normalize(bounced))
    return
  end

  local online = CAME_ONLINE and text:match(CAME_ONLINE)
  if online then
    private.Log("came online:", online)
    handlers.onReachable(Transport.Normalize(online))
    return
  end

  local offline = WENT_OFFLINE and text:match(WENT_OFFLINE)
  if offline then
    private.Log("went offline:", offline)
    handlers.onOffline(Transport.Normalize(offline))
  end
end

--- Records where the player is and whether addon messages are blocked there
--- @param reason string
local function logSurroundings(reason)
  local inInstance, instanceType = IsInInstance()
  private.Log(reason, "zone:", GetRealZoneText() or "?", "instance:", tostring(inInstance), instanceType or "none", "locked:", tostring(Transport.IsLocked()))
end

--- @param newHandlers TransportHandlers
function Transport.Init(newHandlers)
  handlers = newHandlers
  C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

  frame:RegisterEvent("CHAT_MSG_ADDON")
  frame:RegisterEvent("CHAT_MSG_SYSTEM")
  frame:RegisterEvent("PLAYER_ENTERING_WORLD")
  -- Not every client build has the restriction events
  pcall(frame.RegisterEvent, frame, "ADDON_RESTRICTION_STATE_CHANGED")

  frame:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_ADDON" then
      local prefix, text, channel, sender = ...
      if prefix == PREFIX and issecretvalue and (issecretvalue(text) or issecretvalue(sender)) then
        -- Under lockdown the client may hand over a payload that can't be read
        private.Log("recv unreadable payload, lockdown")
      elseif prefix == PREFIX and (channel == "WHISPER" or channel == "GUILD") then
        private.Log("recv", channel, sender, text)
        handlers.onMessage(Transport.Normalize(sender), text, channel == "GUILD")
      end
    elseif event == "CHAT_MSG_SYSTEM" then
      onSystemMessage(...)
    elseif event == "PLAYER_ENTERING_WORLD" then
      logSurroundings("entered world,")
    elseif event == "ADDON_RESTRICTION_STATE_CHANGED" then
      local restriction, state = ...
      logSurroundings("restriction " .. tostring(restriction) .. " state " .. tostring(state) .. ",")
      if restriction == Enum.AddOnRestrictionType.Chat and state == Enum.AddOnRestrictionState.Inactive then
        -- The restriction is only really lifted once this event has finished dispatching
        C_Timer.After(1, function()
          handlers.onReachable()
        end)
      end
    end
  end)

  -- Whispering an addon message to an offline player prints an error in chat. Retries would
  -- otherwise fill the chat window with them.
  local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
  if addFilter then
    addFilter("CHAT_MSG_SYSTEM", function(_, _, text)
      return bouncedWhisper(text) ~= nil
    end)
  end
end
