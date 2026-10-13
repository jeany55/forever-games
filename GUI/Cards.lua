--------------------------
--  Cards
--------------------------
-- Playing cards, for any game played with them: what a card looks like, a row of them that
-- fans out to fit the room it has, a hand that is such a row held in an arc for the player to
-- pick from, a single card for a deck or a pile, and cards that fly from one place to another:
-- one at a time as they are played, or dealt round the table and turned over as they land.
--
-- Nothing here knows any rules. A card is the two characters games write it as, rank and then
-- suit ("QH", "TS"), and anything else is a card seen from the back. See Games/CrazyEights.lua.
--
-- This is for cards that are held and played. A game where they lie in piles on a table and are
-- moved from one to the other has GUI/CardTable.lua, see Games/Solitaire.lua.
--
-- The pictures are Kenney's (Tools/convert_kenney.py), one size of them: a card isn't drawn
-- much bigger or smaller than it is.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class Cards
local Cards = {}
private.Cards = Cards

local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\Cards\\"
-- How wide a card is for its height
Cards.RATIO = 140 / 190
-- How far apart cards lie when there is all the room they want, as a fraction of their width:
-- held like a hand, with enough of each showing to read its corner
local SPREAD = 0.7
-- How far a card the player may pick stands out of the row, and how much further under the
-- cursor, as fractions of its height
local LIFT, HOVER_LIFT = 0.1, 0.16
-- A card that can't be picked while others can
local DIMMED = { 0.55, 0.55, 0.6 }
-- How much higher the middle of a hand is held than its ends, as a fraction of a card's height
local ARC = 0.08
-- Seconds a card takes to fly somewhere
local FLIGHT = 0.28
-- Seconds a card that is dealt takes, and from one card leaving the deck to the next. A big
-- deal is hurried up so that it never takes much longer than this in all
local DEAL_FLIGHT, DEAL_GAP, DEAL_TIME = 0.36, 0.1, 1.8
-- The part of its flight a card spends turning over, and how narrow it gets edge on
local TURN_FROM, TURN_TO, TURN_EDGE = 0.25, 0.8, 0.06

--- @param card string
--- @return string
function Cards.Texture(card)
  return IMAGES .. (card:match("^[A2-9TJQK][SHDC]$") or "back")
end

-- White shapes to tint (Tools/make_cards.py): a card with nothing on it, the outline of a place
-- one can be put, and an arrow that goes round
Cards.BLANK, Cards.SLOT, Cards.AGAIN = IMAGES .. "blank", IMAGES .. "slot", IMAGES .. "again"

--- The pip of a suit on its own
--- @param suit string S, H, D or C
--- @return string
function Cards.Suit(suit)
  return IMAGES .. "suit" .. suit
end

--- A single card: the top of a pile, a deck to draw from
--- @param parent Frame
--- @return Button card With Set(card) to say which, nil for none, and a count FontString on it
function Cards.Card(parent)
  local button = CreateFrame("Button", nil, parent)
  button.face = button:CreateTexture(nil, "ARTWORK")
  button.face:SetAllPoints()
  local hover = button:CreateTexture(nil, "HIGHLIGHT")
  hover:SetAllPoints()
  hover:SetColorTexture(1, 1, 1, 0.18)
  button.hover = hover
  button.count = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  button.count:SetPoint("CENTER")

  --- @param card string?
  function button:Set(card)
    self.card = card
    self.face:SetShown(card ~= nil)
    if card then
      self.face:SetTexture(Cards.Texture(card))
    end
  end

  --- Whether clicking it does anything, which it shows by lighting up under the cursor
  --- @param enabled boolean
  function button:SetPlayable(enabled)
    self.playable = enabled
    self.hover:SetAlpha(enabled and 1 or 0)
  end
  button:SetPlayable(false)
  return button
end

-----------------------------
-- Row
-----------------------------

--- @class CardRow
--- @field frame Frame
--- @field cards Button[] One per card shown, the first on the left
--- @field onPick fun(card: string, index: number)? The player clicked a card they may pick
local Row = {}
Row.__index = Row

--- A row of cards, overlapping as much as it takes to fit
--- @param parent Frame
--- @return CardRow
function Cards.Row(parent)
  --- @type CardRow
  local row = setmetatable({ frame = CreateFrame("Frame", nil, parent), cards = {}, held = {}, width = 0, height = 0 }, Row)
  return row
end

--- The player's own cards: a row held the way a hand of cards is, in a shallow arc
--- @param parent Frame
--- @return CardRow
function Cards.Hand(parent)
  local hand = Cards.Row(parent)
  hand.arc = ARC
  return hand
end

--- @param row CardRow
--- @param index number
--- @return Button
local function cardAt(row, index)
  local button = row.cards[index]
  if button then
    return button
  end
  button = CreateFrame("Button", nil, row.frame)
  -- Each card lies on the one to its left
  button:SetFrameLevel(row.frame:GetFrameLevel() + index)
  button.face = button:CreateTexture(nil, "ARTWORK")
  button.face:SetAllPoints()
  button:SetScript("OnEnter", function(self)
    self.hovered = true
    row:place(index)
  end)
  button:SetScript("OnLeave", function(self)
    self.hovered = false
    row:place(index)
  end)
  button:SetScript("OnClick", function(self)
    if self.pickable and row.onPick then
      row.onPick(self.card, index)
    end
  end)
  row.cards[index] = button
  return button
end

--- Puts a card where it belongs in the row
--- @param index number
function Row:place(index)
  local button = self.cards[index]
  local count = #self.held
  local arc = self.arc or 0
  local cardHeight = self.height / (1 + HOVER_LIFT + arc)
  local cardWidth = cardHeight * Cards.RATIO
  local step = cardWidth * SPREAD
  if count > 1 then
    step = math.min(step, (self.width - cardWidth) / (count - 1))
  end
  local left = (self.width - (cardWidth + step * (count - 1))) / 2
  -- An arc is highest in the middle and falls away to both sides
  local along = count > 1 and (index - 1) / (count - 1) * 2 - 1 or 0
  local lift = cardHeight * arc * (1 - along ^ 2)
  if button.pickable then
    lift = lift + cardHeight * (button.hovered and HOVER_LIFT or LIFT)
  end
  button:SetSize(cardWidth, cardHeight)
  button:ClearAllPoints()
  button:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", left + (index - 1) * step, lift)
end

--- How much room the row has. Cards are as high as that allows, less what one that is pointed
--- at rises by and what the arc of a hand takes
--- @param width number
--- @param height number
function Row:SetSize(width, height)
  self.width, self.height = width, height
  self.frame:SetSize(width, height)
  for index = 1, #self.held do
    self:place(index)
  end
end

--- @param cards string[] Left to right. Anything that isn't a card is drawn as the back of one
--- @param pickable table<string, boolean>? The cards the player may pick right now. Left out for a row that is only looked at
function Row:Set(cards, pickable)
  self.held = { unpack(cards) }
  local choosing = pickable ~= nil and next(pickable) ~= nil
  for index, card in ipairs(cards) do
    local button = cardAt(self, index)
    button.card = card
    button.pickable = pickable ~= nil and pickable[card] == true
    button.face:SetTexture(Cards.Texture(card))
    -- What can't be played steps back while there is a choice to make
    if choosing and not button.pickable then
      button.face:SetVertexColor(unpack(DIMMED))
    else
      button.face:SetVertexColor(1, 1, 1)
    end
    button:EnableMouse(pickable ~= nil)
    button:Show()
    self:place(index)
  end
  for index = #cards + 1, #self.cards do
    self.cards[index].card = nil
    self.cards[index]:Hide()
  end
end

--- The card in the row showing a face, to fly a card from or to. The last card of the row if
--- it isn't there, and the row itself if nothing is
--- @param card string?
--- @return Region
function Row:Find(card)
  for index = 1, #self.held do
    if self.held[index] == card then
      return self.cards[index]
    end
  end
  return self.cards[#self.held] or self.frame
end

-----------------------------
-- Flight
-----------------------------

--- @class CardFlights
--- @field frame Frame
local Flights = {}
Flights.__index = Flights

--- Cards on the move, drawn over everything in the frame they are made for
--- @param parent Frame
--- @return CardFlights
function Cards.Flights(parent)
  --- @type CardFlights
  local flights = setmetatable({ frame = CreateFrame("Frame", nil, parent), flying = {}, spare = {} }, Flights)
  flights.frame.flights = flights
  flights.frame:SetAllPoints()
  flights.frame:SetFrameLevel(parent:GetFrameLevel() + 40)
  flights.frame:SetScript("OnUpdate", function(_, elapsed)
    flights:advance(elapsed)
  end)
  return flights
end

--- Where the middle of a region is, measured from the bottom left corner of the frame flown over.
--- Asked before the region moves on, for a card that is about to leave where it is
--- @param region Region
--- @return number? x, number? y nil for a region that has no place yet
function Flights:Spot(region)
  local x, y = region:GetCenter()
  local left, bottom = self.frame:GetLeft(), self.frame:GetBottom()
  if not x or not left or not bottom then
    return nil
  end
  return x - left, y - bottom
end

--- Flies a card from one place to another. Whatever is at the far end stays out of sight until
--- the card gets there, so it looks like the card that arrived
--- @param card string What it shows on the way
--- @param fromX number? Where it sets out from, as Spot says it. Without one it doesn't fly
--- @param fromY number?
--- @param to Region
--- @param width number How big the card is on the way
--- @param height number
--- @param options { delay: number?, seconds: number?, face: string?, onStart: fun()? }? Seconds to wait before it sets out, how long it takes, a card it turns over into on the way, and something to do as it leaves
function Flights:Fly(card, fromX, fromY, to, width, height, options)
  local toX, toY = self:Spot(to)
  if not fromX or not toX then
    return
  end
  options = options or {}
  local flight = table.remove(self.spare) or { texture = self.frame:CreateTexture(nil, "OVERLAY") }
  flight.fromX, flight.fromY, flight.toX, flight.toY = fromX, fromY, toX, toY
  flight.card, flight.face, flight.turned = card, options.face, false
  flight.width, flight.height = width, height
  flight.seconds, flight.onStart = options.seconds or FLIGHT, options.onStart
  -- Not on its way yet for as long as this is below nothing
  flight.elapsed, flight.started, flight.to = -(options.delay or 0), false, to
  flight.texture:SetTexture(Cards.Texture(card))
  flight.texture:SetSize(width, height)
  flight.texture:Hide()
  to:SetAlpha(0)
  self.flying[#self.flying + 1] = flight
  self:advance(0)
end

--- Deals cards out of a deck, one after the other. Each is dealt face down and may turn over
--- as it lands
--- @param deck Region
--- @param stops { to: Region, face: string? }[] Where each card goes, in the order they are dealt, and what it turns out to be
--- @param width number How big a card is on the way
--- @param height number
--- @param onDealt fun(index: number)? Called as each card leaves the deck
function Flights:Deal(deck, stops, width, height, onDealt)
  local x, y = self:Spot(deck)
  local gap = math.min(DEAL_GAP, DEAL_TIME / math.max(1, #stops))
  for index, stop in ipairs(stops) do
    self:Fly("back", x, y, stop.to, width, height, {
      delay = (index - 1) * gap,
      seconds = DEAL_FLIGHT,
      face = stop.face,
      onStart = onDealt and function()
        onDealt(index)
      end,
    })
  end
end

--- Whether any card is still on its way
--- @return boolean
function Flights:Busy()
  return #self.flying > 0
end

--- @param flight table
function Flights:land(flight)
  flight.texture:Hide()
  flight.to:SetAlpha(1)
  self.spare[#self.spare + 1] = flight
end

--- Lands every card that is still on its way
function Flights:Stop()
  for index = #self.flying, 1, -1 do
    self:land(table.remove(self.flying, index))
  end
end

--- @param elapsed number
function Flights:advance(elapsed)
  -- In the order they were sent off, so that what each one does as it leaves happens in order
  local index = 1
  while self.flying[index] do
    local flight = self.flying[index]
    flight.elapsed = flight.elapsed + elapsed
    local progress = flight.elapsed / flight.seconds
    if progress >= 1 then
      table.remove(self.flying, index)
      if not flight.started and flight.onStart then
        flight.onStart()
      end
      self:land(flight)
    else
      index = index + 1
      if progress >= 0 then
        if not flight.started then
          flight.started = true
          flight.texture:Show()
          if flight.onStart then
            flight.onStart()
          end
        end
        -- Fast at first, settling as it arrives
        local left = (1 - progress) ^ 3
        local x = flight.toX + (flight.fromX - flight.toX) * left
        local y = flight.toY + (flight.fromY - flight.toY) * left
        flight.texture:ClearAllPoints()
        flight.texture:SetPoint("CENTER", self.frame, "BOTTOMLEFT", x, y)

        if flight.face then
          -- Turning over in the air: narrower until it is edge on, then wider again showing its face
          local turn = math.max(0, math.min(1, (progress - TURN_FROM) / (TURN_TO - TURN_FROM)))
          if turn >= 0.5 and not flight.turned then
            flight.turned = true
            flight.texture:SetTexture(Cards.Texture(flight.face))
          end
          flight.texture:SetWidth(flight.width * math.max(TURN_EDGE, math.abs(math.cos(turn * math.pi))))
        end
      end
    end
  end
end
