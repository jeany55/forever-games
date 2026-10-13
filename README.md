# Forever Games

A World of Warcraft Forever addon for playing classic games against your friends and guildies, at
your own pace. Make a move, go pull a boss, come back later.

Games so far: Tic Tac Toe, Chess, Connect Four, Reversi, Checkers, Battleship, Backgammon,
Chinese Checkers, which is for up to six, and Crazy Eights, which is too. And Solitaire, for when
nobody is around.

## Usage

- `/fg` (or the minimap button) opens the window. The top shows how many guildies and friends are
  online with the addon, checked at login, when the window opens and when you press Refresh
- **New Game** walks you through picking a game and an opponent. Type in the search box, or pick
  a kind of game or how many are playing, to narrow the list down. Click the star on a game to
  keep it at the top, the rest are listed by name. The list scrolls with the mouse wheel and
  fits as many games next to each other as the window has room for
- A game for more than two has you pick everyone who plays: click them in the list, or type a
  name and press Enter, one after the other. The game begins once they have all accepted, and it
  is off if one of them declines. Whoever resigns leaves the others to play on
- A game for one has nobody to pick and begins as soon as you choose it, or with `/fg play`.
  It waits for as long as you like, **Undo** takes back a move, and as many more as you press
  it for, **Start Another** swaps it for a new one and **Give Up** takes it off your list
- Drag the corner of the window to make it any size, the board grows with it. **Focus** hides
  everything but the game you are looking at
- In chess, drag a piece or click it and then where it goes. Click a move in the list, use the
  buttons under it or scroll the mouse wheel over the board to look back through the game.
  **Offer Draw** goes out with your next move, and your opponent turns it down by playing on
- In Connect Four, click anywhere in a column to drop a disc into it. In Reversi, click one of
  the marked squares to place a disc
- Checkers moves like chess: drag a piece or click it and then where it goes. When a piece can
  take, the ones that have to are pointed out. A piece that can go on jumping stays in your hand
  until it has: click each square in turn, or right click to take it back and choose again
- In Chinese Checkers, click a marble and then one of the marked holes: every hole it can hop
  its way to is marked, however many hops that takes. Your own corner of the star is at the
  bottom, and the list next to the board says who plays which colour and whose turn it is
- In Backgammon the dice are rolled for you. Click a checker and then where it goes, or drag it:
  the points it can reach are marked, by one die or by both. Put your turn together a checker at
  a time, **Undo** or a right click takes the last one back, and nothing is sent until you
  press **Play**. A roll you can't play at all is skipped by itself
- In Crazy Eights a new game is dealt out in front of you. The cards you can play stand out of
  your hand, click one to play it. An eight
  asks which suit comes next. Click the deck to draw instead, and if what you drew can be played
  the choice is yours: play, or **Pass**. Everyone else's cards are turned over when the game ends
- Battleship begins with your fleet laid out at random on your own sea. Click a ship to pick it
  up and click the water to put it down again, a right click or **Rotate** turns it, **Random**
  lays out another fleet, and nothing is sent until you press **Deploy**. You can arrange yours
  while you wait for the other fleet. After that click a square of the other sea to fire at it:
  you are told what the shot did right away, whether your opponent is around or not. The sea
  you aren't playing on is shown small, click it for a closer look
- Solitaire is Klondike, dealt out in front of you. Drag a card where it should go, with
  whatever lies on it, or just click it: it goes home if it can and to the first column that
  will have it if not, and a right click only ever sends it home. Click the stock to turn a
  card, and again when it is empty to go through it once more. When nothing is left face down,
  **Finish** plays the rest out for you
- `/fg challenge <player> [game]` challenges someone, or use the box at the bottom of the window. Leave
  the name empty to challenge your target

- `/fg log` shows recent activity (messages sent and received, with results). The full log is saved
  per character in the `ForeverGames.lua` saved variables file on logout or `/reload`

Everyone playing needs the addon. There is no server: moves travel directly between the players as
addon whispers, so they are delivered when sender and receiver are online and outside instances that
block addon communication. Anything that can't be delivered right away is kept and sent later, and
in a game of more than two whoever is around passes on what a player missed.

Having no server also means there is nobody to roll the dice or hold the deck. Every player's
copy of the addon works them out the same way from the moves made so far, and shows you only
what you are meant to see. It keeps a game among friends fair, the way a game at a table is: it
would not stop someone determined to look at cards that aren't theirs.

## Development

The folder has to be called `ForeverGames` inside `Interface/AddOns`.

```
./Tests/RunTests.sh
```

runs the tests with a stock `lua` (5.1), no game client needed. The engine is tested for real. The
window is clicked through against a stand-in for the client (`Tests/FakeClient.lua`) that draws
nothing: that catches mistakes in what the window does, not in how it looks.

### Layout

- `Engine/` rules of play and the sync protocol. No WoW API in here, which is what makes it testable
  - `Codec.lua` wire format
  - `Random.lua` dice and shuffles that come out the same for every player
  - `Games.lua` game registry
  - `Match.lua` a match is its players and a log of moves, state is derived by replaying it
  - `Session.lua` challenges, moves, retries and resync, between two players or among several
  - `Presence.lua` who is online with the addon
- `Games/` one file per game: its rules and its view
- `Transport.lua` addon messages, lockdown and online/offline detection
- `GUI/` main window, new game wizard and toast
  - `Board.lua` a board of squares and pieces for games to draw on: any size and shape, pieces
    that are moved by drag and drop or placed with a click, target marks, pieces that glide,
    drop, turn over and settle, and a shared set of round pieces. Given a layout it is a board
    of holes wherever the game wants them instead of a grid, that can be turned to face each
    player, with piles of pieces counted where they get too high to draw. A grid can lie on a
    picture that shimmers, carry things that lie across several squares, and say which square
    the cursor is over
  - `Cards.lua` playing cards: a hand that fans out to fit and lets the player pick a card, a
    card for a deck or a pile, and cards that fly from one to the other, dealt round the table
    and turned over in the air
  - `CardTable.lua` a table that cards lie on in piles and are moved about on: it is told which
    cards are in which pile and shows whatever that changed by itself, cards flying to where
    they are now and turning over on the way, one after the other when they are dealt. The
    player drags cards from pile to pile, alone or with what lies on them, or clicks them, and
    what can't stay where it was let go goes back
- `Core.lua` wires it all together
- `Sounds/` cards, chips and dice
- `Tools/` scripts that made the textures in `Images/`

### Adding a game

Add a file to `Games/`, list it in `ForeverGames.toc` and call `private.Games.Register` with the
functions described at the top of `Engine/Games.lua`. A game has two halves:

- **Rules**: `newState`, `turn`, `validate`, `apply` and `result`, pure functions over a state
  table. A move is a short string the game defines (letters, digits and `-+.=_`). `apply` can
  return a table saying what the move did, which the view gets back to animate from. `turn`
  decides who is next and needn't alternate: Reversi hands the turn straight back when a player
  has nowhere to go
- **Chance**: `newState` and `apply` are handed a `random` to roll and shuffle with
  (`random:Roll(6)`, `random:Shuffle(deck)`). It is the only place chance may come from: it is
  worked out from the match and the moves made in it, which is what makes every player's copy
  come out with the same dice. Roll for the next turn while applying a move, so the roll is
  there when the move arrives and a turn stays one message
- **Secrets**: a game where players don't all know the same has `visible(state, seat)`, which
  returns a copy of the position with what that seat may not see blanked out. Views are only
  ever shown that, until the game is over and everything is turned face up. What `apply`
  returns is seen by everyone, so it mustn't name a card nobody was shown
- **Players**: `seats` says how many play, a number or a list where there is a choice
  (`{ 2, 3, 4, 6 }`). `newState` is told how many there are this time. A game for more than two
  also has `drop`, which takes a player who resigned out of the game for the others to play on
- **Alone**: a game with `seats = 1` is played by the player on their own. It is the same two
  halves and nothing else: there is no challenge, it is always seat 1's turn and no move is
  ever sent. With `undo = true` the window lets moves be taken back, and `progress(state)` is
  a few words on how it is going for where other games say whose turn it is
- **View**: `createView(stage)` builds the game's widgets in the frame it is given and returns an
  object with `Layout(width, height)` and `Update(view)`. It can draw however it likes, games
  played on a grid get most of it from `GUI/Board.lua`. `view.played` is the move to animate,
  when there is one worth showing

Give the game a `genre` so it can be found in the new game wizard: one that is there already
(`strategy`, `casual`, `dice`, `cards`, `words`, `solo`) or a new one, with its name in the locale file as `genre_<name>`.

Everything else is the engine's and the same for every game: challenges, gathering the players
of a game for more than two, turn notifications, saving, delivery, resigning, and for games of two
that ask for them draw offers (`draws = true`) and the move list with stepping back through the
game (`history = true`).

`Games/TicTacToe.lua` is the smallest example, `Games/Chess.lua` uses all of it. For a game
where pieces are placed look at `Games/ConnectFour.lua` and `Games/Reversi.lua`, at
`Games/Checkers.lua` for moves made in several steps, and at `Games/ChineseCheckers.lua` for more
than two players and a board that isn't a grid. `Games/Backgammon.lua` rolls dice and stacks
its pieces, `Games/CrazyEights.lua` deals cards and keeps hands hidden. `Games/Battleship.lua`
hides what a player chose rather than what they were dealt, on two boards at once, with pieces
several squares long. `Games/Solitaire.lua` is for one, on a card table (`GUI/CardTable.lua`)
that does all of its moving and animating.

The round pieces, the star Chinese Checkers is played on and the icons of the games played with
them are drawn by `Tools/make_discs.py`, the backgammon table and the noughts and crosses by
`Tools/make_tables.py`, the sea, ships and pegs of Battleship by `Tools/make_fleet.py`. The cards,
dice and sounds are converted by `Tools/convert_kenney.py`, and what a card table needs besides
(a blank card, the outline of a place for one, the icon of Solitaire) is drawn by
`Tools/make_cards.py`.

## Credits

The chess pieces are from [ChessCraft Creative Commons](https://gitlab.com/zulban/chesscraft-creative-commons)
by Zulban, used under CC BY-SA 4.0. See `Images/Chess/README.md`.

The playing cards, the dice and the sounds are from the
Boardgame Pack by [Kenney](https://www.kenney.nl), released into the public
domain (CC0).
