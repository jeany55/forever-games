--------------------------
--  Checkers
--------------------------
-- English draughts. Men move one square diagonally forward and take by jumping over a piece
-- next to them onto the empty square behind it. A man that reaches the far row is crowned and
-- moves and takes backwards too. Taking is compulsory, and a piece that can take again from
-- where it landed has to go on, all in the same move. A man that is crowned stops there. A
-- player with no pieces or no move left loses. The game is drawn by agreement, when a position
-- comes up for the third time, or after forty moves each without a capture or a man moving.
--
-- A move is every square the piece stands on, joined by dashes: "11-15", or "22-15-8" for a
-- double jump. Squares have the numbers players know them by, 1 to 32 over the dark squares,
-- starting in the first player's own right hand corner. Seat 1 plays red and moves first.
--
-- The board itself is numbered the way GUI/Board.lua does it, 0 to 63 from the bottom left as
-- red sees it. Pieces are "r" and "w", upper case once crowned.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Grid = private.Grid

local RED, WHITE = 1, 2
local SIZE = 8
local BOARD = Grid.New(SIZE)
local ALL_STEPS = Grid.DIAGONAL
-- Where a man may go, the two up the board for red and the two down it for white
local MAN_STEPS = { { ALL_STEPS[1], ALL_STEPS[2] }, { ALL_STEPS[3], ALL_STEPS[4] } }
-- Half moves without a capture or a man moving that make a draw
local QUIET_LIMIT = 80

--- @class CheckersMove
--- @field path number[] Every square the piece stands on, starting where it is
--- @field captures number[] Squares of the pieces it takes, one per jump

--- @class CheckersState
--- @field board table<number, string>
--- @field turn number
--- @field legal table<string, CheckersMove> Legal moves for the side to move, by move string
--- @field quiet number Half moves since the last capture or man move
--- @field positions table<string, number> How often each position has occurred
--- @field last CheckersMove? The move that led here
--- @field outcome { winner: number, detail: string? }?

--- @class CheckersEvent: MatchEvent
--- @field path number[] Every square the piece stood on
--- @field to number Where it ended up
--- @field captured number[] Squares of the pieces it took
--- @field crowned boolean

-----------------------------
-- Board helpers
-----------------------------

--- @param piece string?
--- @return number?
local function ownerOf(piece)
  if not piece then
    return nil
  end
  return piece:lower() == "r" and RED or WHITE
end

--- @param seat number
--- @return number
local function other(seat)
  return seat == RED and WHITE or RED
end

--- @param piece string
--- @return boolean
local function isKing(piece)
  return piece:upper() == piece
end

--- The number players call a dark square by
--- @param square number
--- @return number
local function numberOf(square)
  return math.floor(square / SIZE) * 4 + 4 - math.floor((square % SIZE) / 2)
end

--- @param number number 1 to 32
--- @return number
local function squareOf(number)
  local row = math.floor((number - 1) / 4)
  return row * SIZE + 2 * (3 - (number - 1) % 4) + row % 2
end

--- Whether a man of this seat is crowned on a square
--- @param seat number
--- @param square number
--- @return boolean
local function isCrownRow(seat, square)
  return math.floor(square / SIZE) == (seat == RED and SIZE - 1 or 0)
end

--- @param path number[]
--- @param separator string
--- @return string
local function pathName(path, separator)
  local numbers = {}
  for index, square in ipairs(path) do
    numbers[index] = numberOf(square)
  end
  return table.concat(numbers, separator)
end

--- @param moves table<string, CheckersMove>
--- @param path number[]
--- @param captures number[]
local function add(moves, path, captures)
  local move = { path = { unpack(path) }, captures = { unpack(captures) } }
  moves[pathName(path, "-")] = move
end

-----------------------------
-- Move generation
-----------------------------

--- Adds every way the piece that set out from path[1] can go on jumping from where it is now.
--- A piece that can jump again has to, so only the complete sequences are moves.
--- @param board table<number, string>
--- @param piece string
--- @param path number[] Squares it has stood on so far
--- @param captures number[] Pieces it has taken so far, still on the board until the move is over
--- @param moves table<string, CheckersMove>
--- @return boolean found Whether it could jump at all from here
local function addJumps(board, piece, path, captures, moves)
  local seat, square = ownerOf(piece), path[#path]
  local found = false
  for _, step in ipairs(isKing(piece) and ALL_STEPS or MAN_STEPS[seat]) do
    local over = BOARD:Step(square, step[1], step[2])
    local to = BOARD:Step(square, step[1] * 2, step[2] * 2)
    local victim = over and board[over]
    local taken = false
    for _, captured in ipairs(captures) do
      taken = taken or captured == over
    end
    -- The square it set out from is empty by now, a king can come back through it
    if to and victim and ownerOf(victim) ~= seat and not taken and (not board[to] or to == path[1]) then
      found = true
      path[#path + 1], captures[#captures + 1] = to, over
      -- Being crowned ends the move, the new king doesn't get to jump on
      local crowned = not isKing(piece) and isCrownRow(seat, to)
      if crowned or not addJumps(board, piece, path, captures, moves) then
        add(moves, path, captures)
      end
      path[#path], captures[#captures] = nil, nil
    end
  end
  return found
end

--- @param board table<number, string>
--- @param seat number
--- @param free boolean? Taking is up to the player
--- @return table<string, CheckersMove>
local function legalMoves(board, seat, free)
  local jumps, steps = {}, {}
  for square, piece in pairs(board) do
    if ownerOf(piece) == seat then
      addJumps(board, piece, { square }, {}, jumps)
      for _, step in ipairs(isKing(piece) and ALL_STEPS or MAN_STEPS[seat]) do
        local to = BOARD:Step(square, step[1], step[2])
        if to and not board[to] then
          add(steps, { square, to }, {})
        end
      end
    end
  end
  if free then
    for key, move in pairs(steps) do
      jumps[key] = move
    end
    return jumps
  end
  -- Taking is compulsory: with a jump on, nothing else is allowed
  return next(jumps) and jumps or steps
end

--- Identifies a position for the repetition rule
--- @param state CheckersState
--- @return string
local function positionKey(state)
  local parts = {}
  for number = 1, 32 do
    parts[number] = state.board[squareOf(number)] or "."
  end
  parts[33] = state.turn
  return table.concat(parts)
end

--- Works out the legal moves and whether the game is over. Called after every move
--- @param state CheckersState
local function evaluate(state)
  state.legal = legalMoves(state.board, state.turn, state.free)
  local key = positionKey(state)
  state.positions[key] = (state.positions[key] or 0) + 1

  if not next(state.legal) then
    -- Out of pieces or out of moves, either way they have lost
    state.outcome = { winner = other(state.turn) }
  elseif state.positions[key] >= 3 then
    state.outcome = { winner = 0, detail = "repetition" }
  elseif state.quiet >= QUIET_LIMIT then
    state.outcome = { winner = 0, detail = "forty" }
  end
end

-----------------------------
-- Rules
-----------------------------

--- @param _ number
--- @param __ Random
--- @param rules table<string, any>? The usual ones if left out
--- @return CheckersState
local function newState(_, __, rules)
  local board = {}
  for number = 1, 12 do
    board[squareOf(number)] = "r"
    board[squareOf(number + 20)] = "w"
  end
  --- @type CheckersState
  local state = { board = board, turn = RED, legal = {}, quiet = 0, positions = {}, free = rules ~= nil and not rules.forced }
  evaluate(state)
  return state
end

--- @param state CheckersState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  if seat ~= state.turn then
    return false, "not_your_turn"
  end
  if not state.legal[move] then
    return false, "invalid_move"
  end
  return true
end

--- @param state CheckersState
--- @param seat number
--- @param moveString string
--- @return CheckersEvent
local function apply(state, seat, moveString)
  local move = state.legal[moveString]
  local board, path = state.board, move.path
  local from, to = path[1], path[#path]
  local piece = board[from]
  local crowned = not isKing(piece) and isCrownRow(seat, to)

  state.quiet = (#move.captures > 0 or not isKing(piece)) and 0 or state.quiet + 1
  board[from] = nil
  for _, square in ipairs(move.captures) do
    board[square] = nil
  end
  board[to] = crowned and piece:upper() or piece
  state.last = move
  state.turn = other(seat)
  evaluate(state)

  return {
    path = path,
    to = to,
    captured = move.captures,
    crowned = crowned,
    notation = pathName(path, #move.captures > 0 and "x" or "-"),
  }
end

--- Every move the side to move has, taking where taking is compulsory, in order
--- @param state CheckersState
--- @return string[]
local function moves(state)
  local list = {}
  for move in pairs(state.legal) do
    list[#list + 1] = move
  end
  table.sort(list)
  return list
end

-----------------------------
-- The computer
-----------------------------
-- It counts pieces first, a king for more than a man, and a man for a little more the further
-- it has come. Men left on the back row keep the other side from being crowned, and pieces in
-- the middle of the board have more to go to. Ahead, it is glad to trade pieces off: three
-- against two is better than four against three, and the fewer there are the more the one
-- left over counts. It never stops looking in the middle of taking, where the next jump may
-- take everything back.

local MAN, KING = 100, 160
-- What each row a man has come forward is worth, a man on its own back row, and a piece in one
-- of the middle squares
local ADVANCE, GUARD, MIDDLE = 3, 12, 6
local CENTRE = { [27] = true, [28] = true, [35] = true, [36] = true, [18] = true, [21] = true, [42] = true, [45] = true }

--- How well a seat stands
--- @param state CheckersState
--- @param seat number
--- @return number
local function standing(state, seat)
  local material, score = { 0, 0 }, 0
  for square, piece in pairs(state.board) do
    local owner, worth = ownerOf(piece), 0
    if isKing(piece) then
      worth = KING
    else
      -- Rows come forward from the owner's own side
      local row = math.floor(square / SIZE)
      local forward = owner == RED and row or SIZE - 1 - row
      worth = MAN + forward * ADVANCE + (forward == 0 and GUARD or 0)
    end
    if CENTRE[square] then
      worth = worth + MIDDLE
    end
    material[owner] = material[owner] + (isKing(piece) and KING or MAN)
    score = score + (owner == seat and worth or -worth)
  end
  -- Ahead, the fewer pieces there are the better
  local mine, theirs = material[seat], material[other(seat)]
  if mine ~= theirs then
    score = score + (mine - theirs) * 200 / (mine + theirs + 1)
  end
  return score
end

local COMPUTER = {
  evaluate = standing,
  priority = function(state, move)
    local made = state.legal[move]
    return made and #made.captures or 0
  end,
  noisy = function(state, move)
    local made = state.legal[move]
    return made ~= nil and #made.captures > 0
  end,
  -- How often it came up and, close to the forty moves, how close: the same pieces can be a draw
  -- one way and not another
  key = function(state)
    local placed = positionKey(state)
    return placed .. (state.positions[placed] or 0) .. (state.quiet >= QUIET_LIMIT - 10 and state.quiet or "")
  end,
  copy = function(state)
    local board = {}
    for square, piece in pairs(state.board) do
      board[square] = piece
    end
    -- Moves only ever add to how often a position came up, and work out the legal moves anew
    return {
      board = board,
      turn = state.turn,
      legal = state.legal,
      quiet = state.quiet,
      positions = private.Computer.Over(state.positions),
      free = state.free,
      last = state.last,
      outcome = state.outcome,
    }
  end,
  levels = {
    easy = { depth = 2, slip = 0.3, among = 3, quiet = 2 },
    medium = { depth = 4, budget = 3000, slip = 0.08 },
    hard = { depth = 20, budget = 15000 },
  },
}

-----------------------------
-- View
-----------------------------
-- Played on the shared board (GUI/Board.lua). What is checkers about it is in here: taking
-- several pieces in a move one jump at a time, pointing out the pieces that have to take, and
-- the count of what each side has taken.

local DISCS = { r = "red", R = "redK", w = "white", W = "whiteK" }
local LAST_MOVE = { 0.95, 0.85, 0.25, 0.4 }
local MUST_TAKE = { 0.9, 0.35, 0.15, 0.45 }
local TALLY_HEIGHT = 22
local TALLY_GAP = 4
local SOUNDS = { move = "chipsCollide", capture = "IG_BACKPACK_CLOSE" }

--- @param piece string
--- @param pixels number? Screen pixels it will be drawn at
--- @return string
local function textureFor(piece, pixels)
  return private.Board.Disc(DISCS[piece], pixels)
end

--- The legal moves that start out along these squares
--- @param state CheckersState
--- @param path number[]
--- @return CheckersMove[]
local function continuing(state, path)
  local moves = {}
  for _, move in pairs(state.legal) do
    local matches = #move.path >= #path
    for index, square in ipairs(path) do
      matches = matches and move.path[index] == square
    end
    if matches then
      moves[#moves + 1] = move
    end
  end
  return moves
end

--- @class CheckersView: GameViewObject
--- @field board Board
--- @field tallies Frame[] What the opponent took above the board, what the player took below
--- @field view GameView? What was last asked for
--- @field walked number[]? Squares a piece has jumped along so far in a move that isn't finished
--- @field dropped boolean? The move being played was dragged, so the piece is already there
local View = {}
View.__index = View

--- @param stage Frame
--- @return CheckersView
local function createView(stage)
  --- @type CheckersView
  local self = setmetatable({}, View)
  local Board = private.Board

  self.board = Board.New(stage, { columns = SIZE, rows = SIZE })
  self.board.frame:SetPoint("CENTER")
  self.board:SetInput({
    pickable = function(square)
      if self.walked then
        -- Halfway through a move only the piece that is making it can go on
        return square == self.walked[#self.walked]
      end
      return #continuing(self.view.state, { square }) > 0
    end,
    targets = function(square)
      local path = { unpack(self.walked or { square }) }
      local targets = {}
      for _, move in ipairs(continuing(self.view.state, path)) do
        targets[move.path[#path + 1]] = true
      end
      return targets
    end,
    onMove = function(from, to, dropped)
      self:play(from, to, dropped)
    end,
    onCancel = function()
      if self.walked then
        self.walked = nil
        self:draw()
      end
    end,
  })

  self.tallies = { Board.Tally(stage, TALLY_HEIGHT), Board.Tally(stage, TALLY_HEIGHT) }
  self.tallies[1]:SetPoint("BOTTOMLEFT", self.board.frame, "TOPLEFT", 0, TALLY_GAP)
  self.tallies[2]:SetPoint("TOPLEFT", self.board.frame, "BOTTOMLEFT", 0, -TALLY_GAP)
  return self
end

--- The piece in hand was put on a square it can go to
--- @param from number
--- @param to number
--- @param dropped boolean
function View:play(from, to, dropped)
  local board = self.board
  local path = { unpack(self.walked or { from }) }
  path[#path + 1] = to

  local moves = continuing(self.view.state, path)
  if #moves == 0 then
    return
  end
  if #moves == 1 and #moves[1].path == #path then
    self.dropped = dropped
    self.walked = path
    self.view.submit(pathName(path, "-"))
    self.dropped, self.walked = nil, nil
    return
  end

  -- There are more jumps to make: stand the piece where it has got to and keep it in hand
  self.walked = path
  self:draw()
  if not dropped then
    board:Glide(to, path[#path - 1])
  end
  board:Select(to)
end

--- @param width number
--- @param height number
function View:Layout(width, height)
  local board = self.board
  board:SetSize(math.min(width, height - 2 * (TALLY_HEIGHT + TALLY_GAP)))
  for _, tally in ipairs(self.tallies) do
    tally:SetWidth(board.cell * SIZE)
  end
end

--- Puts the current position on the board
function View:draw()
  local view = self.view
  --- @type CheckersState
  local state = view.state
  local board, walked = self.board, self.walked

  local pieces, left = {}, { 0, 0 }
  for square, piece in pairs(state.board) do
    pieces[square] = piece
    left[ownerOf(piece)] = left[ownerOf(piece)] + 1
  end
  if walked then
    -- A move in the making: the piece stands where it has jumped to, without what it jumped
    local piece = pieces[walked[1]]
    for index = 2, #walked do
      pieces[(walked[index - 1] + walked[index]) / 2] = nil
    end
    -- In this order: a king can jump its way back to where it set out from
    pieces[walked[1]] = nil
    pieces[walked[#walked]] = piece
  end
  board:SetPieces(pieces, textureFor)

  local tints = {}
  if state.last then
    tints[state.last.path[1]], tints[state.last.path[#state.last.path]] = LAST_MOVE, LAST_MOVE
  end
  if view.canMove and not walked and not state.free then
    -- Taking is compulsory, show which pieces that leaves to move
    for _, move in pairs(state.legal) do
      if #move.captures > 0 then
        tints[move.path[1]] = MUST_TAKE
      end
    end
  end
  board:SetTints(tints)

  for index, seat in ipairs({ other(view.seat), view.seat }) do
    local taken = 12 - left[other(seat)]
    local tally = self.tallies[index]
    tally:Set(textureFor(seat == RED and "w" or "r", TALLY_HEIGHT), "x " .. taken)
    tally:SetShown(taken > 0)
  end
end

--- @param view GameView
function View:Update(view)
  local walked = self.walked
  self.view = view

  local board = self.board
  if view.changed then
    -- What was picked up or being jumped belonged to the position that was showing
    self.walked = nil
    board:Select(nil)
    board:StopGlides()
  end
  if not view.canMove then
    self.walked = nil
  end
  -- Each player sees their own pieces at the bottom
  board:SetFlipped(view.seat == WHITE)
  board:SetEnabled(view.canMove)
  self:draw()

  --- @type CheckersEvent?
  local event = view.played
  if event then
    if not self.dropped then
      -- A piece the player jumped along themselves is already most of the way there
      local path, via = event.path, {}
      local start = walked and event.seat == view.seat and #walked - 1 or 1
      for index = start + 1, #path - 1 do
        via[#via + 1] = path[index]
      end
      board:Glide(event.to, path[start], via)
    end
    private.Widgets.PlaySound(SOUNDS[#event.captured > 0 and "capture" or "move"])
  end
end

private.Games.Register({
  id = "checkers",
  name = L["game_checkers"],
  description = L["game_checkers_description"],
  genre = "strategy",
  icon = "Interface\\AddOns\\ForeverGames\\Images\\Icons\\checkers",
  version = 1,
  seats = 2,
  draws = true,
  history = true,
  options = {
    { id = "forced", name = L["checkers_option_forced"], description = L["checkers_option_forced_tip"], default = true },
  },
  howto = {
    { heading = L["howto_goal"], text = L["checkers_howto_goal"] },
    { heading = L["howto_turn"], text = L["checkers_howto_turn"] },
    {
      heading = L["checkers_howto_taking"],
      text = function(rules)
        return L[rules.forced and "checkers_howto_taking_forced" or "checkers_howto_taking_free"]
      end,
    },
    { heading = L["checkers_howto_kings"], text = L["checkers_howto_kings_text"] },
    { heading = L["howto_end"], text = L["checkers_howto_end"] },
  },
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
    return seat == RED and L["checkers_red"] or L["checkers_white"]
  end,
})
