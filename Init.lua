--------------------------
--  Forever Games
--------------------------
--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class ForeverGamesPrivate
--- @field ADDON_NAME string
--- @field L table<string, string> Localized strings
--- @field Codec Codec
--- @field Games Games
--- @field Match MatchModel
--- @field Session Session Session class, the running instance is private.session
--- @field session Session
--- @field Presence Presence Presence class, the running instance is private.presence
--- @field presence Presence
--- @field Widgets Widgets
--- @field Wizard Wizard
--- @field Transport Transport
--- @field Toast Toast
--- @field MainFrame MainFrame
private.ADDON_NAME = "ForeverGames"
private.ICON = "Interface\\Icons\\INV_Misc_Dice_01"
private.L = LibStub("AceLocale-3.0"):GetLocale(private.ADDON_NAME)

-----------------------------
-- Log
-----------------------------
-- A rolling record of what was sent, received and noticed, kept in the saved variables so a
-- session can be looked at afterwards. It is written to disk on logout or /reload.

local LOG_SIZE = 600
local entries = {}

--- Adds a line to the log. Arguments are joined with spaces.
--- @param ... any
function private.Log(...)
  entries[#entries + 1] = date("%m-%d %H:%M:%S") .. " " .. table.concat({ tostringall(...) }, " ")
  while #entries > LOG_SIZE do
    table.remove(entries, 1)
  end
end

--- Continues the log in a saved table, keeping what was logged before the saved data was loaded
--- @param stored string[]
function private.UseLog(stored)
  for _, entry in ipairs(entries) do
    stored[#stored + 1] = entry
  end
  entries = stored
  while #entries > LOG_SIZE do
    table.remove(entries, 1)
  end
end

--- @return string[]
function private.LogEntries()
  return entries
end
