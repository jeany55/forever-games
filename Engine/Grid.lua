--------------------------
--  Grid
--------------------------
-- Boards of squares in rows and columns, for the rules of any game played on one. The squares
-- are numbered the way GUI/Board.lua draws them: row by row from the bottom left, from 0, so
-- that on a board eight wide 0 is a1, 7 is h1 and 8 is a2. What a square is called is the letter
-- of its column and the number of its row, "a1" to "h8" on such a board.
--
-- A step is how far across and how far up it goes, { 1, 0 } one to the right. Everything that is
-- worked out from a square and a step is worked out once and kept, so that the rules can ask
-- about it as often as they like: the squares a line runs through, the ones around a square, the
-- runs of four in a row there are. Each board of a size is made once, Grid.New hands back the
-- same one every time.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class Grid
--- @field columns number
--- @field rows number
--- @field squares number How many there are: the last is one fewer, they start from 0
--- @field rays table<number, table<number, number[]>> Lines out of each square, by square and step
--- @field near table<table, table<number, number[]>> Squares around each square, by the steps asked about and the square
--- @field rayLists table<table, table<number, number[][]>> Lines out of each square in each of a list of steps
--- @field windows table<string, number[][]> Runs of squares, by length and the steps asked about
local Grid = {}
Grid.__index = Grid
private.Grid = Grid

-- The ways a rook goes: right, left, up, down
Grid.STRAIGHT = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
-- The ways a bishop goes, the two up the board first: up right, up left, down right, down left
Grid.DIAGONAL = { { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }
-- The ways a queen goes, and a king a square of: the straight ones and then the diagonal ones
Grid.AROUND = { Grid.STRAIGHT[1], Grid.STRAIGHT[2], Grid.STRAIGHT[3], Grid.STRAIGHT[4], Grid.DIAGONAL[1], Grid.DIAGONAL[2], Grid.DIAGONAL[3], Grid.DIAGONAL[4] }
-- Where a knight jumps
Grid.KNIGHT = { { 1, 2 }, { 2, 1 }, { 2, -1 }, { 1, -2 }, { -1, -2 }, { -2, -1 }, { -2, 1 }, { -1, 2 } }
-- The ways a line of squares can run, each once: the other way along it is the same line
Grid.LINES = { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 1, -1 } }

-- Columns are called by a letter, so only a board no wider than there are letters has names
local MOST_NAMED = 26
-- Steps go no further than this across or up, which is what lets a pair of them be one number
local FARTHEST = 31

--- @type table<number, Grid>
local made = {}

--- The board of a size
--- @param columns number
--- @param rows number? As many as there are columns if left out
--- @return Grid
function Grid.New(columns, rows)
  rows = rows or columns
  local key = columns * 10000 + rows
  local grid = made[key]
  if not grid then
    grid = setmetatable({ columns = columns, rows = rows, squares = columns * rows, rays = {}, near = {}, rayLists = {}, windows = {} }, Grid)
    made[key] = grid
  end
  return grid
end

--- @param across number
--- @param up number
--- @return number
local function stepKey(across, up)
  assert(math.abs(across) <= FARTHEST and math.abs(up) <= FARTHEST, "A step goes no further than 31 squares")
  return (across + FARTHEST) * (2 * FARTHEST + 1) + up + FARTHEST
end

-----------------------------
-- Squares
-----------------------------

--- Whether a column and row are on the board, both counted from 0
--- @param column number
--- @param row number
--- @return boolean
function Grid:Inside(column, row)
  return column >= 0 and column < self.columns and row >= 0 and row < self.rows
end

--- The square at a column and row, both counted from 0
--- @param column number
--- @param row number
--- @return number? nil when that is off the board
function Grid:Square(column, row)
  if column < 0 or column >= self.columns or row < 0 or row >= self.rows then
    return nil
  end
  return row * self.columns + column
end

--- Where a square is
--- @param square number
--- @return number column, number row Both counted from 0
function Grid:Coordinates(square)
  return square % self.columns, math.floor(square / self.columns)
end

--- The square a step away from another
--- @param square number
--- @param across number
--- @param up number
--- @return number? nil when that is off the board
function Grid:Step(square, across, up)
  local columns = self.columns
  local column, row = square % columns + across, math.floor(square / columns) + up
  if column < 0 or column >= columns or row < 0 or row >= self.rows then
    return nil
  end
  return row * columns + column
end

--- How many moves a king would take from one square to the other
--- @param from number
--- @param to number
--- @return number
function Grid:Distance(from, to)
  local columns = self.columns
  return math.max(math.abs(from % columns - to % columns), math.abs(math.floor(from / columns) - math.floor(to / columns)))
end

--- What a square is called: "a1" for the one in the bottom left. Only a board with no more
--- columns than there are letters has names
--- @param square number
--- @return string
function Grid:Name(square)
  assert(self.columns <= MOST_NAMED, "Only a board up to 26 columns wide has names")
  return string.char(97 + square % self.columns) .. (math.floor(square / self.columns) + 1)
end

--- The square a name is of, written exactly as Grid:Name writes it
--- @param name string
--- @return number? nil if there is no such square on the board
function Grid:Parse(name)
  local letter, number = name:match("^([a-z])([1-9]%d?)$")
  if not letter then
    return nil
  end
  return self:Square(letter:byte() - 97, tonumber(number) - 1)
end

-----------------------------
-- Lines
-----------------------------

--- The squares a line runs through from a square, nearest first, as far as the edge. The square
--- itself isn't one of them. The list is the board's own: it mustn't be changed
--- @param square number
--- @param across number
--- @param up number
--- @return number[]
function Grid:Ray(square, across, up)
  local key = stepKey(across, up)
  local fromSquare = self.rays[square]
  if not fromSquare then
    fromSquare = {}
    self.rays[square] = fromSquare
  end
  local ray = fromSquare[key]
  if not ray then
    ray = {}
    local to = self:Step(square, across, up)
    while to do
      ray[#ray + 1] = to
      to = self:Step(to, across, up)
    end
    fromSquare[key] = ray
  end
  return ray
end

--- The lines from a square in each of a list of steps (Grid:Ray), in the order of the steps.
--- The lists are the board's own: they mustn't be changed
--- @param square number
--- @param steps number[][]
--- @return number[][]
function Grid:Rays(square, steps)
  local bySquare = self.rayLists[steps]
  if not bySquare then
    bySquare = {}
    self.rayLists[steps] = bySquare
  end
  local rays = bySquare[square]
  if not rays then
    rays = {}
    for index, step in ipairs(steps) do
      rays[index] = self:Ray(square, step[1], step[2])
    end
    bySquare[square] = rays
  end
  return rays
end

--- The squares a single step away from a square, in each of a list of steps there is room for,
--- in the order of the steps: the eight around it (Grid.AROUND), where a knight jumps
--- (Grid.KNIGHT). The list is the board's own: it mustn't be changed
--- @param square number
--- @param steps number[][]
--- @return number[]
function Grid:Around(square, steps)
  local bySquare = self.near[steps]
  if not bySquare then
    bySquare = {}
    self.near[steps] = bySquare
  end
  local around = bySquare[square]
  if not around then
    around = {}
    for _, step in ipairs(steps) do
      around[#around + 1] = self:Step(square, step[1], step[2])
    end
    bySquare[square] = around
  end
  return around
end

--- The longest line of squares through a square that all pass a test, along each of a list of
--- ways a line can run (Grid.LINES): four in a row, five in a row
--- @param square number It is in the line whatever the test says of it
--- @param steps number[][] Each is also gone along backwards
--- @param test fun(square: number): boolean
--- @param least number? The shortest that is any use: a line shorter than this is nil
--- @return number[]? line From the square out, the way the step goes before the way back
function Grid:Line(square, steps, test, least)
  local best = nil
  for _, step in ipairs(steps) do
    local line = { square }
    for _, sign in ipairs({ 1, -1 }) do
      for _, other in ipairs(self:Ray(square, step[1] * sign, step[2] * sign)) do
        if not test(other) then
          break
        end
        line[#line + 1] = other
      end
    end
    if not best or #line > #best then
      best = line
    end
  end
  if best and #best < (least or 1) then
    return nil
  end
  return best
end

--- Every run of so many squares in a row on the board, along each of a list of ways a line can
--- run (Grid.LINES): every four a disc could make a line of. The list is the board's own: it
--- mustn't be changed
--- @param length number
--- @param steps number[][]
--- @return number[][]
function Grid:Windows(length, steps)
  local key = length .. tostring(steps)
  local windows = self.windows[key]
  if windows then
    return windows
  end
  windows = {}
  for row = 0, self.rows - 1 do
    for column = 0, self.columns - 1 do
      for _, step in ipairs(steps) do
        if self:Inside(column + step[1] * (length - 1), row + step[2] * (length - 1)) then
          local window = {}
          for index = 0, length - 1 do
            window[index + 1] = (row + step[2] * index) * self.columns + column + step[1] * index
          end
          windows[#windows + 1] = window
        end
      end
    end
  end
  self.windows[key] = windows
  return windows
end

-----------------------------
-- Spreading
-----------------------------

--- Goes out from where it begins a step at a time, nearest first, the way water would: the
--- squares opened around an empty one in Minesweeper, every hole a marble can hop to. Works for
--- anything that can be numbered, not only the squares of a Grid
--- @param seeds number[] Where it begins
--- @param visit fun(square: number, depth: number, from: number?): number[]? Called once for every square it gets to, in the order it does, with how many steps out it is and the square it came from (nil for a seed). Hands back where it may go on to from there, if anywhere
--- @param depth number? How many steps out the seeds are, 0 if left out
--- @return number[] reached Every square it got to, in that order
function Grid.Spread(seeds, visit, depth)
  local reached, depths, from, seen = {}, {}, {}, {}
  for _, square in ipairs(seeds) do
    if not seen[square] then
      local index = #reached + 1
      seen[square] = true
      reached[index], depths[index] = square, depth or 0
    end
  end
  local head = 1
  while reached[head] do
    local square, steps = reached[head], depths[head]
    local onward = visit(square, steps, from[head])
    head = head + 1
    for _, other in ipairs(onward or {}) do
      if not seen[other] then
        local index = #reached + 1
        seen[other] = true
        reached[index], depths[index], from[index] = other, steps + 1, square
      end
    end
  end
  return reached
end
