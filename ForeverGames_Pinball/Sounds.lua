--------------------------
--  Pinball: sounds
--------------------------
-- What is heard when something happens on the table, by what happened.
--
-- The machine's own noises (the flippers, the bumpers, the ball on steel and rubber) are made by
-- Tools/make_pinball_sounds.py into Sounds\. Where there are several, one is picked at
-- random each time, so that a sound heard often doesn't sound like a recording.
--
-- The big moments are the game's own sounds, played by their SoundKit ids: the level-up ding, a
-- quest accepted and handed in, coins, Stormwind's bell, a dragon's roar, Frost Nova and Shield
-- Wall. Every id here is in the client's own data (the SoundKit and SoundKitEntry tables of builds
-- 1.60.1.70374 and 70450, as wago.tools has them), and each plays exactly one file, named in its
-- note, or one of the few named.
-- An event can have both: the machine's noise and the game's sound over it.
--
-- `volume` is how loud the sound is against the others, 0 to 1, as it was made: the client plays an
-- addon's sound at the level it is, so it is only a guide to what to leave out when much happens at once.
--
--   files   our sounds, by name, under Interface\AddOns\PinballBench\Sounds\
--   kit     the client's SoundKit id, for PlaySound
--   note    what it is

local ADDON, ns = ...

-- In the folder of whichever addon this is: the game's, or the bench's that tries it out
ns.SOUND_FOLDER = "Interface\\AddOns\\" .. ADDON .. "\\Sounds\\"

ns.Sounds = {
  -- The machine
  flipperUp = { files = { "flipperUp1", "flipperUp2", "flipperUp3" }, volume = 0.9, note = "a flipper's coil firing" },
  flipperDown = { files = { "flipperDown1", "flipperDown2" }, volume = 0.55, note = "a flipper let go, falling back" },
  bumper = { files = { "bumper1", "bumper2", "bumper3" }, volume = 0.95, note = "a pop bumper kicking" },
  sling = { files = { "sling1", "sling2" }, volume = 0.85, note = "a slingshot kicking" },
  rollover = { files = { "rollover" }, volume = 0.35, note = "a rollover's switch" },
  targetDrop = { files = { "targetDrop" }, volume = 0.7, note = "a drop target hit and falling" },
  targetsReset = { files = { "targetsReset" }, volume = 0.9, note = "the drop targets coming back up" },
  standup = { files = { "standup" }, volume = 0.6, note = "a standup target hit" },
  spinner = { files = { "spinner" }, volume = 0.4, note = "one turn of the spinner, played for every turn" },
  saucerIn = { files = { "saucerIn" }, volume = 0.75, note = "the ball dropping into the saucer" },
  saucerKick = { files = { "saucerKick" }, volume = 0.9, note = "the saucer kicking the ball out" },
  kickback = { files = { "kickback" }, volume = 0.95, note = "the kickback firing" },
  plungerPull = { files = { "plungerPull" }, volume = 0.35, note = "the plunger's spring stretched" },
  plungerRelease = { files = { "plungerRelease" }, volume = 0.8, note = "the plunger let go" },
  gate = { files = { "gate" }, volume = 0.35, note = "the shooter lane's wire gate" },
  rampEnter = { files = { "rampEnter" }, volume = 0.45, note = "the ball rolling up the ramp's plastic" },
  rampMade = { files = { "rampFlap" }, kit = 3201, volume = 0.6, note = "over the ramp's flap; iquestupdate.ogg, a quest objective done" },
  wireRail = { files = { "wireRail" }, volume = 0.5, note = "the ball rattling down the wire return" },
  drain = { files = { "drain" }, volume = 0.7, note = "the ball down the drain, into the trough" },
  ballHit = { files = { "ballHit" }, volume = 0.4, note = "two balls meeting" },
  railHit = { files = { "railHit1", "railHit2" }, volume = 0.45, note = "the ball off a steel rail, softly and hard" },
  rubberHit = { files = { "rubberHit" }, volume = 0.45, note = "the ball off a rubber post" },
  tilt = { files = { "tilt" }, volume = 0.6, note = "the tilt buzzer" },
  ballServe = { files = { "ballServe" }, volume = 0.75, note = "a ball served into the shooter lane" },
  rolling = { files = { "rolling" }, volume = 0.3, note = "two seconds of the ball rolling, that join end to start" },
  postUp = { files = { "postUp" }, volume = 0.9, note = "the post between the flippers coming up" },
  postDown = { files = { "postDown" }, volume = 0.6, note = "and going back down" },

  -- The machine's music, from its speakers
  attract1 = { files = { "attract1" }, volume = 0.75, note = "the machine calling to be played: bells rising over brass" },
  attract2 = { files = { "attract2" }, volume = 0.75, note = "and another: a sparkle falling to a low bell" },
  powerOn = { files = { "powerOn" }, volume = 0.8, note = "switched on: relays, the lamps' hum, a chord" },
  gameStart = { files = { "gameStart" }, volume = 0.85, note = "a game started: a fanfare" },
  letter = { files = { "letter" }, volume = 0.4, note = "a letter of the initials changed" },
  letterChosen = { files = { "letterChosen" }, volume = 0.6, note = "a letter of the initials chosen" },

  -- The game's own
  tiltWarning = { kit = 8959, volume = 0.7, note = "RAID_WARNING, raidwarning.ogg: a nudge too many, one more tilts" },
  ballSave = { kit = 15, volume = 0.8, note = "divineshield.ogg: Divine Intervention, the ball saved" },
  extraBall = { kit = 7354, volume = 0.9, note = "soulstoneresurrection_base.ogg: the Soulstone, an extra ball" },
  levelUp = { kit = 888, volume = 1, note = "LEVELUP, levelup.ogg: the ding" },
  questStart = { kit = 618, volume = 0.8, note = "iquestactivate.ogg: a quest accepted" },
  questComplete = { kit = 878, volume = 0.9, note = "IG_QUEST_LIST_COMPLETE, iquestcomplete.ogg: a quest handed in" },
  jackpot = { kit = 287276, volume = 0.9, note = "lootcoinlarge.ogg: a jackpot, a pile of coins" },
  coins = { kit = 120, volume = 0.6, note = "LOOT_WINDOW_COIN_SOUND, lootcoinsmall.ogg: a small award" },
  superJackpot = { kit = 7256, volume = 1, note = "belltollalliance.ogg: Stormwind's bell, the super jackpot" },
  multiball = { kit = 5903, volume = 1, note = "dragonaggro.ogg: a dragon's roar, the raid begins" },
  wings = { kit = 5059, volume = 0.8, note = "hugewingflap3.ogg: great wings, for a dragon's phase of the raid" },
  skillShot = { kit = 8960, volume = 0.8, note = "READY_CHECK, readycheck.ogg: the skill shot made" },
  fanfare = { kit = 8459, volume = 0.9, note = "PVP_THROUGH_QUEUE, pvpthroughqueue.ogg: a fanfare, for something rare" },
  talent = { kit = 8473, volume = 0.9, note = "reputationlevelup.ogg: a talent learned" },
  gameOver = { kit = 847, volume = 0.8, note = "IG_QUEST_FAILED, igquestfailed.ogg: the last ball lost" },

  -- The class spells, as they sound in the game
  frostNova = { kit = 3076, volume = 1, note = "frostnova.ogg: Frost Nova cast, the balls frozen where they are" },
  frostEnd = { kit = 3182, volume = 0.9, note = "frostnovastateend.ogg: the ice breaking, the balls let go" },
  shieldWall = { files = { "postUp" }, kit = 3094, volume = 1, note = "over the post coming up; shieldwalltarget.ogg: Shield Wall" },
  shieldBlock = { kit = 3263, volume = 0.9, note = "metalshieldblock1-3.ogg, one at random: the Shield Wall stopping a ball" },
}
