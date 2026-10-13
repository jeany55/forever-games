# Forever Games

A World of Warcraft Forever addon for playing classic games against your friends and guildies, at
your own pace. Make a move, go pull a boss, come back later.

Games so far: Tic Tac Toe and Chess.

## Usage

- `/fg` (or the minimap button) opens the window. The top shows how many guildies and friends are
  online with the addon, checked at login, when the window opens and when you press Refresh
- **New Game** walks you through picking a game and an opponent
- Drag the corner of the window to make it any size, the board grows with it. **Focus** hides
  everything but the game you are looking at
- In chess, drag a piece or click it and then where it goes. Click a move in the list, use the
  buttons under it or scroll the mouse wheel over the board to look back through the game.
  **Offer Draw** goes out with your next move, and your opponent turns it down by playing on
- `/fg challenge <player> [game]` challenges someone, or use the box at the bottom of the window. Leave
  the name empty to challenge your target

- `/fg log` shows recent activity (messages sent and received, with results). The full log is saved
  per character in the `ForeverGames.lua` saved variables file on logout or `/reload`

Both players need the addon. There is no server: moves travel directly between the two players as
addon whispers, so they are delivered when both are online and outside instances that block addon
communication. Anything that can't be delivered right away is kept and sent later.

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
  - `Games.lua` game registry
  - `Match.lua` a match is a log of moves, state is derived by replaying it
  - `Session.lua` challenges, moves, retries and resync
  - `Presence.lua` who is online with the addon
- `Games/` one file per game: its rules and its view
- `Transport.lua` addon messages, lockdown and online/offline detection
- `GUI/` main window, new game wizard and toast
  - `Board.lua` a board of squares and pieces for games to draw on: any size, drag and drop,
    target marks, gliding pieces
- `Core.lua` wires it all together
- `Tools/` scripts that made the textures in `Images/`

### Adding a game

Add a file to `Games/`, list it in `ForeverGames.toc` and call `private.Games.Register` with the
functions described at the top of `Engine/Games.lua`. A game has two halves:

- **Rules**: `newState`, `turn`, `validate`, `apply` and `result`, pure functions over a state
  table. A move is a short string the game defines (letters, digits and `-+.=_`). `apply` can
  return a table saying what the move did, which the view gets back to animate from
- **View**: `createView(stage)` builds the game's widgets in the frame it is given and returns an
  object with `Layout(width, height)` and `Update(view)`. It can draw however it likes, games
  played on a grid get most of it from `GUI/Board.lua`

Everything else is the engine's and the same for every game: challenges, turn notifications,
saving, delivery, resigning, and for games that ask for them draw offers (`draws = true`) and
the move list with stepping back through the game (`history = true`).

`Games/TicTacToe.lua` is the smallest example, `Games/Chess.lua` uses all of it.

## Credits

The chess pieces are from [ChessCraft Creative Commons](https://gitlab.com/zulban/chesscraft-creative-commons)
by Zulban, used under CC BY-SA 4.0. See `Images/Chess/README.md`.
