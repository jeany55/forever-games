--------------------------------
--   Forever Games Locale File
--   ENGLISH
--------------------------------
local L = LibStub("AceLocale-3.0"):NewLocale("ForeverGames", "enUS", true, true)

-- Games
L["game_tictactoe"] = "Tic Tac Toe"
L["game_chess"] = "Chess"
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
L["challenge"] = "Challenge"
L["challenge_placeholder"] = "Player name"
L["challenge_hint"] = "Type a player name, or leave it empty to challenge your target."
L["empty_list"] = "No games yet.\n\nChallenge a friend or guildie below. They need Forever Games too."
L["no_selection"] = "Select a game on the left."
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
L["help_usage"] = "Usage: /fg to open, /fg challenge <player> [game] to challenge someone"

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
