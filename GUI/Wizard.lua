--------------------------
--  New game wizard
--------------------------
-- Two steps: pick a game, then pick who to play. Lives inside the main window and takes over its
-- content while open.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Games = private.Games
local Transport = private.Transport
local Widgets = private.Widgets

--- @class Wizard
local Wizard = {}
private.Wizard = Wizard

local CARD_WIDTH, CARD_HEIGHT = 350, 96
local PLAYER_ROW_HEIGHT = 26
local COLUMN_WIDTH = 350

local SOURCE_LABELS = { guild = "source_guild", friend = "source_friend", other = "source_other" }

local panel
--- @type fun(matchId: string?)
local onClose
--- @type GameDefinition?
local chosenGame
-- Opponent picked from the list of available players, full name
--- @type string?
local chosenPlayer

local refresh

--- The opponent the challenge would go to: whatever is typed wins over the list selection
--- @return string?
local function opponent()
  local typed = Transport.Normalize(panel.nameBox:GetText())
  return typed or chosenPlayer
end

--- @return string? Full name of the targeted player, if there is one
local function targetName()
  if not UnitIsPlayer("target") or UnitIsUnit("target", "player") then
    return nil
  end
  local character, characterRealm = UnitFullName("target")
  return Transport.Normalize((characterRealm and characterRealm ~= "") and (character .. "-" .. characterRealm) or character)
end

local function send()
  local match, err = private.session:Invite(opponent(), chosenGame and chosenGame.id)
  if not match then
    panel.error:SetText(L["err_" .. err])
    return
  end
  Wizard.Close(match.id)
end

-----------------------------
-- Step 1: game
-----------------------------

--- @param parent Frame
--- @param game GameDefinition
--- @return Button
local function createGameCard(parent, game)
  local card = Widgets.Panel(parent, "Button")
  card:SetSize(CARD_WIDTH, CARD_HEIGHT)

  local hover = card:CreateTexture(nil, "HIGHLIGHT")
  hover:SetAllPoints()
  hover:SetColorTexture(1, 0.82, 0, 0.12)

  local icon = Widgets.Icon(card, game.icon or private.ICON, 64)
  icon:SetPoint("LEFT", 16, 0)

  local name = Widgets.Label(card, "GameFontNormalLarge", game.name)
  name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 14, -4)

  local description = Widgets.Label(card, "GameFontHighlightSmall", game.description)
  description:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -6)
  description:SetWidth(CARD_WIDTH - 110)
  description:SetJustifyV("TOP")
  description:SetTextColor(unpack(Widgets.GREY))

  card:SetScript("OnClick", function()
    chosenGame = game
    refresh()
  end)
  return card
end

--- @param parent Frame
--- @return Frame
local function createGameStep(parent)
  local step = CreateFrame("Frame", nil, parent)
  for index, game in ipairs(Games.List()) do
    local card = createGameCard(step, game)
    local column, row = (index - 1) % 2, math.floor((index - 1) / 2)
    card:SetPoint("TOPLEFT", column * (CARD_WIDTH + 12), -row * (CARD_HEIGHT + 12))
  end
  return step
end

-----------------------------
-- Step 2: opponent
-----------------------------

--- @param content Frame
--- @return Button
local function createPlayerRow(content)
  local row = CreateFrame("Button", nil, content)

  row.selected = row:CreateTexture(nil, "BACKGROUND")
  row.selected:SetAllPoints()
  row.selected:SetColorTexture(1, 0.82, 0, 0.2)

  local hover = row:CreateTexture(nil, "HIGHLIGHT")
  hover:SetAllPoints()
  hover:SetColorTexture(1, 1, 1, 0.08)

  row.dot = row:CreateTexture(nil, "ARTWORK")
  row.dot:SetSize(8, 8)
  row.dot:SetPoint("LEFT", 8, 0)
  row.dot:SetColorTexture(unpack(Widgets.GREEN))

  row.name = Widgets.Label(row, "GameFontHighlight")
  row.name:SetPoint("LEFT", 24, 0)

  row.source = Widgets.Label(row, "GameFontDisableSmall")
  row.source:SetPoint("RIGHT", -8, 0)

  row:SetScript("OnClick", function(self)
    chosenPlayer = self.player
    panel.nameBox:SetText("")
    panel.nameBox:ClearFocus()
    refresh()
  end)
  return row
end

--- @param parent Frame
--- @return Frame
local function createOpponentStep(parent)
  local step = CreateFrame("Frame", nil, parent)

  -- Players known to be online with the addon
  local available = Widgets.Panel(step)
  available:SetPoint("TOPLEFT")
  available:SetPoint("BOTTOMLEFT")
  available:SetWidth(COLUMN_WIDTH)

  local availableTitle = Widgets.Label(available, "GameFontNormal", L["wizard_available"])
  availableTitle:SetPoint("TOPLEFT", 10, -10)

  panel.players = Widgets.List(available, COLUMN_WIDTH - 12, PLAYER_ROW_HEIGHT, createPlayerRow)
  panel.players.frame:SetPoint("TOPLEFT", 6, -32)
  panel.players.frame:SetPoint("BOTTOMRIGHT", -6, 6)

  panel.nobody = Widgets.Label(available, "GameFontDisable", L["wizard_nobody"])
  panel.nobody:SetPoint("TOPLEFT", 12, -40)
  panel.nobody:SetWidth(COLUMN_WIDTH - 24)

  -- Anyone else, by name
  local other = Widgets.Panel(step)
  other:SetPoint("TOPLEFT", available, "TOPRIGHT", 12, 0)
  other:SetPoint("BOTTOMRIGHT")

  local otherTitle = Widgets.Label(other, "GameFontNormal", L["wizard_by_name"])
  otherTitle:SetPoint("TOPLEFT", 10, -10)

  panel.nameBox = CreateFrame("EditBox", nil, other, "InputBoxTemplate")
  panel.nameBox:SetSize(COLUMN_WIDTH - 40, 24)
  panel.nameBox:SetPoint("TOPLEFT", 18, -36)
  panel.nameBox:SetAutoFocus(false)
  panel.nameBox:SetMaxLetters(48)
  panel.nameBox:SetScript("OnEnterPressed", function()
    if opponent() then
      send()
    end
  end)
  panel.nameBox:SetScript("OnEscapePressed", panel.nameBox.ClearFocus)
  panel.nameBox:SetScript("OnTextChanged", function(_, userInput)
    if userInput then
      chosenPlayer = nil
      refresh()
    end
  end)

  panel.targetButton = Widgets.Button(other, "", COLUMN_WIDTH - 40, 24)
  panel.targetButton:SetPoint("TOPLEFT", panel.nameBox, "BOTTOMLEFT", -6, -10)
  panel.targetButton:SetScript("OnClick", function()
    local target = targetName()
    if target then
      chosenPlayer = nil
      panel.nameBox:SetText(Transport.DisplayName(target))
      refresh()
    end
  end)

  local hint = Widgets.Label(other, "GameFontDisableSmall", L["wizard_by_name_hint"])
  hint:SetPoint("TOPLEFT", panel.targetButton, "BOTTOMLEFT", 2, -14)
  hint:SetWidth(COLUMN_WIDTH - 44)
  hint:SetJustifyV("TOP")

  return step
end

-----------------------------
-- Shell
-----------------------------

refresh = function()
  local choosingOpponent = chosenGame ~= nil
  panel.gameStep:SetShown(not choosingOpponent)
  panel.opponentStep:SetShown(choosingOpponent)
  panel.backButton:SetShown(choosingOpponent)
  panel.sendButton:SetShown(choosingOpponent)
  panel.error:SetText("")

  if not choosingOpponent then
    panel.step:SetText(L["wizard_step_game"])
    panel.summary:SetText("")
    return
  end

  panel.step:SetText(L["wizard_step_opponent"]:format(chosenGame.name))

  local players = private.presence:List()
  panel.players:Update(players, function(row, player)
    row.player = player.name
    row.name:SetText(Transport.DisplayName(player.name))
    row.source:SetText(L[SOURCE_LABELS[player.source]])
    row.selected:SetShown(player.name == chosenPlayer and opponent() == chosenPlayer)
  end)
  panel.nobody:SetShown(#players == 0)

  local target = targetName()
  panel.targetButton:SetShown(target ~= nil)
  if target then
    panel.targetButton:SetText(L["wizard_use_target"]:format(Transport.DisplayName(target)))
  end

  local name = opponent()
  panel.sendButton:SetEnabled(name ~= nil)
  if name then
    panel.summary:SetText(L["wizard_summary"]:format(chosenGame.name, Transport.DisplayName(name)))
  else
    panel.summary:SetText(L["wizard_pick_someone"])
  end
end

--- @param parent Frame The main window
--- @param closed fun(matchId: string?) Called when the wizard closes, with the new match if one was started
function Wizard.Init(parent, closed)
  onClose = closed

  panel = CreateFrame("Frame", nil, parent)
  panel:SetPoint("TOPLEFT", 14, -32)
  panel:SetPoint("BOTTOMRIGHT", -14, 14)
  panel:Hide()
  -- The "use my target" shortcut follows the target
  panel:RegisterEvent("PLAYER_TARGET_CHANGED")
  panel:SetScript("OnEvent", function()
    Wizard.Refresh()
  end)

  local title = Widgets.Label(panel, "GameFontNormalHuge", L["new_game"])
  title:SetPoint("TOPLEFT", 4, -6)

  panel.step = Widgets.Label(panel, "GameFontHighlight")
  panel.step:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)

  panel.gameStep = createGameStep(panel)
  panel.gameStep:SetPoint("TOPLEFT", 4, -66)
  panel.gameStep:SetPoint("BOTTOMRIGHT", -4, 44)

  panel.opponentStep = createOpponentStep(panel)
  panel.opponentStep:SetPoint("TOPLEFT", 4, -66)
  panel.opponentStep:SetPoint("BOTTOMRIGHT", -4, 44)

  panel.sendButton = Widgets.Button(panel, L["wizard_send"], 150, 28)
  panel.sendButton:SetPoint("BOTTOMRIGHT", -4, 4)
  panel.sendButton:SetScript("OnClick", send)

  local cancelButton = Widgets.Button(panel, CANCEL, 90, 28)
  cancelButton:SetPoint("BOTTOMLEFT", 4, 4)
  cancelButton:SetScript("OnClick", function()
    Wizard.Close()
  end)

  panel.backButton = Widgets.Button(panel, BACK, 90, 28)
  panel.backButton:SetPoint("LEFT", cancelButton, "RIGHT", 6, 0)
  panel.backButton:SetScript("OnClick", function()
    chosenGame = nil
    refresh()
  end)

  panel.summary = Widgets.Label(panel, "GameFontHighlight")
  panel.summary:SetPoint("RIGHT", panel.sendButton, "LEFT", -12, 0)
  panel.summary:SetJustifyH("RIGHT")

  panel.error = Widgets.Label(panel, "GameFontRedSmall")
  panel.error:SetPoint("BOTTOMRIGHT", panel.sendButton, "TOPRIGHT", 0, 6)
  panel.error:SetJustifyH("RIGHT")
end

--- @return boolean
function Wizard.IsOpen()
  return panel ~= nil and panel:IsShown()
end

function Wizard.Open()
  chosenGame, chosenPlayer = nil, nil
  panel.nameBox:SetText("")
  panel:Show()
  refresh()
end

--- @param matchId string? The match that was started, if any
function Wizard.Close(matchId)
  panel:Hide()
  onClose(matchId)
end

--- Puts the wizard away without starting anything, for when the window itself closes
function Wizard.Reset()
  if panel then
    panel:Hide()
  end
end

--- Redraws the wizard if it is open, for when the available players change
function Wizard.Refresh()
  if Wizard.IsOpen() then
    refresh()
  end
end
