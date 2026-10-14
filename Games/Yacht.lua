--------------------------
--  Yacht
--------------------------
-- The dice game for one, scored on a card of thirteen boxes. A turn begins with a roll of five
-- dice. Any of them can be kept and the rest rolled again, twice more at most, and then the dice
-- go in a box of the card that is still open: one box a turn, and a box the dice don't fit
-- scores nothing but is used up all the same. After thirteen turns the card is full.
--
-- The upper boxes, ones to sixes, score the dice that show their number, and 63 or more between
-- them (three of each) earns 35 on top. The lower boxes:
--   three of a kind, four of a kind   at least that many the same: all five dice
--   full house                        three of one and two of another: 25
--   small straight                    four in a row: 30
--   large straight                    five in a row: 40
--   yacht                             all five the same: 50
--   chance                            anything at all: all five dice
-- Another yacht once the yacht box has its 50 is worth 100 more, and whichever box it goes in it
-- counts as a full house and as either straight.
--
-- It is the game Yahtzee was made from, scored the way Yahtzee is. 200 points or more is a win.
--
-- A move rolls again, "r" and for each die whether it is kept: "r10010" keeps the first and the
-- fourth. Or it puts the dice in a box, "s" and the box: "sfh". The dice are the engine's
-- (Engine/Random.lua), and the first roll of a turn is made as the box before it is filled, so a
-- turn needs no move to begin. Nothing can be taken back: chosen differently, a roll would come
-- out differently too.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L

local DICE, FACES = 5, 6
local ROLLS = 3
local UPPER_TARGET, UPPER_BONUS = 63, 35
local EXTRA_YACHT = 100
local TARGET = 200
local SCORE_KEY = "score"

--- The boxes of the card, in order: the upper ones count the dice of a face, `same` asks for that
--- many of a kind, `run` for that many in a row, and `fixed` is what it scores instead of the dice
--- @type { id: string, face: number?, same: number?, run: number?, house: boolean?, fixed: number? }[]
local BOXES = {
  { id = "1", face = 1 },
  { id = "2", face = 2 },
  { id = "3", face = 3 },
  { id = "4", face = 4 },
  { id = "5", face = 5 },
  { id = "6", face = 6 },
  { id = "3k", same = 3 },
  { id = "4k", same = 4 },
  { id = "fh", house = true, fixed = 25 },
  { id = "ss", run = 4, fixed = 30 },
  { id = "ls", run = 5, fixed = 40 },
  { id = "y", same = 5, fixed = 50 },
  { id = "c" },
}
local BOX = {}
for _, box in ipairs(BOXES) do
  BOX[box.id] = box
end

--- @class YachtState
--- @field dice number[] The five as they lie
--- @field rolls number How many times this turn's dice were rolled, from 1
--- @field card table<string, number> What each box scored, by id. One that is still open isn't there
--- @field bonus number What yachts after the first earned
--- @field turn number From 1, and one past the last once the card is full
--- @field over boolean

--- @class YachtEvent: MatchEvent
--- @field kept string? The dice were rolled again, these were kept: "1" for kept, "0" for not
--- @field box string? Or the dice went in this box
--- @field scored number? And scored this
--- @field upper boolean? Which brought the upper boxes to the bonus
--- @field extra number? What another yacht earned on top

-----------------------------
-- Rules
-----------------------------

--- How many of each face there are
--- @param dice number[]
--- @return number[] counts By face
--- @return number total Of all of them
local function countOf(dice)
  local counts, total = {}, 0
  for face = 1, FACES do
    counts[face] = 0
  end
  for _, face in ipairs(dice) do
    counts[face] = counts[face] + 1
    total = total + face
  end
  return counts, total
end

--- @param dice number[]
--- @return boolean All five the same
local function isYacht(dice)
  for _, face in ipairs(dice) do
    if face ~= dice[1] then
      return false
    end
  end
  return true
end

--- What dice would score in a box
--- @param dice number[]
--- @param id string
--- @param card table<string, number> What is scored already: another yacht stands in for what it has to
--- @return number
local function scoreOf(dice, id, card)
  local box = BOX[id]
  local counts, total = countOf(dice)
  if box.face then
    return counts[box.face] * box.face
  end
  local most, longest, run, pair, three = 0, 0, 0, false, false
  for face = 1, FACES do
    most = math.max(most, counts[face])
    pair, three = pair or counts[face] == 2, three or counts[face] == 3
    run = counts[face] > 0 and run + 1 or 0
    longest = math.max(longest, run)
  end
  -- Another yacht, with the yacht box filled already
  local joker = most == DICE and card.y ~= nil
  local fits = true
  if box.same then
    fits = most >= box.same
  elseif box.run then
    fits = longest >= box.run or joker
  elseif box.house then
    fits = (pair and three) or joker
  end
  if not fits then
    return 0
  end
  return box.fixed or total
end

--- @param card table<string, number>
--- @return number What the upper boxes scored between them
local function upperOf(card)
  local sum = 0
  for face = 1, FACES do
    sum = sum + (card[tostring(face)] or 0)
  end
  return sum
end

--- @param state YachtState
--- @return number Everything on the card
local function totalOf(state)
  local total = state.bonus
  for _, scored in pairs(state.card) do
    total = total + scored
  end
  if upperOf(state.card) >= UPPER_TARGET then
    total = total + UPPER_BONUS
  end
  return total
end

--- @param state YachtState
--- @param random Random
--- @param kept string? Which to keep, "1" for each that is
local function roll(state, random, kept)
  for index = 1, DICE do
    if not kept or kept:sub(index, index) ~= "1" then
      state.dice[index] = random:Roll(FACES)
    end
  end
end

--- @param _ number
--- @param random Random
--- @return YachtState
local function newState(_, random)
  --- @type YachtState
  local state = { dice = {}, rolls = 1, card = {}, bonus = 0, turn = 1, over = false }
  roll(state, random)
  return state
end

--- @param state YachtState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  if seat ~= 1 then
    return false, "not_your_turn"
  elseif state.over then
    return false, "invalid_move"
  end
  local kept = move:match("^r([01][01][01][01][01])$")
  if kept then
    if state.rolls >= ROLLS or kept == "11111" then
      return false, "invalid_move"
    end
    return true
  end
  local id = move:match("^s(%w+)$")
  if id and BOX[id] and state.card[id] == nil then
    return true
  end
  return false, "invalid_move"
end

--- @param state YachtState
--- @param seat number
--- @param move string
--- @param random Random
--- @return YachtEvent
local function apply(state, _, move, random)
  local kept = move:match("^r(%d+)$")
  if kept then
    roll(state, random, kept)
    state.rolls = state.rolls + 1
    return { kept = kept }
  end

  local id = move:sub(2)
  --- @type YachtEvent
  local event = { box = id }
  local scored = scoreOf(state.dice, id, state.card)
  if isYacht(state.dice) and state.card.y == BOX.y.fixed then
    state.bonus = state.bonus + EXTRA_YACHT
    event.extra = EXTRA_YACHT
  end
  local before = upperOf(state.card)
  state.card[id] = scored
  event.scored = scored
  event.upper = before < UPPER_TARGET and upperOf(state.card) >= UPPER_TARGET or nil

  state.turn = state.turn + 1
  if state.turn > #BOXES then
    state.over = true
  else
    roll(state, random)
    state.rolls = 1
  end
  return event
end

-----------------------------
-- View
-----------------------------
-- The table on the left: felt, with a tray along its near edge, and under it the button to roll
-- again. The card on the right. A turn's first roll waits in the player's hand until they throw
-- it (GUI/Dice.lua). Clicking a die keeps it, it goes to its place in the tray, and clicked again
-- it goes back. Holding the button down picks up the dice that aren't kept and shakes them,
-- letting go throws them. Once the dice lie still the card shows what every open box would
-- score, and clicking one scores it.

local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\"
local FELT, FELT_EDGE = { 0.07, 0.24, 0.15, 0.97 }, { 0.62, 0.48, 0.25, 0.8 }
local TRAY, SLOT = { 0, 0, 0, 0.3 }, { 0, 0, 0, 0.35 }
local CARD = { 0.06, 0.05, 0.04, 0.85 }
local LINE = { 1, 0.82, 0, 0.25 }
local MARGIN = 8
-- The card takes this much of the width, within these
local CARD_SHARE, CARD_MIN, CARD_MAX = 0.34, 210, 300
local BUTTON_WIDTH, BUTTON_HEIGHT = 200, 30
-- A die's side: how many fit across the felt and down it, and no smaller or bigger than this
local ACROSS, DOWN, DIE_MIN, DIE_MAX = 8, 5.2, 24, 72
-- The tray, in dice: how high, how far apart its places are, how big each is
local TRAY_HEIGHT, SLOT_PITCH, SLOT_SIZE = 1.6, 1.35, 1.2
-- Room at the top of the felt for the turn
local HEADING = 26
-- Rows of the card: how high, and the room between the upper boxes and the lower, in rows
local ROW_MIN, ROW_MAX, SECTION_GAP = 16, 30, 0.5
local OPEN, NOTHING = { 0.45, 0.9, 0.45 }, { 0.55, 0.55, 0.55 }
local HOVER, FLASH = 0.12, 0.45
local FLASH_SECONDS = 0.7
-- How long the words that cheer a yacht wait for the dice to land, and how big they are against a die
local CHEER_SIZE = 0.8
local OVER_AFTER = 0.5
local OVER_COLOR = { 0.92, 0.9, 0.86 }
local KEEP_SOUND, SCORE_SOUND, BONUS_SOUND = "chipsCollide", "cardPlace", "IG_QUEST_LIST_COMPLETE"
-- The fanfare for a yacht, and what to play on a client that doesn't have it
local YACHT_SOUND, YACHT_SOUND_ELSE = "UI_EPICLOOT_TOAST", "IG_QUEST_LIST_COMPLETE"

-- The rows of the card, top to bottom: every box, and what is added up
local ROWS = {}
for index, box in ipairs(BOXES) do
  ROWS[#ROWS + 1] = { box = box.id }
  if index == FACES then
    ROWS[#ROWS + 1] = { sum = "upper" }
  end
end
ROWS[#ROWS + 1] = { sum = "extra" }
ROWS[#ROWS + 1] = { sum = "total" }

--- @class YachtRow: Button
--- @field spec { box: string?, sum: string? }
--- @field light Texture
--- @field name FontString
--- @field value FontString
--- @field open boolean? It can be scored in now
--- @field hovered boolean?
--- @field x number Its middle on the stage
--- @field y number

--- @class YachtView: GameViewObject
--- @field stage Frame
--- @field felt Frame
--- @field dice Dice
--- @field effects Effects
--- @field card Frame
--- @field rows YachtRow[]
--- @field rollButton Button
--- @field view GameView? What was last asked for
--- @field kept boolean[] The dice the player is keeping, by place
--- @field keptTurn number? The turn they are kept in
--- @field thrown table<string, boolean> The turns whose first roll the player has thrown, by key
--- @field rolled string? The turn last put on the table, by key
--- @field tossing boolean? The roll being made is the one the player just threw
--- @field canRoll boolean? The button rolls again
local View = {}
View.__index = View

--- @param stage Frame
--- @return YachtView
local function createView(stage)
  local Widgets = private.Widgets
  --- @type YachtView
  local self = setmetatable({ stage = stage, kept = {}, thrown = {}, rows = {}, slots = {} }, View)

  self.felt = Widgets.Panel(stage)
  self.felt:SetBackdropColor(unpack(FELT))
  self.felt:SetBackdropBorderColor(unpack(FELT_EDGE))
  self.tray = self.felt:CreateTexture(nil, "BACKGROUND", nil, 1)
  self.tray:SetColorTexture(unpack(TRAY))
  for index = 1, DICE do
    local slot = self.felt:CreateTexture(nil, "BORDER")
    slot:SetTexture(private.Tiles.CELL)
    slot:SetVertexColor(unpack(SLOT))
    self.slots[index] = slot
  end
  self.heading = Widgets.Label(self.felt, "GameFontNormal")
  self.heading:SetPoint("TOPLEFT", 10, -8)
  self.hint = Widgets.Label(self.felt, "GameFontDisableSmall")
  self.hint:SetPoint("TOPRIGHT", -10, -9)
  self.hint:SetJustifyH("RIGHT")

  self.dice = private.Dice.New(self.felt)
  self.dice:OnLanded(function()
    self:landed()
  end)

  -- Held down it shakes the dice that aren't kept, let go it throws them
  self.rollButton = Widgets.Button(stage, "", BUTTON_WIDTH, BUTTON_HEIGHT)
  self.rollButton:HookScript("OnMouseDown", function(_, button)
    if button == "LeftButton" then
      self:grab()
    end
  end)
  self.rollButton:HookScript("OnMouseUp", function()
    self.dice:Release()
  end)

  self.card = Widgets.Panel(stage)
  self.card:SetBackdropColor(unpack(CARD))
  self.animator = Widgets.Animator(self.card)
  for index, spec in ipairs(ROWS) do
    self.rows[index] = self:newRow(spec)
  end
  self.lines = {}
  for index = 1, 2 do
    local line = self.card:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(unpack(LINE))
    line:SetHeight(1)
    self.lines[index] = line
  end
  self.best = Widgets.Label(stage, "GameFontDisableSmall")
  self.best:SetJustifyH("CENTER")

  self.effects = private.Effects.New(stage)
  return self
end

--- A row of the card
--- @param spec { box: string?, sum: string? }
--- @return YachtRow
function View:newRow(spec)
  local Widgets = private.Widgets
  --- @type YachtRow
  local row = CreateFrame("Button", nil, self.card)
  row.spec = spec
  row.light = row:CreateTexture(nil, "BACKGROUND")
  row.light:SetAllPoints()
  row.light:SetColorTexture(1, 1, 1, 1)
  row.light:SetAlpha(0)
  local font = spec.sum == "total" and "GameFontNormalLarge" or (spec.sum and "GameFontNormal" or "GameFontHighlight")
  row.name = Widgets.Label(row, font, L["yacht_row_" .. (spec.box or spec.sum)])
  row.name:SetPoint("LEFT", 10, 0)
  row.value = Widgets.Label(row, font)
  row.value:SetJustifyH("RIGHT")
  row.value:SetPoint("RIGHT", -10, 0)
  if spec.box then
    row:SetScript("OnClick", function()
      self:score(spec.box)
    end)
    row:SetScript("OnEnter", function()
      row.hovered = true
      self:light(row)
      GameTooltip:SetOwner(row, "ANCHOR_LEFT")
      GameTooltip:SetText(L["yacht_row_" .. spec.box], 1, 0.82, 0)
      GameTooltip:AddLine(L["yacht_tip_" .. spec.box], 1, 1, 1, true)
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
      row.hovered = false
      self:light(row)
      GameTooltip_Hide()
    end)
  end
  return row
end

--- Lights a row up while the cursor is over it, if it can be scored in
--- @param row YachtRow
function View:light(row)
  row.light:SetVertexColor(1, 1, 1)
  row.light:SetAlpha((row.open and row.hovered) and HOVER or 0)
end

--- @param width number
--- @param height number
function View:Layout(width, height)
  local cardWidth = math.max(CARD_MIN, math.min(CARD_MAX, math.floor(width * CARD_SHARE)))
  local feltWidth = math.max(100, width - cardWidth - 3 * MARGIN)
  local feltHeight = math.max(100, height - 3 * MARGIN - BUTTON_HEIGHT)
  local size = math.floor(math.max(DIE_MIN, math.min(DIE_MAX, feltWidth / ACROSS, feltHeight / DOWN)))
  self.size = size

  local felt = self.felt
  felt:SetSize(feltWidth, feltHeight)
  felt:ClearAllPoints()
  felt:SetPoint("TOPLEFT", self.stage, "TOPLEFT", MARGIN, -MARGIN)
  self.rollButton:ClearAllPoints()
  self.rollButton:SetPoint("TOP", felt, "BOTTOM", 0, -MARGIN)

  -- The tray along the near edge, with a place for each die. Places are on the felt, from its top left
  local trayHeight = math.floor(size * TRAY_HEIGHT)
  self.tray:ClearAllPoints()
  self.tray:SetPoint("BOTTOMLEFT", 1, 1)
  self.tray:SetPoint("BOTTOMRIGHT", -1, 1)
  self.tray:SetHeight(trayHeight)
  self.spots = {}
  for index, slot in ipairs(self.slots) do
    local x, y = feltWidth / 2 + (index - (DICE + 1) / 2) * size * SLOT_PITCH, feltHeight - 1 - trayHeight / 2
    self.spots[index] = { x = x, y = y }
    slot:SetSize(size * SLOT_SIZE, size * SLOT_SIZE)
    slot:ClearAllPoints()
    slot:SetPoint("CENTER", felt, "TOPLEFT", x, -y)
  end
  -- Above it the dice fall anywhere, and are thrown in from the far corner
  local areaHeight = feltHeight - trayHeight - HEADING - size * 0.2
  self.area = { x = size * 0.3, y = HEADING, width = feltWidth - size * 0.6, height = areaHeight }
  self.from = { x = self.area.x + self.area.width - size * 1.8, y = self.area.y + self.area.height - size * 0.8 }

  -- The card down the right, with the best there was under it
  local cardHeight = height - 2 * MARGIN - 18
  local card = self.card
  card:SetSize(cardWidth, cardHeight)
  card:ClearAllPoints()
  card:SetPoint("TOPRIGHT", self.stage, "TOPRIGHT", -MARGIN, -MARGIN)
  self.best:ClearAllPoints()
  self.best:SetPoint("TOP", card, "BOTTOM", 0, -4)
  local rowHeight = math.floor(math.max(ROW_MIN, math.min(ROW_MAX, (cardHeight - 8) / (#ROWS + 2 * SECTION_GAP))))
  local top = math.floor((cardHeight - rowHeight * (#ROWS + 2 * SECTION_GAP)) / 2)
  local lines = 0
  for _, row in ipairs(self.rows) do
    if row.spec.box == "3k" or row.spec.sum == "total" then
      -- A gap, with a line through it, before the lower boxes and before the total
      lines = lines + 1
      local line = self.lines[lines]
      line:ClearAllPoints()
      line:SetPoint("TOPLEFT", 8, -(top + rowHeight * SECTION_GAP / 2))
      line:SetPoint("TOPRIGHT", -8, -(top + rowHeight * SECTION_GAP / 2))
      top = top + rowHeight * SECTION_GAP
    end
    row:SetSize(cardWidth - 4, rowHeight)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 2, -top)
    row.x, row.y = width - MARGIN - cardWidth / 2, MARGIN + top + rowHeight / 2
    top = top + rowHeight
  end

  if self.view then
    self:showDice()
  end
end

--- @return boolean Whether the player can do something with the dice now: they lie still, out of hand
function View:settled()
  local view = self.view
  --- @type YachtState
  local state = view.state
  return view.live and view.canMove and not state.over and not self.dice:Holding() and not self.dice:Flying()
end

--- Puts the dice on the table: the ones kept in the tray, the others on the felt
function View:showDice()
  local view = self.view
  --- @type YachtState
  local state = view.state
  local spots = {}
  for index = 1, DICE do
    if self.kept[index] and view.live then
      spots[index] = self.spots[index]
    end
  end
  self.dice:Show({
    key = view.match.id .. ":" .. state.turn,
    faces = state.dice,
    color = "white",
    size = self.size,
    from = self.from,
    area = self.area,
    spots = spots,
    glow = isYacht(state.dice),
  })
end

--- Puts a new turn's first roll in the player's hand, or throws a roll again that was made
--- while the player wasn't looking
--- @param event YachtEvent?
function View:throwDice(event)
  local view = self.view
  --- @type YachtState
  local state = view.state
  local roll = self.dice.roll
  local key = roll and roll.key
  if key ~= self.rolled then
    self.rolled = key
    if view.live and view.canMove and not state.over and state.rolls == 1 and not self.thrown[key] then
      self.dice:Hold(function()
        self.thrown[key] = true
        self:refresh()
      end)
    end
  elseif event and event.kept and view.changed and view.live and not self.tossing then
    local only = {}
    for index = 1, DICE do
      only[index] = event.kept:sub(index, index) ~= "1" or nil
    end
    self.dice:Throw(0, only)
  end
end

--- The dice that aren't kept go up into the player's hand, to be shaken and thrown
function View:grab()
  if not self.canRoll then
    return
  end
  local only = {}
  for index = 1, DICE do
    only[index] = not self.kept[index] or nil
  end
  self.dice:Grab(only, function()
    local kept = {}
    for index = 1, DICE do
      kept[index] = self.kept[index] and "1" or "0"
    end
    self.tossing = true
    self.view.submit("r" .. table.concat(kept))
    self.tossing = false
  end)
  self:refresh()
end

--- A die was clicked: kept, or not kept any more
--- @param index number
function View:keep(index)
  if not self:settled() then
    return
  end
  self.kept[index] = not self.kept[index] or nil
  private.Widgets.PlaySound(KEEP_SOUND)
  self:showDice()
  self:refresh()
end

--- The dice go in a box
--- @param id string
function View:score(id)
  local view = self.view
  if self:settled() and view.state.card[id] == nil then
    view.submit("s" .. id)
  end
end

--- Says what every row of the card holds: what was scored, or what the dice would score
function View:fill()
  local view = self.view
  --- @type YachtState
  local state = view.state
  local Widgets = private.Widgets
  local open = self:settled()
  for _, row in ipairs(self.rows) do
    local spec, text, color = row.spec, "", { 1, 1, 1 }
    row.open = false
    if spec.box then
      local scored = state.card[spec.box]
      if scored then
        text = scored
      elseif open then
        text = scoreOf(state.dice, spec.box, state.card)
        color = text > 0 and OPEN or NOTHING
        row.open = true
      end
      row.name:SetTextColor(unpack(scored and NOTHING or { 1, 1, 1 }))
    elseif spec.sum == "upper" then
      local sum = upperOf(state.card)
      if sum >= UPPER_TARGET then
        text, color = "+" .. UPPER_BONUS, Widgets.GOLD
      else
        text, color = L["yacht_upper_progress"]:format(sum, UPPER_TARGET), NOTHING
      end
    elseif spec.sum == "extra" then
      text, color = state.bonus > 0 and "+" .. state.bonus or "", Widgets.GOLD
    else
      text, color = totalOf(state), Widgets.GOLD
    end
    row.value:SetText(tostring(text))
    row.value:SetTextColor(unpack(color))
    row:EnableMouse(spec.box ~= nil)
    self:light(row)
  end
end

--- Brings everything but the dice up to date with what can be done now
function View:refresh()
  local view = self.view
  --- @type YachtState
  local state = view.state
  self:fill()

  local settled = self:settled()
  local left, loose = ROLLS - state.rolls, false
  for index = 1, DICE do
    loose = loose or not self.kept[index]
  end
  self.canRoll = settled and left > 0 and loose
  self.rollButton:SetEnabled(self.canRoll)
  self.rollButton:SetText(left > 0 and L["yacht_roll"]:format(left) or L["yacht_no_rolls"])
  self.rollButton:SetShown(view.live and not state.over)
  self.dice:SetClick((settled and left > 0) and function(index)
    self:keep(index)
  end or nil)

  if state.over then
    self.heading:SetText(L["yacht_card_full"])
  else
    self.heading:SetText(L["yacht_turn"]:format(state.turn, #BOXES))
  end
  local hint = ""
  if settled then
    hint = left > 0 and L["yacht_hint_keep"] or L["yacht_hint_score"]
  end
  self.hint:SetText(hint)

  local best, mine = view.best(SCORE_KEY)
  best = math.max(best or 0, state.over and totalOf(state) or 0)
  self.best:SetText(best > 0 and L["yacht_best"]:format(best) or "")
  self.best:SetTextColor(unpack((mine and best > 0) and private.Widgets.GOLD or NOTHING))
end

--- The thrown dice have come to rest: the card can be read, and a yacht is cheered
function View:landed()
  if not self.view then
    return
  end
  self:refresh()
  --- @type YachtState
  local state = self.view.state
  -- Only for the roll on the table: one that is cleared away comes to rest first, unseen
  local roll = self.dice.roll
  local current = roll ~= nil and roll.key == self.view.match.id .. ":" .. state.turn
  if current and isYacht(state.dice) and self.view.live and not state.over then
    local area = self.area
    local x, y = MARGIN + area.x + area.width / 2, MARGIN + area.y + area.height * 0.35
    self.effects:Float(L["yacht_cheer"], x, y, { size = math.floor(self.size * CHEER_SIZE) })
    self.effects:Confetti()
    private.Widgets.PlaySound(SOUNDKIT[YACHT_SOUND] and YACHT_SOUND or YACHT_SOUND_ELSE)
  end
end

--- Lights a row of the card up for a moment, and has something drift up from it
--- @param id string Which row: a box, or what is added up
--- @param text string
function View:mark(id, text)
  for _, row in ipairs(self.rows) do
    if row.spec.box == id or row.spec.sum == id then
      row.light:SetVertexColor(unpack(private.Widgets.GOLD))
      self.animator:Play(FLASH_SECONDS, function(progress)
        row.light:SetAlpha(FLASH * (1 - progress))
      end, {
        onDone = function()
          self:light(row)
        end,
      })
      self.effects:Float(text, row.x, row.y - 6, { size = 16 })
    end
  end
end

--- The card is full: says so across the game
--- @param after number? Seconds to wait first. At once for a game that was over before it was looked at
function View:finish(after)
  local view = self.view
  local total = totalOf(view.state)
  local best, mine = view.best(SCORE_KEY)
  local words = L["yacht_final"]:format(total)
  if mine and best == total and best > 0 then
    words = words .. "  " .. L["new_best"]
  end
  local won = total >= TARGET
  self.effects:Banner(won and L["yacht_won"] or L["yacht_over"], words, {
    color = won and private.Widgets.GOLD or OVER_COLOR,
    delay = after,
    instant = after == nil,
  })
end

--- @param view GameView
function View:Update(view)
  local before = self.view
  self.view = view
  --- @type YachtState
  local state = view.state
  local sameGame = before ~= nil and before.match.id == view.match.id
  --- @type YachtEvent?
  local event = view.played

  if not sameGame then
    self.effects:Clear()
  elseif view.changed and self.effects:HasBanner() and not state.over then
    self.effects:Clear()
  end
  -- What is kept is kept for the turn
  if not sameGame or self.keptTurn ~= state.turn then
    self.kept, self.keptTurn = {}, state.turn
  end

  self:showDice()
  self:throwDice(event)
  self:refresh()

  if event and event.box and view.changed and view.live then
    local Widgets = private.Widgets
    self:mark(event.box, "+" .. event.scored)
    Widgets.PlaySound(SCORE_SOUND)
    if event.upper then
      self:mark("upper", "+" .. UPPER_BONUS)
      Widgets.PlaySound(BONUS_SOUND)
    end
    if event.extra then
      self:mark("extra", "+" .. event.extra)
      Widgets.PlaySound(BONUS_SOUND)
    end
    if state.over then
      self:finish(OVER_AFTER)
    end
  end
  -- A game that was over before it was looked at says so without making an entrance
  if state.over and not self.effects:HasBanner() then
    self:finish()
  end
end

private.Games.Register({
  id = "yacht",
  name = L["game_yacht"],
  description = L["game_yacht_description"],
  genre = "dice",
  icon = IMAGES .. "Icons\\yacht",
  version = 1,
  seats = 1,
  newState = newState,
  turn = function()
    return 1
  end,
  validate = validate,
  apply = apply,
  result = function(state)
    if state.over then
      return { winner = totalOf(state) >= TARGET and 1 or 0 }
    end
    return nil
  end,
  progress = function(state)
    if state.over then
      return L["yacht_final"]:format(totalOf(state))
    end
    return L["yacht_progress"]:format(totalOf(state), state.turn, #BOXES)
  end,
  record = function(state)
    if state.over then
      return { { key = SCORE_KEY, value = totalOf(state) } }
    end
    return nil
  end,
  createView = createView,
  -- Not the engine's business: for the tests
  rules = { scoreOf = scoreOf, totalOf = totalOf },
})
