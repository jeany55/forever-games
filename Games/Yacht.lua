--------------------------
--  Yacht-Z
--------------------------
-- The dice game, scored on a card of thirteen boxes: alone, or around a table of up to four with
-- a card each, people and the computer. A turn begins with a roll of five dice. Any of them can
-- be kept and the rest rolled again, twice more at most, and then the dice go in a box of the
-- player's card that is still open: one box a turn, and a box the dice don't fit scores nothing
-- but is used up all the same. Everyone takes a turn in their seat's order, and after thirteen
-- rounds every card is full.
--
-- The upper boxes, ones to sixes, score the dice that show their number, and 63 or more between
-- them (three of each) earns 35 on top. The lower boxes:
--   three of a kind, four of a kind   at least that many the same: all five dice
--   full house                        three of one and two of another: 25
--   small straight                    four in a row: 30
--   large straight                    five in a row: 40
--   Yacht-Z                           all five the same: 50
--   chance                            anything at all: all five dice
-- Another Yacht-Z once its box has its 50 is worth 100 more, and whichever box it goes in it
-- counts as a full house and as either straight.
--
-- It is the game Yahtzee was made from, Yacht, scored the way Yahtzee is. Alone, 200 points or
-- more is a win. Around a table the most points win, and the same most between them is a draw.
--
-- A move rolls again, "r" and for each die whether it is kept: "r10010" keeps the first and the
-- fourth. Or it puts the dice in a box, "s" and the box: "sfh". The dice are the engine's
-- (Engine/Random.lua), and the first roll of a turn is made as the box before it is filled, so a
-- turn needs no move to begin. Nothing can be taken back: chosen differently, a roll would come
-- out differently too.
--
-- The id is still "yacht", from when it was called that and played alone: the matches and the
-- best scores kept since go on by it.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L

local DICE, FACES = 5, 6
local ROLLS = 3
local UPPER_TARGET, UPPER_BONUS = 63, 35
local EXTRA_YACHT = 100
local TARGET = 200
local SCORE_KEY = "score"
local MOST_SEATS = 4

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
--- @field seats number How many are playing
--- @field dice number[] The five as they lie, the dice of the seat whose turn it is
--- @field rolls number How many times this turn's dice were rolled, from 1
--- @field held string? Which of them were kept when they were last rolled again this turn, "1" for each that was
--- @field cards table<string, number>[] By seat: what each box scored, by id. One that is still open isn't there
--- @field bonus number[] By seat: what Yacht-Zs after the first earned
--- @field round number From 1, and one past the last once every card is full
--- @field turn number The seat whose turn it is
--- @field out table<number, boolean> Seats that left the game
--- @field over boolean

--- @class YachtEvent: MatchEvent
--- @field seat number Whose dice
--- @field kept string? The dice were rolled again, these were kept: "1" for kept, "0" for not
--- @field box string? Or the dice went in this box
--- @field scored number? And scored this
--- @field upper boolean? Which brought the upper boxes to the bonus
--- @field extra number? What another Yacht-Z earned on top

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

--- What dice would score in a box, told by how many there are of each face
--- @param counts number[] By face
--- @param total number Of all of them
--- @param id string
--- @param card table<string, number> What is scored already: another Yacht-Z stands in for what it has to
--- @return number
local function scoreCounts(counts, total, id, card)
  local box = BOX[id]
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
  -- Another Yacht-Z, with its box filled already
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

--- What dice would score in a box
--- @param dice number[]
--- @param id string
--- @param card table<string, number> What is scored already: another Yacht-Z stands in for what it has to
--- @return number
local function scoreOf(dice, id, card)
  local counts, total = countOf(dice)
  return scoreCounts(counts, total, id, card)
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
--- @param seat number
--- @return number Everything on the seat's card
local function totalOf(state, seat)
  local card = state.cards[seat]
  local total = state.bonus[seat]
  for _, scored in pairs(card) do
    total = total + scored
  end
  if upperOf(card) >= UPPER_TARGET then
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

--- The turn goes to the next seat still playing, and past the last seat the next round begins.
--- Its dice are the ones on the table until they are rolled
--- @param state YachtState
local function pass(state)
  local seat = state.turn
  for _ = 1, state.seats do
    seat = seat % state.seats + 1
    if seat == 1 then
      state.round = state.round + 1
    end
    if not state.out[seat] then
      break
    end
  end
  state.turn = seat
  state.rolls, state.held = 1, nil
  state.over = state.round > #BOXES
end

--- @param seats number
--- @param random Random
--- @return YachtState
local function newState(seats, random)
  --- @type YachtState
  local state = { seats = seats, dice = {}, rolls = 1, cards = {}, bonus = {}, round = 1, turn = 1, out = {}, over = false }
  for seat = 1, seats do
    state.cards[seat], state.bonus[seat] = {}, 0
  end
  roll(state, random)
  return state
end

--- @param state YachtState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  if state.over then
    return false, "invalid_move"
  elseif seat ~= state.turn then
    return false, "not_your_turn"
  end
  local kept = move:match("^r([01][01][01][01][01])$")
  if kept then
    if state.rolls >= ROLLS or kept == "11111" then
      return false, "invalid_move"
    end
    return true
  end
  local id = move:match("^s(%w+)$")
  if id and BOX[id] and state.cards[seat][id] == nil then
    return true
  end
  return false, "invalid_move"
end

--- Every way of keeping some of the dice and rolling the rest, while there is a roll left, and
--- every box of the seat's card that is still open
--- @param state YachtState
--- @param seat number
--- @return string[]
local function moves(state, seat)
  local list = {}
  if state.rolls < ROLLS then
    -- All but keeping all five, which wouldn't roll anything
    for pattern = 0, 2 ^ DICE - 2 do
      local kept = {}
      for index = 1, DICE do
        kept[index] = math.floor(pattern / 2 ^ (DICE - index)) % 2
      end
      list[#list + 1] = "r" .. table.concat(kept)
    end
  end
  for _, box in ipairs(BOXES) do
    if state.cards[seat][box.id] == nil then
      list[#list + 1] = "s" .. box.id
    end
  end
  return list
end

--- @param state YachtState
--- @param seat number
--- @param move string
--- @param random Random
--- @return YachtEvent
local function apply(state, seat, move, random)
  local kept = move:match("^r(%d+)$")
  if kept then
    roll(state, random, kept)
    state.rolls, state.held = state.rolls + 1, kept
    return { seat = seat, kept = kept }
  end

  local id = move:sub(2)
  local card = state.cards[seat]
  --- @type YachtEvent
  local event = { seat = seat, box = id }
  local scored = scoreOf(state.dice, id, card)
  if isYacht(state.dice) and card.y == BOX.y.fixed then
    state.bonus[seat] = state.bonus[seat] + EXTRA_YACHT
    event.extra = EXTRA_YACHT
  end
  local before = upperOf(card)
  card[id] = scored
  event.scored = scored
  event.upper = before < UPPER_TARGET and upperOf(card) >= UPPER_TARGET or nil

  pass(state)
  if not state.over then
    roll(state, random)
  end
  return event
end

--- A player left: their card stays as it is, and the others play on. Whoever's turn it was, the
--- next player begins theirs with the dice as they lie
--- @param state YachtState
--- @param seat number
local function drop(state, seat)
  state.out[seat] = true
  if state.turn == seat and not state.over then
    pass(state)
  end
end

--- Alone, a win is 200 or more. At a table, whoever has the most of those still playing, and a
--- draw where two have the same most
--- @param state YachtState
--- @return { winner: number }?
local function result(state)
  if not state.over then
    return nil
  end
  if state.seats == 1 then
    return { winner = totalOf(state, 1) >= TARGET and 1 or 0 }
  end
  local winner, best = 0, -1
  for seat = 1, state.seats do
    if not state.out[seat] then
      local total = totalOf(state, seat)
      if total > best then
        winner, best = seat, total
      elseif total == best then
        winner = 0
      end
    end
  end
  return { winner = winner }
end

-----------------------------
-- The computer
-----------------------------
-- It plays its own card for as many points as it can and pays the others no mind. What it knows
-- is the odds: a hand of five is only ever one of 252, told by how many of each face it has, and
-- what any of them is worth put in a box is quick to say. From there it works out, for every
-- handful it could keep, what the best it could do after one more roll is worth on average,
-- and then after two, and keeps the handful that comes out best, or scores, if that is better
-- than any. The engine's way of looking ahead, move after move, has nothing to go on in a game
-- that is mostly the dice.
--
-- What a hand is worth in a box is what it scores there, less what that box would be likely to
-- score later on if it were left open (PAR, what the best play comes to on average), so that it
-- doesn't fill the Yacht-Z box with nothing in the first round. Ones to sixes are worth a little
-- more for each point above three of a kind, or less below, while the 35 can still be had.
--
-- At its easiest it only ever looks one roll ahead, and the easier it is the more often it slips.
-- Measured over 2000 cards each (Tools/YachtBench.lua), hard averages 239 and makes 200 three
-- times in four, medium 213 and easy 177: not quite the best there is (254), and how much the
-- upper boxes are pulled towards their 35 hardly matters.

-- What the best play scores in each box on average, which is what leaving one open is worth
local PAR = { ["1"] = 1.9, ["2"] = 5.3, ["3"] = 8.6, ["4"] = 12.2, ["5"] = 15.7, ["6"] = 19.2, ["3k"] = 21.7, ["4k"] = 13.1, fh = 22.6, ss = 29.5, ls = 32.7, y = 16.9, c = 22 }
-- What a point of an upper box is worth to the 35 above or below three of its face, while it can still be had
local UPPER_PULL = 1
-- A hand's number: how many ones, and six times how many twos, and so on. A hand and a handful
-- kept from another are added up by adding their numbers
local PLACE = {}
for face = 1, FACES do
  PLACE[face] = 6 ^ (face - 1)
end

--- Every way of having so many dice, by how many of each face: what it is called, and how likely
--- that many dice are to come up that way
--- @type { counts: number[], key: number, chance: number }[][]?
local hands

--- @param count number
--- @return number count!
local function factorial(count)
  local product = 1
  for factor = 2, count do
    product = product * factor
  end
  return product
end

--- Fills `hands`, the first time the computer plays
local function countHands()
  hands = {}
  for size = 0, DICE do
    hands[size] = {}
  end
  local counts = {}
  local function fill(face, left)
    if face > FACES then
      local size, key, ways = DICE - left, 0, 1
      for each = 1, FACES do
        key = key + counts[each] * PLACE[each]
        ways = ways * factorial(counts[each])
      end
      local list = hands[size]
      list[#list + 1] = { counts = { unpack(counts) }, key = key, chance = factorial(size) / ways / FACES ^ size }
      return
    end
    for count = 0, left do
      counts[face] = count
      fill(face + 1, left - count)
    end
  end
  fill(1, DICE)
end

--- Every handful that can be kept of a hand, by number
--- @param counts number[]
--- @return number[]
local function handfuls(counts)
  local keys = { 0 }
  for face = 1, FACES do
    local found = #keys
    for count = 1, counts[face] do
      for index = 1, found do
        keys[#keys + 1] = keys[index] + count * PLACE[face]
      end
    end
  end
  return keys
end

--- What every hand of five is worth to a seat at best, scored in whichever of its open boxes
--- @param state YachtState
--- @param seat number
--- @param brain Brain
--- @return table<number, number> By hand
local function scoredNow(state, seat, brain)
  local card = state.cards[seat]
  local needed = UPPER_TARGET - upperOf(card)
  local extra = card.y == BOX.y.fixed and EXTRA_YACHT or 0
  local worth = {}
  for _, hand in ipairs(hands[DICE]) do
    local counts, total = hand.counts, 0
    for face = 1, FACES do
      total = total + counts[face] * face
    end
    local best = -math.huge
    for _, box in ipairs(BOXES) do
      if card[box.id] == nil then
        local scored = scoreCounts(counts, total, box.id, card)
        local value = scored - PAR[box.id]
        if box.face and needed > 0 then
          value = value + (scored - 3 * box.face) * UPPER_PULL
        end
        best = math.max(best, value)
      end
    end
    -- Another Yacht-Z earns its 100 wherever it goes
    worth[hand.key] = best + ((extra > 0 and math.max(unpack(counts)) == DICE) and extra or 0)
    brain:Spend()
  end
  return worth
end

--- What keeping each handful is worth on average, rolling the rest once more
--- @param after table<number, number> What every hand of five is worth after the roll, by hand
--- @param brain Brain
--- @return table<number, number> By handful
local function keeping(after, brain)
  local worth = {}
  for size = 0, DICE do
    for _, kept in ipairs(hands[size]) do
      local sum = 0
      for _, rolled in ipairs(hands[DICE - size]) do
        sum = sum + rolled.chance * after[kept.key + rolled.key]
      end
      worth[kept.key] = sum
    end
    brain:Spend(#hands[size])
  end
  return worth
end

--- What every hand of five is worth with a roll left: the best handful of it to keep
--- @param kept table<number, number> What keeping each handful is worth, by handful
--- @param brain Brain
--- @return table<number, number> By hand
local function withRoll(kept, brain)
  local worth = {}
  for _, hand in ipairs(hands[DICE]) do
    local best = -math.huge
    for _, key in ipairs(handfuls(hand.counts)) do
      best = math.max(best, kept[key])
    end
    worth[hand.key] = best
    brain:Spend()
  end
  return worth
end

--- @param seen YachtState
--- @param seat number
--- @param brain Brain
--- @return string
local function think(seen, seat, brain)
  if not hands then
    countHands()
  end
  local now = scoredNow(seen, seat, brain)
  local card, left = seen.cards[seat], ROLLS - seen.rolls
  local counts, total = countOf(seen.dice)
  local needed = UPPER_TARGET - upperOf(card)
  local extra = (card.y == BOX.y.fixed and isYacht(seen.dice)) and EXTRA_YACHT or 0

  local scored = {}
  for _, box in ipairs(BOXES) do
    if card[box.id] == nil then
      local points = scoreCounts(counts, total, box.id, card)
      local value = points - PAR[box.id] + extra
      if box.face and needed > 0 then
        value = value + (points - 3 * box.face) * UPPER_PULL
      end
      scored[#scored + 1] = { move = "s" .. box.id, score = value, rank = 0 }
    end
  end
  if left > 0 then
    -- One roll ahead, or two where there are two and it looks that far
    local worth = keeping(now, brain)
    if left > 1 and brain.level.depth > 1 then
      worth = keeping(withRoll(worth, brain), brain)
    end
    local tried = {}
    for pattern = 0, 2 ^ DICE - 2 do
      local kept, key = {}, 0
      for index = 1, DICE do
        kept[index] = math.floor(pattern / 2 ^ (DICE - index)) % 2
        key = key + kept[index] * PLACE[seen.dice[index]]
      end
      -- The same handful kept from other places is the same move
      if not tried[key] then
        tried[key] = true
        scored[#scored + 1] = { move = "r" .. table.concat(kept), score = worth[key], rank = 0 }
      end
    end
  end
  table.sort(scored, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.move < b.move
  end)
  return brain:Pick(scored).move
end

local COMPUTER = {
  think = think,
  -- Another try would be another roll of the dice
  takeback = false,
  -- The dice have to land before the next roll
  pause = 0.8,
  levels = {
    easy = { depth = 1, slip = 0.5, among = 4 },
    medium = { depth = 2, slip = 0.2, among = 4 },
    hard = { depth = 2, slip = 0 },
  },
}

-----------------------------
-- View
-----------------------------
-- The table on the left: felt, with a tray along its near edge, and under it the button to roll
-- again. The card on the right, with a column for each player at a table. A turn's first roll
-- waits in the player's hand until they throw it (GUI/Dice.lua). Clicking a die keeps it, it
-- goes to its place in the tray, and clicked again it goes back. Holding the button down picks up
-- the dice that aren't kept and shakes them, letting go throws them. Once the dice lie still the
-- player's column shows what every open box would score, and clicking one scores it. The others'
-- dice are thrown for them as their turns come in, and what they keep goes in the tray.

local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\"
local FELT, FELT_EDGE = { 0.07, 0.24, 0.15, 0.97 }, { 0.62, 0.48, 0.25, 0.8 }
local TRAY, SLOT = { 0, 0, 0, 0.3 }, { 0, 0, 0, 0.35 }
local CARD = { 0.06, 0.05, 0.04, 0.85 }
local LINE = { 1, 0.82, 0, 0.25 }
-- The column of whoever's turn it is
local TURN_TINT = { 1, 0.82, 0, 0.08 }
local MARGIN = 8
-- The card takes this much of the width, within these: more for every player after the first
local CARD_SHARE, CARD_MIN, CARD_MAX = 0.34, 210, 300
local SHARE_EACH, MIN_EACH, MAX_EACH = 0.06, 46, 64
-- A column of a card for more than one, no narrower or wider than these
local COLUMN_MIN, COLUMN_MAX = 44, 72
-- Room on the card for the names of the boxes beside the columns
local NAMES_WIDTH = 116
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
-- What a box the dice would score in breathes with
local GLOW = { 0.3, 0.9, 0.3, 0.22 }
local FLASH_SECONDS = 0.7
-- How big the words that cheer a Yacht-Z are against a die
local CHEER_SIZE = 0.8
local OVER_AFTER = 0.5
local OVER_COLOR = { 0.92, 0.9, 0.86 }
local KEEP_SOUND, SCORE_SOUND, BONUS_SOUND = "chipsCollide", "cardPlace", "IG_QUEST_LIST_COMPLETE"
-- The fanfare for a Yacht-Z, and what to play on a client that doesn't have it
local YACHT_SOUND, YACHT_SOUND_ELSE = "UI_EPICLOOT_TOAST", "IG_QUEST_LIST_COMPLETE"

-- The rows of the card, top to bottom: who each column is for at a table, every box, and what
-- is added up
local ROWS = { { head = true } }
for index, box in ipairs(BOXES) do
  ROWS[#ROWS + 1] = { box = box.id }
  if index == FACES then
    ROWS[#ROWS + 1] = { sum = "upper" }
  end
end
ROWS[#ROWS + 1] = { sum = "extra" }
ROWS[#ROWS + 1] = { sum = "total" }

--- @class YachtRow: Button
--- @field spec { head: boolean?, box: string?, sum: string? }
--- @field light Texture
--- @field glow Glow Breathes while the dice would score something there
--- @field font string What its words are written in
--- @field name FontString
--- @field values FontString[] By seat
--- @field open boolean? It can be scored in now
--- @field hovered boolean?
--- @field y number Its middle on the stage

--- @class YachtView: GameViewObject
--- @field stage Frame
--- @field felt Frame
--- @field dice Dice
--- @field effects Effects
--- @field card Frame
--- @field rows YachtRow[]
--- @field tints Texture[] Behind the columns, by seat
--- @field columns { x: number, width: number }[] Where each seat's column is on the card, from its left, and its middle on the stage
--- @field seats number How many columns the card is laid out for
--- @field rollButton Button
--- @field view GameView? What was last asked for
--- @field kept boolean[] The dice the player is keeping, by place
--- @field keptTurn string? The turn they are kept in
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
  local self = setmetatable({ stage = stage, kept = {}, thrown = {}, rows = {}, slots = {}, tints = {}, columns = {}, seats = 1 }, View)

  self.felt = Widgets.Panel(stage)
  private.Felt.Paint(self.felt, FELT)
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
  for seat = 1, MOST_SEATS do
    local tint = self.card:CreateTexture(nil, "BACKGROUND", nil, 1)
    tint:SetColorTexture(unpack(TURN_TINT))
    tint:Hide()
    self.tints[seat] = tint
  end
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
--- @param spec { head: boolean?, box: string?, sum: string? }
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
  row.glow = Widgets.Glow(row, GLOW)
  row.font = spec.sum == "total" and "GameFontNormalLarge" or ((spec.sum or spec.head) and "GameFontNormal" or "GameFontHighlight")
  row.name = Widgets.Label(row, row.font, spec.head and "" or L["yacht_row_" .. (spec.box or spec.sum)])
  row.name:SetPoint("LEFT", 10, 0)
  row.values = {}
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

--- The text of a seat's column in a row, made the first time it is asked for
--- @param row YachtRow
--- @param seat number
--- @return FontString
function View:valueOf(row, seat)
  local value = row.values[seat]
  if not value then
    value = private.Widgets.Label(row, row.font)
    value:SetWordWrap(false)
    row.values[seat] = value
  end
  return value
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
  self.width, self.height = width, height
  local seats = self.seats
  local more = seats - 1
  local cardWidth = math.floor(math.max(CARD_MIN + more * MIN_EACH, math.min(CARD_MAX + more * MAX_EACH, width * (CARD_SHARE + more * SHARE_EACH))))
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

  -- Alone, the score sits at the right of the row. At a table each player has a column, side by
  -- side up to the right edge
  local column = seats == 1 and 0 or math.floor(math.max(COLUMN_MIN, math.min(COLUMN_MAX, (cardWidth - NAMES_WIDTH) / seats)))
  self.columns = {}
  for seat = 1, seats do
    local x = cardWidth - 4 - (seats - seat + 1) * column
    self.columns[seat] = { x = x, width = column, middle = width - MARGIN - cardWidth + x + column / 2 }
  end
  if seats == 1 then
    self.columns[1].middle = width - MARGIN - cardWidth / 2
  end

  local shown = {}
  for _, row in ipairs(self.rows) do
    row:SetShown(seats > 1 or not row.spec.head)
    if row:IsShown() then
      shown[#shown + 1] = row
    end
  end
  local rowHeight = math.floor(math.max(ROW_MIN, math.min(ROW_MAX, (cardHeight - 8) / (#shown + 2 * SECTION_GAP))))
  local top = math.floor((cardHeight - rowHeight * (#shown + 2 * SECTION_GAP)) / 2)
  local lines, columnsTop = 0, top
  for _, row in ipairs(shown) do
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
    row.y = MARGIN + top + rowHeight / 2
    for seat = 1, seats do
      local value = self:valueOf(row, seat)
      value:ClearAllPoints()
      if seats == 1 then
        value:SetJustifyH("RIGHT")
        value:SetWidth(0)
        value:SetPoint("RIGHT", -10, 0)
      else
        value:SetJustifyH("CENTER")
        value:SetWidth(column - 4)
        -- The row starts 2 in from the card
        value:SetPoint("CENTER", row, "LEFT", self.columns[seat].x - 2 + column / 2, 0)
      end
    end
    for seat = seats + 1, #row.values do
      row.values[seat]:Hide()
    end
    top = top + rowHeight
  end
  for seat, tint in ipairs(self.tints) do
    tint:ClearAllPoints()
    if seat <= seats and seats > 1 then
      tint:SetPoint("TOPLEFT", self.columns[seat].x, -columnsTop)
      tint:SetSize(column, top - columnsTop)
    end
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
  return view.live and view.canMove and state.turn == view.seat and not state.over and not self.dice:Holding() and not self.dice:Flying()
end

--- @return boolean Whether the dice on the table are the player's own to roll
function View:mine()
  return self.view.state.turn == self.view.seat
end

--- @return string Which turn the dice on the table are for
function View:turnKey()
  --- @type YachtState
  local state = self.view.state
  return self.view.match.id .. ":" .. state.round .. ":" .. state.turn
end

--- Puts the dice on the table: the ones kept in the tray, the others on the felt. The player's
--- own as they keep them, anyone else's as they kept them when they last rolled
function View:showDice()
  local view = self.view
  --- @type YachtState
  local state = view.state
  local spots = {}
  for index = 1, DICE do
    local kept
    if self:mine() and view.canMove then
      kept = self.kept[index] and view.live
    else
      kept = state.held ~= nil and state.held:sub(index, index) == "1"
    end
    spots[index] = kept and self.spots[index] or nil
  end
  self.dice:Show({
    key = self:turnKey(),
    faces = state.dice,
    size = self.size,
    from = self.from,
    area = self.area,
    spots = spots,
    glow = isYacht(state.dice),
  })
end

--- Puts the player's first roll of a turn in their hand, or throws a roll that was made by
--- somebody else, or while the player wasn't looking
--- @param event YachtEvent?
function View:throwDice(event)
  local view = self.view
  --- @type YachtState
  local state = view.state
  local roll = self.dice.roll
  local key = roll and roll.key
  local showing = event ~= nil and view.changed and (view.live or view.catching)
  if key ~= self.rolled then
    self.rolled = key
    if state.over then
      return
    elseif view.live and view.canMove and self:mine() and state.rolls == 1 and not self.thrown[key] then
      self.dice:Hold(function()
        self.thrown[key] = true
        self:refresh()
      end)
    elseif showing and event.box then
      -- The next player's first roll, as the last one scored
      self.dice:Throw(0)
    end
  elseif showing and event.kept and not self.tossing then
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
  if self:settled() and view.state.cards[view.seat][id] == nil then
    view.submit("s" .. id)
  end
end

--- Says what every row of the card holds: what was scored, or what the dice would score in the
--- player's own column while they are theirs to score
function View:fill()
  local view = self.view
  --- @type YachtState
  local state = view.state
  local Widgets = private.Widgets
  local open = self:settled()
  local alone = state.seats == 1
  for _, row in ipairs(self.rows) do
    local spec = row.spec
    row.open = false
    local scores = false
    for seat = 1, state.seats do
      local card = state.cards[seat]
      local out = state.out[seat]
      local text, color = "", { 1, 1, 1 }
      if spec.head then
        text = view.names[seat] or ""
        color = (seat == state.turn and not state.over) and Widgets.GOLD or (out and NOTHING or { 1, 1, 1 })
      elseif spec.box then
        local scored = card[spec.box]
        if scored then
          text = scored
          color = out and NOTHING or color
        elseif open and seat == view.seat then
          text = scoreOf(state.dice, spec.box, card)
          color = text > 0 and OPEN or NOTHING
          row.open = true
          scores = text > 0
        end
      elseif spec.sum == "upper" then
        local sum = upperOf(card)
        if sum >= UPPER_TARGET then
          text, color = "+" .. UPPER_BONUS, Widgets.GOLD
        else
          text, color = L[alone and "yacht_upper_progress" or "yacht_upper_short"]:format(sum, UPPER_TARGET), NOTHING
        end
      elseif spec.sum == "extra" then
        text, color = state.bonus[seat] > 0 and "+" .. state.bonus[seat] or "", Widgets.GOLD
      else
        text, color = totalOf(state, seat), out and NOTHING or Widgets.GOLD
      end
      local value = self:valueOf(row, seat)
      value:SetText(tostring(text))
      value:SetTextColor(unpack(color))
      value:Show()
    end
    if spec.box then
      -- Alone the name of a box that is filled goes grey, at a table that is for the player's own
      local filled = state.cards[view.seat] and state.cards[view.seat][spec.box] ~= nil
      row.name:SetTextColor(unpack(filled and NOTHING or { 1, 1, 1 }))
    end
    row:EnableMouse(spec.box ~= nil)
    row.glow:SetShown(scores)
    self:light(row)
  end
  for seat, tint in ipairs(self.tints) do
    tint:SetShown(not alone and seat <= state.seats and seat == state.turn and not state.over)
  end
end

--- Brings everything but the dice up to date with what can be done now
function View:refresh()
  local view = self.view
  --- @type YachtState
  local state = view.state
  self:fill()

  local settled = self:settled()
  local mine = self:mine() and view.canMove
  local left, loose = ROLLS - state.rolls, false
  for index = 1, DICE do
    loose = loose or not self.kept[index]
  end
  self.canRoll = settled and left > 0 and loose
  self.rollButton:SetEnabled(self.canRoll)
  self.rollButton:SetText(left > 0 and L["yacht_roll"]:format(left) or L["yacht_no_rolls"])
  self.rollButton:SetShown(view.live and not state.over and (mine or state.seats == 1))
  self.dice:SetClick((settled and left > 0) and function(index)
    self:keep(index)
  end or nil)

  if state.over then
    self.heading:SetText(L["yacht_card_full"])
  elseif state.seats == 1 then
    self.heading:SetText(L["yacht_turn"]:format(state.round, #BOXES))
  else
    self.heading:SetText(L["yacht_round"]:format(state.round, #BOXES))
  end
  local hint = ""
  if settled then
    hint = left > 0 and L["yacht_hint_keep"] or L["yacht_hint_score"]
  elseif not state.over and not self:mine() then
    hint = L["yacht_hint_wait"]:format(view.names[state.turn] or "")
  end
  self.hint:SetText(hint)
  -- Out of rolls a box has to be picked: that is worth seeing
  self.hint:SetTextColor(unpack((settled and left == 0) and private.Widgets.GOLD or NOTHING))

  -- The best there ever was is for a game played alone
  local best, mine = nil, false
  if state.seats == 1 then
    best, mine = view.best(SCORE_KEY)
    best = math.max(best or 0, state.over and totalOf(state, 1) or 0)
  end
  self.best:SetText((best or 0) > 0 and L["yacht_best"]:format(best) or "")
  self.best:SetTextColor(unpack((mine and (best or 0) > 0) and private.Widgets.GOLD or NOTHING))
end

--- The thrown dice have come to rest: the card can be read, and a Yacht-Z is cheered
function View:landed()
  if not self.view then
    return
  end
  self:refresh()
  --- @type YachtState
  local state = self.view.state
  -- Only for the roll on the table: one that is cleared away comes to rest first, unseen
  local roll = self.dice.roll
  local current = roll ~= nil and roll.key == self:turnKey()
  if current and isYacht(state.dice) and (self.view.live or self.view.catching) and not state.over then
    local area = self.area
    local x, y = MARGIN + area.x + area.width / 2, MARGIN + area.y + area.height * 0.35
    self.effects:Float(L["yacht_cheer"], x, y, { size = math.floor(self.size * CHEER_SIZE) })
    self.effects:Confetti()
    private.Widgets.PlaySound(SOUNDKIT[YACHT_SOUND] and YACHT_SOUND or YACHT_SOUND_ELSE)
  end
end

--- Lights a row of the card up for a moment, and has something drift up from a seat's column
--- @param id string Which row: a box, or what is added up
--- @param seat number
--- @param text string
function View:mark(id, seat, text)
  local column = self.columns[seat] or self.columns[1]
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
      self.effects:Float(text, column.middle, row.y - 6, { size = 16 })
    end
  end
end

--- Every card is full: says so across the game
--- @param after number? Seconds to wait first. At once for a game that was over before it was looked at
function View:finish(after)
  local view = self.view
  --- @type YachtState
  local state = view.state
  local Widgets = private.Widgets
  local title, words, won
  if state.seats == 1 then
    local total = totalOf(state, 1)
    local best, mine = view.best(SCORE_KEY)
    words = L["yacht_final"]:format(total)
    if mine and best == total and best > 0 then
      words = words .. "  " .. L["new_best"]
    end
    won = total >= TARGET
    title = won and L["yacht_won"] or L["yacht_over"]
  else
    local outcome = result(state)
    local winner = outcome and outcome.winner or 0
    local top = 0
    for seat = 1, state.seats do
      if not state.out[seat] then
        top = math.max(top, totalOf(state, seat))
      end
    end
    words = L["yacht_final"]:format(top)
    won = winner == view.seat
    if winner == 0 then
      title = L["yacht_tie"]
    elseif won then
      title = L["yacht_you_won"]
    else
      title = L["yacht_they_won"]:format(view.names[winner] or "")
    end
  end
  self.effects:Banner(title, words, {
    color = won and Widgets.GOLD or OVER_COLOR,
    delay = after,
    instant = after == nil,
  })
end

--- Whether a roll is still in the air, which the computer's next move waits for
--- @return boolean
function View:Busy()
  return self.dice:Flying()
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

  if state.seats ~= self.seats then
    self.seats = state.seats
    if self.width then
      self:Layout(self.width, self.height)
    end
  end
  if not sameGame then
    self.effects:Clear()
  elseif view.changed and self.effects:HasBanner() and not state.over then
    self.effects:Clear()
  end
  -- What is kept is kept for the turn
  local turn = self:turnKey()
  if not sameGame or self.keptTurn ~= turn then
    self.kept, self.keptTurn = {}, turn
  end

  self:showDice()
  self:throwDice(event)
  self:refresh()

  if event and event.box and view.changed and (view.live or view.catching) then
    local Widgets = private.Widgets
    local seat = event.seat or 1
    self:mark(event.box, seat, "+" .. event.scored)
    Widgets.PlaySound(SCORE_SOUND)
    if event.upper then
      self:mark("upper", seat, "+" .. UPPER_BONUS)
      Widgets.PlaySound(BONUS_SOUND)
    end
    if event.extra then
      self:mark("extra", seat, "+" .. event.extra)
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
  -- 2: for more than one, each with a card of their own
  version = 2,
  seats = { 1, 2, 3, MOST_SEATS },
  howto = {
    {
      heading = L["howto_goal"],
      text = function(_, players)
        return L[(players == 1 and "yacht_howto_goal_alone") or (players and "yacht_howto_goal_table") or "yacht_howto_goal_either"]
      end,
    },
    { heading = L["howto_turn"], text = L["yacht_howto_turn"] },
    { heading = L["yacht_howto_boxes"], text = L["yacht_howto_boxes_text"] },
    { heading = L["yacht_howto_bonus"], text = L["yacht_howto_bonus_text"] },
    { heading = L["howto_end"], text = L["yacht_howto_end"] },
  },
  newState = newState,
  turn = function(state)
    return state.turn
  end,
  validate = validate,
  apply = apply,
  moves = moves,
  drop = drop,
  result = result,
  progress = function(state)
    if state.over then
      return L["yacht_final"]:format(totalOf(state, 1))
    end
    return L["yacht_progress"]:format(totalOf(state, 1), state.round, #BOXES)
  end,
  record = function(state)
    if state.over then
      return { { key = SCORE_KEY, value = totalOf(state, 1) } }
    end
    return nil
  end,
  computer = COMPUTER,
  createView = createView,
  -- Not the engine's business: for the tests
  rules = { scoreOf = scoreOf, totalOf = totalOf, think = think },
})
