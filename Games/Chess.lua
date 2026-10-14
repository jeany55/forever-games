--------------------------
--  Chess
--------------------------
-- Full rules: castling, en passant, promotion, checkmate, stalemate, and draws by threefold
-- repetition, the fifty move rule and insufficient material. Draws by agreement are the engine's
-- business, the game only says it allows them.
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
-- Straight first, then diagonally
local ALL_STEPS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
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

-- From every square: where a knight jumps to, and the squares a line runs through in each of
-- ALL_STEPS, nearest first. Worked out once, they are asked about all the time
--- @type table<number, number[]>
local KNIGHT_JUMPS = {}
--- @type table<number, number[][]>
local RAYS = {}
for square = 0, 63 do
  KNIGHT_JUMPS[square] = {}
  for _, step in ipairs(KNIGHT_STEPS) do
    KNIGHT_JUMPS[square][#KNIGHT_JUMPS[square] + 1] = offset(square, step[1], step[2])
  end
  RAYS[square] = {}
  for index, step in ipairs(ALL_STEPS) do
    local ray, to = {}, offset(square, step[1], step[2])
    while to do
      ray[#ray + 1] = to
      to = offset(to, step[1], step[2])
    end
    RAYS[square][index] = ray
  end
end
-- Which of the lines from a square each piece moves along: the first four of ALL_STEPS are
-- straight, the last four diagonal
local SLIDES = { r = { 1, 4 }, b = { 5, 8 }, q = { 1, 8 }, k = { 1, 8 } }
-- The pieces that attack along the straight lines and along the diagonals, by seat
local STRAIGHT = { [WHITE] = { R = true, Q = true }, [BLACK] = { r = true, q = true } }
local DIAGONAL = { [WHITE] = { B = true, Q = true }, [BLACK] = { b = true, q = true } }

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

  for _, from in ipairs(KNIGHT_JUMPS[square]) do
    if board[from] == knight then
      return true
    end
  end

  local straight, diagonal = STRAIGHT[by], DIAGONAL[by]
  for index, ray in ipairs(RAYS[square]) do
    local sliders = index <= 4 and straight or diagonal
    for distance, from in ipairs(ray) do
      local piece = board[from]
      if piece then
        if sliders[piece] or (distance == 1 and piece == king) then
          return true
        end
        break
      end
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
      elseif kind == "n" then
        for _, to in ipairs(KNIGHT_JUMPS[from]) do
          if ownerOf(board[to]) ~= seat then
            add(candidates, from, to, false)
          end
        end
      else
        local rays = RAYS[from]
        for index = SLIDES[kind][1], SLIDES[kind][2] do
          for distance, to in ipairs(rays[index]) do
            if ownerOf(board[to]) ~= seat then
              add(candidates, from, to, false)
            end
            -- A king goes one square, the others as far as nothing is in the way
            if board[to] or kind == "k" then
              break
            end
          end
        end
      end
    end
  end
  castlingMoves(state, candidates, seat)

  -- Keep the moves that don't leave the mover's own king attacked. Each is made on the board
  -- itself and taken back again, which only ever touches the squares saved here
  local legal = {}
  local king, kingAt = seat == WHITE and "K" or "k", nil
  for square = 0, 63 do
    if board[square] == king then
      kingAt = square
      break
    end
  end
  local enemy, enPassant = other(seat), state.enPassant
  for _, move in ipairs(candidates) do
    local from, to = move.from, move.to
    local piece = board[from]
    local kind = piece:lower()
    local touched = { from, to }
    if kind == "p" and to == enPassant then
      touched[3] = offset(to, 0, seat == WHITE and -1 or 1)
    elseif kind == "k" and math.abs(to - from) == 2 then
      touched[3], touched[4] = to > from and from + 3 or from - 4, to > from and from + 1 or from - 1
    end
    local saved = {}
    for index, square in ipairs(touched) do
      saved[index] = board[square] or false
    end
    movePieces(board, move, enPassant)
    local at = kind == "k" and to or kingAt
    if not at or not isAttacked(board, at, enemy) then
      legal[moveName(move)] = move
    end
    for index, square in ipairs(touched) do
      board[square] = saved[index] or nil
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

--- Every legal move for the side to move, worked out already with every position (evaluate).
--- In order, so that the list is the same whatever order the table keeps them in
--- @param state ChessState
--- @return string[]
local function moves(state)
  local list = {}
  for name in pairs(state.legal) do
    list[#list + 1] = name
  end
  table.sort(list)
  return list
end

--- What a move did, for drawing it and writing it down
--- @class ChessEvent: MatchEvent
--- @field from number
--- @field to number
--- @field piece string The piece that moved, a pawn that promotes is still the pawn
--- @field captured string? The piece taken
--- @field capturedAt number? Where it stood, which en passant makes a different square from `to`
--- @field promotion string?
--- @field rook { from: number, to: number }? The rook's half of castling
--- @field check boolean

--- Writes a move the way players do: "e4", "Nxf3", "O-O", "exd8=Q". Check is added afterwards.
--- @param state ChessState The position before the move
--- @param move ChessMove
--- @param isCapture boolean
--- @return string
local function notationOf(state, move, isCapture)
  local piece = state.board[move.from]
  local kind = piece:lower()
  local to = squareName(move.to)
  local fromName = squareName(move.from)

  if kind == "k" and math.abs(move.to - move.from) == 2 then
    return move.to > move.from and "O-O" or "O-O-O"
  end
  if kind == "p" then
    local text = isCapture and (fromName:sub(1, 1) .. "x" .. to) or to
    return move.promotion and (text .. "=" .. move.promotion:upper()) or text
  end

  -- Say which one when another piece of the same kind could have gone there too: by file if
  -- that settles it, else by rank, else both
  local rivals, sameFile, sameRank = false, false, false
  for _, rival in pairs(state.legal) do
    if rival.to == move.to and rival.from ~= move.from and state.board[rival.from] == piece then
      rivals = true
      sameFile = sameFile or rival.from % 8 == move.from % 8
      sameRank = sameRank or math.floor(rival.from / 8) == math.floor(move.from / 8)
    end
  end
  local which = ""
  if rivals then
    which = not sameFile and fromName:sub(1, 1) or (not sameRank and fromName:sub(2, 2) or fromName)
  end
  return kind:upper() .. which .. (isCapture and "x" or "") .. to
end

--- @param state ChessState
--- @param seat number
--- @param moveString string
--- @return ChessEvent
local function apply(state, seat, moveString)
  local move = state.legal[moveString]
  local board = state.board
  local piece = board[move.from]
  local isPawn = piece:lower() == "p"
  local capturedAt = move.to
  if isPawn and move.to == state.enPassant then
    capturedAt = offset(move.to, 0, seat == WHITE and -1 or 1)
  end
  local captured = board[capturedAt]
  local isCapture = captured ~= nil

  --- @type ChessEvent
  local event = {
    from = move.from,
    to = move.to,
    piece = piece,
    captured = captured,
    capturedAt = isCapture and capturedAt or nil,
    promotion = move.promotion,
    notation = notationOf(state, move, isCapture),
  }
  if piece:lower() == "k" and math.abs(move.to - move.from) == 2 then
    local kingside = move.to > move.from
    event.rook = { from = kingside and move.from + 3 or move.from - 4, to = kingside and move.from + 1 or move.from - 1 }
  end

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

  event.check = state.check
  if state.check then
    event.notation = event.notation .. (state.outcome and "#" or "+")
  end
  return event
end

-----------------------------
-- The computer
-----------------------------
-- It counts what each side has, and where: every piece has squares it is better on, a knight
-- in the middle, a rook on the seventh rank, pawns further up the board. The king keeps out of
-- the way behind its pawns until the queens are gone and there is little left that could
-- trouble it, and comes out to fight then. Two bishops are worth more than a bishop and a
-- knight. It looks at captures first, the most valuable piece taken by the least valuable
-- first, and never stops looking in the middle of an exchange.

local VALUES_OF = { p = 100, n = 320, b = 330, r = 500, q = 900, k = 0 }
local BISHOP_PAIR = 30
-- Below this much besides pawns and kings on the board, the king comes out
local ENDGAME = 1300
-- Where each piece is better and worse off, for white, from a8 along to h1: the way a board
-- is printed. Black's are these upside down
local PLACES = {
  p = {
    0, 0, 0, 0, 0, 0, 0, 0,
    50, 50, 50, 50, 50, 50, 50, 50,
    10, 10, 20, 30, 30, 20, 10, 10,
    5, 5, 10, 25, 25, 10, 5, 5,
    0, 0, 0, 20, 20, 0, 0, 0,
    5, -5, -10, 0, 0, -10, -5, 5,
    5, 10, 10, -20, -20, 10, 10, 5,
    0, 0, 0, 0, 0, 0, 0, 0,
  },
  n = {
    -50, -40, -30, -30, -30, -30, -40, -50,
    -40, -20, 0, 0, 0, 0, -20, -40,
    -30, 0, 10, 15, 15, 10, 0, -30,
    -30, 5, 15, 20, 20, 15, 5, -30,
    -30, 0, 15, 20, 20, 15, 0, -30,
    -30, 5, 10, 15, 15, 10, 5, -30,
    -40, -20, 0, 5, 5, 0, -20, -40,
    -50, -40, -30, -30, -30, -30, -40, -50,
  },
  b = {
    -20, -10, -10, -10, -10, -10, -10, -20,
    -10, 0, 0, 0, 0, 0, 0, -10,
    -10, 0, 5, 10, 10, 5, 0, -10,
    -10, 5, 5, 10, 10, 5, 5, -10,
    -10, 0, 10, 10, 10, 10, 0, -10,
    -10, 10, 10, 10, 10, 10, 10, -10,
    -10, 5, 0, 0, 0, 0, 5, -10,
    -20, -10, -10, -10, -10, -10, -10, -20,
  },
  r = {
    0, 0, 0, 0, 0, 0, 0, 0,
    5, 10, 10, 10, 10, 10, 10, 5,
    -5, 0, 0, 0, 0, 0, 0, -5,
    -5, 0, 0, 0, 0, 0, 0, -5,
    -5, 0, 0, 0, 0, 0, 0, -5,
    -5, 0, 0, 0, 0, 0, 0, -5,
    -5, 0, 0, 0, 0, 0, 0, -5,
    0, 0, 0, 5, 5, 0, 0, 0,
  },
  q = {
    -20, -10, -10, -5, -5, -10, -10, -20,
    -10, 0, 0, 0, 0, 0, 0, -10,
    -10, 0, 5, 5, 5, 5, 0, -10,
    -5, 0, 5, 5, 5, 5, 0, -5,
    0, 0, 5, 5, 5, 5, 0, -5,
    -10, 5, 5, 5, 5, 5, 0, -10,
    -10, 0, 5, 0, 0, 0, 0, -10,
    -20, -10, -10, -5, -5, -10, -10, -20,
  },
  k = {
    -30, -40, -40, -50, -50, -40, -40, -30,
    -30, -40, -40, -50, -50, -40, -40, -30,
    -30, -40, -40, -50, -50, -40, -40, -30,
    -30, -40, -40, -50, -50, -40, -40, -30,
    -20, -30, -30, -40, -40, -30, -30, -20,
    -10, -20, -20, -20, -20, -20, -20, -10,
    20, 20, 0, 0, 0, 0, 20, 20,
    20, 30, 10, 0, 0, 10, 30, 20,
  },
  -- The king once there is little left
  e = {
    -50, -40, -30, -20, -20, -30, -40, -50,
    -30, -20, -10, 0, 0, -10, -20, -30,
    -30, -10, 20, 30, 30, 20, -10, -30,
    -30, -10, 30, 40, 40, 30, -10, -30,
    -30, -10, 30, 40, 40, 30, -10, -30,
    -30, -10, 20, 30, 30, 20, -10, -30,
    -30, -30, 0, 0, 0, 0, -30, -30,
    -50, -30, -30, -30, -30, -30, -30, -50,
  },
}

--- How well a seat stands
--- @param state ChessState
--- @param seat number
--- @return number
local function standing(state, seat)
  local board = state.board
  local officers, bishops = 0, { 0, 0 }
  for _, piece in pairs(board) do
    local kind = piece:lower()
    if kind ~= "p" and kind ~= "k" then
      officers = officers + VALUES_OF[kind]
    end
    if kind == "b" then
      local owner = ownerOf(piece)
      bishops[owner] = bishops[owner] + 1
    end
  end
  local endgame = officers <= ENDGAME

  local score = 0
  for square, piece in pairs(board) do
    local kind = piece:lower()
    local owner = ownerOf(piece)
    local rank, file = math.floor(square / 8), square % 8
    -- The tables are printed from white's side, rank 8 first
    local row = owner == WHITE and 7 - rank or rank
    local places = PLACES[(kind == "k" and endgame) and "e" or kind]
    local worth = VALUES_OF[kind] + places[row * 8 + file + 1]
    score = score + (owner == seat and worth or -worth)
  end
  for owner = WHITE, BLACK do
    if bishops[owner] >= 2 then
      score = score + (owner == seat and BISHOP_PAIR or -BISHOP_PAIR)
    end
  end
  return score
end

--- What a move takes, if anything, en passant included
--- @param state ChessState
--- @param move ChessMove
--- @return string?
local function takes(state, move)
  local captured = state.board[move.to]
  if not captured and move.to == state.enPassant and state.board[move.from]:lower() == "p" then
    return "p"
  end
  return captured and captured:lower()
end

local COMPUTER = {
  evaluate = standing,
  priority = function(state, name)
    local move = state.legal[name]
    if not move then
      return 0
    end
    local captured = takes(state, move)
    local score = move.promotion and VALUES_OF[move.promotion] or 0
    if captured then
      score = score + VALUES_OF[captured] * 10 - VALUES_OF[state.board[move.from]:lower()] / 100
    end
    return score
  end,
  noisy = function(state, name)
    local move = state.legal[name]
    return move ~= nil and (move.promotion ~= nil or takes(state, move) ~= nil)
  end,
  -- How often it came up and, close to the fifty moves, how close: the same pieces can be a draw
  -- one way and not another
  key = function(state)
    local placed = positionKey(state)
    return placed .. (state.positions[placed] or 0) .. (state.halfMoves >= 90 and state.halfMoves or "")
  end,
  copy = function(state)
    local board = {}
    for square, piece in pairs(state.board) do
      board[square] = piece
    end
    local castle = state.castle
    -- A move works out the legal moves anew and only adds to how often a position came up
    return {
      board = board,
      turn = state.turn,
      castle = { K = castle.K, Q = castle.Q, k = castle.k, q = castle.q },
      enPassant = state.enPassant,
      halfMoves = state.halfMoves,
      positions = private.Computer.Over(state.positions),
      legal = state.legal,
      check = state.check,
      last = state.last,
      outcome = state.outcome,
    }
  end,
  levels = {
    -- Looks no further than what it takes, and doesn't see it coming back
    easy = { depth = 2, budget = 300, slip = 0.3, among = 3, quiet = 0 },
    medium = { depth = 3, budget = 1500, slip = 0.1, quiet = 4 },
    hard = { depth = 8, budget = 8000, quiet = 8 },
  },
}

-----------------------------
-- View
-----------------------------
-- The board itself is the shared toolkit's (GUI/Board.lua). What is chess about it is in here:
-- the pieces, which squares to point out, asking what a pawn promotes to, and the trays of
-- captured pieces above and below the board.

-- Each piece comes in several sizes, see Tools/convert_pieces.py
local TEXTURES = "Interface\\AddOns\\ForeverGames\\Images\\Chess\\"
local LAST_MOVE = { 0.95, 0.85, 0.25, 0.4 }
local CHECK = { 0.9, 0.15, 0.15, 0.6 }
local TRAY_HEIGHT = 22
local TRAY_GAP = 4
local VALUES = { p = 1, n = 3, b = 3, r = 5, q = 9, k = 0 }
-- Captured pieces are lined up most valuable first
local TRAY_ORDER = { q = 1, r = 2, b = 3, n = 4, p = 5 }
-- Sound kit names, played through Widgets.PlaySound
local SOUNDS = { move = "IG_ABILITY_ICON_DROP", capture = "IG_BACKPACK_CLOSE", check = "MAP_PING" }

--- @param piece string
--- @param pixels number? Screen pixels it will be drawn at
--- @return string
local function textureFor(piece, pixels)
  return TEXTURES .. private.Board.TextureSize(pixels) .. "\\" .. (ownerOf(piece) == WHITE and "w" or "b") .. piece:upper()
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

--- @class ChessView: GameViewObject
--- @field stage Frame
--- @field board Board
--- @field view GameView? What was last asked for
--- @field pending { from: number, to: number }? A promotion waiting for the player to pick a piece
--- @field dropped boolean? The move being played was dragged, so the piece is already there
local View = {}
View.__index = View

--- A strip showing the pieces one player has taken, and how far ahead they are
--- @param stage Frame
--- @return Frame
local function createTray(stage)
  local tray = CreateFrame("Frame", nil, stage)
  tray.icons = {}
  tray.lead = tray:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  tray.lead:SetTextColor(0.65, 0.65, 0.65)
  return tray
end

--- @param tray Frame
--- @param pieces string[] Pieces taken, in display order
--- @param lead number Points of material ahead, 0 or less shows nothing
local function fillTray(tray, pieces, lead)
  local size = TRAY_HEIGHT
  local x, previous = 0, nil
  for index, piece in ipairs(pieces) do
    local icon = tray.icons[index]
    if not icon then
      icon = tray:CreateTexture(nil, "ARTWORK")
      tray.icons[index] = icon
    end
    -- Pieces of a kind overlap, with a gap before the next kind
    if previous then
      x = x + size * (previous == piece and 0.5 or 0.85)
    end
    icon:SetTexture(textureFor(piece, size))
    icon:SetSize(size, size)
    icon:ClearAllPoints()
    icon:SetPoint("LEFT", x, 0)
    icon:Show()
    previous = piece
  end
  for index = #pieces + 1, #tray.icons do
    tray.icons[index]:Hide()
  end

  tray.lead:ClearAllPoints()
  tray.lead:SetPoint("LEFT", previous and (x + size + 4) or 2, 0)
  tray.lead:SetText(lead > 0 and ("+" .. lead) or "")
end

--- Asks what a pawn becomes: the four choices in a column down from the square it reached, over
--- a dimmed board. Clicking anywhere else takes the move back.
--- @param self ChessView
local function createPicker(self)
  local boardFrame = self.board.frame

  local dim = CreateFrame("Button", nil, boardFrame)
  dim:SetAllPoints()
  dim:SetFrameLevel(boardFrame:GetFrameLevel() + 5)
  local shade = dim:CreateTexture(nil, "BACKGROUND")
  shade:SetAllPoints()
  shade:SetColorTexture(0, 0, 0, 0.45)
  dim:SetScript("OnClick", function()
    self.pending = nil
    self:draw()
  end)
  dim:Hide()

  local picker = CreateFrame("Frame", nil, dim)
  picker:SetFrameLevel(boardFrame:GetFrameLevel() + 10)
  local background = picker:CreateTexture(nil, "BACKGROUND")
  background:SetAllPoints()
  background:SetColorTexture(0.93, 0.93, 0.9, 1)

  picker.buttons = {}
  for index, promotion in ipairs(PROMOTIONS) do
    local button = CreateFrame("Button", nil, picker)
    button.piece = button:CreateTexture(nil, "ARTWORK")
    button.piece:SetAllPoints()
    local hover = button:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetColorTexture(0.25, 0.7, 0.3, 0.45)
    button:SetScript("OnClick", function()
      local pending = self.pending
      -- The pawn is already drawn where it is going
      self.dropped = true
      self.view.submit(squareName(pending.from) .. squareName(pending.to) .. promotion)
      self.dropped = nil
    end)
    picker.buttons[index] = button
  end

  self.dim, self.picker = dim, picker
end

--- @param stage Frame
--- @return ChessView
local function createView(stage)
  --- @type ChessView
  local self = setmetatable({ stage = stage }, View)

  self.board = private.Board.New(stage, { columns = 8, rows = 8, files = "abcdefgh", ranks = "12345678" })
  self.board.frame:SetPoint("CENTER")
  self.board:SetInput({
    pickable = function(square)
      return ownerOf(self.view.state.board[square]) == self.view.seat
    end,
    targets = function(square)
      return targetsFrom(self.view.state, square)
    end,
    onMove = function(from, to, dropped)
      self:play(from, to, dropped)
    end,
  })

  -- The opponent's captures above the board, the player's own below
  self.trays = { createTray(stage), createTray(stage) }
  self.trays[1]:SetPoint("BOTTOMLEFT", self.board.frame, "TOPLEFT", 0, TRAY_GAP)
  self.trays[2]:SetPoint("TOPLEFT", self.board.frame, "BOTTOMLEFT", 0, -TRAY_GAP)

  createPicker(self)
  return self
end

--- A piece was put on a square it can go to
--- @param from number
--- @param to number
--- @param dropped boolean
function View:play(from, to, dropped)
  local move = targetsFrom(self.view.state, from)[to]
  if not move then
    return
  end
  if move.promotion then
    -- Ask which piece before sending anything
    self.pending = { from = from, to = to }
    self:draw()
    return
  end
  self.dropped = dropped
  self.view.submit(moveName(move))
  self.dropped = nil
end

--- @param width number
--- @param height number
function View:Layout(width, height)
  local board = self.board
  board:SetSize(math.min(width, height - 2 * (TRAY_HEIGHT + TRAY_GAP)))
  for _, tray in ipairs(self.trays) do
    tray:SetSize(board.cell * 8, TRAY_HEIGHT)
  end
  self.picker:SetSize(board.cell, board.cell * #PROMOTIONS)
  for index, button in ipairs(self.picker.buttons) do
    button:SetSize(board.cell, board.cell)
    button:ClearAllPoints()
    button:SetPoint("TOPLEFT", 0, -(index - 1) * board.cell)
  end
  if self.view then
    self:draw()
  end
end

--- Puts the current position on the board
function View:draw()
  local view = self.view
  --- @type ChessState
  local state = view.state
  local board, pending = self.board, self.pending

  local pieces = {}
  for square, piece in pairs(state.board) do
    pieces[square] = piece
  end
  if pending then
    -- While the player chooses, the pawn stands where it is going
    pieces[pending.to], pieces[pending.from] = pieces[pending.from], nil
  end
  board:SetPieces(pieces, textureFor)

  local tints = {}
  if state.last then
    tints[state.last.from], tints[state.last.to] = LAST_MOVE, LAST_MOVE
  end
  if state.check then
    local king = state.turn == WHITE and "K" or "k"
    for square, piece in pairs(state.board) do
      if piece == king then
        tints[square] = CHECK
      end
    end
  end
  board:SetTints(tints)

  self.dim:SetShown(pending ~= nil)
  if pending then
    local x, y = board:OffsetOf(pending.to)
    self.picker:ClearAllPoints()
    self.picker:SetPoint("TOPLEFT", board.frame, "TOPLEFT", x, -y)
    for index, promotion in ipairs(PROMOTIONS) do
      local piece = view.seat == WHITE and promotion:upper() or promotion
      self.picker.buttons[index].piece:SetTexture(textureFor(piece, board:pixels()))
    end
  end

  -- What each side has taken so far, and who is ahead on what is left
  local taken, material = { {}, {} }, { 0, 0 }
  for index = 1, view.ply do
    local event = view.events[index]
    if event and event.captured then
      table.insert(taken[event.seat], event.captured)
    end
  end
  for _, piece in pairs(state.board) do
    material[ownerOf(piece)] = material[ownerOf(piece)] + VALUES[piece:lower()]
  end
  local seats = { other(view.seat), view.seat }
  for index, seat in ipairs(seats) do
    table.sort(taken[seat], function(a, b)
      return TRAY_ORDER[a:lower()] < TRAY_ORDER[b:lower()]
    end)
    fillTray(self.trays[index], taken[seat], material[seat] - material[other(seat)])
  end
end

--- @param view GameView
function View:Update(view)
  self.view = view

  local board = self.board
  if view.changed then
    -- What was picked up or being chosen belonged to the position that was showing
    self.pending = nil
    board:Select(nil)
    board:StopGlides()
  end
  if not view.canMove then
    self.pending = nil
  end
  -- Each player sees their own pieces at the bottom
  board:SetFlipped(view.seat == BLACK)
  board:SetEnabled(view.canMove)
  self:draw()

  --- @type ChessEvent?
  local event = view.played
  if event then
    if not self.dropped then
      board:Glide(event.to, event.from)
    end
    if event.rook then
      board:Glide(event.rook.to, event.rook.from)
    end
    private.Widgets.PlaySound(SOUNDS[event.check and "check" or (event.captured and "capture" or "move")])
  end
end

private.Games.Register({
  id = "chess",
  name = L["game_chess"],
  description = L["game_chess_description"],
  genre = "strategy",
  icon = "Interface\\AddOns\\ForeverGames\\Images\\Icons\\chess",
  -- 2: draws by agreement
  version = 2,
  seats = 2,
  draws = true,
  history = true,
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
  seatLabel = function(seat)
    return seat == WHITE and L["chess_white"] or L["chess_black"]
  end,
})
