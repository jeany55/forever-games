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
-- How many milliseconds a frame the computer may think for the tables of people it sits at, when
-- they aren't on screen. Less than the window gives it: the player is doing something else
local DRIVE_MS = 3
-- Wait for the client to settle after login before announcing ourselves
local HELLO_DELAY = 5
-- Lines shown by /fg log
local LOG_LINES = 20

--- The date in UTC, which is when a day's challenge begins and ends for the whole guild
--- @return string
local function today()
  return date("!%Y-%m-%d")
end

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
    -- The runs that set them, for a game with a ghost to race next time, by game id and key
    ghosts = {},
    -- How the player's games against the computer went, by game id and level
    versus = {},
    -- How the player last set up a game against the computer in the wizard, by game id
    computer = {},
    -- The last day each game's challenge was taken on, by game id, so that every character
    -- has the one go at it between them
    dailies = {},
    -- What the guild made of the challenges of the last few days, see Engine/Daily.lua
    boards = {},
    -- Whether the window of the games for a room is small, and where each size of it was left
    party = { mini = false },
    -- The questions of Trivia this player asked as a host, and when, see Games/Trivia.lua
    trivia = { serial = 0, ids = {} },
  },
}

local dataObject

function ForeverGames:OnInitialize()
  -- A game that needs an addon of its own is only offered while that addon can be loaded: there,
  -- switched on, and fit for this client
  Games.SetAddOnCheck(function(addon)
    local loadable = C_AddOns and C_AddOns.IsAddOnLoadable
    if not loadable then
      return true
    end
    local ok, can = pcall(loadable, addon, UnitName("player"), true)
    return ok and can == true
  end)
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
    ghosts = self.db.profile.ghosts,
    versus = self.db.profile.versus,
    offers = self.db.char.offers,
    onRefused = function(host, gameId, reason)
      local game = Games.Get(gameId)
      local text = L[reason == "offline" and "link_offline" or reason == "version" and "link_version" or reason == "taken" and "link_taken" or "link_closed"]
      self:Print(text:format(Transport.DisplayName(host), game and game.name or gameId))
    end,
    takes = function(sender)
      return self.db.profile.challenges ~= "known" or Transport.IsFriendOrGuildmate(sender)
    end,
    send = Transport.Send,
    named = Transport.Named,
    namedMe = Transport.NamedMe,
    now = time,
    random = math.random,
    clock = debugprofilestop,
    log = private.Log,
    today = today,
    dailies = self.db.profile.dailies,
    notify = function(event, match)
      self:OnMatchEvent(event, match)
    end,
    lacks = function(game, sender)
      self:Print(L["lacks_addon"]:format(Transport.DisplayName(sender), game.name, game.addon))
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

  private.daily = private.Daily.New({
    me = Transport.PlayerName(),
    now = time,
    today = today,
    broadcast = Transport.Broadcast,
    whisper = Transport.Send,
    boards = self.db.profile.boards,
    onChange = function()
      MainFrame.Refresh()
    end,
  })
  private.daily:Prune()
  private.Trivia.asked = self.db.profile.trivia
  private.rooms = Rooms.New({
    me = Transport.PlayerName(),
    now = GetTime,
    random = math.random,
    broadcast = Transport.BroadcastTo,
    send = Transport.Send,
    onChannel = Transport.OnChannel,
    reaches = Transport.Reaches,
    named = Transport.Named,
    namedMe = Transport.NamedMe,
    notify = function(event, subject)
      self:OnRoomEvent(event, subject)
    end,
  })

  -- The name the player's own messages came back by last time, so they are known from the first
  Transport.SetHeardAs(self.db.char.heardAs)
  Transport.Init({
    onMessage = function(sender, text, viaGuild, channel)
      if private.rooms:Handle(sender, text, channel) then
        return
      end
      -- Nothing but a room is ever talked about in a group
      if channel == "GROUP" or private.presence:Handle(sender, text, viaGuild) or private.daily:Handle(sender, text) then
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
    onHeardAs = function(name)
      self.db.char.heardAs = name
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
  -- What the front page says of the games open in chat counts down, and one that closed goes
  local linked = false
  C_Timer.NewTicker(FLUSH_INTERVAL, function()
    private.presence:Tick()
    private.session:Flush()
    local open = #private.session:Offers() > 0
    if open or linked then
      MainFrame.RefreshHome()
    end
    linked = open
  end)
  C_Timer.NewTicker(ROOM_BEAT, function()
    private.rooms:Tick()
  end)

  -- The computer's seats at the tables of people this client plays them at are played whether or
  -- not the window is open, a little at a time, and not in the middle of a fight. The game on
  -- screen has the window see to it
  local driver = CreateFrame("Frame")
  driver:SetScript("OnUpdate", function(_, elapsed)
    if not InCombatLockdown() then
      private.session:Drive(elapsed, DRIVE_MS, MainFrame.Pondering())
    end
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
  -- A game against the computer goes on only while the player looks at it
  if Match.IsComputerMatch(match) then
    return nil
  end
  -- A race is the player's own game: only the rival's answer and how they did are news
  if match.race then
    local rival = Transport.DisplayName(match.race.rival)
    if match.hidden then
      return nil
    elseif event == "invite" then
      return L["toast_race"]:format(rival, gameName(match))
    elseif event == "accepted" then
      return L["toast_race_accepted"]:format(rival, gameName(match))
    elseif event == "raced" or event == "declined" then
      return gameName(match) .. ": " .. MainFrame.Describe(match)
    end
    return nil
  end
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
  elseif event == "daily" then
    private.Log("daily", match.daily, match.game, tostring(match.score))
    private.daily:Post(match.daily, match.game, match.score)
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
  if Transport.IsMe(host) then
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
    -- A game to play alone, against the computer if it is a game for more: the one that is
    -- named, or the first there is
    local wanted, game = argument:lower(), nil
    for _, candidate in ipairs(Games.List()) do
      local named = wanted == "" or wanted == candidate.id or wanted == candidate.name:lower()
      if not game and named and Games.PlaysAlone(candidate) and Games.Offered(candidate) then
        game = candidate
      end
    end
    -- Set up the way the player last set it up in the wizard
    local setup = { options = game and self.db.profile.rules[game.id] }
    if game and not Games.CanSeat(game, 1) then
      local last = self.db.profile.computer[game.id] or {}
      setup.computer, setup.seat = { levels = last.levels, level = last.level, count = last.count }, last.seat
    end
    local match, err = private.session:Invite({}, game and game.id, setup)
    if match then
      MainFrame.Open(match.id)
    else
      self:Print(L["err_" .. err])
    end
  elseif command == "link" then
    -- A game left open to whoever clicks the link to it first, set up the way it was last time
    local game = argument ~= "" and Links.Find(argument)
    if not game then
      return self:Print(argument == "" and L["link_usage"] or L["link_no_game"]:format(argument))
    end
    local ok, err = Links.Share(game)
    if not ok then
      -- A game for a room is linked as the room, which is opened in its window
      if err == "no_room" then
        Party.Open(game.id)
      end
      self:Print(L["err_" .. err])
    end
  elseif command == "daily" or command == "today" then
    -- Today's challenge at the game that is named, or at the first that has one
    local wanted, game = argument:lower(), nil
    for _, candidate in ipairs(private.Daily.Games()) do
      if not game and (wanted == "" or wanted == candidate.id or wanted == candidate.name:lower()) then
        game = candidate
      end
    end
    local match, err = private.session:Daily(game and game.id or wanted)
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
