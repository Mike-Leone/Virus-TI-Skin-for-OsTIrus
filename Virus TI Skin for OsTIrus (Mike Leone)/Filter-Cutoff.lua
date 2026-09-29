-- ============================================================
-- Analog mode toggle + filter cutoff/resonance XY pad
-- Two independent pieces sharing one file: a button that toggles the filter
-- between its "Classic" (modes 0-3) and "Analog" (modes 4-7) mode groups,
-- remembering the last mode used within each group; and a draggable XY
-- handle overlaid on each filter's LCD strip that edits Cutoff (X) and
-- Resonance (Y) — with the handle's X position and hit-shape depending on
-- the filter's current mode, since each mode draws a differently-shaped curve.
-- ============================================================

-- ========== Analog Mode toggle ==========
local DEFAULT_CLASSIC = 0   -- fallback "last classic mode" if none has been visited yet
local DEFAULT_ANALOG = 4    -- fallback "last analog mode" if none has been visited yet

local lastClassic = DEFAULT_CLASSIC
local lastAnalog = DEFAULT_ANALOG

-- Modes 0-3 are the "classic" filter types, 4-7 are "analog" emulations
local function isClassic(value)
	return value <= 3
end

local function clamp(value)
	return math.max(0, math.min(7, tonumber(value) or 0))
end

-- Tracks whichever classic/analog mode was most recently active, so the
-- toggle button can restore it later
local function onFilterModeChanged()
	local current = clamp(params.get("Filter1 Mode"))
	if isClassic(current) then
		lastClassic = current
	else
		lastAnalog = current
	end
end

-- Global — bound to the button by name, do not rename. Switches Filter 1
-- between its last-used classic mode and its last-used analog mode.
function Button_Analog_Mode()
	local current = clamp(params.get("Filter1 Mode"))
	params.set("Filter1 Mode", isClassic(current) and lastAnalog or lastClassic)
end

-- ========== Filter cutoff / resonance XY pad ==========
local CANVAS_W = 166                        -- reference canvas width the layout constants below were designed at
local BOX, HALF, STROKE = 10, 5, 2          -- handle square size, half of that size, handle border thickness
local TOP_MARGIN, Y_BOTTOM = 28, 72         -- resonance handle's Y range for modes other than 3
local Y_MODE3_TOP, Y_MODE3_BOT = 72, 128    -- resonance handle's Y range for mode 3, which uses a separate band

local SPEED = { shift = 0.1, ctrl = 0.2, alt = 0.5 }   -- drag speed multipliers for modifier keys
local WHEEL = { default = 4, shift = 2, ctrl = 1 }     -- mouse wheel step size per modifier key
local HIT_MARGIN, DBLCLICK_MARGIN = 8, 4               -- extra pixels around the handle that still count as a hit

local DEFAULTS = { cutoff = 127, res = 0 }   -- values restored on double-click (only res is actually reset, see onDblClick)

local canvases = {}          -- all registered canvas entries (one per filter LCD)
local dragging = nil         -- the canvas entry currently being dragged, or nil
local dragLastX, dragLastY = 0, 0     -- last raw mouse position seen during a drag (for computing deltas)
local dragVirtX, dragVirtY = 0, 0     -- "virtual" cursor position, scaled by modifier-key drag speed
local stickyHit = false      -- whether the mouse is currently considered "on" the handle (hover or active drag)

local function getParam(name, fallback)
	return tonumber(params.get(name)) or fallback
end

local function clamp01(v)
	if v < 0 then return 0 elseif v > 1 then return 1 end
	return v
end

local function clamp127(v)
	if v < 0 then return 0 elseif v > 127 then return 127 end
	return v
end

local function keyDown(v)
	return v == true or (type(v) == "number" and v ~= 0)
end

-- Rounds a coordinate to the nearest whole pixel (for crisp canvas rendering)
local function roundToPixel(v)
	return math.floor(v + 0.5)
end

-- Snaps a line's center so a stroke of width w renders on a crisp pixel boundary
local function snapLine(v, w)
	return math.floor(v - w / 2 + 0.5) + w / 2
end

-- Returns the drag-speed multiplier for whichever modifier key is held
local function dragSpeedScale(event)
	local p = event.parameters
	if keyDown(p.shift_key) then return SPEED.shift
	elseif keyDown(p.ctrl_key) then return SPEED.ctrl
	elseif keyDown(p.alt_key) then return SPEED.alt end
	return 1.0
end

-- Converts a mouse event's page-relative coordinates into coordinates local to element `el`
local function getLocalMouse(event, el)
	local mx, my = event.parameters.mouse_x, event.parameters.mouse_y
	local left, top, e = 0, 0, el
	while e do
		left = left + (tonumber(e.offset_left) or 0)
		top = top + (tonumber(e.offset_top) or 0)
		e = e.parent_node
	end
	return mx - left, my - top
end

-- Converts a normalized position along the cutoff curve (0..1, "t") into a
-- normalized cutoff value (0..1), given where the curve's "knee" sits
local function cutoffFromT(t, knee)
	t = clamp01(t)
	if t <= knee then return t / knee * 0.5 end
	return 0.5 + (t - knee) / (1 - knee) * 0.5
end

-- Inverse of cutoffFromT: converts a normalized cutoff (0..1) into a
-- normalized position along the curve (0..1, "t")
local function tFromCutoff(cut, knee)
	if cut <= 0.5 then return cut * 2 * knee end
	return knee + (cut - 0.5) * 2 * (1 - knee)
end

-- Maps a raw local (possibly speed-scaled/"virtual") canvas position to
-- Cutoff/Resonance parameter values (0..127), given the filter's current
-- mode. Each mode places its curve differently along X, so the cutoff
-- mapping branches by mode; resonance's Y range also depends on mode (3 uses
-- a separate band from the rest).
local function posToParams(localX, localY, w, mode)
	local scale = w / CANVAS_W
	local boxX, boxY = localX / scale, localY / scale

	local resTop = (mode == 3) and Y_MODE3_TOP or TOP_MARGIN
	local resBot = (mode == 3) and Y_MODE3_BOT or Y_BOTTOM
	local res = clamp01(1 - (((boxY - HALF) - resTop) / (resBot - resTop)))

	local cut
	if mode == 0 or mode == 4 or mode == 5 or mode == 6 or mode == 7 then
		local t = clamp01((boxX - 12 - HALF) / (CANVAS_W - BOX - 38))
		cut = cutoffFromT(t, 0.5593)
	elseif mode == 1 then
		local knee = ((83 - 1 - HALF) - 26) / (CANVAS_W - BOX - 38)
		local t = clamp01((boxX - 26 - HALF) / (CANVAS_W - BOX - 38))
		cut = cutoffFromT(t, knee)
	else
		cut = clamp01((boxX - 26 - HALF) / (CANVAS_W - BOX - 52))
	end

	return cut * 127, res * 127
end

-- Canvas paint callback: draws the filter's curve (mode-dependent shape,
-- from a fixed anchor point to the cutoff/resonance handle) and the handle
-- square itself; records the handle's hit-test rectangle on `entry`.
local function drawFilterMeter(ctx, entry)
	local canvas = entry.canvas
	local w = canvas.offset_width
	if w <= 0 then return end

	local scale = w / CANVAS_W
	local lineW = 2 * scale
	ctx.fillStyle = "#697081"
	ctx.strokeStyle = "#0F1B2A"
	ctx.lineWidth = lineW

	local mode = getParam(entry.mode, 0)
	local cut = clamp01(getParam(entry.cutoff, 64) / 127)
	local res = clamp01(getParam(entry.res, 64) / 127)

	local yPos = Y_BOTTOM - res * (Y_BOTTOM - TOP_MARGIN)
	local cy = yPos + HALF
	local xPos, cx

	ctx:beginPath()

	if mode == 0 or mode == 4 or mode == 5 or mode == 6 or mode == 7 then
		local t = tFromCutoff(cut, 0.5593)
		xPos = 12 + t * (CANVAS_W - BOX - 38)
		cx = xPos + HALF
		local ay = 77
		local ayS = snapLine(ay * scale, lineW)
		ctx:moveTo(8 * scale, ayS)
		ctx:lineTo(snapLine((cx - 8) * scale, lineW), ayS)
		ctx:lineTo(snapLine(cx * scale, lineW), snapLine(cy * scale, lineW))
		ctx:lineTo(snapLine((cx + 20) * scale, lineW), snapLine((ay + 61) * scale, lineW))

	elseif mode == 1 then
		local knee = ((83 - 1 - HALF) - 26) / (CANVAS_W - BOX - 38)
		local t = tFromCutoff(cut, knee)
		xPos = 26 + t * (CANVAS_W - BOX - 38)
		cx = xPos + HALF
		local ay = 77
		local ayS = snapLine(ay * scale, lineW)
		ctx:moveTo((CANVAS_W - 8) * scale, ayS)
		ctx:lineTo(snapLine((cx + 8) * scale, lineW), ayS)
		ctx:lineTo(snapLine(cx * scale, lineW), snapLine(cy * scale, lineW))
		ctx:lineTo(snapLine((cx - 20) * scale, lineW), snapLine((ay + 61) * scale, lineW))

	elseif mode == 2 then
		xPos = 26 + cut * (CANVAS_W - BOX - 52)
		cx = xPos + HALF
		ctx:moveTo(snapLine((cx - 20) * scale, lineW), snapLine(138 * scale, lineW))
		ctx:lineTo(snapLine(cx * scale, lineW), snapLine(cy * scale, lineW))
		ctx:lineTo(snapLine((cx + 20) * scale, lineW), snapLine(138 * scale, lineW))

	elseif mode == 3 then
		xPos = 26 + cut * (CANVAS_W - BOX - 52)
		cx = xPos + HALF
		yPos = Y_MODE3_BOT - res * (Y_MODE3_BOT - Y_MODE3_TOP)
		cy = yPos + HALF
		local ay = 77
		local ayS = snapLine(ay * scale, lineW)
		ctx:moveTo(8 * scale, ayS)
		ctx:lineTo(snapLine((cx - 9) * scale, lineW), ayS)
		ctx:lineTo(snapLine(cx * scale, lineW), snapLine(cy * scale, lineW))
		ctx:lineTo(snapLine((cx + 9) * scale, lineW), ayS)
		ctx:lineTo((CANVAS_W - 8) * scale, ayS)
	else
		xPos = (CANVAS_W - BOX) * 0.5
		cx = xPos + HALF
	end

	ctx:stroke()

	local handleSize, strokeW, halfHandle = BOX * scale, STROKE * scale, HALF * scale
	local x, y = xPos * scale + halfHandle, yPos * scale + halfHandle

	local outerX, outerY = roundToPixel(x - halfHandle - strokeW), roundToPixel(y - halfHandle - strokeW)
	local outerS = roundToPixel(handleSize + strokeW * 2)
	local innerX, innerY = roundToPixel(x - halfHandle), roundToPixel(y - halfHandle)

	ctx.fillStyle = "#CACFD8"
	ctx:fillRect(outerX, outerY, outerS, outerS)
	ctx.fillStyle = "#697081"
	ctx:fillRect(innerX, innerY, roundToPixel(handleSize), roundToPixel(handleSize))

	entry.squareX, entry.squareY, entry.squareSize = outerX, outerY, outerS
end

-- Returns true if (lx, ly) is within marginPx of the handle square recorded
-- by the last drawFilterMeter call for this entry
local function hitTest(entry, lx, ly, marginPx)
	local margin = (marginPx or HIT_MARGIN) * (entry.canvas.offset_width / CANVAS_W)
	return lx >= entry.squareX - margin and lx <= entry.squareX + entry.squareSize + margin
			and ly >= entry.squareY - margin and ly <= entry.squareY + entry.squareSize + margin
end

-- Double-click on the handle resets Resonance to its default (Cutoff is
-- left untouched — DEFAULTS.cutoff exists but is unused here)
local function onDblClick(entry, event)
	local lx, ly = getLocalMouse(event, entry.element)
	if not hitTest(entry, lx, ly, DBLCLICK_MARGIN) then return end
	params.set(entry.res, DEFAULTS.res)
	event:StopPropagation()
end

-- Mouse wheel over the handle nudges Resonance up/down by a step size that
-- depends on the held modifier key
local function onWheel(entry, event)
	if not stickyHit then
		local lx, ly = getLocalMouse(event, entry.element)
		stickyHit = hitTest(entry, lx, ly)
	end
	if not stickyHit then return end

	local delta = event.parameters.wheel_delta_y or event.parameters.wheel_delta or 0
	if delta == 0 then return end

	local amount = WHEEL.default
	if keyDown(event.parameters.shift_key) then amount = WHEEL.shift
	elseif keyDown(event.parameters.ctrl_key) then amount = WHEEL.ctrl end

	local cur = getParam(entry.res, 64)
	params.set(entry.res, clamp127(cur + ((delta > 0) and -amount or amount)))
	event:StopPropagation()
end

-- Registers one filter LCD canvas as an editable cutoff/resonance XY pad
local function setupCanvas(id, modeName, cutoffName, resName)
	local el = document:GetElementById(id)
	if not el then return end

	local canvas = Element.As.Canvas(el)
	local entry = {
		canvas = canvas, element = el,
		mode = modeName, cutoff = cutoffName, res = resName,
		squareX = 0, squareY = 0, squareSize = BOX,
	}

	canvas:setPaintFunction(function(ctx) drawFilterMeter(ctx, entry) end)

	el:AddEventListener("mousedown", function(event)
		local lx, ly = getLocalMouse(event, el)
		-- Drag + modifiers only apply when starting on the resonance square
		if not hitTest(entry, lx, ly) then return end
		dragging = entry
		stickyHit = true
		dragLastX, dragLastY = lx, ly
		dragVirtX, dragVirtY = lx, ly
	end)

	el:AddEventListener("dblclick", function(event) onDblClick(entry, event) end)
	el:AddEventListener("mousescroll", function(event) onWheel(entry, event) end)

	el:AddEventListener("mousemove", function(event)
		if dragging then return end
		local lx, ly = getLocalMouse(event, el)
		stickyHit = hitTest(entry, lx, ly)
	end)

	el:AddEventListener("mouseout", function()
		if dragging then return end
		stickyHit = false
	end)

	canvases[#canvases + 1] = entry
	canvas:repaint()
end

-- Registers the document-level mousemove/mouseup listeners that drive an
-- in-progress drag on whichever canvas entry is currently `dragging`
local function setupGlobalDragHandlers()
	document:AddEventListener("mousemove", function(event)
		if not dragging then return end
		local lx, ly = getLocalMouse(event, dragging.element)
		local speedScale = dragSpeedScale(event) -- Shift x0.1, Ctrl x0.2, Alt x0.5
		dragVirtX = dragVirtX + (lx - dragLastX) * speedScale
		dragVirtY = dragVirtY + (ly - dragLastY) * speedScale
		dragLastX, dragLastY = lx, ly

		local mode = getParam(dragging.mode, 0)
		local cut, res = posToParams(dragVirtX, dragVirtY, dragging.canvas.offset_width, mode)
		params.set(dragging.cutoff, math.floor(cut + 0.5))
		params.set(dragging.res, math.floor(res + 0.5))
	end)

	document:AddEventListener("mouseup", function()
		dragging = nil
	end)
end

-- Repaints every canvas entry whose mode/cutoff/resonance parameter matches
-- one of the given names
local function repaintByParams(...)
	local names = { ... }
	for i = 1, #canvases do
		local c = canvases[i]
		for j = 1, #names do
			if c.mode == names[j] or c.cutoff == names[j] or c.res == names[j] then
				c.canvas:repaint()
				break
			end
		end
	end
end

-- Builds a params.onChange callback that repaints every canvas depending on
-- any of the given parameter names (used so one filter's 3 parameters share
-- a single closure instead of each needing its own inline handler)
local function makeRepaintHandler(...)
	local names = { ... }
	return function() repaintByParams(table.unpack(names)) end
end

-- ------------------------------------------------------------
-- Entry point
-- Global — bound to a widget lifecycle event by name, do not rename.
-- ------------------------------------------------------------
function Filter_Cutoff()
	params.onChange("Filter1 Mode", onFilterModeChanged)
	params.onPartChanged(onFilterModeChanged)
	onFilterModeChanged()

	canvases, dragging, stickyHit = {}, nil, false
	dragLastX, dragLastY = 0, 0

	-- Filter 1's main and "Easy" LCDs both edit the same underlying
	-- parameters, so both get their own canvas entry driving the same target
	local canvasSetups = {
		{ "Filter-1-LCD", "Filter1 Mode", "Cutoff", "Filter1 Resonance" },
		{ "Filter-1-Easy-LCD", "Filter1 Mode", "Cutoff", "Filter1 Resonance" },
		{ "Filter-2-LCD", "Filter2 Mode", "Cutoff2", "Filter2 Resonance" },
	}
	for i = 1, #canvasSetups do
		local s = canvasSetups[i]
		setupCanvas(s[1], s[2], s[3], s[4])
	end

	setupGlobalDragHandlers()

	-- Repaint every affected canvas whenever a filter's mode/cutoff/resonance
	-- changes from any source (not just this widget's own drag/wheel/dblclick)
	local paramGroups = {
		{ "Filter1 Mode", "Cutoff", "Filter1 Resonance" },
		{ "Filter2 Mode", "Cutoff2", "Filter2 Resonance" },
	}
	for i = 1, #paramGroups do
		local names = paramGroups[i]
		local handler = makeRepaintHandler(table.unpack(names))
		for j = 1, #names do
			params.onChange(names[j], handler)
		end
	end
end
