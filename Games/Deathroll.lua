--------------------------
--  Deathroll
--------------------------
-- The gamble of every tavern in Azeroth, as a tourney for a room (Engine/Rooms.lua). Two players
-- take turns rolling: the first from 1 to the number the tourney starts at, each after that from
-- 1 to what the other just rolled, and whoever rolls a 1 is out. The host draws everyone in the
-- room into a bracket, every duel of a round is rolled at once, and the winners meet in the next
-- round until one is left. Whoever doesn't roll in time has it rolled for them, so a raid's worth
-- of players is through in a couple of minutes.
--
--   RND:round:start:seconds:duels[:late]
--                                from the host: these duels are rolled now, from this number,
--                                with this long for each roll. The duels are member numbers with
--                                a "." between them, "3-5.7.2-9": of a pair the first rolls
--                                first, and one on their own goes through to the next round
--                                without rolling. With round 1 a new tourney begins and everyone
--                                has nothing, unless it is `late`: told to somebody who just came
--                                in, who is only being told where the tourney is
--   R:round:k:max:value          from a player in a duel: their roll, the k-th of the duel, from 1
--                                to max
--   FF:round:n                   from the host: member n is out of their duel, gone or never
--                                rolling
--   ST:round:first:duels         from the host to somebody who came in late: how the duels from
--                                number `first` on stand, "k/max/winner" each with a "." between
--   END:n                        from the host: member n won the tourney, 0 if nobody did
--   STOP                         from the host: the tourney is called off
--
-- A roll is made by the client of whoever rolls and nobody else checks it, which between friends
-- is what a game here does. It also keeps every roll out of the chat window: forty players rolling
-- at once would leave no room in it for anything else.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Rooms = private.Rooms

--- @class Deathroll
local Deathroll = {}
private.Deathroll = Deathroll

Deathroll.STARTS = { 100, 1000, 10000 }
Deathroll.PACES = { 5, 10, 20 }
local USUAL_START, USUAL_PACE = 1000, 10
-- Seconds the host gives a roll on top of the time for it before taking the player to be gone,
-- and between two rounds
local GRACE, PAUSE = 8, 5

--- @class DeathrollRoll
--- @field n number Who rolled
--- @field value number
--- @field max number

--- @class DeathrollDuel
--- @field a number Rolls first
--- @field b number? Nobody: `a` goes through without rolling
--- @field k number How many rolls there have been
--- @field max number What the next roll is from 1 to
--- @field at number When the last roll was, or the duel began
--- @field winner number?
--- @field rolls DeathrollRoll[]

-----------------------------
-- Duels
-----------------------------

--- Whose roll it is
--- @param duel DeathrollDuel
--- @return number? n Nobody's once the duel is over
local function turnOf(duel)
  if duel.winner then
    return nil
  end
  return duel.k % 2 == 0 and duel.a or duel.b
end
Deathroll.TurnOf = turnOf

--- @param duel DeathrollDuel
--- @param n number One of the two
--- @return number? The other
local function otherOf(duel, n)
  if n == duel.a then
    return duel.b
  end
  return duel.a
end
Deathroll.OtherOf = otherOf

--- @param duels { a: number, b: number? }[]
--- @return string
local function encode(duels)
  local entries = {}
  for _, duel in ipairs(duels) do
    entries[#entries + 1] = duel.b and (duel.a .. "-" .. duel.b) or tostring(duel.a)
  end
  return table.concat(entries, ".")
end

--- @param text string?
--- @return { a: number, b: number? }[]?
local function decode(text)
  local duels = {}
  for entry in (text or ""):gmatch("[^.]+") do
    local a, b = entry:match("^(%d+)%-(%d+)$")
    a = tonumber(a or entry:match("^(%d+)$"))
    if not a then
      return nil
    end
    duels[#duels + 1] = { a = a, b = tonumber(b) }
  end
  return #duels > 0 and duels or nil
end

--- @param room Room
--- @param duel DeathrollDuel
--- @param winner number?
local function decide(room, duel, winner)
  duel.winner = winner or 0
  local member = room.members[duel.winner]
  if member then
    member.score = member.score + 1
  end
end

--- @param room Room
--- @param duels { a: number, b: number? }[]
local function begin(room, duels)
  local state = room.state
  room:Say("RND", state.round + 1, state.start, state.seconds, encode(duels))
end

-----------------------------
-- What the players do
-----------------------------

--- On the host: draws everyone in the room into a bracket and starts it
--- @param room Room
--- @param rules { start: number?, seconds: number? }?
--- @return boolean ok, string? error
function Deathroll.Start(room, rules)
  local state = room.state
  if not room:IsHost() then
    return false, "not_host"
  elseif room.count < 2 then
    return false, "deathroll_alone"
  elseif state.phase == "play" then
    return false, "deathroll_playing"
  end
  state.start = rules and rules.start or state.start
  state.seconds = rules and rules.seconds or state.seconds

  local players = {}
  for _, member in ipairs(room:Members()) do
    players[#players + 1] = member.n
  end
  for index = #players, 2, -1 do
    local other = room:Random(index)
    players[index], players[other] = players[other], players[index]
  end
  -- Whoever is left over goes through the first round without rolling, as many as it takes to
  -- leave a number of players that halves all the way down to one. Nobody goes through after it
  local size = 1
  while size < #players do
    size = size * 2
  end
  local duels = {}
  for index = 1, size - #players do
    duels[#duels + 1] = { a = players[index] }
  end
  for index = size - #players + 1, #players, 2 do
    duels[#duels + 1] = { a = players[index], b = players[index + 1] }
  end
  state.round = 0
  begin(room, duels)
  return true
end

--- On the host: calls the tourney off, the room stays
--- @param room Room
function Deathroll.Stop(room)
  if room:IsHost() and room.state.phase == "play" then
    room:Say("STOP")
  end
end

--- @param room Room
--- @return DeathrollDuel? The local player's in this round, while there is a round
function Deathroll.MyDuel(room)
  local state = room.state
  return state.phase == "play" and state.duelOf[room.me] or nil
end

--- Whether it is the local player's roll
--- @param room Room
--- @return boolean
function Deathroll.MyRoll(room)
  local duel = Deathroll.MyDuel(room)
  return duel ~= nil and turnOf(duel) == room.me
end

--- The local player rolls
--- @param room Room
--- @return boolean rolled False if it isn't their roll
function Deathroll.Roll(room)
  local state = room.state
  local duel = Deathroll.MyDuel(room)
  if not duel or turnOf(duel) ~= room.me then
    return false
  end
  room:Say("R", state.round, duel.k + 1, duel.max, room:Random(duel.max))
  return true
end

--- @param room Room
--- @param duel DeathrollDuel?
--- @return number? Seconds left for the roll that is due in a duel, nil if none is
function Deathroll.TimeLeft(room, duel)
  if not duel or room.state.phase ~= "play" or not turnOf(duel) then
    return nil
  end
  return math.max(0, duel.at + room.state.seconds - room:Now())
end

--- How many are still in the tourney
--- @param room Room
--- @return number
function Deathroll.Left(room)
  local count = 0
  for _, duel in ipairs(room.state.duels) do
    count = count + ((duel.winner and 1) or (duel.b and 2 or 1))
  end
  return count
end

-----------------------------
-- What is said in the room
-----------------------------

--- @param room Room
--- @param member RoomMember
--- @param kind string
--- @param fields string[]
local function receive(room, member, kind, fields)
  local state = room.state
  local fromHost = member.name == room.host
  local now = room:Now()

  if kind == "RND" and fromHost then
    local round, start, seconds, duels = tonumber(fields[1]), tonumber(fields[2]), tonumber(fields[3]), decode(fields[4])
    if not (round and start and seconds and duels) then
      return
    end
    if round == 1 and fields[5] ~= "1" then
      for _, other in pairs(room.members) do
        other.score = 0
      end
    end
    state.round, state.start, state.seconds = round, math.max(2, start), math.max(1, math.min(60, seconds))
    state.phase, state.champion, state.stopped, state.nextAt = "play", nil, nil, nil
    state.entries, state.duels, state.duelOf = fields[4], {}, {}
    for _, entry in ipairs(duels) do
      --- @type DeathrollDuel
      local duel = { a = entry.a, b = entry.b, k = 0, max = state.start, at = now, rolls = {} }
      if not entry.b then
        duel.winner = entry.a
      end
      state.duels[#state.duels + 1] = duel
      state.duelOf[entry.a] = duel
      if entry.b then
        state.duelOf[entry.b] = duel
      end
    end
  elseif kind == "R" and state.phase == "play" then
    local round, k, max, value = tonumber(fields[1]), tonumber(fields[2]), tonumber(fields[3]), tonumber(fields[4])
    local duel = state.duelOf[member.n]
    if round ~= state.round or not duel or duel.winner or not (k and max and value) or k <= duel.k then
      return
    end
    -- A roll that went missing on the way is no reason to doubt the next: it says where it is from
    local roller = k % 2 == 1 and duel.a or duel.b
    if roller ~= member.n or value < 1 or value > max then
      return
    end
    duel.k, duel.max, duel.at = k, value, now
    duel.rolls[#duel.rolls + 1] = { n = member.n, value = value, max = max }
    if value == 1 then
      decide(room, duel, otherOf(duel, member.n))
    end
  elseif kind == "FF" and fromHost and state.phase == "play" then
    local n = tonumber(fields[2])
    local duel = n and state.duelOf[n]
    if tonumber(fields[1]) == state.round and duel and not duel.winner then
      duel.forfeit = n
      decide(room, duel, otherOf(duel, n))
    end
  elseif kind == "ST" and fromHost and state.phase == "play" and tonumber(fields[1]) == state.round then
    local index = tonumber(fields[2]) or 1
    for k, max, winner in (fields[3] or ""):gmatch("(%d+)/(%d+)/(%d+)") do
      local duel = state.duels[index]
      if duel then
        duel.k, duel.max = tonumber(k), tonumber(max)
        duel.winner = winner ~= "0" and tonumber(winner) or duel.winner
      end
      index = index + 1
    end
  elseif kind == "END" and fromHost and state.phase == "play" then
    local n = tonumber(fields[1])
    state.phase, state.nextAt = "idle", nil
    state.champion = n ~= 0 and n or nil
  elseif kind == "STOP" and fromHost then
    state.phase, state.nextAt, state.champion, state.stopped = "idle", nil, nil, true
  else
    return
  end
  state.rev = state.rev + 1
end

--- On the host: the next round, of whoever won this one and is still here, or the end of it
--- @param room Room
local function nextRound(room)
  local state = room.state
  local winners = {}
  for _, duel in ipairs(state.duels) do
    if duel.winner and room.members[duel.winner] then
      winners[#winners + 1] = duel.winner
    end
  end
  if #winners <= 1 then
    room:Say("END", winners[1] or 0)
    return
  end
  -- In the order of the bracket, so that it stays one. Somebody left over when somebody else
  -- left goes through
  local duels = {}
  for index = 1, #winners, 2 do
    local a, b = winners[index], winners[index + 1]
    if b and room:Random(2) == 2 then
      a, b = b, a
    end
    duels[#duels + 1] = { a = a, b = b }
  end
  begin(room, duels)
end

--- @param room Room
--- @param now number
local function tick(room, now)
  local state = room.state
  if state.phase ~= "play" then
    return
  end
  -- Whoever doesn't roll has it rolled for them
  if Deathroll.MyRoll(room) and now >= state.duelOf[room.me].at + state.seconds then
    Deathroll.Roll(room)
  end
  if not room:IsHost() then
    return
  end

  local done = true
  for _, duel in ipairs(state.duels) do
    local due = turnOf(duel)
    if due then
      done = false
      -- Their client would have rolled by now: there is no client
      if now >= duel.at + state.seconds + GRACE then
        local member = room.members[due]
        if member then
          member.away = true
        end
        room:Say("FF", state.round, due)
      end
    end
  end
  if done and not state.nextAt then
    state.nextAt = now + PAUSE
  elseif done and now >= state.nextAt then
    state.nextAt = nil
    nextRound(room)
  end
end

--- @param room Room
--- @param member RoomMember
local function left(room, member)
  local state = room.state
  local duel = state.duelOf[member.n]
  if room:IsHost() and state.phase == "play" and duel and not duel.winner then
    room:Say("FF", state.round, member.n)
  end
end

--- On the host: tells somebody who came in late where the tourney is. They watch until the next
--- @param room Room
--- @param member RoomMember
local function welcome(room, member)
  local state = room.state
  if state.phase ~= "play" then
    return
  end
  room:Tell(member, "RND", state.round, state.start, state.seconds, state.entries, 1)
  local head = "ST:" .. state.round .. ":"
  local first, chunk = 1, {}
  local function flush(index)
    if #chunk > 0 then
      room:Tell(member, "ST", state.round, first, table.concat(chunk, "."))
    end
    first, chunk = index, {}
  end
  for index, duel in ipairs(state.duels) do
    local entry = duel.k .. "/" .. duel.max .. "/" .. (duel.winner or 0)
    if #head + #tostring(first) + 1 + #table.concat(chunk, ".") + 1 + #entry > Rooms.PAYLOAD then
      flush(index)
    end
    chunk[#chunk + 1] = entry
  end
  flush(#state.duels + 1)
end

--- @param room Room
--- @param n number?
--- @return string
local function nameOf(room, n)
  local member = room.members[n]
  return member and private.Transport.DisplayName(member.name) or "?"
end
Deathroll.NameOf = nameOf

--- How the game stands, for the header over it and for the small window
--- @param room Room
--- @return string text, boolean urgent It is the player's to do something
local function statusOf(room)
  local state = room.state
  if state.phase == "idle" then
    if room:IsHost() then
      return L[room.count < 2 and "deathroll_alone" or "deathroll_idle_host"], false
    end
    return L["deathroll_idle"]:format(private.Transport.DisplayName(room.host)), false
  end
  local duel = state.duelOf[room.me]
  if not duel then
    return L["deathroll_watching"], false
  elseif turnOf(duel) == room.me then
    return L["deathroll_your_roll"]:format(duel.max), true
  elseif turnOf(duel) then
    return L["deathroll_their_roll"]:format(nameOf(room, turnOf(duel)), duel.max), false
  elseif duel.winner == room.me then
    return L[duel.b and "deathroll_won" or "deathroll_through"], false
  end
  return L["deathroll_out"], false
end

Rooms.Register({
  id = "deathroll",
  name = L["game_deathroll"],
  description = L["game_deathroll_description"],
  icon = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01",
  version = 1,
  options = {
    {
      id = "start",
      name = L["deathroll_option_start"],
      description = L["deathroll_option_start_tip"],
      choices = Deathroll.STARTS,
      default = USUAL_START,
    },
    {
      id = "seconds",
      name = L["deathroll_option_pace"],
      description = L["deathroll_option_pace_tip"],
      choices = Deathroll.PACES,
      default = USUAL_PACE,
      label = function(value)
        return L["deathroll_seconds"]:format(value)
      end,
    },
  },
  new = function(_, rules)
    return {
      phase = "idle",
      round = 0,
      start = rules and rules.start or USUAL_START,
      seconds = rules and rules.seconds or USUAL_PACE,
      duels = {},
      duelOf = {},
      rev = 0,
    }
  end,
  receive = receive,
  tick = tick,
  left = left,
  welcome = welcome,
  status = statusOf,
  mark = function(room, member)
    local state = room.state
    if state.phase == "idle" then
      return member.n == state.champion and "gold" or nil
    end
    local duel = state.duelOf[member.n]
    if duel and turnOf(duel) == member.n then
      return "gold"
    end
    return duel and (not duel.winner or duel.winner == member.n) and "green" or nil
  end,
  view = function(parent)
    return private.DeathrollView.New(parent)
  end,
})

-----------------------------
-- View
-----------------------------
-- On the left the player's own duel, big, with the button to roll, and under it every duel of
-- the round. Down the right who is playing and how many duels they won. Somebody who is out, or
-- came in late, is shown the duel that is still being rolled instead of their own. Made small it
-- is the duel and the button.

--- @class DeathrollView
--- @field frame Frame
local DeathrollView = {}
DeathrollView.__index = DeathrollView
private.DeathrollView = DeathrollView

-- The line over the duel, the duel, a row of the list, and the space between things
local TITLE, CARD, ROW, GAP = 26, 210, 22, 8
-- The column down the right: never narrower or wider than this
local COLUMN_LEAST, COLUMN_MOST = 200, 260
local BUTTON_ROW = 26
-- How many of a duel's rolls are listed under its names
local HISTORY = 6

--- @param parent Frame
--- @return DeathrollView
function DeathrollView.New(parent)
  local Widgets = private.Widgets
  local self = setmetatable({}, DeathrollView)
  local frame = CreateFrame("Frame", nil, parent)
  self.frame = frame

  self.title = Widgets.Label(frame, "GameFontNormalLarge")
  self.title:SetWordWrap(false)
  self.left = Widgets.Label(frame, "GameFontHighlight")
  self.left:SetJustifyH("RIGHT")

  -- The duel
  local card = Widgets.Panel(frame)
  self.card = card
  self.nameA = Widgets.Label(card, "GameFontNormalLarge")
  self.nameA:SetPoint("TOPLEFT", 14, -14)
  self.nameA:SetPoint("RIGHT", card, "CENTER", -22, 0)
  self.nameA:SetWordWrap(false)
  self.versus = Widgets.Label(card, "GameFontDisable", L["deathroll_versus"])
  self.versus:SetPoint("TOP", 0, -16)
  self.nameB = Widgets.Label(card, "GameFontNormalLarge")
  self.nameB:SetPoint("TOPRIGHT", -14, -14)
  self.nameB:SetPoint("LEFT", card, "CENTER", 22, 0)
  self.nameB:SetJustifyH("RIGHT")
  self.nameB:SetWordWrap(false)
  self.history = Widgets.Label(card, "GameFontDisableSmall")
  self.history:SetPoint("TOP", 0, -40)
  self.history:SetPoint("LEFT", 14, 0)
  self.history:SetPoint("RIGHT", -14, 0)
  self.history:SetJustifyH("CENTER")
  self.history:SetWordWrap(false)
  self.number = Widgets.Label(card, "GameFontNormalHuge")
  self.number:SetJustifyH("CENTER")
  self.detail = Widgets.Label(card, "GameFontHighlight")
  self.detail:SetPoint("TOP", self.number, "BOTTOM", 0, -8)
  self.detail:SetPoint("LEFT", 14, 0)
  self.detail:SetPoint("RIGHT", -14, 0)
  self.detail:SetJustifyH("CENTER")

  self.roll = Widgets.Button(card, "", 180, 34)
  self.roll:SetNormalFontObject("GameFontNormalLarge")
  self.roll:SetHighlightFontObject("GameFontHighlightLarge")
  self.roll:SetPoint("BOTTOM", 0, 30)
  self.roll:SetScript("OnClick", function()
    if Deathroll.Roll(self.room) then
      Widgets.PlaySound("dieThrow")
      self:Update(self.room)
    end
  end)
  self.auto = Widgets.Label(card, "GameFontDisableSmall")
  self.auto:SetPoint("TOP", self.roll, "BOTTOM", 0, -5)
  self.start = Widgets.Button(card, L["deathroll_start"], 200, 34)
  self.start:SetNormalFontObject("GameFontNormalLarge")
  self.start:SetHighlightFontObject("GameFontHighlightLarge")
  self.start:SetPoint("BOTTOM", 0, 30)
  self.start:SetScript("OnClick", function()
    local ok, err = Deathroll.Start(self.room)
    if not ok and err then
      ForeverGames:Print(L["err_" .. err])
    end
  end)

  -- Every duel of the round
  self.listPanel = Widgets.Panel(frame)
  self.listTitle = Widgets.Label(self.listPanel, "GameFontNormal")
  self.listTitle:SetPoint("TOPLEFT", 8, -8)
  self.list = Widgets.List(self.listPanel, 100, ROW, function(content)
    local row = CreateFrame("Frame", nil, content)
    row.middle = Widgets.Label(row, "GameFontHighlightSmall")
    row.middle:SetPoint("CENTER")
    row.middle:SetWidth(70)
    row.middle:SetJustifyH("CENTER")
    row.a = Widgets.Label(row, "GameFontHighlightSmall")
    row.a:SetPoint("LEFT", 6, 0)
    row.a:SetPoint("RIGHT", row.middle, "LEFT", -4, 0)
    row.a:SetJustifyH("RIGHT")
    row.a:SetWordWrap(false)
    row.b = Widgets.Label(row, "GameFontHighlightSmall")
    row.b:SetPoint("RIGHT", -6, 0)
    row.b:SetPoint("LEFT", row.middle, "RIGHT", 4, 0)
    row.b:SetWordWrap(false)
    return row
  end)
  self.list.frame:SetPoint("TOPLEFT", 2, -28)
  self.list.frame:SetPoint("BOTTOMRIGHT", -2, 4)

  self.stop = Widgets.Button(frame, L["deathroll_stop"], 130, 22)
  self.stop:SetScript("OnClick", function()
    Deathroll.Stop(self.room)
  end)

  self.roster = private.Party.Roster(frame)
  return self
end

--- @param width number
--- @param height number
--- @param compact boolean? There is only room for the duel
function DeathrollView:Layout(width, height, compact)
  self.compact = compact
  self.frame:SetSize(width, height)
  for _, region in ipairs({ self.title, self.left, self.card, self.listPanel, self.stop, self.number }) do
    region:ClearAllPoints()
  end
  self.roster.frame:SetShown(not compact)
  self.listPanel:SetShown(not compact)

  local main = width
  if not compact then
    local column = math.max(COLUMN_LEAST, math.min(COLUMN_MOST, math.floor(width * 0.28)))
    main = width - column - GAP
    self.roster:Layout(column, height)
    self.roster.frame:ClearAllPoints()
    self.roster.frame:SetPoint("TOPRIGHT")
  end

  self.title:SetPoint("TOPLEFT", 2, -4)
  self.title:SetWidth(compact and main - 4 or main - 120)
  self.title:SetFontObject(compact and "GameFontNormal" or "GameFontNormalLarge")
  self.left:SetPoint("TOPRIGHT", self.frame, "TOPLEFT", main - 2, -5)
  self.card:SetPoint("TOPLEFT", 0, -TITLE)
  local cardHeight = compact and height - TITLE or CARD
  self.card:SetSize(main, cardHeight)
  self.number:SetPoint("CENTER", self.card, "CENTER", 0, compact and 20 or 14)
  self.number:SetWidth(main - 28)

  if not compact then
    self.listPanel:SetPoint("TOPLEFT", self.card, "BOTTOMLEFT", 0, -GAP)
    self.listPanel:SetSize(main, height - TITLE - cardHeight - GAP * 2 - BUTTON_ROW)
    self.list:SetWidth(main - 4)
    self.stop:SetPoint("TOPRIGHT", self.listPanel, "BOTTOMRIGHT", 0, -GAP + 2)
  end
end

--- Which duel the player is shown: their own while they are in one, else the first that is still
--- being rolled, else the last there was
--- @param room Room
--- @return DeathrollDuel?
local function featured(room)
  local state = room.state
  local mine = state.duelOf[room.me]
  if mine and (state.phase == "play" or mine.winner) then
    return mine
  end
  local last
  for _, duel in ipairs(state.duels) do
    if not duel.winner then
      return duel
    end
    last = duel.b and duel or last
  end
  return last
end

--- @param room Room
--- @param duel DeathrollDuel
--- @return string
local function historyOf(room, duel)
  local parts = {}
  for index = math.max(1, #duel.rolls - HISTORY + 1), #duel.rolls do
    local roll = duel.rolls[index]
    parts[#parts + 1] = (roll.n == duel.a and "|cffffd100%d|r" or "|cff99ccff%d|r"):format(roll.value)
  end
  if #duel.rolls > HISTORY then
    table.insert(parts, 1, "...")
  else
    table.insert(parts, 1, tostring(room.state.start))
  end
  return table.concat(parts, "  >  ")
end

--- @param room Room
--- @param n number?
--- @param duel DeathrollDuel
--- @return number[]
local function colorOf(room, n, duel)
  local Widgets = private.Widgets
  if duel.winner then
    return duel.winner == n and Widgets.GREEN or Widgets.GREY
  end
  return turnOf(duel) == n and Widgets.GOLD or { 1, 1, 1 }
end

--- @param room Room
function DeathrollView:Update(room)
  local Widgets = private.Widgets
  self.room = room
  local state = room.state
  local playing, host = state.phase == "play", room:IsHost()
  local status, urgent = statusOf(room)

  -- Over the duel: which round, or how the player stands when there is no room for more
  local title = L["game_deathroll"]
  if playing then
    local final = #state.duels == 1 and state.duels[1].b ~= nil
    title = final and L["deathroll_final"] or L["deathroll_round"]:format(state.round)
  end
  self.title:SetText(self.compact and status or title)
  self.title:SetTextColor(unpack(self.compact and urgent and Widgets.GREEN or Widgets.GOLD))
  self.left:SetText(playing and not self.compact and L["deathroll_left"]:format(Deathroll.Left(room)) or "")

  local duel = state.round > 0 and featured(room) or nil
  local idle = not playing
  for _, region in ipairs({ self.nameA, self.nameB, self.versus, self.history }) do
    region:SetShown(not idle and duel ~= nil)
  end

  if idle then
    -- Who won, or what is about to happen
    local notice = L["game_deathroll"]
    if state.champion then
      notice = L["deathroll_champion"]:format(nameOf(room, state.champion))
    elseif state.stopped then
      notice = L["deathroll_stopped"]
    end
    self.number:SetText(notice)
    self.number:SetTextColor(unpack(state.champion == room.me and Widgets.GREEN or Widgets.GOLD))
    local detail = L["deathroll_rules_line"]:format(state.start, state.seconds)
    if not host then
      detail = status
    elseif room.count < 2 then
      detail = L["deathroll_alone"]
    end
    self.detail:SetText(detail)
  elseif duel then
    local mineNow = turnOf(duel) == room.me
    self.nameA:SetText(nameOf(room, duel.a))
    self.nameA:SetTextColor(unpack(colorOf(room, duel.a, duel)))
    self.nameB:SetText(duel.b and nameOf(room, duel.b) or "")
    self.nameB:SetTextColor(unpack(colorOf(room, duel.b, duel)))
    self.versus:SetShown(duel.b ~= nil)
    self.history:SetText(#duel.rolls > 0 and historyOf(room, duel) or "")
    local last = duel.rolls[#duel.rolls]
    self.number:SetText(last and last.value or duel.max)
    self.number:SetTextColor(unpack(last and last.value == 1 and Widgets.RED or (mineNow and Widgets.GREEN or { 1, 1, 1 })))
    local detail
    if duel.winner and not duel.b then
      detail = L["deathroll_bye_line"]:format(nameOf(room, duel.a))
    elseif duel.winner then
      local loser = otherOf(duel, duel.winner)
      detail = L[duel.forfeit and "deathroll_forfeit_line" or "deathroll_lost_line"]:format(nameOf(room, loser))
    elseif last then
      detail = L["deathroll_rolled"]:format(nameOf(room, last.n), last.value, last.max)
    else
      detail = L["deathroll_first"]:format(nameOf(room, duel.a), duel.max)
    end
    self.detail:SetText(detail)

    -- The other side rolled: heard, the way the player's own roll is
    local heard = self.heard
    local theirs = last ~= nil and last.n ~= room.me and Deathroll.MyDuel(room) == duel
    if theirs and heard and heard.duel == duel and #duel.rolls > heard.count then
      Widgets.PlaySound("dieThrow")
    end
    self.heard = { duel = duel, count = #duel.rolls }
  else
    self.number:SetText("")
    self.detail:SetText(status)
  end

  local mine = Deathroll.MyRoll(room)
  local myDuel = Deathroll.MyDuel(room)
  self.roll:SetShown(playing and myDuel ~= nil and myDuel == duel and not duel.winner)
  self.roll:SetEnabled(mine)
  self.roll:SetText(mine and L["deathroll_roll"]:format(myDuel.max) or L["deathroll_wait"])
  local left = mine and Deathroll.TimeLeft(room, myDuel)
  self.auto:SetShown(left ~= nil and left ~= false)
  if left then
    self.auto:SetText(L["deathroll_auto"]:format(math.ceil(left)))
  end
  self.start:SetShown(idle and host)
  self.start:SetEnabled(room.count >= 2)
  self.start:SetText(L[state.round > 0 and "deathroll_again" or "deathroll_start"])
  self.stop:SetShown(host and playing and not self.compact)

  if not self.compact then
    self.listTitle:SetText(playing and L["deathroll_duels"] or L["deathroll_last_round"])
    self.list:Update(state.round > 0 and state.duels or {}, function(row, entry)
      row.a:SetText(nameOf(room, entry.a))
      row.a:SetTextColor(unpack(colorOf(room, entry.a, entry)))
      row.b:SetText(entry.b and nameOf(room, entry.b) or "")
      row.b:SetTextColor(unpack(colorOf(room, entry.b, entry)))
      local middle
      if not entry.b then
        middle = "|cffa6a6a6" .. L["deathroll_bye"] .. "|r"
      elseif entry.winner then
        local last = entry.rolls[#entry.rolls]
        middle = "|cffa6a6a6" .. (entry.forfeit and L["deathroll_forfeit"] or (last and last.value or "")) .. "|r"
      else
        middle = (entry.k % 2 == 0 and "< " or "") .. entry.max .. (entry.k % 2 == 1 and " >" or "")
      end
      row.middle:SetText(middle)
    end)
    self.roster:Update(room)
  end
end
