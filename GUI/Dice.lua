--------------------------
--  Dice
--------------------------
-- Dice on a table. They are thrown across it tumbling and bouncing, and come to rest a little
-- askew, each over its shadow. What they show was settled before they ever left the hand
-- (Engine/Random.lua): all of this is for the eye, and every client throws them its own way.
--
-- A game shows the roll there is with Show, as often as it likes: the same roll stays where it
-- came to rest, with the dice that are used up drawn small and grey, and a new one is a new roll.
-- Then it throws it, or for a roll of the player's own puts it in their hand: the dice wait
-- there until the player clicks anywhere on the table, shaking for as long as the button is
-- held, and fly when it is let go.
--
-- The dice of a roll lie in a row, or where the game puts each of them, or wherever they fall
-- in a part of the table, out of each other's way. One the game moves somewhere else glides
-- there. A game can have the dice clicked, and can pick some of them up off the table to be
-- shaken and thrown again (Grab and Release), for one where dice are kept and the rest rolled.
--
-- Nothing here knows any game. See Games/Backgammon.lua and Games/Yacht.lua.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L

--- What a game wants on the table. Places are in pixels, right and down from the top left
--- corner of what the dice lie on
--- @class DiceRoll
--- @field key any Which roll it is: the same key keeps the dice where they came to rest, another is a new roll
--- @field faces number[] What each die rolled. Shown again with other faces under the same key, the dice thrown since show those
--- @field color string Which dice they are: "white" or "red"
--- @field size number Side of a die
--- @field from { x: number, y: number } Where they are thrown from, and held until then
--- @field x number? Where the middle of the row comes to rest, for dice the roll doesn't put anywhere else
--- @field y number?
--- @field gap number? Between two dice in the row, a fifth of a die if left out
--- @field area { x: number, y: number, width: number, height: number }? Where dice fall instead of in a row: anywhere in it, out of each other's way
--- @field spots table<number, { x: number, y: number }>? Where some dice lie instead, straight, by place in the roll
--- @field thrown number? How many of them are thrown, all if left out. The rest are the same again, put down beside them once they have come to rest: doubles, played four times
--- @field spent boolean[]? Dice that are used up, by place in the roll
--- @field glow boolean? Something to cheer about: they light up as they come to rest

--- @class Die
--- @field face Texture
--- @field shadow Texture
--- @field glow Texture
--- @field button Button To click it by, while it lies still and the game wants it clicked
--- @field value number What it rolled
--- @field shown number The face it shows now
--- @field where "rest"|"hand"|"air"|"waiting" Waiting is for a die put down once the others are thrown
--- @field slot string? What says where it lies: its spot, or the row or area
--- @field gliding boolean? On its way from one place to another on the table
--- @field hover boolean? The cursor is over it
--- @field askew number Radians it comes to rest turned by, where it isn't put straight
--- @field dx number How far from its place in the row it comes to rest, in dice
--- @field dy number
--- @field ax number? Where in the area it lies, as a part of its width
--- @field ay number?
--- @field spent number 1 for a die that is used up, 0 for one that isn't, in between while it changes
--- @field target number What spent is on its way to
--- @field x number Where it was last drawn, its angle and how high
--- @field y number
--- @field angle number
--- @field height number
--- @field turn number? In hand: radians it is turned by, before it rocks
--- @field grab number? In hand: how far along it is from where it was picked up, 1 once there
--- @field gx number? Where it was picked up from
--- @field gy number?
--- @field jx number? Shaken: how far it was jolted, in dice and radians
--- @field jy number?
--- @field jolt number?

--- @class Dice
--- @field frame Frame Lies over everything of the frame it was made for
--- @field roll DiceRoll? What is on the table
--- @field held { onThrow: fun()?, time: number, shake: number, whole: boolean? }? There are dice in the player's hand, the whole roll if they were put there to be thrown
--- @field onClick fun(index: number)?
--- @field onLanded fun()?
local Dice = {}
Dice.__index = Dice
private.Dice = Dice

local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\"
-- A die fills this much of its texture, which leaves it room to turn (Tools/convert_kenney.py)
local DIE_FILL = 88 / 128
-- Seconds a throw takes, give or take, and how much later each die leaves the hand than the one before
local THROW, THROW_SPREAD, THROW_STAGGER = 0.85, 0.1, 0.05
-- When a die touches down, as how far into the throw, and how high it goes before each, in
-- dice. After the last it slides to a stop
local BOUNCES = { 0.4, 0.67, 0.84 }
local HEIGHTS = { 1.1, 0.4, 0.12 }
-- From this touch down on a die shows what it rolled: the last hops are on its own face
local SETTLED = 2
-- How much bigger a die is drawn for every die's height it is above the table
local LIFT = 0.4
-- Its shadow: how dark it is under a die on the table, how much it fades and how far it falls
-- away for every die's height the die is above it, in dice. The light comes from the top left
local SHADOW_ALPHA, SHADOW_FADE = 0.45, 0.25
local SHADOW_OFFSET, SHADOW_DROP, SHADOW_GROW = 0.06, 0.35, 0.15
-- Seconds between one face and the next as it tumbles
local TUMBLE_FACE = 0.06
-- Turns it makes on the way, give or take
local SPIN, SPIN_SPREAD = 1.6, 0.7
-- How far askew it comes to rest, in radians, and how far from its place in a row, in dice
local ASKEW, ASTRAY = 0.2, 0.08
-- How far its path bends to the side, in dice
local CURVE = 0.5
-- How the path slows down: the higher, the sooner it is mostly there
local SLOWING = 2.2
-- Falling in an area: how far apart two dice want to be and how far in from its edge, in dice,
-- and how many places are tried for one before it takes the roomiest of them
local APART, EDGE, TRIES = 1.6, 0.75, 40
-- A die moved on the table: seconds it takes, and how high it is lifted on the way, in dice
local GLIDE_SECONDS, GLIDE_LIFT = 0.25, 0.35
-- How much bigger a die is drawn under the cursor, when it can be clicked
local HOVER_SCALE = 1.08
-- A die that is used up: how small, how faint, and seconds it takes to get that way
local SPENT_SCALE, SPENT_ALPHA, SPENT_SECONDS = 0.8, 0.4, 0.2
-- Dice put down after a throw: seconds each takes, from how small, and how long after the one before
local EXTRA_SECONDS, EXTRA_FROM, EXTRA_STAGGER = 0.25, 0.4, 0.08
-- The light of a roll to cheer about: seconds, how big around a die, and its colour
local GLOW_SECONDS, GLOW_SIZE = 0.8, 2.4
local GLOW_COLOR = { 1, 0.85, 0.35 }
-- In the hand: how big the dice are, how far apart, how high, and how much they rock and bob
local HAND_SCALE, HAND_GAP, HAND_LIFT, HAND_STAGGER = 0.9, 0.62, 0.15, 0.12
local ROCK, BOB = 0.12, 0.05
-- Seconds a die picked up off the table takes to get to the hand
local GRAB_SECONDS = 0.12
-- Shaken: how far each way, in dice and radians, seconds between one jolt and the next, and how high
local SHAKE, SHAKE_TURN, SHAKE_STEP, SHAKE_LIFT = 0.14, 0.4, 0.05, 0.35
local SHAKE_SOUND, THROW_SOUND = "dieShuffle", "dieThrow"

--- @param range number
--- @return number Anywhere from -range to range. How the dice fly is nobody's business but the eye's, the client's own dice will do
local function spread(range)
  return (math.random() * 2 - 1) * range
end

--- A face other than the one shown
--- @param shown number?
--- @return number
local function another(shown)
  local face = math.random(5)
  return shown and face >= shown and face + 1 or face
end

--- @param parent Frame What they lie on: a game's table
--- @return Dice
function Dice.New(parent)
  local Widgets = private.Widgets
  --- @type Dice
  local self = setmetatable({ dice = {} }, Dice)
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetAllPoints()
  frame:SetFrameLevel(parent:GetFrameLevel() + 10)
  self.frame = frame
  self.animator = Widgets.Animator(frame)

  -- The whole table is there to click while the dice wait in hand: nothing else on it can be
  -- played before they are thrown
  local hand = CreateFrame("Button", nil, frame)
  hand:SetAllPoints()
  hand:SetFrameLevel(frame:GetFrameLevel() + 1)
  hand:Hide()
  hand:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" then
      self:shake()
    end
  end)
  hand:SetScript("OnMouseUp", function()
    self:Release()
  end)
  self.hand = hand
  self.prompt = Widgets.Label(hand, "GameFontHighlightLarge", L["dice_roll"])
  self.prompt:SetTextColor(unpack(Widgets.GOLD))
  self.pulse = Widgets.Pulse(self.prompt)

  -- Keeps the dice in hand moving. Apart from the hand, so that what takes the mouse doesn't
  -- also take every frame
  self.ticker = CreateFrame("Frame", nil, frame)
  self.ticker:Hide()
  self.ticker:SetScript("OnUpdate", function(_, elapsed)
    self:tick(elapsed)
  end)

  -- What was on its way when the table was hidden has got there by the time it is shown again,
  -- and dice being shaken are held still
  frame:SetScript("OnHide", function()
    self.animator:Stop()
    self:still()
  end)
  return self
end

--- The widgets of a die, made the first time there are that many
--- @param index number
--- @return Die
function Dice:die(index)
  local die = self.dice[index]
  if not die then
    -- Later dice lie over earlier ones, every shadow under every die
    local face = self.frame:CreateTexture(nil, "ARTWORK", nil, math.min(index, 7))
    local shadow = self.frame:CreateTexture(nil, "BORDER")
    shadow:SetTexture(IMAGES .. "Dice\\shadow")
    shadow:SetVertexColor(0, 0, 0)
    local glow = self.frame:CreateTexture(nil, "BORDER", nil, 1)
    glow:SetTexture(IMAGES .. "glow")
    glow:SetBlendMode("ADD")
    glow:SetVertexColor(unpack(GLOW_COLOR))
    -- Over the hand, so that dice on the table can be clicked while the rest are shaken
    local button = CreateFrame("Button", nil, self.frame)
    button:SetFrameLevel(self.frame:GetFrameLevel() + 2)
    button:Hide()
    die = { face = face, shadow = shadow, glow = glow, button = button, value = 1, shown = 1, where = "rest" }
    die.askew, die.dx, die.dy, die.spent, die.target = 0, 0, 0, 0, 0
    die.x, die.y, die.angle, die.height = 0, 0, 0, 0
    button:SetScript("OnClick", function()
      if self.onClick and die.where == "rest" and not die.gliding then
        self.onClick(index)
      end
    end)
    button:SetScript("OnEnter", function()
      die.hover = true
      self:settle(index)
    end)
    button:SetScript("OnLeave", function()
      die.hover = false
      self:settle(index)
    end)
    self.dice[index] = die
  end
  return die
end

--- @param die Die
local function hideDie(die)
  die.face:Hide()
  die.shadow:Hide()
  die.glow:Hide()
  die.button:Hide()
end

--- @return number How many of the roll are thrown at once
function Dice:thrown()
  local roll = self.roll
  return math.min(roll.thrown or #roll.faces, #roll.faces)
end

--- What says where a die of the roll lies
--- @param index number
--- @return string
function Dice:slotOf(index)
  local roll = self.roll
  if roll.spots and roll.spots[index] then
    return "spot"
  end
  return roll.area and "area" or "row"
end

--- Somewhere in the area for a die to fall, as far from the others there as it can have
--- @param index number
function Dice:scatter(index)
  local roll, die = self.roll, self.dice[index]
  local area, size = roll.area, roll.size
  local edgeX = math.min(0.5, size * EDGE / math.max(1, area.width))
  local edgeY = math.min(0.5, size * EDGE / math.max(1, area.height))
  local roomiest, bestX, bestY = -1, 0.5, 0.5
  for _ = 1, TRIES do
    local x = edgeX + math.random() * (1 - 2 * edgeX)
    local y = edgeY + math.random() * (1 - 2 * edgeY)
    local nearest = math.huge
    for other = 1, #roll.faces do
      local there = self.dice[other]
      if other ~= index and there.ax and self:slotOf(other) == "area" then
        local apartX, apartY = (x - there.ax) * area.width, (y - there.ay) * area.height
        nearest = math.min(nearest, math.sqrt(apartX * apartX + apartY * apartY))
      end
    end
    if nearest > roomiest then
      roomiest, bestX, bestY = nearest, x, y
    end
    if nearest >= size * APART then
      break
    end
  end
  die.ax, die.ay = bestX, bestY
end

--- Where a die comes to rest
--- @param index number
--- @return number x, number y
function Dice:place(index)
  local roll, die = self.roll, self.dice[index]
  local slot = self:slotOf(index)
  if slot == "spot" then
    local spot = roll.spots[index]
    return spot.x, spot.y
  elseif slot == "area" then
    if not die.ax then
      self:scatter(index)
    end
    local area = roll.area
    return area.x + die.ax * area.width, area.y + die.ay * area.height
  end
  local size = roll.size
  local step = size + (roll.gap or size * 0.2)
  return (roll.x or 0) + (index - (#roll.faces + 1) / 2) * step + die.dx * size, (roll.y or 0) + die.dy * size
end

--- How a die is turned where it comes to rest: put somewhere, it lies straight
--- @param index number
--- @return number
function Dice:angleOf(index)
  return self:slotOf(index) == "spot" and 0 or self.dice[index].askew
end

--- Puts a die somewhere, over its shadow
--- @param die Die
--- @param x number
--- @param y number
--- @param angle number Radians
--- @param height number Above the table, in dice
--- @param scale number? On top of what height and being used up make of it
function Dice:draw(die, x, y, angle, height, scale)
  local roll = self.roll
  local size = roll.size
  local spent = die.spent
  local shrink = (1 - (1 - SPENT_SCALE) * spent) * (scale or 1)
  local alpha = 1 - (1 - SPENT_ALPHA) * spent
  die.x, die.y, die.angle, die.height = x, y, angle, height

  local face = die.face
  local side = size / DIE_FILL * (1 + LIFT * height) * shrink
  face:SetTexture(IMAGES .. "Dice\\" .. roll.color .. die.shown)
  face:SetSize(side, side)
  face:ClearAllPoints()
  face:SetPoint("CENTER", self.frame, "TOPLEFT", x, -y)
  face:SetRotation(angle)
  face:SetAlpha(alpha)
  face:SetDesaturated(spent > 0.5)
  face:Show()

  local shadow = die.shadow
  local away = (SHADOW_OFFSET + SHADOW_DROP * height) * size * shrink
  side = size / DIE_FILL * (1 + SHADOW_GROW * height) * shrink
  shadow:SetSize(side, side)
  shadow:ClearAllPoints()
  shadow:SetPoint("CENTER", self.frame, "TOPLEFT", x + away, -y - away)
  shadow:SetRotation(angle)
  shadow:SetAlpha(math.max(0, SHADOW_ALPHA - SHADOW_FADE * height) * alpha)
  shadow:Show()
end

--- Draws a die where it came to rest, there to be clicked if the game wants that
--- @param index number
--- @param scale number?
function Dice:rest(index, scale)
  local die = self.dice[index]
  local x, y = self:place(index)
  local clickable = self.onClick ~= nil and not die.gliding
  self:draw(die, x, y, self:angleOf(index), 0, (scale or 1) * ((clickable and die.hover) and HOVER_SCALE or 1))
  local button = die.button
  button:SetShown(clickable)
  if clickable then
    button:SetSize(self.roll.size, self.roll.size)
    button:ClearAllPoints()
    button:SetPoint("CENTER", self.frame, "TOPLEFT", x, -y)
  end
end

--- Draws a die again if it is lying still, as it is now
--- @param index number
function Dice:settle(index)
  local die = self.dice[index]
  if self.roll and index <= #self.roll.faces and die.where == "rest" and not die.gliding then
    self:rest(index)
  end
end

--- Moves a die lying on the table to where it lies now, lifting it on the way
--- @param index number
function Dice:glide(index)
  local die = self.dice[index]
  local fromX, fromY, fromAngle = die.x, die.y, die.angle
  die.gliding = true
  die.button:Hide()
  self.animator:Play(GLIDE_SECONDS, function(progress)
    local x, y = self:place(index)
    local angle = fromAngle + (self:angleOf(index) - fromAngle) * progress
    local lift = GLIDE_LIFT * math.sin(math.pi * progress)
    self:draw(die, fromX + (x - fromX) * progress, fromY + (y - fromY) * progress, angle, lift)
  end, {
    ease = private.Widgets.Ease.out,
    onDone = function()
      die.gliding = false
      self:settle(index)
    end,
  })
end

--- Puts a roll on the table, or takes it off with nil. Shown again, a roll stays as it is but for
--- what changed: dice put somewhere else glide there, and dice used up are told apart
--- @param roll DiceRoll?
function Dice:Show(roll)
  local before = self.roll
  local same = roll and before and before.key == roll.key and #before.faces == #roll.faces
  if not same then
    -- The roll that was there has come to rest before it goes
    self.animator:Stop()
    self:letGo()
    for _, die in ipairs(self.dice) do
      hideDie(die)
      die.where = "rest"
    end
  end
  self.roll = roll
  if not roll then
    return
  end

  -- Each needs the others there to fall out of their way
  for index = 1, #roll.faces do
    self:die(index)
  end
  for index, value in ipairs(roll.faces) do
    local die = self:die(index)
    local spent = roll.spent and roll.spent[index] and 1 or 0
    local slot = self:slotOf(index)
    die.value = value
    if not same then
      die.shown, die.slot, die.gliding = value, slot, false
      die.askew, die.dx, die.dy, die.ax, die.ay = spread(ASKEW), spread(ASTRAY), spread(ASTRAY), nil, nil
      die.spent, die.target = spent, spent
    else
      if die.target ~= spent then
        -- Used up or given back: it gets there over a moment
        local from = die.spent
        die.target = spent
        if die.where == "rest" then
          self.animator:Play(SPENT_SECONDS, function(progress)
            die.spent = from + (spent - from) * progress
            self:settle(index)
          end, { ease = private.Widgets.Ease.out })
        else
          die.spent = spent
        end
      end
      if die.slot ~= slot then
        die.slot = slot
        if slot == "area" then
          die.askew, die.ax, die.ay = spread(ASKEW), nil, nil
        end
        if die.where == "rest" and not die.gliding then
          die.shown = value
          self:glide(index)
        end
      end
    end
    if die.where == "rest" and not die.gliding then
      die.shown = value
      self:rest(index)
    end
  end
  if self.held then
    self:tick(0)
  end
end

--- Takes the dice off the table
function Dice:Hide()
  self:Show(nil)
end

--- Has the dice clicked while they lie still, or no longer with nil
--- @param onClick fun(index: number)?
function Dice:SetClick(onClick)
  self.onClick = onClick
  if self.roll then
    for index = 1, #self.roll.faces do
      self:settle(index)
    end
  end
end

--- Puts the roll that is shown in the player's hand, for them to throw by clicking the table
--- @param onThrow fun() Called as the player throws them
--- @param prompt string? What the table says meanwhile, "Click to roll" if left out
function Dice:Hold(onThrow, prompt)
  if not self.roll then
    return
  end
  self.held = { onThrow = onThrow, time = 0, shake = 0, whole = true }
  for index, die in ipairs(self.dice) do
    hideDie(die)
    if index > #self.roll.faces or index > self:thrown() then
      die.where = "waiting"
    else
      die.where, die.shown, die.turn, die.grab = "hand", another(), spread(ROCK * 2), 1
      die.jx, die.jy, die.jolt = 0, 0, 0
    end
  end
  self.prompt:SetText(prompt or L["dice_roll"])
  self.hand:Show()
  self.prompt:Show()
  self.pulse:Play()
  self.ticker:Show()
  self:tick(0)
end

--- Picks dice up off the table into the player's hand and shakes them there, until Release
--- @param only table<number, boolean> Which, by place in the roll. Only those lying still are picked up
--- @param onThrow fun()? Called as they are thrown
function Dice:Grab(only, onThrow)
  if not self.roll or self.shaking then
    return
  end
  local any = false
  for index in pairs(only) do
    local die = self.dice[index]
    if die and index <= #self.roll.faces and die.where == "rest" and not die.gliding then
      die.where, die.grab, die.gx, die.gy, die.turn = "hand", 0, die.x, die.y, die.angle
      die.jx, die.jy, die.jolt = 0, 0, 0
      die.button:Hide()
      any = true
    end
  end
  if not any then
    return
  end
  self.held = { onThrow = onThrow, time = 0, shake = 0 }
  self.ticker:Show()
  self:shake()
end

--- Throws what is shaken in the hand, if anything is
function Dice:Release()
  if not self.shaking then
    return
  end
  local onThrow = self.held and self.held.onThrow
  self:Throw()
  if onThrow then
    onThrow()
  end
end

--- Whether there are dice in the player's hand
--- @return boolean
function Dice:Holding()
  return self.held ~= nil
end

--- Whether there are dice in the air
--- @return boolean
function Dice:Flying()
  if self.roll then
    for index = 1, #self.roll.faces do
      if self.dice[index].where == "air" then
        return true
      end
    end
  end
  return false
end

--- Has something done whenever the dice of a throw have all come to rest, or no longer with nil.
--- It mustn't put another roll on the table
--- @param onLanded fun()?
function Dice:OnLanded(onLanded)
  self.onLanded = onLanded
end

--- Whether anything is still on the move. Dice in hand aren't
--- @return boolean
function Dice:Busy()
  return self.animator:Busy()
end

--- Takes everything to its end at once
function Dice:Stop()
  self.animator:Stop()
end

--- Moves the dice in hand along
--- @param elapsed number
function Dice:tick(elapsed)
  local held, roll = self.held, self.roll
  if not held or not roll then
    return
  end
  held.time = held.time + elapsed
  local size = roll.size

  local jolted = false
  if self.shaking then
    held.shake = held.shake + elapsed
    jolted = held.shake >= SHAKE_STEP
    if jolted then
      held.shake = 0
    end
  end
  local inHand = {}
  for index = 1, #roll.faces do
    if self.dice[index].where == "hand" then
      inHand[#inHand + 1] = index
    end
  end
  for place, index in ipairs(inHand) do
    local die = self.dice[index]
    local x = roll.from.x + (place - (#inHand + 1) / 2) * HAND_GAP * size
    local y = roll.from.y + (place % 2 == 0 and HAND_STAGGER or -HAND_STAGGER) * size
    local angle = die.turn + ROCK * math.sin(held.time * 2.4 + index * 1.7)
    local height = HAND_LIFT + BOB * math.sin(held.time * 3.1 + index)
    if self.shaking then
      if jolted then
        die.jx, die.jy, die.jolt = spread(SHAKE), spread(SHAKE), spread(SHAKE_TURN)
        if math.random() < 0.5 then
          die.shown = another(die.shown)
        end
      end
      x, y, angle, height = x + die.jx * size, y + die.jy * size, angle + die.jolt, SHAKE_LIFT
    end
    if die.grab < 1 then
      -- Still on its way up from the table
      die.grab = math.min(1, die.grab + elapsed / GRAB_SECONDS)
      local along = private.Widgets.Ease.out(die.grab)
      x, y, height = die.gx + (x - die.gx) * along, die.gy + (y - die.gy) * along, height * along
    end
    self:draw(die, x, y, angle, height, HAND_SCALE)
  end

  local promptX, promptY = roll.x, roll.y
  if roll.area then
    promptX, promptY = roll.area.x + roll.area.width / 2, roll.area.y + roll.area.height / 2
  end
  self.prompt:ClearAllPoints()
  self.prompt:SetPoint("CENTER", self.frame, "TOPLEFT", promptX or 0, -(promptY or 0))
end

--- The button went down: the dice in hand are shaken until it comes up again
function Dice:shake()
  if not self.held or self.shaking then
    return
  end
  self.shaking = true
  self.held.shake = SHAKE_STEP
  self.pulse:Stop()
  self.prompt:Hide()
  self.rattle = private.Widgets.PlaySound(SHAKE_SOUND)
end

--- Stops the shaking. Dice that wait in hand go on waiting, dice picked up off the table are put
--- back down
function Dice:still()
  if not self.shaking then
    return
  end
  self.shaking = false
  private.Widgets.StopSound(self.rattle)
  self.rattle = nil
  if self.hand:IsShown() then
    self.prompt:Show()
    self.pulse:Play()
    return
  end
  self.held = nil
  self.ticker:Hide()
  if self.roll then
    for index = 1, #self.roll.faces do
      local die = self.dice[index]
      if die.where == "hand" then
        die.where = "rest"
        self:glide(index)
      end
    end
  end
end

--- Puts the hand away. What is in it stays where it is until it is thrown or a new roll comes
function Dice:letGo()
  if self.shaking then
    self.shaking = false
    private.Widgets.StopSound(self.rattle)
    self.rattle = nil
  end
  self.held = nil
  self.pulse:Stop()
  self.hand:Hide()
  self.ticker:Hide()
end

--- Throws dice: whatever is in the player's hand, or else the ones said, or else the whole roll
--- from where the roll says it is thrown from
--- @param delay number? Seconds to wait first
--- @param only table<number, boolean>? Which, by place in the roll
function Dice:Throw(delay, only)
  local roll = self.roll
  if not roll then
    return
  end
  local going, count, fromHand = {}, 0, false
  for index = 1, #roll.faces do
    if self.dice[index].where == "hand" then
      going[index], fromHand = true, true
    end
  end
  -- A whole roll: what isn't thrown is put down beside it once it lands
  local whole = (fromHand and self.held ~= nil and self.held.whole) or (not fromHand and not only)
  if not fromHand then
    for index = 1, #roll.faces do
      going[index] = (only and only[index]) or (whole and index <= self:thrown()) or nil
    end
  end
  self:letGo()

  -- Where they fall is found before any of them leaves: each out of the others' way
  for index in pairs(going) do
    count = count + 1
    local die = self.dice[index]
    die.askew, die.dx, die.dy, die.ax, die.ay = spread(ASKEW), spread(ASTRAY), spread(ASTRAY), nil, nil
  end
  for index in pairs(going) do
    if self:slotOf(index) == "area" then
      self:scatter(index)
    end
  end

  local size = roll.size
  local left, sounded, order = count, false, 0
  for index = 1, #roll.faces do
    local die = self.dice[index]
    if going[index] then
      order = order + 1
      local fromX, fromY, angle, lift = die.x, die.y, die.angle, die.height
      if die.where ~= "hand" then
        fromX = roll.from.x + (order - (count + 1) / 2) * HAND_GAP * size
        fromY, angle, lift = roll.from.y, spread(math.pi), SHAKE_LIFT
        hideDie(die)
      end
      die.where, die.gliding = "air", false
      die.button:Hide()
      local seconds = THROW + spread(THROW_SPREAD)
      -- It turns all the way from how it left the hand to how it comes to rest
      local turns = (SPIN + spread(SPIN_SPREAD)) * (math.random() < 0.5 and -1 or 1)
      local spin = angle - self:angleOf(index) + turns * 2 * math.pi
      local bend = spread(CURVE)
      local tumbled = -1

      self.animator:Play(seconds, function(progress)
        local toX, toY = self:place(index)
        local along = 1 - (1 - progress) ^ SLOWING
        local acrossX, acrossY = toX - fromX, toY - fromY
        local length = math.max(1, math.sqrt(acrossX * acrossX + acrossY * acrossY))
        local aside = bend * size * math.sin(math.pi * along)
        local x = fromX + acrossX * along - acrossY / length * aside
        local y = fromY + acrossY * along + acrossX / length * aside

        -- Which hop it is on, and how high it is on it
        local height, hop, start = 0, #BOUNCES + 1, 0
        for bounce, at in ipairs(BOUNCES) do
          if progress < at then
            local part = (progress - start) / (at - start)
            height = 4 * HEIGHTS[bounce] * part * (1 - part) + (bounce == 1 and lift * (1 - part) or 0)
            hop = bounce
            break
          end
          start = at
        end
        if hop > 1 and not sounded then
          -- The first die to hit the table is heard
          sounded = true
          private.Widgets.PlaySound(THROW_SOUND)
        end
        if hop > SETTLED then
          die.shown = die.value
        else
          local face = math.floor(progress * seconds / TUMBLE_FACE)
          if face ~= tumbled then
            tumbled = face
            die.shown = another(die.shown)
          end
        end
        self:draw(die, x, y, self:angleOf(index) + spin * (1 - progress) ^ 2, height)
      end, {
        delay = (delay or 0) + (order - 1) * THROW_STAGGER,
        onDone = function()
          die.where, die.shown, die.slot = "rest", die.value, self:slotOf(index)
          self:rest(index)
          left = left - 1
          if left == 0 then
            self:landed(whole)
          end
        end,
      })
    elseif whole then
      die.where = "waiting"
      hideDie(die)
    end
  end
end

--- The thrown dice have all come to rest: the rest of a whole roll is put down beside them, and
--- a roll to cheer about lights up
--- @param whole boolean
function Dice:landed(whole)
  local roll = self.roll
  local thrown = self:thrown()
  if whole then
    for index = thrown + 1, #roll.faces do
      local die = self.dice[index]
      die.where, die.shown = "rest", die.value
      self.animator:Play(EXTRA_SECONDS, function(progress)
        self:rest(index, EXTRA_FROM + (1 - EXTRA_FROM) * progress)
      end, { ease = private.Widgets.Ease.back, delay = (index - thrown - 1) * EXTRA_STAGGER })
    end
  end
  if self.onLanded then
    self.onLanded()
  end
  if not roll.glow then
    return
  end
  for index = 1, #roll.faces do
    local glow = self.dice[index].glow
    self.animator:Play(GLOW_SECONDS, function(progress)
      local x, y = self:place(index)
      local side = roll.size * GLOW_SIZE * (0.8 + 0.4 * progress)
      glow:SetSize(side, side)
      glow:ClearAllPoints()
      glow:SetPoint("CENTER", self.frame, "TOPLEFT", x, -y)
      glow:SetAlpha(math.sin(math.pi * progress) * 0.8)
    end, {
      delay = (whole and index > thrown) and (index - thrown - 1) * EXTRA_STAGGER or 0,
      onStart = function()
        glow:Show()
      end,
      onDone = function()
        glow:Hide()
      end,
    })
  end
end
