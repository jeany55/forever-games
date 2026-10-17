--------------------------
--  Blockfall
--------------------------
-- Shown to the players as Tetris (L["game_blockfall"]). Its id, which matches are kept under,
-- is "blockfall", so that what it is called can change without losing anyone's games.
--
-- Falling blocks, for one player. Pieces of four squares each, the seven there are (I, O, T, S,
-- Z, J and L), fall one at a time into a well ten squares wide and twenty deep. The player moves
-- them from side to side and turns them as they fall, and a row that is filled from wall to wall
-- is cleared, everything above it coming down. The game is over when the next piece has no room
-- to come in at the top.
--
-- It plays the way the games of the last twenty years do. A piece that is turned against a wall
-- or the stack tries a few places nearby before it gives up (KICKS, the "super rotation system"),
-- so that a T can be turned into a slot it couldn't have been dropped into: a T-spin, which
-- scores far more than the same rows cleared any other way. The pieces come out of a bag of all
-- seven, shuffled, and the next bag once it is empty, so there is never long to wait for the one
-- that is needed. The next five are shown, and one piece can be put aside to swap in later, once
-- a piece. A piece that lands doesn't stop at once: it can still be moved and turned for half a
-- second, and every move starts that half second again, fifteen times at most.
--
-- What a clear scores (CLEAR_POINTS and the rest) is multiplied by the level, which goes up every
-- ten lines and makes the pieces fall faster (fallSeconds). Four lines at once, or a T-spin that
-- clears any, is a hard clear, and two of those with only easy ones between (none clear nothing)
-- are back to back, worth half as much again. Every clear right after another adds to a combo,
-- and a clear that leaves the well empty is a perfect clear, with a bonus of its own. Dropping a
-- piece faster is worth a point a row, all the way at once two.
--
-- It is played three ways (MODES): a marathon of 150 lines, up through the levels; a sprint, 40
-- lines as quickly as they can be cleared; and two minutes for as many points as there are in
-- them, the day's challenge for everyone in the guild.
--
-- Like Warcraftstein, the falling is the view's business and happens many times a second, too
-- often to be written down. What the engine is told is where each piece came to rest, and the
-- rest follows from that: the rows it cleared, what that scored, the next piece. So a game that
-- is left and loaded again has the well as it was, and only the piece that was falling starts
-- again from the top. The rules check that a piece fits where it is said to have landed and lies
-- on something, not that it could have got there. Between guildies the game takes the player's
-- word for that, as the day's board does.
--
-- The bag is shuffled from a chance of the game's own, kept in the state, which is dealt with the
-- game and never stirred by the moves: a race or the day's challenge deals both players the same
-- pieces in the same order, however differently they play them.
--
-- The squares of the well are numbered along the rows from 1 in the top left corner. It has two
-- rows above the twenty that are seen, where pieces come in (HIDDEN). The state keeps what lies
-- on every square: 0 for nothing, else the kind of piece it was part of (KINDS), for its colour.
-- Where a piece is is the square of the top left corner of the box it turns in (SHAPES), which
-- can be outside the well while the piece itself is in it.
--
-- The moves:
--   "<turns>.<column>.<row>" and what is to be said about it: the piece came to rest turned
--       that many times clockwise (0 to 3) from the way it comes in, its box at that column and
--       row, "1.4.19". After that "s" and how many rows it was pushed down, "d" and how many it
--       was dropped all the way, "t" if the last thing done to it was a turn and "k" if that turn
--       took the farthest of its kicks: "0.-1.21d18", "2.5.20s3tk"
--   "h" the piece is put aside, and the one that was is taken out, or the next if none was
--   "e" the time is up, in a game against it

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L

local WIDTH, HEIGHT, HIDDEN = 10, 22, 2
local I, O, T, S, Z, J, LL = 1, 2, 3, 4, 5, 6, 7
local KINDS = { I, O, T, S, Z, J, LL }
-- Each piece as it comes in: how many squares the box it turns in is each way, and the squares
-- of it in that box, counted from 0 across and down
local SHAPES = {
  [I] = { size = 4, { 0, 1 }, { 1, 1 }, { 2, 1 }, { 3, 1 } },
  [O] = { size = 4, still = true, { 1, 0 }, { 2, 0 }, { 1, 1 }, { 2, 1 } },
  [T] = { size = 3, { 1, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 } },
  [S] = { size = 3, { 1, 0 }, { 2, 0 }, { 0, 1 }, { 1, 1 } },
  [Z] = { size = 3, { 0, 0 }, { 1, 0 }, { 1, 1 }, { 2, 1 } },
  [J] = { size = 3, { 0, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 } },
  [LL] = { size = 3, { 2, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 } },
}
-- Where a piece comes in: its box's top left corner
local SPAWN_COLUMN, SPAWN_ROW = 4, 1
-- Where a piece that is turned tries to go, in order, by the turn it was and the turn it is
-- going to: across, and down. The I has its own
local KICKS = {
  ["01"] = { { 0, 0 }, { -1, 0 }, { -1, -1 }, { 0, 2 }, { -1, 2 } },
  ["10"] = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, -2 }, { 1, -2 } },
  ["12"] = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, -2 }, { 1, -2 } },
  ["21"] = { { 0, 0 }, { -1, 0 }, { -1, -1 }, { 0, 2 }, { -1, 2 } },
  ["23"] = { { 0, 0 }, { 1, 0 }, { 1, -1 }, { 0, 2 }, { 1, 2 } },
  ["32"] = { { 0, 0 }, { -1, 0 }, { -1, 1 }, { 0, -2 }, { -1, -2 } },
  ["30"] = { { 0, 0 }, { -1, 0 }, { -1, 1 }, { 0, -2 }, { -1, -2 } },
  ["03"] = { { 0, 0 }, { 1, 0 }, { 1, -1 }, { 0, 2 }, { 1, 2 } },
}
local I_KICKS = {
  ["01"] = { { 0, 0 }, { -2, 0 }, { 1, 0 }, { -2, 1 }, { 1, -2 } },
  ["10"] = { { 0, 0 }, { 2, 0 }, { -1, 0 }, { 2, -1 }, { -1, 2 } },
  ["12"] = { { 0, 0 }, { -1, 0 }, { 2, 0 }, { -1, -2 }, { 2, 1 } },
  ["21"] = { { 0, 0 }, { 1, 0 }, { -2, 0 }, { 1, 2 }, { -2, -1 } },
  ["23"] = { { 0, 0 }, { 2, 0 }, { -1, 0 }, { 2, -1 }, { -1, 2 } },
  ["32"] = { { 0, 0 }, { -2, 0 }, { 1, 0 }, { -2, 1 }, { 1, -2 } },
  ["30"] = { { 0, 0 }, { 1, 0 }, { -2, 0 }, { 1, 2 }, { -2, -1 } },
  ["03"] = { { 0, 0 }, { -1, 0 }, { 2, 0 }, { -1, -2 }, { 2, 1 } },
}
-- The corners of a T's box, across and down from its middle, and which two are in front of it
-- by how it is turned: the ones either side of its point
local CORNERS = { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }
local FRONT = { [0] = { 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 1 } }
-- How many pieces are shown coming, and how many are kept in the queue at least to show them
local PREVIEW = 5
-- What a clear is worth at level 1, by how many rows it cleared: plainly, by a T-spin, by a
-- small T-spin, and on top of that for leaving the well empty
local CLEAR_POINTS = { [0] = 0, 100, 300, 500, 800 }
local SPIN_POINTS = { [0] = 400, 800, 1200, 1600 }
local MINI_POINTS = { [0] = 100, 200, 400 }
local PERFECT_POINTS = { 800, 1200, 1800, 2000 }
-- A perfect clear of four lines back to back, and what back to back multiplies a clear by
local PERFECT_CHAIN, CHAIN = 3200, 1.5
local COMBO_POINTS = 50
-- Rows a level, the highest level there is, and what each way of playing is played for
local LEVEL_LINES, TOP_LEVEL = 10, 20
local MARATHON_LINES, SPRINT_LINES, ULTRA_SECONDS = 150, 40, 120
local MODES = { "marathon", "sprint", "ultra" }
local LEVELS = { 1, 5, 10, 15 }
-- The farthest a piece can have fallen, or have been pushed: the well and then some
local MOST_ROWS = HEIGHT
local HOLD, TIME_UP = "h", "e"

--- @class BlockfallState
--- @field mode string One of MODES
--- @field start number The level it began at
--- @field level number
--- @field cells number[] What lies on every square of the well
--- @field current number The kind of piece falling now
--- @field queue number[] The pieces that come after it, in order
--- @field hold number The piece that was put aside, 0 for none
--- @field held boolean The piece falling now was swapped in, and can't be put aside again
--- @field chance number Where the shuffling of the bag has got to, see Random
--- @field lines number Cleared so far
--- @field score number
--- @field pieces number How many have come to rest
--- @field combo number Clears in a row, less one: -1 after a piece that cleared nothing
--- @field chain boolean The last clear was a hard one: four rows, or a T-spin
--- @field quads number Clears of four rows
--- @field spins number T-spins that cleared rows
--- @field over boolean
--- @field won boolean It ended because it was played through: the lines are cleared, the time is up
--- @field blocked boolean? It ended because a piece had no room

--- @class BlockfallPiece
--- @field kind number
--- @field turn number How many times it was turned clockwise from how it came in, 0 to 3
--- @field column number Where the top left corner of its box is
--- @field row number

--- @class BlockfallEvent: MatchEvent
--- @field action "lock"|"hold"|"time"
--- @field kind number? The piece that came to rest
--- @field placed number[]? The squares it came to rest on
--- @field rows number[]? The rows it cleared, from the top
--- @field spin "full"|"mini"|nil It was a T-spin
--- @field chain boolean? The clear was back to back
--- @field combo number? How many clears in a row this one makes, past the first
--- @field perfect boolean? It left the well empty
--- @field gained number What it scored, dropping included
--- @field level number? The level it took the game up to
--- @field over boolean?
--- @field won boolean?

-----------------------------
-- Rules
-----------------------------

-- Every way every piece can be turned, by kind and then by turn from 0: its squares in its box
local TURNS = {}
for kind, shape in pairs(SHAPES) do
  local turns, squares = {}, {}
  for index, square in ipairs(shape) do
    squares[index] = { square[1], square[2] }
  end
  for turn = 0, 3 do
    turns[turn] = squares
    local turned = {}
    for index, square in ipairs(squares) do
      -- A quarter turn clockwise in a box this size, unless the piece looks the same every way
      turned[index] = shape.still and square or { shape.size - 1 - square[2], square[1] }
    end
    squares = turned
  end
  TURNS[kind] = turns
end

--- The squares of a piece, in its box
--- @param kind number
--- @param turn number
--- @return number[][]
local function squaresOf(kind, turn)
  return TURNS[kind][turn]
end

--- Whether a piece has room somewhere: every square of it in the well, and nothing on any
--- @param cells number[]
--- @param kind number
--- @param turn number
--- @param column number
--- @param row number
--- @return boolean
local function fits(cells, kind, turn, column, row)
  for _, square in ipairs(TURNS[kind][turn]) do
    local x, y = column + square[1], row + square[2]
    if x < 1 or x > WIDTH or y < 1 or y > HEIGHT or cells[(y - 1) * WIDTH + x] ~= 0 then
      return false
    end
  end
  return true
end

--- How far down a piece would go if it were let fall: the row it would come to rest on
--- @param cells number[]
--- @param piece BlockfallPiece
--- @return number
local function landing(cells, piece)
  local row = piece.row
  while fits(cells, piece.kind, piece.turn, piece.column, row + 1) do
    row = row + 1
  end
  return row
end

--- Where a piece turned a quarter one way or the other would go, trying every kick in turn
--- @param cells number[]
--- @param piece BlockfallPiece
--- @param way number 1 clockwise, -1 the other way
--- @return number? turn nil if it can't be turned at all
--- @return number column
--- @return number row
--- @return boolean far It took the last of the kicks, which counts a small T-spin as a full one
local function turned(cells, piece, way)
  local kind, from = piece.kind, piece.turn
  if SHAPES[kind].still then
    return nil, piece.column, piece.row, false
  end
  local to = (from + way) % 4
  local kicks = (kind == I and I_KICKS or KICKS)[from .. to]
  for index, kick in ipairs(kicks) do
    local column, row = piece.column + kick[1], piece.row + kick[2]
    if fits(cells, kind, to, column, row) then
      return to, column, row, index == #kicks
    end
  end
  return nil, piece.column, piece.row, false
end

--- Whether a square counts as filled for a T-spin: the walls and the floor do
--- @param cells number[]
--- @param x number
--- @param y number
--- @return boolean
local function solid(cells, x, y)
  return x < 1 or x > WIDTH or y > HEIGHT or (y >= 1 and cells[(y - 1) * WIDTH + x] ~= 0)
end

--- Whether a T that came to rest was spun in: it was turned last, and three of the four corners
--- around its middle are filled. A full one has both corners in front of it filled, or took the
--- farthest kick to get there. The T's own squares are never in its corners
--- @param cells number[]
--- @param piece BlockfallPiece
--- @param twisted boolean The last thing done to it was a turn
--- @param far boolean That turn took the farthest kick
--- @return "full"|"mini"|nil
local function spinOf(cells, piece, twisted, far)
  if piece.kind ~= T or not twisted then
    return nil
  end
  local middleX, middleY = piece.column + 1, piece.row + 1
  local filled, front = 0, 0
  for index, corner in ipairs(CORNERS) do
    if solid(cells, middleX + corner[1], middleY + corner[2]) then
      filled = filled + 1
      if index == FRONT[piece.turn][1] or index == FRONT[piece.turn][2] then
        front = front + 1
      end
    end
  end
  if filled < 3 then
    return nil
  end
  return (front == 2 or far) and "full" or "mini"
end

--- How long a piece takes to fall a row at a level, in seconds: the curve the games settled on,
--- a second at level 1 and too quick to see by level 15
--- @param level number
--- @return number
local function fallSeconds(level)
  return (0.8 - (level - 1) * 0.007) ^ (level - 1)
end

--- Keeps enough pieces coming to show the next few, shuffling a new bag of all seven when it runs low
--- @param state BlockfallState
local function fill(state)
  while #state.queue < PREVIEW + 1 do
    -- The game's own chance, never the match's: the moves don't stir it
    local chance = setmetatable({ value = state.chance }, private.Random)
    local bag = chance:Shuffle({ unpack(KINDS) })
    state.chance = chance.value
    for _, kind in ipairs(bag) do
      state.queue[#state.queue + 1] = kind
    end
  end
end

--- Takes the next piece off the queue
--- @param state BlockfallState
--- @return number
local function nextPiece(state)
  fill(state)
  local kind = table.remove(state.queue, 1)
  fill(state)
  return kind
end

--- Where a piece comes in, at the top of the well
--- @param kind number
--- @return BlockfallPiece
local function spawn(kind)
  return { kind = kind, turn = 0, column = SPAWN_COLUMN, row = SPAWN_ROW }
end

--- The piece falling now, as it comes in
--- @param state BlockfallState
--- @return BlockfallPiece
local function arriving(state)
  return spawn(state.current)
end

--- Whether the piece falling now has room to come in: if not, the game is over
--- @param state BlockfallState
--- @return boolean
local function hasRoom(state)
  local piece = arriving(state)
  return fits(state.cells, piece.kind, piece.turn, piece.column, piece.row)
end

--- @param seats number
--- @param random Random
--- @param rules table<string, any>?
--- @return BlockfallState
local function newState(_, random, rules)
  local mode = rules and rules.mode or MODES[1]
  local start = mode == "sprint" and 1 or (rules and rules.level or 1)
  --- @type BlockfallState
  local state = {
    mode = mode, start = start, level = start, cells = {}, queue = {}, hold = 0, held = false,
    chance = private.Random.New(random:Roll(2147483646)).value,
    lines = 0, score = 0, pieces = 0, combo = -1, chain = false, quads = 0, spins = 0, over = false, won = false,
  }
  for square = 1, WIDTH * HEIGHT do
    state.cells[square] = 0
  end
  state.current = nextPiece(state)
  return state
end

--- Reads where a piece came to rest
--- @param move string
--- @return { turn: number, column: number, row: number, soft: number, hard: number, twisted: boolean, far: boolean }?
local function parse(move)
  local turn, column, row, rest = move:match("^([0-3])%.(%-?%d+)%.(%d+)(.*)$")
  if not turn then
    return nil
  end
  local placed = { turn = tonumber(turn), column = tonumber(column), row = tonumber(row), soft = 0, hard = 0, twisted = false, far = false }
  local seen = {}
  local position = 1
  while position <= #rest do
    local flag, count, after = rest:match("^(%a)(%d*)()", position)
    if not flag or seen[flag] then
      return nil
    end
    seen[flag] = true
    if flag == "s" or flag == "d" then
      local rows = tonumber(count)
      if not rows or rows > MOST_ROWS then
        return nil
      end
      placed[flag == "s" and "soft" or "hard"] = rows
    elseif (flag == "t" or flag == "k") and count == "" then
      placed[flag == "t" and "twisted" or "far"] = true
    else
      return nil
    end
    position = after
  end
  return placed
end

--- @param state BlockfallState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  if seat ~= 1 then
    return false, "not_your_turn"
  elseif state.over then
    return false, "invalid_move"
  end
  if move == HOLD or move == TIME_UP then
    local allowed = (move == HOLD and not state.held) or (move == TIME_UP and state.mode == "ultra")
    if not allowed then
      return false, "invalid_move"
    end
    return true
  end
  local placed = parse(move)
  if not placed then
    return false, "invalid_move"
  end
  local kind = state.current
  local rests = fits(state.cells, kind, placed.turn, placed.column, placed.row)
    and not fits(state.cells, kind, placed.turn, placed.column, placed.row + 1)
  if not rests then
    return false, "invalid_move"
  end
  return true
end

--- Every place the piece could be dropped straight down to as it comes in, turned every way it
--- can be, and putting it aside if that can still be done. Not the places it could only be got
--- into by sliding or turning it under something: enough to play a game with. A place an I, an
--- S or a Z fills the same squares of turned either of two ways is only listed once
--- @param state BlockfallState
--- @return string[]
local function moves(state)
  local list = {}
  if state.over then
    return list
  end
  local kind, filled = state.current, {}
  for turn = 0, SHAPES[kind].still and 0 or 3 do
    for column = -2, WIDTH do
      if fits(state.cells, kind, turn, column, SPAWN_ROW) then
        local row = landing(state.cells, { kind = kind, turn = turn, column = column, row = SPAWN_ROW })
        local squares = {}
        for index, square in ipairs(squaresOf(kind, turn)) do
          squares[index] = (row + square[2] - 1) * WIDTH + column + square[1]
        end
        table.sort(squares)
        local key = table.concat(squares, ",")
        if not filled[key] then
          filled[key] = true
          list[#list + 1] = turn .. "." .. column .. "." .. row
        end
      end
    end
  end
  if not state.held then
    list[#list + 1] = HOLD
  end
  if state.mode == "ultra" then
    list[#list + 1] = TIME_UP
  end
  return list
end

--- The rows that are full from wall to wall, from the top
--- @param cells number[]
--- @return number[]
local function fullRows(cells)
  local rows = {}
  for row = 1, HEIGHT do
    local full = true
    for column = 1, WIDTH do
      full = full and cells[(row - 1) * WIDTH + column] ~= 0
    end
    if full then
      rows[#rows + 1] = row
    end
  end
  return rows
end

--- Takes rows out of the well, everything above them coming down
--- @param cells number[]
--- @param rows number[] From the top
local function clear(cells, rows)
  local gone = {}
  for _, row in ipairs(rows) do
    gone[row] = true
  end
  -- From the bottom up, every row that stays is moved down past the ones that went below it
  local to = HEIGHT
  for from = HEIGHT, 1, -1 do
    if not gone[from] then
      for column = 1, WIDTH do
        cells[(to - 1) * WIDTH + column] = cells[(from - 1) * WIDTH + column]
      end
      to = to - 1
    end
  end
  for row = to, 1, -1 do
    for column = 1, WIDTH do
      cells[(row - 1) * WIDTH + column] = 0
    end
  end
end

--- Whether there is nothing at all in the well
--- @param cells number[]
--- @return boolean
local function empty(cells)
  for _, value in ipairs(cells) do
    if value ~= 0 then
      return false
    end
  end
  return true
end

--- What a clear scores, and what it does to the chain and the combo
--- @param state BlockfallState
--- @param event BlockfallEvent
--- @param lines number
--- @param spin "full"|"mini"|nil
--- @return number
local function scoreClear(state, event, lines, spin)
  local level = state.level
  local points = (spin == "full" and SPIN_POINTS or spin == "mini" and MINI_POINTS or CLEAR_POINTS)[lines] * level
  if lines == 0 then
    -- A spin that clears nothing scores, but doesn't make or break a chain
    state.combo = -1
    return points
  end
  local hard = lines == 4 or spin ~= nil
  if hard and state.chain then
    points = math.floor(points * CHAIN)
    event.chain = true
  end
  state.chain = hard
  state.combo = state.combo + 1
  if state.combo > 0 then
    points = points + COMBO_POINTS * state.combo * level
    event.combo = state.combo
  end
  return points
end

--- @param state BlockfallState
--- @param seat number
--- @param move string
--- @return BlockfallEvent
local function apply(state, _, move)
  if move == HOLD then
    local kind = state.current
    if state.hold == 0 then
      state.current = nextPiece(state)
    else
      state.current = state.hold
    end
    state.hold, state.held = kind, true
    if not hasRoom(state) then
      state.over, state.blocked = true, true
    end
    return { action = "hold", kind = kind, gained = 0, over = state.over or nil }
  elseif move == TIME_UP then
    state.over, state.won = true, true
    return { action = "time", gained = 0, over = true, won = true }
  end

  local placed = assert(parse(move))
  --- @type BlockfallPiece
  local piece = { kind = state.current, turn = placed.turn, column = placed.column, row = placed.row }
  local cells = state.cells
  --- @type BlockfallEvent
  local event = { action = "lock", kind = piece.kind, placed = {}, gained = 0 }
  local above = true
  for _, square in ipairs(squaresOf(piece.kind, piece.turn)) do
    local x, y = piece.column + square[1], piece.row + square[2]
    cells[(y - 1) * WIDTH + x] = piece.kind
    event.placed[#event.placed + 1] = (y - 1) * WIDTH + x
    above = above and y <= HIDDEN
  end
  state.pieces = state.pieces + 1

  local spin = spinOf(cells, piece, placed.twisted, placed.far)
  local rows = fullRows(cells)
  clear(cells, rows)
  event.rows, event.spin = rows, spin
  local gained = scoreClear(state, event, #rows, spin) + placed.soft + placed.hard * 2
  if #rows > 0 and empty(cells) then
    event.perfect = true
    gained = gained + (#rows == 4 and event.chain and PERFECT_CHAIN or PERFECT_POINTS[#rows]) * state.level
  end
  state.score = state.score + gained
  event.gained = gained
  state.lines = state.lines + #rows
  state.quads = state.quads + (#rows == 4 and 1 or 0)
  state.spins = state.spins + ((spin and #rows > 0) and 1 or 0)

  if state.mode ~= "sprint" then
    local level = math.min(TOP_LEVEL, state.start + math.floor(state.lines / LEVEL_LINES))
    if level ~= state.level then
      state.level, event.level = level, level
    end
  end

  local goal = (state.mode == "marathon" and MARATHON_LINES) or (state.mode == "sprint" and SPRINT_LINES) or nil
  state.held = false
  if goal and state.lines >= goal then
    state.over, state.won = true, true
  else
    state.current = nextPiece(state)
    -- A piece that came to rest wholly above the well, or a next one with no room, ends it
    if above or not hasRoom(state) then
      state.over, state.blocked = true, true
    end
  end
  event.over, event.won = state.over or nil, state.won or nil
  return event
end

--- @param state BlockfallState
--- @return { winner: number }?
local function result(state)
  if not state.over then
    return nil
  end
  return { winner = state.won and 1 or 0 }
end

--- A number of points as it is easiest to read: 12,345
--- @param value number
--- @return string
local function points(value)
  return BreakUpLargeNumbers and BreakUpLargeNumbers(value) or tostring(value)
end

--- What a game's best is kept under: its way of playing, and the level it began at for the ones
--- played for points
--- @param state BlockfallState|table<string, any> Or the rules it is played by
--- @return string
local function recordKey(state)
  local start = state.start or state.level or 1
  return state.mode == "sprint" and "sprint" or (state.mode .. start)
end

--- @param state BlockfallState
--- @return string
local function progress(state)
  if state.mode == "sprint" then
    return L["blockfall_progress_sprint"]:format(math.min(state.lines, SPRINT_LINES), SPRINT_LINES)
  elseif state.mode == "ultra" then
    return L["blockfall_progress_ultra"]:format(points(state.score), state.lines)
  end
  return L["blockfall_progress_marathon"]:format(points(state.score), state.level, state.lines)
end

-----------------------------
-- View
-----------------------------
-- The well in the middle, with the piece that is falling, and under it, faintly, where it would
-- land. To its left the piece put aside and what the game keeps count of, to its right the
-- pieces to come and the best there was. A thin gauge along the well's right side fills up
-- towards what the game is played for: the next level, the fortieth line, the end of the time.
-- In a race it also shows how far the rival had got by the same moment, from the ghost of their
-- run.
--
-- The keys are taken wherever the cursor is while the game is on, the way Freedoom's are: the
-- arrows (or A and D) move the piece, Up (or X, or W) turns it clockwise and Z (or Q, or Ctrl)
-- the other way, Down (or S) pushes it down and Space drops it all the way. C (or Shift) puts it
-- aside. A move key that is held starts repeating after a moment (SHIFT_DELAY), quickly. P or
-- Escape pauses: the well is covered so that nobody thinks about their next piece for free, and
-- the clock stops (Paused). The game is paused, too, when the window is closed or another game is
-- looked at, and when a fight begins, since the keys go back to the character then. It begins,
-- and begins again after a pause, with a count so the first piece isn't lost while the hand
-- finds the keys. While it is paused or over the keys go on to do whatever they usually do.
--
-- A turn or a hold pressed in the moment between one piece and the next is kept and done to the
-- next as it comes in, so a quick hand is never ignored.

local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\Blockfall\\"
local FLAT = "Interface\\Buttons\\WHITE8X8"
-- The colours of the pieces, the ones every game of falling blocks has come to give them, set
-- apart in hue and lightness so no two are taken for each other (cyan and blue most of all)
local COLORS = {
  [I] = { 0.15, 0.95, 0.95 },
  [O] = { 1, 0.92, 0.15 },
  [T] = { 0.82, 0.32, 1 },
  [S] = { 0.35, 0.82, 0.18 },
  [Z] = { 0.92, 0.12, 0.25 },
  [J] = { 0.18, 0.36, 1 },
  [LL] = { 1, 0.56, 0.1 },
}
-- What the stack turns as the game is lost
local DEAD = { 0.42, 0.43, 0.48 }
local WELL = { 0.045, 0.05, 0.075, 0.97 }
local WELL_EDGE = { 0.55, 0.62, 0.85, 0.35 }
local LINE_ALPHA = 0.045
local GHOST_ALPHA, GHOST_FILL = 0.55, 0.12
local PANEL = { 0.06, 0.065, 0.09, 0.85 }
local INK_DIM = { 0.62, 0.66, 0.78 }

-- The room things are laid out in, in squares of the well: the well itself and the two rows
-- above it pieces come in through, the boxes either side and the gaps between
local SIDE_BOX, GAP, TOP_ROOM = 4.8, 0.55, 2.2
local MARGIN, HINT_HEIGHT, STAT_HEIGHT, STAT_GAP = 8, 14, 38, 5
local GAUGE_WIDTH = 4
-- Squares of a piece in the box it is shown in, as a part of the well's squares: the first to
-- come and the one put aside, then the rest
local PREVIEW_BIG, PREVIEW_SMALL = 0.82, 0.6
-- The picture a square is drawn with, by how big it is on screen
local ART_SMALL, ART_LARGE, ART_FROM = "32", "64", 26

-- Seconds a move key is held before the piece moves on by itself, and between two of those moves
local SHIFT_DELAY, SHIFT_EVERY = 0.16, 0.035
-- How many times faster than falling the piece goes while it is pushed down
local SOFT_TIMES = 20
-- Seconds a piece lies on something before it stays there, and how often a move or a turn
-- gives it that long again
local LOCK_SECONDS, LOCK_RESETS = 0.5, 15
-- Seconds between a piece coming to rest and the next coming in, and when rows are cleared
local ENTRY_SECONDS, CLEAR_SECONDS, QUAD_CLEAR_SECONDS = 0.1, 0.36, 0.48
-- How long the rows that are cleared light up for, before what is left above them comes down
local FLASH_SECONDS, COLLAPSE_SECONDS = 0.22, 0.12
-- The count before the game starts, and before it goes on after a pause, a beat each
local READY_BEATS, RESUME_BEATS, BEAT = { "blockfall_ready", "blockfall_go" }, { "3", "2", "1" }, 0.5
-- Seconds a callout stays up, and how long the stack takes to grey once the game is lost
local CALLOUT_SECONDS, TOP_OUT_SECONDS, OVER_AFTER = 1.5, 0.7, 0.25
-- Seconds of the hard drop's streak, and how far the well is knocked down by a drop
local STREAK_SECONDS, BUMP, BUMP_SECONDS = 0.22, 3, 0.14
-- Seconds between two samples of where the player is for the ghost of their run
local SAMPLE_EVERY = 0.25

local KEYS = {
  LEFT = "left", A = "left", RIGHT = "right", D = "right",
  DOWN = "soft", S = "soft",
  UP = "turn", X = "turn", W = "turn",
  Z = "back", Q = "back", LCTRL = "back", RCTRL = "back",
  SPACE = "drop",
  C = "hold", LSHIFT = "hold", RSHIFT = "hold",
  P = "pause", ESCAPE = "pause",
}
local SHIFTS = { left = -1, right = 1 }

local SOUNDS = {
  move = "blockfallMove", turn = "blockfallTurn", land = "blockfallLand", drop = "blockfallDrop",
  hold = "blockfallHold", clear = "blockfallClear", quad = "blockfallQuad", spin = "blockfallSpin",
  level = "blockfallLevel", over = "blockfallOver", beat = "blockfallBeat", go = "blockfallGo",
  won = "UI_EPICLOOT_TOAST", wonElse = "IG_QUEST_LIST_COMPLETE", pause = "IG_MAINMENU_OPTION_CHECKBOX_OFF",
}

--- @class BlockfallView: GameViewObject
--- @field stage Frame
--- @field view GameView?
--- @field matchId string?
--- @field piece (BlockfallPiece|{ soft: number, resets: number, lowest: number, twisted: boolean, far: boolean })? The piece falling, while one is
--- @field shown number[] The well as it is drawn, which a clear is shown out of
--- @field down table<string, boolean> The keys held, by what they do
--- @field queued string[] What was pressed between two pieces, to do to the next
--- @field wait number Seconds until the next piece comes in
--- @field fall number Seconds the piece has been on its way down the row it is on
--- @field lock number Seconds it has lain on something
--- @field paused boolean
--- @field counting { beats: string[], at: number }? The count before play, while it goes on
local View = {}
View.__index = View

--- Rounds to the screen's pixels, near enough
--- @param value number
--- @return number
local function whole(value)
  return math.floor(value + 0.5)
end

--- A time to the hundredth of a second: "1:02.37"
--- @param seconds number
--- @return string
local function exactTime(seconds)
  local hundredths = math.floor(seconds * 100 + 0.5)
  return L["race_time"]:format(private.Widgets.Time(math.floor(hundredths / 100)), hundredths % 100)
end

--- A square to draw a piece with: a texture on a frame, with a light over it for when it lands
--- @param parent Frame
--- @param layer string
--- @param sublevel number
--- @return Texture
local function newSquare(parent, layer, sublevel)
  local square = parent:CreateTexture(nil, layer, nil, sublevel)
  square:Hide()
  return square
end

--- @param parent Frame
--- @param title string
--- @return Frame box With .title
local function newBox(parent, title)
  local box = private.Widgets.Panel(parent)
  box:SetBackdropColor(unpack(PANEL))
  box:SetBackdropBorderColor(WELL_EDGE[1], WELL_EDGE[2], WELL_EDGE[3], 0.18)
  box.title = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  box.title:SetPoint("TOP", 0, -5)
  box.title:SetText(title)
  box.title:SetTextColor(unpack(INK_DIM))
  return box
end

--- @param stage Frame
--- @return BlockfallView
local function createView(stage)
  local Widgets = private.Widgets
  --- @type BlockfallView
  local self = setmetatable({
    stage = stage, shown = {}, down = {}, queued = {}, wait = 0, fall = 0, lock = 0, paused = false,
    squares = {}, side = 16, sinceSample = 0, callouts = {},
  }, View)
  for square = 1, WIDTH * HEIGHT do
    self.shown[square] = 0
  end

  -- The well, and on it everything that is in it
  self.well = Widgets.Panel(stage)
  self.well:SetBackdropColor(unpack(WELL))
  self.well:SetBackdropBorderColor(unpack(WELL_EDGE))
  self.board = CreateFrame("Frame", nil, self.well)
  self.lines = {}
  for index = 1, (WIDTH - 1) + (HEIGHT - HIDDEN - 1) do
    local line = self.board:CreateTexture(nil, "BACKGROUND", nil, 1)
    line:SetColorTexture(1, 1, 1, LINE_ALPHA)
    self.lines[index] = line
  end
  for square = 1, WIDTH * HEIGHT do
    self.squares[square] = newSquare(self.board, "ARTWORK", 0)
  end
  self.ghost, self.falling, self.glints = {}, {}, {}
  for index = 1, 4 do
    self.ghost[index] = newSquare(self.board, "ARTWORK", 1)
    self.falling[index] = newSquare(self.board, "ARTWORK", 3)
    -- What lights a piece up for a moment as it comes to rest
    local glint = newSquare(self.board, "OVERLAY", 2)
    glint:SetTexture(FLAT)
    glint:SetBlendMode("ADD")
    self.glints[index] = glint
  end
  -- The streaks a dropped piece leaves behind it, one a column
  self.streaks = {}
  for index = 1, 4 do
    local streak = newSquare(self.board, "ARTWORK", 2)
    streak:SetTexture(IMAGES .. "streak")
    streak:SetBlendMode("ADD")
    self.streaks[index] = streak
  end
  -- The light along a row as it is cleared
  self.flashes = {}
  for index = 1, 4 do
    local flash = newSquare(self.board, "OVERLAY", 3)
    flash:SetTexture(IMAGES .. "flare")
    flash:SetBlendMode("ADD")
    self.flashes[index] = flash
  end

  -- What covers the well: while it is paused, and the count before play
  self.cover = CreateFrame("Frame", nil, self.well)
  self.cover:SetAllPoints()
  self.cover:SetFrameLevel(self.board:GetFrameLevel() + 5)
  self.veil = self.cover:CreateTexture(nil, "BACKGROUND")
  self.veil:SetAllPoints()
  self.veil:SetColorTexture(0.02, 0.025, 0.04, 0.94)
  self.veil:Hide()
  self.big = self.cover:CreateFontString(nil, "OVERLAY")
  self.big:SetFont(STANDARD_TEXT_FONT, 28, "OUTLINE")
  self.big:SetPoint("CENTER", 0, 10)
  self.small = self.cover:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  self.small:SetPoint("TOP", self.big, "BOTTOM", 0, -8)
  self.small:SetTextColor(unpack(INK_DIM))
  -- A click on a paused well plays on
  self.cover:SetScript("OnMouseDown", function()
    if self.paused then
      self:resume()
    end
  end)
  self.cover:EnableMouse(false)

  -- The gauge along the well's side, and where the rival had got to
  self.gauge = Widgets.Panel(stage)
  self.gauge:SetBackdropColor(0, 0, 0, 0.5)
  self.gauge:SetBackdropBorderColor(1, 1, 1, 0.08)
  self.gaugeFill = self.gauge:CreateTexture(nil, "ARTWORK")
  self.gaugeFill:SetTexture(FLAT)
  self.gaugeFill:SetPoint("BOTTOMLEFT", 1, 1)
  self.gaugeFill:SetPoint("BOTTOMRIGHT", -1, 1)
  self.gaugeMark = self.gauge:CreateTexture(nil, "OVERLAY")
  self.gaugeMark:SetColorTexture(1, 0.35, 0.3, 1)
  self.gaugeMark:SetHeight(2)
  self.gaugeMark:Hide()

  -- The piece put aside, and the ones to come
  self.holdBox = newBox(stage, L["blockfall_hold"])
  self.nextBox = newBox(stage, L["blockfall_next"])
  self.holdSquares, self.nextSquares = {}, {}
  for index = 1, 4 do
    self.holdSquares[index] = newSquare(self.holdBox, "ARTWORK", 0)
  end
  for slot = 1, PREVIEW do
    self.nextSquares[slot] = {}
    for index = 1, 4 do
      self.nextSquares[slot][index] = newSquare(self.nextBox, "ARTWORK", 0)
    end
  end

  -- What the game keeps count of
  self.score = Widgets.Stat(stage, L["stat_score"], 80, STAT_HEIGHT)
  self.level = Widgets.Stat(stage, L["blockfall_stat_level"], 80, STAT_HEIGHT)
  self.linesStat = Widgets.Stat(stage, L["blockfall_stat_lines"], 80, STAT_HEIGHT)
  self.time = Widgets.Stat(stage, L["stat_time"], 80, STAT_HEIGHT)
  self.best = Widgets.Stat(stage, L["stat_best"], 80, STAT_HEIGHT)
  self.rival = Widgets.Stat(stage, "", 80, STAT_HEIGHT)
  self.rival:Hide()

  -- What a clear was called, under the piece put aside: "T-Spin Double", "Back-to-Back"
  self.callout = CreateFrame("Frame", nil, stage)
  self.callout:SetFrameLevel(self.well:GetFrameLevel() + 8)
  self.calloutTitle = self.callout:CreateFontString(nil, "OVERLAY")
  self.calloutTitle:SetFont(STANDARD_TEXT_FONT, 16, "OUTLINE")
  self.calloutTitle:SetPoint("TOP")
  self.calloutLine = self.callout:CreateFontString(nil, "OVERLAY")
  self.calloutLine:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
  self.calloutLine:SetPoint("TOP", self.calloutTitle, "BOTTOM", 0, -3)
  self.calloutCombo = self.callout:CreateFontString(nil, "OVERLAY")
  self.calloutCombo:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
  self.calloutCombo:SetPoint("TOP", self.calloutLine, "BOTTOM", 0, -3)
  self.callout:SetAlpha(0)

  self.hint = stage:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  self.hint:SetText(L["blockfall_hint"])
  self.hint:SetJustifyH("CENTER")
  self.hint:SetWordWrap(true)

  self.effects = private.Effects.New(stage)

  -- Times what the view animates by itself, takes the keys and moves the piece
  local ticker = CreateFrame("Frame", nil, stage)
  ticker:SetAllPoints()
  self.animator = Widgets.Animator(CreateFrame("Frame", nil, stage))
  Widgets.Keys(ticker, function(key)
    return self:press(key)
  end, true)
  ticker:SetScript("OnKeyUp", function(_, key)
    local action = KEYS[key]
    if action then
      self.down[key] = nil
    end
  end)
  ticker:SetScript("OnUpdate", function(_, elapsed)
    self:tick(math.min(elapsed, 0.1))
  end)
  -- Out of sight, out of play: the window closed, or another game looked at
  ticker:SetScript("OnHide", function()
    self.down = {}
    self:pause()
  end)
  -- And a fight takes the keys back
  local watch = CreateFrame("Frame", nil, stage)
  watch:RegisterEvent("PLAYER_REGEN_DISABLED")
  watch:SetScript("OnEvent", function()
    self.down = {}
    self:pause()
  end)
  return self
end

-----------------------------
-- Drawing
-----------------------------

--- The picture a square is drawn with at the size squares are now
--- @return string
function View:art(name)
  return IMAGES .. name .. (self.side >= ART_FROM and ART_LARGE or ART_SMALL)
end

--- Where the middle of a square of the well is, from the board's top left corner. The rows above
--- the well are above it
--- @param column number
--- @param row number
--- @return number x, number y
function View:at(column, row)
  local side = self.side
  return (column - 0.5) * side, -(row - HIDDEN - 0.5) * side
end

--- Puts a texture on a square of the well
--- @param texture Texture
--- @param column number
--- @param row number
--- @param scale number? Of a square, 1 if left out
function View:place(texture, column, row, scale)
  local x, y = self:at(column, row)
  local size = self.side * (scale or 1)
  texture:SetSize(size, size)
  texture:ClearAllPoints()
  texture:SetPoint("CENTER", self.board, "TOPLEFT", x, y)
end

--- Paints a square of a piece
--- @param texture Texture
--- @param kind number
--- @param dim number? How much darker, 0 to 1
function View:paint(texture, kind, dim)
  local color = COLORS[kind] or DEAD
  local light = 1 - (dim or 0)
  texture:SetTexture(self:art("block"))
  texture:SetVertexColor(color[1] * light, color[2] * light, color[3] * light, 1)
end

--- Draws what lies in the well, as it is shown (self.shown)
--- @param drop table<number, number>? How far each row is still to come down, in squares: for rows coming down after a clear
--- @param fade table<number, number>? How much is left of each row that is being cleared, 1 to 0
function View:drawWell(drop, fade)
  local shown, squares = self.shown, self.squares
  for row = 1, HEIGHT do
    local going = fade and fade[row]
    local lift = drop and drop[row] or 0
    for column = 1, WIDTH do
      local square = (row - 1) * WIDTH + column
      local texture, kind = squares[square], shown[square]
      if kind == 0 or (going and going <= 0) then
        texture:Hide()
      else
        if self.dead then
          texture:SetTexture(self:art("block"))
          local grey = self.dead[row] and DEAD or COLORS[kind]
          texture:SetVertexColor(grey[1], grey[2], grey[3], 1)
        else
          self:paint(texture, kind)
        end
        local x, y = self:at(column, row - lift)
        -- A row that goes shrinks from the middle out
        local scale = 1
        if going then
          local fromMiddle = math.abs(column - (WIDTH + 1) / 2) / (WIDTH / 2)
          scale = math.max(0, math.min(1, going * 1.6 - fromMiddle * 0.6))
        end
        texture:SetSize(self.side * scale, self.side * scale)
        texture:ClearAllPoints()
        texture:SetPoint("CENTER", self.board, "TOPLEFT", x, y)
        texture:SetAlpha(going and math.min(1, going * 2) or 1)
        texture:SetShown(scale > 0)
      end
    end
  end
end

--- Draws the piece that is falling and where it would land, or neither while there is none
function View:drawPiece()
  local piece, view = self.piece, self.view
  local hidden = not piece or self.paused or not view
  for index = 1, 4 do
    self.falling[index]:SetShown(not hidden)
    self.ghost[index]:SetShown(not hidden)
  end
  if hidden then
    return
  end
  local cells = view.state.cells
  local floor = landing(cells, piece)
  local color = COLORS[piece.kind]
  for index, square in ipairs(squaresOf(piece.kind, piece.turn)) do
    local column = piece.column + square[1]
    local falling = self.falling[index]
    self:paint(falling, piece.kind)
    -- It dims a little as its time to lie there runs out, so it is seen to be about to stay
    local resting = floor == piece.row and math.min(1, self.lock / LOCK_SECONDS) or 0
    falling:SetAlpha(1 - resting * 0.25)
    self:place(falling, column, piece.row + square[2])
    local ghost = self.ghost[index]
    ghost:SetTexture(self:art("ghost"))
    ghost:SetVertexColor(color[1], color[2], color[3], GHOST_ALPHA)
    self:place(ghost, column, floor + square[2])
    ghost:SetShown(ghost:IsShown() and floor ~= piece.row)
  end
end

--- Draws a piece in a box beside the well, in the middle of the room it is given
--- @param textures Texture[]
--- @param kind number? Nothing shown if nil
--- @param box Frame
--- @param x number The middle of the room, from the box's top left
--- @param y number
--- @param side number How big a square is
--- @param dim boolean? Shown darker: it can't be swapped in again yet
function View:drawShape(textures, kind, box, x, y, side, dim)
  for index, texture in ipairs(textures) do
    texture:SetShown(kind ~= nil)
    if kind then
      local square = SHAPES[kind][index]
      local wide, tall, left, top = 0, 0, math.huge, math.huge
      for _, other in ipairs(SHAPES[kind]) do
        left, top = math.min(left, other[1]), math.min(top, other[2])
        wide, tall = math.max(wide, other[1] + 1), math.max(tall, other[2] + 1)
      end
      wide, tall = wide - left, tall - top
      texture:SetTexture(IMAGES .. "block" .. (side >= ART_FROM and ART_LARGE or ART_SMALL))
      local color = COLORS[kind]
      local light = dim and 0.4 or 1
      texture:SetVertexColor(color[1] * light, color[2] * light, color[3] * light, dim and 0.7 or 1)
      texture:SetSize(side, side)
      texture:ClearAllPoints()
      texture:SetPoint("CENTER", box, "TOPLEFT", x + (square[1] - left - wide / 2 + 0.5) * side, -(y + (square[2] - top - tall / 2 + 0.5) * side))
    end
  end
end

--- Draws the piece put aside and the ones to come
function View:drawSides()
  local view, side = self.view, self.side
  if not view then
    return
  end
  --- @type BlockfallState
  local state = view.state
  local holdBox, nextBox = self.holdBox, self.nextBox
  local big, small = whole(side * PREVIEW_BIG), whole(side * PREVIEW_SMALL)
  local titleRoom = 18
  self:drawShape(self.holdSquares, state.hold ~= 0 and state.hold or nil, holdBox, holdBox:GetWidth() / 2,
    titleRoom + (holdBox:GetHeight() - titleRoom) / 2, big, state.held)
  local y = titleRoom + big * 1.4
  for slot = 1, PREVIEW do
    local kind = state.queue[slot]
    local size = slot == 1 and big or small
    self:drawShape(self.nextSquares[slot], kind, nextBox, nextBox:GetWidth() / 2, y, size)
    y = y + (slot == 1 and big * 1.4 + small * 1.5 or small * 2.6)
  end
end

--- Says what the game keeps count of, and fills the gauge
function View:tally()
  local view = self.view
  if not view then
    return
  end
  --- @type BlockfallState
  local state = view.state
  local Widgets = private.Widgets
  local clock = view.clock()
  self.score:Set(points(state.score))
  self.level:Set(state.level)
  local fill, color
  if state.mode == "sprint" then
    self.linesStat:Set(L["blockfall_of"]:format(math.min(state.lines, SPRINT_LINES), SPRINT_LINES))
    self.time:Set(exactTime(clock), true)
    fill, color = state.lines / SPRINT_LINES, Widgets.GOLD
  elseif state.mode == "ultra" then
    self.linesStat:Set(state.lines)
    self.time:Set(Widgets.Time(math.ceil(math.max(0, ULTRA_SECONDS - clock))), true)
    self.time:Tint(ULTRA_SECONDS - clock < 10 and not state.over and Widgets.RED or nil)
    fill, color = 1 - math.min(1, clock / ULTRA_SECONDS), { 0.4, 0.75, 1 }
  else
    self.linesStat:Set(state.lines)
    self.time:Set(Widgets.Time(clock), true)
    fill = state.level >= TOP_LEVEL and 1 or (state.lines % LEVEL_LINES) / LEVEL_LINES
    color = COLORS[T]
  end
  local room = self.gauge:GetHeight() - 2
  self.gaugeFill:SetHeight(math.max(0.01, room * math.max(0, math.min(1, fill))))
  self.gaugeFill:SetVertexColor(color[1], color[2], color[3], 0.85)

  -- The best there was: the quickest sprint, else the most points, which follows the score
  local best, mine = view.best(recordKey(state))
  if state.mode == "sprint" then
    self.best:Set(best and exactTime(best) or L["stat_none"])
  else
    best = math.max(best or 0, state.score)
    self.best:Set(best > 0 and points(best) or L["stat_none"])
  end
  self.best:Tint((mine and best and best ~= 0) and Widgets.GOLD or nil)

  self:tallyRival(state, clock)
end

--- In a race: how far the rival had got by now, from their ghost, or how their run ended
--- @param state BlockfallState
--- @param clock number
function View:tallyRival(state, clock)
  local race = self.view.race
  self.rival:SetShown(race ~= nil)
  self.gaugeMark:Hide()
  if not race then
    return
  end
  self.rival:SetTitle(race.rival)
  local ghost = race.ghost
  local sample = ghost and ghost[math.min(#ghost, math.floor(clock) + 1)]
  local lines, score = 0, 0
  if sample then
    lines, score = sample:match("^(%d+)%.(%d+)$")
    lines, score = tonumber(lines) or 0, tonumber(score) or 0
  end
  -- Where they were at the same moment while their run went on that long, how it ended after
  local text
  if sample and math.floor(clock) + 1 <= #ghost then
    text = state.mode == "sprint" and L["blockfall_of"]:format(math.min(lines, SPRINT_LINES), SPRINT_LINES) or points(score)
  elseif race.theirs == false then
    text = L["race_no_time"]
  elseif race.theirs then
    text = state.mode == "sprint" and exactTime(race.theirs) or points(race.theirs)
  else
    text = L["race_running"]
  end
  self.rival:Set(text, true)
  if sample and state.mode == "sprint" and math.floor(clock) + 1 <= #ghost then
    local room = self.gauge:GetHeight() - 2
    self.gaugeMark:ClearAllPoints()
    self.gaugeMark:SetPoint("BOTTOMLEFT", self.gauge, "BOTTOMLEFT", -2, 1 + room * math.min(1, lines / SPRINT_LINES))
    self.gaugeMark:SetPoint("BOTTOMRIGHT", self.gauge, "BOTTOMRIGHT", 2, 1 + room * math.min(1, lines / SPRINT_LINES))
    self.gaugeMark:Show()
  end
end

--- @param width number
--- @param height number
function View:Layout(width, height)
  self.width, self.height = width, height
  local across = WIDTH + 2 * (SIDE_BOX + GAP)
  local down = (HEIGHT - HIDDEN) + TOP_ROOM
  local side = math.floor(math.min((width - MARGIN * 2) / across, (height - MARGIN * 2 - HINT_HEIGHT * 2) / down))
  side = math.max(8, side)
  self.side = side
  local wellWidth, wellHeight = WIDTH * side, (HEIGHT - HIDDEN) * side
  local left = math.floor((width - wellWidth) / 2)
  local top = math.floor(MARGIN + (height - MARGIN * 2 - HINT_HEIGHT * 2 - down * side) / 2 + TOP_ROOM * side)
  self.wellLeft, self.wellTop = left, top

  self.well:SetSize(wellWidth + 2, wellHeight + 2)
  self:moveWell(0)
  self.board:SetSize(wellWidth, wellHeight)
  self.board:ClearAllPoints()
  self.board:SetPoint("TOPLEFT", self.well, "TOPLEFT", 1, -1)
  -- The faint lines between the squares
  local index = 0
  for column = 1, WIDTH - 1 do
    index = index + 1
    local line = self.lines[index]
    line:SetSize(1, wellHeight)
    line:ClearAllPoints()
    line:SetPoint("TOPLEFT", self.board, "TOPLEFT", column * side, 0)
  end
  for row = 1, HEIGHT - HIDDEN - 1 do
    index = index + 1
    local line = self.lines[index]
    line:SetSize(wellWidth, 1)
    line:ClearAllPoints()
    line:SetPoint("TOPLEFT", self.board, "TOPLEFT", 0, -row * side)
  end

  self.gauge:SetSize(GAUGE_WIDTH + 2, wellHeight + 2)
  self.gauge:ClearAllPoints()
  self.gauge:SetPoint("TOPLEFT", self.well, "TOPRIGHT", 3, 0)

  -- The boxes either side, as high as the top of the well
  local boxWidth = whole(SIDE_BOX * side)
  local gap = whole(GAP * side)
  self.holdBox:SetSize(boxWidth, whole(side * 3.6))
  self.holdBox:ClearAllPoints()
  self.holdBox:SetPoint("TOPRIGHT", self.stage, "TOPLEFT", left - gap, -top)
  local big, small = side * PREVIEW_BIG, side * PREVIEW_SMALL
  self.nextBox:SetSize(boxWidth, whole(18 + big * 2.8 + small * 1.5 + small * 2.6 * (PREVIEW - 1)))
  self.nextBox:ClearAllPoints()
  self.nextBox:SetPoint("TOPLEFT", self.stage, "TOPLEFT", left + wellWidth + gap + GAUGE_WIDTH + 2, -top)

  -- What is kept count of: down the left from the bottom of the well, the best down the right
  local statWidth = boxWidth
  local stats = { self.score, self.level, self.linesStat, self.time }
  for position, stat in ipairs(stats) do
    stat:SetSize(statWidth, STAT_HEIGHT)
    stat:ClearAllPoints()
    stat:SetPoint("BOTTOMRIGHT", self.stage, "TOPLEFT", left - gap, -(top + wellHeight - (#stats - position) * (STAT_HEIGHT + STAT_GAP)))
  end
  for position, stat in ipairs({ self.rival, self.best }) do
    stat:SetSize(statWidth, STAT_HEIGHT)
    stat:ClearAllPoints()
    stat:SetPoint("BOTTOMLEFT", self.stage, "TOPLEFT", left + wellWidth + gap + GAUGE_WIDTH + 2, -(top + wellHeight - (2 - position) * (STAT_HEIGHT + STAT_GAP)))
  end

  self.callout:SetSize(boxWidth + gap, side * 4)
  self.callout:ClearAllPoints()
  self.callout:SetPoint("TOP", self.holdBox, "BOTTOM", 0, -side * 0.8)
  self.calloutTitle:SetFont(STANDARD_TEXT_FONT, math.max(12, whole(side * 0.78)), "OUTLINE")
  self.calloutLine:SetFont(STANDARD_TEXT_FONT, math.max(10, whole(side * 0.56)), "OUTLINE")
  self.calloutCombo:SetFont(STANDARD_TEXT_FONT, math.max(10, whole(side * 0.56)), "OUTLINE")
  self.calloutTitle:SetWidth(boxWidth + gap * 2)
  self.calloutLine:SetWidth(boxWidth + gap * 2)

  self.big:SetFont(STANDARD_TEXT_FONT, math.max(18, whole(side * 1.6)), "OUTLINE")
  self.small:SetWidth(wellWidth - side)

  self.hint:SetWidth(math.min(width - MARGIN * 2, wellWidth + 2 * (boxWidth + gap) + 40))
  self.hint:ClearAllPoints()
  self.hint:SetPoint("TOP", self.stage, "TOPLEFT", width / 2, -(top + wellHeight + MARGIN))

  -- Everything drawn again at the new size
  self:drawWell()
  self:drawPiece()
  self:drawSides()
  self:tally()
end

--- Puts the well where it goes, knocked down a little way if it was just hit
--- @param knock number Pixels
function View:moveWell(knock)
  self.well:ClearAllPoints()
  self.well:SetPoint("TOPLEFT", self.stage, "TOPLEFT", self.wellLeft - 1, -(self.wellTop - 1) - knock)
end

-----------------------------
-- Playing
-----------------------------

--- Whether the game on screen is one that is being played: live, and not over
--- @return boolean
function View:playing()
  local view = self.view
  return view ~= nil and view.live and view.canMove and not view.state.over
end

--- The board the piece falls through, as the rules have it
--- @return number[]
function View:cells()
  return self.view.state.cells
end

--- Forgets the keys that were let go of somewhere the view didn't hear of it
function View:keysUp()
  if not IsKeyDown then
    return
  end
  for key in pairs(self.down) do
    if not IsKeyDown(key) then
      self.down[key] = nil
    end
  end
end

--- Whether a key for something is held
--- @param action string
--- @return boolean
function View:holding(action)
  for key in pairs(self.down) do
    if KEYS[key] == action then
      return true
    end
  end
  return false
end

--- A key was pressed
--- @param key string
--- @return boolean used
function View:press(key)
  local action = KEYS[key]
  if not action or not self:playing() then
    return false
  end
  if self.paused then
    -- Only P plays on: Escape goes on to close the window, the rest to steer the character
    if action == "pause" and key ~= "ESCAPE" then
      self:resume()
      return true
    end
    return false
  end
  if action == "pause" then
    self:pause()
    return true
  end
  self.down[key] = true
  local way = SHIFTS[action]
  if way then
    -- The newest way pressed is the way it goes, and the wait before it repeats starts again
    self.shiftWay, self.shiftHeld, self.shiftOwed = way, 0, 0
  end
  if self:holdingStill() then
    return true
  end
  if not self.piece then
    -- Between two pieces: done to the next as it comes in
    if action == "turn" or action == "back" or action == "hold" then
      self.queued[#self.queued + 1] = action
    end
    return true
  end
  if way then
    self:shift(way)
  elseif action == "turn" or action == "back" then
    self:turn(action == "turn" and 1 or -1)
  elseif action == "drop" then
    self:drop()
  elseif action == "hold" then
    self:hold()
  elseif action == "soft" then
    -- A row at once, so a tap is felt
    self.fall = math.max(self.fall, self:fallEvery())
  end
  return true
end

--- Seconds the piece takes to come down a row now, pushed down or not
--- @return number
function View:fallEvery()
  local every = fallSeconds(self.view.state.level)
  return self:holding("soft") and every / SOFT_TIMES or every
end

--- Whether the piece lies on something
--- @return boolean
function View:grounded()
  local piece = self.piece
  return not fits(self:cells(), piece.kind, piece.turn, piece.column, piece.row + 1)
end

--- The piece was moved or turned: if it lies on something it gets its half second again, as
--- many times as that is allowed
--- @param wasGrounded boolean
function View:moved(wasGrounded)
  local piece = self.piece
  if (wasGrounded or self:grounded()) and piece.resets < LOCK_RESETS then
    piece.resets = piece.resets + 1
    self.lock = 0
  end
  self:drawPiece()
end

--- Moves the piece a square to one side
--- @param way number -1 left, 1 right
--- @param repeated boolean? It is the key repeating, which is quieter
--- @return boolean moved
function View:shift(way, repeated)
  local piece = self.piece
  if not piece or not fits(self:cells(), piece.kind, piece.turn, piece.column + way, piece.row) then
    return false
  end
  local wasGrounded = self:grounded()
  piece.column, piece.twisted = piece.column + way, false
  self:moved(wasGrounded)
  if not repeated then
    private.Widgets.PlaySound(SOUNDS.move)
  end
  return true
end

--- Turns the piece a quarter, kicking it aside if it has to be
--- @param way number 1 clockwise, -1 the other way
--- @return boolean turned
function View:turn(way)
  local piece = self.piece
  local wasGrounded = self:grounded()
  local to, column, row, far = turned(self:cells(), piece, way)
  if not to then
    return false
  end
  piece.turn, piece.column, piece.row, piece.twisted, piece.far = to, column, row, true, far
  if row > piece.lowest then
    piece.lowest, piece.resets = row, 0
  end
  self:moved(wasGrounded)
  private.Widgets.PlaySound(SOUNDS.turn)
  return true
end

--- Drops the piece all the way, where it stays at once
function View:drop()
  local piece = self.piece
  local floor = landing(self:cells(), piece)
  local rows = floor - piece.row
  if rows > 0 then
    piece.twisted = false
    self:streak(piece, floor)
  end
  piece.row, piece.hard = floor, rows
  self:bump()
  private.Widgets.PlaySound(SOUNDS.drop)
  self:settle(true)
end

--- Puts the piece aside, unless the one falling was just swapped in
function View:hold()
  if self.view.state.held then
    private.Widgets.PlaySound("IG_MAINMENU_OPTION_CHECKBOX_OFF")
    return
  end
  self.piece, self.wait = nil, 0
  self:drawPiece()
  self.view.submit(HOLD)
end

--- The piece stays where it is: tells the engine, which answers with the next
--- @param dropped boolean? It was dropped all the way, which made its own sound
function View:settle(dropped)
  local piece = self.piece
  local move = piece.turn .. "." .. piece.column .. "." .. piece.row
  if piece.soft > 0 then
    move = move .. "s" .. math.min(piece.soft, MOST_ROWS)
  end
  if piece.hard > 0 then
    move = move .. "d" .. math.min(piece.hard, MOST_ROWS)
  end
  if piece.twisted then
    move = move .. "t" .. (piece.far and "k" or "")
  end
  self.piece, self.wait, self.fall, self.lock = nil, ENTRY_SECONDS, 0, 0
  self:glint(piece)
  if not dropped then
    private.Widgets.PlaySound(SOUNDS.land)
  end
  self:drawPiece()
  self.view.submit(move)
end

--- The next piece comes in at the top, and whatever was pressed for it is done to it
function View:spawn()
  --- @type BlockfallState
  local state = self.view.state
  local piece = arriving(state)
  -- It comes in a row above the well and drops straight into sight if it can
  if fits(state.cells, piece.kind, piece.turn, piece.column, piece.row + 1) then
    piece.row = piece.row + 1
  end
  piece.soft, piece.hard, piece.resets, piece.lowest, piece.twisted, piece.far = 0, 0, 0, piece.row, false, false
  self.piece, self.fall, self.lock = piece, 0, 0
  local queued = self.queued
  self.queued = {}
  for _, action in ipairs(queued) do
    if action == "hold" then
      if not state.held then
        self:hold()
        return
      end
    else
      self:turn(action == "turn" and 1 or -1)
    end
  end
  self:drawPiece()
end

--- The way a move key is held, if one is: the newest one pressed while it is still held
--- @return number?
function View:heldWay()
  local left, right = self:holding("left"), self:holding("right")
  if (self.shiftWay == -1 and left) or (self.shiftWay == 1 and right) then
    return self.shiftWay
  end
  return (left and -1) or (right and 1) or nil
end

--- Moves the piece on by itself while a move key is held long enough
--- @param elapsed number
function View:repeatShift(elapsed)
  local way = self:heldWay()
  if way ~= self.shiftWay then
    -- The key that was let go of hands over to the other one, which waits again
    self.shiftWay, self.shiftHeld, self.shiftOwed = way, 0, 0
  end
  if not way then
    return
  end
  local before = self.shiftHeld
  self.shiftHeld = before + elapsed
  if self.shiftHeld < SHIFT_DELAY or not self.piece then
    return
  end
  self.shiftOwed = before < SHIFT_DELAY and SHIFT_EVERY or self.shiftOwed + elapsed
  while self.shiftOwed >= SHIFT_EVERY do
    self.shiftOwed = self.shiftOwed - SHIFT_EVERY
    if not self:shift(way, true) then
      self.shiftOwed = 0
    end
  end
end

--- Lets the piece fall, and stay once it has lain long enough
--- @param elapsed number
function View:gravity(elapsed)
  local piece = self.piece
  if self:grounded() then
    self.fall = 0
    self.lock = self.lock + elapsed
    if self.lock >= LOCK_SECONDS then
      self:settle()
      return
    end
    -- Dimming as its time runs out
    self:drawPiece()
    return
  end
  local every, pushed = self:fallEvery(), self:holding("soft")
  self.fall = self.fall + elapsed
  local fell = false
  while self.fall >= every and not self:grounded() do
    self.fall = self.fall - every
    piece.row, piece.twisted, fell = piece.row + 1, false, true
    if pushed then
      piece.soft = piece.soft + 1
    end
    if piece.row > piece.lowest then
      piece.lowest, piece.resets, self.lock = piece.row, 0, 0
    end
  end
  if fell then
    self:drawPiece()
  end
end

--- Whether the game is held still: paused, or counting in before the piece may move
--- @return boolean
function View:holdingStill()
  if self.paused then
    return true
  end
  local counting = self.counting
  return counting ~= nil and counting.at < counting.from * BEAT
end

--- @return boolean
function View:Paused()
  return self:playing() and self:holdingStill()
end

--- Shows the count, and ends it once it has been counted
--- @param elapsed number
function View:count(elapsed)
  local counting = self.counting
  local beat = math.floor(counting.at / BEAT) + 1
  counting.at = counting.at + elapsed
  local now = math.floor(counting.at / BEAT) + 1
  if now > #counting.beats then
    self.counting = nil
    self.big:SetText("")
    self.small:SetText("")
    return
  end
  if now ~= beat or not counting.shown then
    counting.shown = true
    local word = counting.beats[now]
    self.big:SetText(word:match("^%d+$") and word or L[word])
    local last = now == #counting.beats
    self.big:SetTextColor(unpack(last and private.Widgets.GOLD or { 1, 1, 1 }))
    self.small:SetText("")
    private.Widgets.PlaySound(last and counting.from <= #counting.beats and SOUNDS.go or SOUNDS.beat)
  end
  -- Each word comes up a little and fades as its beat ends
  local into = (counting.at % BEAT) / BEAT
  self.big:SetAlpha(into < 0.15 and into / 0.15 or (into > 0.7 and (1 - into) / 0.3 or 1))
end

--- Keeps the well still with the board covered, so that nobody thinks about the next piece for free
function View:pause()
  if not self:playing() or self.paused then
    return
  end
  self.paused, self.counting, self.down = true, nil, {}
  self.board:Hide()
  self.veil:Show()
  self.big:SetText(L["blockfall_paused"])
  self.big:SetTextColor(1, 1, 1)
  self.big:SetAlpha(1)
  self.small:SetText(L["blockfall_paused_how"])
  self.cover:EnableMouse(true)
  private.Widgets.PlaySound(SOUNDS.pause)
end

--- Uncovers the well and counts back into play
function View:resume()
  self.paused = false
  self.board:Show()
  self.veil:Hide()
  self.cover:EnableMouse(false)
  self.small:SetText("")
  self.counting = { beats = RESUME_BEATS, at = 0, from = #RESUME_BEATS + 1 }
  self:count(0)
  self:drawPiece()
end

--- @param elapsed number
function View:tick(elapsed)
  local view = self.view
  if not view or not self:playing() or self.paused then
    return
  end
  self:keysUp()
  if self.counting then
    self:count(elapsed)
    if self:holdingStill() then
      return
    end
  end
  --- @type BlockfallState
  local state = view.state

  -- The clock, which in a game against it can end it
  self.sinceTally = (self.sinceTally or 0) + elapsed
  if self.sinceTally >= 0.05 then
    self.sinceTally = 0
    self:tally()
  end
  if state.mode == "ultra" and view.clock() >= ULTRA_SECONDS then
    self.piece = nil
    self:drawPiece()
    view.submit(TIME_UP)
    return
  end
  if view.sample then
    self.sinceSample = self.sinceSample + elapsed
    if self.sinceSample >= SAMPLE_EVERY then
      self.sinceSample = 0
      view.sample(state.lines .. "." .. state.score)
    end
  end

  self:repeatShift(elapsed)
  if not self.piece then
    self.wait = self.wait - elapsed
    if self.wait <= 0 then
      self:spawn()
    end
    return
  end
  self:gravity(elapsed)
end

-----------------------------
-- Showing what happened
-----------------------------

--- Lights up the squares a piece came to rest on, for a moment
--- @param piece BlockfallPiece
function View:glint(piece)
  local glints = self.glints
  for index, square in ipairs(squaresOf(piece.kind, piece.turn)) do
    local glint = glints[index]
    self:place(glint, piece.column + square[1], piece.row + square[2])
    glint:SetVertexColor(1, 1, 1, 1)
    glint:SetAlpha(0)
    glint:Show()
  end
  self.animator:Play(0.2, function(progress)
    for _, glint in ipairs(glints) do
      glint:SetAlpha(0.45 * (1 - progress))
    end
  end, {
    onDone = function()
      for _, glint in ipairs(glints) do
        glint:Hide()
      end
    end,
  })
end

--- The light a piece leaves behind it as it is dropped, down every column it is in
--- @param piece BlockfallPiece
--- @param floor number The row it lands on
function View:streak(piece, floor)
  local tops, side = {}, self.side
  for _, square in ipairs(squaresOf(piece.kind, piece.turn)) do
    local column, row = piece.column + square[1], piece.row + square[2]
    tops[column] = math.min(tops[column] or row, row)
  end
  local color, index = COLORS[piece.kind], 0
  local used = {}
  for column, top in pairs(tops) do
    index = index + 1
    local streak = self.streaks[index]
    local x, y = self:at(column, top)
    local length = (floor - piece.row) * side + side
    streak:SetSize(side * 0.9, length)
    streak:ClearAllPoints()
    streak:SetPoint("TOP", self.board, "TOPLEFT", x, y + side / 2)
    streak:SetVertexColor(color[1], color[2], color[3], 1)
    streak:Show()
    used[#used + 1] = streak
  end
  self.animator:Play(STREAK_SECONDS, function(progress)
    for _, streak in ipairs(used) do
      streak:SetAlpha(0.55 * (1 - progress))
    end
  end, {
    onDone = function()
      for _, streak in ipairs(used) do
        streak:Hide()
      end
    end,
  })
end

--- Knocks the well down a little, and lets it come back
function View:bump()
  self.animator:Play(BUMP_SECONDS, function(progress)
    self:moveWell(whole(BUMP * math.sin(progress * math.pi)))
  end)
end

--- Says what a clear was, under the piece put aside, for a moment
--- @param title string
--- @param color number[]
--- @param line string?
--- @param combo string?
function View:announce(title, color, line, combo)
  self.calloutTitle:SetText(title)
  self.calloutTitle:SetTextColor(unpack(color))
  self.calloutLine:SetText(line or "")
  self.calloutLine:SetTextColor(unpack(private.Widgets.GOLD))
  self.calloutCombo:SetText(combo or "")
  self.calloutCombo:SetTextColor(0.55, 0.85, 1)
  self.calloutToken = (self.calloutToken or 0) + 1
  local token = self.calloutToken
  self.animator:Play(CALLOUT_SECONDS, function(progress)
    if token ~= self.calloutToken then
      return
    end
    self.callout:SetAlpha(progress < 0.06 and progress / 0.06 or (progress > 0.75 and (1 - progress) / 0.25 or 1))
    self.callout:ClearAllPoints()
    self.callout:SetPoint("TOP", self.holdBox, "BOTTOM", 0, -self.side * 0.8 + (progress < 0.06 and (1 - progress / 0.06) * 6 or 0))
  end)
end

--- What a clear is called
--- @param event BlockfallEvent
--- @return string? title, number[]? color
local function calloutFor(event)
  local lines = #event.rows
  local name = lines > 0 and L["blockfall_lines_" .. lines] or nil
  if event.spin then
    local spin = L[event.spin == "mini" and "blockfall_spin_mini" or "blockfall_spin"]
    return name and L["blockfall_spin_lines"]:format(spin, name) or spin, COLORS[T]
  elseif lines == 4 then
    return name, COLORS[I]
  elseif lines > 0 then
    return name, { 1, 1, 1 }
  end
  return nil
end

--- Shows rows being cleared: they light up and go, from the middle out, and what was above them
--- comes down. The well is drawn from what it was before, until it is what it is now
--- @param rows number[]
--- @param after number[] The well once they are gone
function View:clearRows(rows, after)
  local fade = {}
  for _, row in ipairs(rows) do
    fade[row] = 1
  end
  -- How far every row that stays comes down, by where it ends up
  local fall = {}
  for row = HEIGHT, 1, -1 do
    if not fade[row] then
      local gone = 0
      for _, cleared in ipairs(rows) do
        gone = gone + (cleared > row and 1 or 0)
      end
      fall[row + gone] = gone
    end
  end
  local wide = WIDTH * self.side
  for index, flash in ipairs(self.flashes) do
    local row = rows[index]
    flash:SetShown(row ~= nil)
    if row then
      local _, y = self:at(1, row)
      flash:SetSize(wide * 1.3, self.side * 2.2)
      flash:ClearAllPoints()
      flash:SetPoint("CENTER", self.board, "TOPLEFT", wide / 2, y)
      flash:SetVertexColor(1, 1, 1, 1)
    end
  end
  self:drawWell(nil, fade)
  local quad = #rows == 4
  self.animator:Play(FLASH_SECONDS * (quad and 1.3 or 1), function(progress)
    for row in pairs(fade) do
      fade[row] = 1 - progress
    end
    for index, flash in ipairs(self.flashes) do
      if rows[index] then
        flash:SetAlpha(math.sin(math.min(1, progress * 1.6) * math.pi) * (quad and 1 or 0.8))
        flash:SetWidth(wide * (0.6 + 0.7 * progress))
      end
    end
    self:drawWell(nil, fade)
  end, {
    onDone = function()
      for _, flash in ipairs(self.flashes) do
        flash:Hide()
      end
      for square = 1, WIDTH * HEIGHT do
        self.shown[square] = after[square]
      end
      local lift = {}
      self.animator:Play(COLLAPSE_SECONDS, function(progress)
        for row, gone in pairs(fall) do
          lift[row] = gone * (1 - progress)
        end
        self:drawWell(lift)
      end, { ease = private.Widgets.Ease.into })
    end,
  })
end

--- Shows a piece coming to rest, or put aside, and what came of it
--- @param event BlockfallEvent
function View:play(event)
  local Widgets = private.Widgets
  --- @type BlockfallState
  local state = self.view.state
  if event.action ~= "lock" then
    if event.action == "hold" then
      Widgets.PlaySound(SOUNDS.hold)
    end
    if event.over then
      self:finish(false)
    end
    return
  end

  -- The well as it was, with the piece where it came to rest
  for _, square in ipairs(event.placed) do
    self.shown[square] = event.kind
  end
  local after = {}
  for square, value in ipairs(state.cells) do
    after[square] = value
  end
  local rows = event.rows
  if #rows > 0 then
    self.wait = #rows == 4 and QUAD_CLEAR_SECONDS or CLEAR_SECONDS
    self:clearRows(rows, after)
    -- What it scored drifts up from where the rows were
    local _, y = self:at(1, rows[math.ceil(#rows / 2)])
    local x = self.wellLeft + WIDTH * self.side / 2
    self.effects:Float("+" .. points(event.gained), x, self.wellTop - y, { size = math.max(14, whole(self.side * 0.9)) })
  else
    self.shown = after
    self:drawWell()
  end

  local title, color = calloutFor(event)
  if title then
    local combo = event.combo and L["blockfall_combo"]:format(event.combo) or nil
    self:announce(title, color, event.chain and L["blockfall_chain"] or nil, combo)
  end
  if event.spin and #rows > 0 then
    Widgets.PlaySound(SOUNDS.spin)
  elseif #rows == 4 then
    Widgets.PlaySound(SOUNDS.quad)
    self.effects:Flash({ COLORS[I][1], COLORS[I][2], COLORS[I][3], 0.18 }, 0.45)
  elseif #rows > 0 then
    Widgets.PlaySound(SOUNDS.clear)
  end
  local middleX, middleY = self.wellLeft + WIDTH * self.side / 2, self.wellTop + (HEIGHT - HIDDEN) * self.side * 0.4
  if event.perfect then
    self.effects:Float(L["blockfall_perfect"], middleX, middleY, { size = math.max(18, whole(self.side * 1.3)), color = Widgets.GOLD })
    self.effects:Confetti()
    Widgets.PlaySound(SOUNDS[SOUNDKIT and SOUNDKIT[SOUNDS.won] and "won" or "wonElse"])
  end
  if event.level then
    self.effects:Float(L["blockfall_level_up"]:format(event.level), middleX, middleY + self.side * 2,
      { size = math.max(16, whole(self.side * 1.1)), color = { 0.55, 0.85, 1 }, delay = 0.15 })
    Widgets.PlaySound(SOUNDS.level)
  end
  if event.over then
    self:finish(false)
  end
end

--- How the game ended, across the stage. At once for a game that was over before it was looked at
--- @param instant boolean
function View:finish(instant)
  local view = self.view
  --- @type BlockfallState
  local state = view.state
  local Widgets = private.Widgets
  self.piece, self.queued = nil, {}
  self:drawPiece()
  self:tally()

  local title, words
  if state.blocked then
    title = L["blockfall_over"]
    words = state.mode == "sprint" and L["blockfall_progress_sprint"]:format(state.lines, SPRINT_LINES) or L["blockfall_points"]:format(points(state.score))
  elseif state.mode == "sprint" then
    title, words = L["blockfall_sprint_done"]:format(SPRINT_LINES), exactTime(view.clock())
  elseif state.mode == "ultra" then
    title, words = L["blockfall_time_up"], L["blockfall_points"]:format(points(state.score))
  else
    title, words = L["blockfall_marathon_done"], L["blockfall_points"]:format(points(state.score))
  end
  local best, mine = view.best(recordKey(state))
  if mine and best then
    words = words .. "  " .. L["new_best"]
  end
  local color = state.won and Widgets.GOLD or { 0.92, 0.9, 0.86 }

  if instant then
    if state.blocked then
      self.dead = {}
      for row = 1, HEIGHT do
        self.dead[row] = true
      end
      self:drawWell()
    end
    self.effects:Banner(title, words, { color = color, instant = true })
    return
  end
  if state.blocked then
    -- The stack goes grey from the bottom up, and then it is said
    Widgets.PlaySound(SOUNDS.over)
    self.dead = {}
    self.animator:Play(TOP_OUT_SECONDS, function(progress)
      local up = math.floor(progress * HEIGHT + 0.5)
      for row = HEIGHT, HEIGHT - up + 1, -1 do
        self.dead[row] = true
      end
      self:drawWell()
    end, { delay = 0.15 })
    self.effects:Banner(title, words, { color = color, delay = TOP_OUT_SECONDS + OVER_AFTER })
  else
    self.effects:Confetti(0.1)
    Widgets.PlaySound(SOUNDS[SOUNDKIT and SOUNDKIT[SOUNDS.won] and "won" or "wonElse"])
    self.effects:Banner(title, words, { color = color, delay = OVER_AFTER })
  end
end

--- Starts showing a game afresh: another one than before, or the first
--- @param view GameView
function View:reset(view)
  self.animator:Stop()
  self.effects:Clear()
  self.piece, self.queued, self.wait, self.fall, self.lock = nil, {}, 0, 0, 0
  self.dead, self.paused, self.down = nil, false, {}
  self.shiftWay, self.shiftHeld, self.shiftOwed = nil, 0, 0
  self.callout:SetAlpha(0)
  self.board:Show()
  self.veil:Hide()
  self.cover:EnableMouse(false)
  self.big:SetText("")
  self.small:SetText("")
  for square, value in ipairs(view.state.cells) do
    self.shown[square] = value
  end
  self.counting = self:playing() and { beats = READY_BEATS, at = 0, from = #READY_BEATS - 1 } or nil
  if self.counting then
    self:count(0)
  end
end

--- @param view GameView
function View:Update(view)
  local before = self.view
  self.view = view
  --- @type BlockfallState
  local state = view.state
  local sameGame = before ~= nil and before.match.id == view.match.id
  if not sameGame then
    self:reset(view)
    self:drawWell()
  elseif view.changed then
    -- Whatever was falling was for the position before
    self.piece = nil
    if view.played and view.played.action then
      self:play(view.played)
    else
      for square, value in ipairs(state.cells) do
        self.shown[square] = value
      end
      self:drawWell()
    end
  end
  if not self:playing() then
    -- Given up, or looked back on: nothing falls, and nothing is held still
    self.piece, self.counting = nil, nil
    if self.paused then
      self.paused = false
      self.board:Show()
      self.veil:Hide()
      self.cover:EnableMouse(false)
    end
    self.big:SetText("")
    self.small:SetText("")
  end
  self:drawPiece()
  self:drawSides()
  self:tally()
  -- A game that was over before it was looked at says so without making an entrance
  if state.over and not self.effects:HasBanner() and not (sameGame and view.played) then
    self:finish(true)
  end
end

private.Games.Register({
  id = "blockfall",
  name = L["game_blockfall"],
  description = L["game_blockfall_description"],
  genre = "solo",
  icon = "Interface\\AddOns\\ForeverGames\\Images\\Icons\\blockfall",
  version = 1,
  seats = 1,
  options = {
    {
      id = "mode",
      name = L["blockfall_option_mode"],
      description = L["blockfall_option_mode_tip"],
      choices = MODES,
      default = MODES[1],
      label = function(value)
        return L["blockfall_mode_" .. value]
      end,
    },
    {
      id = "level",
      name = L["blockfall_option_level"],
      description = L["blockfall_option_level_tip"],
      choices = LEVELS,
      default = LEVELS[1],
      label = function(value)
        return L["blockfall_option_level_label"]:format(value)
      end,
      when = function(rules)
        return rules.mode ~= "sprint"
      end,
    },
  },
  howto = {
    {
      heading = L["howto_goal"],
      text = function(rules)
        return L["blockfall_howto_goal_" .. rules.mode]
      end,
    },
    { heading = L["howto_controls"], text = L["blockfall_howto_controls"] },
    { heading = L["blockfall_howto_pieces"], text = L["blockfall_howto_pieces_text"] },
    {
      heading = L["howto_scoring"],
      -- A sprint is for its time, whatever it scored
      text = function(rules)
        return rules.mode ~= "sprint" and L["blockfall_howto_scoring"] or nil
      end,
    },
  },
  clock = "open",
  newState = newState,
  turn = function()
    return 1
  end,
  validate = validate,
  apply = apply,
  moves = moves,
  result = result,
  progress = progress,
  record = function(state, seconds)
    if state.mode ~= "sprint" then
      return { { key = recordKey(state), value = state.score } }
    elseif state.won then
      -- Only forty lines cleared have a time worth keeping
      return { { key = recordKey(state), value = seconds, lower = true } }
    end
    return nil
  end,
  -- A sprint is raced on its time, the others on their points
  raceFor = function(rules)
    if rules.mode == "sprint" then
      return nil
    end
    return {
      key = recordKey(rules),
      show = function(value)
        return L["blockfall_points"]:format(points(value))
      end,
    }
  end,
  -- How far the rival had got, a second at a time: their lines and their points
  ghost = { every = 1 },
  -- The day's two minutes
  daily = {
    rules = { mode = "ultra" },
    score = function(state)
      return state.score
    end,
  },
  createView = createView,
})
