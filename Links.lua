--------------------------
--  Links
--------------------------
-- Games that are open to whoever wants them, as links in chat.
--
-- The server only lets through the kinds of link it knows, so what is sent is plain text:
-- "[Forever Games: Chess]". Everyone with the addon has that turned into a link as it is shown
-- to them, one that remembers who said it. Clicking it asks that player for the game. Anyone
-- can type the same words, so the link itself promises nothing: whether there is a game to be
-- had is for whoever is asked to say.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local Games = private.Games

--- @class Links
local Links = {}
private.Links = Links

-- The same in every language, it is what the clients know each other's links by
local TITLE = "Forever Games"
local TEXT = "%[" .. TITLE .. ": ([^%[%]|]+)%]"
local LINK = "|cff71d5ff|Haddon:%s:%s:%s|h[" .. TITLE .. ": %s]|h|r"
local CLICKED = "^addon:" .. private.ADDON_NAME .. ":([^:]+):(.+)$"
-- Everywhere one player can say something to another, where it is known who said it
local EVENTS = {
  "CHAT_MSG_SAY",
  "CHAT_MSG_YELL",
  "CHAT_MSG_PARTY",
  "CHAT_MSG_PARTY_LEADER",
  "CHAT_MSG_RAID",
  "CHAT_MSG_RAID_LEADER",
  "CHAT_MSG_RAID_WARNING",
  "CHAT_MSG_INSTANCE_CHAT",
  "CHAT_MSG_INSTANCE_CHAT_LEADER",
  "CHAT_MSG_GUILD",
  "CHAT_MSG_OFFICER",
  "CHAT_MSG_WHISPER",
  "CHAT_MSG_CHANNEL",
}

--- What a player sends to link a game
--- @param game GameDefinition
--- @return string
function Links.Text(game)
  return "[" .. TITLE .. ": " .. game.name .. "]"
end

--- The game a link is to, going by what it says. Only a game two can play can be linked, or a
--- game for a room (Engine/Rooms.lua), where the link is to the room whoever said it is host of
--- @param name string
--- @return GameDefinition|PartyGame?
function Links.Find(name)
  name = name:lower()
  for _, game in ipairs(Games.List()) do
    if (game.name:lower() == name or game.id == name) and Games.CanSeat(game, 2) then
      return game
    end
  end
  for _, game in ipairs(private.Rooms.Games()) do
    if game.name:lower() == name or game.id == name then
      return game
    end
  end
  return nil
end

--- Turns the games linked in something a player said into links that can be clicked
--- @param text string
--- @param host string Full name of whoever said it
--- @return string? nil if there is nothing in it to link
function Links.Decorate(text, host)
  local found = false
  local decorated = text:gsub(TEXT, function(name)
    local game = Links.Find(name)
    if not game then
      return nil
    end
    found = true
    return LINK:format(private.ADDON_NAME, game.id, host, game.name)
  end)
  return found and decorated or nil
end

--- @param link string What the client says was clicked
--- @return string? host Full name of whoever linked the game, nil if the link isn't one of ours
--- @return string? gameId
function Links.Parse(link)
  local gameId, host = link:match(CLICKED)
  return host, gameId
end

--- Puts the link to a game where the player is typing, or starts a line of chat with it
--- @param game GameDefinition|PartyGame
function Links.Insert(game)
  local text = Links.Text(game)
  local insert = (ChatFrameUtil and ChatFrameUtil.InsertLink) or ChatEdit_InsertLink
  if not (insert and insert(text)) then
    local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
    open(text)
  end
end

--- @param onClick fun(host: string, gameId: string) Called when a link to a game is clicked
function Links.Init(onClick)
  local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
  if not addFilter or not EventRegistry then
    return
  end

  local function filter(_, _, text, sender, ...)
    -- Under lockdown the client may hand over a line that can't be read
    local unreadable = issecretvalue and (issecretvalue(text) or issecretvalue(sender))
    if unreadable or type(text) ~= "string" or type(sender) ~= "string" then
      return false
    end
    local host = private.Transport.Normalize(sender)
    local decorated = host and Links.Decorate(text, host)
    if decorated then
      return false, decorated, sender, ...
    end
    return false
  end
  for _, event in ipairs(EVENTS) do
    addFilter(event, filter)
  end

  -- What the client does with a link of the kind that is there for addons
  EventRegistry:RegisterCallback("SetItemRef", function(_, link)
    local host, gameId = Links.Parse(link)
    if host then
      onClick(host, gameId)
    end
  end, Links)
end
