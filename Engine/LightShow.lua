--------------------------
--  LightShow
--------------------------
-- The lamps of a game, and how bright each is from moment to moment: a pinball table's inserts
-- and flashers, or anything else a game lights up to say what is going on.
--
-- Every lamp has a state of its own that the game sets as things change (Set): off, on, blinking
-- or pulsing. Over that the game plays shows (Play): a sweep across the table, a chase along a
-- row, the whole table flashing. A show runs for a while and lights the lamps it wants to, and
-- the lamps it leaves alone keep their own state; the show playing with the highest priority has
-- its way where shows overlap. When the game has nothing to say, an attract show can run under
-- everything (as the game sets it, with a low priority and no end).
--
-- Brightness asks how bright a lamp is now, 0 to 1. Nothing here draws: the game shows each lamp
-- that bright, and a real bulb's warming up and cooling down is Glow's, which takes a lamp towards
-- how bright it should be at the speed a bulb does.
--
-- Lamps have places (x and y, in whatever the game measures in) for the shows that move across
-- them, and are named by the game. Time is in seconds, as the game gives it: the same clock for
-- every call.

--- @type nil, ForeverGamesPrivate
local _, private = ...

local floor, min, max, abs, sqrt = math.floor, math.min, math.max, math.abs, math.sqrt

--- @class LightShowLamp
--- @field name string
--- @field x number
--- @field y number
--- @field mode string "off", "on", "blink" or "pulse"
--- @field period number Seconds a blink or pulse takes, all of it
--- @field since number When it was set, so a blink starts lit
--- @field shown number How bright it was last drawn, for Glow

--- @class LightShowShow
--- @field id integer
--- @field priority number
--- @field from number When it began
--- @field til number? When it ends, or never
--- @field light fun(lamp: LightShowLamp, t: number): number? How bright a lamp is `t` seconds into the show, or nil for the show to leave it be

--- @class LightShow
--- @field lamps table<string, LightShowLamp>
--- @field order LightShowLamp[] In the order they were given
--- @field shows LightShowShow[]
local LightShow = {}
LightShow.__index = LightShow
private.LightShow = LightShow

-- How long a bulb takes to light, and to go out: most of the way in this many seconds
local WARM, COOL = 0.05, 0.12

--- @param lamps { name: string, x: number?, y: number? }[]
--- @return LightShow
function LightShow.New(lamps)
  local show = setmetatable({ lamps = {}, order = {}, shows = {}, nextId = 0 }, LightShow)
  for _, lamp in ipairs(lamps) do
    local made = { name = lamp.name, x = lamp.x or 0, y = lamp.y or 0, mode = "off", period = 1, since = 0, shown = 0 }
    show.lamps[lamp.name] = made
    show.order[#show.order + 1] = made
  end
  return show
end

--- Sets a lamp's own state
--- @param name string
--- @param mode string|boolean "off", "on", "blink" or "pulse", or true for on and false or nil for off
--- @param period number? Seconds a blink or pulse takes, 0.5 if not said
--- @param now number? When, so that a blink starts lit
function LightShow:Set(name, mode, period, now)
  local lamp = self.lamps[name]
  if not lamp then
    return
  end
  if mode == true then
    mode = "on"
  elseif not mode then
    mode = "off"
  end
  if lamp.mode ~= mode or lamp.period ~= (period or 0.5) then
    lamp.mode, lamp.period, lamp.since = mode, period or 0.5, now or lamp.since
  end
end

--- Puts every lamp off
function LightShow:Clear()
  for _, lamp in ipairs(self.order) do
    lamp.mode = "off"
  end
end

--- Plays a show over the lamps' own states
--- @param light fun(lamp: LightShowLamp, t: number): number? How bright each lamp is, `t` seconds in
--- @param now number
--- @param seconds number? How long it plays, for ever if not said
--- @param priority number? 1 if not said; the highest playing has its way
--- @return integer id To Stop it by
function LightShow:Play(light, now, seconds, priority)
  self.nextId = self.nextId + 1
  local show = { id = self.nextId, light = light, from = now, til = seconds and now + seconds, priority = priority or 1 }
  -- Kept with the highest priority first, the latest first among the same
  local at = #self.shows + 1
  for index, other in ipairs(self.shows) do
    if other.priority <= show.priority then
      at = index
      break
    end
  end
  table.insert(self.shows, at, show)
  return show.id
end

--- @param id integer
function LightShow:Stop(id)
  for index, show in ipairs(self.shows) do
    if show.id == id then
      table.remove(self.shows, index)
      return
    end
  end
end

--- Stops every show
function LightShow:StopAll()
  self.shows = {}
end

--- Whether a show is still playing
--- @param id integer
--- @param now number
--- @return boolean
function LightShow:Playing(id, now)
  for _, show in ipairs(self.shows) do
    if show.id == id then
      return not show.til or now < show.til
    end
  end
  return false
end

local function own(lamp, now)
  local mode = lamp.mode
  if mode == "on" then
    return 1
  elseif mode == "blink" then
    return ((now - lamp.since) % lamp.period) < lamp.period / 2 and 1 or 0
  elseif mode == "pulse" then
    local t = ((now - lamp.since) % lamp.period) / lamp.period
    return 0.5 - 0.5 * math.cos(t * 2 * math.pi)
  end
  return 0
end

--- How bright a lamp should be now, 0 to 1
--- @param name string
--- @param now number
--- @return number
function LightShow:Brightness(name, now)
  local lamp = self.lamps[name]
  if not lamp then
    return 0
  end
  for _, show in ipairs(self.shows) do
    if now >= show.from and (not show.til or now < show.til) then
      local level = show.light(lamp, now - show.from)
      if level then
        return level
      end
    end
  end
  return own(lamp, now)
end

--- Lets the shows that have ended go
--- @param now number
function LightShow:Tidy(now)
  for index = #self.shows, 1, -1 do
    local show = self.shows[index]
    if show.til and now >= show.til then
      table.remove(self.shows, index)
    end
  end
end

--- How bright a lamp looks now, a bulb taking a moment to light and to go out, after `elapsed`
--- seconds since it was last asked
--- @param name string
--- @param now number
--- @param elapsed number
--- @return number
function LightShow:Glow(name, now, elapsed)
  local lamp = self.lamps[name]
  if not lamp then
    return 0
  end
  local target = self:Brightness(name, now)
  local shown = lamp.shown
  local speed = target > shown and WARM or COOL
  shown = shown + (target - shown) * min(1, elapsed / speed)
  lamp.shown = shown
  return shown
end

-----------------------------
-- Shows
-----------------------------
-- Each makes the `light` a show is played with. The lamps a show uses can be named, in the order
-- it uses them; it uses every lamp otherwise.

local function named(list)
  if not list then
    return nil
  end
  local set = {}
  for index, name in ipairs(list) do
    set[name] = index
  end
  return set
end

LightShow.Shows = {}
local Shows = LightShow.Shows

--- Every lamp it uses flashing on and off together, `times` a second
--- @param names string[]?
--- @param times number?
function Shows.Flash(names, times)
  local set = named(names)
  local period = 1 / (times or 6)
  return function(lamp, t)
    if set and not set[lamp.name] then
      return nil
    end
    return (t % period) < period / 2 and 1 or 0
  end
end

--- A light running along the lamps in turn, `width` of them lit, going round `speed` lamps a second
--- @param names string[]
--- @param speed number?
--- @param width number?
function Shows.Chase(names, speed, width)
  local set = named(names)
  local count = #names
  speed, width = speed or 12, width or 1
  return function(lamp, t)
    local index = set[lamp.name]
    if not index then
      return nil
    end
    local head = (t * speed) % count
    local behind = (head - (index - 1)) % count
    return behind < width and 1 or 0
  end
end

--- A band of light crossing the lamps, `way` "up", "down", "left" or "right", from one side of the
--- lamps it uses to the other in `seconds`, `width` deep (in the lamps' own measure), once or
--- `repeats` times. The lamps it has passed are left be
--- @param way string
--- @param seconds number
--- @param width number
--- @param names string[]?
--- @param repeats number?
--- @param lamps table<string, LightShowLamp> The lamps, to find how far the band has to go
function Shows.Sweep(lamps, way, seconds, width, names, repeats)
  local set = named(names)
  local low, high = math.huge, -math.huge
  local across = way == "left" or way == "right"
  for name, lamp in pairs(lamps) do
    if not set or set[name] then
      local at = across and lamp.x or lamp.y
      low, high = min(low, at), max(high, at)
    end
  end
  local span = high - low + width
  return function(lamp, t)
    if set and not set[lamp.name] then
      return nil
    end
    local pass = t / seconds
    if pass >= (repeats or 1) then
      return nil
    end
    local front = (pass % 1) * (span + width)
    local at = across and lamp.x or lamp.y
    -- How far the band has come into the lamps, from the side it set out from
    local into = (way == "down" or way == "right") and at - low or high - at
    local behind = front - into
    if behind >= 0 and behind < width then
      return 1
    end
    return nil
  end
end

--- A ring of light going out from a point, `speed` a second, `width` deep
--- @param x number
--- @param y number
--- @param speed number
--- @param width number
--- @param names string[]?
function Shows.Ripple(x, y, speed, width, names)
  local set = named(names)
  return function(lamp, t)
    if set and not set[lamp.name] then
      return nil
    end
    local dx, dy = lamp.x - x, lamp.y - y
    local behind = t * speed - sqrt(dx * dx + dy * dy)
    if behind >= 0 and behind < width then
      return 1
    end
    return nil
  end
end

--- Lamps lighting at random, each for a moment, about `rate` of every lamp a second. The same
--- for the same seed
--- @param rate number
--- @param seed number?
--- @param names string[]?
function Shows.Sparkle(rate, seed, names)
  local set = named(names)
  seed = seed or 1
  return function(lamp, t)
    if set and not set[lamp.name] then
      return nil
    end
    -- A number from the lamp and the moment, the same for both always
    local slot = floor(t * rate * 4)
    local hash = 0
    local name = lamp.name
    for index = 1, #name do
      hash = (hash * 31 + name:byte(index)) % 2147483647
    end
    hash = (hash * 1103515245 + slot * 12345 + seed * 2654435761) % 2147483648
    return (hash % 4 == 0) and 1 or 0
  end
end

--- Every lamp it uses, all off
--- @param names string[]?
function Shows.Dark(names)
  local set = named(names)
  return function(lamp)
    if set and not set[lamp.name] then
      return nil
    end
    return 0
  end
end

--- One show after another, each for its seconds, round and round: what a game plays while nobody is
--- playing it
--- @param steps { light: function, seconds: number }[]
function Shows.Cycle(steps)
  local total = 0
  for _, step in ipairs(steps) do
    total = total + step.seconds
  end
  return function(lamp, t)
    local at = t % total
    for _, step in ipairs(steps) do
      if at < step.seconds then
        return step.light(lamp, at)
      end
      at = at - step.seconds
    end
    return nil
  end
end
