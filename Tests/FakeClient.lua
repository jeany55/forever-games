-- A stand-in for the game client's widget API, just enough of it to run the GUI code from the
-- terminal. Nothing is drawn: a widget remembers its size, whether it is shown, its text and its
-- script handlers, and shrugs off every other call. That is enough to click through the window
-- and catch the mistakes a typo or a wrong assumption about the engine would cause, it says
-- nothing about how any of it looks.

local Client = { cursor = { 0, 0 }, mouseDown = false, combat = false, over = true, sounds = {}, widgets = {} }

local Widget = {}

local function newWidget(kind, parent)
  local widget = { kind = kind, parent = parent, scripts = {}, shown = true, width = 0, height = 0, scroll = 0 }
  setmetatable(widget, Widget)
  Client.widgets[#Client.widgets + 1] = widget
  return widget
end

local methods = {}

-- The client has a frame take the mouse as soon as it is given something to do with it
local MOUSE_SCRIPTS = { OnMouseDown = true, OnMouseUp = true, OnEnter = true, OnLeave = true }

function methods:SetScript(name, handler)
  self.scripts[name] = handler
  if handler and MOUSE_SCRIPTS[name] then
    self.mouse = true
  end
end

function methods:EnableMouse(enabled)
  self.mouse = enabled and true or false
end

function methods:IsMouseEnabled()
  return self.mouse == true
end

function methods:GetScript(name)
  return self.scripts[name]
end

--- Runs a script handler the way the client would
function methods:Fire(name, ...)
  local handler = self.scripts[name]
  if handler then
    handler(self, ...)
  end
end

function methods:SetSize(width, height)
  local changed = width ~= self.width or height ~= self.height
  self.width, self.height = width, height
  if changed then
    self:Fire("OnSizeChanged", width, height)
  end
end

function methods:SetWidth(width)
  self.width = width
end

function methods:SetHeight(height)
  self.height = height
end

function methods:GetWidth()
  return self.width
end

function methods:GetHeight()
  return self.height
end

-- Every widget sits with its bottom left corner in the bottom left of the screen
function methods:GetLeft()
  return 0
end

function methods:GetTop()
  return self.height
end

function methods:GetBottom()
  return 0
end

function methods:GetCenter()
  return self.width / 2, self.height / 2
end

-- Where a widget was put is remembered the way it was said: every SetPoint since the last
-- ClearAllPoints, as what it was called with
function methods:SetPoint(...)
  self.anchors = self.anchors or {}
  self.anchors[#self.anchors + 1] = { ... }
end

function methods:ClearAllPoints()
  self.anchors = nil
end

function methods:SetScale(scale)
  self.scale = scale
end

function methods:SetAlpha(alpha)
  self.alpha = alpha
end

function methods:GetAlpha()
  return self.alpha or 1
end

function methods:GetEffectiveScale()
  return 1
end

function methods:GetFrameLevel()
  return 1
end

function methods:Show()
  self:SetShown(true)
end

function methods:Hide()
  self:SetShown(false)
end

function methods:SetShown(shown)
  shown = shown and true or false
  if shown ~= self.shown then
    self.shown = shown
    self:Fire(shown and "OnShow" or "OnHide")
  end
end

function methods:IsShown()
  return self.shown
end

--- Whether the widget and everything it sits in is shown
function methods:IsVisible()
  local widget = self
  while widget do
    if not widget.shown then
      return false
    end
    widget = widget.parent
  end
  return true
end

--- The cursor is over every widget there is, or with Client.over unset over none of them
function methods:IsMouseOver()
  return Client.over
end

function methods:SetPropagateKeyboardInput(propagate)
  self.propagates = propagate
end

function methods:EnableKeyboard(enabled)
  self.keyboard = enabled
end

function methods:SetText(text)
  self.text = text
end

function methods:GetText()
  return self.text
end

function methods:GetStringWidth()
  return #(self.text or "") * 6
end

function methods:SetTexture(texture)
  self.texture = texture
end

function methods:SetEnabled(enabled)
  self.enabled = enabled
end

function methods:SetVertexColor(red, green, blue, alpha)
  self.color = { red, green, blue, alpha or 1 }
end

function methods:GetVertexColor()
  return unpack(self.color or { 1, 1, 1, 1 })
end

function methods:SetVerticalScroll(scroll)
  self.scroll = scroll
end

function methods:GetVerticalScroll()
  return self.scroll
end

for _, name in ipairs({ "CreateTexture", "CreateFontString", "CreateAnimationGroup", "CreateAnimation", "CreateLine" }) do
  methods[name] = function(self)
    return newWidget(name:sub(7), self)
  end
end

local function ignore() end

function Widget:__index(key)
  -- The client's methods start with a capital, anything else is a field the addon hasn't set
  if methods[key] or (type(key) == "string" and key:match("^%u")) then
    return methods[key] or ignore
  end
  return nil
end

--- Defines the globals the addon expects from the client
function Client.Install()
  Client.widgets, Client.sounds = {}, {}
  Client.cursor, Client.mouseDown = { 0, 0 }, false
  Client.combat, Client.over = false, true

  function InCombatLockdown()
    return Client.combat
  end

  function CreateFrame(kind, name, parent, template)
    local frame = newWidget(kind, parent)
    if name then
      _G[name] = frame
    end
    if template == "BasicFrameTemplateWithInset" then
      frame.TitleText = newWidget("FontString", frame)
    end
    return frame
  end

  UIParent = newWidget("Frame")
  GameTooltip = newWidget("GameTooltip")
  GameTooltip_Hide = ignore
  UISpecialFrames, StaticPopupDialogs = {}, {}
  StaticPopup_Show = ignore
  STANDARD_TEXT_FONT, YES, NO = "font", "Yes", "No"
  SOUNDKIT = setmetatable({}, {
    __index = function(_, key)
      return key
    end,
  })

  function PlaySound(kit)
    Client.sounds[#Client.sounds + 1] = kit
  end

  -- One of the addon's own sounds: remembered by what it is, whichever take was played
  function PlaySoundFile(path)
    Client.sounds[#Client.sounds + 1] = path:match("([%a]+)%d*%.ogg$")
  end

  function GetCursorPosition()
    return Client.cursor[1], Client.cursor[2]
  end

  function IsMouseButtonDown()
    return Client.mouseDown
  end

  function GetScreenWidth()
    return 1920
  end

  function GetScreenHeight()
    return 1080
  end

  function GetPhysicalScreenSize()
    return 1920, 1080
  end
end

--- Every widget for which a test returns true, in the order they were made
--- @param test fun(widget: table): boolean?
--- @return table[]
function Client.Find(test)
  local found = {}
  for _, widget in ipairs(Client.widgets) do
    if test(widget) then
      found[#found + 1] = widget
    end
  end
  return found
end

--- The one visible button showing a text
--- @param text string
--- @return table
function Client.Button(text)
  local found = Client.Find(function(widget)
    return widget.kind == "Button" and widget.text == text and widget:IsVisible()
  end)
  assert(#found == 1, "Expected one visible button saying " .. text .. ", found " .. #found)
  return found[1]
end

return Client
