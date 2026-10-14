--------------------------
--  Party window
--------------------------
-- Where the games for a room are played (Engine/Rooms.lua). A window of its own, since such a
-- game goes on while the player does something else: it can be made small enough to sit in a
-- corner, where it shows only the game, and it makes itself big again for as long as the game
-- says it needs the player (GameDefinition `busy`: it is their turn to draw).
--
-- Outside a room the window lists the games there are to open one for, and the rooms that were
-- heard of. Inside one it is the game on the left and who is there on the right.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Rooms = private.Rooms
local Widgets = private.Widgets

--- @class Party
local Party = {}
private.Party = Party

local FULL_WIDTH, FULL_HEIGHT = 860, 560
local MINI_WIDTH, MINI_HEIGHT = 300, 318
local HEADER, PAD, SIDE = 26, 8, 190
local ROW = 18
-- How often the game is shown again without anything having happened, for its clock
local BEAT = 0.2
local COLORS = { gold = Widgets.GOLD, green = Widgets.GREEN }

local frame
--- @type table<string, table> What shows each game, by id
local views = {}
--- @type table<table, string> The room each of them was last given
local laid = {}
-- The window was made big because the game asked, and goes back when it no longer does
local grown = false
-- The player made it small while the game asked for it big, and that is respected until the
-- game asks again
local declined = false

--- @return { mini: boolean, full: table?, small: table? }
local function settings()
  local profile = ForeverGames.db.profile
  profile.party = profile.party or { mini = false }
  return profile.party
end

--- @param err string?
local function report(err)
  if err then
    ForeverGames:Print(L["err_" .. err])
  end
end

--- @param channel RoomChannel?
--- @return string
local function channelName(channel)
  return L[channel == "GUILD" and "party_guild" or (channel == "GROUP" and "party_group" or "party_friends")]
end

-----------------------------
-- Outside a room
-----------------------------

local function createLobby(parent)
  local lobby = CreateFrame("Frame", nil, parent)
  lobby:SetAllPoints()

  local intro = Widgets.Label(lobby, "GameFontHighlight", L["party_intro"])
  intro:SetPoint("TOPLEFT", 6, -4)
  intro:SetPoint("TOPRIGHT", -6, -4)
  intro:SetTextColor(unpack(Widgets.GREY))
  intro:SetSpacing(2)

  -- A game, and who to open a room of it for
  lobby.games = {}
  for index, game in ipairs(Rooms.Games()) do
    local row = Widgets.Panel(lobby)
    row:SetHeight(64)
    row:SetPoint("TOPLEFT", 0, -44 - (index - 1) * 70)
    row:SetPoint("TOPRIGHT", 0, -44 - (index - 1) * 70)
    local icon = Widgets.Icon(row, game.icon or private.ICON, 44)
    icon:SetPoint("LEFT", 10, 0)
    local name = Widgets.Label(row, "GameFontNormalLarge", game.name)
    name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 12, -2)
    local description = Widgets.Label(row, "GameFontHighlightSmall", game.description)
    description:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -4)
    description:SetPoint("RIGHT", -330, 0)
    description:SetTextColor(unpack(Widgets.GREY))
    local previous
    for _, channel in ipairs({ "FRIENDS", "GROUP", "GUILD" }) do
      local open = Widgets.Button(row, channelName(channel), 100, 26)
      if previous then
        open:SetPoint("RIGHT", previous, "LEFT", -4, 0)
      else
        open:SetPoint("RIGHT", -10, 0)
      end
      open:SetScript("OnClick", function()
        local _, err = private.rooms:Open(game.id, channel ~= "FRIENDS" and channel or nil)
        report(err)
      end)
      previous = open
    end
    lobby.games[index] = row
  end

  local title = Widgets.Label(lobby, "GameFontNormal", L["party_rooms"])
  title:SetPoint("TOPLEFT", 6, -56 - #lobby.games * 70)
  lobby.refresh = Widgets.Button(lobby, L["party_look"], 90, 20)
  lobby.refresh:SetPoint("TOPRIGHT", 0, -52 - #lobby.games * 70)
  lobby.refresh:SetScript("OnClick", function()
    private.rooms:Look()
    Party.Refresh()
  end)

  lobby.none = Widgets.Label(lobby, "GameFontDisable", L["party_no_rooms"])
  lobby.none:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)

  lobby.list = Widgets.List(lobby, FULL_WIDTH - PAD * 2, 30, function(content)
    local row = Widgets.Panel(content)
    row.text = Widgets.Label(row, "GameFontHighlight")
    row.text:SetPoint("LEFT", 10, 0)
    row.join = Widgets.Button(row, L["party_join"], 90, 22)
    row.join:SetPoint("RIGHT", -6, 0)
    row.join:SetScript("OnClick", function()
      local _, err = private.rooms:Join(row.id)
      report(err)
      Party.Refresh()
    end)
    return row
  end)
  lobby.list.frame:SetPoint("TOPLEFT", title, "BOTTOMLEFT", -6, -8)
  lobby.list.frame:SetPoint("BOTTOMRIGHT")
  return lobby
end

local function refreshLobby()
  local lobby, rooms = frame.lobby, private.rooms
  local known = rooms:Known()
  lobby.none:SetShown(#known == 0)
  lobby.list:Update(known, function(row, info)
    local game = Rooms.Game(info.game)
    row.id = info.id
    local host, name = private.Transport.DisplayName(info.host), game and game.name or info.game
    row.text:SetText(L[info.invited and "party_room_invited" or "party_room"]:format(host, name, channelName(info.channel)))
    local asked = rooms.joining ~= nil and rooms.joining.id == info.id
    row.join:SetText(asked and L["party_joining"] or L["party_join"])
    row.join:SetEnabled(not asked and game ~= nil and game.version == info.version)
  end)
end

-----------------------------
-- In a room
-----------------------------

local function invite()
  local box = frame.side.name
  local typed = box:GetText() or ""
  local name = private.Transport.Normalize(typed)
  if not name and UnitIsPlayer("target") then
    name = private.Transport.Normalize(GetUnitName("target", true))
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

local function createSide(parent)
  local side = Widgets.Panel(parent)
  side:SetWidth(SIDE)
  side:SetPoint("TOPRIGHT")
  side:SetPoint("BOTTOMRIGHT")

  side.title = Widgets.Label(side, "GameFontNormal")
  side.title:SetPoint("TOPLEFT", 8, -8)
  side.title:SetPoint("RIGHT", -8, 0)
  side.title:SetWordWrap(false)
  side.where = Widgets.Label(side, "GameFontDisableSmall")
  side.where:SetPoint("TOPLEFT", side.title, "BOTTOMLEFT", 0, -3)

  side.leave = Widgets.Button(side, L["party_leave"], SIDE - 16, 22)
  side.leave:SetPoint("BOTTOM", 0, 8)
  side.leave:SetScript("OnClick", function()
    private.rooms:Leave()
  end)

  -- Only the host asks people in
  side.invite = Widgets.Button(side, L["party_invite"], 62, 22)
  side.invite:SetPoint("BOTTOMRIGHT", side.leave, "TOPRIGHT", 0, 6)
  side.invite:SetScript("OnClick", invite)
  side.name = CreateFrame("EditBox", nil, side, "InputBoxTemplate")
  side.name:SetSize(SIDE - 16 - 62 - 10, 20)
  side.name:SetPoint("BOTTOMLEFT", side.leave, "TOPLEFT", 6, 7)
  side.name:SetAutoFocus(false)
  side.name:SetScript("OnEnterPressed", invite)
  side.name:SetScript("OnEscapePressed", side.name.ClearFocus)
  side.name:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(L["party_invite_tip"], 1, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  side.name:SetScript("OnLeave", GameTooltip_Hide)

  side.list = Widgets.List(side, SIDE - 12, ROW, function(content)
    local row = CreateFrame("Frame", nil, content)
    row.name = Widgets.Label(row, "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", 4, 0)
    row.name:SetPoint("RIGHT", -52, 0)
    row.name:SetWordWrap(false)
    row.score = Widgets.Label(row, "GameFontHighlightSmall")
    row.score:SetPoint("RIGHT", -4, 0)
    row.score:SetJustifyH("RIGHT")
    return row
  end)
  side.list.frame:SetPoint("TOPLEFT", 6, -42)
  side.list.frame:SetPoint("BOTTOMRIGHT", -6, 66)
  return side
end

--- @param room Room
local function refreshSide(room)
  local side, game = frame.side, Rooms.Game(room.game)
  local host = room:IsHost()
  side.title:SetText(L["party_room_of"]:format(private.Transport.DisplayName(room.host)))
  side.where:SetText(L["party_where"]:format(channelName(room.channel), room.count))
  side.leave:SetText(host and L["party_close"] or L["party_leave"])
  side.invite:SetShown(host)
  side.name:SetShown(host)

  -- Whoever has the most comes first, then whoever came first
  local members = room:Members()
  table.sort(members, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.n < b.n
  end)
  side.list:Update(members, function(row, member)
    local color, note = nil, nil
    if game.mark then
      color, note = game.mark(room, member)
    end
    row.name:SetText(private.Transport.DisplayName(member.name))
    row.name:SetTextColor(unpack(COLORS[color] or (member.n == room.me and { 1, 1, 1 } or Widgets.GREY)))
    row.score:SetText((note and ("|cff4de64d" .. note .. "|r  ") or "") .. member.score)
  end)
end

--- @param room Room
--- @return table
local function viewFor(room)
  local view = views[room.game]
  if not view then
    view = Rooms.Game(room.game).view(frame.stage)
    view.frame:SetPoint("TOPLEFT")
    views[room.game] = view
  end
  return view
end

-----------------------------
-- The window
-----------------------------

--- Puts the window where the player left it at the size it has now
local function place()
  local saved = settings()
  local mini = frame.mini
  local point = mini and saved.small or saved.full
  frame:SetSize(mini and MINI_WIDTH or FULL_WIDTH, mini and MINI_HEIGHT or FULL_HEIGHT)
  frame:ClearAllPoints()
  if point then
    frame:SetPoint(point[1], UIParent, point[2], point[3], point[4])
  elseif mini then
    frame:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -260, 180)
  else
    frame:SetPoint("CENTER")
  end
end

--- @param mini boolean
local function resize(mini)
  settings().mini = mini
  Party.Refresh()
end

local function create()
  frame = CreateFrame("Frame", "ForeverGamesParty", UIParent, "BackdropTemplate")
  frame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  frame:SetBackdropColor(0.05, 0.05, 0.08, 0.94)
  frame:SetBackdropBorderColor(1, 0.82, 0, 0.9)
  frame:SetFrameStrata("MEDIUM")
  frame:SetToplevel(true)
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relative, x, y = self:GetPoint(1)
    settings()[self.mini and "small" or "full"] = { point, relative, x, y }
  end)
  frame:Hide()

  frame.title = Widgets.Label(frame, "GameFontNormal")
  frame.title:SetPoint("TOPLEFT", PAD + 2, -8)
  frame.close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  frame.close:SetSize(24, 24)
  frame.close:SetPoint("TOPRIGHT", -2, -2)
  frame.size = Widgets.Button(frame, "", 22, 18)
  frame.size:SetPoint("RIGHT", frame.close, "LEFT", 0, 0)
  frame.size:SetScript("OnClick", function()
    grown, declined = false, not settings().mini
    resize(not settings().mini)
  end)
  frame.size:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(L[settings().mini and "party_grow_tip" or "party_shrink_tip"], 1, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame.size:SetScript("OnLeave", GameTooltip_Hide)

  frame.body = CreateFrame("Frame", nil, frame)
  frame.body:SetPoint("TOPLEFT", PAD, -HEADER)
  frame.body:SetPoint("BOTTOMRIGHT", -PAD, PAD)
  frame.lobby = createLobby(frame.body)
  frame.stage = CreateFrame("Frame", nil, frame.body)
  frame.stage:SetAllPoints()
  frame.side = createSide(frame.stage)

  local since = 0
  frame:SetScript("OnUpdate", function(_, elapsed)
    since = since + elapsed
    if since >= BEAT then
      since = 0
      Party.Refresh()
    end
  end)
  frame:SetScript("OnShow", function()
    if not private.rooms.room then
      private.rooms:Look()
    end
    Party.Refresh()
  end)
end

--- Shows the window as things are now, if it is open
function Party.Refresh()
  if not frame or not frame:IsShown() then
    return
  end
  local room = private.rooms.room
  local game = room and Rooms.Game(room.game)
  local saved = settings()

  -- A game that needs the player gets the whole window, for as long as it does
  local busy = game ~= nil and game.busy ~= nil and game.busy(room)
  declined = declined and busy
  if busy and saved.mini and not declined then
    grown = true
    return resize(false)
  elseif grown and not busy then
    grown = false
    return resize(true)
  end
  -- Outside a room there is nothing to show small
  local mini = saved.mini and room ~= nil
  if frame.mini ~= mini then
    frame.mini = mini
    place()
  end

  frame.title:SetText(game and game.name or L["party_title"])
  frame.size:SetText(mini and "+" or "-")
  frame.size:SetShown(room ~= nil)
  frame.lobby:SetShown(not room)
  frame.stage:SetShown(room ~= nil)
  if not room then
    return refreshLobby()
  end

  frame.side:SetShown(not mini)
  for id, view in pairs(views) do
    view.frame:SetShown(id == room.game)
  end
  local view = viewFor(room)
  local width, height = frame:GetWidth() - PAD * 2 - (mini and 0 or SIDE + PAD), frame:GetHeight() - HEADER - PAD
  local size = width .. "x" .. height .. (mini and " small" or "")
  if laid[view] ~= size then
    laid[view] = size
    view:Layout(width, height, mini)
  end
  view:Update(room)
  if not mini then
    refreshSide(room)
  end
end

--- Opens the window, on the room the player is in or on the rooms there are
function Party.Open()
  if not frame then
    create()
  end
  frame:Show()
  frame:Raise()
  Party.Refresh()
end

function Party.Toggle()
  if frame and frame:IsShown() then
    frame:Hide()
  else
    Party.Open()
  end
end

--- @return boolean
function Party.IsOpen()
  return frame ~= nil and frame:IsShown()
end
