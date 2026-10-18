--------------------------
--  Pinball: what it is made of
--------------------------
-- The parts of the engine the game is played on, put where its other files look for them, which is
-- also where the bench that tries it out on its own (Tools/PinballBench) puts its copies of them:
-- the physics the ball rolls by, the lamps' light shows, and the dot-matrix display.

local _, own = ...
local engine = ForeverGamesAPI
own.Physics, own.LightShow, own.DotMatrix = engine.Physics, engine.LightShow, engine.DotMatrix
