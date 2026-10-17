--------------------------
--  Crazy Eights
--------------------------
-- For two to six players with one deck of cards. Everyone is dealt a hand, seven cards between
-- two players and five among more, and a card is turned up to start the pile. In turn each
-- player puts a card on the pile that matches the one on top in suit or in rank. An eight goes
-- on anything, and whoever plays one says which suit comes next. First to run out of cards wins.
--
-- A player who can't play, or would rather not, draws a card. If it can't be played either the
-- turn is over: the game sees to that. If it can, the turn goes on, and the player plays
-- something or passes. When the deck runs out the pile is shuffled back into it, all but the
-- card on top. The hand of a player who resigns goes back under the deck.
--
-- Nobody sees the deck or anybody else's hand: `visible` leaves the local player with the backs
-- of those cards, and nothing the game says about a move names a card that wasn't shown.
--
-- A card is its rank and its suit, "QH" for the queen of hearts, with T for ten. A move is the
-- card played ("QH"), followed by the suit called if it is an eight ("8SD"), "d" to draw and "p"
-- to pass.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Deck = private.Deck
local Tables = private.Tables

local RANKS, SUITS = Deck.RANKS, Deck.SUITS
local WILD = "8"
-- A card the local player doesn't get to see the face of
local HIDDEN = Deck.HIDDEN
-- Cards dealt to each player, by how many play
local DEALT = { [2] = 7 }
local DEALT_CROWD = 5
local DRAW, PASS = "d", "p"

--- @class CrazyEightsState
--- @field seats number How many are playing
--- @field hands string[][] Cards by seat, in the order they were picked up
--- @field deck string[] Face down, the next card to be drawn is the last
--- @field pile string[] Face up, the card on top is the last
--- @field suit string The suit to follow: that of the card on top, or what was called with an eight
--- @field turn number
--- @field drew boolean Whoever's turn it is has drawn, and may now play or pass
--- @field idle number Players in a row who could neither play nor draw
--- @field out table<number, boolean> Seats that resigned
--- @field outcome { winner: number, detail: string? }?

--- @class CrazyEightsEvent: MatchEvent
--- @field card string? The card that was played
--- @field called string? The suit called with it
--- @field drew boolean? A card was drawn instead. Which one is nobody else's business
--- @field passed boolean? The turn went on to the next player
--- @field shuffled boolean? The pile had to be shuffled back into the deck first

-----------------------------
-- Rules
-----------------------------

--- Whether a card may go on the pile
--- @param state CrazyEightsState
--- @param card string
--- @return boolean
local function playable(state, card)
  local rank, suit = Deck.Parts(card)
  return rank == WILD or suit == state.suit or rank == Deck.Parts(state.pile[#state.pile])
end

--- Whether there is a card left to draw, in the deck or under the top of the pile
--- @param state CrazyEightsState
--- @return boolean
local function canDraw(state)
  return #state.deck > 0 or #state.pile > 1
end

--- Hands the turn to the next player who is still in the game
--- @param state CrazyEightsState
local function pass(state)
  repeat
    state.turn = state.turn % state.seats + 1
  until not state.out[state.turn]
  state.drew = false
end

--- @param seats number
--- @param random Random
--- @param rules table<string, any>? The usual ones if left out
--- @return CrazyEightsState
local function newState(seats, random, rules)
  local deck = Deck.Shuffled(random)

  --- @type CrazyEightsState
  local state = { seats = seats, hands = {}, deck = deck, pile = {}, turn = 1, drew = false, idle = 0, out = {} }
  for seat = 1, seats do
    state.hands[seat] = {}
  end
  local dealt = rules and rules.dealt or 0
  Deck.Deal(deck, state.hands, dealt > 0 and dealt or DEALT[seats] or DEALT_CROWD)

  -- The pile starts with the first card that isn't an eight
  local starter = #deck
  while Deck.Parts(deck[starter]) == WILD do
    starter = starter - 1
  end
  state.pile[1] = table.remove(deck, starter)
  state.suit = select(2, Deck.Parts(state.pile[1]))
  return state
end

--- @param state CrazyEightsState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  if seat ~= state.turn then
    return false, "not_your_turn"
  end
  if move == DRAW then
    if state.drew or not canDraw(state) then
      return false, "cant_draw"
    end
    return true
  elseif move == PASS then
    -- Only after drawing, unless there is nothing left to draw
    if not state.drew and canDraw(state) then
      return false, "draw_first"
    end
    return true
  end

  local rank, suit, called = move:match("^([%dAJKQT])([SHDC])([SHDC]?)$")
  if not rank or not RANKS:find(rank, 1, true) or (rank == WILD) ~= (called ~= "") then
    return false, "invalid_move"
  end
  local card = rank .. suit
  if not Deck.Find(state.hands[seat], card) then
    return false, "invalid_move"
  end
  if not playable(state, card) then
    return false, "card_doesnt_match"
  end
  return true
end

--- Every card in the hand that can go on the pile, an eight once with each suit it could call,
--- and drawing or passing where the player may. Nothing in it but what the player can see
--- @param state CrazyEightsState
--- @param seat number
--- @return string[]
local function moves(state, seat)
  local list = {}
  for _, card in ipairs(state.hands[seat]) do
    if playable(state, card) then
      if Deck.Parts(card) == WILD then
        for suit in SUITS:gmatch(".") do
          list[#list + 1] = card .. suit
        end
      else
        list[#list + 1] = card
      end
    end
  end
  if not state.drew and canDraw(state) then
    list[#list + 1] = DRAW
  else
    list[#list + 1] = PASS
  end
  return list
end

--- @param state CrazyEightsState
--- @param seat number
--- @param move string
--- @param random Random
--- @return CrazyEightsEvent
local function apply(state, seat, move, random)
  local hand = state.hands[seat]
  if move == PASS then
    -- All the way round without anyone playing or drawing, and the game is stuck
    state.idle = state.drew and 0 or state.idle + 1
    local left = 0
    for other = 1, state.seats do
      left = left + (state.out[other] and 0 or 1)
    end
    if state.idle >= left then
      state.outcome = { winner = 0, detail = "blocked" }
    end
    pass(state)
    return { passed = true }
  end
  state.idle = 0

  if move == DRAW then
    local shuffled = #state.deck == 0
    if shuffled then
      local top = table.remove(state.pile)
      state.deck, state.pile = random:Shuffle(state.pile), { top }
    end
    local card = table.remove(state.deck)
    hand[#hand + 1] = card
    state.drew = true
    -- With nothing to play even now, there is nothing left to decide
    local stuck = true
    for _, held in ipairs(hand) do
      stuck = stuck and not playable(state, held)
    end
    if stuck then
      pass(state)
    end
    return { drew = true, passed = stuck, shuffled = shuffled }
  end

  local card, called = move:sub(1, 2), move:sub(3, 3)
  table.remove(hand, Deck.Find(hand, card))
  state.pile[#state.pile + 1] = card
  state.suit = called ~= "" and called or select(2, Deck.Parts(card))
  if #hand == 0 then
    state.outcome = { winner = seat }
  else
    pass(state)
  end
  return { card = card, called = called ~= "" and called or nil, passed = true }
end

--- A player resigned: their cards go back under the deck
--- @param state CrazyEightsState
--- @param seat number
local function drop(state, seat)
  state.out[seat] = true
  for _, card in ipairs(state.hands[seat]) do
    table.insert(state.deck, 1, card)
  end
  state.hands[seat] = {}
  if state.turn == seat then
    pass(state)
  end
end

--- What a player may see: their own hand and the pile. Of the deck and the other hands, only
--- how many cards there are
--- @param state CrazyEightsState
--- @param seat number
--- @return CrazyEightsState
local function visible(state, seat)
  local seen = Tables.Shallow(state)
  seen.deck, seen.pile, seen.hands = Deck.Backs(#state.deck), { unpack(state.pile) }, {}
  for other, hand in ipairs(state.hands) do
    seen.hands[other] = other == seat and { unpack(hand) } or Deck.Backs(#hand)
  end
  return seen
end

-----------------------------
-- The computer
-----------------------------
-- It sees what anyone at the table would, its own hand and the pile, and guesses at the rest:
-- the cards it hasn't seen dealt out among the other hands and the deck, as many to each as
-- there are. It plays its hand against a few such guesses at once and does whatever comes out
-- best over all of them. What it wants is fewer cards than anybody else, and to keep it that
-- way: an eight held back for when nothing else will do, and a hand of few suits, which is
-- easier to keep playing from.

local HELD, OTHERS, EIGHT, SUITED = 10, 4, 6, 2

--- How well a seat stands
--- @param state CrazyEightsState
--- @param seat number
--- @return number
local function standing(state, seat)
  local hand = state.hands[seat]
  local score = -HELD * #hand
  -- The others' hands, the shortest of them most of all: that is who is about to win
  local fewest, total, others = nil, 0, 0
  for other = 1, state.seats do
    if other ~= seat and not state.out[other] then
      local held = #state.hands[other]
      fewest = fewest and math.min(fewest, held) or held
      total, others = total + held, others + 1
    end
  end
  if others > 0 then
    score = score + OTHERS * (fewest + total / others) / 2
  end
  local suits = {}
  for _, card in ipairs(hand) do
    local rank, suit = Deck.Parts(card)
    if rank == WILD then
      score = score + EIGHT
    else
      suits[suit] = (suits[suit] or 0) + 1
    end
  end
  for _, count in pairs(suits) do
    score = score + SUITED * (count - 1)
  end
  return score
end

--- The whole table as it could be, from what a seat sees of it: every card it hasn't seen
--- dealt out at random among the other hands and the deck, as many to each as there are
--- @param seen CrazyEightsState
--- @param seat number
--- @param random Random
--- @return CrazyEightsState
local function guess(seen, seat, random)
  local unseen = random:Shuffle(Deck.Unseen(seen.hands[seat], seen.pile))

  local world = Tables.Shallow(seen)
  world.pile, world.hands, world.out = { unpack(seen.pile) }, {}, {}
  for other in pairs(seen.out) do
    world.out[other] = true
  end
  for other, hand in ipairs(seen.hands) do
    if other == seat then
      world.hands[other] = { unpack(hand) }
    else
      world.hands[other] = {}
      for index = 1, #hand do
        world.hands[other][index] = table.remove(unseen)
      end
    end
  end
  world.deck = {}
  for index = 1, #seen.deck do
    world.deck[index] = table.remove(unseen)
  end
  return world
end

local COMPUTER = {
  evaluate = standing,
  guess = guess,
  priority = function(state, move)
    -- An eight last, drawing after that
    if move == DRAW or move == PASS then
      return -2
    end
    return Deck.Parts(move) == WILD and -1 or 0
  end,
  levels = {
    easy = { depth = 1, slip = 0.35, among = 3, samples = 2 },
    medium = { depth = 2, budget = 1500, samples = 4, slip = 0.05 },
    -- Looking further ahead than this only goes further into what it guessed
    hard = { depth = 3, budget = 6000, samples = 8 },
  },
}

-----------------------------
-- View
-----------------------------
-- A card table on the shared cards (GUI/Cards.lua): the player's hand along the bottom, the
-- others' along the top as so many backs, and the deck and the pile between them. A card that
-- can be played stands out of the hand, clicking it plays it. An eight asks for a suit first,
-- and playing something else instead is how the player thinks better of it.
--
-- A game the player opens before anyone has played is dealt out in front of them: a card at a
-- time round the table, their own turning face up as they land, and one turned up for the pile.

local SUIT_ORDER = { S = 1, H = 2, D = 3, C = 4 }
-- The most players there are other than the local one
local MAX_OTHERS = 5
-- How much of the table's height the player's hand takes, and no more than this many units
local HAND_SHARE, HAND_MAX = 0.3, 190
-- The others' hands and the cards in the middle, as fractions of the height of the player's
local OTHERS_SCALE, MIDDLE_SCALE = 0.42, 0.72
local LABEL_HEIGHT = 18
local FELT = { 0.06, 0.24, 0.15, 0.85 }
local BUTTON_WIDTH, BUTTON_HEIGHT = 90, 24
local PLAY_SOUND, DRAW_SOUND = "cardPlace", "cardSlide"
-- A deal of more cards than this is heard every other card, not every one
local QUIET_DEAL = 16
-- Matches the player has watched being dealt, by id: once is enough
local dealt = {}

--- @class CrazyEightsView: GameViewObject
--- @field stage Frame
--- @field hand CardRow The player's own
--- @field others { row: CardRow, label: FontString }[] Everyone else's, going round from the player
--- @field deck Button
--- @field pile Button
--- @field under Button The card below the top of the pile, seen while one is on its way there
--- @field follow Frame The suit that has to be followed
--- @field note FontString
--- @field passButton Button
--- @field picker Frame The four suits, to call one with an eight
--- @field flights CardFlights
--- @field view GameView? What was last asked for
--- @field pending string? The eight the player is choosing a suit for
--- @field dealing number? Cards that have yet to leave the deck, while the game is being dealt
local View = {}
View.__index = View

--- @param hand string[]
--- @return string[] The same cards, sorted by suit and then by rank
local function sorted(hand)
  local cards = { unpack(hand) }
  table.sort(cards, function(a, b)
    local suitA, suitB = Deck.Suit(a), Deck.Suit(b)
    if suitA ~= suitB then
      return (SUIT_ORDER[suitA] or 0) < (SUIT_ORDER[suitB] or 0)
    end
    return Deck.Rank(a) < Deck.Rank(b)
  end)
  return cards
end

--- The seat an other player's row is for, going round the table from the local player
--- @param state CrazyEightsState
--- @param seat number The local player's
--- @param index number
--- @return number
local function seatAt(state, seat, index)
  return (seat + index - 1) % state.seats + 1
end

--- @param stage Frame
--- @return CrazyEightsView
local function createView(stage)
  --- @type CrazyEightsView
  local self = setmetatable({ stage = stage, others = {} }, View)
  local Cards, Widgets = private.Cards, private.Widgets

  local felt = stage:CreateTexture(nil, "BACKGROUND")
  felt:SetAllPoints()
  felt:SetColorTexture(unpack(FELT))

  self.hand = Cards.Hand(stage)
  self.hand.frame:SetPoint("BOTTOM")
  self.hand.onPick = function(card)
    if Deck.Parts(card) == WILD then
      -- Which suit comes next has to be said with it
      self.pending = card
      self:draw()
    else
      self.view.submit(card)
    end
  end

  for index = 1, MAX_OTHERS do
    local row = Cards.Row(stage)
    local label = Widgets.Label(stage, "GameFontHighlightSmall")
    label:SetPoint("TOP", row.frame, "BOTTOM", 0, -2)
    self.others[index] = { row = row, label = label }
  end

  self.under, self.pile, self.deck = Cards.Card(stage), Cards.Card(stage), Cards.Card(stage)
  self.pile:SetFrameLevel(self.under:GetFrameLevel() + 1)
  self.deck:SetPlayable(true)
  self.deck:SetScript("OnClick", function(deck)
    if deck.playable then
      self.view.submit(DRAW)
    end
  end)

  self.follow = CreateFrame("Frame", nil, stage)
  self.follow.icon = self.follow:CreateTexture(nil, "ARTWORK")
  self.follow.icon:SetAllPoints()
  self.follow.label = Widgets.Label(stage, "GameFontDisableSmall", L["crazyeights_follow"])
  self.follow.label:SetPoint("BOTTOM", self.follow, "TOP", 0, 4)

  self.note = Widgets.Label(stage, "GameFontHighlightSmall")
  self.note:SetJustifyH("CENTER")
  self.note:SetTextColor(unpack(Widgets.GOLD))

  self.passButton = Widgets.Button(stage, L["crazyeights_pass"], BUTTON_WIDTH, BUTTON_HEIGHT)
  self.passButton:SetPoint("TOP", self.note, "BOTTOM", 0, -6)
  self.passButton:SetScript("OnClick", function()
    self.view.submit(PASS)
  end)

  -- The suits to call with an eight, where the pass button is otherwise
  self.picker = CreateFrame("Frame", nil, stage)
  self.picker:SetPoint("TOP", self.note, "BOTTOM", 0, -6)
  self.picker.suits = {}
  for index = 1, #SUITS do
    local suit = SUITS:sub(index, index)
    local button = CreateFrame("Button", nil, self.picker)
    button.suit = suit
    local back = button:CreateTexture(nil, "BACKGROUND")
    back:SetAllPoints()
    back:SetColorTexture(0.93, 0.93, 0.9, 1)
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 3, -3)
    icon:SetPoint("BOTTOMRIGHT", -3, 3)
    icon:SetTexture(Cards.Suit(suit))
    local hover = button:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetColorTexture(0.25, 0.7, 0.3, 0.45)
    button:SetScript("OnClick", function()
      self.view.submit(self.pending .. suit)
    end)
    self.picker.suits[index] = button
  end

  self.flights = Cards.Flights(stage)
  return self
end

--- @param width number
--- @param height number
function View:Layout(width, height)
  local Cards = private.Cards
  self.width, self.height = width, height
  local handHeight = math.min(HAND_MAX, math.floor(height * HAND_SHARE))
  self.handHeight = handHeight
  self.hand:SetSize(width, handHeight)

  local othersHeight = math.floor(handHeight * OTHERS_SCALE)
  local cardHeight = math.floor(handHeight * MIDDLE_SCALE)
  local cardWidth = math.floor(cardHeight * Cards.RATIO)
  self.cardWidth, self.cardHeight = cardWidth, cardHeight
  -- The middle of what is left between the others' hands and the player's own
  local rise = (handHeight - othersHeight - LABEL_HEIGHT) / 2
  for _, card in ipairs({ self.deck, self.pile, self.under }) do
    card:SetSize(cardWidth, cardHeight)
    card:ClearAllPoints()
    card:SetPoint("CENTER", self.stage, "CENTER", (card == self.deck and -1 or 1) * cardWidth * 0.62, rise)
  end
  local pip = math.floor(cardWidth * 0.5)
  self.follow:SetSize(pip, pip)
  self.follow:ClearAllPoints()
  self.follow:SetPoint("LEFT", self.pile, "RIGHT", 18, -6)

  self.note:ClearAllPoints()
  self.note:SetPoint("TOP", self.stage, "CENTER", 0, rise - cardHeight / 2 - 8)
  self.note:SetWidth(width)
  local side = BUTTON_HEIGHT + 8
  self.picker:SetSize(#SUITS * (side + 6) - 6, side)
  for index, button in ipairs(self.picker.suits) do
    button:SetSize(side, side)
    button:ClearAllPoints()
    button:SetPoint("LEFT", (index - 1) * (side + 6), 0)
  end

  self.seated = nil
  if self.view then
    self:draw()
  end
end

--- Gives everyone else their place along the top, however many they are
--- @param count number
function View:seat(count)
  if self.seated == count then
    return
  end
  self.seated = count
  local room = self.width / count
  local height = math.floor(self.handHeight * OTHERS_SCALE)
  for index, other in ipairs(self.others) do
    other.row.frame:SetShown(index <= count)
    other.label:SetShown(index <= count)
    if index <= count then
      other.row:SetSize(math.min(room * 0.8, height * 4), height)
      other.row.frame:ClearAllPoints()
      other.row.frame:SetPoint("TOP", self.stage, "TOPLEFT", (index - 0.5) * room, 0)
    end
  end
end

--- Puts the position on the table
function View:draw()
  local view = self.view
  --- @type CrazyEightsState
  local state = view.state
  local Widgets = private.Widgets
  local seat = view.seat
  local playing = view.live and view.match.status == "active" and not state.outcome

  local pickable, choice = nil, false
  if view.canMove then
    pickable = {}
    for _, card in ipairs(state.hands[seat]) do
      pickable[card] = playable(state, card)
      choice = choice or pickable[card]
    end
  end
  self.hand:Set(sorted(state.hands[seat]), pickable)

  self:seat(state.seats - 1)
  for index = 1, state.seats - 1 do
    local other, owner = self.others[index], seatAt(state, seat, index)
    -- Backs while the game is on, their cards once it is over
    other.row:Set(sorted(state.hands[owner]))
    if state.out[owner] then
      other.label:SetText(L["crazyeights_out"]:format(view.names[owner]))
      other.label:SetTextColor(0.45, 0.45, 0.45)
    else
      other.label:SetText(L["crazyeights_cards"]:format(view.names[owner], #state.hands[owner]))
      if playing and state.turn == owner then
        other.label:SetTextColor(unpack(Widgets.GOLD))
      else
        other.label:SetTextColor(0.85, 0.85, 0.85)
      end
    end
  end

  self.pile:Set(state.pile[#state.pile])
  self.under:Set(state.pile[#state.pile - 1])
  self.deck:Set(#state.deck > 0 and HIDDEN or nil)
  self.deck.count:SetText(#state.deck + (self.dealing or 0))
  self.deck:SetPlayable(view.canMove and not state.drew and canDraw(state))
  self.follow.icon:SetTexture(private.Cards.Suit(state.suit))

  local choosing = view.canMove and self.pending ~= nil
  -- A turn can also be passed when there is nothing to draw any more
  local mayPass = view.canMove and not choosing and (state.drew or not canDraw(state))
  self.picker:SetShown(choosing)
  self.passButton:SetShown(mayPass)
  if choosing then
    self.note:SetText(L["crazyeights_call"])
  elseif mayPass then
    self.note:SetText(L["crazyeights_drawn"])
  elseif view.canMove and not choice then
    self.note:SetText(L["crazyeights_stuck"])
  elseif view.canMove then
    self.note:SetText(L["crazyeights_choose"])
  else
    self.note:SetText("")
  end
end

--- The cards of whoever sits in a seat, as they are on the table
--- @param seat number
--- @return CardRow
function View:rowOf(seat)
  local view = self.view
  for index = 1, view.state.seats - 1 do
    if seatAt(view.state, view.seat, index) == seat then
      return self.others[index].row
    end
  end
  return self.hand
end

--- Whether nobody has played yet in the position on the table
--- @return boolean
function View:isOpening()
  local view = self.view
  for index = 1, view.ply do
    if view.events[index].kind == "move" then
      return false
    end
  end
  return view.live and view.match.status == "active"
end

--- Deals the game out: a card to everyone in turn until the hands are full, the player's own
--- face up, and then the card that starts the pile. The table already holds all of it, each
--- card just isn't seen until it has arrived
function View:deal()
  local view = self.view
  --- @type CrazyEightsState
  local state = view.state
  local stops = {}
  for round = 1, #state.hands[view.seat] do
    for seat = 1, state.seats do
      if seat == view.seat then
        -- Hands are kept in the order they were dealt, and shown sorted
        local card = state.hands[seat][round]
        stops[#stops + 1] = { to = self.hand:Find(card), face = card }
      else
        stops[#stops + 1] = { to = self:rowOf(seat).cards[round] }
      end
    end
  end
  stops[#stops + 1] = { to = self.pile, face = state.pile[#state.pile] }

  local every = #stops > QUIET_DEAL and 2 or 1
  self.dealing = #stops
  self.deck.count:SetText(#state.deck + #stops)
  self.flights:Deal(self.deck, stops, self.cardWidth, self.cardHeight, function(index)
    -- The deck gets thinner as the cards leave it
    self.dealing = index < #stops and #stops - index or nil
    self.deck.count:SetText(#state.deck + #stops - index)
    if index % every == 0 then
      private.Widgets.PlaySound(DRAW_SOUND)
    end
  end)
  if not self.flights:Busy() then
    -- The table has no place on screen yet to deal across: the cards are simply there
    self.dealing = nil
    self.deck.count:SetText(#state.deck)
  end
end

--- Shows a move being made: the card played flies to the pile, a card drawn out of the deck
--- @param event CrazyEightsEvent
--- @param fromX number? Where the card set out from, when it was in the player's own hand
--- @param fromY number?
--- @param held table<string, boolean> What the player held before
function View:animate(event, fromX, fromY, held)
  local view, flights = self.view, self.flights
  local mine = event.seat == view.seat
  local row = self:rowOf(event.seat)

  if event.card then
    if not fromX then
      fromX, fromY = flights:Spot(row.frame)
    end
    flights:Fly(event.card, fromX, fromY, self.pile, self.cardWidth, self.cardHeight)
    private.Widgets.PlaySound(PLAY_SOUND)
  elseif event.drew then
    -- The player's own lands where it belongs in the hand, anyone else's at the end of theirs
    local drawn
    for _, card in ipairs(mine and view.state.hands[view.seat] or {}) do
      drawn = drawn or (not held[card] and card or nil)
    end
    local x, y = flights:Spot(self.deck)
    flights:Fly(HIDDEN, x, y, row:Find(drawn), self.cardWidth, self.cardHeight)
    private.Widgets.PlaySound(DRAW_SOUND)
  end
end

--- @param view GameView
function View:Update(view)
  local before = self.view
  self.view = view
  if view.changed or not view.canMove then
    -- An eight waiting for its suit belonged to the position that was showing
    self.pending = nil
  end
  if view.changed then
    self.flights:Stop()
    self.dealing = nil
  end

  --- @type CrazyEightsEvent?
  local event = view.played
  local fromX, fromY, held = nil, nil, {}
  if event and before and event.seat == view.seat then
    for _, card in ipairs(before.state.hands[view.seat] or {}) do
      held[card] = true
    end
    if event.card then
      fromX, fromY = self.flights:Spot(self.hand:Find(event.card))
    end
  end
  self:draw()
  if view.changed and not dealt[view.match.id] and self:isOpening() then
    dealt[view.match.id] = true
    self:deal()
  elseif event then
    self:animate(event, fromX, fromY, held)
  end
end

private.Games.Register({
  id = "crazyeights",
  name = L["game_crazyeights"],
  description = L["game_crazyeights_description"],
  genre = "cards",
  icon = "Interface\\AddOns\\ForeverGames\\Images\\Icons\\crazyeights",
  version = 1,
  seats = { 2, 3, 4, 5, 6 },
  options = {
    {
      id = "dealt",
      name = L["crazyeights_option_dealt"],
      description = L["crazyeights_option_dealt_tip"],
      -- Six players with eight cards each still leave some to draw
      choices = { 0, 5, 7, 8 },
      default = 0,
      label = function(value)
        return value == 0 and L["crazyeights_option_dealt_usual"] or tostring(value)
      end,
    },
  },
  howto = {
    { heading = L["howto_goal"], text = L["crazyeights_howto_goal"] },
    {
      heading = L["crazyeights_howto_dealing"],
      text = function(rules)
        return rules.dealt == 0 and L["crazyeights_howto_deal_usual"] or L["crazyeights_howto_deal"]:format(rules.dealt)
      end,
    },
    { heading = L["howto_turn"], text = L["crazyeights_howto_turn"] },
    { heading = L["crazyeights_howto_eights"], text = L["crazyeights_howto_eights_text"] },
    { heading = L["howto_end"], text = L["crazyeights_howto_end"] },
  },
  newState = newState,
  turn = function(state)
    return state.turn
  end,
  validate = validate,
  apply = apply,
  moves = moves,
  result = function(state)
    return state.outcome
  end,
  drop = drop,
  visible = visible,
  computer = COMPUTER,
  createView = createView,
})
