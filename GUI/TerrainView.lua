--------------------------
--  TerrainView
--------------------------
-- A view over a course (Engine/Course.lua) from a camera above it: hills, the road, the sky, and
-- whatever stands on the ground, for a racing game to drive round in.
--
-- The screen is a sheet of its own size (960 by 600, say), cut into a grid: rows, as thin near
-- the horizon as they need to be and every few pixels above it, by bands across. Along each edge
-- between two bands a ray goes out over the ground, a little further each step, and the row of
-- the screen each step reaches is worked out from how high the ground is there; a step higher on
-- the screen than any before it is seen, one lower is behind something nearer. That tells for
-- every corner of the grid which spot of the ground it shows, or that it shows sky. Each cell of
-- the grid is then a picture mapped by its four corners, with all eight texture coordinates,
-- onto the ground. The cells never move, only what they show: the cheap kind of change
-- (Tools/DoomBench measured a moved piece at four times one only shown another part of its picture).
--
-- The ground is two pictures, one over the other: the client's own ground (Tanaris sand, say),
-- repeated, and over it the course's picture, made by Tools/make_course.py, which has the road,
-- rock and the sun's light and shade in it and lets the ground under it show through elsewhere.
-- With "own" ground, or if the client's can't be had, the course's picture with its own ground
-- already in it is drawn alone. Beyond the map the ground is the repeated one only, lit as flat
-- ground is: the course's picture is as lit as that all round its edge, so the two meet unseen.
--
-- A hill's outline is a straight line from one band to the next, not a step: one piece across
-- the band, cut off along the line by a wedge-shaped mask (Images wedgerise, wedgefall). Against
-- the sky it is drawn up to a line between where the rays at the band's sides see the top of the
-- hills. Where one ray sees a near hill and the other what is beyond it, the cells between show
-- what is beyond and the piece draws the near hill over them up to a line between where it
-- crests on each side. A client without masks gets strips a few pixels wide instead.
--
-- Things on the ground are the client's 3D models (PlayerModel), or pictures: the course's own
-- (a cactus, a water tower) and any the game passes each frame (the karts). Each is drawn as big
-- as it is far, the nearer over the further, cut off where a crest nearer than it hides it, and
-- only the nearest so many models at once, as each costs (about 0.12 ms a frame in the bench).

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class TerrainViewOptions
--- @field width number The sheet's own pixels across
--- @field height number And down
--- @field horizon number How far down the sheet the horizon is
--- @field focal number How many pixels across one unit is, one unit away
--- @field folder string Where the course's pictures are, ending in a backslash
--- @field bands integer? How many bands across (16)
--- @field rows integer? How many rows below the horizon (120)
--- @field above number? How far above the horizon a hill can be seen (132), with a row every ABOVE pixels
--- @field cameraHeight number? How high above the ground the camera usually is (14), for the rows
--- @field ground string? "client" for the client's ground under the course's picture, "own" for the course's alone
--- @field masks boolean? false for strips rather than masks, as a client without them has
--- @field models integer? How many models are drawn at most (24)
--- @field filter string? How pictures are sampled, "NEAREST" for pixels that stay square

--- @class TerrainThing
--- @field x number
--- @field y number
--- @field z number? How high, the ground under it if not said
--- @field size number How big it is drawn, in units: the side of the square it fits in
--- @field heading number? The way its front faces
--- @field display integer? A creature's display, drawn as a model
--- @field model integer|string? A model's file, drawn as a model
--- @field unit string? A unit, "player" say, drawn as a model
--- @field sprite string? A picture, seen from behind, tinted `colour`
--- @field colour number[]?
--- @field alpha number?
--- @field animation integer? For a model

--- @class TerrainCamera
--- @field x number
--- @field y number
--- @field z number
--- @field heading number

--- @class TerrainView
--- @field frame Frame
--- @field course Course?
--- @field split { cast: number, fill: number, things: number, frames: integer } Milliseconds spent on each, in all, and over how many frames
--- @field loaded { tile: any, overlay: any } What SetTexture said of the client's ground and the course's picture
--- @field drawn integer Things drawn the last frame
local TerrainView = {}
TerrainView.__index = TerrainView
private.TerrainView = TerrainView

local floor, min, max, abs, sqrt = math.floor, math.min, math.max, math.abs, math.sqrt
local cos, sin, atan2, pi = math.cos, math.sin, math.atan2, math.pi

-- Rays: how near the first step is, how far the last, and how much further each step goes
local NEAREST, FARTHEST, STRIDE, STEP = 3, 2400, 1.045, 0.4
-- Above the horizon, a row every this many pixels
local ABOVE = 3
-- A ray has gone over a crest where the ground it sees next is this many times further than the
-- crest. A near hill hides what is beyond it from one ray of a band and not the other where that
-- ray sees this many times further than the other, past a crest about as far as the other sees
local OVER, JUMP, SAME = 1.08, 1.1, 1.6
-- A wedge mask's slope ends a row of its 64 above its bottom (make_course.py), and without masks
-- a band's outline is up to this many strips
local WEDGE, STRIPS = 64 / 63, 5
-- How much bigger than its share a hill's outline is drawn, so that nothing shows between it and
-- the cells beside it
local OVERLAP = 0.5
-- Things nearer than this aren't drawn, nor further than this, nor smaller than this many pixels
local THING_NEAREST, THING_FARTHEST, THING_SMALLEST = 4, 1200, 2
local MODELS = 24
-- Units of the map to a yard of the client's models, as a scene measures them
local YARD = 3

--- How many strips draw a line that rises or falls `rise` pixels across a band
local function stripsFor(rise)
  rise = abs(rise)
  return rise < 2 and 1 or rise < 8 and 3 or STRIPS
end

--- Sets a picture, sampled as asked if the client knows how. What SetTexture said of it
local function picture(texture, file, wrap, filter)
  if filter then
    local ok, result = pcall(texture.SetTexture, texture, file, wrap, wrap, filter)
    if ok then
      return result
    end
  end
  return texture:SetTexture(file, wrap, wrap)
end

--- @param parent Frame
--- @param options TerrainViewOptions
--- @return TerrainView
function TerrainView.New(parent, options)
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetAllPoints()
  frame:SetClipsChildren(true)
  -- Models over everything drawn on the frame
  local stage = CreateFrame("Frame", nil, frame)
  stage:SetAllPoints()
  stage:SetFrameLevel(frame:GetFrameLevel() + 5)
  local self = setmetatable({
    frame = frame, stage = stage, options = options,
    width = options.width, height = options.height, horizon = options.horizon, focal = options.focal,
    bands = options.bands or 16, folder = options.folder, filter = options.filter,
    maxModels = options.models or MODELS,
    cells = {}, rays = {}, edges = {}, pieces = {}, jump = {}, order = {}, seen = {},
    split = { cast = 0, fill = 0, things = 0, frames = 0 }, loaded = {}, drawn = 0, scale = 1,
    holders = {}, flip = -1,
  }, TerrainView)
  -- How wide a scene sees: as wide as the view. And how far to one side the view sees, a unit ahead
  self.fov = 2 * atan2(self.width / 2, self.focal)
  self.spread = self.width / 2 / self.focal
  self.masked = options.masks ~= false and frame.CreateMaskTexture ~= nil
  self.sky = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
  self.under = frame:CreateTexture(nil, "BACKGROUND", nil, -6)
  self:Rows(options.rows or 120, options.above or 132, options.cameraHeight or 14)
  return self
end

--- Where the rows of ground begin and end below the horizon: each 1 pixel tall or as tall as
--- keeps how deep it sees the same as the others, `count` of them or as near as can be
local function below(count, plane, first)
  local function rowsFor(k)
    local o, n = first, 0
    while o < plane do
      o, n = o + max(1, o * k), n + 1
    end
    return n
  end
  local low, high = 0, 4
  for _ = 1, 50 do
    local middle = (low + high) / 2
    if rowsFor(middle) > count then
      low = middle
    else
      high = middle
    end
  end
  local offsets, o = { first }, first
  while o < plane do
    o = min(plane, o + max(1, o * high))
    offsets[#offsets + 1] = o
  end
  return offsets
end

--- Cuts the screen into rows again: `count` below the horizon, and every ABOVE pixels up to
--- `above` over it
--- @param count integer
--- @param above number
--- @param cameraHeight number
function TerrainView:Rows(count, above, cameraHeight)
  local edges, horizon = self.edges, self.horizon
  for index = #edges, 1, -1 do
    edges[index] = nil
  end
  self.top = horizon - above
  local offsets = below(min(self.height - horizon, count), self.height - horizon, cameraHeight * self.focal / FARTHEST)
  for y = self.top, horizon + offsets[1] - 0.5, ABOVE do
    edges[#edges + 1] = y
  end
  for _, offset in ipairs(offsets) do
    edges[#edges + 1] = horizon + offset
  end
  for k = 0, self.bands do
    self.rays[k] = self.rays[k] or { u = {}, v = {}, depth = {}, out = {}, crest = {}, reach = {}, skyline = {}, steps = 0 }
  end
  self.laid = false
end

--- Makes the cells for the rows and bands, and puts them in place for the frame's size
--- @param scale number Screen points to one of the sheet's pixels
function TerrainView:Layout(scale)
  self.scale = scale
  local frame, edges, bands, cells = self.frame, self.edges, self.bands, self.cells
  local width = self.width / bands
  -- Cells meet exactly, on the screen's pixels: the course's picture is see-through, and where
  -- two overlapped its shade would be laid on twice
  local pixel = 0
  local ok, _, high = pcall(GetPhysicalScreenSize)
  if ok and high and high > 0 then
    pixel = 768 / high / (frame:GetEffectiveScale() or 1)
  end
  local function snap(value)
    return pixel > 0 and floor(value / pixel + 0.5) * pixel or value
  end
  local index = 0
  for r = 1, #edges - 1 do
    for k = 1, bands do
      index = index + 1
      local cell = cells[index]
      if not cell then
        cell = { ground = frame:CreateTexture(nil, "BORDER", nil, 0), overlay = frame:CreateTexture(nil, "BORDER", nil, 1) }
        cell.overlay:SetAllPoints(cell.ground)
        cells[index] = cell
      end
      local ground = cell.ground
      local left, top = snap((k - 1) * width * scale), snap(edges[r] * scale)
      ground:ClearAllPoints()
      ground:SetPoint("TOPLEFT", frame, "TOPLEFT", left, -top)
      ground:SetSize(max(pixel, snap(k * width * scale) - left), max(pixel, snap(edges[r + 1] * scale) - top))
      ground:Hide()
      cell.overlay:Hide()
      cell.outside = nil
    end
  end
  for unused = index + 1, #cells do
    cells[unused].ground:Hide()
    cells[unused].overlay:Hide()
    cells[unused].outside = nil
  end
  self.cellCount = index

  for _, holder in ipairs(self.holders) do
    self:placeScene(holder.scene)
  end
  self.sky:ClearAllPoints()
  self.sky:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  self.sky:SetSize(self.width * scale, self.horizon * scale + 1)
  self.under:ClearAllPoints()
  self.under:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -self.horizon * scale)
  self.under:SetSize(self.width * scale, (self.height - self.horizon) * scale)
  self.laid = true
end

--- Shows a course: its pictures, the client's ground under them, its sky and haze
--- @param course Course
--- @return { tile: any, overlay: any } What SetTexture said of the client's ground and the course's picture
function TerrainView:SetCourse(course)
  self.course = course
  local folder, pictures, filter = self.folder, course.pictures, self.filter
  local client = self.options.ground ~= "own" and course.tile ~= nil
  local loaded = { tile = false, overlay = false }
  -- The client's ground, if it is there: tried on a texture of its own first
  if client then
    loaded.tile = picture(self.under, course.tile.file, "REPEAT", filter)
    client = loaded.tile ~= false
  end
  self.client = client
  self.tileFile = client and course.tile.file or folder .. pictures.tile
  self.overlayFile = folder .. (client and pictures.overlay or pictures.full)
  self.repeats = course.world / (course.tile and course.tile.units or 40)
  self.light = course.light
  self.rises, self.falls = folder .. "wedgerise", folder .. "wedgefall"
  -- Whether the course's picture is there, tried on the sky, which takes its own after
  loaded.overlay = picture(self.sky, self.overlayFile, "CLAMP", filter)
  if picture(self.sky, folder .. pictures.sky, "REPEAT") == false then
    self.sky:SetColorTexture(0.35, 0.55, 0.85)
  end
  local haze = course.haze
  self.under:SetColorTexture(haze[1], haze[2], haze[3])
  self.sky:Show()
  self.under:Show()
  self.loaded = loaded
  -- Every cell and piece takes these pictures when it is next drawn
  self.dressing = {}
  self.things = {}
  for index, thing in ipairs(course.things) do
    self.things[index] = { x = thing.x, y = thing.y, z = course:Height(thing.x, thing.y), size = thing.size,
      heading = thing.facing, model = thing.model }
  end
  return loaded
end

--------------------------------------------------------------------------------
-- The ground

--- Casts every ray, from the camera at (camX, camY, camZ) looking along (fx, fy). The ground's
--- height is looked up here rather than through Course:Height, which is most of the time it takes
function TerrainView:cast(camX, camY, camZ, fx, fy)
  local course, edges, rays = self.course, self.edges, self.rays
  local width, horizon, focal, bands = self.width, self.horizon, self.focal, self.bands
  local count, world = #edges, course.world
  local rx, ry = -fy, fx
  local size, cell, heights = course.size, course.cell, course.heights
  local last = size - 1
  for k = 0, bands do
    local ray = rays[k]
    local spread = (k * width / bands - width / 2) / focal
    local dx, dy = fx + rx * spread, fy + ry * spread
    ray.dx, ray.dy = dx, dy
    local u, v, depth, out, crest = ray.u, ray.v, ray.depth, ray.out, ray.crest
    local reach, skyline = ray.reach, ray.skyline
    -- Rows are seen from the bottom of the screen up
    local edge, edgeY = count, edges[count]
    local lowest = self.height + 1
    local lastY, lastZ = self.height * 50, NEAREST
    local z, steps = NEAREST, 0
    -- How far the last ground seen was, and the last crest gone over
    local seenZ, over = nil, 0
    while z < FARTHEST and edge >= 1 do
      local x, y = camX + dx * z, camY + dy * z
      local gx, gy = x / cell, y / cell
      local ground
      if gx >= 0 and gy >= 0 and gx < last and gy < last then
        local i, j = gx - gx % 1, gy - gy % 1
        local fx2, fy2 = gx - i, gy - j
        local at = j * size + i + 1
        local h00, h10 = heights[at], heights[at + 1]
        local top = h00 + (h10 - h00) * fx2
        local h01 = heights[at + size]
        ground = top + (h01 + (heights[at + size + 1] - h01) * fx2 - top) * fy2
      else
        ground = course:Height(x, y)
      end
      local screenY = horizon + (camZ - ground) * focal / z
      if screenY < lowest then
        if seenZ and z > seenZ * OVER and lastY >= lowest then
          over = seenZ
        end
        seenZ = z
        while edge >= 1 and edgeY >= screenY do
          if edgeY < lowest then
            local at = lastZ + (z - lastZ) * (lastY - edgeY) / (lastY - screenY)
            local seenU, seenV = (camX + dx * at) / world, (camY + dy * at) / world
            u[edge], v[edge], depth[edge], crest[edge] = seenU, seenV, at, over
            out[edge] = seenU < 0 or seenU > 1 or seenV < 0 or seenV > 1
          end
          edge = edge - 1
          edgeY = edges[edge]
        end
        lowest = screenY
      end
      steps = steps + 1
      reach[steps], skyline[steps] = z, lowest
      lastY, lastZ = screenY, z
      z = z * STRIDE + STEP
    end
    for above = 1, edge do
      depth[above] = false
    end
    ray.steps, ray.top, ray.highest = steps, edge + 1, lowest
  end
end

--- Shows a cell or piece of the ground the spots its corners are on the map's picture: the
--- course's picture over the client's ground on the map, or the course's own picture alone, and
--- beyond the map the repeated ground lit as flat ground is
function TerrainView:paint(item, outside, ulx, uly, llx, lly, urx, ury, lrx, lry)
  local ground, overlay = item.ground, item.overlay
  if item.dressed ~= self.dressing then
    picture(ground, self.tileFile, "REPEAT", self.filter)
    picture(overlay, self.overlayFile, "CLAMP", self.filter)
    item.dressed, item.outside = self.dressing, nil
  end
  if outside ~= item.outside then
    item.outside = outside
    if outside then
      local light = self.light
      ground:SetVertexColor(light, light, light)
      ground:Show()
      overlay:Hide()
    else
      if self.client then
        ground:SetVertexColor(1, 1, 1)
        ground:Show()
      else
        ground:Hide()
      end
      overlay:Show()
    end
  end
  if outside or self.client then
    local r = self.repeats
    ground:SetTexCoord(ulx * r, uly * r, llx * r, lly * r, urx * r, ury * r, lrx * r, lry * r)
  end
  if not outside then
    overlay:SetTexCoord(ulx, uly, llx, lly, urx, ury, lrx, lry)
  end
end

local function hideItem(item)
  if item.outside ~= nil then
    item.ground:Hide()
    item.overlay:Hide()
    item.outside = nil
  end
end

--- Puts piece number `number`, `left` across and `width` wide, down to `bottom`, cut off above a
--- line from `leftTop` at its left to `rightTop` at its right if it can be, else flat at the higher,
--- showing the ground with its top left corner at (ulx, uly) on the map's picture and so on
function TerrainView:placePiece(number, left, width, leftTop, rightTop, bottom, ulx, uly, llx, lly, urx, ury, lrx, lry)
  local frame, pieces = self.frame, self.pieces
  local piece = pieces[number]
  if not piece then
    -- Over the cells, under the things
    piece = { ground = frame:CreateTexture(nil, "ARTWORK", nil, -8), overlay = frame:CreateTexture(nil, "ARTWORK", nil, -7) }
    piece.overlay:SetAllPoints(piece.ground)
    pieces[number] = piece
  end
  local top = min(leftTop, rightTop)
  if top >= bottom - 0.25 then
    hideItem(piece)
    return
  end
  local outside = ulx < 0 or ulx > 1 or uly < 0 or uly > 1 or urx < 0 or urx > 1 or ury < 0 or ury > 1
    or llx < 0 or llx > 1 or lly < 0 or lly > 1 or lrx < 0 or lrx > 1 or lry < 0 or lry > 1
  self:paint(piece, outside, ulx, uly, llx, lly, urx, ury, lrx, lry)
  local scale = self.scale
  local ground = piece.ground
  ground:ClearAllPoints()
  ground:SetPoint("TOPLEFT", frame, "TOPLEFT", left * scale, -top * scale)
  ground:SetSize(width * scale + OVERLAP, (bottom - top) * scale + OVERLAP)
  if self.masked then
    local mask = piece.mask
    if not mask then
      mask = frame:CreateMaskTexture()
      piece.ground:AddMaskTexture(mask)
      piece.overlay:AddMaskTexture(mask)
      piece.mask = mask
    end
    local file = rightTop < leftTop and self.rises or self.falls
    if piece.maskFile ~= file then
      -- Clamped, so that below the wedge the mask goes on all seen
      mask:SetTexture(file, "CLAMP", "CLAMP")
      piece.maskFile = file
    end
    mask:ClearAllPoints()
    mask:SetPoint("TOPLEFT", frame, "TOPLEFT", left * scale, -top * scale)
    mask:SetSize(width * scale + OVERLAP, max(0.5, abs(rightTop - leftTop) * WEDGE) * scale)
  end
end

--- Where (s, d) is on a piece with those corners, s across it and d down it, both 0 to 1
local function within(s, d, ulx, uly, llx, lly, urx, ury, lrx, lry)
  local topX, topY = ulx + (urx - ulx) * s, uly + (ury - uly) * s
  return topX + (llx + (lrx - llx) * s - topX) * d, topY + (lly + (lry - lly) * s - topY) * d
end

--- Draws a hill's outline over a band: one piece cut off along the line if the client can, else
--- strips each up to the line at its middle. Returns the number of the last piece used, `number`
--- the one before the first.
---
--- The top corner on the lower side is cut off, so it is left out (nil) and made what keeps the
--- picture across the piece flat, as the three corners seen have it: the client draws the piece
--- as two triangles, and a fourth corner of its own would bend what the other three show
function TerrainView:outline(number, left, width, leftTop, rightTop, bottom, ulx, uly, llx, lly, urx, ury, lrx, lry)
  if not ulx then
    ulx, uly = urx + llx - lrx, ury + lly - lry
  elseif not urx then
    urx, ury = ulx + lrx - llx, uly + lry - lly
  end
  if self.masked then
    self:placePiece(number + 1, left, width, leftTop, rightTop, bottom, ulx, uly, llx, lly, urx, ury, lrx, lry)
    return number + 1
  end
  local parts = stripsFor(rightTop - leftTop)
  local top = min(leftTop, rightTop)
  local tall = bottom - top
  for part = 0, parts - 1 do
    local from, to = part / parts, (part + 1) / parts
    local stripTop = leftTop + (rightTop - leftTop) * (from + to) / 2
    local down = tall > 0 and (stripTop - top) / tall or 0
    local sulx, suly = within(from, down, ulx, uly, llx, lly, urx, ury, lrx, lry)
    local sllx, slly = within(from, 1, ulx, uly, llx, lly, urx, ury, lrx, lry)
    local surx, sury = within(to, down, ulx, uly, llx, lly, urx, ury, lrx, lry)
    local slrx, slry = within(to, 1, ulx, uly, llx, lly, urx, ury, lrx, lry)
    self:placePiece(number + part + 1, left + width * from, width / parts, stripTop, stripTop, bottom,
      sulx, suly, sllx, slly, surx, sury, slrx, slry)
  end
  return number + parts
end

--- Shows each cell of the grid what its corners see, from the camera at (camX, camY). A cell is
--- drawn where all four of its corners see ground. Then the hills' outlines
function TerrainView:fill(camX, camY)
  local bands, edges, rays, cells, jump = self.bands, self.edges, self.rays, self.cells, self.jump
  local rowCount = #edges - 1
  local across = self.width / bands
  local world = self.course.world
  local dressing, client, r = self.dressing, self.client, self.repeats
  local piece = 0
  for k = 1, bands do
    local left, right = rays[k - 1], rays[k]
    local lu, lv, ru, rv, lo, ro = left.u, left.v, right.u, right.v, left.out, right.out
    local ld, rd, lc, rc = left.depth, right.depth, left.crest, right.crest
    local ldx, ldy, rdx, rdy = left.dx, left.dy, right.dx, right.dy
    local first = max(left.top, right.top)
    for e = first, rowCount + 1 do
      local a, b = ld[e], rd[e]
      local hides = rc[e]
      if a * JUMP < b and hides * SAME > a and hides < a * SAME then
        jump[e] = -1
      else
        hides = lc[e]
        jump[e] = b * JUMP < a and hides * SAME > b and hides < b * SAME and 1 or 0
      end
    end
    local index = k
    for r = 1, rowCount do
      local cell = cells[index]
      if r >= first then
        local below = r + 1
        local ulx, uly, urx, ury = lu[r], lv[r], ru[r], rv[r]
        local llx, lly, lrx, lry = lu[below], lv[below], ru[below], rv[below]
        local top, bottom = jump[r], jump[below]
        local outside = lo[r] or lo[below] or ro[r] or ro[below]
        -- Where a near hill hides the rest from one side, that side looks as far along its own
        -- ray as the other sees
        if top == -1 then
          local far = rd[r]
          ulx, uly = (camX + ldx * far) / world, (camY + ldy * far) / world
        elseif top == 1 then
          local far = ld[r]
          urx, ury = (camX + rdx * far) / world, (camY + rdy * far) / world
        end
        if bottom == -1 then
          local far = rd[below]
          llx, lly = (camX + ldx * far) / world, (camY + ldy * far) / world
        elseif bottom == 1 then
          local far = ld[below]
          lrx, lry = (camX + rdx * far) / world, (camY + rdy * far) / world
        end
        if top ~= 0 or bottom ~= 0 then
          outside = ulx < 0 or ulx > 1 or uly < 0 or uly > 1 or urx < 0 or urx > 1 or ury < 0 or ury > 1
            or llx < 0 or llx > 1 or lly < 0 or lly > 1 or lrx < 0 or lrx > 1 or lry < 0 or lry > 1
        end
        -- As it was the frame before, only showing another part of its pictures, most often
        if cell.dressed == dressing and cell.outside == outside then
          if outside or client then
            cell.ground:SetTexCoord(ulx * r, uly * r, llx * r, lly * r, urx * r, ury * r, lrx * r, lry * r)
          end
          if not outside then
            cell.overlay:SetTexCoord(ulx, uly, llx, lly, urx, ury, lrx, lry)
          end
        else
          self:paint(cell, outside, ulx, uly, llx, lly, urx, ury, lrx, lry)
        end
      else
        hideItem(cell)
      end
      index = index + bands
    end

    -- Against the sky, where at least one side sees ground above the first cell drawn: from the
    -- top of what the higher side sees down to that cell
    if first <= rowCount + 1 then
      local bottom = edges[first]
      local leftSees, rightSees = left.top <= rowCount, right.top <= rowCount
      local leftTop = leftSees and left.highest or bottom
      local rightTop = rightSees and right.highest or bottom
      if leftTop < bottom or rightTop < bottom then
        if leftTop <= rightTop then
          local high = left.top
          piece = self:outline(piece, (k - 1) * across, across, leftTop, rightTop, bottom,
            lu[high], lv[high], lu[first], lv[first], nil, nil, ru[first], rv[first])
        else
          local high = right.top
          piece = self:outline(piece, (k - 1) * across, across, leftTop, rightTop, bottom,
            nil, nil, lu[first], lv[first], ru[high], rv[high], ru[first], rv[first])
        end
      end
    end

    -- A near hill over what is beyond it: each run of edges where one side sees the hill and the
    -- other beyond. The near side's ray crests at the top of the run, the far side's at its
    -- bottom, where both see the hill
    local e = first
    while e <= rowCount do
      local side = jump[e]
      if side ~= 0 then
        local from = e
        while e < rowCount and jump[e + 1] == side do
          e = e + 1
        end
        local crestNear, crestFar = edges[from], edges[e + 1]
        local crest = e + 1
        if side == -1 then
          piece = self:outline(piece, (k - 1) * across, across, crestNear, crestFar, crestFar,
            lu[from], lv[from], lu[crest], lv[crest], nil, nil, ru[crest], rv[crest])
        else
          piece = self:outline(piece, (k - 1) * across, across, crestFar, crestNear, crestFar,
            nil, nil, lu[crest], lv[crest], ru[from], rv[from], ru[crest], rv[crest])
        end
      end
      e = e + 1
    end
  end
  local pieces = self.pieces
  for unused = piece + 1, #pieces do
    hideItem(pieces[unused])
  end
  self.pieceCount = piece
end

--- Where one ray says the ground nearer than `depth` reaches up to on the screen
local function skylineOf(ray, depth, height)
  local reach, low, high = ray.reach, 1, ray.steps
  if high < 1 or reach[1] >= depth then
    return height
  end
  while low < high do
    local middle = floor((low + high + 1) / 2)
    if reach[middle] < depth then
      low = middle
    else
      high = middle - 1
    end
  end
  return ray.skyline[low]
end

--- Where the ground nearer than `depth` reaches up to on the screen at a spot across it: between
--- what the rays either side of it say, as the hills' outlines are drawn
--- @param screenX number
--- @param depth number
--- @return number
function TerrainView:SkylineAt(screenX, depth)
  local bands, height = self.bands, self.height
  local at = min(bands, max(0, screenX / (self.width / bands)))
  local k = min(bands - 1, floor(at))
  local before = skylineOf(self.rays[k], depth, height)
  local after = skylineOf(self.rays[k + 1], depth, height)
  return before + (after - before) * (at - k)
end

--------------------------------------------------------------------------------
-- Things on the ground
--
-- A creature or a unit (a racer's mount, your character) is a PlayerModel, which frames the
-- creature to fill it, as big as the thing is drawn. A model's file (a cactus, a water tower) is
-- an actor in a ModelScene, a scene with a camera of its own: put where the view's camera is,
-- looking the same way and as wide, it draws the model as big as it really is, where it really
-- is. A scene is square and as wide as the view, with the horizon across its middle, so that how
-- wide it sees is the same whichever way the client measures it. Each thing has its own frame
-- round it that cuts it off, at the bottom where a crest nearer than it hides it.

--- Shows a creature, a unit or a model's file in a PlayerModel
local function showModel(holder)
  local model, thing = holder.model, holder.thing
  if thing.unit then
    model:SetUnit(thing.unit)
  elseif thing.display then
    model:SetDisplayInfo(thing.display)
  end
  if thing.animation then
    pcall(model.SetAnimation, model, thing.animation)
  end
end

--- The PlayerModel a creature or unit is drawn with, in a frame that cuts it off
function TerrainView:modelOf(thing)
  local holder = thing.holder
  if not holder then
    local clip = CreateFrame("Frame", nil, self.stage)
    clip:SetClipsChildren(true)
    local model = CreateFrame("PlayerModel", nil, clip)
    holder = { clip = clip, model = model, thing = thing }
    model:SetScript("OnShow", function()
      showModel(holder)
    end)
    pcall(model.SetScript, model, "OnModelLoaded", function()
      if thing.animation then
        pcall(model.SetAnimation, model, thing.animation)
      end
    end)
    thing.holder = holder
    clip:Hide()
  end
  return holder
end

--- Puts a scene where every scene goes: square, as wide as the view, the horizon across its middle
function TerrainView:placeScene(scene)
  local scale = self.scale
  scene:ClearAllPoints()
  scene:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, -(self.horizon - self.width / 2) * scale)
  scene:SetSize(self.width * scale, self.width * scale)
end

--- The scene a model's file is drawn in, or nil if the client has no scenes
function TerrainView:sceneOf(thing)
  local holder = thing.holder
  if holder or self.scenes == false then
    return holder
  end
  local clip = CreateFrame("Frame", nil, self.stage)
  clip:SetClipsChildren(true)
  local ok, scene = pcall(CreateFrame, "ModelScene", nil, clip)
  if not ok or not scene or not scene.CreateActor then
    self.scenes = false
    clip:Hide()
    return nil
  end
  self.scenes = true
  local actor = scene:CreateActor()
  actor:SetModelByFileID(thing.model)
  actor:SetPosition(0, 0, 0)
  pcall(scene.SetCameraFieldOfView, scene, self.fov)
  pcall(scene.SetCameraNearClip, scene, 0.1)
  pcall(scene.SetCameraFarClip, scene, FARTHEST / YARD)
  self:placeScene(scene)
  holder = { clip = clip, scene = scene, actor = actor, thing = thing }
  thing.holder = holder
  self.holders[#self.holders + 1] = holder
  clip:Hide()
  return holder
end

--- Points the camera of a scene the way the view's looks, from where it is, as the thing in the
--- scene sees it: the thing stands in the middle of its scene, unturned, and the camera is put
--- where it is from the thing, turned as far the other way as the thing faces. That turns the
--- thing without turning its actor, which the client may not do
function TerrainView:aim(scene, camX, camY, camZ, heading, thing)
  local flip = self.flip
  if not thing then
    scene:SetCameraPosition(camX / YARD, flip * camY / YARD, camZ / YARD)
    self:turn(scene, flip * heading)
    return
  end
  local facing = thing.heading or 0
  local fx, fy = cos(facing), sin(facing)
  local dx, dy = camX - thing.x, camY - thing.y
  -- Ahead of the thing, and to its left: (fy, -fx) with y down
  local ahead, left = dx * fx + dy * fy, dx * fy - dy * fx
  scene:SetCameraPosition(ahead / YARD, -flip * left / YARD, (camZ - thing.z2) / YARD)
  self:turn(scene, flip * (heading - facing))
end

--- Turns a scene's camera to look level, `yaw` round from its x axis towards its y: by the
--- directions it looks, to its right and up, where the client takes them
function TerrainView:turn(scene, yaw)
  local x, y = cos(yaw), sin(yaw)
  if scene.SetCameraOrientationByAxisVectors then
    scene:SetCameraOrientationByAxisVectors(x, y, 0, y, -x, 0, 0, 0, 1)
  else
    scene:SetCameraOrientationByYawPitchRoll(yaw, 0, 0)
  end
end

--- The first time a scene is drawn: where it puts a spot straight ahead and one to the right of
--- it, to tell whether it sees the map the right way round and as wide as the view. If it has
--- them mirrored, it is turned round; if not as wide, as wide. What it found is kept in
--- `calibration`, to be told
function TerrainView:calibrate(scene, camX, camY, camZ, heading)
  self.calibrated = true
  -- Whether turning the camera and an actor takes: what they say they face after being turned
  local turned = {}
  local function forward()
    local ok, x, y = pcall(scene.GetCameraForward, scene)
    if ok and type(x) == "table" then
      x, y = x.x, x.y
    end
    return ok and x and ("%.2f, %.2f"):format(x, y or 0) or "?"
  end
  pcall(scene.SetCameraOrientationByYawPitchRoll, scene, 1, 0, 0)
  turned[#turned + 1] = "yaw 1 looks " .. forward()
  if scene.SetCameraOrientationByAxisVectors then
    pcall(scene.SetCameraOrientationByAxisVectors, scene, 0, 1, 0, 1, 0, 0, 0, 0, 1)
    turned[#turned + 1] = "axes (0, 1) look " .. forward()
  else
    turned[#turned + 1] = "no axes"
  end
  local holder = self.holders[1]
  if holder then
    local actor = holder.actor
    pcall(actor.SetYaw, actor, 0.7)
    local ok, yaw = pcall(actor.GetYaw, actor)
    turned[#turned + 1] = "actor yaw 0.7 reads " .. tostring(ok and yaw)
    pcall(actor.SetYaw, actor, 0)
  end
  self.turned = table.concat(turned, ", ")
  if not scene.Project3DPointTo2D then
    self.calibration = "scenes can't project a point; " .. self.turned
    return
  end
  local fx, fy = cos(heading), sin(heading)
  local ahead = 30 * YARD
  local function project(side)
    local x, y = camX + fx * ahead - fy * side * ahead, camY + fy * ahead + fx * side * ahead
    local ok, sx, sy = pcall(scene.Project3DPointTo2D, scene, x / YARD, self.flip * y / YARD, camZ / YARD)
    return ok and sx, sy
  end
  self:aim(scene, camX, camY, camZ, heading)
  local x1, y1 = project(0)
  local x2 = project(0.5)
  if not (x1 and x2) then
    self.calibration = "scenes projected nothing; " .. self.turned
    return
  end
  local mirrored = x2 < x1
  if mirrored then
    self.flip = -self.flip
  end
  -- Half a unit to the right a unit ahead is half the focal length to the right on the sheet.
  -- The scene may answer in its own points or in the screen's pixels
  local width = scene:GetWidth()
  local expected = 0.5 * self.focal / self.width
  local measured = math.abs(x2 - x1) / width
  local pixels = measured / (scene:GetEffectiveScale() or 1)
  local ratio = math.abs(pixels / expected - 1) < math.abs(measured / expected - 1) and pixels / expected or measured / expected
  local note = ""
  if ratio > 0.4 and ratio < 2.5 and math.abs(ratio - 1) > 0.03 then
    self.fov = 2 * math.atan(math.tan(self.fov / 2) * ratio)
    for _, holder in ipairs(self.holders) do
      pcall(holder.scene.SetCameraFieldOfView, holder.scene, self.fov)
    end
    note = (", widened to %.1f degrees"):format(math.deg(self.fov))
  end
  self.calibration = ("scenes: %s, %.2f as wide as the view%s; straight ahead at %.0f, %.0f of %.0f wide; %s"):format(
    mirrored and "mirrored, turned round" or "the right way round", ratio, note, x1, y1 or -1, width, self.turned)
end

--- Whatever showed a thing, hidden
local function hideThing(thing)
  if thing.holder then
    thing.holder.clip:Hide()
  elseif thing.texture then
    thing.texture:Hide()
  end
end

--- Hides a model or picture a game won't draw again, a kart that has gone, say
--- @param thing TerrainThing
function TerrainView:Forget(thing)
  hideThing(thing)
end

--- How big a model's file is, in yards from where it stands: what its actor says once it has
--- loaded, else a box twice as wide and three times as high as its size, to be sure of it
local function boundsOf(thing)
  local bounds = thing.bounds
  if bounds then
    return bounds
  end
  local holder = thing.holder
  if holder and holder.actor and holder.actor.GetActiveBoundingBox then
    local ok, x1, y1, z1, x2, y2, z2 = pcall(holder.actor.GetActiveBoundingBox, holder.actor)
    if ok and x1 and x2 and x2 > x1 and z2 > z1 then
      bounds = { x1, y1, z1, x2, y2, z2 }
      thing.bounds = bounds
      return bounds
    end
  end
  local half = thing.size / YARD
  return { -half, -half, 0, half, half, half * 1.5 }
end

--- Where a model's file is on the sheet: the box round where its corners are, or nil if it is
--- all behind the camera
function TerrainView:boxOf(thing, z, camX, camY, camZ, fx, fy)
  local bounds = boundsOf(thing)
  local facing = thing.heading or 0
  local dx, dy = cos(facing), sin(facing)
  -- To the left of the way it faces, as the model has it, with y down
  local lx, ly = dy, -dx
  local focal, width, horizon = self.focal, self.width, self.horizon
  local left, top, right, bottom = math.huge, math.huge, -math.huge, -math.huge
  local ahead = false
  for corner = 0, 7 do
    local mx = (corner % 2 == 0 and bounds[1] or bounds[4]) * YARD
    local my = (floor(corner / 2) % 2 == 0 and bounds[2] or bounds[5]) * YARD
    local mz = (corner < 4 and bounds[3] or bounds[6]) * YARD
    local px, py = thing.x + dx * mx + lx * my - camX, thing.y + dy * mx + ly * my - camY
    local depth = px * fx + py * fy
    if depth > 0 then
      ahead = true
    end
    -- A corner behind the camera counts as if it were a unit ahead of it, which puts it as far
    -- out to its side as it can be
    depth = max(1, depth)
    local sx = width / 2 + (px * -fy + py * fx) * focal / depth
    local sy = horizon + (camZ - z - mz) * focal / depth
    left, right, top, bottom = min(left, sx), max(right, sx), min(top, sy), max(bottom, sy)
  end
  if not ahead then
    return nil
  end
  return max(left, -width), max(top, -self.height), min(right, 2 * width), min(bottom, 2 * self.height)
end

local function nearer(one, other)
  return one.depth < other.depth
end

local function further(one, other)
  return one.depth > other.depth
end

--- Draws the things: where each is on the screen, the nearer over the further, cut off by crests.
--- Of the models, only the nearest so many
function TerrainView:drawThings(camX, camY, camZ, heading, list, more)
  local fx, fy = cos(heading), sin(heading)
  local rx, ry = -fy, fx
  local focal, width, height, horizon, scale = self.focal, self.width, self.height, self.horizon, self.scale
  local order, seen, course = self.order, 0, self.course
  for pass = 1, 2 do
    local things = pass == 1 and more or list
    for _, thing in ipairs(things or {}) do
      local dx, dy = thing.x - camX, thing.y - camY
      local depth = dx * fx + dy * fy
      local shown = false
      local file = thing.model and not thing.display and not thing.unit
      if depth > -thing.size and depth < THING_FARTHEST and not (file and self.scenes == false) then
        local z = thing.z or course:Height(thing.x, thing.y)
        local left, top, right, bottom
        local reach = thing.size * 1.5
        if file and abs(dx * rx + dy * ry) - reach > (depth + reach) * self.spread then
          -- Well off to one side of what the camera sees
          left = nil
        elseif file then
          left, top, right, bottom = self:boxOf(thing, z, camX, camY, camZ, fx, fy)
        elseif depth > THING_NEAREST then
          local size = thing.size * focal / depth
          local x = width / 2 + (dx * rx + dy * ry) * focal / depth
          bottom = horizon + (camZ - z) * focal / depth
          left, top, right = x - size / 2, bottom - size, x + size / 2
        end
        if left and right - left >= THING_SMALLEST and right > 0 and left < width and top < height then
          local hidden = self:SkylineAt(min(width, max(0, (left + right) / 2)), max(THING_NEAREST, depth))
          if top < hidden then
            thing.depth, thing.left, thing.top, thing.right, thing.bottom = depth, left, top, right, bottom
            thing.cut, thing.hidden, thing.z2 = min(bottom, hidden), hidden, z
            thing.seenFrom = heading + atan2(dx * rx + dy * ry, max(depth, 0.01))
            seen = seen + 1
            order[seen] = thing
            shown = true
          end
        end
      end
      if not shown then
        hideThing(thing)
      end
    end
  end
  for index = seen + 1, #order do
    order[index] = nil
  end
  -- The nearest models only, the others hidden
  table.sort(order, nearer)
  local models, kept = 0, 0
  for index = 1, seen do
    local thing = order[index]
    if thing.model or thing.display or thing.unit then
      models = models + 1
      if models > self.maxModels then
        hideThing(thing)
        thing = nil
      end
    end
    if thing then
      kept = kept + 1
      order[kept] = thing
    end
  end
  for index = kept + 1, seen do
    order[index] = nil
  end
  seen = kept
  table.sort(order, further)
  local frame, stage = self.frame, self.stage
  local level = stage:GetFrameLevel()
  for rank, thing in ipairs(order) do
    local left, top, right = thing.left * scale, thing.top * scale, thing.right * scale
    local cut = thing.cut * scale
    if thing.model and not thing.display and not thing.unit then
      local holder = self:sceneOf(thing)
      if holder then
        -- Cut off only at the bottom, where a nearer crest hides it: how far it reaches to its
        -- sides and up is the scene's to draw
        local clip, scene, actor = holder.clip, holder.scene, holder.actor
        clip:SetFrameLevel(level + rank)
        clip:ClearAllPoints()
        clip:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        clip:SetSize(width * scale, max(0.01, min(thing.hidden, height) * scale))
        if not self.calibrated then
          self:calibrate(scene, camX, camY, camZ, heading)
        end
        self:aim(scene, camX, camY, camZ, heading, thing)
        clip:Show()
      end
    elseif thing.display or thing.unit then
      local holder = self:modelOf(thing)
      local clip, model = holder.clip, holder.model
      local size = right - left
      clip:SetFrameLevel(level + rank)
      clip:ClearAllPoints()
      clip:SetPoint("TOPLEFT", frame, "TOPLEFT", left, -top)
      clip:SetSize(size, max(0.01, cut - top))
      model:ClearAllPoints()
      model:SetPoint("TOPLEFT", clip, "TOPLEFT")
      model:SetSize(size, size)
      model:SetFacing(pi - ((thing.heading or 0) - thing.seenFrom))
      model:SetAlpha(thing.alpha or 1)
      clip:Show()
    else
      local texture = thing.texture
      if not texture then
        texture = frame:CreateTexture(nil, "ARTWORK")
        texture:SetTexture(thing.sprite)
        thing.texture = texture
      end
      local colour = thing.colour
      if colour then
        texture:SetVertexColor(colour[1], colour[2], colour[3])
      end
      texture:SetAlpha(thing.alpha or 1)
      local size = right - left
      local shown = (cut - top) / size
      texture:SetDrawLayer("ARTWORK", min(7, -6 + rank))
      texture:ClearAllPoints()
      texture:SetPoint("TOPLEFT", frame, "TOPLEFT", left, -top)
      texture:SetSize(size, max(0.01, cut - top))
      texture:SetTexCoord(0, 1, 0, shown)
      texture:Show()
    end
  end
  self.drawn = seen
  return seen
end

--------------------------------------------------------------------------------

--- Draws the view from a camera, with the course's own things and `things` on the ground too.
--- Returns how many things were drawn
--- @param camera TerrainCamera
--- @param things TerrainThing[]?
--- @return integer
function TerrainView:Draw(camera, things)
  local camX, camY, camZ, heading = camera.x, camera.y, camera.z, camera.heading
  local fx, fy = cos(heading), sin(heading)
  local u = heading / (pi / 2)
  self.sky:SetTexCoord(u, u + (2 * atan2(self.width / 2, self.focal)) / (pi / 2), 0, 1)
  local began = debugprofilestop()
  self:cast(camX, camY, camZ, fx, fy)
  local cast = debugprofilestop()
  self:fill(camX, camY)
  local filled = debugprofilestop()
  local drawn = self:drawThings(camX, camY, camZ, heading, self.things, things)
  local split = self.split
  split.cast, split.fill, split.things = split.cast + cast - began, split.fill + filled - cast, split.things + debugprofilestop() - filled
  split.frames = split.frames + 1
  return drawn
end

--- How high the camera can be at a spot without being inside a hill
--- @param x number
--- @param y number
--- @return number
function TerrainView:GroundAt(x, y)
  return self.course:Height(x, y)
end

--- Hides everything the view draws
function TerrainView:Hide()
  for _, cell in ipairs(self.cells) do
    hideItem(cell)
  end
  for _, piece in ipairs(self.pieces) do
    hideItem(piece)
  end
  for _, thing in ipairs(self.order) do
    hideThing(thing)
  end
  for _, thing in ipairs(self.things or {}) do
    hideThing(thing)
  end
  self.sky:Hide()
  self.under:Hide()
end
