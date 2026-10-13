--------------------------
--  Words with Warcraft
--------------------------
-- For two to four players, with a bag of lettered tiles and a board of fifteen squares by
-- fifteen. Everyone holds seven tiles and in turn lays some of them in one line to make a word,
-- reading across or down, then draws back up to seven. The first word lies on the middle square
-- and every one after it joins what is on the board already: whatever new words that makes
-- where tiles come to lie next to each other have to be words as well, and all of them score.
--
-- A tile scores what its letter is worth. Some squares double or triple the tile first put on
-- them, others the whole word, and laying all seven tiles at once is worth a bonus. The two
-- blank tiles stand for any letter and are worth nothing. Instead of laying tiles a player may
-- swap some for others from the bag, while there are still seven in it, or pass.
--
-- A word is one the English list has (Lexicon/English.lua) or one from Azeroth
-- (Lexicon/Warcraft.lua). Those are worth a little more, and the names everybody knows more
-- again. Both lists are the same for every player whatever language they play in, and they are
-- part of the rules: `version` goes up whenever one of them changes.
--
-- The game ends when somebody lays their last tile with the bag empty, and gets what the others
-- are left holding added to their score while they lose it. It also ends when everyone has gone
-- two turns in a row without laying anything, and then everyone loses what they hold.
--
-- Nobody sees the bag or anybody else's tiles: `visible` leaves the local player with how many
-- there are, and nothing the game says about a move names a tile that was drawn.
--
-- Squares are numbered row by row from the top left, starting at 0, and written the way players
-- say them: a letter for the column and a number for the row, "H8" for the middle. A tile is its
-- letter, and "_" for a blank. A move is one of
--   aD8.QUeST   lay tiles across (a) or down (d) from a square. A capital is a tile with that
--               letter on it, a small letter a blank standing for it, and "_" a square the word
--               runs through that had a tile on it already
--   x.AEI_      swap these tiles
--   p           pass

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Lexicon = private.Lexicon

local SIZE = 15
local CENTRE = 7 * SIZE + 7
local RACK = 7
local BLANK = "_"
-- Every kind of tile, in the order the bag is filled in before it is shuffled
local KINDS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ" .. BLANK
-- A tile the local player doesn't get to see the face of
local HIDDEN = "?"
local PASS = "p"
-- For laying every tile held at once
local ALL_TILES_BONUS = 50
-- For a word from Azeroth, by the rank its list gives it: any of them, and the legendary ones
local LORE_BONUS = { 5, 15 }

-- How many tiles there are of each letter and what one is worth. Azeroth is fond of K and Z
local TILES = {
  A = { 9, 1 },
  B = { 2, 3 },
  C = { 2, 3 },
  D = { 4, 2 },
  E = { 12, 1 },
  F = { 2, 4 },
  G = { 3, 2 },
  H = { 3, 3 },
  I = { 8, 1 },
  J = { 1, 8 },
  K = { 2, 4 },
  L = { 4, 1 },
  M = { 3, 3 },
  N = { 6, 1 },
  O = { 8, 1 },
  P = { 2, 3 },
  Q = { 1, 10 },
  R = { 7, 1 },
  S = { 4, 1 },
  T = { 6, 1 },
  U = { 4, 1 },
  V = { 2, 4 },
  W = { 2, 4 },
  X = { 1, 8 },
  Y = { 2, 4 },
  Z = { 2, 8 },
  [BLANK] = { 2, 0 },
}

-- The top left quarter of the board, the middle row and column included: the rest mirrors it.
-- d and t double and triple the tile on them, D and T the word, and the middle square (*) counts
-- as D
local QUARTER = {
  "...T..d.",
  "..d..D..",
  ".d..t..d",
  "T..D..t.",
  "..t.D...",
  ".D...t.d",
  "d..t..d.",
  "..d..d.*",
}
--- @type table<string, { letter: number?, word: number? }>
local PREMIUMS = { d = { letter = 2 }, t = { letter = 3 }, D = { word = 2 }, T = { word = 3 }, ["*"] = { word = 2 } }

--- @class WordsState
--- @field seats number How many are playing
--- @field board table<number, string> The tile on each square that has one: a capital letter, or a small one for a blank standing for it
--- @field bag string[] The next tile to be drawn is the last
--- @field racks string[][] Tiles held, by seat
--- @field scores number[] By seat
--- @field turn number
--- @field idle number Turns in a row on which nothing was laid
--- @field out table<number, boolean> Seats that resigned
--- @field outcome { winner: number, detail: string? }?

--- A word a move made
--- @class WordsWord
--- @field text string In capitals
--- @field square number Where it starts
--- @field across boolean
--- @field length number
--- @field score number What it came to, its bonus included
--- @field lore LexiconEntry? What it is, for a word from Azeroth

--- @class WordsEvent: MatchEvent
--- @field placed table<number, string>? The tiles that were laid, by square
--- @field words WordsWord[]? The words that made, the one along the line of the tiles first if there is one
--- @field score number? What the move came to
--- @field allTiles boolean? Every tile held was laid, for the bonus
--- @field drew number? How many tiles were drawn. Which ones is nobody else's business
--- @field swapped number? How many tiles were swapped instead
--- @field passed boolean?
--- @field settled table<number, number>? The game is over: what each seat's last tiles did to their score

-----------------------------
-- Rules
-----------------------------

--- @param square number
--- @return string? The kind of square it is, a key of PREMIUMS, nil for a plain one
local function premiumAt(square)
  local column, row = square % SIZE, math.floor(square / SIZE)
  -- As far in from the nearest edge as the quarter has it
  column, row = math.min(column, SIZE - 1 - column), math.min(row, SIZE - 1 - row)
  local kind = QUARTER[row + 1]:sub(column + 1, column + 1)
  return PREMIUMS[kind] and kind or nil
end

--- @param tile string As it is held or as it lies on the board
--- @return number What it is worth
local function worth(tile)
  local known = TILES[tile]
  return known and known[2] or 0
end

--- @param square number
--- @return string "H8"
local function nameOf(square)
  return string.char(65 + square % SIZE) .. (math.floor(square / SIZE) + 1)
end

--- @param text string
--- @return boolean
local function isWord(text)
  return Lexicon.Has("english", text) or Lexicon.Has("warcraft", text)
end

--- Hands the turn to the next player who is still in the game
--- @param state WordsState
local function pass(state)
  repeat
    state.turn = state.turn % state.seats + 1
  until not state.out[state.turn]
end

--- Fills a player's rack from the bag
--- @param state WordsState
--- @param seat number
--- @return number How many tiles that took
local function draw(state, seat)
  local rack, drawn = state.racks[seat], 0
  while #rack < RACK and #state.bag > 0 do
    rack[#rack + 1] = table.remove(state.bag)
    drawn = drawn + 1
  end
  return drawn
end

--- @param seats number
--- @param random Random
--- @return WordsState
local function newState(seats, random)
  local bag = {}
  for tile in KINDS:gmatch(".") do
    for _ = 1, TILES[tile][1] do
      bag[#bag + 1] = tile
    end
  end
  random:Shuffle(bag)

  --- @type WordsState
  local state = { seats = seats, board = {}, bag = bag, racks = {}, scores = {}, turn = 1, idle = 0, out = {} }
  for seat = 1, seats do
    state.racks[seat], state.scores[seat] = {}, 0
    draw(state, seat)
  end
  return state
end

--- Takes tiles out of a rack
--- @param rack string[]
--- @param tiles string[]
--- @return string[]? What is left of it, nil if it didn't hold them all
local function without(rack, tiles)
  local left = { unpack(rack) }
  for _, tile in ipairs(tiles) do
    local found
    for index, held in ipairs(left) do
      if held == tile then
        found = index
        break
      end
    end
    if not found then
      return nil
    end
    table.remove(left, found)
  end
  return left
end

--- Reads a move that lays tiles
--- @param state WordsState
--- @param move string
--- @return table<number, string>? placed The tiles as they would lie on the board, by square
--- @return boolean|string across Which way they run, or the error code
--- @return string[]? used The tiles that takes out of the rack, in the order they are laid
local function layOut(state, move)
  local way, file, rank, tiles = move:match("^([ad])([A-O])([1-9]%d?)%.([%a_]+)$")
  if not way or tiles:sub(1, 1) == BLANK or tiles:sub(-1) == BLANK then
    return nil, "invalid_move"
  end
  local across = way == "a"
  local column, row = file:byte() - 65, tonumber(rank) - 1
  local last = (across and column or row) + #tiles - 1
  if row >= SIZE or last >= SIZE then
    return nil, "invalid_move"
  end

  local placed, used = {}, {}
  for index = 1, #tiles do
    local square = (row + (across and 0 or index - 1)) * SIZE + column + (across and index - 1 or 0)
    local tile = tiles:sub(index, index)
    -- A square is run through exactly when something lies on it
    if (tile == BLANK) ~= (state.board[square] ~= nil) then
      return nil, "invalid_move"
    end
    if tile ~= BLANK then
      placed[square] = tile
      used[#used + 1] = tile:match("%l") and BLANK or tile
    end
  end
  return placed, across, used
end

--- The word that runs through a square one way, once the tiles of a move lie on the board
--- @param state WordsState
--- @param placed table<number, string>
--- @param square number
--- @param across boolean
--- @return WordsWord
local function wordThrough(state, placed, square, across)
  local step = across and 1 or SIZE
  --- @param from number
  --- @param by number
  --- @return number? The next square that way if it is on the board and has a tile
  local function beyond(from, by)
    local to = from + by
    local onBoard = to >= 0 and to < SIZE * SIZE and (not across or math.floor(to / SIZE) == math.floor(from / SIZE))
    return onBoard and (state.board[to] or placed[to]) and to or nil
  end

  local first = square
  while beyond(first, -step) do
    first = beyond(first, -step)
  end

  local letters, sum, times, at = {}, 0, 1, first
  while at do
    local tile = state.board[at] or placed[at]
    local points = worth(tile)
    -- A square only counts for the move that first covers it
    local premium = placed[at] and PREMIUMS[premiumAt(at)]
    if premium then
      points = points * (premium.letter or 1)
      times = times * (premium.word or 1)
    end
    letters[#letters + 1] = tile:upper()
    sum = sum + points
    at = beyond(at, step)
  end
  return { text = table.concat(letters), square = first, across = across, length = #letters, score = sum * times }
end

--- What laying tiles would make
--- @param state WordsState
--- @param placed table<number, string>
--- @param across boolean
--- @return WordsWord[]? words Every word it makes, nil if it can't be done
--- @return number|string score What it all comes to, or the error code
--- @return WordsWord? wrong The word that isn't one
local function measure(state, placed, across)
  local squares = {}
  for square in pairs(placed) do
    squares[#squares + 1] = square
  end
  table.sort(squares)

  local words = {}
  local main = wordThrough(state, placed, squares[1], across)
  if main.length > 1 then
    words[1] = main
  end
  -- Tiles in one line can only have older ones beside them the other way
  local joined = main.length > #squares
  for _, square in ipairs(squares) do
    local cross = wordThrough(state, placed, square, not across)
    if cross.length > 1 then
      words[#words + 1] = cross
      joined = true
    end
  end

  if next(state.board) == nil then
    if not placed[CENTRE] then
      return nil, "words_off_centre"
    end
  elseif not joined then
    return nil, "words_not_joined"
  end
  if #words == 0 then
    return nil, "words_too_short"
  end

  local score = #squares == RACK and ALL_TILES_BONUS or 0
  for _, word in ipairs(words) do
    if not isWord(word.text) then
      return nil, "words_not_a_word", word
    end
    word.lore = Lexicon.Entry("warcraft", word.text)
    if word.lore then
      word.score = word.score + (LORE_BONUS[word.lore.rank] or LORE_BONUS[1])
    end
    score = score + word.score
  end
  return words, score
end

--- @param state WordsState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  if seat ~= state.turn then
    return false, "not_your_turn"
  end
  if move == PASS then
    return true
  end

  local swapped = move:match("^x%.([A-Z_]+)$")
  if swapped then
    if #state.bag < RACK then
      return false, "words_cant_swap"
    end
    local tiles = {}
    for tile in swapped:gmatch(".") do
      tiles[#tiles + 1] = tile
    end
    if not without(state.racks[seat], tiles) then
      return false, "words_not_held"
    end
    return true
  end

  local placed, across, used = layOut(state, move)
  if not placed then
    return false, across
  end
  if not without(state.racks[seat], used) then
    return false, "words_not_held"
  end
  local words, err = measure(state, placed, across)
  if not words then
    return false, err
  end
  return true
end

--- Ends the game: everyone loses what they are left holding, and whoever went out gets it
--- @param state WordsState
--- @param finisher number? The seat that laid its last tile
--- @return table<number, number> What that did to each seat's score
local function settle(state, finisher)
  local settled, gained = {}, 0
  for seat = 1, state.seats do
    if not state.out[seat] and seat ~= finisher then
      local held = 0
      for _, tile in ipairs(state.racks[seat]) do
        held = held + worth(tile)
      end
      settled[seat] = -held
      state.scores[seat] = state.scores[seat] - held
      gained = gained + held
    end
  end
  if finisher then
    settled[finisher] = gained
    state.scores[finisher] = state.scores[finisher] + gained
  end

  local winner, best
  for seat = 1, state.seats do
    if not state.out[seat] then
      if best == nil or state.scores[seat] > best then
        winner, best = seat, state.scores[seat]
      elseif state.scores[seat] == best then
        winner = 0
      end
    end
  end
  state.outcome = { winner = winner, detail = finisher and "words_out" or "words_passes" }
  return settled
end

--- A turn on which nothing was laid: the game is over once everyone has had two of them in a row
--- @param state WordsState
--- @return table<number, number>? What the end of the game did to each seat's score, if this ended it
local function idle(state)
  state.idle = state.idle + 1
  local left = 0
  for seat = 1, state.seats do
    left = left + (state.out[seat] and 0 or 1)
  end
  if state.idle >= 2 * left then
    return settle(state)
  end
  pass(state)
  return nil
end

--- @param state WordsState
--- @param seat number
--- @param move string
--- @param random Random
--- @return WordsEvent
local function apply(state, seat, move, random)
  if move == PASS then
    return { passed = true, settled = idle(state), notation = L["words_passed"] }
  end

  local rack = state.racks[seat]
  local swapped = move:match("^x%.(.+)$")
  if swapped then
    local tiles = {}
    for tile in swapped:gmatch(".") do
      tiles[#tiles + 1] = tile
    end
    state.racks[seat] = without(rack, tiles)
    -- New tiles first, so that none of those given back can be drawn again
    draw(state, seat)
    for _, tile in ipairs(tiles) do
      state.bag[#state.bag + 1] = tile
    end
    random:Shuffle(state.bag)
    return { swapped = #tiles, drew = #tiles, settled = idle(state), notation = L["words_swapped"]:format(#tiles) }
  end

  local placed, across, used = layOut(state, move)
  local words, score = measure(state, placed, across)
  for square, tile in pairs(placed) do
    state.board[square] = tile
  end
  state.racks[seat] = without(rack, used)
  state.scores[seat] = state.scores[seat] + score
  state.idle = 0

  --- @type WordsEvent
  local event = { placed = placed, words = words, score = score, allTiles = #used == RACK }
  event.notation = ("%s %s +%d"):format(nameOf(words[1].square), words[1].text, score)
  event.drew = draw(state, seat)
  if #state.racks[seat] == 0 then
    event.settled = settle(state, seat)
  else
    pass(state)
  end
  return event
end

--- A player resigned: their tiles go back under the bag
--- @param state WordsState
--- @param seat number
local function drop(state, seat)
  state.out[seat] = true
  for _, tile in ipairs(state.racks[seat]) do
    table.insert(state.bag, 1, tile)
  end
  state.racks[seat] = {}
  if state.turn == seat then
    pass(state)
  end
end

--- @param count number
--- @return string[] That many tiles seen from the back
local function backs(count)
  local tiles = {}
  for index = 1, count do
    tiles[index] = HIDDEN
  end
  return tiles
end

--- What a player may see: the board, the scores and their own tiles. Of the bag and the other
--- racks, only how many tiles there are
--- @param state WordsState
--- @param seat number
--- @return WordsState
local function visible(state, seat)
  local seen = {}
  for key, value in pairs(state) do
    seen[key] = value
  end
  seen.bag, seen.racks = backs(#state.bag), {}
  for other, rack in ipairs(state.racks) do
    seen.racks[other] = other == seat and { unpack(rack) } or backs(#rack)
  end
  return seen
end

-----------------------------
-- View
-----------------------------
-- The board in a window that zooms (GUI/Viewport.lua), the player's tiles in a rack under it
-- and, down the side, everyone's score, what the tiles laid out so far would come to, and the
-- buttons.
--
-- Tiles are laid out before they are played. A tile is dragged from the rack to a square, or
-- from square to square, or back (GUI/Drag.lua): a click picks one up and another puts it down
-- as well. Or the player clicks a square, which leaves an arrow there, and types: the tiles go
-- down from the arrow on, the way it points, and clicking the square again turns it. Nothing is
-- sent until Play is pressed, and all the while the side says what the move would make. Tiles
-- can be laid out while it is somebody else's turn too.
--
-- Squares are coloured the way loot is, from the tile doubled (green) to the word tripled
-- (orange). Words from Azeroth are gold wherever they lie, the names everybody knows orange,
-- and pointing at one says what it is.

local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\"
-- The rules above are also loaded where there is nothing to draw with: these are looked up when
-- the first view is built
local Tiles, Widgets
local GAP = 8
-- The side panel's share of the width, and the rack's of the height
local PANEL_SHARE, PANEL_MIN, PANEL_MAX = 0.27, 128, 190
local RACK_SHARE, RACK_MIN, RACK_MAX = 0.12, 34, 60
local RACK_GAP = 3
-- How big a square should be to lay tiles on: a board drawn smaller is zoomed in on to that
local COMFORTABLE = 36
local MAX_ZOOM = 3
local PLATE_HEIGHT, BUTTON_HEIGHT = 38, 22
-- How fast a tile in the rack closes in on where it belongs, as a share of the way a second
local RACK_SPEED = 16

local BOARD_BACK = { 0.05, 0.05, 0.07 }
-- Squares by what they do: plain, and the four that count for more
local SQUARE_COLORS = {
  plain = { 0.19, 0.21, 0.27 },
  d = { 0.15, 0.46, 0.2 },
  t = { 0.12, 0.33, 0.62 },
  D = { 0.45, 0.2, 0.6 },
  T = { 0.78, 0.4, 0.08 },
  ["*"] = { 0.45, 0.2, 0.6 },
}
local SQUARE_LABEL = { 1, 1, 1, 0.75 }
local GOLD, LEGEND = { 1, 0.82, 0.1 }, { 1, 0.5, 0 }
-- The light around tiles, by what it says: colour and how strong
local GLOWS = {
  wrong = { 1, 0.15, 0.1, 0.9 },
  fine = { 0.5, 1, 0.55, 0.7 },
  laying = { 1, 1, 1, 0.45 },
  gold = { GOLD[1], GOLD[2], GOLD[3], 0.95 },
  legend = { LEGEND[1], LEGEND[2], LEGEND[3], 1 },
  -- The same two for words that lie on the board already, where they shouldn't shout
  lore = { GOLD[1], GOLD[2], GOLD[3], 0.5 },
  known = { LEGEND[1], LEGEND[2], LEGEND[3], 0.65 },
  last = { 0.55, 0.8, 1, 0.5 },
}
local LAID_TINT = { 1, 0.96, 0.8 }
local PICKED_TINT = { 0.65, 0.85, 1 }
local HOVER = { 1, 1, 1, 0.22 }
local CURSOR = { 1, 0.82, 0.1, 0.4 }
local PLATE, PLATE_TURN = { 0, 0, 0, 0.35 }, { 0.35, 0.28, 0.05, 0.6 }
local RED, WHITE = "|cffff4d40", "|cffffffff"
local GOLD_TEXT, LEGEND_TEXT, GREY_TEXT = "|cffffd11a", "|cffff8000", "|cff909090"
local SOUNDS = { tile = "chipsCollide", draw = "cardSlide", shuffle = "dieShuffle", lore = "UI_EPICLOOT_TOAST", legend = "UI_LEGENDARY_LOOT_TOAST" }
-- Seconds between one tile of a move going down and the next, how long one takes to settle, and
-- between one word being counted and the next
local TILE_APART, TILE_POP, WORD_APART = 0.09, 0.26, 0.5
local FLIGHT = 0.3
local COUNT_UP = 0.7
local FLOAT, FLOAT_RISE = 1.5, 34

--- A tile the player holds, and where they have put it for now
--- @class WordsEntry
--- @field tile string
--- @field square number? Laid on the board there, not played yet
--- @field as string? The letter a blank laid on the board stands for, small
--- @field fresh boolean? Just drawn, and not seen arriving yet

--- What a player is doing in a match that hasn't been sent
--- @class WordsDraft
--- @field entries WordsEntry[] The tiles held, in the order the player keeps them
--- @field ply number? The position they were last matched against
--- @field cursor { square: number?, across: boolean }? Where typing puts the next tile, no square once it has run off the board
--- @field typed WordsEntry[] The tiles that were typed, in order
--- @field swap table<WordsEntry, boolean>? The tiles picked to be swapped, while the player is picking
--- @field passing boolean? Pass was pressed once
--- @field picking WordsEntry? The blank a letter is being chosen for

--- @type table<string, WordsDraft> By match id
local drafts = {}

--- What the tiles laid out would make
--- @class WordsPreview
--- @field move string? The move that plays them, if it is one
--- @field words WordsWord[]?
--- @field score number?
--- @field err string? Why it isn't a move
--- @field wrong WordsWord? The word that isn't one
--- @field pending boolean? A blank has no letter yet

--- @param word WordsWord
--- @return number[] The squares it lies on
local function squaresOf(word)
  local squares = {}
  for index = 0, word.length - 1 do
    squares[#squares + 1] = word.square + index * (word.across and 1 or SIZE)
  end
  return squares
end

--- Works out the move that would play the tiles laid out
--- @param state WordsState
--- @param laid WordsEntry[]
--- @return WordsPreview
local function compose(state, laid)
  if #laid == 0 then
    return {}
  end
  table.sort(laid, function(a, b)
    return a.square < b.square
  end)
  local bySquare = {}
  for _, entry in ipairs(laid) do
    if entry.tile == BLANK and not entry.as then
      return { pending = true }
    end
    bySquare[entry.square] = entry
  end

  local first, last = laid[1].square, laid[#laid].square
  local across
  if #laid == 1 then
    -- One tile makes its word whichever way it has a neighbour
    local column = first % SIZE
    local beside = (column > 0 and state.board[first - 1]) or (column < SIZE - 1 and state.board[first + 1])
    local above = state.board[first - SIZE] or state.board[first + SIZE]
    across = (beside and true or false) or not above
  elseif math.floor(first / SIZE) == math.floor(last / SIZE) then
    across = true
  elseif first % SIZE == last % SIZE then
    across = false
  else
    return { err = "words_one_line" }
  end

  local tiles = {}
  for square = first, last, across and 1 or SIZE do
    local entry = bySquare[square]
    if entry then
      tiles[#tiles + 1] = entry.as or entry.tile
    elseif state.board[square] then
      tiles[#tiles + 1] = BLANK
    else
      return { err = "words_gap" }
    end
  end
  local move = (across and "a" or "d") .. nameOf(first) .. "." .. table.concat(tiles)
  local placed, way = layOut(state, move)
  if not placed then
    return { err = way }
  end
  local words, score, wrong = measure(state, placed, way)
  if not words then
    return { err = score, wrong = wrong }
  end
  return { move = move, words = words, score = score }
end

--- Every word from Azeroth that lies on a board, by the squares it lies on
--- @param state WordsState
--- @return table<number, number> The rank of the best known word through each square
local function loreOn(state)
  local found = {}
  for _, across in ipairs({ true, false }) do
    for square = 0, SIZE * SIZE - 1 do
      local before = square - (across and 1 or SIZE)
      local starts = state.board[square] and not (state.board[before] and (not across or square % SIZE > 0))
      if starts then
        local word = wordThrough(state, {}, square, across)
        local lore = word.length > 1 and Lexicon.Entry("warcraft", word.text)
        if lore then
          for _, on in ipairs(squaresOf(word)) do
            found[on] = math.max(found[on] or 0, lore.rank)
          end
        end
      end
    end
  end
  return found
end

--- Where the middle of a region is, measured from the bottom left corner of a frame that may be
--- drawn at another scale
--- @param region Region
--- @param frame Frame
--- @return number? x, number? y
local function centreIn(region, frame)
  local x, y = region:GetCenter()
  local left, bottom = frame:GetLeft(), frame:GetBottom()
  if not x or not left or not bottom then
    return nil
  end
  local scale = region:GetEffectiveScale() / frame:GetEffectiveScale()
  return x * scale - left, y * scale - bottom
end

--- @class WordsView: GameViewObject
--- @field stage Frame
--- @field viewport Viewport
--- @field board Frame What is zoomed: the squares and everything on them
--- @field cell number Side of a square, before zooming
--- @field squares { cell: Texture, label: FontString?, star: Texture? }[] By square
--- @field glows table<number, Texture> The light around the tile on a square, made when first needed
--- @field tiles table<number, Tile> The tile on a square, made when first needed
--- @field rack Frame
--- @field held table<WordsEntry, Tile> The tiles in the rack, by what they show
--- @field spare Tile[] Tiles the rack has no use for right now
--- @field panel Frame
--- @field plates Frame[] By seat
--- @field drag Drag
--- @field puppet Tile What is carried looks like
--- @field carried WordsEntry?
--- @field animator table
--- @field view GameView? What was last asked for
--- @field preview WordsPreview
local View = {}
View.__index = View

-----------------------------
-- Building
-----------------------------

--- @param stage Frame
--- @return WordsView
local function createView(stage)
  --- @type WordsView
  local self = setmetatable({ stage = stage, cell = 0, squares = {}, glows = {}, tiles = {}, held = {}, spare = {} }, View)
  Tiles, Widgets = private.Tiles, private.Widgets
  self.preview, self.counting = {}, {}

  self.viewport = private.Viewport.New(stage, {
    maxZoom = MAX_ZOOM,
    onSettle = function()
      for _, tile in pairs(self.tiles) do
        tile:Sharpen()
      end
    end,
  })
  self.viewport.frame.wordsWindow = true
  local back = self.viewport.frame:CreateTexture(nil, "BACKGROUND")
  back:SetAllPoints()
  back:SetColorTexture(unpack(BOARD_BACK))

  local board = self.viewport.content
  board.wordsBoard = true
  board:EnableMouse(true)
  self.board = board
  for square = 0, SIZE * SIZE - 1 do
    local kind = premiumAt(square)
    local parts = { cell = board:CreateTexture(nil, "BACKGROUND") }
    parts.cell:SetTexture(Tiles.CELL)
    parts.cell:SetVertexColor(unpack(SQUARE_COLORS[kind or "plain"]))
    if kind == "*" then
      parts.star = board:CreateTexture(nil, "BORDER")
      parts.star:SetTexture(Tiles.STAR)
      parts.star:SetVertexColor(1, 0.9, 0.6, 0.85)
    elseif kind then
      parts.label = board:CreateFontString(nil, "BORDER")
      parts.label:SetTextColor(unpack(SQUARE_LABEL))
    end
    self.squares[square] = parts
  end
  -- Light, tiles and what points at squares each on a layer of their own, so that the light
  -- around one tile never lies over the tile next to it
  self.glowLayer = CreateFrame("Frame", nil, board)
  self.glowLayer:SetAllPoints()
  self.tileLayer = CreateFrame("Frame", nil, board)
  self.tileLayer:SetAllPoints()
  self.tileLayer:SetFrameLevel(self.glowLayer:GetFrameLevel() + 1)
  self.markLayer = CreateFrame("Frame", nil, board)
  self.markLayer:SetAllPoints()
  self.markLayer:SetFrameLevel(self.glowLayer:GetFrameLevel() + 2)
  self.hoverMark = self.markLayer:CreateTexture(nil, "ARTWORK")
  self.hoverMark:SetColorTexture(unpack(HOVER))
  self.hoverMark:Hide()
  self.cursorMark = self.markLayer:CreateTexture(nil, "ARTWORK")
  self.cursorMark:SetColorTexture(unpack(CURSOR))
  self.cursorMark:Hide()
  self.cursorArrow = self.markLayer:CreateTexture(nil, "OVERLAY")
  self.cursorArrow:SetTexture(Tiles.ARROW)
  self.cursorArrow:SetVertexColor(unpack(GOLD))
  self.cursorArrow:Hide()
  self.cursorPulse = Widgets.Pulse(self.cursorArrow)

  board:SetScript("OnMouseDown", function(_, button)
    self:boardDown(button)
  end)
  board:SetScript("OnMouseUp", function(_, button)
    self:boardUp(button)
  end)
  board:SetScript("OnUpdate", function(_, elapsed)
    self:watch(elapsed)
  end)
  board:SetScript("OnHide", function()
    -- The keyboard isn't ours to keep once there is nothing to type on
    self:point(nil)
    self.tipSquare = nil
    GameTooltip_Hide()
  end)

  self.rack = CreateFrame("Frame", nil, stage)
  self.rack.wordsRack = true
  local shelf = self.rack:CreateTexture(nil, "BACKGROUND")
  shelf:SetAllPoints()
  shelf:SetColorTexture(0, 0, 0, 0.3)
  self.rack:SetScript("OnUpdate", function(_, elapsed)
    self:slideRack(elapsed)
  end)

  self:buildPanel()

  -- What flies and floats over it all
  self.effects = CreateFrame("Frame", nil, stage)
  self.effects.wordsEffects = true
  self.effects:SetAllPoints()
  self.effects:SetFrameLevel(stage:GetFrameLevel() + 30)
  self.animator = Widgets.Animator(self.effects)
  self.floats, self.flights = {}, {}
  self.banner = self.effects:CreateFontString(nil, "OVERLAY")
  self.banner:SetTextColor(unpack(GOLD))
  self.banner:Hide()

  self.drag = private.Drag.New(stage)
  self.puppet = Tiles.New(self.drag.frame)
  self.puppet:Hide()
  self.drag:AddTarget({
    region = board,
    clip = self.viewport.frame,
    spot = function()
      local square = self:squareAt()
      return square and self:free(square) and square or nil
    end,
    onHover = function(_, square)
      self.hoverSquare = square
      self:showMarks()
    end,
    onDrop = function(entry, square)
      self.carried = nil
      self:lay(entry, square)
    end,
  })
  self.drag:AddTarget({
    region = self.rack,
    spot = function()
      return self:rackSpot()
    end,
    onHover = function(_, index)
      self.gap = index
    end,
    onDrop = function(entry, index)
      self.carried, self.gap = nil, nil
      self:keep(entry, index)
    end,
  })

  self:buildPicker()
  self:buildTyping()
  return self
end

function View:buildPanel()
  local panel = CreateFrame("Frame", nil, self.stage)
  self.panel = panel
  self.plates = {}
  for seat = 1, 4 do
    local plate = CreateFrame("Frame", nil, panel)
    plate:SetHeight(PLATE_HEIGHT)
    plate.wordsPlate = seat
    plate.back = plate:CreateTexture(nil, "BACKGROUND")
    plate.back:SetAllPoints()
    plate.mark = plate:CreateTexture(nil, "BORDER")
    plate.mark:SetColorTexture(unpack(GOLD))
    plate.mark:SetPoint("TOPLEFT")
    plate.mark:SetPoint("BOTTOMLEFT")
    plate.mark:SetWidth(3)
    plate.name = Widgets.Label(plate, "GameFontHighlightSmall")
    plate.name:SetPoint("TOPLEFT", 8, -5)
    plate.name:SetWordWrap(false)
    plate.held = Widgets.Label(plate, "GameFontDisableSmall")
    plate.held:SetPoint("BOTTOMLEFT", 8, 5)
    plate.score = Widgets.Label(plate, "GameFontNormalLarge")
    plate.score:SetPoint("RIGHT", -8, 0)
    plate.score:SetJustifyH("RIGHT")
    self.plates[seat] = plate
  end

  self.bag = Widgets.Label(panel, "GameFontHighlightSmall")
  self.bagIcon = Tiles.New(panel)
  self.bagIcon:Fit(16)
  self.bagIcon:Set(nil)
  self.bag:SetPoint("LEFT", self.bagIcon, "RIGHT", 6, 0)
  self.note = Widgets.Label(panel, "GameFontHighlightSmall")
  self.note.wordsNote = true
  self.note:SetJustifyV("TOP")
  self.note:SetSpacing(3)

  local buttons = {}
  for _, name in ipairs({ "play", "recall", "shuffle", "swap", "pass" }) do
    buttons[name] = Widgets.Button(panel, L["words_" .. name], 60, BUTTON_HEIGHT)
  end
  buttons.play:SetHeight(BUTTON_HEIGHT + 6)
  buttons.pass:SetPoint("BOTTOMRIGHT")
  buttons.swap:SetPoint("BOTTOMLEFT")
  buttons.shuffle:SetPoint("BOTTOMRIGHT", buttons.pass, "TOPRIGHT", 0, 3)
  buttons.recall:SetPoint("BOTTOMLEFT", buttons.swap, "TOPLEFT", 0, 3)
  buttons.play:SetPoint("BOTTOMLEFT", buttons.recall, "TOPLEFT", 0, 4)
  buttons.play:SetPoint("BOTTOMRIGHT", buttons.shuffle, "TOPRIGHT", 0, 4)
  buttons.play:SetScript("OnClick", function()
    self:play()
  end)
  buttons.recall:SetScript("OnClick", function()
    self:recall()
  end)
  buttons.shuffle:SetScript("OnClick", function()
    self:shuffle()
  end)
  buttons.swap:SetScript("OnClick", function()
    self:startSwap()
  end)
  buttons.pass:SetScript("OnClick", function()
    self:pass()
  end)
  self.buttons = buttons
end

--- The letters a blank can stand for, to pick one from
function View:buildPicker()
  local picker = Widgets.Panel(self.stage)
  picker:SetFrameLevel(self.stage:GetFrameLevel() + 60)
  picker:SetBackdropColor(0.05, 0.05, 0.08, 0.95)
  picker:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 0.6)
  picker:EnableMouse(true)
  picker:Hide()
  picker.title = Widgets.Label(picker, "GameFontNormal", L["words_pick_letter"])
  picker.title:SetPoint("TOP", 0, -8)
  picker.letters = {}
  for index = 1, 26 do
    local letter = string.char(64 + index)
    local button = CreateFrame("Button", nil, picker)
    button.wordsLetter = letter
    button.tile = Tiles.New(button)
    button.tile:SetPoint("CENTER")
    button.tile:Set(letter, nil, true)
    button:SetScript("OnClick", function()
      self:pick(letter)
    end)
    picker.letters[index] = button
  end
  picker:SetScript("OnMouseDown", function(_, button)
    if button ~= "LeftButton" then
      self:pick(nil)
    end
  end)
  self.picker = picker
end

--- Typing goes through a box nobody sees: it has the keyboard for as long as there is an arrow
--- on the board, and gives it back the way every other box does
function View:buildTyping()
  local box = CreateFrame("EditBox", nil, self.stage)
  box:SetSize(1, 1)
  box:SetPoint("TOPLEFT")
  box:SetAlpha(0)
  box:SetAutoFocus(false)
  box:SetFontObject("ChatFontNormal")
  -- One character it always holds, so that taking it away is something to notice
  box:SetText(" ")
  box:SetScript("OnChar", function(_, character)
    self:type(character)
  end)
  box:SetScript("OnTextChanged", function(_, byPlayer)
    if byPlayer and box:GetText() == "" then
      self:untype()
    end
    if box:GetText() ~= " " then
      box:SetText(" ")
    end
  end)
  box:SetScript("OnEnterPressed", function()
    self:play()
  end)
  box:SetScript("OnEscapePressed", function()
    self:point(nil)
  end)
  box:SetScript("OnEditFocusLost", function()
    local draft = self.view and drafts[self.view.match.id]
    if draft and draft.cursor then
      draft.cursor = nil
      self:showMarks()
    end
  end)
  self.typing = box
end

-----------------------------
-- Layout
-----------------------------

--- @param width number
--- @param height number
function View:Layout(width, height)
  local panelWidth = math.max(PANEL_MIN, math.min(PANEL_MAX, math.floor(width * PANEL_SHARE)))
  local rackHeight = math.max(RACK_MIN, math.min(RACK_MAX, math.floor(height * RACK_SHARE)))
  local cell = math.max(8, math.floor(math.min(height - rackHeight - GAP, width - panelWidth - GAP) / SIZE))
  local side = cell * SIZE
  local left = math.floor((width - side - GAP - panelWidth) / 2)
  local top = math.floor((height - side - GAP - rackHeight) / 2)
  self.cell, self.side = cell, side

  local viewport = self.viewport
  viewport.frame:ClearAllPoints()
  viewport.frame:SetPoint("TOPLEFT", self.stage, "TOPLEFT", left, -top)
  viewport:SetSize(side, side)
  viewport:SetContentSize(side, side)
  viewport:Fit(true)

  local font = math.max(6, math.floor(cell * 0.3))
  for square = 0, SIZE * SIZE - 1 do
    local parts = self.squares[square]
    local x, y = self:offsetOf(square)
    parts.cell:ClearAllPoints()
    parts.cell:SetPoint("TOPLEFT", x, -y)
    parts.cell:SetSize(cell, cell)
    if parts.label then
      parts.label:SetFont(STANDARD_TEXT_FONT, font, "")
      parts.label:SetText(L["words_square_" .. premiumAt(square)])
      parts.label:ClearAllPoints()
      parts.label:SetPoint("CENTER", self.board, "TOPLEFT", x + cell / 2, -(y + cell / 2))
    end
    if parts.star then
      parts.star:ClearAllPoints()
      parts.star:SetPoint("CENTER", self.board, "TOPLEFT", x + cell / 2, -(y + cell / 2))
      parts.star:SetSize(cell * 0.7, cell * 0.7)
    end
    if self.tiles[square] then
      self:placeTile(square)
    end
    if self.glows[square] then
      self:placeGlow(square)
    end
  end
  self.hoverMark:SetSize(cell, cell)
  self.cursorMark:SetSize(cell, cell)
  self.cursorArrow:SetSize(cell * 0.8, cell * 0.8)

  self.rack:ClearAllPoints()
  self.rack:SetPoint("TOPLEFT", self.stage, "TOPLEFT", left, -(top + side + GAP))
  self.rack:SetSize(side, rackHeight)
  self.rackSide = math.min(rackHeight - 4, math.floor((side - (RACK + 1) * RACK_GAP) / (RACK + 0.5)))
  self.puppet:Fit(self.rackSide * 1.1)
  for _, tile in pairs(self.held) do
    tile:Fit(self.rackSide)
    tile.x = nil
  end

  local panel = self.panel
  panel:ClearAllPoints()
  panel:SetPoint("TOPLEFT", self.stage, "TOPLEFT", left + side + GAP, -top)
  panel:SetSize(panelWidth, side + GAP + rackHeight)
  for seat, plate in ipairs(self.plates) do
    plate:ClearAllPoints()
    plate:SetPoint("TOPLEFT", 0, -(seat - 1) * (PLATE_HEIGHT + 3))
    plate:SetWidth(panelWidth)
    plate.name:SetWidth(panelWidth - 56)
  end
  local half = math.floor((panelWidth - 4) / 2)
  for _, name in ipairs({ "recall", "shuffle", "swap", "pass" }) do
    self.buttons[name]:SetWidth(half)
  end
  self.note:SetWidth(panelWidth)

  local letter = math.max(20, math.min(30, math.floor(side / 12)))
  local picker = self.picker
  picker:SetSize(7 * (letter + 3) + 17, 4 * (letter + 3) + 40)
  picker:ClearAllPoints()
  picker:SetPoint("CENTER", viewport.frame, "CENTER")
  for index, button in ipairs(picker.letters) do
    button:SetSize(letter, letter)
    button.tile:Fit(letter)
    button:ClearAllPoints()
    button:SetPoint("TOPLEFT", 10 + ((index - 1) % 7) * (letter + 3), -30 - math.floor((index - 1) / 7) * (letter + 3))
  end
  self.banner:SetFont(STANDARD_TEXT_FONT, math.max(14, math.floor(side / 14)), "OUTLINE")

  if self.view then
    self:Update(self.view)
  end
end

--- Where a square is drawn: the distance of its top left corner from the board's, right and down
--- @param square number
--- @return number x, number y
function View:offsetOf(square)
  return square % SIZE * self.cell, math.floor(square / SIZE) * self.cell
end

--- @return number? The square the cursor is over
function View:squareAt()
  local board = self.board
  local scale = board:GetEffectiveScale()
  local x, y = GetCursorPosition()
  x, y = x / scale - (board:GetLeft() or 0), (board:GetTop() or 0) - y / scale
  if self.cell <= 0 or x < 0 or y < 0 then
    return nil
  end
  local column, row = math.floor(x / self.cell), math.floor(y / self.cell)
  if column >= SIZE or row >= SIZE then
    return nil
  end
  return row * SIZE + column
end

--- @param square number
--- @param scale number? For a tile that is drawn larger or smaller than its square for a moment
function View:placeTile(square, scale)
  local tile = self.tiles[square]
  local x, y = self:offsetOf(square)
  tile:Fit(self.cell * (scale or 1))
  tile:ClearAllPoints()
  tile:SetPoint("CENTER", self.board, "TOPLEFT", x + self.cell / 2, -(y + self.cell / 2))
end

--- @param square number
function View:placeGlow(square)
  local glow = self.glows[square]
  local x, y = self:offsetOf(square)
  glow:ClearAllPoints()
  glow:SetPoint("CENTER", self.board, "TOPLEFT", x + self.cell / 2, -(y + self.cell / 2))
  glow:SetSize(self.cell * Tiles.GLOW_SCALE, self.cell * Tiles.GLOW_SCALE)
end

-----------------------------
-- The draft
-----------------------------

--- Whether the player can lay tiles out right now: only in a game that is on, as it stands
--- @return boolean
function View:busy()
  local view = self.view
  return view ~= nil and view.live and view.match.status == "active" and not view.state.out[view.seat]
end

--- What the player is doing in the match on screen, brought in line with the tiles they hold
--- @return WordsDraft
function View:draft()
  local view = self.view
  --- @type WordsState
  local state = view.state
  local id = view.match.id
  local draft = drafts[id]
  local isNew = draft == nil
  if isNew then
    draft = { entries = {}, typed = {} }
    drafts[id] = draft
  end
  if draft.ply ~= view.ply then
    draft.ply, draft.cursor, draft.typed, draft.swap, draft.passing, draft.picking = view.ply, nil, {}, nil, false, nil
  end

  -- Keep the tiles that are still held where the player has them, and add the new ones
  local wanted = {}
  for _, tile in ipairs(state.racks[view.seat]) do
    wanted[tile] = (wanted[tile] or 0) + 1
  end
  local entries = {}
  for _, entry in ipairs(draft.entries) do
    -- A tile on a square that now has one was played, or somebody got there first: either way
    -- it isn't lying there any more, and if it is still held it comes back like one just drawn
    local gone = entry.square and state.board[entry.square]
    if not gone and (wanted[entry.tile] or 0) > 0 then
      wanted[entry.tile] = wanted[entry.tile] - 1
      entries[#entries + 1] = entry
    end
  end
  for _, tile in ipairs(state.racks[view.seat]) do
    if (wanted[tile] or 0) > 0 then
      wanted[tile] = wanted[tile] - 1
      entries[#entries + 1] = { tile = tile, fresh = not isNew }
    end
  end
  draft.entries = entries
  return draft
end

--- @param square number
--- @return WordsEntry? The tile the player has laid there
function View:laidAt(square)
  local draft = drafts[self.view.match.id]
  for _, entry in ipairs(draft and draft.entries or {}) do
    if entry.square == square and entry ~= self.carried then
      return entry
    end
  end
  return nil
end

--- @param square number
--- @return boolean Whether a tile could be laid there
function View:free(square)
  return self:busy() and not self.view.state.board[square] and not self:laidAt(square)
end

--- @return WordsEntry[] The tiles in the rack, in order
function View:inRack()
  local entries = {}
  if not self:busy() then
    -- Looking back, or after the end: the tiles as they were, nothing to arrange
    for index, tile in ipairs(self.view.state.racks[self.view.seat]) do
      self.fixed = self.fixed or {}
      self.fixed[index] = self.fixed[index] or {}
      self.fixed[index].tile = tile
      entries[index] = self.fixed[index]
    end
    return entries
  end
  for _, entry in ipairs(self:draft().entries) do
    if not entry.square and entry ~= self.carried then
      entries[#entries + 1] = entry
    end
  end
  return entries
end

--- Shows what was changed
function View:refresh()
  if self.view then
    self:Update(self.view)
  end
end

--- Brings a square close enough to lay tiles around, if the board is drawn too small for that
--- @param square number
function View:closeIn(square)
  local zoom = math.min(MAX_ZOOM, COMFORTABLE / self.cell)
  if zoom > 1.1 and self.viewport:Fits() then
    local x, y = self:offsetOf(square)
    self.viewport:ZoomTo(zoom, x + self.cell / 2, y + self.cell / 2)
  end
end

--- Lays a tile on a square
--- @param entry WordsEntry
--- @param square number
--- @param as string? The letter it stands for, if it is a blank and that is known
function View:lay(entry, square, as)
  local draft = self:draft()
  entry.square, entry.as, entry.fresh = square, nil, nil
  draft.passing = false
  if entry.tile == BLANK then
    entry.as = as
    draft.picking = not as and entry or nil
  end
  Widgets.PlaySound(SOUNDS.tile)
  self:closeIn(square)
  self:refresh()
end

--- Puts a tile back in the rack
--- @param entry WordsEntry
--- @param index number? Where among the tiles there, at the end if left out
function View:keep(entry, index)
  local draft = self:draft()
  -- The tile it goes in front of, counting the others only
  local before, others = nil, 0
  for _, other in ipairs(self:inRack()) do
    if other ~= entry then
      others = others + 1
      before = before or (others == index and other or nil)
    end
  end
  entry.square, entry.as = nil, nil
  if draft.picking == entry then
    draft.picking = nil
  end
  for at, other in ipairs(draft.entries) do
    if other == entry then
      table.remove(draft.entries, at)
      break
    end
  end
  local to = #draft.entries + 1
  for at, other in ipairs(draft.entries) do
    if other == before then
      to = at
    end
  end
  table.insert(draft.entries, to, entry)
  self:refresh()
end

--- Picks a tile up, from the rack or from where it was laid
--- @param entry WordsEntry
function View:carry(entry)
  local draft = self:draft()
  self:point(nil)
  draft.passing = false
  self.carried = entry
  self.puppet:Set(entry.tile ~= BLANK and entry.tile or (entry.as and entry.as:upper()), worth(entry.tile), entry.tile == BLANK)
  self.drag:Carry(entry, {
    puppet = self.puppet,
    onReturn = function()
      self.carried, self.gap, self.hoverSquare = nil, nil, nil
      self:refresh()
    end,
  })
  self:refresh()
end

--- Takes every tile off the board again, or stops picking tiles to swap
function View:recall()
  local draft = self:draft()
  for _, entry in ipairs(draft.entries) do
    entry.square, entry.as = nil, nil
  end
  draft.swap, draft.passing, draft.picking, draft.typed = nil, false, nil, {}
  self:point(nil)
  self.viewport:Fit()
  self:refresh()
end

--- Puts the tiles in the rack in another order
function View:shuffle()
  local draft = self:draft()
  local loose = {}
  for at, entry in ipairs(draft.entries) do
    if not entry.square then
      loose[#loose + 1] = at
    end
  end
  for index = #loose, 2, -1 do
    local other = math.random(index)
    local a, b = loose[index], loose[other]
    draft.entries[a], draft.entries[b] = draft.entries[b], draft.entries[a]
  end
  Widgets.PlaySound(SOUNDS.shuffle)
  self:refresh()
end

--- Starts picking tiles to swap
function View:startSwap()
  local draft = self:draft()
  self:recall()
  draft.swap = {}
  self:refresh()
end

function View:pass()
  local draft = self:draft()
  if not draft.passing then
    draft.passing = true
    self:refresh()
    return
  end
  self.view.submit(PASS)
end

--- Sends what was laid out, or the tiles picked to be swapped
function View:play()
  local view, draft = self.view, self:draft()
  if not view.canMove then
    return
  end
  if draft.swap then
    local tiles = {}
    for _, entry in ipairs(draft.entries) do
      if draft.swap[entry] then
        tiles[#tiles + 1] = entry.tile
      end
    end
    if #tiles > 0 then
      view.submit("x." .. table.concat(tiles))
    end
  elseif self.preview.move then
    view.submit(self.preview.move)
  end
end

--- A letter was chosen for the blank that is waiting for one, or with nil nothing was
--- @param letter string?
function View:pick(letter)
  local draft = self:draft()
  local entry = draft.picking
  if not entry then
    return
  end
  draft.picking = nil
  if letter then
    entry.as = letter:lower()
    self:refresh()
  else
    self:keep(entry)
  end
end

-----------------------------
-- Mouse and keyboard
-----------------------------

--- @param button string
function View:boardDown(button)
  local square = self:squareAt()
  local entry = square and self:busy() and self:laidAt(square)
  self.pressed = nil
  if entry and button == "LeftButton" then
    self:carry(entry)
  elseif entry then
    self:keep(entry)
  else
    -- Not on anything of the player's: the board itself is what is taken hold of
    self.viewport:Grab(button)
    self.pressed = button == "LeftButton" and square or nil
  end
end

--- @param button string
function View:boardUp(button)
  local square = self.pressed
  self.pressed = nil
  if button ~= "LeftButton" or not square or self.viewport.dragged or not self:busy() then
    return
  end
  local draft = self:draft()
  if draft.swap then
    return
  end
  -- A click on a square puts the arrow there, another turns it and a third takes it away
  local cursor = draft.cursor
  if not self:free(square) then
    self:point(nil)
  elseif cursor and cursor.square == square then
    self:point(cursor.across and square or nil, false)
  else
    self:point(square, true)
  end
end

--- Puts the arrow that typing goes from on a square, or takes it away
--- @param square number?
--- @param across boolean?
function View:point(square, across)
  local draft = self.view and drafts[self.view.match.id]
  if not draft then
    return
  end
  if square then
    draft.cursor, draft.typed = { square = square, across = across }, {}
    self.typing:SetFocus()
  elseif draft.cursor then
    draft.cursor = nil
    self.typing:ClearFocus()
  end
  self:showMarks()
end

--- @param character string What was typed
function View:type(character)
  local draft = self.view and self:busy() and self:draft()
  local cursor = draft and draft.cursor
  local letter = character:upper()
  if not cursor or not cursor.square or not letter:match("^[A-Z]$") then
    return
  end
  -- The tile with the letter on it, or a blank to stand for it
  local found
  for _, entry in ipairs(draft.entries) do
    if not entry.square and (entry.tile == letter or (entry.tile == BLANK and not found)) then
      found = entry
      if entry.tile == letter then
        break
      end
    end
  end
  if not found then
    Widgets.PlaySound("IG_BACKPACK_CLOSE")
    return
  end

  local square = cursor.square
  draft.typed[#draft.typed + 1] = found
  -- On to the next square that has nothing on it
  local step = cursor.across and 1 or SIZE
  local onward = square
  repeat
    local from = onward
    onward = onward + step
    if onward >= SIZE * SIZE or (cursor.across and math.floor(onward / SIZE) ~= math.floor(from / SIZE)) then
      onward = nil
    end
  until not onward or (not self.view.state.board[onward] and not self:laidAt(onward))
  cursor.square = onward
  self:lay(found, square, found.tile == BLANK and letter:lower() or nil)
end

--- Takes back the tile that was typed last
function View:untype()
  local draft = self.view and self:busy() and self:draft()
  local entry = draft and draft.cursor and table.remove(draft.typed)
  if not entry or not entry.square then
    return
  end
  draft.cursor.square = entry.square
  self:keep(entry)
end

--- @return number? Where among the tiles in the rack the one carried would go
function View:rackSpot()
  local rack = self.rack
  local scale = rack:GetEffectiveScale()
  local x = GetCursorPosition() / scale - (rack:GetLeft() or 0)
  local count = #self:inRack()
  local pitch = self.rackSide + RACK_GAP
  local start = (rack:GetWidth() - (count + 1) * pitch) / 2
  return math.max(1, math.min(count + 1, math.floor((x - start) / pitch) + 1))
end

--- Every frame: the view follows a tile carried to the edge, and pointing at a word says what it is
--- @param elapsed number
function View:watch(elapsed)
  if self.drag:Carrying() then
    self.viewport:EdgeScroll(elapsed)
    return
  end
  local board = self.board
  local square = self.view and board:IsMouseOver() and self.viewport.frame:IsMouseOver() and self:squareAt() or nil
  if square ~= self.tipSquare then
    self.tipSquare = square
    self:showTip(square)
  end
end

--- @param square number?
function View:showTip(square)
  --- @type WordsState
  local state = self.view.state
  if not square then
    GameTooltip_Hide()
    return
  end
  local lines = {}
  if state.board[square] then
    for _, across in ipairs({ true, false }) do
      local word = wordThrough(state, {}, square, across)
      local lore = word.length > 1 and Lexicon.Entry("warcraft", word.text)
      if lore then
        local color = lore.rank > 1 and LEGEND or GOLD
        local what = L["words_group_" .. lore.group]
        lines[#lines + 1] = { lore.name, color }
        lines[#lines + 1] = { lore.rank > 1 and L["words_legendary"]:format(what) or what, { 0.8, 0.8, 0.8 } }
      elseif word.length > 1 then
        lines[#lines + 1] = { word.text, { 1, 1, 1 } }
      end
    end
  elseif premiumAt(square) then
    lines[1] = { L["words_square_tip_" .. premiumAt(square)], SQUARE_COLORS[premiumAt(square)] }
  end
  if #lines == 0 then
    GameTooltip_Hide()
    return
  end
  GameTooltip:SetOwner(self.viewport.frame, "ANCHOR_CURSOR")
  GameTooltip:SetText(lines[1][1], unpack(lines[1][2]))
  for index = 2, #lines do
    GameTooltip:AddLine(lines[index][1], unpack(lines[index][2]))
  end
  GameTooltip:Show()
end

-----------------------------
-- Drawing
-----------------------------

--- The square a tile carried would land on, and where typing goes
function View:showMarks()
  local draft = self.view and drafts[self.view.match.id]
  local hover = self.drag:Carrying() and self.hoverSquare or nil
  self.hoverMark:SetShown(hover ~= nil)
  if hover then
    local x, y = self:offsetOf(hover)
    self.hoverMark:ClearAllPoints()
    self.hoverMark:SetPoint("TOPLEFT", x, -y)
  end

  local cursor = draft and self:busy() and draft.cursor
  local at = cursor and cursor.square
  self.cursorMark:SetShown(at ~= nil)
  self.cursorArrow:SetShown(at ~= nil)
  if at then
    self.cursorPulse:Play()
    local x, y = self:offsetOf(at)
    self.cursorMark:ClearAllPoints()
    self.cursorMark:SetPoint("TOPLEFT", x, -y)
    self.cursorArrow:ClearAllPoints()
    self.cursorArrow:SetPoint("CENTER", self.board, "TOPLEFT", x + self.cell / 2, -(y + self.cell / 2))
    -- The picture points right: turned a quarter, it points down
    if cursor.across then
      self.cursorArrow:SetTexCoord(0, 1, 0, 1)
    else
      self.cursorArrow:SetTexCoord(0, 1, 1, 1, 0, 0, 1, 0)
    end
  end
end

--- The tiles on the board, played and laid out, and the light around them
--- @param draft WordsDraft?
function View:showBoard(draft)
  local view = self.view
  --- @type WordsState
  local state = view.state
  local laid, glows = {}, {}
  for _, entry in ipairs(draft and draft.entries or {}) do
    if entry.square and entry ~= self.carried then
      laid[entry.square] = entry
    end
  end

  -- From the least to the most worth saying: what was played last, what is from Azeroth, and
  -- what the tiles laid out would make
  local last = view.events[view.ply]
  for square in pairs(last and last.placed or {}) do
    glows[square] = "last"
  end
  local key = view.match.id .. ":" .. view.ply
  if self.loreFor ~= key then
    self.loreFor, self.lore = key, loreOn(state)
  end
  for square, rank in pairs(self.lore) do
    glows[square] = rank > 1 and "known" or "lore"
  end
  local preview = self.preview
  for square in pairs(laid) do
    glows[square] = "laying"
  end
  for _, word in ipairs(preview.words or {}) do
    local glow = word.lore and (word.lore.rank > 1 and "legend" or "gold") or "fine"
    for _, square in ipairs(squaresOf(word)) do
      if glows[square] ~= "legend" and not (glows[square] == "gold" and glow == "fine") then
        glows[square] = glow
      end
    end
  end
  for _, square in ipairs(preview.wrong and squaresOf(preview.wrong) or {}) do
    glows[square] = "wrong"
  end

  for square = 0, SIZE * SIZE - 1 do
    local played, entry = state.board[square], laid[square]
    local tile = self.tiles[square]
    if (played or entry) and not tile then
      tile = Tiles.New(self.tileLayer)
      tile.wordsSquare = square
      self.tiles[square] = tile
      self:placeTile(square)
    end
    if played then
      local stood = played:match("%l") ~= nil
      tile:Set(played:upper(), not stood and worth(played) or nil, stood)
      tile:Tint(nil)
    elseif entry then
      local letter = entry.as and entry.as:upper() or (entry.tile ~= BLANK and entry.tile or nil)
      tile:Set(letter, entry.tile ~= BLANK and worth(entry.tile) or nil, entry.tile == BLANK)
      tile:Tint(LAID_TINT)
    end
    if tile then
      tile.laid = entry ~= nil
      tile:SetShown((played or entry) ~= nil)
    end

    local glow, style = self.glows[square], GLOWS[glows[square]]
    if style and not glow then
      glow = self.glowLayer:CreateTexture(nil, "ARTWORK")
      glow:SetTexture(Tiles.GLOW)
      glow:SetBlendMode("ADD")
      self.glows[square] = glow
      self:placeGlow(square)
    end
    if glow then
      glow.style = glows[square]
      glow:SetShown(style ~= nil)
      if style then
        glow:SetVertexColor(unpack(style))
      end
      -- A name everybody knows doesn't just lie there while it waits to be played
      local throbs = glows[square] == "legend"
      if throbs ~= (glow.throbs or false) then
        glow.throbs = throbs
        glow.pulse = glow.pulse or Widgets.Pulse(glow)
        if throbs then
          glow.pulse:Play()
        else
          glow.pulse:Stop()
        end
      end
    end
  end
end

--- The tiles in the rack. Each keeps its own picture for as long as it is there, so that it can
--- be seen going from one place to another
--- @param draft WordsDraft?
function View:showRack(draft)
  local entries = self:inRack()
  local used = {}
  for index, entry in ipairs(entries) do
    local tile = self.held[entry]
    if not tile then
      tile = table.remove(self.spare)
      if not tile then
        tile = Tiles.New(self.rack)
        tile.wordsHeld = true
        tile:EnableMouse(true)
        tile:SetScript("OnMouseDown", function(held, button)
          self:rackDown(held.entry, button)
        end)
      end
      tile:Fit(self.rackSide)
      -- A tile just drawn comes in from the side, one after the other
      tile.x = entry.fresh and (self.rack:GetWidth() + index * self.rackSide) or nil
      self.held[entry] = tile
    end
    entry.fresh = nil
    tile.entry, tile.index = entry, index
    tile:Set(entry.tile ~= BLANK and entry.tile or nil, worth(entry.tile))
    tile.picked = draft ~= nil and draft.swap ~= nil and draft.swap[entry] == true
    tile:Tint(tile.picked and PICKED_TINT or nil)
    tile:Show()
    used[entry] = true
  end
  for entry, tile in pairs(self.held) do
    if not used[entry] then
      self.held[entry] = nil
      tile.entry = nil
      tile:Hide()
      self.spare[#self.spare + 1] = tile
    end
  end
  self.rackCount = #entries
  self:slideRack(0)
end

--- Moves the tiles in the rack towards where they belong, leaving room where one carried would go
--- @param elapsed number
function View:slideRack(elapsed)
  if not self.rackSide then
    return
  end
  local count = self.rackCount or 0
  local gap = self.drag:Carrying() and self.gap or nil
  local pitch = self.rackSide + RACK_GAP
  local start = (self.rack:GetWidth() - (count + (gap and 1 or 0)) * pitch + RACK_GAP) / 2
  for _, tile in pairs(self.held) do
    local slot = tile.index - 1 + (gap and tile.index >= gap and 1 or 0)
    local x = start + slot * pitch
    local y = tile.picked and self.rackSide * 0.18 or 0
    -- One that has no place yet is where it belongs
    tile.x, tile.y = tile.x or x, tile.y or y
    local share = math.min(1, elapsed * RACK_SPEED)
    tile.x, tile.y = tile.x + (x - tile.x) * share, tile.y + (y - tile.y) * share
    tile:ClearAllPoints()
    tile:SetPoint("LEFT", self.rack, "LEFT", tile.x, tile.y)
  end
end

--- @param entry WordsEntry
--- @param button string
function View:rackDown(entry, button)
  if not entry or not self:busy() or button ~= "LeftButton" then
    return
  end
  local draft = self:draft()
  if draft.swap then
    draft.swap[entry] = not draft.swap[entry] or nil
    self:refresh()
    return
  end
  self:carry(entry)
end

--- What the side says about the tiles laid out
--- @param draft WordsDraft?
--- @return string
function View:noteText(draft)
  local view, preview = self.view, self.preview
  if not draft then
    return ""
  end
  if draft.swap then
    return L["words_swap_pick"]
  end
  local lines = {}
  for _, word in ipairs(preview.words or {}) do
    if word.lore then
      local color = word.lore.rank > 1 and LEGEND_TEXT or GOLD_TEXT
      lines[#lines + 1] = ("%s%s  %d|r"):format(color, word.lore.name, word.score)
      lines[#lines + 1] = ("%s%s|r"):format(GREY_TEXT, L["words_group_" .. word.lore.group])
    else
      lines[#lines + 1] = ("%s%s  %d|r"):format(WHITE, word.text, word.score)
    end
  end
  if preview.words and #preview.words > 0 then
    local laid = 0
    for _, entry in ipairs(draft.entries) do
      laid = laid + (entry.square and 1 or 0)
    end
    if laid == RACK then
      lines[#lines + 1] = GOLD_TEXT .. L["words_all_tiles"]:format(ALL_TILES_BONUS) .. "|r"
    end
  elseif preview.wrong then
    lines[1] = RED .. L["words_not_word"]:format(preview.wrong.text) .. "|r"
  elseif preview.err then
    lines[1] = RED .. L["err_" .. preview.err] .. "|r"
  elseif not preview.pending then
    lines[1] = GREY_TEXT .. L[view.canMove and "words_hint" or "words_hint_waiting"] .. "|r"
  end
  return table.concat(lines, "\n")
end

--- Scores, the bag, what the move would make and the buttons
--- @param draft WordsDraft?
function View:showPanel(draft)
  local view, preview = self.view, self.preview
  --- @type WordsState
  local state = view.state
  local turn = view.match.status == "active" and state.turn or nil
  local last
  for seat, plate in ipairs(self.plates) do
    plate:SetShown(seat <= state.seats)
    if seat <= state.seats then
      last = plate
      plate.back:SetColorTexture(unpack(seat == turn and PLATE_TURN or PLATE))
      plate.mark:SetShown(seat == turn)
      plate.name:SetText(view.names[seat])
      plate.held:SetText(state.out[seat] and L["words_resigned"] or L["words_tiles"]:format(#state.racks[seat]))
      plate:SetAlpha(state.out[seat] and 0.5 or 1)
      if not self.counting[seat] then
        plate.score:SetText(tostring(state.scores[seat]))
      end
    end
  end
  self.bagIcon:ClearAllPoints()
  self.bagIcon:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 8, -8)
  self.bag:SetText(L["words_bag"]:format(#state.bag))
  self.note:ClearAllPoints()
  self.note:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -34)
  self.note:SetText(self:noteText(draft))

  local buttons = self.buttons
  local laid, loose, picked = 0, 0, 0
  for _, entry in ipairs(draft and draft.entries or {}) do
    laid = laid + (entry.square and 1 or 0)
    loose = loose + (entry.square and 0 or 1)
    picked = picked + (draft.swap and draft.swap[entry] and 1 or 0)
  end
  local swapping = draft ~= nil and draft.swap ~= nil
  for _, button in pairs(buttons) do
    button:SetShown(draft ~= nil)
  end
  if not draft then
    return
  end
  if swapping then
    buttons.play:SetText(L["words_swap_n"]:format(picked))
    buttons.play:SetEnabled(view.canMove and picked > 0)
  else
    buttons.play:SetText(preview.move and L["words_play_for"]:format(preview.score) or L["words_play"])
    buttons.play:SetEnabled(view.canMove and preview.move ~= nil)
  end
  buttons.recall:SetText(swapping and L["words_cancel"] or L["words_recall"])
  buttons.recall:SetEnabled(swapping or laid > 0)
  buttons.shuffle:SetEnabled(not swapping and loose > 1)
  buttons.swap:SetEnabled(view.canMove and not swapping and #state.bag >= RACK)
  buttons.pass:SetText(draft.passing and L["words_pass_sure"] or L["words_pass"])
  buttons.pass:SetEnabled(view.canMove and not swapping)
end

--- @param view GameView
function View:Update(view)
  local other = self.view == nil or self.view.match.id ~= view.match.id
  self.view = view
  if view.changed then
    -- Whatever was still moving belonged to another position
    self.animator:Stop()
    self.tipSquare = nil
  end
  if other then
    self.drag:Cancel(true)
    self.carried, self.gap, self.hoverSquare = nil, nil, nil
    self.viewport:Fit(true)
    self.typing:ClearFocus()
  end

  local draft = self:busy() and self:draft() or nil
  if not draft and self.drag:Carrying() then
    self.drag:Cancel(true)
  end
  local laid = {}
  for _, entry in ipairs(draft and draft.entries or {}) do
    if entry.square then
      laid[#laid + 1] = entry
    end
  end
  self.preview = draft and compose(view.state, laid) or {}

  self:showBoard(draft)
  self:showRack(draft)
  self:showPanel(draft)
  self:showMarks()
  self.picker:SetShown(draft ~= nil and draft.picking ~= nil)

  if view.played then
    self:celebrate(view.played)
  end
end

-----------------------------
-- Showing a move
-----------------------------

--- Lets a line of text rise from a point and fade
--- @param text string
--- @param where fun(): number?, number? The point, from the bottom left corner of the stage. Asked when the text appears: by then the board may have been zoomed
--- @param below number How far under the point it starts
--- @param size number
--- @param delay number
function View:float(text, where, below, size, delay)
  local label = table.remove(self.floats) or self.effects:CreateFontString(nil, "OVERLAY")
  label.wordsFloat = true
  label:SetFont(STANDARD_TEXT_FONT, size, "OUTLINE")
  label:SetText(text)
  label:Hide()
  local x, y = 0, 0
  self.animator:Play(FLOAT, function(progress)
    label:ClearAllPoints()
    label:SetPoint("CENTER", self.effects, "BOTTOMLEFT", x, y - below + FLOAT_RISE * (1 - (1 - progress) ^ 2))
    label:SetAlpha(progress < 0.7 and 1 or (1 - progress) / 0.3)
  end, {
    delay = delay,
    onStart = function()
      local atX, atY = where()
      x, y = atX or 0, atY or 0
      label:Show()
    end,
    onDone = function()
      label:Hide()
      self.floats[#self.floats + 1] = label
    end,
  })
end

--- Shows a move being made: the tiles going down one after the other, each word it made lighting
--- up with what it scored, and the score counting up
--- @param event WordsEvent
function View:celebrate(event)
  local view, animator = self.view, self.animator
  local plate = self.plates[event.seat]
  local mine = event.seat == view.seat
  local who = view.names[event.seat]
  local middleX, middleY = centreIn(self.viewport.frame, self.effects)
  middleX, middleY = middleX or 0, middleY or 0

  if not event.placed then
    local text = event.swapped and L["words_they_swapped"]:format(who, event.swapped) or L["words_they_passed"]:format(who)
    self:float(text, function()
      return middleX, middleY
    end, 0, 16, 0)
    if mine and event.swapped then
      Widgets.PlaySound(SOUNDS.draw)
    end
    return
  end

  -- A move should be seen whole, the player's own as well: they were close in to lay it
  self.viewport:Fit()
  local squares = {}
  for square in pairs(event.placed) do
    squares[#squares + 1] = square
  end
  table.sort(squares)
  local fromX, fromY = centreIn(plate, self.effects)
  for index, square in ipairs(squares) do
    local tile = self.tiles[square]
    local delay = (index - 1) * TILE_APART
    if tile then
      tile:SetAlpha(0)
      local land = delay
      if not mine and fromX then
        -- It comes from whoever played it
        land = delay + FLIGHT
        local flight = table.remove(self.flights) or Tiles.New(self.effects)
        flight:Set(event.placed[square]:upper(), worth(event.placed[square]), event.placed[square]:match("%l") ~= nil)
        flight:Hide()
        animator:Play(FLIGHT, function(progress)
          local toX, toY = centreIn(tile, self.effects)
          local eased = 1 - (1 - progress) ^ 3
          flight:Fit(self.cell * (0.5 + 0.5 * eased) * self.viewport.zoom)
          flight:ClearAllPoints()
          flight:SetPoint("CENTER", self.effects, "BOTTOMLEFT", fromX + ((toX or fromX) - fromX) * eased, fromY + ((toY or fromY) - fromY) * eased)
        end, {
          delay = delay,
          onStart = function()
            flight:Show()
          end,
          onDone = function()
            flight:Hide()
            self.flights[#self.flights + 1] = flight
          end,
        })
      end
      animator:Play(TILE_POP, function(progress)
        -- Up to size quickly, a little past it and back
        self:placeTile(square, 0.5 + 0.5 * (1 - (1 - progress) ^ 2) + math.sin(progress * math.pi) * 0.18)
      end, {
        delay = land,
        onStart = function()
          tile:SetAlpha(1)
          Widgets.PlaySound(SOUNDS.tile)
        end,
        onDone = function()
          self:placeTile(square)
        end,
      })
    end
  end

  local after = #squares * TILE_APART + TILE_POP + (mine and 0 or FLIGHT)
  for index, word in ipairs(event.words) do
    local delay = after + (index - 1) * WORD_APART
    local on = squaresOf(word)
    local color = word.lore and (word.lore.rank > 1 and LEGEND or GOLD) or { 1, 1, 1 }
    -- The word lights up and dies down to what it was
    animator:Play(WORD_APART * 1.6, function(progress)
      for _, square in ipairs(on) do
        local glow = self.glows[square]
        if glow then
          local style = GLOWS[glow.style] or { 1, 1, 1, 0 }
          local share = (1 - progress) ^ 2
          glow:Show()
          glow:SetVertexColor(
            style[1] + (color[1] - style[1]) * share,
            style[2] + (color[2] - style[2]) * share,
            style[3] + (color[3] - style[3]) * share,
            style[4] + (1 - style[4]) * share
          )
          if progress >= 1 then
            glow:SetShown(GLOWS[glow.style] ~= nil)
          end
        end
      end
    end, {
      delay = delay,
      onStart = function()
        for _, square in ipairs(on) do
          if not self.glows[square] then
            local glow = self.glowLayer:CreateTexture(nil, "ARTWORK")
            glow:SetTexture(Tiles.GLOW)
            glow:SetBlendMode("ADD")
            self.glows[square] = glow
            self:placeGlow(square)
          end
        end
        if word.lore then
          Widgets.PlaySound(word.lore.rank > 1 and SOUNDS.legend or SOUNDS.lore)
        end
      end,
    })

    --- @return number?, number? The middle of the word
    local function middle()
      local x, y = centreIn(self.tiles[on[1]], self.effects)
      local farX, farY = centreIn(self.tiles[on[#on]], self.effects)
      if not x or not farX then
        return nil
      end
      return (x + farX) / 2, (y + farY) / 2
    end
    if word.lore then
      local text = (word.lore.rank > 1 and LEGEND_TEXT or GOLD_TEXT) .. word.lore.name .. "  +" .. word.score .. "|r"
      self:float(text, middle, 0, word.lore.rank > 1 and 26 or 20, delay)
      self:float(GREY_TEXT .. L["words_group_" .. word.lore.group] .. "|r", middle, 20, 12, delay)
    else
      self:float("+" .. word.score, middle, 0, 16, delay)
    end
  end

  if event.allTiles then
    local banner = self.banner
    banner:SetText(L["words_all_tiles"]:format(ALL_TILES_BONUS))
    animator:Play(2, function(progress)
      banner:ClearAllPoints()
      banner:SetPoint("CENTER", self.effects, "BOTTOMLEFT", middleX, middleY + 10 * progress)
      banner:SetAlpha(progress < 0.15 and progress / 0.15 or (progress < 0.75 and 1 or (1 - progress) / 0.25))
    end, {
      delay = after,
      onStart = function()
        banner:Show()
        Widgets.PlaySound(SOUNDS.legend)
      end,
      onDone = function()
        banner:Hide()
      end,
    })
  end

  -- The score counts up to where it now stands
  local to = view.state.scores[event.seat]
  local from = to - event.score - (event.settled and event.settled[event.seat] or 0)
  self.counting[event.seat] = true
  plate.score:SetText(tostring(from))
  animator:Play(COUNT_UP, function(progress)
    plate.score:SetText(tostring(math.floor(from + (to - from) * (1 - (1 - progress) ^ 2) + 0.5)))
  end, {
    delay = after,
    onDone = function()
      self.counting[event.seat] = nil
      plate.score:SetText(tostring(to))
    end,
  })
  if mine and event.drew and event.drew > 0 then
    Widgets.PlaySound(SOUNDS.draw)
  end
end

private.Games.Register({
  id = "words",
  name = L["game_words"],
  description = L["game_words_description"],
  genre = "words",
  icon = "Interface\\AddOns\\ForeverGames\\Images\\Icons\\words",
  version = 1,
  seats = { 2, 3, 4 },
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
  visible = visible,
  createView = createView,
  history = true,
})
