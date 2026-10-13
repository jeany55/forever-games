--------------------------
--  Toast
--------------------------
-- A small click-through-to-open notification, and the sound that goes with it. The player can
-- have either without the other. Not during combat unless the player asked for that, nor in a
-- dungeon, raid or battleground if the player said so: whatever arrives then is held back and
-- the most recent one is shown once the fight is over or the player is back outside.

--- @type nil, ForeverGamesPrivate
local _, private = ...
local L = private.L

--- @class Toast
local Toast = {}
private.Toast = Toast

local DURATION = 8

local frame
--- @type { text: string, onClick: fun()? }?
local held
local hideTimer

local function create()
  frame = CreateFrame("Button", "ForeverGamesToast", UIParent, "BackdropTemplate")
  frame:SetSize(320, 52)
  frame:SetPoint("TOP", UIParent, "TOP", 0, -140)
  frame:SetFrameStrata("DIALOG")
  frame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  frame:SetBackdropColor(0.05, 0.05, 0.08, 0.92)
  frame:SetBackdropBorderColor(1, 0.82, 0, 1)
  frame:Hide()

  frame.icon = frame:CreateTexture(nil, "ARTWORK")
  frame.icon:SetSize(34, 34)
  frame.icon:SetPoint("LEFT", 10, 0)
  frame.icon:SetTexture(private.ICON)

  frame.text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  frame.text:SetPoint("TOPLEFT", frame.icon, "TOPRIGHT", 10, 0)
  frame.text:SetPoint("RIGHT", -10, 0)
  frame.text:SetJustifyH("LEFT")
  frame.text:SetWordWrap(false)

  frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  frame.hint:SetPoint("BOTTOMLEFT", frame.icon, "BOTTOMRIGHT", 10, 0)
  frame.hint:SetText(L["toast_click"])

  frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  frame:SetScript("OnClick", function(self, button)
    self:Hide()
    if button == "LeftButton" and self.onClick then
      self.onClick()
    end
  end)

  -- Show what was held back once combat ends, or the player has left the instance
  frame:RegisterEvent("PLAYER_REGEN_ENABLED")
  frame:RegisterEvent("PLAYER_ENTERING_WORLD")
  frame:SetScript("OnEvent", Toast.Release)
end

--- Whether this is no time to bother the player
--- @return boolean
local function mustWait()
  local profile = ForeverGames.db.profile
  return (not profile.combat and InCombatLockdown()) or (profile.quiet and IsInInstance()) == true
end

--- Shows what was held back, if the time has come
function Toast.Release()
  if held and not mustWait() then
    local toast = held
    held = nil
    Toast.Show(toast.text, toast.onClick)
  end
end

--- @param text string
--- @param onClick fun()? Called when the toast is left clicked
function Toast.Show(text, onClick)
  local profile = ForeverGames.db.profile
  if not profile.toasts and not profile.alert then
    return
  end
  if not frame then
    create()
  end

  if mustWait() then
    held = { text = text, onClick = onClick }
    return
  end

  if profile.alert then
    PlaySound(SOUNDKIT.TELL_MESSAGE)
  end
  if not profile.toasts then
    return
  end

  frame.text:SetText(text)
  frame.onClick = onClick
  frame:Show()

  if hideTimer then
    hideTimer:Cancel()
  end
  hideTimer = C_Timer.NewTimer(DURATION, function()
    frame:Hide()
  end)
end
