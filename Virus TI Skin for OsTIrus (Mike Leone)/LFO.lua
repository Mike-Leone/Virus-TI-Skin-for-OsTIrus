-- ============================================================
-- "LCD LFO waveform" + knob "Clock Divider" controls
-- Two independent pieces: Lcd Wave, a drag/scroll/dblclick-editable LFO/OSC
-- waveform-select display (shared with a subset also used by Oscillator.lua,
-- extended here with LFO-only shapes: "SH" and a "SG" wave),
-- and a per-LFO "Button Clock-Switch" + "Rate/Knob Clock Divider" visibility toggle driven
-- by each LFO's Clock parameter.
-- ============================================================

local DATA_POINTS    = Wavetable_Points or 256   -- samples per waveform, as provided by the host
local OSC_WAVE_COUNT = Wavetable_Count or 64      -- number of oscillator wavetable slots, as provided by the host
local LFO_WAVE_COUNT = 68                          -- 6 special LFO shapes (Sin/Tri/Saw/Sqr/SH/SG) + 62 wavetable slots

local WAVE_COLOR  = "#71798C"
local FILL_STYLE  = "#0D58CE3D"
local LINE_WIDTH  = 2
local CENTER_GAP  = 2   -- gap left around the center line where the wave crosses it, for visual clarity
local MARGIN      = 1

local RATE_CLOCK_FRAMES = 128                    -- number of sprite frames in the clock-divider knob's image strip
local RATE_CLOCK_PREFIX = "knob-big-mini_"       -- filename prefix for the clock-divider knob's sprite frames
local DRAG_RANGE_PX     = 200                    -- pixel distance for a full-range drag of the clock-divider knob
local SPEED = { shift = 0.1, ctrl = 0.2, alt = 0.5 }   -- drag speed multipliers for modifier keys

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function keyDown(v)
    return v == true or (type(v) == "number" and v ~= 0)
end

-- Rounds a coordinate to the nearest whole pixel (for crisp canvas rendering)
local function pixelSnap(v)
    return math.floor(v + 0.5)
end

-- Returns the drag-speed multiplier for whichever modifier key is held
local function getSpeedScale(event)
    local p = event.parameters
    if keyDown(p.shift_key) then return SPEED.shift end
    if keyDown(p.ctrl_key) then return SPEED.ctrl end
    if keyDown(p.alt_key) then return SPEED.alt end
    return 1.0
end

-- Builds a standard sawtooth waveform (used both as an LFO shape and as one
-- endpoint of the oscillator's saw/pulse morph elsewhere in the codebase)
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

-- Sample & Hold: 13 held random-looking step values, rendered as a staircase
-- (see drawStaircase) rather than the usual smooth waveform
local SH_STEPS = {
    0.96552, -0.55172, 0.13793, -0.96552, 0.75862, -0.27586, 0.55172,
    -0.62069, -0.20690, -0.82759, 0.62069, -0.13793, 0.89655,
}

-- "SG" (grain-style) LFO shape: a fixed table of DATA_POINTS sample values,
-- authored/captured elsewhere and baked in here as a lookup table
local SG_WAVE = {
    [0] = -0.01754, [1] = 0.07835, [2] = 0.17424, [3] = 0.27013, [4] = 0.36602, [5] = 0.46191, [6] = 0.55780, [7] = 0.65369,
    [8] = 0.74958, [9] = 0.84548, [10] = 0.94137, [11] = 0.90746, [12] = 0.83131, [13] = 0.75516, [14] = 0.67901, [15] = 0.60286,
    [16] = 0.52671, [17] = 0.45057, [18] = 0.37442, [19] = 0.29827, [20] = 0.22212, [21] = 0.14597, [22] = 0.06982, [23] = -0.00633,
    [24] = -0.08248, [25] = -0.15863, [26] = -0.23478, [27] = -0.31093, [28] = -0.38708, [29] = -0.46322, [30] = -0.49329, [31] = -0.45476,
    [32] = -0.41623, [33] = -0.37771, [34] = -0.33918, [35] = -0.30065, [36] = -0.26212, [37] = -0.22360, [38] = -0.18507, [39] = -0.14654,
    [40] = -0.10802, [41] = -0.06949, [42] = -0.03096, [43] = 0.00757, [44] = 0.04609, [45] = 0.08462, [46] = 0.12315, [47] = 0.16168,
    [48] = 0.20020, [49] = 0.23873, [50] = 0.27726, [51] = 0.22535, [52] = 0.16456, [53] = 0.10377, [54] = 0.04298, [55] = -0.01781,
    [56] = -0.07859, [57] = -0.13938, [58] = -0.20017, [59] = -0.26096, [60] = -0.32175, [61] = -0.38254, [62] = -0.44332, [63] = -0.50411,
    [64] = -0.56490, [65] = -0.62569, [66] = -0.68648, [67] = -0.74727, [68] = -0.80805, [69] = -0.86884, [70] = -0.92963, [71] = -0.92899,
    [72] = -0.84337, [73] = -0.75775, [74] = -0.67214, [75] = -0.58652, [76] = -0.50090, [77] = -0.41529, [78] = -0.32967, [79] = -0.24405,
    [80] = -0.15843, [81] = -0.07282, [82] = 0.01280, [83] = 0.09842, [84] = 0.18404, [85] = 0.26965, [86] = 0.35527, [87] = 0.44089,
    [88] = 0.52650, [89] = 0.61212, [90] = 0.69774, [91] = 0.78336, [92] = 0.74118, [93] = 0.68916, [94] = 0.63715, [95] = 0.58514,
    [96] = 0.53313, [97] = 0.48111, [98] = 0.42910, [99] = 0.37709, [100] = 0.32508, [101] = 0.27306, [102] = 0.22105, [103] = 0.16904,
    [104] = 0.11703, [105] = 0.06501, [106] = 0.01300, [107] = -0.03901, [108] = -0.09103, [109] = -0.14304, [110] = -0.13725, [111] = -0.10836,
    [112] = -0.07946, [113] = -0.05057, [114] = -0.02167, [115] = 0.00723, [116] = 0.03612, [117] = 0.06502, [118] = 0.09391, [119] = 0.12281,
    [120] = 0.15170, [121] = 0.18060, [122] = 0.20950, [123] = 0.23839, [124] = 0.26729, [125] = 0.29618, [126] = 0.32508, [127] = 0.35397,
    [128] = 0.34951, [129] = 0.31168, [130] = 0.27385, [131] = 0.23603, [132] = 0.19820, [133] = 0.16037, [134] = 0.12254, [135] = 0.08472,
    [136] = 0.04689, [137] = 0.00906, [138] = -0.02877, [139] = -0.06659, [140] = -0.10442, [141] = -0.14225, [142] = -0.18007, [143] = -0.21790,
    [144] = -0.25573, [145] = -0.29356, [146] = -0.33138, [147] = -0.36921, [148] = -0.40704, [149] = -0.44487, [150] = -0.48269, [151] = -0.52052,
    [152] = -0.55835, [153] = -0.56930, [154] = -0.54811, [155] = -0.52692, [156] = -0.50573, [157] = -0.48454, [158] = -0.46335, [159] = -0.44216,
    [160] = -0.42097, [161] = -0.39978, [162] = -0.37859, [163] = -0.35740, [164] = -0.33621, [165] = -0.31502, [166] = -0.29383, [167] = -0.27264,
    [168] = -0.25145, [169] = -0.23025, [170] = -0.20906, [171] = -0.20041, [172] = -0.23123, [173] = -0.26206, [174] = -0.29288, [175] = -0.32370,
    [176] = -0.35452, [177] = -0.38535, [178] = -0.41617, [179] = -0.44699, [180] = -0.47781, [181] = -0.50863, [182] = -0.53946, [183] = -0.57028,
    [184] = -0.60110, [185] = -0.63192, [186] = -0.66274, [187] = -0.69357, [188] = -0.72439, [189] = -0.75521, [190] = -0.78603, [191] = -0.81686,
    [192] = -0.77062, [193] = -0.69871, [194] = -0.62679, [195] = -0.55488, [196] = -0.48296, [197] = -0.41104, [198] = -0.33913, [199] = -0.26721,
    [200] = -0.19529, [201] = -0.12338, [202] = -0.05146, [203] = 0.02046, [204] = 0.09237, [205] = 0.16429, [206] = 0.23620, [207] = 0.30812,
    [208] = 0.38004, [209] = 0.45195, [210] = 0.52387, [211] = 0.59579, [212] = 0.63867, [213] = 0.59822, [214] = 0.55776, [215] = 0.51731,
    [216] = 0.47686, [217] = 0.43640, [218] = 0.39595, [219] = 0.35550, [220] = 0.31504, [221] = 0.27459, [222] = 0.23414, [223] = 0.19368,
    [224] = 0.15323, [225] = 0.11278, [226] = 0.07232, [227] = 0.03187, [228] = -0.00858, [229] = -0.04904, [230] = -0.08511, [231] = -0.02552,
    [232] = 0.03408, [233] = 0.09367, [234] = 0.15326, [235] = 0.21285, [236] = 0.27245, [237] = 0.33204, [238] = 0.39163, [239] = 0.45122,
    [240] = 0.51081, [241] = 0.57041, [242] = 0.63000, [243] = 0.68959, [244] = 0.74918, [245] = 0.80878, [246] = 0.86837, [247] = 0.92796,
    [248] = 0.81465, [249] = 0.69577, [250] = 0.57688, [251] = 0.45800, [252] = 0.33911, [253] = 0.22023, [254] = 0.10134, [255] = -0.01754,
}

local LFO_SPECIAL_NAMES = { [0] = "Sin", [1] = "Tri", [2] = "Saw", [3] = "Sqr", [4] = "SH", [5] = "SG" }
local specialWaveCache = {}   -- memoizes getSpecialWave() results, since the underlying wave tables never change

-- Returns the waveform data for one of the 6 special LFO shapes (indices
-- 0-5): Sin/Tri come from the oscillator's own wavetable, Saw/Sqr are built
-- locally, SG is the fixed table above, and SH has no continuous waveform
-- (it's drawn separately by drawStaircase, so returns nothing here)
local function getSpecialWave(index)
    local cached = specialWaveCache[index]
    if cached then return cached end
    local name = LFO_SPECIAL_NAMES[index]
    local wave
    if name == "Sin" then wave = OSC_WAVE_DATA[0]
    elseif name == "Tri" then wave = OSC_WAVE_DATA[1]
    elseif name == "Saw" then wave = SAW_WAVE
    elseif name == "Sqr" then wave = getPulseWave(0.5)
    elseif name == "SG" then wave = SG_WAVE
    end
    if wave then specialWaveCache[index] = wave end
    return wave
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

-- Draws the Sample & Hold shape as a staircase (flat horizontal segments
-- connecting each held step value), rather than the smooth interpolated
-- curve used for every other waveform. Pixel-snaps each step's line
-- ("s"-prefixed locals) separately from the fill geometry, since crisp
-- 1px-wide strokes need different rounding than filled regions do.
local function drawStaircase(ctx, w, h, centerY, halfGap, lineW, lineColor, fillColor)
    local amp = h * 0.5
    local n = #SH_STEPS
    local centerYs = pixelSnap(centerY)
    local topGapY  = pixelSnap(centerY - halfGap)
    local botGapY  = pixelSnap(centerY + halfGap)

    -- X positions of the n+1 step boundaries, evenly spaced across the width
    local xs = {}
    for i = 0, n do
        xs[i + 1] = pixelSnap((i / n) * w)
    end

    -- Y position (held value) of each of the n steps
    local ys = {}
    for i = 1, n do
        ys[i] = pixelSnap(centerY - SH_STEPS[i] * amp)
    end

    ctx.fillStyle = fillColor
    for i = 1, n do
        local gapY = (ys[i] < centerYs) and topGapY or botGapY
        fillSegment(ctx, xs[i], ys[i], xs[i + 1], ys[i], gapY)
    end

    -- The stroke needs its own pixel-snapped copies of every coordinate,
    -- offset by half a pixel when the line width is odd, so a 1px stroke
    -- lands crisply on a pixel row/column instead of straddling two
    local roundedLineW = math.max(1, math.floor(lineW + 0.5))
    local strokeOffset = (roundedLineW % 2 == 1) and 0.5 or 0

    local sxs = {}
    for i = 1, n + 1 do sxs[i] = xs[i] + strokeOffset end
    local sys = {}
    for i = 1, n do sys[i] = ys[i] + strokeOffset end
    local sCenterY = centerYs + strokeOffset
    local sTopGapY = topGapY + strokeOffset
    local sBotGapY = botGapY + strokeOffset

    -- Clamp the first/last stroke x so the line's edge doesn't get clipped
    -- by the canvas boundary at large stroke widths
    local halfLineW = lineW * 0.5
    sxs[1]     = math.max(sxs[1], halfLineW)
    sxs[n + 1] = math.min(sxs[n + 1], w - halfLineW)

    ctx.strokeStyle = lineColor
    ctx.lineWidth   = lineW
    ctx:beginPath()
    -- Where a step's line enters/exits the canvas edge, route it through the
    -- center-gap edge instead of the step's own value, matching how the
    -- smooth-waveform stroke (see draw()) enters/exits at the gap
    local function stopY(y)
        if y < sCenterY - 1 then return sTopGapY end
        if y > sCenterY + 1 then return sBotGapY end
        return y
    end
    ctx:moveTo(sxs[1], stopY(sys[1]))
    ctx:lineTo(sxs[1], sys[1])
    for i = 1, n do
        ctx:lineTo(sxs[i + 1], sys[i])
        if i < n then
            ctx:lineTo(sxs[i + 1], sys[i + 1])
        end
    end
    ctx:lineTo(sxs[n + 1], stopY(sys[n]))
    ctx:stroke()
end

-- Canvas paint callback shared by every LcdWave entry (LFO or oscillator).
-- Draws the current wave (or the SH staircase, for LFOs on that shape) plus
-- a small text label naming it, scaled to the canvas's actual pixel size.
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

    -- SH (index 4) has no continuous waveform to plot — draw its staircase and bail early
    if entry.isLFO and waveIndex == 4 then
        drawStaircase(ctx, w, h, centerY, halfGap, lineW, entry.lineColor, entry.fillColor)
        ctx.fillStyle    = entry.textColor
        ctx.font         = math.floor(8 * lineScale) .. "px sans-serif"
        ctx.textAlign    = "center"
        ctx.textBaseline = "bottom"
        ctx:fillText("SH", w / 2, h - marginY)
        return
    end

    -- LFOs offset into the oscillator wavetable by 4, since indices 0-5 are
    -- reserved for the special shapes (Sin/Tri/Saw/Sqr/SH/SG) rather than
    -- wavetable slots
    local wave
    if entry.isLFO then
        wave = waveIndex < 6 and getSpecialWave(waveIndex) or OSC_WAVE_DATA[waveIndex - 4]
    else
        wave = OSC_WAVE_DATA[waveIndex]
    end

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
    local label
    if entry.isLFO then
        label = waveIndex < 6 and (LFO_SPECIAL_NAMES[waveIndex] or "?") or string.format("W%02d", waveIndex - 3)
    else
        label = string.format("W%02d", waveIndex + 1)
    end
    ctx:fillText(label, w / 2, h - marginY)
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
-- resets to wave 0. Multiple canvases (one per LFO/oscillator) can share
-- this module; global drag handlers are installed once and dispatch to
-- whichever entry is currently `activeEntry`.
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

    -- Registers one wave-select LCD canvas. `isLFO` selects between the
    -- LFO-flavored draw() branch (special shapes + SH staircase) and the
    -- plain oscillator wavetable display.
    function LcdWave.setup(elementId, paramName, lineColor, fillColor, textColor, waveCount, isLFO, displayLabel)
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
            isLFO = isLFO or false,
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

    -- Installs the shared global drag handlers; safe to call once per LFO/osc
    -- registration group since installGlobalHandlers() no-ops after the first call
    function LcdWave.initAll()
        installGlobalHandlers()
    end
end

--------------------------------------------------------------------------
-- Clock Divider
-- Each LFO has a "Clock" parameter: 0 means free-running at its Rate
-- knob's speed, any nonzero value selects a tempo-synced clock division
-- instead. This section drives the divider knob's sprite, the switch that
-- toggles between Rate and Clock-Divider, and their drag/scroll interaction.
--------------------------------------------------------------------------

local lfoStates = {
    [1] = { active = false, lastValue = 1, param = "Lfo1 Clock" },
    [2] = { active = false, lastValue = 1, param = "Lfo2 Clock" },
    [3] = { active = false, lastValue = 1, param = "Lfo3 Clock" },
}

local clockDrag = nil   -- { i, startValue, accum, lastX, lastY } while a divider knob is being dragged, else nil

-- Returns the valid value range for a Clock parameter: 1 (fastest division)
-- up to the host-reported max (falling back to 21 if unavailable)
local function getParamRange(param)
    local info = params.getInfo(param)
    return 1, (info and info.max or 21)
end

-- Builds the element id for a given LFO index and suffix, e.g. "LFO-2-Rate"
local function lfoId(i, suffix)
    return "LFO-" .. i .. "-" .. suffix
end

-- Updates the clock-divider knob's sprite frame to match its current value
local function applyClockSprite(i, state, value)
    local el = document:GetElementById(lfoId(i, "Clock-Divider"))
    if not el then return end
    local minV, maxV = getParamRange(state.param)
    local t = clamp((value - minV) / (maxV - minV), 0, 1)
    local frame = math.floor(t * (RATE_CLOCK_FRAMES - 1) + 0.5)
    el.style.decorator = "image(" .. RATE_CLOCK_PREFIX .. string.format("%03d", frame) .. ")"
end

-- Shows the Rate knob and hides the divider knob when Clock is off (free
-- rate mode), or the reverse when Clock is on (tempo-synced mode); also
-- keeps the toggle switch's checked state in sync
local function updateVisibility(i, state)
    local rate  = document:GetElementById(lfoId(i, "Rate"))
    local clock = document:GetElementById(lfoId(i, "Clock-Divider"))
    local btn   = document:GetElementById(lfoId(i, "Clock-Switch"))
    if rate then rate:SetClass("disabled", state.active) end
    if clock then clock:SetClass("disabled", not state.active) end
    if btn then btn:SetClass("checked", state.active) end
end

-- Clamps and writes a new Clock value, skipping the write if it wouldn't
-- actually change anything
local function setClockValue(i, state, value)
    local minV, maxV = getParamRange(state.param)
    value = clamp(value, minV, maxV)
    if value ~= (tonumber(params.get(state.param)) or minV) then
        params.set(state.param, value)
    end
end

-- Reacts to any change of a Clock parameter (from this widget or elsewhere):
-- refreshes the divider knob's sprite, remembers the last nonzero division
-- (so the toggle switch can restore it later), and updates visibility if
-- the on/off state actually flipped
local function onClockChanged(i, state, value)
    applyClockSprite(i, state, value)
    local active = value ~= 0
    if active then state.lastValue = value end
    if active ~= state.active then
        state.active = active
        updateVisibility(i, state)
    end
end

-- Global — bound to the toggle switch by name, do not rename. Switches an
-- LFO between free rate (Clock = 0) and its last-used tempo-synced division.
function Clock_Switch(_, el)
    local i = tonumber(el.id:match("LFO%-(%d+)%-Clock%-Switch"))
    local state = i and lfoStates[i]
    if not state then return end
    local cur = tonumber(params.get(state.param)) or 0
    params.set(state.param, cur ~= 0 and 0 or state.lastValue)
end

-- Wires up drag/scroll/dblclick editing for one LFO's clock-divider knob
local function initKnob(i, state)
    local el = document:GetElementById(lfoId(i, "Clock-Divider"))
    if not el then return end

    el:AddEventListener("mousedown", function(e)
        local minV, maxV = getParamRange(state.param)
        clockDrag = {
            i = i,
            startValue = clamp(tonumber(params.get(state.param)) or minV, minV, maxV),
            accum = 0,
            lastX = e.parameters.mouse_x,
            lastY = e.parameters.mouse_y,
        }
    end)

    el:AddEventListener("dblclick", function()
        local info = params.getInfo(state.param)
        setClockValue(i, state, math.max(info and info.defaultValue or 1, 1))
    end)

    el:AddEventListener("mousescroll", function(e)
        local d = e.parameters.wheel_delta_y or e.parameters.wheel_delta or 0
        if d == 0 then return end
        local cur = tonumber(params.get(state.param)) or 1
        setClockValue(i, state, cur + (d > 0 and -1 or 1))
    end)
end

-- Applies an in-progress clock-divider knob drag, using an accumulated
-- (dx+dy) delta scaled by DRAG_RANGE_PX so a full-range drag covers the
-- knob's whole value range regardless of which axis the user drags along
document:AddEventListener("mousemove", function(e)
    if not clockDrag then return end
    local state = lfoStates[clockDrag.i]
    if not state then return end
    local p = e.parameters
    local scale = getSpeedScale(e)
    local dx = p.mouse_x - clockDrag.lastX
    local dy = clockDrag.lastY - p.mouse_y
    clockDrag.accum = clockDrag.accum + (dx + dy) * scale
    clockDrag.lastX, clockDrag.lastY = p.mouse_x, p.mouse_y
    local minV, maxV = getParamRange(state.param)
    local value = math.floor(clockDrag.startValue + clockDrag.accum / DRAG_RANGE_PX * (maxV - minV) + 0.5)
    setClockValue(clockDrag.i, state, value)
end)

document:AddEventListener("mouseup", function()
    clockDrag = nil
end)

-- ------------------------------------------------------------
-- Entry points
-- All global — bound to widget lifecycle events by name, do not rename.
-- ------------------------------------------------------------

function LFO_Clock_Divider()
    for i = 1, 3 do
        local state = lfoStates[i]
        local cur = tonumber(params.get(state.param)) or 0
        state.active = cur ~= 0
        state.lastValue = state.active and cur or 1
        initKnob(i, state)
        applyClockSprite(i, state, cur)
        updateVisibility(i, state)
        params.onChange(state.param, function(v)
            onClockChanged(i, state, v)
        end)
    end
end

function LFO_1_LCD_Waves()
    LcdWave.setup("LFO-1-LCD-Waves", "Lfo1 Shape", "#23395D", "#8C97A9", "#FFFFFF80", LFO_WAVE_COUNT, true, "LFO 1/Waveform Shape")
    LcdWave.initAll()
end

function LFO_2_LCD_Waves()
    LcdWave.setup("LFO-2-LCD-Waves", "Lfo2 Shape", "#23395D", "#8C97A9", "#FFFFFF80", LFO_WAVE_COUNT, true, "LFO 2/Waveform Shape")
    LcdWave.initAll()
end

function LFO_3_LCD_Waves()
    LcdWave.setup("LFO-3-LCD-Waves", "Lfo3 Shape", "#23395D", "#8C97A9", "#FFFFFF80", LFO_WAVE_COUNT, true, "LFO 3/Waveform Shape")
    LcdWave.initAll()
end

function LFO()
    LFO_1_LCD_Waves()
    LFO_2_LCD_Waves()
    LFO_3_LCD_Waves()
    LFO_Clock_Divider()
end
