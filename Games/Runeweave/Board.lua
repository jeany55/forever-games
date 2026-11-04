--------------------------
--  Runeweave: the board, and a swap played out on it
--------------------------
-- The rules side of Runeweave, with nothing in it that touches the game client: a board of runes
-- laid out from the match's chance, which swaps make a line, and everything that follows from
-- one: lines cleared, runes of power made and set off, the runes above falling into the gaps and
-- new ones coming in from the top, again and again until nothing more lines up. It runs inside
-- the game's rules on every client that replays the match, so it takes its chance from `random`
-- and nowhere else, and every step of what happened is kept for the view to play back.
--
-- The board is SIZE squares a side, numbered 1 to SQUARES along the rows from the top left. A
-- square holds a rune as one number, Value(school, kind): the school of magic it belongs to,
-- 1 to SCHOOLS, and what kind of rune it is:
--   PLAIN    an ordinary rune
--   ROW      charged: when it is cleared, a bolt clears its whole row
--   COLUMN   the same, down its column
--   NOVA     when it is cleared, it bursts and clears everything within two steps of it
--   PRISM    belongs to no school. Swapped with a rune, it clears every rune of that rune's
--            school; with another prism, the whole board. Cleared any other way, it takes the
--            school there is most of
-- 0 is a square with nothing in it, which is only ever seen in the middle of working a swap out.
--
-- A line of four makes a charged rune, which bolts the way the four lay; two lines of a school
-- that cross (an L, a T or a plus) make a nova; five in a line make a prism. The new rune is
-- made where the player moved a rune to, if that is in the line, and otherwise where the lines
-- cross or in the middle of the longest of them.

local _, private = ...
private.Runeweave = private.Runeweave or {}
local own = private.Runeweave

local Board = {}
own.Board = Board

local floor, min, max, abs = math.floor, math.min, math.max, math.abs

local SIZE = 8
local SQUARES = SIZE * SIZE
local SCHOOLS = 6
local PLAIN, ROW, COLUMN, NOVA, PRISM = 0, 1, 2, 3, 4
-- A value is kind * KIND + school
local KIND = 8
-- How far a nova reaches, in steps across and down together
local NOVA_REACH = 2
-- Points: a line of n is worth LINE * (n - 2), every rune cleared by a power POWER, and the lot
-- times how deep in the cascade it came and the level
local LINE, POWER = 50, 20
-- How many times a board is shuffled looking for one with a move and no line, before a new one is laid
local SHUFFLES = 200

Board.SIZE, Board.SQUARES, Board.SCHOOLS = SIZE, SQUARES, SCHOOLS
Board.PLAIN, Board.ROW, Board.COLUMN, Board.NOVA, Board.PRISM = PLAIN, ROW, COLUMN, NOVA, PRISM
Board.LINE, Board.POWER = LINE, POWER

--- @param value integer
--- @return integer school 0 for an empty square or a prism
function Board.School(value)
  return value % KIND
end

--- @param value integer
--- @return integer
function Board.Kind(value)
  return floor(value / KIND)
end

--- @param school integer
--- @param kind integer?
--- @return integer
function Board.Value(school, kind)
  return (kind or PLAIN) * KIND + (kind == PRISM and 0 or school)
end

local School, Kind, Value = Board.School, Board.Kind, Board.Value

--- The row and column of a square, both from 0, the row from the top
--- @param square integer
--- @return integer row, integer column
function Board.Place(square)
  return floor((square - 1) / SIZE), (square - 1) % SIZE
end

--- @param row integer
--- @param column integer
--- @return integer? square nil off the board
function Board.Square(row, column)
  if row < 0 or row >= SIZE or column < 0 or column >= SIZE then
    return nil
  end
  return row * SIZE + column + 1
end

local Place, Square = Board.Place, Board.Square

local function copy(board)
  local out = {}
  for index = 1, SQUARES do
    out[index] = board[index]
  end
  return out
end
Board.Copy = copy

-----------------------------
-- Lines
-----------------------------

--- Every line of three or more of a school, across and then down
--- @param board integer[]
--- @return { cells: integer[], across: boolean, school: integer }[]
local function runs(board)
  local list = {}
  for across = 1, 0, -1 do
    for line = 0, SIZE - 1 do
      local step = 0
      while step < SIZE do
        local first = across == 1 and Square(line, step) or Square(step, line)
        local school = School(board[first])
        local length = 1
        if school > 0 then
          while step + length < SIZE do
            local next = across == 1 and Square(line, step + length) or Square(step + length, line)
            if School(board[next]) ~= school or Kind(board[next]) == PRISM then
              break
            end
            length = length + 1
          end
        end
        if school > 0 and Kind(board[first]) ~= PRISM and length >= 3 then
          local cells = {}
          for k = 0, length - 1 do
            cells[#cells + 1] = across == 1 and Square(line, step + k) or Square(step + k, line)
          end
          list[#list + 1] = { cells = cells, across = across == 1, school = school }
        end
        step = step + length
      end
    end
  end
  return list
end

--- @class RuneweaveGroup
--- @field cells integer[] Every square of it, each once
--- @field runs { cells: integer[], across: boolean }[] The lines it is made of
--- @field school integer
--- @field kind integer What it makes: PLAIN for nothing
--- @field at integer? Where it makes it

--- The lines on a board, those of a school that share a square joined into one group, with what
--- each makes and where
--- @param board integer[]
--- @param moved integer[]? The squares the player just moved runes to, where a rune of power is made first
--- @return RuneweaveGroup[]
function Board.Groups(board, moved)
  local owner, list = {}, {}
  for _, run in ipairs(runs(board)) do
    local into
    for _, cell in ipairs(run.cells) do
      local other = owner[cell]
      if other and other ~= into then
        if not into then
          into = other
        else
          -- Two groups this line runs through become one
          for _, moving in ipairs(other.cells) do
            owner[moving] = into
            into.cells[#into.cells + 1] = moving
          end
          for _, line in ipairs(other.runs) do
            into.runs[#into.runs + 1] = line
          end
          other.dead = true
        end
      end
    end
    if not into then
      into = { cells = {}, runs = {}, school = run.school }
      list[#list + 1] = into
    end
    into.runs[#into.runs + 1] = run
    for _, cell in ipairs(run.cells) do
      if owner[cell] ~= into then
        owner[cell] = into
        into.cells[#into.cells + 1] = cell
      end
    end
  end

  local groups = {}
  for _, group in ipairs(list) do
    if not group.dead then
      groups[#groups + 1] = group
      local longest, across, down, crossing = nil, false, false, nil
      local count = {}
      for _, run in ipairs(group.runs) do
        if not longest or #run.cells > #longest.cells then
          longest = run
        end
        across = across or run.across
        down = down or not run.across
        for _, cell in ipairs(run.cells) do
          count[cell] = (count[cell] or 0) + 1
          if count[cell] == 2 and not crossing then
            crossing = cell
          end
        end
      end
      if #longest.cells >= 5 then
        group.kind = PRISM
      elseif across and down then
        group.kind = NOVA
      elseif #longest.cells == 4 then
        group.kind = longest.across and ROW or COLUMN
      else
        group.kind = PLAIN
      end
      if group.kind ~= PLAIN then
        local at
        for _, square in ipairs(moved or {}) do
          if not at and owner[square] == group then
            at = square
          end
        end
        group.at = at or crossing or longest.cells[floor((#longest.cells + 1) / 2)]
      end
    end
  end
  return groups
end

--- Whether a line runs through a square
--- @param board integer[]
--- @param square integer
--- @return boolean
local function lineThrough(board, square)
  local value = board[square]
  local school = School(value)
  if school == 0 or Kind(value) == PRISM then
    return false
  end
  local row, column = Place(square)
  local function same(r, c)
    local other = Square(r, c)
    return other ~= nil and School(board[other]) == school and Kind(board[other]) ~= PRISM
  end
  for _, step in ipairs({ { 0, 1 }, { 1, 0 } }) do
    local length = 1
    local k = 1
    while same(row + step[1] * k, column + step[2] * k) do
      length, k = length + 1, k + 1
    end
    k = 1
    while same(row - step[1] * k, column - step[2] * k) do
      length, k = length + 1, k + 1
    end
    if length >= 3 then
      return true
    end
  end
  return false
end

-----------------------------
-- Swaps
-----------------------------

--- The two squares of a move, the second right of or below the first
--- @param move any
--- @return integer? a, integer? b
function Board.Swap(move)
  if type(move) ~= "string" or #move > 4 then
    return nil
  end
  local digits, way = move:match("^s(%d+)([rd])$")
  local index = digits and tonumber(digits)
  -- Written the one way, so that no swap can be written two
  if not index or index >= SQUARES or tostring(index) ~= digits then
    return nil
  end
  local a = index + 1
  local row, column = Place(a)
  local b
  if way == "r" then
    b = Square(row, column + 1)
  else
    b = Square(row + 1, column)
  end
  if not b then
    return nil
  end
  return a, b
end

--- How a swap of two squares next to each other is written
--- @param a integer
--- @param b integer
--- @return string? nil for two squares that aren't next to each other
function Board.Write(a, b)
  a, b = min(a, b), max(a, b)
  local ra, ca = Place(a)
  local rb, cb = Place(b)
  if ra == rb and cb == ca + 1 then
    return "s" .. (a - 1) .. "r"
  elseif ca == cb and rb == ra + 1 then
    return "s" .. (a - 1) .. "d"
  end
  return nil
end

--- Whether swapping two squares does anything: makes a line, or sets off a prism
--- @param board integer[]
--- @param a integer
--- @param b integer
--- @return boolean
function Board.Works(board, a, b)
  local va, vb = board[a], board[b]
  if va == 0 or vb == 0 then
    return false
  elseif Kind(va) == PRISM or Kind(vb) == PRISM then
    return true
  elseif va == vb then
    return false
  end
  board[a], board[b] = vb, va
  local works = lineThrough(board, a) or lineThrough(board, b)
  board[a], board[b] = va, vb
  return works
end

--- Every swap that does something, as moves
--- @param board integer[]
--- @return string[]
function Board.Moves(board)
  local list = {}
  for a = 1, SQUARES do
    local row, column = Place(a)
    local right, down = Square(row, column + 1), Square(row + 1, column)
    if right and Board.Works(board, a, right) then
      list[#list + 1] = "s" .. (a - 1) .. "r"
    end
    if down and Board.Works(board, a, down) then
      list[#list + 1] = "s" .. (a - 1) .. "d"
    end
  end
  return list
end

--- Whether any swap does something
--- @param board integer[]
--- @return boolean
function Board.CanMove(board)
  for a = 1, SQUARES do
    local row, column = Place(a)
    local right, down = Square(row, column + 1), Square(row + 1, column)
    if (right and Board.Works(board, a, right)) or (down and Board.Works(board, a, down)) then
      return true
    end
  end
  return false
end

-----------------------------
-- Laying out
-----------------------------

--- A fresh board with no line on it and at least one swap that makes one
--- @param random Random
--- @return integer[]
function Board.Make(random)
  while true do
    local board = {}
    for square = 1, SQUARES do
      local row, column = Place(square)
      -- Never the school that would make three across or down with the two before it
      local left = column >= 2 and board[square - 1] == board[square - 2] and board[square - 1] or nil
      local above = row >= 2 and board[square - SIZE] == board[square - 2 * SIZE] and board[square - SIZE] or nil
      local choices = {}
      for school = 1, SCHOOLS do
        if school ~= left and school ~= above then
          choices[#choices + 1] = school
        end
      end
      board[square] = choices[random:Roll(#choices)]
    end
    if Board.CanMove(board) then
      return board
    end
  end
end

--- The same runes in another order, with no line on it and a swap that makes one, or a fresh
--- board if no order of them will do
--- @param board integer[]
--- @param random Random
--- @return integer[]
function Board.Shuffle(board, random)
  local runes = copy(board)
  for _ = 1, SHUFFLES do
    random:Shuffle(runes)
    if #Board.Groups(runes) == 0 and Board.CanMove(runes) then
      return runes
    end
  end
  return Board.Make(random)
end

-----------------------------
-- A swap played out
-----------------------------

--- The squares a rune of power clears when it goes off
--- @param board integer[]
--- @param square integer
--- @param value integer
--- @param school integer? For a prism, the school it takes
--- @return integer[]
local function reach(board, square, value, school)
  local kind = Kind(value)
  local row, column = Place(square)
  local list = {}
  if kind == ROW then
    for c = 0, SIZE - 1 do
      list[#list + 1] = Square(row, c)
    end
  elseif kind == COLUMN then
    for r = 0, SIZE - 1 do
      list[#list + 1] = Square(r, column)
    end
  elseif kind == NOVA then
    for r = row - NOVA_REACH, row + NOVA_REACH do
      for c = column - NOVA_REACH, column + NOVA_REACH do
        local there = Square(r, c)
        if there and abs(r - row) + abs(c - column) <= NOVA_REACH then
          list[#list + 1] = there
        end
      end
    end
  elseif kind == PRISM then
    for other = 1, SQUARES do
      if school == nil or (School(board[other]) == school and Kind(board[other]) ~= PRISM) then
        list[#list + 1] = other
      end
    end
  end
  return list
end

--- The school there is most of on the board, leaving out what is cleared already: the first of
--- those there are as many of
local function commonest(board, cleared)
  local count = {}
  for square = 1, SQUARES do
    local school = School(board[square])
    if school > 0 and Kind(board[square]) ~= PRISM and not cleared[square] then
      count[school] = (count[school] or 0) + 1
    end
  end
  local best
  for school = 1, SCHOOLS do
    if count[school] and (not best or count[school] > count[best]) then
      best = school
    end
  end
  return best or 1
end

--- @class RuneweaveBolt
--- @field square integer Where the rune of power was
--- @field kind integer What it was
--- @field school integer? The school a prism cleared, nil for the whole board

--- @class RuneweaveStep
--- @field before integer[] The board as the step began
--- @field cleared table<integer, string> The squares cleared, "line" or "power"
--- @field made { square: integer, value: integer }[] Runes of power made, where they were made
--- @field lines { cells: integer[], points: integer }[] The lines that were cleared and what each was worth
--- @field bolts RuneweaveBolt[] Runes of power set off, in the order they went
--- @field cascade integer 1 for what the swap itself did, 2 for what fell into place after, and so on
--- @field points integer
--- @field count integer How many runes were cleared
--- @field after integer[] The board once everything has fallen and the gaps are filled
--- @field from integer[] For each square of `after`, the row its rune fell from: less than 0 for one that came in from above

--- One step: what is cleared, made and set off, and then everything falling into place
--- @param board integer[] Changed to the board after it
--- @param groups RuneweaveGroup[]
--- @param starts { square: integer, value: integer, school: integer? }[] Runes of power set off before the lines are cleared: a prism swapped
--- @param cascade integer
--- @param level integer
--- @param random Random
--- @return RuneweaveStep
local function step(board, groups, starts, cascade, level, random)
  local before = copy(board)
  local cleared, made, protected = {}, {}, {}
  local lines, bolts, queue = {}, {}, {}
  local points = 0

  local function clear(square, why)
    if protected[square] or cleared[square] or board[square] == 0 then
      return
    end
    cleared[square] = why
    if Kind(board[square]) ~= PLAIN then
      queue[#queue + 1] = { square = square, value = board[square] }
    end
  end

  for _, start in ipairs(starts) do
    cleared[start.square] = "power"
    queue[#queue + 1] = start
  end
  for _, group in ipairs(groups) do
    if group.kind ~= PLAIN then
      protected[group.at] = true
      made[#made + 1] = { square = group.at, value = Value(group.school, group.kind) }
    end
  end
  for _, group in ipairs(groups) do
    local worth = LINE * (#group.cells - 2)
    points = points + worth
    lines[#lines + 1] = { cells = group.cells, points = worth * cascade * level }
    for _, square in ipairs(group.cells) do
      if protected[square] then
        -- The rune made here takes the place of what was there, which goes off if it was one of power
        if Kind(board[square]) ~= PLAIN then
          queue[#queue + 1] = { square = square, value = board[square] }
        end
      else
        clear(square, "line")
      end
    end
  end
  -- The runes of power go off one after the other, each setting off any it clears
  local next = 1
  while next <= #queue do
    local power = queue[next]
    next = next + 1
    local school = power.school
    if Kind(power.value) == PRISM and school == nil and not power.all then
      school = commonest(board, cleared)
    end
    bolts[#bolts + 1] = { square = power.square, kind = Kind(power.value), school = school }
    for _, square in ipairs(reach(board, power.square, power.value, school)) do
      clear(square, "power")
    end
  end

  local count = 0
  for square, why in pairs(cleared) do
    count = count + 1
    if why == "power" then
      points = points + POWER
    end
    board[square] = 0
  end
  for _, rune in ipairs(made) do
    board[rune.square] = rune.value
  end

  -- Everything falls, column by column from the bottom, and the gaps at the top are filled
  local from = {}
  for column = 0, SIZE - 1 do
    local to = SIZE - 1
    for row = SIZE - 1, 0, -1 do
      local square = Square(row, column)
      local value = board[square]
      if value ~= 0 then
        local target = Square(to, column)
        board[square] = 0
        board[target] = value
        from[target] = row
        to = to - 1
      end
    end
    local empty = to + 1
    for row = to, 0, -1 do
      local square = Square(row, column)
      board[square] = random:Roll(SCHOOLS)
      from[square] = row - empty
    end
  end

  return {
    before = before,
    cleared = cleared,
    made = made,
    lines = lines,
    bolts = bolts,
    cascade = cascade,
    points = points * cascade * level,
    count = count,
    after = copy(board),
    from = from,
  }
end

--- @class RuneweavePlay
--- @field a integer
--- @field b integer
--- @field start integer[] The board before the swap
--- @field steps RuneweaveStep[]
--- @field points integer
--- @field count integer Runes cleared in all
--- @field shuffled integer[]? The board shuffled after it, there being no swap left that did anything

--- Plays a swap out on a board, to the end of the last cascade
--- @param board integer[] Changed to the board after it
--- @param a integer
--- @param b integer
--- @param level integer What the points are multiplied by
--- @param random Random
--- @return RuneweavePlay
function Board.Play(board, a, b, level, random)
  local play = { a = a, b = b, start = copy(board), steps = {}, points = 0, count = 0 }
  local va, vb = board[a], board[b]
  board[a], board[b] = vb, va
  local starts = {}
  if Kind(va) == PRISM or Kind(vb) == PRISM then
    if Kind(va) == PRISM and Kind(vb) == PRISM then
      starts[1] = { square = a, value = va, all = true }
      starts[2] = { square = b, value = vb, all = true }
    else
      -- The prism, where it now is, clears the school it was swapped with
      local prism, other = Kind(va) == PRISM and b or a, Kind(va) == PRISM and vb or va
      starts[1] = { square = prism, value = Value(0, PRISM), school = School(other) }
    end
  end
  local cascade = 1
  local groups = Board.Groups(board, { b, a })
  while #groups > 0 or #starts > 0 do
    local done = step(board, groups, starts, cascade, level, random)
    play.steps[#play.steps + 1] = done
    play.points = play.points + done.points
    play.count = play.count + done.count
    starts = {}
    cascade = cascade + 1
    groups = Board.Groups(board)
  end
  if not Board.CanMove(board) then
    local shuffled = Board.Shuffle(board, random)
    for square = 1, SQUARES do
      board[square] = shuffled[square]
    end
    play.shuffled = copy(board)
  end
  return play
end
