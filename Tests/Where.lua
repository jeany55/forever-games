-- Where in Azeroth and what it is built on: places in the world (Engine/Places.lua), a race won
-- on points and a ghost of marks (Engine/Race.lua), the catalogue of places and its pictures,
-- and the two views, looking round a panorama (GUI/PanoView.lua) and the map to guess on
-- (GUI/MapView.lua), in the fake client.

local ADDON_NAME = "ForeverGames"

local function equal(expected, actual, label)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", label or "value", tostring(expected), tostring(actual)), 2)
  end
end

local function near(expected, actual, within, label)
  if math.abs(expected - actual) > within then
    error(string.format("%s: expected %s within %s, got %s", label or "value", tostring(expected), tostring(within), tostring(actual)), 2)
  end
end

local function exists(path)
  local file = io.open(path, "rb")
  if file then
    file:close()
    return true
  end
  return false
end

--- The fake client, with as much of the client's map as the views ask of it: one continent
--- 30000 by 20000 yards from (0, 0), drawn as a map of 1002 by 668 in twelve tiles, and a
--- zone that is its middle third
local function fakeMaps(Client)
  Client.Install()
  ForeverGames = { db = { profile = { sound = false } } }
  local Vector = {}
  Vector.__index = Vector
  function Vector:GetXY()
    return self.x, self.y
  end
  function CreateVector2D(x, y)
    return setmetatable({ x = x, y = y }, Vector)
  end
  Enum = { UIMapType = { Continent = 2, Zone = 3 } }
  local CONTINENT, ZONE, WORLD = 1415, 1429, 947
  local maps = {
    [WORLD] = { name = "Azeroth", parent = 0, left = -60000, top = -40000, width = 120000, height = 80000 },
    [CONTINENT] = { name = "Eastern Kingdoms", parent = WORLD, left = 0, top = 0, width = 30000, height = 20000, type = 2 },
    [ZONE] = { name = "Elwynn Forest", parent = CONTINENT, left = 10000, top = 6666, width = 10000, height = 6666, type = 3 },
  }
  C_Map = {
    GetFallbackWorldMapID = function()
      return WORLD
    end,
    GetMapInfo = function(id)
      local map = maps[id]
      return map and { mapID = id, name = map.name, parentMapID = map.parent, mapType = map.type }
    end,
    GetMapArtLayers = function(id)
      return maps[id] and { { layerWidth = 1002, layerHeight = 668, tileWidth = 256, tileHeight = 256 } } or nil
    end,
    GetMapArtLayerTextures = function(id)
      local textures = {}
      for index = 1, 12 do
        textures[index] = id * 100 + index
      end
      return textures
    end,
    GetWorldPosFromMapPos = function(id, position)
      local map = maps[id]
      return 0, CreateVector2D(map.left + position.x * map.width, map.top + position.y * map.height)
    end,
    GetMapPosFromWorldPos = function(continent, world, id)
      local map = maps[id]
      return id, CreateVector2D((world.x - map.left) / map.width, (world.y - map.top) / map.height)
    end,
    GetMapInfoAtPosition = function(id, x, y)
      if id == CONTINENT and x > 1 / 3 and x < 2 / 3 and y > 1 / 3 and y < 2 / 3 then
        return { mapID = ZONE, name = maps[ZONE].name }
      end
      return { mapID = id, name = maps[id].name }
    end,
    GetMapRectOnMap = function(id, parent)
      return 1 / 3, 2 / 3, 1 / 3, 2 / 3
    end,
    GetMapChildrenInfo = function(id)
      return id == WORLD and { { mapID = CONTINENT, name = maps[CONTINENT].name } } or {}
    end,
    GetMapHighlightInfoAtPosition = function()
      return 0
    end,
  }
  return CONTINENT, ZONE
end

--- The widgets of the window, loaded on their own into a fresh `private`
local function loadWidgets(files)
  local private = { L = setmetatable({}, { __index = function(_, key)
    return key
  end }) }
  for _, file in ipairs(files) do
    assert(loadfile(file))(ADDON_NAME, private)
  end
  return private
end

return function(tests, loadEngine)
  function tests.PlacesDecayIsTheSameCurveAsExp()
    local Places = loadEngine().Places
    for step = 0, 400 do
      local x = step / 20
      near(math.exp(-x), Places.Decay(x), 1e-12 + math.exp(-x) * 1e-9, "e^-" .. x)
    end
    equal(1, Places.Decay(0))
    equal(0, Places.Decay(1000))
  end

  function tests.PlacesScoreFallsAwayWithDistance()
    local Places = loadEngine().Places
    equal(5000, Places.Score(0))
    equal(5000, Places.Score(Places.NEAR), "within a few yards is all of it")
    equal(0, Places.Score(nil), "another continent is nothing")
    near(5000 / math.exp(1), Places.Score(Places.NEAR + Places.SCALE), 1, "a scale out")
    local last = 5001
    for yards = 0, 40000, 250 do
      local score = Places.Score(yards)
      assert(score <= last and score >= 0, "never more for further out, at " .. yards)
      last = score
    end
  end

  function tests.PlacesTravelAsText()
    local Places = loadEngine().Places
    local text = Places.Encode({ continent = 1, x = -8899.4, y = 770.6 })
    equal("1_-8899_771", text)
    local place = Places.Decode(text)
    equal(1, place.continent)
    equal(-8899, place.x)
    equal(771, place.y)
    for _, wrong in ipairs({ "", "1:2:3", "a_1_2", "0_1", "0_999999_1", "0_1_2_3", "-1_2_3" }) do
      equal(nil, Places.Decode(wrong), wrong)
    end
    local Codec = loadEngine().Codec
    assert(Codec.IsSafeField("g" .. text), "a guess goes in a message")
  end

  function tests.PlacesPicksTheSameFromTheSameSeed()
    local private = loadEngine()
    local Places, Random = private.Places, private.Random
    local catalogue = {}
    for index = 1, 20 do
      catalogue[index] = { id = "p" .. index, continent = index % 2, x = index, y = -index }
    end
    local first = Places.Pick(Random.New(42), catalogue, 5)
    local again = Places.Pick(Random.New(42), catalogue, 5)
    local seen = {}
    equal(5, #first)
    for index, place in ipairs(first) do
      equal(place.id, again[index].id, "the same seed deals the same")
      assert(not seen[place.id], "never the same place twice")
      seen[place.id] = true
    end
    local other = Places.Pick(Random.New(43), catalogue, 5)
    local same = true
    for index, place in ipairs(other) do
      same = same and place.id == first[index].id
    end
    assert(not same, "another seed deals otherwise")
    equal(3, #Places.Pick(Random.New(1), catalogue, 99, function(place)
      return place.id == "p1" or place.id == "p2" or place.id == "p3"
    end), "no more than there are")
    equal("p7", Places.Find(catalogue, "p7").id)
  end

  function tests.WhereIsPlayedThroughFivePlaces()
    local private = loadEngine()
    local game, Places = private.Games.Get("where"), private.Places
    local state = game.newState(1, private.Random.New(7), private.Games.Rules(game.options))
    equal(5, #state.places)
    equal(0, state.time)
    local first = private.Where.placeOf(state)
    assert(game.validate(state, 1, "g" .. Places.Encode(first)))
    equal(false, (game.validate(state, 1, "gnowhere")))
    equal(false, (game.validate(state, 1, "x")))
    local event = game.apply(state, 1, "g" .. Places.Encode(first))
    equal(5000, event.points, "spot on")
    equal(2, state.round)
    game.apply(state, 1, "s")
    equal(0, state.guesses[2].points, "no guess")
    local third = private.Where.placeOf(state)
    local elsewhere = (third.continent + 1) % 2
    game.apply(state, 1, "g" .. Places.Encode({ continent = elsewhere, x = third.x, y = third.y }))
    equal(0, state.guesses[3].points, "the wrong continent")
    equal(nil, state.guesses[3].yards)
    equal(nil, game.result(state))
    equal(nil, game.record(state, 30, nil), "nothing to keep before the end")
    local fourth = private.Where.placeOf(state)
    game.apply(state, 1, "g" .. Places.Encode({ continent = fourth.continent, x = fourth.x + 1000, y = fourth.y }))
    assert(state.guesses[4].points > 3000 and state.guesses[4].points < 5000, "a thousand yards out is a good guess")
    game.apply(state, 1, "s")
    equal(1, game.result(state).winner)
    equal(false, (game.validate(state, 1, "s")), "nothing after the last place")
    local record = game.record(state, 120, game.result(state))
    equal("score", record[1].key)
    equal(state.total, record[1].value)
    equal(nil, record[1].lower, "more is better")
    equal(state.total, game.daily.score(state))
  end

  function tests.WhereVersionCountsItsPlaces()
    local private = loadEngine()
    equal(1000 + #private.WherePlaces, private.Games.Get("where").version)
  end

  function tests.RaceIsWonOnPointsByAGameThatSaysSo()
    local private = loadEngine()
    local Race, game = private.Race, private.Games.Get("where")
    assert(Race.Has(game))
    assert(Race.Higher(game))
    equal(false, Race.Higher(private.Games.Get("minesweeper")))
    local more = { run = { "2100000" }, heard = { "1800000" }, told = 1 }
    equal("won", Race.Outcome(more, game), "more points win")
    equal("lost", Race.Outcome(more), "where a time would lose")
    local less = { run = { "1800000" }, heard = { "2100000" }, told = 1 }
    equal("lost", Race.Outcome(less, game))
    equal("drawn", Race.Outcome({ run = { "5" }, heard = { "5" }, told = 1 }, game))
    equal("won", Race.Outcome({ run = { "0" }, heard = { "-" }, told = 1 }, game), "any score beats a run given up")
    equal("21,000", private.Where.points(21000))
    equal("999", private.Where.points(999))
    equal("1,234,567", private.Where.points(1234567))
    equal("string", type(Race.Show(game, 2100000)), "points are shown by the game")
    equal(nil, Race.Show(private.Games.Get("minesweeper"), 100), "a time is shown by the window")
    local state = { places = { "a" }, round = 2, total = 4321, guesses = {} }
    equal(432100, Race.Time(game, state, 99, { winner = 1 }), "raced on its points, not its time")
  end

  function tests.RaceGhostOfMarksKeepsEverySample()
    local Race = loadEngine().Race
    local race = {}
    assert(Race.Sample(race, { marks = true }, 0, "1=0_10_20"))
    assert(Race.Sample(race, { marks = true }, 0, "2=s"))
    assert(Race.Sample(race, { marks = true }, 0.1, "3=1_-5_6"))
    equal(3, race.samples)
    equal("1=0_10_20+2=s+3=1_-5_6", race.trail)
    local timed = {}
    assert(Race.Sample(timed, { every = 1 }, 0, "a"))
    assert(Race.Sample(timed, { every = 1 }, 0.5, "b"))
    equal(1, timed.samples, "a ghost of the clock keeps one a second")
  end

  function tests.WhereCatalogueIsSound()
    local private = { L = setmetatable({}, { __index = function(_, key)
      return key
    end }) }
    assert(loadfile("Engine/Codec.lua"))(ADDON_NAME, private)
    assert(loadfile("Engine/Places.lua"))(ADDON_NAME, private)
    assert(loadfile("Games/Where/Places.lua"))(ADDON_NAME, private)
    local Places, seen = private.Places, {}
    assert(#private.WherePlaces >= 1, "there is somewhere to go")
    for index, place in ipairs(private.WherePlaces) do
      local where = "place " .. index .. " (" .. tostring(place.id) .. ")"
      assert(type(place.id) == "string" and place.id:match("^%l[%l%d]+$"), where .. " has a bad id")
      assert(not seen[place.id], where .. " is there twice")
      seen[place.id] = true
      assert(math.floor(place.continent) == place.continent, where .. " is on no continent")
      local back = Places.Decode(Places.Encode(place))
      assert(back and math.abs(back.x - place.x) <= 0.5 and math.abs(back.y - place.y) <= 0.5, where .. " doesn't travel")
      assert(type(place.mapID) == "number", where .. " has no map")
      local pano = place.pano
      assert(pano.tiles >= 1 and pano.top > 0 and pano.bottom < 0, where .. " has a panorama that doesn't go round")
      for tile = 1, pano.tiles do
        local file = ("ForeverGames_Places/Images/%s_%d"):format(place.id, tile)
        assert(exists(file .. ".blp") or exists(file .. ".tga"), where .. " has no picture " .. file)
      end
    end
  end

  function tests.PanoViewDrawsTheRingInColumnsSideBySide()
    local Client = dofile("Tests/FakeClient.lua")
    Client.Install()
    local private = loadWidgets({ "GUI/Strips.lua", "GUI/PanoView.lua" })
    local view = private.PanoView.New(CreateFrame("Frame"), { columns = 120 })
    view:SetSize(600, 300)
    assert(view:Show({ folder = "x\\", file = "p", tiles = 4, top = 0.6, bottom = -0.4 }, 6.2))
    view.frame:Fire("OnUpdate", 0.5)
    local columns = {}
    for index = 1, view.strips.drawn do
      local piece = view.strips.pieces[index]
      if piece.file then
        columns[#columns + 1] = piece
      end
    end
    assert(#columns >= 120, "a column at least for each")
    near(0, columns[1].left, 1e-9, "from the left edge")
    local crossed = 0
    for index = 2, #columns do
      local before, piece = columns[index - 1], columns[index]
      near(before.left + before.width, piece.left, 1e-6, "column " .. index .. " against the one before")
      if piece.file ~= before.file then
        crossed = crossed + 1
        near(1, before.u1, 1e-9, "a picture to its right edge")
        near(0, piece.u0, 1e-9, "the next from its left")
      else
        near(before.u1, piece.u0, 1e-9, "column " .. index .. " goes on where the one before ended")
      end
    end
    near(600, columns[#columns].left + columns[#columns].width, 1e-6, "to the right edge")
    equal(1, crossed, "across from the last picture to the first")
    -- Taller to the sides than in the middle, as the cylinder is further away there
    assert(columns[1].height > columns[60].height, "the sides are stretched")
  end

  function tests.PanoViewIsntFlungRoundWhereItStartsAgain()
    local Client = dofile("Tests/FakeClient.lua")
    Client.Install()
    local private = loadWidgets({ "GUI/Strips.lua", "GUI/PanoView.lua" })
    local view = private.PanoView.New(CreateFrame("Frame"))
    view:SetSize(600, 300)
    view:Show({ folder = "x\\", file = "p", tiles = 1, top = 0.6, bottom = -0.4 }, 0.02)
    Client.cursor, Client.mouseDown = { 300, 150 }, true
    view.frame:Fire("OnMouseDown", "LeftButton")
    -- Dragged right, which turns the view back across where it starts
    for step = 1, 10 do
      Client.cursor = { 300 + step * 6, 150 }
      view.frame:Fire("OnUpdate", 1 / 60)
    end
    assert(view.yaw > 6, "it went back across the start")
    assert(math.abs(view.speed) < 3, "and is turning as fast as it was dragged, not a turn a frame: " .. view.speed)
    Client.mouseDown = false
    for _ = 1, 600 do
      view.frame:Fire("OnUpdate", 1 / 60)
    end
    equal(0, view.speed, "let go, it comes to rest")
  end

  function tests.MapViewPinsAPlaceOnWhicheverMapIsShown()
    local Client = dofile("Tests/FakeClient.lua")
    local continent, zone = fakeMaps(Client)
    local private = loadWidgets({ "GUI/Widgets.lua", "GUI/Viewport.lua", "GUI/MapView.lua" })
    local clicked
    local map = private.MapView.New(CreateFrame("Frame"), { map = continent, onClick = function(place)
      clicked = place
    end })
    map:SetSize(600, 400)
    map:Show(continent)
    local place = { continent = 0, x = 15000, y = 10000 }
    map:SetPin("guess", { place = place, color = { 1, 0, 0 }, size = 12 })
    near(0.5, map.pins.guess.x, 1e-9, "in the middle of the continent")
    map:Show(zone)
    near(0.5, map.pins.guess.x, 1e-9, "and of the zone in its middle")
    map:SetPin("far", { place = { continent = 0, x = 1000, y = 1000 }, color = { 1, 1, 1 }, size = 12 })
    equal(nil, map.pins.far.x, "off the zone, not shown")
    -- A click in the middle of the zone is the middle of the continent
    Client.cursor = { 300, map.frame:GetTop() - 200 }
    map.frame:Fire("OnMouseUp", "LeftButton")
    assert(clicked, "the click came through")
    near(15000, clicked.x, 20, "across")
    near(10000, clicked.y, 20, "down")
    map:Line("guess", "far", { 1, 1, 1 })
    map:Frame({ place, { continent = 0, x = 16000, y = 11000 } })
    equal(continent, map.mapID, "two places on a continent are framed on its map")
    map:Clear()
    equal(nil, next(map.pins))
  end

  function tests.WhereViewPlaysAPlaceThroughToItsReveal()
    local Client = dofile("Tests/FakeClient.lua")
    local continent = fakeMaps(Client)
    local private = loadEngine()
    for _, file in ipairs({ "GUI/Widgets.lua", "GUI/Effects.lua", "GUI/Viewport.lua", "GUI/Strips.lua", "GUI/PanoView.lua",
      "GUI/MapView.lua", "Games/Where/View.lua" }) do
      assert(loadfile(file))(ADDON_NAME, private)
    end
    local game = private.Games.Get("where")
    local state = game.newState(1, private.Random.New(3), private.Games.Rules(game.options))
    local submitted, sampled = {}, {}
    local shown = { match = { id = "m1" }, state = state, canMove = true, live = true,
      submit = function(move)
        submitted[#submitted + 1] = move
      end,
      sample = function(text)
        sampled[#sampled + 1] = text
        return true
      end }
    local stage = CreateFrame("Frame")
    local view = game.createView(stage)
    view:Layout(900, 560)
    view:Update(shown)
    equal(1, view.round)
    -- Pinned right on the place, and guessed
    local place = private.Where.placeOf(state)
    view:pinAt(place)
    view:guess()
    equal("g" .. private.Places.Encode(place), submitted[1])
    equal("1=" .. private.Places.Encode(place), sampled[1], "the guess goes in the ghost")
    game.apply(state, 1, submitted[1])
    view:Update(shown)
    equal(1, view.revealed, "the guess is shown")
    assert(view.reveal:IsShown())
    view.animator:Stop()
    view:onward()
    equal(2, view.round, "on to the next place")
    -- Nothing pinned: no guess
    view:guess()
    equal("s", submitted[2])
    equal(continent ~= nil, true)
  end
end
