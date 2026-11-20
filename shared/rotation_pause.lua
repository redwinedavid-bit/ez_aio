-- Shared rotation pause / hard-stop helpers.
-- Used by all class rotations to avoid interrupting eating/drinking.

local rotation_pause = {}

---@type enums
local enums = require("common/enums")

---@type buff_manager
local buff_manager = require("common/modules/buff_manager")

local FALLBACK_EAT_DRINK_AURAS = { 
    -- Generic / Era (all ranks)
    430, 431, 432, 433, -- Drink (Rank 1-4)
    434, 435, 436,       -- Food  (Rank 1-3)
    -- TBC Common (Purified Draenic Water, etc)
    27089, 27088, 27087, 27086, 27085, 27084,
    27083, 27082, 27081, 27080,
    -- Mage Tables / TBC Specific
    33722, 33717, 33042, 29007,
    -- TBC Extended (Conjured / Vendor)
    10250, 22734, 25696, 28616, 33254, 34291,
    43706, 43763, 46755,
    -- General RESTING
    1127, -- Eating (generic)
    1129, -- Eating (generic alt)
    1131, -- Eating (generic alt)
    1133, -- Drinking (Mage)
    1135, -- Eating (Mage)
    1137, -- Rested (Inn)
}

local last_resting_ms = 0
local STICKY_PAUSE_MS = 1500

---@param local_player game_object
---@param cache_ms? number
---@return boolean
function rotation_pause.is_eating_or_drinking(local_player, cache_ms)
    if not local_player then
        return false
    end

    local now = core.game_time()
    local cache_time = cache_ms or 200

    -- Hard break: If moving or in combat, we are definitely NOT resting.
    if local_player:is_moving() or local_player:is_in_combat() then
        last_resting_ms = 0
        return false
    end

    local is_resting = false

    -- Build specs list; use manual iteration (NOT ipairs) to skip nil entries.
    -- ipairs stops at the first nil gap, which would skip FALLBACK_EAT_DRINK_AURAS
    -- if any enums.buff_db field is nil.
    local specs = {
        enums.buff_db and enums.buff_db.EATING_OR_DRINKING or false,
        enums.buff_db and enums.buff_db.DRINKING or false,
        enums.buff_db and enums.buff_db.EATING or false,
        FALLBACK_EAT_DRINK_AURAS,
    }

    for i = 1, #specs do
        local spec = specs[i]
        if spec and spec ~= false then
            -- Fast path: aura cache (used by most rotations).
            local ok_aura, aura = pcall(function()
                return buff_manager:get_aura_data(local_player, spec, cache_time)
            end)
            if ok_aura and aura and aura.is_active == true then
                is_resting = true
                break
            end

            -- Last fallback: direct unit API (supports id list in this project).
            local ok_direct, up = pcall(function()
                return local_player:buff_up(spec) == true
            end)
            if ok_direct and up == true then
                is_resting = true
                break
            end
        end
    end

    if is_resting then
        last_resting_ms = now
        return true
    end

    -- STICKY PAUSE: Keep pausing for a short duration after buff disappeared 
    -- to prevent "flickering" into a cast if the buff is refreshing or slightly delayed.
    if last_resting_ms > 0 and (now - last_resting_ms) < STICKY_PAUSE_MS then
        return true
    end

    return false
end

return rotation_pause
