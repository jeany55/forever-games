--------------------------
--  Where in Azeroth: the view
--------------------------
-- The place fills the window, looked round in (GUI/PanoView.lua), with the round, the score and
-- the time left in a corner and a compass along the top. The map to guess on sits small in the
-- bottom right corner and grows while the cursor is over it (GUI/MapView.lua), or for good while
-- it is kept open: a click pins where the player thinks they are, Guess (or Space) says so.
-- Arrows look round too.
--
-- A guess is shown on the whole map: the pin, where the place really was, the line between, how
-- far out it was and the points counting up, and in a race what the rival guessed (their ghost,
-- Engine/Race.lua). Then on to the next place, and after the last all of them at once, with the
-- score against the player's best and the rival's.
--
-- What the player pinned and how long is left aren't the game's, they are the view's own: a
-- game picked up again later starts the place it is at afresh. A timed place that runs out puts
-- in whatever is pinned, or no guess.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L

--- @class WhereView
local WhereView = {}
private.WhereView = WhereView

local View = {}
View.__index = View

local floor, min, max = math.floor, math.min, math.max
local FOLDER = "Interface\\AddOns\\ForeverGames_Places\\Images\\"
-- The map to guess on: its size in the corner as a part of the window across, and while the
-- cursor is over it, how much of its width its height is, and the room for the button under it
local SMALL, LARGE, SHAPE, BUTTON = 0.3, 0.58, 0.66, 30
-- How quickly the map grows and shrinks (part of the way left a second), and how long it waits
-- once the cursor has left before shrinking
local GROW_LEFT, SHRINK_AFTER = 0.0002, 0.7
local PAD = 10
local BAR = 92
local MINE, ANSWER, RIVAL = { 0.3, 0.65, 1 }, { 1, 0.82, 0 }, { 1, 0.42, 0.3 }
local LINE, RIVAL_LINE = { 1, 1, 1 }, { 1, 0.55, 0.45 }
-- How long the points take to count up, and a score that is worth cheering
local COUNT, CHEER = 1.1, 0.8
-- The map to start on if the world's has no art in this client
local EASTERN_KINGDOMS = 1415

local Where, Places, Widgets

local function call(f, ...)
  if type(f) ~= "function" then
    return nil
  end
  local ok, a, b = pcall(f, ...)
  if ok then
    return a, b
  end
  return nil
end

--- The client's name for the zone a place is in
local function zoneName(place)
  local info = place and call(C_Map.GetMapInfo, place.mapID)
  return info and info.name or (place and place.zone) or ""
end

--- @param place table A place of the catalogue
--- @return Panorama
local function panorama(place)
  local pano = place.pano
  return { folder = FOLDER, file = place.id, tiles = pano.tiles, top = pano.top, bottom = pano.bottom, facing = pano.facing,
    sky = pano.sky, ground = pano.ground }
end

--- The map a guess starts on: the world's, where the client has it
local function startMap()
  local world = call(C_Map.GetFallbackWorldMapID)
  local layers = world and call(C_Map.GetMapArtLayers, world)
  return layers and layers[1] and world or EASTERN_KINGDOMS
end

-----------------------------
-- Building
-----------------------------

--- @param stage Frame
--- @return table
function WhereView.New(stage)
  Where, Places, Widgets = private.Where, private.Places, private.Widgets
  local self = setmetatable({ stage = stage, width = 0, height = 0, mapGrow = 0, mapGoal = 0 }, View)

  self.pano = private.PanoView.New(stage, { compass = true })
  self.pano.frame:SetPoint("TOPLEFT")
  self.missing = self.pano.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  self.missing:SetPoint("CENTER")
  self.missing:SetWidth(420)
  self.missing:SetText(L["where_missing"])
  self.missing:Hide()

  -- The round, the score and the time left
  local hud = CreateFrame("Frame", nil, stage)
  hud:SetFrameLevel(self.pano.frame:GetFrameLevel() + 10)
  hud:SetPoint("TOPLEFT", PAD, -PAD)
  hud:SetSize(250, 40)
  self.hud = hud
  self.stats = {
    round = Widgets.Stat(hud, L["where_round"], 70),
    score = Widgets.Stat(hud, L["where_score"], 96),
    time = Widgets.Stat(hud, L["where_time"], 70),
  }
  self.stats.round:SetPoint("TOPLEFT")
  self.stats.score:SetPoint("LEFT", self.stats.round, "RIGHT", 6, 0)
  self.stats.time:SetPoint("LEFT", self.stats.score, "RIGHT", 6, 0)

  -- The map to guess on, in its corner
  local corner = Widgets.Panel(stage)
  corner:SetFrameLevel(self.pano.frame:GetFrameLevel() + 20)
  corner:SetPoint("BOTTOMRIGHT", -PAD, PAD)
  self.corner = corner
  self.small = private.MapView.New(corner, { trail = true, onClick = function(place)
    self:pinAt(place)
  end })
  self.small.frame:SetPoint("TOPLEFT", 4, -4)
  -- Kept open, the map stays big wherever the cursor goes: the player's to choose, and kept
  self.keepButton = Widgets.Button(corner, "", 96, 24)
  self.keepButton:SetPoint("BOTTOMLEFT", 4, 4)
  self.keepButton:SetScript("OnClick", function()
    ForeverGames.db.profile.whereKeepMap = not ForeverGames.db.profile.whereKeepMap or nil
    self:refreshKeep()
  end)
  self:refreshKeep()
  self.guessButton = Widgets.Button(corner, L["where_guess"], 120, 24)
  self.guessButton:SetPoint("BOTTOMLEFT", self.keepButton, "BOTTOMRIGHT", 4, 0)
  self.guessButton:SetPoint("BOTTOMRIGHT", -4, 4)
  self.guessButton:SetScript("OnClick", function()
    self:guess()
  end)

  -- A guess, and the game, shown on the whole map
  local reveal = CreateFrame("Frame", nil, stage)
  reveal:SetFrameLevel(self.pano.frame:GetFrameLevel() + 40)
  reveal:SetPoint("TOPLEFT")
  reveal:Hide()
  self.reveal = reveal
  local back = reveal:CreateTexture(nil, "BACKGROUND")
  back:SetAllPoints()
  back:SetColorTexture(0.05, 0.05, 0.06, 0.96)
  self.big = private.MapView.New(reveal)
  self.big.frame:SetPoint("TOPLEFT")
  self.big:Lock(true)
  local bar = CreateFrame("Frame", nil, reveal)
  bar:SetPoint("BOTTOMLEFT")
  bar:SetPoint("BOTTOMRIGHT")
  bar:SetHeight(BAR)
  self.bar = bar
  self.points = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
  self.points:SetPoint("TOP", 0, -10)
  self.distance = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  self.distance:SetPoint("TOP", self.points, "BOTTOM", 0, -4)
  local track = bar:CreateTexture(nil, "ARTWORK")
  track:SetColorTexture(1, 1, 1, 0.12)
  track:SetPoint("BOTTOM", 0, 16)
  track:SetSize(360, 8)
  self.track = track
  self.fill = bar:CreateTexture(nil, "OVERLAY")
  self.fill:SetColorTexture(ANSWER[1], ANSWER[2], ANSWER[3], 1)
  self.fill:SetPoint("LEFT", track, "LEFT")
  self.fill:SetSize(1, 8)
  self.nextButton = Widgets.Button(bar, L["where_next"], 150, 26)
  self.nextButton:SetPoint("RIGHT", -16, 0)
  self.nextButton:SetScript("OnClick", function()
    self:onward()
  end)
  -- The places of the game, beside the map once it is over
  self.list = reveal:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  self.list:SetPoint("TOPLEFT", 14, -14)
  self.list:SetJustifyH("LEFT")
  self.listBack = reveal:CreateTexture(nil, "ARTWORK")
  self.listBack:SetColorTexture(0, 0, 0, 0.6)
  self.listBack:SetPoint("TOPLEFT", self.list, -8, 8)
  self.listBack:SetPoint("BOTTOMRIGHT", self.list, 8, -8)

  -- The clock and the map's growing, and the counting up
  local clock = CreateFrame("Frame", nil, stage)
  clock:SetScript("OnUpdate", function(_, elapsed)
    self:tick(math.min(elapsed, 0.1))
  end)
  local ticker = CreateFrame("Frame", nil, stage)
  self.animator = Widgets.Animator(ticker)
  self.effects = private.Effects.New(stage)

  -- Keys, while the cursor is over the game
  local keys = CreateFrame("Frame", nil, stage)
  keys:SetAllPoints()
  self.keys = keys
  local ARROWS = { LEFT = "left", RIGHT = "right", UP = "up", DOWN = "down", A = "left", D = "right", W = "up", S = "down" }
  Widgets.Keys(keys, function(key)
    if self.reveal:IsShown() then
      if key == "SPACE" or key == "ENTER" then
        self:onward()
        return true
      end
      return false
    elseif ARROWS[key] then
      self.pano:Key(ARROWS[key], true)
      return true
    elseif key == "SPACE" or key == "ENTER" then
      self:guess()
      return true
    end
    return false
  end)
  keys:SetScript("OnKeyUp", function(_, key)
    if ARROWS[key] then
      self.pano:Key(ARROWS[key], false)
    end
  end)
  return self
end

-----------------------------
-- Layout
-----------------------------

--- How big the map in the corner is now, between its small size and its large one
function View:mapSize()
  local across = self.width * (SMALL + (LARGE - SMALL) * self.mapGrow)
  local down = min(across * SHAPE, self.height - 2 * PAD - 60)
  return across, down + BUTTON + 8
end

function View:layoutMap()
  local width, height = self:mapSize()
  self.corner:SetSize(width, height)
  self.small:SetSize(width - 8, height - BUTTON - 12)
end

--- @param width number
--- @param height number
function View:Layout(width, height)
  self.width, self.height = width, height
  self.pano:SetSize(width, height)
  self:layoutMap()
  self.reveal:SetSize(width, height)
  self.big:SetSize(width, height - BAR)
end

-----------------------------
-- Playing a place
-----------------------------

--- Shows a place to look round in and guess
--- @param round integer
function View:play(round)
  local state = self.view.state
  local place = Where.placeOf(state, round)
  self.round, self.revealed, self.over, self.pin = round, nil, nil, nil
  self.animator:Stop()
  self.effects:Clear()
  self.reveal:Hide()
  self.hud:Show()
  self.corner:Show()
  self.small:Clear()
  self.small:Show(startMap())
  local loaded = place and self.pano:Show(panorama(place)) or false
  self.missing:SetShown(not loaded)
  self.deadline = state.time > 0 and GetTime() + state.time or nil
  self:refreshHud()
  self:refreshGuess()
end

--- Pins where the player thinks they are
--- @param place Place
function View:pinAt(place)
  if not self.view or not self.view.canMove or self.revealed then
    return
  end
  self.pin = place
  self.small:SetPin("mine", { place = place, color = MINE, size = 14 })
  Widgets.PlaySound("MAP_PING")
  self:refreshGuess()
end

function View:refreshGuess()
  local button = self.guessButton
  local can = self.view and self.view.canMove and not self.revealed
  button:SetEnabled(can and self.pin ~= nil)
  button:SetText(self.pin and L["where_guess"] or L["where_place_pin"])
end

function View:refreshKeep()
  self.keepButton:SetText(ForeverGames.db.profile.whereKeepMap and L["where_map_let_shrink"] or L["where_map_keep_open"])
end

function View:refreshHud()
  local state = self.view.state
  local count = #state.places
  self.stats.round:Set(("%d/%d"):format(min(self.round or state.round, count), count))
  self.stats.score:Set(Where.points(state.total))
  self.stats.time:SetShown(state.time > 0)
end

--- Says where the player thinks they are, or that they don't: the time ran out without a pin
function View:guess()
  local view = self.view
  if not view or not view.canMove or self.revealed or self.reveal:IsShown() then
    return
  end
  local state = view.state
  if state.round ~= self.round then
    return
  end
  local said = self.pin and Places.Encode(self.pin)
  -- Before the move, as once the last is made the run is over and keeps no more
  if view.sample then
    view.sample(state.round .. "=" .. (said or Where.SKIP))
  end
  self.deadline = nil
  view.submit(said and (Where.GUESS .. said) or Where.SKIP)
end

--- @param elapsed number
function View:tick(elapsed)
  if not self.view then
    return
  end
  -- The map grows while the cursor is over it, and shrinks a moment after it has left: not while
  -- it is being dragged or gone into a zone, which the cursor may wander off the map doing, nor
  -- while it is kept open
  if self.corner:IsShown() then
    local small = self.small
    local busy = small.viewport.grab or small.diving or ForeverGames.db.profile.whereKeepMap
    if busy or self.corner:IsMouseOver() then
      self.mapGoal, self.leftAt = 1, nil
    elseif self.mapGoal == 1 then
      self.leftAt = self.leftAt or GetTime()
      if GetTime() - self.leftAt > SHRINK_AFTER then
        self.mapGoal = 0
      end
    end
    if math.abs(self.mapGrow - self.mapGoal) > 0.002 then
      self.mapGrow = self.mapGoal + (self.mapGrow - self.mapGoal) * GROW_LEFT ^ elapsed
      self:layoutMap()
    end
  end
  if self.deadline then
    local left = self.deadline - GetTime()
    self.stats.time:Set(Widgets.Time(max(0, math.ceil(left))), true)
    self.stats.time:Tint(left < 10 and Widgets.RED or nil)
    if left <= 0 then
      self:guess()
    end
  end
end

-----------------------------
-- A guess, shown
-----------------------------

--- What the rival guessed at each place, from their ghost: a place, or false for none
--- @return table<integer, Place|false>?
function View:rivalGuesses()
  local race = self.view.race
  local ghost = race and race.ghost
  if not ghost then
    return nil
  end
  local guesses = {}
  for _, sample in ipairs(ghost) do
    local round, said = sample:match("^(%d+)=(.+)$")
    round = tonumber(round)
    if round then
      guesses[round] = said ~= Where.SKIP and Places.Decode(said) or false
    end
  end
  return guesses
end

--- Puts a place and the guesses at it on the big map, numbered for the summary
function View:pinRound(round, number)
  local state = self.view.state
  local place, guess = Where.placeOf(state, round), state.guesses[round]
  local suffix = number and tostring(round) or ""
  local shown = {}
  if place then
    self.big:SetPin("answer" .. suffix, { place = place, color = ANSWER, size = number and 14 or 20, ring = false,
      label = number and tostring(round) or zoneName(place) })
    shown[#shown + 1] = place
  end
  if guess and guess.guess then
    self.big:SetPin("mine" .. suffix, { place = guess.guess, color = MINE, size = number and 10 or 15,
      label = not number and L["where_you"] or nil })
    self.big:Line("mine" .. suffix, "answer" .. suffix, LINE, number ~= nil)
    shown[#shown + 1] = guess.guess
  end
  local rival = self:rivalGuesses()
  rival = rival and rival[round]
  if rival then
    self.big:SetPin("rival" .. suffix, { place = rival, color = RIVAL, size = number and 10 or 15,
      label = not number and self.view.race.rival or nil })
    self.big:Line("rival" .. suffix, "answer" .. suffix, RIVAL_LINE, number ~= nil)
    shown[#shown + 1] = rival
  end
  return shown
end

--- The points counting up to what a guess was worth (or the game came to), the bar filling
--- with them
--- @param points number
--- @param best number What fills the bar
--- @param prefix string? Before the number, "+" for a guess
function View:countUp(points, best, prefix)
  prefix = prefix or ""
  self.points:SetText(prefix .. "0")
  self.fill:SetWidth(1)
  self.animator:Play(COUNT, function(progress)
    self.points:SetText(prefix .. Where.points(points * progress))
    self.fill:SetWidth(max(1, self.track:GetWidth() * points / best * progress))
  end, { ease = Widgets.Ease.out, delay = 0.35 })
end

--- Shows how a guess went
--- @param round integer
function View:showReveal(round)
  local state = self.view.state
  local guess = state.guesses[round]
  self.revealed = round
  self.deadline = nil
  self.pano:Key("left", false)
  self.pano:Key("right", false)
  self.corner:Hide()
  self.hud:Hide()
  self.list:Hide()
  self.listBack:Hide()
  self.big:Clear()
  self.reveal:Show()
  self.big:Frame(self:pinRound(round))
  self.track:Show()
  self.fill:Show()
  if guess.yards then
    self.distance:SetText(L["where_yards"]:format(Where.points(guess.yards)))
  else
    self.distance:SetText(guess.guess and L["where_wrong_continent"] or L["where_no_guess"])
  end
  self:countUp(guess.points, Places.BEST, "+")
  if guess.points >= Places.BEST then
    Widgets.PlaySound("UI_EPICLOOT_TOAST")
  elseif guess.points >= Places.BEST * CHEER then
    Widgets.PlaySound("IG_QUEST_LIST_COMPLETE")
  end
  self.nextButton:SetText(round >= #state.places and L["where_see_results"] or L["where_next"])
  self.nextButton:Show()
  self:refreshHud()
end

--- On from a guess: to the next place, or to how the game went
function View:onward()
  local state = self.view.state
  if not self.revealed then
    return
  end
  self.animator:Stop()
  if state.round > #state.places then
    self:showSummary()
  else
    self:play(state.round)
  end
end

--- Every place of the game on the map, and what it all came to
function View:showSummary()
  local view, state = self.view, self.view.state
  self.over, self.revealed = true, nil
  self.deadline = nil
  self.corner:Hide()
  self.hud:Hide()
  self.big:Clear()
  self.reveal:Show()
  local everything, lines = {}, {}
  for round = 1, #state.places do
    for _, place in ipairs(self:pinRound(round, true)) do
      everything[#everything + 1] = place
    end
    local guess = state.guesses[round]
    local how = guess and (guess.yards and L["where_yards"]:format(Where.points(guess.yards))
      or (guess.guess and L["where_wrong_continent"] or L["where_no_guess"])) or ""
    lines[#lines + 1] = L["where_round_line"]:format(round, zoneName(Where.placeOf(state, round)), how,
      Where.points(guess and guess.points or 0))
  end
  self.big:Frame(everything)
  local most = #state.places * Places.BEST
  local best, isThis = nil, false
  if view.best then
    best, isThis = view.best("score")
  end
  if isThis then
    lines[#lines + 1] = "|cff40ff40" .. L["where_new_best"] .. "|r"
  elseif best then
    lines[#lines + 1] = L["where_best"]:format(Where.points(best))
  end
  local race = view.race
  if race and race.theirs then
    lines[#lines + 1] = L["where_rival_scored"]:format(race.rival, Where.points(race.theirs))
  end
  self.list:SetText(table.concat(lines, "\n"))
  self.list:Show()
  self.listBack:Show()
  self.distance:SetText(L["where_out_of"]:format(Where.points(most)))
  self.track:Show()
  self.fill:Show()
  self:countUp(state.total, math.max(1, most))
  self.nextButton:Hide()
  if most > 0 and state.total >= most * CHEER then
    self.effects:Confetti(0.6)
  end
end

-----------------------------
-- Update
-----------------------------

--- @param view GameView
function View:Update(view)
  self.view = view
  local state = view.state
  local id = view.match and view.match.id
  if id ~= self.matchId then
    -- Another game, or this one shown for the first time: at the place it is at
    self.matchId = id
    self.animator:Stop()
    self.effects:Clear()
    if state.round > #state.places then
      self:showSummary()
    else
      self:play(state.round)
    end
    return
  end
  -- A guess was made: shown before anything else
  if self.round and not self.revealed and not self.over and state.round > self.round and state.guesses[self.round] then
    self:showReveal(self.round)
    return
  end
  self:refreshHud()
  self:refreshGuess()
end

--- Whether the points are still counting up
--- @return boolean
function View:Busy()
  return self.animator:Busy()
end
