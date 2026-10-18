--------------------------
--  Options
--------------------------
-- The addon's page in the game's own settings window: how the player is told it is their turn,
-- what they hear, who may challenge them, how the window is drawn and what the cards, the felt,
-- the dice and the dominoes look like. How a game is played is not in here, that is set for each game in the
-- new game wizard.
--
-- Everything on the page is a setting the client keeps for as long as the window is open and
-- reads from and writes to the saved profile through the two functions it is given.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Toast = private.Toast
local MainFrame = private.MainFrame
local Cards = private.Cards
local Felt = private.Felt
local Dice = private.Dice
local Dominoes = private.Dominoes

--- @class Options
local Options = {}
private.Options = Options

-- How big the window can be drawn, in hundredths of its usual size
local SCALE_MIN, SCALE_MAX, SCALE_STEP = 60, 150, 5
-- Who the player takes challenges from, in the order they are offered
local CHALLENGERS = { "anyone", "known" }
-- The looks to choose from are pictures to click on, a row of them for each thing to choose.
-- How much room there is between two pictures, between two rows, and above and below the rows
local THUMB_GAP, ROW_GAP, PICKER_TOP = 6, 10, 8
-- Every picture is as wide as a card back, so that the rows line up and seven of them fit
-- before the window's scroll bar. How tall a card back, a swatch of felt and a die are
local CARD_WIDTH = 40
local CARD_HEIGHT = math.floor(CARD_WIDTH / Cards.RATIO + 0.5)
local FELT_WIDTH, FELT_HEIGHT = CARD_WIDTH, 40
local DIE_SIDE = CARD_WIDTH
-- How much of its picture a die fills (Tools/convert_kenney.py), how big the die is drawn, which
-- is bigger than its place for the room round it to hang over, and the face it shows
local DIE_FILL, DIE_BODY, DIE_FACE = 88 / 128, 34, 5
-- A domino stands in its picture this many pixels wide, showing these pips
local DOMINO_UNIT, DOMINO_HEIGHT, DOMINO_TILE = 24, 56, "36"
-- How tall the card lying on a swatch of felt is, for the swatch's height
local FELT_CARD = 0.6
-- The swatch for each game's own felt is half the one colour games have and half the other
local OWN_FELTS = { "green", "teal" }
-- Where the settings window puts its controls across a row, and their names, from its middle
-- and from its left edge
local CONTROL_X, LABEL_X = -80, 37
-- How far the gold the chosen one lies on reaches round it
local CHOSEN_RIM = 3
local GOLD = { 1, 0.82, 0 }

local category
-- The pickers on the page while it is open, to be shown what was chosen when it changes
local pickers = {}

--- @return table
local function profile()
  return ForeverGames.db.profile
end

--- A setting kept in the saved profile under a name of its own
--- @param key string What it goes by in the profile
--- @param onChange fun(value: any)? What else there is to do when it is changed
--- @return table setting
local function stored(key, onChange)
  local default = ForeverGames.db.defaults.profile[key]
  return Settings.RegisterProxySetting(category, "ForeverGames_" .. key, type(default), L["options_" .. key], default, function()
    return profile()[key]
  end, function(value)
    profile()[key] = value
    if onChange then
      onChange(value)
    end
  end)
end

--- @param title string
local function section(layout, title)
  layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(title))
end

-----------------------------
-- Pickers
-----------------------------
-- What things look like is chosen by clicking on a picture of it: a part of the page of its own,
-- made from a template in GUI/Options.xml as tall as the rows in it, each row of pictures beside
-- its name as every setting has.

--- @class PickerRow
--- @field label string
--- @field setting table What a click sets
--- @field choices string[]
--- @field chosen fun(): string Which of them is chosen now
--- @field value (fun(choice: string): string)? What a click on one sets the setting to, the choice itself if left out
--- @field paint fun(button: Button, choice: string) Draws a choice on its picture, the texture button.picture
--- @field name fun(choice: string): string What it is called, under the cursor
--- @field width number Of each picture
--- @field height number
--- @field inset number? How far in from the picture's edges what it shows begins, for the gold and the light to fit it
--- @field overhang number? How far the picture reaches out of its place, where its edges are clear

--- @param back string
--- @return string design, string colour
local function partsOf(back)
  return back:match("^(%a+)_(%a+)$")
end

--- Shows every picker on the page what is chosen now
local function refreshPickers()
  for each in pairs(pickers) do
    each:Refresh()
  end
end

--- A picture to click on
--- @param frame Frame
--- @param row PickerRow
--- @param onClick fun()
--- @return Button
local function thumbnail(frame, row, onClick)
  local button = CreateFrame("Button", nil, frame)
  button:SetSize(row.width, row.height)
  local inset = row.inset or 0
  -- The chosen one lies on gold the shape of a card, a little bigger than what it shows
  button.chosen = button:CreateTexture(nil, "BACKGROUND")
  button.chosen:SetTexture(Cards.BLANK)
  button.chosen:SetVertexColor(unpack(GOLD))
  button.chosen:SetPoint("TOPLEFT", inset - CHOSEN_RIM, CHOSEN_RIM - inset)
  button.chosen:SetPoint("BOTTOMRIGHT", CHOSEN_RIM - inset, inset - CHOSEN_RIM)
  button.picture = button:CreateTexture(nil, "ARTWORK")
  local overhang = row.overhang or 0
  button.picture:SetPoint("TOPLEFT", -overhang, overhang)
  button.picture:SetPoint("BOTTOMRIGHT", overhang, -overhang)
  local hover = button:CreateTexture(nil, "HIGHLIGHT")
  hover:SetPoint("TOPLEFT", inset, -inset)
  hover:SetPoint("BOTTOMRIGHT", -inset, inset)
  hover:SetTexture(Cards.BLANK)
  hover:SetBlendMode("ADD")
  hover:SetAlpha(0.25)
  button:SetScript("OnClick", onClick)
  button:SetScript("OnEnter", function()
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    GameTooltip:SetText(button.name)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", GameTooltip_Hide)
  return button
end

--- What a picker on the page does, for the templates in GUI/Options.xml
ForeverGamesPickerMixin = {}

--- Called by the settings window each time it shows the picker
--- @param initializer table
function ForeverGamesPickerMixin:Init(initializer)
  if not self.rows then
    self.rows, self.buttons = initializer:GetData().rows, {}
    local top = -PICKER_TOP
    for index, row in ipairs(self.rows) do
      local text = self:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      text:SetPoint("LEFT", self, "TOPLEFT", LABEL_X, top - row.height / 2)
      text:SetText(row.label)
      self.buttons[index] = {}
      for column, choice in ipairs(row.choices) do
        local button = thumbnail(self, row, function()
          row.setting:SetValue(row.value and row.value(choice) or choice)
        end)
        button:SetPoint("TOPLEFT", self, "TOP", CONTROL_X + (column - 1) * (row.width + THUMB_GAP), top)
        self.buttons[index][column] = button
      end
      top = top - row.height - ROW_GAP
    end
  end
  pickers[self] = true
  self:Refresh()
end

--- Called by the settings window when it is done with the picker for now
function ForeverGamesPickerMixin:Release()
  pickers[self] = nil
end

--- Draws every choice, the chosen ones on gold
function ForeverGamesPickerMixin:Refresh()
  for index, row in ipairs(self.rows) do
    local chosen = row.chosen()
    for column, choice in ipairs(row.choices) do
      local button = self.buttons[index][column]
      row.paint(button, choice)
      button.chosen:SetShown(choice == chosen)
      button.name = row.name(choice)
    end
  end
end

--- Puts a picker on the page, where the client has a way to put a part of one's own on it
--- @param layout table
--- @param template string Of GUI/Options.xml, as tall as the rows
--- @param rows PickerRow[]
--- @param ... string Words to find it by in the window's search
local function addPicker(layout, template, rows, ...)
  local initializer = Settings.CreateElementInitializer(template, { rows = rows })
  local height = 2 * PICKER_TOP + ROW_GAP * (#rows - 1)
  for _, row in ipairs(rows) do
    height = height + row.height
  end
  -- As tall as the template, said again in case the window asks the picker instead
  function initializer:GetExtent()
    return height
  end
  if initializer.AddSearchTags then
    initializer:AddSearchTags(...)
  end
  layout:AddInitializer(initializer)
end

--- @param colour string
--- @return string
local function colourName(colour)
  return L["options_colour_" .. colour]
end

--- The back of the cards: each design in the colour chosen, and the design chosen in each colour
--- @param layout table
local function cardBacks(layout)
  local setting = stored("cardBack", function(value)
    Cards.SetBack(value)
    refreshPickers()
  end)
  local function design()
    return (partsOf(Cards.Back()))
  end
  local function colour()
    return select(2, partsOf(Cards.Back()))
  end
  section(layout, L["options_cards"])
  addPicker(layout, "ForeverGamesCardBackTemplate", {
    {
      label = L["options_cardBack_design"],
      setting = setting,
      choices = Cards.BACK_DESIGNS,
      chosen = design,
      value = function(choice)
        return choice .. "_" .. colour()
      end,
      paint = function(button, choice)
        button.picture:SetTexture(Cards.BackTexture(choice .. "_" .. colour()))
      end,
      name = function(choice)
        return L["options_cardBack_" .. choice]
      end,
      width = CARD_WIDTH,
      height = CARD_HEIGHT,
    },
    {
      label = L["options_cardBack_colour"],
      setting = setting,
      choices = Cards.BACK_COLOURS,
      chosen = colour,
      value = function(choice)
        return design() .. "_" .. choice
      end,
      paint = function(button, choice)
        button.picture:SetTexture(Cards.BackTexture(design() .. "_" .. choice))
      end,
      name = colourName,
      width = CARD_WIDTH,
      height = CARD_HEIGHT,
    },
  }, L["options_cardBack"], L["options_cards"])
end

--- A swatch of felt with a card lying on it, the felt of each game half one colour and half another
--- @param button Button
--- @param colour string
local function paintFelt(button, colour)
  if not button.half then
    button.half = button:CreateTexture(nil, "ARTWORK", nil, 1)
    button.half:SetTexture(Cards.BLANK)
    button.half:SetTexCoord(0.5, 1, 0, 1)
    button.half:SetPoint("TOPRIGHT")
    button.half:SetPoint("BOTTOMRIGHT")
    button.half:SetWidth(FELT_WIDTH / 2)
    button.card = button:CreateTexture(nil, "ARTWORK", nil, 2)
    button.card:SetSize(FELT_HEIGHT * FELT_CARD * Cards.RATIO, FELT_HEIGHT * FELT_CARD)
    button.card:SetPoint("CENTER")
  end
  local own = colour == Felt.OWN
  button.picture:SetTexture(Cards.BLANK)
  button.picture:SetVertexColor(unpack(Felt.RGB[own and OWN_FELTS[1] or colour]))
  button.half:SetVertexColor(unpack(Felt.RGB[OWN_FELTS[2]]))
  button.half:SetShown(own)
  button.card:SetTexture(Cards.BackTexture(Cards.Back()))
end

--- What the table is covered with, the colour of the dice on it that stand for nobody, and what
--- the dominoes are made of
--- @param layout table
local function tableLooks(layout)
  section(layout, L["options_table"])
  addPicker(layout, "ForeverGamesTableTemplate", {
    {
      label = L["options_feltColour"],
      setting = stored("feltColour", function(value)
        Felt.SetColour(value)
        refreshPickers()
      end),
      choices = Felt.COLOURS,
      chosen = Felt.Colour,
      paint = paintFelt,
      name = function(choice)
        return choice == Felt.OWN and L["options_feltColour_own"] or colourName(choice)
      end,
      width = FELT_WIDTH,
      height = FELT_HEIGHT,
    },
    {
      label = L["options_diceColour"],
      setting = stored("diceColour", function(value)
        Dice.SetColour(value)
        refreshPickers()
      end),
      choices = Dice.COLOURS,
      chosen = Dice.Colour,
      paint = function(button, choice)
        button.picture:SetTexture(Dice.Texture(choice, DIE_FACE))
      end,
      name = colourName,
      width = DIE_SIDE,
      height = DIE_SIDE,
      inset = (DIE_SIDE - DIE_BODY) / 2,
      overhang = (DIE_BODY / DIE_FILL - DIE_SIDE) / 2,
    },
    {
      label = L["options_dominoStyle"],
      setting = stored("dominoStyle", function(value)
        Dominoes.SetStyle(value)
        refreshPickers()
      end),
      choices = Dominoes.STYLES,
      chosen = Dominoes.Style,
      paint = function(button, choice)
        if not button.domino then
          -- Standing in the middle of its place, made of what it would be
          button.domino = Dominoes.New(button)
          button.domino.frame:EnableMouse(false)
        end
        button.domino:Set(DOMINO_TILE, choice)
        button.domino:Place(CARD_WIDTH / 2, DOMINO_HEIGHT / 2, DOMINO_UNIT, math.pi / 2)
      end,
      name = function(choice)
        return L["options_dominoStyle_" .. choice]
      end,
      width = CARD_WIDTH,
      height = DOMINO_HEIGHT,
    },
  }, L["options_feltColour"], L["options_diceColour"], L["options_dominoStyle"], L["options_table"])
end

--- Builds the page. Does nothing on a client that has no settings window to put it in
function Options.Init()
  if category or not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterProxySetting) then
    return
  end
  local layout
  category, layout = Settings.RegisterVerticalLayoutCategory(L["title"])

  section(layout, L["options_notifications"])
  Settings.CreateCheckbox(category, stored("toasts"), L["options_toasts_tip"])
  Settings.CreateCheckbox(category, stored("alert"), L["options_alert_tip"])
  -- What was held back for as long as these said to has waited long enough
  Settings.CreateCheckbox(category, stored("combat", Toast.Release), L["options_combat_tip"])
  Settings.CreateCheckbox(category, stored("quiet", Toast.Release), L["options_quiet_tip"])

  section(layout, L["options_sounds"])
  Settings.CreateCheckbox(category, stored("sound"), L["options_sound_tip"])

  section(layout, L["options_challengers"])
  local createDropdown = Settings.CreateDropdown or Settings.CreateDropDown
  createDropdown(category, stored("challenges"), function()
    local container = Settings.CreateControlTextContainer()
    for _, who in ipairs(CHALLENGERS) do
      container:Add(who, L["options_challenges_" .. who])
    end
    return container:GetData()
  end, L["options_challenges_tip"])

  section(layout, L["options_window"])
  -- The profile says whether the button is hidden, the page asks whether it is shown
  local minimap = Settings.RegisterProxySetting(category, "ForeverGames_minimap", "boolean", L["options_minimap"], true, function()
    return not profile().minimap.hide
  end, function(value)
    profile().minimap.hide = not value
    local icon = LibStub("LibDBIcon-1.0")
    if value then
      icon:Show(private.ADDON_NAME)
    else
      icon:Hide(private.ADDON_NAME)
    end
  end)
  Settings.CreateCheckbox(category, minimap, L["options_minimap_tip"])
  Settings.CreateCheckbox(category, stored("wisp", MainFrame.Refresh), L["options_wisp_tip"])

  local usualScale = ForeverGames.db.defaults.profile.window.scale
  local scale = Settings.RegisterProxySetting(category, "ForeverGames_scale", "number", L["options_scale"], usualScale, function()
    return profile().window.scale
  end, function(value)
    profile().window.scale = value
    MainFrame.ApplyScale()
  end)
  local slider = Settings.CreateSliderOptions(SCALE_MIN, SCALE_MAX, SCALE_STEP)
  slider:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
    return L["options_scale_label"]:format(value)
  end)
  Settings.CreateSlider(category, scale, slider, L["options_scale_tip"])

  layout:AddInitializer(CreateSettingsButtonInitializer(L["options_reset"], L["options_reset_button"], MainFrame.ResetWindow, L["options_reset_tip"], true))

  -- What things look like, where the client has a way to show the pictures to choose from
  if Settings.CreateElementInitializer then
    cardBacks(layout)
    tableLooks(layout)
  end

  Settings.RegisterAddOnCategory(category)
end

--- Opens the settings window on the addon's page
--- @return boolean, string? error
function Options.Open()
  if not category then
    return false, "no_options"
  end
  -- The client doesn't let an addon open its settings in the middle of a fight
  if InCombatLockdown() then
    return false, "options_combat"
  end
  Settings.OpenToCategory(category:GetID())
  return true
end
