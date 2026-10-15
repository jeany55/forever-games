--------------------------
--  Sudoku
--------------------------
-- For one player. A grid of nine squares by nine, in nine boxes of three by three, with some of
-- its squares filled in. The rest are for the player to fill so that every row, every column
-- and every box holds each digit from 1 to 9 once. There is only ever one way to do that, and
-- no way to lose: the game is won when the grid is full and right.
--
-- A puzzle is made for the game it is played in, out of nothing but the chance the engine hands
-- it (Puzzles, below): a full grid is filled in at random and squares are taken out of it for
-- as long as what is left can still be solved. How hard that is to do is what a difficulty
-- means. An easy puzzle only ever asks where in a row, column or box a digit can still go. A
-- medium one also asks which digit is the only one a square can still take. A hard one can't be
-- solved without ruling digits out first, by where they have to go in a box or a line or by
-- two squares that share two digits, and an expert one not even with that. Whoever sets the
-- game up picks one of them, and whether a digit that is wrong is pointed out as it is written
-- (OPTIONS).
--
-- Besides digits the player can pencil notes into an empty square, the digits it might be. A
-- digit that is written takes the notes of it out of its row, column and box. A hint fills a
-- square in for good, the way the ones the puzzle came with are. Wrong digits are counted
-- whether they are pointed out or not, and a game won without a hint is timed against the best
-- for its difficulty.
--
-- Squares are numbered row by row from the top left, starting at 1, and a move names one by its
-- row and its column:
--   527    write a 7 into row 5, column 2
--   520    rub out what is there: the digit, or the notes of a square without one
--   n527   pencil a 7 into it, or rub that note out again
--   h52    have it filled in

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L

local SIDE, CELLS = 9, 81
local LEVELS = { "easy", "medium", "hard", "expert" }

-- What whoever sets a game up may change
--- @type GameOption[]
local OPTIONS = {
  {
    id = "level",
    name = L["sudoku_option_level"],
    description = L["sudoku_option_level_tip"],
    choices = LEVELS,
    default = "medium",
    label = function(value)
      return L["sudoku_level_" .. value]
    end,
  },
  { id = "check", name = L["sudoku_option_check"], description = L["sudoku_option_check_tip"], default = true },
}

-----------------------------
-- Geometry
-----------------------------
-- There are twenty-seven units, the rows, the columns and the boxes, and each is known by where
-- its nine digits start in a list that has an entry for every digit of every unit: 0 for the
-- first row, 9 for the second, 81 for the first column, 162 for the first box. A digit of a
-- unit is that plus the digit, which is all the solver ever needs of one.

--- @type number[], number[], number[] The row, the column and the box of every square
local ROW, COLUMN, BOX = {}, {}, {}
--- @type table<number, number[]> The squares of every unit
local UNITS = {}
--- @type number[][] The twenty squares that share a unit with a square
local PEERS = {}
--- @type number[], number[] The unit and the digit that a digit of a unit is
local KEY_UNIT, KEY_DIGIT = {}, {}

for unit = 0, 26 do
  UNITS[unit * SIDE] = {}
  for digit = 1, SIDE do
    KEY_UNIT[unit * SIDE + digit], KEY_DIGIT[unit * SIDE + digit] = unit * SIDE, digit
  end
end
for cell = 1, CELLS do
  local row, column = math.floor((cell - 1) / SIDE), (cell - 1) % SIDE
  local box = math.floor(row / 3) * 3 + math.floor(column / 3)
  ROW[cell], COLUMN[cell], BOX[cell] = row * SIDE, (SIDE + column) * SIDE, (2 * SIDE + box) * SIDE
  for _, unit in ipairs({ ROW[cell], COLUMN[cell], BOX[cell] }) do
    table.insert(UNITS[unit], cell)
  end
end
for cell = 1, CELLS do
  PEERS[cell] = {}
  for other = 1, CELLS do
    if other ~= cell and (ROW[other] == ROW[cell] or COLUMN[other] == COLUMN[cell] or BOX[other] == BOX[cell]) then
      table.insert(PEERS[cell], other)
    end
  end
end

-----------------------------
-- Solver
-----------------------------
-- One grid is worked on at a time, in the lists below, which are used over and over: a puzzle is
-- loaded into them, and whatever follows from it is worked out as digits go in.
--
-- For every square and digit `block` counts what stands in the way of that digit going there:
-- the squares it shares a unit with that hold it, and one more if reasoning ruled it out. From
-- that two counts are kept up to date with every digit that goes in: how many digits a square
-- can still take (`open`), and in how many squares of a unit a digit can still go (`places`).
-- A count that drops to one is a digit found, and goes on a list of things to do: the only
-- digit left for a square, or the only square left for a digit. One that drops to none means
-- the grid can't be finished.
--
-- That alone solves most puzzles, and it is fast because nothing is ever looked for: it falls
-- out of the counting. Where it stops, the harder reasoning takes a look at the whole grid
-- (Reasoning, below), or a digit is tried to see what comes of it (Search).

--- @type number[], number[], number[], number[]
local val, block, open, places = {}, {}, {}, {}
-- What was found and is still to be written: a square that can take only one digit, or as a
-- negative number a digit of a unit that can go in only one square
--- @type number[]
local queue = {}
local queued, filled = 0, 0
-- The grid can't be finished
local bad = false
-- Whether a square with one digit left is something to go by. Without it only the places of a
-- digit in a unit are, which is all an easy puzzle asks for
local naked = true
-- How much has been done since it was last set to nothing: every digit written counts one.
-- What makes a puzzle is held to a budget of this, so that making one never takes long
local work = 0
-- The squares that are all the solver is after, one or two of them: once they are filled in
-- there is no need to go on
--- @type number|false, number
local watch, watchToo = false, 0
-- Added to the places of a digit in a unit that holds it, so the count never looks like a find
local TAKEN = 100
-- What looking the whole grid over counts as, next to writing a digit
local SCAN = 10

--- A digit has one place fewer to go in a unit
--- @param key number The digit of the unit
local function fewer(key)
  local left = places[key] - 1
  places[key] = left
  if left == 1 then
    queued = queued + 1
    queue[queued] = -key
  elseif left == 0 then
    bad = true
  end
end

--- A square can take one digit fewer
--- @param cell number
--- @param digit number
local function narrow(cell, digit)
  local left = open[cell] - 1
  open[cell] = left
  if left == 0 then
    bad = true
  elseif left == 1 and naked then
    queued = queued + 1
    queue[queued] = cell
  end
  fewer(ROW[cell] + digit)
  fewer(COLUMN[cell] + digit)
  fewer(BOX[cell] + digit)
end

--- Writes a digit into an empty square that can take it. This is where the solver spends its
--- time, so it does the counting itself instead of asking `fewer` and `narrow` to
--- @param cell number
--- @param digit number
local function place(cell, digit)
  local val, block, open, places, queue = val, block, open, places, queue
  local count, broken = queued, bad
  work = work + 1
  val[cell] = digit
  filled = filled + 1
  local base = (cell - 1) * SIDE
  local row, column, box = ROW[cell], COLUMN[cell], BOX[cell]
  -- Whatever else could have gone here has a place fewer to go
  for other = 1, SIDE do
    if other ~= digit and block[base + other] == 0 then
      local key = row + other
      local left = places[key] - 1
      places[key] = left
      if left <= 1 then
        if left == 1 then
          count = count + 1
          queue[count] = -key
        else
          broken = true
        end
      end
      key = column + other
      left = places[key] - 1
      places[key] = left
      if left <= 1 then
        if left == 1 then
          count = count + 1
          queue[count] = -key
        else
          broken = true
        end
      end
      key = box + other
      left = places[key] - 1
      places[key] = left
      if left <= 1 then
        if left == 1 then
          count = count + 1
          queue[count] = -key
        else
          broken = true
        end
      end
    end
  end
  places[row + digit] = places[row + digit] + TAKEN
  places[column + digit] = places[column + digit] + TAKEN
  places[box + digit] = places[box + digit] + TAKEN

  -- And the digit can't go in any square that shares a unit with this one
  local peers, singles = PEERS[cell], naked
  for index = 1, 20 do
    local peer = peers[index]
    local key = (peer - 1) * SIDE + digit
    local blocked = block[key]
    block[key] = blocked + 1
    if blocked == 0 and val[peer] == 0 then
      local left = open[peer] - 1
      open[peer] = left
      if left <= 1 then
        if left == 0 then
          broken = true
        elseif singles then
          count = count + 1
          queue[count] = peer
        end
      end
      key = ROW[peer] + digit
      left = places[key] - 1
      places[key] = left
      if left <= 1 then
        if left == 1 then
          count = count + 1
          queue[count] = -key
        else
          broken = true
        end
      end
      key = COLUMN[peer] + digit
      left = places[key] - 1
      places[key] = left
      if left <= 1 then
        if left == 1 then
          count = count + 1
          queue[count] = -key
        else
          broken = true
        end
      end
      key = BOX[peer] + digit
      left = places[key] - 1
      places[key] = left
      if left <= 1 then
        if left == 1 then
          count = count + 1
          queue[count] = -key
        else
          broken = true
        end
      end
    end
  end
  queued, bad = count, broken
end

--- Rules a digit out of a square by reasoning
--- @param cell number
--- @param digit number
--- @return boolean changed False if it couldn't go there anyway
local function eliminate(cell, digit)
  local key = (cell - 1) * SIDE + digit
  if val[cell] ~= 0 or block[key] ~= 0 then
    return false
  end
  block[key] = 1
  narrow(cell, digit)
  return true
end

--- Takes a digit back out of a square. Only for a grid nothing was worked out in yet: what
--- reasoning ruled out isn't brought back
--- @param cell number
--- @param digit number
local function unplace(cell, digit)
  val[cell] = 0
  filled = filled - 1
  local base = (cell - 1) * SIDE
  local row, column, box = ROW[cell], COLUMN[cell], BOX[cell]
  places[row + digit] = places[row + digit] - TAKEN
  places[column + digit] = places[column + digit] - TAKEN
  places[box + digit] = places[box + digit] - TAKEN
  for _, peer in ipairs(PEERS[cell]) do
    local key = (peer - 1) * SIDE + digit
    local blocked = block[key] - 1
    block[key] = blocked
    if blocked == 0 and val[peer] == 0 then
      open[peer] = open[peer] + 1
      places[ROW[peer] + digit] = places[ROW[peer] + digit] + 1
      places[COLUMN[peer] + digit] = places[COLUMN[peer] + digit] + 1
      places[BOX[peer] + digit] = places[BOX[peer] + digit] + 1
    end
  end
  -- The square is somewhere to go again for whatever nothing stands in the way of by now
  local left = 1
  for other = 1, SIDE do
    if other ~= digit and block[base + other] == 0 then
      left = left + 1
      places[row + other] = places[row + other] + 1
      places[column + other] = places[column + other] + 1
      places[box + other] = places[box + other] + 1
    end
  end
  open[cell] = left
end

--- Whether an empty square can be filled in straight away: it is the only place left for its
--- digit in one of its units, or the digit is the only one it can still take
--- @param cell number
--- @param digit number The digit that belongs in it
--- @param singles boolean Whether the second counts
--- @return boolean
local function obvious(cell, digit, singles)
  return places[ROW[cell] + digit] == 1
    or places[COLUMN[cell] + digit] == 1
    or places[BOX[cell] + digit] == 1
    or (singles and open[cell] == 1)
end

--- Gets ready to work out a grid that only had digits written into it so far: finds whatever
--- there is to find to begin with
--- @param singles boolean Whether a square with one digit left is something to go by
local function begin(singles)
  queued, bad, naked = 0, false, singles
  for cell = 1, CELLS do
    if val[cell] == 0 and open[cell] <= 1 then
      if open[cell] == 0 then
        bad = true
      elseif singles then
        queued = queued + 1
        queue[queued] = cell
      end
    end
  end
  for key = 1, 27 * SIDE do
    if places[key] <= 1 then
      if places[key] == 0 then
        bad = true
      else
        queued = queued + 1
        queue[queued] = -key
      end
    end
  end
end

--- Writes everything that was found, and whatever is found by writing it
--- @return boolean sound False if the grid can't be finished
local function drain()
  while queued > 0 and not bad and not (watch and val[watch] ~= 0 and val[watchToo] ~= 0) do
    local found = queue[queued]
    queued = queued - 1
    if found > 0 then
      if val[found] == 0 then
        local base = (found - 1) * SIDE
        for digit = 1, SIDE do
          if block[base + digit] == 0 then
            place(found, digit)
            break
          end
        end
      end
    elseif places[-found] == 1 then
      local digit = KEY_DIGIT[-found]
      for _, cell in ipairs(UNITS[KEY_UNIT[-found]]) do
        if val[cell] == 0 and block[(cell - 1) * SIDE + digit] == 0 then
          place(cell, digit)
          break
        end
      end
    end
  end
  return not bad
end

--- Starts over with an empty grid
--- @param singles boolean Whether a square with one digit left is something to go by
local function reset(singles)
  for key = 1, CELLS * SIDE do
    block[key] = 0
  end
  for cell = 1, CELLS do
    val[cell], open[cell] = 0, SIDE
  end
  for key = 1, 27 * SIDE do
    places[key] = SIDE
  end
  queued, filled, bad, naked = 0, 0, false, singles
end

--- Starts over with a puzzle. Nothing is worked out yet, see `begin`
--- @param puzzle number[] A digit for every square, 0 for an empty one
--- @return boolean sound False if it has a digit twice in a row, column or box
local function loadPuzzle(puzzle)
  reset(true)
  for cell = 1, CELLS do
    local digit = puzzle[cell]
    if digit ~= 0 then
      if block[(cell - 1) * SIDE + digit] ~= 0 then
        return false
      end
      place(cell, digit)
    end
  end
  return true
end

-----------------------------
-- Reasoning
-----------------------------
-- What a player does once no digit can simply be written: rule digits out. Three ways of it are
-- known here, the ones a hard puzzle asks for. Each looks the whole grid over and says whether
-- it ruled anything out.

--- The unit of one kind that all the places a digit has left in another unit lie in
--- @param cells number[] The squares of the unit
--- @param digit number
--- @param count number How many places it has left there
--- @param of number[] The unit of that kind each square is in: ROW, COLUMN or BOX
--- @return number? unit nil if they don't all lie in the same
local function shared(cells, digit, count, of)
  local unit = nil
  for index = 1, SIDE do
    local cell = cells[index]
    if val[cell] == 0 and block[(cell - 1) * SIDE + digit] == 0 then
      if unit == nil then
        unit = of[cell]
      elseif unit ~= of[cell] then
        return nil
      end
      count = count - 1
      if count == 0 then
        break
      end
    end
  end
  return unit
end

--- A digit that can only go in two or three squares of a box that lie in one line can't go
--- anywhere else in that line, and the other way around: one that has to be in one box of a
--- line can't be anywhere else in that box
--- @return boolean changed
local function locked()
  local changed = false
  for unit = 0, 26 * SIDE, SIDE do
    local cells = UNITS[unit]
    local isBox = unit >= 18 * SIDE
    for digit = 1, SIDE do
      local count = places[unit + digit]
      if count == 2 or count == 3 then
        local other
        if isBox then
          other = shared(cells, digit, count, ROW) or shared(cells, digit, count, COLUMN)
        else
          other = shared(cells, digit, count, BOX)
        end
        -- Nothing to rule out where these are all the places it has in the other unit too
        if other and places[other + digit] > count then
          for _, cell in ipairs(UNITS[other]) do
            if ROW[cell] ~= unit and COLUMN[cell] ~= unit and BOX[cell] ~= unit and eliminate(cell, digit) then
              changed = true
            end
          end
        end
      end
    end
  end
  work = work + SCAN
  return changed
end

-- The two digits of every square that can take just two, as one number: used by nakedPairs
--- @type number[]
local twos = {}

--- Two squares of a unit that can both only take the same two digits take them between them:
--- neither digit can go anywhere else in the unit
--- @return boolean changed
local function nakedPairs()
  local changed = false
  for cell = 1, CELLS do
    local pair = 0
    if val[cell] == 0 and open[cell] == 2 then
      local base = (cell - 1) * SIDE
      for digit = 1, SIDE do
        if block[base + digit] == 0 then
          pair = pair * 10 + digit
        end
      end
    end
    twos[cell] = pair
  end
  for unit = 0, 26 * SIDE, SIDE do
    local cells = UNITS[unit]
    for index = 1, SIDE - 1 do
      local pair = twos[cells[index]]
      if pair ~= 0 then
        for other = index + 1, SIDE do
          if twos[cells[other]] == pair then
            local low, high = pair % 10, math.floor(pair / 10)
            for third = 1, SIDE do
              if third ~= index and third ~= other then
                local cell = cells[third]
                if eliminate(cell, low) then
                  changed = true
                end
                if eliminate(cell, high) then
                  changed = true
                end
              end
            end
          end
        end
      end
    end
  end
  work = work + SCAN
  return changed
end

-- The two squares of a unit a digit can go in, as one number, by digit: used by hiddenPairs
--- @type number[]
local spots = {}

--- Two digits that can both only go in the same two squares of a unit take those squares
--- between them: nothing else can go in either
--- @return boolean changed
local function hiddenPairs()
  local changed = false
  for unit = 0, 26 * SIDE, SIDE do
    local cells = UNITS[unit]
    for digit = 1, SIDE do
      local pair = 0
      if places[unit + digit] == 2 then
        for index = 1, SIDE do
          local cell = cells[index]
          if val[cell] == 0 and block[(cell - 1) * SIDE + digit] == 0 then
            pair = pair * 100 + cell
          end
        end
      end
      spots[digit] = pair
    end
    for digit = 1, SIDE - 1 do
      local pair = spots[digit]
      if pair ~= 0 then
        for other = digit + 1, SIDE do
          if spots[other] == pair then
            for _, cell in ipairs({ pair % 100, math.floor(pair / 100) }) do
              for third = 1, SIDE do
                if third ~= digit and third ~= other and eliminate(cell, third) then
                  changed = true
                end
              end
            end
          end
        end
      end
    end
  end
  work = work + SCAN
  return changed
end

--- Solves what is loaded as far as reasoning of a grade takes it
--- @param grade number 1 and 2 only ever write what was found, 3 rules digits out as well
--- @return boolean solved
local function deduce(grade)
  while drain() do
    if filled == CELLS or (watch and val[watch] ~= 0 and val[watchToo] ~= 0) then
      return true
    end
    if grade < 3 or not (locked() or nakedPairs() or hiddenPairs()) then
      return false
    end
  end
  return false
end

-----------------------------
-- Search
-----------------------------
-- Trying a digit and seeing what comes of it: what tells how many solutions a puzzle has, and
-- what fills an empty grid in. The grid as it was is kept for every digit that is tried, to go
-- back to.

--- @type { val: number[], block: number[], open: number[], places: number[], filled: number }[]
local kept = {}
-- The first solution a search came to, and whether it came to one yet
--- @type number[]
local answer = {}
local answered = false
-- A search is given up once this much has been done
local limit = math.huge
local gaveUp = false

--- @param depth number
local function keep(depth)
  local copy = kept[depth]
  if not copy then
    copy = { val = {}, block = {}, open = {}, places = {} }
    kept[depth] = copy
  end
  local keptVal, keptBlock, keptOpen, keptPlaces = copy.val, copy.block, copy.open, copy.places
  for key = 1, CELLS * SIDE do
    keptBlock[key] = block[key]
  end
  for cell = 1, CELLS do
    keptVal[cell], keptOpen[cell] = val[cell], open[cell]
  end
  for key = 1, 27 * SIDE do
    keptPlaces[key] = places[key]
  end
  copy.filled = filled
  work = work + 4
end

--- @param depth number
local function goBack(depth)
  local copy = kept[depth]
  -- The lists change hands: what was kept is worked on, and what was worked on is kept in next
  val, copy.val = copy.val, val
  block, copy.block = copy.block, block
  open, copy.open = copy.open, open
  places, copy.places = copy.places, places
  filled, queued, bad = copy.filled, 0, false
end

--- Counts the ways the grid can be finished from where it is, see `ways`
--- @param depth number How many digits were tried to get here, and one
--- @param most number Stop counting at this many
--- @param random Random?
--- @return number
local function search(depth, most, random)
  if not drain() then
    return 0
  end
  if filled == CELLS then
    if not answered then
      answered = true
      for cell = 1, CELLS do
        answer[cell] = val[cell]
      end
    end
    return 1
  end
  if work > limit then
    gaveUp = true
    return 0
  end

  -- The square that leaves the least to try
  local cell, least = nil, SIDE + 1
  for other = 1, CELLS do
    if val[other] == 0 and open[other] < least then
      cell, least = other, open[other]
      if least == 2 then
        break
      end
    end
  end
  local digits = {}
  for digit = 1, SIDE do
    if block[(cell - 1) * SIDE + digit] == 0 then
      digits[#digits + 1] = digit
    end
  end
  if random then
    random:Shuffle(digits)
  end

  local found = 0
  for index, digit in ipairs(digits) do
    local last = index == #digits
    if not last then
      keep(depth)
    end
    place(cell, digit)
    found = found + search(depth + 1, most - found, random)
    if found >= most or gaveUp or last then
      return found
    end
    goBack(depth)
  end
  return found
end

--- Counts the ways the grid that is loaded can be finished. The first one found is in `answer`
--- afterwards
--- @param most number Stop counting at this many
--- @param random Random? Try digits in an order it picks, for a grid that is filled in by chance
--- @param cap number? Give up once this much more work was done, which `gaveUp` says afterwards
--- @return number
local function ways(most, random, cap)
  watch, answered, gaveUp = false, false, false
  limit = cap and work + cap or math.huge
  return search(1, most, random)
end

-----------------------------
-- Puzzles
-----------------------------
-- A puzzle starts out as a full grid, filled in at random, that squares are taken out of. Each
-- time one goes the question is whether what is left can still be solved, and by what: that is
-- asked of the solver, which is why it has to be quick. Two things keep it so. The grid with
-- only the squares the puzzle comes with in it is kept from one question to the next, with a
-- square taken out or put back as that changes, instead of being built again. And a square
-- that was just taken out only has to be got back: with it the puzzle is one that was solved
-- before.
--
-- How hard a puzzle comes out is steered, not left to luck. Squares go for as long as the
-- puzzle stays easier than it should be, and then the one is looked for that makes it just hard
-- enough when it goes. Not every grid has one, so a harder puzzle may take a few grids, and
-- there is a limit to how much is done for one (WORK_MOST): past it the game is played with a
-- puzzle from stock (STOCK), mixed up so that it is never the same one twice.
--
-- All of this is part of the rules. A game isn't kept as its puzzle but as the chance it began
-- with and the moves made in it, and is put together again from those every time it is loaded:
-- a change to how puzzles are made puts another puzzle under the moves of every game that is
-- still being played. Bump `version` with it.

--- @class Sudoku
local Sudoku = {}
private.Sudoku = Sudoku

Sudoku.LEVELS = LEVELS
-- How a puzzle of each difficulty is made. First squares are taken out of the full grid two at
-- a time, for as long as what is left can be solved with reasoning of the grade `base` names,
-- and until only so many are left (`floor`). That is all an easy one takes. For the others
-- squares then go one at a time until the puzzle takes reasoning of `grade` and no more, see
-- Sudoku.Grade, and after that until `floor` are left
--- @type table<string, { base: { grade: number, floor: number }, grade: number?, floor: number? }>
local PLANS = {
  easy = { base = { grade = 1, floor = 38 } },
  medium = { base = { grade = 1, floor = 24 }, grade = 2, floor = 28 },
  hard = { base = { grade = 2, floor = 24 }, grade = 3, floor = 26 },
  expert = { base = { grade = 2, floor = 24 }, grade = 4, floor = 26 },
}
-- How much work making a puzzle may take before one from stock is used instead, and what a
-- single search may take while one is being made. Nothing new is begun past the first, so
-- whatever was being asked of the solver just then is all that can come on top of it.
--
-- This is what trades how long a puzzle can take against how often it is made to order. As it
-- is, a medium puzzle is from stock one time in twenty and a hard or an expert one about one
-- time in four, and none takes more than some thirty thousandths of a second where an easy one
-- takes one or two. Half as much again and it is one hard puzzle in eight, at twice the wait
local WORK_MOST, WORK_SEARCH = 8000, 1500

--- How many solutions a puzzle has
--- @param puzzle number[] A digit for every square, 0 for an empty one
--- @param most number? Stop counting at this many, 2 if left out: all that matters is whether there is exactly one
--- @return number count
--- @return number[]? solution The first that was found
function Sudoku.Count(puzzle, most)
  if not loadPuzzle(puzzle) then
    return 0, nil
  end
  begin(true)
  local count = ways(most or 2)
  return count, count > 0 and { unpack(answer) } or nil
end

--- What it takes to solve the grid that is loaded, see Sudoku.Grade
--- @param most number Don't try anything harder than this
--- @param capped boolean? Give up on a search that takes long
--- @param cell number? A square that was just taken out of a puzzle known to have one solution. Being able to fill it back in is as good as solving all of it then, and all that is looked at: what comes back is what that takes
--- @param twin number? Another that was taken out with it
--- @return number? grade nil if it takes more, or the puzzle doesn't have exactly one solution
local function rate(most, capped, cell, twin)
  watch, watchToo = cell or false, twin or cell or 0
  begin(false)
  if deduce(1) then
    return 1
  elseif bad or most < 2 then
    return nil
  end
  -- From here on a square with one digit left is something to go by. Which those are wasn't
  -- kept track of so far
  naked = true
  for other = 1, CELLS do
    if val[other] == 0 and open[other] == 1 then
      queued = queued + 1
      queue[queued] = other
    end
  end
  if deduce(2) then
    return 2
  elseif bad or most < 3 then
    return nil
  elseif deduce(3) then
    return 3
  elseif bad or most < 4 then
    return nil
  end
  return (ways(2, nil, capped and WORK_SEARCH or nil) == 1 and not gaveUp) and 4 or nil
end

--- What it takes to solve a puzzle
--- @param puzzle number[] A digit for every square, 0 for an empty one
--- @return number? grade 1 if looking for the only place a digit can go in a row, column or box is enough. 2 if it also takes looking for the only digit a square can take. 3 if digits have to be ruled out first, by where they must go in a box or a line or by pairs. 4 if even that doesn't do. nil for a puzzle that doesn't have exactly one solution
function Sudoku.Grade(puzzle)
  return loadPuzzle(puzzle) and rate(4) or nil
end

--- Fills a grid in at random
--- @param random Random
--- @return number[]? solution nil if it took too long
local function fill(random)
  reset(true)
  -- The three boxes down the middle share no row and no column: any nine digits will do for
  -- each, which leaves a lot less to try
  local digits = {}
  for digit = 1, SIDE do
    digits[digit] = digit
  end
  for box = 18, 26, 4 do
    random:Shuffle(digits)
    for index, cell in ipairs(UNITS[box * SIDE]) do
      place(cell, digits[index])
    end
  end
  if ways(1, random, WORK_SEARCH) ~= 1 then
    return nil
  end
  return { unpack(answer) }
end

--- Whether the grid that is loaded, which just had squares taken out of it, can still be solved.
--- It is left the way it was
--- @param most number With reasoning of this grade at most
--- @param cell number The square that was taken out
--- @param twin number? Another that was
--- @return number? grade What it takes to get them back, nil if they can't be
local function holds(most, cell, twin)
  keep(0)
  local grade = rate(most, true, cell, twin)
  goBack(0)
  return grade
end

--- Takes squares out of a full grid, two at a time that lie across the middle from each other,
--- for as long as what is left stays easy to solve. The grid is left loaded with what the puzzle
--- comes with
--- @param solution number[]
--- @param step { grade: number, floor: number } What easy means, and how many squares to stop at
--- @param random Random
--- @return number[] puzzle
--- @return number left How many squares it comes with
local function dig(solution, step, random)
  local puzzle, left = { unpack(solution) }, CELLS
  loadPuzzle(solution)
  local order = {}
  for cell = 1, (CELLS + 1) / 2 do
    order[cell] = cell
  end
  random:Shuffle(order)
  local singles = step.grade > 1
  for _, cell in ipairs(order) do
    if left <= step.floor or work > WORK_MOST then
      break
    end
    local twin = CELLS + 1 - cell
    local digit, other = solution[cell], solution[twin]
    unplace(cell, digit)
    local fine
    if twin == cell then
      fine = obvious(cell, digit, singles)
    else
      unplace(twin, other)
      -- Nothing has to be solved if the one square comes straight back with the other gone,
      -- and the other after that
      fine = obvious(cell, digit, singles)
      if fine then
        place(cell, digit)
        fine = obvious(twin, other, singles)
        unplace(cell, digit)
      end
    end
    if fine or holds(step.grade, cell, twin) then
      puzzle[cell], puzzle[twin] = 0, 0
      left = left - (twin == cell and 1 or 2)
    else
      place(cell, digit)
      if twin ~= cell then
        place(twin, other)
      end
    end
  end
  return puzzle, left
end

--- Goes on taking squares out of a puzzle, one at a time, until it is as hard as it should be.
--- Every square it still comes with is tried: one that makes it hard enough when it goes is
--- what was looked for. If there is none, one that can go without that is taken out and the
--- others like it are tried again, for as long as there are any
--- @param puzzle number[] The puzzle the grid is loaded with. Changed
--- @param left number How many squares it comes with
--- @param solution number[]
--- @param plan { grade: number, floor: number } How hard, and how many squares to stop at once it is
--- @param random Random
--- @return boolean reached False if it didn't get that hard
local function harden(puzzle, left, solution, plan, random)
  local rest = {}
  for cell = 1, CELLS do
    if puzzle[cell] ~= 0 then
      rest[#rest + 1] = cell
    end
  end
  random:Shuffle(rest)

  while #rest > 0 do
    local spare = {}
    for index, cell in ipairs(rest) do
      unplace(cell, solution[cell])
      local grade = holds(plan.grade, cell)
      if grade == plan.grade then
        -- Hard enough. A few more may go, if that leaves it no harder than it should be
        puzzle[cell], left = 0, left - 1
        for later = index + 1, #rest do
          if left <= plan.floor or work > WORK_MOST then
            break
          end
          local other = rest[later]
          unplace(other, solution[other])
          if holds(plan.grade, other) then
            puzzle[other], left = 0, left - 1
          else
            place(other, solution[other])
          end
        end
        return true
      end
      place(cell, solution[cell])
      if grade then
        spare[#spare + 1] = cell
      end
      if work > WORK_MOST then
        return false
      end
    end
    local cell = table.remove(spare)
    if cell then
      unplace(cell, solution[cell])
      puzzle[cell], left = 0, left - 1
    end
    rest = spare
  end
  return false
end

-- Puzzles to fall back on, a few for each difficulty: every one has exactly one solution and
-- is as hard as its difficulty says, which the tests check. They were made by Sudoku.Generate
-- itself. A dot is an empty square.
--- @type table<string, string[]>
local STOCK = {
  easy = {
    ".6.8..3.2379..1.8.....36.91714.5...92.......46...2.71354.97.....8.5..6471.7..4.2.",
    "....59.8..813.75.45..1.87...135..6.8...6.4...9.7..324...97.1..33.29.685..4.23....",
    "....9.18.1.9.53.2.2.416...963..1.54....2.4....12.8..978...492.3.2.87.4.1.45.2....",
    "..89...65...35..42.74.2..3.7.9.6.3..62.7.3.98..1.8.2.6.6..4.98.45..97...89...65..",
  },
  medium = {
    ".6.8..3.2.79..1.8.....3...17.4.5.................2.7.35...7.....8....64.1.7..4.2.",
    ".....9....813.7..45.....7...13...6.8.........9.7...24...9..1..33..9.685....2.....",
    "5..6...892.1..53........6..9.6...42.....4.....82...9.5..5........39..8.66....8..3",
    "...9.5.2....21...6..1....8.....3.2.5..51.6...3.6.7.....8....7..1...42....4.6.7...",
    "....5.3.8.45.1..2..23...9..2.....5.....5.7.....9.....6......28..3..6.45.9.8.3....",
    ".8..3...2.51..7.3.......6571..9..7......74.....4..8..6819.......7.1..92.4...5..7.",
    "7.3.......4273.....56.89...8.7..5...3.......5...3..2.14..12.59.....5761.......7..",
    ".1.2..9...3...7..8.......6....385..1.........7..624...49.......2..1...53..8..3.7.",
    ".5...97.....38..26...4.......16.2.38..8...4..36.7.89.......6...23..9......61...7.",
    "..73...1.......9.43..4..8.5...1.4.6..2..3..9..5.8.6...9.4.....32.6.......1...86..",
    "8....2.394....3..7..18...4.7..541...............268..4.7...69.....7....526.1....3",
    "9..1.....3.8..7...7526.8...2.5.......4.8.2.5.......3.....9.4572...2..6.9.....3..4",
    "..96.72.8...........1..2.97.2.4...7...5.6.3...9...3.8.71.2..9.......4...9.23.57..",
    "7......2...2..9.43..9......82..57....4..3..8....46..92......5..25.6..83..3......1",
    ".....4..3.6.9.7.1..74...8..5.....6...1...8.7...9.....5..8...16..9.4.6.5.7..2.....",
    "6..9.7.83..1..3...83...6..21.4........7...3........6.14..5...3..1.6..8..25.1....9",
    "31.7........9.4.76.....32....5....3187.....2592.........75.....68.3.9.......61.97",
    "..2...1...197..3....8..5..2.4..6....687...591....5..4.1.....8.5..4..291...6...2..",
    "...3175....5.........92..76..3....686.....7.985....1..53..64.........2....4179...",
    "6.31.....8...97.......4..58.92.....1.6...9.4.3.....69.27..3.......75...2.8...15.3",
    ".....7....2.13.7.9.5..621...1..8.6.....5.4.....8....9...429..3.6.2.75.1....3.....",
    "...8.9..2......96.4.72..8...1..3.....23...7......1..8...5..41.9.38......9..5.1...",
    ".....14......8...5.4275.....3....9.88...1...22.4....6.....2679.65..7......34.....",
    "..8265........7.2...6.81...8.....34.96.....75.37.....6...7..9...4.1........3921..",
  },
  hard = {
    "...4....9..5.3..1..3...74..85.7..9....6...7....71.5.68..32...9..2..6.1..1...94...",
    "12.....34..3..96......7..1.8....5.6....7.2....6.9....3.8..2......58..3..3.7....81",
    "..2.1.635.....6.9.........4.1..8...73.6...8.27..1...6.1...2.....7.3.....68..4.9..",
    ".16.8.........4..22.3.....9....18...9.16.73.....54....6.....9.57..4......2..3.47.",
    "..4268.1.62............78.....6.273...........417.3.....64..1.........73.1.39.5..",
    ".8......2.51..7.3.......65.1..9..7.....274.....4..8..68.9.......7.1..92.4...5..7.",
    "..3.......4273......6.89..78.7..5...3.......5...3..2.14..12.59.....576........7..",
    "..9.3.2.....1..49..8...5.......6...886.....522...1....4..7...1..26..9.....7.4.5..",
    "8....2.394....3..7..18...4.7..541...............268..4.7...69..........526......3",
    "9..1.....3.8..7...7526.....2.5.......4.8.2.5.......3.6...9.4.72...2..6.9.....3..4",
    "..4316..7..1..4..6..69..8.......8...4.......3...1.......8..12..3.....5..6..8931..",
    "31.72.......9.4..6.....32....5....3187......5.2.........75.....68...9.......61.97",
    "..2...1...197.....3.8..5..2.4..6....687...591....5..4.1..4..8.5..4..291...6...2..",
    ".1..8..4....5.......8.2.63...4.52..67.......16..73.5....7.4.8.......8....4..9..1.",
    "...3175....5.........92..76..3....686.2...7.985....1...3..6..........2....4179...",
    "6.3......8...97.......4..58.92.....1.6.3.9.4.3.....69.27..3.......75...2.....15..",
    "...14..79.....7....3.2..4.1..2.5....5.4...9.7......2..9.86...5.1..5.....24..79...",
    ".....7......13.7.9.5..621...1..8.6.....5.4.....8.2..9...4.9..3.6.2.75.1....3.....",
    "...1...85.....8...5..76..4..72.3...9.9.5.1.3.1...8.6...6..14..2...8.....42...5...",
    "..2.1.9.3.9..2...1.......8....1...78...296...36..84....7.....9.....6..3.6.1.3.8..",
    "........5.765.....4.58.2...9.86......37.4.19......53.2...7..5.9.....681.6........",
    "......5.6....7.9....943...7..8...79.7..8.3....94...2.39...156....2.4....3.1......",
    "1.98.2........4..9.....5....4.....26.3.1.9.5771.....8....67....4..9........4.13.2",
    ".6..347..43.8......1..6...29...7....7.4...6.8....1...71...2..6......3.4...864..7.",
  },
  expert = {
    "...45...9..5.3..1..3...74..85.7.69....6...7.....1.5.68..3....9..2..6.1..1...94...",
    ".....9....81..7..45..1..7...13...6.8...6.4.....7...24...9..1..33..9..85....2.....",
    "..2.1.635.....6.9.....9...4.1..82..73.6...8.27..13..6.....2.....7.3.....685.4.9..",
    ".8..3...2.51..7.3.......6571..9..7.....2.4.....4..8..6819.......7.1..92.4...5....",
    "..3.......4273.....56.89...8.7..5...3.......5...3..2.14..12.59.....5761.......7..",
    "..4...9..53...7..8.......64...385..1.........7..624...49.......2..1...53..8...27.",
    ".5...97.....385.26...4.......1..2.385.8...4.736.7..9.......6...23.89......61...7.",
    "..73...1.......9.43..4..8.5...1.4.6..2.....9..5.8.6...9.4..2..32.........1...86..",
    "8....2..94....3..7..18...4.7..541...............268..4.7...69..9.......526.1....3",
    ".1..6.5..5.8..........1.49.9....32..8..7.6..1..12......29.3.....4....8.6..5.4..1.",
    ".86.......2.9.3..8...6...4..3.8.1..41...5...75..7.4.6..5...7...9..4.8.3........2.",
    "...9.7.83..1..3...8....6..21.4........7...3........6.14..5...36.1.6..8..25.1....9",
    "..2.......197.....3.8..5..2.4..6....687...591....5..4.1..4..8.5.....2.1...6...2..",
    "....2.4........67.....5...3.95..372....6.5....634..91.7...4.....39...8....4.1....",
    "6.31.....8...97.......4..5..92.....1.6.3.9.4.3.....69.27..........75...2.....15.3",
    ".....7......13.7.9.5..621...1..8.6.....5.4.....8.2..9...429..3.6.2.7..1....3.....",
    "..8265........7.2...6.81...8.....34.96.....75.37.....6....4.9...4.1........392...",
    "........5.765.....4.58.2...9.86......3..4.1.......53.2...7..5.9.....681.6........",
    ".6..347...3.8......1..6...29...7....7.4...6.8....1...71...2..6......3.4...864..7.",
    "..7..63....8.3.7.5.....1.8.21......7...4.3...4......92.5.3.....9...1.5....694.8..",
    ".6..57...3..9....6.98..1.....6.3..2.4.......9.7..1.6.....5..14.9....3..8...67....",
    "7...8.24......1......67..9..2.3...76.57...83.8......2..1..92......4......42....69",
    "1.8...2.....25....96...8.7.73.6.........8.........3.97.7.1...4......6.....6...9.5",
    "....2....9..1.8...67.9.....86....4..24...1.89..34...51.....513....2.9..8....4....",
  },
}

--- The numbers from 0 to 8 in an order that keeps threes together: the threes are mixed up, and
--- so is each of them. Rows or columns of a grid put in that order still make a grid
--- @param random Random
--- @return number[]
local function lines(random)
  local order = {}
  for _, three in ipairs(random:Shuffle({ 0, 1, 2 })) do
    for _, line in ipairs(random:Shuffle({ 0, 1, 2 })) do
      order[#order + 1] = three * 3 + line
    end
  end
  return order
end

--- A puzzle from stock, turned into another one that is just as hard: its digits swapped for
--- each other, its rows and columns mixed up within their threes and the threes among
--- themselves, and the whole of it flipped over or not. There are over a million million ways
--- of doing that, so the same puzzle doesn't come up twice
--- @param random Random
--- @param level string
--- @return number[] puzzle
function Sudoku.Stock(random, level)
  local stock = STOCK[level]
  local text = stock[random:Roll(#stock)]
  local digits = {}
  for digit = 1, SIDE do
    digits[digit] = digit
  end
  random:Shuffle(digits)
  local rows, columns, flipped = lines(random), lines(random), random:Roll(2) == 2
  local puzzle = {}
  for row = 0, SIDE - 1 do
    for column = 0, SIDE - 1 do
      local from = flipped and (columns[column + 1] * SIDE + rows[row + 1]) or (rows[row + 1] * SIDE + columns[column + 1])
      puzzle[row * SIDE + column + 1] = digits[tonumber(text:sub(from + 1, from + 1))] or 0
    end
  end
  return puzzle
end

--- Every puzzle there is in stock, the way it is kept, for the tests to hold them to what they
--- promise
--- @return table<string, number[][]>
function Sudoku.AllStock()
  local all = {}
  for level, stock in pairs(STOCK) do
    all[level] = {}
    for index, text in ipairs(stock) do
      all[level][index] = {}
      for cell = 1, CELLS do
        all[level][index][cell] = tonumber(text:sub(cell, cell)) or 0
      end
    end
  end
  return all
end

--- Makes a puzzle: a grid with some of its squares filled in that can be finished in one way
--- only, as hard to do as a difficulty asks for. What comes out follows from `random` alone.
---
--- An easy puzzle always comes out at once. A harder one only comes of some grids, so there may
--- be a few tries, and when none came of it in time one from stock is used
--- @param random Random
--- @param level string One of Sudoku.LEVELS
--- @return number[] puzzle A digit for every square, 0 for an empty one
--- @return number[] solution
--- @return { work: number, tries: number, stock: boolean? } made How much went into it, and whether it is one from stock
function Sudoku.Generate(random, level)
  work = 0
  local tries = 0
  local plan = PLANS[level]
  while work < WORK_MOST do
    tries = tries + 1
    local solution = fill(random)
    if solution then
      local puzzle, left = dig(solution, plan.base, random)
      if work <= WORK_MOST and (not plan.grade or harden(puzzle, left, solution, plan, random)) then
        return puzzle, solution, { work = work, tries = tries }
      end
    end
  end
  local puzzle = Sudoku.Stock(random, level)
  local _, solution = Sudoku.Count(puzzle, 1)
  return puzzle, solution, { work = work, tries = tries, stock = true }
end

-- The puzzles that were made last, by the chance they were made from and their difficulty. A
-- game is put together again from its moves whenever one of them is taken back, and there is no
-- need to make its puzzle again for that
--- @type { key: string, puzzle: number[], solution: number[] }[]
local made = {}
local MADE_MOST = 6

--- The puzzle a game is played with
--- @param random Random
--- @param level string
--- @return number[] puzzle, number[] solution Not to be changed
local function puzzleFor(random, level)
  local key = random.value .. level
  for _, entry in ipairs(made) do
    if entry.key == key then
      return entry.puzzle, entry.solution
    end
  end
  local puzzle, solution = Sudoku.Generate(random, level)
  table.insert(made, 1, { key = key, puzzle = puzzle, solution = solution })
  made[MADE_MOST + 1] = nil
  return puzzle, solution
end

-----------------------------
-- Rules
-----------------------------

--- @class SudokuState
--- @field level string How hard the puzzle is, one of Sudoku.LEVELS
--- @field check boolean Whether a digit that is wrong is pointed out as it is written
--- @field solution number[] The digit that belongs in every square
--- @field grid number[] The digit that is in every square, 0 for none
--- @field given table<number, boolean> The squares the puzzle came with
--- @field hinted table<number, boolean> The squares that were filled in for the player
--- @field notes table<number, boolean> What is pencilled in: a square's nine come one after the other, the 7 of square 3 is 2 * 9 + 7
--- @field filled number How many squares hold a digit
--- @field mistakes number How many digits were written that were wrong
--- @field hints number How many squares the player had filled in
--- @field outcome { winner: number }?

--- @class SudokuEvent: MatchEvent
--- @field cell number The square it was about
--- @field digit number? What was written into it, 0 for a square that was rubbed out
--- @field was number? What was in it before
--- @field wrong boolean? What was written doesn't belong there
--- @field hint boolean? It was filled in for the player
--- @field note number? The digit that was pencilled in or rubbed out again
--- @field on boolean? Whether that note is there now
--- @field cleared number[]? The squares a note of the digit was taken out of because it was written
--- @field units string[]? What the digit completed: "r4" for the fourth row, "c7" for a column, "b2" for a box, see Sudoku.Unit
--- @field won boolean? It was the last one

local WRITE, ERASE, NOTE, HINT = "write", "erase", "note", "hint"

--- @param seats number
--- @param random Random
--- @param rules table<string, any>?
--- @return SudokuState
local function newState(_, random, rules)
  rules = private.Games.Rules(OPTIONS, rules)
  local puzzle, solution = puzzleFor(random, rules.level)
  --- @type SudokuState
  local state = {
    level = rules.level,
    check = rules.check,
    solution = solution,
    grid = { unpack(puzzle) },
    given = {},
    hinted = {},
    notes = {},
    filled = 0,
    mistakes = 0,
    hints = 0,
  }
  for cell = 1, CELLS do
    if puzzle[cell] ~= 0 then
      state.given[cell] = true
      state.filled = state.filled + 1
    end
  end
  return state
end

--- @param move string
--- @return string? kind WRITE, ERASE, NOTE or HINT, nil for anything that isn't a move written the one way it is written
--- @return number? cell
--- @return number? digit
local function read(move)
  local kind, row, column, digit = move:match("^([nh]?)([1-9])([1-9])(%d?)$")
  if not kind then
    return nil
  end
  local cell = (tonumber(row) - 1) * SIDE + tonumber(column)
  if kind == "h" then
    return digit == "" and HINT or nil, cell
  elseif digit == "" or (kind == "n" and digit == "0") then
    return nil
  elseif kind == "n" then
    return NOTE, cell, tonumber(digit)
  end
  return digit == "0" and ERASE or WRITE, cell, tonumber(digit)
end

--- How a move is written
--- @param kind string WRITE, ERASE, NOTE or HINT
--- @param cell number
--- @param digit number? For writing and for a note
--- @return string
local function moveFor(kind, cell, digit)
  local square = (math.floor((cell - 1) / SIDE) + 1) .. ((cell - 1) % SIDE + 1)
  if kind == HINT then
    return "h" .. square
  elseif kind == NOTE then
    return "n" .. square .. digit
  end
  return square .. (kind == ERASE and 0 or digit)
end

--- @param state SudokuState
--- @param cell number
--- @return boolean Whether anything is pencilled into a square
local function hasNotes(state, cell)
  for digit = 1, SIDE do
    if state.notes[(cell - 1) * SIDE + digit] then
      return true
    end
  end
  return false
end

--- @param state SudokuState
--- @param move string
--- @return string? error nil for a move that can be made
local function refusal(state, move)
  local kind, cell, digit = read(move)
  if not kind or state.outcome then
    return "invalid_move"
  elseif state.given[cell] or state.hinted[cell] then
    return "sudoku_fixed"
  end
  local there = state.grid[cell]
  if kind == WRITE then
    return there == digit and "invalid_move" or nil
  elseif kind == NOTE then
    return there ~= 0 and "sudoku_filled" or nil
  elseif kind == ERASE then
    return (there == 0 and not hasNotes(state, cell)) and "invalid_move" or nil
  end
  return there == state.solution[cell] and "invalid_move" or nil
end

--- @param state SudokuState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  if seat ~= 1 then
    return false, "not_your_turn"
  end
  local err = refusal(state, move)
  return err == nil, err
end

-- How every square is written in a move, by row and column: "52"
local SQUARES = {}
for cell = 1, CELLS do
  SQUARES[cell] = (math.floor((cell - 1) / SIDE) + 1) .. ((cell - 1) % SIDE + 1)
end

--- Every move there is in every square the player may still change: each digit written into
--- it, rubbing it out, each note pencilled in or rubbed out, and having it filled in. The same as
--- what refusal lets through, worked out square by square rather than move by move: a random
--- game asks for all of them after every move
--- @param state SudokuState
--- @return string[]
local function moves(state)
  local list = {}
  if state.outcome then
    return list
  end
  for cell = 1, CELLS do
    if not state.given[cell] and not state.hinted[cell] then
      local square, there = SQUARES[cell], state.grid[cell]
      for digit = 1, SIDE do
        if digit ~= there then
          list[#list + 1] = square .. digit
        end
        if there == 0 then
          list[#list + 1] = "n" .. square .. digit
        end
      end
      if there ~= 0 or hasNotes(state, cell) then
        list[#list + 1] = square .. "0"
      end
      if there ~= state.solution[cell] then
        list[#list + 1] = "h" .. square
      end
    end
  end
  return list
end

--- The squares of a row, a column or a box, by the name moves and events have for it
--- @param name string "r4" for the fourth row from the top, "c7" for the seventh column, "b2" for the second box, which are counted the way squares are
--- @return number[]
function Sudoku.Unit(name)
  return UNITS[((name:sub(1, 1) == "r" and 0 or (name:sub(1, 1) == "c" and SIDE or 2 * SIDE)) + tonumber(name:sub(2)) - 1) * SIDE]
end

--- The units a square is in, by name
--- @param cell number
--- @return string[]
local function unitsOf(cell)
  return { "r" .. ROW[cell] / SIDE + 1, "c" .. COLUMN[cell] / SIDE - SIDE + 1, "b" .. BOX[cell] / SIDE - 2 * SIDE + 1 }
end

--- Whether a unit is done: full, with every digit in it once. Where wrong digits are pointed
--- out they aren't taken for done either
--- @param state SudokuState
--- @param name string
--- @return boolean
local function complete(state, name)
  local seen = {}
  for _, cell in ipairs(Sudoku.Unit(name)) do
    local digit = state.grid[cell]
    if digit == 0 or seen[digit] or (state.check and digit ~= state.solution[cell]) then
      return false
    end
    seen[digit] = true
  end
  return true
end

--- @param state SudokuState
--- @param seat number
--- @param move string
--- @return SudokuEvent
local function apply(state, _, move)
  local kind, cell, digit = read(move)
  --- @type SudokuEvent
  local event = { cell = cell }
  if kind == NOTE then
    local key = (cell - 1) * SIDE + digit
    state.notes[key] = not state.notes[key] or nil
    event.note, event.on = digit, state.notes[key] == true
    return event
  end

  local was = state.grid[cell]
  event.was = was
  for other = 1, SIDE do
    state.notes[(cell - 1) * SIDE + other] = nil
  end
  if kind == ERASE then
    state.grid[cell] = 0
    state.filled = state.filled - (was ~= 0 and 1 or 0)
    event.digit = 0
    return event
  end

  if kind == HINT then
    digit = state.solution[cell]
    state.hinted[cell] = true
    state.hints = state.hints + 1
    event.hint = true
  end
  state.grid[cell] = digit
  state.filled = state.filled + (was == 0 and 1 or 0)
  event.digit = digit
  local wrong = digit ~= state.solution[cell]
  if wrong then
    state.mistakes = state.mistakes + 1
    event.wrong = true
  end

  -- The digit can't go anywhere else in its row, column and box now: the notes of it there
  -- are tidied away. Not for one that is pointed out as wrong, which is about to be rubbed out
  if not (wrong and state.check) then
    for _, peer in ipairs(PEERS[cell]) do
      local key = (peer - 1) * SIDE + digit
      if state.notes[key] then
        state.notes[key] = nil
        event.cleared = event.cleared or {}
        table.insert(event.cleared, peer)
      end
    end
  end
  for _, name in ipairs(unitsOf(cell)) do
    if complete(state, name) then
      event.units = event.units or {}
      table.insert(event.units, name)
    end
  end

  if state.filled == CELLS then
    local right = true
    for other = 1, CELLS do
      right = right and state.grid[other] == state.solution[other]
    end
    if right then
      state.outcome = { winner = 1 }
      event.won = true
    end
  end
  return event
end

--- The squares that hold a digit another square of their row, column or box holds too
--- @param grid number[] The digit in every square, 0 for none
--- @return table<number, boolean>
function Sudoku.Clashes(grid)
  local clashes = {}
  for cell = 1, CELLS do
    local digit = grid[cell]
    if digit ~= 0 then
      for _, peer in ipairs(PEERS[cell]) do
        if grid[peer] == digit then
          clashes[cell] = true
          break
        end
      end
    end
  end
  return clashes
end

--- How many of each digit are still to be written
--- @param grid number[]
--- @return number[] By digit. Less than nothing for one that is there too often
function Sudoku.Left(grid)
  local left = {}
  for digit = 1, SIDE do
    left[digit] = SIDE
  end
  for cell = 1, CELLS do
    if grid[cell] ~= 0 then
      left[grid[cell]] = left[grid[cell]] - 1
    end
  end
  return left
end

--- Which square a hint would best fill in
--- @param state SudokuState
--- @param cell number? The square the player is looking at, which it is if that one isn't right yet
--- @return number? cell nil if there is nothing left to fill in
function Sudoku.HintFor(state, cell)
  --- @param other number
  --- @return boolean
  local function wanting(other)
    return not state.given[other] and not state.hinted[other] and state.grid[other] ~= state.solution[other]
  end
  if cell and wanting(cell) then
    return cell
  end
  -- Otherwise the one that the grid leaves the least choice for: the one the player was the
  -- closest to finding
  local best, least = nil, SIDE + 1
  for other = 1, CELLS do
    if wanting(other) then
      local seen, choice = {}, SIDE
      for _, peer in ipairs(PEERS[other]) do
        local digit = state.grid[peer]
        if digit ~= 0 and not seen[digit] then
          seen[digit] = true
          choice = choice - 1
        end
      end
      if choice < least then
        best, least = other, choice
      end
    end
  end
  return best
end

-----------------------------
-- View
-----------------------------
-- The grid (GUI/NumberGrid.lua) with a pad of keys next to it, or under it where the window is
-- taller than wide, and a row of boxes over it all that say how the game is going: how hard it
-- is, how long it has been played for, how many digits were wrong and the best time there is
-- to beat.
--
-- The player picks a square by clicking it or with the arrow keys, and writes with the pad or
-- the keyboard. The square they are on is pointed out with its row, its column and its box,
-- and so is every square that holds the same digit. Digits that are twice in a row, column or
-- box are marked whatever the game was set up to point out.
--
-- Which square the player is on and whether they are pencilling notes is nobody's business but
-- the view's: neither is a move, and neither is kept with the game. Both are remembered for
-- every game that was looked at, so going to another game and coming back changes nothing. A
-- move taken back puts the player on the square it was about.

local INK = {
  given = { 0.93, 0.93, 0.96 },
  written = { 0.45, 0.76, 1 },
  hinted = { 1, 0.82, 0 },
  wrong = { 1, 0.36, 0.36 },
}
local TINT = {
  selected = { 0.2, 0.45, 0.85, 0.6 },
  same = { 1, 0.82, 0, 0.26 },
  clash = { 0.85, 0.12, 0.12, 0.5 },
  near = { 1, 1, 1, 0.07 },
}
local GRID = {
  columns = SIDE,
  rows = SIDE,
  boxColumns = 3,
  boxRows = 3,
  paper = { 0.09, 0.1, 0.13, 1 },
  paperOther = { 0.13, 0.14, 0.18, 1 },
}
-- What a square lights up in: when its row, column or box is done, when it was filled in for
-- the player, when a move about it was taken back, when a note went from it, and for the wave
-- that goes over the grid when it is solved
local GLOW = {
  unit = { 0.35, 0.9, 0.45, 0.55 },
  hint = { 1, 0.82, 0, 0.6 },
  undone = { 1, 1, 1, 0.3 },
  tidied = { 1, 1, 1, 0.14 },
  won = { 1, 0.82, 0, 0.6 },
}
-- Seconds from one square to the next when a row, column or box lights up, and from one
-- slanting line of squares to the next when the whole grid does
local SWEEP_GAP, WAVE_GAP = 0.045, 0.05
-- Seconds after the last digit until paper rains and the words come
local CONFETTI_AFTER, BANNER_AFTER = 0.5, 1.1
local STAT_HEIGHT, STAT_WIDTH = 38, 104
local GAP, KEY_GAP = 8, 4
-- A key of the pad next to the grid, as a multiple of a square of the grid
local KEY_BESIDE = 1.3
local TOOLS = { "notes", "erase", "hint" }
local SOUNDS = {
  write = "cardPlace",
  note = "cardSlide",
  erase = "cardSlide",
  wrong = "IG_QUEST_LOG_ABANDON_QUEST",
  unit = "IG_QUEST_LIST_COMPLETE",
  won = "UI_EPICLOOT_TOAST",
  refused = "IG_MAINMENU_OPTION_CHECKBOX_OFF",
  on = "IG_MAINMENU_OPTION_CHECKBOX_ON",
  off = "IG_MAINMENU_OPTION_CHECKBOX_OFF",
}
-- Where an arrow key takes the player: columns and rows on from the square they are on
local STEPS = { LEFT = { -1, 0 }, RIGHT = { 1, 0 }, UP = { 0, -1 }, DOWN = { 0, 1 } }
local MIDDLE = (CELLS + 1) / 2

--- @class SudokuView: GameViewObject
--- @field stage Frame
--- @field grid NumberGrid
--- @field pad table The keys to write with, see NumberGrid.Pad
--- @field stats table<string, Frame> The boxes over the grid, by what they count
--- @field effects Effects
--- @field view GameView? What was last asked for
--- @field selected number? The square the player is on
--- @field pencil boolean Whether digits are pencilled in as notes
--- @field memory table<string, { selected: number?, pencil: boolean }> Where the player was in the other games that were looked at, by match id
--- @field mode string "beside" or "under": where the pad is
--- @field shownSeconds number? What the clock says
--- @field last { ply: number, event: SudokuEvent? }? The position that was shown last, and the move that led to it
local View = {}
View.__index = View

--- @param stage Frame
--- @return SudokuView
local function createView(stage)
  --- @type SudokuView
  local self = setmetatable({ stage = stage, pencil = false, memory = {}, mode = "beside" }, View)
  local Widgets = private.Widgets
  self.figures, self.inks, self.notes, self.tints = {}, {}, {}, {}

  self.stats = {
    level = Widgets.Stat(stage, L["sudoku_option_level"], STAT_WIDTH, STAT_HEIGHT),
    time = Widgets.Stat(stage, L["stat_time"], STAT_WIDTH, STAT_HEIGHT),
    mistakes = Widgets.Stat(stage, L["sudoku_mistakes"], STAT_WIDTH, STAT_HEIGHT),
    best = Widgets.Stat(stage, L["stat_best"], STAT_WIDTH, STAT_HEIGHT),
  }

  self.grid = private.NumberGrid.New(stage, GRID)
  self.grid:SetInput({
    onClick = function(square, button)
      self:click(square, button)
    end,
  })

  self.pad = private.NumberGrid.Pad(stage, SIDE, TOOLS, function(digit)
    self:enter(digit)
  end, function(tool)
    self:tool(tool)
  end)
  for _, tool in ipairs(TOOLS) do
    self.pad.tools[tool]:Set(L["sudoku_" .. tool])
    self.pad.tools[tool]:SetTip(L["sudoku_" .. tool], L["sudoku_" .. tool .. "_tip"])
  end

  self.effects = private.Effects.New(stage)

  -- Takes the keys, and keeps the clock going
  local keys = CreateFrame("Frame", nil, stage)
  keys:SetAllPoints()
  Widgets.Keys(keys, function(key)
    return self:key(key)
  end)
  keys:SetScript("OnUpdate", function()
    self:tick()
  end)
  self.keys = keys
  return self
end

-----------------------------
-- Layout
-----------------------------

--- @param width number
--- @param height number
function View:Layout(width, height)
  local room = height - STAT_HEIGHT - GAP
  -- Next to the grid the pad is three keys wide, under it two keys high. Whichever leaves the
  -- grid larger is how it is laid out
  local beside = math.min(room, math.floor((width - GAP - 2 * KEY_GAP) / (1 + 3 * KEY_BESIDE / SIDE)))
  local under = math.min(width, math.floor((room - GAP - KEY_GAP) / (1 + 2 / SIDE)))
  self.mode = beside >= under and "beside" or "under"

  local grid, pad = self.grid, self.pad
  grid:SetSize(math.max(SIDE, self.mode == "beside" and beside or under))
  local side = grid.frame:GetWidth()
  local padWidth, padHeight, blockWidth, blockHeight
  if self.mode == "beside" then
    -- Four rows of keys are never higher than the grid
    local key = math.floor(math.min(side / SIDE * KEY_BESIDE, (side - 3 * KEY_GAP) / 4))
    padWidth, padHeight = pad:Layout(3, key, KEY_GAP)
    blockWidth, blockHeight = side + GAP + padWidth, side
  else
    padWidth, padHeight = pad:Layout(SIDE, math.floor((side - (SIDE - 1) * KEY_GAP) / SIDE), KEY_GAP)
    blockWidth, blockHeight = side, side + GAP + padHeight
  end

  local left = math.floor((width - blockWidth) / 2)
  local top = math.floor((height - STAT_HEIGHT - GAP - blockHeight) / 2)
  local order = { "level", "time", "mistakes", "best" }
  local statWidth = math.min(STAT_WIDTH, math.floor((width - (#order - 1) * GAP) / #order))
  local statLeft = math.floor((width - #order * statWidth - (#order - 1) * GAP) / 2)
  for index, name in ipairs(order) do
    local stat = self.stats[name]
    stat:SetSize(statWidth, STAT_HEIGHT)
    stat:ClearAllPoints()
    stat:SetPoint("TOPLEFT", self.stage, "TOPLEFT", statLeft + (index - 1) * (statWidth + GAP), -top)
  end

  top = top + STAT_HEIGHT + GAP
  grid.frame:ClearAllPoints()
  pad.frame:ClearAllPoints()
  if self.mode == "beside" then
    grid.frame:SetPoint("TOPLEFT", self.stage, "TOPLEFT", left, -top)
    pad.frame:SetPoint("TOPLEFT", self.stage, "TOPLEFT", left + side + GAP, -(top + math.floor((side - padHeight) / 2)))
  else
    grid.frame:SetPoint("TOPLEFT", self.stage, "TOPLEFT", left, -top)
    pad.frame:SetPoint("TOPLEFT", self.stage, "TOPLEFT", left + math.floor((side - padWidth) / 2), -(top + side + GAP))
  end
end

-----------------------------
-- Drawing
-----------------------------

--- @param one number
--- @param other number
--- @return boolean Whether two squares share a row, a column or a box
local function near(one, other)
  return ROW[one] == ROW[other] or COLUMN[one] == COLUMN[other] or BOX[one] == BOX[other]
end

--- Shows the position, at once: what is written and pencilled in, what is pointed out, what
--- the keys say and how the game is going
--- @param loud boolean? Draw the eye to a count that changed: it did because of a move just made
function View:draw(loud)
  local view = self.view
  --- @type SudokuState
  local state = view.state
  local grid, board = state.grid, self.grid
  local selected = view.canMove and self.selected or nil
  local same = selected and grid[selected] ~= 0 and grid[selected] or nil
  local clashes = Sudoku.Clashes(grid)

  local figures, inks, notes, tints = self.figures, self.inks, self.notes, self.tints
  for cell = 1, CELLS do
    local digit = grid[cell]
    figures[cell] = digit ~= 0 and digit or nil
    if state.given[cell] then
      inks[cell] = INK.given
    elseif state.hinted[cell] then
      inks[cell] = INK.hinted
    else
      inks[cell] = (state.check and digit ~= state.solution[cell]) and INK.wrong or INK.written
    end

    local pencilled = nil
    if digit == 0 then
      for note = 1, SIDE do
        if state.notes[(cell - 1) * SIDE + note] then
          pencilled = (pencilled or "") .. note
        end
      end
    end
    notes[cell] = pencilled

    if cell == selected then
      tints[cell] = TINT.selected
    elseif clashes[cell] then
      tints[cell] = TINT.clash
    elseif same and digit == same then
      tints[cell] = TINT.same
    else
      tints[cell] = (selected and near(cell, selected)) and TINT.near or nil
    end
  end
  board:SetFigures(figures, inks)
  board:SetNotes(notes, same and tostring(same) or nil)
  board:SetTints(tints)
  board:Select(selected)
  board:SetEnabled(view.canMove)

  -- A key says how many of its digit are still to be written, and is dimmed once they all are
  local left = Sudoku.Left(grid)
  for digit, key in ipairs(self.pad.keys) do
    key:Set(digit, left[digit] > 0 and left[digit] or "")
    key:SetDim(not view.canMove or left[digit] <= 0)
  end
  local tools = self.pad.tools
  tools.notes:Set(L["sudoku_notes"], L[self.pencil and "option_on" or "option_off"])
  tools.notes:SetOn(self.pencil and view.canMove)
  for _, tool in ipairs(TOOLS) do
    tools[tool]:SetDim(not view.canMove)
  end

  local stats = self.stats
  stats.level:Set(L["sudoku_level_" .. state.level], true)
  -- Counting what isn't pointed out would point it out
  stats.mistakes:Set((state.check or state.outcome) and state.mistakes or L["stat_none"], not loud)
  stats.mistakes:Tint((state.check and state.mistakes > 0) and INK.wrong or nil)
  local best, mine = view.best(state.level)
  stats.best:Set(best and private.Widgets.Time(best) or L["stat_none"], true)
  stats.best:Tint(mine and private.Widgets.GOLD or nil)
  self:tick()
end

--- Keeps the clock up to date
function View:tick()
  local seconds = self.view and math.floor(self.view.clock())
  if seconds and seconds ~= self.shownSeconds then
    self.shownSeconds = seconds
    self.stats.time:Set(private.Widgets.Time(seconds), true)
  end
end

--- Says across the grid that it is solved, in how long, and what that is worth
--- @param instant boolean For a game that was over before it was looked at
function View:banner(instant)
  local view = self.view
  --- @type SudokuState
  local state = view.state
  local time = private.Widgets.Time(view.clock())
  local _, mine = view.best(state.level)
  local subtitle = time
  if state.hints > 0 then
    subtitle = L["sudoku_time_hints"]:format(time, state.hints)
  elseif mine then
    subtitle = L["sudoku_time_best"]:format(time, L["new_best"])
  end
  self.effects:Banner(L["sudoku_solved"], subtitle, { instant = instant, delay = BANNER_AFTER })
end

--- Shows a move being made: the position as it is now, and what the move did to get there
--- @param event SudokuEvent
function View:play(event)
  --- @type SudokuState
  local state = self.view.state
  local board = self.grid
  self.selected = event.cell
  self:draw(true)

  if event.note then
    private.Widgets.PlaySound(SOUNDS.note)
    return
  elseif event.digit == 0 then
    private.Widgets.PlaySound(SOUNDS.erase)
    return
  end

  board:Pop(event.cell)
  if event.wrong and state.check then
    board:Shake(event.cell)
    private.Widgets.PlaySound(SOUNDS.wrong)
  else
    private.Widgets.PlaySound(SOUNDS.write)
  end
  if event.hint then
    board:Flash(event.cell, GLOW.hint)
  end
  for _, cell in ipairs(event.cleared or {}) do
    board:Flash(cell, GLOW.tidied)
  end

  -- A row, column or box that is done lights up from the square that finished it outwards
  local column, row = (event.cell - 1) % SIDE, math.floor((event.cell - 1) / SIDE)
  for _, name in ipairs(event.units or {}) do
    for _, cell in ipairs(Sudoku.Unit(name)) do
      local far = math.abs((cell - 1) % SIDE - column) + math.abs(math.floor((cell - 1) / SIDE) - row)
      board:Flash(cell, GLOW.unit, far * SWEEP_GAP)
    end
  end
  if event.units and not event.won then
    private.Widgets.PlaySound(SOUNDS.unit)
  end

  if event.won then
    -- And the whole grid from its top left corner to the bottom right
    for cell = 1, CELLS do
      board:Flash(cell, GLOW.won, ((cell - 1) % SIDE + math.floor((cell - 1) / SIDE)) * WAVE_GAP)
    end
    self.effects:Confetti(CONFETTI_AFTER)
    self:banner(false)
    private.Widgets.PlaySound(SOUNDS.won)
  end
end

--- @param view GameView
function View:Update(view)
  local before, last = self.view, self.last
  self.view = view
  -- The move that led here, to know what a move taken back was about
  self.last = { ply = view.ply, event = view.events[view.ply] }
  --- @type SudokuState
  local state = view.state

  if not before or before.match.id ~= view.match.id then
    -- Another game: what was going on in the one before is over, and where the player was in
    -- it is kept for when they come back to it
    if before then
      self.memory[before.match.id] = { selected = self.selected, pencil = self.pencil }
    end
    local kept = self.memory[view.match.id] or {}
    self.selected, self.pencil = kept.selected, kept.pencil == true
    self.grid:Settle()
    self.effects:Clear()
    self:draw()
  elseif not view.changed then
    self:draw()
  elseif view.played then
    self:play(view.played)
  else
    -- A move was taken back. Nothing that it set off should go on, and the player is put on
    -- the square it was about, which lights up to say so
    self.grid:Settle()
    self.effects:Clear()
    local undone = last and last.ply == view.ply + 1 and last.event or nil
    if undone and undone.cell then
      self.selected = undone.cell
    end
    self:draw()
    if undone and undone.cell then
      self.grid:Flash(undone.cell, GLOW.undone)
    end
  end

  -- A game that is solved says so for as long as it is looked at
  if state.outcome and not self.effects:HasBanner() then
    self:banner(true)
  end
end

-----------------------------
-- Playing
-----------------------------

--- Says that something can't be done: the square it was about shakes its head, or the keys do
--- @param cell number?
function View:refuse(cell)
  if cell then
    self.grid:Shake(cell)
  else
    self.effects:Jolt(self.pad.frame, 4)
  end
  private.Widgets.PlaySound(SOUNDS.refused)
end

--- A square was clicked
--- @param square number
--- @param button string
function View:click(square, button)
  if not self.view.canMove then
    return
  end
  -- Any other button means "never mind": the player is on no square then
  self.selected = button == "LeftButton" and square or nil
  self:draw()
end

--- A digit was asked for, on the pad or on the keyboard: it is written into the square the
--- player is on, or pencilled into it, and rubbed out again if it is there already
--- @param digit number
function View:enter(digit)
  local view, cell = self.view, self.selected
  if not view or not view.canMove then
    return
  end
  --- @type SudokuState
  local state = view.state
  if not cell or Sudoku.Left(state.grid)[digit] <= 0 and state.grid[cell] ~= digit then
    -- Nowhere to write it, or nine of it are there already
    self:refuse(cell)
    return
  end
  local move
  if self.pencil then
    move = moveFor(NOTE, cell, digit)
  elseif state.grid[cell] == digit then
    move = moveFor(ERASE, cell)
  else
    move = moveFor(WRITE, cell, digit)
  end
  if refusal(state, move) then
    self:refuse(cell)
  else
    view.submit(move)
  end
end

--- Rubs out what is in the square the player is on
function View:erase()
  local view, cell = self.view, self.selected
  if not view or not view.canMove then
    return
  end
  if not cell or refusal(view.state, moveFor(ERASE, cell)) then
    self:refuse(cell)
  else
    view.submit(moveFor(ERASE, cell))
  end
end

--- Has a square filled in: the one the player is on if that isn't right yet
function View:hint()
  local view = self.view
  if not view or not view.canMove then
    return
  end
  local cell = Sudoku.HintFor(view.state, self.selected)
  if not cell then
    self:refuse(self.selected)
    return
  end
  view.submit(moveFor(HINT, cell))
end

--- One of the keys under the digits was pressed
--- @param tool string
function View:tool(tool)
  if not self.view or not self.view.canMove then
    return
  end
  if tool == "notes" then
    self.pencil = not self.pencil
    private.Widgets.PlaySound(self.pencil and SOUNDS.on or SOUNDS.off)
    self:draw()
  elseif tool == "erase" then
    self:erase()
  else
    self:hint()
  end
end

--- A key was pressed with the cursor over the game
--- @param key string The client's name for it
--- @return boolean used
function View:key(key)
  local view = self.view
  if not view or not view.canMove or not self.stage:IsVisible() then
    return false
  end
  -- The digits along the top of the keyboard and the ones of the number pad
  local digit = tonumber(key:match("^NUMPAD(%d)$") or key:match("^%d$"))
  local step = STEPS[key]
  if digit == 0 or key == "BACKSPACE" or key == "DELETE" then
    self:erase()
  elseif digit then
    self:enter(digit)
  elseif step then
    -- Off one edge and back on at the other. With no square to start from it is the middle one
    local cell = self.selected
    if cell then
      local column, row = ((cell - 1) % SIDE + step[1]) % SIDE, (math.floor((cell - 1) / SIDE) + step[2]) % SIDE
      cell = row * SIDE + column + 1
    end
    self.selected = cell or MIDDLE
    self:draw()
  elseif key == "N" or key == "SPACE" then
    self:tool("notes")
  else
    return false
  end
  return true
end


private.Games.Register({
  id = "sudoku",
  name = L["game_sudoku"],
  description = L["game_sudoku_description"],
  genre = "solo",
  icon = "Interface\\AddOns\\ForeverGames\\Images\\Icons\\sudoku",
  version = 1,
  seats = 1,
  options = OPTIONS,
  undo = true,
  clock = "open",
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
    return L["sudoku_progress"]:format(state.filled, CELLS)
  end,
  -- The best time for each difficulty, and only for a game the player solved all by themselves
  record = function(state, seconds, result)
    if result and result.winner == 1 and state.hints == 0 then
      return { { key = state.level, value = seconds, lower = true } }
    end
    return nil
  end,
  -- The day's puzzle is a middling one, timed for whoever solved it all by themselves
  daily = {
    score = function(state, seconds, result)
      return result.winner == 1 and state.hints == 0 and seconds or nil
    end,
    lower = true,
    time = true,
  },
  createView = createView,
})
