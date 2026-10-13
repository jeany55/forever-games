--------------------------
--  Chinese Checkers
--------------------------
-- For two, three, four or six players on a star with six points. Everyone starts with ten
-- marbles in a point and races them into the point straight across. A marble steps into an
-- empty hole next to it, or hops over a marble next to it, anyone's, into the empty hole behind,
-- and may go on hopping from there for as long as there is something to hop over. Nothing is
-- ever taken. A marble that has reached the point it is headed for stays in it.
--
-- Whoever fills the point across from them first wins. A hole there that someone else's marble
-- sits in counts as filled, so nobody can stop a player winning by leaving a marble at home.
-- The marbles of a player who resigns come off the board.
--
-- Holes are numbered 1 to 121, row by row from the top and left to right, as the first player
-- sees the board with their own point at the bottom. A move is where a marble sets out from and
-- where it ends up, "112-96": which way it hopped to get there doesn't matter.
--
-- Underneath, a hole is at (x, z) on a grid of three axes: z counts rows downwards and x runs
-- along them, the third axis is y = -x - z. The star is two triangles laid over each other, and
-- its six points are where one of the three is more than RADIUS away from the middle.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L

-- Of the hexagon in the middle of the star. The points are this many rows deep
local RADIUS = 4
local STEPS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, -1 }, { -1, 1 } }
-- Which points are played from, going round the board from the first player's, by how many play.
-- The point across from point n is n + 3.
local POINTS = { [2] = { 0, 3 }, [3] = { 0, 2, 4 }, [4] = { 0, 1, 3, 4 }, [6] = { 0, 1, 2, 3, 4, 5 } }
-- The colour that is played from each point
local COLORS = { [0] = "red", "yellow", "green", "blue", "white", "purple" }

--- @class ChineseCheckersState
--- @field seats number How many are playing
--- @field points number[] The point each seat starts from
--- @field board table<number, number> Seat of the marble in each hole
--- @field turn number
--- @field out table<number, boolean> Seats that resigned
--- @field last { from: number, to: number }? The move that led here
--- @field outcome { winner: number, detail: string? }?

--- @class ChineseCheckersEvent: MatchEvent
--- @field from number
--- @field to number
--- @field path number[] Every hole the marble stood in, from first to last

-----------------------------
-- The star
-----------------------------

--- @type { x: number, z: number }[]
local holes = {}
-- Hole number by where it is
local numbers = {}
-- The holes next to each hole, by direction. Not every direction leads somewhere
--- @type table<number, number>[]
local neighbours = {}
-- Which point a hole is in, nil in the middle
--- @type table<number, number>
local pointOf = {}
-- The holes of each point
--- @type table<number, number[]>
local pointHoles = {}

--- @param x number
--- @param z number
--- @return number
local function key(x, z)
  return (x + 2 * RADIUS) * (4 * RADIUS + 1) + z + 2 * RADIUS
end

for z = -2 * RADIUS, 2 * RADIUS do
  for x = -2 * RADIUS, 2 * RADIUS do
    local y = -x - z
    local low, high = math.min(x, y, z), math.max(x, y, z)
    if low >= -RADIUS or high <= RADIUS then
      holes[#holes + 1] = { x = x, z = z }
      numbers[key(x, z)] = #holes

      local point
      if z > RADIUS then
        point = 0
      elseif x < -RADIUS then
        point = 1
      elseif y > RADIUS then
        point = 2
      elseif z < -RADIUS then
        point = 3
      elseif x > RADIUS then
        point = 4
      elseif y < -RADIUS then
        point = 5
      end
      if point then
        pointOf[#holes] = point
        pointHoles[point] = pointHoles[point] or {}
        table.insert(pointHoles[point], #holes)
      end
    end
  end
end
for number, hole in ipairs(holes) do
  neighbours[number] = {}
  for direction, step in ipairs(STEPS) do
    neighbours[number][direction] = numbers[key(hole.x + step[1], hole.z + step[2])]
  end
end

-----------------------------
-- Rules
-----------------------------

--- The point a seat's marbles are headed for
--- @param state ChineseCheckersState
--- @param seat number
--- @return number
local function goalOf(state, seat)
  return (state.points[seat] + 3) % 6
end

--- Everywhere the marble in a hole may go, with the holes it passes through to get there
--- @param state ChineseCheckersState
--- @param from number
--- @return table<number, number[]> paths By where it ends up, each starting with `from`
local function reachable(state, from)
  local board = state.board
  local paths = { [from] = { from } }

  -- Hop by hop, nearest first, so every hole is reached the shortest way there is
  local queue, head = { from }, 1
  while queue[head] do
    local at = queue[head]
    head = head + 1
    for direction = 1, #STEPS do
      local over = neighbours[at][direction]
      local to = over and neighbours[over][direction]
      -- The marble isn't in the hole it set out from any more, there is nothing there to hop over
      if to and over ~= from and board[over] and not board[to] and not paths[to] then
        local path = { unpack(paths[at]) }
        path[#path + 1] = to
        paths[to] = path
        queue[#queue + 1] = to
      end
    end
  end
  paths[from] = nil

  for direction = 1, #STEPS do
    local to = neighbours[from][direction]
    if to and not board[to] then
      paths[to] = { from, to }
    end
  end

  -- Once it has arrived it doesn't leave again
  local goal = goalOf(state, board[from])
  if pointOf[from] == goal then
    for to in pairs(paths) do
      if pointOf[to] ~= goal then
        paths[to] = nil
      end
    end
  end
  return paths
end

--- @param state ChineseCheckersState
--- @param seat number
--- @return boolean
local function canMove(state, seat)
  for hole, owner in pairs(state.board) do
    if owner == seat and next(reachable(state, hole)) then
      return true
    end
  end
  return false
end

--- Whether the point a seat is headed for is full, with a marble of theirs in it
--- @param state ChineseCheckersState
--- @param seat number
--- @return boolean
local function hasArrived(state, seat)
  local own = false
  for _, hole in ipairs(pointHoles[goalOf(state, seat)]) do
    local owner = state.board[hole]
    if not owner then
      return false
    end
    own = own or owner == seat
  end
  return own
end

--- Hands the turn to the next player who is still in the game and has somewhere to go
--- @param state ChineseCheckersState
local function pass(state)
  local seat = state.turn
  for _ = 1, state.seats do
    seat = seat % state.seats + 1
    if not state.out[seat] and canMove(state, seat) then
      state.turn = seat
      return
    end
  end
  -- Nobody can move at all. It takes some doing, but the board could be jammed solid
  state.outcome = { winner = 0, detail = "blocked" }
end

--- @param seats number
--- @return ChineseCheckersState
local function newState(seats)
  --- @type ChineseCheckersState
  local state = { seats = seats, points = POINTS[seats], board = {}, turn = 1, out = {} }
  for seat, point in ipairs(state.points) do
    for _, hole in ipairs(pointHoles[point]) do
      state.board[hole] = seat
    end
  end
  return state
end

--- @param move string
--- @return number? from, number? to
local function parse(move)
  local from, to = move:match("^(%d+)%-(%d+)$")
  return tonumber(from), tonumber(to)
end

--- @param state ChineseCheckersState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  if seat ~= state.turn then
    return false, "not_your_turn"
  end
  local from, to = parse(move)
  if not from or state.board[from] ~= seat or not reachable(state, from)[to] then
    return false, "invalid_move"
  end
  return true
end

--- @param state ChineseCheckersState
--- @param seat number
--- @param move string
--- @return ChineseCheckersEvent
local function apply(state, seat, move)
  local from, to = parse(move)
  local path = reachable(state, from)[to]
  state.board[from], state.board[to] = nil, seat
  state.last = { from = from, to = to }

  -- A marble can fill the last hole of a point someone else is headed for. Whoever moved comes
  -- first, should it ever be both
  for offset = 0, state.seats - 1 do
    local other = (seat + offset - 1) % state.seats + 1
    if not state.outcome and not state.out[other] and hasArrived(state, other) then
      state.outcome = { winner = other }
    end
  end
  if not state.outcome then
    pass(state)
  end
  return { from = from, to = to, path = path, notation = move }
end

--- A player resigned: their marbles come off the board
--- @param state ChineseCheckersState
--- @param seat number
local function drop(state, seat)
  state.out[seat] = true
  for hole, owner in pairs(state.board) do
    if owner == seat then
      state.board[hole] = nil
    end
  end
  if state.turn == seat then
    pass(state)
  end
end

--- @param seat number
--- @param seats number
--- @return string
local function colorOf(seat, seats)
  return COLORS[POINTS[seats][seat]]
end

-----------------------------
-- View
-----------------------------
-- The star is a board with a layout (GUI/Board.lua): the holes are where this file says, and
-- it is turned so that every player sees their own point at the bottom. Next to it is a list of
-- who plays which colour, with whoever is to move lit up.

local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\Board\\"
-- How far the points of the star reach from the middle, in holes, and how much of its picture
-- the star takes up (Tools/make_discs.py)
local STAR_REACH, STAR_FILLS = 8.6, 0.97
-- Rows are closer together than the holes in them
local ROW = math.sqrt(3) / 2
local HOLE = { texture = IMAGES .. "disc", color = { 0.2, 0.12, 0.06 }, scale = 0.62 }
-- How much of a player's colour the holes of their point take on
local POINT_SHADE = 0.55
local RGB = {
  red = { 0.78, 0.16, 0.14 },
  yellow = { 0.94, 0.77, 0.16 },
  green = { 0.2, 0.63, 0.27 },
  blue = { 0.19, 0.41, 0.82 },
  white = { 0.93, 0.91, 0.86 },
  purple = { 0.57, 0.28, 0.75 },
}
local LAST_MOVE = { 1, 0.95, 0.6, 0.5 }
local LEGEND_HEIGHT, LEGEND_GAP = 20, 4
local MOVE_SOUND = "IG_ABILITY_ICON_DROP"

--- Where a hole is on a board that has been turned so a point is at the bottom
--- @param hole number
--- @param point number The point at the bottom
--- @return number x, number y In holes, right and down from the top left corner of the board
local function spotOf(hole, point)
  local x, z = holes[hole].x, holes[hole].z
  for _ = 1, point do
    -- A sixth of the way round
    x, z = x + z, -x
  end
  return STAR_REACH * ROW + x + z / 2, STAR_REACH + z * ROW
end

--- @param color string
--- @param pixels number? Screen pixels it will be drawn at
--- @return string
local function textureFor(color, pixels)
  return private.Board.Disc(color, pixels)
end

--- @class ChineseCheckersView: GameViewObject
--- @field board Board
--- @field legend Frame[] One line per seat
--- @field view GameView? What was last asked for
--- @field dropped boolean? The move being played was dragged, so the marble is already there
local View = {}
View.__index = View

--- @param stage Frame
--- @return ChineseCheckersView
local function createView(stage)
  --- @type ChineseCheckersView
  local self = setmetatable({}, View)
  local Board = private.Board

  local all = {}
  for hole = 1, #holes do
    all[hole] = hole
  end
  self.board = Board.New(stage, {
    layout = {
      squares = all,
      width = 2 * STAR_REACH * ROW,
      height = 2 * STAR_REACH,
      at = spotOf,
      backdrop = { texture = IMAGES .. "star", size = 2 * STAR_REACH / STAR_FILLS },
    },
    inlay = HOLE,
  })
  self.board.frame:SetPoint("CENTER")
  self.board:SetInput({
    pickable = function(hole)
      local state = self.view.state
      return state.board[hole] == self.view.seat and next(reachable(state, hole)) ~= nil
    end,
    targets = function(hole)
      return reachable(self.view.state, hole)
    end,
    onMove = function(from, to, dropped)
      self.dropped = dropped
      self.view.submit(from .. "-" .. to)
      self.dropped = nil
    end,
  })

  self.legend = {}
  for seat = 1, #POINTS[6] do
    local line = Board.Tally(stage, LEGEND_HEIGHT)
    line:SetPoint("TOPLEFT", 0, -(seat - 1) * (LEGEND_HEIGHT + LEGEND_GAP))
    line:SetWidth(160)
    self.legend[seat] = line
  end
  return self
end

--- @param width number
--- @param height number
function View:Layout(width, height)
  self.board:SetSize(width, height)
end

--- Puts the current position on the board
function View:draw()
  local view = self.view
  --- @type ChineseCheckersState
  local state = view.state
  local board = self.board

  local pieces = {}
  for hole, seat in pairs(state.board) do
    pieces[hole] = colorOf(seat, state.seats)
  end
  board:SetPieces(pieces, textureFor)

  -- The holes of a point show whose it is to start from
  local inlays = {}
  for seat, point in ipairs(state.points) do
    local rgb = RGB[COLORS[point]]
    local shade = {}
    for index = 1, 3 do
      shade[index] = HOLE.color[index] + (rgb[index] - HOLE.color[index]) * POINT_SHADE
    end
    for _, hole in ipairs(state.out[seat] and {} or pointHoles[point]) do
      inlays[hole] = shade
    end
  end
  board:SetInlays(inlays)

  local tints = {}
  if state.last then
    tints[state.last.from], tints[state.last.to] = LAST_MOVE, LAST_MOVE
  end
  board:SetTints(tints)

  local turn = not state.outcome and view.live and view.match.status == "active" and state.turn or nil
  for seat, line in ipairs(self.legend) do
    line:SetShown(seat <= state.seats)
    if seat <= state.seats then
      local name = seat == view.seat and L["chinesecheckers_you"] or view.names[seat]
      local text = state.out[seat] and L["chinesecheckers_out"]:format(name) or name
      line:Set(textureFor(colorOf(seat, state.seats), LEGEND_HEIGHT), text)
      if state.out[seat] then
        line.label:SetTextColor(0.45, 0.45, 0.45)
      elseif seat == turn then
        line.label:SetTextColor(unpack(private.Widgets.GOLD))
      else
        line.label:SetTextColor(0.85, 0.85, 0.85)
      end
    end
  end
end

--- @param view GameView
function View:Update(view)
  self.view = view
  local board = self.board
  if view.changed then
    -- What was picked up belonged to the position that was showing
    board:Select(nil)
    board:StopGlides()
  end
  -- Everyone sees their own point at the bottom
  board:SetFacing(view.state.points[view.seat])
  board:SetEnabled(view.canMove)
  self:draw()

  --- @type ChineseCheckersEvent?
  local event = view.played
  if event then
    if not self.dropped then
      local via = {}
      for index = 2, #event.path - 1 do
        via[#via + 1] = event.path[index]
      end
      board:Glide(event.to, event.from, via)
    end
    private.Widgets.PlaySound(MOVE_SOUND)
  end
end

private.Games.Register({
  id = "chinesecheckers",
  name = L["game_chinesecheckers"],
  description = L["game_chinesecheckers_description"],
  genre = "strategy",
  icon = "Interface\\AddOns\\ForeverGames\\Images\\Icons\\chinesecheckers",
  version = 1,
  seats = { 2, 3, 4, 6 },
  newState = newState,
  turn = function(state)
    return state.turn
  end,
  validate = validate,
  apply = apply,
  result = function(state)
    return state.outcome
  end,
  drop = drop,
  createView = createView,
  seatLabel = function(seat, seats)
    return L["chinesecheckers_" .. colorOf(seat, seats)]
  end,
})
