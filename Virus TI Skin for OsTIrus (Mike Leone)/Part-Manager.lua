-- ============================================================
-- Preset part manager
-- Manages the 16 numbered preset load/save button rows and their name
-- labels: highlights whichever row corresponds to the currently active
-- part, and routes each row's load/save click through to the host's single
-- shared PresetLoad/PresetSave controls (so this script never implements
-- loading/saving itself — it only decides which row looks "active").
-- ============================================================

local initialized = false
local Load_Buttons, Save_Buttons, Preset_Name = {}, {}, {}   -- [0..15] -> element, per preset row
local PresetLoad, PresetSave   -- the host's single shared load/save controls, clicked on the active row's behalf

-- Enables the load/save buttons and highlights the name label for the row
-- matching `part` (0..15), disabling all others
local function refreshActivePart(part)
    part = (part >= 0 and part <= 15) and part or 0
    for i = 0, 15 do
        local active = (i == part)
        if Load_Buttons[i] then Load_Buttons[i]:SetClass("disabled", not active) end
        if Save_Buttons[i] then Save_Buttons[i]:SetClass("disabled", not active) end
        if Preset_Name[i] then Preset_Name[i]:SetClass("Preset-Name-Active", active) end
    end
end

-- ------------------------------------------------------------
-- Entry point
-- Global — bound to a widget lifecycle event by name, do not rename.
-- Guarded by `initialized` so re-invocation is a safe no-op.
-- ------------------------------------------------------------
function Part_Manager()
    if initialized then return end
    initialized = true

    PresetLoad = document:GetElementById("PresetLoad")
    PresetSave = document:GetElementById("PresetSave")

    -- Finds each of the 16 rows' load/save buttons and name label by id,
    -- and wires each row's load/save click to trigger the host's shared control
    for i = 0, 15 do
        local loadEl = document:GetElementById("Preset-Load-" .. i)
        if loadEl then
            Load_Buttons[i] = loadEl
            loadEl:AddEventListener("click", function()
                if PresetLoad then PresetLoad:Click() end
            end)
        end

        local saveEl = document:GetElementById("Preset-Save-" .. i)
        if saveEl then
            Save_Buttons[i] = saveEl
            saveEl:AddEventListener("click", function()
                if PresetSave then PresetSave:Click() end
            end)
        end

        local nameEl = document:GetElementById("Preset-Name-" .. i)
        if nameEl then Preset_Name[i] = nameEl end
    end

    -- Keeps the active-row highlight in sync whenever the host switches parts
    params.onPartChanged(refreshActivePart)
    refreshActivePart(params.getCurrentPart())
end
