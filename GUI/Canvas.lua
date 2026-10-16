--------------------------
--  Canvas
--------------------------
-- A sheet to draw on with the mouse, and to show what somebody else drew. A picture is lines,
-- each a colour, a width and the points it goes through, measured on a sheet of a size of its
-- own: the canvas shows that at whatever size it is given, so the same picture fills a window
-- or sits in a corner.
--
-- The client has no pixels to offer, only straight lines between two points. So a line that
-- was drawn is as many of those as it has points, with a round dot on every point where it is
-- thick enough for the corners to show. They are never thrown away: a canvas that is wiped
-- keeps them for the next picture. What is drawn later lies over what was drawn before, which
-- is all rubbing out is: a thick line the colour of the sheet.
--
-- The client keeps no order among what is drawn on the same frame on the same layer, so a red
-- line drawn over a black one may well come out under it. Each run of lines of one colour is
-- drawn on a frame of its own, every one a level over the one before. A fill is rectangles of
-- a colour, and goes under all the lines: it is made to reach a little under those around it,
-- since the patch it fills is found more coarsely than the lines are drawn.

--- @type nil, ForeverGamesPrivate
local _, private = ...

--- @class CanvasStroke
--- @field color number Which of the canvas's colours
--- @field width number Which of its widths
--- @field points number[] x and y of every point, one after the other

--- @class CanvasFill
--- @field color number Which of the canvas's colours
--- @field points number[] Where it was poured
--- @field area number[] What it covers, in the sheet's measure: x, y, width and height of each of its rectangles

--- @class CanvasOptions
--- @field width number How wide the sheet is in its own measure
--- @field height number
--- @field colors number[][] The colours a line can have, each as red, green and blue
--- @field widths number[] How thick a line can be, in the sheet's measure
--- @field paper number[] The colour of the sheet

--- @class Canvas
--- @field frame Frame
--- @field onPen (fun(x: number, y: number): boolean)? The pen was put down there on the sheet. Returns whether that starts a line
--- @field onDraw fun(x: number, y: number)? And moved to there
--- @field onLift fun()? And taken off
local Canvas = {}
Canvas.__index = Canvas
private.Canvas = Canvas

local DOT = "Interface\\AddOns\\ForeverGames\\Images\\Board\\dot"
-- How much of that texture is the dot
local DOT_FILL = 60 / 64
-- A line thinner than this many of the screen's points needs no dots on its corners
local ROUND_FROM = 2.5
-- How far the pen has to move before that is a new point, in the sheet's measure
local STEP = 3
-- More than this is more than a picture needs, and more than the client should be asked for
local MOST_MARKS = 9000
-- How many frames a picture is drawn on at most, one a level over the other. Whatever is put on
-- the sheet should be more than this many levels over it
Canvas.LAYERS = 120

--- @param parent Frame
--- @param options CanvasOptions
--- @return Canvas
function Canvas.New(parent, options)
  local self = setmetatable({ options = options, layers = {}, layer = 0, used = 0, shown = {}, scale = 1 }, Canvas)
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetClipsChildren(true)
  self.frame = frame

  local paper = frame:CreateTexture(nil, "BACKGROUND")
  paper:SetAllPoints()
  paper:SetColorTexture(options.paper[1], options.paper[2], options.paper[3])

  frame:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" and self.onPen then
      local x, y = self:cursor()
      self.down = self.onPen(x, y) == true
      self.lastX, self.lastY = x, y
    end
  end)
  frame:SetScript("OnMouseUp", function()
    self:lift()
  end)
  frame:SetScript("OnUpdate", function()
    if not self.down then
      return
    end
    -- The button can be let go of anywhere, not just over the sheet
    if not IsMouseButtonDown("LeftButton") then
      return self:lift()
    end
    local x, y = self:cursor()
    if math.abs(x - self.lastX) >= STEP or math.abs(y - self.lastY) >= STEP then
      self.lastX, self.lastY = x, y
      if self.onDraw then
        self.onDraw(x, y)
      end
    end
  end)
  frame:EnableMouse(false)
  return self
end

--- @return number x, number y Where the cursor is on the sheet, in its own measure
function Canvas:cursor()
  local frame = self.frame
  local x, y = GetCursorPosition()
  local scale = frame:GetEffectiveScale()
  return (x / scale - frame:GetLeft()) / self.scale, (frame:GetTop() - y / scale) / self.scale
end

function Canvas:lift()
  if self.down then
    self.down = false
    if self.onLift then
      self.onLift()
    end
  end
end

--- Whether the mouse draws. Without that it goes through the sheet to whatever is behind it
--- @param on boolean
function Canvas:SetInk(on)
  if on ~= self.ink then
    self.ink = on
    self.frame:EnableMouse(on)
    if not on then
      self:lift()
    end
  end
end

--- @param width number How wide to show the sheet, as high as goes with that
function Canvas:Layout(width)
  local scale = width / self.options.width
  if scale ~= self.scale or not self.laid then
    self.laid, self.scale = true, scale
    self.frame:SetSize(width, self.options.height * scale)
    -- Everything is somewhere else now
    self:wipe()
  end
end

function Canvas:wipe()
  for _, layer in ipairs(self.layers) do
    for index = 1, layer.used do
      layer.marks[index].line:Hide()
      layer.marks[index].dot:Hide()
    end
    for index = 1, layer.filled do
      layer.rects[index]:Hide()
    end
    layer.used, layer.filled = 0, 0
  end
  self.used, self.shown, self.layer, self.color = 0, {}, 0, nil
end

--- Moves on to a frame over everything drawn so far, unless there are as many as there can be
--- @param color number? What colour of line goes on it, nil for a fill
function Canvas:nextLayer(color)
  self.color = color
  if self.layer >= Canvas.LAYERS then
    return
  end
  self.layer = self.layer + 1
  local layer = self.layers[self.layer]
  if not layer then
    local frame = CreateFrame("Frame", nil, self.frame)
    frame:SetAllPoints()
    layer = { frame = frame, marks = {}, used = 0, rects = {}, filled = 0 }
    self.layers[self.layer] = layer
  end
  layer.frame:SetFrameLevel(self.frame:GetFrameLevel() + self.layer)
end

--- Draws from the point before to a point of a line, or the point alone if it is the first
--- @param stroke CanvasStroke
--- @param index number Which of its points
function Canvas:mark(stroke, index)
  if self.used >= MOST_MARKS then
    return
  end
  if self.color ~= stroke.color then
    self:nextLayer(stroke.color)
  end
  local layer = self.layers[self.layer]
  self.used, layer.used = self.used + 1, layer.used + 1
  local mark = layer.marks[layer.used]
  if not mark then
    mark = { line = layer.frame:CreateLine(nil, "ARTWORK"), dot = layer.frame:CreateTexture(nil, "ARTWORK") }
    mark.dot:SetTexture(DOT)
    layer.marks[layer.used] = mark
  end
  self.last = { layer = layer, index = layer.used }

  local scale, points = self.scale, stroke.points
  local color = self.options.colors[stroke.color] or self.options.colors[1]
  local thickness = math.max(1, (self.options.widths[stroke.width] or 1) * scale)
  local x, y = points[index * 2 - 1] * scale, -points[index * 2] * scale

  if index > 1 then
    mark.line:SetColorTexture(color[1], color[2], color[3])
    mark.line:SetThickness(thickness)
    mark.line:SetStartPoint("TOPLEFT", self.frame, points[index * 2 - 3] * scale, -points[index * 2 - 2] * scale)
    mark.line:SetEndPoint("TOPLEFT", self.frame, x, y)
    mark.line:Show()
  else
    mark.line:Hide()
  end

  if index == 1 or thickness >= ROUND_FROM then
    local size = math.max(2, thickness) / DOT_FILL
    mark.dot:SetVertexColor(color[1], color[2], color[3])
    mark.dot:SetSize(size, size)
    mark.dot:ClearAllPoints()
    mark.dot:SetPoint("CENTER", self.frame, "TOPLEFT", x, y)
    mark.dot:Show()
  else
    mark.dot:Hide()
  end
end

--- Draws a fill, on a frame of its own
--- @param fill CanvasFill
function Canvas:fill(fill)
  self:nextLayer(nil)
  local layer, scale, area = self.layers[self.layer], self.scale, fill.area
  local color = self.options.colors[fill.color] or self.options.colors[1]
  for index = 1, #area, 4 do
    if self.used >= MOST_MARKS then
      return
    end
    self.used, layer.filled = self.used + 1, layer.filled + 1
    local rect = layer.rects[layer.filled]
    if not rect then
      rect = layer.frame:CreateTexture(nil, "ARTWORK")
      layer.rects[layer.filled] = rect
    end
    rect:SetColorTexture(color[1], color[2], color[3])
    rect:ClearAllPoints()
    rect:SetPoint("TOPLEFT", self.frame, "TOPLEFT", area[index] * scale, -area[index + 1] * scale)
    rect:SetSize(area[index + 2] * scale, area[index + 3] * scale)
    rect:Show()
  end
end

--- Shows a picture. Cheap to call with the picture that is shown already, and with one that
--- only has more to it than the last: then only what is new is drawn. The last point of the last
--- line may have moved since, that is drawn again
--- @param strokes (CanvasStroke|CanvasFill)[]
function Canvas:Render(strokes)
  local same = #self.shown <= #strokes and self.base == self.frame:GetFrameLevel()
  for index, shown in ipairs(self.shown) do
    local stroke = strokes[index]
    if not same or stroke ~= shown.stroke or #stroke.points < shown.count * 2 then
      same = false
      break
    end
  end
  for index = #self.shown + 1, #strokes do
    -- A fill goes under every line, which takes drawing them all again
    if same and strokes[index].area and #self.shown > 0 then
      same = false
    end
  end
  local moved
  local lastShown = self.shown[#self.shown]
  if same and lastShown and not lastShown.stroke.area then
    local points, count = lastShown.stroke.points, lastShown.count
    if points[count * 2 - 1] ~= lastShown.x or points[count * 2] ~= lastShown.y then
      -- Only the last thing drawn can be drawn again in its place
      local last = self.last
      if lastShown.last and last and lastShown.last.layer == last.layer and lastShown.last.index == last.index and last.layer.used == last.index then
        moved = lastShown
      else
        same = false
      end
    end
  end
  if not same then
    self:wipe()
    self.base = self.frame:GetFrameLevel()
  elseif moved then
    local layer = moved.last.layer
    layer.used, self.used = layer.used - 1, self.used - 1
    moved.count = moved.count - 1
  end

  -- The fills first, under everything
  if #self.shown == 0 then
    for _, stroke in ipairs(strokes) do
      if stroke.area then
        self:fill(stroke)
      end
    end
  end
  for index, stroke in ipairs(strokes) do
    local shown = self.shown[index]
    if not shown then
      shown = { stroke = stroke, count = 0 }
      self.shown[index] = shown
    end
    if stroke.area then
      shown.count = 1
    else
      local total = #stroke.points / 2
      for point = shown.count + 1, total do
        self:mark(stroke, point)
      end
      if total > shown.count then
        shown.count, shown.last = total, self.last
        shown.x, shown.y = stroke.points[total * 2 - 1], stroke.points[total * 2]
      end
    end
  end
end
