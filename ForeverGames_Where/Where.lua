--------------------------
--  Where in Azeroth
--------------------------
-- Taken somewhere in the world, the player looks round and says where on the map they think they
-- are. The nearer the guess, the more it is worth: all 5000 within a few yards, falling away the
-- further out it was, nothing for the wrong continent (Engine/Places.lua). Five places a game,
-- each dealt from the game's chance out of every place there is, so a race (Engine/Race.lua) and
-- the day's game (Engine/Daily.lua) deal the same five for everyone.
-- A race is won on points rather than time, and what the rival guessed at each place goes with
-- their score, to be shown on the map next to the player's own.
--
-- The places are panoramas of the client's own world, looked round in (GUI/PanoView.lua). They come
-- in packs, addons of their own named ForeverGames_Where_<something>, each a list of places
-- (Places.AddPack) and the pictures of them. ForeverGames_Where_Places is the one that comes with
-- the game, and is needed for it to be played (PLACES_ADDON); anybody can make another with
-- Tools/GeoBench and Tools/places.py, and every place of every pack there is is dealt from.
--
-- Where in Azeroth is an addon of its own, not a part of Forever Games: it knows the engine only
-- by what ForeverGamesAPI has (Engine/API.lua). Its strings are in Locales/enUS.lua, its view in
-- View.lua.
--
-- A move is a guess at the place the game is at: "g" and the place (Places.Encode), or "s" for
-- none, when the time ran out without one. Whoever sets a game up may give each place a time
-- (`time`): the view puts in what the player had pinned when it runs out, or "s". Nothing checks
-- the time but the player's own client, as with every timed game here.
--
-- Places are only ever added to the end of a pack, and the game's version is counted from which
-- places there are (Places.Signature), so that two players with different packs are told they are
-- on other versions rather than being dealt different places.

--- @type string, table
local ADDON, own = ...
local engine = ForeverGamesAPI
local L = engine.L
local Places = engine.Places

local ROUNDS = 5
local GUESS, SKIP = "g", "s"
local PLACES_ADDON = "ForeverGames_Where_Places"
-- How the version is counted: the rules' own, by the million, and which places there are under
-- that. Before there were packs it was a thousand and one more for every place
local RULES = 2

--- @return integer
local function version()
  return RULES * 1000000 + Places.Signature("where")
end

--- @class WhereGuess
--- @field guess Place? Where the player said, nil for no guess
--- @field yards number? How far out it was, nil for none or another continent
--- @field points integer

--- @class WhereState
--- @field places string[] The places of the game, by id, in the order they are played
--- @field round integer The place the game is at, one past the last once it is over
--- @field guesses WhereGuess[] By round
--- @field total integer Points so far
--- @field time integer Seconds each place is given, 0 for as long as it takes

local function catalogue()
  return Places.Catalogue("where")
end

--- The place a game is at, or one of its places by round
--- @param state WhereState
--- @param round integer?
--- @return table?
local function placeOf(state, round)
  return Places.Find(catalogue(), state.places[round or state.round])
end

--- Points as they are shown: "23,410"
--- @param points number
--- @return string
local function points(points)
  local text = tostring(math.floor(points + 0.5))
  local grouped = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (grouped:gsub("^,", ""))
end

local OPTIONS = {
  {
    id = "time",
    name = L["where_option_time"],
    description = L["where_option_time_description"],
    choices = { 0, 30, 60, 120, 180 },
    default = 0,
    label = function(value)
      return value == 0 and L["where_time_none"] or L["where_time_seconds"]:format(value)
    end,
  },
}

--- @param seats number
--- @param random Random
--- @param rules table<string, any>
--- @return WhereState
local function newState(seats, random, rules)
  local ids = {}
  for index, place in ipairs(Places.Pick(random, catalogue(), ROUNDS)) do
    ids[index] = place.id
  end
  return { places = ids, round = 1, guesses = {}, total = 0, time = rules.time or 0 }
end

--- @param state WhereState
--- @param seat number
--- @param move string
--- @return boolean, string?
local function validate(state, seat, move)
  if state.round > #state.places then
    return false, "where_over"
  elseif move == SKIP then
    return true
  elseif move:sub(1, 1) == GUESS and Places.Decode(move:sub(2)) then
    return true
  end
  return false, "where_bad_guess"
end

--- @param state WhereState
--- @param seat number
--- @param move string
--- @return table
local function apply(state, seat, move)
  local round, place = state.round, placeOf(state)
  local guess = move ~= SKIP and Places.Decode(move:sub(2)) or nil
  local yards = guess and place and Places.Distance(guess, place) or nil
  local scored = guess and place and Places.Score(yards) or 0
  state.guesses[round] = { guess = guess, yards = yards, points = scored }
  state.total = state.total + scored
  state.round = round + 1
  return { round = round, points = scored, yards = yards }
end

--- @param state WhereState
local function result(state)
  if state.round > #state.places then
    return { winner = 1 }
  end
  return nil
end

--- A guess right on the place, one well off it, and none: enough for the tests to play it out
--- @param state WhereState
--- @return string[]
local function moves(state)
  local place = placeOf(state)
  if not place then
    return { SKIP }
  end
  local near = { continent = place.continent, x = place.x + 40, y = place.y - 30 }
  local far = { continent = place.continent, x = place.x - 3000, y = place.y + 2000 }
  return { GUESS .. Places.Encode(place), GUESS .. Places.Encode(near), GUESS .. Places.Encode(far), SKIP }
end

own.Where = { ROUNDS = ROUNDS, GUESS = GUESS, SKIP = SKIP, placeOf = placeOf, points = points, catalogue = catalogue }

local WHERE = {
  id = "where",
  name = L["game_where"],
  description = L["game_where_description"],
  genre = "solo",
  icon = "Interface\\AddOns\\ForeverGames_Where\\Images\\icon",
  plugin = ADDON,
  version = version(),
  seats = 1,
  options = OPTIONS,
  howto = {
    { heading = L["howto_goal"], text = L["where_howto_goal"] },
    { heading = L["where_howto_look"], text = L["where_howto_look_text"] },
    { heading = L["where_howto_guess"], text = L["where_howto_guess_text"] },
    {
      heading = L["where_time"],
      text = function(rules)
        return rules.time > 0 and L["where_howto_timed"] or nil
      end,
    },
    { heading = L["howto_scoring"], text = L["where_howto_scoring"] },
  },
  clock = "open",
  addon = PLACES_ADDON,
  newState = newState,
  turn = function()
    return 1
  end,
  validate = validate,
  apply = apply,
  moves = moves,
  result = result,
  progress = function(state)
    local shown = math.min(state.round, #state.places)
    return L["where_progress"]:format(shown, #state.places, points(state.total))
  end,
  record = function(state, seconds, outcome)
    -- Only a game played to its end has a score worth keeping
    if outcome and state.round > #state.places and #state.places > 0 then
      return { { key = "score", value = state.total } }
    end
    return nil
  end,
  -- A race is won on points, and what the rival guessed at each place goes with them
  raceFor = { key = "score", show = function(value)
    return L["where_points"]:format(points(value))
  end },
  ghost = { marks = true },
  daily = {
    rules = { time = 120 },
    score = function(state)
      return state.total
    end,
  },
  createView = function(stage)
    return own.WhereView.New(stage)
  end,
}

engine.Games.Register(WHERE)
-- A pack loads after the game, and has the game deal from more places than it did: another version
Places.OnPack("where", function()
  WHERE.version = version()
end)
