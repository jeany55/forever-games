--------------------------
--  Actors
--------------------------
-- Things that go through states the way Doom's do: a monster standing about, walking, firing,
-- flinching and falling down, a fireball flying and bursting, a puff of smoke. A state is a frame
-- of the thing's sprite shown for so many tics (Doom's 35ths of a second, -1 for as long as
-- nothing else happens), something the thing does on coming to it, and which state comes next.
-- The states come in sequences, each going on to the next of its own and after its last to
-- another sequence ("next"), or to nothing, which is the end of the thing ("remove").
--
-- What a thing does on coming to a state is the game's: it is told the action's name (act). Any
-- game with things that live this way can have them, in a sector map (SectorMap:AddThing) or not.
--
--   sequences = {
--     stand = { { "A", 10, "look" }, { "B", 10, "look" }, next = "stand" },
--     die = { { "H", 5 }, { "I", 5, "scream" }, { "L", -1 } },
--   }
--
-- A step is the frame's letter, its tics, the action if there is one and true if it lights itself.
-- A sequence may be of another sprite than the thing's own (sprite = "BEXP"): a barrel going up.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class ActorStep
--- @field [1] string The frame's letter
--- @field [2] integer Tics, -1 for ever
--- @field [3] string? What the thing does on coming to it
--- @field [4] boolean? It lights itself

--- @class Actor
--- @field sprite string The sprite its frames are of
--- @field sequences table<string, ActorStep[]>
--- @field act fun(actor: Actor, action: string) Does what a state says
--- @field sequence string? Which it is in
--- @field step integer? And where in it
--- @field tics integer Left of the state it is in
--- @field picture string? The frame it shows, its sprite and the letter
--- @field bright boolean?
--- @field removed boolean? It came to the end

--- @class Actors
local Actors = {}
private.Actors = Actors

-- A sequence that goes round and round without a tic in it is a mistake, not a thing that lives
local MOST_STEPS = 64

--- Comes to a step, and does what it says. One of no time at all is gone straight past
--- @param actor Actor
local function enter(actor, sequence, step)
  for _ = 1, MOST_STEPS do
    local steps = actor.sequences[sequence]
    local state = steps and steps[step]
    if not state then
      actor.sequence, actor.step, actor.removed, actor.picture = nil, nil, true, nil
      return
    end
    actor.sequence, actor.step, actor.tics = sequence, step, state[2]
    actor.picture, actor.bright = (steps.sprite or actor.sprite) .. state[1], state[4] == true
    if state[3] then
      actor:act(state[3])
      -- What it did may have put it somewhere else
      if actor.sequence ~= sequence or actor.step ~= step or actor.removed then
        return
      end
    end
    if actor.tics ~= 0 then
      return
    end
    sequence, step = Actors.Following(actor, sequence, step)
  end
  error("Sequence " .. tostring(sequence) .. " of " .. tostring(actor.sprite) .. " never takes any time")
end

--- The step after one: the next of the sequence, or the first of whichever comes after it
--- @return string? sequence Nil for the end of the thing
--- @return integer step
function Actors.Following(actor, sequence, step)
  local steps = actor.sequences[sequence]
  if steps[step + 1] then
    return sequence, step + 1
  end
  local after = steps.next
  if not after or after == "remove" then
    return nil, 1
  end
  return after, 1
end

--- Puts a thing at the start of a sequence
--- @param actor Actor
--- @param sequence string
function Actors.Start(actor, sequence)
  actor.removed = false
  enter(actor, sequence, 1)
end

--- One tic of a thing's life
--- @param actor Actor
function Actors.Tick(actor)
  if not actor.sequence or actor.tics < 0 then
    return
  end
  actor.tics = actor.tics - 1
  if actor.tics <= 0 then
    local sequence, step = Actors.Following(actor, actor.sequence, actor.step)
    if sequence then
      enter(actor, sequence, step)
    else
      actor.sequence, actor.step, actor.removed, actor.picture = nil, nil, true, nil
    end
  end
end
