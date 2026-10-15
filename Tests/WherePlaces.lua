-- Places for the tests to deal Where in Azeroth from, in place of the real catalogue
-- (Games/Where/Places.lua), which may have only a few in it: a dozen made up, on both continents.

--- @type nil, ForeverGamesPrivate
local _, private = ...

local places = {}
for index = 1, 12 do
  places[index] = {
    id = "test" .. index,
    continent = index % 2,
    x = -9000 + index * 1234.5,
    y = 2000 - index * 777.25,
    mapID = 1400 + index,
    pano = { tiles = 4, width = 4096, height = 1024, top = 0.6, bottom = -0.4, sky = { 0.5, 0.6, 0.7 }, ground = { 0.2, 0.2, 0.1 } },
  }
end
private.WherePlaces = places
