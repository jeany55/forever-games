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
-- turn, and with `undo` a move can be taken back. The engine can keep the time it is played for
-- (`clock`) and remember the best the player ever did at it (`record`): see Games/Minesweeper.lua.
-- And it can be the day's challenge (`daily`), dealt the same way for the whole guild every
-- day, with a board of how everyone did: see Engine/Daily.lua.
--
-- A game for one that is timed and keeps records can be raced against somebody, with nothing
-- more from the game: both are dealt the same, each plays it whenever they like, and the
-- quicker time wins (Engine/Race.lua). A game can give the race a ghost of the rival's run to
-- race against (`ghost`): its view keeps where the player is every so often, and is shown where
-- the rival was (GameView.race).
--
-- A game can let whoever sets it up change some of its rules (`options`): what a bonus is worth,
-- whether taking is compulsory. What they chose travels with the challenge and is kept with the
-- match, and the game is handed all of it when the state is made: see Games/Words.lua. Only what
-- isn't the default is ever sent or kept, so a game without any is a game by the usual rules.
--
-- A game for two or more can be played against the computer (`computer`), which takes the seats
-- of everyone but the player: see Engine/Computer.lua. Given nothing but the moves there are, it
-- plays the game, and the more the game tells it the better it plays.
--
-- A game needn't have turns at all (`together`): everyone moves whenever they like, as when a
-- puzzle is solved between them. It has no `turn`, and it has to take its moves in whatever order
-- they happen to arrive: what two players did at the same moment is put one after the other, and
-- a move that is no longer legal by then (the other one found that word first) is dropped.
--
-- Every game is put through the same checks by the tests (Tests/EveryGame.lua): that the same
-- seed always deals the same game, that its rules never ask the client for the time or a random
-- number of its own, and that everything it shows the players is in the locale. A game that can
-- list the moves there are (`moves`) is also played out at random, many times over: every move
-- it lists has to be legal, and the log has to replay to the same position on another client.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- What a view is asked to show
--- @class GameView
--- @field match Match
--- @field state table The position to draw, as the local player may see it. Belongs to the engine: don't change it or keep it
--- @field seat number The local player's seat
--- @field names string[] Who is playing, by seat, as their names are shown
--- @field canMove boolean Whether the local player may move right now. In a game played together that is for as long as it lasts
--- @field submit fun(move: string) Plays a move for the local player
--- @field ply number How many log entries led to this position
--- @field live boolean False while the player is looking back at an earlier position
--- @field events MatchEvent[] What every log entry did, events[ply] led to this position
--- @field fresh boolean The player hasn't seen this position before
--- @field changed boolean This isn't the position the view was last asked to show
--- @field clock fun(): number For a game that is timed (`clock`): how many seconds it has been played for by now. Asked whenever the view likes, it goes on counting between updates
--- @field best fun(key: string): number?, boolean For a game that keeps records (`record`): the best there ever was under a key, and whether it was this match that set it
--- @field played MatchEvent? The move to show being made: set when the position follows from the last one shown by that move, or when the opponent made it while the player wasn't looking
--- @field catching boolean? The window is showing the player the moves the others made while they were away, one after the other, before the game as it stands. Not `live`, and nothing can be played, but `played` is to be shown being made as it would be in the game as it stands: the dice thrown, the turn played out. A view that says it is still showing a move (`Busy`) is waited for before the next
--- @field sample (fun(text: string): boolean)? For a game for one with a `ghost`: where the player is now, for the ghost of their run, kept with their best if it is one (and in a race sent to the rival). As RaceView.sample
--- @field ghost (fun(key: string): string[]?)? For a game for one with a `ghost`: the samples of the run that set the player's best under a key, nil if there is none, to race against
--- @field race RaceView? The game for one is a race against somebody, who is playing the same deal on their own (Engine/Race.lua): who, how they did, and for a game with a `ghost` where they were as they played

--- @class GameViewObject
--- @field Layout fun(self: GameViewObject, width: number, height: number) Fit into this much room. Called before the first Update and again whenever the window is resized
--- @field Update fun(self: GameViewObject, view: GameView) Show a position. Called on every change and often when nothing changed at all, so it has to be cheap and must not restart animations
--- @field Busy (fun(self: GameViewObject): boolean)? Whether it is still showing a move being made. The window waits for it before the computer makes its next move, and before showing the next of the moves the player missed
--- @field Paused (fun(self: GameViewObject): boolean)? For a game that is timed (`clock`): whether the player is keeping it still, as a game played against the clock as it falls is paused. The clock isn't run while it is

--- Something about a game that whoever sets it up may change
--- @class GameOption
--- @field id string Sent over the wire, letters and digits only. Keep it short
--- @field name string
--- @field description string? A sentence about what it does, for the tooltip
--- @field choices (number|string)[]? What it can be set to. Left out for something that is on or off
--- @field default number|string|boolean What it is unless somebody says otherwise. Changing it changes the rules: bump `version`
--- @field label (fun(value: number|string): string)? How a choice is shown, the value itself if left out
--- @field when (fun(rules: table<string, any>): boolean)? Whether it matters with the rest set the way it is. One that doesn't isn't offered
--- @field alone boolean? Only matters in a game played alone, of one that can be played with others too: the computer players in it. It isn't offered for a game with others, nor sent with a challenge

--- A part of how a game is played, for whoever doesn't know it: what it is for, what a turn is,
--- how it ends, which keys do what. Shown a heading over its text by the window's How to play
--- @class GameHowTo
--- @field heading string
--- @field text string|fun(rules: table<string, any>, players: number?): string? What it says, or what it says with the rules set the way they are (see Games.Rules) for so many players, if that is known. A section whose function says nothing isn't shown for those rules

--- Something a game for one is played for: a score to beat, a time to get under
--- @class GameRecord
--- @field key string What it is the best of, e.g. "score" or the name of a difficulty. Letters, digits and underscores
--- @field value number
--- @field lower boolean? Less is better, as with a time

--- @class GameDefinition
--- @field id string Unique id sent over the wire, letters and digits only
--- @field name string Display name
--- @field description string? One or two sentences for the new game wizard
--- @field genre string? What kind of game it is, for narrowing down the list in the wizard. Shown as L["genre_" .. genre], use one that is there already where it fits
--- @field icon string? Texture path, square
--- @field version number Bump when the rules or move format change, players on different versions can't play each other
--- @field seats number|number[] How many play it. A list where there is a choice, e.g. { 2, 3, 4, 6 }. 1 for a game the player plays alone
--- @field options GameOption[]? What whoever sets a game up may change about its rules, in the order they are offered
--- @field howto GameHowTo[]? How the game is played, a section at a time, the way it is usually played unless a section says otherwise for the rules that were set
--- @field newState fun(seats: number, random: Random, rules: table<string, any>): table Fresh game state for this many players. `rules` has what every option is set to for this match, by id: keep in the state whatever the rules need of it later. A game of chance deals and rolls from `random`, never from anywhere else: it is what makes every player's client come out with the same cards and dice (Engine/Random.lua)
--- @field together boolean? There are no turns: every player moves whenever they like, see above. Whatever the game does with a move has to come out right with the moves of the others before or after it
--- @field turn (fun(state: table): number)? Seat that moves next. Left out by a game played together. It needn't be the other player's: a game where a player can be left without a move just says it is the same seat's turn again
--- @field validate fun(state: table, seat: number, move: string): boolean, string? Whether a move is legal, with an error code if not
--- @field apply fun(state: table, seat: number, move: string, random: Random): table? Applies a legal move to the state. May return a table saying what happened, for the view to animate from: the engine hands it back as a MatchEvent. Set `notation` in it for the move list. Whatever the move leaves to chance (the next roll, a card drawn from a pile that had to be shuffled) comes from `random`. Every player gets to see the table, so it mustn't say what only some of them may know
--- @field visible (fun(state: table, seat: number): table)? For games where players don't all know the same: what a seat may see of a position. Returns a copy with the rest blanked out, shaped like the state itself so the view has only one thing to draw. Views are never shown anything else while the game is on. This is good manners rather than a secret kept: the log every player holds has all of it
--- @field result fun(state: table): { winner: number, detail: string?, all: boolean? }? nil while in progress, winner 0 for a draw. Winner 0 and `all` where the players were on the same side and made it together. detail names how it ended and is shown as L["result_" .. detail]
--- @field drop (fun(state: table, seat: number))? A player resigned and the others play on: take them out of the game and never say it is their turn again. Needed by games for more than two, unless they are played together. The engine ends the game itself once only one player is left
--- @field beaten (fun(state: table, seat: number): boolean)? For a game for more than two where a player can be put out of it by the others while they play on: whether a seat has been. A game against the computer is over for the player once they are, the computer doesn't play on among itself
--- @field moves (fun(state: table, seat: number): string[])? The moves a seat could make, each of them legal and none twice. All of them where that is practical; where there are far too many (every word that could be laid) enough of them for a game played with nothing else to get somewhere. Asked only while the game is on, of a seat that may move: the one whose turn it is, or anyone still in a game played together. The tests play every game that has it out at random to see that its rules hold together (Tests/EveryGame.lua)
--- @field createView fun(stage: Frame): GameViewObject Builds the game's widgets inside stage. Called once, the first time one of its matches is looked at
--- @field draws boolean? Players may agree a draw
--- @field history boolean? Moves have a notation: show the move list and let players step back through the game
--- @field seatLabel (fun(seat: number, seats: number): string)? Short label for a seat in a game of this many players, e.g. "X"
--- @field undo boolean? For a game for one: the player may take moves back, as many as they like. The window has the button, and the view is shown the position before with `changed` set
--- @field progress (fun(state: table): string?)? For a game for one or one played together: how it is going in a few words, e.g. "120 points in 34 moves". Shown where a game against someone says whose turn it is
--- @field clock ("open"|"move")? For a game for one: the engine keeps the time it is played for, while it is on screen and not over. From when it is first looked at, or only once the first move is made
--- @field record (fun(state: table, seconds: number, result: MatchResult?): GameRecord[]?)? For a game for one: what of this position is worth remembering if it is the best the player ever did. Asked after every move, with how long the game has been played for and how it ended if it has
--- @field computer GameComputer? The game can be played against the computer, and this is what it knows about playing it (Engine/Computer.lua). `{}` will do for a game with `moves`
--- @field addon string? What the game needs to be played is an addon of its own, loaded when it is (its maps, say, too much to load at every login). The game is only offered, and a challenge to it only taken up, while that addon is there and switched on (Games.Offered)
--- @field daily GameDaily? For a game that can be played alone: it is a challenge every day, the same for everyone who plays it that day (Engine/Daily.lua)
--- @field ghost GameGhost? For a game for one that can be raced (`clock` and `record`): the player's run is kept as they go, a few samples a second, goes to the rival with their time, and is shown to the rival while they race it (Engine/Race.lua). Nothing is asked of a game without one
--- @field raced boolean? False for a game that is timed and keeps records but isn't to be raced, which every other such game can be (Engine/Race.lua)
--- @field raceFor (GameRaceFor|GameRaceForRules)? A game that is raced is raced on its time unless it says what else: the record it is raced for, the more the better, and how a run's value is shown (Engine/Race.lua). Or a function of the rules that says so for a race set up that way, nil for its time

--- @class Games
local Games = {}
private.Games = Games

--- @type table<string, GameDefinition>
local registry = {}
--- @type GameDefinition[]
local ordered = {}
-- Whether an addon a game needs is there and switched on: the client says, the engine knows
-- nothing of addons (SetAddOnCheck). Until told, every addon is taken to be there
local addOnThere = function()
  return true
end

local REQUIRED = { "newState", "validate", "apply", "result", "createView" }
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

--- Whether a game can be played by the player on their own: a game for one, or one the computer
--- plays the others' seats of
--- @param game GameDefinition
--- @return boolean
function Games.PlaysAlone(game)
  return Games.CanSeat(game, 1) or game.computer ~= nil
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

--- What an option can be set to
--- @param option GameOption
--- @return (number|string|boolean)[]
function Games.Choices(option)
  return option.choices or { true, false }
end

--- @param value number|string|boolean
--- @return string How a value is written in a challenge
local function written(value)
  if type(value) == "boolean" then
    return value and "1" or "0"
  end
  return tostring(value)
end

--- @param option GameOption
--- @param value any
--- @return boolean
local function allows(option, value)
  for _, choice in ipairs(Games.Choices(option)) do
    if choice == value then
      return true
    end
  end
  return false
end

--- What every option is set to: what was chosen where that is something the option can be,
--- and what the game does by default for the rest
--- @param options GameOption[]?
--- @param chosen table<string, any>?
--- @return table<string, any>
function Games.Rules(options, chosen)
  local rules = {}
  for _, option in ipairs(options or {}) do
    local value = chosen and chosen[option.id]
    if value == nil or not allows(option, value) then
      value = option.default
    end
    rules[option.id] = value
  end
  return rules
end

--- What is left of a choice of rules once everything that is the default anyway is taken out
--- @param game GameDefinition
--- @param chosen table<string, any>?
--- @return table<string, any>? nil for the usual rules
function Games.Chosen(game, chosen)
  local rules, kept = Games.Rules(game.options, chosen), nil
  for _, option in ipairs(game.options or {}) do
    if rules[option.id] ~= option.default then
      kept = kept or {}
      kept[option.id] = rules[option.id]
    end
  end
  return kept
end

--- A choice of rules for a game of so many players: what only matters to a game played alone is
--- left out of one with others
--- @param game GameDefinition
--- @param chosen table<string, any>?
--- @param players number
--- @return table<string, any>?
function Games.ForPlayers(game, chosen, players)
  if not chosen or players == 1 then
    return chosen
  end
  local kept = {}
  for _, option in ipairs(game.options or {}) do
    if not option.alone then
      kept[option.id] = chosen[option.id]
    end
  end
  return kept
end

--- Writes a choice of rules down for a challenge: "lore=10+bingo=100"
--- @param game GameDefinition
--- @param chosen table<string, any>?
--- @return string? nil for the usual rules
function Games.EncodeOptions(game, chosen)
  local kept = Games.Chosen(game, chosen)
  if not kept then
    return nil
  end
  local parts = {}
  for _, option in ipairs(game.options) do
    if kept[option.id] ~= nil then
      parts[#parts + 1] = option.id .. "=" .. written(kept[option.id])
    end
  end
  return table.concat(parts, "+")
end

--- Reads the rules a challenge came with
--- @param game GameDefinition
--- @param text string?
--- @return table<string, any>? chosen nil for the usual rules
--- @return boolean understood False if it names an option this game doesn't have here, or something it can't be set to
function Games.DecodeOptions(game, text)
  if not text then
    return nil, true
  end
  local chosen = {}
  for part in text:gmatch("[^+]+") do
    local id, value = part:match("^(%w+)=(.+)$")
    local found = false
    for _, option in ipairs(game.options or {}) do
      if option.id == id and chosen[id] == nil then
        for _, choice in ipairs(Games.Choices(option)) do
          if written(choice) == value then
            chosen[id], found = choice, true
          end
        end
      end
    end
    if not found then
      return nil, false
    end
  end
  return Games.Chosen(game, chosen), true
end

--- How a setting of an option is shown to the players
--- @param option GameOption
--- @param value number|string|boolean
--- @return string
function Games.OptionLabel(option, value)
  if type(value) == "boolean" then
    return private.L[value and "option_on" or "option_off"]
  end
  return option.label and option.label(value) or tostring(value)
end

--- The options that matter with the rules set the way they are
--- @param game GameDefinition
--- @param rules table<string, any> Everything set, see Games.Rules
--- @param players number? How many are playing, if it is known
--- @return GameOption[]
function Games.OptionsFor(game, rules, players)
  local offered = {}
  for _, option in ipairs(game.options or {}) do
    local matters = not option.alone or not players or players == 1
    if matters and (not option.when or option.when(rules)) then
      offered[#offered + 1] = option
    end
  end
  return offered
end

--- What is different about a match from the way the game is usually played, a line for each
--- thing: "All seven tiles: +100"
--- @param game GameDefinition
--- @param chosen table<string, any>?
--- @param players number? How many are playing, if it is known
--- @return string[] Nothing for the usual rules
function Games.DescribeOptions(game, chosen, players)
  local rules, lines = Games.Rules(game.options, chosen), {}
  for _, option in ipairs(Games.OptionsFor(game, rules, players)) do
    if rules[option.id] ~= option.default then
      lines[#lines + 1] = private.L["option_line"]:format(option.name, Games.OptionLabel(option, rules[option.id]))
    end
  end
  return lines
end

--- How a game is played, with its rules set this way: every section that has something to say
--- for them
--- @param game GameDefinition
--- @param chosen table<string, any>?
--- @param players number? How many are playing, if it is known
--- @return { heading: string, text: string }[] Nothing for a game that doesn't say
function Games.HowTo(game, chosen, players)
  local rules, sections = Games.Rules(game.options, chosen), {}
  for _, section in ipairs(game.howto or {}) do
    local text = section.text
    if type(text) == "function" then
      text = text(rules, players)
    end
    if text then
      sections[#sections + 1] = { heading = section.heading, text = text }
    end
  end
  return sections
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
  assert(counts[#counts] <= 2 or definition.together or type(definition.drop) == "function", "Game " .. definition.id .. " is missing drop")
  for _, key in ipairs(REQUIRED) do
    assert(type(definition[key]) == "function", "Game " .. definition.id .. " is missing " .. key)
  end
  assert(definition.together or type(definition.turn) == "function", "Game " .. definition.id .. " is missing turn")
  assert(definition.moves == nil or type(definition.moves) == "function", "Game " .. definition.id .. " has moves that aren't a function")
  local problem = private.Computer.Problem(definition)
  assert(not problem, "Game " .. definition.id .. " " .. tostring(problem))
  if definition.daily then
    assert(Games.CanSeat(definition, 1), "Game " .. definition.id .. " is a daily challenge and can't be played alone")
    assert(type(definition.daily.score) == "function", "Game " .. definition.id .. " is a daily challenge without a score")
  end
  local raceFor = definition.raceFor
  if raceFor and type(raceFor) ~= "function" then
    assert(type(raceFor.key) == "string" and type(raceFor.show) == "function",
      "Game " .. definition.id .. " is raced for something without saying what or how it is shown")
  end
  if definition.ghost then
    assert(private.Race.Has(definition), "Game " .. definition.id .. " has a ghost and can't be raced")
    local every = definition.ghost.every
    assert(definition.ghost.marks or (type(every) == "number" and every > 0), "Game " .. definition.id .. " has a ghost without a time between its samples")
    local course = definition.ghost.course
    assert(course == nil or type(course) == "function", "Game " .. definition.id .. " has a ghost whose course isn't a function")
  end
  for _, section in ipairs(definition.howto or {}) do
    local text = section.text
    assert(type(section.heading) == "string" and (type(text) == "string" or type(text) == "function"),
      "Game " .. definition.id .. " has a part of how to play it without a heading or anything to say")
  end
  local seen = {}
  for _, option in ipairs(definition.options or {}) do
    local named = type(option.id) == "string" and option.id:match("^%w+$") ~= nil and not seen[option.id]
    assert(named, "Game " .. definition.id .. " has an option with a bad or repeated id")
    assert(allows(option, option.default), "Option " .. option.id .. " of " .. definition.id .. " can't be what it is by default")
    seen[option.id] = true
  end
  for id, value in pairs(definition.daily and definition.daily.rules or {}) do
    local known = false
    for _, option in ipairs(definition.options or {}) do
      known = known or (option.id == id and allows(option, value))
    end
    assert(known, "Game " .. definition.id .. " has a daily challenge with an option it can't be set to: " .. tostring(id))
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

--- Says how to tell whether an addon is there and switched on, for games that need one
--- @param check fun(addon: string): boolean
function Games.SetAddOnCheck(check)
  addOnThere = check
end

--- Whether a game can be played here: it needs no addon of its own, or the one it needs is there
--- @param game GameDefinition
--- @return boolean
function Games.Offered(game)
  return game.addon == nil or addOnThere(game.addon) == true
end

--- The genres there are games of, in the order they first came up
--- @return string[]
function Games.Genres()
  local genres, seen = {}, {}
  for _, game in ipairs(ordered) do
    if game.genre and not seen[game.genre] and Games.Offered(game) then
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
    local matches = (genre == nil or game.genre == genre) and Games.Offered(game)
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
