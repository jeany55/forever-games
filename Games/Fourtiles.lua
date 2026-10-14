--------------------------
--  Fourtiles
--------------------------
-- Twenty tiles with a few letters on each, cut from five words of four tiles. Whatever one to
-- four of them spell counts if it is a word, and the more tiles a word takes the more it is
-- worth. Finding the five words the tiles were cut from is worth a bonus on top.
--
-- It is played alone or by two who look for the words together, with no turns: either of them
-- puts a word together whenever they see one (GameDefinition.together), and the score is theirs
-- both. There is nothing to lose. The game goes on until somebody who has the five long words
-- and the top rank calls it done, or until there is no word left to find.
--
-- The puzzles come ready made (Lexicon/Fourtiles.lua, written by Tools/make_fourtiles.py), with
-- how many words there are in each: counting them here would take far too long. What counts as
-- a word is the English list of Games/Words.lua.
--
-- A move is the tiles of a word in the order they are put together, a letter for each: "cfk" is
-- the third, the sixth and the eleventh of the state's tiles. "X" calls the game done.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Lexicon = private.Lexicon

local LIST = "english"
local TILES, MOST = 20, 4
local COLUMNS, ROWS = 4, 5
-- What a word of so many tiles is worth, and what finding all of the long ones adds
local POINTS = { 1, 2, 4, 8 }
local BONUS = 40
-- The score each rank begins at. The top one can be reached with everyday words in every puzzle
local RANKS = { 0, 25, 50, 75, 100 }
local WRAP_UP = "X"
local FIRST = ("a"):byte()

--- @class FourtilesFind
--- @field word string
--- @field size number How many tiles it took
--- @field seat number Who found it

--- @class FourtilesState
--- @field seats number
--- @field tiles string[] What is on each tile
--- @field of number[] Which of the five words each tile was cut from
--- @field words string[] The five words
--- @field counts number[] How many words there are to find, by how many tiles they take
--- @field total number How many words there are to find in all
--- @field found table<string, FourtilesFind>
--- @field list FourtilesFind[] The words found, in the order they were
--- @field sizes number[] How many words were found, by how many tiles they take
--- @field score number
--- @field by number[] How much of the score each seat found
--- @field done boolean

--- @class FourtilesEvent: MatchEvent
--- @field word string? The word that was found, nothing where the game was called done
--- @field size number?
--- @field points number? What it was worth, the bonus not counted
--- @field bonus boolean? It was the last of the five long words
--- @field rank number? The rank it took the players to, where that is a new one
--- @field tiles number[]? The tiles it was put together from
--- @field done boolean? That was the end of the game

--- Takes a puzzle apart
--- @param text string As Tools/make_fourtiles.py writes it: "RE.SE.MB.LED DI.FF.IC.ULT ... 6.21.5"
--- @return string[] tiles, number[] of, string[] words, number[] counts
local function parse(text)
  local tiles, of, words, counts = {}, {}, {}, {}
  for part in text:gmatch("%S+") do
    if part:find("%d") then
      for count in part:gmatch("%d+") do
        counts[#counts + 1] = tonumber(count)
      end
    else
      words[#words + 1] = part:gsub("%.", "")
      for tile in part:gmatch("[^.]+") do
        tiles[#tiles + 1] = tile
        of[#of + 1] = #words
      end
    end
  end
  counts[MOST] = #words
  return tiles, of, words, counts
end

--- @param seats number
--- @param random Random
--- @return FourtilesState
local function newState(seats, random)
  local puzzles = private.FourtilesPuzzles
  local tiles, of, words, counts = parse(puzzles[random:Roll(#puzzles)])
  -- The tiles of a word don't lie next to each other, or in its order
  local order = {}
  for index = 1, #tiles do
    order[index] = index
  end
  random:Shuffle(order)
  local state = { seats = seats, tiles = {}, of = {}, words = words, counts = counts, total = 0, found = {}, list = {}, sizes = {}, score = 0, by = {}, done = false }
  for index, from in ipairs(order) do
    state.tiles[index], state.of[index] = tiles[from], of[from]
  end
  for size = 1, MOST do
    state.total = state.total + counts[size]
    state.sizes[size] = 0
  end
  for seat = 1, seats do
    state.by[seat] = 0
  end
  return state
end

--- What a move spells
--- @param state FourtilesState
--- @param move string
--- @return string? word nil for something that isn't one to four different tiles
--- @return number[]? tiles
local function spell(state, move)
  if #move < 1 or #move > MOST or not move:match("^%l+$") then
    return nil
  end
  local tiles, used, parts = {}, {}, {}
  for index = 1, #move do
    local tile = move:byte(index) - FIRST + 1
    if tile > #state.tiles or used[tile] then
      return nil
    end
    used[tile] = true
    tiles[index], parts[index] = tile, state.tiles[tile]
  end
  return table.concat(parts), tiles
end

--- The most points there are in a puzzle
--- @param state FourtilesState
--- @return number
local function mostPoints(state)
  local most = BONUS
  for size = 1, MOST do
    most = most + state.counts[size] * POINTS[size]
  end
  return most
end

--- @param score number
--- @return number rank 1 for the lowest
local function rankOf(score)
  local rank = 1
  for index, from in ipairs(RANKS) do
    if score >= from then
      rank = index
    end
  end
  return rank
end

--- Whether the game may be called done: the five long words are found and the top rank is reached
--- @param state FourtilesState
--- @return boolean
local function canWrapUp(state)
  return not state.done and state.sizes[MOST] == #state.words and state.score >= RANKS[#RANKS]
end

--- @param state FourtilesState
--- @param _ number
--- @param move string
--- @return boolean, string?
local function validate(state, _, move)
  if state.done then
    return false, "finished"
  elseif move == WRAP_UP then
    return canWrapUp(state), "fourtiles_early"
  end
  local word = spell(state, move)
  if not word then
    return false, "invalid_move"
  elseif state.found[word] then
    return false, "fourtiles_found"
  elseif not Lexicon.Has(LIST, word) then
    return false, "fourtiles_not_word"
  end
  return true
end

--- @param state FourtilesState
--- @param seat number
--- @param move string
--- @return FourtilesEvent
local function apply(state, seat, move)
  if move == WRAP_UP then
    state.done = true
    return { notation = L["fourtiles_wrapped"], done = true }
  end

  local word, tiles = spell(state, move)
  local size = #tiles
  local find = { word = word, size = size, seat = seat }
  state.found[word] = find
  state.list[#state.list + 1] = find
  state.sizes[size] = state.sizes[size] + 1

  local before = rankOf(state.score)
  local points = POINTS[size]
  local bonus = size == MOST and state.sizes[MOST] == #state.words
  local gained = points + (bonus and BONUS or 0)
  state.score = state.score + gained
  state.by[seat] = state.by[seat] + gained
  -- Nothing left to look for
  state.done = #state.list >= state.total

  local rank = rankOf(state.score)
  return {
    notation = word:lower(),
    word = word,
    size = size,
    points = points,
    bonus = bonus or nil,
    rank = rank > before and rank or nil,
    tiles = tiles,
    done = state.done or nil,
  }
end

--- @param state FourtilesState
local function result(state)
  if not state.done then
    return nil
  elseif state.seats == 1 then
    return { winner = 1 }
  end
  return { winner = 0, all = true }
end

--- @param state FourtilesState
--- @return string
local function progress(state)
  return L["fourtiles_progress"]:format(state.score, L["fourtiles_rank_" .. rankOf(state.score)])
end

-----------------------------
-- View
-----------------------------

local MARGIN, GAP = 12, 6
local SIDE_MIN, SIDE_MAX = 190, 280
local TRAY_HEIGHT, SAYS_HEIGHT, BUTTON_HEIGHT = 46, 20, 26
local TILE_WIDEST, TILE_TALLEST = 150, 58
local STAT_HEIGHT = 40
local ROW_HEIGHT = 18
local BUTTON_WIDTH = 96
-- The tiles are white pictures with round corners, tinted (Tools/make_fourtiles.py)
local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\Fourtiles\\"
-- How the tiles look: as they lie there, picked for the word being put together, and once the
-- long word they were cut from is found
local PLAIN = { 0.21, 0.22, 0.27 }
local PICKED = { 0.6, 0.45, 0.1 }
local SOLVED = { 0.15, 0.37, 0.22 }
-- What is written on them, in Lexend (GUI/Lettering.lua): a warm white, softer than white is on a
-- dark tile
local CHALK = { 0.94, 0.92, 0.86 }
-- How large the letters are and how round the corners, as fractions of a tile's height. A tile
-- is never too narrow for four letters: they get smaller first
local LETTERS, CORNERS = 0.44, 0.22
-- How wide a letter is, as a fraction of its size
local LETTER_WIDTH = 0.62
-- How long a shuffle takes the tiles, how much later each sets off than the one before it, and
-- how high they lift on the way
local SHUFFLE_FOR, SHUFFLE_AFTER, SHUFFLE_LIFT = 0.4, 0.012, 8
-- What each of two players found is written in
local SEAT_COLORS = { { 0.52, 0.8, 1 }, { 1, 0.66, 0.84 } }
local WHITE = { 1, 1, 1 }
local FOUND_SOUND, LONG_SOUND, REFUSE_SOUND, PICK_SOUND = "cardPlace", "IG_QUEST_LIST_COMPLETE", "IG_MAINMENU_OPTION_CHECKBOX_OFF", "cardSlide"
-- How long what the game says about a word stays
local SAYS_FOR = 4

--- @class FourtilesView: GameViewObject
--- @field view GameView?
local View = {}
View.__index = View

--- @param color number[]
--- @return string
local function hex(color)
  return ("|cff%02x%02x%02x"):format(color[1] * 255, color[2] * 255, color[3] * 255)
end

--- @param stage Frame
--- @return FourtilesView
local function createView(stage)
  local Widgets = private.Widgets
  local self = setmetatable({ stage = stage, tiles = {}, picked = {}, order = {}, width = 0, height = 0 }, View)

  -- The word being put together
  self.tray = Widgets.Panel(stage)
  self.word = private.Lettering.New(self.tray, 24)
  self.word:SetTextColor(unpack(Widgets.GOLD))
  self.word:SetPoint("CENTER", 0, 1)
  self.hint = self.tray:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  self.hint:SetPoint("CENTER")
  self.hint:SetText(L["fourtiles_hint"])
  self.says = stage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  self.says:SetJustifyH("CENTER")

  -- A button for each tile, that goes wherever the tile is laid
  for index = 1, TILES do
    local tile = CreateFrame("Button", nil, stage)
    tile.tile = index
    -- A shadow under it, the tile, the light along its top and the line around it once picked
    local shadow = Widgets.Slices(tile, IMAGES .. "body", "BACKGROUND", nil, { y = -2, grow = 1 })
    shadow:SetVertexColor(0, 0, 0, 0.45)
    tile.body = Widgets.Slices(tile, IMAGES .. "body", "BORDER")
    local gloss = Widgets.Slices(tile, IMAGES .. "gloss", "ARTWORK")
    tile.ring = Widgets.Slices(tile, IMAGES .. "ring", "ARTWORK", 1)
    tile.ring:SetVertexColor(1, 0.82, 0, 0.95)
    local hover = Widgets.Slices(tile, IMAGES .. "body", "HIGHLIGHT")
    hover:SetVertexColor(1, 1, 1, 0.07)
    tile.slices = { shadow, tile.body, gloss, tile.ring, hover }
    tile.label = private.Lettering.New(tile, 16)
    tile.label:SetPoint("CENTER", 0, 1)
    tile.label:SetShadow({ 0, 0, 0, 0.6 }, 0, -1)
    -- Where it comes in the word, small in its corner
    tile.number = private.Lettering.New(tile, 10)
    tile.number:SetTextColor(unpack(Widgets.GOLD))
    tile:SetScript("OnClick", function()
      self:pick(index)
    end)
    self.tiles[index] = tile
  end

  self.buttons = {
    shuffle = Widgets.Button(stage, L["fourtiles_shuffle"], BUTTON_WIDTH, BUTTON_HEIGHT),
    clear = Widgets.Button(stage, L["fourtiles_clear"], BUTTON_WIDTH, BUTTON_HEIGHT),
    enter = Widgets.Button(stage, L["fourtiles_enter"], BUTTON_WIDTH, BUTTON_HEIGHT),
    wrap = Widgets.Button(stage, L["fourtiles_wrap_up"], BUTTON_WIDTH + 30, BUTTON_HEIGHT),
  }
  self.buttons.shuffle:SetScript("OnClick", function()
    self:shuffle()
  end)
  self.buttons.clear:SetScript("OnClick", function()
    self:clear()
  end)
  self.buttons.enter:SetScript("OnClick", function()
    self:enter()
  end)
  self.buttons.wrap:SetScript("OnClick", function()
    self:wrapUp()
  end)
  self.buttons.wrap:SetScript("OnEnter", function(button)
    GameTooltip:SetOwner(button, "ANCHOR_TOP")
    GameTooltip:SetText(L["fourtiles_wrap_up"])
    GameTooltip:AddLine(L["fourtiles_wrap_up_tip"], 1, 1, 1, true)
    GameTooltip:Show()
  end)
  self.buttons.wrap:SetScript("OnLeave", GameTooltip_Hide)

  -- What is kept count of, and the words found so far
  self.score = Widgets.Stat(stage, L["stat_score"], SIDE_MIN, STAT_HEIGHT)
  self.rank = Widgets.Stat(stage, L["fourtiles_stat_rank"], SIDE_MIN, STAT_HEIGHT)
  self.count = Widgets.Stat(stage, L["fourtiles_stat_words"], SIDE_MIN, STAT_HEIGHT)
  self.next = stage:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  self.next:SetJustifyH("CENTER")
  self.who = stage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  self.who:SetJustifyH("CENTER")
  self.side = Widgets.Panel(stage)
  self.found = Widgets.List(self.side, SIDE_MIN, ROW_HEIGHT, function(content)
    local row = CreateFrame("Frame", nil, content)
    row.word = Widgets.Label(row, "GameFontHighlightSmall")
    row.word:SetPoint("LEFT", 8, 0)
    row.points = Widgets.Label(row, "GameFontDisableSmall")
    row.points:SetPoint("RIGHT", -10, 0)
    return row
  end)
  self.found.frame:SetPoint("TOPLEFT", 2, -4)
  self.found.frame:SetPoint("BOTTOMRIGHT", -2, 4)

  self.effects = private.Effects.New(stage)
  -- Takes the keys while the cursor is anywhere over the game, and times what is said
  local keys = CreateFrame("Frame", nil, stage)
  keys:SetAllPoints()
  self.animator = Widgets.Animator(keys)
  -- The tiles move on their own: what is said going away doesn't stop them
  self.slide = Widgets.Animator(CreateFrame("Frame", nil, stage))
  Widgets.Keys(keys, function(key)
    return self:key(key)
  end)
  return self
end

--- Says something about what the player just tried, for a while
--- @param text string
--- @param color number[]?
function View:say(text, color)
  -- Ending what was said before takes it away, so that comes first
  self.animator:Stop()
  self.says:SetText(text)
  self.says:SetTextColor(unpack(color or WHITE))
  if text ~= "" then
    self.animator:Play(SAYS_FOR, function() end, {
      onDone = function()
        self.says:SetText("")
      end,
    })
  end
end

--- The move the picked tiles make
--- @return string
function View:move()
  local letters = {}
  for index, tile in ipairs(self.picked) do
    letters[index] = string.char(FIRST + tile - 1)
  end
  return table.concat(letters)
end

--- Puts a tile on the end of the word, or takes it out of it again
--- @param tile number
function View:pick(tile)
  local view = self.view
  if not view or not view.canMove then
    return
  end
  local at
  for index, picked in ipairs(self.picked) do
    at = picked == tile and index or at
  end
  if at then
    table.remove(self.picked, at)
  elseif #self.picked < MOST then
    self.picked[#self.picked + 1] = tile
  else
    private.Widgets.PlaySound(REFUSE_SOUND)
    self:say(L["fourtiles_full"], private.Widgets.GREY)
    return
  end
  self.asked = nil
  private.Widgets.PlaySound(PICK_SOUND)
  self:draw()
end

function View:clear()
  self.picked, self.asked = {}, nil
  self:draw()
end

--- @param tile Button
--- @param x number From the left of the stage
--- @param y number Down from its top
function View:put(tile, x, y)
  tile:ClearAllPoints()
  tile:SetPoint("TOPLEFT", self.stage, "TOPLEFT", x, -y)
end

--- Puts every tile where it lies, at once
function View:place()
  self.slide:Stop()
  if not self.spots then
    return
  end
  for place, index in ipairs(self.order) do
    local spot = self.spots[place]
    self:put(self.tiles[index], spot[1], spot[2])
  end
end

--- Lays the tiles out another way, which is how words get seen. They slide there, lifting a little
--- on the way, one just after the other
function View:shuffle()
  -- One that is still on its way from the last shuffle is where it was going
  self.slide:Stop()
  local was = {}
  for place, index in ipairs(self.order) do
    was[index] = self.spots and self.spots[place]
  end
  for place = #self.order, 2, -1 do
    local other = math.random(place)
    self.order[place], self.order[other] = self.order[other], self.order[place]
  end
  for place, index in ipairs(self.order) do
    local tile, from, to = self.tiles[index], was[index], self.spots and self.spots[place]
    if from and from ~= to then
      self.slide:Play(SHUFFLE_FOR, function(progress)
        local lift = math.sin(progress * math.pi) * SHUFFLE_LIFT
        self:put(tile, from[1] + (to[1] - from[1]) * progress, from[2] + (to[2] - from[2]) * progress - lift)
      end, { ease = private.Widgets.Ease.inOut, delay = (place - 1) * SHUFFLE_AFTER })
    end
  end
  private.Widgets.PlaySound(PICK_SOUND)
  self:draw()
end

--- Tries the word that was put together
function View:enter()
  local view = self.view
  if not view or not view.canMove or #self.picked == 0 then
    return
  end
  local Widgets = private.Widgets
  --- @type FourtilesState
  local state = view.state
  local move = self:move()
  local word = spell(state, move)
  local ok, err = validate(state, view.seat, move)
  if ok then
    self.picked = {}
    view.submit(move)
    return
  end

  if err == "fourtiles_found" then
    local find = state.found[word]
    local mine = state.seats == 1 or find.seat == view.seat
    self:say(mine and L["fourtiles_found"]:format(word:lower()) or L["fourtiles_found_by"]:format(view.names[find.seat], word:lower()), Widgets.GREY)
  else
    self:say(L["fourtiles_not_word"]:format(word:lower()), Widgets.RED)
  end
  self.effects:Jolt(self.tray)
  Widgets.PlaySound(REFUSE_SOUND)
end

--- Calls the game done, once asked twice: it is over for everyone playing
function View:wrapUp()
  local view = self.view
  if not view or not view.canMove or not canWrapUp(view.state) then
    return
  end
  if not self.asked then
    self.asked = true
    self:say(L["fourtiles_wrap_up_sure"], private.Widgets.GOLD)
    self:draw()
    return
  end
  self.asked = nil
  view.submit(WRAP_UP)
end

--- @param key string
--- @return boolean
function View:key(key)
  local view = self.view
  if not view or not view.canMove or not self.stage:IsVisible() then
    return false
  end
  if key == "ENTER" then
    self:enter()
  elseif key == "BACKSPACE" or key == "DELETE" then
    if #self.picked == 0 then
      return false
    end
    table.remove(self.picked)
    self:draw()
  elseif key == "SPACE" then
    self:shuffle()
  else
    return false
  end
  return true
end

--- Lays everything out for the room there is
function View:arrange()
  local width, height, stage = self.width, self.height, self.stage
  local side = math.max(SIDE_MIN, math.min(SIDE_MAX, math.floor(width * 0.28)))
  local room = width - side - MARGIN * 3
  local tall = height - MARGIN * 2 - TRAY_HEIGHT - SAYS_HEIGHT - BUTTON_HEIGHT - GAP * 3
  local tileWidth = math.max(20, math.min(TILE_WIDEST, math.floor((room - GAP * (COLUMNS - 1)) / COLUMNS)))
  local tileHeight = math.max(14, math.min(TILE_TALLEST, math.floor((tall - GAP * (ROWS - 1)) / ROWS)))
  local board = tileWidth * COLUMNS + GAP * (COLUMNS - 1)
  local used = TRAY_HEIGHT + SAYS_HEIGHT + BUTTON_HEIGHT + GAP * 3 + tileHeight * ROWS + GAP * (ROWS - 1)
  local left, top = MARGIN + math.floor((room - board) / 2), math.floor((height - used) / 2)

  self.tray:SetSize(board, TRAY_HEIGHT)
  self.tray:ClearAllPoints()
  self.tray:SetPoint("TOPLEFT", stage, "TOPLEFT", left, -top)
  self.says:SetSize(board, SAYS_HEIGHT)
  self.says:ClearAllPoints()
  self.says:SetPoint("TOPLEFT", stage, "TOPLEFT", left, -(top + TRAY_HEIGHT + GAP))
  -- Where what a word scored drifts up from
  self.middleX, self.middleY = left + board / 2, top + TRAY_HEIGHT / 2

  local gridTop = top + TRAY_HEIGHT + SAYS_HEIGHT + GAP * 2
  self.spots = {}
  for place = 1, TILES do
    local column, row = (place - 1) % COLUMNS, math.floor((place - 1) / COLUMNS)
    self.spots[place] = { left + column * (tileWidth + GAP), gridTop + row * (tileHeight + GAP) }
  end
  local corner = math.max(4, math.floor(math.min(tileWidth, tileHeight) * CORNERS))
  local size = math.max(9, math.min(math.floor(tileHeight * LETTERS), math.floor((tileWidth - 10) / (4 * LETTER_WIDTH))))
  for _, tile in ipairs(self.tiles) do
    tile:SetSize(tileWidth, tileHeight)
    for _, slices in ipairs(tile.slices) do
      slices:SetCorner(corner)
    end
    if size ~= self.letterSize then
      tile.label:SetFontSize(size)
    end
    tile.number:ClearAllPoints()
    tile.number:SetPoint("TOPRIGHT", -math.floor(corner * 0.6) - 1, -3)
  end
  self.letterSize = size
  self:place()

  local buttonsTop = gridTop + tileHeight * ROWS + GAP * ROWS
  local buttons = self.buttons
  buttons.shuffle:ClearAllPoints()
  buttons.shuffle:SetPoint("TOPLEFT", stage, "TOPLEFT", left, -buttonsTop)
  buttons.clear:ClearAllPoints()
  buttons.clear:SetPoint("LEFT", buttons.shuffle, "RIGHT", GAP, 0)
  buttons.enter:ClearAllPoints()
  buttons.enter:SetPoint("TOPRIGHT", stage, "TOPLEFT", left + board, -buttonsTop)
  buttons.wrap:ClearAllPoints()
  buttons.wrap:SetPoint("TOP", stage, "TOPLEFT", left + board / 2, -buttonsTop)

  -- Down the right: the score, the rank, how many words, and under them the words themselves
  local sideLeft = width - MARGIN - side
  local half = math.floor((side - GAP) / 2)
  self.score:SetSize(half, STAT_HEIGHT)
  self.score:ClearAllPoints()
  self.score:SetPoint("TOPLEFT", stage, "TOPLEFT", sideLeft, -MARGIN)
  self.count:SetSize(side - half - GAP, STAT_HEIGHT)
  self.count:ClearAllPoints()
  self.count:SetPoint("TOPRIGHT", stage, "TOPLEFT", sideLeft + side, -MARGIN)
  self.rank:SetSize(side, STAT_HEIGHT)
  self.rank:ClearAllPoints()
  self.rank:SetPoint("TOPLEFT", stage, "TOPLEFT", sideLeft, -(MARGIN + STAT_HEIGHT + GAP))
  local below = MARGIN + (STAT_HEIGHT + GAP) * 2
  for _, line in ipairs({ self.next, self.who }) do
    line:SetSize(side, 14)
    line:ClearAllPoints()
    line:SetPoint("TOPLEFT", stage, "TOPLEFT", sideLeft, -below)
    below = below + 16
  end
  self.side:ClearAllPoints()
  self.side:SetPoint("TOPLEFT", stage, "TOPLEFT", sideLeft, -(below + GAP))
  self.side:SetPoint("BOTTOMRIGHT", stage, "TOPLEFT", sideLeft + side, -(height - MARGIN))
  self.found:SetWidth(side - 4)
end

--- @param width number
--- @param height number
function View:Layout(width, height)
  self.width, self.height = width, height
  self:arrange()
end

--- The words found so far, the long ones first, under how many of their kind there are
--- @return table[]
function View:listed()
  local view = self.view
  --- @type FourtilesState
  local state = view.state
  local items = {}
  for size = MOST, 1, -1 do
    items[#items + 1] = { header = L["fourtiles_size_" .. size], found = state.sizes[size], total = state.counts[size] }
    local words = {}
    for _, find in ipairs(state.list) do
      if find.size == size then
        words[#words + 1] = find
      end
    end
    table.sort(words, function(a, b)
      return a.word < b.word
    end)
    for _, find in ipairs(words) do
      items[#items + 1] = find
    end
  end
  return items
end

--- Shows the game as it stands
function View:draw()
  local view = self.view
  --- @type FourtilesState
  local state = view.state
  local Widgets = private.Widgets
  local shared = state.seats > 1

  -- The word so far, and where each of its tiles comes in it
  local at, parts = {}, {}
  for index, tile in ipairs(self.picked) do
    at[tile], parts[index] = index, state.tiles[tile]:lower()
  end
  self.word:SetText(table.concat(parts, "|cff808080·|r"))
  self.hint:SetShown(#parts == 0 and view.canMove)

  -- A long word that was found has its tiles marked, in the colour of whoever found it
  local solved = {}
  for _, find in ipairs(state.list) do
    if find.size == MOST then
      for index, word in ipairs(state.words) do
        if word == find.word then
          solved[index] = find.seat
        end
      end
    end
  end
  for index, tile in ipairs(self.tiles) do
    local color = at[index] and PICKED or (solved[state.of[index]] and SOLVED) or PLAIN
    tile.label:SetText(state.tiles[index]:lower())
    tile.label:SetTextColor(unpack(at[index] and WHITE or CHALK))
    tile.number:SetText(at[index] and tostring(at[index]) or "")
    tile.body:SetVertexColor(color[1], color[2], color[3])
    tile.ring:SetShown(at[index] ~= nil)
    tile:SetEnabled(view.canMove)
    tile:SetAlpha(view.canMove and 1 or 0.7)
  end

  local buttons = self.buttons
  buttons.shuffle:SetEnabled(view.canMove)
  buttons.clear:SetEnabled(view.canMove and #self.picked > 0)
  buttons.enter:SetEnabled(view.canMove and #self.picked > 0)
  buttons.wrap:SetShown(view.canMove and canWrapUp(state))
  buttons.wrap:SetText(L[self.asked and "fourtiles_wrap_up_again" or "fourtiles_wrap_up"])

  local rank = rankOf(state.score)
  self.score:Set(state.score)
  self.count:Set(L["fourtiles_of"]:format(#state.list, state.total))
  self.rank:Set(L["fourtiles_rank_" .. rank])
  self.rank:Tint(rank == #RANKS and Widgets.GOLD or nil)
  if rank < #RANKS then
    self.next:SetText(L["fourtiles_next_rank"]:format(RANKS[rank + 1] - state.score, L["fourtiles_rank_" .. rank + 1]))
  else
    self.next:SetText(L["fourtiles_most"]:format(mostPoints(state)))
  end
  local who = {}
  for seat = 1, shared and state.seats or 0 do
    who[seat] = hex(SEAT_COLORS[seat] or WHITE) .. view.names[seat] .. " " .. state.by[seat] .. "|r"
  end
  self.who:SetText(table.concat(who, "   "))

  self.found:Update(self:listed(), function(row, item)
    if item.header then
      row.word:SetText(item.header)
      row.word:SetTextColor(unpack(Widgets.GOLD))
      row.points:SetText(L["fourtiles_of"]:format(item.found, item.total))
    else
      row.word:SetText("  " .. item.word:lower())
      row.word:SetTextColor(unpack(shared and SEAT_COLORS[item.seat] or WHITE))
      row.points:SetText("")
    end
  end)
end

--- The game is over: says so across the board
--- @param after number? Seconds to wait first. At once for a game that was over before it was looked at
function View:finish(after)
  local state = self.view.state
  local title = L[#state.list >= state.total and "fourtiles_all_found" or "fourtiles_done"]
  self.effects:Banner(title, progress(state), { color = private.Widgets.GOLD, delay = after, instant = after == nil })
end

--- Shows a word being found, by whoever it was
--- @param event FourtilesEvent
function View:play(event)
  local view = self.view
  local Widgets, effects = private.Widgets, self.effects
  if event.word then
    local gained = "+" .. (event.points + (event.bonus and BONUS or 0))
    local theirs = event.seat ~= view.seat
    local color = event.size == MOST and Widgets.GOLD or Widgets.GREEN
    local word = event.word:lower()
    self:say(theirs and L["fourtiles_they_found"]:format(view.names[event.seat], word, gained) or (word .. "  " .. gained), color)
    effects:Float(gained, self.middleX, self.middleY, { color = color, size = event.size == MOST and 26 or 18 })
    if event.size == MOST then
      effects:Flash(Widgets.GOLD)
    end
    if event.bonus then
      effects:Confetti()
    end
    if event.rank then
      effects:Float(L["fourtiles_rank_" .. event.rank], self.middleX, self.middleY + 34, { color = Widgets.GOLD, size = 22, delay = 0.3 })
    end
    Widgets.PlaySound((event.size == MOST or event.rank) and LONG_SOUND or FOUND_SOUND)
  end
  if event.done then
    self:finish(1)
  end
end

--- @param view GameView
function View:Update(view)
  local before = self.view
  self.view = view
  --- @type FourtilesState
  local state = view.state
  local sameGame = before ~= nil and before.match.id == view.match.id

  if not sameGame then
    self.picked, self.asked = {}, nil
    for place = 1, TILES do
      self.order[place] = place
    end
    self:place()
    self.effects:Clear()
    self.says:SetText("")
  elseif not view.changed then
    -- Called often with nothing new: only whether the player may move can be another
    if before.canMove == view.canMove then
      return
    end
  end

  if not view.canMove then
    self.picked, self.asked = {}, nil
  end
  self:draw()
  if sameGame and view.changed and view.played and view.played.kind == "move" then
    self:play(view.played)
  elseif state.done and not self.effects:HasBanner() then
    self:finish()
  end
end

private.Fourtiles = { POINTS = POINTS, BONUS = BONUS, RANKS = RANKS, WRAP_UP = WRAP_UP, Parse = parse, Spell = spell, MostPoints = mostPoints, CanWrapUp = canWrapUp }

private.Games.Register({
  id = "fourtiles",
  name = L["game_fourtiles"],
  description = L["game_fourtiles_description"],
  genre = "words",
  icon = "Interface\\AddOns\\ForeverGames\\Images\\Icons\\fourtiles",
  version = 1,
  seats = { 1, 2 },
  together = true,
  newState = newState,
  validate = validate,
  apply = apply,
  result = result,
  progress = progress,
  createView = createView,
})
