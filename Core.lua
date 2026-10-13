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
local Toast = private.Toast
local MainFrame = private.MainFrame

--- @class ForeverGames: AceAddon-3.0, AceConsole-3.0, AceEvent-3.0
--- @field db AceDBObject-3.0
ForeverGames = LibStub("AceAddon-3.0"):NewAddon(private.ADDON_NAME, "AceConsole-3.0", "AceEvent-3.0")

-- How often undelivered moves are retried. The session spaces out retries per opponent on top of this.
local FLUSH_INTERVAL = 15
-- Wait for the client to settle after login before announcing ourselves
local HELLO_DELAY = 5
-- Lines shown by /fg log
local LOG_LINES = 20

local defaults = {
  -- Matches belong to the character that is playing them
  char = { matches = {}, log = {} },
  profile = {
    minimap = { hide = false },
    toasts = true,
    sound = true,
    window = { width = 920, height = 680, focus = false },
    -- Ids of the games the player starred in the new game wizard
    favourites = {},
    -- How the player last set the rules of each game in the wizard, by game id
    rules = {},
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

  Transport.Init({
    onMessage = function(sender, text, viaGuild)
      if private.presence:Handle(sender, text, viaGuild) then
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
    end,
  })

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

  local text = toastText(event, match)
  if text and not MainFrame.IsViewing(match.id) then
    if self.db.profile.toasts then
      Toast.Show(text, function()
        MainFrame.Open(match.id)
      end)
    end
    if self.db.profile.sound and not InCombatLockdown() then
      PlaySound(SOUNDKIT.TELL_MESSAGE)
    end
  end

  MainFrame.Refresh()
  self:UpdateAttention()
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
    OnClick = function()
      MainFrame.Toggle()
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

--- @param input string
function ForeverGames:HandleSlashCommand(input)
  local command, argument = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
  command = command:lower()

  if command == "" then
    MainFrame.Toggle()
  elseif command == "new" then
    MainFrame.NewGame()
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
    local match, err = private.session:Invite({}, game and game.id)
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
