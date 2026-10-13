--------------------------
--  Widgets
--------------------------
-- Small building blocks shared by the windows, so they look like they belong together.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class Widgets
local Widgets = {}
private.Widgets = Widgets

local FLAT = "Interface\\Buttons\\WHITE8X8"
local SOUND_FILES = "Interface\\AddOns\\ForeverGames\\Sounds\\"
-- The addon's own sounds and how many takes there are of each, so the same thing doesn't sound
-- the same every time: Sounds/<name><take>.ogg
local SOUNDS = { cardPlace = 3, cardSlide = 3, chipsCollide = 3, dieThrow = 2, dieShuffle = 1 }

Widgets.GREEN = { 0.3, 0.9, 0.3 }
Widgets.GREY = { 0.65, 0.65, 0.65 }
Widgets.GOLD = { 1, 0.82, 0 }

--- A slightly darker box with a hairline border, for grouping content
--- @param parent Frame
--- @param frameType string?
--- @return Frame
function Widgets.Panel(parent, frameType)
  local panel = CreateFrame(frameType or "Frame", nil, parent, "BackdropTemplate")
  panel:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1 })
  panel:SetBackdropColor(0, 0, 0, 0.4)
  panel:SetBackdropBorderColor(1, 1, 1, 0.1)
  return panel
end

--- @param parent Frame
--- @param text string
--- @param width number
--- @param height number?
--- @return Button
function Widgets.Button(parent, text, width, height)
  local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  button:SetSize(width, height or 24)
  button:SetText(text)
  return button
end

--- @param parent Frame
--- @param font string Font object name
--- @param text string?
--- @return FontString
function Widgets.Label(parent, font, text)
  local label = parent:CreateFontString(nil, "OVERLAY", font)
  label:SetJustifyH("LEFT")
  label:SetText(text or "")
  return label
end

--- @param parent Frame
--- @param path string
--- @param size number
--- @return Texture
function Widgets.Icon(parent, path, size)
  local icon = parent:CreateTexture(nil, "ARTWORK")
  icon:SetSize(size, size)
  icon:SetTexture(path)
  return icon
end

--- Plays a sound, unless the player turned the addon's sounds off
--- @param name string? One of the addon's own (SOUNDS above), or a key in SOUNDKIT for one of the client's. Ones this client doesn't have are skipped
function Widgets.PlaySound(name)
  if not name or not ForeverGames.db.profile.sound then
    return
  end
  local takes = SOUNDS[name]
  if takes then
    -- Which take is played is nobody's business but the ear's, the client's own dice will do
    PlaySoundFile(SOUND_FILES .. name .. math.random(takes) .. ".ogg", "SFX")
  elseif SOUNDKIT[name] then
    PlaySound(SOUNDKIT[name])
  end
end

--- Makes a region fade in and out to draw the eye. Returns the animation, :Play() and :Stop() it.
--- @param region Region
--- @return AnimationGroup
function Widgets.Pulse(region)
  local group = region:CreateAnimationGroup()
  group:SetLooping("BOUNCE")
  local fade = group:CreateAnimation("Alpha")
  fade:SetFromAlpha(1)
  fade:SetToAlpha(0.25)
  fade:SetDuration(0.7)
  fade:SetSmoothing("IN_OUT")
  return group
end

--- Things that happen over time: a frame's worth of them at once, each with its own start and
--- length. A view starts one for everything it wants to see move, and stops them all when what
--- they were about is no longer what is shown.
--- @param frame Frame Runs them while it is shown. Its OnUpdate is taken
--- @return { Play: fun(self: table, seconds: number, step: fun(progress: number), options: { delay: number?, onStart: fun()?, onDone: fun()? }?), Stop: fun(self: table), Busy: fun(self: table): boolean }
function Widgets.Animator(frame)
  local animator = { running = {} }

  --- @param seconds number How long it takes
  --- @param step fun(progress: number) Called every frame with how far along it is, from 0 to 1. Always called with 1 in the end
  --- @param options { delay: number?, onStart: fun()?, onDone: fun()? }? Seconds to wait first, something to do as it starts and something to do when it is over
  function animator:Play(seconds, step, options)
    options = options or {}
    local run = { seconds = seconds, step = step, elapsed = -(options.delay or 0), onStart = options.onStart, onDone = options.onDone }
    self.running[#self.running + 1] = run
  end

  --- @param run table
  local function start(run)
    if not run.started then
      run.started = true
      if run.onStart then
        run.onStart()
      end
    end
  end

  --- Takes everything to its end at once, in the order it was started
  function animator:Stop()
    -- Whatever one of them starts in ending is ended as well
    while #self.running > 0 do
      local run = table.remove(self.running, 1)
      start(run)
      run.step(1)
      if run.onDone then
        run.onDone()
      end
    end
  end

  --- @return boolean
  function animator:Busy()
    return #self.running > 0
  end

  frame:SetScript("OnUpdate", function(_, elapsed)
    local running = animator.running
    if #running == 0 then
      return
    end
    local over = {}
    -- Only the ones there are now: one that is started on the way begins with the next frame
    for index = 1, #running do
      local run = running[index]
      run.elapsed = run.elapsed + elapsed
      if run.elapsed >= 0 then
        start(run)
        local progress = run.seconds > 0 and math.min(1, run.elapsed / run.seconds) or 1
        run.step(progress)
        if progress >= 1 then
          over[#over + 1] = run
        end
      end
    end
    for _, run in ipairs(over) do
      for index, other in ipairs(running) do
        if other == run then
          table.remove(running, index)
          break
        end
      end
      if run.onDone then
        run.onDone()
      end
    end
  end)
  return animator
end

--- A list that scrolls with the mouse wheel. Rows are built on demand and reused.
--- @param parent Frame
--- @param width number
--- @param rowHeight number
--- @param createRow fun(content: Frame): Frame
--- @return { frame: ScrollFrame, Update: fun(self: table, items: any[], fill: fun(row: Frame, item: any)), ScrollTo: fun(self: table, index: number), SetWidth: fun(self: table, width: number) }
function Widgets.List(parent, width, rowHeight, createRow)
  local scroll = CreateFrame("ScrollFrame", nil, parent)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(width, 1)
  scroll:SetScrollChild(content)
  scroll:EnableMouseWheel(true)

  -- A sliver down the right edge that says there is more, and where in it the list is
  local thumb = scroll:CreateTexture(nil, "OVERLAY")
  thumb:SetColorTexture(1, 1, 1, 0.25)
  thumb:SetWidth(3)
  thumb:Hide()

  local function placeThumb()
    local visible, total = scroll:GetHeight(), content:GetHeight()
    local scrollable = visible > 0 and total > visible + 1
    thumb:SetShown(scrollable)
    if scrollable then
      thumb:SetHeight(math.max(12, visible * visible / total))
      thumb:ClearAllPoints()
      thumb:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 0, -scroll:GetVerticalScroll() / total * visible)
    end
  end

  scroll:SetScript("OnMouseWheel", function(self, delta)
    local furthest = math.max(0, content:GetHeight() - self:GetHeight())
    self:SetVerticalScroll(math.min(furthest, math.max(0, self:GetVerticalScroll() - delta * rowHeight)))
    placeThumb()
  end)
  -- The room the list gets changes with the window
  scroll:SetScript("OnSizeChanged", placeThumb)

  local list = { frame = scroll, rows = {} }

  function list:Update(items, fill)
    for index, item in ipairs(items) do
      local row = self.rows[index]
      if not row then
        row = createRow(content)
        row:SetSize(width, rowHeight)
        row:SetPoint("TOPLEFT", 0, -(index - 1) * rowHeight)
        self.rows[index] = row
      end
      fill(row, item)
      row:Show()
    end
    for index = #items + 1, #self.rows do
      self.rows[index]:Hide()
    end
    content:SetHeight(math.max(1, #items * rowHeight))
    scroll:SetVerticalScroll(math.min(scroll:GetVerticalScroll(), math.max(0, #items * rowHeight - scroll:GetHeight())))
    placeThumb()
  end

  --- Makes the rows this wide from now on, for a list that follows the window
  --- @param newWidth number
  function list:SetWidth(newWidth)
    if newWidth == width then
      return
    end
    width = newWidth
    content:SetWidth(width)
    for _, row in ipairs(self.rows) do
      row:SetWidth(width)
    end
  end

  --- Scrolls just far enough to bring a row into view
  function list:ScrollTo(index)
    local top, visible = scroll:GetVerticalScroll(), scroll:GetHeight()
    local rowTop, rowBottom = (index - 1) * rowHeight, index * rowHeight
    if rowTop < top then
      scroll:SetVerticalScroll(rowTop)
    elseif rowBottom > top + visible then
      scroll:SetVerticalScroll(math.max(0, rowBottom - visible))
    end
    placeThumb()
  end

  return list
end
