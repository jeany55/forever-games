--------------------------
--  Transport
--------------------------
-- Carries session payloads between players, and watches for the signals that say whether a retry
-- is worth it: addon chat lockdown lifting, a player coming online, or a whisper bouncing because
-- the player is offline.
--
-- There are two routes to a player. Battle.net friends are reached through Battle.net game data,
-- which doesn't care about realm or faction. Everyone else gets a whispered addon message.

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
-- Battle.net game accounts of friends who are in game, by full character name and the reverse
local gameAccounts = {}
local accountNames = {}

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
--- Character names on Forever can be more than one word ("Quets Al"), so spaces inside are kept.
--- @param name string?
--- @return string?
function Transport.Normalize(name)
  if type(name) ~= "string" then
    return nil
  end
  name = name:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
  if name == "" then
    return nil
  end

  local character, characterRealm = name:match("^([^-]*)-(.*)$")
  character = (character or name):gsub("%s+$", "")
  if character == "" then
    return nil
  end
  if not character:find("[\128-\255]") then
    character = character:lower():gsub("%f[%a]%a", string.upper)
  end
  -- Realms are always written without spaces
  characterRealm = characterRealm and characterRealm:gsub("%s", "")
  if characterRealm == "" then
    characterRealm = nil
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
--- @param result any
--- @return boolean
local function succeeded(result)
  return result == true or result == Enum.SendAddonMessageResult.Success
end

--- @param target string Full player name
--- @param text string
--- @return boolean sent
local function sendBattleNet(target, text)
  local account = gameAccounts[target]
  if not account then
    return false
  end
  local result = C_BattleNet.SendGameData(account, PREFIX, text)
  private.Log("send battle.net", target, text, "->", resultName(result))
  return succeeded(result)
end

--- @param target string Full player name
--- @param text string
--- @return boolean sent
local function sendWhisper(target, text)
  -- Players on the same realm are whispered by bare name, the realm suffix is only for others
  local name = Transport.DisplayName(target)
  lastWhisper[shortName(target)] = GetTime()
  local result = C_ChatInfo.SendAddonMessage(PREFIX, text, "WHISPER", name)
  private.Log("send whisper", name, text, "->", resultName(result))
  if result == Enum.SendAddonMessageResult.TargetOffline and not gameAccounts[target] then
    handlers.onOffline(target)
  end
  return succeeded(result)
end

--- @param target string Full player name
--- @param text string
--- @return boolean sent
function Transport.Send(target, text)
  if Transport.IsLocked() then
    private.Log("send held, lockdown:", target, text)
    return false
  end
  return sendBattleNet(target, text) or sendWhisper(target, text)
end

--- Sends by every route there is. For greetings, where it isn't known yet which route works
--- and an extra copy does no harm.
--- @param target string Full player name
--- @param text string
function Transport.SendEveryWay(target, text)
  if Transport.IsLocked() then
    return
  end
  sendBattleNet(target, text)
  sendWhisper(target, text)
end

--- Sends to everyone in the player's guild
--- @param text string
function Transport.Broadcast(text)
  if IsInGuild() and not Transport.IsLocked() then
    local result = C_ChatInfo.SendAddonMessage(PREFIX, text, "GUILD")
    private.Log("send GUILD", text, "->", resultName(result))
  end
end

--- Whispers that can wait, sent one a second. Greeting a long friends list all at once would
--- run into the addon message throttle and hold up moves.
local slowQueue = {}
local slowTicker

--- @param target string Full player name
--- @param text string
function Transport.SendSlowly(target, text)
  slowQueue[#slowQueue + 1] = { target = target, text = text }
  if slowTicker then
    return
  end
  slowTicker = C_Timer.NewTicker(1, function()
    local message = table.remove(slowQueue, 1)
    if message then
      Transport.SendEveryWay(message.target, message.text)
    end
    if #slowQueue == 0 and slowTicker then
      slowTicker:Cancel()
      slowTicker = nil
    end
  end)
end

--- Characters that Battle.net friends are playing right now in this version of the game
--- @param add fun(name: string)
--- @return number found
local function battleNetFriends(add)
  if not (BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendNumGameAccounts) then
    return 0
  end

  local found = 0
  local total, online = BNGetNumFriends()
  private.Log("Battle.net friends:", tostring(total), "total,", tostring(online), "online, this game is project", tostring(WOW_PROJECT_ID))
  for friend = 1, total or 0 do
    for account = 1, C_BattleNet.GetFriendNumGameAccounts(friend) or 0 do
      local info = C_BattleNet.GetFriendGameAccountInfo(friend, account)
      local playing = info and info.isOnline and info.clientProgram == BNET_CLIENT_WOW and info.wowProjectID == WOW_PROJECT_ID
      local hasCharacter = info and info.characterName and info.characterName ~= ""
      local hasRealm = info and info.realmName and info.realmName ~= ""
      if info and info.isOnline then
        -- No names in the log, just enough to see why a friend was or wasn't greeted
        private.Log(
          "Battle.net friend",
          friend,
          "is in",
          tostring(info.clientProgram),
          "project",
          tostring(info.wowProjectID),
          "faction",
          tostring(info.factionName),
          hasCharacter and "character known," or "character unknown,",
          hasRealm and "realm known" or "realm unknown",
          (playing and hasCharacter) and "-> greeting" or "-> skipped",
          "as",
          tostring(info.characterName),
          tostring(info.realmName),
          tostring(info.realmDisplayName),
          tostring(info.realmID)
        )
      end
      if playing and hasCharacter then
        -- Without a realm the friend is taken to be on the player's own
        local name = Transport.Normalize(hasRealm and (info.characterName .. "-" .. info.realmName) or info.characterName)
        gameAccounts[name] = info.gameAccountID
        accountNames[info.gameAccountID] = name
        add(name)
        found = found + 1
      end
    end
  end
  return found
end

--- Friends who are online: the character friends list plus Battle.net friends playing this game
--- @return string[] Full names
function Transport.OnlineFriends()
  local names, seen = {}, {}
  local function add(name)
    name = Transport.Normalize(name)
    if name and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end

  local total, characters = C_FriendList.GetNumFriends() or 0, 0
  for index = 1, total do
    local info = C_FriendList.GetFriendInfoByIndex(index)
    if info and info.connected and info.name then
      add(info.name)
      characters = characters + 1
    end
  end
  local battleNet = battleNetFriends(add)

  private.Log("friends online:", characters, "of", total, "character friends,", battleNet, "Battle.net friends in game, guild:", tostring(IsInGuild()))
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
    local name = Transport.Normalize(bounced)
    private.Log("whisper bounced, player not found:", bounced)
    -- A Battle.net friend can still be reached the other way
    if not gameAccounts[name] then
      handlers.onOffline(name)
    end
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

--- Full character name behind a Battle.net game account, remembered so answers go back the same way
--- @param account number
--- @return string?
local function nameOfAccount(account)
  if accountNames[account] then
    return accountNames[account]
  end
  local info = C_BattleNet.GetGameAccountInfoByID(account)
  if not info or not info.characterName or info.characterName == "" then
    return nil
  end
  local hasRealm = info.realmName and info.realmName ~= ""
  local name = Transport.Normalize(hasRealm and (info.characterName .. "-" .. info.realmName) or info.characterName)
  gameAccounts[name] = account
  accountNames[account] = name
  return name
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
  frame:RegisterEvent("BN_CHAT_MSG_ADDON")
  frame:RegisterEvent("CHAT_MSG_SYSTEM")
  frame:RegisterEvent("PLAYER_ENTERING_WORLD")
  -- The friends list is only filled in once the client has asked the server for it
  C_FriendList.ShowFriends()
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
    elseif event == "BN_CHAT_MSG_ADDON" then
      local prefix, text, _, account = ...
      if prefix == PREFIX then
        local sender = nameOfAccount(account)
        private.Log("recv battle.net", tostring(sender), text)
        if sender then
          handlers.onMessage(sender, text, false)
        end
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
