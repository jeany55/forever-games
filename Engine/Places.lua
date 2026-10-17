--------------------------
--  Places
--------------------------
-- Somewhere in the world, for the rules of a game about where things are: which continent, and
-- where on it in yards, the way the client's map puts its own world (C_Map.GetWorldPosFromMapPos)
-- — the view turns a click on a map into that, the rules never ask the client anything. How far
-- apart two places are, and what a guess at one is worth by how near it came.
--
-- A place travels as text: "0_-8899_770", the continent and the two yards across it, to the
-- nearest yard, in nothing a message can't carry. A move that guesses one is a letter and that.
--
-- A game deals places from a catalogue of its own (a list of entries with `continent`, `x` and
-- `y`, and whatever else it wants with them: a picture to look round, a name): Pick draws so many
-- of them in an order that comes from the game's chance alone, so the same seed deals the same
-- places on every client, by the catalogue's order. Its entries are known by an `id`, and a
-- catalogue is only ever added to at its end, or the game's version bumped: otherwise one client
-- would deal another place than another from the same seed.
--
-- What a guess is worth falls away the further out it was, as GeoGuessr's do: all of it within a
-- few yards, then e to the minus the distance over the scale. The curve is worked out with
-- nothing but adding and multiplying, so that it comes out the same on every client, which the
-- client's own exp needn't.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class Place
--- @field continent integer The client's continent (instance) the place is on
--- @field x number Yards across it, as the client's world positions have them
--- @field y number

--- @class Places
local Places = {}
private.Places = Places

-- The most a guess is worth, and how near it has to be for all of it
Places.BEST = 5000
Places.NEAR = 25
-- How many yards out a guess is worth a third of the best, about, on a continent
Places.SCALE = 4000
-- The furthest a place is taken to be from the middle of the world, in yards: more than either
-- continent reaches
local FARTHEST = 99999

--- e to the minus x, for x of 0 or more, the same on every client: e^-x is (e^-(x/2^k))^(2^k),
--- and for a small enough x/2^k a few terms of its series are exact to well within a point
--- @param x number
--- @return number
function Places.Decay(x)
  if x <= 0 then
    return 1
  elseif x > 60 then
    return 0
  end
  local halvings = 0
  while x > 0.0625 do
    x, halvings = x / 2, halvings + 1
  end
  -- 1 - x + x^2/2 - x^3/6 + ... - x^7/5040, nested
  local value = 1 - x * (1 - x / 2 * (1 - x / 3 * (1 - x / 4 * (1 - x / 5 * (1 - x / 6 * (1 - x / 7))))))
  for _ = 1, halvings do
    value = value * value
  end
  return value
end

--- How many yards apart two places are, nil for two on different continents
--- @param a Place
--- @param b Place
--- @return number?
function Places.Distance(a, b)
  if a.continent ~= b.continent then
    return nil
  end
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

--- What a guess so many yards out is worth: all of Places.BEST within Places.NEAR, nothing for
--- one on another continent (nil)
--- @param yards number?
--- @param scale number? Yards for the score to fall to about a third, Places.SCALE if left out
--- @return integer
function Places.Score(yards, scale)
  if not yards then
    return 0
  end
  if yards <= Places.NEAR then
    return Places.BEST
  end
  return math.floor(Places.BEST * Places.Decay((yards - Places.NEAR) / (scale or Places.SCALE)) + 0.5)
end

--- Writes a place down to the nearest yard: "0_-8899_770"
--- @param place Place
--- @return string
function Places.Encode(place)
  local function yards(value)
    return math.floor(value + 0.5)
  end
  return ("%d_%d_%d"):format(place.continent, yards(place.x), yards(place.y))
end

--- Reads a place written down by Encode
--- @param text string?
--- @return Place?
function Places.Decode(text)
  if type(text) ~= "string" then
    return nil
  end
  local continent, x, y = text:match("^(%d+)_(%-?%d+)_(%-?%d+)$")
  continent, x, y = tonumber(continent), tonumber(x), tonumber(y)
  if not continent or continent > 9999 or math.abs(x) > FARTHEST or math.abs(y) > FARTHEST then
    return nil
  end
  return { continent = continent, x = x, y = y }
end

--- Draws `count` different entries of a catalogue, in an order that comes from `random` alone:
--- as many as there are, if there aren't that many
--- @generic T
--- @param random Random
--- @param catalogue T[]
--- @param count integer
--- @param keep (fun(entry: T): boolean)? Only the entries this says yes to, in the catalogue's order
--- @return T[]
function Places.Pick(random, catalogue, count, keep)
  local pool = {}
  for _, entry in ipairs(catalogue) do
    if not keep or keep(entry) then
      pool[#pool + 1] = entry
    end
  end
  local picked = {}
  -- The first `count` of a shuffle of the pool, one swap at a time
  for index = 1, math.min(count, #pool) do
    local other = index - 1 + random:Roll(#pool - index + 1)
    pool[index], pool[other] = pool[other], pool[index]
    picked[index] = pool[index]
  end
  return picked
end

--- The entry of a catalogue with an id
--- @generic T
--- @param catalogue T[]
--- @param id string
--- @return T?
function Places.Find(catalogue, id)
  for _, entry in ipairs(catalogue) do
    if entry.id == id then
      return entry
    end
  end
  return nil
end

-----------------------------
-- Packs of places
-----------------------------
-- A game's places can come in packs: addons of their own, each a list of places and the pictures
-- that go with them, which anybody can make and drop in beside the game (API.md). A pack adds its
-- places to the game's catalogue under its own name, and the catalogue is every pack there is in
-- the order of their names, each in its own order. So two clients with the same packs have the
-- same catalogue whatever order the client happened to load them in. A place whose id a pack
-- before it has already is left out.
--
-- Which places there are, in which order, is summed up in a number (Signature) for the game to
-- count its version from, so that two players with different packs are told they are on other
-- versions rather than being dealt different places.

local catalogues = {}

--- @param name string
--- @return { packs: table<string, table[]>, listeners: fun()[], merged: table[]? }
local function catalogueNamed(name)
  local catalogue = catalogues[name]
  if not catalogue then
    catalogue = { packs = {}, listeners = {} }
    catalogues[name] = catalogue
  end
  return catalogue
end

--- Adds a pack of places to a catalogue. Each place is given the pack's name (`pack`), for the
--- game to find its pictures by
--- @param name string Which catalogue: the id of the game that deals from it
--- @param pack string The addon the places come in
--- @param places table[] Its places, in the order they were added to it: only ever added to at the end
function Places.AddPack(name, pack, places)
  assert(type(name) == "string" and type(pack) == "string", "A pack of places needs a catalogue and a name")
  assert(type(places) == "table", "A pack of places needs places")
  local catalogue = catalogueNamed(name)
  catalogue.packs[pack] = places
  catalogue.merged = nil
  for _, listener in ipairs(catalogue.listeners) do
    listener()
  end
end

--- Every place of a catalogue: the packs in the order of their names, each in its own order
--- @param name string
--- @return table[]
function Places.Catalogue(name)
  local catalogue = catalogueNamed(name)
  if not catalogue.merged then
    local names = {}
    for pack in pairs(catalogue.packs) do
      names[#names + 1] = pack
    end
    table.sort(names)
    local merged, seen = {}, {}
    for _, pack in ipairs(names) do
      for _, place in ipairs(catalogue.packs[pack]) do
        if type(place.id) == "string" and not seen[place.id] then
          seen[place.id] = true
          place.pack = pack
          merged[#merged + 1] = place
        end
      end
    end
    catalogue.merged = merged
  end
  return catalogue.merged
end

-- Signatures are worked out below this, a prime, so that they stay whole numbers a double holds
local SIGNATURE_MODULUS = 999983

--- A number for which places a catalogue has and in which order, the same on every client with
--- the same packs, and almost surely another with any other
--- @param name string
--- @return integer From 0 up to but not including a million
function Places.Signature(name)
  local signature = 0
  for _, place in ipairs(Places.Catalogue(name)) do
    for index = 1, #place.id do
      signature = (signature * 31 + place.id:byte(index)) % SIGNATURE_MODULUS
    end
    -- Between one id and the next, so that "ab" then "c" isn't "a" then "bc"
    signature = (signature * 31 + 1) % SIGNATURE_MODULUS
  end
  return signature
end

--- Has something told whenever a pack is added to a catalogue, as one that loads after the game
--- that deals from it will be
--- @param name string
--- @param listener fun()
function Places.OnPack(name, listener)
  local listeners = catalogueNamed(name).listeners
  listeners[#listeners + 1] = listener
end
