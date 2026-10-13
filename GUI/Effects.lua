--------------------------
--  Effects
--------------------------
-- What a game does to say that something happened, over whatever it draws: paper raining down on
-- a game that was won, a flash and a jolt for one that blew up, a number drifting up from where
-- points were made, and a few words across it all when it is over.
--
-- A game makes one of these over its stage and asks for what it wants when it wants it. None of
-- it takes the mouse, so whatever lies under it is played on as before, and all of it is gone
-- again with Clear: a view that is shown another position clears before it draws.
--
-- Nothing here knows any game. See Games/Minesweeper.lua, Games/Sudoku.lua and Games/2048.lua.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class Effects
--- @field frame Frame Lies over everything of the frame it was made for
local Effects = {}
Effects.__index = Effects
private.Effects = Effects

local FLAT = "Interface\\Buttons\\WHITE8X8"
-- The colours paper comes in
local PAPER = {
  { 1, 0.82, 0 },
  { 0.3, 0.9, 0.3 },
  { 0.25, 0.6, 1 },
  { 1, 0.35, 0.35 },
  { 0.8, 0.45, 1 },
  { 1, 1, 1 },
}
local PAPER_COUNT = 70
-- Seconds a piece of paper is in the air for, give or take, and over how long they set out
local PAPER_SECONDS, PAPER_SPREAD = 2.2, 0.9
-- Seconds a number drifts for, and how far up, as a multiple of its own height
local FLOAT_SECONDS, FLOAT_RISE = 0.9, 2.2
-- Seconds the words take to arrive, and how dark it gets behind them
local BANNER_SECONDS, BANNER_VEIL = 0.35, 0.55
local JOLTS = 6

--- @param parent Frame What it lies over, usually a game's stage
--- @return Effects
function Effects.New(parent)
  --- @type Effects
  local self = setmetatable({ papers = {}, floats = {}, jolts = {} }, Effects)
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetAllPoints()
  frame:SetFrameLevel(parent:GetFrameLevel() + 20)
  self.frame = frame
  self.animator = private.Widgets.Animator(frame)

  self.flash = frame:CreateTexture(nil, "BACKGROUND")
  self.flash:SetAllPoints()
  self.flash:Hide()

  self.veil = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
  self.veil:SetAllPoints()
  self.veil:SetColorTexture(0, 0, 0, 1)
  self.veil:Hide()
  self.title = frame:CreateFontString(nil, "OVERLAY")
  self.title:SetFont(STANDARD_TEXT_FONT, 20, "OUTLINE")
  self.title:SetPoint("CENTER", 0, 12)
  self.title:Hide()
  self.subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  self.subtitle:SetPoint("TOP", self.title, "BOTTOM", 0, -8)
  self.subtitle:Hide()

  -- What was on its way when the stage was hidden has got there by the time it is shown again
  frame:SetScript("OnHide", function()
    self.animator:Stop()
  end)
  return self
end

--- Whether anything is still on the move
--- @return boolean
function Effects:Busy()
  return self.animator:Busy()
end

--- Paper rains down over the stage: the game was won
--- @param delay number? Seconds to wait first
function Effects:Confetti(delay)
  local width, height = self.frame:GetWidth(), self.frame:GetHeight()
  for index = 1, PAPER_COUNT do
    local paper = self.papers[index]
    if not paper then
      paper = self.frame:CreateTexture(nil, "ARTWORK")
      paper:SetTexture(FLAT)
      self.papers[index] = paper
    end
    -- How it falls is nobody's business but the eye's, the client's own dice will do
    local color = PAPER[math.random(#PAPER)]
    local size = 5 + math.random() * 7
    local startX, drift = math.random() * width, (math.random() - 0.5) * width * 0.3
    local turns, sway = (math.random() - 0.5) * 10, math.random() * math.pi * 2
    paper:SetVertexColor(color[1], color[2], color[3])
    paper:SetSize(size, size * (0.4 + math.random() * 0.6))
    paper:Hide()
    self.animator:Play(PAPER_SECONDS * (0.7 + math.random() * 0.6), function(progress)
      local x = startX + drift * progress + math.sin(sway + progress * 9) * 8
      paper:ClearAllPoints()
      paper:SetPoint("CENTER", self.frame, "TOPLEFT", x, -(progress ^ 1.6) * (height + 20) + 10)
      paper:SetRotation(turns * progress)
      paper:SetAlpha(progress > 0.8 and (1 - progress) * 5 or 1)
    end, {
      delay = (delay or 0) + math.random() * PAPER_SPREAD,
      onStart = function()
        paper:Show()
      end,
      onDone = function()
        paper:Hide()
      end,
    })
  end
end

--- The whole stage lights up in a colour for a moment
--- @param color number[]
--- @param seconds number? 0.4 if left out
function Effects:Flash(color, seconds)
  local flash = self.flash
  flash:SetColorTexture(color[1], color[2], color[3], 1)
  flash:Show()
  self.animator:Play(seconds or 0.4, function(progress)
    flash:SetAlpha((1 - progress) * (color[4] or 0.5))
  end, {
    onDone = function()
      flash:Hide()
    end,
  })
end

--- Gives something a jolt: it is thrown about a little and comes to rest where it was
--- @param region Region
--- @param strength number? How far it is thrown, 6 if left out
function Effects:Jolt(region, strength)
  local jolt = self.jolts[region]
  if not jolt then
    jolt = region:CreateAnimationGroup()
    local steps = {}
    for order = 1, JOLTS do
      local step = jolt:CreateAnimation("Translation")
      step:SetOrder(order)
      step:SetDuration(0.045)
      steps[order] = step
    end
    jolt.steps = steps
    self.jolts[region] = jolt
  end
  -- Every step undoes the one before and goes a little less far the other way
  local at = 0
  for order, step in ipairs(jolt.steps) do
    local to = order == JOLTS and 0 or (strength or 6) * (1 - order / JOLTS) * (order % 2 == 0 and 1 or -1)
    step:SetOffset(to - at, (to - at) * 0.4)
    at = to
  end
  jolt:Stop()
  jolt:Play()
end

--- Something written drifts up from a place and fades: the points a move made
--- @param text string
--- @param x number Where it starts, right of the stage's top left corner
--- @param y number And below it
--- @param options { color: number[]?, size: number?, delay: number? }?
function Effects:Float(text, x, y, options)
  options = options or {}
  local float = nil
  for _, other in ipairs(self.floats) do
    float = float or (not other.busy and other or nil)
  end
  if not float then
    float = self.frame:CreateFontString(nil, "OVERLAY")
    self.floats[#self.floats + 1] = float
  end
  local size = options.size or 18
  float.busy = true
  float:SetFont(STANDARD_TEXT_FONT, size, "OUTLINE")
  float:SetText(text)
  float:SetTextColor(unpack(options.color or private.Widgets.GOLD))
  float:Hide()
  self.animator:Play(FLOAT_SECONDS, function(progress)
    float:ClearAllPoints()
    float:SetPoint("CENTER", self.frame, "TOPLEFT", x, -y + size * FLOAT_RISE * (1 - (1 - progress) ^ 2))
    float:SetAlpha(progress > 0.5 and (1 - progress) * 2 or 1)
  end, {
    delay = options.delay,
    onStart = function()
      float:Show()
    end,
    onDone = function()
      float.busy = false
      float:Hide()
    end,
  })
end

--- Writes across the stage how the game ended, and stays until Clear
--- @param title string
--- @param subtitle string? A line under it: the score, the time
--- @param options { color: number[]?, delay: number?, instant: boolean? }? instant for a game that was over before it was looked at
function Effects:Banner(title, subtitle, options)
  options = options or {}
  local size = math.max(20, math.min(54, math.floor(self.frame:GetWidth() * 0.09)))
  self.title:SetFont(STANDARD_TEXT_FONT, size, "OUTLINE")
  self.title:SetText(title)
  self.title:SetTextColor(unpack(options.color or private.Widgets.GOLD))
  self.subtitle:SetText(subtitle or "")
  self.banner = title

  local function show(progress)
    self.veil:SetAlpha(BANNER_VEIL * progress)
    self.title:SetAlpha(progress)
    self.subtitle:SetAlpha(progress)
    self.title:ClearAllPoints()
    self.title:SetPoint("CENTER", 0, 12 - (1 - progress) * size * 0.6)
  end
  local function reveal()
    self.veil:Show()
    self.title:Show()
    self.subtitle:Show()
  end
  if options.instant then
    reveal()
    show(1)
    return
  end
  self.animator:Play(BANNER_SECONDS, show, { delay = options.delay, ease = private.Widgets.Ease.out, onStart = reveal })
end

--- Whether there are words across the stage
--- @return boolean
function Effects:HasBanner()
  return self.banner ~= nil
end

--- Takes everything away again, at once
function Effects:Clear()
  -- Whatever was on its way gets there first, so that nothing arrives after it was cleared away
  self.animator:Stop()
  self.banner = nil
  self.veil:Hide()
  self.title:Hide()
  self.subtitle:Hide()
  self.flash:Hide()
end
