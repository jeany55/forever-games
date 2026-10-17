--------------------------
--  FreeCell
--------------------------
-- The other solitaire everyone knows, for one player with one deck and nothing hidden. All
-- fifty-two cards are dealt face up into eight columns, seven in the first four and six in the
-- rest. Four free cells hold a card each while it is in the way, and the game is won by getting
-- every card home: onto four piles, one for each suit, built up from the ace to the king.
--
-- A column is built down in turn about, red on black and black on red, and any card goes into a
-- column that is empty. Only one card moves at a time, but a run that is built down that way can
-- be carried across in one go when there is room for it to have been moved a card at a time:
-- one card more than there are free cells, doubled for every empty column it isn't going into.
-- A card that is home stays home.
--
-- The deals are the ones Microsoft numbered, from 1 to 32000, dealt the way its game dealt them:
-- "game 11982" is the same deal here as everywhere else, and the one deal of them nobody can win
-- is never dealt. Every other one can be won.
--
-- A card goes home by itself once nothing could still want it in a column: an ace or a two, or a
-- card both piles of the other colour are no more than one short of. Once every column is built
-- down from its foot, whatever the suits, the rest is only work and the game offers to do it. A
-- game with nothing left to move is lost.
--
-- A card is its rank and its suit, "QH" for the queen of hearts, with T for ten. A move is where
-- from and where to: "a" to "d" for a free cell, "1" to "8" for a column, and "f" for home. How
-- many cards go follows when it is more than one: "3a", "a5", "3f", "35", "354". "x" sends home
-- all there is.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Deck = private.Deck

local RANKS, SUITS = Deck.RANKS, Deck.SUITS
local RED = Deck.RED
local COLUMNS = 8
local CELLS = "abcd"
local HOME, FINISH = "f", "x"
-- The deals there are, and the one of them that can't be won
local DEALS, UNWINNABLE = 32000, 11982

--- @class FreeCellState
--- @field deal number Which of Microsoft's deals it is
--- @field cells (string|false)[] What each free cell holds
--- @field homes table<string, string[]> By suit, from the ace up
--- @field columns string[][] From the foot of each column up
--- @field moves number How many the player has made
--- @field outcome { winner: number, detail: string? }?

--- @class FreeCellEvent: MatchEvent
--- @field cards string[]? The cards that went from one pile to another, the one underneath first
--- @field auto string[]? The cards that went home by themselves afterwards, in the order they went
--- @field finished string[]? Everything that was sent home at once, in the order it went
--- @field stuck boolean? Nothing is left to move: the game is lost

-----------------------------
-- Rules
-----------------------------

--- The cards of one of Microsoft's deals, in the order they are dealt: the first eight make the
--- first row across the columns, and so on down. Its game numbered a deck from the ace of clubs,
--- the ace of diamonds, hearts and spades up to the king of spades, and shuffled it with the C
--- library's own random numbers, seeded with the number of the deal
--- @param number number
--- @return string[]
local function dealt(number)
  local deck = {}
  for index = 0, 51 do
    deck[index] = RANKS:sub(math.floor(index / 4) + 1, math.floor(index / 4) + 1) .. ("CDHS"):sub(index % 4 + 1, index % 4 + 1)
  end
  local seed, order, left = number, {}, 52
  for _ = 1, 52 do
    seed = (seed * 214013 + 2531011) % 2147483648
    local pick = math.floor(seed / 65536) % left
    order[#order + 1] = deck[pick]
    -- The last card still in the deck takes the place of the one that was dealt
    deck[pick] = deck[left - 1]
    left = left - 1
  end
  return order
end

--- @param seats number
--- @param random Random
--- @return FreeCellState
local function newState(_, random)
  local number = random:Roll(DEALS - 1)
  if number >= UNWINNABLE then
    number = number + 1
  end
  --- @type FreeCellState
  local state = { deal = number, cells = { false, false, false, false }, homes = {}, columns = {}, moves = 0 }
  for suit in SUITS:gmatch(".") do
    state.homes[suit] = {}
  end
  for column = 1, COLUMNS do
    state.columns[column] = {}
  end
  for index, card in ipairs(dealt(number)) do
    table.insert(state.columns[(index - 1) % COLUMNS + 1], card)
  end
  return state
end

--- Whether a card may go home: it is the next of its suit
--- @param state FreeCellState
--- @param card string
--- @return boolean
local function fitsHome(state, card)
  return Deck.Rank(card) == #state.homes[Deck.Suit(card)] + 1
end

--- Whether a card may go on a column: any card into an empty one, or on a card one higher of
--- the other colour
--- @param cards string[] The column
--- @param card string
--- @return boolean
local function fitsColumn(cards, card)
  local top = cards[#cards]
  return not top or (Deck.Rank(top) == Deck.Rank(card) + 1 and RED[Deck.Suit(top)] ~= RED[Deck.Suit(card)])
end

--- Whether the cards of a column from one of them up are built down in turn about
--- @param cards string[]
--- @param from number
--- @return boolean
local function isRun(cards, from)
  for index = from + 1, #cards do
    if not fitsColumn({ cards[index - 1] }, cards[index]) then
      return false
    end
  end
  return true
end

--- How many cards can go across at once: as many as could be moved a card at a time through the
--- free cells and the empty columns, the column they go to not counted
--- @param state FreeCellState
--- @param to string? The column they go to
--- @return number
local function capacity(state, to)
  local free, empty = 1, 0
  for _, cell in ipairs(state.cells) do
    free = free + (cell and 0 or 1)
  end
  for column, cards in ipairs(state.columns) do
    if #cards == 0 and tostring(column) ~= to then
      empty = empty + 1
    end
  end
  return free * 2 ^ empty
end

--- Whether the rest of the game can be played out without the player: every column is built
--- down from its foot, so the lowest card left is always on top of something, and there is
--- something left to send home
--- @param state FreeCellState
--- @return boolean
local function canFinish(state)
  local left = 0
  for _, cell in ipairs(state.cells) do
    left = left + (cell and 1 or 0)
  end
  for _, cards in ipairs(state.columns) do
    for index = 2, #cards do
      if Deck.Rank(cards[index]) >= Deck.Rank(cards[index - 1]) then
        return false
      end
    end
    left = left + #cards
  end
  return left > 0
end

--- The cards of the pile a move takes from
--- @param state FreeCellState
--- @param pile string
--- @return string[]
local function cardsOf(state, pile)
  local cell = CELLS:find(pile, 1, true)
  if cell then
    return { state.cells[cell] or nil }
  end
  return state.columns[tonumber(pile)]
end

--- @param move string
--- @return string? from, string? to, number? count nil for anything that isn't a move of cards written the one way it is written
local function read(move)
  local from, to, count = move:match("^([a-d1-8])([a-df1-8])(%d*)$")
  if not from or (count ~= "" and (count == "1" or not count:match("^[1-9]%d?$"))) then
    return nil
  end
  return from, to, tonumber(count) or 1
end

--- @param state FreeCellState
--- @param move string
--- @return boolean
local function allowed(state, move)
  if type(move) ~= "string" then
    return false
  elseif move == FINISH then
    return canFinish(state)
  end
  local from, to, count = read(move)
  if not from or from == to then
    return false
  end
  local cards, toColumn = cardsOf(state, from), state.columns[tonumber(to)]
  -- More than one only from a column to a column, and only a run built down
  if count > #cards or (count > 1 and not (state.columns[tonumber(from)] and toColumn)) then
    return false
  end
  local first = #cards - count + 1
  local card = cards[first]
  if to == HOME then
    return fitsHome(state, card)
  elseif not toColumn then
    return not state.cells[CELLS:find(to, 1, true)]
  end
  return isRun(cards, first) and fitsColumn(toColumn, card) and count <= capacity(state, to)
end

--- @param state FreeCellState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  if seat ~= 1 then
    return false, "not_your_turn"
  elseif state.outcome then
    return false, "finished"
  elseif not allowed(state, move) then
    return false, "invalid_move"
  end
  return true
end

--- Every move there is: playing the rest out where that can be done, and every card or run of
--- cards that has somewhere to go. A card isn't moved from one free cell to another, which gets
--- nowhere
--- @param state FreeCellState
--- @return string[]
local function moves(state)
  local list = {}
  if allowed(state, FINISH) then
    list[1] = FINISH
  end
  for from in (CELLS .. "12345678"):gmatch(".") do
    local cards = cardsOf(state, from)
    local most = state.columns[tonumber(from)] and #cards or math.min(1, #cards)
    for to in ("f12345678" .. (CELLS:find(from, 1, true) and "" or CELLS)):gmatch(".") do
      for count = 1, to:match("%d") and most or math.min(1, most) do
        local move = from .. to .. (count > 1 and count or "")
        if allowed(state, move) then
          list[#list + 1] = move
        end
      end
    end
  end
  return list
end

--- Whether a card can go home without anything still wanting it on a column: an ace or a two,
--- or a card the piles of the other colour have both come to within one of
--- @param state FreeCellState
--- @param card string
--- @return boolean
local function safeHome(state, card)
  local rank = Deck.Rank(card)
  if not fitsHome(state, card) then
    return false
  elseif rank <= 2 then
    return true
  end
  for suit in SUITS:gmatch(".") do
    if RED[suit] ~= RED[Deck.Suit(card)] and #state.homes[suit] < rank - 1 then
      return false
    end
  end
  return true
end

--- Sends home everything that can safely go, one card at a time from the free cells and then the
--- columns, until nothing more can
--- @param state FreeCellState
--- @return string[] The cards in the order they went
local function autoHome(state)
  local sent = {}
  local more = true
  while more do
    more = false
    for from in (CELLS .. "12345678"):gmatch(".") do
      local cards = cardsOf(state, from)
      local card = cards[#cards]
      if card and safeHome(state, card) then
        local cell = CELLS:find(from, 1, true)
        if cell then
          state.cells[cell] = false
        else
          table.remove(cards)
        end
        table.insert(state.homes[Deck.Suit(card)], card)
        sent[#sent + 1] = card
        more = true
      end
    end
  end
  return sent
end

--- Sends everything home that isn't, lowest first: with every column built down from its foot
--- the lowest card left is always on top of one, or in a free cell
--- @param state FreeCellState
--- @return string[] The cards in the order they went
local function finish(state)
  local sent = {}
  for rank = 1, #RANKS do
    for suit in SUITS:gmatch(".") do
      if #state.homes[suit] < rank then
        local card = RANKS:sub(rank, rank) .. suit
        state.homes[suit][rank] = card
        sent[#sent + 1] = card
      end
    end
  end
  state.cells = { false, false, false, false }
  for column = 1, COLUMNS do
    state.columns[column] = {}
  end
  return sent
end

--- @param state FreeCellState
--- @return number How many cards are home
local function homeCount(state)
  local home = 0
  for _, pile in pairs(state.homes) do
    home = home + #pile
  end
  return home
end

--- @param state FreeCellState
--- @param seat number
--- @param move string
--- @return FreeCellEvent
local function apply(state, _, move)
  state.moves = state.moves + 1
  if move == FINISH then
    local sent = finish(state)
    state.outcome = { winner = 1 }
    return { finished = sent }
  end

  local from, to, count = read(move)
  local moved = {}
  local cell = CELLS:find(from, 1, true)
  if cell then
    moved[1] = state.cells[cell]
    state.cells[cell] = false
  else
    local cards = state.columns[tonumber(from)]
    for index = #cards - count + 1, #cards do
      moved[#moved + 1] = cards[index]
    end
    for _ = 1, count do
      table.remove(cards)
    end
  end
  if to == HOME then
    table.insert(state.homes[Deck.Suit(moved[1])], moved[1])
  elseif state.columns[tonumber(to)] then
    for _, card in ipairs(moved) do
      table.insert(state.columns[tonumber(to)], card)
    end
  else
    state.cells[CELLS:find(to, 1, true)] = moved[1]
  end

  --- @type FreeCellEvent
  local event = { cards = moved }
  local auto = autoHome(state)
  event.auto = #auto > 0 and auto or nil
  if homeCount(state) == #RANKS * #SUITS then
    state.outcome = { winner = 1 }
  elseif #moves(state) == 0 then
    state.outcome = { winner = 0, detail = "freecell_stuck" }
    event.stuck = true
  end
  return event
end

-----------------------------
-- View
-----------------------------
-- A card table (GUI/CardTable.lua): the four free cells in one corner, the four piles the cards
-- go home on in the other, and the eight columns under them. A pile is called what moves call
-- it, a home by its suit.
--
-- A card is dragged to where it should go, with whatever lies on it, or just clicked: it then
-- goes home if it can, to the first column that will have it if not, and into a free cell if
-- there is nowhere else. A right click only ever sends it home. The table shows whatever that
-- makes of the position, and a move taken back the same way.

local FELT = { 0.05, 0.2, 0.22, 0.85 }
-- A card is never drawn wider than this, however big the window
local CARD_MAX = 110
-- How many card heights the table needs from top to bottom to be played on: the row along the
-- top, and columns of a dozen cards or so
local TABLE_HEIGHTS = 3.8
-- The line along the bottom that says how the game is going
local HUD_HEIGHT = 26
-- How the cards of a column lie on each other, as fractions of a card (GUI/CardTable.lua)
local COLUMN_FAN = { 0, 0.25 }
local FINISH_WIDTH, FINISH_HEIGHT = 110, 22
local PLAY_SOUND, DEAL_SOUND, WIN_SOUND, STUCK_SOUND = "cardPlace", "cardSlide", "UI_EPICLOOT_TOAST", "IG_QUEST_FAILED"
-- Seconds from one card to the next when they go home one after the other, and how long after
-- the last of them has set out the cards start leaping off the table
local HOME_GAP, WIN_AFTER = 0.07, 0.6
-- Where the cards are dealt from: a pile under the bottom edge, out of sight
local DECK = "deck"
-- How long what the game says about a move stays
local SAYS_FOR = 3
-- Matches the player has watched being dealt, by id: once is enough
local watched = {}

--- @class FreeCellView: GameViewObject
--- @field stage Frame
--- @field felt CardTable
--- @field tally FontString How the game is going
--- @field says FontString Why a move can't be made
--- @field finish Button Plays the rest of the game out
--- @field view GameView? What was last asked for
local View = {}
View.__index = View

--- The pile a card table calls a place by: a home by its suit
--- @param pile string
--- @return boolean
local function isHome(pile)
  return #pile == 1 and SUITS:find(pile, 1, true) ~= nil
end

--- The move that takes the cards from a place in one pile to another pile
--- @param state FreeCellState
--- @param from string
--- @param index number Where in the pile the lowest of them lies
--- @param to string
--- @return string? nil when no move is written that way
local function moveFor(state, from, index, to)
  if isHome(from) or from == DECK or to == DECK then
    return nil
  end
  local count = #cardsOf(state, from) - index + 1
  return from .. (isHome(to) and HOME or to) .. (count > 1 and count or "")
end

--- What clicking a card does: where it would rather go. Home, then a column with something in
--- it, then an empty column, then a free cell
--- @param state FreeCellState
--- @param from string
--- @param index number
--- @param homeOnly boolean? Only if it can go home
--- @return string? move
local function bestMove(state, from, index, homeOnly)
  local home = moveFor(state, from, index, HOME)
  if allowed(state, home) then
    return home
  elseif homeOnly then
    return nil
  end
  local spare = nil
  for column = 1, COLUMNS do
    local move = moveFor(state, from, index, tostring(column))
    if allowed(state, move) then
      if #state.columns[column] > 0 then
        return move
      end
      -- An empty column, though not for the whole of a column that is somewhere to itself already
      if not (state.columns[tonumber(from)] and index == 1) then
        spare = spare or move
      end
    end
  end
  if spare then
    return spare
  end
  if not CELLS:find(from, 1, true) then
    for cell = 1, #CELLS do
      local move = moveFor(state, from, index, CELLS:sub(cell, cell))
      if allowed(state, move) then
        return move
      end
    end
  end
  return nil
end

--- @param stage Frame
--- @return FreeCellView
local function createView(stage)
  --- @type FreeCellView
  local self = setmetatable({ stage = stage }, View)
  local Widgets = private.Widgets

  local felt = stage:CreateTexture(nil, "BACKGROUND")
  felt:SetAllPoints()
  private.Felt.Paint(felt, FELT)

  self.felt = private.CardTable.New(stage)
  self.felt.canLift = function(pile, index)
    local view = self.view
    if not view.canMove or isHome(pile) or pile == DECK then
      return false
    end
    -- A run built down in a column, with all that lies on it, or what is in a free cell
    return isRun(cardsOf(view.state, pile), index)
  end
  self.felt.canDrop = function(from, index, to)
    local move = moveFor(self.view.state, from, index, to)
    return move ~= nil and allowed(self.view.state, move)
  end
  self.felt.onDrop = function(from, index, to)
    self.view.submit(moveFor(self.view.state, from, index, to))
  end
  self.felt.onClick = function(pile, index)
    self:click(pile, index)
  end
  self.felt.onRightClick = function(pile, index)
    self:click(pile, index, true)
  end

  self.tally = Widgets.Label(stage, "GameFontHighlight")
  -- The clock goes on between one update and the next
  self.ticker = CreateFrame("Frame", nil, stage)
  self.ticker:SetScript("OnUpdate", function()
    self:tick()
  end)
  self.says = Widgets.Label(stage, "GameFontHighlight")
  self.says:SetJustifyH("CENTER")
  self.animator = Widgets.Animator(self.ticker)
  self.finish = Widgets.Button(stage, L["freecell_finish"], FINISH_WIDTH, FINISH_HEIGHT)
  self.finish:SetScript("OnClick", function()
    self.view.submit(FINISH)
  end)
  self.effects = private.Effects.New(stage)
  return self
end

--- Says something about what the player just tried, for a while
--- @param text string
function View:say(text)
  self.animator:Stop()
  self.says:SetText(text)
  self.animator:Play(SAYS_FOR, function() end, {
    onDone = function()
      self.says:SetText("")
    end,
  })
end

--- A card was clicked, or the place of a pile that has none
--- @param pile string
--- @param index number?
--- @param homeOnly boolean? Send it home or leave it
function View:click(pile, index, homeOnly)
  local view = self.view
  --- @type FreeCellState
  local state = view.state
  if not view.canMove or not index or not self.felt.canLift(pile, index) then
    return
  end
  local move = bestMove(state, pile, index, homeOnly)
  if move then
    view.submit(move)
    return
  end
  -- Nowhere to go. A run that would have somewhere if there were room enough says so
  local count = #cardsOf(state, pile) - index + 1
  if count > 1 and not homeOnly then
    local most = capacity(state)
    for column = 1, COLUMNS do
      local cards = state.columns[column]
      if #cards > 0 and fitsColumn(cards, cardsOf(state, pile)[index]) and count > most then
        self:say(L["freecell_too_many"]:format(count, most))
      end
    end
  end
  self.felt:Refuse(cardsOf(state, pile)[index])
end

--- @param width number
--- @param height number
function View:Layout(width, height)
  local Cards = private.Cards
  local gap = math.max(4, math.floor(width * 0.012))
  -- As wide as eight of them fit side by side, and no taller than leaves the columns room
  local cardWidth = math.min(CARD_MAX, math.floor((width - gap * (COLUMNS + 1)) / COLUMNS))
  local cardHeight = math.floor(cardWidth / Cards.RATIO)
  local tallest = math.floor((height - HUD_HEIGHT - gap * 4) / TABLE_HEIGHTS)
  if cardHeight > tallest then
    cardWidth, cardHeight = math.floor(tallest * Cards.RATIO), tallest
  end

  local left = math.floor((width - cardWidth * COLUMNS - gap * (COLUMNS - 1)) / 2)
  local function across(column)
    return left + (column - 1) * (cardWidth + gap)
  end
  local top = gap
  local columnsTop = top + cardHeight + gap * 2

  local felt = self.felt
  felt:SetSize(width, height, cardWidth, cardHeight)
  felt:Pile(DECK, { x = math.floor((width - cardWidth) / 2), y = height + cardHeight })
  for cell = 1, #CELLS do
    felt:Pile(CELLS:sub(cell, cell), { x = across(cell), y = top })
  end
  for index = 1, #SUITS do
    local suit = SUITS:sub(index, index)
    felt:Pile(suit, { x = across(COLUMNS - #SUITS + index), y = top, mark = Cards.Suit(suit) })
  end
  for column = 1, COLUMNS do
    felt:Pile(tostring(column), {
      x = across(column),
      y = columnsTop,
      fan = COLUMN_FAN,
      room = height - HUD_HEIGHT - gap - columnsTop - cardHeight,
    })
  end

  self.tally:ClearAllPoints()
  self.tally:SetPoint("BOTTOMLEFT", self.stage, "BOTTOMLEFT", left, (HUD_HEIGHT - 12) / 2)
  self.says:ClearAllPoints()
  self.says:SetPoint("BOTTOM", self.stage, "BOTTOM", 0, (HUD_HEIGHT - 12) / 2 + HUD_HEIGHT)
  self.finish:ClearAllPoints()
  self.finish:SetPoint("BOTTOMRIGHT", self.stage, "BOTTOMRIGHT", -left, (HUD_HEIGHT - FINISH_HEIGHT) / 2)

  if self.view then
    self:draw({ instant = true })
  end
end

--- What lies in which pile of the table, see CardTable.Set
--- @param state FreeCellState
--- @return table<string, CardTableCards>
local function piles(state)
  local lying = {}
  for cell = 1, #CELLS do
    lying[CELLS:sub(cell, cell)] = { cards = { state.cells[cell] or nil } }
  end
  for suit, cards in pairs(state.homes) do
    lying[suit] = { cards = cards }
  end
  for index, cards in ipairs(state.columns) do
    lying[tostring(index)] = { cards = cards }
  end
  return lying
end

--- Shows what the clock says by now, with the rest of the line along the bottom
function View:tick()
  local view = self.view
  if not view then
    return
  end
  local seconds = math.floor(view.clock())
  if seconds ~= self.seconds then
    self.seconds = seconds
    self:writeTally()
  end
end

function View:writeTally()
  local view, Widgets = self.view, private.Widgets
  --- @type FreeCellState
  local state = view.state
  local best = view.best("time")
  local text = L["freecell_tally"]:format(state.deal, state.moves, Widgets.Time(self.seconds or 0))
  if best then
    text = text .. "   " .. L["freecell_tally_best"]:format(Widgets.Time(best))
  end
  self.tally:SetText(text)
end

--- Puts the position on the table
--- @param how table? How what changed gets there, see CardTable.Set
function View:draw(how)
  local view = self.view
  self.felt:Set(piles(view.state), how)
  self.seconds = math.floor(view.clock())
  self:writeTally()
  self.finish:SetShown(view.canMove and canFinish(view.state))
end

--- Deals the game out from under the table, a card to each column in turn
function View:deal()
  --- @type FreeCellState
  local state = self.view.state
  local order = dealt(state.deal)
  -- The first card to be dealt is on top
  local deck = {}
  for index = #order, 1, -1 do
    deck[#deck + 1] = order[index]
  end
  self.felt:Set({ [DECK] = { cards = deck, down = #deck } }, { instant = true })
  self:draw({ sequence = order, gap = 0.025, sound = DEAL_SOUND })
end

--- Writes across the table how the game ended
--- @param delay number? Seconds to wait first
--- @param instant boolean? For a game that was over before it was looked at
function View:verdict(delay, instant)
  local view, Widgets = self.view, private.Widgets
  --- @type FreeCellState
  local state = view.state
  if state.outcome.winner == 1 then
    local time = Widgets.Time(view.clock())
    local _, mine = view.best("time")
    local subtitle = L["freecell_solved_in"]:format(state.deal, time)
    if mine then
      subtitle = subtitle .. " " .. L["new_best"]
    end
    self.effects:Banner(L["freecell_won"], subtitle, { color = Widgets.GOLD, delay = delay, instant = instant })
  else
    self.effects:Banner(L["freecell_stuck"], L["freecell_stuck_detail"]:format(homeCount(state)), { color = Widgets.RED, delay = delay, instant = instant })
  end
end

--- The game was just won: the cards leap off the piles they went home on, kings first
--- @param after number Seconds until the last card has set out for home
function View:celebrate(after)
  --- @type FreeCellState
  local state = self.view.state
  local order = {}
  for rank = #RANKS, 1, -1 do
    for suit in SUITS:gmatch(".") do
      order[#order + 1] = state.homes[suit][rank]
    end
  end
  self.felt:Fountain(order, after + WIN_AFTER)
  self:verdict(after + WIN_AFTER)
  private.Widgets.PlaySound(WIN_SOUND)
end

--- @param view GameView
function View:Update(view)
  local before = self.view
  self.view = view
  --- @type FreeCellState
  local state = view.state
  local sameGame = before ~= nil and before.match.id == view.match.id
  --- @type FreeCellEvent?
  local event = view.played

  if not sameGame then
    self.effects:Clear()
    self.says:SetText("")
    local opening = view.live and view.match.status == "active" and view.ply == 0
    if opening and not watched[view.match.id] then
      watched[view.match.id] = true
      self:deal()
    else
      self:draw({ instant = true })
    end
    if state.outcome then
      self:verdict(nil, true)
    end
  elseif not view.changed then
    self:draw()
  elseif event and event.finished then
    self:draw({ sequence = event.finished, gap = HOME_GAP, sound = PLAY_SOUND })
    self:celebrate(#event.finished * HOME_GAP)
  else
    self.effects:Clear()
    -- What went by itself goes after the move that let it
    local sequence = nil
    if event and event.auto then
      sequence = {}
      for _, list in ipairs({ event.cards, event.auto }) do
        for _, card in ipairs(list) do
          sequence[#sequence + 1] = card
        end
      end
    end
    self:draw({ sequence = sequence, gap = HOME_GAP, sound = PLAY_SOUND })
    if event and state.outcome and state.outcome.winner == 1 then
      self:celebrate(sequence and #sequence * HOME_GAP or 0)
    elseif event and event.stuck then
      self:verdict(0.4)
      private.Widgets.PlaySound(STUCK_SOUND)
    end
  end
end

private.FreeCell = { Dealt = dealt, Capacity = capacity, CanFinish = canFinish }

private.Games.Register({
  id = "freecell",
  name = L["game_freecell"],
  description = L["game_freecell_description"],
  genre = "cards",
  icon = "Interface\\AddOns\\ForeverGames\\Images\\Icons\\freecell",
  version = 1,
  seats = 1,
  undo = true,
  howto = {
    { heading = L["howto_goal"], text = L["freecell_howto_goal"] },
    { heading = L["freecell_howto_cells"], text = L["freecell_howto_cells_text"] },
    { heading = L["freecell_howto_columns"], text = L["freecell_howto_columns_text"] },
    { heading = L["howto_controls"], text = L["freecell_howto_controls"] },
    { heading = L["howto_end"], text = L["freecell_howto_end"] },
  },
  clock = "move",
  newState = newState,
  turn = function()
    return 1
  end,
  validate = validate,
  apply = apply,
  moves = moves,
  result = function(state)
    return state.outcome
  end,
  progress = function(state)
    return L["freecell_progress"]:format(state.deal, homeCount(state), state.moves)
  end,
  record = function(state, seconds)
    -- Only a game that was won has a time worth keeping
    if state.outcome and state.outcome.winner == 1 then
      return { { key = "time", value = seconds, lower = true }, { key = "moves", value = state.moves, lower = true } }
    end
    return nil
  end,
  -- The day's deal is played for time, and only a game that was won has one
  daily = {
    score = function(state, seconds)
      return state.outcome and state.outcome.winner == 1 and seconds or nil
    end,
    lower = true,
    time = true,
  },
  createView = createView,
})
