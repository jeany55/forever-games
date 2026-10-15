--------------------------
--  Daily
--------------------------
-- Today's challenge: a game for one that everyone in the guild is dealt the same way, every day
-- another. A game opts in with `daily` (GameDefinition): the rules everyone plays the day's game
-- by, and what it comes to once it is over. The day's match takes its chance from the date and
-- the game instead of from its own id (Engine/Match.lua), so whoever plays Solitaire today is
-- dealt the same cards in the same order, and the same moves turn up the same ones from the
-- stock. Each player gets one go at it a day, played through without taking anything back:
-- whoever could take a move back could look at what it turned up and try another.
--
-- What everyone made of it goes round the guild, the way Presence does, and makes a board for
-- the day:
--
--   DAY:date:game:score     the sender's own result at that day's game: a whole number, or "-"
--                           for one that was over without coming to anything (a field that blew
--                           up). Said on the guild channel once it is over, and whispered to
--                           whoever asks
--   DAYS:date               on the guild channel: what did everyone make of that day's games?
--                           Whoever played any of them answers with a DAY for each
--
-- A day is a day in UTC, so that it begins at the same moment for the whole guild, whatever the
-- realm's time. Nobody checks a result against the moves that led to it, which between guildies
-- is what a game here does: it takes their word for it.
--
-- Like the session, nothing in here touches the WoW API.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- What a game for one is like as the day's challenge
--- @class GameDaily
--- @field rules table<string, any>? What its options are set to for everyone, by id. The usual rules if left out
--- @field score fun(state: table, seconds: number, result: MatchResult): number? What a day's game came to once it is over: points, or the seconds it took. nil for one that came to nothing, as a field that blew up
--- @field lower boolean? Less is better: a time
--- @field time boolean? The score is in seconds, and shown as a time

--- @class DailyEnv
--- @field me string Full name of the local player
--- @field now fun(): number
--- @field today fun(): string The date in UTC, "2026-10-14"
--- @field broadcast fun(text: string) Sends to the player's guild, does nothing without one
--- @field whisper fun(target: string, text: string)
--- @field boards table<string, table<string, table<string, number|false>>>? What everyone made of each day's games, by date, game id and player: a score, or false for nothing. Persisted. Forgotten with the session if left out
--- @field onChange fun() Something new came in

--- @class DailyEntry
--- @field name string Full player name
--- @field score number|false
--- @field place number? Where it puts them, the best first. nil for nothing

--- @class Daily
--- @field env DailyEnv
--- @field asked table<string, number> When each day's board was last asked for
--- @field answered table<string, number> When each player was last answered, by name and date
local Daily = {}
Daily.__index = Daily
private.Daily = Daily

local Codec = private.Codec
local Games = private.Games

local DAY = private.Codec.PROTOCOL_VERSION .. ":DAY:"
local DAYS = private.Codec.PROTOCOL_VERSION .. ":DAYS:"
local NOTHING = "-"
-- Shortest time between two askings for the same day's board, and between two answers to the
-- same player about the same day
local ASK_COOLDOWN = 60
local ANSWER_COOLDOWN = 30
-- Days of boards that are kept, today's included
local KEEP_DAYS = 7
-- The highest score that is taken: more than any game comes to
local MOST = 999999999

-----------------------------
-- The day's game
-----------------------------

--- Whether a game has a challenge every day
--- @param game GameDefinition?
--- @return boolean
function Daily.Has(game)
  return game ~= nil and game.daily ~= nil and Games.CanSeat(game, 1)
end

--- The games that have a challenge every day, in the order they were registered
--- @return GameDefinition[]
function Daily.Games()
  local list = {}
  for _, game in ipairs(Games.List()) do
    if Daily.Has(game) then
      list[#list + 1] = game
    end
  end
  return list
end

--- What a day's game takes its chance from (Engine/Random.lua): the same for everyone that day
--- @param gameId string
--- @param date string
--- @return string
function Daily.Seed(gameId, date)
  return "daily:" .. gameId .. ":" .. date
end

--- Whether some text is a date the way Daily writes them
--- @param text string?
--- @return boolean
function Daily.IsDate(text)
  return type(text) == "string" and text:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil
end

--- What a day's game that is over came to
--- @param game GameDefinition
--- @param state table
--- @param seconds number It was played for
--- @param result MatchResult
--- @return number|false score A whole number, false for nothing
function Daily.Score(game, state, seconds, result)
  local score = game.daily.score(state, seconds, result)
  if type(score) ~= "number" or score ~= score then
    return false
  end
  return math.max(0, math.min(MOST, math.floor(score + 0.5)))
end

--- Whether one score is better than another at a game
--- @param game GameDefinition
--- @param a number|false
--- @param b number|false
--- @return boolean
function Daily.Better(game, a, b)
  if a == false or b == false then
    return a ~= false and b == false
  end
  if game.daily.lower then
    return a < b
  end
  return a > b
end

-----------------------------
-- The board
-----------------------------

--- @param env DailyEnv
--- @return Daily
function Daily.New(env)
  env.boards = env.boards or {}
  return setmetatable({ env = env, asked = {}, answered = {} }, Daily)
end

--- @param score number|false
--- @return string
local function written(score)
  return score == false and NOTHING or tostring(score)
end

--- @param date string
--- @param gameId string
--- @param name string
--- @param score number|false
--- @return boolean changed
function Daily:note(date, gameId, name, score)
  local day = self.env.boards[date] or {}
  self.env.boards[date] = day
  local board = day[gameId] or {}
  day[gameId] = board
  if board[name] == score then
    return false
  end
  board[name] = score
  return true
end

--- The local player is done with a day's game: it goes on their board, and round the guild
--- @param date string
--- @param gameId string
--- @param score number|false
function Daily:Post(date, gameId, score)
  self:note(date, gameId, self.env.me, score)
  self.env.broadcast(DAY .. date .. ":" .. gameId .. ":" .. written(score))
  self.env.onChange()
end

--- Asks the guild what they made of a day's games, unless that was asked a moment ago
--- @param date string
--- @return boolean asked
function Daily:Ask(date)
  local now = self.env.now()
  if self.asked[date] and now - self.asked[date] < ASK_COOLDOWN then
    return false
  end
  self.asked[date] = now
  self.env.broadcast(DAYS .. date)
  return true
end

--- Handles a received payload if it is about the day's games
--- @param sender string Full player name
--- @param text string
--- @return boolean handled False if the payload isn't about them
function Daily:Handle(sender, text)
  if text:sub(1, #DAYS) == DAYS then
    local date = text:sub(#DAYS + 1)
    if sender ~= self.env.me and Daily.IsDate(date) then
      self:answer(sender, date)
    end
    return true
  elseif text:sub(1, #DAY) ~= DAY then
    return false
  end
  if sender == self.env.me then
    return true
  end
  local date, gameId, value = text:sub(#DAY + 1):match("^([^:]+):([^:]+):([^:]+)$")
  local game = gameId and Games.Get(gameId)
  if not Daily.IsDate(date) or not Daily.Has(game) then
    return true
  end
  local score = false
  if value ~= NOTHING then
    score = tonumber(value)
    if not score or score ~= math.floor(score) or score < 0 or score > MOST or not value:match("^%d+$") then
      return true
    end
  end
  if self:note(date, gameId, sender, score) then
    self.env.onChange()
  end
  return true
end

--- Tells somebody who asked what the local player made of a day's games
--- @param name string
--- @param date string
function Daily:answer(name, date)
  local key, now = name .. "@" .. date, self.env.now()
  if self.answered[key] and now - self.answered[key] < ANSWER_COOLDOWN then
    return
  end
  self.answered[key] = now
  local day = self.env.boards[date] or {}
  for _, game in ipairs(Daily.Games()) do
    local mine = day[game.id] and day[game.id][self.env.me]
    if mine ~= nil and Codec.IsSafeField(game.id) then
      self.env.whisper(name, DAY .. date .. ":" .. game.id .. ":" .. written(mine))
    end
  end
end

--- Everyone's result at a day's game, the best first and then whoever came to nothing. Players
--- with the same score have the same place
--- @param date string
--- @param gameId string
--- @return DailyEntry[]
function Daily:Board(date, gameId)
  local game = Games.Get(gameId)
  local board = self.env.boards[date] and self.env.boards[date][gameId] or {}
  local entries = {}
  for name, score in pairs(board) do
    entries[#entries + 1] = { name = name, score = score }
  end
  table.sort(entries, function(a, b)
    if a.score ~= b.score and game and game.daily then
      return Daily.Better(game, a.score, b.score)
    end
    return a.name < b.name
  end)
  for index, entry in ipairs(entries) do
    if entry.score ~= false then
      local before = entries[index - 1]
      entry.place = (before and before.score == entry.score) and before.place or index
    end
  end
  return entries
end

--- The local player's result at a day's game
--- @param date string
--- @param gameId string
--- @return number|false|nil score nil if they haven't played it
function Daily:Mine(date, gameId)
  local day = self.env.boards[date]
  return day and day[gameId] and day[gameId][self.env.me]
end

--- Which day a date is, counted from long ago: one more for every day after
--- @param date string
--- @return number
local function dayOf(date)
  local year, month, day = date:match("^(%d+)%-(%d+)%-(%d+)$")
  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  -- From March, so that the day a leap year has on top comes last
  if month <= 2 then
    year = year - 1
  end
  local era = math.floor(year / 400)
  local ofEra = year - era * 400
  local ofYear = math.floor((153 * ((month + 9) % 12) + 2) / 5) + day - 1
  local ofCycle = ofEra * 365 + math.floor(ofEra / 4) - math.floor(ofEra / 100) + ofYear
  return era * 146097 + ofCycle
end

--- Forgets the boards of the days long gone, and of any day that hasn't come yet
function Daily:Prune()
  local today = dayOf(self.env.today())
  for date in pairs(self.env.boards) do
    local day = Daily.IsDate(date) and dayOf(date)
    if not day or day > today or today - day >= KEEP_DAYS then
      self.env.boards[date] = nil
    end
  end
end
