--------------------------
--  Tic Tac Toe
--------------------------
-- The reference game. A move is the cell number "1" to "9", counted left to right, top to bottom.
-- Seat 1 plays X and moves first.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L

local LINES = { { 1, 2, 3 }, { 4, 5, 6 }, { 7, 8, 9 }, { 1, 4, 7 }, { 2, 5, 8 }, { 3, 6, 9 }, { 1, 5, 9 }, { 3, 5, 7 } }
local MARKS = { "X", "O" }

--- @class TicTacToeState
--- @field board table<number, number> Seat occupying each cell
--- @field turn number
--- @field count number Cells filled
--- @field last number? The cell that was marked last

--- @class TicTacToeEvent: MatchEvent
--- @field cell number

--- @return TicTacToeState
local function newState()
  return { board = {}, turn = 1, count = 0 }
end

--- @param state TicTacToeState
--- @return number? winner, number[]? line
local function findWinner(state)
  local board = state.board
  for _, line in ipairs(LINES) do
    local seat = board[line[1]]
    if seat and seat == board[line[2]] and seat == board[line[3]] then
      return seat, line
    end
  end
  return nil
end

--- @param state TicTacToeState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  local cell = tonumber(move)
  if not cell or cell < 1 or cell > 9 or cell ~= math.floor(cell) or tostring(cell) ~= move then
    return false, "invalid_move"
  end
  if seat ~= state.turn then
    return false, "not_your_turn"
  end
  if state.board[cell] then
    return false, "cell_taken"
  end
  return true
end

--- @param state TicTacToeState
--- @param seat number
--- @param move string
--- @return TicTacToeEvent
local function apply(state, seat, move)
  local cell = tonumber(move)
  state.board[cell] = seat
  state.count = state.count + 1
  state.turn = seat == 1 and 2 or 1
  state.last = cell
  return { cell = cell }
end

--- Every cell that is still empty
--- @param state TicTacToeState
--- @return string[]
local function moves(state)
  local list = {}
  for cell = 1, 9 do
    if not state.board[cell] then
      list[#list + 1] = tostring(cell)
    end
  end
  return list
end

--- @param state TicTacToeState
--- @return { winner: number }?
local function result(state)
  local winner = findWinner(state)
  if winner then
    return { winner = winner }
  end
  if state.count == 9 then
    return { winner = 0 }
  end
  return nil
end

-----------------------------
-- View
-----------------------------
-- Nine squares of the shared board (GUI/Board.lua) with a line between them, and a nought or a
-- cross put down where the player clicks. The line that wins lights up.

local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\Marks\\"
local TEXTURES = { "x", "o" }
local SIZE = 3
local PAPER = { 0.13, 0.14, 0.17 }
local RULES = { 0.42, 0.44, 0.5 }
-- Nothing marks the empty squares, any of them will do
local NO_MARK = { 0, 0, 0, 0 }
local LAST_MOVE = { 1, 1, 1, 0.07 }
local WON = { 0.25, 0.7, 0.3, 0.5 }
-- Squares grow with the window up to this size
local MAX_CELL_SIZE = 140
local SOUND = "IG_ABILITY_ICON_DROP"

--- The board counts its squares from the bottom left and from 0, the game from the top left and from 1
--- @param cell number
--- @return number square
local function squareOf(cell)
  return (SIZE - 1 - math.floor((cell - 1) / SIZE)) * SIZE + (cell - 1) % SIZE
end

--- @param square number
--- @return number cell
local function cellOf(square)
  return (SIZE - 1 - math.floor(square / SIZE)) * SIZE + square % SIZE + 1
end

--- @param seat number
--- @param pixels number? Screen pixels it will be drawn at
--- @return string
local function textureFor(seat, pixels)
  return IMAGES .. private.Board.TextureSize(pixels) .. "\\" .. TEXTURES[seat]
end

--- @class TicTacToeView: GameViewObject
--- @field board Board
--- @field view GameView? What was last asked for
local View = {}
View.__index = View

--- @param stage Frame
--- @return TicTacToeView
local function createView(stage)
  --- @type TicTacToeView
  local self = setmetatable({}, View)

  local options = { columns = SIZE, rows = SIZE, light = PAPER, dark = PAPER, lines = RULES, mark = NO_MARK }
  self.board = private.Board.New(stage, options)
  self.board.frame:SetPoint("CENTER")
  self.board:SetInput({
    place = function(square)
      return not self.view.state.board[cellOf(square)] and square or nil
    end,
    onPlace = function(square)
      self.view.submit(tostring(cellOf(square)))
    end,
  })
  return self
end

--- @param width number
--- @param height number
function View:Layout(width, height)
  self.board:SetSize(math.min(width, height, MAX_CELL_SIZE * SIZE))
end

--- @param view GameView
function View:Update(view)
  self.view = view
  --- @type TicTacToeState
  local state = view.state
  local board = self.board
  if view.changed then
    board:StopGlides()
  end
  board:SetEnabled(view.canMove)

  local pieces, tints = {}, {}
  for cell, seat in pairs(state.board) do
    pieces[squareOf(cell)] = seat
  end
  if state.last then
    tints[squareOf(state.last)] = LAST_MOVE
  end
  local _, line = findWinner(state)
  for _, cell in ipairs(line or {}) do
    tints[squareOf(cell)] = WON
  end
  board:SetPieces(pieces, textureFor)
  board:SetTints(tints)

  --- @type TicTacToeEvent?
  local event = view.played
  if event then
    board:Pop(squareOf(event.cell))
    private.Widgets.PlaySound(SOUND)
  end
end

private.Games.Register({
  id = "tictactoe",
  name = L["game_tictactoe"],
  description = L["game_tictactoe_description"],
  genre = "casual",
  icon = "Interface\\AddOns\\ForeverGames\\Images\\Icons\\tictactoe",
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
    return MARKS[seat]
  end,
})
