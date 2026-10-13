--------------------------
--  Chess
--------------------------
-- Full rules: castling, en passant, promotion, checkmate, stalemate, and draws by threefold
-- repetition, the fifty move rule and insufficient material. Draws by agreement are not possible,
-- the engine has no way for players to offer anything yet.
--
-- A move is the origin and destination square, plus the piece letter when promoting: "e2e4",
-- "e1g1" (castling moves the king two squares), "e7e8q". Seat 1 plays white.
--
-- Squares are numbered 0 (a1) to 63 (h8). Pieces are the usual letters, upper case for white.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L

local WHITE, BLACK = 1, 2

local KNIGHT_STEPS = { { 1, 2 }, { 2, 1 }, { 2, -1 }, { 1, -2 }, { -1, -2 }, { -2, -1 }, { -2, 1 }, { -1, 2 } }
local ROOK_STEPS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local BISHOP_STEPS = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
local ALL_STEPS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
local SLIDERS = { r = ROOK_STEPS, b = BISHOP_STEPS, q = ALL_STEPS }
local PROMOTIONS = { "q", "r", "b", "n" }
local BACK_RANK = { "r", "n", "b", "q", "k", "b", "n", "r" }

-- Castling rights lost when a piece leaves or is captured on a square
local CASTLE_SQUARES = { [0] = "Q", [4] = "KQ", [7] = "K", [56] = "q", [60] = "kq", [63] = "k" }

--- @class ChessMove
--- @field from number
--- @field to number
--- @field promotion string? Lower case piece letter

--- @class ChessState
--- @field board table<number, string>
--- @field turn number
--- @field castle table<string, boolean> Remaining castling rights, keyed K Q k q
--- @field enPassant number? Square a pawn can capture onto en passant
--- @field halfMoves number Half moves since the last capture or pawn move
--- @field positions table<string, number> How often each position has occurred
--- @field legal table<string, ChessMove> Legal moves for the side to move, by move string
--- @field check boolean Whether the side to move is in check
--- @field last ChessMove? The move that led here
--- @field outcome { winner: number, detail: string }?

-----------------------------
-- Board helpers
-----------------------------

--- @param piece string?
--- @return number?
local function ownerOf(piece)
  if not piece then
    return nil
  end
  return piece:lower() == piece and BLACK or WHITE
end

--- @param seat number
--- @return number
local function other(seat)
  return seat == WHITE and BLACK or WHITE
end

--- @param square number
--- @return string
local function squareName(square)
  return string.char(97 + square % 8) .. (math.floor(square / 8) + 1)
end

--- @param move ChessMove
--- @return string
local function moveName(move)
  return squareName(move.from) .. squareName(move.to) .. (move.promotion or "")
end

--- Square reached by stepping from a square, nil when that leaves the board
--- @return number?
local function offset(square, files, ranks)
  local file, rank = square % 8 + files, math.floor(square / 8) + ranks
  if file < 0 or file > 7 or rank < 0 or rank > 7 then
    return nil
  end
  return rank * 8 + file
end

--- @param board table<number, string>
--- @param square number
--- @param by number Attacking seat
--- @return boolean
local function isAttacked(board, square, by)
  local pawn, knight, king = "p", "n", "k"
  if by == WHITE then
    pawn, knight, king = "P", "N", "K"
  end

  -- A pawn attacks diagonally forward, so look one rank back from the target
  local back = by == WHITE and -1 or 1
  for _, files in ipairs({ -1, 1 }) do
    local from = offset(square, files, back)
    if from and board[from] == pawn then
      return true
    end
  end

  for _, step in ipairs(KNIGHT_STEPS) do
    local from = offset(square, step[1], step[2])
    if from and board[from] == knight then
      return true
    end
  end

  for index, step in ipairs(ALL_STEPS) do
    local straight = index <= 4
    local from = offset(square, step[1], step[2])
    if from and board[from] == king then
      return true
    end
    while from do
      local piece = board[from]
      if piece then
        local kind = piece:lower()
        if ownerOf(piece) == by and (kind == "q" or kind == (straight and "r" or "b")) then
          return true
        end
        break
      end
      from = offset(from, step[1], step[2])
    end
  end

  return false
end

--- @param board table<number, string>
--- @param seat number
--- @return boolean
local function inCheck(board, seat)
  local king = seat == WHITE and "K" or "k"
  for square = 0, 63 do
    if board[square] == king then
      return isAttacked(board, square, other(seat))
    end
  end
  return false
end

--- Moves the pieces for a move, including the rook when castling and the pawn taken en passant
--- @param board table<number, string>
--- @param move ChessMove
--- @param enPassant number?
local function movePieces(board, move, enPassant)
  local piece = board[move.from]
  local kind = piece:lower()
  board[move.from] = nil
  board[move.to] = piece

  if kind == "p" then
    if move.to == enPassant then
      board[offset(move.to, 0, ownerOf(piece) == WHITE and -1 or 1)] = nil
    end
    if move.promotion then
      board[move.to] = ownerOf(piece) == WHITE and move.promotion:upper() or move.promotion
    end
  elseif kind == "k" and math.abs(move.to - move.from) == 2 then
    local kingside = move.to > move.from
    local rookFrom = kingside and move.from + 3 or move.from - 4
    local rookTo = kingside and move.from + 1 or move.from - 1
    board[rookTo] = board[rookFrom]
    board[rookFrom] = nil
  end
end

-----------------------------
-- Move generation
-----------------------------

--- @param moves ChessMove[]
--- @param from number
--- @param to number
--- @param promotes boolean
local function add(moves, from, to, promotes)
  if promotes then
    for _, promotion in ipairs(PROMOTIONS) do
      moves[#moves + 1] = { from = from, to = to, promotion = promotion }
    end
  else
    moves[#moves + 1] = { from = from, to = to }
  end
end

--- @param state ChessState
--- @param moves ChessMove[]
--- @param from number
--- @param seat number
local function pawnMoves(state, moves, from, seat)
  local board = state.board
  local forward = seat == WHITE and 1 or -1
  local rank = math.floor(from / 8)
  local promotes = rank == (seat == WHITE and 6 or 1)

  local ahead = offset(from, 0, forward)
  if ahead and not board[ahead] then
    add(moves, from, ahead, promotes)
    if rank == (seat == WHITE and 1 or 6) then
      local twoAhead = offset(from, 0, forward * 2)
      if not board[twoAhead] then
        add(moves, from, twoAhead, false)
      end
    end
  end

  for _, files in ipairs({ -1, 1 }) do
    local to = offset(from, files, forward)
    if to and ((board[to] and ownerOf(board[to]) ~= seat) or to == state.enPassant) then
      add(moves, from, to, promotes)
    end
  end
end

--- @param state ChessState
--- @param moves ChessMove[]
--- @param seat number
local function castlingMoves(state, moves, seat)
  local board = state.board
  local king = seat == WHITE and 4 or 60
  local enemy = other(seat)
  if board[king] ~= (seat == WHITE and "K" or "k") or isAttacked(board, king, enemy) then
    return
  end

  local rook = seat == WHITE and "R" or "r"
  if state.castle[seat == WHITE and "K" or "k"] and board[king + 3] == rook then
    if not board[king + 1] and not board[king + 2] and not isAttacked(board, king + 1, enemy) then
      add(moves, king, king + 2, false)
    end
  end
  if state.castle[seat == WHITE and "Q" or "q"] and board[king - 4] == rook then
    if not board[king - 1] and not board[king - 2] and not board[king - 3] and not isAttacked(board, king - 1, enemy) then
      add(moves, king, king - 2, false)
    end
  end
end

--- Every legal move for the side to move
--- @param state ChessState
--- @return table<string, ChessMove>
local function legalMoves(state)
  local board, seat = state.board, state.turn
  local candidates = {}

  for from = 0, 63 do
    local piece = board[from]
    if ownerOf(piece) == seat then
      local kind = piece:lower()
      if kind == "p" then
        pawnMoves(state, candidates, from, seat)
      elseif kind == "n" or kind == "k" then
        for _, step in ipairs(kind == "n" and KNIGHT_STEPS or ALL_STEPS) do
          local to = offset(from, step[1], step[2])
          if to and ownerOf(board[to]) ~= seat then
            add(candidates, from, to, false)
          end
        end
      else
        for _, step in ipairs(SLIDERS[kind]) do
          local to = offset(from, step[1], step[2])
          while to do
            if ownerOf(board[to]) ~= seat then
              add(candidates, from, to, false)
            end
            if board[to] then
              break
            end
            to = offset(to, step[1], step[2])
          end
        end
      end
    end
  end
  castlingMoves(state, candidates, seat)

  -- Keep the moves that don't leave the mover's own king attacked
  local legal = {}
  for _, move in ipairs(candidates) do
    local after = {}
    for square, piece in pairs(board) do
      after[square] = piece
    end
    movePieces(after, move, state.enPassant)
    if not inCheck(after, seat) then
      legal[moveName(move)] = move
    end
  end
  return legal
end

-----------------------------
-- Rules
-----------------------------

--- Identifies a position for the repetition rule: placement, side to move and what is still possible
--- @param state ChessState
--- @return string
local function positionKey(state)
  local parts = {}
  for square = 0, 63 do
    parts[#parts + 1] = state.board[square] or "."
  end
  for _, right in ipairs({ "K", "Q", "k", "q" }) do
    parts[#parts + 1] = state.castle[right] and right or "-"
  end
  parts[#parts + 1] = state.turn
  parts[#parts + 1] = state.enPassant or "-"
  return table.concat(parts)
end

--- Whether neither side has enough left to ever deliver checkmate
--- @param board table<number, string>
--- @return boolean
local function insufficientMaterial(board)
  local minors = 0
  for square = 0, 63 do
    local kind = board[square] and board[square]:lower()
    if kind == "p" or kind == "r" or kind == "q" then
      return false
    elseif kind == "n" or kind == "b" then
      minors = minors + 1
    end
  end
  return minors <= 1
end

--- Works out what the side to move can do and whether the game is over
--- @param state ChessState
local function evaluate(state)
  state.legal = legalMoves(state)
  state.check = inCheck(state.board, state.turn)

  local key = positionKey(state)
  state.positions[key] = (state.positions[key] or 0) + 1

  if not next(state.legal) then
    if state.check then
      state.outcome = { winner = other(state.turn), detail = "checkmate" }
    else
      state.outcome = { winner = 0, detail = "stalemate" }
    end
  elseif insufficientMaterial(state.board) then
    state.outcome = { winner = 0, detail = "material" }
  elseif state.positions[key] >= 3 then
    state.outcome = { winner = 0, detail = "repetition" }
  elseif state.halfMoves >= 100 then
    state.outcome = { winner = 0, detail = "fifty" }
  end
end

--- @return ChessState
local function newState()
  local board = {}
  for file = 0, 7 do
    board[file] = BACK_RANK[file + 1]:upper()
    board[8 + file] = "P"
    board[48 + file] = "p"
    board[56 + file] = BACK_RANK[file + 1]
  end

  local state = {
    board = board,
    turn = WHITE,
    castle = { K = true, Q = true, k = true, q = true },
    halfMoves = 0,
    positions = {},
  }
  evaluate(state)
  return state
end

--- @param state ChessState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  if seat ~= state.turn then
    return false, "not_your_turn"
  end
  if state.outcome or not state.legal[move] then
    return false, "invalid_move"
  end
  return true
end

--- @param state ChessState
--- @param seat number
--- @param moveString string
local function apply(state, seat, moveString)
  local move = state.legal[moveString]
  local board = state.board
  local isPawn = board[move.from]:lower() == "p"
  local isCapture = board[move.to] ~= nil or (isPawn and move.to == state.enPassant)

  movePieces(board, move, state.enPassant)

  for _, square in ipairs({ move.from, move.to }) do
    for right in (CASTLE_SQUARES[square] or ""):gmatch(".") do
      state.castle[right] = false
    end
  end

  state.enPassant = nil
  if isPawn and math.abs(move.to - move.from) == 16 then
    state.enPassant = (move.from + move.to) / 2
  end

  state.halfMoves = (isPawn or isCapture) and 0 or state.halfMoves + 1
  state.last = move
  state.turn = other(seat)
  evaluate(state)
end

-----------------------------
-- Board
-----------------------------

local CELL_SIZE = 36
local TEXTURES = "Interface\\AddOns\\ForeverGames\\Images\\Chess\\"
local LIGHT = { 0.86, 0.80, 0.66 }
local DARK = { 0.45, 0.32, 0.23 }

local render

--- @param piece string
--- @return string
local function textureFor(piece)
  return TEXTURES .. (ownerOf(piece) == WHITE and "w" or "b") .. piece:upper()
end

--- Legal destinations of the piece on a square
--- @param state ChessState
--- @param from number?
--- @return table<number, ChessMove>
local function targetsFrom(state, from)
  local targets = {}
  if from then
    for _, move in pairs(state.legal) do
      if move.from == from then
        targets[move.to] = move
      end
    end
  end
  return targets
end

--- @param parent Frame
--- @param square number
local function onCellClicked(parent, square)
  local view = parent.view
  if not view.canMove then
    return
  end

  parent.promoting = nil
  local move = targetsFrom(view.state, parent.selected)[square]
  if move and move.promotion then
    -- Ask which piece before sending anything
    parent.promoting = { from = move.from, to = move.to }
  elseif move then
    parent.selected = nil
    return view.submit(moveName(move))
  elseif ownerOf(view.state.board[square]) == view.seat and parent.selected ~= square then
    parent.selected = square
  else
    parent.selected = nil
  end
  render(parent, view)
end

--- @param parent Frame
local function createWidgets(parent)
  local margin = (parent:GetWidth() - CELL_SIZE * 8) / 2

  parent.cells = {}
  for index = 0, 63 do
    local cell = CreateFrame("Button", nil, parent)
    cell:SetSize(CELL_SIZE, CELL_SIZE)
    cell:SetPoint("TOPLEFT", margin + (index % 8) * CELL_SIZE, -(margin + math.floor(index / 8) * CELL_SIZE))

    cell.background = cell:CreateTexture(nil, "BACKGROUND")
    cell.background:SetAllPoints()

    -- Tints the square: selection, last move or check
    cell.tint = cell:CreateTexture(nil, "BORDER")
    cell.tint:SetAllPoints()

    cell.piece = cell:CreateTexture(nil, "ARTWORK")
    cell.piece:SetPoint("TOPLEFT", 1, -1)
    cell.piece:SetPoint("BOTTOMRIGHT", -1, 1)

    -- Marks a square the selected piece can move to
    cell.target = cell:CreateTexture(nil, "OVERLAY")
    cell.target:SetSize(12, 12)
    cell.target:SetPoint("CENTER")
    cell.target:SetColorTexture(0.2, 0.75, 0.25, 0.85)

    local hover = cell:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetColorTexture(1, 1, 1, 0.15)

    cell:SetScript("OnClick", function(self)
      onCellClicked(parent, self.square)
    end)
    parent.cells[index] = cell
  end

  -- Promotion choice, shown over the board
  local picker = CreateFrame("Frame", nil, parent)
  picker:SetSize(#PROMOTIONS * 48 + 12, 60)
  picker:SetPoint("CENTER")
  picker:SetFrameLevel(parent:GetFrameLevel() + 10)
  picker:EnableMouse(true)
  local background = picker:CreateTexture(nil, "BACKGROUND")
  background:SetAllPoints()
  background:SetColorTexture(0.08, 0.08, 0.1, 0.95)

  picker.buttons = {}
  for index, promotion in ipairs(PROMOTIONS) do
    local button = CreateFrame("Button", nil, picker)
    button:SetSize(48, 48)
    button:SetPoint("LEFT", 6 + (index - 1) * 48, 0)
    button.piece = button:CreateTexture(nil, "ARTWORK")
    button.piece:SetAllPoints()
    local hover = button:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetColorTexture(1, 1, 1, 0.2)
    button:SetScript("OnClick", function()
      local pending = parent.promoting
      parent.promoting, parent.selected = nil, nil
      parent.view.submit(squareName(pending.from) .. squareName(pending.to) .. promotion)
    end)
    picker.buttons[index] = button
  end
  parent.picker = picker
end

--- @param parent Frame
--- @param view GameView
render = function(parent, view)
  if not parent.cells then
    createWidgets(parent)
  end

  --- @type ChessState
  local state = view.state
  -- A selection only makes sense for the position it was made in
  local position = view.match.id .. ":" .. #view.match.log
  if parent.position ~= position or not view.canMove then
    parent.selected, parent.promoting = nil, nil
  end
  parent.position = position
  parent.view = view

  local targets = targetsFrom(state, parent.selected)
  local checked
  if state.check then
    local king = state.turn == WHITE and "K" or "k"
    for square = 0, 63 do
      if state.board[square] == king then
        checked = square
      end
    end
  end

  for index = 0, 63 do
    -- Each player sees their own pieces at the bottom
    local file, rank = index % 8, 7 - math.floor(index / 8)
    if view.seat == BLACK then
      file, rank = 7 - file, 7 - rank
    end
    local square = rank * 8 + file
    local cell = parent.cells[index]
    local piece = state.board[square]

    cell.square = square
    cell.background:SetColorTexture(unpack((file + rank) % 2 == 0 and DARK or LIGHT))

    if piece then
      cell.piece:SetTexture(textureFor(piece))
    end
    cell.piece:SetShown(piece ~= nil)

    if square == parent.selected then
      cell.tint:SetColorTexture(0.25, 0.7, 0.3, 0.55)
    elseif square == checked then
      cell.tint:SetColorTexture(0.9, 0.15, 0.15, 0.6)
    elseif state.last and (square == state.last.from or square == state.last.to) then
      cell.tint:SetColorTexture(0.95, 0.85, 0.25, 0.4)
    else
      cell.tint:SetColorTexture(0, 0, 0, 0)
    end

    cell.target:SetShown(targets[square] ~= nil)
  end

  parent.picker:SetShown(parent.promoting ~= nil)
  for index, promotion in ipairs(PROMOTIONS) do
    parent.picker.buttons[index].piece:SetTexture(textureFor(view.seat == WHITE and promotion:upper() or promotion))
  end
end

private.Games.Register({
  id = "chess",
  name = L["game_chess"],
  description = L["game_chess_description"],
  icon = "Interface\\AddOns\\ForeverGames\\Images\\Icons\\chess",
  version = 1,
  seats = 2,
  newState = newState,
  turn = function(state)
    return state.turn
  end,
  validate = validate,
  apply = apply,
  result = function(state)
    return state.outcome
  end,
  render = render,
  seatLabel = function(seat)
    return seat == WHITE and L["chess_white"] or L["chess_black"]
  end,
})
