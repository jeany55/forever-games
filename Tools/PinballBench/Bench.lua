-- The bench's own table of strings, which the game's Locales/enUS.lua fills in place of Forever
-- Games' locale
local _, ns = ...
ns.L = {}
-- The game's files find their table as private.Pinball: here that is the bench's own
ns.Pinball = ns
