--------------------------
--  Main window
--------------------------
-- The window opens on its front page: the logo, who is around to play, a way to start a game
-- and a way back into one, and the player's games, with a challenge answered right there. A
-- game that is picked takes the whole window, and has a way back to the front page. The window
-- knows nothing about any particular game: it gives the game's view a stage to draw on and
-- tells it which position to show. What every game shares is built here around that stage: the
-- status line, resigning and draw offers, the list of moves and stepping back through them. A
-- game the player plays alone has no opponent to name and nobody to wait for: it can be given
-- up or started again at any time, and a move can be taken back where the game allows it.
--
-- The window can be resized. The stage is given whatever room there is and the game's view
-- lays itself out in it.

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
local ROW_HEIGHT = 46
-- The games on the front page: no wider than this however wide the window is, and how wide the
-- buttons a game has there are
local LIST_WIDTH, ROW_BUTTON_WIDTH = 620, 84
-- Space between the window's edge and what is in it, and between the panels
local INSET, GAP = 14, 8
-- The logo is wider than it is high, and stretched into a square texture: see Tools/make_logo.py,
-- which also makes the light and the line the page it is on is dressed with, and what the shine
-- on its letters is made of
local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\"
local LOGO_HEIGHT, LOGO_ASPECT = 200, 1.591
-- With games to list under it the logo makes room: the share of the page's height it gets, and
-- how small it may become
local LOGO_SHARE, LOGO_SMALLEST = 0.27, 110
-- And how far under the top of the page it is then
local LOGO_TOP = 6
-- The two big buttons on the front page, and the space between them
local HOME_BUTTON_WIDTH, HOME_BUTTON_GAP = 200, 24
-- The blue the logo glows with
local LOGO_BLUE = { 0.16, 0.55, 1 }
-- The thin cloud of light that drifts behind it, in two layers that turn one each way: the
-- seconds each takes to go around, what colour it is and how bright, as alpha
local NEBULA = {
  { lap = 95, color = LOGO_BLUE, alpha = 0.3 },
  { lap = -65, color = { 0.45, 0.8, 1 }, alpha = 0.22 },
}
-- And how far each layer wanders from the middle of the logo as it turns
local NEBULA_WANDER = 14
-- Where the middle line of the logo's infinity sign runs, measured on the picture: how far under
-- the middle of the logo its crossing is, and how far its loops reach sideways and up and down,
-- as fractions of the logo's width and height
local LOOP_DROP, LOOP_REACH, LOOP_RISE = 0.245, 0.189, 0.082
-- The wisp that drifts around it: seconds for a lap, how many lights its tail is made of and
-- how many seconds each is behind the one before, and how many motes it sheds and how long
-- each lasts
local WISP_LAP, WISP_TAIL, WISP_GAP = 4.5, 24, 0.03
-- How often where the wisp is gets remembered, for its tail to be where it was
local WISP_STEP = 0.015
-- The tail stays clear of the wisp, so the two are told apart: how far from the middle of the
-- wisp it is gone altogether, and how much further out it is all there
local WISP_CLEAR, WISP_CLEAR_FADE = 15, 9
-- The tail is a pale thread with a blue light around it. The thread is drawn over the logo
-- rather than added to it, or it would be lost on the gold and on the blue alike
local WISP_THREAD = { 0.88, 0.97, 1 }
local WISP_MOTES, WISP_MOTE_LIFE = 8, 1.4
local WISP_CORE, WISP_HALO, WISP_TRAIL = { 0.75, 0.9, 1 }, { 0.2, 0.5, 1 }, { 0.35, 0.7, 1 }
-- What the game's own wisp looks like, the one a night elf is when dead, and how big a frame it
-- is shown in. Where the client doesn't have it the wisp is made of lights instead
local WISP_DISPLAY, WISP_MODEL_SIZE = 10045, 52
-- The shine that runs over the logo's gold letters: how many seconds apart, how long it takes to
-- cross them, and how soon after the page is shown the first one comes
local SHINE_EVERY, SHINE_SWEEP, SHINE_FIRST = 6.5, 1.5, 0.8
local SHINE_GOLD = { 1, 0.93, 0.7 }
-- The streak of light it is: how wide and high, and how far over the middle of the logo, as
-- fractions of the logo's width and height. It leans, its top being this much of its width
-- further right than its middle, see Tools/make_logo.py
local SHINE_WIDTH, SHINE_HEIGHT, SHINE_RISE, SHINE_LEAN = 0.3, 0.46, 0.045, 0.17
-- Where its middle starts and ends up, from the middle of the logo: just clear of the letters
local SHINE_FROM, SHINE_TO = -0.58, 0.6
-- The corners of letters that glint as it goes by, measured on the picture: of the F, the G, the
-- V, the S and the last R
local GLINTS = { { -0.393, 0.242 }, { -0.152, -0.004 }, { 0.16, 0.203 }, { 0.246, -0.004 }, { 0.426, -0.053 } }
-- How big a glint gets, and how far on the shine is when it has gone out, as fractions of the
-- logo's width
local GLINT_SIZE, GLINT_REACH = 0.15, 0.2
local AUTHOR, THANKS = "Jeany Beany", "Quetz"
-- The space between the words of the disclaimer where one text ends and the next begins
local DISCLAIMER_GAP = 3
local HEADER_TOP = 32
-- Room the selected game's panel keeps around the stage: its title above, the note and buttons below
local STAGE_TOP, STAGE_BOTTOM, STAGE_SIDE = 66, 72, 12
local MOVES_WIDTH = 150
local MOVE_ROW_HEIGHT = 20
local STEP_BUTTON_WIDTH = 36
-- Names listed in the "who is available" tooltip before it is cut short
local TOOLTIP_NAMES = 15
-- Opening the window looks for players again if the last look is older than this
local STALE_AFTER = 60
-- The box that says who is around, and what turns in it while that is being asked: how big it
-- is, how many dots it is made of and how many seconds they take to go around, and how big each
-- dot is
local PRESENCE_HEIGHT = 44
local SPINNER_SIZE, SPINNER_LIGHTS, SPINNER_LAP = 20, 8, 0.9
local SPINNER_DOT = 4
-- How long the front page says it is looking after a refresh
local LOOKING_FOR = 6

local DECLINE_REASONS = {
  off = "status_declined_off",
  nogame = "status_declined_nogame",
  version = "status_declined_version",
  busy = "status_declined_busy",
  strangers = "status_declined_strangers",
  gone = "status_declined_gone",
}
local SOURCE_LABELS = { guild = "source_guild", friend = "source_friend", other = "source_other" }

local frame
-- The game on screen. The front page is, while there is none
--- @type string?
local selectedId
-- The game that was on screen last, which is the one to go on with
--- @type string?
local lastId
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
--- @return { width: number, height: number, scale: number }
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
  local game = Games.Get(match.game)
  if not game then
    return L["status_missing_game"]
  end
  if Match.IsSolo(match) then
    -- Nobody to wait for and nobody to lose to: how it is going, as the game puts it
    local result = Match.Result(match)
    local progress = game.progress and game.progress(Match.State(match))
    if not result then
      return progress or L["status_solo"]
    elseif result.reason == "resign" then
      return L["status_gave_up"]
    elseif result.winner ~= match.me then
      -- The game itself said it was over, and not well
      return progress and L["status_solo_lost_with"]:format(progress) or L["status_solo_lost"]
    end
    return progress and L["status_won_with"]:format(progress) or L["status_won"]
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
    if result and Match.IsTogether(match) and result.reason == "resign" then
      -- Everyone left it
      return L["status_gave_up"]
    elseif result and result.all then
      local progress = game.progress and game.progress(Match.State(match))
      return progress and L["status_won_with"]:format(progress) or L["status_won"]
    elseif not result or result.winner == 0 then
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

  if Match.IsTogether(match) then
    -- Nobody is waited on: how it is going, as the game puts it
    return game.progress and game.progress(Match.State(match)) or L["status_together"]:format(opponent)
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
  -- A game played alone is always the player's to move in, and waits on nobody
  return match.status == "incoming" or (Match.IsMyTurn(match) and not Match.IsSolo(match))
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
  -- By the rules the last one was played by
  local newMatch, err = private.session:Invite(others, match.game, { options = match.options })
  if not newMatch then
    return report(err)
  end
  MainFrame.Select(newMatch.id)
end

-- For a game played alone: `data` is what giving it up is followed by
StaticPopupDialogs["FOREVERGAMES_GIVE_UP"] = {
  text = "%s",
  button1 = YES,
  button2 = NO,
  OnAccept = function(_, proceed)
    proceed()
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}

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

--- Buttons offered for a game the player plays alone, in display order
--- @param match Match
--- @return { text: string, onClick: fun(), disabled: boolean? }[]
local function soloActionsFor(match)
  local session, id = private.session, match.id
  local game = Games.Get(match.game)
  local name = game and game.name or match.game

  local function forget()
    session:Forget(id)
  end
  local function again()
    rematch(match)
  end
  -- The game that is given up for another doesn't stay around
  local function another()
    session:Forget(id)
    rematch(match)
  end
  --- Does it at once in a game nothing has happened in yet, and asks first in any other
  --- @param question string
  --- @param proceed fun()
  --- @return fun()
  local function afterAsking(question, proceed)
    return function()
      if #match.log == 0 then
        proceed()
      else
        StaticPopup_Show("FOREVERGAMES_GIVE_UP", L[question]:format(name), nil, proceed)
      end
    end
  end

  if match.status ~= "active" then
    return { { text = L["play_again"], onClick = again }, { text = L["remove"], onClick = forget } }
  end
  local actions = {
    { text = L["give_up"], onClick = afterAsking("give_up_confirm", forget) },
    { text = L["start_another"], onClick = afterAsking("start_another_confirm", another) },
  }
  if game and game.undo then
    actions[3] = {
      text = L["undo"],
      disabled = not session:CanUndo(match),
      onClick = function()
        session:Undo(id)
      end,
    }
  end
  return actions
end

--- Buttons offered for a match, in display order
--- @param match Match
--- @return { text: string, onClick: fun(), disabled: boolean? }[]
local function actionsFor(match)
  local session, id = private.session, match.id
  if Match.IsSolo(match) then
    return soloActionsFor(match)
  end

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
    if Match.IsTogether(match) then
      -- Nobody is beaten by it: the others play on
      StaticPopup_Show("FOREVERGAMES_GIVE_UP", L["leave_confirm"]:format(MainFrame.Names(match)), nil, function()
        session:Resign(id)
      end)
      return
    end
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
    local actions = { { text = L[Match.IsTogether(match) and "leave" or "resign"], onClick = resign } }
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
-- Who is around
-----------------------------

--- Asks who is online again, if it hasn't just been done
local function lookForPlayers()
  if not private.presence:CanAnnounce() then
    return
  end
  private.presence:Announce()
  MainFrame.Refresh()
end

local function refreshPresence()
  local presence = frame.home.presence
  local counts = private.presence:Counts()
  local since = private.presence:SinceAnnounce()
  presence.refresh:SetEnabled(private.presence:CanAnnounce())

  -- While the answers are still coming in the dot gives way to something that turns
  local looking = since ~= nil and since < LOOKING_FOR
  presence.spinner:SetShown(looking)
  presence.dot:SetShown(not looking)

  if counts.total == 0 and looking then
    presence.title:SetText(L["presence_looking"])
    presence.title:SetTextColor(1, 1, 1)
    presence.detail:SetText(L["presence_looking_detail"])
    return
  end

  if counts.total == 0 then
    presence.dot:SetColorTexture(0.45, 0.45, 0.45)
    presence.title:SetText(L["presence_none"])
    presence.title:SetTextColor(unpack(Widgets.GREY))
    presence.detail:SetText(L["presence_none_detail"])
    return
  end

  presence.dot:SetColorTexture(unpack(Widgets.GREEN))
  presence.title:SetText((counts.total == 1 and L["presence_one"] or L["presence_many"]):format(counts.total))
  presence.title:SetTextColor(1, 1, 1)

  local parts = {}
  for _, source in ipairs({ "guild", "friend", "other" }) do
    if counts[source] > 0 then
      parts[#parts + 1] = L["presence_" .. source]:format(counts[source])
    end
  end
  presence.detail:SetText(table.concat(parts, "  |cff666666-|r  "))
end

--- @param owner Frame
local function showPresenceTooltip(owner)
  local players = private.presence:List()
  GameTooltip:SetOwner(owner, "ANCHOR_BOTTOM")
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

--- Lights in a ring that brighten one after the other, around and around, for as long as it is
--- shown: something is being waited for
--- @param parent Frame
--- @return Frame
local function createSpinner(parent)
  local spinner = CreateFrame("Frame", nil, parent)
  spinner:SetSize(SPINNER_SIZE, SPINNER_SIZE)

  local lights = {}
  for index = 1, SPINNER_LIGHTS do
    local angle = (index - 1) / SPINNER_LIGHTS * 2 * math.pi
    -- Dots with an edge to them: soft lights this small run into one blur
    local light = spinner:CreateTexture(nil, "ARTWORK")
    light:SetTexture(IMAGES .. "Board\\dot")
    light:SetVertexColor(unpack(Widgets.GOLD))
    light:SetSize(SPINNER_DOT, SPINNER_DOT)
    -- Clockwise from the top
    local reach = (SPINNER_SIZE - SPINNER_DOT) / 2
    light:SetPoint("CENTER", math.sin(angle) * reach, math.cos(angle) * reach)
    lights[index] = light
  end

  local turned = 0
  spinner:SetScript("OnUpdate", function(_, elapsed)
    turned = (turned + elapsed / SPINNER_LAP) % 1
    for index, light in ipairs(lights) do
      -- Brightest where the turn has just been, fading the longer ago that was
      local behind = (turned - (index - 1) / SPINNER_LIGHTS) % 1
      light:SetAlpha(0.15 + 0.85 * (1 - behind) ^ 2)
    end
  end)
  return spinner
end

--- Who is around to play, in a box of its own: two lines, and a way to ask again
--- @param parent Frame
--- @return Frame
local function createPresence(parent)
  -- The summary is one hover target that lists who it is counting
  local presence = Widgets.Panel(parent)
  presence:SetHeight(PRESENCE_HEIGHT)
  presence:EnableMouse(true)
  presence:SetScript("OnEnter", showPresenceTooltip)
  presence:SetScript("OnLeave", GameTooltip_Hide)

  presence.dot = presence:CreateTexture(nil, "ARTWORK")
  presence.dot:SetSize(10, 10)
  presence.dot:SetPoint("CENTER", presence, "LEFT", 22, 0)

  presence.spinner = createSpinner(presence)
  presence.spinner:SetPoint("CENTER", presence.dot)
  presence.spinner:Hide()

  presence.refresh = Widgets.Button(presence, L["presence_refresh"], 84, 24)
  presence.refresh:SetPoint("RIGHT", -10, 0)
  presence.refresh:SetScript("OnClick", lookForPlayers)
  presence.refresh:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(L["presence_refresh"])
    GameTooltip:AddLine(L["presence_refresh_tooltip"], 1, 1, 1, true)
    GameTooltip:Show()
  end)
  presence.refresh:SetScript("OnLeave", GameTooltip_Hide)

  presence.title = Widgets.Label(presence, "GameFontNormal")
  presence.title:SetPoint("TOPLEFT", 42, -8)
  presence.title:SetPoint("RIGHT", presence.refresh, "LEFT", -10, 0)
  presence.title:SetWordWrap(false)

  presence.detail = Widgets.Label(presence, "GameFontHighlightSmall")
  presence.detail:SetPoint("TOPLEFT", presence.title, "BOTTOMLEFT", 0, -4)
  presence.detail:SetPoint("RIGHT", presence.refresh, "LEFT", -10, 0)
  presence.detail:SetWordWrap(false)
  presence.detail:SetTextColor(unpack(Widgets.GREY))
  return presence
end

-----------------------------
-- Game list
-----------------------------

--- What a game is called in a list: who it is with and what it is, or just what it is
--- @param match Match
--- @return string
local function nameFor(match)
  local game = Games.Get(match.game)
  local name = game and game.name or match.game
  if Match.IsSolo(match) then
    return name
  end
  return MainFrame.Names(match) .. "  |cff808080" .. name .. "|r"
end

--- What can be done about a game without opening it: answering a challenge, taking one back,
--- and clearing away or playing again one that is over. A game that is being played is opened
--- @param match Match
--- @return { text: string, onClick: fun(), disabled: boolean? }[]
local function listActionsFor(match)
  if match.status == "active" then
    return {}
  end
  return actionsFor(match)
end

--- @param content Frame
--- @return Button
local function createRow(content)
  local row = CreateFrame("Button", nil, content)

  local hover = row:CreateTexture(nil, "HIGHLIGHT")
  hover:SetAllPoints()
  hover:SetColorTexture(1, 1, 1, 0.07)

  -- Flashing edge for games that are waiting on the player
  row.marker = row:CreateTexture(nil, "ARTWORK")
  row.marker:SetSize(4, ROW_HEIGHT - 10)
  row.marker:SetPoint("LEFT", 2, 0)
  row.marker:SetColorTexture(unpack(Widgets.GREEN))
  row.markerPulse = Widgets.Pulse(row.marker)

  row.icon = Widgets.Icon(row, private.ICON, 32)
  row.icon:SetPoint("LEFT", 12, 0)

  row.name = Widgets.Label(row, "GameFontNormal")
  row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 10, -1)
  row.name:SetWordWrap(false)

  row.status = Widgets.Label(row, "GameFontHighlightSmall")
  row.status:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 10, 1)
  row.status:SetWordWrap(false)
  row.statusPulse = Widgets.Pulse(row.status)

  row.buttons = {}
  for index = 1, 2 do
    local button = Widgets.Button(row, "", ROW_BUTTON_WIDTH, 22)
    button:SetPoint("RIGHT", -10 - (index - 1) * (ROW_BUTTON_WIDTH + 4), 0)
    row.buttons[index] = button
  end

  row:SetScript("OnClick", function(self)
    MainFrame.Select(self.matchId)
  end)
  return row
end

--- @param row Button
--- @param match Match
local function fillRow(row, match)
  local waiting = waitingOnMe(match)

  row.matchId = match.id
  row.icon:SetTexture(iconFor(match))
  row.name:SetText(nameFor(match))

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

  -- The first thing to do is the one nearest the name
  local actions = listActionsFor(match)
  for index, button in ipairs(row.buttons) do
    local action = actions[#actions + 1 - index]
    button:SetShown(action ~= nil)
    if action then
      button:SetText(action.text)
      button:SetEnabled(not action.disabled)
      button:SetScript("OnClick", function()
        local challenge = match.status == "incoming"
        action.onClick()
        -- A challenge is taken up to play it
        if challenge and match.status == "active" then
          MainFrame.Select(match.id)
        end
      end)
    end
  end
  -- The texts end where the buttons begin
  local room = -10 - #actions * (ROW_BUTTON_WIDTH + 4)
  row.name:SetPoint("RIGHT", room, 0)
  row.status:SetPoint("RIGHT", room, 0)
end

--- @param parent Frame
--- @return Frame
local function createListPanel(parent)
  local panel = Widgets.Panel(parent)

  panel.title = Widgets.Label(panel, "GameFontNormal", L["list_title"])
  panel.title:SetPoint("TOPLEFT", 12, -9)

  panel.waiting = Widgets.Label(panel, "GameFontHighlightSmall")
  panel.waiting:SetPoint("TOPRIGHT", -12, -10)
  panel.waiting:SetTextColor(unpack(Widgets.GREEN))
  panel.waitingPulse = Widgets.Pulse(panel.waiting)

  panel.list = Widgets.List(panel, LIST_WIDTH - 8, ROW_HEIGHT, createRow)
  panel.list.frame:SetPoint("TOPLEFT", 4, -28)
  panel.list.frame:SetPoint("BOTTOMRIGHT", -4, 4)
  return panel
end

--- The games that can't go on until the player does something, in the order they are listed
--- @param list Match[]
--- @param except string? A match to leave out
--- @return Match[]
local function waitingIn(list, except)
  local waiting = {}
  for _, match in ipairs(list) do
    if match.id ~= except and waitingOnMe(match) then
      waiting[#waiting + 1] = match
    end
  end
  return waiting
end

--- @param list Match[]
--- @param width number How wide the panel is
local function refreshList(list, width)
  local panel = frame.home.listPanel
  local waiting = #waitingIn(list)

  panel.list:SetWidth(width - 8)
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
  detail:SetAllPoints()

  detail.icon = Widgets.Icon(detail, private.ICON, 40)
  detail.icon:SetPoint("TOPLEFT", 14, -12)

  detail.header = Widgets.Label(detail, "GameFontNormalLarge")
  detail.header:SetPoint("TOPLEFT", detail.icon, "TOPRIGHT", 12, -2)

  detail.status = Widgets.Label(detail, "GameFontHighlight")
  detail.status:SetPoint("TOPLEFT", detail.header, "BOTTOMLEFT", 0, -5)
  detail.statusPulse = Widgets.Pulse(detail.status)

  -- Back to the front page, where the other games are
  detail.home = Widgets.Button(detail, L["home"], 96, 22)
  detail.home:SetPoint("TOPRIGHT", -STAGE_SIDE, -12)
  detail.home:SetScript("OnClick", function()
    MainFrame.Home()
  end)

  -- Straight on to another game that is waiting on the player, while there is one
  detail.next = Widgets.Button(detail, "", 150, 22)
  detail.next:SetPoint("RIGHT", detail.home, "LEFT", -6, 0)
  detail.next:SetScript("OnClick", function()
    local waiting = waitingIn(private.session:List(), selectedId)
    if waiting[1] then
      MainFrame.Select(waiting[1].id)
    end
  end)

  detail.seat = Widgets.Label(detail, "GameFontDisableSmall")
  detail.seat:SetPoint("TOPRIGHT", detail.home, "BOTTOMRIGHT", -2, -6)

  -- Says so when whoever set the game up changed its rules, and what to when pointed at
  detail.rules = CreateFrame("Frame", nil, detail)
  detail.rules:SetPoint("RIGHT", detail.seat, "LEFT", -10, 0)
  detail.rules:EnableMouse(true)
  detail.rules.label = Widgets.Label(detail.rules, "GameFontNormalSmall", L["rules_custom"])
  detail.rules.label:SetPoint("RIGHT")
  detail.rules:SetSize(detail.rules.label:GetStringWidth() + 4, 14)
  detail.rules:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
    GameTooltip:SetText(L["rules_custom"])
    GameTooltip:AddLine(L["rules_custom_tip"], 1, 1, 1, true)
    for _, line in ipairs(self.lines or {}) do
      GameTooltip:AddLine(line, unpack(Widgets.GOLD))
    end
    GameTooltip:Show()
  end)
  detail.rules:SetScript("OnLeave", GameTooltip_Hide)

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
  for index = 1, 3 do
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
  local game = match and Games.Get(match.game)
  local showBoard = game ~= nil and (match.status == "active" or match.status == "finished") and Match.Started(match)
  -- The view that stays is left as it is: hiding it would take whatever is in the player's hand
  -- out of it, and stop what is on the move
  for id, entry in pairs(views) do
    if not (showBoard and id == game.id) then
      entry.stage:Hide()
    end
  end
  for _, button in ipairs(detail.buttons) do
    button:Hide()
  end
  detail:SetShown(match ~= nil)
  if not match then
    return
  end

  local waiting = waitingOnMe(match)

  detail.icon:SetTexture(iconFor(match))
  if Match.IsSolo(match) then
    detail.header:SetText(game and game.name or match.game)
  else
    local title = L[#match.players > 2 and "with_players" or "versus"]
    detail.header:SetText(title:format(game and game.name or match.game, MainFrame.Names(match)))
  end
  detail.status:SetText(MainFrame.Describe(match))
  local others = #waitingIn(private.session:List(), match.id)
  detail.next:SetShown(others > 0)
  detail.next:SetText(L["next_waiting"]:format(others))
  if waiting then
    detail.status:SetTextColor(unpack(Widgets.GREEN))
    detail.statusPulse:Play()
  else
    detail.status:SetTextColor(1, 1, 1)
    detail.statusPulse:Stop()
    detail.status:SetAlpha(1)
  end

  local history = showBoard and game.history == true
  detail.seat:SetText((showBoard and game.seatLabel) and L["you_are"]:format(game.seatLabel(match.me, #match.players)) or "")
  -- A challenge says what it is a challenge to: the rules are part of what is being accepted
  local rules = game and Games.DescribeOptions(game, match.options) or {}
  local message = MainFrame.Describe(match)
  if #rules > 0 then
    message = message .. "\n\n|cffffd100" .. L["rules_custom"] .. "|r\n|cffffffff" .. table.concat(rules, "\n") .. "|r"
  end
  detail.message:SetText(showBoard and "" or message)
  detail.rules.lines = rules
  detail.rules:SetShown(showBoard and #rules > 0)
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
      state = Match.Visible(match, ply),
      seat = match.me,
      names = names,
      canMove = live and Match.CanMove(match),
      submit = function(move)
        local ok, err = private.session:Move(match.id, move)
        if not ok then
          report(err)
        end
      end,
      clock = function()
        return private.session:Elapsed(match)
      end,
      best = function(key)
        return private.session:Best(match.game, key), private.session:SetBest(match, key)
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
    button:SetEnabled(not action.disabled)
    button:Show()
  end
end

-----------------------------
-- Front page
-----------------------------

--- A soft light behind something, which slowly swells and dims
--- @param parent Frame
--- @param color number[]
--- @param from number How bright it is at its dimmest, as alpha
--- @param to number
--- @param seconds number From one to the other
--- @return Texture
local function createGlow(parent, color, from, to, seconds)
  local glow = parent:CreateTexture(nil, "BACKGROUND")
  glow:SetTexture(IMAGES .. "glow")
  glow:SetBlendMode("ADD")
  glow:SetVertexColor(unpack(color))
  glow:SetAlpha(from)

  local group = glow:CreateAnimationGroup()
  group:SetLooping("BOUNCE")
  local fade = group:CreateAnimation("Alpha")
  fade:SetFromAlpha(from)
  fade:SetToAlpha(to)
  fade:SetDuration(seconds)
  fade:SetSmoothing("IN_OUT")
  group:Play()
  return glow
end

--- A thin cloud of light behind something, which drifts for as long as it is shown: two layers
--- that turn slowly, one each way, and wander a little, so that its wisps pass over each other
--- and no moment looks like another
--- @param parent Frame Whose it is, and behind what else of it it is drawn
--- @param within Region It ends where this does, however far it would reach
--- @return Frame nebula Hidden, the cloud keeps still
local function createNebula(parent, within)
  local edge = parent:CreateMaskTexture()
  edge:SetTexture("Interface\\Buttons\\WHITE8X8", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  edge:SetAllPoints(within)

  local layers = {}
  for index, kind in ipairs(NEBULA) do
    local texture = parent:CreateTexture(nil, "BACKGROUND")
    texture:SetTexture(IMAGES .. "nebula")
    texture:SetBlendMode("ADD")
    texture:SetVertexColor(unpack(kind.color))
    texture:SetAlpha(kind.alpha)
    -- As far as the light it is in reaches, which is as far again as the logo to every side
    texture:SetPoint("CENTER", parent, "CENTER")
    texture:SetSize(parent:GetWidth() * 2, parent:GetHeight() * 2)
    texture:AddMaskTexture(edge)
    layers[index] = texture
  end

  local nebula = CreateFrame("Frame", nil, parent)
  local clock = 0
  nebula:SetScript("OnUpdate", function(_, elapsed)
    clock = clock + math.min(elapsed, 0.1)
    for index, texture in ipairs(layers) do
      -- What is turned is the picture, inside the shape it is stretched to
      texture:SetRotation(clock / NEBULA[index].lap * 2 * math.pi)
      -- Each layer goes its own way around the middle, and swells and dims in its own time
      local pace = 0.11 + 0.04 * index
      texture:SetPoint("CENTER", parent, "CENTER", NEBULA_WANDER * math.sin(clock * pace + 2 * index), 0.6 * NEBULA_WANDER * math.sin(clock * pace * 1.6 + index))
      texture:SetAlpha(NEBULA[index].alpha * (0.8 + 0.2 * math.sin(clock * (0.5 + 0.2 * index) + 2 * index)))
    end
  end)
  return nebula
end

--- One of the round lights a wisp is made of
--- @param parent Frame
--- @param color number[]
--- @return Texture
local function createLight(parent, color)
  local light = parent:CreateTexture(nil, "OVERLAY")
  light:SetTexture(IMAGES .. "glow")
  light:SetBlendMode("ADD")
  light:SetVertexColor(unpack(color))
  return light
end

--- A wisp that drifts around the infinity sign of the logo for as long as it is shown: the game's
--- own, or a pale heart in a blue halo that flickers where the client has none, with a tail that
--- wavers behind it and motes that float up off it
--- @param parent Frame
--- @param logo Region
--- @return Frame wisp Hidden, it is gone and costs nothing
local function createWisp(parent, logo)
  -- Its own frame, so the lights are drawn over the logo and only move while it is on screen
  local wisp = CreateFrame("Frame", nil, parent)
  wisp:SetAllPoints(logo)

  local tail, motes = {}, {}
  for index = 1, WISP_TAIL do
    tail[index] = { glow = createLight(wisp, WISP_TRAIL), thread = createLight(wisp, WISP_THREAD) }
    tail[index].thread:SetBlendMode("BLEND")
  end
  for index = 1, WISP_MOTES do
    motes[index] = { light = createLight(wisp, WISP_HALO), age = WISP_MOTE_LIFE, x = 0, y = 0, drift = 0 }
    motes[index].light:Hide()
  end
  local halo, core = createLight(wisp, WISP_HALO), createLight(wisp, WISP_CORE)
  core:SetSize(16, 16)

  local model = CreateFrame("PlayerModel", nil, wisp)
  model:SetSize(WISP_MODEL_SIZE, WISP_MODEL_SIZE)
  -- A model forgets what it is of while hidden
  model:SetScript("OnShow", function()
    model:SetDisplayInfo(WISP_DISPLAY)
  end)
  model:SetDisplayInfo(WISP_DISPLAY)

  --- Where on the logo the wisp is a part of a lap in, from the middle of the logo
  --- @param lap number
  --- @return number x, number y
  local function along(lap)
    -- A figure of eight: once across and back while twice up and down
    local angle = lap * 2 * math.pi
    return LOOP_REACH * logo:GetWidth() * math.cos(angle), (LOOP_RISE * math.sin(2 * angle) - LOOP_DROP) * logo:GetHeight()
  end

  -- Where it has been, newest first, a WISP_STEP apart: x and y in turn
  local trail, kept = {}, 2 * (math.ceil(WISP_TAIL * WISP_GAP / WISP_STEP) + 2)
  local clock, lap, owed, shed, nextMote = 0, 0, 0, 0, 1
  local lastX, lastY
  wisp:SetScript("OnUpdate", function(_, elapsed)
    -- A stutter shouldn't fling it across the logo
    elapsed = math.min(elapsed, 0.1)
    clock = clock + elapsed

    -- It doesn't keep a pace: it lingers, then glides on, and never quite the same way twice
    local pace = 1 + 0.55 * math.sin(clock * 0.83) + 0.3 * math.sin(clock * 2.09 + 2)
    lap = lap + elapsed / WISP_LAP * pace

    -- Nor does it keep to the line. It floats, rising and sinking and wandering to the sides
    local x, y = along(lap)
    x = x + 2.5 * math.sin(clock * 1.37 + 1) + 1 * math.sin(clock * 4.1)
    y = y + 4 * math.sin(clock * 1.9) + 1.5 * math.sin(clock * 3.3 + 0.5)
    core:SetPoint("CENTER", logo, "CENTER", x, y)
    halo:SetPoint("CENTER", logo, "CENTER", x, y)
    model:SetPoint("CENTER", logo, "CENTER", x, y)
    -- The lights stand in for the model for as long as there is none
    local drawn = not (model.GetModelFileID and model:GetModelFileID())
    core:SetShown(drawn)
    halo:SetShown(drawn)

    -- Two waves that never quite line up make the halo flicker without a beat to it
    local flicker = 0.5 + 0.25 * math.sin(clock * 7.3) + 0.25 * math.sin(clock * 11.9 + 1)
    halo:SetAlpha(0.5 + 0.3 * flicker)
    local size = 40 + 8 * flicker
    halo:SetSize(size, size)

    -- Remember the way it came since the last time, however long ago that was
    lastX, lastY = lastX or x, lastY or y
    owed = owed + elapsed
    local steps = math.floor(owed / WISP_STEP)
    owed = owed - steps * WISP_STEP
    for step = 1, steps do
      local part = step / steps
      table.insert(trail, 1, lastY + (y - lastY) * part)
      table.insert(trail, 1, lastX + (x - lastX) * part)
    end
    for index = #trail, kept + 1, -1 do
      trail[index] = nil
    end
    lastX, lastY = x, y

    -- The tail is where the wisp was, so it bunches up where it lingers and draws out where it
    -- glides, thinning towards its end. It is a thin thing next to the wisp, and isn't drawn
    -- where it would run into it
    for index, light in ipairs(tail) do
      local fade = 1 - index / (WISP_TAIL + 1)
      local at = 2 * math.floor(index * WISP_GAP / WISP_STEP)
      local tailX, tailY = trail[at + 1] or x, trail[at + 2] or y
      local away = math.sqrt((tailX - x) ^ 2 + (tailY - y) ^ 2)
      local clear = math.max(0, math.min(1, (away - WISP_CLEAR) / WISP_CLEAR_FADE))
      local size = 4 + 7 * fade
      light.thread:SetPoint("CENTER", logo, "CENTER", tailX, tailY)
      light.thread:SetAlpha(fade * clear)
      light.thread:SetSize(size, size)
      light.glow:SetPoint("CENTER", logo, "CENTER", tailX, tailY)
      light.glow:SetAlpha(0.7 * fade * clear)
      light.glow:SetSize(size * 2.6, size * 2.6)
    end

    -- Every so often a mote comes off it, and floats up as it goes out
    shed = shed + elapsed
    if shed >= WISP_MOTE_LIFE / WISP_MOTES then
      shed = 0
      local mote = motes[nextMote]
      nextMote = nextMote % WISP_MOTES + 1
      mote.age, mote.x, mote.y, mote.drift = 0, x, y, math.sin(clock * 13) * 6
      mote.light:Show()
    end
    for _, mote in ipairs(motes) do
      if mote.age < WISP_MOTE_LIFE then
        mote.age = mote.age + elapsed
        local progress = math.min(1, mote.age / WISP_MOTE_LIFE)
        mote.light:SetPoint("CENTER", logo, "CENTER", mote.x + mote.drift * progress, mote.y + 14 * progress)
        mote.light:SetAlpha(0.8 * (1 - progress))
        mote.light:SetSize(7 - 3 * progress, 7 - 3 * progress)
        mote.light:SetShown(progress < 1)
      end
    end
  end)
  return wisp
end

--- A shine that runs over the gold letters of the logo every so often, for as long as it is
--- shown: a leaning streak of light that falls on the letters alone, and a glint off a corner
--- of one here and there as it goes by
--- @param parent Frame
--- @param logo Region
--- @return Frame shimmer Hidden, it is gone and costs nothing
local function createShimmer(parent, logo)
  local shimmer = CreateFrame("Frame", nil, parent)
  shimmer:SetAllPoints(logo)

  -- The streak is only drawn where the letters are
  local letters = shimmer:CreateMaskTexture()
  letters:SetTexture(IMAGES .. "lettering", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  letters:SetAllPoints(logo)
  local streak = shimmer:CreateTexture(nil, "ARTWORK")
  streak:SetTexture(IMAGES .. "sheen")
  streak:SetBlendMode("ADD")
  streak:SetVertexColor(unpack(SHINE_GOLD))
  streak:AddMaskTexture(letters)

  local glints = {}
  for index in ipairs(GLINTS) do
    glints[index] = shimmer:CreateTexture(nil, "OVERLAY")
    glints[index]:SetTexture(IMAGES .. "spark")
    glints[index]:SetBlendMode("ADD")
    glints[index]:SetVertexColor(unpack(SHINE_GOLD))
  end

  local clock = 0
  -- The first one comes soon after the page is shown, rather than whenever it is next due
  shimmer:SetScript("OnShow", function()
    clock = SHINE_EVERY - SHINE_FIRST
  end)
  shimmer:SetScript("OnUpdate", function(_, elapsed)
    clock = (clock + math.min(elapsed, 0.1)) % SHINE_EVERY
    local part = clock / SHINE_SWEEP
    streak:SetShown(part < 1)
    if part >= 1 then
      for _, glint in ipairs(glints) do
        glint:Hide()
      end
      return
    end

    -- It sets off gently and slows down at the end, without ever quite stopping
    local width, height = logo:GetWidth(), logo:GetHeight()
    local at = SHINE_FROM + (SHINE_TO - SHINE_FROM) * (0.5 * part + 0.5 * part * part * (3 - 2 * part))
    streak:SetSize(SHINE_WIDTH * width, SHINE_HEIGHT * height)
    streak:SetPoint("CENTER", logo, "CENTER", at * width, SHINE_RISE * height)
    streak:SetAlpha(0.9 * math.min(1, 5 * part, 5 * (1 - part)))

    -- A corner glints from when the middle of the streak reaches it: it swells, turning, and
    -- is gone again by the time the streak is a little further on
    for index, glint in ipairs(glints) do
      local x, y = GLINTS[index][1], GLINTS[index][2]
      local past = (at + SHINE_LEAN * SHINE_WIDTH * 2 * (y - SHINE_RISE) / SHINE_HEIGHT - x) / GLINT_REACH
      glint:SetShown(past > 0 and past < 1)
      if past > 0 and past < 1 then
        local swell = math.sin(math.pi * past)
        local size = GLINT_SIZE * width * (0.45 + 0.55 * swell)
        glint:SetPoint("CENTER", logo, "CENTER", x * width, y * height)
        glint:SetSize(size, size)
        glint:SetAlpha(swell)
        glint:SetRotation(0.5 * past)
      end
    end
  end)
  return shimmer
end

--- A line across that fades out at both ends
--- @param parent Frame
--- @param width number
--- @param color number[]
--- @param alpha number
--- @return Texture
local function createRule(parent, width, color, alpha)
  local rule = parent:CreateTexture(nil, "ARTWORK")
  rule:SetTexture(IMAGES .. "rule")
  rule:SetSize(width, 2)
  rule:SetVertexColor(color[1], color[2], color[3], alpha)
  return rule
end

--- The game to go on with: one that is waiting on the player, else the one they looked at last
--- if it is still being played, else any that is
--- @param list Match[]
--- @return Match?
local function gameToContinue(list)
  local waiting = waitingIn(list)[1]
  if waiting then
    return waiting
  end
  local playing
  for _, match in ipairs(list) do
    if match.status == "active" then
      if match.id == lastId then
        return match
      end
      playing = playing or match
    end
  end
  return playing
end

--- The page the window opens on, and the one it shows whenever no game is picked: the logo, who
--- is around, a way to start a game and one to go on with one, the player's games, and who the
--- addon is by
--- @param body Frame
--- @return Frame
local function createHomePanel(body)
  local home = Widgets.Panel(body)
  home:SetAllPoints()

  -- The logo and what glows and drifts around it, as one thing that is made smaller as one
  local crest = CreateFrame("Frame", nil, home)
  crest:SetSize(LOGO_HEIGHT * LOGO_ASPECT, LOGO_HEIGHT)
  home.crest = crest

  local logo = Widgets.Icon(crest, IMAGES .. "logo", LOGO_HEIGHT)
  logo:SetAllPoints()

  -- The light behind it reaches as far again as the logo to every side, see refreshHome
  home.halo = createGlow(crest, LOGO_BLUE, 0.22, 0.42, 3.5)
  home.halo:SetWidth(LOGO_HEIGHT * LOGO_ASPECT * 2)
  home.halo:SetPoint("BOTTOM", crest, "CENTER", 0, -LOGO_HEIGHT)
  home.nebula = createNebula(crest, home.halo)

  -- The wisp is in front of the shine on the letters
  home.shimmer = createShimmer(crest, crest)
  home.wisp = createWisp(crest, crest)
  home.wisp:SetFrameLevel(home.shimmer:GetFrameLevel() + 1)

  local rule = createRule(home, 340, Widgets.GOLD, 0.7)
  rule:SetPoint("TOP", crest, "BOTTOM", 0, -4)

  home.presence = createPresence(home)
  home.presence:SetPoint("TOP", rule, "BOTTOM", 0, -10)
  -- It shows things that change with time alone: the "looking" message after a refresh and
  -- whether Refresh can be pressed again
  local sinceUpdate = 0
  home.presence:SetScript("OnUpdate", function(_, elapsed)
    sinceUpdate = sinceUpdate + elapsed
    if sinceUpdate >= 1 then
      sinceUpdate = 0
      refreshPresence()
    end
  end)

  -- Said only while there are no games to list instead
  home.title = Widgets.Label(home, "GameFontNormalHuge", L["empty_title"])
  home.title:SetPoint("TOP", home.presence, "BOTTOM", 0, -12)

  home.blurb = Widgets.Label(home, "GameFontHighlight", L["empty_text"])
  home.blurb:SetPoint("TOP", home.title, "BOTTOM", 0, -8)
  home.blurb:SetWidth(460)
  home.blurb:SetJustifyH("CENTER")
  home.blurb:SetSpacing(2)
  home.blurb:SetTextColor(unpack(Widgets.GREY))

  -- The two big buttons sit side by side in a row of their own, or the one in the middle of it
  home.actions = CreateFrame("Frame", nil, home)
  home.actions:SetSize(HOME_BUTTON_WIDTH * 2 + HOME_BUTTON_GAP, 38)

  home.newGame = Widgets.Button(home.actions, L["new_game"], HOME_BUTTON_WIDTH, 38)
  home.newGame:SetScript("OnClick", function()
    MainFrame.NewGame()
  end)

  home.continue = Widgets.Button(home.actions, L["continue_game"], HOME_BUTTON_WIDTH, 38)
  home.continue:SetPoint("RIGHT")
  home.continue:SetScript("OnClick", function(self)
    MainFrame.Select(self.target)
  end)
  for _, button in ipairs({ home.newGame, home.continue }) do
    button:SetNormalFontObject("GameFontNormalLarge")
    button:SetHighlightFontObject("GameFontHighlightLarge")
  end

  -- The games for a room have a window of their own, see GUI/Party.lua
  home.party = Widgets.Button(home, L["party_open"], 130, 26)
  home.party:SetPoint("TOPRIGHT", -12, -12)
  home.party:SetScript("OnClick", function()
    private.Party.Open()
  end)

  -- Which game that is
  home.continuing = Widgets.Label(home.actions, "GameFontHighlightSmall")
  home.continuing:SetPoint("TOP", home.continue, "BOTTOM", 0, -4)
  home.continuing:SetWidth(HOME_BUTTON_WIDTH + HOME_BUTTON_GAP)
  home.continuing:SetJustifyH("CENTER")
  home.continuing:SetWordWrap(false)
  home.continuing:SetTextColor(unpack(Widgets.GREY))

  -- The small print, from the bottom up
  -- One line with the words that matter most in it drawn heavier. A text can't change weight
  -- part of the way, so it is three texts in a row
  local before, after = L["empty_disclaimer"]:match("^(.-)%s*%%s%s*(.*)$")
  local disclaimer = CreateFrame("Frame", nil, home)
  disclaimer:SetPoint("BOTTOM", 0, 12)
  local parts, width = {}, 0
  for index, text in ipairs({ before or L["empty_disclaimer"], L["disclaimer_stress"], after or "" }) do
    local part = Widgets.Label(disclaimer, "GameFontDisableSmall", text)
    part:SetTextColor(unpack(Widgets.RED))
    if index == 2 then
      -- The client has no bold of this font: an outline in its own colour is what makes it heavy
      local font, size = part:GetFont()
      part:SetFont(font, size, "OUTLINE")
      part:SetTextColor(1, 0.42, 0.36)
    end
    if index == 1 then
      part:SetPoint("LEFT")
    else
      part:SetPoint("LEFT", parts[index - 1], "RIGHT", DISCLAIMER_GAP, 0)
    end
    parts[index] = part
    width = width + part:GetStringWidth()
  end
  disclaimer:SetSize(width + 2 * DISCLAIMER_GAP, 12)

  local gold = "|cffffd100%s|r"
  local credits = Widgets.Label(home, "GameFontHighlightSmall")
  credits:SetPoint("BOTTOM", disclaimer, "TOP", 0, 6)
  credits:SetTextColor(unpack(Widgets.GREY))
  credits:SetText(table.concat({
    L["empty_version"]:format(gold:format(C_AddOns.GetAddOnMetadata(private.ADDON_NAME, "Version"))),
    L["empty_created"]:format(gold:format(AUTHOR)),
    L["empty_thanks"]:format(gold:format(THANKS)) .. " |T" .. IMAGES .. "heart:12:12|t",
  }, "    |cff555555\194\183|r    "))

  local line = createRule(home, 560, { 1, 1, 1 }, 0.22)
  line:SetPoint("BOTTOM", credits, "TOP", 0, 8)

  -- The games get what is left between the buttons and the small print
  home.listPanel = createListPanel(home)
  home.listPanel:SetPoint("TOP", home.actions, "BOTTOM", 0, -24)
  home.listPanel:SetPoint("BOTTOM", line, "TOP", 0, 8)

  -- It comes up out of the dark rather than being there all at once
  local arrive = home:CreateAnimationGroup()
  local fade = arrive:CreateAnimation("Alpha")
  fade:SetFromAlpha(0)
  fade:SetToAlpha(1)
  fade:SetDuration(0.45)
  fade:SetSmoothing("OUT")
  home:SetScript("OnShow", function()
    arrive:Play()
  end)
  return home
end

--- @param list Match[] The player's games
local function refreshHome(list)
  local home = frame.home
  local width, height = frame:GetWidth() - INSET * 2, frame:GetHeight() - HEADER_TOP - INSET
  local any = #list > 0
  refreshPresence()
  -- The wisp is there, the letters shine and the cloud behind it drifts, unless the player would
  -- rather the logo kept still, see GUI/Options.lua
  home.wisp:SetShown(ForeverGames.db.profile.wisp ~= false)
  home.shimmer:SetShown(ForeverGames.db.profile.wisp ~= false)
  home.nebula:SetShown(ForeverGames.db.profile.wisp ~= false)

  -- With no games the logo is the page, a little above the middle of it. With games it moves up
  -- and makes room for them, the more the less room there is
  local scale = any and math.max(LOGO_SMALLEST, math.min(LOGO_HEIGHT, height * LOGO_SHARE)) / LOGO_HEIGHT or 1
  home.crest:SetScale(scale)
  -- At the top of the page there is less room over the logo than its light reaches, and the
  -- light ends where the page does. The page can't cut it off itself: a list that scrolls draws
  -- nothing inside a frame that cuts its children off
  local over = any and LOGO_HEIGHT / 2 + LOGO_TOP / scale or LOGO_HEIGHT
  home.halo:SetHeight(LOGO_HEIGHT + over)
  home.halo:SetTexCoord(0, 1, (LOGO_HEIGHT - over) / (LOGO_HEIGHT * 2), 1)
  home.crest:ClearAllPoints()
  if any then
    -- Where a frame is put is measured in its own points, which are smaller now
    home.crest:SetPoint("TOP", home, "TOP", 0, -LOGO_TOP / scale)
  else
    home.crest:SetPoint("CENTER", home, "CENTER", 0, 118)
  end

  home.title:SetShown(not any)
  home.blurb:SetShown(not any)
  home.actions:ClearAllPoints()
  if any then
    home.actions:SetPoint("TOP", home.presence, "BOTTOM", 0, -10)
  else
    home.actions:SetPoint("TOP", home.blurb, "BOTTOM", 0, -18)
  end

  local match = gameToContinue(list)
  home.continue:SetShown(match ~= nil)
  home.continuing:SetShown(match ~= nil)
  home.newGame:ClearAllPoints()
  home.newGame:SetPoint(match and "LEFT" or "CENTER")
  if match then
    home.continue.target = match.id
    home.continuing:SetText(nameFor(match))
  end

  -- The two boxes are as wide as each other
  local listWidth = math.min(LIST_WIDTH, width - 40)
  home.presence:SetWidth(listWidth)
  home.listPanel:SetShown(any)
  if any then
    home.listPanel:SetWidth(listWidth)
    refreshList(list, listWidth)
  end
end

-----------------------------
-- Construction
-----------------------------

--- Makes the window as big as the player wants everything in it, and lets it be resized up to
--- the size of the screen, which is fewer of the window's own points the bigger it is drawn
local function applyScale()
  local scale = settings().scale / 100
  frame:SetScale(scale)
  local maxWidth, maxHeight = math.max(MIN_WIDTH, GetScreenWidth() / scale), math.max(MIN_HEIGHT, GetScreenHeight() / scale)
  if frame.SetResizeBounds then
    frame:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT, maxWidth, maxHeight)
  else
    frame:SetMinResize(MIN_WIDTH, MIN_HEIGHT)
    frame:SetMaxResize(maxWidth, maxHeight)
  end
end

--- The corner the window is resized by
local function createResizeGrip()
  frame:SetResizable(true)
  applyScale()

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
  -- The cast bar shares this strata, so the window is lifted over it when opened or clicked
  frame:SetToplevel(true)
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetScript("OnShow", function()
    frame:Raise()
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

  frame.body = CreateFrame("Frame", nil, frame)
  frame.body:SetPoint("TOPLEFT", INSET, -HEADER_TOP)
  frame.body:SetPoint("BOTTOMRIGHT", -INSET, INSET)
  frame.detail = createDetailPanel(frame.body)
  frame.home = createHomePanel(frame.body)
  -- A game that is timed is on the clock for as long as it is looked at, see Session.Spend
  frame.detail:SetScript("OnUpdate", function(_, elapsed)
    if selectedId and not review and not Wizard.IsOpen() then
      private.session:Spend(selectedId, elapsed)
    end
  end)
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
    Wizard.Refresh()
  else
    local selected = selectedId and private.session:Get(selectedId)
    if not selected or selected.hidden then
      -- A game that is gone leaves the player at the front page
      selected, selectedId = nil, nil
    end
    local fresh = selected ~= nil and selected.unread == true
    if selected then
      lastId = selected.id
      -- Looking at a match is what clears its "something new" flag
      private.session:MarkRead(selected.id)
    end

    frame.home:SetShown(not selected)
    if not selected then
      refreshHome(private.session:List())
    end
    refreshDetail(selected, fresh)
  end

  refreshing = false
end

--- Call when the player changed how big the window is drawn
function MainFrame.ApplyScale()
  if frame then
    applyScale()
    MainFrame.Refresh()
  end
end

--- Puts the window back in the middle of the screen at the size it started out with
function MainFrame.ResetWindow()
  local window, usual = settings(), ForeverGames.db.defaults.profile.window
  window.width, window.height = usual.width, usual.height
  if frame then
    frame:ClearAllPoints()
    frame:SetPoint("CENTER")
    frame:SetSize(window.width, window.height)
    MainFrame.Refresh()
  end
end

--- @param id string? The match to show, or none for the front page
function MainFrame.Select(id)
  selectedId = id
  MainFrame.Refresh()
end

--- Back to the front page
function MainFrame.Home()
  MainFrame.Select(nil)
end

--- Whether the player is currently looking at this match
--- @param id string
--- @return boolean
function MainFrame.IsViewing(id)
  return frame ~= nil and frame:IsShown() and not Wizard.IsOpen() and selectedId == id
end

--- @param id string? Match to show. Without one the window is where it was left: on the front page, or on the game that was being looked at
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
