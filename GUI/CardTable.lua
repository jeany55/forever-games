--------------------------
--  Card table
--------------------------
-- A table that cards lie on in piles, for any game where they are moved from one pile to
-- another: a deck, a discard, columns that fan out, places to build on.
--
-- A game says where its piles are and how the cards in them lie on each other, and from then on
-- only which cards are in which pile. Every card on the table is the same card for as long as
-- it is there, so the table sees for itself what a new position changed and shows it: a card
-- that is somewhere else now flies there, one that was turned over turns over on the way, a
-- column that got too long for its room closes up. A move, a move taken back, a deal and a
-- whole deck gone through again are all the same thing to it, and none of them is anything the
-- game has to animate.
--
-- The player moves cards by dragging them, with whatever lies on top of the one they took hold
-- of, or by clicking. The game says what may be picked up and where it may be put down, and is
-- told when something was. A card let go where it can't stay goes back by itself, and so does
-- everything else that isn't where it belongs.
--
-- Nothing here knows any rules. A card is whatever the game calls it, shown as GUI/Cards.lua
-- draws that name: "QH" is the queen of hearts, and anything that isn't a card is seen from the
-- back. Two cards on one table can't have the same name. See Games/Solitaire.lua.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class CardTablePile
--- @field id string
--- @field x number Where its first card lies: the left and the top of it, from the top left corner of the table
--- @field y number
--- @field fan number[]? How far a card lies from the one under it, across and down, as fractions of a card's width and height. Not at all if left out
--- @field downFan number[]? The same from a card that lies face down, which needs less of it showing. Half of `fan` if left out
--- @field spread number? Only this many cards on top are fanned out, the rest lie where the first one does
--- @field room number? How far the fan may reach from the first card. Cards lie closer together to stay within it
--- @field press boolean? Clicking the top of it, or the place itself when it is empty, does something: it lights up under the cursor
--- @field mark (string|false)? A picture drawn faintly in the place while nothing covers it, false for none

--- What the cards in a pile are
--- @class CardTableCards
--- @field cards string[] From the bottom of the pile up
--- @field down number? How many of them lie face down, counted from the bottom. None if left out

--- @class CardTable
--- @field frame Frame
--- @field canLift (fun(pile: string, index: number): boolean)? Whether a card may be picked up, with all that lies on it
--- @field canDrop (fun(from: string, index: number, to: string): boolean)? Whether what was picked up there may be put down on a pile
--- @field onDrop fun(from: string, index: number, to: string)? It was. Say so by showing the position that makes, or it goes back
--- @field onClick fun(pile: string, index: number?)? A card was clicked, or with no index a place that is empty
--- @field onRightClick fun(pile: string, index: number?)? The same with the other button
local CardTable = {}
CardTable.__index = CardTable
private.CardTable = CardTable

-- Seconds a card takes to fly to another pile, to go back where it came from, to move up
-- within its pile and to turn over where it lies
local FLIGHT, RETURN, SHIFT, TURN = 0.26, 0.18, 0.16, 0.22
-- A card that turns over where it lies waits for whatever was on it to leave
local TURN_AFTER = 0.1
-- From one card of a sequence setting out to the next
local SEQUENCE_GAP = 0.05
-- A sequence of more cards than this is heard every other card, not every one
local QUIET = 16
-- The part of its flight a card spends turning over, and how narrow it gets edge on
local TURN_FROM, TURN_TO, TURN_EDGE = 0.2, 0.8, 0.06
-- How high a card rises on the way, as a fraction of its height, on a flight of two card
-- heights or more: a short hop stays low
local RISE, RISE_OVER = 0.07, 2
-- How far the cursor has to travel with the button held before a click becomes a drag
local DRAG_DISTANCE = 4
-- Frame levels, counted from the table's: places, the cards in a pile, cards in the air and in hand
local PLACE_LEVEL, PILE_LEVEL, ALOFT_LEVEL, CARRIED_LEVEL = 1, 2, 80, 400
-- Cards in the air lie over the ones that set out before them, up to this many
local ALOFT_MOST = 300
-- The shadow of a card off the table: how dark, and how far it falls as fractions of the card
local SHADOW, SHADOW_X, SHADOW_Y = 0.35, 0.05, 0.05
local OUTLINE, MARK = 0.22, 0.3
-- The light on a card that can be taken and on the pile a card would land on
local HOVER_LIGHT = { 1, 1, 1, 0.12 }
local TARGET_LIGHT = { 1, 0.82, 0, 0.4 }
-- A card that is refused shakes its head: for how long, how far as a fraction of its width, how fast
local SHAKE, SHAKE_REACH, SHAKE_SPEED = 0.3, 0.06, 46
-- A fountain: seconds between cards, how fast they set out across and upwards and how hard they
-- fall, in card heights, how much of its speed a card keeps when it bounces, the longest step
-- the falling is worked out over, and how long the cards take to appear again afterwards
local TOSS_GAP, TOSS_ACROSS, TOSS_UP, GRAVITY, BOUNCE, TOSS_STEP, TOSS_BACK = 0.09, { 1.2, 3 }, { 0.3, 2.6 }, 11, 0.74, 0.04, 0.5

--- @param parent Frame
--- @return CardTable
function CardTable.New(parent)
  --- @type CardTable
  local self = setmetatable({ piles = {}, order = {}, sprites = {}, spare = {}, flying = {}, shaking = {}, aloft = 0 }, CardTable)
  self.width, self.height, self.cardWidth, self.cardHeight = 0, 0, 0, 0
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetPoint("TOPLEFT")
  -- A card that is carried or thrown past the edge of the table isn't drawn over what is next to it
  if frame.SetClipsChildren then
    frame:SetClipsChildren(true)
  end
  frame.cardTable = self
  frame:SetScript("OnUpdate", function(_, elapsed)
    self:advance(elapsed)
  end)
  -- Nothing goes on while nobody is looking, least of all a card being held
  frame:SetScript("OnHide", function()
    self:Stop()
  end)
  self.frame = frame
  return self
end

-----------------------------
-- Looks
-----------------------------

--- Lights a card or a place up, or doesn't: as where a card would land, or as something to take
--- @param region Frame
local function relight(region)
  local light = region.target and TARGET_LIGHT or (region.hovered and HOVER_LIGHT or nil)
  region.light:SetShown(light ~= nil)
  if light then
    region.light:SetVertexColor(unpack(light))
  end
end

--- @param region Frame A card or a place
--- @return Texture
local function newLight(region)
  local light = region:CreateTexture(nil, "OVERLAY")
  light:SetAllPoints()
  light:SetTexture(private.Cards.BLANK)
  light:SetBlendMode("ADD")
  light:Hide()
  return light
end

--- Turns a card to show its face or its back
--- @param sprite Frame
--- @param up boolean
local function face(sprite, up)
  if sprite.showing ~= up then
    sprite.showing = up
    sprite.picture:SetTexture(private.Cards.Texture(up and sprite.id or ""))
  end
end

--- Draws a card where it is, or a little off it
--- @param sprite Frame
--- @param offX number?
--- @param offY number?
function CardTable:show(sprite, offX, offY)
  sprite:ClearAllPoints()
  sprite:SetPoint("CENTER", self.frame, "TOPLEFT", sprite.x + (offX or 0), -(sprite.y + (offY or 0)))
end

--- Gives a card the size cards are, and its shadow the reach that goes with it
--- @param sprite Frame
function CardTable:fit(sprite)
  local width, height = self.cardWidth, self.cardHeight
  sprite:SetSize(width, height)
  sprite.shadow:ClearAllPoints()
  sprite.shadow:SetPoint("TOPLEFT", width * SHADOW_X, -height * SHADOW_Y)
  sprite.shadow:SetPoint("BOTTOMRIGHT", width * SHADOW_X, -height * SHADOW_Y)
end

--- The card of that name, made if it isn't on the table yet
--- @param id string
--- @return Frame
function CardTable:spriteFor(id)
  local sprite = self.sprites[id]
  if sprite then
    return sprite
  end
  sprite = table.remove(self.spare)
  if not sprite then
    sprite = CreateFrame("Frame", nil, self.frame)
    sprite:EnableMouse(true)
    sprite.shadow = sprite:CreateTexture(nil, "BACKGROUND")
    sprite.shadow:SetTexture(private.Cards.BLANK)
    sprite.shadow:SetVertexColor(0, 0, 0, SHADOW)
    sprite.picture = sprite:CreateTexture(nil, "ARTWORK")
    sprite.picture:SetAllPoints()
    sprite.light = newLight(sprite)
    sprite:SetScript("OnMouseDown", function(pressed, button)
      if pressed.pile then
        self:pressed(pressed.pile, pressed.index, button)
      end
    end)
    sprite:SetScript("OnEnter", function(entered)
      local pile, index = entered.pile, entered.index
      local live = pile ~= nil and not self.carry and not self.fountain
      entered.hovered = live and ((pile.press and index == #pile.held) or (self.canLift ~= nil and self.canLift(pile.id, index)))
      relight(entered)
    end)
    sprite:SetScript("OnLeave", function(left)
      left.hovered = false
      relight(left)
    end)
  end
  sprite.id, sprite.showing = id, nil
  self.sprites[id] = sprite
  return sprite
end

--- Takes a card off the table
--- @param sprite Frame
function CardTable:discard(sprite)
  self:ground(sprite)
  self.sprites[sprite.id] = nil
  sprite.pile, sprite.index, sprite.toss, sprite.hovered, sprite.target = nil, nil, nil, false, false
  relight(sprite)
  sprite:SetAlpha(1)
  sprite:Hide()
  self.spare[#self.spare + 1] = sprite
end

-----------------------------
-- Piles
-----------------------------

--- Where the cards of a pile lie, and where the next one would
--- @param pile CardTablePile
--- @return { x: number, y: number }[] The middle of each card from the bottom of the pile up, and one more
function CardTable:spots(pile)
  local width, height = self.cardWidth, self.cardHeight
  local count = #pile.held
  local fan = pile.fan or { 0, 0 }
  local downFan = pile.downFan or { fan[1] / 2, fan[2] / 2 }
  local flat = pile.spread and count - pile.spread or 0

  -- How far each card lies from the one under it
  local steps, acrossAll, downAll = {}, 0, 0
  for index = 1, count do
    local step = index <= pile.down and downFan or fan
    local across, down = 0, 0
    if index > flat then
      across, down = step[1] * width, step[2] * height
    end
    steps[index] = { across, down }
    -- The last of them is to where the next card would lie, which needs no room yet
    if index < count then
      acrossAll, downAll = acrossAll + across, downAll + down
    end
  end
  -- A pile that would reach further than it has room for lies closer together
  local reach = math.max(math.abs(acrossAll), math.abs(downAll))
  local squeeze = (pile.room and reach > pile.room) and pile.room / reach or 1

  local spots = {}
  local x, y = pile.x + width / 2, pile.y + height / 2
  for index = 1, count + 1 do
    spots[index] = { x = x, y = y }
    local step = steps[index] or { fan[1] * width, fan[2] * height }
    x, y = x + step[1] * squeeze, y + step[2] * squeeze
  end
  return spots
end

--- Makes a pile, or changes one: where it is, how its cards lie. What is left out stays as it was
--- @param id string
--- @param options CardTablePile|table
--- @return CardTablePile
function CardTable:Pile(id, options)
  local pile = self.piles[id]
  if not pile then
    local place = CreateFrame("Frame", nil, self.frame)
    place:SetFrameLevel(self.frame:GetFrameLevel() + PLACE_LEVEL)
    place:EnableMouse(true)
    place.outline = place:CreateTexture(nil, "BACKGROUND")
    place.outline:SetAllPoints()
    place.outline:SetTexture(private.Cards.SLOT)
    place.outline:SetVertexColor(1, 1, 1, OUTLINE)
    place.mark = place:CreateTexture(nil, "ARTWORK")
    place.mark:SetPoint("CENTER")
    place.mark:SetVertexColor(1, 1, 1, MARK)
    place.mark:Hide()
    place.light = newLight(place)
    pile = { id = id, x = 0, y = 0, held = {}, down = 0, place = place, rank = #self.order + 1 }
    place:SetScript("OnMouseDown", function(_, button)
      self:pressed(pile, nil, button)
    end)
    place:SetScript("OnEnter", function(entered)
      entered.hovered = pile.press == true and not self.carry
      relight(entered)
    end)
    place:SetScript("OnLeave", function(left)
      left.hovered = false
      relight(left)
    end)
    self.piles[id] = pile
    self.order[#self.order + 1] = pile
  end
  for key, value in pairs(options) do
    pile[key] = value
  end

  local place = pile.place
  place:SetSize(self.cardWidth, self.cardHeight)
  place:ClearAllPoints()
  place:SetPoint("TOPLEFT", self.frame, "TOPLEFT", pile.x, -pile.y)
  place.mark:SetShown(pile.mark ~= nil and pile.mark ~= false)
  if pile.mark then
    place.mark:SetTexture(pile.mark)
    place.mark:SetSize(self.cardWidth * 0.5, self.cardWidth * 0.5)
  end
  return pile
end

--- How big the table is. Say so before saying where the piles are
--- @param width number
--- @param height number
--- @param cardWidth number How big a card is on it
--- @param cardHeight number
function CardTable:SetSize(width, height, cardWidth, cardHeight)
  self.width, self.height, self.cardWidth, self.cardHeight = width, height, cardWidth, cardHeight
  self.frame:SetSize(width, height)
end

-----------------------------
-- Cards on the move
-----------------------------

--- A card that was on its way no longer is
--- @param sprite Frame
function CardTable:ground(sprite)
  sprite.flight = nil
  for index, flying in ipairs(self.flying) do
    if flying == sprite then
      table.remove(self.flying, index)
      return
    end
  end
end

--- Puts a card where it belongs, the way it lies there
--- @param sprite Frame
function CardTable:place(sprite)
  self:ground(sprite)
  sprite.x, sprite.y = sprite.homeX, sprite.homeY
  face(sprite, sprite.up)
  self:fit(sprite)
  sprite:SetFrameLevel(self.frame:GetFrameLevel() + PILE_LEVEL + sprite.index)
  sprite.shadow:Hide()
  sprite:Show()
  self:show(sprite)
end

--- Sends a card to where it belongs
--- @param sprite Frame
--- @param seconds number
--- @param options { delay: number?, raised: boolean?, sound: string? }? Seconds before it sets out, whether it leaves the table to get there, and what that sounds like
function CardTable:fly(sprite, seconds, options)
  options = options or {}
  self:ground(sprite)
  sprite.flight = { elapsed = -(options.delay or 0), seconds = seconds, raised = options.raised, sound = options.sound, started = false }
  self.flying[#self.flying + 1] = sprite
  if not options.raised then
    -- It stays in its pile, where it may have a new place among the others
    sprite:SetFrameLevel(self.frame:GetFrameLevel() + PILE_LEVEL + sprite.index)
  end
end

--- Sends everything that was let go of to where it belongs
--- @param sprites Frame[]
function CardTable:settle(sprites)
  for _, sprite in ipairs(sprites) do
    if sprite.pile and not sprite.flight then
      if sprite.x == sprite.homeX and sprite.y == sprite.homeY then
        self:place(sprite)
      else
        self:fly(sprite, RETURN, { raised = true })
      end
    end
  end
end

--- @param elapsed number
function CardTable:animate(elapsed)
  local level = self.frame:GetFrameLevel()
  local index = 1
  while self.flying[index] do
    local sprite = self.flying[index]
    local flight = sprite.flight
    flight.elapsed = flight.elapsed + elapsed
    if flight.elapsed < 0 then
      index = index + 1
    else
      if not flight.started then
        flight.started = true
        flight.fromX, flight.fromY = sprite.x, sprite.y
        flight.turns = sprite.showing ~= sprite.up
        -- Turning over where it lies takes the whole of it, on the way somewhere only the middle
        flight.turnFrom, flight.turnTo = TURN_FROM, TURN_TO
        if flight.fromX == sprite.homeX and flight.fromY == sprite.homeY then
          flight.turnFrom, flight.turnTo = 0, 1
        end
        local far = math.abs(flight.fromX - sprite.homeX) + math.abs(flight.fromY - sprite.homeY)
        flight.rise = flight.raised and RISE * self.cardHeight * math.min(1, far / (RISE_OVER * self.cardHeight)) or 0
        if flight.raised then
          -- Over everything that lies, and over whatever set out before it
          self.aloft = self.aloft + 1
          sprite:SetFrameLevel(level + ALOFT_LEVEL + math.min(self.aloft, ALOFT_MOST))
          sprite.shadow:Show()
        end
        private.Widgets.PlaySound(flight.sound)
      end

      local progress = flight.seconds > 0 and math.min(1, flight.elapsed / flight.seconds) or 1
      if progress >= 1 then
        self:place(sprite)
      else
        index = index + 1
        -- Fast at first, settling as it arrives. Where it is going is asked every time, the
        -- table may be another size by now
        local left = (1 - progress) ^ 3
        sprite.x = sprite.homeX + (flight.fromX - sprite.homeX) * left
        sprite.y = sprite.homeY + (flight.fromY - sprite.homeY) * left
        if flight.turns then
          -- Narrower until it is edge on, then wider again showing its other side
          local turn = math.max(0, math.min(1, (progress - flight.turnFrom) / (flight.turnTo - flight.turnFrom)))
          if turn >= 0.5 then
            face(sprite, sprite.up)
          end
          sprite:SetWidth(self.cardWidth * math.max(TURN_EDGE, math.abs(math.cos(turn * math.pi))))
        end
        self:show(sprite, 0, -flight.rise * math.sin(progress * math.pi))
      end
    end
  end
  if #self.flying == 0 and not self.fountain then
    self.aloft = 0
  end

  for position = #self.shaking, 1, -1 do
    local sprite = self.shaking[position]
    sprite.shake = sprite.shake + elapsed
    local left = 1 - sprite.shake / SHAKE
    if left <= 0 or not sprite.pile then
      sprite.shake = nil
      table.remove(self.shaking, position)
    end
    if sprite.pile and not sprite.flight then
      self:show(sprite, left > 0 and math.sin(sprite.shake * SHAKE_SPEED) * SHAKE_REACH * self.cardWidth * left or 0)
    end
  end

  if self.fountain then
    self:spout(math.min(elapsed, TOSS_STEP))
  end
end

-----------------------------
-- Fountain
-----------------------------

--- @param low number
--- @param high number
--- @return number Somewhere between the two. How a card falls is nobody's business but the eye's, the client's own dice will do
local function between(low, high)
  return low + (high - low) * math.random()
end

--- Throws cards off the table one after the other, to fall and bounce their way out of sight,
--- and has them back where they were when the last one is gone. A click on any card stops it
--- @param cards string[] In the order they go
--- @param delay number? Seconds before the first one does, for cards that have yet to arrive
function CardTable:Fountain(cards, delay)
  self:release()
  local height = self.cardHeight
  local tossed = {}
  for _, id in ipairs(cards) do
    local sprite = self.sprites[id]
    if sprite and sprite.pile and not sprite.toss then
      sprite.toss = {
        wait = (delay or 0) + #tossed * TOSS_GAP,
        across = between(unpack(TOSS_ACROSS)) * height * (math.random() < 0.5 and -1 or 1),
        down = -between(unpack(TOSS_UP)) * height,
      }
      tossed[#tossed + 1] = sprite
    end
  end
  if #tossed > 0 then
    self.fountain = { sprites = tossed }
  end
end

--- @param elapsed number
function CardTable:spout(elapsed)
  local fountain = self.fountain
  if fountain.back then
    -- They are all gone: here they are again
    fountain.back = fountain.back + elapsed
    local alpha = math.min(1, fountain.back / TOSS_BACK)
    for _, sprite in ipairs(fountain.sprites) do
      if sprite.pile then
        sprite:SetAlpha(alpha)
      end
    end
    if alpha >= 1 then
      self.fountain = nil
    end
    return
  end

  local width, height = self.cardWidth, self.cardHeight
  local floor = self.height - height / 2
  local left = 0
  for _, sprite in ipairs(fountain.sprites) do
    local toss = sprite.toss
    if toss then
      left = left + 1
      toss.wait = toss.wait - elapsed
      if toss.wait <= 0 then
        if not toss.started then
          toss.started = true
          -- From where it belongs, whether or not it had got there
          self:place(sprite)
          self.aloft = self.aloft + 1
          sprite:SetFrameLevel(self.frame:GetFrameLevel() + ALOFT_LEVEL + math.min(self.aloft, ALOFT_MOST))
        end
        toss.down = toss.down + GRAVITY * height * elapsed
        sprite.x, sprite.y = sprite.x + toss.across * elapsed, sprite.y + toss.down * elapsed
        if sprite.y > floor then
          sprite.y, toss.down = floor - (sprite.y - floor), -toss.down * BOUNCE
        end
        if sprite.x < -width or sprite.x > self.width + width then
          sprite.toss = nil
          sprite:SetAlpha(0)
        end
        self:show(sprite)
      end
    end
  end
  if left == 0 then
    for _, sprite in ipairs(fountain.sprites) do
      if sprite.pile then
        self:place(sprite)
        sprite:SetAlpha(0)
      end
    end
    fountain.back = 0
  end
end

-----------------------------
-- The player's hand
-----------------------------

--- Where the cursor is, from the top left corner of the table
--- @return number x, number y
function CardTable:cursor()
  local scale = self.frame:GetEffectiveScale()
  local x, y = GetCursorPosition()
  return x / scale - (self.frame:GetLeft() or 0), (self.frame:GetTop() or 0) - y / scale
end

--- Lights up the pile what is in hand would land on, the card on top of it or the place
--- itself, and no longer the one that was
--- @param carry table
--- @param pile CardTablePile?
function CardTable:mark(carry, pile)
  if carry.lit then
    carry.lit.target = false
    relight(carry.lit)
  end
  carry.over, carry.lit = pile, nil
  if pile then
    local top = pile.held[#pile.held]
    carry.lit = top and self.sprites[top] or pile.place
    carry.lit.target = true
    relight(carry.lit)
  end
end

--- The pile what is in hand would be put down on if it were let go right now: the one most of
--- it is over, of those it may go on
--- @param carry table
--- @return CardTablePile?
function CardTable:landing(carry)
  local width, height = self.cardWidth, self.cardHeight
  local lead = carry.sprites[1]
  local best, most = nil, 0
  for _, pile in ipairs(self.order) do
    if pile ~= carry.from then
      -- A pile is everything from its first card to where the next one would lie
      local first, last = pile.spots[1], pile.spots[#pile.spots]
      local across = math.min(lead.x, math.max(first.x, last.x)) - math.max(lead.x, math.min(first.x, last.x)) + width
      local down = math.min(lead.y, math.max(first.y, last.y)) - math.max(lead.y, math.min(first.y, last.y)) + height
      if across > 0 and down > 0 and across * down > most and self.canDrop and self.canDrop(carry.from.id, carry.index, pile.id) then
        best, most = pile, across * down
      end
    end
  end
  return best
end

--- A button went down on a card, or on a place with no card on it
--- @param pile CardTablePile
--- @param index number?
--- @param button string
function CardTable:pressed(pile, index, button)
  if self.fountain then
    -- Seen enough
    self:Stop()
    return
  end
  if button ~= "LeftButton" then
    -- Any other button puts back what is in hand
    if self.carry then
      self:release()
    elseif self.onRightClick then
      self.onRightClick(pile.id, index)
    end
    return
  end
  local x, y = self:cursor()
  local lift = index ~= nil and self.canLift ~= nil and self.canLift(pile.id, index)
  self.press = { pile = pile, index = index, x = x, y = y, lift = lift }
end

--- What the button went down on comes off the table, and everything that lies on it with it
--- @param press table
function CardTable:pickUp(press)
  local pile = press.pile
  local carry = { from = pile, index = press.index, sprites = {} }
  for index = press.index, #pile.held do
    local sprite = self.sprites[pile.held[index]]
    self:ground(sprite)
    face(sprite, sprite.up)
    self:fit(sprite)
    -- Held where it was taken hold of
    sprite.gripX, sprite.gripY = sprite.x - press.x, sprite.y - press.y
    sprite.hovered = false
    relight(sprite)
    sprite.shadow:Show()
    sprite:SetFrameLevel(self.frame:GetFrameLevel() + CARRIED_LEVEL + #carry.sprites)
    carry.sprites[#carry.sprites + 1] = sprite
  end
  self.carry = carry
end

--- Follows the cursor with what is in hand, and lets go of it when the button is let go
function CardTable:follow()
  local press = self.press
  if not press then
    return
  end
  local x, y = self:cursor()
  if not self.carry and press.lift and math.abs(x - press.x) + math.abs(y - press.y) > DRAG_DISTANCE then
    self:pickUp(press)
  end

  local carry = self.carry
  if carry then
    for _, sprite in ipairs(carry.sprites) do
      sprite.x, sprite.y = x + sprite.gripX, y + sprite.gripY
      self:show(sprite)
    end
    local over = self:landing(carry)
    if over ~= carry.over then
      self:mark(carry, over)
    end
  end

  if IsMouseButtonDown("LeftButton") then
    return
  end
  self.press, self.carry = nil, nil
  if not carry then
    -- Let go where it went down: a click
    if self.onClick then
      self.onClick(press.pile.id, press.index)
    end
    return
  end
  local over = carry.over
  self:mark(carry, nil)
  if over and self.onDrop then
    self.onDrop(carry.from.id, carry.index, over.id)
  end
  -- Whatever the game didn't find a new place for goes back
  self:settle(carry.sprites)
end

--- @param elapsed number
function CardTable:advance(elapsed)
  self:animate(elapsed)
  self:follow()
end

-----------------------------
-- Public
-----------------------------

--- Says which cards are in which pile. Whatever that changes about what was on the table is
--- shown happening, see above. Saying the same again changes nothing and disturbs nothing
--- @param piles table<string, CardTableCards> By pile. A pile that is left out has no cards
--- @param how { instant: boolean?, sequence: string[]?, gap: number?, sound: string? }? `instant` to have it all there at once. `sequence` for cards that set out one after the other, `gap` seconds apart, instead of at the same moment: named in the order they go, a card that isn't named doesn't wait. `sound` is what a card leaving for another pile sounds like, heard once for those that leave together
function CardTable:Set(piles, how)
  how = how or {}
  local positions = {}
  for position, id in ipairs(how.sequence or {}) do
    positions[id] = position
  end

  local onTable, movers, fresh = {}, {}, {}
  for _, pile in ipairs(self.order) do
    local content = piles[pile.id]
    pile.held = { unpack(content and content.cards or {}) }
    pile.down = content and content.down or 0
    pile.spots = self:spots(pile)
    for index, id in ipairs(pile.held) do
      local sprite = self:spriteFor(id)
      local spot, up = pile.spots[index], index > pile.down
      local hopped = sprite.pile ~= pile or sprite.index ~= index
      local changed = hopped or sprite.homeX ~= spot.x or sprite.homeY ~= spot.y or sprite.up ~= up
      onTable[id] = true
      if sprite.pile == nil then
        fresh[#fresh + 1] = sprite
      elseif changed then
        movers[#movers + 1] = { sprite = sprite, hopped = hopped, moved = sprite.homeX ~= spot.x or sprite.homeY ~= spot.y, position = positions[id] or 0 }
      end
      sprite.pile, sprite.index, sprite.homeX, sprite.homeY, sprite.up = pile, index, spot.x, spot.y, up
    end
  end
  local gone = false
  for id, sprite in pairs(self.sprites) do
    if not onTable[id] then
      gone = true
      self:discard(sprite)
    end
  end

  if how.instant then
    self:Stop()
    return
  end
  for _, sprite in ipairs(fresh) do
    self:place(sprite)
  end
  if #movers == 0 and not gone then
    return
  end

  -- The table is no longer what the player had hold of, or what was being thrown about
  self:release()
  -- In the order they are to go, and those that go together from the bottom of a pile up, so
  -- that each lands on the one before
  table.sort(movers, function(a, b)
    if a.position ~= b.position then
      return a.position < b.position
    elseif a.sprite.pile ~= b.sprite.pile then
      return a.sprite.pile.rank < b.sprite.pile.rank
    end
    return a.sprite.index < b.sprite.index
  end)
  local gap = how.gap or SEQUENCE_GAP
  local every = #(how.sequence or {}) > QUIET and 2 or 1
  local heard = false
  for _, mover in ipairs(movers) do
    local sprite = mover.sprite
    local delay = math.max(0, mover.position - 1) * gap
    if mover.hopped then
      local sound = nil
      if mover.position > 0 then
        sound = mover.position % every == 0 and how.sound or nil
      elseif not heard then
        heard, sound = true, how.sound
      end
      self:fly(sprite, FLIGHT, { delay = delay, raised = true, sound = sound })
    elseif mover.moved then
      self:fly(sprite, SHIFT, { delay = delay })
    else
      self:fly(sprite, TURN, { delay = delay + TURN_AFTER })
    end
  end
  -- Whatever goes at once is on its way before the table is next drawn
  self:animate(0)
end

--- Lets go of whatever the player is holding and ends a fountain, without anything being moved
function CardTable:release()
  local carry = self.carry
  self.press, self.carry = nil, nil
  if carry then
    self:mark(carry, nil)
    self:settle(carry.sprites)
  end
  local fountain = self.fountain
  if fountain then
    self.fountain = nil
    for _, sprite in ipairs(fountain.sprites) do
      sprite.toss = nil
      sprite:SetAlpha(1)
      if sprite.pile then
        self:place(sprite)
      end
    end
  end
end

--- Has everything where it belongs at once: cards on their way arrive, what is in hand goes back
function CardTable:Stop()
  self:release()
  for _, sprite in pairs(self.sprites) do
    self:place(sprite)
  end
  self.aloft = 0
end

--- Whether anything is still on its way, or being thrown about
--- @return boolean
function CardTable:Busy()
  return #self.flying > 0 or self.fountain ~= nil
end

--- Has a card shake its head, for one the player wanted to move that has nowhere to go
--- @param id string
function CardTable:Refuse(id)
  local sprite = self.sprites[id]
  if sprite and sprite.pile and not sprite.shake then
    sprite.shake = 0
    self.shaking[#self.shaking + 1] = sprite
  end
end
