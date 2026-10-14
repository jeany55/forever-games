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
Widgets.RED = { 1, 0.3, 0.25 }

-- A plain, round font the addon brings along, easy on the eyes in lower case (Fonts/)
Widgets.LEXEND = "Interface\\AddOns\\ForeverGames\\Fonts\\Lexend-SemiBold.ttf"

--- Writes a text in Lexend. The client's own font is set first: a text told to use a font the
--- client can't find, as it can't one that was added while it was running, keeps the one it had
--- @param text FontString
--- @param size number
--- @param flags string?
function Widgets.Lexend(text, size, flags)
  text:SetFont(STANDARD_TEXT_FONT, size, flags or "")
  text:SetFont(Widgets.LEXEND, size, flags or "")
end

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

-- Where a picture cut in nine is cut, the same both ways: a quarter of it at each edge
local CUTS = { 0, 0.25, 0.75, 1 }

--- @class Slices
--- @field pieces Texture[] The nine, row by row from the top left

--- A picture cut in nine like a window pane and laid over a frame: its corners keep their size and
--- the edges and the middle stretch, so something with round corners stays round however wide or
--- tall the frame is. The picture keeps a quarter of its side at each edge from stretching
--- @param frame Frame
--- @param file string
--- @param layer string? Draw layer, ARTWORK if left out
--- @param sublevel number?
--- @param options { x: number?, y: number?, grow: number? }? How far it is moved from the frame, and how much larger than it it is drawn all round
--- @return Slices
function Widgets.Slices(frame, file, layer, sublevel, options)
  options = options or {}
  local x, y, grow = options.x or 0, options.y or 0, options.grow or 0
  local slices, pieces = {}, {}
  for row = 1, 3 do
    for column = 1, 3 do
      local piece = frame:CreateTexture(nil, layer or "ARTWORK", nil, sublevel)
      piece:SetTexture(file)
      piece:SetTexCoord(CUTS[column], CUTS[column + 1], CUTS[row], CUTS[row + 1])
      pieces[#pieces + 1] = piece
    end
  end
  local topLeft, top, topRight, left, middle, right, bottomLeft, bottom, bottomRight = unpack(pieces)
  topLeft:SetPoint("TOPLEFT", frame, "TOPLEFT", x - grow, y + grow)
  topRight:SetPoint("TOPRIGHT", frame, "TOPRIGHT", x + grow, y + grow)
  bottomLeft:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", x - grow, y - grow)
  bottomRight:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", x + grow, y - grow)
  -- Each of the others fills what lies between two of the corners
  for _, between in ipairs({
    { top, topLeft, "TOPRIGHT", topRight, "BOTTOMLEFT" },
    { left, topLeft, "BOTTOMLEFT", bottomLeft, "TOPRIGHT" },
    { right, topRight, "BOTTOMLEFT", bottomRight, "TOPRIGHT" },
    { bottom, bottomLeft, "TOPRIGHT", bottomRight, "BOTTOMLEFT" },
    { middle, topLeft, "BOTTOMRIGHT", bottomRight, "TOPLEFT" },
  }) do
    local piece, from, fromPoint, to, toPoint = unpack(between)
    piece:SetPoint("TOPLEFT", from, fromPoint)
    piece:SetPoint("BOTTOMRIGHT", to, toPoint)
  end
  slices.pieces = pieces

  --- How large the corners are drawn
  --- @param size number
  function slices:SetCorner(size)
    for _, corner in ipairs({ topLeft, topRight, bottomLeft, bottomRight }) do
      corner:SetSize(size, size)
    end
  end

  --- @param red number
  --- @param green number
  --- @param blue number
  --- @param alpha number?
  function slices:SetVertexColor(red, green, blue, alpha)
    for _, piece in ipairs(pieces) do
      piece:SetVertexColor(red, green, blue, alpha or 1)
    end
  end

  --- @param shown boolean
  function slices:SetShown(shown)
    for _, piece in ipairs(pieces) do
      piece:SetShown(shown)
    end
  end

  --- @param mode string
  function slices:SetBlendMode(mode)
    for _, piece in ipairs(pieces) do
      piece:SetBlendMode(mode)
    end
  end

  slices:SetCorner(8)
  return slices
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

--- How something gets from where it was to where it is going: each takes how far along in time
--- it is, from 0 to 1, and says how far along the way. Give one to an Animator as `ease`.
Widgets.Ease = {
  --- Fast at first, settling at the end: for whatever arrives somewhere
  --- @param progress number
  --- @return number
  out = function(progress)
    return 1 - (1 - progress) ^ 3
  end,
  --- Slow at first: for whatever leaves or falls
  into = function(progress)
    return progress ^ 2
  end,
  --- Slow at both ends: for whatever only changes place
  inOut = function(progress)
    return progress < 0.5 and 4 * progress ^ 3 or 1 - (-2 * progress + 2) ^ 3 / 2
  end,
  --- A little past the end and back: for whatever is put down or pops up
  back = function(progress)
    local over = 1.70158
    return 1 + (over + 1) * (progress - 1) ^ 3 + over * (progress - 1) ^ 2
  end,
  --- There and back again, ending where it began: for a swell or a nudge. Not a way to get anywhere
  swell = function(progress)
    return math.sin(progress * math.pi)
  end,
}

--- Seconds as a clock shows them: "0:07", "12:34", "1:02:03"
--- @param seconds number
--- @return string
function Widgets.Time(seconds)
  local whole = math.max(0, math.floor(seconds))
  local hours, minutes = math.floor(whole / 3600), math.floor(whole / 60) % 60
  if hours > 0 then
    return string.format("%d:%02d:%02d", hours, minutes, whole % 60)
  end
  return string.format("%d:%02d", minutes, whole % 60)
end

--- Things that happen over time: a frame's worth of them at once, each with its own start and
--- length. A view starts one for everything it wants to see move, and stops them all when what
--- they were about is no longer what is shown.
--- @param frame Frame Runs them while it is shown. Its OnUpdate is taken
--- @return { Play: fun(self: table, seconds: number, step: fun(progress: number), options: { delay: number?, ease: (fun(progress: number): number)?, onStart: fun()?, onDone: fun()? }?), Stop: fun(self: table), Busy: fun(self: table): boolean }
function Widgets.Animator(frame)
  local animator = { running = {} }

  --- @param seconds number How long it takes
  --- @param step fun(progress: number) Called every frame with how far along it is, from 0 to 1. Always called with 1 in the end
  --- @param options { delay: number?, ease: (fun(progress: number): number)?, onStart: fun()?, onDone: fun()? }? Seconds to wait first, how it gets there (Widgets.Ease, evenly if left out), something to do as it starts and something to do when it is over
  function animator:Play(seconds, step, options)
    options = options or {}
    local ease = options.ease
    if ease then
      local plain = step
      step = function(progress)
        plain(ease(progress))
      end
    end
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

--- Lets a frame take keys: the arrows for a game that is played with them, the digits for one
--- that has numbers written into it. Only while the cursor is over the frame, so that a window
--- left open doesn't keep the player from steering their character, and never in combat, where
--- the client doesn't let an addon decide key by key what it keeps: every key then does what it
--- always does.
--- @param frame Frame Its OnKeyDown and OnEvent are taken
--- @param onKey fun(key: string): boolean? What to do with a key, by the client's name for it ("LEFT", "A", "1", "BACKSPACE"). Returns true for a key it used, any other goes on to do what it usually does
function Widgets.Keys(frame, onKey)
  frame:SetScript("OnKeyDown", function(self, key)
    if InCombatLockdown() then
      return
    end
    local used = self:IsMouseOver() and onKey(key) == true
    self:SetPropagateKeyboardInput(not used)
  end)
  -- Going into combat is the last moment the frame may still be told to let every key through
  frame:RegisterEvent("PLAYER_REGEN_DISABLED")
  frame:RegisterEvent("PLAYER_REGEN_ENABLED")
  frame:SetScript("OnEvent", function(self, event)
    -- Neither is in combat yet, or any more
    self:SetPropagateKeyboardInput(true)
    self:EnableKeyboard(event == "PLAYER_REGEN_ENABLED")
  end)
  if not InCombatLockdown() then
    frame:SetPropagateKeyboardInput(true)
    frame:EnableKeyboard(true)
  end
end

--- A number with a word over it, for what a game keeps count of: a score, a time, how many are
--- left. It swells for a moment when it is told something else, so a change is seen.
--- @param parent Frame
--- @param title string
--- @param width number
--- @param height number? 38 if left out
--- @return Frame stat Set(text, quiet) changes what it says, without the swell if quiet. SetTitle(text) changes the word, Tint(color) the colour of the number
function Widgets.Stat(parent, title, width, height)
  local stat = Widgets.Panel(parent)
  stat:SetSize(width, height or 38)
  local caption = stat:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  caption:SetPoint("TOP", 0, -4)
  caption:SetText(title)
  local value = stat:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  value:SetPoint("BOTTOM", 0, 5)
  stat.caption, stat.value = caption, value

  local swell = value:CreateAnimationGroup()
  for order, scale in ipairs({ 1.25, 0.8 }) do
    local grow = swell:CreateAnimation("Scale")
    grow:SetOrder(order)
    grow:SetDuration(order == 1 and 0.08 or 0.16)
    grow:SetScale(scale, scale)
    grow:SetSmoothing(order == 1 and "OUT" or "IN")
  end

  --- @param text string|number
  --- @param quiet boolean? Don't draw the eye to it
  function stat:Set(text, quiet)
    text = tostring(text)
    if text == self.shown then
      return
    end
    local first = self.shown == nil
    self.shown = text
    value:SetText(text)
    if not quiet and not first then
      swell:Stop()
      swell:Play()
    end
  end

  --- @param text string
  function stat:SetTitle(text)
    caption:SetText(text)
  end

  --- @param color number[]? White if left out
  function stat:Tint(color)
    value:SetTextColor(unpack(color or { 1, 1, 1 }))
  end

  return stat
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
