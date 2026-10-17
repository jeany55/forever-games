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
-- A link can say a little more after the game's name, "[Forever Games: Freedoom - 1:23.45]": the
-- time of the best that is raced, say. It is only there to be read.
-- Pointed at, a link says what it is to and what clicking it does. The player's own says
-- whether it is still open.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Games = private.Games
local Race = private.Race

--- @class Links
local Links = {}
private.Links = Links

-- The same in every language, it is what the clients know each other's links by
local TITLE = "Forever Games"
-- Between the game's name and what the link says besides
local NOTE = " - "
local NOTED = "^(.-) %- (.+)$"
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
--- @param note string? What the link says besides
--- @return string
function Links.Text(game, note)
  return "[" .. TITLE .. ": " .. game.name .. (note and NOTE .. note or "") .. "]"
end

--- The game a link is to, going by what it says. Only a game two can play can be linked, a game
--- for one that can be raced (Engine/Race.lua), where the link is to a race, or a game for a room
--- (Engine/Rooms.lua), where the link is to the room whoever said it is host of
--- @param name string
--- @return GameDefinition|PartyGame?
function Links.Find(name)
  name = name:lower()
  for _, game in ipairs(Games.List()) do
    if (game.name:lower() == name or game.id == name) and (Games.CanSeat(game, 2) or Race.Has(game)) then
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
  local decorated = text:gsub(TEXT, function(said)
    local game, note = Links.Find(said), nil
    if not game then
      local name, rest = said:match(NOTED)
      game, note = name and Links.Find(name), rest
    end
    if not game then
      return nil
    end
    found = true
    return LINK:format(private.ADDON_NAME, game.id, host, game.name .. (note and NOTE .. note or ""))
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
--- @param note string? What the link says besides
function Links.Insert(game, note)
  local text = Links.Text(game, note)
  local insert = (ChatFrameUtil and ChatFrameUtil.InsertLink) or ChatEdit_InsertLink
  if not (insert and insert(text)) then
    local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
    open(text)
  end
end

--- Leaves a game open to whoever clicks a link to it and hands the player the link: a game for
--- two, or a race at a game for one, by the rules it is given or the way the player last set it
--- up in the wizard. A race is against the player's best where they have one that can be sent,
--- and its link says how long it took. A game for a room is linked as the room the player is host
--- of, there being nothing to leave open without one
--- @param game GameDefinition|PartyGame
--- @param setup { options: table<string, any>?, seat: number?, best: boolean? }? As for Session:Offer
--- @return boolean ok, string? error
function Links.Share(game, setup)
  if private.Rooms.Game(game.id) == game then
    local room = private.rooms and private.rooms.room
    if not room or room.game ~= game.id or not private.rooms:Link() then
      return false, "no_room"
    end
    Links.Insert(game)
    ForeverGames:Print(L["party_link_ready"]:format(game.name))
    return true
  end
  local race = Race.Has(game)
  if not setup then
    local last = ForeverGames.db.profile.rules
    local options = Games.ForPlayers(game, Games.Rules(game.options, last and last[game.id]), race and 1 or 2)
    setup = { options = options, best = race and private.session:BestToRace(game.id, options) ~= nil or nil }
  end
  local offered, err = private.session:Offer(game.id, setup)
  if not offered then
    return false, err
  end
  local best = race and setup.best and private.session:BestToRace(game.id, setup.options)
  Links.Insert(offered, best and private.MainFrame.RaceTime(math.floor(best * 100 + 0.5)) or nil)
  ForeverGames:Print(L[race and "link_ready_race" or "link_ready"]:format(offered.name))
  return true
end

--- How many minutes there are left of a game open in chat, as said to the player: never none
--- while it is still open
--- @param seconds number
--- @return number
function Links.Minutes(seconds)
  return math.max(1, math.ceil(seconds / 60))
end

--- What pointing at a link says: what it is to, then what clicking it does
--- @param host string Full name of whoever linked the game
--- @param gameId string
--- @return string? title nil if there is no such game here
--- @return string[] lines
function Links.Describe(host, gameId)
  local Transport = private.Transport
  local party = private.Rooms.Game(gameId)
  local game = party or Games.Get(gameId)
  if not game then
    return nil, {}
  end
  local lines = { game.description }
  local mine = Transport.IsMe(host)
  if party then
    lines[#lines + 1] = mine and L["link_tip_own_room"] or L["link_tip_room"]:format(Transport.DisplayName(host))
  elseif mine then
    local left = private.session:OfferLeft(gameId)
    if left then
      lines[#lines + 1] = L["link_tip_own_open"]:format(Links.Minutes(left))
    else
      lines[#lines + 1] = L["link_tip_own_closed"]
    end
  else
    lines[#lines + 1] = L[Race.Has(game) and "link_tip_race" or "link_tip_play"]:format(Transport.DisplayName(host))
  end
  return game.name, lines
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
    -- Who said it by the name they are heard by, and the player's own name for their own line
    local host = private.Transport.Sender(sender)
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

  -- Pointed at, in every chat window: the ones there from the start and the ones a whisper opens
  local describing = false
  local function enter(chatFrame, link)
    local host, gameId = Links.Parse(link)
    if not host then
      return
    end
    local title, lines = Links.Describe(host, gameId)
    if not title then
      return
    end
    GameTooltip:SetOwner(chatFrame, "ANCHOR_CURSOR")
    GameTooltip:SetText(title)
    for index, line in ipairs(lines) do
      -- What it is in grey, what clicking does in white
      local shade = index < #lines and 0.7 or 1
      GameTooltip:AddLine(line, shade, shade, shade, true)
    end
    GameTooltip:Show()
    describing = true
  end
  local function leave()
    if describing then
      describing = false
      GameTooltip:Hide()
    end
  end
  local hooked = {}
  local function hook(chatFrame)
    if chatFrame and chatFrame.HookScript and not hooked[chatFrame] then
      hooked[chatFrame] = true
      chatFrame:HookScript("OnHyperlinkEnter", enter)
      chatFrame:HookScript("OnHyperlinkLeave", leave)
    end
  end
  for index = 1, NUM_CHAT_WINDOWS or 0 do
    hook(_G["ChatFrame" .. index])
  end
  if FCF_OpenTemporaryWindow then
    hooksecurefunc("FCF_OpenTemporaryWindow", function()
      for _, name in ipairs(CHAT_FRAMES or {}) do
        hook(_G[name])
      end
    end)
  end
end
