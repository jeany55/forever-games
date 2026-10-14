--------------------------
--  Connect Four
--------------------------
-- Seven columns, six rows. Players take turns dropping a disc into a column, where it falls as
-- far as it can. Four in a line wins, a full rack with no line is a draw.
--
-- A move is the column, "1" to "7" from the left. Seat 1 plays red and moves first.
--
-- Squares are numbered the way GUI/Board.lua does it: row by row from the bottom left, from 0.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L

local COLUMNS, ROWS = 7, 6
local LINE = 4
-- The four ways a line can run, each is also looked along backwards
local DIRECTIONS = { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 1, -1 } }

--- @class ConnectFourState
--- @field board table<number, number> Seat owning the disc on each square
--- @field heights number[] Discs in each column
--- @field turn number
--- @field count number Discs dropped
--- @field last number? Square the last disc landed on
--- @field winner number?
--- @field line number[]? The squares that won it

--- @class ConnectFourEvent: MatchEvent
--- @field square number Where the disc landed

--- @return ConnectFourState
local function newState()
  local heights = {}
  for column = 1, COLUMNS do
    heights[column] = 0
  end
  return { board = {}, heights = heights, turn = 1, count = 0 }
end

--- The line of four or more through a square, if its disc is part of one
--- @param board table<number, number>
--- @param square number
--- @return number[]?
local function lineThrough(board, square)
  local seat = board[square]
  local column, row = square % COLUMNS, math.floor(square / COLUMNS)
  for _, direction in ipairs(DIRECTIONS) do
    local line = { square }
    for _, sign in ipairs({ 1, -1 }) do
      local nextColumn, nextRow = column + direction[1] * sign, row + direction[2] * sign
      while nextColumn >= 0 and nextColumn < COLUMNS and nextRow >= 0 and nextRow < ROWS do
        local other = nextRow * COLUMNS + nextColumn
        if board[other] ~= seat then
          break
        end
        line[#line + 1] = other
        nextColumn, nextRow = nextColumn + direction[1] * sign, nextRow + direction[2] * sign
      end
    end
    if #line >= LINE then
      return line
    end
  end
  return nil
end

--- @param state ConnectFourState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  local column = tonumber(move)
  if not column or column < 1 or column > COLUMNS or column ~= math.floor(column) or tostring(column) ~= move then
    return false, "invalid_move"
  end
  if seat ~= state.turn then
    return false, "not_your_turn"
  end
  if state.heights[column] >= ROWS then
    return false, "column_full"
  end
  return true
end

--- @param state ConnectFourState
--- @param seat number
--- @param move string
--- @return ConnectFourEvent
local function apply(state, seat, move)
  local column = tonumber(move)
  local square = state.heights[column] * COLUMNS + column - 1
  state.board[square] = seat
  state.heights[column] = state.heights[column] + 1
  state.count = state.count + 1
  state.last = square
  state.turn = seat == 1 and 2 or 1

  state.line = lineThrough(state.board, square)
  if state.line then
    state.winner = seat
  end
  return { square = square }
end

--- Every column that still has room for a disc
--- @param state ConnectFourState
--- @return string[]
local function moves(state)
  local list = {}
  for column = 1, COLUMNS do
    if state.heights[column] < ROWS then
      list[#list + 1] = tostring(column)
    end
  end
  return list
end

--- @param state ConnectFourState
--- @return { winner: number }?
local function result(state)
  if state.winner then
    return { winner = state.winner }
  end
  if state.count == COLUMNS * ROWS then
    return { winner = 0 }
  end
  return nil
end

-----------------------------
-- View
-----------------------------
-- A blue rack with a hole for every square, on the shared board (GUI/Board.lua). The player
-- points anywhere in a column and the board shows where the disc would come to rest.

local DISCS = { "red", "yellow" }
local RACK = { 0.15, 0.33, 0.66 }
local HOLE = { texture = "Interface\\AddOns\\ForeverGames\\Images\\Board\\disc", color = { 0.05, 0.1, 0.24 }, scale = 0.84 }
local LANDING = { 1, 1, 1, 0.3 }
local LAST_MOVE = { 1, 1, 1, 0.16 }
local WON = { 0.3, 0.9, 0.35, 0.6 }
-- Room kept above the rack for a disc to drop in from
local HEADROOM = 16
local SOUND = "chipsCollide"

--- @class ConnectFourView: GameViewObject
--- @field board Board
--- @field view GameView? What was last asked for
local View = {}
View.__index = View

--- @param stage Frame
--- @return ConnectFourView
local function createView(stage)
  --- @type ConnectFourView
  local self = setmetatable({}, View)

  self.board = private.Board.New(stage, {
    columns = COLUMNS,
    rows = ROWS,
    light = RACK,
    dark = RACK,
    inlay = HOLE,
    mark = LANDING,
  })
  self.board.frame:SetPoint("BOTTOM")
  self.board:SetInput({
    -- Anywhere in a column means the lowest free square in it
    place = function(square)
      local column = square % COLUMNS + 1
      local height = self.view.state.heights[column]
      return height < ROWS and height * COLUMNS + column - 1 or nil
    end,
    onPlace = function(square)
      self.view.submit(tostring(square % COLUMNS + 1))
    end,
  })
  return self
end

--- @param width number
--- @param height number
function View:Layout(width, height)
  self.board:SetSize(width, height - HEADROOM)
end

--- @param view GameView
function View:Update(view)
  self.view = view
  --- @type ConnectFourState
  local state = view.state
  local board = self.board
  if view.changed then
    board:StopGlides()
  end
  board:SetEnabled(view.canMove)

  local pieces, tints = {}, {}
  for square, seat in pairs(state.board) do
    pieces[square] = DISCS[seat]
  end
  if state.last then
    tints[state.last] = LAST_MOVE
  end
  for _, square in ipairs(state.line or {}) do
    tints[square] = WON
  end
  board:SetPieces(pieces, private.Board.Disc)
  board:SetTints(tints)

  --- @type ConnectFourEvent?
  local event = view.played
  if event then
    board:Drop(event.square)
    private.Widgets.PlaySound(SOUND)
  end
end

private.Games.Register({
  id = "connectfour",
  name = L["game_connectfour"],
  description = L["game_connectfour_description"],
  genre = "casual",
  icon = "Interface\\AddOns\\ForeverGames\\Images\\Icons\\connectfour",
  version = 1,
  seats = 2,
  newState = newState,
  turn = function(state)
    return state.turn
  end,
  validate = validate,
  apply = apply,
  moves = moves,
  result = result,
  createView = createView,
  seatLabel = function(seat)
    return seat == 1 and L["connectfour_red"] or L["connectfour_yellow"]
  end,
})
