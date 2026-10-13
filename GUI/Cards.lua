--------------------------
--  Cards
--------------------------
-- Playing cards, for any game played with them: what a card looks like, a row of them that
-- fans out to fit the room it has and lets the player pick one, a single card for a deck or a
-- pile, and cards that fly from one place to another.
--
-- Nothing here knows any rules. A card is the two characters games write it as, rank and then
-- suit ("QH", "TS"), and anything else is a card seen from the back. See Games/CrazyEights.lua.
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
-- Seconds a card takes to fly somewhere
local FLIGHT = 0.28

--- @param card string
--- @return string
function Cards.Texture(card)
  return IMAGES .. (card:match("^[A2-9TJQK][SHDC]$") or "back")
end

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
  local cardHeight = self.height / (1 + HOVER_LIFT)
  local cardWidth = cardHeight * Cards.RATIO
  local step = cardWidth * SPREAD
  if count > 1 then
    step = math.min(step, (self.width - cardWidth) / (count - 1))
  end
  local left = (self.width - (cardWidth + step * (count - 1))) / 2
  local lift = 0
  if button.pickable then
    lift = cardHeight * (button.hovered and HOVER_LIFT or LIFT)
  end
  button:SetSize(cardWidth, cardHeight)
  button:ClearAllPoints()
  button:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", left + (index - 1) * step, lift)
end

--- How much room the row has. Cards are as high as that allows, less what one that is pointed
--- at rises by
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
function Flights:Fly(card, fromX, fromY, to, width, height)
  local toX, toY = self:Spot(to)
  if not fromX or not toX then
    return
  end
  local flight = table.remove(self.spare) or { texture = self.frame:CreateTexture(nil, "OVERLAY") }
  flight.fromX, flight.fromY, flight.toX, flight.toY = fromX, fromY, toX, toY
  flight.elapsed, flight.to = 0, to
  flight.texture:SetTexture(Cards.Texture(card))
  flight.texture:SetSize(width, height)
  flight.texture:Show()
  to:SetAlpha(0)
  self.flying[#self.flying + 1] = flight
  self:advance(0)
end

--- Lands every card that is still on its way
function Flights:Stop()
  for index = #self.flying, 1, -1 do
    local flight = table.remove(self.flying, index)
    flight.texture:Hide()
    flight.to:SetAlpha(1)
    self.spare[#self.spare + 1] = flight
  end
end

--- @param elapsed number
function Flights:advance(elapsed)
  for index = #self.flying, 1, -1 do
    local flight = self.flying[index]
    flight.elapsed = flight.elapsed + elapsed
    local progress = flight.elapsed / FLIGHT
    if progress >= 1 then
      table.remove(self.flying, index)
      flight.texture:Hide()
      flight.to:SetAlpha(1)
      self.spare[#self.spare + 1] = flight
    else
      -- Fast at first, settling as it arrives
      local left = (1 - progress) ^ 3
      local x = flight.toX + (flight.fromX - flight.toX) * left
      local y = flight.toY + (flight.fromY - flight.toY) * left
      flight.texture:ClearAllPoints()
      flight.texture:SetPoint("CENTER", self.frame, "BOTTOMLEFT", x, y)
    end
  end
end
