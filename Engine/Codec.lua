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
--   WHO:id:seat:name[:seat:name...]       the players an INV had no room left for
--   ACC:id                                accept a challenge
--   DEC:id[:reason]                       decline / cancel a challenge
--   MOV:id:n:total:entry                  entry n of the match log, sender has `total` entries
--   ACK:id:n                              sender has n log entries
--   SYN:id:n                              sender has n log entries and wants whatever it is missing

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
--- @field seats number? How many are playing, in a challenge to a match of more than two
--- @field mine number? Seat of whoever the challenge is sent to
--- @field names table<number, string>? Full player names by seat
--- @field reason string?
--- @field n number?
--- @field total number?
--- @field entry string?

local FIELD = "^[%w%-%+%.=!_]+$"

--- Whether a string can be used as a field (ids, game ids and log entries) without escaping
--- @param value any
--- @return boolean
function Codec.IsSafeField(value)
  return type(value) == "string" and value:match(FIELD) ~= nil
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
    if fields[7] then
      message.seats, message.mine, message.names = toCount(fields[7]), toCount(fields[8]), toNames(fields, 9)
      if not message.seats or not message.mine or not message.names then
        return nil
      end
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
    if not message.n or message.n < 1 or not message.total or not Codec.IsSafeField(message.entry) then
      return nil
    end
  elseif messageType == "ACK" or messageType == "SYN" then
    message.n = toCount(fields[4])
    if not message.n then
      return nil
    end
  else
    return nil
  end

  return message
end
