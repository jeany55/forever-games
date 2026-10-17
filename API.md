# Writing a game for Forever Games

A game for Forever Games doesn't have to be part of Forever Games. You can put one in an addon of
your own, and anyone who installs that addon next to Forever Games gets it in their list of games
the next time they log in. It is played like the games that come with the addon: challenges,
turns that wait while a player is offline, rematches, How to play, and, if the game supports
them, the computer, races and the day's challenge. Nobody has to change Forever Games or tell it
about your game.

Freedoom and Where in Azeroth are written this way. Their code is in `ForeverGames_Freedoom` and
`ForeverGames_Where`, and uses only what this page describes. There is a smaller example in
[`Examples/ForeverGames_Pig`](Examples/ForeverGames_Pig): Pig, a dice game for two to four
players with a computer opponent, in about 240 lines. This guide goes through it file by file.

- [How it works](#how-it-works)
- [The files of a game](#the-files-of-a-game)
- [The rules](#the-rules)
- [The view](#the-view)
- [Registering the game](#registering-the-game)
- [Testing](#testing)
- [Trying it in the game](#trying-it-in-the-game)
- [Playing with other people](#playing-with-other-people)
- [Settings](#settings)
- [Large content: maps, pictures, sounds](#large-content-maps-pictures-sounds)
- [Packs of places](#packs-of-places)
- [What ForeverGamesAPI has](#what-forevergamesapi-has)
- [Rules for a game addon](#rules-for-a-game-addon)

## How it works

Your addon's `.toc` says it depends on Forever Games:

```
## Dependencies: ForeverGames
```

The client then loads your addon after Forever Games. By then the global `ForeverGamesAPI` exists
([`Engine/API.lua`](Engine/API.lua)), and your files call `ForeverGamesAPI.Games.Register` with the
game. Forever Games sets up its window and loads the player's matches when they log in, which is
after every addon has loaded, so your game is in the registry before anything looks for it.

A game has two halves:

1. The rules are plain functions over a table that holds the position. They don't call the WoW
   API. Every player's client replays the moves through them to work out the position, so they
   have to give the same answer everywhere.
2. The view draws a position into a frame the window gives it, and turns the player's clicks
   into moves.

Forever Games handles everything else: who is playing, whose turn it is, sending moves, saving
matches, resigning, rematches and the list of games.

## The files of a game

```
ForeverGames_Pig/
  ForeverGames_Pig.toc
  Locales/enUS.lua
  Pig.lua
  Tests.lua
```

The folder and the `.toc` must have the same name. Calling it `ForeverGames_<Name>` and giving it
`## Group: ForeverGames` puts it under Forever Games in the AddOns list.

### The .toc

```
## Interface: 16001
## Title: Forever Games: Pig
## Notes: Pig, the dice game, for Forever Games. An example of a game in an addon of its own
## Author: Jeany
## Version: 1.0.0
## Dependencies: ForeverGames
## Group: ForeverGames

Locales\enUS.lua
Pig.lua
```

Don't make the addon `LoadOnDemand`. Its game has to be registered at login to show up. If the
game needs a lot of data, put that data in a second addon that is loaded on demand (see
[Large content](#large-content-maps-pictures-sounds)).

List the strings first, so they are there when the game file reads them. `Tests.lua` isn't
listed: the game client never loads it.

### Strings

Everything the players read goes through Forever Games' locale. `ForeverGamesAPI.Locale` gives
you a table to write your strings into:

```lua
local L = ForeverGamesAPI.Locale("enUS", true)

L["game_pig"] = "Pig"
L["game_pig_description"] = "Roll as often as you dare, but a one loses everything you rolled this turn. First to the target wins."
L["pig_howto_goal"] = "Be the first to bank as many points as the target."
L["pig_roll"] = "Roll"
```

The second argument says this is the language to fall back on, so these strings are used
wherever a language has no translation. A default never replaces a string that already exists.
Start every key with your game's id so that it can't clash with Forever Games' strings or another
game's.

A translation goes in a file of its own. `Locale` returns nil when the language isn't the
client's:

```lua
local L = ForeverGamesAPI.Locale("deDE")
if not L then
  return
end
L["pig_roll"] = "Würfeln"
```

Write all of a language's strings straight after asking for it, before calling `Locale` again.
This is how AceLocale works.

Your game reads the strings back from `ForeverGamesAPI.L`, which also has Forever Games' shared
strings. These are the ones a game commonly uses:

| Key | Text |
|---|---|
| `howto_goal` | The aim |
| `howto_turn` | A turn |
| `howto_end` | How it ends |
| `howto_controls` | Controls |
| `howto_scoring` | Scoring |
| `genre_casual`, `genre_strategy`, `genre_dice`, `genre_cards`, `genre_words`, `genre_solo`, `genre_party` | The genres the wizard filters by |
| `err_not_your_turn`, `err_invalid_move` | What the player is told when a move is refused |

The window shows an error code from `validate` as `L["err_" .. code]`, and the `detail` of a
result as `L["result_" .. detail]`. If your game has codes of its own, add those strings too, for
example `L["err_pig_nothing_to_hold"]`.

## The rules

Pig keeps the whole position in one table:

```lua
local function newState(seats, random, rules)
  local scores = {}
  for seat = 1, seats do
    scores[seat] = 0
  end
  return { scores = scores, turn = 1, pot = 0, target = rules.target, out = {} }
end
```

`seats` is how many are playing this match. `rules` has the value of every option, here the
`target` option. `random` is for a game that deals or rolls at the start.

A move is a short string that your game defines. Pig has two: `"r"` to roll and `"h"` to hold.
Moves are sent between clients in addon messages, so keep them short and use only letters,
digits and `-+.=_`.

`validate` says whether a seat may make a move, and gives an error code if not:

```lua
local function validate(state, seat, move)
  if seat ~= state.turn then
    return false, "not_your_turn"
  end
  if move == ROLL or (move == HOLD and state.pot > 0) then
    return true
  end
  return false, "invalid_move"
end
```

`apply` makes a move that has been validated. It changes the state in place, and can return a
table describing what happened, which the view receives as `view.played`:

```lua
local function apply(state, seat, move, random)
  if move == HOLD then
    -- bank the pot and pass the turn
    ...
    return { held = true }
  end
  local roll = random:Roll(6)
  ...
  return { roll = roll }
end
```

The die comes from `random`, which the engine passes in. It is seeded from the match and the
moves made so far, so every client rolls the same number. This is the only place a game may get
chance from. Calling `math.random`, `time`, `GetTime` or similar inside the rules would give each
client a different position, and the tests fail any game that does.

`result` returns nil while the game is still on, and `{ winner = seat }` (or `{ winner = 0 }` for
a draw) once it is over. `turn` returns the seat whose move it is. A game for more than two also
needs `drop`, which removes a player who resigned so that the others can play on.

`moves` lists the legal moves in a position. It is optional, but with it the tests can play your
game out at random, and the computer can play it with no other help.

### The computer

`computer = {}` is enough for a game that has `moves`. The engine searches ahead with your rules.
A game with a simple strategy can decide its moves itself with `think` instead, as Pig does:

```lua
computer = {
  takeback = false,
  think = function(state, seat)
    local pot = state.pot
    if pot > 0 and (pot >= COMPUTER_HOLDS_AT or state.scores[seat] + pot >= state.target) then
      return HOLD
    end
    return ROLL
  end,
},
```

`takeback = false` stops the player from taking a move back after seeing the roll. See
[`Engine/Computer.lua`](Engine/Computer.lua) for `evaluate`, `priority`, `levels` and the other
fields that help the search.

## The view

`createView(stage)` is called once, the first time one of your game's matches is opened. It
builds widgets inside `stage` and returns an object with `Layout` and `Update`:

```lua
local function createView(stage)
  local Widgets = engine.Widgets
  local self = setmetatable({ scores = {} }, View)
  self.roll = Widgets.Button(stage, L["pig_roll"], 100, 28)
  self.roll:SetPoint("TOPRIGHT", self.pot, "BOTTOM", -6, -20)
  self.roll:SetScript("OnClick", function()
    self.view.submit(ROLL)
  end)
  ...
  return self
end
```

`Layout(width, height)` is called before the first `Update` and again whenever the window is
resized. `Update(view)` is called on every change and also when nothing has changed, so it must be
cheap and must not restart animations. The fields of `view` you will use most are:

| Field | What it is |
|---|---|
| `state` | The position to draw, as this player may see it. Don't change it or keep it |
| `seat` | The player's seat |
| `names` | The players' names, by seat |
| `canMove` | Whether the player may move now |
| `submit(move)` | Makes a move for the player |
| `played` | What `apply` returned for the move that led here, when there is one to show |
| `fresh` | The player hasn't seen this position before. Play sounds only then |
| `live` | False while the player is looking back at an earlier position |

The full list is on `GameView` in [`Engine/Games.lua`](Engine/Games.lua). The view is the only
part of a game that uses the WoW API. The engine's widgets are there to build it with: boards,
cards, dice, tiles and more (see [What ForeverGamesAPI has](#what-forevergamesapi-has)).

## Registering the game

The game file ends by registering everything:

```lua
local ADDON = ...
local engine = ForeverGamesAPI
local L = engine.L

-- rules and view as above

engine.Games.Register({
  id = "pig",
  name = L["game_pig"],
  description = L["game_pig_description"],
  genre = "dice",
  plugin = ADDON,
  version = 1,
  seats = { 2, 3, 4 },
  options = {
    { id = "target", name = L["pig_option_target"], description = L["pig_option_target_tip"], choices = { 50, 100 }, default = 100 },
  },
  howto = {
    { heading = L["howto_goal"], text = L["pig_howto_goal"] },
    { heading = L["howto_turn"], text = L["pig_howto_turn"] },
  },
  newState = newState,
  turn = function(state)
    return state.turn
  end,
  validate = validate,
  apply = apply,
  moves = moves,
  result = result,
  drop = drop,
  computer = COMPUTER,
  createView = createView,
})
```

- `id` is sent in every challenge, so it has to be unique across every game anyone has installed.
  Use letters and digits only. `Register` raises an error for a second game with an id that is
  already taken, and that game isn't registered.
- `plugin` is your addon's name, which the client passes to every file as the first value of
  `...`. If someone is challenged to your game and doesn't have it, the challenger is told which
  folder they need.
- `version` must go up whenever the rules or the format of a move change. Two players whose
  versions differ can't play each other, and the challenge says so.
- `icon` is the path of a square texture, for example
  `"Interface\\AddOns\\ForeverGames_Pig\\Images\\icon"`. If you leave it out, the addon's icon is
  used.

`Register` checks the definition and raises an error that names what is wrong, so mistakes show
up as soon as the addon loads. Every field and what it does is listed on `GameDefinition` in
[`Engine/Games.lua`](Engine/Games.lua). Besides what Pig uses, there are games for one player
(`seats = 1`), with `undo`, a `clock` and a `record` to beat; games that can be raced, with a
`ghost` of the rival's run; the day's challenge (`daily`); hidden information (`visible`); games
without turns (`together`); and a move list (`history`). [CONTRIBUTING.md](CONTRIBUTING.md)
describes each of these, and every game in [`Games/`](Games) is an example of one or more.

## Testing

Forever Games' tests run on a stock Lua 5.1 with no game client. They load every game addon in
the repository (the `ForeverGames_*` folders, and those in `Examples/`), and any folder you name
in `FOREVER_GAMES_PLUGINS`, separated by semicolons. From a copy of Forever Games:

```
FOREVER_GAMES_PLUGINS=/path/to/ForeverGames_Pig lua Tests/RunTests.lua pig
```

The words after `RunTests.lua` choose which tests run: here, every test with `pig` in its name.

Your game gets a test called `EveryGame_<id>` with no work from you. It checks that:

- the same seed always deals the same game
- the rules never ask the client for the time or a random number
- every string the game shows is in the locale
- if the game has `moves`, a few games played at random keep to the rules, and their logs replay
  to the same position on another client
- if the game has a computer, it picks legal moves, the same one every time from the same
  position, and can play a whole game against itself
- if the game can be raced or is a daily challenge, it deals the same for everyone

To add tests of your own, put a `Tests.lua` in your folder that returns a function. It is passed
the table of tests to add to, a function that loads a fresh copy of the engine with every addon
in it, and the helpers Forever Games' own tests use:

```lua
return function(tests, loadEngine, helpers)
  local equal = helpers.equal

  function tests.PigLosesTheTurnOnAOne()
    local game = loadEngine().Games.Get("pig")
    local state = game.newState(2, nil, { target = 100 })
    local ones = { Roll = function() return 1 end }
    game.apply(state, 1, "r", ones)
    equal(0, state.pot)
    equal(2, state.turn)
  end
end
```

The helpers are `equal(expected, actual, label)`, `near(expected, actual, label)`, `World` (players
on simulated clients linked by a fake network, see `Tests/RunTests.lua`), `Client` (a stand-in for
the WoW API that views can be built on, see `Tests/FakeClient.lua`) and `openWindow(player)`.
`loadEngine().plugins.<AddonName>` is the table the client gave your addon, if your tests need
to reach something you keep there.

## Trying it in the game

Copy your folder into `Interface\AddOns` next to `ForeverGames` and restart the game. The client
looks for new addons only when it starts, so `/reload` isn't enough the first time. After that,
`/reload` picks up changes to your files. Errors show with the client's error display turned on
(`/console scriptErrors 1`), and `/fg log` shows the addon's log.

## Playing with other people

Both players need your addon, at the same `version`. When the other player doesn't have it, their
client turns the challenge down and the challenger is told the name in `plugin`.

Forever Games saves every match. If a player removes your addon, their matches of your game stay
in the list, marked as a game that isn't installed, and they come back when the addon does.

A match is saved as its list of moves and replayed through the rules installed now, every time it
is loaded. Forever Games doesn't keep old versions of a game's rules. When you change the rules,
raise `version` so that players on different versions can't start a match together, and keep the
new rules able to replay the moves of matches that were started before. If they can't, those
matches can end up in a different position than the one the players saw.

## Settings

A choice the player makes in your view that should be remembered next time, such as Where in
Azeroth's button that keeps the map open, goes in the table `ForeverGamesAPI.Settings(id)` returns
for your game's id. Forever Games saves it with its own settings, so your addon doesn't need
saved variables of its own:

```lua
self.keep:SetScript("OnClick", function()
  local settings = engine.Settings("where")
  settings.keepMap = not settings.keepMap or nil
end)
```

Ask for the table when you need it, not when your file loads. Forever Games may not have read its
saved settings yet when your files run.

## Large content: maps, pictures, sounds

Pictures and sounds cost nothing until they are shown or played, so keep them in your addon's
folder and refer to them by path, as `Interface\AddOns\ForeverGames_Pig\Images\...`. An addon
of pictures can still load at login, as long as its Lua is small. Where in Azeroth's places
(`ForeverGames_Where_Places`) are 130 MB of panoramas and a list of 49 places a few KB long, and
it is the list that is loaded. See [Packs of places](#packs-of-places).

Lua data is different: everything a loaded addon lists is read at login. Freedoom's maps are 9 MB,
so they are a second addon, `ForeverGames_Freedoom_Maps`, marked `## LoadOnDemand: 1` and
depending on `ForeverGames_Freedoom`. The game names it:

```lua
addon = "ForeverGames_Freedoom_Maps",
```

and loads it the first time a map is needed:

```lua
local load = C_AddOns and C_AddOns.LoadAddOn or LoadAddOn
pcall(load, "ForeverGames_Freedoom_Maps")
```

A game with `addon` is only offered while that addon is installed and switched on. A challenge to
it is turned down when the addon is missing, and the player who was challenged is told which
folder they need.

## Packs of places

Where in Azeroth deals its places from packs. A pack is an addon named `ForeverGames_Where_<Name>`
with a list of places and the panoramas of them, and anyone can make one. Every pack that is
installed is dealt from, so a player adds places by dropping a folder into `Interface\AddOns`.

A pack is two things. Its `.toc` depends on Where in Azeroth:

```
## Interface: 16001
## Title: Forever Games: Where in Azeroth, Bob
## Dependencies: ForeverGames_Where
## Group: ForeverGames

Places.lua
```

And its `Places.lua` hands its places to the engine:

```lua
local ADDON = ...

ForeverGamesAPI.Places.AddPack("where", ADDON, {
  { id = "bobsfarm", continent = 0, x = -9464.3, y = 62.1, mapID = 1429, zone = "Elwynn Forest",
    pano = { tiles = 4, width = 4096, height = 1024, top = 0.6, bottom = -0.4, facing = 1.2,
      sky = { 0.4, 0.5, 0.6 }, ground = { 0.3, 0.3, 0.1 } } },
})
```

The pictures go in its `Images` folder, `bobsfarm_1.blp` to `bobsfarm_4.blp` for the four tiles of
that panorama. You don't write any of this by hand. The capture tool, `Tools/GeoBench`, takes the
screenshots and `stitch.py` joins them into a panorama. Then

```
Tools/GeoBench/python.sh ../places.py --pack Bob add <panorama> bobsfarm
```

makes `ForeverGames_Where_Bob`, with its `.toc`, its `Places.lua` and its pictures, the first time
it is run, and adds to it after that. Without `--pack`, places go into `ForeverGames_Where_Places`.

The packs are put together in the order of their names, each in its own order. A place whose id
an earlier pack already has is left out. The game's version is worked out from the ids of every
place in that order (`Places.Signature`), so when two players with different packs try to race,
they are told they are on different versions. The day's game doesn't check versions: with
different packs, two guildmates are dealt different places for it, and their scores still go on
the same board.

Any game can deal from packs the same way, under a catalogue name of its own:
`Places.AddPack(name, pack, places)` adds a pack, `Places.Catalogue(name)` is every place there is,
`Places.Signature(name)` is the number to count a version from, and `Places.OnPack(name, fn)` is
called whenever another pack arrives. Packs load after the game they belong to, so the game
updates its version there, as `ForeverGames_Where/Where.lua` does.

## What ForeverGamesAPI has

`ForeverGamesAPI.version` is 1. It goes up when something here changes in a way that would break
an addon written for the version before.

| Name | What it is for |
|---|---|
| `Games` | The registry: `Register`, `Get`, `List` |
| `Rooms` | Party games played in a room, as Sketch and Trivia are: `Rooms.Register` |
| `L` | Every string, yours included |
| `Locale(locale, isDefault)` | Somewhere to add your strings, see [Strings](#strings) |
| `Settings(id)` | A table to keep the player's settings for your game in, saved with the addon's own. See [Settings](#settings) |
| `SoundOn()` | Whether the player has the addon's sounds on. Check it before playing a sound of your own |
| `Log(...)` | Adds a line to the addon's log, shown by `/fg log` and saved on logout |
| `ICON` | The path of Forever Games' icon |
| `Codec` | The wire format, and `Codec.IsSafeField` for whether a string can travel |
| `Random` | The type of `random`: `random:Roll(max)`, `random:Shuffle(list)` |
| `Tables` | Copying positions |
| `Grid` | Boards of squares: names like `"e4"`, steps, lines, neighbours |
| `Deck` | Playing cards: decks, hands, trick-taking |
| `Phases` | The phases of a party game |
| `Computer` | The computer's search, for a game with its own `think` |
| `Race` | Races between two players on the same deal |
| `Lexicon` | Word lists, for word games |
| `SectorMap`, `Actors`, `Course` | Doom-style maps, the things that move in them, and race courses |
| `Places` | Places in Azeroth: distances, scoring a guess, and packs of places (`AddPack`, `Catalogue`) |
| `Widgets` | Buttons, labels, dropdowns, lists, sounds, animation |
| `Lettering` | Text drawn as pictures, in fonts the client doesn't have |
| `Effects` | Glows, bursts and other short effects |
| `Board`, `Heaps`, `SlideGrid`, `NumberGrid`, `Tiles` | Boards and pieces |
| `Cards`, `CardTable` | Cards and a table to play them on |
| `Felt` | The cloth a table is covered with, in the colour the player chose |
| `Dice` | Dice that are thrown across the table |
| `Viewport`, `Drag` | Zooming, panning and dragging |
| `Canvas` | Drawing lines, for Sketch |
| `Strips`, `SectorView` | A screen drawn a frame at a time, and the Doom-style view of a sector map |
| `PanoView`, `MapView`, `MapOverlays`, `TerrainView` | Panoramas and maps of the world |

Each part is documented at the top of its file in [`Engine/`](Engine) or [`GUI/`](GUI). Parts that
run the addon itself, such as the player's matches, the window and the messages between players,
aren't in `ForeverGamesAPI`. A game shouldn't need them.

## Rules for a game addon

- Read `ForeverGamesAPI` into a local at the top of every file (`local engine = ForeverGamesAPI`).
  The tests load many copies of the engine, and the global changes between them.
- Keep your own things in the table the client passes your addon (`local ADDON, own = ...`), not
  in `ForeverGamesAPI` or in globals. Writing to `ForeverGamesAPI` is an error.
- In the rules, use only `random` for chance, and never the clock.
- The player chooses in the options what card backs, the felt of a table and dice look like, and
  what is on screen changes as soon as they do. Let your game go along with it:
  - Draw a card you put on a texture of your own with `Cards.Paint(texture, card)`, not by
    setting `Cards.Texture(card)` on it.
  - Cover a table with `Felt.Paint(texture, own)`, `own` being your colour for it (red, green,
    blue and how opaque). It is used unless the player chose one colour for every table.
  - Leave out `color` from a roll of `Dice` unless the colour tells players apart, as
    Backgammon's do. Dice with no colour of their own are the one the player chose.
- Raise `version` whenever the rules or the format of a move change.
- Put every string the players read in the locale, under keys that start with your game's id.
- Give the game an `id` no other game uses.
