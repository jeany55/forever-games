--------------------------
--  Wordle
--------------------------
-- A word is hidden, and the player has a guess more than it has letters to find it in. Every
-- guess has to be a word itself, and says of each of its letters whether it is in the hidden
-- word in that very place, somewhere else in it, or nowhere in it. A letter guessed twice is
-- only said to be in the word as many times as the word has it: the ones in the right place
-- first, then from the left.
--
-- Whoever sets a game up picks how long the word is (`length`, four to seven letters), whether it
-- is an everyday word or one only Azeroth knows (`words`), and whether what was found has to be
-- used (`hard`): every letter found in its place stays there in every guess after, and every
-- letter found somewhere has to be in them.
--
-- The everyday words to find are common ones (Lexicon/Wordle.lua, picked by
-- Tools/make_wordle.py), and a guess can be any word of the English list of Games/Words.lua. A
-- word of Azeroth is one of the names of Lexicon/Warcraft.lua, which can be guessed as well.
--
-- A move is the guess in small letters: "crane".
--
-- The game is timed from the first guess, and the best the player ever did by each set of rules
-- is kept: fewer guesses first, then less time. A race is won the same way, and the guesses
-- that took the rival there are shown once the player's own game is over, their colours only.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Lexicon = private.Lexicon

local ENGLISH, WARCRAFT = "english", "warcraft"
-- The words that can be the one to find, by the kind of word they are
local ANSWERS = { everyday = "wordle", warcraft = "wordlewarcraft" }
local LENGTHS = { 4, 5, 6, 7 }
-- What a guess says of a letter: in its place, somewhere else, nowhere
local CORRECT, PRESENT, ABSENT = "c", "p", "x"
-- A run's score is the guesses it took and then the time: so many points a guess spared, less a
-- point a second, the time never counting for as much as a guess
local SCALE = 10000
-- How many guesses the moves listed for a position go on to, at most
local LISTED = 30

--- @type GameOption[]
local OPTIONS = {
  {
    id = "length",
    name = L["wordle_option_length"],
    description = L["wordle_option_length_tip"],
    choices = LENGTHS,
    default = 5,
    label = function(value)
      return L["wordle_letters"]:format(value)
    end,
  },
  {
    id = "words",
    name = L["wordle_option_words"],
    description = L["wordle_option_words_tip"],
    choices = { "everyday", "warcraft" },
    default = "everyday",
    label = function(value)
      return L["wordle_words_" .. value]
    end,
  },
  {
    id = "hard",
    name = L["wordle_option_hard"],
    description = L["wordle_option_hard_tip"],
    default = false,
  },
}

--- @class WordleState
--- @field length number How many letters the word has
--- @field tries number How many guesses there are to find it in
--- @field words string What kind of word it is, see ANSWERS
--- @field hard boolean Whatever was found has to be used
--- @field answer string The word to find, in capitals
--- @field guesses string[] What was guessed, in capitals
--- @field marks string[] What each guess said of its letters, a character each: CORRECT, PRESENT or ABSENT
--- @field outcome { winner: number, detail: string? }?

--- @class WordleEvent: MatchEvent
--- @field guess string
--- @field marks string
--- @field solved boolean?
--- @field out boolean? That was the last guess, and it wasn't the word

-----------------------------
-- Rules
-----------------------------

--- @param seats number
--- @param random Random
--- @param rules table<string, any>
--- @return WordleState
local function newState(_, random, rules)
  local length, words = rules.length or 5, rules.words or "everyday"
  local list = ANSWERS[words]
  return {
    length = length,
    tries = length + 1,
    words = words,
    hard = rules.hard == true,
    answer = Lexicon.At(list, length, random:Roll(Lexicon.Size(list, length))),
    guesses = {},
    marks = {},
  }
end

--- What a guess says of each of its letters
--- @param answer string
--- @param guess string
--- @return string marks A character for each letter: CORRECT, PRESENT or ABSENT
local function mark(answer, guess)
  local marks, left = {}, {}
  for index = 1, #answer do
    local wanted, said = answer:sub(index, index), guess:sub(index, index)
    if wanted == said then
      marks[index] = CORRECT
    else
      left[wanted] = (left[wanted] or 0) + 1
    end
  end
  -- What is left of each letter once the ones in their place are taken, from the left
  for index = 1, #guess do
    if not marks[index] then
      local said = guess:sub(index, index)
      if (left[said] or 0) > 0 then
        marks[index], left[said] = PRESENT, left[said] - 1
      else
        marks[index] = ABSENT
      end
    end
  end
  return table.concat(marks)
end

--- What a guess leaves out of what was found, in a game where all of it has to be used: a
--- letter that was found in a place and isn't in it, or one found somewhere that isn't anywhere
--- @param state WordleState
--- @param word string In capitals
--- @return { letter: string, at: number? }? nil for a guess that uses all of it. `at` for a letter that has to be in that place
local function unused(state, word)
  local needed = {}
  for turn, guess in ipairs(state.guesses) do
    local marks, found = state.marks[turn], {}
    for index = 1, #guess do
      local letter, said = guess:sub(index, index), marks:sub(index, index)
      if said == CORRECT and word:sub(index, index) ~= letter then
        return { letter = letter, at = index }
      end
      if said ~= ABSENT then
        found[letter] = (found[letter] or 0) + 1
      end
    end
    for letter, count in pairs(found) do
      needed[letter] = math.max(needed[letter] or 0, count)
    end
  end
  local letters = {}
  for letter, count in pairs(needed) do
    local _, has = word:gsub(letter, "")
    if has < count then
      letters[#letters + 1] = letter
    end
  end
  -- The same one whichever way the table is gone through
  table.sort(letters)
  return letters[1] and { letter = letters[1] } or nil
end

--- Whether a word may be guessed at all: it is a word, of the right kind
--- @param state WordleState
--- @param word string In capitals
--- @return boolean
local function isWord(state, word)
  return Lexicon.Has(ENGLISH, word) or (state.words == "warcraft" and Lexicon.Entry(WARCRAFT, word) ~= nil) or word == state.answer
end

--- @param state WordleState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  if seat ~= 1 then
    return false, "not_your_turn"
  elseif state.outcome then
    return false, "finished"
  elseif type(move) ~= "string" or #move ~= state.length or not move:match("^%l+$") then
    return false, "wordle_short"
  end
  local word = move:upper()
  for _, guess in ipairs(state.guesses) do
    if guess == word then
      return false, "wordle_guessed"
    end
  end
  if not isWord(state, word) then
    return false, "wordle_not_word"
  elseif state.hard and unused(state, word) then
    return false, "wordle_hard"
  end
  return true
end

--- @param state WordleState
--- @param seat number
--- @param move string
--- @return WordleEvent
local function apply(state, _, move)
  local guess = move:upper()
  local marks = mark(state.answer, guess)
  state.guesses[#state.guesses + 1] = guess
  state.marks[#state.marks + 1] = marks
  --- @type WordleEvent
  local event = { notation = move, guess = guess, marks = marks }
  if guess == state.answer then
    state.outcome = { winner = 1 }
    event.solved = true
  elseif #state.guesses >= state.tries then
    state.outcome = { winner = 0, detail = "wordle_out" }
    event.out = true
  end
  return event
end

--- Guesses that could be made, some of the words that could be the one: every one of them is a
--- word, and uses what was found where it has to be. The word itself always could, so there is
--- always one
--- @param state WordleState
--- @return string[]
local function moves(state)
  local list = {}
  if state.outcome then
    return list
  end
  local answers = ANSWERS[state.words]
  local size = Lexicon.Size(answers, state.length)
  -- Somewhere else in the list for every guess, so a game played out of them gets somewhere
  local start = (#state.guesses * 37) % size
  for step = 0, size - 1 do
    local word = Lexicon.At(answers, state.length, (start + step) % size + 1):lower()
    if validate(state, 1, word) then
      list[#list + 1] = word
      if #list >= LISTED then
        break
      end
    end
  end
  return list
end

--- The word as it is properly written: a name of Azeroth with its capitals and apostrophes
--- @param state WordleState
--- @return string
local function written(state)
  local entry = state.words == "warcraft" and Lexicon.Entry(WARCRAFT, state.answer)
  return entry and entry.name:upper() or state.answer
end

--- What the best by a set of rules is kept under
--- @param length number
--- @param words string
--- @param hard boolean
--- @return string
local function scoreKey(length, words, hard)
  return "score" .. length .. (words == "warcraft" and "w" or "") .. (hard and "h" or "")
end

--- What a run came to: the guesses it took, then its time
--- @param state WordleState
--- @param seconds number
--- @return number
local function score(state, seconds)
  local spared = state.tries + 1 - #state.guesses
  return spared * SCALE + (SCALE - 1 - math.min(SCALE - 1, math.floor(seconds)))
end

--- How a score is shown: "3/6 in 1:24"
--- @param tries number
--- @param value number
--- @return string
local function showScore(tries, value)
  value = math.floor(value + 0.5)
  local guesses = tries + 1 - math.floor(value / SCALE)
  local seconds = SCALE - 1 - value % SCALE
  return L["wordle_score"]:format(guesses, tries, ("%d:%02d"):format(math.floor(seconds / 60), seconds % 60))
end

--- @param state WordleState
--- @return string
local function progress(state)
  if state.outcome and state.outcome.winner == 1 then
    return L["wordle_progress_solved"]:format(#state.guesses, state.tries)
  elseif state.outcome then
    return L["wordle_progress_out"]
  end
  return L["wordle_progress"]:format(#state.guesses, state.tries)
end

-----------------------------
-- View
-----------------------------
-- A row of tiles for every guess there is, the one being typed among them, and under them a
-- keyboard whose keys take on the colour of what is known of their letter. Letters are typed
-- with the keys while the cursor is over the game, or clicked on the keyboard. A guess turns its
-- tiles over one after the other to show what it said, and one that can't be made shakes its
-- row with a word on why.

local MARGIN, GAP, KEY_GAP = 14, 6, 5
local TILE_MOST, KEY_WIDEST, KEY_RATIO = 62, 44, 1.32
local SAYS_HEIGHT, TALLY_HEIGHT = 22, 18
-- The tiles are white pictures with round corners, tinted, the ones Fourtiles is played with
-- (Tools/make_fourtiles.py)
local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\Fourtiles\\"
-- What the tiles and keys are tinted: nothing in them yet, a letter typed, and what a guess said
-- of a letter. The same as in Tools/make_wordle.py
local EMPTY = { 0.11, 0.11, 0.13 }
local TYPED = { 0.17, 0.17, 0.2 }
local KEY = { 0.32, 0.33, 0.37 }
local TINTS = { [CORRECT] = { 0.33, 0.55, 0.31 }, [PRESENT] = { 0.79, 0.63, 0.13 }, [ABSENT] = { 0.23, 0.23, 0.25 } }
local RING_EMPTY, RING_TYPED = { 0.3, 0.3, 0.34 }, { 0.62, 0.62, 0.68 }
local CHALK = { 0.96, 0.95, 0.92 }
-- What is known of a letter beats what isn't
local KNOWN = { [CORRECT] = 3, [PRESENT] = 2, [ABSENT] = 1 }
local KEY_ROWS = { "QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM" }
local ENTER, BACK = "ENTER", "BACK"
-- How large the letters are and how round the corners, as fractions of a tile's side
local LETTERS, CORNERS = 0.52, 0.16
-- How long a tile takes to turn over and how much later the next one starts, and how long a
-- typed letter makes its tile swell for
local FLIP, FLIP_AFTER, POP = 0.36, 0.22, 0.1
-- The tiles of a word that was found jump one after the other, this high as a part of a tile
local JUMP, JUMP_AFTER, JUMP_HEIGHT = 0.32, 0.09, 0.32
-- How long what the game says stays
local SAYS_FOR = 2.5
-- The words a word found in so many guesses is called, and their colours: those of an item's quality
local QUALITIES = { "legendary", "epic", "rare", "uncommon", "common", "poor" }
local QUALITY_COLORS = {
  legendary = { 1, 0.5, 0 },
  epic = { 0.64, 0.21, 0.93 },
  rare = { 0, 0.44, 0.87 },
  uncommon = { 0.12, 1, 0 },
  common = { 1, 1, 1 },
  poor = { 0.62, 0.62, 0.62 },
}
local TYPE_SOUND, FLIP_SOUND, REFUSE_SOUND, WIN_SOUND, LOSE_SOUND = "cardSlide", "cardPlace", "IG_MAINMENU_OPTION_CHECKBOX_OFF", "UI_EPICLOOT_TOAST", "IG_QUEST_FAILED"
-- The rival's guesses, how big as a part of a tile
local RIVAL_SCALE = 0.36

--- @class WordleView: GameViewObject
--- @field view GameView?
--- @field typed string What is typed of the next guess, in capitals
--- @field shown number How many of the guesses show what they said
local View = {}
View.__index = View

--- @param parent Frame
--- @return Frame tile
local function newTile(parent)
  local Widgets = private.Widgets
  local tile = CreateFrame("Frame", nil, parent)
  tile.body = Widgets.Slices(tile, IMAGES .. "body", "BORDER")
  local gloss = Widgets.Slices(tile, IMAGES .. "gloss", "ARTWORK")
  gloss:SetVertexColor(1, 1, 1, 0.6)
  tile.ring = Widgets.Slices(tile, IMAGES .. "ring", "ARTWORK", 1)
  tile.slices = { tile.body, gloss, tile.ring }
  tile.label = private.Lettering.New(tile, 16)
  tile.label:SetPoint("CENTER", 0, 1)
  tile.label:SetShadow({ 0, 0, 0, 0.5 }, 0, -1)
  return tile
end

--- @param parent Frame
--- @param text string
--- @param onClick fun()
--- @return Button key
local function newKey(parent, text, onClick)
  local Widgets = private.Widgets
  local key = CreateFrame("Button", nil, parent)
  key.body = Widgets.Slices(key, IMAGES .. "body", "BORDER")
  local gloss = Widgets.Slices(key, IMAGES .. "gloss", "ARTWORK")
  gloss:SetVertexColor(1, 1, 1, 0.5)
  local hover = Widgets.Slices(key, IMAGES .. "body", "HIGHLIGHT")
  hover:SetVertexColor(1, 1, 1, 0.08)
  key.slices = { key.body, gloss, hover }
  key.label = key:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  key.label:SetPoint("CENTER", 0, 1)
  key.label:SetText(text)
  key:SetScript("OnClick", onClick)
  return key
end

--- Shows a tile as it is: empty, with a letter typed, or with what a guess said of its letter
--- @param tile Frame
--- @param letter string?
--- @param said string? CORRECT, PRESENT or ABSENT for a letter that was guessed
local function paint(tile, letter, said)
  local tint = said and TINTS[said] or (letter and TYPED or EMPTY)
  tile.body:SetVertexColor(tint[1], tint[2], tint[3])
  local ring = letter and RING_TYPED or RING_EMPTY
  tile.ring:SetShown(not said)
  tile.ring:SetVertexColor(ring[1], ring[2], ring[3], 0.9)
  tile.label:SetText(letter or "")
  tile.label:SetTextColor(unpack(CHALK))
  tile.letter, tile.said = letter, said
end

--- @param stage Frame
--- @return WordleView
local function createView(stage)
  local Widgets = private.Widgets
  local self = setmetatable({ stage = stage, rows = {}, keys = {}, rival = {}, typed = "", shown = 0, width = 0, height = 0 }, View)

  self.says = stage:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  self.says:SetJustifyH("CENTER")
  self.tally = stage:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  self.tally:SetJustifyH("CENTER")

  for row = 1, 3 do
    for letter in KEY_ROWS[row]:gmatch(".") do
      self.keys[letter] = newKey(stage, letter, function()
        self:press(letter)
      end)
    end
  end
  self.keys[ENTER] = newKey(stage, L["wordle_enter"], function()
    self:press(ENTER)
  end)
  self.keys[BACK] = newKey(stage, L["wordle_back"], function()
    self:press(BACK)
  end)

  self.rivalName = stage:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  self.rivalName:SetJustifyH("CENTER")

  self.effects = private.Effects.New(stage)
  -- Takes the keys while the cursor is anywhere over the game, runs the clock and times what is
  -- said and the tiles turning over
  local keys = CreateFrame("Frame", nil, stage)
  keys:SetAllPoints()
  Widgets.Keys(keys, function(key)
    return self:key(key)
  end)
  self.animator = Widgets.Animator(keys)
  -- A typed letter's tile swelling doesn't keep the next letter waiting, as the tiles of a guess
  -- turning over do
  self.popping = Widgets.Animator(CreateFrame("Frame", nil, stage))
  self.saying = Widgets.Animator(CreateFrame("Frame", nil, stage))
  self.ticker = CreateFrame("Frame", nil, stage)
  self.ticker:SetScript("OnUpdate", function()
    self:tick()
  end)
  return self
end

--- The row of tiles for a guess, made the first time it is needed
--- @param index number
--- @return Frame
function View:row(index)
  local row = self.rows[index]
  if not row then
    row = CreateFrame("Frame", nil, self.stage)
    row.tiles = {}
    self.rows[index] = row
  end
  return row
end

--- A tile of a row, made the first time it is needed
--- @param row Frame
--- @param index number
--- @return Frame
local function tileOf(row, index)
  row.tiles[index] = row.tiles[index] or newTile(row)
  return row.tiles[index]
end

--- Says something about what the player just tried, for a while
--- @param text string
--- @param color number[]?
function View:say(text, color)
  self.saying:Stop()
  self.says:SetText(text)
  self.says:SetTextColor(unpack(color or { 1, 1, 1 }))
  self.saying:Play(SAYS_FOR, function() end, {
    onDone = function()
      self.says:SetText("")
    end,
  })
end

--- @param width number
--- @param height number
function View:Layout(width, height)
  self.width, self.height = width, height
  if self.view then
    self:arrange()
    self:draw()
  end
end

--- Lays the tiles and the keys out for the room there is and the size of the word
function View:arrange()
  --- @type WordleState
  local state = self.view.state
  local width, height, stage = self.width, self.height, self.stage
  local columns, rows = state.length, state.tries

  local keyWidth = math.max(16, math.min(KEY_WIDEST, math.floor((width - MARGIN * 2 - KEY_GAP * 9) / 10)))
  local keyHeight = math.floor(keyWidth * KEY_RATIO)
  local keyboard = keyHeight * 3 + KEY_GAP * 2
  -- A rival's guesses go to the right of the board, in a race that is over
  local room = width - MARGIN * 2
  local tall = height - MARGIN * 2 - SAYS_HEIGHT - TALLY_HEIGHT - keyboard - GAP * 3 - GAP * (rows - 1)
  local tile = math.max(14, math.min(TILE_MOST, math.floor(tall / rows), math.floor((room * 0.7 - GAP * (columns - 1)) / columns)))
  local board = tile * columns + GAP * (columns - 1)
  local used = SAYS_HEIGHT + tile * rows + GAP * (rows - 1) + GAP * 3 + keyboard + TALLY_HEIGHT
  local top = math.max(MARGIN, math.floor((height - used) / 2))
  local left = math.floor((width - board) / 2)
  self.tile, self.boardLeft, self.boardWidth = tile, left, board

  self.says:SetSize(width, SAYS_HEIGHT)
  self.says:ClearAllPoints()
  self.says:SetPoint("TOP", stage, "TOP", 0, -top)

  local corner = math.max(3, math.floor(tile * CORNERS))
  local size = math.max(9, math.floor(tile * LETTERS))
  local boardTop = top + SAYS_HEIGHT + GAP
  for index = 1, math.max(rows, #self.rows) do
    local row = self:row(index)
    row:SetShown(index <= rows)
    row:SetSize(board, tile)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", stage, "TOPLEFT", left, -(boardTop + (index - 1) * (tile + GAP)))
    for column = 1, math.max(columns, #row.tiles) do
      local piece = tileOf(row, column)
      piece:SetShown(column <= columns)
      piece:SetSize(tile, tile)
      piece:ClearAllPoints()
      piece:SetPoint("CENTER", row, "LEFT", (column - 1) * (tile + GAP) + tile / 2, 0)
      for _, slices in ipairs(piece.slices) do
        slices:SetCorner(corner)
      end
      piece.label:SetFontSize(size)
    end
  end
  self.rivalTop = boardTop

  -- The keyboard, its rows in the middle, Enter and Back either side of the last
  local keysTop = boardTop + tile * rows + GAP * (rows - 1) + GAP * 2
  local keyCorner = math.max(3, math.floor(keyWidth * 0.18))
  local wide = math.floor(keyWidth * 1.5 + KEY_GAP / 2)
  for number, letters in ipairs(KEY_ROWS) do
    local count = #letters
    local across = count * keyWidth + (count - 1) * KEY_GAP
    if number == 3 then
      across = across + (wide + KEY_GAP) * 2
    end
    local x = math.floor((width - across) / 2)
    local y = keysTop + (number - 1) * (keyHeight + KEY_GAP)
    local function put(key, keyWide)
      key:SetSize(keyWide, keyHeight)
      key:ClearAllPoints()
      key:SetPoint("TOPLEFT", stage, "TOPLEFT", x, -y)
      for _, slices in ipairs(key.slices) do
        slices:SetCorner(keyCorner)
      end
      x = x + keyWide + KEY_GAP
    end
    if number == 3 then
      put(self.keys[ENTER], wide)
    end
    for letter in letters:gmatch(".") do
      put(self.keys[letter], keyWidth)
    end
    if number == 3 then
      put(self.keys[BACK], wide)
    end
  end

  self.tally:SetSize(width, TALLY_HEIGHT)
  self.tally:ClearAllPoints()
  self.tally:SetPoint("TOP", stage, "TOP", 0, -(keysTop + keyboard + GAP))
  -- Where what was said about a guess comes from
  self.middleY = boardTop + (tile * rows) / 2
end

--- What each letter is known to be, from the guesses that show what they said
--- @return table<string, string>
function View:known()
  --- @type WordleState
  local state = self.view.state
  local known = {}
  for turn = 1, math.min(self.shown, #state.guesses) do
    local guess, marks = state.guesses[turn], state.marks[turn]
    for index = 1, #guess do
      local letter, said = guess:sub(index, index), marks:sub(index, index)
      if not known[letter] or KNOWN[said] > KNOWN[known[letter]] then
        known[letter] = said
      end
    end
  end
  return known
end

--- Shows everything as it stands, at once
function View:draw()
  local view = self.view
  --- @type WordleState
  local state = view.state
  local typing = #state.guesses + 1
  for index = 1, state.tries do
    local row = self:row(index)
    local guess, marks = state.guesses[index], state.marks[index]
    for column = 1, state.length do
      local tile = tileOf(row, column)
      if guess then
        paint(tile, guess:sub(column, column), index <= self.shown and marks:sub(column, column) or nil)
      elseif index == typing and view.canMove then
        local letter = self.typed:sub(column, column)
        paint(tile, letter ~= "" and letter or nil)
      else
        paint(tile, nil)
      end
    end
  end

  local known = self:known()
  for letter, key in pairs(self.keys) do
    local tint = TINTS[known[letter] or ""] or KEY
    key.body:SetVertexColor(tint[1], tint[2], tint[3])
    key.label:SetTextColor(known[letter] == ABSENT and 0.6 or 1, known[letter] == ABSENT and 0.6 or 1, known[letter] == ABSENT and 0.6 or 1)
    key:SetEnabled(view.canMove)
  end
  self:drawRival()
  self:writeTally()
end

--- Writes how many guesses there have been, and the time
function View:writeTally()
  local view = self.view
  --- @type WordleState
  local state = view.state
  self.seconds = math.floor(view.clock())
  self.tally:SetText(L["wordle_tally"]:format(math.min(state.tries, #state.guesses + (state.outcome and 0 or 1)), state.tries, private.Widgets.Time(self.seconds)))
end

--- Keeps the clock going
function View:tick()
  if self.view and math.floor(self.view.clock()) ~= self.seconds then
    self:writeTally()
  end
end

--- In a race that is over for the player: the colours of the rival's guesses, once they are known
function View:drawRival()
  local view = self.view
  --- @type WordleState
  local state = view.state
  local ghost = state.outcome and view.race and view.race.ghost or nil
  local small = math.max(5, math.floor((self.tile or 20) * RIVAL_SCALE))
  local gap = math.max(1, math.floor(small / 6))
  local left = (self.boardLeft or 0) + (self.boardWidth or 0) + MARGIN * 2
  local count = 0
  for turn, marks in ipairs(ghost or {}) do
    if #marks == state.length and not marks:find("[^cpx]") then
      for index = 1, #marks do
        count = count + 1
        local square = self.rival[count]
        if not square then
          square = self.stage:CreateTexture(nil, "ARTWORK")
          square:SetTexture(IMAGES .. "body")
          self.rival[count] = square
        end
        local tint = TINTS[marks:sub(index, index)]
        square:SetVertexColor(tint[1], tint[2], tint[3])
        square:SetSize(small, small)
        square:ClearAllPoints()
        square:SetPoint("TOPLEFT", self.stage, "TOPLEFT", left + (index - 1) * (small + gap), -((self.rivalTop or 0) + 18 + (turn - 1) * (small + gap)))
        square:Show()
      end
    end
  end
  for index = count + 1, #self.rival do
    self.rival[index]:Hide()
  end
  self.rivalName:SetShown(count > 0)
  if count > 0 then
    self.rivalName:SetText(view.race.rival)
    self.rivalName:ClearAllPoints()
    self.rivalName:SetPoint("TOPLEFT", self.stage, "TOPLEFT", left, -(self.rivalTop or 0))
  end
end

--- A key of the keyboard was pressed, or clicked on screen
--- @param key string A letter, ENTER or BACK
function View:press(key)
  local view = self.view
  if not view or not view.canMove or self.animator:Busy() then
    return
  end
  --- @type WordleState
  local state = view.state
  if key == ENTER then
    self:enter()
    return
  elseif key == BACK then
    if #self.typed > 0 then
      self.typed = self.typed:sub(1, -2)
      self:draw()
    end
    return
  elseif #self.typed >= state.length then
    return
  end
  self.typed = self.typed .. key
  self:draw()
  -- The tile it went in swells a little
  local tile = tileOf(self:row(#state.guesses + 1), #self.typed)
  local side = self.tile
  self.popping:Play(POP, function(progress)
    local swell = side * (1 + 0.1 * math.sin(progress * math.pi))
    tile:SetSize(swell, swell)
  end)
  private.Widgets.PlaySound(TYPE_SOUND)
end

--- Makes the guess that is typed, or says why it can't be made
function View:enter()
  local view = self.view
  local Widgets = private.Widgets
  --- @type WordleState
  local state = view.state
  local move = self.typed:lower()
  local ok, err = validate(state, view.seat, move)
  if ok then
    -- What it says goes with the run first: once the last guess is made the run keeps no more
    if view.sample then
      view.sample(mark(state.answer, self.typed))
    end
    self.typed = ""
    view.submit(move)
    return
  end

  local text = L["wordle_not_word"]
  if err == "wordle_short" then
    text = L["wordle_short"]
  elseif err == "wordle_guessed" then
    text = L["wordle_guessed"]
  elseif err == "wordle_hard" then
    local miss = unused(state, self.typed)
    text = miss.at and L["wordle_hard_place"]:format(miss.at, miss.letter) or L["wordle_hard_use"]:format(miss.letter)
  end
  self:say(text, Widgets.GREY)
  self.effects:Jolt(self:row(#state.guesses + 1), 8)
  Widgets.PlaySound(REFUSE_SOUND)
end

--- @param key string
--- @return boolean
function View:key(key)
  local view = self.view
  if not view or not view.canMove or not self.stage:IsVisible() then
    return false
  end
  if key == "ENTER" then
    self:press(ENTER)
  elseif key == "BACKSPACE" or key == "DELETE" then
    self:press(BACK)
  elseif #key == 1 and key:match("%a") then
    self:press(key:upper())
  else
    return false
  end
  return true
end

--- The word a guess found the word in is called, for the number of guesses it took
--- @param guesses number
--- @return string
local function quality(guesses)
  return QUALITIES[math.min(guesses, #QUALITIES)]
end

--- Writes across the board how the game ended
--- @param delay number? Seconds to wait first
--- @param instant boolean? For a game that was over before it was looked at
function View:verdict(delay, instant)
  local view = self.view
  --- @type WordleState
  local state = view.state
  if state.outcome.winner == 1 then
    local named = quality(#state.guesses)
    local subtitle = L["wordle_solved_in"]:format(written(state), #state.guesses, state.tries, private.Widgets.Time(view.clock()))
    self.effects:Banner(L["wordle_quality_" .. named], subtitle, { color = QUALITY_COLORS[named], delay = delay, instant = instant })
  else
    self.effects:Banner(L["wordle_out"], L["wordle_was"]:format(written(state)), { color = private.Widgets.RED, delay = delay, instant = instant })
  end
end

--- Turns the tiles of the last guess over one after the other to show what it said, then shows
--- the keys and how the game ended
--- @param event WordleEvent
function View:reveal(event)
  local view = self.view
  --- @type WordleState
  local state = view.state
  local turn = #state.guesses
  local row = self:row(turn)
  local side = self.tile
  self.shown = turn - 1
  self:draw()
  for column = 1, state.length do
    local tile = tileOf(row, column)
    local turned = false
    self.animator:Play(FLIP, function(progress)
      local squash = math.abs(math.cos(progress * math.pi))
      tile:SetSize(side, math.max(1, side * squash))
      tile.label:SetAlpha(squash > 0.3 and 1 or 0)
      if progress >= 0.5 and not turned then
        turned = true
        paint(tile, event.guess:sub(column, column), event.marks:sub(column, column))
      end
    end, {
      delay = (column - 1) * FLIP_AFTER,
      onStart = function()
        private.Widgets.PlaySound(FLIP_SOUND)
      end,
    })
  end
  local after = (state.length - 1) * FLIP_AFTER + FLIP
  self.animator:Play(0, function() end, {
    delay = after,
    onDone = function()
      self.shown = turn
      self:draw()
      if event.solved then
        self:jump(row)
      end
    end,
  })
  if event.solved then
    self.effects:Confetti(after + JUMP)
    self:verdict(after + JUMP + state.length * JUMP_AFTER)
    private.Widgets.PlaySound(WIN_SOUND)
  elseif event.out then
    self:verdict(after + 0.2)
    self.animator:Play(0, function() end, {
      delay = after,
      onDone = function()
        private.Widgets.PlaySound(LOSE_SOUND)
      end,
    })
  end
end

--- The tiles of the word that was found jump, one after the other
--- @param row Frame
function View:jump(row)
  local side = self.tile
  for column = 1, self.view.state.length do
    local tile = tileOf(row, column)
    local x = (column - 1) * (side + GAP) + side / 2
    self.animator:Play(JUMP, function(progress)
      tile:ClearAllPoints()
      tile:SetPoint("CENTER", row, "LEFT", x, math.sin(progress * math.pi) * side * JUMP_HEIGHT)
    end, { delay = (column - 1) * JUMP_AFTER })
  end
end

--- @return boolean
function View:Busy()
  return self.animator:Busy()
end

--- @param view GameView
function View:Update(view)
  local before = self.view
  self.view = view
  --- @type WordleState
  local state = view.state
  local sameGame = before ~= nil and before.match.id == view.match.id
  local reshaped = not before or before.state.length ~= state.length or before.state.tries ~= state.tries

  if not sameGame then
    self.popping:Stop()
    self.animator:Stop()
    self.effects:Clear()
    self.saying:Stop()
    self.typed, self.shown = "", #state.guesses
    self:arrange()
    self:draw()
    if state.outcome then
      self:verdict(nil, true)
    end
    return
  elseif reshaped then
    self:arrange()
  end

  --- @type WordleEvent?
  local event = view.played
  if view.changed and event and event.guess and (view.live or view.catching) then
    self.popping:Stop()
    self.animator:Stop()
    self:arrange()
    self:reveal(event)
  elseif view.changed then
    self.animator:Stop()
    self:arrange()
    self.shown = #state.guesses
    self:draw()
  elseif not self.animator:Busy() then
    -- Called often with nothing new: whether the player may move can be another, and the
    -- rival's guesses can have arrived
    self:draw()
  end
end

private.Wordle = { Mark = mark, Unused = unused, Score = score, ShowScore = showScore, ScoreKey = scoreKey }

private.Games.Register({
  id = "wordle",
  name = L["game_wordle"],
  description = L["game_wordle_description"],
  genre = "words",
  icon = "Interface\\AddOns\\ForeverGames\\Images\\Icons\\wordle",
  version = 1,
  seats = 1,
  options = OPTIONS,
  howto = {
    { heading = L["howto_goal"], text = L["wordle_howto_goal"] },
    { heading = L["wordle_howto_colours"], text = L["wordle_howto_colours_text"] },
    { heading = L["howto_controls"], text = L["wordle_howto_controls"] },
    {
      heading = L["wordle_howto_hard"],
      text = function(rules)
        return rules.hard and L["wordle_howto_hard_text"] or nil
      end,
    },
    {
      heading = L["wordle_howto_warcraft"],
      text = function(rules)
        return rules.words == "warcraft" and L["wordle_howto_warcraft_text"] or nil
      end,
    },
    { heading = L["howto_end"], text = L["wordle_howto_end"] },
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
  progress = progress,
  record = function(state, seconds)
    -- Only a word that was found is worth keeping, by fewer guesses and then less time
    if state.outcome and state.outcome.winner == 1 then
      return { { key = scoreKey(state.length, state.words, state.hard), value = score(state, seconds) } }
    end
    return nil
  end,
  -- A race is won on the guesses, then the time, and the colours of each guess go with it
  raceFor = function(rules)
    return {
      key = scoreKey(rules.length, rules.words, rules.hard),
      show = function(value)
        return showScore(rules.length + 1, value)
      end,
    }
  end,
  ghost = { marks = true },
  -- The day's word is an everyday one of five letters, and counts by the guesses it took
  daily = {
    rules = { length = 5, words = "everyday", hard = false },
    score = function(state)
      return state.outcome and state.outcome.winner == 1 and #state.guesses or nil
    end,
    lower = true,
  },
  createView = createView,
})
