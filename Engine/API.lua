--------------------------
--  The engine, for addons of their own
--------------------------
-- A game needn't be part of Forever Games. An addon of its own can bring one, and it is offered,
-- played, raced and kept exactly like the games that come with it, without Forever Games knowing
-- of it beforehand. ForeverGames_Freedoom and ForeverGames_Where are two, and API.md says how to
-- write another.
--
-- The addon says it needs Forever Games (`## Dependencies: ForeverGames` in its .toc), so the
-- client loads it afterwards, and once Forever Games is loaded this is there for it as the global
-- ForeverGamesAPI: the parts of the engine the games here are written with, and the registry to
-- put a game in. Whatever is registered by the time the player logs in is offered with the rest.
--
-- Only the parts a game is written with are here, the same ones as the games in Games/ use. What
-- runs the addon itself (the matches the player has, the window, the messages between players)
-- is the engine's business and not for a game to reach into.

--- @type nil, ForeverGamesPrivate
local _, private = ...

-- The parts there are, by the name they have on the engine. Each is looked up when it is asked
-- for, not copied, so a part loaded later (the GUI's, in the tests) is there all the same
local PARTS = {}
for _, name in ipairs({
  -- The rules side (Engine/), none of which touches the game client
  "Games", "Rooms", "Codec", "Random", "Tables", "Grid", "Deck", "Bones", "Phases", "Computer", "Race", "Lexicon",
  "SectorMap", "Actors", "Course", "Places", "Physics", "LightShow",
  -- The view side (GUI/): widgets, and what boards, cards and maps are drawn with
  "Widgets", "Lettering", "Effects", "Dice", "SlideGrid", "NumberGrid", "Board", "Heaps", "Cards", "CardTable", "Dominoes", "Felt",
  "Viewport", "Drag", "Tiles", "Canvas", "Strips", "SectorView", "PanoView", "MapOverlays", "MapView", "TerrainView",
  "DotMatrix",
  -- The locale, the log and the addon's icon
  "L", "Log", "ICON",
}) do
  PARTS[name] = true
end

--- @class ForeverGamesAPI
--- @field version number Goes up by one whenever something here changes so that an addon written for it before would no longer work. Check it is what yours was written for
--- @field Games Games The registry: Games.Register puts a game in it
--- @field Rooms Rooms Games played at a party, a room at a time: Rooms.Register
--- @field L table<string, string> The strings shown to the players, yours among them once they are added (API.Locale)
--- @field Log (fun(...: any))? Adds a line to the addon's own log, saved with its settings and shown by /fg log
local API = { version = 1 }

--- Somewhere to put a game's strings, among Forever Games' own: what the game is called, how it
--- is played and whatever its view says. Write them all straight after asking for it, before
--- asking again, the way AceLocale has it.
---
--- English (`isDefault`) is shown wherever a language has nothing of its own. A string that is
--- there already is never written over by a default, so begin the names of yours with the game's id.
--- @param locale string "enUS", "deDE"...
--- @param isDefault boolean? This is the language to fall back on
--- @return table<string, string|true>? Nil for a language that isn't the client's, there is no need for it
function API.Locale(locale, isDefault)
  local AceLocale = LibStub and LibStub("AceLocale-3.0", true)
  if AceLocale then
    return AceLocale:NewLocale(private.ADDON_NAME, locale, isDefault, true)
  end
  -- The tests' locale hands back the key it is asked for, so there is nothing to keep
  return isDefault and {} or nil
end

-- What games keep of their settings while there is nowhere to save them: in the tests, and
-- before the addon has read its saved variables
local unsaved = {}

--- Somewhere for a game to keep the player's settings for it: a choice it remembers from one game
--- to the next. Saved with the addon's own settings. Ask for it when it is wanted rather than as
--- the file loads, which is before the addon has read what was saved
--- @param id string The game's id
--- @return table
function API.Settings(id)
  local addon = ForeverGames
  local profile = addon and addon.db and addon.db.profile
  if not profile then
    unsaved[id] = unsaved[id] or {}
    return unsaved[id]
  end
  profile.settings = profile.settings or {}
  profile.settings[id] = profile.settings[id] or {}
  return profile.settings[id]
end

--- Whether the player wants to hear the games, as the addon's options have it. A game that plays
--- sounds of its own asks before every one
--- @return boolean
function API.SoundOn()
  local addon = ForeverGames
  return not (addon and addon.db) or addon.db.profile.sound == true
end

-- The parts are read through to, and nothing else is to be put in
setmetatable(API, {
  __index = function(_, name)
    if PARTS[name] then
      return private[name]
    end
  end,
  __newindex = function(_, name)
    error("ForeverGamesAPI is the engine's: keep " .. tostring(name) .. " in a table of your own", 2)
  end,
})

ForeverGamesAPI = API
