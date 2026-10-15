--------------------------
--  Geo Bench: panoramas
--------------------------
-- Looking around in a panorama: the picture is the inside of a cylinder round where it was taken
-- (stitch.py makes them so), its width all the way round and its height from `top` to `bottom`,
-- heights on a cylinder of radius 1 (the tangent of how far above the horizon). The screen is cut
-- into columns, each showing the slice of the cylinder it sees: a column `x` across from the
-- middle sees the cylinder at an angle atan(x / f) from where you look, and there the cylinder
-- is 1 / cos of that angle away, so the slice is that much taller. Within a column the slice
-- maps onto it linearly, top to bottom: it is exact up to the column's width. It is how Doom drew
-- a wall, and the same textured columns Freedoom's Strips are.
--
-- Looking up and down moves the picture up and down (as Doom's looking up did) rather than tilt
-- it: fine for as far as the panoramas go above and below the horizon.
--
-- A panorama is a few pictures side by side (tiles), as one picture can only be so wide: a column
-- that crosses from one to the next is drawn as two.
--
--   /geobench pano [name] [cols <n>] [fov <degrees>] [full] [nearest] [spin]
--   /geobench sweep
--
-- Drag to look round (it carries on a little when let go), the wheel or + and - to zoom, arrows
-- to turn, Space to spin by itself. Measured for a few seconds when it spins (spin), else the
-- readout says how each frame went.

local _, ns = ...
local say = ns.say
local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local atan, tan, cos, pi = math.atan, math.tan, math.cos, math.pi
local TAU = 2 * pi

local WIDTH, HEIGHT = 960, 540
local DEFAULTS = { cols = 320, fov = 80 }
local MIN_FOV, MAX_FOV = 25, 110
-- Radians a second the arrows turn, and spinning by itself does
local TURN, SPIN = 1.2, 0.5
-- How quickly a flung view slows (part of its speed kept a second)
local CARRY = 0.04
-- The fastest a fling turns the view, radians a second
local MAX_FLING = 6

local frame = ns.frame
local pieces = {}
local sky = frame:CreateTexture(nil, "BACKGROUND", nil, -6)
local ground = frame:CreateTexture(nil, "BACKGROUND", nil, -6)
local view

local function texture(index)
  local piece = pieces[index]
  if not piece then
    piece = { texture = frame:CreateTexture(nil, "ARTWORK") }
    pieces[index] = piece
  end
  return piece
end

local function hideFrom(index)
  for i = index, #pieces do
    local piece = pieces[i]
    if piece.shown then
      piece.texture:Hide()
      piece.shown = false
    end
  end
end

--- Shows a piece: tile `tile` of the panorama from `left` to `right` across it, on the window from
--- x0 to x1 and y0 to y1 down. Nothing is told the client again that it was the frame before
local function place(index, tile, left, right, x0, x1, y0, y1)
  local piece = texture(index)
  local t = piece.texture
  local file = view.files[tile]
  if piece.file ~= file then
    piece.file = file
    t:SetTexture(file, nil, nil, view.filter)
  end
  if piece.left ~= left or piece.right ~= right then
    piece.left, piece.right = left, right
    t:SetTexCoord(left, right, 0, 1)
  end
  if piece.x0 ~= x0 or piece.y0 ~= y0 then
    piece.x0, piece.y0 = x0, y0
    t:SetPoint("TOPLEFT", frame, "TOPLEFT", x0, -y0)
  end
  local w, h = x1 - x0, y1 - y0
  if piece.w ~= w or piece.h ~= h then
    piece.w, piece.h = w, h
    t:SetSize(w, h)
  end
  if not piece.shown then
    t:Show()
    piece.shown = true
  end
end

--- Draws the view, and how many pieces it took
local function draw()
  local v = view
  local scale = v.scale
  local width, height = v.width * scale, v.height * scale
  local f = width / 2 / tan(math.rad(v.fov) / 2)
  local pano = v.pano
  local tiles = pano.tiles
  local cols = v.cols
  local cw = width / cols
  local middle = height / 2
  local yaw, shear = v.yaw, v.shear
  local count = 0
  -- Sky above the horizon, ground below, where the picture doesn't reach
  local horizon = middle - shear
  sky:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  sky:SetSize(width, max(1, horizon))
  ground:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -max(0, horizon))
  ground:SetSize(width, max(1, height - horizon))
  for c = 0, cols - 1 do
    local x0 = c * cw - width / 2
    local x1 = x0 + cw
    local a0 = yaw + atan(x0 / f)
    local a1 = yaw + atan(x1 / f)
    local stretch = f / cos(atan((x0 + x1) / 2 / f))
    local y0 = middle - stretch * pano.top - shear
    local y1 = middle - stretch * pano.bottom - shear
    -- Where across the panorama, counted in tiles
    local u0, u1 = a0 / TAU * tiles, a1 / TAU * tiles
    local k = floor(u0)
    local edge = k + 1
    if u1 <= edge + 1e-9 then
      count = count + 1
      place(count, k % tiles + 1, u0 - k, min(1, u1 - k), x0 + width / 2, x1 + width / 2, y0, y1)
    else
      -- Crosses into the next tile: two pieces, split where that tile begins
      local xb = f * tan(edge / tiles * TAU - yaw)
      count = count + 1
      place(count, k % tiles + 1, u0 - k, 1, x0 + width / 2, xb + width / 2, y0, y1)
      count = count + 1
      place(count, edge % tiles + 1, 0, min(1, u1 - edge), xb + width / 2, x1 + width / 2, y0, y1)
    end
  end
  hideFrom(count + 1)
  return count
end

local function compass(v)
  -- The panorama begins (yaw 0) where you faced when it was taken; facing is anticlockwise from
  -- north, the panorama goes round clockwise
  local facing = v.pano.facing
  if not facing then
    return ""
  end
  local degrees = (math.deg(v.yaw) - math.deg(facing)) % 360
  local points = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
  return ("   heading %03d %s"):format(degrees, points[floor((degrees + 22.5) / 45) % 8 + 1])
end

local function clampShear(v)
  local scale = v.scale
  local height = v.height * scale
  local f = v.width * scale / 2 / tan(math.rad(v.fov) / 2)
  -- No further than the picture's edge coming 15% of the way in from the window's
  local up = max(0, f * v.pano.top - height * 0.35)
  local down = max(0, -f * v.pano.bottom - height * 0.35)
  v.shear = max(-up, min(down, v.shear))
end

local function zoom(v, by)
  v.fov = max(MIN_FOV, min(MAX_FOV, v.fov * by))
  clampShear(v)
end

local function cursorAngle(v, x)
  local scale = v.scale
  local width = v.width * scale
  local f = width / 2 / tan(math.rad(v.fov) / 2)
  return atan((x - width / 2) / f)
end

local mode = {}
local queue

function mode.start(pano, options)
  local full = options.full
  local width, height = WIDTH, HEIGHT
  if full then
    width, height = UIParent:GetWidth(), UIParent:GetHeight()
  end
  local scale = ns.window(width, height)
  local files = {}
  for tile = 1, pano.tiles do
    files[tile] = ns.IMAGES .. pano.file .. "_" .. tile
  end
  view = { pano = pano, files = files, width = width, height = height, scale = scale, cols = options.cols or DEFAULTS.cols,
    fov = options.fov or DEFAULTS.fov, yaw = options.yaw or 0, shear = 0, spin = options.spin, keys = {}, speed = 0,
    filter = options.nearest and "NEAREST" or nil, clock = 0, shown = 0 }
  local sc, gc = pano.sky or { 0.45, 0.6, 0.8 }, pano.ground or { 0.25, 0.22, 0.18 }
  sky:SetColorTexture(sc[1], sc[2], sc[3], 1)
  ground:SetColorTexture(gc[1], gc[2], gc[3], 1)
  sky:Show()
  ground:Show()
  -- Whether each tile loads
  local probe = texture(1).texture
  view.loaded = 0
  for tile = 1, pano.tiles do
    if probe:SetTexture(files[tile]) ~= false then
      view.loaded = view.loaded + 1
    end
  end
  texture(1).file = nil
  if view.loaded < pano.tiles then
    say(("|cffff4040%d of %d pictures of %s didn't load|r: a picture new since the game started needs it restarted"):format(
      pano.tiles - view.loaded, pano.tiles, pano.name))
  end
  if options.spin then
    view.measuring = ns.measurement(("%s %dx%d in %d tiles, %d columns, fov %d%s%s"):format(pano.name, pano.width, pano.height,
      pano.tiles, view.cols, view.fov, full and ", full screen" or "", options.nearest and ", nearest" or ""))
  end
  clampShear(view)
end

function mode.stop()
  hideFrom(1)
  sky:Hide()
  ground:Hide()
  view = nil
end

function mode.update(elapsed)
  local v = view
  if not v then
    return
  end
  elapsed = min(elapsed, 0.1)
  if v.dragging then
    local x, y = ns.cursor()
    local before = v.yaw
    v.yaw = v.grabYaw - (cursorAngle(v, x) - cursorAngle(v, v.grabX))
    v.shear = v.grabShear + (v.grabY - y)
    clampShear(v)
    -- Turned by the shorter way round: the yaw is kept within one turn, so a drag across where it
    -- starts again would otherwise look like a whole turn in a frame, and fling the view round
    local turned = (v.yaw - before + pi) % TAU - pi
    v.speed = max(-MAX_FLING, min(MAX_FLING, turned / max(elapsed, 0.001) * 0.5 + v.speed * 0.5))
  elseif v.spin then
    v.yaw = v.yaw + SPIN * elapsed
  else
    local turn = (v.keys.RIGHT and 1 or 0) - (v.keys.LEFT and 1 or 0)
    if turn ~= 0 then
      v.yaw, v.speed = v.yaw + turn * TURN * elapsed, 0
    elseif abs(v.speed) > 0.01 then
      v.yaw = v.yaw + v.speed * elapsed
      v.speed = v.speed * CARRY ^ elapsed
    end
    local tilt = (v.keys.UP and 1 or 0) - (v.keys.DOWN and 1 or 0)
    if tilt ~= 0 then
      v.shear = v.shear - tilt * 300 * elapsed
      clampShear(v)
    end
  end
  v.yaw = v.yaw % TAU
  local began = debugprofilestop()
  local count = draw()
  local spent = debugprofilestop() - began
  if v.measuring and ns.measure(v.measuring, elapsed, spent, count) then
    ns.result(v.measuring)
    v.measuring = nil
    if queue then
      local following = table.remove(queue, 1)
      if following then
        ns.begin(mode, following[1], following[2])
        return
      end
      queue = nil
      say("Sweep done. /reload to keep the results in GeoBenchDB")
      ns.finish()
      return
    end
  end
  v.clock = v.clock + elapsed
  if v.clock - v.shown >= 0.25 then
    v.shown = v.clock
    local p = v.pano
    ns.readout(("%s%s%s\n%d columns, fov %.0f, %d pieces: frame %.1f ms, Lua %.2f ms%s\n%s"):format(p.name,
      p.zone and (": " .. p.zone) or "", p.subzone and p.subzone ~= "" and (" / " .. p.subzone) or "", v.cols, v.fov, count,
      elapsed * 1000, spent, compass(v), v.measuring and "measuring" or "drag to look, wheel to zoom, Space spins, Escape stops"))
  end
end

function mode.key(key, down)
  local v = view
  if not v then
    return false
  end
  if key == "LEFT" or key == "RIGHT" or key == "UP" or key == "DOWN" then
    v.keys[key] = down or nil
    return true
  end
  if not down then
    return false
  end
  if key == "SPACE" then
    v.spin = not v.spin
    return true
  elseif key == "=" or key == "+" or key == "NUMPADPLUS" then
    zoom(v, 0.9)
    return true
  elseif key == "-" or key == "NUMPADMINUS" then
    zoom(v, 1 / 0.9)
    return true
  end
  return false
end

function mode.wheel(delta)
  if view then
    zoom(view, 0.9 ^ delta)
  end
end

function mode.down(button)
  local v = view
  if v and button == "LeftButton" then
    local x, y = ns.cursor()
    v.dragging, v.grabX, v.grabY, v.grabYaw, v.grabShear, v.speed, v.spin = true, x, y, v.yaw, v.shear, 0, false
  end
end

function mode.up(button)
  if view and button == "LeftButton" then
    view.dragging = false
  end
end

local function find(name)
  local panos = ns.panos or {}
  if not name then
    -- The newest of your own, else the test picture
    return panos[#panos]
  end
  for _, pano in ipairs(panos) do
    if pano.name:lower() == name:lower() then
      return pano
    end
  end
end

ns.commands.pano = {
  usage = "[name] [cols <n>] [fov <degrees>] [full] [nearest] [spin]",
  run = function(words)
    local options, index, name = {}, 2, nil
    while words[index] do
      local word, value = words[index]:lower(), tonumber(words[index + 1])
      if (word == "cols" or word == "fov") and value then
        options[word], index = value, index + 2
      elseif word == "full" or word == "nearest" or word == "spin" then
        options[word], index = true, index + 1
      elseif not name then
        name, index = words[index], index + 1
      else
        return false
      end
    end
    options.cols = options.cols and max(8, min(1600, floor(options.cols)))
    local pano = find(name)
    if not pano then
      local names = {}
      for i, p in ipairs(ns.panos or {}) do
        names[i] = p.name
      end
      say(("No panorama %s. There are: %s"):format(tostring(name), table.concat(names, ", ")))
      return true
    end
    queue = nil
    ns.begin(mode, pano, options)
    return true
  end,
}

ns.commands.sweep = {
  run = function()
    queue = {}
    for _, name in ipairs({ "test2048", "test4096" }) do
      local pano = find(name)
      if pano then
        for _, cols in ipairs({ 160, 320, 640, 960 }) do
          queue[#queue + 1] = { pano, { cols = cols, spin = true } }
        end
      end
    end
    local own = find()
    if own and own.name ~= "test2048" and own.name ~= "test4096" then
      queue[#queue + 1] = { own, { cols = 320, spin = true } }
      queue[#queue + 1] = { own, { cols = 320, spin = true, full = true } }
    end
    local first = table.remove(queue, 1)
    if not first then
      say("No panoramas to sweep: run install.sh, which makes the test pictures")
      return true
    end
    say(("Sweeping %d measurements, about %d seconds. Escape stops it"):format(#queue + 1, (#queue + 1) * 5))
    ns.begin(mode, first[1], first[2])
    return true
  end,
}
