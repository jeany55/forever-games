--------------------------
--  Main window
--------------------------
-- Match list on the left, the selected match on the right. The window knows nothing about any
-- particular game: the board area is handed to the game's render function.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Games = private.Games
local Match = private.Match
local Transport = private.Transport

--- @class MainFrame
local MainFrame = {}
private.MainFrame = MainFrame

local LIST_WIDTH = 220
local ROW_HEIGHT = 38
local BOARD_SIZE = 300

local DECLINE_REASONS = {
  nogame = "status_declined_nogame",
  version = "status_declined_version",
  busy = "status_declined_busy",
  gone = "status_declined_gone",
}

local frame
--- @type string?
local selectedId
local rows = {}
-- One board container per game, so each game keeps its own widgets
local boards = {}
local gameIndex = 1
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

--- @param err string? Error code from the session
local function report(err)
  ForeverGames:Print(L["err_" .. (err or "invalid_move")])
end

--- @return GameDefinition?
local function chosenGame()
  return Games.List()[gameIndex]
end

-----------------------------
-- Actions
-----------------------------

local function challenge()
  local name = frame.nameBox:GetText()
  if name:gsub("%s", "") == "" and UnitIsPlayer("target") and not UnitIsUnit("target", "player") then
    local character, characterRealm = UnitFullName("target")
    name = (characterRealm and characterRealm ~= "") and (character .. "-" .. characterRealm) or character
  end

  local game = chosenGame()
  local match, err = private.session:Invite(Transport.Normalize(name), game and game.id)
  if not match then
    return report(err)
  end
  frame.nameBox:SetText("")
  frame.nameBox:ClearFocus()
  MainFrame.Select(match.id)
end

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
-- Match list
-----------------------------

--- @param index number
--- @return Button
local function getRow(index)
  if rows[index] then
    return rows[index]
  end

  local row = CreateFrame("Button", nil, frame.listContent)
  row:SetSize(LIST_WIDTH - 26, ROW_HEIGHT)
  row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)

  row.selected = row:CreateTexture(nil, "BACKGROUND")
  row.selected:SetAllPoints()
  row.selected:SetColorTexture(1, 0.82, 0, 0.18)

  local highlight = row:CreateTexture(nil, "HIGHLIGHT")
  highlight:SetAllPoints()
  highlight:SetColorTexture(1, 1, 1, 0.08)

  row.marker = row:CreateTexture(nil, "ARTWORK")
  row.marker:SetSize(4, ROW_HEIGHT - 8)
  row.marker:SetPoint("LEFT", 2, 0)
  row.marker:SetColorTexture(0.3, 0.9, 0.3, 1)

  row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.name:SetPoint("TOPLEFT", 12, -5)
  row.name:SetPoint("RIGHT", -4, 0)
  row.name:SetJustifyH("LEFT")
  row.name:SetWordWrap(false)

  row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.status:SetPoint("BOTTOMLEFT", 12, 6)
  row.status:SetPoint("RIGHT", -4, 0)
  row.status:SetJustifyH("LEFT")
  row.status:SetWordWrap(false)

  row:SetScript("OnClick", function(self)
    MainFrame.Select(self.matchId)
  end)

  rows[index] = row
  return row
end

--- @param list Match[]
local function refreshList(list)
  for index, match in ipairs(list) do
    local row = getRow(index)
    local game = Games.Get(match.game)
    local attention = private.session:NeedsAttention(match)

    row.matchId = match.id
    row.name:SetText(Transport.DisplayName(Match.Opponent(match)) .. "  |cff808080" .. (game and game.name or match.game) .. "|r")
    row.status:SetText(MainFrame.Describe(match))
    if attention then
      row.status:SetTextColor(0.3, 0.9, 0.3)
    else
      row.status:SetTextColor(0.7, 0.7, 0.7)
    end
    row.marker:SetShown(attention)
    row.selected:SetShown(match.id == selectedId)
    row:Show()
  end

  for index = #list + 1, #rows do
    rows[index]:Hide()
  end

  frame.listContent:SetHeight(math.max(1, #list * ROW_HEIGHT))
  frame.emptyText:SetShown(#list == 0)
end

-----------------------------
-- Selected match
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

--- @param match Match?
local function refreshDetail(match)
  local detail = frame.detail
  for _, board in pairs(boards) do
    board:Hide()
  end
  for _, button in ipairs(detail.buttons) do
    button:Hide()
  end

  if not match then
    detail.header:SetText("")
    detail.seat:SetText("")
    detail.status:SetText(L["no_selection"])
    detail.note:SetText("")
    return
  end

  local game = Games.Get(match.game)
  local opponent = Transport.DisplayName(Match.Opponent(match))
  detail.header:SetText(L["versus"]:format(game and game.name or match.game, opponent))
  detail.status:SetText(MainFrame.Describe(match))
  detail.note:SetText(deliveryNote(match) or "")

  local showBoard = game and (match.status == "active" or match.status == "finished")
  if showBoard and game.seatLabel then
    detail.seat:SetText(L["you_are"]:format(game.seatLabel(match.me)))
  else
    detail.seat:SetText("")
  end

  if showBoard then
    local board = boards[game.id]
    if not board then
      board = CreateFrame("Frame", nil, detail.boardArea)
      board:SetAllPoints()
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
-- Construction
-----------------------------

local function create()
  frame = CreateFrame("Frame", "ForeverGamesFrame", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(LIST_WIDTH + BOARD_SIZE + 60, BOARD_SIZE + 170)
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
    MainFrame.Refresh()
  end)
  frame:Hide()
  table.insert(UISpecialFrames, "ForeverGamesFrame")

  frame.TitleText:SetText(L["title"])

  -- Match list
  local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 12, -32)
  scroll:SetPoint("BOTTOMLEFT", 12, 76)
  scroll:SetWidth(LIST_WIDTH - 26)
  frame.listContent = CreateFrame("Frame", nil, scroll)
  frame.listContent:SetSize(LIST_WIDTH - 26, 1)
  scroll:SetScrollChild(frame.listContent)

  frame.emptyText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  frame.emptyText:SetPoint("TOPLEFT", scroll, "TOPLEFT", 8, -12)
  frame.emptyText:SetWidth(LIST_WIDTH - 40)
  frame.emptyText:SetJustifyH("LEFT")
  frame.emptyText:SetText(L["empty_list"])

  -- New challenge
  frame.nameBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
  frame.nameBox:SetSize(LIST_WIDTH - 12, 22)
  frame.nameBox:SetPoint("BOTTOMLEFT", 20, 44)
  frame.nameBox:SetAutoFocus(false)
  frame.nameBox:SetMaxLetters(48)
  frame.nameBox:SetScript("OnEnterPressed", challenge)
  frame.nameBox:SetScript("OnEscapePressed", frame.nameBox.ClearFocus)
  frame.nameBox:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(L["challenge_placeholder"])
    GameTooltip:AddLine(L["challenge_hint"], 1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame.nameBox:SetScript("OnLeave", GameTooltip_Hide)

  -- Cycles through the installed games
  frame.gameButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.gameButton:SetSize(108, 24)
  frame.gameButton:SetPoint("BOTTOMLEFT", 14, 14)
  frame.gameButton:SetScript("OnClick", function()
    gameIndex = gameIndex % #Games.List() + 1
    MainFrame.Refresh()
  end)

  frame.challengeButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.challengeButton:SetSize(100, 24)
  frame.challengeButton:SetPoint("LEFT", frame.gameButton, "RIGHT", 4, 0)
  frame.challengeButton:SetText(L["challenge"])
  frame.challengeButton:SetScript("OnClick", challenge)

  -- Selected match
  local detail = CreateFrame("Frame", nil, frame)
  detail:SetPoint("TOPLEFT", LIST_WIDTH + 20, -32)
  detail:SetPoint("BOTTOMRIGHT", -14, 12)
  frame.detail = detail

  detail.header = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  detail.header:SetPoint("TOPLEFT", 4, -4)

  detail.seat = detail:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  detail.seat:SetPoint("TOPRIGHT", -4, -8)

  detail.status = detail:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  detail.status:SetPoint("TOPLEFT", detail.header, "BOTTOMLEFT", 0, -6)

  detail.boardArea = CreateFrame("Frame", nil, detail)
  detail.boardArea:SetSize(BOARD_SIZE, BOARD_SIZE)
  detail.boardArea:SetPoint("TOP", 0, -50)

  detail.note = detail:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  detail.note:SetPoint("TOPLEFT", detail.boardArea, "BOTTOMLEFT", 0, -6)
  detail.note:SetWidth(BOARD_SIZE)
  detail.note:SetJustifyH("LEFT")

  detail.buttons = {}
  for index = 1, 2 do
    local button = CreateFrame("Button", nil, detail, "UIPanelButtonTemplate")
    button:SetSize(100, 24)
    button:SetPoint("BOTTOMRIGHT", -(index - 1) * 104, 2)
    detail.buttons[index] = button
  end
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

  local game = chosenGame()
  frame.gameButton:SetText(game and game.name or "")
  refreshList(list)
  refreshDetail(selected)

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
  return frame ~= nil and frame:IsShown() and selectedId == id
end

--- @param id string? Match to select
function MainFrame.Open(id)
  if not frame then
    create()
  end
  if id then
    selectedId = id
  end
  if frame:IsShown() then
    MainFrame.Refresh()
  else
    frame:Show()
  end
end

function MainFrame.Toggle()
  if frame and frame:IsShown() then
    frame:Hide()
  else
    MainFrame.Open()
  end
end
