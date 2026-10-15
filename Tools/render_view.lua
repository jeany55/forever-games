-- Draws a sector map the way the game shows it, outside the game: the view from a spot, as a
-- picture to look at. For whoever makes a map, to see it without loading the client.
--
--   lua Tools/render_view.lua <map.lua> <id> <out-folder> x,y,angle[,eye] ...
--
-- Run from the repository root. Every spot is a picture of its own, <out-folder>/view<N>.ppm, as
-- Doom's 320 by 168 view with its pixels as tall as Doom's (Tools/ppm_to_png.py makes PNGs of
-- them). The angle is in degrees, the eye that far over the floor (Doom's 41 if left out). What
-- stands in the map is drawn as it is on Doom's middle skill, standing still. The pictures are read
-- from where the map says they are, under Interface\AddOns\<addon>\..., as this repository has them.

local mapFile, id, outFolder = arg[1], arg[2], arg[3]
if not mapFile or not id or not outFolder or not arg[4] then
  io.stderr:write("Usage: lua Tools/render_view.lua <map.lua> <id> <out-folder> x,y,angle[,eye] ...\n")
  os.exit(1)
end

local WIDTH, HEIGHT, EYE, SKILL = 320, 168, 41, 2

local private = {}
private.Strips = { New = function()
  return { frame = {}, Layout = function() end }
end }
assert(loadfile("Engine/SectorMap.lua"))("ForeverGames", private)
assert(loadfile("GUI/SectorView.lua"))("ForeverGames", private)
assert(loadfile(mapFile))("ForeverGames", private)
local map = private.SectorMap.Load(id)

-- What stands about, in its first frame
local kinds = map.data.kinds or {}
for _, thing in ipairs(map.data.things) do
  local kind = kinds[thing.type]
  if kind and thing.flags % (SKILL * 2) >= SKILL and thing.flags % 32 < 16 then
    local letter = kind.frames:sub(1, 1)
    map:AddThing({ x = thing.x, y = thing.y, angle = math.rad(thing.angle), radius = kind.radius, height = kind.height, solid = kind.solid,
      hanging = kind.hanging, kind = kind, picture = kind.sprite .. letter,
      bright = kind.bright == "*" or (kind.bright ~= "" and kind.bright:find(letter, 1, true) ~= nil) })
  end
end

-- Pictures, read from their TGAs: rows of { r, g, b, a } from the top
local pictures = {}
local function picture(file)
  local found = pictures[file]
  if found then
    return found
  end
  local path = file:gsub("^Interface\\AddOns\\", ""):gsub("\\", "/") .. ".tga"
  local handle = assert(io.open(path, "rb"), "No picture " .. path)
  local raw = handle:read("*a")
  handle:close()
  local width = raw:byte(13) + raw:byte(14) * 256
  local height = raw:byte(15) + raw:byte(16) * 256
  local pixels = {}
  for y = 0, height - 1 do
    -- TGA rows run bottom to top
    local at = 19 + (height - 1 - y) * width * 4
    for x = 0, width - 1 do
      local b, g, r, a = raw:byte(at + x * 4, at + x * 4 + 3)
      pixels[y * width + x] = { r, g, b, a }
    end
  end
  found = { width = width, height = height, pixels = pixels }
  pictures[file] = found
  return found
end

local function sample(file, u, v)
  local found = picture(file)
  local x = math.floor(u * found.width) % found.width
  local y = math.floor(v * found.height) % found.height
  return found.pixels[y * found.width + x]
end

local function shoot(x, y, angle, eye)
  local view = private.SectorView.New({}, { width = WIDTH, height = HEIGHT })
  view:SetMap(map)
  local calls, level = {}, 0
  local sink = {
    Begin = function() end,
    SetLevel = function(_, to) level = to end,
    Quad = function(_, ...) calls[#calls + 1] = { level, #calls, "quad", ... } end,
    Mapped = function(_, ...) calls[#calls + 1] = { level, #calls, "mapped", ... } end,
    Finish = function() return #calls end,
  }
  local z = map:SectorAt(x, y).floor + eye
  view:Draw({ x = x, y = y, z = z, angle = math.rad(angle) }, sink)
  table.sort(calls, function(one, other)
    if one[1] ~= other[1] then
      return one[1] < other[1]
    end
    return one[2] < other[2]
  end)
  local screen = {}
  for index = 0, WIDTH * HEIGHT - 1 do
    screen[index] = { 255, 0, 255 }
  end
  local function put(px, py, texel, r, g, b, alpha)
    if px < 0 or px >= WIDTH or py < 0 or py >= HEIGHT or not texel or texel[4] == 0 then
      return
    end
    local pixel = screen[py * WIDTH + px]
    local a = alpha or 1
    pixel[1] = pixel[1] * (1 - a) + texel[1] * r * a
    pixel[2] = pixel[2] * (1 - a) + texel[2] * g * a
    pixel[3] = pixel[3] * (1 - a) + texel[3] * b * a
  end
  for _, call in ipairs(calls) do
    local left, top, right, bottom, file = call[4], call[5], call[6], call[7], call[8]
    for py = math.floor(top), math.ceil(bottom) - 1 do
      for px = math.floor(left), math.ceil(right) - 1 do
        local across = (px + 0.5 - left) / (right - left)
        local down = (py + 0.5 - top) / (bottom - top)
        if call[3] == "quad" then
          local u0, u1, v0, v1, r, g, b, a = call[9], call[10], call[11], call[12], call[13], call[14], call[15], call[16]
          put(px, py, sample(file, u0 + (u1 - u0) * across, v0 + (v1 - v0) * down), r, g, b, a)
        else
          -- A row of floor: from its top left corner to its top right
          local ulx, uly, urx, ury, r, g, b = call[9], call[10], call[13], call[14], call[17], call[18], call[19]
          put(px, py, sample(file, ulx + (urx - ulx) * across, uly + (ury - uly) * across), r, g, b)
        end
      end
    end
  end
  return screen
end

for index = 4, #arg do
  local x, y, angle, eye = arg[index]:match("^(-?[%d.]+),(-?[%d.]+),(-?[%d.]+),?(-?[%d.]*)$")
  assert(x, "A spot is x,y,angle[,eye]: " .. arg[index])
  local screen = shoot(tonumber(x), tonumber(y), tonumber(angle), tonumber(eye) or EYE)
  local path = ("%s/view%d.ppm"):format(outFolder, index - 3)
  local handle = assert(io.open(path, "wb"))
  handle:write(("P6\n%d %d\n255\n"):format(WIDTH, HEIGHT))
  local row = {}
  for py = 0, HEIGHT - 1 do
    for px = 0, WIDTH - 1 do
      local pixel = screen[py * WIDTH + px]
      row[px + 1] = string.char(math.floor(math.min(255, pixel[1])), math.floor(math.min(255, pixel[2])), math.floor(math.min(255, pixel[3])))
    end
    handle:write(table.concat(row))
  end
  handle:close()
  print(path)
end
