--------------------------
--  Starfall: what is seen and heard
--------------------------
-- The night's sky in the middle, the falling stars still to fire on its left and the score and
-- the constellations on its right. While the player may fire, the crescent at the top follows
-- the mouse (or the arrow keys) and a line of dots shows the way the star would go, as far as the
-- first stone it would touch, worked out by the same physics the shot is.
--
-- A shot is worked out whole by the rules the moment it is fired (Board.Fly), and what came of it
-- is the move's event: every flight's path, sixty places a second, and every touch with its tick.
-- The view plays that back: the star falls, stones light as it touches them, each with a chime a
-- step higher than the last, and once it is out of the sky the lit stones vanish one by one, the
-- constellations it finished wake, the score counts up and the Moonwell slides to its next place.
-- A position that wasn't just played (looking back, or a game loaded again) is drawn as it is.

local _, own = ...
local engine = ForeverGamesAPI
local L = engine.L
local Board = own.Board
local Physics = engine.Physics

local floor, min, max, abs = math.floor, math.min, math.max, math.abs

local IMAGES = "Interface\\AddOns\\ForeverGames_Starfall\\Images\\"
local SOUNDS = "Interface\\AddOns\\ForeverGames_Starfall\\Sounds\\"

local SKY_W, SKY_H = Board.SKY_WIDTH, Board.SKY_HEIGHT
local LX, LY = Board.LAUNCH_X, Board.LAUNCH_Y
local HZ, SAMPLE = Board.HZ, Board.SAMPLE
-- The panels either side of the sky, and the whole, in the sky's units
local PANEL = 132
local WIDTH, HEIGHT = SKY_W + 2 * PANEL, SKY_H
-- How big things are drawn, in units: a stone's picture has glow round it
local STONE_SIZE = 26
local STAR_SIZE = 28
local MARK_SIZE = 12
-- How far ahead the guide looks, in ticks, and a dot every so many
local GUIDE_TICKS, GUIDE_EVERY = floor(HZ * 1.1), 5
-- Trailing glows behind a falling star, a sample apart
local TRAIL = 7
-- How much faster a falling star goes while the player holds the button or Space
local HURRY = 3
-- Seconds between two lit stones vanishing, at most, and for all of them together
local POP_GAP, POP_ALL = 0.05, 1.1
-- Seconds a constellation takes to wake, and the score to count up
local WAKE_SECONDS, COUNT_SECONDS = 1.3, 0.6
-- Colours: the faint lines of a constellation, lit ones, woken ones
local LINE_DIM = { 0.6, 0.55, 1, 0.32 }
local LINE_LIT = { 1, 0.86, 0.5, 0.5 }
local LINE_WOKEN = { 1, 0.85, 0.35, 0.9 }
local GOLD = { 1, 0.84, 0.3 }
local PALE = { 0.78, 0.82, 1 }
-- The keys
local KEYS_LEFT, KEYS_RIGHT = { LEFT = true, A = true }, { RIGHT = true, D = true }
local KEYS_FIRE = { SPACE = true, ENTER = true }

--- 1234567 as "1,234,567"
--- @param value number
--- @return string
local function commas(value)
  local text = tostring(floor(value))
  local made
  repeat
    text, made = text:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
  until made == 0
  return text
end
own.commas = commas

--- A place along a flight's path, `k` samples after it set out
local function along(path, k)
  local n = #path / 2
  if k <= 0 then
    return path[1], path[2]
  elseif k >= n - 1 then
    return path[2 * n - 1], path[2 * n]
  end
  local i = floor(k)
  local f = k - i
  local x1, y1, x2, y2 = path[2 * i + 1], path[2 * i + 2], path[2 * i + 3], path[2 * i + 4]
  return x1 + (x2 - x1) * f, y1 + (y2 - y1) * f
end

local function play(name)
  if engine.SoundOn() then
    PlaySoundFile(SOUNDS .. name .. ".ogg", "SFX")
  end
end

local function ease(progress)
  return 1 - (1 - progress) * (1 - progress)
end

local View = {}
View.__index = View

-----------------------------
-- Building
-----------------------------

--- A picture of the sky's, from a pool that grows as more are needed
local function pool(self, name, layer, sublevel, file, additive)
  local list = self.pools[name]
  if not list then
    list = { used = 0 }
    self.pools[name] = list
  end
  return function()
    list.used = list.used + 1
    local texture = list[list.used]
    if not texture then
      texture = self.canvas:CreateTexture(nil, layer, nil, sublevel)
      texture:SetTexture(IMAGES .. file)
      if additive then
        texture:SetBlendMode("ADD")
      end
      list[list.used] = texture
    end
    texture:Show()
    return texture
  end, list
end

--- Hides every picture of a pool, to be used again
local function release(list)
  for index = 1, #list do
    list[index]:Hide()
  end
  list.used = 0
end

local function label(parent, size, color, justify)
  local text = parent:CreateFontString(nil, "OVERLAY")
  text.size = size
  text:SetFont(STANDARD_TEXT_FONT, size, "OUTLINE")
  text:SetTextColor(unpack(color or PALE))
  text:SetJustifyH(justify or "CENTER")
  return text
end

--- @param stage Frame
function own.CreateView(stage)
  local self = setmetatable({ stage = stage, pools = {}, scale = 1, aim = Board.AIMS / 2, stones = {}, glows = {}, marks = {}, lines = {}, burstsFree = {} }, View)
  local frame = CreateFrame("Frame", nil, stage)
  frame:SetPoint("CENTER")
  self.frame = frame

  -- The panels' backing, the whole width
  local back = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
  back:SetAllPoints()
  back:SetColorTexture(0.03, 0.03, 0.08, 0.92)

  local sky = CreateFrame("Frame", nil, frame)
  sky:SetClipsChildren(true)
  sky:EnableMouse(true)
  self.sky = sky
  -- Everything in the sky is drawn on a frame inside it, so that the sky's edges cut it off
  local canvas = CreateFrame("Frame", nil, sky)
  canvas:SetAllPoints()
  self.canvas = canvas
  self.background = canvas:CreateTexture(nil, "BACKGROUND")
  self.background:SetAllPoints()
  self.background:SetTexture(IMAGES .. "sky")
  self.background:SetTexCoord(0, 1, 0, 0.75)
  -- A thin edge of moonlight round the sky
  self.edges = {}
  for index = 1, 4 do
    local edge = frame:CreateTexture(nil, "BORDER")
    edge:SetColorTexture(0.55, 0.6, 1, 0.45)
    self.edges[index] = edge
  end

  -- The Moonwell, its glow over it, and its light thrown up
  self.well = canvas:CreateTexture(nil, "ARTWORK", nil, 1)
  self.well:SetTexture(IMAGES .. "well")
  self.wellGlow = canvas:CreateTexture(nil, "ARTWORK", nil, 2)
  self.wellGlow:SetTexture(IMAGES .. "wellGlow")
  self.wellGlow:SetBlendMode("ADD")

  -- The crescent the stars are fired from, and the star waiting in it
  self.crescent = canvas:CreateTexture(nil, "OVERLAY", nil, 2)
  self.crescent:SetTexture(IMAGES .. "crescent")
  self.ready = canvas:CreateTexture(nil, "OVERLAY", nil, 3)
  self.ready:SetTexture(IMAGES .. "comet")
  self.ready:SetBlendMode("ADD")

  -- The pictures there are many of
  self.newDot, self.dots = pool(self, "dots", "OVERLAY", 0, "glow", true)
  self.newTrail, self.trails = pool(self, "trails", "OVERLAY", 1, "glow", true)
  self.newBall, self.balls = pool(self, "balls", "OVERLAY", 4, "comet", true)

  -- The left panel: the stars still to fire
  self.starsTitle = label(frame, 12, PALE)
  self.starsTitle:SetText(L["starfall_stars"])
  self.starsCount = label(frame, 30, GOLD)
  self.quiver = {}

  -- The right panel: the score, the shot, the constellations, a rival
  self.scoreTitle = label(frame, 12, PALE)
  self.scoreTitle:SetText(L["starfall_score"])
  self.score = label(frame, 24, GOLD)
  self.best = label(frame, 10, PALE)
  self.shotPoints = label(frame, 16, { 1, 1, 1 })
  self.chain = label(frame, 20, { 0.55, 1, 0.85 })
  self.groupsTitle = label(frame, 12, PALE)
  self.groupsTitle:SetText(L["starfall_constellations"])
  self.groupRows = {}
  self.rival = label(frame, 10, { 1, 0.6, 0.6 })
  self.rival:SetWordWrap(true)

  self.effects = engine.Effects.New(frame)
  local animated = CreateFrame("Frame", nil, frame)
  self.animator = engine.Widgets.Animator(animated)

  -- The aim, the shot played back, and the stars twinkling, every frame
  local ticker = CreateFrame("Frame", nil, stage)
  ticker:SetAllPoints()
  self.ticker = ticker
  ticker:SetScript("OnUpdate", function(_, elapsed)
    self:OnFrame(elapsed)
  end)
  engine.Widgets.Keys(ticker, function(key)
    return self:KeyDown(key)
  end)
  ticker:SetScript("OnKeyUp", function(_, key)
    if KEYS_FIRE[key] then
      self.held = false
    end
  end)
  sky:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" then
      self.usingKeys = false
      self:Fire()
    end
  end)
  return self
end

-----------------------------
-- Layout
-----------------------------

--- Puts a picture with its middle at a place in the sky, so big
function View:Put(texture, x, y, width, height)
  local s = self.scale
  texture:ClearAllPoints()
  texture:SetPoint("CENTER", self.sky, "TOPLEFT", x * s, -y * s)
  texture:SetSize(width * s, (height or width) * s)
end

function View:Layout(width, height)
  local s = min(width / WIDTH, height / HEIGHT)
  self.scale = s
  local frame = self.frame
  frame:SetSize(WIDTH * s, HEIGHT * s)
  self.sky:ClearAllPoints()
  self.sky:SetPoint("TOPLEFT", frame, "TOPLEFT", PANEL * s, 0)
  self.sky:SetSize(SKY_W * s, SKY_H * s)
  local e = self.edges
  local line = max(1, s)
  e[1]:SetPoint("TOPLEFT", self.sky, "TOPLEFT", -line, 0)
  e[1]:SetPoint("BOTTOMRIGHT", self.sky, "BOTTOMLEFT", 0, 0)
  e[2]:SetPoint("TOPLEFT", self.sky, "TOPRIGHT", 0, 0)
  e[2]:SetPoint("BOTTOMRIGHT", self.sky, "BOTTOMRIGHT", line, 0)
  e[3]:SetPoint("BOTTOMLEFT", self.sky, "TOPLEFT", -line, 0)
  e[3]:SetPoint("TOPRIGHT", self.sky, "TOPRIGHT", line, line)
  e[4]:Hide()

  for _, text in ipairs({ self.starsTitle, self.starsCount, self.scoreTitle, self.score, self.best, self.shotPoints, self.chain, self.groupsTitle, self.rival }) do
    text:SetFont(STANDARD_TEXT_FONT, max(6, text.size * s), "OUTLINE")
  end
  local mid = PANEL / 2
  self.starsTitle:SetPoint("TOP", frame, "TOPLEFT", mid * s, -16 * s)
  self.starsCount:SetPoint("TOP", frame, "TOPLEFT", mid * s, -34 * s)
  local right = (PANEL + SKY_W + PANEL / 2) * s
  self.scoreTitle:SetPoint("TOP", frame, "TOPLEFT", right, -16 * s)
  self.score:SetPoint("TOP", frame, "TOPLEFT", right, -32 * s)
  self.best:SetPoint("TOP", frame, "TOPLEFT", right, -60 * s)
  self.shotPoints:SetPoint("TOP", frame, "TOPLEFT", right, -82 * s)
  self.chain:SetPoint("TOP", frame, "TOPLEFT", right, -102 * s)
  self.groupsTitle:SetPoint("TOP", frame, "TOPLEFT", right, -136 * s)
  self.rival:SetPoint("BOTTOM", frame, "BOTTOMLEFT", right, 14 * s)
  self.rival:SetWidth((PANEL - 12) * s)

  self:Put(self.crescent, LX, LY, 72)
  self.drawnAim = nil
  local anim = self.anim
  if anim then
    self:DrawStones(anim.gone, anim.lit)
    self:DrawGroups(anim.gone, anim.lit)
    self:DrawQuiver(anim.stars)
    self:PlaceWell(self.wellLeft)
  elseif self.state then
    self:Draw()
  end
end

-----------------------------
-- Drawing a position
-----------------------------

--- The Moonwell at a place along the bottom
function View:PlaceWell(left)
  self.wellLeft = left
  local width = Board.WELL_WIDTH
  self:Put(self.well, left + width / 2, SKY_H - 10, width + 24, 40)
  self:Put(self.wellGlow, left + width / 2, SKY_H - 28, width + 40, 72)
end

--- The stones and constellations as they are, with these stones gone and these lit
--- @param gone table<integer, boolean>
--- @param lit table<integer, boolean>?
function View:DrawStones(gone, lit)
  local state = self.state
  lit = lit or {}
  local stones = state.stones
  for index, stone in ipairs(stones) do
    local picture = self.stones[index]
    if not picture then
      picture = self.canvas:CreateTexture(nil, "ARTWORK", nil, 0)
      self.stones[index] = picture
      local glow = self.canvas:CreateTexture(nil, "ARTWORK", nil, -2)
      glow:SetTexture(IMAGES .. "glow")
      glow:SetBlendMode("ADD")
      self.glows[index] = glow
      local mark = self.canvas:CreateTexture(nil, "ARTWORK", nil, -1)
      mark:SetTexture(IMAGES .. "spark")
      mark:SetBlendMode("ADD")
      self.marks[index] = mark
    end
    local glow, mark = self.glows[index], self.marks[index]
    local kind = stone.kind
    local woken = stone.group and state.constellations[stone.group].woken
    if gone[index] then
      picture:Hide()
      glow:Hide()
      -- A star lit already is a small light in the sky where it was, a woken one a bright one
      if kind == "star" then
        self:Put(mark, stone.x, stone.y, woken and MARK_SIZE * 1.8 or MARK_SIZE)
        mark:SetVertexColor(1, 0.9, 0.6, woken and 1 or 0.55)
        mark:Show()
      else
        mark:Hide()
      end
    else
      mark:Hide()
      local on = lit[index]
      picture:SetTexture(IMAGES .. kind .. (on and "Lit" or ""))
      local size = kind == "star" and STAR_SIZE or STONE_SIZE
      self:Put(picture, stone.x, stone.y, size)
      picture:Show()
      if on or kind ~= "stone" then
        local color = kind == "wisp" and { 0.3, 1, 0.75 } or (kind == "star" and GOLD or PALE)
        glow:SetVertexColor(color[1], color[2], color[3])
        glow.base = on and 0.95 or 0.35
        glow.twinkle = not on
        glow:SetAlpha(glow.base)
        self:Put(glow, stone.x, stone.y, on and size * 2.6 or size * 1.9)
        glow:Show()
      else
        glow:Hide()
      end
    end
  end
  for index = #stones + 1, #self.stones do
    self.stones[index]:Hide()
    self.glows[index]:Hide()
    self.marks[index]:Hide()
  end

  -- The constellations' lines
  local count = 0
  for _, group in ipairs(state.constellations) do
    local joined = group.lines
    for index = 1, #joined - 1, 2 do
      count = count + 1
      local line = self.lines[count]
      if not line then
        line = self.canvas:CreateLine(nil, "BORDER")
        line:SetTexture("Interface\\Buttons\\WHITE8X8")
        self.lines[count] = line
      end
      local a, b = stones[joined[index]], stones[joined[index + 1]]
      local s = self.scale
      line:SetStartPoint("TOPLEFT", self.sky, a.x * s, -a.y * s)
      line:SetEndPoint("TOPLEFT", self.sky, b.x * s, -b.y * s)
      local done = function(which)
        return gone[which] or lit[which]
      end
      local color = group.woken and LINE_WOKEN or ((done(joined[index]) and done(joined[index + 1])) and LINE_LIT or LINE_DIM)
      line:SetColorTexture(color[1], color[2], color[3], color[4])
      line:SetThickness(max(1, (group.woken and 2 or 1.4) * s))
      line:Show()
    end
  end
  for index = count + 1, #self.lines do
    self.lines[index]:Hide()
  end
end

--- The falling stars still to fire, down the left
function View:DrawQuiver(count)
  local s = self.scale
  self.starsCount:SetText(count)
  for index = 1, max(count, #self.quiver) do
    local icon = self.quiver[index]
    if not icon and index <= count then
      icon = self.frame:CreateTexture(nil, "ARTWORK")
      icon:SetTexture(IMAGES .. "comet")
      icon:SetBlendMode("ADD")
      self.quiver[index] = icon
    end
    if icon then
      if index <= min(count, 16) then
        local column, row = (index - 1) % 2, floor((index - 1) / 2)
        icon:ClearAllPoints()
        icon:SetPoint("CENTER", self.frame, "TOPLEFT", (PANEL / 2 + (column - 0.5) * 34) * s, -(92 + row * 40) * s)
        icon:SetSize(34 * s, 34 * s)
        icon:Show()
      else
        icon:Hide()
      end
    end
  end
end

--- The constellations down the right: their names, gold once woken, and how many of their stars are lit
function View:DrawGroups(gone, lit)
  local state, s = self.state, self.scale
  lit = lit or {}
  for index, group in ipairs(state.constellations) do
    local row = self.groupRows[index]
    if not row then
      row = label(self.frame, 11, PALE)
      self.groupRows[index] = row
    end
    row:SetFont(STANDARD_TEXT_FONT, max(6, 11 * s), "OUTLINE")
    local done = 0
    for _, star in ipairs(group.stars) do
      if gone[star] or lit[star] then
        done = done + 1
      end
    end
    row:ClearAllPoints()
    row:SetPoint("TOP", self.frame, "TOPLEFT", (PANEL + SKY_W + PANEL / 2) * s, -(156 + (index - 1) * 30) * s)
    row:SetText(L["starfall_c_" .. group.name])
    row:SetTextColor(unpack(group.woken and GOLD or PALE))
    row:Show()
    -- A light for each of its stars under the name, bright for those lit
    row.pips = row.pips or {}
    local count = #group.stars
    for pip = 1, max(count, #row.pips) do
      local light = row.pips[pip]
      if not light and pip <= count then
        light = self.frame:CreateTexture(nil, "ARTWORK")
        light:SetTexture(IMAGES .. "spark")
        light:SetBlendMode("ADD")
        row.pips[pip] = light
      end
      if light then
        if pip <= count then
          light:ClearAllPoints()
          light:SetPoint("CENTER", self.frame, "TOPLEFT", (PANEL + SKY_W + PANEL / 2 + (pip - (count + 1) / 2) * 13) * s, -(156 + (index - 1) * 30 + 18) * s)
          light:SetSize(14 * s, 14 * s)
          if group.woken then
            light:SetVertexColor(1, 0.85, 0.35, 1)
          elseif pip <= done then
            light:SetVertexColor(1, 0.9, 0.6, 0.9)
          else
            light:SetVertexColor(0.45, 0.45, 0.7, 0.45)
          end
          light:Show()
        else
          light:Hide()
        end
      end
    end
  end
  for index = #state.constellations + 1, #self.groupRows do
    self.groupRows[index]:Hide()
    for _, light in ipairs(self.groupRows[index].pips or {}) do
      light:Hide()
    end
  end
end

--- The score, the best and a rival
function View:DrawScore(score)
  self.score:SetText(commas(score))
  local view = self.view
  local best = view and view.best and view.best("score")
  self.best:SetText(best and L["starfall_best"]:format(commas(best)) or "")
  local race = view and view.race
  if not race then
    self.rival:SetText("")
    return
  end
  local text
  if race.theirs then
    text = L["starfall_rival"]:format(race.rival, commas(race.theirs))
  elseif race.ghost then
    -- Where they were after as many shots
    local shots, theirs = self.state.shots, nil
    for _, sample in ipairs(race.ghost) do
      local n, value = sample:match("^(%d+)=(%d+)$")
      if n and tonumber(n) <= shots then
        theirs = { tonumber(n), tonumber(value) }
      end
    end
    if theirs then
      text = L["starfall_rival_after"]:format(race.rival, theirs[1], commas(theirs[2]))
    end
  end
  self.rival:SetText(text or race.rival)
end

--- Everything as the position has it, nothing moving
function View:Draw()
  local state = self.state
  self:DrawStones(state.gone)
  self:DrawGroups(state.gone)
  self:DrawQuiver(state.stars)
  self:DrawScore(state.score)
  self:PlaceWell(Board.WellLeft(state.well))
  self.shotPoints:SetText("")
  self.chain:SetText("")
  self:DrawAim()
end

-----------------------------
-- Aiming
-----------------------------

--- Whether the player may fire now
function View:CanFire()
  local view = self.view
  return view ~= nil and view.canMove and view.live and not self.anim and not self.state.over
end

--- The crescent turned to the aim, the star in it, and the dots of the way it would go
function View:DrawAim()
  local state = self.state
  local can = self:CanFire()
  -- Asked often with nothing changed: the guide is only worked out again for a new aim or position
  local drawn = (can and "y" or "n") .. self.aim .. ":" .. (self.shown or "")
  if drawn == self.drawnAim then
    return
  end
  self.drawnAim = drawn
  release(self.dots)
  local angle = (self.aim - Board.AIMS / 2) / 10 * math.pi / 180
  -- Its open side faces down, and turns the way the star is aimed: anticlockwise to the right
  self.crescent:SetRotation(angle)
  self.ready:SetShown(not self.anim and not state.over)
  local vx, vy = Board.Launch(self.aim)
  self:Put(self.ready, LX + vx / Board.LAUNCH_SPEED * 10, LY + vy / Board.LAUNCH_SPEED * 10, 40)
  if not can then
    return
  end
  -- The way it would go, by the physics a shot flies by, as far as the first stone
  local key = self.view.match.id .. ":" .. state.shots
  if self.guideKey ~= key then
    self.guideKey = key
    self.guideWorld = Board.World(state.stones, state.gone)
  end
  local world = self.guideWorld
  local ball = world:AddBall(LX, LY, Board.STAR_RADIUS)
  world:Launch(ball, vx, vy)
  local touched = false
  world.onEvent = function(kind, made)
    if kind == "hit" and made and made.game then
      touched = true
    end
  end
  local dots = 0
  for tick = 1, GUIDE_TICKS do
    world:Tick()
    if touched or ball.y > SKY_H then
      break
    end
    if tick % GUIDE_EVERY == 0 and tick > 8 then
      dots = dots + 1
      local dot = self.newDot()
      self:Put(dot, ball.x, ball.y, 7)
      dot:SetVertexColor(0.85, 0.9, 1)
      dot:SetAlpha(max(0.15, 0.9 - dots * 0.02))
    end
  end
  if touched then
    -- Where it would meet the stone
    local dot = self.newDot()
    self:Put(dot, ball.x, ball.y, 16)
    dot:SetVertexColor(1, 0.9, 0.5)
    dot:SetAlpha(0.9)
  end
  world:RemoveBall(ball)
end

--- The aim the mouse points at, if it is over the sky
function View:AimAtCursor()
  if self.usingKeys or not self.sky:IsMouseOver() then
    return
  end
  local x, y = GetCursorPosition()
  local scale = self.sky:GetEffectiveScale()
  local left, top = self.sky:GetLeft(), self.sky:GetTop()
  if not left or not top then
    return
  end
  local ux, uy = (x / scale - left) / self.scale, (top - y / scale) / self.scale
  local dx, dy = ux - LX, max(0.5, uy - LY)
  local degrees = math.atan2(dx, dy) * 180 / math.pi
  local aim = max(0, min(Board.AIMS, floor(Board.AIMS / 2 + degrees * 10 + 0.5)))
  if aim ~= self.aim then
    self.aim = aim
    self:DrawAim()
  end
end

function View:KeyDown(key)
  if KEYS_FIRE[key] then
    if self:CanFire() then
      self:Fire()
    else
      self.held = true
    end
    return true
  end
  local way = KEYS_LEFT[key] and -1 or (KEYS_RIGHT[key] and 1 or 0)
  if way ~= 0 and self:CanFire() then
    self.usingKeys = true
    -- Left turns the crescent's mouth to the left, which is a smaller aim
    local step = IsShiftKeyDown() and 20 or 2
    self.aim = max(0, min(Board.AIMS, self.aim + way * step))
    self:DrawAim()
    return true
  end
  return false
end

function View:Fire()
  if not self:CanFire() then
    return
  end
  release(self.dots)
  self.drawnAim = nil
  self.view.submit("a" .. self.aim)
end

-----------------------------
-- A shot played back
-----------------------------

--- A ring of light bursting out from a place and fading
function View:Burst(x, y, size, color, seconds)
  local burst = table.remove(self.burstsFree)
  if not burst then
    burst = self.canvas:CreateTexture(nil, "OVERLAY", nil, 5)
    burst:SetTexture(IMAGES .. "ring")
    burst:SetBlendMode("ADD")
  end
  burst:SetVertexColor(color[1], color[2], color[3])
  burst:Show()
  self.animator:Play(seconds or 0.45, function(progress)
    self:Put(burst, x, y, size * (0.4 + progress))
    burst:SetAlpha(1 - progress)
  end, {
    ease = ease,
    onDone = function()
      burst:Hide()
      self.burstsFree[#self.burstsFree + 1] = burst
    end,
  })
end

--- Starts playing back a shot that led to the position
--- @param shot StarfallShot
function View:StartShot(shot)
  local state = self.state
  -- What the sky was like before it: the stones it lit still there, the stars it had
  local gone = {}
  for index in pairs(state.gone) do
    gone[index] = true
  end
  for _, index in ipairs(shot.lit) do
    gone[index] = nil
  end
  local woken = {}
  for _, index in ipairs(shot.woken) do
    woken[index] = true
    state.constellations[index].woken = false
  end
  local stars = state.stars + 1 - (shot.well and 1 or 0)
  local before = state.score - shot.points - (shot.bonus or 0)
  self.anim = {
    shot = shot,
    t = 0,
    gone = gone,
    lit = {},
    litCount = 0,
    points = 0,
    touch = 1,
    freed = 1,
    woken = woken,
    stars = stars - 1,
    before = before,
    wellDone = {},
    wellLeft = self.wellLeft,
  }
  -- The view drew the position after the shot: put its constellations back as they were before
  -- it, for as long as it is played
  self:DrawStones(gone)
  self:DrawGroups(gone)
  self:DrawQuiver(stars - 1)
  self:DrawScore(before)
  self.shotPoints:SetText("")
  self.chain:SetText("")
  self.aim = shot.aim
  self:DrawAim()
  self.ready:Hide()
  play("fire")
  self:Burst(LX, LY, 60, PALE, 0.35)
end

--- The constellations the shot woke are woken, now that it is time to say so
function View:WakeAll()
  for index in pairs(self.anim.woken) do
    self.state.constellations[index].woken = true
  end
end

--- Moves a shot on by a frame
function View:Advance(elapsed)
  local anim = self.anim
  local shot = anim.shot
  if anim.phase then
    return
  end
  local hurry = (self.held or IsMouseButtonDown("LeftButton")) and HURRY or 1
  anim.t = anim.t + elapsed * HZ * hurry
  local t = anim.t
  local stones = self.state.stones
  local changed = false

  -- Every touch up to now: the stone lit, with a chime a step higher than the last
  local touches = shot.touches
  while anim.touch <= #touches and touches[anim.touch].at <= t do
    local touch = touches[anim.touch]
    anim.touch = anim.touch + 1
    local stone = stones[touch.stone]
    if touch.first then
      anim.lit[touch.stone] = true
      anim.litCount = anim.litCount + 1
      anim.points = anim.points + Board.POINTS[stone.kind]
      changed = true
      play("chime" .. min(anim.litCount, 14))
      local color = stone.kind == "wisp" and { 0.3, 1, 0.75 } or (stone.kind == "star" and GOLD or PALE)
      self:Burst(stone.x, stone.y, 46, color, 0.4)
      if stone.kind == "wisp" then
        play("wisp")
        anim.gone[touch.stone] = true
      end
    else
      play("tick")
      self:Burst(stone.x, stone.y, 30, PALE, 0.25)
    end
  end
  local freed = shot.freed
  while anim.freed <= #freed and freed[anim.freed].at <= t do
    local index = freed[anim.freed].stone
    anim.freed = anim.freed + 1
    anim.gone[index] = true
    anim.lit[index] = true
    changed = true
    play("pop")
  end
  if changed then
    self:DrawStones(anim.gone, anim.lit)
    self:DrawGroups(anim.gone, anim.lit)
    local chain = 1 + floor(anim.litCount / Board.CHAIN)
    self.shotPoints:SetText("+" .. commas(anim.points))
    self.chain:SetText(chain > 1 and L["starfall_chain"]:format(chain) or "")
  end

  -- The falling stars where they are, each with its trail
  release(self.balls)
  release(self.trails)
  local flying = false
  for index, flight in ipairs(shot.flights) do
    local k = (t - flight.from) / SAMPLE
    local last = #flight.path / 2 - 1
    if k >= 0 and k < last then
      flying = true
      local x, y = along(flight.path, k)
      local ball = self.newBall()
      self:Put(ball, x, y, 44)
      for back = 1, TRAIL do
        local tk = k - back * 0.8
        if tk >= 0 then
          local tx, ty = along(flight.path, tk)
          local trail = self.newTrail()
          local fade = 1 - back / (TRAIL + 1)
          self:Put(trail, tx, ty, 18 * fade + 4)
          trail:SetVertexColor(0.75, 0.85, 1)
          trail:SetAlpha(0.55 * fade)
        end
      end
    elseif k >= last and flight.well and not anim.wellDone[index] then
      anim.wellDone[index] = true
      anim.stars = anim.stars + 1
      self:DrawQuiver(anim.stars)
      play("well")
      self:Burst(self.wellLeft + Board.WELL_WIDTH / 2, SKY_H - 16, 140, { 0.6, 0.8, 1 }, 0.7)
      self.effects:Float(L["starfall_returned"], (PANEL + self.wellLeft + Board.WELL_WIDTH / 2) * self.scale, (SKY_H - 60) * self.scale, { size = max(10, floor(16 * self.scale)), color = { 0.7, 0.9, 1 } })
    elseif k < 0 then
      flying = true
    end
  end
  if not flying and t >= shot.ticks then
    self:Finish()
  end
end

--- The shot is over: the lit stones vanish, constellations wake, the score counts up and the
--- Moonwell moves on
function View:Finish()
  local anim = self.anim
  local shot = anim.shot
  local state = self.state
  anim.phase = "after"
  release(self.balls)
  release(self.trails)
  local delay = 0
  local gap = #shot.lit > 0 and min(POP_GAP, POP_ALL / #shot.lit) or 0
  for _, index in ipairs(shot.lit) do
    if not anim.gone[index] then
      self.animator:Play(0, function() end, {
        delay = delay,
        onDone = function()
          anim.gone[index] = true
          anim.lit[index] = nil
          local stone = state.stones[index]
          self:Burst(stone.x, stone.y, 40, stone.kind == "star" and GOLD or PALE, 0.3)
          self:DrawStones(anim.gone, anim.lit)
          play("pop")
        end,
      })
      delay = delay + gap
    end
  end
  delay = delay + 0.25
  if shot.chain > 1 then
    self.shotPoints:SetText("+" .. commas(anim.points * shot.chain))
  end
  -- Each constellation woken, one after the other
  for _, index in ipairs(shot.woken) do
    self.animator:Play(WAKE_SECONDS, function(progress)
      local glow = progress < 0.5 and progress * 2 or (1 - progress) * 2
      self.background:SetVertexColor(1, 1 - glow * 0.1, 1 - glow * 0.3)
    end, {
      delay = delay,
      onStart = function()
        local group = state.constellations[index]
        group.woken = true
        self:DrawStones(anim.gone, anim.lit)
        self:DrawGroups(anim.gone, anim.lit)
        play("wake")
        local x, y = 0, 0
        for _, star in ipairs(group.stars) do
          local stone = state.stones[star]
          x, y = x + stone.x, y + stone.y
          self:Burst(stone.x, stone.y, 90, GOLD, 0.9)
        end
        x, y = x / #group.stars, y / #group.stars
        self.effects:Float(L["starfall_wakes"]:format(L["starfall_c_" .. group.name]), (PANEL + x) * self.scale, y * self.scale, { size = max(12, floor(22 * self.scale)), color = GOLD })
      end,
    })
    delay = delay + WAKE_SECONDS * 0.8
  end
  -- The score counting up, and the Moonwell to its next place
  local from, to = anim.before, state.score
  local wellFrom, wellTo = anim.wellLeft, Board.WellLeft(state.well)
  self.animator:Play(COUNT_SECONDS, function(progress)
    self:DrawScore(from + (to - from) * progress)
    if not state.over then
      self:PlaceWell(wellFrom + (wellTo - wellFrom) * progress)
    end
  end, {
    delay = delay,
    ease = ease,
    onStart = function()
      if to > from then
        play("count")
      end
    end,
    onDone = function()
      if self.anim ~= anim then
        return
      end
      self:WakeAll()
      self.anim = nil
      self:Draw()
      self:Ended(true)
    end,
  })
end

--- The night won or lost, said once it is
--- @param now boolean? It ended just now, rather than before it was looked at
function View:Ended(now)
  local state = self.state
  if not state.over then
    return
  end
  if state.outcome and state.outcome.winner == 1 then
    if now then
      play("won")
      self.effects:Confetti()
    end
    self.effects:Banner(L["starfall_won"], state.stars > 0 and L["starfall_won_text"]:format(state.stars, commas(state.stars * Board.UNSPENT)) or L["starfall_points"]:format(commas(state.score)), { instant = not now })
  else
    if now then
      play("dawn")
    end
    local left = Board.StarsLeft(state)
    self.effects:Banner(L["starfall_dawn"], L["starfall_dawn_text"]:format(left), { color = { 1, 0.6, 0.4 }, instant = not now })
  end
end

-----------------------------
-- Every frame
-----------------------------

function View:OnFrame(elapsed)
  if not self.state then
    return
  end
  if self.anim then
    self:Advance(elapsed)
  elseif self:CanFire() then
    self:AimAtCursor()
  end
  -- The stars still to light twinkle, each in its own time
  self.clock = (self.clock or 0) + elapsed
  local now = self.clock
  for index, glow in ipairs(self.glows) do
    if glow.twinkle and glow:IsShown() then
      glow:SetAlpha(glow.base * (0.75 + 0.25 * math.sin(now * 2.2 + index * 1.7)))
    end
  end
  local pulse = 0.7 + 0.3 * math.sin(now * 1.6)
  self.wellGlow:SetAlpha(pulse)
end

function View:Busy()
  return self.anim ~= nil
end

function View:Update(view)
  self.view = view
  local state = view.state
  local key = view.match.id .. ":" .. view.ply
  local played = view.played
  if key == self.shown then
    -- Nothing new: only whether the player may fire
    if not self.anim then
      self:DrawAim()
    end
    return
  end
  self.shown = key
  local sameMatch = self.matchId == view.match.id
  self.matchId = view.match.id
  if self.anim then
    self.anim = nil
    self.animator:Stop()
  end
  self.effects:Clear()
  self.background:SetVertexColor(1, 1, 1)
  -- The rules' own table is the engine's: the view keeps a copy it may change as it plays back
  self.state = engine.Tables.Copy(state)
  if not sameMatch then
    self.aim = Board.AIMS / 2
  end
  if played and played.aim and played.flights then
    if view.sample and view.live then
      view.sample(state.shots .. "=" .. state.score)
    end
    self:StartShot(played)
  else
    self:Draw()
    self:Ended(false)
  end
end
