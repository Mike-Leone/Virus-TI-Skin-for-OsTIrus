-- ============================================================
-- Custom parameter readout display
-- A read-only companion to the "ADSR/Arpeggiator/Filter" canvases: it does
-- not edit any parameter itself, only shows a floating name/value label
-- (fading out after a delay) whenever the user hovers, clicks, drags, or
-- scrolls on a custom control or canvas — including re-deriving hit-testing
-- and layout logic for each canvas purely to know what's under the cursor.
-- ============================================================

local initialized = false

-- Element ids for the custom readout (what this script writes to) and the
-- native host readout (temporarily hidden while a custom readout is shown)
local IDS         = {
    customName  = "Custom-Focused-Name",
    customValue = "Custom-Focused-Value",
    nativeName  = "FocusedParameterName",
    nativeValue = "FocusedParameterValue",
}

local HIDE_CLASS  = "Custom-Display-Hide"   -- CSS class that drives the readout's fade-out transition

local function clamp01(v)
    if v < 0 then return 0 elseif v > 1 then return 1 end
    return v
end

-- Rounds a coordinate to the nearest whole pixel (for crisp canvas hit-testing math)
local function roundToPixel(v)
    return math.floor(v + 0.5)
end

local function keyDown(v)
    return v == true or (type(v) == "number" and v ~= 0)
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

local function paramNum(name, fallback)
    return tonumber(params.get(name)) or fallback
end

-- Prefers the host's own formatted display text for a parameter (e.g. "50%"),
-- falling back to the given default if the host has no text for it
local function paramTextOr(name, fallback)
    local t = params.getText and params.getText(name)
    if t and t ~= "" then return t end
    return fallback
end

--------------------------------------------------------------------------
-- Display
-- Owns the custom name/value readout elements: showing them, hiding the
-- native readout while they're up, and fading them out after a delay.
-- `gen` is a generation counter used to cancel/ignore stale fade timers
-- when a new show() interrupts one already in progress.
--------------------------------------------------------------------------

local Display = { fading = false, gen = 0 }

-- Looks up the custom name/value elements by id (not cached, since the
-- underlying DOM can be rebuilt by the host)
function Display.elements()
    return document:GetElementById(IDS.customName), document:GetElementById(IDS.customValue)
end

-- Shows or hides the host's own native readout elements
function Display.showNative(visible)
    local nameEl = document:GetElementById(IDS.nativeName)
    local valueEl = document:GetElementById(IDS.nativeValue)
    if nameEl then nameEl:SetClass("disabled", not visible) end
    if valueEl then valueEl:SetClass("disabled", not visible) end
end

local function clearHideClass(el)
    el:SetClass(HIDE_CLASS, false)
end

local function clearHideClasses(nameEl, valueEl)
    clearHideClass(nameEl)
    clearHideClass(valueEl)
end

-- Cancels any in-progress fade-out, keeping the readout fully visible
function Display.cancelFade()
    local nameEl, valueEl = Display.elements()
    if not nameEl or not valueEl then return end
    Display.gen = Display.gen + 1
    clearHideClasses(nameEl, valueEl)
    Display.fading = false
end

-- Starts (or restarts) the readout's fade-out-after-a-delay transition
function Display.startFade()
    local nameEl, valueEl = Display.elements()
    if not nameEl or not valueEl then return end

    Display.gen = Display.gen + 1
    local myGen = Display.gen

    -- Force a real class change so the 1.5s delay transition restarts:
    -- strip hide + briefly disable, read layout, then re-apply hide.
    nameEl:SetClass("disabled", true)
    valueEl:SetClass("disabled", true)
    clearHideClasses(nameEl, valueEl)
    nameEl:SetClass("disabled", false)
    valueEl:SetClass("disabled", false)

    local _ = nameEl.offset_width
    local _ = valueEl.offset_width

    nameEl:SetClass(HIDE_CLASS, true)
    valueEl:SetClass(HIDE_CLASS, true)

    Display.fading  = true
    Display.fadeGen = myGen
end

-- Immediately hides the readout (skipping the fade transition), optionally
-- restoring the native readout's visibility
function Display.hide(restoreNative)
    local nameEl, valueEl = Display.elements()
    Display.gen = Display.gen + 1
    if nameEl then
        nameEl:SetClass("disabled", true)
        clearHideClass(nameEl)
    end
    if valueEl then
        valueEl:SetClass("disabled", true)
        clearHideClass(valueEl)
    end
    if restoreNative then Display.showNative(true) end
    Display.fading = false
end

-- Displays label/text in the custom readout, hides the native readout, and
-- either cancels or (re)starts the fade-out depending on keepVisible
function Display.show(label, text, keepVisible)
    local nameEl, valueEl = Display.elements()
    if not nameEl or not valueEl then return end
    nameEl:SetClass("disabled", false)
    valueEl:SetClass("disabled", false)
    nameEl.inner_rml = label
    valueEl.inner_rml = text
    Display.showNative(false)
    if keepVisible then Display.cancelFade() else Display.startFade() end
end

-- CSS transitionend handler: once the fade-out animation finishes, actually
-- disables the element (removing it from layout/hit-testing). Ignores stale
-- events from a fade that's since been cancelled or superseded (via `gen`).
function Display.onTransitionEnd(e)
    if not Display.fading then return end
    if Display.fadeGen and Display.gen ~= Display.fadeGen then return end

    local el = e.target_element
    if not el or not el:IsClassSet(HIDE_CLASS) then return end
    el:SetClass("disabled", true)
    el:SetClass(HIDE_CLASS, false)

    local nameEl, valueEl = Display.elements()
    if nameEl and valueEl and nameEl:IsClassSet("disabled") and valueEl:IsClassSet("disabled") then
        Display.fading = false
    end
end

function Display.bindTransitionEnd()
    local nameEl, valueEl = Display.elements()
    if nameEl then nameEl:AddEventListener("transitionend", Display.onTransitionEnd) end
    if valueEl then valueEl:AddEventListener("transitionend", Display.onTransitionEnd) end
end

--------------------------------------------------------------------------
-- Pointer
-- Tracks whether the mouse is hovering/dragging a custom control, and
-- which one (`activeKey`) — so parameter-change callbacks know whether
-- their own control is the one currently shown, and drag-end can trigger
-- the fade-out for whichever control was being dragged.
--------------------------------------------------------------------------

local Pointer = {
    hovering  = false,
    dragging  = false,
    activeKey = nil,
}

-- Marks `key` as the active hovered/dragged control and shows its readout.
-- This is the shared entry point every control type (button, canvas, knob)
-- calls into; Display.show() itself has no notion of "which control".
local function activatePointer(key, label, text, keepVisible)
    Pointer.hovering  = true
    Pointer.activeKey = key
    if keepVisible then Pointer.dragging = true end
    Display.show(label, text, keepVisible)
end

document:AddEventListener("mouseup", function()
    if not Pointer.dragging then return end
    Pointer.dragging = false
    -- Keep activeKey/hovering so the readout can fade out; next native
    -- mouseover or a new custom activatePointer() will replace state cleanly.
    Display.startFade()
end)

--------------------------------------------------------------------------
-- DOM-bound custom controls
-- Simple non-canvas elements (buttons, switches) whose readout text is a
-- single value derived from one parameter.
--------------------------------------------------------------------------

-- Ids of every element this script has bound to custom behavior. Checked
-- later by setupNativeParamElements() to avoid double-handling elements
-- that are both a native [param] element and a custom control.
local customControlIds = {}

-- Wires up hover/click/drag/live-update readout behavior for a single
-- element identified by id. `getText` computes the current display text;
-- `param`, if given, is watched so the readout live-updates while dragging.
local function registerControl(id, label, getText, param)
    local el = document:GetElementById(id)
    if not el then return end
    customControlIds[id] = true

    local key            = id

    local function activate(keepVisible)
        activatePointer(key, label, getText(), keepVisible)
    end

    el:AddEventListener("mouseover", function() activate(false) end)
    el:AddEventListener("click", function() activate(false) end)
    el:AddEventListener("mousedown", function()
        Pointer.dragging = true
        activate(true)
    end)
    el:AddEventListener("mouseout", function()
        if Pointer.activeKey ~= key then return end
        Pointer.hovering = false
    end)

    if param then
        params.onChange(param, function()
            if not Pointer.dragging or Pointer.activeKey ~= key then return end
            Display.show(label, getText(), true)
        end)
    end
end

local function noText() return "" end

-- Like registerControl, but for a specific already-resolved element and a
-- fixed empty display text — used for action buttons that have no value to
-- show, only a label (e.g. "Reset Pattern")
local function registerElement(el, id, label, key)
    if not el then return end
    customControlIds[id] = true

    local function activate(keepVisible)
        activatePointer(key, label, "", keepVisible)
    end

    el:AddEventListener("mouseover", function() activate(false) end)
    el:AddEventListener("click", function() activate(false) end)
    el:AddEventListener("mousedown", function()
        Pointer.dragging = true
        activate(true)
    end)
    el:AddEventListener("mouseout", function()
        if Pointer.activeKey ~= key then return end
        Pointer.hovering = false
    end)
end

-- Registers every element sharing an id (the host UI sometimes duplicates
-- ids across layouts/parts), falling back to a single GetElementById lookup
-- if QuerySelectorAll finds nothing
local function registerAllById(id, label)
    local els = document:QuerySelectorAll("[id='" .. id .. "']")
    if els and #els > 0 then
        for i = 1, #els do
            registerElement(els[i], id, label, id .. ":" .. i)
        end
        return
    end
    local el = document:GetElementById(id)
    if el then registerElement(el, id, label, id) end
end

-- Readouts for the 3 LFOs' clock-divider and clock-sync-switch controls
local function registerLfoClockControls()
    for i = 1, 3 do
        local param = "Lfo" .. i .. " Clock"
        registerControl(
                "LFO-" .. i .. "-Clock-Divider",
                "LFO " .. i .. " Clock Divider",
                function() return params.getText(param) end,
                param
        )
        registerControl(
                "LFO-" .. i .. "-Clock-Switch",
                "LFO " .. i .. " Clock Switch",
                function() return (tonumber(params.get(param)) or 0) ~= 0 and "On" or "Off" end,
                param
        )
    end
end

local ARP_BUTTONS = {
    { id = "Button-Arp-Left", label = "Shift Sequence to Left" },
    { id = "Button-Arp-Right", label = "Shift Sequence to Right" },
    { id = "Button-Arp-Fill", label = "Fill Up Pattern" },
    { id = "Button-Arp-Reset", label = "Reset Pattern" },
    { id = "Button-Arp-Step", label = "Randomize Pattern" },
    { id = "Button-Arp-Velocity", label = "Randomize Velocity" },
    { id = "Button-Arp-Length", label = "Randomize Note Length" },
}

-- Arpeggiator action buttons (shift/fill/reset/randomize) — label-only, no value
local function registerArpButtons()
    for i = 1, #ARP_BUTTONS do
        local btn = ARP_BUTTONS[i]
        registerControl(btn.id, btn.label, noText, nil)
    end
end

-- Preset load/save buttons — label-only, no value. Covers 16 numbered slots
-- across both current and legacy id naming schemes, plus prev/next.
local function registerPresetButtons()
    for i = 0, 15 do
        -- Visible part buttons (same IDs as Part-Manager)
        registerControl("Preset-Load-" .. i, "Preset Load", noText, nil)
        registerControl("Preset-Save-" .. i, "Preset Save", noText, nil)
        -- Legacy / alternate IDs
        registerControl("Load-" .. i, "Preset Load", noText, nil)
        registerControl("Save-" .. i, "Preset Save", noText, nil)
    end
    registerControl("PresetLoad", "Preset Load", noText, nil)
    registerControl("PresetSave", "Preset Save", noText, nil)
    registerAllById("PresetPrev", "Preset Previous")
    registerAllById("PresetNext", "Preset Next")
end

local function registerAnalogModeButton()
    registerControl(
            "Button-Analog-Mode",
            "Filter 1 Mode",
            function()
                local t = params.getText("Filter1 Mode")
                if t and t ~= "" then return t end
                return tostring(params.get("Filter 1 Mode") or 0)
            end,
            "Filter1 Mode"
    )
end

--------------------------------------------------------------------------
-- Simple canvases (LCD waves / morph wave-select)
--------------------------------------------------------------------------

local LFO_SPECIAL_NAMES = { [0] = "Sin", [1] = "Tri", [2] = "Saw", [3] = "Sqr", [4] = "SH", [5] = "SG" }
local OSC_WAVE_COUNT    = Wavetable_Count or 64
local LFO_WAVE_COUNT    = 68

-- Computes the display text for a wave-select parameter: prefers the host's
-- own formatted text, otherwise names LFO shapes below index 6 and falls
-- back to a "W01"-style index label for everything else
local function waveText(param, isLFO, waveCount)
    local hostText = params.getText and params.getText(param)
    if hostText and hostText ~= "" then return hostText end
    local maxWave   = (waveCount or OSC_WAVE_COUNT) - 1
    local waveIndex = math.max(0, math.min(maxWave, math.floor(paramNum(param, 0))))
    if isLFO and waveIndex < 6 then
        return LFO_SPECIAL_NAMES[waveIndex] or tostring(waveIndex)
    elseif isLFO then
        return string.format("W%02d", waveIndex - 3)
    end
    return string.format("W%02d", waveIndex + 1)
end

-- Wires up hover/drag/scroll/dblclick readout behavior for a simple canvas
-- driven by a single parameter (LCD wave displays). `spec` fields: id,
-- label, param, optional getText override, isLFO, waveCount, key.
local function bindParamCanvas(spec)
    local el = document:GetElementById(spec.id)
    if not el then return end
    customControlIds[spec.id] = true

    local key                 = spec.key or ("canvas:" .. spec.id)

    local function currentText()
        if spec.getText then return spec.getText() end
        return waveText(spec.param, spec.isLFO, spec.waveCount)
    end

    local function activate(keepVisible)
        activatePointer(key, spec.label, currentText(), keepVisible)
    end

    el:AddEventListener("mouseover", function() activate(false) end)
    el:AddEventListener("mousedown", function()
        Pointer.dragging = true
        activate(true)
    end)
    el:AddEventListener("mousescroll", function() activate(false) end)
    el:AddEventListener("dblclick", function() activate(false) end)
    el:AddEventListener("mouseout", function()
        if Pointer.activeKey ~= key then return end
        Pointer.hovering = false
    end)

    if spec.param then
        params.onChange(spec.param, function()
            if Pointer.activeKey ~= key then return end
            Display.show(spec.label, currentText(), Pointer.dragging)
        end)
    end
end

local function registerLcdWaves()
    local specs = {
        { id = "LFO-1-LCD-Waves", param = "Lfo1 Shape", label = "LFO 1/Waveform Shape", isLFO = true, waveCount = LFO_WAVE_COUNT },
        { id = "LFO-2-LCD-Waves", param = "Lfo2 Shape", label = "LFO 2/Waveform Shape", isLFO = true, waveCount = LFO_WAVE_COUNT },
        { id = "LFO-3-LCD-Waves", param = "Lfo3 Shape", label = "LFO 3/Waveform Shape", isLFO = true, waveCount = LFO_WAVE_COUNT },
        { id = "Osc-1-LCD-Waves", param = "Osc1 Wave Select", label = "Oscillator 1 Wave Select", waveCount = OSC_WAVE_COUNT },
        { id = "Osc-2-LCD-Waves", param = "Osc2 Wave Select", label = "Oscillator 2 Wave Select", waveCount = OSC_WAVE_COUNT },
        { id = "Osc-1-Knob-LCD-Waves", param = "Osc1 Wave Select", label = "Osc1 Wave Select", waveCount = OSC_WAVE_COUNT },
        { id = "Osc-2-Knob-LCD-Waves", param = "Osc2 Wave Select", label = "Osc2 Wave Select", waveCount = OSC_WAVE_COUNT },
    }
    for i = 1, #specs do
        bindParamCanvas(specs[i])
    end
end

--------------------------------------------------------------------------
-- Filter canvases
-- Independently re-derives the filter LCD's cutoff/resonance handle position
-- (mirroring the actual filter canvas widget) purely to hit-test whether the
-- cursor is over that handle vs. the general cutoff-drag area of the strip.
--------------------------------------------------------------------------

local FILTER_CANVAS_W                        = 166
local FILTER_BOX, FILTER_HALF, FILTER_STROKE = 10, 5, 2
local FILTER_TOP, FILTER_BOT                 = 28, 72
local FILTER_M3_TOP, FILTER_M3_BOT           = 72, 128
local FILTER_HIT_MARGIN                      = 8

-- Maps a normalized cutoff (0..1) to a normalized position along the curve,
-- given where the curve's "knee" sits (filter-mode dependent)
local function tFromCutoff(cut, knee)
    if cut <= 0.5 then return cut * 2 * knee end
    return knee + (cut - 0.5) * 2 * (1 - knee)
end

-- True if (lx, ly) is within marginPx of the cutoff/resonance handle for the
-- given filter mode/cutoff/resonance parameters. Handle x-position depends
-- on filter mode (each mode's curve shape places it differently); handle
-- y-position is resonance, except mode 3 which uses a separate Y range.
local function filterSquareHit(el, modeName, cutoffName, resName, lx, ly, marginPx)
    local w = el.offset_width
    if w <= 0 then return false end
    local scale = w / FILTER_CANVAS_W
    local mode  = paramNum(modeName, 0)
    local cut   = clamp01(paramNum(cutoffName, 64) / 127)
    local res   = clamp01(paramNum(resName, 64) / 127)

    local yPos  = FILTER_BOT - res * (FILTER_BOT - FILTER_TOP)
    local xPos

    if mode == 0 or mode == 4 or mode == 5 or mode == 6 or mode == 7 then
        local t = tFromCutoff(cut, 0.5593)
        xPos    = 12 + t * (FILTER_CANVAS_W - FILTER_BOX - 38)
    elseif mode == 1 then
        local knee = ((83 - 1 - FILTER_HALF) - 26) / (FILTER_CANVAS_W - FILTER_BOX - 38)
        local t    = tFromCutoff(cut, knee)
        xPos       = 26 + t * (FILTER_CANVAS_W - FILTER_BOX - 38)
    elseif mode == 2 then
        xPos = 26 + cut * (FILTER_CANVAS_W - FILTER_BOX - 52)
    elseif mode == 3 then
        xPos = 26 + cut * (FILTER_CANVAS_W - FILTER_BOX - 52)
        yPos = FILTER_M3_BOT - res * (FILTER_M3_BOT - FILTER_M3_TOP)
    else
        xPos = (FILTER_CANVAS_W - FILTER_BOX) * 0.5
    end

    local handleSize, strokeW, halfHandle = FILTER_BOX * scale, FILTER_STROKE * scale, FILTER_HALF * scale
    local x, y           = xPos * scale + halfHandle, yPos * scale + halfHandle
    local outerX, outerY = roundToPixel(x - halfHandle - strokeW), roundToPixel(y - halfHandle - strokeW)
    local outerS         = roundToPixel(handleSize + strokeW * 2)
    local margin         = (marginPx or FILTER_HIT_MARGIN) * scale
    return lx >= outerX - margin and lx <= outerX + outerS + margin
            and ly >= outerY - margin and ly <= outerY + outerS + margin
end

-- Wires up hover/drag/scroll/dblclick readout behavior for a filter LCD.
-- Two readout "zones": the cutoff/resonance handle (shows both values) vs.
-- the rest of the strip (shows cutoff only), switched based on hit-testing.
local function bindFilterCanvas(id, modeName, cutoffName, resName)
    local el = document:GetElementById(id)
    if not el then return end
    customControlIds[id]         = true

    local dualKey                = "filter:" .. cutoffName .. ":dual"
    local cutKey                 = "filter:" .. cutoffName .. ":cut"
    local squareZone, cutoffZone = false, false
    local dragDual               = false

    local dualLabel              = (cutoffName == "Cutoff2") and "Filter 2 Cutoff / Resonance" or "Filter 1 Cutoff / Resonance"
    local cutLabel               = (cutoffName == "Cutoff2") and "Filter 2 Cutoff" or "Filter 1 Cutoff"

    local function dualText()
        local cut = math.floor(paramNum(cutoffName, 64) + 0.5)
        local res = math.floor(paramNum(resName, 64) + 0.5)
        return cut .. " / " .. res
    end

    local function cutText()
        return paramTextOr(cutoffName, tostring(math.floor(paramNum(cutoffName, 64) + 0.5)))
    end

    local function showDual(keep) activatePointer(dualKey, dualLabel, dualText(), keep) end
    local function showCut(keep) activatePointer(cutKey, cutLabel, cutText(), keep) end

    el:AddEventListener("mousedown", function(event)
        local lx, ly           = getLocalMouse(event, el)
        dragDual               = filterSquareHit(el, modeName, cutoffName, resName, lx, ly)
        squareZone, cutoffZone = dragDual, not dragDual
        Pointer.dragging       = true
        if dragDual then showDual(true) else showCut(true) end
    end)

    el:AddEventListener("mousemove", function(event)
        if Pointer.dragging then return end
        local lx, ly   = getLocalMouse(event, el)
        local onSquare = filterSquareHit(el, modeName, cutoffName, resName, lx, ly)
        if onSquare then
            cutoffZone = false
            if not squareZone then
                squareZone = true
                showDual(false)
            end
        else
            squareZone = false
            if not cutoffZone then
                cutoffZone = true
                showCut(false)
            end
        end
    end)

    el:AddEventListener("mouseout", function()
        if Pointer.dragging then return end
        squareZone, cutoffZone = false, false
    end)

    el:AddEventListener("mousescroll", function(event)
        local lx, ly = getLocalMouse(event, el)
        if filterSquareHit(el, modeName, cutoffName, resName, lx, ly) then
            showDual(false)
        else
            showCut(false)
        end
    end)

    el:AddEventListener("dblclick", function(event)
        local lx, ly = getLocalMouse(event, el)
        if filterSquareHit(el, modeName, cutoffName, resName, lx, ly) then
            showDual(false)
        else
            showCut(false)
        end
    end)

    local function refreshIfActive()
        if Pointer.activeKey == dualKey then
            Display.show(dualLabel, dualText(), Pointer.dragging)
        elseif Pointer.activeKey == cutKey then
            Display.show(cutLabel, cutText(), Pointer.dragging)
        end
    end

    params.onChange(cutoffName, refreshIfActive)
    params.onChange(resName, refreshIfActive)
end

local function registerFilterCanvases()
    bindFilterCanvas("Filter-1-LCD", "Filter1 Mode", "Cutoff", "Filter1 Resonance")
    bindFilterCanvas("Filter-1-Easy-LCD", "Filter1 Mode", "Cutoff", "Filter1 Resonance")
    bindFilterCanvas("Filter-2-LCD", "Filter2 Mode", "Cutoff2", "Filter2 Resonance")
end

--------------------------------------------------------------------------
-- ADSR canvases
--------------------------------------------------------------------------

local ADSR_HIT_ORDER                   = { "R", "T", "D", "S", "A" }
local ADSR_TIME_NEUTRAL                = 64 / 127
local ADSR_BOX, ADSR_HALF, ADSR_STROKE = 10, 5, 2
local ADSR_HIT_MARGIN                  = 8

local AMP_PARAMS = {
    A = "Amp Env Attack", D = "Amp Env Decay", S = "Amp Env Sustain",
    T = "Amp Env Sustain Time", R = "Amp Env Release",
}

local FILTER_SETS = {
    { A = "Filter Env Attack", D = "Filter Env Decay", S = "Filter Env Sustain", T = "Filter Env Sustain Time", R = "Filter Env Release" },
    { A = "Envelope 3/Attack", D = "Envelope 3/Decay", S = "Envelope 3/Sustain", T = "Envelope 3/Sustain Time", R = "Envelope 3/Release" },
    { A = "Envelope 4/Attack", D = "Envelope 4/Decay", S = "Envelope 4/Sustain", T = "Envelope 4/Sustain Time", R = "Envelope 4/Release" },
}

-- Display labels only (param names above stay for params.get / onChange)
local AMP_LABELS = {
    A  = "Amplifier Envelope/Attack",
    D  = "Amplifier Envelope/Decay",
    S  = "Amplifier Envelope/Sustain",
    T  = "Amplifier Envelope/Sustain Slope",
    R  = "Amplifier Envelope/Release",
    DS = "Amplifier Envelope Decay / Sustain",
}

local FILTER_LABELS = {
    {
        A  = "Filter Envelope Attack",
        D  = "Filter Envelope/Decay",
        S  = "Filter Envelope/Sustain",
        T  = "Filter Envelope/Sustain Slope",
        R  = "Filter Envelope/Release",
        DS = "Filter Envelope Decay / Sustain",
    },
    {
        A  = "Envelope 3/Attack",
        D  = "Envelope 3/Decay",
        S  = "Envelope 3/Sustain",
        T  = "Envelope 3/Sustain Slope",
        R  = "Envelope 3/Release",
        DS = "Envelope 3 Decay / Sustain",
    },
    {
        A  = "Envelope 4/Attack",
        D  = "Envelope 4/Decay",
        S  = "Envelope 4/Sustain",
        T  = "Envelope 4/Sustain Slope",
        R  = "Envelope 4/Release",
        DS = "Envelope 4 Decay / Sustain",
    },
}

local adsrFilterIndex = 1   -- which of the 3 FILTER_SETS/FILTER_LABELS is currently shown

-- Returns the active parameter-name set for a canvas entry (Amp or the selected filter envelope)
local function adsrNames(isFilter)
    return isFilter and FILTER_SETS[adsrFilterIndex] or AMP_PARAMS
end

-- Returns the matching display-label set for a canvas entry
local function adsrLabels(isFilter)
    return isFilter and FILTER_LABELS[adsrFilterIndex] or AMP_LABELS
end

-- Recomputes the unscaled (pre-canvas-scale) coordinates of every ADSR
-- handle from the current A/D/S/T/R parameter values — mirrors the layout
-- math in the actual ADSR canvas widget, purely so this script can hit-test
-- the same handle positions without needing to read them from that widget.
local function adsrLayout(entry, names)
    local A              = clamp01(paramNum(names.A, 0) / 127)
    local D              = clamp01(paramNum(names.D, 127) / 127)
    local S              = clamp01(paramNum(names.S, 127) / 127)
    local ST             = clamp01(paramNum(names.T, 64) / 127)
    local R              = clamp01(paramNum(names.R, 4) / 127)

    local x0, yBot, yTop = entry.ml, entry.mt + entry.uh, entry.mt
    local ax             = x0 + A * math.max(1, entry.limitX - x0)
    local minDist        = entry.gap
    local maxDist        = math.max(minDist + 1, entry.limitX - x0)
    local dx             = ax + minDist + D * (maxDist - minDist)
    local sy             = yBot - S * entry.uh

    local slopeNorm      = 0
    if ST < ADSR_TIME_NEUTRAL then
        slopeNorm = (ST - ADSR_TIME_NEUTRAL) / ADSR_TIME_NEUTRAL
    elseif ST > ADSR_TIME_NEUTRAL then
        slopeNorm = (ST - ADSR_TIME_NEUTRAL) / (1 - ADSR_TIME_NEUTRAL)
    end
    local ty = sy
    if slopeNorm ~= 0 then
        ty = math.max(yTop, math.min(yBot, sy - slopeNorm * 0.25 * entry.uh))
    end

    local minR = entry.timeX + entry.gap
    local maxR = entry.ml + entry.uw - 2
    local rx   = minR + R * math.max(1, maxR - minR)
    return ax, yTop, dx, sy, entry.sustainX, sy, entry.timeX, ty, rx, yBot
end

-- Returns which handle id ("A"/"D"/"S"/"T"/"R") the given local coordinates
-- fall on, checked in ADSR_HIT_ORDER so overlapping handles resolve consistently
local function adsrHit(entry, names, lx, ly)
    local w = entry.el.offset_width
    if w <= 0 then return nil end
    local scale                                       = w / entry.cw
    local ax, yTop, dx, sy, sx, sy2, tx, ty, rx, yBot = adsrLayout(entry, names)
    local handleSize, strokeW, halfHandle              = ADSR_BOX * scale, ADSR_STROKE * scale, ADSR_HALF * scale
    local margin                                      = ADSR_HIT_MARGIN * scale

    local function handleRect(cx, cy)
        local x, y           = cx * scale, cy * scale
        local outerX, outerY = roundToPixel(x - halfHandle - strokeW), roundToPixel(y - halfHandle - strokeW)
        local outerS         = roundToPixel(handleSize + strokeW * 2)
        return outerX, outerY, outerS
    end

    local pts = {
        A = { ax, yTop },
        S = { sx, sy2 },
        D = { dx, sy },
        T = { tx, ty },
        R = { rx, yBot },
    }
    for i = 1, #ADSR_HIT_ORDER do
        local id         = ADSR_HIT_ORDER[i]
        local p          = pts[id]
        local ox, oy, os = handleRect(p[1], p[2])
        if lx >= ox - margin and lx <= ox + os + margin
                and ly >= oy - margin and ly <= oy + os + margin then
            return id
        end
    end
    return nil
end

-- Shows the readout for one ADSR handle. The "D" (Decay) handle is special:
-- since dragging it can also move Sustain, its readout shows both values
-- ("Decay / Sustain") rather than Decay alone.
local function adsrShow(entry, pointId, keepVisible)
    if not pointId then return end
    local names  = adsrNames(entry.isFilter)
    local labels = adsrLabels(entry.isFilter)
    local key    = "adsr:" .. (entry.isFilter and ("filter" .. adsrFilterIndex) or "amp") .. ":" .. pointId
    if pointId == "D" then
        local dName, sName = names.D, names.S
        local dText = paramTextOr(dName, tostring(math.floor(paramNum(dName, 127) + 0.5)))
        local sText = paramTextOr(sName, tostring(math.floor(paramNum(sName, 127) + 0.5)))
        activatePointer(key, labels.DS, dText .. " / " .. sText, keepVisible)
        return
    end
    local name = names[pointId]
    if not name then return end
    local label = labels[pointId] or name
    activatePointer(key, label, paramTextOr(name, tostring(math.floor(paramNum(name, 64) + 0.5))), keepVisible)
end

-- Wires up hover/drag/scroll/dblclick readout behavior for one ADSR canvas.
-- cw/ch/ml/mt/mr/mb/limitX/sustainX/timeX/gap mirror the actual ADSR
-- widget's layout constants — must stay in sync with it for hit-testing to
-- land on the same handle positions the widget actually draws.
local function bindAdsrCanvas(id, isFilter, cw, ch, ml, mt, mr, mb, limitX, sustainX, timeX, gap)
    local el = document:GetElementById(id)
    if not el then return end
    customControlIds[id] = true

    local entry          = {
        el           = el, isFilter = isFilter,
        cw           = cw, ch = ch, ml = ml, mt = mt, mr = mr, mb = mb,
        uw           = cw - ml - mr, uh = ch - mt - mb,
        limitX       = limitX, sustainX = sustainX, timeX = timeX, gap = gap,
        activeHandle = nil, dragPoint = nil,
    }

    el:AddEventListener("mousedown", function(event)
        local lx, ly = getLocalMouse(event, el)
        local hit    = adsrHit(entry, adsrNames(isFilter), lx, ly)
        if not hit then return end
        entry.dragPoint    = hit
        entry.activeHandle = hit
        Pointer.dragging   = true
        adsrShow(entry, hit, true)
    end)

    el:AddEventListener("mousemove", function(event)
        if Pointer.dragging then return end
        local lx, ly = getLocalMouse(event, el)
        local hit    = adsrHit(entry, adsrNames(isFilter), lx, ly)
        if hit ~= entry.activeHandle then
            entry.activeHandle = hit
            if hit then adsrShow(entry, hit, false) end
        end
    end)

    el:AddEventListener("mouseout", function()
        if Pointer.dragging then return end
        entry.activeHandle = nil
        entry.dragPoint    = nil
        if Pointer.activeKey and Pointer.activeKey:sub(1, 5) == "adsr:" then
            Pointer.hovering = false
        end
    end)

    el:AddEventListener("mousescroll", function(event)
        local lx, ly = getLocalMouse(event, el)
        local hit    = entry.activeHandle or adsrHit(entry, adsrNames(isFilter), lx, ly)
        if hit then adsrShow(entry, hit, false) end
    end)

    el:AddEventListener("dblclick", function(event)
        local lx, ly = getLocalMouse(event, el)
        local hit    = adsrHit(entry, adsrNames(isFilter), lx, ly)
        if hit then adsrShow(entry, hit, false) end
    end)

-- Refreshes the readout in place if this canvas's active/dragged handle's
-- underlying parameter just changed (e.g. via a different control)
    local function refreshIfActive()
        local point = Pointer.dragging and entry.dragPoint or entry.activeHandle
        if not point then return end
        if Pointer.activeKey and Pointer.activeKey:sub(1, 5) == "adsr:" then
            adsrShow(entry, point, Pointer.dragging)
        end
    end

    if isFilter then
        for s = 1, #FILTER_SETS do
            for _, name in pairs(FILTER_SETS[s]) do
                params.onChange(name, refreshIfActive)
            end
        end
    else
        for _, name in pairs(AMP_PARAMS) do
            params.onChange(name, refreshIfActive)
        end
    end

    return entry
end

-- Registers both ADSR canvases and the filter-envelope-select buttons that
-- switch which of the 3 FILTER_SETS the filter canvas currently reflects
local function registerAdsrCanvases()
    bindAdsrCanvas("Amplifier-Envelope-Canvas", false, 466, 176, 17, 15, 15, 17, 141, 265, 325, 6)
    bindAdsrCanvas("Filter-Envelopes-Canvas", true, 432, 176, 15, 15, 15, 17, 131, 247, 301, 6)

    local buttons = {
        ["Button-Filter-Envelope"] = 1,
        ["Button-Envelope-3"]      = 2,
        ["Button-Envelope-4"]      = 3,
    }
    for id, idx in pairs(buttons) do
        local btn = document:GetElementById(id)
        if btn then
            btn:AddEventListener("click", function()
                adsrFilterIndex = idx
            end)
        end
    end
end

--------------------------------------------------------------------------
-- Arpeggiator canvas
-- Independently re-derives the step-grid layout (mirroring the actual
-- Arpeggiator canvas widget) purely to hit-test which step/handle is under
-- the cursor. Purely read-only: never calls params.set.
--------------------------------------------------------------------------

local ARP_STEPS      = 32
local ARP_DESIGN_W   = 1280   -- reference canvas width the layout math below was designed at
local ARP_EDGE       = 8      -- hit-test margin around a bar's top/right edge for drag handles
local ARP_MIN_VEL_PX = 4      -- smallest bar height, even for very low velocity
local ARP_MIN_BAR_PX = 4      -- smallest bar width, even for very short length

-- Builds the underlying parameter name for a given step and field, e.g. "Step 5 Velocity"
local function arpStepName(step, suffix)
    return "Step " .. step .. " " .. suffix
end

-- Reads a step's value, transparently substituting preset data when a
-- read-only preset (ArpPresets, provided globally by the pattern editor) is selected
local function arpGetStep(step, kind, default)
    local sel = math.max(0, math.min(63, paramNum("Arp Pattern Selct", 0)))
    if sel > 0 and ArpPresets and ArpPresets[sel] then
        local data = ArpPresets[sel][step]
        if data then
            if kind == "Bitfield" then return data[1] or default end
            if kind == "Velocity" then return data[2] or default end
            if kind == "Length" then return data[3] or default end
        end
    end
    return paramNum(arpStepName(step, kind), default)
end

-- Number of steps currently in the pattern (1..ARP_STEPS)
local function arpPatternLength()
    local raw = paramNum("Arpeggiator/UserPatternLength", ARP_STEPS - 1)
    return math.max(0, math.min(ARP_STEPS - 1, raw)) + 1
end

-- Recomputes every active step's on-screen rectangle (position/size), for
-- hit-testing. Mirrors the actual Arpeggiator canvas's layout math: groups
-- of consecutive active steps share one bar (legato), width encodes Length
-- (scaled by group size and the global gate factor), height encodes Velocity,
-- and even-numbered steps get a swing offset.
local function arpRebuildRects(el)
    local canvasWidth, canvasHeight = el.offset_width, el.offset_height
    if canvasWidth <= 0 or canvasHeight <= 0 then return {}, 1 end
    local scale     = canvasWidth / ARP_DESIGN_W
    local baseW     = canvasWidth / ARP_STEPS
    local bitActive = {}
    for i = 1, ARP_STEPS do
        bitActive[i] = arpGetStep(i, "Bitfield", 0) > 0
    end
    local limitIndex   = arpPatternLength()
    local groupSize, i = {}, 1
    while i <= ARP_STEPS do
        if bitActive[i] then
            local j = i + 1
            while j <= ARP_STEPS and not bitActive[j] do j = j + 1 end
            groupSize[i] = j - i
            i            = j
        else
            groupSize[i] = 0
            i            = i + 1
        end
    end
    local groups = {}
    for s = 1, ARP_STEPS do
        if bitActive[s] then
            local gSize     = math.max(1, groupSize[s] or 0)
            local effective = math.min(gSize, limitIndex - s + 1)
            if effective < 1 then effective = gSize end
            for j = s, s + effective - 1 do
                if j <= ARP_STEPS then
                    groups[j] = { startStep = s, size = effective }
                end
            end
        end
    end

    local noteLen     = paramNum("Arp Note Length", 64)
    local globalGate  = (noteLen <= 64) and (noteLen / 64.0) or (1.0 + (noteLen - 64) / 63.0)
    local swingFactor = math.max(0, math.min(1, paramNum("Arp Swing", 0) / 127.0))
    local maxSwingPx  = baseW * 0.45 * swingFactor
    local minVelPx    = ARP_MIN_VEL_PX * scale
    local minBarPx    = ARP_MIN_BAR_PX * scale
    local edgeMargin  = math.max(1, roundToPixel(2 * scale))

    local rects       = {}
    for s = 1, ARP_STEPS do
        if bitActive[s] then
            local inRange      = s <= limitIndex
            local leftPos      = baseW * (s - 1)
            local g            = groups[s]
            local gSize        = (g and g.size) or 1
            local swingOffset  = (s % 2 == 0) and maxSwingPx or 0
            local groupWidthPx = baseW * gSize
            local stepLen      = arpGetStep(s, "Length", 64)
            local targetWidth  = groupWidthPx * globalGate * (stepLen / 127.0)
            local maxAllowed   = math.max(minBarPx, (baseW * gSize) - swingOffset - edgeMargin)
            local drawWidth    = math.max(minBarPx, math.min(targetWidth, maxAllowed))
            drawWidth          = math.min(drawWidth, (canvasWidth - leftPos) - edgeMargin)
            local finalLeft    = leftPos + swingOffset
            if finalLeft + drawWidth > canvasWidth - edgeMargin then
                finalLeft = math.max(0, canvasWidth - drawWidth - edgeMargin)
            end
            local vel    = arpGetStep(s, "Velocity", 64)
            local barH   = math.max(minVelPx, (vel / 127.0) * canvasHeight)
            local barTop = canvasHeight - barH
            rects[s]     = {
                x       = roundToPixel(finalLeft), y = roundToPixel(barTop), w = roundToPixel(drawWidth), h = roundToPixel(barH),
                inRange = inRange,
            }
        end
    end
    return rects, scale
end

-- Returns which step (and which part of its bar — "top"/"right"/"corner"/"body")
-- the given local coordinates fall on, or nil if none. "top"/"right"/"corner"
-- correspond to the Velocity/Length/both drag handles.
local function arpHit(el, mx, my)
    local rects, scale = arpRebuildRects(el)
    local margin       = ARP_EDGE * scale
    for s = 1, ARP_STEPS do
        local r = rects[s]
        if r and r.inRange
                and mx >= r.x - margin and mx <= r.x + r.w + margin
                and my >= r.y - margin and my <= r.y + r.h + margin then
            local nearRight = math.abs(mx - (r.x + r.w)) <= margin
            local nearTop   = math.abs(my - r.y) <= margin
            if nearTop and nearRight then return s, "corner"
            elseif nearTop then return s, "top"
            elseif nearRight then return s, "right"
            else return s, "body" end
        end
    end
    return nil, nil
end

-- Maps a local x coordinate to a step index (1..ARP_STEPS), regardless of
-- whether a step is actually active there — used by the wheel handler,
-- which acts on raw grid columns rather than rendered bars
local function arpColumn(el, mx)
    local canvasWidth = el.offset_width
    if canvasWidth <= 0 then return 1 end
    return math.max(1, math.min(ARP_STEPS, math.floor(mx / (canvasWidth / ARP_STEPS)) + 1))
end

-- Builds the readout label/text for a given step and handle mode
local function arpLabelText(step, mode)
    if mode == "top" then
        return "Step " .. step .. " Velocity", tostring(math.floor(arpGetStep(step, "Velocity", 64) + 0.5))
    elseif mode == "right" then
        return "Step " .. step .. " Length", tostring(math.floor(arpGetStep(step, "Length", 64) + 0.5))
    elseif mode == "corner" then
        local vel = math.floor(arpGetStep(step, "Velocity", 64) + 0.5)
        local len = math.floor(arpGetStep(step, "Length", 64) + 0.5)
        return "Step " .. step .. " Velocity / Length", vel .. " / " .. len
    end
    return nil, nil
end

-- Wires up hover/drag/scroll/dblclick readout behavior for the arpeggiator
-- step grid. Left-drag on a handle shows Velocity/Length/both live; on the
-- corner handle, Shift/Ctrl during the drag narrows the readout to
-- Length-only/Velocity-only (matching the actual widget's modifier behavior).
local function registerArpCanvas()
    local el = document:GetElementById("Lua-Arpeggiator")
    if not el then return end
    customControlIds["Lua-Arpeggiator"] = true

    local hoverStep, hoverMode          = nil, nil
    local dragStep, dragMode            = nil, nil

    local function showStep(step, mode, keepVisible)
        local label, text = arpLabelText(step, mode)
        if not label then return end
        activatePointer(mode .. ":" .. step, label, text, keepVisible)
    end

    -- Plain left-click (not right/middle/alt-click) on a handle begins tracking
    -- a drag purely for readout purposes — this script never edits the parameter
    el:AddEventListener("mousedown", function(event)
        if keyDown(event.parameters.alt_key) then return end
        local button = event.parameters.button
        if button == 1 or button == 2 then return end
        local mx, my     = getLocalMouse(event, el)
        local step, mode = arpHit(el, mx, my)
        if not step or mode == "body" then return end
        dragStep, dragMode   = step, mode
        hoverStep, hoverMode = nil, nil
        Pointer.dragging     = true
        showStep(step, mode, true)
    end)

    el:AddEventListener("mousemove", function(event)
        if Pointer.dragging or dragStep then return end
        local mx, my     = getLocalMouse(event, el)
        local step, mode = arpHit(el, mx, my)
        if mode == "body" then step, mode = nil, nil end
        if step == hoverStep and mode == hoverMode then return end
        hoverStep, hoverMode = step, mode
        if mode == "top" or mode == "right" or mode == "corner" then
            showStep(step, mode, false)
        end
    end)

    el:AddEventListener("mouseout", function()
        hoverStep, hoverMode = nil, nil
    end)

    el:AddEventListener("mousescroll", function(event)
        local mx    = getLocalMouse(event, el)
        local col   = arpColumn(el, mx)
        local shift = keyDown(event.parameters.shift_key)
        showStep(col, shift and "right" or "top", false)
    end)

    el:AddEventListener("dblclick", function(event)
        local mx, my     = getLocalMouse(event, el)
        local step, mode = arpHit(el, mx, my)
        if not step then return end
        if mode == "body" or not mode then
            showStep(step, "corner", false)
        else
            showStep(step, mode, false)
        end
    end)

    -- Live-updates the readout while a drag is in progress (matches the
    -- modifier-key readout narrowing described above)
    document:AddEventListener("mousemove", function(event)
        if not dragStep then return end
        local onlyLength   = dragMode == "corner" and keyDown(event.parameters.shift_key)
        local onlyVelocity = dragMode == "corner" and keyDown(event.parameters.ctrl_key)
        local displayMode  = dragMode
        if onlyLength then displayMode = "right"
        elseif onlyVelocity then displayMode = "top" end
        showStep(dragStep, displayMode, true)
    end)

    document:AddEventListener("mouseup", function(event)
        if not dragStep then return end
        local step, mode   = dragStep, dragMode
        dragStep, dragMode = nil, nil
        local mx, my       = getLocalMouse(event, el)
        local hitStep, hitMode = arpHit(el, mx, my)
        if hitMode == "body" then hitStep, hitMode = nil, nil end
        hoverStep, hoverMode = hitStep, hitMode
        if hitMode == "top" or hitMode == "right" or hitMode == "corner" then
            showStep(hitStep, hitMode, false)
        end
    end)

    -- Refreshes the readout in place if the currently shown step/handle's
    -- Velocity or Length just changed (e.g. edited via the actual widget
    -- while this readout is being kept visible by a drag)
    local function refreshArpActive()
        if not Pointer.activeKey then return end
        local mode, step = Pointer.activeKey:match("^(%a+):(%d+)$")
        step             = tonumber(step)
        if not mode or not step then return end
        if mode ~= "top" and mode ~= "right" and mode ~= "corner" then return end
        local label, text = arpLabelText(step, mode)
        if label then
            Display.show(label, text, Pointer.dragging)
        end
    end

    for i = 1, ARP_STEPS do
        params.onChange(arpStepName(i, "Velocity"), refreshArpActive)
        params.onChange(arpStepName(i, "Length"), refreshArpActive)
    end
end

--------------------------------------------------------------------------
-- Native [param] elements yield while custom is active
-- Every native host element with a [param] attribute that this script hasn't
-- claimed as a custom control still needs its readout handed back to it when
-- the mouse enters it.
--------------------------------------------------------------------------

-- Binds a mouseover handler to every native [param] element not already
-- registered as a custom control, so hovering it clears custom pointer
-- state and restores the native readout
local function setupNativeParamElements()
    local els = document:QuerySelectorAll("[param]")
    for i = 1, #els do
        local el = els[i]
        local id = el.id
        if not (id and customControlIds[id]) then
            -- Entering a host param: hand readout back to native and clear
            -- custom pointer state. Do NOT touch native visibility on mouseout —
            -- that was hiding the host focus after leaving ADSR/native knobs
            -- whenever Pointer.hovering was still true from an earlier custom hover.
            el:AddEventListener("mouseover", function()
                if Pointer.dragging then return end
                Pointer.hovering  = false
                Pointer.activeKey = nil
                Display.hide(true)
            end)
        end
    end
end

--------------------------------------------------------------------------
-- Entry point
-- Global — bound to a widget lifecycle event by name, do not rename.
-- Guarded by `initialized` so re-invocation is a safe no-op.
--------------------------------------------------------------------------

function Custom_Display()
    if initialized then return end
    initialized = true

    registerLfoClockControls()
    registerArpButtons()
    registerPresetButtons()
    registerAnalogModeButton()
    registerLcdWaves()
    registerFilterCanvases()
    registerAdsrCanvases()
    registerArpCanvas()
    Display.bindTransitionEnd()
    setupNativeParamElements()
end
