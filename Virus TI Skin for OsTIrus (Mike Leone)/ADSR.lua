-- ============================================================
-- "ADSR" envelope editor widget
-- Draws interactive Attack/Decay/Sustain/Time/Release envelopes
-- for the Amp envelope and up to 3 Filter envelopes, and handles
-- mouse drag / wheel / double-click editing of their parameters.
-- ============================================================

local SEGMENTS                    = 12                  -- number of line segments used to approximate each exponential curve
local INV_SEG                     = 1 / SEGMENTS
local BOX, HALF, STROKE           = 10, 5, 2   -- handle square size, half of that size, handle border thickness

local SPEED                       = { shift = 0.1, ctrl = 0.2, alt = 0.5 }   -- drag speed multipliers for modifier keys
local WHEEL                       = { default = 4, shift = 2, ctrl = 1 }     -- mouse wheel step size per modifier key
local HIT_MARGIN, DBLCLICK_MARGIN = 8, 4               -- extra pixels around a handle that still count as a hit

local HIT_ORDER                   = { "R", "T", "D", "S", "A" }          -- hit-test priority when handles overlap
local DEFAULTS                    = { A = 0, D = 127, S = 127, T = 64, R = 4 }  -- values restored on double-click
local TIME_NEUTRAL                = 64 / 127                           -- "Sustain Time" value that means no time-slope

-- Precomputed exponential curve lookup table (shared by all attack/decay/release curves)
local EXP_TABLE                   = {}
do
    local denom = 1 - math.exp(-4)
    for i = 1, SEGMENTS do
        EXP_TABLE[i] = 1 - math.exp(-4 * (i * INV_SEG)) / denom
    end
end

-- Parameter names for the Amp envelope
local AMP_PARAMS           = {
    A = "Amp Env Attack", D = "Amp Env Decay", S = "Amp Env Sustain",
    T = "Amp Env Sustain Time", R = "Amp Env Release",
}

-- Parameter names for each of the 3 selectable filter envelopes
local FILTER_SETS          = {
    { A = "Filter Env Attack", D = "Filter Env Decay", S = "Filter Env Sustain", T = "Filter Env Sustain Time", R = "Filter Env Release" },
    { A = "Envelope 3/Attack", D = "Envelope 3/Decay", S = "Envelope 3/Sustain", T = "Envelope 3/Sustain Time", R = "Envelope 3/Release" },
    { A = "Envelope 4/Attack", D = "Envelope 4/Decay", S = "Envelope 4/Sustain", T = "Envelope 4/Sustain Time", R = "Envelope 4/Release" },
}

-- ------------------------------------------------------------
-- Module state
-- ------------------------------------------------------------
local canvases             = {}          -- all registered canvas entries (Amp + Filter)
local dragging             = nil         -- { entry, point } while a handle is being dragged, otherwise nil
local dragLastX, dragLastY = 0, 0     -- last raw mouse position seen during a drag (for computing deltas)
local dragVirtX, dragVirtY = 0, 0     -- "virtual" cursor position, scaled by modifier-key drag speed
local stickyHit            = nil        -- handle currently under the mouse (or locked during drag), used by the wheel handler
local activeFilterIndex    = 1  -- which of the 3 FILTER_SETS is currently shown/edited

-- ------------------------------------------------------------
-- Small helpers
-- ------------------------------------------------------------

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
    local mx, my       = event.parameters.mouse_x, event.parameters.mouse_y
    local left, top, e = 0, 0, el
    while e do
        left = left + (tonumber(e.offset_left) or 0)
        top  = top + (tonumber(e.offset_top) or 0)
        e    = e.parent_node
    end
    return mx - left, my - top
end

-- Returns the active parameter-name set (Amp or the currently selected Filter envelope) for a canvas entry
local function getParamNames(entry)
    return entry.isFilter and FILTER_SETS[activeFilterIndex] or AMP_PARAMS
end

-- Reads and normalizes (0..1) the current A/D/S/T/R parameter values for a canvas entry
local function getNormalizedValues(names)
    return {
        clamp01(getParam(names.A, 0) / 127),
        clamp01(getParam(names.D, 127) / 127),
        clamp01(getParam(names.S, 127) / 127),
        clamp01(getParam(names.T, 64) / 127),
        clamp01(getParam(names.R, 4) / 127),
    }
end

-- ------------------------------------------------------------
-- Layout: turns normalized A/D/S/T/R values into unscaled (pre-canvas-scale)
-- coordinates for each handle/curve point
-- ------------------------------------------------------------
local function computeEnvelopePoints(entry, A, D, S, ST, R)
    local x0, yBot, yTop = entry.marginLeft, entry.marginTop + entry.usableHeight, entry.marginTop
    local ax             = x0 + A * math.max(1, entry.limitX - x0)
    local minDist        = entry.gap
    local maxDist        = math.max(minDist + 1, entry.limitX - x0)
    local dx             = ax + minDist + D * (maxDist - minDist)
    local sy             = yBot - S * entry.usableHeight

    -- Sustain-time slope: how far the "T" handle tilts up/down from the sustain line
    local slopeNorm      = 0
    if ST < TIME_NEUTRAL then
        slopeNorm = (ST - TIME_NEUTRAL) / TIME_NEUTRAL
    elseif ST > TIME_NEUTRAL then
        slopeNorm = (ST - TIME_NEUTRAL) / (1 - TIME_NEUTRAL)
    end

    local ty = sy
    if slopeNorm ~= 0 then
        ty = sy - slopeNorm * 0.25 * entry.usableHeight
        ty = math.max(yTop, math.min(yBot, ty))
    end

    local minR = entry.timeX + entry.gap
    local maxR = entry.marginLeft + entry.usableWidth - 2
    local rx   = minR + R * math.max(1, maxR - minR)

    return x0, yBot, ax, yTop, dx, sy, entry.sustainX, entry.timeX, ty, rx
end

-- ------------------------------------------------------------
-- Drawing
-- ------------------------------------------------------------
local function drawEnvelope(ctx, entry)
    local w = entry.canvas.offset_width
    if w <= 0 then return end

    local scale                                      = w / entry.canvasWidth
    local names                                      = getParamNames(entry)
    local n                                          = getNormalizedValues(names)
    local x0, yBot, ax, yTop, dx, sy, sx, tx, ty, rx = computeEnvelopePoints(entry, n[1], n[2], n[3], n[4], n[5])

    local lineW                                      = 2 * scale
    local handleSize, strokeW, halfHandle            = BOX * scale, STROKE * scale, HALF * scale

    -- Pixel-snapped handle centers so the polyline ends exactly at the square centers
    local function snapHandleCenter(cx, cy, yOverride)
        local x, y      = cx * scale, yOverride or (cy * scale)
        local outerX    = roundToPixel(x - halfHandle - strokeW)
        local outerY    = roundToPixel(y - halfHandle - strokeW)
        local outerSize = roundToPixel(handleSize + strokeW * 2)
        return outerX + outerSize * 0.5, outerY + outerSize * 0.5
    end

    local axC, ayC       = snapHandleCenter(ax, yTop)
    local dxC, dyC       = snapHandleCenter(dx, sy)
    local sxC, syC       = snapHandleCenter(sx, sy)
    local tyLine         = snapLine(ty * scale, lineW)
    local txC, tyC       = snapHandleCenter(tx, ty, tyLine)
    local rxC, ryC       = snapHandleCenter(rx, yBot)
    local x0Px           = x0 * scale
    local yBotLine       = snapLine(yBot * scale, lineW)

    local dxSpan, dySpan = (dxC - axC), (dyC - ayC)
    local rxSpan, rySpan = (rxC - txC), (ryC - tyC)

    -- Filled envelope shape
    ctx.fillStyle        = "#464C54"
    ctx:beginPath()
    ctx:moveTo(x0Px, yBotLine)
    ctx:lineTo(axC, ayC)
    for i = 1, SEGMENTS do
        local et = EXP_TABLE[i]
        ctx:lineTo(axC + dxSpan * (i * INV_SEG), ayC + dySpan * et)
    end
    ctx:lineTo(sxC, syC)
    ctx:lineTo(txC, tyC)
    for i = 1, SEGMENTS do
        local et = EXP_TABLE[i]
        ctx:lineTo(txC + rxSpan * (i * INV_SEG), tyC + rySpan * et)
    end
    ctx:lineTo(x0Px, yBotLine)
    ctx:closePath()
    ctx:fill()

    -- Outline stroke over the same shape
    ctx.strokeStyle = "#CDCFD6"
    ctx.lineWidth   = lineW
    ctx:beginPath()
    ctx:moveTo(axC, ayC)
    ctx:lineTo(x0Px, yBotLine)
    ctx:lineTo(rxC, ryC)
    for i = SEGMENTS, 1, -1 do
        local et = EXP_TABLE[i]
        ctx:lineTo(txC + rxSpan * (i * INV_SEG), tyC + rySpan * et)
    end
    ctx:lineTo(txC, tyC)
    ctx:lineTo(sxC, syC)
    ctx:lineTo(dxC, dyC)
    for i = SEGMENTS, 1, -1 do
        local et = EXP_TABLE[i]
        ctx:lineTo(axC + dxSpan * (i * INV_SEG), ayC + dySpan * et)
    end
    ctx:lineTo(axC, ayC)
    ctx:stroke()

    -- Vertical guide line at the "Time" handle position
    local txLine = snapLine(tx * scale, lineW)
    ctx:beginPath()
    ctx:moveTo(txLine, entry.marginTop * scale)
    ctx:lineTo(txLine, (entry.marginTop + entry.usableHeight) * scale)
    ctx:stroke()

    entry.handles = {}

    -- Draws one square handle and records its hit-test rectangle
    local function drawHandleAt(cxPx, cyPx, id)
        local outerX    = roundToPixel(cxPx - halfHandle - strokeW)
        local outerY    = roundToPixel(cyPx - halfHandle - strokeW)
        local outerSize = roundToPixel(handleSize + strokeW * 2)
        local innerX    = roundToPixel(cxPx - halfHandle)
        local innerY    = roundToPixel(cyPx - halfHandle)
        ctx.fillStyle   = "#CDCFD6"
        ctx:fillRect(outerX, outerY, outerSize, outerSize)
        ctx.fillStyle = "#6C6D7C"
        ctx:fillRect(innerX, innerY, roundToPixel(handleSize), roundToPixel(handleSize))
        entry.handles[id] = { x = outerX, y = outerY, s = outerSize }
    end

    drawHandleAt(axC, ayC, "A")
    drawHandleAt(sxC, syC, "S")
    drawHandleAt(dxC, dyC, "D")
    drawHandleAt(txC, tyC, "T")
    drawHandleAt(rxC, ryC, "R")
end

-- ------------------------------------------------------------
-- Hit-testing and interaction
-- ------------------------------------------------------------

-- Returns the id of the handle under (lx, ly), or nil. Checked in HIT_ORDER
-- so that overlapping handles resolve to a consistent winner.
local function hitTest(entry, lx, ly, marginPx)
    local h = entry.handles
    if not h then return nil end
    local margin = (marginPx or HIT_MARGIN) * (entry.canvas.offset_width / entry.canvasWidth)
    for i = 1, #HIT_ORDER do
        local id = HIT_ORDER[i]
        local r  = h[id]
        if r and lx >= r.x - margin and lx <= r.x + r.s + margin
                and ly >= r.y - margin and ly <= r.y + r.s + margin then
            return id
        end
    end
    return nil
end

-- Maps a raw (possibly speed-scaled/"virtual") local mouse position directly to a
-- parameter value for the given handle, and writes it via params.set
local function applyAbsoluteDrag(entry, pointId, lx, ly)
    local scale      = entry.canvas.offset_width / entry.canvasWidth
    local boxX, boxY = lx / scale, ly / scale
    local names      = getParamNames(entry)
    local x0, yTop   = entry.marginLeft, entry.marginTop
    local yBot, uh   = entry.marginTop + entry.usableHeight, entry.usableHeight

    if pointId == "A" then
        local range = math.max(1, entry.limitX - x0)
        local A     = clamp01((boxX - x0) / range)
        params.set(names.A, math.floor(A * 127 + 0.5))
    elseif pointId == "D" then
        local A       = clamp01(getParam(names.A, 0) / 127)
        local ax      = x0 + A * math.max(1, entry.limitX - x0)
        local minDist = entry.gap
        local maxDist = math.max(minDist + 1, entry.limitX - x0)
        local D       = clamp01((boxX - ax - minDist) / (maxDist - minDist))
        local S       = clamp01((yBot - boxY) / uh)
        params.set(names.D, math.floor(D * 127 + 0.5))
        params.set(names.S, math.floor(S * 127 + 0.5))
    elseif pointId == "S" then
        local S = clamp01((yBot - boxY) / uh)
        params.set(names.S, math.floor(S * 127 + 0.5))
    elseif pointId == "T" then
        local S         = clamp01(getParam(names.S, 127) / 127)
        local sy        = yBot - S * uh
        local slopeNorm = (sy - boxY) / math.max(1e-6, 0.25 * uh)
        if slopeNorm < -1 then slopeNorm = -1 elseif slopeNorm > 1 then slopeNorm = 1 end
        local ST
        if slopeNorm <= 0 then
            ST = TIME_NEUTRAL + slopeNorm * TIME_NEUTRAL
        else
            ST = TIME_NEUTRAL + slopeNorm * (1 - TIME_NEUTRAL)
        end
        params.set(names.T, math.floor(clamp01(ST) * 127 + 0.5))
    elseif pointId == "R" then
        local minR = entry.timeX + entry.gap
        local maxR = entry.marginLeft + entry.usableWidth - 2
        local R    = clamp01((boxX - minR) / math.max(1, maxR - minR))
        params.set(names.R, math.floor(R * 127 + 0.5))
    end
end

-- Double-click on a handle resets its parameter to its default value
local function onDblClick(entry, event)
    local lx, ly = getLocalMouse(event, entry.element)
    local hit    = hitTest(entry, lx, ly, DBLCLICK_MARGIN)
    if not hit then return end
    local name = getParamNames(entry)[hit]
    if not name then return end
    params.set(name, DEFAULTS[hit])
    event:StopPropagation()
end

-- Mouse wheel over a handle nudges its parameter up/down by a step size
-- that depends on the held modifier key
local function onWheel(entry, event)
    local hit = stickyHit
    if not hit then
        local lx, ly = getLocalMouse(event, entry.element)
        hit          = hitTest(entry, lx, ly)
        if hit then stickyHit = hit end
    end
    if not hit then return end

    local delta = event.parameters.wheel_delta_y or event.parameters.wheel_delta or 0
    if delta == 0 then return end

    local amount = WHEEL.default
    if keyDown(event.parameters.shift_key) then amount = WHEEL.shift
    elseif keyDown(event.parameters.ctrl_key) then amount = WHEEL.ctrl end

    local name = getParamNames(entry)[hit]
    if not name then return end
    local cur = getParam(name, 64)
    params.set(name, clamp127(cur + ((delta > 0) and -amount or amount)))
    event:StopPropagation()
end

-- ------------------------------------------------------------
-- Canvas setup
-- ------------------------------------------------------------

-- Registers a canvas element as an envelope editor.
-- cw/ch: design-time canvas size; ml/mt/mr/mb: margins inside the canvas;
-- limitX: rightmost x for the Attack handle; sustainX/timeX: fixed x positions
-- for the Sustain and Time handles; gap: minimum horizontal spacing between handles.
local function setupCanvas(id, isFilter, cw, ch, ml, mt, mr, mb, limitX, sustainX, timeX, gap)
    local el = document:GetElementById(id)
    if not el then return end

    local canvas = Element.As.Canvas(el)
    local entry  = {
        canvas      = canvas, element = el, handles = {}, isFilter = isFilter,
        canvasWidth = cw, canvasHeight = ch,
        marginLeft  = ml, marginTop = mt, marginRight = mr, marginBottom = mb,
        usableWidth = cw - ml - mr, usableHeight = ch - mt - mb,
        limitX      = limitX, sustainX = sustainX, timeX = timeX, gap = gap,
    }

    canvas:setPaintFunction(function(ctx) drawEnvelope(ctx, entry) end)

    el:AddEventListener("mousedown", function(event)
        local lx, ly = getLocalMouse(event, el)
        local hit    = hitTest(entry, lx, ly)
        if not hit then return end
        local names          = getParamNames(entry)
        dragging             = { entry = entry, point = hit }
        stickyHit            = hit
        dragLastX, dragLastY = lx, ly
        dragVirtX, dragVirtY = lx, ly
        applyAbsoluteDrag(entry, hit, lx, ly)
    end)

    el:AddEventListener("dblclick", function(event) onDblClick(entry, event) end)
    el:AddEventListener("mousescroll", function(event) onWheel(entry, event) end)

    el:AddEventListener("mousemove", function(event)
        if dragging then return end
        local lx, ly = getLocalMouse(event, el)
        stickyHit    = hitTest(entry, lx, ly)
    end)

    el:AddEventListener("mouseout", function()
        if not dragging then stickyHit = nil end
    end)

    canvases[#canvases + 1] = entry
    canvas:repaint()
end

-- Repaints every registered canvas (called on any watched parameter change)
local function repaintAll()
    for i = 1, #canvases do
        canvases[i].canvas:repaint()
    end
end

-- Subscribes repaintAll to changes of every parameter in a name set
local function subscribeParams(names)
    for _, name in pairs(names) do
        params.onChange(name, repaintAll)
    end
end

-- Switches which filter envelope (1..3) is currently displayed/edited
local function setFilterIndex(idx)
    if activeFilterIndex == idx then return end
    activeFilterIndex   = idx
    stickyHit, dragging = nil, nil
    repaintAll()
end

-- ------------------------------------------------------------
-- Entry point
-- ------------------------------------------------------------
function ADSR()
    canvases, dragging, stickyHit, activeFilterIndex = {}, nil, nil, 1

    setupCanvas("Amplifier-Envelope-Canvas", false, 466, 176, 17, 15, 15, 17, 141, 265, 325, 6)
    setupCanvas("Filter-Envelopes-Canvas", true, 432, 176, 15, 15, 15, 17, 131, 247, 301, 6)

    document:AddEventListener("mousemove", function(event)
        if not dragging then return end
        local lx, ly         = getLocalMouse(event, dragging.entry.element)
        local speedScale     = dragSpeedScale(event)
        -- Virtual cursor: Shift x0.1, Ctrl x0.2, Alt x0.5 (absolute mapping still applies)
        dragVirtX            = dragVirtX + (lx - dragLastX) * speedScale
        dragVirtY            = dragVirtY + (ly - dragLastY) * speedScale
        dragLastX, dragLastY = lx, ly
        applyAbsoluteDrag(dragging.entry, dragging.point, dragVirtX, dragVirtY)
    end)

    document:AddEventListener("mouseup", function() dragging = nil end)

    local buttons = {
        ["Button-Filter-Envelope"] = 1,
        ["Button-Envelope-3"]      = 2,
        ["Button-Envelope-4"]      = 3,
    }
    for id, idx in pairs(buttons) do
        local btn = document:GetElementById(id)
        if btn then
            btn:AddEventListener("click", function() setFilterIndex(idx) end)
        end
    end

    subscribeParams(AMP_PARAMS)
    for i = 1, #FILTER_SETS do
        subscribeParams(FILTER_SETS[i])
    end
end
