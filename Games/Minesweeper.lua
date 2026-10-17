--------------------------
--  Minesweeper
--------------------------
-- A field of covered squares with mines under some of them, for one player. Opening a square
-- that has no mine shows how many of the squares touching it do, and one that touches none
-- opens everything around it as well, and so on outward. The game is won when every square
-- without a mine is open, and lost by opening one that has one.
--
-- Whoever sets a game up picks how hard it is (`level`): nine by nine squares with ten mines,
-- sixteen by sixteen with forty, or thirty by sixteen with ninety-nine.
--
-- The first square opened is never a mine and never touches one, so the game always begins
-- with a patch of the field open. That takes the mines being laid only then, around wherever
-- the player began: until the first square is opened the state holds none at all.
--
-- A square the player thinks is mined can be flagged, which also keeps it from being opened by
-- mistake. Once a number has as many flags around it as it says, the rest of what touches it
-- can be opened in one go, a chord. That takes the flags at their word: one planted on the
-- wrong square and it opens a mine. A game that is won gets the mines left over flagged for it.
--
-- Squares are numbered row by row from the bottom left, starting at 0, the way GUI/Board.lua
-- numbers them. A move is a letter and a square: "r40" opens (reveals) square 40, "f40" plants
-- a flag on it or takes the one there away, and "c40" is a chord on the number at 40.
--
-- There is no taking a move back, a mine that went off stays gone off. The engine keeps the
-- time (`clock`) from the first move, and the fastest win at each level is kept as the record
-- (`record`), under the level's name.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Grid = private.Grid

local REVEAL, FLAG, CHORD = "r", "f", "c"
-- How big the field is and how many mines lie in it, by how hard that is
local LEVELS = {
  beginner = { columns = 9, rows = 9, mines = 10 },
  intermediate = { columns = 16, rows = 16, mines = 40 },
  expert = { columns = 30, rows = 16, mines = 99 },
}
local LEVEL_NAMES = { "beginner", "intermediate", "expert" }

--- @type GameOption[]
local OPTIONS = {
  {
    id = "level",
    name = L["minesweeper_option_level"],
    description = L["minesweeper_option_level_tip"],
    choices = LEVEL_NAMES,
    default = "beginner",
    label = function(value)
      return L["minesweeper_level_" .. value]
    end,
  },
}

--- @class MinesweeperState
--- @field level string Which of LEVELS it is played at
--- @field columns number
--- @field rows number
--- @field mines number How many there are, laid or not
--- @field laid boolean Whether the mines are in the field yet: they aren't until the first square is opened
--- @field mine table<number, boolean> The squares with a mine under them
--- @field open table<number, number> The squares that are open, and how many mines touch each
--- @field flag table<number, boolean> The squares with a flag on them
--- @field opened number How many squares are open
--- @field flags number How many flags are planted
--- @field moves number How many the player has made
--- @field hit number? The mine that was opened, in a game that was lost
--- @field outcome { winner: number }?

--- @class MinesweeperEvent: MatchEvent
--- @field action string What kind of move it was: REVEAL, FLAG or CHORD
--- @field square number The square it was made on
--- @field planted boolean? For a flag: whether it was planted, false for one taken away
--- @field laid boolean? The mines were laid for this move, it was the first to open anything
--- @field opened number[]? The squares it opened, in the order the opening spread to them
--- @field depths number[]? For each of those, how many steps from where the move was made it took to get there
--- @field exploded number? The mine it opened, which lost the game
--- @field mines number[]? In a game that was lost: every other mine nobody had flagged, nearest the one that went off first
--- @field reach number[]? For each of those, how many squares away it is
--- @field wrong number[]? In a game that was lost: the flags that were on squares without a mine
--- @field won boolean? It opened the last square without a mine
--- @field swept number[]? In a game that was won: the mines that were flagged for the player, nearest the move first

-----------------------------
-- Rules
-----------------------------

--- The squares that touch a square, up to eight of them
--- @param state MinesweeperState
--- @param square number
--- @return number[]
local function around(state, square)
  return Grid.New(state.columns, state.rows):Around(square, Grid.AROUND)
end

--- How many squares apart two squares are, going diagonally where that is shorter
--- @param state MinesweeperState
--- @param from number
--- @param to number
--- @return number
local function distance(state, from, to)
  return Grid.New(state.columns, state.rows):Distance(from, to)
end

--- Puts squares in the order of how far they are from one, the nearest first
--- @param state MinesweeperState
--- @param squares number[] Sorted in place
--- @param from number
--- @return number[] squares, number[] reach How far each of them is
local function outward(state, squares, from)
  table.sort(squares, function(a, b)
    local reachA, reachB = distance(state, from, a), distance(state, from, b)
    if reachA ~= reachB then
      return reachA < reachB
    end
    return a < b
  end)
  local reach = {}
  for index, square in ipairs(squares) do
    reach[index] = distance(state, from, square)
  end
  return squares, reach
end

--- @param seats number
--- @param random Random
--- @param rules table<string, any>? The usual ones if left out
--- @return MinesweeperState
local function newState(_, _, rules)
  rules = rules or private.Games.Rules(OPTIONS)
  local level = LEVELS[rules.level]
  --- @type MinesweeperState
  return {
    level = rules.level,
    columns = level.columns,
    rows = level.rows,
    mines = level.mines,
    laid = false,
    mine = {},
    open = {},
    flag = {},
    opened = 0,
    flags = 0,
    moves = 0,
  }
end

--- Whether a square can be opened: it is neither open nor flagged
--- @param state MinesweeperState
--- @param square number
--- @return boolean
local function canReveal(state, square)
  return state.open[square] == nil and not state.flag[square]
end

--- Whether a square can be flagged, or have its flag taken away: it isn't open
--- @param state MinesweeperState
--- @param square number
--- @return boolean
local function canFlag(state, square)
  return state.open[square] == nil
end

--- What a chord on a square would open: the squares touching it that are neither open nor flagged
--- @param state MinesweeperState
--- @param square number
--- @return number[] covered, number flags How many flags touch it
local function chordOf(state, square)
  local covered, flags = {}, 0
  for _, other in ipairs(around(state, square)) do
    if state.flag[other] then
      flags = flags + 1
    elseif state.open[other] == nil then
      covered[#covered + 1] = other
    end
  end
  return covered, flags
end

--- Whether a chord can be made on a square: it is an open number with exactly that many flags
--- around it, and something left to open
--- @param state MinesweeperState
--- @param square number
--- @return boolean
local function canChord(state, square)
  local number = state.open[square]
  if not number or number == 0 then
    return false
  end
  -- Counted rather than listed: the view asks this of every square, over and over
  local covered, flags = 0, 0
  for _, other in ipairs(around(state, square)) do
    if state.flag[other] then
      flags = flags + 1
    elseif state.open[other] == nil then
      covered = covered + 1
    end
  end
  return flags == number and covered > 0
end

--- @param state MinesweeperState
--- @param move string
--- @return string? kind, number? square nil for anything that isn't a move written the one way it is written
local function read(state, move)
  local kind, digits = move:match("^([rfc])(%d+)$")
  local square = tonumber(digits)
  if not kind or tostring(square) ~= digits or square >= state.columns * state.rows then
    return nil
  end
  return kind, square
end

--- @param state MinesweeperState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  if seat ~= 1 then
    return false, "not_your_turn"
  end
  local kind, square = read(state, move)
  local allowed = false
  if kind and not state.outcome then
    if kind == REVEAL then
      allowed = canReveal(state, square)
    elseif kind == FLAG then
      allowed = canFlag(state, square)
    else
      allowed = canChord(state, square)
    end
  end
  if not allowed then
    return false, "invalid_move"
  end
  return true
end

--- Every move there is: opening or flagging any square that isn't open, and a chord on every
--- number that has its flags
--- @param state MinesweeperState
--- @return string[]
local function moves(state)
  local list = {}
  for square = 0, state.columns * state.rows - 1 do
    if canReveal(state, square) then
      list[#list + 1] = REVEAL .. square
    end
    if canFlag(state, square) then
      list[#list + 1] = FLAG .. square
    end
    if canChord(state, square) then
      list[#list + 1] = CHORD .. square
    end
  end
  return list
end

--- Lays the mines, anywhere but on the square the player began with and the ones touching it
--- @param state MinesweeperState
--- @param square number
--- @param random Random
local function lay(state, square, random)
  local spared = { [square] = true }
  for _, other in ipairs(around(state, square)) do
    spared[other] = true
  end
  local free = {}
  for candidate = 0, state.columns * state.rows - 1 do
    if not spared[candidate] then
      free[#free + 1] = candidate
    end
  end
  random:Shuffle(free)
  for index = 1, state.mines do
    state.mine[free[index]] = true
  end
  state.laid = true
end

--- @param state MinesweeperState
--- @param square number
--- @return number How many mines touch a square
local function count(state, square)
  local mines = 0
  for _, other in ipairs(around(state, square)) do
    mines = mines + (state.mine[other] and 1 or 0)
  end
  return mines
end

--- Opens squares that have no mine, and from every one that touches none everything around it,
--- a step further out each time. A flag is left standing, whatever it stands on
--- @param state MinesweeperState
--- @param seeds number[] Where to begin
--- @param depth number How many steps from the move those are
--- @param event MinesweeperEvent Told what was opened, in the order it was
local function open(state, seeds, depth, event)
  local opened, depths = event.opened, event.depths
  Grid.Spread(seeds, function(square, steps)
    local touching = count(state, square)
    state.open[square] = touching
    state.opened = state.opened + 1
    opened[#opened + 1], depths[#depths + 1] = square, steps
    if touching > 0 then
      return nil
    end
    local onward = {}
    for _, other in ipairs(around(state, square)) do
      if canReveal(state, other) then
        onward[#onward + 1] = other
      end
    end
    return onward
  end, depth)
end

--- @param state MinesweeperState
--- @param seat number
--- @param move string
--- @param random Random
--- @return MinesweeperEvent
local function apply(state, _, move, random)
  local kind, square = read(state, move)
  state.moves = state.moves + 1
  --- @type MinesweeperEvent
  local event = { action = kind, square = square }
  if kind == FLAG then
    event.planted = not state.flag[square]
    state.flag[square] = event.planted or nil
    state.flags = state.flags + (event.planted and 1 or -1)
    return event
  end

  local targets = { square }
  if kind == CHORD then
    targets = chordOf(state, square)
  elseif not state.laid then
    lay(state, square, random)
    event.laid = true
  end
  -- Whatever of it has no mine is opened either way, a chord can open a mine and other squares
  local safe = {}
  for _, target in ipairs(targets) do
    if state.mine[target] then
      event.exploded = event.exploded or target
    else
      safe[#safe + 1] = target
    end
  end
  event.opened, event.depths = {}, {}
  open(state, safe, kind == CHORD and 1 or 0, event)

  local total = state.columns * state.rows
  if event.exploded then
    state.hit = event.exploded
    state.outcome = { winner = 0 }
    local mines, wrong = {}, {}
    for other = 0, total - 1 do
      if state.mine[other] and not state.flag[other] and other ~= state.hit then
        mines[#mines + 1] = other
      elseif state.flag[other] and not state.mine[other] then
        wrong[#wrong + 1] = other
      end
    end
    event.mines, event.reach = outward(state, mines, state.hit)
    event.wrong = outward(state, wrong, state.hit)
  elseif state.opened == total - state.mines then
    state.outcome = { winner = 1 }
    event.won = true
    -- Nothing is left covered but mines: they are flagged for the player
    local swept = {}
    for other = 0, total - 1 do
      if state.mine[other] and not state.flag[other] then
        state.flag[other] = true
        swept[#swept + 1] = other
      end
    end
    state.flags = state.mines
    event.swept = outward(state, swept, square)
  end
  return event
end

-----------------------------
-- View
-----------------------------
-- The field is a board (GUI/Board.lua), one for each size there is, made when a game of that
-- size is first looked at. An open square is a square of the board, sunk and dark, with its
-- number written on it. The raised tile on a square that isn't open is the board's inlay, shown
-- or not square by square, and a flag or a mine is the piece that stands on it.
--
-- A left click opens a square, a right click flags it. A left click on a number that has its
-- flags makes the chord, and so does the middle button. Whatever a click can't do says so: the
-- squares it was about light up red for a moment. Pointing at a number lights up the squares
-- around it that are still to be dealt with, green once the chord is there to be made.
--
-- What a move did is shown as it spreads: the squares it opened in a ripple outward from the
-- click, the mines of a lost game going off one after the other away from the one that was hit.
-- Until its turn in that comes, a square is held back the way it looked before the move (`held`).

local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\Minesweeper\\"
-- What stands on a square comes in these sizes, see Tools/make_minesweeper.py
local PIECE_SIZES = { 32, 64, 128 }
local SUNK, LINES = { 0.15, 0.165, 0.205 }, { 0.06, 0.07, 0.095 }
local NO_MARK = { 0, 0, 0, 0 }
-- The inlay of a square that is covered, and of one that isn't
local COVERED, OPENED = { 1, 1, 1, 1 }, { 1, 1, 1, 0 }
-- The colours the numbers have always had, as light as it takes to read them on a dark square
local NUMBER_COLORS = {
  { 0.42, 0.66, 1 },
  { 0.35, 0.84, 0.38 },
  { 1, 0.36, 0.33 },
  { 0.72, 0.5, 1 },
  { 0.95, 0.58, 0.24 },
  { 0.27, 0.86, 0.82 },
  { 0.95, 0.95, 0.95 },
  { 0.64, 0.64, 0.68 },
}
local NUMBER_SCALE = 0.68
-- The square of the mine that was opened
local CULPRIT = { 0.9, 0.1, 0.08, 0.85 }
-- Around a number that is pointed at: the squares still to be dealt with, and the same once a chord would open them
local HINT, READY = { 1, 1, 1, 0.16 }, { 0.3, 0.9, 0.3, 0.28 }
local RED = { 1, 0.3, 0.25 }
local REFUSED, REFUSED_ALPHA, REFUSED_SECONDS = { 1, 0.25, 0.2 }, 0.5, 0.3
local BLAST, BLAST_ALPHA = { 1, 0.62, 0.15 }, 0.7
local FLASH = { 1, 0.25, 0.1, 0.45 }
local JOLT = 9

-- Room kept around it all, and between the numbers on top and the field
local PAD, GAP = 4, 6
local HUD_HEIGHT = 38
local STAT_MIN, STAT_MAX = 72, 120
-- A square is never drawn bigger than this, however big the window
local CELL_MAX = 56

-- Seconds from one ring of a ripple to the next, how long a ripple takes at most however far it
-- goes, and how long a square takes to lose its cover once the ripple gets to it
local RING, RIPPLE_MAX, UNCOVER = 0.035, 0.7, 0.16
-- How bright the front of the ripple is
local RIPPLE_GLOW = 0.35
-- Seconds between the mine that was hit and the others, from one ring of those to the next, how
-- long they take at most, and how long the light of one going off lasts
local BLAST_PAUSE, CHAIN, CHAIN_MAX, BLAST_SECONDS = 0.25, 0.06, 0.9, 0.25
-- Seconds between one wrong flag turning over and the next
local WRONG_GAP = 0.06
-- Seconds between one mine being flagged for the player and the next, and how long that takes at most
local SWEEP, SWEEP_MAX = 0.05, 0.8
-- Seconds the words across a game that is over wait for what led to them to be seen
local WON_AFTER, LOST_AFTER = 0.5, 0.7
-- A ripple this big sounds like one
local FLOOD = 4
local REVEAL_SOUND, FLOOD_SOUND = "IG_MAINMENU_OPTION_CHECKBOX_ON", "cardSlide"
local FLAG_SOUND, UNFLAG_SOUND, REFUSED_SOUND = "chipsCollide", "IG_BACKPACK_CLOSE", "IG_MAINMENU_OPTION_CHECKBOX_OFF"
local BLAST_SOUNDS, WIN_SOUND = { "dieThrow", "IG_QUEST_FAILED" }, "IG_QUEST_LIST_COMPLETE"

--- @class MinesweeperView: GameViewObject
--- @field stage Frame
--- @field boards table<string, Board> The field of each level that has been looked at
--- @field board Board? The one that is shown
--- @field hud { mines: Frame, time: Frame, best: Frame } The numbers over the field
--- @field animator table Runs whatever a move is shown by
--- @field effects Effects
--- @field view GameView? What was last asked for
--- @field held table<number, boolean|string> Squares a move changed that are still shown as they were: covered, or with a "flag"
--- @field glow table<number, number[]> Squares lit up for a moment, and in what colour
--- @field over number? The square the cursor is on
local View = {}
View.__index = View

--- @param key string
--- @param pixels number Screen pixels a square is drawn at
--- @return string
local function pieceTexture(key, pixels)
  local best = PIECE_SIZES[#PIECE_SIZES]
  for index = #PIECE_SIZES, 1, -1 do
    if PIECE_SIZES[index] >= pixels * 0.85 then
      best = PIECE_SIZES[index]
    end
  end
  return IMAGES .. best .. "\\" .. key
end

--- @param list table
local function wipe(list)
  for key in pairs(list) do
    list[key] = nil
  end
end

--- @param stage Frame
--- @return MinesweeperView
local function createView(stage)
  local Widgets = private.Widgets
  --- @type MinesweeperView
  local self = setmetatable({ stage = stage, boards = {}, held = {}, glow = {}, width = 0, height = 0 }, View)
  self.covers, self.pieces, self.labels, self.inks, self.tints = {}, {}, {}, {}, {}

  self.hud = {
    mines = Widgets.Stat(stage, L["minesweeper_mines"], STAT_MAX, HUD_HEIGHT),
    time = Widgets.Stat(stage, L["stat_time"], STAT_MAX, HUD_HEIGHT),
    best = Widgets.Stat(stage, L["stat_best"], STAT_MAX, HUD_HEIGHT),
  }
  -- The clock goes on between one update and the next
  self.hud.time:SetScript("OnUpdate", function()
    self:tick()
  end)

  local ticker = CreateFrame("Frame", nil, stage)
  ticker:SetPoint("TOPLEFT")
  ticker:SetSize(1, 1)
  self.animator = Widgets.Animator(ticker)
  -- What was on its way when the stage was hidden has got there by the time it is shown again
  ticker:SetScript("OnHide", function()
    if self.view and self.board then
      self:settle()
      self:draw()
    end
  end)
  self.effects = private.Effects.New(stage)
  return self
end

-----------------------------
-- Layout
-----------------------------

--- The field for a position: every level has its own, they aren't the same shape
--- @param state MinesweeperState
--- @return Board
function View:fieldFor(state)
  local board = self.boards[state.level]
  if not board then
    board = private.Board.New(self.stage, {
      columns = state.columns,
      rows = state.rows,
      light = SUNK,
      dark = SUNK,
      lines = LINES,
      inlay = { texture = IMAGES .. "cover", color = COVERED, scale = 1 },
      mark = NO_MARK,
      labelScale = NUMBER_SCALE,
    })
    board.frame.board = board
    board.frame:Hide()
    board:SetInput({
      -- Every square a left click does something on, which the board then lights up under the cursor
      place = function(square)
        local position = self.view.state
        return (canReveal(position, square) or canChord(position, square)) and square or nil
      end,
      onPlace = function(square)
        self.view.submit((self.view.state.open[square] and CHORD or REVEAL) .. square)
      end,
      onRightClick = function(square)
        if canFlag(self.view.state, square) then
          self.view.submit(FLAG .. square)
        else
          self:refuse(square)
        end
      end,
      -- Whatever the board had no use for: a left click that does nothing, or another button
      onCancel = function(button)
        local square = self.over
        if not square then
          return
        elseif button == "MiddleButton" and canChord(self.view.state, square) then
          self.view.submit(CHORD .. square)
        else
          self:refuse(square)
        end
      end,
      onHover = function(square)
        self.over = square
        self:paint()
      end,
    })
    self.boards[state.level] = board
  end
  if board ~= self.board then
    if self.board then
      self.board.frame:Hide()
    end
    self.board, self.over = board, nil
    board.frame:Show()
    self:arrange()
  end
  return board
end

--- Puts the field in the middle of the room there is, as big as it goes, and the numbers over it
function View:arrange()
  local board, width, height = self.board, self.width, self.height
  if not board or width <= 0 then
    return
  end
  local roomWidth, roomHeight = width - 2 * PAD, height - 2 * PAD - HUD_HEIGHT - GAP
  board:SetSize(math.min(roomWidth, CELL_MAX * board.columns), math.min(roomHeight, CELL_MAX * board.rows))
  local fieldWidth, fieldHeight = board.cell * board.columns, board.cell * board.rows
  -- Whole numbers all the way, half a pixel would blur every square
  local top = math.max(0, math.floor((height - HUD_HEIGHT - GAP - fieldHeight) / 2))
  board.frame:ClearAllPoints()
  board.frame:SetPoint("TOPLEFT", self.stage, "TOPLEFT", math.floor((width - fieldWidth) / 2), -(top + HUD_HEIGHT + GAP))

  -- As wide as the field where three of them fit over it, and never wider than the room
  local widest = math.floor((roomWidth - 2 * GAP) / 3)
  local statWidth = math.max(1, math.min(widest, STAT_MAX, math.max(STAT_MIN, math.floor((fieldWidth - 2 * GAP) / 3))))
  local left = math.floor((width - 3 * statWidth - 2 * GAP) / 2)
  for index, stat in ipairs({ self.hud.mines, self.hud.time, self.hud.best }) do
    stat:SetSize(statWidth, HUD_HEIGHT)
    stat:ClearAllPoints()
    stat:SetPoint("TOPLEFT", self.stage, "TOPLEFT", left + (index - 1) * (statWidth + GAP), -top)
  end
end

--- @param width number
--- @param height number
function View:Layout(width, height)
  self.width, self.height = width, height
  self:arrange()
end

-----------------------------
-- Drawing
-----------------------------

--- Works out what every square looks like: the position, less whatever of the last move hasn't
--- been shown yet
function View:compose()
  --- @type MinesweeperState
  local state = self.view.state
  local held = self.held
  local lost = state.outcome ~= nil and state.outcome.winner == 0
  for square = 0, state.columns * state.rows - 1 do
    local cover, piece, label = COVERED, nil, nil
    local was = held[square]
    if was then
      piece = was == "flag" and "flag" or nil
    elseif state.open[square] then
      cover = OPENED
      label = state.open[square] > 0 and state.open[square] or nil
    elseif state.flag[square] then
      -- In a game that was lost a flag stays where it was right, and is crossed out where it wasn't
      piece = (lost and not state.mine[square]) and "wrong" or "flag"
    elseif lost and state.mine[square] then
      cover, piece = OPENED, "mine"
    end
    self.covers[square], self.pieces[square] = cover, piece
    self.labels[square], self.inks[square] = label, label and NUMBER_COLORS[label] or nil
  end
end

--- Colours squares: the mine that was hit, what a number that is pointed at is about, and
--- whatever is lit up for a moment
function View:paint()
  local view, board, tints = self.view, self.board, self.tints
  if not view or not board then
    return
  end
  --- @type MinesweeperState
  local state = view.state
  wipe(tints)
  if state.hit and not self.held[state.hit] then
    tints[state.hit] = CULPRIT
  end
  local over = self.over
  if over and view.canMove and (state.open[over] or 0) > 0 then
    local covered, flags = chordOf(state, over)
    for _, square in ipairs(covered) do
      tints[square] = flags == state.open[over] and READY or HINT
    end
  end
  for square, color in pairs(self.glow) do
    tints[square] = color
  end
  board:SetTints(tints)
end

--- Puts on the board what compose worked out
function View:show()
  local board = self.board
  board:SetInlays(self.covers)
  board:SetLabels(self.labels, self.inks)
  board:SetPieces(self.pieces, pieceTexture)
  self:paint()
end

--- The numbers over the field
function View:refreshHud()
  local view, Widgets = self.view, private.Widgets
  --- @type MinesweeperState
  local state = view.state
  self.hud.mines:Set(state.mines - state.flags)
  self:tick()
  local best, mine = view.best(state.level)
  -- Gold for one this very game set, which is also when it is worth drawing the eye to
  self.hud.best:Set(best and Widgets.Time(best) or L["stat_none"], not mine)
  self.hud.best:Tint(mine and Widgets.GOLD or nil)
end

--- Shows what the clock says by now
function View:tick()
  local view = self.view
  if not view then
    return
  end
  local seconds = math.floor(view.clock())
  if seconds ~= self.seconds then
    self.seconds = seconds
    self.hud.time:Set(private.Widgets.Time(seconds), true)
  end
end

--- Shows the position as it is, at once
function View:draw()
  self.board:SetEnabled(self.view.canMove)
  self:compose()
  self:show()
  self:refreshHud()
end

--- Takes whatever was being shown to its end. Whoever asks for that draws the position afterwards
function View:settle()
  -- What gets there this way does so without a sound, and without being drawn on the way
  self.rushed = true
  self.animator:Stop()
  self.rushed = false
  wipe(self.held)
  wipe(self.glow)
  if self.board then
    self.board:StopGlides()
  end
end

-----------------------------
-- Showing a move
-----------------------------

--- @param name string?
function View:sound(name)
  if not self.rushed then
    private.Widgets.PlaySound(name)
  end
end

--- Makes what stands on a square settle into it as if just put there
--- @param square number
function View:pop(square)
  if not self.rushed then
    self.board:Pop(square)
  end
end

--- Lights squares up in a colour that fades, on top of whatever else they are coloured
--- @param squares number[]
--- @param color number[]
--- @param alpha number How strong it starts out
--- @param seconds number
--- @param delay number?
function View:flare(squares, color, alpha, seconds, delay)
  local light = { color[1], color[2], color[3], alpha }
  self.animator:Play(seconds, function(progress)
    light[4] = alpha * (1 - progress)
    if not self.rushed then
      self:paint()
    end
  end, {
    delay = delay,
    onStart = function()
      for _, square in ipairs(squares) do
        self.glow[square] = light
      end
    end,
    onDone = function()
      for _, square in ipairs(squares) do
        if self.glow[square] == light then
          self.glow[square] = nil
        end
      end
      if not self.rushed then
        self:paint()
      end
    end,
  })
end

--- A click that can't do anything says so: the square lights up, and with it what a number
--- that hasn't got its flags is still waiting for
--- @param square number
function View:refuse(square)
  --- @type MinesweeperState
  local state = self.view.state
  local squares = { square }
  if (state.open[square] or 0) > 0 then
    for _, other in ipairs((chordOf(state, square))) do
      squares[#squares + 1] = other
    end
  end
  self:flare(squares, REFUSED, REFUSED_ALPHA, REFUSED_SECONDS)
  self:sound(REFUSED_SOUND)
end

--- Opens the squares a move opened a ring at a time, outward from where it was made
--- @param event MinesweeperEvent
--- @return number seconds How long that takes
function View:ripple(event)
  local opened, depths = event.opened or {}, event.depths
  if #opened == 0 then
    return 0
  end
  -- A chord begins a step out, on the squares around its number
  local first, last, rings = depths[1], depths[#depths], {}
  for index, square in ipairs(opened) do
    local ring = rings[depths[index] - first + 1]
    if not ring then
      ring = { squares = {}, cover = { 1, 1, 1, 1 }, light = { 1, 1, 1, 0 } }
      rings[depths[index] - first + 1] = ring
    end
    ring.squares[#ring.squares + 1] = square
    self.held[square] = true
  end

  local gap = math.min(RING, RIPPLE_MAX / math.max(1, last - first))
  local seconds = (#rings - 1) * gap + UNCOVER
  self.animator:Play(seconds, function(progress)
    local now = progress * seconds
    for index, ring in ipairs(rings) do
      -- How far along this ring is in losing its covers
      local along = progress >= 1 and 1 or (now - (index - 1) * gap) / UNCOVER
      if along > 0 and not ring.over then
        ring.over = along >= 1
        ring.cover[4], ring.light[4] = 1 - along, RIPPLE_GLOW * (1 - along)
        for _, square in ipairs(ring.squares) do
          self.held[square] = nil
          self.glow[square] = (not ring.over) and ring.light or nil
        end
      end
    end
    if self.rushed then
      return
    end
    self:compose()
    for _, ring in ipairs(rings) do
      if not ring.over and ring.cover[4] < 1 then
        for _, square in ipairs(ring.squares) do
          self.covers[square] = ring.cover
        end
      end
    end
    self:show()
  end)
  return seconds
end

--- Does something once its time has come in what a move is shown by
--- @param delay number
--- @param what fun()
function View:after(delay, what)
  self.animator:Play(0, function() end, { delay = delay, onStart = what })
end

--- Shows squares that were held back the way they are now
--- @param squares number[]
function View:release(squares)
  for _, square in ipairs(squares) do
    self.held[square] = nil
  end
  -- Rushed to its end, all of it is drawn at once afterwards
  if not self.rushed then
    self:compose()
    self:show()
  end
end

--- A mine was opened: it goes off, and then every other mine does, outward from it. After
--- that the flags that marked nothing are turned over
--- @param event MinesweeperEvent
--- @param delay number Seconds to wait first
--- @return number seconds Until all of it is over
function View:explode(event, delay)
  local hit = event.exploded
  self.held[hit] = true
  self:after(delay, function()
    self:release({ hit })
    self:pop(hit)
    if not self.rushed then
      self.effects:Flash(FLASH)
      self.effects:Jolt(self.board.frame, JOLT)
    end
    for _, name in ipairs(BLAST_SOUNDS) do
      self:sound(name)
    end
  end)
  self:flare({ hit }, BLAST, BLAST_ALPHA, BLAST_SECONDS, delay)

  -- The others a ring at a time: all that are as far away as each other go off together
  local rings = {}
  for index, square in ipairs(event.mines) do
    local ring = rings[#rings]
    if not ring or ring.reach ~= event.reach[index] then
      ring = { reach = event.reach[index] }
      rings[#rings + 1] = ring
    end
    ring[#ring + 1] = square
    self.held[square] = true
  end
  local gap = math.min(CHAIN, CHAIN_MAX / math.max(1, #rings))
  local at = delay + BLAST_PAUSE
  for _, ring in ipairs(rings) do
    self:after(at, function()
      self:release(ring)
      for _, square in ipairs(ring) do
        self:pop(square)
      end
    end)
    self:flare(ring, BLAST, BLAST_ALPHA, BLAST_SECONDS, at)
    at = at + gap
  end

  for _, square in ipairs(event.wrong) do
    self.held[square] = "flag"
  end
  if #event.wrong > 0 then
    self:after(at, function()
      self:release(event.wrong)
      for index, square in ipairs(event.wrong) do
        if not self.rushed then
          self.board:Flip(square, "flag", (index - 1) * WRONG_GAP)
        end
      end
    end)
  end
  return at + BLAST_SECONDS
end

--- The last square without a mine was opened: the mines nobody flagged get their flags, one
--- after the other
--- @param event MinesweeperEvent
--- @param delay number Seconds to wait first
function View:sweep(event, delay)
  local gap = math.min(SWEEP, SWEEP_MAX / math.max(1, #event.swept))
  for index, square in ipairs(event.swept) do
    self.held[square] = true
    self:after(delay + (index - 1) * gap, function()
      self:release({ square })
      self:pop(square)
    end)
  end
  self:after(delay, function()
    self:sound(WIN_SOUND)
  end)
end

--- Writes across the field how the game ended
--- @param delay number? Seconds to wait first
--- @param instant boolean? For a game that was over before it was looked at
function View:verdict(delay, instant)
  local view, Widgets = self.view, private.Widgets
  --- @type MinesweeperState
  local state = view.state
  if state.outcome.winner == 1 then
    local time = Widgets.Time(view.clock())
    local _, mine = view.best(state.level)
    local subtitle = L["minesweeper_cleared_in"]:format(time)
    if mine then
      subtitle = L["minesweeper_cleared_best"]:format(time, L["new_best"])
    end
    self.effects:Banner(L["minesweeper_won"], subtitle, { delay = delay, instant = instant })
  else
    local safe = state.columns * state.rows - state.mines
    local subtitle = L["minesweeper_cleared_some"]:format(state.opened, safe)
    self.effects:Banner(L["minesweeper_lost"], subtitle, { color = RED, delay = delay, instant = instant })
  end
end

--- Shows a move being made
--- @param event MinesweeperEvent
function View:play(event)
  local board = self.board
  board:SetEnabled(self.view.canMove)
  if event.action == FLAG then
    self:compose()
    self:show()
    if event.planted then
      board:Pop(event.square)
    end
    self:sound(event.planted and FLAG_SOUND or UNFLAG_SOUND)
  else
    self:sound(#event.opened >= FLOOD and FLOOD_SOUND or REVEAL_SOUND)
    local seconds = self:ripple(event)
    if event.exploded then
      self:verdict(self:explode(event, seconds) + LOST_AFTER)
    elseif event.won then
      self:sweep(event, seconds)
      self.effects:Confetti(seconds)
      self:verdict(seconds + WON_AFTER)
    end
    -- Everything the move changed is held back now, and shown as its turn comes
    self:compose()
    self:show()
  end
  self:refreshHud()
end

--- @param view GameView
function View:Update(view)
  local before = self.view
  local sameGame = before ~= nil and before.match.id == view.match.id
  --- @type MinesweeperEvent?
  local event = view.played

  if sameGame and not view.changed then
    -- Nothing new: whatever is being shown goes on being shown
    self.view = view
    self.board:SetEnabled(view.canMove)
    self:refreshHud()
    return
  end

  -- Whatever the last move was still being shown by is over with
  if self.view then
    self:settle()
  end
  self.view = view
  self.seconds = nil
  self:fieldFor(view.state)
  if sameGame and event then
    self:play(event)
  else
    -- Another game, or this one from somewhere else in it: there it is
    self.effects:Clear()
    self:draw()
    if view.state.outcome then
      self:verdict(nil, true)
    end
  end
end

private.Games.Register({
  id = "minesweeper",
  name = L["game_minesweeper"],
  description = L["game_minesweeper_description"],
  genre = "solo",
  icon = "Interface\\AddOns\\ForeverGames\\Images\\Icons\\minesweeper",
  version = 1,
  seats = 1,
  options = OPTIONS,
  howto = {
    { heading = L["howto_goal"], text = L["minesweeper_howto_goal"] },
    { heading = L["minesweeper_howto_numbers"], text = L["minesweeper_howto_numbers_text"] },
    { heading = L["howto_controls"], text = L["minesweeper_howto_controls"] },
    { heading = L["minesweeper_howto_chord"], text = L["minesweeper_howto_chord_text"] },
    { heading = L["howto_end"], text = L["minesweeper_howto_end"] },
  },
  clock = "move",
  newState = newState,
  turn = function()
    return 1
  end,
  validate = validate,
  apply = apply,
  moves = moves,
  result = function(state)
    return state.outcome
  end,
  progress = function(state)
    return L["minesweeper_progress"]:format(state.opened, state.columns * state.rows - state.mines, state.mines - state.flags)
  end,
  record = function(state, seconds)
    -- Only a field that was cleared has a time worth keeping
    if state.outcome and state.outcome.winner == 1 then
      return { { key = state.level, value = seconds, lower = true } }
    end
    return nil
  end,
  -- The day's field is a middling one, and only a field that was cleared has a time
  daily = {
    rules = { level = "intermediate" },
    score = function(state, seconds)
      return state.outcome and state.outcome.winner == 1 and seconds or nil
    end,
    lower = true,
    time = true,
  },
  createView = createView,
})
