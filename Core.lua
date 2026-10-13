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

local defaults = {
  -- Matches belong to the character that is playing them
  char = { matches = {} },
  profile = { minimap = { hide = false }, toasts = true, sound = true },
}

local dataObject

function ForeverGames:OnInitialize()
  self.db = LibStub("AceDB-3.0"):New("ForeverGamesDB", defaults, true)
  self:RegisterChatCommand("fg", "HandleSlashCommand")
  self:RegisterChatCommand("forevergames", "HandleSlashCommand")
end

function ForeverGames:OnEnable()
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

  Transport.Init({
    onMessage = function(sender, text)
      private.session:Receive(sender, text)
    end,
    onReachable = function(peer)
      private.session:Wake(peer)
    end,
    onOffline = function(peer)
      private.session:PeerOffline(peer)
    end,
  })

  self:RegisterMinimapIcon()
  self:UpdateAttention()

  C_Timer.After(HELLO_DELAY, function()
    private.session:Hello()
  end)
  C_Timer.NewTicker(FLUSH_INTERVAL, function()
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
  local opponent = Transport.DisplayName(Match.Opponent(match))
  if event == "invite" then
    return L["toast_invite"]:format(opponent, gameName(match))
  elseif event == "accepted" and not Match.IsMyTurn(match) then
    return L["toast_accepted"]:format(opponent, gameName(match))
  elseif event == "accepted" or event == "moved" then
    return L["toast_your_turn"]:format(gameName(match), opponent)
  elseif event == "finished" or event == "declined" then
    return gameName(match) .. ": " .. MainFrame.Describe(match)
  end
  return nil
end

--- Called by the session whenever a match changes
--- @param event string
--- @param match Match
function ForeverGames:OnMatchEvent(event, match)
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

--- @param input string
function ForeverGames:HandleSlashCommand(input)
  local command, argument = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
  command = command:lower()

  if command == "" then
    MainFrame.Toggle()
  elseif command == "challenge" or command == "invite" then
    local target, gameName = argument:match("^(%S*)%s*(.-)$")
    local game = Games.List()[1]
    for _, candidate in ipairs(Games.List()) do
      if gameName ~= "" and (candidate.id == gameName:lower() or candidate.name:lower() == gameName:lower()) then
        game = candidate
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
