--------------------------
--  Deck
--------------------------
-- Playing cards, for the rules of any game played with them. A card is two characters, its rank
-- and its suit: "QH" for the queen of hearts, "TS" for the ten of spades, "AC" for the ace of
-- clubs. That is how games send them and how GUI/Cards.lua and GUI/CardTable.lua draw them. A card
-- somebody isn't shown is Deck.HIDDEN, which they draw as a card's back.
--
-- A pile of cards is a list of them with the top at the end, so that drawing one is
-- table.remove(pile). A new deck comes in the same order every time, spades, hearts, diamonds
-- and clubs, each from the ace up: a game's match shuffles it with its own dice (Engine/Random.lua)
-- and every client gets the same deal.
--
-- For the games where everyone plays a card to a trick and the best one takes it (Hearts, Spades,
-- Euchre) there is what every one of them needs: which cards a player may play to a trick, and
-- whose card takes it.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class Deck
local Deck = {}
private.Deck = Deck

-- From the ace up, T for the ten
Deck.RANKS = "A23456789TJQK"
Deck.SUITS = "SHDC"
-- The suits that are red, the others are black
Deck.RED = { H = true, D = true }
Deck.HIDDEN = "?"
-- How the ranks go when the ace is worth the most, as it is in a trick
Deck.ACE_HIGH = "23456789TJQKA"

--- @param card string
--- @return string rank, string suit
function Deck.Parts(card)
  return card:sub(1, 1), card:sub(2, 2)
end

--- @param card string
--- @param order string? How the ranks go, from the least: Deck.RANKS if left out, the ace the least
--- @return number rank 1 for the least, 13 for the most. 0 for a card that isn't one
function Deck.Rank(card, order)
  return (order or Deck.RANKS):find(card:sub(1, 1), 1, true) or 0
end

--- @param card string
--- @return string
function Deck.Suit(card)
  return card:sub(2, 2)
end

--- @param card string
--- @return boolean
function Deck.IsRed(card)
  return Deck.RED[card:sub(2, 2)] == true
end

--- Whether some text is a card: a rank and a suit, nothing else
--- @param text string?
--- @return boolean
function Deck.IsCard(text)
  return type(text) == "string" and #text == 2 and Deck.RANKS:find(text:sub(1, 1), 1, true) ~= nil and Deck.SUITS:find(text:sub(2, 2), 1, true) ~= nil
end

--- A whole deck of fifty-two, in the same order every time: spades, hearts, diamonds and clubs,
--- each from the ace to the king
--- @return string[]
function Deck.New()
  local deck = {}
  for suit in Deck.SUITS:gmatch(".") do
    for rank in Deck.RANKS:gmatch(".") do
      deck[#deck + 1] = rank .. suit
    end
  end
  return deck
end

--- A whole deck, shuffled with the match's dice
--- @param random Random
--- @return string[]
function Deck.Shuffled(random)
  return random:Shuffle(Deck.New())
end

--- Deals cards from the top of a pile, one to each hand at a time and round again
--- @param pile string[] What is dealt is taken off it
--- @param hands string[][] Each is added to
--- @param each number Cards to each hand
function Deck.Deal(pile, hands, each)
  for _ = 1, each do
    for _, hand in ipairs(hands) do
      hand[#hand + 1] = table.remove(pile)
    end
  end
end

--- Where a card is in a pile or a hand
--- @param cards string[]
--- @param card string
--- @return number? nil if it isn't there
function Deck.Find(cards, card)
  for index, held in ipairs(cards) do
    if held == card then
      return index
    end
  end
  return nil
end

--- So many cards seen from the back, for what a player isn't shown of a pile or a hand
--- @param count number
--- @return string[]
function Deck.Backs(count)
  local backs = {}
  for index = 1, count do
    backs[index] = Deck.HIDDEN
  end
  return backs
end

--- The cards of the deck that aren't in any of some lists, in the deck's own order: what could
--- be in the hands and the piles a player can't see
--- @param ... string[] The cards they can see
--- @return string[]
function Deck.Unseen(...)
  local known = {}
  for index = 1, select("#", ...) do
    for _, card in ipairs((select(index, ...))) do
      known[card] = true
    end
  end
  local unseen = {}
  for _, card in ipairs(Deck.New()) do
    if not known[card] then
      unseen[#unseen + 1] = card
    end
  end
  return unseen
end

--- Puts cards in the order a player would hold them: by suit, and from the least up in each
--- @param cards string[] Sorted in place
--- @param order string? How the ranks go, Deck.RANKS if left out
--- @return string[] cards
function Deck.Sort(cards, order)
  table.sort(cards, function(a, b)
    local suitA, suitB = Deck.SUITS:find(a:sub(2, 2), 1, true) or 0, Deck.SUITS:find(b:sub(2, 2), 1, true) or 0
    if suitA ~= suitB then
      return suitA < suitB
    end
    return Deck.Rank(a, order) < Deck.Rank(b, order)
  end)
  return cards
end

-----------------------------
-- Tricks
-----------------------------
-- A trick is the cards played to it, in the order they were. The first one's suit is the one
-- led, which everyone has to follow if they can. Whose card takes it is the highest of the suit
-- led, unless a trump was played: then the highest trump.
--
-- A game whose suits aren't always what is printed on the card says what they are (`suitOf`):
-- in Euchre the jack of the other suit of trump's colour is a trump. One whose ranks don't go
-- the usual way, ace high, says how they go (`rankOf`).

--- @class DeckTrickRules
--- @field trump string? The suit that is trump, if there is one
--- @field suitOf (fun(card: string, trump: string?): string)? The suit a card counts as
--- @field rankOf (fun(card: string, trump: string?): number)? How much a card is worth against another of the suit it counts as, the higher the more

--- @param card string
--- @param rules DeckTrickRules?
--- @return string
local function suitOf(card, rules)
  local custom = rules and rules.suitOf
  return custom and custom(card, rules and rules.trump) or card:sub(2, 2)
end

--- @param card string
--- @param rules DeckTrickRules?
--- @return number
local function rankOf(card, rules)
  local custom = rules and rules.rankOf
  return custom and custom(card, rules and rules.trump) or Deck.Rank(card, Deck.ACE_HIGH)
end

--- The suit a trick asks for: the one its first card counts as
--- @param trick string[]
--- @param rules DeckTrickRules?
--- @return string? nil while nothing has been played to it
function Deck.Led(trick, rules)
  return trick[1] and suitOf(trick[1], rules) or nil
end

--- The cards of a hand that may be played to a trick: any of them to lead, else the ones of the
--- suit led, or any of them by somebody who has none of it
--- @param hand string[]
--- @param trick string[]
--- @param rules DeckTrickRules?
--- @return string[]
function Deck.Playable(hand, trick, rules)
  local led = Deck.Led(trick, rules)
  if not led then
    return { unpack(hand) }
  end
  local following = {}
  for _, card in ipairs(hand) do
    if suitOf(card, rules) == led then
      following[#following + 1] = card
    end
  end
  return #following > 0 and following or { unpack(hand) }
end

--- Which card of a trick takes it
--- @param trick string[] At least one card
--- @param rules DeckTrickRules?
--- @return number Where in the trick the card is: 1 for the one led
function Deck.Winner(trick, rules)
  local trump = rules and rules.trump
  local best, bestSuit, bestRank = 1, suitOf(trick[1], rules), rankOf(trick[1], rules)
  for index = 2, #trick do
    local suit, rank = suitOf(trick[index], rules), rankOf(trick[index], rules)
    local beats
    if suit == bestSuit then
      beats = rank > bestRank
    else
      -- Off suit loses, unless it is a trump played on something that isn't
      beats = trump ~= nil and suit == trump
    end
    if beats then
      best, bestSuit, bestRank = index, suit, rank
    end
  end
  return best
end
