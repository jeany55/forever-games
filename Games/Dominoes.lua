--------------------------
--  Dominoes
--------------------------
-- The Block game for two with a double-six set, and the Draw game as an option. The twenty-eight
-- tiles are washed face down and each player draws seven. The rest stay face down in the
-- boneyard. In turn each player lays a tile on one of the two open ends of the line of play,
-- touching an end of the same number. A player who can't lay one passes (knocks); in the Draw
-- game they first draw from the boneyard until they can, and pass only once it is empty.
--
-- A hand ends when somebody lays their last tile ("domino!"), who then scores the pips left in
-- the other's hand, or when neither can lay one and it is blocked: then whoever holds fewer pips
-- scores the other's, and as many each scores nobody anything. Hands are played until somebody
-- has the target, a hundred points unless the rules say otherwise; with a target of nought there
-- is the one hand. The first hand is begun by whoever holds the biggest double, with it. Every
-- hand after that by whoever won the one before, with any tile.
--
-- Passing takes no deciding, so the game does it: after every move, a player who can do nothing
-- has passed, and it is the other's turn again. Every move is a tile laid, or drawing.
--
-- A move is the tile laid and the end it goes on, "35r" for the three-five on the right end,
-- "66" for a tile that begins the line, or "d" to draw. Tiles are written as Engine/Bones.lua has
-- them, the fewer pips first. Nobody sees the other's hand or the boneyard: `visible` leaves
-- them backs, and nothing the game says about a move names a tile that wasn't shown until the
-- hand is over and both hands are laid open to be counted.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Bones = private.Bones
local Tables = private.Tables

local TOP = Bones.SIX
local DEALT = 7
local DRAW = "d"
local LEFT, RIGHT = Bones.LEFT, Bones.RIGHT
local HIDDEN = Bones.HIDDEN

--- @class DominoesState
--- @field hands string[][] Tiles by seat
--- @field yard string[] The boneyard, face down: the next tile drawn is the last
--- @field line BonesLine
--- @field turn number
--- @field scores number[] Points by seat, from the hands before this one
--- @field target number Points that win, 0 for a game of one hand
--- @field draw boolean? The Draw game: a player who can't lay a tile draws from the boneyard
--- @field hand number Which hand this is, from 1
--- @field leader number Who began this hand
--- @field lead string? The tile the line has to begin with: the biggest double, in the first hand
--- @field void table<number, boolean>[] By seat, the numbers they passed on and so are known to have none of, until they draw
--- @field outcome { winner: number, detail: string? }?

--- How a hand ended: laid open for everyone, as it was before the next was dealt
--- @class DominoesEnding
--- @field reason string "domino" or "blocked"
--- @field winner number 0 for a blocked hand nobody won
--- @field points number What the winner scored
--- @field pips number[] Left in each hand, by seat
--- @field hands string[][] Left in each hand
--- @field line BonesLine The line of play as it was at the end

--- @class DominoesEvent: MatchEvent
--- @field tile string? The tile laid
--- @field side string? The end it went on, nil for the first in the line
--- @field laid string? How it lies there, the end laid against first
--- @field drew number? Tiles drawn from the boneyard instead. Which ones is nobody else's business
--- @field knocked number[]? Who couldn't play after it, in turn, and passed
--- @field ended DominoesEnding? The hand is over
--- @field dealt boolean? And the next one has been dealt

-----------------------------
-- Rules
-----------------------------

--- @param seat number
--- @return number
local function other(seat)
  return 3 - seat
end

--- Whether a seat has a tile it could lay
--- @param state DominoesState
--- @param seat number
--- @return boolean
local function canLay(state, seat)
  return Bones.AnyFits(state.line, state.hands[seat])
end

--- Whether a seat can do anything but pass: lay a tile, or draw for one
--- @param state DominoesState
--- @param seat number
--- @return boolean
local function canAct(state, seat)
  return canLay(state, seat) or (state.draw == true and #state.yard > 0)
end

--- Washes the tiles and deals a hand
--- @param state DominoesState
--- @param random Random
--- @param leader number? Who begins it. Whoever holds the biggest double if left out, with it
local function deal(state, random, leader)
  local yard = Bones.Shuffled(random, TOP)
  state.hands = { {}, {} }
  Bones.Deal(yard, state.hands, DEALT)
  state.yard, state.line, state.void = yard, Bones.NewLine(), { {}, {} }
  if leader then
    state.lead = nil
  else
    leader, state.lead = Bones.Opener(state.hands)
  end
  state.turn, state.leader = leader, leader
end

--- @param seats number
--- @param random Random
--- @param rules table<string, any>
--- @return DominoesState
local function newState(seats, random, rules)
  --- @type DominoesState
  local state = { scores = { 0, 0 }, target = rules.target or 100, draw = rules.draw or nil, hand = 1 }
  deal(state, random)
  return state
end

--- What a move is: the tile and the end, "" for none
--- @param move string
--- @return string? tile, string? side
local function parse(move)
  local tile, side = move:match("^(..)([lr]?)$")
  if not tile or not Bones.IsTile(tile, TOP) then
    return nil, nil
  end
  return tile, side
end

--- @param state DominoesState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  if seat ~= state.turn then
    return false, "not_your_turn"
  end
  if move == DRAW then
    if not state.draw or #state.yard == 0 then
      return false, "dominoes_cant_draw"
    elseif canLay(state, seat) then
      return false, "dominoes_can_lay"
    end
    return true
  end
  local tile, side = parse(move)
  if not tile or not Bones.Find(state.hands[seat], tile) then
    return false, "invalid_move"
  end
  if not state.line.first then
    if side ~= "" then
      return false, "invalid_move"
    elseif state.lead and tile ~= state.lead then
      return false, "dominoes_lead"
    end
    return true
  end
  if side == "" then
    return false, "invalid_move"
  end
  local left, right = Bones.Fits(state.line, tile)
  if (side == LEFT and not left) or (side == RIGHT and not right) then
    return false, "dominoes_doesnt_fit"
  end
  return true
end

--- Every tile that can be laid and where, or drawing. A tile that would go on either end of a
--- line whose two ends are the same is listed on the right only: it comes to the same
--- @param state DominoesState
--- @param seat number
--- @return string[]
local function moves(state, seat)
  local list = {}
  local line = state.line
  if not line.first then
    if state.lead then
      return { state.lead }
    end
    for _, tile in ipairs(state.hands[seat]) do
      list[#list + 1] = tile
    end
    return list
  end
  local leftEnd, rightEnd = Bones.LineEnds(line)
  for _, tile in ipairs(state.hands[seat]) do
    local left, right = Bones.Fits(line, tile)
    if left and leftEnd ~= rightEnd then
      list[#list + 1] = tile .. LEFT
    end
    if right then
      list[#list + 1] = tile .. RIGHT
    end
  end
  if #list == 0 and state.draw and #state.yard > 0 then
    list[1] = DRAW
  end
  return list
end

--- Scores a hand that is over and deals the next, unless somebody has won
--- @param state DominoesState
--- @param random Random
--- @param reason string "domino" or "blocked"
--- @param seat number? Who laid their last tile
--- @param event DominoesEvent
local function endHand(state, random, reason, seat, event)
  local pips = { Bones.Count(state.hands[1]), Bones.Count(state.hands[2]) }
  local winner = seat
  if not winner then
    winner = pips[1] < pips[2] and 1 or (pips[2] < pips[1] and 2 or 0)
  end
  local points = winner > 0 and pips[other(winner)] or 0
  event.ended = {
    reason = reason,
    winner = winner,
    points = points,
    pips = pips,
    hands = { { unpack(state.hands[1]) }, { unpack(state.hands[2]) } },
    line = Bones.CopyLine(state.line),
  }
  if winner > 0 then
    state.scores[winner] = state.scores[winner] + points
  end
  if state.target == 0 then
    state.outcome = { winner = winner, detail = winner == 0 and "blocked" or nil }
    return
  elseif winner > 0 and state.scores[winner] >= state.target then
    state.outcome = { winner = winner }
    return
  end
  -- A hand nobody won is begun by the other player this time
  state.hand = state.hand + 1
  deal(state, random, winner > 0 and winner or other(state.leader))
  event.dealt = true
end

--- A player can't lay a tile and passes: they have none of either end's number
--- @param state DominoesState
--- @param seat number
--- @param event DominoesEvent
local function knock(state, seat, event)
  local left, right = Bones.LineEnds(state.line)
  state.void[seat][left], state.void[seat][right] = true, true
  event.knocked = event.knocked or {}
  event.knocked[#event.knocked + 1] = seat
end

--- After a move: whoever can do nothing passes, and once neither can the hand is blocked
--- @param state DominoesState
--- @param random Random
--- @param seat number Who moved
--- @param event DominoesEvent
--- @param stuck boolean? The one who moved has passed already, having drawn the boneyard dry
local function settle(state, random, seat, event, stuck)
  for _, next in ipairs(stuck and { other(seat) } or { other(seat), seat }) do
    if canAct(state, next) then
      state.turn = next
      return
    end
    knock(state, next, event)
  end
  endHand(state, random, "blocked", nil, event)
end

--- How a move is written in the list of moves
--- @param event DominoesEvent
--- @return string
local function notation(event)
  local parts = {}
  if event.drew then
    parts[1] = L["dominoes_notation_drew"]:format(event.drew)
  else
    local a, b = Bones.Ends(event.tile)
    local tile = a .. "|" .. b
    parts[1] = event.side and L["dominoes_notation_" .. event.side]:format(tile) or tile
  end
  if event.knocked then
    parts[#parts + 1] = L["dominoes_notation_pass"]
  end
  if event.ended then
    parts[#parts + 1] = L["dominoes_notation_" .. event.ended.reason]
  end
  return table.concat(parts, ", ")
end

--- @param state DominoesState
--- @param seat number
--- @param move string
--- @param random Random
--- @return DominoesEvent
local function apply(state, seat, move, random)
  local hand = state.hands[seat]
  --- @type DominoesEvent
  local event = {}
  if move == DRAW then
    local drawn = 0
    repeat
      hand[#hand + 1] = table.remove(state.yard)
      drawn = drawn + 1
    until #state.yard == 0 or canLay(state, seat)
    -- Whatever they passed on before, they may well hold it now
    state.void[seat] = {}
    event.drew = drawn
    if not canLay(state, seat) then
      knock(state, seat, event)
      settle(state, random, seat, event, true)
    end
  else
    local tile, side = parse(move)
    table.remove(hand, Bones.Find(hand, tile))
    event.tile, event.side = tile, side ~= "" and side or nil
    event.laid = Bones.Lay(state.line, tile, event.side)
    state.lead = nil
    if #hand == 0 then
      endHand(state, random, "domino", seat, event)
    else
      settle(state, random, seat, event)
    end
  end
  event.notation = notation(event)
  return event
end

--- What a player may see: their own hand and the line. Of the other hand and the boneyard, only
--- how many tiles there are
--- @param state DominoesState
--- @param seat number
--- @return DominoesState
local function visible(state, seat)
  local seen = Tables.Shallow(state)
  seen.hands, seen.yard = {}, Bones.Backs(#state.yard)
  for owner, hand in ipairs(state.hands) do
    seen.hands[owner] = owner == seat and { unpack(hand) } or Bones.Backs(#hand)
  end
  return seen
end

-----------------------------
-- The computer
-----------------------------
-- It sees what anyone at the table would, its own hand and the line, and guesses at the rest:
-- the tiles it hasn't seen dealt out between the other hand and the boneyard, as many to each
-- as there are. A number the other player passed on isn't in their hand, unless they have drawn
-- since, so it deals them none. It plays its hand against a few such guesses and does whatever
-- comes out best over all of them.
--
-- What it wants is fewer tiles and fewer pips than the other player, and more tiles that can be
-- laid than they have: the heavy ones gone early, ends left open that it can follow and they
-- can't. The points matter most of all.
--
-- At its easiest it is a beginner, who lays whatever fits, more often the first tile they see
-- that does than not, and never thinks about what the other player holds.
--
-- Played to 100 against each other (lua Tools/DominoesBench.lua): medium beats easy 82% of the
-- time, hard beats medium 60% and easy 90%. In the Draw game medium beats easy 88%. A hand is
-- mostly the tiles dealt, so even a beginner wins now and then.

-- What a point scored is worth, a tile and a pip held, and a tile that can be laid now
local POINT, TILE, PIP, OPEN = 6, 18, 2, 5
-- How often a beginner lays the first tile in their hand that fits, rather than any that does
local FIRST_FIT = 0.6

--- How well a seat stands
--- @param state DominoesState
--- @param seat number
--- @return number
local function standing(state, seat)
  local them = other(seat)
  local mine, theirs = state.hands[seat], state.hands[them]
  local score = POINT * (state.scores[seat] - state.scores[them])
  score = score + TILE * (#theirs - #mine) + PIP * (Bones.Count(theirs) - Bones.Count(mine))
  if state.line.first then
    local open = 0
    for _, tile in ipairs(mine) do
      local left, right = Bones.Fits(state.line, tile)
      open = open + ((left or right) and 1 or 0)
    end
    for _, tile in ipairs(theirs) do
      local left, right = Bones.Fits(state.line, tile)
      open = open - ((left or right) and 1 or 0)
    end
    score = score + OPEN * open
  end
  return score
end

--- @param state DominoesState
--- @return DominoesState
local function copy(state)
  local world = Tables.Shallow(state)
  world.hands = { { unpack(state.hands[1]) }, { unpack(state.hands[2]) } }
  world.yard, world.line, world.scores = { unpack(state.yard) }, Bones.CopyLine(state.line), { unpack(state.scores) }
  world.void = { Tables.Shallow(state.void[1]), Tables.Shallow(state.void[2]) }
  return world
end

--- The whole table as it could be, from what a seat sees of it
--- @param seen DominoesState
--- @param seat number
--- @param random Random
--- @return DominoesState
local function guess(seen, seat, random)
  local them = other(seat)
  local void = seen.void[them]
  local unseen = random:Shuffle(Bones.Unseen(TOP, seen.hands[seat], Bones.LineTiles(seen.line)))
  -- The tiles they could hold first, the ones they can't only if there aren't enough
  local could, couldnt = {}, {}
  for _, tile in ipairs(unseen) do
    local a, b = Bones.Ends(tile)
    local list = (void[a] or void[b]) and couldnt or could
    list[#list + 1] = tile
  end
  local world = copy(seen)
  local theirs = {}
  for index = 1, #seen.hands[them] do
    theirs[index] = table.remove(could) or table.remove(couldnt)
  end
  world.hands[them] = theirs
  for _, tile in ipairs(couldnt) do
    could[#could + 1] = tile
  end
  random:Shuffle(could)
  world.yard = {}
  for index = 1, #seen.yard do
    world.yard[index] = could[index]
  end
  return world
end

--- A beginner's move: whatever fits, as often as not the first tile they see that does
--- @param seen DominoesState
--- @param seat number
--- @param brain Brain
--- @return string
local function beginner(seen, seat, brain)
  local list = moves(seen, seat)
  if brain.random:Roll(100) <= FIRST_FIT * 100 then
    return list[1]
  end
  return list[brain.random:Roll(#list)]
end

local COMPUTER = {
  evaluate = standing,
  guess = guess,
  copy = copy,
  priority = function(state, move)
    if move == DRAW then
      return -1
    end
    -- Doubles and heavy tiles first: they are the hardest to get rid of later
    local tile = move:sub(1, 2)
    return Bones.Pips(tile) + (Bones.IsDouble(tile) and 6 or 0)
  end,
  think = function(seen, seat, brain)
    if brain.level.beginner then
      return beginner(seen, seat, brain)
    end
    return (brain:Search(seen))
  end,
  levels = {
    easy = { beginner = true },
    medium = { depth = 2, budget = 1500, samples = 4, slip = 0.1, among = 2 },
    hard = { depth = 4, budget = 9000, samples = 10, slip = 0 },
  },
}

-----------------------------
-- View
-----------------------------
-- A table covered in felt (GUI/Felt.lua) with the line of play laid out in the middle of it
-- (GUI/Dominoes.lua), the player's own hand standing along the bottom and the other's, backs
-- to the player, along the top. The boneyard lies face down at the right, and each player's
-- points are at the left by their hand.
--
-- The tiles the player can lay stand up out of their hand. Pointing at one shows, faintly,
-- where it would go. Clicking it lays it there, or where there are two ends it would go on, it
-- is taken in hand and the end is clicked; or it is dragged to an end. With nothing to lay in
-- the Draw game, the boneyard is clicked to draw from.
--
-- Every tile is always somewhere on the table, the twenty-eight of them in the line, the hands
-- and the boneyard, and each one on screen is the same tile wherever it goes: a tile laid flies
-- from the hand into the line, turning to lie the way it goes there, and the rest of the line
-- moves over to make room. At the end of a hand the other player's tiles are turned over and
-- counted, and the points go to whoever won it. Before the next hand the tiles are washed, face
-- down in the middle, and drawn again.
--
-- What is on screen is planned from scratch for every position, each tile under a name of its
-- own: "m35" for the three-five in the player's own hand, "t3" for the third of the other's,
-- "l35" for the three-five in the line, "y7" for the seventh in the boneyard. A move says which
-- names it took tiles from and to, and those fly; anything else that moved slides.

-- The table's own felt, a deep green
local FELT = { 0.05, 0.19, 0.13, 1 }
-- The bands across the bottom and the top for the hands, as parts of the stage's height and no
-- more than so many pixels, and the column at the left for the points
local MINE_SHARE, MINE_MOST = 0.25, 160
local THEIRS_SHARE, THEIRS_MOST = 0.14, 70
local SCORE_WIDTH, SCORE_HEIGHT, MARGIN = 104, 42, 10
-- How much of a hand's band its tiles stand in, and the room between two of them, as a part of
-- the width of one
local STANDING, HAND_GAP = 0.84, 0.2
-- How big a tile in the line and in the boneyard is at most, next to one in the player's hand,
-- and how much of the line's room it may fill
local LINE_SCALE, YARD_SCALE, LINE_ROOM = 0.74, 0.58, 0.92
-- How far a tile that can be played stands up out of the hand, and one pointed at, in its widths
local READY_RISE, POINTED_RISE = 0.16, 0.42
-- A line tile is drawn a little smaller than its place, for a seam between it and the next
local SEAM = 0.965
-- Room above the line for what the game is played to, and below it for what is going on
local INFO_HEIGHT, NOTE_HEIGHT = 18, 22
-- Seconds: a tile flying, everything else moving out of its way, tiles drawn one after another,
-- the other's hand turned over at the end, and the wash and the deal
local FLY, SLIDE, DRAW_GAP = 0.42, 0.3, 0.12
local REVEAL, REVEAL_GAP, REVEAL_AFTER = 0.32, 0.09, 0.45
local GATHER, SWIRL, DEAL, DEAL_GAP = 0.45, 0.5, 0.34, 0.045
-- How long a summary stays up while the player is being shown what they missed
local CATCHING_SUMMARY = 2.5
-- Lights: a tile that can be laid, one taken in hand, where it can go, the last tile laid and
-- a boneyard to draw from
local PLAYABLE = { 1, 0.78, 0.3, 0.5 }
local CHOSEN = { 1, 0.9, 0.5, 0.95 }
local GHOST = { 0.45, 1, 0.55, 0.9 }
local LAST = { 1, 1, 0.85, 0.32 }
local DRAWABLE = { 1, 0.8, 0.3, 0.7 }
-- How see-through the tile showing where one would go is
local GHOST_ALPHA = 0.55
-- Where the first tile of a hand goes, in the middle, for the ghost of it
local FIRST = "first"
local SOUNDS = {
  lay = "dominoesClack",
  draw = "dominoesSlide",
  wash = "dominoesWash",
  knock = "dominoesKnock",
  win = "dominoesWin",
}
local WON_COLOR, LOST_COLOR = { 1, 0.82, 0.2 }, { 0.85, 0.85, 0.85 }
-- Hands the player has watched being dealt, by match and hand: once is enough
local dealt = {}

--- What there is to show of a hand: from the position, or from the end of the hand before it
--- @class DominoesShown
--- @field line BonesLine
--- @field mine string[] The player's own tiles, in the order they came
--- @field theirs string[] The other's, their backs while they are hidden
--- @field yard number Tiles in the boneyard

--- How a tile is to be shown under a name
--- @class DominoesSpec
--- @field tile string
--- @field place DominoPlace
--- @field dim boolean?
--- @field light number[]?
--- @field breathe boolean?
--- @field rise number?

--- @class DominoesView: GameViewObject
--- @field stage Frame
--- @field view GameView?
--- @field at table<string, Domino> The tiles on the table, by name
--- @field spare Domino[] Tiles that aren't anywhere
--- @field shown DominoesShown? What the table shows
--- @field animator table
--- @field pointed string? The name of the tile pointed at
--- @field chosen string? The tile taken in hand to be laid on an end the player has yet to click
local View = {}
View.__index = View

--- @param tile string
--- @return string "3|5"
local function written(tile)
  local a, b = Bones.Ends(tile)
  return a .. "|" .. b
end

--- @param stage Frame
--- @return DominoesView
local function createView(stage)
  local Widgets = private.Widgets
  --- @type DominoesView
  local self = setmetatable({ stage = stage, at = {}, spare = {}, ghosts = {}, catches = {}, width = 0, height = 0 }, View)

  local felt = stage:CreateTexture(nil, "BACKGROUND")
  felt:SetAllPoints()
  private.Felt.Paint(felt, FELT)
  -- A little light on the middle of the table, and the edges in shadow
  local glow = stage:CreateTexture(nil, "BACKGROUND", nil, 1)
  glow:SetTexture("Interface\\AddOns\\ForeverGames\\Images\\Dominoes\\table")
  glow:SetAllPoints()

  self.animator = Widgets.Animator(stage)
  -- Its own, for tiles standing up and sitting down again under the pointer, which mustn't be
  -- put an end to when a move is shown
  local hovering = CreateFrame("Frame", nil, stage)
  self.hovering = Widgets.Animator(hovering)

  self.scores = {}
  for index = 1, 2 do
    local stat = Widgets.Stat(stage, "", SCORE_WIDTH, SCORE_HEIGHT)
    stat:SetFrameLevel(stage:GetFrameLevel() + 5)
    self.scores[index] = stat
  end
  self.info = Widgets.Label(stage, "GameFontDisableSmall")
  self.info:SetJustifyH("CENTER")
  self.note = Widgets.Label(stage, "GameFontHighlight")
  self.note:SetJustifyH("CENTER")
  self.note:SetTextColor(unpack(Widgets.GOLD))
  self.yardLabel = Widgets.Label(stage, "GameFontDisableSmall")
  self.yardLabel:SetJustifyH("CENTER")
  self.counts = { Widgets.Label(stage, "GameFontHighlightSmall"), Widgets.Label(stage, "GameFontHighlightSmall") }

  -- Where a tile taken in hand is put down, over where it would go at each end
  self.drag = private.Drag.New(stage)
  self.puppet = private.Dominoes.New(self.drag.frame)
  -- Drag puts it wherever the pointer is
  self.puppet.loose = true
  for index = 1, 2 do
    local ghost = private.Dominoes.New(stage)
    local catch = CreateFrame("Frame", nil, stage)
    ghost.frame:SetFrameLevel(stage:GetFrameLevel() + 8)
    ghost.frame:SetAlpha(GHOST_ALPHA)
    ghost.frame:SetScript("OnClick", function()
      if self.chosen then
        self:lay(self.chosen, catch.side ~= FIRST and catch.side or nil)
      end
    end)
    self.ghosts[index] = ghost
    self.catches[index] = catch
    self.drag:AddTarget({
      region = catch,
      spot = function(tile)
        local side = catch.side
        return catch:IsShown() and self:fits(tile, side ~= FIRST and side or nil) and side or nil
      end,
      onHover = function(tile, spot)
        self:hoverEnd(tile, spot and index or nil)
      end,
      onDrop = function(tile, spot)
        self:lay(tile, spot ~= FIRST and spot or nil, true)
      end,
    })
  end

  self.summary = Widgets.Panel(stage)
  self.summary:SetFrameLevel(stage:GetFrameLevel() + 30)
  self.summary:SetBackdropColor(0.03, 0.06, 0.05, 0.92)
  self.summary:SetBackdropBorderColor(1, 0.82, 0, 0.45)
  self.summary.title = self.summary:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
  self.summary.title:SetPoint("TOP", 0, -14)
  self.summary.detail = Widgets.Label(self.summary, "GameFontHighlight")
  self.summary.detail:SetJustifyH("CENTER")
  self.summary.detail:SetPoint("TOP", self.summary.title, "BOTTOM", 0, -8)
  self.summary.points = Widgets.Label(self.summary, "GameFontNormal")
  self.summary.points:SetJustifyH("CENTER")
  self.summary.points:SetPoint("TOP", self.summary.detail, "BOTTOM", 0, -6)
  self.summary.next = Widgets.Button(self.summary, L["dominoes_next_hand"], 120, 24)
  self.summary.next:SetPoint("BOTTOM", 0, 12)
  self.summary.next:SetScript("OnClick", function()
    self:closeSummary(true)
  end)
  self.summary:Hide()

  self.effects = private.Effects.New(stage)
  return self
end

--- @param width number
--- @param height number
function View:Layout(width, height)
  self.width, self.height = width, height
  local mineBand = math.max(56, math.min(MINE_MOST, height * MINE_SHARE))
  local theirsBand = math.max(32, math.min(THEIRS_MOST, height * THEIRS_SHARE))
  self.mineBand, self.theirsBand = mineBand, theirsBand
  self.mineUnit = mineBand * STANDING / 2
  self.theirsUnit = theirsBand * STANDING / 2
  self.yardUnit = self.mineUnit * YARD_SCALE
  self.yardWidth = 5 * self.yardUnit
  -- The room for the line, between the hands and between the points and the boneyard
  local left, right = SCORE_WIDTH + MARGIN, width - self.yardWidth - MARGIN
  local top, bottom = theirsBand + INFO_HEIGHT, height - mineBand - NOTE_HEIGHT
  self.room = {
    x = (left + right) / 2,
    y = (top + bottom) / 2,
    width = (right - left) * LINE_ROOM,
    height = (bottom - top) * LINE_ROOM,
  }
  self.lineMost = self.mineUnit * LINE_SCALE
  self.across = math.max(8, math.floor(self.room.width / self.lineMost) - 1)

  self.scores[1]:ClearAllPoints()
  self.scores[1]:SetPoint("LEFT", self.stage, "TOPLEFT", MARGIN, -height + mineBand / 2)
  self.scores[2]:ClearAllPoints()
  self.scores[2]:SetPoint("LEFT", self.stage, "TOPLEFT", MARGIN, -theirsBand / 2)
  self.info:ClearAllPoints()
  self.info:SetPoint("TOP", self.stage, "TOPLEFT", self.room.x, -theirsBand - 3)
  self.note:ClearAllPoints()
  self.note:SetPoint("BOTTOM", self.stage, "BOTTOMLEFT", self.room.x, mineBand + 4)
  self.note:SetWidth(right - left)
  self.yardLabel:ClearAllPoints()
  local yardX, yardBelow = width - self.yardWidth / 2 - MARGIN / 2, (top + bottom) / 2 + 4.6 * self.yardUnit
  self.yardLabel:SetPoint("TOP", self.stage, "TOPLEFT", yardX, -yardBelow)
  self.summary:SetSize(math.min(340, right - left), 140)
  self.summary:ClearAllPoints()
  self.summary:SetPoint("CENTER", self.stage, "TOPLEFT", self.room.x, -self.room.y)

  if self.view and self.shown then
    self.animator:Stop()
    self:arrange(self.shown, nil, true)
  end
end

-----------------------------
-- What the table shows
-----------------------------

--- @param state DominoesState
--- @param seat number
--- @return DominoesShown
local function shownFrom(state, seat)
  return { line = state.line, mine = state.hands[seat], theirs = state.hands[other(seat)], yard = #state.yard }
end

--- What was on the table when a hand ended, the other's tiles still face down unless `open`
--- @param ending DominoesEnding
--- @param seat number
--- @param open boolean?
--- @return DominoesShown
local function shownAtEnd(ending, seat, open)
  local theirs = ending.hands[other(seat)]
  local yard = #Bones.Set(TOP) - Bones.LineLength(ending.line) - #ending.hands[1] - #ending.hands[2]
  return { line = ending.line, mine = ending.hands[seat], theirs = open and theirs or Bones.Backs(#theirs), yard = yard }
end

--- Whether the player may lay a tile right now, and the position they would lay it in
--- @return DominoesState?
function View:playing()
  local view = self.view
  if not view or not view.canMove or self.summary:IsShown() or self.washing or self.ending then
    return nil
  end
  return view.state
end

--- Whether the player could lay a tile on an end right now
--- @param tile string
--- @param side string?
--- @return boolean
function View:fits(tile, side)
  local state = self:playing()
  if not state or not Bones.Find(state.hands[self.view.seat], tile) then
    return false
  end
  if not state.line.first then
    return side == nil and (not state.lead or state.lead == tile)
  end
  local left, right = Bones.Fits(state.line, tile)
  return (side == LEFT and left) or (side == RIGHT and right) or false
end

--- The ends a tile of the player's could go on: none, one or both. A line whose two ends are the
--- same has the tile go on the right
--- @param tile string
--- @return string[]? nil for a tile that can't be laid; an empty list for the first in the line
function View:ends(tile)
  local state = self:playing()
  if not state then
    return nil
  end
  if not state.line.first then
    return self:fits(tile, nil) and {} or nil
  end
  local list = {}
  local leftEnd, rightEnd = Bones.LineEnds(state.line)
  if self:fits(tile, LEFT) and leftEnd ~= rightEnd then
    list[#list + 1] = LEFT
  end
  if self:fits(tile, RIGHT) then
    list[#list + 1] = RIGHT
  end
  return #list > 0 and list or nil
end

--- Where in the room for it a place in the line is, for a line laid out as `fit` says
--- @param spot DominoSpot
--- @param fit table
--- @return DominoPlace
function View:linePlace(spot, fit)
  local room = self.room
  return {
    x = room.x + (spot.x - fit.middleX) * fit.unit,
    y = room.y + (spot.y - fit.middleY) * fit.unit,
    unit = fit.unit * SEAM,
    angle = spot.angle,
  }
end

--- How the line is laid out on the table
--- @param line BonesLine
--- @return DominoSnake snake, table fit
function View:fitLine(line)
  local snake = private.Dominoes.Snake(line, self.across)
  local unit, middleX, middleY = private.Dominoes.Fit(snake.bounds, self.room.width, self.room.height, self.lineMost)
  return snake, { unit = unit, middleX = middleX, middleY = middleY }
end

--- Every tile of what there is to show, by name, where it goes and how it looks
--- @param shown DominoesShown
--- @return table<string, DominoesSpec>
function View:plan(shown)
  local specs = {}
  local width, height = self.width, self.height

  -- The line
  local snake, fit = self:fitLine(shown.line)
  self.fit = fit
  local function inLine(spot)
    if spot then
      specs["l" .. Bones.Tile(Bones.Ends(spot.tile))] = { tile = spot.tile, place = self:linePlace(spot, fit) }
    end
  end
  inLine(snake.first)
  for _, spot in ipairs(snake.left) do
    inLine(spot)
  end
  for _, spot in ipairs(snake.right) do
    inLine(spot)
  end

  -- The hands, standing in a row across the middle of their band
  local function row(tiles, unit, y, prefix, each)
    local count = #tiles
    local room = width - 2 * (SCORE_WIDTH + MARGIN)
    unit = math.min(unit, room / math.max(1, count * (1 + HAND_GAP)))
    local step = unit * (1 + HAND_GAP)
    local first = width / 2 - step * (count - 1) / 2
    for index, tile in ipairs(tiles) do
      local spec = { tile = tile, place = { x = first + (index - 1) * step, y = y, unit = unit, angle = math.pi / 2 } }
      specs[prefix .. (prefix == "m" and tile or index)] = spec
      if each then
        each(spec, tile)
      end
    end
  end
  local mine = Bones.Sort({ unpack(shown.mine) })
  local state = self:playing()
  row(mine, self.mineUnit, height - self.mineBand / 2, "m", function(spec, tile)
    if state then
      local ends = self:ends(tile)
      spec.dim = ends == nil
      if ends then
        spec.light, spec.breathe = self.chosen == tile and CHOSEN or PLAYABLE, self.chosen == tile
        spec.rise = (self.pointed == "m" .. tile or self.chosen == tile) and POINTED_RISE or READY_RISE
      end
    end
  end)
  row(shown.theirs, self.theirsUnit, self.theirsBand / 2, "t")

  -- The boneyard: lying in two untidy columns down the right
  local unit = self.yardUnit
  local drawing = state and state.draw and not Bones.AnyFits(state.line, state.hands[self.view.seat]) and shown.yard > 0
  local jitter = private.Random.New(97)
  local middleX = width - self.yardWidth / 2 - MARGIN / 2
  local rows = math.ceil(shown.yard / 2)
  local pitch = math.min(unit * 1.2, (self.height - self.mineBand - self.theirsBand - 2 * INFO_HEIGHT) / math.max(rows, 1))
  local top = self.room.y - pitch * (rows - 1) / 2
  for index = 1, shown.yard do
    local column, line = (index - 1) % 2, math.floor((index - 1) / 2)
    specs["y" .. index] = {
      tile = HIDDEN,
      place = {
        x = middleX + (column - 0.5) * unit * 2.2 + (jitter:Roll(9) - 5) * unit * 0.02,
        y = top + line * pitch + (jitter:Roll(9) - 5) * unit * 0.02,
        unit = unit,
        angle = (jitter:Roll(9) - 5) * 0.012,
      },
      light = drawing and DRAWABLE or nil,
      breathe = drawing,
    }
  end

  -- The tile laid last stays lit until the player has moved
  local view = self.view
  local last = view and view.events and view.events[view.ply]
  if last and last.tile and not last.ended and view.canMove then
    local spec = specs["l" .. last.tile]
    if spec then
      spec.light = LAST
    end
  end
  return specs
end

--- A tile to show, from those that aren't anywhere
--- @return Domino
function View:take()
  local domino = table.remove(self.spare)
  if domino then
    return domino
  end
  domino = private.Dominoes.New(self.stage)
  domino.frame:SetFrameLevel(self.stage:GetFrameLevel() + 2)
  domino.frame:RegisterForClicks("LeftButtonUp")
  domino.frame:SetScript("OnEnter", function()
    self:point(domino.name)
  end)
  domino.frame:SetScript("OnLeave", function()
    if self.pointed == domino.name then
      self:point(nil)
    end
  end)
  domino.frame:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" then
      self:pickUp(domino)
    end
  end)
  domino.frame:SetScript("OnMouseUp", function(_, button)
    if button == "LeftButton" then
      self:letGo(domino)
    end
  end)
  return domino
end

--- Gives a tile the light, the darkness and the height its spec says
--- @param domino Domino
--- @param spec DominoesSpec
--- @param instant boolean?
function View:dress(domino, spec, instant)
  domino:SetDim(spec.dim == true)
  domino:SetLight(spec.light, spec.breathe)
  local rise = (spec.rise or 0) * domino.unit
  if instant or math.abs(rise - domino.rise) < 0.5 then
    domino:SetRise(rise)
    return
  end
  local from = domino.rise
  self.hovering:Play(0.09, function(progress)
    domino:SetRise(from + (rise - from) * progress)
  end, { ease = private.Widgets.Ease.out })
end

--- Puts what there is to show on the table: straight there, or with the tiles a move took from
--- one place to another flying there and the rest sliding over
--- @param shown DominoesShown
--- @param moved table<string, { from: string, reveal: boolean?, delay: number? }>? The names tiles were taken from, by where they went
--- @param instant boolean? Nothing moves, it is all simply there
--- @return number seconds Until it has all got there
function View:arrange(shown, moved, instant)
  self.shown = shown
  local specs = self:plan(shown)
  local before = self.at
  local taken, at = {}, {}
  for name, move in pairs(moved or {}) do
    if specs[name] and before[move.from] then
      at[name], taken[move.from] = before[move.from], true
    end
  end
  for name in pairs(specs) do
    if not at[name] and before[name] and not taken[name] then
      at[name], taken[name] = before[name], true
    end
  end
  for name, domino in pairs(before) do
    if not taken[name] then
      domino:Set(nil)
      domino:SetLight(nil)
      self.spare[#self.spare + 1] = domino
    end
  end
  local over = 0
  for name, spec in pairs(specs) do
    local domino = at[name]
    local move = moved and moved[name]
    if not domino then
      domino = self:take()
      at[name] = domino
      domino:Set(spec.tile)
      domino:Place(spec.place.x, spec.place.y, spec.place.unit, spec.place.angle)
    elseif instant or not (move or self:differs(domino, spec.place)) then
      domino:Set(spec.tile)
      domino:Place(spec.place.x, spec.place.y, spec.place.unit, spec.place.angle)
    elseif move then
      local reveal = nil
      if domino.tile == HIDDEN then
        reveal = spec.tile ~= HIDDEN and spec.tile or nil
      elseif domino.tile ~= spec.tile then
        -- The same tile written the other way round, which is the same picture turned right
        -- round: it flies without turning over
        domino.tile, domino.angle = spec.tile, domino.angle + math.pi
      end
      local delay = move.delay or 0
      domino:Move(self.animator, spec.place, FLY, { delay = delay, arc = 0.8, reveal = reveal, ease = private.Widgets.Ease.out })
      over = math.max(over, delay + FLY)
    else
      domino:Set(spec.tile)
      domino:Move(self.animator, spec.place, SLIDE, { delay = 0.05 })
      over = math.max(over, SLIDE + 0.05)
    end
    domino.name = name
    self:dress(domino, spec, true)
  end
  self.at = at
  self:words()
  return over
end

--- Whether a tile isn't where a place is
--- @param domino Domino
--- @param place DominoPlace
--- @return boolean
function View:differs(domino, place)
  return math.abs(domino.x - place.x) > 0.5 or math.abs(domino.y - place.y) > 0.5 or math.abs(domino.unit - place.unit) > 0.2
    or math.abs(domino.angle - place.angle) > 0.01
end

--- Lights the tiles up as the player points at them and takes them in hand, without moving any
function View:relight()
  if not self.shown then
    return
  end
  local specs = self:plan(self.shown)
  for name, domino in pairs(self.at) do
    local spec = specs[name]
    if spec then
      self:dress(domino, spec)
    end
  end
  self:showGhosts()
  self:words()
end

-----------------------------
-- Laying a tile
-----------------------------

--- Shows where the tile pointed at or taken in hand would go, at the end being pointed at too
function View:showGhosts()
  local tile = self.chosen or self.drag:Carrying() or (self.pointed and self.pointed:sub(1, 1) == "m" and self.pointed:sub(2))
  local ends = tile and self:ends(tile)
  local state = self.view and self.view.state
  -- The middle of the table, for the first tile of a hand
  if ends and state and not state.line.first then
    ends = { FIRST }
  end
  for index = 1, 2 do
    local ghost, catch = self.ghosts[index], self.catches[index]
    local side = ends and ends[index]
    if side then
      local spot = private.Dominoes.SpotFor(state.line, tile, side ~= FIRST and side or nil, self.across)
      local place = self:linePlace(spot, self.fit)
      ghost:Set(spot.tile)
      ghost:Place(place.x, place.y, place.unit, place.angle)
      local taken = self.chosen ~= nil or self.drag:Carrying() ~= nil
      ghost:SetLight(GHOST, taken)
      ghost.frame:EnableMouse(self.chosen ~= nil)
      catch:SetSize(3 * place.unit, 3 * place.unit)
      catch:ClearAllPoints()
      catch:SetPoint("CENTER", self.stage, "TOPLEFT", place.x, -place.y)
      catch.side = side
      catch:Show()
    else
      ghost:Set(nil)
      ghost:SetLight(nil)
      catch:Hide()
    end
  end
end

--- The tile carried is over an end it could go on, or no longer
--- @param tile string
--- @param index number? Which end, nil for none
function View:hoverEnd(tile, index)
  local puppet = self.puppet
  if index then
    -- It turns to lie the way it would there
    local ghost = self.ghosts[index]
    puppet.tile, puppet.angle, puppet.unit = ghost.tile, ghost.angle, ghost.unit
  else
    puppet.tile, puppet.angle, puppet.unit = tile, math.pi / 2, self.mineUnit
  end
  puppet:paint()
end

--- @param name string? The tile pointed at, nil for none
function View:point(name)
  if self.pointed == name then
    return
  end
  self.pointed = name
  if not self.drag:Carrying() then
    self:relight()
  end
end

--- The button went down on a tile: one of the player's that can be laid is picked up
--- @param domino Domino
function View:pickUp(domino)
  local name = domino.name or ""
  if name:sub(1, 1) == "y" then
    if self:playing() and self.view.state.draw and #self:moveList() == 1 and self:moveList()[1] == DRAW then
      self.view.submit(DRAW)
    end
    return
  end
  local tile = name:sub(1, 1) == "m" and name:sub(2) or nil
  if not tile or not self:ends(tile) then
    return
  end
  if self.chosen and self.chosen ~= tile then
    self.chosen = nil
  end
  local puppet = self.puppet
  puppet:Set(tile)
  puppet.angle, puppet.unit, puppet.lift = math.pi / 2, self.mineUnit, 1
  puppet:paint()
  self.drag:Carry(tile, {
    puppet = puppet.frame,
    from = domino.frame,
    onReturn = function()
      self:relight()
    end,
  })
  self:showGhosts()
end

--- The button came up on a tile: a click rather than a drag. A tile that goes in one place only
--- goes there, one that could go on either end waits for the end to be clicked
--- @param domino Domino
function View:letGo(domino)
  local tile = self.drag:Carrying()
  if not tile or domino.name ~= "m" .. tile or self.drag:Dragged() then
    return
  end
  local ends = self:ends(tile)
  if not ends then
    self.drag:Cancel(true)
    return
  end
  if #ends <= 1 then
    self.drag:Cancel(true)
    self:lay(tile, ends[1])
    return
  end
  -- Both ends: the tile stays where it was, lit, and the ends are clicked
  self.drag:Cancel(true)
  self.chosen = self.chosen ~= tile and tile or nil
  self:relight()
end

--- The moves the player has, as the game lists them
--- @return string[]
function View:moveList()
  local state = self:playing()
  return state and moves(state, self.view.seat) or {}
end

--- Lays a tile of the player's
--- @param tile string
--- @param side string?
--- @param dropped boolean? It was let go of over the end: it flies on from there
function View:lay(tile, side, dropped)
  if not self:fits(tile, side) then
    return
  end
  local domino = self.at["m" .. tile]
  if dropped and domino then
    -- Into the line from where it was let go, rather than from the hand
    local puppet = self.puppet
    local x, y = puppet.frame:GetCenter()
    local left, top = self.stage:GetLeft(), self.stage:GetTop()
    if x and left and top then
      local scale = puppet.frame:GetEffectiveScale() / self.stage:GetEffectiveScale()
      domino.tile = puppet.tile
      domino:Place(x * scale - left, top - y * scale, puppet.unit, puppet.angle)
      domino:SetRise(0)
    end
  end
  self.chosen, self.pointed = nil, nil
  self:showGhosts()
  self.view.submit(tile .. (side or ""))
end

-----------------------------
-- Words
-----------------------------

--- Says whose points are whose, what the game is played to and what is going on
function View:words()
  local view = self.view
  if not view then
    return
  end
  --- @type DominoesState
  local state = view.state
  local seat, them = view.seat, other(view.seat)
  local playing = (view.live or view.catching) and view.match.status == "active" and not state.outcome
  local Widgets = private.Widgets
  local ending = self.ending
  local scores = ending and ending.scores or state.scores
  self.scores[1]:SetTitle(L["dominoes_you"])
  self.scores[1]:Set(scores[seat])
  self.scores[2]:SetTitle(view.names[them] or "")
  self.scores[2]:Set(scores[them])
  for index, owner in ipairs({ seat, them }) do
    self.scores[index]:Tint(playing and not ending and state.turn == owner and Widgets.GOLD or nil)
  end
  if state.target == 0 then
    self.info:SetText(L["dominoes_one_hand"])
  else
    self.info:SetText(L["dominoes_info"]:format(state.target, ending and ending.hand or state.hand))
  end
  local yard = self.shown and self.shown.yard or 0
  self.yardLabel:SetText(yard > 0 and L["dominoes_boneyard"]:format(yard) or "")

  local note = ""
  local fresh = self:playing()
  if self.summary:IsShown() or self.washing then
    note = ""
  elseif fresh then
    local list = self:moveList()
    if self.chosen then
      note = L["dominoes_choose_end"]
    elseif not state.line.first then
      note = state.lead and L["dominoes_lead_yours"]:format(written(state.lead)) or L["dominoes_begin"]
    elseif list[1] == DRAW then
      note = L["dominoes_draw"]
    else
      note = L["dominoes_your_turn"]
    end
  elseif playing then
    local last = view.events and view.events[view.ply]
    if last and last.knocked then
      for _, knocked in ipairs(last.knocked) do
        if knocked == seat then
          note = L["dominoes_you_passed"]
        end
      end
    end
    if note == "" and not state.line.first and state.lead and state.turn == them then
      note = L["dominoes_lead_theirs"]:format(view.names[them] or "", written(state.lead))
    end
  end
  self.note:SetText(note)
end

-----------------------------
-- Moves
-----------------------------

--- Where a player's points are, for writing something there
--- @param seat number
--- @return number x, number y
function View:scoreSpot(seat)
  local mine = seat == self.view.seat
  return MARGIN + SCORE_WIDTH / 2, mine and self.height - self.mineBand / 2 or self.theirsBand / 2
end

--- Shows a move being made
--- @param event DominoesEvent
--- @param before DominoesShown What was on the table
--- @return number seconds Until it has been shown
function View:animate(event, before)
  local view = self.view
  local seat, mover = view.seat, event.seat
  local ending = event.ended
  if ending then
    -- Until it has been summed up, the table is the hand that ended, not the next
    local scores = { unpack(view.state.scores) }
    if ending.winner > 0 then
      scores[ending.winner] = scores[ending.winner] - ending.points
    end
    self.ending = { scores = scores, hand = view.state.outcome and view.state.hand or view.state.hand - 1 }
  end
  local shown = ending and shownAtEnd(ending, seat) or shownFrom(view.state, seat)
  local moved = {}
  if event.tile then
    local tile = event.tile
    moved["l" .. tile] = { from = mover == seat and "m" .. tile or "t" .. #before.theirs }
  elseif event.drew then
    for index = 1, event.drew do
      local from = "y" .. (before.yard - index + 1)
      if mover == seat then
        local tiles = shown.mine
        moved["m" .. tiles[#tiles - event.drew + index]] = { from = from, delay = (index - 1) * DRAW_GAP }
      else
        moved["t" .. (#before.theirs + index)] = { from = from, delay = (index - 1) * DRAW_GAP }
      end
    end
  end
  local over = self:arrange(shown, moved)
  local Widgets = private.Widgets
  if event.tile then
    self.animator:Play(0, function() end, {
      delay = FLY * 0.85,
      onDone = function()
        Widgets.PlaySound(SOUNDS.lay)
      end,
    })
  elseif event.drew then
    for index = 1, event.drew do
      self.animator:Play(0, function() end, {
        delay = (index - 1) * DRAW_GAP,
        onDone = function()
          Widgets.PlaySound(SOUNDS.draw)
        end,
      })
    end
  end
  for index, knocked in ipairs(event.knocked or {}) do
    local x, y = self:scoreSpot(knocked)
    local at = over + (index - 1) * 0.5
    self.effects:Float(L["dominoes_pass"], x + SCORE_WIDTH * 0.75, y, { delay = at, size = 18, color = LOST_COLOR })
    self.animator:Play(0, function() end, {
      delay = at,
      onDone = function()
        Widgets.PlaySound(SOUNDS.knock)
      end,
    })
    over = at + 0.4
  end
  if ending then
    over = self:finishHand(event, over)
  end
  return over
end

--- The end of a hand: the other's tiles turned over and counted, the points given, and what
--- happened said over the table until the player is ready for the next
--- @param event DominoesEvent
--- @param at number Seconds from now it starts
--- @return number seconds Until it has been shown
function View:finishHand(event, at)
  local view, ending = self.view, event.ended
  local seat, them = view.seat, other(view.seat)
  local Widgets = private.Widgets
  local big = math.max(22, math.min(46, math.floor(self.width * 0.07)))
  local word = L[ending.reason == "domino" and "dominoes_domino" or "dominoes_blocked"]
  local color = ending.winner == seat and WON_COLOR or LOST_COLOR
  self.effects:Float(word, self.room.x, self.room.y, { size = big, delay = at, color = color })

  local theirs = ending.hands[them]
  local start = at + REVEAL_AFTER
  for index, tile in ipairs(theirs) do
    local domino = self.at["t" .. index]
    if domino then
      domino:Reveal(self.animator, tile, REVEAL, { delay = start + (index - 1) * REVEAL_GAP })
    end
  end
  local counted = start + #theirs * REVEAL_GAP + REVEAL
  self.animator:Play(0, function() end, {
    delay = counted,
    onDone = function()
      self.shown.theirs = theirs
      self.counts[1]:SetText(L["dominoes_pips"]:format(ending.pips[seat]))
      self.counts[2]:SetText(L["dominoes_pips"]:format(ending.pips[them]))
      self.counts[1]:ClearAllPoints()
      self.counts[1]:SetPoint("BOTTOM", self.stage, "BOTTOMLEFT", self.width / 2, self.mineBand - 2)
      self.counts[2]:ClearAllPoints()
      self.counts[2]:SetPoint("TOP", self.stage, "TOPLEFT", self.width / 2, -self.theirsBand + 2)
      self.counts[1]:Show()
      self.counts[2]:Show()
      if ending.winner > 0 then
        local x, y = self:scoreSpot(ending.winner)
        self.effects:Float("+" .. ending.points, x + SCORE_WIDTH * 0.75, y, { size = 22 })
        self.ending.scores = view.state.scores
        self:words()
      end
      if ending.winner == seat then
        Widgets.PlaySound(SOUNDS.win)
      end
    end,
  })
  local summary = counted + 0.35
  self.animator:Play(0, function() end, {
    delay = summary,
    onDone = function()
      self:openSummary(event, true)
    end,
  })
  if view.state.outcome and view.state.outcome.winner == seat then
    self.effects:Confetti(summary)
  end
  return summary
end

--- Says over the table how a hand went
--- @param event DominoesEvent
--- @param holds boolean It waits for the player to go on to the next hand
function View:openSummary(event, holds)
  if self.stopping then
    -- Put an end to with everything else on its way: what the view is shown now comes instead
    return
  end
  local view, ending = self.view, event.ended
  local seat, them = view.seat, other(view.seat)
  local names = view.names
  local summary = self.summary
  local winner = ending.winner
  local title
  if ending.reason == "domino" then
    title = winner == seat and L["dominoes_you_domino"] or L["dominoes_they_domino"]:format(names[winner] or "")
  else
    title = L["dominoes_hand_blocked"]
  end
  summary.title:SetText(title)
  summary.title:SetTextColor(unpack(winner == seat and WON_COLOR or LOST_COLOR))
  local lines = {}
  if winner == 0 then
    lines[1] = L["dominoes_tied"]:format(ending.pips[1])
  else
    local loser = other(winner)
    if ending.reason == "blocked" then
      lines[1] = winner == seat and L["dominoes_fewer_yours"]:format(ending.pips[winner], ending.pips[loser])
        or L["dominoes_fewer_theirs"]:format(names[winner] or "", ending.pips[winner], ending.pips[loser])
    end
    lines[#lines + 1] = winner == seat and L["dominoes_score_yours"]:format(ending.points)
      or L["dominoes_score_theirs"]:format(names[winner] or "", ending.points)
  end
  summary.detail:SetText(table.concat(lines, "\n"))
  local state = view.state
  local outcome = state.outcome
  if outcome and state.target > 0 then
    local mine, theirs = state.scores[seat], state.scores[them]
    summary.points:SetText(outcome.winner == seat and L["dominoes_match_yours"]:format(mine, theirs)
      or L["dominoes_match_theirs"]:format(names[outcome.winner] or "", theirs, mine))
  elseif state.target > 0 then
    summary.points:SetText(L["dominoes_standing"]:format(state.scores[seat], names[them] or "", state.scores[them], state.target))
  else
    summary.points:SetText("")
  end
  summary.next:SetShown(holds and event.dealt == true)
  summary.holds = holds and event.dealt == true
  summary:Show()
  if summary.holds and view.catching then
    self.animator:Play(0, function() end, {
      delay = CATCHING_SUMMARY,
      onDone = function()
        self:closeSummary(true)
      end,
    })
  end
  self:words()
end

--- Takes the summary of the hand away, and washes the tiles for the next
--- @param deal boolean Wash and deal the next hand
function View:closeSummary(deal)
  local summary = self.summary
  if not summary:IsShown() then
    return
  end
  summary:Hide()
  summary.holds = false
  self.ending = nil
  self.counts[1]:Hide()
  self.counts[2]:Hide()
  if deal and self.view then
    self:wash(shownFrom(self.view.state, self.view.seat))
  end
end

--- Washes every tile on the table face down in the middle and deals a hand from them
--- @param shown DominoesShown The hand dealt
function View:wash(shown)
  local view = self.view
  dealt[view.match.id .. ":" .. view.state.hand] = true
  local animator, room = self.animator, self.room
  local Widgets = private.Widgets
  local stir = private.Random.New(view.ply + 7)
  local unit = self.fit and self.fit.unit or self.lineMost
  local spread = math.min(room.width, room.height) * 0.32

  -- Every tile there is, wherever it was: twenty-eight of them
  local tiles = {}
  for _, domino in pairs(self.at) do
    tiles[#tiles + 1] = domino
  end
  self.at = {}
  while #tiles < #Bones.Set(TOP) do
    local domino = self:take()
    domino:Set(HIDDEN)
    domino:Place(room.x, room.y, unit, 0)
    tiles[#tiles + 1] = domino
  end
  local function somewhere()
    local turn = stir:Roll(628) / 100
    local away = spread * math.sqrt(stir:Roll(100) / 100)
    return {
      x = room.x + math.cos(turn) * away,
      y = room.y + math.sin(turn) * away * 0.7,
      unit = unit,
      angle = stir:Roll(628) / 100,
    }
  end
  self.washing = true
  for index, domino in ipairs(tiles) do
    domino:SetLight(nil)
    domino:SetDim(false)
    domino:SetRise(0)
    domino.name = nil
    local face = domino.tile ~= HIDDEN and HIDDEN or nil
    domino:Move(animator, somewhere(), GATHER, { reveal = face, arc = 0.3, delay = (index % 7) * 0.02 })
    domino:Move(animator, somewhere(), SWIRL, { delay = GATHER + 0.02 * (index % 5), ease = Widgets.Ease.inOut })
  end
  Widgets.PlaySound(SOUNDS.wash)
  local dealAt = GATHER + SWIRL + 0.15

  -- Then each player draws theirs, one at a time in turn, and the rest go to the boneyard
  self.animator:Play(0, function() end, {
    delay = dealAt,
    onDone = function()
      self.washing = false
      local specs = self:plan(shown)
      local order = {}
      local mine = Bones.Sort({ unpack(shown.mine) })
      for index = 1, math.max(#mine, #shown.theirs) do
        if mine[index] then
          order[#order + 1] = "m" .. mine[index]
        end
        if shown.theirs[index] then
          order[#order + 1] = "t" .. index
        end
      end
      for index = 1, shown.yard do
        order[#order + 1] = "y" .. index
      end
      self.at = {}
      for index, name in ipairs(order) do
        local spec = specs[name]
        local domino = table.remove(tiles)
        self.at[name], domino.name = domino, name
        local delay = (index - 1) * DEAL_GAP
        local reveal = spec.tile ~= HIDDEN and spec.tile or nil
        domino:Move(self.animator, spec.place, DEAL, { delay = delay, arc = 0.5, reveal = reveal })
        if index % 3 == 1 then
          self.animator:Play(0, function() end, {
            delay = delay,
            onDone = function()
              Widgets.PlaySound(SOUNDS.draw)
            end,
          })
        end
      end
      for _, domino in ipairs(tiles) do
        domino:Set(nil)
        self.spare[#self.spare + 1] = domino
      end
      self.shown = shown
      self.animator:Play(0, function() end, {
        delay = #order * DEAL_GAP + DEAL,
        onDone = function()
          self:relight()
        end,
      })
      self:words()
    end,
  })
  self:words()
end

--- Whether nobody has done anything yet in the hand on the table
--- @param state DominoesState
--- @return boolean
local function opening(state)
  return not state.line.first and #state.hands[1] == DEALT and #state.hands[2] == DEALT
end

--- @param view GameView
function View:Update(view)
  local before = self.view
  self.view = view
  --- @type DominoesState
  local state = view.state
  if not view.changed then
    -- The same position: whether the player may move is all that can have changed
    if view.canMove ~= (before and before.canMove) then
      self:relight()
    end
    self:words()
    return
  end

  if view.changed then
    -- Whatever was on its way gets there at once, and the next hand is on the table if the
    -- last was still being summed up
    local summed = self.summary:IsShown() and before and before.state
    self.stopping = true
    self.animator:Stop()
    self.stopping = false
    self.effects:Clear()
    self.drag:Cancel(true)
    self.chosen, self.washing, self.ending = nil, false, nil
    self:closeSummary(false)
    if summed and before.match.id == view.match.id and summed.line and not summed.outcome then
      self:arrange(shownFrom(summed, view.seat), nil, true)
    end
  end

  local seat = view.seat
  --- @type DominoesEvent?
  local event = view.played
  local last = view.events and view.events[view.ply]
  if event and self.shown and before and before.match.id == view.match.id then
    self:animate(event, self.shown)
  elseif last and last.ended and (state.outcome or not view.live) then
    -- A hand that is over, looked back at: as it was when it ended, laid open
    self.ending = { scores = state.scores, hand = state.outcome and state.hand or state.hand - 1 }
    self:arrange(shownAtEnd(last.ended, seat, true), nil, true)
    self:openSummary(last, false)
  elseif view.live and opening(state) and not dealt[view.match.id .. ":" .. state.hand] and self.width > 0 then
    self.shown = nil
    self:wash(shownFrom(state, seat))
  else
    self:arrange(shownFrom(state, seat), nil, true)
  end
  self:showGhosts()
  self:words()
end

--- @return boolean
function View:Busy()
  return self.animator:Busy() or self.washing == true or (self.summary:IsShown() and self.summary.holds == true)
end

private.Games.Register({
  id = "dominoes",
  name = L["game_dominoes"],
  description = L["game_dominoes_description"],
  genre = "strategy",
  icon = "Interface\\AddOns\\ForeverGames\\Images\\Icons\\dominoes",
  version = 1,
  seats = 2,
  history = true,
  options = {
    {
      id = "draw",
      name = L["dominoes_option_draw"],
      description = L["dominoes_option_draw_tip"],
      default = false,
    },
    {
      id = "target",
      name = L["dominoes_option_target"],
      description = L["dominoes_option_target_tip"],
      choices = { 0, 50, 100, 150, 200 },
      default = 100,
      label = function(value)
        return value == 0 and L["dominoes_option_target_one"] or tostring(value)
      end,
    },
  },
  howto = {
    {
      heading = L["howto_goal"],
      text = function(rules)
        if rules.target == 0 then
          return L["dominoes_howto_goal_one"]
        end
        return L["dominoes_howto_goal"]:format(rules.target)
      end,
    },
    { heading = L["dominoes_howto_start"], text = L["dominoes_howto_start_text"] },
    {
      heading = L["howto_turn"],
      text = function(rules)
        return L[rules.draw and "dominoes_howto_turn_draw" or "dominoes_howto_turn"]
      end,
    },
    { heading = L["howto_scoring"], text = L["dominoes_howto_scoring_text"] },
    { heading = L["howto_controls"], text = L["dominoes_howto_controls"] },
  },
  newState = newState,
  turn = function(state)
    return state.turn
  end,
  validate = validate,
  apply = apply,
  moves = moves,
  visible = visible,
  result = function(state)
    return state.outcome
  end,
  tally = function(state)
    return state.scores
  end,
  computer = COMPUTER,
  createView = createView,
  -- Not the engine's business: for the tests, the bench and the view
  rules = { canLay = canLay, canAct = canAct, standing = standing, parse = parse, DRAW = DRAW, TOP = TOP },
})
