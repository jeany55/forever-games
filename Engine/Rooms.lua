--------------------------
--  Rooms
--------------------------
-- For the games that are played by whoever turns up: a room is opened, people come and go, and
-- nothing of it is kept once it is over. That is the opposite of a match in nearly every way, so
-- it is no match: there is no log to agree on and nothing is offered again until it arrives. What
-- is said in a room is said once, and whoever misses it has missed it.
--
-- A room is opened by a host, for their guild or for the group they are in, and everything said
-- in it is said on that channel: one message reaches everyone, however many they are. The host
-- can also ask in a few players who aren't on the channel, or open a room for nobody but those.
-- Such a guest only ever talks to the host, who passes on to the channel what the guest said
-- and to the guest what was said on the channel. That costs the host a whisper for every guest
-- and every message, which is why there can only be a few of them.
--
--   WHO                          on a channel: which rooms are there?
--   OPEN:game:version:channel:invited
--                                there is this room. On its channel when it is opened, whispered
--                                to whoever asked WHO and to a player the host wants in it
--   JOIN:heard:version           to the host: let me in. `heard` is 1 if the room was heard of on
--                                its channel, which is how the host knows the player is on it
--   KNOCK:0:version:game         to the host, with 0 for the room: let me into your room of this
--                                game. Sent by clicking a link to it in chat (Links.lua), which
--                                lets in whoever clicks it, the way being asked in does
--   NO:reason                    from the host: you can't come in
--   WELCOME:n:route:game:channel from the host: you are in, as member n. Route is "c" for a
--                                member who talks on the channel and "d" for a guest
--   IN:n:name:score[:n:name:score...]
--                                from the host: these are in the room. The host is member 1
--   OUT:n                        member n has left, said by themselves or by the host
--   SHUT                         from the host: the room is closed
--   VIA:n:...                    from the host: what member n said, passed on
--
-- Everything else belongs to the game played in the room, which is handed whatever a member says
-- that the room doesn't know (see PartyGame). A game gets to know its own messages the same way
-- as everybody else's, so it only says how to take a message, never how to send one.
--
-- The client only lets through so many addon messages a second. Whatever is to be sent waits in
-- line for its turn, and there are three lines: what the game can't do without goes first, then
-- what is happening right now (the line being drawn), then what somebody asked to be told again.
--
-- Like the session, nothing in here touches the WoW API.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class RoomsEnv
--- @field me string Full name of the local player
--- @field now fun(): number Seconds, as finely as the client can tell
--- @field random fun(max: number): number
--- @field broadcast fun(channel: RoomChannel, text: string): boolean Returns false if it could not be sent right now
--- @field send fun(target: string, text: string): boolean
--- @field onChannel fun(channel: RoomChannel): boolean Whether the local player has that channel: is in a guild, is in a group
--- @field reaches fun(channel: RoomChannel, name: string): boolean Whether what is said on a channel gets to this player
--- @field named (fun(name: string): string?)? The full name of a player named in what somebody sent, which may be written differently from how this client writes it. As it is if left out
--- @field namedMe (fun(name: string))? Somebody sent the player's own name, the way they write it
--- @field notify fun(event: string, subject: any) "open" with a RoomInfo, "refused" with a reason, "joined", "roster", "changed" and "closed" with the room

--- @alias RoomChannel "GUILD"|"GROUP"

--- @class RoomMember
--- @field n number What the host calls them, never given to anyone else
--- @field name string Full player name
--- @field score number
--- @field direct boolean? Known to the host only: a guest, who has to be whispered
--- @field away boolean? Known to the host only: didn't answer when it was their turn

--- A room somebody else opened, as far as is known of it
--- @class RoomInfo
--- @field id string
--- @field host string Full player name
--- @field game string
--- @field version number
--- @field channel RoomChannel?
--- @field invited boolean The host asked for this player
--- @field onChannel boolean It was heard of on its channel
--- @field heard number

--- A game for a room
--- @class PartyGame
--- @field id string Unique id sent over the wire, letters and digits only
--- @field name string
--- @field description string?
--- @field icon string?
--- @field version number Bump when its messages change, players on different versions can't share a room
--- @field lanes table<string, number>? Which line a kind of message waits in, 1 if it isn't named
--- @field options GameOption[]? What whoever opens a room can set, as a game played at its own pace has them (Engine/Games.lua)
--- @field new fun(room: Room, rules: table<string, any>?): table What the game keeps about a room, from when it is opened or joined. Whoever opened it is given how they set it up
--- @field status (fun(room: Room): string?, boolean?)? How the game stands, in a few words for the header over it, and whether that is the player's to do something about
--- @field receive fun(room: Room, member: RoomMember, kind: string, fields: string[]) A member said something. Also called for what the local player said
--- @field tick (fun(room: Room, now: number))? Called several times a second
--- @field welcome (fun(room: Room, member: RoomMember))? On the host: somebody came in and has to be told where the game is, see Room.Tell
--- @field left (fun(room: Room, member: RoomMember))? Somebody left
--- @field busy (fun(room: Room): boolean)? Whether the game needs the player's whole attention right now: a window that was made small is made big for as long
--- @field mark (fun(room: Room, member: RoomMember): string?, string?)? How a member stands out in the list of who is in the room: "gold" or "green", and a few characters to put next to what they have
--- @field view (fun(parent: any): table)? Builds what shows it, see GUI/Party.lua
--- @field fight (fun(room: Room, fighting: boolean))? The local player went into combat, or came out of it
--- @field calm boolean? Keeps out of the way of a fight: its small window is hidden while the player is in combat

--- @class Room
--- @field id string
--- @field game string
--- @field host string Full player name
--- @field channel RoomChannel?
--- @field me number The local player's member number
--- @field direct boolean? The local player is a guest
--- @field members table<number, RoomMember>
--- @field count number
--- @field state table The game's
--- @field invited table<string, boolean>? On the host: who was asked in
--- @field linked boolean? On the host: there is a link to it in chat, and whoever clicks it gets in
--- @field nextN number? On the host: the number the next member gets
local Room = {}
Room.__index = Room

--- @class Rooms
--- @field env RoomsEnv
--- @field room Room? The room the player is in
--- @field joining { id: string?, host: string, at: number, knock: string? }? The room the player asked to be let into, or the game a room is of when that was by a link
--- @field known table<string, RoomInfo> Rooms heard of, by id
local Rooms = {}
Rooms.__index = Rooms
private.Rooms = Rooms

local Codec = private.Codec

local PREFIX = Codec.PROTOCOL_VERSION .. ":ROOM:"
local ID_LENGTH = 6
-- What a game may say in one message: the kind and its fields, colons and all. The rest of the
-- 255 bytes is for the room's id and for the host to say who it is from
Rooms.PAYLOAD = Codec.MAX_LENGTH - #PREFIX - ID_LENGTH - 1 - #"VIA:99:"

-- The client lets ten messages through at once and one more every second. This stays under
-- that, moves of the games that are played at their own pace go out on the same allowance
local BURST, RATE = 6, 0.8
local LANES = 3
local SEND_TRIES = 3
-- How many messages wait in a line before the oldest are let go. Never of the first line
local LINE_LIMIT = 80
-- What the host calls itself
local HOST_N = 1
local MAX_GUESTS = 5
local MAX_MEMBERS = 40
local LOOK_COOLDOWN = 10
local FORGET_AFTER = 600
local JOIN_PATIENCE = 20
local CHANNEL_CODES = { GUILD = "G", GROUP = "P" }
local CHANNELS = { G = "GUILD", P = "GROUP" }

--- @type table<string, PartyGame>
local games = {}
--- @type PartyGame[]
local gameList = {}

--- @param game PartyGame
function Rooms.Register(game)
  assert(Codec.IsSafeField(game.id) and not games[game.id], "Bad or repeated party game id")
  games[game.id] = game
  gameList[#gameList + 1] = game
end

--- @param id string?
--- @return PartyGame?
function Rooms.Game(id)
  return games[id]
end

--- @return PartyGame[] In the order they were registered
function Rooms.Games()
  return gameList
end

--- A number that stands for a text, for telling whether two texts are the same without saying
--- either. Not a secret kept from anyone who wants it badly enough
--- @param text string
--- @return number
function Rooms.Hash(text)
  local hash = 7
  for index = 1, #text do
    hash = (hash * 31 + text:byte(index)) % 2147483647
  end
  return hash
end

--- @param env RoomsEnv
--- @return Rooms
function Rooms.New(env)
  local lines = {}
  for lane = 1, LANES do
    lines[lane] = {}
  end
  return setmetatable({ env = env, known = {}, lines = lines, tokens = BURST, filled = env.now() }, Rooms)
end

--- @param text string
--- @return string[] Its fields, empty ones as well
local function split(text)
  local fields = {}
  for field in (text .. ":"):gmatch("([^:]*):") do
    fields[#fields + 1] = field
  end
  return fields
end

-----------------------------
-- Sending
-----------------------------

--- Sends what is waiting, as far as the allowance goes
function Rooms:drain()
  local now = self.env.now()
  self.tokens = math.min(BURST, self.tokens + (now - self.filled) * RATE)
  self.filled = now
  for lane = 1, LANES do
    local line = self.lines[lane]
    while #line > 0 do
      if self.tokens < 1 then
        return
      end
      local message = line[1]
      local sent
      if message.target then
        sent = self.env.send(message.target, message.text)
      else
        sent = self.env.broadcast(message.channel, message.text)
      end
      if not sent then
        -- Nothing gets out right now, there is no use in trying the rest. What doesn't get out
        -- time after time is let go, it may be for someone who is no longer there
        message.tries = (message.tries or 0) + 1
        if message.tries >= SEND_TRIES then
          table.remove(line, 1)
        end
        self.tokens = 0
        return
      end
      table.remove(line, 1)
      self.tokens = self.tokens - 1
    end
  end
end

--- @param lane number
--- @param channel RoomChannel? The channel to say it on, or
--- @param target string? the player to whisper it to
--- @param text string
function Rooms:post(lane, channel, target, text)
  assert(#text <= Codec.MAX_LENGTH, "Room message too long")
  local line = self.lines[lane]
  if lane > 1 and #line >= LINE_LIMIT then
    table.remove(line, 1)
  end
  line[#line + 1] = { channel = channel, target = target, text = text }
  self:drain()
end

--- How many messages are waiting in a line
--- @param lane number
--- @return number
function Rooms:Backlog(lane)
  return #self.lines[lane]
end

--- Sends something to everyone in the room but the player, and but one other where it is theirs
--- @param room Room
--- @param lane number
--- @param body string Kind and fields
--- @param origin RoomMember? On the host: whose it is, to pass it on for them
--- @param heardOn RoomChannel? On the host: the channel the others have heard it on already
function Rooms:spread(room, lane, body, origin, heardOn)
  local text = PREFIX .. room.id .. ":" .. body
  if room.host ~= self.env.me then
    if room.direct then
      self:post(lane, nil, room.host, text)
    else
      self:post(lane, room.channel, nil, text)
    end
    return
  end
  if origin then
    text = PREFIX .. room.id .. ":VIA:" .. origin.n .. ":" .. body
  end
  if room.channel and not heardOn then
    self:post(lane, room.channel, nil, text)
  end
  for _, member in pairs(room.members) do
    if member.direct and member ~= origin then
      self:post(lane, nil, member.name, text)
    end
  end
end

--- @param game PartyGame?
--- @param kind string
--- @return number
local function laneOf(game, kind)
  return game and game.lanes and game.lanes[kind] or 1
end

-----------------------------
-- A room
-----------------------------

--- @return boolean
function Room:IsHost()
  return self.host == self.rooms.env.me
end

--- @return RoomMember? The local player
function Room:Me()
  return self.members[self.me]
end

--- @return RoomMember[] By the order they came in
function Room:Members()
  local list = {}
  for _, member in pairs(self.members) do
    list[#list + 1] = member
  end
  table.sort(list, function(a, b)
    return a.n < b.n
  end)
  return list
end

--- @return number
function Room:Now()
  return self.rooms.env.now()
end

--- @param max number
--- @return number From 1 to max
function Room:Random(max)
  return self.rooms.env.random(max)
end

--- Says something to everyone in the room. The game gets to hear it like anybody's
--- @param kind string
--- @param ... string|number
function Room:Say(kind, ...)
  self.rooms:say(self, laneOf(games[self.game], kind), kind, ...)
end

--- The same, for what was said before and somebody wants to hear again: it waits until there
--- is nothing else to send
--- @param kind string
--- @param ... string|number
function Room:Repeat(kind, ...)
  local body = table.concat({ kind, ... }, ":")
  self.rooms:spread(self, LANES, body)
end

--- On the host: says something to one member only
--- @param member RoomMember
--- @param kind string
--- @param ... string|number
function Room:Tell(member, kind, ...)
  assert(self:IsHost(), "Only the host tells one member")
  if member.n ~= self.me then
    self.rooms:post(1, nil, member.name, PREFIX .. self.id .. ":" .. table.concat({ kind, ... }, ":"))
  end
end

--- On the host: tells one member a list, as many messages as it takes. Each message is the kind,
--- the fields given, and as many of the entries as fit in it with a "." between them
--- @param member RoomMember
--- @param kind string
--- @param entries (string|number)[]
--- @param ... string|number
function Room:TellList(member, kind, entries, ...)
  local fields, last = { ... }, select("#", ...) + 1
  local head = table.concat({ kind, ... }, ":") .. ":"
  local chunk, length = {}, #head
  local function flush()
    if #chunk > 0 then
      fields[last] = table.concat(chunk, ".")
      self:Tell(member, kind, unpack(fields))
      chunk, length = {}, #head
    end
  end
  for _, entry in ipairs(entries) do
    entry = tostring(entry)
    if #chunk > 0 and length + 1 + #entry > Rooms.PAYLOAD then
      flush()
    end
    length = length + (#chunk > 0 and 1 or 0) + #entry
    chunk[#chunk + 1] = entry
  end
  flush()
end

--- Shuffles a list in place, the same way on every client that is given the same rolls
--- @generic T
--- @param list T[]
--- @return T[] The same list
function Room:Shuffle(list)
  for index = #list, 2, -1 do
    local other = self:Random(index)
    list[index], list[other] = list[other], list[index]
  end
  return list
end

--- Everyone in the room starts again from nothing, for a new game
function Room:ClearScores()
  for _, member in pairs(self.members) do
    member.score = 0
  end
end

--- How many messages of a kind are still waiting to be sent, for a game that would rather say
--- more in one message than fall behind
--- @param kind string
--- @return number
function Room:Waiting(kind)
  return self.rooms:Backlog(laneOf(games[self.game], kind))
end

--- @param room Room
--- @param lane number
--- @param kind string
--- @param ... string|number
function Rooms:say(room, lane, kind, ...)
  local fields = {}
  for index = 1, select("#", ...) do
    fields[index] = tostring((select(index, ...)))
  end
  local body = #fields > 0 and (kind .. ":" .. table.concat(fields, ":")) or kind
  assert(#body <= Rooms.PAYLOAD, "Room message too long")
  self:spread(room, lane, body)
  self:deliver(room, room:Me(), kind, fields)
end

--- @param id string
--- @param gameId string
--- @param host string
--- @param channel RoomChannel?
--- @return Room
function Rooms:newRoom(id, gameId, host, channel)
  local room = { id = id, game = gameId, host = host, channel = channel, members = {}, count = 0, rooms = self }
  return setmetatable(room, Room)
end

--- @param room Room
--- @param n number
--- @param name string
--- @param score number
--- @return RoomMember member, boolean new
function Rooms:addMember(room, n, name, score)
  local member = room.members[n]
  if member then
    return member, false
  end
  member = { n = n, name = name, score = score }
  room.members[n] = member
  room.count = room.count + 1
  return member, true
end

--- @param room Room
--- @param name string
--- @return RoomMember?
local function memberNamed(room, name)
  for _, member in pairs(room.members) do
    if member.name == name then
      return member
    end
  end
  -- Somebody written into the room differently from how they are heard, who goes by how they
  -- are heard from then on
  local named = room.rooms.env.named
  for _, member in pairs(named and room.members or {}) do
    if member.n ~= room.me and named(member.name) == name then
      member.name = name
      return member
    end
  end
  return nil
end

--- The player is no longer in a room
--- @param reason string
function Rooms:close(reason)
  local room = self.room
  if room then
    self.room = nil
    self.known[room.id] = nil
    room.closed = reason
    self.env.notify("closed", room)
  end
end

-----------------------------
-- What the player does
-----------------------------

--- Opens a room and says so on its channel
--- @param gameId string
--- @param channel RoomChannel? Who it is for. Without one it is for whoever the host asks in
--- @param rules table<string, any>? How the game is set up, see PartyGame.options
--- @return Room? room, string? error
function Rooms:Open(gameId, channel, rules)
  local game = games[gameId]
  if not game then
    return nil, "unknown_game"
  elseif self.room then
    return nil, "in_room"
  elseif channel and not self.env.onChannel(channel) then
    return nil, channel == "GUILD" and "no_guild" or "no_group"
  end

  local id = ""
  for _ = 1, ID_LENGTH do
    local digit = self.env.random(36)
    id = id .. ("0123456789abcdefghijklmnopqrstuvwxyz"):sub(digit, digit)
  end
  local room = self:newRoom(id, gameId, self.env.me, channel)
  room.invited, room.nextN, room.me = {}, HOST_N + 1, HOST_N
  self:addMember(room, HOST_N, self.env.me, 0)
  room.state = game.new(room, rules)
  self.room, self.joining = room, nil
  if channel then
    self:post(1, channel, nil, self:openText(room, false))
  end
  self.env.notify("joined", room)
  return room
end

--- @param room Room
--- @param invited boolean
--- @return string
function Rooms:openText(room, invited)
  local game = games[room.game]
  local channel = CHANNEL_CODES[room.channel] or "-"
  return PREFIX .. table.concat({ room.id, "OPEN", room.game, game.version, channel, invited and 1 or 0 }, ":")
end

--- On the host: asks a player in, whether they are on the room's channel or not
--- @param name string? Full player name
--- @return boolean ok, string? error
function Rooms:Invite(name)
  local room = self.room
  if not room or not room:IsHost() then
    return false, "not_host"
  elseif not name then
    return false, "no_target"
  elseif name == self.env.me then
    return false, "self_invite"
  end
  room.invited[name] = true
  self:post(1, nil, name, self:openText(room, true))
  return true
end

--- On the host: whoever clicks a link to the room in chat may come in from now on
--- @return PartyGame? game What to link to, nil if the player has no room
function Rooms:Link()
  local room = self.room
  if not room or not room:IsHost() then
    return nil
  end
  room.linked = true
  return games[room.game]
end

--- Asks to be let into a room somebody linked in chat
--- @param host string Full name of whoever linked it
--- @param gameId string
--- @return boolean ok, string? error
function Rooms:Knock(host, gameId)
  local game = games[gameId]
  if not game then
    return false, "unknown_game"
  elseif host == self.env.me then
    return false, "own_room"
  elseif self.room then
    return false, "in_room"
  end
  self.joining = { host = host, knock = gameId, at = self.env.now() }
  self:post(1, nil, host, PREFIX .. table.concat({ "0", "KNOCK", 0, game.version, gameId }, ":"))
  return true
end

--- Asks which rooms there are, on every channel the player has
--- @return boolean asked False if it was asked only a moment ago
function Rooms:Look()
  local now = self.env.now()
  if self.looked and now - self.looked < LOOK_COOLDOWN then
    return false
  end
  self.looked = now
  for _, channel in ipairs({ "GUILD", "GROUP" }) do
    if self.env.onChannel(channel) then
      self:post(1, channel, nil, PREFIX .. "0:WHO")
    end
  end
  return true
end

--- The rooms the player could ask to be let into, the ones they were asked into first
--- @return RoomInfo[]
function Rooms:Known()
  local now, list = self.env.now(), {}
  for id, info in pairs(self.known) do
    if now - info.heard > FORGET_AFTER then
      self.known[id] = nil
    else
      list[#list + 1] = info
    end
  end
  table.sort(list, function(a, b)
    if a.invited ~= b.invited then
      return a.invited
    end
    return a.heard > b.heard
  end)
  return list
end

--- Asks the host of a room to be let in
--- @param id string
--- @return boolean ok, string? error
function Rooms:Join(id)
  local info = self.known[id]
  local game = info and games[info.game]
  if not info then
    return false, "no_room"
  elseif not game or game.version ~= info.version then
    return false, "room_version"
  elseif self.room then
    return false, "in_room"
  end
  self.joining = { id = id, host = info.host, at = self.env.now() }
  self:post(1, nil, info.host, PREFIX .. table.concat({ id, "JOIN", info.onChannel and 1 or 0, game.version }, ":"))
  return true
end

--- Leaves the room. If it is the player's own that closes it for everyone
function Rooms:Leave()
  local room = self.room
  if not room then
    return
  end
  if room:IsHost() then
    self:say(room, 1, "SHUT")
  else
    self:say(room, 1, "OUT", room.me)
  end
end

-----------------------------
-- What the others say
-----------------------------

--- @param room Room
--- @param member RoomMember? Who said it
--- @param kind string
--- @param fields string[]
function Rooms:deliver(room, member, kind, fields)
  local game = games[room.game]
  local fromHost = member ~= nil and member.name == room.host
  if kind == "IN" then
    if not fromHost and room.count > 0 then
      return
    end
    for index = 1, #fields - 2, 3 do
      local n, score, name = tonumber(fields[index]), tonumber(fields[index + 2]), fields[index + 1]
      if n == HOST_N and fromHost then
        -- The host goes by the name its messages come from. The client doesn't always say a
        -- player's name the way they would say it themselves ("Jeany" may be heard as "Jeany
        -- Beany"), and whoever is in the room is told apart by how they are heard
        name = room.host
      elseif n == room.me then
        if self.env.namedMe and name then
          self.env.namedMe(name)
        end
      elseif name and self.env.named then
        name = self.env.named(name) or name
      end
      if n and score and name ~= "" then
        self:addMember(room, n, name, score)
      end
    end
    self.env.notify("roster", room)
  elseif not member then
    return
  elseif kind == "OUT" then
    local gone = room.members[tonumber(fields[1])]
    if not gone or not (fromHost or gone == member) or gone.name == room.host then
      return
    end
    room.members[gone.n] = nil
    room.count = room.count - 1
    if gone.n == room.me then
      return self:close("left")
    end
    if game.left then
      game.left(room, gone)
    end
    self.env.notify("roster", room)
  elseif kind == "SHUT" then
    if fromHost then
      self:close(room:IsHost() and "left" or "shut")
    end
  else
    game.receive(room, member, kind, fields)
    self.env.notify("changed", room)
  end
end

--- On the host: somebody wants in
--- @param room Room
--- @param sender string
--- @param fields string[]
--- @param linked boolean? They clicked a link to the room
function Rooms:onJoin(room, sender, fields, linked)
  local game = games[room.game]
  local function refuse(reason)
    self:post(1, nil, sender, PREFIX .. room.id .. ":NO:" .. reason)
  end

  local member = memberNamed(room, sender)
  if not member then
    local direct = not (room.channel and (fields[1] == "1" or self.env.reaches(room.channel, sender)))
    local guests = 0
    for _, other in pairs(room.members) do
      guests = guests + (other.direct and 1 or 0)
    end
    if tonumber(fields[2]) ~= game.version then
      return refuse("version")
    elseif direct and not room.invited[sender] and not linked then
      return refuse("closed")
    elseif room.count >= MAX_MEMBERS or (direct and guests >= MAX_GUESTS) then
      return refuse("full")
    end
    member = self:addMember(room, room.nextN, sender, 0)
    member.direct = direct or nil
    room.nextN = room.nextN + 1
  end
  -- Somebody who was in already has lost the room, to a reload perhaps, and is told it all again

  local welcome = { room.id, "WELCOME", member.n, member.direct and "d" or "c", room.game, CHANNEL_CODES[room.channel] or "-" }
  self:post(1, nil, sender, PREFIX .. table.concat(welcome, ":"))
  local chunk = {}
  local function flush()
    if #chunk > 0 then
      self:post(1, nil, sender, PREFIX .. room.id .. ":IN:" .. table.concat(chunk, ":"))
      chunk = {}
    end
  end
  for _, other in ipairs(room:Members()) do
    local entry = other.n .. ":" .. other.name .. ":" .. other.score
    if #table.concat(chunk, ":") + #entry > Rooms.PAYLOAD - 8 then
      flush()
    end
    chunk[#chunk + 1] = entry
  end
  flush()
  self:spread(room, 1, table.concat({ "IN", member.n, member.name, member.score }, ":"))
  if game.welcome then
    game.welcome(room, member)
  end
  self.env.notify("roster", room)
end

--- @param sender string
--- @param id string
--- @param fields string[]
--- @param channel RoomChannel?
function Rooms:onOpen(sender, id, fields, channel)
  local version = tonumber(fields[2])
  if not Codec.IsSafeField(id) or not Codec.IsSafeField(fields[1]) or not version or (self.room and self.room.id == id) then
    return
  end
  local old = self.known[id]
  if old and old.host ~= sender then
    return
  end
  local invited = fields[4] == "1"
  --- @type RoomInfo
  local info = {
    id = id,
    host = sender,
    game = fields[1],
    version = version,
    channel = CHANNELS[fields[3]],
    invited = invited or (old ~= nil and old.invited),
    onChannel = channel ~= nil or (old ~= nil and old.onChannel),
    heard = self.env.now(),
  }
  self.known[id] = info
  if not old or (invited and not old.invited) then
    self.env.notify("open", info)
  end
end

--- Handles a received payload if it is about a room
--- @param sender string Full player name
--- @param text string
--- @param channel RoomChannel? The channel it was heard on, nil for a whisper
--- @return boolean handled False if the payload is not about a room
function Rooms:Handle(sender, text, channel)
  if type(text) ~= "string" or text:sub(1, #PREFIX) ~= PREFIX then
    return false
  end
  if sender == self.env.me or #text > Codec.MAX_LENGTH then
    return true
  end
  local fields = split(text:sub(#PREFIX + 1))
  local id, kind = table.remove(fields, 1), table.remove(fields, 1)
  local room = self.room
  local hosting = room ~= nil and room:IsHost()

  if kind == "WHO" then
    if hosting and channel and channel == room.channel then
      self:post(1, nil, sender, self:openText(room, false))
    end
    return true
  elseif kind == "OPEN" then
    self:onOpen(sender, id, fields, channel)
    return true
  elseif kind == "KNOCK" then
    if not channel and hosting and room.linked and fields[3] == room.game then
      self:onJoin(room, sender, fields, true)
    elseif not channel then
      self:post(1, nil, sender, PREFIX .. "0:NO:closed")
    end
    return true
  end

  local joining = self.joining
  local answers = joining and joining.host == sender and (joining.id == id or joining.knock)
  if answers and (kind == "NO" or kind == "WELCOME") then
    self.joining = nil
    local info, n = self.known[id], tonumber(fields[1])
    if joining.knock and kind == "WELCOME" and fields[3] == joining.knock then
      info = { game = fields[3], channel = CHANNELS[fields[4]] }
    end
    if kind == "NO" or not info or not n or room then
      if fields[1] == "closed" then
        self.known[id] = nil
      end
      self.env.notify("refused", kind == "NO" and fields[1] or "closed")
      return true
    end
    room = self:newRoom(id, info.game, sender, info.channel)
    room.me, room.direct = n, fields[2] == "d"
    room.state = games[info.game].new(room)
    self.room = room
    self.env.notify("joined", room)
    return true
  end

  if not room or room.id ~= id then
    local info = self.known[id]
    if kind == "SHUT" and info and info.host == sender then
      self.known[id] = nil
      self.env.notify("gone", info)
    end
    return true
  end
  if channel and channel ~= room.channel then
    return true
  end

  if hosting then
    if kind == "JOIN" then
      if not channel then
        self:onJoin(room, sender, fields)
      end
      return true
    end
    local member = memberNamed(room, sender)
    if not member or kind == "VIA" or kind == "IN" or kind == "SHUT" then
      return true
    end
    member.away = nil
    local body = #fields > 0 and (kind .. ":" .. table.concat(fields, ":")) or kind
    if #body <= Rooms.PAYLOAD then
      -- The rest of the room has to hear it too: the guests what was said on the channel, the
      -- channel and the other guests what a guest said
      self:spread(room, laneOf(games[room.game], kind), body, member, channel)
      self:deliver(room, member, kind, fields)
    end
    return true
  end

  local member
  if kind == "VIA" then
    if sender ~= room.host then
      return true
    end
    member = room.members[tonumber(table.remove(fields, 1))]
    kind = table.remove(fields, 1)
    if not member or not kind or member.n == room.me then
      return true
    end
  elseif sender == room.host then
    -- The host is who says who is in the room, before it is known that the host is
    member = memberNamed(room, sender) or { n = 0, name = sender, score = 0 }
  elseif channel then
    member = memberNamed(room, sender)
  end
  -- What the player said themselves, heard back on the channel by a name that isn't quite theirs
  if member and member.n ~= room.me then
    self:deliver(room, member, kind, fields)
  end
  return true
end

--- A player can no longer be reached
--- @param name string
function Rooms:PeerOffline(name)
  local room = self.room
  if not room then
    return
  end
  if name == room.host then
    self:close("host_gone")
  elseif room:IsHost() then
    local member = memberNamed(room, name)
    if member then
      self:say(room, 1, "OUT", member.n)
    end
  end
end

--- The local player went into combat, or came out of it
--- @param fighting boolean
function Rooms:Fighting(fighting)
  local room = self.room
  local game = room and games[room.game]
  if game and game.fight then
    game.fight(room, fighting)
  end
end

--- Call several times a second: sends what was waiting and lets the game do what is due
function Rooms:Tick()
  local now = self.env.now()
  if self.joining and now - self.joining.at > JOIN_PATIENCE then
    self.joining = nil
    self.env.notify("refused", "offline")
  end
  local room = self.room
  local game = room and games[room.game]
  if game and game.tick then
    game.tick(room, now)
  end
  self:drain()
end
