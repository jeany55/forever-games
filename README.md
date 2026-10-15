# Forever Games

A World of Warcraft Forever addon for playing classic games against your friends and guildies, at
your own pace. Make a move, go pull a boss, come back later. Or against the computer, whenever
nobody is around.

Games so far: Tic Tac Toe, Chess, Connect Four, Reversi, Checkers, Battleship, Backgammon,
Chinese Checkers, which is for up to six, and Crazy Eights, which is too. Wormcraft, artillery for
up to four the way Worms played it. And Solitaire, Minesweeper
Sudoku, 2048, Warcraftstein 3D and Freedoom, for when nobody is around. And Fourtiles, a word puzzle to
solve on your own or the two of you together, both at once.

## Usage

- `/fg` (or the minimap button) opens the window. The top shows how many guildies and friends are
  online with the addon, checked at login, when the window opens and when you press Refresh
- **New Game** walks you through picking a game and an opponent. Type in the search box, or pick
  a kind of game or how many are playing, to narrow the list down. Click the star on a game to
  keep it at the top, the rest are listed by name. The list scrolls with the mouse wheel and
  fits as many games next to each other as the window has room for
- The second step is who to play, and how. Whoever you played last is at the top, online or not,
  then your guildies and friends who are online with the addon. Type to narrow the list down, or
  type the name of anyone else. Next to it is what the game lets you change about its rules: what
  the bonuses in Words with Warcraft are worth, whether taking is compulsory in Checkers, which
  side you play. Whoever you challenge sees what you changed before they accept, and the next
  game of that kind starts out set the same way
- Who plays is a table across the top: a card for your seat, one for each player picked, and the
  seats still open. Click players in the list, or type a name and press Enter, and they sit in
  the next open seat; a full table grows for them as far as the game goes. **Seats** sets how
  many there are, among the numbers the game is for, and × on a seat leaves it open again. A
  game for more than two begins once everyone has accepted, and it is off if one of them
  declines. Whoever resigns leaves the others to play on
- Every game for two or more can be played against the computer, which the game's card shows
  with a cog: **+ Computer** on an open seat sits it there. Click how well it plays on the seat
  for another difficulty: **Easy** doesn't look far ahead and makes mistakes, **Medium** thinks
  a few moves ahead and seldom slips, **Hard** looks as far ahead as it can and never slips, and
  each seat has its own. Pointing at it shows how your games against it went. A table of you and
  the computer begins at once,
  nothing about it is sent anywhere, and it waits for you: the computer only thinks while the
  game is on screen, and takes a moment over its move so you see it made. **Take Back** takes
  back your last move and the computer's answer to it, in the games where that gives nothing
  away (not where cards or a hidden fleet were turned up, nor where the dice were rolled for
  it). **Offer Draw** works too: it takes the draw when it is no better off playing on.
  **Play Again** sets the same game up again, the other way round. The next game of that kind
  starts out against the computer again, set the same way, and so does `/fg play <game>`
- In a game for more than two the computer can sit at the table with the people you pick, in
  the seats they leave open. A player picked when the table is as big as it goes takes a seat
  of the computer's. It is a challenge like any other, and the others are told which seats are the computer's. Your client
  plays them, whether or not the window is open (not in the middle of a fight), and sends its
  moves to the others like your own, so they wait on you being online. If you resign, the next
  person still in the game takes the computer over. Once every person has left, the game is
  over. Players on an earlier version are told the challenge is from another version
- The games you play alone have a challenge every day, which their card shows with a pocket
  watch: click it for **Today's Challenge**. Everyone in your guild who plays it that day gets
  the same game: the same deal of Solitaire, the same field of mines (a middling one), the same
  Sudoku, the same tiles turning up in 2048, the same Fourtiles and the same monastery to find
  the way out of. You get one go a day, played to the end with nothing taken back, and the
  **Guild Board** beside it shows how everyone did: the best score, or the quickest time, first.
  What you made of it goes round the guild when you finish, and opening a challenge asks the
  guild how they did. A new one is dealt at midnight UTC. `/fg daily <game>` goes straight to it
- The games you play alone against the clock (Minesweeper, Sudoku, Warcraftstein 3D and
  Freedoom) can be raced: pick somebody on the second step, as you would for any game, and
  **Challenge to a Race**. You each get the same deal, set up the way you chose: the same field
  of mines, the same puzzle, the same monastery or map. You start at once and they start when
  they take it up, each playing on your own whenever you like, online together or not. Nothing
  is taken back, and **Give Up** counts as not finishing. When a run is over its time goes to
  the other, and the quicker one wins: a run that didn't finish (a mine, a death, a Sudoku with
  a hint in it) loses to any that did. The race shows both times beside the game, the one to
  beat while you play, and who won once both are in. **Race Again** deals another. Pick nobody
  and the game is yours alone, as ever
- A game that can be played alone or together, like Fourtiles, is played alone if you pick
  nobody: **Play Alone**. Played together it has no turns. Both of you play whenever you like,
  online together or not, and what each of you did is put together when you next meet
- A game for two doesn't need anyone picked: **Link in Chat** puts `[Forever Games: Chess]` where
  you type, to send to your party, your guild or anyone else. Everyone with the addon sees it
  as a link, and the first to click it plays you, by the rules you set. The game stays open for
  an hour
- The games that are played in a room by whoever turns up are in the list with the rest, under
  **Party**. Picking one asks who the room is for, the way any game asks who you play: your
  guild, the group you are in, or nobody but the players you invite. How the game is played is
  set next to that, and under it are the rooms others have open, to join instead. Everyone on
  the room's channel with the addon is told, and can come and go while it lasts
- In a room, its host can invite a player by name, or put a link to the room in chat: whoever
  clicks it comes in, in the guild or not. A few players from outside the guild or group can be
  in a room at once. **Make Small** puts the game in a small window of its own for a corner of
  the screen while you do something else, and it comes back whole when it is your turn. The
  room is gone when its host leaves, and nothing of it is kept
- **Sketch** is the first of them: one of you is given three things to pick from and draws one,
  everyone else types what they think it is. The sooner you get it the more it is worth, and
  whoever drew gets something for everyone who did
- **Trivia** is a quiz the way Kahoot plays one, for a raid while it waits. The host asks and
  everyone gets the same question at once, with two to four answers marked by raid icons. Click
  one, or press 1 to 4 with the cursor over the game. A right answer is worth up to 1000, less
  the longer you took, and a little more for every right answer in a row before it. Once the time
  is up, or everyone answered, the right one lights up with how many picked each. Which questions
  (General, Warcraft from the Third War to the Lich King, or both), how many and how long you
  have for each are set when the room is opened. The quiz stops whenever the host goes into
  combat, and the question that was up counts for nothing; it goes on by itself a few seconds
  after the fight, and the host can **Pause** and **Go On** by hand too. Made small, its window
  hides while you fight. The host doesn't ask what it asked lately, from one night to the next
- A game for one has nobody to pick and begins as soon as you choose it, or with `/fg play`
  (which plays a game for more against the computer).
  One with something to set up, like how hard Minesweeper is, asks for that first, and
  `/fg play` goes by what you said last.
  It waits for as long as you like, **Undo** takes back a move, and as many more as you press
  it for, **Start Another** swaps it for a new one and **Give Up** takes it off your list
- Come back to a game the others moved on in while you were away, and you see what they did
  before the game as it stands: each of their moves made on the board in turn, the dice thrown
  and the turns played out, wherever you left off, after a /reload too. **Skip** or Space goes
  straight to the game as it stands, and looking back through the game is up to you from then
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
- In Fourtiles, click one to four of the twenty tiles to spell a word and press **Enter**. A
  word is worth 1, 2, 4 or 8 points by how many tiles it takes, and the five words the tiles
  were cut from, the Fourtiles, are worth 40 more once you have them all. **Shuffle** lays the
  tiles out another way. With the five found and the rank of Master reached, at 100 points,
  **Call It Done** ends the game, and until then there are more words to find. The keys work
  while the cursor is over the game: Enter, Backspace, and Space to shuffle
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
- Wormcraft is for up to four, each with a squad on an island. Against the computer you play one
  to three squads of its own, Easy, Medium or Hard: Easy throws things more or less your way,
  Hard hardly ever misses and walks to where it can hit you from. Once your squad is gone the
  game is lost, whoever of the computer's is left. Everybody picks a class first,
  and every class has one thing of its own: a warrior's Charge, a mage's Blink, a priest's
  Prayer of Healing. Then you take turns: walk one of your squad about with the arrow keys or A
  and D, aim with up and down or W and S, and hold space to wind up a shot, longer for more
  power. Enter jumps and Backspace flips backwards. Pick what to fire under the island, or with
  Q and E: fireballs blow with the wind, grenades bounce until their fuse (1 to 5) burns down,
  and a blizzard or a kodo comes down wherever you click. After firing you have three seconds to
  run. Your turn is ready as soon as it is yours, and the clock only starts once you move:
  Tab picks somebody else of your squad before that. Everybody is a level higher every round
  and learns more to fire, crates fall from a zeppelin between turns with something rarer in
  them, and from a round you pick when you set the game up the sea rises. The turns the others
  had since you last looked are played out again for you when you open the game, space skips
  them. The mouse wheel zooms in, and dragging moves the island about. A turn that isn't over
  when you leave the game is begun again when you come back
- Solitaire is Klondike, dealt out in front of you. Drag a card where it should go, with
  whatever lies on it, or just click it: it goes home if it can and to the first column that
  will have it if not, and a right click only ever sends it home. Click the stock to turn a
  card, and again when it is empty to go through it once more. When nothing is left face down,
  **Finish** plays the rest out for you
- Minesweeper asks how hard you want it before it begins: a small field with ten mines, a
  bigger one with forty, or a wide one with ninety-nine. Left click a square to open it, the
  first one is always safe. Right click to plant a flag on a square you think is mined, and
  again to take it away. Once a number has its flags, a left or a middle click on it opens the
  rest around it. Point at a number to see which squares it is still about. The clock starts
  with your first click, and your best time at each difficulty is kept
- In 2048, push the tiles with the arrow keys or W, A, S and D while the cursor is over the
  game, drag across the board, or click the arrows next to it. Two tiles worth the same that
  meet become one worth both. Making 2048 wins the game but doesn't end it: it goes on until
  nothing moves, and your best score and biggest tile are kept for every size of board. The
  board is four by four unless you pick three or five when you set the game up, and on three
  the tile to make is 256
- Sudoku asks how hard a puzzle you want before it begins, from Easy to Expert, and whether
  wrong digits should be pointed out as you write them. Click a square, or move to it with the
  arrow keys, and write with the digits on your keyboard or the keys next to the grid: each key
  says how many of its digit are still missing. The same digit again takes it back out, and so
  does Backspace. **Notes** (or N, or the space bar) switches to pencilling small digits into a
  square, which are tidied away as the digits they are about get written. **Hint** fills in
  the square you are on, though a game with a hint in it doesn't count for your best time.
  The keys are only the game's while the cursor is over it, and never in combat
- Warcraftstein 3D is the Scarlet Monastery, seen from inside it: fight your way through the
  graveyard, the library and the cathedral to the armory, where Herod guards the portal out.
  It stays shut until he falls. You start in a chapel the Crusade won't follow you into, where
  you get your health back but can't fight: go back to it whenever you need to. You go in as the class of the character you are on (press
  space), or as any other you pick: each strikes its own way, from a warrior's sword to a
  mage's fireballs, and can do one thing more, from a rogue's stealth to a shaman's totem.
  Every kill is worth experience, every level a talent point, and every class has three trees
  of talents to spend them in (press N). Soldiers, monks, adepts who cast from afar, defenders
  behind their shields and the phantasms of the graveyard are in the way. Hold W and S or the
  up and down arrows to walk, A and D or the left and right arrows to turn, Q and E to step
  sideways, space to strike and F for what your class can do, with the cursor over the game.
  Or hold the right mouse button and turn with the mouse, with A and D to step sideways. With
  the cursor anywhere else, or the talents open, the monastery stands still. Potions on the
  floor are drunk by walking over them, red for health and blue for mana, rage or energy. Pick
  how many rooms there are when you set the game up, your best time for every size is kept.
  Where you are isn't, and nor are your talents: a game you come back to after logging out
  begins at the start again
- Freedoom is the first episode of [Freedoom](https://freedoom.github.io), the free Doom, drawn
  the way Doom drew it: pick one of its nine maps when you set the game up and fight your way to
  its exit, against the clock; your best time on every map is kept. Every map is finished with
  Doom's screen for it, what you killed, picked up and found counting up, your time to the
  hundredth and how it stands. Play a map again and the ghost of your best run on it runs beside
  you, a glowing marine; race a friend on it and theirs does, with their name over its head,
  going where they went when they did. It sounds as Doom does too: guns, doors, lifts and
  monsters, heard from where they are and only as far as Doom heard them. Ghosts make no sound. Teleports, lifts, stairs that
  build themselves, doors that open on a switch or a shot, and floors of slime that hurt. Its
  zombies, shotgun guys, imps, demons, spectres, lost souls and barons hear your shots from the
  rooms around and come for you, and barrels go up when they are shot. Fight back with your fists, the pistol, and
  the chainsaw, shotgun, chaingun, rocket launcher, plasma gun and BFG when you find them, the
  rockets, plasma and the BFG's ball flying as Doom's did (a rocket up close hurts you too);
  Ctrl, F or the left mouse button fires, 1 to 7 changes weapon. Walk over health, armour, ammunition, weapons and keys to pick them up,
  by Doom's rules, under Doom's status bar; a door that needs a key says which. Space opens doors
  and presses switches, Shift runs, and the rest of the keys are Warcraftstein's. Tab shows what
  drawing a frame costs, F5 switches to Doom's low detail, which draws half as many columns
- `/fg challenge <player> [game]` challenges someone, or use the box at the bottom of the window. Leave
  the name empty to challenge your target

- `/fg options` (or a right click on the minimap button) opens the options, which are also in the
  game's own settings under AddOns: whether your turn coming up is shown, heard or both, whether
  that happens in combat, and whether it waits until you are out of an instance; the games' own sounds; whether anyone can challenge
  you or only friends and guildies; the minimap button, and how big the window is drawn
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

### Layout

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
  its maps, the pictures they are drawn with and its status bar, too much to load at every login.
  Made by `Tools/import_freedoom.sh` from `freedoom1.wad`; `install.sh` and `build.sh` take it along

### Adding a game

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
  seconds of their run, to show while the player races them. Every game that can be raced is
  checked to deal a race the same on the rival's client
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
rules need of it in the state. The wizard, the challenge and the rematch are the engine's. See
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
than two players and a board that isn't a grid. `Games/Backgammon.lua` rolls dice and stacks
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
The puzzles of Fourtiles, its icon and its tiles are made by `Tools/make_fourtiles.py`.
The letters on the tiles of Fourtiles and Words are drawn from Lexend by `Tools/make_lettering.py`:
the client won't write in a font an addon brings, so they are pictures.
The icon of Sudoku is drawn by `Tools/make_sudoku.py`, the walls, floor and
ceiling of Warcraftstein 3D, everyone and everything in it and its icon by
`Tools/make_warcraftstein.py`. The squads of Wormcraft, what they throw, its islands and its icon
are drawn by `Tools/make_wormcraft.py`. Freedoom's maps, the pictures they are drawn with, the
sprites of what lies about in them, the status bar and the icon are taken from `freedoom1.wad` by
`Tools/import_freedoom.sh`, with `Tools/import_wad.py`, which takes any map of a Doom WAD.

## Credits

The map, walls, floors, sky, sprites, status bar and messages of Freedoom are from [Freedoom](https://freedoom.github.io) 0.13.0
by the contributors to the Freedoom project, used under its BSD licence. See
`ForeverGames_Freedoom/COPYING.txt` and `ForeverGames_Freedoom/CREDITS.txt`.

The chess pieces are from [ChessCraft Creative Commons](https://gitlab.com/zulban/chesscraft-creative-commons)
by Zulban, used under CC BY-SA 4.0. See `Images/Chess/README.md`.

The playing cards, the dice and the sounds are from the
Boardgame Pack by [Kenney](https://www.kenney.nl), released into the public
domain (CC0).

The words the puzzles of Fourtiles are cut from were picked with the help of
[SCOWL](http://wordlist.aspell.net) by Kevin Atkinson, whose lists say how common a word is.

The tiles of Fourtiles and Words are written in [Lexend](https://github.com/googlefonts/lexend)
by The Lexend Project Authors, used under the SIL Open Font License 1.1. See
`Images/Lettering/Lexend-OFL.txt`.
