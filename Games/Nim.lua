--------------------------
--  Nim
--------------------------
-- Rows of stones. Players take turns taking stones from one row, as many as they like but at
-- least one. Whoever takes the last stone wins, or with the rules set the other way, loses.
--
-- A move is the row, a letter from "A" at the top, and how many are taken from it: "C2". Seat 1
-- moves first.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L

-- How the rows can be laid out, the top one first. A deal of rows at random has as many as the
-- classic layout, each of one to as many as its longest
local LAYOUTS = { classic = { 1, 3, 5, 7 }, small = { 3, 4, 5 } }
local RANDOM_ROWS, LONGEST = 4, 7
local LETTERS = "ABCDEFGH"

--- @class NimState
--- @field rows number[] Stones left in each row
--- @field size number[] Stones each row started with
--- @field taken number[] Stones each seat has taken
--- @field turn number
--- @field misere boolean? Whoever takes the last stone loses
--- @field outcome { winner: number, detail: string? }?

--- @class NimEvent: MatchEvent
--- @field row number
--- @field count number Stones taken

--- @param seat number
--- @return number
local function other(seat)
  return 3 - seat
end

--- @param seats number
--- @param random Random
--- @param rules table<string, any>
--- @return NimState
local function newState(seats, random, rules)
  local rows = {}
  if rules.rows == "random" then
    for index = 1, RANDOM_ROWS do
      rows[index] = random:Roll(LONGEST)
    end
    -- Shortest at the top, like the classic layout
    table.sort(rows)
  else
    for index, count in ipairs(LAYOUTS[rules.rows] or LAYOUTS.classic) do
      rows[index] = count
    end
  end
  return { rows = rows, size = { unpack(rows) }, taken = { 0, 0 }, turn = 1, misere = rules.misere or nil }
end

--- @param move string
--- @return number? row, number? count
local function parse(move)
  local letter, count = move:match("^(%u)([1-9])$")
  if not letter then
    return nil, nil
  end
  return LETTERS:find(letter, 1, true), tonumber(count)
end

--- @param state NimState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  local row, count = parse(move)
  if not row or row > #state.rows then
    return false, "invalid_move"
  end
  if seat ~= state.turn then
    return false, "not_your_turn"
  end
  if count > state.rows[row] then
    return false, "nim_too_many"
  end
  return true
end

--- @param state NimState
--- @param seat number
--- @param move string
--- @return NimEvent
local function apply(state, seat, move)
  local row, count = parse(move)
  state.rows[row] = state.rows[row] - count
  state.taken[seat] = state.taken[seat] + count
  local left = 0
  for _, stones in ipairs(state.rows) do
    left = left + stones
  end
  if left == 0 then
    state.outcome = { winner = state.misere and other(seat) or seat, detail = state.misere and "nim_last_loses" or "nim_last" }
  end
  state.turn = other(seat)
  return { row = row, count = count, notation = move }
end

--- Every row and number of stones that could be taken from it
--- @param state NimState
--- @return string[]
local function moves(state)
  local list = {}
  for row, stones in ipairs(state.rows) do
    for count = 1, stones do
      list[#list + 1] = LETTERS:sub(row, row) .. count
    end
  end
  return list
end

-----------------------------
-- The computer
-----------------------------
-- Nim is solved: write every row's count in binary and add them up without carrying (their
-- nim-sum, an exclusive or). A player left with a nim-sum of nothing loses against anyone who
-- knows that, and from anything else there is a move that leaves the other player with nothing.
-- Playing to lose with the last stone is the same until the end: once no row would have more
-- than one stone, leave an odd number of rows of one rather than an even one.
--
-- So the computer always knows which moves win. How well it plays is how often it takes one of
-- them, and when it can't win it takes as little as it can, to keep the game going for as long as
-- it takes the other player to slip.

--- @param a number
--- @param b number
--- @return number
local function xor(a, b)
  local result, bit = 0, 1
  while a > 0 or b > 0 do
    if a % 2 ~= b % 2 then
      result = result + bit
    end
    a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
  end
  return result
end

--- Whether the player to move with these rows left loses against someone who plays it right
--- @param rows number[]
--- @param misere boolean?
--- @return boolean
local function lost(rows, misere)
  local sum, big, ones = 0, false, 0
  for _, stones in ipairs(rows) do
    sum = xor(sum, stones)
    big = big or stones > 1
    ones = ones + (stones == 1 and 1 or 0)
  end
  if misere and not big then
    return ones % 2 == 1
  end
  return sum == 0
end

local COMPUTER = {
  think = function(state, seat, brain)
    local scored = {}
    for _, move in ipairs(moves(state)) do
      local row, count = parse(move)
      local after = { unpack(state.rows) }
      after[row] = after[row] - count
      brain:Spend()
      -- Winning moves first, and among the rest the ones that take the least
      local score = lost(after, state.misere) and 1 or -count / 100
      scored[#scored + 1] = { move = move, score = score, rank = 0 }
    end
    table.sort(scored, function(a, b)
      if a.score ~= b.score then
        return a.score > b.score
      end
      return a.move < b.move
    end)
    return brain:Pick(scored).move
  end,
  levels = {
    easy = { slip = 0.6, among = 8 },
    medium = { slip = 0.25, among = 4 },
    hard = { slip = 0 },
  },
}

-----------------------------
-- View
-----------------------------
-- A slate with the stones in hollows along its rows (GUI/Heaps.lua), and a bowl at each side for
-- what each player has taken: the player's own at the right. Pointing at a stone lifts it and
-- every stone to its right in its row, which is what clicking takes.

local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\"
-- The slate, in units. Tools/make_nim.py draws it from the same numbers
local MARGIN_X, MARGIN_Y = 0.4, 0.5
local BOWL, GAP = 1.9, 0.45
local SPOT, PITCH = 0.82, 0.92
local WIDTH = 2 * MARGIN_X + 2 * BOWL + 2 * GAP + LONGEST * SPOT
local HEIGHT = 2 * MARGIN_Y + RANDOM_ROWS * PITCH
-- The shadow round the slate in its texture, and how much of the texture it fills
local PAD = 0.22
local BOARD_ROWS = 449 / 512
-- A stone and the hollow it lies in, in units, and how the stones' looks are laid out in their
-- textures: eight colours across, four shapes down
local STONE, HOLLOW = 0.56, 0.7
local STONE_COLUMNS, STONE_ROWS = 8, 4
-- The bowls, by whose they are to the player
local MINE, THEIRS = "mine", "theirs"
local LINE_GAP = 4
local LETTER_COLOR = { 0.62, 0.68, 0.76 }
-- The bowl of the winner, and the row the last move was taken from
local WINNER = { 1, 0.8, 0.3, 0.7, pulse = true }
local LAST = { 1, 1, 1, 0.1 }
local SOUNDS = { land = "nimClack" }

--- The places of the slate, for rows that start with so many stones
--- @param size number[]
--- @return table<any, HeapPlace>
local function places(size)
  local list = {}
  for row, stones in ipairs(size) do
    list[row] = {
      x = WIDTH / 2,
      y = HEIGHT / 2 + (row - (#size + 1) / 2) * PITCH,
      width = stones * SPOT,
      height = SPOT,
      row = stones,
      bed = { texture = IMAGES .. "Nim\\hollow", size = HOLLOW },
    }
  end
  for _, bowl in ipairs({ { MINE, WIDTH - MARGIN_X - BOWL / 2 }, { THEIRS, MARGIN_X + BOWL / 2 } }) do
    list[bowl[1]] = {
      x = bowl[2],
      y = HEIGHT / 2,
      width = BOWL,
      height = BOWL,
      floor = 0.7,
      label = { x = bowl[2], y = HEIGHT / 2 + BOWL / 2 + 0.3 },
      glow = IMAGES .. "Mancala\\pit",
    }
  end
  return list
end

--- A stone's look, at a size
--- @param look number
--- @param pixels number
--- @return string, number[]
local function stoneTexture(look, pixels)
  local column, row = (look - 1) % STONE_COLUMNS, math.floor((look - 1) / STONE_COLUMNS)
  local file = pixels > 36 and "stones64" or "stones32"
  local coords = { column / STONE_COLUMNS, (column + 1) / STONE_COLUMNS, row / STONE_ROWS, (row + 1) / STONE_ROWS }
  return IMAGES .. "Nim\\" .. file, coords
end

--- @class NimView: GameViewObject
--- @field heaps Heaps
--- @field effects Effects
--- @field layout string? The rows the slate is laid out for
--- @field letters FontString[] By row
--- @field names FontString[] The opponent's above the slate, the player's own below
--- @field note FontString What the last move did
--- @field preview FontString What clicking the stone pointed at would take
--- @field pointed { row: number, index: number }?
--- @field width number The stage's
--- @field height number
--- @field view GameView? What was last asked for
local View = {}
View.__index = View

--- @param stage Frame
--- @return NimView
local function createView(stage)
  local Widgets = private.Widgets
  --- @type NimView
  local self = setmetatable({ letters = {}, width = 0, height = 0 }, View)

  self.heaps = private.Heaps.New(stage, {
    width = WIDTH,
    height = HEIGHT,
    places = places(LAYOUTS.classic),
    token = STONE,
    looks = STONE_COLUMNS * STONE_ROWS,
    textureFor = stoneTexture,
    backdrop = {
      texture = IMAGES .. "Nim\\slate",
      coords = { 0, 1, 0, BOARD_ROWS },
      x = -PAD,
      y = -PAD,
      width = WIDTH + 2 * PAD,
      height = HEIGHT + 2 * PAD,
    },
    labelSize = 0.3,
    labelColor = { 0.86, 0.9, 0.96 },
    sounds = SOUNDS,
  })
  self.heaps:SetInput({
    pickable = function(place, index)
      return self:taking(place, index) ~= nil
    end,
    onClick = function(place, index)
      local count = self:taking(place, index)
      self.pointed = nil
      self.heaps:SetEnabled(false)
      self.view.submit(LETTERS:sub(place, place) .. count)
    end,
    onHover = function(place, index)
      self.pointed = place and { row = place, index = index } or nil
      self:light()
    end,
  })

  self.names = { Widgets.Label(stage, "GameFontHighlight"), Widgets.Label(stage, "GameFontHighlight") }
  self.names[1]:SetPoint("BOTTOMLEFT", self.heaps.frame, "TOPLEFT", 0, LINE_GAP)
  self.names[2]:SetPoint("TOPRIGHT", self.heaps.frame, "BOTTOMRIGHT", 0, -LINE_GAP)
  self.note = Widgets.Label(stage, "GameFontHighlightSmall")
  self.note:SetPoint("BOTTOMRIGHT", self.heaps.frame, "TOPRIGHT", 0, LINE_GAP)
  self.note:SetTextColor(unpack(Widgets.GOLD))
  self.preview = Widgets.Label(stage, "GameFontHighlight")
  self.preview:SetPoint("TOPLEFT", self.heaps.frame, "BOTTOMLEFT", 0, -LINE_GAP)
  self.preview:SetTextColor(unpack(Widgets.GOLD))

  self.effects = private.Effects.New(stage)
  return self
end

--- @param width number
--- @param height number
function View:Layout(width, height)
  local room = height - 2 * (18 + LINE_GAP)
  self.heaps:SetSize(width * WIDTH / (WIDTH + 2 * PAD), room * HEIGHT / (HEIGHT + 2 * PAD))
  self.heaps.frame:ClearAllPoints()
  self.heaps.frame:SetPoint("CENTER")
  self.width, self.height = width, height
  self:placeLetters()
end

--- Writes each row's letter at its left
function View:placeLetters()
  local unit = self.heaps.unit
  local size = self.view and self.view.state.size or {}
  for row = 1, math.max(#size, #self.letters) do
    local letter = self.letters[row]
    if not letter and size[row] then
      letter = self.heaps.frame:CreateFontString(nil, "OVERLAY")
      letter:SetTextColor(unpack(LETTER_COLOR))
      letter:SetShadowColor(0, 0, 0, 0.8)
      self.letters[row] = letter
    end
    if size[row] then
      letter:SetFont(STANDARD_TEXT_FONT, math.max(9, math.floor(unit * 0.26)), "")
      letter:SetShadowOffset(1, -1)
      letter:SetText(LETTERS:sub(row, row))
      letter:ClearAllPoints()
      local x = WIDTH / 2 - size[row] * SPOT / 2 - 0.22
      local y = HEIGHT / 2 + (row - (#size + 1) / 2) * PITCH
      letter:SetPoint("CENTER", self.heaps.frame, "TOPLEFT", x * unit, -y * unit)
      letter:Show()
    elseif letter then
      letter:Hide()
    end
  end
end

--- How many stones clicking a spot of a row would take: the stone there and every one to its right
--- @param place any
--- @param index number?
--- @return number?
function View:taking(place, index)
  local view = self.view
  if not view or not view.canMove or type(place) ~= "number" or not index or self.heaps:Busy() then
    return nil
  end
  local stones = view.state.rows[place]
  if index > stones then
    return nil
  end
  return stones - index + 1
end

--- Lifts the stones the one pointed at would take, and lights up the bowl of a winner
function View:light()
  local view = self.view
  --- @type NimState
  local state = view.state
  local lights, raised, text = {}, {}, ""
  local pointed = self.pointed
  local count = pointed and self:taking(pointed.row, pointed.index)
  if count then
    raised[pointed.row] = count
    local left = -count
    for _, stones in ipairs(state.rows) do
      left = left + stones
    end
    local letter = LETTERS:sub(pointed.row, pointed.row)
    if left == 0 then
      text = L[state.misere and "nim_preview_last_loses" or "nim_preview_last"]:format(count, letter)
    else
      text = L["nim_preview"]:format(count, letter)
    end
  elseif state.outcome and state.outcome.winner ~= 0 then
    lights[state.outcome.winner == view.seat and MINE or THEIRS] = WINNER
  else
    local event = view.events and view.events[view.ply]
    if event and event.row then
      lights[event.row] = LAST
    end
  end
  self.heaps:SetRaised(raised)
  self.heaps:SetHighlights(lights)
  self.preview:SetText(text)
end

--- The stones there are where, as the player sees them
--- @param rows number[]
--- @param taken number[]
--- @param seat number
--- @return table<any, number>
local function countsOf(rows, taken, seat)
  local counts = { [MINE] = taken[seat], [THEIRS] = taken[other(seat)] }
  for row, stones in ipairs(rows) do
    counts[row] = stones
  end
  return counts
end

--- @param view GameView
function View:Update(view)
  self.view = view
  --- @type NimState
  local state = view.state
  local heaps, seat = self.heaps, view.seat

  local layout = table.concat(state.size, ",")
  if layout ~= self.layout then
    self.layout = layout
    heaps:SetPlaces(places(state.size))
    self.pointed = nil
  end
  self:placeLetters()

  --- @type NimEvent?
  local event = view.played
  if view.changed then
    heaps:Stop()
    self.effects:Clear()
  end
  local over
  if event then
    -- From the position before it: the stones back in their row, out of the bowl
    local rows, taken = { unpack(state.rows) }, { unpack(state.taken) }
    rows[event.row] = rows[event.row] + event.count
    taken[event.seat] = taken[event.seat] - event.count
    heaps:Show(countsOf(rows, taken, seat))
    over = heaps:Gather(event.row, event.seat == seat and MINE or THEIRS, { count = event.count, each = true })
    heaps:Then(over, function()
      self:light()
    end)
    if state.outcome and state.outcome.winner == seat and (view.live or view.catching) then
      self.effects:Confetti(over)
    end
  end
  heaps:Show(countsOf(state.rows, state.taken, seat))
  heaps:SetEnabled(view.canMove)

  self.names[1]:SetText(view.names[other(seat)] or "")
  self.names[2]:SetText(L["nim_you"])
  local last = view.events and view.events[view.ply]
  if last and last.row and last.seat ~= seat and not state.outcome then
    self.note:SetText(L["nim_took"]:format(view.names[last.seat] or "", last.count, LETTERS:sub(last.row, last.row)))
  else
    self.note:SetText("")
  end
  self:light()
end

--- @return boolean
function View:Busy()
  return self.heaps:Busy()
end

private.Games.Register({
  id = "nim",
  name = L["game_nim"],
  description = L["game_nim_description"],
  genre = "casual",
  icon = IMAGES .. "Icons\\nim",
  version = 1,
  seats = 2,
  history = true,
  options = {
    {
      id = "rows",
      name = L["nim_option_rows"],
      description = L["nim_option_rows_tip"],
      choices = { "classic", "small", "random" },
      default = "classic",
      label = function(value)
        return L["nim_rows_" .. value]
      end,
    },
    { id = "misere", name = L["nim_option_misere"], description = L["nim_option_misere_tip"], default = false },
  },
  howto = {
    {
      heading = L["howto_goal"],
      text = function(rules)
        return L[rules.misere and "nim_howto_goal_misere" or "nim_howto_goal"]
      end,
    },
    { heading = L["howto_turn"], text = L["nim_howto_turn"] },
    {
      heading = L["howto_end"],
      text = function(rules)
        return L[rules.misere and "nim_howto_end_misere" or "nim_howto_end"]
      end,
    },
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
  computer = COMPUTER,
  createView = createView,
  -- Not the engine's business: for the tests
  rules = { lost = lost },
})
