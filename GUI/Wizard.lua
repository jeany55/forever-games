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
-- then played with whoever clicks the link, each with a game of their own. A game for one that
-- can be raced is linked the same way, for whoever clicks it to race. Shift-clicked on the first
-- step, the way an item is linked, a game is linked there and then, set up the way it was last
-- time.
-- A game that can be played alone or with others has the players to pick like any other, and is
-- played alone when nobody is.
-- Who plays is shown as a table across the top of the second step, a card for each seat: the
-- player's own, then whoever was picked, then the seats still open. Picking somebody sits them
-- in the next open seat, and a full table grows for them as far as the game goes. How many seats
-- there are can be set outright, among the numbers the game is for. An open seat can be given to
-- the computer, in a game it plays, and each of its seats has how well it plays on it: a table of
-- the computer alone is a game against it, and one with people at it a challenge like any other.
-- The computer's seats are set up the same way the next time, the people's left open.
-- A game for one that can be raced (Engine/Race.lua) has somebody to pick the way a game that
-- can be played alone or with others does: picked, they are challenged to race it, each playing
-- the same deal of it on their own, and with nobody picked it is played alone.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Computer = private.Computer
local Games = private.Games
local Race = private.Race
local Rooms = private.Rooms
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
-- An option of more choices than MOST_BUTTONS is a dropdown rather than its choices side by side
-- when they would take more rows than MOST_CHOICE_ROWS. A few choices are better seen all at once,
-- even over a few rows. Under the options, room is kept for the note on how the rules are set
local MOST_BUTTONS, MOST_CHOICE_ROWS, NOTE_ROOM = 5, 2, 40
local SOLO_GENRE = "solo"
-- What the games for a room (Engine/Rooms.lua) are listed as
local PARTY_GENRE = "party"
local STAR = "Interface\\AddOns\\ForeverGames\\Images\\Board\\favourite"
-- What stands for the computer: a cog, which every client has
local COMPUTER_ICON = "Interface\\Icons\\INV_Misc_Gear_01"
-- A game that is the day's challenge, which it is started as from its card
local DAILY_ICON = "Interface\\Icons\\INV_Misc_PocketWatch_01"
-- The table of who plays, across the top of the second step: its title, then a card for each seat
local TABLE_HEIGHT, SEAT_HEIGHT, SEAT_GAP, SEAT_MOST_WIDTH = 92, 56, 8, 170

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
-- Who sits at the table besides the player, seat after seat: a player picked, { name = "Bob-Realm" },
-- or the computer, { computer = "hard" }. The seats after them are open
--- @type ({ name: string?, computer: string? })[]
local atTable = {}
-- How many seats the player asked for. The table has as many as it takes for everyone at it all
-- the same
local wanted = 2
-- How well the computer put at the table last plays, for the next one put there
local lastLevel = Computer.DEFAULT_LEVEL
-- What the list of players is narrowed down to: "recent", "guild" or "friend"
--- @type string?
local chosenGroup
-- What every option of the chosen game is set to, by id
--- @type table<string, any>
local chosenRules = {}
-- The seat the player asked for in a game of two, nil to leave it to chance
--- @type number?
local chosenSeat
-- What went wrong with what the player just did, for the next refresh to say, as a locale key
--- @type string?
local problem
-- In a race whose game can send the run that set the player's best as it is, whether that is what
-- is raced rather than a new run each (Session:BestToRace). Only where there is a best to send
local racingBest = true

local refresh
--- @type fun(): WizardPlayer[], string?
local listing

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

--- How the player last set up each game against the computer, by game id. Remembered between
--- sessions
--- @return table<string, { level: string?, count: number?, seat: number?, chosen: boolean? }>
local function rememberedComputer()
  local profile = ForeverGames.db.profile
  profile.computer = profile.computer or {}
  return profile.computer
end

--- @param level string
--- @return string
local function levelName(level)
  return L["computer_level_" .. level]
end

--- How the player's games against the computer went at a level, in a few words
--- @param gameId string
--- @param level string
--- @return string
local function tallyText(gameId, level)
  local tally = private.session:Versus(gameId, level)
  if tally.won + tally.drawn + tally.lost == 0 then
    return L["computer_tally_none"]
  end
  return L["computer_tally"]:format(tally.won, tally.drawn, tally.lost)
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

--- Whether the chosen game is one for one that can be raced against somebody
--- @return boolean
local function raceable()
  return chosenGame ~= nil and Games.IsSolo(chosenGame) and Race.Has(chosenGame)
end

--- How long the run that set the player's best by the rules as they are set took, for a race whose
--- game can send that run to be raced as it is (GameGhost.course)
--- @return number? seconds nil for no best by these rules
--- @return boolean sendable Whether the game can send a best at all
local function bestToRace()
  if not raceable() or not (chosenGame.ghost and chosenGame.ghost.course) then
    return nil, false
  end
  return private.session:BestToRace(chosenGame.id, Games.ForPlayers(chosenGame, chosenRules, 1)), true
end

--- @return boolean Whether a race sent now would be against the player's best rather than a new run
local function sendingBest()
  return racingBest and bestToRace() ~= nil
end

--- A race's time, to the hundredth: "1:23.45"
--- @param seconds number
--- @return string
local function raceTime(seconds)
  local hundredths = math.floor(seconds * 100 + 0.5)
  return L["race_time"]:format(Widgets.Time(math.floor(hundredths / 100)), hundredths % 100)
end

--- How many can sit at the table of the chosen game: a race is the player and their rival, or
--- the player alone
--- @return number[]
local function seatCounts()
  return raceable() and { 1, 2 } or Games.SeatCounts(chosenGame)
end

--- How many others the chosen game can be played with at most
--- @return number
local function mostOpponents()
  local counts = seatCounts()
  return counts[#counts] - 1
end

--- @param name string?
--- @return number? index Where a player sits at the table
local function seatOf(name)
  for index, seat in ipairs(atTable) do
    if seat.name ~= nil and seat.name == name then
      return index
    end
  end
  return nil
end

--- The fewest seats the chosen game can be played with that are at least so many
--- @param count number
--- @return number? nil if it can't be played by that many
local function seatsFor(count)
  for _, seats in ipairs(seatCounts()) do
    if seats >= count then
      return seats
    end
  end
  return nil
end

--- How many seats the table has: as many as were asked for, or as it takes for everyone at it
--- @return number
local function tableSize()
  return seatsFor(math.max(wanted, #atTable + 1)) or #atTable + 1
end

--- Takes the last of the computer's seats away from the table
--- @return boolean Whether it had one
local function dropComputer()
  for index = #atTable, 1, -1 do
    if atTable[index].computer then
      table.remove(atTable, index)
      return true
    end
  end
  return false
end

--- Sits a player at the table, or lets them go again if they sit there already. Between two they
--- take the one seat whoever had it, and with more the next open one: a full table grows for
--- them, and where it can't grow the computer gives a seat up to them
--- @param name string
local function seatPlayer(name)
  local index = seatOf(name)
  if index then
    table.remove(atTable, index)
  elseif mostOpponents() == 1 then
    atTable = { { name = name } }
  elseif seatsFor(#atTable + 2) or dropComputer() then
    atTable[#atTable + 1] = { name = name }
  else
    problem = "wizard_table_full"
  end
end

--- Sets how many seats the table has. The computer gives up seats where it takes too many, the
--- players picked don't
--- @param count number
local function setSize(count)
  while #atTable + 1 > count and dropComputer() do
  end
  if #atTable + 1 > count then
    problem = "wizard_table_too_small"
  end
  wanted = count
end

--- "2 players", "2 to 6 players", or "2, 3, 4 or 6 players" where not every number in between is
--- @param game GameDefinition|PartyGame
--- @return string
local function countText(game)
  if Rooms.Game(game.id) == game then
    return L["players_party"]
  elseif Games.IsSolo(game) then
    return L[Race.Has(game) and "players_race" or "players_solo"]
  end
  local counts = Games.SeatCounts(game)
  if #counts == 1 then
    return L["players_exactly"]:format(counts[1])
  elseif #counts > 2 and counts[#counts] - counts[1] == #counts - 1 then
    return L["players_range"]:format(counts[1], counts[#counts])
  end
  return L["players_choice"]:format(table.concat(counts, ", ", 1, #counts - 1), counts[#counts])
end

--- How many play a game, and that the computer can be played against at it
--- @param game GameDefinition|PartyGame
--- @return string
local function playersText(game)
  local text = countText(game)
  return (Rooms.Game(game.id) ~= game and Computer.Plays(game)) and L["players_or_computer"]:format(text) or text
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
  return Transport.UnitPlayer("target")
end

--- Who sits at the table as it is to be sent: whoever the box over the list stands for takes the
--- next open seat, and a full table grows for them where it can
--- @return ({ name: string?, computer: string?, typed: boolean? })[] seats Besides the player's own, the open ones left out
--- @return number size How many seats there are
local function sitting()
  local seats, size = { unpack(atTable) }, tableSize()
  local _, typed = listing()
  if typed and not seatOf(typed) then
    local room = #seats < size - 1 and size or seatsFor(#seats + 2)
    if room then
      size = room
      seats[#seats + 1] = { name = typed, typed = true }
    end
  end
  return seats, size
end

--- @param seats { name: string?, computer: string? }[]
--- @return string[] names The players at the table
--- @return string[] levels How well the computer plays each of its seats
local function whoIsAt(seats)
  local names, levels = {}, {}
  for _, seat in ipairs(seats) do
    if seat.name then
      names[#names + 1] = seat.name
    else
      levels[#levels + 1] = seat.computer
    end
  end
  return names, levels
end

local function send()
  local seats, size = sitting()
  local names, levels = whoIsAt(seats)
  -- A race is played alone on both sides
  local players = raceable() and 1 or size
  local setup = { options = Games.ForPlayers(chosenGame, chosenRules, players), seat = (size == 2 and not raceable()) and chosenSeat or nil, best = sendingBest() or nil }
  if #levels > 0 then
    setup.computer = { levels = levels }
  end
  local match, err = private.session:Invite(names, chosenGame.id, setup)
  if not match then
    panel.error:SetText(L["err_" .. err])
    return
  end
  remembered()[chosenGame.id] = Games.Chosen(chosenGame, chosenRules)
  if Computer.Plays(chosenGame) then
    -- The same table the next time: the computer where it was, the players' seats open
    rememberedComputer()[chosenGame.id] = { size = size, levels = levels, seat = setup.seat, chosen = #levels > 0 }
  end
  Wizard.Close(match.id)
end

--- Leaves the game open to whoever clicks a link to it, and hands the player the link to send
local function link()
  local setup = { options = Games.ForPlayers(chosenGame, chosenRules, 2), seat = chosenSeat }
  if raceable() then
    setup = { options = Games.ForPlayers(chosenGame, chosenRules, 1), best = sendingBest() or nil }
  end
  local ok, err = private.Links.Share(chosenGame, setup)
  if not ok then
    panel.error:SetText(L["err_" .. err])
    return
  end
  remembered()[chosenGame.id] = Games.Chosen(chosenGame, chosenRules)
  Wizard.Close()
end

--- The game was chosen. One that is played alone begins there and then unless it has rules to
--- set, anything else goes on to who it is played with and how
--- @param game GameDefinition|PartyGame
--- @param rules table<string, any>? How its rules are set, rather than the way they were last time
local function pick(game, rules)
  -- A game for a room isn't set up here at all: it has a window of its own, where a room of it
  -- is opened or joined
  if Rooms.Game(game.id) == game then
    Wizard.Close()
    private.Party.Open(game.id)
    return
  end
  if Games.IsSolo(game) and #(game.options or {}) == 0 and not Race.Has(game) then
    local match = private.session:Invite({}, game.id)
    Wizard.Close(match and match.id)
    return
  end
  chosenGame = game
  chosenGroup, chosenSeat, racingBest = nil, nil, true
  chosenRules = Games.Rules(game.options, rules or remembered()[game.id])
  atTable, wanted = {}, Games.SeatCounts(game)[1]
  -- The computer at the table again if it sat there last time, where it sat and as good
  local last = rememberedComputer()[game.id] or {}
  if Computer.Plays(game) and last.chosen then
    local levels = { unpack(last.levels or {}) }
    for index = 1, #levels == 0 and (last.count or 1) or 0 do
      -- Set up before each seat had its own
      levels[index] = last.level
    end
    for _, level in ipairs(levels) do
      if seatsFor(#atTable + 2) then
        atTable[#atTable + 1] = { computer = Computer.IsLevel(level) and level or Computer.DEFAULT_LEVEL }
        lastLevel = atTable[#atTable].computer
      end
    end
    wanted = (last.size and Games.CanSeat(game, last.size)) and last.size or wanted
    chosenSeat = last.seat
  end
  panel.nameBox:SetText("")
  refresh()
end

--- A game shift-clicked: linked in chat the way it was set up last time, and the wizard left
--- open. A game for a room has the room linked, and without one its window is where one is opened
--- @param game GameDefinition|PartyGame
local function share(game)
  if Rooms.Game(game.id) ~= game and not Games.CanSeat(game, 2) and not Race.Has(game) then
    ForeverGames:Print(L["link_alone"]:format(game.name))
    return
  end
  local ok, err = private.Links.Share(game)
  if not ok then
    if err == "no_room" then
      pick(game)
    end
    ForeverGames:Print(L["err_" .. err])
  end
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

  -- As far as the column on the right, cut short where it doesn't fit
  card.players = Widgets.Label(card, "GameFontHighlightSmall")
  card.players:SetPoint("LEFT", card.genre, "RIGHT", 10, 0)
  card.players:SetPoint("RIGHT", card, "RIGHT", -32, 0)
  card.players:SetWordWrap(false)
  card.players:SetTextColor(unpack(Widgets.GREY))

  -- Under the star, for a game the computer plays. It says so when pointed at, and lets clicks
  -- through to the card
  card.computer = CreateFrame("Frame", nil, card)
  card.computer:SetSize(16, 16)
  card.computer:SetPoint("TOPRIGHT", -10, -34)
  card.computer.icon = Widgets.Icon(card.computer, COMPUTER_ICON, 16)
  card.computer.icon:SetAllPoints()
  card.computer.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  card.computer:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(L["computer"])
    GameTooltip:AddLine(L["computer_plays_tip"], 1, 1, 1, true)
    GameTooltip:Show()
  end)
  card.computer:SetScript("OnLeave", GameTooltip_Hide)
  if card.computer.SetMouseClickEnabled then
    card.computer:SetMouseClickEnabled(false)
  end

  -- Under the icon and as wide as the card, cut short where it doesn't fit
  card.description = Widgets.Label(card, "GameFontHighlightSmall")
  card.description:SetPoint("TOPLEFT", card.icon, "BOTTOMLEFT", 0, -8)
  card.description:SetPoint("BOTTOMRIGHT", -12, 10)
  card.description:SetJustifyV("TOP")
  card.description:SetTextColor(unpack(Widgets.GREY))

  -- Where the computer's would be, for a game that is the day's challenge: today's is started,
  -- or gone back to, from here
  card.daily = CreateFrame("Button", nil, card)
  card.daily:SetSize(20, 20)
  card.daily:SetPoint("TOPRIGHT", -8, -32)
  card.daily.icon = Widgets.Icon(card.daily, DAILY_ICON, 20)
  card.daily.icon:SetAllPoints()
  card.daily.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  local shine = card.daily:CreateTexture(nil, "HIGHLIGHT")
  shine:SetAllPoints()
  shine:SetColorTexture(1, 1, 1, 0.25)
  card.daily:SetScript("OnClick", function()
    GameTooltip_Hide()
    local match, err = private.session:Daily(card.game.id)
    if not match then
      ForeverGames:Print(L["err_" .. err])
      return
    end
    Wizard.Close(match.id)
  end)
  card.daily:SetScript("OnEnter", function(self)
    local game, daily, today = card.game, private.daily, private.session:Today()
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(L["daily_card"])
    GameTooltip:AddLine(L["daily_card_tip"], 1, 1, 1, true)
    if daily and today then
      local mine = daily:Mine(today, game.id)
      local played = #daily:Board(today, game.id)
      if mine ~= nil then
        GameTooltip:AddLine(L["daily_card_mine"]:format(private.MainFrame.DailyScore(game.id, mine)), unpack(Widgets.GOLD))
      elseif private.session:PlayedToday(game.id) then
        GameTooltip:AddLine(L["daily_card_playing"], unpack(Widgets.GOLD))
      end
      GameTooltip:AddLine(L["daily_card_played"]:format(played), unpack(Widgets.GREY))
    end
    GameTooltip:Show()
  end)
  card.daily:SetScript("OnLeave", GameTooltip_Hide)

  card:SetScript("OnClick", function(self)
    if IsShiftKeyDown() then
      share(self.game)
    else
      pick(self.game)
    end
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
      local genre = Rooms.Game(game.id) == game and PARTY_GENRE or game.genre
      card.genre:SetText(genre and L["genre_" .. genre] or "")
      card.players:SetText(countText(game))
      local daily = Rooms.Game(game.id) ~= game and private.Daily.Has(game)
      card.computer:SetShown(not daily and Rooms.Game(game.id) ~= game and Computer.Plays(game))
      card.daily:SetShown(daily)
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
  if #Rooms.Games() > 0 then
    add(L["genre_" .. PARTY_GENRE], "genre", function()
      return chosenGenre == PARTY_GENRE
    end, function()
      chosenGenre = chosenGenre ~= PARTY_GENRE and PARTY_GENRE or nil
    end)
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
  -- The games for a room are listed with the rest. They are for any number but one
  local words = {}
  for word in (panel.searchBox:GetText() or ""):lower():gmatch("%S+") do
    words[#words + 1] = word
  end
  for _, game in ipairs(Rooms.Games()) do
    local matches = (chosenGenre == nil or chosenGenre == PARTY_GENRE) and chosenSeats ~= 1
    local about = table.concat({ game.name, game.description or "", L["genre_" .. PARTY_GENRE] }, " "):lower()
    for _, word in ipairs(words) do
      matches = matches and about:find(word, 1, true) ~= nil
    end
    if matches and (starred[game.id] or not favouritesOnly) then
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
listing = function()
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
        if player.name then
          listed[player.name] = true
        end
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
  if typed and not inList[typed] and not seatOf(typed) then
    local online = known[typed] and known[typed].online
    section(L["wizard_by_name"], { { name = typed, online = online, note = L["wizard_by_name_note"] } })
  end
  for _, seat in ipairs(atTable) do
    if seat.name and not inList[seat.name] then
      local player = known[seat.name] or {}
      also[#also + 1] = { name = seat.name, source = player.source, online = player.online, ago = player.ago }
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
    seatPlayer(self.player)
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

  local picked = seatOf(item.name) ~= nil or item.name == typed
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
  choice:SetScript("OnEnter", function(self)
    if self.tip then
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:SetText(self.label:GetText())
      GameTooltip:AddLine(self.tip, 1, 1, 1, true)
      GameTooltip:Show()
    end
  end)
  choice:SetScript("OnLeave", GameTooltip_Hide)
  -- One that can't be chosen still says why
  if choice.SetMotionScriptsWhileDisabled then
    choice:SetMotionScriptsWhileDisabled(true)
  end
  return choice
end

--- @param choice Button
--- @param text string
--- @param on boolean Whether it is what is chosen
--- @param pick fun()
--- @param tip string? What it means, for the tooltip
--- @param disabled boolean? It can't be chosen as things are, the tooltip saying why
local function fillChoice(choice, text, on, pick, tip, disabled)
  choice.pick, choice.picked, choice.tip = pick, on, tip
  choice.label:SetText(text)
  choice:SetSize(choice.label:GetStringWidth() + CHOICE_PADDING, FILTER_HEIGHT)
  choice:SetEnabled(not disabled)
  paint(choice, on)
  if disabled then
    choice.label:SetTextColor(unpack(Widgets.GREY))
  end
end

--- A line of the rules: what it is about, and what it can be set to next to that
--- @param parent Frame
--- @return Frame
local function createOptionRow(parent)
  local row = CreateFrame("Frame", nil, parent)
  row:SetHeight(OPTION_ROW_HEIGHT)
  row:EnableMouse(true)
  row.name = Widgets.Label(row, "GameFontHighlight")
  row.name:SetPoint("LEFT", row, "TOPLEFT", 0, -OPTION_ROW_HEIGHT / 2)
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

--- What a race is run against, for a game that can send the player's best as it is: that run, or
--- a new one each. Without a best by these rules there is only the new run, and the line says so
--- @param best number? Seconds the best by these rules took
--- @return { name: string, tip: string?, choices: { text: string, on: boolean, pick: fun(), tip: string?, disabled: boolean? }[] } A line of the rules, see refreshRules
local function raceLine(best)
  local line = { name = L["wizard_race_against"], tip = L["wizard_race_against_tip"], choices = {} }
  if best then
    line.choices[1] = {
      text = L["wizard_race_mine"]:format(raceTime(best)),
      on = racingBest,
      pick = function()
        racingBest = true
      end,
      tip = L["wizard_race_mine_tip"],
    }
  else
    line.choices[1] = { text = L["wizard_race_no_best"], on = false, pick = function() end, tip = L["wizard_race_no_best_tip"], disabled = true }
  end
  line.choices[2] = {
    text = L["wizard_race_new"],
    on = not best or not racingBest,
    pick = function()
      racingBest = false
    end,
    tip = L["wizard_race_new_tip"],
  }
  return line
end

--- The next level up from one, round to the easiest again after the hardest
--- @param level string
--- @return string
local function nextLevel(level)
  for index, known in ipairs(Computer.LEVELS) do
    if known == level then
      return Computer.LEVELS[index % #Computer.LEVELS + 1]
    end
  end
  return Computer.DEFAULT_LEVEL
end

--- A seat at the table: whoever sits there, or that it is open
--- @param parent Frame
--- @return Button
local function createSeatCard(parent)
  local card = Widgets.Panel(parent, "Button")
  card:SetHeight(SEAT_HEIGHT)

  card.name = Widgets.Label(card, "GameFontHighlight")
  card.name:SetPoint("TOPLEFT", 10, -9)
  card.name:SetPoint("TOPRIGHT", -24, -9)
  card.name:SetWordWrap(false)

  card.note = Widgets.Label(card, "GameFontDisableSmall")
  card.note:SetPoint("BOTTOMLEFT", 10, 10)
  card.note:SetPoint("BOTTOMRIGHT", -10, 10)
  card.note:SetWordWrap(false)

  -- How well the computer plays the seat, or the computer to sit in it where it is open
  card.action = createChoice(card)
  card.action:SetPoint("BOTTOMLEFT", 8, 6)

  -- Leaves the seat open again
  card.remove = CreateFrame("Button", nil, card)
  card.remove:SetSize(18, 18)
  card.remove:SetPoint("TOPRIGHT", -3, -3)
  card.remove.label = Widgets.Label(card.remove, "GameFontDisable", "x")
  card.remove.label:SetPoint("CENTER", 0, 1)
  card.remove:SetScript("OnEnter", function(self)
    self.label:SetTextColor(1, 1, 1)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(L["wizard_seat_remove"])
    GameTooltip:Show()
  end)
  card.remove:SetScript("OnLeave", function(self)
    self.label:SetTextColor(0.5, 0.5, 0.5)
    GameTooltip_Hide()
  end)
  card.remove:SetScript("OnClick", function()
    GameTooltip_Hide()
    table.remove(atTable, card.index)
    refresh()
  end)
  return card
end

--- @param card Button
--- @param seat { name: string?, computer: string?, typed: boolean? }? Nil for an open seat
--- @param index number? Where it is at the table, nil for the player's own seat
local function fillSeatCard(card, seat, index)
  card.index = index
  local own, open = index == nil, index ~= nil and seat == nil
  card:SetBackdropBorderColor(1, own and 0.82 or 1, own and 0 or 1, own and 0.6 or (open and 0.06 or 0.18))
  card:SetBackdropColor(0, 0, 0, open and 0.15 or 0.4)
  card.remove:SetShown(seat ~= nil and not seat.typed)
  card.note:Show()
  card.action:Hide()
  card.name:SetTextColor(1, 1, 1)

  if own then
    card.name:SetText(Transport.DisplayName(Transport.PlayerName()))
    card.note:SetText(L["wizard_seat_you"])
  elseif seat and seat.name then
    card.name:SetText(Transport.DisplayName(seat.name))
    card.note:SetText(L[(seat.typed and "wizard_seat_typed") or (sendingBest() and "wizard_seat_racing_best") or (raceable() and "wizard_seat_racing") or "wizard_seat_challenged"])
  elseif seat then
    -- Clicked, it plays better, and from the hardest round to the easiest again
    card.name:SetText(L["computer"])
    card.note:Hide()
    local level = seat.computer
    local tip = L["computer_level_" .. level .. "_tip"] .. "\n\n" .. tallyText(chosenGame.id, level) .. "\n\n" .. L["wizard_level_click"]
    fillChoice(card.action, levelName(level), true, function()
      seat.computer = nextLevel(level)
      lastLevel = seat.computer
    end, tip)
    card.action:Show()
  else
    card.name:SetText(L["wizard_seat_open"])
    card.name:SetTextColor(unpack(Widgets.GREY))
    if Computer.Plays(chosenGame) then
      card.note:Hide()
      fillChoice(card.action, L["wizard_add_computer"], false, function()
        atTable[#atTable + 1] = { computer = lastLevel }
      end, L["wizard_add_computer_tip"])
      card.action:Show()
    else
      card.note:SetText(L[raceable() and "wizard_seat_open_race" or "wizard_seat_open_note"])
    end
  end
end

--- Shows who sits at the table, and how many seats it can have
local function refreshTable()
  local bar = panel.table
  local seats, size = sitting()
  local counts = seatCounts()

  -- How many seats, where there is a choice, over on the right
  local x = widthOf(bar, 800)
  for index = #bar.sizes + 1, #counts do
    bar.sizes[index] = createChoice(bar)
  end
  for index = #bar.sizes, 1, -1 do
    local choice, count = bar.sizes[index], counts[index]
    choice:SetShown(count ~= nil and #counts > 1)
    if count and #counts > 1 then
      fillChoice(choice, tostring(count), count == size, function()
        setSize(count)
      end)
      x = x - choice:GetWidth() - (index < #counts and FILTER_GAP or 0)
      choice:ClearAllPoints()
      choice:SetPoint("TOPLEFT", x, 0)
    end
  end
  bar.seats:SetShown(#counts > 1)
  bar.seats:ClearAllPoints()
  bar.seats:SetPoint("RIGHT", bar, "TOPLEFT", x - 8, -FILTER_HEIGHT / 2)
  -- Who goes first is drawn, unless it is asked for between two
  local race = raceable() and size == 2 and (sendingBest() and "wizard_table_race_best" or "wizard_table_race")
  bar.note:SetText((size > 2 and L["wizard_table_drawn"]) or (race and L[race]) or "")

  local width = widthOf(bar, 800)
  local cardWidth = math.min(SEAT_MOST_WIDTH, math.floor((width - (size - 1) * SEAT_GAP) / size))
  for index = #bar.cards + 1, size do
    bar.cards[index] = createSeatCard(bar)
  end
  for index, card in ipairs(bar.cards) do
    card:SetShown(index <= size)
    if index <= size then
      card:SetWidth(cardWidth)
      card:ClearAllPoints()
      card:SetPoint("TOPLEFT", (index - 1) * (cardWidth + SEAT_GAP), -(FILTER_HEIGHT + 8))
      if index == 1 then
        fillSeatCard(card, nil, nil)
      else
        fillSeatCard(card, seats[index - 1], index - 1)
      end
    end
  end
end

--- Shows the game that was chosen and what its rules are set to
local function refreshRules()
  local rules = panel.rules
  rules.icon:SetTexture(chosenGame.icon or private.ICON)
  rules.name:SetText(chosenGame.name)
  rules.players:SetText(playersText(chosenGame))
  rules.description:SetText(chosenGame.description or "")

  -- Seats are only for the asking between two, a crowd draws them
  -- and where there are no turns there is no going first either
  local seats, size = sitting()
  local names, levels = whoIsAt(seats)
  local seated = not Games.IsSolo(chosenGame) and not chosenGame.together and size == 2
  local lines = {}
  if seated then
    lines[#lines + 1] = seatLine()
  end
  -- What only matters alone isn't set up for a game that can't be played alone
  for _, option in ipairs(Games.OptionsFor(chosenGame, chosenRules, raceable() and 1 or size)) do
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
  -- Under the rules it depends on: what set the best is for these rules alone
  local best, sendable = bestToRace()
  if sendable then
    lines[#lines + 1] = raceLine(best)
  end

  -- Every line of the rules under the one before, as tall as it takes for its choices to fit
  -- across: whatever doesn't fit next to the others goes on underneath them. A line of many
  -- choices that would take more than MOST_CHOICE_ROWS rows of them is a dropdown instead, and so
  -- are more of them, the tallest first, while the rules would be too tall for the panel
  local first, room = OPTION_NAME_WIDTH + FILTER_GAP, RULES_WIDTH - 2 * RULES_INSET
  local inset = (OPTION_ROW_HEIGHT - FILTER_HEIGHT) / 2
  local laid = {}
  for index = 1, math.max(#lines, #rules.rows) do
    local row, line = rules.rows[index], lines[index]
    if line and not row then
      row = createOptionRow(rules)
      rules.rows[index] = row
    end
    if row then
      row:SetShown(line ~= nil)
    end
    if line then
      row.tip = line.tip
      row.name:SetText(line.name)
      local x, y, places = first, inset, {}
      for position = 1, math.max(#line.choices, #row.choices) do
        local choice, spec = row.choices[position], line.choices[position]
        if spec and not choice then
          choice = createChoice(row)
          row.choices[position] = choice
        end
        if spec then
          fillChoice(choice, spec.text, spec.on, spec.pick, spec.tip, spec.disabled)
          if x > first and x + choice:GetWidth() > room then
            x, y = first, y + FILTER_HEIGHT + FILTER_GAP
          end
          places[position] = { x, y }
          x = x + choice:GetWidth() + FILTER_GAP
        end
      end
      local rows = math.floor((y - inset) / (FILTER_HEIGHT + FILTER_GAP) + 0.5) + 1
      laid[index] = { row = row, line = line, places = places, rows = rows, height = y + FILTER_HEIGHT + inset, listed = rows > MOST_CHOICE_ROWS and #line.choices > MOST_BUTTONS }
    end
  end
  local function total()
    local height = OPTIONS_TOP + NOTE_ROOM
    for _, each in ipairs(laid) do
      height = height + (each.listed and OPTION_ROW_HEIGHT or each.height)
    end
    return height
  end
  local panelHeight = rules:GetHeight() or 0
  while panelHeight > 0 and total() > panelHeight do
    local tallest
    for _, each in ipairs(laid) do
      if not each.listed and each.rows > 1 and (not tallest or each.rows > tallest.rows) then
        tallest = each
      end
    end
    if not tallest then
      break
    end
    tallest.listed = true
  end

  local top = OPTIONS_TOP
  for _, each in ipairs(laid) do
    local row, line = each.row, each.line
    for position, choice in ipairs(row.choices) do
      local place = each.places[position]
      choice:SetShown(place ~= nil and not each.listed)
      if place then
        choice:ClearAllPoints()
        choice:SetPoint("TOPLEFT", place[1], -place[2])
      end
    end
    if each.listed and not row.dropdown then
      row.dropdown = Widgets.Dropdown(row, FILTER_HEIGHT)
      row.dropdown:SetPoint("TOPLEFT", first, -inset)
      row.dropdown:SetWidth(room - first)
    end
    if row.dropdown then
      row.dropdown:SetShown(each.listed)
      if each.listed then
        row.dropdown:SetChoices(line.choices, refresh)
      end
    end
    local height = each.listed and OPTION_ROW_HEIGHT or each.height
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", RULES_INSET, -top)
    row:SetPoint("TOPRIGHT", -RULES_INSET, -top)
    row:SetHeight(height)
    top = top + height
  end

  local changed = (seated and chosenSeat ~= nil) or Games.Chosen(chosenGame, chosenRules) ~= nil
  rules.reset:SetShown(changed)
  rules.usual:SetShown(#lines == 0)
  rules.note:SetText(L[Games.Chosen(chosenGame, chosenRules) and "wizard_rules_changed" or "wizard_rules_usual"])
  if raceable() and #names > 0 then
    rules.note:SetText(L["wizard_race_rules"])
  elseif Games.IsSolo(chosenGame) and Games.Chosen(chosenGame, chosenRules) then
    -- Nobody to challenge, nobody to be shown what was changed
    rules.note:SetText(L["wizard_solo_note"])
  elseif #levels > 0 and #names == 0 then
    rules.note:SetText(L["wizard_computer_rules"])
  end
  rules.note:SetShown(#lines > 0)
  rules.note:ClearAllPoints()
  rules.note:SetPoint("TOPLEFT", RULES_INSET, -top - 8)
  rules.note:SetPoint("TOPRIGHT", -RULES_INSET, -top - 8)
end

--- Picks whoever the box over the list stands for
local function pickTyped()
  local _, typed = listing()
  if typed then
    if not seatOf(typed) then
      seatPlayer(typed)
    end
    panel.nameBox:SetText("")
    refresh()
  end
end

--- @param parent Frame
--- @return Frame
local function createOpponentStep(parent)
  local step = CreateFrame("Frame", nil, parent)

  -- Who plays, a card for each seat, across the top
  local bar = CreateFrame("Frame", nil, step)
  bar:SetPoint("TOPLEFT")
  bar:SetPoint("TOPRIGHT")
  bar:SetHeight(TABLE_HEIGHT)
  bar.sizes, bar.cards = {}, {}
  panel.table = bar
  bar.title = Widgets.Label(bar, "GameFontNormal", L["wizard_table"])
  bar.title:SetPoint("LEFT", bar, "TOPLEFT", 2, -FILTER_HEIGHT / 2)
  bar.note = Widgets.Label(bar, "GameFontDisableSmall")
  bar.note:SetPoint("LEFT", bar.title, "RIGHT", 12, 0)
  bar.seats = Widgets.Label(bar, "GameFontHighlightSmall", L["wizard_table_seats"])
  bar.seats:SetTextColor(unpack(Widgets.GREY))

  -- The game, and how it is to be played
  local rules = Widgets.Panel(step)
  rules:SetPoint("TOPRIGHT", 0, -TABLE_HEIGHT)
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
  who:SetPoint("TOPLEFT", 0, -TABLE_HEIGHT)
  who:SetPoint("BOTTOMRIGHT", rules, "BOTTOMLEFT", -CARD_GAP, 0)
  panel.who = who

  panel.whoTitle = Widgets.Label(who, "GameFontNormal")
  panel.whoTitle:SetPoint("TOPLEFT", 10, -10)

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
      -- Between two, typing a name is looking for somebody to sit in the one seat instead
      if mostOpponents() == 1 and (panel.nameBox:GetText() or "") ~= "" then
        atTable = {}
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
  panel.whoTitle:SetText(L[(crowd and "wizard_who_more") or (raceable() and "wizard_who_race") or "wizard_who"])
  panel.whoHint:SetText(L[(crowd and "wizard_by_name_hint_more") or (raceable() and "wizard_race_hint") or "wizard_by_name_hint"])
  panel.nameHint:SetShown((panel.nameBox:GetText() or "") == "")
  -- A link is to a game for two whose other seat is open, or to a race nobody was picked for
  local seats, size = sitting()
  panel.linkButton:SetShown(#seats == 0 and (raceable() or size == 2))

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
  panel.error:SetText(problem and L[problem] or "")
  problem = nil

  panel.linkHint:SetShown(not choosingOpponent)
  if not choosingOpponent then
    panel.step:SetText(L["wizard_step_game"])
    panel.summary:SetText("")
    refreshGames()
    return
  end

  -- A game for one has nobody to pick: its rules have the step to themselves. Unless it can be
  -- raced, when there is somebody to race it against
  local solo = Games.IsSolo(chosenGame) and not raceable()
  panel.who:SetShown(not solo)
  panel.table:SetShown(not solo)
  panel.rules:ClearAllPoints()
  panel.rules:SetPoint(solo and "TOP" or "TOPRIGHT", 0, solo and 0 or -TABLE_HEIGHT)
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

  refreshTable()

  -- Every seat has to be somebody's before the game can begin
  local seats, size = sitting()
  local names, levels = whoIsAt(seats)
  local open = size - 1 - #seats
  panel.sendButton:SetEnabled(open == 0)
  -- Nobody to challenge: the game is the player's own, against the computer or alone
  if #names == 0 and open == 0 then
    panel.sendButton:SetText(L[#levels == 0 and "wizard_play_alone" or "wizard_play"])
  elseif raceable() then
    panel.sendButton:SetText(L["wizard_race"])
  end
  local best = sendingBest() and raceTime(bestToRace())
  local summary
  if open > 0 then
    summary = L[open == 1 and "wizard_seat_open_one" or "wizard_seats_open"]:format(open)
  elseif #levels == 0 and #names == 0 then
    -- Nobody picked, and the game doesn't need anyone
    if best then
      summary = L["wizard_summary_race_best_alone"]:format(chosenGame.name, best)
    else
      summary = L[raceable() and "wizard_summary_race_alone" or "wizard_summary_alone"]:format(chosenGame.name)
    end
  elseif best then
    summary = L["wizard_summary_race_best"]:format(chosenGame.name, best, listed(names))
  elseif raceable() then
    summary = L["wizard_summary_race"]:format(chosenGame.name, listed(names))
  elseif #names == 0 then
    summary = #levels == 1 and L["wizard_summary_computer"]:format(chosenGame.name) or L["wizard_summary_computers"]:format(chosenGame.name, #levels)
  elseif #levels == 1 then
    summary = L["wizard_summary_with_computer"]:format(chosenGame.name, listed(names))
  elseif #levels > 1 then
    summary = L["wizard_summary_with_computers"]:format(chosenGame.name, listed(names), #levels)
  else
    summary = L[(#names > 1 or chosenGame.together) and "with_players" or "wizard_summary"]:format(chosenGame.name, listed(names))
  end
  panel.summary:SetText(summary)
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
  panel.sendButton:SetScript("OnClick", function()
    send()
  end)

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

  -- Where the summary is on the second step: that a game can be linked without going there
  panel.linkHint = Widgets.Label(panel, "GameFontDisableSmall", L["wizard_link_hint"])
  panel.linkHint:SetPoint("BOTTOMRIGHT", -8, 12)
  panel.linkHint:SetJustifyH("RIGHT")

  panel.error = Widgets.Label(panel, "GameFontRedSmall")
  panel.error:SetPoint("BOTTOMRIGHT", panel.sendButton, "TOPRIGHT", 0, 6)
  panel.error:SetJustifyH("RIGHT")
end

--- @return boolean
function Wizard.IsOpen()
  return panel ~= nil and panel:IsShown()
end

--- @param gameId string? A game to begin on, chosen already: where its best is to be sent to somebody, say
--- @param rules table<string, any>? How its rules are set, the way they were last time if left out
function Wizard.Open(gameId, rules)
  chosenGame, chosenGroup, chosenSeat, problem = nil, nil, nil, nil
  atTable, wanted = {}, 2
  chosenGenre, chosenSeats, favouritesOnly = nil, nil, false
  panel.nameBox:SetText("")
  panel.searchBox:SetText("")
  panel:Show()
  refresh()
  panel.games:ScrollTo(1)
  -- So that the day's challenges can say how many have played them
  local today = private.session:Today()
  if private.daily and today then
    private.daily:Ask(today)
  end
  local game = gameId and Games.Get(gameId)
  if game then
    pick(game, rules)
  end
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
