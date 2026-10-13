--------------------------
--  New game wizard
--------------------------
-- Two steps: pick a game, then pick who to play and how. Lives inside the main window and takes over its
-- content while open. The games are a list that scrolls, narrowed down by typing, by genre or by
-- how many are playing, with the ones the player starred first and the rest by name. However
-- wide the window is, the cards share its width: as many next to each other as fit.
-- A game for more than two has its players picked one after the other, as many as it can seat.
-- What a game lets be changed about its rules is set on the second step too, and goes out with
-- the challenge. The next game of the same kind starts out set the same way.
-- A game for one has nobody to pick, and begins as soon as it is chosen. One that has rules to
-- set goes on to the second step all the same, with only those on it.
-- A game for two doesn't need anyone picked either: it can be linked in chat instead, and is
-- then played with whoever clicks the link first.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Games = private.Games
local Transport = private.Transport
local Widgets = private.Widgets

--- @class Wizard
local Wizard = {}
private.Wizard = Wizard

-- A card is never narrower than this. The window as it comes has room for three of them
local MIN_CARD_WIDTH, CARD_HEIGHT = 260, 122
local CARD_GAP = 12
local DEFAULT_COLUMNS = 3
-- Kept free down the right of the games for the sliver that says there is more
local SCROLL_ROOM = 8
local FILTER_HEIGHT, FILTER_GAP, FILTER_GROUP_GAP = 24, 6, 32
local PLAYER_ROW_HEIGHT = 26
local COLUMN_WIDTH = 350
-- Where the list of players starts, under the box and the buttons that narrow it down
local PLAYERS_TOP = 96
-- The button that links the game in chat, next to what is said under the players
local LINK_WIDTH = 110
-- How many of the players last played with are offered before anyone asks for them
local RECENT_MOST = 6
-- The panel the game and its rules are in, and the lines of it
local RULES_WIDTH, RULES_INSET = 400, 12
local OPTIONS_TOP, OPTION_ROW_HEIGHT, OPTION_NAME_WIDTH = 146, 30, 142
local CHOICE_PADDING = 16
local SOLO_GENRE = "solo"
local STAR = "Interface\\AddOns\\ForeverGames\\Images\\Board\\favourite"

local SOURCE_LABELS = { guild = "source_guild", friend = "source_friend", other = "source_other" }
local GROUP_LABELS = { all = "wizard_all_games", recent = "wizard_recent", guild = "wizard_guild", friend = "wizard_friends" }

local panel
--- @type fun(matchId: string?)
local onClose
--- @type GameDefinition?
local chosenGame
-- Genre the list of games is narrowed down to
--- @type string?
local chosenGenre
-- How many players the games listed have to be for: one, two, or three for three and more
--- @type number?
local chosenSeats
-- Whether only the starred games are listed
local favouritesOnly = false
-- How the cards are laid out in the room there is, see fitCards
local cardColumns, cardWidth = DEFAULT_COLUMNS, MIN_CARD_WIDTH
-- The players picked so far, full names. Only ever one for a game of two
--- @type string[]
local chosenPlayers = {}
-- What the list of players is narrowed down to: "recent", "guild" or "friend"
--- @type string?
local chosenGroup
-- What every option of the chosen game is set to, by id
--- @type table<string, any>
local chosenRules = {}
-- The seat the player asked for in a game of two, nil to leave it to chance
--- @type number?
local chosenSeat

local refresh
--- @type fun(): string[]
local opponents

--- How the player last set the rules of each game, by game id. Remembered between sessions
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

--- The games the player starred, by id. Remembered between sessions
--- @return table<string, boolean>
local function favourites()
  return ForeverGames.db.profile.favourites
end

--- How wide something is that takes its width from the window
--- @param region Region
--- @param fallback number What to go by before the client has laid it out
--- @return number
local function widthOf(region, fallback)
  local width = region:GetWidth()
  return (width and width > 0) and width or fallback
end

--- How many cards go next to each other in this much room, and how wide that makes them
--- @param width number
--- @return number columns, number cardWidth
function Wizard.FitCards(width)
  local columns = math.max(1, math.floor((width + CARD_GAP) / (MIN_CARD_WIDTH + CARD_GAP)))
  return columns, math.floor((width - (columns - 1) * CARD_GAP) / columns)
end

--- How many others the chosen game can be played with at most
--- @return number
local function mostOpponents()
  local counts = Games.SeatCounts(chosenGame)
  return counts[#counts] - 1
end

--- @param name string?
--- @return number? index Where a player is among the ones picked
local function chosenIndex(name)
  for index, chosen in ipairs(chosenPlayers) do
    if chosen == name then
      return index
    end
  end
  return nil
end

--- Picks a player, or for a game of more than two unpicks one that is picked already
--- @param name string
local function choose(name)
  if mostOpponents() == 1 then
    chosenPlayers = { name }
    return
  end
  local index = chosenIndex(name)
  if index then
    table.remove(chosenPlayers, index)
  elseif #chosenPlayers < mostOpponents() then
    chosenPlayers[#chosenPlayers + 1] = name
  end
end

--- "2 players", or "2, 3, 4 or 6 players" where there is a choice
--- @param game GameDefinition
--- @return string
local function playersText(game)
  local counts = Games.SeatCounts(game)
  if Games.IsSolo(game) then
    return L["players_solo"]
  elseif #counts == 1 then
    return L["players_exactly"]:format(counts[1])
  end
  return L["players_choice"]:format(table.concat(counts, ", ", 1, #counts - 1), counts[#counts])
end

--- @param names string[] Full names
--- @return string
local function listed(names)
  local shown = {}
  for index, name in ipairs(names) do
    shown[index] = Transport.DisplayName(name)
  end
  if #shown < 2 then
    return shown[1] or ""
  end
  return L["names_and"]:format(table.concat(shown, ", ", 1, #shown - 1), shown[#shown])
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
  local others = Games.IsSolo(chosenGame) and {} or opponents()
  local match, err = private.session:Invite(others, chosenGame.id, { options = chosenRules, seat = chosenSeat })
  if not match then
    panel.error:SetText(L["err_" .. err])
    return
  end
  remembered()[chosenGame.id] = Games.Chosen(chosenGame, chosenRules)
  Wizard.Close(match.id)
end

--- Leaves the game open to whoever clicks a link to it, and hands the player the link to send
local function link()
  local game, err = private.session:Offer(chosenGame.id, { options = chosenRules, seat = chosenSeat })
  if not game then
    panel.error:SetText(L["err_" .. err])
    return
  end
  remembered()[game.id] = Games.Chosen(game, chosenRules)
  private.Links.Insert(game)
  ForeverGames:Print(L["link_ready"]:format(game.name))
  Wizard.Close()
end

--- The game was chosen. One that is played alone begins there and then unless it has rules to
--- set, anything else goes on to who it is played with and how
--- @param game GameDefinition
local function pick(game)
  if Games.IsSolo(game) and #(game.options or {}) == 0 then
    local match = private.session:Invite({}, game.id)
    Wizard.Close(match and match.id)
    return
  end
  chosenGame = game
  chosenPlayers, chosenGroup, chosenSeat = {}, nil, nil
  chosenRules = Games.Rules(game.options, remembered()[game.id])
  panel.nameBox:SetText("")
  refresh()
end

-----------------------------
-- Step 1: game
-----------------------------

--- A game to pick. Cards are reused for whatever games the search leaves, see fillGameRow
--- @param parent Frame
--- @return Button
local function createGameCard(parent)
  local card = Widgets.Panel(parent, "Button")
  card:SetHeight(CARD_HEIGHT)

  local hover = card:CreateTexture(nil, "HIGHLIGHT")
  hover:SetAllPoints()
  hover:SetColorTexture(1, 0.82, 0, 0.12)

  card.icon = Widgets.Icon(card, private.ICON, 48)
  card.icon:SetPoint("TOPLEFT", 12, -12)

  -- Keeps the game among the first in the list, or lets it go again
  card.star = CreateFrame("Button", nil, card)
  card.star:SetSize(20, 20)
  card.star:SetPoint("TOPRIGHT", -8, -8)
  card.star.icon = Widgets.Icon(card.star, STAR, 20)
  card.star.icon:SetPoint("CENTER")
  local glow = card.star:CreateTexture(nil, "HIGHLIGHT")
  glow:SetAllPoints()
  glow:SetTexture(STAR)
  glow:SetVertexColor(1, 0.82, 0, 0.6)
  card.star:SetScript("OnClick", function()
    local starred = favourites()
    starred[card.game.id] = not starred[card.game.id] or nil
    GameTooltip_Hide()
    refresh()
  end)
  card.star:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(L[favourites()[card.game.id] and "wizard_favourite_remove" or "wizard_favourite_add"])
    GameTooltip:Show()
  end)
  card.star:SetScript("OnLeave", GameTooltip_Hide)

  card.name = Widgets.Label(card, "GameFontNormalLarge")
  card.name:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 12, -5)
  card.name:SetPoint("TOPRIGHT", -32, -17)
  card.name:SetWordWrap(false)

  -- What kind of game it is and how many play it, side by side
  card.genre = Widgets.Label(card, "GameFontDisableSmall")
  card.genre:SetPoint("TOPLEFT", card.name, "BOTTOMLEFT", 0, -6)

  card.players = Widgets.Label(card, "GameFontHighlightSmall")
  card.players:SetPoint("LEFT", card.genre, "RIGHT", 10, 0)
  card.players:SetTextColor(unpack(Widgets.GREY))

  -- Under the icon and as wide as the card, cut short where it doesn't fit
  card.description = Widgets.Label(card, "GameFontHighlightSmall")
  card.description:SetPoint("TOPLEFT", card.icon, "BOTTOMLEFT", 0, -8)
  card.description:SetPoint("BOTTOMRIGHT", -12, 10)
  card.description:SetJustifyV("TOP")
  card.description:SetTextColor(unpack(Widgets.GREY))

  card:SetScript("OnClick", function(self)
    pick(self.game)
  end)
  return card
end

--- One line of the list of games. Its cards are made as the window comes to have room for them
--- @param content Frame
--- @return Frame
local function createGameRow(content)
  local row = CreateFrame("Frame", nil, content)
  row.cards = {}
  return row
end

--- @param row Frame
--- @param games GameDefinition[] The games on this line, one per column
local function fillGameRow(row, games)
  local starred = favourites()
  for column = 1, math.max(#row.cards, #games) do
    local card = row.cards[column]
    if not card then
      card = createGameCard(row)
      row.cards[column] = card
    end
    local game = games[column]
    card.game = game
    card:SetShown(game ~= nil)
    if game then
      card:SetWidth(cardWidth)
      card:ClearAllPoints()
      card:SetPoint("TOPLEFT", (column - 1) * (cardWidth + CARD_GAP), 0)
      card.icon:SetTexture(game.icon or private.ICON)
      card.name:SetText(game.name)
      card.genre:SetText(game.genre and L["genre_" .. game.genre] or "")
      card.players:SetText(playersText(game))
      card.description:SetText(game.description or "")
      local favourite = starred[game.id] == true
      card.star.icon:SetVertexColor(1, favourite and 0.82 or 1, favourite and 0 or 1, favourite and 1 or 0.25)
    end
  end
end

--- A button that narrows the list of games down, and widens it again when it is clicked once more
--- @param parent Frame
--- @param text string
--- @param group string Buttons that belong together stand together
--- @param isOn fun(): boolean Whether it is what the list is narrowed down to right now
--- @param click fun()
--- @return Button
local function createFilterButton(parent, text, group, isOn, click)
  local button = Widgets.Panel(parent, "Button")
  button.group, button.isOn = group, isOn

  local label = Widgets.Label(button, "GameFontHighlightSmall", text)
  label:SetPoint("CENTER")
  button.label = label
  button:SetSize(label:GetStringWidth() + 24, FILTER_HEIGHT)

  local hover = button:CreateTexture(nil, "HIGHLIGHT")
  hover:SetAllPoints()
  hover:SetColorTexture(1, 0.82, 0, 0.12)

  button:SetScript("OnClick", function()
    click()
    refresh()
  end)
  return button
end

--- Everything the list can be narrowed down by, apart from what is typed
--- @param parent Frame
--- @return Button[]
local function createFilterButtons(parent)
  local buttons = {}
  local function add(...)
    buttons[#buttons + 1] = createFilterButton(parent, ...)
  end

  add(L["wizard_all_games"], "all", function()
    return not chosenGenre and not chosenSeats and not favouritesOnly
  end, function()
    chosenGenre, chosenSeats, favouritesOnly = nil, nil, false
  end)
  add(L["wizard_favourites"], "all", function()
    return favouritesOnly
  end, function()
    favouritesOnly = not favouritesOnly
  end)
  for _, genre in ipairs(Games.Genres()) do
    -- Playing alone is a number of players here, it goes with the others below
    if genre ~= SOLO_GENRE then
      add(L["genre_" .. genre], "genre", function()
        return chosenGenre == genre
      end, function()
        chosenGenre = chosenGenre ~= genre and genre or nil
      end)
    end
  end
  local counts = { { 1, L["genre_" .. SOLO_GENRE] }, { 2, L["wizard_two_players"] }, { 3, L["wizard_more_players"] } }
  for _, players in ipairs(counts) do
    local seats = players[1]
    add(players[2], "players", function()
      return chosenSeats == seats
    end, function()
      chosenSeats = chosenSeats ~= seats and seats or nil
    end)
  end
  return buttons
end

--- Puts the buttons next to each other, on as many lines as it takes
--- @param width number The room there is across
--- @return number height What they take up
local function placeFilterButtons(width)
  local x, y = 0, 0
  for index, button in ipairs(panel.filterButtons) do
    local before = panel.filterButtons[index - 1]
    local gap = before and (before.group == button.group and FILTER_GAP or FILTER_GROUP_GAP) or 0
    if x > 0 and x + gap + button:GetWidth() > width then
      x, y, gap = 0, y + FILTER_HEIGHT + FILTER_GAP, 0
    end
    button:ClearAllPoints()
    button:SetPoint("TOPLEFT", x + gap, -y)
    x = x + gap + button:GetWidth()
  end
  return y + FILTER_HEIGHT
end

--- The games the search box and the buttons leave: the starred ones first, and by name from there
--- @return GameDefinition[]
local function matchingGames()
  local starred = favourites()
  local games = {}
  for _, game in ipairs(Games.Search(panel.searchBox:GetText(), chosenGenre, chosenSeats)) do
    if starred[game.id] or not favouritesOnly then
      games[#games + 1] = game
    end
  end
  table.sort(games, function(one, other)
    local first, second = starred[one.id] == true, starred[other.id] == true
    if first ~= second then
      return first
    end
    return one.name < other.name
  end)
  return games
end

--- @param parent Frame
--- @return Frame
local function createGameStep(parent)
  local step = CreateFrame("Frame", nil, parent)

  -- Up beside the title, where there is room for it at any width
  panel.searchBox = CreateFrame("EditBox", nil, step, "InputBoxTemplate")
  panel.searchBox:SetSize(220, 24)
  panel.searchBox:SetPoint("BOTTOMRIGHT", step, "TOPRIGHT", -2, 12)
  panel.searchBox:SetAutoFocus(false)
  panel.searchBox:SetMaxLetters(40)
  panel.searchBox:SetTextInsets(0, 18, 0, 0)
  panel.searchBox:SetScript("OnEscapePressed", panel.searchBox.ClearFocus)
  panel.searchBox:SetScript("OnTextChanged", function()
    refresh()
  end)
  -- With the list down to one game there is nothing left to choose
  panel.searchBox:SetScript("OnEnterPressed", function()
    local games = matchingGames()
    if #games == 1 then
      pick(games[1])
    end
  end)

  -- Says what the box is for until something is typed into it
  panel.searchHint = Widgets.Label(panel.searchBox, "GameFontDisable", L["wizard_search"])
  panel.searchHint:SetPoint("LEFT", 2, 0)

  -- And takes it out again once something is
  panel.searchClear = CreateFrame("Button", nil, panel.searchBox)
  panel.searchClear:SetSize(18, 18)
  panel.searchClear:SetPoint("RIGHT", -2, 0)
  local cross = Widgets.Label(panel.searchClear, "GameFontDisable", "x")
  cross:SetPoint("CENTER", 0, 1)
  panel.searchClear:SetScript("OnEnter", function()
    cross:SetTextColor(1, 1, 1)
  end)
  panel.searchClear:SetScript("OnLeave", function()
    cross:SetTextColor(0.5, 0.5, 0.5)
  end)
  panel.searchClear:SetScript("OnClick", function()
    panel.searchBox:SetText("")
    panel.searchBox:ClearFocus()
    refresh()
  end)

  panel.filterButtons = createFilterButtons(step)

  panel.games = Widgets.List(step, DEFAULT_COLUMNS * (MIN_CARD_WIDTH + CARD_GAP), CARD_HEIGHT + CARD_GAP, createGameRow)

  panel.noGames = Widgets.Label(step, "GameFontDisable")
  panel.noGames:SetPoint("TOPLEFT", panel.games.frame, "TOPLEFT", 4, -8)
  panel.noGames:SetPoint("TOPRIGHT", panel.games.frame, "TOPRIGHT", -4, -8)
  return step
end

--- Shows the games that match what is being looked for, laid out for the room there is
local function refreshGames()
  local width = widthOf(panel.gameStep, DEFAULT_COLUMNS * (MIN_CARD_WIDTH + CARD_GAP) - CARD_GAP + SCROLL_ROOM)
  cardColumns, cardWidth = Wizard.FitCards(width - SCROLL_ROOM)

  panel.games.frame:ClearAllPoints()
  panel.games.frame:SetPoint("TOPLEFT", 0, -(placeFilterButtons(width) + CARD_GAP))
  panel.games.frame:SetPoint("BOTTOMRIGHT")
  panel.games:SetWidth(width)

  local games = matchingGames()
  local rows = {}
  for index, game in ipairs(games) do
    local row = math.ceil(index / cardColumns)
    rows[row] = rows[row] or {}
    table.insert(rows[row], game)
  end
  panel.games:Update(rows, fillGameRow)
  panel.noGames:SetShown(#games == 0)
  panel.noGames:SetText(L[(favouritesOnly and next(favourites()) == nil) and "wizard_no_favourites" or "wizard_no_games"])
  local typed = panel.searchBox:GetText() ~= ""
  panel.searchHint:SetShown(not typed)
  panel.searchClear:SetShown(typed)

  for _, button in ipairs(panel.filterButtons) do
    paint(button, button.isOn())
  end
end

-----------------------------
-- Step 2: who, and how
-----------------------------
-- Two panels side by side. On the left, who to play: one list of everyone worth offering, with
-- a box over it that narrows the list down and takes any other name as well. Whoever the player
-- had a game with lately comes first, online or not, then the guildies and friends who are
-- online with the addon. On the right, the game and what can be changed about its rules.

--- Someone in the list of players, or a line that says who the ones under it are
--- @class WizardPlayer
--- @field header string? The line it is instead of a player
--- @field name string? Full name
--- @field source PresenceSource? How they are known, if they are online with the addon
--- @field online boolean?
--- @field ago number? Seconds since their last game with the player was touched
--- @field note string? What to say about them instead of how they are known

--- @param text string
--- @return string
local function trimmed(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- @param seconds number
--- @return string "Played 3 days ago"
local function playedText(seconds)
  local days = math.floor(seconds / (24 * 60 * 60))
  if days < 1 then
    return L["wizard_played_today"]
  elseif days < 2 then
    return L["wizard_played_yesterday"]
  end
  return L["wizard_played_days"]:format(days)
end

--- Everyone to offer, under what they are, and who the box over the list stands for
--- @return WizardPlayer[] items
--- @return string? typed Full name of the player what is typed means: the one it leaves in the list if it is down to one or spells them out, anyone else by that name otherwise
local function listing()
  local text = trimmed(panel.nameBox:GetText() or ""):lower()

  --- @type table<string, WizardPlayer>
  local known = {}
  for _, player in ipairs(private.presence:List()) do
    known[player.name] = { name = player.name, source = player.source, online = true }
  end
  for _, opponent in ipairs(private.session:Opponents()) do
    known[opponent.name] = known[opponent.name] or { name = opponent.name }
    known[opponent.name].ago = opponent.ago
  end

  --- @type table<string, WizardPlayer[]>
  local groups = { recent = {}, guild = {}, friend = {}, other = {} }
  local found, exact = {}, nil
  for name, player in pairs(known) do
    local shown = Transport.DisplayName(name):lower()
    local wanted = not chosenGroup or (chosenGroup == "recent" and player.ago ~= nil) or player.source == chosenGroup
    if wanted and (text == "" or shown:find(text, 1, true)) then
      found[#found + 1] = player
      exact = (shown == text or name:lower() == text) and name or exact
      table.insert(groups[player.ago and "recent" or player.source], player)
    end
  end
  table.sort(groups.recent, function(a, b)
    if a.online ~= b.online then
      return a.online == true
    elseif a.ago ~= b.ago then
      return a.ago < b.ago
    end
    return a.name < b.name
  end)
  -- Only the latest of them, unless they are what is being looked for
  if text == "" and chosenGroup ~= "recent" then
    for index = #groups.recent, RECENT_MOST + 1, -1 do
      local player = table.remove(groups.recent, index)
      if player.source then
        table.insert(groups[player.source], player)
      end
    end
  end
  for _, source in ipairs({ "guild", "friend", "other" }) do
    table.sort(groups[source], function(a, b)
      return a.name < b.name
    end)
  end

  local typed = nil
  if text ~= "" then
    typed = exact or (#found == 1 and found[1].name) or Transport.Normalize(panel.nameBox:GetText())
  end

  local items, listed = {}, {}
  --- @param title string
  --- @param players WizardPlayer[]
  local function section(title, players)
    if #players > 0 then
      items[#items + 1] = { header = title }
      for _, player in ipairs(players) do
        items[#items + 1] = player
        listed[player.name] = true
      end
    end
  end

  -- Whoever is picked can always be seen, and unpicked
  local also, inList = {}, {}
  for _, players in pairs(groups) do
    for _, player in ipairs(players) do
      inList[player.name] = true
    end
  end
  if typed and not inList[typed] and not chosenIndex(typed) then
    local online = known[typed] and known[typed].online
    section(L["wizard_by_name"], { { name = typed, online = online, note = L["wizard_by_name_note"] } })
  end
  for _, name in ipairs(chosenPlayers) do
    if not inList[name] then
      local player = known[name] or {}
      also[#also + 1] = { name = name, source = player.source, online = player.online, ago = player.ago }
    end
  end
  section(L["wizard_chosen_also"], also)
  local target = targetName()
  if target and text == "" and not chosenGroup and not inList[target] and not listed[target] then
    section(L["wizard_target"], { { name = target, online = known[target] and known[target].online, note = "" } })
  end
  section(L["wizard_recent"], groups.recent)
  section(L["wizard_guild"], groups.guild)
  section(L["wizard_friends"], groups.friend)
  section(L["wizard_online"], groups.other)
  return items, typed
end

--- Everyone the challenge would go to: the players picked, and whoever the box stands for. For
--- a game of two the box wins over the list selection
--- @return string[]
opponents = function()
  local _, typed = listing()
  if not typed then
    return chosenPlayers
  elseif mostOpponents() == 1 then
    return { typed }
  end
  local everyone = { unpack(chosenPlayers) }
  if not chosenIndex(typed) and #everyone < mostOpponents() then
    everyone[#everyone + 1] = typed
  end
  return everyone
end

--- @param content Frame
--- @return Button
local function createPlayerRow(content)
  local row = CreateFrame("Button", nil, content)

  row.selected = row:CreateTexture(nil, "BACKGROUND")
  row.selected:SetAllPoints()
  row.selected:SetColorTexture(1, 0.82, 0, 0.2)

  row.hover = row:CreateTexture(nil, "HIGHLIGHT")
  row.hover:SetAllPoints()
  row.hover:SetColorTexture(1, 1, 1, 0.08)

  row.dot = row:CreateTexture(nil, "ARTWORK")
  row.dot:SetSize(8, 8)
  row.dot:SetPoint("LEFT", 8, 0)

  row.name = Widgets.Label(row, "GameFontHighlight")
  row.name:SetPoint("LEFT", 24, 0)

  row.source = Widgets.Label(row, "GameFontDisableSmall")
  row.source:SetPoint("RIGHT", -10, 0)

  -- The line over a group of players
  row.header = Widgets.Label(row, "GameFontNormalSmall")
  row.header:SetPoint("BOTTOMLEFT", 6, 5)
  row.rule = row:CreateTexture(nil, "ARTWORK")
  row.rule:SetColorTexture(1, 1, 1, 0.1)
  row.rule:SetHeight(1)
  row.rule:SetPoint("BOTTOMLEFT", 4, 1)
  row.rule:SetPoint("BOTTOMRIGHT", -8, 1)

  row:SetScript("OnClick", function(self)
    if not self.player then
      return
    end
    choose(self.player)
    panel.nameBox:SetText("")
    panel.nameBox:ClearFocus()
    refresh()
  end)
  return row
end

--- @param row Button
--- @param item WizardPlayer
--- @param typed string? Who the box over the list stands for
local function fillPlayerRow(row, item, typed)
  local isPlayer = item.header == nil
  row.player = item.name
  row:EnableMouse(isPlayer)
  row.hover:SetShown(isPlayer)
  row.dot:SetShown(isPlayer)
  row.name:SetShown(isPlayer)
  row.source:SetShown(isPlayer)
  row.header:SetShown(not isPlayer)
  row.rule:SetShown(not isPlayer)
  if not isPlayer then
    row.header:SetText(item.header)
    row.selected:Hide()
    return
  end

  local picked = chosenIndex(item.name) ~= nil or item.name == typed
  row.selected:SetShown(picked)
  -- Green for someone who would get the challenge right now
  if item.online then
    row.dot:SetColorTexture(unpack(Widgets.GREEN))
    row.name:SetTextColor(1, 1, 1)
  else
    row.dot:SetColorTexture(0.4, 0.4, 0.4)
    row.name:SetTextColor(unpack(Widgets.GREY))
  end
  row.name:SetText(Transport.DisplayName(item.name))

  local about = {}
  if item.source and item.source ~= "other" then
    about[#about + 1] = L[SOURCE_LABELS[item.source]]
  end
  if item.ago then
    about[#about + 1] = playedText(item.ago)
  end
  row.source:SetText(item.note or table.concat(about, "  -  "))
end

--- One of the things an option can be set to, or a way of narrowing the players down
--- @param parent Frame
--- @return Button
local function createChoice(parent)
  local choice = Widgets.Panel(parent, "Button")
  choice.label = Widgets.Label(choice, "GameFontHighlightSmall")
  choice.label:SetPoint("CENTER")

  local hover = choice:CreateTexture(nil, "HIGHLIGHT")
  hover:SetAllPoints()
  hover:SetColorTexture(1, 0.82, 0, 0.12)

  choice:SetScript("OnClick", function(self)
    self.pick()
    refresh()
  end)
  return choice
end

--- @param choice Button
--- @param text string
--- @param on boolean Whether it is what is chosen
--- @param pick fun()
local function fillChoice(choice, text, on, pick)
  choice.pick, choice.picked = pick, on
  choice.label:SetText(text)
  choice:SetSize(choice.label:GetStringWidth() + CHOICE_PADDING, FILTER_HEIGHT)
  paint(choice, on)
end

--- A line of the rules: what it is about, and what it can be set to next to that
--- @param parent Frame
--- @return Frame
local function createOptionRow(parent)
  local row = CreateFrame("Frame", nil, parent)
  row:SetHeight(OPTION_ROW_HEIGHT)
  row:EnableMouse(true)
  row.name = Widgets.Label(row, "GameFontHighlight")
  row.name:SetPoint("LEFT", 0, 0)
  row.name:SetWidth(OPTION_NAME_WIDTH)
  row.name:SetWordWrap(false)
  row.choices = {}
  row:SetScript("OnEnter", function(self)
    if self.tip then
      GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
      GameTooltip:SetText(self.name:GetText())
      GameTooltip:AddLine(self.tip, 1, 1, 1, true)
      GameTooltip:Show()
    end
  end)
  row:SetScript("OnLeave", GameTooltip_Hide)
  return row
end

--- Which seat the player asked for, for a game of two: where the game names its seats that is
--- what they choose between, White or Black
--- @return { name: string, tip: string?, choices: { text: string, on: boolean, pick: fun() }[] } A line of the rules, see refreshRules
local function seatLine()
  local named = chosenGame.seatLabel ~= nil
  local line = { name = L[named and "wizard_seat" or "wizard_turn"], tip = L["wizard_seat_tip"], choices = {} }
  --- @param text string
  --- @param seat number?
  local function offer(text, seat)
    line.choices[#line.choices + 1] = {
      text = text,
      on = chosenSeat == seat,
      pick = function()
        chosenSeat = seat
      end,
    }
  end
  offer(L["wizard_seat_random"], nil)
  for seat = 1, 2 do
    offer(named and chosenGame.seatLabel(seat, 2) or L["wizard_turn_" .. seat], seat)
  end
  return line
end

--- Shows the game that was chosen and what its rules are set to
local function refreshRules()
  local rules = panel.rules
  rules.icon:SetTexture(chosenGame.icon or private.ICON)
  rules.name:SetText(chosenGame.name)
  rules.players:SetText(playersText(chosenGame))
  rules.description:SetText(chosenGame.description or "")

  -- Seats are only for the asking between two, a crowd draws them
  local seated = not Games.IsSolo(chosenGame) and #opponents() <= 1 and Games.CanSeat(chosenGame, 2)
  local lines = {}
  if seated then
    lines[1] = seatLine()
  end
  for _, option in ipairs(Games.OptionsFor(chosenGame, chosenRules)) do
    local line = { name = option.name, tip = option.description, choices = {} }
    for _, value in ipairs(Games.Choices(option)) do
      line.choices[#line.choices + 1] = {
        text = Games.OptionLabel(option, value),
        on = chosenRules[option.id] == value,
        pick = function()
          chosenRules[option.id] = value
        end,
      }
    end
    lines[#lines + 1] = line
  end

  for index = 1, math.max(#lines, #rules.rows) do
    local row, line = rules.rows[index], lines[index]
    if line and not row then
      row = createOptionRow(rules)
      row:SetPoint("TOPLEFT", RULES_INSET, -OPTIONS_TOP - (index - 1) * OPTION_ROW_HEIGHT)
      row:SetPoint("TOPRIGHT", -RULES_INSET, -OPTIONS_TOP - (index - 1) * OPTION_ROW_HEIGHT)
      rules.rows[index] = row
    end
    if row then
      row:SetShown(line ~= nil)
    end
    if line then
      row.tip = line.tip
      row.name:SetText(line.name)
      local x = OPTION_NAME_WIDTH + FILTER_GAP
      for position = 1, math.max(#line.choices, #row.choices) do
        local choice, spec = row.choices[position], line.choices[position]
        if spec and not choice then
          choice = createChoice(row)
          row.choices[position] = choice
        end
        if choice then
          choice:SetShown(spec ~= nil)
        end
        if spec then
          fillChoice(choice, spec.text, spec.on, spec.pick)
          choice:ClearAllPoints()
          choice:SetPoint("LEFT", x, 0)
          x = x + choice:GetWidth() + FILTER_GAP
        end
      end
    end
  end

  local changed = (seated and chosenSeat ~= nil) or Games.Chosen(chosenGame, chosenRules) ~= nil
  rules.reset:SetShown(changed)
  rules.usual:SetShown(#lines == 0)
  rules.note:SetText(L[Games.Chosen(chosenGame, chosenRules) and "wizard_rules_changed" or "wizard_rules_usual"])
  if Games.IsSolo(chosenGame) and Games.Chosen(chosenGame, chosenRules) then
    -- Nobody to challenge, nobody to be shown what was changed
    rules.note:SetText(L["wizard_solo_note"])
  end
  rules.note:SetShown(#lines > 0)
  rules.note:ClearAllPoints()
  rules.note:SetPoint("TOPLEFT", RULES_INSET, -OPTIONS_TOP - #lines * OPTION_ROW_HEIGHT - 8)
  rules.note:SetPoint("TOPRIGHT", -RULES_INSET, -OPTIONS_TOP - #lines * OPTION_ROW_HEIGHT - 8)
end

--- Picks whoever the box over the list stands for
local function pickTyped()
  local _, typed = listing()
  if typed then
    if mostOpponents() == 1 or not chosenIndex(typed) then
      choose(typed)
    end
    panel.nameBox:SetText("")
    refresh()
  end
end

--- @param parent Frame
--- @return Frame
local function createOpponentStep(parent)
  local step = CreateFrame("Frame", nil, parent)

  -- The game, and how it is to be played
  local rules = Widgets.Panel(step)
  rules:SetPoint("TOPRIGHT")
  rules:SetPoint("BOTTOMRIGHT")
  rules:SetWidth(RULES_WIDTH)
  rules.rows = {}
  panel.rules = rules

  rules.icon = Widgets.Icon(rules, private.ICON, 40)
  rules.icon:SetPoint("TOPLEFT", RULES_INSET, -12)
  rules.name = Widgets.Label(rules, "GameFontNormalLarge")
  rules.name:SetPoint("TOPLEFT", rules.icon, "TOPRIGHT", 12, -3)
  rules.players = Widgets.Label(rules, "GameFontHighlightSmall")
  rules.players:SetPoint("TOPLEFT", rules.name, "BOTTOMLEFT", 0, -5)
  rules.players:SetTextColor(unpack(Widgets.GREY))
  rules.description = Widgets.Label(rules, "GameFontHighlightSmall")
  rules.description:SetPoint("TOPLEFT", RULES_INSET, -62)
  rules.description:SetPoint("TOPRIGHT", -RULES_INSET, -62)
  rules.description:SetHeight(42)
  rules.description:SetJustifyV("TOP")
  rules.description:SetTextColor(unpack(Widgets.GREY))

  local optionsTitle = Widgets.Label(rules, "GameFontNormal", L["wizard_options"])
  optionsTitle:SetPoint("TOPLEFT", RULES_INSET, -OPTIONS_TOP + 26)

  -- Back to the way the game is usually played
  rules.reset = Widgets.Button(rules, L["wizard_reset"], 110, 20)
  rules.reset:SetPoint("TOPRIGHT", -RULES_INSET, -OPTIONS_TOP + 30)
  rules.reset:SetScript("OnClick", function()
    chosenRules, chosenSeat = Games.Rules(chosenGame.options), nil
    refresh()
  end)

  rules.usual = Widgets.Label(rules, "GameFontDisable", L["wizard_no_options"])
  rules.usual:SetPoint("TOPLEFT", RULES_INSET, -OPTIONS_TOP - 4)
  rules.usual:SetPoint("TOPRIGHT", -RULES_INSET, -OPTIONS_TOP - 4)
  rules.note = Widgets.Label(rules, "GameFontDisableSmall")

  -- Who to play. Whatever room the window has to spare is theirs
  local who = Widgets.Panel(step)
  who:SetPoint("TOPLEFT")
  who:SetPoint("BOTTOMRIGHT", rules, "BOTTOMLEFT", -CARD_GAP, 0)
  panel.who = who

  panel.whoTitle = Widgets.Label(who, "GameFontNormal")
  panel.whoTitle:SetPoint("TOPLEFT", 10, -10)
  panel.chosenCount = Widgets.Label(who, "GameFontHighlightSmall")
  panel.chosenCount:SetPoint("TOPRIGHT", -10, -11)
  panel.chosenCount:SetTextColor(unpack(Widgets.GREY))

  -- Narrows the list down, and takes the name of anyone who isn't on it
  panel.nameBox = CreateFrame("EditBox", nil, who, "InputBoxTemplate")
  panel.nameBox:SetHeight(24)
  panel.nameBox:SetPoint("TOPLEFT", 16, -32)
  panel.nameBox:SetPoint("TOPRIGHT", -12, -32)
  panel.nameBox:SetAutoFocus(false)
  panel.nameBox:SetMaxLetters(48)
  -- Picks, and leaves the sending to the button: what is typed may only have been a search
  panel.nameBox:SetScript("OnEnterPressed", pickTyped)
  panel.nameBox:SetScript("OnEscapePressed", panel.nameBox.ClearFocus)
  panel.nameBox:SetScript("OnTextChanged", function(_, userInput)
    if userInput then
      if mostOpponents() == 1 then
        chosenPlayers = {}
      end
      refresh()
    end
  end)
  panel.nameHint = Widgets.Label(panel.nameBox, "GameFontDisable", L["wizard_find_player"])
  panel.nameHint:SetPoint("LEFT", 2, 0)

  panel.groupButtons = {}
  for index, group in ipairs({ false, "recent", "guild", "friend" }) do
    local button = createChoice(who)
    button.group = group or nil
    panel.groupButtons[index] = button
  end

  panel.players = Widgets.List(who, COLUMN_WIDTH - 12, PLAYER_ROW_HEIGHT, createPlayerRow)
  panel.players.frame:SetPoint("TOPLEFT", 6, -PLAYERS_TOP)
  panel.players.frame:SetPoint("BOTTOMRIGHT", -6, 50)

  panel.nobody = Widgets.Label(who, "GameFontDisable")
  panel.nobody:SetPoint("TOPLEFT", 12, -PLAYERS_TOP - 8)
  panel.nobody:SetPoint("TOPRIGHT", -12, -PLAYERS_TOP - 8)

  -- What the challenge needs to get there
  panel.whoHint = Widgets.Label(who, "GameFontDisableSmall")
  panel.whoHint:SetPoint("BOTTOMLEFT", 10, 8)
  panel.whoHint:SetPoint("BOTTOMRIGHT", -10 - LINK_WIDTH - 8, 8)
  panel.whoHint:SetHeight(36)
  panel.whoHint:SetJustifyV("BOTTOM")

  -- Or nobody in particular: a link for chat, and the game is whoever's clicks it first
  panel.linkButton = Widgets.Button(who, L["wizard_link"], LINK_WIDTH, 22)
  panel.linkButton:SetPoint("BOTTOMRIGHT", -10, 10)
  panel.linkButton:SetScript("OnClick", link)
  panel.linkButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(L["wizard_link"])
    GameTooltip:AddLine(L["wizard_link_tip"], 1, 1, 1, true)
    GameTooltip:Show()
  end)
  panel.linkButton:SetScript("OnLeave", GameTooltip_Hide)

  return step
end

--- Shows who there is to play
local function refreshPlayers()
  local crowd = mostOpponents() > 1
  panel.whoTitle:SetText(L[crowd and "wizard_who_more" or "wizard_who"])
  panel.chosenCount:SetText(crowd and L["wizard_chosen"]:format(#opponents(), mostOpponents()) or "")
  panel.whoHint:SetText(L[crowd and "wizard_by_name_hint_more" or "wizard_by_name_hint"])
  panel.nameHint:SetShown((panel.nameBox:GetText() or "") == "")
  -- A link is to a game for two
  panel.linkButton:SetShown(Games.CanSeat(chosenGame, 2))

  local x = 10
  for _, button in ipairs(panel.groupButtons) do
    local group = button.group
    fillChoice(button, L[GROUP_LABELS[group or "all"]], chosenGroup == group, function()
      chosenGroup = group
    end)
    button:ClearAllPoints()
    button:SetPoint("TOPLEFT", x, -64)
    x = x + button:GetWidth() + FILTER_GAP
  end

  panel.players:SetWidth(widthOf(panel.who, COLUMN_WIDTH) - 12)
  local items, typed = listing()
  panel.players:Update(items, function(row, item)
    fillPlayerRow(row, item, typed)
  end)
  panel.nobody:SetShown(#items == 0)
  panel.nobody:SetText(L[chosenGroup and "wizard_nobody_group" or "wizard_nobody"])
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
    refreshGames()
    return
  end

  -- A game for one has nobody to pick: its rules have the step to themselves
  local solo = Games.IsSolo(chosenGame)
  panel.who:SetShown(not solo)
  panel.rules:ClearAllPoints()
  panel.rules:SetPoint(solo and "TOP" or "TOPRIGHT")
  panel.rules:SetPoint(solo and "BOTTOM" or "BOTTOMRIGHT")
  panel.sendButton:SetText(L[solo and "wizard_play" or "wizard_send"])
  if solo then
    panel.step:SetText(L["wizard_step_solo"]:format(chosenGame.name))
    refreshRules()
    panel.sendButton:SetEnabled(true)
    panel.summary:SetText(chosenGame.name)
    return
  end

  panel.step:SetText(L["wizard_step_opponent"]:format(chosenGame.name))
  refreshPlayers()
  refreshRules()

  local names = opponents()
  local ready = Games.CanSeat(chosenGame, #names + 1)
  panel.sendButton:SetEnabled(ready)
  if ready then
    panel.summary:SetText(L[#names > 1 and "with_players" or "wizard_summary"]:format(chosenGame.name, listed(names)))
  elseif #names == 0 then
    panel.summary:SetText(L["wizard_pick_someone"])
  else
    panel.summary:SetText(L["wizard_player_counts"]:format(chosenGame.name, playersText(chosenGame)))
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
  -- The target is among the players on offer
  panel:RegisterEvent("PLAYER_TARGET_CHANGED")
  panel:SetScript("OnEvent", function()
    Wizard.Refresh()
  end)
  -- Both steps lay themselves out for the room the window gives them
  panel:SetScript("OnSizeChanged", function()
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
  chosenGame, chosenPlayers, chosenGroup, chosenSeat = nil, {}, nil, nil
  chosenGenre, chosenSeats, favouritesOnly = nil, nil, false
  panel.nameBox:SetText("")
  panel.searchBox:SetText("")
  panel:Show()
  refresh()
  panel.games:ScrollTo(1)
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
