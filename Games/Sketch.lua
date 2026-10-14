--------------------------
--  Sketch
--------------------------
-- One draws, everyone else guesses what it is. A game for a room (Engine/Rooms.lua), for as
-- many as turn up: the host says whose turn it is to draw and for how long, whoever draws is
-- given three things to pick from, and the first to say what it is gets the most for it.
--
--   RND:round:drawer:seconds:list
--                                from the host: this member draws next, for this long, something
--                                from this list (Lexicon/Sketch.lua). With round 1 a new game
--                                begins, and everyone has nothing
--   WRD:hash:pattern[:left]      from whoever draws: they picked, the clock is running. The
--                                hash stands for what it is (Rooms.Hash), so that a guess can be
--                                told from the right one without anyone being sent it. The
--                                pattern is how many letters its words have, "7.3". The host
--                                tells the same to somebody who comes in late, with the seconds
--                                that are left
--   D:k:pieces                   from whoever draws: message k of the picture, see below
--   SEE                          from somebody who came in late: the picture so far, please
--   G:text                       a guess that wasn't it, for everyone to read
--   GOT                          the sender guessed it
--   END:round:word:awards        the round is over. From whoever drew, with what it was and
--                                what everyone gets for it, "3=10+5=8" by member. From the host
--                                with neither if whoever was to draw never did, or is gone
--   STOP                         from the host: that was the game
--
-- Nobody but whoever draws ever needs to know more than that hash, and it is them who say how
-- the round went. That takes their word for it, which between friends is what a game does.
--
-- The picture is lines. It is drawn on a sheet of 512 by 384, whatever size it is shown at, and
-- sent a second's worth at a time as pieces with a "." between them:
--
--   n<colour><width><points>     a new line, each point three characters
--   c<colour><width><points>     more of the line that was being drawn
--   u                            the last line is taken back
--   x                            the sheet is wiped
--
-- The messages are numbered so that one sent again is known for what it is, and so that the
-- picture can be put together in the right order when they don't arrive in it.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Rooms = private.Rooms

--- @class Sketch
local Sketch = {}
private.Sketch = Sketch

Sketch.WIDTH, Sketch.HEIGHT = 512, 384
-- The last one is the sheet's own, for rubbing out
Sketch.COLORS = {
  { 0.1, 0.1, 0.1 },
  { 0.85, 0.15, 0.12 },
  { 0.95, 0.55, 0.1 },
  { 0.95, 0.85, 0.15 },
  { 0.2, 0.65, 0.2 },
  { 0.15, 0.4, 0.85 },
  { 0.55, 0.25, 0.7 },
  { 0.5, 0.32, 0.16 },
  { 0.96, 0.94, 0.88 },
}
Sketch.PAPER = #Sketch.COLORS
-- How thick a line can be, in the sheet's own measure
Sketch.WIDTHS = { 3, 7, 18 }
Sketch.LENGTHS = { 60, 80, 120 }
Sketch.LISTS = { "b", "e", "w" }

-- Seconds to pick what to draw, between two rounds, and that the host gives whoever draws on
-- top of what they have before taking the round to be lost
local PICK, PAUSE, GRACE = 15, 7, 8
local USUAL_LENGTH = 80
-- How often what is being drawn is sent, in seconds
local FLUSH = 1
-- A piece has at most this many points, and a message this many characters of pieces
local PIECE_POINTS, MESSAGE_ROOM = 60, 200
local FEED_LINES = 40
local GUESS_LENGTH = 40
-- What a guess is worth by how many had it before, and to whoever drew
local AWARDS, AWARD_LATE = { 10, 8, 6, 4 }, 3
local DRAWER_AWARD, DRAWER_MOST = 2, 10

local DIGITS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-+"
local VALUES = {}
for index = 1, #DIGITS do
  VALUES[DIGITS:byte(index)] = index - 1
end

-----------------------------
-- The picture
-----------------------------

--- @param x number
--- @param y number
--- @return string
local function encodePoint(x, y)
  local value = x * 512 + y
  local high, middle, low = math.floor(value / 4096), math.floor(value / 64) % 64, value % 64
  return DIGITS:sub(high + 1, high + 1) .. DIGITS:sub(middle + 1, middle + 1) .. DIGITS:sub(low + 1, low + 1)
end

--- @param piece string
--- @return { color: number, width: number, points: number[] }? stroke nil if it isn't a line that can be drawn
local function decodeStroke(piece)
  local color, width = tonumber(piece:sub(2, 2)), tonumber(piece:sub(3, 3))
  if not Sketch.COLORS[color] or not Sketch.WIDTHS[width] or (#piece - 3) % 3 ~= 0 then
    return nil
  end
  local points = {}
  for index = 4, #piece, 3 do
    local high, middle, low = VALUES[piece:byte(index)], VALUES[piece:byte(index + 1)], VALUES[piece:byte(index + 2)]
    if not (high and middle and low) then
      return nil
    end
    local value = high * 4096 + middle * 64 + low
    local x, y = math.floor(value / 512), value % 512
    if y >= Sketch.HEIGHT then
      return nil
    end
    points[#points + 1] = x
    points[#points + 1] = y
  end
  return { color = color, width = width, points = points }
end

--- Does to the picture what one message of it says
--- @param state table
--- @param pieces string
local function apply(state, pieces)
  local strokes = state.strokes
  for piece in pieces:gmatch("[^.]+") do
    local what = piece:sub(1, 1)
    if what == "x" then
      strokes = {}
      state.strokes, state.open = strokes, false
    elseif what == "u" then
      strokes[#strokes] = nil
      state.open = false
    elseif what == "n" or what == "c" then
      local stroke = decodeStroke(piece)
      local last = strokes[#strokes]
      if stroke and what == "c" and state.open and last then
        for _, value in ipairs(stroke.points) do
          last.points[#last.points + 1] = value
        end
      elseif stroke then
        strokes[#strokes + 1] = stroke
      end
      state.open = stroke ~= nil
    end
  end
end

--- Puts the picture together again from every message there is of it
--- @param state table
local function rebuild(state)
  state.strokes, state.open = {}, false
  for k = 1, state.top do
    if state.ops[k] then
      apply(state, state.ops[k])
    else
      -- What was being drawn across a message that is missing is two lines now
      state.open = false
    end
  end
end

--- @param state table
--- @param k number
--- @param pieces string
local function takeMessage(state, k, pieces)
  if state.ops[k] or #pieces > MESSAGE_ROOM + 20 then
    return
  end
  state.ops[k] = pieces
  if k > state.top then
    if k ~= state.top + 1 then
      state.open = false
    end
    state.top = k
    apply(state, pieces)
  else
    rebuild(state)
  end
  state.rev = state.rev + 1
end

-----------------------------
-- Words
-----------------------------

--- What of a word counts: its letters
--- @param text string
--- @return string
local function letters(text)
  return (text:upper():gsub("[^A-Z]", ""))
end

--- @param room Room
--- @param round number
--- @param word string
--- @return number
local function hashOf(room, round, word)
  return Rooms.Hash(room.id .. round .. letters(word))
end

--- @param word string
--- @return string How many letters each of its words has, "7.3"
local function patternOf(word)
  local counts = {}
  for part in word:gmatch("%S+") do
    counts[#counts + 1] = #letters(part)
  end
  return table.concat(counts, ".")
end

--- What a player typed, as it may be shown to the others: nothing a chat window would take for
--- more than text, and not too much of it
--- @param text string?
--- @return string
local function tidy(text)
  text = (text or ""):gsub("[%c:|]", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if #text > GUESS_LENGTH then
    -- Not through the middle of a letter that is more than one byte
    text = text:sub(1, GUESS_LENGTH):gsub("[\192-\255][\128-\191]*$", "")
  end
  return text
end

-- What this player was asked to draw before, so it isn't the same thing every evening
local drawn = {}

--- @param room Room
--- @param list string
--- @return string[] Three things to pick from
local function choices(room, list)
  local lists = private.SketchWords
  local pool = {}
  for _, key in ipairs(list == "b" and { "e", "w" } or { list }) do
    for _, word in ipairs(lists[key] or lists.e) do
      pool[#pool + 1] = word
    end
  end
  local picked, taken = {}, {}
  for try = 1, 60 do
    local word = pool[room:Random(#pool)]
    -- After a while anything will do
    if not taken[word] and (not drawn[word] or try > 40) then
      taken[word] = true
      picked[#picked + 1] = word
      if #picked == 3 then
        break
      end
    end
  end
  return picked
end

-----------------------------
-- The game
-----------------------------

--- @param state table
--- @param entry { n: number?, text: string?, got: boolean?, note: string? }
local function feed(state, entry)
  state.feed[#state.feed + 1] = entry
  if #state.feed > FEED_LINES then
    table.remove(state.feed, 1)
  end
end

--- @param state table
local function wipe(state)
  state.ops, state.top, state.cleared, state.strokes, state.open = {}, 0, nil, {}, false
  state.pieces, state.pending, state.resend = nil, nil, nil
  state.got, state.order, state.gained = {}, {}, {}
  state.word, state.hash, state.pattern, state.choices = nil, nil, nil, nil
  state.rev = state.rev + 1
end

--- On the host: who draws after the one who just did
--- @param room Room
--- @return RoomMember
local function nextDrawer(room)
  local members, state = room:Members(), room.state
  local start = 0
  for index, member in ipairs(members) do
    if member.n <= (state.drawer or 0) then
      start = index
    end
  end
  for pass = 1, 2 do
    for step = 1, #members do
      local member = members[(start + step - 1) % #members + 1]
      if not member.away or pass == 2 then
        return member
      end
    end
    -- Nobody answers? Then everybody gets another chance
    for _, member in ipairs(members) do
      member.away = nil
    end
  end
  return members[1]
end

--- @param room Room
local function beginRound(room)
  local state = room.state
  room:Say("RND", state.round + 1, nextDrawer(room).n, state.length, state.list)
end

--- On the host: starts a game with whoever is in the room
--- @param room Room
--- @param options { length: number?, list: string? }?
--- @return boolean ok, string? error
function Sketch.Start(room, options)
  if not room:IsHost() then
    return false, "not_host"
  elseif room.count < 2 then
    return false, "sketch_alone"
  end
  local state = room.state
  state.length = options and options.length or state.length
  state.list = options and options.list or state.list
  state.round, state.drawer = 0, nil
  beginRound(room)
  return true
end

--- On the host: ends the game, the room stays
--- @param room Room
function Sketch.Stop(room)
  if room:IsHost() and room.state.phase ~= "idle" then
    room:Say("STOP")
  end
end

--- Whoever draws picks what
--- @param room Room
--- @param index number
function Sketch.Choose(room, index)
  local state = room.state
  local word = state.choices and state.phase == "pick" and state.choices[index]
  if not word then
    return
  end
  drawn[word] = true
  state.word, state.choices = word, nil
  room:Say("WRD", hashOf(room, state.round, word), patternOf(word))
end

--- @param room Room
--- @param text string
--- @return boolean ok, boolean|string? Whether that was it, or why it couldn't be guessed
function Sketch.Guess(room, text)
  local state = room.state
  if state.phase ~= "draw" or state.drawer == room.me or state.got[room.me] then
    return false, "sketch_not_now"
  end
  text = tidy(text)
  if letters(text) == "" then
    return false, "sketch_no_guess"
  end
  if hashOf(room, state.round, text) == state.hash then
    room:Say("GOT")
    return true, true
  end
  room:Say("G", text)
  return true, false
end

--- Whether the local player is the one drawing right now
--- @param room Room
--- @return boolean
function Sketch.Drawing(room)
  return room.state.phase == "draw" and room.state.drawer == room.me
end

--- @param room Room
--- @return number? Seconds left to pick or to draw, nil between rounds
function Sketch.TimeLeft(room)
  local state = room.state
  local due = state.phase == "pick" and state.pickBy or (state.phase == "draw" and state.endsAt)
  return due and math.max(0, due - room:Now()) or nil
end

--- What the players are shown of the word: all of it if they may know, a dash for every letter
--- if they don't
--- @param room Room
--- @return string?
function Sketch.Hint(room)
  local state = room.state
  if state.word then
    return state.word
  elseif not state.pattern then
    return nil
  end
  local parts = {}
  for count in state.pattern:gmatch("%d+") do
    parts[#parts + 1] = ("_ "):rep(math.min(20, tonumber(count))):sub(1, -2)
  end
  return table.concat(parts, "    ")
end

-----------------------------
-- Drawing
-----------------------------

--- @param value number
--- @param most number
--- @return number
local function onSheet(value, most)
  return math.max(0, math.min(most, math.floor(value + 0.5)))
end

--- What was drawn since it was last sent becomes a piece that waits to be
--- @param state table
local function cutPiece(state)
  local pending = state.pending
  if not pending then
    return
  end
  if #pending.points > 0 then
    local parts = { (pending.fresh and "n" or "c") .. pending.color .. pending.width }
    for index = 1, #pending.points, 2 do
      parts[#parts + 1] = encodePoint(pending.points[index], pending.points[index + 1])
    end
    state.pieces[#state.pieces + 1] = table.concat(parts)
    pending.points, pending.fresh = {}, false
  end
  if pending.done then
    state.pending = nil
  end
end

--- Sends the pieces that wait, as few messages as they fit in
--- @param room Room
local function sendPieces(room)
  local state = room.state
  cutPiece(state)
  local pieces = state.pieces
  state.pieces = {}
  local message, wiped
  local function send()
    if message then
      local k = state.top + 1
      state.ops[k], state.top = message, k
      if wiped then
        -- Whoever asks for the picture needs nothing from before it was wiped
        state.cleared = k
      end
      room:Say("D", k, message)
      message, wiped = nil, false
    end
  end
  for _, piece in ipairs(pieces) do
    if message and #message + 1 + #piece > MESSAGE_ROOM then
      send()
    end
    message = message and (message .. "." .. piece) or piece
    wiped = wiped or piece == "x"
  end
  send()
  state.flushed = room:Now()
end

--- Whoever draws puts the pen down
--- @param room Room
--- @param color number
--- @param width number
--- @param x number On the sheet, from its left edge
--- @param y number And down from its top
--- @return boolean drawing
function Sketch.Pen(room, color, width, x, y)
  local state = room.state
  if not Sketch.Drawing(room) or not Sketch.COLORS[color] or not Sketch.WIDTHS[width] then
    return false
  end
  if state.pending then
    state.pending.done = true
    cutPiece(state)
  end
  x, y = onSheet(x, Sketch.WIDTH - 1), onSheet(y, Sketch.HEIGHT - 1)
  state.strokes[#state.strokes + 1] = { color = color, width = width, points = { x, y } }
  state.pending = { fresh = true, color = color, width = width, points = { x, y } }
  state.rev = state.rev + 1
  return true
end

--- And moves it
--- @param room Room
--- @param x number
--- @param y number
function Sketch.Draw(room, x, y)
  local state = room.state
  local pending, stroke = state.pending, state.strokes[#state.strokes]
  if not Sketch.Drawing(room) or not pending or pending.done or not stroke then
    return
  end
  x, y = onSheet(x, Sketch.WIDTH - 1), onSheet(y, Sketch.HEIGHT - 1)
  local points = stroke.points
  if points[#points - 1] == x and points[#points] == y then
    return
  end
  points[#points + 1], points[#points + 2] = x, y
  pending.points[#pending.points + 1], pending.points[#pending.points + 2] = x, y
  if #pending.points >= PIECE_POINTS * 2 then
    cutPiece(state)
  end
  state.rev = state.rev + 1
end

--- And takes it off the sheet
--- @param room Room
function Sketch.Lift(room)
  local pending = room.state.pending
  if pending then
    pending.done = true
    cutPiece(room.state)
  end
end

--- @param room Room
--- @param piece string
local function edit(room, piece)
  local state = room.state
  if not Sketch.Drawing(room) then
    return
  end
  Sketch.Lift(room)
  if piece == "x" then
    state.strokes = {}
  else
    state.strokes[#state.strokes] = nil
  end
  state.pieces[#state.pieces + 1] = piece
  state.rev = state.rev + 1
end

--- Whoever draws takes back their last line
--- @param room Room
function Sketch.Undo(room)
  edit(room, "u")
end

--- Or wipes the sheet
--- @param room Room
function Sketch.Clear(room)
  edit(room, "x")
end

-----------------------------
-- What is said in the room
-----------------------------

--- Whoever drew says how the round went
--- @param room Room
local function finish(room)
  local state = room.state
  sendPieces(room)
  local awards = {}
  for place, n in ipairs(state.order) do
    awards[#awards + 1] = n .. "=" .. (AWARDS[place] or AWARD_LATE)
  end
  if #state.order > 0 then
    awards[#awards + 1] = room.me .. "=" .. math.min(DRAWER_MOST, DRAWER_AWARD * #state.order)
  end
  room:Say("END", state.round, state.word and (state.word:gsub(" ", "_")) or "-", table.concat(awards, "+"))
end

--- @param room Room
--- @param member RoomMember
--- @param kind string
--- @param fields string[]
local function receive(room, member, kind, fields)
  local state = room.state
  local fromHost, fromDrawer = member.name == room.host, member.n == state.drawer
  local now = room:Now()

  if kind == "RND" and fromHost then
    local round, drawer, length = tonumber(fields[1]), tonumber(fields[2]), tonumber(fields[3])
    if not (round and drawer and length) then
      return
    end
    if round == 1 then
      for _, other in pairs(room.members) do
        other.score = 0
      end
      state.feed = {}
    end
    wipe(state)
    state.round, state.drawer, state.length, state.list = round, drawer, math.max(10, math.min(600, length)), fields[4] or "b"
    state.phase, state.pickBy, state.nextAt, state.endsAt = "pick", now + PICK, nil, nil
    feed(state, { n = drawer, note = "round" })
    if drawer == room.me then
      state.pieces = {}
      state.choices = choices(room, state.list)
    end
  elseif kind == "WRD" and state.phase == "pick" and (fromDrawer or fromHost) then
    local hash, left = tonumber(fields[1]), tonumber(fields[3])
    if not hash or not fields[2] or not fields[2]:match("^[%d.]+$") then
      return
    end
    state.hash, state.pattern, state.choices = hash, fields[2], nil
    state.phase, state.endsAt = "draw", now + math.min(state.length, left or state.length)
    if left and state.drawer ~= room.me then
      -- Told by the host on the way in: the picture is well under way
      room:Say("SEE")
    end
  elseif kind == "D" and fromDrawer and state.phase == "draw" and state.drawer ~= room.me then
    local k = tonumber(fields[1])
    if k and k >= 1 and k < 10000 and fields[2] then
      takeMessage(state, k, fields[2])
    end
  elseif kind == "SEE" and Sketch.Drawing(room) and member.n ~= room.me then
    state.resend = true
  elseif kind == "G" and state.phase == "draw" and not fromDrawer then
    local text = tidy(fields[1])
    if text ~= "" then
      feed(state, { n = member.n, text = text })
    end
  elseif kind == "GOT" and state.phase == "draw" and not fromDrawer and not state.got[member.n] then
    state.got[member.n] = true
    state.order[#state.order + 1] = member.n
    feed(state, { n = member.n, got = true })
    if state.drawer == room.me and #state.order >= room.count - 1 then
      finish(room)
    end
  elseif kind == "END" and (fromDrawer or fromHost) and state.phase ~= "idle" then
    if tonumber(fields[1]) ~= state.round then
      return
    end
    if fromDrawer and fields[3] and fields[3] ~= "" and state.awarded ~= state.round then
      state.awarded = state.round
      for n, points in fields[3]:gmatch("(%d+)=(%d+)") do
        local other = room.members[tonumber(n)]
        if other then
          local gained = math.min(AWARDS[1], tonumber(points))
          other.score = other.score + gained
          state.gained[other.n] = gained
        end
      end
    end
    if fromDrawer and fields[2] and fields[2] ~= "-" then
      state.word = tidy((fields[2]:gsub("_", " ")))
    end
    if state.phase ~= "over" then
      state.phase, state.pending, state.pieces, state.choices = "over", nil, nil, nil
      feed(state, { note = "over", text = state.word })
      if room:IsHost() then
        state.nextAt = now + PAUSE
      end
    end
  elseif kind == "STOP" and fromHost then
    state.phase, state.pending, state.pieces, state.choices, state.nextAt = "idle", nil, nil, nil, nil
    feed(state, { note = "stopped" })
  end
end

--- @param room Room
--- @param now number
local function tick(room, now)
  local state = room.state
  if state.drawer == room.me then
    if state.phase == "pick" and state.choices and now >= state.pickBy then
      Sketch.Choose(room, 1)
    elseif state.phase == "draw" and now >= state.endsAt then
      finish(room)
    elseif state.phase == "draw" then
      local waiting = #state.pieces > 0 or (state.pending and #state.pending.points > 0)
      if waiting and room:Waiting("D") == 0 and now - (state.flushed or 0) >= FLUSH then
        sendPieces(room)
      end
      if state.resend and room.rooms:Backlog(3) == 0 and now - (state.resent or -60) >= 10 then
        state.resend, state.resent = nil, now
        for k = state.cleared or 1, state.top do
          room:Repeat("D", k, state.ops[k])
        end
      end
    end
  end

  if room:IsHost() then
    if state.phase == "pick" and now > state.pickBy + GRACE then
      local drawer = room.members[state.drawer]
      if drawer then
        drawer.away = true
      end
      room:Say("END", state.round, "-", "")
    elseif state.phase == "draw" and now > state.endsAt + GRACE then
      room:Say("END", state.round, "-", "")
    elseif state.phase == "over" and state.nextAt and now >= state.nextAt then
      state.nextAt = nil
      if room.count >= 2 then
        beginRound(room)
      else
        room:Say("STOP")
      end
    end
  end
end

--- @param room Room
--- @param member RoomMember
local function left(room, member)
  local state = room.state
  if not room:IsHost() or state.phase == "idle" then
    return
  end
  if member.n == state.drawer and state.phase ~= "over" then
    room:Say("END", state.round, "-", "")
  end
  if room.count < 2 then
    room:Say("STOP")
  end
end

--- On the host: tells somebody who came in late where the game is
--- @param room Room
--- @param member RoomMember
local function welcome(room, member)
  local state = room.state
  if state.phase ~= "pick" and state.phase ~= "draw" then
    return
  end
  room:Tell(member, "RND", state.round, state.drawer, state.length, state.list)
  if state.phase == "draw" then
    room:Tell(member, "WRD", state.hash, state.pattern, math.max(1, math.floor(state.endsAt - room:Now())))
  end
end

--- @param room Room
--- @param n number?
--- @return string
local function nameOf(room, n)
  local member = room.members[n]
  return member and private.Transport.DisplayName(member.name) or "?"
end

--- How the game stands, for the header over it and for the small window
--- @param room Room
--- @return string text, boolean urgent It is the player's to do something
local function statusOf(room)
  local state = room.state
  local mine, drawer = state.drawer == room.me, nameOf(room, state.drawer)
  if state.phase == "idle" then
    if room:IsHost() then
      return L[room.count < 2 and "sketch_alone" or "sketch_idle_host"], false
    end
    return L["sketch_idle"]:format(private.Transport.DisplayName(room.host)), false
  elseif state.phase == "pick" then
    return mine and L["sketch_pick"] or L["sketch_picking"]:format(drawer), mine
  elseif state.phase == "draw" then
    if mine then
      return L["sketch_draw_this"], true
    end
    return state.got[room.me] and L["sketch_you_got"] or L["sketch_drawing"]:format(drawer), false
  end
  return state.word and L["sketch_was"]:format(state.word) or L["sketch_skipped"], false
end

Rooms.Register({
  id = "sketch",
  name = L["game_sketch"],
  description = L["game_sketch_description"],
  icon = "Interface\\Icons\\INV_Inscription_Tradeskill01",
  version = 1,
  -- The picture waits behind everything the game can't do without
  lanes = { D = 2 },
  options = {
    {
      id = "length",
      name = L["sketch_option_length"],
      description = L["sketch_option_length_tip"],
      choices = Sketch.LENGTHS,
      default = USUAL_LENGTH,
      label = function(value)
        return L["sketch_seconds"]:format(value)
      end,
    },
    {
      id = "list",
      name = L["sketch_option_words"],
      description = L["sketch_option_words_tip"],
      choices = Sketch.LISTS,
      default = "b",
      label = function(value)
        return L["sketch_list_" .. value]
      end,
    },
  },
  new = function(_, rules)
    return {
      phase = "idle",
      round = 0,
      length = rules and rules.length or USUAL_LENGTH,
      list = rules and rules.list or "b",
      ops = {},
      top = 0,
      strokes = {},
      got = {},
      order = {},
      gained = {},
      feed = {},
      rev = 0,
    }
  end,
  receive = receive,
  tick = tick,
  left = left,
  welcome = welcome,
  status = statusOf,
  busy = function(room)
    local state = room.state
    return state.drawer == room.me and (state.phase == "pick" or state.phase == "draw")
  end,
  mark = function(room, member)
    local state = room.state
    if state.phase == "idle" then
      return nil
    end
    local gained = state.phase == "over" and state.gained[member.n]
    local color = (member.n == state.drawer and "gold") or (state.got[member.n] and "green") or nil
    return color, gained and ("+" .. gained) or nil
  end,
  view = function(parent)
    return private.SketchView.New(parent)
  end,
})

-----------------------------
-- View
-----------------------------
-- The sheet on the left as big as the room allows, and down its right who is playing, what they
-- guessed and where the player guesses. Over the sheet what it is (as far as the player may
-- know) and the time that is left, under it what whoever draws draws with. Made small it is the
-- sheet, the last thing said and the guess.

--- @class SketchView
--- @field frame Frame
local SketchView = {}
SketchView.__index = SketchView
private.SketchView = SketchView

-- The line over the sheet, the tools under it, and the space between things
local HINT, TOOLS, GAP = 28, 26, 8
-- The column down the right: never narrower or wider than this, and how much of it is for who is
-- playing
local COLUMN_LEAST, COLUMN_MOST, ROSTER_SHARE = 220, 300, 0.42
local FEED_LINE, GUESS_HEIGHT = 15, 24
local SMALL_HINT = 22
local DARK = { 0.12, 0.12, 0.12 }
local SHEET = Sketch.WIDTH / Sketch.HEIGHT

--- @param parent Frame
--- @return SketchView
function SketchView.New(parent)
  local Widgets, Canvas = private.Widgets, private.Canvas
  local self = setmetatable({ color = 1, pen = 2 }, SketchView)
  local frame = CreateFrame("Frame", nil, parent)
  self.frame = frame

  self.hint = Widgets.Label(frame, "GameFontHighlightLarge")
  self.hint:SetJustifyH("CENTER")
  self.hint:SetWordWrap(false)
  self.timer = Widgets.Label(frame, "GameFontNormalLarge")
  self.timer:SetJustifyH("RIGHT")

  local canvas = Canvas.New(frame, {
    width = Sketch.WIDTH,
    height = Sketch.HEIGHT,
    colors = Sketch.COLORS,
    widths = Sketch.WIDTHS,
    paper = Sketch.COLORS[Sketch.PAPER],
  })
  self.canvas = canvas
  canvas.onPen = function(x, y)
    local drawing = Sketch.Pen(self.room, self.color, self.pen, x, y)
    canvas:Render(self.room.state.strokes)
    return drawing
  end
  canvas.onDraw = function(x, y)
    -- What the pen does is seen at once, not when the window next looks
    Sketch.Draw(self.room, x, y)
    canvas:Render(self.room.state.strokes)
  end
  canvas.onLift = function()
    Sketch.Lift(self.room)
  end
  -- A hairline around the sheet, so that its edge is seen on the dark
  local edge = Widgets.Panel(frame)
  edge:SetPoint("TOPLEFT", canvas.frame, "TOPLEFT", -1, 1)
  edge:SetPoint("BOTTOMRIGHT", canvas.frame, "BOTTOMRIGHT", 1, -1)
  edge:SetBackdropColor(0, 0, 0, 0)
  edge:SetBackdropBorderColor(1, 0.82, 0, 0.25)
  edge:SetFrameLevel(canvas.frame:GetFrameLevel() + 1)
  edge:EnableMouse(false)

  -- What lies over the sheet while nothing is drawn on it
  local overlay = CreateFrame("Frame", nil, canvas.frame)
  overlay:SetAllPoints()
  overlay:SetFrameLevel(canvas.frame:GetFrameLevel() + 5)
  self.overlay = overlay
  self.notice = Widgets.Label(overlay, "GameFontNormalHuge")
  self.notice:SetPoint("LEFT", 16, 0)
  self.notice:SetPoint("RIGHT", -16, 0)
  self.notice:SetJustifyH("CENTER")
  self.notice:SetTextColor(unpack(DARK))
  self.notice:SetShadowColor(0, 0, 0, 0)
  self.detail = Widgets.Label(overlay, "GameFontHighlight")
  self.detail:SetPoint("TOP", self.notice, "BOTTOM", 0, -8)
  self.detail:SetPoint("LEFT", 16, 0)
  self.detail:SetPoint("RIGHT", -16, 0)
  self.detail:SetJustifyH("CENTER")
  self.detail:SetTextColor(0.35, 0.35, 0.35)
  self.detail:SetShadowColor(0, 0, 0, 0)

  self.picks = {}
  for index = 1, 3 do
    local pick = Widgets.Button(overlay, "", 200, 30)
    pick:SetNormalFontObject("GameFontNormalLarge")
    pick:SetHighlightFontObject("GameFontHighlightLarge")
    pick:SetScript("OnClick", function()
      Sketch.Choose(self.room, index)
    end)
    self.picks[index] = pick
  end
  self.start = Widgets.Button(overlay, L["sketch_start"], 200, 34)
  self.start:SetNormalFontObject("GameFontNormalLarge")
  self.start:SetHighlightFontObject("GameFontHighlightLarge")
  self.start:SetScript("OnClick", function()
    Sketch.Start(self.room)
  end)

  -- What whoever draws draws with
  local tools = CreateFrame("Frame", nil, frame)
  tools:SetHeight(TOOLS)
  self.tools = tools
  self.swatches, self.nibs = {}, {}
  for index, color in ipairs(Sketch.COLORS) do
    local swatch = CreateFrame("Button", nil, tools)
    swatch:SetSize(20, 20)
    swatch:SetPoint("LEFT", (index - 1) * 24 + 2, 0)
    swatch.edge = swatch:CreateTexture(nil, "BACKGROUND")
    swatch.edge:SetPoint("TOPLEFT", -2, 2)
    swatch.edge:SetPoint("BOTTOMRIGHT", 2, -2)
    local fill = swatch:CreateTexture(nil, "ARTWORK")
    fill:SetAllPoints()
    fill:SetColorTexture(color[1], color[2], color[3])
    swatch:SetScript("OnClick", function()
      self.color = index
      -- Rubbing out wants the widest there is, and drawing again doesn't
      self.pen = index == Sketch.PAPER and #Sketch.WIDTHS or (self.pen == #Sketch.WIDTHS and 2 or self.pen)
      self:paintTools()
    end)
    if index == Sketch.PAPER then
      swatch:SetScript("OnEnter", function(button)
        GameTooltip:SetOwner(button, "ANCHOR_TOP")
        GameTooltip:SetText(L["sketch_rubber"])
        GameTooltip:Show()
      end)
      swatch:SetScript("OnLeave", GameTooltip_Hide)
    end
    self.swatches[index] = swatch
  end
  for index in ipairs(Sketch.WIDTHS) do
    local nib = CreateFrame("Button", nil, tools)
    nib:SetSize(24, 22)
    nib:SetPoint("LEFT", #Sketch.COLORS * 24 + 14 + (index - 1) * 27, 0)
    nib.edge = nib:CreateTexture(nil, "BACKGROUND")
    nib.edge:SetAllPoints()
    local dot = Widgets.Icon(nib, "Interface\\AddOns\\ForeverGames\\Images\\Board\\dot", 3 + index * 4)
    dot:SetPoint("CENTER")
    nib:SetScript("OnClick", function()
      self.pen = index
      self:paintTools()
    end)
    self.nibs[index] = nib
  end
  local undo = Widgets.Button(tools, L["sketch_undo"], 64, 22)
  undo:SetPoint("LEFT", self.nibs[#self.nibs], "RIGHT", 14, 0)
  undo:SetScript("OnClick", function()
    Sketch.Undo(self.room)
    self:Update(self.room)
  end)
  local clear = Widgets.Button(tools, L["sketch_clear"], 64, 22)
  clear:SetPoint("LEFT", undo, "RIGHT", 4, 0)
  clear:SetScript("OnClick", function()
    Sketch.Clear(self.room)
    self:Update(self.room)
  end)
  self:paintTools()

  -- Whoever opened the room ends the game from where the tools are, when they aren't drawing
  self.stop = Widgets.Button(frame, L["sketch_stop"], 110, 22)
  self.stop:SetPoint("RIGHT", tools, "RIGHT", 0, 0)
  self.stop:SetScript("OnClick", function()
    Sketch.Stop(self.room)
  end)

  -- Down the right: who is playing, what everybody guessed, and where the player does
  self.roster = private.Party.Roster(frame)
  self.feedPanel = Widgets.Panel(frame)
  local feedTitle = Widgets.Label(self.feedPanel, "GameFontNormal", L["sketch_guesses"])
  feedTitle:SetPoint("TOPLEFT", 8, -8)
  self.feedTitle = feedTitle
  self.feed = Widgets.Label(self.feedPanel, "GameFontHighlightSmall")
  self.feed:SetJustifyV("BOTTOM")
  self.feed:SetWordWrap(false)
  self.feed:SetSpacing(3)

  local guess = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
  guess:SetHeight(GUESS_HEIGHT)
  guess:SetAutoFocus(false)
  guess:SetMaxLetters(GUESS_LENGTH)
  guess:SetScript("OnEnterPressed", function(box)
    local ok, right = Sketch.Guess(self.room, box:GetText() or "")
    box:SetText("")
    if not ok or right == true then
      box:ClearFocus()
    end
    if right == true then
      Widgets.PlaySound("chipsCollide")
    end
  end)
  guess:SetScript("OnEscapePressed", guess.ClearFocus)
  guess:SetScript("OnTextChanged", function(box)
    self.guessHint:SetShown((box:GetText() or "") == "")
  end)
  self.guess = guess
  self.guessHint = Widgets.Label(guess, "GameFontDisable", L["sketch_guess_here"])
  self.guessHint:SetPoint("LEFT", 2, 0)
  return self
end

--- Shows which colour and which width the pen has
function SketchView:paintTools()
  for index, swatch in ipairs(self.swatches) do
    local on = index == self.color
    swatch.edge:SetColorTexture(1, on and 0.82 or 1, on and 0 or 1, on and 1 or 0.15)
  end
  for index, nib in ipairs(self.nibs) do
    local on = index == self.pen
    nib.edge:SetColorTexture(1, 0.82, 0, on and 0.5 or 0.08)
  end
end

--- @param width number
--- @param height number
--- @param compact boolean? There is only room for the picture and a guess
function SketchView:Layout(width, height, compact)
  self.compact = compact
  self.frame:SetSize(width, height)
  local canvas, feed, guess, hint, timer = self.canvas.frame, self.feedPanel, self.guess, self.hint, self.timer
  for _, region in ipairs({ canvas, feed, guess, hint, timer, self.tools }) do
    region:ClearAllPoints()
  end
  self.roster.frame:SetShown(not compact)
  self.feedTitle:SetShown(not compact)

  if compact then
    -- The sheet, a line of what was said last, and the guess
    local below = GAP + FEED_LINE + 10 + GAP + GUESS_HEIGHT
    local sheetWidth = math.floor(math.min(width, (height - SMALL_HINT - below) * SHEET))
    self.canvas:Layout(sheetWidth)
    canvas:SetPoint("TOP", 0, -SMALL_HINT)
    hint:SetPoint("BOTTOMLEFT", canvas, "TOPLEFT", 2, 5)
    hint:SetPoint("BOTTOMRIGHT", canvas, "TOPRIGHT", -40, 5)
    timer:SetPoint("BOTTOMRIGHT", canvas, "TOPRIGHT", -2, 4)
    feed:SetPoint("TOPLEFT", canvas, "BOTTOMLEFT", 0, -GAP)
    feed:SetPoint("TOPRIGHT", canvas, "BOTTOMRIGHT", 0, -GAP)
    feed:SetHeight(FEED_LINE + 10)
    self.feed:ClearAllPoints()
    self.feed:SetPoint("TOPLEFT", 8, -5)
    self.feed:SetPoint("BOTTOMRIGHT", -8, 5)
    guess:SetPoint("TOPLEFT", feed, "BOTTOMLEFT", 6, -GAP)
    guess:SetPoint("TOPRIGHT", feed, "BOTTOMRIGHT", 0, -GAP)
    self.feedLines = 1
  else
    -- As big a sheet as there is room for, with a column next to it that is neither cramped
    -- nor wider than it needs to be. Whatever is over goes either side of the two, evenly
    local sheetHeight = height - HINT - GAP - TOOLS
    local sheetWidth = math.floor(sheetHeight * SHEET)
    local column = width - sheetWidth - GAP
    if column < COLUMN_LEAST then
      column = COLUMN_LEAST
      sheetWidth = width - column - GAP
    end
    column = math.min(column, COLUMN_MOST)
    self.canvas:Layout(sheetWidth)
    local left = math.floor((width - sheetWidth - GAP - column) / 2)
    canvas:SetPoint("TOPLEFT", left, -HINT)
    hint:SetPoint("BOTTOMLEFT", canvas, "TOPLEFT", 60, 7)
    hint:SetPoint("BOTTOMRIGHT", canvas, "TOPRIGHT", -60, 7)
    timer:SetPoint("BOTTOMRIGHT", canvas, "TOPRIGHT", -2, 6)
    self.tools:SetPoint("TOPLEFT", canvas, "BOTTOMLEFT", 0, -GAP)
    self.tools:SetPoint("TOPRIGHT", canvas, "BOTTOMRIGHT", 0, -GAP)

    -- The column runs from the top of everything to the bottom of the tools
    local columnHeight = HINT + canvas:GetHeight() + GAP + TOOLS
    local rosterHeight = math.floor(columnHeight * ROSTER_SHARE)
    self.roster:Layout(column, rosterHeight)
    self.roster.frame:ClearAllPoints()
    self.roster.frame:SetPoint("TOPLEFT", left + sheetWidth + GAP, 0)
    feed:SetPoint("TOPLEFT", self.roster.frame, "BOTTOMLEFT", 0, -GAP)
    feed:SetSize(column, columnHeight - rosterHeight - GAP * 2 - GUESS_HEIGHT)
    self.feed:ClearAllPoints()
    self.feed:SetPoint("TOPLEFT", 8, -28)
    self.feed:SetPoint("BOTTOMRIGHT", -8, 6)
    guess:SetPoint("TOPLEFT", feed, "BOTTOMLEFT", 6, -GAP)
    guess:SetPoint("TOPRIGHT", feed, "BOTTOMRIGHT", 0, -GAP)
    self.feedLines = math.max(1, math.floor((feed:GetHeight() - 34) / (FEED_LINE + 3)))
  end

  -- The choices and the button over the sheet stand in its middle, whatever its size
  local middle = canvas:GetHeight() / 2
  self.notice:ClearAllPoints()
  self.notice:SetPoint("TOP", 0, -math.max(12, middle - (compact and 70 or 100)))
  self.notice:SetPoint("LEFT", 16, 0)
  self.notice:SetPoint("RIGHT", -16, 0)
  self.notice:SetFontObject(compact and "GameFontNormalLarge" or "GameFontNormalHuge")
  for index, pick in ipairs(self.picks) do
    pick:ClearAllPoints()
    pick:SetPoint("TOP", self.notice, "BOTTOM", 0, -(compact and 8 or 18) - (index - 1) * (compact and 32 or 38))
  end
  self.start:ClearAllPoints()
  self.start:SetPoint("TOP", self.detail, "BOTTOM", 0, compact and -10 or -22)
  self.feedSeen = nil
end

--- @param room Room
--- @param lines number How many of the last things said there is room for
--- @return string
local function feedText(room, lines)
  local state, shown = room.state, {}
  for index = math.max(1, #state.feed - lines + 1), #state.feed do
    local entry = state.feed[index]
    local name = nameOf(room, entry.n)
    if entry.note == "round" then
      shown[#shown + 1] = "|cffffd100" .. L["sketch_feed_round"]:format(name) .. "|r"
    elseif entry.note == "over" then
      local what = entry.text and L["sketch_feed_was"]:format(entry.text) or L["sketch_feed_skipped"]
      shown[#shown + 1] = "|cffa6a6a6" .. what .. "|r"
    elseif entry.note == "stopped" then
      shown[#shown + 1] = "|cffa6a6a6" .. L["sketch_feed_stopped"] .. "|r"
    elseif entry.got then
      shown[#shown + 1] = "|cff4de64d" .. L["sketch_feed_got"]:format(name) .. "|r"
    else
      shown[#shown + 1] = "|cffffd100" .. name .. ":|r " .. entry.text
    end
  end
  return table.concat(shown, "\n")
end

--- @param room Room
--- @return string? Who won, once there was a game to win
local function winner(room)
  local best
  for _, member in ipairs(room:Members()) do
    if member.score > 0 and (not best or member.score > best.score) then
      best = member
    end
  end
  return best and L["sketch_leader"]:format(nameOf(room, best.n), best.score) or nil
end

--- @param room Room
function SketchView:Update(room)
  local Widgets = private.Widgets
  self.room = room
  local state = room.state
  local phase, mine, host = state.phase, state.drawer == room.me, room:IsHost()
  local drawing = Sketch.Drawing(room)
  local status = statusOf(room)

  -- Over the sheet: the word as far as the player may know it, and small, how the game stands
  local hint = (phase == "draw" or phase == "over") and Sketch.Hint(room) or nil
  self.hint:SetText(hint or (self.compact and status or ""))
  self.hint:SetFontObject((self.compact or not hint or #hint > 40) and "GameFontHighlight" or "GameFontHighlightLarge")
  local left = Sketch.TimeLeft(room)
  self.timer:SetText(left and math.ceil(left) or "")
  self.timer:SetTextColor(unpack(left and left <= 10 and Widgets.RED or Widgets.GOLD))

  self.canvas:Render(state.strokes)
  self.canvas:SetInk(drawing)

  -- On the sheet while nothing is drawn on it: what is about to happen
  self.overlay:SetShown(phase == "idle" or phase == "pick")
  local notice, detail = status, ""
  if phase == "idle" then
    notice = state.round > 0 and (winner(room) or L["sketch_feed_stopped"]) or L["game_sketch"]
    detail = L["sketch_rules_line"]:format(state.length, L["sketch_list_" .. state.list])
    if not host then
      detail = status
    elseif room.count < 2 then
      detail = L["sketch_alone"]
    end
  end
  self.notice:SetText(notice)
  self.detail:SetText(detail)
  for index, pick in ipairs(self.picks) do
    local word = phase == "pick" and mine and state.choices and state.choices[index]
    pick:SetShown(word ~= nil and word ~= false)
    if word then
      pick:SetText(word)
    end
  end
  self.start:SetShown(phase == "idle" and host)
  self.start:SetEnabled(room.count >= 2)
  self.start:SetText(L[state.round > 0 and "sketch_again" or "sketch_start"])

  self.tools:SetShown(drawing and not self.compact)
  self.stop:SetShown(host and phase ~= "idle" and not drawing and not self.compact)

  if not self.compact then
    self.roster:Update(room)
  end
  local last = state.feed[#state.feed]
  if self.feedSeen ~= last or self.feedCount ~= room.count then
    self.feedSeen, self.feedCount = last, room.count
    local text = feedText(room, self.feedLines or 1)
    self.feed:SetText(text ~= "" and text or (self.compact and "" or "|cff808080" .. L["sketch_no_guesses"] .. "|r"))
  end
  local guessing = phase == "draw" and not mine and not state.got[room.me]
  self.guess:SetEnabled(guessing)
  self.guess:SetAlpha(guessing and 1 or 0.4)
  self.guessHint:SetText(L[guessing and "sketch_guess_here" or (state.got[room.me] and phase == "draw" and "sketch_you_got" or "sketch_guess_wait")])
  if not guessing and self.guess:HasFocus() then
    self.guess:ClearFocus()
  end
end
