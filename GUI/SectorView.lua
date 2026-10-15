--------------------------
--  SectorView
--------------------------
-- What somebody standing in a sector map (Engine/SectorMap.lua) sees, drawn the way Doom drew it,
-- onto Strips (GUI/Strips.lua). Any game with a sector map can show it: the view is told where
-- the eye is and which way it looks, and draws a frame.
--
-- The map is gone through nearest first, down its tree of nodes, skipping whatever lies wholly
-- behind walls already drawn. Every seg that faces the eye is drawn a column of the screen at a
-- time: the wall it is if nothing is behind it, else the upper and lower walls where the ceiling
-- or floor beyond is lower or higher, which leaves less of that column to draw anything further
-- into. A column with a wall all the way across it is done with. Floors and ceilings are marked
-- in the columns where they are seen, as visplanes (all of one height, picture and light), and
-- drawn last a row at a time: everything on a row of a floor is equally far away, so a row is
-- one span mapped straight onto the floor's picture. The sky is drawn in columns, turning with
-- the eye and never nearer.
--
-- Things are drawn last, in the sectors that were seen, each a picture standing upright and
-- facing the eye, the frame of a sprite the thing says it shows from whichever of eight sides it
-- is seen. Every column of the screen remembers how much of it was left open past every wall
-- drawn into it, and how far away that wall was, so a thing is cut off by whatever walls are
-- nearer than it: hidden behind a corner, its feet behind a step. Middle walls that can be seen
-- through (grates, bars) are drawn then too, through what was left open where they are. Things
-- and those walls are drawn over each other furthest first, at higher levels of the screen the
-- nearer they are (Strips:SetLevel). A thing may be tinted and seen through (tint, alpha). One that
-- was seen at all is told where on the screen its top was (seenAt, seenX, seenTop), for a game to
-- show something over it: a name over somebody's head.
--
-- Nothing it works out a frame is thrown away for the client to collect: what it keeps of a wall
-- or thing until the end of the frame is kept in tables it uses again the next, a garbage
-- collection being a pause the player sees.
--
-- It is Doom's light too: a sector's light, less with distance, and walls that run up and down
-- the map a little lighter than those across it. Pictures that are animated move on with the
-- map's clock (SectorMap:Frame).
--
-- The screen is 320 by 200 of Doom's pixels, which are taller than they are wide: shown at 4 by
-- 3 it looks the way Doom did, and 320 by 168 over a status bar. At low detail half as many
-- columns are drawn, each twice as wide, which is what Doom did for a computer that was too slow.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class SectorViewOptions
--- @field width number? Pixels across, 320 if left out
--- @field height number? And down, 200
--- @field detail number? 1, or 2 to draw half as many columns, each twice as wide

--- @class SectorViewCamera
--- @field x number
--- @field y number
--- @field z number Height of the eye
--- @field angle number Radians, anticlockwise from looking along the map's x
--- @field light number? Steps of Doom's light everything is lighter by: a gun going off

--- @class SectorViewStats
--- @field pieces integer Drawn on the screen
--- @field moved integer Of those, how many had to be moved
--- @field segs integer Segs looked at
--- @field planes integer Visplanes drawn
--- @field things integer Things drawn
--- @field wallsMs number Of the time, going through the map and drawing walls
--- @field planesMs number Floors, ceilings and sky
--- @field thingsMs number Things and walls that are seen through
--- @field garbage number Kilobytes of memory the frame left to be collected, as near as can be told
--- @field ms number How long working it out and drawing it took, in Lua

--- @class SectorView
--- @field strips Strips What it draws on. Its frame is the view's: size it, then Layout
--- @field frame Frame
--- @field map SectorMap?
--- @field animates boolean Something animated was drawn the last frame: when the map's pictures move on (SectorMap:AnimationStep), the view changes
--- @field stamp integer Counts frames drawn
local SectorView = {}
SectorView.__index = SectorView
private.SectorView = SectorView

local floor, ceil, sqrt, atan, max, min = math.floor, math.ceil, math.sqrt, math.atan, math.max, math.min
local TWO_PI = math.pi * 2
-- Doom's line flags: an upper wall's picture hangs from the ceiling, a lower wall's or a
-- middle one's stands on the floor
local UPPER_UNPEGGED, LOWER_UNPEGGED = 8, 16
-- The light of a column, from its sector's (0 to 255) and how near it is: Doom's 32 shades
local SHADES = 32
-- Sky pictures are this many pixels tall, and show 4 times around the horizon
local SKY_TIMES = 4
-- Nearer than this to the eye a wall is taken to be this near
local NEAREST = 0.5
-- An empty column of a visplane
local EMPTY = 1e9
-- The levels things are drawn at over walls and floors, as Strips has them
local LOWEST, HIGHEST = -8, 7
-- How much of a thing in shadow is seen, and how dark it is
local SHADOW, SHADOW_LIGHT = 0.45, 0.25
-- A thing nearer than this to the eye isn't drawn
local THING_NEAREST = 4
local EIGHTH = math.pi / 4

--- @param flags integer
--- @param flag integer
local function has(flags, flag)
  return flags % (flag * 2) >= flag
end

--- @param parent Frame
--- @param options SectorViewOptions?
--- @return SectorView
function SectorView.New(parent, options)
  options = options or {}
  local self = setmetatable({ width = options.width or 320, height = options.height or 200, files = {}, planes = {}, used = 0,
    spanStart = {}, solid = {}, ceilingClip = {}, floorClip = {},
    stats = { pieces = 0, moved = 0, segs = 0, planes = 0, things = 0, ms = 0, wallsMs = 0, planesMs = 0, thingsMs = 0, garbage = 0 },
    -- How far away every wall drawn into a column is, and what of it was left open past it
    openCount = {}, openDepth = {}, openTop = {}, openBottom = {}, stamp = 0,
    -- What is drawn over walls and floors: the list, and what is used of the tables for it
    vis = {}, drawn = {}, seeThrough = {}, seeThroughUsed = 0, sprites = {}, spritesUsed = 0,
    wallPictures = {}, flatPictures = {}, spritePictures = {} }, SectorView)
  self.strips = private.Strips.New(parent, { width = self.width, height = self.height, filter = "NEAREST" })
  self.frame = self.strips.frame
  self:SetDetail(options.detail or 1)
  return self
end

--- Draws half as many columns, or all of them again
--- @param detail number 1 or 2
function SectorView:SetDetail(detail)
  self.detail = detail
  self.columns = floor(self.width / detail)
  self.rows = self.height
  self.centerX, self.centerY = self.columns / 2, self.rows / 2
  -- Ninety degrees across, and pixels as tall for every step away whatever the detail. The
  -- sheet stays as wide: a column at low detail is two of its pixels
  self.focalX, self.focalY = self.columns / 2, self.width / 2
end

--- After the frame changed size
function SectorView:Layout()
  self.strips:Layout()
end

--- The map to show
--- @param map SectorMap
function SectorView:SetMap(map)
  self.map = map
  self.wallPictures, self.flatPictures, self.spritePictures = {}, {}, {}
end

--- Where a picture is, and how big, by the name the map gives it
--- @return table? picture { file, width, height }
function SectorView:picture(name, flat)
  local cache = flat and self.flatPictures or self.wallPictures
  local found = cache[name]
  if found == nil then
    local data = self.map.data
    local known = (flat and data.flats or data.walls)[name]
    found = known and { file = data.folder .. (flat and "\\flats\\" or "\\walls\\") .. name, width = known.width, height = known.height } or false
    cache[name] = found
  end
  return found or nil
end

--- Where a sprite's picture is, and how big it is and where its middle and foot are
--- @return table? picture { file, width, height, left, top, fileWidth, fileHeight }
function SectorView:sprite(lump)
  local found = self.spritePictures[lump]
  if found == nil then
    local data = self.map.data
    local known = data.sprites and data.sprites[lump]
    found = known and { file = data.folder .. "\\sprites\\" .. lump, width = known.width, height = known.height, left = known.left,
      top = known.top, fileWidth = known.fileWidth, fileHeight = known.fileHeight } or false
    self.spritePictures[lump] = found
  end
  return found or nil
end

--- How light something is, 0 to 1, from Doom's colormap for its light and how near it is
--- @param light number 0 to 255
--- @param shift number One lighter or darker than the sector, for walls
--- @param level number How many shades nearer it is drawn lighter
-- How much lighter the frame being drawn is all over
local extraLight = 0

local function shade(light, shift, near)
  local index = min(15, max(0, floor(light / 16) + shift + extraLight))
  local darker = min(SHADES - 1, max(0, (15 - index) * 4 - near))
  return (SHADES - darker) / SHADES
end

--- A visplane to mark the columns a floor or ceiling is seen in
function SectorView:findPlane(height, picture, light, sky)
  local planes = self.planes
  for index = 1, self.used do
    local plane = planes[index]
    if plane.height == height and plane.picture == picture and plane.light == light then
      return plane
    end
  end
  return self:newPlane(height, picture, light, sky)
end

function SectorView:newPlane(height, picture, light, sky)
  local used = self.used + 1
  self.used = used
  local plane = self.planes[used]
  if not plane then
    plane = { top = {}, bottom = {} }
    self.planes[used] = plane
  else
    for x = plane.minX, plane.maxX do
      plane.top[x] = nil
    end
  end
  plane.height, plane.picture, plane.light, plane.sky = height, picture, light, sky
  plane.minX, plane.maxX = 1e9, -1e9
  return plane
end

--- The same visplane if none of these columns are marked in it yet, else another just like it
function SectorView:checkPlane(plane, first, last)
  local top = plane.top
  for x = max(first, plane.minX), min(last, plane.maxX) do
    if top[x] then
      plane = self:newPlane(plane.height, plane.picture, plane.light, plane.sky)
      break
    end
  end
  plane.minX, plane.maxX = min(plane.minX, first), max(plane.maxX, last)
  return plane
end

--- A picture as it is now, noting when it is one that is animated
function SectorView:frameOf(name)
  local map = self.map
  if map:IsAnimated(name) then
    self.animates = true
  end
  return map:Frame(name)
end

--- Whether a thing was drawn the last frame, so that how it looks matters to the view
--- @param thing SectorMapThing
--- @return boolean
function SectorView:Shows(thing)
  return thing.shown == self.stamp
end

--- A wall seen through, kept until it is drawn: the columns of it that can be seen
function SectorView:seeThroughWall(picture, mid, light)
  local used = self.seeThroughUsed + 1
  self.seeThroughUsed = used
  local wall = self.seeThrough[used]
  if not wall then
    wall = { kind = "wall", xs = {}, scales = {}, us = {}, tops = {}, bottoms = {}, nears = {} }
    self.seeThrough[used] = wall
  end
  wall.picture, wall.mid, wall.light, wall.count, wall.depth = picture, mid, light, 0, math.huge
  return wall
end

--- A thing to draw, kept until it is drawn
function SectorView:spriteItem()
  local used = self.spritesUsed + 1
  self.spritesUsed = used
  local item = self.sprites[used]
  if not item then
    item = { kind = "thing" }
    self.sprites[used] = item
  end
  return item
end

local function further(one, other)
  return one.depth > other.depth
end

--- A row of a floor or ceiling from one column to another, mapped onto its picture. The plane
--- and where the eye is are the view's, for the frame
local function span(self, strips, y, from, to)
  local flat = self.spanFlat
  local dy = y + 0.5 - self.centerY
  if not flat or dy == 0 then
    return
  end
  local centerX, focalX, cos, sin = self.centerX, self.focalX, self.cos, self.sin
  local distance = -self.spanHeight * self.focalY / dy
  local leftOff = (from - centerX) / focalX * distance
  local rightOff = (to + 1 - centerX) / focalX * distance
  local aheadX, aheadY = self.camX + cos * distance, self.camY + sin * distance
  local lx, ly = aheadX + sin * leftOff, aheadY - cos * leftOff
  local rx, ry = aheadX + sin * rightOff, aheadY - cos * rightOff
  local bright = shade(self.spanLight, 0, 160 / (floor(distance / 16) + 1) / 2)
  local width, height = flat.width, flat.height
  local u1, v1, u2, v2 = lx / width, -ly / height, rx / width, -ry / height
  local detail = self.detail
  strips:Mapped(from * detail, y, (to + 1) * detail, y + 1, flat.file, u1, v1, u1, v1, u2, v2, u2, v2, bright, bright, bright)
end

--- Columns of a thing from one to another, all open from the same row to the same row
local function spriteRun(strips, item, detail, from, to, rowFrom, rowTo)
  local picture, x1, wide, top, tall = item.picture, item.x1, item.x2 - item.x1, item.top, item.bottom - item.top
  local u0, u1 = (from - x1) / wide * picture.width, (to + 1 - x1) / wide * picture.width
  if item.mirrored then
    u0, u1 = picture.width - u0, picture.width - u1
  end
  strips:Quad(from * detail, rowFrom, (to + 1) * detail, rowTo + 1, picture.file, u0 / picture.fileWidth, u1 / picture.fileWidth,
    (rowFrom - top) / tall * picture.height / picture.fileHeight, (rowTo + 1 - top) / tall * picture.height / picture.fileHeight,
    item.r, item.g, item.b, item.alpha)
  -- Some of it was seen: where its middle and top are, for whatever is to be shown over it
  local thing = item.thing
  thing.seenAt, thing.seenX, thing.seenTop, thing.seenDepth = item.stamp, (x1 + wide / 2) * detail, top, item.depth
end

--- Draws a frame
--- @param camera SectorViewCamera
--- @param sink table? Something with Begin, SetLevel, Quad, Mapped and Finish to draw on instead of the view's own strips
--- @return SectorViewStats
function SectorView:Draw(camera, sink)
  local began = debugprofilestop and debugprofilestop()
  local memory = collectgarbage("count")
  local map = assert(self.map, "No map to show")
  local strips = sink or self.strips
  local columns, rows = self.columns, self.rows
  local centerX, centerY, focalX, focalY = self.centerX, self.centerY, self.focalX, self.focalY
  local camX, camY, camZ, angle = camera.x, camera.y, camera.z, camera.angle
  extraLight = camera.light or 0
  local cos, sin = math.cos(angle), math.sin(angle)
  self.camX, self.camY, self.cos, self.sin = camX, camY, cos, sin
  local behind = private.SectorMap.Behind
  local solid, ceilingClip, floorClip = self.solid, self.ceilingClip, self.floorClip
  local data, skyFlat = map.data, map.data.skyFlat
  local nodes, subsectors, segs = map.nodes, map.subsectors, map.segs
  local stats = self.stats
  stats.segs = 0
  local openCount, openDepth, openTop, openBottom = self.openCount, self.openDepth, self.openTop, self.openBottom
  self.stamp = self.stamp + 1
  local stamp = self.stamp
  -- Things and see-through walls, to draw once everything else is
  local vis = self.vis
  for index = #vis, 1, -1 do
    vis[index] = nil
  end
  self.seeThroughUsed, self.spritesUsed = 0, 0
  self.animates = false

  for x = 0, columns - 1 do
    solid[x], ceilingClip[x], floorClip[x] = false, -1, rows
    openCount[x] = 0
    if not openDepth[x] then
      openDepth[x], openTop[x], openBottom[x] = {}, {}, {}
    end
  end
  local open = columns
  self.used = 0
  strips:Begin()

  --- Which columns, if any, a line between two points of the map covers: clipped to what the
  --- eye sees, the screen's x of each end, and where the clipped ends are along it (0 to 1)
  local function project(x1, y1, x2, y2)
    local ax, ay, bx, by = x1 - camX, y1 - camY, x2 - camX, y2 - camY
    local d1, s1 = ax * cos + ay * sin, ax * sin - ay * cos
    local d2, s2 = bx * cos + by * sin, bx * sin - by * cos
    local t1, t2 = 0, 1
    -- Inside the left edge of what is seen
    local f1, f2 = d1 + s1, d2 + s2
    if f1 < 0 and f2 < 0 then
      return nil
    elseif f1 < 0 then
      t1 = f1 / (f1 - f2)
    elseif f2 < 0 then
      t2 = f1 / (f1 - f2)
    end
    -- And the right
    local g1, g2 = d1 - s1, d2 - s2
    local ga, gb = g1 + (g2 - g1) * t1, g1 + (g2 - g1) * t2
    if ga < 0 and gb < 0 then
      return nil
    elseif ga < 0 then
      t1 = t1 + (t2 - t1) * ga / (ga - gb)
    elseif gb < 0 then
      t2 = t1 + (t2 - t1) * ga / (ga - gb)
    end
    local da, sa = d1 + (d2 - d1) * t1, s1 + (s2 - s1) * t1
    local db, sb = d1 + (d2 - d1) * t2, s1 + (s2 - s1) * t2
    -- Inside what is seen a point is never further to the side than it is ahead
    local xa, xb = centerX + sa / max(da, 1e-6) * focalX, centerX + sb / max(db, 1e-6) * focalX
    return xa, xb, max(da, NEAREST), max(db, NEAREST), t1, t2
  end

  --- Whether any of a box of the map can be seen past what is drawn already
  local function boxSeen(box)
    local top, bottom, left, right = box[1], box[2], box[3], box[4]
    if camX >= left and camX <= right and camY >= bottom and camY <= top then
      return true
    end
    -- The two corners that are its outline from where the eye is: the far corner of each side
    local x1, y1, x2, y2
    if camX <= left then
      if camY >= top then
        x1, y1, x2, y2 = right, top, left, bottom
      elseif camY > bottom then
        x1, y1, x2, y2 = left, top, left, bottom
      else
        x1, y1, x2, y2 = left, top, right, bottom
      end
    elseif camX < right then
      if camY >= top then
        x1, y1, x2, y2 = right, top, left, top
      else
        x1, y1, x2, y2 = left, bottom, right, bottom
      end
    else
      if camY >= top then
        x1, y1, x2, y2 = right, bottom, left, top
      elseif camY > bottom then
        x1, y1, x2, y2 = right, bottom, right, top
      else
        x1, y1, x2, y2 = left, bottom, right, top
      end
    end
    local xa, xb = project(x1, y1, x2, y2)
    if not xa then
      return false
    end
    if xa > xb then
      xa, xb = xb, xa
    end
    for x = max(0, ceil(xa - 0.5) - 1), min(columns - 1, ceil(xb - 0.5)) do
      if not solid[x] then
        return true
      end
    end
    return false
  end

  local floorPlane, ceilingPlane

  --- Draws what of a seg can be seen in some columns
  local function wall(seg, first, last, xa, xb, da, db, ua, ub, closed)
    local front, back, side, line = seg.front, seg.back, seg.side, seg.line
    local worldTop, worldBottom = front.ceiling - camZ, front.floor - camZ
    local frontSky = front.ceilingPicture == skyFlat
    local markCeiling, markFloor = true, true
    local upper, lower, middle, masked
    local upperMid, lowerMid, middleMid, maskedMid
    local worldHigh, worldLow
    if back then
      worldHigh, worldLow = back.ceiling - camZ, back.floor - camZ
      if frontSky and back.ceilingPicture == skyFlat then
        -- The sky isn't a wall
        worldTop = worldHigh
      end
      markFloor = worldLow ~= worldBottom or back.floorPicture ~= front.floorPicture or back.light ~= front.light
      markCeiling = worldHigh ~= worldTop or back.ceilingPicture ~= front.ceilingPicture or back.light ~= front.light
      if closed then
        markCeiling, markFloor = true, true
      end
      if worldHigh < worldTop and side.upper ~= "-" then
        upper = self:picture(self:frameOf(side.upper))
        if upper then
          upperMid = has(line.flags, UPPER_UNPEGGED) and worldTop or back.ceiling + upper.height - camZ
          upperMid = upperMid + side.y
        end
      end
      if worldLow > worldBottom and side.lower ~= "-" then
        lower = self:picture(self:frameOf(side.lower))
        if lower then
          lowerMid = (has(line.flags, LOWER_UNPEGGED) and worldTop or worldLow) + side.y
        end
      end
      if side.middle ~= "-" and not closed then
        masked = self:picture(self:frameOf(side.middle))
        if masked then
          -- Hung from the lower of the two ceilings, or stood on the higher floor
          maskedMid = (has(line.flags, LOWER_UNPEGGED) and max(front.floor, back.floor) + masked.height or min(front.ceiling, back.ceiling)) - camZ + side.y
          masked = self:seeThroughWall(masked, maskedMid, front.light)
          vis[#vis + 1] = masked
        end
      end
    else
      middle = side.middle ~= "-" and self:picture(self:frameOf(side.middle)) or nil
      if middle then
        middleMid = (has(line.flags, LOWER_UNPEGGED) and front.floor + middle.height - camZ or worldTop) + side.y
      end
    end
    if front.floor >= camZ then
      markFloor = false
    end
    if front.ceiling <= camZ and not frontSky then
      markCeiling = false
    end
    if markCeiling and ceilingPlane then
      ceilingPlane = self:checkPlane(ceilingPlane, first, last)
    end
    if markFloor and floorPlane then
      floorPlane = self:checkPlane(floorPlane, first, last)
    end
    local ceilingTop, ceilingBottom = ceilingPlane and ceilingPlane.top, ceilingPlane and ceilingPlane.bottom
    local floorTop, floorBottom = floorPlane and floorPlane.top, floorPlane and floorPlane.bottom

    -- Doom's light for a wall: one lighter along the map's y, one darker along its x
    local shift = line.dy == 0 and -1 or line.dx == 0 and 1 or 0
    local light = front.light
    local iza, izb = 1 / da, 1 / db
    local uza, uzb = ua * iza, ub * izb
    local span = xb - xa
    local detail = self.detail

    for x = first, last do
      local t = span > 0 and (x + 0.5 - xa) / span or 0
      local invZ = iza + (izb - iza) * t
      local u = (uza + (uzb - uza) * t) / invZ
      local scale = focalY * invZ
      local ceilingAt, floorAt = ceilingClip[x], floorClip[x]

      local top = ceil(centerY - worldTop * scale - 0.5)
      if top <= ceilingAt then
        top = ceilingAt + 1
      end
      if markCeiling and ceilingTop then
        local bottom = min(top - 1, floorAt - 1)
        if ceilingAt + 1 <= bottom then
          ceilingTop[x], ceilingBottom[x] = ceilingAt + 1, bottom
        end
      end
      local bottom = ceil(centerY - worldBottom * scale - 0.5) - 1
      if bottom >= floorAt then
        bottom = floorAt - 1
      end
      if markFloor and floorTop then
        local from = max(bottom + 1, ceilingAt + 1)
        if from <= floorAt - 1 then
          floorTop[x], floorBottom[x] = from, floorAt - 1
        end
      end

      local near = min(47, floor(160 / max(1 / invZ, 1) * 16)) / 2
      local bright = shade(light, shift, near)
      if back then
        if upper then
          local mid = ceil(centerY - worldHigh * scale - 0.5) - 1
          if mid >= floorAt then
            mid = floorAt - 1
          end
          if mid >= top then
            local strip = floor(u) % upper.width
            strips:Quad(x * detail, top, (x + 1) * detail, mid + 1, upper.file, (strip + 0.25) / upper.width, (strip + 0.75) / upper.width,
              (upperMid + (top - centerY) / scale) / upper.height, (upperMid + (mid + 1 - centerY) / scale) / upper.height, bright, bright, bright)
            ceilingClip[x] = mid
          else
            ceilingClip[x] = top - 1
          end
        elseif markCeiling then
          ceilingClip[x] = top - 1
        end
        if lower then
          local mid = ceil(centerY - worldLow * scale - 0.5)
          if mid <= ceilingClip[x] then
            mid = ceilingClip[x] + 1
          end
          if mid <= bottom then
            local strip = floor(u) % lower.width
            strips:Quad(x * detail, mid, (x + 1) * detail, bottom + 1, lower.file, (strip + 0.25) / lower.width, (strip + 0.75) / lower.width,
              (lowerMid + (mid - centerY) / scale) / lower.height, (lowerMid + (bottom + 1 - centerY) / scale) / lower.height, bright, bright, bright)
            floorClip[x] = mid
          else
            floorClip[x] = bottom + 1
          end
        elseif markFloor then
          floorClip[x] = bottom + 1
        end
        if closed and not solid[x] then
          solid[x] = true
          open = open - 1
        end
        local count = openCount[x] + 1
        openCount[x] = count
        openDepth[x][count] = 1 / invZ
        if closed then
          openTop[x][count], openBottom[x][count] = rows, -1
        else
          openTop[x][count], openBottom[x][count] = ceilingClip[x], floorClip[x]
          if masked then
            local at = masked.count + 1
            masked.count = at
            masked.xs[at], masked.scales[at], masked.us[at] = x, scale, u
            masked.tops[at], masked.bottoms[at], masked.nears[at] = ceilingClip[x], floorClip[x], near
            masked.depth = min(masked.depth, 1 / invZ)
          end
        end
      else
        if middle and top <= bottom then
          local strip = floor(u) % middle.width
          strips:Quad(x * detail, top, (x + 1) * detail, bottom + 1, middle.file, (strip + 0.25) / middle.width, (strip + 0.75) / middle.width,
            (middleMid + (top - centerY) / scale) / middle.height, (middleMid + (bottom + 1 - centerY) / scale) / middle.height, bright, bright, bright)
        end
        if not solid[x] then
          solid[x] = true
          open = open - 1
        end
        local count = openCount[x] + 1
        openCount[x] = count
        openDepth[x][count], openTop[x][count], openBottom[x][count] = 1 / invZ, rows, -1
      end
    end
  end

  --- A seg, if it faces the eye and anything of it can be seen
  local function addSeg(seg)
    local x1, y1, x2, y2 = seg.x1, seg.y1, seg.x2, seg.y2
    if behind(x1, y1, x2 - x1, y2 - y1, camX, camY) then
      return
    end
    local xa, xb, da, db, t1, t2 = project(x1, y1, x2, y2)
    if not xa then
      return
    end
    local first, last = ceil(xa - 0.5), ceil(xb - 0.5) - 1
    if first < 0 then
      first = 0
    end
    if last > columns - 1 then
      last = columns - 1
    end
    if first > last then
      return
    end
    stats.segs = stats.segs + 1
    local front, back = seg.front, seg.back
    local closed = not back or back.ceiling <= front.floor or back.floor >= front.ceiling
    if back and not closed and back.ceiling == front.ceiling and back.floor == front.floor and back.ceilingPicture == front.ceilingPicture
      and back.floorPicture == front.floorPicture and back.light == front.light and seg.side.middle == "-" then
      -- Nothing to tell this side of it from the other
      return
    end
    -- Where along its picture each end is
    local length = sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
    local start = seg.side.x + seg.offset
    local ua, ub = start + t1 * length, start + t2 * length
    -- In runs of columns that aren't done with yet
    local runStart
    for x = first, last + 1 do
      local free = x <= last and not solid[x]
      if free and not runStart then
        runStart = x
      elseif not free and runStart then
        wall(seg, runStart, x - 1, xa, xb, da, db, ua, ub, closed)
        runStart = nil
      end
    end
  end

  local function subsector(index)
    local sub = subsectors[index]
    local sector = sub.sector
    floorPlane = sector.floor < camZ and self:findPlane(sector.floor, self:frameOf(sector.floorPicture), sector.light, false) or nil
    local sky = sector.ceilingPicture == skyFlat
    ceilingPlane = (sector.ceiling > camZ or sky) and self:findPlane(sky and 0 or sector.ceiling, sky and skyFlat or self:frameOf(sector.ceilingPicture), sky and 0 or sector.light, sky) or nil
    if sector.seen ~= stamp then
      sector.seen = stamp
      for thing in pairs(sector.things) do
        if thing.picture then
          vis[#vis + 1] = thing
        end
      end
    end
    for at = sub.first, sub.first + sub.count - 1 do
      addSeg(segs[at])
    end
  end

  local function node(at)
    if open <= 0 then
      return
    end
    if at < 0 then
      subsector(-at)
      return
    end
    local split = nodes[at]
    if behind(split.x, split.y, split.dx, split.dy, camX, camY) then
      node(split.back)
      if boxSeen(split.frontBox) then
        node(split.front)
      end
    else
      node(split.front)
      if boxSeen(split.backBox) then
        node(split.back)
      end
    end
  end
  node(map.root)
  local wallsDone = debugprofilestop and debugprofilestop()

  -- Floors and ceilings, a row at a time
  local spanStart = self.spanStart
  local detail = self.detail
  for index = 1, self.used do
    local plane = self.planes[index]
    if plane.minX <= plane.maxX then
      local top, bottom = plane.top, plane.bottom
      if plane.sky then
        local sky = self:picture(data.sky)
        if sky then
          local stretch = 200 / rows
          for x = plane.minX, plane.maxX do
            local from, to = top[x], bottom[x]
            if from and from <= to then
              local turn = angle + atan((centerX - (x + 0.5)) / focalX)
              local u = (turn / TWO_PI * SKY_TIMES) % 1
              local v0, v1 = (100 + (from - centerY) * stretch) / sky.height, (100 + (to + 1 - centerY) * stretch) / sky.height
              strips:Quad(x * detail, from, (x + 1) * detail, to + 1, sky.file, u, u + 0.25 / sky.width, v0, v1, 1, 1, 1)
            end
          end
        end
      else
        self.spanFlat, self.spanHeight, self.spanLight = self:picture(plane.picture, true), plane.height - camZ, plane.light
        -- Doom's R_MakeSpans: rows open where a column reaches them and close where one doesn't
        local t1, b1 = EMPTY, -1
        for x = plane.minX, plane.maxX + 1 do
          local t2, b2 = top[x] or EMPTY, bottom[x] or -1
          if x > plane.maxX then
            t2, b2 = EMPTY, -1
          end
          while t1 < t2 and t1 <= b1 do
            span(self, strips, t1, spanStart[t1], x - 1)
            t1 = t1 + 1
          end
          while b1 > b2 and b1 >= t1 do
            span(self, strips, b1, spanStart[b1], x - 1)
            b1 = b1 - 1
          end
          while t2 < t1 and t2 <= b2 do
            spanStart[t2] = x
            t2 = t2 + 1
          end
          while b2 > b1 and b2 >= t2 do
            spanStart[b2] = x
            b2 = b2 - 1
          end
          t1, b1 = top[x] or EMPTY, bottom[x] or -1
        end
      end
    end
  end

  local planesDone = debugprofilestop and debugprofilestop()

  -- Things and see-through walls, furthest first, each over what is behind it
  local spriteFrames = data.spriteFrames or {}
  local drawn = self.drawn
  for index = #drawn, 1, -1 do
    drawn[index] = nil
  end
  for _, item in ipairs(vis) do
    if item.kind == "wall" then
      if item.count > 0 then
        drawn[#drawn + 1] = item
      end
    else
      local thing = item
      local dx, dy = thing.x - camX, thing.y - camY
      local depth = dx * cos + dy * sin
      local frames = spriteFrames[thing.picture]
      if depth >= THING_NEAREST and frames then
        local side = dx * sin - dy * cos
        local choice = frames[1]
        if #frames == 8 then
          -- Which of its sides faces the eye: the first is its front
          local towards = math.atan2(dy, dx)
          choice = frames[floor(((towards - thing.angle + EIGHTH * 4.5) % TWO_PI) / EIGHTH) % 8 + 1]
        end
        local picture = self:sprite(choice[1])
        if picture then
          local x1 = centerX + (side - picture.left) * focalX / depth
          local x2 = x1 + picture.width * focalX / depth
          if x2 > 0 and x1 < columns then
            local top = centerY - (map:Bottom(thing) + picture.top - camZ) * focalY / depth
            thing.shown = stamp
            local sprite = self:spriteItem()
            sprite.picture, sprite.mirrored, sprite.depth, sprite.x1, sprite.x2, sprite.top = picture, choice[2], depth, x1, x2, top
            sprite.bottom = top + picture.height * focalY / depth
            local light = thing.bright and 1 or shade(thing.sector.light, 0, min(47, floor(160 / depth * 16)) / 2)
            -- A thing in shadow (Doom's spectre) is a dark shimmer; another may be tinted and seen through
            if thing.shadow then
              light = light * SHADOW_LIGHT
            end
            local tint = thing.tint
            sprite.r, sprite.g, sprite.b = tint and light * tint[1] or light, tint and light * tint[2] or light, tint and light * tint[3] or light
            sprite.alpha = thing.shadow and SHADOW or thing.alpha or 1
            sprite.thing, sprite.stamp = thing, stamp
            drawn[#drawn + 1] = sprite
          end
        end
      end
    end
  end
  table.sort(drawn, further)

  for rank, item in ipairs(drawn) do
    -- The nearest at the highest level, the walls and floors below them all
    strips:SetLevel(max(LOWEST + 1, HIGHEST - (#drawn - rank)))
    if item.kind == "wall" then
      local picture, mid, light = item.picture, item.mid, item.light
      local xs, scales, us, tops, bottoms, nears = item.xs, item.scales, item.us, item.tops, item.bottoms, item.nears
      for at = 1, item.count do
        local scale, x = scales[at], xs[at]
        local topY = centerY - mid * scale
        local from = max(ceil(topY - 0.5), tops[at] + 1)
        local to = min(ceil(topY + picture.height * scale - 0.5) - 1, bottoms[at] - 1)
        if from <= to then
          local strip = floor(us[at]) % picture.width
          local bright = shade(light, 0, nears[at])
          strips:Quad(x * detail, from, (x + 1) * detail, to + 1, picture.file, (strip + 0.25) / picture.width,
            (strip + 0.75) / picture.width, (from - topY) / scale / picture.height, (to + 1 - topY) / scale / picture.height, bright, bright, bright)
        end
      end
    else
      local depth, x1, x2, top, bottom = item.depth, item.x1, item.x2, item.top, item.bottom
      local first, last = max(0, ceil(x1 - 0.5)), min(columns - 1, ceil(x2 - 0.5) - 1)
      local fromTop, toBottom = ceil(top - 0.5), ceil(bottom - 0.5) - 1
      local runStart, runFrom, runTo
      for x = first, last + 1 do
        local from, to
        if x <= last then
          -- What is left open past the furthest wall drawn into the column that is nearer than it
          local openFrom, openTo = 0, rows - 1
          local depths = openDepth[x]
          for index = openCount[x], 1, -1 do
            if depths[index] < depth then
              openFrom, openTo = openTop[x][index] + 1, openBottom[x][index] - 1
              break
            end
          end
          from, to = max(fromTop, openFrom), min(toBottom, openTo)
          if from > to then
            from = nil
          end
        end
        if runStart and (from ~= runFrom or to ~= runTo) then
          spriteRun(strips, item, detail, runStart, x - 1, runFrom, runTo)
          runStart = nil
        end
        if from and not runStart then
          runStart, runFrom, runTo = x, from, to
        end
      end
    end
  end
  stats.things = #drawn

  stats.pieces = strips:Finish()
  stats.moved = strips.moved or 0
  stats.planes = self.used
  if began then
    local done = debugprofilestop()
    stats.ms, stats.wallsMs, stats.planesMs, stats.thingsMs = done - began, wallsDone - began, planesDone - wallsDone, done - planesDone
  end
  -- Less than there was if the collector ran meanwhile, which says nothing about this frame
  stats.garbage = max(0, collectgarbage("count") - memory)
  return stats
end
