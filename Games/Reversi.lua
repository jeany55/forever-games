--------------------------
--  Reversi
--------------------------
-- Players take turns placing a disc so that it traps one or more lines of the opponent's discs
-- between itself and another disc of their own. The trapped discs turn over. A player with
-- nowhere to place sits the turn out, and when neither can place the one with more discs wins.
--
-- A move is the square the disc goes on, "a1" to "h8". Seat 1 plays black and moves first.
-- Sitting out isn't a move: the game just says it is the same player's turn again.
--
-- Squares are numbered 0 (a1) to 63 (h8).

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L

local BLACK, WHITE = 1, 2
local SIZE = 8
local DIRECTIONS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }

--- @class ReversiState
--- @field board table<number, number> Seat owning the disc on each square
--- @field turn number
--- @field legal table<number, number[]> Where the side to move may place, with the discs each placement turns over
--- @field counts number[] Discs by seat
--- @field last number? Square of the last disc placed
--- @field passed number? Seat that had to sit out after the last move
--- @field outcome { winner: number }?

--- @class ReversiEvent: MatchEvent
--- @field square number Where the disc went
--- @field flipped number[] Discs it turned over
--- @field passed boolean? The opponent had no move after it

--- @param seat number
--- @return number
local function other(seat)
  return seat == BLACK and WHITE or BLACK
end

--- @param square number
--- @return string
local function squareName(square)
  return string.char(97 + square % SIZE) .. (math.floor(square / SIZE) + 1)
end

--- The discs a seat would turn over by placing on an empty square
--- @param board table<number, number>
--- @param seat number
--- @param square number
--- @return number[]
local function flipsFor(board, seat, square)
  local flips = {}
  local column, row = square % SIZE, math.floor(square / SIZE)
  for _, direction in ipairs(DIRECTIONS) do
    local line = {}
    local nextColumn, nextRow = column + direction[1], row + direction[2]
    while nextColumn >= 0 and nextColumn < SIZE and nextRow >= 0 and nextRow < SIZE do
      local at = nextRow * SIZE + nextColumn
      local owner = board[at]
      if owner == seat then
        -- The line is closed off by one of their own, everything in between turns
        for _, trapped in ipairs(line) do
          flips[#flips + 1] = trapped
        end
        break
      elseif not owner then
        break
      end
      line[#line + 1] = at
      nextColumn, nextRow = nextColumn + direction[1], nextRow + direction[2]
    end
  end
  return flips
end

--- @param board table<number, number>
--- @param seat number
--- @return table<number, number[]>
local function legalMoves(board, seat)
  local legal = {}
  for square = 0, SIZE * SIZE - 1 do
    if not board[square] then
      local flips = flipsFor(board, seat, square)
      if #flips > 0 then
        legal[square] = flips
      end
    end
  end
  return legal
end

--- @return ReversiState
local function newState()
  local board = { [27] = WHITE, [36] = WHITE, [28] = BLACK, [35] = BLACK }
  return { board = board, turn = BLACK, legal = legalMoves(board, BLACK), counts = { 2, 2 } }
end

--- @param state ReversiState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  local file, rank = move:match("^([a-h])([1-8])$")
  if not file then
    return false, "invalid_move"
  end
  if seat ~= state.turn then
    return false, "not_your_turn"
  end
  if not state.legal[(file:byte() - 97) + (tonumber(rank) - 1) * SIZE] then
    return false, "invalid_move"
  end
  return true
end

--- @param state ReversiState
--- @param seat number
--- @param move string
--- @return ReversiEvent
local function apply(state, seat, move)
  local square = (move:byte(1) - 97) + (tonumber(move:sub(2)) - 1) * SIZE
  local flipped = state.legal[square]
  local opponent = other(seat)

  state.board[square] = seat
  for _, turned in ipairs(flipped) do
    state.board[turned] = seat
  end
  state.counts[seat] = state.counts[seat] + #flipped + 1
  state.counts[opponent] = state.counts[opponent] - #flipped
  state.last = square

  -- The opponent is next if they can place anywhere. If not the turn comes straight back, and
  -- if that doesn't help either the game is over
  state.turn, state.legal, state.passed = opponent, legalMoves(state.board, opponent), nil
  if not next(state.legal) then
    state.turn, state.legal = seat, legalMoves(state.board, seat)
    if next(state.legal) then
      state.passed = opponent
    else
      local mine, theirs = state.counts[seat], state.counts[opponent]
      state.outcome = { winner = mine == theirs and 0 or (mine > theirs and seat or opponent) }
    end
  end

  return { square = square, flipped = flipped, passed = state.passed ~= nil, notation = move }
end

-----------------------------
-- View
-----------------------------
-- A green board on the shared toolkit (GUI/Board.lua), with the squares a disc may go on marked,
-- and each player's number of discs above and below it.

local DISCS = { "black", "white" }
local FELT = { 0.14, 0.48, 0.26 }
local LINES = { 0.07, 0.3, 0.16 }
local LABELS = { 0.55, 0.8, 0.6 }
local PLACEABLE = { 0, 0, 0, 0.3 }
local LAST_MOVE = { 1, 0.9, 0.3, 0.3 }
local TALLY_HEIGHT = 22
local TALLY_GAP = 4
-- Seconds between one disc starting to turn and the next one further out
local RIPPLE = 0.07
local SOUND = "chipsCollide"

--- @param seat number
--- @return string
local function seatLabel(seat)
  return seat == BLACK and L["reversi_black"] or L["reversi_white"]
end

--- @class ReversiView: GameViewObject
--- @field board Board
--- @field tallies Frame[] The opponent's above the board, the player's own below
--- @field note FontString Says when somebody had to sit out
--- @field view GameView? What was last asked for
local View = {}
View.__index = View

--- @param stage Frame
--- @return ReversiView
local function createView(stage)
  --- @type ReversiView
  local self = setmetatable({}, View)
  local Board = private.Board

  self.board = Board.New(stage, {
    columns = SIZE,
    rows = SIZE,
    light = FELT,
    dark = FELT,
    lines = LINES,
    mark = PLACEABLE,
    files = "abcdefgh",
    ranks = "12345678",
    label = LABELS,
  })
  self.board.frame:SetPoint("CENTER")
  self.board:SetInput({
    place = function(square)
      return self.view.state.legal[square] and square or nil
    end,
    onPlace = function(square)
      self.view.submit(squareName(square))
    end,
  })

  self.tallies = { Board.Tally(stage, TALLY_HEIGHT), Board.Tally(stage, TALLY_HEIGHT) }
  self.tallies[1]:SetPoint("BOTTOMLEFT", self.board.frame, "TOPLEFT", 0, TALLY_GAP)
  self.tallies[2]:SetPoint("TOPLEFT", self.board.frame, "BOTTOMLEFT", 0, -TALLY_GAP)

  self.note = private.Widgets.Label(stage, "GameFontHighlightSmall")
  self.note:SetPoint("TOPRIGHT", self.board.frame, "BOTTOMRIGHT", 0, -TALLY_GAP - 4)
  self.note:SetTextColor(unpack(private.Widgets.GOLD))
  return self
end

--- @param width number
--- @param height number
function View:Layout(width, height)
  local board = self.board
  board:SetSize(math.min(width, height - 2 * (TALLY_HEIGHT + TALLY_GAP)))
  for _, tally in ipairs(self.tallies) do
    tally:SetWidth(board.cell * SIZE / 2)
  end
end

--- @param view GameView
function View:Update(view)
  self.view = view
  --- @type ReversiState
  local state = view.state
  local board = self.board
  if view.changed then
    board:StopGlides()
  end
  board:SetEnabled(view.canMove)

  local pieces = {}
  for square, seat in pairs(state.board) do
    pieces[square] = DISCS[seat]
  end
  board:SetPieces(pieces, private.Board.Disc)
  board:SetTints(state.last and { [state.last] = LAST_MOVE } or {})

  for index, seat in ipairs({ other(view.seat), view.seat }) do
    self.tallies[index]:Set(private.Board.Disc(DISCS[seat], TALLY_HEIGHT), seatLabel(seat) .. "  " .. state.counts[seat])
  end
  self.note:SetText(state.passed and L["reversi_passed"]:format(seatLabel(state.passed), seatLabel(state.turn)) or "")

  --- @type ReversiEvent?
  local event = view.played
  if event then
    -- The trapped discs turn over one after the other, outwards from the one that was placed
    local column, row = event.square % SIZE, math.floor(event.square / SIZE)
    for _, square in ipairs(event.flipped) do
      local distance = math.max(math.abs(square % SIZE - column), math.abs(math.floor(square / SIZE) - row))
      board:Flip(square, DISCS[other(event.seat)], (distance - 1) * RIPPLE)
    end
    board:Pop(event.square)
    private.Widgets.PlaySound(SOUND)
  end
end

private.Games.Register({
  id = "reversi",
  name = L["game_reversi"],
  description = L["game_reversi_description"],
  genre = "strategy",
  icon = "Interface\\AddOns\\ForeverGames\\Images\\Icons\\reversi",
  version = 1,
  seats = 2,
  history = true,
  newState = newState,
  turn = function(state)
    return state.turn
  end,
  validate = validate,
  apply = apply,
  result = function(state)
    return state.outcome
  end,
  createView = createView,
  seatLabel = seatLabel,
})
