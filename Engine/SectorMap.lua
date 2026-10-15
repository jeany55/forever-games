--------------------------
--  SectorMap
--------------------------
-- A world of rooms of different heights, the way Doom built its own: whatever a game makes of
-- it, a shooter or a maze or a walk through a building, it is drawn by GUI/SectorView.lua and
-- walked about in by way of this. It knows nothing of any game, only of floors, ceilings and walls.
--
-- Seen from above the map is lines between vertices, and every area the lines close off is a
-- sector: a floor and a ceiling, each a height and a picture, and how light it is in there. A
-- line has a side for each sector it borders, the front on its right going from its first vertex
-- to its second, the back only where there is a sector on that side too. A side says which
-- pictures it shows: the middle of a wall with nothing behind it, or where there is something
-- behind, the upper and lower walls where the ceiling or floor beyond is at another height.
--
-- To be drawn quickly the map also comes cut up the way Doom's node builders cut it: a binary
-- tree of nodes, each a line through the map with everything in front of it on one side and the
-- rest on the other, down to subsectors, small convex areas whose walls are segs, pieces of
-- lines. Whatever is in front of a node is never behind what is behind it, which is all a
-- renderer needs to go through the map nearest first. Maps are made with a Doom map editor and
-- turned into Lua by Tools/import_wad.py, nodes and all.
--
-- Things stand about in it: whatever a game puts there, a lamp, a key, somebody. The map knows
-- where each is, which sector it is in and how big it is, so that a thing that is solid is in
-- the way of whoever walks into it, whoever walks over one is told (Touching), and a view finds
-- the things to draw with the sectors it sees. What a thing is and what it looks like (its
-- picture, a frame of a sprite) is the game's business. Things that go about on their own walk
-- as Doom's monsters do (TryMoveThing): up a step but not a wall, and not off a ledge.
--
-- And it says what can be seen and hit from where, as Doom did: whether one point sees another
-- past the walls and through the gaps between floors and ceilings (Sees), what a shot along the
-- map hits (Shoot: the first thing it can reach, else the wall it stops at), and where a sound
-- carries (Noise: through every opening, but only so far past lines that muffle it).
--
-- A map is registered once, as data (Register), and every game that is played on it gets its own
-- copy to change (Load): doors that open are ceilings that move. Maps too big to load with the
-- addon are kept in an addon of their own that is loaded when they are needed, which puts them
-- in ForeverGamesSectorMaps (and other pictures in ForeverGamesSectorPictures) by their ids:
-- they are found there as well as here. Heights are in the map's units,
-- which for a map from Doom is about an inch and a half each, and points are measured across and
-- up the map. Angles are radians from looking along the map's x, growing anticlockwise.
--
-- Data a map is registered with:
--   vertices     x and y of every vertex, one after the other
--   sectors      { floor, ceiling, floorPicture, ceilingPicture, light (0 to 255), special, tag }
--   sides        { x, y (how far the pictures are moved along and down), upper, lower, middle (picture names, "-" for none), sector }
--   lines        { from, to (vertices), front, back (sides, back left out for a wall), flags, special, tag }
--   segs         { from, to, line, back (it lies along the line's back side), offset (how far along the line it starts) }
--   subsectors   { first (seg), count }
--   nodes        { x, y, dx, dy (the line), frontBox, backBox (top, bottom, left, right), front, back (a node, or a subsector counted negative) }
--   things       { x, y, angle (degrees), type, flags }: whatever stands about, for the game to make something of
--   walls, flats { [name] = { width, height } } the pictures, under folder .. "\walls\" .. name and "\flats\"
--   animations   lists of pictures that take turns, every animationTics 35ths of a second
--   sky          the picture for the sky, shown wherever a ceiling's picture is skyFlat
--   kinds        { [type] = { sprite, frames, tics, bright, radius, height, solid, hanging, pickup } } what things of a type are
--   spriteFrames { [frame] = { { lump, mirrored } } } the pictures of a frame of a sprite ("BON1A"): one, or one from each of 8 sides
--   sprites      { [lump] = { width, height, left, top, fileWidth, fileHeight } } under folder .. "\sprites\" .. lump
--
-- Other pictures that go with maps, a status bar, say, are registered as sets of their own
-- (RegisterPictures): { folder, pictures = { [name] = { width, height, left, top, fileWidth, fileHeight } } }.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class SectorMapSector
--- @field index integer
--- @field floor number Height of the floor
--- @field ceiling number
--- @field floorPicture string
--- @field ceilingPicture string
--- @field light number 0 to 255
--- @field special integer What the map says goes on in it, for the game to make something of
--- @field tag integer What lines that do something to sectors find it by
--- @field lines SectorMapLine[] Every line it is on either side of

--- @class SectorMapSide
--- @field x number How far its pictures are moved along the line
--- @field y number And down
--- @field upper string
--- @field lower string
--- @field middle string
--- @field sector SectorMapSector

--- @class SectorMapLine
--- @field index integer
--- @field x1 number
--- @field y1 number
--- @field x2 number
--- @field y2 number
--- @field dx number
--- @field dy number
--- @field length number
--- @field front SectorMapSide
--- @field back SectorMapSide? Only where there is a sector behind it
--- @field flags integer
--- @field special integer
--- @field tag integer

--- @class SectorMapSeg
--- @field x1 number
--- @field y1 number
--- @field x2 number
--- @field y2 number
--- @field line SectorMapLine
--- @field side SectorMapSide The side of the line it lies along
--- @field front SectorMapSector The sector it is seen from
--- @field back SectorMapSector? The one behind it, if any
--- @field offset number How far along its line it begins

--- @class SectorMapActor
--- @field x number
--- @field y number
--- @field z number Where its feet are
--- @field radius number
--- @field height number
--- @field step number? How high a step it can take, 24 if left out
--- @field floor number? Set by every move: the highest floor under it
--- @field ceiling number? And the lowest ceiling over it

--- @class SectorMapThing
--- @field x number
--- @field y number
--- @field z number? Where its foot is. Left out for one on the floor, or one hanging from the ceiling
--- @field angle number Radians, which way it faces
--- @field radius number
--- @field height number
--- @field solid boolean? In the way
--- @field hanging boolean? From the ceiling
--- @field picture string? The frame of a sprite it shows, nothing drawn without one
--- @field bright boolean? It lights itself
--- @field shadow boolean? It is a dark shimmer, as Doom's spectre is
--- @field tint number[]? Its colours times these, red, green and blue
--- @field alpha number? How much of it is seen, all of it if left out
--- @field seenAt integer? Set by a view (GUI/SectorView.lua): the frame some of it was last seen in (SectorView.stamp), and where on the
--- view's sheet it was, seenX across its middle and seenTop down to its top, seenDepth away
--- @field sector SectorMapSector Set by the map

--- @class SectorMapMoveOptions
--- @field speed number Units a second
--- @field onArrive (fun(sector: SectorMapSector))? Called once it gets there
--- @field canMove (fun(sector: SectorMapSector, height: number): boolean)? Asked before every step. Returning false stops it where it is, and calls onBlocked
--- @field onBlocked (fun(sector: SectorMapSector))?
--- @field delay number? Seconds to wait before it starts

--- @class SectorMap
--- @field data table What it was registered with
--- @field sectors SectorMapSector[]
--- @field sides SectorMapSide[]
--- @field lines SectorMapLine[]
--- @field segs SectorMapSeg[]
--- @field subsectors { first: integer, count: integer, sector: SectorMapSector }[]
--- @field nodes table[]
--- @field root integer The node to start from, or a subsector counted negative for a map that is one
--- @field clock number Seconds the map has been running for, by Tick
--- @field version integer Counts every change to what there is to see: a floor that moved, a thing that came or went (and Changed)
local SectorMap = {}
SectorMap.__index = SectorMap
private.SectorMap = SectorMap

-- Lines are found by the squares of a grid they cross, this many units each way
local BLOCK = 128
-- Doom's line flag for a line nothing walks through, though there is room beyond it
local BLOCKING, SOUND_BLOCKING = 1, 64
-- A shot reaches things this far above or below level, for every step away: Doom's aim
local AIM = 100 / 160
-- How high a step an actor takes in its stride unless it says
local STEP = 24
-- No move goes further than this much of the actor's radius at once, so nothing is walked through
local STRIDE = 0.5

local registry, pictureSets = {}, {}

--- Makes a map known by an id, for any game to load
--- @param id string
--- @param data table See the top of this file
function SectorMap.Register(id, data)
  registry[id] = data
end

--- A map's data, registered or put where an addon of maps puts them
local function find(id)
  return registry[id] or (ForeverGamesSectorMaps and ForeverGamesSectorMaps[id])
end

--- @param id string
--- @return boolean
function SectorMap.Has(id)
  return find(id) ~= nil
end

--- Makes a set of pictures known that goes with maps: a status bar, a font
--- @param id string
--- @param set table { folder, pictures }
function SectorMap.RegisterPictures(id, set)
  pictureSets[id] = set
end

--- @param id string
--- @return table? set
function SectorMap.Pictures(id)
  return pictureSets[id] or (ForeverGamesSectorPictures and ForeverGamesSectorPictures[id])
end

--- Which side of a line through (x, y) going (dx, dy) a point is on: false in front, which is
--- the right going along it, true behind it or on it
local function behind(x, y, dx, dy, px, py)
  return (px - x) * dy - (py - y) * dx <= 0
end
SectorMap.Behind = behind

--- A copy of a registered map to play on
--- @param id string
--- @return SectorMap
function SectorMap.Load(id)
  local data = assert(find(id), "No sector map " .. tostring(id))
  local self = setmetatable({ data = data, sectors = {}, sides = {}, lines = {}, segs = {}, subsectors = {}, movers = {}, timers = {}, clock = 0,
    stamp = 0, version = 0 }, SectorMap)
  local vertices = data.vertices

  for index, sector in ipairs(data.sectors) do
    self.sectors[index] = {
      index = index,
      floor = sector.floor,
      ceiling = sector.ceiling,
      floorPicture = sector.floorPicture,
      ceilingPicture = sector.ceilingPicture,
      light = sector.light,
      special = sector.special or 0,
      tag = sector.tag or 0,
      lines = {},
      things = {},
    }
  end
  for index, side in ipairs(data.sides) do
    self.sides[index] = { x = side.x or 0, y = side.y or 0, upper = side.upper or "-", lower = side.lower or "-", middle = side.middle or "-", sector = self.sectors[side.sector] }
  end

  local left, bottom, right, top = math.huge, math.huge, -math.huge, -math.huge
  for index, line in ipairs(data.lines) do
    local x1, y1 = vertices[line.from * 2 - 1], vertices[line.from * 2]
    local x2, y2 = vertices[line.to * 2 - 1], vertices[line.to * 2]
    local made = {
      index = index,
      x1 = x1, y1 = y1, x2 = x2, y2 = y2,
      dx = x2 - x1, dy = y2 - y1,
      length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2),
      left = math.min(x1, x2), right = math.max(x1, x2), bottom = math.min(y1, y2), top = math.max(y1, y2),
      front = self.sides[line.front],
      back = line.back and self.sides[line.back] or nil,
      flags = line.flags or 0,
      special = line.special or 0,
      tag = line.tag or 0,
      stamp = 0,
    }
    self.lines[index] = made
    table.insert(made.front.sector.lines, made)
    if made.back and made.back.sector ~= made.front.sector then
      table.insert(made.back.sector.lines, made)
    end
    left, bottom = math.min(left, made.left), math.min(bottom, made.bottom)
    right, top = math.max(right, made.right), math.max(top, made.top)
  end

  for index, seg in ipairs(data.segs) do
    local line = self.lines[seg.line]
    local side, other = line.front, line.back
    if seg.back then
      side, other = line.back, line.front
    end
    self.segs[index] = {
      x1 = vertices[seg.from * 2 - 1], y1 = vertices[seg.from * 2],
      x2 = vertices[seg.to * 2 - 1], y2 = vertices[seg.to * 2],
      line = line,
      side = side,
      front = side.sector,
      back = other and other.sector or nil,
      offset = seg.offset or 0,
    }
  end
  for index, subsector in ipairs(data.subsectors) do
    self.subsectors[index] = { first = subsector.first, count = subsector.count, sector = self.segs[subsector.first].front }
  end
  self.nodes = data.nodes or {}
  self.root = #self.nodes > 0 and #self.nodes or -1

  -- The grid that finds lines near a point
  self.gridLeft, self.gridBottom = left, bottom
  self.columns = math.floor((right - left) / BLOCK) + 1
  self.rows = math.floor((top - bottom) / BLOCK) + 1
  self.blocks, self.thingBlocks = {}, {}
  for _, line in ipairs(self.lines) do
    for column = math.floor((line.left - left) / BLOCK), math.floor((line.right - left) / BLOCK) do
      for row = math.floor((line.bottom - bottom) / BLOCK), math.floor((line.top - bottom) / BLOCK) do
        -- Only the squares the line goes through, not every one its corners make a box of
        local x0, y0 = left + column * BLOCK, bottom + row * BLOCK
        local corners = behind(line.x1, line.y1, line.dx, line.dy, x0, y0)
        local crosses = false
        for _, corner in ipairs({ { x0 + BLOCK, y0 }, { x0, y0 + BLOCK }, { x0 + BLOCK, y0 + BLOCK } }) do
          if behind(line.x1, line.y1, line.dx, line.dy, corner[1], corner[2]) ~= corners then
            crosses = true
          end
        end
        if crosses or line.dx == 0 or line.dy == 0 then
          local key = row * self.columns + column + 1
          self.blocks[key] = self.blocks[key] or {}
          table.insert(self.blocks[key], line)
        end
      end
    end
  end
  return self
end

--- The subsector a point is in, and so its sector
--- @param x number
--- @param y number
--- @return table subsector
function SectorMap:SubsectorAt(x, y)
  local nodes, at = self.nodes, self.root
  while at > 0 do
    local node = nodes[at]
    at = behind(node.x, node.y, node.dx, node.dy, x, y) and node.back or node.front
  end
  return self.subsectors[-at]
end

--- @param x number
--- @param y number
--- @return SectorMapSector
function SectorMap:SectorAt(x, y)
  return self:SubsectorAt(x, y).sector
end

--- Every line that crosses a square of the grid a box touches, each once
--- @param left number
--- @param bottom number
--- @param right number
--- @param top number
--- @param out SectorMapLine[] Emptied and filled
--- @return SectorMapLine[] out
function SectorMap:LinesNear(left, bottom, right, top, out)
  for index = #out, 1, -1 do
    out[index] = nil
  end
  self.stamp = self.stamp + 1
  local stamp, blocks, columns = self.stamp, self.blocks, self.columns
  local fromColumn = math.max(0, math.floor((left - self.gridLeft) / BLOCK))
  local toColumn = math.min(columns - 1, math.floor((right - self.gridLeft) / BLOCK))
  local fromRow = math.max(0, math.floor((bottom - self.gridBottom) / BLOCK))
  local toRow = math.min(self.rows - 1, math.floor((top - self.gridBottom) / BLOCK))
  for row = fromRow, toRow do
    for column = fromColumn, toColumn do
      local block = blocks[row * columns + column + 1]
      if block then
        for _, line in ipairs(block) do
          if line.stamp ~= stamp then
            line.stamp = stamp
            out[#out + 1] = line
          end
        end
      end
    end
  end
  return out
end

--- How much room there is through a line: from the higher of its floors to the lower of its
--- ceilings. None for a line with nothing behind it
--- @param line SectorMapLine
--- @return number bottom
--- @return number top
function SectorMap.Opening(line)
  if not line.back then
    return 0, 0
  end
  local front, back = line.front.sector, line.back.sector
  return math.max(front.floor, back.floor), math.min(front.ceiling, back.ceiling)
end

local near, nearThings = {}, {}

--- The square of the grid a point is in, as its key, or nil off the grid
function SectorMap:block(x, y)
  local column, row = math.floor((x - self.gridLeft) / BLOCK), math.floor((y - self.gridBottom) / BLOCK)
  if column < 0 or row < 0 or column >= self.columns or row >= self.rows then
    return nil
  end
  return row * self.columns + column + 1
end

--- Puts a thing in the map, where it says it is
--- @param thing SectorMapThing
function SectorMap:AddThing(thing)
  self.version = self.version + 1
  thing.sector = self:SectorAt(thing.x, thing.y)
  thing.sector.things[thing] = true
  local key = self:block(thing.x, thing.y)
  thing.block = key
  if key then
    self.thingBlocks[key] = self.thingBlocks[key] or {}
    self.thingBlocks[key][thing] = true
  end
end

--- Takes a thing out of the map
--- @param thing SectorMapThing
function SectorMap:RemoveThing(thing)
  self.version = self.version + 1
  if thing.sector then
    thing.sector.things[thing] = nil
    thing.sector = nil
  end
  if thing.block and self.thingBlocks[thing.block] then
    self.thingBlocks[thing.block][thing] = nil
  end
  thing.block = nil
end

--- Puts a thing where it now is in the grid and its sector, saying the view changed if it is seen
function SectorMap:relink(thing, x, y)
  if thing.picture then
    self.version = self.version + 1
  end
  thing.sector.things[thing] = nil
  if thing.block and self.thingBlocks[thing.block] then
    self.thingBlocks[thing.block][thing] = nil
  end
  thing.x, thing.y = x, y
  thing.sector = self:SectorAt(x, y)
  thing.sector.things[thing] = true
  local key = self:block(x, y)
  thing.block = key
  if key then
    self.thingBlocks[key] = self.thingBlocks[key] or {}
    self.thingBlocks[key][thing] = true
  end
end

local thingTouched = {}

--- Walks a thing to a point if it can get there: there is room for it, it isn't too high a step
--- up, and unless it may it isn't a drop of more than a step either
--- @param thing SectorMapThing
--- @param x number
--- @param y number
--- @param drops boolean? It may step off a ledge
--- @return boolean moved
--- @return SectorMapLine[] touched The lines it was up against, where it would have been. Used again by the next call
function SectorMap:TryMoveThing(thing, x, y, drops)
  local blocked, floor, ceiling, lowest = self:Check(x, y, thing.radius, thingTouched, thing)
  local z = self:Bottom(thing)
  if blocked or ceiling - floor < thing.height or ceiling - z < thing.height or floor - z > STEP or (not drops and floor - lowest > STEP) then
    return false, thingTouched
  end
  self:relink(thing, x, y)
  return true, thingTouched
end

--- Moves a thing to another point, without asking whether there is room for it there
--- @param thing SectorMapThing
--- @param x number
--- @param y number
function SectorMap:MoveThing(thing, x, y)
  self:RemoveThing(thing)
  thing.x, thing.y = x, y
  self:AddThing(thing)
end

--- How high a thing's foot is: on the floor of its sector, or as far under the ceiling as it is tall
--- @param thing SectorMapThing
--- @return number
function SectorMap:Bottom(thing)
  if thing.z then
    return thing.z
  end
  local sector = thing.sector
  return thing.hanging and sector.ceiling - thing.height or sector.floor
end

--- Every thing whose square (as wide as it is, each way from its middle) overlaps one around a point
--- @param x number
--- @param y number
--- @param radius number
--- @param out SectorMapThing[] Emptied and filled
--- @return SectorMapThing[] out
function SectorMap:Touching(x, y, radius, out)
  for index = #out, 1, -1 do
    out[index] = nil
  end
  -- A thing is in the square of the grid its middle is in, so look as far as the widest could reach
  local reach = radius + BLOCK / 2
  local columns, blocks = self.columns, self.thingBlocks
  local fromColumn = math.max(0, math.floor((x - reach - self.gridLeft) / BLOCK))
  local toColumn = math.min(columns - 1, math.floor((x + reach - self.gridLeft) / BLOCK))
  local fromRow = math.max(0, math.floor((y - reach - self.gridBottom) / BLOCK))
  local toRow = math.min(self.rows - 1, math.floor((y + reach - self.gridBottom) / BLOCK))
  for row = fromRow, toRow do
    for column = fromColumn, toColumn do
      local block = blocks[row * columns + column + 1]
      if block then
        for thing in pairs(block) do
          local apart = thing.radius + radius
          if math.abs(thing.x - x) < apart and math.abs(thing.y - y) < apart then
            out[#out + 1] = thing
          end
        end
      end
    end
  end
  return out
end

--- What an actor standing at a point would have about it: the highest floor and lowest
--- ceiling under and over the square it takes up, and whether a wall is in the way
--- @param x number
--- @param y number
--- @param radius number
--- @param touched SectorMapLine[]? Filled with every line it overlaps
--- @param mover table? Whoever is asking, who isn't in their own way, nor whoever fired it if it is a shot (mover.source)
--- @return boolean blocked A wall, a line that is drawn as one or a solid thing is where it would be
--- @return number floor
--- @return number ceiling
--- @return number lowest The lowest floor under it, for whoever minds stepping off a ledge
function SectorMap:Check(x, y, radius, touched, mover)
  local sector = self:SectorAt(x, y)
  local floor, ceiling = sector.floor, sector.ceiling
  local lowest = floor
  local left, right, bottom, top = x - radius, x + radius, y - radius, y + radius
  if touched then
    for index = #touched, 1, -1 do
      touched[index] = nil
    end
  end
  for _, line in ipairs(self:LinesNear(left, bottom, right, top, near)) do
    if line.right > left and line.left < right and line.top > bottom and line.bottom < top then
      -- The square is on both sides of it
      local x1, y1, dx, dy = line.x1, line.y1, line.dx, line.dy
      local side = behind(x1, y1, dx, dy, left, bottom)
      if behind(x1, y1, dx, dy, right, bottom) ~= side or behind(x1, y1, dx, dy, left, top) ~= side or behind(x1, y1, dx, dy, right, top) ~= side then
        if touched then
          touched[#touched + 1] = line
        end
        if not line.back or line.flags % (BLOCKING * 2) >= BLOCKING then
          return true, floor, ceiling, lowest
        end
        local low, high = SectorMap.Opening(line)
        floor, ceiling = math.max(floor, low), math.min(ceiling, high)
        lowest = math.min(lowest, line.front.sector.floor, line.back.sector.floor)
      end
    end
  end
  local source = mover and mover.source
  for _, thing in ipairs(self:Touching(x, y, radius, nearThings)) do
    if thing.solid and thing ~= mover and thing ~= source then
      return true, floor, ceiling, lowest
    end
  end
  return false, floor, ceiling, lowest
end

local touched = {}

--- Moves an actor to a point if there is room for it there, and it isn't too high a step up
--- @param actor SectorMapActor Moved, with its floor and ceiling set, if it can be
--- @param x number
--- @param y number
--- @param crossed SectorMapLine[]? Lines with a special that its middle went over on the way are added to this
--- @return boolean moved
function SectorMap:TryMove(actor, x, y, crossed)
  local blocked, floor, ceiling = self:Check(x, y, actor.radius, touched, actor)
  if blocked or ceiling - floor < actor.height or ceiling - actor.z < actor.height or floor - actor.z > (actor.step or STEP) then
    return false
  end
  if actor.block then
    -- One of the map's things: where it is in the grid goes with it
    self:relink(actor, x, y)
  end
  if crossed then
    for _, line in ipairs(touched) do
      if line.special ~= 0 and behind(line.x1, line.y1, line.dx, line.dy, actor.x, actor.y) ~= behind(line.x1, line.y1, line.dx, line.dy, x, y) then
        crossed[#crossed + 1] = line
      end
    end
  end
  actor.x, actor.y, actor.floor, actor.ceiling = x, y, floor, ceiling
  return true
end

--- Moves an actor by as much of a step as it can take: all of it, or along whichever way across
--- or up the map isn't in the way, so that walking into a wall at an angle slides along it. A
--- long step is taken a little at a time
--- @param actor SectorMapActor
--- @param dx number
--- @param dy number
--- @param crossed SectorMapLine[]? As TryMove
--- @return boolean moved At all
function SectorMap:Slide(actor, dx, dy, crossed)
  local steps = math.max(1, math.ceil(math.sqrt(dx * dx + dy * dy) / (actor.radius * STRIDE)))
  local stepX, stepY, moved = dx / steps, dy / steps, false
  for _ = 1, steps do
    local x, y = actor.x, actor.y
    if self:TryMove(actor, x + stepX, y + stepY, crossed) or (stepX ~= 0 and self:TryMove(actor, x + stepX, y, crossed)) or (stepY ~= 0 and self:TryMove(actor, x, y + stepY, crossed)) then
      moved = true
    else
      break
    end
  end
  return moved
end

--- Settles an actor on whatever floor is under it, for after the floor moved or it stepped
--- down. It falls, it doesn't drop: `fall` units at most
--- @param actor SectorMapActor
--- @param fall number?
function SectorMap:Settle(actor, fall)
  local _, floor, ceiling = self:Check(actor.x, actor.y, actor.radius)
  actor.floor, actor.ceiling = floor, ceiling
  if actor.z > floor then
    actor.z = math.max(floor, actor.z - (fall or math.huge))
  else
    actor.z = floor
  end
end

local along, alongThings = {}, {}

--- Every line in the squares of the grid a line between two points goes through, each once,
--- and with things the things in and next to those squares
--- @return SectorMapLine[] lines
--- @return SectorMapThing[]? things
function SectorMap:LinesAlong(x1, y1, x2, y2, withThings)
  for index = #along, 1, -1 do
    along[index] = nil
  end
  for index = #alongThings, 1, -1 do
    alongThings[index] = nil
  end
  self.stamp = self.stamp + 1
  local stamp, blocks, thingBlocks, columns, rows = self.stamp, self.blocks, self.thingBlocks, self.columns, self.rows
  local gx1, gy1 = (x1 - self.gridLeft) / BLOCK, (y1 - self.gridBottom) / BLOCK
  local gx2, gy2 = (x2 - self.gridLeft) / BLOCK, (y2 - self.gridBottom) / BLOCK
  local column, row = math.floor(gx1), math.floor(gy1)
  local lastColumn, lastRow = math.floor(gx2), math.floor(gy2)
  local dx, dy = gx2 - gx1, gy2 - gy1
  local stepX, stepY = dx > 0 and 1 or -1, dy > 0 and 1 or -1
  local nextX = dx ~= 0 and (stepX > 0 and column + 1 - gx1 or gx1 - column) / math.abs(dx) or math.huge
  local nextY = dy ~= 0 and (stepY > 0 and row + 1 - gy1 or gy1 - row) / math.abs(dy) or math.huge
  local deltaX, deltaY = dx ~= 0 and 1 / math.abs(dx) or math.huge, dy ~= 0 and 1 / math.abs(dy) or math.huge
  for _ = 1, columns + rows + 2 do
    if column >= 0 and row >= 0 and column < columns and row < rows then
      local block = blocks[row * columns + column + 1]
      if block then
        for _, line in ipairs(block) do
          if line.stamp ~= stamp then
            line.stamp = stamp
            along[#along + 1] = line
          end
        end
      end
    end
    if withThings then
      for aroundRow = row - 1, row + 1 do
        for aroundColumn = column - 1, column + 1 do
          local block = aroundColumn >= 0 and aroundRow >= 0 and aroundColumn < columns and aroundRow < rows and thingBlocks[aroundRow * columns + aroundColumn + 1]
          if block then
            for thing in pairs(block) do
              if thing.stamp ~= stamp then
                thing.stamp = stamp
                alongThings[#alongThings + 1] = thing
              end
            end
          end
        end
      end
    end
    if column == lastColumn and row == lastRow then
      break
    end
    if nextX < nextY then
      nextX, column = nextX + deltaX, column + stepX
    else
      nextY, row = nextY + deltaY, row + stepY
    end
  end
  return along, withThings and alongThings or nil
end

--- How far along a line between two points (0 to 1) it crosses a line of the map, if it does
local function crossing(line, x1, y1, x2, y2)
  local dx, dy = x2 - x1, y2 - y1
  if behind(line.x1, line.y1, line.dx, line.dy, x1, y1) == behind(line.x1, line.y1, line.dx, line.dy, x2, y2)
    or behind(x1, y1, dx, dy, line.x1, line.y1) == behind(x1, y1, dx, dy, line.x2, line.y2) then
    return nil
  end
  local denominator = dx * line.dy - dy * line.dx
  return denominator ~= 0 and ((line.x1 - x1) * line.dy - (line.y1 - y1) * line.dx) / denominator or 0
end

local function sooner(one, other)
  return one.at < other.at
end
local events, eventPool = {}, {}

--- Whether an eye at one point sees any of what is between two heights at another: Doom's
--- line of sight, past the edges of every floor and ceiling between them
--- @param x1 number
--- @param y1 number
--- @param z1 number The eye's height
--- @param x2 number
--- @param y2 number
--- @param bottom number What is looked for, from this high
--- @param top number To this high
--- @return boolean
function SectorMap:Sees(x1, y1, z1, x2, y2, bottom, top)
  local total = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
  if total < 1 then
    return true
  end
  local topSlope, bottomSlope = (top - z1) / total, (bottom - z1) / total
  local count = 0
  for _, line in ipairs(self:LinesAlong(x1, y1, x2, y2)) do
    local at = crossing(line, x1, y1, x2, y2)
    if at then
      if not line.back then
        return false
      end
      count = count + 1
      local event = eventPool[count] or {}
      eventPool[count] = event
      event.at, event.line = at, line
      events[count] = event
    end
  end
  for index = #events, count + 1, -1 do
    events[index] = nil
  end
  table.sort(events, sooner)
  for _, event in ipairs(events) do
    local line = event.line
    local front, back = line.front.sector, line.back.sector
    local low, high = SectorMap.Opening(line)
    if low >= high then
      return false
    end
    local distance = event.at * total
    if front.floor ~= back.floor then
      bottomSlope = math.max(bottomSlope, (low - z1) / distance)
    end
    if front.ceiling ~= back.ceiling then
      topSlope = math.min(topSlope, (high - z1) / distance)
    end
    if topSlope <= bottomSlope then
      return false
    end
  end
  return true
end

--- @class SectorMapShot
--- @field thing SectorMapThing? What was hit, if a thing was
--- @field line SectorMapLine? Else the line of the wall it stopped at, if it did
--- @field x number Where the shot stopped
--- @field y number
--- @field z number
--- @field distance number

--- A shot from a point along the map, Doom's way: it is aimed first, up or down at the first thing
--- in its way that can be shot and can be seen past every edge of floor and ceiling between (as
--- far up or down as Doom aimed for the player), on a ledge above or in a pit below. With nothing
--- to aim at it is fired level, and stops at the first wall it meets at that height
--- @param x number
--- @param y number
--- @param z number The height it is fired from
--- @param angle number
--- @param range number
--- @param shooter table? Who fired, who isn't hit by it
--- @param shootable fun(thing: SectorMapThing): boolean What can be hit
--- @param shot SectorMapShot Filled in
--- @return SectorMapShot shot
function SectorMap:Shoot(x, y, z, angle, range, shooter, shootable, shot)
  local cos, sin = math.cos(angle), math.sin(angle)
  local toX, toY = x + cos * range, y + sin * range
  local lines, things = self:LinesAlong(x, y, toX, toY, true)
  local count = 0
  local function add(at, line, thing)
    count = count + 1
    local event = eventPool[count] or {}
    eventPool[count] = event
    event.at, event.line, event.thing = at, line, thing
    events[count] = event
  end
  for _, line in ipairs(lines) do
    local at = crossing(line, x, y, toX, toY)
    if at then
      add(at, line, nil)
    end
  end
  for _, thing in ipairs(things) do
    if thing ~= shooter and shootable(thing) then
      -- Along the shot and how far to the side of it its middle is
      local ahead = (thing.x - x) * cos + (thing.y - y) * sin
      local aside = math.abs((thing.x - x) * sin - (thing.y - y) * cos)
      if ahead > 0 and ahead <= range and aside < thing.radius then
        add(math.max(0, ahead - thing.radius) / range, nil, thing)
      end
    end
  end
  for index = #events, count + 1, -1 do
    events[index] = nil
  end
  table.sort(events, sooner)
  local topSlope, bottomSlope = AIM, -AIM
  -- Where a level shot stops, and whether there is still anything that can be aimed at
  local stopAt, stopLine, aiming = nil, nil, true
  for _, event in ipairs(events) do
    local distance = math.max(1, event.at * range)
    local line, thing = event.line, event.thing
    if line then
      local low, high = SectorMap.Opening(line)
      if not line.back or low >= high then
        if not stopAt then
          stopAt, stopLine = event.at, line
        end
        break
      end
      if not stopAt and (z < low or z > high) then
        stopAt, stopLine = event.at, line
      end
      if aiming then
        local front, back = line.front.sector, line.back.sector
        if front.floor ~= back.floor then
          bottomSlope = math.max(bottomSlope, (low - z) / distance)
        end
        if front.ceiling ~= back.ceiling then
          topSlope = math.min(topSlope, (high - z) / distance)
        end
        aiming = topSlope > bottomSlope
      end
      if not aiming and stopAt then
        break
      end
    elseif aiming then
      local bottom = self:Bottom(thing)
      local thingTop, thingBottom = (bottom + thing.height - z) / distance, (bottom - z) / distance
      if thingTop > bottomSlope and thingBottom < topSlope then
        shot.thing, shot.line, shot.distance = thing, nil, distance
        shot.x, shot.y = thing.x - cos * thing.radius, thing.y - sin * thing.radius
        -- Aimed at its middle, or as near it as can be reached
        local slope = math.max(bottomSlope, math.min(topSlope, (thingTop + thingBottom) / 2))
        shot.z = z + slope * distance
        return shot
      end
    end
  end
  -- Short of the wall, so that what it leaves is seen in front of it
  local distance = math.max(0, (stopAt or 1) * range - 4)
  shot.thing, shot.line, shot.distance = nil, stopLine, distance
  shot.x, shot.y, shot.z = x + cos * distance, y + sin * distance, z
  return shot
end

--- Lets a sound be heard from a sector: every sector it carries to remembers who made it, as
--- far as it carries past lines that are open between them, and only past one line that muffles
--- sound (Doom's flag for it)
--- @param sector SectorMapSector
--- @param source table Who made it
function SectorMap:Noise(sector, source)
  self.stamp = self.stamp + 1
  local stamp = self.stamp
  local function spread(at, muffled)
    if at.heard == stamp and at.muffled <= muffled then
      return
    end
    at.heard, at.muffled, at.soundTarget = stamp, muffled, source
    for _, line in ipairs(at.lines) do
      if line.back then
        local low, high = SectorMap.Opening(line)
        if high > low then
          local other = line.front.sector == at and line.back.sector or line.front.sector
          if line.flags % (SOUND_BLOCKING * 2) >= SOUND_BLOCKING then
            if muffled == 0 then
              spread(other, 1)
            end
          else
            spread(other, muffled)
          end
        end
      end
    end
  end
  spread(sector, 0)
end

--- What is first in the way of a line of sight: the nearest line it crosses that does something
--- (has a special) or has no room through it
--- @param x number From
--- @param y number
--- @param angle number
--- @param range number How far it reaches
--- @return SectorMapLine? line
--- @return boolean front The line was reached from its front
function SectorMap:Trace(x, y, angle, range)
  local toX, toY = x + math.cos(angle) * range, y + math.sin(angle) * range
  local best, bestAt, bestFront
  for _, line in ipairs(self:LinesAlong(x, y, toX, toY)) do
    local at = crossing(line, x, y, toX, toY)
    if at then
      local low, high = SectorMap.Opening(line)
      if (line.special ~= 0 or high - low <= 0) and (not bestAt or at < bestAt) then
        best, bestAt, bestFront = line, at, not behind(line.x1, line.y1, line.dx, line.dy, x, y)
      end
    end
  end
  return best, bestFront == true
end

--- Every sector across a line from this one
--- @param sector SectorMapSector
--- @return SectorMapSector[]
function SectorMap:Neighbours(sector)
  if not sector.neighbours then
    local list, seen = {}, { [sector] = true }
    for _, line in ipairs(sector.lines) do
      for _, side in ipairs({ line.front, line.back }) do
        if side and not seen[side.sector] then
          seen[side.sector] = true
          list[#list + 1] = side.sector
        end
      end
    end
    sector.neighbours = list
  end
  return sector.neighbours
end

--- The lowest or highest floor or ceiling of the sectors next to one
--- @param sector SectorMapSector
--- @param plane "floor"|"ceiling"
--- @param highest boolean?
--- @return number? Nil for a sector with nothing next to it
function SectorMap:Neighbouring(sector, plane, highest)
  local found
  for _, other in ipairs(self:Neighbours(sector)) do
    local height = other[plane]
    if not found or (highest and height > found) or (not highest and height < found) then
      found = height
    end
  end
  return found
end

--- Every sector with a tag
--- @param tag integer
--- @return SectorMapSector[]
function SectorMap:Tagged(tag)
  local list = {}
  if tag ~= 0 then
    for _, sector in ipairs(self.sectors) do
      if sector.tag == tag then
        list[#list + 1] = sector
      end
    end
  end
  return list
end

--- Sets a floor or ceiling moving to another height. Whatever it was doing before it stops doing
--- @param sector SectorMapSector
--- @param plane "floor"|"ceiling"
--- @param target number
--- @param options SectorMapMoveOptions
function SectorMap:Move(sector, plane, target, options)
  self.movers[sector.index .. plane] = { sector = sector, plane = plane, target = target, options = options, wait = options.delay or 0 }
end

--- What a floor or ceiling is moving to, if it is
--- @param sector SectorMapSector
--- @param plane "floor"|"ceiling"
--- @return number? target
function SectorMap:Moving(sector, plane)
  local mover = self.movers[sector.index .. plane]
  return mover and mover.target
end

--- Moves whatever is moving along for so many seconds
--- @param seconds number
function SectorMap:Tick(seconds)
  self.clock = self.clock + seconds
  local arrived = {}
  for key, mover in pairs(self.movers) do
    if mover.wait > 0 then
      mover.wait = mover.wait - seconds
    else
      local sector, plane, options = mover.sector, mover.plane, mover.options
      local now = sector[plane]
      local step = options.speed * seconds
      local height = now < mover.target and math.min(mover.target, now + step) or math.max(mover.target, now - step)
      if options.canMove and not options.canMove(sector, height) then
        self.movers[key] = nil
        if options.onBlocked then
          arrived[#arrived + 1] = { options.onBlocked, sector }
        end
      else
        if height ~= now then
          sector[plane] = height
          self.version = self.version + 1
        end
        if height == mover.target then
          self.movers[key] = nil
          if options.onArrive then
            arrived[#arrived + 1] = { options.onArrive, sector }
          end
        end
      end
    end
  end
  -- Only once every mover has moved, as what is called may well set the sector moving again
  for _, call in ipairs(arrived) do
    call[1](call[2])
  end
  local timers, due = self.timers, {}
  for index = #timers, 1, -1 do
    if timers[index].at <= self.clock then
      table.insert(due, 1, table.remove(timers, index).call)
    end
  end
  for _, call in ipairs(due) do
    call()
  end
end

--- Says that something changed that is seen, that the map can't tell by itself: a picture on a
--- wall, a thing that shows another frame
function SectorMap:Changed()
  self.version = self.version + 1
end

--- How many times animated pictures have moved on, by the map's clock: when this is the same
--- as it was, so are they
--- @return integer
function SectorMap:AnimationStep()
  return math.floor(self.clock * 35 / (self.data.animationTics or 8))
end

--- Calls something once so many seconds have gone by on the map's clock
--- @param seconds number
--- @param call fun()
function SectorMap:After(seconds, call)
  table.insert(self.timers, { at = self.clock + seconds, call = call })
end

--- Whether a picture is one of an animation's frames
--- @param name string
--- @return boolean
function SectorMap:IsAnimated(name)
  self:Frame(name)
  return self.animated[name] ~= nil
end

--- The picture to show for one that may be animated, at the map's clock
--- @param name string
--- @return string
function SectorMap:Frame(name)
  local animated = self.animated
  if not animated then
    animated = {}
    for _, sequence in ipairs(self.data.animations or {}) do
      for index, frame in ipairs(sequence) do
        animated[frame] = { sequence = sequence, index = index }
      end
    end
    self.animated = animated
  end
  local found = animated[name]
  if not found then
    return name
  end
  local sequence = found.sequence
  return sequence[(found.index - 1 + self:AnimationStep()) % #sequence + 1]
end
