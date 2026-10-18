--------------------------------
--   Pinball for Forever Games
--   ENGLISH
--------------------------------
-- Added to Forever Games' own strings, which is where the engine looks for them. English is
-- what is shown wherever a language has nothing of its own. The bench that tries the game out on
-- its own (Tools/PinballBench) gives a table of its own instead, as `own.L`.
local _, own = ...
local L = own.L or ForeverGamesAPI.Locale("enUS", true)

L["game_pinball"] = "Pinball: Moonglade"
L["game_pinball_description"] = "A pinball machine under the night sky of Moonglade: a ramp onto a winding wire, a corkscrew and the Moonwell, quests, a raid on Onyxia, and two class spells to cast. Three balls, for the best score you can make."
L["pinball_howto_goal"] = "Score as many points as you can with three balls. Your best score is kept, and you can race a friend for the higher one."
L["pinball_howto_controls"] = "Shift, Z and / or the arrow keys work the flippers. Hold Space or Down to pull the plunger back, and let go to shoot the ball. X, . and Up nudge the table, but nudge too often and it tilts. V shows the whole machine or comes in closer on the table."
L["pinball_howto_shots"] = "The shots"
L["pinball_howto_shots_text"] = "The ramp on the right takes the ball up onto a wire that winds over the bumpers and down a corkscrew to the left flipper. The Moonwell in the middle holds the ball, then shoots it up its glass tube onto a wire round to the right flipper. Knock down the three targets on the left to light a quest at the Moonwell, finish three quests to light the raid on Onyxia, and roll through the three lanes at the top to raise the bonus multiplier."
L["pinball_howto_spells"] = "Spells"
L["pinball_howto_spells_text"] = "1 casts Frost Nova, which freezes every ball where it is for a moment. 2 casts Shield Wall, which raises a post between the flippers for ten seconds. You can also click them in the bar beside the machine. Each has a cooldown."
L["pinball_howto_end"] = "The game is over when the last ball goes down the drain. A ball lost soon after it is shot is given back, and an extra ball can be won on the ramp."
L["pinball_progress"] = "Playing"
L["pinball_progress_over"] = "%s points"
L["pinball_points"] = "%s points"
L["pinball_keys"] = "Flippers: Shift, Z and /, or the arrows\nPlunger: Space or Down, held\nNudge: X . Up\nSpells: 1 Frost Nova   2 Shield Wall\nV the whole machine or closer"
L["pinball_frost"] = "Frost Nova"
L["pinball_frost_tip"] = "Freezes every ball where it is"
L["pinball_frost_about"] = "Every ball on the playfield is frozen in ice where it is for %s seconds, then drops. Save a ball heading for the drain, or stop one to aim it."
L["pinball_wall"] = "Shield Wall"
L["pinball_wall_tip"] = "Raises the post between the flippers"
L["pinball_wall_about"] = "The post between the flippers comes up for %s seconds, and every ball that would go down the middle bounces back off it."
L["pinball_spell_press"] = "Press %s, or click"
L["pinball_spell_cooldown"] = "%s second cooldown"
L["pinball_spell_no_game"] = "Start a game first"
L["pinball_spell_active"] = "Active"
L["pinball_spell_cooling"] = "Cooling down"
L["pinball_spell_ready"] = "Press |cffffd100%s|r or click"
