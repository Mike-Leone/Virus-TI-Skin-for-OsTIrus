-- ============================================================
-- Arpeggiator user pattern editor script
-- Draws a 32-step grid of velocity/length bars, supports editing
-- via drag (velocity/length/both), right-click step toggling,
-- alt-drag "paint" mode, middle-click copy/paste of steps, mouse
-- wheel nudging, and preset patterns (ArpPresets).
-- ============================================================

local STEPS                                     = 32
local CANVAS_DESIGN_W                           = 1280   -- reference canvas width the layout constants below were designed at
local currentScale                              = 1          -- actual canvas width / CANVAS_DESIGN_W, recomputed every repaint

local canvasElement, canvas, initialized        = nil, nil, false
local currentPresetIndex                        = 0            -- 0 = editing the user pattern; 1..63 = viewing a read-only preset
local savedPatternLength                        = STEPS - 1    -- user pattern length preserved while a preset is being viewed

-- ------------------------------------------------------------
-- Visual style constants
-- ------------------------------------------------------------
local COLOR_ACTIVE_FILL                         = "#AAC0DC80"   -- fill color for steps within the current pattern length
local COLOR_ACTIVE_BORDER                       = "#E8F4FF80"
local COLOR_INACTIVE_FILL                       = "#AAC0DC32"   -- fill color for steps beyond the current pattern length
local COLOR_INACTIVE_BORDER                     = "#E8F4FF33"
local COLOR_COPY_GHOST_FILL                     = "#33CC5580"     -- fill for the green "copy in progress" preview bar
local COLOR_COPY_GHOST_BORDER                   = "#A0FF71E6"   -- border for the preview bar, and outline drawn on the source step

local BORDER_WIDTH                              = 2
local BORDER_RADIUS                             = 2
local MIN_VELOCITY_PX                           = 4      -- smallest bar height drawn, even for very low velocity
local MIN_BAR_WIDTH_PX                          = 4     -- smallest bar width drawn, even for very short length
local HOVER_THICK                               = 2          -- thickness of the top/right hover highlight strip
local CORNER_HOVER_SIZE                         = 10   -- size of the corner (velocity+length) hover highlight triangle
local DRAG_EDGE_PX                              = 8         -- hit-test margin around a bar's top/right edge for drag handles

local DEFAULT_VELOCITY                          = 100   -- value restored on double-click
local DEFAULT_LENGTH                            = 64      -- value restored on double-click
local MIN_DISABLED_FRACTION                     = 0.25   -- RandomizeStep: minimum fraction of steps left enabled

-- ------------------------------------------------------------
-- Per-step layout, computed fresh each repaint
-- ------------------------------------------------------------
local stepRects                                 = {}    -- [step] = { x, y, w, h, groupWidthPx, globalGate, inRange } — screen rect + drag context
local stepGroups                                = {}   -- [step] = { startStep, endStep, size } — run of consecutive active steps this step belongs to

-- ------------------------------------------------------------
-- Drag state (resizing a step's velocity/length via its top/right/corner handle)
-- ------------------------------------------------------------
local dragStep, dragMode                        = nil, nil                    -- currently dragged step index and handle ("top"/"right"/"corner")
local lastDownStep, lastDownMode                = nil, nil             -- last mousedown hit, used as a fallback target for dblclick
local dragLastMouseX, dragLastMouseY            = 0, 0             -- last raw mouse position seen during a drag (for computing deltas)
local dragVirtX, dragVirtY                      = 0, 0                       -- "virtual" cursor position, scaled by modifier-key drag speed

local SPEED_SCALE_SHIFT                         = 0.5           -- drag speed multiplier while Shift is held
local SPEED_SCALE_CTRL                          = 0.2            -- drag speed multiplier while Ctrl is held
local CORNER_SLOWDOWN_SCALE                     = 0.3       -- extra slowdown for corner-drag while Alt is held

local WHEEL_STEP_DEFAULT                        = 4
local WHEEL_STEP_CTRL                           = 1

local hoverStep, hoverMode                      = nil, nil   -- step/handle currently under the mouse (when not dragging)

-- ------------------------------------------------------------
-- Alt-drag "paint" mode: sweeping across steps to set velocity in one gesture
-- ------------------------------------------------------------
local paintActive                               = false
local paintStartMx, paintStartMy, paintStartCol = 0, 0, nil

-- ------------------------------------------------------------
-- Right-click drag: sweeping across steps to toggle them on/off
-- ------------------------------------------------------------
local rightDragActive                           = false
local rightDragStartCol                         = nil
local rightDragTargetState                      = nil    -- the on/off state being applied to every step the drag passes over

-- ------------------------------------------------------------
-- Middle-click drag: copy one step (or its whole group) onto another
-- ------------------------------------------------------------
local copySourceCol                             = nil
local copySourceVals                            = nil
local copySourceGroupSize                       = 0
local copyDragTargetCol                         = nil   -- step currently under the cursor during an in-progress copy drag (drives the green preview)

local PATTERN_LEN_MIN, PATTERN_LEN_MAX          = 0, STEPS - 1

-- ------------------------------------------------------------
-- Small helpers
-- ------------------------------------------------------------

local function getParam(name, default)
    local v = params.get(name)
    return (v == nil) and default or v
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

-- Builds the underlying parameter name for a given step and field, e.g. "Step 5 Velocity"
local function stepParamName(step, suffix)
    return "Step " .. step .. " " .. suffix
end

-- Reads a step's value, transparently substituting preset data when a read-only preset is active
local function getStepParam(step, paramType, default)
    if currentPresetIndex > 0 and currentPresetIndex <= 63 then
        local preset   = ArpPresets[currentPresetIndex]
        local stepData = preset and preset[step]
        if not stepData then return default end
        if paramType == "Bitfield" then return stepData[1] or default
        elseif paramType == "Velocity" then return stepData[2] or default
        elseif paramType == "Length" then return stepData[3] or default
        else return default end
    end
    return getParam(stepParamName(step, paramType), default)
end

local function isStepBitActive(step)
    return getStepParam(step, "Bitfield", 0) > 0
end

-- Number of steps currently in the pattern (1..STEPS)
local function getPatternLength()
    local raw = getParam("Arpeggiator/UserPatternLength", STEPS - 1)
    return math.max(0, math.min(STEPS - 1, raw)) + 1
end

-- Traces a rounded-rectangle path on the canvas context (does not fill/stroke)
local function roundedRectPath(ctx, x, y, w, h, r)
    r = math.max(0, math.min(r, w / 2, h / 2))
    ctx:beginPath()
    ctx:moveTo(x + r, y)
    ctx:lineTo(x + w - r, y)
    ctx:arc(x + w - r, y + r, r, -math.pi / 2, 0)
    ctx:lineTo(x + w, y + h - r)
    ctx:arc(x + w - r, y + h - r, r, 0, math.pi / 2)
    ctx:lineTo(x + r, y + h)
    ctx:arc(x + r, y + h - r, r, math.pi / 2, math.pi)
    ctx:lineTo(x, y + r)
    ctx:arc(x + r, y + r, r, math.pi, math.pi * 1.5)
    ctx:closePath()
end

-- Bakes the currently viewed read-only preset into the user pattern parameters,
-- then switches selection back to the user pattern (0), so it becomes editable.
-- Called automatically by every edit action before it writes a value.
local function copyPresetToUser()
    local capturedLen = getPatternLength()
    for i = 1, STEPS do
        params.set(stepParamName(i, "Bitfield"), getStepParam(i, "Bitfield", 0))
        params.set(stepParamName(i, "Velocity"), getStepParam(i, "Velocity", 64))
        params.set(stepParamName(i, "Length"), getStepParam(i, "Length", 64))
    end
    savedPatternLength = math.max(0, math.min(STEPS - 1, capturedLen - 1))
    params.set("Arp Pattern Selct", 0)
end

-- Reads the first `len` steps' length/velocity/bitfield values into three parallel arrays
local function collectStepValues(len)
    local lengths, velocities, bitfields = {}, {}, {}
    for i = 1, len do
        lengths[i]    = getParam(stepParamName(i, "Length"), 64)
        velocities[i] = getParam(stepParamName(i, "Velocity"), 64)
        bitfields[i]  = getParam(stepParamName(i, "Bitfield"), 0)
    end
    return lengths, velocities, bitfields
end

-- Writes one step's length/velocity/bitfield values back to its parameters
local function applyStepValues(i, length, velocity, bitfield)
    params.set(stepParamName(i, "Length"), length)
    params.set(stepParamName(i, "Velocity"), velocity)
    params.set(stepParamName(i, "Bitfield"), bitfield)
end

-- ------------------------------------------------------------
-- Pattern-editing actions
-- Exposed as global functions so the host UI can bind them to buttons
-- by name — do not rename these. All are no-ops while a read-only
-- preset is selected (currentPresetIndex > 0).
-- ------------------------------------------------------------

-- Randomizes the Length of every active step within the current pattern length
function RandomizeLengths()
    if currentPresetIndex > 0 then return end
    local len = getPatternLength()
    for i = 1, len do
        if isStepBitActive(i) then
            params.set(stepParamName(i, "Length"), math.random(0, 127))
        end
    end
    UpdateAllSteps()
end

-- Randomizes the Velocity of every active step within the current pattern length
function RandomizeVelocity()
    if currentPresetIndex > 0 then return end
    local len = getPatternLength()
    for i = 1, len do
        if isStepBitActive(i) then
            params.set(stepParamName(i, "Velocity"), math.random(0, 127))
        end
    end
    UpdateAllSteps()
end

-- Randomly enables/disables steps within the current pattern length, keeping
-- at least MIN_DISABLED_FRACTION of them active
function RandomizeStep()
    if currentPresetIndex > 0 then return end
    local len = getPatternLength()

    for i = 1, len do
        params.set(stepParamName(i, "Bitfield"), 0)
    end

    local minActive = math.max(1, math.ceil(len * MIN_DISABLED_FRACTION))
    local count     = math.random(minActive, len)

    local steps     = {}
    for i = 1, len do steps[i] = i end
    for i = len, 2, -1 do
        local j            = math.random(i)
        steps[i], steps[j] = steps[j], steps[i]
    end

    for i = 1, count do
        params.set(stepParamName(steps[i], "Bitfield"), 1)
    end

    UpdateAllSteps()
end

-- Rotates all step values one position to the right (wrapping around the pattern length)
function Right()
    if currentPresetIndex > 0 then return end
    local len                            = getPatternLength()
    local lengths, velocities, bitfields = collectStepValues(len)
    for i = len, 1, -1 do
        local src = (i == 1) and len or (i - 1)
        applyStepValues(i, lengths[src], velocities[src], bitfields[src])
    end
    UpdateAllSteps()
end

-- Rotates all step values one position to the left (wrapping around the pattern length)
function Left()
    if currentPresetIndex > 0 then return end
    local len                            = getPatternLength()
    local lengths, velocities, bitfields = collectStepValues(len)
    for i = 1, len do
        local src = (i == len) and 1 or (i + 1)
        applyStepValues(i, lengths[src], velocities[src], bitfields[src])
    end
    UpdateAllSteps()
end

-- Repeats the current pattern (its first `len` steps) across all 32 steps
function Fill()
    if currentPresetIndex > 0 then return end
    local len = getPatternLength()
    for i = 1, STEPS do
        local src = ((i - 1) % len) + 1
        params.set(stepParamName(i, "Length"), getParam(stepParamName(src, "Length"), 64))
        params.set(stepParamName(i, "Velocity"), getParam(stepParamName(src, "Velocity"), 64))
        params.set(stepParamName(i, "Bitfield"), getParam(stepParamName(src, "Bitfield"), 0))
    end
    UpdateAllSteps()
end

-- Restores the full 32-step pattern to its factory default values
function Reset()
    if currentPresetIndex > 0 then return end
    params.set("Arpeggiator/UserPatternLength", STEPS - 1)
    for i = 1, STEPS do
        params.set(stepParamName(i, "Length"), 64)
        params.set(stepParamName(i, "Velocity"), 100)
        params.set(stepParamName(i, "Bitfield"), 1)
    end
    UpdateAllSteps()
end

-- ------------------------------------------------------------
-- Canvas refresh
-- Also global (bound to params.onChange below), do not rename.
-- ------------------------------------------------------------

-- Detects preset selection changes (switching the active parameter-name source
-- and preserving/restoring the user pattern length), then repaints the canvas.
-- Bound to every parameter that can affect the drawing.
function UpdateAllSteps()
    if not canvas or not canvasElement then return end

    local patternSelect  = getParam("Arp Pattern Selct", 0)
    local newPresetIndex = math.max(0, math.min(63, patternSelect))

    if newPresetIndex ~= currentPresetIndex then
        if currentPresetIndex > 0 and newPresetIndex == 0 then
            params.set("Arpeggiator/UserPatternLength", savedPatternLength)
        elseif currentPresetIndex == 0 and newPresetIndex > 0 then
            local raw          = getParam("Arpeggiator/UserPatternLength", STEPS - 1)
            savedPatternLength = math.max(0, math.min(STEPS - 1, raw))
        end
        currentPresetIndex = newPresetIndex
    end

    if currentPresetIndex > 0 and currentPresetIndex <= 63 then
        local preset = ArpPresets[currentPresetIndex]
        if preset and preset.Steps then
            local targetLen = math.max(1, math.min(STEPS, preset.Steps))
            params.set("Arpeggiator/UserPatternLength", targetLen - 1)
        end
    end

    canvas:repaint()
end

-- Per-step parameter-change callback; a single step's change can shift the whole
-- pattern layout (e.g. group sizes), so it simply triggers a full refresh
function UpdateStep(step)
    UpdateAllSteps()
end

-- ------------------------------------------------------------
-- Drawing
-- ------------------------------------------------------------

-- Canvas paint callback: lays out and draws every active step's velocity/length bar,
-- including swing offset, gate-length scaling, and hover/drag highlights
function DrawSteps(ctx)
    local canvasWidth, canvasHeight = canvasElement.offset_width, canvasElement.offset_height
    if canvasWidth <= 0 or canvasHeight <= 0 then return end

    currentScale        = canvasWidth / CANVAS_DESIGN_W
    stepRects           = {}
    stepGroups          = {}

    local baseStepWidth = canvasWidth / STEPS

    local bitActive     = {}
    for i = 1, STEPS do
        bitActive[i] = getStepParam(i, "Bitfield", 0) > 0
    end

    local patternLength = getPatternLength()
    local limitIndex    = patternLength

    -- First pass: for each run of consecutive active steps, record how many
    -- steps that run spans (a "group" — legato-style steps that share one bar)
    local groupSize     = {}
    local i             = 1
    while i <= STEPS do
        if bitActive[i] then
            local j = i + 1
            while j <= STEPS and not bitActive[j] do j = j + 1 end
            groupSize[i] = j - i
            i            = j
        else
            groupSize[i] = 0
            i            = i + 1
        end
    end

    -- Second pass: record each group's info against every step index it covers
    -- (clamped to the current pattern length), so hit-testing and drag/copy
    -- logic can look up "which group does this step belong to" in O(1)
    for i = 1, STEPS do
        if bitActive[i] then
            local gSize         = math.max(1, groupSize[i] or 0)
            local effectiveSize = math.min(gSize, limitIndex - i + 1)
            if effectiveSize < 1 then effectiveSize = gSize end

            for j = i, i + effectiveSize - 1 do
                if j <= STEPS then
                    stepGroups[j] = { startStep = i, endStep = i + effectiveSize - 1, size = effectiveSize }
                end
            end
        end
    end

    -- Global note-length ("gate") factor: <=64 shortens notes, >64 lets them
    -- overhang into neighboring steps (legato)
    local ArpNoteLength = getParam("Arp Note Length", 64)
    local globalGate    = (ArpNoteLength <= 64)
            and (ArpNoteLength / 64.0)
            or (1.0 + (ArpNoteLength - 64) / 63.0)

    local swingFactor   = math.max(0, math.min(1, getParam("Arp Swing", 0) / 127.0))
    local maxSwingPx    = baseStepWidth * 0.45 * swingFactor

    local borderWidth   = BORDER_WIDTH * currentScale
    local borderRadius  = BORDER_RADIUS * currentScale
    local minVelPx      = MIN_VELOCITY_PX * currentScale
    local minBarWidthPx = MIN_BAR_WIDTH_PX * currentScale
    local hoverThick    = HOVER_THICK * currentScale
    local cornerSize    = CORNER_HOVER_SIZE * currentScale
    local edgeMargin    = math.max(1, roundToPixel(2 * currentScale))

    -- Draw each active step's bar: width encodes Length (scaled by group size and
    -- global gate), height encodes Velocity, and odd/even steps get a swing offset
    for i = 1, STEPS do
        local Bitfield = getStepParam(i, "Bitfield", 0)
        if Bitfield == 0 then goto continue end

        local inRange            = i <= limitIndex
        local leftPos            = baseStepWidth * (i - 1)
        local group              = stepGroups[i]
        local effectiveGroupSize = (group and group.size) or 1

        local swingOffset        = (i % 2 == 0) and maxSwingPx or 0
        local groupWidthPx       = baseStepWidth * effectiveGroupSize

        local StepLength         = getStepParam(i, "Length", 64)
        local targetWidth        = groupWidthPx * globalGate * (StepLength / 127.0)

        local maxAllowedPx       = math.max(minBarWidthPx, (baseStepWidth * effectiveGroupSize) - swingOffset - edgeMargin)
        local drawWidth          = math.max(minBarWidthPx, math.min(targetWidth, maxAllowedPx))
        drawWidth                = math.min(drawWidth, (canvasWidth - leftPos) - edgeMargin)

        local finalLeftPos       = leftPos + swingOffset
        if finalLeftPos + drawWidth > canvasWidth - edgeMargin then
            finalLeftPos = math.max(0, canvasWidth - drawWidth - edgeMargin)
        end

        local Velocity       = getStepParam(i, "Velocity", 64)
        local barHeight      = math.max(minVelPx, (Velocity / 127.0) * canvasHeight)
        local barTop         = canvasHeight - barHeight

        finalLeftPos, barTop = roundToPixel(finalLeftPos), roundToPixel(barTop)
        drawWidth, barHeight = roundToPixel(drawWidth), roundToPixel(barHeight)

        roundedRectPath(ctx, finalLeftPos, barTop, drawWidth, barHeight, borderRadius)
        ctx.fillStyle = inRange and COLOR_ACTIVE_FILL or COLOR_INACTIVE_FILL
        ctx:fill()

        local half   = borderWidth / 2
        local iw, ih = drawWidth - borderWidth, barHeight - borderWidth
        if iw > 0 and ih > 0 then
            local isBeingCopied = (i == copySourceCol) and copyDragTargetCol and (copyDragTargetCol ~= copySourceCol)
            roundedRectPath(ctx, finalLeftPos + half, barTop + half, iw, ih, math.max(0, borderRadius - half))
            ctx.strokeStyle = isBeingCopied and COLOR_COPY_GHOST_BORDER or (inRange and COLOR_ACTIVE_BORDER or COLOR_INACTIVE_BORDER)
            ctx.lineWidth   = borderWidth
            ctx:stroke()
        end

        if (i == hoverStep and hoverMode) or (dragStep == i and dragMode) then
            ctx.fillStyle       = "#FFD400"
            local highlightMode = (dragStep == i and dragMode) or hoverMode

            if highlightMode == "top" then
                ctx:fillRect(finalLeftPos, barTop, drawWidth, hoverThick)
            elseif highlightMode == "right" then
                ctx:fillRect(finalLeftPos + drawWidth - hoverThick, barTop, hoverThick, barHeight)
            elseif highlightMode == "corner" then
                local size = math.min(cornerSize, drawWidth, barHeight)
                ctx:beginPath()
                ctx:moveTo(finalLeftPos + drawWidth - size, barTop)
                ctx:lineTo(finalLeftPos + drawWidth, barTop)
                ctx:lineTo(finalLeftPos + drawWidth, barTop + size)
                ctx:closePath()
                ctx:fill()
            end
        end

        stepRects[i] = {
            x            = finalLeftPos, y = barTop, w = drawWidth, h = barHeight,
            groupWidthPx = groupWidthPx, globalGate = globalGate, inRange = inRange,
        }

        :: continue ::
    end

    -- While a middle-click copy-drag is in progress, draw a green preview of
    -- the copied bar at the column currently under the cursor. The source
    -- step's own border is recolored to match (see the border block in the
    -- main draw loop above), so the user can see what is being dragged and
    -- where it will land.
    if copySourceCol and copyDragTargetCol then
        local targetGroup    = stepGroups[copyDragTargetCol]
        local actualTarget   = (targetGroup and targetGroup.startStep) or copyDragTargetCol

        local ghostGroupSize = math.max(1, copySourceGroupSize)
        local leftPos        = baseStepWidth * (actualTarget - 1)
        local groupWidthPx   = baseStepWidth * ghostGroupSize
        local swingOffset    = (actualTarget % 2 == 0) and maxSwingPx or 0

        local ghostLength    = (copySourceVals and copySourceVals.Length) or 64
        local ghostVelocity  = (copySourceVals and copySourceVals.Velocity) or 64

        local targetWidth    = groupWidthPx * globalGate * (ghostLength / 127.0)
        local maxAllowedPx   = math.max(minBarWidthPx, (baseStepWidth * ghostGroupSize) - swingOffset - edgeMargin)
        local drawWidth      = math.max(minBarWidthPx, math.min(targetWidth, maxAllowedPx))
        drawWidth            = math.min(drawWidth, (canvasWidth - leftPos) - edgeMargin)

        local finalLeftPos   = leftPos + swingOffset
        if finalLeftPos + drawWidth > canvasWidth - edgeMargin then
            finalLeftPos = math.max(0, canvasWidth - drawWidth - edgeMargin)
        end

        local barHeight      = math.max(minVelPx, (ghostVelocity / 127.0) * canvasHeight)
        local barTop         = canvasHeight - barHeight

        finalLeftPos, barTop = roundToPixel(finalLeftPos), roundToPixel(barTop)
        drawWidth, barHeight = roundToPixel(drawWidth), roundToPixel(barHeight)

        roundedRectPath(ctx, finalLeftPos, barTop, drawWidth, barHeight, borderRadius)
        ctx.fillStyle = COLOR_COPY_GHOST_FILL
        ctx:fill()

        local half   = borderWidth / 2
        local iw, ih = drawWidth - borderWidth, barHeight - borderWidth
        if iw > 0 and ih > 0 then
            roundedRectPath(ctx, finalLeftPos + half, barTop + half, iw, ih, math.max(0, borderRadius - half))
            ctx.strokeStyle = COLOR_COPY_GHOST_BORDER
            ctx.lineWidth   = borderWidth
            ctx:stroke()
        end
    end
end

-- ------------------------------------------------------------
-- Hit-testing and interaction helpers
-- ------------------------------------------------------------

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

-- Returns which step (and which part of its bar — "top"/"right"/"corner"/"body")
-- the given local coordinates fall on, or nil if none. "top"/"right"/"corner" are
-- drag handles (velocity/length/both); "body" means inside the bar but not on an edge.
local function hitTestStep(mx, my)
    local margin = DRAG_EDGE_PX * currentScale
    for i = 1, STEPS do
        local r = stepRects[i]
        if r and r.inRange
                and mx >= r.x - margin and mx <= r.x + r.w + margin
                and my >= r.y - margin and my <= r.y + r.h + margin then
            local nearRight = math.abs(mx - (r.x + r.w)) <= margin
            local nearTop   = math.abs(my - r.y) <= margin
            if nearTop and nearRight then return i, "corner"
            elseif nearTop then return i, "top"
            elseif nearRight then return i, "right"
            else return i, "body" end
        end
    end
    return nil, nil
end

-- Maps a local x coordinate to a step index (1..STEPS), regardless of which
-- step is actually active/visible there — used by handlers that work on raw
-- grid columns rather than rendered bars (right-click, paint, copy, wheel)
local function columnAt(mx)
    local canvasWidth = canvasElement.offset_width
    return math.max(1, math.min(STEPS, math.floor(mx / (canvasWidth / STEPS)) + 1))
end

local function getGroupForColumn(col)
    return stepGroups[col]
end

-- Returns the drag-speed multiplier for the current drag handle and held modifier key
local function dragSpeedScale(event)
    if dragMode == "corner" then
        return keyDown(event.parameters.alt_key) and CORNER_SLOWDOWN_SCALE or 1.0
    end
    local p = event.parameters
    if keyDown(p.shift_key) then return SPEED_SCALE_SHIFT
    elseif keyDown(p.ctrl_key) then return SPEED_SCALE_CTRL end
    return 1.0
end

-- ------------------------------------------------------------
-- Handle drag: resizing a step's Velocity/Length via its top/right/corner handle
-- ------------------------------------------------------------

-- Plain left-click on a handle (not right/middle/alt-click): begins a resize
-- drag. Ignored if the click lands on the bar body, not an edge handle.
local function ArpDragStart(event)
    local mx, my               = getLocalMouse(event, canvasElement)
    local step, mode           = hitTestStep(mx, my)
    lastDownStep, lastDownMode = step, mode

    if not step or mode == "body" then
        dragStep, dragMode = nil, nil
        return
    end

    if currentPresetIndex > 0 then copyPresetToUser() end

    dragStep, dragMode             = step, mode
    dragLastMouseX, dragLastMouseY = mx, my
    dragVirtX, dragVirtY           = mx, my

    hoverStep, hoverMode           = nil, nil
end

-- Applies the in-progress resize drag: "top"/"corner" adjust Velocity from the
-- virtual cursor's Y, "right"/"corner" adjust Length from its X. On the corner
-- handle, holding Shift locks to Length-only and Ctrl locks to Velocity-only.
local function ArpDrag(event)
    if not dragStep then return end

    local mx, my                   = getLocalMouse(event, canvasElement)
    local scale                    = dragSpeedScale(event)
    -- Virtual cursor: Shift/Ctrl slowdown (corner: Alt); absolute map still applies
    dragVirtX                      = dragVirtX + (mx - dragLastMouseX) * scale
    dragVirtY                      = dragVirtY + (my - dragLastMouseY) * scale
    dragLastMouseX, dragLastMouseY = mx, my

    local canvasHeight             = canvasElement.offset_height
    local r0                       = stepRects[dragStep]

    local onlyLength               = dragMode == "corner" and keyDown(event.parameters.shift_key)
    local onlyVelocity             = dragMode == "corner" and keyDown(event.parameters.ctrl_key)

    if not onlyLength and (dragMode == "top" or dragMode == "corner") then
        local newVel = math.floor((1 - dragVirtY / canvasHeight) * 127.0 + 0.5)
        params.set(stepParamName(dragStep, "Velocity"), clamp127(newVel))
    end

    if not onlyVelocity and (dragMode == "right" or dragMode == "corner") then
        local left         = (r0 and r0.x) or 0
        local groupWidthPx = (r0 and r0.groupWidthPx) or (canvasElement.offset_width / STEPS)
        local globalGate   = (r0 and r0.globalGate) or 1.0
        local denom        = math.max(1, groupWidthPx * globalGate)
        local newLen       = math.floor((dragVirtX - left) / denom * 127.0 + 0.5)
        params.set(stepParamName(dragStep, "Length"), clamp127(newLen))
    end

    canvas:repaint()
end

local function ArpDragEnd(event)
    dragStep, dragMode = nil, nil

    local mx, my       = getLocalMouse(event, canvasElement)
    local step, mode   = hitTestStep(mx, my)
    if mode == "body" then step, mode = nil, nil end
    hoverStep, hoverMode = step, mode

    canvas:repaint()
end

-- Double-click on a handle resets the corresponding value(s) to their defaults;
-- double-click on the bar body resets both Velocity and Length
local function ArpDblClick(event)
    local mx, my     = getLocalMouse(event, canvasElement)
    local step, mode = hitTestStep(mx, my)
    if not step then
        step, mode = lastDownStep, lastDownMode
    end
    if not step then return end

    if currentPresetIndex > 0 then copyPresetToUser() end

    dragStep, dragMode = nil, nil

    if mode == "body" or not mode then
        params.set(stepParamName(step, "Velocity"), DEFAULT_VELOCITY)
        params.set(stepParamName(step, "Length"), DEFAULT_LENGTH)
    else
        if mode == "top" or mode == "corner" then
            params.set(stepParamName(step, "Velocity"), DEFAULT_VELOCITY)
        end
        if mode == "right" or mode == "corner" then
            params.set(stepParamName(step, "Length"), DEFAULT_LENGTH)
        end
    end

    canvas:repaint()
    event:StopPropagation()
end

-- ------------------------------------------------------------
-- Right-click drag: sweeping across the grid toggles steps on/off, all set
-- to whichever state the first clicked step was switched to
-- ------------------------------------------------------------

local function ArpRightClick(event)
    local mx   = getLocalMouse(event, canvasElement)
    local step = columnAt(mx)
    if step > getPatternLength() then return end

    if currentPresetIndex > 0 then copyPresetToUser() end

    local cur            = getParam(stepParamName(step, "Bitfield"), 0)
    rightDragTargetState = (cur > 0) and 0 or 1
    params.set(stepParamName(step, "Bitfield"), rightDragTargetState)

    rightDragActive, rightDragStartCol = true, step
    event:StopPropagation()
end

local function ArpRightDrag(event)
    if not rightDragActive then return end
    local mx   = getLocalMouse(event, canvasElement)
    local step = columnAt(mx)
    if step == rightDragStartCol or step > getPatternLength() then return end
    params.set(stepParamName(step, "Bitfield"), rightDragTargetState)
end

local function ArpRightDragEnd(event)
    rightDragActive, rightDragStartCol, rightDragTargetState = false, nil, nil
end

-- ------------------------------------------------------------
-- Middle-click drag: copies one step (or its whole legato group) onto the
-- step released on. If the source was a single step, the step right after
-- the target is enabled to receive the pasted values as a fresh single step.
-- ------------------------------------------------------------

-- Middle mouse down: remembers the source step's (or group's) values
local function ArpCopyStart(event)
    local mx, my = getLocalMouse(event, canvasElement)
    local col    = columnAt(mx)
    if col > getPatternLength() then return end

    if currentPresetIndex > 0 then copyPresetToUser() end

    local group = getGroupForColumn(col)
    if group then
        copySourceCol, copySourceGroupSize = group.startStep, group.size
    else
        copySourceCol, copySourceGroupSize = col, 1
    end

    copySourceVals    = {
        Bitfield = getParam(stepParamName(copySourceCol, "Bitfield"), 0),
        Velocity = getParam(stepParamName(copySourceCol, "Velocity"), 64),
        Length   = getParam(stepParamName(copySourceCol, "Length"), 64),
    }

    copyDragTargetCol = col
    canvas:repaint()
    event:StopPropagation()
end

-- Middle-drag move: tracks which column the cursor is currently over so
-- DrawSteps can render a green preview of what will be pasted, and where
local function ArpCopyDrag(event)
    if not copySourceCol then return end
    local mx        = getLocalMouse(event, canvasElement)
    local col       = columnAt(mx)
    local newTarget = (col <= getPatternLength()) and col or nil

    if newTarget == copyDragTargetCol then return end
    copyDragTargetCol = newTarget
    canvas:repaint()
end

-- Middle mouse up: pastes the captured source values onto the released-on step (or its group)
local function ArpCopyEnd(event)
    if not copySourceCol then return end
    local mx     = getLocalMouse(event, canvasElement)
    local target = columnAt(mx)

    if target <= getPatternLength() then
        local targetGroup  = getGroupForColumn(target)
        local actualTarget = targetGroup and targetGroup.startStep or target

        if actualTarget ~= copySourceCol then
            params.set(stepParamName(actualTarget, "Bitfield"), copySourceVals.Bitfield)
            params.set(stepParamName(actualTarget, "Velocity"), copySourceVals.Velocity)
            params.set(stepParamName(actualTarget, "Length"), copySourceVals.Length)

            if copySourceGroupSize > 1 then
                for i = 1, copySourceGroupSize - 1 do
                    local stepToDisable = actualTarget + i
                    if stepToDisable <= getPatternLength() then
                        params.set(stepParamName(stepToDisable, "Bitfield"), 0)
                    end
                end
            else
                local nextStep = actualTarget + 1
                if nextStep <= getPatternLength() then
                    params.set(stepParamName(nextStep, "Bitfield"), 1)
                end
            end
        end
    end

    copySourceCol, copySourceVals, copySourceGroupSize = nil, nil, 0
    copyDragTargetCol                                  = nil
    canvas:repaint()
end

-- ------------------------------------------------------------
-- Alt-drag "paint" mode: sets Velocity of every step the cursor sweeps over.
-- Plain paint follows the cursor freely; Shift draws a straight ramp between
-- the start and current velocity; Shift+Ctrl draws a flat (horizontal) ramp
-- at the starting velocity.
-- ------------------------------------------------------------

-- Writes Velocity for the step(s) under the paint gesture, per the given mode
local function ArpPaintApply(mx, my, mode)
    local canvasHeight = canvasElement.offset_height

    if mode ~= "free" and paintStartCol then
        local curCol = columnAt(mx)
        local vStart = (1 - paintStartMy / canvasHeight) * 127
        local vEnd   = (mode == "horizontal") and vStart or ((1 - my / canvasHeight) * 127)
        local span   = curCol - paintStartCol
        local lo, hi = math.min(paintStartCol, curCol), math.max(paintStartCol, curCol)
        for c = lo, hi do
            local r = stepRects[c]
            if r and r.inRange then
                local t = (span == 0) and 0 or (c - paintStartCol) / span
                local v = math.floor(vStart + (vEnd - vStart) * t + 0.5)
                params.set(stepParamName(c, "Velocity"), clamp127(v))
            end
        end
        return
    end

    local col = columnAt(mx)
    local r   = stepRects[col]
    if not (r and r.inRange) then return end
    local vel = math.floor((1 - my / canvasHeight) * 127 + 0.5)
    params.set(stepParamName(col, "Velocity"), clamp127(vel))
end

-- Alt+mousedown on a step body begins a paint gesture
local function ArpPaintStart(event)
    local mx, my = getLocalMouse(event, canvasElement)
    local col    = columnAt(mx)
    local r      = stepRects[col]
    if not (r and r.inRange) then return end

    if currentPresetIndex > 0 then copyPresetToUser() end

    paintActive                               = true
    paintStartMx, paintStartMy, paintStartCol = mx, my, col
    hoverStep, hoverMode                      = nil, nil
    ArpPaintApply(mx, my, "free")
    event:StopPropagation()
end

-- Continues an in-progress paint gesture, choosing free/straight/horizontal
-- mode from the currently held modifier keys
local function ArpPaint(event)
    if not paintActive then return end
    local mx, my      = getLocalMouse(event, canvasElement)
    local shift, ctrl = keyDown(event.parameters.shift_key), keyDown(event.parameters.ctrl_key)
    local mode        = "free"
    if shift and ctrl then mode = "horizontal"
    elseif shift then mode = "straight" end
    ArpPaintApply(mx, my, mode)
end

local function ArpPaintEnd(event)
    paintActive, paintStartCol = false, nil
end

-- ------------------------------------------------------------
-- Top-level mouse routing
-- ------------------------------------------------------------

-- Dispatches mousedown to the right gesture by button/modifier: right-click
-- toggles a step, middle-click starts a copy, Alt+left starts painting,
-- otherwise a plain left-click starts a handle resize drag
local function ArpMouseDown(event)
    local button = event.parameters.button
    if button == 1 then
        ArpRightClick(event)
        return
    end
    if button == 2 then
        ArpCopyStart(event)
        return
    end
    if keyDown(event.parameters.alt_key) then
        ArpPaintStart(event)
        return
    end
    ArpDragStart(event)
end

-- Mouse wheel over a step nudges Velocity (or Length, with Shift) up/down by a step size
local function ArpWheel(event)
    local mx, my = getLocalMouse(event, canvasElement)
    local col    = columnAt(mx)
    local r      = stepRects[col]
    if not (r and r.inRange) then return end

    local delta = event.parameters.wheel_delta_y or event.parameters.wheel_delta or 0
    if delta == 0 then return end

    if currentPresetIndex > 0 then copyPresetToUser() end

    local amount = keyDown(event.parameters.ctrl_key) and WHEEL_STEP_CTRL or WHEEL_STEP_DEFAULT
    local dir    = (delta > 0) and -1 or 1
    local shift  = keyDown(event.parameters.shift_key)
    local suffix = shift and "Length" or "Velocity"
    local full   = stepParamName(col, suffix)
    params.set(full, clamp127(getParam(full, 64) + dir * amount))

    event:StopPropagation()
end

-- ------------------------------------------------------------
-- Hover highlighting (only relevant when not actively dragging/painting)
-- ------------------------------------------------------------

-- Tracks which handle the mouse is currently over so it can be drawn highlighted
local function ArpHover(event)
    if dragStep or paintActive then return end
    local mx, my     = getLocalMouse(event, canvasElement)
    local step, mode = hitTestStep(mx, my)
    if mode == "body" then step, mode = nil, nil end

    if step == hoverStep and mode == hoverMode then return end

    hoverStep, hoverMode = step, mode
    canvas:repaint()
end

-- Clears the hover highlight when the mouse leaves the canvas
local function ArpHoverClear(event)
    if hoverStep then
        hoverStep, hoverMode = nil, nil
        canvas:repaint()
    end
end

-- ------------------------------------------------------------
-- Pattern-length slider (a separate UI element, outside the step canvas)
-- ------------------------------------------------------------

-- Maps a click position on the length slider to a pattern length value
local function SliderPatternLengthClick(event)
    local el = document:GetElementById("Slider-Arp")
    if not el or el.offset_width <= 0 then return end

    local mx    = getLocalMouse(event, el)
    local frac  = math.max(0, math.min(1, mx / el.offset_width))
    local value = math.floor(frac * (PATTERN_LEN_MAX - PATTERN_LEN_MIN) + 0.5) + PATTERN_LEN_MIN
    params.set("Arpeggiator/UserPatternLength", value)
end

-- ------------------------------------------------------------
-- Entry point
-- Also global — bound to a widget lifecycle event by name, do not rename.
-- Guarded by `initialized` so re-invocation is a safe no-op.
-- ------------------------------------------------------------
function Arpeggiator()
    if initialized then return end

    canvasElement = document:GetElementById("Lua-Arpeggiator")
    if not canvasElement then return end

    canvas = Element.As.Canvas(canvasElement)
    if not canvas then return end

    initialized = true
    canvas:setPaintFunction(DrawSteps)

    canvasElement:AddEventListener("mousedown", ArpMouseDown)
    canvasElement:AddEventListener("dblclick", ArpDblClick)
    canvasElement:AddEventListener("mousescroll", ArpWheel)
    canvasElement:AddEventListener("mousemove", ArpHover)
    canvasElement:AddEventListener("mouseout", ArpHoverClear)
    document:AddEventListener("mousemove", ArpDrag)
    document:AddEventListener("mouseup", ArpDragEnd)
    document:AddEventListener("mousemove", ArpPaint)
    document:AddEventListener("mouseup", ArpPaintEnd)
    document:AddEventListener("mousemove", ArpRightDrag)
    document:AddEventListener("mouseup", ArpRightDragEnd)
    document:AddEventListener("mousemove", ArpCopyDrag)
    document:AddEventListener("mouseup", ArpCopyEnd)

    local sliderEl = document:GetElementById("Slider-Arp")
    if sliderEl then
        sliderEl:AddEventListener("mousedown", SliderPatternLengthClick)
    end

    -- Repaint on anything that affects the whole pattern's layout/rendering
    params.onChange("Arp Note Length", UpdateAllSteps)
    params.onChange("Arp Swing", UpdateAllSteps)
    params.onChange("Arpeggiator/UserPatternLength", UpdateAllSteps)
    params.onChange("Arp Pattern Selct", UpdateAllSteps)

    -- Repaint whenever any individual step's data changes
    for i = 1, STEPS do
        params.onChange(stepParamName(i, "Length"), UpdateStep)
        params.onChange(stepParamName(i, "Velocity"), UpdateStep)
        params.onChange(stepParamName(i, "Bitfield"), UpdateStep)
    end

    UpdateAllSteps()
end
