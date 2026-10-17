-- Pig's own tests, run with Forever Games' (lua Tests/RunTests.lua Pig, from a copy of Forever
-- Games). The checks every game is put through (Tests/EveryGame.lua) are run on it as well,
-- EveryGame_pig, with nothing written here for them.
--
-- Handed the tests to add to, the engine to load, and what Forever Games' tests are written with.
-- Not listed in the .toc, so the game client never loads it.
return function(tests, loadEngine, helpers)
  local equal = helpers.equal

  --- A game of Pig as it stands after these rolls of the die, for two
  --- @return table game, table state
  local function after(rolls)
    local game = loadEngine().Games.Get("pig")
    local state = game.newState(2, nil, { target = 100 })
    local index = 0
    local dice = {
      Roll = function()
        index = index + 1
        return rolls[index]
      end,
    }
    for _ = 1, #rolls do
      game.apply(state, state.turn, "r", dice)
    end
    return game, state
  end

  function tests.PigAddsUpTheRollsOfATurn()
    local _, state = after({ 4, 6, 3 })
    equal(13, state.pot)
    equal(1, state.turn, "still the first player's turn")
  end

  function tests.PigLosesTheTurnOnAOne()
    local game, state = after({ 5, 5, 1 })
    equal(0, state.pot, "nothing kept")
    equal(2, state.turn, "and the die goes round")
    equal(false, (game.validate(state, 2, "h")), "nothing to hold yet")
  end

  function tests.PigIsWonByBankingTheTarget()
    local game, state = after({ 6 })
    state.scores[1] = 95
    game.apply(state, 1, "h")
    equal(101, state.scores[1])
    equal(1, game.result(state).winner)
  end

  -- A whole game against the computer, on a simulated player's client: the player rolls once and
  -- holds, the computer does what it thinks best, and nothing is ever sent
  function tests.PigIsPlayedOutAgainstTheComputer()
    local world = helpers.World.New()
    local alice = world:AddPlayer("Alice-Realm")
    local session, Match = alice.session, alice.private.Match
    local match = assert(session:Invite({}, "pig", { computer = { level = "easy" }, seat = 1 }))
    equal("active", match.status)
    local moves = 0
    while match.status == "active" and moves < 2000 do
      local state = Match.State(match)
      assert(session:Move(match.id, state.pot > 0 and "h" or "r"))
      session:ThinkThrough(match.id)
      moves = moves + 1
    end
    equal("finished", match.status, "somebody got to the target")
    equal(0, #world.sent, "messages sent")
  end
end
