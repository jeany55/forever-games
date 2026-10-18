# Pinball: game design

What the WoW pinball table plays like: its shots, its rules, and the talents of its three classes.
Nothing here is built yet. The bench (this folder) is for the physics and how the table feels. The
rules come after, on the engine parts listed under "What the engine needs".

The shots are the bench's own layout (Tools/pinball_table.py), so everything here can be played on
it. The full table will add a shot or two. Those are marked as such.

## The table

You go from level 1 to 60 in one game. Shots earn XP and points. Levels unlock talents at the class
trainer (the centre saucer), and each talent changes what is worth shooting for the rest of the
game. Every game starts at level 1 with no talents.

### Shots

| Shot | Where | What it does in the base rules |
|---|---|---|
| Shooter lane | Right edge | The plunger. A full plunge goes round the arch and down the left orbit to the left flipper. A softer one drops into the top lanes. The skill shot happens here |
| Top lanes | 3 rollovers under the arch | Light a lane by rolling through it. Light all 3 to raise the bonus multiplier (up to 5x), then they reset. The flipper buttons move the lit lanes left and right (lane change) |
| Pop bumpers | 3, below the top lanes | Small points and XP for each hit. Count toward "kill" quests. They feed balls to the rest of the table at random |
| Left orbit and spinner | Lane up the left side | Shot from the right flipper. Goes round the arch and back down. Every spin of the spinner scores. A hard orbit spins it 20 to 40 times. Spinner spins relight the kickback (25 spins) |
| Drop targets | 3-bank on the left | Each one scores. Completing the bank lights the quest giver at the saucer and resets the targets |
| Moonwell (class trainer) | Centre | A saucer that holds a slow ball. If a talent pick is waiting, you choose it here. If a quest is lit, you accept it here. Otherwise, a small award. After a second or two the ball is kicked straight up a glass tube onto a wire that crosses over the ramp and winds down the right side to the right inlane |
| Ramp | Right, up to 93 mm | Shot from the left flipper. At its top the ball goes onto a wire that arches over the bumpers, winds once down a corkscrew in the top left corner and runs down the left side to the left inlane, so the left flipper has it next. A weak shot rolls back off the wire before its crest and doesn't count. It's the main jackpot shot in multiball and is worth XP every time |
| Slingshots | Above each inlane | Kick the ball away. Small points. Nothing more in the base rules, but Warrior rage and some talents use them |
| Kickback | Left outlane | When lit, it fires a ball that falls into the left outlane back into play. Lit at the start of the game. Relit by 25 spinner spins |
| Centre post | Between the flippers | Down in the base rules. Talents raise it, and it stops one drain each time it comes up |

The full table will add:

- **Right orbit**: a lane up the right side, mirroring the left. It gives the left flipper an orbit
  shot and makes combos (orbit to orbit) possible.
- **Upper flipper**: a small flipper at the upper right, for shooting the top lanes or a second ramp.
- **Inlane rollovers**: sensors in both inlanes, so combos can count "ramp then the inlane feed then
  orbit" and lane change can use them.

### Lights on the bench table

The bench layout already has these lamps, and the rules use them:

| Lamp | Meaning |
|---|---|
| lane1 to lane3 | Top lanes made this round |
| target1 to target3 | Drop targets down |
| saucer arrow | Flashing: a talent pick is waiting. Steady: a quest is ready to accept |
| ramp arrow | The ramp is lit (jackpot, quest step, or a talent's lit shot) |
| spinner arrow | The orbit is lit |
| kickback | The kickback is lit |
| shootAgain | Ball save running, or an extra ball waiting |
| level1 to level5 | Progress to the next talent tier, one lamp per 2 levels |

## Base rules

### Levels and XP

- XP is a second number beside the score. Points decide who wins. XP decides your level.
- XP to the next level grows with your level, so early levels come fast: level 10 in the first minute
  or so of a decent ball.
- Where XP comes from: every shot gives a little. Quests give the most (1 to 2 levels each at low
  level, scaled up as you level). Raid jackpots give a lot.
- A good 3-ball game, 6 to 9 minutes, should reach level 40 to 50. Level 60 should be a great game.
  This is a tuning target for the robot player runs, not a fixed number.
- **Ding.** A level-up plays the level-up sound, flashes gold over the table, shows the new level on
  the display and lights one more level lamp every 2 levels. It doesn't stop play.
- Talent tiers are reached at levels 10, 20, 30, 40 and 50, and the capstone at 60. Reaching one
  makes the saucer flash.

### The trainer

- When a pick is waiting, the saucer flashes. Shooting it holds the ball, and the display shows the
  tier's three talents.
- The flipper buttons move between the talents and the launch button takes one. The game is paused
  while you choose: timers stop and no other ball moves.
- If you don't shoot the trainer, the pick waits. Picks stack, so you can reach level 30 still
  holding two picks. This is part of the game: the trainer is one more shot to make while quests and
  modes ask for others.
- A pick lasts for the rest of the game. There's no respec.

### Quests

- Completing the drop target bank lights the quest giver. Shoot the saucer to accept.
- If a talent pick is waiting as well, the pick comes first and the quest is offered straight after.
  The ball stays held for both.
- One quest runs at a time, with a timer shown on the display. When the timer runs out the quest
  fails and the drop targets have to be completed again to light another.
- Quests come in a set order (the quest log), so a player learns what is next. The Arcane talent
  Presence of Mind lets you choose instead.

| Quest | Do this | Time | Notes |
|---|---|---|---|
| Kill 10 Defias Bandits | 10 pop bumper hits | 30 s | The easy opener. Shoot the top lanes or the orbit and let the bumpers do it |
| The Deeprun Tram | 3 ramps | 40 s | The ramp arrow lights for each |
| Bounty: Hogger | Complete the drop target bank, then the saucer to turn in | 45 s | The second bank resets fast during the quest |
| Gnoll Paws | 40 spinner spins | 30 s | Two good orbits do it |
| Explore Elwynn Forest | All 3 top lanes | 35 s | Lane change helps. A soft plunge counts if the quest runs at the start of a ball |
| Westfall Courier | Orbit, then ramp, then orbit, in that order | 20 s per step | The lit shot moves along. Missing a step's time fails the quest |
| Escort the Defias Traitor | Hit whichever shot is lit, 5 times. The lit shot moves each time | 50 s | A drain during the escort fails it, even with ball save |
| Report to Stormwind | The saucer, once | 20 s | Always the last quest of a set. Completing it lights the raid |

- Completing 3 quests lights raid multiball at the saucer (Report to Stormwind also does).
- Quest XP scales with your level, so a quest is always worth roughly a level and a half.

### Raid multiball: Onyxia's Lair

- **Lit** after 3 completed quests. **Started** at the saucer.
- **Start**: the saucer ball and two more from the shooter lane, 3 balls in all. Ball save for 15
  seconds.
- **Phase 1**: the ramp is lit for jackpots. 3 jackpots move to phase 2.
- **Phase 2 (Deep Breath)**: Onyxia takes off. The bumpers become whelps, each hit worth a jackpot
  fraction. Hitting the orbit 2 times brings her down.
- **Phase 3**: the saucer is lit for the super jackpot, the boss loot. Collecting it relights phase 1
  with jackpots worth more.
- Multiball ends when one ball is left. Unfinished phases are lost. The quest log carries on.

### Ball save, extra ball, tilt

- **Divine Intervention (ball save)**: 8 seconds at the start of each ball. While it runs, the
  shootAgain lamp flashes and a drained ball comes back from the plunger.
- **Soulstone (extra ball)**: lit at the ramp at levels 25 and 50. Collecting it lights shootAgain
  steady. When the ball ends, you play the same ball again.
- **Tilt**: nudging is allowed. Each nudge fills a tilt meter, which empties over a few seconds. Two
  warnings, then a tilt: the flippers go dead, the ball drains, and there's no bonus for that ball.

### Skill shot and bonus

- **Skill shot**: one top lane flashes, moving every half second. Plunge softly so the ball drops
  into it for skill shot XP.
- **Super skill shot**: hold the left flipper during the plunge. A full plunge then comes down the
  left orbit to the left flipper, and making the ramp within 3 seconds is the super skill shot.
- **End-of-ball bonus**: bumper hits, spinner spins, targets and quests done this ball, times the
  bonus multiplier, counted on the display. The bonus counts as XP as well as points, so a long
  ball can end with a level-up.

## Classes

You pick a class before ball 1. The flipper buttons move through the three class crests on the
display and launch takes one. Each class has:

- **A resource** that its shots fill and its abilities spend.
- **A base ability** on the action button from the start.

There is one action button. A talent marked **(active)** puts itself on the button and takes the
place of whatever was there, the base ability included. Taking a second active means giving up the
first. Picking an active talent is a decision about the button as much as about the talent.

### Capstones

- With 3 of your 5 picks in one spec, the level 60 pick is that spec's capstone.
- Otherwise it is the class's hybrid capstone, which is good but has a lower ceiling.
- Five picks can only put 3 in one spec, so there is never a choice between two capstones.
- The pull between taking the best option for this moment and staying on track for a capstone is
  meant to be one of the game's main decisions.

---

## Mage

**Resource: mana**, 0 to 100.

- Each spinner spin gives 1, each top lane gives 5.
- Mana doesn't fade.
- So the Mage's loop is: shoot the orbit to fill up, spend mana to save balls or score big.

**Base ability: Polymorph**: costs 40 mana. The ball turns into a sheep for 3 seconds, and time on
the table runs at half speed. It's a save when the ball is heading for the drain, or an aiming aid.

Specs:

- **Arcane** is control: mana, the spinner, choosing what comes next.
- **Fire** is risk and score: the bumpers and multiball.
- **Frost** is survival: slowing time, posts and freezes.

| Level | Arcane | Fire | Frost |
|---|---|---|---|
| 10 | **Arcane Missiles**: a spinner rip of 20+ spins lights the ramp for 6 s. That ramp scores 3 ramps' worth and gives 20 mana | **Ignite**: each bumper hit adds a Burn stack (20 at most). Every stack scores each second. Stacks fall by 2 a second while the ball is away from the bumpers | **Frost Nova** *(active)*: the ball stops dead where it is for 1.5 s, then drops. 45 s cooldown, no mana |
| 20 | **Presence of Mind**: when a quest is accepted, you choose it from 2 in the log, not the next in order. Quest timers stop while the ball is in the saucer | **Combustion**: raid jackpots and the super jackpot are worth double. Raid multiball has no ball save | **Ice Barrier**: every level-up raises the centre post until it stops one ball |
| 30 | **Blink** *(active)*: for 10 s, nudges are twice as strong and don't fill the tilt meter. 60 s cooldown | **Living Bomb**: completing the drop targets plants a bomb with a 10 s fuse. The ramp sets it off for a big score and XP. If the fuse runs out, you lose all Burn stacks | **Shatter**: for 3 s after any freeze or slow (Frost Nova, Polymorph), shots score 3x and drop targets count twice |
| 40 | **Arcane Power** *(active)*: costs 50 mana. 20 s of double score and XP. While it runs, ball save and the kickback are off | **Pyroclasm**: at 20 Burn stacks, they explode. That lights the super jackpot at the saucer for 15 s, in or out of multiball, and the stacks start again | **Cold Snap**: every level-up resets the action button's cooldown and adds 5 s of ball save |
| 50 | **Clearcasting**: every 25 spinner spins, your next mana cost is free | **Hot Streak**: two ramps in a row with no bumper hit between them light Pyroblast at the saucer: one shot worth a raid jackpot | **Brittle**: drop targets reset 3 times faster and score double, and a completed bank gives 10 mana |
| 60 | **Evocation**: the saucer fills your mana and starts a 30 s barrage. Every shot is lit, and each different shot in a row adds 1x, to 5x | **Pyroblast**: a 2-ball mode. The ramp charges Pyroblast in 3 steps, then the saucer fires it for the biggest single score in the game. No ball save in the mode | **Ice Block**: once per ball, a drain is caught. The ball comes back from the plunger and every running mode carries on |

**Hybrid capstone: Mage Armor.** Mana fills by 1 a second on its own, and the kickback relights at
every level-up.

The decisions:

- **Level 10**: Arcane if you can make the left orbit from the right flipper most of the time. Fire
  if the top lanes are feeding the bumpers well. Frost after a bad first ball, or if your button
  matters more as a save than Polymorph does. Frost Nova costs no mana, so Polymorph's mana has
  nothing else to pay for unless later talents use it.
- **Level 20**: Presence of Mind if quests are how you are levelling. Combustion if the raid is one
  quest away and you trust your multiball. Ice Barrier if you are levelling fast and draining often.
- **Level 30**: Blink if you use the button for nudge saves and don't need Frost Nova or Polymorph
  any more. Living Bomb if you hit drop targets then ramp reliably, and are willing to risk the Burn
  stacks. Shatter only with a freeze or slow you will actually use, which makes it a Frost or
  Polymorph commitment.
- **Level 40**: Arcane Power when you are ahead and want a big finish, or on your last ball, never
  when you need saves. Pyroclasm if you are living in the bumpers anyway. Cold Snap if level-ups are
  coming quickly.
- **Level 50**: Clearcasting if Polymorph or Arcane Power is on your button. Hot Streak works
  against Ignite's bumper play, so a Fire player has to choose a style. Brittle if you are
  quest-heavy (Hogger, the quest lighting) and want mana from targets.

---

## Warrior

**Resource: rage**, 0 to 100.

- Rage comes from hard hits:
  - a bumper hit gives 3
  - a slingshot kick gives 4
  - any hit faster than 2 m/s (the physics reports the speed) gives 2
- With no rage gained for 3 seconds, rage falls by 5 a second.
- Cradling bleeds rage. A Warrior wants the ball moving.

**Base ability: Heroic Strike**: costs 30 rage. For 8 s the ramp and the orbit are lit "Strike".
The first one made scores 10 times its usual value.

Specs:

- **Arms** is timing and one big hit.
- **Fury** is speed, chains and taking risks for score.
- **Protection** spends rage on saving the ball.

| Level | Arms | Fury | Protection |
|---|---|---|---|
| 10 | **Mortal Strike** *(active)*: spends all your rage. The next ramp within 6 s scores rage x 1000 and XP to match. A miss loses the rage | **Flurry**: 3 hard hits within 2 s (bumpers, slings) set off Flurry: for 10 s rage doesn't fade and the time allowed between combo shots doubles | **Shield Block**: when the kickback fires, 25 rage is spent to relight it at once. With less than 25 rage it stays unlit |
| 20 | **Sweeping Strikes**: for 10 s after a ramp, every bumper hit counts twice toward kill quests and drop targets count double | **Enrage**: at 100 rage you are Enraged for 15 s: everything scores double, but ball save and the kickback are off | **Last Stand**: reaching 100 rage spends it all and raises the centre post until it stops a ball |
| 30 | **Overpower**: completing the drop targets lights the ramp for 5 s. Making it gives a quarter of a level | **Rampage**: while you keep making shots within 4 s of each other (ramp, orbit, saucer), rage doesn't fade and each shot in the chain adds 1x | **Shield Wall** *(active)*: needs 50 rage, spends all of it. The centre post is up for 10 s and the kickback is lit |
| 40 | **Execute**: a shot made in the last 5 s of any timer (quest, mode, raid phase) counts as two steps | **Whirlwind** *(active)*: costs 50 rage. For 10 s bumper hits count 3 times and the slingshots kick 50% harder. The ball goes wild | **Taunt**: the saucer pulls 3 times as hard, catching balls that would roll past it. It holds the ball more often, and rage fades while it is held |
| 50 | **Retaliation**: each slingshot kick lights the ramp for 3 s at double value | **Death Wish**: rage comes twice as fast, and the tilt meter fills twice as fast | **Revenge**: after any save (kickback, centre post, ball save, nudge out of an outlane), the next shot within 4 s scores triple |
| 60 | **Executioner**: the saucer starts a mode of 4 lit shots in turn, 6 s each. Each one made doubles the next. A miss ends it | **Bloodthirst**: each ramp or orbit made within 5 s of the last adds 2 s of ball save. A long enough chain can't drain | **Shield Slam**: the centre post stays up while you have 50+ rage. It costs 5 rage a second while up |

**Hybrid capstone: Battle Shout.** Each ball starts with full rage, and the kickback relights at
every level-up.

The decisions:

- **Level 10**: Mortal Strike if you can make the ramp on demand. It also gives up Heroic Strike,
  which hits two shots. Flurry if the ball spends its time in the bumpers and slings. Shield Block
  if outlanes are costing you balls, paid for with rage you'd otherwise spend on scoring.
- **Level 20**: Sweeping Strikes if a kill quest is running or next. Enrage when you are behind and
  have to gamble. Last Stand if you'd rather your rage became a save than a score.
- **Level 30**: Overpower to level faster through the drop targets and ramp. Rampage if you can
  chain shots from the flippers. Shield Wall if a strong save on demand is worth losing your
  scoring button.
- **Level 40**: Execute rewards playing to the timer, so it suits a quest-focused game. Whirlwind
  scores a lot and drains a lot. Taunt makes quests and the trainer easy, at the cost of rage.
- **Level 50**: Retaliation if the ball keeps coming off the slings toward the left flipper.
  Death Wish only if you rarely nudge. Revenge if your build already saves a lot of balls.

---

## Rogue

**Resource: combo points**, 0 to 5.

- **Builders**, each worth 1 combo point:
  - an orbit with at least 10 spins
  - a ramp
  - a top lane
- **Finisher**: a drop target hit with combo points spends them all (Eviscerate) and scores the
  target times the points spent.
- Combo points fade 20 s after the last builder.
- So a Rogue routes the ball: build on the orbit and the ramp, then finish on the targets.

**Base ability: Evasion**: needs at least 2 combo points, spends all of them. Ball save for 2 s per
point. Holding points for a save means not spending them on a finisher.

Specs:

- **Assassination** is poison and payoffs that last over time.
- **Combat** is chains and speed.
- **Subtlety** is stealth: lamps go dark, and shots made unseen are worth much more.

| Level | Assassination | Combat | Subtlety |
|---|---|---|---|
| 10 | **Deadly Poison**: a finisher poisons the bumpers for 15 s. Each bumper hit scores times the points that finisher spent | **Riposte**: a slingshot kick builds a combo point | **Stealth** *(active)*: all lamps go dark for 10 s. The first shot made in stealth is an Ambush worth 5x, and it gives 3 combo points. 30 s cooldown |
| 20 | **Rupture**: a finisher also starts a 12 s bleed. Every spinner spin during it scores times the points spent | **Blade Flurry** *(active)*: spends 5 combo points to kick out a second ball for 20 s. It can drain without ending your ball. It has no ball save | **Shadowstep**: the saucer kicks the ball out aimed at the shot you pick with the flippers: the left flipper, the right flipper, or straight at the drop targets |
| 30 | **Seal Fate**: while a quest timer is running, builders give 2 combo points | **Adrenaline Rush** *(active)*: for 15 s, combo points don't fade and the table runs at 80% speed. 60 s cooldown | **Premeditation**: every kickout from the saucer starts you with 2 combo points and 5 s of stealth (lamps dark) |
| 40 | **Vile Poisons**: while the bumpers are poisoned, drop targets count twice for quests and stay down until the bank is done. Finishers on them score nothing: the reward moves to quests | **Killing Spree**: ramp, orbit, ramp, each within 4 s of the last, gives 5 combo points and a jackpot | **Cheat Death**: once per ball, a drain while you hold 3+ combo points brings the ball back from the plunger. It costs all of them |
| 50 | **Toxic Bumpers**: poisoned bumpers pull the ball toward them, keeping it in the nest longer | **Lightning Reflexes**: the flippers swing faster. Shots are harder and the ball is harder to catch and cradle | **Hemorrhage**: an Ambush lights 3 shots in turn. Each made while you are still unseen doubles |
| 60 | **Vendetta**: for the rest of the game, every finisher also counts as one step of the running quest | **Ruthless**: combo points go up to 10. A 10-point finisher starts raid multiball, lit or not | **Shadow Dance**: the saucer starts 20 s where every shot is an Ambush (5x). All lamps are dark and there is no ball save |

**Hybrid capstone: Sprint.** Combo points no longer fade, and the kickback relights at every
level-up.

The decisions:

- **Level 10**: Deadly Poison if the targets often send the ball up into the bumpers. Riposte if
  you're bad at the orbit and want points from chaos. Stealth if you know the table well enough to
  shoot without lamps, though it gives up Evasion, your only save.
- **Level 20**: Rupture if you can go from the targets to the orbit. Blade Flurry if a second ball
  is worth losing Evasion or Stealth from the button. Shadowstep if you want the saucer to set up
  your next shot. It's strong with a trainer pick or quest waiting.
- **Level 30**: Seal Fate if quests are your main source of XP. Adrenaline Rush if you want a
  slow-motion window and can spare the button. Premeditation if you shoot the saucer a lot.
- **Level 40**: Vile Poisons only with Deadly Poison, and only if you are levelling through quests.
  Killing Spree if you can make the ramp, orbit, ramp chain. Cheat Death if you play to hold combo
  points, which means fewer finishers.
- **Level 50**: Toxic Bumpers if Deadly Poison pays well. The bumper nest also drains more balls
  than the flippers do. Lightning Reflexes suits players who shoot from the flipper straight away
  rather than cradling. Hemorrhage only if Stealth or Premeditation is giving you Ambushes.

---

## What the engine needs

These are the parts this design asks of the rules side, as engine parts other games can use
(Engine/, held to tests like the rest):

- **Switches from physics events.** Named shapes report hit, kick, enter, leave, cross and hold.
  The rules see named switches with how hard or which way. "A hit faster than 2 m/s" is a switch
  with a speed.
- **A mode stack with priorities.** The base rules, a quest, the raid, class modes and talents are
  each a mode. A mode reacts to switches, can let a switch through or stop it, and comes and goes.
  Talents are modifiers on the modes under them.
- **Timers that pause.** They stop while the ball is in the saucer, while a pick is being made and
  while the game is paused. They can be extended (Execute) and read ("the last 5 s").
- **Lit shots.** Each shot knows which modes have it lit and for what. The lamp shows the
  highest-priority one, flashing or steady. One shot can be lit by several modes at once.
- **Lamp shows** that a mode can play (raid start, ding, ambush), above the lamps' normal state,
  and the "all lamps dark" mode (Stealth) under them.
- **Resources.** A number with a top, rules for filling and fading, and spending. Mana, rage and
  combo points are all this.
- **The action button.** One slot, an ability with a cost and a cooldown, which an active talent
  replaces.
- **Talents.** Tiers, three exclusive options each, a capstone needing 3 picks in one spec, picks
  made one at a time and stacked when not taken. Kept generic, so Wormcraft or another game could
  use it.
- **Physics knobs the rules can turn:**
  - time scale (Polymorph, Frost Nova, Adrenaline Rush)
  - stopping a ball where it is (Frost Nova)
  - posts up and down
  - the kickback
  - the saucer's pull, and how hard and which way it kicks out (Taunt, Shadowstep)
  - slingshot kick
  - flipper speed
  - pull on the bumpers (Toxic Bumpers)
  - how fast the tilt meter fills
- **Ball bookkeeping.**
  - Balls in play.
  - Ball save.
  - Adding balls from the shooter lane.
  - A ball that drains without ending the turn (Blade Flurry).
  - Bringing a drained ball back with modes still running (Ice Block, Cheat Death).
  - The extra ball.
- **The display.** A queue of messages with priorities (quest text, ding, jackpots, the pick
  cards), and choices made with the flipper buttons.
- **Replays.** The class, every pick, and every button and flipper press recorded at its physics
  tick. The physics is deterministic, so a game plays back exactly from that.
- **A robot player** that can choose picks, to run many headless games per build and catch an
  option that is always taken or never worth taking.

## Open questions

1. Should level 60 be a normal outcome of a good game, or a rare one? This decides how often anyone
   sees a capstone.
2. Should the class be picked before ball 1, or at the first trainer visit at level 10? For the
   daily challenge, should everyone play the same class?
3. Should XP and points stay two numbers, or should the guild board rank by points alone, with
   level as a shown extra?
4. Rogue Stealth darkens every lamp. Is hiding the table's state from the player fun, or too harsh?
5. Theme of the full table: levelling through Elwynn and Westfall, as the quests above are, or a
   raid such as Onyxia's Lair or Molten Core for the whole table?
