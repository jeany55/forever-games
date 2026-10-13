--------------------------
--  Warcraft
--------------------------
-- Words that are only words on Azeroth: its places, peoples and beasts, the names of those who
-- made its history, what its players say to each other. Written by hand, a name a time.
--
-- A name is one word of at most fifteen letters and is written here the way it is properly
-- written, apostrophes and all: only its letters count on the board, "Kael'thas" is KAELTHAS.
-- Of somebody with two names each is a word of its own, where it is one worth having. The group
-- says what a name is, for telling the player (L["words_group_" .. group]).
--
-- These are worth more than an ordinary word, and the names every player knows more again:
-- they are the lists given the rank 2. Most of what is here is no English word at all. The few
-- that are (the classes, the two factions, a quest) are here because the game wouldn't be about
-- Warcraft without them.
--
-- Nothing of two letters is added, and little of three: every short word changes the game a lot
-- more than a long one does. This list is part of the rules, so Games/Words.lua needs a new
-- version whenever it changes.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @param group string
--- @param names string
--- @param rank number?
local function add(group, names, rank)
  private.Lexicon.Names("warcraft", group, names, rank)
end

local LEGENDARY = 2

-----------------------------
-- Who
-----------------------------

add(
  "figure",
  [[
  Thrall Jaina Sylvanas Arthas Illidan Anduin Varian Uther Tyrande Malfurion Garrosh Vol'jin
  Cairne Khadgar Medivh Gul'dan Kael'thas Kil'jaeden Archimonde Sargeras Deathwing Alexstrasza
  Ysera Nozdormu Malygos Ragnaros Nefarian Onyxia Kel'Thuzad Bolvar Tirion Grommash Durotan
  Saurfang Rexxar Chromie Hogger Leeroy Velen Maiev Vashj Magni Muradin Brann Lothar Turalyon
  Alleria Azshara Cenarius Mannoroth Mal'Ganis Ner'zhul Zul'jin C'Thun Yogg-Saron N'Zoth
  Proudmoore Windrunner Stormrage Whisperwind Hellscream Bloodhoof Wrynn Menethil Bronzebeard
  Patchwerk Mankrik Elune Bwonsamdi
]],
  LEGENDARY
)

add(
  "figure",
  [[
  Baine Orgrim Gelbin Mekkatorque Gallywix Vereesa Rhonin Krasus Aegwynn Antonidas Terenas Daelin
  Garona Kargath Blackhand Kilrogg Gorefiend Akama Liadrin Lor'themar Rommath Genn Greymane
  Shadowsong Sunstrider Fordring Mograine Whitemane Rivendare Thaurissan Wrathion Kalecgos
  Sindragosa Sapphiron Neltharion Gruul Magtheridon Kazzak Azuregos Thunderaan Loken Thorim Hodir
  Mimiron Algalon Zovaal Denathrius Xal'atath Thalyssra Talanji Rastakhan Nathanos Putress Faol
  Staghelm Fandral Shandris Broxigar Hakkar Jin'do Mandokir Ossirian Skeram Ouro Razorgore
  Vaelastrasz Chromaggus Lucifron Magmadar Gehennas Garr Shazzrah Golemagg Executus Heigan
  Loatheb Grobbulus Gluth Maexxna Faerlina Razuvious Gothik Thaddius Anub'arak Leotheras
  Al'ar Supremus Azgalor Anetheron Brutallus Felmyst Nalorakk Akil'zon Halazzi Attumen Moroes
  Netherspite Nightbane Malchezaar Marrowgar Festergut Rotface Putricide Lana'thel Valithria
  Cho'gall Sinestra Atramedes Maloriak Magmaw Al'Akir Garalon Elisande Helya Odyn Xavius Aggramar
  Eonar Aman'Thul Golganneth Khaz'goroth Norgannon G'huun Mythrax Zul Raszageth Sarkareth Fyrakk
  Iridikron Vyranoth Ansurek Tichondrius Varimathras Y'Shaarj Anzu Tarecgosa Senegos Ebyssian
  Taelia Calia Falstad Kurdran Danath
  Drek'Thar Vanndar Galvangar Balinda Nazgrim Zaela Eitrigg Varok Dranosh
]]
)

add(
  "race",
  [[
  Tauren Draenei Worgen Pandaren Nightborne Zandalari Vulpera Dracthyr Mechagnome Mag'har
  Sin'dorei Kal'dorei Quel'dorei Shal'dorei Ren'dorei Haranir Darkspear Amani Gurubashi Farraki
  Drakkari Mogu Saurok Jinyu Hozen Grummle Vrykul Tuskarr Taunka Gorloc Wolvar Arakkoa Ogron
  Gronn Saberon Botani Naaru Eredar Nathrezim Shivarra Man'ari Qiraji Nerubian Nerubians Aqir
  Kyrian Venthyr Necrolord Sethrak Tortollan Ankoan Nightfallen Highborne Krokul Niffen Djaradin
  Quilboar Furbolg Furbolgs Murloc Murlocs Gnoll Gnolls Naga Makrura Magnataur Kvaldir Tol'vir
  Yaungol Sporeling Val'kyr Dreadlord Dreadlords Lightforged Kul'Tiran Trogg Troggs

]]
)

add("class", [[
  Paladin Warlock Shaman Druid Mage Rogue Priest Hunter Warrior Monk Evoker Windwalker
  Brewmaster Mistweaver Archmage Archdruid Farseer Warchief Highlord Loremaster Lightbringer
  Spellbreaker Shadowhunter Blademaster Runemaster
]])

add(
  "creature",
  [[
  Felguard Felhound Felhunter Voidwalker Doomguard Voidlord Worg Kodo Kodos Zhevra Plainstrider
  Hippogryph Netherdrake Felbat Talbuk Clefthoof Elekk Mushan Shoveltusk Wolpertinger
  Devilsaur Crocolisk Silithid Dragonhawk Sporebat Riverbeast Goren Podling Moonkin Treant
  Felstalker Jormungar Mechanostrider Nightsaber
  Frostsaber Direhorn Quilen Whelpling Wyrm Dragonkin Drakonid Dragonspawn
  Felsteed Dreadsteed Deathcharger
]]
)

-----------------------------
-- Where
-----------------------------

add(
  "city",
  [[
  Stormwind Orgrimmar Ironforge Darnassus Undercity Silvermoon Exodar Shattrath Dalaran
  Gnomeregan Boralus Dazar'alor Oribos Valdrakken Dornogal Suramar Gadgetzan Everlook Theramore
  Lordaeron Stratholme Andorhal Southshore Goldshire Lakeshire Darkshire Auberdine Astranaar
  Sen'jin Stromgarde Gilneas Kezan Nethergarde Kharanos Thelsamar Nighthaven Halaa Garadar Telaar
  Thrallmar Wyrmrest Valgarde Halfhill Karabor Bel'ameth Mechagon Bilgewater
  Stonard Hammerfall Revantusk
  Taurajo Mojache Thalanaar Feathermoon
]]
)

add(
  "zone",
  [[
  Azeroth Kalimdor Northrend Pandaria Draenor Outland Argus Zandalar Shadowlands Maldraxxus
  Ardenweald Revendreth Korthia Quel'Thalas Elwynn Westfall Redridge Duskwood Stranglethorn
  Tanaris Un'Goro Silithus Winterspring Felwood Ashenvale Darkshore Teldrassil Durotar Mulgore
  Desolace Feralas Stonetalon Dustwallow Tirisfal Silverpine Hillsbrad Alterac Arathi Deadwind
  Moonglade Nagrand Zangarmarsh Terokkar Netherstorm Shadowmoon Quel'Danas Eversong Ghostlands
  Azuremyst Bloodmyst Dragonblight Icecrown Wintergrasp Sholazar Zul'Drak Hyjal Vashj'ir Deepholm
  Uldum Kun-Lai Krasarang Talador Gorgrond Tanaan Azsuna Val'sharah Highmountain Stormheim
  Tiragarde Drustvar Stormsong Nazmir Vol'dun Zuldazar Nazjatar Thaldraszus Ohn'ahran Hallowfall
  Azj-Kahet Blackrock Nordrassil Amirdrassil Vordrassil Sunwell Ashran Warsong
  Frostwolf Stormpike
]]
)

add(
  "dungeon",
  [[
  Deadmines Scholomance Uldaman Maraudon Karazhan Naxxramas Ahn'Qiraj Zul'Gurub Zul'Farrak
  Zul'Aman Ulduar Uldir Nighthold Antorus Ny'alotha Blackwing Shadowfang Blackfathom Razorfen
  Sethekk Auchindoun Auchenai Botanica Mechanar Arcatraz Steamvault Underbog Utgarde Azjol-Nerub
  Gundrak Drak'Tharon Mogu'shan Torghast Nathria Aberrus Nerub-ar Manaforge Waycrest Atal'Dazar
  Atal'Hakkar Naxx Kara Strat Scholo

]]
)

-----------------------------
-- What
-----------------------------

add(
  "item",
  [[
  Thunderfury Sulfuras Ashbringer Frostmourne Atiesh Shadowmourne Val'anyr Thori'dal Doomhammer
  Gorehowl Dragonwrath Warglaive Warglaives Azzinoth Quel'Serrar Rhok'delar Hearthstone
  Fyr'alath Ashkandi
]],
  LEGENDARY
)

add(
  "item",
  [[
  Aluneth Ebonchill Felo'melorn Taeshalach Lok'delar Zin'rokh Soulstone Healthstone Mithril
  Arcanite Adamantite Felsteel Khorium Saronite Titansteel Elementium Truesilver Azerite
  Runecloth Mageweave Netherweave Frostweave Embersilk Windwool Felcloth Mooncloth Peacebloom
  Silverleaf Earthroot Mageroyal Briarthorn Stranglekelp Bruiseweed Kingsblood Liferoot Fadeleaf
  Goldthorn Firebloom Sungrass Gromsblood Dreamfoil Felweed Terocone Lichbloom Icethorn
  Manastone Spellstone Netherwing Darkmoon Fel Felfire
]]
)

add(
  "spell",
  [[
  Pyroblast Frostbolt Flamestrike Moonfire Starfire Starsurge Sunfire Lifebloom Swiftmend
  Barkskin Starfall Shadowmeld Shadowstep Bladestorm Bloodthirst Lightwell Shadowform
  Shadowfiend Shadowburn Windfury Earthbind Stormstrike Multishot Felblade
  Spellsteal Bloodlust Frostfire Mindbender Soulburn
  Shadowfury Earthliving Flametongue Frostbrand Rockbiter
]]
)

add(
  "faction",
  [[
  Horde Alliance Cenarion Aldor Scryer Scryers Kurenai Sha'tar Kalu'ak Timbermaw Hydraxian Defias
  Bloodsail Steamwheedle Silverwing Dragonmaw Shado-Pan Klaxxi Illidari Valarjar Ramkahen
  Ravenholdt Wildhammer Stonemaul Dunemaul Frostmane Dragonflight Sunreaver Sunreavers
  Stormreaver Scourge Forsaken Kirin
]]
)

add(
  "lore",
  [[
  Warcraft Worldsoul Thalassian Darnassian Taurahe Zandali Gutterspeak Loa Loas
  An'she Lok'tar Ogar Zug Zugzug Dabu Mrgl Mrglgl Kek Shorel'aran
  Orcish Dwarvish Felblood Lich Lichborne Titanforged Azerothian Draenic
]]
)

add(
  "slang",
  [[
  Quest Quests DPS HPS AOE LFG LFM LFR PVP PVE NPC NPCs GCD BOE DKP AFK OOM RNG WTS WTB TBC
  BFA WOD WotLK Aggro Nerf Nerfs Nerfed Debuff Debuffs Respec Twink Twinks Gank Ganks Ganked
  Ganker Noob Noobs Proc Procs Zerg Addon Addons Transmog Rez Gratz Grats Lowbie Soulbound
  Spellpower Offtank Overheal Timewalking
  Crit Crits
]]
)
