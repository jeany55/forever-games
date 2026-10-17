# Working on Forever Games

This is for anyone changing the addon itself. To play it, see the [README](README.md).

The folder has to be called `ForeverGames` inside `Interface/AddOns`. After changing anything the
addon ships, `./install.sh` copies it into the game, ready to `/reload`.

## Tests

```
./Tests/RunTests.sh
```

runs the tests with a stock `lua` (5.1), no game client needed. The engine is tested for real. The
window is clicked through against a stand-in for the client (`Tests/FakeClient.lua`) that draws
nothing: that catches mistakes in what the window does, not in how it looks.

Every game is also put through the same checks, a test of its own each (`EveryGame_<id>`, see
`Tests/EveryGame.lua`): the same seed deals the same game, the rules never ask the client for the
time or a random number, and what the game shows by name is in the locale. A game that lists its
moves (`moves`, see `Engine/Games.lua`) is played out at random from a few seeds as well: every
move it lists has to be legal and fit in a message, and the log has to replay to the same
position on another client. A new game is checked the moment it is registered.

A game the computer plays has it decide on a move at some of those positions, at every level:
it has to be a move the game takes, the same one every time from the same position, and deciding
mustn't change what it was shown. What the game tells the computer is held to that too: a guess
at a hidden position has to look from the seat exactly like what the seat sees, a quick copy has
to be a copy, and how good a position is has to stay well short of a win. Then the computer plays
a whole game against itself, and a game for more than two is played at a table of two people and
the computer, on two clients that talk to each other: their logs have to come out the same.

Words after it run only the tests whose names have one of them in:
`./Tests/RunTests.sh EveryGame_chess Codec`.

## Layout

- `Engine/` rules of play and the sync protocol. No WoW API in here, which is what makes it testable
  - `Codec.lua` wire format
  - `Random.lua` dice and shuffles that come out the same for every player
  - `Tables.lua` the one copy of a position everything uses, the computer included
  - `Grid.lua` boards of squares for the rules: squares and what they are called ("e4"), steps
    that stay on the board, the lines a rook or a bishop runs along, what is around a square or
    a knight's jump away, every four in a row, the longest line through a square, and spreading
    out from a square nearest first (Minesweeper opening a field, a marble's hops)
  - `Deck.lua` playing cards for the rules: a deck dealt the same for everyone, hands, the cards
    a player hasn't seen, and for trick-taking games which cards may be played to a trick and
    which one takes it, trumps and cards that count as another suit (Euchre's bowers) included
  - `Games.lua` game registry
  - `Daily.lua` the day's challenge: a game for one dealt from the date, the same for the whole
    guild, and the board of how everyone did, which goes round the guild channel
  - `Race.lua` races: a game for one played by two on the same deal, each on their own, the
    quicker time winning. What a run came to, and the ghost a game can send along with it
  - `Computer.lua` the computer: looks ahead through the moves a game lists with its own rules,
    as far as its level lets it, and picks the best. Counts what it looks at rather than
    seconds, so it plays the same on any computer, and thinks a little at a time so the client
    never stalls. Only ever sees what its seat may see, and guesses at the rest
  - `Match.lua` a match is its players and a log of moves, state is derived by replaying it
  - `Session.lua` challenges, moves, retries and resync, between two players or among several
  - `Presence.lua` who is online with the addon
  - `Rooms.lua` rooms for the games played by whoever turns up: who is in one, what is said in
    it on a guild or group channel, guests the host passes everything on to and from, and a
    queue that keeps it all under what the client lets an addon send. Nothing like a match:
    no log, nothing sent again, nothing kept. `Games/Sketch.lua` is the game to copy from. A
    game can stop for a fight (`fight`) and have its small window keep out of one (`calm`), see
    `Games/Trivia.lua`, whose questions are in `Lexicon/Trivia.lua`
  - `Phases.lua` the clock a game for a room is played to: which step it is at, since when and
    until when, the same on every client and for whoever comes in late, what being quick is
    worth, and who is ahead
  - `SectorMap.lua` worlds of rooms of different heights, the way Doom built its own: which
    sector a point is in, room to stand and steps to take, lines walked over or in reach, floors
    and ceilings that move, pictures that are animated, and things standing about that are in
    the way or can be walked over, or walk about by Doom's rules. What can be seen from where, what
    a shot hits and how far a sound carries. Maps are made in any Doom map editor and turned into
    Lua by `Tools/import_wad.py`, the sprites of the things in them too
  - `Actors.lua` things that go through states the way Doom's do: a frame of a sprite for so many
    tics, something done on coming to it, and what comes next. Monsters, fireballs and smoke, a
    weapon in the player's hands
- `Games/` one file per game: its rules and its view. `Games/Maps/` the sector maps
- `Transport.lua` addon messages, lockdown and online/offline detection
- `Links.lua` games linked in chat: the text that is sent, and the link it is shown as
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
  - `SlideGrid.lua` tiles that slide about on a grid, for games where what lies on the squares
    travels: it is told which tiles went where, where those that met became one and what turned
    up, and shows it, getting there at once when the next move comes before the last has
    finished. Tiles are tinted and written on, so they are sharp at any size. Played on by
    dragging across it
  - `NumberGrid.lua` a grid to write figures into, for puzzles solved with a pencil: thin lines
    between squares and heavy ones between boxes, a figure in a square or small ones pencilled
    into it, squares washed in a colour, a frame around the one the player is on, figures that
    pop in, squares that shake their head or light up one after the other. With it a pad of
    keys to write with, which say something small about themselves and can be dimmed or on
  - `Canvas.lua` a sheet to draw on with the mouse and to show a drawing on, at any size: lines
    in a handful of colours and widths, drawn over each other in the order they were made
  - `Party.lua` the pages a room is set up and played on, and the small window it can be put
    in for a corner
  - `Strips.lua` a screen to draw on a frame at a time, for a game that works out its own
    picture: columns, spans mapped onto a picture and blocks of colour, kept from one frame to
    the next so that only what changed costs anything
  - `SectorView.lua` what somebody standing in a sector map sees, drawn onto Strips the way Doom
    drew it: walls a column at a time nearest first, floors and ceilings a row at a time, the
    sky, things as sprites cut off by the walls in front of them, walls that are seen through,
    Doom's light and detail
- `Core.lua` wires it all together
- `Sounds/` cards, chips and dice
- `Tools/` scripts that made the textures in `Images/`
- `ForeverGames_Freedoom/` an addon of its own, loaded when a game of Freedoom is first shown:
  its maps, Run among them, the pictures they are drawn with and its status bar, too much to load
  at every login. Made by `Tools/import_freedoom.sh` from `freedoom1.wad`; `install.sh` and `build.sh` take it along

## Adding a game

Add a file to `Games/`, list it in `ForeverGames.toc` and call `private.Games.Register` with the
functions described at the top of `Engine/Games.lua`. A game has two halves:

- **Rules**: `newState`, `turn`, `validate`, `apply` and `result`, pure functions over a state
  table. A move is a short string the game defines (letters, digits and `-+.=_`). `apply` can
  return a table saying what the move did, which the view gets back to animate from. `turn`
  decides who is next and needn't alternate: Reversi hands the turn straight back when a player
  has nowhere to go. A game on a board of squares has `Engine/Grid.lua` for them, one with
  playing cards `Engine/Deck.lua`, and `Engine/Tables.lua` copies a position
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
- **Daily**: a game that can be played alone can be the day's challenge (`daily`): the rules
  everyone plays it by (`rules`) and what a game of it came to once it is over (`score`), points
  or with `lower` and `time` the seconds it took. The engine deals it from the date, keeps it to
  one go a day with nothing taken back, and puts it on the guild's board. Every such game is
  checked to deal the same for everyone, and another way the next day
- **Race**: a game for one that is timed (`clock`) and keeps a best time (`record`) can be raced
  with nothing more from it. Both players' matches go by the same id, which deals them the same,
  and the time a run is raced for is the `lower` record the game keeps for it: a run it keeps
  none for didn't finish. The challenge, delivery, the result and the window are the engine's,
  see `Engine/Race.lua`. A game can send a ghost of the run along with the time (`ghost`, with
  `every` the seconds between samples): its view is handed `view.race`, whose `sample(text)`
  keeps where the player is now and whose `ghost` is the rival's samples, one every `every`
  seconds of their run, to show while the player races them. A game whose every run by the same
  rules is the same course, whatever its deal, can also say how such a run gets to the end
  (`ghost.course(options)`, its log): the run that set the player's best can then be sent as the
  challenge itself (`Session:BestToRace`, `best` in the setup), their side of the race over
  already. Every game that can be raced is checked to deal a race the same on the rival's client
- **Together**: a game with `together = true` has no turns and no `turn`. Everyone moves whenever
  they like, also while the others are offline, and `view.canMove` is true for as long as the
  game lasts. What the players did at the same moment, or apart, ends up one after the other in
  some order, so `validate` and `apply` must come out right whichever it is, and a move that is
  no longer legal by the time its turn comes (somebody else got there first) is dropped
- **Computer**: `computer = {}` lets the game be played against the computer, which needs
  nothing more than `moves`: it looks ahead through them with the game's own rules, and judges
  where it gets to by playing on from there at random. It plays far better told how good a
  position is (`evaluate`), which moves to look at first (`priority`, captures in chess) and
  which ones it can't stop looking after (`noisy`), what a position is called so it can tell it
  has been there before (`key`), and a quicker way to copy one (`copy`). A game with secrets
  says what could be behind what a seat sees (`guess`): the computer plays against a few such
  guesses at once. A game that needs another way of thinking altogether does its own (`think`),
  with the engine's search to hand: Backgammon weighs every roll the other side could throw,
  Battleship counts the ways a ship could lie, Words builds its words a letter at a time. Each
  level (`levels`) can look further or less far and slip more or less often, and is given a
  budget of positions to look at, so that a move takes about as long in every game. See
  `Engine/Computer.lua`, and `Games/ConnectFour.lua` for a game that tells it everything. A game
  for more than two where a player can be put out by the others (`beaten`) is over for the
  player then, the computer doesn't play on among itself. A game for more than two the computer
  plays can have it at a table of people too, with nothing more from the game
- **View**: `createView(stage)` builds the game's widgets in the frame it is given and returns an
  object with `Layout(width, height)` and `Update(view)`. It can draw however it likes, games
  played on a grid get most of it from `GUI/Board.lua`. `view.played` is the move to animate,
  when there is one worth showing

A game can let whoever sets it up change some of its rules with `options`: each has an `id`, a
`name`, a `default` and the `choices` it can be set to (leave those out for something that is on
or off). `newState` is handed what they are all set to as its third argument, and keeps what the
rules need of it in the state. The wizard, the challenge and the rematch are the engine's: the
wizard shows a few choices as buttons side by side, and an option of many (more than five that
don't fit in two rows, as Freedoom's maps) as a dropdown (`Widgets.Dropdown`). See
`Games/Words.lua`. An option marked `alone` is only offered for a game played alone, of one that
can be played with others too, and never sent with a challenge.

Give the game a `genre` so it can be found in the new game wizard: one that is there already
(`strategy`, `casual`, `dice`, `cards`, `words`, `solo`) or a new one, with its name in the locale file as `genre_<name>`.

Everything else is the engine's and the same for every game: challenges, gathering the players
of a game for more than two, turn notifications, saving, delivery, resigning, and for games of two
that ask for them draw offers (`draws = true`) and the move list with stepping back through the
game (`history = true`), as quick at the end of a long game as at its start: the engine keeps a
position every few moves on the way. Showing the player the moves they missed one after the
other is the engine's too: the view is handed each with `played` and `catching`, and a view that
takes its time over a move says so with `Busy`, which is waited for. And the games against the computer: setting them up, letting it think,
taking moves back, how your games against it went, and seating it at a table of people.

`Games/TicTacToe.lua` is the smallest example, `Games/Chess.lua` uses all of it. For a game
where pieces are placed look at `Games/ConnectFour.lua` and `Games/Reversi.lua`, at
`Games/Checkers.lua` for moves made in several steps, and at `Games/ChineseCheckers.lua` for more
than two players and a board that isn't a grid. `Games/Mancala.lua` keeps counts of things
that are all alike, seeds in pits, and draws them as heaps of their own that are carried and
swept from place to place (`GUI/Heaps.lua`). `Games/Backgammon.lua` rolls dice and stacks
its pieces, `Games/CrazyEights.lua` deals cards and keeps hands hidden. `Games/Battleship.lua`
hides what a player chose rather than what they were dealt, on two boards at once, with pieces
several squares long. `Games/Solitaire.lua` is for one, on a card table (`GUI/CardTable.lua`)
that does all of its moving and animating. `Games/Minesweeper.lua` is for one as well, with a
difficulty to pick before it begins (`options`), a clock and a best time that the engine keeps
(`clock`, `record`), a way to lose (`winner = 0`), and moves that are shown spreading across
the board with `Widgets.Animator` and `GUI/Effects.lua`. `Games/2048.lua` has a board the
player picks the size of, a best score that is kept, and tiles that slide
and become one on a `GUI/SlideGrid.lua`: what its `apply` returns says everything that moved.
`Games/Sudoku.lua` is played on a grid of numbers
(`GUI/NumberGrid.lua`). It makes its own puzzles, which takes a solver that has to be quick: a
game is put together again from its moves every time it is loaded, so `newState` runs often.
`Games/Fourtiles.lua` is played alone or by two together, with no turns (`together`), and has
its puzzles made ahead of time by a tool.
`Games/Wormcraft.lua` has physics: a move is everything a player did in a turn, tick by tick,
and every client plays it out again in whole numbers only, so that every grenade bounces the
same everywhere. Its view plays out again whichever turn of somebody else's it is handed, to
show the others what happened.
`Games/Warcraftstein.lua` isn't played in moves at all: its view walks the player through the
monastery many times a second and draws what they see, walls a column at a time and floor and
ceiling a row at a time, and the engine only ever hears who went in, and that the way out was
found or that they died looking. What a class is in there, what its talents do and what the
Crusade is like are tables of numbers in the file (`CLASSES`, `TALENTS`, `FOES`).
`Games/Freedoom.lua` is played the same way, on a sector map: the map and its view are the
engine's, and the game is what the lines of a Doom map do (`SPECIALS`), what picking things up
gives (`PICKUPS`), which doors need which key (`LOCKS`), the monsters and barrels and how they
live (`MONSTERS`), the player's weapons (`GUNS`), how the player walks and the status bar.
Another game on a sector map needs only its own of those, and a map. Its maps are an addon of their
own, loaded on demand, which the game names (`addon`): a game that does is only offered, and a
challenge to it only taken up, while that addon is installed and switched on.

The round pieces, the star Chinese Checkers is played on and the icons of the games played with
them are drawn by `Tools/make_discs.py`, the backgammon table and the noughts and crosses by
`Tools/make_tables.py`, the sea, ships and pegs of Battleship by `Tools/make_fleet.py`. The cards,
dice and sounds are converted by `Tools/convert_kenney.py`, and what a card table needs besides
(a blank card, the outline of a place for one, the icon of Solitaire) is drawn by
`Tools/make_cards.py`. The tiles, flags and mines of Minesweeper are drawn by
`Tools/make_minesweeper.py`. The tile 2048 tints and its icon are drawn by `Tools/make_2048.py`.
Tetris's squares, its icon and its sounds are made by `Tools/make_blockfall.py`.
The puzzles of Fourtiles, its icon and its tiles are made by `Tools/make_fourtiles.py`.
The letters on the tiles of Fourtiles and Words are drawn from Lexend by `Tools/make_lettering.py`:
the client won't write in a font an addon brings, so they are pictures.
The icon of Sudoku is drawn by `Tools/make_sudoku.py`, the walls, floor and
ceiling of Warcraftstein 3D, everyone and everything in it and its icon by
`Tools/make_warcraftstein.py`. The squads of Wormcraft, what they throw, its islands and its icon
are drawn by `Tools/make_wormcraft.py`. The icons of Where in Azeroth, Sketch and Trivia are drawn
by `Tools/make_icons.py`. Freedoom's maps, the pictures they are drawn with, the
sprites of what lies about in them, the status bar and the icon are taken from `freedoom1.wad` by
`Tools/import_freedoom.sh`, with `Tools/import_wad.py`, which takes any map of a Doom WAD. Run is
written rather than drawn, by `Tools/make_run.py` with `Tools/mapkit.py`, which builds a Doom map
from sectors given as outlines, lines, pictures and nodes and all, into a WAD of its own.
`Tools/render_view.lua` draws the view from any spot of a sector map outside the game, as a
picture to look at (`Tools/ppm_to_png.py` makes PNGs of them).
