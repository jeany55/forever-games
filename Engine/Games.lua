--------------------------
--  Game registry
--------------------------
-- A game is two halves. The rules are pure functions over a state table, with no game client in
-- them: they are what both players replay to agree on a position, and what the tests run. The
-- view draws a position into a frame it is given and turns clicks into moves.
--
-- To add a game, drop a file in Games/, list it in the .toc and call private.Games.Register from
-- it. Games/TicTacToe.lua is the smallest example, Games/Chess.lua uses everything on offer.
--
-- The window around the view is the engine's: who is playing, whose turn it is, resigning, draw
-- offers, the list of moves and stepping back through them. A game opts into the last two with
-- `draws` and `history`, it doesn't build them.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- What a view is asked to show
--- @class GameView
--- @field match Match
--- @field state table The position to draw. Belongs to the engine: don't change it or keep it
--- @field seat number The local player's seat
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
--- @field icon string? Texture path, square
--- @field version number Bump when the rules or move format change, players on different versions can't play each other
--- @field seats number Number of players, only 2 is supported for now
--- @field newState fun(): table Fresh game state
--- @field turn fun(state: table): number Seat that moves next. It needn't be the other player's: a game where a player can be left without a move just says it is the same seat's turn again
--- @field validate fun(state: table, seat: number, move: string): boolean, string? Whether a move is legal, with an error code if not
--- @field apply fun(state: table, seat: number, move: string): table? Applies a legal move to the state. May return a table saying what happened, for the view to animate from: the engine hands it back as a MatchEvent. Set `notation` in it for the move list
--- @field result fun(state: table): { winner: number, detail: string? }? nil while in progress, winner 0 for a draw. detail names how it ended and is shown as L["result_" .. detail]
--- @field createView fun(stage: Frame): GameViewObject Builds the game's widgets inside stage. Called once, the first time one of its matches is looked at
--- @field draws boolean? Players may agree a draw
--- @field history boolean? Moves have a notation: show the move list and let players step back through the game
--- @field seatLabel (fun(seat: number): string)? Short label for a seat, e.g. "X"

--- @class Games
local Games = {}
private.Games = Games

--- @type table<string, GameDefinition>
local registry = {}
--- @type GameDefinition[]
local ordered = {}

local REQUIRED = { "newState", "turn", "validate", "apply", "result", "createView" }

--- @param definition GameDefinition
function Games.Register(definition)
  assert(private.Codec.IsSafeField(definition.id), "Game id must be alphanumeric")
  assert(not registry[definition.id], "Game already registered: " .. definition.id)
  assert(definition.seats == 2, "Only two player games are supported")
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
