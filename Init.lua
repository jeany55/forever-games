--------------------------
--  Forever Games
--------------------------
--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class ForeverGamesPrivate
--- @field ADDON_NAME string
--- @field L table<string, string> Localized strings
--- @field Codec Codec
--- @field Games Games
--- @field Match MatchModel
--- @field Session Session Session class, the running instance is private.session
--- @field session Session
--- @field Transport Transport
--- @field Toast Toast
--- @field MainFrame MainFrame
private.ADDON_NAME = "ForeverGames"
private.ICON = "Interface\\Icons\\INV_Misc_Dice_01"
private.L = LibStub("AceLocale-3.0"):GetLocale(private.ADDON_NAME)
