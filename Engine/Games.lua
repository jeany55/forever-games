--------------------------
--  Game registry
--------------------------
-- A game is a table of pure functions plus a render function. To add a game, drop a file in
-- Games/, list it in the .toc and call private.Games.Register from it. See Games/TicTacToe.lua.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class GameView
--- @field match Match
--- @field state table Current game state
--- @field seat number The local player's seat
--- @field canMove boolean Whether the local player may move right now
--- @field submit fun(move: string) Plays a move for the local player

--- @class GameDefinition
--- @field id string Unique id sent over the wire, letters and digits only
--- @field name string Display name
--- @field version number Bump when the rules or move format change, players on different versions can't play each other
--- @field seats number Number of players, only 2 is supported for now
--- @field newState fun(): table Fresh game state
--- @field turn fun(state: table): number Seat that moves next
--- @field validate fun(state: table, seat: number, move: string): boolean, string? Whether a move is legal, with an error code if not
--- @field apply fun(state: table, seat: number, move: string) Applies a legal move to the state
--- @field result fun(state: table): { winner: number, detail: string? }? nil while in progress, winner 0 for a draw. detail names how it ended and is shown as L["result_" .. detail]
--- @field render fun(parent: Frame, view: GameView) Draws the state into parent. Called on every change, create widgets once and reuse them
--- @field seatLabel (fun(seat: number): string)? Short label for a seat, e.g. "X"

--- @class Games
local Games = {}
private.Games = Games

--- @type table<string, GameDefinition>
local registry = {}
--- @type GameDefinition[]
local ordered = {}

local REQUIRED = { "newState", "turn", "validate", "apply", "result", "render" }

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
