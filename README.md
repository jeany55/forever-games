# Forever Games

A World of Warcraft Forever addon for playing classic games against your friends and guildies, at
your own pace. Make a move, go pull a boss, come back later.

Games so far: Tic Tac Toe and Chess.

## Usage

- `/fg` (or the minimap button) opens the window. The top shows how many guildies and friends are
  online with the addon, checked at login, when the window opens and when you press Refresh
- **New Game** walks you through picking a game and an opponent
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

runs the engine tests with a stock `lua` (5.1), no game client needed.

### Layout

- `Engine/` rules of play and the sync protocol. No WoW API in here, which is what makes it testable
  - `Codec.lua` wire format
  - `Games.lua` game registry
  - `Match.lua` a match is a log of moves, state is derived by replaying it
  - `Session.lua` challenges, moves, retries and resync
  - `Presence.lua` who is online with the addon
- `Games/` one file per game
- `Transport.lua` addon messages, lockdown and online/offline detection
- `GUI/` main window, new game wizard and toast
- `Core.lua` wires it all together

### Adding a game

Add a file to `Games/`, list it in `ForeverGames.toc` and call `private.Games.Register` with the
functions described at the top of `Engine/Games.lua`. `Games/TicTacToe.lua` is the reference. A
move is a short string the game defines (letters, digits and `-+.=_`), everything else (challenges,
turn notifications, saving, delivery) is handled by the engine.
