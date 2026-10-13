--------------------------
--  Solitaire
--------------------------
-- Klondike, the game most people mean by solitaire, for one player with one deck. Twenty-eight
-- cards are dealt into seven columns, one in the first and seven in the last, only the top one
-- of each face up. The rest are the stock. The game is won by getting every card home: onto
-- four piles, one for each suit, built up from the ace to the king.
--
-- A column is built down in turn about, red on black and black on red, and the cards built on
-- each other can be moved together. Only a king, with whatever lies on it, goes into a column
-- that is empty. The card left on top of a column when one is taken away is turned over. The
-- stock is turned a card at a time onto the waste, whose top card can be played, and when it
-- runs out the waste is turned over to go through again, as often as it takes. A card that is
-- home can be brought back to a column.
--
-- Once nothing lies face down in the columns the rest is only work, and the game offers to do
-- it: with the stock turned a card at a time every card left can be got at.
--
-- Points are the usual ones: ten for a card sent home, five for one played from the waste to a
-- column and for one turned over, fifteen off for a card brought back from home and a hundred
-- off for going through the stock again, though never to below nothing.
--
-- A card is its rank and its suit, "QH" for the queen of hearts, with T for ten. A move is where
-- from and where to: "w" for the waste, "1" to "7" for a column and the letter of a suit for
-- the pile it is home on, to a column or "f" for home. From a column, how many cards go follows
-- when it is more than one: "w3", "5f", "25", "253", "H4". "d" turns a card of the stock or the
-- waste back over, "a" sends home all there is.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L

local RANKS, SUITS = "A23456789TJQK", "SHDC"
local RED = { H = true, D = true }
local COLUMNS = 7
local DRAW, FINISH = "d", "a"
local STOCK, WASTE, HOME = "s", "w", "f"
local POINTS = { home = 10, played = 5, turned = 5, back = -15, again = -100 }

--- @class SolitaireState
--- @field stock string[] Face down, the next card to be turned is the last
--- @field waste string[] Face up, the card on top is the last
--- @field homes table<string, string[]> By suit, from the ace up
--- @field columns { cards: string[], down: number }[] From the bottom up, and how many of them lie face down
--- @field score number
--- @field moves number How many the player has made
--- @field outcome { winner: number }?

--- @class SolitaireEvent: MatchEvent
--- @field drew string? The card of the stock that was turned
--- @field again boolean? The waste was turned over to be the stock again
--- @field cards string[]? The cards that went from one pile to another, the one underneath first
--- @field turned string? The card of a column that was turned over because of it
--- @field finished string[]? Everything that was sent home at once, in the order it went

-----------------------------
-- Rules
-----------------------------

--- @param card string
--- @return number rank From 1 for the ace to 13 for the king
--- @return string suit
local function parts(card)
  return RANKS:find(card:sub(1, 1), 1, true), card:sub(2, 2)
end

--- @param seats number
--- @param random Random
--- @return SolitaireState
local function newState(_, random)
  local deck = {}
  for suit in SUITS:gmatch(".") do
    for rank in RANKS:gmatch(".") do
      deck[#deck + 1] = rank .. suit
    end
  end
  random:Shuffle(deck)

  --- @type SolitaireState
  local state = { stock = deck, waste = {}, homes = {}, columns = {}, score = 0, moves = 0 }
  for suit in SUITS:gmatch(".") do
    state.homes[suit] = {}
  end
  for column = 1, COLUMNS do
    state.columns[column] = { cards = {}, down = column - 1 }
  end
  -- A card to each column in turn, a column fewer every time round
  for row = 1, COLUMNS do
    for column = row, COLUMNS do
      table.insert(state.columns[column].cards, table.remove(deck))
    end
  end
  return state
end

--- Whether a card may go home: it is the next of its suit
--- @param state SolitaireState
--- @param card string
--- @return boolean
local function fitsHome(state, card)
  local rank, suit = parts(card)
  return rank == #state.homes[suit] + 1
end

--- Whether a card may go on a column: a king on an empty one, or on a card one higher of the
--- other colour
--- @param column { cards: string[], down: number }
--- @param card string
--- @return boolean
local function fitsColumn(column, card)
  local rank, suit = parts(card)
  local top = column.cards[#column.cards]
  if not top then
    return rank == #RANKS
  end
  local topRank, topSuit = parts(top)
  return topRank == rank + 1 and RED[topSuit] ~= RED[suit]
end

--- Whether the rest of the game can be played out without the player: nothing lies face down
--- in the columns any more, and there is something left to send home
--- @param state SolitaireState
--- @return boolean
local function canFinish(state)
  local left = #state.stock + #state.waste
  for _, column in ipairs(state.columns) do
    if column.down > 0 then
      return false
    end
    left = left + #column.cards
  end
  return left > 0
end

--- The cards of the pile a move names
--- @param state SolitaireState
--- @param pile string
--- @return string[]
local function cardsOf(state, pile)
  if pile == WASTE then
    return state.waste
  end
  return state.homes[pile] or state.columns[tonumber(pile)].cards
end

--- @param move string
--- @return string? from, string? to, number? count nil for anything that isn't a move of cards written the one way it is written
local function read(move)
  local from, to, count = move:match("^([w1-7SHDC])([f1-7])(%d*)$")
  if not from or (count ~= "" and (count == "1" or not count:match("^[1-9]%d?$"))) then
    return nil
  end
  return from, to, tonumber(count) or 1
end

--- @param state SolitaireState
--- @param move string
--- @return boolean
local function allowed(state, move)
  if move == DRAW then
    return #state.stock + #state.waste > 0
  elseif move == FINISH then
    return canFinish(state)
  end

  local from, to, count = read(move)
  if not from or from == to then
    return false
  end
  local cards, column = cardsOf(state, from), state.columns[tonumber(from)]
  -- Only the cards of a column that lie face up move, and only there more than one at a time
  if count > #cards - (column and column.down or 0) or (count > 1 and not column) then
    return false
  end
  local card = cards[#cards - count + 1]
  if to == HOME then
    return count == 1 and not state.homes[from] and fitsHome(state, card)
  end
  return fitsColumn(state.columns[tonumber(to)], card)
end

--- @param state SolitaireState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  if seat ~= 1 then
    return false, "not_your_turn"
  elseif not allowed(state, move) then
    return false, "invalid_move"
  end
  return true
end

--- @param state SolitaireState
--- @param points number
local function score(state, points)
  state.score = math.max(0, state.score + points)
end

--- Sends everything home that isn't, lowest first: with nothing face down in the columns the
--- next card of a suit never lies under a higher one
--- @param state SolitaireState
--- @return string[] The cards in the order they went
local function finish(state)
  local sent = {}
  for rank = 1, #RANKS do
    for suit in SUITS:gmatch(".") do
      if #state.homes[suit] < rank then
        local card = RANKS:sub(rank, rank) .. suit
        state.homes[suit][rank] = card
        sent[#sent + 1] = card
        score(state, POINTS.home)
      end
    end
  end
  state.stock, state.waste = {}, {}
  for _, column in ipairs(state.columns) do
    column.cards = {}
  end
  return sent
end

--- @param state SolitaireState
--- @param seat number
--- @param move string
--- @return SolitaireEvent
local function apply(state, _, move)
  state.moves = state.moves + 1
  if move == FINISH then
    local sent = finish(state)
    state.outcome = { winner = 1 }
    return { finished = sent }
  elseif move == DRAW then
    if #state.stock > 0 then
      local card = table.remove(state.stock)
      state.waste[#state.waste + 1] = card
      return { drew = card }
    end
    -- Turned over as it lies: the card that was turned first is the first to be turned again
    while #state.waste > 0 do
      state.stock[#state.stock + 1] = table.remove(state.waste)
    end
    score(state, POINTS.again)
    return { again = true }
  end

  local from, to, count = read(move)
  local cards, column = cardsOf(state, from), state.columns[tonumber(from)]
  local moved = {}
  for index = #cards - count + 1, #cards do
    moved[#moved + 1] = cards[index]
  end
  for _ = 1, count do
    table.remove(cards)
  end
  local onto = to == HOME and state.homes[select(2, parts(moved[1]))] or state.columns[tonumber(to)].cards
  for _, card in ipairs(moved) do
    onto[#onto + 1] = card
  end

  if to == HOME then
    score(state, POINTS.home)
  elseif from == WASTE then
    score(state, POINTS.played)
  elseif state.homes[from] then
    score(state, POINTS.back)
  end
  --- @type SolitaireEvent
  local event = { cards = moved }
  if column and #column.cards > 0 and column.down == #column.cards then
    -- The card that was under them is turned over
    column.down = column.down - 1
    event.turned = column.cards[#column.cards]
    score(state, POINTS.turned)
  end

  local home = 0
  for _, pile in pairs(state.homes) do
    home = home + #pile
  end
  if home == #RANKS * #SUITS then
    state.outcome = { winner = 1 }
  end
  return event
end

-----------------------------
-- View
-----------------------------
-- A card table (GUI/CardTable.lua): the stock and the waste in one corner, the four piles the
-- cards go home on in the other, and the seven columns under them. A pile is called what moves
-- call it, and "s" for the stock.
--
-- A card is dragged to where it should go, with whatever lies on it, or just clicked: it then
-- goes home if it can and to the first column that will have it if not. A right click only
-- ever sends it home. Clicking the stock turns a card, and turns the waste back over when
-- there is none. The table shows whatever that makes of the position, and a move taken back
-- the same way.

local FELT = { 0.06, 0.24, 0.15, 0.85 }
-- A card is never drawn wider than this, however big the window
local CARD_MAX = 120
-- How many card heights the table needs from top to bottom to be played on: the row along the
-- top, and columns with a few cards in them
local TABLE_HEIGHTS = 3.4
-- The line along the bottom that says how the game is going
local HUD_HEIGHT = 26
-- How the cards of a pile lie on each other, as fractions of a card (GUI/CardTable.lua). A stock
-- is a little thicker for every card in it, the waste shows the last three that were turned
local STOCK_FAN, WASTE_FAN, WASTE_SPREAD = { 0.0025, -0.0025 }, { 0.2, 0 }, 3
local COLUMN_FAN, COLUMN_DOWN_FAN = { 0, 0.27 }, { 0, 0.12 }
local FINISH_WIDTH, FINISH_HEIGHT = 110, 22
local PLAY_SOUND, DRAW_SOUND, WIN_SOUND = "cardPlace", "cardSlide", "UI_EPICLOOT_TOAST"
-- Seconds from one card to the next when the game is played out, and how long after the last
-- of them has set out the cards start leaping off the table
local FINISH_GAP, WIN_AFTER = 0.07, 0.6
-- Matches the player has watched being dealt, by id: once is enough
local dealt = {}

--- @class SolitaireView: GameViewObject
--- @field stage Frame
--- @field felt CardTable
--- @field tally FontString How the game is going
--- @field finish Button Plays the rest of the game out
--- @field view GameView? What was last asked for
local View = {}
View.__index = View

--- The move that takes the cards from a place in one pile to another pile
--- @param state SolitaireState
--- @param from string
--- @param index number Where in the pile the lowest of them lies
--- @param to string
--- @return string? nil when no move is written that way
local function moveFor(state, from, index, to)
  if from == STOCK or to == STOCK or to == WASTE then
    return nil
  end
  local count = #cardsOf(state, from) - index + 1
  return from .. (state.homes[to] and HOME or to) .. (count > 1 and count or "")
end

--- What clicking a card does: where it would rather go
--- @param state SolitaireState
--- @param from string
--- @param index number
--- @param homeOnly boolean? Only if it can go home
--- @return string? move
local function bestMove(state, from, index, homeOnly)
  local home = moveFor(state, from, index, HOME)
  if home and allowed(state, home) then
    return home
  elseif homeOnly or state.homes[from] then
    -- A card that is home stays there unless it is carried off
    return nil
  end
  local column = state.columns[tonumber(from)]
  local spare = nil
  for target = 1, COLUMNS do
    local move = moveFor(state, from, index, tostring(target))
    if move and allowed(state, move) then
      if #state.columns[target].cards > 0 then
        return move
      end
      -- An empty column is somewhere to go, but not for a king that has one to itself already
      if not (column and index == 1) then
        spare = spare or move
      end
    end
  end
  return spare
end

--- @param stage Frame
--- @return SolitaireView
local function createView(stage)
  --- @type SolitaireView
  local self = setmetatable({ stage = stage }, View)
  local Widgets = private.Widgets

  local felt = stage:CreateTexture(nil, "BACKGROUND")
  felt:SetAllPoints()
  felt:SetColorTexture(unpack(FELT))

  self.felt = private.CardTable.New(stage)
  self.felt.canLift = function(pile, index)
    local view = self.view
    if not view.canMove or pile == STOCK then
      return false
    end
    local column = view.state.columns[tonumber(pile)]
    -- Whatever is face up in a column, with all that lies on it, and the top card anywhere else
    return index > (column and column.down or #cardsOf(view.state, pile) - 1)
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
  self.finish = Widgets.Button(stage, L["solitaire_finish"], FINISH_WIDTH, FINISH_HEIGHT)
  self.finish:SetScript("OnClick", function()
    self.view.submit(FINISH)
  end)
  return self
end

--- A card was clicked, or the place of a pile that has none
--- @param pile string
--- @param index number?
--- @param homeOnly boolean? Send it home or leave it
function View:click(pile, index, homeOnly)
  local view = self.view
  --- @type SolitaireState
  local state = view.state
  if not view.canMove then
    return
  end
  if pile == STOCK then
    if not homeOnly and allowed(state, DRAW) then
      view.submit(DRAW)
    end
    return
  end
  if not index or not self.felt.canLift(pile, index) then
    return
  end
  local move = bestMove(state, pile, index, homeOnly)
  if move then
    view.submit(move)
  else
    -- Nowhere to go
    self.felt:Refuse(cardsOf(state, pile)[index])
  end
end

--- @param width number
--- @param height number
function View:Layout(width, height)
  local Cards = private.Cards
  local gap = math.max(4, math.floor(width * 0.014))
  -- As wide as seven of them fit side by side, and no taller than leaves the columns room
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
  -- A little room over the top row for the stock to be as thick as it gets
  local top = gap + math.ceil(cardHeight * 0.06)
  local columnsTop = top + cardHeight + gap * 2

  local felt = self.felt
  felt:SetSize(width, height, cardWidth, cardHeight)
  felt:Pile(STOCK, { x = across(1), y = top, fan = STOCK_FAN, downFan = STOCK_FAN })
  felt:Pile(WASTE, { x = across(2), y = top, fan = WASTE_FAN, spread = WASTE_SPREAD })
  for index = 1, #SUITS do
    local suit = SUITS:sub(index, index)
    felt:Pile(suit, { x = across(COLUMNS - #SUITS + index), y = top, mark = Cards.Suit(suit) })
  end
  for column = 1, COLUMNS do
    felt:Pile(tostring(column), {
      x = across(column),
      y = columnsTop,
      fan = COLUMN_FAN,
      downFan = COLUMN_DOWN_FAN,
      room = height - HUD_HEIGHT - gap - columnsTop - cardHeight,
    })
  end

  self.tally:ClearAllPoints()
  self.tally:SetPoint("BOTTOMLEFT", self.stage, "BOTTOMLEFT", left, (HUD_HEIGHT - 12) / 2)
  self.finish:ClearAllPoints()
  self.finish:SetPoint("BOTTOMRIGHT", self.stage, "BOTTOMRIGHT", -left, (HUD_HEIGHT - FINISH_HEIGHT) / 2)

  if self.view then
    self:draw({ instant = true })
  end
end

--- What lies in which pile of the table, see CardTable.Set
--- @param state SolitaireState
--- @return table<string, CardTableCards>
local function piles(state)
  local lying = {
    [STOCK] = { cards = state.stock, down = #state.stock },
    [WASTE] = { cards = state.waste },
  }
  for suit, cards in pairs(state.homes) do
    lying[suit] = { cards = cards }
  end
  for index, column in ipairs(state.columns) do
    lying[tostring(index)] = { cards = column.cards, down = column.down }
  end
  return lying
end

--- Puts the position on the table
--- @param how table? How what changed gets there, see CardTable.Set
function View:draw(how)
  local view = self.view
  --- @type SolitaireState
  local state = view.state
  local canDraw = view.canMove and #state.stock + #state.waste > 0
  -- An empty stock says whether there is anything to turn back over
  self.felt:Pile(STOCK, { press = canDraw, mark = canDraw and private.Cards.AGAIN or false })
  self.felt:Set(piles(state), how)
  self.tally:SetText(L["solitaire_tally"]:format(state.score, state.moves))
  self.finish:SetShown(view.canMove and canFinish(state))
end

--- Deals the game out: everything starts in the stock, and the columns are dealt from it a
--- card at a time, the last of each turned up as it lands
function View:deal()
  --- @type SolitaireState
  local state = self.view.state
  local order = {}
  for row = 1, COLUMNS do
    for column = row, COLUMNS do
      order[#order + 1] = state.columns[column].cards[row]
    end
  end
  -- The first card to be dealt is on top
  local deck = { unpack(state.stock) }
  for index = #order, 1, -1 do
    deck[#deck + 1] = order[index]
  end
  self.felt:Set({ [STOCK] = { cards = deck, down = #deck } }, { instant = true })
  self:draw({ sequence = order, sound = DRAW_SOUND })
end

--- The game was just won: the cards leap off the piles they went home on, kings first
--- @param after number Seconds until the last card has set out for home
function View:celebrate(after)
  --- @type SolitaireState
  local state = self.view.state
  local order = {}
  for rank = #RANKS, 1, -1 do
    for suit in SUITS:gmatch(".") do
      order[#order + 1] = state.homes[suit][rank]
    end
  end
  self.felt:Fountain(order, after + WIN_AFTER)
  private.Widgets.PlaySound(WIN_SOUND)
end

--- @param view GameView
function View:Update(view)
  local before = self.view
  self.view = view
  --- @type SolitaireState
  local state = view.state
  local sameGame = before ~= nil and before.match.id == view.match.id
  --- @type SolitaireEvent?
  local event = view.played

  if not sameGame then
    local opening = view.live and view.match.status == "active" and view.ply == 0
    if opening and not dealt[view.match.id] then
      dealt[view.match.id] = true
      self:deal()
    else
      self:draw({ instant = true })
    end
  elseif not view.changed then
    self:draw()
  elseif event and event.finished then
    self:draw({ sequence = event.finished, gap = FINISH_GAP, sound = PLAY_SOUND })
    self:celebrate(#event.finished * FINISH_GAP)
  else
    -- A card turned from the stock and a move taken back slide, anything else is put down
    self:draw({ sound = (event and event.cards) and PLAY_SOUND or DRAW_SOUND })
    if event and state.outcome then
      self:celebrate(0)
    end
  end
end

private.Games.Register({
  id = "solitaire",
  name = L["game_solitaire"],
  description = L["game_solitaire_description"],
  genre = "solo",
  icon = "Interface\\AddOns\\ForeverGames\\Images\\Icons\\solitaire",
  version = 1,
  seats = 1,
  undo = true,
  newState = newState,
  turn = function()
    return 1
  end,
  validate = validate,
  apply = apply,
  result = function(state)
    return state.outcome
  end,
  progress = function(state)
    return L["solitaire_progress"]:format(state.score, state.moves)
  end,
  createView = createView,
})
