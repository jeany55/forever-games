--------------------------
--  Backgammon
--------------------------
-- Two players race fifteen checkers each around twenty-four points and off the board, by the
-- roll of two dice. A checker moves by what one die shows, onto any point the opponent doesn't
-- hold with two or more. Landing on a single checker of theirs hits it: it goes to the bar and
-- has to come back in at the far end before anything else of theirs moves. Doubles are played
-- four times. Once all fifteen are in the last six points they are borne off, and whoever gets
-- all of theirs off first wins.
--
-- As much of a roll as can be played has to be: both dice if there is a way to, and the higher
-- one if it can only be one of them. A player who can't move at all sits the turn out, which
-- the game sees to by itself.
--
-- The dice are the engine's (Engine/Random.lua). The opening roll is one die each, the higher
-- goes first and plays those two. After that the roll for the next turn is made as a move is
-- applied, so it is there for the player when the move arrives: a turn is one message.
--
-- Each player counts the points their own way round: their checkers travel from 24 down to 1,
-- their home is 1 to 6, the bar is 25 and off the board is 0. What is point 5 to one is point
-- 20 to the other. A move is every checker moved in the turn, "24-18.13-11", in the mover's
-- numbers. There is no doubling cube.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L

local WHITE, RED = 1, 2
local POINTS = 24
local CHECKERS = 15
local HOME = 6
local BAR, OFF = POINTS + 1, 0
-- Where the checkers start, by point
local START = { [24] = 2, [13] = 5, [8] = 3, [6] = 5 }
-- Turns in a row that nobody could move in before the game is called off. It doesn't happen
local MAX_SKIPS = 200

--- @class BackgammonStep
--- @field from number Point the checker left, 25 for the bar. In the mover's numbers
--- @field to number Point it went to, 0 for off the board
--- @field hit boolean? It landed on a checker of the opponent's

--- @class BackgammonState
--- @field points number[][] Checkers on each point, by seat and then by point in that seat's numbers
--- @field bar number[] Checkers on the bar, by seat
--- @field off number[] Checkers borne off, by seat
--- @field turn number
--- @field dice number[] The roll to play, higher die first
--- @field playable number How many dice of the roll can be played
--- @field must number? The die that has to be the one played, when only one of the two can be
--- @field last { seat: number, steps: BackgammonStep[] }? The move that led here
--- @field skipped { seat: number, dice: number[] }[] Who had to sit out since, with what they rolled
--- @field outcome { winner: number, detail: string? }?

--- @class BackgammonEvent: MatchEvent
--- @field steps BackgammonStep[]
--- @field dice number[] What was rolled for the turn after

--- @param seat number
--- @return number
local function other(seat)
  return seat == WHITE and RED or WHITE
end

--- The dice of a roll one at a time: doubles are played four times
--- @param dice number[]
--- @return number[]
local function rolls(dice)
  if dice[1] == dice[2] then
    return { dice[1], dice[1], dice[1], dice[1] }
  end
  return { dice[1], dice[2] }
end

--- @param list number[]
--- @param index number
--- @return number[] The list without one of its entries
local function without(list, index)
  local rest = {}
  for position, value in ipairs(list) do
    if position ~= index then
      rest[#rest + 1] = value
    end
  end
  return rest
end

-----------------------------
-- Rules
-----------------------------

--- Where a checker moved by a die ends up, nil if it can't be moved by it
--- @param state BackgammonState
--- @param seat number
--- @param from number
--- @param die number
--- @return number?
local function landing(state, seat, from, die)
  local mine = state.points[seat]
  if from == BAR then
    if state.bar[seat] == 0 then
      return nil
    end
  elseif state.bar[seat] > 0 or (mine[from] or 0) == 0 then
    -- Whatever is on the bar comes in first
    return nil
  end

  local to = from - die
  if to >= 1 then
    return state.points[other(seat)][BAR - to] < 2 and to or nil
  end

  -- Off the board, which takes every checker being home
  for point = HOME + 1, POINTS do
    if mine[point] > 0 then
      return nil
    end
  end
  if to < 0 then
    -- A die that is more than it takes only bears off the checker furthest back
    for point = from + 1, HOME do
      if mine[point] > 0 then
        return nil
      end
    end
  end
  return OFF
end

--- Moves a checker. Whether it can be is for `landing` to say
--- @param state BackgammonState
--- @param seat number
--- @param from number
--- @param to number
--- @return boolean hit
local function step(state, seat, from, to)
  local mine, theirs = state.points[seat], state.points[other(seat)]
  if from == BAR then
    state.bar[seat] = state.bar[seat] - 1
  else
    mine[from] = mine[from] - 1
  end
  if to == OFF then
    state.off[seat] = state.off[seat] + 1
    return false
  end
  mine[to] = mine[to] + 1
  if theirs[BAR - to] == 1 then
    theirs[BAR - to] = 0
    state.bar[other(seat)] = state.bar[other(seat)] + 1
    return true
  end
  return false
end

--- Takes a step back
--- @param state BackgammonState
--- @param seat number
--- @param from number
--- @param to number
--- @param hit boolean
local function unstep(state, seat, from, to, hit)
  local mine = state.points[seat]
  if to == OFF then
    state.off[seat] = state.off[seat] - 1
  else
    mine[to] = mine[to] - 1
    if hit then
      state.points[other(seat)][BAR - to] = 1
      state.bar[other(seat)] = state.bar[other(seat)] - 1
    end
  end
  if from == BAR then
    state.bar[seat] = state.bar[seat] + 1
  else
    mine[from] = mine[from] + 1
  end
end

--- How many of these dice can be played one after the other, at best. The state is tried out
--- on and left as it was
--- @param state BackgammonState
--- @param seat number
--- @param dice number[]
--- @return number
local function most(state, seat, dice)
  local best, tried = 0, {}
  for index, die in ipairs(dice) do
    if not tried[die] then
      tried[die] = true
      local rest = without(dice, index)
      for from = BAR, 1, -1 do
        local to = landing(state, seat, from, die)
        if to then
          local hit = step(state, seat, from, to)
          local count = 1 + most(state, seat, rest)
          unstep(state, seat, from, to, hit)
          if count > best then
            best = count
            if best == #dice then
              return best
            end
          end
        end
      end
    end
  end
  return best
end

--- Whether a die moves anything at all
--- @param state BackgammonState
--- @param seat number
--- @param die number
--- @return boolean
local function moves(state, seat, die)
  for from = BAR, 1, -1 do
    if landing(state, seat, from, die) then
      return true
    end
  end
  return false
end

--- The dice that are left once some steps have been made. A checker borne off may have been
--- moved by either die, so there can be more than one answer. The state is left as it was
--- @param state BackgammonState
--- @param seat number
--- @param dice number[]
--- @param steps BackgammonStep[]
--- @param index number? The step to go on from
--- @param found number[][]?
--- @return number[][] found Empty if the steps can't be made
local function follow(state, seat, dice, steps, index, found)
  index, found = index or 1, found or {}
  local next = steps[index]
  if not next then
    found[#found + 1] = dice
    return found
  end
  local tried = {}
  for position, die in ipairs(dice) do
    if not tried[die] then
      tried[die] = true
      if landing(state, seat, next.from, die) == next.to then
        local hit = step(state, seat, next.from, next.to)
        follow(state, seat, without(dice, position), steps, index + 1, found)
        unstep(state, seat, next.from, next.to, hit)
      end
    end
  end
  return found
end

--- A position to try moves out on
--- @param state BackgammonState
--- @return BackgammonState
local function scratch(state)
  return {
    points = { { unpack(state.points[WHITE]) }, { unpack(state.points[RED]) } },
    bar = { unpack(state.bar) },
    off = { unpack(state.off) },
    dice = state.dice,
    playable = state.playable,
    must = state.must,
    turn = state.turn,
  }
end

--- The steps the player to move may make next, after the ones made so far in the turn: only
--- those that leave as much of the roll playable as has to be played
--- @param state BackgammonState
--- @param steps BackgammonStep[] Made so far
--- @return table<number, table<number, boolean>> options Points a checker can go to, by where it is
--- @return BackgammonState position The position with the steps made, to draw or go on from
local function continuations(state, steps)
  local seat = state.turn
  local position = scratch(state)
  local lefts = follow(position, seat, rolls(state.dice), steps)
  for _, made in ipairs(steps) do
    made.hit = step(position, seat, made.from, made.to)
  end

  local options = {}
  for _, dice in ipairs(lefts) do
    local tried = {}
    for index, die in ipairs(dice) do
      -- With only one die to play it has to be the right one
      if not tried[die] and (state.playable > 1 or not state.must or die == state.must) then
        tried[die] = true
        local rest = without(dice, index)
        for from = BAR, 1, -1 do
          local to = landing(position, seat, from, die)
          if to then
            local hit = step(position, seat, from, to)
            if #steps + 1 + most(position, seat, rest) >= state.playable then
              options[from] = options[from] or {}
              options[from][to] = true
            end
            unstep(position, seat, from, to, hit)
          end
        end
      end
    end
  end
  return options, position
end

--- Works out what the roll lets the player to move do
--- @param state BackgammonState
local function assess(state)
  local dice, seat = state.dice, state.turn
  state.playable = most(state, seat, rolls(dice))
  state.must = nil
  if state.playable == 1 and dice[1] ~= dice[2] and moves(state, seat, dice[1]) then
    state.must = dice[1]
  end
end

--- @param random Random
--- @return number[] dice Higher first
local function roll(random)
  local first, second = random:Roll(6), random:Roll(6)
  return { math.max(first, second), math.min(first, second) }
end

--- @param _ number
--- @param random Random
--- @return BackgammonState
local function newState(_, random)
  --- @type BackgammonState
  local state = { points = { {}, {} }, bar = { 0, 0 }, off = { 0, 0 }, skipped = {} }
  for seat = WHITE, RED do
    for point = 1, POINTS do
      state.points[seat][point] = START[point] or 0
    end
  end

  -- A die each to see who starts, again for as long as they come up the same
  local white, red
  repeat
    white, red = random:Roll(6), random:Roll(6)
  until white ~= red
  state.turn = white > red and WHITE or RED
  state.dice = { math.max(white, red), math.min(white, red) }
  assess(state)
  return state
end

--- @param move string
--- @return BackgammonStep[]?
local function parse(move)
  local steps = {}
  for part in (move .. "."):gmatch("(.-)%.") do
    local from, to = part:match("^(%d+)%-(%d+)$")
    from, to = tonumber(from), tonumber(to)
    if not from or from < 1 or from > BAR or to >= from or tostring(from) .. "-" .. tostring(to) ~= part then
      return nil
    end
    steps[#steps + 1] = { from = from, to = to }
  end
  return steps
end

--- @param steps BackgammonStep[]
--- @return string
local function moveName(steps)
  local parts = {}
  for index, made in ipairs(steps) do
    parts[index] = made.from .. "-" .. made.to
  end
  return table.concat(parts, ".")
end

--- @param state BackgammonState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  if seat ~= state.turn then
    return false, "not_your_turn"
  end
  local steps = parse(move)
  if not steps or #steps ~= state.playable then
    return false, "invalid_move"
  end
  if state.must and landing(state, seat, steps[1].from, state.must) ~= steps[1].to then
    return false, "invalid_move"
  end
  if #follow(state, seat, rolls(state.dice), steps) == 0 then
    return false, "invalid_move"
  end
  return true
end

--- Every turn the roll can be played as, one way of making each position it can lead to. Two
--- turns that leave the checkers where they are on both sides are the same turn, whichever
--- order the steps were made in. Doubles are only tried with each checker moved no further
--- back than the one before it: any turn of them can be made in that order
--- @param state BackgammonState
--- @param seat number
--- @return string[]
local function everyTurn(state, seat)
  local position = scratch(state)
  local doubles = state.dice[1] == state.dice[2]
  local list, reached, steps = {}, {}, {}

  local function search(dice, highest)
    if #steps == state.playable then
      local key = table.concat(position.points[seat], ",") .. ":" .. table.concat(position.points[other(seat)], ",") .. ":" .. table.concat(position.bar, ",")
      if not reached[key] then
        reached[key] = true
        list[#list + 1] = moveName(steps)
      end
      return
    end
    local tried = {}
    for index, die in ipairs(dice) do
      -- With only one die to play it has to be the right one
      if not tried[die] and (not state.must or die == state.must) then
        tried[die] = true
        local rest = without(dice, index)
        for from = doubles and highest or BAR, 1, -1 do
          local to = landing(position, seat, from, die)
          if to then
            local hit = step(position, seat, from, to)
            steps[#steps + 1] = { from = from, to = to }
            search(rest, from)
            steps[#steps] = nil
            unstep(position, seat, from, to, hit)
          end
        end
      end
    end
  end

  search(rolls(state.dice), BAR)
  return list
end

--- How the game was won: a gammon if the loser has borne nothing off, a backgammon if they
--- also still have a checker on the bar or in the winner's home
--- @param state BackgammonState
--- @param winner number
--- @return string?
local function wonBy(state, winner)
  local loser = other(winner)
  if state.off[loser] > 0 then
    return nil
  end
  local far = state.bar[loser]
  for point = POINTS - HOME + 1, POINTS do
    far = far + state.points[loser][point]
  end
  return far > 0 and "backgammon" or "gammon"
end

--- @param steps BackgammonStep[]
--- @return string
local function notate(steps)
  local parts = {}
  for index, made in ipairs(steps) do
    local from = made.from == BAR and "bar" or made.from
    local to = made.to == OFF and "off" or made.to
    parts[index] = from .. "/" .. to .. (made.hit and "*" or "")
  end
  return table.concat(parts, " ")
end

--- @param state BackgammonState
--- @param seat number
--- @param move string
--- @param random Random
--- @return BackgammonEvent
local function apply(state, seat, move, random)
  local steps = parse(move)
  for _, made in ipairs(steps) do
    made.hit = step(state, seat, made.from, made.to)
  end
  state.last = { seat = seat, steps = steps }
  state.skipped = {}

  if state.off[seat] == CHECKERS then
    state.outcome = { winner = seat, detail = wonBy(state, seat) }
    return { steps = steps, dice = {}, notation = notate(steps) }
  end

  -- The roll for whoever is next. With nothing to play it, the turn passes straight on
  local dice
  repeat
    state.turn = other(state.turn)
    state.dice = roll(random)
    dice = dice or state.dice
    assess(state)
    if state.playable == 0 then
      state.skipped[#state.skipped + 1] = { seat = state.turn, dice = state.dice }
    end
  until state.playable > 0 or #state.skipped >= MAX_SKIPS
  if state.playable == 0 then
    state.outcome = { winner = 0, detail = "blocked" }
  end
  return { steps = steps, dice = dice, notation = notate(steps) }
end

--- How far a player's checkers have left to travel between them
--- @param state BackgammonState
--- @param seat number
--- @return number
local function pips(state, seat)
  local total = state.bar[seat] * BAR
  for point = 1, POINTS do
    total = total + state.points[seat][point] * point
  end
  return total
end

-----------------------------
-- The computer
-----------------------------
-- A turn is the whole roll played, so the computer has every way of playing it to choose from
-- and plays each out to see where it leaves the checkers. It judges that by how far each side
-- has to go, which is all that matters once they have got past each other, and until then by
-- what is at risk: a checker on its own that the other side could hit, with as many of the 36
-- rolls as would hit it, costs what it would have to come round again. Points made with two
-- or more count, in the home board most, all the more in a row that is hard to get past, and
-- so do points held at the back of the other side's board, to come in on.
--
-- At its best it doesn't take the position after its turn for what it is: for the few turns
-- that look best it goes through all 21 rolls the other side could throw, how likely each is,
-- and what the other side would do with it, and plays whichever turn stands up best to that.
-- What the dice will really do it doesn't know, any more than anyone.

-- How many of the 36 rolls hit a checker so many points away, with one checker to hit it with
local SHOTS = { 11, 12, 14, 15, 15, 17, 6, 6, 5, 3, 2, 3, 0, 0, 1, 1, 0, 1, 0, 1, 0, 0, 0, 1 }
-- What being hit costs on top of the points it has to come round again, what each point made is
-- worth at home and at the back of the other side's board, what each checker on the bar costs,
-- and what a row of points made is worth by how long it is, squared
local HIT, HOME_POINT, ANCHOR, ON_BAR, PRIME = 10, 8, 10, 12, 3
-- The other side's checkers on their own count for less: they get to move before they can be hit
local THEIR_BLOTS = 0.5
-- What a game that is won is worth here, well short of the engine's win but more than anything else
local WON = 100000

--- Plays a turn on a position, without rolling for the next
--- @param position BackgammonState
--- @param seat number
--- @param move string
local function playTurn(position, seat, move)
  for _, made in ipairs(parse(move)) do
    step(position, seat, made.from, made.to)
  end
end

--- What a seat's checkers on their own stand to lose to the other side's
--- @param state BackgammonState
--- @param seat number Whose checkers are at risk
--- @return number
local function exposure(state, seat)
  local foe = other(seat)
  local mine, theirs = state.points[seat], state.points[foe]
  local risk = 0
  for point = 1, POINTS do
    if mine[point] == 1 then
      -- The point in the other side's numbers, which they move down towards
      local at = BAR - point
      local shots = 0
      for from = at + 1, BAR do
        local count = from == BAR and state.bar[foe] or theirs[from]
        if count > 0 then
          shots = shots + (SHOTS[from - at] or 0)
        end
      end
      risk = risk + math.min(shots, 36) / 36 * (HIT + BAR - point)
    end
  end
  return risk
end

--- The point of a seat's checker furthest back, in its own numbers. 0 when they are all off
--- @param state BackgammonState
--- @param seat number
--- @return number
local function furthestBack(state, seat)
  if state.bar[seat] > 0 then
    return BAR
  end
  for point = POINTS, 1, -1 do
    if state.points[seat][point] > 0 then
      return point
    end
  end
  return 0
end

--- How well a seat stands
--- @param state BackgammonState
--- @param seat number
--- @return number
local function standing(state, seat)
  local foe = other(seat)
  if state.off[seat] == CHECKERS then
    return WON
  elseif state.off[foe] == CHECKERS then
    return -WON
  end
  local score = pips(state, foe) - pips(state, seat)
  -- Got past each other: it is a race and nothing else
  if furthestBack(state, seat) + furthestBack(state, foe) <= BAR then
    return score
  end

  score = score - exposure(state, seat) + THEIR_BLOTS * exposure(state, foe)
  score = score + ON_BAR * (state.bar[foe] - state.bar[seat])
  for _, side in ipairs({ seat, foe }) do
    local points, worth, run, best = state.points[side], 0, 0, 0
    for point = 1, POINTS do
      local made = points[point] >= 2
      if made and point <= HOME then
        worth = worth + HOME_POINT
      elseif made and point > POINTS - HOME then
        worth = worth + ANCHOR
      end
      run = made and run + 1 or 0
      best = math.max(best, run)
    end
    worth = worth + PRIME * best * best
    score = score + (side == seat and worth or -worth)
  end
  return score
end

--- How a position after the computer's turn stands up to every roll the other side could throw,
--- each played as well as the other side can
--- @param after BackgammonState
--- @param seat number The computer's
--- @param brain Brain
--- @return number
local function lookAhead(after, seat, brain)
  if after.off[seat] == CHECKERS then
    return WON
  end
  local foe, total = other(seat), 0
  for high = 1, 6 do
    for low = 1, high do
      local position = scratch(after)
      position.turn, position.dice = foe, { high, low }
      assess(position)
      local worst = nil
      if position.playable == 0 then
        worst = standing(position, seat)
      else
        for _, reply in ipairs(everyTurn(position, foe)) do
          local answered = scratch(position)
          playTurn(answered, foe, reply)
          local worth = standing(answered, seat)
          worst = worst and math.min(worst, worth) or worth
          brain:Spend()
        end
      end
      -- Doubles come up one way, the rest two
      total = total + worst * (high == low and 1 or 2)
    end
  end
  return total / 36
end

local COMPUTER = {
  -- Trying another turn after seeing the dice the other side was given for it would be trying
  -- for better dice
  takeback = false,
  -- The dice have to land before the checkers move
  pause = 1,
  think = function(seen, seat, brain)
    local turns = everyTurn(seen, seat)
    if #turns == 1 then
      return turns[1]
    end
    local scored = {}
    for index, turn in ipairs(turns) do
      local after = scratch(seen)
      playTurn(after, seat, turn)
      scored[index] = { move = turn, score = standing(after, seat), rank = 0, index = index, after = after }
      brain:Spend()
    end
    local function best(a, b)
      if a.score ~= b.score then
        return a.score > b.score
      end
      return a.index < b.index
    end
    table.sort(scored, best)
    local level = brain.level
    if level.depth >= 2 then
      -- Only the most promising are worth looking further into
      local kept = {}
      for index = 1, math.min(level.consider or 4, #scored) do
        kept[index] = scored[index]
        kept[index].score = lookAhead(kept[index].after, seat, brain)
      end
      scored = kept
      table.sort(scored, best)
    end
    return brain:Pick(scored).move
  end,
  levels = {
    easy = { depth = 1, slip = 0.4, among = 4 },
    medium = { depth = 1, slip = 0.1 },
    hard = { depth = 2, consider = 6 },
  },
}

-----------------------------
-- View
-----------------------------
-- The table is a board with a layout (GUI/Board.lua): every place a checker can be drawn is a
-- square of it, five to a point, and the layout says which of them a click anywhere on a point
-- means. Each player sees the board their own way round, with their home at the bottom right.
--
-- A turn is put together a checker at a time and only sent once the player says so, until then
-- any of it can be taken back. Clicking a point two dice away moves a checker by both.
--
-- The dice (GUI/Dice.lua) lie in the half of the table whoever rolled them sits at. A roll of
-- the player's own waits in their hand until they throw it, the opponent's is thrown for them
-- as it comes.

local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\"
local DISCS = { "white", "red" }
-- The table, measured in checkers. Tools/make_tables.py draws it from the same numbers
local EDGE = 0.45
local BAR_WIDTH = 1.1
local TRAY_GAP, TRAY_WIDTH = 0.3, 1.3
-- Checkers drawn on a point before they are counted instead
local STACK = 5
local MIDDLE = 1.8
local WIDTH = EDGE + HOME + BAR_WIDTH + HOME + TRAY_GAP + TRAY_WIDTH + EDGE
local HEIGHT = EDGE + STACK + MIDDLE + STACK + EDGE
-- How far up a point a click still counts as one on it
local POINT_REACH = STACK + 0.4
-- Squares that aren't on a point: a square on one is the point times ten plus how high up it
local MY_BAR, THEIR_BAR, MY_OFF, THEIR_OFF = 251, 261, 271, 281
local DIE_SIZE, DIE_GAP = 0.95, 0.15
-- How far in from the end of the table a roll is thrown from, at its far side from the bar
local HAND = 0.75
-- Seconds the opponent's roll waits for the checkers just moved to get where they are going
local THROW_DELAY = 0.3
local LAST_MOVE = { 1, 0.9, 0.35, 0.55 }
local TALLY_HEIGHT, TALLY_GAP = 22, 4
local BUTTON_WIDTH = 72
local MOVE_SOUND = "chipsCollide"

--- Where a point is on the table as the player sees it
--- @param point number In the player's own numbers
--- @return number column From 0 on the left
--- @return boolean top Whether it hangs down from the top edge
local function placeOf(point)
  if point > POINTS / 2 then
    return point - POINTS / 2 - 1, true
  end
  return POINTS / 2 - point, false
end

--- @param square number
--- @return number x, number y In checkers, right and down from the top left corner of the table
local function spotOf(square)
  local barX = EDGE + HOME + BAR_WIDTH / 2
  local trayX = WIDTH - EDGE - TRAY_WIDTH / 2
  if square == MY_BAR then
    return barX, HEIGHT / 2 + 0.75
  elseif square == THEIR_BAR then
    return barX, HEIGHT / 2 - 0.75
  elseif square == MY_OFF then
    return trayX, HEIGHT - EDGE - 1
  elseif square == THEIR_OFF then
    return trayX, EDGE + 1
  end
  local column, top = placeOf(math.floor(square / 10))
  local height = square % 10 - 0.5
  local x = EDGE + column + 0.5 + (column >= HOME and BAR_WIDTH or 0)
  return x, top and EDGE + height or HEIGHT - EDGE - height
end

--- @class BackgammonView: GameViewObject
--- @field board Board
--- @field dice Dice
--- @field tallies Frame[] The opponent's above the table, the player's own below
--- @field note FontString Says who had to sit out
--- @field undo Button
--- @field play Button
--- @field view GameView? What was last asked for
--- @field steps BackgammonStep[] The turn the player is putting together
--- @field position BackgammonState The position with those steps made
--- @field options table<number, table<number, boolean>> Where the player's checkers can go next
--- @field paths table<number, BackgammonStep[]> How the checker in hand gets to each square it can go to
--- @field sent boolean? The move being shown is the player's own, the checkers are already there
--- @field rolled any The roll last put on the table, by its key
--- @field thrown table<any, boolean> The player's own rolls they have thrown, by key
local View = {}
View.__index = View

--- The square a point is drawn on, for a point as the local player counts them
--- @param point number 25 for the bar, 0 for off the board
--- @param slot number How high up the point
--- @param mine boolean Whether it is about the local player's checkers
--- @return number
local function squareOf(point, slot, mine)
  if point == BAR then
    return mine and MY_BAR or THEIR_BAR
  elseif point == OFF then
    return mine and MY_OFF or THEIR_OFF
  end
  return point * 10 + math.max(1, math.min(slot, STACK))
end

--- How many checkers stand on a point, whoever they belong to
--- @param point number In the local player's numbers
--- @return number mine, number theirs
function View:countOn(point)
  local seat = self.view.seat
  return self.position.points[seat][point], self.position.points[other(seat)][BAR - point]
end

--- The square a checker put on a point would be drawn on. One that hits takes the place of
--- what it hit
--- @param point number
--- @return number
function View:landingSquare(point)
  local mine, theirs = self:countOn(point)
  return squareOf(point, theirs > 0 and theirs or mine + 1, true)
end

--- The square at a place on the table: a click anywhere on a point means the checker on top of
--- it or, with one in hand, where that one would come to rest
--- @param x number
--- @param y number
--- @return number?
function View:find(x, y)
  if y < EDGE or y > HEIGHT - EDGE or x < EDGE or x > WIDTH - EDGE then
    return nil
  end
  local top = y < HEIGHT / 2
  local across = x - EDGE
  if across >= 2 * HOME + BAR_WIDTH then
    return across >= 2 * HOME + BAR_WIDTH + TRAY_GAP and MY_OFF or nil
  elseif across >= HOME and across < HOME + BAR_WIDTH then
    return top and THEIR_BAR or MY_BAR
  end
  if (top and y - EDGE or HEIGHT - EDGE - y) > POINT_REACH then
    return nil
  end

  local column = math.floor(across >= HOME and across - BAR_WIDTH or across)
  local point = top and POINTS / 2 + 1 + column or POINTS / 2 - column
  local selected = self.board.selected
  if selected and math.floor(selected / 10) ~= point then
    local landing = self:landingSquare(point)
    if self.paths[landing] then
      return landing
    end
  end
  -- Not somewhere the checker in hand can go: the click is for what stands there
  local mine, theirs = self:countOn(point)
  return squareOf(point, mine + theirs, true)
end

--- The point a square of the player's own checkers stands for, if it is the one to pick up from
--- @param square number
--- @return number? point 25 for the bar
function View:sourceOf(square)
  if square == MY_BAR then
    return self.position.bar[self.view.seat] > 0 and BAR or nil
  end
  local point = math.floor(square / 10)
  if point < 1 or point > POINTS then
    return nil
  end
  local mine = self:countOn(point)
  return mine > 0 and square == squareOf(point, mine, true) and point or nil
end

--- Everywhere the checker on a point can go with what is left of the roll, by one die or by
--- several one after the other
--- @param from number
--- @return table<number, BackgammonStep[]> paths The steps that get it there, by square
function View:pathsFrom(from)
  local state = self.view.state
  local paths = {}

  local function extend(steps, at, trail)
    for to in pairs(continuations(state, steps)[at] or {}) do
      local square = to == OFF and MY_OFF or self:landingSquare(to)
      if not paths[square] or #trail + 1 < #paths[square] then
        local made = { from = at, to = to }
        local path, further = { unpack(trail) }, { unpack(steps) }
        path[#path + 1], further[#further + 1] = made, made
        paths[square] = path
        if to ~= OFF then
          extend(further, to, path)
        end
      end
    end
  end
  extend(self.steps, from, {})
  return paths
end

--- @param stage Frame
--- @return BackgammonView
local function createView(stage)
  --- @type BackgammonView
  local self = setmetatable({ steps = {}, options = {}, paths = {}, thrown = {} }, View)
  local Board, Widgets = private.Board, private.Widgets

  local squares = { MY_BAR, THEIR_BAR, MY_OFF, THEIR_OFF }
  for point = 1, POINTS do
    for slot = 1, STACK do
      squares[#squares + 1] = point * 10 + slot
    end
  end
  self.board = Board.New(stage, {
    layout = {
      squares = squares,
      width = WIDTH,
      height = HEIGHT,
      at = spotOf,
      find = function(x, y)
        return self:find(x, y)
      end,
      backdrop = { texture = IMAGES .. "Board\\backgammon", width = WIDTH, height = HEIGHT },
    },
  })
  self.board.frame:SetPoint("CENTER")
  self.board:SetInput({
    pickable = function(square)
      local from = self:sourceOf(square)
      return from ~= nil and self.options[from] ~= nil
    end,
    targets = function(square)
      self.paths = self:pathsFrom(self:sourceOf(square))
      return self.paths
    end,
    onMove = function(from, to, dropped)
      self:step(from, to, dropped)
    end,
    onCancel = function(button)
      -- Any button but the left one takes the last checker back
      if button then
        self:takeBack()
      end
    end,
  })

  self.dice = private.Dice.New(self.board.frame)

  self.tallies = { Board.Tally(stage, TALLY_HEIGHT), Board.Tally(stage, TALLY_HEIGHT) }
  self.tallies[1]:SetPoint("BOTTOMLEFT", self.board.frame, "TOPLEFT", 0, TALLY_GAP)
  self.tallies[2]:SetPoint("TOPLEFT", self.board.frame, "BOTTOMLEFT", 0, -TALLY_GAP)

  self.note = Widgets.Label(stage, "GameFontHighlightSmall")
  self.note:SetPoint("BOTTOMRIGHT", self.board.frame, "TOPRIGHT", 0, TALLY_GAP + 4)
  self.note:SetTextColor(unpack(Widgets.GOLD))

  self.play = Widgets.Button(stage, L["backgammon_play"], BUTTON_WIDTH, TALLY_HEIGHT)
  self.play:SetPoint("TOPRIGHT", self.board.frame, "BOTTOMRIGHT", 0, -TALLY_GAP)
  self.play:SetScript("OnClick", function()
    self.sent = true
    self.view.submit(moveName(self.steps))
    self.sent = nil
  end)
  self.undo = Widgets.Button(stage, L["backgammon_undo"], BUTTON_WIDTH, TALLY_HEIGHT)
  self.undo:SetPoint("RIGHT", self.play, "LEFT", -4, 0)
  self.undo:SetScript("OnClick", function()
    self:takeBack()
  end)
  return self
end

--- A checker in hand was put somewhere it can go
--- @param from number Square
--- @param to number Square
--- @param dropped boolean
function View:step(from, to, dropped)
  local path = self.paths[to]
  if not path then
    return
  end
  local via = {}
  for index, made in ipairs(path) do
    self.steps[#self.steps + 1] = made
    if index < #path then
      via[#via + 1] = self:landingSquare(made.to)
    end
  end
  self:draw()
  if not dropped then
    self.board:Glide(to, from, via)
  end
  private.Widgets.PlaySound(MOVE_SOUND)
end

--- Takes back the checker moved last in the turn being put together
function View:takeBack()
  if #self.steps > 0 then
    self.steps[#self.steps] = nil
    self.board:StopGlides()
    self:draw()
  end
end

--- @param width number
--- @param height number
function View:Layout(width, height)
  local board = self.board
  board:SetSize(width, height - 2 * (TALLY_HEIGHT + TALLY_GAP))
  for _, tally in ipairs(self.tallies) do
    tally:SetWidth(board.cell * WIDTH / 2)
  end
  if self.view then
    self:showDice()
  end
end

--- Puts the roll that is being played on the table, with the dice already used up told apart
function View:showDice()
  local view, board = self.view, self.board
  --- @type BackgammonState
  local state = view.state
  -- A game that is over has no roll left to play, looking back through one shows them as they fell
  if state.outcome ~= nil or (view.live and view.match.status ~= "active") then
    self.dice:Hide()
    return
  end
  local shown = rolls(state.dice)

  -- Which of them the turn so far has used. Either die may have borne a checker off: say the
  -- one that leaves the most to go on with
  local left = {}
  if state.turn == view.seat and #self.steps > 0 then
    local lefts = follow(scratch(state), state.turn, rolls(state.dice), self.steps)
    for _, die in ipairs(lefts[1] or {}) do
      left[die] = (left[die] or 0) + 1
    end
  else
    for _, die in ipairs(shown) do
      left[die] = (left[die] or 0) + 1
    end
  end
  local spent = {}
  for index, die in ipairs(shown) do
    spent[index] = (left[die] or 0) == 0
    if not spent[index] then
      left[die] = left[die] - 1
    end
  end

  -- In the roller's half, thrown in from its far end
  local cell = board.cell
  local mine = state.turn == view.seat
  local centre = EDGE + HOME / 2 + (mine and HOME + BAR_WIDTH or 0)
  local hand = mine and EDGE + 2 * HOME + BAR_WIDTH - HAND or EDGE + HAND
  self.dice:Show({
    key = view.match.id .. ":" .. view.ply,
    faces = shown,
    color = DISCS[state.turn],
    x = centre * cell,
    y = HEIGHT / 2 * cell,
    from = { x = hand * cell, y = HEIGHT / 2 * cell },
    size = DIE_SIZE * cell,
    gap = DIE_GAP * cell,
    thrown = 2,
    spent = spent,
    glow = #shown > 2,
  })
end

--- A new roll on the table is thrown: by the player, when it is theirs to play, or for the
--- opponent as their roll comes in
--- @param event BackgammonEvent?
function View:throwDice(event)
  local view = self.view
  local roll = self.dice.roll
  local key = roll and roll.key
  if key == self.rolled then
    return
  end
  self.rolled = key
  if not key or not view.live then
    return
  end
  if view.state.turn == view.seat and view.canMove then
    if not self.thrown[key] then
      self.dice:Hold(function()
        self.thrown[key] = true
        self.board:SetEnabled(self.view.canMove)
      end)
    end
  elseif event then
    self.dice:Throw(THROW_DELAY)
  end
end

--- Puts the position on the table, with as much of the player's turn as they have made
function View:draw()
  local view = self.view
  --- @type BackgammonState
  local state = view.state
  local board, seat = self.board, view.seat

  if view.canMove then
    self.options, self.position = continuations(state, self.steps)
  else
    self.options, self.position = {}, state
  end
  local position = self.position

  local pieces, labels = {}, {}
  for _, owner in ipairs({ seat, other(seat) }) do
    local mine = owner == seat
    for point = 1, POINTS do
      local count = position.points[owner][point]
      local shown = mine and point or BAR - point
      for slot = 1, math.min(count, STACK) do
        pieces[squareOf(shown, slot, true)] = DISCS[owner]
      end
      if count > STACK then
        labels[squareOf(shown, STACK, true)] = count
      end
    end
    for _, place in ipairs({ { BAR, position.bar[owner], 1 }, { OFF, position.off[owner], 0 } }) do
      if place[2] > 0 then
        pieces[squareOf(place[1], 1, mine)] = DISCS[owner]
        labels[squareOf(place[1], 1, mine)] = place[2] > place[3] and place[2] or nil
      end
    end
  end
  board:SetPieces(pieces, private.Board.Disc)
  board:SetLabels(labels)

  -- Where the last move went, until the player starts on their own
  local tints = {}
  if state.last and #self.steps == 0 then
    local mine = state.last.seat == seat
    for _, made in ipairs(state.last.steps) do
      if made.to ~= OFF then
        local point = mine and made.to or BAR - made.to
        local own, theirs = self:countOn(point)
        tints[squareOf(point, own + theirs, true)] = LAST_MOVE
      end
    end
  end
  board:SetTints(tints)
  self:showDice()

  for index, owner in ipairs({ other(seat), seat }) do
    local name = owner == seat and L["backgammon_you"] or view.names[owner]
    local text = L["backgammon_pips"]:format(name, pips(position, owner))
    self.tallies[index]:Set(private.Board.Disc(DISCS[owner], TALLY_HEIGHT), text)
  end

  local skipped = state.skipped[#state.skipped]
  if skipped and (view.live or view.catching) then
    local name = skipped.seat == seat and L["backgammon_you"] or view.names[skipped.seat]
    self.note:SetText(L["backgammon_skipped"]:format(name, skipped.dice[1], skipped.dice[2]))
  else
    self.note:SetText("")
  end

  self.undo:SetShown(view.canMove)
  self.play:SetShown(view.canMove)
  self.undo:SetEnabled(#self.steps > 0)
  self.play:SetEnabled(#self.steps == state.playable)
end

--- Shows a move being made: every checker glides to where it went, by way of where it touched
--- down, and what was hit goes to the bar
--- @param event BackgammonEvent
function View:animate(event)
  local board = self.board
  local mine = event.seat == self.view.seat

  --- @param point number In the mover's numbers
  --- @return number point In the local player's
  local function seen(point)
    return (mine or point == BAR or point == OFF) and point or BAR - point
  end

  -- A checker moved by both dice is one journey
  local journeys = {}
  for _, made in ipairs(event.steps) do
    local journey
    for _, earlier in ipairs(journeys) do
      if earlier[#earlier] == made.from then
        journey = earlier
        break
      end
    end
    if not journey then
      journey = { made.from }
      journeys[#journeys + 1] = journey
    end
    journey[#journey + 1] = made.to
    if made.hit then
      board:Glide(mine and THEIR_BAR or MY_BAR, squareOf(seen(made.to), 1, true))
    end
  end

  -- Checkers that end up on the same point come to rest one on top of the other
  local landed = {}
  for index = #journeys, 1, -1 do
    local journey = journeys[index]
    local squares = {}
    for stop, point in ipairs(journey) do
      local shown = seen(point)
      local own, theirs = 0, 0
      if point ~= BAR and point ~= OFF then
        own, theirs = self:countOn(shown)
      end
      local height = own + theirs
      if stop == #journey then
        height = height - (landed[point] or 0)
        landed[point] = (landed[point] or 0) + 1
      elseif stop == 1 then
        height = height + 1
      end
      squares[stop] = squareOf(shown, height, mine)
    end
    local to, from = table.remove(squares), table.remove(squares, 1)
    board:Glide(to, from, squares)
  end
end

--- @param view GameView
function View:Update(view)
  self.view = view
  local board = self.board
  if view.changed or not view.canMove then
    -- A turn that was being put together belonged to the position that was showing
    self.steps = {}
  end
  if view.changed then
    board:Select(nil)
    board:StopGlides()
  end
  self:draw()

  --- @type BackgammonEvent?
  local event = view.played
  if event then
    if not self.sent then
      self:animate(event)
    end
    private.Widgets.PlaySound(MOVE_SOUND)
  end
  self:throwDice(event)
  -- Nothing to play before the dice are out of the hand
  board:SetEnabled(view.canMove and not self.dice:Holding())
end

private.Games.Register({
  id = "backgammon",
  name = L["game_backgammon"],
  description = L["game_backgammon_description"],
  genre = "dice",
  icon = IMAGES .. "Icons\\backgammon",
  version = 1,
  seats = 2,
  howto = {
    { heading = L["howto_goal"], text = L["backgammon_howto_goal"] },
    { heading = L["howto_turn"], text = L["backgammon_howto_turn"] },
    { heading = L["backgammon_howto_roll"], text = L["backgammon_howto_roll_text"] },
    { heading = L["backgammon_howto_hitting"], text = L["backgammon_howto_hitting_text"] },
    { heading = L["backgammon_howto_off"], text = L["backgammon_howto_off_text"] },
    { heading = L["howto_end"], text = L["backgammon_howto_end"] },
  },
  newState = newState,
  turn = function(state)
    return state.turn
  end,
  validate = validate,
  apply = apply,
  moves = everyTurn,
  result = function(state)
    return state.outcome
  end,
  computer = COMPUTER,
  createView = createView,
  seatLabel = function(seat)
    return seat == WHITE and L["backgammon_white"] or L["backgammon_red"]
  end,
  -- Not the engine's business: for the tests, which play whole games and set positions up
  rules = { continuations = continuations, assess = assess },
})
