--------------------------
--  Game registry
--------------------------
-- A game is two halves. The rules are pure functions over a state table, with no game client in
-- them: they are what both players replay to agree on a position, and what the tests run. The
-- view draws a position into a frame it is given and turns clicks into moves.
--
-- To add a game, drop a file in Games/, list it in the .toc and call private.Games.Register from
-- it. Games/TicTacToe.lua is the smallest example, Games/Chess.lua uses everything on offer.
-- Games/ConnectFour.lua and Games/Reversi.lua place pieces instead of moving them, and
-- Games/ChineseCheckers.lua is for up to six players on a board that isn't a grid.
--
-- The window around the view is the engine's: who is playing, whose turn it is, resigning, draw
-- offers, the list of moves and stepping back through them. A game opts into the last two with
-- `draws` and `history`, it doesn't build them.
--
-- Games of chance are given their dice and shuffles by the engine (Engine/Random.lua), see
-- Games/Backgammon.lua. Games where a player holds something the others don't see say what each
-- of them may know with `visible`, see Games/CrazyEights.lua, and Games/Battleship.lua for
-- something a player chose themselves instead of being dealt.
--
-- A game can also be for one (`seats = 1`), see Games/Solitaire.lua. There is nobody to
-- challenge and nothing to send: it begins as soon as it is picked, it is always the player's
-- turn, and with `undo` a move can be taken back.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- What a view is asked to show
--- @class GameView
--- @field match Match
--- @field state table The position to draw, as the local player may see it. Belongs to the engine: don't change it or keep it
--- @field seat number The local player's seat
--- @field names string[] Who is playing, by seat, as their names are shown
--- @field canMove boolean Whether the local player may move right now
--- @field submit fun(move: string) Plays a move for the local player
--- @field ply number How many log entries led to this position
--- @field live boolean False while the player is looking back at an earlier position
--- @field events MatchEvent[] What every log entry did, events[ply] led to this position
--- @field fresh boolean The player hasn't seen this position before
--- @field changed boolean This isn't the position the view was last asked to show
--- @field played MatchEvent? The move to show being made: set when the position follows from the last one shown by that move, or when the opponent made it while the player wasn't looking

--- @class GameViewObject
--- @field Layout fun(self: GameViewObject, width: number, height: number) Fit into this much room. Called before the first Update and again whenever the window is resized
--- @field Update fun(self: GameViewObject, view: GameView) Show a position. Called on every change and often when nothing changed at all, so it has to be cheap and must not restart animations

--- @class GameDefinition
--- @field id string Unique id sent over the wire, letters and digits only
--- @field name string Display name
--- @field description string? One or two sentences for the new game wizard
--- @field genre string? What kind of game it is, for narrowing down the list in the wizard. Shown as L["genre_" .. genre], use one that is there already where it fits
--- @field icon string? Texture path, square
--- @field version number Bump when the rules or move format change, players on different versions can't play each other
--- @field seats number|number[] How many play it. A list where there is a choice, e.g. { 2, 3, 4, 6 }. 1 for a game the player plays alone
--- @field newState fun(seats: number, random: Random): table Fresh game state for this many players. A game of chance deals and rolls from `random`, never from anywhere else: it is what makes every player's client come out with the same cards and dice (Engine/Random.lua)
--- @field turn fun(state: table): number Seat that moves next. It needn't be the other player's: a game where a player can be left without a move just says it is the same seat's turn again
--- @field validate fun(state: table, seat: number, move: string): boolean, string? Whether a move is legal, with an error code if not
--- @field apply fun(state: table, seat: number, move: string, random: Random): table? Applies a legal move to the state. May return a table saying what happened, for the view to animate from: the engine hands it back as a MatchEvent. Set `notation` in it for the move list. Whatever the move leaves to chance (the next roll, a card drawn from a pile that had to be shuffled) comes from `random`. Every player gets to see the table, so it mustn't say what only some of them may know
--- @field visible (fun(state: table, seat: number): table)? For games where players don't all know the same: what a seat may see of a position. Returns a copy with the rest blanked out, shaped like the state itself so the view has only one thing to draw. Views are never shown anything else while the game is on. This is good manners rather than a secret kept: the log every player holds has all of it
--- @field result fun(state: table): { winner: number, detail: string? }? nil while in progress, winner 0 for a draw. detail names how it ended and is shown as L["result_" .. detail]
--- @field drop (fun(state: table, seat: number))? A player resigned and the others play on: take them out of the game and never say it is their turn again. Needed by games for more than two. The engine ends the game itself once only one player is left
--- @field createView fun(stage: Frame): GameViewObject Builds the game's widgets inside stage. Called once, the first time one of its matches is looked at
--- @field draws boolean? Players may agree a draw
--- @field history boolean? Moves have a notation: show the move list and let players step back through the game
--- @field seatLabel (fun(seat: number, seats: number): string)? Short label for a seat in a game of this many players, e.g. "X"
--- @field undo boolean? For a game for one: the player may take moves back, as many as they like. The window has the button, and the view is shown the position before with `changed` set
--- @field progress (fun(state: table): string?)? For a game for one: how it is going in a few words, e.g. "120 points in 34 moves". Shown where a game against someone says whose turn it is

--- @class Games
local Games = {}
private.Games = Games

--- @type table<string, GameDefinition>
local registry = {}
--- @type GameDefinition[]
local ordered = {}

local REQUIRED = { "newState", "turn", "validate", "apply", "result", "createView" }
-- Seats are a single digit in the log
local MAX_SEATS = 9

--- The numbers of players a game can be played with, smallest first
--- @param game GameDefinition
--- @return number[]
function Games.SeatCounts(game)
  local counts = type(game.seats) == "table" and { unpack(game.seats) } or { game.seats }
  table.sort(counts)
  return counts
end

--- Whether a game is only ever played alone
--- @param game GameDefinition
--- @return boolean
function Games.IsSolo(game)
  local counts = Games.SeatCounts(game)
  return counts[#counts] == 1
end

--- @param game GameDefinition
--- @param seats number
--- @return boolean
function Games.CanSeat(game, seats)
  for _, count in ipairs(Games.SeatCounts(game)) do
    if count == seats then
      return true
    end
  end
  return false
end

--- @param definition GameDefinition
function Games.Register(definition)
  assert(private.Codec.IsSafeField(definition.id), "Game id must be alphanumeric")
  assert(not registry[definition.id], "Game already registered: " .. definition.id)
  local counts = Games.SeatCounts(definition)
  assert(#counts > 0, "Game " .. definition.id .. " doesn't say how many play it")
  for _, count in ipairs(counts) do
    local whole = type(count) == "number" and count == math.floor(count)
    assert(whole and count >= 1 and count <= MAX_SEATS, "Games are for 1 to " .. MAX_SEATS .. " players")
  end
  assert(counts[#counts] <= 2 or type(definition.drop) == "function", "Game " .. definition.id .. " is missing drop")
  for _, key in ipairs(REQUIRED) do
    assert(type(definition[key]) == "function", "Game " .. definition.id .. " is missing " .. key)
  end

  registry[definition.id] = definition
  ordered[#ordered + 1] = definition
end

--- @param id string
--- @return GameDefinition?
function Games.Get(id)
  return registry[id]
end

--- @return GameDefinition[]
function Games.List()
  return ordered
end

--- The genres there are games of, in the order they first came up
--- @return string[]
function Games.Genres()
  local genres, seen = {}, {}
  for _, game in ipairs(ordered) do
    if game.genre and not seen[game.genre] then
      seen[game.genre] = true
      genres[#genres + 1] = game.genre
    end
  end
  return genres
end

--- The games to offer someone looking for one
--- @param text string? What they typed. Every word has to turn up in the name, the description or the genre, in any case
--- @param genre string? Only games of this genre
--- @param players number? Only games this many can play. Three stands for three or more
--- @return GameDefinition[]
function Games.Search(text, genre, players)
  local words = {}
  for word in (text or ""):lower():gmatch("%S+") do
    words[#words + 1] = word
  end

  local found = {}
  for _, game in ipairs(ordered) do
    local matches = genre == nil or game.genre == genre
    if players then
      local counts = Games.SeatCounts(game)
      matches = matches and (Games.CanSeat(game, players) or (players >= 3 and counts[#counts] >= 3))
    end
    local about = table.concat({ game.name, game.description or "", game.genre and private.L["genre_" .. game.genre] or "" }, " ")
    for _, word in ipairs(words) do
      matches = matches and about:lower():find(word, 1, true) ~= nil
    end
    if matches then
      found[#found + 1] = game
    end
  end
  return found
end
