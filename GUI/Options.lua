--------------------------
--  Options
--------------------------
-- The addon's page in the game's own settings window: how the player is told it is their turn,
-- what they hear, who may challenge them, how the window is drawn and what the cards, the felt,
-- the dice and the dominoes look like. How a game is played is not in here, that is set for each
-- game in the new game wizard.
--
-- The page is a frame of the addon's own that the settings window shows as it is (a canvas), not
-- settings put into the window's own list. That list is shared: its rows are used again for the
-- client's settings, and its search mixes everyone's together. Rows that had shown an addon's
-- settings carried the addon's taint into the client's own, and the client blocked what only it
-- may do there (searching the settings brought up "ForeverGames has been blocked from an action
-- only available to the Blizzard UI"). Nothing of the page's is ever in that list now, and it
-- isn't searched.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Toast = private.Toast
local MainFrame = private.MainFrame
local Widgets = private.Widgets
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
-- Where a row's control begins, from the middle of the page, and its name, from the left edge:
-- where the settings window puts its own
local CONTROL_X, LABEL_X = -80, 37
-- How tall a row is, a section's heading, and the page's title above them all
local ROW_HEIGHT, SECTION_HEIGHT, TITLE_HEIGHT = 30, 44, 50
-- How wide the dropdown and the slider are, and the reset button
local CONTROL_WIDTH, BUTTON_WIDTH = 200, 120
-- How far a turn of the mouse wheel scrolls the page
local WHEEL_STEP = 40
-- How far the gold the chosen one lies on reaches round it
local CHOSEN_RIM = 3
local GOLD = { 1, 0.82, 0 }
-- The client's own pictures for a box to tick and for the bar a slider runs along
local CHECK_TEXTURES = {
  normal = "Interface\\Buttons\\UI-CheckBox-Up",
  pushed = "Interface\\Buttons\\UI-CheckBox-Down",
  highlight = "Interface\\Buttons\\UI-CheckBox-Highlight",
  checked = "Interface\\Buttons\\UI-CheckBox-Check",
}
local SLIDER_THUMB = "Interface\\Buttons\\UI-SliderBar-Button-Horizontal"

-- The page, and what the settings window knows it by
local panel, category
-- Every setting on the page, for the window's Defaults button
local settings = {}
-- What shows each setting's value, to show it again when it changes or the page is shown
local refreshers = {}

--- @return table
local function profile()
  return ForeverGames.db.profile
end

--- What a control on the page sets: a value with its usual one, read and written through the two
--- functions it is given
--- @class OptionSetting
--- @field default any
--- @field GetValue fun(self: OptionSetting): any
--- @field SetValue fun(self: OptionSetting, value: any)

--- @param default any
--- @param get fun(): any
--- @param set fun(value: any)
--- @return OptionSetting
local function setting(default, get, set)
  local made = {
    default = default,
    GetValue = function()
      return get()
    end,
    SetValue = function(_, value)
      set(value)
    end,
  }
  settings[#settings + 1] = made
  return made
end

--- A setting kept in the saved profile under a name of its own
--- @param key string What it goes by in the profile
--- @param onChange fun(value: any)? What else there is to do when it is changed
--- @return OptionSetting
local function stored(key, onChange)
  return setting(ForeverGames.db.defaults.profile[key], function()
    return profile()[key]
  end, function(value)
    profile()[key] = value
    if onChange then
      onChange(value)
    end
  end)
end

--- Shows every control on the page what its setting is now
local function refresh()
  for _, each in ipairs(refreshers) do
    each()
  end
end

-----------------------------
-- The page
-----------------------------
-- Everything is put down the page one after the other, each row as wide as the page, its name on
-- the left and what changes it from the middle.

--- @class OptionsPage
--- @field content Frame What the rows are put in, inside the part that scrolls
--- @field top number How far down the page the next row goes
local page = {}

--- The name and what it is for, under the cursor
--- @param owner Frame
--- @param title string
--- @param tip string?
local function explain(owner, title, tip)
  owner:SetScript("OnEnter", function()
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText(title)
    if tip then
      GameTooltip:AddLine(tip, 1, 1, 1, true)
    end
    GameTooltip:Show()
  end)
  owner:SetScript("OnLeave", GameTooltip_Hide)
end

--- A row of the page, as tall as it says, with a name on the left
--- @param height number
--- @param label string?
--- @param tip string?
--- @return Frame row
local function row(height, label, tip)
  local frame = CreateFrame("Frame", nil, page.content)
  frame:SetPoint("TOPLEFT", page.content, "TOPLEFT", 0, -page.top)
  frame:SetPoint("TOPRIGHT", page.content, "TOPRIGHT", 0, -page.top)
  frame:SetHeight(height)
  page.top = page.top + height
  if label then
    frame.label = Widgets.Label(frame, "GameFontNormal", label)
    frame.label:SetPoint("LEFT", frame, "LEFT", LABEL_X, 0)
    explain(frame, label, tip)
  end
  return frame
end

--- A section's heading
--- @param title string
local function section(title)
  local frame = row(SECTION_HEIGHT)
  local text = Widgets.Label(frame, "GameFontHighlightLarge", title)
  text:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", LABEL_X - 30, 8)
  local line = frame:CreateTexture(nil, "ARTWORK")
  line:SetColorTexture(1, 1, 1, 0.15)
  line:SetHeight(1)
  line:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", LABEL_X - 30, 2)
  line:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -20, 2)
end

--- A box to tick, for a setting that is on or off
--- @param value OptionSetting
--- @param label string
--- @param tip string?
--- @return CheckButton
local function checkbox(value, label, tip)
  local frame = row(ROW_HEIGHT, label, tip)
  local check = CreateFrame("CheckButton", nil, frame)
  check:SetSize(26, 26)
  check:SetPoint("LEFT", frame, "CENTER", CONTROL_X, 0)
  check:SetNormalTexture(CHECK_TEXTURES.normal)
  check:SetPushedTexture(CHECK_TEXTURES.pushed)
  check:SetHighlightTexture(CHECK_TEXTURES.highlight, "ADD")
  check:SetCheckedTexture(CHECK_TEXTURES.checked)
  check:SetScript("OnClick", function(self)
    local on = not value:GetValue()
    value:SetValue(on)
    self:SetChecked(on)
  end)
  explain(check, label, tip)
  refreshers[#refreshers + 1] = function()
    check:SetChecked(value:GetValue() == true)
  end
  frame.control = check
  return check
end

--- A choice of a few things, named
--- @param value OptionSetting
--- @param choices { value: any, text: string }[]
--- @param label string
--- @param tip string?
--- @return Button
local function dropdown(value, choices, label, tip)
  local frame = row(ROW_HEIGHT, label, tip)
  local menu = Widgets.Dropdown(frame, 22)
  menu:SetWidth(CONTROL_WIDTH)
  menu:SetPoint("LEFT", frame, "CENTER", CONTROL_X + 4, 0)
  refreshers[#refreshers + 1] = function()
    local list = {}
    for index, choice in ipairs(choices) do
      list[index] = {
        text = choice.text,
        on = value:GetValue() == choice.value,
        pick = function()
          value:SetValue(choice.value)
        end,
      }
    end
    menu:SetChoices(list, refresh)
  end
  frame.control = menu
  return menu
end

--- A number along a bar, from the least it can be to the most, by steps
--- @param value OptionSetting
--- @param least number
--- @param most number
--- @param step number
--- @param show fun(value: number): string How it is written beside the bar
--- @param label string
--- @param tip string?
--- @return Slider
local function slider(value, least, most, step, show, label, tip)
  local frame = row(ROW_HEIGHT, label, tip)
  local bar = CreateFrame("Slider", nil, frame)
  bar:SetOrientation("HORIZONTAL")
  bar:SetSize(CONTROL_WIDTH - 50, 18)
  bar:SetPoint("LEFT", frame, "CENTER", CONTROL_X + 8, 0)
  bar:SetMinMaxValues(least, most)
  bar:SetValueStep(step)
  bar:SetObeyStepOnDrag(true)
  bar:SetThumbTexture(SLIDER_THUMB)
  local track = bar:CreateTexture(nil, "BACKGROUND")
  track:SetColorTexture(1, 1, 1, 0.2)
  track:SetHeight(4)
  track:SetPoint("LEFT")
  track:SetPoint("RIGHT")
  local text = Widgets.Label(frame, "GameFontHighlight")
  text:SetPoint("LEFT", bar, "RIGHT", 10, 0)
  local showing = false
  bar:SetScript("OnValueChanged", function(_, number)
    number = math.floor(number / step + 0.5) * step
    text:SetText(show(number))
    -- Only what the player does to it changes the setting, not the page showing what it is
    if not showing and number ~= value:GetValue() then
      value:SetValue(number)
    end
  end)
  explain(bar, label, tip)
  refreshers[#refreshers + 1] = function()
    showing = true
    bar:SetValue(value:GetValue())
    text:SetText(show(value:GetValue()))
    showing = false
  end
  frame.control = bar
  return bar
end

--- A button that does something there and then
--- @param label string
--- @param text string On the button
--- @param onClick fun()
--- @param tip string?
--- @return Button
local function action(label, text, onClick, tip)
  local frame = row(ROW_HEIGHT, label, tip)
  local button = Widgets.Button(frame, text, BUTTON_WIDTH, 22)
  button:SetPoint("LEFT", frame, "CENTER", CONTROL_X + 4, 0)
  button:SetScript("OnClick", function()
    onClick()
    refresh()
  end)
  explain(button, label, tip)
  frame.control = button
  return button
end

-----------------------------
-- Pickers
-----------------------------
-- What things look like is chosen by clicking on a picture of it: a row of pictures beside its
-- name, as every setting has.

--- @class PickerRow
--- @field label string
--- @field setting OptionSetting What a click sets
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

--- Rows of pictures to choose from, one under the other
--- @param rows PickerRow[]
--- @return { rows: PickerRow[], buttons: Button[][] } picker
local function picker(rows)
  local made = { rows = rows, buttons = {} }
  for index, each in ipairs(rows) do
    local frame = row(each.height + (index == 1 and PICKER_TOP or 0) + (index == #rows and PICKER_TOP or ROW_GAP))
    local top = index == 1 and -PICKER_TOP or 0
    frame.label = Widgets.Label(frame, "GameFontNormal", each.label)
    frame.label:SetPoint("LEFT", frame, "TOPLEFT", LABEL_X, top - each.height / 2)
    made.buttons[index] = {}
    for column, choice in ipairs(each.choices) do
      local button = thumbnail(frame, each, function()
        each.setting:SetValue(each.value and each.value(choice) or choice)
        refresh()
      end)
      button:SetPoint("TOPLEFT", frame, "TOP", CONTROL_X + (column - 1) * (each.width + THUMB_GAP), top)
      made.buttons[index][column] = button
    end
  end
  -- Every choice drawn, the chosen ones on gold
  refreshers[#refreshers + 1] = function()
    for index, each in ipairs(rows) do
      local chosen = each.chosen()
      for column, choice in ipairs(each.choices) do
        local button = made.buttons[index][column]
        each.paint(button, choice)
        button.chosen:SetShown(choice == chosen)
        button.name = each.name(choice)
      end
    end
  end
  return made
end

--- @param colour string
--- @return string
local function colourName(colour)
  return L["options_colour_" .. colour]
end

--- The back of the cards: each design in the colour chosen, and the design chosen in each colour
--- @return table picker
local function cardBacks()
  local back = stored("cardBack", Cards.SetBack)
  local function design()
    return (partsOf(Cards.Back()))
  end
  local function colour()
    return select(2, partsOf(Cards.Back()))
  end
  section(L["options_cards"])
  return picker({
    {
      label = L["options_cardBack_design"],
      setting = back,
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
      setting = back,
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
  })
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
--- @return table picker
local function tableLooks()
  section(L["options_table"])
  return picker({
    {
      label = L["options_feltColour"],
      setting = stored("feltColour", Felt.SetColour),
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
      setting = stored("diceColour", Dice.SetColour),
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
      setting = stored("dominoStyle", Dominoes.SetStyle),
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
  })
end

--- Puts everything on the page
local function build()
  local title = Widgets.Label(panel, "GameFontHighlightHuge", L["title"])
  title:SetPoint("TOPLEFT", panel, "TOPLEFT", LABEL_X - 30, -16)
  local scroll = Widgets.Scroll(panel, WHEEL_STEP)
  scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -TITLE_HEIGHT)
  scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -6, 6)
  page.content, page.top = scroll.content, 0
  -- As wide as the room the settings window gives it
  scroll:HookScript("OnSizeChanged", function(self, width)
    page.content:SetWidth(width)
  end)

  section(L["options_notifications"])
  checkbox(stored("toasts"), L["options_toasts"], L["options_toasts_tip"])
  checkbox(stored("alert"), L["options_alert"], L["options_alert_tip"])
  -- What was held back for as long as these said to has waited long enough
  checkbox(stored("combat", Toast.Release), L["options_combat"], L["options_combat_tip"])
  checkbox(stored("quiet", Toast.Release), L["options_quiet"], L["options_quiet_tip"])

  section(L["options_sounds"])
  checkbox(stored("sound"), L["options_sound"], L["options_sound_tip"])

  section(L["options_challengers"])
  local who = {}
  for index, each in ipairs(CHALLENGERS) do
    who[index] = { value = each, text = L["options_challenges_" .. each] }
  end
  dropdown(stored("challenges"), who, L["options_challenges"], L["options_challenges_tip"])

  section(L["options_window"])
  -- The profile says whether the button is hidden, the page asks whether it is shown
  local minimap = setting(true, function()
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
  checkbox(minimap, L["options_minimap"], L["options_minimap_tip"])
  checkbox(stored("wisp", MainFrame.Refresh), L["options_wisp"], L["options_wisp_tip"])
  local scale = setting(ForeverGames.db.defaults.profile.window.scale, function()
    return profile().window.scale
  end, function(value)
    profile().window.scale = value
    MainFrame.ApplyScale()
  end)
  slider(scale, SCALE_MIN, SCALE_MAX, SCALE_STEP, function(value)
    return L["options_scale_label"]:format(value)
  end, L["options_scale"], L["options_scale_tip"])
  checkbox(stored("smallFade"), L["options_smallFade"], L["options_smallFade_tip"])
  checkbox(stored("smallFights"), L["options_smallFights"], L["options_smallFights_tip"])
  action(L["options_reset"], L["options_reset_button"], MainFrame.ResetWindow, L["options_reset_tip"])

  Options.cardBacks = cardBacks()
  Options.tableLooks = tableLooks()
  page.content:SetHeight(page.top + PICKER_TOP)
end

--- Builds the page and gives it to the settings window
function Options.Init()
  if panel then
    return
  end
  panel = CreateFrame("Frame")
  panel.name = L["title"]
  panel:Hide()
  build()
  -- Shown what everything is set to each time it is opened, and what everything is set to by
  -- anything else meanwhile
  panel:SetScript("OnShow", refresh)
  refresh()
  -- The window's Defaults button: everything on the page as it is to begin with
  function panel.OnDefault()
    for _, each in ipairs(settings) do
      each:SetValue(each.default)
    end
    refresh()
  end
  if Settings and Settings.RegisterCanvasLayoutCategory then
    category = Settings.RegisterCanvasLayoutCategory(panel, L["title"])
    Settings.RegisterAddOnCategory(category)
  elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(panel)
  end
  Options.panel = panel
end

--- Opens the settings window on the addon's page
--- @return boolean, string? error
function Options.Open()
  if not panel then
    return false, "no_options"
  end
  -- The client doesn't let an addon open its settings in the middle of a fight
  if InCombatLockdown() then
    return false, "options_combat"
  end
  if category then
    Settings.OpenToCategory(category:GetID())
  elseif InterfaceOptionsFrame_OpenToCategory then
    -- The old window only lands on the page the second time it is asked
    InterfaceOptionsFrame_OpenToCategory(panel)
    InterfaceOptionsFrame_OpenToCategory(panel)
  else
    return false, "no_options"
  end
  return true
end
