--------------------------
--  Things to draw
--------------------------
-- What Sketch asks a player to draw: things there is a picture of in everybody's head, and that
-- can be got across with a mouse in a minute. Written by hand. Some are two words.
--
-- Only whoever draws picks from these, the others only ever guess. So unlike the word lists the
-- board games play by they are no part of the rules: players whose lists differ can share a room.
-- A word is letters, blanks and apostrophes, nothing else: what is compared is its letters.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @param text string Words with commas between them
--- @return string[]
local function words(text)
  local list = {}
  for word in text:gmatch("[^,]+") do
    word = word:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if word ~= "" then
      list[#list + 1] = word
    end
  end
  return list
end

--- The lists by the letter a room names them with
--- @type table<string, string[]>
private.SketchWords = {
  -- Everyday things
  e = words([[
    apple, anchor, ant, arrow, axe, backpack, balloon, banana, barrel, basket, bat, beach, bear,
    bed, bee, bell, bicycle, bird, boat, bomb, bone, book, boot, bottle, bow, bowl, box, bread,
    bridge, broom, bucket, butterfly, button, cake, camel, camera, campfire, candle, cannon,
    carrot, castle, cat, cave, chain, chair, cheese, chest, chicken, chimney, church, clock,
    cloud, coin, comb, compass, cow, crab, crown, cup, dagger, deer, desert, dice, dog, door,
    dragon, drum, duck, eagle, ear, egg, elephant, eye, feather, fence, fire, fish, fishing rod,
    flag, flower, fork, fox, frog, ghost, giraffe, glasses, glove, goat, grapes, guitar, hammer,
    hand, hat, heart, helmet, hook, horse, horseshoe, hourglass, house, iceberg, island, key,
    king, kite, knife, ladder, lamp, leaf, lighthouse, lightning, lion, lock, map, mask, mill,
    mirror, monkey, moon, mountain, mouse, mushroom, nail, necklace, needle, nest, net, nose,
    octopus, owl, palm tree, pants, pear, pencil, pig, pillow, pirate, pizza, plate, pumpkin,
    queen, rabbit, rain, rainbow, rat, ring, river, rocket, roof, rope, saddle, sail, sandwich,
    saw, scarf, scissors, scorpion, shark, sheep, shield, ship, shirt, shovel, skull, snail,
    snake, snowman, sock, spider, spoon, stairs, star, sun, sword, table, tent, tooth, torch,
    tower, trap, treasure, tree, trumpet, turtle, umbrella, volcano, wagon, wall, waterfall,
    well, whale, wheel, whistle, window, wing, witch, wolf, worm
  ]]),
  -- Things there are on Azeroth
  w = words([[
    murloc, hearthstone, gnome, tauren, troll, dwarf, night elf, undead, orc, goblin, ogre,
    kobold, gnoll, naga, worgen, wisp, treant, imp, felhound, succubus, voidwalker, infernal,
    water elemental, totem, gryphon, wyvern, zeppelin, mailbox, auction house, bank, inn,
    flight path, portal, moonwell, mage, warrior, priest, rogue, hunter, paladin, shaman,
    warlock, druid, healer, tank, sheep spell, fireball, frostbolt, blizzard, bubble, backstab,
    fishing bobber, mining pick, anvil, forge, cauldron, healing potion, mana potion, bandage,
    spirit healer, graveyard, corpse run, quest giver, loot, epic mount, raptor, kodo, tiger mount,
    ram mount, mechanostrider, battleground, flag carrier, dungeon, raid boss, dragon whelp,
    Onyxia, Ragnaros, Hogger, Thrall, Sylvanas, Illidan, Arthas, Frostmourne, Ashbringer,
    Doomhammer, Thunderfury, Dark Portal, Stormwind, Orgrimmar, Ironforge, Darnassus,
    Thunder Bluff, Undercity, Booty Bay, Deadmines, Molten Core, Deeprun Tram, World Tree,
    Horde, Alliance, guild tabard, trainer, pet, critter, campfire buff, soulstone, summoning stone,
    lockpick, gnomish engineer, target dummy, rested, level up, world buff
  ]]),
}
