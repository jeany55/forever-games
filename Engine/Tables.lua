--------------------------
--  Tables
--------------------------
-- Copies of tables, for any game: a whole position to play a move on without touching the one it
-- came from, or what a seat may see of it with the rest blanked out. One copy for everybody, so
-- that a position copied by the computer, by a game's `visible` or by a game for itself comes out
-- the same.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class Tables
local Tables = {}
private.Tables = Tables

--- @param value any
--- @param made table<table, table> What has been copied so far, by original
--- @return any
local function copyOf(value, made)
  if type(value) ~= "table" then
    return value
  end
  local done = made[value]
  if done then
    return done
  end
  local result = {}
  made[value] = result
  for key, inner in pairs(value) do
    result[key] = copyOf(inner, made)
  end
  return setmetatable(result, getmetatable(value))
end

--- A copy of a table and of every table in it, down to the last. What one part of it shares with
--- another, the copy shares in the same way, and a table that reads through to another
--- (Computer.Over) still does. Anything that isn't a table is handed back as it is
--- @generic T
--- @param value T
--- @return T
function Tables.Copy(value)
  return copyOf(value, {})
end

--- A copy of a table that shares every table in it with the original: for a position of which
--- only a few parts are changed, each of them replaced rather than changed in place
--- @generic T: table
--- @param source T
--- @return T
function Tables.Shallow(source)
  local result = {}
  for key, value in pairs(source) do
    result[key] = value
  end
  return result
end
