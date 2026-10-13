--------------------------
--  New game wizard
--------------------------
-- Two steps: pick a game, then pick who to play. Lives inside the main window and takes over its
-- content while open. The games are a list that scrolls, narrowed down by typing, by genre or by
-- how many are playing, with the ones the player starred first and the rest by name. However
-- wide the window is, the cards share its width: as many next to each other as fit.
-- A game for more than two has its players picked one after the other, as many as it can seat.
-- A game for one has nobody to pick, and begins as soon as it is chosen.

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
local SOLO_GENRE = "solo"
local STAR = "Interface\\AddOns\\ForeverGames\\Images\\Board\\favourite"

local SOURCE_LABELS = { guild = "source_guild", friend = "source_friend", other = "source_other" }

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

local refresh

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

--- Everyone the challenge would go to: the players picked, and whoever is typed in. For a game
--- of two whatever is typed wins over the list selection
--- @return string[]
local function opponents()
  local typed = Transport.Normalize(panel.nameBox:GetText())
  if not typed then
    return chosenPlayers
  elseif mostOpponents() == 1 then
    return { typed }
  end
  local everyone = { unpack(chosenPlayers) }
  if not chosenIndex(typed) then
    everyone[#everyone + 1] = typed
  end
  return everyone
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
  local match, err = private.session:Invite(opponents(), chosenGame and chosenGame.id)
  if not match then
    panel.error:SetText(L["err_" .. err])
    return
  end
  Wizard.Close(match.id)
end

--- The game was chosen. One that is played alone begins there and then, anything else goes on
--- to who it is played with
--- @param game GameDefinition
local function pick(game)
  if Games.IsSolo(game) then
    local match = private.session:Invite({}, game.id)
    Wizard.Close(match and match.id)
    return
  end
  chosenGame = game
  chosenPlayers = {}
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
    local on = button.isOn()
    button:SetBackdropBorderColor(1, on and 0.82 or 1, on and 0 or 1, on and 0.9 or 0.1)
    button.label:SetTextColor(1, on and 0.82 or 1, on and 0 or 1)
  end
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
    choose(self.player)
    panel.nameBox:SetText("")
    panel.nameBox:ClearFocus()
    refresh()
  end)
  return row
end

--- One of the players picked for a game of more than two. Clicking it unpicks them
--- @param content Frame
--- @return Button
local function createChosenRow(content)
  local row = CreateFrame("Button", nil, content)

  local hover = row:CreateTexture(nil, "HIGHLIGHT")
  hover:SetAllPoints()
  hover:SetColorTexture(1, 1, 1, 0.08)

  row.name = Widgets.Label(row, "GameFontHighlight")
  row.name:SetPoint("LEFT", 8, 0)

  local remove = Widgets.Label(row, "GameFontDisableSmall", L["wizard_remove"])
  remove:SetPoint("RIGHT", -8, 0)

  row:SetScript("OnClick", function(self)
    choose(self.player)
    refresh()
  end)
  return row
end

--- @param parent Frame
--- @return Frame
local function createOpponentStep(parent)
  local step = CreateFrame("Frame", nil, parent)

  -- Anyone else, by name
  local other = Widgets.Panel(step)
  other:SetPoint("TOPRIGHT")
  other:SetPoint("BOTTOMRIGHT")
  other:SetWidth(COLUMN_WIDTH)

  -- Players known to be online with the addon. Whatever room the window has to spare is theirs
  local available = Widgets.Panel(step)
  available:SetPoint("TOPLEFT")
  available:SetPoint("BOTTOMRIGHT", other, "BOTTOMLEFT", -CARD_GAP, 0)
  panel.available = available

  local availableTitle = Widgets.Label(available, "GameFontNormal", L["wizard_available"])
  availableTitle:SetPoint("TOPLEFT", 10, -10)

  panel.players = Widgets.List(available, COLUMN_WIDTH - 12, PLAYER_ROW_HEIGHT, createPlayerRow)
  panel.players.frame:SetPoint("TOPLEFT", 6, -32)
  panel.players.frame:SetPoint("BOTTOMRIGHT", -6, 6)

  panel.nobody = Widgets.Label(available, "GameFontDisable", L["wizard_nobody"])
  panel.nobody:SetPoint("TOPLEFT", 12, -40)
  panel.nobody:SetPoint("TOPRIGHT", -12, -40)

  local otherTitle = Widgets.Label(other, "GameFontNormal", L["wizard_by_name"])
  otherTitle:SetPoint("TOPLEFT", 10, -10)

  panel.nameBox = CreateFrame("EditBox", nil, other, "InputBoxTemplate")
  panel.nameBox:SetSize(COLUMN_WIDTH - 40, 24)
  panel.nameBox:SetPoint("TOPLEFT", 18, -36)
  panel.nameBox:SetAutoFocus(false)
  panel.nameBox:SetMaxLetters(48)
  panel.nameBox:SetScript("OnEnterPressed", function()
    local typed = Transport.Normalize(panel.nameBox:GetText())
    if not typed then
      return
    end
    if mostOpponents() == 1 then
      send()
    else
      -- One name after the other, the challenge goes out when they are all in
      if not chosenIndex(typed) then
        choose(typed)
      end
      panel.nameBox:SetText("")
      refresh()
    end
  end)
  panel.nameBox:SetScript("OnEscapePressed", panel.nameBox.ClearFocus)
  panel.nameBox:SetScript("OnTextChanged", function(_, userInput)
    if userInput then
      if mostOpponents() == 1 then
        chosenPlayers = {}
      end
      refresh()
    end
  end)

  panel.targetButton = Widgets.Button(other, "", COLUMN_WIDTH - 40, 24)
  panel.targetButton:SetPoint("TOPLEFT", panel.nameBox, "BOTTOMLEFT", -6, -10)
  panel.targetButton:SetScript("OnClick", function()
    local target = targetName()
    if target and mostOpponents() == 1 then
      chosenPlayers = {}
      panel.nameBox:SetText(Transport.DisplayName(target))
      refresh()
    elseif target then
      if not chosenIndex(target) then
        choose(target)
      end
      refresh()
    end
  end)

  panel.nameHint = Widgets.Label(other, "GameFontDisableSmall")
  panel.nameHint:SetPoint("TOPLEFT", panel.targetButton, "BOTTOMLEFT", 2, -14)
  panel.nameHint:SetWidth(COLUMN_WIDTH - 44)
  panel.nameHint:SetJustifyV("TOP")

  -- Who is in so far, for a game of more than two
  panel.chosenTitle = Widgets.Label(other, "GameFontNormal")
  panel.chosenTitle:SetPoint("TOPLEFT", 10, -170)
  panel.chosen = Widgets.List(other, COLUMN_WIDTH - 12, PLAYER_ROW_HEIGHT, createChosenRow)
  panel.chosen.frame:SetPoint("TOPLEFT", 6, -192)
  panel.chosen.frame:SetPoint("BOTTOMRIGHT", -6, 6)

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
    refreshGames()
    return
  end

  panel.step:SetText(L["wizard_step_opponent"]:format(chosenGame.name))

  panel.players:SetWidth(widthOf(panel.available, COLUMN_WIDTH) - 12)
  local players = private.presence:List()
  panel.players:Update(players, function(row, player)
    row.player = player.name
    row.name:SetText(Transport.DisplayName(player.name))
    row.source:SetText(L[SOURCE_LABELS[player.source]])
    row.selected:SetShown(chosenIndex(player.name) ~= nil)
  end)
  panel.nobody:SetShown(#players == 0)

  local target = targetName()
  panel.targetButton:SetShown(target ~= nil)
  if target then
    panel.targetButton:SetText(L["wizard_use_target"]:format(Transport.DisplayName(target)))
  end

  local crowd = mostOpponents() > 1
  panel.nameHint:SetText(L[crowd and "wizard_by_name_hint_more" or "wizard_by_name_hint"])
  panel.chosenTitle:SetShown(crowd)
  panel.chosen.frame:SetShown(crowd)
  if crowd then
    panel.chosenTitle:SetText(L["wizard_chosen"]:format(#chosenPlayers, mostOpponents()))
    panel.chosen:Update(chosenPlayers, function(row, name)
      row.player = name
      row.name:SetText(Transport.DisplayName(name))
    end)
  end

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
  -- The "use my target" shortcut follows the target
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
  chosenGame, chosenPlayers = nil, {}
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
