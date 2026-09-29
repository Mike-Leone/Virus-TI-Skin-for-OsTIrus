-- ============================================================
-- Oscillator waveform LCD displays
-- Three independent widgets: Lcd Wave, a drag/scroll/dblclick-editable
-- wavetable-select display (the non-LFO counterpart of the module in
-- LFO.lua — this version has no special shapes or SH staircase, just plain
-- wavetable slots); Morph Wave, a read-only display that continuously blends
-- between the selected wavetable slot, a saw, and a variable-width pulse as
-- the oscillator's Shape/Pulsewidth knobs move; and HyperSaw_Density_LCD, a
-- simple bar-count display for the HyperSaw unison voice count.
-- ============================================================

local DATA_POINTS    = Wavetable_Points or 256   -- samples per waveform, as provided by the host
local OSC_WAVE_COUNT = Wavetable_Count or 64      -- number of oscillator wavetable slots, as provided by the host

local WAVE_COLOR = "#71798C"
local FILL_STYLE = "#0D58CE3D"
local LINE_WIDTH = 2
local CENTER_GAP = 2   -- gap left around the center line where the wave crosses it, for visual clarity
local MARGIN     = 1

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function keyDown(v)
    return v == true or (type(v) == "number" and v ~= 0)
end

-- Builds a standard sawtooth waveform (used as one endpoint of the
-- morphing oscillator's saw/pulse blend, see MorphWave below)
local function buildSaw()
    local pts = {}
    for i = 0, DATA_POINTS - 1 do
        pts[i] = 1 - 2 * (i / DATA_POINTS)
    end
    return pts
end

-- Builds a pulse/square waveform with the given duty cycle (0..1)
local function buildSquare(duty)
    duty = duty or 0.5
    local pts = {}
    for i = 0, DATA_POINTS - 1 do
        pts[i] = (i / DATA_POINTS < duty) and 1 or -1
    end
    return pts
end

local SAW_WAVE = buildSaw()
local pulseCache = {}   -- memoizes buildSquare() results per duty cycle, since duty rarely changes

-- Returns the pulse wave for a given duty cycle, building and caching it on first use
local function getPulseWave(duty)
    local cached = pulseCache[duty]
    if not cached then
        cached = buildSquare(duty)
        pulseCache[duty] = cached
    end
    return cached
end

-- Fills the quad between two waveform points and the horizontal gap line at
-- gapY (either the top or bottom edge of the center gap, depending on which
-- side of center this segment sits on) — this is what gives the waveform
-- fill its "gap around the center line" look rather than a solid fill
local function fillSegment(ctx, x1, y1, x2, y2, gapY)
    ctx:beginPath()
    ctx:moveTo(x1, y1)
    ctx:lineTo(x2, y2)
    ctx:lineTo(x2, gapY)
    ctx:lineTo(x1, gapY)
    ctx:closePath()
    ctx:fill()
end

-- Converts a mouse event's page-relative coordinates into coordinates local to element `el`
local function getLocalMouse(event, el)
    local mx, my = event.parameters.mouse_x, event.parameters.mouse_y
    local left, top, e = 0, 0, el
    while e do
        left = left + (tonumber(e.offset_left) or 0)
        top  = top  + (tonumber(e.offset_top) or 0)
        e    = e.parent_node
    end
    return mx - left, my - top
end

--------------------------------------------------------------------------
-- LcdWave
-- A reusable "wave select" LCD widget: vertical drag changes the wave index
-- (speed scaled by modifier keys), scroll steps it by 1-2, and double-click
-- resets to wave 0. Multiple canvases (one per oscillator) can share this
-- module; global drag handlers are installed once and dispatch to whichever
-- entry is currently `activeEntry`.
--------------------------------------------------------------------------

local LcdWave = {}
do
    local entries = {}          -- every registered LcdWave canvas entry
    local initialized = {}      -- [elementId] -> true, guards against double-registering the same element
    local dragging, activeEntry, dragStartY, dragStartValue = false, nil, 0, 0
    local globalHandlersInstalled = false   -- guards against installing the document-level listeners more than once

    -- Installs the shared document-level mousemove/mouseup listeners that
    -- drive an in-progress drag on whichever entry is currently `activeEntry`
    local function installGlobalHandlers()
        if globalHandlersInstalled then return end
        globalHandlersInstalled = true

        document:AddEventListener("mouseup", function()
            dragging = false
            activeEntry = nil
        end)

        document:AddEventListener("mousemove", function(event)
            if not dragging or not activeEntry then return end
            local _, ly = getLocalMouse(event, activeEntry.element)
            local h = activeEntry.canvas.offset_height
            if h <= 0 then return end

            local deltaY = (dragStartY - ly) / h
            local cur = tonumber(params.get(activeEntry.param)) or 0
            local maxWave = activeEntry.waveCount - 1
            local speed = 0.5
            local p = event.parameters
            if keyDown(p.shift_key) then speed = 0.05
            elseif keyDown(p.ctrl_key) then speed = 0.1
            elseif keyDown(p.alt_key) then speed = 0.25 end

            local value = clamp(math.floor(dragStartValue + deltaY * maxWave * speed + 0.5), 0, maxWave)
            if value ~= cur then
                params.set(activeEntry.param, value)
            end
            event:StopPropagation()
        end)
    end

    -- Canvas paint callback: draws the currently selected wavetable slot's
    -- waveform plus a "W01"-style text label, scaled to the canvas's actual
    -- pixel size
    local function draw(ctx, entry)
        local canvas = entry.canvas
        local w, h = canvas.offset_width, canvas.offset_height
        if w <= 0 or h <= 0 then return end

        local scaleX, scaleY = w / 130, h / 62
        local lineScale = math.min(scaleX, scaleY)
        local maxWave = entry.waveCount - 1
        local waveIndex = clamp(math.floor(tonumber(params.get(entry.param)) or 0), 0, maxWave)

        local marginX = MARGIN * scaleX
        local marginY = MARGIN * scaleY
        local plotW = w - marginX * 2
        local plotH = h - marginY * 2
        local centerY = h * 0.5
        local halfGap = (CENTER_GAP * lineScale) * 0.5
        local lineW = LINE_WIDTH * lineScale

        local wave = OSC_WAVE_DATA[waveIndex]
        if not wave then
            ctx.fillStyle = entry.fillColor
            ctx:fillRect(0, 0, w, h)
            return
        end

        local amp = plotH * 0.5
        local topGapY, botGapY = centerY - halfGap, centerY + halfGap

        local pts = {}
        local inv = 1 / (DATA_POINTS - 1)
        for i = 0, DATA_POINTS - 1 do
            local sample = wave[i] or 0
            pts[i + 1] = { x = marginX + i * inv * plotW, y = centerY - sample * amp }
        end

        ctx.fillStyle = entry.fillColor
        for i = 1, #pts - 1 do
            local p1, p2 = pts[i], pts[i + 1]
            local side1, side2 = p1.y - centerY, p2.y - centerY
            if (side1 >= 0) == (side2 >= 0) then
                local gapY = side1 < 0 and topGapY or botGapY
                fillSegment(ctx, p1.x, p1.y, p2.x, p2.y, gapY)
            else
                local t = side1 / (side1 - side2)
                local xc = p1.x + (p2.x - p1.x) * t
                local gapY1 = side1 < 0 and topGapY or botGapY
                local gapY2 = side2 < 0 and topGapY or botGapY
                fillSegment(ctx, p1.x, p1.y, xc, centerY, gapY1)
                fillSegment(ctx, xc, centerY, p2.x, p2.y, gapY2)
            end
        end

        local function stopY(y)
            if y < centerY - 1 then return centerY - halfGap end
            if y > centerY + 1 then return centerY + halfGap end
            return y
        end

        ctx.strokeStyle = entry.lineColor
        ctx.lineWidth   = lineW
        ctx:beginPath()
        ctx:moveTo(pts[1].x, stopY(pts[1].y))
        for i = 1, #pts do
            ctx:lineTo(pts[i].x, pts[i].y)
        end
        ctx:lineTo(pts[#pts].x, stopY(pts[#pts].y))
        ctx:stroke()

        ctx.fillStyle    = entry.textColor
        ctx.font         = math.floor(8 * lineScale) .. "px sans-serif"
        ctx.textAlign    = "center"
        ctx.textBaseline = "bottom"
        ctx:fillText(string.format("W%02d", waveIndex + 1), w / 2, h - marginY)
    end

    -- Registers one wave-select LCD canvas for a plain oscillator wavetable slot
    function LcdWave.setup(elementId, paramName, lineColor, fillColor, textColor, waveCount, displayLabel)
        if initialized[elementId] then return end
        local el = document:GetElementById(elementId)
        if not el then return end
        initialized[elementId] = true

        local canvas = Element.As.Canvas(el)
        if not canvas then return end

        local entry = {
            canvas = canvas,
            element = el,
            param = paramName,
            displayLabel = displayLabel,
            lineColor = lineColor or WAVE_COLOR,
            fillColor = fillColor or FILL_STYLE,
            textColor = textColor or "#FFFFFF80",
            waveCount = waveCount or OSC_WAVE_COUNT,
        }
        entries[#entries + 1] = entry

        local maxWave = entry.waveCount - 1

        canvas:setPaintFunction(function(ctx) draw(ctx, entry) end)
        params.onChange(entry.param, function() canvas:repaint() end)

        el:AddEventListener("mousedown", function(event)
            local _, ly = getLocalMouse(event, el)
            activeEntry = entry
            dragging = true
            dragStartY = ly
            dragStartValue = tonumber(params.get(entry.param)) or 0
        end)

        el:AddEventListener("dblclick", function(event)
            params.set(entry.param, 0)
            event:StopPropagation()
        end)

        el:AddEventListener("mousescroll", function(event)
            local delta = event.parameters.wheel_delta_y or event.parameters.wheel_delta or 0
            if delta == 0 then return end
            local direction = (delta > 0) and -1 or 1
            local amount = keyDown(event.parameters.ctrl_key) and 1 or 2
            local cur = tonumber(params.get(entry.param)) or 0
            local next = clamp(math.floor(cur + direction * amount + 0.5), 0, maxWave)
            if next ~= cur then
                params.set(entry.param, next)
            end
            event:StopPropagation()
        end)

        canvas:repaint()
    end

    -- Installs the shared global drag handlers; safe to call once per
    -- oscillator registration since installGlobalHandlers() no-ops after the first call
    function LcdWave.initAll()
        installGlobalHandlers()
    end
end

--------------------------------------------------------------------------
-- Morphing oscillator
-- A read-only display (no drag/scroll/click editing — Shape and Pulsewidth
-- are edited by their own knobs elsewhere) that continuously blends the
-- selected wavetable slot toward a sawtooth as Shape goes 0->64, then from
-- that sawtooth toward a pulse of the current Pulsewidth as Shape goes
-- 64->127. This gives one knob a "wave shaping" sweep across three
-- waveform families instead of a hard switch between them.
--------------------------------------------------------------------------

local MorphWave = {}
do
    local SHAPE_MAX, SHAPE_MID = 127, 64   -- Shape's full range and its midpoint (where the blend pivots from base-wave/saw to saw/pulse)
    local PULSEWIDTH_MAX = 127
    local CANVAS_W, CANVAS_H = 130, 62

    local function getParam(name, fallback)
        local v = params.get(name)
        return v == nil and fallback or v
    end

    -- Blends sample i of the base wave toward saw (Shape 0-64), or saw
    -- toward the pulse wave (Shape 64-127), depending on which half of
    -- Shape's range the current value falls in
    local function morphedPoint(i, baseWave, shape, pulseWave)
        if shape <= SHAPE_MID then
            return lerp(baseWave[i], SAW_WAVE[i], shape / SHAPE_MID)
        end
        return lerp(SAW_WAVE[i], pulseWave[i], (shape - SHAPE_MID) / (SHAPE_MAX - SHAPE_MID))
    end

    -- How much the pulse wave contributes to the blend (0 below the
    -- midpoint, ramping to 1 as Shape approaches its max) — used to morph
    -- the pulse edge's rendered position too, not just its sample values
    local function pulseBlend(shape)
        if shape <= SHAPE_MID then return 0 end
        return (shape - SHAPE_MID) / (SHAPE_MAX - SHAPE_MID)
    end

    local ptsBuf, strokeBuf = {}, {}   -- reused frame-to-frame to avoid allocating new point tables every repaint

    -- Canvas paint callback: computes the morphed point set for the current
    -- Shape/Pulsewidth, then fills and strokes it exactly like the plain
    -- LcdWave display does. No text label is drawn (this display has no
    -- single "wave name" to show, since it's continuously blending).
    local function draw(ctx, entry)
        local el = entry.canvasElement
        local w, h = el.offset_width, el.offset_height
        if w <= 0 or h <= 0 then return end

        local scaleX, scaleY = w / CANVAS_W, h / CANVAS_H
        local lineScale = math.min(scaleX, scaleY)

        local waveIndex = clamp(math.floor(getParam(entry.waveSelectParam, 0)), 0, OSC_WAVE_COUNT - 1)
        local shape = clamp(getParam(entry.shapeParam, 0), 0, SHAPE_MAX)
        local duty = 0.5 + 0.5 * (clamp(getParam(entry.pulsewidthParam, 0), 0, PULSEWIDTH_MAX) / PULSEWIDTH_MAX)

        local baseWave = OSC_WAVE_DATA[waveIndex]
        if not baseWave then return end

        local pulseWave = shape > SHAPE_MID and getPulseWave(duty) or nil

        local margin = MARGIN * scaleY
        local marginX = MARGIN * scaleX
        local plotW = w - marginX * 2
        local plotH = h - margin * 2
        local halfGap = (CENTER_GAP * lineScale) * 0.5
        local lineW = LINE_WIDTH * lineScale
        local centerY = margin + plotH * 0.5
        local amp = plotH * 0.5

        local inv = 1 / (DATA_POINTS - 1)
        for i = 0, DATA_POINTS - 1 do
            local sample = morphedPoint(i, baseWave, shape, pulseWave)
            local p = ptsBuf[i + 1] or {}
            p.x = marginX + i * inv * plotW
            p.y = centerY - sample * amp
            ptsBuf[i + 1] = p
        end

        -- Once the pulse edge starts blending in (Shape > midpoint), snap the
        -- two samples nearest the pulse's duty-cycle transition point onto a
        -- crisp vertical edge instead of leaving them on the smoother
        -- interpolated curve — this is what makes the morph read as
        -- "gaining a pulse edge" rather than just getting noisier
        if pulseWave then
            local blend = pulseBlend(shape)
            local edgeX = math.floor(marginX + duty * plotW) + 0.5
            local edgeSampleIdx = duty * (DATA_POINTS - 1)
            local i0 = math.floor(edgeSampleIdx)
            if i0 >= 0 and i0 < DATA_POINTS - 1 then
                local highY = centerY - lerp(SAW_WAVE[i0], 1, blend) * amp
                local lowY  = centerY - lerp(SAW_WAVE[i0 + 1], -1, blend) * amp
                ptsBuf[i0 + 1].x = edgeX
                ptsBuf[i0 + 1].y = highY
                ptsBuf[i0 + 2].x = edgeX
                ptsBuf[i0 + 2].y = lowY
            end
        end

        ctx.fillStyle = FILL_STYLE
        local topGapY, botGapY = centerY - halfGap, centerY + halfGap
        for i = 1, DATA_POINTS - 1 do
            local p1, p2 = ptsBuf[i], ptsBuf[i + 1]
            local side1, side2 = p1.y - centerY, p2.y - centerY
            if (side1 >= 0) == (side2 >= 0) then
                local gapY = side1 < 0 and topGapY or botGapY
                ctx:beginPath()
                ctx:moveTo(p1.x, p1.y)
                ctx:lineTo(p2.x, p2.y)
                ctx:lineTo(p2.x, gapY)
                ctx:lineTo(p1.x, gapY)
                ctx:closePath()
                ctx:fill()
            else
                local t = side1 / (side1 - side2)
                local xc = p1.x + (p2.x - p1.x) * t
                local gapY1 = side1 < 0 and topGapY or botGapY
                local gapY2 = side2 < 0 and topGapY or botGapY

                ctx:beginPath()
                ctx:moveTo(p1.x, p1.y)
                ctx:lineTo(xc, centerY)
                ctx:lineTo(p1.x, gapY1)
                ctx:closePath()
                ctx:fill()

                ctx:beginPath()
                ctx:moveTo(xc, centerY)
                ctx:lineTo(p2.x, p2.y)
                ctx:lineTo(p2.x, gapY2)
                ctx:closePath()
                ctx:fill()
            end
        end

        -- Reduces the stroke path to only the points where the line actually
        -- bends (drops any point collinear with its neighbors, via the cross
        -- product test), since DATA_POINTS is large and most consecutive
        -- samples along a straight segment (e.g. the flat top of a pulse)
        -- don't need their own line-to call
        local strokeCount = 1
        strokeBuf[1] = ptsBuf[1]
        for i = 2, DATA_POINTS - 1 do
            local a, b, c = strokeBuf[strokeCount], ptsBuf[i], ptsBuf[i + 1]
            local cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            if math.abs(cross) > 1e-6 then
                strokeCount = strokeCount + 1
                strokeBuf[strokeCount] = b
            end
        end
        strokeCount = strokeCount + 1
        strokeBuf[strokeCount] = ptsBuf[DATA_POINTS]

        local function stopY(y)
            if y < centerY - 1 then return centerY - halfGap end
            if y > centerY + 1 then return centerY + halfGap end
            return y
        end

        ctx.strokeStyle = entry.color or WAVE_COLOR
        ctx.lineWidth   = lineW
        ctx:beginPath()
        ctx:moveTo(strokeBuf[1].x, stopY(strokeBuf[1].y))
        for i = 1, strokeCount do
            ctx:lineTo(strokeBuf[i].x, strokeBuf[i].y)
        end
        ctx:lineTo(strokeBuf[strokeCount].x, stopY(strokeBuf[strokeCount].y))
        ctx:stroke()
    end

    local initialized = {}   -- [canvasId] -> true, guards against double-registering the same element

    -- Registers one read-only morph display, repainting whenever any of its
    -- 3 driving parameters (wave select, shape, pulsewidth) changes
    function MorphWave.setup(canvasId, waveSelectParam, shapeParam, pulsewidthParam, color)
        if initialized[canvasId] then return end
        local el = document:GetElementById(canvasId)
        if not el then return end
        initialized[canvasId] = true

        local canvas = Element.As.Canvas(el)
        if not canvas then return end

        local entry = {
            canvasElement = el,
            canvas = canvas,
            waveSelectParam = waveSelectParam,
            shapeParam = shapeParam,
            pulsewidthParam = pulsewidthParam,
            color = color,
        }

        canvas:setPaintFunction(function(ctx) draw(ctx, entry) end)
        local function repaint() canvas:repaint() end
        params.onChange(waveSelectParam, repaint)
        params.onChange(shapeParam, repaint)
        params.onChange(pulsewidthParam, repaint)
        canvas:repaint()
    end
end

--------------------------------------------------------------------------
-- HyperSaw Density display
-- A read-only bar-graph showing how many unison voices the HyperSaw's
-- Density parameter currently produces (1-9 bars, with the newest bar
-- growing in smoothly as Density increases rather than popping in at full
-- height) and how far apart they're spread, driven by Detune.
--------------------------------------------------------------------------

local HyperSaw_Density_LCD = {}
do
    local CANVAS_W, CANVAS_H = 122, 78
    local MAX_BARS = 9
    local BAR_COLOR = "#696E76"

    -- Maps raw Density (0-127) to a fractional voice count (1.0-9.0). The
    -- curve isn't linear — it eases each new bar in gradually and holds
    -- briefly at each integer count — so this is a baked lookup table
    -- rather than a formula.
    local DENSITY_CURVE = {
        [0] = 1.0, [1] = 1.1, [2] = 1.1, [3] = 1.1, [4] = 1.2, [5] = 1.2, [6] = 1.2, [7] = 1.3,
        [8] = 1.3, [9] = 1.3, [10] = 1.4, [11] = 1.4, [12] = 1.4, [13] = 1.5, [14] = 1.5, [15] = 1.5,
        [16] = 1.6, [17] = 1.6, [18] = 1.6, [19] = 1.7, [20] = 1.7, [21] = 1.7, [22] = 1.7, [23] = 1.8,
        [24] = 1.8, [25] = 1.8, [26] = 1.8, [27] = 1.9, [28] = 1.9, [29] = 1.9, [30] = 1.9, [31] = 2.0,
        [32] = 2.0, [33] = 2.1, [34] = 2.1, [35] = 2.1, [36] = 2.2, [37] = 2.2, [38] = 2.2, [39] = 2.3,
        [40] = 2.3, [41] = 2.3, [42] = 2.4, [43] = 2.4, [44] = 2.4, [45] = 2.5, [46] = 2.5, [47] = 2.5,
        [48] = 2.6, [49] = 2.6, [50] = 2.6, [51] = 2.7, [52] = 2.7, [53] = 2.7, [54] = 2.7, [55] = 2.8,
        [56] = 2.8, [57] = 2.8, [58] = 2.8, [59] = 2.9, [60] = 2.9, [61] = 2.9, [62] = 2.9, [63] = 3.0,
        [64] = 3.0, [65] = 3.1, [66] = 3.2, [67] = 3.3, [68] = 3.4, [69] = 3.5, [70] = 3.5, [71] = 3.6,
        [72] = 3.6, [73] = 3.7, [74] = 3.7, [75] = 3.8, [76] = 3.8, [77] = 3.9, [78] = 3.9, [79] = 4.0,
        [80] = 4.0, [81] = 4.1, [82] = 4.2, [83] = 4.3, [84] = 4.4, [85] = 4.5, [86] = 4.5, [87] = 4.6,
        [88] = 4.6, [89] = 4.7, [90] = 4.7, [91] = 4.8, [92] = 4.8, [93] = 4.9, [94] = 4.9, [95] = 5.0,
        [96] = 5.0, [97] = 5.1, [98] = 5.3, [99] = 5.5, [100] = 5.7, [101] = 5.8, [102] = 5.9, [103] = 6.0,
        [104] = 6.0, [105] = 6.1, [106] = 6.3, [107] = 6.5, [108] = 6.7, [109] = 6.8, [110] = 6.9, [111] = 7.0,
        [112] = 7.0, [113] = 7.1, [114] = 7.3, [115] = 7.5, [116] = 7.7, [117] = 7.8, [118] = 7.9, [119] = 8.0,
        [120] = 8.0, [121] = 8.1, [122] = 8.3, [123] = 8.5, [124] = 8.7, [125] = 8.8, [126] = 8.9, [127] = 9.0,
    }

    -- Returns how many "step" units a bar sits from the center bar, in a
    -- zigzag order: bar 1 is centered (offset 0), bar 2 is one step right,
    -- bar 3 one step left, bar 4 two steps right, and so on — so bars grow
    -- outward symmetrically from the center as Density increases
    local function barOffsetUnits(barIndex)
        if barIndex == 1 then return 0 end
        local pairIndex = math.floor(barIndex / 2)
        local sign = (barIndex % 2 == 0) and 1 or -1
        return sign * pairIndex
    end

    -- Snaps a vertical bar's x position for a crisp stroke: whole pixel for
    -- even line widths, half-pixel offset for odd ones (same 1px-crispness
    -- logic as the staircase/waveform strokes elsewhere in this codebase)
    local function snapX(v, lineW)
        local lw = math.floor(lineW + 0.5)
        if lw % 2 == 0 then
            return math.floor(v + 0.5)
        else
            return math.floor(v) + 0.5
        end
    end

    -- Canvas paint callback: draws the center bar, then each additional
    -- full bar out to the current (eased) Density, then a partial-height
    -- bar for the fractional remainder if Density is still growing toward
    -- the next bar
    local function draw(ctx, entry)
        local el = entry.canvasElement
        local w, h = el.offset_width, el.offset_height
        if w <= 0 or h <= 0 then return end

        local scaleX, scaleY = w / CANVAS_W, h / CANVAS_H
        local lineScale = math.min(scaleX, scaleY)
        local lineW = LINE_WIDTH * lineScale

        local densityRaw = clamp(math.floor((params.get(entry.densityParam) or 0) + 0.5), 0, 127)
        local density = DENSITY_CURVE[densityRaw] or 1.0

        local detune = clamp(params.get(entry.detuneParam) or 0, 0, entry.detuneMax)
        local detuneT = entry.detuneMax > 0 and (detune / entry.detuneMax) or 0
        local step = lerp(entry.detuneMinStep, entry.detuneMaxStep, detuneT)

        local pos = density
        local fullBars = math.floor(pos + 1e-9)
        local growFrac = pos - fullBars

        if fullBars >= MAX_BARS then
            fullBars = MAX_BARS
            growFrac = 0
        end

        local centerX = w * 0.5
        local marginY = MARGIN * scaleY
        local yOffset = (math.floor(lineW + 0.5) % 2 == 0) and 1 or 0
        local topY = math.floor(marginY + 0.5) + yOffset
        local botY = math.floor(h - marginY + 0.5) + yOffset

        ctx.strokeStyle = entry.color or BAR_COLOR
        ctx.lineWidth = lineW

        local centerX_px = snapX(centerX, lineW)
        ctx:beginPath()
        ctx:moveTo(centerX_px, topY)
        ctx:lineTo(centerX_px, botY)
        ctx:stroke()

        for barIndex = 2, fullBars do
            local offset = barOffsetUnits(barIndex)
            local x = snapX(centerX + offset * step * scaleX, lineW)
            ctx:beginPath()
            ctx:moveTo(x, topY)
            ctx:lineTo(x, botY)
            ctx:stroke()
        end

        if growFrac > 0 and fullBars < MAX_BARS then
            local nextBarIndex = fullBars + 1
            local offset = barOffsetUnits(nextBarIndex)
            local x = snapX(centerX + offset * step * scaleX, lineW)
            local growTopY = math.floor(botY - (botY - topY) * growFrac + 0.5)
            ctx:beginPath()
            ctx:moveTo(x, growTopY)
            ctx:lineTo(x, botY)
            ctx:stroke()
        end
    end

    local initialized = {}   -- [canvasId] -> true, guards against double-registering the same element

    -- Registers one read-only HyperSaw density display, repainting whenever
    -- Density or Detune changes
    function HyperSaw_Density_LCD.setup(canvasId, densityParam, detuneParam, detuneMax, color)
        if initialized[canvasId] then return end
        local el = document:GetElementById(canvasId)
        if not el then return end
        initialized[canvasId] = true

        local canvas = Element.As.Canvas(el)
        if not canvas then return end

        local entry = {
            canvasElement = el,
            canvas = canvas,
            densityParam = densityParam,
            detuneParam = detuneParam,
            detuneMax = detuneMax or 127,
            detuneMinStep = 4,
            detuneMaxStep = 14,
            color = color,
        }

        canvas:setPaintFunction(function(ctx) draw(ctx, entry) end)
        params.onChange(densityParam, function() canvas:repaint() end)
        params.onChange(detuneParam, function() canvas:repaint() end)
        canvas:repaint()
    end
end

--------------------------------------------------------------------------
-- Public entry points
-- All global — bound to widget lifecycle events by name, do not rename.
--------------------------------------------------------------------------

function Osc_1_LCD_Waves()
    LcdWave.setup("Osc-1-LCD-Waves", "Osc1 Wave Select", "#71798C", "#0D58CE3D", "#FFFFFF80", OSC_WAVE_COUNT, "Oscillator 1 Wave Select")
    LcdWave.initAll()
end

function Osc_2_LCD_Waves()
    LcdWave.setup("Osc-2-LCD-Waves", "Osc2 Wave Select", "#71798C", "#0D58CE3D", "#FFFFFF80", OSC_WAVE_COUNT, "Oscillator 2 Wave Select")
    LcdWave.initAll()
end

function Osc_1_Knob_LCD_Waves()
    MorphWave.setup("Osc-1-Knob-LCD-Waves", "Osc1 Wave Select", "Osc1 Shape", "Osc1 Pulsewidth", WAVE_COLOR)
end

function Osc_2_Knob_LCD_Waves()
    MorphWave.setup("Osc-2-Knob-LCD-Waves", "Osc2 Wave Select", "Osc2 Shape", "Osc2 Pulsewidth", WAVE_COLOR)
end

function HyperSaw_1_Density_LCD()
    HyperSaw_Density_LCD.setup("HyperSaw-1-Density-LCD", "Osc1 HyperSaw/Density", "Osc1 HyperSaw/DetuneSpread", 127, "#696E76")
end

function HyperSaw_2_Density_LCD()
    HyperSaw_Density_LCD.setup("HyperSaw-2-Density-LCD", "Osc2 HyperSaw/Density", "Osc2 HyperSaw/DetuneSpread", 127, "#696E76")
end

function Oscillator()
    Osc_1_LCD_Waves()
    Osc_2_LCD_Waves()
    Osc_1_Knob_LCD_Waves()
    Osc_2_Knob_LCD_Waves()
    HyperSaw_1_Density_LCD()
    HyperSaw_2_Density_LCD()
end
