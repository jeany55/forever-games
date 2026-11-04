--------------------------
--  Pinball: what it is made of
--------------------------
-- The game's own table, private.Pinball, which its other files find their parts in, with the parts
-- of the engine it is played on: the physics the ball rolls by, the lamps' light shows, and the
-- dot-matrix display. The bench that tries it out on its own (Tools/PinballBench) has a table of
-- its own in its place, with its own copies of them.

local _, private = ...
private.Pinball = private.Pinball or {}
local own = private.Pinball
own.Physics, own.LightShow, own.DotMatrix = private.Physics, private.LightShow, private.DotMatrix
