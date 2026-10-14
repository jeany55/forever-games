--------------------------
--  Forever Games Core
--------------------------
-- Wires the engine to the game client: saved data, the transport, notifications and commands.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Games = private.Games
local Match = private.Match
local Transport = private.Transport
local Links = private.Links
local Toast = private.Toast
local MainFrame = private.MainFrame
local Party = private.Party
local Rooms = private.Rooms
local Options = private.Options

--- @class ForeverGames: AceAddon-3.0, AceConsole-3.0, AceEvent-3.0
--- @field db AceDBObject-3.0
ForeverGames = LibStub("AceAddon-3.0"):NewAddon(private.ADDON_NAME, "AceConsole-3.0", "AceEvent-3.0")

-- How often undelivered moves are retried. The session spaces out retries per opponent on top of this.
local FLUSH_INTERVAL = 15
-- How often a room sends what is waiting and its game looks at the clock
local ROOM_BEAT = 0.25
-- Wait for the client to settle after login before announcing ourselves
local HELLO_DELAY = 5
-- Lines shown by /fg log
local LOG_LINES = 20

local defaults = {
  -- Matches belong to the character that is playing them
  char = { matches = {}, log = {}, offers = {} },
  profile = {
    minimap = { hide = false },
    -- Whether a turn that comes up is shown, and whether it is heard
    toasts = true,
    alert = true,
    -- Whether that happens in the middle of a fight, or waits for it to end
    combat = false,
    -- Whether that waits for the player to be out of a dungeon, raid or battleground
    quiet = false,
    -- What the games themselves sound like: cards, dice, pieces
    sound = true,
    -- Who the player takes challenges from: "anyone", or only "known" friends and guildmates
    challenges = "anyone",
    -- Whether a wisp drifts around the logo on the window's front page, its letters shine and the
    -- light behind it drifts
    wisp = true,
    -- The scale is in hundredths of the window's usual size
    window = { width = 920, height = 680, scale = 100 },
    -- Ids of the games the player starred in the new game wizard
    favourites = {},
    -- How the player last set the rules of each game in the wizard, by game id
    rules = {},
    -- The best the player ever did at the games played alone, by game id
    records = {},
    -- Whether the window of the games for a room is small, and where each size of it was left
    party = { mini = false },
    -- The questions of Trivia this player asked as a host, and when, see Games/Trivia.lua
    trivia = { serial = 0, ids = {} },
  },
}

local dataObject

function ForeverGames:OnInitialize()
  self.db = LibStub("AceDB-3.0"):New("ForeverGamesDB", defaults, true)
  private.UseLog(self.db.char.log)
  self:RegisterChatCommand("fg", "HandleSlashCommand")
  self:RegisterChatCommand("forevergames", "HandleSlashCommand")
end

function ForeverGames:OnEnable()
  private.Log("login", C_AddOns.GetAddOnMetadata(private.ADDON_NAME, "Version"), Transport.PlayerName(), "guild:", tostring(IsInGuild()))
  private.Log("realm:", tostring(GetRealmName()), "normalized:", tostring(GetNormalizedRealmName()), "id:", tostring(GetRealmID and GetRealmID()))

  private.session = private.Session.New({
    me = Transport.PlayerName(),
    matches = self.db.char.matches,
    records = self.db.profile.records,
    offers = self.db.char.offers,
    onRefused = function(host, gameId, reason)
      local game = Games.Get(gameId)
      local text = L[reason == "offline" and "link_offline" or (reason == "version" and "link_version" or "link_closed")]
      self:Print(text:format(Transport.DisplayName(host), game and game.name or gameId))
    end,
    takes = function(sender)
      return self.db.profile.challenges ~= "known" or Transport.IsFriendOrGuildmate(sender)
    end,
    send = Transport.Send,
    now = time,
    random = math.random,
    notify = function(event, match)
      self:OnMatchEvent(event, match)
    end,
  })

  private.presence = private.Presence.New({
    me = Transport.PlayerName(),
    now = time,
    broadcast = Transport.Broadcast,
    whisper = Transport.Send,
    greet = Transport.SendSlowly,
    friends = Transport.OnlineFriends,
    onChange = function()
      MainFrame.Refresh()
    end,
  })

  private.Trivia.asked = self.db.profile.trivia
  private.rooms = Rooms.New({
    me = Transport.PlayerName(),
    now = GetTime,
    random = math.random,
    broadcast = Transport.BroadcastTo,
    send = Transport.Send,
    onChannel = Transport.OnChannel,
    reaches = Transport.Reaches,
    notify = function(event, subject)
      self:OnRoomEvent(event, subject)
    end,
  })

  Transport.Init({
    onMessage = function(sender, text, viaGuild, channel)
      if private.rooms:Handle(sender, text, channel) then
        return
      end
      -- Nothing but a room is ever talked about in a group
      if channel == "GROUP" or private.presence:Handle(sender, text, viaGuild) then
        return
      end
      -- Games are only ever played over whispers
      if not viaGuild then
        private.presence:Touch(sender)
        private.session:Receive(sender, text)
      end
    end,
    onReachable = function(peer)
      private.session:Wake(peer)
    end,
    onOffline = function(peer)
      private.presence:Remove(peer)
      private.session:PeerOffline(peer)
      private.rooms:PeerOffline(peer)
    end,
  })

  -- A game for a room may stop for a fight, and keep out of its way
  self:RegisterEvent("PLAYER_REGEN_DISABLED", function()
    private.rooms:Fighting(true)
    Party.Refresh()
  end)
  self:RegisterEvent("PLAYER_REGEN_ENABLED", function()
    private.rooms:Fighting(false)
    Party.Refresh()
  end)

  Links.Init(function(host, gameId)
    self:OnLinkClicked(host, gameId)
  end)

  Options.Init()
  self:RegisterMinimapIcon()
  self:UpdateAttention()

  C_Timer.After(HELLO_DELAY, function()
    private.presence:Announce()
    private.session:Hello()
  end)
  C_Timer.NewTicker(FLUSH_INTERVAL, function()
    private.presence:Tick()
    private.session:Flush()
  end)
  C_Timer.NewTicker(ROOM_BEAT, function()
    private.rooms:Tick()
  end)
end

-----------------------------
-- Notifications
-----------------------------

--- @param match Match
--- @return string
local function gameName(match)
  local game = Games.Get(match.game)
  return game and game.name or match.game
end

--- Text for the toast an event deserves, nil if it doesn't deserve one
--- @param event string
--- @param match Match
--- @return string?
local function toastText(event, match)
  local opponent = MainFrame.Names(match)
  if event == "invite" then
    return L["toast_invite"]:format(MainFrame.Names(match, { Match.Inviter(match) }), gameName(match))
  elseif (event == "accepted" or event == "started") and not Match.IsMyTurn(match) then
    if #match.players > 2 then
      return L["toast_started"]:format(gameName(match), opponent)
    end
    return L["toast_accepted"]:format(opponent, gameName(match))
  elseif event == "moved" and not Match.IsMyTurn(match) then
    -- They moved and it still isn't this player's turn, nothing to do yet
    return nil
  elseif event == "accepted" or event == "started" or event == "moved" then
    return L["toast_your_turn"]:format(gameName(match), opponent)
  elseif event == "draw" then
    return L["toast_draw"]:format(opponent, gameName(match))
  elseif event == "finished" or event == "declined" then
    return gameName(match) .. ": " .. MainFrame.Describe(match)
  end
  return nil
end

--- Called by the session whenever a match changes
--- @param event string
--- @param match Match
function ForeverGames:OnMatchEvent(event, match)
  local acked = {}
  for _, seat in ipairs(Match.Others(match)) do
    acked[#acked + 1] = match.seen[seat] or 0
  end
  local players = "seat " .. match.me .. " of " .. table.concat(match.players, ",")
  private.Log("match", event, match.id, match.game, players, match.status, "entries:", #match.log, "acked:", table.concat(acked, ","))

  if event == "joined" then
    -- The player clicked a link to get here, the game is what they are waiting to see
    MainFrame.Open(match.id)
  end

  local text = toastText(event, match)
  if text and not MainFrame.IsViewing(match.id) then
    -- Shown, heard, both or neither, and when: that is the player's to say, see GUI/Options.lua
    Toast.Show(text, function()
      MainFrame.Open(match.id)
    end)
  end

  MainFrame.Refresh()
  self:UpdateAttention()
end

--- Called by the rooms whenever something happens to one
--- @param event string
--- @param subject any The room, or what is known of somebody else's, or why the player wasn't let in
function ForeverGames:OnRoomEvent(event, subject)
  if event == "open" then
    --- @type RoomInfo
    local info = subject
    local game = Rooms.Game(info.game)
    private.Log("room heard of", info.id, info.game, info.host, tostring(info.channel), "invited:", tostring(info.invited))
    -- Strangers get to ask the player in only if the player takes challenges from them
    local welcome = info.onChannel or self.db.profile.challenges ~= "known" or Transport.IsFriendOrGuildmate(info.host)
    if game and welcome and not private.rooms.room and not Party.IsOpen() then
      local text = L[info.invited and "toast_room_invited" or "toast_room"]:format(Transport.DisplayName(info.host), game.name)
      Toast.Show(text, function()
        local ok, err = private.rooms:Join(info.id)
        if not ok then
          self:Print(L["err_" .. err])
        end
        Party.Open()
      end)
    end
  elseif event == "refused" then
    self:Print(L["room_refused_" .. subject])
  elseif event == "joined" then
    private.Log("room joined", subject.id, subject.game, subject.host, tostring(subject.channel))
    Party.Open()
  elseif event == "closed" then
    private.Log("room left", subject.id, subject.closed)
    if subject.closed ~= "left" then
      self:Print(L["room_" .. subject.closed]:format(Transport.DisplayName(subject.host)))
    end
  end
  -- What only changes what the game shows is seen at the window's next beat
  if event ~= "changed" then
    Party.Refresh()
  end
  -- The front page has a way back to the room for as long as there is one
  if event == "joined" or event == "closed" then
    MainFrame.Refresh()
  end
end

--- A link to a game someone left open was clicked
--- @param host string Full name of whoever linked it
--- @param gameId string
function ForeverGames:OnLinkClicked(host, gameId)
  -- A link to a game for a room is to the room
  local party = Rooms.Game(gameId)
  if party then
    local ok, err = private.rooms:Knock(host, gameId)
    if ok then
      self:Print(L["room_knocking"]:format(Transport.DisplayName(host), party.name))
    else
      self:Print(L["err_" .. err])
    end
    return
  end
  local game = Games.Get(gameId)
  local name = game and game.name or gameId
  if host == Transport.PlayerName() then
    return self:Print(L[private.session:Offered(gameId) and "link_own_open" or "link_own_closed"]:format(name))
  end
  local ok, err = private.session:Ask(host, gameId)
  if ok then
    self:Print(L["link_asking"]:format(Transport.DisplayName(host), name))
  else
    self:Print(L["err_" .. err])
  end
end

--- Shows how many matches are waiting on the player next to the minimap icon's data broker entry
function ForeverGames:UpdateAttention()
  if not dataObject then
    return
  end
  local count = private.session:AttentionCount()
  dataObject.text = count > 0 and ("|cff4de64d" .. count .. "|r") or "0"
end

function ForeverGames:RegisterMinimapIcon()
  dataObject = LibStub("LibDataBroker-1.1"):NewDataObject(private.ADDON_NAME, {
    type = "data source",
    label = L["title"],
    text = "0",
    icon = private.ICON,
    OnClick = function(_, button)
      if button == "RightButton" then
        self:OpenOptions()
      else
        MainFrame.Toggle()
      end
    end,
    OnTooltipShow = function(tooltip)
      local count = private.session:AttentionCount()
      tooltip:AddLine(L["title"])
      if count > 0 then
        tooltip:AddLine(L["tooltip_attention"]:format(count), 0.3, 0.9, 0.3)
      else
        tooltip:AddLine(L["tooltip_nothing"], 0.7, 0.7, 0.7)
      end
      tooltip:AddLine(" ")
      tooltip:AddLine(L["tooltip_left_click"], 1, 1, 1)
      tooltip:AddLine(L["tooltip_right_click"], 1, 1, 1)
    end,
  })
  LibStub("LibDBIcon-1.0"):Register(private.ADDON_NAME, dataObject, self.db.profile.minimap)
end

-----------------------------
-- Commands
-----------------------------

--- Prints the end of the log to chat, or empties it
--- @param argument string "clear", or how many lines to show
function ForeverGames:PrintLog(argument)
  local entries = private.LogEntries()
  if argument == "clear" then
    for index = #entries, 1, -1 do
      entries[index] = nil
    end
    return self:Print(L["log_cleared"])
  end

  local count = math.min(#entries, tonumber(argument) or LOG_LINES)
  for index = #entries - count + 1, #entries do
    print("|cff808080" .. entries[index] .. "|r")
  end
  self:Print(L["log_shown"]:format(count, #entries))
end

function ForeverGames:OpenOptions()
  local ok, err = Options.Open()
  if not ok then
    self:Print(L["err_" .. err])
  end
end

--- @param input string
function ForeverGames:HandleSlashCommand(input)
  local command, argument = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
  command = command:lower()

  if command == "" then
    MainFrame.Toggle()
  elseif command == "new" then
    MainFrame.NewGame()
  elseif command == "party" or command == "room" then
    Party.Toggle()
  elseif command == "options" or command == "config" or command == "settings" then
    self:OpenOptions()
  elseif command == "log" then
    self:PrintLog(argument)
  elseif command == "play" then
    -- A game to play alone: the one that is named, or the first there is
    local wanted, game = argument:lower(), nil
    for _, candidate in ipairs(Games.List()) do
      local named = wanted == "" or wanted == candidate.id or wanted == candidate.name:lower()
      if not game and named and Games.CanSeat(candidate, 1) then
        game = candidate
      end
    end
    -- Set up the way the player last set it up in the wizard
    local match, err = private.session:Invite({}, game and game.id, { options = game and self.db.profile.rules[game.id] })
    if match then
      MainFrame.Open(match.id)
    else
      self:Print(L["err_" .. err])
    end
  elseif command == "challenge" or command == "invite" then
    -- Names can be more than one word, so the game is whatever game name the argument ends with
    local target, game = argument, Games.List()[1]
    for _, candidate in ipairs(Games.List()) do
      for _, label in ipairs({ candidate.id, candidate.name:lower() }) do
        local suffix = " " .. label
        if #argument > #suffix and argument:lower():sub(-#suffix) == suffix then
          target, game = argument:sub(1, -#suffix - 1), candidate
        end
      end
    end
    local match, err = private.session:Invite(Transport.Normalize(target), game and game.id)
    if match then
      MainFrame.Open(match.id)
    else
      self:Print(L["err_" .. err])
    end
  else
    self:Print(L["help_usage"])
  end
end
