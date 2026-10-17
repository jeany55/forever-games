--------------------------
--  How to play
--------------------------
-- The rules of a game, for whoever doesn't know them, laid over what the player was looking at:
-- the board of a game they are in, or the wizard while they set one up. It is what the game says
-- about itself (GameDefinition.howto), a heading at a time, for the rules as they were set: what
-- was changed from the usual comes first, then every section that has something to say for them.
-- It scrolls with the mouse wheel, and closes with its button, with Escape, or with the button
-- that opened it.
--
-- There is one, moved to wherever it is wanted. Whoever opens it hides what it covers for as
-- long as it is open, see MainFrame: a game on the clock stops for it, and nobody plays a board
-- they can't see.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Games = private.Games
local Widgets = private.Widgets

--- @class HowTo
local HowTo = {}
private.HowTo = HowTo

local INSET = 16
local TITLE_HEIGHT = 56
-- No wider than a line is easy to read, however wide the window
local MOST_WIDTH = 600
local HEADING_GAP, SECTION_GAP = 4, 16
local WHEEL_STEP = 40

--- @type Frame?
local panel
-- Called once it is closed, by whoever opened it
--- @type fun()?
local onClose

--- The rules as they were changed from the usual, as a section of their own
--- @param game GameDefinition
--- @param chosen table<string, any>?
--- @param players number?
--- @return { heading: string, text: string }?
local function houseRules(game, chosen, players)
  local lines = Games.DescribeOptions(game, chosen, players)
  if #lines == 0 then
    return nil
  end
  return { heading = L["rules_custom"], text = L["rules_custom_tip"] .. "\n|cffffd100" .. table.concat(lines, "\n") .. "|r" }
end

--- Puts every section under the one before, as wide as there is room for
local function layout()
  -- Before it has been drawn the client may not know yet how wide anchors make it, and text a
  -- point wide shows nothing at all. It is laid out again the moment it does
  local room = panel.scroll:GetWidth() - INSET
  local width = room > 0 and math.min(MOST_WIDTH, room) or MOST_WIDTH
  local y = 0
  for _, part in ipairs(panel.parts) do
    if part.heading:IsShown() then
      part.heading:SetWidth(width)
      part.text:SetWidth(width)
      part.heading:ClearAllPoints()
      part.heading:SetPoint("TOPLEFT", 0, -y)
      y = y + (part.heading:GetStringHeight() or 0) + HEADING_GAP
      part.text:ClearAllPoints()
      part.text:SetPoint("TOPLEFT", 0, -y)
      y = y + (part.text:GetStringHeight() or 0) + SECTION_GAP
    end
  end
  panel.scroll.content:SetSize(width, math.max(1, y))
  panel.scroll:Refresh()
end

local function create()
  panel = Widgets.Panel(UIParent)
  -- Solid, inside the panel's border: what it covers isn't to be read through it
  local fill = panel:CreateTexture(nil, "BACKGROUND")
  fill:SetColorTexture(0.06, 0.06, 0.08, 1)
  fill:SetPoint("TOPLEFT", 1, -1)
  fill:SetPoint("BOTTOMRIGHT", -1, 1)
  panel:EnableMouse(true)
  panel:Hide()
  panel.parts = {}

  panel.icon = Widgets.Icon(panel, private.ICON, 32)
  panel.icon:SetPoint("TOPLEFT", INSET, -12)
  panel.title = Widgets.Label(panel, "GameFontNormalLarge")
  panel.title:SetPoint("LEFT", panel.icon, "RIGHT", 10, 0)

  panel.close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
  panel.close:SetPoint("TOPRIGHT", -4, -4)
  panel.close:SetScript("OnClick", function()
    HowTo.Close()
  end)

  panel.scroll = Widgets.Scroll(panel, WHEEL_STEP)
  panel.scroll:SetPoint("TOPLEFT", INSET, -TITLE_HEIGHT)
  panel.scroll:SetPoint("BOTTOMRIGHT", -INSET + 6, INSET)
  panel.scroll:HookScript("OnSizeChanged", layout)
  -- The wheel scrolls it from anywhere on it, never what lies under it
  panel:EnableMouseWheel(true)
  panel:SetScript("OnMouseWheel", function(_, delta)
    panel.scroll:GetScript("OnMouseWheel")(panel.scroll, delta)
  end)

  -- Escape closes it rather than the whole window. Every other key goes on to wherever it was going
  Widgets.Keys(panel, function(key)
    if key == "ESCAPE" then
      HowTo.Close()
      return true
    end
    return false
  end, true)
end

--- Lays the rules of a game over a frame
--- @param game GameDefinition
--- @param chosen table<string, any>? How the rules were set
--- @param players number? How many are playing, if it is known
--- @param over Frame What it covers
--- @param closed fun()? Called once it is closed, however that comes about
function HowTo.Open(game, chosen, players, over, closed)
  if not panel then
    create()
  end
  if panel:IsShown() then
    HowTo.Close()
  end
  panel:SetParent(over)
  panel:ClearAllPoints()
  panel:SetAllPoints(over)
  -- Over anything a game's view put on top of its own board
  panel:SetFrameLevel(over:GetFrameLevel() + 50)
  panel.icon:SetTexture(game.icon or private.ICON)
  panel.title:SetText(L["howto_title"]:format(game.name))
  panel.game = game

  local sections = Games.HowTo(game, chosen, players)
  local house = houseRules(game, chosen, players)
  if house then
    table.insert(sections, 1, house)
  end
  for index = 1, math.max(#sections, #panel.parts) do
    local part, section = panel.parts[index], sections[index]
    if section and not part then
      part = {
        heading = Widgets.Label(panel.scroll.content, "GameFontNormal"),
        text = Widgets.Label(panel.scroll.content, "GameFontHighlight"),
      }
      part.text:SetSpacing(2)
      panel.parts[index] = part
    end
    if part then
      part.heading:SetShown(section ~= nil)
      part.text:SetShown(section ~= nil)
      part.heading:SetText(section and section.heading or "")
      part.text:SetText(section and section.text or "")
    end
  end
  onClose = closed
  panel.scroll:SetVerticalScroll(0)
  panel:Show()
  layout()
  -- And again once it is on screen, with the room it really has
  panel:SetScript("OnUpdate", function(self)
    self:SetScript("OnUpdate", nil)
    layout()
  end)
end

--- @param game GameDefinition?
--- @return boolean Whether it is open, for this game if one is given
function HowTo.IsOpen(game)
  return panel ~= nil and panel:IsShown() and (game == nil or panel.game == game)
end

--- Puts it away, if it is open
function HowTo.Close()
  if not HowTo.IsOpen() then
    return
  end
  panel:Hide()
  local closed = onClose
  onClose = nil
  if closed then
    closed()
  end
end

--- Whether a game says how it is played
--- @param game GameDefinition?
--- @return boolean
function HowTo.Has(game)
  return game ~= nil and game.howto ~= nil and #game.howto > 0
end
