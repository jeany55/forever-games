--------------------------
--  Options
--------------------------
-- The addon's page in the game's own settings window: how the player is told it is their turn,
-- what they hear, who may challenge them and how the window is drawn. How a game is played is
-- not in here, that is set for each game in the new game wizard.
--
-- Everything on the page is a setting the client keeps for as long as the window is open and
-- reads from and writes to the saved profile through the two functions it is given.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L
local Toast = private.Toast
local MainFrame = private.MainFrame

--- @class Options
local Options = {}
private.Options = Options

-- How big the window can be drawn, in hundredths of its usual size
local SCALE_MIN, SCALE_MAX, SCALE_STEP = 60, 150, 5
-- Who the player takes challenges from, in the order they are offered
local CHALLENGERS = { "anyone", "known" }

local category

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
