--------------------------
--  Realms
--------------------------
-- The tile-laying game of towns, roads, abbeys and fields, for two to five, drawn as Elwynn
-- Forest. Every turn a player lays the tile they drew next to the tiles already down, so that
-- every side of it matches the side it meets: town wall to town wall, road to road, field to
-- field. Then they may put one of their seven footmen on something of the tile they laid: the
-- town, a road, the abbey or a field. Nobody may put one on something that is joined to
-- something with a footman on it already, though two things that each have their own can be
-- joined later on by a tile between them.
--
-- A town is finished when its walls go all the way round, a road when both of its ends stop at a
-- town, an abbey, a village or another end of itself, and an abbey once there are tiles on all
-- eight sides of it. Whoever has the most footmen on it then scores it, all of them if it is a
-- tie, and the footmen go back to their owners: a town is worth 2 for each tile of it and 2 for
-- each banner, a road 1 for each tile and an abbey 9. Once the tiles run out what is left
-- unfinished scores half that for a town, the same for a road, and an abbey 1 for itself and 1
-- for every tile round it. Footmen in fields stay there until the end, when each field is worth
-- 3 for every finished town it touches to whoever has the most footmen in it.
--
-- The game starts with one tile down, a town with a road along its foot. A tile that can't be
-- laid anywhere is put aside and another drawn instead. Everybody sees which tile the player
-- whose turn it is drew, and how many of each sort are left to draw, but not which comes next:
-- it is drawn from the match's dice the moment it is needed.
--
-- A move is where the tile is laid and how far it is turned, and where the footman goes if one
-- does: "x.y.turn" or "x.y.turn.feature". x goes east and y south of the first tile, turn is
-- quarter turns clockwise from the way the tile is drawn, and feature is which of the tile's
-- things the footman stands on, numbered as in TILES.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Tables = private.Tables

-----------------------------
-- Tiles
-----------------------------
-- Every tile has twelve slots round its edge where what is on it meets what is on the next
-- tile: three to a side, clockwise from the west end of the north side. 0, 1 and 2 are the north
-- side from west to east, 3, 4 and 5 the east from north to south, 6, 7 and 8 the south from east
-- to west, and 9, 10 and 11 the west from south to north. A town takes all three slots of a side,
-- a road the middle one, a field whatever the rest of the side is. Turning a tile a quarter
-- clockwise moves each slot three on.
--
-- The things on a tile: a town (with a banner or not), a road, an abbey or a field, each with the
-- slots it reaches and where on the tile a footman on it stands, x right and y down from the top
-- left corner as fractions of the tile. A field also says which of the tile's towns it touches.
-- Tools/make_realms.py draws them from the same shapes.

local NORTH, EAST, SOUTH, WEST = 0, 1, 2, 3
-- What lies across each side, as a step east and south
local STEPS = { [0] = { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }
-- The eight tiles round one, for an abbey
local AROUND = { { -1, -1 }, { 0, -1 }, { 1, -1 }, { -1, 0 }, { 1, 0 }, { -1, 1 }, { 0, 1 }, { 1, 1 } }
local SLOTS = 12
-- How many features a tile may have at most, for numbering them all
local SPAN = 16
local FOOTMEN = 7
local START = "D"

--- @class RealmsFeature
--- @field kind "town"|"road"|"abbey"|"field"
--- @field slots number[]? Where it reaches the edge
--- @field banner boolean? A town with a banner, worth more
--- @field at number[] Where a footman on it stands
--- @field towns number[]? For a field: the towns of the tile it touches, by their number

--- @class RealmsTileKind
--- @field count number How many there are, the one that starts the game included
--- @field features RealmsFeature[]
--- @field village boolean? Roads meet in a village in the middle, and end there
--- @field edges string[]? What is on each side, "t", "r" or "f", from the north clockwise. Worked out
--- @field slotted number[]? Which feature is at each slot, by slot from 0. Worked out

--- @type table<string, RealmsTileKind>
local TILES = {
  -- An abbey with a road leading away south
  A = {
    count = 2,
    features = {
      { kind = "abbey", at = { 0.5, 0.42 } },
      { kind = "road", slots = { 7 }, at = { 0.5, 0.84 } },
      { kind = "field", slots = { 0, 1, 2, 3, 4, 5, 6, 8, 9, 10, 11 }, at = { 0.18, 0.2 } },
    },
  },
  -- An abbey in a field
  B = {
    count = 4,
    features = {
      { kind = "abbey", at = { 0.5, 0.45 } },
      { kind = "field", slots = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }, at = { 0.18, 0.2 } },
    },
  },
  -- Town all round, with a banner
  C = {
    count = 1,
    features = { { kind = "town", slots = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }, banner = true, at = { 0.5, 0.5 } } },
  },
  -- Town to the north, a road straight across under it: the tile the game starts with
  D = {
    count = 4,
    features = {
      { kind = "town", slots = { 0, 1, 2 }, at = { 0.5, 0.13 } },
      { kind = "road", slots = { 4, 10 }, at = { 0.72, 0.53 } },
      { kind = "field", slots = { 3, 11 }, at = { 0.24, 0.38 }, towns = { 1 } },
      { kind = "field", slots = { 5, 6, 7, 8, 9 }, at = { 0.5, 0.8 } },
    },
  },
  -- Town to the north
  E = {
    count = 5,
    features = {
      { kind = "town", slots = { 0, 1, 2 }, at = { 0.5, 0.13 } },
      { kind = "field", slots = { 3, 4, 5, 6, 7, 8, 9, 10, 11 }, at = { 0.5, 0.64 }, towns = { 1 } },
    },
  },
  -- Town across from west to east, with a banner
  F = {
    count = 2,
    features = {
      { kind = "town", slots = { 3, 4, 5, 9, 10, 11 }, banner = true, at = { 0.5, 0.5 } },
      { kind = "field", slots = { 0, 1, 2 }, at = { 0.5, 0.1 }, towns = { 1 } },
      { kind = "field", slots = { 6, 7, 8 }, at = { 0.5, 0.9 }, towns = { 1 } },
    },
  },
  -- Town across from north to south
  G = {
    count = 1,
    features = {
      { kind = "town", slots = { 0, 1, 2, 6, 7, 8 }, at = { 0.5, 0.5 } },
      { kind = "field", slots = { 3, 4, 5 }, at = { 0.9, 0.5 }, towns = { 1 } },
      { kind = "field", slots = { 9, 10, 11 }, at = { 0.1, 0.5 }, towns = { 1 } },
    },
  },
  -- Two towns, east and west, not joined
  H = {
    count = 3,
    features = {
      { kind = "town", slots = { 3, 4, 5 }, at = { 0.87, 0.5 } },
      { kind = "town", slots = { 9, 10, 11 }, at = { 0.13, 0.5 } },
      { kind = "field", slots = { 0, 1, 2, 6, 7, 8 }, at = { 0.5, 0.5 }, towns = { 1, 2 } },
    },
  },
  -- Two towns, north and east, not joined
  I = {
    count = 2,
    features = {
      { kind = "town", slots = { 0, 1, 2 }, at = { 0.42, 0.12 } },
      { kind = "town", slots = { 3, 4, 5 }, at = { 0.88, 0.58 } },
      { kind = "field", slots = { 6, 7, 8, 9, 10, 11 }, at = { 0.35, 0.62 }, towns = { 1, 2 } },
    },
  },
  -- Town to the north, a road bending from east to south
  J = {
    count = 3,
    features = {
      { kind = "town", slots = { 0, 1, 2 }, at = { 0.5, 0.13 } },
      { kind = "road", slots = { 4, 7 }, at = { 0.65, 0.65 } },
      { kind = "field", slots = { 5, 6 }, at = { 0.88, 0.88 } },
      { kind = "field", slots = { 3, 8, 9, 10, 11 }, at = { 0.26, 0.56 }, towns = { 1 } },
    },
  },
  -- Town to the north, a road bending from south to west
  K = {
    count = 3,
    features = {
      { kind = "town", slots = { 0, 1, 2 }, at = { 0.5, 0.13 } },
      { kind = "road", slots = { 7, 10 }, at = { 0.35, 0.65 } },
      { kind = "field", slots = { 8, 9 }, at = { 0.12, 0.88 } },
      { kind = "field", slots = { 3, 4, 5, 6, 11 }, at = { 0.74, 0.56 }, towns = { 1 } },
    },
  },
  -- Town to the north, roads east, south and west meeting in a village
  L = {
    count = 3,
    village = true,
    features = {
      { kind = "town", slots = { 0, 1, 2 }, at = { 0.5, 0.13 } },
      { kind = "road", slots = { 4 }, at = { 0.84, 0.55 } },
      { kind = "road", slots = { 7 }, at = { 0.5, 0.86 } },
      { kind = "road", slots = { 10 }, at = { 0.16, 0.55 } },
      { kind = "field", slots = { 3, 11 }, at = { 0.24, 0.38 }, towns = { 1 } },
      { kind = "field", slots = { 5, 6 }, at = { 0.84, 0.84 } },
      { kind = "field", slots = { 8, 9 }, at = { 0.16, 0.84 } },
    },
  },
  -- Town filling the north west corner, with a banner
  M = {
    count = 2,
    features = {
      { kind = "town", slots = { 0, 1, 2, 9, 10, 11 }, banner = true, at = { 0.28, 0.28 } },
      { kind = "field", slots = { 3, 4, 5, 6, 7, 8 }, at = { 0.7, 0.7 }, towns = { 1 } },
    },
  },
  -- Town filling the north west corner
  N = {
    count = 3,
    features = {
      { kind = "town", slots = { 0, 1, 2, 9, 10, 11 }, at = { 0.28, 0.28 } },
      { kind = "field", slots = { 3, 4, 5, 6, 7, 8 }, at = { 0.7, 0.7 }, towns = { 1 } },
    },
  },
  -- Town filling the north west corner with a banner, a road bending from east to south
  O = {
    count = 2,
    features = {
      { kind = "town", slots = { 0, 1, 2, 9, 10, 11 }, banner = true, at = { 0.27, 0.27 } },
      { kind = "road", slots = { 4, 7 }, at = { 0.65, 0.65 } },
      { kind = "field", slots = { 5, 6 }, at = { 0.88, 0.88 } },
      { kind = "field", slots = { 3, 8 }, at = { 0.84, 0.3 }, towns = { 1 } },
    },
  },
  -- Town filling the north west corner, a road bending from east to south
  P = {
    count = 3,
    features = {
      { kind = "town", slots = { 0, 1, 2, 9, 10, 11 }, at = { 0.27, 0.27 } },
      { kind = "road", slots = { 4, 7 }, at = { 0.65, 0.65 } },
      { kind = "field", slots = { 5, 6 }, at = { 0.88, 0.88 } },
      { kind = "field", slots = { 3, 8 }, at = { 0.84, 0.3 }, towns = { 1 } },
    },
  },
  -- Town on three sides with a banner, a field to the south
  Q = {
    count = 1,
    features = {
      { kind = "town", slots = { 0, 1, 2, 3, 4, 5, 9, 10, 11 }, banner = true, at = { 0.5, 0.38 } },
      { kind = "field", slots = { 6, 7, 8 }, at = { 0.5, 0.88 }, towns = { 1 } },
    },
  },
  -- Town on three sides, a field to the south
  R = {
    count = 3,
    features = {
      { kind = "town", slots = { 0, 1, 2, 3, 4, 5, 9, 10, 11 }, at = { 0.5, 0.38 } },
      { kind = "field", slots = { 6, 7, 8 }, at = { 0.5, 0.88 }, towns = { 1 } },
    },
  },
  -- Town on three sides with a banner, a road out of it to the south
  S = {
    count = 2,
    features = {
      { kind = "town", slots = { 0, 1, 2, 3, 4, 5, 9, 10, 11 }, banner = true, at = { 0.5, 0.36 } },
      { kind = "road", slots = { 7 }, at = { 0.5, 0.86 } },
      { kind = "field", slots = { 6 }, at = { 0.82, 0.88 }, towns = { 1 } },
      { kind = "field", slots = { 8 }, at = { 0.18, 0.88 }, towns = { 1 } },
    },
  },
  -- Town on three sides, a road out of it to the south
  T = {
    count = 1,
    features = {
      { kind = "town", slots = { 0, 1, 2, 3, 4, 5, 9, 10, 11 }, at = { 0.5, 0.36 } },
      { kind = "road", slots = { 7 }, at = { 0.5, 0.86 } },
      { kind = "field", slots = { 6 }, at = { 0.82, 0.88 }, towns = { 1 } },
      { kind = "field", slots = { 8 }, at = { 0.18, 0.88 }, towns = { 1 } },
    },
  },
  -- A road straight from north to south
  U = {
    count = 8,
    features = {
      { kind = "road", slots = { 1, 7 }, at = { 0.5, 0.5 } },
      { kind = "field", slots = { 2, 3, 4, 5, 6 }, at = { 0.8, 0.5 } },
      { kind = "field", slots = { 8, 9, 10, 11, 0 }, at = { 0.2, 0.5 } },
    },
  },
  -- A road bending from south to west
  V = {
    count = 9,
    features = {
      { kind = "road", slots = { 7, 10 }, at = { 0.35, 0.65 } },
      { kind = "field", slots = { 8, 9 }, at = { 0.12, 0.88 } },
      { kind = "field", slots = { 0, 1, 2, 3, 4, 5, 6, 11 }, at = { 0.68, 0.32 } },
    },
  },
  -- Roads east, south and west meeting in a village
  W = {
    count = 4,
    village = true,
    features = {
      { kind = "road", slots = { 4 }, at = { 0.84, 0.5 } },
      { kind = "road", slots = { 7 }, at = { 0.5, 0.84 } },
      { kind = "road", slots = { 10 }, at = { 0.16, 0.5 } },
      { kind = "field", slots = { 11, 0, 1, 2, 3 }, at = { 0.5, 0.18 } },
      { kind = "field", slots = { 5, 6 }, at = { 0.84, 0.84 } },
      { kind = "field", slots = { 8, 9 }, at = { 0.16, 0.84 } },
    },
  },
  -- Roads every way, meeting in a village
  X = {
    count = 1,
    village = true,
    features = {
      { kind = "road", slots = { 1 }, at = { 0.5, 0.16 } },
      { kind = "road", slots = { 4 }, at = { 0.84, 0.5 } },
      { kind = "road", slots = { 7 }, at = { 0.5, 0.84 } },
      { kind = "road", slots = { 10 }, at = { 0.16, 0.5 } },
      { kind = "field", slots = { 11, 0 }, at = { 0.16, 0.16 } },
      { kind = "field", slots = { 2, 3 }, at = { 0.84, 0.16 } },
      { kind = "field", slots = { 5, 6 }, at = { 0.84, 0.84 } },
      { kind = "field", slots = { 8, 9 }, at = { 0.16, 0.84 } },
    },
  },
}

-- The sorts in order, for anything that goes through them all
local KINDS = {}
for kind, tile in pairs(TILES) do
  KINDS[#KINDS + 1] = kind
  tile.slotted = {}
  for index, feature in ipairs(tile.features) do
    for _, slot in ipairs(feature.slots or {}) do
      tile.slotted[slot] = index
    end
  end
  -- What is on a side is what is at its middle slot
  tile.edges = {}
  for side = 0, 3 do
    local feature = tile.features[tile.slotted[side * 3 + 1]]
    tile.edges[side] = feature.kind == "town" and "t" or (feature.kind == "road" and "r" or "f")
  end
end
table.sort(KINDS)

--- The slot across the edge from one, on the tile next to it
--- @param slot number
--- @return number
local function across(slot)
  local side = math.floor(slot / 3)
  return ((side + 2) % 4) * 3 + (2 - slot % 3)
end

--- Which feature of a tile is at one of its slots, turned
--- @param kind string
--- @param turn number
--- @param slot number Where it is now
--- @return number
local function featureAt(kind, turn, slot)
  return TILES[kind].slotted[(slot - 3 * turn) % SLOTS]
end

--- What is on a side of a tile, turned: "t", "r" or "f"
--- @param kind string
--- @param turn number
--- @param side number
--- @return string
local function edgeOf(kind, turn, side)
  return TILES[kind].edges[(side - turn) % 4]
end

--- Where something on a tile is once it is turned
--- @param x number
--- @param y number
--- @param turn number
--- @return number, number
local function turnedPoint(x, y, turn)
  for _ = 1, turn % 4 do
    x, y = 1 - y, x
  end
  return x, y
end

--- @param x number
--- @param y number
--- @return number
local function keyOf(x, y)
  return (x + 128) * 256 + (y + 128)
end

-----------------------------
-- State
-----------------------------
-- Everything on the board that can be finished or scored is a group: what was a town on one
-- tile, joined to the town on the next and that one to another, is one town. Every feature of
-- every tile laid is numbered, tile * SPAN + feature, and belongs to the group of the first
-- feature of it that was laid, or that it was joined into when two groups met (`parent` leads
-- there). What there is to know about a group is kept with that one feature, in `groups`.

--- @class RealmsTile
--- @field kind string Which sort, a letter of TILES
--- @field x number East of the first tile
--- @field y number South of it
--- @field turn number Quarter turns clockwise

--- @class RealmsGroup
--- @field kind "town"|"road"|"abbey"|"field"
--- @field n number Features in it, for joining the smaller into the larger
--- @field tiles table<number, boolean> The tiles it is on
--- @field size number How many of them
--- @field banners number
--- @field open number Edges of a town or ends of a road that still lead nowhere, or the tiles still to come round an abbey
--- @field men table<number, number> Footmen on it, by seat
--- @field towns number[]? For a field: the features of the towns it touches
--- @field done boolean? Finished and scored

--- @class RealmsFootman
--- @field seat number
--- @field feature number Which feature it stands on, tile * SPAN + feature

--- @class RealmsState
--- @field seats number
--- @field turn number
--- @field tiles RealmsTile[] Every tile laid, in order
--- @field at table<number, number> Which tile is where, by keyOf
--- @field parent table<number, number> Where each feature that isn't the one its group is kept with leads
--- @field groups table<number, RealmsGroup>
--- @field bag string[] The tiles still to draw, in order of sort
--- @field tile string? The tile drawn for the player whose turn it is, nil once the game is over
--- @field men number[] Footmen each seat has left to put down
--- @field footmen RealmsFootman[] Every footman on the board
--- @field scores number[]
--- @field out table<number, boolean> Who resigned
--- @field fields boolean Footmen may go in fields
--- @field outcome { winner: number }?

--- What a group scored
--- @class RealmsScoring
--- @field kind string
--- @field group number The feature it is kept with
--- @field points number
--- @field seats number[] Who scored it, each the same
--- @field footmen RealmsFootman[] Those that stood on it, back to their owners
--- @field final boolean? Scored at the end, unfinished, or a field

--- @class RealmsEvent: MatchEvent
--- @field index number The tile laid
--- @field footman number? The feature a footman was put on, of the tile
--- @field scored RealmsScoring[] In the order they are to be shown
--- @field drawn string? The tile the next player drew
--- @field aside string[]? Tiles drawn that couldn't be laid anywhere, put aside
--- @field final boolean? The tiles ran out: the rest has been scored and the game is over

--- @param state RealmsState
--- @param feature number
--- @return number The feature its group is kept with
local function find(state, feature)
  local parent = state.parent
  while parent[feature] do
    feature = parent[feature]
  end
  return feature
end

--- The group a feature is in
--- @param state RealmsState
--- @param feature number
--- @return RealmsGroup, number
local function groupOf(state, feature)
  local root = find(state, feature)
  return state.groups[root], root
end

--- Joins two groups, the smaller into the larger
--- @param state RealmsState
--- @param a number A feature
--- @param b number Another
--- @return number Where the joined group is kept
local function join(state, a, b)
  a, b = find(state, a), find(state, b)
  if a == b then
    return a
  end
  local groups = state.groups
  if groups[a].n < groups[b].n or (groups[a].n == groups[b].n and a > b) then
    a, b = b, a
  end
  local into, from = groups[a], groups[b]
  into.n = into.n + from.n
  for tile in pairs(from.tiles) do
    if not into.tiles[tile] then
      into.tiles[tile] = true
      into.size = into.size + 1
    end
  end
  into.banners = into.banners + from.banners
  into.open = into.open + from.open
  for seat, count in pairs(from.men) do
    into.men[seat] = (into.men[seat] or 0) + count
  end
  if from.towns then
    for _, town in ipairs(from.towns) do
      into.towns[#into.towns + 1] = town
    end
  end
  state.parent[b] = a
  groups[b] = nil
  return a
end

--- How many sides a feature of a tile reaches, for a town, or ends it has, for a road
--- @param feature RealmsFeature
--- @return number
local function endsOf(feature)
  local slots = feature.slots or {}
  if feature.kind == "road" then
    return #slots
  end
  local sides = {}
  local count = 0
  for _, slot in ipairs(slots) do
    local side = math.floor(slot / 3)
    if not sides[side] then
      sides[side], count = true, count + 1
    end
  end
  return count
end

--- Whether a tile could be laid somewhere, turned some way: on nothing, next to something, and
--- matching every side it meets
--- @param state RealmsState
--- @param kind string
--- @param x number
--- @param y number
--- @param turn number
--- @return boolean
local function fits(state, kind, x, y, turn)
  local at = state.at
  if at[keyOf(x, y)] then
    return false
  end
  local touching = false
  for side = 0, 3 do
    local step = STEPS[side]
    local other = at[keyOf(x + step[1], y + step[2])]
    if other then
      touching = true
      local tile = state.tiles[other]
      if edgeOf(kind, turn, side) ~= edgeOf(tile.kind, tile.turn, (side + 2) % 4) then
        return false
      end
    end
  end
  return touching
end

--- Every empty square next to a tile, from the north west, row by row
--- @param state RealmsState
--- @return { x: number, y: number }[]
local function frontier(state)
  local spots, seen = {}, {}
  for _, tile in ipairs(state.tiles) do
    for side = 0, 3 do
      local x, y = tile.x + STEPS[side][1], tile.y + STEPS[side][2]
      local key = keyOf(x, y)
      if not state.at[key] and not seen[key] then
        seen[key] = true
        spots[#spots + 1] = { x = x, y = y }
      end
    end
  end
  table.sort(spots, function(a, b)
    if a.y ~= b.y then
      return a.y < b.y
    end
    return a.x < b.x
  end)
  return spots
end

--- Every way a tile could be laid: where, and turned how far
--- @param state RealmsState
--- @param kind string
--- @return { x: number, y: number, turn: number }[]
local function placings(state, kind)
  local list = {}
  for _, spot in ipairs(frontier(state)) do
    for turn = 0, 3 do
      if fits(state, kind, spot.x, spot.y, turn) then
        list[#list + 1] = { x = spot.x, y = spot.y, turn = turn }
      end
    end
  end
  return list
end

--- Whether a tile can be laid anywhere at all
--- @param state RealmsState
--- @param kind string
--- @return boolean
local function layable(state, kind)
  for _, spot in ipairs(frontier(state)) do
    for turn = 0, 3 do
      if fits(state, kind, spot.x, spot.y, turn) then
        return true
      end
    end
  end
  return false
end

--- What a tile laid somewhere would join each of its features to, without laying it: which of
--- them would end up in the same group, and whether that group has footmen on it
--- @param state RealmsState
--- @param kind string
--- @param x number
--- @param y number
--- @param turn number
--- @return { feature: number, groups: number[], taken: boolean, open: number, size: number, banners: number, men: table<number, number> }[] By feature of the tile
local function preview(state, kind, x, y, turn)
  local tile = TILES[kind]
  local count = #tile.features
  -- A small set of groups of its own: the tile's features first, then the groups they meet
  local links, joined = {}, {}
  local function top(node)
    while links[node] do
      node = links[node]
    end
    return node
  end
  local function link(a, b)
    a, b = top(a), top(b)
    if a ~= b then
      links[b] = a
    end
  end
  local closed = {}
  for side = 0, 3 do
    local step = STEPS[side]
    local index = state.at[keyOf(x + step[1], y + step[2])]
    if index then
      local other = state.tiles[index]
      for place = 0, 2 do
        local slot = side * 3 + place
        local mine = featureAt(kind, turn, slot)
        local theirs = find(state, index * SPAN + featureAt(other.kind, other.turn, across(slot)))
        joined[theirs] = true
        link(mine, -theirs)
        if place == 1 and tile.features[mine].kind ~= "field" then
          closed[mine] = (closed[mine] or 0) + 2
        end
      end
    end
  end
  -- Gathered by the group each feature ends up in
  local result, sums = {}, {}
  for feature = 1, count do
    local root = top(feature)
    local sum = sums[root]
    if not sum then
      sum = { open = 0, size = 1, banners = 0, men = {}, groups = {}, tiles = {} }
      sums[root] = sum
    end
    local spec = tile.features[feature]
    sum.open = sum.open + endsOf(spec) - (closed[feature] or 0)
    sum.banners = sum.banners + (spec.banner and 1 or 0)
  end
  for group in pairs(joined) do
    local sum = sums[top(-group)]
    if sum then
      local data = state.groups[group]
      sum.groups[#sum.groups + 1] = group
      sum.open = sum.open + data.open
      sum.banners = sum.banners + data.banners
      for seat, men in pairs(data.men) do
        sum.men[seat] = (sum.men[seat] or 0) + men
      end
      for index in pairs(data.tiles) do
        if not sum.tiles[index] then
          sum.tiles[index] = true
          sum.size = sum.size + 1
        end
      end
    end
  end
  for feature = 1, count do
    local sum = sums[top(feature)]
    local taken = false
    for _, men in pairs(sum.men) do
      taken = taken or men > 0
    end
    table.sort(sum.groups)
    result[feature] = { feature = feature, groups = sum.groups, taken = taken, open = sum.open, size = sum.size, banners = sum.banners, men = sum.men }
  end
  -- An abbey is open on every side that has no tile yet
  for feature, spec in ipairs(tile.features) do
    if spec.kind == "abbey" then
      local open = 8
      for _, step in ipairs(AROUND) do
        if state.at[keyOf(x + step[1], y + step[2])] then
          open = open - 1
        end
      end
      result[feature].open = open
    end
  end
  return result
end

--- Who has the most footmen on a group, all of them where it is a tie. Nobody if it has none
--- @param group RealmsGroup
--- @param seats number
--- @return number[]
local function majority(group, seats)
  local most, list = 0, {}
  for seat = 1, seats do
    local men = group.men[seat] or 0
    if men > most then
      most, list = men, { seat }
    elseif men == most and men > 0 then
      list[#list + 1] = seat
    end
  end
  return list
end

--- What a group is worth: finished, or as it stands at the end
--- @param state RealmsState
--- @param group RealmsGroup
--- @param final boolean? The game is over, and it may not be finished
--- @return number
local function worth(state, group, final)
  local kind = group.kind
  if kind == "town" then
    local each = (final and group.open > 0) and 1 or 2
    return each * (group.size + group.banners)
  elseif kind == "road" then
    return group.size
  elseif kind == "abbey" then
    return 9 - group.open
  end
  -- A field: 3 for every finished town it touches, each town once
  local seen, count = {}, 0
  for _, town in ipairs(group.towns) do
    local root = find(state, town)
    if not seen[root] and state.groups[root].done then
      seen[root], count = true, count + 1
    end
  end
  return 3 * count
end

--- Scores a group for whoever has the most footmen on it, and sends every footman on it home
--- @param state RealmsState
--- @param root number Where the group is kept
--- @param final boolean?
--- @return RealmsScoring
local function score(state, root, final)
  local group = state.groups[root]
  local points = worth(state, group, final)
  local seats = majority(group, state.seats)
  for _, seat in ipairs(seats) do
    state.scores[seat] = state.scores[seat] + points
  end
  local home, kept = {}, {}
  for _, footman in ipairs(state.footmen) do
    if find(state, footman.feature) == root then
      home[#home + 1] = footman
      state.men[footman.seat] = state.men[footman.seat] + 1
    else
      kept[#kept + 1] = footman
    end
  end
  state.footmen = kept
  group.men = {}
  return { kind = group.kind, group = root, points = points, seats = seats, footmen = home, final = final or nil }
end

--- The seat after one, past whoever resigned
--- @param state RealmsState
--- @param seat number
--- @return number
local function after(state, seat)
  for _ = 1, state.seats do
    seat = seat % state.seats + 1
    if not state.out[seat] then
      return seat
    end
  end
  return seat
end

--- Scores whatever is left once the tiles run out: what isn't finished, then the fields, and
--- says who won
--- @param state RealmsState
--- @return RealmsScoring[]
local function finish(state)
  state.tile = nil
  local list = {}
  -- Groups in the order they were begun, the fields after everything else
  local roots = {}
  for root, group in pairs(state.groups) do
    if not group.done and next(group.men) then
      roots[#roots + 1] = root
    end
  end
  table.sort(roots, function(a, b)
    local fieldA, fieldB = state.groups[a].kind == "field", state.groups[b].kind == "field"
    if fieldA ~= fieldB then
      return fieldB
    end
    return a < b
  end)
  for _, root in ipairs(roots) do
    local scoring = score(state, root, true)
    list[#list + 1] = scoring
  end
  local winner, best = 0, nil
  for seat = 1, state.seats do
    if not state.out[seat] then
      local points = state.scores[seat]
      if best == nil or points > best then
        winner, best = seat, points
      elseif points == best then
        winner = 0
      end
    end
  end
  state.outcome = { winner = winner }
  return list
end

--- Draws the next tile from the bag, putting aside any that can't be laid anywhere
--- @param state RealmsState
--- @param random Random
--- @return string[] Those put aside
local function draw(state, random)
  local aside = {}
  state.tile = nil
  while #state.bag > 0 do
    local kind = table.remove(state.bag, random:Roll(#state.bag))
    if layable(state, kind) then
      state.tile = kind
      return aside
    end
    aside[#aside + 1] = kind
  end
  return aside
end

--- Lays a tile, joining what is on it to what it meets
--- @param state RealmsState
--- @param kind string
--- @param x number
--- @param y number
--- @param turn number
--- @return number The tile's number
local function lay(state, kind, x, y, turn)
  local index = #state.tiles + 1
  state.tiles[index] = { kind = kind, x = x, y = y, turn = turn }
  state.at[keyOf(x, y)] = index
  local tile = TILES[kind]
  for feature, spec in ipairs(tile.features) do
    local towns = nil
    if spec.kind == "field" then
      towns = {}
      for _, town in ipairs(spec.towns or {}) do
        towns[#towns + 1] = index * SPAN + town
      end
    end
    state.groups[index * SPAN + feature] = {
      kind = spec.kind,
      n = 1,
      tiles = { [index] = true },
      size = 1,
      banners = spec.banner and 1 or 0,
      open = endsOf(spec),
      men = {},
      towns = towns,
    }
  end
  for side = 0, 3 do
    local step = STEPS[side]
    local other = state.at[keyOf(x + step[1], y + step[2])]
    if other then
      local neighbour = state.tiles[other]
      for place = 0, 2 do
        local slot = side * 3 + place
        local mine = featureAt(kind, turn, slot)
        local root = join(state, index * SPAN + mine, other * SPAN + featureAt(neighbour.kind, neighbour.turn, across(slot)))
        -- Both ends of the edge are closed now: the one on this tile, and the one it met
        if place == 1 and tile.features[mine].kind ~= "field" then
          state.groups[root].open = state.groups[root].open - 2
        end
      end
    end
  end
  -- Abbeys: this one counts the tiles round it, those round it count this one
  for feature, spec in ipairs(tile.features) do
    if spec.kind == "abbey" then
      state.groups[index * SPAN + feature].open = 8
    end
  end
  for _, step in ipairs(AROUND) do
    local other = state.at[keyOf(x + step[1], y + step[2])]
    if other then
      for _, abbey in ipairs({ index, other }) do
        local placed = state.tiles[abbey]
        for feature, spec in ipairs(TILES[placed.kind].features) do
          if spec.kind == "abbey" then
            local group = state.groups[abbey * SPAN + feature]
            group.open = group.open - 1
          end
        end
      end
    end
  end
  return index
end

--- @param seats number
--- @param random Random
--- @param rules table<string, any>
--- @return RealmsState
local function newState(seats, random, rules)
  --- @type RealmsState
  local state = {
    seats = seats,
    turn = 1,
    tiles = {},
    at = {},
    parent = {},
    groups = {},
    bag = {},
    men = {},
    footmen = {},
    scores = {},
    out = {},
    fields = rules.fields ~= false,
  }
  for seat = 1, seats do
    state.men[seat], state.scores[seat] = FOOTMEN, 0
  end
  for _, kind in ipairs(KINDS) do
    for _ = 1, TILES[kind].count - (kind == START and 1 or 0) do
      state.bag[#state.bag + 1] = kind
    end
  end
  lay(state, START, 0, 0, 0)
  draw(state, random)
  return state
end

--- A move taken apart, nil if it isn't one
--- @param move string
--- @return number? x, number? y, number? turn, number? feature
local function parse(move)
  local x, y, turn, feature = move:match("^(%-?%d+)%.(%-?%d+)%.([0-3])$")
  if not x then
    x, y, turn, feature = move:match("^(%-?%d+)%.(%-?%d+)%.([0-3])%.([1-9])$")
  end
  if not x or x == "-0" or y == "-0" or tostring(tonumber(x)) ~= x or tostring(tonumber(y)) ~= y then
    return nil
  end
  return tonumber(x), tonumber(y), tonumber(turn), feature and tonumber(feature)
end

--- @param x number
--- @param y number
--- @param turn number
--- @param feature number?
--- @return string
local function moveOf(x, y, turn, feature)
  return x .. "." .. y .. "." .. turn .. (feature and ("." .. feature) or "")
end

--- @param state RealmsState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  local x, y, turn, feature = parse(move)
  if not x then
    return false, "invalid_move"
  end
  if seat ~= state.turn or not state.tile then
    return false, "not_your_turn"
  end
  local kind = state.tile
  if not fits(state, kind, x, y, turn) then
    return false, "realms_no_fit"
  end
  if feature then
    local spec = TILES[kind].features[feature]
    if not spec then
      return false, "invalid_move"
    end
    if spec.kind == "field" and not state.fields then
      return false, "realms_no_fields"
    end
    if state.men[seat] <= 0 then
      return false, "realms_no_footmen"
    end
    if preview(state, kind, x, y, turn)[feature].taken then
      return false, "realms_taken"
    end
  end
  return true
end

--- Lays the tile and puts the footman down, and scores whatever that finished. Draws nothing
--- @param state RealmsState
--- @param seat number
--- @param move string
--- @return RealmsEvent
local function play(state, seat, move)
  local x, y, turn, feature = parse(move)
  --- @cast x number
  --- @cast y number
  --- @cast turn number
  local kind = state.tile
  --- @cast kind string
  local index = lay(state, kind, x, y, turn)
  if feature then
    local group = groupOf(state, index * SPAN + feature)
    group.men[seat] = (group.men[seat] or 0) + 1
    state.men[seat] = state.men[seat] - 1
    state.footmen[#state.footmen + 1] = { seat = seat, feature = index * SPAN + feature }
  end

  -- Whatever the tile finished: its towns and roads, and any abbey it or one round it has
  local scored, seen = {}, {}
  local candidates = {}
  for number, spec in ipairs(TILES[kind].features) do
    if spec.kind ~= "field" then
      candidates[#candidates + 1] = find(state, index * SPAN + number)
    end
  end
  for _, step in ipairs(AROUND) do
    local other = state.at[keyOf(x + step[1], y + step[2])]
    if other then
      for number, spec in ipairs(TILES[state.tiles[other].kind].features) do
        if spec.kind == "abbey" then
          candidates[#candidates + 1] = other * SPAN + number
        end
      end
    end
  end
  for _, root in ipairs(candidates) do
    local group = state.groups[root]
    if not seen[root] and group.open == 0 and not group.done then
      seen[root] = true
      group.done = true
      if next(group.men) then
        scored[#scored + 1] = score(state, root)
      end
    end
  end

  local notation = kind .. " " .. x .. "," .. y
  if feature then
    notation = notation .. " " .. L["realms_notation_" .. TILES[kind].features[feature].kind]
  end
  return { index = index, footman = feature, scored = scored, notation = notation }
end

--- @param state RealmsState
--- @param seat number
--- @param move string
--- @param random Random
--- @return RealmsEvent
local function apply(state, seat, move, random)
  local event = play(state, seat, move)
  local aside = draw(state, random)
  event.aside = #aside > 0 and aside or nil
  if state.tile then
    event.drawn = state.tile
    state.turn = after(state, seat)
  else
    event.final = true
    for _, scoring in ipairs(finish(state)) do
      event.scored[#event.scored + 1] = scoring
    end
  end
  return event
end

--- Every way the seat could lay the tile, with each footman it could put down on it
--- @param state RealmsState
--- @param seat number
--- @return string[]
local function moves(state, seat)
  local list = {}
  local kind = state.tile
  if not kind or seat ~= state.turn then
    return list
  end
  local features = TILES[kind].features
  for _, place in ipairs(placings(state, kind)) do
    list[#list + 1] = moveOf(place.x, place.y, place.turn)
    if state.men[seat] > 0 then
      for feature, outlook in ipairs(preview(state, kind, place.x, place.y, place.turn)) do
        if not outlook.taken and (state.fields or features[feature].kind ~= "field") then
          list[#list + 1] = moveOf(place.x, place.y, place.turn, feature)
        end
      end
    end
  end
  return list
end

--- A player resigned: their footmen leave the board, and they are never asked to move again
--- @param state RealmsState
--- @param seat number
local function drop(state, seat)
  state.out[seat] = true
  local kept = {}
  for _, footman in ipairs(state.footmen) do
    if footman.seat == seat then
      local group = groupOf(state, footman.feature)
      group.men[seat] = group.men[seat] - 1
      if group.men[seat] == 0 then
        group.men[seat] = nil
      end
    else
      kept[#kept + 1] = footman
    end
  end
  state.footmen = kept
  if state.turn == seat then
    state.turn = after(state, seat)
  end
end

--- How many of each sort of tile are left to draw
--- @param state RealmsState
--- @return table<string, number>
local function left(state)
  local counts = {}
  for _, kind in ipairs(state.bag) do
    counts[kind] = (counts[kind] or 0) + 1
  end
  return counts
end

-----------------------------
-- The computer
-----------------------------
-- It plays every way it could lay its tile, with and without each footman it could put down,
-- on a copy of the board, and judges what that leaves: what everybody has scored, and what each
-- thing with footmen on it can be expected to bring its owners by the end. A town that needs
-- many more tiles to close, late in the game, may well never be finished; an abbey early on will
-- likely be surrounded. A footman still in hand is worth something too, more while there are
-- many tiles to come. The move it picks is the one that leaves it best off against the others:
-- half against whoever is doing best of them, half against the rest on average.
--
-- It doesn't look further ahead than its own move: which tile comes next is up to the dice.

-- How it weighs things up, in a table of its own for Tools/RealmsBench.lua to try others with:
-- how likely a town is to be closed, for each edge it still has open, is about tiles left over
-- tiles left and `close`. The same for an abbey getting one more tile round it and `fill`. What
-- every open edge of a town or end of a road may yet add to it early on, `growth`. What a footman
-- in hand is worth at the start, `hand`, and how much more each is worth once there are `few`
-- left, `last`. How much of what it weighs itself against is whoever is doing best, `leader`,
-- the rest is all the others on average. How much what the others stand to gain counts at all,
-- `others`, and what a field is thought to be worth, `farms`, are less than all for a beginner,
-- who sees only what a move does for themselves, doesn't see what a field is for, and puts
-- footmen down freely (COMPUTER.levels)
local TUNING = { close = 30, fill = 8, growth = 1.2, hand = 6, last = 3, few = 2, leader = 0.5, others = 1, farms = 1 }
-- How far apart scores that are to be thought of as the same are
local TIE = 1e-6

--- A copy to play a move on, quicker than the engine's: the tiles laid are never changed, and
--- are shared
--- @param state RealmsState
--- @return RealmsState
local function copy(state)
  local groups = {}
  for root, group in pairs(state.groups) do
    local tiles, men = {}, {}
    for index in pairs(group.tiles) do
      tiles[index] = true
    end
    for seat, count in pairs(group.men) do
      men[seat] = count
    end
    groups[root] = {
      kind = group.kind,
      n = group.n,
      tiles = tiles,
      size = group.size,
      banners = group.banners,
      open = group.open,
      men = men,
      towns = group.towns and { unpack(group.towns) },
      done = group.done,
    }
  end
  local at, parent = {}, {}
  for key, index in pairs(state.at) do
    at[key] = index
  end
  for feature, up in pairs(state.parent) do
    parent[feature] = up
  end
  return {
    seats = state.seats,
    turn = state.turn,
    tiles = { unpack(state.tiles) },
    at = at,
    parent = parent,
    groups = groups,
    bag = { unpack(state.bag) },
    tile = state.tile,
    men = { unpack(state.men) },
    footmen = { unpack(state.footmen) },
    scores = { unpack(state.scores) },
    out = Tables.Shallow(state.out),
    fields = state.fields,
    outcome = state.outcome,
  }
end

--- How likely a town with so many edges open is to be closed
--- @param open number
--- @param tiles number Left to draw
--- @param weights table TUNING, or a level's own
--- @return number
local function closing(open, tiles, weights)
  if open == 0 then
    return 1
  end
  return (tiles / (tiles + weights.close)) ^ open
end

--- What a group can be expected to bring whoever has the most footmen on it, by the end
--- @param state RealmsState
--- @param group RealmsGroup
--- @param tiles number Left to draw
--- @param weights table
--- @return number
local function expected(state, group, tiles, weights)
  local kind, open = group.kind, group.open
  local early = tiles / (#state.tiles + tiles)
  if kind == "town" then
    local chance = closing(open, tiles, weights)
    local base = group.size + group.banners
    return chance * 2 * base + (1 - chance) * base + open * weights.growth * early * (1 + chance)
  elseif kind == "road" then
    return group.size + open * weights.growth * early / 2
  elseif kind == "abbey" then
    return 9 - open + open * tiles / (tiles + weights.fill)
  end
  local seen, value = {}, 0
  for _, town in ipairs(group.towns) do
    local root = find(state, town)
    if not seen[root] then
      seen[root] = true
      local data = state.groups[root]
      value = value + 3 * (data.done and 1 or closing(data.open, tiles, weights))
    end
  end
  return value * weights.farms
end

--- How well off every seat is: scored, to come, and in hand
--- @param state RealmsState
--- @param weights table?
--- @return number[]
local function standings(state, weights)
  weights = weights or TUNING
  local tiles = #state.bag
  local values = {}
  for seat = 1, state.seats do
    local men = state.men[seat]
    local hand = weights.hand * tiles / (#state.tiles + tiles)
    values[seat] = state.scores[seat] + men * hand + (men <= weights.few and weights.last * tiles / (tiles + weights.close) or 0)
  end
  local roots = {}
  for root, group in pairs(state.groups) do
    if not group.done and next(group.men) then
      roots[#roots + 1] = root
    end
  end
  table.sort(roots)
  for _, root in ipairs(roots) do
    local group = state.groups[root]
    local value = expected(state, group, tiles, weights)
    for _, seat in ipairs(majority(group, state.seats)) do
      values[seat] = values[seat] + value
    end
  end
  return values
end

--- How good a position is for a seat, against the others
--- @param state RealmsState
--- @param seat number
--- @param weights table?
--- @return number
local function judge(state, seat, weights)
  weights = weights or TUNING
  local values = standings(state, weights)
  local best, sum, count = nil, 0, 0
  for other = 1, state.seats do
    if other ~= seat and not state.out[other] then
      best = math.max(best or values[other], values[other])
      sum, count = sum + values[other], count + 1
    end
  end
  if count == 0 then
    return values[seat]
  end
  return values[seat] - weights.others * (weights.leader * best + (1 - weights.leader) * sum / count)
end

--- @param seen RealmsState
--- @param seat number
--- @param brain Brain
--- @return string
local function think(seen, seat, brain)
  local weights = TUNING
  if brain.level.weights then
    weights = setmetatable(brain.level.weights, { __index = TUNING })
  end
  local scored = {}
  for _, move in ipairs(moves(seen, seat)) do
    local after = copy(seen)
    play(after, seat, move)
    scored[#scored + 1] = { move = move, score = judge(after, seat, weights), rank = 0 }
    brain:Spend()
  end
  table.sort(scored, function(a, b)
    if math.abs(a.score - b.score) > TIE then
      return a.score > b.score
    end
    return a.move < b.move
  end)
  return brain:Pick(scored).move
end

-- Measured with Tools/RealmsBench.lua over 100 games of two: hard beats medium 77 times, medium
-- beats easy 85 and hard beats easy 98. They score about 95, 83 and 62 a game. Easy is a
-- beginner: it slips often, and among the moves it slips into are some it thinks little of
local COMPUTER = {
  think = think,
  copy = copy,
  evaluate = judge,
  -- Another go would be another draw
  takeback = false,
  levels = {
    easy = { slip = 0.7, among = 10, weights = { others = 0, farms = 0, hand = 1, close = 8, growth = 0 } },
    medium = { slip = 0.35, among = 4, weights = { others = 0.5, hand = 3 } },
    hard = { slip = 0 },
  },
}

-----------------------------
-- View
-----------------------------
-- The map in a window that zooms and can be dragged about (GUI/Viewport.lua), and a panel at
-- its right: everyone's score and the footmen they have left, the tile drawn and how many are
-- left to draw, and what the player is about.
--
-- On the player's turn the squares their tile fits on glow. Pointing at one shows the tile there,
-- turned the first way it fits, and right-clicking or R turns it on to the next. Clicking lays it
-- there for now: the spots on it that could take a footman light up, and clicking one puts a
-- footman there, or takes it off again. Done, or Enter, sends the move. Escape, or Take back,
-- picks the tile up again, and clicking another square that glows moves it there.
--
-- A move is shown being made: the tile dropped into place, the footman set down, and whatever
-- that finished lit up in the colour of whoever scored it, with what they scored rising off it,
-- and the footmen on it leaving for home. At the end of the game everything that is left is
-- scored that way, one after the other.

local IMAGES = "Interface\\AddOns\\ForeverGames\\Images\\Realms\\"
local FLAT = "Interface\\Buttons\\WHITE8X8"
-- Each seat's colour, for its footmen and its name
local SEAT_COLORS = { { 0.3, 0.58, 1 }, { 0.95, 0.27, 0.22 }, { 0.32, 0.82, 0.3 }, { 1, 0.82, 0.18 }, { 0.76, 0.44, 1 } }
local MAP_BACK = { 0.07, 0.09, 0.06, 1 }
-- The panel: its width as a share of the stage, within these
local PANEL_SHARE, PANEL_MIN, PANEL_MAX = 0.27, 190, 250
local GAP = 8
local PLATE_HEIGHT, PLATE_GAP = 42, 3
local PLATE, PLATE_TURN = { 0, 0, 0, 0.35 }, { 1, 0.82, 0, 0.12 }
local BUTTON_HEIGHT = 24
-- A square at its biggest when the map all fits, and as big as zooming in may make one
local MOST_FITTED, MOST_ZOOMED = 88, 160
-- Squares of room round the tiles: the ones that could be laid on next, and a little more
local ROOM = 1.25
-- How big a footman, the ring round a spot that could take one, and a tile's shadow are, as
-- shares of a square
local FOOTMAN, SPOT, SHADOW_OFFSET = 0.42, 0.34, 0.035
-- How much bigger than its square a tile is drawn, so that no sliver of what is under it shows
-- between two tiles where their edges fall between pixels: a share of a square, and at least this
-- much of the map
local OVERLAP, LEAST_OVERLAP = 0.008, 0.6
-- The light on a square the tile fits on, the one pointed at, and round the tile laid for now
local FITS, POINTED, LAID = { 1, 0.82, 0.3, 0.55 }, { 1, 0.9, 0.5, 0.9 }, { 1, 0.9, 0.5, 1 }
-- The tile pointed at but not yet laid
local GHOST_ALPHA = 0.72
-- Seconds: a tile dropping into place, a footman being set down, a scoring being shown, the
-- time between scorings, and how long something scored stays lit
local DROP, SET, SCORE_AFTER, SCORE_EACH, LIT = 0.28, 0.22, 0.4, 0.75, 0.9
local GOLD = { 1, 0.82, 0 }
local GREY = { 0.65, 0.65, 0.65 }

--- The colour of a seat
--- @param seat number
--- @return number[]
local function colorOf(seat)
  return SEAT_COLORS[(seat - 1) % #SEAT_COLORS + 1]
end

--- A colour as the client writes it in text, "|cffrrggbb"
--- @param color number[]
--- @return string
local function textColor(color)
  return string.format("|cff%02x%02x%02x", color[1] * 255, color[2] * 255, color[3] * 255)
end

--- Turns a texture a number of quarter turns clockwise
--- @param texture Texture
--- @param turn number
local function turnTexture(texture, turn)
  -- The texture's corners clockwise from the top left, and which of them shows at each corner
  -- of the square once it is turned
  local corners = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } }
  local function at(place)
    return corners[(place - turn) % 4 + 1]
  end
  local topLeft, topRight, bottomRight, bottomLeft = at(0), at(1), at(2), at(3)
  texture:SetTexCoord(topLeft[1], topLeft[2], bottomLeft[1], bottomLeft[2], topRight[1], topRight[2], bottomRight[1], bottomRight[2])
end

--- What a group finished now would score, or scores as it stands at the end
--- @param kind string
--- @param size number
--- @param banners number
--- @param open number
--- @return number
local function pointsOf(kind, size, banners, open)
  if kind == "town" then
    return (open == 0 and 2 or 1) * (size + banners)
  elseif kind == "road" then
    return size
  elseif kind == "abbey" then
    return 9 - open
  end
  return 0
end

--- @class RealmsView: GameViewObject
--- @field stage Frame
--- @field viewport Viewport
--- @field map Frame What is zoomed
--- @field cell number A square's side on the map, before zooming
--- @field origin { x: number, y: number } The square at the map's top left corner, in squares, and a bit
--- @field size { columns: number, rows: number }
--- @field tiles Texture[] By tile laid
--- @field shadows Texture[]
--- @field footmen Texture[] Pool
--- @field marks Texture[] Pool, the squares that glow
--- @field spots Texture[] Pool, the rings round spots that could take a footman
--- @field ghost Texture The tile pointed at, or laid for now
--- @field outline Texture The light round it
--- @field held Texture The footman put on it for now
--- @field lit Texture[] Pool, what lights up something scored
--- @field animator table
--- @field effects Effects
--- @field panel Frame
--- @field plates Frame[]
--- @field drawn Texture The tile drawn, in the panel
--- @field view GameView?
--- @field ply number? The position last laid out
--- @field fitting table<number, number[]>? Where the tile fits and which ways round, by keyOf
--- @field pointed { x: number, y: number }? The square pointed at
--- @field turns table<number, number> Which way round the player last had the tile on each square, by keyOf
--- @field placed { x: number, y: number, turn: number, footman: number? }? Laid for now
--- @field outlook table? What preview says of the tile laid for now
--- @field hovered number? The spot pointed at, of the tile laid for now
local View = {}
View.__index = View

--- @param stage Frame
--- @return RealmsView
local function createView(stage)
  local Widgets = private.Widgets
  --- @type RealmsView
  local self = setmetatable({ stage = stage, cell = 1, origin = { x = 0, y = 0 }, size = { columns = 1, rows = 1 } }, View)
  self.tiles, self.shadows, self.footmen, self.marks, self.spots, self.lit = {}, {}, {}, {}, {}, {}
  self.turns = {}

  self.viewport = private.Viewport.New(stage, {
    maxZoom = 3,
    -- Whole map is for when it isn't all in sight
    onSettle = function()
      if self.view then
        self:showPanel()
      end
    end,
  })
  local back = self.viewport.frame:CreateTexture(nil, "BACKGROUND")
  back:SetAllPoints()
  back:SetColorTexture(unpack(MAP_BACK))
  local map = self.viewport.content
  map:EnableMouse(true)
  self.map = map
  -- Layers, so that nothing on one is ever drawn under what is on the one below
  local function layer(above)
    local frame = CreateFrame("Frame", nil, map)
    frame:SetAllPoints()
    frame:SetFrameLevel(map:GetFrameLevel() + above)
    return frame
  end
  self.tileLayer, self.markLayer, self.footLayer, self.topLayer = layer(1), layer(2), layer(3), layer(4)
  self.ghost = self.markLayer:CreateTexture(nil, "ARTWORK")
  self.ghost:Hide()
  self.outline = self.markLayer:CreateTexture(nil, "OVERLAY")
  self.outline:SetTexture(IMAGES .. "square")
  self.outline:SetBlendMode("ADD")
  self.outline:Hide()
  self.held = self.topLayer:CreateTexture(nil, "OVERLAY")
  self.held:SetTexture(IMAGES .. "footman")
  self.held:Hide()

  map:SetScript("OnMouseDown", function(_, button)
    self:mapDown(button)
  end)
  map:SetScript("OnMouseUp", function(_, button)
    self:mapUp(button)
  end)
  map:SetScript("OnUpdate", function()
    self:watch()
  end)
  map:SetScript("OnHide", function()
    self.pointed, self.hovered = nil, nil
    GameTooltip_Hide()
  end)
  Widgets.Keys(self.viewport.frame, function(key)
    return self:key(key)
  end)

  self:buildPanel()

  self.effects = private.Effects.New(stage)
  local over = CreateFrame("Frame", nil, stage)
  self.animator = Widgets.Animator(over)
  return self
end

function View:buildPanel()
  local Widgets = private.Widgets
  local panel = CreateFrame("Frame", nil, self.stage)
  self.panel = panel
  self.plates = {}
  for seat = 1, #SEAT_COLORS do
    local plate = CreateFrame("Frame", nil, panel)
    plate:SetHeight(PLATE_HEIGHT)
    plate.back = plate:CreateTexture(nil, "BACKGROUND")
    plate.back:SetAllPoints()
    plate.mark = plate:CreateTexture(nil, "BORDER")
    plate.mark:SetColorTexture(unpack(GOLD))
    plate.mark:SetPoint("TOPLEFT")
    plate.mark:SetPoint("BOTTOMLEFT")
    plate.mark:SetWidth(3)
    plate.name = Widgets.Label(plate, "GameFontHighlightSmall")
    plate.name:SetPoint("TOPLEFT", 9, -6)
    plate.name:SetPoint("RIGHT", -48, 0)
    plate.name:SetWordWrap(false)
    plate.score = Widgets.Label(plate, "GameFontNormalLarge")
    plate.score:SetPoint("RIGHT", -8, 0)
    plate.score:SetJustifyH("RIGHT")
    -- The footmen they have left, in a row
    plate.men = {}
    for index = 1, FOOTMEN do
      local man = plate:CreateTexture(nil, "ARTWORK")
      man:SetTexture(IMAGES .. "footman")
      man:SetSize(15, 15)
      man:SetPoint("BOTTOMLEFT", 6 + (index - 1) * 12, 3)
      man:SetVertexColor(unpack(colorOf(seat)))
      plate.men[index] = man
    end
    self.plates[seat] = plate
  end

  self.drawnFrame = CreateFrame("Frame", nil, panel, "BackdropTemplate")
  self.drawnFrame:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1 })
  self.drawnFrame:SetBackdropColor(0, 0, 0, 0.35)
  self.drawnFrame:SetBackdropBorderColor(1, 1, 1, 0.12)
  self.drawn = self.drawnFrame:CreateTexture(nil, "ARTWORK")
  self.drawn:SetPoint("TOPLEFT", 6, -6)
  self.drawn:SetPoint("BOTTOMRIGHT", -6, 6)
  self.drawnLabel = Widgets.Label(panel, "GameFontNormalSmall")
  self.left = Widgets.Label(panel, "GameFontDisableSmall")
  self.left:SetJustifyH("RIGHT")
  self.turnLeft = Widgets.Button(panel, "<", 28, 22)
  self.turnRight = Widgets.Button(panel, ">", 28, 22)
  self.turnLeft:SetScript("OnClick", function()
    self:turn(-1)
  end)
  self.turnRight:SetScript("OnClick", function()
    self:turn(1)
  end)

  self.note = Widgets.Label(panel, "GameFontHighlightSmall")
  self.note:SetJustifyV("TOP")
  self.note:SetSpacing(3)

  self.done = Widgets.Button(panel, L["realms_done"], 60, BUTTON_HEIGHT + 4)
  self.done:SetScript("OnClick", function()
    self:send()
  end)
  self.back = Widgets.Button(panel, L["realms_take_back"], 60, BUTTON_HEIGHT)
  self.back:SetScript("OnClick", function()
    self:pickUp()
  end)
  self.whole = Widgets.Button(panel, L["realms_whole_map"], 60, BUTTON_HEIGHT)
  self.whole:SetScript("OnClick", function()
    self.viewport:Fit()
  end)
end

-----------------------------
-- Layout
-----------------------------

--- @param width number
--- @param height number
function View:Layout(width, height)
  self.width, self.height = width, height
  local panelWidth = math.floor(math.max(PANEL_MIN, math.min(PANEL_MAX, width * PANEL_SHARE)))
  local mapWidth = width - panelWidth - GAP
  local viewport = self.viewport
  viewport.frame:ClearAllPoints()
  viewport.frame:SetPoint("TOPLEFT", self.stage, "TOPLEFT", 0, 0)
  viewport:SetSize(mapWidth, height)

  local panel = self.panel
  panel:ClearAllPoints()
  panel:SetPoint("TOPRIGHT", self.stage, "TOPRIGHT", 0, 0)
  panel:SetSize(panelWidth, height)
  local above = nil
  for _, plate in ipairs(self.plates) do
    plate:ClearAllPoints()
    if above then
      plate:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -PLATE_GAP)
    else
      plate:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    end
    plate:SetWidth(panelWidth)
    above = plate
  end
  local side = math.min(panelWidth - 70, 120)
  self.drawnFrame:SetSize(side, side)
  self.done:ClearAllPoints()
  self.done:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 0)
  self.done:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
  self.back:ClearAllPoints()
  self.back:SetPoint("BOTTOMLEFT", self.done, "TOPLEFT", 0, 4)
  self.back:SetWidth((panelWidth - 4) / 2)
  self.whole:ClearAllPoints()
  self.whole:SetPoint("BOTTOMRIGHT", self.done, "TOPRIGHT", 0, 4)
  self.whole:SetWidth((panelWidth - 4) / 2)
  if self.view then
    self:arrange()
    self:showPanel()
  end
end

--- Places the panel's tile under the players there are
--- @param seats number
function View:placeDrawn(seats)
  local plate = self.plates[seats]
  self.drawnLabel:ClearAllPoints()
  self.drawnLabel:SetPoint("TOPLEFT", plate, "BOTTOMLEFT", 2, -12)
  self.drawnFrame:ClearAllPoints()
  self.drawnFrame:SetPoint("TOPLEFT", self.drawnLabel, "BOTTOMLEFT", -2, -5)
  self.turnLeft:ClearAllPoints()
  self.turnLeft:SetPoint("TOPLEFT", self.drawnFrame, "TOPRIGHT", 8, 0)
  self.turnRight:ClearAllPoints()
  self.turnRight:SetPoint("TOPLEFT", self.turnLeft, "BOTTOMLEFT", 0, -4)
  self.left:ClearAllPoints()
  self.left:SetPoint("BOTTOMLEFT", self.drawnFrame, "BOTTOMRIGHT", 8, 0)
  self.note:ClearAllPoints()
  self.note:SetPoint("TOPLEFT", self.drawnFrame, "BOTTOMLEFT", 0, -10)
  self.note:SetPoint("BOTTOMRIGHT", self.back, "TOPRIGHT", 0, 8)
end

--- Where a square's top left corner is on the map, before zooming
--- @param x number
--- @param y number
--- @return number left, number top
function View:spotOf(x, y)
  return (x - self.origin.x) * self.cell, (y - self.origin.y) * self.cell
end

--- Where a point of the map is on the stage, for writing something there
--- @param left number
--- @param top number
--- @return number x, number y From the stage's top left corner
function View:onStage(left, top)
  local viewport = self.viewport
  return viewport.x + left * viewport.zoom, viewport.y + top * viewport.zoom
end

--- Sizes the map to the tiles there are and the room round them, and puts every tile, footman
--- and light where it goes
function View:arrange()
  local state = self.view.state
  local minX, maxX, minY, maxY = 0, 0, 0, 0
  for _, tile in ipairs(state.tiles) do
    minX, maxX = math.min(minX, tile.x), math.max(maxX, tile.x)
    minY, maxY = math.min(minY, tile.y), math.max(maxY, tile.y)
  end
  local columns, rows = maxX - minX + 1 + 2 * ROOM, maxY - minY + 1 + 2 * ROOM
  local viewport = self.viewport
  local cell = math.min(MOST_FITTED, viewport.width / columns, viewport.height / rows)
  -- What is in the middle stays there, unless all of it is in sight
  local fitted = viewport:Fits()
  local middleX, middleY
  if not fitted and self.cell > 0 then
    middleX = (viewport.width / 2 - viewport.x) / viewport.zoom / self.cell + self.origin.x
    middleY = (viewport.height / 2 - viewport.y) / viewport.zoom / self.cell + self.origin.y
  end
  local zoom = viewport.zoom
  self.origin = { x = minX - ROOM, y = minY - ROOM }
  self.size = { columns = columns, rows = rows }
  self.cell = cell
  viewport.maxZoom = math.max(1.5, MOST_ZOOMED / cell)
  viewport:SetContentSize(columns * cell, rows * cell)
  if middleX then
    viewport:ZoomTo(zoom, (middleX - self.origin.x) * cell, (middleY - self.origin.y) * cell, true)
  else
    viewport:Fit(true)
  end

  for index, tile in ipairs(state.tiles) do
    self:placeTile(index, tile)
  end
  for index = #state.tiles + 1, #self.tiles do
    self.tiles[index]:Hide()
    self.shadows[index]:Hide()
  end
  self:showFootmen()
  self:showMarks()
end

--- @param index number
--- @param tile RealmsTile
--- @param scale number? Bigger or smaller than its square for a moment
function View:placeTile(index, tile, scale)
  local texture = self.tiles[index]
  if not texture then
    self.shadows[index] = self.tileLayer:CreateTexture(nil, "BACKGROUND")
    self.shadows[index]:SetTexture(FLAT)
    self.shadows[index]:SetVertexColor(0, 0, 0, 0.45)
    texture = self.tileLayer:CreateTexture(nil, "ARTWORK")
    self.tiles[index] = texture
  end
  -- Clamped, so that its edges aren't blended with the opposite edge of the picture
  texture:SetTexture(IMAGES .. tile.kind, "CLAMP", "CLAMP")
  turnTexture(texture, tile.turn)
  local left, top = self:spotOf(tile.x, tile.y)
  local side = self.cell * (scale or 1) + math.max(LEAST_OVERLAP, self.cell * OVERLAP)
  local middleX, middleY = left + self.cell / 2, top + self.cell / 2
  texture:ClearAllPoints()
  texture:SetSize(side, side)
  texture:SetPoint("CENTER", self.map, "TOPLEFT", middleX, -middleY)
  texture:Show()
  local shadow = self.shadows[index]
  local offset = self.cell * SHADOW_OFFSET * (scale or 1) ^ 3
  shadow:ClearAllPoints()
  shadow:SetSize(side, side)
  shadow:SetPoint("CENTER", self.map, "TOPLEFT", middleX + offset, -middleY - offset)
  shadow:Show()
end

--- Where a feature of a tile is on the map, before zooming
--- @param x number
--- @param y number
--- @param kind string
--- @param turn number
--- @param feature number
--- @return number left, number top
function View:featureSpot(x, y, kind, turn, feature)
  local at = TILES[kind].features[feature].at
  local fx, fy = turnedPoint(at[1], at[2], turn)
  local left, top = self:spotOf(x, y)
  return left + fx * self.cell, top + fy * self.cell
end

--- Puts a footman on the map
--- @param texture Texture
--- @param left number Where he stands
--- @param top number
--- @param seat number
--- @param scale number?
function View:standFootman(texture, left, top, seat, scale)
  local side = self.cell * FOOTMAN * (scale or 1)
  texture:ClearAllPoints()
  texture:SetSize(side, side)
  texture:SetPoint("CENTER", self.map, "TOPLEFT", left, -(top - side * 0.08))
  texture:SetVertexColor(unpack(colorOf(seat)))
  texture:Show()
end

--- @param index number
--- @return Texture
function View:footmanTexture(index)
  local texture = self.footmen[index]
  if not texture then
    texture = self.footLayer:CreateTexture(nil, "ARTWORK")
    texture:SetTexture(IMAGES .. "footman")
    self.footmen[index] = texture
  end
  texture:SetAlpha(1)
  return texture
end

--- Every footman on the map, and those on their way home from what was just scored
--- @param leaving RealmsFootman[]? Not on the board any more, but still to be seen going
function View:showFootmen(leaving)
  local state = self.view.state
  local count = 0
  local function show(footman)
    count = count + 1
    local index = math.floor(footman.feature / SPAN)
    local tile = state.tiles[index]
    local left, top = self:featureSpot(tile.x, tile.y, tile.kind, tile.turn, footman.feature % SPAN)
    self:standFootman(self:footmanTexture(count), left, top, footman.seat)
    return self.footmen[count]
  end
  for _, footman in ipairs(state.footmen) do
    show(footman)
  end
  local textures = {}
  for _, footman in ipairs(leaving or {}) do
    textures[#textures + 1] = show(footman)
  end
  for index = count + 1, #self.footmen do
    self.footmen[index]:Hide()
  end
  return textures
end

-----------------------------
-- The player's turn
-----------------------------

--- Whether the player may lay their tile right now
--- @return boolean
function View:placing()
  local view = self.view
  return view ~= nil and view.canMove and view.live and view.state.tile ~= nil and not self.animator:Busy()
end

--- Where the tile fits, and every way round it fits there
--- @return table<number, { x: number, y: number, turns: number[] }>
function View:fits()
  if not self.fitting then
    local state = self.view.state
    local fitting = {}
    for _, place in ipairs(placings(state, state.tile)) do
      local key = keyOf(place.x, place.y)
      fitting[key] = fitting[key] or { x = place.x, y = place.y, turns = {} }
      table.insert(fitting[key].turns, place.turn)
    end
    self.fitting = fitting
  end
  return self.fitting
end

--- Which way round the tile goes on a square: the way the player last had it there, or the way
--- they have it in the panel if it fits that way, or the first way after that it fits
--- @param x number
--- @param y number
--- @return number?
function View:turnAt(x, y)
  local spot = self:fits()[keyOf(x, y)]
  if not spot then
    return nil
  end
  local wanted = self.turns[keyOf(x, y)] or self.facing or 0
  for step = 0, 3 do
    local turn = (wanted + step) % 4
    for _, fits in ipairs(spot.turns) do
      if fits == turn then
        return turn
      end
    end
  end
  return spot.turns[1]
end

--- Turns the tile on to the next way it fits, where it is pointed at or laid for now, or in the
--- panel
--- @param way number 1 clockwise, -1 the other way
function View:turn(way)
  if not self:placing() then
    return
  end
  local square = self.placed or self.pointed
  if square then
    local spot = self:fits()[keyOf(square.x, square.y)]
    if not spot then
      return
    end
    local now = self.placed and self.placed.turn or self:turnAt(square.x, square.y)
    for step = 1, 4 do
      local turn = (now + way * step) % 4
      for _, fits in ipairs(spot.turns) do
        if fits == turn and turn ~= now then
          self.turns[keyOf(square.x, square.y)] = turn
          self.facing = turn
          if self.placed then
            self:lay(square.x, square.y)
          end
          self:showMarks()
          self:showPanel()
          private.Widgets.PlaySound("realmsFootman")
          return
        end
      end
    end
  else
    self.facing = ((self.facing or 0) + way) % 4
    self:showPanel()
  end
end

--- Lays the tile on a square for now, the way round it goes there
--- @param x number
--- @param y number
function View:lay(x, y)
  local turn = self:turnAt(x, y)
  if not turn then
    return
  end
  local state = self.view.state
  local fresh = not self.placed or self.placed.x ~= x or self.placed.y ~= y
  self.placed = { x = x, y = y, turn = turn }
  self.outlook = preview(state, state.tile, x, y, turn)
  self.hovered = nil
  if fresh then
    private.Widgets.PlaySound("realmsLay")
  end
  self:showMarks()
  self:showPanel()
end

--- Picks the tile laid for now back up
function View:pickUp()
  if self.placed then
    self.placed, self.outlook, self.hovered = nil, nil, nil
    GameTooltip_Hide()
    self:showMarks()
    self:showPanel()
  end
end

--- The spots of the tile laid for now that may take a footman
--- @return table<number, boolean>
function View:openSpots()
  local open = {}
  local state, placed = self.view.state, self.placed
  if not placed or state.men[self.view.seat] <= 0 then
    return open
  end
  for feature, entry in ipairs(self.outlook) do
    local kind = TILES[state.tile].features[feature].kind
    if not entry.taken and (state.fields or kind ~= "field") then
      open[feature] = true
    end
  end
  return open
end

--- Puts a footman on a spot of the tile laid for now, or takes him off it again
--- @param feature number
function View:toggleFootman(feature)
  local placed = self.placed
  if placed.footman == feature then
    placed.footman = nil
  else
    placed.footman = feature
    private.Widgets.PlaySound("realmsFootman")
  end
  self:showMarks()
  self:showPanel()
end

--- Sends the move
function View:send()
  local placed = self.placed
  if not placed or not self:placing() then
    return
  end
  self.placed, self.outlook, self.hovered = nil, nil, nil
  GameTooltip_Hide()
  self.turns = {}
  self.view.submit(moveOf(placed.x, placed.y, placed.turn, placed.footman))
end

--- The square under the cursor
--- @return number? x, number? y, number? left, number? top Where on the map, before zooming
function View:cursorSquare()
  local map = self.map
  if not map:IsMouseOver() or not self.viewport.frame:IsMouseOver() then
    return nil
  end
  local scale = map:GetEffectiveScale()
  local cursorX, cursorY = GetCursorPosition()
  local left, top = cursorX / scale - (map:GetLeft() or 0), (map:GetTop() or 0) - cursorY / scale
  return math.floor(left / self.cell + self.origin.x), math.floor(top / self.cell + self.origin.y), left, top
end

--- The spot of the tile laid for now under the cursor, that may take a footman
--- @param left number
--- @param top number
--- @return number?
function View:spotAt(left, top)
  local placed = self.placed
  if not placed then
    return nil
  end
  local best, nearest = nil, self.cell * SPOT * 0.6
  for feature in pairs(self:openSpots()) do
    local x, y = self:featureSpot(placed.x, placed.y, self.view.state.tile, placed.turn, feature)
    local distance = math.sqrt((x - left) ^ 2 + (y - top) ^ 2)
    if distance < nearest then
      best, nearest = feature, distance
    end
  end
  return best
end

--- Keeps up with the cursor: the square and the spot it is over
function View:watch()
  if not self.view then
    return
  end
  local x, y, left, top = self:cursorSquare()
  local placing = self:placing()
  local pointed = placing and x and self:fits()[keyOf(x, y)] and { x = x, y = y } or nil
  local hovered = placing and left and self:spotAt(left, top) or nil
  local was = self.pointed
  if (pointed and was and pointed.x == was.x and pointed.y == was.y) or (pointed == nil and was == nil) then
    if hovered == self.hovered then
      return
    end
  end
  self.pointed, self.hovered = pointed, hovered
  self:showMarks()
  self:showTip()
end

--- @param button string
function View:mapDown(button)
  self.pressed = nil
  self.viewport:Grab(button)
  local x, y, left, top = self:cursorSquare()
  if x then
    self.pressed = { x = x, y = y, left = left, top = top, button = button }
  end
end

--- @param button string
function View:mapUp(button)
  local pressed = self.pressed
  self.pressed = nil
  if not pressed or self.viewport.dragged or not self:placing() then
    return
  end
  local placed = self.placed
  if button == "RightButton" then
    if placed and placed.x == pressed.x and placed.y == pressed.y then
      self:turn(1)
    elseif self:fits()[keyOf(pressed.x, pressed.y)] then
      self.pointed = { x = pressed.x, y = pressed.y }
      self:turn(1)
    end
    return
  end
  if button ~= "LeftButton" then
    return
  end
  local spot = self:spotAt(pressed.left, pressed.top)
  if spot then
    self:toggleFootman(spot)
  elseif self:fits()[keyOf(pressed.x, pressed.y)] then
    self:lay(pressed.x, pressed.y)
  end
end

--- @param key string
--- @return boolean
function View:key(key)
  if not self:placing() then
    return false
  end
  if key == "R" then
    self:turn(1)
  elseif key == "E" then
    self:turn(-1)
  elseif key == "ENTER" and self.placed then
    self:send()
  elseif key == "ESCAPE" and self.placed then
    self:pickUp()
  else
    return false
  end
  return true
end

-----------------------------
-- Showing
-----------------------------

--- @param pool Texture[]
--- @param index number
--- @param make fun(): Texture
--- @return Texture
local function pooled(pool, index, make)
  local texture = pool[index]
  if not texture then
    texture = make()
    pool[index] = texture
  end
  return texture
end

--- The squares the tile fits on, the tile where it is pointed at or laid, and the spots on it
function View:showMarks()
  local count = 0
  local placing = self:placing()
  if placing then
    for _, spot in pairs(self:fits()) do
      count = count + 1
      local mark = pooled(self.marks, count, function()
        local texture = self.markLayer:CreateTexture(nil, "BORDER")
        texture:SetTexture(IMAGES .. "square")
        texture:SetBlendMode("ADD")
        return texture
      end)
      local left, top = self:spotOf(spot.x, spot.y)
      local pointed = self.pointed and self.pointed.x == spot.x and self.pointed.y == spot.y
      mark:ClearAllPoints()
      mark:SetPoint("TOPLEFT", self.map, "TOPLEFT", left, -top)
      mark:SetSize(self.cell, self.cell)
      mark:SetVertexColor(unpack(pointed and POINTED or FITS))
      mark:Show()
    end
  end
  for index = count + 1, #self.marks do
    self.marks[index]:Hide()
  end

  local state = self.view.state
  local placed = self.placed
  local square = placed or (placing and self.pointed) or nil
  local ghost, outline = self.ghost, self.outline
  if square then
    local turn = placed and placed.turn or self:turnAt(square.x, square.y)
    local left, top = self:spotOf(square.x, square.y)
    ghost:SetTexture(IMAGES .. state.tile, "CLAMP", "CLAMP")
    turnTexture(ghost, turn)
    ghost:ClearAllPoints()
    ghost:SetPoint("TOPLEFT", self.map, "TOPLEFT", left, -top)
    ghost:SetSize(self.cell, self.cell)
    ghost:SetAlpha(placed and 1 or GHOST_ALPHA)
    ghost:Show()
    outline:ClearAllPoints()
    outline:SetPoint("TOPLEFT", self.map, "TOPLEFT", left, -top)
    outline:SetSize(self.cell, self.cell)
    outline:SetVertexColor(unpack(LAID))
    outline:SetShown(placed ~= nil)
  else
    ghost:Hide()
    outline:Hide()
  end

  count = 0
  local seat = self.view.seat
  if placed then
    for feature in pairs(self:openSpots()) do
      if feature ~= placed.footman then
        count = count + 1
        local ring = pooled(self.spots, count, function()
          local texture = self.topLayer:CreateTexture(nil, "ARTWORK")
          texture:SetTexture(IMAGES .. "spot")
          texture:SetBlendMode("ADD")
          return texture
        end)
        local left, top = self:featureSpot(placed.x, placed.y, state.tile, placed.turn, feature)
        local side = self.cell * SPOT * (feature == self.hovered and 1.3 or 1)
        ring:ClearAllPoints()
        ring:SetPoint("CENTER", self.map, "TOPLEFT", left, -top)
        ring:SetSize(side, side)
        local color = colorOf(seat)
        ring:SetVertexColor(color[1], color[2], color[3], feature == self.hovered and 1 or 0.8)
        ring:Show()
      end
    end
  end
  for index = count + 1, #self.spots do
    self.spots[index]:Hide()
  end
  if placed and placed.footman then
    local left, top = self:featureSpot(placed.x, placed.y, state.tile, placed.turn, placed.footman)
    self:standFootman(self.held, left, top, seat, placed.footman == self.hovered and 1.1 or 1)
  else
    self.held:Hide()
  end
end

--- What a spot of the tile laid for now is, and what a footman there would come to
function View:showTip()
  local feature = self.hovered
  if not feature then
    GameTooltip_Hide()
    return
  end
  local state = self.view.state
  local spec = TILES[state.tile].features[feature]
  local entry = self.outlook[feature]
  GameTooltip:SetOwner(self.viewport.frame, "ANCHOR_CURSOR")
  GameTooltip:SetText(L["realms_kind_" .. spec.kind])
  local text
  if spec.kind == "field" then
    text = L["realms_tip_field"]
  elseif entry.open == 0 then
    text = L["realms_tip_finishes"]:format(pointsOf(spec.kind, entry.size, entry.banners, 0))
  elseif spec.kind == "abbey" then
    text = L["realms_tip_abbey"]:format(8 - entry.open)
  else
    text = L["realms_tip_" .. spec.kind]:format(entry.size, pointsOf(spec.kind, entry.size, entry.banners, entry.open))
  end
  GameTooltip:AddLine(text, 1, 1, 1, true)
  local here = self.placed and self.placed.footman == feature
  GameTooltip:AddLine(L[here and "realms_tip_take_off" or "realms_tip_put"], 0.6, 0.6, 0.6, true)
  GameTooltip:Show()
end

--- What the tile laid for now would finish, in a few words
--- @return string
function View:outlookText()
  local placed, state = self.placed, self.view.state
  local lines = {}
  local seen = {}
  for feature, entry in ipairs(self.outlook) do
    local spec = TILES[state.tile].features[feature]
    local key = table.concat(entry.groups, ",") .. ":" .. (entry.groups[1] and "" or feature)
    if spec.kind ~= "field" and entry.open == 0 and not seen[key] then
      seen[key] = true
      local men = {}
      for seat, count in pairs(entry.men) do
        men[seat] = count
      end
      if placed.footman and self.outlook[placed.footman] == entry then
        men[self.view.seat] = (men[self.view.seat] or 0) + 1
      end
      local winners = majority({ men = men }, state.seats)
      local points = pointsOf(spec.kind, entry.size, entry.banners, 0)
      if #winners > 0 then
        local names = {}
        for _, seat in ipairs(winners) do
          names[#names + 1] = textColor(colorOf(seat)) .. (seat == self.view.seat and L["realms_you"] or self.view.names[seat]) .. "|r"
        end
        lines[#lines + 1] = L["realms_finishes_for"]:format(L["realms_kind_" .. spec.kind], points, table.concat(names, ", "))
      else
        lines[#lines + 1] = L["realms_finishes"]:format(L["realms_kind_" .. spec.kind])
      end
    end
  end
  return table.concat(lines, "\n")
end

--- Scores, footmen, the tile drawn and what to do
function View:showPanel()
  local view = self.view
  local state = view.state
  local turn = view.match.status == "active" and not state.outcome and state.turn or nil
  for seat, plate in ipairs(self.plates) do
    plate:SetShown(seat <= state.seats)
    if seat <= state.seats then
      plate.back:SetColorTexture(unpack(seat == turn and PLATE_TURN or PLATE))
      plate.mark:SetShown(seat == turn)
      local name = seat == view.seat and L["realms_you"] or (view.names[seat] or "")
      plate.name:SetText(textColor(colorOf(seat)) .. name .. "|r")
      plate.score:SetText(tostring(self.counting and self.counting[seat] or state.scores[seat]))
      local men = state.men[seat]
      if self.placed and self.placed.footman and seat == view.seat then
        men = men - 1
      end
      for index, man in ipairs(plate.men) do
        man:SetAlpha(index <= men and 1 or 0.15)
      end
      plate:SetAlpha(state.out[seat] and 0.45 or 1)
    end
  end
  self:placeDrawn(state.seats)

  local placing = self:placing()
  local tile = state.tile
  self.drawnFrame:SetShown(tile ~= nil)
  if tile then
    self.drawn:SetTexture(IMAGES .. tile, "CLAMP", "CLAMP")
    local facing = self.placed and self.placed.turn or (self.pointed and self:turnAt(self.pointed.x, self.pointed.y)) or self.facing or 0
    turnTexture(self.drawn, placing and facing or 0)
    if placing then
      self.drawnLabel:SetText(L["realms_your_tile"])
    else
      self.drawnLabel:SetText(L["realms_their_tile"]:format(textColor(colorOf(state.turn)) .. (view.names[state.turn] or "") .. "|r"))
    end
  else
    self.drawnLabel:SetText(L["realms_no_tiles"])
  end
  self.left:SetText(L["realms_left"]:format(#state.bag))
  self.turnLeft:SetShown(placing)
  self.turnRight:SetShown(placing)

  local note
  if not view.live then
    note = ""
  elseif placing and self.placed then
    local hint = L[next(self:openSpots()) and "realms_hint_footman" or "realms_hint_no_footman"]
    local outlook = self:outlookText()
    note = outlook ~= "" and (outlook .. "\n\n" .. hint) or hint
  elseif placing then
    -- What the others did since, above what to do now
    note = (self.lastNote and self.lastNote ~= "" and self.lastEvent and self.lastEvent.seat ~= view.seat) and (self.lastNote .. "\n\n" .. L["realms_hint_lay"]) or L["realms_hint_lay"]
  else
    note = self.lastNote or ""
  end
  self.note:SetText(note)
  self.done:SetEnabled(placing and self.placed ~= nil)
  self.back:SetEnabled(placing and self.placed ~= nil)
  self.whole:SetEnabled(not self.viewport:Fits())
end

-----------------------------
-- Moves played
-----------------------------

--- Says what a move did, in a line for the panel
--- @param event RealmsEvent
--- @return string
function View:describe(event)
  local view = self.view
  local lines = {}
  local who = event.seat == view.seat and L["realms_you"] or (view.names[event.seat] or "")
  lines[1] = L["realms_laid"]:format(textColor(colorOf(event.seat)) .. who .. "|r")
  for _, scoring in ipairs(event.scored or {}) do
    if #scoring.seats > 0 and scoring.points > 0 then
      local names = {}
      for _, seat in ipairs(scoring.seats) do
        names[#names + 1] = textColor(colorOf(seat)) .. (seat == view.seat and L["realms_you"] or (view.names[seat] or "")) .. "|r"
      end
      lines[#lines + 1] = L["realms_scored"]:format(table.concat(names, ", "), scoring.points, L["realms_kind_" .. scoring.kind])
    end
  end
  if event.aside then
    lines[#lines + 1] = L["realms_aside"]:format(#event.aside)
  end
  return table.concat(lines, "\n")
end

--- Brings a square into sight, if the map is zoomed in and it is out of it
--- @param x number
--- @param y number
function View:bringIntoSight(x, y)
  local viewport = self.viewport
  if viewport:Fits() then
    return
  end
  local left, top = self:spotOf(x + 0.5, y + 0.5)
  local stageX, stageY = viewport.x + left * viewport.zoom, viewport.y + top * viewport.zoom
  local margin = self.cell * viewport.zoom
  if stageX < margin or stageY < margin or stageX > viewport.width - margin or stageY > viewport.height - margin then
    viewport:ZoomTo(viewport.zoom, left, top)
  end
end

--- Lights up the tiles of a group in a colour for a while, from a time on
--- @param state RealmsState
--- @param root number
--- @param color number[]
--- @param delay number
function View:light(state, root, color, delay)
  local group = state.groups[root]
  if not group then
    return
  end
  local list = {}
  for index in pairs(group.tiles) do
    list[#list + 1] = index
  end
  table.sort(list)
  local textures = {}
  for _, index in ipairs(list) do
    local tile = state.tiles[index]
    local texture = nil
    for _, candidate in ipairs(self.lit) do
      if not candidate.busy then
        texture = candidate
        break
      end
    end
    if not texture then
      texture = self.markLayer:CreateTexture(nil, "OVERLAY")
      texture:SetTexture(IMAGES .. "square")
      texture:SetBlendMode("ADD")
      self.lit[#self.lit + 1] = texture
    end
    texture.busy = true
    local left, top = self:spotOf(tile.x, tile.y)
    texture:ClearAllPoints()
    texture:SetPoint("TOPLEFT", self.map, "TOPLEFT", left, -top)
    texture:SetSize(self.cell, self.cell)
    texture:SetVertexColor(color[1], color[2], color[3], 0)
    texture:Show()
    textures[#textures + 1] = texture
  end
  self.animator:Play(LIT, function(progress)
    for _, texture in ipairs(textures) do
      texture:SetAlpha(math.sin(progress * math.pi))
    end
  end, {
    delay = delay,
    onDone = function()
      for _, texture in ipairs(textures) do
        texture.busy = false
        texture:Hide()
      end
    end,
  })
end

--- The middle of a group's tiles on the stage, for writing what it scored there
--- @param state RealmsState
--- @param root number
--- @return number x, number y
function View:middleOf(state, root)
  local group = state.groups[root]
  local x, y, count = 0, 0, 0
  for index in pairs(group and group.tiles or {}) do
    local tile = state.tiles[index]
    x, y, count = x + tile.x + 0.5, y + tile.y + 0.5, count + 1
  end
  if count == 0 then
    return self.width / 2, self.height / 2
  end
  return self:onStage(self:spotOf(x / count, y / count))
end

--- Shows a move being made
--- @param event RealmsEvent
function View:animate(event)
  local state = self.view.state
  local Widgets = private.Widgets
  local index = event.index
  local tile = state.tiles[index]
  self:bringIntoSight(tile.x, tile.y)
  self.tiles[index]:SetAlpha(0)
  self.shadows[index]:SetAlpha(0)
  self.animator:Play(DROP, function(progress)
    self:placeTile(index, tile, 1.25 - 0.25 * progress)
    self.tiles[index]:SetAlpha(math.min(1, progress * 2))
    self.shadows[index]:SetAlpha(progress)
  end, {
    ease = Widgets.Ease.out,
    onDone = function()
      Widgets.PlaySound("realmsLay")
    end,
  })

  -- The footman put down, if he is still there: one on something finished is shown leaving
  local leaving = {}
  for _, scoring in ipairs(event.scored) do
    for _, footman in ipairs(scoring.footmen) do
      leaving[#leaving + 1] = footman
    end
  end
  local textures = self:showFootmen(leaving)
  local byFeature = {}
  for number, footman in ipairs(leaving) do
    byFeature[footman.feature] = textures[number]
  end
  if event.footman then
    local feature = index * SPAN + event.footman
    local texture = byFeature[feature]
    if not texture then
      for number, footman in ipairs(state.footmen) do
        if footman.feature == feature then
          texture = self.footmen[number]
        end
      end
    end
    if texture then
      local left, top = self:featureSpot(tile.x, tile.y, tile.kind, tile.turn, event.footman)
      texture:SetAlpha(0)
      self.animator:Play(SET, function(progress)
        texture:SetAlpha(progress)
        self:standFootman(texture, left, top - (1 - progress) * self.cell * 0.3, event.seat, 1)
      end, {
        delay = DROP,
        ease = Widgets.Ease.back,
        onDone = function()
          Widgets.PlaySound("realmsFootman")
        end,
      })
    end
  end

  -- What it finished, one after the other
  local at = DROP + SCORE_AFTER
  local scores = {}
  for seat = 1, state.seats do
    scores[seat] = state.scores[seat]
  end
  for _, scoring in ipairs(event.scored) do
    for _, seat in ipairs(scoring.seats) do
      scores[seat] = scores[seat] - scoring.points
    end
  end
  self.counting = scores
  local size = math.max(16, math.floor(self.cell * self.viewport.zoom * 0.3))
  for _, scoring in ipairs(event.scored) do
    local color = #scoring.seats == 1 and colorOf(scoring.seats[1]) or GOLD
    self:light(state, scoring.group, color, at)
    local x, y = self:middleOf(state, scoring.group)
    if #scoring.seats > 0 and scoring.points > 0 then
      self.effects:Float(L["realms_points"]:format(scoring.points), x, y, { color = color, size = size, delay = at })
    end
    for _, footman in ipairs(scoring.footmen) do
      local texture = byFeature[footman.feature]
      if texture then
        self.animator:Play(LIT, function(progress)
          texture:SetAlpha(1 - progress)
        end, {
          delay = at + 0.2,
          onDone = function()
            texture:Hide()
          end,
        })
      end
    end
    self.animator:Play(0, function() end, {
      delay = at,
      onStart = function()
        if #scoring.seats > 0 and scoring.points > 0 then
          Widgets.PlaySound("realmsScore")
        end
        for _, seat in ipairs(scoring.seats) do
          scores[seat] = scores[seat] + scoring.points
        end
        self:showPanel()
      end,
    })
    at = at + (scoring.final and SCORE_EACH * 0.7 or SCORE_EACH)
  end
  self.animator:Play(0, function() end, {
    delay = at,
    onDone = function()
      self.counting = nil
      self.fitting = nil
      self:showFootmen()
      self:showMarks()
      self:showPanel()
    end,
  })
  return at
end

--- @param view GameView
function View:Update(view)
  local fresh = self.view == nil
  self.view = view
  if not view.changed and not fresh then
    self:showPanel()
    return
  end
  self.animator:Stop()
  self.effects:Clear()
  self.counting = nil
  self.fitting = nil
  self.placed, self.outlook, self.hovered, self.pointed = nil, nil, nil, nil
  if self.ply ~= view.ply then
    self.turns = {}
  end
  self.ply = view.ply
  GameTooltip_Hide()
  self:arrange()

  --- @type RealmsEvent?
  local event = view.played
  local last = view.events and view.events[view.ply]
  self.lastNote = last and last.index and self:describe(last) or ""
  self.lastEvent = last
  local over = 0
  if event and event.index then
    over = self:animate(event)
  end
  local state = view.state
  if event and state.outcome and state.outcome.winner == view.seat and (view.live or view.catching) then
    self.effects:Confetti(over)
  end
  self:showPanel()
end

--- @return boolean
function View:Busy()
  return self.animator:Busy()
end

private.Games.Register({
  id = "realms",
  name = L["game_realms"],
  description = L["game_realms_description"],
  genre = "strategy",
  icon = "Interface\\AddOns\\ForeverGames\\Images\\Icons\\realms",
  version = 1,
  seats = { 2, 3, 4, 5 },
  history = true,
  options = {
    { id = "fields", name = L["realms_option_fields"], description = L["realms_option_fields_tip"], default = true },
  },
  howto = {
    { heading = L["howto_goal"], text = L["realms_howto_goal"] },
    { heading = L["howto_turn"], text = L["realms_howto_turn"] },
    {
      heading = L["realms_howto_footmen"],
      text = function(rules)
        return L[rules.fields == false and "realms_howto_footmen_nofields" or "realms_howto_footmen_text"]
      end,
    },
    { heading = L["howto_scoring"], text = L["realms_howto_scoring"] },
    {
      heading = L["howto_end"],
      text = function(rules)
        return L[rules.fields == false and "realms_howto_end_nofields" or "realms_howto_end"]
      end,
    },
    { heading = L["howto_controls"], text = L["realms_howto_controls"] },
  },
  newState = newState,
  turn = function(state)
    return state.turn
  end,
  validate = validate,
  apply = apply,
  moves = moves,
  drop = drop,
  result = function(state)
    return state.outcome
  end,
  computer = COMPUTER,
  createView = createView,
  -- Not the engine's business: for the tests and the view
  rules = {
    TILES = TILES,
    KINDS = KINDS,
    SPAN = SPAN,
    FOOTMEN = FOOTMEN,
    STEPS = STEPS,
    keyOf = keyOf,
    across = across,
    featureAt = featureAt,
    edgeOf = edgeOf,
    turnedPoint = turnedPoint,
    fits = fits,
    placings = placings,
    preview = preview,
    find = find,
    groupOf = groupOf,
    worth = worth,
    majority = majority,
    left = left,
    play = play,
    parse = parse,
    moveOf = moveOf,
    standings = standings,
    think = think,
    TUNING = TUNING,
  },
})
