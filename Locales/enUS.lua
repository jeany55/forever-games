--------------------------------
--   Forever Games Locale File
--   ENGLISH
--------------------------------
local L = LibStub("AceLocale-3.0"):NewLocale("ForeverGames", "enUS", true, true)

-- Games
L["game_tictactoe"] = "Tic Tac Toe"
L["game_chess"] = "Chess"
L["game_tictactoe_description"] = "Three in a row wins. Quick, simple, over in a minute."
L["game_chess_description"] = "The full game, with castling, en passant and promotion. Take as long as you like between moves."
L["chess_white"] = "White"
L["chess_black"] = "Black"

-- How a game ended
L["result_checkmate"] = "checkmate"
L["result_stalemate"] = "stalemate"
L["result_repetition"] = "threefold repetition"
L["result_fifty"] = "fifty move rule"
L["result_material"] = "insufficient material"

-- Main window
L["title"] = "Forever Games"
L["new_game"] = "New Game"
L["empty_title"] = "No games yet"
L["empty_text"] = "Challenge a friend or guildie to get started. They need Forever Games too, and you can both move whenever you have a moment."
L["list_title"] = "Your games"
L["list_waiting_on_you"] = "Waiting on you"
L["list_challenge"] = "Challenges you"
L["list_waiting_count"] = "%d waiting on you"

-- Who is around to play
L["presence_none"] = "Nobody else is online with Forever Games"
L["presence_none_detail"] = "You can still challenge someone by name. They get it when you are both online."
L["presence_one"] = "%d player available"
L["presence_many"] = "%d players available"
L["presence_guild"] = "%d in your guild"
L["presence_friend"] = "%d on your friends list"
L["presence_other"] = "%d you are playing with"
L["presence_tooltip_title"] = "Online with Forever Games"
L["presence_tooltip_none"] = "Guildies and friends show up here when they are online and have the addon."
L["presence_tooltip_more"] = "and %d more"
L["source_guild"] = "Guild"
L["source_friend"] = "Friend"
L["source_other"] = "Opponent"

-- New game wizard
L["wizard_step_game"] = "Step 1 of 2: choose a game"
L["wizard_step_opponent"] = "Step 2 of 2: choose who to play %s with"
L["wizard_available"] = "Available now"
L["wizard_nobody"] = "No guildies or friends are online with Forever Games right now."
L["wizard_by_name"] = "Someone else"
L["wizard_by_name_hint"] = "Type any player's name. They need Forever Games installed, and the challenge reaches them when you are both online."
L["wizard_use_target"] = "Use my target (%s)"
L["wizard_summary"] = "%s against %s"
L["wizard_pick_someone"] = "Pick someone to play"
L["wizard_send"] = "Send Challenge"
L["accept"] = "Accept"
L["decline"] = "Decline"
L["resign"] = "Resign"
L["remove"] = "Remove"
L["withdraw"] = "Withdraw"
L["rematch"] = "Rematch"
L["resign_confirm"] = "Resign your game against %s?"
L["versus"] = "%s vs %s"
L["you_are"] = "You are %s"

-- Match status
L["status_incoming"] = "%s challenges you"
L["status_outgoing"] = "Waiting for %s to accept"
L["status_outgoing_hint"] = "They need Forever Games installed. If they are offline the challenge arrives when you are next online together."
L["status_your_turn"] = "Your turn"
L["status_their_turn"] = "Waiting for %s"
L["status_won"] = "You won!"
L["status_lost"] = "You lost"
L["status_draw"] = "Draw"
L["status_you_resigned"] = "You resigned"
L["status_they_resigned"] = "%s resigned, you win!"
L["status_declined"] = "%s declined"
L["status_declined_nogame"] = "%s doesn't have this game"
L["status_declined_version"] = "%s has a different version of this game"
L["status_declined_busy"] = "%s has too many games open with you"
L["status_declined_gone"] = "%s no longer has this game"
L["status_missing_game"] = "This game is not installed"
L["pending_locked"] = "Your move will be sent when you leave this instance."
L["pending_unreachable"] = "Not delivered yet. It will be sent when %s is reachable."

-- Toasts
L["toast_invite"] = "%s challenges you to %s"
L["toast_accepted"] = "%s accepted your %s challenge"
L["toast_your_turn"] = "%s: your turn against %s"
L["toast_click"] = "Click to open"

-- Minimap
L["tooltip_attention"] = "%d waiting for you"
L["tooltip_nothing"] = "Nothing waiting for you"
L["tooltip_left_click"] = "|cffffd100Left Click|r to open"

-- Chat
L["help_usage"] = "Usage: /fg to open, /fg new to start a game, /fg challenge <player> [game] to challenge someone directly, /fg log to see recent activity"

L["log_cleared"] = "Log cleared."
L["log_shown"] = "Showing the last %d of %d log lines. The full log is saved when you log out or /reload."

-- Errors
L["err_unknown_game"] = "That game is not installed."
L["err_no_target"] = "Type a player name or target a player first."
L["err_self_invite"] = "You can't challenge yourself."
L["err_too_many_matches"] = "You already have too many games open with that player."
L["err_no_match"] = "That game no longer exists."
L["err_not_your_turn"] = "It's not your turn."
L["err_invalid_move"] = "That move isn't allowed."
L["err_cell_taken"] = "That square is taken."
L["err_finished"] = "That game is over."
L["err_match_in_progress"] = "Resign or finish the game first."
