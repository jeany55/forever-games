--------------------------
--  Felt
--------------------------
-- What the table a game is played on is covered with. A game says the colour it has its own
-- felt in, and the player can have every table the one colour of their choosing instead
-- (GUI/Options.lua): a table on screen turns to it the moment they choose. How see-through a
-- felt is stays the game's to say.
--
-- A felt is a texture filled with the colour, or a panel with a backdrop (Widgets.Panel). See
-- Games/Solitaire.lua and Games/Yacht.lua.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class Felt
local Felt = {}
private.Felt = Felt

-- The colours there are to choose from, in the order the options show them. "own" is each
-- game's own colour, the one for a player who hasn't chosen
Felt.COLOURS = { "own", "green", "teal", "blue", "red", "purple", "grey" }
Felt.OWN = "own"
-- Each colour, red, green and blue: dark enough for cards and dice to stand out on
Felt.RGB = {
  green = { 0.06, 0.24, 0.15 },
  teal = { 0.05, 0.2, 0.22 },
  blue = { 0.06, 0.13, 0.27 },
  red = { 0.26, 0.06, 0.08 },
  purple = { 0.17, 0.08, 0.26 },
  grey = { 0.13, 0.14, 0.16 },
}

-- Every felt there is and the game's own colour for it, to be told of a colour the player
-- chose. Forgotten with the felt
local felts = setmetatable({}, { __mode = "k" })

--- The colour the player chose for every table, "own" if they never did or chose one that has gone
--- @return string
function Felt.Colour()
  local chosen = ForeverGames.db.profile.feltColour
  return Felt.RGB[chosen] and chosen or Felt.OWN
end

--- @param felt Texture|Frame
--- @param own number[] Red, green, blue and how opaque, 1 if left out
local function fill(felt, own)
  local red, green, blue = unpack(Felt.RGB[Felt.Colour()] or own)
  local alpha = own[4] or 1
  if felt:IsObjectType("Texture") then
    felt:SetColorTexture(red, green, blue, alpha)
  else
    felt:SetBackdropColor(red, green, blue, alpha)
  end
end

--- Covers a table with felt: the colour the player chose for every table, or the game's own
--- @param felt Texture|Frame A texture to fill, or a panel with a backdrop
--- @param own number[] The game's own colour, red, green, blue and how opaque
function Felt.Paint(felt, own)
  felts[felt] = own
  fill(felt, own)
end

--- Makes a colour the one every table is, "own" for each game's own, and turns every felt there
--- is to it
--- @param colour string
function Felt.SetColour(colour)
  ForeverGames.db.profile.feltColour = colour
  for felt, own in pairs(felts) do
    fill(felt, own)
  end
end
