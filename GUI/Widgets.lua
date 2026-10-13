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

--- Plays one of the client's interface sounds, unless the player turned the addon's sounds off
--- @param name string? Key in SOUNDKIT. Ones this client doesn't have are skipped
function Widgets.PlaySound(name)
  local kit = name and SOUNDKIT[name]
  if kit and ForeverGames.db.profile.sound then
    PlaySound(kit)
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

--- A list that scrolls with the mouse wheel. Rows are built on demand and reused.
--- @param parent Frame
--- @param width number
--- @param rowHeight number
--- @param createRow fun(content: Frame): Frame
--- @return { frame: ScrollFrame, Update: fun(self: table, items: any[], fill: fun(row: Frame, item: any)), ScrollTo: fun(self: table, index: number) }
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
