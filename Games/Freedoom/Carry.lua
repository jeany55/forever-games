--------------------------
--  Freedoom: what the player carries
--------------------------
-- One of the parts of Freedoom (Games/Freedoom.lua): Doom's rules for what the player carries,
-- what picking things up gives them and which doors their keys open. Nothing in here touches
-- the WoW API.

--- @type nil, ForeverGamesPrivate
local _, private = ...
-- What the parts of Freedoom share, and the tests are let see
local Freedoom = private.Freedoom or {}
private.Freedoom = Freedoom

-----------------------------
-- What the player carries
-----------------------------
-- Doom's rules for what is picked up: how much of what it gives, up to what, and that something
-- the player has all they can carry of is left lying where it is. What a monster drops is worth
-- less than what lay there to begin with.

-- Ammunition: how much the player can carry of each, without a backpack and with, and how much
-- one clip of it is
local MAX_AMMO = { bullets = 200, shells = 50, cells = 300, rockets = 50 }
local CLIP = { bullets = 10, shells = 4, cells = 20, rockets = 1 }
-- Weapons: which number they are on the status bar, what they fire and how much of it a shot
-- takes, if more than one
local WEAPONS = {
  fist = { slot = 1 }, chainsaw = { slot = 1 },
  pistol = { slot = 2, ammo = "bullets" },
  shotgun = { slot = 3, ammo = "shells" }, supershotgun = { slot = 3, ammo = "shells" },
  chaingun = { slot = 4, ammo = "bullets" },
  launcher = { slot = 5, ammo = "rockets" },
  plasma = { slot = 6, ammo = "cells" },
  bfg = { slot = 7, ammo = "cells", uses = 40 },
}
local MOST_HEALTH, MOST_BONUS = 100, 200

--- @class FreedoomInventory
--- @field health number
--- @field armor number
--- @field armorClass number 0 for none, 1 for the green vest's (a third of a blow), 2 for the blue's (half)
--- @field ammo table<string, number>
--- @field max table<string, number>
--- @field weapons table<string, boolean>
--- @field weapon string What is in the player's hands
--- @field pending string? What they are changing to
--- @field keys table<string, boolean> By colour and kind: "bluecard", "redskull"
--- @field powers table<string, boolean>
--- @field ammoTimes number? Ammunition picked up counts this many times over: twice on the easiest skill, as in Doom
--- @field backpack boolean

--- What the player has at the start of a map
--- @return FreedoomInventory
local function newInventory()
  local max = {}
  for kind, most in pairs(MAX_AMMO) do
    max[kind] = most
  end
  return {
    health = MOST_HEALTH,
    armor = 0,
    armorClass = 0,
    ammo = { bullets = 50, shells = 0, cells = 0, rockets = 0 },
    max = max,
    weapons = { fist = true, pistol = true },
    weapon = "pistol",
    keys = {},
    powers = {},
    backpack = false,
  }
end

local function giveAmmo(inventory, kind, amount)
  if inventory.ammo[kind] >= inventory.max[kind] then
    return false
  end
  inventory.ammo[kind] = math.min(inventory.max[kind], inventory.ammo[kind] + amount * (inventory.ammoTimes or 1))
  return true
end

local function giveHealth(inventory, amount)
  if inventory.health >= MOST_HEALTH then
    return false
  end
  inventory.health = math.min(MOST_HEALTH, inventory.health + amount)
  return true
end

local function giveArmor(inventory, class)
  local amount = class * 100
  if inventory.armor >= amount then
    return false
  end
  inventory.armor, inventory.armorClass = amount, class
  return true
end

--- A weapon lying about comes with two clips of what it fires, one a monster dropped with one.
--- One the player didn't have is what they hold next
--- @return boolean taken
--- @return boolean new The player didn't have it
local function giveWeapon(inventory, weapon, dropped)
  local ammo = WEAPONS[weapon].ammo
  local gave = ammo ~= nil and giveAmmo(inventory, ammo, CLIP[ammo] * (dropped and 1 or 2))
  local new = not inventory.weapons[weapon]
  inventory.weapons[weapon] = true
  if new then
    inventory.pending = weapon
  end
  return new or gave, new
end

local function ammo(kind, clips)
  return function(inventory, dropped)
    return giveAmmo(inventory, kind, dropped and math.floor(CLIP[kind] * clips / 2) or CLIP[kind] * clips)
  end
end

local function weapon(name)
  return function(inventory, dropped)
    return giveWeapon(inventory, name, dropped)
  end
end

local function key(name)
  return function(inventory)
    inventory.keys[name] = true
    return true
  end
end

local function power(name)
  return function(inventory)
    inventory.powers[name] = true
    return true
  end
end

-- What each kind of thing that can be picked up gives: a function that gives it and says whether
-- the thing was taken, and whether that is worth a grin. And the message that says so
local PICKUPS = {
  [2011] = { function(inventory)
    return giveHealth(inventory, 10)
  end, "stim" },
  [2012] = { function(inventory)
    local low = inventory.health < 25
    return giveHealth(inventory, 25), false, low and "medineed" or nil
  end, "medikit" },
  [2014] = { function(inventory)
    inventory.health = math.min(MOST_BONUS, inventory.health + 1)
    return true
  end, "healthbonus" },
  [2015] = { function(inventory)
    inventory.armor = math.min(MOST_BONUS, inventory.armor + 1)
    inventory.armorClass = math.max(1, inventory.armorClass)
    return true
  end, "armorbonus" },
  [2013] = { function(inventory)
    inventory.health = math.min(MOST_BONUS, inventory.health + 100)
    return true
  end, "soulsphere" },
  [83] = { function(inventory)
    inventory.health, inventory.armor, inventory.armorClass = MOST_BONUS, MOST_BONUS, 2
    return true
  end, "megasphere" },
  [2018] = { function(inventory)
    return giveArmor(inventory, 1)
  end, "armor" },
  [2019] = { function(inventory)
    return giveArmor(inventory, 2)
  end, "megaarmor" },
  [5] = { key("bluecard"), "bluecard" },
  [6] = { key("yellowcard"), "yellowcard" },
  [13] = { key("redcard"), "redcard" },
  [40] = { key("blueskull"), "blueskull" },
  [39] = { key("yellowskull"), "yellowskull" },
  [38] = { key("redskull"), "redskull" },
  [2007] = { ammo("bullets", 1), "clip" },
  [2048] = { ammo("bullets", 5), "clipbox" },
  [2008] = { ammo("shells", 1), "shells" },
  [2049] = { ammo("shells", 5), "shellbox" },
  [2010] = { ammo("rockets", 1), "rocket" },
  [2046] = { ammo("rockets", 5), "rocketbox" },
  [2047] = { ammo("cells", 1), "cell" },
  [17] = { ammo("cells", 5), "cellbox" },
  [8] = { function(inventory)
    if not inventory.backpack then
      inventory.backpack = true
      for kind, most in pairs(MAX_AMMO) do
        inventory.max[kind] = most * 2
      end
    end
    for kind, clip in pairs(CLIP) do
      giveAmmo(inventory, kind, clip)
    end
    return true
  end, "backpack" },
  [2001] = { weapon("shotgun"), "shotgun" },
  [82] = { weapon("supershotgun"), "supershotgun" },
  [2002] = { weapon("chaingun"), "chaingun" },
  [2003] = { weapon("launcher"), "launcher" },
  [2004] = { weapon("plasma"), "plasma" },
  [2006] = { weapon("bfg"), "bfg" },
  [2005] = { function(inventory)
    local new = not inventory.weapons.chainsaw
    inventory.weapons.chainsaw = true
    if new then
      inventory.pending = "chainsaw"
    end
    return new, new
  end, "chainsaw" },
  [2022] = { power("invulnerability"), "invulnerability" },
  [2023] = { function(inventory)
    inventory.powers.berserk = true
    giveHealth(inventory, 100)
    return true
  end, "berserk" },
  [2024] = { power("invisibility"), "invisibility" },
  [2025] = { power("suit"), "suit" },
  [2026] = { power("map"), "map" },
  [2045] = { power("visor"), "visor" },
}

--- Picks a thing up if the player can use it
--- @param inventory FreedoomInventory
--- @param kind integer The thing's type
--- @param dropped boolean? A monster dropped it
--- @return string? message Its locale key, nil if it was left where it is
--- @return boolean grin It was a weapon the player didn't have
local function pickUp(inventory, kind, dropped)
  local pickup = PICKUPS[kind]
  if not pickup then
    return nil, false
  end
  local taken, grin, say = pickup[1](inventory, dropped)
  if not taken then
    return nil, false
  end
  return "freedoom_got_" .. (say or pickup[2]), grin == true
end

-- Doors that need a key, by their special: the colour, either the card or the skull of it
local LOCKS = { [26] = "blue", [32] = "blue", [99] = "blue", [133] = "blue", [27] = "yellow", [34] = "yellow", [136] = "yellow", [137] = "yellow",
  [28] = "red", [33] = "red", [134] = "red", [135] = "red" }

--- Whether the player may open a door
--- @param inventory FreedoomInventory
--- @param special integer
--- @return boolean
--- @return string? colour The key it needs, if it does
local function unlocks(inventory, special)
  local colour = LOCKS[special]
  if not colour then
    return true
  end
  return inventory.keys[colour .. "card"] == true or inventory.keys[colour .. "skull"] == true, colour
end

Freedoom.WEAPONS, Freedoom.newInventory, Freedoom.pickUp, Freedoom.unlocks = WEAPONS, newInventory, pickUp, unlocks
-- For the tests
Freedoom.NewInventory, Freedoom.PickUp, Freedoom.Unlocks = newInventory, pickUp, unlocks
