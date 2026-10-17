--------------------------
--  Wire format
--------------------------
-- Every addon message is a single line of colon separated fields:
--   <protocol version>:<type>:<match id>[:<field>...]
-- Player names never travel in the payload, the sender comes from the chat event.
--
--   INV:id:game:gameVersion:inviterSeat   challenge someone to a match
--   INV:id:game:gameVersion:inviterSeat:seats:yourSeat[:seat:name...]
--                                         the same for a match of more than two: how many are
--                                         playing, where the receiver sits and who else sits where
--   Either may say how the rules are set, where that isn't the way the game is usually played:
--   a field of its own right after inviterSeat, "lore=10+bingo=100" (see Games.EncodeOptions).
--   It is the one field there with a "=" in it. The seats the computer plays at a table of
--   people go there as well, with how well it plays each: "lore=10+_c=2hard.5hard". A client
--   from before the computer could sit with people doesn't know that rule, and turns the
--   challenge down as being from another version
--   WHO:id:seat:name[:seat:name...]       the players an INV had no room left for
--   ACC:id                                accept a challenge
--   DEC:id[:reason]                       decline / cancel a challenge
--   MOV:id:n:total:entry                  entry n of the match log, sender has `total` entries
--   ACK:id:n                              sender has n log entries
--   SYN:id:n                              sender has n log entries and wants whatever it is missing
--   In a game played together (GameDefinition.together) each of the three ends with one more
--   field, a number that stands for the log up to there (Match.Digest): the entries before
--   entry n for MOV, the n entries for ACK and SYN. There an ACK also answers an entry rather
--   than counting them all: the sender has the same first n entries
--   ASK:id:game:gameVersion               ask whoever linked a game in chat to play it. The id is
--                                         the asker's, and what the challenge that answers it is
--                                         called, a challenge (INV) to a game for two or a race
--                                         (RAC) to a game for one. A DEC with that id says there
--                                         is no game to be had: "closed", or "taken" by the asker
--                                         already
--   RAC:id:game:gameVersion[:rules]       challenge someone to race a game for one: each plays the
--                                         same deal of it alone, the one the id deals, and the
--                                         quicker wins (Engine/Race.lua). The rules are written as
--                                         in an INV, and it is answered with ACC or DEC like one
--   In a race MOV, ACK and SYN are about the sender's run of it, which is all the two of them
--   tell each other: MOV is entry n of it (how long it took, then its ghost), and ACK and SYN say
--   how much of the other one's run the sender has

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class Codec
local Codec = {}
private.Codec = Codec

Codec.PROTOCOL_VERSION = 1
-- Addon messages are capped at 255 bytes
Codec.MAX_LENGTH = 255

--- @class Message
--- @field type string
--- @field id string Match id
--- @field game string?
--- @field gameVersion number?
--- @field seat number?
--- @field options string? How the rules are set in a challenge, as it was sent
--- @field computers table<number, string>? The seats the computer plays in a challenge, with the level it plays each at
--- @field seats number? How many are playing, in a challenge to a match of more than two
--- @field mine number? Seat of whoever the challenge is sent to
--- @field names table<number, string>? Full player names by seat
--- @field reason string?
--- @field n number?
--- @field total number?
--- @field entry string?
--- @field digest number? What the sender's log comes to up to where the message is about, in a game played together

local FIELD = "^[%w%-%+%.=!_]+$"

--- Whether a string can be used as a field (ids, game ids and log entries) without escaping
--- @param value any
--- @return boolean
function Codec.IsSafeField(value)
  return type(value) == "string" and value:match(FIELD) ~= nil
end

-- How the seats the computer plays are written among the rules of a challenge
local COMPUTERS = "_c="

--- Writes the seats the computer plays down for a challenge: "_c=2hard.5hard"
--- @param computers table<number, string>? Levels by seat
--- @return string? nil if it plays none
function Codec.EncodeComputers(computers)
  local seats = {}
  for seat in pairs(computers or {}) do
    seats[#seats + 1] = seat
  end
  if #seats == 0 then
    return nil
  end
  table.sort(seats)
  for index, seat in ipairs(seats) do
    seats[index] = seat .. computers[seat]
  end
  return COMPUTERS .. table.concat(seats, ".")
end

--- @param text string What follows "_c="
--- @return table<number, string>? nil if it doesn't read right
local function toComputers(text)
  local computers = {}
  for part in text:gmatch("[^.]+") do
    local seat, level = part:match("^(%d+)(%a+)$")
    seat = tonumber(seat)
    if not seat or seat < 1 or computers[seat] then
      return nil
    end
    computers[seat] = level
  end
  return next(computers) and computers or nil
end

--- @param type string
--- @param id string
--- @param ... string|number
--- @return string
function Codec.Encode(type, id, ...)
  local parts = { Codec.PROTOCOL_VERSION, type, id }
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring((select(i, ...)))
  end
  return table.concat(parts, ":")
end

--- @param value string?
--- @return number?
local function toCount(value)
  local number = tonumber(value)
  if number and number >= 0 and number == math.floor(number) then
    return number
  end
  return nil
end

--- Reads "seat:name" pairs from the end of a message
--- @param fields string[]
--- @param first number Index of the first seat
--- @return table<number, string>? names nil if they don't pair up
local function toNames(fields, first)
  local names = {}
  for index = first, #fields, 2 do
    local seat, name = toCount(fields[index]), fields[index + 1]
    if not seat or seat < 1 or not name or names[seat] then
      return nil
    end
    names[seat] = name
  end
  return names
end

--- Parses a received payload. Returns nil for anything malformed or from another protocol version,
--- remote input is never trusted to be well formed.
--- @param text string
--- @return Message?
function Codec.Decode(text)
  if type(text) ~= "string" or #text > Codec.MAX_LENGTH then
    return nil
  end

  local fields = {}
  for field in text:gmatch("[^:]+") do
    fields[#fields + 1] = field
  end

  if tonumber(fields[1]) ~= Codec.PROTOCOL_VERSION then
    return nil
  end

  local messageType, id = fields[2], fields[3]
  if not Codec.IsSafeField(id) then
    return nil
  end

  local message = { type = messageType, id = id }
  if messageType == "INV" then
    message.game = fields[4]
    message.gameVersion = toCount(fields[5])
    message.seat = toCount(fields[6])
    if not Codec.IsSafeField(message.game) or not message.gameVersion or not message.seat then
      return nil
    end
    if fields[7] and fields[7]:find("=", 1, true) then
      local rules = {}
      for part in table.remove(fields, 7):gmatch("[^+]+") do
        if part:sub(1, #COMPUTERS) == COMPUTERS then
          message.computers = toComputers(part:sub(#COMPUTERS + 1))
          if not message.computers then
            return nil
          end
        else
          rules[#rules + 1] = part
        end
      end
      message.options = #rules > 0 and table.concat(rules, "+") or nil
    end
    if fields[7] then
      message.seats, message.mine, message.names = toCount(fields[7]), toCount(fields[8]), toNames(fields, 9)
      if not message.seats or not message.mine or not message.names then
        return nil
      end
    end
  elseif messageType == "ASK" or messageType == "RAC" then
    message.game = fields[4]
    message.gameVersion = toCount(fields[5])
    if not Codec.IsSafeField(message.game) or not message.gameVersion then
      return nil
    end
    -- A race says how the rules are set the way a challenge does, in the one field with a "="
    if messageType == "RAC" and fields[6] and fields[6]:find("=", 1, true) then
      message.options = fields[6]
    end
  elseif messageType == "WHO" then
    message.names = toNames(fields, 4)
    if not message.names or not next(message.names) then
      return nil
    end
  elseif messageType == "ACC" then
    return message
  elseif messageType == "DEC" then
    message.reason = fields[4]
  elseif messageType == "MOV" then
    message.n = toCount(fields[4])
    message.total = toCount(fields[5])
    message.entry = fields[6]
    message.digest = toCount(fields[7])
    if not message.n or message.n < 1 or not message.total or not Codec.IsSafeField(message.entry) then
      return nil
    end
  elseif messageType == "ACK" or messageType == "SYN" then
    message.n = toCount(fields[4])
    message.digest = toCount(fields[5])
    if not message.n then
      return nil
    end
  else
    return nil
  end

  return message
end
