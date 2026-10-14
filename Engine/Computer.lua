--------------------------
--  The computer
--------------------------
-- A game for two or more can be played against the computer, which takes whichever seats the
-- player doesn't. All it needs of a game is the moves there are (GameDefinition.moves): it looks
-- a few moves ahead through them, playing each one out on a copy of the position by the game's
-- own rules, and picks the one that leads somewhere best for it. With nothing else to go on it
-- judges where that leads by playing the game out from there at random a few times, which is
-- enough to make a beginner of it at anything. A game makes something better of it by saying
-- how good a position is (GameComputer.evaluate), and by pointing out which moves are worth
-- looking at first, which ones it can't stop looking after (a capture that might be taken
-- back), what a position is called so that it can tell one it has been to before, and a quicker
-- way of copying one. A game whose computer needs something else entirely thinks for itself
-- (GameComputer.think), with the help of everything in here.
--
-- How well it plays is how far ahead it looks and how often it slips (LEVELS). How far is
-- counted in positions looked at, never in seconds, so that it plays the same whatever it runs
-- on, and the same again from the same position: a game against it can be played out in the
-- tests and comes out the same every time. Seconds only say when it stops to let a frame by:
-- it thinks a little at a time (Thinker:Run), so the game client never stalls while it does.
--
-- It plays fair. In a game where players don't all know the same (GameDefinition.visible) it is
-- only ever shown what its own seat may see, and has to guess the rest (GameComputer.guess): it
-- plays what it holds against a few guesses at what the others do, and goes with whatever comes
-- out best over all of them. The dice it imagines are its own, it doesn't know how the match's
-- will fall either.
--
-- Only the move it decides on is kept, in the log like anyone's (Engine/Match.lua). Nothing it
-- works out on the way needs to come out the same anywhere else.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- What a game tells the computer about playing it. All of it can be left out: `computer = {}`
--- is a computer that plays the game, everything else makes it play it better or sooner
--- @class GameComputer
--- @field evaluate (fun(state: table, seat: number): number)? How well a seat stands in a position that isn't over: 0 when nobody is ahead, more the better they stand, less the worse. Keep it well under Computer.WIN, which is what a game that is won is worth
--- @field priority (fun(state: table, move: string, seat: number): number)? How promising a move looks before it is looked into, so that the better ones are looked at first: a capture of a queen before anything else. The higher the sooner
--- @field noisy (fun(state: table, move: string, seat: number): boolean)? A move after which a position can't be judged as it stands, as a capture that might be taken straight back: the computer looks on past the last move it meant to look at for as long as there are these
--- @field key (fun(state: table): string)? What a position is called, the same for the same position however it came about. The computer remembers what it found about each one and looks up the rest. Where how it came about matters to the rules, as a draw by repetition, that has to be in it too
--- @field copy (fun(state: table): table)? A copy of a position to play moves on, quicker than the engine's. What it shares with the original mustn't ever be changed by applying a move
--- @field guess (fun(state: table, seat: number, random: Random): table)? For a game with `visible`: a whole position that could be the one behind what a seat sees, with everything it can't see made up. Needed for the computer to look ahead in a game with something to hide
--- @field think (fun(state: table, seat: number, brain: Brain): string)? Decides on a move instead of the engine. Given what the seat may see, never the position itself, and the brain to think with: Brain:Search does what the engine would, Brain:Spend lets a frame by now and then
--- @field levels table<string, table>? What is different about each level for this game, by level: the fields of ComputerLevel that need to be. The budgets, more than anything: a position of one game can take a hundred times as long to look at as one of another
--- @field takeback boolean? Whether the player may take a move back. Yes, unless the game has something to hide (`visible`): there it would let the player see what the move turned up and try another. Say no where the dice would let them try their luck again
--- @field pause number? Seconds the computer looks as though it thinks at least, so that its move doesn't land on top of the one before. The engine's own if left out

--- How the computer plays at a level
--- @class ComputerLevel
--- @field budget number Positions it may look at for a move, those of the games it plays out at random included. It always finishes looking one move ahead, whatever this says
--- @field depth number Moves it looks ahead at most, everyone's counted
--- @field slip number How likely it is to play something other than what it thinks best, from 0 to 1
--- @field among number What it plays when it slips: any of so many of the best
--- @field careless boolean Whether it may slip into a move that loses on the spot
--- @field quiet number Moves it looks on past the last of `depth` at most, while they are `noisy`
--- @field samples number Guesses at what it can't see that it plays against, in a game with something to hide
--- @field playouts number Games it plays out at random from a position to judge it by, in a game that doesn't say how good a position is

--- @class Computer
local Computer = {}
private.Computer = Computer

-- What a position that is won is worth, from the seat that won it. A win sooner is worth a little
-- more than one later, a loss later a little more than one sooner
Computer.WIN = 1000000
-- From the easiest up
Computer.LEVELS = { "easy", "medium", "hard" }
Computer.DEFAULT_LEVEL = "medium"
-- Seconds it looks as though it thinks at least, unless the game says otherwise
Computer.PAUSE = 0.6

--- @type table<string, ComputerLevel>
local LEVELS = {
  easy = { budget = 400, depth = 2, slip = 0.35, among = 3, careless = true, quiet = 0, samples = 3, playouts = 4 },
  medium = { budget = 3000, depth = 4, slip = 0.1, among = 2, careless = false, quiet = 3, samples = 5, playouts = 8 },
  hard = { budget = 16000, depth = 12, slip = 0, among = 1, careless = false, quiet = 6, samples = 8, playouts = 16 },
}

-- Larger than any score
local INFINITE = math.huge
-- Scores this close count as the same when the best is looked for
local TIE = 1e-6
-- What a win is worth at least, however late it comes
local WON = Computer.WIN / 2
-- A game played out at random to judge a position by goes on for no more than this many moves.
-- What it comes to is scaled up to this, well under a win
local PLAYOUT_MOVES, PLAYOUT_SCALE = 200, 1000
-- How much work there is between looks at the clock
local CLOCK_EVERY = 4
-- What the computer remembers about a position: the best found for it, at least that, at most that
local EXACT, LOWER, UPPER = 1, 2, 3

-----------------------------
-- Copies
-----------------------------

--- @param value any
--- @param made table<table, table> Copies made so far, so that what is shared stays shared
--- @return any
local function copyOf(value, made)
  if type(value) ~= "table" then
    return value
  end
  local done = made[value]
  if done then
    return done
  end
  local result = {}
  made[value] = result
  for key, inner in pairs(value) do
    result[key] = copyOf(inner, made)
  end
  return setmetatable(result, getmetatable(value))
end

--- A copy of a position, down to its last table. What one part of it shares with another, the
--- copy shares in the same way
--- @param state table
--- @return table
function Computer.Copy(state)
  return copyOf(state, {})
end

--- A table that reads through to another: what is in it is its own, what isn't is the other's.
--- For a copy of something that moves only ever add to, such as how often each position came
--- up, which would otherwise have to be copied whole for every move looked at
--- @param under table
--- @return table
function Computer.Over(under)
  return setmetatable({}, { __index = under })
end

-----------------------------
-- Levels
-----------------------------

--- Whether a game can be played against the computer
--- @param game GameDefinition
--- @return boolean
function Computer.Plays(game)
  return game.computer ~= nil
end

--- @param level string?
--- @return boolean
function Computer.IsLevel(level)
  return LEVELS[level] ~= nil
end

--- How the computer plays a game at a level: the engine's way, with whatever the game changes
--- @param game GameDefinition
--- @param level string
--- @return ComputerLevel
function Computer.Level(game, level)
  local settings = {}
  for key, value in pairs(LEVELS[level] or LEVELS[Computer.DEFAULT_LEVEL]) do
    settings[key] = value
  end
  local changed = game.computer and game.computer.levels and game.computer.levels[level]
  for key, value in pairs(changed or {}) do
    settings[key] = value
  end
  return settings
end

--- Whether the player may take a move back in a game against the computer
--- @param game GameDefinition
--- @return boolean
function Computer.TakesBack(game)
  local computer = game.computer
  if not computer then
    return false
  end
  if computer.takeback ~= nil then
    return computer.takeback
  end
  return game.visible == nil
end

--- Seconds the computer looks as though it thinks at least
--- @param game GameDefinition
--- @return number
function Computer.Pause(game)
  return game.computer and game.computer.pause or Computer.PAUSE
end

--- What is wrong with a game's computer, for the registry to refuse it
--- @param game GameDefinition
--- @return string? nil if nothing is
function Computer.Problem(game)
  local computer = game.computer
  if computer == nil then
    return nil
  end
  if type(computer) ~= "table" then
    return "has a computer that isn't a table"
  end
  if game.together then
    return "is played together, which the computer can't play"
  end
  if private.Games.IsSolo(game) then
    return "is only ever played alone, there is no seat for the computer"
  end
  if not computer.think and not game.moves then
    return "has a computer, and neither moves nor think"
  end
  if game.visible and not computer.think and not computer.guess then
    return "has something to hide, and its computer neither guesses at it nor thinks for itself"
  end
  local kinds = {
    evaluate = "function",
    priority = "function",
    noisy = "function",
    key = "function",
    copy = "function",
    guess = "function",
    think = "function",
    levels = "table",
  }
  for name, kind in pairs(kinds) do
    if computer[name] ~= nil and type(computer[name]) ~= kind then
      return "has a computer whose " .. name .. " isn't a " .. kind
    end
  end
  for level in pairs(computer.levels or {}) do
    if not LEVELS[level] then
      return "has a computer with a level there is no such thing as: " .. tostring(level)
    end
  end
  return nil
end

-----------------------------
-- The brain
-----------------------------

--- What the computer thinks with while it decides on one move
--- @class Brain
--- @field game GameDefinition
--- @field computer GameComputer
--- @field seat number Whose move it is deciding on
--- @field level ComputerLevel
--- @field random Random Its own dice, for its slips, its guesses and the chances it imagines
--- @field spent number Positions looked at so far
--- @field limit number? Where looking further ahead stops, in positions looked at
--- @field stopped boolean Ran out of positions to look at, what it is looking at now is to be thrown away
--- @field clock (fun(): number)? Milliseconds from some time or other
--- @field slice number? How many it may think for before it lets a frame by
--- @field started number? When it started thinking since it last did
--- @field ticks number Work since it last looked at the clock
--- @field memory table<string, table>? What it found out about each position, by key
--- @field horizon boolean Something it looked at went on further than it looked: looking further might change its mind
--- @field score number? How it thinks it stands, after the move it decided on
--- @field reached number? How many moves ahead it last looked all the way
local Brain = {}
Brain.__index = Brain
Computer.Brain = Brain

--- @param game GameDefinition
--- @param seat number
--- @param level string
--- @param seed number
--- @return Brain
function Brain.New(game, seat, level, seed)
  return setmetatable({
    game = game,
    computer = game.computer or {},
    seat = seat,
    level = Computer.Level(game, level),
    random = private.Random.New(seed),
    spent = 0,
    stopped = false,
    ticks = 0,
  }, Brain)
end

--- Counts work done, and lets a frame by when it has thought for long enough at a time
--- @param units number? One if left out
function Brain:Spend(units)
  self.ticks = self.ticks + (units or 1)
  if self.ticks < CLOCK_EVERY or not self.clock then
    return
  end
  self.ticks = 0
  if self.clock() - self.started >= self.slice and coroutine.running() then
    coroutine.yield()
  end
end

--- @param state table
--- @return table
function Brain:Copy(state)
  local copy = self.computer.copy
  return copy and copy(state) or copyOf(state, {})
end

--- A copy of a position with a move made in it. Counts as a position looked at
--- @param state table
--- @param seat number Who makes the move
--- @param move string One the game listed
--- @return table
function Brain:Play(state, seat, move)
  local after = self:Copy(state)
  self.game.apply(after, seat, move, self.random)
  self.spent = self.spent + 1
  if self.limit and self.spent >= self.limit then
    self.stopped = true
  end
  self:Spend()
  return after
end

--- Whether it slips this time, at its level
--- @return boolean
function Brain:Slips()
  local slip = self.level.slip
  return slip > 0 and self.random:Roll(1000) <= slip * 1000
end

--- What a game that is over is worth to the computer, some way down the moves it looked at
--- @param outcome { winner: number, all: boolean? }
--- @param depth number How many moves down
--- @return number
function Brain:final(outcome, depth)
  if outcome.winner == self.seat or (outcome.all and outcome.winner == 0) then
    return outcome.all and 0 or Computer.WIN - depth
  elseif outcome.winner == 0 then
    return 0
  end
  return -Computer.WIN + depth
end

--- How a position that isn't over looks to the computer, as the game says or from games played
--- out at random from it
--- @param state table
--- @return number
function Brain:judge(state)
  local evaluate = self.computer.evaluate
  if evaluate then
    return evaluate(state, self.seat)
  end
  local game, random, total, count = self.game, self.random, 0, self.level.playouts
  for _ = 1, count do
    local world, outcome = self:Copy(state), nil
    for _ = 1, PLAYOUT_MOVES do
      outcome = game.result(world)
      if outcome then
        break
      end
      local seat = game.turn(world)
      local list = game.moves(world, seat)
      if #list == 0 then
        break
      end
      game.apply(world, seat, list[random:Roll(#list)], random)
      self.spent = self.spent + 1
      self:Spend()
    end
    if outcome then
      local worth = self:final(outcome, 0)
      total = total + (worth > 0 and 1 or (worth < 0 and -1 or 0))
    end
  end
  return total / count * PLAYOUT_SCALE
end

--- The moves a seat has, the most promising first
--- @param state table
--- @param seat number
--- @param first string? To be looked at before any other
--- @param onlyNoisy boolean? Only the ones the computer can't stop looking after
--- @return string[]
function Brain:ordered(state, seat, first, onlyNoisy)
  local list = self.game.moves(state, seat)
  local computer = self.computer
  if onlyNoisy then
    local kept = {}
    for _, move in ipairs(list) do
      if computer.noisy(state, move, seat) then
        kept[#kept + 1] = move
      end
    end
    list = kept
  end
  local priority = computer.priority
  if not priority and not first then
    return list
  end
  local rank = {}
  for index, move in ipairs(list) do
    rank[move] = (move == first and INFINITE) or (priority and priority(state, move, seat)) or 0
    -- Keeps the order the same where the game sees nothing to choose between them
    rank[move] = rank[move] - index * TIE
  end
  table.sort(list, function(a, b)
    return rank[a] > rank[b]
  end)
  return list
end

--- Looks on past the end of the moves it meant to look at, for as long as they are noisy and
--- the moves of whoever is to move still count
--- @param state table
--- @param alpha number The computer is sure of this much already
--- @param beta number The others won't let it have more than this
--- @param depth number Moves down so far
--- @param left number How many more it may look on for
--- @return number
function Brain:settle(state, alpha, beta, depth, left)
  local outcome = self.game.result(state)
  if outcome then
    return self:final(outcome, depth)
  end
  local standing = self:judge(state)
  if left <= 0 or self.stopped then
    return standing
  end
  local seat = self.game.turn(state)
  local own = seat == self.seat
  -- Whoever is to move needn't make any of these: they can leave it as it stands
  if own then
    if standing >= beta then
      return standing
    end
    alpha = math.max(alpha, standing)
  else
    if standing <= alpha then
      return standing
    end
    beta = math.min(beta, standing)
  end
  local best = standing
  for _, move in ipairs(self:ordered(state, seat, nil, true)) do
    local score = self:settle(self:Play(state, seat, move), alpha, beta, depth + 1, left - 1)
    if self.stopped then
      return best
    end
    if own then
      best = math.max(best, score)
      alpha = math.max(alpha, score)
    else
      best = math.min(best, score)
      beta = math.min(beta, score)
    end
    if alpha >= beta then
      break
    end
  end
  return best
end

--- How good a position is for the computer, looking so many moves ahead from it. Its own moves
--- it picks the best of, everyone else's the worst for it, and whatever can't change the
--- outcome isn't looked into at all
--- @param state table
--- @param ahead number Moves left to look ahead
--- @param alpha number The computer is sure of this much already
--- @param beta number The others won't let it have more than this
--- @param depth number Moves down so far
--- @return number
function Brain:search(state, ahead, alpha, beta, depth)
  local game, computer = self.game, self.computer
  local outcome = game.result(state)
  if outcome then
    return self:final(outcome, depth)
  end
  if ahead <= 0 then
    self.horizon = true
    if computer.noisy and self.level.quiet > 0 then
      return self:settle(state, alpha, beta, depth, self.level.quiet)
    end
    return self:judge(state)
  end

  -- What it already knows about the position, from some other way of getting there
  local key = computer.key and computer.key(state)
  local known = key and self.memory[key]
  local first = known and known.move
  if known and (known.ahead >= ahead or known.final) then
    self.horizon = self.horizon or not known.final
    if known.kind == EXACT then
      return known.score
    elseif known.kind == LOWER then
      alpha = math.max(alpha, known.score)
    else
      beta = math.min(beta, known.score)
    end
    if alpha >= beta then
      return known.score
    end
  end

  local seat = game.turn(state)
  local own = seat == self.seat
  local from, to = alpha, beta
  -- Whether anything under this position goes further than is looked
  local horizon = self.horizon
  self.horizon = false
  local best, bestMove = own and -INFINITE or INFINITE, nil
  for _, move in ipairs(self:ordered(state, seat, first)) do
    local score = self:search(self:Play(state, seat, move), ahead - 1, alpha, beta, depth + 1)
    if self.stopped then
      return best ~= -INFINITE and best ~= INFINITE and best or score
    end
    if own and score > best then
      best, bestMove = score, move
      alpha = math.max(alpha, score)
    elseif not own and score < best then
      best, bestMove = score, move
      beta = math.min(beta, score)
    end
    if alpha >= beta then
      break
    end
  end
  if bestMove == nil then
    -- Nothing to move and still not over: as it stands
    self.horizon = true
    return self:judge(state)
  end

  if key then
    local kind = EXACT
    if best <= from then
      kind = UPPER
    elseif best >= to then
      kind = LOWER
    end
    -- Worked out all the way to the end, it holds however far ahead is asked about next time
    self.memory[key] = { ahead = ahead, score = best, kind = kind, move = bestMove, final = not self.horizon or nil }
  end
  self.horizon = self.horizon or horizon
  return best
end

--- Scores each of the computer's moves in a position, looking further ahead each time round
--- until it has looked at as many positions as it may
--- @param world table A position it knows all of
--- @param moves string[]
--- @param limit number Where to stop, in positions looked at
--- @param exact boolean Every score has to be right, not only the best one
--- @return number[] scores By move, in the order given
function Brain:deepen(world, moves, limit, exact)
  local order = {}
  for index = 1, #moves do
    order[index] = index
  end
  -- Ties go any way, but always the same way from the same position
  self.random:Shuffle(order)
  local priority, seat = self.computer.priority, self.seat
  if priority then
    local rank = {}
    for position, index in ipairs(order) do
      rank[index] = (priority(world, moves[index], seat) or 0) - position * TIE
    end
    table.sort(order, function(a, b)
      return rank[a] > rank[b]
    end)
  end

  local found
  self.memory, self.stopped = {}, false
  for ahead = 1, self.level.depth do
    -- The first time round is finished however long it takes: something has to be played
    self.limit = ahead > 1 and limit or nil
    self.horizon = false
    local scores, alpha = {}, -INFINITE
    for _, index in ipairs(order) do
      local after = self:Play(world, seat, moves[index])
      local score = self:search(after, ahead - 1, exact and -INFINITE or alpha - TIE, INFINITE, 1)
      if self.stopped then
        break
      end
      scores[index] = score
      alpha = math.max(alpha, score)
    end
    if self.stopped then
      break
    end
    found, self.reached = scores, ahead
    table.sort(order, function(a, b)
      if scores[a] ~= scores[b] then
        return scores[a] > scores[b]
      end
      return a < b
    end)
    -- Settled one way or the other, or seen through to the end: looking further won't change it.
    -- Where the others are to be slipped into, they have to be seen for what they are first
    local best = scores[order[1]]
    local settled = (best >= WON and not exact) or best <= -WON
    if settled or not self.horizon or self.spent >= limit then
      break
    end
  end
  self.limit = nil
  return found
end

--- Picks a move from the ones scored: the best, or at a level that slips now and then, one of
--- the next best. Unless it is careless, it never slips past a win it has seen, nor into a move
--- that loses when it doesn't have to. Between moves that are as good as each other it goes by
--- which the game thought more promising to begin with, and then by chance
--- @param scored { move: string, score: number, rank: number? }[] Best first
--- @return { move: string, score: number }
function Brain:Pick(scored)
  local best = scored[1]
  local careless = self.level.careless
  if #scored > 1 and (careless or best.score < WON) and self:Slips() then
    local among = {}
    for _, entry in ipairs(scored) do
      local losing = entry.score <= -WON and best.score > -WON
      if #among < self.level.among and (careless or not losing) then
        among[#among + 1] = entry
      end
    end
    if #among > 0 then
      return among[self.random:Roll(#among)]
    end
  end
  local ties = 1
  while scored[ties + 1] and scored[ties + 1].score >= best.score - TIE and scored[ties + 1].rank == best.rank do
    ties = ties + 1
  end
  return scored[self.random:Roll(ties)]
end

--- Decides on a move the way the engine does: looks ahead from every move the seat has, against
--- a few guesses at what it can't see where there is something hidden, and picks
--- @param seen table What the seat may see of the position
--- @param moves string[]? The moves to choose between, all of them if left out
--- @return string move
--- @return number score How it stands after it, as far as it can tell
function Brain:Search(seen, moves)
  local game, computer, level, seat = self.game, self.computer, self.level, self.seat
  moves = moves or game.moves(seen, seat)
  assert(#moves > 0, "the computer has no move")
  if #moves == 1 and not self.wants then
    return moves[1], 0
  end

  local samples = game.visible and math.max(1, level.samples) or 1
  local totals, counted = {}, {}
  local start = self.spent
  for sample = 1, samples do
    local world = game.visible and computer.guess(seen, seat, self.random) or seen
    -- Each guess gets its share of the positions there are to look at
    local limit = start + math.floor(level.budget * sample / samples)
    local scores = self:deepen(world, moves, limit, level.slip > 0 or samples > 1)
    for index = 1, #moves do
      if scores[index] then
        totals[index] = (totals[index] or 0) + scores[index]
        counted[index] = (counted[index] or 0) + 1
      end
    end
  end

  local scored, priority = {}, computer.priority
  for index, move in ipairs(moves) do
    if totals[index] then
      local rank = priority and priority(seen, move, seat) or 0
      scored[#scored + 1] = { move = move, score = totals[index] / counted[index], rank = rank, index = index }
    end
  end
  table.sort(scored, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    elseif a.rank ~= b.rank then
      return a.rank > b.rank
    end
    return a.index < b.index
  end)
  local picked = self:Pick(scored)
  self.score = scored[1].score
  return picked.move, self.score
end

--- Decides on its move
--- @param seen table What its seat may see of the position
--- @return string
function Brain:decide(seen)
  local think = self.computer.think
  if think then
    return think(seen, self.seat, self)
  end
  return (self:Search(seen))
end

-----------------------------
-- Thinking a little at a time
-----------------------------

--- The computer deciding on one move, which can take a good many frames
--- @class Thinker
--- @field brain Brain
--- @field seen table What the computer's seat may see of the position
--- @field thread thread
--- @field done boolean
--- @field move string? What it decided on, once it is done
--- @field score number? How it thinks it stands after that, if it knows
--- @field failed string? What went wrong, if something did: the move is then the first one there was
local Thinker = {}
Thinker.__index = Thinker

--- Starts the computer thinking about its move
--- @param game GameDefinition
--- @param seen table What the computer's seat may see of the position. It is played on: hand it a copy
--- @param seat number
--- @param level string
--- @param seed number What its dice start from
--- @param wants boolean? It has to know how it stands even with only one move to make, to answer a draw offer by
--- @return Thinker
function Computer.Think(game, seen, seat, level, seed, wants)
  local brain = Brain.New(game, seat, level, seed)
  brain.wants = wants
  local thinker = setmetatable({ brain = brain, seen = seen, done = false }, Thinker)
  thinker.thread = coroutine.create(function()
    return brain:decide(seen)
  end)
  return thinker
end

--- Thinks for a while
--- @param ms number? For how long, until it is done if left out
--- @param clock (fun(): number)? Milliseconds from some time or other, needed to stop in time
--- @return boolean done
function Thinker:Run(ms, clock)
  if self.done then
    return true
  end
  local brain = self.brain
  brain.clock, brain.slice = ms and clock, ms
  brain.started, brain.ticks = brain.clock and clock(), 0
  local ok, move = coroutine.resume(self.thread)
  if not ok or (coroutine.status(self.thread) == "dead" and type(move) ~= "string") then
    -- Whatever went wrong, the game goes on rather than getting stuck
    self.failed = ok and "the computer decided on " .. tostring(move) or tostring(move)
    local listed, moves = pcall(function()
      return brain.game.moves and brain.game.moves(self.seen, brain.seat)
    end)
    self.move, self.done = listed and type(moves) == "table" and moves[1] or nil, true
  elseif coroutine.status(self.thread) == "dead" then
    self.move, self.score, self.done = move, brain.score, true
  end
  return self.done
end

--- Thinks until it knows
--- @return string?
function Thinker:Finish()
  self:Run()
  return self.move
end
