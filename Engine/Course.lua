--------------------------
--  Course
--------------------------
-- A course to race round: ground with hills in it, a road round it, and things standing on it,
-- for a racing game to drive on and GUI/TerrainView.lua to draw.
--
-- The ground is a grid of heights `cell` units apart, `size` of them across and down, over a
-- square map `world` units across. Between them the ground is as high as the four round it make
-- it, each counting as much as it is near. Beyond the map the ground goes on rising, `rise` units
-- for every unit further out, to `highest` above the edge at most, so that nothing can be seen
-- past the edge of the world, only hills.
--
-- The road is a line of points `spacing` units apart round a closed loop, the middle of the road,
-- made by Tools/make_course.py. Point 1 is on the start line and the road is driven towards the
-- points after it. How far round from the start a spot of the road is, its progress, and how far
-- to the right of the middle, its offset, say where on the road anything is.
--
-- Map coordinates have x across to the right and y down, as the map's picture has them, and a
-- heading is the angle atan2(dy, dx) of the way something goes.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class CourseThing
--- @field model integer|string The client's model, by file id or path
--- @field x number
--- @field y number
--- @field size number How big it is drawn: the side of the square it fits in, in units
--- @field facing number The heading its front faces

--- @class CourseData
--- @field name string
--- @field world number Units across the map
--- @field size integer Heights across and down
--- @field cell number Units between two heights
--- @field heights number[] Row by row from y = 0
--- @field rise number Beyond the map the ground rises this many units a unit further out
--- @field highest number To this high above the edge at most
--- @field light number How light flat ground is under the sun the pictures have baked in
--- @field spacing number Units between two points of the road
--- @field track number[] The road's middle, x and y of each point in turn
--- @field half number Half the road's width, and the curbs beside it, and the shoulder beyond them
--- @field curb number
--- @field shoulder number
--- @field tile { file: integer|string, units: number }? The client's ground the course's picture goes over, and how many units one of it covers
--- @field pictures { overlay: string, full: string, tile: string, sky: string } The course's own pictures, by name
--- @field haze number[] The colour of the far ground and the bottom of the sky
--- @field things CourseThing[]

--- @class Course : CourseData
--- @field id string
--- @field count integer How many points the road has
--- @field length number How far round it is
local Course = {}
Course.__index = Course
private.Course = Course

local floor, min, max, sqrt, atan2 = math.floor, math.min, math.max, math.sqrt, math.atan2

-- How far a spot may be from the road found by looking near where something was before, before
-- the whole road is looked through
local NEAR, LOOK = 60, 8

local registry = {}

--- Adds a course that can be loaded by its id
--- @param id string
--- @param data CourseData
function Course.Register(id, data)
  registry[id] = data
end

--- @param id string
--- @return boolean
function Course.Has(id)
  return registry[id] ~= nil
end

--- The ids of the courses there are, in order
--- @return string[]
function Course.Ids()
  local ids = {}
  for id in pairs(registry) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  return ids
end

--- A course to drive on, made from what was registered by `id`
--- @param id string
--- @return Course?
function Course.Load(id)
  local data = registry[id]
  if not data then
    return nil
  end
  local course = setmetatable({ id = id }, Course)
  for key, value in pairs(data) do
    course[key] = value
  end
  course.count = #data.track / 2
  course.length = course.count * data.spacing
  return course
end

--- How high the ground is at (x, y), on the map or beyond it
--- @param x number
--- @param y number
--- @return number
function Course:Height(x, y)
  local size, cell, heights = self.size, self.cell, self.heights
  local gx, gy = x / cell, y / cell
  local outside = 0
  local last = size - 1
  if gx < 0 then
    outside, gx = -gx, 0
  elseif gx > last then
    outside, gx = gx - last, last
  end
  if gy < 0 then
    outside, gy = max(outside, -gy), 0
  elseif gy > last then
    outside, gy = max(outside, gy - last), last
  end
  local i, j = min(last - 1, floor(gx)), min(last - 1, floor(gy))
  local fx, fy = gx - i, gy - j
  local at = j * size + i + 1
  local h00, h10, h01, h11 = heights[at], heights[at + 1], heights[at + size], heights[at + size + 1]
  local top = h00 + (h10 - h00) * fx
  return top + (h01 + (h11 - h01) * fx - top) * fy + min(self.highest, outside * cell * self.rise)
end

--- Where a point of the road is, by its number (wrapping round)
--- @param index integer
--- @return number x, number y
function Course:Point(index)
  local at = ((index - 1) % self.count) * 2
  return self.track[at + 1], self.track[at + 2]
end

--- Where on the road a progress round it is, `offset` units to the right of the middle, and the
--- heading of the road there
--- @param progress number
--- @param offset number
--- @return number x, number y, number heading
function Course:Along(progress, offset)
  local spacing, count, track = self.spacing, self.count, self.track
  local along = (progress % self.length) / spacing
  local i = floor(along)
  local t = along - i
  local at, after = i * 2, ((i + 1) % count) * 2
  local x1, y1 = track[at + 1], track[at + 2]
  local dx, dy = track[after + 1] - x1, track[after + 2] - y1
  local length = sqrt(dx * dx + dy * dy)
  if length > 0 then
    dx, dy = dx / length, dy / length
  end
  -- To the right of the way the road goes, with y down, is (-dy, dx)
  return x1 + (track[after + 1] - x1) * t - dy * offset, y1 + (track[after + 2] - y1) * t + dx * offset, atan2(dy, dx)
end

--- How far a spot is from the stretch of road from point i to the next: the progress of the
--- nearest spot of it, how far right of it, and how far from it altogether
local function nearest(self, i, x, y)
  local track, count = self.track, self.count
  local at, after = i * 2, ((i + 1) % count) * 2
  local x1, y1 = track[at + 1], track[at + 2]
  local dx, dy = track[after + 1] - x1, track[after + 2] - y1
  local length2 = dx * dx + dy * dy
  local t = length2 > 0 and ((x - x1) * dx + (y - y1) * dy) / length2 or 0
  t = min(1, max(0, t))
  local px, py = x - (x1 + dx * t), y - (y1 + dy * t)
  local length = sqrt(length2)
  local offset = length > 0 and (py * dx - px * dy) / length or 0
  return (i + t) * self.spacing, offset, px * px + py * py
end

--- Where a spot is on the road: its progress round, how far right of the middle it is (left is
--- less than nothing), and the number of the stretch of road it is beside, to give back as `hint`
--- next time to look near there first
--- @param x number
--- @param y number
--- @param hint integer?
--- @return number progress, number offset, integer hint
function Course:Locate(x, y, hint)
  local count = self.count
  local best, bestOffset, bestDistance, bestIndex = 0, 0, math.huge, 0
  if hint then
    for i = hint - LOOK, hint + LOOK do
      local index = i % count
      local progress, offset, distance = nearest(self, index, x, y)
      if distance < bestDistance then
        best, bestOffset, bestDistance, bestIndex = progress, offset, distance, index
      end
    end
  end
  if bestDistance > NEAR * NEAR then
    for index = 0, count - 1 do
      local progress, offset, distance = nearest(self, index, x, y)
      if distance < bestDistance then
        best, bestOffset, bestDistance, bestIndex = progress, offset, distance, index
      end
    end
  end
  return best, bestOffset, bestIndex
end

--- Whether a spot `offset` units from the middle of the road is on it, curbs and all
--- @param offset number
--- @return boolean
function Course:OnRoad(offset)
  return offset < self.half + self.curb and offset > -(self.half + self.curb)
end
