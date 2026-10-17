--------------------------
--  Party pages
--------------------------
-- Where the games for a room are played (Engine/Rooms.lua). They live in the main window like
-- everything else, on two pages of their own.
--
-- The first is where a room is opened or joined, and it is the wizard's second step in all but
-- who is picked: the game and how it is to be played on the right, who the room is for on the
-- left, and under that the rooms that are open already. The second is the room: the game gets
-- the whole page under a header that says how it stands, the way a match does.
--
-- Such a game goes on while the player does something else, so the room can also be made small:
-- a window of its own that shows nothing but the game and can sit in a corner, with the main
-- window out of the way. It goes back to being the page for as long as the game says it needs
-- the player (PartyGame `busy`: it is their turn to draw), and is small again after.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local HowTo = private.HowTo
local Rooms = private.Rooms
local Widgets = private.Widgets

--- @class Party
local Party = {}
private.Party = Party

-- The page is laid out like the wizard: see GUI/Wizard.lua for what these are there
local ABOUT_WIDTH, ABOUT_INSET, PANEL_GAP = 400, 12, 12
local OPTIONS_TOP, OPTION_ROW_HEIGHT, OPTION_NAME_WIDTH = 146, 30, 142
local CHOICE_HEIGHT, CHOICE_PADDING, CHOICE_GAP = 24, 16, 6
-- An option of more choices than this is a dropdown when they don't fit across, as in the wizard
local MOST_BUTTONS = 5
-- Who a room can be for, and how high the button for each is
local AUDIENCES = { "GUILD", "GROUP", "FRIENDS" }
local AUDIENCE_HEIGHT, AUDIENCE_GAP = 50, 6
local ROOM_ROW_HEIGHT = 30
-- The room page keeps this much around the game: its header above, the buttons below
local STAGE_TOP, STAGE_BOTTOM, STAGE_SIDE = 66, 46, 12
local ROSTER_ROW = 20
-- The small window, and the strip along its top
local SMALL_WIDTH, SMALL_HEIGHT, SMALL_HEADER, SMALL_PAD = 300, 326, 24, 8
-- How often the game is shown again without anything having happened, for its clock
local BEAT = 0.2
local COLORS = { gold = Widgets.GOLD, green = Widgets.GREEN }

local page
local small
--- @type table<string, table> What shows each game, by id
local views = {}
--- @type table<table, string> The room each of them was last given
local laid = {}
-- The rules being read (GUI/HowTo.lua), while they are: of which game, and over the lobby or
-- over the room
--- @type { game: PartyGame, room: boolean }?
local reading
-- The game a room is being set up for, who for, and what its options are set to
--- @type PartyGame?
local chosenGame
local chosenAudience
--- @type table<string, any>
local chosenRules = {}
-- Whether the room is shown small. Not kept: a room doesn't outlast the session either
local isSmall = false
-- The room was made big because the game asked, and goes back when it no longer does. If the
-- main window was open on something else before, it is opened again on that
local grown, wasShown = false, false
-- The player made it small while the game asked for it big, and that is respected until the
-- game asks again
local declined = false

--- @param err string?
local function report(err)
  if err then
    ForeverGames:Print(L["err_" .. err])
  end
end

--- @param channel string? "GUILD", "GROUP" or anything else for a room that is by invitation
--- @return string
local function channelName(channel)
  return L[channel == "GUILD" and "party_guild" or (channel == "GROUP" and "party_group" or "party_friends")]
end

--- How the player last set up each game, by game id. Remembered between sessions
--- @return table<string, table<string, any>>
local function remembered()
  local profile = ForeverGames.db.profile
  profile.rules = profile.rules or {}
  return profile.rules
end

--- Shows whether something that can be chosen is
--- @param button Button One with a label
--- @param on boolean
local function paint(button, on)
  button:SetBackdropBorderColor(1, on and 0.82 or 1, on and 0 or 1, on and 0.9 or 0.1)
  button.label:SetTextColor(1, on and 0.82 or 1, on and 0 or 1)
end

--- Something to choose that lights up under the cursor
--- @param parent Frame
--- @return Button
local function createChoice(parent)
  local choice = Widgets.Panel(parent, "Button")
  local hover = choice:CreateTexture(nil, "HIGHLIGHT")
  hover:SetAllPoints()
  hover:SetColorTexture(1, 0.82, 0, 0.12)
  return choice
end

--- @param owner Frame
--- @param title string
--- @param text string
local function tooltip(owner, title, text)
  owner:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(title)
    GameTooltip:AddLine(text, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  owner:SetScript("OnLeave", GameTooltip_Hide)
end

-----------------------------
-- Who is in the room
-----------------------------

--- A box that lists who is in a room and what they have, whoever has the most first. A game's
--- view puts it where it has room for it
--- @param parent Frame
--- @return { frame: Frame, Layout: fun(self: table, width: number, height: number), Update: fun(self: table, room: Room) }
function Party.Roster(parent)
  local roster = { frame = Widgets.Panel(parent) }
  local title = Widgets.Label(roster.frame, "GameFontNormal", L["party_players"])
  title:SetPoint("TOPLEFT", 8, -8)
  local count = Widgets.Label(roster.frame, "GameFontHighlightSmall")
  count:SetPoint("TOPRIGHT", -8, -9)
  count:SetTextColor(unpack(Widgets.GREY))

  local list = Widgets.List(roster.frame, 100, ROSTER_ROW, function(content)
    local row = CreateFrame("Frame", nil, content)
    row.score = Widgets.Label(row, "GameFontHighlightSmall")
    row.score:SetPoint("RIGHT", -6, 0)
    row.score:SetJustifyH("RIGHT")
    row.name = Widgets.Label(row, "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", 6, 0)
    row.name:SetPoint("RIGHT", row.score, "LEFT", -6, 0)
    row.name:SetWordWrap(false)
    return row
  end)
  list.frame:SetPoint("TOPLEFT", 2, -28)
  list.frame:SetPoint("BOTTOMRIGHT", -2, 4)

  function roster:Layout(width, height)
    self.frame:SetSize(width, height)
    list:SetWidth(width - 4)
  end

  function roster:Update(room)
    local game = Rooms.Game(room.game)
    local members = room:Members()
    table.sort(members, function(a, b)
      if a.score ~= b.score then
        return a.score > b.score
      end
      return a.n < b.n
    end)
    count:SetText(#members)
    list:Update(members, function(row, member)
      local color, note = nil, nil
      if game and game.mark then
        color, note = game.mark(room, member)
      end
      row.name:SetText(private.Transport.DisplayName(member.name))
      row.name:SetTextColor(unpack(COLORS[color] or (member.n == room.me and { 1, 1, 1 } or Widgets.GREY)))
      row.score:SetText((note and ("|cff4de64d" .. note .. "|r  ") or "") .. member.score)
    end)
  end

  return roster
end

-----------------------------
-- Setting a room up
-----------------------------

--- @param audience string
--- @return boolean
local function available(audience)
  return audience == "FRIENDS" or private.rooms.env.onChannel(audience)
end

local function openRoom()
  local game = chosenGame
  if not game then
    return
  end
  local _, err = private.rooms:Open(game.id, chosenAudience ~= "FRIENDS" and chosenAudience or nil, chosenRules)
  if err then
    page.error:SetText(L["err_" .. err])
    return
  end
  remembered()[game.id] = chosenRules
end

--- A line of how the game is played: what it is about, and what it can be set to next to that
--- @param parent Frame
--- @return Frame
local function createOptionRow(parent)
  local row = CreateFrame("Frame", nil, parent)
  row:SetHeight(OPTION_ROW_HEIGHT)
  row.name = Widgets.Label(row, "GameFontHighlight")
  row.name:SetPoint("LEFT")
  row.name:SetWidth(OPTION_NAME_WIDTH)
  row.name:SetWordWrap(false)
  row.choices = {}
  return row
end

--- @param row Frame
--- @param option GameOption
local function fillOptionRow(row, option)
  row.name:SetText(option.name)
  local x = OPTION_NAME_WIDTH + 6
  for index = 1, math.max(#row.choices, #option.choices) do
    local choice = row.choices[index]
    local value = option.choices[index]
    if not choice and value ~= nil then
      choice = createChoice(row)
      choice.label = Widgets.Label(choice, "GameFontHighlightSmall")
      choice.label:SetPoint("CENTER")
      row.choices[index] = choice
    end
    if choice then
      choice:SetShown(value ~= nil)
    end
    if value ~= nil then
      choice.label:SetText(option.label and option.label(value) or tostring(value))
      choice:SetSize(choice.label:GetStringWidth() + CHOICE_PADDING, CHOICE_HEIGHT)
      choice:ClearAllPoints()
      choice:SetPoint("LEFT", x, 0)
      x = x + choice:GetWidth() + CHOICE_GAP
      paint(choice, chosenRules[option.id] == value)
      choice:SetScript("OnClick", function()
        chosenRules[option.id] = value
        Party.Refresh()
      end)
    end
  end
  -- Many choices that don't fit across the line are a dropdown instead
  local room = ABOUT_WIDTH - 2 * ABOUT_INSET
  local listed = x - CHOICE_GAP > room and #option.choices > MOST_BUTTONS
  for index, choice in ipairs(row.choices) do
    choice:SetShown(option.choices[index] ~= nil and not listed)
  end
  if listed and not row.dropdown then
    row.dropdown = Widgets.Dropdown(row, CHOICE_HEIGHT)
    row.dropdown:SetPoint("LEFT", OPTION_NAME_WIDTH + 6, 0)
    row.dropdown:SetWidth(room - OPTION_NAME_WIDTH - 6)
  end
  if row.dropdown then
    row.dropdown:SetShown(listed)
  end
  if listed then
    local choices = {}
    for _, value in ipairs(option.choices) do
      choices[#choices + 1] = {
        text = option.label and option.label(value) or tostring(value),
        on = chosenRules[option.id] == value,
        pick = function()
          chosenRules[option.id] = value
        end,
      }
    end
    row.dropdown:SetChoices(choices, Party.Refresh)
  end
end

--- Lays the rules of a game over the lobby or the room
--- @param game PartyGame
--- @param over Frame
--- @param inRoom boolean
--- @param rules table<string, any>? How it is set up, if that is known here
local function readRules(game, over, inRoom, rules)
  reading = { game = game, room = inRoom }
  HowTo.Open(game, rules, nil, over, function()
    reading = nil
    if page then
      page.room.howto:SetText(L["howto"])
    end
  end)
end

--- Puts the rules away once what they were read over is gone: the room left or made small, or
--- another game set up
--- @param room Room?
local function stillReading(room)
  if not reading then
    return
  end
  local onPage = page:IsShown() and not isSmall
  local over = reading.room and (room ~= nil and Rooms.Game(room.game) == reading.game)
    or (not reading.room and room == nil and chosenGame == reading.game)
  if not onPage or not over then
    HowTo.Close()
  end
end

--- @param parent Frame
--- @return Frame
local function createLobby(parent)
  local lobby = CreateFrame("Frame", nil, parent)
  lobby:SetPoint("TOPLEFT", 4, -66)
  lobby:SetPoint("BOTTOMRIGHT", -4, 44)

  -- The game, and how it is to be played
  local about = Widgets.Panel(lobby)
  about:SetPoint("TOPRIGHT")
  about:SetPoint("BOTTOMRIGHT")
  about:SetWidth(ABOUT_WIDTH)
  about.rows = {}
  lobby.about = about

  about.icon = Widgets.Icon(about, private.ICON, 40)
  about.icon:SetPoint("TOPLEFT", ABOUT_INSET, -12)
  about.name = Widgets.Label(about, "GameFontNormalLarge")
  about.name:SetPoint("TOPLEFT", about.icon, "TOPRIGHT", 12, -3)
  about.players = Widgets.Label(about, "GameFontHighlightSmall", L["players_party"])
  about.players:SetPoint("TOPLEFT", about.name, "BOTTOMLEFT", 0, -5)
  about.players:SetTextColor(unpack(Widgets.GREY))
  -- The rules of the game for anyone who doesn't know it, as they are set here
  about.howto = Widgets.Button(about, L["howto"], 110, 20)
  about.howto:SetPoint("TOPRIGHT", -ABOUT_INSET, -14)
  about.howto:SetScript("OnClick", function()
    readRules(chosenGame, lobby, false, chosenRules)
  end)
  about.description = Widgets.Label(about, "GameFontHighlightSmall")
  about.description:SetPoint("TOPLEFT", ABOUT_INSET, -62)
  about.description:SetWidth(ABOUT_WIDTH - ABOUT_INSET * 2)
  about.description:SetHeight(42)
  about.description:SetJustifyV("TOP")
  about.description:SetTextColor(unpack(Widgets.GREY))
  local optionsTitle = Widgets.Label(about, "GameFontNormal", L["wizard_options"])
  optionsTitle:SetPoint("TOPLEFT", ABOUT_INSET, -OPTIONS_TOP + 26)
  about.usual = Widgets.Label(about, "GameFontDisable", L["wizard_no_options"])
  about.usual:SetPoint("TOPLEFT", ABOUT_INSET, -OPTIONS_TOP - 4)

  -- Who the room is for
  local who = Widgets.Panel(lobby)
  who:SetPoint("TOPLEFT")
  who:SetPoint("BOTTOMRIGHT", about, "BOTTOMLEFT", -PANEL_GAP, 0)
  lobby.who = who
  local whoTitle = Widgets.Label(who, "GameFontNormal", L["party_who"])
  whoTitle:SetPoint("TOPLEFT", 10, -10)

  lobby.audiences = {}
  for index, audience in ipairs(AUDIENCES) do
    local button = createChoice(who)
    button:SetHeight(AUDIENCE_HEIGHT)
    button:SetPoint("TOPLEFT", 10, -32 - (index - 1) * (AUDIENCE_HEIGHT + AUDIENCE_GAP))
    button:SetPoint("RIGHT", -10, 0)
    button.label = Widgets.Label(button, "GameFontNormal", L["party_for_" .. audience])
    button.label:SetPoint("TOPLEFT", 12, -9)
    button.detail = Widgets.Label(button, "GameFontHighlightSmall")
    button.detail:SetPoint("TOPLEFT", button.label, "BOTTOMLEFT", 0, -4)
    button.detail:SetPoint("RIGHT", -12, 0)
    button.detail:SetWordWrap(false)
    button:SetScript("OnClick", function()
      if available(audience) then
        chosenAudience = audience
        Party.Refresh()
      end
    end)
    button.audience = audience
    lobby.audiences[index] = button
  end

  -- And the rooms there are already
  local roomsTop = 32 + #AUDIENCES * (AUDIENCE_HEIGHT + AUDIENCE_GAP) + 14
  local roomsTitle = Widgets.Label(who, "GameFontNormal", L["party_rooms"])
  roomsTitle:SetPoint("TOPLEFT", 10, -roomsTop)
  lobby.look = Widgets.Button(who, L["party_look"], 90, 20)
  lobby.look:SetPoint("TOPRIGHT", -10, -roomsTop + 4)
  lobby.look:SetScript("OnClick", function()
    private.rooms:Look()
    Party.Refresh()
  end)
  lobby.none = Widgets.Label(who, "GameFontDisable", L["party_no_rooms"])
  lobby.none:SetPoint("TOPLEFT", 12, -roomsTop - 28)
  lobby.none:SetPoint("RIGHT", -12, 0)
  lobby.none:SetJustifyH("LEFT")

  lobby.rooms = Widgets.List(who, 100, ROOM_ROW_HEIGHT, function(content)
    local row = CreateFrame("Frame", nil, content)
    row.join = Widgets.Button(row, L["party_join"], 84, 22)
    row.join:SetPoint("RIGHT", -6, 0)
    row.join:SetScript("OnClick", function()
      local _, err = private.rooms:Join(row.id)
      report(err)
      Party.Refresh()
    end)
    row.text = Widgets.Label(row, "GameFontHighlight")
    row.text:SetPoint("LEFT", 6, 0)
    row.text:SetPoint("RIGHT", row.join, "LEFT", -8, 0)
    row.text:SetWordWrap(false)
    return row
  end)
  lobby.rooms.frame:SetPoint("TOPLEFT", 6, -roomsTop - 24)
  lobby.rooms.frame:SetPoint("BOTTOMRIGHT", -6, 8)
  return lobby
end

local function refreshLobby()
  local lobby, rooms, game = page.lobby, private.rooms, chosenGame
  page.title:SetText(game.name)
  page.step:SetText(L["party_step"])

  local about = lobby.about
  about.icon:SetTexture(game.icon or private.ICON)
  about.name:SetText(game.name)
  about.description:SetText(game.description or "")
  about.howto:SetShown(HowTo.Has(game))
  local options = game.options or {}
  about.usual:SetShown(#options == 0)
  for index = 1, math.max(#about.rows, #options) do
    local row = about.rows[index]
    if not row and options[index] then
      row = createOptionRow(about)
      row:SetPoint("TOPLEFT", ABOUT_INSET, -OPTIONS_TOP - (index - 1) * OPTION_ROW_HEIGHT)
      row:SetPoint("RIGHT", -ABOUT_INSET, 0)
      about.rows[index] = row
    end
    if row then
      row:SetShown(options[index] ~= nil)
    end
    if options[index] then
      fillOptionRow(row, options[index])
    end
  end

  -- A room can't be for a guild or a group the player isn't in
  if not available(chosenAudience) then
    chosenAudience = nil
  end
  for _, audience in ipairs(AUDIENCES) do
    chosenAudience = chosenAudience or (available(audience) and audience) or nil
  end
  for _, button in ipairs(lobby.audiences) do
    local can = available(button.audience)
    paint(button, chosenAudience == button.audience)
    button.detail:SetText(can and L["party_for_" .. button.audience .. "_tip"] or L["party_not_" .. button.audience])
    button.detail:SetTextColor(unpack(Widgets.GREY))
    button:SetAlpha(can and 1 or 0.45)
  end

  local known = rooms:Known()
  lobby.none:SetShown(#known == 0)
  lobby.look:SetEnabled(not rooms.looked or rooms.env.now() - rooms.looked >= 10)
  -- Worked out rather than asked: the panel may not have been laid out yet
  lobby.rooms:SetWidth(page:GetWidth() - 8 - ABOUT_WIDTH - PANEL_GAP - 12)
  lobby.rooms:Update(known, function(row, info)
    local theirs = Rooms.Game(info.game)
    local host, name = private.Transport.DisplayName(info.host), theirs and theirs.name or info.game
    row.id = info.id
    row.text:SetText(L[info.invited and "party_room_invited" or "party_room"]:format(host, name, channelName(info.channel)))
    local asked = rooms.joining ~= nil and rooms.joining.id == info.id
    row.join:SetText(asked and L["party_joining"] or L["party_join"])
    row.join:SetEnabled(not asked and theirs ~= nil and theirs.version == info.version)
  end)

  page.summary:SetText(L["party_summary_" .. chosenAudience]:format(game.name))
end

-----------------------------
-- In a room
-----------------------------

local function invite()
  local box = page.room.name
  local name = private.Transport.Normalize(box:GetText() or "")
  if not name and UnitIsPlayer("target") and not UnitIsUnit("target", "player") then
    name = private.Transport.UnitPlayer("target")
  end
  local ok, err = private.rooms:Invite(name)
  if ok then
    box:SetText("")
    box:ClearFocus()
    ForeverGames:Print(L["party_invited"]:format(private.Transport.DisplayName(name)))
  else
    report(err)
  end
end

--- @param parent Frame
--- @return Frame
local function createRoom(parent)
  local room = Widgets.Panel(parent)
  room:SetAllPoints()

  room.icon = Widgets.Icon(room, private.ICON, 40)
  room.icon:SetPoint("TOPLEFT", 14, -12)
  room.header = Widgets.Label(room, "GameFontNormalLarge")
  room.header:SetPoint("TOPLEFT", room.icon, "TOPRIGHT", 12, -2)
  room.status = Widgets.Label(room, "GameFontHighlight")
  room.status:SetPoint("TOPLEFT", room.header, "BOTTOMLEFT", 0, -5)
  room.statusPulse = Widgets.Pulse(room.status)

  -- Back to the front page. The room goes on, and the front page has the way back to it
  room.home = Widgets.Button(room, L["home"], 96, 22)
  room.home:SetPoint("TOPRIGHT", -STAGE_SIDE, -12)
  room.home:SetScript("OnClick", function()
    Party.Hide()
  end)
  room.shrink = Widgets.Button(room, L["party_small"], 110, 22)
  room.shrink:SetPoint("RIGHT", room.home, "LEFT", -6, 0)
  room.shrink:SetScript("OnClick", function()
    GameTooltip_Hide()
    Party.MakeSmall(true)
  end)
  tooltip(room.shrink, L["party_small"], L["party_shrink_tip"])
  -- The rules, over the game, which goes on underneath: it is everybody's, not the player's to stop
  room.howto = Widgets.Button(room, L["howto"], 120, 22)
  room.howto:SetPoint("RIGHT", room.shrink, "LEFT", -6, 0)
  room.howto:SetScript("OnClick", function(self)
    local game = private.rooms.room and Rooms.Game(private.rooms.room.game)
    if reading then
      HowTo.Close()
    elseif game then
      -- Only whoever opened the room was told how it is set up
      readRules(game, room.reading, true, nil)
      self:SetText(L["howto_back"])
    end
  end)
  room.where = Widgets.Label(room, "GameFontDisableSmall")
  room.where:SetPoint("TOPRIGHT", room.home, "BOTTOMRIGHT", -2, -6)

  -- The room the game's view gets. Sized explicitly, never from its anchors: views lay
  -- themselves out from the numbers before the frame has been drawn
  room.stage = CreateFrame("Frame", nil, room)
  room.stage:SetPoint("TOPLEFT", STAGE_SIDE, -STAGE_TOP)
  room.reading = CreateFrame("Frame", nil, room)
  room.reading:SetPoint("TOPLEFT", STAGE_SIDE, -STAGE_TOP)
  room.reading:SetPoint("BOTTOMRIGHT", -STAGE_SIDE, STAGE_BOTTOM)

  room.leave = Widgets.Button(room, L["party_leave"], 130, 24)
  room.leave:SetPoint("BOTTOMRIGHT", -STAGE_SIDE, 12)
  room.leave:SetScript("OnClick", function()
    private.rooms:Leave()
  end)

  -- Only the host asks people in
  room.asking = Widgets.Label(room, "GameFontHighlightSmall", L["party_invite_label"])
  room.asking:SetPoint("BOTTOMLEFT", STAGE_SIDE + 2, 18)
  room.asking:SetTextColor(unpack(Widgets.GREY))
  room.name = CreateFrame("EditBox", nil, room, "InputBoxTemplate")
  room.name:SetSize(170, 22)
  room.name:SetPoint("LEFT", room.asking, "RIGHT", 12, 0)
  room.name:SetAutoFocus(false)
  room.name:SetMaxLetters(48)
  room.name:SetScript("OnEnterPressed", invite)
  room.name:SetScript("OnEscapePressed", room.name.ClearFocus)
  room.invite = Widgets.Button(room, L["party_invite"], 80, 22)
  room.invite:SetPoint("LEFT", room.name, "RIGHT", 6, 0)
  room.invite:SetScript("OnClick", invite)
  tooltip(room.invite, L["party_invite"], L["party_invite_tip"])
  -- Or anyone at all, whoever clicks a link to it in chat
  room.link = Widgets.Button(room, L["party_link"], 110, 22)
  room.link:SetPoint("LEFT", room.invite, "RIGHT", 6, 0)
  room.link:SetScript("OnClick", function()
    local game = private.rooms:Link()
    if game then
      private.Links.Insert(game)
      ForeverGames:Print(L["party_link_ready"]:format(game.name))
    end
  end)
  tooltip(room.link, L["party_link"], L["party_link_tip"])
  -- What everyone else is told there instead
  room.note = Widgets.Label(room, "GameFontDisableSmall")
  room.note:SetPoint("BOTTOMLEFT", STAGE_SIDE + 2, 18)
  return room
end

--- @param room Room
--- @param parent Frame
--- @return table
local function viewFor(room, parent)
  local view = views[room.game]
  if not view then
    view = Rooms.Game(room.game).view(parent)
    views[room.game] = view
  end
  -- What showed the game of a room the player was in before is put away, not drawn under this
  for _, other in pairs(views) do
    if other ~= view then
      other.frame:Hide()
    end
  end
  if view.frame:GetParent() ~= parent then
    view.frame:SetParent(parent)
    laid[view] = nil
  end
  view.frame:ClearAllPoints()
  view.frame:SetPoint("TOPLEFT")
  view.frame:Show()
  return view
end

--- @param view table
--- @param room Room
--- @param width number
--- @param height number
--- @param compact boolean
local function show(view, room, width, height, compact)
  local size = width .. "x" .. height .. (compact and " small" or "")
  if laid[view] ~= size then
    laid[view] = size
    view:Layout(width, height, compact)
  end
  view:Update(room)
end

--- @param room Room
--- @param game PartyGame
--- @return string text, boolean urgent
local function statusOf(room, game)
  if game.status then
    local text, urgent = game.status(room)
    return text or "", urgent == true
  end
  return "", false
end

--- @param room Room
local function refreshRoom(room)
  local panel, game = page.room, Rooms.Game(room.game)
  local host = room:IsHost()
  panel.icon:SetTexture(game.icon or private.ICON)
  panel.header:SetText(game.name)
  local status, urgent = statusOf(room, game)
  panel.status:SetText(status)
  panel.status:SetTextColor(unpack(urgent and Widgets.GREEN or { 1, 1, 1 }))
  if urgent ~= panel.statusPulse:IsPlaying() then
    if urgent then
      panel.statusPulse:Play()
    else
      panel.statusPulse:Stop()
    end
  end
  local owner = private.Transport.DisplayName(room.host)
  panel.where:SetText(L["party_where"]:format(L["party_room_of"]:format(owner), channelName(room.channel)))
  panel.leave:SetText(host and L["party_close"] or L["party_leave"])
  panel.asking:SetShown(host)
  panel.name:SetShown(host)
  panel.invite:SetShown(host)
  panel.link:SetShown(host)
  panel.note:SetShown(not host)
  panel.note:SetText(L["party_guest_note"]:format(owner))
  panel.howto:SetShown(HowTo.Has(game))

  local width, height = page:GetWidth() - STAGE_SIDE * 2, page:GetHeight() - STAGE_TOP - STAGE_BOTTOM
  panel.stage:SetSize(width, height)
  show(viewFor(room, panel.stage), room, width, height, false)
end

-----------------------------
-- The small window
-----------------------------

local function createSmall()
  small = Widgets.Panel(UIParent)
  small:SetBackdropColor(0.04, 0.04, 0.06, 0.94)
  small:SetBackdropBorderColor(1, 0.82, 0, 0.35)
  small:SetSize(SMALL_WIDTH, SMALL_HEIGHT)
  small:SetFrameStrata("MEDIUM")
  small:SetMovable(true)
  small:SetClampedToScreen(true)
  small:EnableMouse(true)
  small:RegisterForDrag("LeftButton")
  small:SetScript("OnDragStart", small.StartMoving)
  small:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relative, x, y = self:GetPoint(1)
    ForeverGames.db.profile.party = { point, relative, x, y }
  end)
  local saved = ForeverGames.db.profile.party
  if saved and saved[1] then
    small:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])
  else
    small:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -260, 180)
  end
  small:Hide()

  small.title = Widgets.Label(small, "GameFontNormalSmall")
  small.title:SetPoint("TOPLEFT", SMALL_PAD, -7)
  small.close = CreateFrame("Button", nil, small, "UIPanelCloseButton")
  small.close:SetSize(22, 22)
  small.close:SetPoint("TOPRIGHT", 0, 0)
  small.grow = Widgets.Button(small, L["party_grow"], 54, 18)
  small.grow:SetPoint("RIGHT", small.close, "LEFT", 0, 0)
  small.grow:SetScript("OnClick", function()
    GameTooltip_Hide()
    Party.MakeSmall(false)
  end)
  tooltip(small.grow, L["party_grow"], L["party_grow_tip"])

  small.stage = CreateFrame("Frame", nil, small)
  small.stage:SetPoint("TOPLEFT", SMALL_PAD, -SMALL_HEADER)
  small.stage:SetSize(SMALL_WIDTH - SMALL_PAD * 2, SMALL_HEIGHT - SMALL_HEADER - SMALL_PAD)

  local since = 0
  small:SetScript("OnUpdate", function(_, elapsed)
    since = since + elapsed
    if since >= BEAT then
      since = 0
      Party.Refresh()
    end
  end)
end

--- @param room Room
local function refreshSmall(room)
  local game = Rooms.Game(room.game)
  small.title:SetText(game.name)
  show(viewFor(room, small.stage), room, SMALL_WIDTH - SMALL_PAD * 2, SMALL_HEIGHT - SMALL_HEADER - SMALL_PAD, true)
end

-----------------------------
-- Public
-----------------------------

--- Builds the pages into the main window
--- @param parent Frame
function Party.Init(parent)
  page = CreateFrame("Frame", nil, parent)
  page:SetPoint("TOPLEFT", 14, -32)
  page:SetPoint("BOTTOMRIGHT", -14, 14)
  page:Hide()

  page.title = Widgets.Label(page, "GameFontNormalHuge")
  page.title:SetPoint("TOPLEFT", 4, -6)
  page.step = Widgets.Label(page, "GameFontHighlight")
  page.step:SetPoint("TOPLEFT", page.title, "BOTTOMLEFT", 0, -6)
  page.lobby = createLobby(page)

  page.open = Widgets.Button(page, L["party_open_room"], 150, 28)
  page.open:SetPoint("BOTTOMRIGHT", -4, 4)
  page.open:SetScript("OnClick", openRoom)
  page.cancel = Widgets.Button(page, CANCEL, 90, 28)
  page.cancel:SetPoint("BOTTOMLEFT", 4, 4)
  page.cancel:SetScript("OnClick", function()
    Party.Hide()
  end)
  page.summary = Widgets.Label(page, "GameFontHighlight")
  page.summary:SetPoint("RIGHT", page.open, "LEFT", -12, 0)
  page.summary:SetJustifyH("RIGHT")
  page.error = Widgets.Label(page, "GameFontRedSmall")
  page.error:SetPoint("BOTTOMRIGHT", page.open, "TOPRIGHT", 0, 6)
  page.error:SetJustifyH("RIGHT")

  page.room = createRoom(page)

  local since = 0
  page:SetScript("OnUpdate", function(_, elapsed)
    since = since + elapsed
    if since >= BEAT then
      since = 0
      Party.Refresh()
    end
  end)
end

--- Whether the main window is on one of the party pages
--- @return boolean
function Party.OnPage()
  return page ~= nil and page:IsShown()
end

--- Whether the player is looking at a room or setting one up, whole or small
--- @return boolean
function Party.IsOpen()
  return (Party.OnPage() and page:IsVisible()) or (small ~= nil and small:IsShown())
end

--- Shows the room, or where one is set up, as things are now
function Party.Refresh()
  local room = private.rooms.room
  local game = room and Rooms.Game(room.game)
  if not room then
    isSmall, grown, declined = false, false, false
  end
  if page then
    stillReading(room)
  end

  -- A game that needs the player gets the whole page, for as long as it does
  local busy = game ~= nil and game.busy ~= nil and game.busy(room)
  declined = declined and busy
  if busy and isSmall and not declined then
    grown, wasShown = true, private.MainFrame.IsShown()
    return Party.MakeSmall(false, true)
  elseif grown and not busy then
    grown = false
    Party.MakeSmall(true, true)
    if wasShown then
      private.MainFrame.Open()
    end
    return
  end

  if small then
    -- A game that keeps out of the way of a fight is back once it is over (Core.lua says when)
    local hidden = game ~= nil and game.calm == true and InCombatLockdown()
    small:SetShown(isSmall and room ~= nil and not hidden)
    if small:IsShown() then
      refreshSmall(room)
    end
  end
  if not Party.OnPage() or not page:IsVisible() then
    return
  end
  local lobby = room == nil
  page.title:SetShown(lobby)
  page.step:SetShown(lobby)
  page.lobby:SetShown(lobby)
  page.open:SetShown(lobby)
  page.cancel:SetShown(lobby)
  page.summary:SetShown(lobby)
  page.error:SetShown(lobby)
  page.room:SetShown(not lobby)
  if lobby then
    refreshLobby()
  elseif not isSmall then
    refreshRoom(room)
  end
end

--- Shows the room small in a window of its own, or whole in the main window again
--- @param on boolean
--- @param byGame boolean? The game asked for it, not the player
function Party.MakeSmall(on, byGame)
  local room = private.rooms.room
  if not room then
    return
  end
  if not byGame then
    local game = Rooms.Game(room.game)
    grown, declined = false, on and game.busy ~= nil and game.busy(room)
  end
  if on then
    isSmall = true
    if not small then
      createSmall()
    end
    -- The point of it is to have the big window out of the way
    page:Hide()
    stillReading(room)
    private.MainFrame.Hide()
    Party.Refresh()
  else
    Party.Open()
  end
end

--- Opens the main window on the room the player is in, or on where one is set up
--- @param gameId string? The game to set a room up for, the first there is if left out
function Party.Open(gameId)
  if private.Wizard and private.Wizard.IsOpen() then
    private.Wizard.Reset()
  end
  -- Asked for, the room is shown whole even if it was small
  isSmall = false
  private.MainFrame.Open()
  local room = private.rooms.room
  if not room then
    local game = Rooms.Game(gameId) or chosenGame or Rooms.Games()[1]
    if game ~= chosenGame or not page:IsShown() then
      chosenGame = game
      chosenRules = private.Games.Rules(game.options, remembered()[game.id])
      page.error:SetText("")
      private.rooms:Look()
    end
  end
  page:Show()
  private.MainFrame.Refresh()
end

--- Leaves the pages for the front page. A room the player is in goes on
function Party.Hide()
  if page and page:IsShown() then
    page:Hide()
    stillReading(private.rooms.room)
    private.MainFrame.Refresh()
  end
end

--- For /fg party: to the room or to setting one up, and away again
function Party.Toggle()
  if Party.IsOpen() and not isSmall then
    Party.Hide()
  else
    Party.Open()
  end
end
