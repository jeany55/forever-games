--------------------------
--  Main window
--------------------------
-- A header saying who is around to play and a New Game button, then the player's games on the
-- left and the selected one on the right. The window knows nothing about any particular game:
-- it gives the game's view a stage to draw on and tells it which position to show. What every
-- game shares is built here around that stage: the status line, resigning and draw offers, the
-- list of moves and stepping back through them.
--
-- The window can be resized, and "focus" hides everything but the selected game. Either way the
-- stage is given whatever room is left and the game's view lays itself out in it.

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

local MIN_WIDTH, MIN_HEIGHT = 764, 560
local LIST_WIDTH = 244
local ROW_HEIGHT = 54
-- Space between the window's edge and what is in it, and between the panels
local INSET, GAP = 14, 8
local HEADER_TOP, HEADER_HEIGHT = 32, 50
-- Room the selected game's panel keeps around the stage: its title above, the note and buttons below
local STAGE_TOP, STAGE_BOTTOM, STAGE_SIDE = 66, 72, 12
local MOVES_WIDTH = 150
local MOVE_ROW_HEIGHT = 20
local STEP_BUTTON_WIDTH = 36
-- Names listed in the "who is available" tooltip before it is cut short
local TOOLTIP_NAMES = 15
-- Opening the window looks for players again if the last look is older than this
local STALE_AFTER = 60
-- How long the header says it is looking after a refresh
local LOOKING_FOR = 6

local DECLINE_REASONS = {
  off = "status_declined_off",
  nogame = "status_declined_nogame",
  version = "status_declined_version",
  busy = "status_declined_busy",
  gone = "status_declined_gone",
}
local SOURCE_LABELS = { guild = "source_guild", friend = "source_friend", other = "source_other" }

local frame
--- @type string?
local selectedId
-- One stage per game, so each game keeps its own widgets
--- @type table<string, { stage: Frame, view: GameViewObject, width: number?, height: number? }>
local views = {}
-- Set while the player looks back at an earlier position of a match. Forgotten as soon as the
-- match moves on, so news is never hidden behind an old position.
--- @type { id: string, ply: number, total: number }?
local review
-- What the move list last scrolled to, so it only follows the game when something changed
local movesShown
local refreshing = false

--- Window settings that are remembered between sessions
--- @return { width: number, height: number, focus: boolean }
local function settings()
  return ForeverGames.db.profile.window
end

--- Players of a match the way a sentence lists them: "Ann", "Ann and Bob", "Ann, Bob and Cy"
--- @param match Match
--- @param seats number[]? Everyone but the local player if left out
--- @return string
function MainFrame.Names(match, seats)
  local names = {}
  for index, seat in ipairs(seats or Match.Others(match)) do
    names[index] = Transport.DisplayName(match.players[seat])
  end
  if #names < 2 then
    return names[1] or ""
  end
  return L["names_and"]:format(table.concat(names, ", ", 1, #names - 1), names[#names])
end

--- One line summary of where a match stands
--- @param match Match
--- @return string
function MainFrame.Describe(match)
  local opponent = MainFrame.Names(match)
  local crowd = #match.players > 2
  if not Games.Get(match.game) then
    return L["status_missing_game"]
  end

  if match.status == "incoming" then
    return L["status_incoming"]:format(MainFrame.Names(match, { Match.Inviter(match) }))
  elseif match.status == "outgoing" then
    return L["status_outgoing"]:format(MainFrame.Names(match, private.session:Behind(match)))
  elseif match.status == "declined" then
    local who = (crowd and match.declinedBy) and MainFrame.Names(match, { match.declinedBy }) or opponent
    return L[DECLINE_REASONS[match.declineReason] or "status_declined"]:format(who)
  elseif match.status == "finished" then
    local result = Match.Result(match)
    local text
    if not result or result.winner == 0 then
      text = L["status_draw"]
    elseif result.winner ~= match.me and crowd then
      text = L["status_they_won"]:format(MainFrame.Names(match, { result.winner }))
    elseif result.reason == "resign" then
      local won = L[crowd and "status_all_resigned" or "status_they_resigned"]:format(opponent)
      return result.winner == match.me and won or L["status_you_resigned"]
    else
      text = result.winner == match.me and L["status_won"] or L["status_lost"]
    end
    if result and result.detail then
      text = text .. " (" .. L["result_" .. result.detail] .. ")"
    end
    return text
  end

  if not Match.Started(match) then
    return L["status_gathering"]
  elseif Match.IsOut(match, match.me) then
    return L["status_you_left"]
  end

  local offer = Match.DrawOffer(match)
  if Match.IsMyTurn(match) then
    if offer == match.me then
      return L["status_draw_offering"]
    elseif offer then
      return L["status_draw_offered"]:format(opponent)
    end
    return L["status_your_turn"]
  end
  if offer == match.me then
    return L["status_their_turn_draw"]:format(opponent)
  elseif offer then
    return L["status_draw_coming"]:format(opponent)
  end
  local turn = Match.Turn(match)
  return L["status_their_turn"]:format(turn and MainFrame.Names(match, { turn }) or opponent)
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
  local others = {}
  for index, seat in ipairs(Match.Others(match)) do
    others[index] = match.players[seat]
  end
  local newMatch, err = private.session:Invite(others, match.game)
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
    StaticPopup_Show("FOREVERGAMES_RESIGN", MainFrame.Names(match), nil, id)
  end
  local function again()
    rematch(match)
  end

  if match.status == "incoming" then
    return { { text = L["accept"], onClick = accept }, { text = L["decline"], onClick = decline } }
  elseif match.status == "outgoing" then
    return { { text = L["withdraw"], onClick = forget } }
  elseif match.status == "active" and not Match.Started(match) then
    return { { text = L["leave"], onClick = forget } }
  elseif match.status == "active" and not Match.IsOut(match, match.me) then
    local actions = { { text = L["resign"], onClick = resign } }
    if Match.CanAcceptDraw(match) then
      actions[2] = {
        text = L["accept_draw"],
        onClick = function()
          session:AcceptDraw(id)
        end,
      }
    elseif Match.CanOfferDraw(match) then
      actions[2] = {
        text = L["offer_draw"],
        onClick = function()
          session:OfferDraw(id)
        end,
      }
    end
    return actions
  elseif match.status == "active" then
    -- Resigned from a game the others are still playing
    return { { text = L["remove"], onClick = forget } }
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
  row.name:SetText(MainFrame.Names(match) .. "  |cff808080" .. (game and game.name or match.game) .. "|r")
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
    return L["pending_unreachable"]:format(MainFrame.Names(match, private.session:Behind(match)))
  end
  return nil
end

--- How much room the selected game's view gets
--- @param history boolean Whether the move list is taking its share
--- @return number width, number height
local function stageSize(history)
  local width = frame:GetWidth() - INSET * 2 - STAGE_SIDE * 2
  local height = frame:GetHeight() - HEADER_TOP - INSET - STAGE_TOP - STAGE_BOTTOM
  if not frame.focused then
    width = width - LIST_WIDTH - GAP
    height = height - HEADER_HEIGHT - GAP
  end
  if history then
    width = width - MOVES_WIDTH - GAP
  end
  return width, height
end

--- The position of a match that is on screen, as a number of log entries
--- @param match Match
--- @return number
local function shownPly(match)
  if review and review.id == match.id and review.total == #match.log then
    return review.ply
  end
  return #match.log
end

--- Shows the position after `ply` log entries. The last one is the game as it stands.
--- @param match Match
--- @param ply number
local function reviewTo(match, ply)
  local total = #match.log
  ply = math.max(0, math.min(total, ply))
  review = ply < total and { id = match.id, ply = ply, total = total } or nil
  MainFrame.Refresh()
end

--- Steps a move back or forward, passing over entries that aren't moves
--- @param match Match
--- @param direction number -1 or 1
local function reviewStep(match, direction)
  local events, total = Match.Events(match), #match.log
  local ply = shownPly(match)
  repeat
    ply = ply + direction
  until ply <= 0 or ply >= total or events[ply].kind == "move"
  reviewTo(match, ply)
end

--- The match whose moves can be stepped through right now
--- @return Match?
local function reviewable()
  local match = selectedId and private.session:Get(selectedId)
  local game = match and Games.Get(match.game)
  if game and game.history and (match.status == "active" or match.status == "finished") then
    return match
  end
  return nil
end

--- One line of the move list: a move number and the move each player made. A player who had to
--- sit a turn out leaves a gap
--- @param content Frame
--- @return Frame
local function createMoveRow(content)
  local row = CreateFrame("Frame", nil, content)
  row.number = Widgets.Label(row, "GameFontDisableSmall")
  row.number:SetPoint("LEFT", 2, 0)
  row.number:SetWidth(24)
  row.number:SetJustifyH("RIGHT")

  local width = (MOVES_WIDTH - 8 - 30) / 2
  row.moves = {}
  for index = 1, 2 do
    local button = CreateFrame("Button", nil, row)
    button:SetSize(width, MOVE_ROW_HEIGHT)
    button:SetPoint("LEFT", 30 + (index - 1) * width, 0)

    button.current = button:CreateTexture(nil, "BACKGROUND")
    button.current:SetAllPoints()
    button.current:SetColorTexture(1, 0.82, 0, 0.22)
    local hover = button:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetColorTexture(1, 1, 1, 0.1)

    button.text = Widgets.Label(button, "GameFontHighlightSmall")
    button.text:SetPoint("LEFT", 4, 0)

    button:SetScript("OnClick", function(self)
      local match = reviewable()
      if match then
        reviewTo(match, self.ply)
      end
    end)
    row.moves[index] = button
  end
  return row
end

--- @param row Frame
--- @param item { number: number, moves: table<number, { ply: number, text: string, current: boolean }> } Moves by seat
local function fillMoveRow(row, item)
  row.number:SetText(item.number .. ".")
  for index, button in ipairs(row.moves) do
    local move = item.moves[index]
    button:SetShown(move ~= nil)
    if move then
      button.ply = move.ply
      button.text:SetText(move.text)
      button.current:SetShown(move.current)
    end
  end
end

--- @param match Match
--- @param ply number The position on screen
local function refreshMoves(match, ply)
  local detail = frame.detail
  local rows, count, current = {}, 0, nil
  local lastSeat = 2
  for index, event in ipairs(Match.Events(match)) do
    if event.kind == "move" then
      count = count + 1
      -- A line is one move by each player in turn. Players don't always alternate, so a new
      -- line starts whenever the move doesn't fit behind the one before
      if event.seat <= lastSeat then
        rows[#rows + 1] = { number = #rows + 1, moves = {} }
      end
      lastSeat = event.seat
      local move = { ply = index, text = event.notation or match.log[index], current = false }
      rows[#rows].moves[event.seat] = move
      if index <= ply then
        current = { move = move, row = #rows }
      end
    end
  end
  if current then
    current.move.current = true
  end

  detail.moves.list:Update(rows, fillMoveRow)
  -- Keep the move that is on screen in sight, but leave the list alone while nothing changes
  local shown = match.id .. ":" .. ply .. ":" .. count
  if shown ~= movesShown then
    movesShown = shown
    detail.moves.list:ScrollTo(current and current.row or 1)
  end

  local total = #match.log
  detail.steps[1]:SetEnabled(ply > 0)
  detail.steps[2]:SetEnabled(ply > 0)
  detail.steps[3]:SetEnabled(ply < total)
  detail.steps[4]:SetEnabled(ply < total)
end

--- @param body Frame
--- @return Frame
local function createDetailPanel(body)
  local detail = Widgets.Panel(body)

  detail.icon = Widgets.Icon(detail, private.ICON, 40)
  detail.icon:SetPoint("TOPLEFT", 14, -12)

  detail.header = Widgets.Label(detail, "GameFontNormalLarge")
  detail.header:SetPoint("TOPLEFT", detail.icon, "TOPRIGHT", 12, -2)

  detail.status = Widgets.Label(detail, "GameFontHighlight")
  detail.status:SetPoint("TOPLEFT", detail.header, "BOTTOMLEFT", 0, -5)
  detail.statusPulse = Widgets.Pulse(detail.status)

  -- Gives the selected game the whole window, or brings the rest back
  detail.focus = Widgets.Button(detail, "", 96, 22)
  detail.focus:SetPoint("TOPRIGHT", -STAGE_SIDE, -12)
  detail.focus:SetScript("OnClick", function()
    settings().focus = not settings().focus
    MainFrame.Refresh()
  end)

  detail.seat = Widgets.Label(detail, "GameFontDisableSmall")
  detail.seat:SetPoint("TOPRIGHT", detail.focus, "BOTTOMRIGHT", -2, -6)

  -- The room a game's view gets. Sized explicitly, never from its anchors: views lay themselves
  -- out from the numbers before the frame has been drawn
  detail.stageArea = CreateFrame("Frame", nil, detail)
  detail.stageArea:SetPoint("TOPLEFT", STAGE_SIDE, -STAGE_TOP)
  detail.stageArea:EnableMouseWheel(true)
  detail.stageArea:SetScript("OnMouseWheel", function(_, delta)
    local match = reviewable()
    if match then
      reviewStep(match, delta > 0 and -1 or 1)
    end
  end)

  -- Shown in place of the board for games that haven't started
  detail.message = Widgets.Label(detail, "GameFontHighlightLarge")
  detail.message:SetPoint("CENTER", detail.stageArea, "CENTER", 0, 20)
  detail.message:SetWidth(360)
  detail.message:SetJustifyH("CENTER")

  detail.note = Widgets.Label(detail, "GameFontDisableSmall")
  detail.note:SetPoint("BOTTOMLEFT", STAGE_SIDE, 46)
  detail.note:SetPoint("BOTTOMRIGHT", -STAGE_SIDE, 46)
  detail.note:SetJustifyH("CENTER")

  -- The moves so far, for games that write them down. Clicking one shows the position after it
  detail.moves = Widgets.Panel(detail)
  detail.moves:SetPoint("TOPRIGHT", -STAGE_SIDE, -STAGE_TOP)
  detail.moves:SetPoint("BOTTOMRIGHT", -STAGE_SIDE, STAGE_BOTTOM + 28)
  detail.moves:SetWidth(MOVES_WIDTH)
  detail.moves.list = Widgets.List(detail.moves, MOVES_WIDTH - 8, MOVE_ROW_HEIGHT, createMoveRow)
  detail.moves.list.frame:SetPoint("TOPLEFT", 4, -4)
  detail.moves.list.frame:SetPoint("BOTTOMRIGHT", -4, 4)

  -- To the start, back a move, on a move, to the game as it stands
  local steps = {
    {
      text = "<<",
      go = function(match)
        reviewTo(match, 0)
      end,
    },
    {
      text = "<",
      go = function(match)
        reviewStep(match, -1)
      end,
    },
    {
      text = ">",
      go = function(match)
        reviewStep(match, 1)
      end,
    },
    {
      text = ">>",
      go = function(match)
        reviewTo(match, #match.log)
      end,
    },
  }
  detail.steps = {}
  for index, step in ipairs(steps) do
    local button = Widgets.Button(detail, step.text, STEP_BUTTON_WIDTH, 22)
    button:SetPoint("BOTTOMLEFT", detail.moves, "BOTTOMLEFT", (index - 1) * (STEP_BUTTON_WIDTH + 2), -26)
    button:SetScript("OnClick", function()
      local match = reviewable()
      if match then
        step.go(match)
      end
    end)
    detail.steps[index] = button
  end

  detail.buttons = {}
  for index = 1, 2 do
    local button = Widgets.Button(detail, "", 110, 26)
    button:SetPoint("BOTTOMRIGHT", -12 - (index - 1) * 116, 12)
    detail.buttons[index] = button
  end
  return detail
end

--- @param match Match?
--- @param fresh boolean? The match has news the player is seeing for the first time
local function refreshDetail(match, fresh)
  local detail = frame.detail
  for _, entry in pairs(views) do
    entry.stage:Hide()
  end
  for _, button in ipairs(detail.buttons) do
    button:Hide()
  end
  detail:SetShown(match ~= nil)
  if not match then
    return
  end

  local game = Games.Get(match.game)
  local waiting = waitingOnMe(match)

  detail.icon:SetTexture(iconFor(match))
  local title = L[#match.players > 2 and "with_players" or "versus"]
  detail.header:SetText(title:format(game and game.name or match.game, MainFrame.Names(match)))
  detail.status:SetText(MainFrame.Describe(match))
  detail.focus:SetText(frame.focused and L["focus_off"] or L["focus_on"])
  if waiting then
    detail.status:SetTextColor(unpack(Widgets.GREEN))
    detail.statusPulse:Play()
  else
    detail.status:SetTextColor(1, 1, 1)
    detail.statusPulse:Stop()
    detail.status:SetAlpha(1)
  end

  local showBoard = game ~= nil and (match.status == "active" or match.status == "finished") and Match.Started(match)
  local history = showBoard and game.history == true
  detail.seat:SetText((showBoard and game.seatLabel) and L["you_are"]:format(game.seatLabel(match.me, #match.players)) or "")
  detail.message:SetText(showBoard and "" or MainFrame.Describe(match))
  detail.moves:SetShown(history)
  for _, button in ipairs(detail.steps) do
    button:SetShown(history)
  end

  local width, height = stageSize(history)
  detail.stageArea:SetSize(width, height)
  local ply = showBoard and shownPly(match) or #match.log
  local live = ply == #match.log
  if live then
    review = nil
  end
  detail.note:SetText(live and (deliveryNote(match) or "") or L["review_note"])

  if showBoard then
    local entry = views[game.id]
    if not entry then
      local stage = CreateFrame("Frame", nil, detail.stageArea)
      stage:SetPoint("CENTER")
      entry = { stage = stage, view = game.createView(stage) }
      views[game.id] = entry
    end
    if entry.width ~= width or entry.height ~= height then
      entry.width, entry.height = width, height
      entry.stage:SetSize(width, height)
      entry.view:Layout(width, height)
    end
    entry.stage:Show()

    -- Whether the position comes out of the one this view showed last, so it can show the move
    local events, before = Match.Events(match), entry.shown
    local sameMatch = before ~= nil and before.id == match.id
    local changed = not sameMatch or before.ply ~= ply
    local event = events[ply]
    local played = nil
    if changed and event and event.kind == "move" then
      local stepped = sameMatch and ply == before.ply + 1
      local arrived = fresh == true and live and event.seat ~= match.me
      played = (stepped or arrived) and event or nil
    end
    entry.shown = { id = match.id, ply = ply }

    local names = {}
    for seat, name in ipairs(match.players) do
      names[seat] = Transport.DisplayName(name)
    end
    entry.view:Update({
      match = match,
      state = live and Match.State(match) or Match.StateAt(match, ply),
      seat = match.me,
      names = names,
      canMove = live and Match.IsMyTurn(match),
      submit = function(move)
        local ok, err = private.session:Move(match.id, move)
        if not ok then
          report(err)
        end
      end,
      ply = ply,
      live = live,
      events = events,
      fresh = fresh == true,
      changed = changed,
      played = played,
    })
    if history then
      refreshMoves(match, ply)
    end
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

--- Arranges the panels for the whole window or for just the selected game
--- @param focused boolean
local function arrange(focused)
  if frame.focused == focused then
    return
  end
  frame.focused = focused

  frame.body:ClearAllPoints()
  if focused then
    frame.body:SetPoint("TOPLEFT", INSET, -HEADER_TOP)
  else
    frame.body:SetPoint("TOPLEFT", frame.header, "BOTTOMLEFT", 0, -GAP)
  end
  frame.body:SetPoint("BOTTOMRIGHT", -INSET, INSET)

  frame.detail:ClearAllPoints()
  if focused then
    frame.detail:SetPoint("TOPLEFT")
  else
    frame.detail:SetPoint("TOPLEFT", frame.listPanel, "TOPRIGHT", GAP, 0)
  end
  frame.detail:SetPoint("BOTTOMRIGHT")
end

--- The corner the window is resized by
local function createResizeGrip()
  frame:SetResizable(true)
  local maxWidth, maxHeight = math.max(MIN_WIDTH, GetScreenWidth()), math.max(MIN_HEIGHT, GetScreenHeight())
  if frame.SetResizeBounds then
    frame:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT, maxWidth, maxHeight)
  else
    frame:SetMinResize(MIN_WIDTH, MIN_HEIGHT)
    frame:SetMaxResize(maxWidth, maxHeight)
  end

  local grip = CreateFrame("Button", nil, frame)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", -3, 3)
  grip:SetFrameLevel(frame:GetFrameLevel() + 20)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  grip:SetScript("OnMouseDown", function()
    frame:StartSizing("BOTTOMRIGHT")
  end)
  grip:SetScript("OnMouseUp", function()
    frame:StopMovingOrSizing()
    local window = settings()
    window.width, window.height = frame:GetWidth(), frame:GetHeight()
    MainFrame.Refresh()
  end)

  -- The selected game follows the window while it is being dragged to size
  frame:SetScript("OnSizeChanged", function()
    MainFrame.Refresh()
  end)
end

local function create()
  local window = settings()
  frame = CreateFrame("Frame", "ForeverGamesFrame", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(math.max(MIN_WIDTH, window.width), math.max(MIN_HEIGHT, window.height))
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
  frame.listPanel = createListPanel(frame.body)
  frame.detail = createDetailPanel(frame.body)
  frame.empty = createEmptyPanel(frame.body)
  arrange(false)
  createResizeGrip()

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
  frame.body:SetShown(not inWizard)

  if inWizard then
    frame.header:Hide()
    Wizard.Refresh()
  else
    local selected = selectedId and private.session:Get(selectedId)
    if not selected or selected.hidden then
      selected = private.session:List()[1]
      selectedId = selected and selected.id
    end
    local fresh = selected ~= nil and selected.unread == true
    if selected then
      -- Looking at a match is what clears its "something new" flag
      private.session:MarkRead(selected.id)
    end
    local list = private.session:List()

    -- Focus needs a game to focus on
    local focused = settings().focus and selected ~= nil
    arrange(focused)
    frame.header:SetShown(not focused)
    refreshHeader()
    frame.empty:SetShown(#list == 0)
    frame.listPanel:SetShown(#list > 0 and not focused)
    refreshList(list)
    refreshDetail(selected, fresh)
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
