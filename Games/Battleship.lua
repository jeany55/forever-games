--------------------------
--  Battleship
--------------------------
-- Each player hides a fleet of five ships on their own ten by ten sea, then they take turns
-- firing at a square of the other's. A ship goes down once every square of it has been hit, and
-- whoever sinks the whole fleet of the other wins. Ships lie across or up, never over each
-- other, and may touch.
--
-- The first move of each player is their fleet: the square each ship starts on and the way it
-- lies from there, "h" to the right or "v" up, for the carrier, the battleship, the cruiser, the
-- submarine and the destroyer in that order ("a1h.a2h.a3h.a4h.a5h"). Seat 1 puts theirs down
-- first and fires first. After that a move is the square fired at, "a1" to "j10".
--
-- Where a fleet lies is in the log like any other move, so every client can say for itself what
-- a shot did, and a shot is answered the moment it is fired, whether the other player is around
-- or not. Nobody is shown the other fleet all the same: `visible` leaves a player with the ships
-- of the other that have gone down, and what the game says about a move names no square that
-- wasn't fired at.
--
-- Squares are numbered 0 (a1) to 99 (j10), a1 in the bottom left like on every other board.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L

local SIZE = 10
-- The fleet, in the order a move lists it
local SHIPS = {
  { name = "carrier", size = 5 },
  { name = "battleship", size = 4 },
  { name = "cruiser", size = 3 },
  { name = "submarine", size = 3 },
  { name = "destroyer", size = 2 },
}
local HIT, MISS = "hit", "miss"

--- @class BattleshipShip
--- @field size number
--- @field sunk boolean
--- @field square number? The lowest of its squares. Not known of a ship of the other player that is still afloat
--- @field vertical boolean? Whether it lies up from there instead of to the right
--- @field hits number? How many of its squares have been hit

--- @class BattleshipState
--- @field turn number
--- @field placed boolean[] Whether each seat has put their fleet down
--- @field fleets BattleshipShip[][] The ships by seat, in the order of SHIPS
--- @field decks table<number, number>[] By seat, which of their ships lies on a square
--- @field shots table<number, string>[] By seat, what was fired at their sea: HIT or MISS by square
--- @field afloat number[] Ships each seat has left
--- @field last table<number, number> By seat, the square of their sea that was fired at last
--- @field outcome { winner: number }?

--- @class BattleshipEvent: MatchEvent
--- @field placed boolean? A fleet was put down. Where is nobody else's business
--- @field square number? The square that was fired at
--- @field target number? Seat whose sea that is
--- @field hit boolean?
--- @field sunk number? The ship that went down with it, as an index into the fleet

-----------------------------
-- Rules
-----------------------------

--- @param seat number
--- @return number
local function other(seat)
  return seat == 1 and 2 or 1
end

--- @param square number
--- @return string
local function squareName(square)
  return string.char(97 + square % SIZE) .. (math.floor(square / SIZE) + 1)
end

--- @param name string
--- @return number? square nil if there is no such square
local function parseSquare(name)
  local file, rank = name:match("^([a-j])(%d%d?)$")
  if not file or (rank ~= "10" and not rank:match("^[1-9]$")) then
    return nil
  end
  return (file:byte() - 97) + (tonumber(rank) - 1) * SIZE
end

--- The squares a ship lies on
--- @param size number
--- @param square number The lowest of them
--- @param vertical boolean?
--- @return number[]? cells nil if it would stick out over the edge
local function cellsOf(size, square, vertical)
  local column, row = square % SIZE, math.floor(square / SIZE)
  if (vertical and row or column) + size > SIZE then
    return nil
  end
  local cells = {}
  for index = 0, size - 1 do
    cells[index + 1] = square + index * (vertical and SIZE or 1)
  end
  return cells
end

--- Which ship lies on each square
--- @param ships table<number, BattleshipShip> Ones without a square are left out
--- @return table<number, number>
local function decksOf(ships)
  local decks = {}
  for index = 1, #SHIPS do
    local ship = ships[index]
    for _, cell in ipairs(ship and ship.square and cellsOf(ship.size, ship.square, ship.vertical) or {}) do
      decks[cell] = index
    end
  end
  return decks
end

--- @param move string
--- @return BattleshipShip[]? fleet nil if the move doesn't put a whole fleet down properly
local function parseFleet(move)
  local fleet, taken = {}, {}
  for part in (move .. "."):gmatch("([^.]*)%.") do
    local kind = SHIPS[#fleet + 1]
    local name, way = part:match("^(%l%d+)([hv])$")
    local square = name and parseSquare(name)
    local cells = kind and square and cellsOf(kind.size, square, way == "v")
    if not cells then
      return nil
    end
    for _, cell in ipairs(cells) do
      if taken[cell] then
        return nil
      end
      taken[cell] = true
    end
    fleet[#fleet + 1] = { size = kind.size, square = square, vertical = way == "v", hits = 0, sunk = false }
  end
  return #fleet == #SHIPS and fleet or nil
end

--- @param ships table<number, { square: number, vertical: boolean? }> All of them
--- @return string move
local function fleetMove(ships)
  local parts = {}
  for index = 1, #SHIPS do
    parts[index] = squareName(ships[index].square) .. (ships[index].vertical and "v" or "h")
  end
  return table.concat(parts, ".")
end

--- @return BattleshipState
local function newState()
  return {
    turn = 1,
    placed = { false, false },
    fleets = { {}, {} },
    decks = { {}, {} },
    shots = { {}, {} },
    afloat = { 0, 0 },
    last = {},
  }
end

--- @param state BattleshipState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  if seat ~= state.turn then
    return false, "not_your_turn"
  end
  if not state.placed[seat] then
    if not parseFleet(move) then
      return false, "invalid_move"
    end
    return true
  end
  local square = parseSquare(move)
  if not square then
    return false, "invalid_move"
  end
  if state.shots[other(seat)][square] then
    return false, "already_fired"
  end
  return true
end

--- @param state BattleshipState
--- @param seat number
--- @param move string
--- @return BattleshipEvent
local function apply(state, seat, move)
  local target = other(seat)
  state.turn = target
  if not state.placed[seat] then
    state.fleets[seat] = parseFleet(move)
    state.decks[seat] = decksOf(state.fleets[seat])
    state.placed[seat], state.afloat[seat] = true, #SHIPS
    return { placed = true }
  end

  local square = parseSquare(move)
  local index = state.decks[target][square]
  local ship = index and state.fleets[target][index]
  state.shots[target][square] = ship and HIT or MISS
  state.last[target] = square
  if ship then
    ship.hits = ship.hits + 1
    ship.sunk = ship.hits == ship.size
  end
  local sunk = ship and ship.sunk
  if sunk then
    state.afloat[target] = state.afloat[target] - 1
    if state.afloat[target] == 0 then
      state.outcome = { winner = seat }
    end
  end
  return { square = square, target = target, hit = ship ~= nil, sunk = sunk and index or nil, notation = move }
end

--- @param value any
--- @return any
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, inner in pairs(value) do
    result[key] = copy(inner)
  end
  return result
end

--- What a player may see: everything of their own, and of the other fleet the ships that have
--- gone down. Of the rest only that they are there, and how long each is
--- @param state BattleshipState
--- @param seat number
--- @return BattleshipState
local function visible(state, seat)
  local seen = copy(state)
  local foe = other(seat)
  for index, ship in ipairs(seen.fleets[foe]) do
    if not ship.sunk then
      seen.fleets[foe][index] = { size = ship.size, sunk = false }
    end
  end
  seen.decks[foe] = decksOf(seen.fleets[foe])
  return seen
end

-----------------------------
-- View
-----------------------------
-- Two seas on the shared board (GUI/Board.lua): the player's own with their fleet on it, and
-- the other player's to fire at. The one that matters is drawn large and the other small next
-- to it, a click on the small one changes them over. Beside the small one are the two fleets
-- with what is left of them, and a line about the last shot.
--
-- Before the game the player's sea is where they arrange their fleet. It starts out arranged at
-- random. A click on a ship picks it up and a click on the water puts it down again, turned
-- with a right click or with Rotate. Nothing is sent until they press Deploy, and it can be
-- arranged while waiting for the other player to send theirs.

local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\"
local SEA = { texture = IMAGES .. "Board\\sea", shimmer = IMAGES .. "Board\\glints" }
local RING = IMAGES .. "Board\\ring"
local FILES = "ABCDEFGHIJ"
local RANKS = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" }
local LABELS = { 0.72, 0.9, 1 }
-- Nothing marks the squares that can be fired at, they are nearly all of them
local NO_MARK = { 0, 0, 0, 0 }
local LAST_SHOT = { 1, 0.9, 0.4, 0.28 }
local FITS, BLOCKED = { 0.3, 1, 0.45, 0.3 }, { 1, 0.25, 0.2, 0.4 }
-- A ship in hand, seen where it would go
local GHOST_ALPHA = 0.6
-- The side of the small sea as a fraction of the large one's
local SMALL = 0.44
local GAP = 14
local TITLE_HEIGHT = 18
-- The fleets next to the small sea: a ship there is this high at most, and this far from the next
local ROW_UNIT, ROW_GAP, ROW_HEIGHT = 13, 5, 36
local BUTTON_HEIGHT, BUTTON_GAP = 22, 4
-- Rings spread from a square that was fired at: seconds one takes, seconds between them, and how
-- wide they start and end, in squares
local RIPPLE, RIPPLE_APART, RIPPLE_FROM, RIPPLE_TO = 0.7, 0.16, 0.5, 2.6
local RIPPLE_COLORS = { [true] = { 1, 0.6, 0.2 }, [false] = { 0.85, 0.96, 1 } }
local SOUNDS = { [true] = "dieThrow", [false] = "cardSlide" }
local PLACE_SOUND = "chipsCollide"

local CELLS = 0
for _, kind in ipairs(SHIPS) do
  CELLS = CELLS + kind.size
end

-- Fleets being arranged, by match id. They aren't kept past a reload, a new one is drawn up then
--- @class BattleshipDraft
--- @field ships table<number, { size: number, square: number, vertical: boolean }> By ship. One that is in hand or yet to be put down isn't in it
--- @field held number? The ship in hand
--- @field vertical boolean The way the ship in hand lies
--- @type table<string, BattleshipDraft>
local drafts = {}

--- @param name string Which ship
--- @param pixels number? Screen pixels a square of it is drawn at
--- @return string
local function shipTexture(name, pixels)
  -- A ship is four times as long as high in its texture, which comes at half the usual sizes
  return IMAGES .. "Fleet\\" .. private.Board.TextureSize((pixels or 0) * 2) / 2 .. "\\" .. name
end

--- @param peg string HIT or MISS
--- @param pixels number?
--- @return string
local function pegTexture(peg, pixels)
  return IMAGES .. "Marks\\" .. private.Board.TextureSize(pixels) .. "\\" .. peg
end

--- @param index number Which ship of the fleet
--- @return string
local function shipName(index)
  return L["battleship_" .. SHIPS[index].name]
end

--- The square a ship starts on when the player points at one, moved in from the edge as far as
--- it takes for the ship to fit
--- @param size number
--- @param square number
--- @param vertical boolean
--- @return number
local function anchor(size, square, vertical)
  local column, row = square % SIZE, math.floor(square / SIZE)
  if vertical then
    row = math.min(row, SIZE - size)
  else
    column = math.min(column, SIZE - size)
  end
  return row * SIZE + column
end

--- Whether a ship can go somewhere among the ones that are already down
--- @param ships table<number, { size: number, square: number, vertical: boolean }>
--- @param size number
--- @param square number
--- @param vertical boolean
--- @return boolean
local function fits(ships, size, square, vertical)
  local taken = decksOf(ships)
  for _, cell in ipairs(cellsOf(size, square, vertical) or { -1 }) do
    if cell < 0 or taken[cell] then
      return false
    end
  end
  return true
end

--- A whole fleet put down any old way. Where is the player's own business, so the client's own
--- dice will do: the match's are everybody's (Engine/Random.lua)
--- @return BattleshipDraft
local function randomDraft()
  local ships = {}
  for index, kind in ipairs(SHIPS) do
    repeat
      local vertical = math.random(2) == 1
      local square = anchor(kind.size, math.random(SIZE * SIZE) - 1, vertical)
      if fits(ships, kind.size, square, vertical) then
        ships[index] = { size = kind.size, square = square, vertical = vertical }
      end
    until ships[index]
  end
  return { ships = ships, vertical = false }
end

--- @param ships table<number, BattleshipShip> Ones without a square are left out
--- @return BoardSpan[]
local function spansOf(ships)
  local spans = {}
  for index, kind in ipairs(SHIPS) do
    local ship = ships[index]
    if ship and ship.square then
      spans[#spans + 1] = {
        square = ship.square,
        columns = ship.vertical and 1 or kind.size,
        rows = ship.vertical and kind.size or 1,
        key = kind.name,
        upright = ship.vertical,
      }
    end
  end
  return spans
end

--- One of the two seas: a board, what it is called, and the rings a shot leaves on it
--- @class BattleshipSea
--- @field board Board
--- @field title FontString
--- @field rings { texture: Texture, since: number?, wait: number }[]

--- @param stage Frame
--- @return BattleshipSea
local function newSea(stage)
  local board = private.Board.New(stage, {
    columns = SIZE,
    rows = SIZE,
    backdrop = SEA,
    mark = NO_MARK,
    files = FILES,
    ranks = RANKS,
    label = LABELS,
  })
  --- @type BattleshipSea
  local sea = { board = board, rings = {} }
  sea.title = private.Widgets.Label(stage, "GameFontNormal")
  sea.title:SetPoint("BOTTOMLEFT", board.frame, "TOPLEFT", 0, 4)

  local splash = CreateFrame("Frame", nil, board.frame)
  splash:SetAllPoints()
  for index = 1, 2 do
    local texture = splash:CreateTexture(nil, "OVERLAY")
    texture:SetTexture(RING)
    texture:SetBlendMode("ADD")
    texture:Hide()
    sea.rings[index] = { texture = texture, wait = (index - 1) * RIPPLE_APART }
  end
  splash:SetScript("OnUpdate", function(_, elapsed)
    for _, ring in ipairs(sea.rings) do
      if ring.since then
        ring.since = ring.since + elapsed
        local progress = (ring.since - ring.wait) / RIPPLE
        if progress >= 1 then
          ring.since = nil
        elseif progress >= 0 then
          local side = board.cell * (RIPPLE_FROM + (RIPPLE_TO - RIPPLE_FROM) * (1 - (1 - progress) ^ 2))
          ring.texture:SetSize(side, side)
          ring.texture:SetAlpha((1 - progress) ^ 1.5)
        end
        ring.texture:SetShown(ring.since ~= nil and progress >= 0)
      end
    end
  end)
  return sea
end

--- Rings spread from a square of a sea
--- @param sea BattleshipSea
--- @param square number
--- @param hit boolean
local function ripple(sea, square, hit)
  local board = sea.board
  local x, y = board:OffsetOf(square)
  for _, ring in ipairs(sea.rings) do
    ring.since = 0
    ring.texture:SetVertexColor(unpack(RIPPLE_COLORS[hit]))
    ring.texture:ClearAllPoints()
    ring.texture:SetPoint("CENTER", board.frame, "TOPLEFT", x + board.cell / 2, -(y + board.cell / 2))
    ring.texture:Hide()
  end
end

--- A fleet in a row, each ship as long as it is, with the ones that have gone down struck out
--- @param parent Frame
--- @return Frame row Arrange(width) fits it in, Set(caption, fleet) fills it
local function newFleetRow(parent)
  local row = CreateFrame("Frame", nil, parent)
  row:SetHeight(ROW_HEIGHT)
  row.caption = private.Widgets.Label(row, "GameFontHighlightSmall")
  row.caption:SetPoint("TOPLEFT")
  row.ships = {}
  for index in ipairs(SHIPS) do
    row.ships[index] = row:CreateTexture(nil, "ARTWORK")
  end

  --- @param width number
  function row:Arrange(width)
    local unit = math.max(4, math.min(ROW_UNIT, math.floor((width - (#SHIPS - 1) * ROW_GAP) / CELLS)))
    local x = 0
    self:SetWidth(width)
    for index, kind in ipairs(SHIPS) do
      local ship = self.ships[index]
      ship:SetTexture(shipTexture(kind.name, unit))
      ship:SetSize(kind.size * unit, unit)
      ship:ClearAllPoints()
      ship:SetPoint("BOTTOMLEFT", x, 2)
      x = x + kind.size * unit + ROW_GAP
    end
  end

  --- @param caption string
  --- @param fleet BattleshipShip[] Empty for one that isn't down yet
  function row:Set(caption, fleet)
    self.caption:SetText(caption)
    for index, ship in ipairs(self.ships) do
      local sunk = fleet[index] and fleet[index].sunk
      ship.sunk = sunk
      ship:SetVertexColor(1, sunk and 0.3 or 1, sunk and 0.25 or 1)
      ship:SetAlpha(sunk and 0.45 or 1)
    end
  end
  return row
end

--- @class BattleshipView: GameViewObject
--- @field fleet BattleshipSea The player's own
--- @field waters BattleshipSea The other player's
--- @field big BattleshipSea Whichever of the two is drawn large
--- @field small BattleshipSea
--- @field swap Button Lies over the small one, to change them over
--- @field swapped boolean The player changed them over
--- @field shownFor string? What they were last chosen for: a match and what is going on in it
--- @field panel Frame Next to the small sea
--- @field rows Frame[] The other player's fleet and the player's own
--- @field note FontString
--- @field buttons { rotate: Button, random: Button, deploy: Button }
--- @field hovered number? Square of the player's own sea the cursor is over
--- @field view GameView? What was last asked for
local View = {}
View.__index = View

--- @param stage Frame
--- @return BattleshipView
local function createView(stage)
  --- @type BattleshipView
  local self = setmetatable({}, View)
  local Widgets = private.Widgets
  self.stage = stage

  self.fleet, self.waters = newSea(stage), newSea(stage)
  self.big, self.small, self.swapped = self.fleet, self.waters, false
  self.fleet.board:SetInput({
    place = function(square)
      return square
    end,
    onPlace = function(square)
      self:click(square)
    end,
    onCancel = function(button)
      if button then
        self:rotate()
      end
    end,
    onHover = function(square)
      self.hovered = square
      -- Not when it left because the board went away: what it showed may be long gone
      if self.view and self.fleet.board.frame:IsVisible() then
        self:showFleet()
      end
    end,
  })
  self.waters.board:SetInput({
    place = function(square)
      return not self.view.state.shots[other(self.view.seat)][square] and square or nil
    end,
    onPlace = function(square)
      self.view.submit(squareName(square))
    end,
  })

  self.swap = CreateFrame("Button", nil, stage)
  self.swap:SetScript("OnClick", function()
    self.swapped = not self.swapped
    if self.view then
      self:Update(self.view)
    end
  end)
  self.swap:SetScript("OnEnter", function(button)
    GameTooltip:SetOwner(button, "ANCHOR_CURSOR")
    GameTooltip:SetText(L["battleship_swap"])
    GameTooltip:Show()
  end)
  self.swap:SetScript("OnLeave", GameTooltip_Hide)

  self.panel = CreateFrame("Frame", nil, stage)
  self.rows = { newFleetRow(self.panel), newFleetRow(self.panel) }
  self.rows[1]:SetPoint("TOPLEFT")
  self.rows[2]:SetPoint("TOPLEFT", 0, -ROW_HEIGHT - ROW_GAP)
  self.note = Widgets.Label(self.panel, "GameFontHighlightSmall")
  self.note:SetPoint("TOPLEFT", 0, -2 * (ROW_HEIGHT + ROW_GAP) - 2)
  self.note:SetJustifyV("TOP")
  self.note:SetTextColor(unpack(Widgets.GOLD))

  local rotate = Widgets.Button(self.panel, L["battleship_rotate"], 60, BUTTON_HEIGHT)
  rotate:SetPoint("BOTTOMLEFT")
  rotate:SetScript("OnClick", function()
    self:rotate()
  end)
  local random = Widgets.Button(self.panel, L["battleship_random"], 60, BUTTON_HEIGHT)
  random:SetPoint("LEFT", rotate, "RIGHT", BUTTON_GAP, 0)
  random:SetScript("OnClick", function()
    drafts[self.view.match.id] = randomDraft()
    Widgets.PlaySound(PLACE_SOUND)
    self:Update(self.view)
  end)
  local deploy = Widgets.Button(self.panel, L["battleship_deploy"], 60, BUTTON_HEIGHT)
  deploy:SetPoint("LEFT", random, "RIGHT", BUTTON_GAP, 0)
  deploy:SetScript("OnClick", function()
    self.view.submit(fleetMove(self:draft().ships))
  end)
  self.buttons = { rotate = rotate, random = random, deploy = deploy }
  return self
end

--- @param width number
--- @param height number
function View:Layout(width, height)
  self.width, self.height = width, height
  self:arrange()
end

--- Fits the two seas and what goes with them into the room there is
function View:arrange()
  local width, height = self.width, self.height
  local big, small = self.big.board, self.small.board
  -- Next to each other or one above the other, whichever leaves the large one larger
  local across = math.min(height - TITLE_HEIGHT, (width - GAP) / (1 + SMALL))
  local down = math.min(width, (height - 2 * TITLE_HEIGHT - GAP) / (1 + SMALL))
  local wide = across >= down
  big:SetSize(math.floor(wide and across or down))
  small:SetSize(math.floor(big.cell * SIZE * SMALL))
  local bigSide, smallSide = big.cell * SIZE, small.cell * SIZE

  local usedWidth = wide and bigSide + GAP + smallSide or bigSide
  local usedHeight = TITLE_HEIGHT + bigSide + (wide and 0 or GAP + TITLE_HEIGHT + smallSide)
  local left, top = math.floor((width - usedWidth) / 2), math.floor((height - usedHeight) / 2) + TITLE_HEIGHT
  local panelWidth, panelHeight
  big.frame:ClearAllPoints()
  big.frame:SetPoint("TOPLEFT", self.stage, "TOPLEFT", left, -top)
  small.frame:ClearAllPoints()
  self.panel:ClearAllPoints()
  if wide then
    small.frame:SetPoint("TOPLEFT", self.stage, "TOPLEFT", left + bigSide + GAP, -top)
    self.panel:SetPoint("TOPLEFT", small.frame, "BOTTOMLEFT", 0, -GAP)
    panelWidth, panelHeight = smallSide, bigSide - smallSide - GAP
  else
    small.frame:SetPoint("TOPLEFT", self.stage, "TOPLEFT", left, -top - bigSide - GAP - TITLE_HEIGHT)
    self.panel:SetPoint("TOPLEFT", small.frame, "TOPRIGHT", GAP, 0)
    panelWidth, panelHeight = bigSide - smallSide - GAP, smallSide
  end
  self.panel:SetSize(panelWidth, panelHeight)
  self.note:SetWidth(panelWidth)
  for _, row in ipairs(self.rows) do
    row:Arrange(panelWidth)
  end
  for _, button in pairs(self.buttons) do
    button:SetWidth(math.floor((panelWidth - 2 * BUTTON_GAP) / 3))
  end

  self.swap:ClearAllPoints()
  self.swap:SetAllPoints(small.frame)
  self.swap:SetFrameLevel(small.frame:GetFrameLevel() + 5)
end

--- Whether the player has yet to send their fleet, in a game that is still on
--- @return boolean
function View:placing()
  local view = self.view
  return not view.state.placed[view.seat] and view.live and view.match.status == "active"
end

--- The fleet the player is arranging, drawn up at random the first time it is asked for
--- @return BattleshipDraft
function View:draft()
  local id = self.view.match.id
  drafts[id] = drafts[id] or randomDraft()
  return drafts[id]
end

--- The player clicked a square of their own sea while arranging the fleet: on a ship to pick it
--- up, on the water to put down the one in hand
--- @param square number
function View:click(square)
  local draft = self:draft()
  local index = decksOf(draft.ships)[square]
  if index then
    draft.held, draft.vertical = index, draft.ships[index].vertical
    draft.ships[index] = nil
  elseif draft.held then
    local size = SHIPS[draft.held].size
    local at = anchor(size, square, draft.vertical)
    if not fits(draft.ships, size, at, draft.vertical) then
      return
    end
    draft.ships[draft.held] = { size = size, square = at, vertical = draft.vertical }
    -- On to the next one that isn't down yet
    draft.held = nil
    for next = 1, #SHIPS do
      draft.held = draft.held or (not draft.ships[next] and next or nil)
    end
  else
    return
  end
  private.Widgets.PlaySound(PLACE_SOUND)
  self:Update(self.view)
end

--- Turns the ship in hand the other way
function View:rotate()
  local draft = self:placing() and self:draft()
  if draft and draft.held then
    draft.vertical = not draft.vertical
    self:Update(self.view)
  end
end

--- Draws the player's own sea: the fleet as it lies or as it is being arranged, and what was fired at it
function View:showFleet()
  local view, board = self.view, self.fleet.board
  --- @type BattleshipState
  local state = view.state
  local tints = {}
  local spans

  if self:placing() then
    local draft = self:draft()
    spans = spansOf(draft.ships)
    if draft.held and self.hovered then
      -- The ship in hand where it would go, and whether it can
      local kind = SHIPS[draft.held]
      local at = anchor(kind.size, self.hovered, draft.vertical)
      local color = fits(draft.ships, kind.size, at, draft.vertical) and FITS or BLOCKED
      for _, cell in ipairs(cellsOf(kind.size, at, draft.vertical)) do
        tints[cell] = color
      end
      local ghost = spansOf({ [draft.held] = { size = kind.size, square = at, vertical = draft.vertical } })[1]
      ghost.alpha = GHOST_ALPHA
      spans[#spans + 1] = ghost
    end
  else
    spans = spansOf(state.fleets[view.seat])
    if state.last[view.seat] then
      tints[state.last[view.seat]] = LAST_SHOT
    end
  end
  board:SetSpans(spans, shipTexture)
  board:SetPieces(state.shots[view.seat], pegTexture)
  board:SetTints(tints)
end

--- What to say under the fleets
--- @return string
function View:noteText()
  local view = self.view
  --- @type BattleshipState
  local state = view.state
  local foe = other(view.seat)
  if self:placing() then
    local held = self:draft().held
    if held then
      return L["battleship_place"]:format(shipName(held), SHIPS[held].size)
    end
    return view.canMove and L["battleship_ready"] or L["battleship_ready_early"]:format(view.names[foe])
  end
  if not state.placed[foe] then
    return view.match.status == "active" and L["battleship_waiting"]:format(view.names[foe]) or ""
  end

  --- @type BattleshipEvent?
  local event = view.events[view.ply]
  if not event or not event.square then
    return ""
  end
  local mine = event.seat == view.seat
  local what = event.sunk and "sank" or (event.hit and "hit" or "missed")
  local text = L["battleship_" .. (mine and "you_" or "they_") .. what]
  local last = event.sunk and shipName(event.sunk) or squareName(event.square):upper()
  if mine then
    return text:format(last)
  end
  return text:format(view.names[foe], last)
end

--- @param view GameView
function View:Update(view)
  self.view = view
  --- @type BattleshipState
  local state = view.state
  local seat, foe = view.seat, other(view.seat)
  local placing = self:placing()
  if state.placed[seat] then
    drafts[view.match.id] = nil
  end

  -- The sea the player has something to do on is the large one, until they say otherwise
  local shownFor = view.match.id .. (placing and ":fleet" or ":waters")
  if shownFor ~= self.shownFor then
    self.shownFor, self.swapped = shownFor, false
  end
  local big = placing ~= self.swapped and self.fleet or self.waters
  if big ~= self.big then
    self.big, self.small = big, big == self.fleet and self.waters or self.fleet
    self:arrange()
  end

  local fleet, waters = self.fleet.board, self.waters.board
  if view.changed then
    fleet:StopGlides()
    waters:StopGlides()
  end
  -- Only the large one is played on: the small one is for looking at, and for changing them over
  fleet:SetEnabled(placing and self.big == self.fleet)
  waters:SetEnabled(view.canMove and state.placed[seat] and self.big == self.waters)
  self:showFleet()
  waters:SetSpans(spansOf(state.fleets[foe]), shipTexture)
  waters:SetPieces(state.shots[foe], pegTexture)
  waters:SetTints(state.last[foe] and { [state.last[foe]] = LAST_SHOT } or {})

  self.fleet.title:SetText(L["battleship_your_fleet"])
  self.waters.title:SetText(L["battleship_their_waters"]:format(view.names[foe]))
  for index, whose in ipairs({ foe, seat }) do
    local name = whose == seat and L["battleship_you"] or view.names[whose]
    local afloat = state.placed[whose] and state.afloat[whose] or #SHIPS
    self.rows[index]:Set(L["battleship_afloat"]:format(name, afloat), state.fleets[whose])
  end
  self.note:SetText(self:noteText())

  local draft = placing and self:draft() or nil
  for _, button in pairs(self.buttons) do
    button:SetShown(placing)
  end
  self.buttons.rotate:SetEnabled(draft ~= nil and draft.held ~= nil)
  self.buttons.deploy:SetEnabled(draft ~= nil and draft.held == nil and view.canMove)

  --- @type BattleshipEvent?
  local event = view.played
  if event and event.square then
    local sea = event.target == seat and self.fleet or self.waters
    sea.board:Pop(event.square)
    ripple(sea, event.square, event.hit)
    private.Widgets.PlaySound(SOUNDS[event.hit])
  elseif event and event.placed then
    private.Widgets.PlaySound(PLACE_SOUND)
  end
end

private.Games.Register({
  id = "battleship",
  name = L["game_battleship"],
  description = L["game_battleship_description"],
  genre = "strategy",
  icon = IMAGES .. "Icons\\battleship",
  version = 1,
  seats = 2,
  newState = newState,
  turn = function(state)
    return state.turn
  end,
  validate = validate,
  apply = apply,
  visible = visible,
  result = function(state)
    return state.outcome
  end,
  createView = createView,
})
