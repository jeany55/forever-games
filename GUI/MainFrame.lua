--------------------------
--  Main window
--------------------------
-- A header saying who is around to play and a New Game button, then the player's games on the
-- left and the selected one on the right. The window knows nothing about any particular game:
-- the board area is handed to the game's render function.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Games = private.Games
local Match = private.Match
local Transport = private.Transport
local Widgets = private.Widgets
local Wizard = private.Wizard

--- @class MainFrame
local MainFrame = {}
private.MainFrame = MainFrame

local WIDTH, HEIGHT = 764, 560
local LIST_WIDTH = 244
local ROW_HEIGHT = 54
local BOARD_SIZE = 300
-- Names listed in the "who is available" tooltip before it is cut short
local TOOLTIP_NAMES = 15
-- Opening the window looks for players again if the last look is older than this
local STALE_AFTER = 60
-- How long the header says it is looking after a refresh
local LOOKING_FOR = 6

local DECLINE_REASONS = {
  nogame = "status_declined_nogame",
  version = "status_declined_version",
  busy = "status_declined_busy",
  gone = "status_declined_gone",
}
local SOURCE_LABELS = { guild = "source_guild", friend = "source_friend", other = "source_other" }

local frame
--- @type string?
local selectedId
-- One board container per game, so each game keeps its own widgets
local boards = {}
local refreshing = false

--- One line summary of where a match stands
--- @param match Match
--- @return string
function MainFrame.Describe(match)
  local opponent = Transport.DisplayName(Match.Opponent(match))
  if not Games.Get(match.game) then
    return L["status_missing_game"]
  end

  if match.status == "incoming" then
    return L["status_incoming"]:format(opponent)
  elseif match.status == "outgoing" then
    return L["status_outgoing"]:format(opponent)
  elseif match.status == "declined" then
    return L[DECLINE_REASONS[match.declineReason] or "status_declined"]:format(opponent)
  elseif match.status == "finished" then
    local result = Match.Result(match)
    local text
    if not result or result.winner == 0 then
      text = L["status_draw"]
    elseif result.reason == "resign" then
      return result.winner == match.me and L["status_they_resigned"]:format(opponent) or L["status_you_resigned"]
    else
      text = result.winner == match.me and L["status_won"] or L["status_lost"]
    end
    if result and result.detail then
      text = text .. " (" .. L["result_" .. result.detail] .. ")"
    end
    return text
  elseif Match.IsMyTurn(match) then
    return L["status_your_turn"]
  end
  return L["status_their_turn"]:format(opponent)
end

--- Whether the match can't go on until the local player does something
--- @param match Match
--- @return boolean
local function waitingOnMe(match)
  return match.status == "incoming" or Match.IsMyTurn(match)
end

--- @param err string? Error code from the session
local function report(err)
  ForeverGames:Print(L["err_" .. (err or "invalid_move")])
end

--- @param match Match
--- @return string
local function iconFor(match)
  local game = Games.Get(match.game)
  return game and game.icon or private.ICON
end

-----------------------------
-- Actions
-----------------------------

--- @param match Match
local function rematch(match)
  local newMatch, err = private.session:Invite(Match.Opponent(match), match.game)
  if not newMatch then
    return report(err)
  end
  MainFrame.Select(newMatch.id)
end

StaticPopupDialogs["FOREVERGAMES_RESIGN"] = {
  text = L["resign_confirm"],
  button1 = YES,
  button2 = NO,
  OnAccept = function(_, id)
    private.session:Resign(id)
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}

--- Buttons offered for a match, in display order
--- @param match Match
--- @return { text: string, onClick: fun() }[]
local function actionsFor(match)
  local session, id = private.session, match.id

  local function accept()
    session:Accept(id)
  end
  local function decline()
    session:Decline(id)
  end
  local function forget()
    session:Forget(id)
  end
  local function resign()
    StaticPopup_Show("FOREVERGAMES_RESIGN", Transport.DisplayName(Match.Opponent(match)), nil, id)
  end
  local function again()
    rematch(match)
  end

  if match.status == "incoming" then
    return { { text = L["accept"], onClick = accept }, { text = L["decline"], onClick = decline } }
  elseif match.status == "outgoing" then
    return { { text = L["withdraw"], onClick = forget } }
  elseif match.status == "active" then
    return { { text = L["resign"], onClick = resign } }
  end
  return { { text = L["rematch"], onClick = again }, { text = L["remove"], onClick = forget } }
end

-----------------------------
-- Header
-----------------------------

--- Asks who is online again, if it hasn't just been done
local function lookForPlayers()
  if not private.presence:CanAnnounce() then
    return
  end
  private.presence:Announce()
  MainFrame.Refresh()
end

local function refreshHeader()
  local header = frame.header
  local counts = private.presence:Counts()
  local since = private.presence:SinceAnnounce()
  header.refresh:SetEnabled(private.presence:CanAnnounce())

  if counts.total == 0 and since and since < LOOKING_FOR then
    header.dot:SetColorTexture(1, 0.82, 0)
    header.title:SetText(L["presence_looking"])
    header.title:SetTextColor(1, 1, 1)
    header.detail:SetText(L["presence_looking_detail"])
    return
  end

  if counts.total == 0 then
    header.dot:SetColorTexture(0.45, 0.45, 0.45)
    header.title:SetText(L["presence_none"])
    header.title:SetTextColor(unpack(Widgets.GREY))
    header.detail:SetText(L["presence_none_detail"])
    return
  end

  header.dot:SetColorTexture(unpack(Widgets.GREEN))
  header.title:SetText((counts.total == 1 and L["presence_one"] or L["presence_many"]):format(counts.total))
  header.title:SetTextColor(1, 1, 1)

  local parts = {}
  for _, source in ipairs({ "guild", "friend", "other" }) do
    if counts[source] > 0 then
      parts[#parts + 1] = L["presence_" .. source]:format(counts[source])
    end
  end
  header.detail:SetText(table.concat(parts, "  |cff666666-|r  "))
end

--- @param owner Frame
local function showPresenceTooltip(owner)
  local players = private.presence:List()
  GameTooltip:SetOwner(owner, "ANCHOR_BOTTOMLEFT", owner:GetWidth(), 0)
  GameTooltip:SetText(L["presence_tooltip_title"])
  if #players == 0 then
    GameTooltip:AddLine(L["presence_tooltip_none"], 1, 1, 1, true)
  end
  for index, player in ipairs(players) do
    if index > TOOLTIP_NAMES then
      GameTooltip:AddLine(L["presence_tooltip_more"]:format(#players - TOOLTIP_NAMES), 0.65, 0.65, 0.65)
      break
    end
    GameTooltip:AddDoubleLine(Transport.DisplayName(player.name), L[SOURCE_LABELS[player.source]], 1, 1, 1, 0.65, 0.65, 0.65)
  end
  GameTooltip:Show()
end

--- @return Frame
local function createHeader()
  local header = Widgets.Panel(frame)
  header:SetPoint("TOPLEFT", 14, -32)
  header:SetPoint("TOPRIGHT", -14, -32)
  header:SetHeight(50)

  -- The presence summary is one hover target that lists who it is counting
  local presence = CreateFrame("Frame", nil, header)
  presence:SetPoint("TOPLEFT")
  presence:SetPoint("BOTTOMLEFT")
  presence:SetWidth(380)
  presence:EnableMouse(true)
  presence:SetScript("OnEnter", showPresenceTooltip)
  presence:SetScript("OnLeave", GameTooltip_Hide)

  header.dot = presence:CreateTexture(nil, "ARTWORK")
  header.dot:SetSize(10, 10)
  header.dot:SetPoint("LEFT", 14, 0)

  header.title = Widgets.Label(presence, "GameFontNormal")
  header.title:SetPoint("TOPLEFT", 36, -10)

  header.detail = Widgets.Label(presence, "GameFontHighlightSmall")
  header.detail:SetPoint("TOPLEFT", header.title, "BOTTOMLEFT", 0, -4)
  header.detail:SetTextColor(unpack(Widgets.GREY))

  header.newGame = Widgets.Button(header, L["new_game"], 150, 30)
  header.newGame:SetPoint("RIGHT", -10, 0)
  header.newGame:SetScript("OnClick", function()
    MainFrame.NewGame()
  end)

  header.refresh = Widgets.Button(header, L["presence_refresh"], 90, 24)
  header.refresh:SetPoint("RIGHT", header.newGame, "LEFT", -10, 0)
  header.refresh:SetScript("OnClick", lookForPlayers)
  header.refresh:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(L["presence_refresh"])
    GameTooltip:AddLine(L["presence_refresh_tooltip"], 1, 1, 1, true)
    GameTooltip:Show()
  end)
  header.refresh:SetScript("OnLeave", GameTooltip_Hide)

  return header
end

-----------------------------
-- Game list
-----------------------------

--- @param content Frame
--- @return Button
local function createRow(content)
  local row = CreateFrame("Button", nil, content)

  row.selected = row:CreateTexture(nil, "BACKGROUND")
  row.selected:SetAllPoints()
  row.selected:SetColorTexture(1, 0.82, 0, 0.16)

  local hover = row:CreateTexture(nil, "HIGHLIGHT")
  hover:SetAllPoints()
  hover:SetColorTexture(1, 1, 1, 0.07)

  -- Flashing edge for games that are waiting on the player
  row.marker = row:CreateTexture(nil, "ARTWORK")
  row.marker:SetSize(4, ROW_HEIGHT - 10)
  row.marker:SetPoint("LEFT", 2, 0)
  row.marker:SetColorTexture(unpack(Widgets.GREEN))
  row.markerPulse = Widgets.Pulse(row.marker)

  row.icon = Widgets.Icon(row, private.ICON, 36)
  row.icon:SetPoint("LEFT", 12, 0)

  row.name = Widgets.Label(row, "GameFontNormal")
  row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 10, -2)
  row.name:SetPoint("RIGHT", -6, 0)
  row.name:SetWordWrap(false)

  row.status = Widgets.Label(row, "GameFontHighlightSmall")
  row.status:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 10, 2)
  row.status:SetPoint("RIGHT", -6, 0)
  row.status:SetWordWrap(false)
  row.statusPulse = Widgets.Pulse(row.status)

  row:SetScript("OnClick", function(self)
    MainFrame.Select(self.matchId)
  end)
  return row
end

--- @param row Button
--- @param match Match
local function fillRow(row, match)
  local game = Games.Get(match.game)
  local waiting = waitingOnMe(match)

  row.matchId = match.id
  row.icon:SetTexture(iconFor(match))
  row.name:SetText(Transport.DisplayName(Match.Opponent(match)) .. "  |cff808080" .. (game and game.name or match.game) .. "|r")
  row.selected:SetShown(match.id == selectedId)

  if waiting then
    row.status:SetText(match.status == "incoming" and L["list_challenge"] or L["list_waiting_on_you"])
  else
    row.status:SetText(MainFrame.Describe(match))
  end
  if waiting or private.session:NeedsAttention(match) then
    row.status:SetTextColor(unpack(Widgets.GREEN))
  else
    row.status:SetTextColor(unpack(Widgets.GREY))
  end

  row.marker:SetShown(waiting)
  if waiting then
    row.markerPulse:Play()
    row.statusPulse:Play()
  else
    row.markerPulse:Stop()
    row.statusPulse:Stop()
    row.status:SetAlpha(1)
  end
end

--- @param body Frame
--- @return Frame
local function createListPanel(body)
  local panel = Widgets.Panel(body)
  panel:SetPoint("TOPLEFT")
  panel:SetPoint("BOTTOMLEFT")
  panel:SetWidth(LIST_WIDTH)

  panel.title = Widgets.Label(panel, "GameFontNormal", L["list_title"])
  panel.title:SetPoint("TOPLEFT", 12, -10)

  panel.waiting = Widgets.Label(panel, "GameFontHighlightSmall")
  panel.waiting:SetPoint("TOPRIGHT", -10, -12)
  panel.waiting:SetTextColor(unpack(Widgets.GREEN))
  panel.waitingPulse = Widgets.Pulse(panel.waiting)

  panel.list = Widgets.List(panel, LIST_WIDTH - 8, ROW_HEIGHT, createRow)
  panel.list.frame:SetPoint("TOPLEFT", 4, -32)
  panel.list.frame:SetPoint("BOTTOMRIGHT", -4, 4)
  return panel
end

--- @param list Match[]
local function refreshList(list)
  local panel = frame.listPanel
  local waiting = 0
  for _, match in ipairs(list) do
    if waitingOnMe(match) then
      waiting = waiting + 1
    end
  end

  panel.list:Update(list, fillRow)
  if waiting > 0 then
    panel.waiting:SetText(L["list_waiting_count"]:format(waiting))
    panel.waitingPulse:Play()
  else
    panel.waiting:SetText("")
    panel.waitingPulse:Stop()
  end
end

-----------------------------
-- Selected game
-----------------------------

--- @param match Match
--- @return string?
local function deliveryNote(match)
  if match.status == "outgoing" then
    return L["status_outgoing_hint"]
  end
  if private.session:IsPending(match) then
    if Transport.IsLocked() then
      return L["pending_locked"]
    end
    return L["pending_unreachable"]:format(Transport.DisplayName(Match.Opponent(match)))
  end
  return nil
end

--- @param body Frame
--- @return Frame
local function createDetailPanel(body)
  local detail = Widgets.Panel(body)
  detail:SetPoint("TOPLEFT", frame.listPanel, "TOPRIGHT", 8, 0)
  detail:SetPoint("BOTTOMRIGHT")

  detail.icon = Widgets.Icon(detail, private.ICON, 40)
  detail.icon:SetPoint("TOPLEFT", 14, -12)

  detail.header = Widgets.Label(detail, "GameFontNormalLarge")
  detail.header:SetPoint("TOPLEFT", detail.icon, "TOPRIGHT", 12, -2)

  detail.status = Widgets.Label(detail, "GameFontHighlight")
  detail.status:SetPoint("TOPLEFT", detail.header, "BOTTOMLEFT", 0, -5)
  detail.statusPulse = Widgets.Pulse(detail.status)

  detail.seat = Widgets.Label(detail, "GameFontDisableSmall")
  detail.seat:SetPoint("TOPRIGHT", -14, -16)

  detail.boardArea = CreateFrame("Frame", nil, detail)
  detail.boardArea:SetSize(BOARD_SIZE, BOARD_SIZE)
  detail.boardArea:SetPoint("TOP", 0, -66)

  -- Shown in place of the board for games that haven't started
  detail.message = Widgets.Label(detail, "GameFontHighlightLarge")
  detail.message:SetPoint("CENTER", detail.boardArea, "CENTER", 0, 20)
  detail.message:SetWidth(BOARD_SIZE + 60)
  detail.message:SetJustifyH("CENTER")

  detail.note = Widgets.Label(detail, "GameFontDisableSmall")
  detail.note:SetPoint("TOP", detail.boardArea, "BOTTOM", 0, -8)
  detail.note:SetWidth(BOARD_SIZE + 60)
  detail.note:SetJustifyH("CENTER")

  detail.buttons = {}
  for index = 1, 2 do
    local button = Widgets.Button(detail, "", 110, 26)
    button:SetPoint("BOTTOMRIGHT", -12 - (index - 1) * 116, 12)
    detail.buttons[index] = button
  end
  return detail
end

--- @param match Match?
local function refreshDetail(match)
  local detail = frame.detail
  for _, board in pairs(boards) do
    board:Hide()
  end
  for _, button in ipairs(detail.buttons) do
    button:Hide()
  end
  detail:SetShown(match ~= nil)
  if not match then
    return
  end

  local game = Games.Get(match.game)
  local opponent = Transport.DisplayName(Match.Opponent(match))
  local waiting = waitingOnMe(match)

  detail.icon:SetTexture(iconFor(match))
  detail.header:SetText(L["versus"]:format(game and game.name or match.game, opponent))
  detail.status:SetText(MainFrame.Describe(match))
  detail.note:SetText(deliveryNote(match) or "")
  if waiting then
    detail.status:SetTextColor(unpack(Widgets.GREEN))
    detail.statusPulse:Play()
  else
    detail.status:SetTextColor(1, 1, 1)
    detail.statusPulse:Stop()
    detail.status:SetAlpha(1)
  end

  local showBoard = game ~= nil and (match.status == "active" or match.status == "finished")
  detail.seat:SetText((showBoard and game.seatLabel) and L["you_are"]:format(game.seatLabel(match.me)) or "")
  detail.message:SetText(showBoard and "" or MainFrame.Describe(match))

  if showBoard then
    local board = boards[game.id]
    if not board then
      board = CreateFrame("Frame", nil, detail.boardArea)
      -- Sized explicitly: games lay their boards out from this before the frame has been drawn
      board:SetSize(BOARD_SIZE, BOARD_SIZE)
      board:SetPoint("CENTER")
      boards[game.id] = board
    end
    board:Show()
    game.render(board, {
      match = match,
      state = Match.State(match),
      seat = match.me,
      canMove = Match.IsMyTurn(match),
      submit = function(move)
        local ok, err = private.session:Move(match.id, move)
        if not ok then
          report(err)
        end
      end,
    })
  end

  for index, action in ipairs(actionsFor(match)) do
    local button = detail.buttons[index]
    button:SetText(action.text)
    button:SetScript("OnClick", action.onClick)
    button:Show()
  end
end

-----------------------------
-- Empty state
-----------------------------

--- Shown instead of the list and board while the player has no games at all
--- @param body Frame
--- @return Frame
local function createEmptyPanel(body)
  local empty = Widgets.Panel(body)
  empty:SetAllPoints()

  local icon = Widgets.Icon(empty, private.ICON, 64)
  icon:SetPoint("CENTER", 0, 90)

  local title = Widgets.Label(empty, "GameFontNormalHuge", L["empty_title"])
  title:SetPoint("TOP", icon, "BOTTOM", 0, -16)

  local text = Widgets.Label(empty, "GameFontHighlight", L["empty_text"])
  text:SetPoint("TOP", title, "BOTTOM", 0, -10)
  text:SetWidth(420)
  text:SetJustifyH("CENTER")
  text:SetTextColor(unpack(Widgets.GREY))

  local button = Widgets.Button(empty, L["new_game"], 180, 36)
  button:SetPoint("TOP", text, "BOTTOM", 0, -22)
  button:SetScript("OnClick", function()
    MainFrame.NewGame()
  end)
  return empty
end

-----------------------------
-- Construction
-----------------------------

local function create()
  frame = CreateFrame("Frame", "ForeverGamesFrame", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(WIDTH, HEIGHT)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("HIGH")
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetScript("OnShow", function()
    PlaySound(SOUNDKIT.IG_MAINMENU_OPEN)
    local since = private.presence:SinceAnnounce()
    if not since or since > STALE_AFTER then
      lookForPlayers()
    end
    MainFrame.Refresh()
  end)
  frame:SetScript("OnHide", Wizard.Reset)
  frame:Hide()
  table.insert(UISpecialFrames, "ForeverGamesFrame")
  frame.TitleText:SetText(L["title"])

  frame.header = createHeader()
  -- The header shows things that change with time alone: the "looking" message after a refresh
  -- and whether Refresh can be pressed again
  local sinceUpdate = 0
  frame.header:SetScript("OnUpdate", function(_, elapsed)
    sinceUpdate = sinceUpdate + elapsed
    if sinceUpdate >= 1 then
      sinceUpdate = 0
      refreshHeader()
    end
  end)

  frame.body = CreateFrame("Frame", nil, frame)
  frame.body:SetPoint("TOPLEFT", frame.header, "BOTTOMLEFT", 0, -8)
  frame.body:SetPoint("BOTTOMRIGHT", -14, 14)

  frame.listPanel = createListPanel(frame.body)
  frame.detail = createDetailPanel(frame.body)
  frame.empty = createEmptyPanel(frame.body)

  Wizard.Init(frame, function(matchId)
    if matchId then
      selectedId = matchId
    end
    MainFrame.Refresh()
  end)
end

-----------------------------
-- Public
-----------------------------

--- Redraws the window if it is open
function MainFrame.Refresh()
  if not frame or not frame:IsShown() or refreshing then
    return
  end
  refreshing = true

  local inWizard = Wizard.IsOpen()
  frame.header:SetShown(not inWizard)
  frame.body:SetShown(not inWizard)

  if inWizard then
    Wizard.Refresh()
  else
    local selected = selectedId and private.session:Get(selectedId)
    if not selected or selected.hidden then
      selected = private.session:List()[1]
      selectedId = selected and selected.id
    end
    if selected then
      -- Looking at a match is what clears its "something new" flag
      private.session:MarkRead(selected.id)
    end
    local list = private.session:List()

    refreshHeader()
    frame.empty:SetShown(#list == 0)
    frame.listPanel:SetShown(#list > 0)
    refreshList(list)
    refreshDetail(selected)
  end

  refreshing = false
end

--- @param id string?
function MainFrame.Select(id)
  selectedId = id
  MainFrame.Refresh()
end

--- Whether the player is currently looking at this match
--- @param id string
--- @return boolean
function MainFrame.IsViewing(id)
  return frame ~= nil and frame:IsShown() and not Wizard.IsOpen() and selectedId == id
end

--- @param id string? Match to select
function MainFrame.Open(id)
  if not frame then
    create()
  end
  if id then
    selectedId = id
    if Wizard.IsOpen() then
      Wizard.Close()
    end
  end
  if frame:IsShown() then
    MainFrame.Refresh()
  else
    frame:Show()
  end
end

--- Opens the window on the new game wizard
function MainFrame.NewGame()
  if not frame then
    create()
  end
  if not frame:IsShown() then
    frame:Show()
  end
  Wizard.Open()
  MainFrame.Refresh()
end

function MainFrame.Toggle()
  if frame and frame:IsShown() then
    frame:Hide()
  else
    MainFrame.Open()
  end
end
