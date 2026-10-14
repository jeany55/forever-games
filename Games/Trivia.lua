--------------------------
--  Trivia
--------------------------
-- A quiz for a room (Engine/Rooms.lua), the way Kahoot plays one: the host puts a question to
-- everyone at once, with two to four answers to pick from, and whoever picks the right one gets
-- more for it the sooner they do. Short enough to play between two pulls, and it stops for a
-- fight: whenever the host goes into combat the question that was up counts for nothing, and the
-- next one comes once the fight is over.
--
--   Q:k:total:seconds:ago:part:parts:text
--                                from the host: question k of the game's `total`, with this many
--                                seconds to answer it. The text is the question and its answers
--                                in the order they are shown, with a "|" between them, and takes
--                                as many messages as it needs: this is message `part` of `parts`.
--                                `ago` is how many seconds since it was asked: 0, unless it is
--                                told to somebody who just came in. With question 1, asked just
--                                now, a new game begins and everyone has nothing
--   A:k:choice:ms:streak         from a player: their answer to question k, how many thousandths
--                                of a second they took over it, and how many they had right in
--                                a row before it
--   PK:k:answers                 from the host to somebody who came in late: the answers given
--                                so far, "n/choice/ms/streak" each with a "." between them
--   REV:k:right                  from the host: time is up, this answer was the right one
--   HOLD:next:total              from the host: the questions stop for now, the next is `next`.
--                                A question that was up when they stopped counts for nothing
--   END:total                    from the host: that was the last question
--   STOP                         from the host: the game is called off
--
-- The host is the only one who knows the right answer before it is said, and asks the questions
-- from its own copy of them (Lexicon/Trivia.lua): players on another version of the addon play
-- just the same. Nobody checks how long anybody says they took, which between friends is what a
-- game here does.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Rooms = private.Rooms

--- @class Trivia
local Trivia = {}
private.Trivia = Trivia

-- Which questions are asked: the general ones, the Warcraft ones, or both together
Trivia.PACKS = { "m", "w", "g" }
Trivia.COUNTS = { 5, 10, 15 }
Trivia.PACES = { 10, 15, 20 }
local USUAL_PACK, USUAL_COUNT, USUAL_PACE = "m", 10, 15
-- Seconds to read a question before it can be answered, that the host gives an answer on its way
-- on top of the time for it, the right answer is shown for, and the host waits after a fight
-- before asking again
local READ, GRACE, REVEAL, AFTER_FIGHT = 3, 1.5, 6, 5
-- What a right answer is worth: the most at once, the least on the last moment, and on top of
-- that so much for every right answer in a row before it, up to a point
Trivia.MOST, Trivia.LEAST = 1000, 500
Trivia.STREAK, Trivia.STREAK_MOST = 100, 500
-- How much of a question's text goes in one message
local CHUNK = 180
local MOST_ANSWERS = 4

--- Which questions the host asked and when, so that the same ones don't come up night after
--- night. Kept between sessions by Core.lua: `serial` counts the questions ever asked, `ids` says
--- for a question (Rooms.Hash of its text) the count it was asked at
--- @type { serial: number, ids: table<number, number> }
Trivia.asked = { serial = 0, ids = {} }

--- What a right answer is worth
--- @param ms number Thousandths of a second it took
--- @param seconds number There were to answer it
--- @param streak number Right answers in a row before it
--- @return number
function Trivia.Points(ms, seconds, streak)
  local share = math.min(1, math.max(0, ms / (seconds * 1000)))
  local points = math.floor(Trivia.MOST - (Trivia.MOST - Trivia.LEAST) * share + 0.5)
  return points + math.min(Trivia.STREAK_MOST, Trivia.STREAK * streak)
end

--- @param text string?
--- @return string What can be shown and sent of it
local function tidy(text)
  text = (text or ""):gsub("[%c:|]", ""):gsub("^%s+", ""):gsub("%s+$", "")
  return text
end

--- @param value string?
--- @param least number
--- @param most number
--- @return number? nil unless it is a whole number from least to most
local function whole(value, least, most)
  local number = tonumber(value)
  if not number or number ~= math.floor(number) or number < least or number > most then
    return nil
  end
  return number
end

-----------------------------
-- Asking
-----------------------------

--- On the host: every question of a pack, the ones asked longest ago first and in no particular
--- order among themselves
--- @param room Room
--- @param pack string
--- @return { entry: string[], id: number, last: number, key: number }[]
local function deckOf(room, pack)
  local bank = private.TriviaQuestions or {}
  local asked = Trivia.asked.ids
  local deck = {}
  for _, id in ipairs(pack == "m" and { "g", "w" } or { pack }) do
    for _, entry in ipairs(bank[id] or {}) do
      local hash = Rooms.Hash(entry[1])
      deck[#deck + 1] = { entry = entry, id = hash, last = asked[hash] or 0, key = room:Random(1000000) }
    end
  end
  table.sort(deck, function(a, b)
    if a.last ~= b.last then
      return a.last < b.last
    end
    return a.key < b.key
  end)
  return deck
end

--- On the host: says the question that is up, to everyone or to somebody who just came in
--- @param room Room
--- @param member RoomMember?
--- @param ago number
local function sendQuestion(room, member, ago)
  local state = room.state
  local text = state.text
  local parts = math.max(1, math.ceil(#text / CHUNK))
  for part = 1, parts do
    local chunk = text:sub((part - 1) * CHUNK + 1, part * CHUNK)
    if member then
      room:Tell(member, "Q", state.k, state.total, state.seconds, ago, part, parts, chunk)
    else
      room:Say("Q", state.k, state.total, state.seconds, ago, part, parts, chunk)
    end
  end
end

--- On the host: puts the next question of the deck to everyone, as question k
--- @param room Room
--- @param k number
local function ask(room, k)
  local state = room.state
  local item = state.deck[state.pointer]
  if not item then
    room:Say("END", state.total)
    return
  end
  state.pointer = state.pointer + 1
  local memory = Trivia.asked
  memory.serial = memory.serial + 1
  memory.ids[item.id] = memory.serial

  local entry, answers = item.entry, {}
  for index = 2, math.min(#entry, MOST_ANSWERS + 1) do
    answers[#answers + 1] = tidy(entry[index])
  end
  local right = answers[1]
  if #answers == 2 then
    -- True before False, the way it is always put
    table.sort(answers, function(a, b)
      return a == "True" or (b ~= "True" and a < b)
    end)
  else
    room:Shuffle(answers)
  end
  for index, answer in ipairs(answers) do
    if answer == right then
      state.secret = index
    end
  end
  state.text = tidy(entry[1]) .. "|" .. table.concat(answers, "|")
  state.askedAt = room:Now()
  state.k = k
  sendQuestion(room, nil, 0)
end

-----------------------------
-- What the players do
-----------------------------

--- On the host: starts a game for everyone in the room
--- @param room Room
--- @param rules { pack: string?, count: number?, seconds: number? }?
--- @return boolean ok, string? error
function Trivia.Start(room, rules)
  local state = room.state
  if not room:IsHost() then
    return false, "not_host"
  elseif state.phase ~= "idle" and state.phase ~= "over" then
    return false, "trivia_playing"
  end
  state.pack = rules and rules.pack or state.pack
  state.count = rules and rules.count or state.count
  state.seconds = rules and rules.seconds or state.seconds
  state.deck, state.pointer = deckOf(room, state.pack), 1
  if #state.deck == 0 then
    return false, "trivia_empty"
  end
  state.total = math.min(state.count, #state.deck)
  state.fought = nil
  ask(room, 1)
  return true
end

--- On the host: calls the game off, the room stays
--- @param room Room
function Trivia.Stop(room)
  local phase = room.state.phase
  if room:IsHost() and phase ~= "idle" and phase ~= "over" then
    room:Say("STOP")
  end
end

--- On the host: stops the questions for now. A question that is up counts for nothing
--- @param room Room
--- @return boolean paused False if there is nothing to stop, or only the end to come
function Trivia.Pause(room)
  local state = room.state
  if not room:IsHost() then
    return false
  elseif state.phase == "ask" then
    room:Say("HOLD", state.k, state.total)
    return true
  elseif state.phase == "reveal" and state.k < state.total then
    room:Say("HOLD", state.k + 1, state.total)
    return true
  end
  return false
end

--- On the host: the questions go on
--- @param room Room
--- @param delay number? Seconds before the next is asked, none if left out
--- @return boolean
function Trivia.Resume(room, delay)
  local state = room.state
  if not room:IsHost() or state.phase ~= "held" then
    return false
  end
  state.fought = nil
  state.resumeAt = room:Now() + (delay or 0)
  return true
end

--- The local player answers the question that is up
--- @param room Room
--- @param choice number Which of its answers, as they are shown
--- @return boolean answered False if there is nothing to answer, or it was answered already
function Trivia.Answer(room, choice)
  local state = room.state
  local now = room:Now()
  if not Trivia.CanAnswer(room) or not state.answers[choice] then
    return false
  end
  local ms = math.min(state.seconds * 1000, math.floor((now - state.opensAt) * 1000))
  room:Say("A", state.k, choice, ms, state.streak)
  return true
end

--- Whether the local player can answer right now
--- @param room Room
--- @return boolean
function Trivia.CanAnswer(room)
  local state = room.state
  local now = room:Now()
  return state.phase == "ask" and not state.picks[room.me] and now >= state.opensAt and now < state.endsAt
end

--- @param room Room
--- @return number? Seconds left to answer, nil if there is no question up
function Trivia.TimeLeft(room)
  local state = room.state
  if state.phase ~= "ask" then
    return nil
  end
  return math.max(0, state.endsAt - room:Now())
end

--- @param room Room
--- @return number answered, number of How many in the room answered the question that is up
function Trivia.Answered(room)
  local answered = 0
  for _, member in pairs(room.members) do
    answered = answered + (room.state.picks[member.n] and 1 or 0)
  end
  return answered, room.count
end

--- Everyone in the room, whoever has the most first
--- @param room Room
--- @return RoomMember[]
function Trivia.Standings(room)
  local members = room:Members()
  table.sort(members, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.n < b.n
  end)
  return members
end

-----------------------------
-- What is said in the room
-----------------------------

--- @param room Room
--- @param n number
--- @param choice number?
--- @param ms number?
--- @param streak number?
local function pick(room, n, choice, ms, streak)
  local state = room.state
  if state.picks[n] or not choice or not state.answers[choice] or not ms then
    return
  end
  state.picks[n] = { choice = choice, ms = math.min(ms, state.seconds * 1000), streak = streak or 0 }
end

--- @param room Room
--- @param fields string[]
--- @param now number
local function takeQuestion(room, fields, now)
  local state = room.state
  local k, total = whole(fields[1], 1, 99), whole(fields[2], 1, 99)
  local seconds, ago = whole(fields[3], 1, 60), whole(fields[4], 0, 3600)
  local part, parts = whole(fields[5], 1, 9), whole(fields[6], 1, 9)
  if not (k and total and seconds and ago and part and parts and fields[7]) or part > parts then
    return
  end
  if part == 1 then
    state.incoming = { k = k, parts = {} }
  end
  local incoming = state.incoming
  if not incoming or incoming.k ~= k then
    return
  end
  incoming.parts[part] = fields[7]
  for index = 1, parts do
    if not incoming.parts[index] then
      return
    end
  end
  state.incoming = nil

  local pieces = {}
  for piece in (table.concat(incoming.parts) .. "|"):gmatch("([^|]*)|") do
    pieces[#pieces + 1] = tidy(piece)
  end
  local question = table.remove(pieces, 1)
  if not question or question == "" or #pieces < 2 or #pieces > MOST_ANSWERS then
    return
  end
  if k == 1 and ago == 0 then
    room:ClearScores()
    state.streak = 0
  end
  state.phase, state.k, state.total, state.seconds = "ask", k, total, seconds
  state.question, state.answers = question, pieces
  state.opensAt = now - ago + READ
  state.endsAt = state.opensAt + seconds
  state.picks, state.gained, state.counts, state.right = {}, {}, nil, nil
  state.stopped, state.resumeAt, state.nextAt = nil, nil, nil
end

--- @param room Room
--- @param right number
local function reveal(room, right)
  local state = room.state
  state.right, state.counts = right, {}
  for n, given in pairs(state.picks) do
    state.counts[given.choice] = (state.counts[given.choice] or 0) + 1
    if given.choice == right then
      local points = Trivia.Points(given.ms, state.seconds, given.streak)
      state.gained[n] = points
      local member = room.members[n]
      if member then
        member.score = member.score + points
      end
    end
  end
  local mine = state.picks[room.me]
  state.streak = (mine and mine.choice == right) and state.streak + 1 or 0
  state.phase = "reveal"
  if room:IsHost() then
    state.nextAt = room:Now() + REVEAL
  end
end

--- @param room Room
--- @param member RoomMember
--- @param kind string
--- @param fields string[]
local function receive(room, member, kind, fields)
  local state = room.state
  local fromHost = member.name == room.host
  local now = room:Now()
  local asking = state.phase == "ask"

  if kind == "Q" and fromHost then
    takeQuestion(room, fields, now)
  elseif kind == "A" and asking and whole(fields[1], 1, 99) == state.k then
    pick(room, member.n, whole(fields[2], 1, MOST_ANSWERS), whole(fields[3], 0, 3600000), whole(fields[4], 0, 99))
  elseif kind == "PK" and fromHost and asking and whole(fields[1], 1, 99) == state.k then
    for n, choice, ms, streak in (fields[2] or ""):gmatch("(%d+)/(%d+)/(%d+)/(%d+)") do
      pick(room, tonumber(n), tonumber(choice), tonumber(ms), tonumber(streak))
    end
  elseif kind == "REV" and fromHost and asking and whole(fields[1], 1, 99) == state.k then
    local right = whole(fields[2], 1, #state.answers)
    if right then
      reveal(room, right)
    end
  elseif kind == "HOLD" and fromHost and state.phase ~= "idle" then
    local next, total = whole(fields[1], 1, 99), whole(fields[2], 1, 99)
    if not (next and total) then
      return
    end
    state.phase, state.next, state.total = "held", next, total
    state.incoming, state.nextAt = nil, nil
  elseif kind == "END" and fromHost and state.phase ~= "idle" then
    state.phase, state.total = "over", whole(fields[1], 1, 99) or state.total
    state.incoming, state.nextAt, state.resumeAt = nil, nil, nil
  elseif kind == "STOP" and fromHost then
    state.phase, state.stopped = "idle", true
    state.incoming, state.nextAt, state.resumeAt, state.fought = nil, nil, nil, nil
  else
    return
  end
  state.rev = state.rev + 1
end

--- @param room Room
--- @return boolean Whether everyone in the room has answered the question that is up
local function allAnswered(room)
  local answered, of = Trivia.Answered(room)
  return answered >= of
end

--- @param room Room
--- @param now number
local function tick(room, now)
  local state = room.state
  if not room:IsHost() then
    return
  end
  if state.phase == "ask" then
    -- There is no use waiting once everyone answered
    if now >= state.endsAt + GRACE or (now >= state.opensAt and allAnswered(room)) then
      room:Say("REV", state.k, state.secret)
    end
  elseif state.phase == "reveal" and state.nextAt and now >= state.nextAt then
    state.nextAt = nil
    if state.k >= state.total then
      room:Say("END", state.total)
    else
      ask(room, state.k + 1)
    end
  elseif state.phase == "held" and state.resumeAt and now >= state.resumeAt then
    state.resumeAt = nil
    ask(room, state.next)
  end
end

--- On the host: a fight stops the questions, and they go on a little while after it
--- @param room Room
--- @param fighting boolean
local function fight(room, fighting)
  local state = room.state
  if not room:IsHost() then
    return
  end
  if fighting then
    if Trivia.Pause(room) then
      state.fought = true
    elseif state.phase == "held" and state.resumeAt then
      -- Another pull before the questions went on
      state.resumeAt, state.fought = nil, true
    end
  elseif state.fought and state.phase == "held" then
    Trivia.Resume(room, AFTER_FIGHT)
  end
end

--- On the host: tells somebody who came in late where the game is
--- @param room Room
--- @param member RoomMember
local function welcome(room, member)
  local state = room.state
  if state.phase == "ask" or state.phase == "reveal" then
    sendQuestion(room, member, math.floor(room:Now() - state.askedAt))
    if state.phase == "reveal" then
      room:Tell(member, "REV", state.k, state.right)
      return
    end
    local entries = {}
    for n, given in pairs(state.picks) do
      entries[#entries + 1] = table.concat({ n, given.choice, given.ms, given.streak }, "/")
    end
    room:TellList(member, "PK", entries, state.k)
  elseif state.phase == "held" then
    room:Tell(member, "HOLD", state.next, state.total)
  elseif state.phase == "over" then
    room:Tell(member, "END", state.total)
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
  if state.phase == "idle" then
    if room:IsHost() then
      return L["trivia_idle_host"], false
    end
    return L["trivia_idle"]:format(private.Transport.DisplayName(room.host)), false
  elseif state.phase == "ask" then
    if state.picks[room.me] then
      return L["trivia_answered"], false
    end
    return L["trivia_question"]:format(state.k, state.total), Trivia.CanAnswer(room)
  elseif state.phase == "reveal" then
    local gained = state.gained[room.me]
    if gained then
      return L["trivia_right"]:format(gained), false
    end
    return L[state.picks[room.me] and "trivia_wrong" or "trivia_missed"], false
  elseif state.phase == "held" then
    return L["trivia_paused"], false
  end
  local first = Trivia.Standings(room)[1]
  return L["trivia_winner"]:format(nameOf(room, first and first.n)), false
end

Rooms.Register({
  id = "trivia",
  name = L["game_trivia"],
  description = L["game_trivia_description"],
  icon = "Interface\\Icons\\INV_Misc_QuestionMark",
  version = 1,
  options = {
    {
      id = "pack",
      name = L["trivia_option_pack"],
      description = L["trivia_option_pack_tip"],
      choices = Trivia.PACKS,
      default = USUAL_PACK,
      label = function(value)
        return L["trivia_pack_" .. value]
      end,
    },
    {
      id = "count",
      name = L["trivia_option_count"],
      description = L["trivia_option_count_tip"],
      choices = Trivia.COUNTS,
      default = USUAL_COUNT,
    },
    {
      id = "seconds",
      name = L["trivia_option_pace"],
      description = L["trivia_option_pace_tip"],
      choices = Trivia.PACES,
      default = USUAL_PACE,
      label = function(value)
        return L["trivia_seconds"]:format(value)
      end,
    },
  },
  -- Its small window keeps out of the way of a fight
  calm = true,
  new = function(_, rules)
    return {
      phase = "idle",
      pack = rules and rules.pack or USUAL_PACK,
      count = rules and rules.count or USUAL_COUNT,
      seconds = rules and rules.seconds or USUAL_PACE,
      k = 0,
      total = 0,
      streak = 0,
      answers = {},
      picks = {},
      gained = {},
      rev = 0,
    }
  end,
  receive = receive,
  tick = tick,
  fight = fight,
  welcome = welcome,
  status = statusOf,
  mark = function(room, member)
    local state = room.state
    if state.phase == "ask" then
      return state.picks[member.n] and "green" or nil
    elseif state.phase == "reveal" then
      local gained = state.gained[member.n]
      return gained and "green" or nil, gained and ("+" .. gained) or nil
    elseif state.phase == "over" then
      local first = Trivia.Standings(room)[1]
      return first and first.n == member.n and "gold" or nil
    end
    return nil
  end,
  view = function(parent)
    return private.TriviaView.New(parent)
  end,
})

-----------------------------
-- View
-----------------------------
-- The question across the top with the time it has left under it, and under that its answers,
-- two by two, each with a raid marker of its own colour. Down the right who is playing and what
-- they have. Once the time is up the right answer lights up, with how many picked each. Before a
-- game and after it the top three. Made small it is the question and the answers, and nothing
-- else.

--- @class TriviaView
--- @field frame Frame
local TriviaView = {}
TriviaView.__index = TriviaView
private.TriviaView = TriviaView

-- The line over the question, the line under the answers, the host's buttons, the clock's bar
-- and the space between things
local TITLE, FOOT, BUTTON_ROW, BAR, GAP = 26, 24, 26, 6, 8
local SMALL_TITLE, SMALL_FOOT, SMALL_QUESTION = 20, 18, 92
local COLUMN_LEAST, COLUMN_MOST = 200, 260
local ICON, SMALL_ICON = 28, 18
-- The sizes of what is written large: the question, an answer and the clock, whole and small
local QUESTION_SIZE, ANSWER_SIZE, CLOCK_SIZE = 20, 15, 22
local SMALL_QUESTION_SIZE, SMALL_ANSWER_SIZE, SMALL_CLOCK_SIZE = 13, 11, 14
-- The raid markers the answers go by, star, circle, diamond and triangle, in their colours
local MARKERS = {
  { icon = 1, color = { 0.95, 0.8, 0.1 } },
  { icon = 2, color = { 0.95, 0.5, 0.1 } },
  { icon = 3, color = { 0.7, 0.3, 0.9 } },
  { icon = 4, color = { 0.25, 0.75, 0.25 } },
}
local MARKER_PATH = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_"

--- @param parent Frame
--- @return TriviaView
function TriviaView.New(parent)
  local Widgets = private.Widgets
  local self = setmetatable({}, TriviaView)
  local frame = CreateFrame("Frame", nil, parent)
  self.frame = frame

  self.title = Widgets.Label(frame, "GameFontNormalLarge")
  self.title:SetWordWrap(false)
  self.clock = Widgets.Label(frame, "GameFontHighlightLarge")
  self.clock:SetJustifyH("RIGHT")

  -- The question, and the time it has left along the bottom of it
  local card = Widgets.Panel(frame)
  self.card = card
  self.question = Widgets.Label(card, "GameFontHighlightLarge")
  self.question:SetJustifyH("CENTER")
  self.question:SetJustifyV("MIDDLE")
  self.question:SetPoint("TOPLEFT", 14, -10)
  self.question:SetPoint("BOTTOMRIGHT", -14, BAR + 8)
  self.barBack = card:CreateTexture(nil, "ARTWORK")
  self.barBack:SetColorTexture(1, 1, 1, 0.08)
  self.barBack:SetPoint("BOTTOMLEFT", 1, 1)
  self.barBack:SetPoint("BOTTOMRIGHT", -1, 1)
  self.barBack:SetHeight(BAR)
  self.bar = card:CreateTexture(nil, "OVERLAY")
  self.bar:SetPoint("BOTTOMLEFT", 1, 1)
  self.bar:SetHeight(BAR)

  self.answers = {}
  for index, marker in ipairs(MARKERS) do
    local button = Widgets.Panel(frame, "Button")
    button.index = index
    local hover = button:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetColorTexture(1, 1, 1, 0.08)
    button.icon = Widgets.Icon(button, MARKER_PATH .. marker.icon, ICON)
    button.count = Widgets.Label(button, "GameFontNormalLarge")
    button.count:SetJustifyH("RIGHT")
    button.label = Widgets.Label(button, "GameFontHighlight")
    button.label:SetJustifyV("MIDDLE")
    button:SetScript("OnClick", function()
      self:Answer(index)
    end)
    self.answers[index] = button
  end

  self.detail = Widgets.Label(frame, "GameFontHighlight")
  self.detail:SetJustifyH("CENTER")
  self.detail:SetWordWrap(false)

  self.start = Widgets.Button(frame, L["trivia_start"], 200, 34)
  self.start:SetNormalFontObject("GameFontNormalLarge")
  self.start:SetHighlightFontObject("GameFontHighlightLarge")
  self.start:SetScript("OnClick", function()
    local ok, err = Trivia.Start(self.room)
    if not ok and err then
      ForeverGames:Print(L["err_" .. err])
    end
  end)
  self.pause = Widgets.Button(frame, L["trivia_pause"], 110, 22)
  self.pause:SetScript("OnClick", function()
    if self.room.state.phase == "held" then
      Trivia.Resume(self.room)
    else
      Trivia.Pause(self.room)
    end
  end)
  self.stop = Widgets.Button(frame, L["trivia_stop"], 110, 22)
  self.stop:SetScript("OnClick", function()
    Trivia.Stop(self.room)
  end)

  -- 1 to 4 answer, while the cursor is over the game
  Widgets.Keys(frame, function(key)
    local index = tonumber(key)
    return index ~= nil and self:Answer(index)
  end)

  self.roster = private.Party.Roster(frame)
  return self
end

--- @param index number
--- @return boolean
function TriviaView:Answer(index)
  if self.room and Trivia.Answer(self.room, index) then
    private.Widgets.PlaySound("IG_MAINMENU_OPTION_CHECKBOX_ON")
    self:Update(self.room)
    return true
  end
  return false
end

--- @param width number
--- @param height number
--- @param compact boolean? There is only room for the question and its answers
function TriviaView:Layout(width, height, compact)
  local Widgets = private.Widgets
  self.compact = compact
  self.frame:SetSize(width, height)
  for _, region in ipairs({ self.title, self.clock, self.card, self.detail, self.start, self.pause, self.stop }) do
    region:ClearAllPoints()
  end
  self.roster.frame:SetShown(not compact)

  local main = width
  if not compact then
    local column = math.max(COLUMN_LEAST, math.min(COLUMN_MOST, math.floor(width * 0.28)))
    main = width - column - GAP
    self.roster:Layout(column, height)
    self.roster.frame:ClearAllPoints()
    self.roster.frame:SetPoint("TOPRIGHT")
  end

  local title = compact and SMALL_TITLE or TITLE
  local foot = compact and SMALL_FOOT or FOOT
  local buttons = compact and 0 or BUTTON_ROW
  self.title:SetPoint("TOPLEFT", 2, -4)
  self.title:SetWidth(main - 64)
  self.title:SetFontObject(compact and "GameFontNormal" or "GameFontNormalLarge")
  self.clock:SetPoint("TOPRIGHT", self.frame, "TOPLEFT", main - 2, -3)
  self.clock:SetFont(STANDARD_TEXT_FONT, compact and SMALL_CLOCK_SIZE or CLOCK_SIZE, "")

  local cardHeight = compact and SMALL_QUESTION or math.floor((height - title - foot - buttons) * 0.36)
  self.card:SetPoint("TOPLEFT", 0, -title)
  self.card:SetSize(main, cardHeight)
  -- Set again by the next Update, in whichever font what it shows is in
  self.questionFont = nil
  self.barWidth = main - 2

  -- What is left between the question and the line under it is for the answers
  self.area = { top = title + cardHeight + GAP, width = main, height = height - title - cardHeight - GAP * 2 - foot - buttons }
  self.arranged = nil
  for _, button in ipairs(self.answers) do
    button.icon:SetSize(compact and SMALL_ICON or ICON, compact and SMALL_ICON or ICON)
    button.icon:ClearAllPoints()
    button.icon:SetPoint("LEFT", compact and 6 or 10, 0)
    button.count:ClearAllPoints()
    button.count:SetPoint("RIGHT", compact and -6 or -12, 0)
    button.count:SetFont(STANDARD_TEXT_FONT, compact and SMALL_ANSWER_SIZE + 2 or ANSWER_SIZE + 3, "")
    button.label:ClearAllPoints()
    local inset = compact and (6 + SMALL_ICON + 5) or (10 + ICON + 10)
    button.label:SetPoint("TOPLEFT", inset, -4)
    button.label:SetPoint("BOTTOMRIGHT", compact and -24 or -40, 4)
    button.label:SetFont(STANDARD_TEXT_FONT, compact and SMALL_ANSWER_SIZE or ANSWER_SIZE, "")
  end

  self.detail:SetPoint("TOPLEFT", 0, -(height - foot - buttons))
  self.detail:SetSize(main, foot)
  self.start:SetPoint("CENTER", self.frame, "TOPLEFT", main / 2, -(self.area.top + self.area.height / 2))
  self.start:SetSize(compact and 160 or 200, compact and 28 or 34)
  self.stop:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMLEFT", main, 0)
  self.pause:SetPoint("RIGHT", self.stop, "LEFT", -6, 0)
end

--- Puts the answers where they go: two by two, or side by side when there are only two
--- @param count number
function TriviaView:Arrange(count)
  if self.arranged == count then
    return
  end
  self.arranged = count
  local area = self.area
  local rows = count > 2 and 2 or 1
  local cellWidth = math.floor((area.width - GAP) / 2)
  local cellHeight = math.floor((area.height - GAP * (rows - 1)) / rows)
  for index, button in ipairs(self.answers) do
    button:ClearAllPoints()
    button:SetShown(index <= count)
    local column, row = (index - 1) % 2, math.floor((index - 1) / 2)
    button:SetPoint("TOPLEFT", column * (cellWidth + GAP), -(area.top + row * (cellHeight + GAP)))
    button:SetSize(cellWidth, cellHeight)
  end
end

--- @param room Room
--- @return string
local function podium(room)
  local lines = {}
  for place, member in ipairs(Trivia.Standings(room)) do
    if place > 3 then
      break
    end
    local color = place == 1 and "ffd100" or "ffffff"
    lines[#lines + 1] = ("|cff%s%s|r  %s|cffa6a6a6  %d|r"):format(color, L["trivia_place_" .. place], nameOf(room, member.n), member.score)
  end
  return table.concat(lines, "\n")
end

--- @param room Room
function TriviaView:Update(room)
  local Widgets = private.Widgets
  self.room = room
  local state = room.state
  local host, phase = room:IsHost(), state.phase
  local now = room:Now()
  local playing = phase == "ask" or phase == "reveal"
  local status, urgent = statusOf(room)

  -- Over the question: which it is, or how the player stands when there is no room for more
  local title = L["game_trivia"]
  if playing or phase == "held" then
    title = L["trivia_question"]:format(phase == "held" and state.next or state.k, state.total)
  end
  self.title:SetText(self.compact and status or title)
  self.title:SetTextColor(unpack(self.compact and urgent and Widgets.GREEN or Widgets.GOLD))

  -- The clock, and the bar under the question that runs down with it. Grey while it is read
  local left = Trivia.TimeLeft(room)
  local reading = phase == "ask" and now < state.opensAt
  self.clock:SetText(left and not reading and math.ceil(left) or "")
  self.clock:SetTextColor(unpack(left and left <= 3 and Widgets.RED or { 1, 1, 1 }))
  local share = 0
  if reading then
    share = 1 - (state.opensAt - now) / READ
  elseif left then
    share = left / state.seconds
  end
  share = math.max(0, math.min(1, share))
  self.bar:SetShown(share > 0)
  self.bar:SetWidth(math.max(1, self.barWidth * share))
  if reading then
    self.bar:SetColorTexture(0.6, 0.6, 0.6, 0.6)
  else
    local color = left and left <= 3 and Widgets.RED or Widgets.GOLD
    self.bar:SetColorTexture(color[1], color[2], color[3], 0.85)
  end

  -- The question as large as the answers. Whatever stands in for it has names in it, in the
  -- client's font as it comes, which writes every name there is
  local font = playing and "sized" or "client"
  if self.questionFont ~= font then
    self.questionFont = font
    if playing then
      self.question:SetFont(STANDARD_TEXT_FONT, self.compact and SMALL_QUESTION_SIZE or QUESTION_SIZE, "")
    else
      self.question:SetFontObject(self.compact and "GameFontHighlight" or "GameFontHighlightLarge")
    end
  end
  if playing then
    self.question:SetText(state.question)
  elseif phase == "held" then
    self.question:SetText(L["trivia_paused_line"])
  elseif phase == "over" then
    self.question:SetText(podium(room))
  elseif state.stopped then
    self.question:SetText(L["trivia_stopped"])
  elseif host then
    -- Only the host knows how the room was set up
    self.question:SetText(L["trivia_rules_line"]:format(L["trivia_pack_" .. state.pack], state.count, state.seconds))
  else
    self.question:SetText(L["game_trivia_description"])
  end

  -- The answers
  self:Arrange(playing and #state.answers or 0)
  local mine = state.picks[room.me]
  for index, button in ipairs(self.answers) do
    local text = state.answers[index]
    if playing and text then
      local marker = MARKERS[index]
      local revealed = phase == "reveal"
      local right = revealed and state.right == index
      local chosen = mine and mine.choice == index
      button.label:SetText(text)
      button:SetEnabled(Trivia.CanAnswer(room))
      local r, g, b = marker.color[1], marker.color[2], marker.color[3]
      local strength = (reading and 0.15) or (revealed and not right and 0.08) or 0.32
      button:SetBackdropColor(r * 0.6, g * 0.6, b * 0.6, strength + (chosen and 0.2 or 0))
      if right then
        button:SetBackdropBorderColor(0.3, 1, 0.3, 1)
      elseif chosen then
        button:SetBackdropBorderColor(1, 1, 1, 0.9)
      else
        button:SetBackdropBorderColor(r, g, b, 0.35)
      end
      button:SetAlpha((revealed and not right and not chosen) and 0.5 or ((mine and not chosen and not revealed) and 0.55 or 1))
      button.count:SetText(revealed and (state.counts[index] or 0) or "")
    end
  end

  -- Under the answers how the player stands
  local detail = ""
  if phase == "ask" then
    local answered, of = Trivia.Answered(room)
    detail = reading and L["trivia_get_ready"] or L["trivia_answered_count"]:format(answered, of)
  elseif phase == "reveal" then
    local gained = state.gained[room.me]
    if gained then
      detail = L[state.streak > 1 and "trivia_right_streak" or "trivia_right"]:format(gained, state.streak)
    else
      detail = L["trivia_right_answer"]:format(state.answers[state.right] or "?")
    end
  elseif phase == "held" then
    detail = L[host and (state.resumeAt and "trivia_resuming" or "trivia_paused_host") or "trivia_paused"]
  elseif phase == "idle" and not host then
    detail = status
  elseif phase == "over" and not host then
    detail = L["trivia_over"]
  end
  self.detail:SetText(detail)
  self.detail:SetTextColor(unpack(phase == "reveal" and (state.gained[room.me] and Widgets.GREEN or Widgets.RED) or { 1, 1, 1 }))

  self.start:SetShown(host and (phase == "idle" or phase == "over"))
  self.start:SetText(L[phase == "over" and "trivia_again" or "trivia_start"])
  local running = phase ~= "idle" and phase ~= "over"
  self.pause:SetShown(host and running and not self.compact)
  self.pause:SetText(L[phase == "held" and "trivia_resume" or "trivia_pause"])
  self.pause:SetEnabled(phase == "held" or phase == "ask" or (phase == "reveal" and state.k < state.total))
  self.stop:SetShown(host and running and not self.compact)

  -- Heard as well as seen: a new question, and how the player did
  local heard = self.heard
  local moment = phase .. state.k
  if heard and heard.room == room and heard.moment ~= moment then
    if phase == "ask" then
      Widgets.PlaySound("IG_QUEST_LIST_OPEN")
    elseif phase == "reveal" and state.gained[room.me] then
      Widgets.PlaySound("LOOT_WINDOW_COIN_SOUND")
    elseif phase == "over" then
      Widgets.PlaySound("READY_CHECK")
    end
  end
  self.heard = { room = room, moment = moment }

  if not self.compact then
    self.roster:Update(room)
  end
end
