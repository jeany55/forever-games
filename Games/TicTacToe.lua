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
local MARK_COLORS = { { 0.35, 0.75, 1 }, { 1, 0.55, 0.25 } }

local CELL_SIZE = 92
local CELL_GAP = 6

--- @class TicTacToeState
--- @field board table<number, number> Seat occupying each cell
--- @field turn number
--- @field count number Cells filled

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
local function apply(state, seat, move)
  state.board[tonumber(move)] = seat
  state.count = state.count + 1
  state.turn = seat == 1 and 2 or 1
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

--- @param parent Frame
--- @return Button[]
local function createCells(parent)
  local cells = {}
  local offset = (parent:GetWidth() - (CELL_SIZE * 3 + CELL_GAP * 2)) / 2

  for index = 1, 9 do
    local column, row = (index - 1) % 3, math.floor((index - 1) / 3)
    local cell = CreateFrame("Button", nil, parent)
    cell:SetSize(CELL_SIZE, CELL_SIZE)
    cell:SetPoint("TOPLEFT", offset + column * (CELL_SIZE + CELL_GAP), -(offset + row * (CELL_SIZE + CELL_GAP)))

    cell.background = cell:CreateTexture(nil, "BACKGROUND")
    cell.background:SetAllPoints()

    cell.hover = cell:CreateTexture(nil, "HIGHLIGHT")
    cell.hover:SetAllPoints()
    cell.hover:SetColorTexture(1, 1, 1, 0.12)

    cell.mark = cell:CreateFontString(nil, "OVERLAY")
    cell.mark:SetFont(STANDARD_TEXT_FONT, 60, "OUTLINE")
    cell.mark:SetPoint("CENTER")

    cell:SetScript("OnClick", function(self)
      if self.submit then
        self.submit(tostring(index))
      end
    end)

    cells[index] = cell
  end
  return cells
end

--- @param parent Frame
--- @param view GameView
local function render(parent, view)
  parent.cells = parent.cells or createCells(parent)

  --- @type TicTacToeState
  local state = view.state
  local _, winningLine = findWinner(state)
  local winning = {}
  for _, cell in ipairs(winningLine or {}) do
    winning[cell] = true
  end

  for index, cell in ipairs(parent.cells) do
    local seat = state.board[index]
    local playable = view.canMove and not seat

    cell.mark:SetText(seat and MARKS[seat] or "")
    if seat then
      cell.mark:SetTextColor(unpack(MARK_COLORS[seat]))
    end

    if winning[index] then
      cell.background:SetColorTexture(0.2, 0.45, 0.2, 0.9)
    else
      cell.background:SetColorTexture(0.12, 0.12, 0.14, 0.9)
    end

    cell.submit = playable and view.submit or nil
    cell.hover:SetShown(playable)
  end
end

private.Games.Register({
  id = "tictactoe",
  name = L["game_tictactoe"],
  description = L["game_tictactoe_description"],
  icon = "Interface\\AddOns\\ForeverGames\\Images\\Icons\\tictactoe",
  version = 1,
  seats = 2,
  newState = newState,
  turn = function(state)
    return state.turn
  end,
  validate = validate,
  apply = apply,
  result = result,
  render = render,
  seatLabel = function(seat)
    return MARKS[seat]
  end,
})
